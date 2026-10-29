class_name ZoneFixture
extends RefCounted
## Zona de prueba para las pruebas del servidor: un suelo plano de 400 x 400 m con tres puntos de
## aparición (dos de Vardheim y uno de Solmarch). El suelo es un [StaticBody3D] en la capa del
## mundo, así que sirve igual en un [SubViewport] con su propio mundo de física.

## Puntos de aparición de Vardheim y de Solmarch (en el suelo, mirando hacia -Z).
const VARDHEIM_SPAWNS: Array[Vector3] = [Vector3(-20.0, 0.0, 0.0), Vector3(-18.0, 0.0, 4.0)]
const SOLMARCH_SPAWN: Vector3 = Vector3(20.0, 0.0, 0.0)


## Crea la zona como hija de [param parent] (que debe estar en el árbol) y la devuelve.
static func build_flat_zone(parent: Node) -> Node3D:
	var world := Node3D.new()
	world.name = "ZonaDePrueba"
	parent.add_child(world)
	var floor_body := StaticBody3D.new()
	floor_body.name = "Suelo"
	floor_body.collision_layer = PlayerCharacter.WORLD_COLLISION_LAYER
	floor_body.collision_mask = 0
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400.0, 1.0, 400.0)
	floor_shape.shape = box
	floor_shape.position = Vector3(0.0, -0.5, 0.0)
	floor_body.add_child(floor_shape)
	world.add_child(floor_body)
	for i: int in VARDHEIM_SPAWNS.size():
		add_spawn(world, "Vardheim%d" % i, VARDHEIM_SPAWNS[i], &"vardheim")
	add_spawn(world, "Solmarch0", SOLMARCH_SPAWN, &"solmarch")
	return world


## Añade un punto de aparición del reino [param realm] a [param world].
static func add_spawn(world: Node3D, marker_name: String, position: Vector3,
		realm: StringName) -> Marker3D:
	var marker := Marker3D.new()
	marker.name = marker_name
	world.add_child(marker)
	marker.position = position
	marker.add_to_group(Zones.SPAWN_GROUP)
	marker.set_meta(Zones.REALM_META, realm)
	return marker
