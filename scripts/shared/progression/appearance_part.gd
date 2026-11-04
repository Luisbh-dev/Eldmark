class_name AppearancePart
extends Resource
## A part of the appearance (docs/progression.md §7.2, ART-19): a body, a head, a hairstyle, a
## beard or marks from [AppearanceCatalog]. It lives inside the catalog; its position in the list
## is the index stored in the 8 B of [CharacterAppearance], so lists only grow.
## [br][br]
## The scene is a path ([member scene_path]) and not a [PackedScene]: the server loads the catalog
## to validate and must never load models (the server preset trims [code]assets/[/code]).

## Stable id ([code][a-z0-9_][/code]); frozen by [code]data/characters/appearance_ids.txt[/code].
@export var id: StringName = &""
## Name in Spanish for the creation screen.
@export var display_name: String = ""
## glTF scene of the part (client-only; mounted by [code]AppearanceApplier[/code]). Empty for a
## part that has no mesh of its own.
@export var scene_path: String = ""
## Indices of [member AppearanceCatalog.bodies] it fits with; empty = all.
@export var bodies: PackedInt32Array = PackedInt32Array()


## true if the part fits body [param body] (index in the catalog).
func fits_body(body: int) -> bool:
	return bodies.is_empty() or bodies.has(body)
