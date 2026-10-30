extends TestCase
## Plantillas, cambio de arma y efectos de estado de punta a punta con ENet real sobre 127.0.0.1 (H5;
## docs/habilidades.md, secciones 4.6, 6.4 y 7.3): un [ZoneServer] y dos bots ([NetClient]) de Vardheim, cada uno
## en su [SubViewport] con su propio mundo de física. Lo que piden PRG-07, PRG-04/CMB-24 y UI-45:
## [br]- [b]PRG-07[/b]: Ana elige antes de CLIENT_READY una plantilla distinta de la de por defecto (el tirador, con
## [code]--loadout[/code]: LOADOUT_SELECT nada más llegar el WELCOME) y aparece ya con ella, con el arco en su
## predicción y en lo que ve Bruno (revisión de H5: antes elegía el escudero, que es la de por defecto, y la prueba
## pasaba aunque el servidor ignorase la elección). Después los dos eligen en el mundo (Bruno el tirador y Ana el
## escudero, que valen al reaparecer) y acaban con plantillas distintas, y cada uno ve las armas del otro (la pareja
## del SPAWN o del LOADOUT y la ranura activa del bit 3 del registro).
## [br]- [b]PRG-04 y CMB-24[/b]: con 100 ms de RTT y sin pérdida, Bruno cambia de arma seis veces con Q; el servidor las simula y su
## predicción no tiene ni una corrección en toda la ventana (que cubre ± el RTT de cada cambio), y Ana ve cambiar
## el arma activa de Bruno.
## [br]- [b]UI-45[/b]: un sangrado del comando 14 sale con su duración en la fila de efectos del HUD de Ana y en su
## placa en el HUD de Bruno, y se va de las dos al caducar.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const ZONE_ID: String = "test_world"
const WAIT_FRAMES: int = 900
const HUD_SCENE_PATH: String = "res://scenes/ui/hud.tscn"
const CAMERA_RIG_SCENE_PATH: String = "res://scenes/client/camera_rig.tscn"
## Retardo en el servidor sin pérdida (100 ms de RTT): la predicción va por delante del servidor y una diferencia
## en el cambio de arma se vería como una corrección.
const NET_SIM: String = "rtt=100,seed=3"
## Cambios de arma de Bruno y ticks entre dos pulsaciones de Q (el cambio dura 24).
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


## Un HUD de verdad para el bot [param client] (en su viewport): cámara que sigue a su personaje y mira a
## [param yaw], y el HUD atado al personaje, a la cámara y al cliente, como en [OnlineMain].
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
			"entran los dos"):
		return
	var ana_id: int = ana.get_net_id()
	var bruno_id: int = bruno.get_net_id()
	var squire: int = CombatCatalog.template_id(&"squire")
	var marksman: int = CombatCatalog.template_id(&"marksman")
	var sword: int = CombatCatalog.weapon_id(&"sword_shield")
	var bow: int = CombatCatalog.weapon_id(&"bow")
	for client: NetClient in _clients:
		_set_script(client, _idle)

	# --- PRG-07: Ana eligió antes de CLIENT_READY (no la de por defecto) y aparece con ella. ---------------
	assert_true(marksman != CombatCatalog.default_template_id(), "el tirador no es la plantilla por defecto")
	assert_eq(ana.get_stats()["loadout_selects"], 1, "Ana mandó su LOADOUT_SELECT antes de CLIENT_READY")
	assert_eq(_server.get_combat().get_combatant(ana_id).template_id, marksman,
			"y aparece con el tirador, sin reaparecer")
	assert_eq(_server_weapon(ana_id), bow, "con el arco en la mano en el servidor")
	assert_eq(ana.get_character().combat.weapon_id, bow, "y en su predicción desde el SPAWN")
	assert_eq(_server.get_combat().get_combatant(bruno_id).template_id, squire, "Bruno, con la de por defecto")
	var bruno_sees_ana: bool = await _wait_until(func() -> bool:
		var view: RemotePlayerView = bruno.get_remote_world().get_view(ana_id)
		return view != null and view.is_drawn() and view.get_weapons() == Vector2i(bow, sword), 300)
	assert_true(bruno_sees_ana, "Bruno ve a Ana con el arco y la espada")
	# --- Los dos eligen ya en el mundo: vale al reaparecer. -------------------------------------------------
	assert_true(bruno.send_loadout_select(marksman), "Bruno elige el tirador en el mundo")
	assert_true(ana.send_loadout_select(squire), "y Ana el escudero")
	assert_true(await _wait_until(func() -> bool:
			return _peer_of(bruno_id).pending_template_id == marksman \
					and _peer_of(ana_id).pending_template_id == squire, 120), "el servidor las anota como pendientes")
	assert_eq(_server_weapon(bruno_id), sword, "y no cambia nada hasta que reaparecen")
	assert_eq(_server_weapon(ana_id), bow)
	var timing: CombatTiming = _server.get_combat_timing()
	timing.respawn = 20
	timing.auto_respawn = 40
	_server.get_combat().kill(_server.get_combat().get_combatant(bruno_id), _server.get_tick() + 1)
	_server.get_combat().kill(_server.get_combat().get_combatant(ana_id), _server.get_tick() + 1)
	var respawned: bool = await _wait_until(func() -> bool:
		var combatant: Combatant = _server.get_combat().get_combatant(bruno_id)
		var ana_combatant: Combatant = _server.get_combat().get_combatant(ana_id)
		return combatant.is_alive() and combatant.template_id == marksman \
				and bruno.get_character().combat.weapon_id == bow \
				and ana_combatant.is_alive() and ana_combatant.template_id == squire \
				and ana.get_character().combat.weapon_id == sword, 600)
	if not assert_true(respawned, "Bruno reaparece con el tirador y Ana con el escudero, y sus predicciones ya lo llevan"):
		return
	# Cerca el uno del otro, y que se vean.
	_server.teleport(bruno_id, Vector3(0.0, 0.05, 0.0))
	_server.teleport(ana_id, Vector3(0.0, 0.05, -6.0))
	var each_sees: bool = await _wait_until(func() -> bool:
		var bruno_seen: RemotePlayerView = ana.get_remote_world().get_view(bruno_id)
		var ana_seen: RemotePlayerView = bruno.get_remote_world().get_view(ana_id)
		return bruno_seen != null and bruno_seen.is_drawn() and bruno_seen.get_weapons() == Vector2i(bow, sword) \
				and ana_seen != null and ana_seen.is_drawn() and ana_seen.get_weapons().x == sword, 300)
	if not assert_true(each_sees, "cada uno ve las armas del otro"):
		return
	assert_eq(ana.get_remote_world().get_view(bruno_id).get_active_weapon_id(), bow, "Ana ve a Bruno con el arco")
	assert_eq(bruno.get_remote_world().get_view(ana_id).get_active_weapon_id(), sword,
			"y Bruno a Ana con la espada y el escudo")

	# --- PRG-04 y CMB-24: seis cambios sin una sola corrección. ---------------------------------------------
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
	assert_eq(server_changes, SWAPS, "el servidor simula los seis cambios")
	assert_eq(_server_weapon(bruno_id), bow, "un número par: vuelve al arco")
	assert_eq(bruno.get_character().combat.weapon_id, bow, "y la predicción también")
	assert_eq(seen_changes, SWAPS, "Ana ve los seis cambios del arma activa de Bruno")
	assert_eq(after["diffs"], before["diffs"], "ninguna diferencia de predicción alrededor de los cambios")
	assert_eq(after["corrections"], before["corrections"], "ninguna corrección")
	assert_eq(after["hard_resets"], 0, "ningún reinicio duro")

	# --- UI-45: un sangrado del comando 14 en el HUD de Ana y en su placa en el de Bruno. ------------------
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
	if not assert_true(shown, "el sangrado sale en la fila de Ana y en su placa en el HUD de Bruno"):
		return
	var own: StatusIcons.StatusIcon = ana_hud.get_status_row().get_icon(0)
	assert_eq(own.status_id, bleed, "es el sangrado")
	var seconds: int = own.get_seconds_text().to_int()
	assert_true(seconds >= bleed_ticks / 60 - 1 and seconds <= bleed_ticks / 60,
			"con su duración: %s s de %d" % [own.get_seconds_text(), bleed_ticks / 60])
	assert_true(own.harmful, "y perjudica")
	var plate_icons: StatusIcons = bruno_hud.get_nameplates().get_plate_for(ana_id).get_status_icons()
	assert_eq(plate_icons.get_icon(0).status_id, bleed, "la placa enseña el sangrado")
	var gone: bool = await _wait_until(func() -> bool:
		ana_hud._process(0.016)
		bruno_hud.get_nameplates().refresh(0.016)
		var plate: Nameplate = bruno_hud.get_nameplates().get_plate_for(ana_id)
		return ana_hud.get_status_row().get_shown_count() == 0 and plate != null \
				and plate.get_status_icons().get_shown_count() == 0, bleed_ticks + 180)
	assert_true(gone, "y se va de los dos al caducar")
	assert_true(_server.get_combat().get_combatant(ana_id).health < 1000, "el sangrado hizo daño")
	assert_eq(ana.get_stats()["unexplained_diffs"], 0, "Ana predice sin fallos")
	assert_eq(bruno.get_stats()["unexplained_diffs"], 0, "Bruno también")
