class_name FakeSaveSection
extends RefCounted
## Una sección de guardado de pruebas para [CharacterSaver] (docs/plataforma.md §15 P5: «se prueba con una sección
## falsa»). Construye los seis totales de [code]pvp[/code] de cada cuerpo, así que [FakeZonePlatform] la devuelve en
## la reclamación siguiente como lo último aplicado. Sucia desde que cambia hasta que se confirma el
## [code]seq[/code] que llevaba el cambio; apunta cada llamada de [CharacterSaver] (con el tick de
## [member tick_source]) para que las pruebas vean cuándo y para quién se construye, se confirma o se pregunta.

## Nombre de la sección (la clave del cuerpo).
var name: StringName = &"pvp"
## Si es válido, [code]() -> int[/code]: el tick que se apunta en cada llamada.
var tick_source: Callable = Callable()
## net_id -> true: [method build] devuelve [code]{}[/code] (no se puede construir ahora).
var unbuildable: Dictionary[int, bool] = {}
## Llamadas a [method build]: [code][net_id, seq, tick, construido][/code].
var builds: Array[Array] = []
## Llamadas a [method acknowledge]: [code][net_id, seq][/code].
var acknowledged: Array[Array] = []
## net_id de cada llamada a [method is_dirty].
var dirty_checks: Array[int] = []

var _kills: Dictionary[int, int] = {}
var _version: Dictionary[int, int] = {}
var _confirmed: Dictionary[int, int] = {}
var _built: Dictionary[String, int] = {}


## Registra la sección en [param saver].
func attach(saver: CharacterSaver) -> void:
	saver.register_section(name, build, acknowledge, is_dirty)


## Cambia los totales de [param net_id] (las bajas): queda sucia.
func set_kills(net_id: int, kills: int) -> void:
	_kills[net_id] = kills
	_version[net_id] = _version.get(net_id, 0) + 1


## Los totales que construiría ahora para [param net_id].
func totals(net_id: int) -> Dictionary:
	return {"kills": _kills.get(net_id, 0), "deaths": 0, "assists": 0, "captures": 0, "gate_damage": 0,
			"defend_s": 0}


func build(net_id: int, seq: int) -> Dictionary:
	if unbuildable.get(net_id, false):
		builds.append([net_id, seq, _tick(), false])
		return {}
	builds.append([net_id, seq, _tick(), true])
	_built["%d:%d" % [net_id, seq]] = _version.get(net_id, 0)
	return totals(net_id)


func acknowledge(net_id: int, seq: int) -> void:
	acknowledged.append([net_id, seq])
	_confirmed[net_id] = maxi(_confirmed.get(net_id, 0), _built.get("%d:%d" % [net_id, seq], 0))


func is_dirty(net_id: int) -> bool:
	dirty_checks.append(net_id)
	return _version.get(net_id, 0) > _confirmed.get(net_id, 0)


## Los ticks en que se construyó (con éxito) un cuerpo para [param net_id].
func build_ticks(net_id: int) -> Array[int]:
	var ticks: Array[int] = []
	for call: Array in builds:
		if int(call[0]) == net_id and bool(call[3]):
			ticks.append(int(call[2]))
	return ticks


## Cuántas llamadas (de cualquier tipo) ha recibido para [param net_id].
func calls_for(net_id: int) -> int:
	var count: int = dirty_checks.count(net_id)
	for call: Array in builds:
		if int(call[0]) == net_id:
			count += 1
	for call: Array in acknowledged:
		if int(call[0]) == net_id:
			count += 1
	return count


func _tick() -> int:
	return int(tick_source.call()) if tick_source.is_valid() else -1
