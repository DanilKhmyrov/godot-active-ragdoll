shader_type spatial;
// Grey ground with a 1 m grid (and a stronger 5 m one) in world space — easy to judge how far a body flew.

uniform vec3 base_color : source_color = vec3(0.42, 0.43, 0.45);
uniform vec3 line_color : source_color = vec3(0.3, 0.31, 0.33);

varying vec3 world_pos;
varying vec3 world_n;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_n = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
}

float grid(vec2 p, float cell, float width) {
	vec2 g = abs(fract(p / cell - 0.5) - 0.5) * cell;
	vec2 fw = fwidth(p);
	vec2 l = 1.0 - smoothstep(vec2(width) - fw, vec2(width) + fw, g);
	return max(l.x, l.y);
}

void fragment() {
	vec3 n = normalize(world_n);
	vec2 p = abs(n.y) > 0.5 ? world_pos.xz : (abs(n.x) > 0.5 ? world_pos.zy : world_pos.xy);
	float l = max(grid(p, 1.0, 0.01) * 0.6, grid(p, 5.0, 0.02));
	ALBEDO = mix(base_color, line_color, l);
	ROUGHNESS = 0.9;
}
