extends TestCase
## Pruebas de las reglas exportadas para la plataforma ([ProgressionRulesExport];
## docs/progresion.md §13.4, docs/plataforma.md §4.4): [method ProgressionRulesExport.build] es
## determinista y el archivo del repositorio, el que incrusta la plataforma en Go, coincide con él.
## Es la única prueba del archivo: cada documento añade aquí las comprobaciones de sus secciones.


func test_build_is_deterministic() -> void:
	var first: String = JSON.stringify(ProgressionRulesExport.build(), "\t", true)
	var second: String = JSON.stringify(ProgressionRulesExport.build(), "\t", true)
	assert_eq(second, first, "dos llamadas a build() dan lo mismo")
	assert_eq(ProgressionRulesExport.to_json(), first + "\n", "to_json es build() con un salto final")


func test_file_matches_build() -> void:
	var path: String = ProgressionRulesExport.OUTPUT_PATH
	assert_true(FileAccess.file_exists(path), "existe %s" % path)
	var text: String = FileAccess.get_file_as_string(path)
	assert_true(text == ProgressionRulesExport.to_json(),
			"%s está al día (si no, ejecuta tools/progression/export_rules.gd y súbelo)" % path)


func test_file_is_valid_json_with_sorted_keys() -> void:
	var json: JSON = JSON.new()
	assert_eq(json.parse(FileAccess.get_file_as_string(ProgressionRulesExport.OUTPUT_PATH)), OK, "JSON válido")
	var data: Dictionary = json.data
	var keys: Array = data.keys()
	var sorted: Array = keys.duplicate()
	sorted.sort()
	assert_eq(keys, sorted, "claves ordenadas")
	assert_true(data.has("protocol_version") and data.has("names"), "secciones de plataforma.md")


func test_protocol_version_section() -> void:
	assert_eq(ProgressionRulesExport.build()["protocol_version"], NetProtocol.PROTOCOL_VERSION,
			"protocol_version es el de NetProtocol")


func test_names_section() -> void:
	var names: Dictionary = ProgressionRulesExport.build()["names"]
	var expected_keys: Array = ["folded", "lower_letters", "max_length", "min_length", "reserved", "upper_letters"]
	var keys: Array = names.keys()
	keys.sort()
	assert_eq(keys, expected_keys, "las claves de la sección names (plataforma.md §4.4)")
	assert_eq(names["min_length"], NameRules.MIN_LENGTH, "min_length")
	assert_eq(names["max_length"], NameRules.MAX_LENGTH, "max_length")
	assert_eq(names["upper_letters"], NameRules.UPPER_LETTERS, "upper_letters")
	assert_eq(names["lower_letters"], NameRules.LOWER_LETTERS, "lower_letters")
	assert_eq(String(names["upper_letters"]).length(), String(names["lower_letters"]).length(),
			"mayúsculas y minúsculas en el mismo orden")
	assert_eq(names["folded"], NameRules.FOLDED, "folded")
	assert_eq(Array(names["reserved"]), Array(NameRules.RESERVED), "reserved, como está escrito")
