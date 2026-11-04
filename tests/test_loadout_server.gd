extends TestCase
## Tests for the loadout templates on the server (PRG-07, PRG-04; docs/abilities.md, sections 3.5, 4.6 and
## 5.1; package H3c): the player appears with the default template or with the one given
## ([code]--fake-loadout[/code]) and announces it with LOADOUT (the owner's with charges and the public one without them);
## LOADOUT_SELECT before CLIENT_READY decides the template at spawn (since progression.md P5b, the starter kit of the
## ephemeral character, which goes with the equipment of its inventory and no longer changes in the world), and an id that does not exist or
## cannot be chosen counts a warning; command 5 puts the weapon in slot 1 and keeps slot 2, with its LOADOUT, and is not valid
## for a knocked-down player.
## [br][br]
## Fake players and peers assembled by hand (no network) on the flat zone of [ZoneFixture] ([NpcRig] setup).

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const LOADOUT: int = NetMessages.EntityEvent.Kind.LOADOUT
const PEER_ID: int = 77

var _rig: NpcRig = null
var _events: Array[NetMessages.EntityEvent] = []
var _involved: Array[PackedInt32Array] = []
# Test templates added to the catalogue tables (removed in after_each).
var _injected: int = 0


func before_each() -> void:
	_rig = NpcRig.new()
	_events.clear()
	_involved.clear()


func after_each() -> void:
	var tables: CombatTables = CombatCatalog.tables()
	while _injected > 0:
		tables.templates.pop_back()
		tables.template_weapon_ids.pop_back()
		tables.template_charges.resize(tables.template_charges.size() - 1)
		_injected -= 1
	if _rig != null:
		await _rig.stop()
	_rig = null
	await wait_process_frames()


# --- Helpers ----------------------------------------------------------------------------------

func _start() -> void:
	await _rig.start_flat(tree)
	_rig.server.get_combat().event_emitted.connect(func(event: NetMessages.EntityEvent,
			involved: PackedInt32Array) -> void:
		_events.append(event)
		_involved.append(involved))


func _server() -> ZoneServer:
	return _rig.server


func _combat_of(net_id: int) -> CombatState:
	return _rig.character(net_id).combat


func _loadouts(net_id: int) -> Array[NetMessages.EntityEvent]:
	var found: Array[NetMessages.EntityEvent] = []
	for event: NetMessages.EntityEvent in _events:
		if event.event == LOADOUT and event.net_id == net_id:
			found.append(event)
	return found


func _involved_of(event: NetMessages.EntityEvent) -> PackedInt32Array:
	return _involved[_events.find(event)]


func _weapon(weapon_name: StringName) -> int:
	return CombatCatalog.weapon_id(weapon_name)


func _template(template_name: StringName) -> int:
	return CombatCatalog.template_id(template_name)


## Checks the two LOADOUTs of a weapon change: the owner's (them involved, with [param charges]) and the public one
## (no one involved, with 0 charges), with [param template] and the weapons [param weapons].
func _assert_pair(events: Array[NetMessages.EntityEvent], net_id: int, template: int, weapons: Array[int],
		charges: int) -> void:
	if not assert_eq(events.size(), 2, "the owner's and the public one"):
		return
	for event: NetMessages.EntityEvent in events:
		assert_eq(event.template_id, template, "template")
		assert_eq([event.weapon_1, event.weapon_2], weapons, "weapons in slot order")
	assert_eq(events[0].charges, charges, "the owner, with their charges")
	assert_eq(_involved_of(events[0]), PackedInt32Array([net_id]))
	assert_eq(events[1].charges, 0, "the others, without them")
	assert_eq(_involved_of(events[1]), PackedInt32Array(), "to whoever has it as relevant")


## A peer that has just received the WELCOME (loading the zone), assembled by hand on the server.
func _loading_peer(peer_name: String, realm: int) -> ServerPeer:
	var peer := ServerPeer.new(PEER_ID)
	peer.state = ServerPeer.State.LOADING
	peer.realm = realm
	peer.display_name = peer_name
	peer.loading_since_tick = _server().get_tick()
	_server()._peers[PEER_ID] = peer
	return peer


func _select(template_id: int) -> void:
	_server()._on_packet_received(PEER_ID, NetMessages.LoadoutSelect.make(template_id).encode())


## Adds to the tables a template that cannot be chosen (after_each removes it) and returns its id.
func _inject_unselectable() -> int:
	var tables: CombatTables = CombatCatalog.tables()
	var template := EquipmentTemplate.new()
	template.id = &"prueba_no_elegible"
	template.selectable = false
	tables.templates.append(template)
	tables.template_weapon_ids.append(PackedInt32Array([_weapon(&"sword_shield")]))
	tables.template_charges.append(0)
	_injected += 1
	return tables.templates.size()


# --- On spawning ------------------------------------------------------------------------------

func test_a_player_appears_with_the_default_template_and_announces_it() -> void:
	await _start()
	var squire: int = _template(&"squire")
	assert_eq(CombatCatalog.default_template_id(), squire, "the squire is the default")
	var ana: int = _server().add_fake_player(CombatFixture.ScriptBrain.new(1), VARDHEIM)
	var combat: CombatState = _combat_of(ana)
	assert_eq(_server().get_combat().get_combatant(ana).template_id, squire)
	assert_eq([combat.weapon_id, combat.alt_weapon_id], [_weapon(&"sword_shield"), 0])
	assert_false(combat.is_second_slot())
	assert_eq(combat.consumable_charges, CombatState.pack_charges(3, 2), "3 and 2 potions")
	_assert_pair(_loadouts(ana), ana, squire, [_weapon(&"sword_shield"), 0], CombatState.pack_charges(3, 2))
	# --fake-loadout: the marksman.
	var marksman: int = _template(&"marksman")
	var bo: int = _server().add_fake_player(CombatFixture.ScriptBrain.new(2), SOLMARCH, marksman)
	combat = _combat_of(bo)
	assert_eq([combat.weapon_id, combat.alt_weapon_id], [_weapon(&"bow"), _weapon(&"sword_shield")],
			"bow active and sword in slot 2")
	assert_eq(combat.consumable_charges, CombatState.pack_charges(2, 3))
	_assert_pair(_loadouts(bo), bo, marksman, [_weapon(&"bow"), _weapon(&"sword_shield")],
			CombatState.pack_charges(2, 3))
	# The other player's SPAWN already carries both weapons.
	var spawn: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(
			_rig.entity(bo).encode_spawn(_server().get_tick(), false))
	assert_eq(spawn.state.combat.alt_weapon_id, _weapon(&"sword_shield"))
	assert_eq(spawn.state.combat.consumable_charges, 0, "without the charges")


func test_loadout_select_before_client_ready_decides_the_template_of_the_arrival() -> void:
	await _start()
	var marksman: int = _template(&"marksman")
	var peer: ServerPeer = _loading_peer("Ana", SOLMARCH)
	assert_eq(peer.pending_template_id, -1, "no request")
	var strikes: int = peer.strikes_total
	_select(marksman)
	assert_eq(peer.pending_template_id, marksman, "recorded while the zone loads")
	assert_eq(peer.strikes_total, strikes, "no warning")
	_select(200)
	assert_eq(peer.strikes_total, strikes + 1, "one that does not exist counts a warning")
	assert_eq(peer.pending_template_id, marksman, "and changes nothing")
	_select(_inject_unselectable())
	assert_eq(peer.strikes_total, strikes + 2, "one that cannot be chosen, too")
	assert_eq(peer.pending_template_id, marksman)
	_server()._on_packet_received(PEER_ID, PackedByteArray([NetProtocol.MSG_LOADOUT_SELECT]))
	assert_eq(peer.strikes_total, strikes + 3, "malformed, another")
	# CLIENT_READY: it appears at the end of the next tick with the bow. Without a platform it is an ephemeral character with an
	# inventory (progression.md §9.4, P5b): the requested template is its starter kit and its inventory equips it
	# (current template 0 in LOADOUT, "the inventory's equipment"), with the charges of the potions in its bag.
	_server()._pending_ready.append(PEER_ID)
	await _rig.advance(1)
	if not assert_not_null(peer.entity, "in the world"):
		return
	var net_id: int = peer.entity.net_id
	var combatant: Combatant = _server().get_combat().get_combatant(net_id)
	assert_true(_server().get_progress().has_inventory(net_id), "with an inventory")
	assert_eq(combatant.template_id, 0, "the inventory's equipment, with the kit of the requested template")
	assert_eq(peer.pending_template_id, -1, "which stops being pending")
	assert_eq([_combat_of(net_id).weapon_id, _combat_of(net_id).alt_weapon_id],
			[_weapon(&"bow"), _weapon(&"sword_shield")])
	_assert_pair(_loadouts(net_id), net_id, 0, [_weapon(&"bow"), _weapon(&"sword_shield")],
			CombatState.pack_charges(3, 2))
	# With an inventory, LOADOUT_SELECT no longer changes anything after spawning (progression.md §2.5), nor the next
	# spawn; an id that does not exist still adds its warning.
	_select(0)
	assert_eq(peer.pending_template_id, -1, "nothing is left pending")
	assert_eq(peer.strikes_total, strikes + 3, "0 does not count a warning")
	_select(200)
	assert_eq(peer.strikes_total, strikes + 4, "one that does not exist, yes")
	_server().console_command("kill %d" % net_id)
	await _rig.advance(2)
	var wait: int = combatant.respawn_tick - _server().get_tick()
	await _rig.advance(maxi(wait, 0) + 2)
	_events.clear()
	_involved.clear()
	assert_eq(_server().get_combat().request_respawn(net_id, 0, _server().get_tick() + 1),
			CombatDirector.RespawnRequestResult.ACCEPTED)
	await _rig.advance(3)
	assert_true(combatant.is_alive(), "respawns")
	assert_eq(combatant.template_id, 0, "with its equipment")
	assert_eq([_combat_of(net_id).weapon_id, _combat_of(net_id).alt_weapon_id],
			[_weapon(&"bow"), _weapon(&"sword_shield")], "the same weapons")
	assert_eq(_combat_of(net_id).consumable_charges, CombatState.pack_charges(3, 2))
	var loadouts: Array[NetMessages.EntityEvent] = _loadouts(net_id)
	if assert_eq(loadouts.size(), 1, "no weapon change, LOADOUT only to the owner"):
		assert_eq([loadouts[0].template_id, loadouts[0].weapon_1, loadouts[0].weapon_2],
				[0, _weapon(&"bow"), _weapon(&"sword_shield")])


func test_reappearing_with_the_same_template_only_tells_the_owner() -> void:
	await _start()
	var ana: int = _server().add_fake_player(CombatFixture.ScriptBrain.new(1), VARDHEIM)
	var combatant: Combatant = _server().get_combat().get_combatant(ana)
	# Let the test request it, like a person (a fake only requests it on dying).
	combatant.requests_respawn_on_death = false
	_server().console_command("kill %d" % ana)
	await _rig.advance(2)
	await _rig.advance(maxi(combatant.respawn_tick - _server().get_tick(), 0) + 2)
	_events.clear()
	_involved.clear()
	assert_eq(_server().get_combat().request_respawn(ana, 0, _server().get_tick() + 1),
			CombatDirector.RespawnRequestResult.ACCEPTED)
	await _rig.advance(3)
	var loadouts: Array[NetMessages.EntityEvent] = _loadouts(ana)
	if assert_eq(loadouts.size(), 1, "the weapons do not change: only the owner's"):
		assert_eq(_involved_of(loadouts[0]), PackedInt32Array([ana]))
		assert_eq(loadouts[0].charges, CombatState.pack_charges(3, 2), "with the charges full again")


# --- Command 5 --------------------------------------------------------------------------------

func test_command_5_puts_the_weapon_in_slot_one_and_keeps_the_second() -> void:
	await _start()
	var marksman: int = _template(&"marksman")
	var ana: int = _server().add_fake_player(CombatFixture.ScriptBrain.new(1), VARDHEIM, marksman)
	await _rig.advance(3)
	var combat: CombatState = _combat_of(ana)
	combat.ability_ready[1] = _server().get_tick() + 500
	combat.consumable_charges = CombatState.pack_charges(1, 1)
	CombatDirector.commit_state(_rig.character(ana))
	var peer := ServerPeer.new(3)
	peer.entity = _rig.entity(ana)
	_events.clear()
	_involved.clear()
	var hollow_weapon: int = _weapon(&"npc_hollow")
	var payload := PackedByteArray()
	payload.resize(2)
	payload.encode_u16(0, hollow_weapon)
	assert_eq(_server().get_commands().execute_network(peer, NetProtocol.DEBUG_SET_WEAPON, payload),
			CommandRegistry.Result.OK)
	combat = _combat_of(ana)
	assert_eq([combat.weapon_id, combat.alt_weapon_id], [hollow_weapon, _weapon(&"sword_shield")],
			"the new weapon in slot 1, slot 2 stays")
	assert_eq(combat.ability_ready, PackedInt64Array([0, 0, 0, 0, 0, 0]), "reuse timers at 0 (set_loadout)")
	assert_eq(combat.consumable_charges, CombatState.pack_charges(1, 1), "the charges do not change")
	_assert_pair(_loadouts(ana), ana, marksman, [hollow_weapon, _weapon(&"sword_shield")],
			CombatState.pack_charges(1, 1))
	# The same as slot 2: it stays alone.
	assert_true(_server().console_command("set_weapon %d sword_shield" % ana).contains("lleva ahora"))
	assert_eq([_combat_of(ana).weapon_id, _combat_of(ana).alt_weapon_id], [_weapon(&"sword_shield"), 0])
	payload.encode_u16(0, 999)
	assert_eq(_server().get_commands().execute_network(peer, NetProtocol.DEBUG_SET_WEAPON, payload),
			CommandRegistry.Result.BAD_ARGUMENTS, "a weapon that does not exist")
	# Knocked down, no: set_loadout would put it in NONE.
	assert_true(_server().get_combat().down(_server().get_combat().get_combatant(ana), _server().get_tick() + 1))
	payload.encode_u16(0, hollow_weapon)
	assert_eq(_server().get_commands().execute_network(peer, NetProtocol.DEBUG_SET_WEAPON, payload),
			CommandRegistry.Result.REFUSED, "knocked down")
	assert_eq(_combat_of(ana).action, CombatState.Action.DOWNED)


# --- --fake-loadout ---------------------------------------------------------------------------

func test_fake_loadout_gives_the_template_to_a_share_of_the_fakes_in_order() -> void:
	var all: ServerConfig = ServerConfig.from_args(PackedStringArray(["--fake-loadout=marksman"]))
	var marksman: int = _template(&"marksman")
	assert_eq(all.fake_loadout, &"marksman")
	assert_eq(all.fake_loadout_percent, 100)
	assert_eq([all.fake_template_for(0), all.fake_template_for(1), all.fake_template_for(2)],
			[marksman, marksman, marksman], "to everyone")
	var half: ServerConfig = ServerConfig.from_args(PackedStringArray(["--fake-loadout=marksman:50"]))
	var given: Array[int] = []
	for index: int in 6:
		given.append(half.fake_template_for(index))
	assert_eq(given, [0, marksman, 0, marksman, 0, marksman], "with 50, one in two")
	var none: ServerConfig = ServerConfig.from_args(PackedStringArray())
	assert_eq(none.fake_template_for(0), 0, "without the option, the default")
	for invalid: String in ["--fake-loadout=hacha", "--fake-loadout=marksman:0", "--fake-loadout=marksman:101",
			"--fake-loadout=marksman:x", "--fake-loadout=marksman:50:2", "--fake-loadout="]:
		var config: ServerConfig = ServerConfig.from_args(PackedStringArray([invalid]))
		assert_eq(config.fake_loadout, &"", "%s is ignored" % invalid)
		assert_eq(config.fake_template_for(1), 0)
