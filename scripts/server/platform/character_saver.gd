class_name CharacterSaver
extends RefCounted
## Cuándo y cómo se guarda cada personaje en la plataforma (docs/plataforma.md §7.2, §7.3 y §14.3): punto de
## control, eventos críticos, guardado final y baja sin guardado, con una escritura en vuelo por personaje. Solo
## existe con [code]--platform[/code]: sin plataforma nada se guarda (docs/progresion.md §9.4).
## [br][br]
## [b]Secciones[/b] ([method register_section]): cada una pone una clave del cuerpo ([code]progress[/code] de
## [code]ProgressService[/code], progresion.md P5a; [code]pvp[/code] de [code]ScoreKeeper[/code], P6) con tres
## [Callable]: [code]build(net_id, seq) -> Dictionary[/code] (una vez por [code]seq[/code]; [code]{}[/code] = no se
## puede construir ahora), [code]acknowledge(net_id, seq)[/code] (tras un 200 [code]applied[/code] o
## [code]duplicate[/code], solo antes de [method finish]) e [code]is_dirty(net_id) -> bool[/code] (si hay algo que
## guardar en el punto de control, solo antes de [method finish]). Se construyen en el orden en que se registran.
## [b]Sin ninguna sección no hay nada que guardar[/b]: el punto de control nunca está sucio, un crítico no manda
## nada y [method finish] libera el arrendamiento sin guardar, como hacía plataforma.md P4 (la plataforma exige
## [code]progress[/code], que llega con progresion.md P5a).
## [br][br]
## [b]Entradas por [code]lease_id[/code][/b] (único por reclamación), con dos índices: [code]character_id[/code] →
## [code]lease_id[/code] actual y, hasta [method finish] o [method drop], [code]net_id[/code] → [code]lease_id[/code].
## Cada respuesta se asocia por el [code]lease_id[/code] y el [code]seq[/code] de su propia petición (el
## [code]context[/code] de [method ZonePlatform.save]), nunca por [code]character_id[/code] ni por [code]net_id[/code]:
## un [code]net_id[/code] reutilizado o el mismo personaje que vuelve con otra reclamación no reciben las respuestas
## de la entrada vieja.
## [br][br]
## [b]Cuándo[/b] ([method step], tras «altas»): un crítico marcado sale en cuanto no hay otro en vuelo; el punto de
## control, cada [code]interval_ticks[/code] en la fase del personaje ([code]tick % interval ==
## character_id % interval[/code]) si alguna sección está sucia. Mientras uno vuela, los cambios solo marcan; con su
## respuesta definitiva se construye el siguiente en el [method step] de ese tick. [method finish] construye el
## final en el momento (con [code]release_lease[/code]) y, si hay uno en vuelo, espera detrás sin rehacerse.
## [br][br]
## [b]El sobre[/b] (§7.3) lo arma entero esta clase: [code]save_format[/code], [code]character_id[/code],
## [code]zone_instance_id[/code] y [code]lease_id[/code] (ids en cadena), [code]seq[/code] (desde 1 en cada
## arrendamiento, sube 1 en cada cuerpo), [code]reason[/code], [code]release_lease[/code] y una clave por sección.
## Se serializa una sola vez; los reintentos de [ZonePlatform] mandan esos mismos bytes.
## [br][br]
## [b]Respuestas[/b] (la tabla de §7.3): 200 [code]applied[/code] o [code]duplicate[/code] → aplicado; cualquier
## otro 4xx (salvo 401) → definitivo: antes de [method finish], [signal save_rejected] (la zona hace la baja sin
## guardado: [method drop], expulsión con el cuerpo fuera en el acto…); después, solo se registra y, salvo un
## [code]lease_lost[/code], se libera ese arrendamiento. Un 409 [code]instance_*[/code] en un guardado (la
## plataforma de §6.1 no lo da: lo dice [code]instance_status[/code]) no culpa al jugador: el mismo cuerpo se
## reenvía hasta [constant MAX_CLOSING_RESENDS] veces, porque los guardados finales de una instancia cerrada valen.

## Motivo del guardado ([code]reason[/code] del sobre, §7.3).
enum Reason { CHECKPOINT = 1, CRITICAL = 2, LOGOUT = 3, SHUTDOWN = 4, KICK = 5 }

## Un guardado de [param net_id] ha recibido una respuesta definitiva que no es un 200 ([param code]:
## [code]lease_lost[/code], [code]invalid_save[/code], [code]stale_seq[/code], [code]http_403[/code]…) antes de
## [method finish]: la zona hace la baja sin guardado de §7.2. Después de [method finish] no se emite.
signal save_rejected(net_id: int, character_id: int, code: String)

## [code]save_format[/code] del sobre (§7.1).
const SAVE_FORMAT: int = 1
## Reenvíos del mismo cuerpo tras un 409 [code]instance_lost[/code], [code]instance_replaced[/code] o
## [code]instance_stopped[/code]; después, definitivo.
const MAX_CLOSING_RESENDS: int = 3
## Código de la baja sin guardado que no libera: el arrendamiento ya no es de esta zona.
const LEASE_LOST: String = "lease_lost"

## Registro (un [Callable] con un texto); sin él, print. Las alertas van además con [method push_warning].
var log_sink: Callable = Callable()

var _platform: ZonePlatform = null
var _interval_ticks: int = 3600
var _sections: Array[_Section] = []
## lease_id -> entrada.
var _entries: Dictionary[String, _Entry] = {}
## character_id -> lease_id de su entrada más reciente.
var _by_character: Dictionary[int, String] = {}
## net_id -> lease_id, hasta finish o drop.
var _by_net: Dictionary[int, String] = {}
## Fase (character_id % interval) -> lease_id de las entradas atadas: el punto de control de un tick solo mira la
## suya.
var _by_phase: Dictionary[int, PackedStringArray] = {}
## lease_id de las entradas atadas con un crítico marcado o un punto de control aplazado: se miran en cada step.
var _urgent: Dictionary[String, bool] = {}
var _stats: Dictionary[StringName, int] = {
	&"tracked": 0, &"sent": 0, &"bytes": 0, &"max_bytes": 0, &"applied": 0, &"duplicates": 0,
	&"rejected": 0, &"deferred": 0, &"finals": 0, &"finals_unbuilt": 0, &"dropped": 0, &"released": 0,
	&"resent": 0, &"stale_answers": 0, &"criticals": 0,
}
## Críticos marcados por motivo (solo registro y métricas, progresion.md §9.2).
var _criticals_by_reason: Dictionary[StringName, int] = {}


## Una sección del cuerpo.
class _Section:
	extends RefCounted
	var name: StringName = &""
	var build: Callable = Callable()
	var acknowledge: Callable = Callable()
	var is_dirty: Callable = Callable()


## Lo que se sabe de un arrendamiento (una reclamación) de esta zona.
class _Entry:
	extends RefCounted
	var lease_id: String = ""
	var character_id: int = 0
	## El cuerpo que lo construye; 0 tras finish o drop (la entrada ya no es de ningún net_id).
	var net_id: int = 0
	## Último seq usado: el del cuerpo construido más nuevo (0 = ninguno).
	var seq: int = 0
	## Lo que vuela: su seq (0 = nada), sus bytes, si libera y su motivo.
	var flying_seq: int = 0
	var flying_body: PackedByteArray = PackedByteArray()
	var flying_release: bool = false
	var closing_resends: int = 0
	## El final que espera detrás del que vuela (vacío = ninguno).
	var final_seq: int = 0
	var final_body: PackedByteArray = PackedByteArray()
	## Marcado crítico: sale en el próximo step sin nada en vuelo.
	var critical: bool = false
	## Un punto de control que no se pudo construir: se intenta otra vez en el step siguiente.
	var retry_checkpoint: bool = false
	## Al quedar sin nada en vuelo, liberar sin guardar (un final que no se pudo construir, drop).
	var release_when_idle: bool = false
	## El arrendamiento ya no es de esta zona: nunca se libera.
	var lease_lost: bool = false


## [param interval_ticks]: los ticks entre puntos de control ([code]--save-interval[/code] por los ticks por
## segundo).
func _init(platform: ZonePlatform, interval_ticks: int = 3600) -> void:
	_platform = platform
	_interval_ticks = maxi(interval_ticks, 1)


## Registra la sección [param section] (la clave del cuerpo). Una con el mismo nombre sustituye a la anterior.
func register_section(section: StringName, build: Callable, acknowledge: Callable, is_dirty: Callable) -> void:
	var entry := _Section.new()
	entry.name = section
	entry.build = build
	entry.acknowledge = acknowledge
	entry.is_dirty = is_dirty
	for i: int in _sections.size():
		if _sections[i].name == section:
			_sections[i] = entry
			return
	_sections.append(entry)


## Los nombres de las secciones registradas, en su orden.
func section_names() -> Array[StringName]:
	var names: Array[StringName] = []
	for section: _Section in _sections:
		names.append(section.name)
	return names


## Ticks entre puntos de control.
func interval_ticks() -> int:
	return _interval_ticks


## Empieza a guardar el cuerpo [param net_id] del personaje [param character_id] con el arrendamiento
## [param lease_id] (al crear la entidad, antes de [code]ProgressService.on_arrival[/code], que puede marcarlo
## crítico: ese crítico sale en el [method step] de este mismo tick). Una entrada de otro [code]lease_id[/code] del
## mismo personaje (su final aún se reintenta) no se toca.
func track(net_id: int, character_id: int, lease_id: String, tick: int) -> void:
	if net_id < 1 or character_id < 1 or lease_id.is_empty():
		_alert("track con datos que no valen (net_id %d, personaje %d, lease_id «%s»)" % [net_id, character_id,
				lease_id])
		return
	if _entries.has(lease_id):
		_alert("el arrendamiento %s del personaje %d ya tenía entrada: se ignora el segundo track" % [lease_id,
				character_id])
		return
	if _by_net.has(net_id):
		# La zona no llamó a finish ni a drop del cuerpo anterior con este net_id: se suelta sin guardar.
		_alert("el net_id %d aún tenía entrada al llegar otro cuerpo: se suelta sin guardar" % net_id)
		drop(net_id, "net_id_reused")
	var entry := _Entry.new()
	entry.lease_id = lease_id
	entry.character_id = character_id
	entry.net_id = net_id
	_entries[lease_id] = entry
	_by_character[character_id] = lease_id
	_by_net[net_id] = lease_id
	var phase: int = character_id % _interval_ticks
	var bucket: PackedStringArray = _by_phase.get(phase, PackedStringArray())
	bucket.append(lease_id)
	_by_phase[phase] = bucket
	_stats[&"tracked"] += 1
	_log_line("Guardados: personaje %d (net_id %d) con el arrendamiento %s desde el tick %d" % [character_id, net_id,
			lease_id, tick])


## Marca crítico al cuerpo [param net_id]: su guardado sale en el próximo [method step] sin nada en vuelo.
## [param reason] solo va al registro y a las métricas (progresion.md §9.2).
func mark_critical(net_id: int, reason: StringName) -> void:
	var entry: _Entry = _attached(net_id)
	if entry == null:
		return
	entry.critical = true
	_urgent[entry.lease_id] = true
	_stats[&"criticals"] += 1
	_criticals_by_reason[reason] = _criticals_by_reason.get(reason, 0) + 1


## Tras «altas» en cada tick (la foto se toma dentro del tick): los críticos marcados y los puntos de control que
## tocan en [param tick], de los cuerpos sin nada en vuelo. Solo mira los de la fase de [param tick] y los
## pendientes (críticos y aplazados): con 64 cuerpos, casi siempre ninguno.
func step(tick: int) -> void:
	var bucket: PackedStringArray = _by_phase.get(tick % _interval_ticks, PackedStringArray())
	if bucket.is_empty() and _urgent.is_empty():
		return
	var candidates: PackedStringArray = PackedStringArray(_urgent.keys())
	for lease_id: String in bucket:
		if not _urgent.has(lease_id):
			candidates.append(lease_id)
	for lease_id: String in candidates:
		var entry: _Entry = _entries.get(lease_id)
		if entry == null or entry.net_id == 0 or entry.flying_seq != 0:
			continue
		if entry.critical:
			_save_now(entry, Reason.CRITICAL)
		elif entry.retry_checkpoint or tick % _interval_ticks == entry.character_id % _interval_ticks:
			if _any_dirty(entry.net_id):
				_save_now(entry, Reason.CHECKPOINT)
			else:
				entry.retry_checkpoint = false
				_urgent.erase(entry.lease_id)


## El cuerpo [param net_id] se va (salida, expulsión o cierre; [param reason] de [enum Reason]): el final se
## construye ahora, con [code]release_lease[/code], y sale en cuanto no haya otro en vuelo. Desata el
## [code]net_id[/code]: lo que llegue después ya no es de este cuerpo. Sobre un [code]net_id[/code] sin entrada (ya
## pasó por [method drop], o no era de un personaje) no hace nada. Un final que no se puede construir ([code]{}[/code]
## de una sección) o sin secciones: se libera sin guardar.
func finish(net_id: int, reason: int) -> void:
	var entry: _Entry = _attached(net_id)
	if entry == null:
		return
	var body := PackedByteArray()
	var seq: int = entry.seq + 1
	if not _sections.is_empty():
		body = _build_body(entry, seq, reason, true)
		if body.is_empty():
			_stats[&"finals_unbuilt"] += 1
			_alert("no se ha podido construir el guardado final del personaje %d: se libera sin guardar"
					% entry.character_id)
	_detach(entry)
	if body.is_empty():
		entry.release_when_idle = true
		_settle(entry)
		return
	entry.seq = seq
	_stats[&"finals"] += 1
	if entry.flying_seq != 0:
		entry.final_seq = seq
		entry.final_body = body
	else:
		_submit(entry, seq, body, true)


## Baja sin guardado del cuerpo [param net_id] (§7.2): desata la entrada, descarta el final que esperase y libera
## el arrendamiento salvo con [param code] [code]lease_lost[/code] (si hay un guardado en vuelo, al llegar su
## respuesta). Sobre un [code]net_id[/code] sin entrada, nada.
func drop(net_id: int, code: String) -> void:
	var entry: _Entry = _attached(net_id)
	if entry == null:
		return
	_detach(entry)
	entry.final_seq = 0
	entry.final_body = PackedByteArray()
	if code == LEASE_LOST:
		entry.lease_lost = true
	entry.release_when_idle = true
	_stats[&"dropped"] += 1
	_log_line("Guardados: baja sin guardado del personaje %d (net_id %d): %s" % [entry.character_id, net_id, code])
	_settle(entry)


## Atiende una respuesta de [method ZonePlatform.save]. true si era de un guardado (kind [code]save[/code]).
func on_platform_event(event: PlatformEvent) -> bool:
	if event.kind != PlatformEvent.KIND_SAVE:
		return false
	var context: Dictionary = event.context if event.context is Dictionary else {}
	var lease_id: String = String(context.get("lease_id", ""))
	var seq: int = int(context.get("seq", 0))
	var entry: _Entry = _entries.get(lease_id)
	if entry == null or entry.flying_seq == 0 or entry.flying_seq != seq:
		_stats[&"stale_answers"] += 1
		_log_line("Guardados: respuesta que no se esperaba (arrendamiento %s, seq %d): %s" % [lease_id, seq,
				ZonePlatform.describe(event)])
		return true
	var body: PackedByteArray = entry.flying_body
	var released: bool = entry.flying_release
	entry.flying_seq = 0
	entry.flying_body = PackedByteArray()
	entry.flying_release = false
	if event.is_success():
		_on_applied(entry, seq, released, event)
	elif PlatformClient.is_retryable(event) or (PlatformEvent.CLOSING_CODES.has(event.error_code)
			and entry.closing_resends < MAX_CLOSING_RESENDS):
		# No es una respuesta sobre el cuerpo: el mismo, con el mismo seq.
		entry.closing_resends += 1
		_stats[&"resent"] += 1
		_submit(entry, seq, body, released, false)
	else:
		_on_definitive(entry, seq, event)
	return true


## Guardados en vuelo más finales que esperan detrás (el cierre ordenado espera a que sea 0).
func pending_count() -> int:
	var count: int = 0
	for entry: _Entry in _entries.values():
		if entry.flying_seq != 0:
			count += 1
		if not entry.final_body.is_empty():
			count += 1
	return count


## Los net_id con entrada (los que [method finish] o [method drop] aún no han desatado), ordenados.
func tracked_net_ids() -> Array[int]:
	var ids: Array[int] = []
	ids.assign(_by_net.keys())
	ids.sort()
	return ids


## true si [param net_id] tiene entrada.
func is_tracked(net_id: int) -> bool:
	return _by_net.has(net_id)


## El net_id atado al arrendamiento [param lease_id] del personaje [param character_id], o 0.
func net_id_of(character_id: int, lease_id: String) -> int:
	var entry: _Entry = _entries.get(lease_id)
	if entry == null or entry.character_id != character_id:
		return 0
	return entry.net_id


## El lease_id de la entrada más reciente de [param character_id] (vacío si no tiene).
func lease_of(character_id: int) -> String:
	return _by_character.get(character_id, "")


## Entradas vivas (con cuerpo o con algo pendiente).
func entry_count() -> int:
	return _entries.size()


## Contadores para el informe y las pruebas.
func get_stats() -> Dictionary:
	var stats: Dictionary = {}
	for key: StringName in _stats:
		stats[String(key)] = _stats[key]
	var reasons: Dictionary = {}
	for reason: StringName in _criticals_by_reason:
		reasons[String(reason)] = _criticals_by_reason[reason]
	stats["criticals_by_reason"] = reasons
	stats["pending"] = pending_count()
	stats["entries"] = _entries.size()
	stats["interval_ticks"] = _interval_ticks
	return stats


# --- Internos ---------------------------------------------------------------------------------

# La entrada atada a [param net_id], o null.
func _attached(net_id: int) -> _Entry:
	var lease_id: String = _by_net.get(net_id, "")
	if lease_id.is_empty():
		return null
	return _entries.get(lease_id)


func _detach(entry: _Entry) -> void:
	if entry.net_id != 0 and _by_net.get(entry.net_id, "") == entry.lease_id:
		_by_net.erase(entry.net_id)
		var phase: int = entry.character_id % _interval_ticks
		var bucket: PackedStringArray = _by_phase.get(phase, PackedStringArray())
		var index: int = bucket.find(entry.lease_id)
		if index >= 0:
			bucket.remove_at(index)
		if bucket.is_empty():
			_by_phase.erase(phase)
		else:
			_by_phase[phase] = bucket
	_urgent.erase(entry.lease_id)
	entry.net_id = 0
	entry.critical = false
	entry.retry_checkpoint = false


func _any_dirty(net_id: int) -> bool:
	for section: _Section in _sections:
		if section.is_dirty.is_valid() and bool(section.is_dirty.call(net_id)):
			return true
	return false


# Construye y manda un punto de control o un crítico. Si alguna sección no puede construirse, no gasta seq: el
# crítico sigue marcado y el punto de control se intenta en el step siguiente.
func _save_now(entry: _Entry, reason: int) -> void:
	if _sections.is_empty():
		entry.critical = false
		entry.retry_checkpoint = false
		_urgent.erase(entry.lease_id)
		return
	var seq: int = entry.seq + 1
	var body: PackedByteArray = _build_body(entry, seq, reason, false)
	if body.is_empty():
		_stats[&"deferred"] += 1
		if reason == Reason.CHECKPOINT:
			entry.retry_checkpoint = true
			_urgent[entry.lease_id] = true
		return
	entry.seq = seq
	entry.critical = false
	entry.retry_checkpoint = false
	_urgent.erase(entry.lease_id)
	_submit(entry, seq, body, false)


# El sobre entero de §7.3, serializado una vez; vacío si alguna sección devuelve {} (las anteriores ya se han
# construido: la única que puede devolverlo, progress, se registra primero y no toca nada al hacerlo).
func _build_body(entry: _Entry, seq: int, reason: int, release_lease: bool) -> PackedByteArray:
	var envelope: Dictionary = {
		"save_format": SAVE_FORMAT,
		"character_id": PlatformJson.id_text(entry.character_id),
		"zone_instance_id": _platform.instance_id() if _platform != null else "",
		"lease_id": entry.lease_id,
		"seq": seq,
		"reason": reason,
		"release_lease": release_lease,
	}
	for section: _Section in _sections:
		var built: Variant = section.build.call(entry.net_id, seq) if section.build.is_valid() else null
		if not built is Dictionary or (built as Dictionary).is_empty():
			return PackedByteArray()
		envelope[String(section.name)] = built
	return JSON.stringify(envelope).to_utf8_buffer()


func _submit(entry: _Entry, seq: int, body: PackedByteArray, release_lease: bool, first: bool = true) -> void:
	entry.flying_seq = seq
	entry.flying_body = body
	entry.flying_release = release_lease
	if first:
		entry.closing_resends = 0
		_stats[&"sent"] += 1
		_stats[&"bytes"] += body.size()
		_stats[&"max_bytes"] = maxi(_stats[&"max_bytes"], body.size())
	if _platform != null:
		_platform.save(entry.character_id, entry.lease_id, body, release_lease,
				{"lease_id": entry.lease_id, "seq": seq})


func _on_applied(entry: _Entry, seq: int, released: bool, event: PlatformEvent) -> void:
	_stats[&"applied"] += 1
	if bool(event.body_dict().get("duplicate", false)):
		_stats[&"duplicates"] += 1
	if entry.net_id != 0:
		for section: _Section in _sections:
			if section.acknowledge.is_valid():
				section.acknowledge.call(entry.net_id, seq)
	if not entry.final_body.is_empty():
		var final_seq: int = entry.final_seq
		var final_body: PackedByteArray = entry.final_body
		entry.final_seq = 0
		entry.final_body = PackedByteArray()
		_submit(entry, final_seq, final_body, true)
		return
	if released:
		# El final aplicado ya liberó el arrendamiento en la plataforma.
		entry.release_when_idle = false
		_forget(entry)
		return
	_settle(entry)


func _on_definitive(entry: _Entry, seq: int, event: PlatformEvent) -> void:
	var code: String = event.error_code if not event.error_code.is_empty() else "http_%d" % event.status
	_stats[&"rejected"] += 1
	var detail: String = ""
	var fields: Dictionary = PlatformJson.dict_in(event.error_dict(), "fields")
	if not fields.is_empty():
		detail = " (%s: %s)" % [PlatformJson.text_in(fields, "check"), PlatformJson.text_in(fields, "detail")]
	_alert("el guardado del personaje %d (arrendamiento %s, seq %d) recibe %s%s" % [entry.character_id,
			entry.lease_id, seq, ZonePlatform.describe(event), detail])
	if code == LEASE_LOST:
		entry.lease_lost = true
	# El final que esperaba se descarta con él: llevaba solo lo que este no.
	entry.final_seq = 0
	entry.final_body = PackedByteArray()
	if entry.net_id != 0:
		var net_id: int = entry.net_id
		save_rejected.emit(net_id, entry.character_id, code)
		# Si nadie ha hecho la baja, la hace aquí: la entrada no se queda atada a un cuerpo que no guarda.
		if _attached(net_id) == entry:
			drop(net_id, code)
		return
	entry.release_when_idle = true
	_settle(entry)


# Una entrada desatada y sin nada en vuelo ni esperando se cierra: libera si toca (nunca tras un lease_lost).
func _settle(entry: _Entry) -> void:
	if entry.net_id != 0 or entry.flying_seq != 0 or not entry.final_body.is_empty():
		return
	if entry.release_when_idle and not entry.lease_lost and _platform != null:
		_stats[&"released"] += 1
		_platform.release(entry.character_id, entry.lease_id)
	_forget(entry)


func _forget(entry: _Entry) -> void:
	_entries.erase(entry.lease_id)
	if _by_character.get(entry.character_id, "") == entry.lease_id:
		_by_character.erase(entry.character_id)


func _alert(text: String) -> void:
	push_warning("[Eldmark] Guardados: alerta: %s" % text)
	_log_line("Guardados: alerta: %s" % text)


func _log_line(text: String) -> void:
	if log_sink.is_valid():
		log_sink.call(text)
	else:
		print("[Eldmark] %s" % text)
