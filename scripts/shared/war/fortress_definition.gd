class_name FortressDefinition
extends Resource
## Data of a capturable fort (docs/fortress.md, section 1.1), in
## [code]data/fortresses/<id>.tres[/code]. The zone scene points to it with the
## [code]definition[/code] metadata of the fort node ([constant Zones.FORTRESS_GROUP]).
## [br][br]
## Everything is expressed in seconds and converted to ticks with the [code]*_ticks()[/code]
## methods ([method CombatCatalog.seconds_to_ticks]), which are what [FortressState] uses. The
## radius of the capture circle is not here: it comes only from the [code]radius[/code] metadata of
## the scene's [code]CaptureCircle[/code] marker (5 m at Vado Gris).
## [br][br]
## Shared: depends on neither the client nor the server.

## Identifier of the fort (the key of [code]fortresses[/code] in [method RespawnRules.points_for]
## and the [code]fortress[/code] metadata of its respawn points).
@export var id: StringName = &"vado_gris_fort"
## Name in Spanish for war notices and the interface.
@export var display_name: String = "Fuerte del Vado Gris"
## Seconds the capture takes with a single attacker in the circle.
@export_range(1.0, 600.0, 0.5, "suffix:s") var capture_s: float = 30.0
## Seconds with the circle empty before progress starts to decay (at one third of the base speed).
@export_range(0.0, 120.0, 0.5, "suffix:s") var decay_after_empty_s: float = 5.0
## Height (m) of the capture circle's cylinder above its marker.
@export_range(1.0, 20.0, 0.5, "suffix:m") var circle_height_m: float = 4.0
## Gate health.
@export_range(1, 1000000) var gate_health: int = 9000
## Seconds of consolidation after a capture: inactive circle and damageable gate until the new
## owner's garrison arrives.
@export_range(0.0, 3600.0, 0.5, "suffix:s") var consolidation_s: float = 120.0
## Seconds until the dead captain respawns if nobody captures the fort.
@export_range(0.0, 3600.0, 0.5, "suffix:s") var captain_respawn_s: float = 300.0
## Seconds until the dead guards respawn.
@export_range(0.0, 3600.0, 0.5, "suffix:s") var guard_respawn_s: float = 180.0
## Seconds the fort counts as "under attack" after a hit on the gate or on a defender (it cannot be
## respawned at).
@export_range(0.0, 600.0, 0.5, "suffix:s") var under_attack_s: float = 30.0
## Seconds without damage after which the gate is repaired.
@export_range(0.0, 3600.0, 0.5, "suffix:s") var gate_repair_after_s: float = 300.0
## Seconds after which the fort returns to neutral (tests only; 0 = never).
@export_range(0.0, 86400.0, 1.0, "suffix:s") var reset_to_neutral_s: float = 1800.0


## Ticks the capture lasts with a single attacker.
func capture_ticks() -> int:
	return maxi(CombatCatalog.seconds_to_ticks(capture_s), 1)


## Ticks with the circle empty before decay starts.
func decay_after_empty_ticks() -> int:
	return CombatCatalog.seconds_to_ticks(decay_after_empty_s)


## Ticks of the consolidation.
func consolidation_ticks() -> int:
	return CombatCatalog.seconds_to_ticks(consolidation_s)


## Ticks until the captain respawns.
func captain_respawn_ticks() -> int:
	return CombatCatalog.seconds_to_ticks(captain_respawn_s)


## Ticks until the guards respawn.
func guard_respawn_ticks() -> int:
	return CombatCatalog.seconds_to_ticks(guard_respawn_s)


## Ticks the fort counts as under attack.
func under_attack_ticks() -> int:
	return CombatCatalog.seconds_to_ticks(under_attack_s)


## Ticks without damage after which the gate is repaired.
func gate_repair_after_ticks() -> int:
	return CombatCatalog.seconds_to_ticks(gate_repair_after_s)


## Ticks after which the fort returns to neutral (0 = never).
func reset_to_neutral_ticks() -> int:
	return CombatCatalog.seconds_to_ticks(reset_to_neutral_s)
