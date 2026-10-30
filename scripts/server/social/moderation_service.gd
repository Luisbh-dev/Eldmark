class_name ModerationService
extends RefCounted
## La moderación en el servidor de zona (docs/plataforma.md §9, P7b; SOC-14 a SOC-18).
## [br][br]
## [b]Comandos del chat.[/b] El canal GM del CHAT_SEND lleva los comandos que atiende el servidor (lo que sigue a la
## barra, ya saneado): [code]gm …[/code], [code]ignorar[/code], [code]designorar[/code] y [code]reportar[/code]
## ([method handle_command], el [member ChatRouter.command_sink]). Cualquier otro, o [code]/gm[/code] sin plataforma
## o sin rol, contesta «Comando desconocido. Escribe /ayuda.», sin revelar qué existe.
## [br]- [code]/gm comando …[/code] pasa por [method CommandRegistry.execute_chat] con el rol de la reclamación: cada
## comando declara su [code]min_role[/code] (§9.1). Los de moderación los registra este servicio: [code]aviso[/code],
## [code]silenciar[/code] y [code]expulsar[/code] (moderator); [code]suspender[/code], [code]renombrar[/code],
## [code]invisible[/code] y [code]visible[/code] (gm); [code]banear[/code] (admin). Los demás (los de la consola y los
## del fuerte, con [code]gm[/code] por defecto; [code]anuncio[/code] y [code]apagar[/code] de admin) los registra la
## zona.
## [br]- Las sanciones van a [code]POST /internal/v1/sanctions[/code] y las autoriza la plataforma (§9.5): la zona
## solo exige el rol mínimo del comando. Con el 200, a quien está en esta zona: el silencio se aplica ya (y el latido
## lo confirma), el aviso le llega en un NOTICE, el renombrado lo expulsa con guardado final para que elija otro
## nombre y una suspensión o expulsión pide un latido en el acto (su [code]revoked[/code] lo echa).
## [br]- [code]/ignorar nombre[/code] y [code]/designorar nombre[/code] van a [code]/internal/v1/ignores[/code]
## (§9.3); con la respuesta, la cuenta ignorada entra o sale de [member ChatPeerState.ignored_accounts] y el filtro de
## [ChatRouter] y [PartyManager] la aplica en el acto.
## [br]- [code]/reportar nombre categoría [comentario][/code] (§9.4) adjunta los últimos
## [constant MAX_EVIDENCE] mensajes de ese personaje que recibió quien reporta en 10 min (su anillo), la zona, la
## posición y el tick. La zona ya frena 1 por objetivo cada 10 min y 10 por hora (la plataforma lo vuelve a mirar y
## contesta 429).
## [br][br]
## [b]Silencios y avisos.[/b] Los [code]mutes[/code] de cada latido ([method on_heartbeat]) ponen el silencio de las
## cuentas por las que se latió (los demás quedan sin silencio), salvo que una sanción de esta zona lo cambiara
## después de que saliera ese latido. Al entrar, cada aviso de la reclamación sale en un NOTICE ([method on_arrival]).
## [br][br]
## [b]Auditoría y lote de chat.[/b] Con plataforma, cada comando de GM, de consola o de depuración que se ejecuta va al
## lote [code]audit[/code] ([code]{actor_account_id, actor_character_id, command, target_character_id,
## target_account_id, args, at_unix, source}[/code]; la [code]key[/code] la pone [ZonePlatform]): [code]source[/code]
## [code]console[/code] sin actor desde la consola y [code]zone[/code] con la cuenta y el personaje del GM en lo demás;
## el objetivo por id y [code]args[/code] sin nombres ni correos (§9.1). Cada mensaje repartido va al lote
## [code]chat[/code] (§9.2).

## Los comandos del canal GM (sin la barra).
const COMMAND_GM: String = "gm"
const COMMAND_IGNORE: String = "ignorar"
const COMMAND_UNIGNORE: String = "designorar"
const COMMAND_REPORT: String = "reportar"
## Categorías de un reporte: la palabra del comando (sin tildes) -> la de la plataforma (§9.4).
const REPORT_CATEGORIES: Dictionary[String, String] = {
	"lenguaje": "language", "acoso": "harassment", "trampas": "cheating", "bot": "bot", "nombre": "offensive_name",
	"otro": "other",
}
## Tipos de sanción (§9.5) y cómo se llaman en los textos.
const KIND_WARNING: String = "warning"
const KIND_MUTE: String = "mute"
const KIND_SUSPENSION: String = "suspension"
const KIND_BAN: String = "ban"
const KIND_RENAME: String = "rename"
const KIND_NAMES: Dictionary[String, String] = {
	KIND_WARNING: "aviso", KIND_MUTE: "silencio", KIND_SUSPENSION: "suspensión", KIND_BAN: "expulsión permanente",
	KIND_RENAME: "renombrado forzado",
}
## 1 reporte por objetivo cada 10 min y 10 por hora (§9.4), en ticks.
const REPORT_TARGET_WINDOW_TICKS: int = 36000
const REPORT_HOUR_TICKS: int = 216000
const REPORTS_PER_HOUR: int = 10
## La prueba de un reporte: los últimos 20 mensajes del reportado que recibió quien reporta en 10 min.
const MAX_EVIDENCE: int = 20
const EVIDENCE_WINDOW_TICKS: int = 36000
## Topes de la plataforma: comentario de un reporte y motivo de una sanción (caracteres) y duración de una sanción.
const MAX_COMMENT_CHARS: int = 500
const MAX_REASON_CHARS: int = 500
const MAX_SANCTION_MINUTES: int = 10 * 365 * 24 * 60

const TEXT_UNKNOWN: String = CommandRegistry.TEXT_UNKNOWN
const TEXT_NO_PLATFORM: String = "Eso necesita el servicio de cuentas, y este servidor no lo usa."
const TEXT_PLATFORM_DOWN: String = "El servicio de cuentas no responde; inténtalo más tarde."
const TEXT_NAME_TOO_LONG: String = "Ese nombre es demasiado largo."
const TEXT_NOBODY: String = "No hay nadie que se llame «%s»."
const TEXT_IGNORE_USAGE: String = "Uso: /ignorar nombre"
const TEXT_UNIGNORE_USAGE: String = "Uso: /designorar nombre"
const TEXT_IGNORE_SELF: String = "No puedes ignorarte a ti mismo."
const TEXT_IGNORED: String = "Ignoras a «%s»: no te llegarán sus mensajes ni sus invitaciones."
const TEXT_UNIGNORED: String = "Ya no ignoras a «%s»."
const TEXT_IGNORE_FULL: String = "Tu lista de ignorados está llena (100 como mucho)."
const TEXT_REPORT_USAGE: String = "Uso: /reportar nombre categoría [comentario] (categorías: lenguaje, acoso, " \
		+ "trampas, bot, nombre, otro)"
const TEXT_REPORT_SELF: String = "No puedes reportarte a ti mismo."
const TEXT_REPORT_AGAIN: String = "Ya has reportado a «%s» hace poco: espera %d min."
const TEXT_REPORT_TOO_MANY: String = "Has enviado demasiados reportes: espera %d min."
const TEXT_REPORT_SENT: String = "Reporte enviado. Gracias."
const TEXT_REPORT_LIMITED: String = "Has enviado demasiados reportes: espera %d min."
const TEXT_SANCTION_CONSOLE: String = "Desde la consola, usa «admin sanction» de la plataforma."
const TEXT_SANCTION_APPLIED: String = "Sanción aplicada: %s a «%s»%s."
const TEXT_SANCTION_FORBIDDEN: String = "No puedes poner esa sanción a «%s»."
const TEXT_BAD_REQUEST: String = "La plataforma no lo acepta: datos no válidos (%s)."
const TEXT_WARNED: String = "Has recibido un aviso de la moderación: %s"
const TEXT_MUTED_NOW: String = "Un moderador te ha silenciado %s: %s"
const TEXT_RENAME_KICK: String = "Un moderador te pide cambiar el nombre de tu personaje: elige otro al volver a entrar"
const TEXT_KICKED: String = "Un moderador te ha expulsado de la zona"
const TEXT_KICK_DENIED: String = "No puedes expulsar a «%s»."
const TEXT_NOT_HERE: String = "«%s» no está en esta zona."
const TEXT_INVISIBLE: String = "Ahora eres invisible: nadie te ve, no haces ni recibes daño y no cobras nada."
const TEXT_VISIBLE: String = "Vuelves a ser visible. No cobras recompensas hasta reaparecer."

## Recibe cada línea del registro de la zona.
var log_sink: Callable = Callable()

var _zone: ZoneServer = null
var _platform: ZonePlatform = null
var _commands: CommandRegistry = null
var _social: SocialService = null
var _stats: Dictionary[StringName, int] = {
	&"commands": 0, &"gm_commands": 0, &"unknown": 0, &"ignores": 0, &"unignores": 0, &"reports": 0,
	&"reports_refused": 0, &"sanctions": 0, &"sanctions_applied": 0, &"sanctions_denied": 0, &"responses": 0,
	&"audit_entries": 0, &"chat_entries": 0, &"heartbeats": 0, &"mutes_applied": 0, &"warnings_shown": 0,
}


## Monta el servicio en [param zone]: registra los comandos de moderación en [param commands], atiende el canal GM
## del chat de [param social] y, con [param platform], manda la auditoría y el chat a sus lotes y guarda el anillo de
## lo recibido para los reportes.
func setup(zone: ZoneServer, platform: ZonePlatform, commands: CommandRegistry, social: SocialService) -> void:
	_zone = zone
	_platform = platform
	_commands = commands
	_social = social
	var chat: ChatRouter = social.get_chat()
	chat.command_sink = handle_command
	chat.clock_unix = now_unix
	_register_commands()
	if _platform != null:
		chat.keep_received = true
		chat.log_sink = _log_chat
		commands.audit_entry_sink = _audit_entry


## La hora Unix: la de la plataforma (corregida) o, sin ella, la del sistema.
func now_unix() -> int:
	return _platform.now_unix() if _platform != null else int(Time.get_unix_time_from_system())


## Atiende la línea de comando [param line] del canal GM que manda [param peer] en el tick [param now_tick].
func handle_command(peer: ServerPeer, line: String, now_tick: int) -> void:
	_stats[&"commands"] += 1
	var text: String = line.strip_edges()
	if text.begins_with("/"):
		text = text.substr(1)
	var parts: PackedStringArray = text.split(" ", false, 1)
	var command: String = NameRules.normalize_key(parts[0]) if not parts.is_empty() else ""
	var rest: String = parts[1].strip_edges() if parts.size() > 1 else ""
	match command:
		COMMAND_GM:
			if _platform == null or peer.claimed == null:
				_reply(peer, TEXT_UNKNOWN, now_tick)
				return
			_stats[&"gm_commands"] += 1
			_reply(peer, _commands.execute_chat(peer, rest, peer.claimed.role), now_tick)
		COMMAND_IGNORE, COMMAND_UNIGNORE:
			_ignore(peer, rest, command == COMMAND_IGNORE, now_tick)
		COMMAND_REPORT:
			_report(peer, rest, now_tick)
		_:
			_stats[&"unknown"] += 1
			_reply(peer, TEXT_UNKNOWN, now_tick)


## La respuesta de una petición de moderación ([code]ignore[/code], [code]report[/code] o [code]sanction[/code]).
## Devuelve true si era suya.
func on_platform_event(event: PlatformEvent) -> bool:
	var context: Dictionary = event.context if event.context is Dictionary else {}
	match event.kind:
		PlatformEvent.KIND_IGNORE:
			_on_ignore(event, context)
		PlatformEvent.KIND_REPORT:
			_on_report(event, context)
		PlatformEvent.KIND_SANCTION:
			_on_sanction(event, context)
		_:
			return false
	_stats[&"responses"] += 1
	return true


## Los [code]mutes[/code] de un latido aceptado (§6, §9.5): el silencio de cada cuenta por la que se latió es el que
## dice la respuesta (sin él, ninguno), salvo que una sanción de esta zona lo cambiara después de salir el latido.
func on_heartbeat(event: PlatformEvent) -> void:
	_stats[&"heartbeats"] += 1
	var context: Dictionary = event.context if event.context is Dictionary else {}
	var beaten: Dictionary = context.get("characters", {}) if context.get("characters") is Dictionary else {}
	var sent_msec: int = int(context.get("sent_msec", 0))
	var mutes: Dictionary[int, int] = {}
	for value: Variant in PlatformJson.array_in(event.body_dict(), "mutes"):
		var mute: Dictionary = value if value is Dictionary else {}
		var account_id: int = PlatformJson.id_of(mute.get("account_id"))
		var until: int = PlatformJson.int_in(mute, "until_unix", 0, ChatPeerState.MUTE_NO_END_UNIX, 0)
		if account_id > 0:
			mutes[account_id] = until
	for peer_id: int in _zone.get_peer_ids():
		var peer: ServerPeer = _zone.get_peer(peer_id)
		if peer == null or peer.claimed == null:
			continue
		if not context.is_empty() and beaten.get(peer.claimed.character_id, "") != peer.claimed.lease_id:
			continue
		if peer.chat.mute_changed_msec >= 0 and peer.chat.mute_changed_msec >= sent_msec:
			continue
		var until: int = mutes.get(peer.claimed.account_id, 0)
		if until != peer.chat.muted_until_unix:
			_stats[&"mutes_applied"] += 1
			peer.chat.muted_until_unix = until


## [param peer] acaba de entrar en el mundo: un NOTICE con cada aviso de la moderación que su cuenta no ha visto (los
## da por vistos el primer guardado del arrendamiento, §9.5).
func on_arrival(peer: ServerPeer) -> void:
	if peer.claimed == null:
		return
	for warning: Dictionary in peer.claimed.warnings:
		_stats[&"warnings_shown"] += 1
		_zone.send_notice(peer, String(warning.get("text", "")))


## Estadísticas para el informe.
func get_stats() -> Dictionary:
	var stats: Dictionary = {}
	for key: StringName in _stats:
		stats[String(key)] = _stats[key]
	return stats


## Minutos de una duración escrita en un comando: [code]30[/code] o [code]30m[/code] (minutos), [code]2h[/code],
## [code]7d[/code]; -1 si no vale o pasa de [constant MAX_SANCTION_MINUTES].
static func parse_minutes(text: String) -> int:
	var lowered: String = text.strip_edges().to_lower()
	var factor: int = 1
	for suffix: String in ["min", "m", "h", "d"]:
		if lowered.ends_with(suffix):
			factor = {"min": 1, "m": 1, "h": 60, "d": 1440}[suffix]
			lowered = lowered.left(lowered.length() - suffix.length())
			break
	if lowered.is_empty() or not lowered.is_valid_int() or lowered.length() > 9:
		return -1
	var minutes: int = lowered.to_int() * factor
	return minutes if minutes >= 1 and minutes <= MAX_SANCTION_MINUTES else -1


## La fecha de [param unix] para un texto: [code]3/11/2026 18:00 UTC[/code].
static func date_text(unix: int) -> String:
	var date: Dictionary = Time.get_datetime_dict_from_unix_time(unix)
	return "%d/%d/%d %02d:%02d UTC" % [date["day"], date["month"], date["year"], date["hour"], date["minute"]]


# --- Comandos de /gm ---------------------------------------------------------------------------

func _register_commands() -> void:
	var moderator: StringName = CommandRegistry.ROLE_MODERATOR
	var gm: StringName = CommandRegistry.ROLE_GM
	_commands.register(&"aviso", "aviso <jugador> <motivo>", _cmd_warning, Callable(), moderator)
	_commands.register(&"silenciar", "silenciar <jugador> <duración: 30, 2h, 7d> <motivo>", _cmd_mute, Callable(),
			moderator)
	_commands.register(&"expulsar", "expulsar <jugador> [motivo]", _cmd_kick, Callable(), moderator)
	_commands.register(&"suspender", "suspender <jugador> <duración: 30, 2h, 7d> <motivo>", _cmd_suspend,
			Callable(), gm)
	_commands.register(&"renombrar", "renombrar <jugador> <motivo>", _cmd_rename, Callable(), gm)
	_commands.register(&"banear", "banear <jugador> <motivo>", _cmd_ban, Callable(), CommandRegistry.ROLE_ADMIN)
	_commands.register(&"invisible", "invisible (consola: invisible <jugador>)", _cmd_invisible, Callable(), gm)
	_commands.register(&"visible", "visible (consola: visible <jugador>)", _cmd_visible, Callable(), gm)


func _cmd_warning(ctx: CommandRegistry.Context) -> String:
	return _sanction(ctx, KIND_WARNING, false)


func _cmd_mute(ctx: CommandRegistry.Context) -> String:
	return _sanction(ctx, KIND_MUTE, true)


func _cmd_suspend(ctx: CommandRegistry.Context) -> String:
	return _sanction(ctx, KIND_SUSPENSION, true)


func _cmd_rename(ctx: CommandRegistry.Context) -> String:
	return _sanction(ctx, KIND_RENAME, false)


func _cmd_ban(ctx: CommandRegistry.Context) -> String:
	return _sanction(ctx, KIND_BAN, false)


# Una sanción de /gm: el objetivo por nombre (en el mundo de la instancia: puede no estar en esta zona), la duración
# si la lleva y el motivo. La pide a la plataforma, que la autoriza; la respuesta llega a _on_sanction.
func _sanction(ctx: CommandRegistry.Context, kind: String, timed: bool) -> String:
	var usage: String = "Uso: /gm " + _commands.get_usage(StringName(_command_of(kind)))
	if ctx.origin != CommandRegistry.Origin.CHAT or ctx.peer == null or ctx.peer.claimed == null \
			or _platform == null:
		return TEXT_SANCTION_CONSOLE
	var first_reason: int = 2 if timed else 1
	if ctx.args.size() <= first_reason:
		return usage
	var target_name: String = ctx.args[0]
	if target_name.length() > NameRules.MAX_LENGTH:
		return TEXT_NAME_TOO_LONG
	var minutes: int = 0
	if timed:
		minutes = parse_minutes(ctx.args[1])
		if minutes < 1:
			return usage
	var reason: String = " ".join(ctx.args.slice(first_reason)).strip_edges().left(MAX_REASON_CHARS)
	var target: ServerPeer = SocialPeers.find_any_by_name(_zone.get_world_peers(), target_name)
	if target != null:
		ctx.target = target.entity
	ctx.audit_args = {"kind": kind, "minutes": minutes}
	if _platform.is_fenced():
		ctx.note = "plataforma cercada"
		return TEXT_PLATFORM_DOWN
	_stats[&"sanctions"] += 1
	var author: ClaimedCharacter = ctx.peer.claimed
	_platform.request(PlatformEvent.KIND_SANCTION, HTTPClient.METHOD_POST, "/internal/v1/sanctions", {
		"author_character_id": str(author.character_id), "target_name": target_name, "kind": kind,
		"minutes": minutes, "reason": reason, "report_ids": [],
	}, PlatformClient.PRIORITY_PLAYER, {
		"peer_id": ctx.peer.peer_id, "character_id": author.character_id, "kind": kind, "minutes": minutes,
		"target_name": target_name, "reason": reason,
	})
	ctx.note = "pedida a la plataforma"
	return ""


# expulsar <jugador> [motivo]: lo echa de la zona con guardado final. Por /gm, solo a quien tiene un rol menor.
func _cmd_kick(ctx: CommandRegistry.Context) -> String:
	if ctx.args.is_empty():
		return "Uso: /gm " + _commands.get_usage(&"expulsar")
	var target: ServerPeer = SocialPeers.find_any_by_name(_zone.get_world_peers(), ctx.args[0])
	if target == null:
		return TEXT_NOT_HERE % ChatText.clean(ctx.args[0]).left(NetProtocol.MAX_NAME_CHARS)
	ctx.target = target.entity
	if ctx.origin == CommandRegistry.Origin.CHAT and target.claimed != null \
			and CommandRegistry.role_rank(target.claimed.role) >= CommandRegistry.role_rank(ctx.role):
		ctx.note = "rol del objetivo igual o mayor"
		return TEXT_KICK_DENIED % target.display_name
	var reason: String = " ".join(ctx.args.slice(1)).strip_edges().left(MAX_REASON_CHARS)
	var notice: String = TEXT_KICKED if reason.is_empty() else "%s: %s" % [TEXT_KICKED, reason]
	_zone.kick_peer(target, "expulsado por la moderación", notice)
	return "«%s» expulsado de la zona." % target.display_name


func _cmd_invisible(ctx: CommandRegistry.Context) -> String:
	return _set_invisible(ctx, true)


func _cmd_visible(ctx: CommandRegistry.Context) -> String:
	return _set_invisible(ctx, false)


# /gm invisible y /gm visible actúan sobre quien los escribe; desde la consola, sobre el jugador que se nombra.
# Hacerse visible marca al personaje (gm_forced) con plataforma: no cobra hasta reaparecer (progresion.md §6.2).
func _set_invisible(ctx: CommandRegistry.Context, invisible: bool) -> String:
	var target: ServerPeer = null
	if ctx.origin == CommandRegistry.Origin.CHAT:
		target = ctx.peer
	elif not ctx.args.is_empty():
		target = SocialPeers.find_any_by_name(_zone.get_world_peers(), ctx.args[0])
		if target == null:
			return TEXT_NOT_HERE % ChatText.clean(ctx.args[0]).left(NetProtocol.MAX_NAME_CHARS)
	else:
		return "Uso: %s <jugador>" % ("invisible" if invisible else "visible")
	if target == null or target.entity == null:
		return TEXT_UNKNOWN
	ctx.target = target.entity
	_zone.set_gm_invisible(target.entity, invisible)
	if not invisible and _platform != null:
		target.entity.gm_forced = true
	if ctx.origin != CommandRegistry.Origin.CHAT:
		return "%s es ahora %s" % [target.display_name, "invisible" if invisible else "visible"]
	return TEXT_INVISIBLE if invisible else TEXT_VISIBLE


# --- Ignorados y reportes ----------------------------------------------------------------------

func _ignore(peer: ServerPeer, rest: String, add: bool, now_tick: int) -> void:
	if _platform == null or peer.claimed == null:
		_reply(peer, TEXT_NO_PLATFORM, now_tick)
		return
	var target_name: String = rest.split(" ", false)[0] if not rest.is_empty() else ""
	if target_name.is_empty():
		_reply(peer, TEXT_IGNORE_USAGE if add else TEXT_UNIGNORE_USAGE, now_tick)
		return
	if target_name.length() > NameRules.MAX_LENGTH:
		_reply(peer, TEXT_NAME_TOO_LONG, now_tick)
		return
	if NameRules.normalize_key(target_name) == SocialPeers.name_key_of(peer):
		_reply(peer, TEXT_IGNORE_SELF, now_tick)
		return
	if _platform.is_fenced():
		_reply(peer, TEXT_PLATFORM_DOWN, now_tick)
		return
	_stats[&"ignores" if add else &"unignores"] += 1
	_platform.request(PlatformEvent.KIND_IGNORE, HTTPClient.METHOD_POST if add else HTTPClient.METHOD_DELETE,
			"/internal/v1/ignores", {"character_id": str(peer.claimed.character_id), "target_name": target_name},
			PlatformClient.PRIORITY_PLAYER, _request_context(peer, {"add": add, "target_name": target_name}))


func _on_ignore(event: PlatformEvent, context: Dictionary) -> void:
	var peer: ServerPeer = _requester(context)
	var target_name: String = String(context.get("target_name", ""))
	var shown: String = ChatText.clean(target_name).left(NetProtocol.MAX_NAME_CHARS)
	var key: String = NameRules.normalize_key(target_name)
	if bool(context.get("add", true)):
		if event.is_success():
			var account_id: int = PlatformJson.id_of(event.body_dict().get("ignored_account_id"))
			var name: String = PlatformJson.text_in(event.body_dict(), "name", shown)
			if peer != null and account_id > 0:
				peer.chat.ignored_accounts[account_id] = true
				peer.chat.ignored_by_name[key] = account_id
				peer.chat.ignored_by_name[NameRules.normalize_key(name)] = account_id
			_reply_later(peer, TEXT_IGNORED % name)
			return
		_reply_later(peer, _failure_text(event, shown, TEXT_IGNORE_SELF, {"ignore_list_full": TEXT_IGNORE_FULL}))
		return
	if event.is_success():
		if peer != null:
			var accounts: Array[int] = []
			if peer.chat.ignored_by_name.has(key):
				accounts.append(peer.chat.ignored_by_name[key])
			var present: ServerPeer = SocialPeers.find_any_by_name(_zone.get_world_peers(), target_name)
			if present != null and present.claimed != null:
				accounts.append(present.claimed.account_id)
			for account_id: int in accounts:
				peer.chat.ignored_accounts.erase(account_id)
				for name_key: String in peer.chat.ignored_by_name.keys():
					if peer.chat.ignored_by_name[name_key] == account_id:
						peer.chat.ignored_by_name.erase(name_key)
		_reply_later(peer, TEXT_UNIGNORED % shown)
		return
	_reply_later(peer, _failure_text(event, shown, TEXT_IGNORE_SELF, {}))


func _report(peer: ServerPeer, rest: String, now_tick: int) -> void:
	if _platform == null or peer.claimed == null or peer.entity == null:
		_reply(peer, TEXT_NO_PLATFORM, now_tick)
		return
	var words: PackedStringArray = rest.split(" ", false, 2)
	if words.size() < 2 or not REPORT_CATEGORIES.has(NameRules.normalize_key(words[1])):
		_reply(peer, TEXT_REPORT_USAGE, now_tick)
		return
	var target_name: String = words[0]
	if target_name.length() > NameRules.MAX_LENGTH:
		_reply(peer, TEXT_NAME_TOO_LONG, now_tick)
		return
	var key: String = NameRules.normalize_key(target_name)
	if key == SocialPeers.name_key_of(peer):
		_reply(peer, TEXT_REPORT_SELF, now_tick)
		return
	var state: ChatPeerState = peer.chat
	var shown: String = ChatText.clean(target_name).left(NetProtocol.MAX_NAME_CHARS)
	var last: int = state.reported_at.get(key, -REPORT_TARGET_WINDOW_TICKS - 1)
	if now_tick - last < REPORT_TARGET_WINDOW_TICKS:
		_stats[&"reports_refused"] += 1
		_reply(peer, TEXT_REPORT_AGAIN % [shown, _minutes_left(REPORT_TARGET_WINDOW_TICKS - (now_tick - last))],
				now_tick)
		return
	var recent := PackedInt64Array()
	for tick: int in state.report_ticks:
		if now_tick - tick < REPORT_HOUR_TICKS:
			recent.append(tick)
	state.report_ticks = recent
	if recent.size() >= REPORTS_PER_HOUR:
		_stats[&"reports_refused"] += 1
		_reply(peer, TEXT_REPORT_TOO_MANY % _minutes_left(REPORT_HOUR_TICKS - (now_tick - recent[0])), now_tick)
		return
	if _platform.is_fenced():
		_reply(peer, TEXT_PLATFORM_DOWN, now_tick)
		return
	var evidence: Array = []
	for line: ChatPeerState.Received in state.received_from(key, now_tick - EVIDENCE_WINDOW_TICKS, MAX_EVIDENCE):
		evidence.append({"sender_name": line.sender_name, "channel": line.channel, "text": line.text,
				"sent_at_unix": line.sent_at_unix})
	var position: Vector3 = peer.entity.get_position()
	var report_context: Dictionary = {
		"zone_id": _zone.get_config().zone_id, "zone_channel": _zone.get_config().channel, "tick": now_tick,
		"reporter_position": [snappedf(position.x, 0.01), snappedf(position.y, 0.01), snappedf(position.z, 0.01)],
	}
	var target: ServerPeer = SocialPeers.find_any_by_name(_zone.get_world_peers(), target_name)
	if target != null and target.entity != null:
		var at: Vector3 = target.entity.get_position()
		report_context["target_position"] = [snappedf(at.x, 0.01), snappedf(at.y, 0.01), snappedf(at.z, 0.01)]
	state.reported_at[key] = now_tick
	state.report_ticks.append(now_tick)
	_stats[&"reports"] += 1
	_platform.request(PlatformEvent.KIND_REPORT, HTTPClient.METHOD_POST, "/internal/v1/reports", {
		"reporter_character_id": str(peer.claimed.character_id), "target_name": target_name,
		"category": REPORT_CATEGORIES[NameRules.normalize_key(words[1])],
		"comment": (words[2] if words.size() > 2 else "").strip_edges().left(MAX_COMMENT_CHARS),
		"context": report_context, "evidence": evidence,
	}, PlatformClient.PRIORITY_PLAYER, _request_context(peer, {"target_name": target_name, "tick": now_tick}))


func _on_report(event: PlatformEvent, context: Dictionary) -> void:
	var peer: ServerPeer = _requester(context)
	var target_name: String = String(context.get("target_name", ""))
	var shown: String = ChatText.clean(target_name).left(NetProtocol.MAX_NAME_CHARS)
	if event.is_success():
		_reply_later(peer, TEXT_REPORT_SENT)
		return
	if event.status == 429:
		var wait_s: int = PlatformJson.int_in(event.error_dict(), "retry_after_s", 1, 86400, 60)
		_reply_later(peer, TEXT_REPORT_LIMITED % ceili(float(wait_s) / 60.0))
		return
	# No llegó a la cola: no cuenta para los límites de la zona.
	if peer != null:
		var key: String = NameRules.normalize_key(target_name)
		if peer.chat.reported_at.get(key, -1) == int(context.get("tick", -2)):
			peer.chat.reported_at.erase(key)
			var index: int = peer.chat.report_ticks.find(int(context.get("tick", -2)))
			if index >= 0:
				peer.chat.report_ticks.remove_at(index)
	_reply_later(peer, _failure_text(event, shown, TEXT_REPORT_SELF, {}))


# La respuesta de una sanción: el texto a quien la pidió (si sigue aquí) y, con el 200, lo que toca a quien la recibe
# si está en esta zona.
func _on_sanction(event: PlatformEvent, context: Dictionary) -> void:
	var peer: ServerPeer = _requester(context)
	var target_name: String = String(context.get("target_name", ""))
	var shown: String = ChatText.clean(target_name).left(NetProtocol.MAX_NAME_CHARS)
	var kind: String = String(context.get("kind", ""))
	if not event.is_success():
		if event.status == 403:
			_stats[&"sanctions_denied"] += 1
		_reply_later(peer, _failure_text(event, shown, TEXT_SANCTION_FORBIDDEN % shown,
				{"forbidden": TEXT_SANCTION_FORBIDDEN % shown}))
		return
	_stats[&"sanctions_applied"] += 1
	var body: Dictionary = event.body_dict()
	var ends_at: int = PlatformJson.int_in(body, "ends_at_unix", 1, ChatPeerState.MUTE_NO_END_UNIX, 0)
	var until_text: String = " hasta el %s" % date_text(ends_at) if ends_at > 0 else ""
	_reply_later(peer, TEXT_SANCTION_APPLIED % [KIND_NAMES.get(kind, kind), shown, until_text])
	var target: ServerPeer = SocialPeers.find_any_by_name(_zone.get_world_peers(), target_name)
	var reason: String = String(context.get("reason", ""))
	match kind:
		KIND_MUTE:
			if target != null:
				target.chat.muted_until_unix = ends_at if ends_at > 0 else ChatPeerState.MUTE_NO_END_UNIX
				target.chat.mute_changed_msec = Time.get_ticks_msec()
				var minutes: int = int(context.get("minutes", 0))
				_zone.send_notice(target, TEXT_MUTED_NOW % ["%d min" % minutes if minutes > 0 else "sin fin",
						reason])
		KIND_WARNING:
			if target != null:
				_zone.send_notice(target, TEXT_WARNED % reason)
		KIND_RENAME:
			if target != null:
				_zone.kick_peer(target, "renombrado forzado", TEXT_RENAME_KICK)
		KIND_SUSPENSION, KIND_BAN:
			# El latido trae el revoked con el texto de la plataforma: que salga ya.
			_platform.send_heartbeat_now()


# --- Auditoría y chat --------------------------------------------------------------------------

# La entrada del lote de auditoría de un comando ejecutado (CommandRegistry.audit_entry_sink, §9.1).
func _audit_entry(ctx: CommandRegistry.Context, command_name: StringName, _result: String) -> void:
	if ctx.audit_deferred:
		return
	# Un comando que crea una operación fija la hora: la de su detail.at_unix, la misma que la fila del guardado (S8).
	var at_unix: int = ctx.audit_at_unix if ctx.audit_at_unix > 0 else now_unix()
	var entry: Dictionary = {"command": String(command_name), "at_unix": at_unix, "actor_account_id": null,
			"actor_character_id": null, "target_character_id": null, "target_account_id": null}
	var target: NetEntity = ctx.target
	if ctx.origin == CommandRegistry.Origin.CONSOLE:
		entry["source"] = "console"
	else:
		if ctx.peer == null or ctx.peer.claimed == null:
			return
		entry["source"] = "zone"
		entry["actor_account_id"] = str(ctx.peer.claimed.account_id)
		entry["actor_character_id"] = str(ctx.peer.claimed.character_id)
		# Un DEBUG_COMMAND actúa sobre quien lo manda.
		if target == null and ctx.origin == CommandRegistry.Origin.NETWORK:
			target = ctx.peer.entity
	if target != null:
		var owner: ServerPeer = _zone.get_peer(target.owner_peer) if target.owner_peer > 0 else null
		if owner != null and owner.entity == target and owner.claimed != null:
			entry["target_character_id"] = str(owner.claimed.character_id)
			entry["target_account_id"] = str(owner.claimed.account_id)
	var args: Dictionary = ctx.audit_args.duplicate(true)
	if args.is_empty():
		if ctx.origin == CommandRegistry.Origin.NETWORK:
			if not ctx.payload.is_empty():
				args["payload"] = ctx.payload.hex_encode()
		else:
			# Solo los números: el resto puede ser un nombre o texto libre, que la auditoría no guarda (§9.1).
			var values: Array = []
			for arg: String in ctx.args:
				if arg.is_valid_float():
					values.append(arg.to_float())
			if not values.is_empty():
				args["values"] = values
	entry["args"] = args
	if not ctx.audit_key.is_empty():
		entry["key"] = ctx.audit_key
	_stats[&"audit_entries"] += 1
	_platform.enqueue_batch(&"audit", entry)


func _log_chat(entry: Dictionary) -> void:
	_stats[&"chat_entries"] += 1
	_platform.enqueue_batch(&"chat", entry)


# --- Auxiliares --------------------------------------------------------------------------------

# El nombre del comando de /gm de un tipo de sanción.
static func _command_of(kind: String) -> String:
	return {KIND_WARNING: "aviso", KIND_MUTE: "silenciar", KIND_SUSPENSION: "suspender", KIND_RENAME: "renombrar",
			KIND_BAN: "banear"}.get(kind, "")


# El contexto de una petición: quién la pide (por personaje y arrendamiento, que sobreviven a un net_id reutilizado).
func _request_context(peer: ServerPeer, extra: Dictionary) -> Dictionary:
	var context: Dictionary = {"peer_id": peer.peer_id, "character_id": peer.claimed.character_id,
			"lease_id": peer.claimed.lease_id}
	context.merge(extra)
	return context


# Quien pidió lo de [param context], si sigue en el mundo con el mismo personaje; si no, null.
func _requester(context: Dictionary) -> ServerPeer:
	var peer: ServerPeer = _zone.get_peer(int(context.get("peer_id", 0)))
	if peer == null or peer.claimed == null or peer.state != ServerPeer.State.IN_WORLD \
			or peer.claimed.character_id != int(context.get("character_id", 0)):
		return null
	return peer


# El texto de una respuesta fallida de ignorar, reportar o sancionar: el nombre que no existe, la propia cuenta, los
# códigos de [param by_code] o la plataforma que no responde.
func _failure_text(event: PlatformEvent, shown: String, self_text: String, by_code: Dictionary) -> String:
	if by_code.has(event.error_code):
		return by_code[event.error_code]
	if event.status == 404:
		return TEXT_NOBODY % shown
	if event.status == 400:
		var fields: Dictionary = PlatformJson.dict_in(event.error_dict(), "fields")
		if PlatformJson.text_in(fields, "target_name") == "self":
			return self_text
		return TEXT_BAD_REQUEST % ", ".join(PackedStringArray(fields.keys()))
	_log("Moderación: %s rechazada (%s)" % [event.kind, ZonePlatform.describe(event)])
	return TEXT_PLATFORM_DOWN


func _reply(peer: ServerPeer, text: String, now_tick: int) -> void:
	if not text.is_empty():
		_social.get_chat().send_system(peer, text, now_tick)


func _reply_later(peer: ServerPeer, text: String) -> void:
	if peer != null:
		_reply(peer, text, _zone.get_tick())


static func _minutes_left(ticks: int) -> int:
	return maxi(ceili(float(ticks) / float(60 * Engine.physics_ticks_per_second)), 1)


func _log(text: String) -> void:
	if log_sink.is_valid():
		log_sink.call(text)
