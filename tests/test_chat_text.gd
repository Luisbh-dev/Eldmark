extends TestCase
## Pruebas del saneado del texto del chat ([ChatText], docs/social.md secciones 5 y 12.2): caracteres de
## control e invisibles (con una tabla de puntos de código), marcas combinantes, BBCode, espacios y límite de
## longitud.

## Puntos de código que se quitan siempre: controles, formato invisible (Cf), separadores, ignorables por
## defecto, no caracteres, uso privado y sin asignar. [código, qué es].
const STRIPPED_CODES: Array = [
	[0x0007, "campana (C0)"], [0x001B, "escape (C0)"], [0x007F, "DEL"], [0x0085, "siguiente línea (C1)"],
	[0x009F, "C1"], [0x00AD, "guion blando"], [0x034F, "unidor de grafemas"],
	[0x0600, "signo numérico árabe (Cf)"], [0x061C, "marca de letra árabe (dirección)"],
	[0x06DD, "fin de aleya (Cf)"], [0x115F, "relleno hangul inicial"], [0x1160, "relleno hangul medial"],
	[0x17B4, "vocal inherente jemer"], [0x180B, "selector mongol"], [0x180E, "separador de vocal mongol"],
	[0x200B, "anchura cero"], [0x200C, "no unión de anchura cero"], [0x200D, "unión de anchura cero"],
	[0x200E, "marca de izquierda a derecha"], [0x200F, "marca de derecha a izquierda"],
	[0x2028, "separador de línea"], [0x2029, "separador de párrafo"], [0x202A, "incrustación LTR"],
	[0x202E, "inversión RTL"], [0x2060, "unión de palabras"], [0x2061, "función invisible"],
	[0x2066, "aislamiento LTR"], [0x2069, "fin de aislamiento"], [0x3164, "relleno hangul"],
	[0xFE00, "selector de variación 1"], [0xFE0E, "selector de presentación de texto"],
	[0xFEFF, "marca de orden de bytes"], [0xFFA0, "relleno hangul de media anchura"],
	[0xFFF9, "anotación interlineal"], [0xFFFB, "fin de anotación interlineal"],
	[0xFFFC, "sustitución de objeto"], [0xFFFD, "carácter de sustitución"], [0xFDD0, "no carácter"],
	[0xFDEF, "no carácter"], [0xFFFE, "no carácter"], [0xFFFF, "no carácter"], [0x1FFFF, "no carácter"],
	[0x10FFFF, "no carácter"], [0xE000, "uso privado"], [0xF8FF, "uso privado"],
	[0xF0000, "uso privado (plano 15)"], [0x10FFFD, "uso privado (plano 16)"],
	[0xE0001, "etiqueta de idioma"], [0xE0041, "etiqueta A"], [0xE007F, "cancelar etiqueta"],
	[0xE0100, "selector de variación 17"], [0xE01EF, "selector de variación 256"],
	[0x1D173, "inicio de barra musical (Cf)"], [0x13430, "unión jeroglífica (Cf)"],
	[0x1BCA0, "formato taquigráfico (Cf)"], [0x0378, "sin asignar"], [0x0E3B, "sin asignar"],
]
## Puntos de código que pasan a ser un espacio.
const SPACE_CODES: Array = [
	[0x09, "tabulador"], [0x0A, "salto de línea"], [0x0B, "tabulador vertical"], [0x0C, "avance de página"],
	[0x0D, "retorno"], [0xA0, "sin ruptura"], [0x1680, "espacio ogam"], [0x2000, "cuadratín medio"],
	[0x2007, "espacio de cifra"], [0x200A, "espacio fino"], [0x202F, "sin ruptura estrecho"],
	[0x205F, "espacio matemático"], [0x2800, "blanco braille"], [0x3000, "espacio ideográfico"],
]
## Puntos de código que se quedan tal cual, vayan donde vayan.
const KEPT_CODES: Array = [
	[0x41, "A"], [0xF1, "ñ"], [0xBF, "¿"], [0x20AC, "€"], [0x0628, "letra árabe"], [0x05D0, "álef"],
	[0x0915, "letra devanagari"], [0x0E01, "letra tailandesa"], [0x4E2D, "ideograma"],
	[0xAC00, "sílaba hangul"], [0x1F600, "emoji"], [0x2694, "espadas"], [0x2764, "corazón"],
	[0x1F3FB, "tono de piel (modificador, no marca)"], [0xFF9E, "marca sonora de media anchura (Lm)"],
	[0x1F1EA, "indicador regional"],
]
## Marcas combinantes (categoría M): se quedan tras una letra y se quitan sin letra delante.
const MARK_CODES: Array = [
	[0x0300, "grave"], [0x0301, "agudo"], [0x0302, "circunflejo"], [0x0303, "tilde"], [0x0308, "diéresis"],
	[0x036F, "x combinante"], [0x0483, "titlo cirílico"], [0x0591, "acento hebreo"],
	[0x05B4, "jiriq hebreo"], [0x064B, "fathatan"], [0x0651, "shadda"], [0x0670, "álef superíndice"],
	[0x093C, "nukta"], [0x093E, "vocal devanagari (Mc)"], [0x094D, "virama"], [0x0E48, "tono tailandés"],
	[0x0F90, "subíndice tibetano"], [0x1AB0, "diacrítico extendido"], [0x1DC0, "diacrítico suplementario"],
	[0x20D0, "arpón sobre"], [0x20DD, "círculo envolvente (Me)"], [0x20E3, "tecla envolvente (Me)"],
	[0xFE0F, "presentación emoji"], [0xFE20, "media ligadura"], [0x1D167, "trémolo musical"],
]


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
		"😀  😀", "a [b]" + _chr(0x0301), _chr(0x0301) + "a" + _chr(0x0301).repeat(9),
		"x " + _chr(0x2800) + " " + _chr(0x0300) + "y",
	]
	for sample: String in samples:
		var once: String = ChatText.sanitize(sample)
		assert_eq(ChatText.sanitize(once), once, "idempotente: «%s»" % sample)


# --- Invisibles y marcas (tabla de puntos de código) ------------------------------------------

func test_invisible_format_and_unassigned_code_points_are_removed() -> void:
	assert_true(ChatText.is_stripped_control(0), "el byte nulo")
	for entry: Array in STRIPPED_CODES:
		var code: int = entry[0]
		var what: String = "U+%04X (%s)" % [code, entry[1]]
		var c: String = _chr(code)
		assert_eq(ChatText.sanitize("x" + c + "y"), "xy", "%s se quita entre letras" % what)
		assert_true(ChatText.is_stripped_control(code), "%s se trata como invisible" % what)
		assert_eq(ChatText.check(c + c + c), ChatText.Problem.EMPTY, "%s solo: queda vacío" % what)


func test_spaces_table() -> void:
	for entry: Array in SPACE_CODES:
		var code: int = entry[0]
		var what: String = "U+%04X (%s)" % [code, entry[1]]
		var c: String = _chr(code)
		assert_eq(ChatText.sanitize("x" + c + "y"), "x y", "%s es un espacio" % what)
		assert_true(ChatText.is_space(code), "%s cuenta como espacio" % what)
		assert_false(ChatText.is_stripped_control(code), "%s no se quita" % what)
		assert_eq(ChatText.check(c + c + c), ChatText.Problem.EMPTY, "%s solo: queda vacío" % what)


func test_visible_characters_table() -> void:
	for entry: Array in KEPT_CODES:
		var code: int = entry[0]
		var what: String = "U+%04X (%s)" % [code, entry[1]]
		var c: String = _chr(code)
		assert_eq(ChatText.sanitize("x" + c + "y"), "x" + c + "y", "%s se queda" % what)
		assert_eq(ChatText.sanitize(c), c, "%s solo, también" % what)
		assert_false(ChatText.is_stripped_control(code), "%s no es invisible" % what)


func test_combining_marks_table() -> void:
	for entry: Array in MARK_CODES:
		var code: int = entry[0]
		var what: String = "U+%04X (%s)" % [code, entry[1]]
		var c: String = _chr(code)
		assert_eq(ChatText.sanitize("x" + c + "y"), "x" + c + "y", "%s se queda sobre una letra" % what)
		assert_eq(ChatText.sanitize(c + "y"), "y", "%s al principio, sin letra, se quita" % what)
		assert_eq(ChatText.sanitize("x " + c + "y"), "x y", "%s tras un espacio se quita" % what)
		assert_eq(ChatText.check(c + c + c), ChatText.Problem.EMPTY, "%s solas: queda vacío" % what)
		assert_false(ChatText.is_stripped_control(code), "%s no se quita siempre" % what)


func test_a_letter_keeps_at_most_four_marks() -> void:
	# «Zalgo»: una letra con 254 marcas cabe en 255 caracteres; ocupa toda la caja de chat y, con estas
	# marcas variadas, la maquetación de texto de Godot 4.7.2 se queda colgada en quien la recibe.
	var zalgo: String = "a"
	for i: int in 254:
		zalgo += _chr(0x0300 + i % 0x70)
	var cleaned: String = ChatText.sanitize(zalgo)
	assert_eq(cleaned.length(), 1 + ChatText.MAX_MARKS_PER_BASE, "la letra y cuatro marcas")
	assert_eq(cleaned, zalgo.substr(0, 1 + ChatText.MAX_MARKS_PER_BASE), "las cuatro primeras")
	assert_eq(ChatText.MAX_MARKS_PER_BASE, 4, "el tope documentado")
	# Cada letra tiene su propio tope.
	var word: String = ""
	var expected: String = ""
	for letter: String in ["H", "o", "l", "a"]:
		word += letter + _chr(0x0301).repeat(10)
		expected += letter + _chr(0x0301).repeat(ChatText.MAX_MARKS_PER_BASE)
	assert_eq(ChatText.sanitize(word), expected, "cuatro marcas por letra")
	# Lo normal pasa entero.
	var vietnamese: String = "e" + _chr(0x0302) + _chr(0x0301)
	assert_eq(ChatText.sanitize(vietnamese), vietnamese, "dos marcas (vietnamita descompuesto)")
	var keycap: String = "1" + _chr(0xFE0F) + _chr(0x20E3)
	assert_eq(ChatText.sanitize(keycap), keycap, "tecla 1 en emoji")
	var heart: String = _chr(0x2764) + _chr(0xFE0F)
	assert_eq(ChatText.sanitize(heart), heart, "corazón en color")
	var hebrew: String = _chr(0x05D1) + _chr(0x05BC) + _chr(0x05B8) + _chr(0x0591) + _chr(0x05BD)
	assert_eq(ChatText.sanitize(hebrew), hebrew, "letra hebrea con cuatro puntos y acentos")


func test_a_grapheme_keeps_at_most_five_code_points() -> void:
	# Lo que se pega a la letra anterior sin ser una marca (categoría M) también forma un grafema largo: con
	# 128 «ำ» (U+0E33) tras una consonante tailandesa, la maquetación de Godot 4.7.2 se cuelga en quien lo
	# recibe. Cada caso: la base y lo que se le pega, repetido.
	var cases: Dictionary = {
		"ำ tailandés": [0x0E01, 0x0E33], "ຳ lao": [0x0E81, 0x0EB3],
		"vocal del hangul antiguo": [0x1100, 0x1161], "tono de piel": [0x1F44D, 0x1F3FB],
	}
	var limit: int = ChatText.MAX_CODE_POINTS_PER_GRAPHEME
	assert_eq(limit, 1 + ChatText.MAX_MARKS_PER_BASE, "la letra y sus cuatro marcas")
	for what: String in cases:
		var codes: Array = cases[what]
		var hostile: String = _chr(codes[0]) + _chr(codes[1]).repeat(128)
		var cleaned: String = ChatText.sanitize("hola " + hostile + " adiós")
		var expected: String = "hola " + hostile.left(limit) + " adiós"
		assert_eq(cleaned, expected, "%s: se queda la base con %d más" % [what, limit - 1])
		assert_eq(ChatText.sanitize(cleaned), cleaned, "%s: idempotente" % what)
		if cleaned == expected:
			# Lo saneado se maqueta sin colgarse (lo de antes del saneado no se maqueta aquí: colgaría la prueba).
			var line := TextLine.new()
			line.add_string(cleaned, ThemeDB.fallback_font, 16)
			assert_true(line.get_size().x > 0.0, "%s: lo saneado se maqueta" % what)
	# Lo normal, aunque no sea latino, pasa entero.
	for normal: String in ["café con leche, ñandú", "สวัสดีครับ", "ສະບາຍດີ", "안녕하세요", "こんにちは",
			"Здравствуйте", "नमस्ते", _chr(0x1F44D) + _chr(0x1F3FD)]:
		assert_eq(ChatText.sanitize(normal), normal, "«%s» no cambia" % normal)


func test_text_that_only_looks_blank_is_empty() -> void:
	for blank: String in [_chr(0x3164).repeat(5), _chr(0xFFA0) + _chr(0x115F) + _chr(0x1160),
			_chr(0x2800).repeat(3), _chr(0x0301).repeat(5), _chr(0x200B) + " " + _chr(0x061C),
			_chr(0xE0041).repeat(4), _chr(0xFE0F).repeat(3)]:
		assert_eq(ChatText.check(blank), ChatText.Problem.EMPTY,
				"un mensaje que se vería en blanco: %s" % _codes(blank))
	assert_eq(ChatText.sanitize("x" + _chr(0x061C) + "y"), "xy", "la marca de dirección U+061C no pasa")


func test_markup_removal_is_linear_and_keeps_its_meaning() -> void:
	var nested: String = "[".repeat(127) + "]".repeat(127)
	assert_eq(ChatText.sanitize(nested), "", "127 niveles de corchetes")
	assert_eq(ChatText.sanitize("a" + nested + "b"), "ab", "y lo que los rodea se queda")
	assert_eq(ChatText.sanitize("]a[b"), "ab", "un cierre antes de una apertura")
	assert_eq(ChatText.sanitize("[a]b]c"), "bc", "un cierre de más")
	assert_eq(ChatText.sanitize("[a[b]"), "a", "una apertura de más")
	assert_eq(ChatText.sanitize("x" + "[".repeat(300)), "x", "300 aperturas sin cerrar")
	# Mismo resultado que quitar el par más interior una y otra vez (el saneado de antes), en textos al azar.
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var alphabet: Array[String] = ["a", "b", "[", "]", " "]
	for i: int in 400:
		var sample: String = ""
		for _k: int in rng.randi_range(0, 24):
			sample += alphabet[rng.randi_range(0, alphabet.size() - 1)]
		assert_eq(ChatText.sanitize(sample), _reference_markup(sample), "«%s»" % sample)


func test_sanitizing_random_hostile_text_is_stable_and_clean() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var pieces: Array[String] = ["a", "Ñ", " ", "  ", "[", "]", "[b]", _chr(0x0301), _chr(0x0300),
			_chr(0x094D), _chr(0x200B), _chr(0x061C), _chr(0x202E), _chr(0x3164), _chr(0x2800), _chr(0xFE0F),
			_chr(0xFE0E), _chr(0xE0041), _chr(0xE000), _chr(0x0378), _chr(0x1F600), "\t", "\n",
			_chr(0x0E01), _chr(0x0E33), _chr(0x0EB3), _chr(0x1100), _chr(0x1161), _chr(0x1F3FB)]
	var mark := RegEx.create_from_string("\\p{M}")
	var grapheme := RegEx.create_from_string("\\X")
	for i: int in 300:
		var sample: String = ""
		for _k: int in rng.randi_range(0, 40):
			sample += pieces[rng.randi_range(0, pieces.size() - 1)]
		var once: String = ChatText.sanitize(sample)
		assert_eq(ChatText.sanitize(once), once, "idempotente: %s" % _codes(sample))
		assert_false(once.contains("[") or once.contains("]") or once.contains("  "),
				"sin corchetes ni espacios dobles: %s" % _codes(sample))
		assert_eq(once, once.strip_edges(), "sin espacios en los extremos: %s" % _codes(sample))
		var run: int = 0
		for k: int in once.length():
			var code: int = once.unicode_at(k)
			assert_false(ChatText.is_stripped_control(code), "U+%04X no debía quedar" % code)
			if mark.search(once[k]) != null:
				run += 1
				assert_true(k > 0 and once[k - 1] != " ", "marca sin letra: %s" % _codes(sample))
			else:
				run = 0
			assert_true(run <= ChatText.MAX_MARKS_PER_BASE, "demasiadas marcas: %s" % _codes(sample))
		for found: RegExMatch in grapheme.search_all(once):
			assert_true(found.get_string().length() <= ChatText.MAX_CODE_POINTS_PER_GRAPHEME,
					"grafema demasiado largo: %s" % _codes(sample))


# Carácter con el código [param code] (así el archivo no lleva caracteres invisibles).
func _chr(code: int) -> String:
	return String.chr(code)


# Los códigos de [param text], para los mensajes de error.
func _codes(text: String) -> String:
	var parts := PackedStringArray()
	for i: int in text.length():
		parts.append("%04X" % text.unicode_at(i))
	return " ".join(parts)


# El saneado de corchetes de antes (quitar el par más interior hasta que no cambie, y después los sueltos)
# más los espacios, para comparar con el lineal.
func _reference_markup(text: String) -> String:
	var pair := RegEx.create_from_string("\\[[^\\[\\]]*\\]")
	var current: String = text
	var previous: String = ""
	while previous != current:
		previous = current
		current = pair.sub(current, "", true)
	current = current.replace("[", "").replace("]", "")
	var spaces := RegEx.create_from_string(" {2,}")
	return spaces.sub(current, " ", true).strip_edges()
