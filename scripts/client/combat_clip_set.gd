class_name CombatClipSet
extends Resource
## Asigna a cada acción de combate su clip de animación (ART-07/ART-08). Es un recurso de texto
## ([code]data/animation/sword_shield_clips.tres[/code]): quien ajuste el aspecto cambia aquí los
## clips y los segundos de cada tramo sin tocar código.
## [br][br]
## [member libraries] dice dónde están las bibliotecas de animación (UAL1 y UAL2 ya importadas, las
## variantes sin root motion) y [method get_animation] resuelve un clip «biblioteca/nombre». Las
## duraciones de las fases no están aquí: salen de los datos de combate ([CombatCatalog]), y la capa
## estira los tramos para encajarlas.

## Acciones animadas.
@export var entries: Array[CombatActionAnim] = []
## Biblioteca ([code]ual1[/code], [code]ual2[/code]) -> ruta del archivo de animaciones.
@export var libraries: Dictionary[StringName, String] = {}

# Bibliotecas ya cargadas (clave de biblioteca -> AnimationLibrary).
var _loaded: Dictionary[StringName, AnimationLibrary] = {}


## La entrada de la acción [param key], o null.
func find(key: StringName) -> CombatActionAnim:
	for entry: CombatActionAnim in entries:
		if entry != null and entry.key == key:
			return entry
	return null


## Clip «biblioteca/nombre» (por ejemplo [code]ual2/Sword_Block[/code]), o null si la biblioteca o
## el clip no existen.
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


# Carga (una vez) la biblioteca [param key].
func _library(key: StringName) -> AnimationLibrary:
	if _loaded.has(key):
		return _loaded[key]
	if not libraries.has(key):
		return null
	var library: AnimationLibrary = load(libraries[key]) as AnimationLibrary
	if library != null:
		_loaded[key] = library
	return library
