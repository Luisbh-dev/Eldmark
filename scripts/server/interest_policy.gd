class_name InterestPolicy
extends RefCounted
## Interest management hook (docs/networking.md, section 11): which entities each player sees and
## how urgently they need to be sent.
## [br][br]
## The base considers everything relevant with weight 1: in phase 2 the 1200 B budget and the
## priority accumulator of the [SnapshotBuilder] are enough so that 64 visible players do not
## break the cap. Eldrun will replace this class with a grid with hysteresis
## ([code]GridInterestPolicy[/code]) without touching its users.


## true if [param observer] should consider [param entity] relevant.
## [param was_relevant] says whether it already was (to give hysteresis). Entities with
## [constant NetEntity.FLAG_ALWAYS_RELEVANT] do not go through here.
func is_relevant(_observer: NetEntity, _entity: NetEntity, _was_relevant: bool) -> bool:
	return true


## Weight added to [param entity]'s priority accumulator on each snapshot of
## [param observer]: the greater it is, the sooner it is sent when not all fit.
func priority_weight(_observer: NetEntity, _entity: NetEntity) -> float:
	return 1.0
