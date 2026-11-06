# Eldmark · Phases 6-8: weapons, abilities and roles

Design of the weapon catalog from the launch onwards: the twelve weapons, the identity and role of each, their
attacks, their five abilities, the resource that pays for them, the attribute they scale with, the budgets that keep
them balanced against each other, the data and code systems that carry them and the order in which they are produced.
It continues [abilities.md](abilities.md) (phase 4: the ability machine, effects, projectiles, the weapon swap and the
potions) and [combat.md](combat.md) (phase 3: the action machine, block, dodge and the measured sheet of §12), takes
their §0 to §4 as read, and puts the new fields on the wire in [networking.md](networking.md) (§5.8 there).

It applies the decisions of the integrated content design of 2026-11-07 (I01, I06, I11, I20 to I33, I64, I65 and I67:
the ids are those of the integrated design, kept in the "Decision" column below so the two can be read side by side).
The specializations themselves, the mastery trees, the level curve and the item scale live in [advancement.md](advancement.md) and
[items.md](items.md); this document only fixes what touches the weapons. Those two files are written in parallel to this one, so
they are named here without a link: the links are added when they land.

Version 1. Every figure is a **starting value (provisional)**: the data is tuned with `tools/combat_balance.gd` and
the generated weapon sheet (§5.7), and the figures of the sheet win over the ones written here. Times are in seconds in
the `.tres` and are converted to ticks on load with `roundi(s · tick_rate)` (the simulation runs at 60 Hz; the
snapshots at 30 Hz), so a zone that drops to 30 Hz keeps the same data.

---

## 0. Decisions

The ids W1-W20 are local to this document: other documents cite them with the file ("weapons.md W4"), because
`world.md` also numbers its decisions W1-W17.

Almost all of them come from the integrated design; the user's three (free weapons plus a specialization at level 10,
maximum level 60, free assets only) are the first three rows.

| # | Decision | Why |
|---|---|---|
| W1 | **Free weapons.** Any character can carry any weapon, two at a time with Q; no weapon belongs to a realm (the realm only changes the model and what each garrison carries). The class is a **specialization** chosen at level 10 ([advancement.md](advancement.md)). Replaces "No classes" (combat.md §0). *(I01, user)* | Swapping weapon has to be cheap and symmetric between realms: an exclusive weapon would unbalance the war and triple the tuning. |
| W2 | **Catalog of 12 weapons, 10 at launch** (end of phase 8). Phase 6: hatchet, life staff, fire staff (after sword and shield and bow, which exist). Phase 7: crossbow, frost gauntlet, war hammer, greatsword. Phase 8: spear. After launch: twin daggers, great axe. **No gunpowder** and no ammunition. *(I25)* | The order follows the animation clips that exist (§8.4) and what the war needs: the hammer is moved up to phase 7 for the sieges. Gunpowder has no place in the world (world.md: Askarra is bronze and embers) and the crossbow covers the slow piercing shot. Ammunition would add an economy and a bag slot with no decision in RvR. |
| W3 | **Five actives per weapon**: 3 of base and 1 that opens each of the two branches of the mastery tree. You carry **3 per weapon** (6 with the swap) plus the ultimate, chosen for free out of combat. At most **2 catalog variants** `<id>_2` per weapon (one per branch). The other 20 abilities of the original proposal stay as a **reserve pool** of data for after the launch (appendix A). *(I11)* | Production: 50 actives at launch instead of 70, each one with data, icon, VFX, clip and a test. Three of five is a real choice without a bar nobody can fill. |
| W4 | **Slots and unlocks by level.** Ability slots 1, 2 and 3 open at character levels 1, 3 and 6; the 4th and 5th ability of each weapon open from level 8 with the row-2 node of its tree (mastery); variants come with row 4 (level 20); the ultimate with the specialization at 10 ([advancement.md](advancement.md)). *(I12)* | It is the "abilities by level unlock" request, without tying the mastery to the level. |
| W5 | **Only some things are predicted per character**: the weapons, the picked abilities, the ultimate, the mana and the load class. Passives, talents, attributes, specialization and affixes touch **server-only values** (damage, mitigation, healing, effects, controls, block cost). Whatever needs to change a predicted field (cooldown, timings, displacement, projectile) is a **catalog variant** with its own id. *(I21)* | Fewer prediction divergences: the `prediction_hash` stays one for all the players and the state carries only which ability is in each slot. |
| W6 | **Mana only on the three magic weapons** (life staff, fire staff, frost gauntlet): 1000, regenerates 1 per tick (60/s) after 1.5 s without spending, shared by the two weapons; light attacks are free, heavies cost 60-100, abilities 120-300, and abilities keep their cooldown. **The stamina potion becomes the tonic**: +400 stamina and +300 mana. Concentration does not regenerate mana. *(I27, I08)* | Stamina stays the defensive resource (abilities.md §0). The cooldown is still needed: the re-arm rule of the action byte (abilities.md §5.5) demands it and it stops a mage from emptying the pool in one second. Regeneration by an attribute would be a predicted value that differs per character (W5). |
| W7 | **Attributes per weapon**: sword and shield STR/DEX, bow DEX/STR, hatchet STR/DEX, life staff FOC/INT, fire staff INT/FOC, crossbow DEX/INT, frost gauntlet INT/FOC, war hammer STR/DEX, greatsword STR/DEX, spear DEX/STR, twin daggers DEX/INT, great axe STR/DEX. **CON is never a weapon attribute.** Weight 1.0 for the principal and 0.5 for the secondary. *(I26)* | The hammer was proposed with CON as secondary; CON already adds health, so it would count twice. The two staves share attributes so that fire plus life is a natural pair. |
| W8 | **The dodge belongs to the load, not to the weapon.** `sword_dodge` becomes `standard_dodge`; only the armor load class changes it (5.5 / 4.5 / 3.0 m for 250 / 300 / 350 stamina, regeneration delay 0.5 / 0.6 / 0.8 s; [items.md](items.md)). *(I28, I35)* | If the greatsword also dodged worse than the others, the heavy armor would punish the same player twice. One lever is easier to tune and to read. |
| W9 | **Every melee weapon blocks**, with a mitigation per weapon: shield 1.0, two-handed 0.7, one-handed and spear 0.6, daggers 0.5; against magic damage the shield mitigates 0.5 and the rest 0.3. Ranged and magic weapons do not block. *(I28)* | The numbers are already data (`block_mitigation`, combat.md §2); only the table is fixed. With no block, the ranged weapons live by position and dodge, like the bow today. |
| W10 | **Damage types**: slashing 0, piercing 1, blunt 2, **fire 3** (the `ELEMENTAL` of today), frost 4, light 5. **Physical and elemental armor** are separate and resistances are per type. Closes what CMB-07 was missing. *(I29)* | Resistances per type need types with meaning; three elements give realm armors (Vardheim against frost) without inventing a large table. |
| W11 | **Healing without a target**: projectiles that stop at the first ally, areas on the ground, areas around the caster, with a cap on targets. Self-healing ×0.6; sustained healing on one ally ≤ **117 HPS**; healing generates threat (0.5 × healed); wounded allied NPCs can be healed; a knocked-down player is picked up, not healed. *(I30)* | Same principle as the rest of the combat (vision.md: no target selection). The self-heal reduction prevents the immortal healer in a duel. The role trial of the Healer needs healable NPCs. |
| W12 | **Role bands and budgets** (§3.1): DPS bands over the 156.3 DPS of the sword combo; control ≤ 2.5 s every 20 s; burst ≤ 500 in 3 s; areas ≤ 6 m and ≤ 8 targets per pulse, with a warning if a hit does 150 or more; 48 areas per zone and 2 per owner. Passives of one weapon tree add at most **8 %** of effectiveness. *(I31, I10)* | The bands are relations between weapons, so they hold at any power. The 8 % (instead of 10 %) leaves the normalization of Eldrun room to close at 1.15. |
| W13 | **New status kinds, all server-only**: `FORTIFY`, `VULNERABLE`, `WEAKEN`, `HEALING_DOWN`, `LIFESTEAL`, `UNSTOPPABLE`. `FORTIFY` is the `MITIGATION_UP` of the progression proposal and `VULNERABLE` its `MITIGATION_DOWN`: one name each. *(I32)* | Rule of networking.md §6.7: what changes the simulation enters `PlayerState`. These do not, so state and hash do not grow. |
| W14 | **Ground areas** are a new resource (`GroundAreaDefinition`) and a new server system (`AreaSystem`); on the wire an entity of kind AREA with no snapshot records (§6.5). *(armas D4, I67)* | Healing zones, traps, walls and rains are the same machine. Like the projectiles, they cost two reliable messages and no snapshot bytes. |
| W15 | **The ultimate is one more ability**, of the specialization and not of the weapon: its own slot, key **F**, `PlayerInput` bit 13 `ULTIMATE`, cooldown 150 s that survives death and logout, at most 10 targets. The data of the five ultimates is [advancement.md](advancement.md)'s; the slot is this document's. *(I06)* | It reuses the whole ability system. With 150 s and 150 players in Eldrun that is one ultimate per second, which the CPU and the readability can take. |
| W16 | **Two-weapon combos are suggestions** for the five specializations (§2.5); the Herald of the original proposal is dropped. A specialization favors weapons by **tags** (§2.4), never by id. *(I03, I33)* | The Banner of the Vanguard and the control of the Arcanist already cover support; each specialization costs ranks, an ultimate, VFX, a test, a mentor and an icon. |
| W17 | **Numbers at the level-60 reference.** The `.tres` figures are those of the reference character (level 60, equipment of item level 52, attributes 75/25 and CON 33; health 1000, damage factor 1.0). Item level, attributes and affixes scale them on the server ([items.md](items.md), [advancement.md](advancement.md)). Mitigation is relative to the reference armor (combat.md §4.4). *(I18, I20)* | The measured sheet of combat.md §12 stays valid and no balance test changes. |
| W18 | **Tables as CSV, structure as `.tres`.** Weapons and abilities are typed `.tres` written by hand (or from a scaffold) with a validator and a **CSV export and apply round trip** to balance in a spreadsheet; the numeric tables of other systems are CSV that a generator turns into `.tres`. *(I64)* | The `.tres` is the single source of the combat data; the CSV is a view for balancing and is not versioned as a source. |
| W19 | **Animations only from free sources**: the clips of UAL1 and UAL2 Standard, segments, left-hand IK, an own pose-clip tool, and a KayKit Free retarget trial as a **decision gate (ART-70)**. No paid pack. *(user)* | See the animation risk in §12. |
| W20 | **`PROTOCOL_VERSION` goes up when a lane that changes the format merges**: 8 is L4a (TEC-57), then each lane bumps its own (9, 10...). No numbers are reserved per lane. *(I65)* | Six lanes would otherwise fight for the number. |

---

## 1. What is predicted and what the server decides

Extends the table of [abilities.md §1](abilities.md#1-what-is-predicted-and-what-the-server-decides). Rule I21: per
character, only the first group of rows is predicted; everything else is the server's value.

| Data | Where it lives | Predicted | Travels in |
|---|---|---|---|
| The two weapons | `CombatState` (`weapon_id`, `alt_weapon_id`) | Yes (swap); the pair is set by LOADOUT and enforced by the server | own state; public SPAWN; LOADOUT |
| The picked abilities (3 per weapon) | `CombatState.ability_picks` | Yes; the server validates every pick against what the character has unlocked | own state; LOADOUT v2 (owner only) |
| Ultimate: id and cooldown | id in the loadout configuration, `ultimate_ready` in `CombatState` | Yes | LOADOUT v2 (owner only); own state |
| Mana, its regeneration delay and the load class | `CombatState.mana`, `mana_regen_tick` | Yes | own state |
| Cooldowns of abilities (6) and potions | `CombatState` (absolute ticks) | Yes (as in phase 4) | own state |
| Damage, healing, mitigation, block cost, effect durations and controls | server, from attributes, talents, passives, specialization and affixes | **No** | HIT, HEAL, STATUS |
| `FORTIFY`, `VULNERABLE`, `WEAKEN`, `HEALING_DOWN`, `LIFESTEAL`, `UNSTOPPABLE` | `Combatant` (`StatusSystem`) | **No** | STATUS |
| Slow, root, haste (movement scale) | `CombatState` slots, enforced by the server | The effect on the speed, yes | own state; STATUS |
| Knockdown (action 14) and pull | imposed by the server, as the stun is | The movement during it, yes | own state |
| Ground areas | `AreaSystem` | **No** (the slows and roots they apply enter through the movement slots) | AREA SPAWN and DESPAWN |
| Projectiles | `ProjectileSystem` | Only the own one, as an image | PROJECTILE SPAWN and DESPAWN |

A talent, passive or affix that would change a predicted field is rejected by the validator of [advancement.md](advancement.md): it
becomes a variant of the catalog (§3.2) or a server-only value.

---

## 2. Catalog

### 2.1 The twelve weapons

"Band" is the budget row of §3.1. "Clips" says where the animation comes from (§8.4 details it per weapon): U1 =
`ual1/`, U2 = `ual2/`, IK = left hand taken to the grip with IK, OWN = clip made with the pose tool.

| # | Weapon (`id`) | Role | Attributes (main / secondary) | Resource | Reach | Block | Band | Phase | Clips |
|---|---|---|---|---|---|---|---|---|---|
| 1 | Sword and shield (`sword_shield`) | Tank, front line | STR / DEX | Cooldown | 2.6 m | 1.0 (120°) | Shield | Done (F3) | U2 complete |
| 2 | Bow (`bow`) | Sustained physical ranged | DEX / STR | Cooldown | 90 m | No | Ranged | Done (F4) | Poor (ART-41) |
| 3 | Hatchet (`hatchet`) | Melee pressure, throwing | STR / DEX | Cooldown | 2.4 m and 30 m | 0.6 (100°) | No shield | **F6** | U2 complete |
| 4 | Life staff (`life_staff`) | Healer, support | FOC / INT | Mana | 40 m | No | Healer | **F6** | U1 `Spell_Simple_*` |
| 5 | Fire staff (`fire_staff`) | Area magic damage, zone control | INT / FOC | Mana | 40 m | No | Magic | **F6** | U1 `Spell_Simple_*` |
| 6 | Crossbow (`crossbow`) | Burst ranged, anti-armor, wall defense | DEX / INT | Cooldown | 110 m | No | Ranged | F7 | U1 `Pistol_*` |
| 7 | Frost gauntlet (`frost_gauntlet`) | Magic control, zone, escape | INT / FOC | Mana | 36 m | No | Magic | F7 | U1 `Punch_*`, U2 `Slide_*` |
| 8 | War hammer (`war_hammer`) | Area control, siege, offensive tank | STR / DEX | Cooldown | 2.8 m | 0.7 (110°) | Control | F7 | U2 `TreeChopping_Loop` + IK |
| 9 | Greatsword (`greatsword`) | Area melee damage, bruiser | STR / DEX | Cooldown | 3.0 m | 0.7 (120°) | No shield | F7 | U2 slashes + IK + turn |
| 10 | Spear (`spear`) | Mid-range control, knockdown, pull | DEX / STR | Cooldown | 3.6 m | 0.6 (100°) | Reach | F8 | OWN or U1 `Push_Loop` + IK |
| 11 | Twin daggers (`twin_daggers`) | Assassin, backstab damage | DEX / INT | Cooldown | 2.0 m | 0.5 (90°) | Assassin | After launch | U1 `Punch_*` + left hand |
| 12 | Great axe (`great_axe`) | Bruiser with pull and lifesteal | STR / DEX | Cooldown | 2.8 m | 0.7 (120°) | No shield | After launch | Reuses the hammer |

Role coverage at launch: tank 2 (sword, hammer), melee damage 2 (hatchet, greatsword), control 3 (hammer, spear,
frost), physical ranged 2 (bow, crossbow), magic 2 (fire, frost), healer 1 (life). Every attribute but CON has at
least two weapons as principal or secondary: STR (sword, hatchet, hammer, greatsword), DEX (bow, crossbow, spear), INT
(fire, frost), FOC (life); the secondary attributes make the bridge between weapons so that the combos of §2.5 share
an attribute.

### 2.2 Discarded or postponed

| Candidate | Decision | Why |
|---|---|---|
| Musket, blunderbuss | Discarded | W2. |
| Rapier | Postponed with no phase | Its identity (riposte and parry) needs a reactive system (a blow that fires on being hit) that does not exist, and there are no fencing clips. |
| Flail or censer (Solmarch) | Candidate after launch | Melee support weapon (heals by hitting). It fits, but the life staff already covers support and there are no chain clips. |
| Void gauntlet (support with weakens) | Discarded | It overlaps with the life staff (branch Judgment) and the frost gauntlet. |
| War banner | As an ultimate, not as a weapon | A weapon that only gives auras has no attack of its own to read; the Banner of the Vanguard is its home. |
| Tower shield | Discarded | A second shield with the same animations; the shield wall covers its role. |
| Herald (sixth specialization of the original proposal) | Dropped | W16. |

### 2.3 Attributes

The five attributes are those of [advancement.md](advancement.md) (STR, DEX, INT, FOC, CON). Each weapon scales its damage with the
principal (weight 1.0) and, if it has one, the secondary (weight 0.5); the bonus per point and its diminishing returns
are [advancement.md](advancement.md)'s. The life staff scales **damage and healing** with FOC. Pairs that share an attribute (basis of
§2.5): STR (sword, hatchet, hammer, greatsword), DEX (bow, crossbow, spear, daggers), INT/FOC (fire, frost), and the
bridges by the secondary: DEX in the STR weapons, STR in the spear and the bow, INT in the crossbow and the daggers,
FOC in the frost gauntlet (with the life staff).

### 2.4 Tags and specializations

`WeaponDefinition.tags` (server only) is what the passives and ranks of a specialization point at. A new weapon enters
by tag, so no specialization lists weapon ids.

| Weapon | Tags |
|---|---|
| Sword and shield | `melee`, `one_handed`, `shield` |
| Bow | `ranged` |
| Hatchet | `melee`, `one_handed`, `thrown` |
| Life staff | `magic`, `staff`, `healing` |
| Fire staff | `magic`, `staff`, `elemental` |
| Crossbow | `ranged` |
| Frost gauntlet | `magic`, `elemental` |
| War hammer | `melee`, `two_handed` |
| Greatsword | `melee`, `two_handed` |
| Spear | `melee`, `two_handed`, `polearm` |
| Twin daggers | `melee`, `one_handed`, `skirmish` |
| Great axe | `melee`, `two_handed` |

| Specialization | Favored tags | Favored weapons at launch | In the first vertical slice | Suggested attributes |
|---|---|---|---|---|
| Vanguard | `shield`, `polearm` | sword and shield, spear | sword and shield | CON / STR |
| Linebreaker | `two_handed`, `thrown` | war hammer, greatsword, spear, hatchet | hatchet | STR / CON |
| Hunter | `ranged`, `thrown`, `skirmish` | bow, crossbow, hatchet (twin daggers when they arrive) | bow, hatchet | DEX / STR |
| Healer | `healing`, `shield` | life staff, sword and shield | life staff, sword and shield | FOC / CON |
| Arcanist | `elemental`, `staff` | fire staff, frost gauntlet, life staff | none: arrives with the fire staff, right after the slice | INT / FOC |
| Sapper (phase 7) | `two_handed`, `siege` | war hammer, greatsword | none | STR / CON |

The `skirmish` tag exists so that the twin daggers (CMB-61) are favored by one specialization from the day they enter: the Hunter
harries and punishes whoever strays. The validator (V12) checks that every weapon of a phase is favored by at least one specialization and that at least
**40 %** of the value of every rank is general (works with any weapon). The ranks and the ultimates are in
[advancement.md](advancement.md).

### 2.5 Two-weapon combos (suggestions)

A table for the interface and for new players, not a rule: any pair is legal. The ultimates are not listed here.

| Specialization | Role | Recommended combos (main + Q) | Why |
|---|---|---|---|
| Vanguard | Tank | **Sword + hammer** (wall and siege); sword + spear (door control); sword + life staff (solo PvE) | STR is shared; the hammer gives the control the sword lacks |
| Linebreaker | Melee damage | **Greatsword + hatchet** (area and pressure with a throw); greatsword + hammer; hatchet + bow | STR with DEX as the bridge; the hatchet covers mid-range |
| Hunter | Physical ranged | **Bow + spear** (run and slow whoever arrives); crossbow + hatchet; bow + crossbow (walls only) | DEX is shared; the second weapon defends up close |
| Arcanist | Magic damage | **Fire + frost** (damage and control from the same mana); fire + crossbow (DEX and INT) | INT is shared |
| Healer | Healing | **Life + frost** (control to peel, FOC as the bridge); life + sword and shield (front line) | The frost gauntlet protects the healer and still adds FOC |

---

## 3. Common rules

### 3.1 Role budgets (bands)

DPS measured against the dummy with `tools/combat_balance.gd` (combat.md §12, reference armor, power 1.0), with whole
cycles. "Abilities" is the DPS added by the 3 base abilities used on cooldown, at 3 m for melee and 10 m for ranged,
on a single target.

| Band | Weapons | Light (DPS) | Heavy at full charge (DPS) | Abilities | Other |
|---|---|---|---|---|---|
| Shield | sword and shield | 145-160 | ≤ 140 | ≤ 25 % of the light | block 1.0 |
| Control | war hammer | 145-160 | ≤ 160 | ≤ 25 % | control ≤ 2.5 s / 20 s |
| No shield (reach ≤ 3 m) | hatchet, greatsword, great axe | 160-182 | ≤ 160 | ≤ 25 % | block ≤ 0.7 |
| Reach (> 3 m) | spear | 140-155 | ≤ 140 | ≤ 25 % | |
| Assassin | twin daggers | 130-145 from the front | ≤ 140 | ≤ 25 % | back ×1.8 |
| Ranged | bow, crossbow | 90-125 | ≤ 135 | ≤ 25 % | no block |
| Magic | fire staff, frost gauntlet | 88-110 | ≤ 135 | ≤ 60 %, limited by mana | no block |
| Healer | life staff | damage 55-75; healing of the light ≤ 80 HPS | healing ≤ 115 HPS | | total sustained healing on one ally ≤ 117 HPS |

Rules that hold for every weapon (the validator of §5.7 checks them from the data):

- **Control**: seconds of stun and knockdown (weight 1) and root (weight 0.5) that the base kit, used on cooldown,
  gives in 20 s, ≤ 2.5 s. Slows do not count. The chain of controls of combat.md §4.4 still cuts the third one.
- **Burst**: maximum damage in 3 s against a still dummy with lights and the 3 base abilities, ≤ 500 (half the base
  health). No single-player combination kills in 3 s.
- **Areas**: radius ≤ 6 m, ≤ 8 targets per hit or pulse, and every area hit of 150 or more with a warning: cast ≥ 0.4 s
  or delay ≥ 0.5 s. At most 48 areas per zone and 2 per owner. Specialization ultimates are exempt from the radius and target
  caps of weapon areas and have their own: radius ≤ 10 m and ≤ `ultimate_max_targets` (10) per pulse (the Bulwark Banner, Hail of
  Shafts and Prayer of the Flame of [advancement.md](advancement.md) §8.4 need it).
- **Healing**: ≤ 0.75 × 156.3 = 117 HPS sustained on one ally with lights and the strongest legal triple of abilities
  on cooldown; self-healing ×0.6.
- **Cooldowns**: ≥ 6 s on actives, ≥ 120 s on ultimates (150 s in practice).
- **Passives of a tree**: the sum adds at most **8 %** of effectiveness per weapon tree (damage, mitigation or
  healing), checked by the validator of [advancement.md](advancement.md) with this figure (V12).

Why these bands: the weapons without a shield pay their higher DPS (+6 % to +16 %) with a block that lets 30-40 % through
and no wall; the ranged weapons pay with misses and with not blocking; the spear pays its reach; the magic weapons pay
with mana and win in area. The target TTK between equals (combat.md §12.5, median 10-15 s) is measured again with bots
in Vado Gris with each new pair.

### 3.2 The ability set of a weapon

- **Archetypes** (they share code, VFX, clip and bot role): shaped strike, charge (a dash with a strike), projectile,
  fan (several projectiles), area on the ground, area around yourself (centered), channel (block, spin or stream with
  re-hit), self buff, ally support and trap. The base kit of every weapon carries **one of mobility or approach, one
  signature (damage or control) and one of utility or defense**: the default bar always works.
- **Five actives**: the 3 base abilities (available from the start; slot 1, 2 and 3 open at levels 1, 3 and 6) and one
  per branch, which is the **A node of row 2** of that branch of the mastery tree (opens from level 8 with 4 points in
  the branch). Each weapon's table lists the branch names.
- **Variants**: a variant `<id>_2` replaces its base in the bar when the character has the **V node of row 4** of that
  branch (level 20). It exists only when the node changes a **predicted** field (cooldown, cast/active/recovery times,
  displacement, `move_speed_scale`, projectile count or speed, mana cost); a node that only touches server fields
  (damage, effect, duration, radius of an area, controls) is a modifier (M node) in the tree and not a catalog
  entry. Each variant lists which predicted field it changes (§4). At launch that makes **2 variants on the sword and
  shield and 1 on the greatsword**; the other weapons have none and may get one if a tuning pass needs a cooldown
  change.
- **Pool**: `ability_pool` holds the 5 actives and their variants (at most 15 entries, so the 4-bit index of
  `ability_picks` always fits); the 3 default picks are the base abilities.
- **Slots**: 3 per weapon, chosen out of combat with no action in progress, like equipping (progression.md §0). The two
  triples travel in the state and swap with Q along with the cooldowns.
- **Changing an ability**: out of combat. A slot's cooldown is kept in the slot (an absolute tick): replacing an
  ability that is cooling down by another does not make it ready.
- **Production at launch**: 10 weapons × 5 = **50 actives**, at most 20 variants (3 planned), 5 ultimates (+1 of the
  Sapper) and 300 talent nodes with about 40 passives from a closed set ([advancement.md](advancement.md)).

### 3.3 Resource: mana and the tonic

| Value (`CombatRules`) | Figure | Predicted |
|---|---|---|
| `mana_max` | 1000 | Yes |
| `mana_regen_per_tick` | 1 (60/s) | Yes |
| `mana_regen_delay_s` | 1.5 s from the last spend | Yes |
| Cost of a magic light | 0 | |
| Cost of a magic heavy | 60-100 | Yes (`AttackDefinition.mana_cost`) |
| Cost of a magic ability | 120-300 | Yes (`AbilityDefinition.mana_cost`; channels use `mana_per_s`) |

Without enough mana the ability does not come out and the button blinks, like stamina with the dodge. The pace: the
base kit of fire on cooldown spends 52 mana per second and the one of life 55; with the 1.5 s wait after each spend, a
mage that casts every 4 s recovers about 37/s and runs dry in a little over a minute of continuous fighting, which is the
intent (decide when to spend). Mana is **one pool for the character**, shared by the two weapons: a staff and a
non-magic weapon is a legal pair, a staff and a gauntlet draw from the same pool.

**The tonic** (key T, replaces the stamina potion): +400 stamina and +300 mana, both predicted, same shared 20 s cooldown
and charges per life (abilities.md §2.3). The two consumable keys do not grow.

### 3.4 Dodge and block

**Dodge.** One `standard_dodge.tres` for every weapon. Only the load class of the worn armor changes it (class 0 light,
1 medium, 2 heavy; two bits of the state, §6.1): distance, stamina cost and the stamina regeneration delay come from
the table in W8, which [items.md](items.md) owns. Weapon, specialization and talents never change it (W5).

**Block** (`can_block`, `block_mitigation`, `block_angle_deg` per weapon):

| Class | Weapons | Block angle | Mitigation vs physical | vs magic (`block_magic_mitigation`) | Stamina per point |
|---|---|---|---|---|---|
| Shield | sword and shield | 120° (wall: 180°) | 1.0 | 0.5 | 0.6 |
| Two-handed | war hammer 110°, greatsword and great axe 120° | per weapon | 0.7 | 0.3 | 1.0 |
| One-handed and spear | hatchet and spear 100° | 100° | 0.6 | 0.3 | 1.2 |
| Daggers | twin daggers | 90° | 0.5 | 0.3 | 1.2 |
| Ranged, magic | bow, crossbow, staves, gauntlet | none | | | |

The heavy armor trait (−15 % stamina when blocking) and the Vanguard rank bonus are server-side modifiers of the cost
(`BLOCK_STAMINA` passive). `greatsword_blade_guard` (reserve pool) was the only ability with its own block.

### 3.5 Damage types, structures and magic block

| Type | Value | Against structures (`structure_*_multiplier`) | Armor class | Blocked by |
|---|---|---|---|---|
| Slashing | 0 | 0.35 (as today) | physical | block mitigation of the weapon |
| Piercing | 1 | 0.2 (as today) | physical | same |
| Blunt | 2 | 1.0 (as today) | physical | same |
| Fire | 3 (the `ELEMENTAL` of today) | 0.6 (as today) | elemental | `block_magic_mitigation` |
| Frost | 4 | 0.3 | elemental | same |
| Light | 5 | 0.2 | elemental | same |

Physical armor mitigates types 0-2 and elemental armor types 3-5; the resistances by type (CMB-07) apply on top. A hit
can carry its own `structure_damage_scale` (the war hammer's `hammer_wrecking_blow` does ×2.0 against doors, GUE-10).
The formula and the reference armor are in [combat.md §4.4](combat.md#44-damage-scriptssharedcombatdamage_formulagd).

### 3.6 Allies and healing

- `target_filter` on attacks, abilities, projectiles and areas: `ENEMIES` (the default, as today), `ALLIES`,
  `ALLIES_AND_SELF`, `SELF` and `ANY` (hurts enemies and heals allies: the orb of the life staff). There is still no
  friendly fire (combat.md §0): what hurts still passes through allies.
- Healing uses the same rewind as damage (abilities.md §4.4) and line of sight; the HEAL event (8) already exists.
- `max_targets` per hit or pulse, in the resolver's order (nearest to the center first).
- **Self-healing ×0.6** (`CombatRules.self_heal_scale`). A healer alone against a sword attacker lasts 1000 / (156 − 70)
  ≈ 11.6 s instead of 6.4 s: it survives longer, it does not win alone.
- **Threat**: healing adds half of what was healed as threat to the NPCs fighting the healed ally
  (`CombatRules.heal_threat_scale` 0.5; `HfsmBrain`). The sword's challenge fixes the NPCs' target for 4 s.
- **Allied NPCs** that are wounded can be healed by the same rules (the trial of the Healer needs them).
- Nothing heals a knocked-down or dead player: a knocked-down ally is picked up (abilities.md §4.5).

### 3.7 Status kinds

`StatusEffectDefinition.Kind` gains `FORTIFY` (damage taken −x), `VULNERABLE` (+x), `WEAKEN` (damage dealt −x),
`HEALING_DOWN` (healing received −x), `LIFESTEAL` (heals x of the damage dealt) and `UNSTOPPABLE` (no stagger,
knockback or knockdown; stun still applies). All are server-only (W13). Common statuses:

| Status | Kind | Figure | Duration | Stacking |
|---|---|---|---|---|
| `fortified` | FORTIFY | 0.15 | 6 s | the strongest |
| `vulnerable` | VULNERABLE | 0.10 | 5 s | the strongest |
| `weakened` | WEAKEN | 0.15 | 5 s | the strongest |
| `wounded` | HEALING_DOWN | 0.30 | 6 s | refreshes |
| `lifesteal` | LIFESTEAL | 0.25 | 6 s | refreshes |
| `unstoppable` | UNSTOPPABLE | n/a | 4 s | refreshes |
| `empowered` | DAMAGE_UP (exists) | 0.15 | 8 s | the strongest |
| `burning` | DAMAGE_OVER_TIME | 15 fire every 1 s | 4 s | refreshes |
| `poisoned` | DAMAGE_OVER_TIME | 20 every 1 s | 5 s | up to 2 |
| `chilled` | SLOW | ×0.7 | 2 s | the strongest |
| `hasted`, `hasted_strong` | SLOW with scale > 1 | ×1.2 and ×1.3 | 4 s | the strongest |
| `slowed`, `rooted`, `bleed` | exist | | | |

The figures written in an ability ("`fortified` 20 %") are the `status_magnitude` and `status_duration_s` of that
application. The movement statuses do not take a magnitude per application (their scale is predicted), which is why
there are two haste statuses. In `DamageFormula` the three factors apply in a fixed order: `WEAKEN` on the attacker, then
`VULNERABLE` and `FORTIFY` on the victim.

### 3.8 Ground areas

A `GroundAreaDefinition` (§5.3) is created at the commit of an ability or the impact of a projectile, pulses every
`pulse_every_s` and disappears at the end of `duration_s`. Its placement is `SELF` (on the caster), `AIM_POINT` (the
point the camera ray finds, within `placement_range_m`; at the caster's feet if there is no ground) or `ORIGIN` (where
a dash started). A `delay_s` gives the warning the client draws, filling during that time. `trigger_once` makes a trap
(the first enemy that enters fires it) and `blocks_projectiles` a wall (the frost wall). Areas never change the
simulation: the slows and roots they apply enter through the movement slots, as today. Budgets for weapon areas: radius ≤ 6 m, ≤ 8
targets per pulse (`area_max_targets_cap`); an ultimate's area is exempt and has radius ≤ 10 m and ≤ 10 targets
(`ultimate_max_targets`); 48 areas per zone and 2 per owner; the oldest of an owner is removed when
a third is placed. Whoever owns an area dying or leaving the zone removes it.

### 3.9 Power, Eldrun and the item scale

The weapon (family) gives timings, shapes and base damage; the **item** gives the power. The scale is [items.md](items.md)'s
(W17): everything on an item is multiplied by `k(NOe) / k(52)`, so a level-1 item deals 0.40 of the reference and one of
level 60 deals 1.10. In the normalized zones (Eldrun, Vado Gris) the level and the attributes are rescaled and the
reference is used ([advancement.md](advancement.md)). The bands of §3.1 are relations between weapons, so they are valid at any power.
`ItemDefinition.required_level` goes to `@export_range(1, 60)`.

---

## 4. Weapon sheets

Notation: times in seconds (ticks at 60 Hz in parentheses where they matter); "cast/active/recovery" are the phases of
[abilities.md §2.1](abilities.md#21-resources-scriptssharedcombat-data-in-datacombat); shapes are `HitShape` (reach,
angle; heights 0.2-2.0 m unless said otherwise). Names are in English with the Spanish name in the localization file
(§5.6); the `id` is the file name. Each weapon lists exactly **five actives** (three base and one per branch), the
variants it has (if any, with the predicted field that changes) and the reserve abilities it keeps for later
(appendix A). The branch names are those of the mastery tree ([advancement.md](advancement.md)).

### 4.1 Sword and shield (`sword_shield`) · done

Front-line tank: full block, stuns, protects those behind from arrows. Its attacks, block and base abilities do not change
(combat.md §2, abilities.md §2.3). Light combo 310 damage in 119 ticks (**156.3 DPS**).

| Ability (`id`) | Branch | Cast/active/recovery | Cooldown | Effect |
|---|---|---|---|---|
| `shield_bash` Shield Bash | Base | 0.3 / 0.1 / 0.4 | 12 s | Sector 2.2 m, 90°: 60 blunt, stuns 0.8 s, unblockable; dash 1 m/s, movement ×0.2 |
| `shield_rush` Shield Rush | Base | 0.15 / 0.4 / 0.35 | 16 s | 6 m dash, sector 1.8 m, 140°: 50 blunt, stagger 0.4 s, knockback 6 m/s, hyper armor while active |
| `shield_wall` Shield Wall | Base | 0.2 / channel ≤ 6 s / 0 | 18 s | 180° block (stamina 0.6), 2.6 × 2.0 × 0.3 m box that stops enemy arrows; movement ×0.3 |
| `sword_challenge` Challenge | Bulwark | 0.25 / 0.1 / 0.35 | 20 s | 360°, 8 m: NPCs touched fix you as their target for 4 s (`taunt_s`); you get `fortified` 15 % for 4 s |
| `sword_rending_thrust` Rending Thrust | Steel | 0.25 / 0.1 / 0.4 | 12 s | 3.0 m, 40°: 110 piercing and `vulnerable` +10 % for 6 s |

**Variants (2, both change the cooldown, a predicted field)**: `shield_bash_2` (Bulwark, row 4): cooldown 12 → 10 s;
`sword_rending_thrust_2` (Steel, row 4): cooldown 12 → 10 s. The stun lengthening of the Bulwark branch (0.8 → 1.0 s) and
the stronger `vulnerable` (+15 %) are server fields and live as M nodes in the tree, not as catalog entries. Base
control: 0.8 s every 12 s = 1.33 s per 20 s.

Reserve: `sword_rally`, `sword_leaping_strike`. New clips: Challenge `ual2/Idle_Rail_Call` (a shout); Rending Thrust, a
segment of `ual2/Sword_Dash`.

### 4.2 Bow (`bow`) · done

Sustained physical ranged and mobility. Attacks as in abilities.md §2.3: the quick shot (97.3 DPS) and the draw
(125.6-131.7 DPS).

| Ability (`id`) | Branch | Cast/active/recovery | Cooldown | Effect |
|---|---|---|---|---|
| `bow_volley` Volley | Base | 0.3 / 1 tick / 0.4 | 10 s | 3 arrows at ±7°, 45 m/s, 55 piercing each |
| `bow_slowing_shot` Slowing Arrow | Base | 0.35 / 1 tick / 0.3 | 12 s | 55 m/s, 60 piercing, `slowed` ×0.6 for 3 s |
| `bow_evasive_shot` Evasive Shot | Base | 0.3 with a 4 m backward dash / 1 tick / 0.25 | 14 s | Fires on commitment, 50 m/s, 60 piercing |
| `bow_piercing_shot` Piercing Arrow | Marksman | 0.5 / 1 tick / 0.3 | 16 s | 70 m/s, 140 piercing, goes through up to 3 enemies (`pierce_count`) |
| `bow_poison_arrow` Poison Arrow | Tracker | 0.35 / 1 tick / 0.3 | 14 s | 55 m/s, 50 piercing and `poisoned` (20 per second for 5 s) |

**Variants: none.** The tree's upgrades (wounding poison, longer slow) are server fields. Reserve: `bow_arrow_rain`
(it would repeat the Hunter's ultimate), `bow_trackers_stride`.

Animation: the bow needs ART-41 for real (draw, hold, release). Without paying for UAL2 Source the route is the KayKit
Free trial (§8.4) or own clips; until then, today's segments.

### 4.3 Hatchet (`hatchet`) · phase 6 · first new weapon

Melee pressure: fast combo, throws the axe at mid range, goes berserk. One hand, no shield. It is the **template** for the
next weapons (it replaces the war hammer in that role): it needs no new clip, so it validates the whole path (data,
model, clips, icons, band, captures) with a real weapon.

| Attack | Wind-up / active / recovery | Ticks | Damage | Other |
|---|---|---|---|---|
| Light 1 | 0.18 / 0.10 / 0.27 | 33 | 85 slashing | combo window 0.15; dodge from 0.36 |
| Light 2 | 0.16 / 0.10 / 0.27 | 32 | 85 | |
| Light 3 | 0.22 / 0.10 / 0.40 | 43 | 130 | stagger 0.25 s |
| **Combo** | | **108 (1.80 s)** | **300** | **166.7 DPS** |
| Heavy | charge 0.30-1.0; 0.35 / 0.12 / 0.50 after release | 76-118 | 160 → 256 (×1.6) | 150 stamina, stagger 0.4, hyper armor; **126.3-130.2 DPS** |

Shape 2.4 m, 90°. Advance 1.5 m/s, movement ×0.3. Block 100°, mitigation 0.6, 1.2 stamina per point.

| Ability (`id`) | Branch | Cast/active/recovery | Cooldown | Effect |
|---|---|---|---|---|
| `hatchet_throw` Throwing Axe | Base | 0.30 / 1 tick / 0.30 | 10 s | Projectile `thrown_axe` 35 m/s, gravity 9, radius 0.12, life 1.0 s (≈ 30 m): 110 slashing |
| `hatchet_feral_rush` Feral Rush | Base | 0.10 / 0.35 with 5 m / 0.30 | 14 s | 2.4 m, 100°: 100 slashing, once per target |
| `hatchet_berserk` Berserk | Base | 0.20 / 0.1 / 0.2 | 24 s | You: `empowered` +20 % and `hasted` ×1.15 for 6 s |
| `hatchet_bloodthirst` Bloodthirst | Berserker | 0.15 / 0.1 / 0.2 | 30 s | You: `lifesteal` 25 % for 6 s |
| `hatchet_rending_throw` Rending Throw | Headhunter | 0.30 / 1 tick / 0.30 | 14 s | Like the throw: 80 slashing, `bleed` and `wounded` |

**Variants: none** (the `unstoppable` of the Berserker upgrade and the second `bleed` charge of the Headhunter are server
fields). Abilities on cooldown (base kit): +26.4 DPS (16 %). Burst in 3 s: 456. No hard control. Reserve:
`hatchet_axe_storm`, `hatchet_backhand`.

Clips: lights `ual2/Sword_Regular_A/B/C` (the sword's), heavy a segment of `ual2/Sword_Heavy_Combo`, throw
`ual2/OverhandThrow`, rush `ual2/Sword_Dash`, berserk `ual2/Idle_Rail_Call`. Stance: right arm of `ual1/Sword_Idle`, left
arm free of `ual1/Idle_Loop` (`ArmedStanceModifier` without a shield). Model: `tools/blender/build_hatchet.py` with realm
variants (§8.4).

### 4.4 Life staff (`life_staff`) · phase 6 · CMB-33

Healer and support. The light orb heals the first ally or hurts the first enemy; the abilities are areas and projectiles
that heal. Concentration (FOC) scales damage and healing.

| Attack | Phases | Ticks | Effect | Pace |
|---|---|---|---|---|
| Light: Light Orb | 0.2 / 1 tick / 0.4 | 37 (0.617 s) | Projectile 40 m/s, radius 0.2, 1.0 s; `ANY`: heals 45 an ally or deals 40 light to an enemy | 73.0 HPS or 64.9 DPS |
| Heavy: Greater Orb | charge 0.5-1.2; 0.05 / 1 tick / 0.35 | 55-97 | Heals 90 → 180 or deals 70 → 140; 100 mana | 98.2-111.3 HPS |

| Ability (`id`) | Branch | Cast/active/recovery | Cooldown | Mana | Effect |
|---|---|---|---|---|---|
| `life_sacred_ground` Sacred Ground | Base | 0.5 (interruptible) / 0.1 / 0.3 | 18 s | 300 | Area at the aimed point (≤ 20 m; at your feet if no ground): 4 m, 8 s, heals 35 every 1 s, max 6 |
| `life_dawns_embrace` Dawn's Embrace | Base | 0.5 (interruptible) / 1 tick / 0.3 | 10 s | 220 | Allies-only projectile, 80 m/s, radius 0.4: heals 200 and removes one harmful effect |
| `life_radiance` Radiance | Base | 0.35 / 0.1 / 0.3 | 12 s | 200 | Allies within 6 m (max 5): heals 90 |
| `life_aegis` Aegis | Dawn | 0.35 / 1 tick / 0.3 | 16 s | 180 | Allies-only projectile, 60 m/s, radius 0.4: heals 80 and `fortified` 20 % for 6 s |
| `life_dawns_judgment` Dawn's Judgment | Judgment | 0.4 / 0.1 / 0.3 | 16 s | 220 | Aimed area (≤ 20 m), delay 0.5 s, 3 m: 110 light and `weakened` −15 % for 5 s, max 6 |

**Variants: none** (the longer and wider Sacred Ground, the root of Judgment are area and effect fields, M nodes).
Sustained healing on one ally with the strongest legal triple (Embrace, Sacred Ground, Radiance) and the light: 73.0 +
20.0 + 15.6 + 7.5 = **116.1 HPS** (cap 117; Aegis adds 5.0 but cannot be carried together with the three). Reserve:
`life_beacon`, `life_swiftness`.

Clips: stance `ual1/Idle_Torch_Loop` (the staff upright in the right hand) as an arm layer; light and projectiles
`ual1/Spell_Simple_Shoot`; charge `Spell_Simple_Enter` → `Spell_Simple_Idle_Loop`; ground areas `ual2/Farm_PlantSeed` (the
staff is planted); Radiance `ual1/Spell_Simple_Exit`. Model: light wood with a split-sun finial (Solmarch), a rune
(Vardheim) or an ember (Askarra).

### 4.5 Fire staff (`fire_staff`) · phase 6 · CMB-35

Area magic damage and zone control: bow-level damage when sustained and much more in area, paid with mana. Arrives right
after the first vertical slice.

| Attack | Phases | Ticks | Effect | Pace |
|---|---|---|---|---|
| Light: Firebolt | 0.2 / 1 tick / 0.35 | 34 (0.567 s) | Projectile 50 m/s, no gravity, radius 0.15, 0.8 s (40 m): 55 fire | 97.1 DPS |
| Heavy: Charged Fireball | charge 0.4-1.2; 0.05 / 1 tick / 0.35 | 49-97 | 35 → 50 m/s; 100 → 200 fire; explodes 2.0 m at 50 %, max 5; 80 mana | 122.4-123.7 DPS |

| Ability (`id`) | Branch | Cast/active/recovery | Cooldown | Mana | Effect |
|---|---|---|---|---|---|
| `fire_fireball` Fireball | Base | 0.45 / 1 tick / 0.35 | 8 s | 180 | 40 m/s; explodes 2.5 m (max 6): 160 fire direct, 50 % to the rest; `burning` |
| `fire_pillar` Pillar of Fire | Base | 0.4 / 0.1 / 0.3 | 12 s | 240 | Aimed area (≤ 25 m), delay 0.6 s, 2 m, one pulse: 200 fire, max 6 |
| `fire_flame_leap` Flame Leap | Base | 0 / 0.3 with a 7 m advance along the movement / 0.25 | 16 s | 150 | Leaves at the origin an area of 2.5 m, 4 s: 25 fire every 0.5 s, max 6 |
| `fire_dragons_breath` Dragon's Breath | Ember | 0.2 / channel ≤ 2.0 s, re-hit 0.25 / 0 | 14 s | 60/s | 7 m, 30°: 30 fire per hit (8) and `burning`; movement ×0.4 |
| `fire_incinerate` Incinerate | Pyromancer | 0.4 / 0.1 / 0.35 | 16 s | 200 | 360°, 3.5 m: 140 fire, knockback 9 m/s, max 6 |

**Variants: none** (the 75 % splash of the Pyromancer upgrade and the 9 m reach of the breath are server fields). Base
abilities on cooldown on one target: +50.4 DPS (52 %, inside the 60 % of the magic band). Burst: 470. Reserve:
`fire_cinder_rain` (renamed from "Ember Rain", which is the world event; I62), `fire_kindle`.

Clips: the life staff's; Flame Leap `ual2/NinjaJump_Start` and `NinjaJump_Land`; Incinerate `ual2/Idle_Shield_Break`
shortened (crouch and burst); the breath a sustained `Spell_Simple_Idle_Loop`.

### 4.6 Crossbow (`crossbow`) · phase 7

Burst ranged: every bolt weighs, goes through armor and reloads. Wall defense in the sieges and traps.

| Attack | Phases | Ticks | Effect | Pace |
|---|---|---|---|---|
| Light: Snap Shot | 0.15 / 1 tick / 0.85 (includes the reload) | 61 (1.017 s) | Bolt 75 m/s, gravity 3, 1.5 s (≈ 110 m): 120 piercing, `armor_penetration` 0.25 | 118.0 DPS |
| Heavy: Aimed Shot | charge 0.5-1.2; 0.05 / 1 tick / 0.85 | 85-127 | 75 → 95 m/s; 160 → 260; zoom like the bow | 112.9-122.8 DPS |

No block; movement ×0.6 while aiming.

| Ability (`id`) | Branch | Cast/active/recovery | Cooldown | Effect |
|---|---|---|---|---|
| `crossbow_heavy_bolt` Heavy Bolt | Base | 0.45 / 1 tick / 0.5 | 12 s | 90 m/s: 180 piercing, knockback 8 m/s, `armor_penetration` 0.4 |
| `crossbow_caltrops` Caltrops | Base | 0.35 / 0.1 / 0.3 | 20 s | Aimed area (≤ 12 m), 3 m, 6 s: 10 piercing every 1 s and `slowed`, max 8 |
| `crossbow_retreat_shot` Retreat Shot | Base | 0.3 with a 4 m backward dash / 1 tick / 0.3 | 14 s | 120 piercing (the bow's backward-jump pattern) |
| `crossbow_ember_bolt` Ember Bolt | Rampart | 0.45 / 1 tick / 0.4 | 16 s | 70 m/s; explodes 2.5 m (max 5): 100 fire direct, 50 % to the rest, `burning` |
| `crossbow_bear_trap` Bear Trap | Trapper | 0.4 / 0.1 / 0.3 | 15 s | Trap at your feet (springs once), 1.2 m, 30 s: `rooted` 1.5 s and 80 piercing; max 2 per owner |

**Variants: none** (the 0.8 s knockdown of the Rampart upgrade and the third trap are server fields; the knockdown needs
action 14). Base abilities on cooldown: +26.6 DPS (22.5 %). Reserve: `crossbow_steady_aim`, `crossbow_net`.

Clips: **the weapon best served by the free kit** after the hatchet: stance `ual1/Pistol_Idle_Loop`, aim
`ual1/Pistol_Aim_Up`, `Pistol_Aim_Neutral` and `Pistol_Aim_Down` blended by the pitch (the vertical aim the bow lacks),
shot `ual1/Pistol_Shoot`, reload `ual1/Pistol_Reload` (fits the 0.85 s recovery), retreat `ual2/NinjaJump_Start`,
caltrops and trap `ual2/Farm_PlantSeed`.

### 4.7 Frost gauntlet (`frost_gauntlet`) · phase 7

Magic control: slows, roots, stops arrows with a wall and escapes by sliding.

| Attack | Phases | Ticks | Effect | Pace |
|---|---|---|---|---|
| Light 1 (jab) and 2 (cross): Ice Shard | 0.15 / 1 tick / 0.30 and 0.15 / 1 tick / 0.35 | 28 + 31 = 59 (0.983 s) | Projectile 55 m/s, gravity 2, radius 0.12, 0.65 s (≈ 36 m): 45 frost each | 91.5 DPS |
| Heavy: Charged Blizzard | charge 0.4-1.0; 0.05 / 1 tick / 0.35 | 49-85 | 45 m/s; 90 → 160 frost and `chilled`; 60 mana | 110.2-112.9 DPS |

| Ability (`id`) | Branch | Cast/active/recovery | Cooldown | Mana | Effect |
|---|---|---|---|---|---|
| `frost_ice_storm` Ice Storm | Base | 0.5 / 0.1 / 0.3 | 18 s | 220 | Aimed area (≤ 25 m), 4 m, 4 s: 20 frost every 0.5 s and `slowed`, max 8 |
| `frost_ice_spikes` Ice Spikes | Base | 0.4 / 0.1 / 0.35 | 14 s | 200 | 10 m, 15° (line): 120 frost and `rooted` 1.2 s, max 6 |
| `frost_ice_glide` Ice Glide | Base | 0 / 0.5 with an 8 m advance along the movement / 0.2 | 14 s | 120 | Advance; removes slows and roots |
| `frost_glacial_burst` Glacial Burst | Glacier | 0.3 / 0.1 / 0.35 | 20 s | 200 | 360°, 5 m: 80 frost and `rooted` 1.5 s, max 6 |
| `frost_wall` Frost Wall | Blizzard | 0.5 / 0.1 / 0.3 | 24 s | 220 | Box of 6 × 3 × 0.6 m, 6 m in front, 6 s: stops enemy projectiles (the shield wall's box), no movement collision |

**Variants: none** (6 m burst and 8 s wall are area fields). Base control: root 1.2 s every 14 s × 0.5 = 0.86 s per 20 s.
Base abilities on cooldown: +17.5 DPS (19 %). Reserve: `frost_frost_armor`, `frost_shard_volley`.

Clips: lights `ual1/Punch_Jab` and `ual1/Punch_Cross` (the projectile leaves the fist), charge and areas `Spell_Simple_*`,
spikes `ual2/Farm_PlantSeed` (fist to the ground), glide `ual2/Slide_Start`, `Slide_Loop` and `Slide_Exit`, wall
`ual1/Push_Loop`.

### 4.8 War hammer (`war_hammer`) · phase 7 · CMB-40

Area control and siege: slow and blunt, knocks down and stuns, breaks doors. The first two-handed weapon (it introduces the
grip of §8.3).

| Attack | Wind-up / active / recovery | Ticks | Damage | Other |
|---|---|---|---|---|
| Light 1 | 0.40 / 0.12 / 0.48 | 60 | 150 blunt | stagger 0.3 |
| Light 2 | 0.45 / 0.14 / 0.61 | 72 | 190 | stagger 0.5 |
| **Combo** | | **132 (2.2 s)** | **340** | **154.5 DPS** |
| Heavy | charge 0.5-1.5; 0.5 / 0.15 / 0.7 | 111-171 | 260 → 442 (×1.7) | 200 stamina, hyper armor, stagger 0.7, knockback 6; **140.5-155.1 DPS** |

Shape 2.8 m, 110°. Block 110°, 0.7, 1.0 per point.

| Ability (`id`) | Branch | Cast/active/recovery | Cooldown | Effect |
|---|---|---|---|---|
| `hammer_shockwave` Shockwave | Base | 0.55 / 0.1 / 0.5 | 20 s | 360°, 4 m: 90 blunt and stun 0.8 s, max 6 |
| `hammer_wrecking_blow` Wrecking Blow | Base | 0.6 / 0.12 / 0.55 | 14 s | 2.8 m, 80°: 200 blunt, knockdown 1.0 s, ×2.0 against structures |
| `hammer_leaping_slam` Leaping Slam | Base | 0.5 with 6 m / 0.1 / 0.5 | 18 s | On landing, 360°, 3 m: 110 blunt and `slowed`, max 6 |
| `hammer_relentless` Relentless | Colossus | 0.2 / 0.1 / 0.2 | 30 s | You: `unstoppable` 4 s and `fortified` 15 % for 4 s |
| `hammer_armor_breaker` Armor Breaker | Wallbreaker | 0.35 / 0.1 / 0.45 | 14 s | 2.8 m, 60°: 150, unblockable, `vulnerable` +10 % for 5 s |

**Variants: none** (×3.0 against structures and radius 5 m are server and area fields). Base control: 0.8 + 1.43 = 2.23 s
per 20 s. Burst: 440. Reserve: `hammer_clear_out`, `hammer_ground_rupture`.

Clips: top-down strikes `ual2/TreeChopping_Loop` (one cycle split into wind-up, strike and recovery), sweep
`ual2/Farm_Harvest`, slashes of `ual2/Sword_Heavy_Combo` with IK, jump `ual2/NinjaJump_*`, relentless `Idle_Rail_Call`;
two-handed stance with `ual2/Walk_Carry_Loop` as an arm layer while walking.

### 4.9 Greatsword (`greatsword`) · phase 7 · CMB-32

Area melee damage: wide slashes, a charge, a whirlwind. The weapon with the most DPS and the one that defends itself the
least.

| Attack | Wind-up / active / recovery | Ticks | Damage | Other |
|---|---|---|---|---|
| Light 1 | 0.28 / 0.12 / 0.38 | 47 | 130 slashing | |
| Light 2 | 0.26 / 0.12 / 0.38 | 46 | 130 | |
| Light 3 | 0.36 / 0.14 / 0.55 | 63 | 200 | stagger 0.4, hyper armor |
| **Combo** | | **156 (2.6 s)** | **460** | **176.9 DPS** |
| Heavy | charge 0.4-1.4; 0.45 / 0.15 / 0.6 | 96-156 | 220 → 396 (×1.8) | 180 stamina, stagger 0.6, knockback 5, hyper armor; **137.5-152.3 DPS** |

Shape 3.0 m, 140°. Block 120°, 0.7, 1.0 per point.

| Ability (`id`) | Branch | Cast/active/recovery | Cooldown | Effect |
|---|---|---|---|---|
| `greatsword_whirlwind` Whirlwind | Base | 0 / channel ≤ 1.4 s, re-hit 0.35 / 0 | 16 s | 360°, 3 m: 70 slashing per hit (4); movement ×0.5 |
| `greatsword_charge` Charge | Base | 0.1 / 0.45 with 7 m / 0.35 | 16 s | 2.6 m, 120°: 90 and stagger 0.5; hyper armor |
| `greatsword_cleaving_slash` Cleaving Slash | Base | 0.45 / 0.12 / 0.5 | 12 s | 3.4 m, 160°: 180 and `vulnerable` +10 % for 5 s |
| `greatsword_seismic_strike` Seismic Strike | Bladesmaster | 0.5 / 0.1 / 0.5 | 18 s | 360°, 4 m: 100 blunt and `slowed`, max 6 |
| `greatsword_execution` Execution | Executioner | 0.6 / 0.12 / 0.55 | 20 s | 3 m, 60°: 220; ×1.5 if the target is below 35 % (`low_health_bonus`) |

**Variants (1, changes two predicted fields)**: `greatsword_whirlwind_2` (Bladesmaster, row 4): the channel cap
`active_s` 1.4 → 1.75 s (5 hits instead of 4) and `move_speed_scale` 0.5 → 0.7. The 50 % threshold of the Executioner
upgrade is a server field (M node). Base abilities on cooldown: +38.1 DPS (21.5 %). Burst: 460. Reserve:
`greatsword_unstoppable`, `greatsword_blade_guard`.

Clips: slashes `ual2/Sword_Heavy_Combo` segmented with the left hand on the grip by IK, cleave `ual2/TreeChopping_Loop`, charge
`ual2/Sword_Dash`, whirlwind a held slash with a procedural hip turn.

### 4.10 Spear (`spear`) · phase 8 · CMB-42

Mid-range control: long and narrow reach, knocks down, pulls, stops charges.

| Attack | Wind-up / active / recovery | Ticks | Damage | Other |
|---|---|---|---|---|
| Light 1 and 2 | 0.20 / 0.08 / 0.30 | 35 + 35 | 85 piercing each | |
| Light 3 | 0.30 / 0.10 / 0.45 | 51 | 125 | stagger 0.3 |
| **Combo** | | **121 (2.02 s)** | **295** | **146.3 DPS** |
| Heavy | charge 0.35-1.1; 0.35 / 0.12 / 0.5 | 79-124 | 170 → 272 (×1.6) | 150 stamina, stagger 0.5, knockback 6; **129.1-131.6 DPS** |

Shape 3.6 m, 35°, inner 0.4 m. Block 100°, 0.6, 1.2 per point.

| Ability (`id`) | Branch | Cast/active/recovery | Cooldown | Effect |
|---|---|---|---|---|
| `spear_sweep` Sweep | Base | 0.3 / 0.1 / 0.4 | 14 s | 360°, 3.2 m: 70 slashing and knockdown 1.0 s, max 6 |
| `spear_vault` Vault | Base | 0.5 with 8 m / 0.1 / 0.4 | 18 s | On landing, 360°, 2 m: 60 and `slowed` |
| `spear_javelin` Javelin | Base | 0.4 / 1 tick / 0.35 | 14 s | 40 m/s, gravity 9, 1.2 s: 120 piercing and `rooted` 1.0 s |
| `spear_lance_charge` Lance Charge | Phalanx | 0.15 / 0.4 with 6 m / 0.4 | 18 s | 2 m, 60°: 110 and knockdown 0.8 s, once per target |
| `spear_hook` Hook | Dragon | 0.3 / 0.1 / 0.4 | 16 s | 5 m, 25°: 60 and pulls at −10 m/s (stops at 1.5 m) |

**Variants: none** (the root on the hook and the projectile box of the bristle are server fields). Base control: 1.43 + 0.71 =
2.14 s per 20 s. Reserve: `spear_impale`, `spear_bristle`. Clips: the worst-served weapon. Thrusts are either OWN clips
(§8.4) or segments of `ual1/Push_Loop` (both arms push forward) with IK to the shaft; sweep `ual2/Farm_Harvest`, javelin
`ual2/OverhandThrow`, vault `ual2/NinjaJump_*`, lance charge `ual2/Sword_Dash`. That is why it is the last of the launch.

### 4.11 Twin daggers (`twin_daggers`) · after launch

Assassin: a four-hit combo and a back crit of ×1.8 (`WeaponDefinition.backstab_multiplier`; every other weapon stays at
×1.5, combat.md §4.4). Lights 1-3: 0.14 / 0.08 / 0.20 (25 ticks), 55 slashing; light 4: 0.18 / 0.08 / 0.34 (36), 90 →
111-tick combo (1.85 s), 255 → **137.8 DPS from the front, 248 from behind**. Shape 2.0 m, 80°. Base: `daggers_shadowstep` (6 m
dash), `daggers_eviscerate` (2 m, 60°: 120 and 2 `bleed` charges), `daggers_fan_of_knives` (3 knives at ±8°, 40 each).
Branches and the rest of the five actives are designed when it enters its phase. It needs the left hand armed (a second
accessory in `WeaponVisualDefinition`).

### 4.12 Great axe (`great_axe`) · after launch

Bruiser with a pull: light 1 0.32 / 0.12 / 0.46 (54 ticks), 150; light 2 0.38 / 0.14 / 0.58 (66), 210 → 120 ticks (2.0 s),
360 → **180 DPS**. Base: `great_axe_reap` (360°, 4 m, pulls at −8 m/s), `great_axe_charge`, `great_axe_maelstrom` (spin
with re-hit); a branch passive with `lifesteal`. It reuses the hammer's clips and grip. Its branches and the rest of the
five actives are designed when it enters its phase.

---

## 5. Data

### 5.1 Folders and resources

```
data/combat/<family>/<family>.tres             WeaponDefinition
data/combat/<family>/<family>_light_<n>.tres   AttackDefinition (and _heavy)
data/combat/<family>/abilities/<id>.tres       AbilityDefinition (base, branch and _2 variants)
data/combat/<family>/shapes/*.tres             HitShape
data/combat/shared/status/*.tres               StatusEffectDefinition (common to every weapon)
data/combat/shared/projectiles/*.tres          ProjectileDefinition
data/combat/shared/areas/*.tres                GroundAreaDefinition (new)
data/combat/specializations/<spec>.tres        ultimates (created by advancement.md)
data/combat/balance/weapon_bands.tres          WeaponBalanceBands (the table of §3.1, new)
data/animation/<family>_clips.tres             CombatClipSet (client; exists)
data/visual/weapons/<family>.tres              WeaponVisualDefinition (client, new)
data/items/weapon/<item>.tres                  ItemDefinition with ref_id = family (items.md)
data/progression/talents/<family>.tres         mastery tree (advancement.md)
```

`CombatCatalog` does not enter subfolders today (abilities.md §2.2): it walks them from now on, and the ids keep going by
name in alphabetical order in separate spaces; statuses stay in u8 (about 25). With 12 weapons that is some 230
`.tres`, which are not reviewable in one folder.

### 5.2 New fields (P = predicted, enters the `prediction_hash`; S = server only)

`WeaponDefinition`:

| Field | Type | P/S | What it is |
|---|---|---|---|
| `roles` | bitmask | tools | `TANK`, `MELEE`, `RANGED`, `MAGIC`, `HEALER`, `SUPPORT`, `CONTROL` |
| `tags` | bitmask | S | `melee`, `ranged`, `magic`, `shield`, `one_handed`, `two_handed`, `staff`, `polearm`, `elemental`, `healing`, `thrown`, `siege` (§2.4) |
| `balance_band` | StringName | tools | the row of `weapon_bands.tres` |
| `uses_mana` | bool | P | its heavies and abilities spend mana |
| `primary_attribute`, `secondary_attribute`, `secondary_weight` | int, int, float | S | §2.3 (−1 = no secondary; 0.5) |
| `ability_pool` | `Array[AbilityDefinition]` | P | the five actives and their variants (max 15; the index is what travels) |
| `default_picks` | `PackedInt32Array` | P | the 3 pool indices of the default bar (the base abilities) |
| `abilities` | (exists) | P | stays for NPCs and templates; for players the picks replace it |
| `block_magic_mitigation` | float | S | 0.5 shield, 0.3 the rest |
| `backstab_multiplier` | float | S | 1.5; daggers 1.8 |

`AttackDefinition` and `AbilityDefinition` (both):

| Field | P/S | What it is |
|---|---|---|
| `display_name`, `description` | client | English in the `.tres`, contexts `ability` and `ability_desc`; the description with parameters from the data ("{distance} m") |
| `mana_cost` (and in abilities `mana_per_s`, `mana_restore`) | P | §3.3 |
| `target_filter`, `max_targets`, `base_heal`, `cleanse` | S | §3.6; `cleanse` = `NONE`, `MOVEMENT`, `ONE_HARMFUL`, `ALL_HARMFUL` |
| `target_statuses`, `ally_statuses`, `self_statuses` | S | lists (today one); with optional `status_duration_s` and `status_magnitude` per application, so statuses are not duplicated |
| `hit_interval_s` | S | re-hit in channels and long actives (today, each target once per action) |
| `knockdown_s` | S | knockdown (§6.1) |
| `low_health_bonus`, `low_health_threshold` | S | execution |
| `armor_penetration` | S | fraction of armor it ignores |
| `structure_damage_scale` | S | ×N against structures |
| `taunt_s` | S | fixes the NPCs' target |
| `ground_area`, `placement`, `placement_range_m` | S | the area it leaves: `SELF`, `AIM_POINT` (canonical ray, abilities.md §4.4), `ORIGIN` |
| `block_angle_deg`, `block_stamina_per_damage` | S | per ability (today they are global in `CombatRules`) |
| `upgrade_of` | tools and client | the variant shares clip and icon with its base |
| `ai_role` | S and tools | hint for the bot (§7.3); replaces the deduction of `BotBrain.kit_role` when given |

`ProjectileDefinition`: `pierce_count` (S), `hits_allies` (S), `impact_radius_m`, `impact_fraction`, `impact_max_targets`
(S) and `impact_area: GroundAreaDefinition` (S). The ballistics stay P.

### 5.3 `GroundAreaDefinition` (`scripts/shared/combat/ground_area_definition.gd`)

```gdscript
class_name GroundAreaDefinition extends Resource
@export var id: StringName
enum Shape { CIRCLE, BOX }
@export var shape: int = Shape.CIRCLE
@export var radius_m: float = 3.0; @export var half_extents: Vector3 = Vector3.ZERO   # BOX
@export var height_m: float = 2.5
@export var delay_s: float = 0.0           # warning before the first pulse (drawn by the client)
@export var duration_s: float = 4.0        # an exact multiple of pulse_every_s in ticks
@export var pulse_every_s: float = 0.5
@export var target_filter: int = 0         # ENEMIES, ALLIES, ...
@export var pulse_damage: int = 0; @export var damage_type: int = 0; @export var pulse_heal: int = 0
@export var statuses: Array[StatusEffectDefinition] = []
@export var max_targets_per_pulse: int = 6
@export var trigger_once: bool = false     # trap: the first enemy that enters fires it
@export var blocks_projectiles: bool = false   # frost wall: stops enemy projectiles
@export var max_per_owner: int = 2
```

All S: the areas do not change the simulation.

### 5.4 `CombatRules`

New: `mana_max`, `mana_regen_per_tick`, `mana_regen_delay_s` (P); `self_heal_scale` 0.6, `heal_threat_scale` 0.5,
`knockdown_getup_s` 0.6, `max_areas_per_zone` 48, `area_max_targets_cap` 8, `structure_frost_multiplier` 0.3,
`structure_radiant_multiplier` 0.2, `ultimate_unlock_level` 10, `ultimate_cooldown_s` 150 and `ultimate_max_targets` 10 (S);
`armor_reference` (S, the physical reference armor, §3.5 in combat.md).

### 5.5 CSV round trip

The `.tres` files are the only source of the combat data (W18). `tools/combat/combat_table.gd --export` writes
`build/combat/combat_table.csv` (one row per attack and ability, numeric fields only) and `--apply <csv>` writes the
values back into the `.tres`. The CSV serves to balance in a spreadsheet and is not versioned as a source; a test exports,
applies and checks that the repository does not change. The generated numeric tables of the other systems (curve, loot,
affixes) are CSV that a deterministic generator turns into `.tres` with a "generated" header ([advancement.md](advancement.md)); the
combat data is the structured exception (I64).

### 5.6 Localization

Names and descriptions live in the `.tres` in English (`display_name`, `description`), with the contexts `ability` and
`ability_desc` (localization.md), and the Spanish in `es.po`. A description carries parameters (`{damage}`, `{cooldown}`,
`{radius}`) that the client fills in from the converted data, so a change of figures never leaves an old description.
Never a sentence with a placeholder noun.

### 5.7 Validators and the generated sheet

In `CombatTables.errors` (the validation of abilities.md §2.2 exists) and a new `tests/test_weapon_lint.gd`:

| # | Rule |
|---|---|
| V1 | Every weapon: 1-4 lights, one heavy, **5 actives** in `ability_pool` (3 marked base), at most 15 with variants (and at most 2 variants); every ability in a single set (or in the consumables or in a specialization); every `_2` variant points with `upgrade_of` to an ability of the same set and **differs from its base in at least one predicted field** |
| V2 | `uses_mana` ⇔ all its heavies and abilities have `mana_cost > 0` or `mana_per_s > 0`; the others, 0 |
| V3 | Cooldowns ≥ 6 s (and the `REARM_TICKS` rule); ultimates ≥ 120 s |
| V4 | DPS of combo and heavy computed from the ticks inside its band (§3.1, `weapon_bands.tres`) |
| V5 | Base abilities on cooldown ≤ 25 % (physical) or 60 % (magic) of the light, for the default triple and for the strongest legal triple |
| V6 | Base control ≤ 2.5 s per 20 s with the weights of §3.1 |
| V7 | Burst computed in 3 s ≤ 500 |
| V8 | Sustained healing computed ≤ 117 HPS (the light plus the strongest legal triple) |
| V9 | Areas of weapon abilities: radius ≤ 6 m, targets ≤ 8; areas of ultimates: radius ≤ 10 m, targets ≤ `ultimate_max_targets` (10); both: duration a multiple of the pulse, hit ≥ 150 with a warning (cast ≥ 0.4 s or delay ≥ 0.5 s) |
| V10 | `display_name` and `description` not empty; the description's parameters exist in the data |
| V11 (client) | The weapon's `CombatClipSet` has an entry for every attack and ability (or its `upgrade_of`); its `WeaponVisualDefinition` and the icon of each ability exist |
| V12 | The passives of a tree add at most **8 %** per tree, and every weapon of a phase is favored by a specialization with ≥ 40 % of each rank general (checked by [advancement.md](advancement.md)'s validator with these figures) |

V4 to V8 are computed from the data (fast, in every test). `tools/combat_balance.gd --weapons=all` measures them with the
server and no network, and `test_combat_balance` demands that what is measured equals what is computed, as today with
the sword and the bow (combat.md §12.8).

**Generated weapon sheet.** `tools/combat/weapon_sheet.gd` writes `build/combat/weapon_sheet.md` with the tables of §4
computed from the `.tres` (ticks, DPS, budgets). From then on, the figures of this document are only the starting
ones; the current ones come out of the sheet.

---

## 6. State machine and protocol

### 6.1 State and machine

`CombatState` v6 adds **13 B** to the 111 B `PlayerState` of v5 (abilities.md §3.1), which becomes **124 B**:

| Offset | Type | Field | What it is |
|---|---|---|---|
| 111 | u8 × 3 | `ability_picks` | one nibble per slot: pool index 1-15 of that weapon (0 = empty); nibbles 0-2 are the active weapon, 3-5 the other one; the swap exchanges them with `ability_ready` |
| 114 | u32 | `ultimate_ready` | first tick at which the ultimate is usable again (it survives respawn and is stored as the timer `ability:<id>`) |
| 118 | u16 | `mana` | bits 0-9 mana (0-1000; `mana_max` is validated ≤ 1023), bits 10-11 `load_class` (0 light, 1 medium, 2 heavy), bit 12 reserved |
| 120 | u32 | `mana_regen_tick` | first tick at which mana regenerates again (as `stamina_regen_tick`) |

Changes to existing fields:

- `action`: **14 KNOCKED** (knockdown), imposed by the server as the stun is, no dodge, with `knockdown_getup_s` at the end
  (15 stays free). `action_id` is an ability in ABILITY, including the ultimate.
- `combat_flags` bit 7 `ULTIMATE_HELD` (the ULTIMATE button was pressed on the previous tick).
- The slot of an ability (`AbilityTicks.slot`) is no longer fixed: it becomes the *default* slot; the slot in use comes
  from `ability_picks`.
- `PlayerInput` bit 13 `ULTIMATE` (key F, rebindable); `VALID_BUTTONS = (1 << 14) − 1`, bit 14 reserved and 15 stays
  `SUBSTITUTED`. The priority is after ABILITY_3.
- The ultimate's **id** is not in the state: like the loadout, it is configuration applied out of combat (LOADOUT v2 and
  the build state), and the client keeps the previous configuration to replay old ticks.
- Attack: **pull** is a negative `knockback_speed` toward the attacker, stopping at 1.5 m.
- Mana: spent at commitment (or per second in a channel), regenerated 1 per tick once `mana_regen_tick` is reached; a
  heavy or ability without enough mana does not start (the button blinks).

*Note (annotated decision).* The integrated design asked to put the load class in two bits of `combat_flags2`, but that
byte is full today (active slot, six held-button bits, no-cooldowns command): the two bits live in the free top bits of the
`mana` u16 instead, with no change in size. The `mana` field stays below 1024.

### 6.2 Messages

| Message | Change |
|---|---|
| `PlayerState` | 124 B (v6 of `CombatState`); the snapshot header with own state and extra block is 13 + 124 + 9 + 1 = **147 B** and ⌊(1200 − 149) / 21⌋ = **50 records** (the same as v5) |
| LOADOUT (ENTITY_EVENT 9) **v2** | `u8 template_id`, `u16 weapon_1`, `u16 weapon_2`, `u8 charges`, `u8[3] ability_picks` (same nibbles as the state), `u16 ultimate_id`: 11 B of data, **20 B** in total. To the owner with everything; to whoever sees the player, picks and ultimate at 0 and `charges` 0 (picks are private; the enemy learns the ultimate when it is cast). Sent again when the picks change (out of combat only) |
| Action byte | ABILITY with bits 4-5 = 3 (free in ABILITY) is the **ultimate**, and its phase (0 cast, 1 active or channel, 2 recovery) goes in bits 6-7 |
| Entity kind **AREA** | See §6.5 and networking.md |
| Build messages | The picks are chosen with BUILD_REQUEST `SET_ABILITIES` ([advancement.md](advancement.md)); the server validates against what is unlocked |

### 6.3 Per-tick rules added

1. The ultimate button follows the edge rules of the other three, with its own held bit; it is rejected while its
   `ultimate_ready` is in the future or the character has no specialization (a notice).
2. A swap moves the picks and the ready ticks of both weapons together.
3. Mana regeneration runs in the stamina step; it does not run during a channel that spends mana.
4. A slot whose pick is 0 (empty) never starts an ability.

### 6.4 What the server enforces

On spawn and on every loadout change: the weapons, the picks (each one inside the pool of its weapon and unlocked by
level and by the row-2 node; otherwise replaced by the default), the ultimate (the character's specialization) and the load
class from the equipment. In camp, the picks are enforced and the mana is refilled with the charges. A pick sent by a
client that the character has not unlocked counts a warning and is replaced by the default pick.

### 6.5 Entity kind AREA

Networking.md has 4 as STRUCTURE since protocol 3, so the area takes the next free kind, **5 AREA** (annotated against the
integrated design, which wrote 4). SPAWN (reliable, channel 3): owner, `area_def_id`, source, position, yaw, `spawn_tick`;
DESPAWN (reliable) with reason 6 expired or 7 removed (2 and 3 are death and handoff); **no snapshot records**, like the projectiles. The client draws the
decal with the real radius, ally or enemy color, and the warning that fills during `delay_s`. Format and size:
[networking.md §5.8](networking.md#58-phases-6-8-content-additions).

---

## 7. Server

### 7.1 Tick order

Completes the order of [abilities.md §4.1](abilities.md#41-tick-order-completes-fortressmd-17): areas are created in step 3
(the commit of abilities and the impact of projectiles) and pulse in step 6 together with the status pulses; mana
regenerates with the stamina in the simulation step; healing is resolved with the damage of the same tick.

### 7.2 Systems

| System | What it does | Files |
|---|---|---|
| Target filter and healing | `target_filter` in the candidates (same rewind and line of sight), `max_targets`, HEAL, self-heal ×0.6, `HEALING_DOWN`, nothing to the knocked down | `combat_resolver.gd`, `combat_director.gd`, `downed_system.gd` |
| New statuses | the six new kinds in `DamageFormula` (`FORTIFY`, `VULNERABLE`, `WEAKEN` as factors in a fixed order) and in the resolver (`UNSTOPPABLE`, `LIFESTEAL`), several applications per hit, magnitude and duration per application, cleansing | `status_system.gd`, `damage_formula.gd`, `combat_resolver.gd` |
| Re-hit | each target at most once per `hit_interval_s` in the same action | `combat_resolver.gd`, `combatant.gd` |
| Areas (`AreaSystem`, new) | creates areas, pulses with statuses, traps, boxes that stop projectiles (`ProjectileSystem` queries them like the shield wall's box), caps per owner and per zone, cleanup when the owner dies or leaves | `scripts/server/area_system.gd` (new; in the section the split of `zone_server.gd` provides), `projectile_system.gd` |
| Projectiles v2 | pierce, touch allies, explode on impact, area on impact | `projectile_system.gd` |
| Threat and taunt | healing adds threat; `taunt_s` fixes the target | `ai/hfsm_brain.gd` |
| Picks | validates requested picks against what is unlocked | `combat_director.gd`, `progress/…` |
| Ultimate | persistent cooldown with the timer `ability:<id>` (progression.md §8 reserves it; `test_player_progress` fails today if one appears, and changes to the rule for ultimates) | `progress/progress_service.gd`, `player_progress.gd` |
| Structures | `structure_damage_scale` and the new multipliers against `StructureTarget` | `combat_resolver.gd`, `war/…` |
| Bots | `ai_role` and new roles in `BotBrain` (`HEAL`, `AREA`, `BUFF`, `ALLY_BUFF`, `TRAP`, `CHANNEL`): the combat bot uses any weapon, which is what the balance measures | `scripts/shared/bot_brain.gd`, `tools/combat_balance.gd` |

### 7.3 Interest in PvE zones

The PvE zones add NPCs and areas to what a client receives. Areas and projectiles are reliable events delivered to whoever
has the owner as relevant; the interest policy of the PvE zones is in [networking.md §5.8](networking.md#58-phases-6-8-content-additions).

---

## 8. Client and content tools

### 8.1 Systems

| System | What it does | Files |
|---|---|---|
| Weapons by data | `WeaponProps` and `SwordModel` read `WeaponVisualDefinition` (model per realm, grips, second accessory, trail) | `weapon_props.gd`, `sword_model.gd` → `weapon_model.gd`, `sword_trail.gd` |
| Stance per weapon | `ArmedStanceModifier` takes the rest pose and arm layer from the weapon (today fixed to shield and sword) | `armed_stance_modifier.gd`, `character_animator.gd` |
| Areas and warnings | `AreaWorld` (decal on the ground with the real radius, ally or enemy color, a warning that fills during `delay_s`) and the placement reticle for `AIM_POINT` | `scripts/client/area_world.gd` (new), `crosshair.gd` |
| HUD | mana bar in the slot reserved since phase 4 (abilities.md §0), mana cost on the bar, the F slot of the ultimate, healing numbers | `action_bar.gd`, `hud.gd`, `damage_numbers.gd` |
| VFX | per archetype and element (fire, frost, light) with the ART-09 pipeline (`tools/vfx/`) | `scenes/vfx/`, `tools/vfx/` |
| Icons | the ART-12 route (SVG from game-icons.net, CC BY 3.0, credited) for about 60 abilities | `tools/ui/`, `CombatIcons` |
| Clip planner | `CombatClipPlanner` looks up by ability, and a variant falls back to its `upgrade_of` | `combat_clip_planner.gd` |

### 8.2 Prediction

The client predicts the picks, the ultimate and the mana like the stamina: a rejection reverts the slot, the mana shown
is the predicted one and the ultimate's cooldown comes back from the state. Healing and area results appear on
confirmation (HEAL and HIT), never predicted.

### 8.3 Two-handed grip and procedural turn

IK of the left hand to the weapon's grip point (the `SkeletonModifier3D` IK modifiers; `TwoBoneIK3D` since Godot 4.6, to be
checked in 4.7.2), after `CombatPoseModifier`; it turns the one-hand slashes of UAL2 into two-hand slashes. A hip rotation
around Y during a channel (whirlwinds) is laid on a held slash.

### 8.4 Animation sources

All free (W19), in this order of preference:

1. The clips of UAL1 and UAL2 Standard, in segments (a cycle split into wind-up, strike and recovery) and with per-weapon
   stance layers. They serve the hatchet (the sword's clips), both staves (`Spell_Simple_*`), the crossbow (`Pistol_*` with
   the vertical aim blend), the gauntlet (`Punch_*`, `Slide_*`), and, with IK, the hammer and the greatsword.
2. **Left-hand IK** to the grip point (§8.3).
3. **An own pose-clip tool**, `tools/animation/build_pose_clips.gd`: it generates `Animation` as text `.tres`
   (`assets/animations/eldmark/`) from key poses written as data (a starting frame of a UAL clip plus rotations per bone),
   interpolated; reviewed with `tools/quality/anim_strips.gd`.
4. **KayKit Character Animations Free 1.1** (CC0): a retarget **trial** of the bow, thrust and two-handed clips to the UAL
   skeleton, as a **decision gate (ART-70)** with captures, in phase 6 with the bow. If it does not pass the user's eye,
   own clips with the tool of point 3. `assets/animations/kaykit/` holds only what is approved.

Models: one `tools/blender/build_<weapon>.py` per family with a base and three realm variants, from the sword's template
(art.md §4.9: LOD0 and LOD1, trail markers, textures in code).

### 8.5 Production order by clip availability

The weapons with all their clips come first and the ones that need new animation work last: **hatchet** (the sword's clips) →
**life staff and fire staff** (`Spell_Simple_*`) → **crossbow** (`Pistol_*`, with vertical aim) → **frost gauntlet**
(`Punch_*`, `Slide_*`) → **war hammer and greatsword** (left-hand IK over `TreeChopping_Loop` and the UAL2 slashes) →
**spear** (own thrusts or `Push_Loop`). The first vertical slice (Hondal, phase 6) takes the **hatchet and the life staff**
with the sword and the bow; the fire staff follows right after.

---

## 9. Packages and contracts

### 9.1 Packages

| Package | Contents | Depends on |
|---|---|---|
| E · Combat v6 | catalog v2 and sub-folders, validators V1-V12, `WeaponVisualDefinition`, picks and loadout, new statuses, passive system, mana, the ultimate slot, damage types | phase 4 |
| F · Allies, healing and areas | target filter, healing, `GroundAreaDefinition`, `AreaSystem`, projectiles v2, area reticle and warnings | E |
| G · Weapons of the slice | the branch abilities of sword and bow, the hatchet, the life staff, their trees, models, icons, the KayKit trial | D (progression), E, F |
| Later | fire staff (CV1+), then phase 7: knockdown and pull, crossbow, frost gauntlet, hammer (grip IK), greatsword; phase 8: spear | G |

### 9.2 Contracts

```gdscript
# scripts/shared/combat/combat_state.gd (extends): picks, ultimate, mana and load class
var ability_picks: PackedByteArray          # 3 B, 6 nibbles: active weapon [0..2], other weapon [3..5]
var ultimate_ready: int                     # tick
var mana: int                               # 0..mana_max
var mana_regen_tick: int
var load_class: int                         # 0 light, 1 medium, 2 heavy (two bits of the mana word)
const ACTION_KNOCKED: int = 14
const FLAG_ULTIMATE_HELD: int = 1 << 7      # of combat_flags

# scripts/shared/combat/ground_area_definition.gd · class_name GroundAreaDefinition extends Resource (§5.3)

# scripts/shared/combat/combat_catalog.gd (extends): walks sub-folders; ability_pool(weapon_id) ->
# PackedInt32Array (ids in pool order); default_picks(weapon_id) -> PackedInt32Array;
# ultimate(spec_id) -> AbilityTicks; area(id) -> GroundAreaTicks, area_id(name) -> int

# scripts/shared/combat/ability_rules.gd (extends): try_ultimate(c, t, input, ctx) -> bool;
# spend_mana(c, t, amount, rules); the slot of an ability = the nibble of ability_picks

# scripts/server/area_system.gd · class_name AreaSystem extends RefCounted
func create(owner: Combatant, def: GroundAreaTicks, pos: Vector3, yaw: float, tick: int) -> int
func step_pulses(tick: int) -> void         # step 6 of the tick
func blocks_segment(a: Vector3, b: Vector3, owner_realm: int) -> bool   # for ProjectileSystem
func remove_owned_by(net_id: int) -> void

# tools/combat/combat_table.gd --export | --apply <csv>; tools/combat/weapon_sheet.gd
```

`scripts/shared/` does not depend on the client or the server (`test_architecture`): the new resources and
`GroundAreaDefinition` are shared; `AreaSystem` and `AreaWorld` live each on its side.

### 9.3 Tests (each < 30 s)

`test_combat_catalog` (same ids by name; the hash changes only by the new P fields), `test_weapon_lint` (V1-V12),
`test_ability_loadout` (the pick is predicted and reconciled, swap with Q, the server rejects a locked slot),
`test_status_effects` extended, `test_ally_targets`, `test_mana` (prediction, reconciliation, the 1.5 s wait),
`test_healing` (ally yes, enemy no, cap, ×0.6, knocked-down no, threat), `test_ground_areas` (exact pulses, caps, trap,
box against arrows, cleanup when the owner leaves), `test_projectiles` extended, `test_hatchet` against the dummy with the
measured band, `test_damage_formula` with types, `test_knockdown`, 0 prediction corrections with picks, mana and ultimate.

---

## 10. Dependencies with other documents

| Document | What this needs | What it gives |
|---|---|---|
| [advancement.md](advancement.md) | Attribute formula and returns; mastery XP; rows, passives and reset of the trees; specializations, ranks and ultimates; normalization | Attributes per weapon (§2.3), five actives and the variants per weapon, unlock rules (W4), the 8 % cap (V12), bands valid at any power |
| [items.md](items.md) | Power per item level (§3.9), weapon items by tier up to 60, rarities and affixes ("% damage of the family"), load class and the dodge and armor numbers | Families (`ref_id`), tags, attributes |
| [npcs.md](npcs.md) | Enemies with the new weapons (archers, fire mages in the 1-10 zone), weapon masters in the capital, abilities by `ai_role`, healing threat | `ai_role`, `taunt_s`, `npc_*` weapons that reuse family abilities |
| [world.md](world.md) | Training grounds with dummies in each capital; doors and walls (GUE-10, GUE-27) for the hammer | Multipliers against structures |
| War and performance (CMB-36, TEC-34) | Candidate grid, caps per area, projectile budget | The caps of §3.1, `max_areas_per_zone`, areas without snapshot records |
| [art.md](art.md) | Models, clips, VFX, icons | Sheets with the clips of each action |
| Interface | UI-30 (abilities window with 3-of-5 picks, ultimate and variants), mana bar, area reticle | Data for the tooltips with parameters |
| [networking.md](networking.md) | Protocol version (§6.2) and the registry | The formats of §6 |

---

## 11. Production order

Each increment closes with tests and captures (the bench of `tools/quality/`, `run.py` per area and `anim_strips.gd`, strips
of 12 frames from the side, front and the game camera), archived before and after in `Eldmark-capturas`. What measures
balance leaves its `combat_balance` JSON in `build/`.

**Phase 6** (lanes E, F, G of the integrated plan)

| # | Increment | Tests | Captures |
|---|---|---|---|
| 1 | Catalog v2 with no game change: sub-folders, new fields with defaults, `standard_dodge`, damage type values, validator V1-V10, generated sheet | `test_combat_catalog`, `test_weapon_lint` | The sheet of sword and bow |
| 2 | `WeaponVisualDefinition` and `WeaponProps` by data | `test_combat_animation` | Before and after identical (sword and bow strips) |
| 3 | New statuses and support in an area around yourself | `test_status_effects` extended | Icons on the nameplate and on the own row |
| 4 | Pick 3 of 5, the ultimate slot (bit 13, key F, persistent cooldown), mana, the tonic and the branch abilities of sword and bow | `test_ability_loadout`, `test_mana` | Bar with Challenge in slot 2 and the mana bar |
| 5 | **Hatchet** (model, clips, stance without a shield, 5 actives, re-hit, bot profile) | `test_hatchet`, measured band, duels and 2 vs 2 with bots | Photos of the model per realm; strips of the combo, the throw and the rush |
| 6 | Healing to allies (orb and area around yourself) | `test_healing` | Healing numbers on an ally |
| 7 | Ground areas (server, kind AREA, client) | `test_ground_areas` | Decal and warning, ally and enemy |
| 8 | **Life staff** | balance with a healer: 2 vs 2 with one healer per side, measured HPS | Strips of the orb, Sacred Ground and Embrace |
| 9 | Projectiles v2 and the **fire staff** (right after the slice) | `test_projectiles` extended; band | Strips of the fireball (explosion) and the breath |

**Phase 7**

| # | Increment | Tests | Captures |
|---|---|---|---|
| 10 | Knockdown (action 14) and pull | `test_knockdown` (predicted knockdown, chain, unstoppable) | Knockdown strip and `LayToIdle` |
| 11 | Resistances per type with the split armor | `test_damage_formula` with types | none |
| 12 | **Crossbow** with vertical aim | band, ranges at 10, 30 and 50 m like the bow | Strips aiming up, ahead and down |
| 13 | **Frost gauntlet** | band, wall against arrows | Strips of jab, cross and glide |
| 14 | Two-handed IK and the **war hammer** | band; GUE-10 gate with 3 hammers | Left hand on the shaft in every two-handed strip |
| 15 | **Greatsword** (procedural turn) | band | Strips of the combo and the whirlwind |

**Phase 8**: 16, pose tool or KayKit for thrusts and the **spear**; 17, the bow animation (ART-41). **After launch**: twin
daggers and great axe.

Why this order: the hatchet needs no new clip and validates the full path with a real weapon; the staves are the missing
role (there is no healing but potions) and have clips (`Spell_Simple_*`); the crossbow and the gauntlet have almost all
their clips; the two-handed weapons need the IK first; the spear is the only one without clips for its basic attack.

---

## 12. Risks

| Risk | Mitigation |
|---|---|
| **Animation with free clips looks bad** (ART-44 already said it of the sword). It is the biggest risk: two hands, the spear and the bow have no clips of their own in the free kit. | Order by available clips; IK and segments before new clips; the KayKit trial in phase 6 to decide early; the user's eye on strips of every weapon before the next is made. |
| **Content volume**: 50 actives, each with data, icon, VFX, clip and test. | Archetypes that share everything but the numbers; the generated sheet and the validator replace the manual review of figures; variants without a clip of their own. |
| **Performance in Eldrun**: areas, healing pulses and more projectiles. | Caps (8 targets, 48 areas per zone, 2 per owner), areas without snapshot records, magic projectiles inside `max_projectiles_per_zone`; measure with TEC-34 and CMB-36 before opening Eldrun. |
| **Stacked healers** make a group immortal. | Cap per area, self-healing ×0.6, `wounded` on the hatchet's Rending Throw (and the spear's Impale once it enters); if the tests ask for it, healing received decreasing with the number of healers (not now). |
| **State and `simulate()`**: +13 B and more rules in the machine (already the bottleneck, abilities.md §8). | Mana and picks are cheap reads; measure `simulate()` in increments 4 and 5; the stored weapon's cooldowns to u16 if needed. |
| **Balance combinatorics**: 10 weapons, 45 pairs, bots that do not react. | Bands per weapon (not per pair), duels with bots for every new weapon, CMB-38 telemetry; no tweak against bots if the data meets the bands (combat.md §12.5). |
| **Mass control**: area knockdowns and stuns in a siege. | Control budget, at most 6 targets on control abilities, chain of immunity. |
| **Healing through walls** or an ally hiding. | Same line of sight as damage. |
| **Mana in the state**: the packed `load_class` bits share a word with mana. | A test fixes the layout; `mana_max` is validated ≤ 1023. |

---

## 13. Backlog

Ids assigned by the integrated design (the backlog itself is written elsewhere):

| Id | Item | Phase |
|---|---|---|
| CMB-43 | Weapon catalog v2: sub-folders, roles, tags, attributes, ability set, `WeaponBalanceBands` and the generated sheet | 6 |
| CMB-44 | Weapon validator (V1-V12) and `combat_balance --weapons=all` with bands | 6 |
| CMB-45 | Ability loadout: 3 of 5 per weapon, `CombatState` v6 and LOADOUT v2 | 6 |
| CMB-46 | New status kinds | 6 |
| CMB-47 | Allies and non-targeted healing (includes healable allied NPCs) | 6 |
| CMB-48 | Mana and the tonic | 6 |
| CMB-49 | Ground areas | 6 |
| CMB-50 | Projectiles v2 | 6 |
| CMB-51 | Channels with re-hit and per-ability block | 6 |
| CMB-52 | Branch abilities of sword and shield and of the bow | 6 |
| CMB-53 | Hatchet | 6 |
| CMB-33 | Life staff (rewritten) | 6 |
| CMB-35 | Fire staff (rewritten: important, phase 6) | 6 |
| CMB-54 | Ultimate slot (F) | 6 |
| CMB-55 | Passive system (with [advancement.md](advancement.md)) | 6 |
| CMB-56 | Specialization ultimates (with [advancement.md](advancement.md)) | 6 |
| CMB-57 | Damage types and physical and elemental armor | 6 |
| CMB-58 | Knockdown and pull | 7 |
| CMB-59 | Crossbow | 7 |
| CMB-60 | Frost gauntlet | 7 |
| CMB-40 | War hammer (moved to phase 7) | 7 |
| CMB-32 | Greatsword (moved to phase 7) | 7 |
| CMB-42 | Spear (moved to phase 8) | 8 |
| CMB-61 | Twin daggers | After launch |
| CMB-62 | Great axe | After launch |
| ART-65 to ART-72 | `WeaponVisualDefinition`, hatchet and life staff models, the other models, stance and grip, pose tool, KayKit trial, magic VFX and area decals, icons | 6-8 |
| UI-76, UI-77, UI-78 | Ultimate on the bar, mana bar and costs, area reticle and warnings | 6 |

---

## Appendix A. Reserve pool

The 20 abilities of the original proposal that are not among the five actives of a weapon. They stay as data for after the
launch: `ability_pool` admits 15 entries, so a reserve ability enters a weapon by adding an A node to its tree (or
replacing one), with its icon, VFX and clip. They are **not** in the catalog at launch and the validator does not count them.
Figures are the original starting values.

| Weapon | Ability (`id`) | Branch | Cast/active/recovery | Cooldown | Cost | Effect |
|---|---|---|---|---|---|---|
| Sword and shield | `sword_rally` Rally | Bulwark | 0.4 / 0.1 / 0.3 | 35 s | | Allies and you within 8 m (max 5): `fortified` 15 % for 6 s |
| | `sword_leaping_strike` Leaping Strike | Steel | 0.35 with 5 m / 0.1 / 0.4 | 18 s | | On landing, 360°, 2.5 m: 90 slashing, stagger 0.4 s |
| Bow | `bow_arrow_rain` Arrow Rain | Marksman | 0.6 / 1 tick / 0.3 | 22 s | | Area at the aimed point (≤ 35 m), delay 0.5 s, 4 m, 2.5 s, 5 pulses of 30 piercing and `slowed`, max 8 (do not enter while the Hunter's ultimate has this shape) |
| | `bow_trackers_stride` Tracker's Stride | Tracker | 0 / 0.1 / 0.1 | 20 s | | You: `hasted` ×1.2 for 4 s, removes slows and roots |
| Hatchet | `hatchet_axe_storm` Axe Storm | Berserker | 0 / channel ≤ 1.2 s, re-hit 0.30 / 0 | 18 s | | 360°, 2.5 m: 45 slashing per hit (4), movement ×0.6 |
| | `hatchet_backhand` Backhand | Headhunter | 0.15 / 0.1 / 0.3 | 12 s | | 1.8 m, 90°: 40 blunt, knockback 9 m/s, stagger 0.3 |
| Life staff | `life_beacon` Beacon | Dawn | 0.4 / 1 tick / 0.3 | 18 s | 240 | Projectile 30 m/s, gravity 6; on touching the ground leaves a 4 m area, 6 s, heals 40 every 1 s, max 6 |
| | `life_swiftness` Swiftness | Judgment | 0.3 / 0.1 / 0.3 | 24 s | 150 | Allies within 8 m (max 5): `hasted` ×1.2 for 4 s, removes slows and roots |
| Fire staff | `fire_cinder_rain` Cinder Rain | Pyromancer | 0.6 / 0.1 / 0.3 | 25 s | 300 | Aimed area (≤ 30 m), delay 0.5 s, 5 m, 4 s: 35 fire every 0.5 s, max 8 |
| | `fire_kindle` Kindle | Ember | 0.2 / 0.1 / 0.2 | 30 s | 0 | You: `empowered` +15 % for 8 s and you recover 150 mana (`mana_restore`, predicted) |
| Crossbow | `crossbow_steady_aim` Steady Aim | Rampart | 0.2 / 0.1 / 0.2 | 30 s | | You: `empowered` +20 % and `slowed_self` ×0.8 for 8 s |
| | `crossbow_net` Net Shot | Trapper | 0.3 / 1 tick / 0.3 | 18 s | | 40 m/s, no damage: `rooted` 2.0 s |
| Frost gauntlet | `frost_frost_armor` Frost Armor | Glacier | 0.25 / 0.1 / 0.2 | 30 s | 150 | You: `fortified` 25 % for 5 s and `unstoppable` 3 s |
| | `frost_shard_volley` Shard Volley | Blizzard | 0.3 / 1 tick / 0.3 | 12 s | 160 | 5 projectiles at ±12°, 50 m/s: 45 each and `chilled` |
| War hammer | `hammer_clear_out` Clear Out | Wallbreaker | 0.4 / 0.1 / 0.45 | 16 s | | 2.6 m, 180°: 80 and knockback 12 m/s, max 6 |
| | `hammer_ground_rupture` Ground Rupture | Colossus | 0.5 / 0.1 / 0.4 | 18 s | | 8 m, 20° (line): 100 and `rooted` 1.2 s, max 6 |
| Greatsword | `greatsword_unstoppable` Unstoppable | Executioner | 0.2 / 0.1 / 0.2 | 30 s | | You: `unstoppable` 4 s and `fortified` 10 % for 4 s |
| | `greatsword_blade_guard` Blade Guard | Bladesmaster | 0.15 / channel ≤ 2.0 s / 0 | 14 s | | 140° block with mitigation 1.0 and 0.8 stamina per point; movement ×0.3 |
| Spear | `spear_impale` Impale | Dragon | 0.35 / 0.1 / 0.45 | 18 s | | 4 m, 20°: 150, `bleed` and `wounded` |
| | `spear_bristle` Bristle | Phalanx | 0.15 / channel ≤ 2.0 s, re-hit 0.5 / 0 | 20 s | | 3.6 m, 120° ahead: 50 and knockback 6 m/s to whoever enters; movement ×0.2 |

The upgrades of the original proposal that are server-only (the longer stun of the shield bash is the exception already
moved to a cooldown variant) are M nodes of the trees and are not repeated here.
