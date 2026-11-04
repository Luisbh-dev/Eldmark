class_name RaceDefinition
extends Resource
## A playable people (docs/progresion.md §7.1, PRG-14), in
## [code]data/characters/races/<id>.tres[/code]: one per realm and cosmetic only. It says which
## parts and colors of [AppearanceCatalog] one of its members can wear; the whole rule is in
## [method CharacterAppearance.validate].
## [br][br]
## The lists are indices into the catalog list of the same name (from 0; hair and beard too, even
## though in the 8 B they go with +1). There are no racial stats: [member stat_modifiers] must be
## empty (the test requires it). Nothing changes in the simulation.

## Stable id: [code]race_<realm>[/code] (the API and the database store it).
@export var id: StringName = &""
## Realm, as a [RealmCatalog] id ([code]vardheim[/code]…). In the API and in the exported rules it
## goes as its [enum NetProtocol.Realm] code.
@export var realm: StringName = &""
## Name in Spanish (provisional until MUN-28).
@export var display_name: String = ""
## What is distinctive about the people, for the creation screen (expanded by ART-20).
@export_multiline var description: String = ""
## Allowed indices of each catalog list.
@export var bodies: PackedInt32Array = PackedInt32Array()
@export var heads: PackedInt32Array = PackedInt32Array()
@export var hairs: PackedInt32Array = PackedInt32Array()
@export var beards: PackedInt32Array = PackedInt32Array()
@export var marks: PackedInt32Array = PackedInt32Array()
@export var skin_tones: PackedInt32Array = PackedInt32Array()
@export var hair_colors: PackedInt32Array = PackedInt32Array()
@export var eye_colors: PackedInt32Array = PackedInt32Array()
## Going without hair can be chosen (byte 3 = 0).
@export var allows_no_hair: bool = true
## Going without a beard can be chosen (byte 4 = 0).
@export var allows_no_beard: bool = true
## Effect on stats: none (decision in §0). Must be empty.
@export var stat_modifiers: Dictionary = {}


## Allowed indices of category [param category] ([constant AppearanceCatalog.PART_CATEGORIES] or
## [constant AppearanceCatalog.COLOR_CATEGORIES]); empty if it does not exist.
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
