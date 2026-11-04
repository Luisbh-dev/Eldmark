extends TestCase
## Tests for [SiegeView] (docs/fortress.md, section 7): what the siege bots see of a fort,
## filled from a [FortressState] (server) or from the OBJECT_STATE fields (clients).

const DEFINITION_PATH: String = "res://data/fortresses/vado_gris.tres"
const VARDHEIM: int = 1
const SOLMARCH: int = 2

var _def: FortressDefinition = null


func before_each() -> void:
	_def = load(DEFINITION_PATH) as FortressDefinition


func test_an_unknown_fort_is_neutral_whole_and_closed_to_everyone() -> void:
	var view := SiegeView.new()
	assert_false(view.known)
	assert_eq(view.owner, 0)
	assert_false(view.is_gate_broken(), "with no data it is not assumed broken")
	assert_true(view.is_gate_closed_for(VARDHEIM))
	assert_true(view.is_gate_closed_for(SOLMARCH))
	assert_true(view.can_damage_gate(VARDHEIM))
	assert_false(view.is_circle_active())
	assert_true(view.should_attack(VARDHEIM))
	assert_false(view.should_defend(VARDHEIM))
	assert_false(view.should_defend(0), "the Hollow do not defend like a realm")
	assert_near(view.gate_health_fraction(), 1.0, 0.0001)


func test_it_follows_the_fortress_state() -> void:
	var state: FortressState = FortressState.initial(_def, 0)
	var view := SiegeView.new()
	view.set_places(Vector3(-20, 10.2, 0), Vector3(-8.5, 10.25, 0), 5.0)
	view.update_from_state(state)
	assert_true(view.known)
	assert_eq(view.gate_max, 9000)
	assert_eq(view.gate_position, Vector3(-20, 10.2, 0))
	# The owner changes.
	state.owner = VARDHEIM
	view.update_from_state(state)
	assert_true(view.should_defend(VARDHEIM))
	assert_false(view.should_attack(VARDHEIM))
	assert_true(view.should_attack(SOLMARCH))
	assert_false(view.is_gate_closed_for(VARDHEIM), "its own door does not block its way")
	assert_true(view.is_gate_closed_for(SOLMARCH), "but it does block the enemy")
	assert_false(view.can_damage_gate(VARDHEIM))
	# The door takes damage and breaks.
	state.on_gate_damaged(10, 4500, SOLMARCH)
	view.update_from_state(state)
	assert_near(view.gate_health_fraction(), 0.5, 0.0001)
	assert_true(view.is_gate_closed_for(SOLMARCH))
	state.on_gate_damaged(20, 9000, SOLMARCH)
	view.update_from_state(state)
	assert_true(view.is_gate_broken())
	assert_false(view.is_gate_closed_for(SOLMARCH), "broken, it lets through")
	assert_false(view.can_damage_gate(SOLMARCH))
	assert_near(view.gate_health_fraction(), 0.0, 0.0001)


func test_the_circle_and_the_capture_phases() -> void:
	var state: FortressState = FortressState.initial(_def, 0)
	var view := SiegeView.new()
	view.update_from_state(state)
	assert_false(view.is_circle_active(), "with the captain alive, not")
	state.on_captain_died(10, SOLMARCH)
	view.update_from_state(state)
	assert_true(view.is_circle_active(), "VULNERABLE")
	assert_false(view.is_capturing(SOLMARCH))
	state.advance(_def, 11, PackedInt32Array([0, 0, 2, 0]))
	view.update_from_state(state)
	assert_true(view.is_circle_active(), "CAPTURING")
	assert_true(view.is_capturing(SOLMARCH))
	assert_false(view.is_capturing(VARDHEIM))
	assert_eq(view.capture_realm, SOLMARCH)
	state.advance(_def, 12, PackedInt32Array([0, 1, 2, 0]))
	view.update_from_state(state)
	assert_true(view.contested)


func test_it_can_be_filled_from_object_state_fields() -> void:
	var view := SiegeView.new()
	view.update_from_fields({
		FortressFields.OWNER: 2, FortressFields.PHASE: FortressState.Phase.CAPTURING,
		FortressFields.CAPTURE_REALM: 1, FortressFields.GATE_HEALTH: 3000, FortressFields.GATE_MAX: 9000,
		FortressFields.CONTESTED: 1, FortressFields.PHASE_TICK: 77, 99: 5,
	})
	assert_true(view.known)
	assert_eq(view.owner, SOLMARCH)
	assert_true(view.is_capturing(VARDHEIM))
	assert_true(view.contested)
	assert_near(view.gate_health_fraction(), 1.0 / 3.0, 0.0001)
	# A partial update only touches what it carries.
	view.update_from_fields({FortressFields.GATE_HEALTH: 0})
	assert_true(view.is_gate_broken())
	assert_eq(view.owner, SOLMARCH, "the owner is kept")


func test_is_in_circle_is_horizontal() -> void:
	var view := SiegeView.new()
	view.set_places(Vector3.ZERO, Vector3(-8.5, 10.25, 0.0), 5.0)
	assert_true(view.is_in_circle(Vector3(-8.5, 10.25, 0.0)))
	assert_true(view.is_in_circle(Vector3(-13.5, 99.0, 0.0)), "height does not count here")
	assert_false(view.is_in_circle(Vector3(-13.6, 10.25, 0.0)))


func test_places_can_come_from_the_approach_routes() -> void:
	var routes := ApproachRoutes.new()
	var view := SiegeView.new()
	assert_false(routes.has_places(), "routes without a fort do not say where it is")
	assert_false(view.set_places_from_routes(routes), "and change nothing")
	assert_eq(view.circle_radius, 0.0)
	assert_false(view.set_places_from_routes(null), "without routes neither")
	routes.gate_point = Vector2(-20.0, 0.0)
	routes.circle_point = Vector2(-8.5, 1.5)
	routes.circle_radius = 5.0
	assert_true(routes.has_places())
	assert_true(view.set_places_from_routes(routes, 10.2))
	assert_eq(view.gate_position, Vector3(-20.0, 10.2, 0.0), "the door, at whatever height is given")
	assert_eq(view.circle_center, Vector3(-8.5, 10.2, 1.5))
	assert_eq(view.circle_radius, 5.0)
	var shipped: ApproachRoutes = load("res://data/routes/vado_gris.tres") as ApproachRoutes
	assert_true(shipped.has_places(), "the Vado Gris routes carry the fort")
	assert_eq(shipped.enclosure_size, Vector2(40.0, 40.0), "and its 40 x 40 m enclosure (F6b)")


func test_the_enclosure_says_whether_a_point_is_inside_the_palisade() -> void:
	var view := SiegeView.new()
	view.set_places(Vector3(-20.0, 10.2, 0.0), Vector3(-8.5, 10.2, 0.0), 5.0)
	assert_eq(view.is_inside_enclosure(Vector3(-8.5, 10.2, 0.0)), -1, "without the enclosure's size it is not known")
	var routes := ApproachRoutes.new()
	routes.gate_point = Vector2(-20.0, 0.0)
	routes.circle_point = Vector2(-8.5, 0.0)
	routes.circle_radius = 5.0
	routes.enclosure_size = Vector2(40.0, 40.0)
	assert_true(view.set_places_from_routes(routes, 10.2))
	assert_eq(view.enclosure_size, Vector2(40.0, 40.0), "the routes carry the enclosure")
	assert_eq(view.is_inside_enclosure(Vector3(-8.5, 0.0, 0.0)), 1, "the circle, inside")
	assert_eq(view.is_inside_enclosure(Vector3(19.0, 0.0, -19.0)), 1, "a corner at the back, inside")
	assert_eq(view.is_inside_enclosure(Vector3(-22.0, 0.0, 0.0)), 0, "the esplanade, outside")
	assert_eq(view.is_inside_enclosure(Vector3(-7.0, 0.0, 20.7)), 0, "pressed against the south wall from outside")
	assert_eq(view.is_inside_enclosure(Vector3(21.0, 0.0, 0.0)), 0, "behind the back wall")
	assert_eq(view.is_inside_enclosure(Vector3(-7.0, 0.0, 19.8), 0.5), 0, "with slack, the inner edge does not count")
	# With the door on another wall (to the south, facing -Z) the enclosure rotates with it.
	view.set_places(Vector3(0.0, 0.0, 20.0), Vector3(0.0, 0.0, 8.5), 5.0)
	assert_eq(view.is_inside_enclosure(Vector3(19.0, 0.0, -19.0)), 1)
	assert_eq(view.is_inside_enclosure(Vector3(0.0, 0.0, 22.0)), 0)
	assert_eq(view.is_inside_enclosure(Vector3(21.0, 0.0, 0.0)), 0)
