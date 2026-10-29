extends TestCase
## Los golpes avisados que recuerda un bot del cliente ([BotThreatSight], F6b): cada TELEGRAPH es un
## [BotBrain.Threat] con el origen, el giro y el alcance del aviso, activo hasta su impacto más la ventana activa
## del golpe; el mismo PNJ sustituye su aviso anterior y su DESPAWN lo olvida. Los demás eventos no cuentan.


func _telegraph(npc_id: int, tick: int, origin: Vector3, yaw: float, radius_cm: int,
		impact_in: int) -> NetMessages.EntityEvent:
	return NetMessages.EntityEvent.telegraph(npc_id, tick, 7, NetMessages.EntityEvent.SHAPE_SECTOR, origin, yaw,
			radius_cm, impact_in)


func test_a_telegraph_is_a_threat_until_its_impact_and_active_window() -> void:
	var sight := BotThreatSight.new()
	sight.note(_telegraph(40, 1000, Vector3(1.0, 2.0, 3.0), PI, 350, 60))
	var found: Array[BotBrain.Threat] = sight.find(1000)
	if not assert_eq(found.size(), 1, "activo desde el aviso"):
		return
	assert_vec_near(found[0].origin, Vector3(1.0, 2.0, 3.0), 0.001, "con el origen del aviso")
	assert_near(found[0].yaw, PI, 0.001, "su giro")
	assert_near(found[0].radius, 3.5, 0.001, "y su alcance en metros")
	var last: int = 1000 + 60 + BotThreatSight.ACTIVE_TICKS
	assert_eq(sight.find(last).size(), 1, "sigue hasta el impacto más la ventana activa")
	assert_eq(sight.find(last + 1).size(), 0, "y después ya no")
	assert_eq(sight.size(), 0, "lo olvida al pasar")


func test_the_same_npc_replaces_its_warning_and_a_despawn_forgets_it() -> void:
	var sight := BotThreatSight.new()
	sight.note(_telegraph(40, 1000, Vector3.ZERO, 0.0, 350, 60))
	sight.note(_telegraph(41, 1010, Vector3(5.0, 0.0, 0.0), 0.0, 260, 30))
	assert_eq(sight.find(1020).size(), 2, "dos PNJ, dos golpes")
	sight.note(_telegraph(40, 1100, Vector3(9.0, 0.0, 0.0), 1.0, 350, 60))
	var found: Array[BotBrain.Threat] = sight.find(1100)
	assert_eq(found.size(), 1, "el otro ya ha pasado y el primero tiene uno nuevo")
	assert_vec_near(found[0].origin, Vector3(9.0, 0.0, 0.0), 0.001, "el nuevo sustituye al anterior")
	sight.forget(40)
	assert_eq(sight.find(1100).size(), 0, "su DESPAWN lo olvida")


func test_other_events_are_ignored() -> void:
	var sight := BotThreatSight.new()
	sight.note(NetMessages.EntityEvent.hit(5, 1000, 6, 90, 0, 0, 3))
	sight.note(NetMessages.EntityEvent.war(5, 1000, WarEvents.GATE_BROKEN, 1))
	sight.note(null)
	assert_eq(sight.find(1000).size(), 0)
