run: build
	./hello-vulkan.exe

build:
	odin build src -out:hello-vulkan.exe -debug
