class_name ZoneCommands
extends RefCounted
## Administration commands of the zone (docs/networking.md §13, docs/platform.md §9 and docs/progression.md §10).
## [br][br]
## [b]What lives here[/b]: the [CommandRegistry] wiring ([method _register_commands]), the [code]_net_*[/code]
## handlers (the six network commands of DEBUG_COMMAND, which answer with a result code), the
## [code]_console_*[/code] handlers (the same commands from the server console or [code]/gm[/code], which answer
## with text), the console itself ([method start_console], [method push_console_line]) and the two packet
## handlers that carry a command: DEBUG_COMMAND (role check and rate, [method _handle_debug_command]) and
## UNSTUCK_REQUEST ([method _handle_unstuck_request]).
## [br][br]
## [b]Tick step[/b]: the console lines run at the start of the poll ([method _run_console_lines]); DEBUG_COMMAND
## and UNSTUCK_REQUEST arrive in the poll through [ZoneIntents].
## [br][br]
## [b]Touch this file[/b] to add or change a command or a console line. A command that moves, heals or shows a
## character marks it with [member NetEntity.gm_forced] ([method _mark_gm_forced]). The progression commands are
## registered by [ProgressService.setup] and the fortress ones by [FortressController], not here.
## [br][br]
## [b]Moderation[/b] (docs/platform.md §9, [ModerationService], [method get_moderation]): the chat GM
## channel carries [code]/gm[/code] (through the [CommandRegistry], with the claim's role),
## [code]/ignorar[/code] (ignore), [code]/designorar[/code] (unignore) and [code]/reportar[/code]
## (report); with the platform, DEBUG_COMMAND additionally requires the minimum role of each command. An
## invisible GM ([method set_gm_invisible]) does not enter anyone's interest, neither deals nor receives
## damage, is not a target of NPCs or bots and does not count in the circle or on the scoreboard. The
## commands that move, heal or show a character mark it with [member NetEntity.gm_forced] (with the
## platform). Chat is per character ([method SocialService.on_peer_joined]); mutes, ignored players and
## the report ring are applied by [ChatRouter]; the audit and messages go to the platform batches;
## moderation notices go out on entry.
## [br][br]
## It is a plain [RefCounted] owned by the [ZoneServer], which builds it in [code]_init[/code] and passes
## itself in. The state it works on stays reachable through [code]_z[/code]; the state that only this
## subsystem uses lives here. It never runs a step of the tick on its own: [method ZoneServer._physics_process]
## calls it at the point the tick order (documented in its header) requires. Moving code between the
## subsystems is a mechanical change, but moving a call to a different step of the tick is not: the order is
## normative (docs/networking.md, section 3).


## Maximum coordinate (in absolute value) that a debug teleport accepts.
const MAX_TELEPORT_COORDINATE: float = 5000.0
## Distance (m) in front of the player at which a dummy from the spawn_dummy command appears.
const DUMMY_SPAWN_DISTANCE: float = 3.0

var _z: ZoneServer


func _init(zone: ZoneServer) -> void:
	_z = zone


## Executes a console line ([code]kick Ana[/code]) and returns the response. It is what the server does with
## each line of standard input; tests call it directly.
func console_command(line: String) -> String:
	return _z._commands.execute_console(line)


## Starts the standard input console (reader thread, without blocking the tick). Returns false if there is no
## usable standard input or it was already running.
func start_console() -> bool:
	if _z._console == null:
		_z._console = ServerConsole.new()
	return _z._console.start()


## The console ([ServerConsole]), or null if it has not been started nor given a line.
func get_console() -> ServerConsole:
	return _z._console


## Pushes a line into the console queue as if it had been typed on standard input; it is executed at the start
## of the next tick.
func push_console_line(line: String) -> void:
	if _z._console == null:
		_z._console = ServerConsole.new()
	_z._console.push_line(line)


# Registers the administration commands: the six network ones (fixed NetProtocol ids) with their console
# version, and those that are console-only.
# Each command with its minimum role for /gm and, with the platform, for DEBUG_COMMAND (docs/platform.md §9.1): gm by
# default (the network ones: teleport, health, fort); kick, announce and shutdown, and their /gm names anuncio and apagar,
# admin (the kick from the zone by moderators is /gm expulsar, from ModerationService). Those that create or keep
# value of a persistent character or skip their equipment require admin (progression.md §10, P5d): 5 set_weapon and
# 13 cooldowns_off, also through /gm; 16 refill, through DEBUG_COMMAND (through /gm it is a GM operation like item_give, with
# gm). Those of §10 (40–43 and the console ones) are registered by ProgressService.setup.
func _register_commands() -> void:
	var admin: StringName = CommandRegistry.ROLE_ADMIN
	var gm: StringName = CommandRegistry.ROLE_GM
	_z._commands.register(&"teleport", "teleport <jugador> <x> <y> <z> | teleport <jugador> <otro jugador>",
			_console_teleport, _net_teleport)
	_z._commands.register(&"heal", "heal <jugador>", _console_heal, _net_heal)
	_z._commands.register(&"kill", "kill <jugador>", _console_kill, _net_kill)
	_z._commands.register(&"stamina_inf", "stamina_inf <jugador> [on|off]", _console_stamina_inf,
			_net_stamina_inf)
	_z._commands.register(&"set_weapon", "set_weapon <jugador> <arma>", _console_set_weapon,
			_net_set_weapon, admin)
	_z._commands.register(&"spawn_dummy", "spawn_dummy <x> <y> <z> [quieto|bloqueando|girando]",
			_console_spawn_dummy, _net_spawn_dummy)
	_z._commands.register(&"cooldowns_off", "cooldowns_off <jugador> [on|off]", _console_cooldowns_off,
			_net_cooldowns_off, admin)
	_z._commands.register(&"apply_status", "apply_status <jugador> <efecto> [ticks]", _console_apply_status,
			_net_apply_status)
	_z._commands.register(&"down", "down <jugador>", _console_down, _net_down)
	_z._commands.register(&"refill", "refill <jugador> [motivo… (con plataforma, obligatorio)]", _console_refill,
			_net_refill, gm, admin)
	_z._fortresses.register_commands(_z._commands, Callable(_z, "_next_tick"))
	if _z._npc_system != null:
		_z._npc_system.register_commands(_z._commands)
	_z._commands.register(&"unstuck", "unstuck <jugador>", _console_unstuck, _net_unstuck)
	_z._commands.register(&"announce", "announce <texto>", _console_announce, Callable(), admin)
	_z._commands.register(&"anuncio", "anuncio <texto>", _console_announce, Callable(), admin)
	_z._commands.register(&"kick", "kick <jugador> [motivo]", _console_kick, Callable(), admin)
	_z._commands.register(&"shutdown", "shutdown <segundos> | shutdown cancel", _console_shutdown, Callable(), admin)
	_z._commands.register(&"apagar", "apagar <segundos> | apagar cancelar", _console_shutdown, Callable(), admin)
	_z._commands.register(&"players", "players", _console_players)


# Executes the lines someone has typed in the console since the previous tick.
func _run_console_lines() -> void:
	if _z._console == null:
		return
	for line: String in _z._console.take_lines():
		var response: String = _z._commands.execute_console(line)
		if not response.is_empty():
			_z._log(response)


# A player, fake player or NPC by net_id or by name (case-insensitive), or null.
func _find_entity(text: String) -> NetEntity:
	var wanted: String = text.strip_edges()
	if wanted.is_valid_int():
		var by_id: NetEntity = _z._registry.get_entity(wanted.to_int())
		if by_id != null:
			return by_id
	var key: String = NameRules.normalize_key(wanted)
	for entity: NetEntity in _z._registry.get_sorted():
		if NameRules.normalize_key(entity.display_name) == key:
			return entity
	return null


func _is_valid_teleport_target(target: Vector3) -> bool:
	return target.is_finite() and absf(target.x) <= MAX_TELEPORT_COORDINATE \
			and absf(target.y) <= MAX_TELEPORT_COORDINATE \
			and absf(target.z) <= MAX_TELEPORT_COORDINATE


# Position of a dummy from the spawn_dummy command: in front of the player, facing them.
func _dummy_spawn_for(entity: NetEntity) -> Transform3D:
	var yaw: float = entity.get_character().yaw
	var forward: Vector3 = Basis(Vector3.UP, yaw) * Vector3.FORWARD
	return Transform3D(Basis(Vector3.UP, yaw + PI),
			entity.get_position() + forward * DUMMY_SPAWN_DISTANCE)


func _combatant_of_peer(ctx: CommandRegistry.Context) -> Combatant:
	if ctx.peer == null or ctx.peer.entity == null:
		return null
	return _z._combat.get_combatant(ctx.peer.entity.net_id)


# With the platform, a GM command that moves, heals or shows a character flags it until it respawns
# (progression.md §6.2; docs/platform.md §9.1): it does not enter the capture list nor earn merits or NPC rewards.
func _mark_gm_forced(entity: NetEntity) -> void:
	if _z._platform != null and entity != null and entity.kind == NetProtocol.EntityKind.PLAYER:
		entity.gm_forced = true


# The player (or fake or NPC) that [param text] names for a command, recorded as its target in the audit.
func _command_target(ctx: CommandRegistry.Context, text: String) -> NetEntity:
	var entity: NetEntity = _find_entity(text)
	ctx.target = entity
	return entity


func _net_teleport(ctx: CommandRegistry.Context) -> int:
	if ctx.payload.size() != NetMessages.DebugCommand.TELEPORT_PAYLOAD_SIZE:
		return CommandRegistry.Result.BAD_ARGUMENTS
	var target := Vector3(ctx.payload.decode_float(0), ctx.payload.decode_float(4),
			ctx.payload.decode_float(8))
	if not _is_valid_teleport_target(target):
		ctx.note = "destino fuera de rango"
		return CommandRegistry.Result.BAD_ARGUMENTS
	_z.teleport(ctx.peer.entity.net_id, target)
	_mark_gm_forced(ctx.peer.entity)
	ctx.note = str(target)
	ctx.audit_args = {"position": [target.x, target.y, target.z]}
	return CommandRegistry.Result.OK


func _net_heal(ctx: CommandRegistry.Context) -> int:
	var combatant: Combatant = _combatant_of_peer(ctx)
	if combatant == null or not combatant.is_alive():
		return CommandRegistry.Result.REFUSED
	_z._combat.heal(combatant)
	_mark_gm_forced(combatant.entity)
	return CommandRegistry.Result.OK


func _net_kill(ctx: CommandRegistry.Context) -> int:
	var combatant: Combatant = _combatant_of_peer(ctx)
	if combatant == null or combatant.is_dead():
		return CommandRegistry.Result.REFUSED
	_z._combat.kill(combatant, _z._tick + 1)
	return CommandRegistry.Result.OK


func _net_stamina_inf(ctx: CommandRegistry.Context) -> int:
	var combatant: Combatant = _combatant_of_peer(ctx)
	if combatant == null:
		return CommandRegistry.Result.REFUSED
	var enabled: bool
	match ctx.payload.size():
		0:
			enabled = (combatant.get_character().combat.combat_flags
					& CombatState.FLAG_INFINITE_STAMINA) == 0
		1:
			enabled = ctx.payload[0] != 0
		_:
			return CommandRegistry.Result.BAD_ARGUMENTS
	_z._combat.set_infinite_stamina(combatant, enabled)
	_mark_gm_forced(combatant.entity)
	ctx.note = "activada" if enabled else "desactivada"
	return CommandRegistry.Result.OK


func _net_set_weapon(ctx: CommandRegistry.Context) -> int:
	var combatant: Combatant = _combatant_of_peer(ctx)
	if combatant == null:
		return CommandRegistry.Result.REFUSED
	if ctx.payload.size() != 2:
		return CommandRegistry.Result.BAD_ARGUMENTS
	var weapon_id: int = ctx.payload.decode_u16(0)
	if CombatCatalog.weapon(weapon_id) == null:
		ctx.note = "arma %d inexistente" % weapon_id
		return CommandRegistry.Result.BAD_ARGUMENTS
	# 5 is set_loadout with the weapon in slot 1 (docs/abilities.md, section 3.5), with its LOADOUT.
	if not _z._combat.set_weapon(combatant, weapon_id, _z._tick + 1):
		return CommandRegistry.Result.REFUSED
	return CommandRegistry.Result.OK


# 13 cooldowns_off (docs/abilities.md, section 5.1): u8 0 or 1, bit 7 of combat_flags2.
func _net_cooldowns_off(ctx: CommandRegistry.Context) -> int:
	var combatant: Combatant = _combatant_of_peer(ctx)
	if combatant == null:
		return CommandRegistry.Result.REFUSED
	if ctx.payload.size() != 1 or ctx.payload[0] > 1:
		return CommandRegistry.Result.BAD_ARGUMENTS
	var enabled: bool = ctx.payload[0] == 1
	_z._combat.set_cooldowns_off(combatant, enabled)
	ctx.note = "sin reutilizaciones" if enabled else "con reutilizaciones"
	return CommandRegistry.Result.OK


# 14 apply_status: u8 status_id and u16 ticks (0 = those from the data). It is applied to whoever sends it, with no
# author, on the tick the server is about to simulate.
func _net_apply_status(ctx: CommandRegistry.Context) -> int:
	var combatant: Combatant = _combatant_of_peer(ctx)
	if combatant == null:
		return CommandRegistry.Result.REFUSED
	if ctx.payload.size() != NetMessages.DebugCommand.APPLY_STATUS_PAYLOAD_SIZE:
		return CommandRegistry.Result.BAD_ARGUMENTS
	var status_id: int = ctx.payload.decode_u8(0)
	var ticks: int = ctx.payload.decode_u16(1)
	if CombatCatalog.status(status_id) == null:
		ctx.note = "efecto %d inexistente" % status_id
		return CommandRegistry.Result.BAD_ARGUMENTS
	if not _z._combat.apply_status(combatant, status_id, _z._tick + 1, ticks):
		return CommandRegistry.Result.REFUSED
	ctx.note = "%s, %d ticks" % [CombatCatalog.status(status_id).name, ticks]
	return CommandRegistry.Result.OK


# 15 down (docs/abilities.md, section 4.5): knocks itself down with no author (on bleeding out, DEATH without KILL),
# on the tick the server is about to simulate. Rejected outside RvR zones, in one's own safe zone or when not alive.
func _net_down(ctx: CommandRegistry.Context) -> int:
	if not ctx.payload.is_empty():
		return CommandRegistry.Result.BAD_ARGUMENTS
	var combatant: Combatant = _combatant_of_peer(ctx)
	if combatant == null or not _z._combat.down(combatant, _z._tick + 1):
		return CommandRegistry.Result.REFUSED
	return CommandRegistry.Result.OK


# 16 refill: restores the charges of the consumables of its template (set_charges, with LOADOUT to the owner). With an
# inventory, without the platform, a forced CAMP_REFILL of its bag (progression.md §4.4); with the platform, a GM
# operation with a GM_GRANT for what is missing and the note "debug" (progression.md §4.4 and §10, P5d; requires admin).
func _net_refill(ctx: CommandRegistry.Context) -> int:
	if not ctx.payload.is_empty():
		return CommandRegistry.Result.BAD_ARGUMENTS
	var combatant: Combatant = _combatant_of_peer(ctx)
	if combatant == null:
		return CommandRegistry.Result.REFUSED
	if _z._progress.has_inventory(combatant.get_id()):
		if _z._platform != null:
			return _z._progress.gm_commands().net_refill(ctx)
		return CommandRegistry.Result.OK if _z._progress.force_refill(combatant.get_id(), _z._tick + 1) \
				else CommandRegistry.Result.REFUSED
	if not _z._combat.refill(combatant, _z._tick + 1):
		return CommandRegistry.Result.REFUSED
	return CommandRegistry.Result.OK


func _net_spawn_dummy(ctx: CommandRegistry.Context) -> int:
	if ctx.peer == null or ctx.peer.entity == null:
		return CommandRegistry.Result.REFUSED
	var mode: int = NpcBrain.Mode.STILL
	match ctx.payload.size():
		0:
			pass
		1:
			mode = ctx.payload[0]
			if mode < NpcBrain.Mode.STILL or mode > NpcBrain.Mode.SPIN:
				return CommandRegistry.Result.BAD_ARGUMENTS
		_:
			return CommandRegistry.Result.BAD_ARGUMENTS
	var spawn: Transform3D = _dummy_spawn_for(ctx.peer.entity)
	var net_id: int = _z._zone_bodies.spawn_dummy(spawn.origin, CombatDirector._yaw_of(spawn), mode)
	if net_id < 0:
		return CommandRegistry.Result.REFUSED
	ctx.note = "net_id %d, %s" % [net_id, NpcBrain.mode_name(mode)]
	return CommandRegistry.Result.OK


func _net_unstuck(ctx: CommandRegistry.Context) -> int:
	if not ctx.payload.is_empty():
		return CommandRegistry.Result.BAD_ARGUMENTS
	if ctx.peer == null or ctx.peer.entity == null:
		return CommandRegistry.Result.REFUSED
	return CommandRegistry.Result.OK \
			if _z._zone_lingering._request_unstuck(ctx.peer) == UnstuckTracker.RequestResult.STARTED \
			else CommandRegistry.Result.REFUSED


# Teleports the player right away to the nearest safe point of their realm (with no channeling or
# reuse cooldown: it is an administration tool).
func _console_unstuck(ctx: CommandRegistry.Context) -> String:
	if ctx.args.size() != 1:
		return "Uso: unstuck <jugador>"
	var entity: NetEntity = _command_target(ctx, ctx.args[0])
	if entity == null or entity.kind != NetProtocol.EntityKind.PLAYER:
		return "No hay ningún jugador «%s»" % ctx.args[0]
	_z._zone_lingering._teleport_unstuck(entity, _z._tick + 1)
	_mark_gm_forced(entity)
	return "%s llevado al punto seguro más cercano de su reino" % entity.display_name


# teleport <player> <x> <y> <z>, or teleport <player> <other> (next to the other). With the platform it flags the one
# who moves (gm_forced, progression.md §6.2).
func _console_teleport(ctx: CommandRegistry.Context) -> String:
	var usage: String = "Uso: teleport <jugador> <x> <y> <z> | teleport <jugador> <otro jugador>"
	if ctx.args.size() != 4 and ctx.args.size() != 2:
		return usage
	var entity: NetEntity = _command_target(ctx, ctx.args[0])
	if entity == null or entity.get_character() == null:
		return "No hay ningún jugador «%s»" % ctx.args[0]
	var target: Vector3
	if ctx.args.size() == 2:
		var other: NetEntity = _find_entity(ctx.args[1])
		if other == null or other.get_character() == null or (other.gm_invisible and other != entity):
			return "No hay ningún jugador «%s»" % ctx.args[1]
		target = other.get_position()
	else:
		for i: int in range(1, 4):
			if not ctx.args[i].is_valid_float():
				return "Coordenada no válida: %s" % ctx.args[i]
		target = Vector3(ctx.args[1].to_float(), ctx.args[2].to_float(), ctx.args[3].to_float())
	if not _is_valid_teleport_target(target):
		return "Destino fuera de rango"
	_z.teleport(entity.net_id, target)
	_mark_gm_forced(entity)
	ctx.audit_args = {"position": [target.x, target.y, target.z]}
	return "%s teletransportado a %s" % [entity.display_name, target]


func _console_heal(ctx: CommandRegistry.Context) -> String:
	if ctx.args.size() != 1:
		return "Uso: heal <jugador>"
	var combatant: Combatant = _combatant_by_name(ctx.args[0], ctx)
	if combatant == null:
		return "No hay ningún jugador «%s»" % ctx.args[0]
	if combatant.is_dead():
		return "%s está muerto" % combatant.entity.display_name
	if combatant.is_downed():
		return "%s está derribado" % combatant.entity.display_name
	_z._combat.heal(combatant)
	_mark_gm_forced(combatant.entity)
	return "%s curado" % combatant.entity.display_name


func _console_kill(ctx: CommandRegistry.Context) -> String:
	if ctx.args.size() != 1:
		return "Uso: kill <jugador>"
	var combatant: Combatant = _combatant_by_name(ctx.args[0], ctx)
	if combatant == null:
		return "No hay ningún jugador «%s»" % ctx.args[0]
	if combatant.is_dead() or combatant.immortal:
		return "%s no se puede matar" % combatant.entity.display_name
	_z._combat.kill(combatant, _z._tick + 1)
	return "%s muerto" % combatant.entity.display_name


func _console_stamina_inf(ctx: CommandRegistry.Context) -> String:
	if ctx.args.is_empty() or ctx.args.size() > 2:
		return "Uso: stamina_inf <jugador> [on|off]"
	var combatant: Combatant = _combatant_by_name(ctx.args[0], ctx)
	if combatant == null:
		return "No hay ningún jugador «%s»" % ctx.args[0]
	var enabled: bool = (combatant.get_character().combat.combat_flags
			& CombatState.FLAG_INFINITE_STAMINA) == 0
	if ctx.args.size() == 2:
		match ctx.args[1].to_lower():
			"on", "1", "si", "sí":
				enabled = true
			"off", "0", "no":
				enabled = false
			_:
				return "Uso: stamina_inf <jugador> [on|off]"
	_z._combat.set_infinite_stamina(combatant, enabled)
	_mark_gm_forced(combatant.entity)
	return "Resistencia infinita %s para %s" % ["activada" if enabled else "desactivada",
			combatant.entity.display_name]


func _console_set_weapon(ctx: CommandRegistry.Context) -> String:
	if ctx.args.size() != 2:
		return "Uso: set_weapon <jugador> <arma>"
	var combatant: Combatant = _combatant_by_name(ctx.args[0], ctx)
	if combatant == null:
		return "No hay ningún jugador «%s»" % ctx.args[0]
	var weapon_id: int = CombatCatalog.weapon_id(StringName(ctx.args[1]))
	if weapon_id == 0 and ctx.args[1].is_valid_int():
		weapon_id = ctx.args[1].to_int()
	if CombatCatalog.weapon(weapon_id) == null:
		return "No existe el arma «%s»" % ctx.args[1]
	if not _z._combat.set_weapon(combatant, weapon_id, _z._tick + 1):
		return "%s está derribado" % combatant.entity.display_name
	return "%s lleva ahora %s" % [combatant.entity.display_name, ctx.args[1]]


func _console_cooldowns_off(ctx: CommandRegistry.Context) -> String:
	if ctx.args.is_empty() or ctx.args.size() > 2:
		return "Uso: cooldowns_off <jugador> [on|off]"
	var combatant: Combatant = _combatant_by_name(ctx.args[0], ctx)
	if combatant == null:
		return "No hay ningún jugador «%s»" % ctx.args[0]
	var enabled: bool = (combatant.get_character().combat.combat_flags2
			& CombatState.FLAG2_NO_COOLDOWNS) == 0
	if ctx.args.size() == 2:
		match ctx.args[1].to_lower():
			"on", "1", "si", "sí":
				enabled = true
			"off", "0", "no":
				enabled = false
			_:
				return "Uso: cooldowns_off <jugador> [on|off]"
	_z._combat.set_cooldowns_off(combatant, enabled)
	return "%s para %s" % ["Sin reutilizaciones" if enabled else "Con reutilizaciones",
			combatant.entity.display_name]


func _console_apply_status(ctx: CommandRegistry.Context) -> String:
	if ctx.args.size() < 2 or ctx.args.size() > 3:
		return "Uso: apply_status <jugador> <efecto> [ticks]"
	var combatant: Combatant = _combatant_by_name(ctx.args[0], ctx)
	if combatant == null:
		return "No hay ningún jugador «%s»" % ctx.args[0]
	var status_id: int = CombatCatalog.status_id(StringName(ctx.args[1]))
	if status_id == 0 and ctx.args[1].is_valid_int():
		status_id = ctx.args[1].to_int()
	if CombatCatalog.status(status_id) == null:
		return "No existe el efecto «%s»" % ctx.args[1]
	var ticks: int = 0
	if ctx.args.size() == 3:
		if not ctx.args[2].is_valid_int() or ctx.args[2].to_int() < 0 \
				or ctx.args[2].to_int() > 0xFFFF:
			return "Uso: apply_status <jugador> <efecto> [ticks]"
		ticks = ctx.args[2].to_int()
	if not _z._combat.apply_status(combatant, status_id, _z._tick + 1, ticks):
		return "%s no está en pie" % combatant.entity.display_name
	return "%s aplicado a %s" % [CombatCatalog.status(status_id).name, combatant.entity.display_name]


func _console_down(ctx: CommandRegistry.Context) -> String:
	if ctx.args.size() != 1:
		return "Uso: down <jugador>"
	var combatant: Combatant = _combatant_by_name(ctx.args[0], ctx)
	if combatant == null:
		return "No hay ningún jugador «%s»" % ctx.args[0]
	if not _z._combat.down(combatant, _z._tick + 1):
		return "%s no puede quedar derribado aquí" % combatant.entity.display_name
	return "%s derribado" % combatant.entity.display_name


# refill <player>: without the platform, like 16; with it, for whoever has an inventory, the GM operation of 16 with the
# written reason (refill <player> <reason…>; progression.md P5d).
func _console_refill(ctx: CommandRegistry.Context) -> String:
	if ctx.args.is_empty() or (ctx.args.size() != 1 and _z._platform == null):
		return "Uso: refill <jugador>" + (" <motivo…>" if _z._platform != null else "")
	var combatant: Combatant = _combatant_by_name(ctx.args[0], ctx)
	if combatant == null:
		return "No hay ningún jugador «%s»" % ctx.args[0]
	if _z._progress.has_inventory(combatant.get_id()):
		if _z._platform != null:
			return _z._progress.gm_commands().console_refill(ctx, combatant.get_id())
		if not _z._progress.force_refill(combatant.get_id(), _z._tick + 1):
			return "%s no puede reponer ahora" % combatant.entity.display_name
		return "Pociones de %s repuestas" % combatant.entity.display_name
	if not _z._combat.refill(combatant, _z._tick + 1):
		return "%s no tiene cargas que reponer" % combatant.entity.display_name
	return "Cargas de %s repuestas" % combatant.entity.display_name


func _console_spawn_dummy(ctx: CommandRegistry.Context) -> String:
	if ctx.args.size() < 3 or ctx.args.size() > 4:
		return "Uso: spawn_dummy <x> <y> <z> [quieto|bloqueando|girando]"
	for i: int in 3:
		if not ctx.args[i].is_valid_float():
			return "Coordenada no válida: %s" % ctx.args[i]
	var target := Vector3(ctx.args[0].to_float(), ctx.args[1].to_float(), ctx.args[2].to_float())
	if not _is_valid_teleport_target(target):
		return "Posición fuera de rango"
	var mode: int = NpcBrain.Mode.STILL
	if ctx.args.size() == 4:
		mode = NpcBrain.mode_from_name(ctx.args[3])
		if mode < 0:
			return "Modo desconocido: %s (quieto, bloqueando o girando)" % ctx.args[3]
	var net_id: int = _z._zone_bodies.spawn_dummy(target, 0.0, mode)
	if net_id < 0:
		return "No se puede crear otro maniquí (hay %d como mucho)" % ZoneServer.MAX_DUMMIES
	return "Maniquí %s creado (net_id %d)" % [NpcBrain.mode_name(mode), net_id]


func _console_announce(ctx: CommandRegistry.Context) -> String:
	if ctx.args.is_empty():
		return "Uso: announce <texto>"
	var count: int = _z._zone_lifecycle._broadcast_notice(" ".join(ctx.args))
	return "Anuncio enviado a %d jugadores" % count


func _console_kick(ctx: CommandRegistry.Context) -> String:
	if ctx.args.is_empty():
		return "Uso: kick <jugador> [motivo]"
	var entity: NetEntity = _command_target(ctx, ctx.args[0])
	if entity == null or entity.kind != NetProtocol.EntityKind.PLAYER:
		return "No hay ningún jugador «%s»" % ctx.args[0]
	var reason: String = "expulsado desde la consola"
	if ctx.args.size() > 1:
		reason += ": " + " ".join(ctx.args.slice(1))
	if _z._fakes.has(entity.net_id):
		_z._zone_bodies.remove_fake_player(entity.net_id)
		return "Jugador falso %s dado de baja" % entity.display_name
	var peer: ServerPeer = _z._peers.get(entity.owner_peer)
	if peer == null:
		return "%s no está conectado" % entity.display_name
	_z._zone_sessions._kick(peer, reason, false)
	return "%s expulsado" % entity.display_name


func _console_shutdown(ctx: CommandRegistry.Context) -> String:
	if ctx.args.size() != 1:
		return "Uso: shutdown <segundos> | shutdown cancel"
	if ctx.args[0].to_lower() == "cancel" or ctx.args[0].to_lower() == "cancelar":
		if _z._shutdown_tick < 0:
			return "No hay ningún cierre pendiente"
		_z._shutdown_tick = -1
		_z._zone_lifecycle._broadcast_notice("Cierre del servidor cancelado")
		return "Cierre cancelado"
	if not ctx.args[0].is_valid_int() or ctx.args[0].to_int() < 0 or ctx.args[0].to_int() > 86400:
		return "Uso: shutdown <segundos> | shutdown cancel"
	var seconds: int = ctx.args[0].to_int()
	_z._shutdown_tick = _z._tick + seconds * Engine.physics_ticks_per_second
	if seconds > 0:
		_z._zone_lifecycle._broadcast_notice("El servidor se cerrará en %d s" % seconds)
	return "Cierre dentro de %d s" % seconds


func _console_players(_ctx: CommandRegistry.Context) -> String:
	var lines := PackedStringArray()
	for entity: NetEntity in _z._registry.get_sorted():
		if entity.kind == NetProtocol.EntityKind.STRUCTURE:
			continue
		var combatant: Combatant = _z._combat.get_combatant(entity.net_id)
		lines.append("%d %s (%s%s) vida %d/%d" % [entity.net_id, entity.display_name,
				NetProtocol.realm_display_name(entity.realm),
				", PNJ" if entity.kind == NetProtocol.EntityKind.NPC else "",
				combatant.health if combatant != null else 0,
				combatant.max_health if combatant != null else 0])
	return "%d entidades: %s" % [lines.size(), "; ".join(lines)]


# The combat of whoever [param text] names; with [param ctx], it becomes the command's target in the audit.
func _combatant_by_name(text: String, ctx: CommandRegistry.Context = null) -> Combatant:
	var entity: NetEntity = _command_target(ctx, text) if ctx != null else _find_entity(text)
	return _z._combat.get_combatant(entity.net_id) if entity != null else null


func _handle_debug_command(peer: ServerPeer, bytes: PackedByteArray) -> void:
	if peer.state != ServerPeer.State.IN_WORLD:
		_z._zone_sessions._add_strike(peer, "comando de depuración antes de entrar en el mundo")
		return
	if not _z._config.debug_commands:
		_z._zone_sessions._add_strike(peer, "comando de depuración no permitido")
		return
	var command: NetMessages.DebugCommand = NetMessages.DebugCommand.decode(bytes)
	if command == null:
		_z._zone_sessions._add_strike(peer, "comando de depuración mal formado")
		return
	# With the platform, in addition to --debug-commands, the command's minimum role (docs/platform.md §9.1) with that of the
	# claim; without it, a warning and nothing is executed.
	var role: StringName = &""
	if _z._platform != null:
		role = peer.claimed.role if peer.claimed != null else CommandRegistry.ROLE_PLAYER
	var result: int = _z._commands.execute_network(peer, command.command, command.payload, role)
	match result:
		CommandRegistry.Result.FORBIDDEN:
			_z._zone_sessions._add_strike(peer, "comando de depuración sin permiso (%d)" % command.command)
		CommandRegistry.Result.UNKNOWN:
			# A fixed protocol id whose handler does not exist on this server (that of a command that has been
			# removed, or that of npc_debug with --no-npcs) is accepted without doing anything: it is not a faulty client.
			if not NetProtocol.DEBUG_COMMAND_IDS.values().has(command.command):
				_z._zone_sessions._add_strike(peer, "comando de depuración desconocido (%d)" % command.command)
		CommandRegistry.Result.BAD_ARGUMENTS:
			_z._zone_sessions._add_strike(peer, "comando de depuración con argumentos no válidos (%d)"
					% command.command)


# UNSTUCK_REQUEST (/atascado, docs/fortress.md section 5): no need for --debug-commands. A 10 s channeling
# out of combat, interrupted by combat, with a 5 min reuse cooldown; see _request_unstuck.
func _handle_unstuck_request(peer: ServerPeer, bytes: PackedByteArray) -> void:
	if peer.state != ServerPeer.State.IN_WORLD:
		_z._zone_sessions._add_strike(peer, "petición de /atascado antes de entrar en el mundo")
		return
	if NetMessages.UnstuckRequest.decode(bytes) == null:
		_z._zone_sessions._add_strike(peer, "petición de /atascado mal formada")
		return
	_z._zone_lingering._request_unstuck(peer)
