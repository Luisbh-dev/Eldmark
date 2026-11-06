extends RefCounted
## Quality capture bench (TEC-50), video: one minute of combat with the engine's Movie Maker mode.
##
## Meant to be launched with [code]--write-movie <file.avi>[/code] (which [code]run.py video[/code] does): the engine records each
## frame and the master bus audio, so it is useful to judge what captures do not show: sound, hitstop and
## smoothness. The driver throttles the game to real time while recording ([code]online_driver.gd[/code]), so that the server
## and the client stay in sync.
## [br][br]
## Script (by frames, so it lasts the same recorded or not): the first 45 % in the fort courtyard against the Hollow and
## the Captain (debug command 8 so that all of them are there, and again when they are all down), alternating fighting
## and shield-up stretches (block sparks), and the rest against an enemy combat bot, in front of its camp.
## The client fights with [code]spar.gd[/code] (light attacks, abilities, dodge, block and heavy attacks). Duration with
## [code]--seconds=N[/code] (60 by default).

const Spar = preload("res://tools/quality/spar.gd")

const FPS: int = 60
## Open spots of the fort courtyard (the closed gate does not let anyone pass on foot): the client appears inside, near the
## Captain and the Hollow; [method online_driver.open_spot] picks the one with the fewest obstacles around.
const FORT_SPOTS: Array = [Vector2(-12.0, -6.0), Vector2(-12.0, 6.0), Vector2(-14.0, 0.0), Vector2(8.0, -14.0), Vector2(8.0, 14.0)]
## Parts of the first (fort) stretch, as fractions of the video: [start, end, mode]. "tank" holds the shield up to
## show block sparks; the others fight (light attacks, abilities, dodge, block, heavy attacks).
const FORT_PLAN: Array = [[0.0, 0.14, "fight"], [0.14, 0.24, "tank"], [0.24, 0.36, "fight"], [0.36, 0.45, "tank"]]

var d: Variant
var spar: Variant
var _bot_spot: Vector2 = Vector2(0.0, 105.0)
var _fort_spot: Vector2 = Vector2(-12.0, -6.0)
var _seconds: int = 60
var _start_frame: int = 0


func run(drv: Variant) -> void:
	d = drv
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--seconds="):
			_seconds = clampi(int(arg.trim_prefix("--seconds=")), 10, 600)
	if not await d.enter_world():
		return
	spar = Spar.new(d, 21)
	spar.look_offset_deg = 0.0
	_bot_spot = d.open_spot(Spar.MEET_CANDIDATES)
	# Fort full of NPCs and the client at the gate.
	d.cmd(NetProtocol.DEBUG_FORT_RESET)
	await d.wait_healing(3.0)
	_fort_spot = d.open_spot(FORT_SPOTS)
	await d.tp(_fort_spot.x, _fort_spot.y, d.yaw_to(_fort_spot.x, _fort_spot.y, 0.0, 0.0), 5.0, NAN, 1.0)
	_start_frame = Engine.get_process_frames()
	d.note("vídeo: %d s (%d fotogramas a %d por segundo)" % [_seconds, _seconds * FPS, FPS])
	await _fight_until(0.45, "npc")
	await d.ensure_alive()
	await d.tp(_bot_spot.x, _bot_spot.y, 180.0, 6.0, NAN, 1.0)
	await _fight_until(1.0, "player")
	spar.stop()
	d.release_all()
	d.note("vídeo: fin del guion tras %d fotogramas" % (Engine.get_process_frames() - _start_frame))


func _elapsed_fraction() -> float:
	return float(Engine.get_process_frames() - _start_frame) / float(_seconds * FPS)


# Fights the nearest enemy of the requested kind until the fraction [param until] of the video has passed.
func _fight_until(until: float, wanted_kind: String) -> void:
	var kind: String = wanted_kind
	var next_heal: int = 0
	var no_rival_since: int = 0
	spar.set_mode("fight")
	var heavy_next: int = Time.get_ticks_msec() + 6000
	var next_reset: int = 0
	while _elapsed_fraction() < until:
		var now: int = Time.get_ticks_msec()
		if now >= next_heal:
			d.heal()
			next_heal = now + 300
		if d.client.is_dead() or d.client.is_downed():
			spar.stop()
			await d.ensure_alive()
			if kind == "npc":
				await d.tp(_fort_spot.x, _fort_spot.y, d.yaw_to(_fort_spot.x, _fort_spot.y, 0.0, 0.0), 5.0, NAN, 0.6)
			else:
				await d.tp(_bot_spot.x, _bot_spot.y, 180.0, 6.0, NAN, 0.6)
		var enemy: Dictionary = _nearest(kind)
		if enemy.is_empty() and kind == "player":
			# The sparring bot did not show up (or left): go back to the fort instead of standing still.
			if no_rival_since == 0:
				no_rival_since = now
			elif now - no_rival_since > 3000:
				kind = "npc"
				no_rival_since = 0
				d.note("vídeo: sin rival humano, se vuelve al fuerte")
				await d.tp(_fort_spot.x, _fort_spot.y, d.yaw_to(_fort_spot.x, _fort_spot.y, 0.0, 0.0), 5.0, NAN, 0.6)
				continue
		elif not enemy.is_empty():
			no_rival_since = 0
		if enemy.is_empty():
			spar.stop()
			if kind == "npc" and now >= next_reset:
				# Everyone in the fort is down: it is reset so that the Hollow and the Captain come back.
				next_reset = now + 6000
				d.cmd(NetProtocol.DEBUG_FORT_RESET)
				await d.wait_healing(2.5)
				await d.tp(_fort_spot.x, _fort_spot.y, d.yaw_to(_fort_spot.x, _fort_spot.y, 0.0, 0.0), 5.0, NAN, 0.4)
			await d.step()
			continue
		if kind == "npc" and _plan_mode() == "tank":
			spar.set_mode("tank")
			spar.step(enemy["pos"])
			await d.step()
			continue
		if spar.mode == "tank":
			spar.set_mode("fight")
		# Now and then, a charged heavy attack to see the hitstop and the knockdown.
		if now >= heavy_next and spar.mode == "fight":
			spar.set_mode("heavy")
			heavy_next = now + 5000
		elif spar.mode == "heavy" and now >= heavy_next - 3200:
			spar.set_mode("fight")
		spar.step(enemy["pos"])
		await d.step()
	spar.stop()


func _plan_mode() -> String:
	var f: float = _elapsed_fraction()
	for part: Array in FORT_PLAN:
		if f >= float(part[0]) and f < float(part[1]):
			return String(part[2])
	return "fight"


func _nearest(kind: String) -> Dictionary:
	var my_realm: int = d.client.get_config().realm
	for r: Dictionary in d.remotes():
		if float(r["dist"]) > 45.0:
			break
		if int(r["realm"]) == my_realm or (int(r["action"]) & 0x0F) == CombatState.Action.DEAD:
			continue
		var is_npc: bool = int(r["kind"]) == NetProtocol.EntityKind.NPC
		if is_npc and String(r["name"]).begins_with("Mani"):
			continue
		if (kind == "npc") == is_npc:
			return r
	return {}
