class_name DustKick
extends VfxEffect
## Polvo del suelo al aterrizar o esquivar (ART-09, solo cliente).
## [br][br]
## El eje +Z del efecto es el suelo hacia arriba: el anillo de polvo y las bocanadas se abren alrededor
## de él. En una esquiva se suma la estela de polvo que levanta el pie hacia atrás
## ([method play_dodge]); en un aterrizaje solo el anillo ([method play_landing]). El color es el del
## suelo del reino ([method set_realm], [VfxPalette]).

## Aviso que lanza la estela de polvo hacia atrás de la esquiva.
const CUE_DODGE: StringName = &"dodge"

## Reino que decide el color del polvo ([VfxPalette]).
@export var realm: int = 0:
	set = set_realm


## Aterrizaje en [param position] (el suelo): anillo de polvo y bocanadas. [param strength] de 0 a 1 según
## la altura de la caída: con poca fuerza salen menos bocanadas y el anillo es más pequeño.
func play_landing(position: Vector3, strength: float = 1.0) -> void:
	_apply_strength(strength)
	play_at(position, Vector3.UP)


## Esquiva desde [param position] (el suelo) con el cuerpo yendo hacia [param move_direction]: lo anterior
## más una estela de polvo hacia atrás.
func play_dodge(position: Vector3, move_direction: Vector3, strength: float = 1.0) -> void:
	_apply_strength(strength)
	var back: Vector3 = -Vector3(move_direction.x, 0.0, move_direction.z)
	if back.length_squared() < 0.0001:
		back = Vector3.BACK
	# El eje +Z queda hacia arriba y el +Y hacia atrás: la estela sale por +Y.
	var facing: Basis = Basis.looking_at(Vector3.DOWN, back.normalized())
	global_transform = Transform3D(facing, position)
	play()
	trigger(CUE_DODGE)


## Colores por reino (ver [VfxPalette]).
func set_realm(value: int) -> void:
	realm = value
	tint = VfxPalette.dust(value)


func _apply_strength(strength: float) -> void:
	var amount: float = clampf(strength, 0.0, 1.0)
	var puffs: GPUParticles3D = get_node_or_null(^"Puffs") as GPUParticles3D
	if puffs != null:
		puffs.amount_ratio = lerpf(0.4, 1.0, amount)
	var ring: Node3D = get_node_or_null(^"Ring") as Node3D
	if ring != null:
		ring.scale = Vector3.ONE * lerpf(0.65, 1.15, amount)
