extends RefCounted
## Banco de capturas de calidad (TEC-50): lista de tiras de personajes vistos desde el cliente de captura.
##
## Cada tira ([method add]) tiene un id (nombre de archivo), una condición sobre las muestras de la grabadora
## ([code]cond(actual, anterior) -> bool[/code], normalmente un borde de subida de la acción: «ahora BLOCK, antes no»), cuántos
## fotogramas lleva, cada cuántos milisegundos y cuánto de antes del disparo. [method evaluate], una vez por fotograma,
## lanza la tira cuyo disparo se da en el personaje seguido y, cuando la grabadora ya tiene lo que sigue al disparo, la
## saca del anillo y la escribe ([method StripRecorder.save_strip]).
## [br][br]
## Una tira puede llevar una validación ([code]validate(metas, info) -> bool[/code]) que comprueba que lo grabado es lo que
## dice el título (por ejemplo, que un «ataque ligero» no se convirtió en carga a mitad de la toma y que el arma es la
## espada): si no la cumple se descarta y se espera otra toma. Una tira en la que otro cuerpo tapa al seguido en más de
## un tercio de los fotogramas se repite hasta [constant MAX_ATTEMPTS] veces antes de darla por buena (el aviso va en su
## nota y en el índice).

const MAX_ATTEMPTS: int = 3
## Tras descartar una toma de una tira, esperas (ms) antes de volver a dispararla: las condiciones de «andar» o «correr» se
## cumplen casi siempre y, sin pausa, una toma rechazada tras otra dejaría sin ventana a las demás tiras.
const REJECT_COOLDOWN_MS: int = 4000

var specs: Array[Dictionary] = []
## id -> true de las tiras guardadas.
var done: Dictionary = {}
## id -> intentos descartados por tapadas o por anillo corto.
var attempts: Dictionary = {}
## id -> tomas descartadas por no cumplir su validación.
var rejected: Dictionary = {}
## Cuántas tiras se han guardado con fotogramas tapados (tras agotar los intentos).
var saved_occluded: int = 0

var _d: Variant
var _rec: Variant
var _pending: Dictionary = {}
var _last_eval_ms: int = -1
# id -> instante (ms) hasta el que no se vuelve a disparar.
var _cooldown: Dictionary = {}


func _init(driver: Variant, recorder: Variant) -> void:
	_d = driver
	_rec = recorder


## Disparo: borde de subida de la acción, «ahora una de [param names] y antes ninguna».
static func edge(names: Array) -> Callable:
	return func(cur: Dictionary, prev: Dictionary) -> bool:
		return names.has(cur["action"]) and not names.has(prev["action"])


## Validación: al menos [param min_frames] fotogramas con alguna de las acciones [param wanted], ninguno con las de
## [param forbidden], y el arma [param weapon] (vacía = cualquiera).
static func has_action(wanted: Array, min_frames: int, forbidden: Array = [], weapon: String = "") -> Callable:
	return func(metas: Array, info: Dictionary) -> bool:
		if not weapon.is_empty() and String(info.get("weapon", "")) != weapon:
			return false
		var count: int = 0
		for m: Dictionary in metas:
			if forbidden.has(m["action"]):
				return false
			if wanted.has(m["action"]):
				count += 1
		return count >= min_frames


## Añade una tira. [param target_key] dice a qué tipo de personaje se aplica (el escenario pasa el suyo a
## [method evaluate]); [param cond] recibe la muestra actual y la anterior (sus [code]meta[/code]); [param validate]
## (opcional) recibe las [code]meta[/code] de todos los fotogramas y los datos del seguido ([method StripRecorder.target_info]).
## Con [param one_shot] (muertes y derribos: no se pueden repetir a voluntad) una toma con fotogramas tapados se guarda igualmente.
func add(id: String, title: String, target_key: String, cond: Callable, count: int = 12, interval_ms: int = 100,
		pre_ms: int = 150, desc: String = "", validate: Callable = Callable(), one_shot: bool = false) -> void:
	specs.append({"id": id, "title": title, "target": target_key, "cond": cond, "n": count,
			"interval": interval_ms, "pre": pre_ms, "desc": desc, "validate": validate, "one_shot": one_shot})


func is_done(id: String) -> bool:
	return done.has(id)


## Ids de las tiras que aún faltan (de todos los objetivos, o solo de [param target_key]).
func missing(target_key: String = "") -> PackedStringArray:
	var out := PackedStringArray()
	for spec: Dictionary in specs:
		if done.has(spec["id"]):
			continue
		if not target_key.is_empty() and spec["target"] != target_key:
			continue
		out.append(String(spec["id"]))
	return out


func all_done(target_key: String = "") -> bool:
	return missing(target_key).is_empty()


func is_recording() -> bool:
	return not _pending.is_empty()


## Descarta la tira en curso (se cambió de personaje seguido, murió o se perdió).
func cancel() -> void:
	_pending.clear()
	_last_eval_ms = -1


## Una vez por fotograma, tras [code]d.step()[/code]. [param target_key] es el tipo del personaje que sigue la grabadora.
func evaluate(target_key: String) -> void:
	var ms: int = _rec.last_sample_ms()
	if ms < 0 or ms == _last_eval_ms:
		return
	_last_eval_ms = ms
	if not _pending.is_empty():
		var spec: Dictionary = _pending["spec"]
		var due_ms: int = int(_pending["trigger_ms"]) - int(spec["pre"]) + (int(spec["n"]) - 1) * int(spec["interval"]) \
				+ _rec.SAMPLE_MS
		if ms >= due_ms:
			_finish()
		return
	var current: Dictionary = _rec.last_meta()
	var previous: Dictionary = _rec.previous_meta()
	if previous.is_empty():
		return
	for spec: Dictionary in specs:
		if done.has(spec["id"]) or spec["target"] != target_key:
			continue
		if int(_cooldown.get(spec["id"], 0)) > ms:
			continue
		if (spec["cond"] as Callable).call(current, previous):
			_pending = {"spec": spec, "trigger_ms": int(current["ms"])}
			return


## Dispara una tira a mano (para los disparos que no salen de la muestra, como un golpe bloqueado): la toma cuenta como
## si su condición se hubiera dado en [param trigger_ms].
func trigger(id: String, trigger_ms: int) -> void:
	if not _pending.is_empty() or done.has(id):
		return
	for spec: Dictionary in specs:
		if spec["id"] == id:
			_pending = {"spec": spec, "trigger_ms": trigger_ms}
			return


func _finish() -> void:
	var spec: Dictionary = _pending["spec"]
	var trigger_ms: int = int(_pending["trigger_ms"])
	_pending.clear()
	var id: String = String(spec["id"])
	var frames: Array[Dictionary] = _rec.extract(trigger_ms, int(spec["pre"]), int(spec["interval"]), int(spec["n"]))
	if frames.size() < int(spec["n"]):
		_d.note("tira %s: el anillo no llegaba al principio, se descarta" % id)
		attempts[id] = int(attempts.get(id, 0)) + 1
		return
	var occluded: int = 0
	var max_neighbors: int = 0
	var metas: Array = []
	for f: Dictionary in frames:
		var m: Dictionary = f["meta"]
		metas.append(m)
		if bool(m.get("occluded", false)):
			occluded += 1
		max_neighbors = maxi(max_neighbors, int(m.get("neighbors", 0)))
	var info: Dictionary = _rec.target_info()
	var validate: Callable = spec["validate"]
	if validate.is_valid() and not bool(validate.call(metas, info)):
		rejected[id] = int(rejected.get(id, 0)) + 1
		_cooldown[id] = Time.get_ticks_msec() + REJECT_COOLDOWN_MS
		return
	var tries: int = int(attempts.get(id, 0))
	if occluded * 3 > frames.size() and tries + 1 < MAX_ATTEMPTS and not bool(spec.get("one_shot", false)):
		attempts[id] = tries + 1
		_d.note("tira %s: %d de %d fotogramas con el personaje tapado, se repite (intento %d)" % [id, occluded, frames.size(), tries + 1])
		return
	var note_text: String = "aislado: solo el cliente de captura a menos de 4 m" if max_neighbors <= 1 \
			else "%d cuerpos a menos de 4 m del seguido" % max_neighbors
	if occluded > 0:
		note_text += "; %d de %d fotogramas con otro cuerpo delante" % [occluded, frames.size()]
		if occluded * 3 > frames.size():
			saved_occluded += 1
	var extra: Dictionary = {"desc": String(spec["desc"]), "weapon": String(info.get("weapon", "")), "target": info}
	_rec.save_strip(_d.raw_dir, id, String(spec["title"]), frames, note_text, extra)
	done[id] = true
	_d.note("tira %s guardada sobre %s (clips de la capa: %s)" % [id, info.get("name", "el jugador local"),
			_clips_of(frames)])


func _clips_of(frames: Array[Dictionary]) -> String:
	var clips: Dictionary = {}
	for f: Dictionary in frames:
		var clip: String = String((f["meta"] as Dictionary).get("clip", ""))
		if not clip.is_empty():
			clips[clip.get_file()] = true
	return ", ".join(clips.keys()) if not clips.is_empty() else "ninguno"
