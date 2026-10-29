class_name CorrectionSmoother
extends RefCounted
## Suaviza las correcciones de la reconciliación (docs/red.md, sección 6.6).
##
## El cuerpo del personaje se corrige de golpe, porque manda la colisión del servidor. Lo que ve
## el jugador no: el error (posición vieja menos posición nueva, en coordenadas del mundo) se
## guarda aquí como desfase y se aplica a los nodos locales que dibujan al personaje
## ([code]Visual[/code] y [code]CameraTarget[/code], nunca [code]Collision[/code]). Como el desfase
## está en el mundo y esos nodos cuelgan del personaje, cada tick se recalcula en espacio local,
## porque el yaw cambia:
## [code]target.position = base_position + character.basis.inverse() * offset[/code].
## [br][br]
## El desfase decae en cada tick de física con una semivida de [constant HALF_LIFE_TICKS] ticks y se
## anula por debajo de [constant MIN_OFFSET]. Se escribe dentro del tick de física, así que la
## interpolación de física lo interpola como todo lo demás y no hace falta
## [code]reset_physics_interpolation()[/code].
## [br][br]
## [b]Orden dentro del tick.[/b] El desfase que añade [method add_offset] (la corrección de este
## tick) no decae hasta el siguiente [method physics_step]: en el tick de la corrección el cuerpo
## salta del punto viejo al nuevo y el desfase pasa de 0 a «viejo menos nuevo», así que la posición
## visible no salta; después converge sin tirones.

## Semivida del desfase (ticks).
const HALF_LIFE_TICKS: float = 6.0
## Por debajo de esta longitud (m) el desfase se anula.
const MIN_OFFSET: float = 0.001

var _character: PlayerCharacter = null
var _targets: Array[Node3D] = []
var _bases: PackedVector3Array = PackedVector3Array()
## Desfase (mundo) que ya se ha aplicado en algún [method physics_step].
var _offset: Vector3 = Vector3.ZERO
## Correcciones añadidas desde el último [method physics_step]: todavía no decaen.
var _pending: Vector3 = Vector3.ZERO
## true si los nodos están desplazados de su posición base.
var _applied: bool = false
var _decay_per_tick: float = pow(0.5, 1.0 / HALF_LIFE_TICKS)


## Guarda la posición local base de cada destino (por ejemplo, [code]Visual[/code] y
## [code]CameraTarget[/code]) y anula cualquier desfase.
func setup(character: PlayerCharacter, targets: Array[Node3D]) -> void:
	_character = character
	_targets.assign(targets)
	_bases = PackedVector3Array()
	for target: Node3D in _targets:
		_bases.append(target.position)
	_offset = Vector3.ZERO
	_pending = Vector3.ZERO
	_applied = false


## Suma [param world_offset] (error en coordenadas del mundo: posición vieja menos posición nueva)
## al desfase actual.
func add_offset(world_offset: Vector3) -> void:
	_pending += world_offset


## Anula el desfase y devuelve los nodos a su posición base (teletransporte, error de más de 3 m).
func clear() -> void:
	_offset = Vector3.ZERO
	_pending = Vector3.ZERO
	_apply()


## Dentro del tick de física: decae el desfase ya aplicado, le suma las correcciones nuevas y lo
## aplica a los destinos como [code]base + basis.inverse() * offset[/code].
func physics_step() -> void:
	_offset = _offset * _decay_per_tick + _pending
	_pending = Vector3.ZERO
	if _offset.length() < MIN_OFFSET:
		_offset = Vector3.ZERO
	_apply()


## Desfase actual en coordenadas del mundo, incluidas las correcciones aún no aplicadas.
func get_offset() -> Vector3:
	return _offset + _pending


func _apply() -> void:
	if _offset == Vector3.ZERO and not _applied:
		return
	if not is_instance_valid(_character):
		return
	var local_offset: Vector3 = _character.basis.inverse() * _offset
	for i: int in _targets.size():
		var target: Node3D = _targets[i]
		if is_instance_valid(target):
			target.position = _bases[i] + local_offset
	_applied = _offset != Vector3.ZERO
