extends TestCase
## Pruebas de los iconos de estados (UI-45, docs/habilidades.md, secciones 6.4 y 7.3, H4): el
## [StatusTracker] de cada entidad sigue los STATUS ya temporizados de [NetClient] (los quitan STATUS 2,
## DEATH, DOWNED, RESPAWN y el ENTITY_DESPAWN); la fila propia del [HUD] enseña duración y acumulaciones
## contra el tick del servidor estimado y la placa de un remoto hasta 4 iconos, primero los perjudiciales,
## con la marca de derribado; los dos se van al caducar. Los eventos son sintéticos: el [StatusSystem] del
## servidor es de H3a.

const OWN_ID: int = 5
const ALLY_ID: int = 21
const HUD_SCENE_PATH: String = "res://scenes/ui/hud.tscn"
const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const CAMERA_RIG_SCENE_PATH: String = "res://scenes/client/camera_rig.tscn"


## Reloj de dibujo fijo.
class FixedClock extends InterpolationClock:
	var render: float = 0.0

	func get_render_tick() -> float:
		return render


## Cliente de red que no conecta con nada: el tick del servidor estimado y el de dibujo los fija la prueba.
class FakeClient extends NetClient:
	var fake_estimated_tick: int = 0
	var fake_clock: FixedClock = FixedClock.new()
	var fake_config: ClientConfig = ClientConfig.new()

	func get_estimated_server_tick() -> int:
		return fake_estimated_tick

	func get_interpolation_clock() -> InterpolationClock:
		return fake_clock

	func get_net_id() -> int:
		return OWN_ID

	func get_config() -> ClientConfig:
		return fake_config

	func has_health() -> bool:
		return true


var _nodes: Array[Node] = []


func after_each() -> void:
	for node: Node in _nodes:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()
	_nodes.clear()
	await wait_process_frames()


func _track(node: Node, parent: Node = null) -> Node:
	(parent if parent != null else tree.root).add_child(node)
	_nodes.append(node)
	return node


func _status(target: int, tick: int, status_name: StringName, stacks: int, until: int,
		author: int = 0) -> NetMessages.EntityEvent:
	return NetMessages.EntityEvent.status(target, tick, author, NetMessages.EntityEvent.StatusOp.APPLIED,
			CombatCatalog.status_id(status_name), stacks, until)


func _removed(target: int, tick: int, status_name: StringName) -> NetMessages.EntityEvent:
	return NetMessages.EntityEvent.status(target, tick, 0, NetMessages.EntityEvent.StatusOp.REMOVED,
			CombatCatalog.status_id(status_name), 0, tick)


func test_the_tracker_follows_status_events_and_forgets_on_death_downed_and_respawn() -> void:
	var tracker := StatusTracker.new()
	assert_true(tracker.handle_event(_status(OWN_ID, 100, &"bleed", 1, 460, 77)))
	assert_true(tracker.handle_event(_status(OWN_ID, 110, &"potion_regen", 1, 290)))
	assert_eq(tracker.size(), 2)
	# Una acumulación más renueva el mismo efecto.
	tracker.handle_event(_status(OWN_ID, 160, &"bleed", 2, 520, 77))
	assert_eq(tracker.size(), 2, "renovar no duplica")
	var bleed: StatusTracker.Entry = tracker.get_entry(CombatCatalog.status_id(&"bleed"))
	assert_eq(bleed.stacks, 2)
	assert_eq(bleed.until_tick, 520)
	assert_eq(bleed.source_entity, 77)
	assert_true(bleed.is_harmful(), "el sangrado perjudica")
	assert_false(tracker.get_entry(CombatCatalog.status_id(&"potion_regen")).is_harmful())
	# Caducar no necesita evento.
	assert_eq(tracker.get_active(289).size(), 2)
	assert_eq(tracker.get_active(290).size(), 1, "la curación acabó en su until_tick (exclusivo)")
	assert_eq(tracker.prune(300), 1)
	# STATUS 2 quita; DEATH, DOWNED y RESPAWN quitan todo.
	tracker.handle_event(_removed(OWN_ID, 200, &"bleed"))
	assert_eq(tracker.size(), 0)
	for clearing: NetMessages.EntityEvent in [NetMessages.EntityEvent.death(OWN_ID, 300, 77, 1),
			NetMessages.EntityEvent.downed(OWN_ID, 300, 77, 1), NetMessages.EntityEvent.respawn(OWN_ID, 300, 0)]:
		tracker.handle_event(_status(OWN_ID, 299, &"slowed", 1, 480))
		assert_eq(tracker.size(), 1)
		assert_true(tracker.handle_event(clearing), "el evento %d borra los efectos" % clearing.event)
		assert_eq(tracker.size(), 0)
	# Orden de las placas: primero los perjudiciales, y dentro, el que acaba antes.
	tracker.handle_event(_status(OWN_ID, 400, &"potion_regen", 1, 580))
	tracker.handle_event(_status(OWN_ID, 400, &"bleed", 1, 760))
	tracker.handle_event(_status(OWN_ID, 400, &"slowed", 1, 580))
	var ordered: Array[StatusTracker.Entry] = tracker.get_active(401, true)
	assert_eq(ordered[0].status_id, CombatCatalog.status_id(&"slowed"))
	assert_eq(ordered[1].status_id, CombatCatalog.status_id(&"bleed"))
	assert_eq(ordered[2].status_id, CombatCatalog.status_id(&"potion_regen"), "los beneficiosos, al final")
	assert_eq(tracker.get_active(401)[0].status_id, CombatCatalog.status_id(&"potion_regen"),
			"sin ordenar, en el orden en que llegaron")


func test_the_net_client_keeps_one_tracker_per_entity_and_drops_it_on_despawn() -> void:
	var client: FakeClient = _track(FakeClient.new()) as FakeClient
	assert_null(client.get_status_tracker(ALLY_ID), "sin STATUS no hay tracker")
	client._deliver_combat_event(_status(ALLY_ID, 100, &"bleed", 1, 460), false)
	client._deliver_combat_event(_status(OWN_ID, 100, &"slowed", 1, 280), true)
	assert_eq(client.get_status_tracker(ALLY_ID).size(), 1)
	assert_eq(client.get_status_tracker(OWN_ID).size(), 1)
	# Un DEATH sin tracker no crea ninguno.
	client._deliver_combat_event(NetMessages.EntityEvent.death(99, 110, 0, 0), false)
	assert_null(client.get_status_tracker(99))
	assert_eq(client.get_stats()["status_trackers"], 2)
	var despawn := NetMessages.EntityDespawn.new()
	despawn.net_id = ALLY_ID
	despawn.despawn_tick = 120
	despawn.reason = NetProtocol.DespawnReason.OUT_OF_INTEREST
	client._on_packet_received(NetClient.SERVER_PEER_ID, despawn.encode())
	assert_null(client.get_status_tracker(ALLY_ID), "el ENTITY_DESPAWN tira su tracker")
	assert_not_null(client.get_status_tracker(OWN_ID))


class HudRig:
	var hud: HUD
	var client: FakeClient
	var character: PlayerCharacter
	var rig: CameraRig


func _make_hud() -> HudRig:
	var h := HudRig.new()
	var world: Node3D = _track(Node3D.new()) as Node3D
	h.character = (load(CHARACTER_SCENE_PATH) as PackedScene).instantiate() as PlayerCharacter
	_track(h.character, world)
	h.rig = (load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate() as CameraRig
	h.rig.set_scripted_look(true)
	_track(h.rig)
	h.hud = (load(HUD_SCENE_PATH) as PackedScene).instantiate() as HUD
	_track(h.hud)
	h.hud.bind(h.character, h.rig)
	h.client = FakeClient.new()
	h.client.fake_config.realm = NetProtocol.Realm.VARDHEIM
	_track(h.client)
	h.hud.bind_net(h.client, world)
	return h


func test_the_own_row_shows_duration_and_stacks_and_goes_away_when_it_expires() -> void:
	var h: HudRig = _make_hud()
	var row: StatusIcons = h.hud.get_status_row()
	if not assert_not_null(row, "el HUD tiene la fila de efectos propios"):
		return
	assert_true(row.get_index() < h.hud.get_death_screen().get_index(), "por debajo de la pantalla de muerte")
	h.client.fake_estimated_tick = 100
	h.hud._process(0.016)
	assert_eq(row.get_shown_count(), 0, "sin efectos, vacía")
	# Un sangrado de dos acumulaciones aplicado por el servidor (seis segundos) y la curación de una poción.
	h.client._deliver_combat_event(_status(OWN_ID, 100, &"bleed", 2, 460, 77), true)
	h.client._deliver_combat_event(_status(OWN_ID, 100, &"potion_regen", 1, 280), true)
	h.client.fake_estimated_tick = 130
	h.hud._process(0.016)
	assert_eq(row.get_shown_count(), 2, "los dos efectos")
	var bleed: StatusIcons.StatusIcon = row.get_icon(0)
	assert_eq(bleed.status_id, CombatCatalog.status_id(&"bleed"))
	assert_eq(bleed.get_seconds_text(), "6", "le quedan 330 ticks: 6 s")
	assert_eq(bleed.get_stacks_text(), "2", "con sus acumulaciones")
	assert_eq(bleed.get_border_color(), StatusIcons.HARMFUL_BORDER, "borde rojo: perjudica")
	assert_true(bleed.tooltip_text.begins_with("Sangrado ×2"), "tooltip: %s" % bleed.tooltip_text)
	assert_eq(bleed.icon.get_width(), 26, "la fila propia usa la variante dibujada de 26 px")
	var regen: StatusIcons.StatusIcon = row.get_icon(1)
	assert_eq(regen.get_border_color(), StatusIcons.BENEFICIAL_BORDER, "borde verde: no perjudica")
	assert_eq(regen.get_stacks_text(), "", "una sola acumulación no se escribe")
	# Caduca sola, contra el tick estimado del servidor.
	h.client.fake_estimated_tick = 280
	h.hud._process(0.016)
	assert_eq(row.get_shown_count(), 1, "la curación se ha ido al caducar")
	h.client.fake_estimated_tick = 460
	h.hud._process(0.016)
	assert_eq(row.get_shown_count(), 0, "y el sangrado también")
	assert_eq(row.get_pool_size(), 2, "los iconos se reutilizan")


func test_a_nameplate_shows_up_to_four_icons_harmful_first_and_the_downed_mark() -> void:
	var h: HudRig = _make_hud()
	var remote_world: RemoteWorld = h.client.get_remote_world()
	remote_world.install_visuals = false
	remote_world.on_spawn(_ally_spawn(ALLY_ID, Vector3(0.0, 0.0, -8.0)))
	h.client.fake_clock.render = 50.0
	remote_world.draw(50.0, 0.0)
	var plates: Nameplates = h.hud.get_nameplates()
	plates.refresh(0.016)
	var plate: Nameplate = plates.get_plate_for(ALLY_ID)
	if not assert_not_null(plate, "el aliado tiene placa"):
		return
	assert_eq(plate.get_status_icons().get_shown_count(), 0)
	# Cinco efectos (uno desconocido): caben cuatro, primero los perjudiciales.
	for entry: Array in [[&"potion_regen", 300], [&"bleed", 400], [&"slowed", 200], [&"rooted", 250]]:
		h.client._deliver_combat_event(_status(ALLY_ID, 40, entry[0], 1, int(entry[1])), false)
	h.client._deliver_combat_event(NetMessages.EntityEvent.status(ALLY_ID, 40, 0,
			NetMessages.EntityEvent.StatusOp.APPLIED, 200, 1, 500), false)
	plates.refresh(0.016)
	var icons: StatusIcons = plate.get_status_icons()
	assert_eq(icons.get_shown_count(), Nameplate.MAX_STATUS_ICONS, "como mucho cuatro iconos")
	assert_true(icons.compact, "pequeños, sin segundos")
	assert_eq(icons.get_icon(0).get_seconds_text(), "")
	for index: int in Nameplate.MAX_STATUS_ICONS:
		assert_true(icons.get_icon(index).harmful, "los cuatro son los perjudiciales (%d)" % index)
	assert_eq(icons.get_icon(0).status_id, CombatCatalog.status_id(&"slowed"), "el que acaba antes, primero")
	assert_false(plate.is_downed())
	# Se van al caducar, contra el tick de dibujo.
	h.client.fake_clock.render = 260.0
	plates.refresh(0.016)
	assert_eq(icons.get_shown_count(), 3, "a los 260 quedan el sangrado, la curación y el desconocido")
	assert_false(icons.get_icon(icons.get_shown_count() - 1).harmful, "el beneficioso al final")
	h.client.fake_clock.render = 600.0
	plates.refresh(0.016)
	assert_eq(icons.get_shown_count(), 0, "ya no queda ninguno")
	# Derribado (la acción DOWNED de su registro dibujado): barra de derribado e icono.
	var record: EntityRecord = EntityRecord.from_state(ALLY_ID, NetProtocol.EntityKind.PLAYER,
			_ally_spawn(ALLY_ID, Vector3(0.0, 0.0, -8.0)).state, 0)
	record.action = CombatState.Action.DOWNED | (ActionMachine.PHASE_NONE << 4)
	record.health_q = EntityRecord.quantize_health(200, 400)
	remote_world.get_view(ALLY_ID).push(52, record)
	remote_world.draw(60.0, 0.0)
	plates.refresh(0.016)
	plate = plates.get_plate_for(ALLY_ID)
	assert_true(plate.is_downed(), "la placa marca el derribado")
	assert_near(plate.get_health_fraction(), 0.5, 0.01, "con la vida de derribado")


func _ally_spawn(net_id: int, feet: Vector3) -> NetMessages.EntitySpawn:
	var spawn := NetMessages.EntitySpawn.new()
	spawn.net_id = net_id
	spawn.kind = NetProtocol.EntityKind.PLAYER
	spawn.spawn_tick = 10
	spawn.realm = NetProtocol.Realm.VARDHEIM
	spawn.display_name = "Ana"
	var state := PlayerState.new()
	state.position = feet
	state.grounded = true
	spawn.state = state
	return spawn
