class_name AppearanceColor
extends Resource
## A color of the appearance (docs/progression.md §7.2, ART-19): a skin tone, a hair color (hair,
## beard and eyebrows) or an eye color from [AppearanceCatalog]. Like parts, its position in the
## list is the index that gets stored, so lists only grow.

## Stable id ([code][a-z0-9_][/code]); frozen by [code]data/characters/appearance_ids.txt[/code].
@export var id: StringName = &""
## Name in Spanish for the creation screen.
@export var display_name: String = ""
## Tint the client applies to the material.
@export var color: Color = Color.WHITE
## Own texture (optional and client-only), as a path: the server does not load textures.
@export var texture_path: String = ""
