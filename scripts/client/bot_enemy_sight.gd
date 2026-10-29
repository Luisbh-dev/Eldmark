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
## guarniciones), no los maniquíes; con [code]war_npcs_only[/code], solo ellos (el buscador de defensores del
## cerebro de asedio, [method BotBrain.set_defender_finder]). No conoce las zonas seguras ni la protección de
## reaparición (eso lo sabe el servidor): un bot que persigue a alguien en su campamento no le hace
## daño, y los jugadores falsos del servidor sí lo evitan.

var _client: NetClient
var _include_npcs: bool = false
var _include_war_npcs: bool = false
var _war_npcs_only: bool = false


func _init(client: NetClient, include_npcs: bool = false, include_war_npcs: bool = false,
		war_npcs_only: bool = false) -> void:
	_client = client
	_include_npcs = include_npcs
	_include_war_npcs = include_war_npcs or war_npcs_only
	_war_npcs_only = war_npcs_only


## Posición dibujada (un [Vector3]) del enemigo más cercano a [param position], o null si no hay
## ninguno.
func find(position: Vector3) -> Variant:
	var world: RemoteWorld = _client.get_remote_world()
	var config: ClientConfig = _client.get_config()
	var welcome: NetMessages.Welcome = _client.get_welcome()
	if world == null or config == null or welcome == null:
		return null
	var zone_id: StringName = StringName(welcome.zone_id)
	var best: Variant = null
	var best_distance: float = INF
	for view: RemotePlayerView in world.get_views():
		if not view.is_drawn() or view.get_drawn_health_q() == EntityRecord.HEALTH_Q_DEAD:
			continue
		var war_npc: bool = view.get_kind() == NetProtocol.EntityKind.NPC and view.get_npc_def_id() > 0
		if _war_npcs_only and not war_npc:
			continue
		if view.get_kind() != NetProtocol.EntityKind.PLAYER and not _include_npcs \
				and not (_include_war_npcs and war_npc):
			continue
		if not FactionRules.can_damage(config.realm, view.get_realm(), zone_id):
			continue
		var feet: Vector3 = view.get_drawn_position()
		var distance: float = position.distance_squared_to(feet)
		if distance < best_distance:
			best_distance = distance
			best = feet
	return best
