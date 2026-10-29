class_name CombatClipSegment
extends Resource
## Un tramo de un clip de animación: de [member from_s] a [member to_s] segundos del clip
## [member animation]. La capa de combate ([CombatAnimationLayer]) lo reproduce estirado o encogido
## para que ocupe exactamente la fase de la acción a la que se asigna (anticipación, golpe activo o
## recuperación), así que la velocidad de reproducción sale de la duración de la fase en los datos
## de combate, no del clip original.

## Clip como «biblioteca/nombre», por ejemplo [code]ual2/Sword_Regular_A[/code]. Las bibliotecas
## las declara [member CombatClipSet.libraries].
@export var animation: StringName = &""
## Segundo del clip en el que empieza el tramo.
@export var from_s: float = 0.0
## Segundo del clip en el que acaba el tramo.
@export var to_s: float = 0.0


## Duración (s) del tramo en el clip original.
func length_s() -> float:
	return to_s - from_s
