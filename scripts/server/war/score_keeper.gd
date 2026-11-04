class_name ScoreKeeper
extends RefCounted
## Battle scoreboard (docs/fuerte.md, section 6; UI-41): per player, kills, deaths, assists, damage
## to the gate, time in the circle, captures, defending time and merits. It is fed by the
## [ZoneServer] with the combat KILL and DEATH events and by the [FortressController] with the
## circle, the gate and the captures, and [method build_rows] gives the SCOREBOARD rows that are sent
## to the whole zone every 2 s.
## [br][br]
## [b]Provisional merits[/b] (the real rule arrives with PRG-09, with anti-farming and damage-based
## sharing): [code]kills × 10 + assists × 5 + seconds in the circle[/code]
## ([constant MERITS_PER_KILL], [constant MERITS_PER_ASSIST]). Against the same opponent they always
## yield the same: there is no anti-farming here.
## [br][br]
## [b]Persistence[/b] (docs/plataforma.md §7.1 and §8, GUE-19): with the platform, [method attach]
## registers the [code]pvp[/code] section of [CharacterSaver] (behind [code]progress[/code]). Each
## body carries the totals loaded in the claim ([method load_totals], from
## [member ClaimedCharacter.pvp]) plus those of the session:
## [code]{kills, deaths, assists, captures, gate_damage, defend_s}[/code], with
## [code]defend_s = loaded + defend_ticks / 60[/code]. It is dirty while those totals are not those
## of the last confirmed body. Since [method CharacterSaver.finish] builds the snapshot at that
## moment, the "Exit" (the logout flow) calls it before [method forget].

## Merits for each kill and for each assist.
const MERITS_PER_KILL: int = 10
const MERITS_PER_ASSIST: int = 5
## Name of the save section (the body key, §7.3).
const SECTION: StringName = &"pvp"
## Cap of the totals that the platform stores in [code]int[/code] columns (2^31 − 1) and of
## [code]gate_damage[/code], a [code]bigint[/code] that travels as an exact JSON number (2^53 − 1): a
## larger total would be an [code]invalid_save[/code] (§7.3). With [code]greatest[/code] on the
## platform, clamping it lowers nothing.
const MAX_INT4_TOTAL: int = 2147483647
const MAX_GATE_DAMAGE_TOTAL: int = (1 << 53) - 1


## Counters of one player.
class Entry:
	extends RefCounted

	var kills: int = 0
	var deaths: int = 0
	var assists: int = 0
	var gate_damage: int = 0
	## Ticks spent inside an active capture circle.
	var circle_ticks: int = 0
	## Captures in which it was on the [FortressController] list (docs/plataforma.md §8).
	var captures: int = 0
	## Ticks in the active circle of a fortress of its realm (the owner), for [code]defend_s[/code].
	var defend_ticks: int = 0


	## Whole seconds in the circle.
	func circle_seconds() -> int:
		@warning_ignore("integer_division")
		return circle_ticks / CombatCatalog.TICK_RATE


	## Whole seconds defending.
	func defend_seconds() -> int:
		@warning_ignore("integer_division")
		return defend_ticks / CombatCatalog.TICK_RATE


	## Provisional merits of this player.
	func merits() -> int:
		return kills * MERITS_PER_KILL + assists * MERITS_PER_ASSIST + circle_seconds()


# net_id -> counters.
var _entries: Dictionary[int, Entry] = {}
# net_id -> totals loaded in the claim (the six of ClaimedCharacter.PVP_KEYS).
var _loaded: Dictionary[int, Dictionary] = {}
# net_id -> totals of the last confirmed body (acknowledge); without it, the loaded ones.
var _acknowledged: Dictionary[int, Dictionary] = {}
# net_id -> {seq: totals} of the bodies built but not yet confirmed.
var _built: Dictionary[int, Dictionary] = {}


## A kill by [param net_id].
func add_kill(net_id: int) -> void:
	_entry(net_id).kills += 1


## A death of [param net_id].
func add_death(net_id: int) -> void:
	_entry(net_id).deaths += 1


## An assist by [param net_id].
func add_assist(net_id: int) -> void:
	_entry(net_id).assists += 1


## [param amount] of damage to the gate by [param net_id].
func add_gate_damage(net_id: int, amount: int) -> void:
	if amount > 0:
		_entry(net_id).gate_damage += amount


## [param ticks] spent by [param net_id] inside an active circle.
func add_circle_ticks(net_id: int, ticks: int) -> void:
	if ticks > 0:
		_entry(net_id).circle_ticks += ticks


## A capture by [param net_id] (it was on the capture list, docs/plataforma.md §8).
func add_capture(net_id: int) -> void:
	_entry(net_id).captures += 1


## [param ticks] spent defending by [param net_id]: inside the active circle of a fortress of its realm.
func add_defend_ticks(net_id: int, ticks: int) -> void:
	if ticks > 0:
		_entry(net_id).defend_ticks += ticks


## Counters of [param net_id], or null if it does not have any yet.
func get_entry(net_id: int) -> Entry:
	return _entries.get(net_id)


## Deletes the counters of [param net_id] and what is known about its section (it leaves the world:
## its id may be reused).
func forget(net_id: int) -> void:
	_entries.erase(net_id)
	_loaded.erase(net_id)
	_acknowledged.erase(net_id)
	_built.erase(net_id)


## Deletes everything.
func clear() -> void:
	_entries.clear()
	_loaded.clear()
	_acknowledged.clear()
	_built.clear()


## Players with counters.
func size() -> int:
	return _entries.size()


## The SCOREBOARD rows of [param net_ids] (in the given order; those without counters come out at
## zero).
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


# --- pvp section of CharacterSaver (docs/plataforma.md §7.1 and §8) ------------------------------

## Registers the [constant SECTION] section in [param saver] (with the platform, behind the
## [code]progress[/code] one). A section registered later with the same name replaces it.
func attach(saver: CharacterSaver) -> void:
	saver.register_section(SECTION, build_section, acknowledge_section, is_section_dirty)


## The totals brought by the claim of [param net_id] ([member ClaimedCharacter.pvp]): the base of its
## section. Without calling it, the base is 0 for everything.
func load_totals(net_id: int, pvp: Dictionary) -> void:
	var base: Dictionary = {}
	for key: String in ClaimedCharacter.PVP_KEYS:
		var value: Variant = pvp.get(key, 0)
		base[key] = maxi(int(value), 0) if value is int or value is float else 0
	_loaded[net_id] = base
	_acknowledged[net_id] = base.duplicate()
	_built.erase(net_id)


## The totals of [param net_id] now: the loaded ones plus those of the session, clamped to what fits
## on the platform.
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


## [code]build(net_id, seq)[/code] of the section: the totals as of now (never [code]{}[/code]).
func build_section(net_id: int, seq: int) -> Dictionary:
	var totals: Dictionary = pvp_totals(net_id)
	if not _built.has(net_id):
		_built[net_id] = {}
	(_built[net_id] as Dictionary)[seq] = totals.duplicate()
	return totals


## [code]acknowledge(net_id, seq)[/code]: body [param seq] was applied; what was built up to it
## becomes confirmed.
func acknowledge_section(net_id: int, seq: int) -> void:
	var built: Dictionary = _built.get(net_id, {})
	if built.has(seq):
		_acknowledged[net_id] = built[seq]
	for key: int in built.keys():
		if key <= seq:
			built.erase(key)


## [code]is_dirty(net_id)[/code]: the totals as of now are not those of the last confirmed body (or the
## loaded ones).
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
