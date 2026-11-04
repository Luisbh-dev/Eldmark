class_name CombatClipSet
extends Resource
## Assigns each combat action its animation clip (ART-07/ART-08). It is a text resource
## ([code]data/animation/sword_shield_clips.tres[/code]): whoever tunes the look changes the
## clips and the seconds of each segment here without touching code.
## [br][br]
## [member libraries] says where the animation libraries are (UAL1 and UAL2, already imported, the
## variants without root motion) and [method get_animation] resolves a "library/name" clip. The
## phase durations are not here: they come from the combat data ([CombatCatalog]), and the layer
## stretches the segments to fit them.

## Animated actions.
@export var entries: Array[CombatActionAnim] = []
## Library ([code]ual1[/code], [code]ual2[/code]) -> path of the animations file.
@export var libraries: Dictionary[StringName, String] = {}

# Libraries already loaded (library key -> AnimationLibrary).
var _loaded: Dictionary[StringName, AnimationLibrary] = {}


## The entry for action [param key], or null.
func find(key: StringName) -> CombatActionAnim:
	for entry: CombatActionAnim in entries:
		if entry != null and entry.key == key:
			return entry
	return null


## "library/name" clip (for example [code]ual2/Sword_Block[/code]), or null if the library or
## the clip does not exist.
func get_animation(full_name: StringName) -> Animation:
	var text: String = String(full_name)
	var slash: int = text.find("/")
	if slash <= 0:
		return null
	var library_key := StringName(text.substr(0, slash))
	var library: AnimationLibrary = _library(library_key)
	if library == null:
		return null
	var clip_name := StringName(text.substr(slash + 1))
	if not library.has_animation(clip_name):
		return null
	return library.get_animation(clip_name)


# Loads library [param key] (once).
func _library(key: StringName) -> AnimationLibrary:
	if _loaded.has(key):
		return _loaded[key]
	if not libraries.has(key):
		return null
	var library: AnimationLibrary = load(libraries[key]) as AnimationLibrary
	if library != null:
		_loaded[key] = library
	return library
