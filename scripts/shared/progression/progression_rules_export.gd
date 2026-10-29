class_name ProgressionRulesExport
extends RefCounted
## Las reglas del juego que necesita la plataforma en Go, en un solo archivo:
## [code]platform/internal/gamedata/progression_rules.json[/code] (docs/progresion.md §13.4,
## docs/plataforma.md §4.4). La plataforma lo incrusta con [code]//go:embed[/code] y valida con él lo
## mismo que la simulación: los nombres de personaje (con [NameRules]) y, con progresion.md, razas,
## apariencia, plantillas de inicio, objetos, curva de niveles, monedas, motivos y contenedores.
## [br][br]
## [method build] es el único generador; [code]tools/progression/export_rules.gd[/code] escribe el
## archivo y [code]tests/test_progression_rules_export.gd[/code] comprueba que el del repositorio
## coincide con [method build]. Si una regla cambia, se vuelve a exportar y el archivo nuevo se sube
## con el cambio.
## [br][br]
## Secciones de docs/plataforma.md: [code]protocol_version[/code] (el
## [code]ELDMARK_MIN_PROTOCOL[/code] por defecto en dev y test) y [code]names[/code]. Las demás las
## añade progresion.md P3 (cada una con su función, como [method _names]). Sin estado, reloj ni
## azar: dos llamadas dan lo mismo.

## Ruta del archivo, relativa a la raíz del proyecto.
const OUTPUT_PATH: String = "res://platform/internal/gamedata/progression_rules.json"


## Las reglas exportadas, una clave por sección.
static func build() -> Dictionary:
	return {
		"protocol_version": NetProtocol.PROTOCOL_VERSION,
		"names": _names(),
	}


## El texto del archivo: [method build] en JSON con las claves ordenadas, tabuladores y un salto de
## línea al final.
static func to_json() -> String:
	return JSON.stringify(build(), "\t", true) + "\n"


## Sección [code]names[/code]: lo que [NameRules] necesita para [method NameRules.validate] y
## [method NameRules.normalize_key]. [code]reserved[/code] va tal como está escrito en
## [constant NameRules.RESERVED]: la plataforma lo normaliza con la misma regla.
static func _names() -> Dictionary:
	var folded: Dictionary = {}
	for letter: String in NameRules.FOLDED:
		folded[letter] = NameRules.FOLDED[letter]
	var reserved: Array[String] = []
	reserved.assign(NameRules.RESERVED)
	return {
		"min_length": NameRules.MIN_LENGTH,
		"max_length": NameRules.MAX_LENGTH,
		"upper_letters": NameRules.UPPER_LETTERS,
		"lower_letters": NameRules.LOWER_LETTERS,
		"folded": folded,
		"reserved": reserved,
	}
