extends TestCase
## Tests for consumables on the server (PRG-08; docs/habilidades.md, sections 2.3, 4.2 and 4.6; package H3c):
## the health potion heals in 6 pulses of 50 on finishing the drink, an interrupting hit spends neither the charge nor the
## shared cooldown, the camp refill restores the charges without touching the weapon (with slot 2
## active), the cooldowns or the channeling in progress (and not outside the camp or in combat), command
## 16 and the foreign LOADOUT with 0 charges.
## [br][br]
## Scripted fake players on the flat zone of [ZoneFixture] ([NpcRig] setup); the network LOADOUT, with
## two real clients over ENet on 127.0.0.1.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const HIT: int = NetMessages.EntityEvent.Kind.HIT
const HEAL: int = NetMessages.EntityEvent.Kind.HEAL
const STATUS: int = NetMessages.EntityEvent.Kind.STATUS
const LOADOUT: int = NetMessages.EntityEvent.Kind.LOADOUT
const WAIT_FRAMES: int = 900

var _rig: NpcRig = null
# Director events with the ones involved.
var _events: Array[NetMessages.EntityEvent] = []
var _involved: Array[PackedInt32Array] = []
var _server_viewport: SubViewport = null
var _client_viewports: Array[SubViewport] = []


func before_each() -> void:
	_rig = NpcRig.new()
	_events.clear()
	_involved.clear()


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
	await wait_process_frames()


# --- Helpers ----------------------------------------------------------------------------------

func _start(build: Callable = Callable()) -> void:
	await _rig.start_flat(tree, build)
	_rig.server.get_combat().event_emitted.connect(func(event: NetMessages.EntityEvent,
			involved: PackedInt32Array) -> void:
		_events.append(event)
		_involved.append(involved))


func _server() -> ZoneServer:
	return _rig.server


func _combatant(net_id: int) -> Combatant:
	return _server().get_combat().get_combatant(net_id)


func _combat_of(net_id: int) -> CombatState:
	return _rig.character(net_id).combat


## A fake player that holds each button of [param holds] ([code]Vector3i(button, from, to)[/code], which
## can be added later) facing [param yaw]. [param template] is its template (0 = the default one).
func _scripted(realm: int, position: Vector3, yaw: float, holds: Array[Vector3i], template: int = 0) -> int:
	var brain := CombatFixture.ScriptBrain.new(1)
	brain.script_fn = func(tick: int, _position: Vector3, _yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = yaw
		for entry: Vector3i in holds:
			if tick >= entry.y and tick < entry.z:
				input.buttons |= entry.x
		return input
	var net_id: int = _server().add_fake_player(brain, realm, template)
	_server().teleport(net_id, position)
	_rig.character(net_id).yaw = yaw
	return net_id


func _events_of(kind: int, net_id: int = -1) -> Array[NetMessages.EntityEvent]:
	var found: Array[NetMessages.EntityEvent] = []
	for event: NetMessages.EntityEvent in _events:
		if event.event == kind and (net_id < 0 or event.net_id == net_id):
			found.append(event)
	return found


func _advance_to(tick: int) -> void:
	var remaining: int = tick - _server().get_tick()
	if remaining > 0:
		await _rig.advance(remaining)


func _ticks_of(events: Array[NetMessages.EntityEvent]) -> Array[int]:
	var ticks: Array[int] = []
	for event: NetMessages.EntityEvent in events:
		ticks.append(event.tick)
	return ticks


# --- Drinking ---------------------------------------------------------------------------------

func test_the_health_potion_heals_in_six_pulses_of_fifty_after_drinking() -> void:
	await _start()
	var holds: Array[Vector3i] = []
	var drinker: int = _scripted(VARDHEIM, Vector3(0.0, 0.05, 0.0), 0.0, holds)
	await _rig.advance(3)
	var combatant: Combatant = _combatant(drinker)
	combatant.health = 500
	# In combat: without natural regeneration, which would muddy the numbers.
	combatant.mark_combat(_server().get_tick() + 1)
	var potion: AbilityTicks = CombatCatalog.ability(CombatCatalog.ability_id(&"potion_health"))
	var regen: int = CombatCatalog.status_id(&"potion_regen")
	assert_eq(_combat_of(drinker).charges_of(0), 3, "the squire carries 3 health potions")
	var press: int = _server().get_tick() + 2
	holds.append(Vector3i(PlayerInput.CONSUMABLE_1, press, press + 2))
	var commit: int = press + potion.cast_ticks
	await _advance_to(commit - 1)
	assert_eq(_combat_of(drinker).action, CombatState.Action.ABILITY, "drinking")
	assert_eq(_events_of(STATUS, drinker).size(), 0, "before the commit, nothing")
	await _advance_to(commit + 200)
	var applied: Array[NetMessages.EntityEvent] = _events_of(STATUS, drinker)
	if assert_true(not applied.is_empty(), "the healing over time starts when the drink finishes"):
		assert_eq(applied[0].status_id, regen)
		assert_eq(applied[0].tick, commit)
		assert_eq(applied[0].until_tick, commit + 180)
	var heals: Array[NetMessages.EntityEvent] = _events_of(HEAL, drinker)
	assert_eq(_ticks_of(heals), [commit + 30, commit + 60, commit + 90, commit + 120, commit + 150, commit + 180],
			"6 pulses, every 0.5 s")
	for heal: NetMessages.EntityEvent in heals:
		assert_eq(heal.amount, 50)
		assert_eq(heal.get_source(), CombatSource.make(CombatSource.Kind.STATUS, regen))
	assert_eq(combatant.health, 800, "300 in total")
	assert_eq(_combat_of(drinker).charges_of(0), 2, "spends a charge")
	assert_eq(_combat_of(drinker).consumable_ready_tick, commit + 1200, "and the shared cooldown of 20 s")


func test_a_hit_that_interrupts_drinking_spends_neither_the_charge_nor_the_cooldown() -> void:
	await _start()
	var attacker_holds: Array[Vector3i] = []
	var drinker_holds: Array[Vector3i] = []
	var attacker: int = _scripted(VARDHEIM, Vector3(0.0, 0.05, 0.0), 0.0, attacker_holds)
	var drinker: int = _scripted(SOLMARCH, Vector3(0.0, 0.05, -1.5), PI, drinker_holds)
	await _rig.advance(3)
	var potion: AbilityTicks = CombatCatalog.ability(CombatCatalog.ability_id(&"potion_health"))
	var light: AttackTicks = CombatCatalog.attack(CombatCatalog.attack_id(&"sword_light_1"))
	var drink: int = _server().get_tick() + 2
	drinker_holds.append(Vector3i(PlayerInput.CONSUMABLE_1, drink, drink + 2))
	attacker_holds.append(Vector3i(PlayerInput.PRIMARY, drink + 2, drink + 4))
	assert_true(drink + 2 + light.windup_ticks < drink + potion.cast_ticks, "the hit arrives before the commit")
	await _advance_to(drink + potion.cast_ticks + 10)
	var hits: Array[NetMessages.EntityEvent] = _events_of(HIT, drinker)
	if assert_eq(hits.size(), 1, "a hit"):
		assert_eq(hits[0].attacker, attacker)
		assert_true((hits[0].hit_flags & NetMessages.EntityEvent.HIT_FLAG_INTERRUPTED) != 0, "that interrupts (bit 5)")
	var combat: CombatState = _combat_of(drinker)
	assert_eq(combat.action, CombatState.Action.NONE, "stops drinking")
	assert_eq(combat.charges_of(0), 3, "without spending the charge")
	if not hits.is_empty():
		assert_eq(combat.consumable_ready_tick, hits[0].tick + AbilityTicks.REARM_TICKS,
				"nor the cooldown: only the margin so a remote player sees the NONE (H5 revision)")
	assert_eq(_events_of(STATUS, drinker).size(), 0, "nor healing")
	# And it can drink again right away.
	var again: int = _server().get_tick() + 2
	drinker_holds.append(Vector3i(PlayerInput.CONSUMABLE_1, again, again + 2))
	await _advance_to(again + potion.cast_ticks + 2)
	assert_eq(_combat_of(drinker).charges_of(0), 2, "this time it does")
	assert_eq(_events_of(STATUS, drinker).size(), 1)


# --- Camp refill ------------------------------------------------------------------------------

func test_the_camp_recharge_keeps_the_weapon_the_cooldowns_and_the_channel() -> void:
	await _start(func(world: Node3D) -> void:
		NpcRig.add_safe_area(world, &"vardheim", Vector3(0.0, 0.0, 0.0), 12.0))
	var marksman: int = CombatCatalog.template_id(&"marksman")
	var full: int = CombatCatalog.template_charges(marksman)
	assert_eq(full, CombatState.pack_charges(2, 3), "the shooter carries 2 and 3")
	var holds: Array[Vector3i] = []
	var archer: int = _scripted(VARDHEIM, Vector3(0.0, 0.05, 0.0), 0.0, holds, marksman)
	# Two others with spent charges: one outside the camp and one inside, but in combat.
	var outside: int = _scripted(VARDHEIM, Vector3(40.0, 0.05, 0.0), 0.0, [] as Array[Vector3i], marksman)
	var fighting: int = _scripted(VARDHEIM, Vector3(3.0, 0.05, 0.0), 0.0, [] as Array[Vector3i], marksman)
	await _rig.advance(3)
	var bow: int = CombatCatalog.weapon_id(&"bow")
	var sword: int = CombatCatalog.weapon_id(&"sword_shield")
	assert_eq([_combat_of(archer).weapon_id, _combat_of(archer).alt_weapon_id], [bow, sword], "bow and sword")
	# Switches to the sword (slot 2), throws the shield bash (leaves its cooldown) and raises the wall.
	var start: int = _server().get_tick() + 2
	holds.append(Vector3i(PlayerInput.SWAP_WEAPON, start, start + 2))
	holds.append(Vector3i(PlayerInput.ABILITY_1, start + 40, start + 42))
	var wall_from: int = start + 120
	holds.append(Vector3i(PlayerInput.ABILITY_3, wall_from, wall_from + 300))
	await _advance_to(wall_from + 20)
	var combat: CombatState = _combat_of(archer)
	assert_true(combat.is_second_slot(), "slot 2 active")
	assert_eq(combat.weapon_id, sword)
	assert_eq(combat.action, CombatState.Action.ABILITY, "with the wall raised")
	assert_eq(combat.action_id, CombatCatalog.ability_id(&"shield_wall"))
	assert_true(combat.ability_ready[0] > 0, "and the shield bash on cooldown")
	# Spent charges, without touching anything else.
	for net_id: int in [archer, outside, fighting]:
		ActionMachine.set_charges(_combat_of(net_id), CombatState.pack_charges(0, 1))
		CombatDirector.commit_state(_rig.character(net_id))
	_combatant(fighting).mark_combat(_server().get_tick() + 1)
	combat = _combat_of(archer)
	var before: Dictionary = {
		"weapon": combat.weapon_id, "alt": combat.alt_weapon_id, "flags2": combat.combat_flags2 & 1,
		"ready": combat.ability_ready.duplicate(), "action": combat.action, "action_id": combat.action_id,
		"action_tick": combat.action_tick,
	}
	var recharge: int = (_server().get_tick() / CombatDirector.RECHARGE_INTERVAL_TICKS + 1) \
			* CombatDirector.RECHARGE_INTERVAL_TICKS
	assert_true(recharge < wall_from + 12 + 360, "the refill falls with the wall still raised")
	_events.clear()
	_involved.clear()
	await _advance_to(recharge - 1)
	assert_eq(_combat_of(archer).consumable_charges, CombatState.pack_charges(0, 1), "not yet")
	await _advance_to(recharge)
	combat = _combat_of(archer)
	assert_eq(combat.consumable_charges, full, "on the refill tick, the charges full")
	assert_eq(combat.weapon_id, before["weapon"], "the weapon does not change")
	assert_eq(combat.alt_weapon_id, before["alt"])
	assert_eq(combat.combat_flags2 & 1, before["flags2"], "nor the active slot")
	assert_eq(combat.ability_ready, before["ready"], "nor the cooldowns")
	assert_eq(combat.action, before["action"], "nor the action in progress")
	assert_eq(combat.action_id, before["action_id"])
	assert_eq(combat.action_tick, before["action_tick"])
	var loadouts: Array[NetMessages.EntityEvent] = _events_of(LOADOUT, archer)
	if assert_eq(loadouts.size(), 1, "LOADOUT only to the owner"):
		assert_eq(loadouts[0].tick, recharge)
		assert_eq(loadouts[0].charges, full)
		assert_eq(loadouts[0].template_id, marksman)
		assert_eq([loadouts[0].weapon_1, loadouts[0].weapon_2], [bow, sword], "the weapons in slot order")
		assert_eq(_involved[_events.find(loadouts[0])], PackedInt32Array([archer]))
	assert_eq(_combat_of(outside).consumable_charges, CombatState.pack_charges(0, 1), "outside the camp, no")
	assert_eq(_combat_of(fighting).consumable_charges, CombatState.pack_charges(0, 1), "in combat, no")
	await _rig.advance(30)
	assert_eq(_combat_of(archer).action, CombatState.Action.ABILITY, "the wall remains")
	assert_eq(int(_server()._combat_report().get("recharges", -1)), 1)


func test_command_16_refills_the_charges_of_the_template() -> void:
	await _start()
	var ana: int = _scripted(VARDHEIM, Vector3(0.0, 0.05, 0.0), 0.0, [] as Array[Vector3i])
	await _rig.advance(3)
	ActionMachine.set_charges(_combat_of(ana), 0)
	CombatDirector.commit_state(_rig.character(ana))
	var peer := ServerPeer.new(3)
	peer.entity = _rig.entity(ana)
	var commands: CommandRegistry = _server().get_commands()
	_events.clear()
	assert_eq(commands.execute_network(peer, NetProtocol.DEBUG_REFILL, PackedByteArray([1])),
			CommandRegistry.Result.BAD_ARGUMENTS, "no data")
	assert_eq(commands.execute_network(peer, NetProtocol.DEBUG_REFILL, PackedByteArray()),
			CommandRegistry.Result.OK, "16")
	assert_eq(_combat_of(ana).consumable_charges, CombatCatalog.template_charges(CombatCatalog.template_id(&"squire")))
	var loadouts: Array[NetMessages.EntityEvent] = _events_of(LOADOUT, ana)
	if assert_eq(loadouts.size(), 1, "LOADOUT to the owner, only"):
		assert_eq(_involved[_events.find(loadouts[0])], PackedInt32Array([ana]))
	ActionMachine.set_charges(_combat_of(ana), 0)
	CombatDirector.commit_state(_rig.character(ana))
	assert_eq(_server().console_command("refill %d" % ana), "Cargas de %s repuestas" % _rig.entity(ana).display_name)
	assert_eq(_combat_of(ana).charges_of(0), 3)
	_server().console_command("kill %d" % ana)
	await _rig.advance(2)
	assert_eq(commands.execute_network(peer, NetProtocol.DEBUG_REFILL, PackedByteArray()),
			CommandRegistry.Result.REFUSED, "dead, no")


# --- LOADOUT over the network -----------------------------------------------------------------

func test_the_loadout_of_another_player_goes_out_with_zero_charges() -> void:
	var port: int = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(tree.root, "")
	var config := ServerConfig.new()
	config.port = port
	config.zone_id = "test_world"
	config.max_players = 8
	config.no_dummies = true
	var server: ZoneServer = NetHarness.start_server(_server_viewport, config)
	if not assert_not_null(server, "the server listens"):
		return
	await wait_physics_frames(3)
	var owner_client: NetClient = await _join_bot(server, port, VARDHEIM, 51)
	var observer: NetClient = await _join_bot(server, port, SOLMARCH, 52)
	if not assert_true(owner_client != null and observer != null, "both enter"):
		return
	var owner_id: int = owner_client.get_net_id()
	var seen_by_owner: Array[NetMessages.EntityEvent] = []
	var seen_by_observer: Array[NetMessages.EntityEvent] = []
	owner_client.combat_event.connect(func(event: NetMessages.EntityEvent, _own: bool) -> void:
		if event.event == LOADOUT and event.net_id == owner_id:
			seen_by_owner.append(event))
	observer.combat_event.connect(func(event: NetMessages.EntityEvent, _own: bool) -> void:
		if event.event == LOADOUT and event.net_id == owner_id:
			seen_by_observer.append(event))
	# The owner switches to the bow (command 5): its weapons change.
	var owner_name: String = server.get_registry().get_entity(owner_id).display_name
	assert_true(server.console_command("set_weapon %s bow" % owner_name).contains("lleva ahora"))
	var arrived: bool = false
	for _i: int in WAIT_FRAMES:
		await tree.physics_frame
		if not seen_by_owner.is_empty() and not seen_by_observer.is_empty():
			arrived = true
			break
	if not assert_true(arrived, "both receive the LOADOUT"):
		return
	var charges: int = server.get_combat().get_combatant(owner_id).get_character().combat.consumable_charges
	assert_true(charges != 0, "the owner carries potions")
	assert_eq(seen_by_owner[0].charges, charges, "the owner, with their charges")
	assert_eq(seen_by_observer[0].charges, 0, "the other one, with 0")
	for event: NetMessages.EntityEvent in [seen_by_owner[0], seen_by_observer[0]]:
		assert_eq(event.weapon_1, CombatCatalog.weapon_id(&"bow"), "the weapons, the same")
		# Without a platform, a bot is an ephemeral character with an inventory (progresion.md §9.4): template 0.
		assert_eq(event.template_id, 0, "the inventory equipment")
	# A refill (command 16; with an inventory, a forced CAMP_REFILL) does not change the weapons: only the owner.
	server.console_command("refill %s" % owner_name)
	for _i: int in 60:
		await tree.physics_frame
	assert_eq(seen_by_owner.size(), 2, "the owner receives the one from 16")
	assert_eq(seen_by_observer.size(), 1, "the other one does not")


func _join_bot(server: ZoneServer, port: int, realm: int, bot_seed: int) -> NetClient:
	var viewport: SubViewport = NetHarness.make_world_viewport(tree.root, "")
	_client_viewports.append(viewport)
	var client: NetClient = NetHarness.start_bot(viewport, port, realm, bot_seed)
	for _i: int in WAIT_FRAMES:
		await tree.physics_frame
		if client.get_net_id() > 0 and server.get_combat().get_combatant(client.get_net_id()) != null:
			return client
	return null
