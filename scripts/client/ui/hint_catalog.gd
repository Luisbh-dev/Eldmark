class_name HintCatalog
extends RefCounted
## Las pistas del juego (UI-42, docs/fuerte.md sección 6): consejos cortos, en español, que [HintToasts]
## enseña una sola vez por jugador cuando pasa lo que los motiva. Cada una tiene un identificador estable
## (es lo que guarda [HintLog]) y su texto. Los textos son provisionales (la redacción definitiva es del
## usuario).
## [br][br]
## [b]Glifos reales.[/b] Los textos llevan marcas [code]{accion}[/code] ([code]{open_map}[/code],
## [code]{primary_attack}[/code]...) que [method text_of] sustituye por la tecla o el botón que el jugador
## tiene asignado ([method UIKeyGlyph.label_for_action]): si reasigna los controles, la pista lo dice bien.
## Solo cliente.

const COMBAT: StringName = &"combat"
const CONTROLS: StringName = &"controls"
const FORT_NEAR: StringName = &"fort_near"
const CAPTAIN_DOWN: StringName = &"captain_down"
const GATE_CLOSED: StringName = &"gate_closed"
const TELEGRAPH: StringName = &"telegraph"
const RESPAWN_MAP: StringName = &"respawn_map"

## Pistas en el orden en que se ofrecen si coinciden varias.
const IDS: Array[StringName] = [COMBAT, CONTROLS, FORT_NEAR, GATE_CLOSED, CAPTAIN_DOWN, TELEGRAPH, RESPAWN_MAP]

## Acciones cuyas marcas se sustituyen en los textos.
const ACTIONS: Array[StringName] = [&"primary_attack", &"block", &"dodge", &"open_map", &"scoreboard",
		&"open_settings"]

const TEXTS: Dictionary = {
	COMBAT: "Combate: {primary_attack} ataca, {block} bloquea y {dodge} esquiva. Cada acción gasta resistencia.",
	CONTROLS: "Pulsa {open_map} para abrir el mapa, mantén {scoreboard} para ver el marcador y {open_settings} para los ajustes.",
	FORT_NEAR: "Estás cerca de un fuerte. Cuando caiga su capitán, entra en el círculo de captura para tomarlo.",
	GATE_CLOSED: "La puerta está cerrada para tu reino: rómpela a golpes o espera a que la abran desde dentro.",
	CAPTAIN_DOWN: "Ha caído el capitán: el círculo de captura está activo. Quédate dentro para capturar el fuerte.",
	TELEGRAPH: "Una marca en el suelo avisa de un ataque enemigo: sal de ella antes de que se llene.",
	RESPAWN_MAP: "Puedes elegir dónde reaparecer: pulsa «Elegir en el mapa» y toca un punto resaltado.",
}


## true si [param id] es una pista del catálogo.
static func has_hint(id: StringName) -> bool:
	return TEXTS.has(id)


## Texto de la pista [param id] con las teclas reales del jugador (vacío si no existe).
static func text_of(id: StringName) -> String:
	return resolve(String(TEXTS.get(id, "")))


## [param template] con cada [code]{accion}[/code] sustituida por la tecla o el botón asignado a esa acción.
static func resolve(template: String) -> String:
	var text: String = template
	for action: StringName in ACTIONS:
		var mark: String = "{%s}" % action
		if text.contains(mark):
			text = text.replace(mark, UIKeyGlyph.label_for_action(action))
	return text
