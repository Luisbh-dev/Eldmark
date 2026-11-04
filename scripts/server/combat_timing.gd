class_name CombatTiming
extends RefCounted
## Combat time limits used only by the server, already in ticks (docs/combate.md, section 2). They come from
## [CombatRules] (seconds in the [code].tres[/code] files) with [code]roundi(s · 60)[/code], like the rest
## of the catalog.
## [br][br]
## Tests shorten the long limits (respawn, for example) by changing these fields on the
## [CombatTiming] exposed by [method ZoneServer.get_combat_timing]; the default values are
## those of the data.

## Seconds after death at which respawn happens on its own if the player does not request it.
const AUTO_RESPAWN_S: float = 30.0
## Seconds without taking damage after which the training dummy fully heals.
const DUMMY_HEAL_S: float = 5.0
## How many ticks between respawn waves in a zone with a fortress (10 s).
const WAVE_TICKS: int = 600
## Ticks of lead with which a RESPAWN_REQUEST is accepted before [member Combatant.respawn_tick]:
## the client counts the server's tick ahead (it carries its inputs' lead), so
## its button may arrive a couple of ticks before the server allows it. The request stays
## pending until the time comes.
const RESPAWN_REQUEST_SLACK_TICKS: int = 12

## Ticks "in combat" after dealing or receiving damage.
var in_combat: int = 600
## Ticks from death until respawning is possible.
var respawn: int = 600
## Ticks after death at which respawn happens on its own (at the realm's first point); with waves, in the
## first wave from there on ([method auto_respawn_tick_for]).
var auto_respawn: int = 1800
## Ticks of protection after respawning.
var protection: int = 180
## Respawn waves (docs/fuerte.md, section 5; GUE-14): if greater than 1, nobody respawns outside
## a multiple of this number of ticks (the first one that falls [member respawn] ticks or more after
## death if they request it, and the first one [member auto_respawn] ticks or more after if they do not). 0 = no waves,
## respawn at [member respawn] ticks. The server sets it to [constant WAVE_TICKS] in zones with a
## fortress.
var respawn_wave_ticks: int = 0
## Window (ticks) in which chained controls are counted, and ticks of immunity after the chain.
var cc_window: int = 180
var cc_immunity: int = 120
## Ticks of stagger for the parried attacker and of stun after a guard break.
var parry_stagger: int = 36
var guard_break_stun: int = 60
## Ticks without damage after which the dummy heals.
var dummy_heal: int = 300


## The time limits of [param rules] in ticks.
static func from_rules(rules: CombatRules) -> CombatTiming:
	var timing := CombatTiming.new()
	timing.in_combat = seconds_to_ticks(rules.in_combat_s)
	timing.respawn = seconds_to_ticks(rules.respawn_s)
	timing.auto_respawn = maxi(seconds_to_ticks(AUTO_RESPAWN_S), timing.respawn)
	timing.protection = seconds_to_ticks(rules.respawn_protection_s)
	timing.cc_window = seconds_to_ticks(rules.cc_chain_window_s)
	timing.cc_immunity = seconds_to_ticks(rules.cc_immunity_s)
	timing.parry_stagger = seconds_to_ticks(rules.parry_stagger_s)
	timing.guard_break_stun = seconds_to_ticks(rules.guard_break_stun_s)
	timing.dummy_heal = seconds_to_ticks(DUMMY_HEAL_S)
	return timing


## Seconds to simulation ticks ([constant CombatCatalog.TICK_RATE] per second), rounding.
static func seconds_to_ticks(seconds: float) -> int:
	return roundi(seconds * float(CombatCatalog.TICK_RATE))


## First tick at which whoever dies at [param death_tick] can respawn: [member respawn] ticks
## later or, with waves ([member respawn_wave_ticks]), the first wave multiple from there on.
func respawn_tick_for(death_tick: int) -> int:
	return _on_wave(death_tick + respawn)


## Tick at which whoever dies at [param death_tick] and has not requested it respawns on their own: [member auto_respawn]
## ticks later or, with waves, the first wave multiple from there on (automatic respawn
## also comes out in a wave).
func auto_respawn_tick_for(death_tick: int) -> int:
	return _on_wave(death_tick + auto_respawn)


# [param earliest] or, with waves, the first wave multiple that is not earlier.
func _on_wave(earliest: int) -> int:
	if respawn_wave_ticks <= 1:
		return earliest
	@warning_ignore("integer_division")
	return ((earliest + respawn_wave_ticks - 1) / respawn_wave_ticks) * respawn_wave_ticks
