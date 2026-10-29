class_name BattleLog
extends RefCounted
## Telemetría de la batalla (GUE-17; docs/fuerte.md, sección 7): los eventos de guerra y las muertes en
## un archivo JSON Lines ([code]--battle-log=<ruta>[/code]), una línea por evento, que resume
## [code]tools/war/summarize_battle.gd[/code] ([BattleSummary]).
## [br][br]
## Cada línea es un objeto con [code]tick[/code] y [code]event[/code]:
## [codeblock]
## {"tick":0,"event":"battle_start","zone":"vado_gris","fortresses":[{"id":"vado_gris_fort",
##    "position":[0,10.2,0],"gate":[-20,10.2,0],"circle":[-8.5,10.25,0],"radius":5}]}
## {"tick":812,"event":"war","war":"capture_started","realm":1,"fortress":"vado_gris_fort",
##    "position":[-8.5,10.25,0]}
## {"tick":820,"event":"gate_damage_started","fortress":"vado_gris_fort","position":[-20,10.2,0]}
## {"tick":901,"event":"death","victim":4,"victim_name":"Ana","victim_realm":2,"victim_kind":"player","killer":3,
##    "killer_name":"Bo","killer_realm":1,"attack":2,"position":[-30,7.1,12]}
## [/codeblock]
## [code]war[/code] es la clave interna de [WarEvents] ([method WarEvents.key_of]); [code]realm[/code], el
## código de red del reino que acompaña al aviso. Un [code]killer[/code] 0 es el entorno.

var _file: FileAccess = null


## Abre (y vacía) el archivo [param path], creando las carpetas que falten. null si no se puede.
static func open(path: String) -> BattleLog:
	if path.is_empty():
		return null
	var directory: String = path.get_base_dir()
	if not directory.is_empty() and not DirAccess.dir_exists_absolute(directory):
		DirAccess.make_dir_recursive_absolute(directory)
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("[Eldmark] No se pudo abrir el registro de batalla '%s' (error %d)"
				% [path, FileAccess.get_open_error()])
		return null
	var battle_log := BattleLog.new()
	battle_log._file = file
	return battle_log


## true mientras el archivo está abierto.
func is_open() -> bool:
	return _file != null


## Primera línea: la zona y, de cada fortaleza, su id, su posición, la de su puerta y su círculo.
## [param fortresses] son diccionarios con [code]id[/code], [code]position[/code], [code]gate[/code],
## [code]circle[/code] y [code]radius[/code].
func log_start(zone_id: String, fortresses: Array[Dictionary]) -> void:
	var entries: Array = []
	for fortress: Dictionary in fortresses:
		entries.append({
			"id": String(fortress.get("id", "")),
			"position": _vec(fortress.get("position", Vector3.ZERO)),
			"gate": _vec(fortress.get("gate", Vector3.ZERO)),
			"circle": _vec(fortress.get("circle", Vector3.ZERO)),
			"radius": snappedf(float(fortress.get("radius", 0.0)), 0.01),
		})
	_write(0, "battle_start", {"zone": zone_id, "fortresses": entries})


## Un aviso de guerra ([param war_event]: id de [WarEvents]) de [param fortress_id], con el reino que lo
## acompaña y la posición de la fortaleza.
func log_war(tick: int, war_event: int, realm: int, fortress_id: StringName,
		position: Vector3) -> void:
	_write(tick, "war", {"war": String(WarEvents.key_of(war_event)), "realm": realm,
			"fortress": String(fortress_id), "position": _vec(position)})


## La primera vez que se daña la puerta entera de [param fortress_id].
func log_gate_damage_started(tick: int, fortress_id: StringName, position: Vector3) -> void:
	_write(tick, "gate_damage_started", {"fortress": String(fortress_id),
			"position": _vec(position)})


## Una muerte: [param victim] y, si lo hay, [param killer] (null = el entorno), con el ataque y el
## lugar donde cayó el muerto.
func log_death(tick: int, victim: NetEntity, killer: NetEntity, attack_id: int,
		position: Vector3) -> void:
	_write(tick, "death", {
		"victim": victim.net_id if victim != null else 0,
		"victim_name": victim.display_name if victim != null else "",
		"victim_realm": victim.realm if victim != null else 0,
		"victim_kind": "player" if victim != null and victim.kind == NetProtocol.EntityKind.PLAYER \
				else "npc",
		"killer": killer.net_id if killer != null else 0,
		"killer_name": killer.display_name if killer != null else "",
		"killer_realm": killer.realm if killer != null else 0,
		"attack": attack_id,
		"position": _vec(position),
	})


## Vuelca lo escrito a disco.
func flush() -> void:
	if _file != null:
		_file.flush()


## Cierra el archivo.
func close() -> void:
	if _file != null:
		_file.close()
		_file = null


func _write(tick: int, event_name: String, fields: Dictionary) -> void:
	if _file == null:
		return
	var line: Dictionary = {"tick": tick, "event": event_name}
	line.merge(fields)
	_file.store_line(JSON.stringify(line))


static func _vec(value: Variant) -> Array:
	var vector: Vector3 = value as Vector3
	return [snappedf(vector.x, 0.01), snappedf(vector.y, 0.01), snappedf(vector.z, 0.01)]
