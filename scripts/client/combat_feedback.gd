class_name CombatFeedback
extends Node
## Distributes the combat feel on the client (docs/combat.md, section 8; UI-12, basic ART-09,
## CMB-11). It receives the ENTITY_EVENTs [b]already timed[/b] by [NetClient] ([signal
## NetClient.combat_event]: the player's own on arrival, other players' on their draw tick) and distributes them:
## [br]- [b]Confirmed own hits[/b] ([method handle_event], HIT with the local player as attacker):
## hit marker ([HitMarker]) and damage number ([DamageNumbers]) with its variant, and the
## [DpsMeter]. A hit not confirmed by the server produces nothing: it is not predicted.
## [br]- [b]Damage taken[/b]: camera shake ([method CameraRig.add_shake]), red number and the
## signal [signal damage_taken] (from which the HUD direction arcs hang).
## [br]- [b]Flash[/b] of the victim: a white, additive [code]material_overlay[/code] of about 80 ms that falls to zero
## (UI-50). At full intensity on hits involving the local player and faint on others'.
## [br][br]
## [b]Timing of a remote's reaction.[/b] An own event arrives as soon as it occurs on the
## server, but remotes are drawn a few ticks behind (the [InterpolationClock] delay).
## What belongs to the local player (marker, number, DPS, shake, HUD) is applied on arrival; what is
## seen on the remote (flash, health nameplate with [signal entity_damaged], sound of its death or
## kill) waits in a [CombatEventQueue] of its own until its draw tick reaches the event's
## [code]tick[/code], just like other players' events. Without a client (the sandbox) there is no delay and everything is
## immediate.
## [br]
## [br]- [b]Sound and effect hooks[/b]: the signal [signal sound_requested] with the sound name and its
## position, and [signal hit_impact], once for each confirmed HIT, whoever's it is and blocked or not, on its draw
## tick, from which the impact sound ([CombatAudio]) and the sparks ([CombatVfx]) hang.
## [br]- [b]Predicted hit[/b] (ART-09, decision 6 of quality.md): while the own hit is active it is checked
## against the DRAWN positions of the enemies to see whether it would reach any ([method _try_predict]). If so, the
## impact already sounds, the sparks fly and the animation does the hitstop (50 ms for light, 80 ms for heavy),
## without waiting for the server ([signal hit_predicted]). It is cosmetic only: the number, the marker and the DPS keep
## waiting for the event; and if the server confirms it as a normal hit the sound and the spark are not repeated.
## [br]- Own death and respawn: [signal local_died] and [signal local_respawned].
## [br][br]
## [b]Own actions without signals.[/b] The simulation emits no combat signals (reconciliation replays
## would duplicate or lose effects). Instead, after each physics tick
## [code](action, action_id, action_tick)[/code] of the displayed state is compared with the last one seen:
## if it changes, another action begins ([signal action_changed]); and the weapon sweep is tracked, active
## while the hit lasts ([signal swing_active_changed], hook for the trail). A correction that
## replays ticks does not change the key, so it duplicates nothing; and one that only shifts the start of
## the same action by a few ticks (the edge input reached the server late, which replaced it and started
## the dodge one tick later) is not a new action either. The allowed shift is the size of the
## input buffer ([member CombatRules.input_buffer_ticks]), less than the duration of the shortest
## action (the dodge lasts 27 ticks), so a second chained action is told apart.
## [br][br]
## The player options are [member hit_markers_enabled], [member damage_numbers_enabled],
## [member camera_shake_enabled] and [member flash_enabled].

## A hit by this player confirmed by the server. [param kind] is a [enum HitMarker.Kind].
signal hit_confirmed(kind: int, amount: int, event: NetMessages.EntityEvent)
## The local player took [param amount] damage from attacker [param attacker_id] (0 if none).
signal damage_taken(amount: int, attacker_id: int, event: NetMessages.EntityEvent)
## A HIT with damage on [param net_id], whoever it is (nameplates show their health for a few seconds). If
## the event is own and the victim a remote, it fires when the victim is drawn on the hit's tick.
signal entity_damaged(net_id: int)
## The local player killed [param victim_id].
signal kill_confirmed(victim_id: int, event: NetMessages.EntityEvent)
## The local player has died; [param killer_id] is 0 if it was the environment.
signal local_died(killer_id: int, attack_id: int)
## The local player has respawned at point [param point] on server tick [param tick].
signal local_respawned(point: int, tick: int)
## The local character's action has changed ([param previous_action] is the previous one).
signal action_changed(action: int, attack_id: int, action_tick: int, previous_action: int)
## The weapon hit becomes active (or stops being so): starts or cuts the trail.
signal swing_active_changed(active: bool, attack_id: int)
## Sound hook: [param sound] is one of the [code]SOUND_*[/code] and [param world_position] is where it
## plays.
signal sound_requested(sound: StringName, world_position: Vector3)

## The hit of [param event] has landed at point [param position] (the victim's feet), whoever
## strikes, already on the tick at which it is drawn. [param involves_me]: the local player is the attacker or the victim.
## [param already_predicted]: the hit was already shown as a local prediction and is a normal hit (do not repeat sound or
## spark).
signal hit_impact(event: NetMessages.EntityEvent, position: Vector3, involves_me: bool, already_predicted: bool)
## The active own hit would reach someone according to what is drawn: [param position] is the victim's feet.
signal hit_predicted(net_id: int, position: Vector3, heavy: bool)
## [param net_id] dies at [param position] (the feet), on the tick at which it is drawn.
signal entity_died(net_id: int, position: Vector3)

const SOUND_SWING: StringName = &"swing"
const SOUND_DODGE: StringName = &"dodge"
const SOUND_HIT_DEALT: StringName = &"hit_dealt"
const SOUND_HIT_TAKEN: StringName = &"hit_taken"
const SOUND_BLOCK: StringName = &"block"
const SOUND_PARRY: StringName = &"parry"
const SOUND_KILL: StringName = &"kill"
const SOUND_DEATH: StringName = &"death"
const SOUND_RESPAWN: StringName = &"respawn"

## Duration (s) of the victim's flash: brief, with the opacity falling in a straight line to zero.
const FLASH_SECONDS: float = 0.08
## White, additive flash (adds light, does not tint red): its opacity at the start, at full intensity (hits involving
## the local player) and the fraction of that intensity that other players' hits have.
const FLASH_COLOR: Color = Color(1.0, 1.0, 1.0, 0.55)
const FLASH_OTHERS_INTENSITY: float = 0.45
## Camera shake on taking damage: base amplitude and per fraction of maximum health lost (m),
## cap and duration (s). A blocked hit shakes half as much.
const SHAKE_BASE: float = 0.03
const SHAKE_PER_HEALTH_FRACTION: float = 0.25
const SHAKE_MAX: float = 0.15
const SHAKE_SECONDS: float = 0.18
const BLOCKED_SHAKE_SCALE: float = 0.5
## Hitstop (s) of the attacker's animation: a light hit, a heavy one, a parry and a death.
const HITSTOP_LIGHT: float = 0.05
const HITSTOP_HEAVY: float = 0.08
const HITSTOP_PARRY: float = 0.10
const HITSTOP_KILL: float = 0.10
## Camera push (m) when releasing the heavy attack and when an own one connects.
const HEAVY_RELEASE_SHAKE: float = 0.05
const HEAVY_DEALT_SHAKE: float = 0.04
const PARRY_DEALT_SHAKE: float = 0.05
## Seconds a predicted hit is valid to skip the sound and spark of the same confirmed hit.
const PREDICTION_WINDOW_SECONDS: float = 1.2
## Text of the numbers of parried hits and of blocked hits with no damage.
const TEXT_PARRIED: String = "Parada"
const TEXT_BLOCKED: String = "Bloqueado"

## Player options.
var hit_markers_enabled: bool = true:
	set(value):
		hit_markers_enabled = value
		if is_instance_valid(_marker):
			_marker.enabled = value
var damage_numbers_enabled: bool = true:
	set(value):
		damage_numbers_enabled = value
		if is_instance_valid(_numbers):
			_numbers.enabled = value
var camera_shake_enabled: bool = true
var flash_enabled: bool = true
## Only for tests and the sandbox: if valid, it is asked first where an entity is
## (it receives the [code]net_id[/code] and returns its draw position, or [constant Vector3.INF]).
var position_resolver: Callable = Callable()

var _client: NetClient = null
var _camera_rig: CameraRig = null
var _character: PlayerCharacter = null
var _marker: HitMarker = null
var _numbers: DamageNumbers = null
var _dps: DpsMeter = DpsMeter.new()
var _own_net_id_override: int = 0
var _last_event_tick: int = 0
# Last key (action, attack, start tick) seen of the local character and whether the hit was active.
var _last_action_key: Vector3i = Vector3i(-1, -1, -1)
var _last_action: int = CombatState.Action.NONE
var _swing_active: bool = false
var _flash_meshes: Array[MeshInstance3D] = []
var _flash_left: Array[float] = []
# Material and initial opacity of each flash in progress (in the order of _flash_meshes).
var _flash_materials: Array[StandardMaterial3D] = []
var _flash_peaks: Array[float] = []
var _events_handled: int = 0
# Locally predicted hit: the attack, when (ms) and whether it was already predicted in this sweep.
var _predicted_attack: int = -1
var _predicted_msec: int = -1000000
var _predicted_this_swing: bool = false
var _predictions_made: int = 0
# Visual reactions to own events on a remote that are waiting for their draw tick.
var _deferred: CombatEventQueue = CombatEventQueue.new()


func _init() -> void:
	name = "CombatFeedback"
	# After NetClient (and the prediction) or the controller have simulated the tick.
	process_physics_priority = 100


func _process(delta: float) -> void:
	advance_flashes(delta)


func _physics_process(_delta: float) -> void:
	observe_action()
	deliver_due_reactions()


## Connects the distribution to what is on screen. Everything is optional: without [param client] (the sandbox)
## only the character's action is tracked; without a marker, numbers or camera, that effect is skipped.
## With a client, events arrive through [signal NetClient.combat_event].
func setup(client: NetClient, camera_rig: CameraRig, character: PlayerCharacter,
		marker: HitMarker, numbers: DamageNumbers) -> void:
	if is_instance_valid(_client) and _client.combat_event.is_connected(handle_event):
		_client.combat_event.disconnect(handle_event)
	_client = client
	_camera_rig = camera_rig
	_character = character
	_marker = marker
	_numbers = numbers
	if is_instance_valid(_marker):
		_marker.enabled = hit_markers_enabled
	if is_instance_valid(_numbers):
		_numbers.enabled = damage_numbers_enabled
		if is_instance_valid(_camera_rig):
			_numbers.set_camera(_camera_rig.get_camera())
	if is_instance_valid(_client) and not _client.combat_event.is_connected(handle_event):
		_client.combat_event.connect(handle_event)
	_last_action_key = Vector3i(-1, -1, -1)
	_swing_active = false
	_deferred.clear()


## Only for tests and the sandbox: the local player's network id if there is no [NetClient].
func set_own_net_id(net_id: int) -> void:
	_own_net_id_override = net_id


## Network id of the local player (0 if unknown).
func get_own_net_id() -> int:
	if is_instance_valid(_client):
		return _client.get_net_id()
	return _own_net_id_override


func get_dps_meter() -> DpsMeter:
	return _dps


## Damage per second over the last 30 s (F3 panel).
func get_dps() -> float:
	return _dps.get_dps(_now_tick())


## Damage of the own hits over the last 30 s.
func get_damage_in_window() -> int:
	return _dps.get_damage(_now_tick())


## Events distributed since it exists.
func get_events_handled() -> int:
	return _events_handled


## Visual reactions to own events on a remote that are still waiting for their draw tick.
func get_pending_reactions() -> int:
	return _deferred.size()


# --- Events -----------------------------------------------------------------------------------

## Distributes an already timed event ([signal NetClient.combat_event]). [param is_own] says whether the
## local player is involved; the distribution also checks the ids, so it works the same if it is missing.
func handle_event(event: NetMessages.EntityEvent, is_own: bool = false) -> void:
	if event == null:
		return
	_events_handled += 1
	_last_event_tick = maxi(_last_event_tick, event.tick)
	match event.event:
		NetMessages.EntityEvent.Kind.HIT:
			_on_hit(event, is_own)
		NetMessages.EntityEvent.Kind.DEATH:
			_on_death(event, is_own)
		NetMessages.EntityEvent.Kind.KILL:
			_on_kill(event, is_own)
		NetMessages.EntityEvent.Kind.RESPAWN:
			_on_respawn(event, is_own)


## Marker and number variant for a HIT: death, parry, blocked, heavy or normal.
func kind_of(event: NetMessages.EntityEvent) -> int:
	if event.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_LETHAL):
		return HitMarker.Kind.KILL
	if event.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_PARRIED):
		return HitMarker.Kind.PARRY
	if event.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_BLOCKED):
		return HitMarker.Kind.BLOCKED
	var attack: AttackTicks = CombatCatalog.attack(event.attack_id)
	if attack != null and attack.heavy:
		return HitMarker.Kind.HEAVY
	return HitMarker.Kind.HIT


## Name of player [param net_id] as this client sees it ("" if unknown).
func get_entity_name(net_id: int) -> String:
	if net_id == 0 or not is_instance_valid(_client):
		return ""
	var view: RemotePlayerView = _client.get_remote_world().get_view(net_id)
	return view.get_display_name() if view != null else ""


## Position (feet) at which entity [param net_id] is drawn now: the local character or the
## view of a remote. [constant Vector3.INF] if unknown (out of interest).
func get_entity_position(net_id: int) -> Vector3:
	if position_resolver.is_valid():
		var resolved: Vector3 = position_resolver.call(net_id)
		if resolved != Vector3.INF:
			return resolved
	var body: PlayerCharacter = _body_of(net_id)
	if body == null:
		return Vector3.INF
	return body.global_position if body.is_inside_tree() else body.position


func knows_entity(net_id: int) -> bool:
	return get_entity_position(net_id) != Vector3.INF


func _on_hit(event: NetMessages.EntityEvent, is_own: bool) -> void:
	var own_id: int = get_own_net_id()
	var attacker_is_me: bool = own_id != 0 and event.attacker == own_id
	var victim_is_me: bool = own_id != 0 and event.net_id == own_id
	var parried: bool = event.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_PARRIED)
	var blocked: bool = event.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_BLOCKED)
	var kind: int = kind_of(event)
	var position: Vector3 = get_entity_position(event.net_id)
	if not _defer_remote_reaction(event, is_own):
		_react_to_hit(event)
	if attacker_is_me:
		_dps.add_hit(event.tick, event.amount)
		if is_instance_valid(_marker):
			_marker.show_marker(kind)
		if is_instance_valid(_numbers) and position != Vector3.INF:
			_numbers.add_number(event.net_id, position, event.amount, kind, false,
					event.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_CRITICAL),
					_text_for(event, parried, blocked))
		hit_confirmed.emit(kind, event.amount, event)
		if heavy_or_parry_dealt(event):
			_shake_dealt(parried)
		_request_sound(SOUND_PARRY if parried else (SOUND_BLOCK if blocked else SOUND_HIT_DEALT),
				position)
	if victim_is_me:
		_shake_for(event.amount, blocked or parried)
		if is_instance_valid(_numbers) and position != Vector3.INF \
				and (event.amount > 0 or parried or blocked):
			_numbers.add_number(event.net_id, position, event.amount, kind, true,
					event.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_CRITICAL),
					_text_for(event, parried, blocked))
		damage_taken.emit(event.amount, event.attacker, event)
		_request_sound(SOUND_PARRY if parried else (SOUND_BLOCK if blocked else SOUND_HIT_TAKEN),
				position)


func _on_death(event: NetMessages.EntityEvent, is_own: bool) -> void:
	var own_id: int = get_own_net_id()
	if not _defer_remote_reaction(event, is_own):
		_react_to_death(event)
	if own_id != 0 and event.net_id == own_id:
		local_died.emit(event.killer, event.attack_id)


func _on_kill(event: NetMessages.EntityEvent, is_own: bool) -> void:
	var own_id: int = get_own_net_id()
	if own_id != 0 and event.killer == own_id:
		kill_confirmed.emit(event.net_id, event)
		if not _defer_remote_reaction(event, is_own):
			_react_to_kill(event)


# What is seen on the victim of a HIT with damage: its nameplate shows the health and it flashes (at full intensity if the hit
# is by the local player or the local player receives it, faint if it is others').
func _react_to_hit(event: NetMessages.EntityEvent) -> void:
	_react_body(event, event.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_BLOCKED)
			or event.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_PARRIED))
	var own_id: int = get_own_net_id()
	var involves_me: bool = own_id != 0 and (event.attacker == own_id or event.net_id == own_id)
	if event.amount > 0:
		entity_damaged.emit(event.net_id)
		flash(event.net_id, 1.0 if involves_me else FLASH_OTHERS_INTENSITY)
	_emit_impact(event, involves_me)


# The victim's body reacts to the hit (ART-48, ART-50): it recoils, away from the attacker, or, if
# it blocks, pushes the shield. Visual only and only if the victim has a drawn [HumanoidVisual].
func _react_body(event: NetMessages.EntityEvent, blocked: bool) -> void:
	var body: PlayerCharacter = _body_of(event.net_id)
	if body == null:
		return
	var visual: HumanoidVisual = body.get_node_or_null(^"Visual/HumanoidVisual") as HumanoidVisual
	if visual == null:
		return
	var direction := Vector3.ZERO
	var attacker_position: Vector3 = get_entity_position(event.attacker)
	if attacker_position != Vector3.INF:
		direction = attacker_position - body.global_position
	visual.react_to_hit(direction, float(event.amount), blocked)


func _react_to_death(event: NetMessages.EntityEvent) -> void:
	var position: Vector3 = get_entity_position(event.net_id)
	_request_sound(SOUND_DEATH, position)
	if position != Vector3.INF:
		entity_died.emit(event.net_id, position)


func _react_to_kill(event: NetMessages.EntityEvent) -> void:
	_request_sound(SOUND_KILL, get_entity_position(event.net_id))


# Stores the visual reaction of [param event] if it is own and happens to a remote that is still
# drawn before the event's tick (the server produced it [code]delay[/code] ticks ahead of what
# is seen of it). Returns true if it stored it; then [method deliver_due_reactions] applies it when
# the draw tick reaches the event's. Without a client (sandbox) or with the own player as victim there is
# nothing to wait for. With the clock not started (draw tick 0) it also waits: nobody is drawn yet.
func _defer_remote_reaction(event: NetMessages.EntityEvent, is_own: bool) -> bool:
	if not is_own or not is_instance_valid(_client):
		return false
	var own_id: int = get_own_net_id()
	if own_id != 0 and event.net_id == own_id:
		return false
	var render_tick: float = _client.get_interpolation_clock().get_render_tick()
	if render_tick > 0.0 and render_tick >= float(event.tick):
		return false
	_deferred.push(event)
	return true


## Applies the visual reactions to own events on remotes whose tick the draw tick has now reached
## ([method _defer_remote_reaction]). [method _physics_process] calls it after each
## tick; tests call it by hand.
func deliver_due_reactions() -> void:
	if _deferred.size() == 0:
		return
	if not is_instance_valid(_client):
		_deferred.clear()
		return
	for event: NetMessages.EntityEvent in _deferred.pop_due(
			_client.get_interpolation_clock().get_render_tick()):
		match event.event:
			NetMessages.EntityEvent.Kind.HIT:
				_react_to_hit(event)
			NetMessages.EntityEvent.Kind.DEATH:
				_react_to_death(event)
			NetMessages.EntityEvent.Kind.KILL:
				_react_to_kill(event)


func _on_respawn(event: NetMessages.EntityEvent, is_own: bool) -> void:
	var own_id: int = get_own_net_id()
	_request_sound(SOUND_RESPAWN, get_entity_position(event.net_id))
	if is_own or (own_id != 0 and event.net_id == own_id):
		local_respawned.emit(event.point, event.tick)


# Text of the number: empty (the damage) except on parried hits or blocked hits with no damage.
func _text_for(event: NetMessages.EntityEvent, parried: bool, blocked: bool) -> String:
	if parried:
		return TEXT_PARRIED
	if blocked and event.amount <= 0:
		return TEXT_BLOCKED
	return ""


func _shake_for(amount: int, softened: bool) -> void:
	if not camera_shake_enabled or not is_instance_valid(_camera_rig):
		return
	var max_health: float = float(maxi(_client.get_max_health(), 1)) \
			if is_instance_valid(_client) else 1000.0
	var strength: float = SHAKE_BASE + SHAKE_PER_HEALTH_FRACTION * float(amount) / max_health
	strength = minf(strength, SHAKE_MAX)
	if softened:
		strength *= BLOCKED_SHAKE_SCALE
	_camera_rig.add_shake(strength, SHAKE_SECONDS)


func _request_sound(sound: StringName, position: Vector3) -> void:
	sound_requested.emit(sound, position if position != Vector3.INF else Vector3.ZERO)


# true if the own hit is heavy or a parry (the ones that push the camera on connecting).
func heavy_or_parry_dealt(event: NetMessages.EntityEvent) -> bool:
	if event.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_PARRIED):
		return true
	var attack: AttackTicks = CombatCatalog.attack(event.attack_id)
	return attack != null and attack.heavy


func _shake_dealt(parried: bool) -> void:
	if not camera_shake_enabled or not is_instance_valid(_camera_rig):
		return
	_camera_rig.add_shake(PARRY_DEALT_SHAKE if parried else HEAVY_DEALT_SHAKE, SHAKE_SECONDS * 0.7)


# Announces the impact of [param event] (see [signal hit_impact]) and gives the attacker hitstop (and both on a
# parry or a death) if it was not already given when the hit was predicted.
func _emit_impact(event: NetMessages.EntityEvent, involves_me: bool) -> void:
	var position: Vector3 = get_entity_position(event.net_id)
	if position == Vector3.INF:
		return
	var blocked: bool = event.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_BLOCKED)
	var parried: bool = event.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_PARRIED)
	var already: bool = _consume_prediction(event) and not blocked and not parried
	hit_impact.emit(event, position, involves_me, already)
	var attack: AttackTicks = CombatCatalog.attack(event.attack_id)
	var heavy: bool = attack != null and attack.heavy
	var lethal: bool = event.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_LETHAL)
	var seconds: float = HITSTOP_HEAVY if heavy else HITSTOP_LIGHT
	if parried:
		seconds = HITSTOP_PARRY
	elif lethal:
		seconds = maxf(seconds, HITSTOP_KILL)
	# An already predicted hit gave its hitstop when it was thrown; only death adds a longer one.
	if already and not lethal:
		return
	if event.attacker != 0 and event.attacker != event.net_id:
		_hitstop(event.attacker, seconds)
	if parried or lethal:
		_hitstop(event.net_id, seconds)


# true (and consumes it) if [param event] is the own hit that was just predicted locally.
func _consume_prediction(event: NetMessages.EntityEvent) -> bool:
	var own_id: int = get_own_net_id()
	if own_id == 0 or event.attacker != own_id or _predicted_attack != event.attack_id:
		return false
	var age: float = float(Time.get_ticks_msec() - _predicted_msec) / 1000.0
	if age > PREDICTION_WINDOW_SECONDS:
		return false
	_predicted_attack = -1
	return true


# Freezes the combat animation of entity [param net_id] for [param seconds] (only the animation: the simulation
# does not find out).
func _hitstop(net_id: int, seconds: float) -> void:
	var body: PlayerCharacter = _body_of(net_id)
	if body == null:
		return
	var visual: HumanoidVisual = HumanoidVisual.of_body(body)
	if visual != null:
		visual.start_hitstop(seconds)


## Hits that have been predicted locally since it exists (tests).
func get_predictions_made() -> int:
	return _predictions_made


## true if [param net_id] is an NPC of the Hollow (it sounds and looks different from a human).
func is_hollow(net_id: int) -> bool:
	if not is_instance_valid(_client) or net_id == 0:
		return false
	var view: RemotePlayerView = _client.get_remote_world().get_view(net_id)
	if view == null or view.get_kind() != NetProtocol.EntityKind.NPC:
		return false
	var definition: NpcDefinition = NpcCatalog.get_by_number(view.get_npc_def_id())
	return definition != null and definition.weapon_id == &"npc_hollow"


## Feet of the local character (Vector3.ZERO if none).
func get_local_position() -> Vector3:
	var character: PlayerCharacter = _local_character()
	if character == null:
		return Vector3.ZERO
	return character.global_position if character.is_inside_tree() else character.position


## Where the local character is facing (horizontal, unit length).
func get_local_heading() -> Vector3:
	var character: PlayerCharacter = _local_character()
	if character == null:
		return Vector3.FORWARD
	return Basis(Vector3.UP, character.yaw) * Vector3.FORWARD


## Realm of the local player ([enum NetProtocol.Realm] code; 0 if unknown).
func get_local_realm() -> int:
	if is_instance_valid(_client) and _client.get_welcome() != null:
		return _client.get_welcome().realm
	return 0


## true if the drawn remote [param view] is someone the local player can damage (realm and zone; NPCs,
## always) and is not dead.
func is_valid_target(view: RemotePlayerView) -> bool:
	if not is_instance_valid(_client) or view == null or not view.is_drawn():
		return false
	if (view.get_drawn_action() & 15) == CombatState.Action.DEAD:
		return false
	var welcome: NetMessages.Welcome = _client.get_welcome()
	if welcome == null:
		return false
	return FactionRules.can_damage(welcome.realm, view.get_realm(), StringName(welcome.zone_id))


# Checks the active own hit against the drawn positions of the enemies and, if it reaches any, it
# predicts it: sound, spark and hitstop right away, without waiting for the server (cosmetic only).
func _try_predict(character: PlayerCharacter, state: CombatState) -> void:
	if not is_instance_valid(_client):
		return
	var attack: AttackTicks = CombatCatalog.attack(state.action_id)
	if attack == null or attack.shape == null:
		return
	var origin: Vector3 = character.global_position if character.is_inside_tree() else character.position
	var space: PhysicsDirectSpaceState3D = null
	if character.is_inside_tree():
		space = character.get_world_3d().direct_space_state
	for view: RemotePlayerView in _client.get_remote_world().get_views():
		if view.get_net_id() == get_own_net_id() or not is_valid_target(view):
			continue
		# Whoever dodges (on their invulnerability ticks) does not receive the hit: it is not predicted.
		if (view.get_drawn_action() & 15) == CombatState.Action.DODGE:
			continue
		var feet: Vector3 = view.get_drawn_position()
		if HitShapes.sector_hits_capsule(origin, character.yaw, attack.shape, feet,
				HitShapes.CAPSULE_RADIUS, HitShapes.CAPSULE_HEIGHT) \
						and (space == null or HitShapes.has_line_of_sight(space, origin, feet)):
			_predicted_this_swing = true
			_predicted_attack = state.action_id
			_predicted_msec = Time.get_ticks_msec()
			_predictions_made += 1
			hit_predicted.emit(view.get_net_id(), feet, attack.heavy)
			_hitstop(get_own_net_id(), HITSTOP_HEAVY if attack.heavy else HITSTOP_LIGHT)
			return


# --- Flash ------------------------------------------------------------------------------------

## Brief flash (white, additive material_overlay) on the meshes of entity [param net_id] with strength
## [param intensity] (1 = full, that of [constant FLASH_COLOR]). No effect with [member flash_enabled] set to false or if its
## body is unknown.
func flash(net_id: int, intensity: float = 1.0) -> void:
	if not flash_enabled:
		return
	var body: PlayerCharacter = _body_of(net_id)
	if body == null:
		return
	var peak: float = FLASH_COLOR.a * clampf(intensity, 0.0, 1.0)
	var material: StandardMaterial3D = _make_flash_material(peak)
	for node: Node in body.find_children("*", "MeshInstance3D", true, false):
		var mesh: MeshInstance3D = node as MeshInstance3D
		if mesh == null or not mesh.visible:
			continue
		mesh.material_overlay = material
		var index: int = _flash_meshes.find(mesh)
		if index >= 0:
			_flash_left[index] = FLASH_SECONDS
			_flash_materials[index] = material
			_flash_peaks[index] = peak
		else:
			_flash_meshes.append(mesh)
			_flash_left.append(FLASH_SECONDS)
			_flash_materials.append(material)
			_flash_peaks.append(peak)


## Advances the flash by [param delta] seconds, lowers its opacity and removes the overlay from the meshes that have finished.
func advance_flashes(delta: float) -> void:
	var index: int = _flash_meshes.size() - 1
	while index >= 0:
		_flash_left[index] -= delta
		var mesh: MeshInstance3D = _flash_meshes[index]
		if not is_instance_valid(mesh):
			_remove_flash(index)
		elif _flash_left[index] <= 0.0:
			mesh.material_overlay = null
			_remove_flash(index)
		else:
			_flash_materials[index].albedo_color.a = _flash_peaks[index] * (_flash_left[index] / FLASH_SECONDS)
		index -= 1


## Meshes that currently have the flash applied.
func get_flashing_count() -> int:
	return _flash_meshes.size()


## Current opacity of the flash of the first mesh that has it (0 if none): for tests.
func get_flash_alpha() -> float:
	return _flash_materials[0].albedo_color.a if not _flash_materials.is_empty() else 0.0


func _remove_flash(index: int) -> void:
	_flash_meshes.remove_at(index)
	_flash_left.remove_at(index)
	_flash_materials.remove_at(index)
	_flash_peaks.remove_at(index)


func _make_flash_material(alpha: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(FLASH_COLOR.r, FLASH_COLOR.g, FLASH_COLOR.b, alpha)
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.no_depth_test = false
	return material


func _exit_tree() -> void:
	if OS.has_environment("ELDMARK_FEEL_LOG"):
		print("[feedback] eventos %d, golpes predichos en local %d" % [_events_handled, _predictions_made])
	# So that no mesh stays tinted if the distributor disappears halfway.
	for mesh: MeshInstance3D in _flash_meshes:
		if is_instance_valid(mesh):
			mesh.material_overlay = null
	_flash_meshes.clear()
	_flash_left.clear()
	_flash_materials.clear()
	_flash_peaks.clear()
	_deferred.clear()


# --- Own actions ------------------------------------------------------------------------------

## Compares the key of the local character's action with the last one seen and fires the signals for what
## changed. [method _physics_process] calls it after each tick; tests call it by
## hand.
func observe_action() -> void:
	var character: PlayerCharacter = _local_character()
	if character == null:
		return
	var state: CombatState = character.combat
	var key := Vector3i(state.action, state.action_id, state.action_tick)
	if key != _last_action_key:
		var first: bool = _last_action_key == Vector3i(-1, -1, -1)
		var previous: int = _last_action
		var shifted: bool = not first and _is_shifted_start(key, _last_action_key)
		_last_action_key = key
		_last_action = state.action
		if not first and not shifted:
			action_changed.emit(state.action, state.action_id, state.action_tick, previous)
			if state.action == CombatState.Action.DODGE:
				_request_sound(SOUND_DODGE, character.global_position)
			if previous == CombatState.Action.CHARGE and state.action == CombatState.Action.HEAVY \
					and camera_shake_enabled and is_instance_valid(_camera_rig):
				_camera_rig.add_shake(HEAVY_RELEASE_SHAKE, SHAKE_SECONDS)
	var active: bool = ActionMachine.is_attack_active(state, character.last_input_tick)
	if active != _swing_active:
		_swing_active = active
		swing_active_changed.emit(active, state.action_id if active else 0)
		if active:
			_request_sound(SOUND_SWING, character.global_position)
		else:
			_predicted_this_swing = false
	if active and not _predicted_this_swing:
		_try_predict(character, state)


# true if [param key] is the same action as [param previous] with the start moved by a few ticks (a
# reconciliation correction), not another action: same type and same attack, other than NONE.
func _is_shifted_start(key: Vector3i, previous: Vector3i) -> bool:
	return key.x != CombatState.Action.NONE and key.x == previous.x and key.y == previous.y \
			and absi(key.z - previous.z) <= CombatCatalog.rules().input_buffer_ticks


## true while the own weapon's hit is active.
func is_swing_active() -> bool:
	return _swing_active


# --- Helpers ----------------------------------------------------------------------------------

func _now_tick() -> int:
	var estimated: int = _client.get_estimated_server_tick() if is_instance_valid(_client) else 0
	return maxi(estimated, _last_event_tick)


func _local_character() -> PlayerCharacter:
	if is_instance_valid(_character):
		return _character
	if is_instance_valid(_client):
		return _client.get_character()
	return null


func _body_of(net_id: int) -> PlayerCharacter:
	if net_id == 0:
		return null
	if net_id == get_own_net_id():
		return _local_character()
	if not is_instance_valid(_client):
		return null
	var view: RemotePlayerView = _client.get_remote_world().get_view(net_id)
	if view == null:
		return null
	var body: PlayerCharacter = view.get_body()
	return body if is_instance_valid(body) else null
