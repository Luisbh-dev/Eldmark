class_name NpcVisualProfile
extends RefCounted
## Perfil visual de un tipo de PNJ (ART-52, solo cliente): lo que lo distingue de un jugador a 20 m mientras llega el
## modelo definitivo de ART-16. Se elige por el arma de combate del PNJ ([code]npc_hollow[/code],
## [code]npc_captain[/code]...), que es lo que el visual ya sabe de él (la ve el remoto en su registro y el sandbox
## la pone en su estado), y lo aplica [method HumanoidVisual.apply_profile].
## [br][br]
## [b]Hueco[/b]: sin escudo, piel y ropa de hueso gris desaturado, ojos que brillan (emisivos) y el andar arrastrado de
## zombi ([ArmedStanceModifier.use_zombie_profile]). [b]Capitán del Vado[/b]: escala visual 1,25, hierro enrojecido y
## un arma mayor. La escala y el color son solo visuales: la cápsula y las cajas de golpe no cambian. El guardia y el
## Guardián de la Puerta no tienen perfil: se ven como un soldado con espada y escudo.

## Sombreado que recolorea la textura de un material del cuerpo: desatura hacia su luminancia ([code]saturation[/code])
## y la tiñe ([code]tint[/code]). Un color multiplicado no basta: un jubón verde multiplicado por gris sigue verde.
const RECOLOR_SHADER: String = """shader_type spatial;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 tint : source_color = vec4(1.0);
uniform float saturation = 1.0;
uniform float roughness_value = 0.85;
void fragment() {
	vec3 base = texture(albedo_tex, UV).rgb;
	float luminance = dot(base, vec3(0.299, 0.587, 0.114));
	ALBEDO = mix(vec3(luminance), base, saturation) * tint.rgb;
	ROUGHNESS = roughness_value;
}
"""

## Nombre del arma -> perfil (se crean una vez).
static var _profiles: Dictionary[StringName, NpcVisualProfile] = {}

## Identificador (el del arma de combate).
var id: StringName = &""
## Escala visual del modelo entero (1 = la del jugador).
var scale: float = 1.0
## Color por el que se multiplica el albedo de cada material del cuerpo (blanco = el suyo).
var tint: Color = Color.WHITE
## Saturación de la textura del cuerpo (1 = la suya, 0 = grises): con menos de 1 el color pasa por el sombreado de
## recoloreado ([constant RECOLOR_SHADER]) en lugar de multiplicarse.
var saturation: float = 1.0
## Brillo de los ojos: color y energía (0 = sin brillo).
var eye_glow: Color = Color.WHITE
var eye_energy: float = 0.0
## false: sin escudo en el brazo izquierdo.
var shield: bool = true
## Escala del arma de la mano derecha (1 = la normal).
var weapon_scale: float = 1.0
## Postura del reposo y la locomoción: [code]shield[/code] (guardia con escudo) o [code]zombie[/code].
var stance: StringName = &"shield"


## Perfil del PNJ cuya arma de combate se llama [param weapon_name], o null si ese PNJ (o un jugador) no tiene.
static func for_weapon(weapon_name: StringName) -> NpcVisualProfile:
	if _profiles.is_empty():
		_build()
	return _profiles.get(weapon_name)


## Perfil del PNJ de [param weapon_id] (id del catálogo de combate) o null.
static func for_weapon_id(weapon_id: int) -> NpcVisualProfile:
	var weapon: WeaponTicks = CombatCatalog.weapon(weapon_id)
	return for_weapon(weapon.name) if weapon != null else null


## true si el perfil cambia el aspecto (escala, color, ojos o escudo) respecto al de un jugador.
func changes_look() -> bool:
	return scale != 1.0 or tint != Color.WHITE or saturation != 1.0 or eye_energy > 0.0 or not shield or weapon_scale != 1.0


static func _build() -> void:
	var hollow := NpcVisualProfile.new()
	hollow.id = &"npc_hollow"
	hollow.saturation = 0.15
	hollow.tint = Color(1.95, 1.97, 1.82)
	hollow.eye_glow = Color(0.45, 1.0, 0.78)
	hollow.eye_energy = 3.5
	hollow.shield = false
	hollow.stance = &"zombie"
	_profiles[hollow.id] = hollow
	var captain := NpcVisualProfile.new()
	captain.id = &"npc_captain"
	captain.scale = 1.25
	captain.saturation = 0.4
	captain.tint = Color(1.45, 0.78, 0.65)
	captain.weapon_scale = 1.3
	_profiles[captain.id] = captain
