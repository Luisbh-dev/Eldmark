class_name HintCatalog
extends RefCounted
## The game's hints (UI-42, docs/fortress.md section 6): short tips, in Spanish, that [HintToasts] shows
## only once per player when what motivates them happens. Each has a stable identifier (what [HintLog]
## stores) and its text. The texts are provisional (the final wording is up to the user).
## [br][br]
## [b]Real glyphs.[/b] The texts carry [code]{action}[/code] markers ([code]{open_map}[/code],
## [code]{primary_attack}[/code]...) that [method text_of] replaces with the key or button the player has
## assigned ([method UIKeyGlyph.label_for_action]): if they remap the controls, the hint says it correctly.
## Client only.

const COMBAT: StringName = &"combat"
const CONTROLS: StringName = &"controls"
const FORT_NEAR: StringName = &"fort_near"
const CAPTAIN_DOWN: StringName = &"captain_down"
const GATE_CLOSED: StringName = &"gate_closed"
const TELEGRAPH: StringName = &"telegraph"
const RESPAWN_MAP: StringName = &"respawn_map"

## Hints in the order they are offered if several coincide.
const IDS: Array[StringName] = [COMBAT, CONTROLS, FORT_NEAR, GATE_CLOSED, CAPTAIN_DOWN, TELEGRAPH, RESPAWN_MAP]

## Actions whose markers are replaced in the texts.
const ACTIONS: Array[StringName] = [&"primary_attack", &"block", &"dodge", &"open_map", &"scoreboard",
		&"open_settings", &"toggle_help"]

const TEXTS: Dictionary = {
	COMBAT: "Combate: {primary_attack} ataca, {block} bloquea y {dodge} esquiva. Cada acción gasta resistencia.",
	CONTROLS: "Pulsa {open_map} para abrir el mapa, mantén {scoreboard} para ver el marcador y {open_settings} para los ajustes. {toggle_help} muestra u oculta la línea de controles.",
	FORT_NEAR: "Estás cerca de un fuerte. Cuando caiga su capitán, entra en el círculo de captura para tomarlo.",
	GATE_CLOSED: "La puerta está cerrada para tu reino: rómpela a golpes o espera a que la abran desde dentro.",
	CAPTAIN_DOWN: "Ha caído el capitán: el círculo de captura está activo. Quédate dentro para capturar el fuerte.",
	TELEGRAPH: "Una marca en el suelo avisa de un ataque enemigo: sal de ella antes de que se llene.",
	RESPAWN_MAP: "Puedes elegir dónde reaparecer: pulsa «Elegir en el mapa» y toca un punto resaltado.",
}


## true if [param id] is a hint in the catalog.
static func has_hint(id: StringName) -> bool:
	return TEXTS.has(id)


## Text of hint [param id] with the player's real keys (empty if it does not exist).
static func text_of(id: StringName) -> String:
	return resolve(String(TEXTS.get(id, "")))


## [param template] with each [code]{action}[/code] replaced by the key or button assigned to that action.
static func resolve(template: String) -> String:
	var text: String = template
	for action: StringName in ACTIONS:
		var mark: String = "{%s}" % action
		if text.contains(mark):
			text = text.replace(mark, UIKeyGlyph.label_for_action(action))
	return text
