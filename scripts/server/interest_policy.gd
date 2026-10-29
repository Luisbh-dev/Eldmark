class_name InterestPolicy
extends RefCounted
## Gancho de la gestión de interés (docs/red.md, sección 11): qué entidades ve cada jugador y
## cuánta prisa hay por enviárselas.
## [br][br]
## La base lo considera todo relevante y con peso 1: en la fase 2 el presupuesto de 1200 B y el
## acumulador de prioridad del [SnapshotBuilder] ya bastan para que 64 jugadores visibles no
## rompan el tope. Eldrun sustituirá esta clase por una rejilla con histéresis
## ([code]GridInterestPolicy[/code]) sin tocar a quien la usa.


## true si [param observer] debe tener a [param entity] por relevante.
## [param was_relevant] dice si ya lo era (para dar histéresis). Las entidades con
## [constant NetEntity.FLAG_ALWAYS_RELEVANT] no pasan por aquí.
func is_relevant(_observer: NetEntity, _entity: NetEntity, _was_relevant: bool) -> bool:
	return true


## Peso que suma al acumulador de prioridad de [param entity] en cada snapshot de
## [param observer]: cuanto mayor, antes se envía cuando no caben todas.
func priority_weight(_observer: NetEntity, _entity: NetEntity) -> float:
	return 1.0
