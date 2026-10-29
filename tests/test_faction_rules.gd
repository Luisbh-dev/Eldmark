extends TestCase
## Pruebas de [FactionRules] (quién puede dañar a quién) y de [method Zones.get_pvp_mode]:
## la matriz completa de los cuatro bandos (0 los Huecos neutrales; 1, 2 y 3 los reinos) en una
## zona RVR y en una zona segura, los códigos inválidos y el modo PvP de cada zona registrada.

const HUECOS: int = RealmCatalog.NEUTRAL_CODE
const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ASKARRA: int = NetProtocol.Realm.ASKARRA
## Zona que no está registrada: modo SAFE.
const SAFE_ZONE: StringName = &"zona_segura_de_prueba"

## Matriz en una zona RVR: fila = atacante, columna = víctima, en el orden Huecos, Vardheim,
## Solmarch, Askarra. Solo la diagonal (sin fuego amigo) es falsa.
const RVR_MATRIX: Array = [
	[false, true, true, true],
	[true, false, true, true],
	[true, true, false, true],
	[true, true, true, false],
]
## Matriz en una zona segura: los reinos no se dañan entre sí, pero los Huecos siguen siendo
## hostiles a todos.
const SAFE_MATRIX: Array = [
	[false, true, true, true],
	[true, false, false, false],
	[true, false, false, false],
	[true, false, false, false],
]


func test_matrix_in_rvr_zone() -> void:
	for zone_id: StringName in [&"vado_gris", &"test_world"]:
		_check_matrix(RVR_MATRIX, zone_id)


func test_matrix_in_safe_zone() -> void:
	_check_matrix(SAFE_MATRIX, SAFE_ZONE)
	_check_matrix(SAFE_MATRIX, &"")


func test_no_friendly_fire() -> void:
	for zone_id: StringName in [&"vado_gris", &"test_world", SAFE_ZONE]:
		for code: int in [HUECOS, VARDHEIM, SOLMARCH, ASKARRA]:
			assert_false(FactionRules.can_damage(code, code, zone_id),
					"el bando %d no se daña a sí mismo en %s" % [code, zone_id])


func test_huecos_are_hostile_to_every_realm_in_any_zone() -> void:
	for zone_id: StringName in [&"vado_gris", &"test_world", SAFE_ZONE]:
		for realm: int in RealmCatalog.realm_codes():
			assert_true(FactionRules.can_damage(HUECOS, realm, zone_id),
					"los Huecos dañan al reino %d en %s" % [realm, zone_id])
			assert_true(FactionRules.can_damage(realm, HUECOS, zone_id),
					"el reino %d daña a los Huecos en %s" % [realm, zone_id])


func test_enemy_realms_only_in_rvr_zones() -> void:
	for attacker: int in RealmCatalog.realm_codes():
		for victim: int in RealmCatalog.realm_codes():
			if attacker == victim:
				continue
			assert_true(FactionRules.can_damage(attacker, victim, &"vado_gris"),
					"%d daña a %d en el Vado Gris (RVR)" % [attacker, victim])
			assert_false(FactionRules.can_damage(attacker, victim, SAFE_ZONE),
					"%d no daña a %d en una zona segura" % [attacker, victim])


func test_invalid_codes_never_damage_or_get_damaged() -> void:
	for invalid: int in [-1, 4, 7, 255, 1000]:
		for zone_id: StringName in [&"vado_gris", SAFE_ZONE]:
			for code: int in [HUECOS, VARDHEIM, SOLMARCH, ASKARRA, invalid]:
				assert_false(FactionRules.can_damage(invalid, code, zone_id),
						"el código %d no daña a %d en %s" % [invalid, code, zone_id])
				assert_false(FactionRules.can_damage(code, invalid, zone_id),
						"%d no daña al código %d en %s" % [code, invalid, zone_id])


func test_codes_come_from_realm_catalog() -> void:
	# La matriz habla en códigos de red: tienen que ser los del catálogo.
	assert_eq(HUECOS, 0, "los Huecos son el código 0")
	assert_eq(RealmCatalog.code_of(RealmCatalog.HUECOS), HUECOS, "catálogo: Huecos")
	assert_eq(RealmCatalog.code_of(RealmCatalog.VARDHEIM), VARDHEIM, "catálogo: Vardheim")
	assert_eq(RealmCatalog.code_of(RealmCatalog.SOLMARCH), SOLMARCH, "catálogo: Solmarch")
	assert_eq(RealmCatalog.code_of(RealmCatalog.ASKARRA), ASKARRA, "catálogo: Askarra")


# --- Modo PvP de las zonas --------------------------------------------------------------------

func test_pvp_mode_of_known_and_unknown_zones() -> void:
	assert_eq(Zones.get_pvp_mode(&"vado_gris"), Zones.PvpMode.RVR, "el Vado Gris es RVR")
	assert_eq(Zones.get_pvp_mode(&"test_world"), Zones.PvpMode.RVR, "el mundo de pruebas es RVR")
	assert_eq(Zones.get_pvp_mode(SAFE_ZONE), Zones.PvpMode.SAFE, "una zona desconocida es SAFE")
	assert_eq(Zones.get_pvp_mode(&""), Zones.PvpMode.SAFE, "una zona vacía es SAFE")
	assert_eq(Zones.PvpMode.SAFE, 0, "SAFE es el 0 del enum")
	assert_eq(Zones.PvpMode.RVR, 1, "RVR es el 1 del enum")


func test_every_registered_zone_declares_its_pvp_mode() -> void:
	for zone_id: StringName in Zones.get_zone_ids():
		assert_true(Zones.PVP_MODES.has(zone_id),
				"la zona %s tiene que declarar su modo PvP en Zones.PVP_MODES" % zone_id)
	for zone_id: StringName in Zones.PVP_MODES:
		assert_true(Zones.has_zone(zone_id),
				"Zones.PVP_MODES habla de una zona que no existe: %s" % zone_id)


# --- Utilidades -------------------------------------------------------------------------------

func _check_matrix(matrix: Array, zone_id: StringName) -> void:
	var codes: Array[int] = [HUECOS, VARDHEIM, SOLMARCH, ASKARRA]
	for row: int in codes.size():
		var expected_row: Array = matrix[row]
		for column: int in codes.size():
			assert_eq(FactionRules.can_damage(codes[row], codes[column], zone_id),
					expected_row[column] as bool,
					"%s: atacante %d contra víctima %d" % [zone_id, codes[row], codes[column]])
