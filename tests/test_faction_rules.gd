extends TestCase
## Tests for [FactionRules] (who can damage whom) and [method Zones.get_pvp_mode]:
## the full matrix of the four sides (0 the neutral Hollow; 1, 2 and 3 the realms) in an
## RVR zone and in a safe zone, invalid codes and the PvP mode of each registered zone.

const HUECOS: int = RealmCatalog.NEUTRAL_CODE
const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ASKARRA: int = NetProtocol.Realm.ASKARRA
## Zone that is not registered: SAFE mode.
const SAFE_ZONE: StringName = &"zona_segura_de_prueba"

## Matrix in an RVR zone: row = attacker, column = victim, in the order Hollow, Vardheim,
## Solmarch, Askarra. Only the diagonal (no friendly fire) is false.
const RVR_MATRIX: Array = [
	[false, true, true, true],
	[true, false, true, true],
	[true, true, false, true],
	[true, true, true, false],
]
## Matrix in a safe zone: the realms do not damage each other, but the Hollow are still
## hostile to everyone.
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
					"side %d does not damage itself in %s" % [code, zone_id])


func test_huecos_are_hostile_to_every_realm_in_any_zone() -> void:
	for zone_id: StringName in [&"vado_gris", &"test_world", SAFE_ZONE]:
		for realm: int in RealmCatalog.realm_codes():
			assert_true(FactionRules.can_damage(HUECOS, realm, zone_id),
					"the Hollow damage realm %d in %s" % [realm, zone_id])
			assert_true(FactionRules.can_damage(realm, HUECOS, zone_id),
					"realm %d damages the Hollow in %s" % [realm, zone_id])


func test_enemy_realms_only_in_rvr_zones() -> void:
	for attacker: int in RealmCatalog.realm_codes():
		for victim: int in RealmCatalog.realm_codes():
			if attacker == victim:
				continue
			assert_true(FactionRules.can_damage(attacker, victim, &"vado_gris"),
					"%d damages %d in Vado Gris (RVR)" % [attacker, victim])
			assert_false(FactionRules.can_damage(attacker, victim, SAFE_ZONE),
					"%d does not damage %d in a safe zone" % [attacker, victim])


func test_invalid_codes_never_damage_or_get_damaged() -> void:
	for invalid: int in [-1, 4, 7, 255, 1000]:
		for zone_id: StringName in [&"vado_gris", SAFE_ZONE]:
			for code: int in [HUECOS, VARDHEIM, SOLMARCH, ASKARRA, invalid]:
				assert_false(FactionRules.can_damage(invalid, code, zone_id),
						"code %d does not damage %d in %s" % [invalid, code, zone_id])
				assert_false(FactionRules.can_damage(code, invalid, zone_id),
						"%d does not damage code %d in %s" % [code, invalid, zone_id])


func test_codes_come_from_realm_catalog() -> void:
	# The matrix speaks in network codes: they must be the catalog's.
	assert_eq(HUECOS, 0, "the Hollow are code 0")
	assert_eq(RealmCatalog.code_of(RealmCatalog.HUECOS), HUECOS, "catalog: Hollow")
	assert_eq(RealmCatalog.code_of(RealmCatalog.VARDHEIM), VARDHEIM, "catalog: Vardheim")
	assert_eq(RealmCatalog.code_of(RealmCatalog.SOLMARCH), SOLMARCH, "catalog: Solmarch")
	assert_eq(RealmCatalog.code_of(RealmCatalog.ASKARRA), ASKARRA, "catalog: Askarra")


# --- PvP mode of the zones --------------------------------------------------------------------

func test_pvp_mode_of_known_and_unknown_zones() -> void:
	assert_eq(Zones.get_pvp_mode(&"vado_gris"), Zones.PvpMode.RVR, "Vado Gris is RVR")
	assert_eq(Zones.get_pvp_mode(&"test_world"), Zones.PvpMode.RVR, "the test world is RVR")
	assert_eq(Zones.get_pvp_mode(SAFE_ZONE), Zones.PvpMode.SAFE, "an unknown zone is SAFE")
	assert_eq(Zones.get_pvp_mode(&""), Zones.PvpMode.SAFE, "an empty zone is SAFE")
	assert_eq(Zones.PvpMode.SAFE, 0, "SAFE is 0 in the enum")
	assert_eq(Zones.PvpMode.RVR, 1, "RVR is 1 in the enum")


func test_every_registered_zone_declares_its_pvp_mode() -> void:
	for zone_id: StringName in Zones.get_zone_ids():
		assert_true(Zones.PVP_MODES.has(zone_id),
				"zone %s must declare its PvP mode in Zones.PVP_MODES" % zone_id)
	for zone_id: StringName in Zones.PVP_MODES:
		assert_true(Zones.has_zone(zone_id),
				"Zones.PVP_MODES mentions a zone that does not exist: %s" % zone_id)


# --- Utilities --------------------------------------------------------------------------------

func _check_matrix(matrix: Array, zone_id: StringName) -> void:
	var codes: Array[int] = [HUECOS, VARDHEIM, SOLMARCH, ASKARRA]
	for row: int in codes.size():
		var expected_row: Array = matrix[row]
		for column: int in codes.size():
			assert_eq(FactionRules.can_damage(codes[row], codes[column], zone_id),
					expected_row[column] as bool,
					"%s: attacker %d against victim %d" % [zone_id, codes[row], codes[column]])
