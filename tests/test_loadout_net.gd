extends TestCase
## Templates, weapon swapping and status effects end to end with real ENet over 127.0.0.1 (H5;
## docs/habilidades.md, sections 4.6, 6.4 and 7.3): a [ZoneServer] and two Vardheim bots ([NetClient]), each
## in its own [SubViewport] with its own physics world. What PRG-07, PRG-04/CMB-24 and UI-45 require:
## [br]- [b]PRG-07[/b]: before CLIENT_READY, Ana chooses a template other than the default (the marksman, with
## [code]--loadout[/code]: LOADOUT_SELECT as soon as the WELCOME arrives) and appears already with it, with the bow in her
## prediction and in what Bruno sees (H5 review: before, she chose the squire, which is the default, and the test
## passed even if the server ignored the choice). Since progresion.md P5b the chosen template is the starter kit
## of the ephemeral character and its inventory equips it: in the world LOADOUT_SELECT no longer changes anything, and Bruno puts on the
## bow from his bag into WEAPON_2 with an INVENTORY_REQUEST. Each sees the other's weapons (the SPAWN's or
## LOADOUT's pair and the active slot from bit 3 of the record).
## [br]- [b]PRG-04 and CMB-24[/b]: with 100 ms of RTT and no loss, Bruno swaps weapons six times with Q; the server simulates them and his
## prediction has not a single correction in the whole window (which covers ± the RTT of each swap), and Ana sees
## Bruno's active weapon change.
## [br]- [b]UI-45[/b]: a bleed from command 14 shows up with its duration in the effects row of Ana's HUD and on his
## nameplate in Bruno's HUD, and disappears from both on expiry.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const BAG: int = InventoryState.ContainerId.BAG
const EQUIPMENT: int = InventoryState.ContainerId.EQUIPMENT
const ZONE_ID: String = "test_world"
const WAIT_FRAMES: int = 900
const HUD_SCENE_PATH: String = "res://scenes/ui/hud.tscn"
const CAMERA_RIG_SCENE_PATH: String = "res://scenes/client/camera_rig.tscn"
## Delay on the server with no loss (100 ms of RTT): the prediction runs ahead of the server and a difference
## in the weapon swap would be seen as a correction.
const NET_SIM: String = "rtt=100,seed=3"
## Bruno's weapon swaps and ticks between two Q presses (the swap lasts 24).
const SWAPS: int = 6
const SWAP_GAP_TICKS: int = 50

var _root: Node
var _server_viewport: SubViewport
var _server: ZoneServer
var _clients: Array[NetClient] = []
var _viewports: Array[SubViewport] = []


func before_each() -> void:
	_root = Node.new()
	_root.name = "LoadoutNet"
	tree.root.add_child(_root)


func after_each() -> void:
	for viewport: SubViewport in _viewports:
		if is_instance_valid(viewport):
			viewport.free()
	_viewports.clear()
	_clients.clear()
	if is_instance_valid(_server_viewport):
		_server_viewport.free()
	_server_viewport = null
	_server = null
	if is_instance_valid(_root):
		tree.root.remove_child(_root)
		_root.free()
	_root = null
	await wait_process_frames()


func _wait_until(condition: Callable, max_frames: int = WAIT_FRAMES) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await tree.physics_frame
	return condition.call()


func _set_script(client: NetClient, script: Callable) -> void:
	var brain := CombatFixture.ScriptBrain.new(1)
	brain.script_fn = script
	(client.get_meta(&"controller") as LocalPlayerController).set_bot(brain)


func _idle(tick: int, _position: Vector3, yaw: float) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = yaw
	return input


## A real HUD for the bot [param client] (in its viewport): camera that follows its character and looks at
## [param yaw], and the HUD bound to the character, the camera and the client, as in [OnlineMain].
func _make_hud(client: NetClient, viewport: SubViewport, yaw: float) -> HUD:
	var character: PlayerCharacter = client.get_character()
	var rig: CameraRig = (load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate() as CameraRig
	viewport.add_child(rig)
	rig.set_scripted_look(true)
	rig.set_target(character.get_camera_target(), character)
	rig.set_look(yaw, 0.0)
	var hud: HUD = (load(HUD_SCENE_PATH) as PackedScene).instantiate() as HUD
	viewport.add_child(hud)
	hud.bind(character, rig)
	hud.bind_net(client, NetHarness.get_world(viewport))
	return hud


func _server_weapon(net_id: int) -> int:
	return _server.get_registry().get_entity(net_id).get_character().combat.weapon_id


## The definition of the object of [param net_id] in that slot (progresion.md P5b), or empty.
func _slot_def(net_id: int, container: int, slot: int) -> StringName:
	var item: ItemInstance = _server.get_progress().get_player(net_id).record.inventory.get_item(container, slot)
	return item.def_id if item != null else &""


func _peer_of(net_id: int) -> ServerPeer:
	for peer_id: int in _server.get_peer_ids():
		var peer: ServerPeer = _server.get_peer(peer_id)
		if peer.entity != null and peer.entity.net_id == net_id:
			return peer
	return null


func test_templates_weapon_swaps_and_a_bleed_over_the_network() -> void:
	var port: int = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, "")
	var config := ServerConfig.new()
	config.port = port
	config.zone_id = ZONE_ID
	config.max_players = 8
	config.debug_commands = true
	config.net_sim_spec = NET_SIM
	_server = NetHarness.start_server(_server_viewport, config)
	await wait_physics_frames(3)
	for entry: Array in [[1, "marksman"], [2, ""]]:
		var viewport: SubViewport = NetHarness.make_world_viewport(_root, "")
		_viewports.append(viewport)
		_clients.append(NetHarness.start_bot(viewport, port, VARDHEIM, entry[0], "", "", "", entry[1]))
	var ana: NetClient = _clients[0]
	var bruno: NetClient = _clients[1]
	if not assert_true(await _wait_until(func() -> bool:
			return ana.get_state() == NetClient.State.IN_WORLD and bruno.get_state() == NetClient.State.IN_WORLD),
			"both enter"):
		return
	var ana_id: int = ana.get_net_id()
	var bruno_id: int = bruno.get_net_id()
	var marksman: int = CombatCatalog.template_id(&"marksman")
	var sword: int = CombatCatalog.weapon_id(&"sword_shield")
	var bow: int = CombatCatalog.weapon_id(&"bow")
	for client: NetClient in _clients:
		_set_script(client, _idle)

	# --- PRG-07: Ana chose before CLIENT_READY (not the default) and appears with it. ---------------
	# Without a platform both are ephemeral characters with an inventory (progresion.md §9.4, P5b): the chosen template is
	# their starter kit and their inventory equips them (current template 0, "the inventory's equipment").
	assert_true(marksman != CombatCatalog.default_template_id(), "the marksman is not the default template")
	assert_eq(ana.get_stats()["loadout_selects"], 1, "Ana sent her LOADOUT_SELECT before CLIENT_READY")
	var progress: ProgressService = _server.get_progress()
	assert_true(progress.has_inventory(ana_id) and progress.has_inventory(bruno_id), "both, with an inventory")
	assert_eq(_server.get_combat().get_combatant(ana_id).template_id, 0, "the equipment of their inventory")
	assert_eq(_slot_def(ana_id, EQUIPMENT, 0), &"bow_vado", "with the marksman's kit, without respawning")
	assert_eq(_server_weapon(ana_id), bow, "with the bow in hand on the server")
	assert_eq(ana.get_character().combat.weapon_id, bow, "and in her prediction since the SPAWN")
	assert_eq([_slot_def(bruno_id, EQUIPMENT, 0), _slot_def(bruno_id, BAG, 0)], [&"sword_shield_vado", &"bow_vado"],
			"Bruno, with the default's kit (squire): the sword equipped and the bow in the bag")
	var bruno_sees_ana: bool = await _wait_until(func() -> bool:
		var view: RemotePlayerView = bruno.get_remote_world().get_view(ana_id)
		return view != null and view.is_drawn() and view.get_weapons() == Vector2i(bow, sword), 300)
	assert_true(bruno_sees_ana, "Bruno sees Ana with the bow and the sword")
	# --- In the world: LOADOUT_SELECT no longer changes anything; Bruno equips the bow from his bag in WEAPON_2. -------
	assert_true(bruno.send_loadout_select(marksman), "Bruno chooses the marksman in the world")
	await wait_physics_frames(30)
	assert_eq(_peer_of(bruno_id).pending_template_id, -1, "with an inventory nothing is left pending")
	var bow_uid: int = progress.get_player(bruno_id).record.inventory.get_item(BAG, 0).uid
	assert_true(bruno.send_inventory_request(ProgressMessages.InventoryRequest.from_request(1,
			InventoryOps.make_request(InventoryOps.Op.MOVE, BAG, 0, EQUIPMENT, 1, 0, bow_uid))),
			"Bruno asks to equip the bow")
	var equipped: bool = await _wait_until(func() -> bool:
		return _server.get_registry().get_entity(bruno_id).get_character().combat.alt_weapon_id == bow \
				and bruno.get_character().combat.alt_weapon_id == bow, 300)
	if not assert_true(equipped, "the server equips it and his prediction picks it up through the LOADOUT"):
		return
	assert_eq(_server_weapon(bruno_id), sword, "with the sword in hand")
	# Close to each other, so they can see each other.
	_server.teleport(bruno_id, Vector3(0.0, 0.05, 0.0))
	_server.teleport(ana_id, Vector3(0.0, 0.05, -6.0))
	var each_sees: bool = await _wait_until(func() -> bool:
		var bruno_seen: RemotePlayerView = ana.get_remote_world().get_view(bruno_id)
		var ana_seen: RemotePlayerView = bruno.get_remote_world().get_view(ana_id)
		return bruno_seen != null and bruno_seen.is_drawn() and bruno_seen.get_weapons() == Vector2i(sword, bow) \
				and ana_seen != null and ana_seen.is_drawn() and ana_seen.get_weapons() == Vector2i(bow, sword), 300)
	if not assert_true(each_sees, "each sees the other's weapons"):
		return
	assert_eq(ana.get_remote_world().get_view(bruno_id).get_active_weapon_id(), sword,
			"Ana sees Bruno with the sword and shield")
	assert_eq(bruno.get_remote_world().get_view(ana_id).get_active_weapon_id(), bow, "and Bruno sees Ana with the bow")

	# --- PRG-04 and CMB-24: six swaps without a single correction. ---------------------------------------------
	await wait_physics_frames(30)
	var before: Dictionary = bruno.get_stats()
	var rtt: int = int(before["rtt_ticks"])
	var first_press: int = bruno.get_prediction().get_predicted_tick() + 20
	_set_script(bruno, func(tick: int, _position: Vector3, yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = yaw
		var since: int = tick - first_press
		if since >= 0 and since < SWAPS * SWAP_GAP_TICKS and since % SWAP_GAP_TICKS < 2:
			input.buttons = PlayerInput.SWAP_WEAPON
		return input)
	var server_changes: int = 0
	var last_weapon: int = _server_weapon(bruno_id)
	var seen_changes: int = 0
	var last_seen: int = ana.get_remote_world().get_view(bruno_id).get_active_weapon_id()
	for _frame: int in SWAPS * SWAP_GAP_TICKS + 20 + 3 * rtt + 60:
		await tree.physics_frame
		var weapon: int = _server_weapon(bruno_id)
		if weapon != last_weapon:
			server_changes += 1
			last_weapon = weapon
		var seen: int = ana.get_remote_world().get_view(bruno_id).get_active_weapon_id()
		if seen != last_seen:
			seen_changes += 1
			last_seen = seen
	var after: Dictionary = bruno.get_stats()
	print("[plantillas] rtt %d ticks; cambios en el servidor %d, vistos por Ana %d; diffs %d -> %d, correcciones %d -> %d" % [
			rtt, server_changes, seen_changes, before["diffs"], after["diffs"], before["corrections"],
			after["corrections"]])
	assert_eq(server_changes, SWAPS, "the server simulates the six swaps")
	assert_eq(_server_weapon(bruno_id), sword, "an even number: back to the sword")
	assert_eq(bruno.get_character().combat.weapon_id, sword, "and the prediction too")
	assert_eq(seen_changes, SWAPS, "Ana sees the six changes of Bruno's active weapon")
	assert_eq(after["diffs"], before["diffs"], "no prediction difference around the swaps")
	assert_eq(after["corrections"], before["corrections"], "no correction")
	assert_eq(after["hard_resets"], 0, "no hard reset")

	# --- UI-45: a bleed from command 14 in Ana's HUD and on his nameplate in Bruno's. ------------------
	var ana_hud: HUD = _make_hud(ana, _viewports[0], 0.0)
	var bruno_hud: HUD = _make_hud(bruno, _viewports[1], 0.0)
	await wait_physics_frames(10)
	var bleed: int = CombatCatalog.status_id(&"bleed")
	var bleed_ticks: int = CombatCatalog.status(bleed).duration_ticks
	ana.send_debug_command(NetProtocol.DEBUG_APPLY_STATUS, NetMessages.DebugCommand.apply_status(bleed).payload)
	var shown: bool = await _wait_until(func() -> bool:
		ana_hud._process(0.016)
		bruno_hud.get_nameplates().refresh(0.016)
		var plate: Nameplate = bruno_hud.get_nameplates().get_plate_for(ana_id)
		return ana_hud.get_status_row().get_shown_count() == 1 and plate != null \
				and plate.get_status_icons().get_shown_count() == 1, 240)
	if not assert_true(shown, "the bleed shows in Ana's row and on his nameplate in Bruno's HUD"):
		return
	var own: StatusIcons.StatusIcon = ana_hud.get_status_row().get_icon(0)
	assert_eq(own.status_id, bleed, "it is the bleed")
	var seconds: int = own.get_seconds_text().to_int()
	assert_true(seconds >= bleed_ticks / 60 - 1 and seconds <= bleed_ticks / 60,
			"with its duration: %s s of %d" % [own.get_seconds_text(), bleed_ticks / 60])
	assert_true(own.harmful, "and it is harmful")
	var plate_icons: StatusIcons = bruno_hud.get_nameplates().get_plate_for(ana_id).get_status_icons()
	assert_eq(plate_icons.get_icon(0).status_id, bleed, "the nameplate shows the bleed")
	var gone: bool = await _wait_until(func() -> bool:
		ana_hud._process(0.016)
		bruno_hud.get_nameplates().refresh(0.016)
		var plate: Nameplate = bruno_hud.get_nameplates().get_plate_for(ana_id)
		return ana_hud.get_status_row().get_shown_count() == 0 and plate != null \
				and plate.get_status_icons().get_shown_count() == 0, bleed_ticks + 180)
	assert_true(gone, "and it disappears from both on expiry")
	assert_true(_server.get_combat().get_combatant(ana_id).health < 1000, "the bleed did damage")
	assert_eq(ana.get_stats()["unexplained_diffs"], 0, "Ana predicts without failures")
	assert_eq(bruno.get_stats()["unexplained_diffs"], 0, "Bruno too")
