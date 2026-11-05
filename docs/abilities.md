# Eldmark · Phase 4: design of abilities, effects, weapons and projectiles

A short design for the combat expansion announced in [fortress.md 10](fortress.md#10-combat-expansion-another-short-design):
abilities with cooldowns (CMB-19), status effects (CMB-20), sword and shield (CMB-21), projectiles
with rewind (CMB-22), bow (CMB-23), weapon swap (CMB-24), knocked down (CMB-28), minimal equipment
(PRG-04), templates (PRG-07), consumables (PRG-08), action bar (UI-11) and status icons
(UI-45). It continues [combat.md](combat.md) (its §1, §3, §4 and §6 are taken as read), [networking.md](networking.md) (§6,
§8, §10, §14) and the tick order of [fortress.md 1.7](fortress.md#17-tick-order-completes-combatmd-42).

Version 2: version 1 after the review by three reviewers (§10). Anything marked "verified" comes from probes in
headless Godot 4.7.2 (not committed).

Coexistence: F4 (NPCs) and chat and parties (SOC-03 to SOC-08, protocol 5) are merged **before**
any H package (§7.1). F4 adds weapons `data/combat/npc_*.tres`, `AttackDefinition.unblockable`
(server only) and command 12: **no catalog id is fixed**, everything is requested by name
(`CombatCatalog.ability_id(&"shield_bash")`). The fort NPCs (`HfsmBrain` and `NpcWorld` from F4;
`NpcBrain` remains the dummy) use abilities and effects like a player (their weapon can carry
`abilities`); finishing off knocked-down players is taught to them by H3c (§4.5).

---

## 0. Decisions

The first four were pending backlog items that blocked progress; they are taken with their recommendation
(**provisional, decided overnight**) and move to "Decisions made" in [backlog.md](backlog.md).

| Question | Decision |
|---|---|
| Resource for abilities | Cooldown only on physical weapons; mana only on staves (phase 6). Stamina remains the defensive resource. *Provisional, decided overnight.* |
| Origin and direction of projectiles | Canonical camera ray from `look_yaw`, `look_pitch` and a shoulder bit; the arrow leaves the chest toward the aimed point, which converges at the depth of the enemy closest to the crosshair (§4.4). *Provisional, decided overnight.* |
| Knocked down | PvP only: if the killing blow comes from a player of another realm, the victim stays knocked down for 20 s. Against NPCs, the environment or in PvE, direct death. *Provisional, decided overnight.* |
| HUD and secondary resource | Action layout: health, stamina and bar at the bottom center; stamina hides when full; the secondary resource slot stays reserved for staves. *Provisional, decided overnight.* |
| When the cooldown starts | At **commitment**: the first active tick of the ability. Channels set it when they end. A control effect or a dodge before commitment does not spend it. |
| Potions | Two fixed ones (health on R, stamina on T), shared 20 s cooldown and charges per life from the template. They are spent when the drink finishes: a hit that interrupts does not consume the potion. |
| Bow | The light attack is the quick shot and the heavy attack's charge is the draw: the phase 3 machine with no shape changes. No block. No random spread: accuracy is ballistics. |
| Projectiles over the network | No records in the snapshot: reliable ENTITY_SPAWN and ENTITY_DESPAWN with the ballistics (§5.3); the client computes the flight. 40 arrows in the air would cost 840 B per snapshot. |
| Own arrow | Seen instantly (predicted); marker and number on confirmation, like melee. |
| Weapon swap | Q, 0.4 s; the weapon changes on the first tick; cooldowns are kept (absolute ticks). Active weapon in `CombatState` and in bit 3 of the record's `flags`. |
| Templates | Squire (sword and shield) and marksman (bow and sword and shield). They are chosen before entering or on the death screen; they apply on the next spawn. |
| Equipment | Only the two weapons. Armor, `StatBlock` and derived sheet are left for PRG-01 and PRG-06 (§9). |
| Effects that move | Two slots in `CombatState` (slow, root); the rest lives on the server. |
| Shield bash | Unblockable (`AttackDefinition.unblockable`, from F4) and stuns for 0.8 s. It can be dodged. |
| Shield wall | 180° block and a box that stops enemy projectiles: it protects those behind from arrows, not from blows. |
| Interruption | Only a HIT from a blow or an arrow with result IMPACT, damage > 0 and a hostile author (not pulses or environment) cuts drinking and the marked casts (phase 0, `[0, cast)`), reviving and executing. Control effects cut any action, as today. |
| Friendly fire | Still none: arrows and areas pass through allies. |
| New keys | Q swap weapon, R health potion, T stamina potion. They are rebindable with UI-17. |
| Deviations from the backlog | CMB-21: the wall protects those behind only from arrows. CMB-23: no spread; the charge gives damage and speed (flatter trajectory). CMB-24: the active weapon goes in bit 3 of the record's `flags`, not in the action byte. PRG-04: only the two weapons, no derived sheet (§9). Noted in backlog.md. |

---

## 1. What is predicted and what the server decides

| Data | Where it lives | Predicted | Travels in |
|---|---|---|---|
| Ability in progress: ABILITY action, id, tick, dash direction | `CombatState` | Yes | own state; action byte of remote players (§5.5) |
| Cooldowns (6 absolute ticks), the consumables' one and the charges | `CombatState` | Yes; the server enforces everything on spawn and, in camp, only the charges (§3.5) | own state |
| Active weapon and the one in the other slot | `CombatState` | The swap, yes; the pair is enforced by the server (template) | own state; public SPAWN; bit 3 of the record's `flags`; LOADOUT |
| Slow and root (2 slots) | `CombatState`, **enforced by the server** | No: adopted on reconciliation; their effect on speed is predicted | own state; STATUS |
| Bleed, heal over time, damage up, mitigation down | `Combatant` (`StatusSystem`) | No | STATUS, HIT (pulse), HEAL |
| Ability hits, areas and charge | `CombatResolver` | No | HIT |
| Projectiles | `ProjectileSystem` | Only the own arrow, as an image | SPAWN and DESPAWN of kind 3 |
| Knocked down, reviving and executing | `CombatState` (**enforced** actions) and `Combatant` | Neither the start nor the outcome; yes the movement and the end of reviving or executing on release or by time | own state; DOWNED; INTERACT |
| Knocked-down health | `Combatant` | No | extra block (bit 3 of `status`), `health_q` |
| Potion healing | `StatusSystem` | No | STATUS, HEAL |
| Potion stamina | `CombatState` | Yes | own state |

Rule from networking.md §6.7: whatever the server decides and changes the simulation enters `PlayerState`, even if
it is not predicted (movement effects, knocked down).

---

## 2. Data

### 2.1 Resources (`scripts/shared/combat/`, data in `data/combat/`)

Seconds in the `.tres` files, ticks on load with `roundi(s · 60)`. "P" = predicted (enters
`prediction_hash`); "S" = server only. Everything in the `data/combat/` folder (the catalog does not enter
subfolders and distinguishes by type).

```gdscript
class_name AbilityDefinition extends Resource
@export var id: StringName
# P · phases: cast [0, cast), active [cast, cast+active), recovery up to the total.
@export var cast_s: float = 0.0; @export var active_s: float = 0.1   # in a channel, its cap
@export var recovery_s: float = 0.3         # 0 in channels
@export var cooldown_s: float = 10.0        # 0 in consumables (they use the shared one)
@export var channel: bool = false           # the active phase is a channel
@export var channel_hold: bool = true       # releasing its slot's button ends it
@export var channel_breaks_on_move: bool = false
@export var cancel_to_dodge_from_s: float = -1.0; @export var cancel_to_attack_from_s: float = -1.0
		# -1 = from recovery
@export var move_speed_scale: float = 0.3; @export var turn_rate: float = 6.0; @export var lunge_speed: float = 0.0
@export var dash_distance_m: float = 0.0    # enforced advance (0 = none), baked like the dodge
@export var dash_from_s: float = 0.0; @export var dash_to_s: float = 0.0; @export var dash_curve: Curve
@export var dash_direction: int = 0         # 0 toward look_yaw, 1 backward, 2 per move (like DODGE)
@export var usable_in_air: bool = false
@export var stamina_restore: int = 0        # on commitment (stamina potion)
@export var blocks: bool = false            # the channel blocks (shield wall)
@export var projectile: ProjectileDefinition    # leaves on commitment
@export var projectile_count: int = 1; @export var projectile_spread_deg: float = 0.0   # between arrows
@export var projectile_speed_mps: float = 45.0
# S · hit on every active tick (without a shape, there is no hit) and effects:
@export var shape: HitShape; @export var base_damage: int = 0; @export var damage_type: int = 0
@export var stagger_s: float = 0.0; @export var stun_s: float = 0.0; @export var knockback_speed: float = 0.0
@export var hyper_armor: bool = false; @export var unblockable: bool = false
@export var target_status: StatusEffectDefinition   # on whoever it hits (also with its arrow)
@export var self_status: StatusEffectDefinition; @export var self_heal: int = 0   # on commitment
@export var interrupt_on_damage: bool = false        # always true on consumables
@export var wall_half_extents: Vector3 = Vector3.ZERO   # box that stops projectiles (channel)
@export var wall_forward_m: float = 0.7

class_name StatusEffectDefinition extends Resource
enum Kind { DAMAGE_OVER_TIME, HEAL_OVER_TIME, SLOW, ROOT, DAMAGE_UP, MITIGATION_DOWN }
enum Stacking { REFRESH, STACK, STRONGEST }
@export var id: StringName; @export var kind: int; @export var duration_s: float
@export var stacking: int = Stacking.REFRESH; @export var max_stacks: int = 1
@export var move_speed_scale: float = 1.0   # P: SLOW (0 < x ≤ 1, or > 1 if it speeds up); ROOT = 0
@export var pulse_every_s: float = 1.0      # S: the duration, an exact multiple in ticks
@export var pulse_amount: int = 0           # S: per stack
@export var damage_type: int = 0            # S
@export var magnitude: float = 0.0          # S: DAMAGE_UP +fraction; MITIGATION_DOWN −fraction

class_name ProjectileDefinition extends Resource     # whole P: ballistics of the predicted arrow
@export var id: StringName; @export var gravity: float = 6.0   # m/s² downward
@export var radius_m: float = 0.05; @export var lifetime_s: float = 2.0

class_name EquipmentTemplate extends Resource        # neither P nor S: enforced by the server
@export var id: StringName; @export var selectable: bool = true   # false: tests and NPCs only
@export var weapons: Array[WeaponDefinition]        # 1 or 2, in slot order
@export var consumable_charges: PackedInt32Array = PackedInt32Array([3, 2])   # 0–15 each
```

Changes to existing resources:

- `AttackDefinition`: `projectile` and `projectile_speed_mps` (P; with a projectile the shape may be null and
  the attack fires on its first active tick), `charge_speed_scale` (P, speed at full charge, linear
  from ×1), `stun_s` and `on_hit_status` (S). `unblockable` is added by F4.
- `WeaponDefinition`: `abilities: Array[AbilityDefinition]` (0–3, the position is the slot) and
  `can_block: bool = true` (P). `light_combo` allows 1 to 3 hits.
- `CombatRules`. P: `swap_s` 0.4, `swap_move_scale` 0.8, `downed_move_scale` 0.15, `downed_turn_rate` 3,
  `revive_s` 3, `execute_s` 1, `consumables: Array[AbilityDefinition]` (exactly 2),
  `consumable_cooldown_s` 20, `aim_pivot_height` 1.6, `aim_shoulder_offset` 0.6,
  `aim_camera_v_offset` 0.1, `aim_range_m` 150, `aim_converge_deg` 12, `muzzle_height` 1.4. S:
  `downed_health` 400, `downed_s` 20, `revived_health` 300, `interact_range_m` 2.0,
  `interact_keep_range_m` 2.5, `ability_block_angle_deg` 180, `ability_block_stamina_per_damage` 0.6,
  `max_projectiles_per_shooter` 8, `max_projectiles_per_zone` 64 (§4.4, §8), `default_template`
  (squire). `aim_shoulder_offset` and `aim_camera_v_offset` are the `h_offset` and `v_offset` of
  `camera_rig.tscn` (checked by `test_aim_ray`).

### 2.2 Catalog

- **Ids**: separate spaces for attacks, weapons, abilities, effects, projectiles and templates;
  1..n in alphabetical order of `id`, 0 = none. Effects and templates fit in u8 (≤ 255; more is an
  error). Nobody writes an id by hand: `ability_id(name)`, `status_id(name)`, `projectile_id(name)`,
  `template_id(name)`. The F4 ones (`npc_*`) only shift numbers.
- **`AbilityTicks`** also stores `slot` (0–2) and `weapon_id`, or `consumable_index` (0–1) if it is a
  consumable, and `hit: AttackTicks`: a **synthesized** attack with the ability's windows
  (windup = `cast`) and its S fields, which is not in the attack table. This way the resolver tests
  an attack and an ability's hit the same way (§4.2). Its `id` is the ability's source (§5.4).
- **Dash**: `dash_curve` is baked like the dodge: an f32 speed per tick between `dash_from` and
  `dash_to` that adds up to `dash_distance_m`.
- **Validation** (errors in `CombatTables.errors`): an ability on a single weapon or in the consumables;
  `cooldown_ticks ≥ total_ticks + REARM_TICKS` (two uses of the same slot leave at least
  `AbilityTicks.REARM_TICKS` = 6 ticks in NONE in between, three snapshot intervals: the
  action byte needs it, §5.5; it used to be `+ 1`, implementation review in §11.10); channel without
  recovery; consumable with `cooldown_s` 0 and `consumable_cooldown_ticks ≥ total + REARM_TICKS` of each
  consumable; duration of an effect with pulses a multiple of
  `pulse_ticks`; ROOT with scale 0, SLOW with scale > 0; dash window inside the ability;
  `lifetime_ticks ≥ 1`; `projectile_count` 1–5; a `selectable` template carries no `npc_*` weapons.
- **`prediction_hash`** (`_HASH_FORMAT` becomes 2): **every field marked P in §2.1 enters, with no
  exceptions** (rules, attacks, weapons and abilities with the baked dash; id, kind and
  `move_speed_scale` of each effect; the projectiles), also `downed_move_scale`, `downed_turn_rate`,
  `revive_s`, `execute_s` and `blocks`. The S fields do not enter (`downed_health`, `downed_s`, `revived_health`,
  `interact_*`, `wall_*`, `ability_block_*`, damage, shapes, control effects, pulses), nor do the templates.

### 2.3 Starting values

Sword and shield (`sword_shield.tres` gains `abilities`). Ticks in parentheses.

| Ability | Slot | Cast | Active | Recovery | Cooldown | Effect |
|---|---|---|---|---|---|---|
| Shield bash `shield_bash` | 1 | 0.3 (18) | 0.1 (6) | 0.4 (24) | 12 s | sector 2.2 m, 90°, 0.2–2.0 m; 60 blunt; **stuns 0.8 s (48)**; unblockable; dash 1 m/s, movement ×0.2, turn 6 |
| Shield rush `shield_rush` | 2 | 0.15 (9) | 0.4 (24) | 0.35 (21) | 16 s | 6 m dash in the active phase (flat curve); sector 1.8 m, 140°; 50 blunt; stagger 0.4 s and knockback 6 m/s; hyper armor in the active phase |
| Shield wall `shield_wall` | 3 | 0.2 (12) | up to 6 s (360), channeled | 0 | 18 s when it ends | 180° block (stamina 0.6 per point); 2.6 × 2.0 × 0.3 m box 0.7 m in front that stops enemy arrows; movement ×0.3, turn 4; released with 3; dodge from the end of the cast |

Bow (`bow.tres`, `bow_quick.tres`, `bow_drawn.tres`; dodge = `sword_dodge.tres`; `can_block = false`).

| Action | Timings | Projectile | Damage | Other |
|---|---|---|---|---|
| Quick shot (light, 1-hit combo) | windup 0.25 (15), active 1/60 (1), recovery 0.35 (21): 37 ticks | 45 m/s | 60 piercing | movement ×0.5, turn 8, dodge from 0.27 (16) |
| Draw (heavy) | charge 0.35–1.0 s (21–60) from the press; after release 0.05 (3) + 1 + 0.3 (18) | 40 → 70 m/s (`charge_speed_scale` 1.75) | 90 → 180 (×2.0) | charging: movement ×0.5, turn 8; no stamina |
| Volley `bow_volley` (1) | 0.3 (18) + 1 + 0.4 (24); cooldown 10 s | 3 arrows at ±7°, 45 m/s | 55 each | |
| Slowing arrow `bow_slowing_shot` (2) | 0.35 (21) + 1 + 0.3 (18); cooldown 12 s | 55 m/s | 60 | `slowed` on hit |
| Evasive shot `bow_evasive_shot` (3) | cast 0.3 (18) with a 4 m backward dash over [0, 0.3); fires on commitment; recovery 0.25 (15); cooldown 14 s | 50 m/s | 60 | |

`arrow.tres`: gravity 6 m/s², radius 0.05 m, 2 s lifetime (90 m at 45 m/s; 140 m at 70).

Consumables (`CombatRules.consumables`), shared cooldown of 20 s (1200):

| Potion | Drink | Movement | On commitment |
|---|---|---|---|
| Health `potion_health` (R) | 0.6 (36) + 1 + 0.2 (12) | ×0.4, no sprint or jump | `potion_regen`: 300 health over 3 s |
| Stamina `potion_stamina` (T) | 0.4 (24) + 1 + 0.2 (12) | ×0.4 | +400 stamina (predicted) |

Effects: `slowed` (SLOW ×0.6, 3 s, the strongest wins), `potion_regen` (heal 50 every 0.5 s for 3
s: 6 pulses; refresh), `bleed` (15 per stack every 1 s for 6 s: 6 pulses; up to 3; slashing;
for NPC weapons and tests), `rooted` (ROOT 1.5 s; tests). Templates: `squire` = [`sword_shield`],
charges [3, 2]; `marksman` = [`bow`, `sword_shield`], charges [2, 3].

### 2.4 Input for the balance sheet (combat.md §12)

Computed from the data above, not measured. H5 (§7) measures it with `tools/combat_balance.gd` and
moves it to combat.md §12 as "12.8 Phase 4 kits".

| Action | Cycle | Damage | Computed DPS |
|---|---|---|---|
| Sword combo (reference, 12.1) | 119 ticks | 310 | 156.3 |
| Repeated quick shot | 37 ticks | 60 | 97.3 |
| Minimum draw | 21 + 22 = 43 ticks | 90 | 125.6 |
| Maximum draw | 60 + 22 = 82 ticks | 180 | 131.7 |
| Sword and shield abilities, at cooldown | | 60 / 12 s + 50 / 16 s | +8.1 and 0.8 s of stun every 12 s |
| Bow abilities, at cooldown | | 165 / 10 s + 60 / 12 s + 60 / 14 s | +25.8 if the whole volley hits |
| Health potion | 20 s | +300 | +15 health per second sustained; 900 per life (squire) |

Flight of the maximum draw: 0.14 s at 10 m, 0.43 s at 30 m, 0.71 s at 50 m (1.5 m drop). Of the quick shot: 1.11
s and 3.7 m drop at 50 m. The target TTK of 12.5 (median 10–15 s) is measured again in 2 versus 2 with
bots and both templates.

**Stamina** (the column from 12.1): no new action costs stamina; the bow's dodge is the
sword's. The wall spends 0.6 per blocked point and does not regenerate: a lone attacker (156.3 DPS) takes
563 in 6 s and **does not break it**; two take 1000 in 5.3 s. This is on purpose (counterplay: unblockable
shield bash, flanking and numerical superiority); H5 measures the break 1 versus 1 and 2 versus 1 and, if two
do not break it either, raises the cost to 0.8–1.0. Exhaustion prevents the wall (like BLOCK) and the draw
(like the charge, `_try_charge`); it does not prevent the quick shot, the other abilities or the potions.

---

## 3. State and action machine

### 3.1 `CombatState` v5

`CombatState.ENCODED_SIZE` goes from 34 to **76 B** and `PlayerState.ENCODED_SIZE` from 69 to **111 B**. The
offsets 35–68 do not change; the following is added at the end (offsets within `PlayerState`):

| Offset | Type | Field | What it is |
|---|---|---|---|
| 69 | u16 | `alt_weapon_id` | weapon in the other slot (0 = none) |
| 71 | u8 | `combat_flags2` | bit0 slot 2 active, bits 1–6 ABILITY_1/2/3, SWAP, CONSUMABLE_1/2 pressed on the previous tick, bit7 no cooldowns (command) |
| 72 | u32 × 3 | `ability_ready[0..2]` | first tick at which each ability of the active weapon is usable again |
| 84 | u32 × 3 | `ability_ready[3..5]` | same, weapon in the other slot |
| 96 | u32 | `consumable_ready_tick` | shared consumable cooldown |
| 100 | u8 | `consumable_charges` | bits 0–3 potion 1, bits 4–7 potion 2 |
| 101 | u8 + u32 | `move_effect_ids[0]`, `move_effect_until[0]` | movement effect (0 = free) and its end (exclusive) |
| 106 | u8 + u32 | `move_effect_ids[1]`, `move_effect_until[1]` | same |

Changes to existing fields:

- `action`: 9 ABILITY (ability or consumable), 10 SWAP, 11 DOWNED, 12 REVIVE, 13 EXECUTE (14 and 15
  free). `action_id` is an attack in LIGHT/HEAVY/CHARGE and an ability in ABILITY.
- `buffered` changes shape: **bits 0–3 type, bits 4–7 ticks remaining**. Types: 0 nothing, 1
  PRIMARY, 2 DODGE, 3 link, 4–6 ABILITY_1–3, 7 SWAP, 8–9 CONSUMABLE_1–2. Reads of `buffered &
  3` are not simply replaced: `_run_buffer` dispatches by type (1 and 3 → light, 2 → dodge, 4–6 →
  `_try_ability`, 7 → `_try_swap`, 8–9 → `_try_consumable`); in `_finish_expired`, `linked` = type ∈
  {PRIMARY, link}; and the expiry of any type other than PRIMARY with the light attack already finished
  also sets `combo_step = 0`.
- `action_dir` also stores the dash direction of an ability.

Cooldowns and effects are absolute ticks, like `cc_until_tick`: restoring a state has no
ambiguity and time runs even when the weapon is stowed. **Two slots** are enough: in phase 4 there are only
`slowed` and `rooted` (test); a third replaces whichever ends first.

**Byte cost.** The own state goes in each snapshot to its owner: +42 B per snapshot. Header with
state and extra block: 13 + 111 + 9 + 1 = **134 B**; with one section, ⌊(1200 − 136) / 21⌋ = **50
records** (previously 52). With 64 players, 63 others in 50 slots: each one gets out at least once every
⌈63/50⌉ = 2 snapshots, same as with 52; with the ~10 fort NPCs, 73 others, also 2 (it becomes 3 with
more than 100 others). Below the cap, +42 B × 30/s = **+1.26 KB/s** per client; at the cap the
packet was already full (36.8 KB/s): what is lost is 2 records per snapshot.

### 3.2 Buttons and substituted inputs

`PlayerInput`: bit 9 `SWAP_WEAPON` (Q), bit 10 `AIM_LEFT` (left shoulder: set by the client with the
camera's effective shoulder; it is a level, not a press), bit 11 `CONSUMABLE_1` (R), bit 12
`CONSUMABLE_2` (T). Bits 13–14 reserved; 15 remains `SUBSTITUTED`. `VALID_BUTTONS = (1 << 13) −
1`. With `SUBSTITUTED`, as in combat.md §3.2, the machine sees no edges (the substitute repeats the
buttons), does not cut a channel for moving and does not release what is held. No loss invents
an ability, a weapon swap or a potion.

### 3.3 Per-tick rules

`ActionMachine.step()` with `t = input.tick`, fixed order (extends combat.md §3.3):

0. **Fast path**, as today, if in addition there are no ABILITY, SWAP or CONSUMABLE presses (`AIM_LEFT` does not
   count) nor their bits in `combat_flags2`, nor any movement slot occupied.
1. **End of actions**, as today and in addition: ABILITY to NONE at `t ≥ action_tick + total` (channel:
   at `t ≥ action_tick + cast + active`, with its cooldown, rule 5); SWAP at `t ≥ action_tick +
   swap_ticks`; REVIVE and EXECUTE at `t ≥ action_tick + revive_ticks` / `execute_ticks`. DOWNED and DEAD do not
   end on their own.
2. **Movement effects**: the slot with `move_effect_until ≤ t` is emptied.
3. **Stamina**, as today; it also does not regenerate during a channel that blocks.
4. **Inputs** (edges with the bits of `combat_flags` and `combat_flags2`, without `SUBSTITUTED`). In
   DOWNED and DEAD only the buffer and press are cleared. Fixed order: **4a** ends by input (channel and
   REVIVE/EXECUTE, below); **4b** the buffer (valid at `p+1 … p+8` for the press at tick `p`, by type,
   §3.1); **4c** the new edges by priority, **DODGE > ABILITY_1 > ABILITY_2 > ABILITY_3 >
   CONSUMABLE_1 > CONSUMABLE_2 > PRIMARY > SWAP > BLOCK**. An edge that cannot be executed now goes
   to the buffer (one slot, the last wins); it is discarded if it makes no sense (empty slot, no charges, no
   alternate weapon, `can_block` false, dash while ROOTed). A channel with `channel_hold` that comes out
   of the buffer requires its button to be down; otherwise it is discarded. Example: releasing 3 and pressing PRIMARY on the same
   tick ends the wall in 4a and the light attack comes out in 4c, on that tick.
   - **DODGE**: as today and in addition from ABILITY starting at its `cancel_to_dodge_from` and from REVIVE and
     EXECUTE (it cuts them). Not while ROOTed. From a channel, it ends it (rule 5).
   - **ABILITY_n**: there is an ability in the slot; `t ≥ ability_ready[n]` (or bit7); an action that allows it:
     NONE, BLOCK, CHARGE (cancels the charge without spending), DODGE from `cancel_to_attack_from`, LIGHT and
     HEAVY in their recovery, ABILITY in its recovery or from its `cancel_to_attack_from`; on the
     ground unless `usable_in_air`. It starts: `action = ABILITY`, `action_id`, `action_tick = t`,
     `action_dir` per `dash_direction` (with this tick's `move` and `look_yaw`), `combo_step = 0`,
     `charge_ticks = 0`, no link or `FLAG_LIGHT_OF_PRESS`. On cooldown: to the buffer (valid if it
     finishes within the next 8 ticks).
   - **CONSUMABLE_n**: same, with `t ≥ consumable_ready_tick` and charges > 0.
   - **PRIMARY**: as today; also from ABILITY in recovery. With the bow, the light attack is the quick
     shot and holding turns it into a draw (combat.md §3.3, unchanged).
   - **SWAP**: `alt_weapon_id ≠ 0`; from NONE, BLOCK, the recovery of LIGHT, HEAVY or ABILITY and DODGE
     from `cancel_to_attack_from`; also in the air. It starts: `action = SWAP`, `action_tick = t`,
     swaps `weapon_id ↔ alt_weapon_id` and `ability_ready[0..2] ↔ [3..5]`, flips bit0 of
     `combat_flags2`, `combo_step = 0`. Never in the middle of windup, active hit, charge, cast
     or channel: it goes to the buffer.
   - **BLOCK**: as today, only if `can_block`.
   - **Channel in progress** (4a; ABILITY with `channel` and `t ≥ action_tick + cast`): with
     `channel_hold`, a real input without its slot's button ends it; with `channel_breaks_on_move`,
     a real input with `|move| ≥ 0.1` does too.
   - **INTERACT** (4a) starts nothing here (reviving and executing are started by the server, §4.5); in REVIVE
     or EXECUTE, a real input without INTERACT ends them (to NONE).
5. **Commitment** (after the inputs): if `action == ABILITY` and `t == action_tick + cast_ticks`:
   consumable → its charge − 1 and `consumable_ready_tick = t + consumable_cooldown_ticks`; ability without
   channel → `ability_ready[slot] = t + cooldown_ticks`; in both, stamina +
   `stamina_restore` (without exceeding the maximum). With `cast = 0` it commits on the tick it starts. A
   channel sets `ability_ready[slot] = t_end + cooldown_ticks` on the tick it ends, for whatever
   cause (also if the server cuts it, §3.5), **if it arrived committed**: one that ends at
   `t ≤ action_tick + cast` (release or DODGE on the commitment tick, which 4a and 4c look at first) is
   cancelled without a cooldown. A tap of 3 shorter than the cast gives 12 ticks of cast, NONE
   and no cooldown, only the `REARM_TICKS` margin on the slot (like an interruption, §4.2 and
   §5.5); releasing at `action_tick + cast + 1`, one tick of wall and 18 s. With bit7 nothing is set and no
   charges are spent. *(Phase 4 review, "abilities" lens: without the margin, another press of 3 at
   `action_tick + cast + 1` came out with the same action byte after a single tick of NONE.)*
6. **Movement output** (§3.4).

### 3.4 Allowed movement

Extends the table in combat.md §3.3:

| Action | Target horizontal speed | Turn | Jump | Sprint |
|---|---|---|---|---|
| ABILITY cast and active | `wish · run · move_scale + forward · lunge` | toward `look_yaw` at `turn_rate`; on the first tick it snaps to `look_yaw` | no | no |
| ABILITY in its dash window | **enforced**: `dir(action_dir) · dash[t − action_tick − dash_from]` | none | no | no |
| ABILITY recovery | `wish · run · move_scale` | none | no | no |
| ABILITY channel | `wish · run · move_scale` | toward `look_yaw` at `turn_rate` | no | no |
| SWAP | `wish · run · swap_move_scale` | the normal one | no | no |
| DOWNED | `wish · run · downed_move_scale` | toward `look_yaw` at `downed_turn_rate` | no | no |
| REVIVE, EXECUTE | brakes | none | no | no |

**Effects.** `Output.speed_factor` = (smallest scale < 1 among the slots, or 1) × (largest scale > 1, or 1)
multiplies the **non-enforced** target speed in all actions, NONE and sprint included; the
dodge, the dash and the knockback are not affected. ROOT (scale 0) also sets `rooted`: no jump, and in the air it brakes
like `move_scale` 0. The bow while drawing uses the usual CHARGE row.

### 3.5 What the server enforces

All followed by `CombatDirector.commit_state` (rounding via `encode/decode`). Those from combat.md §3.4
change as follows: `impose_stagger` and `impose_stun` do nothing on DOWNED or DEAD; all those that change the
action, if they cut a committed channel, set its cooldown on that tick.

- `impose_downed(c, t)`: DOWNED, clears buffer, press, combo and movement slots.
- `impose_revived(c, t)`: NONE with `action_tick = t`.
- `impose_interact(c, t, action)`: REVIVE or EXECUTE with `action_tick = t`.
- `impose_interrupt(c, t)`: NONE (cuts drinking, a marked cast, REVIVE or EXECUTE) **keeping
  the `action_tick` of what it cuts**, like `_to_none` (§4.2, old sample); before commitment there is
  no cooldown or expenditure.
- `impose_move_effect(c, effect_id, until_tick)`: same id → `until = max`; otherwise a free slot; otherwise
  it replaces whichever ends first.
- `clear_move_effects(c)`, `reset_cooldowns(c)`.
- `set_charges(c, charges)`: **only** `consumable_charges`. Used by the camp refill and
  command 16: they do not touch weapon, cooldowns, slots or the action in progress.
- `set_loadout(c, weapon_1, weapon_2, charges)` and `reset_for_respawn(c, t, weapon_1, weapon_2,
  charges)`: weapons in slot order (active one is 1), cooldowns to 0, charges, empty slots; the
  pressed-button bits are kept. **Only on spawn** (newly created character or DEAD); on a
  living one they first force NONE. Command 5 `set_weapon` becomes `set_loadout` with the weapon in slot 1.

### 3.6 Queries

`phase(c, t)`: in ABILITY, 0 cast, 1 active or channel, 2 recovery; in SWAP, DOWNED,
REVIVE and EXECUTE, 3. `active_hit(c, t) -> AttackTicks` (the attack in its active hit or the
synthesized hit of the ability in its active phase; null if there is none). `is_commit_tick(c, t)` (first active tick of
LIGHT, HEAVY or ABILITY). `ability_status(c, slot, t)` (READY, COOLDOWN, BLOCKED, EMPTY, NO_CHARGES; for
the bar). `defense_flags`: the channel that blocks gives `DEFENSE_BLOCKING | DEFENSE_WIDE_BLOCK` (bit 7
of `StateHistory`, free until today); DOWNED gives no defense. The history byte is **`(record's flags
& 0b111) | defense_flags`**: bit 3 of the record (slot 2, §5.2) never enters, because in
`StateHistory` bit 3 is `DEFENSE_BLOCKING`. `_record_history` masks it and the comments in
`StateHistory` and `ActionMachine` say so.

---

## 4. Server

### 4.1 Tick order (completes fortress.md §1.7)

| Step | What | In fortress.md |
|---|---|---|
| 0 | NPC brains (F4) | 0 |
| 1 | Simulate everyone by `net_id` | 1 |
| 2 | Freeze: position, turn, defense, action, `active_hit`, commitment and wall of each one | 2 |
| 3 | **Own shots and effects** of whoever is on their commitment, by `net_id`: new projectiles (§4.4), `self_status` and `self_heal` (HEAL) | — |
| 4 | **Resolve** without touching state: hits from attacks and abilities against the frozen data and the history, gates, and the flight of all live projectiles (including those from step 3) | 3 |
| 5 | **Apply** by the attacker's `net_id` (first their hits, then their projectiles by id) and the target's: damage, block, control effects, `target_status`, interruptions, knock-downs and deaths; DESPAWN of arrows that impact | 4 |
| 6 | **Status effects**: pulses and expirations; first everyone's pulses are gathered and then applied, by the affected's `net_id` and effect id, skipping anyone already knocked down or dead on this tick | 4 |
| 7 | **Knocked down**: bleed-out, new INTERACTs, progress and end of reviving and executing | 4 |
| 8 | Environment, respawns (with template) and consumable refill in camp (every 60 ticks, `set_charges`); from phase 5, with inventory, equipment weapons and CAMP_REFILL (§4.6) | 4 |
| 9 | Publish: health, state, action byte and active slot | 4 |
| 10 | `FortressController.step(s)` | 4b |
| 11 | Spawns, history, snapshots, OBJECT_STATE, events and projectile SPAWN/DESPAWN | 5 |

A knocked-down or dead player in step 5 receives no more hits on that tick (`_apply_hit` discards with
`is_dead() or downed_tick == s`, §4.5): everything was resolved against the same state, like today's
deaths. When an entity is removed (`CombatDirector.remove`: disconnect, `--fake-churn`, a withdrawn NPC),
its live arrows go out with DESPAWN 5 on that tick and its effects on others are removed (STATUS 2); the
removal of a knocked-down player is first a death (§4.5).

### 4.2 Abilities

- **Hit with its own shape** (shield bash): the synthesized hit goes through the same path as an
  attack: rewind fixed on the first active tick, candidates, shape, line of sight and defenses from
  combat.md §4.3. `unblockable` skips parry and block. Apply: `stun_ticks` → `impose_stun`; otherwise
  stagger and knockback as today; `hyper_armor` and the chain of control effects, the same.
- **Shield rush**: the dash is simulated by `simulate()` (predicted, collides with walls); the hit is tested on
  each active tick, each target once per action, with radial knockback.
- **Area**: frontal = sector; centered = `angle_deg ≥ 360` (no cone, `HitShapes` already handles it).
- **Own effect**: in step 3, once (the commitment falls on a single tick).
- **Shield wall**: melee with `DEFENSE_WIDE_BLOCK` → cone of `ability_block_angle_deg` and spend of
  `ability_block_stamina_per_damage`; for projectiles, in addition, the box (§4.4).
- **Old block sample** (changes combat.md §4.3; H3a): **it does not count if the frozen action is not
  BLOCK and its `action_tick > view_tick`, whether it is NONE or not** (today `_dropped_guard_after` accepts
  any NONE). `_to_none` and `impose_interrupt` keep the `action_tick` of what ends: simply releasing the
  shield still counts; lowering it to drink or revive and returning to NONE does not.
- **Gates**: ability hits test gates the same way attacks do.
- **Interruption**: a HIT from a blow or an arrow with result IMPACT, damage > 0 and a hostile author (not effect
  pulses or environment) on whoever is in phase 0 (`[0, cast)`) of a consumable or of an ability with
  `interrupt_on_damage`, or in REVIVE or EXECUTE → `impose_interrupt` (if the hit does not already impose a
  control effect). After commitment it is no longer interrupted: the charge and the healing are already in place. HIT with
  bit 5. Before commitment nothing is spent, but the interruption leaves a margin of `REARM_TICKS`
  ticks on the slot's cooldown (or on the shared one, if it is a consumable) so that the next
  use does not come out with the same action byte after a single tick of NONE (§5.5; review in §11.10).
- **Spawn protection**: it is also lost in an ABILITY that is not a consumable
  (`CombatDirector._started_attack`, like LIGHT, HEAVY and CHARGE) and on **starting to execute** (EXECUTE,
  in `DownedSystem`, on the tick it starts: executing is attacking, and a protected player is not a candidate for
  any hit, so nobody could cut the execution short; review in §11.10); drinking, SWAP and REVIVE do not
  remove it.

### 4.3 Status effects (`StatusSystem`, `scripts/server/status_system.gd`)

- Each `Combatant` carries up to 8 `ActiveEffect`: `status_id`, `source_id`, `anchor_tick`, `until_tick`,
  `stacks`. A new one when there are already 8 replaces whichever ends first.
- **Apply** at `s`: `REFRESH` → `until = s + D` (the anchor does not change); `STACK` → `stacks = min(stacks +
  1, max)` and `until = s + D`; `STRONGEST` → only if it is stronger (lower scale in SLOW/ROOT, more
  `pulse_amount` or `magnitude`), and if equal, `until = max` (with the author of the latest end). REFRESH and
  STACK pass to the latest author. New: `anchor = s`, `stacks = 1`.
  SLOW and ROOT also write their slot (`impose_move_effect`). STATUS 1 event.
- **Exact pulses**: at `anchor + k · P` for `k = 1, 2, …` while `anchor + k · P ≤ until`. Without
  refreshing, N = D / P (6 for `bleed`). The last pulse and the expiry fall on the same tick: the
  pulse first. DOT: `pulse_amount × stacks` of its type, with no block or crit, with the modifiers →
  HIT with the effect's source and attacker `source_id` (can knock down and kill; does not interrupt). HOT:
  heals without exceeding the maximum → HEAL. Immortal NPCs still do not drop below 1. `step` gathers the pulses
  before applying them (§4.1, step 6): a knock-down halfway through does not erase the list being traversed.
- **Expiry**: at `s ≥ until` it is removed (STATUS 2); the movement slot is already emptied by the simulation
  on the same tick.
- **Modifiers**: `DamageFormula.compute(..., damage_scale = 1 + Σ DAMAGE_UP of the attacker,
  mitigation_penalty = Σ MITIGATION_DOWN of the victim)`; the block's mitigation drops by that
  fraction (minimum 0).
- **Cleanup**: on death, on being knocked down and on respawn, all are erased, with no stray STATUS
  (DEATH, DOWNED and RESPAWN erase them on the client). No effects are applied to a knocked-down player.

### 4.4 Projectiles (`ProjectileSystem`, `scripts/server/projectile_system.gd`)

**Shot** (step 3), for each projectile of the attack or ability that commits at `s`:

1. **Rewind**: the one from combat.md §4.3 step 2, fixed now for the whole flight and **rounded to whole
   ticks** (`rewind` and `defense_rewind`; factored out of `CombatResolver._swing_rewind`). Rejected (more than
   `allowed + 8` ticks; up to that it is clamped to the cap) → **harmless** arrow (it flies and collides with the world, does not
   test characters), suspicion + 1 and a log entry. *(Phase 4 review, "cheats" lens: rejection started
   at `allowed + 1` and the arrow of an honest player who fired on a delayed frame came out harmless;
   networking.md §10.)*
   It is also harmless if the shooter is in their realm's safe zone. Fake players and NPCs: no rewind.
2. **Aiming** with the input of `s` (`InputQueue.get_applied(s)`): `AimRay.canonical(feet, look_yaw,
   look_pitch, AIM_LEFT)` gives the canonical camera ray: base `B = Basis(UP, yaw) · Basis(RIGHT,
   pitch)`, direction `D = B · FORWARD` and origin `C = feet + (0, aim_pivot_height, 0) +
   B · (±aim_shoulder_offset, aim_camera_v_offset, 0)` (whatever is behind the character does not count).
   **Aimed point** (`AimRay.aim_point`) `P = C + D · t`, with `t_m` the distance to the first collision with
   the world (`LINE_OF_SIGHT_MASK`) or `aim_range_m` and the hostiles at `s − rewind`: if the ray touches a
   capsule before `t_m`, `t` is that collision; otherwise, the hostile whose center `H` (feet + 0.9 m) lies
   within `aim_converge_deg` of `D` with `(H − C) · D` in `(0, t_m)`, the one with the smallest angle (tie by
   `net_id`), gives `t = (H − C) · D`; with none, `t = t_m`. This way the arrow crosses the crosshair at the
   depth of the target even if it leads into the air (without convergence it deviated by `|O − C| · (1 − d/t)`,
   0.51 m at 30 m with the background at 150 m). Exit at the chest, `O = feet + (0, muzzle_height, 0)`;
   `dir = (P − O).normalized()`, rotated in yaw by the volley's offsets; `v0 = dir · speed ·
   lerp(1, charge_speed_scale, f)`, with the `f` of the damage charge (combat.md §4.4; 0 without charge).
   Bots and NPCs: `AimRay.look_for(feet, point, left)` gives the `(yaw, pitch)` whose ray passes through a point
   (3 fixed-point iterations); they aim at `O + dir · |target − O|` with the `dir` from `solve_lead`.
3. **Rounding**: `O` and `v0` are quantized as they travel in the SPAWN (1 cm, 1 cm/s; `Ballistics.quantize`) and
   the server flies with that, so that the client's trajectory is the same.
4. **Author copy**: the projectile stores `owner_id`, realm, whether it is a player, `source`, `rewind`,
   `defense_rewind`, the charge's `f` and `damage_scale` (DAMAGE_UP at `s`), and does not look up the
   shooter's `Combatant` again (`Hit` gains `projectile_id` and this copy; `should_down` receives the realm and whether it is a
   player). If the shooter is removed, DESPAWN 5 (§4.1).
5. **Spawn**: id from the `NetEntityRegistry` space (`allocate_transient_id`, same 600-tick
   quarantine) without entering its entity list; SPAWN to whoever has the shooter as relevant and to the shooter. **A
   shot is never rejected** (commitment and cooldown are already predicted): with 8 alive from the shooter,
   its oldest goes out, and with 64 in the zone, the oldest in the zone (tie by id), with DESPAWN 5 on that
   tick: these are usually the shots into the sky, which live the full 2 s.

Verified: `h_offset` and `v_offset` shift the origin without rotating the ray (with `v_offset`, within 4·10⁻⁷ m
of the canonical one); zoom and arm (along the ray) do not change the line; the shoulder and the lateral pull do.

**Flight**: both sides call the same `Ballistics.position(p0, v0, g, n) = p0 + v0 · n/60 + (0, −½
· g · (n/60)², 0)`, with `n` an integer (server) or fractional (drawing). On tick `k`, with `n = k −
spawn_tick`, the segment `[pos(n), pos(n + 1)]` is tested (on the shot's tick, the first one). A
segment that **starts inside** a box or a capsule gives fraction 0.

- **World**: `intersect_ray` against `LINE_OF_SIGHT_MASK` (world and gate; not the invisible blockers);
  the first segment, with `hit_from_inside = true`. Contiguous segments: no tunneling. If the body belongs to
  a `StructureTarget` that the shooter can damage (`get_body_rids`), it is a hit on the gate (piercing
  ×0.2).
- **Walls**: the boxes of the shield walls of entities hostile to the shooter, at `k` (present, like
  the world and the gate; whoever holds it moves at ×0.3), with `HitShapes.segment_box_fraction`. Only those
  of someone with no protection and not in their realm's safe zone count (the "open" ones, like the
  candidates): through the wall of someone in their camp the arrow passes as through their capsule, and that wall
  does not cover allies outside either (combat.md §5: inside you neither take nor deal damage). *(Phase 4
  review, "abilities" lens: before, it stopped it, and whoever held it in their camp spent
  stamina, ended up "in combat" with the shooter and, without stamina, suffered the guard break with its
  stun and the part of the hit it did not pay for, until knocked down inside their safe zone.)*
- **Characters**: candidates from combat.md §4.3 step 4 (hostile, alive or knocked down, with no protection or
  safe zone) at `k − rewind`, read with `StateHistory.position_at(id, tick) -> Vector3` (without creating
  objects; with `rewind = 0`, the frozen one). Culling: a **swept box** per candidate (the union of 4
  blocks of 8 ticks that `StateHistory` maintains while recording, which covers at least `[k − 24, k − 1]`, plus the
  frozen position), computed once per tick if there are live arrows or shots; only if it overlaps the
  segment's box, segment against a capsule of radius 0.4 + `radius_m` (`HitShapes.segment_capsule_fraction`).
  `aim_point` culls with the same boxes, by angle.
- The smaller fraction wins. Character: invulnerable in `[k − defense_rewind, k]` → keeps flying and
  is not tested again; block (normal or from the wall) with the cone facing `−velocity` → BLOCKED; never a
  parry; otherwise, IMPACT (point-blank if it starts inside) with the source's damage (with its charge),
  control effects and `target_status`. **Wall** → BLOCKED for whoever holds it, like their block: no damage
  (`block_mitigation` 1), spends `ability_block_stamina_per_damage × damage` and without stamina breaks the
  guard (stuns and cuts the channel with its cooldown). World → it sticks.
- No impact and `n + 1 ≥ lifetime_ticks`, or `y < −100` → DESPAWN 5 (expires).
- **Corners**: the arrow leaves the chest, and the segment toward `P` collides with the corner the chest does not
  see: it does not come out on the camera's side. The chest **can** be inside a vision body: the
  owner crosses their closed gate (fortress.md §3.1) and, with feet in the doorway, the chest is in the
  0.5 m box. That is why the first segment uses `hit_from_inside` and the arrow sticks at the origin
  (verified: without it, the ray starting inside ignores the box). In melee,
  `HitShapes.is_ray_clear` switches to `hit_from_inside = true` (H3a): from the doorway you neither hit nor are
  hit. An enemy archer inside the wall's box collides with it; behind whoever holds it
  (characters do not collide with each other) they shoot freely: the wall covers the front.
- The client only controls yaw, pitch and `AIM_LEFT`, as in melee; `P` only picks the
  direction and never makes the arrow pass through anything. Program-assisted aiming belongs to CMB-39.

### 4.5 Knocked down, reviving and executing (`DownedSystem`, `scripts/server/downed_system.gd`)

- **When**: the health of a **player** (fake ones too) reaches 0 from a blow, arrow or pulse whose
  author is a hostile player in an RVR zone. Otherwise, direct death (NPC, environment, dummy).
- **Falling**: `impose_downed`, `health = 0`, `downed_health = 400`, `downed_tick = s`, `downed_by`,
  `downed_source`, effects erased; DOWNED (whole zone) and HIT with bit 6.
- **Predicates** (`Combatant`): `is_alive()` = health > 0, unchanged; `is_downed()` = `downed_tick ≥ 0`;
  `is_dead()` = health 0 and not knocked down. A knocked-down player is neither alive nor dead, and each use today ends up like this:

| Where | With a knocked-down player |
|---|---|
| `CombatResolver._is_candidate`, `NpcWorld` (F4), `_rebuild_target_cache` (all with `is_dead()`) | candidate, without touching the code |
| `CombatDirector._apply_hit` | discards with `is_dead() or downed_tick == s` |
| `_apply_impact` → `take_damage` (returns 0 at health 0) | `take_downed_damage`: no block or control effects |
| `_process_environment` (lethal volumes) | dies; killer `downed_by` |
| `ZoneServer._gate_blockers` (`is_alive()`) | counts: the gate cannot be repaired with a knocked-down player in the doorway |
| `request_respawn`, `heal` (command and console), `regenerate` | reject it (`request_respawn`: NOT_DEAD) |
| presence in the circle, `UnstuckTracker` (`is_alive()`) | unchanged: does not count or request /stuck |
| `status_bits` | knocked-down bit 3 (§5.2), without DEAD |
| `_should_linger`, `_process_lingering`, `_remove_player` | see "Leaving" |

- **Bleeding out**: −1 every 3 ticks (400 over 1200 ticks = 20 s). Enemy damage (no block possible) takes
  from there; control effects do not apply. At 0: death. DEATH and KILL with killer = whoever dealt the last
  damage, or `downed_by` with source "bled out" (§5.4) if it was time.
- **INTERACT** (step 7): an edge in a real input (the buttons of `s` versus those of `s − 1`, which the
  `Combatant` stores) from someone alive, not knocked down, in NONE or BLOCK and on the ground; the closest knocked-down player within ≤
  `interact_range_m` (horizontal, `|Δy| ≤ 1.5`; tie by `net_id`) **with line of sight**
  (`HitShapes.is_ray_clear` from the chest, feet + 1.4, to the knocked-down player's feet + 0.5; a closed gate
  cuts it):
  - **ally** with nobody reviving them → `impose_interact(REVIVE)`; INTERACT 1 with `end_tick = s +
    revive_ticks`;
  - **enemy** (without safe zones in between: the knocked-down player is not in their realm's one nor is the executioner in
    theirs) → `impose_interact(EXECUTE)`; INTERACT 4. Starting to execute removes spawn
    protection (§4.2).
- **Continuing**: every tick it is cut (`impose_interrupt` if still in the action; INTERACT 2 or 5) if whoever
  acts has left the action (released, dodged or had another imposed), the target is no longer knocked down,
  exceeds `interact_keep_range_m` or line of sight is lost, or one of the two receives an impact
  that interrupts (§4.2). An execution, in addition, if a safe zone ends up in between (the knocked-down player
  crawls to their camp or the executioner enters theirs), also on the final tick (review in
  §11.10). What is predicted only ends the action: the server notices because it leaves REVIVE
  early.
- **Finishing** (checked before continuing: on that tick the simulation has already returned to NONE), at `s == start +
  duration`: revive → `impose_revived`, health 300, INTERACT 3; execute → death with source "execution".
- **NPCs** (H3c, in F4's code): they do not become knocked down. In `NpcWorld` and `HfsmBrain`, a hostile knocked-down player
  within 6 m is the preferred target (before the closest standing one) and is attacked with PRIMARY;
  it asks for an `AttackTokens` token like any target. H3c notes it in fortress.md §4.2.
- **Fort**: a knocked-down player does not count in the circle (fortress.md 1.2).
- **Leaving**: every removal of a knocked-down player (CLIENT_LEAVE, ENet drop, `--fake-churn` or the end of the grace period
  of a body that stayed because of GUE-41) is first a **death on that tick**: DEATH and KILL with killer =
  whoever dealt the last damage, or `downed_by`, and source "bled out"; then, DESPAWN. There is no need to
  keep the body or refresh "in combat", and on returning they appear in the camp like anyone.
- **Command 15** `down`: `downed_by = 0` (on bleeding out, DEATH without KILL); rejected outside the RVR
  zones and in the own safe zone.

### 4.6 Equipment, templates and consumables

- `Combatant.template_id` is the current one; the pending one lives in `ServerPeer.pending_template_id` (−1 =
  none; valid in LOADING and IN_WORLD): LOADOUT_SELECT (§5.1) records it, and it is copied to the `Combatant` on
  registration (`_process_arrivals`) and on every respawn. If not chosen, `default_template`; fake players,
  `--fake-loadout`. On spawn, `set_loadout` or `reset_for_respawn` with its weapons and charges, and LOADOUT
  to the owner and to whoever has them as relevant. **From phase 5**, every player with a peer has an inventory (with or
  without the platform): the template only chooses the kit for the first entry, respawn takes the equipment's
  weapons and CAMP_REFILL replaces the refill, with a fixed total per potion: 3 health and 2 stamina,
  also for the `marksman`, whose charges here are [2, 3] (progression.md §2.5 and §4.4). Only fake players
  still use template and refill.
- **Refill** (every 60 ticks): alive, out of combat, in their realm's safe zone and with fewer charges
  than their template → `set_charges` with full charges and LOADOUT to the owner. Weapon, cooldowns,
  slots and the action in progress do not change.
- **Potions**: they are abilities (§2.3); the healing (HOT) is set by step 3; the stamina, by the simulation.

### 4.7 Validation and anti-cheat

- The server's simulation decides: an ability on cooldown, a consumable without charges or a swap
  mid-hit do not happen. `--bot-cheat=reuse` (hammers an ability on cooldown), `potion` and
  `interact` (INTERACT every tick far from anyone): no extra effect or suspicion.
- Projectiles: rewind fixed per shot with the usual cap and defense minimum; the direction
  comes from yaw and pitch, never from a point sent by the client.
- `--combat-log`: new results `arrow_hit`, `arrow_blocked`, `wall_blocked`, `pulse`, `downed`,
  `executed`, `bled_out`, `revived`; the `ataque` column carries the source's name.

---

## 5. Protocol: `PROTOCOL_VERSION = 6`

"6: abilities, effects, weapon swap, projectiles, knocked down and templates (docs/abilities.md)". Version
5 belongs to chat and parties (SOC-03, `0x40`–`0x4F`), already merged; F4 does not change it. The allocation is fixed: 7 belongs
to phase 5 (platform.md §5.4), which waits for this document. `0x07` and events 7–11 do not collide with SOC.

### 5.1 Inputs and C→S messages

- INPUT_BATCH with no format changes; `VALID_BUTTONS` = bits 0–12 (§3.2).
- **LOADOUT_SELECT** (`0x07`, C→S, channel 3, 2 B): `u8 type`, `u8 template_id`. Valid from WELCOME,
  also before CLIENT_READY (LOADING and IN_WORLD; §4.6). `_on_packet_received` gains its case, with the
  reliable-message limiter. 0 = the default one, without a warning; an id that does not exist or is not `selectable`
  counts a warning.
- **DEBUG_COMMAND**, new ids (fixed): 13 `cooldowns_off` (`u8` 0 or 1: bit7 of `combat_flags2`), 14
  `apply_status` (`u8 status_id`, `u16` ticks, 0 = the data's own), 15 `down` (knocks itself down, as
  if an enemy had done it, but with `downed_by = 0`; §4.5), 16 `refill` (restores the charges
  with `set_charges`). No data on 15 and 16.

### 5.2 State, snapshot and record

- `PlayerState` of 111 B (§3.1) in the own state, in the own SPAWN and in the others' SPAWN.
- **Other players' SPAWN**: besides what is already public, `alt_weapon_id` and bit0 of `combat_flags2` (the
  weapons are visible); cooldowns, charges, consumable, movement slots and button bits, at their
  initial values.
- **Record** (21 B, no size change): bit 3 of `flags` = slot 2 active. The remote player knows which
  weapon is carried from the pair (SPAWN or LOADOUT) and this bit. The action byte has no free bits. The
  history does not take this bit (§3.6).
- **Own extra block** (9 B): bit 3 of `status` = knocked down; when knocked down, `health` is the knocked-down
  health and `max_health` 400. The `health_q` of a knocked-down player comes from that health (never 0: 0 is dead).
- Header of 134 B, 50 records (§3.1).

### 5.3 PROJECTILE (kind 3)

**ENTITY_SPAWN**: usual header (`net_id` = projectile, `realm` = the shooter's, **bit0 of `flags`
(`is_yours`) always 0**: "yours" is `owner` = your `net_id`) and 22 B; total **32 B**. `NetClient._on_spawn`
looks at `kind` before `is_yours`; `RemoteWorld` and `SwarmBot` ignore kind 3.

| Offset | Type | Field | Notes |
|---|---|---|---|
| 10 | u16 | owner | shooter's `net_id` |
| 12 | u16 | projectile_def_id | `ProjectileDefinition` |
| 14 | u16 | source | source of the attack or ability (§5.4) |
| 16 | u8 | volley_index | 0..n−1 within the shot |
| 17 | u8 | proj_flags | bit0 harmless; rest, 0 |
| 18 | u64 | position | `p0`, 20 bits per axis like the record |
| 26 | s16 × 3 | velocity | `v0` in cm/s |

`spawn_tick` is the tick of the shot. `decode` returns `null` if the size is not 32.

**ENTITY_DESPAWN** (8 B, unchanged): new reasons 4 IMPACT and 5 EXPIRED; `despawn_tick` is the tick
of the impact, which the server found in the segment `[pos(n), pos(n + 1)]`, `n = despawn_tick −
spawn_tick` (§6.2).

The snapshot carries **no** projectile records (`Snapshot.decode` keeps rejecting other `kind`s).

### 5.4 ENTITY_EVENT and sources

**Source** (`CombatSource`, shared): the `u16 attack_id` of HIT, DEATH, KILL and TELEGRAPH become
a source: bits 14–15 the class and bits 0–13 the id. 0 = none (environment); `0x0000 | id` attack;
`0x4000 | id` ability; `0x8000 | id` effect (pulse); `0xC000 | 1` execution, `0xC000 | 2` bled out. Today's
attacks keep their number.

HIT gains bit 5 of `flags` (interrupted) and bit 6 (knocks down). New events:

| `event` | Data | `len` | Total | `net_id` | Recipients |
|---|---|---|---|---|---|
| 7 STATUS | `u16 source_entity` (0 = no author), `u8 op` (1 applied or refreshed, 2 removed), `u8 status_id`, `u8 stacks`, `u32 until_tick` | 9 | 18 B | the affected | owner, author and whoever has the affected as relevant |
| 8 HEAL | `u16 healer` (0 = self), `u16 amount`, `u16 source` | 6 | 15 B | the healed | same |
| 9 LOADOUT | `u8 template_id`, `u16 weapon_1`, `u16 weapon_2`, `u8 charges` | 6 | 15 B | the player | owner; and whoever has them as relevant if the weapons change, with `charges` = 0 |
| 10 DOWNED | `u16 attacker`, `u16 source` | 4 | 13 B | the knocked-down player | the whole zone (kill feed) |
| 11 INTERACT | `u16 actor`, `u8 op` (1 revive, 2 revive cut, 3 revived, 4 execute, 5 execute cut), `u32 end_tick` | 7 | 16 B | the knocked-down player | actor, knocked-down player and whoever has them as relevant |

Validation: exact sizes; `op` out of range or STATUS 1 with `stacks` 0 → `null`. "Ability cast"
and "weapon swap" carry no event: they travel in the stream (action byte and bit 3 of `flags`), which animates the
remote player like attacks. Damage pulse = HIT with an effect source; healing = HEAL; executed and
bled out = DEATH with its source; potion = STATUS and HEAL.

**Timing** (combat.md §6): own ones on arrival; a remote player's, at its `render_tick`.
`NetClient._note_imposed_state` also treats as explained: movement STATUS on oneself, DOWNED and
INTERACT where one is the knocked-down player or the actor, own LOADOUT and own HIT with bit 5.

### 5.5 Action byte (`ActionWire`)

| Action | Bits 4–5 | Bits 6–7 |
|---|---|---|
| ABILITY | 0 cast, 1 active or channel, 2 recovery | slot 0–2; 3 = consumable (drink) |
| SWAP | 3 | restart counter (a buffered SWAP comes out on the tick another one ends) |
| DOWNED, REVIVE, EXECUTE | 3 | 0 |
| CHARGE with the bow | 0 | 0 (the remote player knows it is a draw from the weapon) |

Two consecutive uses of the same slot or two consecutive consumables come out with the same byte, but between them
there are always at least `AbilityTicks.REARM_TICKS` = 6 ticks of NONE: the validation in §2.2 demands it from
cooldowns, and an interruption before commitment (§4.2) or a channel released or broken at the end
of its cast, without committing (§3.3, phase 4 review), leave that margin. A single tick of NONE was
not enough: a remote player sees the record every `SNAPSHOT_INTERVAL_TICKS` = 2 ticks (or less often, with the snapshot's
priority-based distribution), and one that did not sample that tick saw the same byte and did not restart the clip
(review in §11.10). With the margin, ABILITY needs no counter. `ActionWire.has_counter` adds SWAP.

### 5.6 Bandwidth

Downstream per client = (136 + n · 21 + 40) B × 30/s: 10 visible ~11.6 KB/s (previously 10.3), 30 visible
~24.2 KB/s (22.9), cap from 50 visible 36.8 KB/s. Projectiles: 40 B (SPAWN + DESPAWN) plus ~10 of ENet
per arrow and recipient: 20 arrows per second in view, ~1 KB/s. Server output with 64: from
~2.4 to ~2.5 MB/s. H2 updates networking.md §5.2, §5.4, §5.5 and §14.

---

## 6. Client

### 6.1 Prediction and rejections

Everything in §3 lives in the predicted state: reconciliation corrects it with no code of its own. **A rejection**
(the server did not start the ability: on its timeline the player was stunned) removes the action and
returns `ability_ready` to its value on replay, and the bar, which reads the predicted state every frame,
reverts the counter on its own. `CombatFeedback` keeps detecting actions by `(action, action_id,
action_tick)`; no signal comes out of `simulate()`.

### 6.2 Arrows (`ProjectileWorld`, `scripts/client/projectile_world.gd`)

- **Predicted**: `ClientPrediction` emits `stepped(tick, input, state)` after **every** `step()` (a physics
  tick can produce 0, 1, 2 or more steps; never during replays) and `ProjectileWorld` looks there at
  `ActionMachine.is_commit_tick(state.combat, tick)`. It is created with that input, `AimRay` against the local
  world and the remote players' capsules **as drawn** (convergence too) and the same
  quantization. It is drawn at the predicted time; it stops at the world with its own ray (first segment
  with `hit_from_inside`) and is hidden on touching an enemy's drawn capsule (no number).
- **Replacement**: the SPAWN with own `owner` is paired with the predicted one of the same source and
  `volley_index` whose tick differs by ≤ `input_buffer_ticks`; the server's `p0`, `v0` and `spawn_tick` are adopted
  with a visual offset that decays over 6 ticks. Without a pair: the server's is drawn. A predicted one
  without SPAWN is withdrawn (rejection) when the tick of the latest snapshot exceeds its tick +
  `input_buffer_ticks` + 30 (the server would already have sent it; the SPAWN goes over the reliable channel and may
  arrive somewhat after the snapshot of its tick). It is measured with the server's tick and not with the input's
  RTT, which goes stale if latency rises (review in §11.10); with no snapshot yet, `rtt + 30`
  ticks.
- **Remote**: they appear when `render_tick ≥ spawn_tick` and are drawn at `pos(render_tick + fraction −
  spawn_tick)`. With DESPAWN 4 they are withdrawn when `render_tick + fraction ≥ despawn_tick + f`, with `f` the
  fraction of their own ray (world and drawn capsules of those hostile to the arrow's realm, the one in the
  SPAWN) on the last segment, or 1 if it touches nothing: this way they reach the wall or the target, like the player's own. If the
  last segment is the first, with `hit_from_inside`, like the server: one that leaves from inside the
  closed gate stays at its mouth (review in §11.10). With DESPAWN 5, at `despawn_tick`.

### 6.3 Action bar (UI-11, `ActionBar`)

Bottom center, above health and stamina: light/heavy (or shot/draw), block (hidden with
`can_block` false), dodge, abilities 1–3 of the active weapon, R and T with their charges, and Q with the icon of the
weapon in the other slot. `UIIconSlot` slots (UI-09): cooldown = `ability_ready[i] −
predicted tick`, with sweep and seconds; flash when it becomes ready; `ability_status` dims them (BLOCKED) or
strikes them through (NO_CHARGES); the dodge blinks without stamina (bit1, as today). On swapping weapons the
icons change. A press during cooldown blinks the slot on the client (it does not travel). Provisional icons:
squares with the weapon's initial and color until ART-12.

### 6.4 Statuses (UI-45, `StatusTracker` and `StatusIcons`)

`StatusTracker` (one per entity) stores `status_id`, `stacks` and `until_tick` from the STATUS events; it removes them
with STATUS 2, DEATH, DOWNED, RESPAWN or DESPAWN. The local player's receives its events on arrival (all
are its own); a remote player's, at its `render_tick`, also the own ones (the STATUS the local player
applies, the DEATH or DOWNED it causes), whose signal does go out on arrival: this follows the server's
tick order. *(Phase 4 review, "abilities" lens: before, an own STATUS on a remote player entered on
arrival and an older foreign STATUS still waiting for its draw tick undid it: the expiry of an ally's
slow erased from the nameplate the one the player had just reapplied, or a foreign STACK
renewal overwrote the own one.)* Own row above health: icon, seconds remaining
(against the estimated server tick), stacks, red border if harmful and green if not,
tooltip. Nameplates: up to 4 icons (harmful ones first), with the knocked-down health and a
knocked-down icon.

### 6.5 Knocked down, templates and bow

- **Knocked down**: "Derribado" notice (knocked down) with the countdown of the knocked-down health (extra block), "Te están
  levantando" (being revived) with the INTERACT 1 bar, "¡Te rematan!" (being executed) with INTERACT 4. Whoever is near a knocked-down
  ally (drawn positions and DOWNED action) sees "Mantén E para levantar a …" (hold E to revive …). An ally can
  revive while one or more enemies execute (§4.5): `DownedNotice` stores each interaction with its actor,
  removes it only on that actor's end or cut (revived, all) and shows the execution before the
  revive. *(Phase 4 review, "abilities" lens: it stored just one and any cut erased it;
  the cut of the reviver removed "¡Te rematan!" with the execution under way, and a revive that started
  covered it.)*
- **Templates**: selector (weapons and charges of each `EquipmentTemplate`) on the death screen and in
  realm selection; it sends LOADOUT_SELECT on choosing. From phase 5 it only counts for the first entry: the
  client does not show it to someone entering with a ticket and, without the platform, hides it after the first spawn
  (§4.6, progression.md §2.5).
- **Bow**: while drawing, the camera narrows the field of view to 75% of the configured one (72° by default,
  `client_settings` changes it; it does not touch the arm, so the canonical ray does not change) and the reticle
  closes. `get_effective_shoulder()` (shoulder after the automatic swap) sets `AIM_LEFT`.

### 6.6 Provisional animation (pending the user's eye)

`CombatClipPlanner` gains keys by ability name and `swap`, `drink`, `downed`, `revive`,
`execute`, with a set of clips per weapon (`data/animation/<weapon>_clips.tres`; new `bow_clips.tres`).
Provisional, with clips that exist (names verified in the `.glb` files): `ual2/Shield_OneShot` (shield
bash), `ual2/Shield_Dash` (rush), `ual2/Idle_Shield_Loop` (wall), `ual2/Consume` (drink),
`ual1/Fixing_Kneeling` (revive), `ual2/Melee_Hook` (execute), `ual2/LayToIdle` (getting up),
`ual2/NinjaJump_Start` (backflip), `ual1/Spell_Simple_Shoot` and `ual1/Pistol_Aim_Neutral` (bow),
`ual1/Death01` held on its last frame (knocked down, still) and `ual1/Crouch_Fwd_Loop` (crawling);
`swap` is a 0.4 s fade. `WeaponProps` gains a provisional bow (curved cylinder) and swaps the
accessories with the slot bit, on remote players too (PRG-07 is visible, not just in the data).
**Pending from the user**: drawing, holding and releasing the bow and tuning the poses and the feel of the
zoom (ART-41), crawling, drawing and stowing the weapon, bow and arrow models, VFX and icons (ART-12).
The remote player animates with the action byte, the slot bit and the weapon pair.

---

## 7. Packages and contracts

### 7.1 Packages

All of H starts with **F4 and SOC-03 to SOC-08 merged**: H1a touches `attack_definition.gd`, `attack_ticks.gd`,
`combat_catalog.gd` and their tests, which F4 and SOC-03 already change, and H2 and H4 the same network files,
`zone_server.gd`, `input_bindings.gd` and `hud.gd` as SOC.

| Package | Contents | Depends on |
|---|---|---|
| **H1a · state and data** | `CombatState` v5 (fields, constants, `copy_from`, no new behavior), `PlayerState` 111 B, `PlayerInput` buttons, resources and `*Ticks` of §2.1, new `CombatRules`, `CombatCatalog` (ids, validation, hash), `CombatSource`, `Ballistics` (`position`, `quantize`), all the `.tres` files of §2.3, backlog.md (§0) | F4, SOC |
| **H1b · machine** | `ActionMachine` (§3, split into `ability_rules.gd`), `ActionWire` (§5.5: slot, consumable, SWAP counter), `PlayerCharacter.simulate` with `speed_factor` and `rooted`, `AimRay` (`canonical`, `aim_point`, `look_for`), `Ballistics.solve_lead`, `HitShapes` (fractions), `DamageFormula` (modifiers) | H1a |
| **H2 · protocol v6** | `PROTOCOL_VERSION`, `VALID_BUTTONS`, LOADOUT_SELECT, ids 13–16, projectile SPAWN and DESPAWN, events 7–11, HIT bits, bit 3 of `flags` and of `status` in the messages, networking.md (new rows of §5.2 with "v6", versions of §5.3, §5.4, §5.5 and §14) | H1a |
| **H3a · abilities and effects** | tick order (§4.1, with the steps of H3b and H3c empty), synthesized hit in `Combatant.freeze` and the resolver, `StatusSystem`, interruptions, melee wall, protection, old sample (§4.2), `is_ray_clear` from inside, history byte (§3.6), `_hide_private_state`, publication of bit 3, `InputQueue.get_applied`, commands 13–14, combat log | H1b, H2 |
| **H3b · projectiles** | `ProjectileSystem`, `allocate_transient_id`, `StateHistory.position_at` and swept boxes, wall box, caps, shooter removals | H3a |
| **H3c · knocked down and templates** | `DownedSystem`, predicates (§4.5), leaving, `HfsmBrain`/`NpcWorld`, templates, `ServerPeer.pending_template_id`, LOADOUT_SELECT in `ZoneServer`, refill, commands 5, 15 and 16 | H3b |
| **H4 · client** | `ProjectileWorld`, `ClientPrediction.stepped`, `ActionBar`, `StatusTracker`/`StatusIcons`, knocked-down notices, template selector, bow zoom and reticle, Q/R/T keys and `AIM_LEFT` bit, new `NetClient` explanations, texts (`CombatText`), provisional clips and `WeaponProps` | H1b, H2 |
| **H5 · integration** | combat `BotBrain` with abilities (holds the button of a channel), weapon swap, potions and bow (`solve_lead` + `look_for`); cheating modes `reuse`, `potion`, `interact` (`bot_cheat_brain.gd`, `bot_cheater.gd`, `client_config.gd`); end-to-end tests and load of §7.3; measured balance sheet (§2.4 → combat.md §12); player limit in networking.md §14 | H3c, H4 |

H2 and H1b in parallel after H1a; H3a → H3b → H3c in series (all touch `zone_server.gd` and
`combat_director.gd`) and H4 at the same time; H5 at the end. With two agents: one H1a → H1b → H3a → H3b → H3c, the other
H2 → H4 → H5.

### 7.2 Contracts

```gdscript
# scripts/shared/combat/combat_state.gd (extends)
enum Action { NONE, LIGHT, HEAVY, CHARGE, BLOCK, DODGE, STAGGER, STUN, DEAD,
		ABILITY, SWAP, DOWNED, REVIVE, EXECUTE }
const ENCODED_SIZE: int = 76; const ABILITY_SLOTS: int = 3; const MOVE_EFFECT_SLOTS: int = 2
const FLAG2_SECOND_SLOT: int = 1 << 0          # bits 1-6: buttons pressed on the previous tick
const FLAG2_NO_COOLDOWNS: int = 1 << 7
const BUFFER_ABILITY_1: int = 4                 # 5, 6; BUFFER_SWAP = 7; BUFFER_CONSUMABLE_1 = 8, _2 = 9
var alt_weapon_id: int; var combat_flags2: int
var ability_ready: PackedInt64Array             # 6; copy_from copies the contents
var consumable_ready_tick: int; var consumable_charges: int
var move_effect_ids: PackedInt32Array           # 2 (0 = free)
var move_effect_until: PackedInt64Array         # 2
static func initial(rules: CombatRules, weapon_id: int, alt_weapon_id: int = 0,
		charges: int = 0) -> CombatState
func buffered_type() -> int; func buffered_ticks() -> int
func charges_of(index: int) -> int; func is_second_slot() -> bool

# scripts/shared/combat/action_machine.gd (extends)
class Output:     # + var speed_factor: float = 1.0; var rooted: bool = false
enum AbilityStatus { READY, COOLDOWN, BLOCKED, EMPTY, NO_CHARGES }
const DEFENSE_WIDE_BLOCK: int = 1 << 7
static func active_hit(c: CombatState, tick: int) -> AttackTicks
static func is_commit_tick(c: CombatState, tick: int) -> bool
static func ability_status(c: CombatState, slot: int, tick: int) -> int
static func impose_downed(c: CombatState, tick: int) -> void
static func impose_revived(c: CombatState, tick: int) -> void
static func impose_interact(c: CombatState, tick: int, action: int) -> void   # REVIVE or EXECUTE
static func impose_interrupt(c: CombatState, tick: int) -> void
static func impose_move_effect(c: CombatState, effect_id: int, until_tick: int) -> void
static func clear_move_effects(c: CombatState) -> void
static func reset_cooldowns(c: CombatState) -> void; static func set_charges(c: CombatState, charges: int) -> void
static func set_loadout(c: CombatState, weapon_1: int, weapon_2: int, charges: int) -> void  # on spawn
static func reset_for_respawn(c: CombatState, tick: int, weapon_1: int, weapon_2: int,
		charges: int) -> void

# scripts/shared/combat/combat_catalog.gd (extends): ability(id) -> AbilityTicks, status(id) ->
# StatusTicks, projectile(id) -> ProjectileTicks, template(id) -> EquipmentTemplate, their *_id(name)
# -> int, template_count() -> int and consumable_ids() -> PackedInt32Array (2, in button order).

# scripts/shared/combat/combat_source.gd
class_name CombatSource extends RefCounted
enum Kind { ATTACK, ABILITY, STATUS, SPECIAL }
const EXECUTE: int = 0xC001; const BLEED_OUT: int = 0xC002
static func make(kind: int, id: int) -> int
static func kind_of(source: int) -> int; static func id_of(source: int) -> int

# scripts/shared/combat/aim_ray.gd · class_name AimRay extends RefCounted
static func canonical(feet: Vector3, look_yaw: float, look_pitch: float,
		left_shoulder: bool) -> Array        # [origin: Vector3, direction: Vector3]
static func aim_point(space: PhysicsDirectSpaceState3D, origin: Vector3, direction: Vector3,
		capsule_feet: PackedVector3Array) -> Vector3   # hostiles; with the convergence from §4.4
static func muzzle(feet: Vector3) -> Vector3
static func look_for(feet: Vector3, point: Vector3, left_shoulder: bool) -> Vector2   # (yaw, pitch)

# scripts/shared/combat/ballistics.gd · class_name Ballistics extends RefCounted
static func position(p0: Vector3, v0: Vector3, gravity: float, ticks: float) -> Vector3
static func quantize(p0: Vector3, v0: Vector3) -> Array    # [p0, v0] as they travel
static func solve_lead(origin: Vector3, target: Vector3, target_velocity: Vector3, speed: float,
		gravity: float) -> Vector3                       # direction (bots and NPCs)

# scripts/shared/combat/hit_shapes.gd (extends); they return 0..1, or -1 if it does not touch
static func segment_capsule_fraction(a: Vector3, b: Vector3, capsule_feet: Vector3, radius: float,
		height: float) -> float
static func segment_box_fraction(a: Vector3, b: Vector3, box: Transform3D, half_extents: Vector3) -> float
# (0 if a is inside); is_ray_clear becomes hit_from_inside = true
# damage_formula.gd: compute(..., damage_scale: float = 1.0, mitigation_penalty: float = 0.0)

# scripts/server/combatant.gd (extends); Frozen gains hit: AttackTicks, commit: bool, wall: Transform3D
var effects: Array[StatusSystem.ActiveEffect]
var downed_health: int; var downed_tick: int = -1; var downed_by: int; var downed_source: int
var interact_target: int; var interact_action: int; var interact_start: int; var last_buttons: int
var template_id: int              # the pending one, in ServerPeer.pending_template_id (−1 = none)
func is_downed() -> bool; func take_downed_damage(amount: int, tick: int) -> int   # is_dead(): §4.5

# scripts/server/projectile_system.gd · class_name ProjectileSystem extends RefCounted
signal spawned(spawn: NetMessages.EntitySpawn, recipients: PackedInt32Array)
signal despawned(projectile_id: int, tick: int, reason: int, recipients: PackedInt32Array)
func fire(shooter: Combatant, source: int, s: int, space: PhysicsDirectSpaceState3D) -> void
func resolve(s: int, combatants: Array[Combatant],
		space: PhysicsDirectSpaceState3D) -> Array[CombatResolver.Hit]   # Hit gains projectile_id
func live_count() -> int; func forget_owner(owner_id: int, s: int) -> void   # DESPAWN 5 for its own

# scripts/server/status_system.gd · class_name StatusSystem extends RefCounted
func apply(target: Combatant, status_id: int, source_id: int, s: int) -> void
func step(s: int, list: Array[Combatant]) -> void; func clear(target: Combatant) -> void

# scripts/server/downed_system.gd · class_name DownedSystem extends RefCounted
func should_down(victim: Combatant, author_realm: int, author_is_player: bool) -> bool
func down(victim: Combatant, author_id: int, source: int, s: int) -> void
func step(s: int, list: Array[Combatant], space: PhysicsDirectSpaceState3D) -> void

# input_queue.gd: get_applied(tick) -> PlayerInput (real or substituted)
# state_history.gd: position_at(id, tick) -> Vector3 (Vector3.INF if absent); swept_box(id) -> AABB
# client_prediction.gd: signal stepped(tick: int, input: PlayerInput, state: PlayerState)
# net_entity_registry.gd: allocate_transient_id(tick) -> int; release_transient_id(id, tick)
# camera_rig.gd: get_effective_shoulder() -> int; set_aim_zoom(f: float)
# net_client.gd: signal projectile_spawned(spawn); signal projectile_despawned(id, tick, reason)
```

### 7.3 Tests (each < 30 s)

None carries microsecond bounds (the machine is shared): cost is measured with tools (§8).

**H1a and H1b** (no network, worlds in a `SubViewport` like `test_prediction`):

- `test_combat_state_v5`: round trip with each field at its offset; 76 and 111 B; new `buffered`.
- `test_ability_machine`: starts on the edge; cooldown set at commitment (with `cast = 0`,
  on the same tick); becomes usable again at `t == ability_ready`, not before; stagger during the cast → no
  cooldown; **stagger cuts a channel** and sets its cooldown on that tick; releasing,
  moving (if the data says so) and the cap end the channel; the examples from §3.3 (release and press
  on the same tick; tap shorter than the cast; release at commitment and one after; buffered wall
  with the button held); priorities with simultaneous edges; buffer of an ability pressed during the
  recovery of a light attack, and one that expires leaves `combo_step = 0`; a substituted input starts nothing.
- `test_ability_reconciliation`: **the cooldown survives a reconciliation**: client and server
  with the same inputs, a position difference imposed after commitment; after replay,
  `ability_ready` is the same and the state matches byte for byte.
- `test_weapon_swap`: swap of weapons and of the two halves; **no swap mid-hit**
  (SWAP during windup or active: the weapon does not change until recovery; it expires if that does not arrive);
  **predicted and reconciled** with a substituted input around the edge: equal states;
  `set_charges` touches nothing else.
- `test_move_effects`: **slow gives the same speed on client and server** (the server
  imposes it at `s`; after reconciling, equal states every tick and speed = `run_speed · 0.6`); ROOT
  prevents dodging and dashing; expiry on the exact tick; a third slot replaces whichever ends first.
- `test_consumables_machine` (charges, shared cooldown, commitment when the drink finishes, exactly +400,
  does not start without charges) and `test_bow_machine` (tap = quick shot, 8 ticks = draw, minimum
  and maximum charges at their ticks, BLOCK does nothing, exhausted cannot draw).
- `test_aim_ray`: the canonical ray matches `CameraRig.get_aim_ray()` (no collision, any zoom
  and FOV, both shoulders) within 1 mm, and `aim_shoulder_offset`/`aim_camera_v_offset` with the scene;
  **lead shot with the background at 150 m**: target at 30 m and crosshair 3 m ahead, the arrow's line
  crosses the crosshair's within 2 cm at the target's depth; `look_for` passes within < 1 mm of the point;
  `Ballistics` and the quantization.
- `test_combat_catalog` (extends): ids requested by name; each error from §2.2; the hash changes with an
  ability timing, `downed_move_scale`, `revive_s` and `blocks`, and not with a damage value; the fast path of
  `simulate()` does not call `CombatCatalog.weapon()` nor traverse slots (counter; the micro-benchmark goes to
  `tools/combat_balance.gd`).
- `test_action_wire` (extends, H1b): ABILITY by slot and phase, consumable (3), SWAP counter.

**H2**: `test_net_messages` (extends): round trip and sizes of events 7–11, of the 32 B SPAWN (with
`is_yours` 0) and of LOADOUT_SELECT; truncated and `op` out of range → `null`; `VALID_BUTTONS`; `CombatSource`;
bit 3 of `flags`; *fuzz*. `test_snapshot_builder`: 50 records and never more than 1200 B.

**H3a, H3b and H3c** (server in one process, `combat_fixture.gd`; the long ones advance by hand with
`CombatDirector.process_tick`, like `test_combat_director`, or `ZoneServer._physics_process`, like
`tools/combat_balance.gd`, without waiting for frames):

- `test_ability_server` (H3a): shield bash stuns from the front and not from behind, passes through a raised
  shield; the rush covers 6 m (±0.3) and pushes; the wall blocks a hit at 85° from the front and not at 95°;
  **the server rejects an ability on cooldown** (a bot pressing it one tick out of two:
  commitments separated by exactly `cooldown_ticks + cast_ticks`); an ability removes protection and
  drinking does not; old sample: a released REVIVE and an interrupted potion inside the rewind do not block;
  slot 2 active without blocking → `flags & DEFENSE_BLOCKING == 0` in the history; from inside the closed
  doorway you neither hit outward nor get hit.
- `test_status_effects` (H3a): **a bleed produces exactly N pulses** (6, at `anchor + 60k`);
  stacking, refreshing and the strongest; a pulse does not interrupt; a pulse that knocks down halfway through the
  list; cleanup on death, on being knocked down and when the author leaves; STATUS with its `until_tick`.
- `test_projectiles` (H3b): **no arrow passes through walls** (40 shots at different angles at a
  target behind a wall: 0 impacts, all with DESPAWN 4 at the wall); **shot hugging a corner**
  (camera on the open side, target visible only to the camera: the arrow hits the corner); owner in the closed
  doorway: it sticks at the origin; frontal block; dodge that lets it pass; the wall stops arrows to an
  ally behind, from far away and with the archer inside its box, and not if they are behind whoever holds it;
  segment starting inside a capsule; caps: with 8 from the shooter or 64 in the zone a new shot exists and
  the oldest goes out; the shooter leaves with arrows in the air (DESPAWN 5); hit on the gate.
- `test_downed` (H3c): **the three outcomes**: revived (180 ticks, health 300, NONE), executed (60
  ticks, DEATH with execution source and KILL) and bled out (1200 ticks, killer = whoever knocked down); revive
  cut by damage; no executing through the closed gate; the gate cannot be repaired with a knocked-down player
  in the doorway; **a knocked-down player who leaves produces DEATH and KILL** and on returning appears in the camp; direct
  death against an NPC; an NPC does not ignore a knocked-down player and executes them with damage; command 15 without KILL.
- `test_consumables_server` (H3c): healing of 6 pulses; **a hit that interrupts** spends no charge or
  cooldown; refill in camp **with slot 2 active and a channel in progress**: weapon,
  `ability_ready` and action do not change; others' LOADOUT with `charges` 0.

**H4**: `test_action_bar` (weapon icons after a swap; **a rejection reverts the counter**: a
reconciliation that removes the ability leaves the slot ready), `test_status_icons` (nameplate and own row; it
disappears on expiry), `test_projectile_world` (the predicted one is replaced by the server's; two steps in one physics
tick with the commitment on the first; own SPAWN with the player already in the world; the remote one appears at
its `render_tick` and is withdrawn at `despawn_tick + f`), `test_hud_combat` (extends: knocked-down notices).

**H5** (ENet on loopback, `net_harness.gd`):

- `test_projectile_loopback`: **arrow at 30 m with rtt=150** (jitter 30) against a target running
  sideways, aimed with `solve_lead` and `look_for`: at least 18 of 20 draws confirmed; control in the
  same run, like `test_combat_loopback`: against the present position (without rewinding) fewer than 10
  would have hit.
- `test_abilities_reconciliation`: **3 bots with NetSim** (`rtt=120, jitter=20, loss=5`, 900 + 180 ticks)
  with both templates using abilities, weapon swap, potions, arrows, slows and
  knock-downs: all corrections explained (substitution, teleport or combat), no hard
  reset after startup and exact convergence when standing still (the phase 2 acceptance).
- `test_loadout_net`: two clients choose different templates (one before CLIENT_READY) and each sees
  the other's weapons (PRG-07); without loss, **0 corrections within ±rtt ticks around each SWAP**
  (PRG-04); a bleed from command 14 appears with its duration on the nameplate and the HUD and disappears on expiry (UI-45).
- `test_bot_cheat` (extends): `reuse`, `potion` and `interact` with no extra effect or suspicion.
  `test_combat_balance` (extends): bow DPS equal to the computed one; dummy at 10, 30 and 50 m; break of the
  wall 1 and 2 versus 1 (§2.4).
- **Load** (`load_test.gd --brawl`, manual like TEC-15): Vado Gris, 64 players (`--fake-loadout=
  marksman:50`), the fort NPCs and the zone cap full: tick p99 ≤ 16.7 ms and the projectile
  section ≤ 1 ms; otherwise the limit in networking.md §14 is lowered.

---

## 8. Risks

- **Projectile CPU** (reviewed with probes, shared machine). A history sample costs
  2.4–3.4 µs (object and dictionary); with the resolver's distance culling, an arrow costs 16 µs
  per tick with scattered candidates and 105–115 µs in a 20 × 20 m brawl, where everyone passes the
  culling: 20 arrows, 2.1 ms, and the p99 margin (15.9 ms with 64, plus the fort and F4's NPCs) is already
  spent. With whole-tick rewind, `position_at` and swept boxes by blocks (§4.4): 50–90 µs fixed per
  tick and 9–13 µs per arrow, dense or scattered (0.4 exact tests per arrow); one tick's `intersect_ray`,
  0.6 µs. Hence the reserve of **1 ms with 64 players** and the cap of **64 arrows per zone**
  (0.7–0.9 ms). H5 measures it under load (§7.3); if the tick p99 exceeds 16.7 ms, the player
  limit in networking.md §14 is lowered. A grid over the boxes could raise the cap. Real Terrain3D, not measured.
- **State size.** +42 B: 50 records instead of 52. If it keeps growing (PRG-06), the
  cooldowns of the stowed weapon can become u16 relative to the swap tick.
- **`simulate()`** is already the bottleneck (69–72 µs per character) and the machine grows a lot: it should be split
  (`ActionMachine` remains the entry point; abilities and consumables in `ability_rules.gd`).
- **Arrows seen late**: the victim sees the arrow in the past and its HIT arrives with it still in flight;
  with the 24-tick cap it is accepted, like melee.
- **Crosshair versus the canonical ray**: the smoothed follow (`follow_sharpness` 25) leaves the pivot up to
  v/25 m behind (0.2 m when running). If noticeable, the bow's reticle goes to the projected canonical point.
- **Animations**: bow, crawling and drawing the weapon are missing (§6.6); without ART-41 the bow looks bad.
- **Knocked down with latency**: reviving and executing are started by the server: whoever presses E sees a correction
  of 1 RTT, explained by INTERACT.
- **F4 and SOC**: no H package starts until they are merged (§7.1).

---

## 9. Out of scope

- **PRG-01** (`StatBlock`): not needed; health, stamina and dodge keep coming from `CombatRules` and
  the weapon. **PRG-06** (armor and load): armor 0. **PRG-04**: only the two weapons; armor
  slots, visual ids per slot and the derived sheet via reliable message arrive with PRG-06.
- Mana and staves (phase 6), choosing abilities or talents (PRG-19), persistence of weapons,
  cooldowns and effects (CMB-30), Eldrun scale for projectiles (CMB-36), statistical
  aim anti-cheat (CMB-39), INTERACT with world objects (MUN-16: the knocked down will have
  priority).
- Final models, clips, VFX, sounds and icons: the user's (ART-12, ART-41).

---

## 10. Review

Three reviewers (prediction and network, server and cheats, implementability): 42 findings on version
1, the repeated ones in one row. Checked against the code and the documents, all hold up; three are
resolved differently ("in part"). The two fixed changes (version 6; projectile caps with their
behavior and load test) go in PRE3 and SER2–SER3.

| Id | Severity | What it was | What was done |
|---|---|---|---|
| PRE1 · SER7 · IMP3 | blocking | The refill and `refill` used `set_loadout`: they changed the active weapon, zeroed the cooldowns and left an ABILITY with the wrong weapon | `set_charges` only touches the charges; `set_loadout` and `reset_for_respawn`, only on spawn and, on a living player, with NONE first (§3.5, §4.6); test in `test_consumables_server` |
| SER1 · SER9 · IMP2 | blocking | A knocked-down player who left escaped dying and being removed; `is_alive` and `is_dead` stopped being complementary and the code uses them as if they were | Every removal of a knocked-down player is first a death with DEATH and KILL; predicate table by place of use (§4.5); tests in `test_downed` |
| IMP1 | blocking | The canonical ray did not count the camera's `v_offset` of 0.1; absolute FOV; no inverse for bots | `aim_camera_v_offset` checked against the scene; zoom at 75% of the configured FOV; `AimRay.look_for` (§2.1, §4.4, §6.5) |
| PRE2 | important | Bit 3 of the record (slot 2) is `DEFENSE_BLOCKING` in the history | The history takes `flags & 0b111` and the comments say so (§3.6, §5.2); test in H3a |
| PRE3 · IMP5 | important | Version 5 already belongs to chat and parties; H2 and H4 collide with SOC | `PROTOCOL_VERSION = 6` (§5); all of H after F4 and SOC (§7.1); H2 marks "v6" in networking.md |
| PRE4 | important | No order among channel ends, buffer and edges, nor a rule for releasing on the commitment tick | 4a ends, 4b buffer, 4c edges; a channel that does not get past commitment spends nothing; the buffered one requires the button; examples in §3.3 and `test_ability_machine`; bots hold the button (H5) |
| PRE5 · IMP6 · IMP9 | important | H1 ∥ H2 was not possible, H1 without F4, §5.5 without a package, cheating modes in the server package, H1 and H3 too large | Packages H1a, H1b, H2, H3a, H3b, H3c, H4 and H5 with their dependencies (§7.1); §5.5 and `test_action_wire` in H1b; cheating modes and `test_bot_cheat` in H5 |
| PRE6 | important | The arrow goes from the chest to `P`; with a lead shot `P` falls in the background and the arrow deviates up to 0.59 m | Convergence at the depth of the hostile closest to the crosshair (`aim_converge_deg` 12); `look_for` for bots; test with the background at 150 m (§4.4, §7.3) |
| SER2 | important | The cost of arrows did not fit in a dense brawl; 256 per zone do not fit in the tick; `AimRay` not budgeted | Whole-tick rewind, `position_at` and swept boxes by blocks (measured: 9–13 µs per arrow); 1 ms reserve; **in part**: cap of 64 per zone, not 96, with what was measured; load test in H5 with a p99 criterion (§4.4, §8) |
| SER3 | important | With the zone full the shot was not created: denial of shot and phantom arrow | A shot is never rejected: the oldest of the shooter or the zone goes out, with DESPAWN 5 (§4.4); test in `test_projectiles` |
| SER4 | important | The owner in their gate's doorway shoots and hits from inside the vision body | First segment and `is_ray_clear` with `hit_from_inside`; corners sentence corrected (§4.4); tests in H3a and H3b |
| SER5 | important | Segments starting inside the wall or a capsule; effects of the wall's BLOCKED; instant of the wall | Fraction 0; BLOCKED like a block (no damage, 0.6 per point, guard break); the wall is tested at `k` (§4.4) |
| SER6 | important | Abilities did not remove spawn protection | Every ABILITY that is not a consumable removes it (§4.2); test in `test_ability_server` |
| SER8 | important | Reviving and executing without line of sight, also through the gate | `is_ray_clear` at the start and on every tick (§4.5); test in `test_downed` |
| PRE13 · SER10 · IMP11 | important | Orphaned arrows and effects when the author leaves | The projectile stores a copy of the author; on removal, DESPAWN 5 of their arrows and STATUS 2 of their effects (§4.1, §4.4) |
| SER12 · IMP8 | important | `NpcBrain` is not the fort's brain and F4 does not prioritize knocked-down players | `HfsmBrain` and `NpcWorld`; the priority is set by H3c and noted in fortress.md §4.2 (§4.5) |
| IMP4 | important | The projectile SPAWN used `is_yours` and `NetClient` discarded it as the player's own character | `is_yours` = 0 on kind 3; "yours" by `owner`; dispatch by `kind` (§5.3) |
| IMP7 | important | Tests over 30 s and a disabled rewind that does not exist | 900 + 180 ticks; H3 advances by hand and 40 shots; **in part**: counterfactual control in the same run, like `test_combat_loopback`, without a new switch (§7.3) |
| IMP10 | important | Deviations from CMB-21, CMB-23, CMB-24 and PRG-04 unnoted; PRG-04 and UI-45 without a test proving them | Row in §0 and a note in backlog.md; 0 corrections around SWAP and command 14's bleed in `test_loadout_net` |
| PRE7 | minor | The remote arrow was withdrawn at `despawn_tick`, up to 1.2 m before the impact; "f64" versus `Vector3` | Withdrawal at `despawn_tick + f` with the local ray; the same `Ballistics.position` with integer or fractional `n` (§4.4, §6.2) |
| PRE8 | minor | Looking at commitment once per physics tick loses prediction steps | `ClientPrediction.stepped` after each `step()`; test with two steps (§6.2) |
| PRE9 | minor | `pending_template_id` on a `Combatant` that does not exist before CLIENT_READY; `0x07` without dispatch | In `ServerPeer`, copied on registration; `0x07` case with the limiter (§4.6, §5.1) |
| PRE10 | minor | Replacing `buffered & 3` with `buffered_type()` without more broke `linked` and `_run_buffer` | Dispatch by type; `linked` = PRIMARY or link; expiry sets the combo to 0 (§3.1) |
| PRE11 | minor | The hash left out P fields (knocked down, interaction, `blocks`) | Every P field enters; test in `test_combat_catalog` (§2.2) |
| PRE12 | minor | The old block sample counted after returning to NONE from REVIVE, a potion or an interruption | It does not count if the action is not BLOCK and started after `view_tick`; changes combat.md §4.3 (§4.2); tests in H3a |
| SER11 | minor | Undefined which impact interrupts and what "drinking" is; a knock-down in the middle of the pulses | Defined (§0, §4.2); `StatusSystem.step` gathers the pulses before applying them (§4.1, §4.3) |
| SER13 | minor | Any template selectable, undefined id 0, command 15 with its own `downed_by` | `selectable` and validation without `npc_*`; 0 = default; command 15 with `downed_by = 0`, only in RVR (§2.1, §4.5, §5.1) |
| IMP12 | minor | LOADOUT revealed the charges to enemies | `charges` = 0 for whoever is not the owner (§5.4) |
| IMP13 | minor | No stamina column; a lone attacker does not break the wall; exhausted cannot draw | **In part**: stamina paragraph (§2.4); the wall that one attacker cannot break is on purpose and H5 measures it; exhaustion preventing the draw and the wall, written down |
| IMP14 | minor | `downed`, `swap` and a provisional bow were missing | `Death01`, `Crouch_Fwd_Loop`, 0.4 s fade and bow in `WeaponProps`; items pending from the user marked (§6.6) |
| IMP15 | minor | A 2 µs bound in a test | Deterministic call counter; the micro-benchmark, informational in `tools/combat_balance.gd` (§7.3) |

---

## 11. Implementation

What each package did, its deviations from this document (which was written before merging F4, F6a,
F6b and chat and parties protocol 5) and what was measured.

### 11.1 H1a · state and data

**Done.**

- `CombatState` v5 (`scripts/shared/combat/combat_state.gd`): actions 9–13 (ABILITY, SWAP, DOWNED,
  REVIVE, EXECUTE), `ENCODED_SIZE` 76, the fields of §3.1 at their offsets (`alt_weapon_id`,
  `combat_flags2`, `ability_ready` as a `PackedInt64Array` of 6, `consumable_ready_tick`,
  `consumable_charges`, `move_effect_ids` and `move_effect_until`), `initial(rules, weapon, alt_weapon,
  charges)`, `copy_from` element by element (the `Packed*Array`s are passed by reference: verified
  in 4.7.2), `buffered_type()`/`buffered_ticks()` with the new format, `charges_of()`,
  `is_second_slot()` and the `FLAG2_*` and `BUFFER_*` constants (4–9). `PlayerState` goes to 111 B.
- `PlayerInput`: `SWAP_WEAPON` (bit 9), `AIM_LEFT` (10), `CONSUMABLE_1` (11) and `CONSUMABLE_2` (12).
- New resources `AbilityDefinition`, `StatusEffectDefinition`, `ProjectileDefinition` and
  `EquipmentTemplate`, with their `AbilityTicks`, `StatusTicks` and `ProjectileTicks`; `AttackDefinition`
  gains `projectile`, `projectile_speed_mps`, `charge_speed_scale`, `stun_s` and `on_hit_status` (and the
  shape can be null with a projectile); `WeaponDefinition`, `abilities` and `can_block` (the light combo
  allows 1 to 3 hits); `CombatRules`, all the fields of §2.1.
- `CombatCatalog`: six id spaces in alphabetical order, all requested by name
  (`ability_id`, `status_id`, `projectile_id`, `template_id`); `ability()`, `status()`,
  `projectile()`, `template()`, `template_count()`, `consumable_ids()`; owner of each ability
  (weapon and slot or consumable), synthesized hit with the ability's source as id, dashes
  baked like the dodge, the validation of §2.2 and the hash with `_HASH_FORMAT` 2.
- `CombatSource` (`make`, `kind_of`, `id_of`, `EXECUTE`, `BLEED_OUT`) and `Ballistics` (`position` with
  integer or fractional `n`, `quantize` to 1 cm and 1 cm/s with `NetMath`, like the SPAWN).
- Data from §2.3 in `data/combat/`: `shield_bash`, `shield_rush`, `shield_wall` (in the slots of
  `sword_shield.tres`) and their two shapes; `bow`, `bow_quick`, `bow_drawn`, `bow_volley`,
  `bow_slowing_shot`, `bow_evasive_shot`; `arrow`; `potion_health` and `potion_stamina` (the
  rules' `consumables`); `slowed`, `potion_regen`, `bleed`, `rooted`; `squire` (the
  `default_template`) and `marksman`.
- backlog.md: the four decisions of §0 and the deviations from CMB-21, CMB-23, CMB-24 and PRG-04 were already
  noted when this design was closed; H1a adds the "Done (H1a)" notes for what it leaves done.

**Tests.** `test_combat_state_v5` (new, 12: offsets of each new field inside `PlayerState`,
76 and 111 B, round trip, u32 of the ticks, the new `buffered` and the dodge stored with it,
`initial`, charges, active slot, array copying, `equals` and reconciliation notice each field,
`reset_for_respawn`); `test_combat_catalog` (from 25 to 35: the six id spaces by name, the
sword-and-shield and bow kits, potions, effects, templates and rules in ticks, the synthesized
hit, each error from §2.2, the effect and template ids in u8, the hash with 47 predicted
changes —ability timings, `downed_move_scale`, `revive_s`, `blocks`, aiming, effects,
arrow…— and 27 server-only ones —damage, shapes, control effects, pulses, knocked down, walls, caps and
templates— and the fast path of `simulate()` without looking up a weapon or abilities, with the
`weapon_lookups` and `ability_lookups` counters of `CombatTables`); `test_ballistics` and `test_combat_source`
(new, 6 and 3); `test_player_input`, `test_combat_state`, `test_player_state`, `test_net_entity`,
`test_net_messages` and `test_snapshot_builder` adapted to 111 B and the new `buffered`.

**Deviations and decisions.**

- **`consumables`: 0 or exactly 2.** Rules without potions (`CombatRules.new()`, those of the
  tests that build catalogs by hand) are valid; with any, there must be two. The real catalog
  carries both (tested by `test_combat_catalog`). Same for `default_template`: it may be null
  (`default_template_id()` = 0) outside `data/combat/`.
- **Gaps and loose abilities.** A `null` in `WeaponDefinition.abilities` is an empty slot (a
  weapon can carry only the 3rd). An ability that no weapon carries and is not a consumable is valid
  (slot −1, weapon 0) and cannot be used.
- **Extra validations**: the active phase lasts at least one tick (the commitment's, also in a
  channel); a consumable carries `interrupt_on_damage` (§2.1: "always true"); a
  projectile's speed ≤ 327.67 m/s (it travels in an s16 of cm/s), also at maximum charge; ids of attacks and abilities
  in 14 bits (the source); a template carries one or two weapons and two charges from 0 to 15.
- **Values that §2.3 does not fix**: null `dash_curve` = flat (the rush); the backflip brakes from 1 to
  0.4 in its window; the draw cancels to dodge from its recovery (tick 4) and, like the quick shot,
  moves ×0.5 and turns 8 while shooting; the three bow abilities, ×0.5 and turn 8; the potions,
  turn 6; `rooted` refreshes; the new shapes go from 0.2 to 2.0 m tall, like the sword's.
- **`buffered` and the machine.** Changing the format forces touching `ActionMachine`: `_run_buffer`
  dispatches by type (1 and 3 light, 2 dodge; types 4–9 it discards until H1b, and nobody
  stores them), `linked` is PRIMARY or link (§3.1) and the expiry of any type with the light attack already
  finished sets `combo_step = 0`. The only behavior change is a corner case: a dodge
  buffered in the air that replaced the press that linked and expires restarts the combo (before it
  left it half-done). `test_action_machine` still passes in full (73).
- **`reset_for_respawn(c, tick)`** keeps its signature until H1b: it now stores both weapons, the active
  slot, the charges and the held buttons of `combat_flags2`, and zeroes cooldowns and
  movement slots.
- **Protocol.** `PROTOCOL_VERSION` stays at 5 and `VALID_BUTTONS` at bits 0–8 until H2: the state
  format is already the 111 B one on both sides and the new hash changes the `sim_hash`, so an
  earlier client cannot enter. `test_snapshot_builder` and `test_net_messages` already check the 50
  records of §3.1 (134 B header, 1186 B full); the builder's property test
  gives its observer C 30 relevant entities instead of 40 so that, with the 15 that enter, they all still fit
  in 50 slots (before it was 52).
- **Extra helpers**: `CombatState.pack_buffer`/`pack_charges`, `CombatCatalog.template_weapons`/
  `template_charges`/`default_template_id`, the rules' durations in ticks in `CombatTables`
  (`swap_ticks`, `revive_ticks`, `execute_ticks`, `consumable_cooldown_ticks`, `downed_ticks`),
  `CombatSource.name_of` (for H3a's combat log) and queries on `AbilityTicks` and
  `StatusTicks` (`is_dashing`, `dash_speed_at`, `is_movement`, `has_pulses`, `is_harmful`).

**Measured** (shared machine, 4 cores with other jobs; indicative): `PlayerState.encode`
2.3–3.2 µs, `PlayerState.decode` 18–22 µs, `CombatState.duplicate_state` 6–7 µs, `copy_from`
1.8–2.6 µs, `CombatState.new` 4.2–4.7 µs (the three arrays add ~1.4 µs per state, measured separately
against an identical object without them) and the fast path of `ActionMachine.step` 3.3 µs. The decode
still creates a throwaway initial `CombatState` (the default value of `PlayerState.combat`); it is
not touched here.

**For the following packages.** H1b: the behavior of §3 (machine, `ActionWire`, `simulate` with
`speed_factor` and `rooted`, `AimRay`, `Ballistics.solve_lead`, `HitShapes` fractions, `DamageFormula`
modifiers) and the new signature of `reset_for_respawn`/`set_loadout`; the fast path must keep
not touching the `CombatTables` counters. H2: `PROTOCOL_VERSION` 6, `VALID_BUTTONS` up to bit
12 and networking.md. H3a: `_hide_private_state` with the new fields (today the others' SPAWN sets them to their
initial value because nobody fills them in yet).

### 11.2 H1b · machine

**Done.**

- `ActionMachine` (§3.3 to §3.6) split in two: input and the phase 3 parts remain in
  `action_machine.gd`; abilities, consumables, channels, weapon swap, reviving and executing,
  knocked down and movement effects, in `ability_rules.gd` (`AbilityRules`, which only the
  machine calls). The fixed order of §3.3: 0 fast path (also without ABILITY, SWAP or CONSUMABLE pressed
  nor in `combat_flags2`, and with both movement slots free; it still does not look up a weapon or
  abilities), 1 end of actions (ABILITY, channel at the cap with its cooldown, SWAP, REVIVE,
  EXECUTE; DOWNED and DEAD do not end), 2 slot expiry, 3 stamina (not in the channel
  that blocks), 4a ends by input, 4b the buffer dispatched by type, 4c the edges by priority,
  5 commitment and 6 movement (table of §3.4 and `Output.speed_factor`/`rooted`).
- What the server enforces (§3.5): `impose_downed`, `impose_revived`, `impose_interact`,
  `impose_interrupt`, `impose_move_effect`, `clear_move_effects`, `reset_cooldowns`, `set_charges`,
  `set_loadout` and `reset_for_respawn(c, tick, weapon_1, weapon_2, charges)`; `impose_stagger` and
  `impose_stun` do nothing on DOWNED or DEAD, and all those that change the action set the
  cooldown of the committed channel they cut.
- Queries (§3.6): `phase` with the ABILITY phases, `active_hit`, `is_commit_tick`,
  `ability_status` (with `AbilityStatus` and the `STATUS_SLOT_CONSUMABLE_1`/`_2` slots),
  `defense_flags` with `DEFENSE_WIDE_BLOCK` (bit 7) in the channel that blocks, `is_blocking` and
  `action_byte` with the slot (3 = consumable) in bits 6-7. The comments of `ActionMachine`
  say that the history byte is `(flags & 0b111) | defense_flags` (the masking is H3a's).
- `ActionWire.has_counter` counts SWAP (§5.5).
- `PlayerCharacter.simulate`: the non-enforced target speed is multiplied by `speed_factor`
  (also sprint and the advance of attacks) and a rooted player neither jumps nor keeps momentum in the
  air.
- `AimRay` (`canonical`, `aim_point` with the convergence from §4.4, `muzzle`, `look_for`),
  `Ballistics.solve_lead`, `HitShapes.segment_capsule_fraction` and `segment_box_fraction` (0 if the
  segment starts inside, -1 if it does not touch) and `DamageFormula.compute(..., damage_scale,
  mitigation_penalty)`.
- `CombatDirector`: respawn uses the new signature; until templates (H3c) it respawns with the
  weapons it carried, in their slot order (active one is 1), and their charges.
- Phase 4 notes in combat.md §3.3 (the extended and split machine) and §3.4 (the new signature of
  `reset_for_respawn`); "Done (H1b)" notes in backlog.md.

**Tests.** New: `test_ability_machine` (24: edge, commitment and cooldown also with
`cast = 0`, usable again at `ability_ready` and not before, stagger during the cast without
cooldown, stagger, stun and death cut a channel and set its
cooldown, releasing, moving with the data, the cap and substituted inputs, the examples of §3.3, the buffered
wall with the button held, priorities with simultaneous edges, buffer in the recovery of a
light attack and the expiry that restarts the combo, substitutes that invent nothing, cancel to dodge,
ground and actions that allow it, empty slot, exhaustion and wall, command 13, queries,
regeneration in the wall, the dash of the rush and of the backflip, knocked down, reviving and
executing), `test_ability_reconciliation` (2: the cooldown survives a reconciliation caused by a
server push after commitment, with the state equal byte for byte, and a rejection returns it to
0), `test_weapon_swap` (7, with the swap predicted and reconciled with a substituted input around
the edge), `test_move_effects` (6, with slow equal on client and server at
`run_speed · 0.6` and its expiry on the exact tick), `test_consumables_machine` (6),
`test_bow_machine` (5) and `test_aim_ray` (5: the canonical ray is that of `CameraRig.get_aim_ray()` within
1 mm with five combinations of yaw, pitch, shoulder, arm and FOV; the rules are those of
`camera_rig.tscn` and `player_character.tscn`; lead shot with the background at 150 m: 0 mm versus
0.5 m without convergence; `look_for` within 1 mm). Extended: `test_action_wire` (+2: slot and
phase of ABILITY, consumable, SWAP counter), `test_hit_shapes` (+2: fractions, consistent with
`segment_hits_capsule` on 200 segments), `test_damage_formula` (+1) and `test_ballistics` (+1:
`solve_lead` within 2 cm of a moving target). Adapted to `reset_for_respawn` with
equipment: `test_action_machine` and `test_combat_state_v5`. Helpers: `tests/machine_driver.gd`
(`MachineDriver`, the machine without physics with two weapons and charges) and `tests/prediction_pair.gd`
(`PredictionPair`, a client with the real `ClientPrediction` and a server with the substitution rule
in two worlds, with whatever the server imposes in a hook).

**Deviations and decisions.**

- **Simultaneous edges.** They are processed in priority order: the first that can, starts, and those
  that cannot go to the buffer; as today with DODGE + PRIMARY, a lower-priority one from the same tick
  replaces in the slot one of higher priority (the last press wins). DODGE + ABILITY_1 from NONE
  dodges and leaves the ability in the buffer.
- **Substituted inputs.** Edges with `SUBSTITUTED` are not ignored: as in combat.md §3.2, the substitute
  repeats the buttons and does not create them. What the bit does affect is 4a (a substitute neither releases a
  channel, reviving or executing nor breaks it by moving).
- **Commitment of a channel.** "Committed" is `t > action_tick + cast` when the
  machine itself ends it within the tick (4a, 4c, cap: releasing or dodging on the commitment tick
  cancels it) and `t ≥ action_tick + cast` when the server cuts it (it imposes after simulating the tick, and that tick's
  commitment has already happened).
- **ROOT.** A rooted dodge is discarded (it does not go to the buffer and does not warn about stamina), like an
  ability with a dash; a dash or dodge already in progress continues (the enforced speed is not
  scaled, §3.4).
- **Buffered channel.** With `channel_hold`, it is discarded as soon as the buffer sees it with the button
  released, not only when about to start (the result is the same and it does not occupy the slot).
- **An exhausted wall** is discarded with the stamina warning (bit 1), like the charge.
- **Stamina potion.** Besides the +400, it takes you out of exhaustion at commitment if it exceeds the
  threshold (otherwise it waited for the regeneration delay).
- **Stamina in the wall.** It does not regenerate during the same window in which it blocks (from the end of the
  cast); since regeneration comes before the inputs, the tick on which it is released does not yet
  regenerate.
- **Turning.** The first tick of an ability snaps to `look_yaw` even if the dash starts on it
  (the backflip: faces the camera and jumps backward); in the dash window it does not turn, and
  `lunge_speed` applies in the cast and the active phase, not in the channel.
- **PRIMARY from ABILITY** from `min(recovery, cancel_to_attack_from)` (the same rule as
  ABILITY_n); SWAP from ABILITY, only in recovery. A SWAP that comes out (from the buffer or from the edge)
  changes the weapon with which the rest of that tick's inputs are examined.
- **`set_loadout`** on a dead player only changes the equipment; on a living one it forces NONE and clears buffer,
  press and combo; it keeps bit 7 (command 13). `reset_for_respawn` does not keep it, like infinite
  stamina. `impose_revived` and `impose_interact` also clear buffer, press and
  combo; `impose_interact` with another action does nothing.
- **`ability_status`**: slots 0-2 (abilities of the active weapon) and 3-4 (consumables); order EMPTY,
  NO_CHARGES, COOLDOWN, BLOCKED, READY; it does not look at the ground (it is not in `CombatState`).
- **`active_hit`** returns the synthesized hit also in the channel (without a shape, it tests
  nobody).
- **`AimRay.look_for`** is a closed-form solution instead of 3 fixed-point iterations: in the camera's
  basis the point is at `(±s, v, −t)` from the pivot, the pitch comes from the height and the yaw from the
  angle in plan view. It is exact without depending on the number of steps (the 3 iterations were also enough:
  0.03 mm at 2 m, verified separately); if the point is closer than `√(s² + v²)` to the pivot, it aims
  from the pivot. `aim_point` with null `space` = no
  world; a hostile's center is feet + 0.9 (`HitShapes.LINE_OF_SIGHT_TO_HEIGHT`).
- **`Ballistics.solve_lead`**: 16 fixed-point steps over the flight time (deterministic).
- **`DamageFormula`**: `mitigation_penalty` subtracts (`max(block_mitigation − p, 0)`); a negative
  `damage_scale` counts as 0. Without effects (1 and 0) the result does not change.
- `HitShapes.is_ray_clear` with `hit_from_inside` is left for H3a, as §7.1 says.
- With H1b abilities 1–3 are already used with their keys (ABILITY_1–3 were already in `VALID_BUTTONS`):
  the server simulates them (movement, cooldown, the wall's block as a phase 3 block)
  without hits, effects or projectiles until H3. Weapon swap and potions wait for H2's `VALID_BUTTONS`
  and their keys (H4).

**Measured** (indicative: shared machine, 4 cores with other jobs; `ActionMachine.step`,
20,000 ticks): fast path 3.8 µs; a light attack 14 µs; the shield bash 17 µs; the held wall
23 µs; standing still and slowed 17 µs (it leaves the fast path, as rule 0 dictates).

**For the following packages.** H2: `VALID_BUTTONS` up to bit 12 and `PROTOCOL_VERSION` 6.
H3a: `active_hit` in `Combatant.freeze` and the resolver, `impose_move_effect` from `StatusSystem`,
`impose_interrupt` (§4.2), the masked history byte, the `DamageFormula` modifiers,
`is_ray_clear` from inside and the protection an ABILITY loses. H3b: `ProjectileSystem` with
`is_commit_tick`, `AimRay` and the fractions. H3c: `DownedSystem` with `impose_downed`,
`impose_revived`, `impose_interact` and `impose_interrupt`; templates with `set_loadout` and
`reset_for_respawn` (they replace the weapons it carried in `CombatDirector`) and the refill with
`set_charges`. H4: `ClientPrediction.stepped` with `is_commit_tick` and the bar with `ability_status`.
H5: bots with `solve_lead` and `look_for`.

### 11.3 H2 · protocol 6

**Done.**

- `NetProtocol`: `PROTOCOL_VERSION` 6 (with its line in the version history), `VALID_BUTTONS` = bits
  0–12 (`SWAP_WEAPON`, `AIM_LEFT`, `CONSUMABLE_1` and `CONSUMABLE_2` travel; bits 13–14 and the
  substituted mark do not), `MSG_LOADOUT_SELECT` (`0x07`, reliable channel), commands 13 `cooldowns_off`, 14
  `apply_status`, 15 `down` and 16 `refill` in `DEBUG_COMMAND_IDS` and `DespawnReason.IMPACT` (4) and `EXPIRED`
  (5).
- `NetMessages`:
  - `LoadoutSelect` (2 B).
  - `DebugCommand`: validates the data of 13 to 16 in `decode` (13, `u8` 0 or 1; 14, `u8 status_id` from 1
    to 255 and `u16` ticks; 15 and 16, no data), with `cooldowns_off()`, `apply_status()`,
    `get_status_id()` and `get_status_ticks()`.
  - `EntitySpawn` of kind 3 (§5.3): 32 B, `for_projectile()`, `is_harmless()` and the fields `owner_id`,
    `projectile_def_id`, `source`, `volley_index`, `projectile_flags`, `origin` (`p0`) and `velocity`
    (`v0`), quantized like `Ballistics.quantize` (checked by the test).
  - `EntityEvent`: STATUS (7), HEAL (8), LOADOUT (9), DOWNED (10) and INTERACT (11) with their exact
    sizes, `StatusOp`, `InteractOp`, their constructors and `get_source()`; bits 5
    (`HIT_FLAG_INTERRUPTED`) and 6 (`HIT_FLAG_DOWNED`) of a HIT.
  - `STATUS_DOWNED` (bit 3 of the `status` of the extra block and of PARTY_STATUS), `Snapshot.is_downed()` and
    `PartyStatus.MemberStatus.is_downed()`.
- `EntityRecord`: `FLAG_SECOND_SLOT` (bit 3 of `flags`), `is_second_slot()`, `HISTORY_FLAGS_MASK`
  (`0b111`); `encode_character` and `from_state` set the bit from `CombatState.is_second_slot()`.
- Client: `NetClient._on_spawn` looks at `kind` before `is_yours` and delivers projectiles through the
  new signals `projectile_spawned` and `projectile_despawned` (the DESPAWN of an id that arrived as a
  projectile goes to its own); `is_own_event` recognizes events 7–11 (timing from §5.4); `RemoteWorld`
  and `SwarmBot` ignore kind 3.
- Documentation: networking.md (catalog of §5.2 with the "v6" rows and the legend, version in §5.3, buttons,
  commands and LOADOUT_SELECT in §5.4, 134 B header, 50 records, bit 3 of `status` and of
  `flags`, others' SPAWN, PROJECTILE, DESPAWN reasons, events 7–11, HIT bits and sources in §5.5,
  guarantee in §9.3, buttons in §12, budget in §14 and contracts in §17.3 and §17.5); protocol 6
  note in combat.md §6; the knocked-down bit of PARTY_STATUS in social.md §12.4; "Done (H2)" notes in
  backlog.md.

**Tests.** New `test_net_messages_v6` (17: constants and channels; the new buttons arrive in an
INPUT_BATCH and bits 13–15 do not; LOADOUT_SELECT; commands 13 to 16; projectile SPAWN with each offset, the
`is_yours` at 0 even if set, the ballistics equal to `Ballistics.quantize`, saturation and malformed ones;
DESPAWN 4 and 5; STATUS, HEAL, LOADOUT, DOWNED and INTERACT with their offsets, `op` out of range and applied
STATUS without stacks; inconsistent lengths; bits 5 and 6 of HIT and the six source classes in
HIT, DEATH, KILL, HEAL and DOWNED; bit 3 of the record from the state and from the character; bit 3 of the snapshot's
status; the player SPAWN with the exact 111 B; malformed and *fuzz* of 8000 buffers).
`test_net_messages` gains the new messages in its examples (malformed, single decoder per type and
*fuzz*). `test_snapshot_builder` (+1): bit 3 of the record of whoever carries slot 2 and the knocked-down state in
the extra block, without exceeding 1200 B (the 50 records were already checked since H1a). `test_net_client`
(+1): projectiles via their signal, own and others', without remote views or touching the local character; DESPAWN
4 and 5 via their own; own STATUS and LOADOUT on arrival and others' DOWNED on their draw tick; an arrow id
that comes back as an entity creates its view. Adapted: `test_net_messages` (version 6, `VALID_BUTTONS`
0x1FFF, 16 commands, event 12 is the unknown one, PROJECTILE now has a format), `test_net_messages_v3`
(the projectile has a format; 13 is now validated), `test_party_messages` (bit 3 is knocked down; the
unknown one becomes 4), `test_command_registry` (16 ids), `test_input_queue` (text) and
`test_combat_server` and `test_hfsm_brain` (the four new commands still without a handler).

**Deviations and decisions.**

- **Commands 13 to 16.** H2 leaves their ids, the table and the validation in `decode`; the handlers belong to
  H3a (13 and 14) and H3c (15 and 16), as §7.1 says. Meanwhile, the server accepts them without warning or effect
  (the rule in networking.md §5.4 for a fixed id without a handler) and `missing_network_commands()` lists them:
  `test_combat_server` and `test_hfsm_brain` expect those four and H3a and H3c will be removing them. 14 requires
  `status_id` ≥ 1: 0 is no effect.
- **LOADOUT_SELECT on the server** belongs to H3c (with `ServerPeer.pending_template_id`); until then a
  `0x07` counts as "unexpected message type". Nobody sends it yet (the selector is H4's).
- **Projectile header flags, entirely 0**, not only the `is_yours` bit: a projectile does not
  teleport. `decode` rejects any header flag and `proj_flags` bits that do not
  exist.
- **Bit 3 of the record is already published.** The record is written from the character when building the snapshot
  (`EntityRecord.encode_character`), not in a separate step, so §7.1 ("publication of bit 3", H3a)
  is done here. The history does not receive it: `ZoneServer._record_history` (and `combat_fixture`)
  compose their bits 0–2 by hand and do not read the record, so the slot 2 bit is never confused with
  `DEFENSE_BLOCKING`; `HISTORY_FLAGS_MASK` remains so that H3a writes it explicitly. In practice it comes out as
  0 until the two-weapon templates (H3c).
- **PARTY_STATUS accepts bit 3.** It is the same status byte as the extra block (`NetEntity.status`):
  without adding it, `encode` would have dropped it and `decode` would have rejected the message of a party with a
  knocked-down member as soon as H3c publishes it. Bit 4 is still unknown.
- **The source stays in `EntityEvent.attack_id`.** Renaming the field touched the whole client; HEAL and DOWNED
  store their `source` there and `get_source()` returns it for the six events that carry it (0 for the
  others). STATUS and INTERACT share the `op` field (with `StatusOp` and `InteractOp`). A removed STATUS
  can carry 0 stacks; an applied one, no. `encode` saturates the stacks to 255 and the healed
  amount to u16; LOADOUT and HEAL ids are not validated on decode (there is no catalog in the message).
- **Client.** The `projectile_spawned` and `projectile_despawned` signals (contracts in §7.2) already come out of
  `NetClient`, so that H3b's kind 3 SPAWN never reaches `RemoteWorld`, the name directory
  or the own registration; `ProjectileWorld` (H4) only has to connect. An id that comes back as an entity stops
  counting as a projectile (they share an id space). `is_own_event` already decides the timing of
  events 7–11 (§5.4); what they explain in prediction (`_note_imposed_state`) is H4's.
- **Tests in their own file**, `test_net_messages_v6.gd`, as protocol 3 did with
  `test_net_messages_v3.gd` (`test_net_messages.gd` is already over 2200 lines); the `test_net_messages`
  filter runs all three.

**Measured.** The sizes are those in the document (projectile SPAWN 32 B, STATUS 18, HEAL 15, LOADOUT 15,
DOWNED 13, INTERACT 16, LOADOUT_SELECT 2, 134 B header and 50 records in 1186 B). The 93 message
tests (the three files) take ~1.3 s without engine startup; their three *fuzz* tests (10,000, 8000 and 8000
buffers) ~0.1 s each.

**For the following packages.** H3a: handlers for 13 and 14 (and remove them from the expected list in
`test_combat_server` and `test_hfsm_brain`), `_hide_private_state` with `alt_weapon_id` and bit 0 of
`combat_flags2`, `EntityRecord.HISTORY_FLAGS_MASK` in `_record_history`, STATUS and HEAL with
`EntityEvent.status`/`heal`, `HIT_FLAG_INTERRUPTED` and the `CombatSource` sources in HIT, DEATH and KILL.
H3b: `EntitySpawn.for_projectile` and `DespawnReason.IMPACT`/`EXPIRED` (`NetClient` already dispatches them). H3c:
LOADOUT_SELECT in `ZoneServer` (reliable-message limiter, LOADING and IN_WORLD), LOADOUT, DOWNED, INTERACT,
`HIT_FLAG_DOWNED`, `STATUS_DOWNED` in `Combatant.status_bits` and commands 15 and 16. H4:
`ProjectileWorld` connected to `NetClient`'s signals, the explanations in `_note_imposed_state`, the
selector that sends LOADOUT_SELECT and the keys that set bits 9 to 12.

### 11.4 H3a · abilities and effects on the server

**Done.**

- **Tick order** (§4.1) inside `CombatDirector.process_tick`, with the steps numbered in the code
  and in the `ZoneServer` header: 2 freeze, 3 own commitment effects, 4 resolve, 5 apply,
  6 status effects, 7 knocked down (empty until H3c), 8 environment and respawns (camp
  refill, empty until H3c), 9 publish. The shots of step 3 and the flight of step 4 are H3b's.
  Note in fortress.md §1.7.
- **Synthesized hit.** `Combatant.Frozen` gains `hit` (`ActionMachine.active_hit`: the active attack or the
  ability's synthesized hit), `commit` (`is_commit_tick`), `wall` and `wall_half_extents` (the shield wall's
  box while blocking; a `Transform3D` cannot be null, so the box is valid if the
  half-extents are not zero). `attack_active` is `hit != null` and `hyper_armor` comes from the hit (the rush's hyper
  armor in its active phase). `CombatResolver.resolve` tests `frozen.hit` instead of looking up the attack by
  `action_id`: rewind fixed on the first active tick, candidates, shape, line of sight, defenses
  and gates, the same as an attack; its `id` is the ability's source, so HIT, DEATH and KILL already
  carry it with no code of their own, and the combat log writes its name.
- **Hit control effects.** `_apply_hit_controls` stuns if the hit carries `stun_ticks` (the shield bash)
  and otherwise staggers and pushes (radial from the attacker, as today), with the usual hyper armor and chain of
  control effects. `unblockable` already skipped parry and block.
- **`StatusSystem`** (`scripts/server/status_system.gd`, §4.3): `ActiveEffect` (`status_id`,
  `source_id`, `anchor_tick`, `until_tick`, `stacks`) in `Combatant.effects`, up to 8 per entity and
  sorted by id; `apply` (REFRESH, STACK, STRONGEST; SLOW and ROOT write their movement slot with
  `impose_move_effect` and pass the state through `encode/decode`), `step` (exact pulses gathered before
  applying them; damage ones are applied by the director as a HIT with the effect's source and healing ones
  heal without exceeding the maximum with HEAL; then, the expiries with STATUS 2), `clear` (on death and on
  respawn, without events, emptying their movement slots), `forget_author` (when an
  entity is removed, STATUS 2 for what it applied to others, with `CombatDirector.remove(net_id, tick)`), `heal`, `find` and
  the modifiers `damage_scale` (1 + Σ DAMAGE_UP of the attacker) and `mitigation_penalty` (Σ
  MITIGATION_DOWN of the victim) that `_apply_impact` and the pulses pass to `DamageFormula.compute`. Each
  `Combatant` stores in `effects_due` the first tick at which something happens to it (a pulse or an expiry) and the
  system the smallest of all: a tick with no events visits nobody, and one with events skips whoever
  has nothing. Each effect stores its `StatusTicks` (it is not looked up in the catalog).
- **Own effects and on the target.** Step 3: whoever is on an ability's commitment applies to themselves their
  `self_status` (the health potion's healing, with themselves as author) and their `self_heal` (HEAL with the
  ability's source). Step 5: an ability's `target_status` and an attack's `on_hit_status` are
  applied on an IMPACT (not on a block or a parry) to whoever is still alive.
- **Interruptions** (§4.2): an IMPACT with damage > 0 from a hostile attacker (the resolver only gives hits from
  hostiles; pulses and the environment do not go through here) to whoever is in the cast of a consumable or
  of an ability with `interrupt_on_damage`, or in REVIVE or EXECUTE, imposes `impose_interrupt` and sets
  bit 5 of the HIT, if the hit has not already imposed a control effect. `CombatDirector.is_interruptible` is public
  (H3b uses it with arrows and H3c with reviving and executing).
- **Melee shield wall.** The resolver chooses the cone per sample: with
  `DEFENSE_WIDE_BLOCK`, `ability_block_angle_deg` (180°); otherwise, the weapon's. `Hit.wide_block` tells the
  director to charge `ability_block_stamina_per_damage` (0.6) instead of the weapon's cost; the mitigation is
  the weapon's (1 on sword and shield). Without stamina, the guard break stuns and cuts the
  channel with its cooldown (`_leave_imposed` from H1b).
- **Spawn protection**: it is also removed by an ABILITY that is not a consumable
  (`_started_attack`); drinking, SWAP, REVIVE and EXECUTE do not (EXECUTE does since the §11.10 review).
- **Old sample** (§4.2): `_dropped_guard_after` discards the `view_tick` sample if the frozen
  action is not BLOCK and its `action_tick > view_tick`, whether NONE or not. Note in combat.md §4.3.
- **`HitShapes.is_ray_clear`** with `hit_from_inside = true`: from the closed gate's doorway you neither
  hit outward nor get hit.
- **History byte** (§3.6): `ZoneServer._record_history`, `Combatant.freeze` and
  `CombatFixture.record` compose `(record flags & EntityRecord.HISTORY_FLAGS_MASK) |
  defense_flags`; the comments of `StateHistory`, `ActionMachine` and `ZoneServer` say so.
- **`NetEntity._hide_private_state`**: the others' SPAWN carries `alt_weapon_id` and bit 0 of
  `combat_flags2`; cooldowns, charges, consumable, movement slots and the rest of
  `combat_flags2`, at their initial values.
- **Publication of bit 3**: H2 already did it when writing the record from the character; H3a checks it on
  a server (record with the bit, history without it).
- **`InputQueue.get_applied(tick)`**: the input that was simulated on that tick (real, or the substitute even if
  the real one arrived later, late); null if not yet consumed or already out of the ring.
- **Commands 13 and 14** in `ZoneServer`, over the network and from the console: `cooldowns_off <player> [on|off]`
  (`CombatDirector.set_cooldowns_off`, bit 7 of `combat_flags2`) and `apply_status <player> <effect>
  [ticks]` (`CombatDirector.apply_status`: without author, on the tick the server is about to simulate, with the
  requested duration or the data's). `missing_network_commands()` now only gives `down` and `refill`.
- **Combat log**: `CombatDirector._log_line` writes the "ataque" column with the source's
  name (`CombatSource.name_of`); new result `pulse` (a damage pulse). `arrow_hit`,
  `arrow_blocked` and `wall_blocked` are H3b's; `downed`, `executed`, `bled_out` and `revived`, H3c's.
- **Report**: new counters of the director (`interrupts`, `pulse_hits`, `heals`) and of `StatusSystem`
  (`status_applied`, `status_removed`, `pulses`, `healed`).

**Tests.** New: `test_ability_server` (9: the shield bash stuns for 48 ticks from the front even if the
target has the shield raised, does not hit the one behind and hits once per action; the rush covers 6 m in
its dash window and pushes with 6 m/s radial and its stagger; the wall blocks at 85° and not at 95°, charges 0.6
per point and a normal block does not stop the 85° one; the wall's break stuns and sets its cooldown; a bot
that presses the shield bash one tick out of two commits exactly every `cooldown + cast` = 738 ticks
and lands one hit per commitment, and with command 13 comes out again right away; an ability removes
protection and drinking or swapping weapons does not; a hit interrupts drinking before commitment (bit 5, without spending
charge or cooldown, keeping the `action_tick`), not after, cuts reviving and is not marked if it already
imposes a control effect; the old sample does not count after a released REVIVE or an interrupted potion and does
when simply releasing the shield; active slot 2 appears in the record and not in the history, and the others' SPAWN
shows both weapons; from the doorway of a closed gate you neither hit nor get hit, and rotated you do) and
`test_status_effects` (10: a bleed produces exactly 6 pulses at `anchor + 60k` with STATUS 1 and 2 and its
`until_tick`, the last pulse before the expiry; stacking, refreshing and the strongest with the
movement slot; healing does not exceed the maximum; a pulse does not interrupt; a pulse that kills halfway through
the list does not change what is traversed; cleanup on death and respawn without STATUS; STATUS 2 when the
author leaves; the movement slots and the ninth effect; more damage and less mitigation; the pulse in the combat
log). Extended: `test_combat_server` (+1: commands 13 and 14 over the network and console, and the
bleed without an author that pulses at `anchor + 60`; the list of commands without a handler), `test_hfsm_brain`
(the list of commands without a handler), `test_input_queue` (+1: `get_applied`), `test_net_entity` (+1: the
others' SPAWN with both weapons and without the abilities' state) and `test_hit_shapes` (+1: a ray that
starts inside a body is not clear).

**Deviations and decisions.**

- **One effect per id and entity.** Refreshing it does not create another: `source_id` becomes the last one to refresh it
  (REFRESH and STACK); in STRONGEST, the one that sets the latest end. The same effect is always equally strong
  (its data does not change), so STRONGEST keeps the latest end and its author. *(Phase 4 review,
  "abilities" lens: STRONGEST did not change author; the STATUS from another shooter's refresh
  came out with the first one and, if the first was removed, `forget_author` removed the slow that
  the second sustained.)* The end never goes backward (`max`, also in
  REFRESH and STACK): only command 14's duration could do that, and this way the movement slot (which also
  keeps the maximum) ends on the same tick as the effect.
- **STATUS 2** comes out on expiry, when the author leaves and when the ninth effect replaces whichever ends first,
  with 0 stacks and `until_tick` = the tick it is removed. HEAL only comes out if it heals something (a pulse with
  full health sends nothing); `healer` is 0 if healing oneself.
- **STATUS and HEAL recipients** (§5.4): `ZoneServer._on_combat_event` sends them to the owners of the
  affected and of the author and to whoever has **the affected** as relevant (not the author, unlike other events).
- **Damage pulses**: `DamageFormula` with the author's damage increase (without block, crit or armor); the
  HIT's attacker is the author (0 if there is none: command 14), who enters "in combat" and the victim's
  damage log if it is someone else. A pulse from an effect without an author that kills gives DEATH without KILL.
- **On death** the effects and their movement slots are removed (`ActionMachine.remove_move_effect`,
  new) before `commit_state`: the DEAD action does not move, but the state is left clean for
  respawn. An effect is not applied to a dead player. The knocked-down part (not applying to a knocked-down player, skipping them
  in pulses, `clear` on falling and discarding hits with `downed_tick == s`) is put in by H3c.
- **Interruption**: decided with the live state at apply time (after the earlier hits of the same tick) and
  with the HIT's damage (the full one on an immortal dummy). A lethal hit does not interrupt (it kills).
- **Ability hits as the peer's "attacks"**: an ability that hits (with a shape or projectile)
  counts in `ServerPeer.swings` on the tick it starts, because its hits already counted in
  `swings_landed`.
- **`Combatant.restore_health(amount)`** (new) heals without exceeding the maximum; used by HEAL and `self_heal`.
- **`is_ray_clear` from inside** applies to everyone who uses it: the line of sight of hits and of
  NPCs (`NpcWorld`) and that of the client's nameplates. A ray that starts inside a world body or
  a structure collides at its origin; character chests are never inside the world (the
  capsule separates them) except in the doorway of the fort's own gate, which is exactly the case that was wanted.
- **`CombatDirector.remove(net_id, tick)`** asks for the tick for the STATUS 2 events (given by `_remove_player`).
- **Extra helpers**: `CombatDirector.set_cooldowns_off`, `apply_status`, `is_interruptible` and `_log_line`;
  `StatusSystem.find`, `heal`, `forget_author` and `stats`; `ActiveEffect.status` and `next_event_after`;
  `Combatant.effects_due`. Step 3 only visits whoever is on their commitment (they are gathered while freezing).

**Measured** (indicative, shared machine with other jobs). The rush covers **6.000 m** in its
dash window and **7.75 m** until it stops: when the dash ends it moves at 15 m/s and brakes at 60 m/s²
(`ground_deceleration`) during recovery, 1.75 m more. §2.3 says "6 m in the active phase" and it stays that way;
if 6 m total is wanted, the curve can fall off at the end (a balance decision for H5, combat.md §12).
`CombatDirector.process_tick` with 64 standing combatants (probe not committed, 600 ticks): 0.49–0.59 ms before
and after H3a (the machine's noise is larger than the difference); with three effects each (192:
bleed, healing and slow with synchronized pulses, the worst case) +10–20 µs on average, and
`StatusSystem.step` only 42–45 µs on average, 0 on ticks without events. Before storing `effects_due`
the same `step` cost 306 µs per tick (it traversed the 192 effects and looked them up in the catalog). The new
tests take ~9 s per file with engine startup; the cooldown one advances 1720
server ticks in ~0.6 s.

**For the following packages.** H3b: `ProjectileSystem.fire` in step 3 (`_process_commits`, also
with the commitment of a LIGHT or HEAVY with a projectile) with `InputQueue.get_applied(s)`, the flight in step
4, the wall box from `Combatant.frozen.wall`/`wall_half_extents`, `Hit.projectile_id`, the
`target_status` of the slowing arrow with `status.apply`, the interruption with
`CombatDirector.is_interruptible`, the `arrow_hit`, `arrow_blocked` and `wall_blocked` results in the
log and the DESPAWN 5 of arrows in `CombatDirector.remove` (next to `forget_author`). H3c:
`DownedSystem` in step 7, the discard with `downed_tick == s` in `_apply_hit`, `StatusSystem` without
knocked-down players (`_takes_pulses`, `apply`) and `status.clear` on falling, the cutting of reviving and executing with an
impact that interrupts, the refill in step 8 and commands 15 and 16.

### 11.5 H3b · projectiles

**Done.**

- **`ProjectileSystem`** (`scripts/server/projectile_system.gd`) with the contract of §7.2 (`spawned`,
  `despawned`, `fire`, `resolve`, `live_count`, `forget_owner`) and, in addition, `begin_tick`, `has_pending`,
  `get_live`, `get_projectile`, `clear`, `merge_by_attacker` and `stats`.
  - **Shot** (step 3): `CombatDirector._process_commits` fires on the commitment of a LIGHT or HEAVY
    with a projectile (the bow) and of an ability with a projectile. The rewind comes from
    `CombatResolver.compute_rewind` (factored out of `_swing_rewind`), rounded to whole ticks and fixed
    for the whole flight; if rejected or from the own safe zone, the arrow is harmless (bit 0 of
    `proj_flags`), and the rejection adds suspicion and reaches the combat log as `rewind_rejected`. Aiming
    is that of §4.4 with the input from `InputQueue.get_applied(s)`: canonical ray, aimed point
    with convergence on the hostiles at `s − rewind` (culled by their swept box against the crosshair's
    cone) and exit from the chest; the volley rotates in yaw; `v0` carries the draw charge (`charge_speed_scale`);
    origin and velocity are quantized with `Ballistics.quantize` and the server flies with that. Each projectile
    stores the author copy (shooter, realm, whether a player, source, hit, rewind, charge and the shot's
    `damage_scale`).
  - **Flight** (step 4): the segment `[pos(n), pos(n + 1)]` against the world and gates (the first with
    `hit_from_inside`), the hostiles' wall boxes and the rewound capsules (radius 0.4 + the
    arrow's) of the candidates; the smaller fraction wins. Invulnerable: keeps flying without being tested
    again (INVULNERABLE hit for the log); block facing the arrow with the weapon's cone or the
    wall's, in the sample of `k` or that of `k − defense_rewind` if it still counts; never a parry. World: it
    sticks; a gate the shooter can damage receives the hit (piercing ×0.2). Expiry at
    `n + 1 ≥ lifetime_ticks` or below y = −100.
  - **Caps**: with 8 alive from the shooter the oldest goes out and with 64 in the zone the oldest in the zone (tie
    by id), with DESPAWN 5 on that tick; the new shot always exists.
  - **Removals**: `CombatDirector.remove` calls `forget_owner` (DESPAWN 5 of the departing player's arrows).
- **`CombatResolver`**: `compute_rewind` and `note_rewind_rejected`; public `is_hostile`,
  `was_invulnerable`, `blocks_sample`, `dropped_guard_after`, `get_safe_areas` and `get_history`. `Hit` gains
  `projectile_id`, `projectile` (the author copy), `wall` (blocked by the wall box) and `direction`
  (the arrow's velocity on contact).
- **`CombatDirector`**: `projectiles`; step 4 merges melee hits and those of the
  projectiles by the attacker's net_id (first their hits, then their projectiles by id); `_apply_hit`
  applies the arrows' with the copied charge and damage increase, the wall box with mitigation 1 and the
  wall's spend (its guard break cuts the channel with its cooldown), the knockback in the
  arrow's direction, the interruption and the usual `target_status` (the slowing arrow applies
  `slowed`), one hit per shot on the peer and the `arrow_hit`, `arrow_blocked` and
  `wall_blocked` results in the log (with their counters). Metrics section `combat_projectiles` (shots and
  flight) and counters `projectile_us` and `projectile_busy_ticks`.
- **`StateHistory`**: `position_at(id, tick)` (without creating objects; `Vector3.INF` if absent) and
  `swept_box(id)`: each track stores while recording the boxes of 4 blocks of 8 ticks and their union, up to date (it covers
  the 25 ticks before the next one at minimum).
- **`NetEntityRegistry`**: `allocate_transient_id`, `release_transient_id`, `is_transient` and
  `transient_count`, from the same space and with the same 600-tick quarantine; `allocate` does not take a
  transient id in use.
- **`ZoneServer`**: projectile ids come from the zone's registry; the kind 3 ENTITY_SPAWN goes
  to the shooter's owner and to whoever has them as relevant; the ENTITY_DESPAWN, exactly to whoever received the
  SPAWN; the report counts shots, impacts, removals, culling, peak of live ones and messages sent.
- Notes in combat.md §4.3, networking.md §5.5 (recipients of SPAWN and DESPAWN) and §17.4 (contracts of
  `NetEntityRegistry` and `StateHistory`) and fortress.md §1.7; "Done (H3b)" notes in
  backlog.md (CMB-19, CMB-21, CMB-22 and CMB-23).

**Tests.** New `test_projectiles` (17): no arrow passes through a wall (40 shots with different angles,
all with DESPAWN 4 on the segment that crosses its face, and the control without a wall, which hits); the
shot hugging a corner hits the corner (the camera sees the target and the chest does not); from the closed gate's
doorway it sticks at the origin (DESPAWN 4 on the shot's tick) and rotated it comes out; a frontal shield
blocks it without parrying even if the parry window is open, and from behind it does not; the dodge lets it pass
through to the one behind; the wall box stops an arrow from afar aimed at the ally behind (no damage, 0.6
per point) and that of an archer inside the box, not that of an archer behind whoever holds it, and
without a wall the ally receives the arrow; a segment that starts inside a capsule hits point-blank on the
shot's tick; the caps (the shooter's ninth takes out their first and the first with 64 in the zone takes out the
oldest in the zone, both with DESPAWN 5, and the new shot exists); whoever leaves takes their arrows with them;
the arrow at the gate (12 = 60 × 0.2) and the owner's, which sticks; the flight against rewound positions
(with 10 ticks of view back it hits where the archer saw the target, and the control without rewinding, in the same
run, misses); the rejected rewind and the safe zone give harmless arrows (suspicion + 1); the
volley (3 arrows at ±7°, one hit per shot), the draw (40 and 70 m/s, 90 and 180), the slowing arrow
(60, `slowed` with its slot and drink interruption) and the backflip; the SPAWN's ballistics are what the
server flies and it expires at `n + 1 = 120` with DESPAWN 5; the culling (swept boxes and x sweep) touches
exactly the same ones as testing everyone's capsules (3000 random segments, with a teleported one);
a fake archer in a `ZoneServer` fires with a transient registry id, hits and, on leaving, takes their
arrow with them; and, with ENet on 127.0.0.1, the client that sees the shooter receives the SPAWN and the DESPAWN. Extended:
`test_state_history` (+3: `position_at`, the swept box covers the 25 ticks and forgets what is more than 4
blocks old, the gap) and `test_net_entity_registry` (+1: transient ids). The 53 test files of the touched areas (combat,
zone server, fort, NPCs, siege, network, snapshots, chat and parties, processes), one by one: 722 tests
green.

**Deviations and decisions.**

- **`begin_tick(s, combatants)`** is added to the contract: `fire` needs the tick's combatants for the
  crosshair convergence. The candidates and walls are computed once per tick and only if there is a shot or
  live arrows.
- **DESPAWN at the end of step 4**, not 5: `resolve` removes the arrows that end (and their id goes to
  quarantine) and returns their hits. On the reliable channel the DESPAWN arrives before the HIT of the same tick;
  both carry their tick, so the client notices no difference.
- **The wall covers the front**: its box only stops arrows whose velocity goes against the facing of whoever holds
  it. This way an enemy archer behind whoever holds it "shoots freely" also at those in
  front (the arrow crosses the box from behind) and one inside the box shooting toward it stops at the
  origin. The box widens by the arrow's radius.
- **No back-attack crit** for arrows: §4.4 does not ask for it and the sheet in §2.4 was computed without it.
  A balance decision for H5.
- **The block cone facing −velocity** is the usual one with an "attacker" behind the victim in the
  horizontal direction the arrow comes from; a vertical arrow counts as frontal.
- **Harmless**: they only collide with the world; not with walls or gates either (a gate sticks it without damage).
- **Rewind**: `roundi` of the hits'; the defenses', `max(roundi(defense), rewind)`.
- **No applied input** at `s` (an unconsumed queue, in tests): body yaw, pitch 0 and right
  shoulder.
- **Truly widened capsule**: radius 0.4 + r and also the height (feet − r, height + 2r), the sum of the
  capsule and the arrow's sphere.
- **One hit per shot** in `ServerPeer.swings_landed` (the arrows of a volley share a `Shot`).
- **Recipients**: `ZoneServer` records which peers received each SPAWN and sends the DESPAWN to those (even if
  they no longer have the shooter as relevant); whoever starts seeing the shooter later does not receive the arrows that are already
  in the air (they live 2 s at most).
- **`get_body_rids`**: `StructureTarget.exclude` already stores the gate's bodies (`FortGate.get_body_rids`),
  so the arrow recognizes the gate by the body its ray touches.
- **Cost**: the culling is that of §4.4 plus an **x sweep** (a one-dimensional grid, the one §8 left
  open): narrow candidates are sorted by their box's left edge (integers in centimeters
  with the index, `PackedInt64Array.sort` and `bsearch`) and each segment only looks at those that fall in its window;
  boxes wider than 12 m (a recent teleport) go aside and are always examined. The union of the
  4 blocks is maintained while recording (each track rebuilds it when a block starts), so `swept_box` does not
  traverse anything. `test_projectiles` checks that the culling does not change the result. The convergence culls with
  a sphere-cone test instead of the angle (equivalent and without `acos`).
- **`touched_ids`** (for tests): the candidates a segment touches, with the culling or testing all
  the capsules.

**Measured** (probe not committed, shared machine with other jobs; indicative). A brawl of 64 moving in 20 × 20
m, 30 shots per second (~51 live arrows, all over the brawl): the projectile section
costs **650–690 µs per tick**: preparing the 64 candidates 130–170 µs, **9–10 µs per arrow and
tick** and 70–115 µs per shot (convergence and aimed point); 0.023 exact tests per segment. With the
cap of 64 live, ~0.8 ms: within the 1 ms reserve. The first version (objects per tick, a traversal
of all candidates per arrow and the union computed on request) cost 3.3 ms. `StateHistory.record`
goes from 0.70–0.73 to 0.95–0.98 µs per entity (+16 µs per tick with 64). `test_projectiles` takes ~13 s with
engine startup (the network one, ~3 s).

**For the following packages.** H3c: `should_down` with `Hit.projectile.realm` and `is_player` (the author
copy); the `downed_tick == s` discard in `_apply_hit` also applies to arrows, and the arrow of a
shooter who has already died or is knocked down can still knock down or kill (the author copy is enough). H4: `ProjectileWorld` with `NetClient`'s
signals; the remote arrow is withdrawn at `despawn_tick + f`, with the segment of §6.2 (it is the one the
server tested), and the harmless one is drawn the same. H5: `test_projectile_loopback` (bots aim with
`solve_lead` and `look_for`, like `_over_drop` in `test_projectiles`) and the load test with the
`combat_projectiles` section of the metrics log.

### 11.6 H3c · knocked down and templates

**Done.**

- **`DownedSystem`** (`scripts/server/downed_system.gd`) with the contract of §7.2 (`should_down`, `down`, `step`)
  and, in addition, the signals `event_emitted` (DOWNED and INTERACT) and `killed` (the death of a knocked-down player, which
  the director applies), `is_enabled`, `killer_of`, `release`, `forget`, `downed_count`, `interacting_count`,
  `clear`, `bleed_loss` and `stats` (`downs`, `revives`, `executions`, `bled_out`, `interact_started`,
  `interact_cut`).
  - **When** (`should_down`): a player (PLAYER entity, fake ones too; never a dummy) left without health by
    the blow, arrow or pulse of a player from a hostile realm in an RVR zone. The director checks it in
    `_apply_impact` (with the arrow's author copy: its realm and whether a player) and in `_apply_pulse` (the
    effect's author, if still in the zone). Otherwise, direct death.
  - **Falling** (`down`): `Combatant.mark_downed` (health 0, 400 knocked-down health, author and source),
    `StatusSystem.clear` (without STATUS), `impose_downed`, `commit_state` and DOWNED to the whole zone. The HIT that
    knocks down carries bit 6 and not 4 (lethal).
  - **Step 7**: bleeding out, new INTERACTs and the progress and end of reviving and executing (§4.5), by net_id,
    with everything in §4.5: INTERACT edge in a real input, alive in NONE or BLOCK and on the ground, the closest
    within 2 m with `|Δy| ≤ 1.5` and line of sight from the chest to feet + 0.5 (a closed gate cuts it), an
    ally with nobody reviving them (REVIVE, INTERACT 1) or an enemy without safe zones in between (EXECUTE,
    INTERACT 4); finishing is checked before continuing (revived with 300 and `impose_revived`, INTERACT 3; executed,
    death with source "execution"); it is cut (INTERACT 2 or 5, `impose_interrupt` if still in the action) if
    whoever acts leaves the action, the target stops being knocked down or takes damage on that tick, exceeds 2.5 m or
    line of sight is lost.
- **Predicates** (`Combatant`): `is_alive` unchanged, `is_downed` (`downed_tick ≥ 0`) and `is_dead` (health 0 and
  not knocked down); `status_bits` with bit 3 (and the "in combat" one), never the dead one; `publish` with the
  knocked-down health out of 400 (`health_q` never 0). Each use in the §4.5 table: the resolver, projectiles,
  `NpcWorld` and `_rebuild_target_cache` treat it as a candidate without touching the code; `_apply_hit` discards with
  `is_dead() or downed_tick == s`; a hit on a knocked-down player goes through `_apply_downed_impact` (knocked-down
  health, no block or control effects); lethal volumes and y < −100 kill it with the killer from
  `killer_of`; `_gate_blockers` counts it (`not is_dead()`); `request_respawn` (NOT_DEAD), `heal` (command
  and console) and `regenerate` reject it; the circle and /stuck do not count it (`is_alive`); `StatusSystem` does not
  apply effects or pulses to it.
- **Leaving**: `ZoneServer._remove_player` first kills a knocked-down player (`CombatDirector.kill_downed`: DEATH and KILL
  with the killer from `killer_of` and the source "bled out"), so it applies to CLIENT_LEAVE, ENet drop,
  `remove_fake_player`/`--fake-churn`, the end of GUE-41's body and `remove_npc`. A knocked-down player leaves no body
  (`_should_linger` asks for `is_alive`), and `_process_departures` removes it from `_world_peers` first, so that what
  comes out of its removal does not reach it.
- **NPCs** (`HfsmBrain`): a hostile knocked-down player within ≤ 6 m (`DOWNED_PRIORITY_RADIUS`) is the preferred target in
  `_choose_target` and also on noticing it while idle or on patrol (`_scan`); it is attacked with the light attack (no shield
  or charge) and with its `AttackTokens` token. Note in fortress.md §4.2.
- **Templates** (§4.6): `ServerPeer.pending_template_id` (−1 = none); LOADOUT_SELECT in
  `ZoneServer._on_packet_received` (`_handle_loadout_select`, in LOADING and IN_WORLD, after the
  reliable-message limiter; 0 = the default one; warning for an id that does not exist, one that cannot be chosen or a malformed
  message). The pending one is copied to the `Combatant` on registration (`_process_arrivals`, before the SPAWN, with
  `CombatDirector.equip_template`: `set_loadout` with its weapons and charges) and on every respawn
  (`_respawn`: `reset_for_respawn` with the template's), and goes back to −1. Fake players:
  `add_fake_player(brain, realm, template_id = 0)` and `--fake-loadout=<template>[:<percentage>]`
  (`ServerConfig.fake_template_for`, in `ServerMain`). LOADOUT with `announce_loadout`: to the owner with their charges
  and, if the weapons change, the public one with 0 charges.
- **Refill** (step 8, `_process_recharge`, `RECHARGE_INTERVAL_TICKS` = 60): alive, out of combat, in their
  realm's safe zone and with fewer charges than their template in any potion → `set_charges` with the full ones
  and LOADOUT to the owner.
- **Commands**: 5 `set_weapon` is `set_loadout` with the weapon in slot 1 and the slot 2 one it carried
  (`CombatDirector.set_weapon(combatant, weapon_id, tick)`), with its LOADOUT; 15 `down` (`CombatDirector.down`)
  and 16 `refill` (`CombatDirector.refill`), over the network and from the console (`down <player>`, `refill <player>`).
  `missing_network_commands()` is now empty.
- **Combat log**: `downed` (after the line of the hit or pulse that knocks down, or that of command 15),
  `executed`, `bled_out` and `revived`. Report: the `DownedSystem` counters, `downed_now` and the
  director's `downed_hits`, `recharges` and `loadouts`.
- `tools/combat_balance.gd`: the "death" in its measurements (ideal TTK, duels and teams) is the fall, DOWNED or
  DEATH, whichever comes first; a knocked-down player who later dies only falls once.
- `NetZones.is_rvr(zone_id)` (new): the server only talks to `Zones` through `NetZones`
  (test_architecture).
- Notes in combat.md §5, fortress.md §1.7 and §4.2 and networking.md §5.4 and §17; "Done (H3c)" notes in backlog.md.

**Tests.** New: `test_downed` (15: the lethal blow between realms knocks down with bit 6 and DOWNED, publishes the
knocked-down health out of 400 with bit 3 and crawls at ×0.15; revived in 180 ticks with 300 health and NONE,
INTERACT 1 with its `end_tick` and 3; executed in 60 with the execution source, DEATH and KILL; bled out in exactly 1200
(200 at 600) with the killer who knocked down; revive cut by a hit on the reviver (bit 5) and by
a hit on the knocked-down player; no executing through the closed gate and rotated yes; the gate cannot be repaired with a
knocked-down player in the doorway; the fake player who leaves knocked down dies first with DEATH and KILL; with ENet, the player who leaves
knocked down dies even if in combat (no body) and on returning appears at their realm's point, and the GUE-41
body knocked down dies when its grace period ends; the lethal blow of an NPC kills without knocking down; a Hollow prefers the
knocked-down player (its first hit is for them, not for the closest standing one) and executes them with damage before 1200 ticks;
command 15 without author (and rejected in the own safe zone, outside RVR or when already knocked down) bleeds out without KILL,
and from the console; two hits on the same tick: the second is discarded and later ones take knocked-down health
without control effects), `test_consumables_server` (5: the health potion heals 6 pulses of 50 at `commitment + 30k`, spends
a charge and sets the shared cooldown; a hit that interrupts spends no charge or cooldown and one can
drink again; the camp refill with slot 2 active, the shield bash on cooldown and the wall
raised: weapon, slot, `ability_ready` and action do not change, LOADOUT only to the owner, and outside the camp or in
combat it does not refill; command 16; with ENet, the LOADOUT of command 5 reaches the owner with their charges and the other with
0, and that of 16 only the owner) and `test_loadout_server` (5: the default squire and the marksman with their weapons,
charges and the two LOADOUTs; LOADOUT_SELECT while loading decides the template on registration, with warnings for an id that
does not exist, one that cannot be chosen and a malformed message, and in the world that of the next respawn;
respawning with the same template only notifies the owner; command 5 puts the weapon in slot 1 and keeps 2,
and is not valid with a knocked-down player; `--fake-loadout` with its distribution and its invalid values). Adapted to the lethal
blow between realms now knocking down: `test_combat_director` (the three death tests use an NPC attacker),
`test_status_effects` (the pulse halfway through the list now knocks down, with the cleanup on being knocked down, and the
version that kills uses an NPC author: 11) and `test_fortress_net` (the GUE-41 body is knocked down and executed);
`test_combat_server` and `test_hfsm_brain` no longer expect commands without a handler.

**Deviations and decisions.**

- **The killer without a hit** (`killer_of`): the last enemy who damaged them while already knocked down and, failing that, whoever
  knocked them down; 0 if no longer in the zone (DEATH without KILL). It applies to bleed-out, leaving, lethal
  volumes, y < −100 and the fall. Bleed-out is exact in integers: cumulative `⌊e · 400 / 1200⌋`.
- **Hits on a knocked-down player**: damage from the formula with the charge, the crit and the damage increase (no block even if an
  old sample says BLOCKED or PARRIED, no control effects, effects or interruptions); the HIT carries bit 4 if it
  kills, and the log writes `hit` or `arrow_hit`. The fall takes knocked-down health; the environment never knocks down.
- **The INTERACT edge** comes from `InputQueue.get_applied(s)` (without `SUBSTITUTED`) versus
  `Combatant.last_buttons` of the previous tick; if it is not up to date (there were no knocked-down players), from `get_applied(s − 1)`.
  It is only examined if there is any knocked-down player in the zone: with none, step 7 visits nobody. `Combatant.last_buttons_tick`
  is added.
- **Several can execute** the same knocked-down player (whoever finishes first wins); reviving, only one. The closest
  of the valid ones is chosen and then line of sight is checked in order.
- **On finishing** it is only required that the target is still knocked down and the actor alive: a hit on the last tick no longer
  cuts it (on that tick the simulation has already returned to NONE). INTERACT's `end_tick` is the planned one in 1 and 4 and
  the tick's in 2, 3 and 5. Revived gives no protection and does not remove "in combat".
- **Command 15**: also rejects whoever is not alive, a dummy and whoever is not a player; DOWNED goes
  without author or source and without HIT. **Command 16**: requires being alive and carrying a template. **Command 5**: with a
  knocked-down player it is rejected (REFUSED; `set_loadout` would put them in NONE) and the same weapon as the slot 2 one leaves it
  empty. NPCs are equipped with it on creation, without LOADOUT (their SPAWN already carries the weapon).
- **LOADOUT via `event_emitted`**: the director emits it twice when the weapons change; with `involved` =
  `[player]` it is the owner's (`ZoneServer` only sends it to them) and with `involved` empty, the public one (charges 0,
  to whoever has the player as relevant, without the owner). On spawning it comes out after the SPAWN; on respawning, after the
  RESPAWN, with the public one only if the weapons change.
- **`template_id` 0** (NPCs, fighters assembled by hand in tests): no template, respawns with what it
  carried (H1b's behavior) and does not refill. A player always carries one: the pending or the default one.
- **The refill** falls on ticks that are multiples of 60, unstaggered (it is cheap: it only looks at whoever has a template
  and is missing charges) and restores the whole template.
- **The lethal blow between realms no longer kills**: tests that took death for granted (those in
  `test_combat_director`, `test_status_effects` and `test_fortress_net`) use an NPC author or execute. Combat fake players
  (`BotBrain`) keep attacking a knocked-down player and execute them with damage; reviving and executing with INTERACT
  belongs to H5. A knocked-down fake player stops looking for enemies (`_find_enemy_position` asks for `is_alive`).
- **No changes** to `BattleLog` and `ScoreKeeper`: a knock-down is not a kill; the kill is the death that follows
  (DEATH and KILL).

**Measured** (indicative, probe not committed with 64 combatants in a brawl and other jobs on the machine):
step 7 without knocked-down players costs 1.6 µs per tick (it visits nobody); with 8 knocked down and half the zone
pressing E every 2 ticks, 55–63 µs (mostly reading the applied input of the 64). `process_tick` with 64,
1.1–1.6 ms with or without knocked-down players (the machine's noise is larger than the difference). `test_downed` takes ~16 s
with engine startup (the bleed-out test advances 1200 ticks in ~0.7 s), `test_consumables_server`
~12 s and `test_loadout_server` ~10 s.

**For the following packages.** H4: `_note_imposed_state` with the own DOWNED, INTERACT (revived and cuts) and
LOADOUT; the knocked-down notices with the extra block's health (bit 3, out of 400); the selector sends
LOADOUT_SELECT (`0x07`) also before CLIENT_READY; the others' LOADOUT arrives with 0 charges. H5: bots that
revive and execute (hold E), the `interact` cheating mode, `test_loadout_net` and the balance sheet with
knock-downs (`tools/combat_balance.gd` already measures up to the fall).

### 11.7 H4 · client

**Done.**

- **Prediction and arrows.** `ClientPrediction` emits `stepped(tick, input, state)` after each `step()` (never
  during replays or the startup's neutral advance). `ProjectileWorld` (`scripts/client/projectile_world.gd`)
  listens to it: on a shot's commitment it creates the predicted arrows with that tick's input, the canonical
  ray against the local world and the capsules of hostile remote players as drawn, and the same
  quantization; it draws them at the predicted time, stops them at the world with its own ray (the first
  segment with `hit_from_inside`) and hides them on touching an enemy's drawn capsule. The own SPAWN
  is paired by source, volley index and tick (within `input_buffer_ticks`) and adopted with an
  offset that decays over 6 ticks; without a pair the server's is drawn; without a SPAWN in `rtt + 30` ticks the
  predicted one is withdrawn. Remote ones appear at their `spawn_tick`, are drawn at `pos(render_tick + fraction −
  spawn_tick)` and are withdrawn at `despawn_tick + f` (DESPAWN 4, with its own ray against the world and the
  drawn capsules) or at `despawn_tick` (DESPAWN 5). `NetClient` creates it, puts it in the zone next to
  `RemoteWorld` and passes it the steps, SPAWNs and DESPAWNs before emitting its signals.
- **`ProjectileLaunch`** (`scripts/shared/combat/projectile_launch.gd`, shared): what a
  commitment fires (`from_state`: attack with a projectile or ability with a projectile, its source, its speed with
  `lerp(1, charge_speed_scale, f)` and the volley) and with what ballistics (`launch`: canonical ray, `aim_point`,
  muzzle at the chest, yaw rotation `(i − (n − 1)/2) · spread` of arrow `i` and `Ballistics.quantize`).
- **Action bar** (`ActionBar`, UI-11): light/heavy (or shot/draw), block (hidden with
  `can_block` false), dodge, abilities 1–3 of the active weapon, R and T with their charges and Q with the weapon in the
  other slot, in `UIIconSlot` slots with their key glyph. It reads the predicted state every frame:
  cooldown `ability_ready[i] − predicted tick` with sweep and seconds, flash when it finishes on its own, no
  flash if a reconciliation (rejection) or a weapon swap removes it; `ability_status` dims (BLOCKED) and
  strikes through (NO_CHARGES); dodge and block dim when exhausted and the dodge blinks with bit 1; an
  ill-timed press (in `LocalPlayerController.input_generated`'s inputs) blinks the slot.
  Provisional `PlaceholderIcon` icons (a self-drawing `Texture2D`: square in the weapon's color and
  its initial) with the colors from `CombatIcons`.
- **Statuses** (UI-45): `StatusTracker` per entity in `NetClient` (`get_status_tracker`), fed with the
  already-timed STATUS events and emptied by STATUS 2, DEATH, DOWNED, RESPAWN and the ENTITY_DESPAWN; `StatusIcons`
  (own row above health, against the estimated server tick: icon, seconds, stacks, red
  or green border and tooltip) and the nameplates (up to 4, harmful ones first, against the draw tick; the
  knocked-down bar in orange with its icon).
- **Knocked down**: `DownedNotice` ("Derribado" with the knocked-down health countdown, "Ana te está
  levantando" or "¡Te rematan!" with the INTERACT bar, "Mantén E para levantar a …" near a knocked-down
  ally and "Levantando a …"); `NetClient.is_downed()` (bit 3 of `status`); the kill feed also shows
  DOWNED events.
- **Templates**: `TemplateSelector` on the death screen (sends LOADOUT_SELECT with
  `NetClient.send_loadout_select`; there its buttons do not take focus, `set_buttons_focusable(false)`, so that Tab
  keeps opening the scoreboard and Enter does not press "Reaparecer", phase 4 review, client) and in realm selection;
  `ClientConfig.loadout` (`--loadout=<template>`) goes out in a LOADOUT_SELECT right after WELCOME arrives, before
  CLIENT_READY.
- **Bow**: while drawing, `CameraRig.set_aim_zoom` narrows the field of view to 75% of the configured one
  (`get_fov` remains the settings' one) and `Crosshair.set_tension` tightens the reticle with the charge.
- **Keys**: Q `swap_weapon`, R `consumable_1`, T `consumable_2` (in `InputBindings` and
  `LocalPlayerController.BUTTON_ACTIONS`) and the `AIM_LEFT` bit in every device input with
  `CameraRig.get_effective_shoulder()` (the shoulder after the automatic swap due to a wall).
- **`NetClient` explanations** (§5.4): movement STATUS on oneself, own DOWNED, INTERACT
  where one is the knocked-down player or the actor and own LOADOUT explain the correction (the own HIT with
  bit 5 already was: every blow received is).
- **Texts** (`CombatText`): `source_label` for the sources of §5.4 (attacks, abilities, pulses, execution and
  bleed-out), the death screen with "Te ha rematado…" and "Te has desangrado…", and the names of
  abilities, effects, weapons and templates, by resource name.
- **Provisional animation** (§6.6): `CombatClipPlanner` gains the keys of each ability, `drink`, `swap`,
  `downed`, `downed_crawl`, `revive`, `execute` and `get_up`; three-part abilities are stretched to
  their cast, active and recovery; `CombatActionAnim.loop` (crawling). Each weapon uses its set
  (`CombatAnimationLayer.clips_for`: `data/animation/<weapon>_clips.tres`; new `bow_clips.tres`, and the
  new entries in `sword_shield_clips.tres`), the remote player with the weapon pair of its view and bit 3 of
  its record (`RemotePlayerView.get_active_weapon_id`, which they take from the SPAWN and from a LOADOUT). `WeaponProps`
  gains the provisional bow (two limbs and a bowed grip, with a string) and `show_weapon`, which
  `HumanoidVisual` calls when the animator reports another weapon (`weapon_shown`), on remote players too.

**Tests.** New: `test_projectile_world` (5: the predicted one is replaced without a jump and adopts id, tick and
ballistics from the server; two steps in one physics tick with the commitment on the first, with the real
`ClientPrediction`; own SPAWN with the player already in the world via `NetClient`, with and without
a pair; the remote one appears at its `render_tick` and is withdrawn at `despawn_tick + f` on a wall (f = 0.25) and at
`despawn_tick` on expiry; the own one sticks in the wall, hides in an enemy's capsule and without a
SPAWN is withdrawn at `rtt + 30`), `test_action_bar` (4: icons and cooldowns after two weapon swaps;
**a rejection reverts the counter** with `PredictionPair` and the lost press, without a flash; the flash
of the one that finishes on its own; charges, strikethrough, blinks and exhaustion), `test_status_icons` (4: tracker, one per
entity and removed on DESPAWN, own row with duration and stacks that disappears on expiry, nameplate with
four harmful icons first, expiry and knocked down) and `test_ability_input` (2: Q, R, T and G with no
repeated keys; the new bits and `AIM_LEFT` from the effective shoulder, also with input
suspended). Extended: `test_hud_combat` (+5: knocked-down notices with reviving, cut and execution; the
invitation to revive an ally and "Levantando a…"; the death-screen selector; bow zoom and
reticle; kill feed and execution and bleed-out phrases), `test_net_client` (+2:
LOADOUT_SELECT before CLIENT_READY and from the death screen; the new explanations),
`test_combat_animation` (+4: clip sets per weapon, ability keys and phases, layer with the weapon
and getting up, accessories per weapon), `test_remote_world` (+1: weapon pair and slot bit),
`test_client_config` (+1, `--loadout`) and `test_realm_select` (+1). Adapted: `test_social_menu` (the key
  for the player menu is G) and `test_combat_animation` (weapon 1 is no longer the sword: it is requested by name).

**Deviations and decisions.**

- **T was the player menu** (SOC-07, provisional). §0 gives T to the stamina potion: the menu moves to
  **G** (free, and not wanted by inventory I, character C, journal L or abilities K from the
  roadmap). Noted in social.md and in SOC-07. Until UI-17 there is no rebinding or saved profile, so
  nobody has an old T.
- **`ProjectileLaunch` is new and shared.** §7.2 leaves the shot inside `ProjectileSystem.fire`; so that
  the predicted arrow and the server's come out the same, what is fired, at what speed and in what
  direction (including the volley rotation, which the document did not fix) lives in one place. H3b, done
  at the same time on another branch, must use it (or match it) on merging: the `test_projectile_world` test compares
  against it. Done in the merge (§11.8): `ProjectileSystem.fire` fires with it.
- **Time of own arrows**: `predicted tick − 1 + fraction`, the instant at which the local
  character is drawn (with physics interpolation, between the previous tick and the latest), so that the arrow
  leaves the chest that is seen.
- **What stops at the world** is only the own one: a remote one does not stop on its own (the server decides
  and announces with DESPAWN 4). An own arrow already stuck disappears when its DESPAWN arrives; leaving it
  stuck for a while belongs to the pending VFX (ART-12).
- **The zoom** arrives in full on reaching the minimum charge (before, it closes in step with the charge) and the
  reticle closes with the charge's `f` (from minimum to maximum).
- **Template in realm selection**: the default one is not requested (no LOADOUT_SELECT), so as not to send
  a message that the pre-H3c server counts as unexpected; choosing another, and any choice on the
  death screen, does send it.
- **Knocked down without server events yet**: the notices read bit 3 of `status` and H3c's INTERACT;
  while nobody sends them, tests use synthetic events, like the earlier client tests.
- **Animation**: no clip for the arrow or for drawing (ART-41); the draw uses `Pistol_Aim_Neutral` and the
  shot, `Spell_Simple_Shoot`; `swap` is a 0.4 s `Sword_Idle` with 0.2 s fades; knocked down
  and still is the last frame of `Death01` and crawls with `Crouch_Fwd_Loop` looping; getting up
  (`LayToIdle`) is seen once on going from DOWNED to NONE. The bow hangs from the same `BoneAttachment3D` as the
  shield (the left hand) and is created the first time it is needed.
- **Healing without a number**: the HEAL (potion) does not yet produce a green number; the effects row already shows
  the regeneration. It is left for when there are VFX.
- **Extra helpers**: `CameraRig.get_effective_fov()`/`get_aim_zoom()`, `Crosshair.get_ring_radius()`,
  `ActionBar.is_ranged(weapon)`, `CombatText.template_summary`, `NetClient.get_projectile_world()`,
  `KillFeed.show_downed`, `RemoteWorld.on_loadout` and `HUD.bind_controller` (the sandbox connects its
  controller for the blinks).

**Measured** (indicative: shared machine, 4 cores with other jobs; `probes/bench_h4.gd`, not committed):
drawing 40 remote arrows, 86–118 µs per frame (2.2–2.9 µs per arrow); the registration of a predicted arrow
(canonical ray and `aim_point` against a flat world), 25–27 µs; `ActionBar.refresh` with a cooldown
running, 31–34 µs per frame; `StatusIcons.show_tracker` with two effects, 28–33 µs at first and 4.6
µs after not touching what does not change (with 32 nameplates it matters: only the icons that change are touched).

**For the following packages.** H3a: the STATUS and HEAL events that the own row and nameplates already draw
(`StatusTracker` takes them from `NetClient` as is), bit 5 of HIT. H3b: `ProjectileSystem.fire` with
`ProjectileLaunch.from_state` and `launch` (the same source, speed, volley and quantization as the predicted
arrow; if anything changes, on both sides), the SPAWN with that source and `volley_index` (the pair is looked up
by them) and DESPAWN 4 and 5 (`ProjectileWorld` already handles them). H3c: bit 3 of `status` with the
knocked-down health in the extra block, DOWNED and INTERACT (the notices already read them), LOADOUT_SELECT in `ZoneServer`
(the client sends it as soon as WELCOME arrives if a template was chosen) and LOADOUT to whoever has the
player as relevant (the remote view takes its weapon pair from it). H5: bots set `AIM_LEFT` themselves (their
camera is the canonical one) and choose a template with `--loadout`; `test_loadout_net` can look at the other's weapons
with `RemotePlayerView.get_weapons`/`get_active_weapon_id` and command 14's bleed with
`NetClient.get_status_tracker` and the HUD row; `test_projectile_loopback`, with the statistics of
`ProjectileWorld` (`substituted`, `rejected`).

### 11.8 Merge of H3 (server) and H4 (client)

H3a–H3c (server, branch `wip/habilidades`) and H4 (client, branch `wip/habilidades-h4`) came out at the same time from
H2. They are merged with `git merge --no-ff wip/habilidades-h4`.

**What collided.** Only the documentation; the code merged by itself, because H3 touched server and shared code and H4,
client, animation data and a new shared file (`ProjectileLaunch`).

- **`docs/backlog.md`**: both branches added their "Done" note at the end of the same lines. They are UI-45,
  CMB-19 to CMB-24, CMB-28, PRG-04, PRG-07 and PRG-08. Each line keeps both notes, H3's first and then
  H4's, in package order. In H4's notes, the "Missing…" items that asked for the server (H3a, H3b or H3c)
  are brought up to date, because it is already done. The checkboxes are those of each branch: CMB-20, CMB-28 and PRG-08 (H3) and
  UI-11 (H4).
- **`docs/abilities.md`**: both branches started their §11 at 11.4. H3's stay at 11.4–11.6 and
  H4's becomes §11.7. Their references are changed at the same time: backlog SOC-07, the link in social.md
  §12.5 and the `InputBindings` comment.

**Code integration: the server fires with `ProjectileLaunch`.** H4 asked in its "Deviations and decisions"
that the server's arrow and the predicted one come out of the same place. H3b computed the same thing on its own, with
three edge differences:

- the server normalized by dividing by `length()`;
- with degenerate aiming, the server went out along the camera ray below 1 cm and
  `ProjectileLaunch` toward −Z only at zero;
- the server only read the charge of a heavy attack.

Now `ProjectileSystem.fire` takes what comes out, the speed (with the charge) and the volley from
`ProjectileLaunch.for_attack`/`for_ability`, and the quantized origin and velocity of each arrow from
`launch_toward(muzzle, point, camera ray)`. The aimed point is still the server's: `aim_point`
with its rewound and culled candidates.

In `ProjectileLaunch`:

- `MIN_AIM_DISTANCE` = 0.01 m;
- `launch_toward` gains `fallback`, the camera ray direction, which `launch` passes;
- `for_attack` does not count the charge of a light attack.

`_charge_progress` and `_MIN_AIM_DISTANCE` leave the server. No H3b or H4 test changes
result. The only difference left between the two arrows is the design one (§6.2): the hostiles for the
convergence, rewound on the server and as drawn on the client.

**New test**: `test_projectiles::test_the_server_arrow_is_the_shared_launch_the_client_predicts`. It does
a quick shot, a draw with 40 ticks of charge from the left shoulder and the volley, each with
convergence on a target at 20 m. The SPAWN carries, bit for bit, the source, the volley index, the origin and
the velocity that the client computes with `ProjectileLaunch.from_state(...).launch(...)` from the same
applied input.

**What already fit** (checked by reading both sides, no changes):

- **Knocked down.** The knocked-down notices read `NetClient.get_health()`, the extra block, which with a
  knocked-down player carries the knocked-down health out of 400 (`Combatant.publish`). The nameplates use the `health_q` of that
  same health.
- **INTERACT.** Operations 1 to 5 and their `end_tick` are the same in `DownedSystem` and `DownedNotice`. The
  execution ends with the DEATH, which erases the notice.
- **LOADOUT.** The others' LOADOUT arrives with 0 charges and `RemoteWorld.on_loadout` only takes the weapons.
- **LOADOUT_SELECT.** The one before CLIENT_READY is accepted by `ZoneServer` in LOADING. The default
  template is the same on both sides (`CombatCatalog.default_template_id`). H4's deviation of not requesting it
  on choosing a realm is no longer needed, but does no harm either.
- **Arrows.** The SPAWN carries the source and `volley_index`, with which `ProjectileWorld` pairs the arrow.
  DESPAWN 4 and 5 are sent by `ProjectileSystem`.
- **STATUS.** The STATUS and HEAL events of `StatusSystem` reach `StatusTracker` as is.

**Fixed while testing.** `test_combat_wire` was already failing in H3c (3 of 8; checked at `8d9a752`, before
merging) and H3c had not run it. There were two causes:

- **The entry's LOADOUT.** Each client receives its own, and the public one of those who enter later. The
  waits for "some event" were satisfied before the HIT, and the one who sees nobody received an event: their own
  LOADOUT.
- **Knocked down.** "test_world" is RVR, so the lethal blow between realms knocks down.

Now the tests wait for the HIT by its class and the blind one receives nothing from the other two. The KILL test
checks that the light attack knocks down (bit 6 and not bit 4, DOWNED to all three), that Ana executes by holding E and
that the DEATH and the KILL carry the execution source, Ana as killer and Cleo as assistant.

**Tests.** 143 files were run, one by one, with 2020 tests. They are all those of the areas the
two branches touch: combat, prediction, messages, `ZoneServer`, HUD, arrows, knocked down, abilities, effects,
templates, consumables, chat and parties, fort, siege, NPCs and bots, plus the local-loop and process ones. Everything
passes green. The only thing that failed was `test_combat_wire`, fixed above. The only files not
run are the 11 nobody touches here: terrain, map and zone of Vado Gris, resources, navmesh and routes,
export, audio, names and realms.

**For H5**, unchanged from §11.6 and §11.7, now that client and server are together:

- `test_projectile_loopback`: with the paired SPAWN, `ProjectileWorld.stats` `substituted` and `rejected`;
- `test_loadout_net`;
- the network test of command 14's bleed on the nameplates and in the HUD;
- bots that revive and execute (hold E) and the `interact` cheating mode;
- `AIM_LEFT` and `--loadout` in the bots;
- the tests against the dummy and the balance sheet.

### 11.9 H5 · integration

**Done.**

- **The bots' kit** (`BotBrain`, `scripts/shared/bot_brain.gd`). If whoever carries the bot gives it its combat
  state (`set_combat_source`: the predicted one on a client, the server's on a fake player), the `COMBAT` and
  `SIEGE` patterns fight with the whole phase 4 equipment:
  - **Abilities by their role in the data** (`KitRole`, `kit_role`): short hit with a shape (the shield bash, at
    2.2 m), forward dash to close in (the rush, between 3.5 and 7 m), channel that blocks (the wall:
    **holds its button** for 60 to 200 ticks, which §3.3 requires for the channel to continue), backward dash
    (the backflip, if the enemy comes within 5 m) and shot (volley and slowing arrow). It only presses a
    slot that `ActionMachine.ability_status` reports as ready.
  - **Weapon swap**: to the bow with the enemy beyond 11 m and to the sword within 5.
  - **Potions**: health below half (`set_health_source`) and stamina below 30%,
    with charges and outside the shared cooldown.
  - **Bow**: keeps distance (9 to 26 m, sideways in between), alternates quick shots and draws (24 to
    60 ticks) and aims every tick with the lead of what it is about to shoot (`BotBrain.lead_look`:
    `Ballistics.solve_lead` from the muzzle, the point `O + dir · |target − O|` and `AimRay.look_for`), with the
    enemy's position extrapolated since it was found and the `AIM_LEFT` bit for its shoulder (the left one with an odd seed).
  - **Knocked down**: executes a knocked-down enemy (the finder returns a `BotTarget` with `downed`) and revives a
    knocked-down ally (`set_ally_finder`) if there is no standing enemy within 6 m, holding INTERACT for as long as
    the action lasts.
  - Counters for tests (`get_kit_counts`) and two static helpers, `is_ranged_weapon` and `lead_look`.
- **`BotTarget`** (`scripts/shared/bot_target.gd`, new): what the enemy finder can return instead of
  a position: feet, velocity, knocked down and net_id.
- **The senses on each side.** Server: `ZoneServer.add_fake_player` gives combat and siege fake players a
  `BotTarget` finder (the target cache also stores velocity and knocked-down state), their `CombatState`, their health
  fraction and the knocked-down allies of their realm. Client: `ClientBotBrains.give_kit_senses` (the predicted
  state of the character, the extra block's health) with `BotEnemySight.find_target` (drawn position and velocity:
  the server rewinds arrows to what was drawn) and `find_downed_ally` (the DOWNED action of the
  drawn record).
- **Cheaters** `reuse`, `potion` and `interact` (`BotCheatBrain.Style`, `BotCheater.MODES`/`COMBAT_MODES`, help for
  `ClientConfig.bot_cheat`): they hammer ability 1 up against the enemy, the two potions or INTERACT, one edge every
  two ticks. Without a kit: they play with their buttons.
- **End-to-end tests** with ENet on 127.0.0.1 (§7.3): `test_projectile_loopback`,
  `test_abilities_reconciliation`, `test_loadout_net` and the three of `test_bot_cheat`; `NetHarness.start_bot` gains
  the template (`--loadout`).
- **Measured balance sheet** (`tools/combat_balance.gd`, §2.4 → [combat.md 12.8](combat.md#128-phase-4-kits-h5-docsabilitiesmd-section-24)):
  kit data, bow against the dummy, ranges at 10, 30 and 50 m, one use of each ability, the wall against one and
  two attackers, duels with the kit (also squire against marksman and marksman against marksman), and 2 versus 2 with the
  two templates; with `--reference`, duels without abilities and with the kit without potions.
- **Load** (`tools/load_test.gd --brawl`): half of the fake players with the marksman template
  (`--fake-loadout=marksman:50`), pure archers with `--fake-archers` (of them, the `--sky-archers` share shoots
  into the sky), the fort NPCs in the zone and, in the summary, the `combat_projectiles` section, the arrows (peak versus
  the cap, evicted by the cap) and the kit, with the phase 4 criterion. Player limit in
  [networking.md 14](networking.md#14-bandwidth-and-cpu-budget).
- **`Nameplates`**: occlusion requests the world with `find_world_3d()` (inside a `SubViewport` with its own
  world, `get_world_3d()` is null and the nameplate failed; uncovered by `test_loadout_net`, which puts a HUD in each bot's
  viewport).

**Tests.** New:

- `test_bot_brain_kit` (11, no network: the action machine advances with the bot's inputs): each
  ability's role comes from its data; without combat state, or with `use_kit` off, the inputs are those of phase 3 byte
  for byte (also with a `BotTarget`); the squire only presses ready slots, holds the wall (≥ 60 ticks of
  channel) and spaces the shield bashes by their cooldown; the rush at 5 m; it drinks the three health charges
  separated by the shared cooldown and the stamina one when tired; the marksman switches to the sword up close and to the
  bow from afar; the archer against a target running at 22 m: 11 of 11 arrows (those of `ProjectileLaunch` with its
  input) hit the moving capsule, with draws and the left shoulder; it executes and revives holding
  INTERACT, and does not revive with an enemy on top of it; deterministic with the seed; load archers do not draw the sword
  and raise their aim.
- `test_projectile_loopback` (1, ~22 s): 150 ms RTT and 30 jitter on the server, 20 draws at 30 m against a
  target running sideways: **20 confirmed**; the control in the same run, the SPAWN's trajectory against
  the target's present position on every tick, **0**; 20 predicted replaced, 0 rejected, no suspicion or
  unexplained corrections.
- `test_abilities_reconciliation` (1, ~19 s): three combat bots with both templates and 120 ms RTT, 20
  jitter and 5% loss: they use abilities (5 ability hits), swap weapons, drink, fire 15 arrows,
  someone ends up slowed and someone knocked down (executed with INTERACT); no unexplained correction, no hard
  reset or resynchronization and exact convergence after 180 ticks standing still. Since the review (§11.10) what
  is counted is what the server does (abilities, weapon swaps and drinks that its state starts, HEAL and the
  HIT with bit 6) and not what the bot wanted to press.
- `test_loadout_net` (1, ~15 s): different templates (Ana the marksman before CLIENT_READY, which is not the default
  one and already comes out in her SPAWN; afterwards both choose in the world and it applies on respawning: §11.10) and each sees
  the other's weapons; with 100 ms RTT without loss, six weapon swaps without any correction and the other sees all six;
  command 14's bleed in the HUD row (6 s) and on an ally's nameplate, and it disappears from both on expiry.

Extended: `test_bot_cheat` (+3: `reuse`, two shield bashes in 900 ticks spaced exactly 738; `potion`, two
drinks in 1300 ticks spaced by the shared cooldown and, since the review (§11.10), a second cheater with
1 and 0 charges that drinks once and no more; `interact`, no INTERACT on an enemy knocked-down player at 4 m; without
suspicion or warnings or prediction failures), `test_bot_cheat_brain` (+3), `test_bot_cheater` (the six
combat modes and their brains), `test_combat_balance` (the minimal pass checks the bow's DPS, the ranges with the flight
of the ballistics, the wall against one and two and 2 versus 2 with both templates), `test_load_test` (+1: the
phase 4 figures and the brawl with marksmen), `test_server_config` (+1: `--fake-archers`) and `test_combat_processes` (combat
fake players use the kit: the combat log also carries ability names, and some must come out).

**Deviations and decisions.**

- **The kit is switched on with the combat state.** Without `set_combat_source` (or with `use_kit` false) `BotBrain` produces
  the same inputs as before: it spends no numbers from its generator (the shoulder comes from the seed's parity), and the
  600-tick fingerprint of `test_bot_brain_siege` does not change. The server's fake players and the client's `--bot-brain=combat` and
  `siege` bots always carry it; those of the cheating bot and the light swarm (`SwarmBot`, which does not simulate and only
  knows its state with an RTT of delay) do not.
- **By role, not by name**: the bot does not know `shield_bash`; it looks at shape, dash, channel and projectile.
  A new weapon with similar abilities is used without touching it.
- **Siege**: `SIEGE` bots use the kit when fighting (step 1 of their plan) but do not revive anyone: they follow their
  route. F6b's siege tests remain green. With F6b merged (its defenders, the walkway, the muster and the capacity of 40,
  which in the fort was an estimate and was measured in the integration review), in
  [fortress.md 8.3](fortress.md#83-what-f0-f1-and-f2-left-behind-additions-to-the-contract-and-decisions), "Integration of the abilities
  on F6b" and "Review of the abilities integration" (the siege bots' bow only fires with a clear line of fire).
- **Bad network on the server** in `test_abilities_reconciliation`: §7.3 asked for `NetSim` on each bot, but the cap of the
  rewind counts the server simulator's delay and not that of a client (networking.md §10), and with the simulator on
  the bots the server rejected 14 of 20 shots (harmless arrows) and 20 hits. With 120 ms RTT, 20 jitter
  and 5% loss on the server, in both directions, nothing is rejected.
- **Fallback in `test_abilities_reconciliation`**: if by mid-fight nobody has been slowed, the server
  slows the Solmarch player (like command 14), and if at two thirds nobody has fallen, it knocks them down (like 15); the test
  says which was needed. Without it, depending on the seeds the fight ends early or the slowing arrow misses, and the
  test would not prove what it says. In H5's runs, the slow came by itself and the knock-down was imposed. Since
  the review (§11.10) the knock-down fallback, at mid-fight, leaves the Solmarch player at 1 health and without health
  potions (with their LOADOUT, like command 16), and a hit knocks them down (HIT with bit 6); `down()` is only left for
  five sixths of the fight, and in the review's runs it was not needed (with 1 health and its potions, one
  in three did: it healed by drinking).
- **The target of `test_projectile_loopback` runs in a circle** around the archer: always sideways and always at
  30 m, without turning around mid-flight (in a straight line and back and forth, 20 draws do not fit in 30 s).
  Draw of 30 ticks (46.9 m/s).
- **`test_loadout_net`** uses 100 ms RTT without loss so that prediction runs ahead of the server, and the
  window without corrections covers the six swaps plus three RTT (more than ±RTT around each one).
- **`--fake-archers` and `--sky-archers`** (load tests): in a dense brawl everyone has an enemy within
  5 m and the marksmen draw the sword: the first measurement gave **0 arrows**. To measure projectiles with the zone
  full, fake players with the bow in hand do not switch to the sword (`kit_ranged_only`) and a share shoots 0.8 rad above
  the good shot (`kit_aim_raise`): their arrows live their full 2 s.
- **`test_combat_balance`** runs a reduced pass (2 fights per team size and without the marksman
  duels, new options `--team-runs` and `--no-template-duels`) to stay under 25 s.

**Measured.** (Indicative: 4-core machine shared with other agents.)

- **Load** (`load_test.gd --brawl`, 60 s of measurement, Vado Gris, fort NPCs; detail in
  [networking.md 14](networking.md#14-bandwidth-and-cpu-budget)): p99 of the tick and of `combat_projectiles` with 32
  combatants, 11.3 and 0.98 ms (meets); with 48, 17.0 and 0.89 ms; with 64, **19.3 and 1.68 ms** (does not meet; with all
  archers firing into the sky, 19.5 and 2.04 ms and a peak of 54 live arrows: the cap of 64 never fills up); with 128, 28.9 and
  2.94 ms. **The player limit per battle drops from 64 to 40** (networking.md 14; the brawl of 40 was measured in the
  review, §11.10: 12.4 and 0.90 ms, meets). `simulate()` stays at 67–69 µs per
  character; no rewind rejected up to 64; the downstream per client, 36 KB/s with 64.
- **Balance** (`combat_balance.gd --duels=60 --seconds=30 --reference`, about 3 min, deterministic; combat.md 12.8):
  everything computed in §2.4 holds (bow 97.3, 125.6 and 131.7 DPS; abilities +8.1 and +25.8 with the whole volley;
  the wall holds against one, 558 stamina in 6 s, and two break it at 5.4 s). The bot duels with the kit last
  longer (median 18.4 s versus 10.7 without abilities; 14.9 s with the kit and without potions: each duel drinks on average
  one potion); the reference without abilities gives exactly the figures of 12.3. No `.tres` changes.
- **Tests**: `test_projectile_loopback` ~22 s, `test_abilities_reconciliation` ~19 s, `test_loadout_net` ~15 s, the three
  of `test_bot_cheat` ~16, 22 and 6 s, `test_combat_balance` ~11 s and `test_bot_brain_kit` ~0.7 s (not counting engine
  startup, about 9 s per file).

**For later.**

- With people: the TTK with both templates, the parry, arrow blocking and proposals P4 and P5 of
  combat.md 12.8.
- The cost of projectiles on the Terrain3D (0.3 to 1 ms per tick with arrows: mostly preparing the boxes
  of all candidates, about 6–8 µs per player or NPC, and about 10 µs per live arrow) and `simulate()` (lever 6): what
  is needed to return to 64 per battle with archers.
- ART-41 (drawing and releasing) and ART-12 (icons and VFX); the light swarm without a kit.

### 11.10 Implementation review

Three reviewers on H1a–H5 (prediction and network, server and cheats, test design) and one verifier per
finding who reproduced it with a disposable probe: 11 findings, all confirmed (three "in part") and all of
low severity after verification (RS1 and RD1 arrived as medium). Each fix carries a test that fails without it
(checked by undoing the fix or with the finding's mutant), except RS3 and RD1, which concern capacity and measurement.

| Id | Severity | Finding | Fix |
|---|---|---|---|
| RP1 | low | The remote arrow with DESPAWN 4 on the shot's tick computed `f` without `hit_from_inside` on segment 0: the arrow leaving from inside the closed gate (SER4) passed through it for a whole tick on the other clients (`end_n` 1 versus the server's 0) | `on_despawn` uses `hit_from_inside` if the last segment is the first, like the server (`flown == 0`) and the own one (`k == 0`); §6.2; test in `test_projectile_world` (`end_n` 0 and it is not seen after its tick) |
| RP2 | low | Without the shooter's view (they left interest with their arrow in the air), `_hostile_feet` used realm 0, which is the Hollow's and hostile to everyone: the shooter's allies and the local player stopped the remote arrow | `Arrow.realm` (the SPAWN's `realm`; `_own_realm` on the predicted one) and `_hostile_feet(id, realm)`, without looking up the view; §6.2; test in `test_projectile_world` (an ally of the shooter on the last segment does not count, an enemy does) |
| RP3 | low | After interrupting a consumable before commitment, another (or the same slot) could start at `s + 1` with the same action byte: a one-tick NONE, and a remote player sampling every 2 ticks kept following the first one's clip without restarting it; §5.5 and `ActionWire` said otherwise | `AbilityTicks.REARM_TICKS` = 6 (three snapshot intervals): `impose_interrupt` (`AbilityRules.rearm_after_interrupt`) leaves that margin in the slot's cooldown or the shared one, and the validation of §2.2 requires `cooldown ≥ total + REARM_TICKS` (and the same for the shared one); §2.2, §4.2, §5.5; tests in `test_action_wire` and `test_combat_catalog` |
| RS1 | low (medium) | An executioner with spawn protection was not a candidate for any hit or arrow and executing did not remove it: an execution nobody could cut in its 3 s | Starting an EXECUTE sets `protected_until = min(protected_until, s)` in `DownedSystem._try_start` (it is not rejected: it would be a rejection the client does not predict); §4.2 and §4.5; test in `test_downed` (it loses protection on the tick of INTERACT 4 and a hit from the knocked-down player's ally cuts it with INTERACT 5 and bit 5) |
| RS2 | low | The safe zone was only checked when starting to execute: a knocked-down player crawling to their camp died executed inside, where no hit reaches them | `_safe_area_between` (their realm's or the executioner's) also in `_keeps_going` and on the final tick; §4.5; test in `test_downed` (INTERACT 5 on the tick they enter, without DEATH) |
| RS3 | low (in part) | `ServerConfig.max_players` was still 64 although the measured per-battle limit with the kit is 40, and nothing enforced it | Per-zone capacity: `Zones.MAX_PLAYERS` (Vado Gris, 40) and `NetZones.max_players`, which `ServerConfig.from_args` uses if `--max-players` is not given; a zone without its own capacity stays at 64 (`DEFAULT_MAX_PLAYERS`) and `--max-players` takes precedence; networking.md 1.2 and 14; test in `test_server_config` |
| RD1 | low (medium, in part) | The limit of 40 came from interpolating between 32 and 48, without measuring it, and the cap of 64 arrows never filled under load (§7.3 asked for "the zone cap full") | Measured: the brawl of 40 (30 fake players and 10 bots) gives 12.4 ms tick p99 and 0.90 for projectiles (meets; the verifier, 14.1 and 0.84) and enters `BRAWL_MATRIX`; the full cap, forced with everyone a sky marksman (peak 64, 4603 evicted, 3.09 ms projectile p99); "20 against 20" in the fort, marked as an estimate; networking.md 14 and TEC-15 |
| RD2 | low (in part) | `test_abilities_reconciliation` checked abilities, weapon swaps and potions with the bot's counters (what it wanted to press) and the test always imposed the knock-down | It counts what the server's state starts (abilities, SWAP and drinks), ability hits and HEAL events; the fallback leaves the Solmarch player at 1 health and without health potions mid-fight and the knock-down comes from a hit (HIT with bit 6), with `down()` only at five sixths |
| RD3 | low | The `potion` cheater never ran out of charges (5 in 1300 ticks with 1200 cooldown): removing the charge check from `try_consumable` did not make the test fail | A second cheater at the same time with 1 health charge and 0 stamina (`set_charges`, `commit_state` and LOADOUT to the owner): one health drink and no more, final charges (0, 0) and one heal; the first checks that two drinks are separated by the shared cooldown. With the finding's mutant, it fails |
| RD4 | low | In `test_loadout_net` the choice before CLIENT_READY was the squire, the default template: the test passed even if the server ignored LOADOUT_SELECT in LOADING | Ana chooses the marksman with `--loadout` and appears with it (server, prediction with the bow and what Bruno sees) without respawning; afterwards both choose in the world (Bruno the marksman, Ana the squire) and they apply on respawning. With the finding's mutant, it fails |
| RD5 | low | `ProjectileWorld` considered a predicted arrow rejected using the handshake's RTT (`rtt + 30`), which was never updated: if latency rose by about 470 ms, all own arrows disappeared and came back without a pair | Rejection is measured with the tick of the last snapshot (`on_server_tick`, which `NetClient` calls with each one): no SPAWN when the server passes the predicted one's tick + `input_buffer_ticks` + 30; with no snapshots yet, the input's RTT; and in any case when its life ends; §6.2; test in `test_projectile_world` (RTT of 3 on entry and 45 ticks of lead: replaced, not rejected) |

**Tests.** New: `test_projectile_world` (+3: RP1, RP2 and RD5), `test_action_wire` (+1: RP3, with the margin
also on an ability's slot and without touching the already committed cooldown), `test_downed` (+2: RS1 and RS2)
and `test_server_config` (+1: RS3). Changed: `test_combat_catalog` (the validation cases with `REARM_TICKS`, which
fail with the earlier rule), `test_consumables_machine`, `test_consumables_server` and `test_ability_server` (after
interrupting a drink, the shared cooldown is `s + REARM_TICKS` instead of 0), `test_load_test` (the
`--brawl` battery has 32, 40, 64 and 128), `test_abilities_reconciliation` (RD2), `test_bot_cheat` (RD3) and `test_loadout_net`
(RD4). All files of the touched areas pass: `test_projectile_world`, `test_projectiles`,
`test_projectile_loopback`, `test_net_client`, `test_action_wire`, `test_combat_catalog`, `test_consumables_machine`,
`test_consumables_server`, `test_ability_machine`, `test_ability_server`, `test_ability_reconciliation`,
`test_status_effects`, `test_downed`, `test_action_bar`, `test_bot_brain_kit`, `test_combat_animation`,
`test_server_config`, `test_server_main`, `test_load_test`, `test_zones`, `test_architecture`,
`test_abilities_reconciliation` (twice),
`test_bot_cheat` and `test_loadout_net`.

**Decisions.**

- **RP3 with a margin and not a bit**: the action byte has no free bits (in ABILITY only the phase value 3 is left,
  which is not enough for a robust counter) and a restart bit in another field of the record required changing the
  protocol. The margin goes in the predicted state (`consumable_ready_tick` and `ability_ready`), so reconciliation
  corrects it by itself when the server interrupts, and in play it is 0.1 s. With today's data (cooldowns of 10 to
  20 s) the new validation changes nothing; it only closes the case of future data with a tight cooldown.
- **RS1 removes protection instead of rejecting the execution**: rejecting it would be an INTERACT the client does not predict and the
  press would be lost without notice. REVIVE still does not remove it.
- **RS3 per zone and not global**: `max_players` is the capacity of any zone's process; lowering the global value to 40
  would cut zones without combat that nobody has measured. Tests and tools that need more pass
  `--max-players` or set their own (`load_test.gd` already did).
- **RD5 with the server tick**: it does not depend on the RTT, which rises and falls during the session, and it is what
  "the server did not send it" really means. The margin of 30 ticks covers the SPAWN (reliable channel) arriving somewhat after
  the snapshot of its tick.

**Measured** (4-core machine at rest; `load_test.gd --scenario=brawl`, 60 s of measurement):

- 40 combatants (30 fake players and 10 bots, half marksmen): tick 7.5 / 12.4 / 16.2 ms (p50, p99, max),
  `combat_projectiles` 0.25 ms median and 0.90 p99, 97 shots with a peak of 18 arrows, 35.4 KB/s per
  client, 0.00% substituted inputs in the window and no rewind rejected: **meets** the phase 4
  criterion, with little margin on projectiles. *(Phase 4 review: the server's fake players now request respawn
  on dying and return after 10 s, not 30. Repeated with the earlier code and the current one in the same session, it gives the same
  —14.5 and 14.6 ms tick p99; 1.28 and 1.01 ms for projectiles, both over a millisecond on that pass—, because in
  the measurement minute almost nobody dies: [fortress.md 8.3](fortress.md#83-what-f0-f1-and-f2-left-behind-additions-to-the-contract-and-decisions).)*
- The full cap (54 fake marksmen, pure archers and into the sky, and 10 bots): 4755 shots (57 per second), peak of
  64 live and 4603 evicted by the cap without errors; `combat_projectiles` 1.29 / 3.09 ms and the tick 23.2 ms p99. The
  cap bounds live arrows, not the cost per shot.
