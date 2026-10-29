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


## Un servidor que pierde ticks (o una subida sostenida de la latencia) baja los offsets de golpe.
## El máximo de la ventana de 2 s recordaría los viejos y el tick de dibujo iría por delante de los
## datos que existen (se extrapolaría 6 ticks y después el remoto se quedaría quieto, hallazgo N3).
## Un escalón sostenido de más de STEP_DOWN_TICKS se adopta en RECENT_TICKS ticks, no en 120.
func test_a_sustained_step_down_of_the_offsets_is_adopted_in_half_a_second() -> void:
	var clock := InterpolationClock.new()
	var local_tick: int = 0
	for _i: int in 200:
		local_tick += 1
		if local_tick % 2 == 0:
			clock.on_snapshot(local_tick + 45, local_tick)
		clock.advance(local_tick)
	# El servidor pierde 15 ticks: los offsets bajan de 45 a 30 y se quedan ahí.
	var change_tick: int = local_tick
	var adopted_after: int = -1
	var jitter_after_100: float = -1.0
	for _i: int in 400:
		local_tick += 1
		if local_tick % 2 == 0:
			clock.on_snapshot(local_tick + 30, local_tick)
		var render_tick: float = clock.advance(local_tick)
		var target: float = float(local_tick + 30) - clock.get_delay_ticks()
		if adopted_after < 0 and absf(render_tick - target) <= 1.0:
			adopted_after = local_tick - change_tick
		if local_tick - change_tick == 100:
			jitter_after_100 = clock.get_jitter_ticks()
	assert_true(adopted_after > 0 and adopted_after <= 40,
			"el tick de dibujo llega a local + 30 - retardo (±1) en 40 ticks o menos (%d)" % adopted_after)
	assert_true(jitter_after_100 >= 0.0 and jitter_after_100 < 1.0,
			"el jitter del escalón vuelve a ser pequeño en poco tiempo (%s)" % jitter_after_100)
	# El retardo vuelve al mínimo y el tick de dibujo lo sigue a 0,05 ticks por tick.
	assert_near(clock.get_delay_ticks(), 4.0, 0.05, "el retardo vuelve al mínimo")
	assert_near(clock.get_render_tick(), float(local_tick + 30) - clock.get_delay_ticks(), 1.0,
			"y el tick de dibujo acaba sobre la medida nueva")


## Un servidor sobrecargado que pierde 1 de cada 12 ticks de forma continua baja los offsets sin parar.
## El tick de dibujo no puede ir más de MAX_EXTRAPOLATION_TICKS por delante del último snapshot (el
## remoto se congelaría), que con el máximo de 2 s sí pasaba de forma permanente.
func test_a_server_that_keeps_losing_ticks_does_not_freeze_the_remotes() -> void:
	var clock := InterpolationClock.new()
	var local_tick: int = 0
	var newest_server_tick: int = 0
	var frozen: int = 0
	var measured: int = 0
	for _i: int in 1200:
		local_tick += 1
		if local_tick % 2 == 0:
			newest_server_tick = local_tick + 30 - local_tick / 12
			clock.on_snapshot(newest_server_tick, local_tick)
		var render_tick: float = clock.advance(local_tick)
		if local_tick > 240:
			measured += 1
			if render_tick - float(newest_server_tick) > float(RemoteInterpolator.MAX_EXTRAPOLATION_TICKS):
				frozen += 1
	assert_true(measured > 900, "se mide casi toda la ejecución")
	assert_eq(frozen, 0, "ningún tick con el remoto más de 6 ticks por delante de su último dato")


## Un bache más corto que RECENT_TICKS no es un escalón: los offsets viejos siguen mandando y el
## tick de dibujo no se mueve de golpe ni durante el bache ni cuando se acaba.
func test_a_short_dip_is_not_a_step() -> void:
	var clock := InterpolationClock.new()
	var local_tick: int = 0
	var previous: float = 0.0
	var max_jump: float = 0.0
	for i: int in 400:
		local_tick += 1
		# Entre los ticks 201 y 220 (20 ticks, menos que RECENT_TICKS) los snapshots llegan con
		# 15 ticks de retraso.
		var offset: int = 30 if i >= 200 and i < 220 else 45
		if local_tick % 2 == 0:
			clock.on_snapshot(local_tick + offset, local_tick)
		var render_tick: float = clock.advance(local_tick)
		if i > 2:
			max_jump = maxf(max_jump, absf(render_tick - previous - 1.0))
		previous = render_tick
	assert_true(max_jump <= InterpolationClock.MAX_CORRECTION_PER_TICK + 1e-9,
			"el tick de dibujo nunca salta (mayor salto %s)" % max_jump)
	assert_near(previous, float(local_tick + 45) - clock.get_delay_ticks(), 1.0,
			"y sigue la medida de siempre (45), no la del bache")


## Una latencia que mejora (offsets que suben) se adopta al instante, como siempre.
func test_offsets_that_go_up_are_adopted_immediately() -> void:
	var clock := InterpolationClock.new()
	var local_tick: int = 0
	for _i: int in 200:
		local_tick += 1
		if local_tick % 2 == 0:
			clock.on_snapshot(local_tick + 30, local_tick)
		clock.advance(local_tick)
	local_tick += 2
	clock.on_snapshot(local_tick + 45, local_tick)
	var render_tick: float = clock.advance(local_tick)
	assert_near(render_tick, float(local_tick + 45) - clock.get_delay_ticks(), 1e-6,
			"salta a la medida nueva en el mismo snapshot")


## Con ticks de servidor por encima de 2^31 (el u32 de red.md 4.1 llega a 828 días) el reloj sigue
## bien: las muestras no pueden ir en enteros de 32 bits (hallazgo N5).
func test_server_ticks_beyond_two_to_the_thirty_one_do_not_overflow() -> void:
	var clock := InterpolationClock.new()
	var base: int = 2147483648 + 1000
	var render_tick: float = 0.0
	for local_tick: int in range(1, 301):
		if local_tick % 2 == 0:
			clock.on_snapshot(base + local_tick + 5, local_tick)
		render_tick = clock.advance(local_tick)
	assert_near(render_tick, float(base + 300 + 5) - 4.0, 0.5,
			"el tick de dibujo es el del servidor menos el retardo, sin desbordar")
	assert_true(render_tick > 0.0, "y positivo")
