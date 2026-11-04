extends RefCounted
## Quality capture bench (TEC-50): list of strips of characters seen from the capture client.
##
## Each strip ([method add]) has an id (file name), a condition on the recorder's samples
## ([code]cond(current, previous) -> bool[/code], normally a rising edge of the action: "now BLOCK, before not"), how many
## frames it has, every how many milliseconds and how much before the trigger. [method evaluate], once per frame,
## launches the strip whose trigger occurs on the followed character and, when the recorder already has what follows the trigger,
## pulls it out of the ring and writes it ([method StripRecorder.save_strip]).
## [br][br]
## A strip can carry a validation ([code]validate(metas, info) -> bool[/code]) that checks that what was recorded is what the
## title says (for example, that a "light attack" did not turn into a charge halfway through the take and that the weapon is the
## sword): if it fails it is discarded and another take is awaited. A strip in which another body blocks the followed one in more than
## a third of the frames is repeated up to [constant MAX_ATTEMPTS] times before accepting it (the warning goes in its
## note and in the index).

const MAX_ATTEMPTS: int = 3
## After discarding a take of a strip, wait (ms) before triggering it again: the "walk" or "run" conditions
## are almost always met and, without a pause, one rejected take after another would leave no window for the other strips.
const REJECT_COOLDOWN_MS: int = 4000

var specs: Array[Dictionary] = []
## id -> true for the strips already saved.
var done: Dictionary = {}
## id -> attempts discarded because of occlusion or a short ring.
var attempts: Dictionary = {}
## id -> takes discarded for failing their validation.
var rejected: Dictionary = {}
## How many strips have been saved with occluded frames (after running out of attempts).
var saved_occluded: int = 0

var _d: Variant
var _rec: Variant
var _pending: Dictionary = {}
var _last_eval_ms: int = -1
# id -> time (ms) until which it is not triggered again.
var _cooldown: Dictionary = {}


func _init(driver: Variant, recorder: Variant) -> void:
	_d = driver
	_rec = recorder


## Trigger: rising edge of the action, "now one of [param names] and before none".
static func edge(names: Array) -> Callable:
	return func(cur: Dictionary, prev: Dictionary) -> bool:
		return names.has(cur["action"]) and not names.has(prev["action"])


## Validation: at least [param min_frames] frames with any of the actions [param wanted], none with those in
## [param forbidden], and the weapon [param weapon] (empty = any).
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


## Adds a strip. [param target_key] says which type of character it applies to (the scenario passes its own to
## [method evaluate]); [param cond] receives the current and the previous sample (their [code]meta[/code]); [param validate]
## (optional) receives the [code]meta[/code] of all the frames and the data of the followed one ([method StripRecorder.target_info]).
## With [param one_shot] (deaths and knockdowns: they cannot be repeated at will) a take with occluded frames is saved anyway.
func add(id: String, title: String, target_key: String, cond: Callable, count: int = 12, interval_ms: int = 100,
		pre_ms: int = 150, desc: String = "", validate: Callable = Callable(), one_shot: bool = false) -> void:
	specs.append({"id": id, "title": title, "target": target_key, "cond": cond, "n": count,
			"interval": interval_ms, "pre": pre_ms, "desc": desc, "validate": validate, "one_shot": one_shot})


func is_done(id: String) -> bool:
	return done.has(id)


## Ids of the strips still missing (of all the targets, or only of [param target_key]).
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


## Discards the strip in progress (the followed character changed, died or was lost).
func cancel() -> void:
	_pending.clear()
	_last_eval_ms = -1


## Once per frame, after [code]d.step()[/code]. [param target_key] is the type of the character the recorder follows.
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


## Triggers a strip by hand (for triggers that do not come from the sample, such as a blocked hit): the take counts as
## if its condition had occurred at [param trigger_ms].
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
