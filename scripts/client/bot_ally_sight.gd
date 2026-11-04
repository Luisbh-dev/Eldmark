class_name BotAllySight
extends RefCounted
## How many of its own a client bot sees near a point (the siege brain's [code]ally_counter[/code],
## [method BotBrain.set_ally_counter]; GUE-44): the remote players of its realm that its
## [RemoteWorld] draws, alive ([method RemotePlayerView.get_drawn_health_q] greater than 0),
## standing (the drawn action is not DOWNED: a knocked-down player publishes its knocked-down
## health, which is never 0; skills integration review) and within the radius horizontally, like
## [code]ZoneServer._count_allies[/code] for the fake players. It is not a remote itself, so it is
## not counted. NPCs (of its realm or not) do not count either.

var _client: NetClient


func _init(client: NetClient) -> void:
	_client = client


## How many players of its realm, not counting itself, it draws within [param radius] meters
## (horizontally) of [param center].
func count(center: Vector3, radius: float) -> int:
	var config: ClientConfig = _client.get_config()
	var welcome: NetMessages.Welcome = _client.get_welcome()
	if welcome == null and config == null:
		return 0
	var realm: int = welcome.realm if welcome != null else config.realm
	return count_in(_client.get_remote_world(), realm, center, radius)


## How many remote players of realm [param realm] [param world] draws, alive, standing and within
## [param radius] meters (horizontally) of [param center]. NPCs, those of other realms, the dead,
## the knocked down and those not yet drawn do not count.
static func count_in(world: RemoteWorld, realm: int, center: Vector3, radius: float) -> int:
	if world == null:
		return 0
	var limit: float = radius * radius
	var found: int = 0
	for view: RemotePlayerView in world.get_views():
		if view.get_kind() != NetProtocol.EntityKind.PLAYER or view.get_realm() != realm:
			continue
		if not view.is_drawn() or view.get_drawn_health_q() == EntityRecord.HEALTH_Q_DEAD \
				or (view.get_drawn_action() & 15) == CombatState.Action.DOWNED:
			continue
		var feet: Vector3 = view.get_drawn_position()
		var dx: float = feet.x - center.x
		var dz: float = feet.z - center.z
		if dx * dx + dz * dz <= limit:
			found += 1
	return found
