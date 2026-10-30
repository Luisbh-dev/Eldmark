class_name ProgressService
extends RefCounted
## El progreso de los personajes en la zona (docs/progresion.md §4, §8 y §9): la carga antes del WELCOME
## ([method prepare]), el alta ([method on_arrival] y [method after_spawn]), el inventario por la red
## ([method handle_packet] y [method apply_pending]), lo que el servidor cambia por su cuenta (CONSUME en
## [method after_simulate], CAMP_REFILL en [method camp_step]), la sección [code]progress[/code] de
## [CharacterSaver] ([method setup] la registra la primera) y la baja ([method on_departure]). Cada personaje con
## peer tiene un [PlayerProgress] atado a su [code]net_id[/code] desde el alta hasta la baja; los jugadores falsos
## no tienen ninguno, y todo gancho por [code]net_id[/code] sobre uno sin [PlayerProgress] no hace nada (§9.2).
## [br][br]
## [b]Con plataforma[/b] todo jugador con peer es persistente: su registro llega en la reclamación ([method
## prepare]) y se guarda. [b]Sin ella[/b] (§9.4) es efímero: el alta crea un personaje nuevo de su reino con el kit
## de la plantilla de LOADOUT_SELECT (o la de por defecto), ids locales y nada que guardar.
## [br][br]
## [b]El alta[/b] (§8 y §9.1): la regla de volver al mundo (en las zonas RVR, el campamento del reino, donde ya lo
## pone la zona; en las SAFE, el sitio guardado si vale), la vida guardada con la regeneración del tiempo sin
## conexión, el temporizador de /atascado, el kit de la primera entrada (crítico), el nivel y la apariencia en la
## entidad, y el [ProgressService.Loadout] con el que la zona lo equipa en lugar de la plantilla. Tras el SPAWN
## propio, [method after_spawn] manda INVENTORY_FULL, un WALLET_UPDATE por moneda y un PROGRESS_UPDATE.
## [br][br]
## [b]Peticiones[/b] (§4.2): RATE al llegar (8 por segundo con ráfaga de 16, y 2 SPLIT o DESTROY por segundo con
## ráfaga de 10; pasados los diez primeros descartes de cada 10 s, cada uno suma un aviso), en cola y aplicadas al
## final del tick tras las altas, en orden de llegada. Cada una recibe su INVENTORY_DELTA; un cambio de las
## ranuras de arma impone las armas ([method ActionMachine.set_weapons], sin reiniciar reutilizaciones) con su
## LOADOUT, y uno de la cantidad de un consumible, las cargas ([code]min(15, bolsa)[/code], §4.4).
## [br][br]
## [b]Ids[/b] ([IdAllocator], §4.5): sin plataforma, [method IdAllocator.local]; con ella, los bloques que llegan
## como eventos [code]id_block[/code] (el primero, del arranque de la plataforma, en el primer «poll») y uno nuevo
## cada vez que quedan pocos ([signal IdAllocator.running_low]), con uno en vuelo como mucho.
## [br][br]
## [b]Recompensas[/b] (§6.2, P5c): méritos de PvP ([method on_merits]: solo con una víctima persistente de otro
## reino) y de objetivo ([method on_objective_ticks]: un mérito por segundo en el círculo activo de un ciclo de
## verdad), con [code]méritos × 10[/code] de XP; XP y oro de los PNJ a cada contribuyente ([method on_npc_killed]);
## y la de captura ([method on_capture]: 300 XP y 20 de oro, una vez por personaje y fortaleza cada 30 min, con el
## temporizador [code]capture:<fortress_id>[/code]). Cobra quien tiene [PlayerProgress] y no está marcado por un
## comando de GM ([member NetEntity.gm_forced]); con plataforma y [code]--fake-players[/code], nadie. Lo ganado
## cambia el saldo al momento (agregado, §5.2) y llega al dueño por [method flush]; subir de nivel pone
## [member NetEntity.level], manda el LEVEL_UP ([member level_up_sink]) y marca el guardado como crítico, igual que
## cobrar una captura.

## La clave de la sección en el cuerpo del guardado (plataforma.md §7.1).
const SECTION: StringName = &"progress"
## Texto del REJECT UNAVAILABLE si el registro no se puede leer (plataforma.md §5.2).
const PREPARE_FAILED_TEXT: String = "No se ha podido cargar el personaje"
## Crítico del kit de inicio (§9.2).
const CRITICAL_STARTER_KIT: StringName = &"starter_kit"
## NOTICE de CAMP_REFILL sin sitio en la bolsa (§4.4), una vez por entrada en la zona segura.
const BAG_FULL_TEXT: String = "Bolsa llena"
## RATE (§4.2): peticiones por tick y ráfaga.
const REQUEST_RATE_PER_TICK: float = 8.0 / 60.0
const REQUEST_BURST: float = 16.0
## RATE de SPLIT y DESTROY, que gastan ids: por tick y ráfaga.
const ID_REQUEST_RATE_PER_TICK: float = 2.0 / 60.0
const ID_REQUEST_BURST: float = 10.0
## INVENTORY_SYNC_REQUEST: uno cada 5 s; más, aviso (§4.6).
const SYNC_INTERVAL_TICKS: int = 300
## WALLET_UPDATE y PROGRESS_UPDATE: uno cada 10 ticks por jugador como mucho (§12).
const FLUSH_INTERVAL_TICKS: int = 10
## Temporizador de /atascado (§8).
const TIMER_UNSTUCK: String = "unstuck"
## Prefijo del temporizador de la recompensa de captura (§6.2 y §8): [code]capture:<fortress_id>[/code].
const TIMER_CAPTURE_PREFIX: String = "capture:"
## Críticos de la subida de nivel y de la recompensa de captura (§9.2).
const CRITICAL_LEVEL_UP: StringName = &"level_up"
const CRITICAL_CAPTURE: StringName = &"capture"
## Recompensa de captura (§6.2): XP y oro a cada uno de la lista, una vez por personaje y fortaleza cada
## [constant CAPTURE_COOLDOWN_S] segundos.
const CAPTURE_XP: int = 300
const CAPTURE_GOLD: int = 20
const CAPTURE_COOLDOWN_S: int = 1800
## Ticks en el círculo activo que dan un mérito de objetivo: uno por segundo, los provisionales del marcador
## ([ScoreKeeper], fuerte.md) hasta que PRG-09 los cambie.
const OBJECTIVE_TICKS_PER_MERIT: int = 60
## Línea del registro al arrancar con plataforma y [code]--fake-players[/code] (§6.2).
const FAKE_PLAYERS_TEXT: String = "Progreso: con --fake-players y la plataforma, la zona no da recompensas persistentes"
## Zonas SAFE (§8): se vuelve al sitio guardado si se guardó hace menos de esto (s).
const RETURN_WINDOW_S: int = 900
## Motivos de los avisos (red.md §12).
const STRIKE_NOT_IN_WORLD: String = "petición de inventario antes de entrar en el mundo"
const STRIKE_MALFORMED: String = "petición de inventario mal formada"
const STRIKE_INVALID: String = "petición de inventario no válida"
const STRIKE_RATE: String = "peticiones de inventario demasiado rápidas"
const STRIKE_SYNC: String = "sincronías de inventario demasiado seguidas"


## Las armas, la ranura activa y las cargas con las que el alta y la reaparición equipan al personaje en lugar de
## la plantilla (§8).
class Loadout:
	extends RefCounted
	## Ids de [CombatCatalog] de las ranuras 0 y 1 del equipo (0 = vacía).
	var weapon_1: int = 0
	var weapon_2: int = 0
	## La ranura 1 activa (bit0 de [code]combat_flags2[/code]).
	var second_active: bool = false
	## Empaquetadas como [member CombatState.consumable_charges]: [code]min(15, bolsa)[/code] de cada consumible.
	var charges: int = 0


# Lo de red de un jugador con inventario en el mundo: su peer, sus ritmos y lo último que se le ha mandado.
class _Session:
	extends RefCounted
	var net_id: int = 0
	var peer: ServerPeer = null
	var player: PlayerProgress = null
	## El combate del cuerpo (el mismo desde el alta hasta la baja; null en un alta sin combate, que no pasa).
	var combatant: Combatant = null
	var requests: RateLimiter = RateLimiter.new(ProgressService.REQUEST_RATE_PER_TICK, ProgressService.REQUEST_BURST)
	var id_requests: RateLimiter = RateLimiter.new(ProgressService.ID_REQUEST_RATE_PER_TICK,
			ProgressService.ID_REQUEST_BURST)
	var flood: ChatPeerState.FloodWindow = ChatPeerState.FloodWindow.new()
	var last_sync_tick: int = -ProgressService.SYNC_INTERVAL_TICKS
	## Las cargas antes del paso 1 del tick (−1 = sin cuerpo): CONSUME mira cuánto han bajado.
	var charges_before: int = -1
	## El último CAMP_REFILL (tick); el aviso de la bolsa llena sale una vez por entrada en la zona segura.
	var last_camp_tick: int = -1
	var bag_full_noticed: bool = false
	## Lo último mandado: saldos (índice = moneda) y [nivel, xp_total, puntos de reino].
	var sent_wallets: PackedInt64Array = PackedInt64Array()
	var sent_progress: Array[int] = []
	## Recompensa de captura: clave del temporizador ([code]capture:<id>[/code]) → tick desde el que vuelve a pagar.
	var capture_ready: Dictionary[String, int] = {}
	## Ticks de círculo que aún no llegan a un mérito de objetivo.
	var objective_ticks: int = 0


# Una petición en cola hasta el final del tick (request null = INVENTORY_SYNC_REQUEST).
class _Pending:
	extends RefCounted
	var session: _Session = null
	var request_id: int = 0
	var request: InventoryOps.Request = null


## Registro (un [Callable] con un texto); sin él, print.
var log_sink: Callable = Callable()
## [code](peer: ServerPeer, bytes: PackedByteArray) -> void[/code]: manda por el canal fiable (lo pone la zona).
var send_sink: Callable = Callable()
## [code](peer: ServerPeer, reason: String) -> void[/code]: suma un aviso al peer (red.md §12).
var strike_sink: Callable = Callable()
## [code](peer: ServerPeer, text: String) -> void[/code]: un NOTICE informativo.
var notice_sink: Callable = Callable()
## [code](net_id: int, level: int, s: int) -> void[/code]: el ENTITY_EVENT LEVEL_UP al dueño y a los de su reino que
## lo tienen relevante (§6.3; lo pone la zona).
var level_up_sink: Callable = Callable()
## [code](peer: ServerPeer, text: String) -> void[/code]: una línea de respuesta de un comando de [code]/gm[/code]
## por el canal del sistema del chat (P5d; lo pone la zona).
var reply_sink: Callable = Callable()
## [code]() -> int[/code]: la hora Unix sin plataforma (P5d: el [code]detail.at_unix[/code] de las operaciones de GM
## de los efímeros; lo pone la zona). Con plataforma manda [method ZonePlatform.now_unix].
var clock_unix: Callable = Callable()

var _zone: ZoneServer = null
var _platform: ZonePlatform = null
var _saver: CharacterSaver = null
var _commands: CommandRegistry = null
## Los comandos de GM de §10 (P5d); null sin registro de comandos.
var _gm: ProgressCommands = null
var _ids: IdAllocator = null
var _db: ItemDatabase = null
## peer_id -> lo preparado en la reclamación, hasta el alta o la baja en LOADING.
var _prepared: Dictionary[int, PlayerProgress] = {}
## net_id -> el progreso del cuerpo.
var _players: Dictionary[int, PlayerProgress] = {}
## net_id -> lo de red del jugador (peer, ritmos y lo último mandado).
var _sessions: Dictionary[int, _Session] = {}
## Las mismas, en una lista (los pasos de cada tick la recorren sin crear un array nuevo).
var _session_list: Array[_Session] = []
## Peticiones del tick en orden de llegada.
var _pending: Array[_Pending] = []
## Un bloque pedido y sin respuesta (el primero llega del arranque de la plataforma).
var _block_pending: bool = false
## Con plataforma y --fake-players no se paga ninguna recompensa (§6.2).
var _rewards_blocked: bool = false
## Id de texto → su huella u32 (ref_id de los PNJ y las fortalezas, §5.2).
var _ref_ids: Dictionary[StringName, int] = {}
var _stats: Dictionary[StringName, int] = {
	&"prepared": 0, &"prepare_failed": 0, &"appearance_replaced": 0, &"cancelled": 0, &"arrivals": 0,
	&"ephemeral": 0, &"kits": 0, &"kits_deferred": 0, &"departures": 0, &"blocks": 0, &"block_requests": 0,
	&"unbuilt": 0, &"requests": 0, &"applied": 0, &"rejected": 0, &"rate_limited": 0, &"not_in_world": 0,
	&"syncs": 0, &"weapon_changes": 0, &"consumed": 0, &"camp_refills": 0, &"bag_full_notices": 0, &"refills": 0,
	&"returned_to_spot": 0, &"merits": 0, &"xp": 0, &"gold": 0, &"npc_rewards": 0, &"captures_paid": 0,
	&"captures_on_cooldown": 0, &"level_ups": 0, &"rewards_blocked": 0,
}


## Engancha el servicio a [param zone]: con [param platform] y [param saver] (null sin plataforma, §9.4), registra la
## sección [code]progress[/code] en [param saver] (la primera: es la única que puede devolver [code]{}[/code], y
## [CharacterSaver] no deshace lo que haya construido otra antes en ese intento) y usa los bloques de la plataforma;
## sin ella, ids locales. En [param commands] registra los comandos de GM de §10 ([ProgressCommands], P5d).
func setup(zone: ZoneServer, platform: ZonePlatform, saver: CharacterSaver, commands: CommandRegistry) -> void:
	_zone = zone
	_platform = platform
	_saver = saver
	_commands = commands
	_db = ItemDatabase.shared()
	if _commands != null:
		_gm = ProgressCommands.new(self, zone, platform)
		_gm.register_commands(_commands)
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
	var config: ServerConfig = zone.get_config() if zone != null else null
	_rewards_blocked = _platform != null and config != null and config.fake_players > 0
	if _rewards_blocked:
		_log(FAKE_PLAYERS_TEXT)


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


## El alta de [param entity] (§9.1 paso 4), tras [method CharacterSaver.track] y antes del SPAWN: ata al
## [code]net_id[/code] el [PlayerProgress] preparado para [param peer] o, sin plataforma, uno efímero nuevo (§9.4);
## aplica la regla de volver al mundo (§8: sitio y vida), restaura el temporizador de /atascado, toma la foto del
## cuerpo como confirmada (entrar sin cambiar nada no ensucia), da el kit de la primera entrada (crítico, §2.5) y
## pone el nivel y la apariencia en la entidad. Devuelve el [ProgressService.Loadout] con el que el alta equipa al
## personaje en lugar de la plantilla; null sin peer o, con plataforma, sin nada preparado (la plantilla, como un
## falso).
func on_arrival(entity: NetEntity, peer: ServerPeer, s: int) -> Loadout:
	if entity == null or peer == null:
		return null
	var player: PlayerProgress = _prepared.get(peer.peer_id)
	if player != null:
		_prepared.erase(peer.peer_id)
	elif _platform == null:
		player = _new_ephemeral(peer)
		_stats[&"ephemeral"] += 1
	else:
		return null
	var net_id: int = entity.net_id
	player.arrival_tick = s
	player.played_base = player.record.played_seconds
	# Un Callable de método (sin lambda): no guarda una referencia fuerte al servicio ni al propio progreso.
	player.live_source = Callable(self, "_live_of").bind(net_id)
	_players[net_id] = player
	_return_to_world(entity, player)
	_restore_timers(entity, player, s)
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
	entity.level = player.record.level
	entity.appearance = player.record.appearance.duplicate()
	var session := _Session.new()
	session.net_id = net_id
	session.peer = peer
	session.player = player
	session.combatant = _combatant(net_id)
	_sessions[net_id] = session
	_session_list.append(session)
	_restore_capture_timers(session, s)
	return _loadout(player, true)


## Tras el SPAWN propio (§9.1 paso 5): INVENTORY_FULL (en páginas), un WALLET_UPDATE por moneda (delta 0) y un
## PROGRESS_UPDATE del estado. Sin [PlayerProgress], nada.
func after_spawn(entity: NetEntity, _peer: ServerPeer, _s: int) -> void:
	var session: _Session = _sessions.get(entity.net_id) if entity != null else null
	if session == null:
		return
	var player: PlayerProgress = session.player
	_send_full(session)
	session.sent_wallets = player.record.wallets.duplicate()
	for code: int in Currency.codes():
		_send(session, ProgressMessages.WalletUpdate.make(code, player.record.wallets[code], 0, 0).encode())
	player.pending_xp_gain = 0
	player.pending_xp_source = ProgressMessages.XpSource.STATE
	_send_progress(session)


## El equipo con el que reaparece [param net_id] (§8): sus armas, la ranura 1 activa solo si WEAPON_1 está vacía
## y las cargas de su bolsa. null sin [PlayerProgress] (quien llama usa la plantilla, como con un falso).
func loadout_for(net_id: int) -> Loadout:
	var player: PlayerProgress = _players.get(net_id)
	return _loadout(player, false) if player != null else null


## true si [param net_id] tiene [PlayerProgress] (un jugador con peer).
func has_inventory(net_id: int) -> bool:
	return _players.has(net_id)


## El nivel de [param net_id]; 0 sin [PlayerProgress].
func level_of(net_id: int) -> int:
	var player: PlayerProgress = _players.get(net_id)
	return player.record.level if player != null else 0


## El [code]character_id[/code] persistente de [param net_id]; 0 sin [PlayerProgress] o si es efímero.
func character_id_of(net_id: int) -> int:
	var player: PlayerProgress = _players.get(net_id)
	return player.character_id if player != null and player.persistent else 0


## INVENTORY_REQUEST (0x50) o INVENTORY_SYNC_REQUEST (0x53) de [param peer], en el «poll»: fuera del mundo o mal
## formado suma un aviso; RATE se mira al llegar, antes que nada (responde ya con el contenido real de las ranuras
## que tocaba); lo demás va a la cola de [method apply_pending]. Una sincronía antes de 5 s suma un aviso y no se
## contesta.
func handle_packet(peer: ServerPeer, bytes: PackedByteArray) -> void:
	if peer == null or bytes.is_empty() or peer.state == ServerPeer.State.LEAVING:
		return
	var tick: int = _zone.get_tick() if _zone != null else 0
	var session: _Session = null
	if peer.state == ServerPeer.State.IN_WORLD and peer.entity != null:
		session = _sessions.get(peer.entity.net_id)
	if session == null or session.peer != peer:
		_stats[&"not_in_world"] += 1
		_strike(peer, STRIKE_NOT_IN_WORLD)
		return
	match bytes[0]:
		NetProtocol.MSG_INVENTORY_REQUEST:
			var message: ProgressMessages.InventoryRequest = ProgressMessages.InventoryRequest.decode(bytes)
			if message == null:
				_strike(peer, STRIKE_MALFORMED)
				return
			_stats[&"requests"] += 1
			var request: InventoryOps.Request = message.to_request()
			var spends_id: bool = request.op == InventoryOps.Op.SPLIT or request.op == InventoryOps.Op.DESTROY
			if session.requests.get_tokens(tick) < 1.0 \
					or (spends_id and session.id_requests.get_tokens(tick) < 1.0):
				_stats[&"rate_limited"] += 1
				var state: InventoryState = session.player.record.inventory
				_send(session, ProgressMessages.InventoryDelta.for_slots(session.player.revision, message.request_id,
						InventoryOps.Result.RATE, 0, state, _touched(state, request)).encode(_db))
				if session.flood.note(tick):
					_strike(peer, STRIKE_RATE)
				return
			session.requests.try_consume(tick)
			if spends_id:
				session.id_requests.try_consume(tick)
			var pending := _Pending.new()
			pending.session = session
			pending.request_id = message.request_id
			pending.request = request
			_pending.append(pending)
		NetProtocol.MSG_INVENTORY_SYNC_REQUEST:
			if ProgressMessages.InventorySyncRequest.decode(bytes) == null:
				_strike(peer, STRIKE_MALFORMED)
				return
			if tick - session.last_sync_tick < SYNC_INTERVAL_TICKS:
				_strike(peer, STRIKE_SYNC)
				return
			session.last_sync_tick = tick
			var sync := _Pending.new()
			sync.session = session
			_pending.append(sync)
		_:
			_strike(peer, STRIKE_MALFORMED)


## Las peticiones del tick [param s] (§4.2), al final del tick y tras las altas, en orden de llegada: cada una con
## el [InventoryOps.Context] del [CombatState] del servidor (la ranura activa, si puede tocar el equipo y si está
## bebiendo), su INVENTORY_DELTA de respuesta y, si se aplica, las armas y las cargas impuestas. INVALID suma un
## aviso. Las sincronías, su INVENTORY_FULL con el estado de ese momento.
func apply_pending(s: int) -> void:
	if _pending.is_empty():
		return
	var pending: Array[_Pending] = _pending
	_pending = []
	for entry: _Pending in pending:
		var session: _Session = entry.session
		if _sessions.get(session.net_id) != session:
			continue
		if entry.request == null:
			_stats[&"syncs"] += 1
			_send_full(session)
		else:
			_apply_request(session, entry, s)


## Antes del paso 1 (simular) del tick [param s]: las cargas de cada jugador con inventario, para que
## [method after_simulate] vea cuánto han bajado.
func before_simulate(_s: int) -> void:
	for session: _Session in _session_list:
		session.charges_before = session.combatant.get_character().combat.consumable_charges \
				if session.combatant != null else -1


## Tras el paso 1 del tick [param s] (§4.4): CONSUME. Si bajó la carga de un consumible (el compromiso de beber,
## habilidades.md §3.3 regla 5), se quita esa cantidad de la pila de su definición con la ranura de bolsa más baja
## (agregado), sale su INVENTORY_DELTA y se imponen las cargas ([code]min(15, bolsa)[/code]: con más de 15, la carga
## vuelve a 15 con un LOADOUT). Beber interrumpido no baja la carga y no gasta nada.
func after_simulate(s: int) -> void:
	for session: _Session in _session_list:
		var before: int = session.charges_before
		session.charges_before = -1
		if before < 0:
			continue
		var combatant: Combatant = session.combatant
		var combat: CombatState = combatant.get_character().combat
		if combat.consumable_charges == before:
			continue
		var consumed: bool = false
		for index: int in range(CombatState.CONSUMABLE_SLOTS):
			var spent: int = ((before >> (4 * index)) & CombatState.MAX_CHARGES) - combat.charges_of(index)
			if spent <= 0:
				continue
			var definition: ItemDefinition = _db.consumable_definition(index)
			if definition == null:
				_alert("el consumible %d no tiene objeto: no se descuenta lo que ha bebido el net_id %d"
						% [index, session.net_id])
				continue
			var outcome: InventoryOps.Outcome = session.player.take_items(definition.id, spent,
					EconomyReason.CONSUME)
			if not outcome.is_ok():
				_alert("el net_id %d ha bebido %d de %s sin tenerlas en la bolsa" % [session.net_id, spent,
						definition.id])
				continue
			consumed = true
			_stats[&"consumed"] += spent
			_send_server_delta(session, outcome.changed, EconomyReason.CONSUME)
		if consumed:
			_impose_charges(session, combatant, s)


## CAMP_REFILL de [param entity] en el tick [param s] (§4.4): lo llama la recarga del campamento (paso 8, cada 60
## ticks, vivo, fuera de combate y en la zona segura de su reino) en lugar de la de la plantilla. Repone el total
## de cada definición con [member ItemDefinition.camp_refill] (agregado), con su INVENTORY_DELTA y las cargas; sin
## sitio para una pila nueva, NOTICE «Bolsa llena» una vez por entrada en la zona segura (una entrada: no haber
## repuesto en la recarga anterior). Sin [PlayerProgress], nada.
func camp_step(entity: NetEntity, s: int) -> void:
	var session: _Session = _sessions.get(entity.net_id) if entity != null else null
	var combatant: Combatant = session.combatant if session != null else null
	if combatant == null:
		return
	if session.last_camp_tick != s - CombatDirector.RECHARGE_INTERVAL_TICKS:
		session.bag_full_noticed = false
	session.last_camp_tick = s
	var outcome: InventoryOps.Outcome = session.player.camp_refill()
	if not outcome.changed.is_empty():
		_stats[&"camp_refills"] += 1
		_send_server_delta(session, outcome.changed, EconomyReason.CAMP_REFILL)
		_impose_charges(session, combatant, s)
	if outcome.bag_full and not session.bag_full_noticed:
		session.bag_full_noticed = true
		_stats[&"bag_full_notices"] += 1
		if notice_sink.is_valid() and _is_reachable(session):
			notice_sink.call(session.peer, BAG_FULL_TEXT)


## El comando 16 [code]refill[/code] (y el [code]refill[/code] de la consola) para quien tiene inventario (§4.4):
## sin plataforma, un CAMP_REFILL forzado (agregado) sin mirar zona ni combate, con su delta, las cargas y LOADOUT
## al dueño. false si [param net_id] no tiene inventario o no está vivo; también con plataforma, donde es una
## operación GM ([method ProgressCommands.net_refill], P5d).
func force_refill(net_id: int, s: int) -> bool:
	var session: _Session = _sessions.get(net_id)
	var combatant: Combatant = session.combatant if session != null else null
	if combatant == null or not combatant.is_alive() or _platform != null:
		return false
	var outcome: InventoryOps.Outcome = session.player.camp_refill()
	if not outcome.changed.is_empty():
		_send_server_delta(session, outcome.changed, EconomyReason.CAMP_REFILL)
	_stats[&"refills"] += 1
	_impose_charges(session, combatant, s, true)
	return true


## WALLET_UPDATE y PROGRESS_UPDATE del tick [param s] (§12): a cada jugador, uno cada
## [constant FLUSH_INTERVAL_TICKS] ticks como mucho (escalonado por [code]net_id[/code]), con el delta sumado de
## cada moneda que ha cambiado (y el motivo de su último cambio) y, si cambió el nivel, la XP o los puntos de reino,
## el progreso con lo ganado desde el anterior.
func flush(s: int) -> void:
	for session: _Session in _session_list:
		if (s + session.net_id) % FLUSH_INTERVAL_TICKS != 0:
			continue
		var player: PlayerProgress = session.player
		for code: int in Currency.codes():
			var balance: int = player.record.wallets[code]
			if session.sent_wallets.size() <= code or balance == session.sent_wallets[code]:
				continue
			_send(session, ProgressMessages.WalletUpdate.make(code, balance, balance - session.sent_wallets[code],
					player.last_currency_reasons[code]).encode())
			session.sent_wallets[code] = balance
		if player.pending_xp_gain > 0 or session.sent_progress != _progress_key(player):
			_send_progress(session)


## Guarda en el registro de [param net_id] el temporizador [param key] que vence en el tick [param ready_tick],
## visto en el tick [param s] (§8: [code]ends_at_unix[/code] con la hora de la plataforma). Uno vencido se quita.
## Sin plataforma (o en un efímero) no hay temporizadores que guardar.
func set_timer(net_id: int, key: String, ready_tick: int, s: int) -> void:
	var player: PlayerProgress = _players.get(net_id)
	var now: int = _platform.now_unix() if _platform != null else 0
	if player == null or not player.persistent or now <= 0:
		return
	if ready_tick <= s:
		player.record.timers.erase(key)
	else:
		player.record.timers[key] = PlayerProgress.ends_at_unix_for(ready_tick, s, now)


## Méritos de PRG-09 para [param net_id] en el tick [param s] (§6.2): [param amount] de [param reason]
## (PVP_KILL, PVP_ASSIST u OBJECTIVE) y [code]amount × 10[/code] de XP. Los de PvP solo con una víctima
## ([param victim_net_id]) persistente de otro reino: la de un PNJ, un falso o un efímero no da nada, y su apunte
## lleva el [code]character_id[/code] de la víctima. Los de objetivo van sin víctima (0). Sube los puntos de reino con
## lo apuntado (I9). Nada sin [PlayerProgress], con [member NetEntity.gm_forced] o con plataforma y
## [code]--fake-players[/code].
func on_merits(net_id: int, amount: int, reason: int, victim_net_id: int, s: int) -> void:
	if amount <= 0 or not EconomyReason.gives_realm_points(reason):
		return
	var session: _Session = _collector(net_id)
	if session == null:
		return
	if reason == EconomyReason.OBJECTIVE:
		if victim_net_id == 0:
			_pay_merits(session, amount, reason, LedgerEntry.RefKind.NONE, 0, ProgressMessages.XpSource.CAPTURE, s)
		return
	var victim: PlayerProgress = _players.get(victim_net_id)
	var victim_entity: NetEntity = _entity(victim_net_id)
	var entity: NetEntity = _entity(net_id)
	if victim == null or not victim.persistent or victim_entity == null or entity == null \
			or victim_entity.realm == entity.realm:
		return
	_pay_merits(session, amount, reason, LedgerEntry.RefKind.CHARACTER, victim.character_id,
			ProgressMessages.XpSource.PVP, s)


## [param ticks] más de [param net_id] en el círculo activo de [param fortress_id] en el tick [param s] (la señal
## [signal FortressController.objective_time]: ciclo de verdad y sin [member NetEntity.gm_forced]): cada
## [constant OBJECTIVE_TICKS_PER_MERIT] ticks acumulados son un mérito de objetivo (motivo OBJECTIVE, con la
## fortaleza como referencia) y su XP.
func on_objective_ticks(fortress_id: StringName, net_id: int, ticks: int, s: int) -> void:
	if ticks <= 0:
		return
	var session: _Session = _collector(net_id)
	if session == null:
		return
	session.objective_ticks += ticks
	@warning_ignore("integer_division")
	var merits: int = session.objective_ticks / OBJECTIVE_TICKS_PER_MERIT
	if merits <= 0:
		return
	session.objective_ticks -= merits * OBJECTIVE_TICKS_PER_MERIT
	_pay_merits(session, merits, EconomyReason.OBJECTIVE, LedgerEntry.RefKind.FORTRESS, _ref_id(fortress_id),
			ProgressMessages.XpSource.CAPTURE, s)


## Ha muerto un PNJ de [param npc] en el tick [param s] (§6.2): cada uno de [param contributors] (quienes hicieron al
## menos el 10 % del daño de la ventana, [method DamageLedger.contributors]) recibe la recompensa entera:
## [member NpcDefinition.xp_reward] de XP y [member NpcDefinition.gold_reward] de oro (NPC_KILL, con el PNJ como
## referencia). Sin méritos. La zona no lo llama si el PNJ defendía una fortaleza en un ciclo forzado.
func on_npc_killed(npc: NpcDefinition, contributors: PackedInt32Array, s: int) -> void:
	if npc == null or (npc.xp_reward <= 0 and npc.gold_reward <= 0):
		return
	for net_id: int in contributors:
		var session: _Session = _collector(net_id)
		if session == null:
			continue
		_stats[&"npc_rewards"] += 1
		if npc.gold_reward > 0:
			_stats[&"gold"] += session.player.gain_currency(Currency.Code.GOLD, npc.gold_reward, EconomyReason.NPC_KILL,
					LedgerEntry.RefKind.NPC, _ref_id(npc.id))
		_grant_xp(session, npc.xp_reward, ProgressMessages.XpSource.NPC, s)


## Captura de verdad de [param fortress_id] por [param owner_realm] en el tick [param s]
## ([signal FortressController.fortress_captured]): cada uno de [param in_circle] (la lista de plataforma.md §8, la
## misma que suma [code]ScoreKeeper.captures[/code]) de ese reino recibe [constant CAPTURE_XP] de XP y
## [constant CAPTURE_GOLD] de oro (OBJECTIVE, con la fortaleza como referencia), una vez cada
## [constant CAPTURE_COOLDOWN_S] s por fortaleza: con plataforma, el temporizador
## [code]capture:<fortress_id>[/code] se guarda y vuelve con el personaje (§8). Cobrar marca el guardado como
## crítico. Una captura forzada no llega aquí.
func on_capture(fortress_id: StringName, owner_realm: int, in_circle: PackedInt32Array, s: int) -> void:
	var key: String = TIMER_CAPTURE_PREFIX + String(fortress_id)
	for net_id: int in in_circle:
		var session: _Session = _collector(net_id)
		var entity: NetEntity = _entity(net_id)
		if session == null or entity == null or entity.realm != owner_realm:
			continue
		if session.capture_ready.get(key, 0) > s:
			_stats[&"captures_on_cooldown"] += 1
			continue
		var ready_tick: int = s + CAPTURE_COOLDOWN_S * PlayerProgress.TICKS_PER_SECOND
		session.capture_ready[key] = ready_tick
		set_timer(net_id, key, ready_tick, s)
		_stats[&"captures_paid"] += 1
		_stats[&"gold"] += session.player.gain_currency(Currency.Code.GOLD, CAPTURE_GOLD, EconomyReason.OBJECTIVE,
				LedgerEntry.RefKind.FORTRESS, _ref_id(fortress_id))
		_grant_xp(session, CAPTURE_XP, ProgressMessages.XpSource.CAPTURE, s)
		if _saver != null and session.player.persistent:
			_saver.mark_critical(net_id, CRITICAL_CAPTURE)
		_log("Progreso: net_id %d (%s) cobra la captura de %s" % [net_id, _who(session.player), fortress_id])


## true si la zona no paga recompensas: con plataforma y [code]--fake-players[/code] (§6.2).
func rewards_blocked() -> bool:
	return _rewards_blocked


## El progreso atado a [param net_id], o null (pruebas y paquetes siguientes).
func get_player(net_id: int) -> PlayerProgress:
	return _players.get(net_id)


## Lo preparado para [param peer_id] y aún sin alta, o null.
func get_prepared(peer_id: int) -> PlayerProgress:
	return _prepared.get(peer_id)


## El generador de ids de la zona.
func get_ids() -> IdAllocator:
	return _ids


## Peticiones en cola para el final del tick (pruebas).
func pending_count() -> int:
	return _pending.size()


## Un evento de la plataforma de los suyos (§14.2): [code]id_block[/code] (un bloque nuevo; si quedan pocos, pide
## otro), [code]progress_op[/code] y [code]progress_ledger[/code] (las respuestas de [code]op_show[/code],
## [code]op_revert[/code] y [code]ledger_show[/code], que atiende [ProgressCommands]). true si era suyo.
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
			if _gm != null:
				_gm.on_platform_event(event)
			return true
	return false


## La baja de [param net_id] (§9.2), tras [method CharacterSaver.finish] y [method ScoreKeeper.forget], o en la baja
## sin guardado: descarta su estado (y sus peticiones en cola). Sobre un [code]net_id[/code] sin [PlayerProgress],
## nada.
func on_departure(net_id: int) -> void:
	var session: _Session = _sessions.get(net_id)
	if session != null:
		_sessions.erase(net_id)
		_session_list.erase(session)
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
	if _gm != null:
		stats["gm"] = _gm.get_stats()
	return stats


# --- Lo que usan los comandos de GM (P5d, [ProgressCommands]) ------------------------------------

## Los comandos de GM de §10 (null sin registro de comandos).
func gm_commands() -> ProgressCommands:
	return _gm


## La hora Unix: la de la plataforma o, sin ella, la de [member clock_unix] (0 si no hay ninguna).
func now_unix() -> int:
	if _platform != null:
		return _platform.now_unix()
	return int(clock_unix.call()) if clock_unix.is_valid() else 0


## El [code]net_id[/code] del jugador con progreso conectado en esta zona que nombra [param text] (su
## [code]net_id[/code] o su nombre, sin distinguir mayúsculas ni tildes), o 0.
func find_connected(text: String) -> int:
	var wanted: String = text.strip_edges()
	var key: String = NameRules.normalize_key(wanted)
	for session: _Session in _session_list:
		if not _is_reachable(session):
			continue
		if (wanted.is_valid_int() and wanted.to_int() == session.net_id) \
				or NameRules.normalize_key(session.peer.display_name) == key:
			return session.net_id
	return 0


## El [code]net_id[/code] del personaje persistente [param character_id] si está conectado en esta zona, o 0.
func connected_net_id_of(character_id: int) -> int:
	for session: _Session in _session_list:
		if session.player.persistent and session.player.character_id == character_id and _is_reachable(session):
			return session.net_id
	return 0


## true si [param net_id] tiene progreso y su peer sigue en el mundo con ese cuerpo.
func is_connected_player(net_id: int) -> bool:
	var session: _Session = _sessions.get(net_id)
	return session != null and _is_reachable(session)


## El peer de [param net_id] si sigue en el mundo con ese cuerpo, o null.
func peer_of(net_id: int) -> ServerPeer:
	var session: _Session = _sessions.get(net_id)
	return session.peer if session != null and _is_reachable(session) else null


## Los [code]net_id[/code] con [PlayerProgress] (también el cuerpo que se queda tras una salida en combate).
func player_net_ids() -> PackedInt32Array:
	return PackedInt32Array(_players.keys())


## La ranura de arma activa de [param net_id] (bit0 de [code]combat_flags2[/code] del [CombatState]; sin cuerpo, la
## del registro).
func active_weapon_slot(net_id: int) -> int:
	var session: _Session = _sessions.get(net_id)
	if session != null and session.combatant != null:
		return 1 if session.combatant.get_character().combat.is_second_slot() else 0
	var player: PlayerProgress = _players.get(net_id)
	return player.saved_active_slot() if player != null else 0


## true si se le pueden cambiar las armas a [param net_id] ahora (sin una acción en curso: [method
## ActionMachine.set_weapons] solo vale con la acción NONE).
func can_change_weapons(net_id: int) -> bool:
	var session: _Session = _sessions.get(net_id)
	return session != null and session.combatant != null \
			and session.combatant.get_character().combat.action == CombatState.Action.NONE


## true si [param net_id] tiene cuerpo y está vivo.
func is_alive(net_id: int) -> bool:
	var session: _Session = _sessions.get(net_id)
	return session != null and session.combatant != null and session.combatant.is_alive()


## Lo que un comando de GM ha cambiado en el inventario de [param net_id] en el tick [param s] (§4.4): el
## INVENTORY_DELTA del servidor con [param reason], las armas si tocó las ranuras de arma ([param weapons_changed]) y
## las cargas, con LOADOUT al dueño si cambian (o siempre, con [param always_loadout]: el 16).
func after_gm_change(net_id: int, changed: Array[Vector2i], weapons_changed: bool, reason: int, s: int,
		always_loadout: bool = false) -> void:
	var session: _Session = _sessions.get(net_id)
	if session == null:
		return
	var unique: Array[Vector2i] = []
	for position: Vector2i in changed:
		if not unique.has(position):
			unique.append(position)
	if not unique.is_empty():
		_send_server_delta(session, unique, reason)
	if session.combatant == null:
		return
	if weapons_changed:
		_impose_weapons(session, session.combatant, s)
	_impose_charges(session, session.combatant, s, always_loadout)


## Tras un cambio de nivel de GM de [param net_id] (que tenía [param old_level]) en el tick [param s]: el nivel en la
## entidad (los SPAWN siguientes) y, si sube, el LEVEL_UP (§6.3). PROGRESS_UPDATE sale en [method flush].
func after_level_change(net_id: int, old_level: int, s: int) -> void:
	var player: PlayerProgress = _players.get(net_id)
	if player == null or player.record.level == old_level:
		return
	var entity: NetEntity = _entity(net_id)
	if entity != null:
		entity.level = player.record.level
	if player.record.level > old_level:
		_stats[&"level_ups"] += 1
		if level_up_sink.is_valid():
			level_up_sink.call(net_id, player.record.level, s)


## Un comando de GM ha cambiado el personaje de [param net_id]: guardado crítico [code]gm[/code] (§9.2).
func mark_gm_critical(net_id: int) -> void:
	var player: PlayerProgress = _players.get(net_id)
	if _saver != null and player != null and player.persistent:
		_saver.mark_critical(net_id, ProgressCommands.CRITICAL_GM)


## Una línea de respuesta a [param peer] por el canal del sistema del chat (los comandos de [code]/gm[/code]).
func reply(peer: ServerPeer, text: String) -> void:
	if reply_sink.is_valid() and peer != null:
		reply_sink.call(peer, text)


## Una línea para el registro de la zona.
func log_line(text: String) -> void:
	_log(text)


## Un NOTICE informativo a [param net_id] si sigue en el mundo (la razón de un DEBUG_COMMAND rechazado).
func notice(net_id: int, text: String) -> void:
	var session: _Session = _sessions.get(net_id)
	if session != null and notice_sink.is_valid() and _is_reachable(session):
		notice_sink.call(session.peer, text)


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


# --- Inventario por la red ------------------------------------------------------------------------

func _apply_request(session: _Session, entry: _Pending, s: int) -> void:
	var player: PlayerProgress = session.player
	var combatant: Combatant = session.combatant
	var outcome: InventoryOps.Outcome
	if combatant == null:
		# Sin cuerpo: NOT_NOW («sin personaje o fuera del mundo», §4.2).
		outcome = InventoryOps.Outcome.new()
		outcome.result = InventoryOps.Result.NOT_NOW
		outcome.changed = _touched(player.record.inventory, entry.request)
	else:
		var combat: CombatState = combatant.get_character().combat
		var context := InventoryOps.Context.new()
		context.active_weapon_slot = 1 if combat.is_second_slot() else 0
		context.can_touch_equipment = combatant.is_alive() and not combatant.is_in_combat(s) \
				and combat.action == CombatState.Action.NONE
		context.drinking = _is_drinking(combat)
		outcome = player.apply_request(entry.request, context)
	if outcome.result == InventoryOps.Result.INVALID:
		_strike(session.peer, STRIKE_INVALID)
	_send(session, ProgressMessages.InventoryDelta.for_slots(player.revision, entry.request_id, outcome.result, 0,
			player.record.inventory, outcome.changed).encode(_db))
	if not outcome.is_ok():
		_stats[&"rejected"] += 1
		return
	_stats[&"applied"] += 1
	_log_request(session, entry, outcome)
	if outcome.weapons_changed:
		_impose_weapons(session, combatant, s)
	if entry.request.op == InventoryOps.Op.DESTROY:
		# Solo DESTROY cambia la cantidad de una definición (mover, dividir y juntar no, I4).
		_impose_charges(session, combatant, s)


# Tras un cambio confirmado de las ranuras de arma (§4.1): guarda las reutilizaciones de las armas que había en cada
# ranura y pone las del equipo con las suyas guardadas ([method ActionMachine.set_weapons]: sin reiniciar nada más),
# la ranura activa la misma (o la otra si se ha quedado sin arma) y LOADOUT al dueño y, si cambian las armas, a
# quien lo tenga relevante.
func _impose_weapons(session: _Session, combatant: Combatant, s: int) -> void:
	var character: PlayerCharacter = combatant.get_character()
	var combat: CombatState = character.combat
	if combat.action != CombatState.Action.NONE:
		# No pasa: tocar el equipo con una acción en curso es NOT_NOW.
		_alert("armas del net_id %d sin imponer: acción %d en curso" % [session.net_id, combat.action])
		return
	var player: PlayerProgress = session.player
	var second_active: bool = combat.is_second_slot()
	var before: PackedInt32Array = CombatDirector.weapons_in_slot_order(combat)
	var active_ready: PackedInt64Array = combat.ability_ready.slice(0, CombatState.ABILITY_SLOTS)
	var other_ready: PackedInt64Array = combat.ability_ready.slice(CombatState.ABILITY_SLOTS,
			2 * CombatState.ABILITY_SLOTS)
	player.stash_ready(before[0], other_ready if second_active else active_ready)
	player.stash_ready(before[1], active_ready if second_active else other_ready)
	var weapons: PackedInt32Array = player.weapons()
	if second_active and weapons[1] == 0 and weapons[0] != 0:
		second_active = false
	elif not second_active and weapons[0] == 0 and weapons[1] != 0:
		second_active = true
	ActionMachine.set_weapons(combat, weapons[0], weapons[1], second_active, player.stashed_ready(weapons[0]),
			player.stashed_ready(weapons[1]))
	CombatDirector.commit_state(character)
	_stats[&"weapon_changes"] += 1
	_zone.get_combat().announce_loadout(combatant, s, before != CombatDirector.weapons_in_slot_order(combat))


# Las cargas de los consumibles: min(15, bolsa) de cada uno (§4.4), con LOADOUT al dueño si cambian (o siempre, con
# [param always]: el comando 16).
func _impose_charges(session: _Session, combatant: Combatant, s: int, always: bool = false) -> void:
	var character: PlayerCharacter = combatant.get_character()
	var charges: int = session.player.charges()
	if character.combat.consumable_charges == charges and not always:
		return
	ActionMachine.set_charges(character.combat, charges)
	CombatDirector.commit_state(character)
	_zone.get_combat().announce_loadout(combatant, s, false)


func _send_full(session: _Session) -> void:
	var player: PlayerProgress = session.player
	var pages: Array[ProgressMessages.InventoryFull] = ProgressMessages.InventoryFull.split(player.revision,
			player.record.inventory)
	if pages.is_empty():
		_alert("el inventario del net_id %d no cabe en INVENTORY_FULL" % session.net_id)
		return
	for page: ProgressMessages.InventoryFull in pages:
		_send(session, page.encode(_db))


func _send_server_delta(session: _Session, changed: Array[Vector2i], reason: int) -> void:
	_send(session, ProgressMessages.InventoryDelta.for_slots(session.player.revision, 0, InventoryOps.Result.OK,
			reason, session.player.record.inventory, changed).encode(_db))


func _send_progress(session: _Session) -> void:
	var player: PlayerProgress = session.player
	var source: int = player.pending_xp_source if player.pending_xp_gain > 0 else ProgressMessages.XpSource.STATE
	_send(session, ProgressMessages.ProgressUpdate.make(LevelCurve.shared(), player.record.level,
			player.record.xp_total, player.pending_xp_gain, source, player.record.realm_points).encode())
	player.pending_xp_gain = 0
	player.pending_xp_source = ProgressMessages.XpSource.STATE
	session.sent_progress = _progress_key(player)


static func _progress_key(player: PlayerProgress) -> Array[int]:
	return [player.record.level, player.record.xp_total, player.record.realm_points]


func _send(session: _Session, bytes: PackedByteArray) -> void:
	if bytes.is_empty():
		_alert("un mensaje de progreso para el net_id %d no se ha podido codificar" % session.net_id)
		return
	if send_sink.is_valid() and _is_reachable(session):
		send_sink.call(session.peer, bytes)


# El peer sigue siendo el dueño del cuerpo y está en el mundo (el cuerpo que se queda tras una salida en combate ya
# no tiene a quién mandar nada).
func _is_reachable(session: _Session) -> bool:
	return session.peer != null and session.peer.state == ServerPeer.State.IN_WORLD \
			and session.peer.entity != null and session.peer.entity.net_id == session.net_id


func _strike(peer: ServerPeer, reason: String) -> void:
	if strike_sink.is_valid():
		strike_sink.call(peer, reason)


# Las ranuras que existen de las que toca [param request] (el contenido real que lleva el delta de un rechazo).
static func _touched(state: InventoryState, request: InventoryOps.Request) -> Array[Vector2i]:
	var slots: Array[Vector2i] = []
	if request == null:
		return slots
	var from := Vector2i(request.from_container, request.from_slot)
	if state.has_slot(from.x, from.y):
		slots.append(from)
	var to := Vector2i(request.to_container, request.to_slot)
	if request.op != InventoryOps.Op.DESTROY and to != from and state.has_slot(to.x, to.y):
		slots.append(to)
	return slots


static func _is_drinking(combat: CombatState) -> bool:
	if combat.action != CombatState.Action.ABILITY:
		return false
	var ability: AbilityTicks = CombatCatalog.ability(combat.action_id)
	return ability != null and ability.is_consumable()


func _log_request(session: _Session, entry: _Pending, outcome: InventoryOps.Outcome) -> void:
	var request: InventoryOps.Request = entry.request
	var who: String = _who(session.player)
	var target: String = "-" if request.op == InventoryOps.Op.DESTROY \
			else "%d:%d" % [request.to_container, request.to_slot]
	_log("Inventario: net_id %d (%s) %s %d:%d -> %s ×%d uid %d%s: OK" % [session.net_id, who,
			_op_name(request.op), request.from_container, request.from_slot, target, request.count,
			request.expected_uid, " (nuevo %d)" % outcome.new_id if outcome.new_id != 0 else ""])


static func _op_name(op: int) -> String:
	match op:
		InventoryOps.Op.MOVE:
			return "MOVE"
		InventoryOps.Op.SPLIT:
			return "SPLIT"
		InventoryOps.Op.DESTROY:
			return "DESTROY"
	return str(op)


# --- Alta ----------------------------------------------------------------------------------------

# Un personaje efímero (§9.4): nuevo, del pueblo del reino del peer con su apariencia por defecto y con el kit de la
# plantilla de LOADOUT_SELECT (la que llegó antes de CLIENT_READY) o la de por defecto; ids locales y nada que
# guardar.
func _new_ephemeral(peer: ServerPeer) -> PlayerProgress:
	var record: ProgressRecord = ProgressRecord.new_character()
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	var race: RaceDefinition = catalog.race_for_realm(RealmCatalog.id_of_code(peer.realm))
	if race != null:
		record.race_id = race.id
		var appearance: CharacterAppearance = CharacterAppearance.default_for(catalog, catalog.race_index(race.id))
		if appearance != null:
			record.appearance = appearance.encode()
	var template: EquipmentTemplate = CombatCatalog.template(
			CombatDirector.resolve_template(maxi(peer.pending_template_id, 0)))
	record.starter_template_id = template.id if template != null else &""
	return PlayerProgress.new(record, false, _ids, _db)


func _loadout(player: PlayerProgress, at_arrival: bool) -> Loadout:
	var weapons: PackedInt32Array = player.weapons()
	var loadout := Loadout.new()
	loadout.weapon_1 = weapons[0]
	loadout.weapon_2 = weapons[1]
	if at_arrival:
		loadout.second_active = player.saved_active_slot() == 1 and weapons[1] != 0
	else:
		loadout.second_active = weapons[0] == 0 and weapons[1] != 0
	loadout.charges = player.charges()
	return loadout


# La regla de volver al mundo (§8). Sitio: en las zonas RVR (todas las de la fase 5), el punto de aparición de su
# reino, donde ya lo ha puesto la zona al crearlo; en las SAFE, el guardado si es de esta instancia, de hace menos de
# 900 s, fuera de combate, vivo, con suelo y fuera de la zona segura de otro reino. Vida: la guardada más la
# regeneración del tiempo sin conexión, sin pasar del máximo; llena con null o 0 o sin posición guardada.
func _return_to_world(entity: NetEntity, player: PlayerProgress) -> void:
	var record: ProgressRecord = player.record
	var location: Dictionary = record.location
	var now: int = _platform.now_unix() if _platform != null else 0
	var saved_at: int = int(location.get(ProgressRecord.LOCATION_CLAIM_KEY, 0))
	var config: ServerConfig = _zone.get_config() if _zone != null else null
	if config != null and not NetZones.is_rvr(config.zone_id) and _can_return(entity, record, config, now, saved_at):
		var spot := Vector3(float(location["x"]), float(location["y"]), float(location["z"]))
		if _zone.place_returning(entity, spot, float(location["yaw"])):
			_stats[&"returned_to_spot"] += 1
	var combatant: Combatant = _combatant(entity.net_id)
	if combatant == null or record.health <= 0 or location.is_empty():
		return
	var elapsed: int = maxi(now - saved_at, 0) if now > 0 and saved_at > 0 else 0
	var regen: int = CombatCatalog.rules().health_regen_per_s
	combatant.health = mini(combatant.max_health, record.health + regen * elapsed)


func _can_return(entity: NetEntity, record: ProgressRecord, config: ServerConfig, now: int, saved_at: int) -> bool:
	var location: Dictionary = record.location
	if location.is_empty() or now <= 0 or saved_at <= 0 or now - saved_at >= RETURN_WINDOW_S:
		return false
	if String(location.get("zone_id", "")) != config.zone_id or int(location.get("channel", -1)) != config.channel:
		return false
	if bool(location.get("in_combat", true)) or record.health == 0:
		return false
	var spot := Vector3(float(location.get("x", 0.0)), float(location.get("y", 0.0)), float(location.get("z", 0.0)))
	var safe: SafeAreas = _zone.get_safe_areas()
	if safe != null:
		for realm: int in NetProtocol.Realm.values():
			if realm != NetProtocol.Realm.NONE and realm != entity.realm and safe.contains_own(realm, spot):
				return false
	return true


# El temporizador de /atascado (§8): el guardado, con su clave ("character:<id>"), en el UnstuckTracker; los
# vencidos se descartan del registro.
func _restore_timers(entity: NetEntity, player: PlayerProgress, s: int) -> void:
	var now: int = _platform.now_unix() if _platform != null else 0
	if now <= 0 or not player.persistent:
		return
	for key: String in player.record.timers.keys():
		if player.record.timers[key] <= now:
			player.record.timers.erase(key)
	if player.record.timers.has(TIMER_UNSTUCK) and _zone != null:
		_zone.get_unstuck().set_ready_at(_zone.unstuck_key_of(entity),
				PlayerProgress.ready_tick_for(player.record.timers[TIMER_UNSTUCK], now, s))


# --- Recompensas (§6.2) --------------------------------------------------------------------------

# La sesión de quien puede cobrar una recompensa: con [PlayerProgress] (un jugador con peer, también el cuerpo que se
# queda tras una salida en combate), sin la marca de un comando de GM y que no sea un GM invisible (plataforma.md P7b:
# además no hace daño ni cuenta en el círculo); null con plataforma y --fake-players.
func _collector(net_id: int) -> _Session:
	if _rewards_blocked:
		_stats[&"rewards_blocked"] += 1
		return null
	var session: _Session = _sessions.get(net_id)
	if session == null:
		return null
	var entity: NetEntity = _entity(net_id)
	# Ni el marcado por un comando de GM ni un GM invisible cobran (§6.2; plataforma.md §9.1).
	if entity == null or entity.gm_forced or entity.gm_invisible:
		return null
	return session


func _pay_merits(session: _Session, amount: int, reason: int, ref_kind: int, ref_id: int, source: int,
		s: int) -> void:
	_stats[&"merits"] += session.player.gain_currency(Currency.Code.MERITS, amount, reason, ref_kind, ref_id)
	_grant_xp(session, amount * ProgressionRules.XP_PER_MERIT, source, s)


# Suma XP; si sube de nivel: el nivel en la entidad (los SPAWN siguientes), el LEVEL_UP y el guardado crítico (§6.3).
# PROGRESS_UPDATE sale en flush con lo ganado.
func _grant_xp(session: _Session, amount: int, source: int, s: int) -> void:
	if amount <= 0:
		return
	var result: ProgressionRules.XpResult = session.player.add_xp(amount, source)
	_stats[&"xp"] += result.applied
	if result.levels_gained <= 0:
		return
	_stats[&"level_ups"] += 1
	var entity: NetEntity = _entity(session.net_id)
	if entity != null:
		entity.level = result.level
	if level_up_sink.is_valid():
		level_up_sink.call(session.net_id, result.level, s)
	if _saver != null and session.player.persistent:
		_saver.mark_critical(session.net_id, CRITICAL_LEVEL_UP)
	_log("Progreso: net_id %d (%s) sube al nivel %d" % [session.net_id, _who(session.player), result.level])


# Los temporizadores de captura guardados (§8), en ticks de esta sesión: los vencidos ya los ha quitado el alta.
func _restore_capture_timers(session: _Session, s: int) -> void:
	var now: int = _platform.now_unix() if _platform != null else 0
	if now <= 0 or not session.player.persistent:
		return
	var timers: Dictionary[String, int] = session.player.record.timers
	for key: String in timers:
		if key.begins_with(TIMER_CAPTURE_PREFIX):
			session.capture_ready[key] = PlayerProgress.ready_tick_for(timers[key], now, s)


# La huella u32 de un id de texto (el ref_id de un PNJ o una fortaleza, §5.2).
func _ref_id(text_id: StringName) -> int:
	if not _ref_ids.has(text_id):
		_ref_ids[text_id] = HandoffTicket.zone_key_of(String(text_id))
	return _ref_ids[text_id]


static func _who(player: PlayerProgress) -> String:
	return "personaje %d" % player.character_id if player.persistent else "efímero"


# --- Interno -------------------------------------------------------------------------------------

func _entity(net_id: int) -> NetEntity:
	return _zone.get_registry().get_entity(net_id) if _zone != null and _zone.get_registry() != null else null


func _combatant(net_id: int) -> Combatant:
	if _zone == null or _zone.get_combat() == null:
		return null
	var combatant: Combatant = _zone.get_combat().get_combatant(net_id)
	return combatant if combatant != null and combatant.get_character() != null else null


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
