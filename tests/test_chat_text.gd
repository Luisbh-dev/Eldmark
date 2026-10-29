extends TestCase
## Pruebas del saneado del texto del chat ([ChatText], docs/social.md sección 5): caracteres de control,
## BBCode, espacios y límite de longitud.


func test_plain_text_is_unchanged() -> void:
	assert_eq(ChatText.sanitize("Hola, mundo"), "Hola, mundo", "texto normal")
	assert_eq(ChatText.sanitize("¿Qué tal, Peña? ¡Ñandú!"), "¿Qué tal, Peña? ¡Ñandú!", "tildes y signos")
	assert_eq(ChatText.sanitize("😀 ⚔ 日本語"), "😀 ⚔ 日本語", "emoji y otras escrituras")
	assert_eq(ChatText.check("Hola"), ChatText.Problem.OK, "un texto normal vale")


func test_control_characters_are_removed() -> void:
	# Un String no puede llevar el byte nulo, así que se prueban los demás controles por su código.
	assert_eq(ChatText.sanitize("a" + _chr(0x07) + "b" + _chr(0x1B) + "c"), "abc", "campana y escape")
	assert_eq(ChatText.sanitize("a" + _chr(0x7F) + "b"), "ab", "DEL")
	assert_eq(ChatText.sanitize("a" + _chr(0x85) + "b" + _chr(0x9F) + "c"), "abc", "controles C1")
	var invisible: Array[int] = [0x200B, 0x200E, 0x202E, 0x2066, 0xFEFF]
	var text: String = ""
	for code: int in invisible:
		text += "x" + _chr(code)
	assert_eq(ChatText.sanitize(text), "x".repeat(invisible.size()),
			"anchura cero, marcas de dirección y marca de orden de bytes")
	assert_eq(ChatText.sanitize("a" + _chr(0x2028) + "b" + _chr(0x2029) + "c"), "abc",
			"separadores de línea y de párrafo")
	assert_eq(ChatText.sanitize(_chr(0x01) + _chr(0x02) + _chr(0x03)), "", "solo controles queda vacío")
	for code: int in range(0x01, 0x20):
		if ChatText.is_space(code):
			continue
		assert_true(ChatText.is_stripped_control(code), "el control 0x%02X se quita" % code)


func test_line_breaks_and_tabs_become_a_space() -> void:
	assert_eq(ChatText.sanitize("hola\nmundo"), "hola mundo", "salto de línea")
	assert_eq(ChatText.sanitize("hola\r\nmundo"), "hola mundo", "retorno y salto")
	assert_eq(ChatText.sanitize("hola\tmundo"), "hola mundo", "tabulador")


func test_bbcode_is_removed() -> void:
	assert_eq(ChatText.sanitize("[b]hola[/b]"), "hola", "negrita")
	assert_eq(ChatText.sanitize("[color=red]rojo[/color] normal"), "rojo normal", "color")
	assert_eq(ChatText.sanitize("[url=http://x.y]enlace[/url]"), "enlace", "enlace")
	assert_eq(ChatText.sanitize("[img]res://icon.svg[/img]"), "res://icon.svg",
			"se quitan las etiquetas, no lo que encierran")
	assert_eq(ChatText.sanitize("[[b]b]x"), "x", "un par anidado no reaparece al quitar el de dentro")
	assert_eq(ChatText.sanitize("[[[b]]]x"), "x", "varios niveles")
	assert_eq(ChatText.sanitize("a [ b"), "a b", "un corchete que abre sin cerrar")
	assert_eq(ChatText.sanitize("a ] b"), "a b", "un corchete que cierra sin abrir")
	assert_eq(ChatText.sanitize("[]"), "", "corchetes vacíos")
	assert_eq(ChatText.sanitize("[lb]b[rb]"), "b", "ni siquiera las secuencias de escape")
	for text: String in ["[b]x", "x[/b]", "[[b]b]", "[[[", "]]]", "a[b]c[d]e", "[a[b]c]d"]:
		var cleaned: String = ChatText.sanitize(text)
		assert_false(cleaned.contains("[") or cleaned.contains("]"), "sin corchetes: «%s»" % text)


func test_spaces_are_collapsed_and_trimmed() -> void:
	assert_eq(ChatText.sanitize("  hola  "), "hola", "espacios de los extremos")
	assert_eq(ChatText.sanitize("a    b"), "a b", "espacios repetidos")
	assert_eq(ChatText.sanitize("a  b"), "a b", "espacios sin ruptura")
	assert_eq(ChatText.sanitize("a" + _chr(0x3000) + "b"), "a b", "espacio ideográfico")
	assert_eq(ChatText.sanitize("  hola  "), "hola", "espacios Unicode en los extremos")
	assert_eq(ChatText.sanitize("a [b] b"), "a b", "el hueco que deja el BBCode también se junta")
	assert_eq(ChatText.sanitize("   "), "", "solo espacios queda vacío")


func test_empty_and_too_long_are_rejected() -> void:
	assert_eq(ChatText.check(""), ChatText.Problem.EMPTY, "vacío")
	assert_eq(ChatText.check("   "), ChatText.Problem.EMPTY, "solo espacios")
	assert_eq(ChatText.check("[b][/b]"), ChatText.Problem.EMPTY, "solo BBCode")
	assert_eq(ChatText.sanitize(""), "", "sanear vacío da vacío")
	var limit: String = "a".repeat(ChatText.MAX_CHARS)
	assert_eq(ChatText.check(limit), ChatText.Problem.OK, "255 caracteres valen")
	assert_eq(ChatText.sanitize(limit), limit, "y se conservan")
	assert_eq(ChatText.check(limit + "a"), ChatText.Problem.TOO_LONG, "256 caracteres no")
	assert_eq(ChatText.sanitize(limit + "a"), "", "y sanear los rechaza")
	# Lo que sobra son espacios o BBCode: tras sanear cabe.
	assert_eq(ChatText.check("  " + limit + "  "), ChatText.Problem.OK, "los espacios no cuentan")
	assert_eq(ChatText.check("[b]" + limit + "[/b]"), ChatText.Problem.OK, "el BBCode no cuenta")
	assert_false(ChatText.problem_text(ChatText.Problem.EMPTY).is_empty(), "hay texto para vacío")
	assert_false(ChatText.problem_text(ChatText.Problem.TOO_LONG).is_empty(), "y para largo")
	assert_eq(ChatText.problem_text(ChatText.Problem.OK), "", "y ninguno para OK")


func test_sanitizing_twice_changes_nothing() -> void:
	var samples: Array[String] = [
		"[b]hola[/b]  mundo\n", "a" + _chr(0x200B) + "b  c", "[[b]b] [", "  ¿Qué?  ", "x\ty\nz",
		"😀  😀",
	]
	for sample: String in samples:
		var once: String = ChatText.sanitize(sample)
		assert_eq(ChatText.sanitize(once), once, "idempotente: «%s»" % sample)


# Carácter con el código [param code] (así el archivo no lleva caracteres invisibles).
func _chr(code: int) -> String:
	return String.chr(code)
