class_name CombatSoundBank
extends RefCounted
## Bancos de sonido del combate y los pasos (ART-11, solo cliente): cada grupo es una carpeta de
## [code]assets/audio/sfx/[/code] con entre 3 y 8 variantes, su recorte de volumen (el de
## [code]niveles.json[/code], que equilibra las categorías entre sí) y la variación aleatoria de tono y volumen.
## Un grupo se carga la primera vez que se pide y devuelve un [AudioStreamRandomizer] sin repetir el
## último sonido.
## [br][br]
## [b]Qué suena para cada cosa.[/b] [method impact_group] elige el grupo de un impacto según el material
## ([enum Armor]) y si es bloqueo o parada; [method step_group] el de un paso según la superficie
## ([constant SURFACE_GRASS]...). Los sonidos de casa los genera [code]tools/audio/synth_sfx.py[/code] y los
## pasos de hierba y madera son de Kenney Impact Sounds (CC0, ver [code]assets/LICENCIAS.md[/code]); la hoja de
## escucha de [code]tools/audio/listening_sheet.py[/code] enseña cada categoría con sus alternativas.

## Material de lo que recibe el golpe.
enum Armor { FLESH, LEATHER, GAMBESON, MAIL, SHIELD_WOOD, SHIELD_METAL, HOLLOW }

const SURFACE_GRASS: StringName = &"grass"
const SURFACE_DIRT: StringName = &"dirt"
const SURFACE_STONE: StringName = &"stone"
const SURFACE_WOOD: StringName = &"wood"
const SURFACE_WATER: StringName = &"water"
const SURFACES: Array[StringName] = [SURFACE_GRASS, SURFACE_DIRT, SURFACE_STONE, SURFACE_WOOD, SURFACE_WATER]

const SFX_DIR: String = "res://assets/audio/sfx"

## Grupos: nombre -> [carpeta, prefijo, número de variantes, recorte de volumen (dB), variación de tono (0,05 =
## ±5 %), variación de volumen (dB)]. Los números son los de [code]niveles.json[/code]; una prueba comprueba que
## coinciden.
const GROUPS: Dictionary = {
	&"sword_swing_light": ["swing", "sword_swing_light", 6, -5.0, 0.05, 2.0],
	&"sword_swing_heavy": ["swing", "sword_swing_heavy", 3, -4.0, 0.05, 2.0],
	&"hit_flesh": ["hit_flesh", "hit_flesh", 5, 0.0, 0.05, 2.0],
	&"hit_leather": ["hit_leather", "hit_leather", 5, 0.0, 0.05, 2.0],
	&"hit_gambeson": ["hit_gambeson", "hit_gambeson", 5, 0.0, 0.05, 2.0],
	&"hit_mail": ["hit_mail", "hit_mail", 4, 0.0, 0.05, 2.0],
	&"hit_shield_wood": ["hit_shield", "hit_shield_wood", 5, -1.0, 0.05, 2.0],
	&"hit_shield_metal": ["hit_shield", "hit_shield_metal", 3, -1.0, 0.05, 2.0],
	&"clash_metal": ["parry", "clash_metal", 4, -2.0, 0.04, 2.0],
	&"body_fall": ["body", "body_fall", 3, -3.0, 0.05, 2.0],
	&"dodge_roll": ["dodge", "dodge_roll", 3, -9.0, 0.06, 2.0],
	&"dodge_step": ["dodge", "dodge_step", 2, -9.0, 0.06, 2.0],
	&"step_stone": ["step_stone", "step_stone", 8, -11.0, 0.05, 2.0],
	&"step_dirt": ["step_dirt", "step_dirt", 8, -12.0, 0.05, 2.0],
	&"step_grass": ["step_grass", "step_grass", 5, -14.0, 0.05, 2.0],
	&"step_wood": ["step_wood", "step_wood", 5, -14.0, 0.05, 2.0],
	&"hollow_hurt": ["hollow", "hollow_hurt", 4, -4.0, 0.06, 2.0],
	&"hollow_death": ["hollow", "hollow_death", 2, -3.0, 0.05, 2.0],
}

# Grupo -> {stream: AudioStreamRandomizer, volume_db: float}.
static var _cache: Dictionary = {}


## true si [param group] existe en la tabla.
static func has_group(group: StringName) -> bool:
	return GROUPS.has(group)


## Nombres de los archivos de [param group] (rutas de [code]res://[/code], las que existen).
static func files_of(group: StringName) -> PackedStringArray:
	var files: PackedStringArray = PackedStringArray()
	if not GROUPS.has(group):
		return files
	var entry: Array = GROUPS[group]
	for index: int in range(1, int(entry[2]) + 1):
		files.append("%s/%s/%s_%02d.ogg" % [SFX_DIR, entry[0], entry[1], index])
	return files


## Recorte de volumen (dB) del grupo (0 si no existe).
static func volume_db_of(group: StringName) -> float:
	return float((GROUPS[group] as Array)[3]) if GROUPS.has(group) else 0.0


## El sonido del grupo con su variación de tono y volumen, o null si no hay ningún archivo cargable (el juego sigue
## sin sonido en vez de romperse).
static func stream_of(group: StringName) -> AudioStream:
	var loaded: Dictionary = _load(group)
	return loaded.get("stream") as AudioStream


## Grupo de un impacto en [param material]; con [param blocked] el golpe lo recibió un escudo (madera, o metal si
## quien bloquea lleva el borde de metal) y con [param parried] suena el choque de acero.
static func impact_group(material: Armor, blocked: bool = false, parried: bool = false) -> StringName:
	if parried:
		return &"clash_metal"
	if blocked:
		return &"hit_shield_metal" if material == Armor.SHIELD_METAL else &"hit_shield_wood"
	match material:
		Armor.LEATHER:
			return &"hit_leather"
		Armor.GAMBESON:
			return &"hit_gambeson"
		Armor.MAIL:
			return &"hit_mail"
		Armor.SHIELD_WOOD:
			return &"hit_shield_wood"
		Armor.SHIELD_METAL:
			return &"hit_shield_metal"
	return &"hit_flesh"


## Grupo de un paso en la superficie [param surface] (el agua del vado suena a tierra mojada: el mismo grupo con
## otro tono, ver [method step_pitch]).
static func step_group(surface: StringName) -> StringName:
	match surface:
		SURFACE_STONE:
			return &"step_stone"
		SURFACE_WOOD:
			return &"step_wood"
		SURFACE_DIRT, SURFACE_WATER:
			return &"step_dirt"
	return &"step_grass"


## Tono con el que se reproduce un paso en [param surface]: el agua baja el de tierra para que suene a chapoteo.
static func step_pitch(surface: StringName) -> float:
	return 0.72 if surface == SURFACE_WATER else 1.0


## Olvida lo cargado (las pruebas).
static func clear_cache() -> void:
	_cache.clear()


static func _load(group: StringName) -> Dictionary:
	if _cache.has(group):
		return _cache[group]
	var result: Dictionary = {}
	if GROUPS.has(group):
		var streams: Array[AudioStream] = []
		for path: String in files_of(group):
			if ResourceLoader.exists(path):
				var stream: AudioStream = load(path) as AudioStream
				if stream != null:
					streams.append(stream)
		if not streams.is_empty():
			var entry: Array = GROUPS[group]
			var randomizer: AudioStreamRandomizer = AudioDirector.make_variation(streams,
					float(entry[4]), float(entry[5]))
			result = {"stream": randomizer, "volume_db": float(entry[3])}
	_cache[group] = result
	return result
