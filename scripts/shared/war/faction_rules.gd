class_name FactionRules
extends RefCounted
## Who can damage whom (docs/combate.md, section 5): a pure rule over the [RealmCatalog] network
## side codes (1 Vardheim, 2 Solmarch, 3 Askarra, 0 the neutral Hollow) and the zone's PvP mode
## ([method Zones.get_pvp_mode]).
## [br][br]
## Safe zones (camps) and respawn protection are separate: the server checks them when resolving
## the hit.
## [br][br]
## Shared: depends on neither the client nor the server.


## true if an attacker of side [param attacker_realm] can damage a victim of side
## [param victim_realm] in zone [param zone_id]:
## [br]- Never between members of the same side (no friendly fire, not even among the Hollow).
## [br]- The Hollow (code [constant RealmCatalog.NEUTRAL_CODE]) is hostile to all realms, and the
## realms to it, in any zone.
## [br]- Two enemy realms only damage each other in an RvR zone ([constant Zones.PvpMode.RVR]); in
## a safe or unknown zone, they do not.
## [br]- A code that is not a side in the catalog neither deals nor receives damage.
static func can_damage(attacker_realm: int, victim_realm: int, zone_id: StringName) -> bool:
	if not _is_faction_code(attacker_realm) or not _is_faction_code(victim_realm):
		return false
	if attacker_realm == victim_realm:
		return false
	if attacker_realm == RealmCatalog.NEUTRAL_CODE or victim_realm == RealmCatalog.NEUTRAL_CODE:
		return true
	return Zones.get_pvp_mode(zone_id) == Zones.PvpMode.RVR


## true if [param code] is the code of a playable realm or of the neutral side.
static func _is_faction_code(code: int) -> bool:
	return code == RealmCatalog.NEUTRAL_CODE or RealmCatalog.is_realm_code(code)
