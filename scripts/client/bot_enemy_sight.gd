class_name BotEnemySight
extends RefCounted
## Where a client bot sees its enemies (the [code]enemy_finder[/code] of [constant
## BotBrain.Pattern.COMBAT]): the nearest of the remotes that its [RemoteWorld] draws.
## [br][br]
## A remote is an enemy if the server would let the bot damage it in this zone
## ([method FactionRules.can_damage] with the bot's realm and the remote's, and the WELCOME's
## zone), if it is drawn and not dead ([method RemotePlayerView.get_drawn_health_q] greater than
## 0). NPCs (dummies) only count with [code]include_npcs[/code]; with [code]include_war_npcs[/code]
## the war NPCs count (those with a definition id, [method RemotePlayerView.get_npc_def_id]: the
## Hollow, captains, garrisons), not the dummies; with [code]war_npcs_only[/code], only them (the
## siege brain's defender finder, [method BotBrain.set_defender_finder]). It does not know about
## safe zones or respawn protection (the server knows that): a bot chasing someone in their camp
## does no damage, and the server's fake players do avoid it.

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


## Drawn position (a [Vector3]) of the enemy nearest to [param position] (with height weighted:
## [method BotBrain.target_distance_squared]), or null if there is none.
func find(position: Vector3) -> Variant:
	var view: RemotePlayerView = _nearest_enemy(position)
	return view.get_drawn_position() if view != null else null


## Like [method find], but with what the bots' kit also needs (H5; docs/habilidades.md, section
## 7.1): a [BotTarget] with the drawn position, the velocity of its drawn body (for lead shots: the
## server rewinds arrows to what was drawn) and whether it is knocked down (the DOWNED action in its record).
func find_target(position: Vector3) -> Variant:
	var view: RemotePlayerView = _nearest_enemy(position)
	if view == null:
		return null
	var body: PlayerCharacter = view.get_body()
	return BotTarget.new(view.get_drawn_position(), body.velocity if body != null else Vector3.ZERO,
			_is_downed(view), view.get_net_id())


## The drawn feet of the nearest knocked-down ally (a player of its realm with the DOWNED action)
## to [param position], or null.
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
		var war_npc: bool = view.get_kind() == NetProtocol.EntityKind.NPC and view.get_npc_def_id() > 0
		if _war_npcs_only and not war_npc:
			continue
		if view.get_kind() != NetProtocol.EntityKind.PLAYER and not _include_npcs \
				and not (_include_war_npcs and war_npc):
			continue
		if not FactionRules.can_damage(config.realm, view.get_realm(), zone_id):
			continue
		var feet: Vector3 = view.get_drawn_position()
		var distance: float = BotBrain.target_distance_squared(position, feet)
		if distance < best_distance:
			best_distance = distance
			best = view
	return best
