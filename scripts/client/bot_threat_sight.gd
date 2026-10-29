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

## Ticks que el golpe sigue activo después del impacto (la ventana activa del golpe del Capitán dura 12).
const ACTIVE_TICKS: int = 12

# net_id del PNJ -> golpe, y tick hasta el que dura.
var _threats: Dictionary[int, BotBrain.Threat] = {}
var _until: Dictionary[int, int] = {}


## Anota [param event] si es un TELEGRAPH (los demás eventos no hacen nada).
func note(event: NetMessages.EntityEvent) -> void:
	if event == null or event.event != NetMessages.EntityEvent.Kind.TELEGRAPH:
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
