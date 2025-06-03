package main

import "base:runtime"
import "core:log"
import "core:slice"
import "vendor:glfw"
import vk "vendor:vulkan"

Swapchain :: struct {
	handle: vk.SwapchainKHR,
	images: []vk.Image,
	image_ready_semaphores: []vk.Semaphore,
}

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
	swapchain: Swapchain,
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

	acquire_semaphore: vk.Semaphore
	semaphore_ci := vk.SemaphoreCreateInfo { sType = .SEMAPHORE_CREATE_INFO }
	vk_check(vk.CreateSemaphore(g.device, &semaphore_ci, nil, &acquire_semaphore))

	frame_fence: vk.Fence
	fence_ci := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED}
	}
	vk_check(vk.CreateFence(g.device, &fence_ci, nil, &frame_fence))

	for !glfw.WindowShouldClose(g.window) {
		free_all(context.temp_allocator)
		glfw.PollEvents()

		vk_check(vk.WaitForFences(g.device, 1, &frame_fence, true, max(u64)))
		vk_check(vk.ResetFences(g.device, 1, &frame_fence))

		image_index: u32
		// TODO: handle SUBOPTIMAL_KHR and ERROR_OUT_OF_DATE_KHR
		vk_check(vk.AcquireNextImageKHR(g.device, g.swapchain.handle, max(u64), acquire_semaphore, 0, &image_index))

		release_semaphore := g.swapchain.image_ready_semaphores[image_index]

		wait_stage_flags := vk.PipelineStageFlags { .COLOR_ATTACHMENT_OUTPUT }
		submit_info := vk.SubmitInfo {
			sType = .SUBMIT_INFO,
			waitSemaphoreCount = 1,
			pWaitSemaphores = &acquire_semaphore,
			pWaitDstStageMask = &wait_stage_flags,
			signalSemaphoreCount = 1,
			pSignalSemaphores = &release_semaphore,
		}
		vk_check(vk.QueueSubmit(g.queue, 1, &submit_info, frame_fence))

		present_info := vk.PresentInfoKHR {
			sType = .PRESENT_INFO_KHR,
			waitSemaphoreCount = 1,
			pWaitSemaphores = &release_semaphore,
			swapchainCount = 1,
			pSwapchains = &g.swapchain.handle,
			pImageIndices = &image_index,
		}
		// TODO: handle SUBOPTIMAL_KHR and ERROR_OUT_OF_DATE_KHR
		vk_check(vk.QueuePresentKHR(g.queue, &present_info))
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

	present_mode_count: u32
	vk_check(vk.GetPhysicalDeviceSurfacePresentModesKHR(g.physical_device, g.surface, &present_mode_count, nil))
	present_modes := make([]vk.PresentModeKHR, present_mode_count, context.temp_allocator)
	vk_check(vk.GetPhysicalDeviceSurfacePresentModesKHR(g.physical_device, g.surface, &present_mode_count, raw_data(present_modes)))

	present_mode := vk.PresentModeKHR.FIFO
	for candidate in present_modes {
		if candidate == .MAILBOX {
			present_mode = candidate
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
		presentMode = present_mode,
		clipped = true,
	}
	vk_check(vk.CreateSwapchainKHR(g.device, &swapchain_ci, nil, &g.swapchain.handle))

	vk_check(vk.GetSwapchainImagesKHR(g.device, g.swapchain.handle, &image_count, nil))
	g.swapchain.images = make([]vk.Image, image_count, context.allocator)
	vk_check(vk.GetSwapchainImagesKHR(g.device, g.swapchain.handle, &image_count, raw_data(g.swapchain.images)))

	g.swapchain.image_ready_semaphores = make([]vk.Semaphore, image_count, context.allocator)

	semaphore_ci := vk.SemaphoreCreateInfo { sType = .SEMAPHORE_CREATE_INFO }
	for &semaphore in g.swapchain.image_ready_semaphores {
		vk_check(vk.CreateSemaphore(g.device, &semaphore_ci, nil, &semaphore))
	}
}

destroy_swapchain :: proc() {
	delete(g.swapchain.images)
	for semaphore in g.swapchain.image_ready_semaphores do vk.DestroySemaphore(g.device, semaphore, nil)
	delete(g.swapchain.image_ready_semaphores)
	vk.DestroySwapchainKHR(g.device, g.swapchain.handle, nil)
}

vk_check :: proc(result: vk.Result, location := #caller_location) {
	if result != .SUCCESS do log.panicf("Vulkan Failure: {}", result, location = location)
}

