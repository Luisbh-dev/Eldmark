class_name MinimapTerrain
extends ColorRect
## Terrain of the [Minimap] (UI-52): the piece of the baked top-down image around the player, inside a
## disc, drawn with a CanvasItem shader. It fixes two defects of the earlier drawing:
## [br]- [b]Stretched stripes.[/b] When the player gets close to an edge of the image, half of the disc falls outside
## it and the texture (non-repeating) stretched its last pixel into stripes. Here the texture coordinates are
## clamped to the image and the terrain fades to a fog color ([constant FOG_COLOR]) over the last
## [constant FADE_METERS] meters before the edge, and is pure fog beyond it.
## [br]- [b]Speckle.[/b] The image (1024 px for 320 m) is downscaled about 2.5 to 5 times depending on the zoom. The shader
## samples it with [code]filter_linear_mipmap[/code] (the import of [code]vado_gris.png[/code] generates mipmaps), so
## trees stop being isolated dots.
## [br][br]
## The disc has its edge smoothed in the shader itself, with no polygons or masks. It does not draw icons, the ring or the
## cone: [Minimap] does that on top. Client only.

## Fog color where the map image ends.
const FOG_COLOR: Color = Color(0.2, 0.225, 0.25, 1.0)
## Meters before the image edge over which the terrain starts to blend into the fog.
const FADE_METERS: float = 14.0
## Width (fraction of the radius) of the disc edge smoothing.
const DISC_EDGE: float = 0.025
## Width (fraction of the radius) and strength of the fog that dims the terrain toward the minimap ring.
const RIM_FADE: float = 0.2
const RIM_STRENGTH: float = 0.55
## Extra contrast for the small disc (quality decision 3: the same layers with more contrast than the map window): a curve
## around [constant CONTRAST_PIVOT], more saturation and a vivid tint where the paint is bluish (the river).
const CONTRAST: float = 1.45
const CONTRAST_PIVOT: float = 0.42
const SATURATION: float = 1.5
const WATER_TINT: Color = Color(0.16, 0.46, 0.80, 1.0)
const WATER_STRENGTH: float = 0.75

const _SHADER_CODE: String = """
shader_type canvas_item;

uniform sampler2D map_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform vec2 center_uv = vec2(0.5);
uniform vec2 half_uv = vec2(0.25);
uniform vec2 fade_uv = vec2(0.04);
uniform vec4 fog_color : source_color = vec4(0.2, 0.225, 0.25, 1.0);
uniform float disc_edge = 0.025;
uniform float rim_fade = 0.2;
uniform float rim_strength = 0.55;
uniform float contrast = 1.45;
uniform float contrast_pivot = 0.42;
uniform float saturation = 1.5;
uniform vec4 water_tint : source_color = vec4(0.16, 0.46, 0.8, 1.0);
uniform float water_strength = 0.75;

void fragment() {
	vec2 p = UV * 2.0 - vec2(1.0);
	vec2 uv = center_uv + p * half_uv;
	// 0 en el borde de la imagen, 1 a fade_uv hacia dentro y negativo fuera de ella.
	vec2 edge = min(uv, vec2(1.0) - uv) / fade_uv;
	float keep = smoothstep(0.0, 1.0, min(edge.x, edge.y));
	vec3 terrain = texture(map_tex, clamp(uv, vec2(0.0), vec2(1.0))).rgb;
	float luma = dot(terrain, vec3(0.299, 0.587, 0.114));
	float bluish = smoothstep(0.015, 0.07, terrain.b - terrain.r);
	terrain = mix(vec3(luma), terrain, saturation);
	terrain = (terrain - vec3(contrast_pivot)) * contrast + vec3(contrast_pivot);
	terrain = mix(terrain, water_tint.rgb * (0.65 + 0.7 * luma), bluish * water_strength);
	terrain = clamp(terrain, vec3(0.0), vec3(1.0));
	float disc = 1.0 - smoothstep(1.0 - disc_edge, 1.0, length(p));
	// Niebla en el borde del círculo (UI-52): el terreno se apaga hacia el aro y deja de verse el corte.
	float rim = smoothstep(1.0 - rim_fade, 1.0, length(p)) * rim_strength;
	vec3 shown = mix(terrain, fog_color.rgb, rim);
	COLOR = vec4(mix(fog_color.rgb, shown, keep), disc);
}
"""

static var _shared_shader: Shader = null

var _material: ShaderMaterial = null
var _map: ZoneMapDefinition = null


func _init() -> void:
	name = "Terreno"
	color = Color.WHITE
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Behind what the minimap draws (ring, icons and cone).
	show_behind_parent = true
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	visible = false
	if _shared_shader == null:
		_shared_shader = Shader.new()
		_shared_shader.code = _SHADER_CODE
	_material = ShaderMaterial.new()
	_material.shader = _shared_shader
	_material.set_shader_parameter(&"fog_color", FOG_COLOR)
	_material.set_shader_parameter(&"disc_edge", DISC_EDGE)
	_material.set_shader_parameter(&"rim_fade", RIM_FADE)
	_material.set_shader_parameter(&"rim_strength", RIM_STRENGTH)
	_material.set_shader_parameter(&"contrast", CONTRAST)
	_material.set_shader_parameter(&"contrast_pivot", CONTRAST_PIVOT)
	_material.set_shader_parameter(&"saturation", SATURATION)
	_material.set_shader_parameter(&"water_tint", WATER_TINT)
	_material.set_shader_parameter(&"water_strength", WATER_STRENGTH)
	material = _material


## Sets the map being drawn ([param map] with its image [param texture]). If either is null, the
## terrain is hidden.
func set_map(map: ZoneMapDefinition, texture: Texture2D) -> void:
	_map = map
	_material.set_shader_parameter(&"map_tex", texture)
	if map != null:
		_material.set_shader_parameter(&"fade_uv", fade_uv_for(map))
	if map == null or texture == null:
		visible = false


## Centers the disc on [param player] with [param visible_meters] m from side to side (the minimap zoom).
func set_view(player: Vector3, visible_meters: float) -> void:
	if _map == null or _material.get_shader_parameter(&"map_tex") == null:
		visible = false
		return
	_material.set_shader_parameter(&"center_uv", _map.world_to_uv(player))
	_material.set_shader_parameter(&"half_uv", half_uv_for(_map, visible_meters))
	visible = true


## Texture coordinates (UV) of the disc center right now (for tests).
func get_center_uv() -> Vector2:
	return _material.get_shader_parameter(&"center_uv") as Vector2


## Half the side of the disc, in UV, right now (for tests).
func get_half_uv() -> Vector2:
	return _material.get_shader_parameter(&"half_uv") as Vector2


## Terrain material (for tests).
func get_terrain_material() -> ShaderMaterial:
	return _material


## Half the side, in UV, of a disc [param visible_meters] m in diameter over [param map].
static func half_uv_for(map: ZoneMapDefinition, visible_meters: float) -> Vector2:
	return Vector2(visible_meters * 0.5 / map.world_size.x, visible_meters * 0.5 / map.world_size.y)


## Width of the fade, in UV, over [param map] ([constant FADE_METERS] m).
static func fade_uv_for(map: ZoneMapDefinition) -> Vector2:
	return Vector2(FADE_METERS / map.world_size.x, FADE_METERS / map.world_size.y)


## How much of the terrain (1) versus the fog (0) is visible at texture coordinate [param uv]: the same computation as
## the shader. 1 at [param fade_uv] or more inside the image, 0 at its edge and outside it.
static func terrain_weight(uv: Vector2, fade_uv: Vector2) -> float:
	var edge: Vector2 = Vector2(minf(uv.x, 1.0 - uv.x) / fade_uv.x, minf(uv.y, 1.0 - uv.y) / fade_uv.y)
	return smoothstep(0.0, 1.0, minf(edge.x, edge.y))
