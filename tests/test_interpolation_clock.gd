extends TestCase
## Pruebas de [InterpolationClock] (docs/red.md, secciones 4.3 y 16): converge al retardo con un
## jitter sintético, el retardo se acota a [4, 12] ticks, la corrección es gradual y salta con
## errores de más de 10 ticks.
## [br][br]
## Los snapshots sintéticos llegan cada 2 ticks locales con
## [code]server_tick = local_tick + base_offset - lateness[/code]: el offset máximo de la ventana
## es [code]base_offset[/code] y el jitter, la media de [code]lateness[/code].
## [br][br]
## [b]Régimen estable.[/b] El tick de dibujo converge justo al objetivo (sin el sesgo de un tick
## del pseudocódigo original de la sección 4.3).

## Tick de dibujo menos objetivo una vez estabilizado el reloj.
const STEADY_LEAD: float = 0.0


func test_does_not_start_before_the_first_snapshot() -> void:
	var clock := InterpolationClock.new()
	for tick: int in range(1, 10):
		assert_eq(clock.advance(tick), 0.0, "sin snapshots no hay con qué medir")
	assert_eq(clock.get_render_tick(), 0.0, "tick de dibujo 0")
	assert_eq(clock.get_delay_ticks(), 4.0, "retardo inicial: 2 intervalos de snapshot")
	assert_eq(clock.get_jitter_ticks(), 0.0, "sin jitter")


func test_converges_to_the_minimum_delay_without_jitter() -> void:
	var clock := InterpolationClock.new()
	var render_tick: float = 0.0
	for local_tick: int in range(1, 301):
		if local_tick % 2 == 0:
			clock.on_snapshot(local_tick + 30, local_tick)
		render_tick = clock.advance(local_tick)
		if local_tick == 2:
			assert_near(render_tick, 2.0 + 30.0 - 4.0, 1e-6, "el primer snapshot arranca el reloj")
	assert_eq(clock.get_jitter_ticks(), 0.0, "sin jitter")
	assert_eq(clock.get_delay_ticks(), 4.0, "retardo mínimo de 4 ticks (67 ms)")
	assert_near(render_tick, 300.0 + 30.0 - 4.0 + STEADY_LEAD, 1e-6,
			"en régimen estable se dibuja 4 ticks por detrás del servidor, más el tick de sesgo")
	assert_near(clock.get_render_tick(), render_tick, 1e-9, "get_render_tick() es el último valor")


func test_jitter_raises_the_delay() -> void:
	var clock := InterpolationClock.new()
	var render_tick: float = 0.0
	var snapshots: int = 0
	for local_tick: int in range(1, 601):
		if local_tick % 2 == 0:
			# Un snapshot puntual y otro dos ticks tarde, alternados: jitter medio de 1 tick.
			var lateness: int = 2 if snapshots % 2 == 1 else 0
			clock.on_snapshot(local_tick + 30 - lateness, local_tick)
			snapshots += 1
		render_tick = clock.advance(local_tick)
	assert_near(clock.get_jitter_ticks(), 1.0, 0.1, "jitter medio")
	assert_near(clock.get_delay_ticks(), 4.0 + 2.0 * 1.0, 0.25, "retardo = 4 + 2 · jitter")
	assert_near(render_tick, 600.0 + 30.0 - clock.get_delay_ticks() + STEADY_LEAD, 0.3,
			"el tick de dibujo sigue al objetivo")


func test_delay_is_clamped_to_twelve_ticks() -> void:
	var clock := InterpolationClock.new()
	for local_tick: int in range(1, 801):
		if local_tick % 2 == 0:
			var lateness: int = 20 if local_tick % 4 == 2 else 0
			clock.on_snapshot(local_tick + 40 - lateness, local_tick)
		clock.advance(local_tick)
	assert_true(clock.get_jitter_ticks() > 5.0, "jitter alto (%s)" % clock.get_jitter_ticks())
	assert_eq(clock.get_delay_ticks(), 12.0, "retardo máximo de 12 ticks (200 ms)")


func test_jitter_goes_back_to_zero_after_a_burst() -> void:
	var clock := InterpolationClock.new()
	for local_tick: int in range(1, 41):
		if local_tick % 2 == 0:
			clock.on_snapshot(local_tick + 30, local_tick)
	# Un bache: cinco snapshots seguidos con 4 ticks de retraso.
	for local_tick: int in range(42, 52, 2):
		clock.on_snapshot(local_tick + 30 - 4, local_tick)
	assert_true(clock.get_jitter_ticks() > 0.5, "el bache sube el jitter")
	for local_tick: int in range(52, 652, 2):
		clock.on_snapshot(local_tick + 30, local_tick)
	assert_eq(clock.get_jitter_ticks(), 0.0,
			"el jitter vuelve exactamente a 0 (si no, el margen objetivo de TickSync se quedaría "
			+ "un tick por encima para siempre)")
	assert_eq(clock.get_delay_ticks(), 4.0, "y el retardo, al mínimo")
	var sync := TickSync.new()
	sync.set_jitter(clock.get_jitter_ticks())
	assert_eq(sync.get_target_margin(), 1, "margen objetivo 1")


func test_small_errors_are_corrected_gradually() -> void:
	var clock := InterpolationClock.new()
	var local_tick: int = 0
	var base_offset: int = 30
	var previous: float = 0.0
	var max_step_error: float = 0.0
	var render_tick: float = 0.0
	for _i: int in 300:
		local_tick += 1
		if local_tick % 2 == 0:
			clock.on_snapshot(local_tick + base_offset, local_tick)
		render_tick = clock.advance(local_tick)
		previous = render_tick
	# El servidor «se adelanta» 5 ticks (por ejemplo, el cliente se quedó sin ticks un momento).
	base_offset += 5
	var target: float = 0.0
	for _i: int in 400:
		local_tick += 1
		if local_tick % 2 == 0:
			clock.on_snapshot(local_tick + base_offset, local_tick)
		render_tick = clock.advance(local_tick)
		max_step_error = maxf(max_step_error, absf(render_tick - previous - 1.0))
		previous = render_tick
		target = float(local_tick + base_offset) - 4.0
	assert_true(max_step_error <= 0.05 + 1e-9,
			"la corrección nunca pasa de 0,05 ticks por tick (fue %s)" % max_step_error)
	assert_true(max_step_error > 0.04, "y sí corrige a ese ritmo (fue %s)" % max_step_error)
	assert_near(render_tick, target + STEADY_LEAD, 0.05, "acaba sobre el objetivo")


func test_jumps_when_the_error_exceeds_ten_ticks() -> void:
	var clock := InterpolationClock.new()
	var local_tick: int = 0
	for _i: int in 200:
		local_tick += 1
		if local_tick % 2 == 0:
			clock.on_snapshot(local_tick + 30, local_tick)
		clock.advance(local_tick)
	# El servidor se adelanta 15 ticks: el objetivo se aleja más de 10 ticks y salta de golpe.
	local_tick += 1
	var before: float = clock.get_render_tick()
	clock.on_snapshot(local_tick + 45, local_tick)
	var jumped: float = clock.advance(local_tick)
	assert_near(jumped, float(local_tick + 45) - 4.0, 1e-6, "salta al objetivo")
	assert_true(jumped - before > 14.0, "el salto es de unos 15 ticks")


func test_max_offset_window_expires_after_two_seconds() -> void:
	var clock := InterpolationClock.new()
	var local_tick: int = 0
	for _i: int in 200:
		local_tick += 1
		if local_tick % 2 == 0:
			clock.on_snapshot(local_tick + 45, local_tick)
		clock.advance(local_tick)
	# La latencia mejora de golpe: los offsets bajan 15 ticks. El máximo de la ventana recuerda los
	# anteriores durante WINDOW_TICKS ticks (mientras tanto parece jitter y el retardo sube) y solo
	# entonces salta a la medida nueva.
	var change_tick: int = local_tick
	var previous: float = clock.get_render_tick()
	var jump_tick: int = -1
	for _i: int in 300:
		local_tick += 1
		if local_tick % 2 == 0:
			clock.on_snapshot(local_tick + 30, local_tick)
		var render_tick: float = clock.advance(local_tick)
		if absf(render_tick - previous - 1.0) > 5.0 and jump_tick < 0:
			jump_tick = local_tick
			assert_near(render_tick, float(local_tick + 30) - clock.get_delay_ticks(), 1e-6,
					"salta a la medida nueva")
		previous = render_tick
	assert_true(jump_tick > 0, "acaba saltando")
	var elapsed: int = jump_tick - change_tick
	assert_true(elapsed >= InterpolationClock.WINDOW_TICKS - 4
			and elapsed <= InterpolationClock.WINDOW_TICKS + 4,
			"el salto llega al caducar la ventana (%d ticks después)" % elapsed)
