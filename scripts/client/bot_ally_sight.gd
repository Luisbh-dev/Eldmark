class_name BotAllySight
extends RefCounted
## Cuántos de los suyos ve un bot del cliente cerca de un punto (el [code]ally_counter[/code] del cerebro de asedio,
## [method BotBrain.set_ally_counter]; GUE-44): los jugadores remotos de su reino que dibuja su [RemoteWorld], vivos
## ([method RemotePlayerView.get_drawn_health_q] mayor que 0) y a menos del radio en horizontal. Él no es un remoto, así
## que no se cuenta. Los PNJ (de su reino o no) tampoco cuentan.

var _client: NetClient


func _init(client: NetClient) -> void:
	_client = client


## Cuántos jugadores de su reino, sin contarle a él, dibuja a menos de [param radius] metros (en horizontal) de
## [param center].
func count(center: Vector3, radius: float) -> int:
	var world: RemoteWorld = _client.get_remote_world()
	var config: ClientConfig = _client.get_config()
	var welcome: NetMessages.Welcome = _client.get_welcome()
	if world == null or (welcome == null and config == null):
		return 0
	var realm: int = welcome.realm if welcome != null else config.realm
	var limit: float = radius * radius
	var found: int = 0
	for view: RemotePlayerView in world.get_views():
		if view.get_kind() != NetProtocol.EntityKind.PLAYER or view.get_realm() != realm:
			continue
		if not view.is_drawn() or view.get_drawn_health_q() == EntityRecord.HEALTH_Q_DEAD:
			continue
		var feet: Vector3 = view.get_drawn_position()
		var dx: float = feet.x - center.x
		var dz: float = feet.z - center.z
		if dx * dx + dz * dz <= limit:
			found += 1
	return found
