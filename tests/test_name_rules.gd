extends TestCase
## Tests for the character name rules ([NameRules], SOC-01): valid and
## invalid names with their reason, texts, reserved names, comparison key (collisions by accents and
## capitals) and default name. The cases in [code]tests/fixtures/names/[/code] are also read by
## the Go platform ([code]internal/names[/code], docs/platform.md §4.4): the two implementations
## must give the same result.

const OK: int = NameRules.Reason.OK
## Cases shared with Go: [code][{name, reason, key}][/code], with the reason in its API code.
const SHARED_CASES_PATH: String = "res://tests/fixtures/names/name_rules_cases.json"


func test_valid_names() -> void:
	var names: Array[String] = [
		"Ana", "Bruno", "Álvaro", "Ñandú", "Úrsula", "Güenda", "Ibáñez", "McDuff", "ANA",
		"Jugadorabcd", "Éowyn", "Abcdefghijklmnop", "Ñññ", "Üdo",
	]
	for display_name: String in names:
		assert_eq(NameRules.validate(display_name), OK, "'%s' is valid" % display_name)
		assert_true(NameRules.is_valid(display_name), "is_valid('%s')" % display_name)


func test_length_limits() -> void:
	assert_eq(NameRules.MIN_LENGTH, 3, "minimum of 3 letters")
	assert_eq(NameRules.MAX_LENGTH, 16, "maximum of 16 letters")
	assert_eq(NameRules.validate(""), NameRules.Reason.TOO_SHORT, "empty")
	assert_eq(NameRules.validate("A"), NameRules.Reason.TOO_SHORT, "one letter")
	assert_eq(NameRules.validate("Al"), NameRules.Reason.TOO_SHORT, "two letters")
	assert_eq(NameRules.validate("Alá"), OK, "three letters (the accent counts as one)")
	assert_eq(NameRules.validate("A" + "b".repeat(15)), OK, "16 letters")
	assert_eq(NameRules.validate("A" + "b".repeat(16)), NameRules.Reason.TOO_LONG, "17 letters")
	assert_eq(NameRules.validate("Ñ" + "ñ".repeat(15)), OK, "16 letters of 2 bytes")
	assert_eq(NameRules.validate("A" + "b".repeat(100)), NameRules.Reason.TOO_LONG, "too long")


func test_only_latin_letters() -> void:
	var cases: Array[Dictionary] = [
		{"name": "Ana Maria", "reason": NameRules.Reason.HAS_SPACE},
		{"name": " Ana", "reason": NameRules.Reason.HAS_SPACE},
		{"name": "Ana ", "reason": NameRules.Reason.HAS_SPACE},
		{"name": "Ana1", "reason": NameRules.Reason.HAS_DIGIT},
		{"name": "Ana007", "reason": NameRules.Reason.HAS_DIGIT},
		{"name": "123", "reason": NameRules.Reason.HAS_DIGIT},
		# The first character that fails decides the reason: here the hyphen comes before the digits.
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


func test_invisible_and_combining_code_points_never_fit_in_a_name() -> void:
	# Names are a closed list of letters: nothing that the chat sanitising removes (invisible characters,
	# direction marks, fillers, combining marks; see test_chat_text) can sneak into one, neither to
	# impersonate another ("Ana" with a zero-width character) nor to write the accent separately.
	var codes: Array[int] = [0x00A0, 0x00AD, 0x0301, 0x0303, 0x0308, 0x034F, 0x0378, 0x061C, 0x115F, 0x200B,
			0x200D, 0x200E, 0x202E, 0x2066, 0x2800, 0x3164, 0xE000, 0xE0041, 0xFE0F, 0xFEFF, 0xFFA0]
	for code: int in codes:
		var display_name: String = "An" + String.chr(code) + "a"
		assert_eq(NameRules.validate(display_name), NameRules.Reason.INVALID_CHARACTER,
				"\"Ana\" with U+%04X is not a name" % code)


func test_initial_capital() -> void:
	for display_name: String in ["ana", "bruno", "álvaro", "ñandú", "úrsula", "aNA", "zOE"]:
		assert_eq(NameRules.validate(display_name), NameRules.Reason.NOT_CAPITALIZED,
				"'%s' starts with a lowercase letter" % display_name)
	# What comes after the initial is accepted as is.
	for display_name: String in ["AnA", "ANA", "AnaBruno", "ÁLVARO", "ÑANDÚ"]:
		assert_eq(NameRules.validate(display_name), OK, "'%s' is valid" % display_name)
	# The capital is checked before the reserved names.
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
				"'%s' is reserved" % display_name)
		assert_true(NameRules.is_reserved(display_name), "is_reserved('%s')" % display_name)
	# No name on the list, written as is, is valid: it is either reserved or fails another rule first.
	for display_name: String in NameRules.RESERVED:
		assert_true(NameRules.is_reserved(display_name), "'%s' from the list is recognised" % display_name)
		assert_false(NameRules.is_valid(display_name), "'%s' from the list is not valid" % display_name)
	assert_eq(NameRules.validate("GM"), NameRules.Reason.TOO_SHORT, "GM no longer fits by length")
	# Reserved names are whole names: a name that merely contains them is valid.
	assert_eq(NameRules.validate("Adminio"), OK, "Adminio")
	assert_eq(NameRules.validate("Eldara"), OK, "Eldara")
	assert_false(NameRules.is_reserved("Ana"), "Ana is not reserved")


func test_reason_texts() -> void:
	var seen: Dictionary = {}
	for reason: int in NameRules.Reason.values():
		var text: String = NameRules.reason_text(reason)
		assert_false(text.is_empty(), "text of reason %d" % reason)
		assert_false(seen.has(text), "reason %d has its own text" % reason)
		seen[text] = true
	assert_false(NameRules.reason_text(99).is_empty(), "an unknown reason also has a text")
	assert_true(NameRules.reason_text(NameRules.Reason.TOO_SHORT).contains("3"), "it states the minimum")
	assert_true(NameRules.reason_text(NameRules.Reason.TOO_LONG).contains("16"), "it states the maximum")
	assert_true(NameRules.rules_summary().contains("3") and NameRules.rules_summary().contains("16"),
			"the summary states the length")


func test_normalize_key() -> void:
	assert_eq(NameRules.normalize_key("Ana"), "ana", "lowercase")
	assert_eq(NameRules.normalize_key("ANA"), "ana", "uppercase")
	assert_eq(NameRules.normalize_key("Álvaro"), "alvaro", "accent")
	assert_eq(NameRules.normalize_key("ÁLVARO"), "alvaro", "accent in uppercase")
	assert_eq(NameRules.normalize_key("Éowyn"), "eowyn", "É")
	assert_eq(NameRules.normalize_key("Íñigo"), "inigo", "Í and ñ")
	assert_eq(NameRules.normalize_key("Óscar"), "oscar", "Ó")
	assert_eq(NameRules.normalize_key("Úrsula"), "ursula", "Ú")
	assert_eq(NameRules.normalize_key("Güenda"), "guenda", "diaeresis")
	assert_eq(NameRules.normalize_key("Peña"), "pena", "the eñe folds to n")
	assert_eq(NameRules.normalize_key("ÑANDÚ"), "nandu", "Ñ and Ú")
	assert_eq(NameRules.normalize_key(""), "", "empty")
	# With garbage it does not fail: it lowercases what it can.
	assert_eq(NameRules.normalize_key("Ana-1 Bo"), "ana-1 bo", "text that is not a name")


func test_collisions_by_accent_and_case() -> void:
	var same: Array[String] = ["Álvaro", "ALVARO", "alvaro", "Alvaro", "ÁLVARO", "aLvArO"]
	var key: String = NameRules.normalize_key(same[0])
	for display_name: String in same:
		assert_eq(NameRules.normalize_key(display_name), key, "'%s' collides with Álvaro" % display_name)
	assert_eq(NameRules.normalize_key("Peña"), NameRules.normalize_key("Pena"), "Peña and Pena")
	assert_eq(NameRules.normalize_key("Güenda"), NameRules.normalize_key("Guenda"), "Güenda")
	var different: Array[String] = ["Ana", "Anna", "Alvara", "Álvar", "Bruno"]
	var keys: Dictionary = {}
	for display_name: String in different:
		var other: String = NameRules.normalize_key(display_name)
		assert_false(keys.has(other), "'%s' does not collide with the others" % display_name)
		keys[other] = true
	assert_false(NameRules.normalize_key("Álvaro") == NameRules.normalize_key("Alvara"),
			"another letter")


func test_default_name() -> void:
	assert_eq(NameRules.default_name(0), "Jugadoraaaa", "seed 0")
	assert_eq(NameRules.default_name(1), "Jugadoraaab", "seed 1")
	assert_eq(NameRules.default_name(25), "Jugadoraaaz", "seed 25")
	assert_eq(NameRules.default_name(26), "Jugadoraaba", "seed 26")
	assert_eq(NameRules.default_name(456975), "Jugadorzzzz", "the last one")
	assert_eq(NameRules.default_name(456976), "Jugadoraaaa", "and it starts over")
	assert_eq(NameRules.default_name(-1), "Jugadorzzzz", "a negative seed is valid too")
	var seen: Dictionary = {}
	for seed_value: int in [0, 1, 7, 42, 9999, 123456, 456975, 4294967296, -5, 9223372036854775807]:
		var display_name: String = NameRules.default_name(seed_value)
		assert_eq(NameRules.validate(display_name), OK, "'%s' is a valid name" % display_name)
		assert_true(display_name.length() <= NetProtocol.MAX_NAME_CHARS, "fits in the HELLO")
		assert_eq(NameRules.default_name(seed_value), display_name, "it is deterministic")
	for seed_value: int in 10000:
		var display_name: String = NameRules.default_name(seed_value)
		assert_false(seen.has(display_name), "different seeds, different names (%d)" % seed_value)
		seen[display_name] = true


func test_shared_cases_with_the_platform() -> void:
	var json: JSON = JSON.new()
	assert_eq(json.parse(FileAccess.get_file_as_string(SHARED_CASES_PATH)), OK, "the cases are valid JSON")
	var cases: Array = json.data
	assert_true(cases.size() >= 100, "there are cases of every reason (%d)" % cases.size())
	var reasons_seen: Dictionary = {}
	var names_seen: Dictionary = {}
	for case: Dictionary in cases:
		var display_name: String = case["name"]
		var label: String = "'%s'" % display_name.c_escape()
		assert_false(names_seen.has(display_name), "%s is not repeated" % label)
		names_seen[display_name] = true
		assert_eq(NameRules.reason_code(NameRules.validate(display_name)), case["reason"], "reason of %s" % label)
		assert_eq(NameRules.normalize_key(display_name), case["key"], "key of %s" % label)
		reasons_seen[case["reason"]] = true
	for reason: int in NameRules.Reason.values():
		if reason != NameRules.Reason.TAKEN:
			assert_true(reasons_seen.has(NameRules.reason_code(reason)),
					"there are cases of %s" % NameRules.reason_code(reason))


func test_reason_codes() -> void:
	var seen: Dictionary = {}
	for reason: int in NameRules.Reason.values():
		var code: String = NameRules.reason_code(reason)
		assert_false(code.is_empty(), "reason %d has a code" % reason)
		assert_false(seen.has(code), "code %s is unique" % code)
		seen[code] = true
		assert_eq(NameRules.reason_from_code(code), reason, "round trip of %s" % code)
	assert_eq(NameRules.reason_code(NameRules.Reason.TOO_SHORT), "too_short", "too_short")
	assert_eq(NameRules.reason_code(NameRules.Reason.INVALID_CHARACTER), "invalid_character", "invalid_character")
	assert_eq(NameRules.reason_code(99), "", "an unknown reason has no code")
	assert_eq(NameRules.reason_from_code("no_existe"), -1, "an unknown code")
