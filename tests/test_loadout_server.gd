extends TestCase
## Pruebas de las plantillas de equipo en el servidor (PRG-07, PRG-04; docs/habilidades.md, secciones 3.5, 4.6 y
## 5.1; paquete H3c): el jugador aparece con la plantilla de por defecto o con la que le dan
## ([code]--fake-loadout[/code]) y lo anuncia con LOADOUT (la del dueño con cargas y la pública sin ellas);
## LOADOUT_SELECT antes de CLIENT_READY decide la plantilla del alta (desde progresion.md P5b, el kit de inicio del
## personaje efímero, que va con el equipo de su inventario y ya no cambia en el mundo), y un id que no existe o no se
## puede elegir cuenta un aviso; el comando 5 pone el arma en la ranura 1 y conserva la 2, con su LOADOUT, y no vale
## con un derribado.
## [br][br]
## Jugadores falsos y peers montados a mano (sin red) sobre la zona plana de [ZoneFixture] (montaje de [NpcRig]).

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const LOADOUT: int = NetMessages.EntityEvent.Kind.LOADOUT
const PEER_ID: int = 77

var _rig: NpcRig = null
var _events: Array[NetMessages.EntityEvent] = []
var _involved: Array[PackedInt32Array] = []
# Plantillas de prueba añadidas a las tablas del catálogo (se quitan en after_each).
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


# --- Ayudantes --------------------------------------------------------------------------------

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


## Comprueba las dos LOADOUT de un cambio de armas: la del dueño (implicado él, con [param charges]) y la pública
## (sin implicados, con 0 cargas), con [param template] y las armas [param weapons].
func _assert_pair(events: Array[NetMessages.EntityEvent], net_id: int, template: int, weapons: Array[int],
		charges: int) -> void:
	if not assert_eq(events.size(), 2, "la del dueño y la pública"):
		return
	for event: NetMessages.EntityEvent in events:
		assert_eq(event.template_id, template, "plantilla")
		assert_eq([event.weapon_1, event.weapon_2], weapons, "armas en orden de ranura")
	assert_eq(events[0].charges, charges, "el dueño, con sus cargas")
	assert_eq(_involved_of(events[0]), PackedInt32Array([net_id]))
	assert_eq(events[1].charges, 0, "los demás, sin ellas")
	assert_eq(_involved_of(events[1]), PackedInt32Array(), "a quien lo tenga por relevante")


## Un peer que acaba de recibir el WELCOME (cargando la zona), montado a mano en el servidor.
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


## Añade a las tablas una plantilla que no se puede elegir (after_each la quita) y devuelve su id.
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


# --- Al aparecer ------------------------------------------------------------------------------

func test_a_player_appears_with_the_default_template_and_announces_it() -> void:
	await _start()
	var squire: int = _template(&"squire")
	assert_eq(CombatCatalog.default_template_id(), squire, "el escudero es la de por defecto")
	var ana: int = _server().add_fake_player(CombatFixture.ScriptBrain.new(1), VARDHEIM)
	var combat: CombatState = _combat_of(ana)
	assert_eq(_server().get_combat().get_combatant(ana).template_id, squire)
	assert_eq([combat.weapon_id, combat.alt_weapon_id], [_weapon(&"sword_shield"), 0])
	assert_false(combat.is_second_slot())
	assert_eq(combat.consumable_charges, CombatState.pack_charges(3, 2), "3 y 2 pociones")
	_assert_pair(_loadouts(ana), ana, squire, [_weapon(&"sword_shield"), 0], CombatState.pack_charges(3, 2))
	# --fake-loadout: el tirador.
	var marksman: int = _template(&"marksman")
	var bo: int = _server().add_fake_player(CombatFixture.ScriptBrain.new(2), SOLMARCH, marksman)
	combat = _combat_of(bo)
	assert_eq([combat.weapon_id, combat.alt_weapon_id], [_weapon(&"bow"), _weapon(&"sword_shield")],
			"arco activo y espada en la ranura 2")
	assert_eq(combat.consumable_charges, CombatState.pack_charges(2, 3))
	_assert_pair(_loadouts(bo), bo, marksman, [_weapon(&"bow"), _weapon(&"sword_shield")],
			CombatState.pack_charges(2, 3))
	# El SPAWN ajeno ya lleva las dos armas.
	var spawn: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(
			_rig.entity(bo).encode_spawn(_server().get_tick(), false))
	assert_eq(spawn.state.combat.alt_weapon_id, _weapon(&"sword_shield"))
	assert_eq(spawn.state.combat.consumable_charges, 0, "sin las cargas")


func test_loadout_select_before_client_ready_decides_the_template_of_the_arrival() -> void:
	await _start()
	var marksman: int = _template(&"marksman")
	var peer: ServerPeer = _loading_peer("Ana", SOLMARCH)
	assert_eq(peer.pending_template_id, -1, "sin petición")
	var strikes: int = peer.strikes_total
	_select(marksman)
	assert_eq(peer.pending_template_id, marksman, "anotada mientras carga la zona")
	assert_eq(peer.strikes_total, strikes, "sin aviso")
	_select(200)
	assert_eq(peer.strikes_total, strikes + 1, "una que no existe cuenta un aviso")
	assert_eq(peer.pending_template_id, marksman, "y no cambia nada")
	_select(_inject_unselectable())
	assert_eq(peer.strikes_total, strikes + 2, "una que no se puede elegir, también")
	assert_eq(peer.pending_template_id, marksman)
	_server()._on_packet_received(PEER_ID, PackedByteArray([NetProtocol.MSG_LOADOUT_SELECT]))
	assert_eq(peer.strikes_total, strikes + 3, "mal formado, otro")
	# CLIENT_READY: aparece al final del siguiente tick con el arco. Sin plataforma es un personaje efímero con
	# inventario (progresion.md §9.4, P5b): la plantilla pedida es su kit de inicio y lo equipa su inventario
	# (plantilla vigente 0 en LOADOUT, «el equipo del inventario»), con las cargas de las pociones de su bolsa.
	_server()._pending_ready.append(PEER_ID)
	await _rig.advance(1)
	if not assert_not_null(peer.entity, "en el mundo"):
		return
	var net_id: int = peer.entity.net_id
	var combatant: Combatant = _server().get_combat().get_combatant(net_id)
	assert_true(_server().get_progress().has_inventory(net_id), "con inventario")
	assert_eq(combatant.template_id, 0, "el equipo del inventario, con el kit de la plantilla pedida")
	assert_eq(peer.pending_template_id, -1, "que deja de estar pendiente")
	assert_eq([_combat_of(net_id).weapon_id, _combat_of(net_id).alt_weapon_id],
			[_weapon(&"bow"), _weapon(&"sword_shield")])
	_assert_pair(_loadouts(net_id), net_id, 0, [_weapon(&"bow"), _weapon(&"sword_shield")],
			CombatState.pack_charges(3, 2))
	# Con inventario, LOADOUT_SELECT ya no cambia nada tras el alta (progresion.md §2.5), tampoco la siguiente
	# aparición; un id que no existe sigue sumando su aviso.
	_select(0)
	assert_eq(peer.pending_template_id, -1, "no queda pendiente")
	assert_eq(peer.strikes_total, strikes + 3, "0 no cuenta aviso")
	_select(200)
	assert_eq(peer.strikes_total, strikes + 4, "uno que no existe, sí")
	_server().console_command("kill %d" % net_id)
	await _rig.advance(2)
	var wait: int = combatant.respawn_tick - _server().get_tick()
	await _rig.advance(maxi(wait, 0) + 2)
	_events.clear()
	_involved.clear()
	assert_eq(_server().get_combat().request_respawn(net_id, 0, _server().get_tick() + 1),
			CombatDirector.RespawnRequestResult.ACCEPTED)
	await _rig.advance(3)
	assert_true(combatant.is_alive(), "reaparece")
	assert_eq(combatant.template_id, 0, "con su equipo")
	assert_eq([_combat_of(net_id).weapon_id, _combat_of(net_id).alt_weapon_id],
			[_weapon(&"bow"), _weapon(&"sword_shield")], "las mismas armas")
	assert_eq(_combat_of(net_id).consumable_charges, CombatState.pack_charges(3, 2))
	var loadouts: Array[NetMessages.EntityEvent] = _loadouts(net_id)
	if assert_eq(loadouts.size(), 1, "sin cambio de armas, LOADOUT solo al dueño"):
		assert_eq([loadouts[0].template_id, loadouts[0].weapon_1, loadouts[0].weapon_2],
				[0, _weapon(&"bow"), _weapon(&"sword_shield")])


func test_reappearing_with_the_same_template_only_tells_the_owner() -> void:
	await _start()
	var ana: int = _server().add_fake_player(CombatFixture.ScriptBrain.new(1), VARDHEIM)
	var combatant: Combatant = _server().get_combat().get_combatant(ana)
	# Que la pida la prueba, como una persona (un falso la pide solo al morir).
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
	if assert_eq(loadouts.size(), 1, "las armas no cambian: solo la del dueño"):
		assert_eq(_involved_of(loadouts[0]), PackedInt32Array([ana]))
		assert_eq(loadouts[0].charges, CombatState.pack_charges(3, 2), "con las cargas llenas otra vez")


# --- Comando 5 --------------------------------------------------------------------------------

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
			"el arma nueva en la ranura 1, la 2 se queda")
	assert_eq(combat.ability_ready, PackedInt64Array([0, 0, 0, 0, 0, 0]), "reutilizaciones a 0 (set_loadout)")
	assert_eq(combat.consumable_charges, CombatState.pack_charges(1, 1), "las cargas no cambian")
	_assert_pair(_loadouts(ana), ana, marksman, [hollow_weapon, _weapon(&"sword_shield")],
			CombatState.pack_charges(1, 1))
	# La misma de la ranura 2: queda sola.
	assert_true(_server().console_command("set_weapon %d sword_shield" % ana).contains("lleva ahora"))
	assert_eq([_combat_of(ana).weapon_id, _combat_of(ana).alt_weapon_id], [_weapon(&"sword_shield"), 0])
	payload.encode_u16(0, 999)
	assert_eq(_server().get_commands().execute_network(peer, NetProtocol.DEBUG_SET_WEAPON, payload),
			CommandRegistry.Result.BAD_ARGUMENTS, "un arma que no existe")
	# Derribado, no: set_loadout lo pondría en NONE.
	assert_true(_server().get_combat().down(_server().get_combat().get_combatant(ana), _server().get_tick() + 1))
	payload.encode_u16(0, hollow_weapon)
	assert_eq(_server().get_commands().execute_network(peer, NetProtocol.DEBUG_SET_WEAPON, payload),
			CommandRegistry.Result.REFUSED, "derribado")
	assert_eq(_combat_of(ana).action, CombatState.Action.DOWNED)


# --- --fake-loadout ---------------------------------------------------------------------------

func test_fake_loadout_gives_the_template_to_a_share_of_the_fakes_in_order() -> void:
	var all: ServerConfig = ServerConfig.from_args(PackedStringArray(["--fake-loadout=marksman"]))
	var marksman: int = _template(&"marksman")
	assert_eq(all.fake_loadout, &"marksman")
	assert_eq(all.fake_loadout_percent, 100)
	assert_eq([all.fake_template_for(0), all.fake_template_for(1), all.fake_template_for(2)],
			[marksman, marksman, marksman], "a todos")
	var half: ServerConfig = ServerConfig.from_args(PackedStringArray(["--fake-loadout=marksman:50"]))
	var given: Array[int] = []
	for index: int in 6:
		given.append(half.fake_template_for(index))
	assert_eq(given, [0, marksman, 0, marksman, 0, marksman], "con 50, uno de cada dos")
	var none: ServerConfig = ServerConfig.from_args(PackedStringArray())
	assert_eq(none.fake_template_for(0), 0, "sin la opción, la de por defecto")
	for invalid: String in ["--fake-loadout=hacha", "--fake-loadout=marksman:0", "--fake-loadout=marksman:101",
			"--fake-loadout=marksman:x", "--fake-loadout=marksman:50:2", "--fake-loadout="]:
		var config: ServerConfig = ServerConfig.from_args(PackedStringArray([invalid]))
		assert_eq(config.fake_loadout, &"", "%s se ignora" % invalid)
		assert_eq(config.fake_template_for(1), 0)
