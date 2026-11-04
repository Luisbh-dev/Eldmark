class_name FortressFixture
extends RefCounted
## Test fort for the fort server (package F3): on top of the flat zone of [ZoneFixture] it adds a
## fort node with the same layout as Vado Gris's (5 m circle, captain marker and the real gate) but
## with short timings, and the respawn points of the camps and of the fort interior, in the same
## order as the real zone (camps first).
## [br][br]
## The fort is at [constant ORIGIN]; the gate, on the plane x = ORIGIN.x - 20 with the interior
## toward +X.

## Id of the test fort.
const FORTRESS_ID: StringName = &"test_fort"
## Gate scene.
const GATE_SCENE: String = "res://scenes/world/props/fort/fort_gate.tscn"
## Origin of the fort node (on [ZoneFixture]'s flat ground, far from its spawn points).
const ORIGIN: Vector3 = Vector3(100.0, 0.0, 0.0)
## Local positions of the circle (radius 5), the captain and the gate.
const CIRCLE_LOCAL: Vector3 = Vector3(-8.5, 0.05, 0.0)
const CAPTAIN_LOCAL: Vector3 = Vector3(-6.0, 0.05, 4.0)
const GATE_LOCAL: Vector3 = Vector3(-20.0, 0.0, 0.0)
## Realm camps (those of [ZoneFixture]) and points inside the fort (local).
const VARDHEIM_CAMP: Vector3 = Vector3(-20.0, 0.0, 0.0)
const SOLMARCH_CAMP: Vector3 = Vector3(20.0, 0.0, 0.0)
const INNER_POINTS_LOCAL: Array[Vector3] = [Vector3(11.0, 0.25, -6.0), Vector3(11.0, 0.25, -2.0)]


## Definition with short timings: capture of [param capture_seconds] with one attacker,
## consolidation of [param consolidation_seconds] and the other test deadlines. No periodic reset
## by default.
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


## Adds to [param world] (which must be in the tree) the fort with [param definition] and returns
## its node. The gate is the real scene, closed and neutral.
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


## Adds the respawn points: one camp per realm (with the realm metadata) and those inside the fort
## (with the fort metadata), in that order. The indices: 0 Vardheim, 1 Solmarch, 2 and 3 the fort.
static func add_respawn_points(world: Node3D) -> void:
	_add_respawn(world, "CampamentoVardheim", VARDHEIM_CAMP, {&"realm": &"vardheim"})
	_add_respawn(world, "CampamentoSolmarch", SOLMARCH_CAMP, {&"realm": &"solmarch"})
	for i: int in INNER_POINTS_LOCAL.size():
		_add_respawn(world, "FuerteInterior%d" % i, ORIGIN + INNER_POINTS_LOCAL[i],
				{&"fortress": FORTRESS_ID})


## World position of the circle's center.
static func circle_center() -> Vector3:
	return ORIGIN + CIRCLE_LOCAL


## World position of the gate (center of the opening at ground level).
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


## Advances a [ZoneServer] by hand and quickly: on each Godot physics tick it calls its
## [code]_physics_process[/code] [member per_frame] times (the server already without its own
## processing), so it runs the ticks "inside" physics, with its delta, and a test of 20 s of game
## time takes a couple of seconds. For what depends on real movement (crossing the gate) the server
## is left to run at its own pace.
class Stepper:
	extends Node

	var server: ZoneServer = null
	var remaining: int = 0
	var per_frame: int = 40


	func _physics_process(delta: float) -> void:
		var count: int = mini(remaining, per_frame)
		for _i: int in count:
			server._physics_process(delta)
		remaining -= count
