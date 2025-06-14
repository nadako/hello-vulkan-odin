#version 450

void main() {
	vec3 position;

	if (gl_VertexIndex == 0)      position = vec3(-0.5, -0.5, 0);
	else if (gl_VertexIndex == 1) position = vec3( 0,    0.5, 0);
	else if (gl_VertexIndex == 2) position = vec3( 0.5, -0.5, 0);

	gl_Position = vec4(position, 1);
}
