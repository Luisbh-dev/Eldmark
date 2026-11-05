class_name RemotePlayerView
extends Node
## View of a remote player (docs/networking.md, section 7): drives an instance of
## [code]player_character.tscn[/code] that never calls [method PlayerCharacter.simulate].
## [br][br]
## The body does not collide ([code]collision_layer = 0[/code], [code]collision_mask = 0[/code]), has no
## physics process and does not use physics interpolation. In [method apply] (once per frame, from
## [method RemoteWorld.draw]) [code]global_position[/code], [code]yaw[/code], [code]velocity[/code] and
## [code]grounded[/code] are written to it from the interpolated sample ([RemoteInterpolator]). This way
## the animation layer ([CharacterAnimator]) animates local and remote characters the same: it reads those
## same fields and the signals [signal PlayerCharacter.jumped] and [signal PlayerCharacter.landed], which
## this view emits when it detects the edges between two consecutive frames (taking off upward, or
## touching the ground again).
## [br][br]
## [b]Appearing and disappearing.[/b] The body is shown when the draw instant reaches the
## [code]spawn_tick[/code] and removed when it reaches the [code]despawn_tick[/code]
## ([method schedule_despawn]), not when the message arrives, so that it does not vanish earlier than what
## is seen. Records outside [code][spawn_tick, despawn_tick)[/code] are ignored.
## [br][br]
## [b]Return after extrapolating.[/b] If the draw instant was ahead of the last sample (extrapolation) and
## new data arrives, the jump between what was already drawn and what the data says becomes an offset that
## decays with a half-life of [constant OFFSET_HALF_LIFE] s (real time) if it lies between
## [constant MIN_BLEND_DISTANCE] and [constant MAX_BLEND_DISTANCE] meters; beyond that, or on a
## teleport, it snaps directly.
## [br][br]
## [b]Weapons[/b] (docs/abilities.md, section 5.2; PRG-07): the pair of weapons in slot order comes from
## the SPAWN (and a LOADOUT changes it, [method set_weapons]) and the active slot from bit 3 of
## [code]flags[/code] of the drawn record: [method get_active_weapon_id] is the weapon seen in their hands
## and used for animation.

## Signal that a remote took off going up: minimum vertical velocity (m/s) to consider it a jump and not
## a fall off an edge.
const JUMP_MIN_VELOCITY: float = 2.0
## Jumps smaller than this (m) when data returns are ignored.
const MIN_BLEND_DISTANCE: float = 0.05
## Jumps larger than this (m) when data returns are applied at once.
const MAX_BLEND_DISTANCE: float = 1.5
## Half-life (s) of the return offset after extrapolating (real time).
const OFFSET_HALF_LIFE: float = 0.1
## Below this length (m) the offset is cancelled.
const MIN_OFFSET: float = 0.001

var _body: PlayerCharacter = null
var _interpolator: RemoteInterpolator = RemoteInterpolator.new()
var _net_id: int = 0
var _kind: int = NetProtocol.EntityKind.PLAYER
var _display_name: String = ""
var _npc_def_id: int = 0
var _realm: int = NetProtocol.Realm.NONE
var _spawn_tick: int = 0
var _despawn_tick: int = -1
var _drawn_position: Vector3 = Vector3.ZERO
# Offset (world) added to the interpolated sample and decaying on every apply().
var _offset: Vector3 = Vector3.ZERO
var _has_drawn: bool = false
var _drawn_visible: bool = false
var _was_grounded: bool = true
var _last_render_time: float = 0.0
# Position of the sample (without offset) and teleport counter of the last apply().
var _last_sample_position: Vector3 = Vector3.ZERO
var _last_teleport: int = 0
var _extrapolating: bool = false
var _jumped_count: int = 0
var _landed_count: int = 0
# Action byte (action, phase and combo step or reset counter) and quantized health of the last drawn record.
var _drawn_action: int = 0
var _drawn_health_q: int = EntityRecord.HEALTH_Q_FULL
# Weapons in slot order (0 = none) and whether the drawn record has slot 2 active.
var _weapon_1: int = 0
var _weapon_2: int = 0
var _drawn_second_slot: bool = false
# Level (protocol 7): the SPAWN's (0 if the remote belongs to another realm) or that of its last LEVEL_UP.
var _level: int = 0
# The 8 B of appearance from the SPAWN (protocol 7; unvalidated).
var _appearance: PackedByteArray = PackedByteArray()


## Takes control of [param body] (a freshly instantiated [PlayerCharacter]) and sets the SPAWN's state as
## its first sample. If the body has not yet entered the tree, the configuration that disables its
## collisions is applied when it is ready (its [code]_ready()[/code] enables them).
func setup(body: PlayerCharacter, spawn: NetMessages.EntitySpawn) -> void:
	_body = body
	_net_id = spawn.net_id
	_kind = spawn.kind
	_display_name = spawn.display_name
	_npc_def_id = spawn.npc_def_id
	_realm = spawn.realm
	_spawn_tick = spawn.spawn_tick
	_despawn_tick = -1
	_level = spawn.level
	_appearance = spawn.appearance.duplicate()
	if body.is_node_ready():
		_configure_body()
	else:
		body.ready.connect(_configure_body, CONNECT_ONE_SHOT)
	# Hidden until the draw instant reaches the spawn tick.
	body.visible = false
	body.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	var first: EntityRecord = EntityRecord.from_state(spawn.net_id, spawn.kind, spawn.state,
			spawn.teleport_counter)
	_interpolator.push(spawn.spawn_tick, first)
	_place(first)
	_last_teleport = first.get_teleport_counter()
	_last_sample_position = first.position
	_was_grounded = first.is_grounded()
	_drawn_action = first.action
	_drawn_health_q = first.health_q
	_drawn_second_slot = first.is_second_slot()
	var combat: CombatState = spawn.state.combat
	if combat.is_second_slot():
		set_weapons(combat.alt_weapon_id, combat.weapon_id)
	else:
		set_weapons(combat.weapon_id, combat.alt_weapon_id)


## Stores the sample of snapshot [param tick]. Ignored if it falls outside
## [code][spawn_tick, despawn_tick)[/code]. If the remote was extrapolating, the jump between what was
## already drawn and what the new data says is spread into an offset (see the class description).
func push(tick: int, record: EntityRecord) -> void:
	if not accepts_tick(tick):
		return
	var was_extrapolating: bool = _extrapolating and _has_drawn
	_interpolator.push(tick, record)
	if not was_extrapolating:
		return
	var corrected: EntityRecord = _interpolator.sample(_last_render_time)
	if corrected == null:
		return
	if corrected.get_teleport_counter() != _last_teleport:
		_offset = Vector3.ZERO
		return
	var jump: Vector3 = _last_sample_position - corrected.position
	var distance: float = jump.length()
	if distance > MAX_BLEND_DISTANCE:
		_offset = Vector3.ZERO
	elif distance > MIN_BLEND_DISTANCE:
		_offset += jump
	# What was already drawn no longer changes: the reference for the next comparison is the new data.
	_last_sample_position = corrected.position
	_extrapolating = _last_render_time > float(_interpolator.get_newest_tick())


## Draws the remote at instant [param render_time] (ticks with fraction): shows or hides the body
## according to [code]spawn_tick[/code] and [code]despawn_tick[/code], writes its position, yaw,
## velocity and ground state, and emits [signal PlayerCharacter.jumped] and
## [signal PlayerCharacter.landed] when there is an edge. [param real_delta] (real seconds) decays the
## return offset.
func apply(render_time: float, real_delta: float) -> void:
	if not is_instance_valid(_body):
		return
	var should_show: bool = render_time >= float(_spawn_tick) and not is_expired(render_time)
	if should_show != _drawn_visible:
		_drawn_visible = should_show
		_body.visible = should_show
	_last_render_time = render_time
	var record: EntityRecord = _interpolator.sample(render_time)
	if record == null:
		return
	_extrapolating = render_time > float(_interpolator.get_newest_tick())
	_decay_offset(real_delta)
	if record.get_teleport_counter() != _last_teleport:
		_offset = Vector3.ZERO
	_last_teleport = record.get_teleport_counter()
	_last_sample_position = record.position
	_drawn_action = record.action
	_drawn_health_q = record.health_q
	_drawn_second_slot = record.is_second_slot()
	_place(record)
	if _has_drawn and should_show:
		_emit_flanks(record)
	_was_grounded = record.is_grounded()
	_has_drawn = true


## Schedules the despawn: the remote is removed when the draw instant reaches [param tick]. Records from
## that tick onward are ignored.
func schedule_despawn(tick: int) -> void:
	_despawn_tick = tick


## true if the draw instant [param render_time] has already reached the despawn tick.
func is_expired(render_time: float) -> bool:
	return _despawn_tick >= 0 and render_time >= float(_despawn_tick)


## Global position drawn in the last [method apply] (with the return offset).
func get_drawn_position() -> Vector3:
	return _drawn_position


## Position of each stored sample of the remote, not interpolated (to mark them in debugging).
func get_sample_positions() -> PackedVector3Array:
	return _interpolator.get_sample_positions()


## true if the record of tick [param tick] belongs to this view: it is not earlier than the spawn nor
## later than (or equal to) the scheduled despawn.
func accepts_tick(tick: int) -> bool:
	return tick >= _spawn_tick and (_despawn_tick < 0 or tick < _despawn_tick)


## true if the despawn has already been scheduled.
func is_despawn_scheduled() -> bool:
	return _despawn_tick >= 0


## Body governed by the view.
func get_body() -> PlayerCharacter:
	return _body


func get_net_id() -> int:
	return _net_id


func get_kind() -> int:
	return _kind


func get_display_name() -> String:
	return _display_name


## Id of the NPC definition from the SPAWN (0 for a player or an NPC without a definition): with it you
## can tell whether it is a boss ([BossInfo]).
func get_npc_def_id() -> int:
	return _npc_def_id


func get_realm() -> int:
	return _realm


func get_spawn_tick() -> int:
	return _spawn_tick


## Scheduled despawn tick, or -1.
func get_despawn_tick() -> int:
	return _despawn_tick


## true if the body is being shown (it has already reached its spawn and not yet its despawn).
func is_drawn() -> bool:
	return _drawn_visible


## [code]action[/code] byte of the drawn record (docs/combat.md, section 3.4: bits 0-3 the action, 4-5
## the phase and 6-7 the combo step or reset counter; [ActionWire]). Read by the remote's combat
## animator.
func get_drawn_action() -> int:
	return _drawn_action


## Quantized health ([method EntityRecord.quantize_health]) of the drawn record: 0 dead, 1-255 alive.
## Read by the nameplates.
func get_drawn_health_q() -> int:
	return _drawn_health_q


## Level of the remote (docs/progression.md §7.3): that of its SPAWN or its last LEVEL_UP; 0 if it belongs
## to another realm (the enemy's level does not cross over) or the zone has no progression.
func get_level() -> int:
	return _level


## A LEVEL_UP of the remote (already at its draw tick): its new level.
func set_level(level: int) -> void:
	_level = clampi(level, 0, ProgressMessages.MAX_LEVEL)


## The 8 B of appearance from its SPAWN, exactly as they arrived (validated by
## [method AppearanceApplier.resolve]).
func get_appearance() -> PackedByteArray:
	return _appearance


## The remote's pair of weapons in slot order ([param weapon_1] is slot 1's; 0 = none): the SPAWN's or
## that of a LOADOUT.
func set_weapons(weapon_1: int, weapon_2: int) -> void:
	_weapon_1 = weapon_1
	_weapon_2 = weapon_2


## Weapons in slot order (x is slot 1, y is slot 2).
func get_weapons() -> Vector2i:
	return Vector2i(_weapon_1, _weapon_2)


## true if the drawn record has slot 2 active (bit 3 of [code]flags[/code]).
func is_drawn_second_slot() -> bool:
	return _drawn_second_slot


## Weapon held in its hands according to what is drawn: slot 2's if its bit is set (and it has one),
## otherwise slot 1's.
func get_active_weapon_id() -> int:
	if _drawn_second_slot and _weapon_2 != 0:
		return _weapon_2
	return _weapon_1


## Return offset after extrapolating that is currently added to the sample (m, in the world).
func get_blend_offset() -> Vector3:
	return _offset


## Number of jumps and landings it has emitted.
func get_jumped_count() -> int:
	return _jumped_count


func get_landed_count() -> int:
	return _landed_count


## Samples stored by the interpolator.
func get_interpolator() -> RemoteInterpolator:
	return _interpolator


# No collisions, no physics process and no physics interpolation: the body is only drawn.
func _configure_body() -> void:
	if not is_instance_valid(_body):
		return
	_body.collision_layer = 0
	_body.collision_mask = 0
	_body.set_physics_process(false)
	_body.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF


# Writes to the body what the other layers read: position, yaw, velocity and ground state.
func _place(record: EntityRecord) -> void:
	var position: Vector3 = record.position + _offset
	_drawn_position = position
	if _body.is_inside_tree():
		_body.global_position = position
	else:
		_body.position = position
	_body.yaw = record.yaw
	_body.velocity = record.velocity
	_body.grounded = record.is_grounded()


func _decay_offset(real_delta: float) -> void:
	if _offset == Vector3.ZERO:
		return
	_offset *= pow(0.5, maxf(real_delta, 0.0) / OFFSET_HALF_LIFE)
	if _offset.length() < MIN_OFFSET:
		_offset = Vector3.ZERO


# Taking off going up is a jump; returning to the ground is a landing. Falling off an edge (taking off
# without going up) is not a jump: the animation infers it from the change in "grounded".
func _emit_flanks(record: EntityRecord) -> void:
	var grounded: bool = record.is_grounded()
	if _was_grounded and not grounded and record.velocity.y > JUMP_MIN_VELOCITY:
		_jumped_count += 1
		_body.jumped.emit()
	elif not _was_grounded and grounded:
		_landed_count += 1
		_body.landed.emit()
