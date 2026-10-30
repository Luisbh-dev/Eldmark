extends TestCase
## Pruebas del derribado (CMB-28; docs/habilidades.md, sección 4.5; paquete H3c) dentro del [ZoneServer]: el
## golpe mortal entre jugadores de dos reinos derriba, los tres desenlaces (levantado en 180 ticks con 300 de
## vida, rematado en 60 con la fuente del remate y KILL, desangrado en 1200 con el asesino que derribó), levantar
## cortado por daño a quien levanta y al derribado, no se remata a través de la puerta cerrada (y rota, sí), la
## puerta no se repara con un derribado en el vano, la baja de un derribado es antes su muerte (CLIENT_LEAVE con
## ENet, el falso que se va y el cuerpo de GUE-41) y al volver aparece en el campamento, la muerte directa contra
## un PNJ, el PNJ que prefiere al derribado y lo remata con daño, el comando 15 sin KILL y el descarte de los
## golpes del mismo tick. Revisión de H5: empezar a rematar quita la protección de reaparición (y así los
## aliados del derribado pueden cortarlo), y el remate se corta si el derribado se arrastra a su campamento.
## [br][br]
## Casi todo con jugadores falsos de guion sobre la zona plana de [ZoneFixture] (montaje de [NpcRig]), avanzados
## deprisa con su [FortressFixture.Stepper]; la salida, con clientes de verdad sobre ENet en 127.0.0.1.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const HUECOS: int = RealmCatalog.NEUTRAL_CODE
const HIT: int = NetMessages.EntityEvent.Kind.HIT
const DEATH: int = NetMessages.EntityEvent.Kind.DEATH
const KILL: int = NetMessages.EntityEvent.Kind.KILL
const DOWNED: int = NetMessages.EntityEvent.Kind.DOWNED
const INTERACT: int = NetMessages.EntityEvent.Kind.INTERACT
const OP_REVIVE: int = NetMessages.EntityEvent.InteractOp.REVIVE
const OP_REVIVE_CUT: int = NetMessages.EntityEvent.InteractOp.REVIVE_CUT
const OP_REVIVED: int = NetMessages.EntityEvent.InteractOp.REVIVED
const OP_EXECUTE: int = NetMessages.EntityEvent.InteractOp.EXECUTE
const OP_EXECUTE_CUT: int = NetMessages.EntityEvent.InteractOp.EXECUTE_CUT
const WAIT_FRAMES: int = 900

var _rig: NpcRig = null
# Lo de las pruebas con ENet.
var _server_viewport: SubViewport = null
var _client_viewports: Array[SubViewport] = []
var _net_server: ZoneServer = null


## Lo que hace un jugador falso cada tick: mira a [member look_yaw], se mueve con [member move] en
## [code][move_from, move_to)[/code] y mantiene cada botón de [member holds] en su intervalo.
class Plan:
	extends RefCounted

	var look_yaw: float = 0.0
	var move: Vector2 = Vector2.ZERO
	var move_from: int = -1
	var move_to: int = -1
	## (botón, desde, hasta) con el hasta exclusivo.
	var holds: Array[Vector3i] = []


	func hold(button: int, from_tick: int, to_tick: int) -> void:
		holds.append(Vector3i(button, from_tick, to_tick))


	func input_for(tick: int) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = look_yaw
		if tick >= move_from and tick < move_to:
			input.move = move
		for entry: Vector3i in holds:
			if tick >= entry.y and tick < entry.z:
				input.buttons |= entry.x
		return input


func before_each() -> void:
	_rig = NpcRig.new()


func after_each() -> void:
	if _rig != null:
		await _rig.stop()
	_rig = null
	for viewport: SubViewport in _client_viewports:
		if is_instance_valid(viewport):
			viewport.get_parent().remove_child(viewport)
			viewport.free()
	_client_viewports.clear()
	if is_instance_valid(_server_viewport):
		_server_viewport.get_parent().remove_child(_server_viewport)
		_server_viewport.free()
	_server_viewport = null
	_net_server = null
	await wait_process_frames()


# --- Ayudantes --------------------------------------------------------------------------------

func _server() -> ZoneServer:
	return _rig.server


func _combatant(net_id: int) -> Combatant:
	return _server().get_combat().get_combatant(net_id)


func _combat_of(net_id: int) -> CombatState:
	return _rig.character(net_id).combat


## Un jugador falso de [param realm] en [param position] mirando a [param yaw] que sigue [param plan].
func _scripted(realm: int, position: Vector3, yaw: float, plan: Plan) -> int:
	plan.look_yaw = yaw
	var brain := CombatFixture.ScriptBrain.new(1)
	brain.script_fn = func(tick: int, _position: Vector3, _yaw: float) -> PlayerInput:
		return plan.input_for(tick)
	return _rig.add_player(realm, position, brain, yaw)


func _events_of(kind: int, net_id: int = -1) -> Array[NetMessages.EntityEvent]:
	var found: Array[NetMessages.EntityEvent] = []
	for event: NetMessages.EntityEvent in _rig.events:
		if event.event == kind and (net_id < 0 or event.net_id == net_id):
			found.append(event)
	return found


func _light_id() -> int:
	return CombatCatalog.weapon(CombatCatalog.weapon_id(&"sword_shield")).light_ids[0]


## Avanza hasta el tick [param tick] del servidor (si no ha pasado ya).
func _advance_to(tick: int) -> void:
	var remaining: int = tick - _server().get_tick()
	if remaining > 0:
		await _rig.advance(remaining)


## El atacante de Vardheim en el origen mirando a -Z y la víctima de Solmarch 1,5 m delante, de cara, con 50 de
## vida: el ligero del atacante la derriba. Devuelve [code][atacante, víctima, tick del derribo][/code] y los
## planes en [param plans] (el del atacante y el de la víctima).
func _downed_pair(plans: Array[Plan] = []) -> Array[int]:
	var attacker_plan := Plan.new()
	var victim_plan := Plan.new()
	plans.append(attacker_plan)
	plans.append(victim_plan)
	var attacker: int = _scripted(VARDHEIM, Vector3(0.0, 0.05, 0.0), 0.0, attacker_plan)
	var victim: int = _scripted(SOLMARCH, Vector3(0.0, 0.05, -1.5), PI, victim_plan)
	_combatant(victim).health = 50
	var press: int = _server().get_tick() + 3
	attacker_plan.hold(PlayerInput.PRIMARY, press, press + 2)
	var downed: bool = await _rig.advance_until(func() -> bool: return _combatant(victim).is_downed(), 120, 2)
	assert_true(downed, "el ligero derriba a la víctima")
	var downs: Array[NetMessages.EntityEvent] = _events_of(DOWNED, victim)
	return [attacker, victim, downs[0].tick if not downs.is_empty() else -1]


# --- Caer -------------------------------------------------------------------------------------

func test_a_lethal_hit_between_two_realms_downs_the_player_instead_of_killing_it() -> void:
	await _rig.start_flat(tree)
	var plans: Array[Plan] = []
	var ids: Array[int] = await _downed_pair(plans)
	var attacker: int = ids[0]
	var victim: int = ids[1]
	var down_tick: int = ids[2]
	var combatant: Combatant = _combatant(victim)
	assert_true(combatant.is_downed())
	assert_false(combatant.is_alive(), "un derribado no está vivo")
	assert_false(combatant.is_dead(), "ni muerto")
	assert_eq(combatant.health, 0)
	assert_eq(combatant.downed_by, attacker)
	assert_eq(combatant.downed_source, _light_id())
	assert_eq(_combat_of(victim).action, CombatState.Action.DOWNED)
	var hits: Array[NetMessages.EntityEvent] = _events_of(HIT, victim)
	if assert_eq(hits.size(), 1, "un HIT"):
		assert_eq(hits[0].hit_flags, NetMessages.EntityEvent.HIT_FLAG_DOWNED, "con el bit 6 y sin el de mortal")
		assert_eq(hits[0].tick, down_tick)
	var downs: Array[NetMessages.EntityEvent] = _events_of(DOWNED, victim)
	if assert_eq(downs.size(), 1, "un DOWNED"):
		assert_eq(downs[0].attacker, attacker)
		assert_eq(downs[0].get_source(), _light_id())
	assert_eq(_events_of(DEATH).size(), 0, "nadie muere")
	assert_eq(_events_of(KILL).size(), 0)
	# Lo que publican los snapshots: la vida de derribado sobre 400 y el bit 3, sin el de muerto.
	var entity: NetEntity = _rig.entity(victim)
	assert_eq(entity.max_health, 400)
	assert_true(entity.health > 390 and entity.health <= 400, "vida de derribado (%d)" % entity.health)
	assert_true(entity.health_q > 0, "la vida cuantizada de un derribado nunca es 0")
	assert_true((entity.status & NetMessages.STATUS_DOWNED) != 0)
	assert_eq(entity.status & NetMessages.STATUS_DEAD, 0)
	# Ni reaparece ni se cura ni recibe efectos.
	assert_eq(_server().get_combat().request_respawn(victim, 0, _server().get_tick() + 1),
			CombatDirector.RespawnRequestResult.NOT_DEAD)
	assert_eq(_server().console_command("heal %d" % victim), "%s está derribado" % entity.display_name)
	assert_false(_server().get_combat().apply_status(combatant, CombatCatalog.status_id(&"bleed"),
			_server().get_tick() + 1))
	# Se arrastra a ×0,15: 2 s andando hacia delante son menos de 2 m (a pie serían 10).
	var start: Vector3 = entity.get_position()
	plans[1].move = Vector2(0.0, 1.0)
	plans[1].move_from = _server().get_tick() + 1
	plans[1].move_to = _server().get_tick() + 121
	await _rig.advance(121)
	var crawled: float = Vector2(entity.get_position().x - start.x, entity.get_position().z - start.z).length()
	assert_true(crawled > 0.5 and crawled < 2.0, "se arrastra despacio (%.2f m en 2 s)" % crawled)
	var report: Dictionary = _server()._combat_report()
	assert_eq(int(report.get("downs", -1)), 1, "el informe cuenta el derribo")
	assert_eq(int(report.get("downed_now", -1)), 1)


# --- Los tres desenlaces ----------------------------------------------------------------------

func test_an_ally_revives_in_180_ticks_with_300_health_and_back_to_none() -> void:
	await _rig.start_flat(tree)
	var ids: Array[int] = await _downed_pair()
	var victim: int = ids[1]
	var ally_plan := Plan.new()
	var ally: int = _scripted(SOLMARCH, Vector3(0.0, 0.05, -3.0), PI, ally_plan)
	await _rig.advance(4)
	var start: int = _server().get_tick() + 2
	ally_plan.hold(PlayerInput.INTERACT, start, start + 240)
	await _advance_to(start + 90)
	assert_eq(_combat_of(ally).action, CombatState.Action.REVIVE, "a mitad, levantando")
	assert_true(_combatant(victim).is_downed(), "y sigue derribado")
	await _advance_to(start + 179)
	assert_true(_combatant(victim).is_downed(), "en el tick 179 aún no")
	await _advance_to(start + 180)
	var revived: Combatant = _combatant(victim)
	assert_false(revived.is_downed(), "en el 180, levantado")
	assert_true(revived.is_alive())
	assert_eq(revived.health, 300, "con 300 de vida")
	assert_eq(_combat_of(victim).action, CombatState.Action.NONE, "y en NONE")
	assert_eq(_combat_of(ally).action, CombatState.Action.NONE, "quien levanta vuelve a NONE")
	var interacts: Array[NetMessages.EntityEvent] = _events_of(INTERACT, victim)
	if assert_eq(interacts.size(), 2, "INTERACT 1 y 3"):
		assert_eq(interacts[0].op, OP_REVIVE)
		assert_eq(interacts[0].actor, ally)
		assert_eq(interacts[0].tick, start)
		assert_eq(interacts[0].end_tick, start + 180, "con el tick en que acabará")
		assert_eq(interacts[1].op, OP_REVIVED)
		assert_eq(interacts[1].tick, start + 180)
	assert_eq(_rig.entity(victim).status & NetMessages.STATUS_DOWNED, 0, "sin el bit de derribado")
	assert_eq(_rig.entity(victim).max_health, 1000)
	assert_eq(_events_of(DEATH).size(), 0)
	# Mantener E sin soltar no empieza otra cosa: ya no hay derribados.
	await _rig.advance(30)
	assert_eq(_events_of(INTERACT, victim).size(), 2)
	assert_eq(int(_server()._combat_report().get("revives", -1)), 1)


func test_an_enemy_executes_in_60_ticks_with_the_execute_source_and_a_kill() -> void:
	await _rig.start_flat(tree)
	var plans: Array[Plan] = []
	var ids: Array[int] = await _downed_pair(plans)
	var attacker: int = ids[0]
	var victim: int = ids[1]
	# Cuando el ligero ha acabado, el atacante mantiene E.
	var start: int = ids[2] + 60
	plans[0].hold(PlayerInput.INTERACT, start, start + 90)
	await _advance_to(start + 30)
	assert_eq(_combat_of(attacker).action, CombatState.Action.EXECUTE, "rematando")
	await _advance_to(start + 59)
	assert_true(_combatant(victim).is_downed())
	await _advance_to(start + 60)
	assert_true(_combatant(victim).is_dead(), "rematado en 60 ticks")
	var interacts: Array[NetMessages.EntityEvent] = _events_of(INTERACT, victim)
	if assert_eq(interacts.size(), 1, "INTERACT 4"):
		assert_eq(interacts[0].op, OP_EXECUTE)
		assert_eq(interacts[0].actor, attacker)
		assert_eq(interacts[0].end_tick, start + 60)
	var deaths: Array[NetMessages.EntityEvent] = _events_of(DEATH, victim)
	if assert_eq(deaths.size(), 1, "una DEATH"):
		assert_eq(deaths[0].tick, start + 60)
		assert_eq(deaths[0].killer, attacker)
		assert_eq(deaths[0].get_source(), CombatSource.EXECUTE, "con la fuente del remate")
	var kills: Array[NetMessages.EntityEvent] = _events_of(KILL, victim)
	if assert_eq(kills.size(), 1, "y su KILL"):
		assert_eq(kills[0].killer, attacker)
		assert_eq(kills[0].get_source(), CombatSource.EXECUTE)
	assert_eq(_server().get_scores().get_entry(attacker).kills, 1, "la baja cuenta en el marcador")
	assert_eq(_combat_of(attacker).action, CombatState.Action.NONE)
	assert_eq(int(_server()._combat_report().get("executions", -1)), 1)


func test_a_downed_bleeds_out_in_1200_ticks_and_the_one_who_downed_it_gets_the_kill() -> void:
	await _rig.start_flat(tree)
	var ids: Array[int] = await _downed_pair()
	var attacker: int = ids[0]
	var victim: int = ids[1]
	var down_tick: int = ids[2]
	await _advance_to(down_tick + 600)
	assert_eq(_combatant(victim).downed_health, 200, "−1 cada 3 ticks: 200 a los 600")
	assert_eq(_rig.entity(victim).health, 200, "y es lo que publica")
	await _advance_to(down_tick + 1199)
	assert_eq(_combatant(victim).downed_health, 1)
	assert_eq(_events_of(DEATH).size(), 0)
	await _advance_to(down_tick + 1200)
	var deaths: Array[NetMessages.EntityEvent] = _events_of(DEATH, victim)
	if assert_eq(deaths.size(), 1, "desangrado a los 1200 ticks"):
		assert_eq(deaths[0].tick, down_tick + 1200)
		assert_eq(deaths[0].killer, attacker, "el asesino es quien lo derribó")
		assert_eq(deaths[0].get_source(), CombatSource.BLEED_OUT, "con la fuente del desangrado")
	var kills: Array[NetMessages.EntityEvent] = _events_of(KILL, victim)
	if assert_eq(kills.size(), 1):
		assert_eq(kills[0].killer, attacker)
	assert_true(_combatant(victim).is_dead())
	assert_eq(_rig.entity(victim).status & NetMessages.STATUS_DEAD, NetMessages.STATUS_DEAD)
	assert_eq(int(_server()._combat_report().get("bled_out", -1)), 1)


# --- Cortes y línea de visión -----------------------------------------------------------------

func test_damage_cuts_the_revive_on_whoever_revives_and_on_the_downed() -> void:
	await _rig.start_flat(tree)
	var plans: Array[Plan] = []
	var ids: Array[int] = await _downed_pair(plans)
	var attacker: int = ids[0]
	var victim: int = ids[1]
	# Que acabe el ligero que derribó (su golpe activo alcanzaría a quien llega).
	await _rig.advance(40)
	# Quien levanta, a 1,8 m a la derecha del derribado mirando a -X; un enemigo detrás de él, también mirando a -X,
	# a 2,4 m de él y a 4,2 del derribado (fuera del alcance de su ligero, con su avance).
	var ally_plan := Plan.new()
	var ally: int = _scripted(SOLMARCH, Vector3(1.8, 0.05, -1.5), PI * 0.5, ally_plan)
	var enemy_plan := Plan.new()
	_scripted(VARDHEIM, Vector3(4.2, 0.05, -1.5), PI * 0.5, enemy_plan)
	await _rig.advance(4)
	var start: int = _server().get_tick() + 2
	ally_plan.hold(PlayerInput.INTERACT, start, start + 400)
	enemy_plan.hold(PlayerInput.PRIMARY, start + 20, start + 22)
	var cut: bool = await _rig.advance_until(func() -> bool:
		return _events_of(INTERACT, victim).size() >= 2, 120, 2)
	assert_true(cut, "el golpe a quien levanta lo corta")
	var interacts: Array[NetMessages.EntityEvent] = _events_of(INTERACT, victim)
	if interacts.size() >= 2:
		assert_eq(interacts[0].op, OP_REVIVE)
		assert_eq(interacts[1].op, OP_REVIVE_CUT, "INTERACT 2")
		var ally_hits: Array[NetMessages.EntityEvent] = _events_of(HIT, ally)
		if assert_eq(ally_hits.size(), 1):
			assert_true((ally_hits[0].hit_flags & NetMessages.EntityEvent.HIT_FLAG_INTERRUPTED) != 0,
					"el HIT lleva el bit 5")
			assert_eq(interacts[1].tick, ally_hits[0].tick, "en el tick del golpe")
	assert_eq(_combat_of(ally).action, CombatState.Action.NONE)
	assert_true(_combatant(victim).is_downed(), "el derribado sigue esperando")
	# Otra vez, desde detrás del derribado (a 1,9 m de él) y con el atacante 0,6 m más atrás: su ligero, con su
	# avance, alcanza al derribado y no a quien levanta.
	_server().teleport(attacker, Vector3(0.0, 0.05, 0.6))
	_rig.character(attacker).yaw = 0.0
	_server().teleport(ally, Vector3(0.0, 0.05, -3.4))
	ally_plan.look_yaw = PI
	_rig.character(ally).yaw = PI
	ally_plan.holds.clear()
	var again: int = _server().get_tick() + 4
	ally_plan.hold(PlayerInput.INTERACT, again, again + 400)
	plans[0].hold(PlayerInput.PRIMARY, again + 20, again + 22)
	var cut_again: bool = await _rig.advance_until(func() -> bool:
		return _events_of(INTERACT, victim).size() >= 4, 120, 2)
	assert_true(cut_again, "el golpe al derribado también lo corta")
	interacts = _events_of(INTERACT, victim)
	if interacts.size() >= 4:
		assert_eq(interacts[2].op, OP_REVIVE)
		assert_eq(interacts[3].op, OP_REVIVE_CUT)
		var downed_hits: Array[NetMessages.EntityEvent] = _events_of(HIT, victim)
		if assert_eq(downed_hits.size(), 2, "el golpe que derribó y este"):
			assert_eq(downed_hits[1].attacker, attacker)
			assert_eq(interacts[3].tick, downed_hits[1].tick)
			assert_true(_combatant(victim).downed_health < 400 - downed_hits[1].amount + 1,
					"el daño le quita vida de derribado")
	assert_eq(_combat_of(ally).action, CombatState.Action.NONE, "quien levantaba vuelve a NONE")
	assert_eq(_events_of(HIT, ally).size(), 1, "sin que le golpeen a él")


func test_no_execution_through_the_closed_gate_and_through_the_broken_one_yes() -> void:
	await _rig.start_flat(tree, func(world: Node3D) -> void:
		FortressFixture.add_fortress(world, FortressFixture.make_definition()))
	var gate_x: float = FortressFixture.gate_position().x
	# El derribado dentro, a 1 m de la puerta; el enemigo fuera, a 0,8 m: 1,8 m entre los dos.
	var victim: int = _scripted(SOLMARCH, Vector3(gate_x + 1.0, 0.05, 0.0), PI * 0.5, Plan.new())
	var executor_plan := Plan.new()
	var executor: int = _scripted(VARDHEIM, Vector3(gate_x - 0.8, 0.05, 0.0), -PI * 0.5, executor_plan)
	await _rig.advance(3)
	assert_true(_server().get_combat().down(_combatant(victim), _server().get_tick() + 1))
	await _rig.advance(3)
	assert_true(_combatant(victim).is_downed())
	var start: int = _server().get_tick() + 2
	executor_plan.hold(PlayerInput.INTERACT, start, start + 20)
	await _advance_to(start + 30)
	assert_eq(_events_of(INTERACT, victim).size(), 0, "la puerta cerrada corta la línea de visión")
	assert_eq(_combat_of(executor).action, CombatState.Action.NONE)
	# Rota, la misma pulsación remata.
	var target: StructureTarget = _server().get_fortresses().get_structure_targets()[0]
	_server().get_fortresses().on_structure_hit(target, _combatant(executor), 900, _server().get_tick() + 1)
	await _rig.advance(3)
	assert_true(_server().get_fortresses().get_gate(FortressFixture.FORTRESS_ID).is_broken())
	var again: int = _server().get_tick() + 2
	executor_plan.hold(PlayerInput.INTERACT, again, again + 90)
	await _advance_to(again + 60)
	var interacts: Array[NetMessages.EntityEvent] = _events_of(INTERACT, victim)
	if assert_eq(interacts.size(), 1, "con la puerta rota, INTERACT 4"):
		assert_eq(interacts[0].op, OP_EXECUTE)
	assert_true(_combatant(victim).is_dead(), "y lo remata")


func test_an_executor_under_respawn_protection_loses_it_and_the_downeds_ally_cuts_it() -> void:
	await _rig.start_flat(tree)
	var plans: Array[Plan] = []
	var ids: Array[int] = await _downed_pair(plans)
	var attacker: int = ids[0]
	var victim: int = ids[1]
	await _rig.advance(60)
	# Un aliado del derribado a 1,5 m del rematador, de cara.
	var ally_plan := Plan.new()
	var ally: int = _scripted(SOLMARCH, Vector3(1.5, 0.05, 0.0), PI * 0.5, ally_plan)
	await _rig.advance(4)
	var start: int = _server().get_tick() + 2
	# Como si el rematador acabara de reaparecer: protegido 3 s.
	_combatant(attacker).protected_until = start + 180
	plans[0].hold(PlayerInput.INTERACT, start, start + 90)
	ally_plan.hold(PlayerInput.PRIMARY, start + 5, start + 7)
	await _advance_to(start + 61)
	var interacts: Array[NetMessages.EntityEvent] = _events_of(INTERACT, victim)
	if assert_eq(interacts.size(), 2, "INTERACT 4 y 5 (antes: el remate no se podía cortar)"):
		assert_eq(interacts[0].op, OP_EXECUTE)
		assert_eq(_combatant(attacker).protected_until, interacts[0].tick,
				"empezar a rematar le quita la protección en ese tick")
		assert_eq(interacts[1].op, OP_EXECUTE_CUT, "el golpe del aliado lo corta")
		var attacker_hits: Array[NetMessages.EntityEvent] = _events_of(HIT, attacker)
		if assert_true(attacker_hits.size() >= 1, "el aliado del derribado le golpea"):
			assert_eq(attacker_hits[0].attacker, ally)
			assert_true((attacker_hits[0].hit_flags & NetMessages.EntityEvent.HIT_FLAG_INTERRUPTED) != 0,
					"con el bit 5")
			assert_eq(interacts[1].tick, attacker_hits[0].tick, "en el tick del golpe")
	assert_true(_combatant(victim).is_downed(), "y el derribado sigue derribado")
	assert_eq(_events_of(DEATH, victim).size(), 0)


func test_an_execution_is_cut_when_the_downed_crawls_into_its_camp() -> void:
	# Un campamento de Solmarch de 10 m de radio con el borde 0,25 m detrás del derribado (en z = -1,75).
	await _rig.start_flat(tree, func(world: Node3D) -> void:
		NpcRig.add_safe_area(world, &"solmarch", Vector3(0.0, 0.0, -1.75 - 10.0), 10.0))
	var plans: Array[Plan] = []
	var ids: Array[int] = await _downed_pair(plans)
	var attacker: int = ids[0]
	var victim: int = ids[1]
	await _rig.advance(60)
	var start: int = _server().get_tick() + 2
	plans[0].hold(PlayerInput.INTERACT, start, start + 90)
	# El derribado se arrastra hacia atrás (hacia -Z), hacia su campamento.
	plans[1].move = Vector2(0.0, -1.0)
	plans[1].move_from = start + 1
	plans[1].move_to = start + 200
	var safe: SafeAreas = _server().get_combat().resolver.get_safe_areas()
	var inside_at: int = -1
	for rel: int in range(1, 70):
		await _advance_to(start + rel)
		if inside_at < 0 and safe.contains_own(SOLMARCH, _rig.entity(victim).get_position()):
			inside_at = _server().get_tick()
	assert_true(inside_at > start and inside_at < start + 60, "entra en su campamento antes del final (%d)" % (
			inside_at - start))
	var interacts: Array[NetMessages.EntityEvent] = _events_of(INTERACT, victim)
	if assert_eq(interacts.size(), 2, "INTERACT 4 y 5 (antes: rematado dentro de su campamento)"):
		assert_eq(interacts[0].op, OP_EXECUTE)
		assert_eq(interacts[1].op, OP_EXECUTE_CUT, "dentro de su zona segura se corta")
		assert_eq(interacts[1].tick, inside_at, "en el tick en que entra")
	assert_eq(_events_of(DEATH, victim).size(), 0, "sin muerte por remate")
	assert_true(_combatant(victim).is_downed(), "sigue derribado")
	assert_eq(_combat_of(attacker).action, CombatState.Action.NONE, "quien remataba vuelve a NONE")


func test_the_gate_is_not_repaired_with_a_downed_player_in_the_doorway() -> void:
	var definition: FortressDefinition = FortressFixture.make_definition()
	definition.gate_repair_after_s = 5.0
	await _rig.start_flat(tree, func(world: Node3D) -> void:
		FortressFixture.add_fortress(world, definition))
	var blocker: int = _scripted(VARDHEIM, FortressFixture.gate_position() + Vector3(0.0, 0.05, 1.0), 0.0,
			Plan.new())
	var target: StructureTarget = _server().get_fortresses().get_structure_targets()[0]
	_server().get_fortresses().on_structure_hit(target, _combatant(blocker), 900, _server().get_tick() + 1)
	await _rig.advance(3)
	assert_true(_server().get_combat().down(_combatant(blocker), _server().get_tick() + 1))
	await _rig.advance(6 * 60)
	assert_true(_combatant(blocker).is_downed())
	var gate: FortGate = _server().get_fortresses().get_gate(FortressFixture.FORTRESS_ID)
	assert_true(gate.is_broken(), "pasado el plazo, un derribado en el vano impide la reparación")
	assert_true(_server().get_fortresses().is_repair_pending(FortressFixture.FORTRESS_ID))
	assert_eq(_server().console_command("kill %d" % blocker), "%s muerto" % _rig.entity(blocker).display_name)
	await _rig.advance(3)
	assert_false(gate.is_broken(), "muerto, la puerta se repara")


# --- Salir derribado --------------------------------------------------------------------------

func test_a_fake_that_leaves_while_downed_dies_first_with_death_and_kill() -> void:
	await _rig.start_flat(tree)
	var ids: Array[int] = await _downed_pair()
	var attacker: int = ids[0]
	var victim: int = ids[1]
	assert_true(_server().remove_fake_player(victim))
	await _rig.advance(2)
	assert_null(_rig.server.get_registry().get_entity(victim), "se va")
	var deaths: Array[NetMessages.EntityEvent] = _events_of(DEATH, victim)
	if assert_eq(deaths.size(), 1, "antes, su DEATH"):
		assert_eq(deaths[0].killer, attacker, "a manos de quien lo derribó")
		assert_eq(deaths[0].get_source(), CombatSource.BLEED_OUT)
	assert_eq(_events_of(KILL, victim).size(), 1, "y su KILL")
	assert_eq(_server().get_scores().get_entry(attacker).kills, 1)


func test_a_filler_retired_while_downed_leaves_without_death_or_kill() -> void:
	# Revisión de la integración de las habilidades: el falso de relleno que cede su sitio a una persona (GUE-43) se iba
	# como cualquier falso, y si estaba derribado su baja era una muerte con KILL para quien lo derribó: la entrada de una
	# persona sumaba una muerte a un bando. Retirado con retire_filler, solo el DESPAWN.
	await _rig.start_flat(tree)
	var ids: Array[int] = await _downed_pair()
	var attacker: int = ids[0]
	var victim: int = ids[1]
	assert_false(_server().is_fake_calm(victim), "derribado no está tranquilo")
	assert_true(_server().is_fake_calm(attacker), "quien lo derribó, sí")
	assert_true(_server().retire_filler(victim))
	await _rig.advance(2)
	assert_null(_rig.server.get_registry().get_entity(victim), "se va")
	assert_eq(_events_of(DEATH, victim).size(), 0, "sin DEATH")
	assert_eq(_events_of(KILL, victim).size(), 0, "ni KILL")
	var entry: Variant = _server().get_scores().get_entry(attacker)
	assert_true(entry == null or entry.kills == 0, "ni muerte en el marcador")


func test_a_player_who_leaves_while_downed_dies_and_comes_back_at_the_camp() -> void:
	await _start_net_server()
	var events: Array[NetMessages.EntityEvent] = []
	_net_server.get_combat().event_emitted.connect(func(event: NetMessages.EntityEvent,
			_involved: PackedInt32Array) -> void: events.append(event))
	var client: NetClient = await _join_bot(SOLMARCH, 41)
	if not assert_not_null(client, "el bot entra"):
		return
	var net_id: int = client.get_net_id()
	var attacker: int = _net_server.add_fake_player(CombatFixture.ScriptBrain.new(1), VARDHEIM)
	var combatant: Combatant = _net_server.get_combat().get_combatant(net_id)
	# Derribado y en combate: aun así no se queda su cuerpo (GUE-41), muere.
	combatant.mark_combat(_net_server.get_tick() + 1)
	_net_server.get_combat().downed.down(combatant, attacker, _light_id(), _net_server.get_tick() + 1)
	await wait_physics_frames(3)
	assert_true(combatant.is_downed())
	client.leave()
	var gone: bool = false
	for _i: int in WAIT_FRAMES:
		await tree.physics_frame
		if _net_server.get_registry().get_entity(net_id) == null:
			gone = true
			break
	if not assert_true(gone, "sale de la zona"):
		return
	assert_false(_net_server.is_lingering(net_id), "sin cuerpo que se quede")
	var deaths: Array[NetMessages.EntityEvent] = events.filter(func(event: NetMessages.EntityEvent) -> bool:
		return event.event == DEATH and event.net_id == net_id)
	if assert_eq(deaths.size(), 1, "muere al salir"):
		assert_eq(deaths[0].killer, attacker)
		assert_eq(deaths[0].get_source(), CombatSource.BLEED_OUT)
	assert_eq(events.filter(func(event: NetMessages.EntityEvent) -> bool:
		return event.event == KILL and event.net_id == net_id).size(), 1, "con su KILL")
	# Al volver aparece en el campamento de su reino, como cualquiera.
	var back: NetClient = await _join_bot(SOLMARCH, 41)
	if not assert_not_null(back, "vuelve a entrar"):
		return
	var returned: Combatant = _net_server.get_combat().get_combatant(back.get_net_id())
	assert_true(returned.is_alive() and not returned.is_downed())
	assert_eq(returned.health, returned.max_health)
	var position: Vector3 = _net_server.get_registry().get_entity(back.get_net_id()).get_position()
	assert_true(Vector2(position.x - ZoneFixture.SOLMARCH_SPAWN.x, position.z - ZoneFixture.SOLMARCH_SPAWN.z).length()
			< 3.0, "en el punto de su reino (%s)" % position)


func test_a_lingering_body_downed_dies_when_its_time_runs_out() -> void:
	await _start_net_server()
	_net_server.linger_ticks = 90
	var events: Array[NetMessages.EntityEvent] = []
	_net_server.get_combat().event_emitted.connect(func(event: NetMessages.EntityEvent,
			_involved: PackedInt32Array) -> void: events.append(event))
	var client: NetClient = await _join_bot(SOLMARCH, 42)
	if not assert_not_null(client, "el bot entra"):
		return
	var net_id: int = client.get_net_id()
	var attacker: int = _net_server.add_fake_player(CombatFixture.ScriptBrain.new(1), VARDHEIM)
	var combatant: Combatant = _net_server.get_combat().get_combatant(net_id)
	combatant.mark_combat(_net_server.get_tick() + 1)
	client.leave()
	var lingering: bool = false
	for _i: int in WAIT_FRAMES:
		await tree.physics_frame
		if _net_server.is_lingering(net_id):
			lingering = true
			break
	if not assert_true(lingering, "sale en combate: su cuerpo se queda"):
		return
	_net_server.get_combat().downed.down(combatant, attacker, _light_id(), _net_server.get_tick() + 1)
	var removed: bool = false
	for _i: int in WAIT_FRAMES:
		await tree.physics_frame
		if _net_server.get_registry().get_entity(net_id) == null:
			removed = true
			break
	assert_true(removed, "al acabar su plazo se retira")
	var deaths: Array[NetMessages.EntityEvent] = events.filter(func(event: NetMessages.EntityEvent) -> bool:
		return event.event == DEATH and event.net_id == net_id)
	if assert_eq(deaths.size(), 1, "y antes muere"):
		assert_eq(deaths[0].killer, attacker)
		assert_eq(deaths[0].get_source(), CombatSource.BLEED_OUT)


# --- PNJ ---------------------------------------------------------------------------------------

func test_a_lethal_hit_from_an_npc_kills_directly() -> void:
	await _rig.start_flat(tree)
	var npc_plan := Plan.new()
	var brain := CombatFixture.ScriptBrain.new(1)
	brain.script_fn = func(tick: int, _position: Vector3, _yaw: float) -> PlayerInput:
		return npc_plan.input_for(tick)
	var npc: int = _server().add_npc(brain, "Hueco", HUECOS, Vector3(0.0, 0.05, 0.0), 0.0)
	var victim: int = _scripted(SOLMARCH, Vector3(0.0, 0.05, -1.5), PI, Plan.new())
	_combatant(victim).health = 50
	var press: int = _server().get_tick() + 3
	npc_plan.hold(PlayerInput.PRIMARY, press, press + 2)
	var dead: bool = await _rig.advance_until(func() -> bool: return _combatant(victim).is_dead(), 120, 2)
	assert_true(dead, "el golpe mortal de un PNJ mata")
	assert_eq(_events_of(DOWNED).size(), 0, "sin derribo")
	var deaths: Array[NetMessages.EntityEvent] = _events_of(DEATH, victim)
	if assert_eq(deaths.size(), 1):
		assert_eq(deaths[0].killer, npc)
	var hits: Array[NetMessages.EntityEvent] = _events_of(HIT, victim)
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].hit_flags, NetMessages.EntityEvent.HIT_FLAG_LETHAL)


func test_an_npc_prefers_a_downed_player_and_finishes_it_with_damage() -> void:
	await _rig.start_flat(tree)
	# Un Hueco suelto mirando a -Z, un jugador derribado a 4 m delante y otro en pie más cerca (2,5 m, a un lado).
	var definition: NpcDefinition = NpcCatalog.get_definition(&"hollow")
	var hollow_brain := HfsmBrain.new(7)
	var hollow: int = _server().add_npc(hollow_brain, definition.display_name, HUECOS, Vector3.ZERO, 0.0, false,
			definition)
	hollow_brain.bind(_rig.npcs().get_world(), _rig.entity(hollow), _combatant(hollow), definition, Vector3.ZERO,
			0.0)
	var downed: int = _scripted(VARDHEIM, Vector3(0.0, 0.05, -4.0), PI, Plan.new())
	var standing: int = _scripted(SOLMARCH, Vector3(1.5, 0.05, -2.0), PI, Plan.new())
	assert_true(_server().get_combat().down(_combatant(downed), _server().get_tick() + 1))
	var down_tick: int = _server().get_tick() + 1
	var finished: bool = await _rig.advance_until(func() -> bool: return _combatant(downed).is_dead(), 1100, 6)
	assert_true(finished, "el Hueco lo remata antes de que se desangre")
	var deaths: Array[NetMessages.EntityEvent] = _events_of(DEATH, downed)
	if assert_eq(deaths.size(), 1):
		assert_eq(deaths[0].killer, hollow, "a manos del Hueco")
		assert_true(deaths[0].tick < down_tick + 1200, "antes de desangrarse")
	var hollow_hits: Array[NetMessages.EntityEvent] = []
	for event: NetMessages.EntityEvent in _events_of(HIT):
		if event.attacker == hollow:
			hollow_hits.append(event)
	if assert_true(not hollow_hits.is_empty(), "le golpea"):
		assert_eq(hollow_hits[0].net_id, downed, "el primer golpe es para el derribado, no para el de pie")
		var on_downed: int = 0
		for event: NetMessages.EntityEvent in hollow_hits:
			if event.net_id == downed:
				on_downed += event.amount
		assert_true(on_downed > 0, "con daño (%d)" % on_downed)
	assert_true(_combatant(standing).is_alive())


# --- Comando 15 y golpes del mismo tick -------------------------------------------------------

func test_command_15_downs_without_an_author_and_bleeds_out_without_a_kill() -> void:
	await _rig.start_flat(tree, func(world: Node3D) -> void:
		NpcRig.add_safe_area(world, &"vardheim", Vector3(-60.0, 0.0, 0.0), 10.0))
	var ana: int = _scripted(VARDHEIM, Vector3(0.0, 0.05, 0.0), 0.0, Plan.new())
	var safe: int = _scripted(VARDHEIM, Vector3(-60.0, 0.05, 0.0), 0.0, Plan.new())
	var commands: CommandRegistry = _server().get_commands()
	var peer := ServerPeer.new(3)
	peer.entity = _rig.entity(safe)
	assert_eq(commands.execute_network(peer, NetProtocol.DEBUG_DOWN, PackedByteArray()),
			CommandRegistry.Result.REFUSED, "en la zona segura propia, no")
	assert_false(_combatant(safe).is_downed())
	# Fuera de las zonas RVR, tampoco.
	_server().get_combat().downed.zone_id = &"zona_sin_rvr"
	peer.entity = _rig.entity(ana)
	assert_eq(commands.execute_network(peer, NetProtocol.DEBUG_DOWN, PackedByteArray()),
			CommandRegistry.Result.REFUSED, "fuera de una zona RVR, no")
	_server().get_combat().downed.zone_id = &"test_world"
	assert_eq(commands.execute_network(peer, NetProtocol.DEBUG_DOWN, PackedByteArray([1])),
			CommandRegistry.Result.BAD_ARGUMENTS, "sin datos")
	var down_tick: int = _server().get_tick() + 1
	assert_eq(commands.execute_network(peer, NetProtocol.DEBUG_DOWN, PackedByteArray()),
			CommandRegistry.Result.OK, "15")
	assert_true(_combatant(ana).is_downed())
	assert_eq(commands.execute_network(peer, NetProtocol.DEBUG_DOWN, PackedByteArray()),
			CommandRegistry.Result.REFUSED, "ya derribado")
	var downs: Array[NetMessages.EntityEvent] = _events_of(DOWNED, ana)
	if assert_eq(downs.size(), 1):
		assert_eq(downs[0].attacker, 0, "sin autor")
		assert_eq(downs[0].tick, down_tick)
	await _advance_to(down_tick + 1200)
	var deaths: Array[NetMessages.EntityEvent] = _events_of(DEATH, ana)
	if assert_eq(deaths.size(), 1, "se desangra"):
		assert_eq(deaths[0].killer, 0)
		assert_eq(deaths[0].tick, down_tick + 1200)
	assert_eq(_events_of(KILL).size(), 0, "sin KILL")
	# Por la consola.
	var bo: int = _scripted(SOLMARCH, Vector3(10.0, 0.05, 0.0), 0.0, Plan.new())
	assert_eq(_server().console_command("down %d" % bo), "%s derribado" % _rig.entity(bo).display_name)
	assert_true(_combatant(bo).is_downed())


func test_two_hits_in_the_same_tick_only_the_first_downs_and_the_second_is_dropped() -> void:
	await _rig.start_flat(tree)
	# Dos atacantes de Vardheim a los lados de la víctima de Solmarch, los dos golpean en el mismo tick.
	var left_plan := Plan.new()
	var right_plan := Plan.new()
	var left: int = _scripted(VARDHEIM, Vector3(-1.5, 0.05, -1.5), -PI * 0.5, left_plan)
	var right: int = _scripted(VARDHEIM, Vector3(1.5, 0.05, -1.5), PI * 0.5, right_plan)
	var victim: int = _scripted(SOLMARCH, Vector3(0.0, 0.05, -1.5), 0.0, Plan.new())
	_combatant(victim).health = 50
	var press: int = _server().get_tick() + 3
	left_plan.hold(PlayerInput.PRIMARY, press, press + 2)
	right_plan.hold(PlayerInput.PRIMARY, press, press + 2)
	var downed: bool = await _rig.advance_until(func() -> bool: return _combatant(victim).is_downed(), 120, 2)
	assert_true(downed)
	await _rig.advance(4)
	var hits: Array[NetMessages.EntityEvent] = _events_of(HIT, victim)
	if assert_eq(hits.size(), 1, "el segundo golpe del mismo tick se descarta"):
		assert_eq(hits[0].attacker, left, "gana el de menor net_id")
	assert_eq(_combatant(victim).downed_by, left)
	assert_true(right > left)
	# Los golpes de después sí le quitan vida de derribado, sin controles.
	right_plan.hold(PlayerInput.PRIMARY, _server().get_tick() + 40, _server().get_tick() + 42)
	var hit_again: bool = await _rig.advance_until(func() -> bool:
		return _events_of(HIT, victim).size() >= 2, 120, 2)
	assert_true(hit_again)
	var later: NetMessages.EntityEvent = _events_of(HIT, victim)[1]
	assert_eq(later.attacker, right)
	assert_eq(later.hit_flags & NetMessages.EntityEvent.HIT_FLAG_DOWNED, 0)
	assert_eq(_combat_of(victim).action, CombatState.Action.DOWNED, "sin tambaleo")
	assert_true(_combatant(victim).downed_health <= 400 - later.amount)


# --- ENet --------------------------------------------------------------------------------------

func _start_net_server() -> void:
	var port: int = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(tree.root, "")
	var config := ServerConfig.new()
	config.port = port
	config.zone_id = "test_world"
	config.max_players = 8
	config.no_dummies = true
	_net_server = NetHarness.start_server(_server_viewport, config)
	assert_not_null(_net_server, "el servidor escucha")
	_net_server.set_meta(&"port", port)
	await wait_physics_frames(3)


func _join_bot(realm: int, bot_seed: int) -> NetClient:
	var viewport: SubViewport = NetHarness.make_world_viewport(tree.root, "")
	_client_viewports.append(viewport)
	var client: NetClient = NetHarness.start_bot(viewport, int(_net_server.get_meta(&"port")), realm, bot_seed)
	for _i: int in WAIT_FRAMES:
		await tree.physics_frame
		if client.get_net_id() > 0 and _net_server.get_combat().get_combatant(client.get_net_id()) != null:
			return client
	return null
