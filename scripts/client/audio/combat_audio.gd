class_name CombatAudio
extends Node
## Combat and footstep audio (ART-11, client only). A single node per client that dispatches sound requests
## through the [AudioDirector] with the banks of [CombatSoundBank]: each sound comes from a different variant
## with random pitch and volume, in 3D and with high priority for the player's own.
## [br][br]
## [b]Where the requests come from[/b]:
## [br]- [CombatFeedback] ([method bind]): the impact of EVERY confirmed hit ([signal CombatFeedback.hit_impact],
## own or someone else's, at its draw tick), the locally predicted hit ([signal CombatFeedback.hit_predicted]), the
## local character's action ([signal CombatFeedback.action_changed]) and its death.
## [br]- The visuals ([HumanoidVisual]): the footsteps, jump and landing of any character
## ([signal CharacterAnimator.stepped]...) and the actions of remote ones (swings and dodges).
## [br][br]
## [b]Swing sync.[/b] The sound peaks [constant SWING_PEAK_LIGHT] ([constant SWING_PEAK_HEAVY])
## seconds after its start, and the active hit begins when the windup ends; it is requested when the action starts with the
## delay that makes the peak land in the middle of the active window ([method swing_delay], rule from
## [code]niveles.json[/code]).
## [br][br]
## What plays is counted per group ([method get_play_count]) even when there is no [AudioDirector] (the tests).

## Seconds from the start of the sound to its peak, in light and heavy swings (niveles.json).
const SWING_PEAK_LIGHT: float = 0.089
const SWING_PEAK_HEAVY: float = 0.197
## Priority (m) of what the local player does or receives versus what belongs to others when allocating voices.
const LOCAL_PRIORITY_BONUS: float = 60.0
## A predicted hit and the confirmed one that follows it are the same if they arrive less than this (s) apart.
const PREDICTION_MATCH_SECONDS: float = 1.2
## Seconds between the killing blow and the sound of the body falling.
const DEATH_FALL_DELAY: float = 0.4
## Meters at which a footstep stops being heard (other players' footsteps attenuate with distance).
const STEP_HEARING_DISTANCE: float = 28.0
## Extra volume (dB) of each footstep when running and sprinting compared with walking.
const STEP_LOUDNESS_DB_RANGE: float = 6.0

static var _instance: CombatAudio = null

var _feedback: CombatFeedback = null
var _counts: Dictionary = {}
var _last_step_msec: Dictionary = {}
var _pending: int = 0


static func get_instance() -> CombatAudio:
	return _instance if is_instance_valid(_instance) else null


func _enter_tree() -> void:
	_instance = self


func _exit_tree() -> void:
	if OS.has_environment("ELDMARK_FEEL_LOG"):
		print("[audio] sonidos pedidos por grupo: %s" % str(_counts))
	if _instance == self:
		_instance = null


func _init() -> void:
	name = "CombatAudio"


## Connects the node to the combat-feedback dispatcher: the impacts, own actions and death come from there.
## It can be called again with another dispatcher.
func bind(feedback: CombatFeedback) -> void:
	if is_instance_valid(_feedback):
		_feedback.hit_impact.disconnect(_on_hit_impact)
		_feedback.hit_predicted.disconnect(_on_hit_predicted)
		_feedback.action_changed.disconnect(_on_local_action)
		_feedback.sound_requested.disconnect(_on_sound_requested)
	_feedback = feedback
	if is_instance_valid(_feedback):
		_feedback.hit_impact.connect(_on_hit_impact)
		_feedback.hit_predicted.connect(_on_hit_predicted)
		_feedback.action_changed.connect(_on_local_action)
		_feedback.sound_requested.connect(_on_sound_requested)


# --- Requests ----------------------------------------------------------------------------------

## Delay (s) with which a swing sound has to start so that its peak lands in the middle of the active
## window: windup + half of the active time - peak, never negative.
static func swing_delay(windup_s: float, active_s: float, heavy: bool) -> float:
	var peak: float = SWING_PEAK_HEAVY if heavy else SWING_PEAK_LIGHT
	return maxf(windup_s + active_s * 0.5 - peak, 0.0)


## Weapon swing at [param position]. If [param windup_s] and [param active_s] are positive it is delayed for the
## sync of [method swing_delay]; [param local] gives priority.
func play_swing(position: Vector3, heavy: bool, windup_s: float = 0.0, active_s: float = 0.0,
		local: bool = false) -> void:
	var delay: float = swing_delay(windup_s, active_s, heavy) if windup_s > 0.0 else 0.0
	var group: StringName = &"sword_swing_heavy" if heavy else &"sword_swing_light"
	if delay > 0.01 and is_inside_tree():
		_pending += 1
		get_tree().create_timer(delay).timeout.connect(func() -> void:
			_pending -= 1
			_play(group, position, 0.0, 1.0, local), CONNECT_ONE_SHOT)
	else:
		_play(group, position, 0.0, 1.0, local)


## Impact of a hit at [param position] (the victim's chest).
## [param material] is a [enum CombatSoundBank.Armor]; [param heavy] makes it deeper and louder.
func play_impact(position: Vector3, material: int, heavy: bool, blocked: bool, parried: bool,
		local: bool) -> void:
	var group: StringName = CombatSoundBank.impact_group(material, blocked, parried)
	_play(group, position, 2.0 if heavy else 0.0, 0.92 if heavy else 1.0, local)
	if material == CombatSoundBank.Armor.HOLLOW and not blocked and not parried:
		_play(&"hollow_hurt", position, 0.0, 1.0, local)


## Footstep of a character at [param position] on [param surface]. [param speed_fraction] (0 = walking, 1 = sprint)
## gives it a bit more force; other players' footsteps attenuate with distance and have lower priority.
func play_step(position: Vector3, surface: StringName, speed_fraction: float, local: bool) -> void:
	var group: StringName = CombatSoundBank.step_group(surface)
	var extra: float = lerpf(-STEP_LOUDNESS_DB_RANGE * 0.5, STEP_LOUDNESS_DB_RANGE * 0.5,
			clampf(speed_fraction, 0.0, 1.0))
	_play(group, position, extra - (0.0 if local else 3.0), CombatSoundBank.step_pitch(surface), local,
			STEP_HEARING_DISTANCE)


## Jump takeoff: a footstep with push.
func play_jump(position: Vector3, surface: StringName, local: bool) -> void:
	_play(CombatSoundBank.step_group(surface), position, 1.0, 1.1, local, STEP_HEARING_DISTANCE)


## Landing with [param strength] from 0 to 1 (the impact speed): two footsteps together, louder the greater it is.
func play_land(position: Vector3, surface: StringName, strength: float, local: bool) -> void:
	var group: StringName = CombatSoundBank.step_group(surface)
	var pitch: float = lerpf(0.95, 0.78, clampf(strength, 0.0, 1.0))
	_play(group, position, lerpf(-1.0, 5.0, strength), pitch * CombatSoundBank.step_pitch(surface), local,
			STEP_HEARING_DISTANCE)


## Dodge: the roll (with cloth and a footfall) of the one who moves.
func play_dodge(position: Vector3, local: bool) -> void:
	_play(&"dodge_roll", position, 0.0, 1.0, local)


## Death: the body falling, a moment after the hit.
func play_death(position: Vector3, local: bool) -> void:
	if is_inside_tree():
		_pending += 1
		get_tree().create_timer(DEATH_FALL_DELAY).timeout.connect(func() -> void:
			_pending -= 1
			_play(&"body_fall", position, 0.0, 1.0, local), CONNECT_ONE_SHOT)
	else:
		_play(&"body_fall", position, 0.0, 1.0, local)


# --- Readout (the tests) ------------------------------------------------------------------------

## Number of times the group [param group] has been requested since it was created.
func get_play_count(group: StringName) -> int:
	return int(_counts.get(group, 0))


## Total requests.
func get_total_play_count() -> int:
	var total: int = 0
	for group: Variant in _counts:
		total += int(_counts[group])
	return total


## Delayed swings waiting for their moment.
func get_pending_count() -> int:
	return _pending


## Forgets the counters (the tests).
func reset_counts() -> void:
	_counts.clear()


## Material the hit sounds with for victim [param net_id]: stable per victim (their armor) and Hollow
## if it is one. Without a dispatcher, flesh.
func material_of(net_id: int) -> int:
	if is_instance_valid(_feedback) and _feedback.is_hollow(net_id):
		return CombatSoundBank.Armor.HOLLOW
	var order: Array[int] = [CombatSoundBank.Armor.FLESH, CombatSoundBank.Armor.LEATHER,
			CombatSoundBank.Armor.GAMBESON, CombatSoundBank.Armor.MAIL]
	return order[absi(net_id) % order.size()]


# --- Internal ---------------------------------------------------------------------------------

func _play(group: StringName, position: Vector3, volume_offset_db: float, pitch: float, local: bool,
		max_distance: float = 0.0) -> void:
	_counts[group] = int(_counts.get(group, 0)) + 1
	var director: AudioDirector = AudioDirector.get_instance()
	if director == null:
		return
	if max_distance > 0.0 and not local \
			and director.get_listener_position().distance_to(position) > max_distance:
		return
	var stream: AudioStream = CombatSoundBank.stream_of(group)
	if stream == null:
		return
	director.play_3d(AudioDirector.Category.VOICES if group == &"hollow_hurt" else AudioDirector.Category.SFX,
			stream, position, CombatSoundBank.volume_db_of(group) + volume_offset_db, pitch,
			LOCAL_PRIORITY_BONUS if local else 0.0)


func _on_hit_impact(event: NetMessages.EntityEvent, position: Vector3, involves_me: bool,
		already_predicted: bool) -> void:
	if already_predicted:
		return
	var blocked: bool = event.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_BLOCKED)
	var parried: bool = event.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_PARRIED)
	var attack: AttackTicks = CombatCatalog.attack(event.attack_id)
	var heavy: bool = attack != null and attack.heavy
	play_impact(position + Vector3(0.0, 1.2, 0.0), material_of(event.net_id), heavy, blocked, parried,
			involves_me)


func _on_hit_predicted(net_id: int, position: Vector3, heavy: bool) -> void:
	play_impact(position + Vector3(0.0, 1.2, 0.0), material_of(net_id), heavy, false, false, true)


func _on_local_action(action: int, attack_id: int, _action_tick: int, _previous: int) -> void:
	if not is_instance_valid(_feedback):
		return
	var position: Vector3 = _feedback.get_local_position()
	if action == CombatState.Action.LIGHT or action == CombatState.Action.HEAVY:
		var attack: AttackTicks = CombatCatalog.attack(attack_id)
		var tick_s: float = 1.0 / float(Engine.physics_ticks_per_second)
		if attack != null:
			play_swing(position + Vector3(0.0, 1.2, 0.0), action == CombatState.Action.HEAVY,
					float(attack.windup_ticks) * tick_s, float(attack.active_ticks) * tick_s, true)
		else:
			play_swing(position + Vector3(0.0, 1.2, 0.0), action == CombatState.Action.HEAVY, 0.0, 0.0, true)
	elif action == CombatState.Action.DODGE:
		play_dodge(position + Vector3(0.0, 0.5, 0.0), true)


func _on_sound_requested(sound: StringName, position: Vector3) -> void:
	# Swings, dodges and hits are already dispatched by their own signals; here, only the death, own or someone else's.
	if sound == CombatFeedback.SOUND_DEATH:
		play_death(position, false)
