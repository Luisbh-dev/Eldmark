class_name AppearancePart
extends Resource
## Una pieza de la apariencia (docs/progresion.md §7.2, ART-19): un cuerpo, una cabeza, un peinado, una
## barba o unas marcas de [AppearanceCatalog]. Va dentro del catálogo; su posición en la lista es el
## índice que se guarda en los 8 B de [CharacterAppearance], así que las listas solo crecen.
## [br][br]
## La escena va como ruta ([member scene_path]) y no como [PackedScene]: el servidor carga el catálogo
## para validar y nunca debe cargar modelos (el preset del servidor recorta [code]assets/[/code]).

## Id estable ([code][a-z0-9_][/code]); lo congela [code]data/characters/appearance_ids.txt[/code].
@export var id: StringName = &""
## Nombre en español para la pantalla de creación.
@export var display_name: String = ""
## Escena glTF de la pieza (solo cliente; la monta [code]AppearanceApplier[/code]). Vacía en una pieza
## que no tiene malla propia.
@export var scene_path: String = ""
## Índices de [member AppearanceCatalog.bodies] con los que encaja; vacío = todos.
@export var bodies: PackedInt32Array = PackedInt32Array()


## true si la pieza encaja con el cuerpo [param body] (índice en el catálogo).
func fits_body(body: int) -> bool:
	return bodies.is_empty() or bodies.has(body)
