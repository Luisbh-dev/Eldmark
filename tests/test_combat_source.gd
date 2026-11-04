extends TestCase
## Tests for [CombatSource] (docs/abilities.md, section 5.4): the u16 source of a hit, a death
## or an effect, with the class in bits 14-15 and the id in bits 0-13.

const Kind = CombatSource.Kind


func test_layout_of_the_source() -> void:
	assert_eq(CombatSource.make(Kind.ATTACK, 0), CombatSource.NONE, "0 is none (the environment)")
	assert_eq(CombatSource.make(Kind.ATTACK, 12), 12, "attacks keep their number")
	assert_eq(CombatSource.make(Kind.ABILITY, 5), 0x4005, "ability: 0x4000 | id")
	assert_eq(CombatSource.make(Kind.STATUS, 3), 0x8003, "effect: 0x8000 | id")
	assert_eq(CombatSource.EXECUTE, 0xC001, "finishing blow")
	assert_eq(CombatSource.BLEED_OUT, 0xC002, "bleed out")
	assert_eq(CombatSource.make(Kind.SPECIAL, 1), CombatSource.EXECUTE, "finishing blow = SPECIAL | 1")
	assert_eq(CombatSource.make(Kind.SPECIAL, 2), CombatSource.BLEED_OUT, "bleed out = SPECIAL | 2")


func test_roundtrip_of_kind_and_id() -> void:
	for kind: int in [Kind.ATTACK, Kind.ABILITY, Kind.STATUS, Kind.SPECIAL]:
		for id: int in [0, 1, 255, 0x3FFF]:
			var source: int = CombatSource.make(kind, id)
			assert_true(source >= 0 and source <= 0xFFFF, "fits in u16")
			assert_eq(CombatSource.kind_of(source), kind, "class of %d/%d" % [kind, id])
			assert_eq(CombatSource.id_of(source), id, "id de %d/%d" % [kind, id])
	# An id of more than 14 bits does not overwrite the class.
	assert_eq(CombatSource.kind_of(CombatSource.make(Kind.ATTACK, 0x7FFF)), Kind.ATTACK,
			"the id is clamped to 14 bits")
	assert_eq(CombatSource.MAX_ID, 0x3FFF, "14 bits of id")


func test_names_of_the_sources() -> void:
	var light: int = CombatCatalog.attack_id(&"sword_light_1")
	assert_eq(CombatSource.name_of(CombatSource.make(Kind.ATTACK, light)), "sword_light_1", "attack")
	var bash: int = CombatCatalog.ability_id(&"shield_bash")
	assert_eq(CombatSource.name_of(CombatSource.make(Kind.ABILITY, bash)), "shield_bash", "ability")
	var bleed: int = CombatCatalog.status_id(&"bleed")
	assert_eq(CombatSource.name_of(CombatSource.make(Kind.STATUS, bleed)), "bleed", "effect")
	assert_eq(CombatSource.name_of(CombatSource.EXECUTE), "remate", "finishing blow")
	assert_eq(CombatSource.name_of(CombatSource.BLEED_OUT), "desangrado", "bleed out")
	assert_eq(CombatSource.name_of(CombatSource.NONE), "entorno", "no source")
	assert_eq(CombatSource.name_of(CombatSource.make(Kind.ABILITY, 0x3FFF)), "?%d" % 0x7FFF,
			"an id that does not exist")
	# The synthesized hit of an ability carries its source.
	assert_eq(CombatSource.name_of(CombatCatalog.ability(bash).hit.id), "shield_bash",
			"the source of the synthesized hit")
