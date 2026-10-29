extends TestCase
## Pruebas de [WarEvents] (docs/fuerte.md, sección 5): los ids de los avisos de guerra y sus textos
## en español.

const FORT_NAME: String = "Fuerte del Vado Gris"


func test_ids_follow_the_contract() -> void:
	assert_eq(WarEvents.UNDER_ATTACK, 1, "fuerte atacado")
	assert_eq(WarEvents.CAPTAIN_DOWN, 2, "capitán caído")
	assert_eq(WarEvents.CAPTURE_STARTED, 3, "captura iniciada")
	assert_eq(WarEvents.CAPTURE_CONTESTED, 4, "captura disputada")
	assert_eq(WarEvents.GATE_BROKEN, 5, "puerta rota")
	assert_eq(WarEvents.FORT_CAPTURED, 6, "fuerte capturado")
	assert_eq(WarEvents.FORT_RESET, 7, "fuerte reiniciado")
	assert_eq(WarEvents.all_ids(), PackedInt32Array([1, 2, 3, 4, 5, 6, 7]))
	for id: int in WarEvents.all_ids():
		assert_true(WarEvents.is_valid(id))
		assert_false(String(WarEvents.key_of(id)).is_empty(), "nombre interno del aviso %d" % id)
	assert_false(WarEvents.is_valid(0))
	assert_false(WarEvents.is_valid(8))
	assert_eq(WarEvents.key_of(8), &"")
	assert_eq(WarEvents.key_of(WarEvents.FORT_CAPTURED), &"fort_captured")


func test_every_event_has_a_spanish_text_that_names_the_realm_and_the_fort() -> void:
	for id: int in [WarEvents.UNDER_ATTACK, WarEvents.CAPTAIN_DOWN, WarEvents.CAPTURE_STARTED,
			WarEvents.GATE_BROKEN, WarEvents.FORT_CAPTURED]:
		var text: String = WarEvents.text(id, 2, FORT_NAME)
		assert_true(text.contains("Solmarch"), "aviso %d nombra al reino: %s" % [id, text])
		assert_true(text.contains(FORT_NAME), "aviso %d nombra el fuerte: %s" % [id, text])
		assert_false(text.contains("{"), "aviso %d sin marcas sin sustituir" % id)
	# La disputa y el reinicio no necesitan reino.
	assert_true(WarEvents.text(WarEvents.CAPTURE_CONTESTED, 1, FORT_NAME).contains(FORT_NAME))
	assert_true(WarEvents.text(WarEvents.FORT_RESET, 0, FORT_NAME).contains(FORT_NAME))


func test_exact_texts() -> void:
	assert_eq(WarEvents.text(WarEvents.UNDER_ATTACK, 2, FORT_NAME), "¡Solmarch ataca el Fuerte del Vado Gris!")
	assert_eq(WarEvents.text(WarEvents.CAPTAIN_DOWN, 1, FORT_NAME), "¡El capitán del Fuerte del Vado Gris ha caído ante Vardheim!")
	assert_eq(WarEvents.text(WarEvents.CAPTURE_STARTED, 1, FORT_NAME), "Vardheim empieza a capturar el Fuerte del Vado Gris.")
	assert_eq(WarEvents.text(WarEvents.CAPTURE_CONTESTED, 1, FORT_NAME), "La captura del Fuerte del Vado Gris está disputada.")
	assert_eq(WarEvents.text(WarEvents.GATE_BROKEN, 2, FORT_NAME), "¡Solmarch ha derribado la puerta del Fuerte del Vado Gris!")
	assert_eq(WarEvents.text(WarEvents.FORT_CAPTURED, 1, FORT_NAME), "¡Vardheim ha capturado el Fuerte del Vado Gris!")
	assert_eq(WarEvents.text(WarEvents.FORT_RESET, 0, FORT_NAME), "El Fuerte del Vado Gris ha vuelto a quedar sin dueño.")


func test_default_fort_name_unknown_ids_and_neutral_realm() -> void:
	assert_eq(WarEvents.text(WarEvents.FORT_CAPTURED, 1), "¡Vardheim ha capturado el Fuerte!", "sin nombre de fuerte")
	assert_eq(WarEvents.text(0, 1, FORT_NAME), "", "un aviso desconocido no tiene texto")
	assert_eq(WarEvents.text(99, 1, FORT_NAME), "")
	assert_eq(WarEvents.realm_label(0), "los Huecos", "el bando neutral")
	assert_eq(WarEvents.realm_label(1), "Vardheim")
	assert_eq(WarEvents.realm_label(3), "Askarra")
	assert_eq(WarEvents.realm_label(9), "un reino desconocido")
