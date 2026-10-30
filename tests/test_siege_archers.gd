extends TestCase
## Los tiradores de asedio sobre el Vado Gris de verdad, con su física (revisión de la integración de las habilidades
## sobre F6b; docs/fuerte.md 8.3): jugadores falsos con el cerebro de asedio ([constant BotBrain.Pattern.SIEGE]) y la
## plantilla del tirador (el arco en la mano y la espada a la espalda). Son las sondas de la revisión convertidas en
## prueba: antes, el arquero del dueño tiraba a su propia puerta cerrada (todas las flechas al mundo), el atacante con la
## puerta rota se quedaba tirando a la empalizada sin entrar, y la puerta se golpeaba a flechazos (unas 2,6 veces menos
## daño que con la espada). Cada prueba falla con el cerebro de antes. Ahora el arco solo tira con línea de tiro
## ([method BotBrain.set_line_of_sight]: el servidor le da los rayos de su mundo), y para la puerta saca la espada.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
## Delante de la puerta (en x = -20; el fuerte hacia +X), en la explanada, a la altura del suelo.
const GATE_FRONT: Vector3 = Vector3(-27.0, 10.3, 0.0)
## Medio minuto de juego.
const HALF_MINUTE: int = 1800

var _runner: SiegeRunner = null
# net_id -> cerebro de cada tirador.
var _brains: Dictionary[int, BotBrain] = {}


func after_each() -> void:
	if is_instance_valid(_runner):
		_runner.finish()
		_runner.get_parent().remove_child(_runner)
		_runner.free()
	_runner = null
	_brains.clear()
	await wait_process_frames()


func _start(with_npcs: bool) -> bool:
	_runner = SiegeRunner.new()
	tree.root.add_child(_runner)
	return await _runner.start(tree.root, "", 64, with_npcs)


## Un tirador de asedio de [param realm] con la semilla [param rng_seed], sin la pasarela ni la reunión, en
## [param position].
func _add_marksman(realm: int, rng_seed: int, position: Vector3) -> int:
	var brain := BotBrain.new(rng_seed, BotBrain.Pattern.SIEGE)
	brain.set_walkway_role(false)
	brain.set_rally(1)
	var net_id: int = _runner.server.add_fake_player(brain, realm, CombatCatalog.template_id(&"marksman"))
	if net_id > 0:
		_brains[net_id] = brain
		_runner.server.teleport(net_id, position)
	return net_id


func _projectiles() -> Dictionary:
	return _runner.server.get_combat().projectiles.stats


func test_the_owners_archers_never_shoot_at_their_own_closed_gate() -> void:
	# Sonda (a): cuatro tiradores de Vardheim, dueños, junto al círculo; cuatro escuderos de Solmarch golpean la puerta
	# cerrada desde fuera. El cuerpo de vista de la puerta para las flechas en los dos sentidos.
	if not assert_true(await _start(false), "el servidor arranca sobre el Vado Gris"):
		return
	_runner.server.console_command("fort_owner vardheim")
	await _runner.advance(10)
	var archers: Array[int] = []
	for i: int in 4:
		archers.append(_add_marksman(VARDHEIM, 500 + i, Vector3(-12.0, 10.6, -1.5 + float(i))))
	for i: int in 4:
		var brain := BotBrain.new(600 + i, BotBrain.Pattern.SIEGE)
		brain.set_walkway_role(false)
		brain.set_rally(1)
		var net_id: int = _runner.server.add_fake_player(brain, SOLMARCH)
		_runner.server.teleport(net_id, GATE_FRONT + Vector3(0.0, 0.0, -1.5 + float(i)))
	var state: FortressState = _runner.state()
	var fighting: int = 0
	for _step: int in HALF_MINUTE / 30:
		await _runner.advance(30)
		for net_id: int in archers:
			fighting += 1 if _brains[net_id].get_siege_task() == BotBrain.SiegeTask.FIGHT else 0
	var stats: Dictionary = _projectiles()
	print("[siege-archers] dueño con la puerta cerrada: puerta %d/%d; flechas %d (mundo %d); muestras peleando %d" % [
			state.gate_health, state.gate_max, stats[&"projectiles_fired"], stats[&"projectile_world_hits"], fighting])
	assert_false(state.is_gate_broken(), "la puerta aguanta el medio minuto")
	assert_true(state.gate_health < state.gate_max, "y la están golpeando")
	assert_eq(int(stats[&"projectiles_fired"]), 0, "ni una flecha a su propia puerta (antes, 146, todas a ella)")
	assert_eq(fighting, 0, "los arqueros del dueño no pelean con quien está tras la puerta cerrada")


func test_with_the_gate_broken_the_attackers_archers_go_in_instead_of_shooting_the_palisade() -> void:
	# Sonda (b), sin PNJ para que no haya más pelea que esa: cuatro tiradores de Vardheim delante de la empalizada, a un
	# lado de la puerta rota, y cuatro de Solmarch quietos en el patio, a unos 10 m y detrás de la pared. Antes tiraban a
	# la madera (139 de 150 flechas al mundo, y uno no entraba en 30 s); ahora no tienen tiro, entran por la puerta y les
	# tiran dentro. Desde el vano, de lado, la mira del hombro también ve la jamba: la línea de tiro mira los dos rayos.
	if not assert_true(await _start(false), "el servidor arranca sobre el Vado Gris"):
		return
	await _runner.advance(10)
	var archers: Array[int] = []
	for i: int in 4:
		archers.append(_add_marksman(VARDHEIM, 700 + i, Vector3(-24.0, 10.3, 6.0 + float(i))))
	for i: int in 4:
		var idle := BotBrain.new(800 + i, BotBrain.Pattern.IDLE)
		var net_id: int = _runner.server.add_fake_player(idle, SOLMARCH)
		_runner.server.teleport(net_id, Vector3(-14.0, 10.6, 8.0 + float(i)))
	var fortresses: FortressController = _runner.server.get_fortresses()
	var gate: StructureTarget = fortresses.get_structure_targets()[0]
	fortresses.on_structure_hit(gate, _runner.server.get_combat().get_combatant(archers[0]), 100000, _runner.tick() + 1)
	await _runner.advance(2)
	var state: FortressState = _runner.state()
	assert_true(state.is_gate_broken(), "la puerta, rota")
	var view: SiegeView = _runner.server.get_siege_view()
	var inside_at: Dictionary[int, int] = {}
	for step: int in HALF_MINUTE / 15:
		await _runner.advance(15)
		for net_id: int in archers:
			var entity: NetEntity = _runner.server.get_registry().get_entity(net_id)
			if entity != null and not inside_at.has(net_id) and view.is_inside_enclosure(entity.get_position()) == 1:
				inside_at[net_id] = (step + 1) * 15
	var stats: Dictionary = _projectiles()
	var fired: int = int(stats[&"projectiles_fired"])
	var world: int = int(stats[&"projectile_world_hits"])
	print("[siege-archers] puerta rota: dentro a los %s ticks; flechas %d (mundo %d, personajes %d)" % [
			inside_at.values(), fired, world, stats[&"projectile_character_hits"]])
	assert_eq(inside_at.size(), 4, "los cuatro entran en el fuerte en medio minuto (%s)" % [inside_at])
	for net_id: int in inside_at:
		assert_true(inside_at[net_id] <= 900, "en 15 s como mucho (%d ticks)" % inside_at[net_id])
	assert_true(int(stats[&"projectile_character_hits"]) > 0, "y dentro les tiran")
	assert_true(world * 5 <= fired, "como mucho una de cada cinco flechas al mundo (%d de %d; antes, 139 de 150)" % [
			world, fired])


func test_the_marksmen_hit_the_gate_with_the_sword() -> void:
	# Sonda de la puerta: cuatro tiradores contra la puerta cerrada del fuerte neutral, medio minuto. A flechazos le
	# quitaban 1880 (138 flechas, todas a la puerta); cuatro escuderos, 4986. Con la espada, lo mismo que ellos, más o
	# menos, y sin flechas.
	if not assert_true(await _start(false), "el servidor arranca sobre el Vado Gris"):
		return
	await _runner.advance(10)
	var archers: Array[int] = []
	for i: int in 4:
		archers.append(_add_marksman(VARDHEIM, 800 + i, GATE_FRONT + Vector3(0.0, 0.0, -1.5 + float(i))))
	var state: FortressState = _runner.state()
	await _runner.advance(HALF_MINUTE)
	var stats: Dictionary = _projectiles()
	var damage: int = state.gate_max - state.gate_health
	print("[siege-archers] tiradores contra la puerta: %d de daño en 30 s; flechas %d" % [damage,
			stats[&"projectiles_fired"]])
	assert_eq(int(stats[&"projectiles_fired"]), 0, "ninguna flecha a la puerta")
	assert_true(damage >= 4000, "con la espada, como los escuderos (%d; a flechazos, 1880)" % damage)
	var sword: int = CombatCatalog.weapon_id(&"sword_shield")
	for net_id: int in archers:
		var character: PlayerCharacter = _runner.server.get_registry().get_entity(net_id).get_character()
		assert_eq(character.combat.weapon_id, sword, "el %d, con la espada en la mano" % net_id)

