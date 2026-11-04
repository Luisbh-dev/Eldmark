class_name CombatSource
extends RefCounted
## Source of a hit, a death or an effect (docs/habilidades.md, section 5.4): a u16 with the kind
## in bits 14-15 and the id in bits 0-13. It is what travels in the [code]attack_id[/code] field of
## HIT, DEATH, KILL and TELEGRAPH.
## [codeblock]
## 0x0000          none (the environment)
## 0x0000 | id     attack (those from phase 3 keep their number)
## 0x4000 | id     ability
## 0x8000 | id     status effect (a pulse)
## 0xC000 | 1      execute
## 0xC000 | 2      bleed out
## [/codeblock]

## Kind of the source (bits 14-15).
enum Kind { ATTACK, ABILITY, STATUS, SPECIAL }

## No source (the environment).
const NONE: int = 0
## Execute of a knocked down character.
const EXECUTE: int = 0xC001
## A knocked down character bleeding out.
const BLEED_OUT: int = 0xC002
## Id bits and kind shift.
const ID_MASK: int = 0x3FFF
const KIND_SHIFT: int = 14
## Maximum id of each kind (14 bits).
const MAX_ID: int = ID_MASK


## The source of kind [param kind] ([enum Kind]) and id [param id] (extra bits are discarded).
static func make(kind: int, id: int) -> int:
	return ((kind & 3) << KIND_SHIFT) | (id & ID_MASK)


## The kind ([enum Kind]) of [param source].
static func kind_of(source: int) -> int:
	return (source >> KIND_SHIFT) & 3


## The id of [param source] within its kind.
static func id_of(source: int) -> int:
	return source & ID_MASK


## Readable name of [param source] for logs: that of the catalog's attack, ability or effect,
## [code]remate[/code] (execute), [code]desangrado[/code] (bled out) or [code]entorno[/code] (environment); an id that does not exist
## gives [code]?<number>[/code].
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
