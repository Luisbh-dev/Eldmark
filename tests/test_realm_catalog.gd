extends TestCase
## Pruebas del catálogo compartido de reinos y bandos ([RealmCatalog]): conversión id <-> código
## de red en los dos sentidos, nombres, colores, emblemas, reinos admitidos por zona y que
## [Zones], [NetZones], [NetProtocol], [ServerAuth] y los estandartes leen de él.

const BANNER_SCENES: Dictionary = {
	&"vardheim": "res://scenes/world/props/camp/vardheim_banner.tscn",
	&"solmarch": "res://scenes/world/props/camp/solmarch_banner.tscn",
	&"huecos": "res://scenes/world/props/fort/banner_pole.tscn",
}


func test_id_to_code_and_back() -> void:
	assert_eq(RealmCatalog.code_of(&"vardheim"), NetProtocol.Realm.VARDHEIM, "vardheim -> 1")
	assert_eq(RealmCatalog.code_of(&"solmarch"), NetProtocol.Realm.SOLMARCH, "solmarch -> 2")
	assert_eq(RealmCatalog.code_of(&"askarra"), NetProtocol.Realm.ASKARRA, "askarra -> 3")
	assert_eq(RealmCatalog.code_of(&"huecos"), 0, "los Huecos son el código 0 (neutral)")
	assert_eq(RealmCatalog.code_of(&"mordor"), -1, "un bando inventado no tiene código")
	assert_eq(RealmCatalog.code_of(&""), -1, "vacío tampoco")

	assert_eq(RealmCatalog.id_of_code(1), &"vardheim", "1 -> vardheim")
	assert_eq(RealmCatalog.id_of_code(2), &"solmarch", "2 -> solmarch")
	assert_eq(RealmCatalog.id_of_code(3), &"askarra", "3 -> askarra")
	assert_eq(RealmCatalog.id_of_code(0), &"huecos", "0 -> huecos")
	assert_eq(RealmCatalog.id_of_code(4), &"", "un código fuera de rango no tiene bando")
	assert_eq(RealmCatalog.id_of_code(-1), &"", "ni uno negativo")
	assert_eq(RealmCatalog.id_of_code(255), &"", "ni 255")


func test_round_trip_for_every_faction() -> void:
	for id: StringName in RealmCatalog.FACTION_IDS:
		var code: int = RealmCatalog.code_of(id)
		assert_eq(RealmCatalog.id_of_code(code), id, "id -> código -> id de %s" % id)
	for code: int in [0, 1, 2, 3]:
		var id: StringName = RealmCatalog.id_of_code(code)
		assert_eq(RealmCatalog.code_of(id), code, "código -> id -> código de %d" % code)
	# Los códigos no se repiten.
	var seen: Dictionary = {}
	for id: StringName in RealmCatalog.FACTION_IDS:
		var code: int = RealmCatalog.code_of(id)
		assert_false(seen.has(code), "el código %d no está repetido" % code)
		seen[code] = true


func test_network_codes_match_the_protocol() -> void:
	# El catálogo y NetProtocol.Realm tienen que decir lo mismo.
	assert_eq(RealmCatalog.code_of(RealmCatalog.VARDHEIM), NetProtocol.Realm.VARDHEIM, "Vardheim")
	assert_eq(RealmCatalog.code_of(RealmCatalog.SOLMARCH), NetProtocol.Realm.SOLMARCH, "Solmarch")
	assert_eq(RealmCatalog.code_of(RealmCatalog.ASKARRA), NetProtocol.Realm.ASKARRA, "Askarra")
	assert_eq(RealmCatalog.NEUTRAL_CODE, NetProtocol.Realm.NONE, "neutral = código 0")
	assert_eq(RealmCatalog.realm_codes(), [1, 2, 3] as Array[int], "códigos de los reinos")
	assert_true(RealmCatalog.is_realm_code(1) and RealmCatalog.is_realm_code(3), "1 y 3 son reinos")
	assert_false(RealmCatalog.is_realm_code(0), "el neutral no es un reino jugable")
	assert_false(RealmCatalog.is_realm_code(4), "4 no es nada")


func test_realm_and_faction_membership() -> void:
	assert_eq(RealmCatalog.REALM_IDS, [&"vardheim", &"solmarch", &"askarra"] as Array[StringName],
			"los tres reinos, en orden de código")
	assert_eq(RealmCatalog.FACTION_IDS.size(), 4, "tres reinos y los Huecos")
	for id: StringName in RealmCatalog.REALM_IDS:
		assert_true(RealmCatalog.is_realm(id), "%s es un reino" % id)
		assert_true(RealmCatalog.has_faction(id), "%s es un bando" % id)
	assert_false(RealmCatalog.is_realm(&"huecos"), "los Huecos no son un reino jugable")
	assert_true(RealmCatalog.has_faction(&"huecos"), "pero sí un bando")
	assert_false(RealmCatalog.has_faction(&"eldrun"), "Eldrun es una zona, no un bando")


func test_display_names() -> void:
	assert_eq(RealmCatalog.display_name(&"vardheim"), "Vardheim", "Vardheim")
	assert_eq(RealmCatalog.display_name(&"solmarch"), "Solmarch", "Solmarch")
	assert_eq(RealmCatalog.display_name(&"askarra"), "Askarra", "Askarra")
	assert_eq(RealmCatalog.display_name(&"huecos"), "Huecos", "Huecos")
	assert_eq(RealmCatalog.display_name(&"mordor"), "", "bando inventado")


func test_faction_colors() -> void:
	assert_eq(RealmCatalog.color_of(&"vardheim").to_html(false), "7ec8e8", "azul hielo")
	assert_eq(RealmCatalog.color_of(&"solmarch").to_html(false), "e9c341", "oro")
	assert_eq(RealmCatalog.color_of(&"askarra").to_html(false), "c3242f", "carmesí")
	assert_eq(RealmCatalog.color_of(&"huecos").to_html(false), "bdb6a6", "gris hueso")
	assert_eq(RealmCatalog.color_of(&"mordor"), Color.WHITE, "un bando inventado sale blanco")
	# Los cuatro colores se distinguen entre sí.
	for i: int in RealmCatalog.FACTION_IDS.size():
		for j: int in range(i + 1, RealmCatalog.FACTION_IDS.size()):
			assert_false(RealmCatalog.color_of(RealmCatalog.FACTION_IDS[i]).is_equal_approx(
					RealmCatalog.color_of(RealmCatalog.FACTION_IDS[j])),
					"%s y %s no comparten color" % [RealmCatalog.FACTION_IDS[i],
					RealmCatalog.FACTION_IDS[j]])


func test_emblem_paths() -> void:
	# El arte aporta los SVG más adelante: aquí solo se fija la ruta prevista.
	assert_eq(RealmCatalog.emblem_path(&"vardheim"), "res://assets/emblems/vardheim.svg",
			"emblema de Vardheim")
	assert_eq(RealmCatalog.emblem_path(&"solmarch"), "res://assets/emblems/solmarch.svg",
			"emblema de Solmarch")
	assert_eq(RealmCatalog.emblem_path(&"askarra"), "res://assets/emblems/askarra.svg",
			"emblema de Askarra")
	assert_eq(RealmCatalog.emblem_path(&"huecos"), "res://assets/emblems/huecos.svg",
			"emblema de los Huecos")
	assert_eq(RealmCatalog.emblem_path(&"mordor"), "", "bando inventado")


func test_allowed_realms_per_zone() -> void:
	assert_eq(RealmCatalog.allowed_realm_ids(&"vado_gris"),
			[&"vardheim", &"solmarch"] as Array[StringName], "el Vado Gris: Vardheim y Solmarch")
	assert_eq(RealmCatalog.allowed_realm_ids(&"test_world"),
			[&"vardheim", &"solmarch", &"askarra"] as Array[StringName], "test_world: todos")
	assert_true(RealmCatalog.allowed_realm_ids(&"atlantida").is_empty(),
			"una zona desconocida no tiene restricción registrada")
	# Toda zona registrada en Zones tiene sus reinos admitidos, y solo reinos jugables.
	for zone_id: StringName in Zones.get_zone_ids():
		var allowed: Array[StringName] = RealmCatalog.allowed_realm_ids(zone_id)
		assert_false(allowed.is_empty(), "%s tiene reinos admitidos" % zone_id)
		for id: StringName in allowed:
			assert_true(RealmCatalog.is_realm(id), "%s admite %s" % [zone_id, id])
	for zone_id: StringName in RealmCatalog.zones_with_realms():
		assert_true(Zones.has_zone(zone_id), "%s está registrada en Zones" % zone_id)


func test_net_zones_reads_from_the_catalog() -> void:
	assert_eq(NetZones.allowed_realms("vado_gris"), PackedInt32Array([1, 2]),
			"el Vado Gris admite Vardheim y Solmarch")
	assert_eq(NetZones.allowed_realms("test_world"), PackedInt32Array([1, 2, 3]),
			"test_world admite los tres")
	assert_true(NetZones.allowed_realms("atlantida").is_empty(), "zona desconocida: vacío = todos")
	for id: StringName in RealmCatalog.REALM_IDS:
		var code: int = RealmCatalog.code_of(id)
		assert_eq(NetZones.realm_from_name(String(id)), code, "realm_from_name(%s)" % id)
		assert_eq(NetZones.realm_name(code), id, "realm_name(%d)" % code)
		assert_eq(NetProtocol.realm_display_name(code), RealmCatalog.display_name(id),
				"nombre para mostrar de %s" % id)
	assert_eq(NetZones.realm_from_name("huecos"), NetProtocol.Realm.NONE,
			"los Huecos no se pueden elegir como reino")
	assert_eq(NetZones.realm_name(0), &"", "el código 0 no es un reino")
	assert_eq(NetProtocol.realm_display_name(0), "Ninguno", "el código 0 se muestra como Ninguno")
	assert_eq(NetProtocol.realm_display_name(7), "Ninguno", "y un código inválido también")


func test_zones_reads_the_realms_from_the_catalog() -> void:
	assert_eq(Zones.REALMS, RealmCatalog.REALM_IDS, "Zones.REALMS son los del catálogo")
	for id: StringName in RealmCatalog.FACTION_IDS:
		assert_eq(Zones.is_realm(id), RealmCatalog.is_realm(id), "Zones.is_realm(%s)" % id)
	assert_true(RealmCatalog.is_realm(Zones.DEFAULT_REALM), "el reino por defecto existe")


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
		assert_eq(auth.validate(hello, "203.0.113.7", 0, 0), expected[realm],
				"reino %d en el Vado Gris" % realm)


func test_banner_scenes_carry_the_catalog_colors() -> void:
	for id: StringName in BANNER_SCENES:
		var scene: PackedScene = load(BANNER_SCENES[id]) as PackedScene
		if not assert_not_null(scene, "se carga %s" % BANNER_SCENES[id]):
			continue
		var root: Node = scene.instantiate()
		var banner: MeshInstance3D = _find_banner(root)
		if assert_not_null(banner, "%s tiene un nodo Estandarte" % BANNER_SCENES[id]):
			var color: Color = banner.get("instance_shader_parameters/faction_color")
			assert_true(color.is_equal_approx(RealmCatalog.color_of(id)),
					"el estandarte de %s lleva el color del catálogo (%s, no %s)" % [
					id, RealmCatalog.color_of(id).to_html(false), color.to_html(false)])
		root.free()


func _find_banner(root: Node) -> MeshInstance3D:
	for child: Node in root.find_children("Estandarte*", "MeshInstance3D", true, false):
		return child as MeshInstance3D
	return null
