class_name DustKick
extends VfxEffect
## Polvo del suelo al aterrizar o esquivar (ART-09, solo cliente).
## [br][br]
## El eje +Z del efecto es el suelo hacia arriba. Un [b]aterrizaje[/b] ([method play_landing]) abre un
## anillo de bocanadas bajas alrededor de los pies y, solo en una caída fuerte, un anillo de polvo bajo
## de 1,2 m o menos que se deshace por el borde. Una [b]esquiva[/b] ([method play_dodge]) es otra cosa: una
## media luna de polvo pegada al suelo por detrás del cuerpo y una rociada de bocanadas hacia atrás, sin
## anillo. Las bocanadas tienen volumen y luz: lo que cae a la sombra se oscurece.
## [br][br]
## El color es el del [b]suelo[/b], no el del reino: [method set_ground] por material
## ([VfxPalette.ground]) o [method set_ground_color] (el que da [VfxGround] mirando el terreno).

## Aviso del aterrizaje: las bocanadas en anillo y el anillo bajo de las caídas fuertes.
const CUE_LANDING: StringName = &"landing"
## Aviso de la esquiva: la media luna y la rociada hacia atrás.
const CUE_DODGE: StringName = &"dodge"
## Fuerza (0 a 1) a partir de la cual el aterrizaje levanta además el anillo bajo.
const RING_MIN_STRENGTH: float = 0.7


## Aterrizaje en [param position] (el suelo): bocanadas en anillo. [param strength] de 0 a 1 según la altura
## de la caída: con poca fuerza salen menos bocanadas y no hay anillo.
func play_landing(position: Vector3, strength: float = 1.0) -> void:
	_apply_strength(strength)
	set_part_enabled(&"Ring", strength >= RING_MIN_STRENGTH)
	play_at(position, Vector3.UP)
	trigger(CUE_LANDING)


## Esquiva desde [param position] (el suelo) con el cuerpo yendo hacia [param move_direction]: una media
## luna de polvo y una rociada hacia atrás.
func play_dodge(position: Vector3, move_direction: Vector3, strength: float = 1.0) -> void:
	_apply_strength(strength)
	var back: Vector3 = -Vector3(move_direction.x, 0.0, move_direction.z)
	if back.length_squared() < 0.0001:
		back = Vector3.BACK
	# El eje +Z queda hacia arriba y el +Y hacia atrás: la media luna y la rociada salen por +Y.
	var facing: Basis = Basis.looking_at(Vector3.DOWN, back.normalized())
	global_transform = Transform3D(facing, position)
	play()
	trigger(CUE_DODGE)


## Color del polvo por material del suelo ([constant VfxPalette.GROUND_KINDS]).
func set_ground(kind: StringName) -> void:
	tint = VfxPalette.ground(kind)


## Color del polvo a mano (el del material pintado bajo los pies, ver [VfxGround]).
func set_ground_color(color: Color) -> void:
	tint = color


func _apply_strength(strength: float) -> void:
	var amount: float = clampf(strength, 0.0, 1.0)
	for part: StringName in [&"Puffs", &"Spray"]:
		var puffs: GPUParticles3D = get_node_or_null(NodePath(part)) as GPUParticles3D
		if puffs != null:
			puffs.amount_ratio = lerpf(0.45, 1.0, amount)
	var ring: Node3D = get_node_or_null(^"Ring") as Node3D
	if ring != null:
		ring.scale = Vector3.ONE * lerpf(0.7, 1.0, amount)
