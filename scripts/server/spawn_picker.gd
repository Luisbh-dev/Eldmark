class_name SpawnPicker
extends RefCounted
## Elige dónde aparece cada jugador que entra en la zona (docs/red.md, sección 1.5).
## [br][br]
## Los puntos son los nodos del grupo [constant Zones.SPAWN_GROUP] de la escena de la zona; los que
## llevan el metadato [constant Zones.REALM_META] son de ese reino. [method pick] reparte los
## puntos de cada reino en rueda, para que los jugadores que llegan juntos no aparezcan apilados.
## Si el reino no tiene puntos se usa cualquiera de la zona y, si la zona no tiene ninguno, el
## origen; en los dos casos con un aviso (una sola vez por reino).

var _world: Node
# Siguiente índice de la rueda de cada reino (código de reino -> índice). Un reino sin puntos
# propios rueda por todos los de la zona con su propio índice.
var _cursors: Dictionary[int, int] = {}
# Avisos ya emitidos, para no llenar el registro con cada jugador que entra.
var _warned: Dictionary[String, bool] = {}


## [param world] es la raíz de la escena de la zona, que debe estar en el árbol cuando se llame a
## [method pick].
func _init(world: Node) -> void:
	_world = world


## Punto de aparición para un jugador de [param realm] (un código de [enum NetProtocol.Realm]):
## el siguiente de la rueda de ese reino. La posición es la del punto y la base solo tiene su
## yaw (hacia donde mira el punto).
func pick(realm: int) -> Transform3D:
	var points: Array[Node3D] = []
	var realm_name: StringName = NetZones.realm_name(realm)
	if not realm_name.is_empty():
		points = Zones.get_spawn_points(_world, realm_name)
	if points.is_empty():
		points = Zones.get_spawn_points(_world)
		if not points.is_empty():
			_warn_once("realm_%d" % realm,
					"La zona no tiene puntos de aparición de %s; se usa cualquiera"
					% NetProtocol.realm_display_name(realm))
	if points.is_empty():
		_warn_once("origin", "La zona no tiene nodos en el grupo '%s'; se aparece en el origen"
				% Zones.SPAWN_GROUP)
		return Transform3D.IDENTITY
	var cursor: int = _cursors.get(realm, 0)
	var index: int = cursor % points.size()
	_cursors[realm] = index + 1
	return _transform_of(points[index])


# Posición del punto y base con su yaw (la misma fórmula que ClientMain._yaw_from_basis).
static func _transform_of(point: Node3D) -> Transform3D:
	var forward: Vector3 = -point.global_transform.basis.z
	var yaw: float = atan2(-forward.x, -forward.z)
	return Transform3D(Basis(Vector3.UP, yaw), point.global_position)


func _warn_once(key: String, message: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	push_warning("[Eldmark] %s" % message)
