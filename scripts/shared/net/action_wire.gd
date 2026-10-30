class_name ActionWire
extends RefCounted
## El byte de acción del registro de red ([member EntityRecord.action]) tal y como lo publica el
## servidor y lo lee el cliente (docs/combate.md, secciones 3.4 y 6).
## [br][br]
## Parte del byte de [method ActionMachine.action_byte] (bits 0-3 la acción, 4-5 la fase, 6-7 el paso
## del combo del ligero en curso o la ranura de la habilidad: 0-2, o 3 si es un consumible) y rellena
## los bits 6-7 de las acciones que se encadenan consigo mismas con un [b]contador de reinicio[/b].
## Sin él, dos acciones iguales y seguidas serían indistinguibles para un remoto: la esquiva o el
## cambio de arma guardados en el búfer salen en el mismo tick en que acaba el anterior (nunca hay un
## tick en NONE) y un segundo tambaleo o aturdimiento encadena con el primero; en los dos casos el
## byte es idéntico, el remoto no reiniciaría el clip y recorrería la segunda acción congelado en la
## última pose. Una habilidad no lo necesita: entre dos usos de la misma ranura (o dos consumibles) hay
## siempre [constant AbilityTicks.REARM_TICKS] ticks de NONE, más que el intervalo de los snapshots: la
## validación del catálogo lo exige a las reutilizaciones y una interrupción antes del compromiso deja ese
## margen (docs/habilidades.md, sección 5.5; con un solo tick, un remoto que no lo muestreaba seguía el clip
## del primero). DOWNED, REVIVE y EXECUTE llevan 0.
## [br][br]
## El contador es de quien publica ([ActionWire] es una instancia por entidad): sube en 1 (módulo 4)
## cada vez que empieza una esquiva, un tambaleo, un aturdimiento o un cambio de arma, es decir, cada
## vez que cambia el par (acción, tick de inicio). Derivarlo del tick de inicio no bastaría: dos
## tambaleos separados un múltiplo de 4 ticks darían el mismo valor. Solo el servidor lo calcula; no
## forma parte de [PlayerState] ni se compara con la predicción.

const COUNTER_SHIFT: int = 6
const COUNTER_MASK: int = 3

var _action: int = -1
var _action_tick: int = -1
var _counter: int = 0


## true si [param action] lleva el contador de reinicio en los bits 6-7: las acciones sin combo ni
## fases que pueden encadenarse consigo mismas sin pasar por NONE (esquiva, tambaleo, aturdimiento y
## cambio de arma).
static func has_counter(action: int) -> bool:
	return action == CombatState.Action.DODGE or action == CombatState.Action.STAGGER \
			or action == CombatState.Action.STUN or action == CombatState.Action.SWAP


## Los bits 6-7 del byte [param action_byte]: el paso del combo si la acción es un ligero, la ranura
## (3 = consumible) si es una habilidad y el contador de reinicio si es una esquiva, un tambaleo, un
## aturdimiento o un cambio de arma (en las demás valen 0).
## Un cambio de este valor con la misma acción y fase es una acción nueva.
static func step_of(action_byte: int) -> int:
	return (action_byte >> COUNTER_SHIFT) & COUNTER_MASK


## El byte de acción de [param state] en el tick [param tick] para el registro de red. Hay que
## llamarlo una vez por tick de quien publica (el contador se alimenta de los cambios de acción).
func encode(state: CombatState, tick: int) -> int:
	var byte: int = ActionMachine.action_byte(state, tick)
	if not has_counter(state.action):
		return byte
	if state.action != _action or state.action_tick != _action_tick:
		_action = state.action
		_action_tick = state.action_tick
		_counter = (_counter + 1) & COUNTER_MASK
	return byte | (_counter << COUNTER_SHIFT)
