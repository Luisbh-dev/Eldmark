extends TestCase
## Pruebas del limitador de ritmo ([RateLimiter], un cubo de fichas en ticks) y de los avisos de
## [ServerPeer] (50 avisos en 600 ticks expulsan), docs/red.md sección 12.


func test_burst_then_empty() -> void:
	var limiter := RateLimiter.new(1.0, 5.0)
	for i: int in 5:
		assert_true(limiter.try_consume(10), "la ráfaga permite el gasto %d" % i)
	assert_false(limiter.try_consume(10), "sin fichas en el mismo tick")
	assert_false(limiter.try_consume(10), "y sigue sin haberlas")


func test_refills_one_rate_per_tick() -> void:
	var limiter := RateLimiter.new(1.0, 5.0)
	for _i: int in 5:
		limiter.try_consume(10)
	assert_false(limiter.try_consume(10), "vacío")
	assert_true(limiter.try_consume(11), "un tick después hay una ficha")
	assert_false(limiter.try_consume(11), "y solo una")
	assert_true(limiter.try_consume(13), "dos ticks después, dos fichas más")
	assert_true(limiter.try_consume(13), "la segunda")
	assert_false(limiter.try_consume(13), "y no hay tercera")


func test_fractional_rate_accumulates() -> void:
	var limiter := RateLimiter.new(0.25, 2.0)
	assert_true(limiter.try_consume(0), "primera de la ráfaga")
	assert_true(limiter.try_consume(0), "segunda de la ráfaga")
	assert_false(limiter.try_consume(0), "vacío")
	assert_false(limiter.try_consume(3), "tres ticks dan 0,75 fichas: aún no")
	assert_true(limiter.try_consume(4), "cuatro ticks completan una ficha")
	assert_false(limiter.try_consume(4), "y no queda nada")


func test_never_exceeds_burst() -> void:
	var limiter := RateLimiter.new(1.0, 5.0)
	limiter.try_consume(0)
	assert_near(limiter.get_tokens(10000), 5.0, 1e-9, "tras mucho tiempo vuelve al tope")
	var granted: int = 0
	for _i: int in 20:
		if limiter.try_consume(10000):
			granted += 1
	assert_eq(granted, 5, "nunca más fichas que la ráfaga")


func test_cost_and_failed_attempts() -> void:
	var limiter := RateLimiter.new(0.0, 10.0)
	assert_true(limiter.try_consume(0, 4.0), "gasta 4")
	assert_false(limiter.try_consume(0, 7.0), "7 no caben en las 6 restantes")
	assert_near(limiter.get_tokens(0), 6.0, 1e-9, "un intento fallido no gasta nada")
	assert_true(limiter.try_consume(0, 6.0), "gasta las 6")
	assert_false(limiter.try_consume(0, 0.5), "ya no queda nada")
	assert_false(RateLimiter.new(1.0, 5.0).try_consume(0, 6.0),
			"un coste mayor que la capacidad no se concede nunca")


func test_going_back_in_time_does_not_refill() -> void:
	var limiter := RateLimiter.new(1.0, 3.0)
	for _i: int in 3:
		limiter.try_consume(100)
	assert_false(limiter.try_consume(50), "un tick anterior no recarga")
	assert_false(limiter.try_consume(100), "ni al volver al tick de antes")
	assert_true(limiter.try_consume(101), "pero el tiempo siguiente sí cuenta desde el último")


func test_negative_parameters_are_clamped() -> void:
	var limiter := RateLimiter.new(-1.0, -5.0)
	assert_false(limiter.try_consume(0), "sin capacidad no concede nada")
	assert_false(limiter.try_consume(1000), "ni con el tiempo")


func test_same_seed_of_calls_gives_same_result() -> void:
	# Determinista: sin reloj ni azar, dos cubos con las mismas llamadas dan lo mismo.
	var a := RateLimiter.new(0.4, 6.0)
	var b := RateLimiter.new(0.4, 6.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var tick: int = 0
	for _i: int in 500:
		tick += rng.randi_range(0, 3)
		var cost: float = float(rng.randi_range(1, 3))
		assert_eq(a.try_consume(tick, cost), b.try_consume(tick, cost), "mismo resultado")


func test_grant_adds_tokens_above_the_burst_until_the_next_refill() -> void:
	var limiter := RateLimiter.new(1.0, 5.0)
	for _i: int in 5:
		limiter.try_consume(10)
	limiter.grant(10, 20.0)
	assert_near(limiter.get_tokens(10), 20.0, 1e-9, "el crédito se suma a lo que quedaba (0)")
	var granted: int = 0
	for _i: int in 30:
		if limiter.try_consume(10):
			granted += 1
	assert_eq(granted, 20, "y permite gastarlo todo en el mismo tick, por encima de la ráfaga")
	# Lo que no se gasta se pierde en la siguiente recarga: el tope vuelve a ser la ráfaga.
	var spare := RateLimiter.new(1.0, 5.0)
	spare.grant(10, 50.0)
	assert_near(spare.get_tokens(10), 55.0, 1e-9, "5 de la ráfaga más 50 de crédito")
	assert_near(spare.get_tokens(11), 5.0, 1e-9, "al pasar un tick se vuelve a limitar a la ráfaga")


func test_grant_refills_first_so_the_credit_is_not_erased() -> void:
	var limiter := RateLimiter.new(1.0, 5.0)
	for _i: int in 5:
		limiter.try_consume(10)
	# Han pasado 3 ticks desde el último uso: se recargan 3 fichas y después se suma el crédito.
	limiter.grant(13, 10.0)
	assert_near(limiter.get_tokens(13), 13.0, 1e-9, "3 recargadas y 10 de crédito")
	limiter.grant(13, -4.0)
	assert_near(limiter.get_tokens(13), 13.0, 1e-9, "un crédito negativo no quita fichas")


# --- Limitadores de ServerPeer ----------------------------------------------------------------

func test_peer_unreliable_limiter_allows_two_per_tick() -> void:
	var peer := ServerPeer.new(3)
	assert_eq(peer.peer_id, 3, "el id que se le da")
	var denied: int = 0
	for tick: int in range(100, 1100):
		for _i: int in 2:
			if not peer.limiter_unreliable.try_consume(tick):
				denied += 1
	assert_eq(denied, 0, "2 paquetes por tick (120 por segundo) pasan siempre")

	var burst := ServerPeer.new(4)
	var granted: int = 0
	for _i: int in 100:
		if burst.limiter_unreliable.try_consume(500):
			granted += 1
	assert_eq(granted, 30, "una ráfaga de 100 en un tick: solo 30")


func test_peer_reliable_limiter_is_ten_per_second_with_burst_of_twenty() -> void:
	var peer := ServerPeer.new(1)
	var granted: int = 0
	for _i: int in 50:
		if peer.limiter_reliable.try_consume(0):
			granted += 1
	assert_eq(granted, 20, "ráfaga de 20 mensajes fiables")
	# 600 ticks (10 s) a un mensaje cada 6 ticks (10 por segundo) deben pasar todos.
	var sustained := ServerPeer.new(2)
	var denied: int = 0
	for tick: int in range(0, 600, 6):
		if not sustained.limiter_reliable.try_consume(tick):
			denied += 1
	assert_eq(denied, 0, "10 mensajes fiables por segundo pasan")
	# A 20 por segundo la ráfaga se agota y empieza a rechazar.
	var flood := ServerPeer.new(5)
	denied = 0
	for tick: int in range(0, 600, 3):
		if not flood.limiter_reliable.try_consume(tick):
			denied += 1
	assert_true(denied > 0, "20 mensajes fiables por segundo no se sostienen")


func test_peer_bytes_limiter_is_16kb_per_second_with_burst_of_4kb() -> void:
	var peer := ServerPeer.new(1)
	assert_true(peer.limiter_bytes.try_consume(0, 4096.0), "la ráfaga son 4 KB")
	assert_false(peer.limiter_bytes.try_consume(0, 1.0), "y no hay más")
	assert_false(peer.limiter_bytes.try_consume(7, 2000.0), "7 ticks recuperan ~1,9 KB: no llega")
	assert_true(peer.limiter_bytes.try_consume(7, 1900.0), "pero 1900 B sí")
	assert_true(peer.limiter_bytes.try_consume(1000, 4096.0), "mucho después vuelve a haber 4 KB")
	assert_false(peer.limiter_bytes.try_consume(1000, 1.0), "pero el cubo no pasa de 4 KB")
	# 1200 B por snapshot a 30 Hz son 36 000 B/s: no cabe en 16 KB/s de ritmo sostenido.
	var flood := ServerPeer.new(2)
	var denied: int = 0
	for tick: int in range(0, 600, 2):
		if not flood.limiter_bytes.try_consume(tick, 1200.0):
			denied += 1
	assert_true(denied > 0, "36 KB/s sostenidos superan el límite de 16 KB/s")
	# 8 KB/s sí pasan siempre.
	var polite := ServerPeer.new(3)
	denied = 0
	for tick: int in range(0, 600, 2):
		if not polite.limiter_bytes.try_consume(tick, 270.0):
			denied += 1
	assert_eq(denied, 0, "~8 KB/s caben")


# --- Avisos y expulsión -----------------------------------------------------------------------

func test_peer_stall_credit_covers_the_ticks_the_server_missed() -> void:
	# El servidor perdió 90 ticks: el cliente siguió mandando un lote por tick y llegan todos juntos.
	var peer := ServerPeer.new(1)
	peer.limiter_unreliable.try_consume(500)
	peer.grant_stall_credit(500, 89)
	var granted: int = 0
	for _i: int in 90:
		if peer.limiter_unreliable.try_consume(500) and peer.limiter_bytes.try_consume(500, 51.0):
			granted += 1
	assert_eq(granted, 90, "pasan los 90 lotes de 51 B (30 de ráfaga + 2 por tick perdido)")
	# El crédito no es un tope nuevo: un tick después todo vuelve a la ráfaga normal.
	assert_near(peer.limiter_unreliable.get_tokens(501), ServerPeer.UNRELIABLE_BURST, 1e-6,
			"el crédito sobrante desaparece")
	var late := ServerPeer.new(2)
	late.grant_stall_credit(10, 0)
	late.grant_stall_credit(10, -5)
	assert_near(late.limiter_unreliable.get_tokens(10), ServerPeer.UNRELIABLE_BURST, 1e-6,
			"sin ticks perdidos no hay crédito")


func test_fifty_strikes_in_the_same_tick_kick() -> void:
	var peer := ServerPeer.new(1)
	for i: int in 49:
		assert_false(peer.add_strike(1000, "paquete malformado"), "el aviso %d no expulsa" % i)
	assert_true(peer.add_strike(1000, "paquete malformado"), "el aviso 50 expulsa")
	assert_eq(peer.strikes_total, 50, "se cuentan todos")
	assert_eq(peer.last_strike_reason, "paquete malformado", "se guarda el motivo")
	assert_true(peer.add_strike(1000, "otro"), "y los siguientes también piden expulsar")
	assert_eq(peer.last_strike_reason, "otro", "el último motivo")


func test_strikes_must_fall_inside_the_window() -> void:
	# 50 avisos, uno cada 12 ticks: del primero al último pasan 588 ticks (< 600): expulsa.
	var fast := ServerPeer.new(1)
	var kicked: bool = false
	for i: int in 50:
		kicked = fast.add_strike(i * 12, "exceso de ritmo")
	assert_true(kicked, "50 avisos en 588 ticks expulsan")

	# Uno cada 13 ticks: del primero al quincuagésimo pasan 637 ticks: nunca hay 50 en 600.
	var slow := ServerPeer.new(2)
	for i: int in 300:
		assert_false(slow.add_strike(i * 13, "exceso de ritmo"), "aviso lento %d" % i)


func test_window_boundary() -> void:
	var inside := ServerPeer.new(1)
	for _i: int in 49:
		inside.add_strike(0, "x")
	assert_true(inside.add_strike(599, "x"), "un aviso del tick 0 aún cuenta en el tick 599")

	var outside := ServerPeer.new(2)
	for _i: int in 49:
		outside.add_strike(0, "x")
	assert_false(outside.add_strike(600, "x"), "y deja de contar en el 600")
	assert_false(outside.add_strike(600, "x"), "sigue sin haber 50 dentro de la ventana")


func test_old_strikes_do_not_accumulate_forever() -> void:
	# Un aviso aislado cada 100 ticks durante mucho tiempo no expulsa nunca.
	var peer := ServerPeer.new(1)
	for i: int in 500:
		assert_false(peer.add_strike(i * 100, "ruido"), "aviso aislado %d" % i)
	assert_eq(peer.strikes_total, 500, "aun así se cuentan en total")


func test_new_peer_has_clean_state() -> void:
	var peer := ServerPeer.new()
	assert_eq(peer.state, ServerPeer.State.AUTHENTICATING, "empieza autenticándose")
	assert_eq(peer.strikes_total, 0, "sin avisos")
	assert_true(peer.relevant.is_empty(), "sin entidades relevantes")
	assert_true(peer.priority.is_empty(), "sin prioridades")
	assert_null(peer.entity, "sin entidad")
	assert_null(peer.input_queue, "sin cola de entradas")
	assert_not_null(peer.limiter_unreliable, "limitador de no fiables")
	assert_not_null(peer.limiter_reliable, "limitador de fiables")
	assert_not_null(peer.limiter_bytes, "limitador de bytes")
