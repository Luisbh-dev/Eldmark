extends TestCase
## Pruebas de [BotCheater] (docs/red.md, secciones 12 y 16; TEC-46) sin red: qué paquetes de más
## genera cada modo de [code]--bot-cheat[/code] y que son reproducibles con la semilla. Lo que hace el
## servidor con ellos lo prueban [code]test_bot_cheat[/code] (en un proceso) y
## [code]test_net_processes[/code] (con procesos de verdad).


## Lote honrado de 4 entradas que acaba en el tick [param newest]: avanza recto y salta en la última.
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
		assert_true(BotCheater.is_valid_mode(mode), "%s es un modo válido" % mode)
	assert_true(BotCheater.is_valid_mode("FLOOD"), "sin distinguir mayúsculas")
	assert_false(BotCheater.is_valid_mode(""), "vacío no es un modo")
	assert_false(BotCheater.is_valid_mode("speedhack"), "ni uno inventado")


func test_version_mode_only_changes_the_hello() -> void:
	var cheater := BotCheater.new("version", 1)
	var hello := NetMessages.Hello.new()
	cheater.tamper_hello(hello)
	assert_eq(hello.protocol_version, NetProtocol.PROTOCOL_VERSION + 1, "otra versión del protocolo")
	assert_true(cheater.extra_packets(_honest_batch(200)).is_empty(), "y no envía nada de más")
	for mode: String in ["future", "dupes", "garbage", "flood"]:
		var other := BotCheater.new(mode, 1)
		var untouched := NetMessages.Hello.new()
		other.tamper_hello(untouched)
		assert_eq(untouched.protocol_version, NetProtocol.PROTOCOL_VERSION,
				"el modo %s no toca el HELLO" % mode)


func test_future_mode_sends_inputs_beyond_the_server_window() -> void:
	var cheater := BotCheater.new("future", 3)
	for tick: int in range(100, 160):
		var packets: Array[BotCheater.Extra] = cheater.extra_packets(_honest_batch(tick))
		if not assert_eq(packets.size(), 1, "un lote de más por tick"):
			return
		assert_eq(packets[0].channel, NetProtocol.CH_INPUT, "por el canal de entradas")
		var batch: NetMessages.InputBatch = NetMessages.InputBatch.decode(packets[0].bytes)
		if not assert_not_null(batch, "es un lote bien formado"):
			return
		assert_true(batch.newest_tick >= tick + NetProtocol.MAX_INPUT_LEAD_TICKS
				+ BotCheater.FUTURE_MIN_EXTRA_TICKS,
				"el tick más nuevo (%d) pasa de la ventana de entradas del servidor" % batch.newest_tick)
		assert_eq(batch.inputs.size(), BotCheater.EXTRA_BATCH_INPUTS)
		assert_true(batch.inputs[0].tick >= tick + NetProtocol.MAX_INPUT_LEAD_TICKS,
				"también el más antiguo")
		assert_true(batch.inputs[0].has(PlayerInput.SPRINT), "esprintando hacia delante")


func test_dupes_mode_repeats_the_ticks_with_different_content() -> void:
	var cheater := BotCheater.new("dupes", 3)
	var honest: NetMessages.InputBatch = _honest_batch(300)
	var packets: Array[BotCheater.Extra] = cheater.extra_packets(honest)
	if not assert_eq(packets.size(), 1, "una copia por tick"):
		return
	var copy: NetMessages.InputBatch = NetMessages.InputBatch.decode(packets[0].bytes)
	if not assert_not_null(copy, "bien formada"):
		return
	assert_eq(copy.newest_tick, honest.newest_tick, "con los mismos ticks")
	assert_eq(copy.inputs.size(), honest.inputs.size())
	for i: int in honest.inputs.size():
		assert_eq(copy.inputs[i].tick, honest.inputs[i].tick, "tick %d" % i)
		assert_true(copy.inputs[i].move != honest.inputs[i].move, "otro movimiento (%d)" % i)
		assert_true(copy.inputs[i].buttons != honest.inputs[i].buttons, "otros botones (%d)" % i)
		assert_eq(copy.view_offsets_q[i], honest.view_offsets_q[i], "y el mismo desfase de vista")


func test_garbage_mode_sends_random_bytes_on_both_channels() -> void:
	var cheater := BotCheater.new("garbage", 5)
	var seen_channels: Dictionary = {}
	for tick: int in 100:
		var packets: Array[BotCheater.Extra] = cheater.extra_packets(_honest_batch(100 + tick))
		assert_eq(packets.size(), 2, "dos paquetes por tick")
		for packet: BotCheater.Extra in packets:
			seen_channels[packet.channel] = true
			var size: int = packet.bytes.size()
			assert_true(size >= BotCheater.GARBAGE_MIN_BYTES and size <= BotCheater.GARBAGE_MAX_BYTES,
					"tamaño %d" % size)
			assert_true(size != 2 and size <= NetProtocol.MAX_PACKET_BYTES,
					"nunca un CLIENT_READY o CLIENT_LEAVE válido ni más de lo que cabe")
	assert_true(seen_channels.has(NetProtocol.CH_INPUT) and seen_channels.has(NetProtocol.CH_RELIABLE),
			"por el canal de entradas y por el fiable")
	assert_eq(cheater.get_packets_generated(), 200, "y los cuenta")


func test_flood_mode_exceeds_the_per_tick_limiter() -> void:
	var cheater := BotCheater.new("flood", 1)
	var honest: NetMessages.InputBatch = _honest_batch(500)
	var packets: Array[BotCheater.Extra] = cheater.extra_packets(honest)
	var input_packets: int = 0
	var reliable_packets: int = 0
	for packet: BotCheater.Extra in packets:
		if packet.channel == NetProtocol.CH_INPUT:
			input_packets += 1
			assert_eq(packet.bytes, honest.encode(), "copia exacta del lote honrado")
		else:
			reliable_packets += 1
	assert_eq(input_packets, BotCheater.FLOOD_COPIES_PER_TICK)
	assert_eq(reliable_packets, BotCheater.FLOOD_RELIABLE_PER_TICK)
	assert_true(float(input_packets) > ServerPeer.UNRELIABLE_RATE_PER_TICK,
			"más lotes por tick de los que recupera el limitador")


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
				assert_eq(from_a[i].bytes, from_b[i].bytes, "%s: misma semilla, mismos bytes" % mode)
				if from_a[i].bytes != from_c[i].bytes:
					differs = true
		assert_true(differs, "%s: otra semilla, otro tráfico" % mode)


# --- Modos de combate ---------------------------------------------------------------------------

func test_combat_modes_are_the_three_of_phase_3_and_the_three_of_phase_4() -> void:
	assert_eq(BotCheater.COMBAT_MODES, ["rewind", "reach", "rate", "reuse", "potion", "interact"] as Array[String])
	for mode: String in BotCheater.MODES:
		assert_eq(BotCheater.new(mode, 1).is_combat_mode(), BotCheater.COMBAT_MODES.has(mode),
				"%s: solo los de combate cambian cómo juega el bot" % mode)


func test_combat_modes_send_no_extra_traffic_and_leave_the_hello_alone() -> void:
	for mode: String in BotCheater.COMBAT_MODES:
		var cheater := BotCheater.new(mode, 4)
		assert_true(cheater.extra_packets(_honest_batch(300)).is_empty(), "%s: ni un paquete de más" % mode)
		var hello := NetMessages.Hello.new()
		cheater.tamper_hello(hello)
		assert_eq(hello.protocol_version, NetProtocol.PROTOCOL_VERSION, "%s: el HELLO es el de verdad" % mode)


func test_rewind_mode_claims_forty_ticks_of_view_in_every_input() -> void:
	var cheater := BotCheater.new("rewind", 2)
	var batch: NetMessages.InputBatch = _honest_batch(300)
	cheater.tamper_batch(batch)
	assert_eq(batch.view_offsets_q.size(), batch.inputs.size(), "sigue habiendo un desfase por entrada")
	for offset: int in batch.view_offsets_q:
		assert_eq(offset, 40 * 16, "40 ticks × 16")
	assert_true(BotCheater.REWIND_VIEW_TICKS > NetProtocol.MAX_REWIND_TICKS + 1, "más que el tope del servidor")
	# Lo que decodifica el servidor es eso mismo.
	var decoded: NetMessages.InputBatch = NetMessages.InputBatch.decode(batch.encode())
	assert_eq(decoded.view_offsets_q[0], 640)


func test_other_modes_leave_the_batch_as_it_was() -> void:
	for mode: String in ["version", "future", "dupes", "garbage", "flood", "reach", "rate", "reuse", "potion",
			"interact"]:
		var batch: NetMessages.InputBatch = _honest_batch(300)
		var before: PackedByteArray = batch.encode()
		BotCheater.new(mode, 2).tamper_batch(batch)
		assert_eq(batch.encode(), before, "%s no toca el lote" % mode)


func test_combat_modes_make_a_brain_and_the_traffic_modes_do_not() -> void:
	var finder: Callable = func(_position: Vector3) -> Variant: return Vector3(0.0, 0.0, -9.0)
	for mode: String in ["version", "future", "dupes", "garbage", "flood"]:
		assert_null(BotCheater.new(mode, 1).make_brain(finder, Vector3.ZERO, 10.0), "%s: sin cerebro" % mode)
	var rewind: BotBrain = BotCheater.new("rewind", 1).make_brain(finder, Vector3.ZERO, 10.0)
	assert_eq(rewind.get_pattern(), BotBrain.Pattern.COMBAT, "rewind pelea con el cerebro de combate")
	assert_true(rewind.has_enemy_finder())
	var reach: BotBrain = BotCheater.new("reach", 1).make_brain(finder, Vector3.ZERO, 10.0)
	assert_true(reach is BotCheatBrain and (reach as BotCheatBrain).get_style() == BotCheatBrain.Style.REACH)
	var rate: BotBrain = BotCheater.new("rate", 1).make_brain(finder, Vector3.ZERO, 10.0)
	assert_true(rate is BotCheatBrain and (rate as BotCheatBrain).get_style() == BotCheatBrain.Style.RATE)
	# Los de la fase 4 (docs/habilidades.md, sección 4.7).
	var styles: Dictionary[String, BotCheatBrain.Style] = {"reuse": BotCheatBrain.Style.REUSE,
			"potion": BotCheatBrain.Style.POTION, "interact": BotCheatBrain.Style.INTERACT}
	for mode: String in styles:
		var brain: BotBrain = BotCheater.new(mode, 1).make_brain(finder, Vector3.ZERO, 10.0)
		assert_true(brain is BotCheatBrain and (brain as BotCheatBrain).get_style() == styles[mode],
				"%s tiene su estilo" % mode)
		assert_true(brain.has_enemy_finder(), "%s sabe dónde están los enemigos" % mode)
		assert_false(brain.has_combat_source(), "%s no usa el kit: juega con sus botones" % mode)
