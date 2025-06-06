package main

import "base:runtime"
import "core:log"
import "core:slice"
import "vendor:glfw"
import vk "vendor:vulkan"

NUM_FRAMES_IN_FLIGHT :: 2
NUM_SWAPCHAIN_IMAGES :: 3

Per_Frame_Data :: struct {
	fence: vk.Fence,
	acquire_semaphore: vk.Semaphore,
	command_pool: vk.CommandPool,
	command_buffer: vk.CommandBuffer,
}

Swapchain :: struct {
	handle: vk.SwapchainKHR,
	width, height: u32,
	images: []vk.Image,
	image_views: []vk.ImageView,
	present_semaphores: []vk.Semaphore,
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
	per_frame: [NUM_FRAMES_IN_FLIGHT]Per_Frame_Data,
	frame_index: u8,
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

	create_frames()
	defer destroy_frames()

	for !glfw.WindowShouldClose(g.window) {
		free_all(context.temp_allocator)
		glfw.PollEvents()

		frame := g.per_frame[g.frame_index]

		vk_check(vk.WaitForFences(g.device, 1, &frame.fence, true, max(u64)))
		vk_check(vk.ResetFences(g.device, 1, &frame.fence))

		image_index: u32
		// TODO: handle SUBOPTIMAL_KHR and ERROR_OUT_OF_DATE_KHR
		vk_check(vk.AcquireNextImageKHR(g.device, g.swapchain.handle, max(u64), frame.acquire_semaphore, 0, &image_index))

		present_semaphore := g.swapchain.present_semaphores[image_index]

		vk_check(vk.ResetCommandPool(g.device, frame.command_pool, {}))

		cmd := frame.command_buffer

		begin_info := vk.CommandBufferBeginInfo {
			sType = .COMMAND_BUFFER_BEGIN_INFO,
			flags = {.ONE_TIME_SUBMIT},
		}
		vk_check(vk.BeginCommandBuffer(cmd, &begin_info))

		transition_to_color_attachment_barrier := vk.ImageMemoryBarrier2 {
			sType = .IMAGE_MEMORY_BARRIER_2,
			image = g.swapchain.images[image_index],
			subresourceRange = {
				aspectMask = {.COLOR},
				levelCount = 1,
				layerCount = 1,
			},
			oldLayout = .UNDEFINED,
			newLayout = .COLOR_ATTACHMENT_OPTIMAL,
			srcStageMask = {.ALL_COMMANDS},
			srcAccessMask = {.MEMORY_READ},
			dstStageMask = {.COLOR_ATTACHMENT_OUTPUT},
			dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
		}
		vk.CmdPipelineBarrier2(cmd, &vk.DependencyInfo {
			sType = .DEPENDENCY_INFO,
			imageMemoryBarrierCount = 1,
			pImageMemoryBarriers = &transition_to_color_attachment_barrier,
		})

		color_attachment := vk.RenderingAttachmentInfo {
			sType = .RENDERING_ATTACHMENT_INFO,
			imageView = g.swapchain.image_views[image_index],
			imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
			loadOp = .CLEAR,
			storeOp = .STORE,
			clearValue = {
				color = { float32 = { 1, 0, 0, 1 } }
			}
		}
		rendering_info := vk.RenderingInfo {
			sType = .RENDERING_INFO,
			renderArea = {
				offset = { 0, 0 },
				extent = { g.swapchain.width, g.swapchain.height }
			},
			layerCount = 1,
			colorAttachmentCount = 1,
			pColorAttachments = &color_attachment,
		}
		vk.CmdBeginRendering(cmd, &rendering_info)

		// draw stuff

		vk.CmdEndRendering(cmd)

		transition_to_present_src_barrier := vk.ImageMemoryBarrier2 {
			sType = .IMAGE_MEMORY_BARRIER_2,
			image = g.swapchain.images[image_index],
			subresourceRange = {
				aspectMask = {.COLOR},
				levelCount = 1,
				layerCount = 1,
			},
			oldLayout = .COLOR_ATTACHMENT_OPTIMAL,
			newLayout = .PRESENT_SRC_KHR,
			srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
			srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
			dstStageMask = {},
			dstAccessMask = {},
		}
		vk.CmdPipelineBarrier2(cmd, &vk.DependencyInfo {
			sType = .DEPENDENCY_INFO,
			imageMemoryBarrierCount = 1,
			pImageMemoryBarriers = &transition_to_present_src_barrier,
		})

		vk_check(vk.EndCommandBuffer(cmd))

		wait_stage_flags := vk.PipelineStageFlags { .COLOR_ATTACHMENT_OUTPUT }
		submit_info := vk.SubmitInfo {
			sType = .SUBMIT_INFO,
			waitSemaphoreCount = 1,
			pWaitSemaphores = &frame.acquire_semaphore,
			pWaitDstStageMask = &wait_stage_flags,
			commandBufferCount = 1,
			pCommandBuffers = &cmd,
			signalSemaphoreCount = 1,
			pSignalSemaphores = &present_semaphore,
		}
		vk_check(vk.QueueSubmit(g.queue, 1, &submit_info, frame.fence))

		present_info := vk.PresentInfoKHR {
			sType = .PRESENT_INFO_KHR,
			waitSemaphoreCount = 1,
			pWaitSemaphores = &present_semaphore,
			swapchainCount = 1,
			pSwapchains = &g.swapchain.handle,
			pImageIndices = &image_index,
		}
		// TODO: handle SUBOPTIMAL_KHR and ERROR_OUT_OF_DATE_KHR
		vk_check(vk.QueuePresentKHR(g.queue, &present_info))

		g.frame_index = (g.frame_index + 1) % NUM_FRAMES_IN_FLIGHT
	}

	vk_check(vk.DeviceWaitIdle(g.device))
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

	next: rawptr

	next = &vk.PhysicalDeviceVulkan13Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		pNext = next,
		dynamicRendering = true,
		synchronization2 = true,
	}

	device_ci := vk.DeviceCreateInfo {
		sType = .DEVICE_CREATE_INFO,
		pNext = next,
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

	image_count: u32 = max(NUM_SWAPCHAIN_IMAGES, surface_caps.minImageCount)
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
	g.swapchain.width, g.swapchain.height = u32(width), u32(height)

	swapchain_ci := vk.SwapchainCreateInfoKHR {
		sType = .SWAPCHAIN_CREATE_INFO_KHR,
		surface = g.surface,
		minImageCount = image_count,
		imageFormat = surface_format.format,
		imageColorSpace = surface_format.colorSpace,
		imageExtent = {g.swapchain.width, g.swapchain.height},
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

	g.swapchain.image_views = make([]vk.ImageView, image_count, context.allocator)
	for image, i in g.swapchain.images {
		image_ci := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = image,
			viewType = .D2,
			format = surface_format.format,
			subresourceRange = {
				aspectMask = {.COLOR},
				levelCount = 1,
				layerCount = 1,
			}
		}
		vk_check(vk.CreateImageView(g.device, &image_ci, nil, &g.swapchain.image_views[i]))
	}

	g.swapchain.present_semaphores = make([]vk.Semaphore, image_count, context.allocator)

	semaphore_ci := vk.SemaphoreCreateInfo { sType = .SEMAPHORE_CREATE_INFO }
	for &semaphore in g.swapchain.present_semaphores {
		vk_check(vk.CreateSemaphore(g.device, &semaphore_ci, nil, &semaphore))
	}
}

destroy_swapchain :: proc() {
	delete(g.swapchain.images)
	for semaphore in g.swapchain.present_semaphores do vk.DestroySemaphore(g.device, semaphore, nil)
	delete(g.swapchain.present_semaphores)
	for image_view in g.swapchain.image_views do vk.DestroyImageView(g.device, image_view, nil)
	delete(g.swapchain.image_views)
	vk.DestroySwapchainKHR(g.device, g.swapchain.handle, nil)
}

create_frames :: proc() {
	for &frame in g.per_frame {
		command_pool_ci := vk.CommandPoolCreateInfo {
			sType = .COMMAND_POOL_CREATE_INFO,
			queueFamilyIndex = g.queue_family_index,
			flags = {.TRANSIENT}
		}
		vk_check(vk.CreateCommandPool(g.device, &command_pool_ci, nil, &frame.command_pool))

		command_buffer_ai := vk.CommandBufferAllocateInfo {
			sType = .COMMAND_BUFFER_ALLOCATE_INFO,
			commandPool = frame.command_pool,
			level = .PRIMARY,
			commandBufferCount = 1,
		}
		vk_check(vk.AllocateCommandBuffers(g.device, &command_buffer_ai, &frame.command_buffer))

		semaphore_ci := vk.SemaphoreCreateInfo { sType = .SEMAPHORE_CREATE_INFO }
		vk_check(vk.CreateSemaphore(g.device, &semaphore_ci, nil, &frame.acquire_semaphore))

		fence_ci := vk.FenceCreateInfo {
			sType = .FENCE_CREATE_INFO,
			flags = {.SIGNALED}
		}
		vk_check(vk.CreateFence(g.device, &fence_ci, nil, &frame.fence))
	}
}

destroy_frames :: proc() {
	for frame in g.per_frame {
		vk.DestroyCommandPool(g.device, frame.command_pool, nil)
		vk.DestroySemaphore(g.device, frame.acquire_semaphore, nil)
		vk.DestroyFence(g.device, frame.fence, nil)
	}
}

vk_check :: proc(result: vk.Result, location := #caller_location) {
	if result != .SUCCESS do log.panicf("Vulkan Failure: {}", result, location = location)
}

