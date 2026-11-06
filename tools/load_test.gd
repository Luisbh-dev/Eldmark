extends SceneTree
## Phase 2 load test (docs/networking.md, sections 14 and 16, "Load"; TEC-11). Outside the test runner:
## it launches a server and the clients as Godot processes, waits for them and summarises what the
## server (and the bot swarm) measures in one report per scenario.
## [br][br]
## [b]Usage[/b], from the project root (the console [code]godot[/code]):
## [codeblock]
## # One scenario: 64 clustered fake players and 10 real clients (--bots) for 30 s of measurement
## godot --headless --path . -s res://tools/load_test.gd -- --scenario=cluster --fakes=64 --bots=10
##
## # The phase 2 battery (see MATRIX): clustered with 2, 10 and 50 bots, the criterion with 100 ms of RTT,
## # spread, joins and leaves, and 128 and 256 fake players; 120 s of measurement per scenario (about 25 min)
## godot --headless --path . -s res://tools/load_test.gd -- --matrix
##
## # 128 and 256 players: the real clients are split among several swarm processes
## godot --headless --path . -s res://tools/load_test.gd -- --fakes=128 --bots=100 --swarms=2
## godot --headless --path . -s res://tools/load_test.gd -- --fakes=156 --bots=100 --swarms=2 --seconds=20
##
## # The phase 3 battery (see BRAWL_MATRIX): clustered brawls of 32, 40, 64 and 128 combatants with the
## # combat brain (server-side fakes and real bots that fight); 60 s of measurement each. Since H5 (phase 4,
## # docs/abilities.md, section 7.3) the fakes fight with the kit and half of them use the marksman
## # loadout (--fake-loadout=marksman:50), pure archers of which half fire at the sky (--fake-archers=50: their
## # arrows live 2 s): arrows, abilities, potions and knockdowns, with the fort NPCs in the zone
## godot --headless --path . -s res://tools/load_test.gd -- --brawl
## # A single brawl: 54 combat fakes and 10 real combat clients (64 in total)
## godot --headless --path . -s res://tools/load_test.gd -- --scenario=brawl --fakes=54 --bots=10
##
## # The phase 4 battery (see SIEGE_MATRIX, GUE-16): sieges of 32 vs 32 and 64 vs 64 at the gate and the
## # circle of the Vado Gris fort, 120 s of measurement each (about 4 min per scenario)
## godot --headless --path . -s res://tools/load_test.gd -- --siege
## # A single siege: 54 siege fakes and 10 real clients (--bot-brain=siege), 32 vs 32
## godot --headless --path . -s res://tools/load_test.gd -- --scenario=siege --fakes=54 --bots=10 --seconds=60
## # The same with the real NPCs and the fort without help (F6b): 32 vs 32, 120 s of measurement
## godot --headless --path . -s res://tools/load_test.gd -- --scenario=siege --fakes=54 --bots=10 --seconds=120 --npcs
##
## # TEC-27 (docs/platform.md §10.2): 64 clustered real bots without DTLS and with DTLS against the same zone, alternating
## # (without, with, without, with), 60 s of measurement per pass, and the comparison with the criterion (the tick p99
## # does not rise by more than 10 %)
## godot --headless --path . -s res://tools/load_test.gd -- --dtls-compare
## # Any scenario over DTLS (with the test certificate, or with --dtls-cert, --dtls-key and --dtls-name)
## godot --headless --path . -s res://tools/load_test.gd -- --scenario=cluster --fakes=0 --bots=64 --swarms=2 --dtls
## [/codeblock]
## [b]Options[/b] (after [code]--[/code]):
## [br]- [code]--scenario=cluster|spread|churn[/code] (default [code]cluster[/code]):
## [br]  · [code]cluster[/code], clustered: all the fake players and all the bots around the same point
## (the Vardheim camp; the server places them with [code]--fake-layout=cluster[/code]), within about
## 60 m of each other.
## [br]  · [code]spread[/code], spread out: the fakes scattered across the zone ([code]--fake-layout=spread[/code]) and
## the bots in the two camps.
## [br]  · [code]churn[/code], joins and leaves: like [code]cluster[/code], but every second the oldest fake player
## leaves and a new one joins ([code]--fake-churn=60[/code]).
## [br]  · [code]brawl[/code], clustered brawl (TEC-15): the fakes fight with the combat brain
## ([code]--fake-brain=combat[/code]) in a ring around [constant BRAWL_CENTER], in the open field
## next to the Vardheim camp (the camps' safe zone would keep them from fighting), and the real
## bots ([code]--bots[/code], all from Vardheim) leave the camp and fight too
## ([code]--bot-brain=combat[/code]): they receive snapshots and ENTITY_EVENT and send their view offset, so
## the server does the real rewind. The fakes are half from each realm.
## [br]  · [code]siege[/code], siege (GUE-16): the fakes besiege and defend the Vado Gris fort
## ([code]--fake-brain=siege[/code], split between Vardheim and Solmarch) and the real bots ([code]--bots[/code],
## one from each realm in turns) carry the siege brain ([code]--bot-brain=siege[/code], which follows the route,
## hits the gate, enters the circle and fights without simulating). Without [code]--npcs[/code] it is the F6a siege: the
## server starts without NPCs ([code]--no-npcs[/code]) and opens the circle with a scheduled command
## ([code]--run-at=<tick>:fort_kill_captain[/code]). With [code]--npcs[/code] (F6b) it starts with its NPCs (the Hollow, the Ford
## Captain, the owner's garrison and the Guardians) and the fort runs on its own: nobody kills the captain for them. In both cases
## it writes a battle log ([code]--battle-log[/code]) that the summary reads. The measurement window starts once
## the bots have reached the gate ([constant SIEGE_EXTRA_SETTLE_SECONDS]); the summary says how many real bots
## had reached the fort before it (GUE-44: those that join late wait for their own in the camp).
## [br]- [code]--fakes=N[/code] fake players (entries injected into the queue, no network; default 64).
## [br]- [code]--bots=N[/code] real clients: [code]--bots=N[/code] processes ([BotSwarm]) that join one every 5 ticks
## (default 0).
## [br]- [code]--swarms=K[/code] swarm processes among which the bots are split (default 1; one process
## handles a few dozen).
## [br]- [code]--seconds=S[/code] seconds of measurement with everyone in (default 30; 120 with
## [code]--matrix[/code], as docs/networking.md, 16 requires).
## [br]- [code]--net-sim=rtt=100,jitter=10,loss=1[/code] network simulator for the bots. With [code]--matrix[/code]
## each [constant MATRIX] scenario sets it (the 100 ms RTT one); the option only applies to those that
## do not carry one.
## [br]- [code]--zone=<id>[/code] server zone (by default the usual one, Vado Gris).
## [br]- [code]--fake-loadout=<template>[:<percentage>][/code] equipment template of the fakes (passed on to the
## server). In brawls, [constant BRAWL_LOADOUT] by default.
## [br]- [code]--sky-archers=<percentage>[/code] in brawls with marksmen: what share of them fires at the sky
## (default [constant BRAWL_SKY_ARCHERS_PERCENT]; with 100, a peak of 54 of the 64 cap with 64 combatants;
## to fill the cap and measure the evictions, all marksmen: [code]--fake-loadout=marksman:100
## --sky-archers=100[/code]: peak of 64 and about 4600 evicted over the whole run).
## [br]- [code]--out=<folder>[/code] where the reports and logs go (default [code]build/load_test[/code]).
## [br]- [code]--siege[/code] launches the [constant SIEGE_MATRIX] battery (120 s of measurement each).
## [br]- [code]--npcs[/code] (only in sieges, also with [code]--siege[/code]): with the zone's NPCs and without the
## command that kills the captain (see [code]siege[/code] above). In the other scenarios it changes nothing.
## [br]- [code]--brawl[/code] launches the [constant BRAWL_MATRIX] brawl battery (60 s of measurement each).
## [br]- [code]--dtls[/code] the server opens the port over DTLS ([code]--dtls-cert --dtls-key[/code]) and the
## swarms connect with the pinned certificate ([code]--dtls-cert --dtls-name[/code]): by default, the test ones
## ([constant DTLS_TEST_CERT]); with [code]--dtls-cert=<pem> --dtls-key=<pem> --dtls-name=<cn>[/code], others.
## [br]- [code]--dtls-compare[/code] the TEC-27 campaign: the scenario (by default [code]cluster[/code] with
## [constant DTLS_COMPARE_BOTS] bots in [constant DTLS_COMPARE_SWARMS] swarms and [constant DTLS_COMPARE_FAKES]
## fakes, [constant DTLS_COMPARE_SECONDS] s) without and with DTLS, alternating, [code]--repeat=N[/code] times each
## ([constant DTLS_COMPARE_REPEAT]); at the end, the comparison ([method dtls_comparison]) and the criterion. Exits with 1 if it
## is not met and implies [code]--check[/code].
## [br]- [code]--soak[/code] the long run (TEC-12, TEC-20): [constant SOAK_FAKES] clustered fake players and [constant SOAK_BOTS]
## real clients that join and leave all the time (each stays [constant SOAK_BOT_MIN_SECONDS] to [constant SOAK_BOT_MAX_SECONDS] s and
## comes back after a short pause), for [code]--seconds=[/code] ([constant SOAK_SECONDS] = 2 h by default; [code]--port=[/code] fixes the port).
## Every report rewrite of the server (10 s) is a sample of tick p99, static memory and object counts, kept in
## [code]soak_*_series.json[/code] (draw it with [code]tools/soak_chart.py[/code]). The criterion ([method LoadTestSummary.soak_figures]):
## after the first 10 minutes, memory and objects grow less than 10 %, the p99 of the tick drifts less than 10 %, and there are no kicks
## or errors. It never runs at the same time as other measurements or videos: it needs the machine to itself.
## [br]- [code]--check[/code] exits with code 1 if any scenario fails the phase 2 criterion.
## [br][br]
## [b]What it measures[/b] (from the server's [code]--report[/code], from [method ZoneServer.write_report], and from that of each
## swarm): the p50, p99 and maximum of the tick and of each of its sections (network, simulation, history,
## snapshots, flush) in µs; the µs of [code]PlayerCharacter.simulate()[/code] per character; the size of the
## snapshots and the µs to build each one; the upload and download KB/s per client; the percentage of
## substituted inputs, the warnings and the kicks. In brawls, in addition, the combat sections
## ([code]combat[/code], with [code]combat_resolve[/code] —hits with rewind— and [code]combat_events[/code]
## —sending the ENTITY_EVENTs— inside it), the µs per hit check, the hits, the deaths and the events
## per second, and each client's download split into snapshots and events (KB/s). In sieges, in addition, the
## NPC sections ([code]npc_brains[/code], their brains, and [code]npc[/code], the spawners) and the fortress
## section ([code]war[/code]), with their average over the whole session, and the NPCs present at each metrics mark of the
## server (their [code]simulate()[/code] goes in [code]sim[/code], along with the players'). The server's percentiles are from the last 2048
## ticks (34 s) of its run, so the server keeps going a few extra seconds after the bots
## join, so that the window is steady-state only. The swarms close by the server's tick
## ([code]--quit-at-server-tick[/code], [constant TAIL_SECONDS] and [constant SWARM_START_MARGIN_TICKS] before its end),
## not by their own clock: with many players the server runs slower than real time and the bots used to leave
## too early. The summary says how many players there were in those 2048 ticks and at the window's marks, and warns if they are not
## those of the peak.
## [br][br]
## [b]Substituted inputs.[/b] The server report gives the percentage for the whole session, with the startup
## included (each bot loses a few dozen inputs while [TickSync] finds its lead, more with
## 100 ms of RTT). Both figures are shown: the session's and the measurement window's, which subtracts what had
## accumulated at the start ([LoadTestSummary]; it comes from the metrics lines the server writes every
## 600 ticks, so the window runs from the first one after the bots join to the last one before they
## leave). The criterion uses the window's.
## [br][br]
## [b]Phase 4 criterion[/b] (docs/abilities.md, sections 7.3 and 8): in the 64 brawl with half
## marksmen, tick p99 below 16.7 ms and the [code]combat_projectiles[/code] section below
## 1 ms (p99); it is shown with the peak of live arrows against the zone cap and those the cap evicted.
## [br][br]
## [b]Phase 2 criterion[/b] (docs/networking.md, 14 and 16), with 64 clustered players and 100 ms of RTT on the
## bots: tick p99 below 8 ms, at most 37 KB/s download per client and less than 1 % of
## substituted inputs. With other sizes or scenarios it is shown for reference.
## [br][br]
## The figures depend on the machine and on whatever else runs on it: the server, the swarm and whoever launches it
## share cores. Each server uses a different port starting from 25000.

const FIRST_PORT: int = 25000
const LAST_PORT: int = 26000
## Seconds to wait, at most, for the server to start listening.
const LISTEN_TIMEOUT_SECONDS: float = 40.0
## Extra seconds, on top of the expected duration, to wait for the processes to finish.
const FINISH_MARGIN_SECONDS: float = 60.0
## Seconds left, after it starts listening, for the processes to start and all the bots to join
## before the measurement window (5 ticks per bot of each swarm are added).
const SETTLE_SECONDS: float = 8.0
## Seconds the server keeps running after the bots leave (short, so as not to pollute the window).
const TAIL_SECONDS: float = 2.0
## Ticks of margin between the swarm closing and the server closing (swarm process startup).
const SWARM_START_MARGIN_TICKS: int = 90
## The swarm closes by the server's tick ([code]--quit-at-server-tick[/code]): with many players the server
## runs slower than real time, and one that closed by its own clock would leave before the window ended
## (with 128 players, at 8400 ticks out of 10 850: the percentiles of the last stretch came from 118 players with no
## clients; F6b review). As an upper bound, and to wait for the processes, a server up to this many times
## slower than real time is accepted.
const SLOW_SERVER_FACTOR: float = 3.0
## If less than this share of the server's last 2048 ticks (the ones its report's percentiles come from) had the
## peak of players, the summary warns that those percentiles are not from the load that was meant to be measured.
const MIN_TAIL_AT_PEAK: float = 0.75
## Phase 2 criterion.
const MAX_P99_TICK_US: int = 8000
const MAX_KB_PER_CLIENT: float = 37.0
const MAX_SUBSTITUTED_PERCENT: float = 1.0
## Tick sections that are shown (the combat ones go inside [code]combat[/code]).
const SECTIONS: Array[String] = ["tick", "net", "npc_brains", "sim", "combat", "combat_resolve", "combat_projectiles",
		"combat_events", "war", "npc", "history", "snapshot", "flush"]
## Loadout of the fakes in a brawl (phase 4, H5): half marksmen, pure archers, of which this
## percentage fires at the sky ([code]--fake-archers[/code]).
const BRAWL_LOADOUT: String = "marksman:50"
const BRAWL_SKY_ARCHERS_PERCENT: int = 50
## Phase 4 criterion (docs/abilities.md, sections 7.3 and 8): p99 of the tick and of the projectiles section.
const MAX_P99_TICK_US_PHASE_4: int = 16700
const MAX_P99_PROJECTILES_US: int = 1000
## Battery for [code]--matrix[/code]: [scenario, fake players, bots, bots' network simulator].
## The first three are the usual ones (no delay); the fourth is the phase 2 criterion measured as
## docs/networking.md, 16 requires (64 clustered and 100 ms of RTT); then spread, joins and leaves, and the sizes
## of 128 and 256 fake players.
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
## Seconds of measurement for each [constant MATRIX] scenario (docs/networking.md, 16: 120 s each).
const MATRIX_SECONDS: int = 120
## Battery for [code]--brawl[/code] (TEC-15): [scenario, fake players, real bots, bots' network
## simulator]. The combatants are the fakes plus the ten real bots: 32, 40, 64 and 128 in total. The 40 one is the
## per-battle player limit with the phase 4 kit (docs/networking.md, section 14) and the Vado Gris capacity.
const BRAWL_MATRIX: Array[Array] = [
	["brawl", 22, 10, ""],
	["brawl", 30, 10, ""],
	["brawl", 54, 10, ""],
	["brawl", 118, 10, ""],
]
## Seconds of measurement for each [constant BRAWL_MATRIX] brawl.
const BRAWL_SECONDS: int = 60
## Point (x, z) in Vado Gris where the fakes of a brawl gather: open field 18 m from the
## edge of the Vardheim camp's safe zone (z = -138, radius 24) and about 34 m from the north
## arm of the river, with no obstacles from here to the camp.
const BRAWL_CENTER: String = "0,-96"
## Extra seconds left, in a brawl, before the measurement window: the real bots leave
## the camp and take a few seconds to reach the ring.
const BRAWL_EXTRA_SETTLE_SECONDS: float = 12.0
## Battery for [code]--siege[/code] (GUE-16): [scenario, fake players, real bots, bots' network
## simulator]. The two sides are the fakes plus the ten real bots split in two: 32 vs 32 (54 + 10) and 64 vs 64
## (118 + 10).
const SIEGE_MATRIX: Array[Array] = [
	["siege", 54, 10, ""],
	["siege", 118, 10, ""],
]
## Seconds of measurement for each [constant SIEGE_MATRIX] siege (docs/fortress.md, section 7: 120 s).
const SIEGE_SECONDS: int = 120
## Extra seconds left, in a siege, before the measurement window: the bots leave their camps
## and take 25 to 45 s to reach the gate (the bridge, direct; the ford, longer).
const SIEGE_EXTRA_SETTLE_SECONDS: float = 50.0
## Seconds of measurement for a single scenario.
const DEFAULT_SECONDS: int = 30

## The soak (--soak): fake players, real clients that come and go, duration and the bounds of how long each client stays.
const SOAK_FAKES: int = 40
const SOAK_BOTS: int = 8
const SOAK_SECONDS: int = 7200
const SOAK_BOT_MIN_SECONDS: int = 60
const SOAK_BOT_MAX_SECONDS: int = 180
## Pause before a client that left comes back.
const SOAK_BOT_PAUSE_MIN_SECONDS: int = 5
const SOAK_BOT_PAUSE_MAX_SECONDS: int = 20
## Seconds between two samples (the server rewrites its report every 10 s).
const SOAK_SAMPLE_SECONDS: float = 10.0
## Certificate, key and DTLS name of [code]--dtls[/code] if no others are given: the test ones
## (docs/platform.md §10.2).
const DTLS_TEST_CERT: String = "res://tests/fixtures/dtls/zone_cert.pem"
const DTLS_TEST_KEY: String = "res://tests/fixtures/dtls/zone_key.pem"
const DTLS_TEST_NAME: String = "zona-pruebas.eldmark.test"
## Campaign of [code]--dtls-compare[/code] (TEC-27, docs/platform.md §10.2): by default, 64 real bots with no fakes
## in two swarms, clustered ([code]cluster[/code]: every snapshot goes full), 60 s of measurement, and two passes of each
## (without, with, without, with).
const DTLS_COMPARE_FAKES: int = 0
const DTLS_COMPARE_BOTS: int = 64
const DTLS_COMPARE_SWARMS: int = 2
const DTLS_COMPARE_SECONDS: int = 60
const DTLS_COMPARE_REPEAT: int = 2
## TEC-27 criterion (provisional, pending the user): DTLS does not raise the tick p99 by more than this fraction.
const MAX_DTLS_P99_RISE: float = 0.10

var _pids: Array[int] = []
var _out_dir: String = ""
var _tick_rate: int = 60


func _initialize() -> void:
	_run()


func _run() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var runs: Array[Dictionary] = []
	if args.has("--dtls-compare"):
		# TEC-27: the same scenario without DTLS and with DTLS, alternating, --repeat times each.
		var repeat: int = maxi(_int_option(args, "--repeat=", DTLS_COMPARE_REPEAT), 1)
		for i: int in repeat:
			for with_dtls: bool in [false, true]:
				var run: Dictionary = _make_run(args, _option(args, "--scenario=", "cluster"),
						_int_option(args, "--fakes=", DTLS_COMPARE_FAKES), _int_option(args, "--bots=", DTLS_COMPARE_BOTS), "",
						DTLS_COMPARE_SECONDS)
				run["swarms"] = maxi(_int_option(args, "--swarms=", DTLS_COMPARE_SWARMS), 1)
				run["dtls"] = with_dtls
				run["pass"] = i + 1
				runs.append(run)
	elif args.has("--soak"):
		runs.append(_make_run(args, "soak", _int_option(args, "--fakes=", SOAK_FAKES),
				_int_option(args, "--bots=", SOAK_BOTS), "", SOAK_SECONDS))
	elif args.has("--matrix"):
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
	var output: Variant = summaries
	if args.has("--dtls-compare"):
		var comparison: Dictionary = dtls_comparison(summaries)
		_print_lines(_dtls_comparison_lines(comparison))
		output = {"runs": summaries, "dtls_comparison": comparison}
		if not bool(comparison.get("criterion_met", false)):
			failed = true
	var file: FileAccess = FileAccess.open(_out_dir.path_join("summary.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(output, "\t"))
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


# [param net_sim] is the scenario's (the battery's); empty = the one from --net-sim.
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
		"dtls": args.has("--dtls"),
		"dtls_cert": _option(args, "--dtls-cert=", ProjectSettings.globalize_path(DTLS_TEST_CERT)),
		"dtls_key": _option(args, "--dtls-key=", ProjectSettings.globalize_path(DTLS_TEST_KEY)),
		"dtls_name": _option(args, "--dtls-name=", DTLS_TEST_NAME),
	}


# --- One scenario -----------------------------------------------------------------------------

# Launches the server and the swarms, waits for them to finish and returns the summary of what was measured.
func _run_scenario(run: Dictionary) -> Dictionary:
	var scenario: String = run["scenario"]
	if scenario == "soak":
		return await _run_soak(run)
	var fakes: int = run["fakes"]
	var bots: int = run["bots"]
	var swarms: int = mini(run["swarms"], maxi(bots, 1))
	var tag: String = "%s_%df_%db" % [scenario, fakes, bots]
	if not str(run["net_sim"]).is_empty():
		tag += "_" + String(run["net_sim"]).replace("=", "").replace(",", "_")
	if bool(run.get("npcs", false)):
		tag += "_npcs"
	if bool(run.get("dtls", false)):
		tag += "_dtls"
	if run.has("pass"):
		tag += "_%d" % int(run["pass"])
	var port: int = _free_port()
	var summary: Dictionary = {"tag": tag, "run": run, "port": port, "ok": false}
	if port < 0:
		summary["error"] = "no hay ningún puerto UDP libre"
		return summary

	# Timings: the server listens, the swarms start, everyone joins and `seconds` seconds are measured.
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
			# The marksmen are pure archers and a share of them fire at the sky: arrows that live their 2 s, to get close to the
			# zone cap (docs/abilities.md, sections 7.3 and 8).
			server_args.append("--fake-archers=%d" % int(run["sky_archers"]))
	if scenario == "siege":
		server_args.append_array(siege_server_args(bool(run.get("npcs", false)), battle_log, settle_ticks))
	if bool(run.get("dtls", false)):
		server_args.append_array(dtls_server_args(run))
	DirAccess.remove_absolute(server_report)
	DirAccess.remove_absolute(server_log)
	print("\n== %s%s%s: %d falsos, %d bots en %d proceso(s), %d s de medida (servidor %d ticks, puerto %d) ==" % [
		scenario, " con PNJ" if bool(run.get("npcs", false)) else "", " con DTLS" if bool(run.get("dtls", false)) else "",
		fakes, bots, swarms if bots > 0 else 0, run["seconds"], server_ticks, port])
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
			# Without --realm: the bots are split between Vardheim and Solmarch.
			swarm_args.append("--bot-brain=siege")
		if not str(run["net_sim"]).is_empty():
			swarm_args.append("--net-sim=%s" % run["net_sim"])
		if bool(run.get("dtls", false)):
			swarm_args.append_array(dtls_swarm_args(run))
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


# Summary figures from the reports.
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
	# Who was present in the stretch the report's percentiles come from (the server's last 2048 ticks).
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
	# Whether the server opened the port with DTLS and whether all the swarms connected with it (TEC-27).
	summary["server_dtls"] = bool(server.get("dtls", false))
	var swarms_dtls: bool = not swarms.is_empty()
	for data: Dictionary in swarms:
		swarms_dtls = swarms_dtls and bool(data.get("dtls", false))
	summary["swarms_dtls"] = swarms_dtls
	if bool((summary["run"] as Dictionary).get("dtls", false)) and not bool(summary["server_dtls"]):
		summary["error"] = "se pidió DTLS y el servidor no lo usó"

	# What the bots themselves measure.
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


# Combat figures of a brawl: what each part costs and what each client downloads in snapshots and in
# events (from the real bots, which measure their application bytes).
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
	# Phase 4 criterion: tick and projectiles below their budget.
	var sections: Dictionary = summary["sections_us"]
	summary["phase_4_criterion_met"] = int((sections["tick"] as Dictionary)["p99"]) <= MAX_P99_TICK_US_PHASE_4 \
			and int((sections["combat_projectiles"] as Dictionary)["p99"]) <= MAX_P99_PROJECTILES_US


# Siege figures (GUE-16): how the tick behaves along the measurement window (the metrics marks
# that the server writes every 10 s, each over the previous 34 s, with the NPCs of each one), what happened
# at the fort according to the battle log (captures, broken gates, player and NPC deaths), what
# the NPC and fortress sections cost, and when the real bots reached the fort.
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
	# The dummies that were created (when the server closes none are left).
	figures["dummies"] = int((server.get("combat", {}) as Dictionary).get("dummies_created", 0))
	figures["fort_arrivals"] = LoadTestSummary.fort_arrivals(swarms, first_tick)
	summary["siege"] = figures


# Percentage of substituted inputs within the measurement window (subtracting the startup): from the
# first server metrics line from [param first_tick] to the last one up to [param last_tick].
# Without two lines in that range, the whole-session figure is kept.
func _summarise_window(summary: Dictionary, server: Dictionary, server_log: String, first_tick: int,
		last_tick: int) -> void:
	var cumulative: Dictionary = LoadTestSummary.parse_metrics_log(FileAccess.get_file_as_string(server_log))
	var window: Dictionary = LoadTestSummary.window_substituted(cumulative, server.get("player_list", []),
			first_tick, last_tick, int(server.get("ticks", 0)))
	summary["substituted_window"] = window
	summary["substituted_percent_window"] = float(window["percent"]) if not window.is_empty() \
			else float(summary["substituted_percent"])
	_apply_criterion(summary)


# Phase 2 criterion (only meaningful with real clients for the KB/s). The substituted
# inputs are those of the measurement window, if it could be computed, and otherwise those of the session.
func _apply_criterion(summary: Dictionary) -> void:
	var sections: Dictionary = summary["sections_us"]
	var p99_tick: int = int((sections["tick"] as Dictionary)["p99"])
	var substituted: float = float(summary.get("substituted_percent_window", summary["substituted_percent"]))
	var met: bool = p99_tick < MAX_P99_TICK_US and substituted < MAX_SUBSTITUTED_PERCENT
	if int(summary["bots_measured"]) > 0:
		met = met and float(summary["client_kb_down_per_s_max"]) <= MAX_KB_PER_CLIENT
	summary["criterion_met"] = met


# Prints a scenario's summary and appends it to summary.txt.
func _print_summary(summary: Dictionary) -> void:
	var lines := PackedStringArray()
	lines.append("== %s: %d falsos, %d bots ==" % [summary["tag"], (summary["run"] as Dictionary)["fakes"],
			(summary["run"] as Dictionary)["bots"]])
	if summary.has("error"):
		lines.append("   ERROR: %s" % summary["error"])
	if summary.has("sections_us"):
		lines.append_array(_summary_lines(summary))
	if summary.has("soak"):
		lines.append_array(_soak_lines(summary))
	_print_lines(lines)


# Prints [param lines] and appends them to summary.txt.
func _print_lines(lines: PackedStringArray) -> void:
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
	if bool(summary.get("server_dtls", false)):
		lines.append("   DTLS: el servidor sí; los enjambres %s" % ("también" if bool(summary.get("swarms_dtls", false)) else "NO"))
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


# Lines of a siege's summary.
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


# Lines of a brawl's summary.
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


## The capacity the server of a scenario with [param fakes] fakes and [param bots] real bots is launched with: all of them plus a
## margin of 8, always with an explicit [code]--max-players[/code]. Without it, Vado Gris would have its own capacity (40, the
## per-battle limit measured with the phase 4 kit: [method NetZones.max_players], docs/networking.md, section 14) and the
## 32 vs 32 and 64 vs 64 sieges of [constant SIEGE_MATRIX], or the 64 and 128 brawls, would not fit.
static func server_max_players(fakes: int, bots: int) -> int:
	return fakes + bots + 8


## The options a swarm closes with: when any of its bots sees the server's tick [param swarm_ticks]
## ([code]--quit-at-server-tick[/code]) and, as an upper bound, after [constant SLOW_SERVER_FACTOR] times that number of ticks of its
## own clock ([code]--quit-after-ticks[/code]).
static func swarm_quit_args(swarm_ticks: int) -> PackedStringArray:
	return PackedStringArray([
		"--quit-at-server-tick=%d" % swarm_ticks,
		"--quit-after-ticks=%d" % ceili(float(swarm_ticks) * SLOW_SERVER_FACTOR),
	])


## Server options specific to a siege: the battle log at [param battle_log] and, without [param with_npcs]
## (the F6a siege), [code]--no-npcs[/code] and the command that declares the captain dead at the end of tick
## [param open_circle_tick] (the start of the measurement window), so that the circle opens. With
## [param with_npcs] the server carries its NPCs and nobody helps it.
static func siege_server_args(with_npcs: bool, battle_log: String, open_circle_tick: int) -> PackedStringArray:
	var args := PackedStringArray(["--battle-log=%s" % battle_log])
	if not with_npcs:
		args.append_array(PackedStringArray(["--no-npcs", "--run-at=%d:fort_kill_captain" % open_circle_tick]))
	return args


## DTLS options of the server of [param run] (the paths to its certificate and its key).
static func dtls_server_args(run: Dictionary) -> PackedStringArray:
	return PackedStringArray(["--dtls-cert=%s" % run["dtls_cert"], "--dtls-key=%s" % run["dtls_key"]])


## DTLS options of a swarm of [param run]: the certificate it pins and the name it checks.
static func dtls_swarm_args(run: Dictionary) -> PackedStringArray:
	return PackedStringArray(["--dtls-cert=%s" % run["dtls_cert"], "--dtls-name=%s" % run["dtls_name"]])


## Comparison of [code]--dtls-compare[/code] (TEC-27): from the [param summaries] that came out fine, the average
## of each figure without DTLS and with DTLS and how much it rises, with the criterion (the tick p99 with DTLS must not exceed by more than
## [constant MAX_DTLS_P99_RISE] the one without DTLS). The figures: p50 and p99 of the tick and of the [code]net[/code]
## (receive and decrypt) and [code]flush[/code] (encrypt and send) sections, server in and out KB/s and download per
## client; [code]pairs[/code] carries the tick p99s of each pass, to see the noise between identical passes.
static func dtls_comparison(summaries: Array[Dictionary]) -> Dictionary:
	var groups: Dictionary = {false: [], true: []}
	for summary: Dictionary in summaries:
		if not bool(summary.get("ok", false)) or not summary.has("sections_us"):
			continue
		(groups[bool((summary["run"] as Dictionary).get("dtls", false))] as Array).append(summary)
	var result: Dictionary = {"plain_runs": (groups[false] as Array).size(), "dtls_runs": (groups[true] as Array).size()}
	if (groups[false] as Array).is_empty() or (groups[true] as Array).is_empty():
		result["criterion_met"] = false
		result["error"] = "hacen falta pasadas buenas con y sin DTLS"
		return result
	var figures: Dictionary = {}
	for section: String in ["tick", "net", "flush"]:
		for stat: String in ["p50", "p99"]:
			var key: String = "%s_%s_us" % [section, stat]
			figures[key] = _compare(groups, func(summary: Dictionary) -> float:
				return float(((summary["sections_us"] as Dictionary)[section] as Dictionary)[stat]))
	figures["server_kb_in_per_s"] = _compare(groups, func(summary: Dictionary) -> float:
		return float(summary["server_kb_in_per_s"]))
	figures["server_kb_out_per_s"] = _compare(groups, func(summary: Dictionary) -> float:
		return float(summary["server_kb_out_per_s"]))
	figures["client_kb_down_per_s"] = _compare(groups, func(summary: Dictionary) -> float:
		return float(summary["client_kb_down_per_s_avg"]))
	figures["players_peak"] = _compare(groups, func(summary: Dictionary) -> float:
		return float(summary["players_peak"]))
	result["figures"] = figures
	var pairs: Array[Dictionary] = []
	for summary: Dictionary in summaries:
		if bool(summary.get("ok", false)) and summary.has("sections_us"):
			pairs.append({"tag": summary["tag"], "dtls": bool((summary["run"] as Dictionary).get("dtls", false)),
					"tick_p99_us": int(((summary["sections_us"] as Dictionary)["tick"] as Dictionary)["p99"])})
	result["passes"] = pairs
	var tick_p99: Dictionary = figures["tick_p99_us"]
	result["tick_p99_rise"] = float(tick_p99["rise"])
	result["criterion_met"] = float(tick_p99["rise"]) <= MAX_DTLS_P99_RISE
	return result


# Average of [param figure] (a Callable over a summary) without and with DTLS, and how much it rises as a fraction of the one without.
static func _compare(groups: Dictionary, figure: Callable) -> Dictionary:
	var means: Array[float] = []
	for with_dtls: bool in [false, true]:
		var total: float = 0.0
		for summary: Dictionary in groups[with_dtls]:
			total += float(figure.call(summary))
		means.append(total / float((groups[with_dtls] as Array).size()))
	return {"plain": means[0], "dtls": means[1],
			"rise": (means[1] - means[0]) / means[0] if means[0] > 0.0 else 0.0}


# Lines of the --dtls-compare summary.
func _dtls_comparison_lines(comparison: Dictionary) -> PackedStringArray:
	var lines := PackedStringArray()
	lines.append("== DTLS (TEC-27): %d pasadas sin y %d con ==" % [comparison["plain_runs"], comparison["dtls_runs"]])
	if comparison.has("error"):
		lines.append("   ERROR: %s" % comparison["error"])
		return lines
	lines.append("   Cifra                              sin DTLS    con DTLS    sube")
	var figures: Dictionary = comparison["figures"]
	for key: String in figures:
		var data: Dictionary = figures[key]
		lines.append("     %-30s %9.1f   %9.1f   %+5.1f %%" % [key, data["plain"], data["dtls"], 100.0 * float(data["rise"])])
	for entry: Dictionary in comparison["passes"]:
		lines.append("     pasada %-40s p99 del tick %6d µs" % [entry["tag"], entry["tick_p99_us"]])
	lines.append("   Criterio de TEC-27 (DTLS no sube el p99 del tick más de un %.0f %%): %s (%+.1f %%)" % [
		100.0 * MAX_DTLS_P99_RISE, "CUMPLIDO" if bool(comparison["criterion_met"]) else "NO CUMPLIDO",
		100.0 * float(comparison["tick_p99_rise"])])
	return lines


# true if the scenario is the one the phase 2 criterion is defined for (docs/networking.md, 16): 64
# clustered fake players, with bots and 100 ms of RTT.
func _is_reference_run(run: Dictionary) -> bool:
	return run["scenario"] == "cluster" and int(run["fakes"]) == 64 and int(run["bots"]) > 0 \
			and str(run["net_sim"]).begins_with("rtt=100")


# --- Processes and helpers ------------------------------------------------------------------------

# Launches another windowless Godot on this project with [param user_args] and its log at [param log_path].
# Its standard output is mixed with this tool's (--quiet would also flush the log, which is
# how it is known that the server is already listening); each scenario's summary goes into summary.txt.
func _launch(user_args: PackedStringArray, log_path: String) -> int:
	var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"),
			"--log-file", log_path, "--"])
	args.append_array(user_args)
	var pid: int = OS.create_process(OS.get_executable_path(), args)
	if pid > 0:
		_pids.append(pid)
	return pid


# Waits for [param condition] to be met, up to [param timeout_seconds]. false if time runs out.
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


# --- The soak ---------------------------------------------------------------------------------

# The long run: one server with fake players and a few real clients that join and leave, sampled for hours. See --soak.
func _run_soak(run: Dictionary) -> Dictionary:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var fakes: int = run["fakes"]
	var bots: int = run["bots"]
	var seconds: int = run["seconds"]
	var tag: String = "soak_%df_%db" % [fakes, bots]
	var port: int = _int_option(args, "--port=", 0)
	if port <= 0:
		port = _free_port()
	var summary: Dictionary = {"tag": tag, "run": run, "port": port, "ok": false}
	if port < 0:
		summary["error"] = "no hay ningún puerto UDP libre"
		return summary
	var server_report: String = _out_dir.path_join("%s_server.json" % tag)
	var server_log: String = _out_dir.path_join("%s_server.log" % tag)
	var series_path: String = _out_dir.path_join("%s_series.json" % tag)
	DirAccess.remove_absolute(server_report)
	var server_ticks: int = (seconds + int(SETTLE_SECONDS)) * _tick_rate
	var server_args := PackedStringArray([
		"--server", "--port=%d" % port, "--max-players=%d" % (fakes + bots + 8),
		"--quit-after-ticks=%d" % server_ticks, "--report=%s" % server_report,
		"--fake-players=%d" % fakes, "--fake-layout=cluster",
	])
	if not str(run["zone"]).is_empty():
		server_args.append("--zone=%s" % run["zone"])
	print("\n== soak: %d falsos, %d bots que entran y salen, %d s (servidor %d ticks, puerto %d) ==" % [
		fakes, bots, seconds, server_ticks, port])
	var server_pid: int = _launch(server_args, server_log)
	if server_pid <= 0:
		summary["error"] = "no se pudo lanzar el servidor"
		return summary
	if not await _wait_until(func() -> bool:
		return FileAccess.get_file_as_string(server_log).contains("escuchando en el puerto") \
				or not OS.is_process_running(server_pid), LISTEN_TIMEOUT_SECONDS):
		summary["error"] = "el servidor no llegó a escuchar"
		return summary
	if not OS.is_process_running(server_pid):
		summary["error"] = "el servidor se cerró al arrancar (mira %s)" % server_log
		return summary

	var rng := RandomNumberGenerator.new()
	rng.seed = 20261106
	# One slot per client: its process, when it leaves and when it comes back.
	var slots: Array[Dictionary] = []
	for index: int in bots:
		slots.append({"pid": 0, "leave_at": 0.0, "return_at": float(index) * 3.0, "launches": 0})
	var series: Array[Dictionary] = []
	var started_msec: int = Time.get_ticks_msec()
	var next_sample: float = 0.0
	var last_ticks: int = -1
	var deadline: float = float(seconds) * SLOW_SERVER_FACTOR + FINISH_MARGIN_SECONDS + SETTLE_SECONDS
	while OS.is_process_running(server_pid):
		var now: float = float(Time.get_ticks_msec() - started_msec) / 1000.0
		if now > deadline:
			summary["error"] = "el servidor no terminó a tiempo (se mató)"
			OS.kill(server_pid)
			break
		var running: bool = now < float(seconds)
		for index: int in slots.size():
			var slot: Dictionary = slots[index]
			var pid: int = slot["pid"]
			if pid > 0 and (now >= float(slot["leave_at"]) or not OS.is_process_running(pid)):
				if OS.is_process_running(pid):
					OS.kill(pid)
				slot["pid"] = 0
				slot["return_at"] = now + float(rng.randi_range(SOAK_BOT_PAUSE_MIN_SECONDS, SOAK_BOT_PAUSE_MAX_SECONDS))
			elif pid == 0 and running and now >= float(slot["return_at"]):
				var stay: int = rng.randi_range(SOAK_BOT_MIN_SECONDS, SOAK_BOT_MAX_SECONDS)
				var launches: int = int(slot["launches"]) + 1
				slot["launches"] = launches
				var bot_args := PackedStringArray([
					"--bots=1", "--connect=127.0.0.1:%d" % port, "--bot-seed=%d" % (1000 * (index + 1) + launches),
					"--realm=vardheim", "--quit-after-ticks=%d" % ((stay + 5) * _tick_rate),
				])
				slot["pid"] = _launch(bot_args, _out_dir.path_join("%s_bot%d.log" % [tag, index]))
				slot["leave_at"] = now + float(stay)
		if now >= next_sample:
			next_sample = now + SOAK_SAMPLE_SECONDS
			var report: Dictionary = _read_json(server_report)
			if not report.is_empty() and int(report.get("ticks", 0)) != last_ticks:
				last_ticks = int(report.get("ticks", 0))
				series.append(LoadTestSummary.soak_sample(report, now))
				if series.size() % 30 == 0:
					print("   soak t=%d s: p99 %d µs, memoria %.1f MB, objetos %d, jugadores %d" % [
						int(now), series[-1]["p99_us"], float(series[-1]["static_memory"]) / 1048576.0,
						series[-1]["object_count"], series[-1]["players"]])
		await create_timer(1.0).timeout
	for slot: Dictionary in slots:
		if int(slot["pid"]) > 0 and OS.is_process_running(int(slot["pid"])):
			OS.kill(int(slot["pid"]))
	var final_report: Dictionary = _read_json(server_report)
	if not final_report.is_empty():
		series.append(LoadTestSummary.soak_sample(final_report, float(Time.get_ticks_msec() - started_msec) / 1000.0))
	var file: FileAccess = FileAccess.open(series_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(series, "\t"))
		file.close()
	var figures: Dictionary = LoadTestSummary.soak_figures(series)
	var errors: int = _count_errors(server_log)
	figures["server_errors"] = errors
	if errors > 0:
		(figures["problems"] as PackedStringArray).append("%d error lines in the server log" % errors)
		figures["criterion_met"] = false
	figures["series"] = series_path
	var launches_per_slot: Array[int] = []
	for slot: Dictionary in slots:
		launches_per_slot.append(int(slot["launches"]))
	figures["bot_launches"] = launches_per_slot
	summary["soak"] = figures
	summary["criterion_met"] = bool(figures["criterion_met"])
	summary["ok"] = not summary.has("error") and not series.is_empty()
	return summary


# Lines of ERROR / SCRIPT ERROR / USER ERROR in a server log before it began to shut down (the engine always complains about
# leaked objects at exit).
func _count_errors(log_path: String) -> int:
	var text: String = FileAccess.get_file_as_string(log_path)
	var cut: int = text.find("Cierre del servidor")
	if cut >= 0:
		text = text.substr(0, cut)
	var count: int = 0
	for line: String in text.split("\n"):
		if line.begins_with("ERROR:") or line.begins_with("SCRIPT ERROR:") or line.begins_with("USER ERROR:"):
			count += 1
	return count


func _soak_lines(summary: Dictionary) -> PackedStringArray:
	var figures: Dictionary = summary["soak"]
	var lines := PackedStringArray()
	lines.append("   Muestras: %d (%d tras el calentamiento de %d s)" % [figures["samples"], figures["judged_samples"],
			int(LoadTestSummary.SOAK_WARMUP_SECONDS)])
	if figures.has("p99_drift_percent"):
		lines.append("   Memoria estática: %+.1f %%   objetos: %+.1f %%   nodos: %+.1f %%" % [
			figures["static_memory_growth_percent"], figures["object_count_growth_percent"], figures["node_count_growth_percent"]])
		lines.append("   p99 del tick: %.0f µs -> %.0f µs (%+.1f %%)" % [figures["p99_before_us"], figures["p99_after_us"],
				figures["p99_drift_percent"]])
	lines.append("   Expulsiones: %s   errores de física: %s   líneas de error en el log: %s" % [
		figures.get("kicks", "?"), figures.get("physics_errors", "?"), figures.get("server_errors", "?")])
	for problem: String in figures["problems"]:
		lines.append("   FALLO: %s" % problem)
	lines.append("   Serie: %s   Criterio del soak: %s" % [figures["series"], "cumplido" if summary["criterion_met"] else "NO cumplido"])
	return lines
