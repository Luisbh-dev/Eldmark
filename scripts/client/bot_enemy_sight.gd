class_name BotEnemySight
extends RefCounted
## Dónde ve un bot del cliente a sus enemigos (el [code]enemy_finder[/code] de [constant
## BotBrain.Pattern.COMBAT]): el más cercano de los remotos que dibuja su [RemoteWorld].
## [br][br]
## Un remoto es enemigo si el servidor dejaría que el bot lo dañase en esta zona
## ([method FactionRules.can_damage] con el reino del bot y el del remoto, y la zona del WELCOME), si
## está dibujado y no está muerto ([method RemotePlayerView.get_drawn_health_q] mayor que 0). Los PNJ
## (maniquíes) solo cuentan con [code]include_npcs[/code]; con [code]include_war_npcs[/code] cuentan los PNJ de
## guerra (los que tienen un id de definición, [method RemotePlayerView.get_npc_def_id]: Huecos, capitanes,
## guarniciones), no los maniquíes. No conoce las zonas seguras ni la protección de
## reaparición (eso lo sabe el servidor): un bot que persigue a alguien en su campamento no le hace
## daño, y los jugadores falsos del servidor sí lo evitan.

var _client: NetClient
var _include_npcs: bool = false
var _include_war_npcs: bool = false


func _init(client: NetClient, include_npcs: bool = false, include_war_npcs: bool = false) -> void:
	_client = client
	_include_npcs = include_npcs
	_include_war_npcs = include_war_npcs


## Posición dibujada (un [Vector3]) del enemigo más cercano a [param position], o null si no hay
## ninguno.
func find(position: Vector3) -> Variant:
	var view: RemotePlayerView = _nearest_enemy(position)
	return view.get_drawn_position() if view != null else null


## Como [method find], pero con lo que el kit de los bots necesita además (H5; docs/habilidades.md, sección
## 7.1): un [BotTarget] con la posición dibujada, la velocidad de su cuerpo dibujado (para el tiro adelantado: el
## servidor rebobina las flechas a lo que se dibujaba) y si está derribado (la acción DOWNED de su registro).
func find_target(position: Vector3) -> Variant:
	var view: RemotePlayerView = _nearest_enemy(position)
	if view == null:
		return null
	var body: PlayerCharacter = view.get_body()
	return BotTarget.new(view.get_drawn_position(), body.velocity if body != null else Vector3.ZERO,
			_is_downed(view), view.get_net_id())


## Los pies dibujados del aliado derribado (un jugador de su reino con la acción DOWNED) más cercano a
## [param position], o null.
func find_downed_ally(position: Vector3) -> Variant:
	var world: RemoteWorld = _client.get_remote_world()
	var config: ClientConfig = _client.get_config()
	if world == null or config == null:
		return null
	var best: Variant = null
	var best_distance: float = INF
	for view: RemotePlayerView in world.get_views():
		if not view.is_drawn() or view.get_kind() != NetProtocol.EntityKind.PLAYER \
				or view.get_realm() != config.realm or not _is_downed(view):
			continue
		var feet: Vector3 = view.get_drawn_position()
		var distance: float = position.distance_squared_to(feet)
		if distance < best_distance:
			best_distance = distance
			best = feet
	return best


static func _is_downed(view: RemotePlayerView) -> bool:
	return (view.get_drawn_action() & 15) == CombatState.Action.DOWNED


func _nearest_enemy(position: Vector3) -> RemotePlayerView:
	var world: RemoteWorld = _client.get_remote_world()
	var config: ClientConfig = _client.get_config()
	var welcome: NetMessages.Welcome = _client.get_welcome()
	if world == null or config == null or welcome == null:
		return null
	var zone_id: StringName = StringName(welcome.zone_id)
	var best: RemotePlayerView = null
	var best_distance: float = INF
	for view: RemotePlayerView in world.get_views():
		if not view.is_drawn() or view.get_drawn_health_q() == EntityRecord.HEALTH_Q_DEAD:
			continue
		if view.get_kind() != NetProtocol.EntityKind.PLAYER and not _include_npcs \
				and not (_include_war_npcs and view.get_kind() == NetProtocol.EntityKind.NPC \
				and view.get_npc_def_id() > 0):
			continue
		if not FactionRules.can_damage(config.realm, view.get_realm(), zone_id):
			continue
		var feet: Vector3 = view.get_drawn_position()
		var distance: float = position.distance_squared_to(feet)
		if distance < best_distance:
			best_distance = distance
			best = view
	return best
