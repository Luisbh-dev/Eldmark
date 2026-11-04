class_name ClientConfig
extends RefCounted
## Networked client configuration (docs/red.md, sections 1.2 and 17.5).
## [br][br]
## It is filled in by [method from_args] from the user arguments (those after
## [code]--[/code]):
## [codeblock]
## --connect=<host>[:<port>]  --local  --bot  --bots=N  --realm=<realm>  --name=<name>
## --port=<port>  --net-sim=rtt=120,jitter=20,loss=5,dup=0,seed=1  --bot-seed=N
## --bot-cheat=<mode>  --bot-brain=<wander|combat|siege>  --quit-after-ticks=N  --quit-at-server-tick=N
## --report=<path.json>  --state-log=<path.csv>  --dev-lock-path=<path.json>  --loadout=<template>
## --title  --platform=<url>  --login=<email>  --password-file=<path>  --character=<name>  --world=N
## --dtls-cert=<pem>  --dtls-name=<cn>  --bot-scenario=<scenario>
## [/codeblock]
## [br]The mode ([enum Mode]) comes from them with this priority (docs/plataforma.md §13.3):
## [code]--bots[/code] ([constant SWARM]) > [code]--bot[/code] ([constant BOT]) > [code]--local[/code]
## ([constant LOCAL]) > [code]--connect[/code] ([constant ONLINE]) > [code]--title[/code] or
## [code]--platform[/code] ([constant TITLE], the title screen with an account) > nothing: the phase 1
## sandbox ([constant OFFLINE]) from the editor and the title screen in an export ([param exported] of
## [method from_args]). [code]--server[/code] is resolved earlier by [code]boot.gd[/code] and is not a
## client mode.
## [br][br]
## [b]With an account[/b] (docs/plataforma.md §5.5 and §13.3): [code]--platform=<url>[/code] is the
## platform's public API (without it, the title screen uses the project setting
## [constant PLATFORM_URL_SETTING]); [code]--bot --platform[/code] logs in with [code]--login[/code]
## and the password from [code]--password-file[/code], creates the character [code]--character[/code]
## if missing and enters with a ticket. [member character_id], [member ticket] and
## [member dtls_cert_pem] do not come from the arguments: [AccountFlow] fills them in from the response
## of [code]enter[/code] for [OnlineMain] ([member from_front] if it comes from [FrontMain]).
## [br][br]
## A value that is not valid (a port out of range, a mistyped number, a realm that does not exist) is
## ignored, the default value is kept and it is recorded in [member warnings]: the client never starts
## with an absurd configuration because of a typing mistake. The zone is not chosen here: the server
## dictates it in the WELCOME.

## Client start-up mode.
enum Mode {
	## Phase 1 offline sandbox ([ClientMain]).
	OFFLINE,
	## Networked client against [member address]:[member port].
	ONLINE,
	## Client against a local server, which is launched if there is none.
	LOCAL,
	## Client that predicts without a camera or HUD, driven by [BotBrain].
	BOT,
	## Swarm of [member bot_count] lightweight clients that do not simulate.
	SWARM,
	## Title screen with an account ([FrontMain], docs/plataforma.md §13): login, characters and entering
	## with a ticket.
	TITLE,
}

## Bot brains ([member bot_brain], [code]--bot-brain[/code]): wander (default), fight or
## besiege a fort. They work for [code]--bot[/code] and for [code]--bots[/code].
const BOT_BRAIN_WANDER: String = "wander"
const BOT_BRAIN_COMBAT: String = "combat"
const BOT_BRAIN_SIEGE: String = "siege"
const BOT_BRAINS: Array[String] = [BOT_BRAIN_WANDER, BOT_BRAIN_COMBAT, BOT_BRAIN_SIEGE]
## Bot scenarios ([member bot_scenario], [code]--bot-scenario[/code]): [code]progress[/code] equips the
## bow, gives itself 50 gold and a potion through DEBUG_COMMAND and exits ([BotProgressScenario],
## docs/progresion.md §15 P8).
const BOT_SCENARIO_PROGRESS: String = "progress"
const BOT_SCENARIOS: Array[String] = [BOT_SCENARIO_PROGRESS]
## Prefix of the default names: "Jugadorabcd" (see [method NameRules.default_name]).
const DEFAULT_NAME_PREFIX: String = NameRules.DEFAULT_PREFIX
## Maximum accepted ticks, bots and seed.
const _MAX_INT: int = 2147483647
const _MAX_PORT: int = 65535
const _MAX_BOTS: int = 4096
const _MAX_WORLD: int = 65535
## Project setting with the URL of the platform's public API (the one the title screen uses without
## [code]--platform[/code]).
const PLATFORM_URL_SETTING: String = "eldmark/platform/url"
## Default URL if the setting does not exist: the development platform on this machine.
const DEFAULT_PLATFORM_URL: String = "http://127.0.0.1:24680"
## Default world (the only one at launch, docs/plataforma.md §0).
const DEFAULT_WORLD_ID: int = 1

var mode: Mode = Mode.OFFLINE
var address: String = "127.0.0.1"
var port: int = NetProtocol.DEFAULT_PORT
## Code of [enum NetProtocol.Realm]. [constant NetProtocol.Realm.NONE] if none was given.
var realm: int = NetProtocol.Realm.NONE
var display_name: String = ""
var net_sim_spec: String = ""
var bot_seed: int = 1
var bot_count: int = 0
## Cheating bot mode ([code]--bot-cheat=<mode>[/code], [constant BotCheater.MODES]): traffic
## ([code]version[/code], [code]future[/code], [code]dupes[/code], [code]garbage[/code],
## [code]flood[/code]) or combat ([code]rewind[/code], [code]reach[/code], [code]rate[/code] and, since
## phase 4, [code]reuse[/code], [code]potion[/code] and [code]interact[/code]). Empty = honest.
## Validated by [NetClient] on start-up.
var bot_cheat: String = ""
## Bot brain ([constant BOT_BRAINS]): empty or [constant BOT_BRAIN_WANDER] strolls;
## [constant BOT_BRAIN_COMBAT] looks for the nearest enemy and fights ([constant BotBrain.Pattern.COMBAT]);
## [constant BOT_BRAIN_SIEGE] follows its realm's route to the fort, breaks the gate, captures the
## circle and defends it ([constant BotBrain.Pattern.SIEGE]).
var bot_brain: String = ""
## Scripted bot scenario ([constant BOT_SCENARIOS], [code]--bot-scenario=<scenario>[/code]; only in
## [constant Mode.BOT]): empty = none. With one, the bot runs it on spawning and, if there is no
## [member quit_after_ticks], exits when it finishes; with it, it keeps going until those ticks. If it
## fails, it exits with code 1.
var bot_scenario: String = ""
var quit_after_ticks: int = 0
## Swarm only ([constant Mode.SWARM]): exits when any of its bots has received a snapshot from this
## server tick or later ([code]--quit-at-server-tick=N[/code]; 0 = no). Load tests close the swarm this
## way by the server's clock, which with many players runs slower than real time;
## [member quit_after_ticks] remains as an upper bound.
var quit_at_server_tick: int = 0
var report_path: String = ""
var state_log_path: String = ""
## Lock file of the local server that [constant Mode.LOCAL] mode checks instead of
## [constant LocalServerLauncher.LOCK_PATH] ([code]--dev-lock-path=<path>[/code]); it is forwarded to
## the server that gets launched. Empty = the usual one. Used by the process tests.
var dev_lock_path: String = ""
## Equipment template for the next spawn ([code]--loadout=<template>[/code], the
## [member EquipmentTemplate.id] of a selectable one, such as [code]marksman[/code]; docs/habilidades.md,
## section 4.6): [NetClient] sends it in a LOADOUT_SELECT as soon as the WELCOME arrives. Empty = the
## default one (nothing is sent). It is also changed by the realm choice and the death screen. A bot with
## [code]--platform[/code] does not send it: it is the starting template of the character it creates if
## it does not exist yet ([method AccountFlow.ensure_character], docs/progresion.md §2.5).
var loadout: String = ""
## Warnings for the user about network arguments that could not be interpreted.
var warnings: PackedStringArray = PackedStringArray()

# --- Account and platform (docs/plataforma.md §13.3) ---
## URL of the platform's public API ([code]--platform=<url>[/code]). Empty = no platform (the usual
## modes); in [constant Mode.TITLE] it is never empty (without the option, the
## [constant PLATFORM_URL_SETTING] setting).
var platform_url: String = ""
## Email the bot logs in with ([code]--login=<email>[/code]).
var login: String = ""
## File with the bot's password ([code]--password-file=<path>[/code]): never on the command line.
var password_file: String = ""
## Bot character ([code]--character=<name>[/code]); empty = [method NameRules.bot_name] of the seed.
var character_name: String = ""
## World ([code]--world=N[/code], 1 by default).
var world_id: int = DEFAULT_WORLD_ID
## [code]--title[/code]: the title screen even if there are other client options with no mode.
var title: bool = false
## The zone's DTLS certificate in PEM ([code]--dtls-cert=<path>[/code], against zones without a platform; §10.2).
var dtls_cert_path: String = ""
## Name (CN) of the zone's DTLS certificate ([code]--dtls-name=<cn>[/code]).
var dtls_name: String = ""
## Character to enter with a ticket (from [code]enter[/code]); 0 = no ticket.
var character_id: int = 0
## 52 B ticket from [code]enter[/code] (goes in the HELLO); empty = no ticket.
var ticket: PackedByteArray = PackedByteArray()
## DTLS certificate in PEM given by [code]enter[/code] (takes precedence over [member dtls_cert_path]); empty = no DTLS.
var dtls_cert_pem: String = ""
## true if the session comes from [FrontMain]: after a rejection or a disconnection [OnlineMain] returns to
## character selection (the account session continues) instead of to [RealmSelect].
var from_front: bool = false


## Reads [param args] (the user arguments) and returns the configuration. Arguments that are not
## network ones ([code]--zone[/code], [code]--demo[/code]...) are ignored without warning.
## [param exported]: the client is an export (not the editor); with no mode at all, an export opens the
## title screen and the editor the sandbox (docs/plataforma.md §5.5).
static func from_args(args: PackedStringArray, exported: bool = false) -> ClientConfig:
	var config := ClientConfig.new()
	var connect_text: String = _string_option(args, "--connect=")
	var has_connect: bool = _has_option(args, "--connect=")
	var is_local: bool = args.has("--local")
	var is_bot: bool = args.has("--bot")
	var has_swarm: bool = _has_option(args, "--bots=")
	config.title = args.has("--title")
	config._parse_account_options(args)

	if has_connect:
		config._parse_connect(connect_text)
	config.port = _int_option(args, "--port=", config.port, 1, _MAX_PORT, config.warnings)
	config.bot_seed = _int_option(args, "--bot-seed=", config.bot_seed, -_MAX_INT, _MAX_INT,
			config.warnings)
	config.quit_after_ticks = _int_option(args, "--quit-after-ticks=", config.quit_after_ticks,
			0, _MAX_INT, config.warnings)
	config.quit_at_server_tick = _int_option(args, "--quit-at-server-tick=", config.quit_at_server_tick,
			0, _MAX_INT, config.warnings)
	config.bot_count = _int_option(args, "--bots=", config.bot_count, 1, _MAX_BOTS,
			config.warnings)
	config.net_sim_spec = _string_option(args, "--net-sim=")
	config.bot_cheat = _string_option(args, "--bot-cheat=").to_lower()
	config.bot_brain = _string_option(args, "--bot-brain=").to_lower()
	if not config.bot_brain.is_empty() and not BOT_BRAINS.has(config.bot_brain):
		config.warnings.append("Cerebro de bot desconocido '%s' (hay: %s); se usa %s" % [
				config.bot_brain, ", ".join(BOT_BRAINS), BOT_BRAIN_WANDER])
		config.bot_brain = ""
	config.bot_scenario = _string_option(args, "--bot-scenario=").to_lower()
	if not config.bot_scenario.is_empty() and not BOT_SCENARIOS.has(config.bot_scenario):
		config.warnings.append("Escenario de bot desconocido '%s' (hay: %s); se juega sin escenario" % [
				config.bot_scenario, ", ".join(BOT_SCENARIOS)])
		config.bot_scenario = ""
	config.report_path = _clean_path(_string_option(args, "--report="))
	config.state_log_path = _clean_path(_string_option(args, "--state-log="))
	config.dev_lock_path = _clean_path(_string_option(args, "--dev-lock-path="))
	var loadout_text: String = _string_option(args, "--loadout=").to_lower()
	if not loadout_text.is_empty():
		if is_selectable_template(loadout_text):
			config.loadout = loadout_text
		else:
			config.warnings.append("Plantilla de equipo desconocida '%s'; se usa la de por defecto"
					% loadout_text)

	if _has_option(args, "--realm="):
		config.realm = NetZones.parse_realm_arg(args)
		if config.realm == NetProtocol.Realm.NONE:
			config.warnings.append("Reino desconocido '%s'" % _string_option(args, "--realm="))
	config.display_name = _string_option(args, "--name=")
	if config.display_name.is_empty():
		# Bots use a fixed name per seed (valid for NameRules); players, a random one.
		config.display_name = NameRules.bot_name(config.bot_seed) if is_bot or has_swarm \
				else default_name()

	if has_swarm and config.bot_count > 0:
		config.mode = Mode.SWARM
	elif is_bot:
		config.mode = Mode.BOT
	elif is_local:
		config.mode = Mode.LOCAL
	elif has_connect:
		config.mode = Mode.ONLINE
	elif config.title or not config.platform_url.is_empty() or exported:
		config.mode = Mode.TITLE
	if config.mode == Mode.TITLE and config.platform_url.is_empty():
		config.platform_url = default_platform_url()
	return config


## Platform URL from the project setting [constant PLATFORM_URL_SETTING] (or
## [constant DEFAULT_PLATFORM_URL] if it does not exist).
static func default_platform_url() -> String:
	var value: String = str(ProjectSettings.get_setting(PLATFORM_URL_SETTING, DEFAULT_PLATFORM_URL)).strip_edges()
	return value if not value.is_empty() else DEFAULT_PLATFORM_URL


## Reason, in Spanish, why [param url] is not valid as a platform URL (empty if it is valid): it must
## start with [code]https://[/code] or, only towards this machine (loopback), with [code]http://[/code]
## (docs/plataforma.md §10.1), and include a host.
static func platform_url_error(url: String) -> String:
	var clean: String = url.strip_edges()
	if clean.is_empty():
		return "Falta la dirección del servidor de cuentas"
	var scheme_end: int = clean.find("://")
	if scheme_end <= 0:
		return "Dirección del servidor de cuentas mal escrita: «%s»" % clean
	var scheme: String = clean.left(scheme_end).to_lower()
	var host: String = url_host(clean)
	if host.is_empty():
		return "Dirección del servidor de cuentas sin servidor: «%s»" % clean
	if scheme == "https":
		return ""
	if scheme == "http":
		if is_loopback_host(host):
			return ""
		return "El servidor de cuentas tiene que usar https:// (http:// solo hacia esta máquina)"
	return "Dirección del servidor de cuentas mal escrita: «%s»" % clean


## The host of a URL ([code]http://host:port/path[/code] → [code]host[/code]; an IPv6 without brackets).
static func url_host(url: String) -> String:
	var clean: String = url.strip_edges()
	var scheme_end: int = clean.find("://")
	var rest: String = clean.substr(scheme_end + 3) if scheme_end >= 0 else clean
	for separator: String in ["/", "?", "#"]:
		var cut: int = rest.find(separator)
		if cut >= 0:
			rest = rest.left(cut)
	var at: int = rest.rfind("@")
	if at >= 0:
		rest = rest.substr(at + 1)
	if rest.begins_with("["):
		var close: int = rest.find("]")
		return rest.substr(1, close - 1) if close > 0 else ""
	var colon: int = rest.rfind(":")
	return rest.left(colon) if colon >= 0 else rest


## true if [param host] is this machine: [code]localhost[/code], 127.0.0.0/8 or [code]::1[/code].
static func is_loopback_host(host: String) -> bool:
	var clean: String = host.strip_edges().to_lower()
	if clean == "localhost" or clean == "::1":
		return true
	if clean.is_valid_ip_address() and clean.begins_with("127."):
		return true
	return false


## true if the configuration enters with a ticket (from [code]enter[/code]).
func has_ticket() -> bool:
	return not ticket.is_empty()


## true if the connection to the zone goes over DTLS: with the certificate from [code]enter[/code] or with
## [code]--dtls-cert[/code].
func has_dtls() -> bool:
	return not dtls_cert_pem.is_empty() or not dtls_cert_path.is_empty()


## A copy of the configuration for a character's session: the same network, bot and report settings,
## without ticket or character (the caller sets those). Used by [AccountFlow] so it does not touch the
## starting one.
func duplicate_config() -> ClientConfig:
	var copy := ClientConfig.new()
	for property: Dictionary in get_property_list():
		if int(property["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue
		var value: Variant = get(property["name"])
		if value is PackedStringArray or value is PackedByteArray:
			value = value.duplicate()
		copy.set(property["name"], value)
	return copy


## Default name of a player: "Jugador" and four random letters (always valid).
static func default_name() -> String:
	return NameRules.default_name(randi_range(0, 456975))


## true if [param template_name] is the [member EquipmentTemplate.id] of a catalog template that the
## player can choose ([member EquipmentTemplate.selectable]).
static func is_selectable_template(template_name: String) -> bool:
	var id: int = CombatCatalog.template_id(StringName(template_name))
	var template: EquipmentTemplate = CombatCatalog.template(id) if id > 0 else null
	return template != null and template.selectable


## Catalog id of [member loadout] (0 if there is none or it is not a selectable template).
func get_loadout_template_id() -> int:
	if loadout.is_empty() or not is_selectable_template(loadout):
		return 0
	return CombatCatalog.template_id(StringName(loadout))


## true if the mode connects to a server (all except [constant OFFLINE]).
func is_online() -> bool:
	return mode != Mode.OFFLINE


## Parses a server address: [code]host[/code], [code]host:port[/code],
## [code][::1][/code] or [code][::1]:port[/code] (an IPv6 without brackets, with several ':', is taken
## whole as the host). Returns [code]{"host": String, "port": int, "error": String}[/code]:
## [code]port[/code] is 0 if absent or not valid and [code]error[/code] (in Spanish) is empty if
## everything is valid. With an invalid port the host is still returned.
static func parse_address(text: String) -> Dictionary:
	var clean: String = text.strip_edges()
	var result: Dictionary = {"host": "", "port": 0, "error": ""}
	if clean.is_empty():
		result["error"] = "Escribe la dirección del servidor"
		return result
	var host: String = clean
	var port_text: String = ""
	if clean.begins_with("["):
		var close: int = clean.find("]")
		if close < 0:
			result["error"] = "Dirección mal escrita: «%s»" % clean
			return result
		host = clean.substr(1, close - 1)
		var rest: String = clean.substr(close + 1)
		if rest.begins_with(":"):
			port_text = rest.substr(1)
	elif clean.count(":") == 1:
		host = clean.get_slice(":", 0)
		port_text = clean.get_slice(":", 1)
	if host.strip_edges().is_empty():
		result["error"] = "Dirección sin servidor: «%s»" % clean
		return result
	result["host"] = host.strip_edges()
	if not port_text.is_empty():
		if port_text.is_valid_int() and port_text.to_int() >= 1 and port_text.to_int() <= _MAX_PORT:
			result["port"] = port_text.to_int()
		else:
			result["error"] = "Puerto no válido «%s»" % port_text
	return result


# Account and DTLS options (docs/plataforma.md §13.3). A platform URL that is not valid is kept (whoever
# uses it fails with its reason, instead of entering without a platform) and a warning is issued.
func _parse_account_options(args: PackedStringArray) -> void:
	platform_url = _string_option(args, "--platform=")
	if _has_option(args, "--platform=") and platform_url.is_empty():
		warnings.append("--platform necesita una dirección (por ejemplo --platform=http://127.0.0.1:24680)")
	elif not platform_url.is_empty():
		var error: String = platform_url_error(platform_url)
		if not error.is_empty():
			warnings.append(error)
	login = _string_option(args, "--login=")
	password_file = _clean_path(_string_option(args, "--password-file="))
	character_name = _string_option(args, "--character=")
	world_id = _int_option(args, "--world=", world_id, 1, _MAX_WORLD, warnings)
	dtls_cert_path = _clean_path(_string_option(args, "--dtls-cert="))
	dtls_name = _string_option(args, "--dtls-name=")
	if not dtls_cert_path.is_empty() and dtls_name.is_empty():
		warnings.append("--dtls-cert necesita --dtls-name=<cn> (el nombre del certificado de la zona)")


# Parses the value of --connect with [method parse_address]. An address that is not understood is
# ignored with a warning; an invalid port leaves the default port.
func _parse_connect(text: String) -> void:
	if text.is_empty():
		warnings.append("--connect necesita una dirección (por ejemplo --connect=127.0.0.1:24600)")
		return
	var parsed: Dictionary = parse_address(text)
	if String(parsed["host"]).is_empty():
		warnings.append(String(parsed["error"]))
		return
	address = parsed["host"]
	if int(parsed["port"]) > 0:
		port = int(parsed["port"])
	elif not String(parsed["error"]).is_empty():
		warnings.append("%s; se usa %d" % [parsed["error"], port])


static func _has_option(args: PackedStringArray, prefix: String) -> bool:
	for arg: String in args:
		if arg.begins_with(prefix):
			return true
	return false


# Value of the first option [param prefix], without spaces or quotes around it ("" if absent).
static func _string_option(args: PackedStringArray, prefix: String) -> String:
	for arg: String in args:
		if arg.begins_with(prefix):
			return arg.trim_prefix(prefix).strip_edges().trim_prefix("\"").trim_suffix("\"") \
					.strip_edges()
	return ""


# Integer value of the option, or [param fallback] (with a warning) if it is not an integer in range.
static func _int_option(args: PackedStringArray, prefix: String, fallback: int, min_value: int,
		max_value: int, out_warnings: PackedStringArray) -> int:
	if not _has_option(args, prefix):
		return fallback
	var text: String = _string_option(args, prefix)
	if not text.is_valid_int() or text.to_int() < min_value or text.to_int() > max_value:
		out_warnings.append("Valor no válido en %s'%s'; se usa %d" % [prefix, text, fallback])
		return fallback
	return text.to_int()


# Path with forward slashes (Windows writes backslashes).
static func _clean_path(value: String) -> String:
	return value.replace("\\", "/")
