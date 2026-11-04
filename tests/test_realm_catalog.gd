extends TestCase
## Tests for the shared catalog of realms and sides ([RealmCatalog]): id <-> network code
## conversion in both directions, names, colors, emblems, realms admitted per zone, and that
## [Zones], [NetZones], [NetProtocol], [ServerAuth] and the banners read from it.

const BANNER_SCENES: Dictionary = {
	&"vardheim": "res://scenes/world/props/camp/vardheim_banner.tscn",
	&"solmarch": "res://scenes/world/props/camp/solmarch_banner.tscn",
	&"huecos": "res://scenes/world/props/fort/banner_pole.tscn",
}


func test_id_to_code_and_back() -> void:
	assert_eq(RealmCatalog.code_of(&"vardheim"), NetProtocol.Realm.VARDHEIM, "vardheim -> 1")
	assert_eq(RealmCatalog.code_of(&"solmarch"), NetProtocol.Realm.SOLMARCH, "solmarch -> 2")
	assert_eq(RealmCatalog.code_of(&"askarra"), NetProtocol.Realm.ASKARRA, "askarra -> 3")
	assert_eq(RealmCatalog.code_of(&"huecos"), 0, "the Hollow is code 0 (neutral)")
	assert_eq(RealmCatalog.code_of(&"mordor"), -1, "a made-up side has no code")
	assert_eq(RealmCatalog.code_of(&""), -1, "neither does an empty one")

	assert_eq(RealmCatalog.id_of_code(1), &"vardheim", "1 -> vardheim")
	assert_eq(RealmCatalog.id_of_code(2), &"solmarch", "2 -> solmarch")
	assert_eq(RealmCatalog.id_of_code(3), &"askarra", "3 -> askarra")
	assert_eq(RealmCatalog.id_of_code(0), &"huecos", "0 -> hollow")
	assert_eq(RealmCatalog.id_of_code(4), &"", "an out-of-range code has no side")
	assert_eq(RealmCatalog.id_of_code(-1), &"", "nor does a negative one")
	assert_eq(RealmCatalog.id_of_code(255), &"", "ni 255")


func test_round_trip_for_every_faction() -> void:
	for id: StringName in RealmCatalog.FACTION_IDS:
		var code: int = RealmCatalog.code_of(id)
		assert_eq(RealmCatalog.id_of_code(code), id, "id -> code -> id of %s" % id)
	for code: int in [0, 1, 2, 3]:
		var id: StringName = RealmCatalog.id_of_code(code)
		assert_eq(RealmCatalog.code_of(id), code, "code -> id -> code of %d" % code)
	# The codes are not repeated.
	var seen: Dictionary = {}
	for id: StringName in RealmCatalog.FACTION_IDS:
		var code: int = RealmCatalog.code_of(id)
		assert_false(seen.has(code), "code %d is not repeated" % code)
		seen[code] = true


func test_network_codes_match_the_protocol() -> void:
	# The catalog and NetProtocol.Realm have to say the same thing.
	assert_eq(RealmCatalog.code_of(RealmCatalog.VARDHEIM), NetProtocol.Realm.VARDHEIM, "Vardheim")
	assert_eq(RealmCatalog.code_of(RealmCatalog.SOLMARCH), NetProtocol.Realm.SOLMARCH, "Solmarch")
	assert_eq(RealmCatalog.code_of(RealmCatalog.ASKARRA), NetProtocol.Realm.ASKARRA, "Askarra")
	assert_eq(RealmCatalog.NEUTRAL_CODE, NetProtocol.Realm.NONE, "neutral = code 0")
	assert_eq(RealmCatalog.realm_codes(), [1, 2, 3] as Array[int], "realm codes")
	assert_true(RealmCatalog.is_realm_code(1) and RealmCatalog.is_realm_code(3), "1 and 3 are realms")
	assert_false(RealmCatalog.is_realm_code(0), "the neutral is not a playable realm")
	assert_false(RealmCatalog.is_realm_code(4), "4 is nothing")


func test_realm_and_faction_membership() -> void:
	assert_eq(RealmCatalog.REALM_IDS, [&"vardheim", &"solmarch", &"askarra"] as Array[StringName],
			"the three realms, in code order")
	assert_eq(RealmCatalog.FACTION_IDS.size(), 4, "three realms and the Hollow")
	for id: StringName in RealmCatalog.REALM_IDS:
		assert_true(RealmCatalog.is_realm(id), "%s is a realm" % id)
		assert_true(RealmCatalog.has_faction(id), "%s is a side" % id)
	assert_false(RealmCatalog.is_realm(&"huecos"), "the Hollow is not a playable realm")
	assert_true(RealmCatalog.has_faction(&"huecos"), "but it is a side")
	assert_false(RealmCatalog.has_faction(&"eldrun"), "Eldrun is a zone, not a side")


func test_display_names() -> void:
	assert_eq(RealmCatalog.display_name(&"vardheim"), "Vardheim", "Vardheim")
	assert_eq(RealmCatalog.display_name(&"solmarch"), "Solmarch", "Solmarch")
	assert_eq(RealmCatalog.display_name(&"askarra"), "Askarra", "Askarra")
	assert_eq(RealmCatalog.display_name(&"huecos"), "Huecos", "Hollow")
	assert_eq(RealmCatalog.display_name(&"mordor"), "", "made-up side")


func test_faction_colors() -> void:
	assert_eq(RealmCatalog.color_of(&"vardheim").to_html(false), "7ec8e8", "ice blue")
	assert_eq(RealmCatalog.color_of(&"solmarch").to_html(false), "e9c341", "gold")
	assert_eq(RealmCatalog.color_of(&"askarra").to_html(false), "c3242f", "crimson")
	assert_eq(RealmCatalog.color_of(&"huecos").to_html(false), "bdb6a6", "bone gray")
	assert_eq(RealmCatalog.color_of(&"mordor"), Color.WHITE, "a made-up side comes out white")
	# The four colors are distinguishable from each other.
	for i: int in RealmCatalog.FACTION_IDS.size():
		for j: int in range(i + 1, RealmCatalog.FACTION_IDS.size()):
			assert_false(RealmCatalog.color_of(RealmCatalog.FACTION_IDS[i]).is_equal_approx(
					RealmCatalog.color_of(RealmCatalog.FACTION_IDS[j])),
					"%s and %s do not share a color" % [RealmCatalog.FACTION_IDS[i],
					RealmCatalog.FACTION_IDS[j]])


func test_emblem_paths() -> void:
	# Art will supply the SVGs later: here only the planned path is fixed.
	assert_eq(RealmCatalog.emblem_path(&"vardheim"), "res://assets/emblems/vardheim.svg",
			"Vardheim's emblem")
	assert_eq(RealmCatalog.emblem_path(&"solmarch"), "res://assets/emblems/solmarch.svg",
			"Solmarch's emblem")
	assert_eq(RealmCatalog.emblem_path(&"askarra"), "res://assets/emblems/askarra.svg",
			"Askarra's emblem")
	assert_eq(RealmCatalog.emblem_path(&"huecos"), "res://assets/emblems/huecos.svg",
			"the Hollow's emblem")
	assert_eq(RealmCatalog.emblem_path(&"mordor"), "", "made-up side")


func test_allowed_realms_per_zone() -> void:
	assert_eq(RealmCatalog.allowed_realm_ids(&"vado_gris"),
			[&"vardheim", &"solmarch"] as Array[StringName], "Vado Gris: Vardheim and Solmarch")
	assert_eq(RealmCatalog.allowed_realm_ids(&"test_world"),
			[&"vardheim", &"solmarch", &"askarra"] as Array[StringName], "test_world: all")
	assert_true(RealmCatalog.allowed_realm_ids(&"atlantida").is_empty(),
			"an unknown zone has no registered restriction")
	# Every zone registered in Zones has its admitted realms, and only playable realms.
	for zone_id: StringName in Zones.get_zone_ids():
		var allowed: Array[StringName] = RealmCatalog.allowed_realm_ids(zone_id)
		assert_false(allowed.is_empty(), "%s has admitted realms" % zone_id)
		for id: StringName in allowed:
			assert_true(RealmCatalog.is_realm(id), "%s admits %s" % [zone_id, id])
	for zone_id: StringName in RealmCatalog.zones_with_realms():
		assert_true(Zones.has_zone(zone_id), "%s is registered in Zones" % zone_id)


func test_net_zones_reads_from_the_catalog() -> void:
	assert_eq(NetZones.allowed_realms("vado_gris"), PackedInt32Array([1, 2]),
			"Vado Gris admits Vardheim and Solmarch")
	assert_eq(NetZones.allowed_realms("test_world"), PackedInt32Array([1, 2, 3]),
			"test_world admits all three")
	assert_true(NetZones.allowed_realms("atlantida").is_empty(), "unknown zone: empty = all")
	for id: StringName in RealmCatalog.REALM_IDS:
		var code: int = RealmCatalog.code_of(id)
		assert_eq(NetZones.realm_from_name(String(id)), code, "realm_from_name(%s)" % id)
		assert_eq(NetZones.realm_name(code), id, "realm_name(%d)" % code)
		assert_eq(NetProtocol.realm_display_name(code), RealmCatalog.display_name(id),
				"display name of %s" % id)
	assert_eq(NetZones.realm_from_name("huecos"), NetProtocol.Realm.NONE,
			"the Hollow cannot be chosen as a realm")
	assert_eq(NetZones.realm_name(0), &"", "code 0 is not a realm")
	assert_eq(NetProtocol.realm_display_name(0), "Ninguno", "code 0 is shown as \"Ninguno\" (None)")
	assert_eq(NetProtocol.realm_display_name(7), "Ninguno", "and an invalid code too")


func test_zones_reads_the_realms_from_the_catalog() -> void:
	assert_eq(Zones.REALMS, RealmCatalog.REALM_IDS, "Zones.REALMS are the catalog's")
	for id: StringName in RealmCatalog.FACTION_IDS:
		assert_eq(Zones.is_realm(id), RealmCatalog.is_realm(id), "Zones.is_realm(%s)" % id)
	assert_true(RealmCatalog.is_realm(Zones.DEFAULT_REALM), "the default realm exists")


func test_server_auth_admits_only_the_realms_of_the_zone() -> void:
	var config := ServerConfig.new()
	var allowed: PackedInt32Array = NetZones.allowed_realms("vado_gris")
	var auth := ServerAuth.new(config, 0x1234, allowed, DevAuthProvider.new())
	var hello := NetMessages.Hello.new()
	hello.sim_hash = 0x1234
	hello.display_name = "Ana"
	var expected: Dictionary = {
		NetProtocol.Realm.NONE: NetProtocol.Result.REALM,
		NetProtocol.Realm.VARDHEIM: NetProtocol.Result.OK,
		NetProtocol.Realm.SOLMARCH: NetProtocol.Result.OK,
		NetProtocol.Realm.ASKARRA: NetProtocol.Result.REALM,
		4: NetProtocol.Result.REALM,
	}
	for realm: int in expected:
		hello.realm = realm
		assert_eq(auth.validate(1, hello, "203.0.113.7", 0, 0), expected[realm],
				"realm %d in Vado Gris" % realm)


func test_banner_scenes_carry_the_catalog_colors() -> void:
	for id: StringName in BANNER_SCENES:
		var scene: PackedScene = load(BANNER_SCENES[id]) as PackedScene
		if not assert_not_null(scene, "%s loads" % BANNER_SCENES[id]):
			continue
		var root: Node = scene.instantiate()
		var banner: MeshInstance3D = _find_banner(root)
		if assert_not_null(banner, "%s has a Estandarte (banner) node" % BANNER_SCENES[id]):
			var color: Color = banner.get("instance_shader_parameters/faction_color")
			assert_true(color.is_equal_approx(RealmCatalog.color_of(id)),
					"the banner of %s carries the catalog color (%s, not %s)" % [
					id, RealmCatalog.color_of(id).to_html(false), color.to_html(false)])
		root.free()


func _find_banner(root: Node) -> MeshInstance3D:
	for child: Node in root.find_children("Estandarte*", "MeshInstance3D", true, false):
		return child as MeshInstance3D
	return null
