class_name SiegeView
extends RefCounted
## What a bot needs to know about a fort in order to besiege it (docs/fuerte.md, section 7):
## owner, phase, capturer, gate health and where the gate and the circle are. Pure and without
## nodes, so all bots share it:
## [br]- the server fills it with the fort's [FortressState] for the fake players
## ([code]--fake-players[/code], [method update_from_state]);
## [br]- the client fills it with what it knows about the fort for [code]--bot[/code]: with
## [code]FortressView[/code] or, in bots that do not simulate ([code]SwarmBot[/code]), by decoding
## OBJECT_STATE by hand ([method update_from_fields] with the [FortressFields] fields).
## [br][br]
## While no state has been received ([member known] is false), the fort is considered neutral,
## intact and with no capture, and the queries give the answer for a fort with no owner.
## [br][br]
## Shared: depends on neither the client nor the server.

## Id of the fort.
var fortress_id: StringName = &""
## true if it has been filled with some state.
var known: bool = false
## Owner (network code; 0 = neutral).
var owner: int = 0
## Phase ([enum FortressState.Phase]).
var phase: int = FortressState.Phase.GARRISONED
## Realm that is capturing (0 if nobody).
var capture_realm: int = 0
## Current and maximum health of the gate.
var gate_health: int = 0
var gate_max: int = 0
## true if the capture is contested.
var contested: bool = false
## Where the gate (the center of the opening, at ground level) and the capture circle (center and
## radius) are.
var gate_position: Vector3 = Vector3.ZERO
var circle_center: Vector3 = Vector3.ZERO
var circle_radius: float = 0.0
## Size of the enclosure measured from the gate (depth toward the circle, width), like
## [member ApproachRoutes.enclosure_size]; (0, 0) = unknown.
var enclosure_size: Vector2 = Vector2.ZERO


## Where the gate and the circle are (from the scene's markers).
func set_places(p_gate_position: Vector3, p_circle_center: Vector3, p_circle_radius: float) -> void:
	gate_position = p_gate_position
	circle_center = p_circle_center
	circle_radius = p_circle_radius


## Where the gate and the circle are according to the zone's routes
## ([member ApproachRoutes.gate_point]...), for bots that do not load the scene. The points are
## horizontal: the height is set to [param ground_height]. Returns false (and changes nothing) if
## the routes do not know.
func set_places_from_routes(routes: ApproachRoutes, ground_height: float = 0.0) -> bool:
	if routes == null or not routes.has_places():
		return false
	set_places(Vector3(routes.gate_point.x, ground_height, routes.gate_point.y),
			Vector3(routes.circle_point.x, ground_height, routes.circle_point.y), routes.circle_radius)
	enclosure_size = routes.enclosure_size
	return true


## Whether [param position] is inside the enclosure (with [param margin] meters of slack inward
## from each wall): 1 yes, 0 no and -1 if unknown (without [member enclosure_size] or without gate
## and circle positions). The enclosure is the rectangle that starts at the gate's wall, extends
## toward the circle [code]enclosure_size.x[/code] meters and is [code]enclosure_size.y[/code] wide
## with the gate in the middle.
func is_inside_enclosure(position: Vector3, margin: float = 0.0) -> int:
	var inward := Vector3(circle_center.x - gate_position.x, 0.0, circle_center.z - gate_position.z)
	if enclosure_size.x <= 0.0 or enclosure_size.y <= 0.0 or inward.length_squared() < 0.0001:
		return -1
	inward = inward.normalized()
	var offset := Vector3(position.x - gate_position.x, 0.0, position.z - gate_position.z)
	var along: float = offset.dot(inward)
	var lateral: float = absf(offset.dot(Vector3(-inward.z, 0.0, inward.x)))
	var inside: bool = along > margin and along < enclosure_size.x - margin \
			and lateral < enclosure_size.y * 0.5 - margin
	return 1 if inside else 0


## Copies from the fort's state what a bot is interested in.
func update_from_state(state: FortressState) -> void:
	known = true
	owner = state.owner
	phase = state.phase
	capture_realm = state.capture_realm
	gate_health = state.gate_health
	gate_max = state.gate_max
	contested = state.contested


## Applies the fields of an OBJECT_STATE ([param fields]: [FortressFields] id -> value). Fields it
## is not interested in, or unknown ones, are ignored.
func update_from_fields(fields: Dictionary) -> void:
	known = true
	for field_id: int in fields:
		var value: int = int(fields[field_id])
		match field_id:
			FortressFields.OWNER:
				owner = value
			FortressFields.PHASE:
				phase = value
			FortressFields.CAPTURE_REALM:
				capture_realm = value
			FortressFields.GATE_HEALTH:
				gate_health = value
			FortressFields.GATE_MAX:
				gate_max = value
			FortressFields.CONTESTED:
				contested = value != 0


## true if the gate is broken (health 0 in a known fort).
func is_gate_broken() -> bool:
	return known and gate_health <= 0


## Gate health from 0 to 1 (1 if not yet known).
func gate_health_fraction() -> float:
	if not known or gate_max <= 0:
		return 1.0
	return clampf(float(gate_health) / float(gate_max), 0.0, 1.0)


## true if the gate blocks the way for [param realm]: intact and of another owner (with a neutral
## fort, for all realms). It must be broken by blows or one must wait for someone else to break it.
func is_gate_closed_for(realm: int) -> bool:
	return not is_gate_broken() and owner != realm


## true if [param realm] can damage the gate: it is intact and not its own.
func can_damage_gate(realm: int) -> bool:
	return is_gate_closed_for(realm)


## true if the capture circle is active (the captain has fallen and the fort is not consolidating).
func is_circle_active() -> bool:
	return phase == FortressState.Phase.VULNERABLE or phase == FortressState.Phase.CAPTURING


## true if [param realm] is the owner: it is its job to defend the walkway and the circle.
func should_defend(realm: int) -> bool:
	return owner == realm and realm != RealmCatalog.NEUTRAL_CODE


## true if [param realm] is among those besieging: the fort is not its own.
func should_attack(realm: int) -> bool:
	return owner != realm


## true if [param realm] is capturing right now.
func is_capturing(realm: int) -> bool:
	return phase == FortressState.Phase.CAPTURING and capture_realm == realm


## true if [param position] is inside the circle horizontally (the height is checked by the
## server).
func is_in_circle(position: Vector3) -> bool:
	var offset := Vector2(position.x - circle_center.x, position.z - circle_center.z)
	return offset.length() <= circle_radius
