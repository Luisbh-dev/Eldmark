extends TestCase
## Tests of [BotCheater] (docs/red.md, sections 12 and 16; TEC-46) without network: which extra packets
## each [code]--bot-cheat[/code] mode generates and that they are reproducible with the seed. What the
## server does with them is tested by [code]test_bot_cheat[/code] (in one process) and
## [code]test_net_processes[/code] (with real processes).


## Honest batch of 4 inputs ending at tick [param newest]: moves straight and jumps on the last one.
func _honest_batch(newest: int) -> NetMessages.InputBatch:
	var batch := NetMessages.InputBatch.new()
	batch.ack_snapshot_tick = newest - 20
	batch.interp_delay_q = 32
	batch.newest_tick = newest
	for i: int in 4:
		var input := PlayerInput.new()
		input.tick = newest - 3 + i
		input.move = Vector2(0.0, 1.0)
		input.look_yaw = 1.0
		input.buttons = PlayerInput.JUMP if i == 3 else 0
		batch.inputs.append(input.quantized())
		batch.view_offsets_q.append(40 + i)
	return batch


func test_modes_are_the_documented_ones() -> void:
	assert_eq(BotCheater.MODES, ["version", "future", "dupes", "garbage", "flood", "rewind", "reach",
			"rate", "reuse", "potion", "interact"] as Array[String])
	for mode: String in BotCheater.MODES:
		assert_true(BotCheater.is_valid_mode(mode), "%s is a valid mode" % mode)
	assert_true(BotCheater.is_valid_mode("FLOOD"), "case-insensitive")
	assert_false(BotCheater.is_valid_mode(""), "empty is not a mode")
	assert_false(BotCheater.is_valid_mode("speedhack"), "nor an invented one")


func test_version_mode_only_changes_the_hello() -> void:
	var cheater := BotCheater.new("version", 1)
	var hello := NetMessages.Hello.new()
	cheater.tamper_hello(hello)
	assert_eq(hello.protocol_version, NetProtocol.PROTOCOL_VERSION + 1, "another protocol version")
	assert_true(cheater.extra_packets(_honest_batch(200)).is_empty(), "and sends nothing extra")
	for mode: String in ["future", "dupes", "garbage", "flood"]:
		var other := BotCheater.new(mode, 1)
		var untouched := NetMessages.Hello.new()
		other.tamper_hello(untouched)
		assert_eq(untouched.protocol_version, NetProtocol.PROTOCOL_VERSION,
				"mode %s does not touch the HELLO" % mode)


func test_future_mode_sends_inputs_beyond_the_server_window() -> void:
	var cheater := BotCheater.new("future", 3)
	for tick: int in range(100, 160):
		var packets: Array[BotCheater.Extra] = cheater.extra_packets(_honest_batch(tick))
		if not assert_eq(packets.size(), 1, "one extra batch per tick"):
			return
		assert_eq(packets[0].channel, NetProtocol.CH_INPUT, "over the input channel")
		var batch: NetMessages.InputBatch = NetMessages.InputBatch.decode(packets[0].bytes)
		if not assert_not_null(batch, "it is a well-formed batch"):
			return
		assert_true(batch.newest_tick >= tick + NetProtocol.MAX_INPUT_LEAD_TICKS
				+ BotCheater.FUTURE_MIN_EXTRA_TICKS,
				"the newest tick (%d) goes beyond the server's input window" % batch.newest_tick)
		assert_eq(batch.inputs.size(), BotCheater.EXTRA_BATCH_INPUTS)
		assert_true(batch.inputs[0].tick >= tick + NetProtocol.MAX_INPUT_LEAD_TICKS,
				"so does the oldest")
		assert_true(batch.inputs[0].has(PlayerInput.SPRINT), "sprinting forward")


func test_dupes_mode_repeats_the_ticks_with_different_content() -> void:
	var cheater := BotCheater.new("dupes", 3)
	var honest: NetMessages.InputBatch = _honest_batch(300)
	var packets: Array[BotCheater.Extra] = cheater.extra_packets(honest)
	if not assert_eq(packets.size(), 1, "one copy per tick"):
		return
	var copy: NetMessages.InputBatch = NetMessages.InputBatch.decode(packets[0].bytes)
	if not assert_not_null(copy, "well-formed"):
		return
	assert_eq(copy.newest_tick, honest.newest_tick, "with the same ticks")
	assert_eq(copy.inputs.size(), honest.inputs.size())
	for i: int in honest.inputs.size():
		assert_eq(copy.inputs[i].tick, honest.inputs[i].tick, "tick %d" % i)
		assert_true(copy.inputs[i].move != honest.inputs[i].move, "different movement (%d)" % i)
		assert_true(copy.inputs[i].buttons != honest.inputs[i].buttons, "different buttons (%d)" % i)
		assert_eq(copy.view_offsets_q[i], honest.view_offsets_q[i], "and the same view offset")


func test_garbage_mode_sends_random_bytes_on_both_channels() -> void:
	var cheater := BotCheater.new("garbage", 5)
	var seen_channels: Dictionary = {}
	for tick: int in 100:
		var packets: Array[BotCheater.Extra] = cheater.extra_packets(_honest_batch(100 + tick))
		assert_eq(packets.size(), 2, "two packets per tick")
		for packet: BotCheater.Extra in packets:
			seen_channels[packet.channel] = true
			var size: int = packet.bytes.size()
			assert_true(size >= BotCheater.GARBAGE_MIN_BYTES and size <= BotCheater.GARBAGE_MAX_BYTES,
					"size %d" % size)
			assert_true(size != 2 and size <= NetProtocol.MAX_PACKET_BYTES,
					"never a valid CLIENT_READY or CLIENT_LEAVE nor more than fits")
	assert_true(seen_channels.has(NetProtocol.CH_INPUT) and seen_channels.has(NetProtocol.CH_RELIABLE),
			"over the input channel and the reliable one")
	assert_eq(cheater.get_packets_generated(), 200, "and counts them")


func test_flood_mode_exceeds_the_per_tick_limiter() -> void:
	var cheater := BotCheater.new("flood", 1)
	var honest: NetMessages.InputBatch = _honest_batch(500)
	var packets: Array[BotCheater.Extra] = cheater.extra_packets(honest)
	var input_packets: int = 0
	var reliable_packets: int = 0
	for packet: BotCheater.Extra in packets:
		if packet.channel == NetProtocol.CH_INPUT:
			input_packets += 1
			assert_eq(packet.bytes, honest.encode(), "exact copy of the honest batch")
		else:
			reliable_packets += 1
	assert_eq(input_packets, BotCheater.FLOOD_COPIES_PER_TICK)
	assert_eq(reliable_packets, BotCheater.FLOOD_RELIABLE_PER_TICK)
	assert_true(float(input_packets) > ServerPeer.UNRELIABLE_RATE_PER_TICK,
			"more batches per tick than the limiter recovers")


func test_same_seed_same_traffic() -> void:
	for mode: String in ["future", "garbage"]:
		var a := BotCheater.new(mode, 9)
		var b := BotCheater.new(mode, 9)
		var c := BotCheater.new(mode, 10)
		var differs: bool = false
		for tick: int in range(50, 80):
			var from_a: Array[BotCheater.Extra] = a.extra_packets(_honest_batch(tick))
			var from_b: Array[BotCheater.Extra] = b.extra_packets(_honest_batch(tick))
			var from_c: Array[BotCheater.Extra] = c.extra_packets(_honest_batch(tick))
			for i: int in from_a.size():
				assert_eq(from_a[i].bytes, from_b[i].bytes, "%s: same seed, same bytes" % mode)
				if from_a[i].bytes != from_c[i].bytes:
					differs = true
		assert_true(differs, "%s: another seed, other traffic" % mode)


# --- Combat modes ---------------------------------------------------------------------------

func test_combat_modes_are_the_three_of_phase_3_and_the_three_of_phase_4() -> void:
	assert_eq(BotCheater.COMBAT_MODES, ["rewind", "reach", "rate", "reuse", "potion", "interact"] as Array[String])
	for mode: String in BotCheater.MODES:
		assert_eq(BotCheater.new(mode, 1).is_combat_mode(), BotCheater.COMBAT_MODES.has(mode),
				"%s: only the combat ones change how the bot plays" % mode)


func test_combat_modes_send_no_extra_traffic_and_leave_the_hello_alone() -> void:
	for mode: String in BotCheater.COMBAT_MODES:
		var cheater := BotCheater.new(mode, 4)
		assert_true(cheater.extra_packets(_honest_batch(300)).is_empty(), "%s: not a single extra packet" % mode)
		var hello := NetMessages.Hello.new()
		cheater.tamper_hello(hello)
		assert_eq(hello.protocol_version, NetProtocol.PROTOCOL_VERSION, "%s: the HELLO is the real one" % mode)


func test_rewind_mode_claims_forty_ticks_of_view_in_every_input() -> void:
	var cheater := BotCheater.new("rewind", 2)
	var batch: NetMessages.InputBatch = _honest_batch(300)
	cheater.tamper_batch(batch)
	assert_eq(batch.view_offsets_q.size(), batch.inputs.size(), "there is still an offset per input")
	for offset: int in batch.view_offsets_q:
		assert_eq(offset, 40 * 16, "40 ticks × 16")
	assert_true(BotCheater.REWIND_VIEW_TICKS > NetProtocol.MAX_REWIND_TICKS + 1, "more than the server's cap")
	# What the server decodes is exactly that.
	var decoded: NetMessages.InputBatch = NetMessages.InputBatch.decode(batch.encode())
	assert_eq(decoded.view_offsets_q[0], 640)


func test_other_modes_leave_the_batch_as_it_was() -> void:
	for mode: String in ["version", "future", "dupes", "garbage", "flood", "reach", "rate", "reuse", "potion",
			"interact"]:
		var batch: NetMessages.InputBatch = _honest_batch(300)
		var before: PackedByteArray = batch.encode()
		BotCheater.new(mode, 2).tamper_batch(batch)
		assert_eq(batch.encode(), before, "%s does not touch the batch" % mode)


func test_combat_modes_make_a_brain_and_the_traffic_modes_do_not() -> void:
	var finder: Callable = func(_position: Vector3) -> Variant: return Vector3(0.0, 0.0, -9.0)
	for mode: String in ["version", "future", "dupes", "garbage", "flood"]:
		assert_null(BotCheater.new(mode, 1).make_brain(finder, Vector3.ZERO, 10.0), "%s: no brain" % mode)
	var rewind: BotBrain = BotCheater.new("rewind", 1).make_brain(finder, Vector3.ZERO, 10.0)
	assert_eq(rewind.get_pattern(), BotBrain.Pattern.COMBAT, "rewind fights with the combat brain")
	assert_true(rewind.has_enemy_finder())
	var reach: BotBrain = BotCheater.new("reach", 1).make_brain(finder, Vector3.ZERO, 10.0)
	assert_true(reach is BotCheatBrain and (reach as BotCheatBrain).get_style() == BotCheatBrain.Style.REACH)
	var rate: BotBrain = BotCheater.new("rate", 1).make_brain(finder, Vector3.ZERO, 10.0)
	assert_true(rate is BotCheatBrain and (rate as BotCheatBrain).get_style() == BotCheatBrain.Style.RATE)
	# The phase 4 ones (docs/habilidades.md, section 4.7).
	var styles: Dictionary[String, BotCheatBrain.Style] = {"reuse": BotCheatBrain.Style.REUSE,
			"potion": BotCheatBrain.Style.POTION, "interact": BotCheatBrain.Style.INTERACT}
	for mode: String in styles:
		var brain: BotBrain = BotCheater.new(mode, 1).make_brain(finder, Vector3.ZERO, 10.0)
		assert_true(brain is BotCheatBrain and (brain as BotCheatBrain).get_style() == styles[mode],
				"%s has its own style" % mode)
		assert_true(brain.has_enemy_finder(), "%s knows where the enemies are" % mode)
		assert_false(brain.has_combat_source(), "%s does not use the kit: it plays with its buttons" % mode)
