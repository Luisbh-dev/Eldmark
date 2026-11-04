extends TestCase
## The siege shooters on the real Vado Gris, with its physics (review of the abilities integration
## on F6b; docs/fuerte.md 8.3): fake players with the siege brain ([constant BotBrain.Pattern.SIEGE]) and the
## shooter template (the bow in hand and the sword on the back). These are the review's probes turned into a
## test: before, the owner's archer shot at its own closed door (all arrows into the world), the attacker with the
## door broken kept shooting at the palisade without entering, and the door was hit with arrows (about 2.6 times less
## damage than with the sword). Each test fails with the old brain. Now the bow only shoots with a line of fire
## ([method BotBrain.set_line_of_sight]: the server gives it its world's rays), and for the door it draws the sword.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
## In front of the door (at x = -20; the fort toward +X), on the esplanade, at ground level.
const GATE_FRONT: Vector3 = Vector3(-27.0, 10.3, 0.0)
## Half a minute of play.
const HALF_MINUTE: int = 1800

var _runner: SiegeRunner = null
# net_id -> brain of each shooter.
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


## A siege shooter of [param realm] with seed [param rng_seed], without the walkway or the rally, at
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
	# Probe (a): four Vardheim shooters, owners, next to the circle; four Solmarch squires hit the closed door
	# from outside. The door's view body stops arrows in both directions.
	if not assert_true(await _start(false), "the server starts on Vado Gris"):
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
	assert_false(state.is_gate_broken(), "the door holds for half a minute")
	assert_true(state.gate_health < state.gate_max, "and they are hitting it")
	assert_eq(int(stats[&"projectiles_fired"]), 0, "not a single arrow at its own door (before, 146, all at it)")
	assert_eq(fighting, 0, "the owner's archers do not fight whoever is behind the closed door")


func test_with_the_gate_broken_the_attackers_archers_go_in_instead_of_shooting_the_palisade() -> void:
	# Probe (b), without NPCs so there is no fight other than this one: four Vardheim shooters in front of the palisade, to one
	# side of the broken door, and four Solmarch ones standing still in the courtyard, about 10 m away and behind the wall. Before they shot at
	# the wood (139 of 150 arrows into the world, and one did not get in within 30 s); now they have no shot, go in through the door and shoot
	# them inside. From the doorway, sideways, the shoulder crosshair also sees the jamb: the line of fire checks both rays.
	if not assert_true(await _start(false), "the server starts on Vado Gris"):
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
	assert_true(state.is_gate_broken(), "the door, broken")
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
	assert_eq(inside_at.size(), 4, "all four enter the fort within half a minute (%s)" % [inside_at])
	for net_id: int in inside_at:
		assert_true(inside_at[net_id] <= 900, "in 15 s at most (%d ticks)" % inside_at[net_id])
	assert_true(int(stats[&"projectile_character_hits"]) > 0, "and inside they shoot them")
	assert_true(world * 5 <= fired, "at most one in five arrows into the world (%d of %d; before, 139 of 150)" % [
			world, fired])


func test_the_marksmen_hit_the_gate_with_the_sword() -> void:
	# Door probe: four shooters against the neutral fort's closed door, half a minute. With arrows they
	# took off 1880 (138 arrows, all at the door); four squires, 4986. With the sword, about the same as they do,
	# and no arrows.
	if not assert_true(await _start(false), "the server starts on Vado Gris"):
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
	assert_eq(int(stats[&"projectiles_fired"]), 0, "no arrows at the door")
	assert_true(damage >= 4000, "with the sword, like the squires (%d; with arrows, 1880)" % damage)
	var sword: int = CombatCatalog.weapon_id(&"sword_shield")
	for net_id: int in archers:
		var character: PlayerCharacter = _runner.server.get_registry().get_entity(net_id).get_character()
		assert_eq(character.combat.weapon_id, sword, "number %d, with the sword in hand" % net_id)

