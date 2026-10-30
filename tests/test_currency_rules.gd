extends TestCase
## Monedas y motivos (docs/progresion.md §5, PRG-12): [Currency], [CurrencyRules] y [EconomyReason]. Topes,
## negativos (también con deltas cerca de 2^63, sin dar la vuelta), dos operaciones del mismo tick sobre un
## saldo (la segunda no cabe y no se aplica, como en la BD de §5.4), la reconstrucción del saldo desde los
## apuntes y los rangos y signos de los motivos.

const CAP: int = 1_000_000_000
const INT_MAX: int = 9223372036854775807
const INT_MIN: int = -9223372036854775807 - 1


func test_currencies() -> void:
	assert_eq(Currency.CAP, CAP, "tope de mil millones (no 10^9, que en GDScript es XOR)")
	assert_eq(Currency.codes(), [1, 2] as Array[int], "oro y méritos")
	assert_eq([Currency.Code.GOLD, Currency.Code.MERITS], [1, 2], "sus códigos")
	assert_eq([Currency.id_of(1), Currency.id_of(2), Currency.id_of(3)], ["gold", "merits", ""], "sus ids")
	assert_eq([Currency.code_of("gold"), Currency.code_of("merits"), Currency.code_of("oro")], [1, 2, 0],
			"y al revés")
	assert_eq([Currency.cap_of(1), Currency.cap_of(2), Currency.cap_of(0)], [CAP, CAP, 0], "el mismo tope")
	assert_eq([Currency.display_name(1), Currency.display_name(2)], ["Oro", "Méritos"], "en español")
	assert_false(Currency.is_valid(0) or Currency.is_valid(3), "solo 1 y 2")
	assert_eq(Currency.WALLET_SIZE, 3, "un monedero indexado por código ([0] sin usar)")


func test_caps_and_negatives() -> void:
	var cases: Array[Array] = [
		[0, 0, true], [0, 1, true], [0, -1, false], [100, -100, true], [100, -101, false],
		[CAP, 0, true], [CAP, 1, false], [CAP - 1, 1, true], [0, CAP, true], [0, CAP + 1, false],
		[CAP, -CAP, true], [-1, 5, false], [CAP + 1, -1, false],
		[5, 1 << 62, false], [5, -(1 << 62), false], [0, INT_MAX, false], [CAP, INT_MIN, false],
		[INT_MAX, INT_MIN, false],
	]
	for entry: Array in cases:
		assert_eq(CurrencyRules.can_apply(entry[0], entry[1]), entry[2], "can_apply(%d, %d)" % [entry[0], entry[1]])


func test_gains_are_clamped_at_the_cap() -> void:
	var cases: Array[Array] = [
		[0, 50, 50], [CAP - 10, 50, 10], [CAP, 50, 0], [100, 0, 0], [100, -5, 0], [-1, 5, 0],
		[0, 1 << 62, CAP], [CAP + 7, 1, 0], [0, INT_MAX, CAP],
	]
	for entry: Array in cases:
		assert_eq(CurrencyRules.clamp_gain(entry[0], entry[1]), entry[2], "clamp_gain(%d, %d)" % [entry[0], entry[1]])


## Dos gastos de 60 en el mismo tick sobre 100: el primero vale y el segundo no cabe y no se aplica entero
## (el saldo queda en 40 y el libro suma 40), como las dos transacciones de §5.4. Y el ejemplo de §5.2: 100
## en la BD, +2 de un PNJ y un currency_add de +50 dan 102 y 152.
func test_two_operations_on_one_balance_in_the_same_tick() -> void:
	var balance: int = 100
	var ledger := PackedInt64Array([100])
	for spend: int in [-60, -60]:
		if CurrencyRules.can_apply(balance, spend):
			balance += spend
			ledger.append(spend)
	assert_eq(balance, 40, "solo cabe uno")
	assert_eq(CurrencyRules.replay(ledger), 40, "el libro suma lo mismo")
	balance = 100
	var after: Array[int] = []
	for delta: int in [CurrencyRules.clamp_gain(balance, 2), 50]:
		assert_true(CurrencyRules.can_apply(balance, delta), "cabe %+d" % delta)
		balance += delta
		after.append(balance)
	assert_eq(after, [102, 152] as Array[int], "balance_after de cada apunte, en el orden del diario")
	assert_eq(CurrencyRules.replay(PackedInt64Array([2, 50]), 100), 152, "desde el saldo de la BD")


func test_replay_rebuilds_the_balance() -> void:
	assert_eq(CurrencyRules.replay(PackedInt64Array()), 0, "sin apuntes, 0")
	assert_eq(CurrencyRules.replay(PackedInt64Array([100, -40, 7])), 67, "la suma")
	assert_eq(CurrencyRules.replay(PackedInt64Array([100, -101])), -1, "un paso negativo no vale")
	assert_eq(CurrencyRules.replay(PackedInt64Array([CAP, 1])), -1, "ni uno por encima del tope")
	assert_eq(CurrencyRules.replay(PackedInt64Array([5, 0])), -1, "ni un apunte de 0")
	assert_eq(CurrencyRules.replay(PackedInt64Array([-5]), 10), 5, "desde otro saldo")
	assert_eq(CurrencyRules.replay(PackedInt64Array([1]), -1), -1, "un saldo de partida que no vale")
	# Un libro al azar: ganancias recortadas y gastos que solo se aplican si caben.
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xC0FFEE
	for round_index: int in range(20):
		var balance: int = 0
		var deltas := PackedInt64Array()
		var balances: Array[int] = []
		for _i: int in range(200):
			var delta: int = 0
			if rng.randf() < 0.6:
				delta = CurrencyRules.clamp_gain(balance, rng.randi_range(1, 400_000_000))
			else:
				delta = -rng.randi_range(1, 300_000_000)
				if not CurrencyRules.can_apply(balance, delta):
					continue
			if delta == 0:
				continue
			balance += delta
			deltas.append(delta)
			balances.append(balance)
			if balance < 0 or balance > CAP:
				fail("ronda %d: saldo fuera de rango %d" % [round_index, balance])
				return
		assert_eq(CurrencyRules.replay(deltas), balance, "ronda %d: saldo = Σ delta" % round_index)
		for i: int in range(balances.size()):
			if CurrencyRules.replay(deltas.slice(0, i + 1)) != balances[i]:
				fail("ronda %d: balance_after del apunte %d" % [round_index, i])
				return


func test_reason_ranges_and_signs() -> void:
	var limits: Array[Array] = [
		[0, false, false, false], [1, true, false, false], [63, true, false, false], [64, false, true, false],
		[127, false, true, false], [128, false, false, true], [191, false, false, true], [192, false, false, false],
	]
	for entry: Array in limits:
		var reason: int = entry[0]
		assert_eq([EconomyReason.is_source(reason), EconomyReason.is_sink(reason), EconomyReason.is_internal(reason)],
				[entry[1], entry[2], entry[3]], "rangos de %d" % reason)
	assert_true(EconomyReason.sign_matches(EconomyReason.STARTER_KIT, 1), "fuente: positivo")
	assert_false(EconomyReason.sign_matches(EconomyReason.STARTER_KIT, -1), "fuente: no negativo")
	assert_true(EconomyReason.sign_matches(EconomyReason.CONSUME, -1), "sumidero: negativo")
	assert_false(EconomyReason.sign_matches(EconomyReason.CONSUME, 1), "sumidero: no positivo")
	assert_true(EconomyReason.sign_matches(EconomyReason.REVERSAL, -3) and EconomyReason.sign_matches(
			EconomyReason.MIGRATION, 3), "interno: cualquier signo")
	assert_false(EconomyReason.sign_matches(EconomyReason.REVERSAL, 0), "pero no 0")
	assert_false(EconomyReason.sign_matches(200, 1) or EconomyReason.sign_matches(0, 1), "fuera de rango, nunca")
	var seen: Dictionary = {}
	for reason_name: String in EconomyReason.CODES:
		var code: int = EconomyReason.CODES[reason_name]
		assert_false(seen.has(code), "%s: el %d no se repite" % [reason_name, code])
		seen[code] = true
		assert_true(EconomyReason.is_source(code) or EconomyReason.is_sink(code) or EconomyReason.is_internal(code),
				"%s en algún rango" % reason_name)
		assert_eq(EconomyReason.name_of(code), reason_name, "name_of(%d)" % code)
		assert_true(EconomyReason.is_known(code), "%s conocido" % reason_name)
	assert_eq(EconomyReason.CODES.size(), 26, "los 26 motivos de §5.3")
	assert_eq([EconomyReason.STARTER_KIT, EconomyReason.CAMP_REFILL, EconomyReason.PVP_KILL, EconomyReason.PVP_ASSIST,
			EconomyReason.OBJECTIVE, EconomyReason.NPC_KILL, EconomyReason.GM_GRANT, EconomyReason.PLAYER_DESTROY,
			EconomyReason.CONSUME, EconomyReason.GM_REMOVE, EconomyReason.REVERSAL, EconomyReason.MIGRATION],
			[1, 2, 3, 4, 5, 6, 7, 64, 65, 66, 128, 129], "los de la fase 5")
	assert_false(EconomyReason.is_known(14) or EconomyReason.is_known(130), "los huecos no son motivos")
	assert_eq(EconomyReason.name_of(14), "", "ni tienen nombre")
	for reason: int in range(0, 256):
		assert_eq(EconomyReason.gives_realm_points(reason), reason >= 3 and reason <= 5,
				"puntos de reino solo con los méritos de juego (I9): %d" % reason)
