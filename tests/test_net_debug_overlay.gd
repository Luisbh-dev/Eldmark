extends TestCase
## Pruebas de [NetDebugOverlay] (docs/red.md, sección 13; TEC-10) con clientes de una prueba de
## integración: servidor y bots en un mismo proceso, cada uno en su [SubViewport].
## [br]- Los textos se rellenan con los datos del [NetClient] al que se enlaza.
## [br]- F3 muestra y oculta el panel; F4, el fantasma translúcido del último estado propio del
## servidor y las marcas de las muestras de los remotos.
## [br]- En [OnlineMain], F3 alterna a la vez el panel de red y el panel de depuración del HUD.

const OVERLAY_SCENE: String = "res://scenes/ui/net_debug_overlay.tscn"
const ONLINE_SCENE: String = "res://scenes/client/online_main.tscn"
const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const WAIT_FRAMES: int = 600

var _root: Node
var _server_viewport: SubViewport
var _server: ZoneServer
var _port: int = 0
var _clients: Array[NetClient] = []
var _client_viewports: Array[SubViewport] = []
var _online: OnlineMain
var _saved_config: ClientConfig
var _saved_hook: Callable
var _saved_max_fps: int = 0


func before_each() -> void:
	_saved_config = OnlineMain.config
	_saved_hook = OnlineMain.quit_hook
	_saved_max_fps = Engine.max_fps
	_root = Node.new()
	_root.name = "NetDebugOverlayTest"
	tree.root.add_child(_root)


func after_each() -> void:
	if is_instance_valid(_online):
		_online.get_parent().remove_child(_online)
		_online.free()
	_online = null
	for viewport: SubViewport in _client_viewports:
		if is_instance_valid(viewport):
			viewport.free()
	_client_viewports.clear()
	_clients.clear()
	if is_instance_valid(_server_viewport):
		_server_viewport.free()
	_server_viewport = null
	_server = null
	if is_instance_valid(_root):
		tree.root.remove_child(_root)
		_root.free()
	_root = null
	OnlineMain.config = _saved_config
	OnlineMain.quit_hook = _saved_hook
	Engine.max_fps = _saved_max_fps
	await wait_process_frames(2)


# --- Ayudantes --------------------------------------------------------------------------------

func _start_server() -> void:
	_port = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, "")
	var config := ServerConfig.new()
	config.port = _port
	config.zone_id = "test_world"
	config.max_players = 8
	_server = NetHarness.start_server(_server_viewport, config)
	await wait_physics_frames(3)


func _add_bot(realm: int, bot_seed: int) -> NetClient:
	var viewport: SubViewport = NetHarness.make_world_viewport(_root, "")
	_client_viewports.append(viewport)
	var client: NetClient = NetHarness.start_bot(viewport, _port, realm, bot_seed)
	_clients.append(client)
	return client


func _wait_until(condition: Callable, max_frames: int = WAIT_FRAMES) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await tree.physics_frame
	return condition.call()


## Dos bots dentro y viéndose, y una depuración enlazada al primero (en su mismo mundo).
func _start_two_bots_with_overlay() -> NetDebugOverlay:
	await _start_server()
	var first: NetClient = _add_bot(VARDHEIM, 1)
	_add_bot(SOLMARCH, 2)
	assert_true(await _wait_until(func() -> bool:
		return first.get_state() == NetClient.State.IN_WORLD \
				and first.get_remote_world().get_view_count() == 1), "entran y se ven")
	var packed: PackedScene = load(OVERLAY_SCENE) as PackedScene
	var overlay: NetDebugOverlay = packed.instantiate() as NetDebugOverlay
	_client_viewports[0].add_child(overlay)
	overlay.bind(first)
	return overlay


func _key(keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	event.keycode = keycode
	event.pressed = true
	return event


## Número que sigue a [param label] en el texto (el primer decimal o entero), o -1 si no está.
func _number_after(text: String, label: String) -> float:
	var regex := RegEx.new()
	regex.compile(label + "\\s*(-?\\d+(?:\\.\\d+)?)")
	var found: RegExMatch = regex.search(text)
	return found.get_string(1).to_float() if found != null else -1.0


# --- Textos -----------------------------------------------------------------------------------

func test_texts_are_filled_from_a_bound_loopback_client() -> void:
	var overlay: NetDebugOverlay = await _start_two_bots_with_overlay()
	var client: NetClient = _clients[0]
	assert_not_null(overlay)
	assert_false(overlay.is_panel_visible(), "el panel empieza oculto")
	await wait_physics_frames(180)
	overlay.refresh()
	var text: String = overlay.get_text()
	for label: String in ["RTT ENet:", "al entrar:", "Por delante del servidor:", "pérdida ENet:",
			"Subida:", "Bajada:", "KB/s", "input_margin:", "ventana:", "objetivo:",
			"Ajustes de TickSync:", "Sustituciones:", "Correcciones:", "última", "máxima",
			"Ticks vueltos a simular:", "Interpolación: retardo", "jitter", "Entidades visibles:",
			"bytes por snapshot:"]:
		assert_true(text.contains(label), "el texto tiene «%s»:\n%s" % [label, text])

	var stats: Dictionary = client.get_stats()
	assert_eq(int(_number_after(text, "al entrar:")), int(stats["rtt_ticks"]), "RTT en ticks")
	assert_eq(int(_number_after(text, "objetivo:")), int(stats["target_margin"]), "margen objetivo")
	assert_eq(int(_number_after(text, "Ajustes de TickSync:")), int(stats["tick_sync_adjustments"]))
	assert_eq(int(_number_after(text, "Sustituciones:")), int(stats["substitutions_total"]))
	assert_eq(int(_number_after(text, "Correcciones:")), int(stats["corrections"]))
	assert_eq(int(_number_after(text, "Ticks vueltos a simular:")), int(stats["resimulated_ticks"]))
	assert_eq(_number_after(text, "Entidades visibles:"), 1.0, "ve a un remoto")
	assert_true(text.contains("Entidades visibles: 1 de 1"), "y lo tiene dibujado")
	var delay: float = _number_after(text, "retardo")
	assert_near(delay, float(stats["delay_ticks"]), 0.06, "retardo de interpolación en ticks")
	assert_true(delay >= 4.0 and delay <= 12.0, "dentro de lo que fija el reloj (%.1f)" % delay)
	var margin_line := RegEx.new()
	margin_line.compile("input_margin: (—|-?\\d+) · ventana: (—|-?\\d+) · objetivo: \\d")
	assert_not_null(margin_line.search(text), "línea del margen de entrada:\n%s" % text)
	# Tráfico real: el cliente sube sus entradas (~5 KB/s) y baja snapshots (algunos KB/s).
	var up: float = _number_after(text, "Subida:")
	var down: float = _number_after(text, "Bajada:")
	assert_true(up > 0.5 and up < 40.0, "subida plausible (%.1f KB/s)" % up)
	assert_true(down > 0.5 and down < 40.0, "bajada plausible (%.1f KB/s)" % down)
	var snapshot_bytes: float = _number_after(text, "bytes por snapshot:")
	assert_true(snapshot_bytes >= 20.0 and snapshot_bytes <= float(NetProtocol.MAX_PACKET_BYTES),
			"bytes por snapshot plausibles (%.0f)" % snapshot_bytes)
	# Con tan poca historia no hay tasas por minuto.
	assert_true(text.contains("(%s)" % NetDebugOverlay.TEXT_NO_VALUE), "sin tasa por minuto aún")


func test_per_minute_rates_appear_with_enough_history() -> void:
	var overlay: NetDebugOverlay = await _start_two_bots_with_overlay()
	var client: NetClient = _clients[0]
	# Dos lecturas separadas 30 s de reloj ficticio: la ventana ya basta para dar tasas por minuto.
	# Sin el refresco automático, que usaría el reloj de verdad.
	overlay.set_process(false)
	overlay.refresh(1000.0)
	await wait_physics_frames(60)
	overlay.refresh(1030.0)
	var text: String = overlay.get_text()
	var regex := RegEx.new()
	regex.compile("Ajustes de TickSync: (\\d+) \\((\\d+\\.\\d)/min\\)")
	var found: RegExMatch = regex.search(text)
	if assert_not_null(found, "ajustes por minuto:\n%s" % text):
		var per_minute: float = found.get_string(2).to_float()
		var moved: int = int(client.get_stats()["tick_sync_adjustments"])
		assert_true(per_minute >= 0.0 and per_minute <= float(moved) * 2.0 + 0.1,
				"coherente con los ajustes (%.1f/min con %d)" % [per_minute, moved])
	assert_true(text.contains("/min)"), "las tres tasas por minuto")
	assert_false(text.contains("Sustituciones: 0 (%s)" % NetDebugOverlay.TEXT_NO_VALUE))
	# Si el cliente se va, el texto no falla.
	_clients[0].leave()
	await wait_physics_frames(30)
	overlay.refresh(1031.0)
	assert_false(overlay.get_text().is_empty())


func test_an_unbound_overlay_says_so_and_a_freed_client_does_not_break_it() -> void:
	var packed: PackedScene = load(OVERLAY_SCENE) as PackedScene
	var overlay: NetDebugOverlay = packed.instantiate() as NetDebugOverlay
	_root.add_child(overlay)
	overlay.refresh()
	assert_true(overlay.get_text().contains("sin cliente"), overlay.get_text())
	var orphan := NetClient.new()
	overlay.bind(orphan)
	overlay.refresh()
	assert_true(overlay.get_text().contains("RTT ENet:"), "con un cliente sin sesión también")
	orphan.free()
	overlay.refresh()
	assert_true(overlay.get_text().contains("sin cliente"), "y si se libera, vuelve a avisar")
	overlay.set_ghost_visible(true)
	await wait_process_frames(2)
	assert_false(overlay.get_ghost().visible, "sin cliente no hay fantasma que dibujar")


# --- F3 y F4 ----------------------------------------------------------------------------------

func test_f3_toggles_the_panel_and_f4_the_ghost_and_sample_marks() -> void:
	var overlay: NetDebugOverlay = await _start_two_bots_with_overlay()
	var viewport: SubViewport = _client_viewports[0]
	var client: NetClient = _clients[0]
	assert_false(overlay.is_panel_visible())
	assert_false(overlay.is_ghost_visible())
	assert_false(overlay.get_ghost().visible, "el fantasma empieza oculto")
	assert_false(overlay.get_sample_marks().visible)

	viewport.push_input(_key(KEY_F3))
	assert_true(overlay.is_panel_visible(), "F3 muestra el panel")
	assert_false(overlay.is_ghost_visible(), "pero no el fantasma")
	viewport.push_input(_key(KEY_F3))
	assert_false(overlay.is_panel_visible(), "y otra vez F3 lo oculta")

	await wait_physics_frames(120)
	viewport.push_input(_key(KEY_F4))
	assert_true(overlay.is_ghost_visible(), "F4 enciende el fantasma")
	await wait_process_frames(2)
	var ghost: MeshInstance3D = overlay.get_ghost()
	assert_true(ghost.visible)
	overlay.update_ghost()
	var server_state: PlayerState = client.get_last_server_state()
	assert_not_null(server_state)
	assert_vec_near(ghost.global_position,
			server_state.position + Vector3(0.0, NetDebugOverlay.GHOST_HEIGHT * 0.5, 0.0), 0.01,
			"el fantasma está en el último estado propio del servidor")
	var character: PlayerCharacter = client.get_character()
	assert_true(ghost.global_position.distance_to(character.global_position) < 6.0,
			"cerca del personaje, que va unos ticks por delante")
	var material: StandardMaterial3D = ghost.mesh.material as StandardMaterial3D
	assert_not_null(material)
	assert_eq(material.transparency, BaseMaterial3D.TRANSPARENCY_ALPHA, "translúcido")
	assert_true(material.albedo_color.a < 1.0 and material.albedo_color.a > 0.0)

	# Una marca por cada muestra guardada del remoto, en su posición sin interpolar. (Sin pantalla,
	# el MultiMesh no devuelve las transformaciones, así que se comprueban las posiciones que se le
	# pasan.)
	var view: RemotePlayerView = client.get_remote_world().get_views()[0]
	var current: PackedVector3Array = view.get_sample_positions()
	assert_true(current.size() > 5, "el remoto tiene muestras (%d)" % current.size())
	var marks: MultiMeshInstance3D = overlay.get_sample_marks()
	assert_true(marks.visible)
	assert_eq(marks.multimesh.instance_count, current.size(), "una marca por muestra")
	assert_eq(overlay.get_mark_positions(), current, "en la posición de cada muestra")
	var newest: Vector3 = current[current.size() - 1]
	assert_true(newest.distance_to(_clients[1].get_character().global_position) < 25.0,
			"la última muestra es del otro bot, que pasea cerca")

	viewport.push_input(_key(KEY_F4))
	assert_false(overlay.is_ghost_visible(), "F4 otra vez lo apaga")
	assert_false(ghost.visible)
	assert_false(marks.visible)


func test_f3_does_not_mark_the_event_as_handled() -> void:
	var overlay: NetDebugOverlay = await _start_two_bots_with_overlay()
	var viewport: SubViewport = _client_viewports[0]
	var seen: Array[bool] = []
	# Un nodo posterior en el árbol que escucha F3 en _unhandled_input, como el HUD.
	var listener: Node = (load("res://tests/net_debug_listener.gd") as GDScript).new() as Node
	listener.set_meta(&"seen", seen)
	viewport.add_child(listener)
	viewport.push_input(_key(KEY_F3))
	assert_true(overlay.is_panel_visible())
	assert_eq(seen.size(), 1, "el HUD sigue recibiendo F3 después de la depuración de red")


# --- En OnlineMain ----------------------------------------------------------------------------

func test_online_main_starts_with_both_debug_panels_hidden_and_f3_toggles_them_together() -> void:
	await _start_server()
	var config := ClientConfig.new()
	config.mode = ClientConfig.Mode.ONLINE
	config.port = _port
	config.realm = VARDHEIM
	config.display_name = "Ana"
	OnlineMain.config = config
	OnlineMain.quit_hook = func(_code: int) -> void: pass
	var packed: PackedScene = load(ONLINE_SCENE) as PackedScene
	_online = packed.instantiate() as OnlineMain
	tree.root.add_child(_online)
	assert_true(await _wait_until(func() -> bool:
		return _online.get_client().get_state() == NetClient.State.IN_WORLD), "entra")
	var overlay: NetDebugOverlay = _online.get_net_debug()
	var hud: HUD = _online.get_hud()
	if not assert_not_null(overlay, "hay depuración de red") or not assert_not_null(hud):
		return
	var hud_panel: Control = hud.get_node(^"DebugPanel") as Control
	assert_false(overlay.is_panel_visible(), "el panel de red empieza oculto")
	assert_false(hud_panel.visible, "y el del HUD también, en modo red")

	tree.root.push_input(_key(KEY_F3))
	assert_true(overlay.is_panel_visible(), "F3 muestra el de red")
	assert_true(hud_panel.visible, "y el del HUD, junto a él")
	await wait_physics_frames(30)
	assert_true(overlay.get_text().contains("Subida:"), "con datos")

	tree.root.push_input(_key(KEY_F3))
	assert_false(overlay.is_panel_visible())
	assert_false(hud_panel.visible, "F3 los oculta a la vez")


func test_the_offline_hud_keeps_its_debug_panel_visible_by_default() -> void:
	# El sandbox sin red no cambia: el panel del HUD sigue visible hasta que F3 lo oculta.
	var packed: PackedScene = load("res://scenes/ui/hud.tscn") as PackedScene
	var hud: HUD = packed.instantiate() as HUD
	_root.add_child(hud)
	var panel: Control = hud.get_node(^"DebugPanel") as Control
	assert_true(panel.visible, "visible por omisión")
	hud.set_debug_visible(false)
	assert_false(panel.visible)
	hud.set_debug_visible(true)
	assert_true(panel.visible)
