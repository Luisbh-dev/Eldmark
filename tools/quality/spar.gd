extends RefCounted
## Quality capture bench (TEC-50): the capture client as a sparring partner.
##
## Drives the client's character with [code]Input.action_press[/code] against an enemy, so that it really fights
## the NPCs and bots while the scenarios record. Modes ([member mode]):
## [br]- [code]fight[/code]: approaches, attacks with light attacks and now and then uses an ability, dodges or blocks.
## [br]- [code]heavy[/code]: approaches and throws charged heavy attacks (they knock down and stagger).
## [br]- [code]tank[/code]: stays in front with the shield up, without attacking (to see hits received while blocking).
## [br]- [code]idle[/code]: looks at the enemy doing nothing, takes the hits.
## [br]- [code]kite[/code]: backs away looking at the enemy (so that it runs after).
## [br]- [code]observe[/code]: moves away to about 5 m and stands still watching (to see someone fall or die without
## having them on top).
## [br]- [code]execute[/code]: approaches a knocked-down player and holds INTERACT to finish them off.
## [method step] is called once per frame. The camera points [member look_offset_deg] degrees to the left of the
## enemy: with the over-the-shoulder camera, this way the enemy ends up right of center and the client's body,
## which is in the foreground on the left, does not block it in the strips.

## Points (x, z) in front of the Solmarch camp, outside its safe zone (about 30 m from its center) and in view of the
## combat bot (40 m), to meet it: [code]online_driver.open_spot[/code] picks the most open one.
const MEET_CANDIDATES: Array = [Vector2(0.0, 105.0), Vector2(30.0, 100.0), Vector2(-30.0, 100.0), Vector2(55.0, 104.0),
		Vector2(-55.0, 104.0), Vector2(15.0, 92.0), Vector2(-15.0, 92.0), Vector2(75.0, 100.0), Vector2(-75.0, 100.0)]

var mode: String = "fight"
## With [code]true[/code], the [code]fight[/code] mode uses no abilities or dodge (only light attacks and the occasional block).
var plain: bool = false
## Degrees the camera is offset to the left of the enemy (see above).
var look_offset_deg: float = 24.0
## Distance (m) it stays at in [code]observe[/code] mode.
var observe_distance: float = 5.0
## Separation (m) it keeps in melee: it approaches if it is further than [member melee_max] and backs off if it is
## closer than [member melee_min], so that the bodies do not overlap (with the over-the-shoulder camera, an
## enemy right up close ends up behind the character and the strips show nothing). The sword reaches 2.6 m, so hitting works fine like this.
var melee_min: float = 1.5
var melee_max: float = 2.4

var _d: Variant
var _rng := RandomNumberGenerator.new()
var _next_attack_ms: int = 0
var _next_special_ms: int = 0
var _block_until_ms: int = 0
var _heavy_until_ms: int = 0
var _held_primary: bool = false


func _init(driver: Variant, seed_value: int = 7) -> void:
	_d = driver
	_rng.seed = seed_value
	_next_special_ms = Time.get_ticks_msec() + 2500


func set_mode(new_mode: String) -> void:
	if new_mode != mode:
		_release_all()
	mode = new_mode


## One frame of sparring against the enemy at [param enemy_pos]: looks towards it and does what is due according to the mode.
func step(enemy_pos: Vector3) -> void:
	var now: int = Time.get_ticks_msec()
	var p: Vector3 = _d.pos()
	var dist: float = Vector2(enemy_pos.x - p.x, enemy_pos.z - p.z).length()
	# The camera offset only applies in melee (close and not walking towards the enemy): when approaching, backing off
	# or stepping aside, the character walks where the camera looks and a skewed camera would divert it.
	var offset: float = look_offset_deg if (dist <= 5.0 and mode != "kite" and mode != "observe") else 0.0
	_d.look(_d.yaw_to(p.x, p.z, enemy_pos.x, enemy_pos.z) + offset, 6.0)
	match mode:
		"observe":
			_d.release(&"move_forward")
			_d.release(&"block")
			if dist < observe_distance:
				_d.hold(&"move_back")
			else:
				_d.release(&"move_back")
		"idle":
			_d.release(&"move_forward")
			_d.release(&"move_back")
		"kite":
			_d.release(&"move_forward")
			if dist < 14.0:
				_d.hold(&"move_back")
			else:
				_d.release(&"move_back")
		"tank":
			_keep_spacing(dist, melee_min, melee_max)
			_d.hold(&"block")
		"heavy":
			_keep_spacing(dist, melee_min, melee_max)
			if dist <= 2.8:
				if _held_primary and now >= _heavy_until_ms:
					_d.release(&"primary_attack")
					_held_primary = false
					_next_attack_ms = now + 1400
				elif not _held_primary and now >= _next_attack_ms:
					_d.hold(&"primary_attack")
					_held_primary = true
					_heavy_until_ms = now + 900
		"execute":
			_approach(dist, 1.6)
			_d.hold(&"interact")
		_:
			_fight(now, dist)


func stop() -> void:
	_release_all()


func _release_all() -> void:
	for action: StringName in [&"move_forward", &"move_back", &"sprint", &"block", &"primary_attack", &"interact"]:
		_d.release(action)
	_held_primary = false


func _approach(dist: float, stop_at: float) -> void:
	if dist > stop_at + 0.4:
		_d.hold(&"move_forward")
		if dist > 10.0:
			_d.hold(&"sprint")
		else:
			_d.release(&"sprint")
	else:
		_d.release(&"move_forward")
		_d.release(&"sprint")


# Approaches if far, backs off if too close and stands still between the two distances.
func _keep_spacing(dist: float, min_d: float, max_d: float) -> void:
	if dist > max_d:
		_d.release(&"move_back")
		_d.hold(&"move_forward")
		if dist > 10.0:
			_d.hold(&"sprint")
		else:
			_d.release(&"sprint")
	elif dist < min_d:
		_d.release(&"move_forward")
		_d.release(&"sprint")
		_d.hold(&"move_back")
	else:
		_d.release(&"move_forward")
		_d.release(&"move_back")
		_d.release(&"sprint")


func _fight(now: int, dist: float) -> void:
	_keep_spacing(dist, melee_min, melee_max)
	if dist > melee_max:
		return
	if now < _block_until_ms:
		return
	_d.release(&"block")
	if now >= _next_special_ms:
		var pick: int = _rng.randi() % (2 if plain else 5)
		match pick:
			0:
				if plain:
					_block_for(now, 900)
				else:
					_d.tap(&"ability_1", 3)
			1:
				_block_for(now, 900)
			2:
				_d.tap(&"ability_2", 3)
			3:
				_d.tap(&"dodge", 3)
			_:
				_block_for(now, 900)
		_next_special_ms = now + 2200 + _rng.randi() % 1500
	elif now >= _next_attack_ms:
		_d.tap(&"primary_attack", 3)
		_next_attack_ms = now + 420


func _block_for(now: int, ms: int) -> void:
	_d.hold(&"block")
	_block_until_ms = now + ms
