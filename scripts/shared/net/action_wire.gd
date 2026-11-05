class_name ActionWire
extends RefCounted
## The action byte of the network record ([member EntityRecord.action]) as published by the
## server and read by the client (docs/combat.md, sections 3.4 and 6).
## [br][br]
## It starts from the byte of [method ActionMachine.action_byte] (bits 0-3 the action, 4-5 the phase, 6-7 the combo
## step of the light attack in progress or the ability slot: 0-2, or 3 if it is a consumable) and fills
## bits 6-7 of actions that chain into themselves with a [b]restart counter[/b].
## Without it, two identical consecutive actions would be indistinguishable to a remote: a dodge or
## weapon swap stored in the buffer comes out on the same tick the previous one ends (there is never a
## tick in NONE) and a second stagger or stun chains with the first; in both cases the
## byte is identical, the remote would not restart the clip and would play through the second action frozen in the
## last pose. An ability does not need it: between two uses of the same slot (or two consumables) there are
## always [constant AbilityTicks.REARM_TICKS] ticks of NONE, more than the snapshot interval: the
## catalog validation requires it of cooldowns, and an interruption before the commit or a
## channel that ends without committing (released at the end of its cast) leave that margin
## (docs/abilities.md, section 5.5; with a single tick, a remote that did not sample it kept following the clip
## of the first). DOWNED, REVIVE and EXECUTE carry 0.
## [br][br]
## The counter belongs to whoever publishes ([ActionWire] is one instance per entity): it goes up by 1 (modulo 4)
## each time a dodge, a stagger, a stun or a weapon swap starts, that is, each
## time the (action, start tick) pair changes. Deriving it from the start tick would not be enough: two
## staggers separated by a multiple of 4 ticks would give the same value. Only the server computes it; it is not
## part of [PlayerState] nor is it compared with prediction.

const COUNTER_SHIFT: int = 6
const COUNTER_MASK: int = 3

var _action: int = -1
var _action_tick: int = -1
var _counter: int = 0


## true if [param action] carries the restart counter in bits 6-7: actions with no combo or
## phases that can chain into themselves without passing through NONE (dodge, stagger, stun and
## weapon swap).
static func has_counter(action: int) -> bool:
	return action == CombatState.Action.DODGE or action == CombatState.Action.STAGGER \
			or action == CombatState.Action.STUN or action == CombatState.Action.SWAP


## Bits 6-7 of the byte [param action_byte]: the combo step if the action is a light attack, the slot
## (3 = consumable) if it is an ability and the restart counter if it is a dodge, a stagger, a
## stun or a weapon swap (in the others they are 0).
## A change in this value with the same action and phase is a new action.
static func step_of(action_byte: int) -> int:
	return (action_byte >> COUNTER_SHIFT) & COUNTER_MASK


## The action byte of [param state] at tick [param tick] for the network record. It must be
## called once per tick by whoever publishes (the counter is fed by action changes).
func encode(state: CombatState, tick: int) -> int:
	var byte: int = ActionMachine.action_byte(state, tick)
	if not has_counter(state.action):
		return byte
	if state.action != _action or state.action_tick != _action_tick:
		_action = state.action
		_action_tick = state.action_tick
		_counter = (_counter + 1) & COUNTER_MASK
	return byte | (_counter << COUNTER_SHIFT)
