extends SceneTree
## Prueba de carga de la fase 2 (docs/red.md, secciones 14 y 16, «Carga»; TEC-11). Fuera del ejecutor de
## pruebas: lanza un servidor y los clientes como procesos de Godot, los espera y resume lo que mide el
## servidor (y el enjambre de bots) en un informe por escenario.
## [br][br]
## [b]Uso[/b], desde la raíz del proyecto (el [code]godot[/code] de consola):
## [codeblock]
## # Un escenario: 64 jugadores falsos agrupados y 10 clientes reales (--bots) durante 30 s de medida
## godot --headless --path . -s res://tools/load_test.gd -- --scenario=cluster --fakes=64 --bots=10
##
## # La batería de la fase 2 (ver MATRIX): agrupado con 2, 10 y 50 bots, el criterio con 100 ms de RTT,
## # disperso, altas y bajas, y 128 y 256 jugadores falsos; 120 s de medida cada escenario (unos 25 min)
## godot --headless --path . -s res://tools/load_test.gd -- --matrix
##
## # 128 y 256 jugadores: los clientes reales se reparten entre varios procesos de enjambre
## godot --headless --path . -s res://tools/load_test.gd -- --fakes=128 --bots=100 --swarms=2
## godot --headless --path . -s res://tools/load_test.gd -- --fakes=156 --bots=100 --swarms=2 --seconds=20
##
## # La batería de la fase 3 (ver BRAWL_MATRIX): refriegas agrupadas de 32, 40, 64 y 128 combatientes con el
## # cerebro de combate (falsos del servidor y bots reales que pelean); 60 s de medida cada una. Desde H5 (fase 4,
## # docs/habilidades.md, sección 7.3) los falsos pelean con el kit y la mitad lleva la plantilla del tirador
## # (--fake-loadout=marksman:50), arqueros puros de los que la mitad dispara al cielo (--fake-archers=50: sus flechas
## # viven 2 s): flechas, habilidades, pociones y derribos, con los PNJ del fuerte en la zona
## godot --headless --path . -s res://tools/load_test.gd -- --brawl
## # Una refriega suelta: 54 falsos de combate y 10 clientes reales de combate (64 en total)
## godot --headless --path . -s res://tools/load_test.gd -- --scenario=brawl --fakes=54 --bots=10
##
## # La batería de la fase 4 (ver SIEGE_MATRIX, GUE-16): asedios de 32 contra 32 y de 64 contra 64 en la puerta y el
## # círculo del fuerte del Vado Gris, 120 s de medida cada uno (unos 4 min por escenario)
## godot --headless --path . -s res://tools/load_test.gd -- --siege
## # Un asedio suelto: 54 falsos de asedio y 10 clientes reales (--bot-brain=siege), 32 contra 32
## godot --headless --path . -s res://tools/load_test.gd -- --scenario=siege --fakes=54 --bots=10 --seconds=60
## # Lo mismo con los PNJ de verdad y el fuerte sin ayudas (F6b): 32 contra 32, 120 s de medida
## godot --headless --path . -s res://tools/load_test.gd -- --scenario=siege --fakes=54 --bots=10 --seconds=120 --npcs
## [/codeblock]
## [b]Opciones[/b] (después de [code]--[/code]):
## [br]- [code]--scenario=cluster|spread|churn[/code] (por defecto [code]cluster[/code]):
## [br]  · [code]cluster[/code], agrupado: todos los jugadores falsos y todos los bots en torno al mismo punto
## (el campamento de Vardheim; el servidor los coloca con [code]--fake-layout=cluster[/code]), a menos de unos
## 60 m unos de otros.
## [br]  · [code]spread[/code], disperso: los falsos repartidos por la zona ([code]--fake-layout=spread[/code]) y
## los bots en los dos campamentos.
## [br]  · [code]churn[/code], altas y bajas: como [code]cluster[/code], pero cada segundo sale el jugador falso
## más antiguo y entra uno nuevo ([code]--fake-churn=60[/code]).
## [br]  · [code]brawl[/code], refriega agrupada (TEC-15): los falsos pelean con el cerebro de combate
## ([code]--fake-brain=combat[/code]) en un corro alrededor de [constant BRAWL_CENTER], en campo abierto
## junto al campamento de Vardheim (la zona segura de los campamentos les impediría pelear), y los
## bots reales ([code]--bots[/code], todos de Vardheim) salen del campamento y pelean también
## ([code]--bot-brain=combat[/code]): reciben snapshots y ENTITY_EVENT y mandan su desfase de vista, así que
## el servidor hace el rebobinado de verdad. Los falsos son la mitad de cada reino.
## [br]  · [code]siege[/code], asedio (GUE-16): los falsos asedian y defienden el fuerte del Vado Gris
## ([code]--fake-brain=siege[/code], repartidos entre Vardheim y Solmarch) y los bots reales ([code]--bots[/code],
## uno de cada reino por turnos) llevan el cerebro de asedio ([code]--bot-brain=siege[/code], que sigue la ruta,
## golpea la puerta, entra en el círculo y pelea sin simular). Sin [code]--npcs[/code] es el asedio de F6a: el
## servidor arranca sin PNJ ([code]--no-npcs[/code]) y abre el círculo con una orden programada
## ([code]--run-at=<tick>:fort_kill_captain[/code]). Con [code]--npcs[/code] (F6b) arranca con sus PNJ (Huecos, Capitán
## del Vado, guarnición del dueño y Guardianes) y el fuerte va solo: nadie mata al capitán por ellos. En los dos casos
## escribe un registro de batalla ([code]--battle-log[/code]) que el resumen lee. La ventana de medida empieza cuando
## los bots ya han llegado a la puerta ([constant SIEGE_EXTRA_SETTLE_SECONDS]); el resumen dice cuántos bots reales
## habían llegado al fuerte antes de ella (GUE-44: los que entran tarde esperan a los suyos en el campamento).
## [br]- [code]--fakes=N[/code] jugadores falsos (entradas inyectadas en la cola, sin red; por defecto 64).
## [br]- [code]--bots=N[/code] clientes reales: procesos [code]--bots=N[/code] ([BotSwarm]) que entran uno cada 5 ticks
## (por defecto 0).
## [br]- [code]--swarms=K[/code] procesos de enjambre entre los que se reparten los bots (por defecto 1; un proceso
## aguanta algunas decenas).
## [br]- [code]--seconds=S[/code] segundos de medida con todos dentro (por defecto 30; 120 con
## [code]--matrix[/code], como pide docs/red.md, 16).
## [br]- [code]--net-sim=rtt=100,jitter=10,loss=1[/code] simulador de red de los bots. En [code]--matrix[/code]
## lo fija cada escenario de [constant MATRIX] (el de 100 ms de RTT); la opción solo vale para los que no
## llevan uno.
## [br]- [code]--zone=<id>[/code] zona del servidor (por defecto la de siempre, el Vado Gris).
## [br]- [code]--fake-loadout=<plantilla>[:<porcentaje>][/code] plantilla de equipo de los falsos (la pasa al
## servidor). En las refriegas, por defecto [constant BRAWL_LOADOUT].
## [br]- [code]--sky-archers=<porcentaje>[/code] en las refriegas con tiradores: qué parte de ellos dispara al cielo
## (por defecto [constant BRAWL_SKY_ARCHERS_PERCENT]; con 100, un pico de 54 de las 64 del tope con 64 combatientes;
## para llenar el tope y medir los desalojos, todos tiradores: [code]--fake-loadout=marksman:100
## --sky-archers=100[/code]: pico de 64 y unas 4600 echadas en toda la ejecución).
## [br]- [code]--out=<carpeta>[/code] dónde van los informes y los registros (por defecto [code]build/load_test[/code]).
## [br]- [code]--siege[/code] lanza la batería de [constant SIEGE_MATRIX] (120 s de medida cada una).
## [br]- [code]--npcs[/code] (solo en los asedios, también con [code]--siege[/code]): con los PNJ de la zona y sin la
## orden que mata al capitán (ver [code]siege[/code] arriba). En los demás escenarios no cambia nada.
## [br]- [code]--brawl[/code] lanza la batería de refriegas de [constant BRAWL_MATRIX] (60 s de medida cada una).
## [br]- [code]--check[/code] sale con código 1 si algún escenario incumple el criterio de la fase 2.
## [br][br]
## [b]Qué mide[/b] (del [code]--report[/code] del servidor, de [method ZoneServer.write_report], y del de cada
## enjambre): el p50, el p99 y el máximo del tick y de cada una de sus secciones (red, simulación, historial,
## snapshots, vaciado) en µs; los µs de [code]PlayerCharacter.simulate()[/code] por personaje; el tamaño de los
## snapshots y los µs de construir cada uno; los KB/s de subida y de bajada por cliente; el porcentaje de
## entradas sustituidas, los avisos y las expulsiones. En las refriegas, además, las secciones de combate
## ([code]combat[/code], con [code]combat_resolve[/code] —golpes con rebobinado— y [code]combat_events[/code]
## —envío de los ENTITY_EVENT— dentro), los µs por comprobación de golpe, los golpes, las muertes y los eventos
## por segundo, y la bajada de cada cliente separada en snapshots y eventos (KB/s). En los asedios, además, las
## secciones de los PNJ ([code]npc_brains[/code], sus cerebros, y [code]npc[/code], los generadores) y la de las
## fortalezas ([code]war[/code]), con su media de toda la sesión, y los PNJ que había en cada marca de métricas del
## servidor (su [code]simulate()[/code] va en [code]sim[/code], con el de los jugadores). Los percentiles del servidor son de los últimos 2048
## ticks (34 s) de su ejecución, así que el servidor sigue unos segundos de más después de que los bots
## entren, para que la ventana sea solo de régimen. Los enjambres se cierran por el tick del servidor
## ([code]--quit-at-server-tick[/code], [constant TAIL_SECONDS] y [constant SWARM_START_MARGIN_TICKS] antes de su final),
## no por su propio reloj: con muchos jugadores el servidor va más despacio que el tiempo real y los bots se iban antes de
## tiempo. El resumen dice cuántos jugadores había en esos 2048 ticks y en las marcas de la ventana, y avisa si no son
## los del pico.
## [br][br]
## [b]Entradas sustituidas.[/b] El informe del servidor da el porcentaje de toda la sesión, con el arranque
## dentro (cada bot pierde unas decenas de entradas mientras [TickSync] encuentra su antelación, más con
## 100 ms de RTT). Se muestran las dos cifras: la de la sesión y la de la ventana de medida, que resta lo
## acumulado al empezar ([LoadTestSummary]; sale de las líneas de métricas que el servidor escribe cada
## 600 ticks, así que la ventana va de la primera tras entrar los bots a la última antes de que se
## vayan). El criterio usa la de la ventana.
## [br][br]
## [b]Criterio de la fase 4[/b] (docs/habilidades.md, secciones 7.3 y 8): en la refriega de 64 con la mitad de
## tiradores, el p99 del tick por debajo de 16,7 ms y la sección [code]combat_projectiles[/code] por debajo de
## 1 ms (p99); se muestra con el pico de flechas vivas frente al tope de la zona y las que el tope echó.
## [br][br]
## [b]Criterio de la fase 2[/b] (docs/red.md, 14 y 16), con 64 jugadores agrupados y 100 ms de RTT en los
## bots: p99 del tick por debajo de 8 ms, como mucho 37 KB/s de bajada por cliente y menos de un 1 % de
## entradas sustituidas. Con otros tamaños o escenarios se muestra como referencia.
## [br][br]
## Las cifras dependen de la máquina y de lo que más corra en ella: el servidor, el enjambre y quien lo lance
## comparten núcleos. Cada servidor usa un puerto distinto a partir del 25000.

const FIRST_PORT: int = 25000
const LAST_PORT: int = 26000
## Segundos que se esperan, como mucho, a que el servidor empiece a escuchar.
const LISTEN_TIMEOUT_SECONDS: float = 40.0
## Segundos de más, sobre la duración prevista, que se espera a que terminen los procesos.
const FINISH_MARGIN_SECONDS: float = 60.0
## Segundos que se dejan, tras empezar a escuchar, para que arranquen los procesos y entren todos los bots
## antes de la ventana de medida (se suman 5 ticks por bot de cada enjambre).
const SETTLE_SECONDS: float = 8.0
## Segundos que sigue el servidor después de que se vayan los bots (poco, para no ensuciar la ventana).
const TAIL_SECONDS: float = 2.0
## Ticks de margen entre el cierre del enjambre y el del servidor (arranque del proceso del enjambre).
const SWARM_START_MARGIN_TICKS: int = 90
## El enjambre se cierra por el tick del servidor ([code]--quit-at-server-tick[/code]): con muchos jugadores el servidor
## va más despacio que el tiempo real, y uno que se cerrase por su propio reloj se iría antes de que acabase la ventana
## (con 128 jugadores, a los 8400 ticks de 10 850: los percentiles del último tramo salían de 118 jugadores sin ningún
## cliente; revisión de F6b). Como cota, y para esperar a los procesos, se admite un servidor hasta este número de veces
## más lento que el tiempo real.
const SLOW_SERVER_FACTOR: float = 3.0
## Si menos de esta parte de los últimos 2048 ticks del servidor (de los que salen los percentiles de su informe) tuvo el
## pico de jugadores, el resumen avisa de que esos percentiles no son de la carga que se quería medir.
const MIN_TAIL_AT_PEAK: float = 0.75
## Criterio de la fase 2.
const MAX_P99_TICK_US: int = 8000
const MAX_KB_PER_CLIENT: float = 37.0
const MAX_SUBSTITUTED_PERCENT: float = 1.0
## Secciones del tick que se muestran (las de combate van dentro de [code]combat[/code]).
const SECTIONS: Array[String] = ["tick", "net", "npc_brains", "sim", "combat", "combat_resolve", "combat_projectiles",
		"combat_events", "war", "npc", "history", "snapshot", "flush"]
## Plantilla de los falsos de una refriega (fase 4, H5): la mitad tiradores, arqueros puros, de los que este
## porcentaje dispara al cielo ([code]--fake-archers[/code]).
const BRAWL_LOADOUT: String = "marksman:50"
const BRAWL_SKY_ARCHERS_PERCENT: int = 50
## Criterio de la fase 4 (docs/habilidades.md, secciones 7.3 y 8): p99 del tick y de la sección de proyectiles.
const MAX_P99_TICK_US_PHASE_4: int = 16700
const MAX_P99_PROJECTILES_US: int = 1000
## Batería de [code]--matrix[/code]: [escenario, jugadores falsos, bots, simulador de red de los bots].
## Los tres primeros son los de siempre (sin retardo); el cuarto es el criterio de la fase 2 medido como
## pide docs/red.md, 16 (64 agrupados y 100 ms de RTT); después disperso, altas y bajas y los tamaños
## de 128 y 256 jugadores falsos.
const MATRIX: Array[Array] = [
	["cluster", 64, 2, ""],
	["cluster", 64, 10, ""],
	["cluster", 64, 50, ""],
	["cluster", 64, 10, "rtt=100"],
	["spread", 64, 10, ""],
	["churn", 64, 10, ""],
	["cluster", 128, 10, ""],
	["cluster", 256, 10, ""],
	["spread", 256, 10, ""],
]
## Segundos de medida de cada escenario de [constant MATRIX] (docs/red.md, 16: 120 s cada uno).
const MATRIX_SECONDS: int = 120
## Batería de [code]--brawl[/code] (TEC-15): [escenario, jugadores falsos, bots reales, simulador de red de los
## bots]. Los combatientes son los falsos más los diez bots reales: 32, 40, 64 y 128 en total. La de 40 es el
## límite de jugadores por batalla con el kit de la fase 4 (docs/red.md, sección 14) y el aforo del Vado Gris.
const BRAWL_MATRIX: Array[Array] = [
	["brawl", 22, 10, ""],
	["brawl", 30, 10, ""],
	["brawl", 54, 10, ""],
	["brawl", 118, 10, ""],
]
## Segundos de medida de cada refriega de [constant BRAWL_MATRIX].
const BRAWL_SECONDS: int = 60
## Punto (x, z) del Vado Gris en el que se juntan los falsos de una refriega: campo abierto a 18 m del
## borde de la zona segura del campamento de Vardheim (z = -138, radio 24) y a unos 34 m del brazo
## norte del río, sin obstáculos de aquí al campamento.
const BRAWL_CENTER: String = "0,-96"
## Segundos de más que se dejan, en una refriega, antes de la ventana de medida: los bots reales salen
## del campamento y tardan unos segundos en llegar al corro.
const BRAWL_EXTRA_SETTLE_SECONDS: float = 12.0
## Batería de [code]--siege[/code] (GUE-16): [escenario, jugadores falsos, bots reales, simulador de red de los
## bots]. Los dos bandos son los falsos más los diez bots reales entre dos: 32 contra 32 (54 + 10) y 64 contra 64
## (118 + 10).
const SIEGE_MATRIX: Array[Array] = [
	["siege", 54, 10, ""],
	["siege", 118, 10, ""],
]
## Segundos de medida de cada asedio de [constant SIEGE_MATRIX] (docs/fuerte.md, sección 7: 120 s).
const SIEGE_SECONDS: int = 120
## Segundos de más que se dejan, en un asedio, antes de la ventana de medida: los bots salen de sus campamentos
## y tardan de 25 a 45 s en llegar a la puerta (el puente, directo; el vado, más largo).
const SIEGE_EXTRA_SETTLE_SECONDS: float = 50.0
## Segundos de medida de un escenario suelto.
const DEFAULT_SECONDS: int = 30

var _pids: Array[int] = []
var _out_dir: String = ""
var _tick_rate: int = 60


func _initialize() -> void:
	_run()


func _run() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var runs: Array[Dictionary] = []
	if args.has("--matrix"):
		for entry: Array in MATRIX:
			runs.append(_make_run(args, entry[0], entry[1], entry[2], entry[3], MATRIX_SECONDS))
	elif args.has("--brawl"):
		for entry: Array in BRAWL_MATRIX:
			runs.append(_make_run(args, entry[0], entry[1], entry[2], entry[3], BRAWL_SECONDS))
	elif args.has("--siege"):
		for entry: Array in SIEGE_MATRIX:
			runs.append(_make_run(args, entry[0], entry[1], entry[2], entry[3], SIEGE_SECONDS))
	else:
		runs.append(_make_run(args, _option(args, "--scenario=", "cluster"),
				_int_option(args, "--fakes=", 64), _int_option(args, "--bots=", 0), "", DEFAULT_SECONDS))
	_out_dir = _option(args, "--out=", "")
	if _out_dir.is_empty():
		_out_dir = ProjectSettings.globalize_path("res://build/load_test")
	DirAccess.make_dir_recursive_absolute(_out_dir)
	DirAccess.remove_absolute(_out_dir.path_join("summary.txt"))
	_tick_rate = Engine.physics_ticks_per_second

	print("Eldmark · prueba de carga (%d escenario%s, %d núcleos, informes en %s; resumen en summary.txt)" % [
		runs.size(), "s" if runs.size() != 1 else "", OS.get_processor_count(), _out_dir])
	var summaries: Array[Dictionary] = []
	var failed: bool = false
	for run: Dictionary in runs:
		var summary: Dictionary = await _run_scenario(run)
		summaries.append(summary)
		_print_summary(summary)
		if not bool(summary.get("ok", false)) or not bool(summary.get("criterion_met", true)):
			failed = true
	var file: FileAccess = FileAccess.open(_out_dir.path_join("summary.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(summaries, "\t"))
		file.close()
		print("Resumen JSON: %s" % _out_dir.path_join("summary.json"))
	for pid: int in _pids:
		if OS.is_process_running(pid):
			OS.kill(pid)
	var errors: bool = false
	for summary: Dictionary in summaries:
		if not bool(summary.get("ok", false)):
			errors = true
	quit(1 if (errors or (args.has("--check") and failed)) else 0)


# [param net_sim] es el del escenario (el de la batería); vacío = el de --net-sim.
func _make_run(args: PackedStringArray, scenario: String, fakes: int, bots: int, net_sim: String,
		default_seconds: int) -> Dictionary:
	return {
		"scenario": scenario,
		"fakes": fakes,
		"bots": bots,
		"swarms": maxi(_int_option(args, "--swarms=", 1), 1),
		"seconds": _int_option(args, "--seconds=", default_seconds),
		"net_sim": net_sim if not net_sim.is_empty() else _option(args, "--net-sim=", ""),
		"zone": _option(args, "--zone=", ""),
		"npcs": args.has("--npcs") and scenario == "siege",
		"loadout": _option(args, "--fake-loadout=", BRAWL_LOADOUT if scenario == "brawl" else ""),
		"sky_archers": _int_option(args, "--sky-archers=", BRAWL_SKY_ARCHERS_PERCENT),
	}


# --- Un escenario -----------------------------------------------------------------------------

# Lanza el servidor y los enjambres, espera a que terminen y devuelve el resumen de lo medido.
func _run_scenario(run: Dictionary) -> Dictionary:
	var scenario: String = run["scenario"]
	var fakes: int = run["fakes"]
	var bots: int = run["bots"]
	var swarms: int = mini(run["swarms"], maxi(bots, 1))
	var tag: String = "%s_%df_%db" % [scenario, fakes, bots]
	if not str(run["net_sim"]).is_empty():
		tag += "_" + String(run["net_sim"]).replace("=", "").replace(",", "_")
	if bool(run.get("npcs", false)):
		tag += "_npcs"
	var port: int = _free_port()
	var summary: Dictionary = {"tag": tag, "run": run, "port": port, "ok": false}
	if port < 0:
		summary["error"] = "no hay ningún puerto UDP libre"
		return summary

	# Tiempos: el servidor escucha, arrancan los enjambres, entran todos y se mide `seconds` segundos.
	var bots_per_swarm: int = ceili(float(bots) / float(swarms)) if bots > 0 else 0
	var settle_seconds: float = SETTLE_SECONDS
	if scenario == "brawl":
		settle_seconds += BRAWL_EXTRA_SETTLE_SECONDS
	elif scenario == "siege":
		settle_seconds += SIEGE_EXTRA_SETTLE_SECONDS
	var settle_ticks: int = ceili(settle_seconds * _tick_rate) + 5 * bots_per_swarm
	var measure_ticks: int = int(run["seconds"]) * _tick_rate
	var server_ticks: int = settle_ticks + measure_ticks + ceili(TAIL_SECONDS * _tick_rate)
	var swarm_ticks: int = server_ticks - ceili(TAIL_SECONDS * _tick_rate) - SWARM_START_MARGIN_TICKS

	var server_report: String = _out_dir.path_join("%s_server.json" % tag)
	var server_log: String = _out_dir.path_join("%s_server.log" % tag)
	var battle_log: String = _out_dir.path_join("%s_battle.jsonl" % tag)
	var server_args := PackedStringArray([
		"--server", "--port=%d" % port, "--max-players=%d" % server_max_players(fakes, bots),
		"--quit-after-ticks=%d" % server_ticks, "--report=%s" % server_report,
	])
	if not str(run["zone"]).is_empty():
		server_args.append("--zone=%s" % run["zone"])
	if fakes > 0:
		server_args.append("--fake-players=%d" % fakes)
		match scenario:
			"cluster", "churn":
				server_args.append("--fake-layout=cluster")
			"spread":
				server_args.append("--fake-layout=spread")
			"brawl":
				server_args.append_array(PackedStringArray(["--fake-layout=cluster",
						"--fake-brain=combat", "--fake-center=%s" % BRAWL_CENTER]))
			"siege":
				server_args.append("--fake-brain=siege")
		if scenario == "churn":
			server_args.append("--fake-churn=%d" % _tick_rate)
		if not str(run["loadout"]).is_empty():
			server_args.append("--fake-loadout=%s" % run["loadout"])
		if scenario == "brawl" and not str(run["loadout"]).is_empty():
			# Los tiradores son arqueros puros y una parte dispara al cielo: flechas que viven sus 2 s, para acercarse al
			# tope de la zona (docs/habilidades.md, secciones 7.3 y 8).
			server_args.append("--fake-archers=%d" % int(run["sky_archers"]))
	if scenario == "siege":
		server_args.append_array(siege_server_args(bool(run.get("npcs", false)), battle_log, settle_ticks))
	DirAccess.remove_absolute(server_report)
	DirAccess.remove_absolute(server_log)
	print("\n== %s%s: %d falsos, %d bots en %d proceso(s), %d s de medida (servidor %d ticks, puerto %d) ==" % [
		scenario, " con PNJ" if bool(run.get("npcs", false)) else "", fakes, bots, swarms if bots > 0 else 0,
		run["seconds"], server_ticks, port])
	var server_pid: int = _launch(server_args, server_log)
	if server_pid <= 0:
		summary["error"] = "no se pudo lanzar el servidor"
		return summary
	var all_pids: Array[int] = [server_pid]

	if not await _wait_until(func() -> bool:
		return FileAccess.get_file_as_string(server_log).contains("escuchando en el puerto") \
				or not OS.is_process_running(server_pid), LISTEN_TIMEOUT_SECONDS):
		summary["error"] = "el servidor no llegó a escuchar"
		return summary
	if not OS.is_process_running(server_pid):
		summary["error"] = "el servidor se cerró al arrancar (mira %s)" % server_log
		return summary

	var swarm_reports: Array[String] = []
	for k: int in (swarms if bots > 0 else 0):
		var count: int = bots / swarms + (1 if k < bots % swarms else 0)
		var report_path: String = _out_dir.path_join("%s_swarm%d.json" % [tag, k])
		DirAccess.remove_absolute(report_path)
		swarm_reports.append(report_path)
		var swarm_args := PackedStringArray([
			"--bots=%d" % count, "--connect=127.0.0.1:%d" % port, "--bot-seed=%d" % (1000 * (k + 1)),
			"--report=%s" % report_path,
		])
		swarm_args.append_array(swarm_quit_args(swarm_ticks))
		if scenario != "spread" and scenario != "siege":
			swarm_args.append("--realm=vardheim")
		if scenario == "brawl":
			swarm_args.append("--bot-brain=combat")
		elif scenario == "siege":
			# Sin --realm: los bots se reparten entre Vardheim y Solmarch.
			swarm_args.append("--bot-brain=siege")
		if not str(run["net_sim"]).is_empty():
			swarm_args.append("--net-sim=%s" % run["net_sim"])
		var pid: int = _launch(swarm_args, _out_dir.path_join("%s_swarm%d.log" % [tag, k]))
		if pid > 0:
			all_pids.append(pid)

	var finished: bool = await _wait_until(func() -> bool:
		for pid: int in all_pids:
			if OS.is_process_running(pid):
				return false
		return true, SLOW_SERVER_FACTOR * float(server_ticks) / float(_tick_rate) + FINISH_MARGIN_SECONDS)
	if not finished:
		for pid: int in all_pids:
			if OS.is_process_running(pid):
				OS.kill(pid)
		summary["error"] = "los procesos no terminaron a tiempo (se mataron)"
	var server_data: Dictionary = _read_json(server_report)
	if server_data.is_empty():
		summary["error"] = str(summary.get("error", "")) + " (el servidor no escribió su informe)"
		return summary
	var swarm_data: Array[Dictionary] = []
	for path: String in swarm_reports:
		swarm_data.append(_read_json(path))
	_summarise(summary, server_data, swarm_data, bots)
	_summarise_window(summary, server_data, server_log, settle_ticks, swarm_ticks)
	if scenario == "brawl" or scenario == "siege":
		_summarise_combat(summary, server_data, swarm_data)
	if scenario == "siege":
		_summarise_siege(summary, server_data, swarm_data, server_log, battle_log, settle_ticks, swarm_ticks)
	summary["ok"] = not summary.has("error")
	return summary


# Cifras del resumen a partir de los informes.
func _summarise(summary: Dictionary, server: Dictionary, swarms: Array[Dictionary], bots: int) -> void:
	var metrics: Dictionary = server.get("metrics", {})
	var sections: Dictionary = metrics.get("sections", {})
	var players: Dictionary = server.get("players", {})
	var sim: Dictionary = server.get("simulate", {})
	var snapshots: Dictionary = server.get("snapshots", {})
	var inputs: Dictionary = server.get("inputs", {})
	var peak: int = int(players.get("peak", 0))
	summary["players_peak"] = peak
	summary["server_ticks"] = int(server.get("ticks", 0))
	# Quién había en el tramo del que salen los percentiles del informe (los últimos 2048 ticks del servidor).
	var samples: int = int((sections.get("tick", {}) as Dictionary).get("samples", ServerMetrics.WINDOW_TICKS))
	var end_tick: int = int(server.get("ticks", 0))
	summary["tail_presence"] = LoadTestSummary.presence(server.get("player_list", []),
			maxi(end_tick - samples + 1, 1), end_tick, end_tick)
	var section_table: Dictionary = {}
	for section: String in SECTIONS:
		var data: Dictionary = sections.get(section, {})
		section_table[section] = {
			"p50": int(data.get("p50", 0)), "p95": int(data.get("p95", 0)), "p99": int(data.get("p99", 0)),
			"max": int(data.get("max", 0)),
		}
	summary["sections_us"] = section_table
	summary["simulate_us_per_character"] = float(sim.get("avg_us", 0.0))
	var sim_p50: int = int((section_table["sim"] as Dictionary)["p50"])
	summary["sim_section_us_per_character"] = float(sim_p50) / float(maxi(peak, 1))
	summary["snapshot_avg_bytes"] = float(snapshots.get("avg_bytes", 0.0))
	summary["snapshot_max_bytes"] = int(snapshots.get("max_bytes", 0))
	summary["snapshot_build_avg_us"] = float(snapshots.get("avg_build_us", 0.0))
	summary["snapshots_sent"] = int(snapshots.get("sent", 0))
	summary["substituted_percent"] = float(inputs.get("substituted_percent", 0.0))
	summary["strikes"] = int((server.get("strikes", {}) as Dictionary).get("total", 0))
	summary["kicks"] = (server.get("kicks", []) as Array).size()
	summary["rejects"] = (server.get("rejects", {}) as Dictionary).size()
	summary["physics_errors"] = int(server.get("physics_errors", 0))
	summary["joined_total"] = int(players.get("joined_total", 0))
	summary["left_total"] = int(players.get("left_total", 0))
	summary["server_kb_out_per_s"] = float(metrics.get("kb_out_per_s", 0.0))
	summary["server_kb_in_per_s"] = float(metrics.get("kb_in_per_s", 0.0))

	# Lo que miden los propios bots.
	var played: int = 0
	var requested: int = 0
	var down_sum: float = 0.0
	var up_sum: float = 0.0
	var down_max: float = 0.0
	var measured: int = 0
	var snapshot_bytes: int = 0
	var snapshot_count: int = 0
	var late: int = 0
	for data: Dictionary in swarms:
		var swarm_bots: Dictionary = data.get("bots", {})
		played += int(swarm_bots.get("played", 0))
		requested += int(swarm_bots.get("requested", 0))
		for client: Dictionary in data.get("clients", []):
			if int(client.get("world_ticks", 0)) < 300:
				continue
			measured += 1
			down_sum += float(client.get("kb_down_per_s", 0.0))
			up_sum += float(client.get("kb_up_per_s", 0.0))
			down_max = maxf(down_max, float(client.get("kb_down_per_s", 0.0)))
		var totals: Dictionary = data.get("totals", {})
		snapshot_bytes += int(totals.get("snapshot_bytes", 0))
		snapshot_count += int(totals.get("snapshots", 0))
		late += int(totals.get("late_snapshots", 0))
	summary["bots_requested"] = requested
	summary["bots_played"] = played
	summary["bots_measured"] = measured
	summary["client_kb_down_per_s_avg"] = down_sum / float(measured) if measured > 0 else 0.0
	summary["client_kb_down_per_s_max"] = down_max
	summary["client_kb_up_per_s_avg"] = up_sum / float(measured) if measured > 0 else 0.0
	summary["client_snapshot_avg_bytes"] = float(snapshot_bytes) / float(snapshot_count) \
			if snapshot_count > 0 else 0.0
	summary["client_late_snapshots"] = late
	if bots > 0 and played < bots:
		summary["error"] = "solo jugaron %d de %d bots" % [played, bots]

	_apply_criterion(summary)


# Cifras del combate de una refriega: lo que cuesta cada parte y lo que baja cada cliente en snapshots y en
# eventos (de los bots reales, que miden sus bytes de aplicación).
func _summarise_combat(summary: Dictionary, server: Dictionary, swarms: Array[Dictionary]) -> void:
	var seconds: float = float(server.get("ticks", 0)) / float(_tick_rate)
	var figures: Dictionary = LoadTestSummary.combat_figures(server, seconds)
	var snapshot_kb: float = 0.0
	var event_kb: float = 0.0
	var wire_kb: float = 0.0
	var measured: int = 0
	var hit_events: int = 0
	var respawns: int = 0
	for data: Dictionary in swarms:
		for client: Dictionary in data.get("clients", []):
			var world_ticks: int = int(client.get("world_ticks", 0))
			if world_ticks < 300:
				continue
			var client_seconds: float = float(world_ticks) / float(_tick_rate)
			measured += 1
			snapshot_kb += float(client.get("snapshot_bytes", 0)) / 1024.0 / client_seconds
			event_kb += float(client.get("event_bytes", 0)) / 1024.0 / client_seconds
			wire_kb += float(client.get("kb_down_per_s", 0.0))
			hit_events += int(client.get("hit_events_seen", 0))
			respawns += int(client.get("respawn_requests", 0))
	figures["clients_measured"] = measured
	figures["client_snapshot_kb_per_s"] = snapshot_kb / float(measured) if measured > 0 else 0.0
	figures["client_event_kb_per_s"] = event_kb / float(measured) if measured > 0 else 0.0
	figures["client_wire_kb_per_s"] = wire_kb / float(measured) if measured > 0 else 0.0
	figures["client_hit_events"] = hit_events
	figures["client_respawn_requests"] = respawns
	figures["rewind_rejected"] = int((server.get("combat", {}) as Dictionary).get("rewind_rejected", 0))
	figures["suspicious"] = ((server.get("combat", {}) as Dictionary).get("suspicious", []) as Array).size()
	figures["seconds"] = seconds
	figures["phase_4"] = LoadTestSummary.phase_4_figures(server, seconds)
	summary["combat"] = figures
	# Criterio de la fase 4: tick y proyectiles por debajo de su presupuesto.
	var sections: Dictionary = summary["sections_us"]
	summary["phase_4_criterion_met"] = int((sections["tick"] as Dictionary)["p99"]) <= MAX_P99_TICK_US_PHASE_4 \
			and int((sections["combat_projectiles"] as Dictionary)["p99"]) <= MAX_P99_PROJECTILES_US


# Cifras del asedio (GUE-16): cómo se comporta el tick a lo largo de la ventana de medida (las marcas de
# métricas que el servidor escribe cada 10 s, cada una sobre los 34 s anteriores, con los PNJ de cada una), qué pasó
# en el fuerte según el registro de batalla (capturas, puertas rotas, muertes de jugadores y de PNJ), lo que cuestan
# las secciones de los PNJ y de las fortalezas, y cuándo llegaron al fuerte los bots reales.
func _summarise_siege(summary: Dictionary, server: Dictionary, swarms: Array[Dictionary], server_log: String,
		battle_log: String, first_tick: int, last_tick: int) -> void:
	var marks: Array[Dictionary] = LoadTestSummary.parse_tick_timeline(FileAccess.get_file_as_string(server_log))
	var figures: Dictionary = {"window": LoadTestSummary.timeline_window(marks, first_tick, last_tick),
			"timeline": marks}
	if FileAccess.file_exists(battle_log):
		var routes: ApproachRoutes = load("res://data/routes/vado_gris.tres") as ApproachRoutes
		var battle: Dictionary = BattleSummary.summarize(FileAccess.get_file_as_string(battle_log), routes)
		figures["battle"] = battle
	var war: Dictionary = (server.get("war", {}) as Dictionary)
	figures["object_states_sent"] = int(war.get("object_states_sent", 0))
	figures["scoreboards_sent"] = int(war.get("scoreboards_sent", 0))
	var sections: Dictionary = (server.get("metrics", {}) as Dictionary).get("sections", {})
	figures["war_section"] = sections.get("war", {})
	figures["npc_brains_section"] = sections.get("npc_brains", {})
	figures["npc_section"] = sections.get("npc", {})
	figures["npcs"] = server.get("npcs", {})
	# Los maniquíes que se crearon (al cerrar el servidor ya no queda ninguno).
	figures["dummies"] = int((server.get("combat", {}) as Dictionary).get("dummies_created", 0))
	figures["fort_arrivals"] = LoadTestSummary.fort_arrivals(swarms, first_tick)
	summary["siege"] = figures


# Porcentaje de entradas sustituidas dentro de la ventana de medida (restando el arranque): de la
# primera línea de métricas del servidor desde [param first_tick] a la última hasta [param last_tick].
# Sin dos líneas en ese rango se queda la cifra de toda la sesión.
func _summarise_window(summary: Dictionary, server: Dictionary, server_log: String, first_tick: int,
		last_tick: int) -> void:
	var cumulative: Dictionary = LoadTestSummary.parse_metrics_log(FileAccess.get_file_as_string(server_log))
	var window: Dictionary = LoadTestSummary.window_substituted(cumulative, server.get("player_list", []),
			first_tick, last_tick, int(server.get("ticks", 0)))
	summary["substituted_window"] = window
	summary["substituted_percent_window"] = float(window["percent"]) if not window.is_empty() \
			else float(summary["substituted_percent"])
	_apply_criterion(summary)


# Criterio de la fase 2 (solo tiene sentido con clientes reales para los KB/s). Las entradas
# sustituidas son las de la ventana de medida, si se ha podido calcular, y si no las de la sesión.
func _apply_criterion(summary: Dictionary) -> void:
	var sections: Dictionary = summary["sections_us"]
	var p99_tick: int = int((sections["tick"] as Dictionary)["p99"])
	var substituted: float = float(summary.get("substituted_percent_window", summary["substituted_percent"]))
	var met: bool = p99_tick < MAX_P99_TICK_US and substituted < MAX_SUBSTITUTED_PERCENT
	if int(summary["bots_measured"]) > 0:
		met = met and float(summary["client_kb_down_per_s_max"]) <= MAX_KB_PER_CLIENT
	summary["criterion_met"] = met


# Imprime el resumen de un escenario y lo añade a summary.txt.
func _print_summary(summary: Dictionary) -> void:
	var lines := PackedStringArray()
	lines.append("== %s: %d falsos, %d bots ==" % [summary["tag"], (summary["run"] as Dictionary)["fakes"],
			(summary["run"] as Dictionary)["bots"]])
	if summary.has("error"):
		lines.append("   ERROR: %s" % summary["error"])
	if summary.has("sections_us"):
		lines.append_array(_summary_lines(summary))
	for line: String in lines:
		print(line)
	var file: FileAccess = FileAccess.open(_out_dir.path_join("summary.txt"),
			FileAccess.READ_WRITE if FileAccess.file_exists(_out_dir.path_join("summary.txt"))
			else FileAccess.WRITE)
	if file != null:
		file.seek_end()
		file.store_string("\n".join(lines) + "\n\n")
		file.close()


func _summary_lines(summary: Dictionary) -> PackedStringArray:
	var lines := PackedStringArray()
	var sections: Dictionary = summary["sections_us"]
	lines.append("   Jugadores (pico): %d   ticks del servidor: %d   altas/bajas: %d/%d" % [
		summary["players_peak"], summary["server_ticks"], summary["joined_total"], summary["left_total"]])
	lines.append("   Tick por sección, µs        p50      p95      p99      máx")
	for section: String in SECTIONS:
		var data: Dictionary = sections[section]
		lines.append("     %-24s %6d   %6d   %6d   %6d" % [section, data["p50"], data["p95"], data["p99"],
				data["max"]])
	var tail: Dictionary = summary.get("tail_presence", {})
	if not tail.is_empty():
		var at_peak: float = float(tail["ticks_at_max"]) / float(maxi(int(tail["ticks"]), 1)) \
				if int(tail["max"]) == int(summary["players_peak"]) else 0.0
		lines.append("   ... de los últimos %d ticks del servidor, con de %d a %d jugadores; con el pico (%d), el %.0f %% de ellos" % [
			tail["ticks"], tail["min"], tail["max"], summary["players_peak"], 100.0 * at_peak])
		if at_peak < MIN_TAIL_AT_PEAK:
			lines.append("   AVISO: los percentiles de arriba no son del pico de jugadores (se fueron antes de que acabara el servidor): mira las marcas de la ventana")
	lines.append("   simulate() por personaje:   %.1f µs   (sección sim p50 / jugadores: %.1f µs)" % [
		summary["simulate_us_per_character"], summary["sim_section_us_per_character"]])
	lines.append("   Snapshot (servidor):        %.0f B de media, %d B como máximo, %.0f µs de construcción cada uno" % [
		summary["snapshot_avg_bytes"], summary["snapshot_max_bytes"], summary["snapshot_build_avg_us"]])
	lines.append("   Entradas sustituidas:       %.2f %% de la sesión entera (con el arranque)   avisos: %d   expulsiones: %d   errores de física: %d" % [
		summary["substituted_percent"], summary["strikes"], summary["kicks"], summary["physics_errors"]])
	var window: Dictionary = summary.get("substituted_window", {})
	if window.is_empty():
		lines.append("   ... en la ventana de medida: sin calcular (no hay dos líneas de métricas del servidor en ella)")
	else:
		lines.append("   ... en la ventana de medida: %.2f %% (%d de %d entradas, ticks %d a %d)" % [
			window["percent"], window["substituted"], window["inputs"], window["from_tick"], window["to_tick"]])
	if summary.has("combat"):
		lines.append_array(_combat_lines(summary["combat"]))
	if summary.has("siege"):
		lines.append_array(_siege_lines(summary["siege"]))
	var run: Dictionary = summary["run"]
	if not str(run["net_sim"]).is_empty():
		lines.append("   Simulador de red de los bots: %s" % run["net_sim"])
	if int(summary["bots_measured"]) > 0:
		lines.append("   Por cliente (%d bots):       bajada %.1f KB/s de media (máx %.1f), subida %.1f KB/s, snapshot de %.0f B" % [
			summary["bots_measured"], summary["client_kb_down_per_s_avg"],
			summary["client_kb_down_per_s_max"], summary["client_kb_up_per_s_avg"],
			summary["client_snapshot_avg_bytes"]])
		lines.append("   Servidor, total:            salida %.1f KB/s, entrada %.1f KB/s" % [
			summary["server_kb_out_per_s"], summary["server_kb_in_per_s"]])
	if summary.has("phase_4_criterion_met"):
		var sections_now: Dictionary = summary["sections_us"]
		lines.append("   Criterio de la fase 4 (p99 del tick <= 16,7 ms y de combat_projectiles <= 1 ms): %s (%.1f ms y %.2f ms)" % [
			"CUMPLIDO" if bool(summary["phase_4_criterion_met"]) else "NO CUMPLIDO",
			float((sections_now["tick"] as Dictionary)["p99"]) / 1000.0,
			float((sections_now["combat_projectiles"] as Dictionary)["p99"]) / 1000.0])
	lines.append("   Criterio de la fase 2 (p99 < 8 ms, <= 37 KB/s por cliente, < 1 %% sustituidas en la ventana): %s%s" % [
		"CUMPLIDO" if bool(summary["criterion_met"]) else "NO CUMPLIDO",
		"" if _is_reference_run(run) else " (solo como referencia: se define con 64 agrupados y 100 ms de RTT)"])
	return lines


# Líneas del resumen de un asedio.
func _siege_lines(figures: Dictionary) -> PackedStringArray:
	var lines := PackedStringArray()
	var window: Dictionary = figures.get("window", {})
	if window.is_empty():
		lines.append("   Tick en la ventana de medida: sin marcas de métricas del servidor en ella")
	else:
		lines.append("   Tick en la ventana (%d marcas de 34 s): p50 %d µs, p99 %d µs (el peor, %d µs), máx %d µs; PNJ de %d a %d; jugadores de %d a %d" % [
			window["marks"], window["p50_us"], window["p99_us"], window["worst_p99_us"], window["max_us"],
			window.get("npcs_min", -1), window.get("npcs_max", -1), window.get("players_min", -1),
			window.get("players_max", -1)])
		if int(window.get("players_min", -1)) != int(window.get("players_max", -1)):
			lines.append("   AVISO: el número de jugadores cambia dentro de la ventana: sus marcas no son todas de la misma carga")
	for entry: Array in [["war", "war_section", "fortalezas"], ["npc_brains", "npc_brains_section", "cerebros de los PNJ"],
			["npc", "npc_section", "generadores de PNJ"]]:
		var data: Dictionary = figures.get(entry[1], {})
		var pushed: int = int(data.get("pushed", 0))
		lines.append("   Sección %s (%s): p50 %d µs, p95 %d µs, p99 %d µs, máx %d µs; media de la sesión %.0f µs" % [
			entry[0], entry[2], int(data.get("p50", 0)), int(data.get("p95", 0)), int(data.get("p99", 0)),
			int(data.get("max", 0)), float(data.get("total_us", 0)) / float(pushed) if pushed > 0 else 0.0])
	lines.append("   Fortalezas: %d OBJECT_STATE y %d marcadores enviados" % [figures["object_states_sent"],
		figures["scoreboards_sent"]])
	var npcs: Dictionary = figures.get("npcs", {})
	lines.append("   PNJ: %d de guerra vivos al acabar (%d puestos), %d aparecidos y %d muertos, %d avisos TELEGRAPH; %d maniquíes creados" % [
		int(npcs.get("alive", 0)), int(npcs.get("slots", 0)), int(npcs.get("spawned", 0)), int(npcs.get("died", 0)),
		int(npcs.get("telegraphs", 0)), figures.get("dummies", 0)])
	var arrivals: Dictionary = figures.get("fort_arrivals", {})
	if int(arrivals.get("bots", 0)) > 0:
		lines.append("   Bots reales en el fuerte (a menos de %.0f m del círculo): %d de %d antes de la ventana, %d en total; el último, en el tick %d" % [
			BotBrain.SIEGE_RALLY_FORT_RADIUS, arrivals["before_window"], arrivals["bots"], arrivals["arrived"],
			arrivals["last_tick"]])
	var battle: Dictionary = figures.get("battle", {})
	if not battle.is_empty():
		var deaths: Dictionary = battle["deaths"]
		var by_route: Dictionary = deaths["by_route"]
		lines.append("   Batalla: %d capturas, %d puertas rotas, %d muertes de jugadores (puente %d, vado %d, explanada y patio %d, pasarela %d, otros %d) y %d de PNJ; avisos %s" % [
			(battle["captures"] as Array).size(), (battle["gate_breaks"] as Array).size(), deaths["players"],
			int(by_route.get("bridge", 0)), int(by_route.get("ford", 0)), int(by_route.get("gate", 0)),
			int(by_route.get("walkway", 0)), int(by_route.get("other", 0)), int(deaths.get("npcs", 0)),
			battle["war_events"]])
		for gate_break: Dictionary in battle["gate_breaks"]:
			lines.append("     puerta rota %.1f s después del primer golpe" % gate_break["seconds"])
		for capture: Dictionary in battle["captures"]:
			lines.append("     captura por el reino %d a los %.0f s del ciclo (%.0f s desde la caída del capitán)" % [
				capture["realm"], capture["seconds_from_cycle_start"], capture["seconds_from_captain_down"]])
	return lines


# Líneas del resumen de una refriega.
func _combat_lines(figures: Dictionary) -> PackedStringArray:
	var lines := PackedStringArray()
	lines.append("   Combate:                    %d golpes (%d bloqueados), %d muertes, %d eventos (%.1f/s), %d paquetes de evento" % [
		figures["hits"], figures["blocked"], figures["deaths"], figures["events"],
		float(figures["events"]) / maxf(float(figures["seconds"]), 1.0), figures["events_sent"]])
	lines.append("   Golpes y rebobinado:        %d comprobaciones en %d ticks, %.1f µs cada una (la sección combat_resolve es el %.0f %% de combat); %d rebobinados rechazados, %d sospechosos" % [
		figures["hit_tests"], figures["resolve_busy_ticks"], figures["resolve_us_per_test"],
		100.0 * float(figures["resolve_share"]), figures["rewind_rejected"], figures["suspicious"]])
	lines.append("   Eventos:                    %.1f µs de envío por evento; servidor, %.1f KB/s de eventos" % [
		figures["events_us_per_event"], figures["event_kb_per_s"]])
	var kit: Dictionary = figures.get("phase_4", {})
	if not kit.is_empty():
		lines.append("   Flechas (fase 4):           %d disparos (%.1f/s), %d a personajes, %d al mundo, %d bloqueadas, %d inofensivas; pico de %d vivas (tope %d), %d echadas por el tope; %d rebobinados rechazados" % [
			kit["fired"], kit["fired_per_s"], kit["character_hits"], kit["world_hits"], kit["arrow_blocked"],
			kit["harmless"], kit["peak"], kit["zone_cap"], kit["evicted"], kit["rewind_rejected"]])
		lines.append("   Flechas, coste:             %.1f µs por tick ocupado (%d ticks), %d segmentos y %d pruebas de cápsula; %d SPAWN/DESPAWN, %.1f KB/s" % [
			kit["projectile_us_per_busy_tick"], kit["busy_ticks"], kit["segments"], kit["capsule_tests"],
			kit["messages"], kit["kb_per_s"]])
		lines.append("   Kit:                        %d efectos aplicados, %d pulsos, %d curado, %d interrupciones; %d derribos, %d levantados, %d rematados, %d desangrados" % [
			kit["status_applied"], kit["pulses"], kit["healed"], kit["interrupts"], kit["downs"], kit["revives"],
			kit["executions"], kit["bled_out"]])
	if int(figures["clients_measured"]) > 0:
		lines.append("   Bajada en detalle (%d bots): snapshots %.1f KB/s + eventos %.1f KB/s (de aplicación); bajada de ENet %.1f KB/s" % [
			figures["clients_measured"], figures["client_snapshot_kb_per_s"],
			figures["client_event_kb_per_s"], figures["client_wire_kb_per_s"]])
	return lines


## El aforo con el que se lanza el servidor de un escenario de [param fakes] falsos y [param bots] bots reales: todos y un
## margen de 8, siempre con [code]--max-players[/code] explícito. Sin él, el Vado Gris tendría su aforo propio (40, el
## límite por batalla medido con el kit de la fase 4: [method NetZones.max_players], docs/red.md, sección 14) y los
## asedios de 32 contra 32 y 64 contra 64 de [constant SIEGE_MATRIX], o las refriegas de 64 y 128, no cabrían.
static func server_max_players(fakes: int, bots: int) -> int:
	return fakes + bots + 8


## Las opciones con las que se cierra un enjambre: cuando alguno de sus bots ve el tick [param swarm_ticks] del servidor
## ([code]--quit-at-server-tick[/code]) y, como cota, tras [constant SLOW_SERVER_FACTOR] veces ese número de ticks de su
## propio reloj ([code]--quit-after-ticks[/code]).
static func swarm_quit_args(swarm_ticks: int) -> PackedStringArray:
	return PackedStringArray([
		"--quit-at-server-tick=%d" % swarm_ticks,
		"--quit-after-ticks=%d" % ceili(float(swarm_ticks) * SLOW_SERVER_FACTOR),
	])


## Opciones del servidor propias de un asedio: el registro de batalla en [param battle_log] y, sin [param with_npcs]
## (el asedio de F6a), [code]--no-npcs[/code] y la orden que da por muerto al capitán al terminar el tick
## [param open_circle_tick] (el principio de la ventana de medida), para que el círculo se abra. Con
## [param with_npcs] el servidor lleva sus PNJ y nadie le ayuda.
static func siege_server_args(with_npcs: bool, battle_log: String, open_circle_tick: int) -> PackedStringArray:
	var args := PackedStringArray(["--battle-log=%s" % battle_log])
	if not with_npcs:
		args.append_array(PackedStringArray(["--no-npcs", "--run-at=%d:fort_kill_captain" % open_circle_tick]))
	return args


# true si el escenario es aquel para el que se define el criterio de la fase 2 (docs/red.md, 16): 64
# jugadores falsos agrupados, con bots y 100 ms de RTT.
func _is_reference_run(run: Dictionary) -> bool:
	return run["scenario"] == "cluster" and int(run["fakes"]) == 64 and int(run["bots"]) > 0 \
			and str(run["net_sim"]).begins_with("rtt=100")


# --- Procesos y ayudas ------------------------------------------------------------------------

# Lanza otro Godot sin ventana sobre este proyecto con [param user_args] y su registro en [param log_path].
# Su salida estándar se mezcla con la de esta herramienta (--quiet también vaciaría el registro, que es
# por donde se sabe que el servidor ya escucha); el resumen de cada escenario queda en summary.txt.
func _launch(user_args: PackedStringArray, log_path: String) -> int:
	var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"),
			"--log-file", log_path, "--"])
	args.append_array(user_args)
	var pid: int = OS.create_process(OS.get_executable_path(), args)
	if pid > 0:
		_pids.append(pid)
	return pid


# Espera a que se cumpla [param condition] hasta [param timeout_seconds]. false si pasa el tiempo.
func _wait_until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while not condition.call():
		if Time.get_ticks_msec() > deadline:
			return false
		await create_timer(0.25).timeout
	return true


func _free_port() -> int:
	for port: int in range(FIRST_PORT, LAST_PORT):
		var probe := PacketPeerUDP.new()
		var error: Error = probe.bind(port)
		probe.close()
		if error == OK:
			return port
	return -1


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK:
		return {}
	return json.data if json.data is Dictionary else {}


func _option(args: PackedStringArray, prefix: String, fallback: String) -> String:
	for arg: String in args:
		if arg.begins_with(prefix):
			return arg.trim_prefix(prefix).strip_edges().trim_prefix("\"").trim_suffix("\"")
	return fallback


func _int_option(args: PackedStringArray, prefix: String, fallback: int) -> int:
	var text: String = _option(args, prefix, "")
	return text.to_int() if text.is_valid_int() else fallback
