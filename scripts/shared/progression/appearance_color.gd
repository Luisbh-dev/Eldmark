class_name AppearanceColor
extends Resource
## Un color de la apariencia (docs/progresion.md §7.2, ART-19): un tono de piel, un color de pelo (pelo,
## barba y cejas) o un color de ojos de [AppearanceCatalog]. Como las piezas, su posición en la lista es
## el índice que se guarda, así que las listas solo crecen.

## Id estable ([code][a-z0-9_][/code]); lo congela [code]data/characters/appearance_ids.txt[/code].
@export var id: StringName = &""
## Nombre en español para la pantalla de creación.
@export var display_name: String = ""
## Tinte que aplica el cliente al material.
@export var color: Color = Color.WHITE
## Textura propia (opcional y solo cliente), como ruta: el servidor no carga texturas.
@export var texture_path: String = ""
