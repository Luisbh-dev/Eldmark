class_name BotTarget
extends RefCounted
## Someone a bot attends to ([BotBrain]; docs/habilidades.md, section 7.1, H5): where their feet are, how
## fast they move and whether they are knocked down.
## [br][br]
## A bot's enemy finder ([method BotBrain.set_enemy_finder]) may return one of these instead of
## a bare position when the caller knows more: the velocity serves for the bow's lead shot
## ([method Ballistics.solve_lead]) and the knockdown, for going to finish off. With a bare position, the bot assumes
## the enemy is still and standing.

## Feet (m).
var position: Vector3 = Vector3.ZERO
## Velocity (m/s).
var velocity: Vector3 = Vector3.ZERO
## true if knocked down (docs/habilidades.md, section 4.5): does not fight; is finished off or revived.
var downed: bool = false
## net_id (0 if unknown).
var net_id: int = 0


func _init(p_position: Vector3 = Vector3.ZERO, p_velocity: Vector3 = Vector3.ZERO, p_downed: bool = false,
		p_net_id: int = 0) -> void:
	position = p_position
	velocity = p_velocity
	downed = p_downed
	net_id = p_net_id
