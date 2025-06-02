package main

import "base:runtime"
import "core:log"
import "vendor:glfw"
import vk "vendor:vulkan"

Globals :: struct {
	odin_context: runtime.Context,
	window: glfw.WindowHandle,
	instance: vk.Instance,
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

	g.window = glfw.CreateWindow(1024, 768, "Hello Vulkan", nil, nil)
	if g.window == nil do return
	defer glfw.DestroyWindow(g.window)

	vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))
	log.assert(vk.CreateInstance != nil, "Failed to load Vulkan API")

	create_instance()
	vk.load_proc_addresses_instance(g.instance)
	log.assert(vk.DestroyInstance != nil, "Failed to load Vulkan instance API")
	defer vk.DestroyInstance(g.instance, nil)

	for !glfw.WindowShouldClose(g.window) {
		free_all(context.temp_allocator)
		glfw.PollEvents()
	}
}

create_instance :: proc() {
	layers := []cstring {}
	extensions := []cstring {}

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
	}
	vk_check(vk.CreateInstance(&instance_ci, nil, &g.instance))
}

vk_check :: proc(result: vk.Result, location := #caller_location) {
	if result != .SUCCESS do log.panicf("Vulkan Failure: {}", result, location = location)
}

