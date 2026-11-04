class_name RealmCatalog
extends RefCounted
## Shared catalog of realms and sides (docs/mundo.md, "Side colors").
## [br][br]
## Single source for the three playable realms and the neutral side of the Hollow. For each one:
## id ([StringName]), network code, name in Spanish, side color and emblem path. It also stores
## the realms admitted in each zone. [Zones], [NetZones], [NetProtocol], [ServerAuth] and the
## banners read from here, so adding or changing a side is done in this file only.
## [br][br]
## The network codes are those of [enum NetProtocol.Realm] (1 Vardheim, 2 Solmarch, 3 Askarra).
## The code [constant NEUTRAL_CODE] (0) is the neutral side of the Hollow: it is the same value as
## [constant NetProtocol.Realm.NONE], which in the HELLO means "no realm" and is rejected, but a
## player is never neutral, so there is no ambiguity.
## [br][br]
## It does not depend on anything in [code]scripts/client/[/code] or [code]scripts/server/[/code].

## Ids of the sides.
const VARDHEIM: StringName = &"vardheim"
const SOLMARCH: StringName = &"solmarch"
const ASKARRA: StringName = &"askarra"
## Neutral side: the Hollow, undead soldiers of Eld's old garrison.
const HUECOS: StringName = &"huecos"

## Side colors (mundo.md): ice blue, gold, crimson and bone gray.
const VARDHEIM_COLOR: Color = Color("#7EC8E8")
const SOLMARCH_COLOR: Color = Color("#E9C341")
const ASKARRA_COLOR: Color = Color("#C3242F")
const HUECOS_COLOR: Color = Color("#BDB6A6")

## Network code of the neutral side.
const NEUTRAL_CODE: int = 0
## Path of a side's emblem, with [code]%s[/code] in place of the id. The SVGs are supplied by the
## art (UI-02); until then the file may not exist, so whoever loads it must check.
const EMBLEM_PATH_FORMAT: String = "res://assets/emblems/%s.svg"

## The three playable realms, in network code order.
const REALM_IDS: Array[StringName] = [VARDHEIM, SOLMARCH, ASKARRA]
## All sides: the three realms and the neutral one.
const FACTION_IDS: Array[StringName] = [VARDHEIM, SOLMARCH, ASKARRA, HUECOS]

## Id -> {code, name, color}.
const _FACTIONS: Dictionary = {
	VARDHEIM: {"code": NetProtocol.Realm.VARDHEIM, "name": "Vardheim", "color": VARDHEIM_COLOR},
	SOLMARCH: {"code": NetProtocol.Realm.SOLMARCH, "name": "Solmarch", "color": SOLMARCH_COLOR},
	ASKARRA: {"code": NetProtocol.Realm.ASKARRA, "name": "Askarra", "color": ASKARRA_COLOR},
	HUECOS: {"code": NEUTRAL_CODE, "name": "Huecos", "color": HUECOS_COLOR},
}

## Zone -> admitted realms (ids). A zone not listed here has no registered restriction.
## Vado Gris is the border between Vardheim and Solmarch (mundo.md): Askarra does not enter.
const _ZONE_REALMS: Dictionary = {
	&"vado_gris": [VARDHEIM, SOLMARCH],
	&"test_world": [VARDHEIM, SOLMARCH, ASKARRA],
}


## true if [param id] is a playable realm (not the neutral side).
static func is_realm(id: StringName) -> bool:
	return REALM_IDS.has(id)


## true if [param id] is a side in the catalog: a realm or the Hollow.
static func has_faction(id: StringName) -> bool:
	return _FACTIONS.has(id)


## true if [param code] is the network code of a playable realm (1 to 3).
static func is_realm_code(code: int) -> bool:
	return is_realm(id_of_code(code))


## Network codes of the playable realms, in order.
static func realm_codes() -> Array[int]:
	var codes: Array[int] = []
	for id: StringName in REALM_IDS:
		codes.append(code_of(id))
	return codes


## Network code of [param id], or -1 if the side does not exist.
static func code_of(id: StringName) -> int:
	var entry: Dictionary = _FACTIONS.get(id, {})
	return entry.get("code", -1)


## Id of the side with network code [param code] (0 = the Hollow), or an empty string if there is
## none.
static func id_of_code(code: int) -> StringName:
	for id: StringName in FACTION_IDS:
		if code_of(id) == code:
			return id
	return &""


## Name in Spanish of [param id] ("Vardheim", "Huecos"...), or an empty string if it does not
## exist.
static func display_name(id: StringName) -> String:
	var entry: Dictionary = _FACTIONS.get(id, {})
	return entry.get("name", "")


## Side color of [param id]; white if the side does not exist.
static func color_of(id: StringName) -> Color:
	var entry: Dictionary = _FACTIONS.get(id, {})
	return entry.get("color", Color.WHITE)


## Expected path of the emblem of [param id] (see [constant EMBLEM_PATH_FORMAT]), or an empty
## string if the side does not exist. The file may not exist yet.
static func emblem_path(id: StringName) -> String:
	if not has_faction(id):
		return ""
	return EMBLEM_PATH_FORMAT % String(id)


## Realms admitted in [param zone_id] as ids. Empty if the zone has no registered restriction
## (unknown zone): the caller decides what to do then.
static func allowed_realm_ids(zone_id: StringName) -> Array[StringName]:
	var result: Array[StringName] = []
	result.assign(_ZONE_REALMS.get(zone_id, []))
	return result


## Zones with registered admitted realms, sorted.
static func zones_with_realms() -> Array[StringName]:
	var ids: Array[StringName] = []
	ids.assign(_ZONE_REALMS.keys())
	ids.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	return ids
