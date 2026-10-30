class_name PlatformClient
extends Node
## El cliente HTTP de la zona contra la API interna de la plataforma (docs/plataforma.md §6), dentro de
## [ZonePlatform]: [HTTPRequest] sin hilos, plazo de [member timeout_s] por intento, colas por prioridad y los
## reintentos de cada clase de petición. Nunca espera de forma síncrona: avanza con el bucle principal.
## [br][br]
## [codeblock]
## prioridad   peticiones                                      reintento
## 0 control   registro, live, GET de fortalezas, primer       registro, live, GET y primer bloque: 1, 2, 4…
##             bloque, latido, baja                            s hasta 60 s (STARTUP); latido y baja: no
## 1 entrada   reclamación, liberación                         reclamación: no; liberación: como un guardado
## 2 jugador   guardados, bloques, operación y libro,           guardados y bloques: el mismo cuerpo a 1, 2, 4,
##             reportes, ignorados, sanciones                  8 y 15 s, luego cada 15 s (STEADY); el resto, no
## 3 fortaleza PUT de fortaleza                                cada 2 s (FORTRESS)
## 4 lotes     chat, auditoría, guerra                         2, 4, 8 y 16 s, luego cada 30 s (BATCH)
## [/codeblock]
## [b]Plazas:[/b] una propia para la prioridad 0 y [constant SHARED_SLOTS] compartidas. Las prioridades 2 a 4
## ocupan [constant MAX_LOW_PRIORITY_IN_FLIGHT] como mucho a la vez, así que siempre quedan dos para la 1: un
## latido no espera detrás de los guardados lentos y una reclamación sale aunque haya cuatro en vuelo. Al quedar
## libre una plaza sale la petición de prioridad más alta; dentro de cada prioridad, por orden de llegada (una
## que espera su reintento no frena a las de detrás).
## [br][br]
## [b]Reintentos:[/b] un intento sin respuesta (sin conexión o plazo vencido), un 5xx o un 401 se repiten con
## los mismos bytes según su clase; cualquier otra respuesta es definitiva y va a [member Request.on_done]. Un
## plazo vencido no es una respuesta: un guardado sigue siendo el mismo cuerpo hasta tener una definitiva (§7.3).
## [br][br]
## El transporte de un intento es [method _perform]: el de esta clase usa [HTTPRequest] y el del falso de las
## pruebas ([code]tests/fake_zone_platform.gd[/code]) contesta sin red, con todo lo demás igual.

## Clases de reintento.
enum Retry { NONE, STARTUP, STEADY, BATCH, FORTRESS }

const PRIORITY_CONTROL: int = 0
const PRIORITY_ENTRY: int = 1
const PRIORITY_PLAYER: int = 2
const PRIORITY_FORTRESS: int = 3
const PRIORITY_BATCH: int = 4
const PRIORITY_COUNT: int = 5
## Plazas compartidas (más la propia de la prioridad 0).
const SHARED_SLOTS: int = 6
## Peticiones de prioridad 2 a 4 en vuelo a la vez, como mucho.
const MAX_LOW_PRIORITY_IN_FLIGHT: int = 4
## Esperas (s) antes de cada reintento de las clases STEADY y BATCH; la última se repite.
const STEADY_DELAYS_S: Array[float] = [1.0, 2.0, 4.0, 8.0, 15.0]
const BATCH_DELAYS_S: Array[float] = [2.0, 4.0, 8.0, 16.0, 30.0]
## Primera espera de STARTUP (se dobla en cada intento) y espera de FORTRESS.
const STARTUP_FIRST_DELAY_S: float = 1.0
const FORTRESS_DELAY_S: float = 2.0
## Tope de un cuerpo de respuesta (la API interna no pasa de 1 MB, §6).
const MAX_RESPONSE_BYTES: int = 2 * 1024 * 1024


## Una petición: los bytes que se mandan no cambian entre intentos.
class Request:
	extends RefCounted
	var method: HTTPClient.Method = HTTPClient.METHOD_GET
	## Ruta con su consulta, sin la base ([code]/internal/v1/claims[/code]).
	var path: String = ""
	var body: PackedByteArray = PackedByteArray()
	var priority: int = PRIORITY_PLAYER
	## Clase de la petición (el kind del [PlatformEvent] si sale como evento).
	var kind: StringName = &""
	var context: Variant = null
	var retry: int = Retry.NONE
	## Se llama con (esta petición, [PlatformEvent]) cuando hay una respuesta definitiva o no quedan intentos.
	var on_done: Callable = Callable()
	## Intentos hechos.
	var attempts: int = 0
	## No sale antes de este instante (ms de [method Time.get_ticks_msec]).
	var not_before_msec: int = 0
	## STARTUP: no se reintenta después de este instante (ms); -1 = sin límite.
	var deadline_msec: int = -1
	## Orden de llegada.
	var seq: int = 0
	## Plaza en la que vuela (-1 = en cola).
	var slot: int = -1


## Base de las rutas ([code]http://127.0.0.1:24681[/code], sin barra al final).
var base_url: String = ""
## Token de la zona ([code]Authorization: Bearer[/code]).
var token: String = ""
## Plazo de cada intento (s).
var timeout_s: float = 3.0
## Escala de las esperas entre reintentos (1 = las de la tabla; las pruebas la bajan).
var retry_scale: float = 1.0

var _queues: Array[Array] = []
## Plaza 0: la propia del control; 1..SHARED_SLOTS: compartidas.
var _slots: Array[Request] = []
var _http: Array[HTTPRequest] = []
var _seq: int = 0
var _sent_attempts: int = 0


func _init() -> void:
	for _i: int in PRIORITY_COUNT:
		_queues.append([])
	_slots.resize(SHARED_SLOTS + 1)
	_http.resize(SHARED_SLOTS + 1)


func _process(_delta: float) -> void:
	pump()


## Encola [param request] y la manda en cuanto haya plaza (puede salir ya, dentro de esta llamada).
func submit(request: Request) -> void:
	_seq += 1
	request.seq = _seq
	request.slot = -1
	_queues[clampi(request.priority, 0, PRIORITY_COUNT - 1)].append(request)
	pump()


## Peticiones en cola o en vuelo; sin contar las de la clase [param excluded_kind] si se da.
func pending_count(excluded_kind: StringName = &"") -> int:
	var count: int = 0
	for queue: Array in _queues:
		for request: Request in queue:
			if request.kind != excluded_kind:
				count += 1
	for request: Request in _slots:
		if request != null and request.kind != excluded_kind:
			count += 1
	return count


## Peticiones en vuelo ahora mismo.
func in_flight_count() -> int:
	var count: int = 0
	for request: Request in _slots:
		if request != null:
			count += 1
	return count


## Intentos mandados desde que existe (métricas y pruebas).
func get_sent_attempts() -> int:
	return _sent_attempts


## Todo lo que espera su reintento sale ya (el cierre ordenado, [method ZonePlatform.begin_flush]).
func hurry() -> void:
	for queue: Array in _queues:
		for request: Request in queue:
			request.not_before_msec = 0
	pump()


## Saca de las colas lo que se puede mandar ya y lo pone en las plazas libres.
func pump() -> void:
	var now: int = Time.get_ticks_msec()
	for slot: int in _slots.size():
		if _slots[slot] != null:
			continue
		var request: Request = _take_next(slot, now)
		if request == null:
			continue
		_start(slot, request)


# La siguiente petición para la plaza [param slot]: la propia (0) solo lleva control; las compartidas, la de
# prioridad más alta que esté lista, con el tope de las prioridades 2 a 4.
func _take_next(slot: int, now: int) -> Request:
	var low_in_flight: int = 0
	for flying: Request in _slots:
		if flying != null and flying.priority >= PRIORITY_PLAYER:
			low_in_flight += 1
	var last_priority: int = PRIORITY_CONTROL if slot == 0 else PRIORITY_COUNT - 1
	for priority: int in range(0, last_priority + 1):
		if priority >= PRIORITY_PLAYER and low_in_flight >= MAX_LOW_PRIORITY_IN_FLIGHT:
			return null
		var queue: Array = _queues[priority]
		for i: int in queue.size():
			var request: Request = queue[i]
			if request.not_before_msec <= now:
				queue.remove_at(i)
				return request
	return null


func _start(slot: int, request: Request) -> void:
	_slots[slot] = request
	request.slot = slot
	request.attempts += 1
	_sent_attempts += 1
	_perform(request)


## El transporte de un intento: tiene que acabar llamando a [method _complete] con [param request] (nunca
## dentro de esta misma llamada). Este usa un [HTTPRequest] por plaza.
func _perform(request: Request) -> void:
	var http: HTTPRequest = _http[request.slot]
	if http == null:
		http = HTTPRequest.new()
		http.name = "Slot%d" % request.slot
		http.use_threads = false
		http.accept_gzip = false
		http.body_size_limit = MAX_RESPONSE_BYTES
		add_child(http)
		http.request_completed.connect(_on_http_completed.bind(request.slot))
		_http[request.slot] = http
	http.timeout = timeout_s
	var headers := PackedStringArray(["Authorization: Bearer %s" % token, "Accept: application/json"])
	if not request.body.is_empty():
		headers.append("Content-Type: application/json")
	var error: Error = http.request_raw(base_url + request.path, headers, request.method, request.body)
	if error != OK:
		# No ha salido (URL mala, sin árbol…): cuenta como un intento sin respuesta.
		_complete.call_deferred(request, false, 0, PackedByteArray())


func _on_http_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray,
		slot: int) -> void:
	var request: Request = _slots[slot]
	if request == null:
		return
	_complete(request, result == HTTPRequest.RESULT_SUCCESS, response_code, body)


## Fin de un intento: la respuesta definitiva va a [member Request.on_done]; si no, se vuelve a encolar con su
## espera (los mismos bytes).
func _complete(request: Request, transport_ok: bool, status: int, raw: PackedByteArray) -> void:
	if request.slot < 0 or request.slot >= _slots.size() or _slots[request.slot] != request:
		return
	_slots[request.slot] = null
	request.slot = -1
	var event: PlatformEvent = PlatformEvent.from_response(request.kind, request.context, transport_ok, status,
			raw)
	var now: int = Time.get_ticks_msec()
	var delay_s: float = _retry_delay_s(request, event, now)
	if delay_s >= 0.0:
		request.not_before_msec = now + int(delay_s * retry_scale * 1000.0)
		_requeue(request)
	elif request.on_done.is_valid():
		request.on_done.call(request, event)
	pump()


# Espera (s) antes de reintentar, o -1 si la respuesta es definitiva o no quedan intentos.
func _retry_delay_s(request: Request, event: PlatformEvent, now: int) -> float:
	if not is_retryable(event):
		return -1.0
	var index: int = request.attempts - 1
	match request.retry:
		Retry.STARTUP:
			var delay: float = STARTUP_FIRST_DELAY_S * pow(2.0, float(mini(index, 10)))
			if request.deadline_msec >= 0 and now + int(delay * retry_scale * 1000.0) > request.deadline_msec:
				return -1.0
			return delay
		Retry.STEADY:
			return STEADY_DELAYS_S[mini(index, STEADY_DELAYS_S.size() - 1)]
		Retry.BATCH:
			return BATCH_DELAYS_S[mini(index, BATCH_DELAYS_S.size() - 1)]
		Retry.FORTRESS:
			return FORTRESS_DELAY_S
	return -1.0


## true si [param event] no es una respuesta definitiva: sin respuesta, un 5xx o un 401 (§7.3).
static func is_retryable(event: PlatformEvent) -> bool:
	return not event.transport_ok or event.status >= 500 or event.status == 401


# Vuelve a la cola de su prioridad en su orden de llegada (es más vieja que las que llegaron después).
func _requeue(request: Request) -> void:
	var queue: Array = _queues[clampi(request.priority, 0, PRIORITY_COUNT - 1)]
	var index: int = queue.size()
	for i: int in queue.size():
		if (queue[i] as Request).seq > request.seq:
			index = i
			break
	queue.insert(index, request)
