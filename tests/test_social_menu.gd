extends TestCase
## Tests for social actions on the player under the crosshair (SOC-07, docs/social.md section 12.6):
## the ray against remotes at 20 m ([SocialTarget.find], with the real action camera and synthetic
## remotes; only living allies, with a human's name and without a wall in front), which options each player
## offers ([SocialTarget.options_for]: invite and whisper an ally, only whisper a party member, nothing with an
## enemy), the menu ([SocialMenu]) and the [HUD] key, which gives the same notice with an enemy, behind a wall or
## with nobody.

const CAMERA_RIG_SCENE_PATH: String = "res://scenes/client/camera_rig.tscn"
const HUD_SCENE_PATH: String = "res://scenes/ui/hud.tscn"
const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ALLY_ID: int = 31
const OTHER_ID: int = 32
const ENEMY_ID: int = 41
const FAKE_ID: int = 51


## Clock whose render tick is set from the test.
class FakeClock extends InterpolationClock:
	var render: float = 0.0

	func get_render_tick() -> float:
		return render


## Network client that connects to nothing: provides the remote world and the character and records the invitations.
class FakeClient extends NetClient:
	var fake_config: ClientConfig = ClientConfig.new()
	var fake_character: PlayerCharacter = null
	var fake_world: RemoteWorld = null
	var invited: Array[String] = []

	func get_config() -> ClientConfig:
		return fake_config

	func get_character() -> PlayerCharacter:
		return fake_character

	func get_remote_world() -> RemoteWorld:
		return fake_world

	func send_party_invite(target_name: String) -> bool:
		invited.append(target_name)
		return true


var _root: Node3D
var _remote_world: RemoteWorld
var _clock: FakeClock
var _rig: CameraRig
var _client: FakeClient
var _nodes: Array[Node] = []
var _tick: int = 1


func before_each() -> void:
	_nodes.clear()
	_root = Node3D.new()
	_root.name = "SocialMenuTest"
	tree.root.add_child(_root)
	_clock = FakeClock.new()
	_remote_world = RemoteWorld.new()
	_remote_world.install_visuals = false
	_remote_world.setup(_clock)
	_root.add_child(_remote_world)
	_rig = (load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate() as CameraRig
	_rig.set_scripted_look(true)
	_root.add_child(_rig)
	_rig.global_position = Vector3(0.0, 1.6, 0.0)
	_rig.set_look(0.0, 0.0)
	_rig._process(0.016)
	_client = _track(FakeClient.new()) as FakeClient
	_client.fake_config.display_name = "Ana"
	_client.fake_config.realm = VARDHEIM
	_client.fake_world = _remote_world
	_tick = 1
	InputBindings.ensure_defaults()


func after_each() -> void:
	for node: Node in _nodes:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()
	_nodes.clear()
	if is_instance_valid(_root):
		tree.root.remove_child(_root)
		_root.free()
	_root = null
	_rig = null
	_remote_world = null
	await wait_process_frames()


# --- Helpers ----------------------------------------------------------------------------------

func _track(node: Node) -> Node:
	tree.root.add_child(node)
	_nodes.append(node)
	return node


## A remote of [param kind] and [param realm] with [param player_name] at [param feet], already being drawn with health
## [param health_q] (0 = dead).
func _spawn(net_id: int, realm: int, player_name: String, feet: Vector3,
		kind: int = NetProtocol.EntityKind.PLAYER, health_q: int = 255) -> void:
	var spawn := NetMessages.EntitySpawn.new()
	spawn.net_id = net_id
	spawn.kind = kind
	spawn.spawn_tick = 1
	spawn.realm = realm
	spawn.display_name = player_name
	var state := PlayerState.new()
	state.position = feet
	state.grounded = true
	spawn.state = state
	_remote_world.on_spawn(spawn)
	_tick += 1
	var record := EntityRecord.new()
	record.net_id = net_id
	record.position = feet
	record.flags = EntityRecord.FLAG_GROUNDED
	record.health_q = health_q
	var snapshot := NetMessages.Snapshot.new()
	snapshot.server_tick = _tick
	snapshot.records = [record] as Array[EntityRecord]
	_remote_world.on_snapshot(snapshot)
	_clock.render = float(_tick)
	_remote_world.draw(float(_tick), 0.016)


## Feet of a point [param meters] meters in front of the reticle, lowered to the ground so that the remote falls on
## the aiming ray.
func _on_the_aim_ray(meters: float) -> Vector3:
	var ray: Dictionary = _rig.get_aim_ray()
	var point: Vector3 = Vector3(ray["origin"]) + Vector3(ray["direction"]) * meters
	return Vector3(point.x, 0.0, point.z)


func _find(own_position: Vector3 = Vector3.ZERO) -> RemotePlayerView:
	return SocialTarget.find(_remote_world, _rig.get_aim_ray(), own_position, VARDHEIM, _space())


func _space() -> PhysicsDirectSpaceState3D:
	return _rig.get_world_3d().direct_space_state


## A 20 x 10 x 0.5 m wall on the world layer, crossing the aiming ray at [param meters] m from the
## camera. Physics queries see it after a couple of physics steps.
func _wall_on_the_aim_ray(meters: float) -> StaticBody3D:
	var ray: Dictionary = _rig.get_aim_ray()
	var wall := StaticBody3D.new()
	wall.name = "Muro"
	wall.collision_layer = PlayerCharacter.WORLD_COLLISION_LAYER
	wall.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20.0, 10.0, 0.5)
	shape.shape = box
	wall.add_child(shape)
	_root.add_child(wall)
	wall.global_position = Vector3(ray["origin"]) + Vector3(ray["direction"]) * meters
	return wall


func _key(keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	event.keycode = keycode
	event.pressed = true
	return event


func _option_ids(options: Array[Dictionary]) -> PackedStringArray:
	var ids := PackedStringArray()
	for option: Dictionary in options:
		ids.append(String(option["id"]))
	return ids


# --- The ray ----------------------------------------------------------------------------------

func test_the_crosshair_finds_the_player_it_points_at_within_twenty_meters() -> void:
	assert_null(_find(), "with nobody, nothing")
	_spawn(ALLY_ID, VARDHEIM, "Bruno", _on_the_aim_ray(10.0))
	var found: RemotePlayerView = _find()
	if not assert_not_null(found, "at 10 m, on the ray, it is found"):
		return
	assert_eq(found.get_net_id(), ALLY_ID, "it is Bruno")
	assert_eq(found.get_display_name(), "Bruno", "with their name")
	_spawn(OTHER_ID, VARDHEIM, "Cora", _on_the_aim_ray(6.0))
	assert_eq(_find().get_net_id(), OTHER_ID, "the closest along the ray wins")
	# An enemy is not a target even if closer: it is ignored (it does not cover anyone, like the nameplates).
	_spawn(ENEMY_ID, SOLMARCH, "Hostil", _on_the_aim_ray(4.0))
	assert_eq(_find().get_net_id(), OTHER_ID, "an enemy in front does not count: it is still Cora")


func test_only_living_allies_with_a_real_name_are_targets() -> void:
	_spawn(ENEMY_ID, SOLMARCH, "Hostil", _on_the_aim_ray(5.0))
	assert_null(_find(), "an enemy alone under the reticle is not a target: like aiming at nobody")
	_spawn(ALLY_ID, VARDHEIM, "Bruno", _on_the_aim_ray(7.0), NetProtocol.EntityKind.PLAYER, 0)
	assert_null(_find(), "a dead ally neither (has no nameplate)")
	# The server's fake players (ZoneServer.add_fake_player, "Bot-01") cannot receive invitations or
	# whispers: their name does not meet NameRules, and a human's always does.
	_spawn(FAKE_ID, VARDHEIM, "Bot-01", _on_the_aim_ray(9.0))
	assert_null(_find(), "a fake player of your realm, neither")
	assert_false(SocialTarget.is_social_target(_remote_world.get_view(FAKE_ID), VARDHEIM), "Bot-01 no")
	assert_false(SocialTarget.is_social_target(_remote_world.get_view(ENEMY_ID), VARDHEIM), "Hostil no")
	assert_false(SocialTarget.is_social_target(_remote_world.get_view(ALLY_ID), VARDHEIM), "dead Bruno no")
	assert_false(SocialTarget.is_social_target(_remote_world.get_view(ENEMY_ID), NetProtocol.Realm.NONE),
			"with no own realm, nobody")
	assert_true(SocialTarget.is_social_target(_remote_world.get_view(ENEMY_ID), SOLMARCH),
			"for a Solmarch one, Hostil yes")
	_spawn(OTHER_ID, VARDHEIM, "Cora", _on_the_aim_ray(11.0))
	var found: RemotePlayerView = _find()
	if assert_not_null(found, "behind all of them, a living ally yes"):
		assert_eq(found.get_net_id(), OTHER_ID, "it is Cora")


func test_a_wall_hides_players_from_the_social_target() -> void:
	_spawn(ALLY_ID, VARDHEIM, "Bruno", _on_the_aim_ray(12.0))
	assert_not_null(_find(), "without a wall, Bruno is in sight")
	_wall_on_the_aim_ray(6.0)
	await wait_physics_frames(2)
	assert_false(HitShapes.is_ray_clear(_space(), Vector3(_rig.get_aim_ray()["origin"]),
			_on_the_aim_ray(12.0) + Vector3(0.0, Nameplates.HEAD_HEIGHT, 0.0)), "the wall covers Bruno's head")
	assert_null(_find(), "behind the wall he is not targeted, just as his nameplate is not seen")
	assert_not_null(SocialTarget.find(_remote_world, _rig.get_aim_ray(), Vector3.ZERO, VARDHEIM, null),
			"without a physics space, occlusion is not checked")
	# One in sight, in front of the wall, yes.
	_spawn(OTHER_ID, VARDHEIM, "Cora", _on_the_aim_ray(4.0))
	var found: RemotePlayerView = _find()
	if assert_not_null(found, "in front of the wall, Cora yes"):
		assert_eq(found.get_net_id(), OTHER_ID, "it is Cora")


func test_players_off_the_ray_or_beyond_twenty_meters_are_not_found() -> void:
	_spawn(ALLY_ID, VARDHEIM, "Lejos", _on_the_aim_ray(25.0))
	assert_null(_find(), "a 25 m no")
	_spawn(OTHER_ID, VARDHEIM, "Aparte", _on_the_aim_ray(8.0) + Vector3(4.0, 0.0, 0.0))
	assert_null(_find(), "at 4 m from the ray neither")
	_spawn(ENEMY_ID, VARDHEIM, "Guardián", _on_the_aim_ray(8.0), NetProtocol.EntityKind.NPC)
	assert_null(_find(), "an NPC is not a player, even if of your realm")


func test_the_range_counts_from_the_player_not_from_the_camera() -> void:
	# The camera is behind the player: the player is 4 m in front of it, on the ray.
	var own: Vector3 = _on_the_aim_ray(4.0)
	_spawn(OTHER_ID, VARDHEIM, "Cora", _on_the_aim_ray(4.0 + 22.0))
	assert_null(_find(own), "at 22 m from the player (26 from the camera) it is not reached")
	_spawn(ALLY_ID, VARDHEIM, "Bruno", _on_the_aim_ray(4.0 + 18.0))
	var found: RemotePlayerView = _find(own)
	if assert_not_null(found, "at 18 m from the player (22 m from the camera) it is found"):
		assert_eq(found.get_net_id(), ALLY_ID, "it is Bruno, not Cora")


# --- Options ----------------------------------------------------------------------------------

func test_an_ally_offers_invite_and_whisper_and_an_enemy_offers_nothing() -> void:
	var ally: Array[Dictionary] = SocialTarget.options_for(VARDHEIM, VARDHEIM, ALLY_ID, null)
	assert_eq(_option_ids(ally), PackedStringArray(["invite", "whisper"]),
			"an ally: invite and whisper")
	assert_eq(ally[0]["text"], "Invitar al grupo", "invite text")
	assert_eq(ally[1]["text"], "Susurrar", "whisper text")
	assert_true(SocialTarget.options_for(VARDHEIM, SOLMARCH, ENEMY_ID, null).is_empty(),
			"an enemy: nothing (neither parties nor whispers cross between realms)")
	assert_true(SocialTarget.options_for(NetProtocol.Realm.NONE, VARDHEIM, ALLY_ID, null).is_empty(),
			"with no own realm, nothing")
	assert_true(SocialTarget.options_for(VARDHEIM, NetProtocol.Realm.NONE, ALLY_ID, null).is_empty(),
			"and a Hollow one neither")


func test_a_party_member_or_a_full_party_only_offers_to_whisper() -> void:
	var party := PartyState.new()
	var roster := NetMessages.PartyRoster.new()
	roster.members.append(NetMessages.PartyRoster.Member.make(1, "Ana"))
	roster.members.append(NetMessages.PartyRoster.Member.make(ALLY_ID, "Bruno"))
	party.apply_roster(roster)
	assert_eq(_option_ids(SocialTarget.options_for(VARDHEIM, VARDHEIM, ALLY_ID, party)),
			PackedStringArray(["whisper"]), "someone already in the party: only whisper")
	assert_eq(_option_ids(SocialTarget.options_for(VARDHEIM, VARDHEIM, OTHER_ID, party)),
			PackedStringArray(["invite", "whisper"]),
			"another ally, with room in the party: both")
	var full := NetMessages.PartyRoster.new()
	for i: int in NetProtocol.PARTY_MAX_SIZE:
		full.members.append(NetMessages.PartyRoster.Member.make(500 + i, "M%d" % i))
	party.apply_roster(full)
	assert_eq(_option_ids(SocialTarget.options_for(VARDHEIM, VARDHEIM, OTHER_ID, party)),
			PackedStringArray(["whisper"]), "with a full party, no invite")


# --- The menu ---------------------------------------------------------------------------------

func _menu_with_chat() -> Array:
	var chat: ChatBox = _track(ChatBox.new()) as ChatBox
	chat.bind(_client, _rig, null)
	var menu: SocialMenu = _track(SocialMenu.new()) as SocialMenu
	menu.setup(_client, chat, _rig)
	return [menu, chat]


func test_the_menu_offers_invite_and_whisper_and_each_one_works() -> void:
	_spawn(ALLY_ID, VARDHEIM, "Bruno", _on_the_aim_ray(10.0))
	var pair: Array = _menu_with_chat()
	var menu: SocialMenu = pair[0]
	var chat: ChatBox = pair[1]
	var view: RemotePlayerView = _find()
	assert_true(menu.open_for(view), "the menu opens on an ally")
	assert_true(menu.is_open(), "open")
	assert_true(_rig.is_ui_holding_cursor(), "with the cursor free")
	assert_eq(menu.get_target_name(), "Bruno", "on Bruno")
	assert_eq(menu.window_title, "Bruno", "and his name in the title")
	assert_eq(menu.get_buttons().size(), 2, "two buttons")
	assert_eq(menu.get_buttons()[0].text, "Invitar al grupo", "invite")
	assert_eq(menu.get_buttons()[1].text, "Susurrar", "whisper")
	assert_not_null(menu.get_button(SocialTarget.OPTION_INVITE), "looked up by action")

	# Invite: presses the button; the request goes out and the menu closes.
	var chosen: Array[String] = []
	menu.option_chosen.connect(func(option_id: StringName, target_name: String) -> void:
		chosen.append("%s:%s" % [option_id, target_name]))
	menu.get_button(SocialTarget.OPTION_INVITE).pressed.emit()
	assert_eq(PackedStringArray(_client.invited), PackedStringArray(["Bruno"]), "Bruno is invited")
	assert_false(menu.is_open(), "the menu closes")
	assert_false(_rig.is_ui_holding_cursor(), "and the cursor goes back to the game")
	# Whisper: opens the chat line with "/s Bruno ".
	assert_true(menu.open_for(view), "it opens again")
	menu.get_button(SocialTarget.OPTION_WHISPER).pressed.emit()
	assert_false(menu.is_open(), "the menu closes before opening the line")
	assert_true(chat.is_open(), "the chat line opens")
	assert_eq(chat.get_input().text, "/s Bruno ", "with the whisper to Bruno written")
	assert_eq(PackedStringArray(chosen), PackedStringArray(["invite:Bruno", "whisper:Bruno"]),
			"option_chosen reports both")


func test_the_menu_does_not_open_on_an_enemy_and_shows_only_what_applies() -> void:
	_spawn(ENEMY_ID, SOLMARCH, "Hostil", _on_the_aim_ray(10.0))
	_spawn(FAKE_ID, VARDHEIM, "Bot-01", _on_the_aim_ray(14.0))
	var pair: Array = _menu_with_chat()
	var menu: SocialMenu = pair[0]
	assert_false(menu.open_for(_remote_world.get_view(ENEMY_ID)), "with an enemy there is nothing to offer")
	assert_false(menu.is_open(), "the menu does not open")
	assert_false(_rig.is_ui_holding_cursor(), "nor touch the cursor")
	assert_eq(menu.get_buttons().size(), 0, "no buttons")
	assert_false(menu.open_for(_remote_world.get_view(FAKE_ID)),
			"with a fake player neither: the server would answer \"no está conectado\" (is not connected)")
	assert_eq(menu.get_buttons().size(), 0, "no buttons")
	assert_false(menu.open_for(null), "with no target, neither")
	# A party member: only whisper.
	_spawn(ALLY_ID, VARDHEIM, "Bruno", _on_the_aim_ray(6.0))
	var roster := NetMessages.PartyRoster.new()
	roster.members.append(NetMessages.PartyRoster.Member.make(1, "Ana"))
	roster.members.append(NetMessages.PartyRoster.Member.make(ALLY_ID, "Bruno"))
	_client.get_party().apply_roster(roster)
	assert_true(menu.open_for(_find()), "a party mate yes")
	assert_eq(menu.get_buttons().size(), 1, "with a single option")
	assert_eq(menu.get_buttons()[0].text, "Susurrar", "whisper")
	assert_null(menu.get_button(SocialTarget.OPTION_INVITE), "they are not invited")
	# Esc closes the menu and returns the cursor.
	menu._input(_key(KEY_ESCAPE))
	assert_false(menu.is_open(), "Esc closes it")
	assert_false(_rig.is_ui_holding_cursor(), "and returns the cursor")


# --- The HUD key ------------------------------------------------------------------------------

func _hud() -> HUD:
	var character: PlayerCharacter = (load(CHARACTER_SCENE_PATH) as PackedScene).instantiate() as PlayerCharacter
	_track(character)
	character.global_position = Vector3.ZERO
	_client.fake_character = character
	var hud: HUD = _track((load(HUD_SCENE_PATH) as PackedScene).instantiate()) as HUD
	hud.bind(character, _rig)
	hud.bind_net(_client, null)
	return hud


func test_the_hud_opens_the_menu_on_the_player_under_the_crosshair() -> void:
	var hud: HUD = _hud()
	var menu: SocialMenu = hud.get_social_menu()
	if not assert_not_null(menu, "the networked HUD has a social menu"):
		return
	assert_true(menu.get_index() < hud.get_death_screen().get_index(), "below the death screen")
	assert_true(menu.get_index() < hud.get_scoreboard().get_index(), "and the scoreboard, which is still the last")
	var bare := HUD.new()
	assert_null(bare.get_social_menu(), "the sandbox has no social menu")
	bare.free()
	# With nobody in sight: a notice goes to the chat.
	assert_false(hud.open_social_menu(), "with nobody, it does not open")
	assert_eq(hud.get_chat().get_log().get_lines().back().text, HUD.TEXT_NO_SOCIAL_TARGET, "and it says why")
	# An ally on the ray: the key opens the menu.
	_spawn(ALLY_ID, VARDHEIM, "Bruno", _on_the_aim_ray(10.0))
	hud._unhandled_input(_key(KEY_G))
	assert_true(menu.is_open(), "the player key opens the menu")
	assert_eq(menu.get_target_name(), "Bruno", "on Bruno")
	# With the menu open another press does nothing (the cursor belongs to the window).
	assert_false(hud.open_social_menu(), "with a window open another one does not open")
	menu.close()
	# With the chat line open, neither.
	hud.get_chat().open()
	assert_false(hud.open_social_menu(), "while typing in the chat it does not open")
	hud.get_chat().close()
	# An enemy on the ray, closer: it does not cover Bruno.
	_spawn(ENEMY_ID, SOLMARCH, "Hostil", _on_the_aim_ray(4.0))
	assert_true(hud.open_social_menu(), "an enemy in front does not count")
	assert_eq(menu.get_target_name(), "Bruno", "the menu is Bruno's")
	menu.close()


func test_the_hud_gives_the_same_answer_for_an_enemy_a_wall_a_fake_or_nobody() -> void:
	var hud: HUD = _hud()
	var menu: SocialMenu = hud.get_social_menu()
	var log: ChatLog = hud.get_chat().get_log()
	assert_false(hud.open_social_menu(), "with nobody, it does not open")
	var nobody: String = log.get_lines().back().text
	assert_eq(nobody, HUD.TEXT_NO_SOCIAL_TARGET, "and it says why")
	# An enemy hidden behind a wall: pressing the key against the wall must not give it away.
	var wall: StaticBody3D = _wall_on_the_aim_ray(6.0)
	await wait_physics_frames(2)
	_spawn(ENEMY_ID, SOLMARCH, "Oculto", _on_the_aim_ray(12.0))
	var before: int = log.get_count()
	assert_false(hud.open_social_menu(), "with an enemy behind the wall, it does not open")
	assert_eq(log.get_count(), before + 1, "a notice")
	assert_eq(log.get_lines().back().text, nobody, "the same as with nobody: whoever is behind is not given away")
	# An ally behind the wall does not open the menu either (their nameplate is hidden).
	_spawn(ALLY_ID, VARDHEIM, "Tapado", _on_the_aim_ray(10.0))
	assert_false(hud.open_social_menu(), "a covered ally does not open the menu")
	assert_false(menu.is_open(), "closed")
	assert_eq(log.get_lines().back().text, nobody, "same notice")
	_root.remove_child(wall)
	wall.free()
	await wait_physics_frames(2)
	assert_true(hud.open_social_menu(), "without the wall, the ally does")
	assert_eq(menu.get_target_name(), "Tapado", "on them")
	menu.close()

	# Somewhere else, far from the earlier ones: an enemy in sight and a fake player of your realm, in front of a
	# real ally.
	_move_player_to(Vector3(100.0, 0.0, 0.0))
	assert_false(hud.open_social_menu(), "there is nobody there")
	_spawn(ENEMY_ID + 1, SOLMARCH, "Hostil", _on_the_aim_ray(4.0))
	assert_false(hud.open_social_menu(), "with an enemy in sight, it does not open")
	assert_eq(log.get_lines().back().text, nobody, "and the notice is the usual one")
	_spawn(FAKE_ID, VARDHEIM, "Bot-01", _on_the_aim_ray(6.0))
	assert_false(hud.open_social_menu(), "with a fake player, it does not open")
	assert_eq(log.get_lines().back().text, nobody, "same notice")
	_spawn(OTHER_ID, VARDHEIM, "Cora", _on_the_aim_ray(8.0))
	assert_true(hud.open_social_menu(), "a real ally behind the two, yes")
	assert_eq(menu.get_target_name(), "Cora", "on Cora")
	menu.close()


## Presses and releases [param keycode] through the window's input (the interface sees it before the game).
func _tap(keycode: Key) -> void:
	for pressed: bool in [true, false]:
		var event := InputEventKey.new()
		event.physical_keycode = keycode
		event.keycode = keycode
		event.pressed = pressed
		tree.root.push_input(event)


## Phase 4 review (client): the menu gives focus to its first button when it opens ("Intro" (Enter) presses it) and windows do not
## suspend game input, so Space, which is jump, also pressed "Invitar al grupo" (Invite to party). Space no longer
## confirms in the interface (ui_accept keeps Enter).
func test_space_jumps_without_pressing_the_focused_button_and_enter_still_presses_it() -> void:
	var accept: Array[Key] = []
	for event: InputEvent in InputMap.action_get_events(&"ui_accept"):
		if event is InputEventKey:
			accept.append((event as InputEventKey).keycode if (event as InputEventKey).keycode != KEY_NONE
					else (event as InputEventKey).physical_keycode)
	assert_false(accept.has(KEY_SPACE), "Space does not confirm (%s)" % [accept])
	assert_true(accept.has(KEY_ENTER), "Enter does")
	var hud: HUD = _hud()
	var menu: SocialMenu = hud.get_social_menu()
	_spawn(ALLY_ID, VARDHEIM, "Bruno", _on_the_aim_ray(10.0))
	hud._unhandled_input(_key(KEY_G))
	if not assert_true(menu.is_open(), "G opens the menu on Bruno"):
		return
	assert_eq(tree.root.gui_get_focus_owner(), menu.get_buttons()[0], "with focus on \"Invitar al grupo\" (Invite to party)")
	_tap(KEY_SPACE)
	assert_eq(_client.invited.size(), 0, "jumping invites nobody")
	assert_true(menu.is_open(), "nor closes the menu")
	_tap(KEY_ENTER)
	assert_eq(PackedStringArray(_client.invited), PackedStringArray(["Bruno"]), "Enter presses the focused button")
	assert_false(menu.is_open())


## Moves the local player (and the camera, which goes with it) to [param feet].
func _move_player_to(feet: Vector3) -> void:
	_client.fake_character.global_position = feet
	_rig.global_position = feet + Vector3(0.0, 1.6, 0.0)
	_rig._process(0.016)
