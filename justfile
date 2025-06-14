run: build
	./hello-vulkan.exe

build: build-shaders
	odin build src -out:hello-vulkan.exe -debug

build-shaders:
	glslc -o shaders/shader.vert.spv -fshader-stage=vert shaders/shader.vert.glsl
	glslc -o shaders/shader.frag.spv -fshader-stage=frag shaders/shader.frag.glsl
