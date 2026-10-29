extends TestCase
## Pruebas de las reglas de nombres de personaje ([NameRules], SOC-01): nombres válidos e
## inválidos con su motivo, textos, reservados, clave de comparación (colisiones por tildes y
## mayúsculas) y nombre por defecto.

const OK: int = NameRules.Reason.OK


func test_valid_names() -> void:
	var names: Array[String] = [
		"Ana", "Bruno", "Álvaro", "Ñandú", "Úrsula", "Güenda", "Ibáñez", "McDuff", "ANA",
		"Jugadorabcd", "Éowyn", "Abcdefghijklmnop", "Ñññ", "Üdo",
	]
	for display_name: String in names:
		assert_eq(NameRules.validate(display_name), OK, "'%s' es válido" % display_name)
		assert_true(NameRules.is_valid(display_name), "is_valid('%s')" % display_name)


func test_length_limits() -> void:
	assert_eq(NameRules.MIN_LENGTH, 3, "mínimo de 3 letras")
	assert_eq(NameRules.MAX_LENGTH, 16, "máximo de 16 letras")
	assert_eq(NameRules.validate(""), NameRules.Reason.TOO_SHORT, "vacío")
	assert_eq(NameRules.validate("A"), NameRules.Reason.TOO_SHORT, "una letra")
	assert_eq(NameRules.validate("Al"), NameRules.Reason.TOO_SHORT, "dos letras")
	assert_eq(NameRules.validate("Alá"), OK, "tres letras (la tilde cuenta como una)")
	assert_eq(NameRules.validate("A" + "b".repeat(15)), OK, "16 letras")
	assert_eq(NameRules.validate("A" + "b".repeat(16)), NameRules.Reason.TOO_LONG, "17 letras")
	assert_eq(NameRules.validate("Ñ" + "ñ".repeat(15)), OK, "16 letras de 2 bytes")
	assert_eq(NameRules.validate("A" + "b".repeat(100)), NameRules.Reason.TOO_LONG, "muy largo")


func test_only_latin_letters() -> void:
	var cases: Array[Dictionary] = [
		{"name": "Ana Maria", "reason": NameRules.Reason.HAS_SPACE},
		{"name": " Ana", "reason": NameRules.Reason.HAS_SPACE},
		{"name": "Ana ", "reason": NameRules.Reason.HAS_SPACE},
		{"name": "Ana1", "reason": NameRules.Reason.HAS_DIGIT},
		{"name": "Ana007", "reason": NameRules.Reason.HAS_DIGIT},
		{"name": "123", "reason": NameRules.Reason.HAS_DIGIT},
		# El primer carácter que falla decide el motivo: aquí el guion va antes que los dígitos.
		{"name": "Jugador-0001", "reason": NameRules.Reason.INVALID_CHARACTER},
		{"name": "Ana_Bo", "reason": NameRules.Reason.INVALID_CHARACTER},
		{"name": "Ana!", "reason": NameRules.Reason.INVALID_CHARACTER},
		{"name": "Ana\n", "reason": NameRules.Reason.INVALID_CHARACTER},
		{"name": "Ana\t", "reason": NameRules.Reason.INVALID_CHARACTER},
		{"name": "Ana" + char(127), "reason": NameRules.Reason.INVALID_CHARACTER},
		{"name": "Zoë", "reason": NameRules.Reason.INVALID_CHARACTER},
		{"name": "Çelia", "reason": NameRules.Reason.INVALID_CHARACTER},
		{"name": "Aná", "reason": NameRules.Reason.INVALID_CHARACTER},
		{"name": "Ана", "reason": NameRules.Reason.INVALID_CHARACTER},
		{"name": "Ｂｒｕｎｏ", "reason": NameRules.Reason.INVALID_CHARACTER},
		{"name": "太郎太", "reason": NameRules.Reason.INVALID_CHARACTER},
		{"name": "Ana€", "reason": NameRules.Reason.INVALID_CHARACTER},
		{"name": "Ana٣", "reason": NameRules.Reason.INVALID_CHARACTER},
	]
	for case: Dictionary in cases:
		assert_eq(NameRules.validate(case["name"]), case["reason"],
				"'%s'" % String(case["name"]).c_escape())


func test_initial_capital() -> void:
	for display_name: String in ["ana", "bruno", "álvaro", "ñandú", "úrsula", "aNA", "zOE"]:
		assert_eq(NameRules.validate(display_name), NameRules.Reason.NOT_CAPITALIZED,
				"'%s' empieza por minúscula" % display_name)
	# Lo que viene después de la inicial se acepta tal cual.
	for display_name: String in ["AnA", "ANA", "AnaBruno", "ÁLVARO", "ÑANDÚ"]:
		assert_eq(NameRules.validate(display_name), OK, "'%s' es válido" % display_name)
	# La mayúscula se mira antes que los reservados.
	assert_eq(NameRules.validate("admin"), NameRules.Reason.NOT_CAPITALIZED, "admin")


func test_reserved_names() -> void:
	var reserved: Array[String] = [
		"Admin", "ADMIN", "Administrador", "Moderador", "Sistema", "Servidor",
		"Vardheim", "Solmarch", "Askarra", "Eld", "Eldrun", "Huecos",
		"Aldcor", "Isenholm", "Valcorin", "Kassar", "Hondal", "Grimfell", "Velmont", "Sarnath",
		"Capitán", "Capitan", "CAPITÁN", "Guardia",
	]
	for display_name: String in reserved:
		assert_eq(NameRules.validate(display_name), NameRules.Reason.RESERVED,
				"'%s' está reservado" % display_name)
		assert_true(NameRules.is_reserved(display_name), "is_reserved('%s')" % display_name)
	# Ningún nombre de la lista, escrito tal cual, es válido: o es reservado o falla otra regla antes.
	for display_name: String in NameRules.RESERVED:
		assert_true(NameRules.is_reserved(display_name), "'%s' de la lista se reconoce" % display_name)
		assert_false(NameRules.is_valid(display_name), "'%s' de la lista no es válido" % display_name)
	assert_eq(NameRules.validate("GM"), NameRules.Reason.TOO_SHORT, "GM ya no cabe por longitud")
	# Los reservados son nombres enteros: un nombre que solo los contiene vale.
	assert_eq(NameRules.validate("Adminio"), OK, "Adminio")
	assert_eq(NameRules.validate("Eldara"), OK, "Eldara")
	assert_false(NameRules.is_reserved("Ana"), "Ana no está reservado")


func test_reason_texts() -> void:
	var seen: Dictionary = {}
	for reason: int in NameRules.Reason.values():
		var text: String = NameRules.reason_text(reason)
		assert_false(text.is_empty(), "texto del motivo %d" % reason)
		assert_false(seen.has(text), "el motivo %d tiene un texto propio" % reason)
		seen[text] = true
	assert_false(NameRules.reason_text(99).is_empty(), "un motivo desconocido también tiene texto")
	assert_true(NameRules.reason_text(NameRules.Reason.TOO_SHORT).contains("3"), "dice el mínimo")
	assert_true(NameRules.reason_text(NameRules.Reason.TOO_LONG).contains("16"), "dice el máximo")
	assert_true(NameRules.rules_summary().contains("3") and NameRules.rules_summary().contains("16"),
			"el resumen dice la longitud")


func test_normalize_key() -> void:
	assert_eq(NameRules.normalize_key("Ana"), "ana", "minúsculas")
	assert_eq(NameRules.normalize_key("ANA"), "ana", "mayúsculas")
	assert_eq(NameRules.normalize_key("Álvaro"), "alvaro", "tilde")
	assert_eq(NameRules.normalize_key("ÁLVARO"), "alvaro", "tilde en mayúscula")
	assert_eq(NameRules.normalize_key("Éowyn"), "eowyn", "É")
	assert_eq(NameRules.normalize_key("Íñigo"), "inigo", "Í y ñ")
	assert_eq(NameRules.normalize_key("Óscar"), "oscar", "Ó")
	assert_eq(NameRules.normalize_key("Úrsula"), "ursula", "Ú")
	assert_eq(NameRules.normalize_key("Güenda"), "guenda", "diéresis")
	assert_eq(NameRules.normalize_key("Peña"), "pena", "la eñe se pliega a n")
	assert_eq(NameRules.normalize_key("ÑANDÚ"), "nandu", "Ñ y Ú")
	assert_eq(NameRules.normalize_key(""), "", "vacío")
	# Con basura no falla: pasa a minúsculas lo que puede.
	assert_eq(NameRules.normalize_key("Ana-1 Bo"), "ana-1 bo", "texto que no es un nombre")


func test_collisions_by_accent_and_case() -> void:
	var same: Array[String] = ["Álvaro", "ALVARO", "alvaro", "Alvaro", "ÁLVARO", "aLvArO"]
	var key: String = NameRules.normalize_key(same[0])
	for display_name: String in same:
		assert_eq(NameRules.normalize_key(display_name), key, "'%s' choca con Álvaro" % display_name)
	assert_eq(NameRules.normalize_key("Peña"), NameRules.normalize_key("Pena"), "Peña y Pena")
	assert_eq(NameRules.normalize_key("Güenda"), NameRules.normalize_key("Guenda"), "Güenda")
	var different: Array[String] = ["Ana", "Anna", "Alvara", "Álvar", "Bruno"]
	var keys: Dictionary = {}
	for display_name: String in different:
		var other: String = NameRules.normalize_key(display_name)
		assert_false(keys.has(other), "'%s' no choca con los demás" % display_name)
		keys[other] = true
	assert_false(NameRules.normalize_key("Álvaro") == NameRules.normalize_key("Alvara"),
			"otra letra")


func test_default_name() -> void:
	assert_eq(NameRules.default_name(0), "Jugadoraaaa", "semilla 0")
	assert_eq(NameRules.default_name(1), "Jugadoraaab", "semilla 1")
	assert_eq(NameRules.default_name(25), "Jugadoraaaz", "semilla 25")
	assert_eq(NameRules.default_name(26), "Jugadoraaba", "semilla 26")
	assert_eq(NameRules.default_name(456975), "Jugadorzzzz", "la última")
	assert_eq(NameRules.default_name(456976), "Jugadoraaaa", "y vuelve a empezar")
	assert_eq(NameRules.default_name(-1), "Jugadorzzzz", "una semilla negativa también vale")
	var seen: Dictionary = {}
	for seed_value: int in [0, 1, 7, 42, 9999, 123456, 456975, 4294967296, -5, 9223372036854775807]:
		var display_name: String = NameRules.default_name(seed_value)
		assert_eq(NameRules.validate(display_name), OK, "'%s' es un nombre válido" % display_name)
		assert_true(display_name.length() <= NetProtocol.MAX_NAME_CHARS, "cabe en el HELLO")
		assert_eq(NameRules.default_name(seed_value), display_name, "es determinista")
	for seed_value: int in 10000:
		var display_name: String = NameRules.default_name(seed_value)
		assert_false(seen.has(display_name), "semillas distintas, nombres distintos (%d)" % seed_value)
		seen[display_name] = true

