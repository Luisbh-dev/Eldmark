extends TestCase
## Pruebas de [SiegeView] (docs/fuerte.md, sección 7): lo que ven los bots de asedio de un fuerte,
## llenado desde un [FortressState] (servidor) o desde los campos de OBJECT_STATE (clientes).

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
	assert_false(view.is_gate_broken(), "sin datos no se da por rota")
	assert_true(view.is_gate_closed_for(VARDHEIM))
	assert_true(view.is_gate_closed_for(SOLMARCH))
	assert_true(view.can_damage_gate(VARDHEIM))
	assert_false(view.is_circle_active())
	assert_true(view.should_attack(VARDHEIM))
	assert_false(view.should_defend(VARDHEIM))
	assert_false(view.should_defend(0), "los Huecos no defienden como un reino")
	assert_near(view.gate_health_fraction(), 1.0, 0.0001)


func test_it_follows_the_fortress_state() -> void:
	var state: FortressState = FortressState.initial(_def, 0)
	var view := SiegeView.new()
	view.set_places(Vector3(-20, 10.2, 0), Vector3(-8.5, 10.25, 0), 5.0)
	view.update_from_state(state)
	assert_true(view.known)
	assert_eq(view.gate_max, 9000)
	assert_eq(view.gate_position, Vector3(-20, 10.2, 0))
	# El dueño cambia.
	state.owner = VARDHEIM
	view.update_from_state(state)
	assert_true(view.should_defend(VARDHEIM))
	assert_false(view.should_attack(VARDHEIM))
	assert_true(view.should_attack(SOLMARCH))
	assert_false(view.is_gate_closed_for(VARDHEIM), "su propia puerta no le cierra el paso")
	assert_true(view.is_gate_closed_for(SOLMARCH), "pero sí al enemigo")
	assert_false(view.can_damage_gate(VARDHEIM))
	# La puerta se daña y se rompe.
	state.on_gate_damaged(10, 4500, SOLMARCH)
	view.update_from_state(state)
	assert_near(view.gate_health_fraction(), 0.5, 0.0001)
	assert_true(view.is_gate_closed_for(SOLMARCH))
	state.on_gate_damaged(20, 9000, SOLMARCH)
	view.update_from_state(state)
	assert_true(view.is_gate_broken())
	assert_false(view.is_gate_closed_for(SOLMARCH), "rota deja pasar")
	assert_false(view.can_damage_gate(SOLMARCH))
	assert_near(view.gate_health_fraction(), 0.0, 0.0001)


func test_the_circle_and_the_capture_phases() -> void:
	var state: FortressState = FortressState.initial(_def, 0)
	var view := SiegeView.new()
	view.update_from_state(state)
	assert_false(view.is_circle_active(), "con el capitán vivo, no")
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
	# Una actualización parcial solo toca lo que trae.
	view.update_from_fields({FortressFields.GATE_HEALTH: 0})
	assert_true(view.is_gate_broken())
	assert_eq(view.owner, SOLMARCH, "el dueño se conserva")


func test_is_in_circle_is_horizontal() -> void:
	var view := SiegeView.new()
	view.set_places(Vector3.ZERO, Vector3(-8.5, 10.25, 0.0), 5.0)
	assert_true(view.is_in_circle(Vector3(-8.5, 10.25, 0.0)))
	assert_true(view.is_in_circle(Vector3(-13.5, 99.0, 0.0)), "la altura no cuenta aquí")
	assert_false(view.is_in_circle(Vector3(-13.6, 10.25, 0.0)))


func test_places_can_come_from_the_approach_routes() -> void:
	var routes := ApproachRoutes.new()
	var view := SiegeView.new()
	assert_false(routes.has_places(), "unas rutas sin fuerte no dicen dónde está")
	assert_false(view.set_places_from_routes(routes), "y no cambian nada")
	assert_eq(view.circle_radius, 0.0)
	assert_false(view.set_places_from_routes(null), "sin rutas tampoco")
	routes.gate_point = Vector2(-20.0, 0.0)
	routes.circle_point = Vector2(-8.5, 1.5)
	routes.circle_radius = 5.0
	assert_true(routes.has_places())
	assert_true(view.set_places_from_routes(routes, 10.2))
	assert_eq(view.gate_position, Vector3(-20.0, 10.2, 0.0), "la puerta, a la altura que se diga")
	assert_eq(view.circle_center, Vector3(-8.5, 10.2, 1.5))
	assert_eq(view.circle_radius, 5.0)
	var shipped: ApproachRoutes = load("res://data/routes/vado_gris.tres") as ApproachRoutes
	assert_true(shipped.has_places(), "las rutas del Vado Gris traen el fuerte")
