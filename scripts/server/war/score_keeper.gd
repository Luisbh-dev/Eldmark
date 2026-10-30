class_name ScoreKeeper
extends RefCounted
## Marcador de la batalla (docs/fuerte.md, sección 6; UI-41): por jugador, bajas, muertes,
## asistencias, daño a la puerta, tiempo en el círculo, capturas, tiempo defendiendo y méritos. Lo alimenta el
## [ZoneServer] con los KILL y DEATH del combate y el [FortressController] con el círculo, la puerta y las
## capturas, y [method build_rows] da las filas del SCOREBOARD que se manda a toda la zona cada 2 s.
## [br][br]
## [b]Méritos provisionales[/b] (la regla de verdad llega con PRG-09, con antifarmeo y reparto por
## daño): [code]bajas × 10 + asistencias × 5 + segundos en el círculo[/code]
## ([constant MERITS_PER_KILL], [constant MERITS_PER_ASSIST]). Contra el mismo rival rinden siempre
## igual: aquí no hay antifarmeo.
## [br][br]
## [b]Persistencia[/b] (docs/plataforma.md §7.1 y §8, GUE-19): con la plataforma, [method attach] registra la
## sección [code]pvp[/code] de [CharacterSaver] (detrás de [code]progress[/code]). Cada cuerpo lleva los totales
## cargados en la reclamación ([method load_totals], de [member ClaimedCharacter.pvp]) más los de la sesión:
## [code]{kills, deaths, assists, captures, gate_damage, defend_s}[/code], con
## [code]defend_s = cargado + defend_ticks / 60[/code]. Está sucia mientras esos totales no son los del último
## cuerpo confirmado. Como [method CharacterSaver.finish] construye la foto en el momento, la «Salida» lo llama
## antes de [method forget].

## Méritos por cada baja y por cada asistencia.
const MERITS_PER_KILL: int = 10
const MERITS_PER_ASSIST: int = 5
## Nombre de la sección del guardado (la clave del cuerpo, §7.3).
const SECTION: StringName = &"pvp"
## Tope de los totales que la plataforma guarda en columnas [code]int[/code] (2^31 − 1) y de
## [code]gate_damage[/code], [code]bigint[/code] que viaja como número JSON exacto (2^53 − 1): un total mayor
## sería un [code]invalid_save[/code] (§7.3). Con [code]greatest[/code] en la plataforma, recortarlo no baja nada.
const MAX_INT4_TOTAL: int = 2147483647
const MAX_GATE_DAMAGE_TOTAL: int = (1 << 53) - 1


## Contadores de un jugador.
class Entry:
	extends RefCounted

	var kills: int = 0
	var deaths: int = 0
	var assists: int = 0
	var gate_damage: int = 0
	## Ticks pasados dentro de un círculo de captura activo.
	var circle_ticks: int = 0
	## Capturas en las que estaba en la lista de [FortressController] (docs/plataforma.md §8).
	var captures: int = 0
	## Ticks en el círculo activo de una fortaleza de su reino (el dueño), para [code]defend_s[/code].
	var defend_ticks: int = 0


	## Segundos enteros en el círculo.
	func circle_seconds() -> int:
		@warning_ignore("integer_division")
		return circle_ticks / CombatCatalog.TICK_RATE


	## Segundos enteros defendiendo.
	func defend_seconds() -> int:
		@warning_ignore("integer_division")
		return defend_ticks / CombatCatalog.TICK_RATE


	## Méritos provisionales de este jugador.
	func merits() -> int:
		return kills * MERITS_PER_KILL + assists * MERITS_PER_ASSIST + circle_seconds()


# net_id -> contadores.
var _entries: Dictionary[int, Entry] = {}
# net_id -> totales cargados en la reclamación (los seis de ClaimedCharacter.PVP_KEYS).
var _loaded: Dictionary[int, Dictionary] = {}
# net_id -> totales del último cuerpo confirmado (acknowledge); sin él, los cargados.
var _acknowledged: Dictionary[int, Dictionary] = {}
# net_id -> {seq: totales} de los cuerpos construidos aún sin confirmar.
var _built: Dictionary[int, Dictionary] = {}


## Una baja de [param net_id].
func add_kill(net_id: int) -> void:
	_entry(net_id).kills += 1


## Una muerte de [param net_id].
func add_death(net_id: int) -> void:
	_entry(net_id).deaths += 1


## Una asistencia de [param net_id].
func add_assist(net_id: int) -> void:
	_entry(net_id).assists += 1


## [param amount] de daño a la puerta de [param net_id].
func add_gate_damage(net_id: int, amount: int) -> void:
	if amount > 0:
		_entry(net_id).gate_damage += amount


## [param ticks] pasados por [param net_id] dentro de un círculo activo.
func add_circle_ticks(net_id: int, ticks: int) -> void:
	if ticks > 0:
		_entry(net_id).circle_ticks += ticks


## Una captura de [param net_id] (estaba en la lista de la captura, docs/plataforma.md §8).
func add_capture(net_id: int) -> void:
	_entry(net_id).captures += 1


## [param ticks] defendiendo de [param net_id]: dentro del círculo activo de una fortaleza de su reino.
func add_defend_ticks(net_id: int, ticks: int) -> void:
	if ticks > 0:
		_entry(net_id).defend_ticks += ticks


## Contadores de [param net_id], o null si todavía no tiene ninguno.
func get_entry(net_id: int) -> Entry:
	return _entries.get(net_id)


## Borra los contadores de [param net_id] y lo que se sabe de su sección (se va del mundo: su id puede
## reutilizarse).
func forget(net_id: int) -> void:
	_entries.erase(net_id)
	_loaded.erase(net_id)
	_acknowledged.erase(net_id)
	_built.erase(net_id)


## Borra todo.
func clear() -> void:
	_entries.clear()
	_loaded.clear()
	_acknowledged.clear()
	_built.clear()


## Jugadores con contadores.
func size() -> int:
	return _entries.size()


## Las filas del SCOREBOARD de [param net_ids] (en el orden dado; los que no tienen contadores salen a
## cero).
func build_rows(net_ids: Array[int]) -> Array[NetMessages.ScoreRow]:
	var rows: Array[NetMessages.ScoreRow] = []
	for net_id: int in net_ids:
		var entry: Entry = _entries.get(net_id)
		if entry == null:
			rows.append(NetMessages.ScoreRow.make(net_id, 0, 0, 0, 0, 0, 0))
		else:
			rows.append(NetMessages.ScoreRow.make(net_id, entry.kills, entry.deaths,
					entry.assists, entry.gate_damage, entry.circle_seconds(), entry.merits()))
	return rows


# --- Sección pvp de CharacterSaver (docs/plataforma.md §7.1 y §8) -------------------------------

## Registra la sección [constant SECTION] en [param saver] (con la plataforma, detrás de la de
## [code]progress[/code]). Una sección registrada después con el mismo nombre la sustituye.
func attach(saver: CharacterSaver) -> void:
	saver.register_section(SECTION, build_section, acknowledge_section, is_section_dirty)


## Los totales que trae la reclamación de [param net_id] ([member ClaimedCharacter.pvp]): la base de su sección.
## Sin llamarla, la base es 0 en todo.
func load_totals(net_id: int, pvp: Dictionary) -> void:
	var base: Dictionary = {}
	for key: String in ClaimedCharacter.PVP_KEYS:
		var value: Variant = pvp.get(key, 0)
		base[key] = maxi(int(value), 0) if value is int or value is float else 0
	_loaded[net_id] = base
	_acknowledged[net_id] = base.duplicate()
	_built.erase(net_id)


## Los totales de [param net_id] ahora: los cargados más los de la sesión, recortados a lo que cabe en la
## plataforma.
func pvp_totals(net_id: int) -> Dictionary:
	var base: Dictionary = _loaded.get(net_id, {})
	var entry: Entry = _entries.get(net_id)
	var session: Dictionary = {
		"kills": entry.kills if entry != null else 0,
		"deaths": entry.deaths if entry != null else 0,
		"assists": entry.assists if entry != null else 0,
		"captures": entry.captures if entry != null else 0,
		"gate_damage": entry.gate_damage if entry != null else 0,
		"defend_s": entry.defend_seconds() if entry != null else 0,
	}
	var totals: Dictionary = {}
	for key: String in ClaimedCharacter.PVP_KEYS:
		var cap: int = MAX_GATE_DAMAGE_TOTAL if key == "gate_damage" else MAX_INT4_TOTAL
		totals[key] = mini(int(base.get(key, 0)) + int(session[key]), cap)
	return totals


## [code]build(net_id, seq)[/code] de la sección: los totales de ahora (nunca [code]{}[/code]).
func build_section(net_id: int, seq: int) -> Dictionary:
	var totals: Dictionary = pvp_totals(net_id)
	if not _built.has(net_id):
		_built[net_id] = {}
	(_built[net_id] as Dictionary)[seq] = totals.duplicate()
	return totals


## [code]acknowledge(net_id, seq)[/code]: el cuerpo [param seq] se aplicó; lo construido hasta él queda confirmado.
func acknowledge_section(net_id: int, seq: int) -> void:
	var built: Dictionary = _built.get(net_id, {})
	if built.has(seq):
		_acknowledged[net_id] = built[seq]
	for key: int in built.keys():
		if key <= seq:
			built.erase(key)


## [code]is_dirty(net_id)[/code]: los totales de ahora no son los del último cuerpo confirmado (o los cargados).
func is_section_dirty(net_id: int) -> bool:
	var confirmed: Dictionary = _acknowledged.get(net_id, _loaded.get(net_id, {}))
	var totals: Dictionary = pvp_totals(net_id)
	for key: String in ClaimedCharacter.PVP_KEYS:
		if int(confirmed.get(key, 0)) != int(totals[key]):
			return true
	return false


func _entry(net_id: int) -> Entry:
	var found: Entry = _entries.get(net_id)
	if found == null:
		found = Entry.new()
		_entries[net_id] = found
	return found
