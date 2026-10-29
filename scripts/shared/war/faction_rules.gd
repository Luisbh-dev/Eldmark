class_name FactionRules
extends RefCounted
## Quién puede dañar a quién (docs/combate.md, sección 5): una regla pura sobre los códigos de
## bando de red de [RealmCatalog] (1 Vardheim, 2 Solmarch, 3 Askarra, 0 los Huecos neutrales) y
## el modo PvP de la zona ([method Zones.get_pvp_mode]).
## [br][br]
## Las zonas seguras (campamentos) y la protección de reaparición son aparte: las comprueba el
## servidor al resolver el golpe.
## [br][br]
## Compartido: no depende del cliente ni del servidor.


## true si un atacante del bando [param attacker_realm] puede dañar a una víctima del bando
## [param victim_realm] en la zona [param zone_id]:
## [br]- Nunca entre miembros del mismo bando (sin fuego amigo, tampoco entre Huecos).
## [br]- Los Huecos (código [constant RealmCatalog.NEUTRAL_CODE]) son hostiles a todos los reinos,
## y los reinos a ellos, en cualquier zona.
## [br]- Dos reinos enemigos solo se dañan en una zona RVR ([constant Zones.PvpMode.RVR]); en una
## zona segura o desconocida, no.
## [br]- Un código que no es un bando del catálogo no daña ni recibe daño.
static func can_damage(attacker_realm: int, victim_realm: int, zone_id: StringName) -> bool:
	if not _is_faction_code(attacker_realm) or not _is_faction_code(victim_realm):
		return false
	if attacker_realm == victim_realm:
		return false
	if attacker_realm == RealmCatalog.NEUTRAL_CODE or victim_realm == RealmCatalog.NEUTRAL_CODE:
		return true
	return Zones.get_pvp_mode(zone_id) == Zones.PvpMode.RVR


## true si [param code] es el código de un reino jugable o el del bando neutral.
static func _is_faction_code(code: int) -> bool:
	return code == RealmCatalog.NEUTRAL_CODE or RealmCatalog.is_realm_code(code)
