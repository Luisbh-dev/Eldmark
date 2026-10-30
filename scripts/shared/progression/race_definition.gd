class_name RaceDefinition
extends Resource
## Un pueblo jugable (docs/progresion.md §7.1, PRG-14), en [code]data/characters/races/<id>.tres[/code]:
## uno por reino y solo estético. Dice qué piezas y colores de [AppearanceCatalog] puede llevar quien es
## de él; la regla entera está en [method CharacterAppearance.validate].
## [br][br]
## Las listas son índices de la lista del mismo nombre del catálogo (desde 0; el pelo y la barba
## también, aunque en los 8 B vayan con +1). No hay estadísticas raciales: [member stat_modifiers] tiene
## que estar vacío (lo exige la prueba). En la simulación no cambia nada.

## Id estable: [code]race_<reino>[/code] (la API y la base de datos lo guardan).
@export var id: StringName = &""
## Reino, como id de [RealmCatalog] ([code]vardheim[/code]…). En la API y en las reglas exportadas va
## como su código de [enum NetProtocol.Realm].
@export var realm: StringName = &""
## Nombre en español (provisional hasta MUN-28).
@export var display_name: String = ""
## Lo propio del pueblo, para la pantalla de creación (lo amplía ART-20).
@export_multiline var description: String = ""
## Índices permitidos de cada lista del catálogo.
@export var bodies: PackedInt32Array = PackedInt32Array()
@export var heads: PackedInt32Array = PackedInt32Array()
@export var hairs: PackedInt32Array = PackedInt32Array()
@export var beards: PackedInt32Array = PackedInt32Array()
@export var marks: PackedInt32Array = PackedInt32Array()
@export var skin_tones: PackedInt32Array = PackedInt32Array()
@export var hair_colors: PackedInt32Array = PackedInt32Array()
@export var eye_colors: PackedInt32Array = PackedInt32Array()
## Se puede elegir ir sin pelo (byte 3 = 0).
@export var allows_no_hair: bool = true
## Se puede elegir ir sin barba (byte 4 = 0).
@export var allows_no_beard: bool = true
## Efecto en las estadísticas: ninguno (decisión de §0). Tiene que estar vacío.
@export var stat_modifiers: Dictionary = {}


## Índices permitidos de la categoría [param category] ([constant AppearanceCatalog.PART_CATEGORIES] o
## [constant AppearanceCatalog.COLOR_CATEGORIES]); vacío si no existe.
func allowed(category: StringName) -> PackedInt32Array:
	match category:
		&"bodies":
			return bodies
		&"heads":
			return heads
		&"hairs":
			return hairs
		&"beards":
			return beards
		&"marks":
			return marks
		&"skin_tones":
			return skin_tones
		&"hair_colors":
			return hair_colors
		&"eye_colors":
			return eye_colors
	return PackedInt32Array()
