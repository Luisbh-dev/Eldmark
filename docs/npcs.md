# Eldmark · Phases 6-8: NPCs, bestiary, interaction and dialogue

Design of the creatures and people of the world: how a hostile NPC is defined, scaled and credited (MUN-49 to
MUN-54, MUN-24, MUN-25), the bestiary and its five tiers, camps, bosses, the interaction and dialogue systems (MUN-16,
MUN-18), service and ambient NPCs (MUN-19, MUN-55, MUN-56), and the cost of all that on the server (MUN-51, TEC-68).

It builds on what exists: the AI of [fortress.md](fortress.md#4-npcs-mun-06--mun-12-gue-11) (navigation, `HfsmBrain`, attack
tokens, spawners), the damage formula and the reference DPS of [combat.md](combat.md), the rewards of
[progression.md](progression.md), the zones of [world.md](world.md), the localization rules of
[localization.md](localization.md) and the wire costs of [networking.md](networking.md). The level curve, the power
scale O(L) and D(L) and the reference character are owned by [advancement.md](advancement.md); weapons, abilities and damage types by
[weapons.md](weapons.md); loot by [items.md](items.md); quests by [quests.md](quests.md). Links to those documents are plain text until they land.

Everything here is **provisional**: the figures are the starting values, adjusted when measured with
`tools/ai/bestiary_balance.gd` and the load test (TEC-68).

## 0. Decisions

| # | Decision | Why |
|---|---|---|
| D1 | **One definition per variant, not per level.** `NpcDefinition` describes a variant (e.g. `bandit_archer`) valid in a level range; the **level comes from the camp** and the figures from one shared table (`NpcScalingRules`) | 60 levels × 3 realms would be thousands of files. With a template plus a level, about 120 definitions cover the whole game and balancing happens in a table |
| D2 | **Scaling reads O(L) and D(L) from [advancement.md](advancement.md)** (the offense and the effective health of a player "at their level" against the reference character). NPC health is proportional to O(L), NPC damage to D(L). In normalized zones the reference (1.0) applies. There is no provisional `vida_ref` table | The time to kill and the danger of an NPC stay the same from level 1 to 60, whatever the curve of the player: a normal dies in 8-12 s and kills an undefended player in 25-35 s |
| D3 | **Realm variant = visual only.** `bandit_swordsman` is the same sheet in the three realms; `visual_by_realm` picks the clan outlaw (Vardheim), crusade deserter (Solmarch) or caravan raider (Askarra) | Triples the visible variety without tripling the balancing |
| D4 | **Eight ranks** (minion, normal, strong, elite, named, boss, dungeon boss, world boss) with health ×0.4/1/2/6/10/25/45/120 and XP ×0.25/1/2/6/12/25/40/60; mastery of 10 per normal in the same proportion | One table, shared with progression. The health multipliers follow the time to kill |
| D5 | **Level difference:** the XP follows the progression table (×0.40 to ×1.20) and **gray (-8 or lower) gives 0 XP and 0 mastery**; in PvE combat ±4 % per level beyond ±2, capped at ±40 %; grays do not attack first | Zero is clearer than a token amount and removes farming. The moderate modifier gives the feeling of a band without nullifying skill |
| D6 | **Credit by contribution** (damage, healing to someone who has credit, and damage blocked while being the target), with a threshold of 10 / 5 / 3 / 1 % by rank, shared with the group at 100 m | There is no target tag without target selection, and 10 % does not work with 30 players against a boss or with healers and shields |
| D7 | **Bestiary in five tiers T1-T5**, aligned with the zone bands of [world.md](world.md#32-zones-and-levels-by-realm): T1 1-10, T2 10-20, T3 20-32, T4 32-45, T5 45-60. NPC levels come from `ZoneDefinition` and the camps, so moving a band regenerates no map | Replaces the six bands of 10 of the first proposal |
| D8 | **Humanoid families first.** Bandits, Hollow, cultists, giants and golems use the human skeleton. Quadrupeds (wolves, boars, bears) have **their own Blender rigs** (small and large, CC BY 4.0) with placeholder bodies in the meantime (pending decision P4). Spiders, scorpions and fliers are out of the launch | The Quaternius Bestiary is under the QAL license and cannot be used in a public repository; there are no free animals in the family |
| D9 | **Three cost levels:** full humanoid combat body, light creature (a `PlayerCharacter` subclass without `move_and_slide`) and ambient (no body, cannot be damaged). Plus **activity levels** (combat, near, asleep) and "rest without simulating" | An NPC costs 50-85 µs per tick; a PvE zone with 150-300 does not fit if everything thinks all the time (MUN-51) |
| D10 | **The client names the interaction target** (`INTERACT_REQUEST` with the id) and the server validates; the `INTERACT` input bit stays for reviving and finishing the downed. **Dialogue travels as indices** (`DIALOGUE_SHOW`, about 12 B) | A server-picked target would be 100-200 ms behind what the player sees and could open the wrong window. Dialogue honors localization: the server never formats text |
| D11 | **No loot bags and no skinning.** Loot goes personal and direct to the bag (or the satchel when it is full), hides come from the loot table, and in RvR zones NPCs drop no equipment | Decided in the items design; removes two interaction types and two systems |
| D12 | **Bosses and phases are data** (`BossScript`): a phase is an NPC weapon plus entry actions. The Ford Captain migrates with the same state log | The boss is wired into `HfsmBrain` today; MUN-30 and the dungeons need the same framework |
| D13 | **Service NPCs are always available; routines only for civilians.** One **Master of the Orders** per capital and **one mentor per specialization** | A merchant that goes to sleep in the middle of a 40 min session only bothers; the day lasts 2 h (MUN-27). The Master changes the specialization, the mentors give the trial and the flavor |
| D14 | **The stable master is the caravan master** (fast travel) until there are mounts | The role has a function from day one |
| D15 | **The server runs at 60 Hz;** data goes in seconds and converts with `roundi` on load | A zone that drops to 30 Hz keeps its data and gains twice the per-tick margin. Budgets are given in ms per tick at 60 Hz |

## 1. Scaling by level

### 1.1 The reference character and the power scale

[advancement.md](advancement.md) defines the **reference character**: level 60, attributes 75/25 and 33 constitution, equipment of item
level 52 in every slot. Its figures are today's combat figures: health 1000, damage factor 1.0, sword 90/90/130, a time
to kill of 10.7 s. For a player "at their level" (60/20/20 point split, common equipment of their level, medium armor)
the sheet gives an offense **O(L)** and an effective health **D(L)**, both relative to the reference:

| Level | O(L) offense | D(L) effective health | Health | Medium armor | Health of a normal NPC |
|---|---|---|---|---|---|
| 1 | 0.30 | 0.51 | 615 | 155 | 302 |
| 5 | 0.35 | 0.54 | 640 | 174 | 345 |
| 10 | 0.40 | 0.58 | 672 | 197 | 402 |
| 20 | 0.52 | 0.66 | 735 | 244 | 522 |
| 30 | 0.65 | 0.74 | 798 | 290 | 653 |
| 45 | 0.87 | 0.87 | 892 | 360 | 867 |
| 60 | 1.10 | 1.01 | 987 | 430 | 1 103 |

The table is [advancement.md](advancement.md)'s (the curve is a table, not a formula); NPC code only reads it.

### 1.2 Formulas (shared, `scripts/shared/ai/npc_stats.gd`)

```
max_health(npc, L)  = roundi(1000 · O(L) · rank.health · variant.health_factor)
output_scale(npc,L) = D(L) · rank.damage · variant.damage_factor
diff_mod(d)         = 0                                   if |d| <= 2
                    = sign(d) · min(0.04 · (|d| - 2), 0.40)   otherwise      (d = npc_level - player_level)
NPC → player hit:   damage_scale *= output_scale · (1 + diff_mod(d))
player → NPC hit:   damage_scale *= (1 - diff_mod(d)) · (1 + family_resistance[type])      (resistance in -0.3..+0.3)
```

- The `base_damage` of NPC weapons (`data/combat/npc_*.tres`) is written **calibrated to the reference character**
  (health 1000): today's `npc_hollow_swipe` of 70 is 7 % of the reference health. With D(L) a blow is always the same
  percentage of the health of a player at their level, and the player's own armor is handled on the player side
  (mitigation relative to the reference), not here.
- The TTK of a normal comes out the same at any level because its health is 1000 · O(L) and the player's damage is
  O(L) times the reference DPS: 10.8 s with the DPS of the bots (93), 8.3 s with a real player (about 120) and 6.4 s with
  the ideal combo (156).
- `scales_with_level = false` leaves an NPC with its literal figures: the five NPCs of Vado Gris carry it and do not
  change. In **normalized zones** (Vado Gris from level 10, Eldrun from level 20) the NPCs use the reference (O = D = 1)
  through `ZoneDefinition.content_level`, and there is no `diff_mod` in RvR.
- Resistances by family use the damage types of [weapons.md](weapons.md) (slashing, piercing, blunt, fire, frost, light). Starting
  values give a reason to swap weapon with Q: the Hollow resist piercing (-25 %) and suffer blunt (+20 %); beasts suffer
  fire (+20 %); golems resist slashing (-25 %). Frost and light start at 0 until the weapon bands are measured.

### 1.3 Ranks

| Rank | Health (× 1000 · O) | Damage (×) | Target TTK | XP (× the base of the level) | Gold (×) | Loot rolls | Credit threshold | Control |
|---|---|---|---|---|---|---|---|---|
| Minion | 0.4 | 0.6 | 4 s alone | 0.25 | 0.25 | 25 % of one | 10 % | normal |
| Normal | 1.0 | 1.0 | 8-12 s alone | 1 | 1 | 1 | 10 % | normal |
| Strong | 2.0 | 1.2 | 18-24 s alone | 2 | 2 | 1 + 25 % | 10 % | push ×0.5 |
| Elite | 6.0 | 1.5 | 25-35 s with 2-3 | 6 | 3 | 40 % of one `elite` roll | 5 % | no push, stun ×0.5 |
| Named (rare) | 10 | 1.6 | 35-50 s with 2-3 | 12 | 10 | 1 `elite` roll + 25 % of another | 5 % | like elite |
| Boss (camp, fort) | 25 | 1.8 | 90-150 s with 3-5 | 25 | 25 | boss table | 3 % | immune except punish windows |
| Dungeon boss | 45 (× 0.70 / 0.85 / 1.00 with 3 / 4 / 5) | 2.0 | 2-4 min with 3-5 | 40 | 40 | boss table | 3 % | like boss |
| World / event boss | 120 × clamp(participants / 10, 1, 4) | 2.2 | 5-8 min with 15-30 | 60 | 60 | event table | 1 % and within 100 m | like boss |

- **Gold and loot of the Elite, Named and Boss ranks are owned by [items.md](items.md) §8.2 (PRG-21)**; the columns above copy its table and
  the loot tables win if they ever differ. The Minion, Strong and dungeon or event boss rows are this document's.
- The XP of a normal is `0.006 · r(L)` of the leveling pace (36 at level 1, 68 at 10, 140 at 30, 248 at 60), then times
  the rank and the level-difference factor of [advancement.md](advancement.md). Mastery is 10 per normal and follows the same rank
  proportion; it comes only from credit events (kills), never from hitting.
- The existing figures fall inside the envelopes: a Hollow of 2500 is a strong (×2.5), the realm guard of 2500 is
  strong, the Ford Captain of 30 000 is a boss (×30) at the reference.

**Hit envelopes** (as a percentage of the health of a player at their level, already scaled): a normal's light hit 5-7 %,
heavy 12-16 %; elite light 8 %, heavy 18-22 %; boss unblockable 30-45 % (always with a mark of at least 1.0 s). A normal's
DPS against someone who does not defend is 3-5 % of their health per second, which is what makes it kill in 25-35 s.
The validator rejects what falls outside the envelopes by more than ±30 %.

**Preparation windows:** those of MUN-08 (at least 0.45 s light, 0.70 s heavy) plus at least 1.0 s for marked unblockables,
1.2 s for aimed shots (line mark) and 1.2 s for caster areas. Difficulty rises with the tier through composition, abilities
and effects, **never by shortening windows** (they have to absorb RTT and interpolation).

### 1.4 Level difference in the interface

| `d` | Color | Effect |
|---|---|---|
| -8 or lower | gray | no XP, no mastery, **does not attack first** |
| -7 … -3 | green | negative `diff_mod` |
| -2 … +2 | white | none |
| +3 … +4 | orange | +4 % / +8 % |
| +5 … +7 | red | +12 % to +20 % |
| +8 or more | red with skull | +24 % to +40 % |

A gray still gives quest credit.

## 2. AI archetypes (on `HfsmBrain`)

The state machine (IDLE → PATROL → ALERT → COMBAT → RETURN), the seeded RNG, the state log, the leash with an immune return
and the attack tokens stay ([fortress.md 4.2](fortress.md#42-ai-mun-07-mun-08)). What is new:

- **Pluggable tactic in COMBAT** (`NpcTactic`, a sub-resource of the definition; code in `scripts/server/ai/tactics/`):
  decides position and movement. One per archetype.
- **Attack choice by score** within COMBAT: `NpcAbilityEntry` = an ability or attack, weight, distance range, "health
  below", minimum nearby enemies and its own cooldown. Abilities are `AbilityDefinition`s in the three slots of the NPC
  weapon, and the `ActionMachine` handles casting, channeling and cooldown as for a player.
- **Threat** (`ThreatTable`, replaces the sum of `damage_by` plus proximity): damage × the multiplier of the source;
  healing (0.5 × what is healed, spread over the NPCs fighting the healed one); taunt (fixes the target for 3 s and raises
  the threat to 110 % of the maximum); decay of 2 % per second without contact. Public API for the Vanguard specialization
  and the life staff.
- **Anti-exploit evasion:** if the target has no route (up on a rock) for 4 s, the NPC returns regenerated and immune
  (today it only gives up when stuck).
- **Activity LOD** (MUN-51, section 8): the brain thinks at 10, 2 Hz or not at all.

| Archetype | Perception (m, cone) / hearing | Loss / leash (m) | Group alert | Combat distance | Behavior |
|---|---|---|---|---|---|
| Brute | 16, 140° / 4 | 28 / 32 | 15 m | melee | the current one; block 10-35 % by variant |
| Charger | 14, 160° / 5 | 26 / 30 | 12 m | 6-12 m to charge | charge along a marked line (0.8 s, 10 m), stops on impact; stunned 1 s if it fails against a wall (punish window) |
| Archer | 24, 140° / 5 | 34 / 36 | 18 m | 12-22 m | if the target is under 6 m, jumps back 4 m (cd 6 s) or uses a dagger; no sight for 1.5 s → tests 8 points on a 6 m circle with one ray each and goes to the first with sight; shoots with `BotBrain.lead_look` and ±0.6 m of error at 20 m (lateral movement dodges) |
| Caster | 22, 140° / 5 | 32 / 34 | 18 m | 10-18 m | ground areas with a mark (1.2-2.0 s), slow projectile; stun cuts the cast |
| Healer | 20, 140° / 5 | 30 / 32 | 20 m | 10-16 m behind its allies | heals the ally below 50 % (cd 12 s, 1.5 s cast, interruptible); prefers players as targets |
| Pack | 18, 220° / 6 | 30 / 34 | 30 m (howl) | flank at 3.5-5 m | 2 tokens (those of MUN-08); the rest take an angle slot around the target (0°, ±120°, 180°) and feint (step in 1.5 m and out); when the alpha dies, 30 % flee |
| Passive (fauna) | 12, 300° / 8 | 20 / 25 | none | none | flees 12 m at 1.4× when attacked or when someone is under 6 m |
| Support | 16, 140° / 4 | 28 / 30 | 20 m | melee | aura at 10 m while alive (the standard); priority target |
| Elite | +25 % | +20 % | 20 m | by base | 2-3 abilities, no push, stun ×0.5 |
| Boss | arena 25-40 m | arena | the whole camp | by phase | `BossScript` (2.2) |

**Flee and call for help:** bandits and beasts at 15 % health, with a 50 % chance (seeded), run 10-14 m toward the nearest
allied group, raise the alert at double radius and return after 4-6 s. Hollow, golems and bosses never flee.

**NPC against NPC:** `targets_npcs = true` only on village and garrison guards; they attack monsters inside their leash
(the village) and do not chase them outside. Monsters only respond. All monsters use the neutral side 0 of `FactionRules`,
which is already hostile to the three realms and does not damage itself.

### 2.1 Difficulty by tier

| Tier | Levels | Abilities per normal | Unblockables from | Effects that appear | Typical group |
|---|---|---|---|---|---|
| T1 | 1-10 | 0-1 | bosses | light bleed, slow | 3-4 equal + 1 different |
| T2 | 10-20 | 1 | elites | + short stun (0.6 s) | brute + archer |
| T3 | 20-32 | 1-2 | elites | + root, burn | + caster or healer |
| T4 | 32-45 | 2 | strongs | + `VULNERABLE` | 5-6 with support |
| T5 | 45-60 | 2-3 | normals (1 per variant) | all | elites on patrol + environment mechanics |

### 2.2 Boss framework (`BossScript`)

```
BossScript (sub-resource or .tres in data/npcs/bosses/)
  arena_radius: float           # from its post; outside it, it does not chase
  reset_when_empty_s: float = 6 # no living players in the arena: back to 100 % and withdraws adds
  enrage_s: float = 240         # +50 % damage (enrage_damage), announced with a shout
  phases: Array[BossPhase]
BossPhase
  health_below: float           # 1.0 the first
  weapon_id: StringName         # the NPC weapon of the phase: light, heavy and its 3 abilities
  special_every: int            # the Captain's "unblockable every N", now per phase
  abilities: Array[NpcAbilityEntry]
  on_enter: Array[BossAction]   # SHOUT, SPAWN_ADDS(def, n, only_if_group_alive), IMMUNE(s), MOVE_TO(marker)
  adds_cap: int                 # alive at once (today: 2 per fortress)
  punish_window_s: float        # after failing a special: takes +25 % and can be stunned
```

Migration of the **Ford Captain**: phase 1 (`npc_captain`, `special_every = 3`, shout on entering combat), phase 2 at 50 %
with `SPAWN_ADDS(hollow, 2, only_if_group_alive)`. Criterion: with the same seed, `test_npc_system` and `test_hfsm_brain`
give the same state log. Jobs for the framework: the Vado Gris Captain, the bandit chief and Hjalmar (zone 1-10), the
castle lords (MUN-30) and the dungeon bosses (MUN-35, D1-D6).

The TELEGRAPH message gains a **LINE** shape (a new width field, u16 in cm: the message goes from 26 to 28 B) for charges
and aimed shots; circle and sector already exist (`TelegraphMarks`).

## 3. Bestiary

### 3.1 Families and bodies

| Family | Body | Archetypes | Tiers | Realms (visual) | Art |
|---|---|---|---|---|---|
| Wolves | small creature | pack, alpha | T1-T3 (embered T4+) | frost wolf / gray wolf / ash jackal | own small quadruped (ART-78) |
| Boars and goats | small creature | charger | T1-T2 | boar / boar / canyon goat | the same small skeleton |
| Passive fauna | small or large creature | passive | all | deer, elk, goat | small or large skeleton |
| Bears and bulls | large creature | brute, elite | T2-T4 | frost bear / brown bear / ash bull | own large quadruped |
| Bandits | humanoid | brute, archer, healer, elite, boss | T1-T4 | clan outlaws / crusade deserters / caravan raiders | Peasant and Ranger outfits (ART-19/20) |
| The Hollow | humanoid (bone) | all | T1-T5 and Eldrun | local variants: the drowned (Skarven), mound sleepers (Grimfell), hollow monks (Lirien), marsh dead (Morvel), hollow miners (Ruhn) | the ART-52 profile with materials |
| Ember cultists (the Forsworn at T1) | humanoid | caster, fanatic brute, summoner, elite | T1 (the Forsworn), T4-T5 | Rune burners / Penitents of the Flame / Flamewrights | outfits plus emissive |
| Embered | those of wolves and bears | those of their base | T3-T5 | same | same model plus a glowing-cracks shader |
| Wandering embers | floating (no skeleton) | caster, exploding minion | T3-T5 | same | simple mesh plus particles (Kenney Particle Pack) |
| Giants and golems | humanoid scaled ×1.6-2.2 | elite, boss | T2-T5 | frost giant / living statue / slag golem | human body with rock or ice pieces in Blender, UAL clips |
| Raiders | humanoid | brute, archer, healer | T5 (borders only) | soldiers of the other two realms | the realm guards that already exist |

Launch split: about 70 % humanoid, 12 % small quadruped, 8 % large, 5 % floating, 5 % giant. Planned total: **about 95
variants and about 25 bosses and rares, around 120 definitions** for 1-60.

Lore: the Embered and the wandering embers are fauna and flame touched by the Embers of Eld ([world.md](world.md#1-history)),
and the cultists want to rekindle the Flame for themselves. That justifies reusing models with a shader in the high tiers.

### 3.2 Tiers against zones

| Tier | Zones (Vardheim / Solmarch / Askarra) | Grade of material |
|---|---|---|
| T1 1-10 | Hondal / Amber Fields / Thal Oasis | G1 |
| T2 10-20 | Skarven / Lirien Forest / Ruhn Canyons | G1-G2 |
| T3 20-32 | Grimfell / Morvel Marsh / Ash Waste | G3-G4 |
| T4 32-45 | Hrimvald Glacier / Vaucelle Heights / Qesh Salt Flats | G4-G5 |
| T5 45-60 | Wolf March / Penitent Plains / Ossar Forges | G5-G6 |

The first proposal had six bands of ten; they are re-bucketed into these five. The NPC level of each camp comes from the
zone and the point of interest, so adjusting the hours per band moves levels and regenerates no map.

### 3.3 Tier T1: the 18 sheets

Health in multiples of `1000 · O(L)` (the rank included); hits in % of the health of a player at their level; times in
seconds. "Respawn" is base / minimum.

| id | Family · rank · archetype | Health | Light / heavy (preparation) | Abilities | Perception / leash | Aggression · group | XP / gold (×) | Respawn |
|---|---|---|---|---|---|---|---|---|
| `wolf` | wolves · normal · pack | 0.8 | bite 6 (0.45) / leap 6 m 12 (0.70) | none | 18 / 34 | aggressive · 3-4 | 1 / 0.5 | 90 / 30 |
| `wolf_alpha` | wolves · strong · pack (alpha) | 2.2 | 7 / 14 | Howl (+15 % damage to the pack 10 s, cd 25 s), Rend (bleed 2 %/s 6 s) | 20 / 36 | aggressive · 1 + 3 | 2 / 1 | 180 / 60 |
| `boar` | boars · normal · charger | 1.2 | gore 7 (0.5) | Charge (line 10 m, 0.8 s, 14 % + push 3 m, cd 8 s) | 14 / 30 | defensive (< 6 m) · 1-2 | 1 / 0.5 | 90 / 30 |
| `deer` | fauna · minion · passive | 0.5 | none | flees | 12 / 25 | passive · 2-4 | 0.25 / 0 | 60 / 30 |
| `bandit_swordsman` | bandits · normal · brute | 1.0 | 6 (0.5) / 14 (0.75) | none | 16 / 32 | aggressive · 2-4 | 1 / 1 | 120 / 40 |
| `bandit_archer` | bandits · normal · archer | 0.8 | quick 5 (0.9) / aimed 12 (1.6, line) | Retreat | 24 / 36 | aggressive · 1-2 | 1 / 1 | 120 / 40 |
| `bandit_brute` | bandits · strong · brute with shield | 2.0 | 7 / 16 | Shield bash (stun 0.6 s, cd 10 s); blocks 35 % | 16 / 32 | aggressive · 1 | 2 / 2 | 180 / 60 |
| `bandit_healer` | bandits · normal · healer | 0.8 | 4 (0.6) | Heal (15 % to ally < 50 %, 1.5 s, cd 12 s), Blinding powder (cone 4 m, slow 30 % 3 s, cd 15 s) | 20 / 34 | aggressive · 1 | 1.5 / 1.5 | 150 / 50 |
| `bandit_lieutenant` | bandits · elite · brute | 6 | 8 / 18 | Rallying cry (+20 % damage to allies 8 s), Whirlwind (circle 3 m, 1.0 s, 16 %) | 18 / 34 | aggressive · 1 + 3 | 6 / 5 | 300 / 120 |
| `bandit_chief` (a proper name per realm) | bandits · boss | 25 | 9 / 20; unblockable 35 (1.2, mark) | P1 sweep + unblockable every 3; P2 at 50 %: 2 `bandit_brute` and fire arrows from 2 archers on the palisade (3 m circles); enrages at 4 min | arena 30 | aggressive · camp | 25 / 25 | 600 / 300 |
| `hollow_wanderer` | Hollow · normal · brute | 1.0 | 7 / 16 | none | 16 / 30 | aggressive · 2-3 | 1 / 0.5 | 120 / 40 |
| `hollow_soldier` | Hollow · strong · brute | 2.5 | 7 / 16 (the current Hollow's) | blocks 12 % | 16 / 32 | aggressive · 2-4 | 2 / 1 | 180 / 60 |
| `hollow_archer` | Hollow · normal · archer | 0.8 | 5 / 12 | none | 24 / 36 | aggressive · 1-2 | 1 / 0.5 | 120 / 40 |
| `hollow_ashcaller` | Hollow · normal · caster | 0.8 | Cold flame (projectile, 8) / Ash circle (3.5 m, 1.4 s, 14 % + slow 30 % 3 s) | none | 22 / 34 | aggressive · 1 | 1.5 / 1 | 150 / 50 |
| `hollow_standard` | Hollow · strong · support | 2.0 | 6 / 14 | Standard aura (allies within 10 m take -15 % damage) | 16 / 30 | aggressive · 1 | 2 / 1 | 180 / 60 |
| `hollow_ruin_captain` | Hollow · boss | 20 | the Captain's × 0.8 | P1 sweep + unblockable; P2 at 50 %: 2 `hollow_soldier` | arena 28 | aggressive · ruins | 20 / 20 | 600 / 300 |
| `old_fang` | wolves · named · pack | 10 | 8 / 16 | Howl, Rend, double leap | 22 / 36 | aggressive · 1 + 2 | 12 / 10 | rare (4.3) |
| `fencebreaker` | boars · named · charger | 10 | 9 / charge 20 | Double chained charge, Stomp (circle 3 m, 1.0 s) | 16 / 32 | defensive · 1 | 12 / 10 | rare |

New NPC weapons and abilities for T1 (in `data/combat/`, prefix `npc_`): `npc_wolf` (bite, leap), `npc_boar` (gore, charge),
`npc_bandit_sword`, `npc_bandit_shield`, `npc_bandit_bow`, `npc_bandit_staff` (healer), `npc_hollow_bow`, `npc_hollow_ash`,
plus the abilities cited: 8 weapons and about 14 attacks and abilities. The `sim_hash` of the catalog changes
([combat.md](combat.md) §7) and tests look things up by id.

### 3.4 Hondal additions derived from the T1 sheets

The zone [Hondal](zones/hondal.md) also needs the Forsworn cultists, three uniques and one boss. They are **variants and
ranks over the 18 sheets**, not new families, and their figures are provisional:

| id | Based on | Rank · archetype | Health | Light / heavy | Abilities | Level in Hondal |
|---|---|---|---|---|---|---|
| `forsworn_zealot` | `bandit_brute` | strong · fanatic brute | 2.0 | 8 / 16 | Brand strike (burn 2 %/s 4 s, cd 10 s) | 8-9 |
| `forsworn_emberbinder` | `hollow_ashcaller` | normal · caster | 0.8 | Ember bolt 8 / Binding circle (3.5 m, 1.4 s, 14 % + slow) | none | 8-9 |
| `forsworn_warden` | `hollow_standard` | strong · support | 2.0 | 6 / 14 | Flame ward (10 % health shield to an ally within 10 m, cd 15 s) | 9 |
| `eldhald_guardian` | `hollow_soldier` | elite · brute | 6.0 | 8 / 18 | Shield wall (blocks 40 % for 4 s, cd 20 s), Slam (circle 3.5 m, 1.2 s, 18 %) | 7 |
| `gunnar_halfhand` | `bandit_lieutenant` | named · brute (fixed post) | 10 | 8 / 18 | Rallying cry, Whirlwind | 6 |
| `hjalmar_forsworn` | `bandit_chief` shape | boss · two phases (`BossScript`) | 25 | 9 / 20; unblockable 35 | P1 sweep + unblockable every 3; P2 at 50 %: 2 `forsworn_zealot` while a warden lives | 9 |

Gunnar is a fixed post of the Deserter Camp, not a rare roll; Greyfang and Fencebreaker are the two true rares of Hondal.

### 3.5 Tiers T2-T5

| Tier | New common families | Vardheim | Solmarch | Askarra | New variants | Bosses and rares |
|---|---|---|---|---|---|---|
| T2 10-20 | bears, minor golems, bandit veterans (2 abilities) | the drowned, fjord raiders (Skarven) | hollow monks of the abbey, brown bear (Lirien) | hollow miners, ash bull, minor slag golem (Ruhn) | ~16 | 2 camp bosses and 3 rares per zone, plus the D1 bosses |
| T3 20-32 | embered, wandering embers | mound sleepers, frost giant (elite) (Grimfell) | marsh dead, corrupted penitents (Morvel) | embers, slag golem (Ash Waste) | ~16 | a giant as the zone boss, D2 |
| T4 32-45 | full cultists, elites on patrol, bigger embered | Rune burners (Hrimvald) | Penitents of the Flame, living statues (Vaucelle) | Flamewrights, salt-glass golems (Qesh) | ~16 | a zone boss and a world boss per zone, D3 and D4 |
| T5 45-60 | raiders of the other realms, Ember lords, hollow knights of the old guard of Eld, ancient giants | embered wolves (Wolf March) | (Penitent Plains) | (Ossar Forges) | ~24 | world bosses per realm, D5 and D6 |

Which zone holds a tier is in [world.md](world.md#32-zones-and-levels-by-realm); the bestiary only requires that every zone
declares its level range. Names of the T2-T5 variants are placeholders until each tier's production increment.

## 4. Camps, content level, respawn and credit (MUN-25)

### 4.1 Camp

A prefabricated scene `scenes/world/camps/<type>.tscn` with an `NpcCamp` root (`scripts/world/npc_camp.gd`, data only, like
`NpcSpawner`) and `NpcSpawner` children. The zone generator ([world.md](world.md#9-the-zone-kit)) places
them.

```
NpcCamp (Node3D)
  camp_id: StringName              # unique in the zone (validator)
  display_name: String             # English, context "place" ("Outlaw Camp")
  level: int                       # 1..60, inside ZoneDefinition.level_min..max
  radius_m: float = 25             # camp alert and count of present players
  respawn_presence_factor: float = 0.35
  rare_npc_id: StringName          # empty = no rare
  rare_chance: float = 0.15        # per full clear
  rare_cooldown_s: Vector2 = (1200, 2400)
  chest: NodePath                  # chest (MUN-16): one per player and cycle
NpcSpawner (exists; exports added)
  level: int = 0                   # 0 = the camp's + the definition's level_offset
  npc_tag: StringName = &""        # stable identity (quests, service)
  name_override: String = ""       # proper name (named bosses, service)
```

A camp holds at most 14 alive, 2 elites and 1 boss. T1 types: bandit camp (10-14 with a chief), wolf lair (8-10 with an
alpha), Eld ruins with Hollow (10-14 with a captain), raided farm (6-8) and sealed entrance (4-6 guardians). Camps are
the "point of interest" templates of [world.md](world.md#69-points-of-interest).

### 4.2 Respawn

```
respawn(s) = max(rank_minimum, rank_base / (1 + 0.35 · (p - 1)))      p = living players within radius_m + 35 m, p >= 1
```

| p | 1 | 2 | 4 | 8 |
|---|---|---|---|---|
| Normal (base 120, minimum 40) | 120 s | 89 s | 59 s | 40 s |

- Counted every 2 s per camp (not per NPC). Nothing appears within 6 m of a player: it waits 3 s, up to 3 times, and then
  appears with 1 s of "standing up" invulnerability.
- A sleeping camp: the clocks keep running; what has expired appears on waking.
- **Kill capacity:** Σ camps (alive × 60 / minimum) must be at least 2.5 × the player cap per channel and per minute. A
  zone with 150 hostiles and 40 s minimums gives about 225 kills per minute, against the 120 that a channel of 48 needs. The
  zone validator checks it.

### 4.3 Named rares

On clearing a whole camp (all dead at once), a seeded roll of `rare_chance`; if it hits, the rare appears in place of the
boss or the marked post on the next respawn and does not return for `rare_cooldown_s`. Loot: one `elite` roll and a 25 % chance of another ([items.md](items.md) §8.2). No chat
announcement; the innkeeper of the village gives hints through dialogue.

### 4.4 Credit by contribution

`NpcContribution` (server, per NPC, a window of 900 ticks like `DamageLedger`):

```
points(p) = damage_done(p → NPC)
          + healing(p → q) for each q whose own points >= threshold          (the healer)
          + damage_blocked(p) while p was the NPC's target                     (the tank)
credit    = { p : points(p) >= rank_threshold · max_health }
          ∪ group members of anyone with credit, alive, within 100 m and with an action in the last 60 s (SOC-23)
          − invisible GMs, marked players (gm_forced) and what progression.md section 6.2 already excludes
```

- Everyone with credit gets their XP, gold and a roll of personal loot, delivered directly to the bag (or the satchel if
  full); gold goes straight in. There is no loot bag in the world. In RvR zones NPCs drop no equipment.
- A gray (-8 or lower) gives quest credit, no XP and no mastery.
- When an NPC returns by the leash its contribution is erased (no farming half a fight).
- Events for other domains (in `ZoneEvents`): `npc_killed(def, family, rank, level, tag, camp_id, position, credited)`,
  `camp_cleared(camp_id, credited)`, `rare_spawned(camp_id)`.

## 5. Interaction (MUN-16, UI-27)

### 5.1 Types

| Type | Verb (context `interact_verb`) | Radius | Channel | State | Extra validation | Owner of the effect |
|---|---|---|---|---|---|---|
| Service or quest NPC | Talk | 4 m | 0 | none | out of combat, NPC not in combat | MUN-18/19 |
| Civilian | Talk | 4 m | 0 | none | none | generic line |
| Door | Open, Close | 3 m | 0 | OBJECT_STATE and collision | key or quest | MUN-16 |
| Lever | Use | 3 m | 1 s | OBJECT_STATE | none | MUN-16 |
| Camp chest | Open | 3 m | 1.5 s | per player | once per player and cycle (personal lock) | MUN-16, items |
| Inscription or book | Read | 3 m | 0 | none | none | MUN-16, MUN-46 |
| Quest object | Pick up, Use | 3 m | 1-3 s | per player | quest state | MUN-17 |
| Gathering node | Mine, Chop, Gather | 3 m | 2-4 s | OBJECT_STATE (depleted) | tool | PRG-26 |
| Zone pass / travel post | Travel | 4 m | 0 / 3 s | discovered | out of combat | TEC-30, MUN-33 |
| Downed ally | Revive | (the `INTERACT` bit, exists) | 3 s | exists | none | [abilities.md 4.5](abilities.md#45-knocked-down-reviving-and-executing-downedsystem-scriptsserverdowned_systemgd) |

There is **no loot-bag and no skin interaction**: personal loot goes straight to the bag and the satchel
([items.md](items.md)), and hides are dropped by the loot table.

### 5.2 Shared rule and protocol

- `InteractionRules.pick(chest, aimed_dir, candidates)` in `scripts/shared/world/`: inside the radius, a cone of ±35° toward
  the aimed point, line of sight; score `angle_degrees + 10 · distance_m`; the downed ally always wins. The client uses it
  on interpolated positions for the prompt "E · Talk to Brenna"; the server only validates.
- C→S `INTERACT_REQUEST` (reliable, **0x24**): `u8 type, u32 id` (net id or object key), `u8 verb`. Validation: distance ≤ radius
  + 0.75 m, sight, state, requirements, a rate of 5/s (`RateLimiter`), not reviving anyone.
- S→C `INTERACT_RESULT` (**0x25**): a code (OK, OUT_OF_RANGE, BUSY, IN_COMBAT, REQUIREMENT, DEPLETED, ALREADY_OPENED) and the
  channel ticks. The channel (`InteractionChannel`, like `UnstuckTracker`) is cut by damage, by attacking or by moving more
  than 0.5 m.
- State per object uses the generic OBJECT_STATE of GUE-09; state per player (a chest already opened) goes in a message
  only for them.
- Registry: `InteractableRegistry` (server) with a spatial index; it gathers the `InteractableNode`s of the gameplay layer,
  NPCs with a service and dynamic ones (nodes).

## 6. Dialogue (MUN-18)

### 6.1 Format

`data/dialogues/<id>.tres`, typed resources with a validator (not Dialogic):

```
DialogueDefinition
  id: StringName                       # network key = u32 fingerprint of the id (like HandoffTicket.zone_key_of)
  speaker_tag: StringName              # default NPC (npc_tag)
  entries: Array[StringName]           # entry nodes in order: the first whose conditions pass
  nodes: Array[DialogueNode]
DialogueNode
  node_id: StringName
  speaker_tag: StringName = &""        # empty = the dialogue's
  text: String                         # English msgid, context "dialogue"
  translator_note: String              # becomes "#." in the .pot
  options: Array[DialogueOption]       # at most 6
DialogueOption
  text: String                         # msgid, context "dialogue_option"
  next_node: StringName = &""          # empty = closes
  conditions: Array[DialogueCondition]
  actions: Array[DialogueAction]
DialogueCondition  kind ∈ {QUEST_STATE(quest, state), LEVEL_AT_LEAST(n), SPECIALIZATION(id), HAS_ITEM(def, n),
                           HAS_CURRENCY(currency, n), FLAG(key, yes/no), REALM(r)}; negate: bool
DialogueAction     kind ∈ {ACCEPT_QUEST(q), TURN_IN_QUEST(q, choice), OPEN_VENDOR(v), OPEN_BANK, OPEN_REPAIR,
                           OPEN_SPECIALIZATION, OPEN_TRAVEL(network), SET_FLAG(key), MARK_MAP(place), END}
```

- Placeholders allowed in the text: `{player}`, `{npc}`, `{realm}`. No grammar in code and no gendered address (the character
  is cosmetic; [localization.md](localization.md) rule 4).
- Per-character flags (`SET_FLAG` / `FLAG`) are stored by the quest service (MUN-17) next to the progress.
- Actions are executed by the owner of each service (quests, vendor, bank, specialization, travel); the dialogue only checks
  and calls.

### 6.2 Network and validation

Messages **0x24-0x28** (the interaction and dialogue range of the common registry): 0x24 `INTERACT_REQUEST` (C→S), 0x25
`INTERACT_RESULT`, 0x26 `DIALOGUE_SHOW`, 0x27 `DIALOGUE_CHOOSE` (C→S), 0x28 `DIALOGUE_CLOSE` (both ways).
`DIALOGUE_SHOW`: `u16 session, u32 key, u16 node, u16 visible-options mask, u16 npc net_id` (about 12 B). `DIALOGUE_CHOOSE`:
`u16 session, u8 option`. The server checks a live session, a visible option, the conditions again and distance ≤ 5 m;
moving beyond 6 m closes it. The NPC stops and faces the player during the session.

**`ServerMessages` 800-849** (the range of interaction and dialogue; text notices, the client formats them from the code and
the parameters): 800 interaction out of range, 801 target busy, 802 not in combat, 803 requirement not met, 804 depleted,
805 already opened, 806 dialogue too far, 807 option no longer available, 808 service unavailable in combat, 809 service too
far; 810-849 reserved. New parameter types: 8 QUEST, 9 EVENT, 10 SPEC, 11 NPC, 12 PLACE. Each lane that changes a format bumps
`PROTOCOL_VERSION` on integration (the NPC SPAWN tail, the line TELEGRAPH and these messages are one such change).

## 7. Service and ambient NPCs

### 7.1 Roles

| Role | Where | Service | Owner of the service |
|---|---|---|---|
| Provisions merchant | capital, villages, garrison | `OPEN_VENDOR` | items |
| Armorer / smith | capital, large village, garrison | `OPEN_VENDOR`, `OPEN_REPAIR` | items |
| Crafting-station artisan | capital | orders and recipes (the station is an object) | items |
| Banker | capital (2), never in Eldrun | `OPEN_BANK` | items (after the first slice) |
| **Master of the Orders** | capital, in the Hall of Arms | `OPEN_SPECIALIZATION`: the first choice (free, after the trial at level 10), changing it in the capital out of combat for `8·L + 20` gold, and re-spending talents | [advancement.md](advancement.md) |
| **Mentor** (one per specialization) | capital, in the Hall of Arms | gives the role trial and the flavor of the order; opens the dialogue branch of their specialization | [advancement.md](advancement.md), [quests.md](quests.md) |
| Caravan master (the "stable") | capital, villages, garrison | `OPEN_TRAVEL` | MUN-33 (mounts: MUN-40) |
| War quartermaster | capital, garrison | `OPEN_VENDOR` in merits | PRG-33 (phase 7) |
| Quest giver | everywhere | `ACCEPT_QUEST`, `TURN_IN_QUEST` | MUN-17 |
| Innkeeper | capital, villages | rumors (rare hints), respawn point if the world decides | world |
| Town guard | capital, villages | "directions" (`MARK_MAP`); in PvE villages fights monsters | UI-32 |
| Civilian | everywhere | generic line | none |

- Each capital has **one Master of the Orders** and **one mentor per specialization** (the Hall of Arms holds six slots: five
  specializations and the Sapper of phase 7). The Master and the mentors are different roles on purpose: the Master is the
  service, the mentors give identity. The first slice has four mentors (Vanguard, Linebreaker, Hunter, Healer); the Arcanist
  arrives with the fire staff.
- `ServiceNpcMarker` (in `scripts/world/`): a world-unique `npc_tag`, a proper name, `npc_id` (the template:
  `merchant_vardheim`…), role, `dialogue_id`, services, post and a stroll of at most 3 m. Proper names are added to the
  reserved list of `NameRules` (SOC-01) with the validator, so nobody can take them.

### 7.2 Body, routes and routines

- `AmbientNpcSystem` (server): an entity without `PlayerCharacter` or `Combatant` (`NetEntity.encode_record` already admits
  entities without a character); it cannot be damaged and does not enter `StateHistory`.
- Routes: route markers become polylines on the navigation mesh on load (one query per leg, once); each tick the NPC
  advances along the polyline at 1.4 m/s with an interpolation, about 2-3 µs. The brain runs at 2 Hz: it picks the next leg
  or the pose.
- Activity (talking, sitting, working, sweeping, hammering…) goes in the action byte of the record: an ambient NPC has no
  `CombatState`, so the client interprets it as an activity from the role of its definition.
- Routines (`NpcRoutine`, `.tres`): `[(from_minute_of_day, activity, place or route)]` with the clock of MUN-27 (with no
  clock, a fixed daytime schedule). On waking the NPC appears where it belongs ("jump to schedule"). **Only civilians have
  routines;** service NPCs are always at their post.
- Interest: radius 90 m and weight 0.3 in the accumulator (they move little and interpolation covers 10 Hz).
- Barks (MUN-56): on the client, within 8 m, 60 s cooldown, context `bark`, no voice.

## 8. Performance and budget per zone

### 8.1 Cost per NPC (µs per tick at 60 Hz)

| State | Today (humanoid) | Humanoid target | Light creature target | Ambient |
|---|---|---|---|---|
| Asleep | does not exist: everyone thinks | 0 | 0 | 0 |
| Awake at rest | about 35 (`simulate` with `move_and_slide`) | ≤ 4 (does not simulate if still, grounded, no action, full stamina and no effects) | ≤ 3 | ≤ 2 |
| Patrol | about 45 | ≤ 45 | ≤ 12 | ≤ 3 |
| Combat | 50-100 | ≤ 85 | ≤ 25 | none |

- **AI activity LOD** (MUN-51, for PvE zones; MUN-29 stays with Eldrun): COMBAT (it has a target or a player within 50 m): the
  brain thinks at 10 Hz (every 6 ticks) and simulates every tick. NEAR (a player within 150 m): thinks at 2 Hz (every 30
  ticks) and simulates only if it moves. ASLEEP (no player within 150 m, with 30 m of hysteresis): neither thinks nor
  simulates, and stays motionless where it is. Evaluated per camp every 30 ticks from its center. Respawn timers keep running
  in absolute ticks. An NPC that falls asleep away from its post returns to it instantly.
- A **spatial index** of 16 m (once per tick) for `query_targets`: today it walks every combatant in each query, O(N²) with
  300 NPCs.
- **Light creature** (`CreatureBody extends PlayerCharacter`, server): the same `ActionMachine` (attack times equal to the
  humanoid) but without `move_and_slide`: it advances and adjusts height with `NavigationServer3D.map_get_closest_point`. It
  moves on the mesh (baked with a 0.4 m radius) even if large, and takes hits with its own capsule: small r 0.45 × h 0.9, human
  0.4 × 1.8, large 0.8 × 2.2, huge 1.2 × 3.5 (`HitShapes` already takes radius and height as parameters).

### 8.2 Budget per zone type

| Zone | Hostiles placed | Awake (cap) | In combat (peak) | Ambient | Players per channel | Tick p99 |
|---|---|---|---|---|---|---|
| Capital 1 km | 0 | none | 0 | 60-120 (no physics, 2 Hz) | 64 | ≤ 10 ms |
| PvE 1.5 km | 150-200 | ≤ 90 | 36 | ≤ 40 | **48**, target 64 | ≤ 12 ms |
| PvE 2 km | 220-300 | ≤ 110 | 40 | ≤ 50 | 48 | ≤ 12 ms |
| Border | 250-320 | ≤ 110 | 36 | ≤ 60 | 64 | ≤ 12 ms |
| Dungeon | 40-80 | 25 | 12 | 0 | 5 | ≤ 2 ms per instance |
| Eldrun | about 150 | MUN-29 | MUN-29 | 0 | TEC-34 | TEC-34 |
| Vado Gris | 9 | 9 | 9 | 0 | as today | about 1 ms ([fortress.md 8.3](fortress.md#83-what-f0-f1-and-f2-left-behind-additions-to-the-contract-and-decisions)) |

The count of a full PvE zone: 48 players × 70 µs = 3.4 ms; 30 NPCs in combat × 85 µs = 2.6 ms; 60 near at rest × 10 µs =
0.6 ms; ambient about 0.1 ms. With network and snapshots the median is about 9 ms and the p99 stays at or under 12 ms of
the 16.7 ms tick. The NPC share is **p50 ≤ 3 ms and p99 ≤ 5 ms**. Going from 48 to 64 players needs MUN-51 measured and,
perhaps, `simulate()` in C++.

- If the awake cap is exceeded, the camps farthest from any player are put to sleep first.
- **Network:** with radius interest a player in a camp sees 10-15 NPCs and about 20 players, well under the 50 records per
  snapshot; the NPC SPAWN carries a 7 B tail (level, rank, role, tag).
- Quests cost at most 0.1 ms on average and 0.5 ms at p99 with 200 players.

## 9. Data, validators and tools

| Data | Where | Format | Validator |
|---|---|---|---|
| Bestiary variants | `data/npcs/<family>/<id>.tres` (recursive catalog, unique id) | `NpcDefinition` v2 | `test_npc_catalog` extended: references (weapon, abilities, loot, visual, family), levels 1-60, health and damage envelopes by rank ±30 % (1.3), minimum windows, `level_min <= level_max` |
| Families | `data/npcs/families.tres` | list: id, name (context `npc_family`), default resistances, default loot table | same |
| Scaling | reads O(L) and D(L) from the progression sheet | `NpcScalingRules` | length 60, monotonic |
| Bosses | sub-resource or `data/npcs/bosses/<id>.tres` | `BossScript` | ordered phases, existing weapons, `adds_cap >= 1` if there are adds |
| Camps | prefabs `scenes/world/camps/` + instances in the zone | `NpcCamp` + `NpcSpawner` | unique ids, level inside the zone, posts on the mesh, kill capacity (4.2), sum of alive ≤ `ZoneDefinition.budget.max_hostile_npcs` |
| Dialogues | `data/dialogues/<id>.tres` | 6.1 | reachable nodes, no dead ends without `END`, existing references (quest, shop, NPC, flag), at most 6 options, at most 600 characters, an `es.po` entry (strict mode of `L10n`) |
| Service NPCs | markers in the gameplay layer | `ServiceNpcMarker` | world-unique `npc_tag`, required roles per capital (one Master of the Orders and one mentor per specialization), names added to `NameRules` |
| Routines | `data/npcs/routines/<id>.tres` | `NpcRoutine` | existing places and routes, the day covered with no gaps |

- **Table or `.tres`:** the numeric tables of the bestiary (health, hits, XP and respawn, from T2) are written in CSV and a
  deterministic generator writes the `.tres` with a "generated" header and a test that demands that the repo is its output;
  tactics, bosses and dialogues stay hand-written typed `.tres`. The 18 T1 sheets are written by hand first.
- **`tools/ai/bestiary_report.gd`:** table of health, hit in %, DPS and theoretical TTK per level (1, 10, …, 60) of every
  variant, for review in the PR.
- **`tools/ai/bestiary_balance.gd`:** like `tools/combat_balance.gd`, no network and advancing by hand: combat bots of level L
  against each variant (alone, and 3 against elites and bosses); TTK and damage taken as JSON. Criterion: inside the envelope of 1.3.
- **Localization:** `tools/i18n/l10n_extract.py` gains `NpcDefinition.title` (`npc_title`), the families (`npc_family`),
  `NpcCamp.display_name` (`place`), `DialogueNode.text` (`dialogue`), `DialogueOption.text` (`dialogue_option`) and ambient
  lines (`bark`). The current Spanish `display_name`s in `data/npcs/` become English with UI-66.
- **Debug and GM commands** (in `ZoneCommands`): `npc_spawn <id> <level>`, `camp_info`, `camp_reset`, `rare_force`,
  `npc_wake_all`; `npc_debug` adds the tactic, the phase and the top three threats.

## 10. Code systems

They live in the **zone subsystems of TEC-65** (the split of `zone_server.gd` into `scripts/server/zone/`); until TEC-65 is
integrated the same hooks go where `zone_server.gd` has them today.

### 10.1 New

| File | Layer | What it does |
|---|---|---|
| `scripts/shared/ai/npc_stats.gd`, `npc_scaling_rules.gd` | shared | section 1.2; used by server, tools and tests |
| `scripts/shared/ai/npc_tactic.gd`, `npc_ability_entry.gd`, `boss_script.gd`, `boss_phase.gd`, `boss_action.gd`, `npc_routine.gd`, `npc_family.gd` | shared | data resources |
| `scripts/shared/dialogue/dialogue_definition.gd` (+ node, option, condition, action, `dialogue_catalog.gd`) | shared | section 6 |
| `scripts/shared/world/interactable.gd`, `interaction_rules.gd` | shared | section 5 |
| `scripts/world/npc_camp.gd`, `service_npc_marker.gd`, `interactable_node.gd` | scene (data) | markers |
| `scripts/server/ai/tactics/` (`melee`, `charger`, `ranged`, `caster`, `healer`, `pack`, `passive`, `support`) | server | positioning in COMBAT |
| `scripts/server/ai/threat_table.gd`, `npc_contribution.gd` | server | threat and credit |
| `scripts/server/ai/boss_director.gd` | server | phases, arena, enrage, adds |
| `scripts/server/ai/camp_system.gd` | server | camps, respawn, rares, chests |
| `scripts/server/ai/npc_activity.gd`, `spatial_index.gd` | server | sleep, LOD, index |
| `scripts/server/ai/creature_body.gd` | server | light body |
| `scripts/server/ai/ambient_npc_system.gd` | server | ambient and service |
| `scripts/server/zone/zone_interactions.gd` | server (TEC-65 subsystem) | `INTERACT_*`, channels, dispatch to services |
| `scripts/server/dialogue/dialogue_service.gd` | server | sessions and validation |
| `scripts/client/world/interaction_detector.gd` | client | the "Press E" prompt (UI-27) |
| `scripts/client/ui/dialogue_window.gd` | client | the dialogue window (UI-28) |
| `scripts/client/npc_visual_catalog.gd` | client | `visual_id` → humanoid scene (outfit, tint, scale) or creature |

The architecture rules hold: `scripts/shared/` depends on neither client nor server, and `scripts/server/` and
`scripts/client/` do not depend on each other (checked by `tests/test_architecture.gd`).

### 10.2 Existing files that change

| File | Change |
|---|---|
| `scripts/shared/ai/npc_definition.gd` | v2 fields with defaults (the 5 `.tres` still load); `scales_with_level` |
| `scripts/shared/ai/npc_catalog.gd` | recursive listing by family, v2 validation |
| `scripts/client/war/boss_info.gd` | stops listing the folder and uses `NpcCatalog` (it is shared) |
| `scripts/server/ai/hfsm_brain.gd` | pluggable tactic, `ThreatTable`, flee, taunt, evasion without a route, LOD; the state log with the same seed does not change for the current NPCs |
| `scripts/server/ai/npc_world.gd` | spatial index; optional NPC targets (`targets_npcs`) |
| `scripts/server/ai/npc_spawner_system.gd` | create with parameters (level, tag, name); PvE camps move to `CampSystem`; sleep |
| `scripts/world/npc_spawner.gd` | exports `level`, `npc_tag`, `name_override` |
| the bodies subsystem (`zone_bodies.gd`, or `zone_server.gd::add_npc` before TEC-65) | `NpcSpawnParams`, scaled health, creature body, ambient entities |
| `zone_events.gd` | death rewards with `NpcContribution`; events `npc_killed`, `camp_cleared` |
| `zone_intents.gd` | dispatches `INTERACT_REQUEST` and `DIALOGUE_*` |
| `zone_report.gd`, `zone_commands.gd` | metrics (asleep, awake, in combat, ambient, µs per category) and commands |
| `scripts/server/combat_director.gd`, `combatant.gd`, `combat_resolver.gd` | damage scale by level and difference, family resistances, reduced control, capsule per combatant |
| `scripts/server/progress/progress_service.gd` | `on_npc_killed` with level, rank and credited players |
| `scripts/server/interest_policy.gd` | radius policy also in PvE and capitals (TEC-32 brought to phase 6) |
| `scripts/shared/net/net_messages.gd`, `net_protocol.gd` | NPC SPAWN tail (`u8 level, u8 rank, u8 role, u32 tag`: +7 B), line TELEGRAPH, `INTERACT_*`, `DIALOGUE_*`; a `PROTOCOL_VERSION` bump |
| `scripts/client/nameplates.gd`, `remote_world.gd`, `remote_player_view.gd`, `humanoid_visual.gd`, `war/telegraph_marks.gd` | NPC nameplate, visual by catalog, line mark |
| `tools/i18n/l10n_extract.py` | new fields (section 9) |
| `tests/test_npc_catalog.gd`, `test_hfsm_brain.gd`, `test_npc_system.gd`, `test_nameplates.gd`, `test_architecture.gd` | extended; new files in their layer |

### 10.3 Tick order

It fits the order of TEC-65 (poll, removals, NPC brains, simulate, combat, forts, NPCs, spawns, …): `npc_activity` at the
start of "NPC brains" (every 30 ticks); ambient advances after "simulate" and before "history" (it is not recorded); interaction
channels after "combat" (damage cuts them); `CampSystem.step` in "NPCs", next to the `NpcSpawnerSystem`. The HfsmBrain gains
its tactic, `ThreatTable` and activity LOD without changing this order.

## 11. Dependencies with other domains

| Domain | What this needs | What this gives |
|---|---|---|
| Progression ([advancement.md](advancement.md)) | O(L) and D(L) for 1-60; XP by level difference; `MAX_LEVEL` 60; the normalization of Eldrun | rank multipliers of XP and gold; death events with level and rank |
| Classes ([advancement.md](advancement.md)) | the specialization list (names, mentors), taunt of the Vanguard, cost and cooldown of the change | the Master and mentor NPCs, the `OPEN_SPECIALIZATION` action, the `SPECIALIZATION` condition, the threat and taunt API |
| Weapons ([weapons.md](weapons.md)) | `AbilityDefinition` for NPCs, damage types and resistances, effects (bleed, slow, stun, root, burn, `VULNERABLE`), life staff threat | families with weaknesses that reward swapping weapons with Q |
| Items ([items.md](items.md)) | `LootTable`, personal loot, rarity, tables per family and rank, vendors, repair, bank | a `loot_table` on each variant, credit, the NPCs and actions that open each service |
| Quests ([quests.md](quests.md)) | the quest service, persisted flags, "!" and "?" markers | dialogue with `ACCEPT/TURN_IN`, events `npc_killed`, `camp_cleared`, `talked`, `interacted`, a stable `npc_tag` |
| World ([world.md](world.md)) | `ZoneDefinition` with level range, `content_level` (RvR) and the budget; the points of interest; the mesh per zone; the clock | camp prefabs, the budget and kill-capacity validator, service markers |
| Network and server | radius interest in PvE (TEC-32, brought to phase 6), TEC-65 integrated, one coordinated protocol bump | NPC metrics in `ZoneReport`; TEC-68, the load test |
| Art ([art.md](art.md)) | skeletons of small and large quadrupeds with clips (rest, walk, run, bite, leap or charge, hurt, die, howl), civilians with life clips, the final Hollow, ember and frost materials | `NpcVisualCatalog` and a bestiary gallery to review |
| Social | groups across zones and their split | the shared credit rule at 100 m |
| War (MUN-29, MUN-30, PRG-31) | the normalized level of Eldrun; reinforcement by connected defenders (pending) | the boss framework, the wall-archer tactic, `scales_with_level` |

## 12. Backlog

Rewritten (existing items): **MUN-16** interaction with world objects, **UI-27** "Press E", **MUN-18** dialogue system, **MUN-19**
ambient NPCs (bodies, routes and routines; the service roles go to MUN-55), **MUN-24** humanoid tactics and the first bestiary
(the 14 humanoid T1 sheets), **MUN-25** camps, content level and credit, **MUN-22** (its population part: camps with `NpcCamp`,
the budget and kill-capacity validator, and a walk with bots that does not exceed 90 awake NPCs) and **MUN-29**, which **stays
with Eldrun** (150 NPCs and 100 bots with an AI p99 under 2 ms and priority of NPC records in the snapshot).

New items (numbers assigned in [backlog.md](backlog.md)):

| Id | Title | Phase |
|---|---|---|
| MUN-49 | NPC data model v2 and level scaling (`NpcDefinition` v2, `NpcScalingRules`, recursive catalog, envelope validator, `bestiary_report.gd`) | F6 |
| MUN-50 | NPC level, rank and role on the wire (the 7 B SPAWN tail, scaled health on creation, `damage_scale` by level and difference, line TELEGRAPH) | F6 |
| MUN-51 | **AI activity LOD for PvE zones** (sleep by camp, rest without simulating, 16 m spatial index, brain at 10/2 Hz, awake cap, `ZoneReport` metrics) | F6 |
| MUN-52 | Creature bodies and pack AI (`CreatureBody`, pack, charger and passive tactics, the quadruped T1 sheets with placeholders) | F6 |
| MUN-53 | Boss framework in data (`BossScript`, the Ford Captain migrated, the bandit chief and Hjalmar) | F6 |
| MUN-54 | Threat, taunt and NPC-versus-NPC rules | F6 |
| MUN-55 | Service NPC roles (`ServiceNpcMarker`, the Master of the Orders and the mentors) | F6 |
| MUN-56 | NPC barks and combat shouts | F6 |
| MUN-75 … MUN-78 | Bestiary T2, T3, T4, T5 (with their zones; T2 with MUN-34) | F8 |
| UI-73 | NPC nameplates: level, rank and color by difference | F6 |
| ART-77 | NPC visual catalog and bestiary gallery | F6 |
| ART-78 | Quadruped rigs, small and large (own Blender rigs, CC BY 4.0; pending P4) | F6 |
| TEC-68 | PvE load test: 48-64 bots and 200-300 NPCs with a PvE mode of `BotBrain` | F6 |
| TEC-32 | Radius or grid interest (brought forward from F7 to F6 for the PvE zones) | F6 |

## 13. Production order

Small increments, each with a test and a capture (`tools/quality/sc_*.gd`), archived before and after in `Eldmark-capturas`.

| # | Increment | Test | Capture |
|---|---|---|---|
| N0 | Data v2 and scaling (MUN-49) | `test_npc_catalog` with envelopes; Vado Gris unchanged | `bestiary_report` table (text) |
| N1 | Level on the wire and nameplates (MUN-50, UI-73) | round trips, scaled damage | `sc_remotos_pnj` with nameplate and level, in en/es |
| N2 | Activity LOD (MUN-51) **before the content**, with a stress scene of 240 NPCs | p50/p99 cost and an asleep NPC at 0 | `npc_debug` overlay with asleep and awake |
| N3 | Radius interest (TEC-32) | 37 KB/s with 240 NPCs | metric |
| N4a | Archer tactic and flee + `bandit_swordsman`, `bandit_archer` | bot test with a seed | strip of the archer retreating |
| N4b | Healer, support, caster + the rest of the bandits and Hollow of T1 | heal test and a dodgeable area | bestiary gallery (ART-77) |
| N5 | Camps, respawn and credit (MUN-25) | two players with credit, a healer, scaling, a rare | bandit camp in the test scene |
| N6 | Boss framework, the Captain migrated, the chief and Hjalmar (MUN-53) | same state log; two phases | ground marks of the chief |
| N7 | Light body and pack with placeholders (MUN-52) | at most 2 biting, a dodgeable charge, ≤ 25 µs | pack surrounding (placeholder) |
| N8 | Interaction (MUN-16, UI-27) | door, chest, inscription, rejection at 3.75 m | "E · Open" in en/es |
| N9 | Dialogue (MUN-18) and window (UI-28) | rejected option, validator | dialogue window in en/es |
| N10 | Ambient (MUN-19) | a square of 40 NPCs under 0.5 ms | square with civilians |
| N11 | Service roles (MUN-55) and threat and guards (MUN-54) | every role opens its window; a guard against a wolf | merchant, Master of the Orders, mentor |
| N12 | Population of the 1-10 zone (MUN-22), load test (TEC-68) | budget and kill-capacity validator, a walk with bots, 48 bots and 200 NPCs | views of every point of interest |
| N13+ | One bestiary tier per new zone (MUN-75 … MUN-78) | `bestiary_balance`, gallery | tier gallery |

N2 goes before the content on purpose: if the cost does not fit, it is known with a stress scene and not with the populated
zone. N0-N2 do not depend on art.

## 14. Risks

| Risk | Mitigation |
|---|---|
| **CPU:** `simulate()` in GDScript (about 70 µs) dominates; 36 NPCs in combat plus 48 players brush the tick | Sleep, rest without simulating, light body, awake cap; measure at N2 before populating; 30 Hz per zone if TEC decides; ambient NPCs do not simulate |
| **Network:** with the base policy everybody receives every NPC | Radius interest in F6 (a hard dependency of N3) |
| **Quadruped art:** no CC0 animals in the family and the Bestiary is QAL | Humanoids first; placeholders that block no code or tests; own rigs (P4) |
| **Volume and balance** (about 120 definitions) | Template plus level, visual realm variants, validated envelopes, `bestiary_balance` with bots and seeds (five seeds per adjustment, like fortress.md section 9) |
| **Test determinism** with new tactics | All randomness comes from the seeded RNG of the brain; every tactic writes its transitions in the state log |
| **Navigation mesh** in zones of 1.5-2.5 km (Vado Gris: 0.3 MB and 2 s for 300 m; area ×25) | A 0.3 m cell outside villages or tiled meshes (world domain); a budget of path queries per tick (MUN-51) |
| **Exploits:** shooting from rocks, dragging NPCs, farming rares, parasitic healers | Evasion without a route in 4 s, leash with immune return and erased contribution, rare cooldowns, group credit only with recent action |
| **Captain migration** while MUN-11 is still open | N6 after closing MUN-11; the criterion is the same state log with the same seed |
| **Renumbering of the catalog** when files are added (alphabetical order) | Client and server from the same commit; tests by id; nothing depends on fixed numbers (already the rule of `NpcCatalog`) |
| **Localization debt:** the current `display_name`s are in Spanish | New data in English from N0; UI-66 migrates the old |

## 15. Open questions

| # | Question | Recommendation |
|---|---|---|
| P4 | **Wolves, boars and bears:** own Blender skeletons (small and large, CC BY 4.0) with placeholder bodies in the meantime, or a CC0 animal pack even if it clashes with Quaternius? The Quaternius Bestiary is QAL and cannot be used in a public repository | **Own**, with the user's approval of the animation strips before the second one is made |
| - | Named rares: announce them in zone chat? | No; hints from the innkeeper |
| - | Open-world elites: fixed figures ("recommended 3 players") or scaled by the present players? | Fixed in the open world, scaled only in events and dungeons |
| - | Raiders from other realms at the borders (T5) | Yes: reuses the realm guards and reinforces the theme of war |
