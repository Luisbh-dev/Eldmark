class_name MinimapTerrain
extends ColorRect
## El terreno del [Minimap] (UI-52): el trozo de la imagen cenital horneada que rodea al jugador, dentro de
## un disco, dibujado con un shader de CanvasItem. Resuelve dos defectos del dibujo anterior:
## [br]- [b]Franjas estiradas.[/b] Cuando el jugador se acerca a un límite de la imagen, la mitad del disco cae fuera
## de ella y la textura (sin repetición) estiraba su último píxel en franjas. Aquí las coordenadas de textura se
## limitan a la imagen y el terreno se funde a un color de niebla ([constant FOG_COLOR]) en los últimos
## [constant FADE_METERS] metros antes del borde y vale niebla pura fuera de él.
## [br]- [b]Moteado.[/b] La imagen (1024 px para 320 m) se reduce unas 2,5 a 5 veces según el zoom. El shader la
## muestrea con [code]filter_linear_mipmap[/code] (la importación de [code]vado_gris.png[/code] genera mipmaps), así
## que los árboles dejan de ser lunares sueltos.
## [br][br]
## El disco tiene el borde suavizado en el propio shader, sin polígonos ni máscaras. No dibuja iconos, el aro ni el
## cono: eso lo hace el [Minimap] encima. Solo cliente.

## Color de la niebla donde acaba la imagen del mapa.
const FOG_COLOR: Color = Color(0.2, 0.225, 0.25, 1.0)
## Metros antes del borde de la imagen en los que el terreno empieza a fundirse con la niebla.
const FADE_METERS: float = 14.0
## Anchura (fracción del radio) del suavizado del borde del disco.
const DISC_EDGE: float = 0.025
## Anchura (fracción del radio) y fuerza de la niebla que apaga el terreno hacia el aro del minimapa.
const RIM_FADE: float = 0.2
const RIM_STRENGTH: float = 0.55

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

void fragment() {
	vec2 p = UV * 2.0 - vec2(1.0);
	vec2 uv = center_uv + p * half_uv;
	// 0 en el borde de la imagen, 1 a fade_uv hacia dentro y negativo fuera de ella.
	vec2 edge = min(uv, vec2(1.0) - uv) / fade_uv;
	float keep = smoothstep(0.0, 1.0, min(edge.x, edge.y));
	vec3 terrain = texture(map_tex, clamp(uv, vec2(0.0), vec2(1.0))).rgb;
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
	# Detrás de lo que dibuja el minimapa (aro, iconos y cono).
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
	material = _material


## Pone el mapa que se dibuja ([param map] con su imagen [param texture]). Con null en cualquiera de los dos, el
## terreno se oculta.
func set_map(map: ZoneMapDefinition, texture: Texture2D) -> void:
	_map = map
	_material.set_shader_parameter(&"map_tex", texture)
	if map != null:
		_material.set_shader_parameter(&"fade_uv", fade_uv_for(map))
	if map == null or texture == null:
		visible = false


## Centra el disco en [param player] con [param visible_meters] m de lado a lado (el zoom del minimapa).
func set_view(player: Vector3, visible_meters: float) -> void:
	if _map == null or _material.get_shader_parameter(&"map_tex") == null:
		visible = false
		return
	_material.set_shader_parameter(&"center_uv", _map.world_to_uv(player))
	_material.set_shader_parameter(&"half_uv", half_uv_for(_map, visible_meters))
	visible = true


## Coordenadas de textura (UV) del centro del disco ahora (para las pruebas).
func get_center_uv() -> Vector2:
	return _material.get_shader_parameter(&"center_uv") as Vector2


## Medio lado del disco, en UV, ahora (para las pruebas).
func get_half_uv() -> Vector2:
	return _material.get_shader_parameter(&"half_uv") as Vector2


## Material del terreno (para las pruebas).
func get_terrain_material() -> ShaderMaterial:
	return _material


## Medio lado, en UV, de un disco de [param visible_meters] m de diámetro sobre [param map].
static func half_uv_for(map: ZoneMapDefinition, visible_meters: float) -> Vector2:
	return Vector2(visible_meters * 0.5 / map.world_size.x, visible_meters * 0.5 / map.world_size.y)


## Anchura del fundido, en UV, sobre [param map] ([constant FADE_METERS] m).
static func fade_uv_for(map: ZoneMapDefinition) -> Vector2:
	return Vector2(FADE_METERS / map.world_size.x, FADE_METERS / map.world_size.y)


## Cuánto del terreno (1) frente a la niebla (0) se ve en la coordenada de textura [param uv]: la misma cuenta que el
## shader. 1 a [param fade_uv] o más hacia dentro de la imagen, 0 en su borde y fuera de ella.
static func terrain_weight(uv: Vector2, fade_uv: Vector2) -> float:
	var edge: Vector2 = Vector2(minf(uv.x, 1.0 - uv.x) / fade_uv.x, minf(uv.y, 1.0 - uv.y) / fade_uv.y)
	return smoothstep(0.0, 1.0, minf(edge.x, edge.y))
