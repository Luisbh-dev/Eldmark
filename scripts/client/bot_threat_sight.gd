class_name BotThreatSight
extends RefCounted
## Los golpes avisados que conoce un bot del cliente (el [code]threat_finder[/code] de
## [constant BotBrain.Pattern.SIEGE], F6b): guarda cada TELEGRAPH que le llega (ENTITY_EVENT 6, docs/fuerte.md
## sección 5) como un [BotBrain.Threat] y lo da por activo hasta que pasa su impacto y la ventana activa del golpe.
## Lo usan [SwarmBot] ([code]--bots[/code]) y [ClientBotBrains] ([code]--bot[/code]).
## [br][br]
## El aviso solo trae el origen, el giro y el alcance de la zona, y lo que falta hasta el impacto; el tick con el
## que se pregunta es el de la entrada que se está decidiendo (el que el servidor simulará con ella), así que un
## bot que va por delante del servidor da el golpe por pasado a la vez que ocurre. Un PNJ que avisa otro golpe
## sustituye al anterior.
## [br][br]
## Solo guarda los golpes de quien puede dañar al bot (el contrato de [method BotBrain.set_threat_finder]), igual que los
## falsos del servidor ([code]ZoneServer._find_threats[/code], que se queda con los PNJ de un reino hostil): el servidor
## avisa los fuertes de todos los PNJ, también los de la guarnición del propio bot, y de esos no hay que salir. Quien lo
## crea da la regla ([code]is_hostile[/code]): [SwarmBot], los PNJ de guerra enemigos que conoce por sus altas;
## [ClientBotBrains], [method is_hostile_view] con su [RemoteWorld]. Sin regla los guarda todos.

## Ticks que el golpe sigue activo después del impacto (la ventana activa del golpe del Capitán dura 12).
const ACTIVE_TICKS: int = 12

# net_id del PNJ -> golpe, y tick hasta el que dura.
var _threats: Dictionary[int, BotBrain.Threat] = {}
var _until: Dictionary[int, int] = {}
# (net_id: int) -> bool: true si quien avisa puede dañar al bot. Sin ella, cuentan todos.
var _is_hostile: Callable = Callable()


## [param is_hostile] ([code](net_id: int) -> bool[/code]) dice si el PNJ que avisa puede dañar al bot; los avisos de
## los demás se ignoran. Sin ella (las pruebas de la clase) se guardan todos.
func _init(is_hostile: Callable = Callable()) -> void:
	_is_hostile = is_hostile


## true si el remoto [param net_id] que dibuja [param world] puede dañar a un bot del reino [param realm] en la zona
## [param zone_id] ([method FactionRules.can_damage]). Uno del que no ha llegado el alta no cuenta: el servidor solo avisa a
## quien ya lo tiene, así que no se sabe de quién es.
static func is_hostile_view(world: RemoteWorld, realm: int, zone_id: StringName, net_id: int) -> bool:
	if world == null:
		return false
	var view: RemotePlayerView = world.get_view(net_id)
	return view != null and FactionRules.can_damage(view.get_realm(), realm, zone_id)


## Anota [param event] si es un TELEGRAPH de quien puede dañar al bot (los demás eventos no hacen nada).
func note(event: NetMessages.EntityEvent) -> void:
	if event == null or event.event != NetMessages.EntityEvent.Kind.TELEGRAPH:
		return
	if _is_hostile.is_valid() and not bool(_is_hostile.call(event.net_id)):
		return
	_threats[event.net_id] = BotBrain.Threat.new(event.position, event.yaw, event.get_radius())
	_until[event.net_id] = event.tick + event.impact_in_ticks + ACTIVE_TICKS


## Los golpes que siguen activos en el tick [param tick]; olvida los que ya han pasado.
func find(tick: int) -> Array[BotBrain.Threat]:
	var active: Array[BotBrain.Threat] = []
	for net_id: int in _until.keys():
		if tick > _until[net_id]:
			_until.erase(net_id)
			_threats.erase(net_id)
		else:
			active.append(_threats[net_id])
	return active


## Olvida un PNJ (su DESPAWN).
func forget(net_id: int) -> void:
	_until.erase(net_id)
	_threats.erase(net_id)


## Cuántos golpes recuerda (activos o no comprobados todavía).
func size() -> int:
	return _until.size()
