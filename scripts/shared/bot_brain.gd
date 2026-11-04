class_name BotBrain
extends RefCounted
## Brain of a bot: generates deterministic player inputs for tests and load.
##
## It is used by the client bots (phase 2) and the server's fake players. It is a function of
## (seed, call sequence): it reads neither the clock nor global randomness, only its own
## [RandomNumberGenerator]. With the same seed and the same positions, it always produces the same
## inputs.
## [br][br]
## Patterns ([enum Pattern]):
## [br]- [constant WANDER]: strolls. Every 60-180 ticks it changes direction or stops for a moment,
## sometimes sprints and jumps from time to time.
## [br]- [constant CIRCLE]: circles around [code]home[/code] at half the radius.
## [br]- [constant IDLE]: does nothing (neutral inputs).
## [br]- [constant JUMPY]: like [constant WANDER], but jumps almost whenever it can.
## [br]- [constant COMBAT]: looks for the nearest enemy (given by [method set_enemy_finder]), approaches,
## attacks (light attacks in a combo and, sometimes, a charged heavy one), and now and then blocks or dodges.
## With no enemy in sight it strolls like [constant WANDER] (without jumping). Everything comes from its seeded
## generator, so with the same seed and the same positions it always does the same.
## [br]- [constant SIEGE] (GUE-15, docs/fortress.md section 7): besieges or defends a fort. It needs a
## [SiegeView] and some [ApproachRoutes] ([method set_siege]). See below.
## [br][br]
## If the bot strays from [code]home[/code] further than the radius, it heads back until it is within
## [constant RETURN_RELEASE_FRACTION] of the radius.
## [br][br]
## [b]Siege ([constant SIEGE]).[/b] On each tick it chooses, in this order:
## [br]1. If an enemy (the one given by [method set_enemy_finder], as in [constant COMBAT]) is within
## [constant SIEGE_FIGHT_RANGE] and can be reached (it is not behind a gate that blocks the way to its realm),
## it fights it just like [constant COMBAT]. While the circle is not active, before anyone else it looks for the NPCs
## that guard the fort (the Hollow, the Captain and the owner's garrison; [method set_defender_finder], F6b): the
## captain has to fall to open the circle. If, while chasing someone who is further than
## [constant COMBAT_ENGAGE_DISTANCE], it does not get closer within [constant SIEGE_STUCK_TICKS] ticks (a wall, the walkway),
## it stops chasing for [constant SIEGE_CHASE_GIVE_UP_TICKS] ticks and continues with its plan. It counts each chase
## separately: reaching fight distance, or changing target, starts another.
## [br]2. [b]March[/b]: follows its realm's route, [constant ApproachRoutes.BRIDGE] or
## [constant ApproachRoutes.FORD] (chosen with its generator at the start and after each respawn), to the
## esplanade in front of the gate, sprinting along the long stretches if there are no enemies nearby.
## [br]3. [b]Assault[/b]: on reaching the esplanade, if the gate blocks the way to its realm
## ([method SiegeView.is_gate_closed_for]) it approaches it and strikes it (light attacks in a combo and an occasional heavy one). Only from
## outside: if it is already inside the fort (the gate was repaired with it inside, or the fort changed owner with it on
## the walkway) it continues with the walkway and the circle, which do not need the gate.
## [br]4. [b]Circle[/b]: with the gate open for its realm (broken, or its own) it enters the capture circle and
## stays inside near the center: attackers take it and the owner defends it (except those with the walkway
## role, GUE-45: see below).
## [br]If it does not advance for [constant SIEGE_STUCK_TICKS] while walking, it first tries a jump and, if it stays
## the same, a lateral detour. A position jump of more than [constant SIEGE_TELEPORT_DISTANCE] meters in one
## tick (respawn) resets the route.
## [br][b]Telegraphed strikes[/b] (F6b): before everything above, if it is in the zone of a strike announced with
## TELEGRAPH (the unblockable of the Ford Captain and the heavy attacks of other NPCs; given by
## [method set_threat_finder]), it leaves it in a straight line away from the striker, with a dodge at the start and
## sprinting, without blocking ([constant SiegeTask.EVADE]). Blocking does not stop the unblockable and leaving is the simplest
## thing that works against all of them; it does not use the generator, so it remains deterministic.
## [br][b]Rally[/b] (GUE-44): an attacker that starts or respawns in its camp does not set out alone. It waits for its own
## at the rally point (the camp exit, the first point of its routes: [method get_siege_rally_point];
## [constant SiegeTask.RALLY]) and leaves when there are [constant SIEGE_RALLY_GROUP_SIZE] of its realm within
## [constant SIEGE_RALLY_RADIUS] (itself included; counted by whoever provides [method set_ally_counter]), when there are already
## [constant SIEGE_RALLY_JOIN_COUNT] of its own fighting at the fort (it goes to help them: an assault in progress is not left
## without reinforcements, and without attackers the captain heals) or, at most, at the next tick of the shared clock (every
## [constant SIEGE_RALLY_PERIOD_TICKS] match ticks, [method next_rally_departure]). The whole group takes the same
## route, which comes from the departure tick ([method rally_route_index]) and not from each one's generator, so those who leave
## together arrive together. Without an ally counter, or with the group at 1 or less ([method set_rally]), it never waits. The
## owner does not wait: it defends as soon as it can.
## [br][b]Formation[/b] (GUE-44): characters do not collide with each other and bots that follow the same points end up one
## on top of another, where a sweeping strike hits them all. In a group (with an ally counter and the rally set) each
## bot has its own slot ([method get_siege_slot]), which it adds to where it is going: sideways on the march, along the gate
## when striking it, in the circle and at the rally point.
## [br][b]Walkway[/b] (GUE-45): a share of the bots ([constant SIEGE_WALKWAY_SHARE], by their seed:
## [method is_walkway_seed]) has the walkway role, if the routes know about it ([method ApproachRoutes.has_walkway]).
## If its realm is the owner, instead of staying in the circle it enters the fort, climbs a ramp (a route of points
## precomputed from the data, checked against the NPC navigation mesh) and guards its post above the gate
## ([constant SiegeTask.WALKWAY]). If it is an attacker, only half of them ([constant SIEGE_WALKWAY_SWEEP_SHARE],
## [method is_walkway_sweeper]): on entering the fort it walks the walkway once to that post (clearing it) and then
## jumps down to the courtyard and goes to the circle. From the walkway no one on the ground can be reached with the weapon (the
## sector reaches from 0.2 to 2 m above the feet and the walkway is at 3.35 m, behind the palisade): inside the compound, whoever
## is more than [constant SIEGE_LEVEL_TOLERANCE] m higher or lower is neither a melee target nor a telegraphed
## strike to avoid, so on the walkway it fights whoever climbs up, without leaving the axis at the corners and without
## dodging sideways (with the kit's bow it does shoot at another level, if there is a shot: see below).
## [br][br]
## [b]Phase 4 kit (H5; docs/abilities.md, section 7.1).[/b] If whoever runs the bot gives it its combat
## state ([method set_combat_source]: the predicted one on a client, the server's on a fake player), the
## [constant COMBAT] and [constant SIEGE] patterns fight with the whole kit: the abilities of the active weapon
## according to what they are for by their data ([enum KitRole]: short strike, charge to close in, wall
## held down while the channeling lasts, backstep, shot), weapon swapping (to the bow from afar, to
## the sword up close), potions (health below [constant KIT_HEALTH_POTION_BELOW] with
## [method set_health_source], stamina below [constant KIT_STAMINA_POTION_BELOW]) and the bow: it keeps
## its distance, alternates quick and drawn shots and aims with lead ([method lead_look]:
## [method Ballistics.solve_lead] and [method AimRay.look_for]), with the [constant PlayerInput.AIM_LEFT] bit for its
## shoulder (the left one if the seed is odd). It finishes off a knocked-down enemy (the finder returns a
## [BotTarget]) and revives a knocked-down ally ([method set_ally_finder]) by holding INTERACT. It only presses what
## its state allows ([method ActionMachine.ability_status]): the server decides all the same, but an honest bot
## does not mash buttons (that is for the cheater, [BotCheatBrain]). Without a state (or with [member use_kit] false)
## it fights as in phase 3, with the same input sequence as before.
## [br]In [constant SIEGE] (integration with F6b) the kit fights in step 1 of the plan with whatever target comes up, the defending NPC
## or the enemy (the bow aims at it, with the velocity its finder gives), but it does not revive anyone: it follows its
## plan. [b]The bow in the siege[/b] (integration review): it shoots whoever is within
## [constant SIEGE_BOW_FIGHT_RANGE] and [b]in line of fire[/b], without the rule of abandoning a chase (it does not chase: it keeps its distance) and
## without the level filter, which is for melee (from the walkway it shoots into the courtyard and vice versa). In line of fire means
## that the arrow arrives: with what it knows about the fort, the intact gate cuts the shot between one side and the other of the palisade
## for all realms, the owner too (its sight body for arrows in both directions), and with the gate broken
## it only shoots from inside out, or the reverse, through the doorway ([constant SIEGE_BOW_GAP_HALF_WIDTH]); and, if whoever runs it
## provides it, with the real line of fire ([method set_line_of_sight]: the server and [code]--bot[/code], the rays from its
## camera and from its mouth to the center of the target in its world, [method bow_sight_clear]). Without a shot it does not fight with the bow: it follows
## its plan (or, up close, draws the sword). With the sword in hand and the bow on its back, it draws the bow for whoever is
## far away and in line of fire, or closer if the sword cannot reach (on the walkway, for example). Going to finish off a knocked-down player is
## approaching, so it follows the chase rule, like the sword. To strike the gate it draws the sword if it
## carries one (arrows do little). On the walkway, since it does not dodge sideways, the archer does not move on it and nobody
## uses the abilities that advance in a straight line (the charge, which also pushes, and the backstep): they pushed both
## off it. While fighting on it, it faces the target (so the weapon reaches even if it is at an angle), but what moves it
## (approaching and the backward dodge) goes along the walkway axis, also without the kit.

## [constant SIEGE] goes last so as not to shift the values of the other patterns.
enum Pattern { WANDER, CIRCLE, IDLE, JUMPY, COMBAT, SIEGE }

## What a [constant SIEGE] bot is doing on this tick ([method get_siege_task]). [constant EVADE] (F6b, at the end
## so as not to shift the others): leaves the zone of a telegraphed strike. [constant RALLY] (GUE-44, afterwards): waits for its own
## at the rally point of its camp. [constant WALKWAY] (GUE-45, the last): climbs to the walkway, walks along it or
## guards its post.
enum SiegeTask { NONE, FIGHT, MARCH, ASSAULT, HOLD, EVADE, RALLY, WALKWAY }

## What the kit uses an ability for, according to its data ([method kit_role]): a short strike with a shape
## ([constant CLOSE]), a forward advance to close in ([constant GAP_CLOSER]), a blocking channeling
## ([constant GUARD], the wall), a backward advance ([constant ESCAPE]) or a shot ([constant SHOT]).
enum KitRole { NONE, CLOSE, GAP_CLOSER, GUARD, ESCAPE, SHOT }

## Minimum duration of a stroll segment (ticks).
const SEGMENT_MIN_TICKS: int = 60
## Maximum duration of a stroll segment (ticks).
const SEGMENT_MAX_TICKS: int = 180
## Probability that a stroll segment is a pause.
const PAUSE_CHANCE: float = 0.2
## Probability that a walking segment is a sprint.
const SPRINT_CHANCE: float = 0.3
## Probability that a walking segment has slightly lateral movement.
const STRAFE_CHANCE: float = 0.25
## Spacing between jumps of a wanderer (ticks, minimum and maximum).
const WANDER_JUMP_GAP_TICKS: Vector2i = Vector2i(120, 420)
## Spacing between jumps of a [constant JUMPY] (ticks, minimum and maximum).
const JUMPY_JUMP_GAP_TICKS: Vector2i = Vector2i(20, 60)
## Ticks the jump button is held down (minimum and maximum).
const JUMP_HOLD_TICKS: Vector2i = Vector2i(2, 5)
## Fraction of the radius at which a bot returning home considers itself arrived.
const RETURN_RELEASE_FRACTION: float = 0.6
## Fraction of the radius at which a [constant CIRCLE] turns.
const CIRCLE_RADIUS_FRACTION: float = 0.5
## Minimum radius of the circle of a [constant CIRCLE] (m).
const CIRCLE_MIN_RADIUS: float = 2.0
## [constant COMBAT]: distance (m) at which it sees an enemy, at which it stops to strike (the weapon
## sector reaches 2.6 m) and beyond which it sprints to reach it.
const COMBAT_SIGHT_RANGE: float = 40.0
const COMBAT_ATTACK_DISTANCE: float = 1.8
const COMBAT_SPRINT_DISTANCE: float = 8.0
## [constant COMBAT]: at this distance it starts fighting (attacks, blocks or dodges).
const COMBAT_ENGAGE_DISTANCE: float = 3.0
## [constant COMBAT]: ticks an attack tap is held.
const COMBAT_TAP_TICKS: int = 2
## [constant COMBAT]: ticks between two attacks (they chain the combo: the link window is the end of
## the recovery) and between a defense and the next decision.
const COMBAT_ATTACK_GAP_TICKS: Vector2i = Vector2i(26, 34)
## [constant COMBAT]: probabilities of each decision (the rest is a light attack) and durations of
## block and heavy attack charge (ticks).
const COMBAT_BLOCK_CHANCE: float = 0.14
const COMBAT_DODGE_CHANCE: float = 0.10
const COMBAT_HEAVY_CHANCE: float = 0.12
const COMBAT_BLOCK_TICKS: Vector2i = Vector2i(30, 80)
const COMBAT_HEAVY_HOLD_TICKS: Vector2i = Vector2i(24, 50)
## [constant COMBAT]: ticks the enemy's position is remembered before looking for it again.
const COMBAT_RETARGET_TICKS: int = 4
## [constant SIEGE]: distance (m) at which an enemy makes it drop its plan to fight (melee; with the kit's
## bow, [constant SIEGE_BOW_FIGHT_RANGE]).
const SIEGE_FIGHT_RANGE: float = 12.0
## [constant SIEGE]: radius (m) within which a route point counts as reached.
const SIEGE_WAYPOINT_RADIUS: float = 2.5
## [constant SIEGE]: distance (m) from the gate at which it stops to strike it (the weapon sector
## reaches 2.6 m from it and the gate face is 0.25 m from its center).
const SIEGE_GATE_ATTACK_DISTANCE: float = 2.3
## [constant SIEGE]: inside the circle it positions itself at this fraction of the radius from the center.
const SIEGE_CIRCLE_HOLD_FRACTION: float = 0.5
## [constant SIEGE]: to enter the fort it aligns with the gate axis (at this lateral distance at
## most, in meters), in front of it at [constant SIEGE_GATE_FRONT_DISTANCE], and crosses it to a point
## [constant SIEGE_GATE_EXIT_DISTANCE] inside. Without this, on reaching the last point of the route, which is
## to the side, the bot went straight for the circle and crashed into the palisade.
const SIEGE_GATE_AXIS_TOLERANCE: float = 1.0
## [constant SIEGE]: half width (m) of the doorway the bot fits through (the doorway is 4 m wide; minus its radius). Pressed against the
## gate wall but further to one side than this, it first returns in front of the gate.
const SIEGE_GATE_OPENING_HALF_WIDTH: float = 1.6
const SIEGE_GATE_FRONT_DISTANCE: float = 4.5
const SIEGE_GATE_EXIT_DISTANCE: float = 2.5
## [constant SIEGE]: radius (m) it uses if the [SiegeView] does not know the circle's.
const SIEGE_DEFAULT_CIRCLE_RADIUS: float = 5.0
## [constant SIEGE]: sprints if more than this distance (m) remains and there are no enemies within the other one.
const SIEGE_SPRINT_DISTANCE: float = 9.0
const SIEGE_SPRINT_ENEMY_CLEARANCE: float = 25.0
## [constant SIEGE]: a position jump of more than this distance (m) in one tick is a respawn.
const SIEGE_TELEPORT_DISTANCE: float = 5.0
## [constant SIEGE]: if it is further than this distance (m) from the point it is chasing, it looks for the nearest one.
const SIEGE_LOST_DISTANCE: float = 70.0
## [constant SIEGE]: within this many meters of the circle, and on the other side of the gate, it is already inside the
## fort and does not need the route (if the [SiegeView] does not know the size of the compound; if it does, the compound counts with
## [constant SIEGE_ENCLOSURE_MARGIN] of slack: pressed against the palisade on the outside it is not inside).
const SIEGE_INSIDE_RADIUS: float = 30.0
const SIEGE_ENCLOSURE_MARGIN: float = 0.5
## [constant SIEGE]: outside the compound but beside or behind it (a chase pulled it off the route), it goes around the
## palisade by its corners, at this distance (m) from the walls, to the gate wall; it counts a corner as
## reached at [constant SIEGE_WAYPOINT_RADIUS].
const SIEGE_CORNER_MARGIN: float = 6.0
## [constant SIEGE]: ticks without advancing [constant SIEGE_STUCK_MIN_PROGRESS] meters after which it is
## considered stuck; ticks a jump or detour lasts to get unstuck; how many ticks between jump
## presses; and angle (rad) of the detour.
const SIEGE_STUCK_TICKS: int = 180
const SIEGE_STUCK_MIN_PROGRESS: float = 1.0
const SIEGE_JUMP_WINDOW_TICKS: int = 40
const SIEGE_JUMP_PULSE_TICKS: int = 20
const SIEGE_DETOUR_TICKS: int = 60
const SIEGE_DETOUR_ANGLE: float = 1.2
## [constant SIEGE]: margin (m) added to the reach of a telegraphed strike and to the edge of its half-plane to count as
## inside its zone (the capsule radius, 0.4 m, and a bit more so as not to stay on the edge).
const SIEGE_THREAT_MARGIN: float = 1.0
## [constant SIEGE]: while still in the zone of a telegraphed strike, how many ticks between dodge presses (the first,
## right on seeing it: 4.5 m in 0.45 s, which take it out of the reach of the Captain's strike before impact).
const SIEGE_EVADE_DODGE_TICKS: int = 15
## [constant SIEGE]: if, while chasing someone who is further than [constant COMBAT_ENGAGE_DISTANCE], it does not get closer by
## [constant SIEGE_STUCK_MIN_PROGRESS] meters in [constant SIEGE_STUCK_TICKS] ticks (they are behind a wall, on the walkway
## or fleeing faster), it stops chasing anyone not within that distance for these ticks and continues with its plan. It measures
## consecutive chases of the same target: on reaching fight distance, or on changing target, another starts.
const SIEGE_CHASE_GIVE_UP_TICKS: int = 600
## [constant SIEGE], rally (GUE-44): how many of its realm (itself included) there must be at the rally point to leave
## without waiting for the clock.
const SIEGE_RALLY_GROUP_SIZE: int = 8
## [constant SIEGE], rally: every how many match ticks the shared clock fires (the most an attacker waits), and at which
## tick within each cycle: 5 s after a respawn wave ([code]CombatTiming.WAVE_TICKS[/code], multiples
## of 600), so that those who respawn in it arrive in time.
const SIEGE_RALLY_PERIOD_TICKS: int = 1800
const SIEGE_RALLY_OFFSET_TICKS: int = 300
## [constant SIEGE], rally: radius (m) of the rally point within which its own are counted (the four camp
## respawn points fall inside); it waits in its slot ([constant SIEGE_SLOT_RALLY_SPREAD]).
const SIEGE_RALLY_RADIUS: float = 15.0
## [constant SIEGE], rally: if there are already at least [constant SIEGE_RALLY_JOIN_COUNT] of its own within
## [constant SIEGE_RALLY_FORT_RADIUS] meters of the circle (fighting at the fort or on its esplanade), it does not wait: it goes to
## help them.
const SIEGE_RALLY_JOIN_COUNT: int = 3
const SIEGE_RALLY_FORT_RADIUS: float = 25.0
## [constant SIEGE], formation (GUE-44): characters do not collide with each other, so bots that follow the same points
## end up one on top of another, and a sweeping strike (the weapon sector) hits the whole pile at once. A bot that goes in a
## group ([method set_ally_counter]) has its slot ([method get_siege_slot], derived from its seed) and adds it to where it is going:
## sideways on the march, along the gate when striking it, inside the circle and at the rally point. Meters of
## each one, and the distance at which it counts its spot as reached.
const SIEGE_SLOT_MARCH_SPREAD: float = 1.0
const SIEGE_SLOT_GATE_SPREAD: float = 1.6
const SIEGE_SLOT_CIRCLE_SPREAD: float = 2.0
const SIEGE_SLOT_RALLY_SPREAD: float = 4.0
const SIEGE_SLOT_REACHED: float = 0.5
## The two steps of the R2 sequence (the inverses of the plastic number and of its square): the slots of consecutive seeds
## end up spread over the disc ([method slot_for_seed]).
const SLOT_STEP_ANGLE: float = 0.7548776662466927
const SLOT_STEP_RADIUS: float = 0.5698402909980532
## [constant SIEGE], walkway (GUE-45): what share of the bots has the walkway role ([method is_walkway_seed]):
## the owner's that guard it and, of them, those that walk it when attacking. With the same share for attackers
## (about five out of twenty that leave the courtyard fight and climb one at a time against the owner's five or so) the recapture
## of siege_battle.gd went from a median of 2.6 to 5.3 min; with half, 2.7 (docs/fortress.md 8.3, F6b, package D).
const SIEGE_WALKWAY_SHARE: float = 0.25
const SIEGE_WALKWAY_SWEEP_SHARE: float = 0.125
## Step of the Weyl sequence with which the role is distributed by seeds (the inverse of the golden ratio): any
## series of consecutive seeds, or one every N, gives almost the same proportion (with twenty, one more or less).
const WALKWAY_SEED_STEP: float = 0.6180339887498949
## [constant SIEGE], walkway: up to how many meters on each side of the post (above the gate, along the
## walkway) each one is placed according to its slot ([method get_siege_slot]).
const SIEGE_WALKWAY_POST_SPREAD: float = 4.0
## [constant SIEGE], walkway: distance (m) at which a point of the ramps, a corner of the walkway
## or its post counts as reached. Less than the axis slack (the walkway is 2 m wide and the capsule 0.8): cutting a corner it does not fall.
const SIEGE_WALKWAY_REACHED: float = 0.5
## [constant SIEGE], walkway: it is on it if its feet are less than [constant SIEGE_WALKWAY_LEVEL_MARGIN] m
## below its floor (or higher) and less than [constant SIEGE_WALKWAY_BAND] m from its axis horizontally.
const SIEGE_WALKWAY_LEVEL_MARGIN: float = 0.8
const SIEGE_WALKWAY_BAND: float = 1.5
## [constant SIEGE], walkway: climbing toward the top of a ramp, if it strays from its axis by more than this (m), it first returns
## to the courtyard point in front of its foot.
const SIEGE_RAMP_AXIS_TOLERANCE: float = 1.0
## [constant SIEGE]: inside the compound (the courtyard is flat), whoever is more than this many meters higher or lower
## (on the walkway, or in the courtyard seen from it) cannot be reached: the weapon sector goes from 0.2 to 2 m above the feet of
## the striker and the capsule is 1.8 tall.
const SIEGE_LEVEL_TOLERANCE: float = 1.6
## Weight of height in the distance with which the bots' enemy finders choose the nearest
## ([method target_distance_squared]): with 4, the walkway (3.35 m above) ends up more than 13 m away, further than the
## fight reach ([constant SIEGE_FIGHT_RANGE]), and any enemy in line of fire on its own level goes first.
const SIEGE_LEVEL_WEIGHT: float = 4.0
## Kit: with the bow in hand and the enemy within this distance (m) it switches to the sword if it carries one, and with the
## sword and the enemy beyond the other, to the bow.
const KIT_SWAP_TO_MELEE_DISTANCE: float = 5.0
const KIT_SWAP_TO_RANGED_DISTANCE: float = 11.0
## Kit: distances (m) between which the archer stays (it moves away below and approaches above).
const KIT_BOW_KEEP_MIN: float = 9.0
const KIT_BOW_KEEP_MAX: float = 26.0
## Kit: probability that a shot is drawn and ticks PRIMARY is held (from the press; the drawn-shot charge
## goes from 21 to 60).
const KIT_BOW_DRAWN_CHANCE: float = 0.45
const KIT_BOW_DRAW_TICKS: Vector2i = Vector2i(24, 60)
## Kit: probability of using a ready shot ability and distance (m) below which the archer
## backsteps.
const KIT_SHOT_ABILITY_CHANCE: float = 0.3
const KIT_ESCAPE_DISTANCE: float = 5.0
## Kit: probability of dodging in an archer decision with the enemy nearby.
const KIT_BOW_DODGE_CHANCE: float = 0.08
## Kit: short strike (the shield one) at this distance (m) at most and with this probability per decision.
const KIT_CLOSE_DISTANCE: float = 2.2
const KIT_CLOSE_CHANCE: float = 0.22
## Kit: charge to close in between these distances (m) and with this probability per decision.
const KIT_GAP_CLOSER_RANGE: Vector2 = Vector2(3.5, 7.0)
const KIT_GAP_CLOSER_CHANCE: float = 0.3
## Kit: probability of raising the wall in a decision and ticks its button is held (the channeling ends on
## release or at its cap).
const KIT_GUARD_CHANCE: float = 0.08
const KIT_GUARD_HOLD_TICKS: Vector2i = Vector2i(60, 200)
## Kit: drinks the health potion below this fraction of health and the stamina one below this
## fraction of stamina.
const KIT_HEALTH_POTION_BELOW: float = 0.5
const KIT_STAMINA_POTION_BELOW: float = 0.3
## Kit: approaches to this distance (m) of a knocked-down player to revive or finish them (the server reaches 2 m)
## and holds INTERACT for the duration of the action plus this margin (ticks).
const KIT_INTERACT_REACH: float = 1.3
const KIT_INTERACT_MARGIN_TICKS: int = 8
## Kit: looks for knocked-down allies up to this distance (m) and only goes to revive them if there is no enemy
## closer than the other one.
const KIT_REVIVE_SEARCH: float = 15.0
const KIT_REVIVE_ENEMY_CLEARANCE: float = 6.0
## Kit: extra ticks between two decisions after finishing an action, and how long each lateral stretch of the archer lasts.
const KIT_DECISION_GAP_TICKS: Vector2i = Vector2i(4, 12)
const KIT_STRAFE_TICKS: Vector2i = Vector2i(40, 100)
## Kit in [constant SIEGE]: distance (m) up to which it shoots with the bow (or draws it) at whoever is in line of fire. With
## [constant SIEGE_FIGHT_RANGE] (12 m, the melee one) the switch to the bow, which asks for more than
## [constant KIT_SWAP_TO_RANGED_DISTANCE], almost never arrived and the archer only kept 9 to 12 m: it is that distance
## plus 9 m of margin, within which the archer keeps its distance ([constant KIT_BOW_KEEP_MAX]). Further out it follows its plan.
const SIEGE_BOW_FIGHT_RANGE: float = 20.0
## Kit in [constant SIEGE]: half width (m) of the broken gate's doorway through which an arrow passes from outside in or the
## reverse (the doorway is 4 m wide; a bit less, because of the jamb thickness).
const SIEGE_BOW_GAP_HALF_WIDTH: float = 1.8

# How a siege bot gets unstuck.
enum _Unstick { NONE, JUMP, DETOUR }
# How a siege bot fights a target: it does not fight, it approaches (melee, or going to finish off) or it shoots it with the
# bow.
enum _Engage { SKIP, CLOSE, SHOOT }
# Maximum pitch (rad) of the bow aim (below the vertical).
const _MAX_AIM_PITCH: float = 1.4


## A telegraphed strike (TELEGRAPH, docs/fortress.md section 5) that a [constant SIEGE] bot avoids: a sector of
## reach [member radius] with its vertex at [member origin] (the feet of the striker) and oriented according to
## [member yaw] (the [PlayerInput] convention: yaw 0 faces -Z). The notice does not say the angle of the sector, so
## the half-plane in front is taken: it amply covers the 120° of the Captain's strike.
class Threat:
	extends RefCounted

	var origin: Vector3 = Vector3.ZERO
	var yaw: float = 0.0
	var radius: float = 0.0


	func _init(new_origin: Vector3 = Vector3.ZERO, new_yaw: float = 0.0, new_radius: float = 0.0) -> void:
		origin = new_origin
		yaw = new_yaw
		radius = new_radius


	## true if [param position] is in the danger zone with [param margin] extra meters: within the reach
	## plus the margin (horizontally) and no more than [param margin] behind the striker.
	func covers(position: Vector3, margin: float) -> bool:
		var offset := Vector3(position.x - origin.x, 0.0, position.z - origin.z)
		if offset.length() > radius + margin:
			return false
		var forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
		return offset.dot(forward) >= -margin

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _pattern: Pattern = Pattern.WANDER
var _home: Vector3 = Vector3.ZERO
var _radius: float = 30.0
var _idle_from: int = -1
var _started: bool = false
var _returning: bool = false
var _circle_sign: float = 1.0
# Current stroll segment.
var _next_change_tick: int = 0
var _heading: float = 0.0
var _move: Vector2 = Vector2.ZERO
var _sprint: bool = false
# Jump: tick at which the next one starts and tick at which the button is released.
var _next_jump_tick: int = 0
var _jump_release_tick: int = -1
# COMBAT: who looks for the enemy, the last one seen, and which button is held until when.
var _enemy_finder: Callable = Callable()
var _enemy_position: Variant = null
var _enemy_checked_tick: int = -1000
var _hold_buttons: int = 0
var _hold_until: int = -1
var _hold_move: Vector2 = Vector2.ZERO
var _next_decision_tick: int = 0
# SIEGE: the fort, the routes and the bot's realm; the route it follows and which point it is heading to.
var _siege: SiegeView = null
var _siege_routes: ApproachRoutes = null
var _siege_realm: int = 0
var _siege_route_id: StringName = &""
var _siege_route_chosen: bool = false
var _siege_route_points: PackedVector2Array = PackedVector2Array()
var _siege_route_index: int = 0
var _siege_task: SiegeTask = SiegeTask.NONE
# SIEGE: the last position (to detect a respawn) and the unstuck state.
var _siege_last_position: Vector3 = Vector3.ZERO
var _siege_has_position: bool = false
var _siege_stuck_ref_position: Vector3 = Vector3.ZERO
var _siege_stuck_ref_tick: int = -1
var _siege_stuck_count: int = 0
var _siege_unstick: _Unstick = _Unstick.NONE
var _siege_unstick_start: int = 0
var _siege_unstick_until: int = -1
var _detour_sign: float = 1.0
# SIEGE: the held button aims at the gate (and not at an enemy).
var _hold_aims_gate: bool = false
# SIEGE: who provides the telegraphed strikes to avoid, and since which tick it has been leaving one (-1 = it is not).
var _siege_threat_finder: Callable = Callable()
var _siege_evade_since: int = -1
# SIEGE: who provides the nearest defending NPC, the last one seen (with its velocity and its knockdown if the finder gives a
# BotTarget, for the kit) and when it was looked at.
var _siege_defender_finder: Callable = Callable()
var _siege_defender_position: Variant = null
var _siege_defender_velocity: Vector3 = Vector3.ZERO
var _siege_defender_downed: bool = false
var _siege_defender_checked_tick: int = -1000
# SIEGE: the chase in progress (distance and reference tick; -1 = none), until when it does not chase, and whom it
# was chasing at the last check (whether it was the defending NPC and where it was): another target is another chase.
var _siege_chase_ref_distance: float = 0.0
var _siege_chase_ref_tick: int = -1
var _siege_chase_blocked_until: int = -1
var _siege_chase_defender: bool = false
var _siege_chase_target: Vector3 = Vector3.ZERO
# SIEGE, rally (GUE-44): who counts its own, the group size and the clock's cycle; whether it is time to check whether it waits
# (at start and after respawning) and, while waiting, until which tick at most (-1 = it does not wait).
var _siege_ally_counter: Callable = Callable()
var _siege_rally_size: int = SIEGE_RALLY_GROUP_SIZE
var _siege_rally_period: int = SIEGE_RALLY_PERIOD_TICKS
var _siege_rally_pending: bool = true
var _siege_rally_until: int = -1
# SIEGE, rally: tick of the last departure from the rally point (-1 = it has never left one).
var _siege_rally_left_tick: int = -1
# SIEGE, formation: the bot's slot (a point of the unit disc, from its seed).
var _siege_slot: Vector2 = Vector2.ZERO
# SIEGE, walkway (GUE-45): the seed (to distribute the role), whether it has the role, whether it has already walked it as an attacker in
# this life, the ramp it climbs (-1 = none) and the point on it it is heading to (-1 = not chosen yet), and whether it is
# on the walkway on this tick.
var _siege_seed: int = 0
var _siege_walkway_role: bool = false
var _siege_walkway_sweeper: bool = false
var _siege_walkway_swept: bool = false
var _siege_climb_ramp: int = -1
var _siege_climb_index: int = -1
var _siege_on_walkway_now: bool = false

## Kit (H5): false turns it off even if there is a combat state (the bot fights as in phase 3). Used by the baseline
## measurements of [code]tools/combat_balance.gd[/code].
var use_kit: bool = true
## Kit, for load tests ([code]--fake-archers[/code]): with the bow in hand it never switches to the sword
## (keeps its distance and shoots), and with the sword it goes back to the bow as soon as it can.
var kit_ranged_only: bool = false
## Kit, for load tests: radians by which the bow aim is raised above the right shot. With a high
## value, arrows go to the sky and live their 2 s (they fill the zone cap; docs/abilities.md, section 4.4).
var kit_aim_raise: float = 0.0
# Kit: where it gets its combat state, its health and the knocked-down allies from.
var _combat_source: Callable = Callable()
var _health_source: Callable = Callable()
var _ally_finder: Callable = Callable()
# Kit: velocity and knockdown of the enemy it follows (from the BotTarget; zero and false with a bare position).
var _enemy_velocity: Vector3 = Vector3.ZERO
var _enemy_downed: bool = false
# Kit: the target of the fight in progress is the SIEGE defending NPC (and not the enemy from set_enemy_finder): the bow
# aims at it and its knockdown decides the finisher.
var _fight_defender: bool = false
# Kit: the nearest knocked-down ally (Vector3 or null) and when it was searched for.
var _ally_position: Variant = null
var _ally_checked_tick: int = -1000
# Kit: what it holds (&"" a tap or nothing; &"execute", &"revive", &"guard", &"draw").
var _hold_kind: StringName = &""
# Kit: speed (m/s) and gravity of the shot it aims (0 = nothing to aim).
var _aim_speed: float = 0.0
var _aim_gravity: float = 0.0
# Kit: shoulder of the aim (the left one with an odd seed) and lateral stretch of the archer.
var _aim_left: bool = false
var _kit_strafe_sign: float = 1.0
var _kit_strafe_until: int = -1
# Kit: how many times it has done each thing (get_kit_counts).
var _kit_counts: Dictionary[StringName, int] = {}
# Kit in SIEGE: the fight in progress is a bow-shooting one (_Engage.SHOOT): with the sword in hand it swaps it for the
# bow and does not approach, and with the bow it does not draw the sword.
var _kit_shoot_plan: bool = false
# Kit in SIEGE: who says whether there is a line of fire (set_line_of_sight) and the last answer for the defending NPC and for the
# enemy, with the tick of the target search it corresponds to (-1 = none).
var _line_of_sight: Callable = Callable()
var _sight_defender_tick: int = -1
var _sight_defender: bool = false
var _sight_enemy_tick: int = -1
var _sight_enemy: bool = false


## [param rng_seed] fixes the sequence. [param home] and [param radius] delimit the zone
## the bot moves through (in the horizontal plane).
func _init(rng_seed: int, pattern: Pattern = Pattern.WANDER, home: Vector3 = Vector3.ZERO,
		radius: float = 30.0) -> void:
	_rng.seed = rng_seed
	_pattern = pattern
	_home = home
	_radius = maxf(radius, 1.0)
	_circle_sign = 1.0 if _rng.randi() % 2 == 0 else -1.0
	_siege_slot = slot_for_seed(rng_seed)
	_siege_seed = rng_seed
	_siege_walkway_role = is_walkway_seed(rng_seed)
	_siege_walkway_sweeper = is_walkway_seed(rng_seed, SIEGE_WALKWAY_SWEEP_SHARE)
	# Without drawing numbers from the generator: the sequence of the earlier patterns does not change.
	_aim_left = posmod(rng_seed, 2) == 1


## Unquantized input for [param tick] (the caller quantizes it). [param position] and
## [param yaw] are the character's current ones. It changes direction every 60-180 ticks, jumps and
## sprints at times and heads back toward home if it leaves the radius.
func next_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	if _pattern == Pattern.IDLE or (_idle_from >= 0 and tick >= _idle_from):
		input.look_yaw = yaw
		return input
	if _pattern == Pattern.COMBAT:
		var fighting: PlayerInput = _combat_input(tick, position, yaw)
		if fighting != null:
			return fighting
	elif _pattern == Pattern.SIEGE and _siege != null:
		return _siege_input(tick, position, yaw)
	if not _started:
		_started = true
		_next_change_tick = tick
		_schedule_jump(tick)

	var to_home: Vector3 = _home - position
	to_home.y = 0.0
	var distance: float = to_home.length()
	if distance > _radius:
		_returning = true
	elif distance < _radius * RETURN_RELEASE_FRACTION:
		_returning = false

	if _returning:
		input.look_yaw = _yaw_toward(to_home, yaw)
		input.move = Vector2(0.0, 1.0)
		# A new segment on arriving, so as not to resume a heading that takes it out of the radius again.
		_next_change_tick = tick
	elif _pattern == Pattern.CIRCLE:
		input.look_yaw = _circle_yaw(position, yaw)
		input.move = Vector2(0.0, 1.0)
	else:
		if tick >= _next_change_tick:
			_start_segment(tick)
		input.look_yaw = _heading
		input.move = _move
		if _sprint:
			input.buttons |= PlayerInput.SPRINT

	if _pattern == Pattern.WANDER or _pattern == Pattern.JUMPY:
		_update_jump(tick)
		if tick < _jump_release_tick:
			input.buttons |= PlayerInput.JUMP
	return input


## Function with which the [constant COMBAT] and [constant SIEGE] patterns look for enemies:
## [code](position: Vector3) -> Variant[/code] returns the position (a [Vector3]) of the enemy nearest
## to [param position], or null if there is none. Without it, [constant COMBAT] strolls and
## [constant SIEGE] only marches, assaults and defends.
func set_enemy_finder(finder: Callable) -> void:
	_enemy_finder = finder
	_enemy_checked_tick = -1000


## true if the [constant COMBAT] or [constant SIEGE] pattern already has something to look for enemies for it.
func has_enemy_finder() -> bool:
	return _enemy_finder.is_valid()


## Pattern of the bot.
func get_pattern() -> Pattern:
	return _pattern


## From [param tick] (inclusive) it only returns neutral inputs: no movement or buttons and
## facing the current yaw. Used by the reconciliation convergence tests.
func set_idle_from(tick: int) -> void:
	_idle_from = tick


## Gives the [constant SIEGE] pattern the fort it besieges or defends ([param view], which whoever runs it keeps
## up to date and which can be shared between bots), the zone routes ([param routes], null = goes straight to the
## gate) and the bot's realm ([param realm], network code). Resets the route.
func set_siege(view: SiegeView, routes: ApproachRoutes, realm: int) -> void:
	_siege = view
	_siege_routes = routes
	_siege_realm = realm
	_reset_route()


## Function with which the [constant SIEGE] pattern learns of the telegraphed strikes (TELEGRAPH) to avoid:
## [code](position: Vector3) -> Array[/code] returns the active [BotBrain.Threat] of those who can damage it
## (it may also return distant ones: the brain checks whether it is inside each). Without it, it avoids nothing.
func set_threat_finder(finder: Callable) -> void:
	_siege_threat_finder = finder


## Function with which the [constant SIEGE] pattern first looks for the NPCs defending the fort (the Hollow, the
## Captain and the owner's garrison): [code](position: Vector3) -> Variant[/code] returns the position of the nearest
## living enemy NPC (a [Vector3] or, like that of [method set_enemy_finder], a [BotTarget] with its velocity, for the kit's
## lead shot), or null. While the circle is not active (the captain lives), if there is one in range it fights it before
## the enemy from [method set_enemy_finder] (a player hitting it does not pull it away), and since the finder always gives
## the nearest, it sticks with the same one until it dies or moves away. With the circle active, or without it, it fights
## the nearest of all.
func set_defender_finder(finder: Callable) -> void:
	_siege_defender_finder = finder
	_siege_defender_checked_tick = -1000


## true if the [constant SIEGE] pattern already has something to look for the defending NPCs for it.
func has_defender_finder() -> bool:
	return _siege_defender_finder.is_valid()


## Function with which the [constant SIEGE] pattern counts its own at the rally point (GUE-44):
## [code](center: Vector3, radius: float) -> int[/code] returns how many living players of its realm, not counting
## itself, are within [param radius] meters (horizontally) of [param center]. Without it, it waits for nobody and leaves alone,
## as before GUE-44.
func set_ally_counter(counter: Callable) -> void:
	_siege_ally_counter = counter


## true if the [constant SIEGE] pattern already has something to count its own for it.
func has_ally_counter() -> bool:
	return _siege_ally_counter.is_valid()


## Changes the rally of the [constant SIEGE] pattern (GUE-44): it leaves when there are [param group_size] of its realm at the
## rally point (itself included) or at the next departure of the clock, which cycles every [param period_ticks] ticks. With
## [param group_size] 1 or less it never waits (as before GUE-44). Used by comparison tools; by
## default, [constant SIEGE_RALLY_GROUP_SIZE] and [constant SIEGE_RALLY_PERIOD_TICKS]. It applies to the next wait; if
## it was waiting and the group becomes 1 or less, it stops waiting.
func set_rally(group_size: int, period_ticks: int = SIEGE_RALLY_PERIOD_TICKS) -> void:
	_siege_rally_size = group_size
	_siege_rally_period = maxi(period_ticks, 1)
	if group_size <= 1:
		_siege_rally_until = -1


## Size of the group with which it leaves the rally (1 or less: it does not wait).
func get_rally_group_size() -> int:
	return _siege_rally_size


## true if the [constant SIEGE] bot is waiting for its own at the rally point.
func is_rallying() -> bool:
	return _siege_rally_until >= 0


## Tick of the clock departure at which, at most, the waiting bot leaves (-1 if it does not wait).
func get_rally_deadline() -> int:
	return _siege_rally_until


## The slot of a bot with seed [param rng_seed] in the formation of the [constant SIEGE] pattern (GUE-44): a point of the
## disc of radius 1 (x sideways, y forward) taken from the R2 sequence, which spreads consecutive seeds well (the bots
## of one group: with twenty consecutive, the closest pair averages 0.19 apart and never under 0.1 over the bases
## from 0 to 6000; in one of every ten bases, under 0.18). It does not use the generator.
static func slot_for_seed(rng_seed: int) -> Vector2:
	var angle: float = TAU * fposmod(float(rng_seed) * SLOT_STEP_ANGLE, 1.0)
	var reach: float = sqrt(fposmod(float(rng_seed) * SLOT_STEP_RADIUS, 1.0))
	return Vector2(cos(angle), sin(angle)) * reach


## This bot's slot in the formation ([method slot_for_seed]).
func get_siege_slot() -> Vector2:
	return _siege_slot


## Tick at which it last left the rally point with its own, also if it did not have to wait because there were
## enough already (-1 if it has never left a rally).
func get_last_rally_departure() -> int:
	return _siege_rally_left_tick


## true if a bot with seed [param rng_seed] has the walkway role of the [constant SIEGE] pattern (GUE-45): the
## fraction [param share] of the seeds, distributed with the Weyl sequence of the golden ratio, so with 20 consecutive
## seeds (or every second one, those of a realm) there are 4 to 6 with [constant SIEGE_WALKWAY_SHARE] (5 in more than half of
## the bases) and 1 to 4 with [constant SIEGE_WALKWAY_SWEEP_SHARE] (almost always 2 or 3). It does not use the generator.
static func is_walkway_seed(rng_seed: int, share: float = SIEGE_WALKWAY_SHARE) -> bool:
	return fposmod(float(rng_seed) * WALKWAY_SEED_STEP, 1.0) < share


## Gives or removes the walkway role of the bot: [param guard], guarding it when its realm is the owner, and [param sweeper],
## walking it when attacking (by default, the same). Without calling it, it has them if [method is_walkway_seed] with its seed and
## [constant SIEGE_WALKWAY_SHARE] or [constant SIEGE_WALKWAY_SWEEP_SHARE]. It applies from the next tick.
func set_walkway_role(guard: bool, sweeper: bool = guard) -> void:
	_siege_walkway_role = guard
	_siege_walkway_sweeper = sweeper
	_siege_climb_ramp = -1


## Redistributes the walkway role with fraction [param share] for the owner's bots (0 = nobody climbs, as before
## GUE-45) and the same proportion as before for attackers (half: [constant SIEGE_WALKWAY_SWEEP_SHARE] of
## [constant SIEGE_WALKWAY_SHARE]), with [method is_walkway_seed] and its seed. Used by comparison tools.
func set_walkway_share(share: float) -> void:
	set_walkway_role(is_walkway_seed(_siege_seed, share),
			is_walkway_seed(_siege_seed, share * SIEGE_WALKWAY_SWEEP_SHARE / SIEGE_WALKWAY_SHARE))


## true if the bot guards the walkway when its realm is the owner (GUE-45).
func has_walkway_role() -> bool:
	return _siege_walkway_role


## true if the bot walks the walkway when attacking (GUE-45).
func is_walkway_sweeper() -> bool:
	return _siege_walkway_sweeper


## true if the attacking bot has already walked the walkway in this life (it does so again after respawning).
func is_walkway_swept() -> bool:
	return _siege_walkway_swept


## This bot's post on the walkway (GUE-45): the point of its axis above the gate plus its slot along it,
## at the height of its floor; null if it has no fort or the routes do not know the walkway.
func get_walkway_post() -> Variant:
	if _siege == null or _siege_routes == null or not _siege_routes.has_walkway() or not _siege_has_places():
		return null
	var point: Vector2 = _siege_routes.walkway_point(_siege_walkway_post_offset())
	return Vector3(point.x, _siege_routes.walkway_height, point.y)


## true if [param position] is on the walkway of the fort it besieges (with its routes): at its height, with
## [constant SIEGE_WALKWAY_LEVEL_MARGIN] of slack, and within [constant SIEGE_WALKWAY_BAND] m of its axis.
func is_on_walkway(position: Vector3) -> bool:
	if _siege_routes == null or not _siege_routes.has_walkway():
		return false
	if position.y < _siege_routes.walkway_height - SIEGE_WALKWAY_LEVEL_MARGIN:
		return false
	return _siege_routes.walkway_distance(Vector2(position.x, position.z)) <= SIEGE_WALKWAY_BAND


## Squared distance with which the bots' enemy finders ([method set_enemy_finder] and
## [method set_defender_finder]: the server, [code]SwarmBot[/code] and [code]--bot[/code]) choose the nearest: the
## horizontal one plus the vertical multiplied by [constant SIEGE_LEVEL_WEIGHT]. Thus the one at its height goes before
## the one on the walkway or in the courtyard seen from it, whom it cannot reach (GUE-45).
static func target_distance_squared(from: Vector3, to: Vector3) -> float:
	var dx: float = to.x - from.x
	var dz: float = to.z - from.z
	var dy: float = (to.y - from.y) * SIEGE_LEVEL_WEIGHT
	return dx * dx + dz * dz + dy * dy


## The rally point of the [constant SIEGE] pattern (GUE-44): the exit of its realm's camp, where its
## routes start (the first point of the first one, by id order; in Vado Gris they all start at the same one), at ground level.
## null if it has no fort or its routes have no points for its realm.
func get_siege_rally_point() -> Variant:
	if _siege_routes == null:
		return null
	var realm_id: StringName = RealmCatalog.id_of_code(_siege_realm)
	for route: StringName in _siege_routes.get_route_ids():
		var points: PackedVector2Array = _siege_routes.get_points(route, realm_id)
		if not points.is_empty():
			return Vector3(points[0].x, 0.0, points[0].y)
	return null


## First tick after [param tick] at which the shared rally clock fires, which cycles every
## [param period_ticks] ticks and fires [constant SIEGE_RALLY_OFFSET_TICKS] ticks after the start of each one. It is
## the same for all bots (the match tick is common), so those waiting leave together.
static func next_rally_departure(tick: int, period_ticks: int = SIEGE_RALLY_PERIOD_TICKS) -> int:
	var period: int = maxi(period_ticks, 1)
	return tick + period - posmod(tick - SIEGE_RALLY_OFFSET_TICKS, period)


## Index (among [param route_count] routes, in the order of [method ApproachRoutes.get_route_ids]) of the route of the group
## leaving the rally at [param tick]: they alternate, one per clock cycle. Each bot of the group computes it the same
## way, without talking to the others. Clock departures fall mid-cycle, so a few ticks of difference
## between clients do not change the route.
static func rally_route_index(tick: int, route_count: int, period_ticks: int = SIEGE_RALLY_PERIOD_TICKS) -> int:
	if route_count <= 0:
		return -1
	@warning_ignore("integer_division")
	return posmod(maxi(tick, 0) / maxi(period_ticks, 1), route_count)


## true if the [constant SIEGE] pattern already has something to warn it of strikes.
func has_threat_finder() -> bool:
	return _siege_threat_finder.is_valid()


## true if the [constant SIEGE] pattern already knows which fort it besieges.
func has_siege() -> bool:
	return _siege != null


## The [SiegeView] of the [constant SIEGE] pattern (null if it has not been given one).
func get_siege_view() -> SiegeView:
	return _siege


## Route followed by a [constant SIEGE] bot ([constant ApproachRoutes.BRIDGE] or
## [constant ApproachRoutes.FORD]); empty while it has not chosen one or if there are no routes.
func get_siege_route() -> StringName:
	return _siege_route_id


## Index of the route point a [constant SIEGE] bot is heading for (the route size if it has already
## walked all of it).
func get_siege_route_index() -> int:
	return _siege_route_index


## What a [constant SIEGE] bot did on the last tick.
func get_siege_task() -> SiegeTask:
	return _siege_task


## Kit (H5): where the bot gets its combat state from, [code]() -> CombatState[/code] (null = it does not know): the one
## after the last simulated tick, with which it decides the input for the next (the predicted one on a client, the
## server's on a fake player). It reads it without changing it. With it, [constant COMBAT] and [constant SIEGE] use the
## kit (see the class documentation).
func set_combat_source(source: Callable) -> void:
	_combat_source = source


## true if the bot already knows where to get its combat state ([method set_combat_source]).
func has_combat_source() -> bool:
	return _combat_source.is_valid()


## Kit: where it gets its health from, [code]() -> float[/code] (fraction from 0 to 1). Without it, the bot does not drink the health
## potion.
func set_health_source(source: Callable) -> void:
	_health_source = source


## Kit: how it finds knocked-down allies, [code](position: Vector3) -> Variant[/code]: the feet (a
## [Vector3]) of the one nearest to [param position], or null. Without it, the bot revives nobody.
func set_ally_finder(finder: Callable) -> void:
	_ally_finder = finder
	_ally_checked_tick = -1000


## Kit in [constant SIEGE]: how it knows whether it has a shot with the bow,
## [code](from: Vector3, to: Vector3, left_shoulder: bool) -> bool[/code]: true if nothing in the world or the structures
## (the palisade, the closed gate) cuts the shot of a shooter with feet at [code]from[/code] and the aim on the left or
## right shoulder at the center of a target with feet at [code]to[/code] ([method bow_sight_clear] with the physics space
## of its world: the server's for the fakes, the client's for [code]--bot[/code]). It is asked at most once
## per target search ([constant COMBAT_RETARGET_TICKS]). Without it, it decides only with what it knows about the fort (the
## gate, the compound and the walkway).
func set_line_of_sight(query: Callable) -> void:
	_line_of_sight = query
	_sight_defender_tick = -1
	_sight_enemy_tick = -1


## true if the bot already knows how to ask about the line of fire ([method set_line_of_sight]).
func has_line_of_sight() -> bool:
	return _line_of_sight.is_valid()


## The line of fire of [method set_line_of_sight] in [param space], that of a server shot (docs/abilities.md,
## section 4.4) at a still target: the ray from the [param left_shoulder] camera that passes through the center
## ([constant AimRay.TARGET_CENTER_HEIGHT]) of the target with feet at [param to_feet] ([method AimRay.look_for]), which is
## the one that chooses the aimed point (if it hits a jamb first, the arrow goes to the jamb), and the muzzle line
## ([method AimRay.muzzle]) of the shooter with feet at [param from_feet] to that center, against the world and the structures
## ([constant HitShapes.LINE_OF_SIGHT_MASK]; the closed gate cuts them in both directions, the owner's too).
## Straight lines: arrow drop does not count. Without a space, true.
static func bow_sight_clear(space: PhysicsDirectSpaceState3D, from_feet: Vector3, to_feet: Vector3,
		left_shoulder: bool) -> bool:
	if space == null:
		return true
	var center: Vector3 = to_feet + Vector3(0.0, AimRay.TARGET_CENTER_HEIGHT, 0.0)
	var look: Vector2 = AimRay.look_for(from_feet, center, left_shoulder)
	var camera: Vector3 = AimRay.canonical(from_feet, look.x, look.y, left_shoulder)[0]
	# Like AimRay.aim_point: without hit_from_inside (the camera may end up inside a wall without it counting).
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(camera, center,
			HitShapes.LINE_OF_SIGHT_MASK)
	if not space.intersect_ray(query).is_empty():
		return false
	return HitShapes.is_ray_clear(space, AimRay.muzzle(from_feet), center)


## Kit: how many times it has done each thing since it was created: [code]ability_0[/code]..[code]ability_2[/code]
## (abilities per slot), [code]potion_0[/code] and [code]potion_1[/code], [code]swap[/code],
## [code]quick[/code] and [code]drawn[/code] (bow shots), [code]guard[/code] (walls raised),
## [code]execute[/code] and [code]revive[/code] (INTERACT held) and [code]dodge[/code]. It is a copy.
func get_kit_counts() -> Dictionary[StringName, int]:
	return _kit_counts.duplicate()


## What the kit uses [param ability] for ([enum KitRole]), by its data: a blocking channeling is
## [constant KitRole.GUARD]; a backward advance, [constant KitRole.ESCAPE] (even if it shoots); a shot,
## [constant KitRole.SHOT]; a forward advance, [constant KitRole.GAP_CLOSER]; a shaped strike,
## [constant KitRole.CLOSE].
static func kit_role(ability: AbilityTicks) -> KitRole:
	if ability == null:
		return KitRole.NONE
	if ability.channel and ability.blocks:
		return KitRole.GUARD
	if ability.dash_distance_m > 0.0 and ability.dash_direction == 1:
		return KitRole.ESCAPE
	if ability.projectile_id != 0:
		return KitRole.SHOT
	if ability.dash_distance_m > 0.0:
		return KitRole.GAP_CLOSER
	if ability.hit != null and ability.hit.shape != null:
		return KitRole.CLOSE
	return KitRole.NONE


## true if weapon [param weapon_id] shoots with the light attack (the bow).
static func is_ranged_weapon(weapon_id: int) -> bool:
	var weapon: WeaponTicks = CombatCatalog.weapon(weapon_id)
	if weapon == null or weapon.light_ids.is_empty():
		return false
	var light: AttackTicks = CombatCatalog.attack(weapon.light_ids[0])
	return light != null and light.projectile_id != 0


## [code](yaw, pitch)[/code] view of a shooter with feet at [param feet] and shoulder
## [param left_shoulder] so that an arrow of [param speed] m/s and [param gravity] m/s² hits the center of a
## target with feet at [param target_feet] moving at [param target_velocity] m/s (docs/abilities.md, section
## 4.4): the direction of [method Ballistics.solve_lead] from the muzzle [code]O[/code], the point
## [code]O + dir · |target − O|[/code] and the canonical ray that passes through it ([method AimRay.look_for]). The yaw is left
## in [0, TAU).
static func lead_look(feet: Vector3, target_feet: Vector3, target_velocity: Vector3, speed: float,
		gravity: float, left_shoulder: bool) -> Vector2:
	var center: Vector3 = target_feet + Vector3(0.0, AimRay.TARGET_CENTER_HEIGHT, 0.0)
	var muzzle: Vector3 = AimRay.muzzle(feet)
	var direction: Vector3 = Ballistics.solve_lead(muzzle, center, target_velocity, speed, gravity)
	var point: Vector3 = muzzle + direction * muzzle.distance_to(center)
	var look: Vector2 = AimRay.look_for(feet, point, left_shoulder)
	return Vector2(fposmod(look.x, TAU), look.y)


# Input of the COMBAT pattern, or null if there is no enemy in sight (then it strolls).
func _combat_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	_refresh_enemy(tick, position)
	var kit: CombatState = _kit_state()
	if kit != null:
		var reviving: PlayerInput = _revive_input(tick, position, yaw, kit)
		if reviving != null:
			return reviving
	if not _enemy_position is Vector3:
		_hold_until = -1
		return null
	var to_enemy: Vector3 = (_enemy_position as Vector3) - position
	to_enemy.y = 0.0
	var distance: float = to_enemy.length()
	if distance > COMBAT_SIGHT_RANGE:
		_hold_until = -1
		return null
	return _fight_input(tick, position, to_enemy, distance, yaw)


# Looks again for the nearest enemy every COMBAT_RETARGET_TICKS ticks. The finder may return the
# position (a Vector3) or a BotTarget (with the velocity and knockdown, which the kit uses).
func _refresh_enemy(tick: int, position: Vector3) -> void:
	if tick - _enemy_checked_tick >= COMBAT_RETARGET_TICKS:
		_enemy_checked_tick = tick
		var found: Variant = _enemy_finder.call(position) if _enemy_finder.is_valid() else null
		_enemy_velocity = Vector3.ZERO
		_enemy_downed = false
		if found is BotTarget:
			var target: BotTarget = found as BotTarget
			_enemy_position = target.position
			_enemy_velocity = target.velocity
			_enemy_downed = target.downed
		else:
			_enemy_position = found


# SIEGE: looks again for the nearest defending NPC every COMBAT_RETARGET_TICKS ticks (like _refresh_enemy: a
# position or a BotTarget).
func _refresh_defender(tick: int, position: Vector3) -> void:
	if tick - _siege_defender_checked_tick >= COMBAT_RETARGET_TICKS:
		_siege_defender_checked_tick = tick
		var found: Variant = _siege_defender_finder.call(position)
		_siege_defender_velocity = Vector3.ZERO
		_siege_defender_downed = false
		if found is BotTarget:
			var target: BotTarget = found as BotTarget
			_siege_defender_position = target.position
			_siege_defender_velocity = target.velocity
			_siege_defender_downed = target.downed
		else:
			_siege_defender_position = found


# Fights an enemy that is [param distance] meters away in direction [param to_enemy]: holds the
# button that was due, decides what to do at fight distance or approaches. With a combat state, with the kit
# ([param defender]: the target is the SIEGE defending NPC and not the enemy from set_enemy_finder).
func _fight_input(tick: int, position: Vector3, to_enemy: Vector3, distance: float,
		yaw: float, defender: bool = false) -> PlayerInput:
	var kit: CombatState = _kit_state()
	if kit != null:
		_fight_defender = defender
		return _kit_fight_input(tick, position, to_enemy, distance, yaw, kit)
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = _yaw_toward(to_enemy, yaw)
	if tick < _hold_until:
		# A held button (tap, block, heavy attack charge or dodge).
		input.buttons = _hold_buttons
		input.move = _hold_move
		return input
	if distance <= COMBAT_ENGAGE_DISTANCE and tick >= _next_decision_tick:
		_decide_combat_action(tick)
		if tick < _hold_until:
			input.buttons = _hold_buttons
			input.move = _hold_move
			return input
	# Approach to striking distance.
	if distance > COMBAT_ATTACK_DISTANCE:
		input.move = Vector2(0.0, 1.0)
		if distance > COMBAT_SPRINT_DISTANCE:
			input.buttons |= PlayerInput.SPRINT
	return input


# Chooses what to do at fight distance: block, dodge, charge a heavy attack or throw a light one.
func _decide_combat_action(tick: int) -> void:
	var roll: float = _rng.randf()
	_hold_move = Vector2.ZERO
	if roll < COMBAT_BLOCK_CHANCE:
		_hold_buttons = PlayerInput.BLOCK
		_hold_until = tick + _rng.randi_range(COMBAT_BLOCK_TICKS.x, COMBAT_BLOCK_TICKS.y)
		_next_decision_tick = _hold_until + 1
	elif roll < COMBAT_BLOCK_CHANCE + COMBAT_DODGE_CHANCE:
		# Dodge sideways or backward.
		_hold_buttons = PlayerInput.DODGE
		_hold_until = tick + 1
		_hold_move = Vector2(1.0 if _rng.randi() % 2 == 0 else -1.0, 0.0) if _rng.randf() < 0.7 \
				else Vector2(0.0, -1.0)
		if _siege_on_walkway_now:
			# On the walkway (no railing on the inside) a sideways dodge throws it into the courtyard: backward, along the axis
			# (it fights whoever is in front of it on it). The generator is used all the same.
			_hold_move = Vector2(0.0, -1.0)
		_next_decision_tick = tick + _rng.randi_range(COMBAT_ATTACK_GAP_TICKS.x,
				COMBAT_ATTACK_GAP_TICKS.y)
	elif roll < COMBAT_BLOCK_CHANCE + COMBAT_DODGE_CHANCE + COMBAT_HEAVY_CHANCE:
		_start_heavy_attack(tick)
	else:
		_start_light_attack(tick)


# A charged heavy attack: holds PRIMARY for a few ticks and waits before the next decision.
func _start_heavy_attack(tick: int) -> void:
	_hold_buttons = PlayerInput.PRIMARY
	_hold_until = tick + _rng.randi_range(COMBAT_HEAVY_HOLD_TICKS.x, COMBAT_HEAVY_HOLD_TICKS.y)
	_next_decision_tick = _hold_until + _rng.randi_range(COMBAT_ATTACK_GAP_TICKS.x,
			COMBAT_ATTACK_GAP_TICKS.y)


# A light attack: a short tap of PRIMARY (consecutive taps chain the combo).
func _start_light_attack(tick: int) -> void:
	_hold_buttons = PlayerInput.PRIMARY
	_hold_until = tick + COMBAT_TAP_TICKS
	_next_decision_tick = tick + _rng.randi_range(COMBAT_ATTACK_GAP_TICKS.x,
			COMBAT_ATTACK_GAP_TICKS.y)


# --- Kit (H5) -----------------------------------------------------------------------------------

# Combat state with which the kit decides, or null if there is none (or the kit is off).
func _kit_state() -> CombatState:
	if not use_kit or not _combat_source.is_valid():
		return null
	return _combat_source.call() as CombatState


# The target of the fight in progress (_fight_defender: the SIEGE defending NPC; otherwise, the enemy): its seen position
# (a Vector3 or null), its velocity, whether it is knocked down and the tick at which it was looked at.
func _target_position() -> Variant:
	return _siege_defender_position if _fight_defender else _enemy_position


func _target_velocity() -> Vector3:
	return _siege_defender_velocity if _fight_defender else _enemy_velocity


func _target_downed() -> bool:
	return _siege_defender_downed if _fight_defender else _enemy_downed


func _target_seen_tick() -> int:
	return _siege_defender_checked_tick if _fight_defender else _enemy_checked_tick


# Fights with the kit: holds what it was holding (aiming, with the bow), decides when it is time and, in between, approaches,
# keeps its distance or goes to finish off.
func _kit_fight_input(tick: int, position: Vector3, to_enemy: Vector3, distance: float, yaw: float,
		state: CombatState) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = _yaw_toward(to_enemy, yaw)
	if state.action == CombatState.Action.DOWNED or state.action == CombatState.Action.DEAD:
		_hold_until = -1
		_hold_kind = &""
		return input
	var ranged: bool = is_ranged_weapon(state.weapon_id)
	# A finisher is dropped if the target is no longer knocked down.
	if _hold_kind == &"execute" and not _target_downed():
		_hold_until = -1
	if tick >= _hold_until:
		_hold_kind = &""
		if tick >= _next_decision_tick:
			_decide_kit_action(tick, state, ranged, distance)
	if tick < _hold_until:
		input.buttons = _hold_buttons
		input.move = _hold_move
	elif _target_downed():
		if distance > KIT_INTERACT_REACH:
			input.move = Vector2(0.0, 1.0)
			if distance > COMBAT_SPRINT_DISTANCE:
				input.buttons |= PlayerInput.SPRINT
	elif ranged:
		_keep_bow_distance(input, tick, distance)
	elif _kit_shoot_plan:
		# SIEGE: it is going to shoot it with the bow (it is drawing it): it does not approach with the sword.
		pass
	elif distance > COMBAT_ATTACK_DISTANCE:
		input.move = Vector2(0.0, 1.0)
		if distance > COMBAT_SPRINT_DISTANCE:
			input.buttons |= PlayerInput.SPRINT
	if ranged:
		_aim(input, position, tick, state)
	return input


# Decides what the kit does: finish off, drink, swap weapon or, depending on the weapon, an ability, a shot or the phase 3
# behavior. What it decides is left in _hold_* and _next_decision_tick.
func _decide_kit_action(tick: int, state: CombatState, ranged: bool, distance: float) -> void:
	_hold_move = Vector2.ZERO
	_hold_buttons = 0
	_aim_speed = 0.0
	var data: CombatTables = CombatCatalog.tables()
	if _target_downed():
		if distance <= KIT_INTERACT_REACH and _can_interact(state):
			_hold(tick, PlayerInput.INTERACT, data.execute_ticks + KIT_INTERACT_MARGIN_TICKS, &"execute")
			_count(&"execute")
		return
	if _health_fraction() < KIT_HEALTH_POTION_BELOW \
			and _slot_ready(state, ActionMachine.STATUS_SLOT_CONSUMABLE_1, tick):
		_tap_consumable(tick, 0)
		return
	if float(state.stamina) < KIT_STAMINA_POTION_BELOW * float(data.rules.stamina_max) \
			and _slot_ready(state, ActionMachine.STATUS_SLOT_CONSUMABLE_2, tick):
		_tap_consumable(tick, 1)
		return
	if state.alt_weapon_id != 0 and state.action == CombatState.Action.NONE:
		var alt_ranged: bool = is_ranged_weapon(state.alt_weapon_id)
		# In SIEGE, if the fight is a shooting one (_kit_shoot_plan), the bow stays in hand and the sword is swapped for it
		# even if the target is close (the sword cannot reach: another level, or the palisade in between).
		if (ranged and not alt_ranged and distance < KIT_SWAP_TO_MELEE_DISTANCE and not kit_ranged_only
					and not _kit_shoot_plan) \
				or (not ranged and alt_ranged
					and (distance > KIT_SWAP_TO_RANGED_DISTANCE or kit_ranged_only or _kit_shoot_plan)):
			_tap(tick, PlayerInput.SWAP_WEAPON, data.swap_ticks + _gap())
			_count(&"swap")
			return
	if ranged:
		_decide_bow_action(tick, state, distance)
	else:
		_decide_melee_action(tick, state, distance)


# Melee: charge to close in, short strike up close, the wall or, failing that, the phase 3 behavior.
func _decide_melee_action(tick: int, state: CombatState, distance: float) -> void:
	var slots: Dictionary[int, int] = _ready_roles(state, tick)
	if slots.has(KitRole.GAP_CLOSER) and distance >= KIT_GAP_CLOSER_RANGE.x \
			and distance <= KIT_GAP_CLOSER_RANGE.y and _rng.randf() < KIT_GAP_CLOSER_CHANCE:
		_use_ability(tick, state, slots[KitRole.GAP_CLOSER])
		return
	if distance > COMBAT_ENGAGE_DISTANCE:
		return
	var roll: float = _rng.randf()
	if slots.has(KitRole.CLOSE) and distance <= KIT_CLOSE_DISTANCE and roll < KIT_CLOSE_CHANCE:
		_use_ability(tick, state, slots[KitRole.CLOSE])
	elif slots.has(KitRole.GUARD) and roll >= KIT_CLOSE_CHANCE \
			and roll < KIT_CLOSE_CHANCE + KIT_GUARD_CHANCE:
		_use_ability(tick, state, slots[KitRole.GUARD])
	else:
		_decide_combat_action(tick)
		if (_hold_buttons & PlayerInput.DODGE) != 0:
			_count(&"dodge")


# Bow: backstep if the enemy approaches, an occasional dodge, a shot ability or a shot (quick or
# drawn).
func _decide_bow_action(tick: int, state: CombatState, distance: float) -> void:
	var data: CombatTables = CombatCatalog.tables()
	var weapon: WeaponTicks = data.weapon(state.weapon_id)
	var slots: Dictionary[int, int] = _ready_roles(state, tick)
	if slots.has(KitRole.ESCAPE) and distance < KIT_ESCAPE_DISTANCE:
		_use_ability(tick, state, slots[KitRole.ESCAPE])
		return
	# On the SIEGE walkway the archer does not dodge: it does not move on it (while shooting, what moves it does not go along the axis; the
	# generator is used all the same).
	if distance < KIT_ESCAPE_DISTANCE and _rng.randf() < KIT_BOW_DODGE_CHANCE and not _siege_on_walkway_now:
		_hold_move = Vector2(0.0, -1.0)
		_tap(tick, PlayerInput.DODGE, (weapon.dodge.duration_ticks if weapon.dodge != null else 30) + _gap())
		_count(&"dodge")
		return
	var shots: Array[int] = _ready_shot_slots(state, tick)
	if not shots.is_empty() and _rng.randf() < KIT_SHOT_ABILITY_CHANCE:
		_use_ability(tick, state, shots[_rng.randi() % shots.size()])
		return
	var light: AttackTicks = data.attack(weapon.light_ids[0])
	var heavy: AttackTicks = data.attack(weapon.heavy_id)
	if heavy != null and not state.is_exhausted() and _rng.randf() < KIT_BOW_DRAWN_CHANCE:
		var held: int = _rng.randi_range(KIT_BOW_DRAW_TICKS.x, KIT_BOW_DRAW_TICKS.y)
		_hold(tick, PlayerInput.PRIMARY, held, &"draw")
		var launched: int = maxi(held, heavy.charge_min_ticks)
		_next_decision_tick = tick + launched + heavy.total_ticks + _gap()
		var launch: ProjectileLaunch = ProjectileLaunch.for_attack(heavy, mini(launched, heavy.charge_max_ticks))
		_set_aim(launch.speed if launch != null else heavy.projectile_speed_mps, heavy.projectile_id)
		_count(&"drawn")
		return
	_tap(tick, PlayerInput.PRIMARY, light.total_ticks + _gap())
	_set_aim(light.projectile_speed_mps, light.projectile_id)
	_count(&"quick")


# Uses the ability in slot [param slot] of the active weapon: the wall is held; the rest, a tap.
func _use_ability(tick: int, state: CombatState, slot: int) -> void:
	var data: CombatTables = CombatCatalog.tables()
	var ability: AbilityTicks = data.ability(data.weapon(state.weapon_id).ability_id(slot))
	var button: int = [PlayerInput.ABILITY_1, PlayerInput.ABILITY_2, PlayerInput.ABILITY_3][slot]
	if kit_role(ability) == KitRole.GUARD:
		var held: int = mini(_rng.randi_range(KIT_GUARD_HOLD_TICKS.x, KIT_GUARD_HOLD_TICKS.y),
				ability.active_to())
		_hold(tick, button, held, &"guard")
		_count(&"guard")
	else:
		_tap(tick, button, ability.total_ticks + _gap())
	if ability.projectile_id != 0:
		_set_aim(ability.projectile_speed_mps, ability.projectile_id)
	_count(StringName("ability_%d" % slot))


# The ready abilities of the active weapon by their role (the first slot of each role). On the SIEGE walkway (no
# railing on the inside), without those that advance in a straight line (the charge, which also pushes, and the backstep): like
# the sideways dodge, they threw both of them off it into the courtyard.
func _ready_roles(state: CombatState, tick: int) -> Dictionary[int, int]:
	var roles: Dictionary[int, int] = {}
	var weapon: WeaponTicks = CombatCatalog.weapon(state.weapon_id)
	if weapon == null:
		return roles
	for slot: int in CombatState.ABILITY_SLOTS:
		if not _slot_ready(state, slot, tick):
			continue
		var role: int = kit_role(CombatCatalog.ability(weapon.ability_id(slot)))
		if _siege_on_walkway_now and (role == KitRole.GAP_CLOSER or role == KitRole.ESCAPE):
			continue
		if role != KitRole.NONE and not roles.has(role):
			roles[role] = slot
	return roles


# Ready slots with a shot ability (without the backstep, which is for fleeing).
func _ready_shot_slots(state: CombatState, tick: int) -> Array[int]:
	var found: Array[int] = []
	var weapon: WeaponTicks = CombatCatalog.weapon(state.weapon_id)
	if weapon == null:
		return found
	for slot: int in CombatState.ABILITY_SLOTS:
		if _slot_ready(state, slot, tick) \
				and kit_role(CombatCatalog.ability(weapon.ability_id(slot))) == KitRole.SHOT:
			found.append(slot)
	return found


func _slot_ready(state: CombatState, slot: int, tick: int) -> bool:
	return ActionMachine.ability_status(state, slot, tick) == ActionMachine.AbilityStatus.READY


func _tap_consumable(tick: int, index: int) -> void:
	var ability: AbilityTicks = CombatCatalog.ability(CombatCatalog.consumable_ids()[index])
	_tap(tick, PlayerInput.CONSUMABLE_1 if index == 0 else PlayerInput.CONSUMABLE_2,
			(ability.total_ticks if ability != null else 60) + _gap())
	_count(StringName("potion_%d" % index))


# A tap of [param button] and the next decision within [param busy_ticks].
func _tap(tick: int, button: int, busy_ticks: int) -> void:
	_hold_buttons = button
	_hold_until = tick + COMBAT_TAP_TICKS
	_hold_kind = &""
	_next_decision_tick = tick + maxi(busy_ticks, COMBAT_TAP_TICKS)


# [param button] held [param ticks] ticks ([param kind]: what it is) and the next decision on release.
func _hold(tick: int, button: int, ticks: int, kind: StringName) -> void:
	_hold_buttons = button
	_hold_until = tick + ticks
	_hold_kind = kind
	_next_decision_tick = _hold_until + 1


func _gap() -> int:
	return _rng.randi_range(KIT_DECISION_GAP_TICKS.x, KIT_DECISION_GAP_TICKS.y)


func _count(key: StringName) -> void:
	_kit_counts[key] = int(_kit_counts.get(key, 0)) + 1


# Speed and gravity of the shot being aimed.
func _set_aim(speed: float, projectile_id: int) -> void:
	_aim_speed = speed
	var projectile: ProjectileTicks = CombatCatalog.projectile(projectile_id)
	_aim_gravity = projectile.gravity if projectile != null else 0.0


# Aims [param input] at the enemy with the lead of the relevant shot (the quick one if there is no other), with
# its position extrapolated since it was searched for.
func _aim(input: PlayerInput, position: Vector3, tick: int, state: CombatState) -> void:
	var seen: Variant = _target_position()
	if not seen is Vector3:
		return
	if _aim_speed <= 0.0:
		var weapon: WeaponTicks = CombatCatalog.weapon(state.weapon_id)
		var light: AttackTicks = CombatCatalog.attack(weapon.light_ids[0])
		_set_aim(light.projectile_speed_mps, light.projectile_id)
	var velocity: Vector3 = _target_velocity()
	var target: Vector3 = (seen as Vector3) + velocity * (float(tick - _target_seen_tick()) / Ballistics.TICK_RATE)
	var look: Vector2 = lead_look(position, target, velocity, _aim_speed, _aim_gravity, _aim_left)
	input.look_yaw = look.x
	input.look_pitch = minf(look.y + kit_aim_raise, _MAX_AIM_PITCH)
	if _aim_left:
		input.buttons |= PlayerInput.AIM_LEFT


# The archer stays between KIT_BOW_KEEP_MIN and KIT_BOW_KEEP_MAX from the enemy, moving sideways in between. On the
# SIEGE walkway (no railing on the inside) it stays still and shoots: while shooting, what moves it does not go along the axis, and
# any step could throw it into the courtyard.
func _keep_bow_distance(input: PlayerInput, tick: int, distance: float) -> void:
	if _siege_on_walkway_now:
		return
	if distance < KIT_BOW_KEEP_MIN:
		input.move = Vector2(0.0, -1.0)
	elif distance > KIT_BOW_KEEP_MAX:
		input.move = Vector2(0.0, 1.0)
		if distance > KIT_BOW_KEEP_MAX + COMBAT_SPRINT_DISTANCE:
			input.buttons |= PlayerInput.SPRINT
	else:
		if tick >= _kit_strafe_until:
			_kit_strafe_until = tick + _rng.randi_range(KIT_STRAFE_TICKS.x, KIT_STRAFE_TICKS.y)
			_kit_strafe_sign = 1.0 if _rng.randi() % 2 == 0 else -1.0
		input.move = Vector2(_kit_strafe_sign, 0.0)


func _can_interact(state: CombatState) -> bool:
	return state.action == CombatState.Action.NONE or state.action == CombatState.Action.BLOCK


func _health_fraction() -> float:
	return float(_health_source.call()) if _health_source.is_valid() else 1.0


# Reviving a knocked-down ally (COMBAT pattern with kit): keeps holding INTERACT if it already was; if there is a
# knocked-down ally nearby and no standing enemy on top of them, it goes toward them and holds INTERACT. null if not applicable.
func _revive_input(tick: int, position: Vector3, yaw: float, state: CombatState) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = yaw
	if _hold_kind == &"revive":
		if tick < _hold_until:
			input.buttons = _hold_buttons
			return input
		_hold_kind = &""
	if not _ally_finder.is_valid() or state.action == CombatState.Action.DOWNED \
			or state.action == CombatState.Action.DEAD:
		return null
	if tick - _ally_checked_tick >= COMBAT_RETARGET_TICKS:
		_ally_checked_tick = tick
		_ally_position = _ally_finder.call(position)
	if not _ally_position is Vector3:
		return null
	var to_ally: Vector3 = (_ally_position as Vector3) - position
	to_ally.y = 0.0
	var distance: float = to_ally.length()
	if distance > KIT_REVIVE_SEARCH or tick < _hold_until:
		return null
	if _enemy_position is Vector3 and not _enemy_downed \
			and position.distance_to(_enemy_position as Vector3) < KIT_REVIVE_ENEMY_CLEARANCE:
		return null
	input.look_yaw = _yaw_toward(to_ally, yaw)
	if distance <= KIT_INTERACT_REACH:
		if _can_interact(state):
			_hold(tick, PlayerInput.INTERACT,
					CombatCatalog.tables().revive_ticks + KIT_INTERACT_MARGIN_TICKS, &"revive")
			_count(&"revive")
			input.buttons = PlayerInput.INTERACT
		return input
	input.move = Vector2(0.0, 1.0)
	if distance > COMBAT_SPRINT_DISTANCE:
		input.buttons |= PlayerInput.SPRINT
	return input


# --- Siege --------------------------------------------------------------------------------------

# Input of the SIEGE pattern (there is always one).
func _siege_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	_note_siege_position(position)
	_siege_on_walkway_now = is_on_walkway(position)
	# 0. Out of the zone of a telegraphed strike, without blocking or finishing what it had in hand.
	var threat: Threat = _siege_threat_covering(position)
	if threat != null:
		if _siege_task != SiegeTask.EVADE:
			_siege_evade_since = tick
		_siege_task = SiegeTask.EVADE
		_hold_until = -1
		_hold_aims_gate = false
		_reset_stuck(tick, position)
		return _siege_evade_input(tick, position, yaw, threat)
	# An attack on the gate already started (a tap or a charged heavy attack) is finished.
	if _hold_aims_gate and tick < _hold_until:
		_siege_task = SiegeTask.ASSAULT
		return _gate_hold_input(tick, position, yaw)
	_hold_aims_gate = false

	# 1. A defending NPC in range that can be reached (what guards the fort while the circle is not active) and,
	# if there is none, any enemy.
	if _siege_defender_finder.is_valid() and not _siege.is_circle_active():
		_refresh_defender(tick, position)
		var fighting_defender: PlayerInput = _siege_fight_if_in_range(tick, position, yaw,
				_siege_defender_position, true)
		if fighting_defender != null:
			return fighting_defender
	if _enemy_finder.is_valid():
		_refresh_enemy(tick, position)
		var fighting: PlayerInput = _siege_fight_if_in_range(tick, position, yaw, _enemy_position, false)
		if fighting != null:
			return fighting
	_hold_until = -1

	# 2. On starting or after respawning in its camp, an attacker waits for its own (GUE-44).
	if _siege_rally_pending:
		_siege_rally_pending = false
		_siege_start_rally(tick, position)
	if _siege_rally_until >= 0:
		var waiting: PlayerInput = _siege_rally_input(tick, position, yaw)
		if waiting != null:
			return waiting

	# 3. The plan: march, assault the gate or stay in the circle.
	_ensure_route(position)
	var inside: bool = _siege_on_walkway_now or _siege_inside_fort(position)
	if inside:
		_siege_route_index = _siege_route_points.size()
	if _siege_route_index < _siege_route_points.size():
		_siege_task = SiegeTask.MARCH
		return _march_input(tick, position, yaw)
	var corner: Variant = _siege_around_enclosure(position)
	if corner is Vector3:
		_siege_task = SiegeTask.MARCH
		var to_corner: Vector3 = (corner as Vector3) - position
		to_corner.y = 0.0
		return _walk_input(tick, position, yaw, to_corner, to_corner.length())
	# The closed gate is only assaulted from outside. An attacker that is already inside (the gate was repaired with it in the
	# courtyard, or the fort changed owner with it on the walkway) continues with the walkway and the circle: the capture does not
	# need the gate, and the formation slot in front of it left it striking the air with its back to it.
	if not inside and _siege.is_gate_closed_for(_siege_realm) and _siege_has_places():
		_siege_task = SiegeTask.ASSAULT
		return _assault_input(tick, position, yaw)
	# 4. With the walkway role (GUE-45): the owner guards it and the attacker walks it once.
	var walkway: PlayerInput = _siege_walkway_input(tick, position, yaw)
	if walkway != null:
		return walkway
	_siege_task = SiegeTask.HOLD
	return _hold_circle_input(tick, position, yaw)


# Fights whoever is at [param target] (a position, or null; [param defender], if it is the defending NPC) if it applies
# (_siege_engagement); null if not. If, chasing it, it does not get closer within SIEGE_STUCK_TICKS, it stops chasing for a while
# (SIEGE_CHASE_GIVE_UP_TICKS); shooting it with the bow, it does not chase.
func _siege_fight_if_in_range(tick: int, position: Vector3, yaw: float, target: Variant,
		defender: bool) -> PlayerInput:
	if not target is Vector3:
		return null
	var target_feet: Vector3 = target
	var to_enemy: Vector3 = target_feet - position
	to_enemy.y = 0.0
	var distance: float = to_enemy.length()
	var engage: _Engage = _siege_engagement(position, target_feet, distance, defender)
	_kit_shoot_plan = engage == _Engage.SHOOT
	if engage == _Engage.SKIP:
		return null
	if engage == _Engage.SHOOT or distance <= COMBAT_ENGAGE_DISTANCE:
		# It has arrived (or shoots from where it is): if the other moves away again (a dodge, a step back) it is another
		# chase, measured from then and not from the distance at which the previous one started.
		_siege_chase_ref_tick = -1
	elif not _siege_keeps_chasing(tick, distance, target_feet, defender):
		return null
	_siege_task = SiegeTask.FIGHT
	_reset_stuck(tick, position)
	var heading: Vector3 = Vector3.ZERO
	if _siege_on_walkway_now and engage == _Engage.CLOSE:
		if distance > COMBAT_ENGAGE_DISTANCE:
			# On the walkway, if there is a corner between the two, the corner first: in a straight line it would fall into the courtyard.
			var enemy_point := Vector2(target_feet.x, target_feet.z)
			var corner: Variant = _siege_walkway_corner(Vector2(position.x, position.z),
					_siege_routes.walkway_offset(enemy_point))
			if corner is Vector2:
				var to_corner := Vector3((corner as Vector2).x - position.x, 0.0, (corner as Vector2).y - position.z)
				return _walk_input(tick, position, yaw, to_corner, to_corner.length())
		heading = _siege_walkway_heading(position, target_feet, yaw)
	var input: PlayerInput = _fight_input(tick, position, to_enemy, distance, yaw, defender)
	if heading != Vector3.ZERO:
		# On the walkway it faces the target (the weapon reaches even if it is at an angle, right next to it), but what moves
		# (approaching, the backward dodge) goes along its axis and not toward the courtyard: with the kit, in long fights, a
		# "backward" dodge with the other almost beside it threw it into the courtyard. Before the integration review it looked
		# along the axis and the one beside it was untouchable for it.
		input.move = _siege_move_along(input.move, heading, input.look_yaw)
	return input


# How it fights the target whose feet are at [param target] [param distance] meters away horizontally
# ([param defender]: the defending NPC). Without the kit, or to go finish off a knocked-down player (you have to arrive on foot), it approaches
# if within SIEGE_FIGHT_RANGE and can reach it (_can_reach). With the bow, it shoots if within
# SIEGE_BOW_FIGHT_RANGE and in line of fire (_siege_has_shot): with the bow in hand, unless it is so close that the kit draws the
# sword; with the sword in hand and the bow on its back, if it is further than the switch to the bow or if the sword cannot
# reach. With the bow in hand and no shot it does not fight (it would shoot at the palisade or the gate).
func _siege_engagement(position: Vector3, target: Vector3, distance: float, defender: bool) -> _Engage:
	var close: bool = distance <= SIEGE_FIGHT_RANGE and _can_reach(position, target)
	var kit: CombatState = _kit_state()
	var downed: bool = _siege_defender_downed if defender else _enemy_downed
	if kit == null or downed:
		return _Engage.CLOSE if close else _Engage.SKIP
	var bow_in_hand: bool = is_ranged_weapon(kit.weapon_id)
	var alt_ranged: bool = kit.alt_weapon_id != 0 and is_ranged_weapon(kit.alt_weapon_id)
	if not bow_in_hand and not alt_ranged:
		return _Engage.CLOSE if close else _Engage.SKIP
	# With the bow in hand, up close the kit draws the sword if it carries one (KIT_SWAP_TO_MELEE_DISTANCE).
	var to_sword: bool = bow_in_hand and kit.alt_weapon_id != 0 and not alt_ranged and not kit_ranged_only \
			and distance < KIT_SWAP_TO_MELEE_DISTANCE
	var shot: bool = distance <= SIEGE_BOW_FIGHT_RANGE and _siege_has_shot(position, target, defender)
	if not shot:
		if bow_in_hand and not to_sword:
			return _Engage.SKIP
		return _Engage.CLOSE if close else _Engage.SKIP
	if not close:
		return _Engage.SHOOT
	if bow_in_hand:
		return _Engage.CLOSE if to_sword else _Engage.SHOOT
	return _Engage.SHOOT if distance > KIT_SWAP_TO_RANGED_DISTANCE or kit_ranged_only else _Engage.CLOSE


# A chase (someone [param distance] meters away, at [param target], further than the fight distance; with
# [param defender], the defending NPC): false if it must be dropped, because it has gone SIEGE_STUCK_TICKS without getting closer or because it
# dropped it recently. It only measures consecutive chases of the same target: if the target changes (from the defender to the enemy or
# the reverse, or its position jumps more than SIEGE_TELEPORT_DISTANCE since the previous check: it is another one) it starts from zero.
func _siege_keeps_chasing(tick: int, distance: float, target: Vector3, defender: bool) -> bool:
	if tick < _siege_chase_blocked_until:
		return false
	var same_target: bool = defender == _siege_chase_defender \
			and target.distance_to(_siege_chase_target) <= SIEGE_TELEPORT_DISTANCE
	_siege_chase_defender = defender
	_siege_chase_target = target
	if not same_target or _siege_chase_ref_tick < 0 \
			or tick - _siege_chase_ref_tick > SIEGE_STUCK_TICKS + COMBAT_RETARGET_TICKS:
		# Starts (another chase, or the same one after a while without chasing).
		_siege_chase_ref_tick = tick
		_siege_chase_ref_distance = distance
		return true
	if tick - _siege_chase_ref_tick < SIEGE_STUCK_TICKS:
		return true
	if _siege_chase_ref_distance - distance < SIEGE_STUCK_MIN_PROGRESS:
		_siege_chase_blocked_until = tick + SIEGE_CHASE_GIVE_UP_TICKS
		_siege_chase_ref_tick = -1
		return false
	_siege_chase_ref_tick = tick
	_siege_chase_ref_distance = distance
	return true


# Records the position and, if it made a jump (respawn), resets the route and what it remembered.
func _note_siege_position(position: Vector3) -> void:
	if _siege_has_position and position.distance_to(_siege_last_position) > SIEGE_TELEPORT_DISTANCE:
		_reset_route()
		_hold_until = -1
		_hold_aims_gate = false
		_enemy_position = null
		_enemy_checked_tick = -1000
		_siege_defender_position = null
		_siege_defender_velocity = Vector3.ZERO
		_siege_defender_downed = false
		_siege_defender_checked_tick = -1000
		_enemy_velocity = Vector3.ZERO
		_enemy_downed = false
		_hold_kind = &""
		_kit_shoot_plan = false
		_sight_defender_tick = -1
		_sight_enemy_tick = -1
		_siege_chase_ref_tick = -1
		_siege_chase_blocked_until = -1
		_siege_rally_until = -1
		_siege_rally_pending = true
	_siege_has_position = true
	_siege_last_position = position


# The nearest telegraphed strike in whose zone [param position] is (with [constant SIEGE_THREAT_MARGIN]), or null.
func _siege_threat_covering(position: Vector3) -> Threat:
	if not _siege_threat_finder.is_valid():
		return null
	var found: Variant = _siege_threat_finder.call(position)
	if not found is Array:
		return null
	var best: Threat = null
	var best_distance: float = INF
	for item: Variant in found:
		var candidate: Threat = item as Threat
		if candidate == null or not candidate.covers(position, SIEGE_THREAT_MARGIN):
			continue
		if not _siege_same_level(position, candidate.origin):
			# A strike from the courtyard does not reach the walkway, nor the reverse (GUE-45).
			continue
		var distance: float = Vector2(position.x - candidate.origin.x, position.z - candidate.origin.z).length()
		if distance < best_distance:
			best_distance = distance
			best = candidate
	return best


# Leave the zone of [param threat]: in a straight line away from the striker (backward from its strike if it is right
# on top), with a dodge at the start (and another every SIEGE_EVADE_DODGE_TICKS if still inside) and sprinting in
# between.
func _siege_evade_input(tick: int, position: Vector3, yaw: float, threat: Threat) -> PlayerInput:
	var away := Vector3(position.x - threat.origin.x, 0.0, position.z - threat.origin.z)
	if away.length_squared() < 0.01:
		away = Vector3(sin(threat.yaw), 0.0, cos(threat.yaw))
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = _yaw_toward(away, yaw)
	input.move = Vector2(0.0, 1.0)
	input.buttons |= PlayerInput.SPRINT
	if (tick - _siege_evade_since) % SIEGE_EVADE_DODGE_TICKS == 0:
		input.buttons |= PlayerInput.DODGE
	return input


func _reset_route() -> void:
	_siege_route_id = &""
	_siege_route_chosen = false
	_siege_route_points = PackedVector2Array()
	_siege_route_index = 0
	_siege_stuck_count = 0
	_siege_unstick = _Unstick.NONE
	_siege_unstick_until = -1
	_siege_stuck_ref_tick = -1
	_siege_walkway_swept = false
	_siege_climb_ramp = -1
	_siege_climb_index = -1


# Chooses the route (with the bot's generator) if it has none yet, and which point it starts at.
func _ensure_route(position: Vector3) -> void:
	if _siege_route_chosen:
		return
	_siege_route_chosen = true
	var candidates: Array[StringName] = _siege_route_candidates()
	if candidates.is_empty():
		return
	_siege_set_route(candidates[_rng.randi() % candidates.size()], position)


# The routes that exist for its realm, in the order of ApproachRoutes.get_route_ids (empty without routes).
func _siege_route_candidates() -> Array[StringName]:
	var candidates: Array[StringName] = []
	if _siege_routes == null:
		return candidates
	var realm_id: StringName = RealmCatalog.id_of_code(_siege_realm)
	for route: StringName in _siege_routes.get_route_ids():
		if _siege_routes.has_route(route, realm_id):
			candidates.append(route)
	return candidates


# Follows route [param route] of its realm from the point nearest to [param position].
func _siege_set_route(route: StringName, position: Vector3) -> void:
	var realm_id: StringName = RealmCatalog.id_of_code(_siege_realm)
	_siege_route_id = route
	_siege_route_points = _siege_routes.get_points(route, realm_id)
	_siege_route_index = maxi(_siege_routes.get_nearest_index(route, realm_id, Vector2(position.x, position.z)), 0)


# --- Rally (GUE-44) -----------------------------------------------------------------------------

# true if it waits for its own on starting or respawning: it has something to count them for it and a group of more than one.
func _siege_rally_enabled() -> bool:
	return _siege_rally_size > 1 and _siege_ally_counter.is_valid()


# true if it goes in a group and, therefore, each one in its slot (the formation goes with the rally).
func _siege_in_formation() -> bool:
	return _siege_rally_enabled()


# On starting or respawning: if it is an attacker and is in its camp (within SIEGE_RALLY_RADIUS of the rally
# point), it waits for its own at most until the next departure of the clock.
func _siege_start_rally(tick: int, position: Vector3) -> void:
	if not _siege_rally_enabled() or _siege.owner == _siege_realm:
		return
	var point: Variant = get_siege_rally_point()
	if not point is Vector3:
		return
	var rally: Vector3 = point
	if Vector2(position.x - rally.x, position.z - rally.z).length() > SIEGE_RALLY_RADIUS:
		return
	_siege_rally_until = next_rally_departure(tick, _siege_rally_period)


# Waits at the rally point: goes to its slot in it and stays there still, facing the fort.
# null if it stops waiting (there are enough already, the clock fires, or it is now the owner and must defend); then it takes the
# group's route and continues with its plan.
func _siege_rally_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	var point: Variant = get_siege_rally_point()
	if _siege.owner == _siege_realm or not point is Vector3 or not _siege_rally_enabled():
		_siege_rally_until = -1
		return null
	var rally: Vector3 = point
	var counted: Variant = _siege_ally_counter.call(rally, SIEGE_RALLY_RADIUS)
	var gathered: int = 1 + (maxi(int(counted), 0) if counted is int else 0)
	var fighting: int = 0
	if _siege_has_places():
		var at_fort: Variant = _siege_ally_counter.call(_siege.circle_center, SIEGE_RALLY_FORT_RADIUS)
		fighting = maxi(int(at_fort), 0) if at_fort is int else 0
	if gathered >= _siege_rally_size or fighting >= SIEGE_RALLY_JOIN_COUNT or tick >= _siege_rally_until:
		_siege_rally_until = -1
		_siege_rally_left_tick = tick
		_siege_take_group_route(tick, position)
		return null
	_siege_task = SiegeTask.RALLY
	var spot: Vector3 = rally + Vector3(_siege_slot.x, 0.0, _siege_slot.y) * SIEGE_SLOT_RALLY_SPREAD
	var to_spot := Vector3(spot.x - position.x, 0.0, spot.z - position.z)
	var distance: float = to_spot.length()
	if distance > SIEGE_SLOT_REACHED:
		return _walk_input(tick, position, yaw, to_spot, distance)
	_reset_stuck(tick, position)
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = yaw
	if _siege_has_places():
		var to_gate: Vector3 = _siege.gate_position - position
		to_gate.y = 0.0
		input.look_yaw = _yaw_toward(to_gate, yaw)
	return input


# On leaving the rally, the group's route (that of the clock cycle in which it leaves, rally_route_index), without the
# generator: all who leave on the same tick take the same one.
func _siege_take_group_route(tick: int, position: Vector3) -> void:
	_siege_route_chosen = true
	var candidates: Array[StringName] = _siege_route_candidates()
	if candidates.is_empty():
		return
	_siege_set_route(candidates[rally_route_index(tick, candidates.size(), _siege_rally_period)], position)


# March: toward the route point that applies, sprinting if far and no enemies nearby.
func _march_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	var target: Vector2 = _siege_route_points[_siege_route_index]
	var to_target := Vector3(target.x - position.x, 0.0, target.y - position.z)
	var distance: float = to_target.length()
	if distance > SIEGE_LOST_DISTANCE:
		# It strayed very far from the route (a fight, a fall): resumes at the nearest point.
		_siege_route_index = maxi(_siege_routes.get_nearest_index(_siege_route_id,
				RealmCatalog.id_of_code(_siege_realm), Vector2(position.x, position.z)), 0)
		target = _siege_route_points[_siege_route_index]
		to_target = Vector3(target.x - position.x, 0.0, target.y - position.z)
		distance = to_target.length()
	if _siege_in_formation():
		# Sideways relative to the segment leading to this point (or to the direction toward it, on the first).
		var along := Vector2(to_target.x, to_target.z)
		if _siege_route_index > 0:
			along = target - _siege_route_points[_siege_route_index - 1]
		if along.length_squared() > 0.0001:
			var side: Vector2 = Vector2(-along.y, along.x).normalized() * _siege_slot.x * SIEGE_SLOT_MARCH_SPREAD
			to_target += Vector3(side.x, 0.0, side.y)
			distance = to_target.length()
	if distance <= SIEGE_WAYPOINT_RADIUS:
		_siege_route_index += 1
	return _walk_input(tick, position, yaw, to_target, distance)


# Assault: approaches the gate and strikes it. In formation, from its spot along the gate and facing it head-on.
func _assault_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	var to_gate: Vector3 = _siege.gate_position - position
	to_gate.y = 0.0
	var distance: float = to_gate.length()
	var facing: Vector3 = to_gate
	var inward: Vector3 = _siege_inward()
	if _siege_in_formation() and inward != Vector3.ZERO:
		var across := Vector3(-inward.z, 0.0, inward.x)
		var spot: Vector3 = _siege.gate_position - inward * SIEGE_GATE_ATTACK_DISTANCE \
				+ across * (_siege_slot.x * SIEGE_SLOT_GATE_SPREAD)
		var to_spot := Vector3(spot.x - position.x, 0.0, spot.z - position.z)
		if to_spot.length() > SIEGE_SLOT_REACHED and distance > SIEGE_GATE_ATTACK_DISTANCE * 0.5:
			return _walk_input(tick, position, yaw, to_spot, to_spot.length())
		facing = inward
	elif distance > SIEGE_GATE_ATTACK_DISTANCE:
		return _walk_input(tick, position, yaw, to_gate, distance)
	_reset_stuck(tick, position)
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = _yaw_toward(facing, yaw)
	if tick >= _next_decision_tick:
		_hold_aims_gate = true
		if _kit_swaps_to_sword_for_gate(tick):
			# With the kit, the gate is struck with the sword if it carries one: with arrows it took off about 2.6 times less.
			input.buttons = _hold_buttons
			return input
		if _rng.randf() < COMBAT_HEAVY_CHANCE:
			_start_heavy_attack(tick)
		else:
			_start_light_attack(tick)
		input.buttons = _hold_buttons
	return input


# Kit, gate assault: with the bow in hand and the sword on its back (and not being a pure archer, kit_ranged_only),
# it presses the weapon swap as soon as it can (no action in progress; meanwhile it does not strike). true if it is not time to strike: it has
# pressed the swap (left in _hold_* and _next_decision_tick, like a tap) or is waiting for it.
func _kit_swaps_to_sword_for_gate(tick: int) -> bool:
	var kit: CombatState = _kit_state()
	if kit == null or kit_ranged_only or kit.alt_weapon_id == 0:
		return false
	if not is_ranged_weapon(kit.weapon_id) or is_ranged_weapon(kit.alt_weapon_id):
		return false
	_hold_buttons = 0
	if kit.action != CombatState.Action.NONE:
		return true
	_hold_move = Vector2.ZERO
	_tap(tick, PlayerInput.SWAP_WEAPON, CombatCatalog.tables().swap_ticks + _gap())
	_count(&"swap")
	return true


# An attack on the gate that continues: PRIMARY held facing the gate (in formation, head-on, as when starting it).
func _gate_hold_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	var to_gate: Vector3 = _siege.gate_position - position
	to_gate.y = 0.0
	var inward: Vector3 = _siege_inward()
	if _siege_in_formation() and inward != Vector3.ZERO:
		to_gate = inward
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = _yaw_toward(to_gate, yaw)
	input.buttons = _hold_buttons
	return input


# Circle: toward its center and, inside, still facing the gate (where enemies arrive from).
func _hold_circle_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	if not _siege_has_places():
		_reset_stuck(tick, position)
		var idle := PlayerInput.new()
		idle.tick = tick
		idle.look_yaw = yaw
		return idle
	var waypoint: Variant = _gate_waypoint(position)
	if waypoint is Vector3:
		var to_waypoint: Vector3 = (waypoint as Vector3) - position
		to_waypoint.y = 0.0
		return _walk_input(tick, position, yaw, to_waypoint, to_waypoint.length())
	var to_center: Vector3 = _siege.circle_center - position
	to_center.y = 0.0
	var distance: float = to_center.length()
	var circle_radius: float = _siege.circle_radius if _siege.circle_radius > 0.0 \
			else SIEGE_DEFAULT_CIRCLE_RADIUS
	var inward: Vector3 = _siege_inward()
	if _siege_in_formation() and inward != Vector3.ZERO:
		# Its spot in the circle: the center plus its slot (sideways and in depth).
		var across := Vector3(-inward.z, 0.0, inward.x)
		var spread: float = minf(SIEGE_SLOT_CIRCLE_SPREAD, circle_radius * SIEGE_CIRCLE_HOLD_FRACTION)
		var spot: Vector3 = _siege.circle_center + (across * _siege_slot.x + inward * _siege_slot.y) * spread
		var to_spot := Vector3(spot.x - position.x, 0.0, spot.z - position.z)
		if to_spot.length() > SIEGE_SLOT_REACHED:
			return _walk_input(tick, position, yaw, to_spot, to_spot.length())
	elif distance > circle_radius * SIEGE_CIRCLE_HOLD_FRACTION:
		return _walk_input(tick, position, yaw, to_center, distance)
	_reset_stuck(tick, position)
	var input := PlayerInput.new()
	input.tick = tick
	var to_gate: Vector3 = _siege.gate_position - position
	to_gate.y = 0.0
	input.look_yaw = _yaw_toward(to_gate, yaw)
	return input


# To enter the fort from outside: the point to go to before the circle (in front of the gate, aligned
# with its axis, and then a bit inside), or null if it has already crossed the gate or does not know where it is.
func _gate_waypoint(position: Vector3) -> Variant:
	var inward: Vector3 = _siege_inward()
	if inward == Vector3.ZERO:
		return null
	var from_gate: Vector3 = position - _siege.gate_position
	from_gate.y = 0.0
	var along: float = from_gate.dot(inward)
	if along >= 0.5:
		return null
	var lateral: float = (from_gate - inward * along).length()
	if lateral > SIEGE_GATE_AXIS_TOLERANCE and (along < -2.0 or lateral > SIEGE_GATE_OPENING_HALF_WIDTH):
		return _siege.gate_position - inward * SIEGE_GATE_FRONT_DISTANCE
	return _siege.gate_position + inward * SIEGE_GATE_EXIT_DISTANCE


# Walk toward [param to_target] (at [param distance] meters): sprints if far and no enemies
# nearby, and gets unstuck with a jump and, afterwards, with a detour.
func _walk_input(tick: int, position: Vector3, yaw: float, to_target: Vector3,
		distance: float) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = _yaw_toward(to_target, yaw)
	input.move = Vector2(0.0, 1.0)
	if distance > SIEGE_SPRINT_DISTANCE and _enemies_clear(position):
		input.buttons |= PlayerInput.SPRINT
	_apply_unstick(tick, position, input)
	return input


# true if the last enemy seen is far away (or there is none).
func _enemies_clear(position: Vector3) -> bool:
	if not _enemy_position is Vector3:
		return true
	return position.distance_to(_enemy_position as Vector3) > SIEGE_SPRINT_ENEMY_CLEARANCE


# If it has spent SIEGE_STUCK_TICKS walking without advancing, it tries a jump and, if still the same, a lateral detour
# (and starts over); modifies [param input] for the duration of the attempt.
func _apply_unstick(tick: int, position: Vector3, input: PlayerInput) -> void:
	if tick < _siege_unstick_until:
		match _siege_unstick:
			_Unstick.JUMP:
				if (tick - _siege_unstick_start) % SIEGE_JUMP_PULSE_TICKS < JUMP_HOLD_TICKS.x:
					input.buttons |= PlayerInput.JUMP
			_Unstick.DETOUR:
				input.look_yaw = fposmod(input.look_yaw + _detour_sign * SIEGE_DETOUR_ANGLE, TAU)
		return
	if _siege_stuck_ref_tick < 0 or _siege_unstick != _Unstick.NONE:
		# An attempt that ends counts from zero.
		_siege_unstick = _Unstick.NONE
		_siege_stuck_ref_position = position
		_siege_stuck_ref_tick = tick
		return
	if tick - _siege_stuck_ref_tick < SIEGE_STUCK_TICKS:
		return
	var moved: float = Vector2(position.x - _siege_stuck_ref_position.x,
			position.z - _siege_stuck_ref_position.z).length()
	_siege_stuck_ref_position = position
	_siege_stuck_ref_tick = tick
	if moved >= SIEGE_STUCK_MIN_PROGRESS:
		_siege_stuck_count = 0
		return
	_siege_stuck_count += 1
	_siege_unstick_start = tick
	if _siege_stuck_count % 2 == 1:
		_siege_unstick = _Unstick.JUMP
		_siege_unstick_until = tick + SIEGE_JUMP_WINDOW_TICKS
		if (tick - _siege_unstick_start) % SIEGE_JUMP_PULSE_TICKS < JUMP_HOLD_TICKS.x:
			input.buttons |= PlayerInput.JUMP
	else:
		_siege_unstick = _Unstick.DETOUR
		_siege_unstick_until = tick + SIEGE_DETOUR_TICKS
		_detour_sign = 1.0 if _rng.randi() % 2 == 0 else -1.0
		input.look_yaw = fposmod(input.look_yaw + _detour_sign * SIEGE_DETOUR_ANGLE, TAU)


# What is not walking (fighting, striking the gate, waiting in the circle) is not being stuck.
func _reset_stuck(tick: int, position: Vector3) -> void:
	_siege_stuck_count = 0
	_siege_unstick = _Unstick.NONE
	_siege_unstick_until = -1
	_siege_stuck_ref_position = position
	_siege_stuck_ref_tick = tick


# true if there are positions for the gate and the circle (without them the bot only follows its route).
func _siege_has_places() -> bool:
	return _siege.circle_radius > 0.0 or _siege.circle_center != Vector3.ZERO \
			or _siege.gate_position != Vector3.ZERO


# Outside the compound, beside a wall that is not the gate's or behind the fort: the corner to go to in order to go around it
# toward the gate wall (on the side it is on), or null if it is inside, in front of the gate wall
# or the compound size is unknown. Without this it went straight for the circle and stayed stuck against the palisade.
func _siege_around_enclosure(position: Vector3) -> Variant:
	if _siege.is_inside_enclosure(position, SIEGE_ENCLOSURE_MARGIN) != 0:
		return null
	var inward: Vector3 = _siege_inward()
	var across := Vector3(-inward.z, 0.0, inward.x)
	var offset: Vector3 = position - _siege.gate_position
	offset.y = 0.0
	var along: float = offset.dot(inward)
	var lateral: float = offset.dot(across)
	var half_width: float = _siege.enclosure_size.y * 0.5
	var beside: bool = absf(lateral) >= half_width - SIEGE_ENCLOSURE_MARGIN
	var behind: bool = along >= _siege.enclosure_size.x - SIEGE_ENCLOSURE_MARGIN
	if along < 0.0 or (not beside and not behind):
		# In front of the gate wall, or in its doorway: the route and the gate take care of that.
		return null
	var side: float = 1.0 if lateral >= 0.0 else -1.0
	var corner_lateral: float = side * (half_width + SIEGE_CORNER_MARGIN)
	var corner_along: float = -SIEGE_CORNER_MARGIN
	if along > _siege.enclosure_size.x and absf(lateral) < half_width + SIEGE_CORNER_MARGIN - SIEGE_WAYPOINT_RADIUS:
		# Behind the back wall: first the back corner on its side.
		corner_along = _siege.enclosure_size.x + SIEGE_CORNER_MARGIN
	var target: Vector3 = _siege.gate_position + inward * corner_along + across * corner_lateral
	target.y = position.y
	return target


# true if [param position] is inside the fort: inside the compound if the [SiegeView] knows its size and, if not, on the
# other side of the gate, looking from outside, and near the circle.
func _siege_inside_fort(position: Vector3) -> bool:
	if not _siege_has_places():
		return false
	var inward: Vector3 = _siege_inward()
	if inward == Vector3.ZERO:
		return false
	var enclosure: int = _siege.is_inside_enclosure(position, SIEGE_ENCLOSURE_MARGIN)
	if enclosure >= 0:
		return enclosure == 1
	var from_gate: Vector3 = position - _siege.gate_position
	from_gate.y = 0.0
	var from_circle: Vector3 = position - _siege.circle_center
	from_circle.y = 0.0
	return from_gate.dot(inward) > 0.0 and from_circle.length() <= SIEGE_INSIDE_RADIUS


# Horizontal direction from the gate toward the circle (toward the inside of the fort); zero if unknown.
func _siege_inward() -> Vector3:
	var inward: Vector3 = _siege.circle_center - _siege.gate_position
	inward.y = 0.0
	return inward.normalized() if inward.length_squared() > 0.0001 else Vector3.ZERO


# true if the bot can walk to [param target] (to strike it in melee or finish it off): it is at its level
# (GUE-45) and not on the other side of a gate that blocks its way. The bow shot is decided by _siege_has_shot.
func _can_reach(position: Vector3, target: Vector3) -> bool:
	if not _siege_same_level(position, target):
		return false
	if not _siege.is_gate_closed_for(_siege_realm) or not _siege_has_places():
		return true
	var inward: Vector3 = _siege_inward()
	if inward == Vector3.ZERO:
		return true
	var mine: Vector3 = position - _siege.gate_position
	var theirs: Vector3 = target - _siege.gate_position
	mine.y = 0.0
	theirs.y = 0.0
	return (mine.dot(inward) > 0.0) == (theirs.dot(inward) > 0.0)


# true if the bot has a bow shot at the target whose feet are at [param target] ([param defender]: the defending NPC):
# allowed by what it knows about the fort (_siege_open_shot) and the line of fire from set_line_of_sight, if it has one. The line is
# asked once per target search (its tick, which changes every COMBAT_RETARGET_TICKS).
func _siege_has_shot(position: Vector3, target: Vector3, defender: bool) -> bool:
	if not _siege_open_shot(position, target):
		return false
	if not _line_of_sight.is_valid():
		return true
	if defender:
		if _sight_defender_tick != _siege_defender_checked_tick:
			_sight_defender_tick = _siege_defender_checked_tick
			_sight_defender = bool(_line_of_sight.call(position, target, _aim_left))
		return _sight_defender
	if _sight_enemy_tick != _enemy_checked_tick:
		_sight_enemy_tick = _enemy_checked_tick
		_sight_enemy = bool(_line_of_sight.call(position, target, _aim_left))
	return _sight_enemy


# What it knows about the fort regarding a shot from [param position] to [param target]: the palisade and the intact gate cut the
# shot between inside and outside the compound for all realms (the owner too: the sight body of its gate for
# arrows in both directions), and with the gate broken one only shoots from one side to the other through the doorway. From the walkway, or at
# someone on it, the line of fire decides (the parapet). Without the compound size, the intact gate cuts the
# shot between the two sides of its plane. Without fort positions, true.
func _siege_open_shot(position: Vector3, target: Vector3) -> bool:
	if not _siege_has_places():
		return true
	if _siege_on_walkway_now or is_on_walkway(target):
		return true
	var mine: int = _siege.is_inside_enclosure(position)
	var theirs: int = _siege.is_inside_enclosure(target)
	if mine < 0 or theirs < 0:
		if _siege.is_gate_broken():
			return true
		var inward: Vector3 = _siege_inward()
		var from_gate: Vector3 = position - _siege.gate_position
		var to_gate: Vector3 = target - _siege.gate_position
		from_gate.y = 0.0
		to_gate.y = 0.0
		return inward == Vector3.ZERO or (from_gate.dot(inward) > 0.0) == (to_gate.dot(inward) > 0.0)
	if mine == theirs:
		return true
	if not _siege.is_gate_broken():
		return false
	return _siege_through_gap(position if mine == 1 else target, target if mine == 1 else position)


# true if the line (in plan view) from [param inside] (inside the compound) to [param outside] (outside) exits through the gate
# doorway: it crosses the gate wall, and within SIEGE_BOW_GAP_HALF_WIDTH of its center. The compound is convex, so
# if it crosses that wall within its width it crosses no other.
func _siege_through_gap(inside: Vector3, outside: Vector3) -> bool:
	var inward: Vector3 = _siege_inward()
	if inward == Vector3.ZERO:
		return false
	var across := Vector3(-inward.z, 0.0, inward.x)
	var a: Vector3 = inside - _siege.gate_position
	var b: Vector3 = outside - _siege.gate_position
	var a_along: float = a.x * inward.x + a.z * inward.z
	var b_along: float = b.x * inward.x + b.z * inward.z
	if a_along <= 0.0 or b_along >= 0.0:
		return false
	var t: float = a_along / (a_along - b_along)
	var a_side: float = a.x * across.x + a.z * across.z
	var b_side: float = b.x * across.x + b.z * across.z
	return absf(a_side + (b_side - a_side) * t) <= SIEGE_BOW_GAP_HALF_WIDTH


# [param move] (in the frame of a character facing [param heading]: y forward, x to its right) converted
# to the frame of [param look_yaw], the one it truly faces: the same displacement in the world. The simulation moves (and dodges)
# relative to the camera yaw (PlayerCharacter.simulate and ActionMachine._dodge_yaw).
static func _siege_move_along(move: Vector2, heading: Vector3, look_yaw: float) -> Vector2:
	if move == Vector2.ZERO:
		return move
	var side := Vector3(-heading.z, 0.0, heading.x)
	var world: Vector3 = heading * move.y + side * move.x
	var forward := Vector3(-sin(look_yaw), 0.0, -cos(look_yaw))
	var right := Vector3(cos(look_yaw), 0.0, -sin(look_yaw))
	return Vector2(world.dot(right), world.dot(forward))


# --- Walkway (GUE-45) ---------------------------------------------------------------------------

# true if [param a] and [param b] are at a level from which they reach each other: within SIEGE_LEVEL_TOLERANCE vertically,
# or both outside the compound (the slopes outside are not levels: nothing changes there). Without a known compound, always.
func _siege_same_level(a: Vector3, b: Vector3) -> bool:
	if absf(a.y - b.y) <= SIEGE_LEVEL_TOLERANCE or not _siege_has_places():
		return true
	return _siege.is_inside_enclosure(a) != 1 and _siege.is_inside_enclosure(b) != 1


# true if the bot has to go to the walkway: the routes know it, and it is either the owner and guards it, or an attacker and
# walks it, has not yet done so in this life and is already inside the fort (or on it).
func _siege_walkway_wanted(position: Vector3) -> bool:
	if _siege_routes == null or not _siege_routes.has_walkway() or not _siege_has_places():
		return false
	if _siege.should_defend(_siege_realm):
		return _siege_walkway_role
	if not _siege_walkway_sweeper or _siege_walkway_swept:
		return false
	return _siege_on_walkway_now or _siege_inside_fort(position)


# Meters along the walkway axis of its post: above the gate, plus its sideways slot.
func _siege_walkway_post_offset() -> float:
	var post: float = _siege_routes.walkway_offset(_siege_routes.walkway_post())
	return clampf(post + _siege_slot.x * SIEGE_WALKWAY_POST_SPREAD, 0.0, _siege_routes.walkway_length())


# The walkway: enters the fort if outside, climbs the ramp that applies to it, goes along the axis to its post and there
# guards it facing outward (the owner) or counts the walkway as walked and continues with its plan (the attacker, who jumps down to the courtyard
# on the way to the circle). null if it does not have to go.
func _siege_walkway_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	if not _siege_walkway_wanted(position):
		_siege_climb_ramp = -1
		return null
	var here := Vector2(position.x, position.z)
	var post_offset: float = _siege_walkway_post_offset()
	if _siege_on_walkway_now and _siege_climb_ramp >= 0:
		# The top of the ramp already counts as walkway, but until the summit (on the axis) it keeps climbing: if it turned earlier,
		# it would leave the ramp from the side.
		var ramp: PackedVector2Array = _siege_routes.walkway_ramps[_siege_climb_ramp]
		var top: Vector2 = ramp[ramp.size() - 1]
		if _siege_climb_index >= ramp.size() - 1 and here.distance_to(top) > SIEGE_WALKWAY_REACHED:
			_siege_task = SiegeTask.WALKWAY
			var to_top := Vector3(top.x - position.x, 0.0, top.y - position.z)
			return _walk_input(tick, position, yaw, to_top, to_top.length())
		_siege_climb_ramp = -1
	if _siege_on_walkway_now:
		var axis: Vector2 = _siege_routes.walkway_point(_siege_routes.walkway_offset(here))
		if here.distance_to(axis) > SIEGE_WALKWAY_REACHED:
			# Off the axis (a fight, a dodge): first it returns to it, away from the inside edge.
			_siege_task = SiegeTask.WALKWAY
			var to_axis := Vector3(axis.x - position.x, 0.0, axis.y - position.z)
			return _walk_input(tick, position, yaw, to_axis, to_axis.length())
		var post: Vector2 = _siege_routes.walkway_point(post_offset)
		if here.distance_to(post) <= SIEGE_WALKWAY_REACHED:
			if not _siege.should_defend(_siege_realm):
				_siege_walkway_swept = true
				return null
			_siege_task = SiegeTask.WALKWAY
			_reset_stuck(tick, position)
			var holding := PlayerInput.new()
			holding.tick = tick
			holding.look_yaw = _yaw_toward(-_siege_inward(), yaw)
			return holding
		_siege_task = SiegeTask.WALKWAY
		var next: Vector2 = _siege_walkway_next(here, post_offset)
		var to_next := Vector3(next.x - position.x, 0.0, next.y - position.z)
		return _walk_input(tick, position, yaw, to_next, to_next.length())
	_siege_task = SiegeTask.WALKWAY
	var waypoint: Variant = _gate_waypoint(position)
	if waypoint is Vector3:
		var to_waypoint: Vector3 = (waypoint as Vector3) - position
		to_waypoint.y = 0.0
		return _walk_input(tick, position, yaw, to_waypoint, to_waypoint.length())
	var target: Vector2 = _siege_climb_target(here, post_offset)
	var to_target := Vector3(target.x - position.x, 0.0, target.y - position.z)
	return _walk_input(tick, position, yaw, to_target, to_target.length())


# The ramp point it heads to: the ramp whose summit is closest to its post along the walkway (on a tie,
# the first), starting from the nearest courtyard point; it reaches them at SIEGE_WALKWAY_REACHED. If it was heading to the summit and
# strayed from the ramp axis (it was pushed or fell), it first returns to the point in front of its foot.
func _siege_climb_target(here: Vector2, post_offset: float) -> Vector2:
	var ramps: Array[PackedVector2Array] = _siege_routes.walkway_ramps
	if _siege_climb_ramp < 0 or _siege_climb_ramp >= ramps.size():
		_siege_climb_ramp = 0
		var best_gap: float = INF
		for index: int in ramps.size():
			if ramps[index].is_empty():
				continue
			var top: Vector2 = ramps[index][ramps[index].size() - 1]
			var gap: float = absf(_siege_routes.walkway_offset(top) - post_offset)
			if gap < best_gap - 0.001:
				best_gap = gap
				_siege_climb_ramp = index
		_siege_climb_index = -1
	var points: PackedVector2Array = ramps[_siege_climb_ramp]
	var last: int = points.size() - 1
	if _siege_climb_index < 0:
		_siege_climb_index = 0
		var best: float = INF
		for index: int in maxi(last, 1):
			var distance: float = here.distance_to(points[index])
			if distance < best:
				best = distance
				_siege_climb_index = index
	if last > 0 and _siege_climb_index >= last and not _siege_on_ramp_axis(here, points[last - 1], points[last]):
		_siege_climb_index = last - 1
	if _siege_climb_index < last and here.distance_to(points[_siege_climb_index]) <= SIEGE_WALKWAY_REACHED:
		_siege_climb_index += 1
	return points[mini(_siege_climb_index, last)]


# The direction (horizontal and unit) of the walkway axis at [param position] toward [param target]: toward where its
# distance along the axis grows if the target is beyond, or backward if it is this side; with the two level (within
# 0.25 m along the axis), toward the side it faces with [param yaw]. Zero if there is no axis.
func _siege_walkway_heading(position: Vector3, target: Vector3, yaw: float) -> Vector3:
	var mine: float = _siege_routes.walkway_offset(Vector2(position.x, position.z))
	var theirs: float = _siege_routes.walkway_offset(Vector2(target.x, target.z))
	var length: float = _siege_routes.walkway_length()
	var from: Vector2 = _siege_routes.walkway_point(clampf(mine - 0.25, 0.0, length))
	var to: Vector2 = _siege_routes.walkway_point(clampf(mine + 0.25, 0.0, length))
	var tangent := Vector3(to.x - from.x, 0.0, to.y - from.y)
	if tangent.length_squared() < 0.0001:
		return Vector3.ZERO
	tangent = tangent.normalized()
	var side: float = signf(theirs - mine) if absf(theirs - mine) >= 0.25 \
			else signf(Vector3(-sin(yaw), 0.0, -cos(yaw)).dot(tangent))
	return tangent * (side if side != 0.0 else 1.0)


# true if [param here] is on the axis of the ramp running from [param foot] to [param top] (with SIEGE_RAMP_AXIS_TOLERANCE
# sideways and a bit of slack at its ends).
func _siege_on_ramp_axis(here: Vector2, foot: Vector2, top: Vector2) -> bool:
	var along: Vector2 = top - foot
	var length: float = along.length()
	if length < 0.001:
		return here.distance_to(top) <= SIEGE_RAMP_AXIS_TOLERANCE
	var direction: Vector2 = along / length
	var offset: Vector2 = here - foot
	var t: float = offset.dot(direction)
	return t >= -SIEGE_RAMP_AXIS_TOLERANCE and t <= length + SIEGE_RAMP_AXIS_TOLERANCE \
			and absf(offset.cross(direction)) <= SIEGE_RAMP_AXIS_TOLERANCE


# Where to go along the walkway from [param here] to reach the axis point that is [param target_offset]
# meters away: the first corner in between or, if there is none, that point.
func _siege_walkway_next(here: Vector2, target_offset: float) -> Vector2:
	var corner: Variant = _siege_walkway_corner(here, target_offset)
	return corner as Vector2 if corner is Vector2 else _siege_routes.walkway_point(target_offset)


# The first corner (a point of the walkway axis) between [param here] and the axis point at [param target_offset]
# meters, or null if there is none (those within SIEGE_WALKWAY_REACHED are counted as passed).
func _siege_walkway_corner(here: Vector2, target_offset: float) -> Variant:
	var mine: float = _siege_routes.walkway_offset(here)
	var offsets: PackedFloat32Array = _siege_routes.walkway_vertex_offsets()
	var path: PackedVector2Array = _siege_routes.walkway_path
	if target_offset > mine:
		for index: int in offsets.size():
			if offsets[index] > mine + SIEGE_WALKWAY_REACHED and offsets[index] < target_offset:
				return path[index]
	else:
		for index: int in range(offsets.size() - 1, -1, -1):
			if offsets[index] < mine - SIEGE_WALKWAY_REACHED and offsets[index] > target_offset:
				return path[index]
	return null


# --- Stroll -------------------------------------------------------------------------------------

# Chooses the heading, the walk and the sprint of the next stroll segment.
func _start_segment(tick: int) -> void:
	_next_change_tick = tick + _rng.randi_range(SEGMENT_MIN_TICKS, SEGMENT_MAX_TICKS)
	_heading = _rng.randf() * TAU
	_sprint = false
	if _rng.randf() < PAUSE_CHANCE:
		_move = Vector2.ZERO
		return
	_move = Vector2(0.0, 1.0)
	if _rng.randf() < STRAFE_CHANCE:
		_move = Vector2(_rng.randf_range(-0.7, 0.7), 1.0).limit_length(1.0)
	else:
		_sprint = _rng.randf() < SPRINT_CHANCE


# Presses the jump button when due and schedules the next jump.
func _update_jump(tick: int) -> void:
	if tick < _next_jump_tick:
		return
	_jump_release_tick = tick + _rng.randi_range(JUMP_HOLD_TICKS.x, JUMP_HOLD_TICKS.y)
	_schedule_jump(_jump_release_tick)


func _schedule_jump(from_tick: int) -> void:
	var gap: Vector2i = JUMPY_JUMP_GAP_TICKS if _pattern == Pattern.JUMPY else WANDER_JUMP_GAP_TICKS
	_next_jump_tick = from_tick + _rng.randi_range(gap.x, gap.y)


# Yaw that faces toward [param direction] (horizontal plane), with the PlayerInput convention: yaw
# 0 faces -Z. With a null direction it keeps [param fallback].
func _yaw_toward(direction: Vector3, fallback: float) -> float:
	if direction.x * direction.x + direction.z * direction.z < 0.0001:
		return fallback
	return fposmod(atan2(-direction.x, -direction.z), TAU)


# Heading of a circle around home: the tangent plus a radial correction that
# returns the bot to its circle if it drifts.
func _circle_yaw(position: Vector3, fallback: float) -> float:
	var circle_radius: float = maxf(_radius * CIRCLE_RADIUS_FRACTION, CIRCLE_MIN_RADIUS)
	var offset: Vector3 = position - _home
	offset.y = 0.0
	var distance: float = offset.length()
	if distance < 0.01:
		return fallback
	var radial: Vector3 = offset / distance
	var tangent := Vector3(-radial.z, 0.0, radial.x) * _circle_sign
	var correction: float = clampf((circle_radius - distance) / circle_radius * 2.0, -1.0, 1.0)
	return _yaw_toward(tangent + radial * correction, fallback)
