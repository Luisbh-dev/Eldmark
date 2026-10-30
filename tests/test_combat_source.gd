extends TestCase
## Pruebas de [CombatSource] (docs/habilidades.md, sección 5.4): la fuente u16 de un golpe, una muerte
## o un efecto, con la clase en los bits 14-15 y el id en los bits 0-13.

const Kind = CombatSource.Kind


func test_layout_of_the_source() -> void:
	assert_eq(CombatSource.make(Kind.ATTACK, 0), CombatSource.NONE, "0 es ninguna (el entorno)")
	assert_eq(CombatSource.make(Kind.ATTACK, 12), 12, "los ataques conservan su número")
	assert_eq(CombatSource.make(Kind.ABILITY, 5), 0x4005, "habilidad: 0x4000 | id")
	assert_eq(CombatSource.make(Kind.STATUS, 3), 0x8003, "efecto: 0x8000 | id")
	assert_eq(CombatSource.EXECUTE, 0xC001, "remate")
	assert_eq(CombatSource.BLEED_OUT, 0xC002, "desangrado")
	assert_eq(CombatSource.make(Kind.SPECIAL, 1), CombatSource.EXECUTE, "remate = SPECIAL | 1")
	assert_eq(CombatSource.make(Kind.SPECIAL, 2), CombatSource.BLEED_OUT, "desangrado = SPECIAL | 2")


func test_roundtrip_of_kind_and_id() -> void:
	for kind: int in [Kind.ATTACK, Kind.ABILITY, Kind.STATUS, Kind.SPECIAL]:
		for id: int in [0, 1, 255, 0x3FFF]:
			var source: int = CombatSource.make(kind, id)
			assert_true(source >= 0 and source <= 0xFFFF, "cabe en u16")
			assert_eq(CombatSource.kind_of(source), kind, "clase de %d/%d" % [kind, id])
			assert_eq(CombatSource.id_of(source), id, "id de %d/%d" % [kind, id])
	# Un id de más de 14 bits no pisa la clase.
	assert_eq(CombatSource.kind_of(CombatSource.make(Kind.ATTACK, 0x7FFF)), Kind.ATTACK,
			"el id se recorta a 14 bits")
	assert_eq(CombatSource.MAX_ID, 0x3FFF, "14 bits de id")


func test_names_of_the_sources() -> void:
	var light: int = CombatCatalog.attack_id(&"sword_light_1")
	assert_eq(CombatSource.name_of(CombatSource.make(Kind.ATTACK, light)), "sword_light_1", "ataque")
	var bash: int = CombatCatalog.ability_id(&"shield_bash")
	assert_eq(CombatSource.name_of(CombatSource.make(Kind.ABILITY, bash)), "shield_bash", "habilidad")
	var bleed: int = CombatCatalog.status_id(&"bleed")
	assert_eq(CombatSource.name_of(CombatSource.make(Kind.STATUS, bleed)), "bleed", "efecto")
	assert_eq(CombatSource.name_of(CombatSource.EXECUTE), "remate", "remate")
	assert_eq(CombatSource.name_of(CombatSource.BLEED_OUT), "desangrado", "desangrado")
	assert_eq(CombatSource.name_of(CombatSource.NONE), "entorno", "sin fuente")
	assert_eq(CombatSource.name_of(CombatSource.make(Kind.ABILITY, 0x3FFF)), "?%d" % 0x7FFF,
			"un id que no existe")
	# El golpe sintetizado de una habilidad lleva su fuente.
	assert_eq(CombatSource.name_of(CombatCatalog.ability(bash).hit.id), "shield_bash",
			"la fuente del golpe sintetizado")
