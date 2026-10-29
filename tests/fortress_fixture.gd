class_name FortressFixture
extends RefCounted
## Fortaleza de pruebas para el servidor del fuerte (paquete F3): sobre la zona plana de [ZoneFixture]
## añade un nodo de fortaleza con el mismo reparto que el del Vado Gris (círculo de 5 m, marcador del
## capitán y la puerta de verdad) pero con tiempos cortos, y los puntos de reaparición de los campamentos y
## del interior del fuerte, en el mismo orden que la zona real (campamentos primero).
## [br][br]
## El fuerte está en [constant ORIGIN]; la puerta, en el plano x = ORIGIN.x - 20 con el interior hacia +X.

## Id de la fortaleza de pruebas.
const FORTRESS_ID: StringName = &"test_fort"
## Escena de la puerta.
const GATE_SCENE: String = "res://scenes/world/props/fort/fort_gate.tscn"
## Origen del nodo de la fortaleza (en el suelo plano de [ZoneFixture], lejos de sus puntos de aparición).
const ORIGIN: Vector3 = Vector3(100.0, 0.0, 0.0)
## Posiciones locales del círculo (radio 5), del capitán y de la puerta.
const CIRCLE_LOCAL: Vector3 = Vector3(-8.5, 0.05, 0.0)
const CAPTAIN_LOCAL: Vector3 = Vector3(-6.0, 0.05, 4.0)
const GATE_LOCAL: Vector3 = Vector3(-20.0, 0.0, 0.0)
## Campamentos de los reinos (los de [ZoneFixture]) y puntos del interior del fuerte (locales).
const VARDHEIM_CAMP: Vector3 = Vector3(-20.0, 0.0, 0.0)
const SOLMARCH_CAMP: Vector3 = Vector3(20.0, 0.0, 0.0)
const INNER_POINTS_LOCAL: Array[Vector3] = [Vector3(11.0, 0.25, -6.0), Vector3(11.0, 0.25, -2.0)]


## Definición con tiempos cortos: captura de [param capture_seconds] con un atacante, consolidación de
## [param consolidation_seconds] y el resto de plazos de las pruebas. Sin reinicio periódico por defecto.
static func make_definition(capture_seconds: float = 2.0, consolidation_seconds: float = 2.0,
		reset_seconds: float = 0.0) -> FortressDefinition:
	var definition := FortressDefinition.new()
	definition.id = FORTRESS_ID
	definition.display_name = "Fuerte de pruebas"
	definition.capture_s = capture_seconds
	definition.decay_after_empty_s = 1.0
	definition.circle_height_m = 4.0
	definition.gate_health = 900
	definition.consolidation_s = consolidation_seconds
	definition.captain_respawn_s = 30.0
	definition.guard_respawn_s = 10.0
	definition.under_attack_s = 5.0
	definition.gate_repair_after_s = 20.0
	definition.reset_to_neutral_s = reset_seconds
	return definition


## Añade a [param world] (que debe estar en el árbol) la fortaleza con [param definition] y devuelve su
## nodo. La puerta es la escena real, cerrada y neutral.
static func add_fortress(world: Node3D, definition: FortressDefinition) -> Node3D:
	var fort := Node3D.new()
	fort.name = "Fuerte"
	world.add_child(fort)
	fort.position = ORIGIN
	fort.add_to_group(&"fortresses")
	fort.set_meta(&"definition", definition)
	var circle := Marker3D.new()
	circle.name = "CaptureCircle"
	fort.add_child(circle)
	circle.position = CIRCLE_LOCAL
	circle.set_meta(&"radius", 5.0)
	circle.add_to_group(&"capture_points")
	var captain := Marker3D.new()
	captain.name = "CaptainSpawn"
	fort.add_child(captain)
	captain.position = CAPTAIN_LOCAL
	var gate: FortGate = (load(GATE_SCENE) as PackedScene).instantiate() as FortGate
	gate.name = "FortGate"
	fort.add_child(gate)
	gate.position = GATE_LOCAL
	return fort


## Añade los puntos de reaparición: un campamento por reino (con el metadato de reino) y los del interior
## del fuerte (con el metadato de fortaleza), en ese orden. Los índices: 0 Vardheim, 1 Solmarch, 2 y 3 el
## fuerte.
static func add_respawn_points(world: Node3D) -> void:
	_add_respawn(world, "CampamentoVardheim", VARDHEIM_CAMP, {&"realm": &"vardheim"})
	_add_respawn(world, "CampamentoSolmarch", SOLMARCH_CAMP, {&"realm": &"solmarch"})
	for i: int in INNER_POINTS_LOCAL.size():
		_add_respawn(world, "FuerteInterior%d" % i, ORIGIN + INNER_POINTS_LOCAL[i],
				{&"fortress": FORTRESS_ID})


## Posición mundial del centro del círculo.
static func circle_center() -> Vector3:
	return ORIGIN + CIRCLE_LOCAL


## Posición mundial de la puerta (centro del vano a ras de suelo).
static func gate_position() -> Vector3:
	return ORIGIN + GATE_LOCAL


static func _add_respawn(world: Node3D, marker_name: String, position: Vector3,
		meta: Dictionary) -> void:
	var marker := Marker3D.new()
	marker.name = marker_name
	world.add_child(marker)
	marker.position = position
	marker.add_to_group(&"respawn_points")
	for key: StringName in meta:
		marker.set_meta(key, meta[key])
