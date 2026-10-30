class_name FortressPersistence
extends RefCounted
## La guerra persistente en la zona (docs/plataforma.md §8, GUE-19): el registro de cada fortaleza en la plataforma
## ([code]fortresses.record[/code], esquema 1) y el historial de sus eventos. Solo existe con
## [code]--platform[/code]; vive en [code]scripts/server/war/[/code] porque lee el reloj de la plataforma
## ([method ZonePlatform.now_unix]), y [code]scripts/shared[/code] no lo lee.
## [codeblock]
## {"schema": 1, "owner": 1, "phase": "consolidating", "phase_ends_at_unix": 1800000120,
##  "captain_alive": false, "captain_respawn_at_unix": null, "gate_health": 2600,
##  "capture_realm": 0, "capture_progress": 0, "last_reset_at_unix": 1799999000}
## [/codeblock]
## [b]Ticks y hora Unix[/b] ([method unix_of], [method tick_until], [method tick_since]): un tick [code]t[/code] se
## escribe como [code]now_unix + ceili((t − tick) / 60.0)[/code]; al cargar, un plazo vuelve como
## [code]tick + max(0, at − now_unix) · 60[/code] y el último reinicio, que es pasado, como
## [code]tick − max(0, now_unix − at) · 60[/code] (reiniciar el proceso no reinicia el ciclo de 30 min). Lo que no
## tiene plazo va como null: [code]phase_ends_at_unix[/code] es el fin de la consolidación o la vuelta del capitán
## en VULNERABLE, y [code]captain_respawn_at_unix[/code], esa vuelta.
## [br][br]
## [b]Al arrancar[/b] ([method load_records], dentro de [method ZoneServer.start] y antes de abrir el puerto): lo que
## trajo el GET de [method ZonePlatform.start] se aplica con [method FortressController.restore_state]. Sin registro
## (primer arranque), el estado inicial sin aviso, y se escribe en cuanto la instancia está viva; con otro
## [code]schema[/code] o uno que no vale, el estado inicial con un aviso. CONSOLIDATING conserva dueño y plazo;
## VULNERABLE, el plazo del capitán; CAPTURING vuelve con su captor y su progreso, el círculo vacío y decayendo (la
## máquina de docs/fuerte.md §1.5 solo tiene progreso en CAPTURING: si nadie vuelve, a 0 pasa a VULNERABLE). Los
## guardias no se guardan: los repone el generador. Una puerta dañada se repara a los 5 min del arranque.
## [br][br]
## [b]Guardar[/b] ([method step], tras el paso de las fortalezas): en cada cambio de dueño, de fase o de ciclo (un
## reinicio) y, si cambió algo más (la vida de la puerta, el progreso, el plazo del capitán), cada 60 s
## ([constant SAVE_INTERVAL_TICKS]); el cierre ordenado escribe lo que quede ([method flush]). Solo escribe la
## instancia [code]live[/code] ([method ZonePlatform.is_live]): un cambio anterior sale al quedar viva.
## [method ZonePlatform.put_fortress] lleva una petición en vuelo por fortaleza con [code]expected_version[/code] y
## reenvía tras [code]version_conflict[/code]; las respuestas llegan aquí como eventos [code]fortress[/code].
## [br][br]
## [b]Historial[/b] ([method on_war_event]): los avisos 3 (captura iniciada), 6 (capturado) y 7 (reiniciado) van al
## lote [code]war[/code] ([code]{key, fortress_id, event, realm, at_unix}[/code]); la [code]key[/code] la pone
## [method ZonePlatform.enqueue_batch] y un lote reenviado no duplica nada.

## Esquema del registro.
const SCHEMA: int = 1
## Cada cuánto (ticks) se escribe una fortaleza a la que solo le han cambiado cosas menores (60 s).
const SAVE_INTERVAL_TICKS: int = 3600
## Nombre de cada [enum FortressState.Phase] en el registro.
const PHASE_NAMES: PackedStringArray = ["garrisoned", "vulnerable", "capturing", "consolidating"]
## Avisos de guerra que van al historial (fortress_events).
const PERSISTED_WAR_EVENTS: Array[int] = [WarEvents.CAPTURE_STARTED, WarEvents.FORT_CAPTURED, WarEvents.FORT_RESET]
## Clase del lote del historial ([method ZonePlatform.enqueue_batch]).
const WAR_BATCH: StringName = &"war"
## La mayor hora Unix que admite la plataforma (9999-12-31).
const MAX_UNIX: int = 253402300799

## Registro de la zona (un [Callable] con un texto); sin él, print. Los avisos van además con [method push_warning].
var log_sink: Callable = Callable()

var _platform: ZonePlatform = null
var _controller: FortressController = null
var _closed: bool = false
var _tracked: Dictionary[StringName, _Tracked] = {}
var _stats: Dictionary[StringName, int] = {
	&"loaded": 0, &"initial": 0, &"discarded": 0, &"puts": 0, &"put_ok": 0, &"put_conflicts": 0,
	&"put_failed": 0, &"war_events": 0,
}


## Lo que se escribió de una fortaleza: la parte que sale enseguida si cambia (dueño, fase y ciclo) y la que sale
## cada 60 s, en ticks (la hora Unix se mueve con el reloj y no dice si cambió algo).
class _Tracked:
	extends RefCounted
	var major: Array = []
	var minor: Array = []
	var last_put_tick: int = 0
	## Escribir en cuanto la instancia esté viva (primer arranque, sin registro).
	var pending: bool = false


## Un registro leído: el estado, el fin de una consolidación cargada y, si no vale, el motivo.
class Loaded:
	extends RefCounted
	var state: FortressState = null
	var consolidation_ends_tick: int = FortressState.NO_TICK
	## Vacío si el registro vale; si no, por qué (el estado es entonces el inicial).
	var error: String = ""


func _init(platform: ZonePlatform, controller: FortressController) -> void:
	_platform = platform
	_controller = controller


# --- Conversión -------------------------------------------------------------------------------

## La hora Unix del tick [param t] visto desde [param tick] con el reloj [param now_unix]:
## [code]now_unix + ceili((t − tick) / 60.0)[/code] (un plazo nunca sale antes de su tick).
static func unix_of(t: int, tick: int, now_unix: int) -> int:
	return now_unix + ceili(float(t - tick) / float(CombatCatalog.TICK_RATE))


## El tick de un plazo futuro [param at_unix]: [code]tick + max(0, at − now_unix) · 60[/code].
static func tick_until(at_unix: int, tick: int, now_unix: int) -> int:
	return tick + maxi(0, at_unix - now_unix) * CombatCatalog.TICK_RATE


## El tick de un instante pasado [param at_unix]: [code]tick − max(0, now_unix − at) · 60[/code].
static func tick_since(at_unix: int, tick: int, now_unix: int) -> int:
	return tick - maxi(0, now_unix - at_unix) * CombatCatalog.TICK_RATE


## El registro (esquema 1) de [param state] en el tick [param tick] con el reloj [param now_unix].
## [param consolidation_ends_tick] es el fin de la consolidación si lo lleva el controlador
## ([method FortressController.get_consolidation_end_tick]); sin él, el inicio de la fase más su duración.
static func to_record(state: FortressState, def: FortressDefinition, tick: int, now_unix: int,
		consolidation_ends_tick: int = FortressState.NO_TICK) -> Dictionary:
	var record: Dictionary = {
		"schema": SCHEMA, "owner": state.owner, "phase": PHASE_NAMES[state.phase], "phase_ends_at_unix": null,
		"captain_alive": state.captain_alive, "captain_respawn_at_unix": null, "gate_health": state.gate_health,
		"capture_realm": 0, "capture_progress": 0,
		"last_reset_at_unix": clampi(unix_of(state.last_reset_tick, tick, now_unix), 0, MAX_UNIX),
	}
	match state.phase:
		FortressState.Phase.CONSOLIDATING:
			var ends: int = consolidation_ends_tick if consolidation_ends_tick != FortressState.NO_TICK \
					else state.phase_tick + def.consolidation_ticks()
			record["phase_ends_at_unix"] = clampi(unix_of(ends, tick, now_unix), 0, MAX_UNIX)
		FortressState.Phase.VULNERABLE:
			if state.captain_respawn_tick != FortressState.NO_TICK:
				var back: int = clampi(unix_of(state.captain_respawn_tick, tick, now_unix), 0, MAX_UNIX)
				record["phase_ends_at_unix"] = back
				record["captain_respawn_at_unix"] = back
		FortressState.Phase.CAPTURING:
			record["capture_realm"] = state.capture_realm
			record["capture_progress"] = state.progress_at(tick)
	return record


## El estado de [param record] (lo que trae el GET, ya leído como JSON) para [param def] en el tick [param tick] con
## el reloj [param now_unix]. Si no vale (no es un objeto, otro [code]schema[/code], un campo que falta o no
## cuadra), [member Loaded.error] dice por qué y el estado es el inicial.
static func from_record(record: Variant, def: FortressDefinition, tick: int, now_unix: int) -> Loaded:
	var loaded := Loaded.new()
	loaded.state = FortressState.initial(def, tick)
	if not record is Dictionary:
		loaded.error = "no es un objeto"
		return loaded
	var data: Dictionary = record
	var schema: int = PlatformJson.int_in(data, "schema", 0, PlatformJson.MAX_SAFE_INT, -1)
	if schema != SCHEMA:
		loaded.error = "esquema %s" % (str(schema) if schema >= 0 else "desconocido")
		return loaded
	var owner: int = PlatformJson.int_in(data, "owner", 0, 3, -1)
	var phase: int = PHASE_NAMES.find(PlatformJson.text_in(data, "phase"))
	var gate_health: int = PlatformJson.int_in(data, "gate_health", 0, PlatformJson.MAX_SAFE_INT, -1)
	var capture_realm: int = PlatformJson.int_in(data, "capture_realm", 0, 3, -1)
	var capture_progress: int = PlatformJson.int_in(data, "capture_progress", 0, PlatformJson.MAX_SAFE_INT, -1)
	var errors := PackedStringArray()
	if owner < 0:
		errors.append("owner")
	if phase < 0:
		errors.append("phase")
	if gate_health < 0:
		errors.append("gate_health")
	if capture_realm < 0:
		errors.append("capture_realm")
	if capture_progress < 0:
		errors.append("capture_progress")
	if not data.get("captain_alive") is bool:
		errors.append("captain_alive")
	for key: String in ["phase_ends_at_unix", "captain_respawn_at_unix", "last_reset_at_unix"]:
		if not _is_optional_unix(data.get(key)):
			errors.append(key)
	if errors.is_empty():
		if phase == FortressState.Phase.CONSOLIDATING and owner == RealmCatalog.NEUTRAL_CODE:
			errors.append("consolidating sin dueño")
		if phase == FortressState.Phase.CAPTURING and (capture_realm == RealmCatalog.NEUTRAL_CODE
				or capture_realm == owner):
			errors.append("capturing sin captor")
	if not errors.is_empty():
		loaded.error = "no valen: %s" % ", ".join(errors)
		return loaded
	var state: FortressState = loaded.state
	state.owner = owner
	state.gate_health = mini(gate_health, state.gate_max)
	if state.gate_health < state.gate_max:
		# La hora del último golpe no se guarda: la reparación cuenta desde el arranque.
		state.gate_last_damage_tick = tick
	var last_reset: Variant = data.get("last_reset_at_unix")
	if last_reset != null:
		state.last_reset_tick = tick_since(int(last_reset), tick, now_unix)
	var phase_ends: Variant = data.get("phase_ends_at_unix")
	var captain_back: Variant = data.get("captain_respawn_at_unix")
	match phase:
		FortressState.Phase.VULNERABLE:
			state.phase = FortressState.Phase.VULNERABLE
			state.captain_alive = false
			var back: Variant = captain_back if captain_back != null else phase_ends
			state.captain_respawn_tick = tick_until(int(back), tick, now_unix) if back != null \
					else tick + def.captain_respawn_ticks()
		FortressState.Phase.CAPTURING:
			# Con su captor y su progreso; el círculo está vacío, así que decae (docs/fuerte.md §1.5).
			state.phase = FortressState.Phase.CAPTURING
			state.captain_alive = false
			state.capture_realm = capture_realm
			state.capture_start_tick = tick
			state.capture_rate = 0
			state.capture_progress_at_start = mini(capture_progress, state.progress_max)
			state.empty_since_tick = tick
		FortressState.Phase.CONSOLIDATING:
			state.phase = FortressState.Phase.CONSOLIDATING
			state.captain_alive = false
			loaded.consolidation_ends_tick = tick_until(int(phase_ends), tick, now_unix) if phase_ends != null \
					else tick + def.consolidation_ticks()
			# El inicio no baja del tick de la carga (OBJECT_STATE no lleva ticks negativos); el fin lo lleva el
			# controlador (FortressController.restore_state).
			state.phase_tick = maxi(tick, loaded.consolidation_ends_tick - def.consolidation_ticks())
	return loaded


# null o una hora Unix entera de 0 a MAX_UNIX.
static func _is_optional_unix(value: Variant) -> bool:
	return value == null or PlatformJson.is_int(value, 0, MAX_UNIX)


# --- Arranque ---------------------------------------------------------------------------------

## Aplica [param records] (lo que trajo el GET del arranque, [method ZonePlatform.fortress_records]:
## [code]{fortress_id, record, version}[/code]) en el tick [param tick], antes de abrir el puerto.
func load_records(records: Array[Dictionary], tick: int) -> void:
	var by_id: Dictionary[StringName, Dictionary] = {}
	for entry: Dictionary in records:
		by_id[StringName(entry.get("fortress_id", &""))] = entry
	var now: int = _platform.now_unix()
	for fortress_id: StringName in _controller.get_fortress_ids():
		var tracked := _Tracked.new()
		_tracked[fortress_id] = tracked
		if not by_id.has(fortress_id):
			# Primer arranque: el estado inicial, sin aviso; se escribe en cuanto la instancia esté viva.
			tracked.pending = true
			_stats[&"initial"] += 1
			_log("Fortaleza %s sin registro en la plataforma: estado inicial" % fortress_id)
		else:
			var entry: Dictionary = by_id[fortress_id]
			var loaded: Loaded = from_record(entry.get("record"), _controller.get_definition(fortress_id), tick,
					now)
			if not loaded.error.is_empty():
				_stats[&"discarded"] += 1
				_warn("Aviso: el registro de la fortaleza %s (versión %d) no vale (%s): estado inicial"
						% [fortress_id, int(entry.get("version", 0)), loaded.error])
			else:
				_controller.restore_state(fortress_id, loaded.state, loaded.consolidation_ends_tick, tick)
				_stats[&"loaded"] += 1
				_log("Fortaleza %s cargada de la plataforma (versión %d): %s" % [fortress_id,
						int(entry.get("version", 0)), describe(_controller, fortress_id, tick)])
		_remember(fortress_id, tick)
	for fortress_id: StringName in by_id:
		if not _tracked.has(fortress_id):
			_log("La plataforma tiene un registro de la fortaleza %s, que esta zona no tiene" % fortress_id)


## Una línea con el estado de [param fortress_id] para el registro: dueño, fase y el plazo que corre.
static func describe(controller: FortressController, fortress_id: StringName, tick: int) -> String:
	var state: FortressState = controller.get_fortress_state(fortress_id)
	if state == null:
		return "sin estado"
	var text: String = "dueño %s, fase %s" % [WarEvents.realm_label(state.owner), PHASE_NAMES[state.phase]]
	match state.phase:
		FortressState.Phase.CONSOLIDATING:
			text += "; consolida %d s más" % _seconds_until(controller.get_consolidation_end_tick(fortress_id), tick)
		FortressState.Phase.VULNERABLE:
			text += "; el capitán reaparece en %d s" % _seconds_until(state.captain_respawn_tick, tick)
		FortressState.Phase.CAPTURING:
			text += "; captura de %s al %d/%d" % [WarEvents.realm_label(state.capture_realm),
					state.progress_at(tick), state.progress_max]
	if state.gate_health < state.gate_max:
		text += "; puerta %d/%d" % [state.gate_health, state.gate_max]
	return text


static func _seconds_until(t: int, tick: int) -> int:
	return ceili(float(maxi(t - tick, 0)) / float(CombatCatalog.TICK_RATE))


# --- Guardar ----------------------------------------------------------------------------------

## Tras el paso de las fortalezas del tick [param s]: escribe la que ha cambiado de dueño, de fase o de ciclo y,
## cada 60 s, la que ha cambiado en algo más. Nada hasta que la instancia está viva ni tras [method close].
func step(s: int) -> void:
	if _closed or not _platform.is_live():
		return
	for fortress_id: StringName in _tracked:
		var tracked: _Tracked = _tracked[fortress_id]
		var state: FortressState = _controller.get_fortress_state(fortress_id)
		if state == null:
			continue
		if tracked.pending or _major(state) != tracked.major:
			_put(fortress_id, s)
		elif s - tracked.last_put_tick >= SAVE_INTERVAL_TICKS and _minor(fortress_id, state, s) != tracked.minor:
			_put(fortress_id, s)


## El cierre ordenado ([method ZoneServer.stop]): escribe ya cada fortaleza con algo sin escribir. Nada si la
## instancia no está viva o ya se cerró.
func flush(s: int) -> void:
	if _closed or not _platform.is_live():
		return
	for fortress_id: StringName in _tracked:
		var tracked: _Tracked = _tracked[fortress_id]
		var state: FortressState = _controller.get_fortress_state(fortress_id)
		if state == null:
			continue
		if tracked.pending or _major(state) != tracked.major or _minor(fortress_id, state, s) != tracked.minor:
			_put(fortress_id, s)


## La plataforma ha cerrado la instancia (docs/plataforma.md §6.1): ya no escribe ni registros ni eventos (la que
## manda ahora es otra).
func close() -> void:
	_closed = true


func _put(fortress_id: StringName, s: int) -> void:
	var state: FortressState = _controller.get_fortress_state(fortress_id)
	var record: Dictionary = to_record(state, _controller.get_definition(fortress_id), s, _platform.now_unix(),
			_controller.get_consolidation_end_tick(fortress_id))
	_platform.put_fortress(fortress_id, record)
	_remember(fortress_id, s)
	_tracked[fortress_id].pending = false
	_stats[&"puts"] += 1


func _remember(fortress_id: StringName, s: int) -> void:
	var tracked: _Tracked = _tracked[fortress_id]
	var state: FortressState = _controller.get_fortress_state(fortress_id)
	tracked.major = _major(state)
	tracked.minor = _minor(fortress_id, state, s)
	tracked.last_put_tick = s


# Lo que sale enseguida si cambia: dueño, fase y ciclo (el inicio de la fase y el último reinicio).
static func _major(state: FortressState) -> Array:
	return [state.owner, state.phase, state.phase_tick, state.last_reset_tick]


# Lo que sale cada 60 s si cambia: la puerta, el capitán, la captura y el fin de la consolidación.
func _minor(fortress_id: StringName, state: FortressState, s: int) -> Array:
	return [state.gate_health, state.captain_alive, state.captain_respawn_tick, state.capture_realm,
			state.progress_at(s) if state.phase == FortressState.Phase.CAPTURING else 0,
			_controller.get_consolidation_end_tick(fortress_id)]


# --- Respuestas y eventos ---------------------------------------------------------------------

## La respuesta de un PUT de fortaleza (evento [code]fortress[/code], docs/plataforma.md §14.3). La versión y el
## reenvío tras [code]version_conflict[/code] los lleva [ZonePlatform]; aquí se cuentan y se registra lo que no
## vale (un 403 es una fortaleza de otra zona). Devuelve true si era suyo.
func on_platform_event(event: PlatformEvent) -> bool:
	if event.kind != PlatformEvent.KIND_FORTRESS:
		return false
	var context: Dictionary = event.context if event.context is Dictionary else {}
	var fortress_id: StringName = context.get("fortress_id", &"")
	if event.is_success():
		_stats[&"put_ok"] += 1
	elif event.status == 409 and event.error_code == "version_conflict":
		_stats[&"put_conflicts"] += 1
		var version: int = PlatformJson.int_in(event.error_dict(), "version", 0, PlatformJson.MAX_SAFE_INT, 0)
		_log("El registro de la fortaleza %s ha cambiado en la plataforma (versión %d): se reenvía el de esta instancia"
				% [fortress_id, version])
	elif not PlatformEvent.CLOSING_CODES.has(event.error_code):
		_stats[&"put_failed"] += 1
		_warn("Alerta: la plataforma no guarda la fortaleza %s: %s" % [fortress_id, ZonePlatform.describe(event)])
	return true


## Un aviso de guerra ([signal FortressController.war_event_emitted]): los de [constant PERSISTED_WAR_EVENTS] van
## al lote [code]war[/code] con la hora de la plataforma.
func on_war_event(event: NetMessages.EntityEvent) -> void:
	if _closed or not PERSISTED_WAR_EVENTS.has(event.war_event):
		return
	var fortress_id: StringName = _controller.get_fortress_id_of(event.net_id)
	if fortress_id.is_empty():
		return
	_platform.enqueue_batch(WAR_BATCH, {"fortress_id": String(fortress_id), "event": event.war_event,
			"realm": event.war_realm, "at_unix": _platform.now_unix()})
	_stats[&"war_events"] += 1


## Contadores para el informe: registros cargados, iniciales y descartados; PUT enviados, aceptados, con conflicto
## y rechazados; eventos al historial.
func get_stats() -> Dictionary:
	var stats: Dictionary = {}
	for key: StringName in _stats:
		stats[String(key)] = _stats[key]
	return stats


func _log(text: String) -> void:
	if log_sink.is_valid():
		log_sink.call(text)
	else:
		print("[Eldmark] %s" % text)


func _warn(text: String) -> void:
	push_warning("[Eldmark] %s" % text)
	_log(text)
