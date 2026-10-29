extends TestCase
## Pruebas de las acciones sociales sobre el jugador bajo el punto de mira (SOC-07, docs/social.md sección 12.6):
## el rayo contra los remotos a 20 m ([SocialTarget.find], con la cámara de acción de verdad y remotos
## sintéticos; solo aliados vivos, con nombre de persona y sin una pared delante), qué opciones ofrece cada jugador
## ([SocialTarget.options_for]: invitar y susurrar a un aliado, solo susurrar a un miembro del grupo, nada con un
## enemigo), el menú ([SocialMenu]) y la tecla del [HUD], que da el mismo aviso con un enemigo, tras una pared o
## sin nadie.

const CAMERA_RIG_SCENE_PATH: String = "res://scenes/client/camera_rig.tscn"
const HUD_SCENE_PATH: String = "res://scenes/ui/hud.tscn"
const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ALLY_ID: int = 31
const OTHER_ID: int = 32
const ENEMY_ID: int = 41
const FAKE_ID: int = 51


## Reloj cuyo tick de dibujo se fija desde la prueba.
class FakeClock extends InterpolationClock:
	var render: float = 0.0

	func get_render_tick() -> float:
		return render


## Cliente de red que no conecta con nada: da el mundo remoto y el personaje y apunta las invitaciones.
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


# --- Ayudantes --------------------------------------------------------------------------------

func _track(node: Node) -> Node:
	tree.root.add_child(node)
	_nodes.append(node)
	return node


## Un remoto de [param kind] y [param realm] con [param player_name] en [param feet], ya dibujándose con la vida
## [param health_q] (0 = muerto).
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


## Pies de un punto a [param meters] metros delante de la retícula, bajado al suelo para que el remoto quede en
## el rayo de puntería.
func _on_the_aim_ray(meters: float) -> Vector3:
	var ray: Dictionary = _rig.get_aim_ray()
	var point: Vector3 = Vector3(ray["origin"]) + Vector3(ray["direction"]) * meters
	return Vector3(point.x, 0.0, point.z)


func _find(own_position: Vector3 = Vector3.ZERO) -> RemotePlayerView:
	return SocialTarget.find(_remote_world, _rig.get_aim_ray(), own_position, VARDHEIM, _space())


func _space() -> PhysicsDirectSpaceState3D:
	return _rig.get_world_3d().direct_space_state


## Un muro de 20 x 10 x 0,5 m en la capa del mundo, cruzado sobre el rayo de puntería a [param meters] m de la
## cámara. Las consultas de física lo ven tras un par de pasos de física.
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


# --- El rayo ----------------------------------------------------------------------------------

func test_the_crosshair_finds_the_player_it_points_at_within_twenty_meters() -> void:
	assert_null(_find(), "sin nadie, nada")
	_spawn(ALLY_ID, VARDHEIM, "Bruno", _on_the_aim_ray(10.0))
	var found: RemotePlayerView = _find()
	if not assert_not_null(found, "a 10 m, en el rayo, se le encuentra"):
		return
	assert_eq(found.get_net_id(), ALLY_ID, "es Bruno")
	assert_eq(found.get_display_name(), "Bruno", "con su nombre")
	_spawn(OTHER_ID, VARDHEIM, "Cora", _on_the_aim_ray(6.0))
	assert_eq(_find().get_net_id(), OTHER_ID, "el más cercano a lo largo del rayo gana")
	# Un enemigo no es objetivo aunque esté más cerca: se le ignora (no tapa a nadie, como las placas).
	_spawn(ENEMY_ID, SOLMARCH, "Hostil", _on_the_aim_ray(4.0))
	assert_eq(_find().get_net_id(), OTHER_ID, "un enemigo delante no cuenta: sigue siendo Cora")


func test_only_living_allies_with_a_real_name_are_targets() -> void:
	_spawn(ENEMY_ID, SOLMARCH, "Hostil", _on_the_aim_ray(5.0))
	assert_null(_find(), "un enemigo solo bajo la retícula no es objetivo: como no apuntar a nadie")
	_spawn(ALLY_ID, VARDHEIM, "Bruno", _on_the_aim_ray(7.0), NetProtocol.EntityKind.PLAYER, 0)
	assert_null(_find(), "un aliado muerto tampoco (no tiene placa)")
	# Los jugadores falsos del servidor (ZoneServer.add_fake_player, «Bot-01») no pueden recibir invitaciones ni
	# susurros: su nombre no cumple NameRules, y el de una persona siempre la cumple.
	_spawn(FAKE_ID, VARDHEIM, "Bot-01", _on_the_aim_ray(9.0))
	assert_null(_find(), "un jugador falso de tu reino, tampoco")
	assert_false(SocialTarget.is_social_target(_remote_world.get_view(FAKE_ID), VARDHEIM), "Bot-01 no")
	assert_false(SocialTarget.is_social_target(_remote_world.get_view(ENEMY_ID), VARDHEIM), "Hostil no")
	assert_false(SocialTarget.is_social_target(_remote_world.get_view(ALLY_ID), VARDHEIM), "Bruno muerto no")
	assert_false(SocialTarget.is_social_target(_remote_world.get_view(ENEMY_ID), NetProtocol.Realm.NONE),
			"sin reino propio, nadie")
	assert_true(SocialTarget.is_social_target(_remote_world.get_view(ENEMY_ID), SOLMARCH),
			"para uno de Solmarch, Hostil sí")
	_spawn(OTHER_ID, VARDHEIM, "Cora", _on_the_aim_ray(11.0))
	var found: RemotePlayerView = _find()
	if assert_not_null(found, "detrás de todos ellos, un aliado vivo sí"):
		assert_eq(found.get_net_id(), OTHER_ID, "es Cora")


func test_a_wall_hides_players_from_the_social_target() -> void:
	_spawn(ALLY_ID, VARDHEIM, "Bruno", _on_the_aim_ray(12.0))
	assert_not_null(_find(), "sin muro, Bruno está a la vista")
	_wall_on_the_aim_ray(6.0)
	await wait_physics_frames(2)
	assert_false(HitShapes.is_ray_clear(_space(), Vector3(_rig.get_aim_ray()["origin"]),
			_on_the_aim_ray(12.0) + Vector3(0.0, Nameplates.HEAD_HEIGHT, 0.0)), "el muro tapa la cabeza de Bruno")
	assert_null(_find(), "tras el muro no se le apunta, como no se ve su placa")
	assert_not_null(SocialTarget.find(_remote_world, _rig.get_aim_ray(), Vector3.ZERO, VARDHEIM, null),
			"sin espacio de física no se comprueba la oclusión")
	# Uno a la vista, delante del muro, sí.
	_spawn(OTHER_ID, VARDHEIM, "Cora", _on_the_aim_ray(4.0))
	var found: RemotePlayerView = _find()
	if assert_not_null(found, "delante del muro, Cora sí"):
		assert_eq(found.get_net_id(), OTHER_ID, "es Cora")


func test_players_off_the_ray_or_beyond_twenty_meters_are_not_found() -> void:
	_spawn(ALLY_ID, VARDHEIM, "Lejos", _on_the_aim_ray(25.0))
	assert_null(_find(), "a 25 m no")
	_spawn(OTHER_ID, VARDHEIM, "Aparte", _on_the_aim_ray(8.0) + Vector3(4.0, 0.0, 0.0))
	assert_null(_find(), "a 4 m del rayo tampoco")
	_spawn(ENEMY_ID, VARDHEIM, "Guardián", _on_the_aim_ray(8.0), NetProtocol.EntityKind.NPC)
	assert_null(_find(), "un PNJ no es un jugador, aunque sea de tu reino")


func test_the_range_counts_from_the_player_not_from_the_camera() -> void:
	# La cámara va detrás del jugador: el jugador está 4 m por delante de ella, sobre el rayo.
	var own: Vector3 = _on_the_aim_ray(4.0)
	_spawn(OTHER_ID, VARDHEIM, "Cora", _on_the_aim_ray(4.0 + 22.0))
	assert_null(_find(own), "a 22 m del jugador (26 de la cámara) no se la alcanza")
	_spawn(ALLY_ID, VARDHEIM, "Bruno", _on_the_aim_ray(4.0 + 18.0))
	var found: RemotePlayerView = _find(own)
	if assert_not_null(found, "a 18 m del jugador (22 m de la cámara) sí se le encuentra"):
		assert_eq(found.get_net_id(), ALLY_ID, "es Bruno, no Cora")


# --- Opciones ---------------------------------------------------------------------------------

func test_an_ally_offers_invite_and_whisper_and_an_enemy_offers_nothing() -> void:
	var ally: Array[Dictionary] = SocialTarget.options_for(VARDHEIM, VARDHEIM, ALLY_ID, null)
	assert_eq(_option_ids(ally), PackedStringArray(["invite", "whisper"]),
			"un aliado: invitar y susurrar")
	assert_eq(ally[0]["text"], "Invitar al grupo", "texto de invitar")
	assert_eq(ally[1]["text"], "Susurrar", "texto de susurrar")
	assert_true(SocialTarget.options_for(VARDHEIM, SOLMARCH, ENEMY_ID, null).is_empty(),
			"un enemigo: nada (ni grupos ni susurros cruzan entre reinos)")
	assert_true(SocialTarget.options_for(NetProtocol.Realm.NONE, VARDHEIM, ALLY_ID, null).is_empty(),
			"sin reino propio, nada")
	assert_true(SocialTarget.options_for(VARDHEIM, NetProtocol.Realm.NONE, ALLY_ID, null).is_empty(),
			"y un Hueco tampoco")


func test_a_party_member_or_a_full_party_only_offers_to_whisper() -> void:
	var party := PartyState.new()
	var roster := NetMessages.PartyRoster.new()
	roster.members.append(NetMessages.PartyRoster.Member.make(1, "Ana"))
	roster.members.append(NetMessages.PartyRoster.Member.make(ALLY_ID, "Bruno"))
	party.apply_roster(roster)
	assert_eq(_option_ids(SocialTarget.options_for(VARDHEIM, VARDHEIM, ALLY_ID, party)),
			PackedStringArray(["whisper"]), "quien ya es del grupo: solo susurrar")
	assert_eq(_option_ids(SocialTarget.options_for(VARDHEIM, VARDHEIM, OTHER_ID, party)),
			PackedStringArray(["invite", "whisper"]),
			"otro aliado, con sitio en el grupo: las dos")
	var full := NetMessages.PartyRoster.new()
	for i: int in NetProtocol.PARTY_MAX_SIZE:
		full.members.append(NetMessages.PartyRoster.Member.make(500 + i, "M%d" % i))
	party.apply_roster(full)
	assert_eq(_option_ids(SocialTarget.options_for(VARDHEIM, VARDHEIM, OTHER_ID, party)),
			PackedStringArray(["whisper"]), "con el grupo completo, no se invita")


# --- El menú ----------------------------------------------------------------------------------

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
	assert_true(menu.open_for(view), "el menú se abre sobre un aliado")
	assert_true(menu.is_open(), "abierto")
	assert_true(_rig.is_ui_holding_cursor(), "con el cursor libre")
	assert_eq(menu.get_target_name(), "Bruno", "sobre Bruno")
	assert_eq(menu.window_title, "Bruno", "y su nombre en el título")
	assert_eq(menu.get_buttons().size(), 2, "dos botones")
	assert_eq(menu.get_buttons()[0].text, "Invitar al grupo", "invitar")
	assert_eq(menu.get_buttons()[1].text, "Susurrar", "susurrar")
	assert_not_null(menu.get_button(SocialTarget.OPTION_INVITE), "se busca por acción")

	# Invitar: pulsa el botón; la petición sale y el menú se cierra.
	var chosen: Array[String] = []
	menu.option_chosen.connect(func(option_id: StringName, target_name: String) -> void:
		chosen.append("%s:%s" % [option_id, target_name]))
	menu.get_button(SocialTarget.OPTION_INVITE).pressed.emit()
	assert_eq(PackedStringArray(_client.invited), PackedStringArray(["Bruno"]), "se invita a Bruno")
	assert_false(menu.is_open(), "el menú se cierra")
	assert_false(_rig.is_ui_holding_cursor(), "y el cursor vuelve al juego")
	# Susurrar: abre la línea del chat con «/s Bruno ».
	assert_true(menu.open_for(view), "se vuelve a abrir")
	menu.get_button(SocialTarget.OPTION_WHISPER).pressed.emit()
	assert_false(menu.is_open(), "el menú se cierra antes de abrir la línea")
	assert_true(chat.is_open(), "se abre la línea del chat")
	assert_eq(chat.get_input().text, "/s Bruno ", "con el susurro a Bruno escrito")
	assert_eq(PackedStringArray(chosen), PackedStringArray(["invite:Bruno", "whisper:Bruno"]),
			"option_chosen avisa de las dos")


func test_the_menu_does_not_open_on_an_enemy_and_shows_only_what_applies() -> void:
	_spawn(ENEMY_ID, SOLMARCH, "Hostil", _on_the_aim_ray(10.0))
	_spawn(FAKE_ID, VARDHEIM, "Bot-01", _on_the_aim_ray(14.0))
	var pair: Array = _menu_with_chat()
	var menu: SocialMenu = pair[0]
	assert_false(menu.open_for(_remote_world.get_view(ENEMY_ID)), "con un enemigo no hay nada que ofrecer")
	assert_false(menu.is_open(), "el menú no se abre")
	assert_false(_rig.is_ui_holding_cursor(), "ni toca el cursor")
	assert_eq(menu.get_buttons().size(), 0, "sin botones")
	assert_false(menu.open_for(_remote_world.get_view(FAKE_ID)),
			"con un jugador falso tampoco: el servidor contestaría «no está conectado»")
	assert_eq(menu.get_buttons().size(), 0, "sin botones")
	assert_false(menu.open_for(null), "sin objetivo, tampoco")
	# Un miembro del grupo: solo susurrar.
	_spawn(ALLY_ID, VARDHEIM, "Bruno", _on_the_aim_ray(6.0))
	var roster := NetMessages.PartyRoster.new()
	roster.members.append(NetMessages.PartyRoster.Member.make(1, "Ana"))
	roster.members.append(NetMessages.PartyRoster.Member.make(ALLY_ID, "Bruno"))
	_client.get_party().apply_roster(roster)
	assert_true(menu.open_for(_find()), "un compañero de grupo sí")
	assert_eq(menu.get_buttons().size(), 1, "con una sola opción")
	assert_eq(menu.get_buttons()[0].text, "Susurrar", "susurrar")
	assert_null(menu.get_button(SocialTarget.OPTION_INVITE), "no se le invita")
	# Esc cierra el menú y devuelve el cursor.
	menu._input(_key(KEY_ESCAPE))
	assert_false(menu.is_open(), "Esc lo cierra")
	assert_false(_rig.is_ui_holding_cursor(), "y devuelve el cursor")


# --- La tecla del HUD -------------------------------------------------------------------------

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
	if not assert_not_null(menu, "el HUD en red tiene menú social"):
		return
	assert_true(menu.get_index() < hud.get_death_screen().get_index(), "por debajo de la pantalla de muerte")
	assert_true(menu.get_index() < hud.get_scoreboard().get_index(), "y del marcador, que sigue siendo el último")
	var bare := HUD.new()
	assert_null(bare.get_social_menu(), "el sandbox no tiene menú social")
	bare.free()
	# Sin nadie a la vista: se avisa en el chat.
	assert_false(hud.open_social_menu(), "sin nadie, no se abre")
	assert_eq(hud.get_chat().get_log().get_lines().back().text, HUD.TEXT_NO_SOCIAL_TARGET, "y se dice por qué")
	# Un aliado en el rayo: la tecla abre el menú.
	_spawn(ALLY_ID, VARDHEIM, "Bruno", _on_the_aim_ray(10.0))
	hud._unhandled_input(_key(KEY_T))
	assert_true(menu.is_open(), "la tecla de jugador abre el menú")
	assert_eq(menu.get_target_name(), "Bruno", "sobre Bruno")
	# Con el menú abierto otra pulsación no hace nada (el cursor es de la ventana).
	assert_false(hud.open_social_menu(), "con una ventana abierta no se abre otro")
	menu.close()
	# Con la línea del chat abierta, tampoco.
	hud.get_chat().open()
	assert_false(hud.open_social_menu(), "escribiendo en el chat no se abre")
	hud.get_chat().close()
	# Un enemigo en el rayo, más cerca: no tapa a Bruno.
	_spawn(ENEMY_ID, SOLMARCH, "Hostil", _on_the_aim_ray(4.0))
	assert_true(hud.open_social_menu(), "un enemigo delante no cuenta")
	assert_eq(menu.get_target_name(), "Bruno", "el menú es de Bruno")
	menu.close()


func test_the_hud_gives_the_same_answer_for_an_enemy_a_wall_a_fake_or_nobody() -> void:
	var hud: HUD = _hud()
	var menu: SocialMenu = hud.get_social_menu()
	var log: ChatLog = hud.get_chat().get_log()
	assert_false(hud.open_social_menu(), "sin nadie, no se abre")
	var nobody: String = log.get_lines().back().text
	assert_eq(nobody, HUD.TEXT_NO_SOCIAL_TARGET, "y se dice por qué")
	# Un enemigo escondido tras un muro: pulsar la tecla contra el muro no puede delatarlo.
	var wall: StaticBody3D = _wall_on_the_aim_ray(6.0)
	await wait_physics_frames(2)
	_spawn(ENEMY_ID, SOLMARCH, "Oculto", _on_the_aim_ray(12.0))
	var before: int = log.get_count()
	assert_false(hud.open_social_menu(), "con un enemigo detrás del muro, no se abre")
	assert_eq(log.get_count(), before + 1, "un aviso")
	assert_eq(log.get_lines().back().text, nobody, "el mismo que sin nadie: no se delata a quien está detrás")
	# Un aliado tras el muro tampoco abre el menú (su placa está oculta).
	_spawn(ALLY_ID, VARDHEIM, "Tapado", _on_the_aim_ray(10.0))
	assert_false(hud.open_social_menu(), "un aliado tapado no abre el menú")
	assert_false(menu.is_open(), "cerrado")
	assert_eq(log.get_lines().back().text, nobody, "mismo aviso")
	_root.remove_child(wall)
	wall.free()
	await wait_physics_frames(2)
	assert_true(hud.open_social_menu(), "sin el muro, el aliado sí")
	assert_eq(menu.get_target_name(), "Tapado", "sobre él")
	menu.close()

	# En otro sitio, lejos de los de antes: un enemigo a la vista y un jugador falso de tu reino, delante de un
	# aliado de verdad.
	_move_player_to(Vector3(100.0, 0.0, 0.0))
	assert_false(hud.open_social_menu(), "allí no hay nadie")
	_spawn(ENEMY_ID + 1, SOLMARCH, "Hostil", _on_the_aim_ray(4.0))
	assert_false(hud.open_social_menu(), "con un enemigo a la vista, no se abre")
	assert_eq(log.get_lines().back().text, nobody, "y el aviso es el de siempre")
	_spawn(FAKE_ID, VARDHEIM, "Bot-01", _on_the_aim_ray(6.0))
	assert_false(hud.open_social_menu(), "con un jugador falso, no se abre")
	assert_eq(log.get_lines().back().text, nobody, "mismo aviso")
	_spawn(OTHER_ID, VARDHEIM, "Cora", _on_the_aim_ray(8.0))
	assert_true(hud.open_social_menu(), "un aliado de verdad detrás de los dos, sí")
	assert_eq(menu.get_target_name(), "Cora", "sobre Cora")
	menu.close()


## Lleva al jugador local (y la cámara, que va con él) a [param feet].
func _move_player_to(feet: Vector3) -> void:
	_client.fake_character.global_position = feet
	_rig.global_position = feet + Vector3(0.0, 1.6, 0.0)
	_rig._process(0.016)
