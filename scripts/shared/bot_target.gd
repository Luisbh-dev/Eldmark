class_name BotTarget
extends RefCounted
## Alguien a quien atiende un bot ([BotBrain]; docs/habilidades.md, sección 7.1, H5): dónde tiene los pies, a
## qué velocidad se mueve y si está derribado.
## [br][br]
## El buscador de enemigos de un bot ([method BotBrain.set_enemy_finder]) puede devolver uno de estos en vez de
## una posición sola cuando quien lo llama sabe más: la velocidad sirve para el tiro adelantado del arco
## ([method Ballistics.solve_lead]) y el derribo, para ir a rematar. Con una posición sola, el bot supone que
## el enemigo está quieto y en pie.

## Pies (m).
var position: Vector3 = Vector3.ZERO
## Velocidad (m/s).
var velocity: Vector3 = Vector3.ZERO
## true si está derribado (docs/habilidades.md, sección 4.5): no pelea; se remata o se levanta.
var downed: bool = false
## net_id (0 si no se sabe).
var net_id: int = 0


func _init(p_position: Vector3 = Vector3.ZERO, p_velocity: Vector3 = Vector3.ZERO, p_downed: bool = false,
		p_net_id: int = 0) -> void:
	position = p_position
	velocity = p_velocity
	downed = p_downed
	net_id = p_net_id
