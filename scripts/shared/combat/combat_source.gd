class_name CombatSource
extends RefCounted
## Fuente de un golpe, una muerte o un efecto (docs/habilidades.md, sección 5.4): un u16 con la clase
## en los bits 14-15 y el id en los bits 0-13. Es lo que viaja en el campo [code]attack_id[/code] de
## HIT, DEATH, KILL y TELEGRAPH.
## [codeblock]
## 0x0000          ninguna (el entorno)
## 0x0000 | id     ataque (los de la fase 3 conservan su número)
## 0x4000 | id     habilidad
## 0x8000 | id     efecto de estado (un pulso)
## 0xC000 | 1      remate
## 0xC000 | 2      desangrado
## [/codeblock]

## Clase de la fuente (bits 14-15).
enum Kind { ATTACK, ABILITY, STATUS, SPECIAL }

## Ninguna fuente (el entorno).
const NONE: int = 0
## Remate de un derribado.
const EXECUTE: int = 0xC001
## Un derribado que se desangra.
const BLEED_OUT: int = 0xC002
## Bits del id y desplazamiento de la clase.
const ID_MASK: int = 0x3FFF
const KIND_SHIFT: int = 14
## Id máximo de cada clase (14 bits).
const MAX_ID: int = ID_MASK


## La fuente de clase [param kind] ([enum Kind]) e id [param id] (los bits de más se descartan).
static func make(kind: int, id: int) -> int:
	return ((kind & 3) << KIND_SHIFT) | (id & ID_MASK)


## La clase ([enum Kind]) de [param source].
static func kind_of(source: int) -> int:
	return (source >> KIND_SHIFT) & 3


## El id de [param source] dentro de su clase.
static func id_of(source: int) -> int:
	return source & ID_MASK


## Nombre legible de [param source] para registros: el del ataque, la habilidad o el efecto del
## catálogo, [code]remate[/code], [code]desangrado[/code] o [code]entorno[/code]; un id que no existe
## da [code]?<número>[/code].
static func name_of(source: int) -> String:
	var id: int = id_of(source)
	match kind_of(source):
		Kind.ATTACK:
			if id == 0:
				return "entorno"
			var attack: AttackTicks = CombatCatalog.attack(id)
			if attack != null:
				return String(attack.name)
		Kind.ABILITY:
			var ability: AbilityTicks = CombatCatalog.ability(id)
			if ability != null:
				return String(ability.name)
		Kind.STATUS:
			var status: StatusTicks = CombatCatalog.status(id)
			if status != null:
				return String(status.name)
		Kind.SPECIAL:
			if source == EXECUTE:
				return "remate"
			if source == BLEED_OUT:
				return "desangrado"
	return "?%d" % source
