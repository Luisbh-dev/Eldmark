class_name LevelCurve
extends Resource
## Curva de experiencia (docs/progresion.md §6.1, PRG-13), en
## [code]data/progression/level_curve.tres[/code]: la XP que hace falta para pasar de cada nivel al
## siguiente, hasta el tope.
## [br][br]
## El dato es la tabla [member xp_to_next], no la fórmula con que se generó
## ([code]round((500 + 150 · (L − 1)^1,6) / 10) · 10[/code]): una cifra se puede retocar a mano sin
## cambiar las demás. La exporta [ProgressionRulesExport] (sección [code]level_curve[/code]) y la
## plataforma comprueba con ella el nivel de cada guardado (S6). Compartido: sin reloj ni azar.

## Ruta del recurso.
const PATH: String = "res://data/progression/level_curve.tres"

## Nivel máximo.
@export_range(2, 255) var level_cap: int = 40
## XP para pasar del nivel [code]i + 1[/code] al [code]i + 2[/code]: [code]level_cap − 1[/code] valores.
@export var xp_to_next: PackedInt32Array = PackedInt32Array()
## Puntos de atributo por nivel ganado (PRG-17; en la fase 5 se ven y no se gastan).
@export_range(0, 100) var attribute_points_per_level: int = 1

static var _shared: LevelCurve = null


## La curva de [constant PATH], cargada una vez. Si no se puede cargar, registra el error y devuelve
## una curva vacía (todo el mundo a nivel 1).
static func shared() -> LevelCurve:
	if _shared == null:
		_shared = ResourceLoader.load(PATH) as LevelCurve
		if _shared == null:
			push_error("[Eldmark] No se puede cargar la curva de niveles %s" % PATH)
			_shared = LevelCurve.new()
	return _shared


## XP total que hace falta para llegar a [param level] desde 0: 0 para el nivel 1 y, para el tope,
## lo que hace falta para llegar al tope. Fuera de [code]1..level_cap[/code], el extremo más cercano.
func total_to(level: int) -> int:
	var steps: int = mini(clampi(level, 1, level_cap) - 1, xp_to_next.size())
	var total: int = 0
	for i: int in range(steps):
		total += xp_to_next[i]
	return total


## Nivel que corresponde a [param xp_total] (I8): el mayor nivel cuyo [method total_to] no pasa de
## él, entre 1 y [member level_cap].
func level_for(xp_total: int) -> int:
	var level: int = 1
	var total: int = 0
	while level < level_cap and level - 1 < xp_to_next.size():
		total += xp_to_next[level - 1]
		if xp_total < total:
			break
		level += 1
	return level


## XP que falta para el nivel siguiente desde el principio de [param level]; 0 en el tope.
func xp_for_next(level: int) -> int:
	if level < 1 or level >= level_cap or level - 1 >= xp_to_next.size():
		return 0
	return xp_to_next[level - 1]


## Errores de los datos (vacío si la curva vale): tantos valores como pasos hasta el tope, todos
## mayores que 0.
func get_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if xp_to_next.size() != level_cap - 1:
		errors.append("xp_to_next tiene %d valores y el tope %d pide %d" % [xp_to_next.size(), level_cap,
				level_cap - 1])
	for i: int in range(xp_to_next.size()):
		if xp_to_next[i] <= 0:
			errors.append("xp_to_next[%d] = %d no es mayor que 0" % [i, xp_to_next[i]])
	return errors
