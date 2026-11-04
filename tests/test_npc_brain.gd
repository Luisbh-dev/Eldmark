extends TestCase
## Tests of [NpcBrain] (the training dummy: standing still, blocking or turning), of the
## [constant BotBrain.Pattern.COMBAT] pattern of [BotBrain] (finds the enemy, approaches, attacks,
## blocks and dodges, with a seed) and of [ServerConsole] (the standard input line queue).


# --- NpcBrain ---------------------------------------------------------------------------------

func test_still_mode_does_nothing_and_keeps_its_yaw() -> void:
	var brain := NpcBrain.new(NpcBrain.Mode.STILL)
	for tick: int in range(1, 200):
		var input: PlayerInput = brain.next_input(tick, Vector3.ZERO, 1.25)
		assert_eq(input.tick, tick)
		assert_eq(input.buttons, 0)
		assert_eq(input.move, Vector2.ZERO)
		assert_near(input.look_yaw, 1.25, 1e-6)


func test_block_mode_holds_block() -> void:
	var brain := NpcBrain.new(NpcBrain.Mode.BLOCK)
	for tick: int in range(1, 50):
		var input: PlayerInput = brain.next_input(tick, Vector3.ZERO, 0.0)
		assert_eq(input.buttons, PlayerInput.BLOCK)
		assert_eq(input.move, Vector2.ZERO)


func test_spin_mode_turns_a_full_circle_every_period_while_moving_just_enough_to_turn() -> void:
	var brain := NpcBrain.new(NpcBrain.Mode.SPIN)
	var first: PlayerInput = brain.next_input(100, Vector3.ZERO, 2.0)
	assert_near(first.look_yaw, 2.0, 1e-6, "starts where it was")
	assert_true(first.move.length() > PlayerCharacter.FACING_MIN_WISH,
			"it moves just enough for the character to turn toward the camera")
	assert_true(first.move.length() < 0.2, "but hardly anything")
	assert_eq(first.buttons, 0)
	var quarter: PlayerInput = brain.next_input(100 + (NpcBrain.SPIN_PERIOD_TICKS >> 2),
			Vector3.ZERO, 2.0)
	assert_near(angle_difference(first.look_yaw, quarter.look_yaw), -PI / 2.0, 1e-4,
			"a quarter turn")
	var full: PlayerInput = brain.next_input(100 + NpcBrain.SPIN_PERIOD_TICKS, Vector3.ZERO, 2.0)
	assert_near(angle_difference(first.look_yaw, full.look_yaw), 0.0, 1e-4, "a full turn")


func test_mode_names_round_trip() -> void:
	for mode: int in [NpcBrain.Mode.STILL, NpcBrain.Mode.BLOCK, NpcBrain.Mode.SPIN]:
		assert_eq(NpcBrain.mode_from_name(NpcBrain.mode_name(mode)), mode)
	assert_eq(NpcBrain.mode_from_name("BLOCK"), NpcBrain.Mode.BLOCK)
	assert_eq(NpcBrain.mode_from_name(" Girando "), NpcBrain.Mode.SPIN)
	assert_eq(NpcBrain.mode_from_name("volando"), -1)


func test_a_spinning_dummy_really_turns_in_the_world() -> void:
	var viewport: SubViewport = CombatFixture.make_world(tree.root)
	var world: Node3D = NetHarness.get_world(viewport)
	var character: PlayerCharacter = CombatFixture.make_character(world, Vector3(0.0, 0.05, 0.0), 0.0)
	await wait_physics_frames(3)
	var brain := NpcBrain.new(NpcBrain.Mode.SPIN)
	var start: Vector3 = character.global_position
	var yaw_start: float = character.yaw
	var tick: int = 1
	for _step: int in 90:
		var input: PlayerInput = brain.next_input(tick, character.global_position, character.yaw)
		character.simulate(input.quantized(), 1.0 / 60.0)
		tick += 1
		await tree.physics_frame
	# In 1.5 s it makes a quarter turn and hardly moves.
	assert_true(absf(angle_difference(character.yaw, yaw_start)) > 1.0, "turns")
	assert_true(character.global_position.distance_to(start) < 1.5, "without moving away")
	viewport.get_parent().remove_child(viewport)
	viewport.free()


# --- BotBrain COMBAT --------------------------------------------------------------------------

func _finder(target: Variant) -> Callable:
	return func(_position: Vector3) -> Variant: return target


func test_combat_without_a_finder_wanders_like_the_walker() -> void:
	var brain := BotBrain.new(5, BotBrain.Pattern.COMBAT, Vector3.ZERO, 20.0)
	assert_eq(brain.get_pattern(), BotBrain.Pattern.COMBAT)
	assert_false(brain.has_enemy_finder())
	var moved: int = 0
	for tick: int in range(1, 400):
		var input: PlayerInput = brain.next_input(tick, Vector3.ZERO, 0.0)
		assert_eq(input.buttons & (PlayerInput.PRIMARY | PlayerInput.BLOCK | PlayerInput.DODGE), 0,
				"without an enemy it does not fight")
		if input.move != Vector2.ZERO:
			moved += 1
	assert_true(moved > 100, "it wanders (%d ticks running)" % moved)


func test_combat_walks_to_the_enemy_and_sprints_when_far() -> void:
	var brain := BotBrain.new(5, BotBrain.Pattern.COMBAT, Vector3.ZERO, 20.0)
	brain.set_enemy_finder(_finder(Vector3(0.0, 0.0, -20.0)))
	assert_true(brain.has_enemy_finder())
	var input: PlayerInput = brain.next_input(1, Vector3.ZERO, 1.0)
	assert_near(angle_difference(input.look_yaw, 0.0), 0.0, 1e-4, "looks at the enemy (toward -Z)")
	assert_eq(input.move, Vector2(0.0, 1.0), "advances")
	assert_true(input.has(PlayerInput.SPRINT), "sprints from afar")
	input = brain.next_input(2, Vector3(0.0, 0.0, -14.0), 0.0)
	assert_false(input.has(PlayerInput.SPRINT), "within 8 m it no longer does")
	assert_eq(input.move, Vector2(0.0, 1.0))
	# An enemy to the east: yaw of -90° (-X is yaw 90°; +X is -90°).
	var east := BotBrain.new(6, BotBrain.Pattern.COMBAT, Vector3.ZERO, 20.0)
	east.set_enemy_finder(_finder(Vector3(10.0, 0.0, 0.0)))
	assert_near(angle_difference(east.next_input(1, Vector3.ZERO, 0.0).look_yaw, -PI / 2.0), 0.0, 1e-4)


func test_combat_ignores_enemies_beyond_sight() -> void:
	var brain := BotBrain.new(5, BotBrain.Pattern.COMBAT, Vector3.ZERO, 20.0)
	brain.set_enemy_finder(_finder(Vector3(0.0, 0.0, -(BotBrain.COMBAT_SIGHT_RANGE + 5.0))))
	var buttons: int = 0
	for tick: int in range(1, 300):
		buttons |= brain.next_input(tick, Vector3.ZERO, 0.0).buttons \
				& (PlayerInput.PRIMARY | PlayerInput.BLOCK | PlayerInput.DODGE)
	assert_eq(buttons, 0, "too far away to fight")


func test_combat_stops_at_attack_distance_and_fights_with_every_action() -> void:
	var brain := BotBrain.new(9, BotBrain.Pattern.COMBAT, Vector3.ZERO, 20.0)
	brain.set_enemy_finder(_finder(Vector3(0.0, 0.0, -1.5)))
	var seen: int = 0
	var longest_primary: int = 0
	var primary_run: int = 0
	var tap_lengths: Array[int] = []
	var dodge_moves: Array[Vector2] = []
	for tick: int in range(1, 3000):
		var input: PlayerInput = brain.next_input(tick, Vector3.ZERO, 0.0)
		seen |= input.buttons
		assert_true(absf(angle_difference(input.look_yaw, 0.0)) < 1e-4, "always looking at the enemy")
		if input.has(PlayerInput.PRIMARY):
			primary_run += 1
		elif primary_run > 0:
			tap_lengths.append(primary_run)
			longest_primary = maxi(longest_primary, primary_run)
			primary_run = 0
		if input.has(PlayerInput.DODGE):
			dodge_moves.append(input.move)
		if not input.has(PlayerInput.PRIMARY | PlayerInput.BLOCK | PlayerInput.DODGE):
			assert_eq(input.move, Vector2.ZERO, "it is already within striking distance: it does not advance")
	assert_true((seen & PlayerInput.PRIMARY) != 0, "attacks")
	assert_true((seen & PlayerInput.BLOCK) != 0, "blocks sometimes")
	assert_true((seen & PlayerInput.DODGE) != 0, "dodges sometimes")
	assert_true(longest_primary >= 24, "sometimes it holds the attack to charge a heavy one (%d)" % longest_primary)
	assert_true(tap_lengths.has(BotBrain.COMBAT_TAP_TICKS), "and almost always taps for %d ticks"
			% BotBrain.COMBAT_TAP_TICKS)
	for move: Vector2 in dodge_moves:
		assert_true(move != Vector2.ZERO, "the dodge has a direction")


func test_combat_is_deterministic_with_the_seed() -> void:
	var first := BotBrain.new(77, BotBrain.Pattern.COMBAT, Vector3.ZERO, 20.0)
	var second := BotBrain.new(77, BotBrain.Pattern.COMBAT, Vector3.ZERO, 20.0)
	var other := BotBrain.new(78, BotBrain.Pattern.COMBAT, Vector3.ZERO, 20.0)
	for brain: BotBrain in [first, second, other]:
		brain.set_enemy_finder(_finder(Vector3(0.0, 0.0, -1.5)))
	var differs: bool = false
	for tick: int in range(1, 1500):
		var a: PlayerInput = first.next_input(tick, Vector3.ZERO, 0.0)
		var b: PlayerInput = second.next_input(tick, Vector3.ZERO, 0.0)
		var c: PlayerInput = other.next_input(tick, Vector3.ZERO, 0.0)
		assert_eq(a.buttons, b.buttons, "same seed, same buttons (tick %d)" % tick)
		assert_eq(a.move, b.move)
		if a.buttons != c.buttons:
			differs = true
	assert_true(differs, "another seed fights differently")


func test_combat_target_is_refreshed_only_every_few_ticks() -> void:
	var brain := BotBrain.new(5, BotBrain.Pattern.COMBAT, Vector3.ZERO, 20.0)
	var calls: Array[int] = [0]
	brain.set_enemy_finder(func(_position: Vector3) -> Variant:
		calls[0] += 1
		return Vector3(0.0, 0.0, -10.0))
	for tick: int in range(1, 41):
		brain.next_input(tick, Vector3.ZERO, 0.0)
	assert_eq(calls[0], 10, "it searches every %d ticks, not on all of them" % BotBrain.COMBAT_RETARGET_TICKS)


# --- ServerConsole ----------------------------------------------------------------------------

func test_console_queue_takes_lines_in_order_and_ignores_blank_ones() -> void:
	var console := ServerConsole.new()
	assert_eq(console.take_lines(), PackedStringArray())
	console.push_line("kick Ana")
	console.push_line("   ")
	console.push_line("")
	console.push_line("  announce hola  ")
	assert_eq(console.take_lines(), PackedStringArray(["kick Ana", "announce hola"]))
	assert_eq(console.take_lines(), PackedStringArray(), "the queue ends up empty")
	assert_false(console.is_running(), "without starting the thread there is no reader")
	assert_false(console.has_reached_eof())


func test_console_queue_is_bounded() -> void:
	var console := ServerConsole.new()
	for index: int in ServerConsole.MAX_PENDING_LINES + 30:
		console.push_line("kick %d" % index)
	var lines: PackedStringArray = console.take_lines()
	assert_eq(lines.size(), ServerConsole.MAX_PENDING_LINES, "the excess is discarded")
	assert_eq(lines[0], "kick 0")


## On Windows a stdin read can bring several lines together (a pipe that sends them all at once):
## the console splits them instead of running the whole text as a single command.
func test_console_splits_a_read_with_several_lines() -> void:
	var console := ServerConsole.new()
	console.push_text("help\nplayers\r\nannounce Hola a todos\n\nshutdown 1")
	assert_eq(console.take_lines(), PackedStringArray(
			["help", "players", "announce Hola a todos", "shutdown 1"]),
			"one line per command (LF and CRLF), without empty ones")
	console.push_text("kick Ana")
	assert_eq(console.take_lines(), PackedStringArray(["kick Ana"]), "and a single line is still valid")
	console.push_text("")
	assert_eq(console.take_lines(), PackedStringArray(), "an empty text adds nothing")
