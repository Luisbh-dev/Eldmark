extends TestCase
## Pruebas de [CharacterSaver] con [FakeZonePlatform] (la ida y vuelta por JSON de [PlatformClient], sin red) y una
## [FakeSaveSection] (docs/plataforma.md §7.2, §7.3 y §15 P5): el punto de control en su fase y solo con algo
## sucio, el crítico al instante (también justo tras track), una escritura en vuelo, el final que espera detrás de
## la que vuela, el sobre entero, duplicate como aplicado, una sección que no se puede construir, sin secciones, las
## respuestas definitivas antes y después de finish, un 403 y un 413 definitivos, los 409 instance_*, un net_id
## reutilizado con el final del anterior en vuelo y el mismo personaje que vuelve mientras su final se reintenta.
## Aquí no hay zona: la prueba hace de ella (step, finish, drop en save_rejected).

const LEASE_A: String = "00000000-0000-4000-8000-00000000000a"
const LEASE_B: String = "00000000-0000-4000-8000-00000000000b"
const LEASE_C: String = "00000000-0000-4000-8000-00000000000c"
## Un character_id por encima de 2^53.
const BIG_CHARACTER_ID: int = 9007199254740993

var _platform: FakeZonePlatform = null
var _saver: CharacterSaver = null
var _section: FakeSaveSection = null
var _rejections: Array[Array] = []
var _tick: int = 0
## Si es false, la prueba no hace la baja al recibir save_rejected (la hace el propio CharacterSaver).
var _drop_on_rejection: bool = true


func after_each() -> void:
	if is_instance_valid(_platform):
		_platform.get_parent().remove_child(_platform)
		_platform.free()
	_platform = null
	_saver = null
	_section = null
	_rejections.clear()
	_tick = 0
	_drop_on_rejection = true
	await wait_process_frames()


# --- Ayudantes --------------------------------------------------------------------------------

## La plataforma falsa arrancada y un CharacterSaver con [param interval_ticks] (y la sección falsa si
## [param with_section]).
func _start(interval_ticks: int = 120, with_section: bool = true) -> bool:
	_platform = FakeZonePlatform.new()
	_platform.name = "Platform"
	_platform.log_sink = func(_text: String) -> void: pass
	tree.root.add_child(_platform)
	var config := ServerConfig.new()
	config.zone_id = "test_world"
	config.platform_url = "http://fake"
	var finished: Array = []
	_platform.startup_finished.connect(func(ok: bool, error: String) -> void: finished.append([ok, error]))
	_platform.start(config, {"token": "token", "ticket_keys": {}})
	for _i: int in 120:
		if not finished.is_empty():
			break
		await wait_process_frames()
	if not assert_eq(finished, [[true, ""]], "la plataforma falsa arranca"):
		return false
	_platform.take_events()
	_saver = CharacterSaver.new(_platform, interval_ticks)
	_saver.log_sink = func(_text: String) -> void: pass
	_saver.save_rejected.connect(func(net_id: int, character_id: int, code: String) -> void:
		_rejections.append([net_id, character_id, code])
		if _drop_on_rejection:
			_saver.drop(net_id, code))
	if with_section:
		_section = FakeSaveSection.new()
		_section.tick_source = func() -> int: return _tick
		_section.attach(_saver)
	return true


## Un tick de la zona: el saver da su paso con el tick siguiente.
func _step() -> void:
	_tick += 1
	_saver.step(_tick)


## Fotogramas con el reparto de los eventos (el «poll» de la zona), hasta [param condition] o [param max_ms].
func _pump_until(condition: Callable, max_ms: int = 3000) -> bool:
	var started: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < max_ms:
		if condition.call():
			return true
		await wait_process_frames()
		for event: PlatformEvent in _platform.take_events():
			_saver.on_platform_event(event)
	return condition.call()


func _pump_ms(ms: int) -> void:
	await _pump_until(func() -> bool: return false, ms)


func _saves() -> Array[Dictionary]:
	return _platform.sent(PlatformEvent.KIND_SAVE)


func _releases() -> Array[Dictionary]:
	return _platform.sent(ZonePlatform.KIND_RELEASE)


# --- Pruebas ----------------------------------------------------------------------------------

## Punto de control con el intervalo de prueba de 120 ticks: cada personaje en su fase (character_id % 120), solo
## con algo sucio, y nada mientras no cambie.
func test_checkpoints_go_out_in_each_phase_only_when_dirty() -> void:
	if not await _start(120):
		return
	_saver.track(5, 42, LEASE_A, 0)
	_saver.track(6, 100, LEASE_B, 0)
	_saver.track(7, 130, LEASE_C, 0)
	_section.set_kills(5, 1)
	_section.set_kills(6, 2)
	for _i: int in 41:
		_step()
	assert_eq(_saves().size(), 0, "nada antes de su fase")
	_step()
	assert_eq(_section.build_ticks(5), [42], "el 42 en el tick 42")
	await _pump_until(func() -> bool: return _section.acknowledged.size() == 1)
	while _tick < 125:
		_step()
	assert_eq(_section.build_ticks(6), [100], "el 100 en el tick 100")
	assert_eq(_section.build_ticks(7), [], "el 130 (fase 10) no tiene nada sucio")
	await _pump_until(func() -> bool: return _section.acknowledged.size() == 2)
	while _tick < 170:
		_step()
	assert_eq(_section.build_ticks(5), [42], "confirmado y sin cambios, el 42 no vuelve a guardar en el 162")
	_section.set_kills(5, 3)
	while _tick < 290:
		_step()
	assert_eq(_section.build_ticks(5), [42, 282], "con un cambio, en su fase siguiente (282)")
	var saves: Array[Dictionary] = _saves()
	assert_eq(saves.size(), 3, "tres guardados en total")
	assert_eq(saves.map(func(b: Dictionary) -> int: return int(b["reason"])), [1, 1, 1], "todos de motivo 1")
	assert_eq(saves.map(func(b: Dictionary) -> String: return String(b["character_id"])), ["42", "100", "42"],
			"en el orden de sus fases")


## Un crítico sale en el mismo paso, aunque el personaje no esté en su fase; también uno marcado justo tras track.
func test_a_critical_goes_out_at_once_even_right_after_track() -> void:
	if not await _start(120):
		return
	_tick = 7
	_saver.track(5, 42, LEASE_A, _tick)
	_saver.mark_critical(5, &"starter_kit")
	_saver.step(_tick)
	assert_eq(_section.build_ticks(5), [7], "en el paso del tick del alta")
	if not assert_eq(_saves().size(), 1, "sale ya"):
		return
	assert_eq(int(_saves()[0]["reason"]), CharacterSaver.Reason.CRITICAL, "con el motivo 2")
	assert_eq(int(_saves()[0]["seq"]), 1, "seq 1")
	assert_eq(_saver.get_stats()["criticals_by_reason"], {"starter_kit": 1}, "el motivo, en las métricas")


## Una escritura en vuelo por personaje: lo marcado mientras vuela sale al llegar la respuesta, en el paso siguiente,
## con el seq siguiente; y el final espera detrás del que vuela, construido en el momento, sin rehacerse.
func test_one_write_in_flight_and_the_final_waits_behind_it() -> void:
	if not await _start(120):
		return
	_saver.track(5, 42, LEASE_A, 0)
	_platform.script_next(PlatformEvent.KIND_SAVE, 200, FakeZonePlatform.DEFAULT, 0.3)
	_saver.mark_critical(5, &"level_up")
	_step()
	_saver.mark_critical(5, &"gm")
	_step()
	_step()
	assert_eq(_section.builds.size(), 1, "uno en vuelo: el segundo crítico espera")
	await _pump_until(func() -> bool: return _section.acknowledged.size() == 1)
	assert_eq(_section.acknowledged, [[5, 1]], "el primero, confirmado")
	assert_eq(_saves().size(), 1, "el segundo no sale hasta el paso siguiente")
	_step()
	assert_eq(_saves().size(), 2, "sale en el paso siguiente")
	assert_eq(int(_saves()[1]["seq"]), 2, "con seq 2")
	await _pump_until(func() -> bool: return _section.acknowledged.size() == 2)
	_platform.script_next(PlatformEvent.KIND_SAVE, 200, FakeZonePlatform.DEFAULT, 0.3)
	_section.set_kills(5, 9)
	_saver.mark_critical(5, &"capture")
	_step()
	_section.set_kills(5, 10)
	_saver.finish(5, CharacterSaver.Reason.LOGOUT)
	assert_eq(_section.builds.size(), 4, "el final se construye en el momento")
	assert_eq(_saves().size(), 3, "pero espera detrás del que vuela")
	assert_eq(_saver.pending_count(), 2, "uno en vuelo y un final esperando")
	await _pump_until(func() -> bool: return _saves().size() == 4)
	var final: Dictionary = _saves()[3]
	assert_eq([int(final["seq"]), int(final["reason"]), final["release_lease"]], [4, CharacterSaver.Reason.LOGOUT, true],
			"el final: seq 4, motivo 3 y release_lease")
	assert_eq(int(final["pvp"]["kills"]), 10, "con la foto del momento de finish")
	assert_eq(_section.acknowledged, [[5, 1], [5, 2]], "tras finish, la respuesta del que volaba no confirma nada")
	await _pump_until(func() -> bool: return _saver.entry_count() == 0)
	assert_eq(_saver.pending_count(), 0, "nada pendiente")
	assert_eq(_releases().size(), 0, "el final libera: sin release aparte")
	assert_eq(_section.builds.size(), 4, "el final no se rehízo")


## El sobre entero de §7.3: ids en cadena (character_id > 2^53), zone_instance_id, lease_id, seq, reason,
## release_lease y la sección; los reintentos mandan el mismo cuerpo.
func test_the_envelope_and_the_same_body_on_retries() -> void:
	if not await _start(120):
		return
	_saver.track(5, BIG_CHARACTER_ID, LEASE_A, 0)
	_section.set_kills(5, 4)
	_platform.script_next(PlatformEvent.KIND_SAVE, 0, null)
	_platform.script_next(PlatformEvent.KIND_SAVE, 503, FakeZonePlatform.error_body("db_unavailable"))
	_saver.mark_critical(5, &"gm")
	_step()
	await _pump_until(func() -> bool: return _section.acknowledged.size() == 1)
	var saves: Array[Dictionary] = _saves()
	if not assert_eq(saves.size(), 3, "sin conexión y 503: dos reintentos"):
		return
	var body: Dictionary = saves[0]
	assert_eq(body.keys().size(), 8, "siete campos del sobre y la sección")
	assert_eq(int(body["save_format"]), 1, "save_format 1")
	assert_eq(body["character_id"], str(BIG_CHARACTER_ID), "character_id en cadena, exacto")
	assert_eq(body["zone_instance_id"], _platform.instance_id(), "zone_instance_id de la instancia")
	assert_eq(body["lease_id"], LEASE_A, "lease_id")
	assert_eq([int(body["seq"]), int(body["reason"]), body["release_lease"]], [1, 2, false], "seq, motivo y release")
	assert_eq(int(body["pvp"]["kills"]), 4, "la sección")
	assert_eq(JSON.stringify(saves[1]), JSON.stringify(body), "el primer reintento, el mismo cuerpo")
	assert_eq(JSON.stringify(saves[2]), JSON.stringify(body), "y el segundo")
	assert_eq(_section.builds.size(), 1, "construido una sola vez")


## Un 200 duplicate (un guardado que llegó y cuya respuesta se perdió) cuenta como aplicado.
func test_duplicate_counts_as_applied() -> void:
	if not await _start(120):
		return
	_saver.track(5, 42, LEASE_A, 0)
	_platform.script_next(PlatformEvent.KIND_SAVE, 200, {"applied": false, "duplicate": true, "save_version": 3,
			"instance_status": "live"})
	_saver.mark_critical(5, &"gm")
	_step()
	await _pump_until(func() -> bool: return not _section.acknowledged.is_empty())
	assert_eq(_section.acknowledged, [[5, 1]], "confirma el seq 1")
	assert_eq(_rejections.size(), 0, "sin expulsión")
	_saver.mark_critical(5, &"gm")
	_step()
	assert_eq(int(_saves().back()["seq"]), 2, "el siguiente lleva seq 2")
	assert_eq(_saver.get_stats()["duplicates"], 1, "contado como duplicado")


## Una sección que devuelve {}: el guardado no sale ni gasta seq; el crítico sigue marcado y el punto de control se
## intenta en el paso siguiente.
func test_a_section_that_cannot_build_defers_without_spending_seq() -> void:
	if not await _start(120):
		return
	_saver.track(5, 42, LEASE_A, 0)
	_section.unbuildable[5] = true
	_saver.mark_critical(5, &"gm")
	_step()
	_step()
	assert_eq(_saves().size(), 0, "no sale")
	assert_eq(_section.builds.size(), 2, "y se intenta en cada paso")
	_section.unbuildable.erase(5)
	_step()
	if assert_eq(_saves().size(), 1, "sale en cuanto se puede"):
		assert_eq(int(_saves()[0]["seq"]), 1, "con seq 1: los intentos fallidos no gastaron ninguno")
	await _pump_until(func() -> bool: return _section.acknowledged.size() == 1)
	_section.set_kills(5, 1)
	_section.unbuildable[5] = true
	while _tick < 42:
		_step()
	_section.unbuildable.erase(5)
	_step()
	assert_eq(_section.build_ticks(5), [3, 43], "el punto de control del 42, aplazado al 43")
	assert_eq(int(_saves().back()["seq"]), 2, "con seq 2")
	assert_eq(_saver.get_stats()["deferred"], 3, "tres aplazados")


## Un final que no se puede construir: alerta y release sin guardar (tras finish el estado ya no existe).
func test_a_final_that_cannot_be_built_releases_without_saving() -> void:
	if not await _start(120):
		return
	_saver.track(5, 42, LEASE_A, 0)
	_section.unbuildable[5] = true
	_saver.finish(5, CharacterSaver.Reason.LOGOUT)
	await _pump_ms(150)
	assert_eq(_saves().size(), 0, "sin guardado")
	assert_eq(_releases(), [{"zone_instance_id": _platform.instance_id(), "lease_id": LEASE_A}], "una liberación")
	assert_eq(_saver.entry_count(), 0, "la entrada se cierra")


## Sin secciones registradas (hasta progresion.md P5a) no hay nada que guardar: ni el punto de control ni el crítico
## mandan nada, y finish libera.
func test_without_sections_nothing_is_saved_and_finish_releases() -> void:
	if not await _start(120, false):
		return
	_saver.track(5, 42, LEASE_A, 0)
	_saver.mark_critical(5, &"gm")
	while _tick < 130:
		_step()
	assert_eq(_saves().size(), 0, "nada que guardar")
	_saver.finish(5, CharacterSaver.Reason.LOGOUT)
	await _pump_until(func() -> bool: return _releases().size() == 1)
	assert_eq(_releases(), [{"zone_instance_id": _platform.instance_id(), "lease_id": LEASE_A}], "finish libera")
	assert_eq(_saves().size(), 0, "sin guardar")


## Antes de finish, una respuesta definitiva (invalid_save, stale_seq, seq_conflict, un 403, un 413, un 404, un 409
## desconocido) emite save_rejected y la baja sin guardado libera una vez; lease_lost, sin liberar. Ninguna se
## reintenta.
func test_definitive_answers_before_finish_reject_and_drop() -> void:
	if not await _start(120):
		return
	var cases: Array = [
		[400, "invalid_save", true], [409, "stale_seq", true], [409, "seq_conflict", true], [403, "forbidden", true],
		[413, "too_large", true], [404, "not_found", true], [409, "whatever", true], [409, "lease_lost", false],
	]
	var net_id: int = 10
	for entry: Array in cases:
		net_id += 1
		var lease_id: String = "00000000-0000-4000-8000-%012d" % net_id
		var extra: Dictionary = {"fields": {"check": "S4", "detail": "ranura repetida"}} \
				if entry[1] == "invalid_save" else {}
		_platform.script_next(PlatformEvent.KIND_SAVE, entry[0], FakeZonePlatform.error_body(entry[1], "", extra))
		_saver.track(net_id, net_id + 100, lease_id, _tick)
		_saver.mark_critical(net_id, &"gm")
		var saves_before: int = _saves().size()
		var releases_before: int = _releases().size()
		_step()
		await _pump_until(func() -> bool: return _rejections.size() == net_id - 10)
		if not assert_eq(_rejections.back(), [net_id, net_id + 100, entry[1]], "%d %s → save_rejected" % [entry[0],
				entry[1]]):
			return
		await _pump_ms(120)
		assert_eq(_saves().size(), saves_before + 1, "%s no se reintenta" % entry[1])
		var released: Array = _releases().slice(releases_before)
		if entry[2]:
			assert_eq(released, [{"zone_instance_id": _platform.instance_id(), "lease_id": lease_id}],
					"%s: se libera una vez" % entry[1])
		else:
			assert_eq(released.size(), 0, "lease_lost: sin liberar")
		assert_false(_saver.is_tracked(net_id), "la entrada queda desatada")
	assert_eq(_saver.entry_count(), 0, "y cerrada")


## Si la zona no hace la baja al recibir save_rejected, CharacterSaver la hace solo: la entrada no queda atada.
func test_a_rejection_without_a_drop_still_detaches() -> void:
	if not await _start(120):
		return
	_drop_on_rejection = false
	_platform.script_next(PlatformEvent.KIND_SAVE, 400, FakeZonePlatform.error_body("invalid_save"))
	_saver.track(5, 42, LEASE_A, 0)
	_saver.mark_critical(5, &"gm")
	_step()
	await _pump_until(func() -> bool: return not _rejections.is_empty())
	assert_false(_saver.is_tracked(5), "desatada")
	await _pump_until(func() -> bool: return _releases().size() == 1)
	assert_eq(_releases().size(), 1, "y liberada")


## Un 409 instance_lost en un guardado (la plataforma lo dice con instance_status; si aun así llega) no culpa al
## jugador: el mismo cuerpo se reenvía; tras MAX_CLOSING_RESENDS, definitivo.
func test_a_closing_code_on_a_save_resends_the_same_body() -> void:
	if not await _start(120):
		return
	_platform.script_next(PlatformEvent.KIND_SAVE, 409, FakeZonePlatform.error_body("instance_lost"))
	_saver.track(5, 42, LEASE_A, 0)
	_section.set_kills(5, 2)
	_saver.mark_critical(5, &"gm")
	_step()
	await _pump_until(func() -> bool: return _section.acknowledged.size() == 1)
	assert_eq(_saves().size(), 2, "reenviado una vez")
	assert_eq(JSON.stringify(_saves()[1]), JSON.stringify(_saves()[0]), "el mismo cuerpo")
	assert_eq(_rejections.size(), 0, "sin expulsión")
	for _i: int in CharacterSaver.MAX_CLOSING_RESENDS + 1:
		_platform.script_next(PlatformEvent.KIND_SAVE, 409, FakeZonePlatform.error_body("instance_stopped"))
	_saver.mark_critical(5, &"gm")
	_step()
	await _pump_until(func() -> bool: return not _rejections.is_empty())
	assert_eq(_saves().size(), 2 + CharacterSaver.MAX_CLOSING_RESENDS + 1, "los reenvíos tienen tope")
	assert_eq(_rejections, [[5, 42, "instance_stopped"]], "y después es definitivo")


## Tras finish, la respuesta definitiva del que volaba solo se registra: el final que esperaba se descarta con él, se
## libera una vez y no hay save_rejected, ni acknowledge, ni is_dirty.
func test_after_finish_a_definitive_answer_only_logs_and_releases() -> void:
	if not await _start(120):
		return
	_saver.track(5, 42, LEASE_A, 0)
	_platform.script_next(PlatformEvent.KIND_SAVE, 400, FakeZonePlatform.error_body("invalid_save"), 0.2)
	_saver.mark_critical(5, &"gm")
	_step()
	_saver.finish(5, CharacterSaver.Reason.SHUTDOWN)
	var calls: int = _section.calls_for(5)
	for _i: int in 5:
		_step()
	await _pump_until(func() -> bool: return _releases().size() == 1)
	await _pump_ms(150)
	assert_eq(_rejections.size(), 0, "sin save_rejected tras finish")
	assert_eq(_saves().size(), 1, "el final se descarta con el que volaba")
	assert_eq(_releases(), [{"zone_instance_id": _platform.instance_id(), "lease_id": LEASE_A}], "una liberación")
	assert_eq(_section.calls_for(5), calls, "la sección no recibe nada más tras finish")
	assert_eq(_saver.entry_count(), 0, "entrada cerrada")


## Un net_id reutilizado con el final del anterior aún en vuelo: el cuerpo nuevo no recibe acknowledge ni
## save_rejected de la entrada vieja, y un invalid_save tardío del viejo solo se registra y libera el suyo.
func test_a_reused_net_id_does_not_get_the_old_answers() -> void:
	if not await _start(120):
		return
	_saver.track(5, 42, LEASE_A, 0)
	_platform.script_next(PlatformEvent.KIND_SAVE, 400, FakeZonePlatform.error_body("invalid_save"), 0.3)
	_saver.mark_critical(5, &"gm")
	_step()
	_saver.finish(5, CharacterSaver.Reason.LOGOUT)
	_saver.track(5, 43, LEASE_B, _tick)
	_saver.mark_critical(5, &"starter_kit")
	_step()
	assert_eq(_saves().size(), 2, "el cuerpo nuevo guarda en paralelo (otro arrendamiento)")
	assert_eq(String(_saves()[1]["lease_id"]), LEASE_B, "con su lease_id")
	assert_eq(int(_saves()[1]["seq"]), 1, "y su propio seq")
	await _pump_until(func() -> bool: return _releases().size() == 1)
	await _pump_ms(120)
	assert_eq(_rejections.size(), 0, "el nuevo no recibe el save_rejected del viejo")
	assert_eq(_section.acknowledged, [[5, 1]], "solo el acknowledge de su propio seq 1")
	assert_eq(_releases(), [{"zone_instance_id": _platform.instance_id(), "lease_id": LEASE_A}],
			"el viejo libera su arrendamiento")
	assert_true(_saver.is_tracked(5), "el nuevo sigue")
	assert_eq(_saver.lease_of(43), LEASE_B, "con su lease_id")


## El mismo personaje vuelve a esta instancia (otra reclamación) mientras su final, ya aplicado, se reintenta: la
## entrada vieja recibe lease_lost y solo se registra (sin liberar), y la nueva no se expulsa.
func test_the_same_character_back_while_its_applied_final_is_retried() -> void:
	if not await _start(120):
		return
	_saver.track(5, 42, LEASE_A, 0)
	# La plataforma aplica el final y libera, pero sus respuestas se pierden; el reintento llega tras la reclamación
	# nueva: lease_lost.
	_platform.script_next(PlatformEvent.KIND_SAVE, 0, null, 0.1)
	_platform.script_next(PlatformEvent.KIND_SAVE, 0, null, 0.1)
	_platform.script_next(PlatformEvent.KIND_SAVE, 409, FakeZonePlatform.error_body("lease_lost"), 0.3)
	_saver.finish(5, CharacterSaver.Reason.LOGOUT)
	_saver.track(8, 42, LEASE_B, _tick)
	assert_eq(_saver.lease_of(42), LEASE_B, "el índice del personaje apunta a la reclamación nueva")
	await _pump_until(func() -> bool: return _saves().size() == 3)
	await _pump_until(func() -> bool: return _saver.entry_count() == 1)
	assert_eq(_rejections.size(), 0, "nadie recibe save_rejected")
	assert_eq(_releases().size(), 0, "lease_lost no libera")
	assert_true(_saver.is_tracked(8), "la entrada nueva sigue")
	_section.set_kills(8, 1)
	_saver.mark_critical(8, &"gm")
	_step()
	await _pump_until(func() -> bool: return not _section.acknowledged.is_empty())
	assert_eq(_section.acknowledged, [[8, 1]], "y guarda con su seq 1")
	assert_eq(String(_saves().back()["lease_id"]), LEASE_B, "con su arrendamiento")
