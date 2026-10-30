class_name ProgressService
extends RefCounted
## El progreso de los personajes en la zona (docs/progresion.md §9): la carga antes del WELCOME
## ([method prepare]), el alta ([method on_arrival]), la sección [code]progress[/code] de [CharacterSaver]
## ([method setup] la registra la primera) y la baja ([method on_departure]). Cada personaje con peer tiene un
## [PlayerProgress] atado a su [code]net_id[/code] desde el alta hasta la baja; los jugadores falsos no tienen
## ninguno, y todo gancho por [code]net_id[/code] sobre uno sin [PlayerProgress] no hace nada (§9.2).
## [br][br]
## [b]progresion.md P5a[/b] hace la carga, la sección, los ids y, en el alta, atar el [PlayerProgress] preparado al
## cuerpo y darle el kit de inicio (marcado crítico, §2.5). Lo demás del alta (la regla de volver al mundo, los
## temporizadores, nivel y apariencia en la entidad y el [ProgressService.Loadout] en lugar de la plantilla), los
## efímeros sin plataforma y el inventario en la red son de P5b: hasta entonces [method on_arrival] devuelve null
## y el alta usa la plantilla, como antes.
## [br][br]
## [b]Ids[/b] ([IdAllocator], §4.5): sin plataforma, [method IdAllocator.local]; con ella, los bloques que llegan
## como eventos [code]id_block[/code] (el primero, del arranque de la plataforma, en el primer «poll») y uno nuevo
## cada vez que quedan pocos ([signal IdAllocator.running_low]), con uno en vuelo como mucho.

## La clave de la sección en el cuerpo del guardado (plataforma.md §7.1).
const SECTION: StringName = &"progress"
## Texto del REJECT UNAVAILABLE si el registro no se puede leer (plataforma.md §5.2).
const PREPARE_FAILED_TEXT: String = "No se ha podido cargar el personaje"
## Crítico del kit de inicio (§9.2).
const CRITICAL_STARTER_KIT: StringName = &"starter_kit"


## Las armas, la ranura activa y las cargas con las que el alta y la reaparición equipan al personaje en lugar de
## la plantilla (§8; lo rellena P5b).
class Loadout:
	extends RefCounted
	var weapon_1: int = 0
	var weapon_2: int = 0
	var second_active: bool = false
	var charges: int = 0


## Registro (un [Callable] con un texto); sin él, print.
var log_sink: Callable = Callable()

var _zone: ZoneServer = null
var _platform: ZonePlatform = null
var _saver: CharacterSaver = null
var _commands: CommandRegistry = null
var _ids: IdAllocator = null
var _db: ItemDatabase = null
## peer_id -> lo preparado en la reclamación, hasta el alta o la baja en LOADING.
var _prepared: Dictionary[int, PlayerProgress] = {}
## net_id -> el progreso del cuerpo.
var _players: Dictionary[int, PlayerProgress] = {}
## Un bloque pedido y sin respuesta (el primero llega del arranque de la plataforma).
var _block_pending: bool = false
var _stats: Dictionary[StringName, int] = {
	&"prepared": 0, &"prepare_failed": 0, &"appearance_replaced": 0, &"cancelled": 0, &"arrivals": 0,
	&"kits": 0, &"kits_deferred": 0, &"departures": 0, &"blocks": 0, &"block_requests": 0, &"unbuilt": 0,
}


## Engancha el servicio a [param zone]: con [param platform] y [param saver] (null sin plataforma, §9.4), registra la
## sección [code]progress[/code] en [param saver] (la primera: es la única que puede devolver [code]{}[/code], y
## [CharacterSaver] no deshace lo que haya construido otra antes en ese intento) y usa los bloques de la plataforma;
## sin ella, ids locales. [param commands] es para los comandos de GM (P5d).
func setup(zone: ZoneServer, platform: ZonePlatform, saver: CharacterSaver, commands: CommandRegistry) -> void:
	_zone = zone
	_platform = platform
	_saver = saver
	_commands = commands
	_db = ItemDatabase.shared()
	if _platform == null:
		_ids = IdAllocator.local()
	else:
		_ids = IdAllocator.new()
		var max_players: int = zone.get_config().max_players if zone != null and zone.get_config() != null \
				else ServerConfig.DEFAULT_MAX_PLAYERS
		_ids.build_reserve = 2 * maxi(max_players, 1)
		_ids.running_low.connect(_check_ids)
	if _saver != null:
		_saver.register_section(SECTION, _build, _acknowledge, _is_dirty)


## Arranque de la zona en el tick [param s]: con plataforma, el primer bloque ya está pedido (lo pide el arranque de
## [ZonePlatform] antes de [signal ZonePlatform.startup_finished]) y llega como evento en el primer «poll».
func start(_s: int) -> void:
	_block_pending = _platform != null


## Paso (3) de plataforma.md §5.2, antes del WELCOME (§9.1 paso 2): lee el registro de la reclamación
## ([method ProgressRecord.from_dictionary]), valida la apariencia con la raza y el reino del personaje (una que no
## vale se sustituye por la de por defecto de su raza, con aviso, sin echar al jugador) y prepara su
## [PlayerProgress] para el alta. false si el registro no se puede leer: la zona responde REJECT UNAVAILABLE
## ([constant PREPARE_FAILED_TEXT]), lo registra como alerta y libera.
func prepare(peer_id: int, claimed: ClaimedCharacter) -> bool:
	if claimed == null:
		return false
	var record: ProgressRecord = ProgressRecord.from_dictionary(claimed.progress, _db)
	if record == null:
		_stats[&"prepare_failed"] += 1
		_alert("el registro del personaje %d no se puede leer: se rechaza su entrada" % claimed.character_id)
		return false
	_check_appearance(record, claimed)
	var player := PlayerProgress.new(record, true, _ids, _db)
	player.character_id = claimed.character_id
	player.account_id = claimed.account_id
	_prepared[peer_id] = player
	_stats[&"prepared"] += 1
	return true


## La baja en LOADING (§9.1 paso 3): descarta lo preparado para [param peer_id]. Sin nada, nada.
func cancel_prepared(peer_id: int) -> void:
	if _prepared.erase(peer_id):
		_stats[&"cancelled"] += 1


## El alta de [param entity] (§9.1 paso 4), tras [method CharacterSaver.track] y antes del SPAWN: ata el
## [PlayerProgress] preparado para [param peer] al [code]net_id[/code], toma la foto del cuerpo como confirmada
## (entrar sin cambiar nada no ensucia) y, en la primera entrada, da el kit de inicio de su plantilla y lo marca
## crítico. Devuelve el [ProgressService.Loadout] con el que el alta equipa al personaje en lugar de la plantilla:
## null hasta P5b (y siempre con quien no tiene [PlayerProgress]: un efímero hasta P5b).
func on_arrival(entity: NetEntity, peer: ServerPeer, s: int) -> Loadout:
	if entity == null or peer == null:
		return null
	var player: PlayerProgress = _prepared.get(peer.peer_id)
	if player == null:
		return null
	_prepared.erase(peer.peer_id)
	var net_id: int = entity.net_id
	player.arrival_tick = s
	player.played_base = player.record.played_seconds
	# Un Callable de método (sin lambda): no guarda una referencia fuerte al servicio ni al propio progreso.
	player.live_source = Callable(self, "_live_of").bind(net_id)
	_players[net_id] = player
	player.confirm_current()
	_stats[&"arrivals"] += 1
	if not player.record.starter_granted:
		if player.grant_starter_kit(player.record.starter_template_id):
			_stats[&"kits"] += 1
			if _saver != null:
				_saver.mark_critical(net_id, CRITICAL_STARTER_KIT)
		else:
			_stats[&"kits_deferred"] += 1
			_log("Progreso: el kit de inicio del personaje %d se aplaza (sin ids del servidor)" % player.character_id)
	return null


## true si [param net_id] tiene [PlayerProgress] (un jugador con peer).
func has_inventory(net_id: int) -> bool:
	return _players.has(net_id)


## El nivel de [param net_id]; 0 sin [PlayerProgress].
func level_of(net_id: int) -> int:
	var player: PlayerProgress = _players.get(net_id)
	return player.record.level if player != null else 0


## El progreso atado a [param net_id], o null (pruebas y paquetes siguientes).
func get_player(net_id: int) -> PlayerProgress:
	return _players.get(net_id)


## Lo preparado para [param peer_id] y aún sin alta, o null.
func get_prepared(peer_id: int) -> PlayerProgress:
	return _prepared.get(peer_id)


## El generador de ids de la zona.
func get_ids() -> IdAllocator:
	return _ids


## Un evento de la plataforma de los suyos (§14.2): [code]id_block[/code] (un bloque nuevo; si quedan pocos, pide
## otro), [code]progress_op[/code] y [code]progress_ledger[/code] (las respuestas de [code]op_show[/code] y
## [code]ledger_show[/code], P5d: hasta entonces se descartan). true si era suyo.
func on_platform_event(event: PlatformEvent) -> bool:
	match event.kind:
		PlatformEvent.KIND_ID_BLOCK:
			_block_pending = false
			var body: Dictionary = event.body_dict()
			var first: Variant = body.get("first")
			if event.is_success() and ProgressJson.is_id(first) \
					and ProgressJson.is_int(body.get("count"), 1, IdAllocator.BLOCK_SIZE * 64):
				_ids.add_block(ProgressJson.id_value(first), int(body["count"]))
				_stats[&"blocks"] += 1
			else:
				_alert("bloque de ids que no vale o rechazado: %s" % ZonePlatform.describe(event))
			_check_ids()
			return true
		PlatformEvent.KIND_PROGRESS_OP, PlatformEvent.KIND_PROGRESS_LEDGER:
			return true
	return false


## La baja de [param net_id] (§9.2), tras [method CharacterSaver.finish] y [method ScoreKeeper.forget], o en la baja
## sin guardado: descarta su estado. Sobre un [code]net_id[/code] sin [PlayerProgress], nada.
func on_departure(net_id: int) -> void:
	if _players.erase(net_id):
		_stats[&"departures"] += 1


## Contadores para el informe y las pruebas.
func get_stats() -> Dictionary:
	var stats: Dictionary = {}
	for key: StringName in _stats:
		stats[String(key)] = _stats[key]
	stats["players"] = _players.size()
	stats["prepared_now"] = _prepared.size()
	stats["ids_available"] = _ids.available() if _ids != null and not _ids.is_local() else -1
	return stats


# --- La sección progress de CharacterSaver (§9.2) ------------------------------------------------

func _build(net_id: int, seq: int) -> Dictionary:
	var player: PlayerProgress = _players.get(net_id)
	if player == null:
		_alert("se pide el guardado del net_id %d, que no tiene progreso" % net_id)
		return {}
	var section: Dictionary = player.build_section(seq)
	if section.is_empty():
		_stats[&"unbuilt"] += 1
		_alert("sin ids para cerrar lo agregado del personaje %d: el guardado se aplaza" % player.character_id)
	return section


func _acknowledge(net_id: int, seq: int) -> void:
	var player: PlayerProgress = _players.get(net_id)
	if player != null:
		player.acknowledge(seq)


func _is_dirty(net_id: int) -> bool:
	var player: PlayerProgress = _players.get(net_id)
	return player != null and player.is_dirty()


# --- Interno -------------------------------------------------------------------------------------

# Pide un bloque si quedan pocos y no hay otro en vuelo.
func _check_ids() -> void:
	if _platform == null or _block_pending or not _ids.needs_block():
		return
	_block_pending = true
	_stats[&"block_requests"] += 1
	_platform.request_id_block()


# §7.2: la apariencia vale para la raza del registro y el reino del personaje; si no, la de por defecto de la raza
# (o, si la raza no es de ese reino, la del pueblo del reino), con aviso. Raza y apariencia son de solo lectura: el
# cambio solo vive en la zona.
func _check_appearance(record: ProgressRecord, claimed: ClaimedCharacter) -> void:
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	var appearance: CharacterAppearance = CharacterAppearance.decode(record.appearance)
	if appearance != null and appearance.validate(catalog, claimed.realm, record.race_id):
		return
	var race_index: int = catalog.race_index(record.race_id)
	var race: RaceDefinition = catalog.races[race_index] if race_index >= 0 else null
	if race == null or race.realm != RealmCatalog.id_of_code(claimed.realm):
		race = catalog.race_for_realm(RealmCatalog.id_of_code(claimed.realm))
		race_index = catalog.race_index(race.id) if race != null else -1
	var fallback: CharacterAppearance = CharacterAppearance.default_for(catalog, race_index)
	_stats[&"appearance_replaced"] += 1
	if fallback == null:
		_alert("la apariencia del personaje %d no vale y su reino no tiene raza: se deja como está"
				% claimed.character_id)
		return
	_alert("la apariencia del personaje %d no vale para %s: se usa la de por defecto de %s" % [claimed.character_id,
			record.race_id, race.id])
	record.race_id = race.id
	record.appearance = fallback.encode()


# Lo que aporta el cuerpo de [param net_id] a la foto de su progreso; null si ya no tiene cuerpo ni progreso.
func _live_of(net_id: int) -> PlayerProgress.Live:
	var player: PlayerProgress = _players.get(net_id)
	if _zone == null or player == null:
		return null
	var entity: NetEntity = _zone.get_registry().get_entity(net_id)
	var character: PlayerCharacter = entity.get_character() if entity != null else null
	var combatant: Combatant = _zone.get_combat().get_combatant(net_id) if _zone.get_combat() != null else null
	if character == null or combatant == null:
		return null
	var tick: int = _zone.get_tick()
	var config: ServerConfig = _zone.get_config()
	var position: Vector3 = entity.get_position()
	var live := PlayerProgress.Live.new()
	live.location = {
		"zone_id": config.zone_id if config != null else "",
		"channel": config.channel if config != null else 0,
		"x": PlayerState.to_f32(position.x), "y": PlayerState.to_f32(position.y),
		"z": PlayerState.to_f32(position.z), "yaw": PlayerState.to_f32(character.yaw),
		"in_combat": combatant.is_in_combat(tick),
	}
	live.health = -1 if combatant.health >= combatant.max_health else maxi(combatant.health, 0)
	live.active_weapon_slot = 1 if character.combat.is_second_slot() else 0
	var elapsed_ticks: int = maxi(tick - player.arrival_tick, 0)
	live.played_seconds = player.played_base + elapsed_ticks / maxi(Engine.physics_ticks_per_second, 1)
	live.now_unix = _platform.now_unix() if _platform != null else 0
	return live


func _alert(text: String) -> void:
	push_warning("[Eldmark] Progreso: alerta: %s" % text)
	_log("Progreso: alerta: %s" % text)


func _log(text: String) -> void:
	if log_sink.is_valid():
		log_sink.call(text)
	else:
		print("[Eldmark] %s" % text)
