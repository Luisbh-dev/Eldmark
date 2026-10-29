class_name CombatActionAnim
extends Resource
## Cómo se anima una acción de combate (ART-07/ART-08): qué clip y qué tramos de él. Se identifica
## por [member key], que es el nombre de un ataque del catálogo ([code]sword_light_1[/code],
## [code]sword_heavy[/code]...) o de una acción sin ataque ([code]charge[/code],
## [code]block[/code], [code]dodge[/code], [code]stagger[/code], [code]stun[/code],
## [code]dead[/code]); ver [method CombatClipPlanner.key_for].
## [br][br]
## [b]Ataques[/b]: tres tramos, uno por fase. [member windup], [member active] y [member recovery] se
## reescalan a la duración de la anticipación, el golpe activo y la recuperación del ataque en los
## datos de combate. [member contact_s] es el segundo del clip, dentro de [member active], en el que
## la hoja da en el blanco: la prueba comprueba que cae dentro de la ventana activa.
## [br][br]
## [b]Resto de acciones[/b]: solo [member windup], que se reproduce durante [member duration_s] (o
## durante lo que dure la acción, si los datos lo dicen: esquiva y controles) y, con [member hold_end],
## se queda en la última pose mientras la acción siga (bloqueo, carga, muerte).

## Clave de la acción (ver la descripción de la clase).
@export var key: StringName = &""
## true: el clip solo se aplica a la parte superior del cuerpo (columna, brazos y cabeza), de modo
## que se puede atacar o bloquear andando; false: cuerpo entero (esquiva, muerte).
@export var upper_body: bool = false
## Tramo de la anticipación (o único tramo en las acciones sin fases).
@export var windup: CombatClipSegment
## Tramo del golpe activo (solo ataques).
@export var active: CombatClipSegment
## Tramo de la recuperación (solo ataques).
@export var recovery: CombatClipSegment
## Segundo del clip de [member active] en el que la hoja da en el blanco (-1 = no aplica).
@export var contact_s: float = -1.0
## Duración (s) de la reproducción de [member windup] en las acciones sin fases y sin duración
## propia en los datos de combate.
@export var duration_s: float = 0.0
## Se queda en la última pose mientras dura la acción (bloqueo, carga, muerte).
@export var hold_end: bool = false
## Segundos que tarda la capa en aparecer al empezar la acción y en irse al acabar.
@export var blend_in_s: float = 0.06
@export var blend_out_s: float = 0.12


## Tramo que corresponde a la fase [param phase] ([constant ActionMachine.PHASE_WINDUP]...). Las
## acciones sin fases siempre usan [member windup].
func segment_for_phase(phase: int) -> CombatClipSegment:
	match phase:
		ActionMachine.PHASE_ACTIVE:
			return active if active != null else windup
		ActionMachine.PHASE_RECOVERY:
			return recovery if recovery != null else windup
	return windup


## true si es una animación de ataque (tiene los tres tramos).
func is_attack() -> bool:
	return windup != null and active != null and recovery != null
