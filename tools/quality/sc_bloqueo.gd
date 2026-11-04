extends RefCounted
## Quality capture bench (TEC-50), combat area: hit received while blocking.
##
## The server runs as in [code]sc_remotos_bot.gd[/code] (no NPCs, with a single enemy combat bot). The capture client
## stays in front of the bot with the shield up and without attacking ([code]spar.gd[/code], [code]tank[/code] mode). Every time
## the client sees a blocked hit ([code]damage_taken[/code] with the block flag, already timed for
## drawing) the recorder pulls the character's own strip out of the ring, with the start of the hit: the game camera and a
## side camera of its own. The game has no clip of its own for taking a hit with the shield: what this strip shows is
## what a player sees today (and what ART-48 will have to change). The [code]meta.json[/code] carries per frame the
## [code]hit[/code] flag (BLOQUEADO "blocked", PARADA "parried", GOLPE "hit") of the hits that fell in its interval.

const Recorder = preload("res://tools/quality/strip_recorder.gd")
const Spar = preload("res://tools/quality/spar.gd")
const Specs = preload("res://tools/quality/strip_specs.gd")

const MEET_YAW: float = 180.0
const TIMEOUT_MS: int = 150000
## Blocked-hit takes that are saved, with their id.
const STRIP_IDS: Array[String] = ["com_bloqueo_recibir_golpe", "com_bloqueo_recibir_golpe_2", "com_bloqueo_recibir_golpe_3"]

var d: Variant
var rec: Variant
var spar: Variant
var specs: Variant
var _meet: Vector2 = Vector2(0.0, 105.0)
var _seen_ms: int = 0
var _next_strip: int = 0


func run(drv: Variant) -> void:
	d = drv
	if not await d.enter_world():
		return
	rec = Recorder.new(d)
	d.recorder = rec
	spar = Spar.new(d, 17)
	spar.set_mode("tank")
	specs = Specs.new(d, rec)
	for i: int in STRIP_IDS.size():
		var suffix: String = "" if i == 0 else " (toma %d)" % (i + 1)
		specs.add(STRIP_IDS[i], "Golpe recibido en bloqueo%s" % suffix, "local",
				func(_cur: Dictionary, _prev: Dictionary) -> bool: return false,
				12, 50, 150, "El jugador con el escudo arriba recibiendo el golpe de un bot.",
				Specs.has_action(["BLOCK"], 8))
	var t_end: int = Time.get_ticks_msec() + TIMEOUT_MS
	_meet = d.open_spot(Spar.MEET_CANDIDATES)
	await d.tp(_meet.x, _meet.y, MEET_YAW, 6.0, NAN, 1.0)
	_seen_ms = Time.get_ticks_msec()
	while Time.get_ticks_msec() < t_end and _next_strip < STRIP_IDS.size():
		await d.ensure_alive()
		var enemy: Dictionary = d.nearest_enemy(60.0)
		if enemy.is_empty():
			spar.stop()
			specs.cancel()
			d.note("sin bot a la vista: vuelta al punto de encuentro")
			await d.tp(_meet.x, _meet.y, MEET_YAW, 6.0, NAN, 1.0)
			await d.wait_healing(5.0)
			continue
		await _tank_against(enemy["view"], t_end)
	spar.stop()
	d.release_all()
	rec.clear()
	d.note("tiras de golpe bloqueado guardadas: %s" % [specs.done.keys()])


func _tank_against(view: Object, t_end: int) -> void:
	rec.follow_local()
	specs.cancel()
	var next_heal: int = 0
	while is_instance_valid(view) and Time.get_ticks_msec() < t_end and _next_strip < STRIP_IDS.size():
		var now: int = Time.get_ticks_msec()
		if now >= next_heal:
			d.heal()
			next_heal = now + 300
		if d.client.is_dead() or d.client.is_downed():
			break
		spar.step(view.get_drawn_position())
		await d.step()
		_watch_blocked_hits()
		specs.evaluate("local")
		if specs.is_done(STRIP_IDS[_next_strip]):
			_next_strip += 1
	spar.stop()


# A new blocked hit triggers the next strip (if none is in progress).
func _watch_blocked_hits() -> void:
	for e: Dictionary in d.hit_events:
		if int(e["ms"]) <= _seen_ms:
			continue
		_seen_ms = int(e["ms"])
		if String(e["kind"]) != "taken" or not (bool(e["blocked"]) or bool(e["parried"])):
			continue
		if _next_strip < STRIP_IDS.size() and not specs.is_recording():
			specs.trigger(STRIP_IDS[_next_strip], int(e["ms"]))
