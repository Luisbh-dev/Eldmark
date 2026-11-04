class_name ServerConfig
extends RefCounted
## Configuration of a zone's dedicated server (docs/red.md, sections 1.2 and 17.4).
## [br][br]
## It is filled by [method from_args] from the user arguments (those after [code]--[/code]):
## [codeblock]
## --server --port=24600 --zone=<id> --max-players=N --max-per-ip=4 --idle-quit=<s>
## --fake-players=N --fake-layout=<cluster|spread> --fake-churn=<ticks> --fake-brain=<combat|siege>
## --fake-center=<x>,<z> --fake-loadout=<template>[:<percentage>] --fake-archers=<percentage>
## --max-realm-diff=N --run-at=<tick>:<command>
## --debug-commands --dev-lock --dev-lock-path=<path>
## --quit-after-ticks=N --report=<path.json> --state-log=<path.csv> --net-sim=rtt=120,jitter=20
## --stop-file=<path> --combat-log=<path.csv> --console --no-dummies --no-npcs --battle-log=<path.jsonl>
## --platform=<internal url> --world=<id> --channel=<n> --public-address=<host>[:<port>] --save-interval=<s>
## --replace --dtls-cert=<pem> --dtls-key=<pem>
## [/codeblock]
## [b]With the platform[/b] (docs/plataforma.md §5.5 and §14.3): [code]--platform=<url>[/code] is the internal API
## (without it, [DevAuthProvider] and ephemeral characters); [code]--world[/code] (1) and [code]--channel[/code] (0) are
## the scope of the zone's token; [code]--public-address[/code] is the host (and port) clients connect to (127.0.0.1 and
## [member port] by default); [code]--save-interval[/code] the [code]CharacterSaver[/code] checkpoint (60 s, P5);
## [code]--replace[/code] replaces a live instance of the same zone and channel; [code]--dtls-cert[/code] and
## [code]--dtls-key[/code] the DTLS certificate and its key (P9c, with or without a platform; see [member dtls]). With an
## [code]env[/code] of [code]staging[/code] or [code]production[/code] the development options
## ([method platform_dev_options]) make the zone exit.
## [code]--combat-log=<path>[/code] writes a CSV with one line per resolved hit
## ([code]tick,attacker,target,attack,view_tick,rewind,result,damage[/code]; in the project use another extension, e.g.
## [code].txt[/code], because the importer converts [code].csv[/code] files into translations). [code]--console[/code]
## reads commands from standard input (announce, kick, shutdown...; see [CommandRegistry]), [code]--no-dummies[/code]
## does not place the zone's dummies and [code]--no-npcs[/code] does not create the NPCs of its spawners (the Hollow, the
## Captain, the garrison and the Guardians; [NpcSpawnerSystem]).
## [code]--battle-log=<path>[/code] writes war events and deaths in JSON Lines ([BattleLog]; summarized by
## [code]tools/war/summarize_battle.gd[/code], GUE-17).
## [code]--fake-loadout=<template>[:<percentage>][/code] (docs/habilidades.md, section 4.6) gives the fake players the
## equipment template of that name ([code]marksman[/code], [code]squire[/code]…): to all of them or, with a percentage,
## to that share distributed in creation order (with 50, every other one); the rest get the default.
## [code]--fake-archers=<percentage>[/code] (load tests, H5) makes pure archers of the fakes that carry the bow in hand:
## they do not switch to the sword ([member BotBrain.kit_ranged_only]) and that percentage of them (0 to 100,
## distributed in order) fires at the sky ([member BotBrain.kit_aim_raise]): their arrows live for 2 s and fill the
## zone's projectile cap.
## [code]--max-realm-diff=N[/code] (GUE-42) limits the difference in connected people between the zone's realms: the
## HELLO of whoever would enter a realm and leave more than N people of advantage over the realm with the fewest
## receives a REJECT 9 (IMBALANCE); 0 = no limit. With N > 0 the auto-realm fake players fill the short side, withdraw
## when people join and do not take their seats: with the server full only because of them, a person enters and a fake
## gives up their seat (GUE-43; see [RealmBalance]).
## [code]--run-at=<tick>:<command>[/code] (repeatable) runs a console command ([CommandRegistry], for example
## [code]fort_kill_captain[/code]) at the end of the given tick: so a load test without standard input can open the
## fort's circle.
## SIGTERM and SIGINT (Ctrl+C, [code]docker stop[/code], systemd) kill the Godot process without going through
## GDScript, so there is no orderly shutdown. To stop it from outside with a shutdown NOTICE, a report and removal of
## the [code]--dev-lock[/code] lock there is [code]--stop-file=<path>[/code]: the server checks every second whether
## the file exists (for example, an [code]ExecStop[/code] that creates it with [code]touch[/code]).
## Without [code]--max-players[/code], the capacity is the zone's ([method NetZones.max_players]: 40 in Vado Gris, the
## per-battle player limit measured with the phase 4 kit, docs/red.md, section 14) or, if the zone has none of its own,
## [constant DEFAULT_MAX_PLAYERS].
## A value that is not a valid number or is out of range is ignored and the default value stays: the server never starts
## with an absurd configuration because of a typo.

## UDP port it listens on.
var port: int = NetProtocol.DEFAULT_PORT
## Id of the zone it serves ([method NetZones.default_zone_id] if not given). Its existence is not checked here:
## [code]ServerMain[/code] does it with [method NetZones.scene_path].
var zone_id: String = ""
## Capacity of a zone without one of its own ([method NetZones.max_players]).
const DEFAULT_MAX_PLAYERS: int = 64

## Maximum players (fakes count; the [member max_realm_diff] fillers give up their seat to people, GUE-43).
## [method from_args] sets the zone's if not given.
var max_players: int = DEFAULT_MAX_PLAYERS
## Maximum simultaneous connections from the same IP (except loopback).
var max_connections_per_ip: int = 4
## Seconds without players after which the server shuts itself down. 0 = never.
var idle_quit_seconds: int = 0
## Ticks after which the server shuts itself down. 0 = never.
var quit_after_ticks: int = 0
## Path of the JSON report written on shutdown. Empty = none.
var report_path: String = ""
## Path of the CSV with each player's state at each tick. Empty = none.
var state_log_path: String = ""
## Path of a file whose existence requests an orderly server shutdown (checked every second; deleted on shutdown, and if
## it already existed at startup it is from a previous stop and is deleted). Empty = none.
var stop_file_path: String = ""
## Network simulator specification ([code]rtt=120,jitter=20,loss=5,dup=0,seed=1[/code]). Empty = no simulator.
var net_sim_spec: String = ""
## Fake players (without a network) created at startup.
var fake_players: int = 0
## Where fake players are distributed (load tests): [constant LAYOUT_CLUSTER] (all at the same point, within 60 m of
## each other), [constant LAYOUT_SPREAD] (spread across the zone) or empty (each one near its realm's camp).
var fake_layout: String = ""
## Every how many ticks the oldest fake player leaves and a new one enters, to measure joins and leaves (60 = one join
## and one leave per second). 0 = none.
var fake_churn_ticks: int = 0
## Allows the client's debug commands (teleport, heal, kill...; see [CommandRegistry]).
var debug_commands: bool = false
## Path of the combat log (CSV). Empty = none.
var combat_log_path: String = ""
## Path of the battle log (JSON Lines: war notices and deaths). Empty = none.
var battle_log_path: String = ""
## Brain of the fake players: empty = the wandering one, [constant FAKE_BRAIN_COMBAT] = the combat one (they look for the
## nearest enemy, attack, block and dodge) and [constant FAKE_BRAIN_SIEGE] = the siege one (they follow their realm's
## route to the fort, break the door, capture and defend; GUE-15).
var fake_brain: String = ""
## With the combat brain and [constant LAYOUT_CLUSTER]: point (x, z) of the zone, at ground level, around which the
## fakes gather instead of the first realm's camp (where the safe zone prevents them from fighting).
## [constant NO_FAKE_CENTER] = none ([method has_fake_center]).
var fake_center: Vector2 = NO_FAKE_CENTER
## Equipment template of the fake players ([code]--fake-loadout[/code]): its name in the combat catalog (empty = the
## default) and to what percentage of them it is given (1 to 100).
var fake_loadout: StringName = &""
var fake_loadout_percent: int = 100
## Pure archers among the fakes with a bow ([code]--fake-archers[/code]; load tests): -1 = no; otherwise, the percentage
## of them that fires at the sky.
var fake_archers_sky_percent: int = -1
## Maximum difference in connected people between the zone's realms (GUE-42); 0 = no limit. Fake players do not count
## towards rejecting a person.
var max_realm_diff: int = 0
## Scheduled console commands ([code]--run-at=<tick>:<command>[/code]): dictionaries with [code]tick[/code] and
## [code]line[/code], in the order they were given.
var scheduled_commands: Array[Dictionary] = []
## Reads console commands from standard input (in a thread, without blocking the tick).
var console: bool = false
## Does not place the training dummies from the zone's [code]dummy_points[/code] markers.
var no_dummies: bool = false
## Does not create the NPCs of the zone's spawners (the Hollow, the Ford Captain, the garrison and the Gate Guardians;
## [NpcSpawnerSystem]).
var no_npcs: bool = false
## URL of the platform's internal API ([code]--platform[/code]); empty = no platform.
var platform_url: String = ""
## World and channel of the zone ([code]--world[/code], [code]--channel[/code]): the scope of its token.
var world_id: int = 1
var channel: int = 0
## [code]<host>[:<port>][/code] that clients connect to ([code]--public-address[/code]); empty = 127.0.0.1 and
## [member port]. See [method public_host] and [method public_port].
var public_address: String = ""
## Seconds between [code]CharacterSaver[/code] checkpoints ([code]--save-interval[/code], P5).
var save_interval_s: int = 60
## Replaces the live instance of the same zone and channel on registering ([code]--replace[/code]).
var replace: bool = false
## Paths of the DTLS certificate and key in PEM ([code]--dtls-cert[/code], [code]--dtls-key[/code];
## docs/plataforma.md §10.2). Read by [code]ServerMain[/code] with [method ZoneDtls.load_files].
var dtls_cert_path: String = ""
var dtls_key_path: String = ""
## The certificate and key already loaded: it does not come from the arguments, it is set by [code]ServerMain[/code] (or
## a test). With it, [ZoneServer] opens the port with DTLS and [ZonePlatform] sends the certificate and its name in the
## registration; null = no DTLS.
var dtls: ZoneDtls = null
## Writes [code]user://dev_server.json[/code] so that [code]--local[/code] reuses the server.
var dev_lock: bool = false
## Where the [member dev_lock] lock is written instead of [code]user://dev_server.json[/code]
## ([code]--dev-lock-path=<path>[/code]): process tests use it so as not to overwrite the real local server of whoever
## runs them. Empty = the usual one.
var dev_lock_path: String = ""

## Values of [member fake_layout].
const LAYOUT_CLUSTER: String = "cluster"
const LAYOUT_SPREAD: String = "spread"
## Value of [member fake_brain] for the combat brain.
const FAKE_BRAIN_COMBAT: String = "combat"
## Value of [member fake_brain] for the siege brain ([constant BotBrain.Pattern.SIEGE]).
const FAKE_BRAIN_SIEGE: String = "siege"
## Value of [member fake_center] when not given.
const NO_FAKE_CENTER: Vector2 = Vector2(INF, INF)
## Maximum coordinate (absolute value, m) that [member fake_center] admits.
const MAX_FAKE_CENTER: float = 5000.0
## Prefix of the scheduled commands option.
const RUN_AT_PREFIX: String = "--run-at="
const _MAX_PORT: int = 65535
## Reasonable cap on players and fake players (network ids are 16-bit).
const _MAX_PLAYERS_LIMIT: int = 4096


## Reads [param args] (the user arguments) and returns the configuration. Everything that is not given stays at its
## default value; the zone, at [method NetZones.default_zone_id].
static func from_args(args: PackedStringArray) -> ServerConfig:
	var config := ServerConfig.new()
	config.zone_id = NetZones.parse_zone_arg(args)
	if config.zone_id.is_empty():
		config.zone_id = NetZones.default_zone_id()

	config.port = _int_option(args, "--port=", config.port, 1, _MAX_PORT)
	# The zone's capacity if it has one (H5 revision: Vado Gris, the limit measured per battle).
	var zone_capacity: int = NetZones.max_players(config.zone_id)
	if zone_capacity > 0:
		config.max_players = zone_capacity
	config.max_players = _int_option(args, "--max-players=", config.max_players, 1,
			_MAX_PLAYERS_LIMIT)
	config.max_connections_per_ip = _int_option(args, "--max-per-ip=",
			config.max_connections_per_ip, 1, _MAX_PLAYERS_LIMIT)
	config.idle_quit_seconds = _int_option(args, "--idle-quit=", config.idle_quit_seconds, 0,
			2147483647)
	config.quit_after_ticks = _int_option(args, "--quit-after-ticks=", config.quit_after_ticks, 0,
			2147483647)
	config.fake_players = _int_option(args, "--fake-players=", config.fake_players, 0,
			_MAX_PLAYERS_LIMIT)
	config.fake_churn_ticks = _int_option(args, "--fake-churn=", config.fake_churn_ticks, 0,
			2147483647)
	var layout: String = _string_option(args, "--fake-layout=").to_lower()
	if layout == LAYOUT_CLUSTER or layout == LAYOUT_SPREAD:
		config.fake_layout = layout
	var brain: String = _string_option(args, "--fake-brain=").to_lower()
	if brain == FAKE_BRAIN_COMBAT or brain == FAKE_BRAIN_SIEGE:
		config.fake_brain = brain
	var center_parts: PackedStringArray = _string_option(args, "--fake-center=").split(",")
	if center_parts.size() == 2 and center_parts[0].strip_edges().is_valid_float() \
			and center_parts[1].strip_edges().is_valid_float():
		var center := Vector2(center_parts[0].strip_edges().to_float(),
				center_parts[1].strip_edges().to_float())
		if center.is_finite() and absf(center.x) <= MAX_FAKE_CENTER and absf(center.y) <= MAX_FAKE_CENTER:
			config.fake_center = center
	_parse_fake_loadout(config, _string_option(args, "--fake-loadout="))
	config.fake_archers_sky_percent = _int_option(args, "--fake-archers=", -1, 0, 100)
	config.max_realm_diff = _int_option(args, "--max-realm-diff=", config.max_realm_diff, 0,
			_MAX_PLAYERS_LIMIT)
	config.scheduled_commands = _scheduled_commands(args)
	config.combat_log_path = _string_option(args, "--combat-log=").replace("\\", "/")
	config.battle_log_path = _string_option(args, "--battle-log=").replace("\\", "/")
	config.console = args.has("--console")
	config.no_dummies = args.has("--no-dummies")
	config.no_npcs = args.has("--no-npcs")
	config.report_path = _string_option(args, "--report=")
	config.state_log_path = _string_option(args, "--state-log=")
	config.stop_file_path = _string_option(args, "--stop-file=")
	config.net_sim_spec = _string_option(args, "--net-sim=")
	config.debug_commands = args.has("--debug-commands")
	config.dev_lock = args.has("--dev-lock")
	config.dev_lock_path = _string_option(args, "--dev-lock-path=").replace("\\", "/")
	config.platform_url = _string_option(args, "--platform=")
	config.world_id = _int_option(args, "--world=", config.world_id, 1, 0xFFFF)
	config.channel = _int_option(args, "--channel=", config.channel, 0, 255)
	config.public_address = _string_option(args, "--public-address=")
	config.save_interval_s = _int_option(args, "--save-interval=", config.save_interval_s, 1, 86400)
	config.replace = args.has("--replace")
	config.dtls_cert_path = _string_option(args, "--dtls-cert=").replace("\\", "/")
	config.dtls_key_path = _string_option(args, "--dtls-key=").replace("\\", "/")
	return config


## true if the zone works with the platform ([code]--platform[/code]).
func uses_platform() -> bool:
	return not platform_url.is_empty()


## The host of [member public_address] (127.0.0.1 if not given). Accepts [code][::1]:24600[/code].
func public_host() -> String:
	var text: String = public_address.strip_edges()
	if text.is_empty():
		return "127.0.0.1"
	if text.begins_with("["):
		var close: int = text.find("]")
		return text.substr(1, close - 1) if close > 0 else text
	var colon: int = text.rfind(":")
	if colon > 0 and text.count(":") == 1:
		return text.substr(0, colon)
	return text


## The port of [member public_address], or [member port] if it has none (or is invalid).
func public_port() -> int:
	var text: String = public_address.strip_edges()
	var colon: int = text.rfind(":")
	if colon < 0 or (not text.begins_with("[") and text.count(":") != 1):
		return port
	var port_text: String = text.substr(colon + 1)
	if not port_text.is_valid_int() or port_text.to_int() < 1 or port_text.to_int() > _MAX_PORT:
		return port
	return port_text.to_int()


## Development options given that with the platform are only valid in [code]dev[/code] and [code]test[/code]
## (docs/plataforma.md §5.5): [code]--debug-commands[/code], [code]--fake-players[/code], [code]--fake-churn[/code],
## [code]--battle-log[/code], [code]--combat-log[/code] and [code]--state-log[/code].
func platform_dev_options() -> PackedStringArray:
	var options := PackedStringArray()
	if debug_commands:
		options.append("--debug-commands")
	if fake_players > 0:
		options.append("--fake-players")
	if fake_churn_ticks > 0:
		options.append("--fake-churn")
	if not battle_log_path.is_empty():
		options.append("--battle-log")
	if not combat_log_path.is_empty():
		options.append("--combat-log")
	if not state_log_path.is_empty():
		options.append("--state-log")
	return options


## The template of [code]--fake-loadout=<template>[:<percentage>][/code]: a combat catalog template that can be chosen
## and, if given, a percentage from 1 to 100. If anything is invalid the whole thing is ignored.
static func _parse_fake_loadout(config: ServerConfig, text: String) -> void:
	var value: String = text.strip_edges()
	if value.is_empty():
		return
	var parts: PackedStringArray = value.split(":")
	if parts.size() > 2:
		return
	var template_name := StringName(parts[0].strip_edges())
	var template: EquipmentTemplate = CombatCatalog.template(CombatCatalog.template_id(template_name))
	if template == null or not template.selectable:
		return
	var percent: int = 100
	if parts.size() == 2:
		var percent_text: String = parts[1].strip_edges()
		if not percent_text.is_valid_int() or percent_text.to_int() < 1 or percent_text.to_int() > 100:
			return
		percent = percent_text.to_int()
	config.fake_loadout = template_name
	config.fake_loadout_percent = percent


## The template of fake player number [param index] (0, 1, 2…) according to [code]--fake-loadout[/code]: its id in the
## catalog or 0 (the default). With a percentage it is distributed in order: fake [param index] carries it if the
## cumulative count rises when counting it ([code]⌊(i + 1)·p / 100⌋ > ⌊i·p / 100⌋[/code]).
func fake_template_for(index: int) -> int:
	if fake_loadout.is_empty():
		return 0
	@warning_ignore("integer_division")
	var takes: bool = (index + 1) * fake_loadout_percent / 100 > index * fake_loadout_percent / 100
	return CombatCatalog.template_id(fake_loadout) if takes else 0


## true if pure archer number [param archer_index] (0, 1, 2…, in creation order among the fakes with a bow) fires at the
## sky according to [code]--fake-archers[/code] (the same distribution as [method fake_template_for]).
func is_sky_archer(archer_index: int) -> bool:
	if fake_archers_sky_percent <= 0:
		return false
	@warning_ignore("integer_division")
	return (archer_index + 1) * fake_archers_sky_percent / 100 > archer_index * fake_archers_sky_percent / 100


## The scheduled commands from [param args] ([code]--run-at=<tick>:<command>[/code]): those with a non-negative integer
## tick and a non-empty command, in the order they were given.
static func _scheduled_commands(args: PackedStringArray) -> Array[Dictionary]:
	var commands: Array[Dictionary] = []
	for arg: String in args:
		if not arg.begins_with(RUN_AT_PREFIX):
			continue
		var text: String = arg.trim_prefix(RUN_AT_PREFIX).strip_edges().trim_prefix("\"") \
				.trim_suffix("\"").strip_edges()
		var colon: int = text.find(":")
		if colon <= 0:
			continue
		var tick_text: String = text.substr(0, colon).strip_edges()
		var line: String = text.substr(colon + 1).strip_edges()
		if not tick_text.is_valid_int() or tick_text.to_int() < 0 or line.is_empty():
			continue
		commands.append({"tick": tick_text.to_int(), "line": line})
	return commands


## true if [member fake_center] was given.
func has_fake_center() -> bool:
	return fake_center.is_finite()


## Integer value of the first [param prefix] option (for example [code]"--port="[/code]) in [param args], or
## [param fallback] if absent, not an integer or outside [[param min_value], [param max_value]].
static func _int_option(args: PackedStringArray, prefix: String, fallback: int, min_value: int,
		max_value: int) -> int:
	var text: String = _string_option(args, prefix)
	if not text.is_valid_int():
		return fallback
	var value: int = text.to_int()
	if value < min_value or value > max_value:
		return fallback
	return value


## Value of the first [param prefix] option in [param args] without spaces or quotes around it, or an empty string if
## absent.
static func _string_option(args: PackedStringArray, prefix: String) -> String:
	for arg: String in args:
		if arg.begins_with(prefix):
			return arg.trim_prefix(prefix).strip_edges().trim_prefix("\"").trim_suffix("\"") \
					.strip_edges()
	return ""

