package main

import "base:runtime"
import "core:log"
import "core:slice"
import "vendor:glfw"
import vk "vendor:vulkan"

Globals :: struct {
	odin_context: runtime.Context,
	window: glfw.WindowHandle,
	instance: vk.Instance,
	debug_messenger: vk.DebugUtilsMessengerEXT,
	surface: vk.SurfaceKHR,
	physical_device: vk.PhysicalDevice,
	queue_family_index: u32,
	device: vk.Device,
	queue: vk.Queue,
	swapchain: vk.SwapchainKHR,
}
g: Globals

main :: proc() {
	context.logger = log.create_console_logger()
	g.odin_context = context

	glfw.SetErrorCallback(proc "c" (error: i32, description: cstring) {
		context = g.odin_context
		log.errorf("GLFW Error {}: {}", error, description)
	})

	if !glfw.Init() do return
	defer glfw.Terminate()

	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	g.window = glfw.CreateWindow(1024, 768, "Hello Vulkan", nil, nil)
	if g.window == nil do return
	defer glfw.DestroyWindow(g.window)

	vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))
	log.assert(vk.CreateInstance != nil, "Failed to load Vulkan API")

	create_instance()
	defer destroy_instance()

	vk_check(glfw.CreateWindowSurface(g.instance, g.window, nil, &g.surface))
	defer vk.DestroySurfaceKHR(g.instance, g.surface, nil)

	create_device()
	defer destroy_device()

	create_swapchain()
	defer destroy_swapchain()

	for !glfw.WindowShouldClose(g.window) {
		free_all(context.temp_allocator)
		glfw.PollEvents()
	}
}

create_instance :: proc() {
	layers := []cstring {
		"VK_LAYER_KHRONOS_validation"
	}
	extensions := slice.concatenate([][]cstring {
		glfw.GetRequiredInstanceExtensions(),
		{vk.EXT_DEBUG_UTILS_EXTENSION_NAME},
	}, context.temp_allocator)

	debug_messenger_ci := vk.DebugUtilsMessengerCreateInfoEXT {
		sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		messageSeverity = {.WARNING, .ERROR},
		messageType = {.VALIDATION, .PERFORMANCE},
		pfnUserCallback = proc "system" (messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT, messageTypes: vk.DebugUtilsMessageTypeFlagsEXT, pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT, pUserData: rawptr) -> b32 {
			context = g.odin_context
			context.logger.options = {.Level, .Terminal_Color}
			level: log.Level
			if .ERROR in messageSeverity do level = .Error
			else if .WARNING in messageSeverity do level = .Warning
			else if .INFO in messageSeverity do level = .Info
			else do level = .Debug
			log.log(level, pCallbackData.pMessage)
			return false
		}
	}

	next: rawptr
	next = &debug_messenger_ci

	instance_ci := vk.InstanceCreateInfo {
		sType = .INSTANCE_CREATE_INFO,
		pApplicationInfo = &{
			sType = .APPLICATION_INFO,
			apiVersion = vk.API_VERSION_1_3,
		},
		enabledLayerCount = u32(len(layers)),
		ppEnabledLayerNames = raw_data(layers),
		enabledExtensionCount = u32(len(extensions)),
		ppEnabledExtensionNames = raw_data(extensions),
		pNext = next,
	}
	vk_check(vk.CreateInstance(&instance_ci, nil, &g.instance))

	vk.load_proc_addresses_instance(g.instance)
	log.assert(vk.DestroyInstance != nil, "Failed to load Vulkan instance API")

	vk_check(vk.CreateDebugUtilsMessengerEXT(g.instance, &debug_messenger_ci, nil, &g.debug_messenger))
}

destroy_instance :: proc() {
	vk.DestroyDebugUtilsMessengerEXT(g.instance, g.debug_messenger, nil)
	vk.DestroyInstance(g.instance, nil)
}

create_device :: proc() {
	physical_device_count: u32
	vk_check(vk.EnumeratePhysicalDevices(g.instance, &physical_device_count, nil))
	log.assert(physical_device_count > 0, "No GPUs found!")
	physical_devices := make([]vk.PhysicalDevice, physical_device_count, context.temp_allocator)
	vk_check(vk.EnumeratePhysicalDevices(g.instance, &physical_device_count, raw_data(physical_devices)))

	device_loop: for candidate in physical_devices {
		queue_family_count: u32
		vk.GetPhysicalDeviceQueueFamilyProperties(candidate, &queue_family_count, nil)
		queue_families := make([]vk.QueueFamilyProperties, queue_family_count, context.temp_allocator)
		vk.GetPhysicalDeviceQueueFamilyProperties(candidate, &queue_family_count, raw_data(queue_families))

		for family, i in queue_families {
			supports_graphics := .GRAPHICS in family.queueFlags
			supports_present: b32
			vk_check(vk.GetPhysicalDeviceSurfaceSupportKHR(candidate, u32(i), g.surface, &supports_present))

			if supports_graphics && supports_present {
				g.physical_device = candidate
				g.queue_family_index = u32(i)
				break device_loop
			}
		}
	}
	log.assert(g.physical_device != nil, "No suitable GPU found!")

	queue_priority := f32(1)
	queue_create_infos := []vk.DeviceQueueCreateInfo {
		{
			sType = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = g.queue_family_index,
			queueCount = 1,
			pQueuePriorities = &queue_priority,
		}
	}

	extensions := []cstring {
		vk.KHR_SWAPCHAIN_EXTENSION_NAME,
	}

	device_ci := vk.DeviceCreateInfo {
		sType = .DEVICE_CREATE_INFO,
		queueCreateInfoCount = u32(len(queue_create_infos)),
		pQueueCreateInfos = raw_data(queue_create_infos),
		enabledExtensionCount = u32(len(extensions)),
		ppEnabledExtensionNames = raw_data(extensions),
	}
	vk_check(vk.CreateDevice(g.physical_device, &device_ci, nil, &g.device))

	vk.load_proc_addresses_device(g.device)
	log.assert(vk.BeginCommandBuffer != nil, "Failed to load Vulkan device API")

	vk.GetDeviceQueue(g.device, g.queue_family_index, 0, &g.queue)
}

destroy_device :: proc() {
	vk.DestroyDevice(g.device, nil)
}

create_swapchain :: proc() {
	surface_caps: vk.SurfaceCapabilitiesKHR
	vk_check(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(g.physical_device, g.surface, &surface_caps))

	image_count: u32 = max(3, surface_caps.minImageCount)
	if surface_caps.maxImageCount != 0 do image_count = min(image_count, surface_caps.maxImageCount)

	surface_format_count: u32
	vk_check(vk.GetPhysicalDeviceSurfaceFormatsKHR(g.physical_device, g.surface, &surface_format_count, nil))
	surface_formats := make([]vk.SurfaceFormatKHR, surface_format_count, context.temp_allocator)
	vk_check(vk.GetPhysicalDeviceSurfaceFormatsKHR(g.physical_device, g.surface, &surface_format_count, raw_data(surface_formats)))

	surface_format := surface_formats[0]
	for candidate in surface_formats {
		if candidate == {.B8G8R8A8_SRGB, .SRGB_NONLINEAR} {
			surface_format = candidate
			break
		}
	}

	width, height := glfw.GetFramebufferSize(g.window)

	swapchain_ci := vk.SwapchainCreateInfoKHR {
		sType = .SWAPCHAIN_CREATE_INFO_KHR,
		surface = g.surface,
		minImageCount = image_count,
		imageFormat = surface_format.format,
		imageColorSpace = surface_format.colorSpace,
		imageExtent = {u32(width), u32(height)},
		imageArrayLayers = 1,
		imageUsage = {.COLOR_ATTACHMENT},
		preTransform = surface_caps.currentTransform,
		compositeAlpha = {.OPAQUE},
		presentMode = .MAILBOX,
		clipped = true,
	}
	vk_check(vk.CreateSwapchainKHR(g.device, &swapchain_ci, nil, &g.swapchain))
}

destroy_swapchain :: proc() {
	vk.DestroySwapchainKHR(g.device, g.swapchain, nil)
}

vk_check :: proc(result: vk.Result, location := #caller_location) {
	if result != .SUCCESS do log.panicf("Vulkan Failure: {}", result, location = location)
}

