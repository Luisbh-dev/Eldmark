# Eldmark · Phase 3: action combat design

Design of step 3 of the [roadmap](vision.md#hoja-de-ruta): light and heavy attacks,
block, dodge, stamina, latency compensation, death and respawn, over the network and with the
server as the authority. It builds on the phase 2 networking ([networking.md](networking.md), above all §6.7, §8,
§10 and §15).

First and only kit of the phase: **sword and shield**. The other weapons and the abilities with
cooldowns arrive in phase 4 (CMB-19 onwards) on the same pieces.

Reviewed through two lenses (netcode and design) before implementing it; version 2 incorporates their
fixes (substituted inputs, full state, tick order, rewind of the current tick,
precedences, contracts between packages).

---

## 0. Decisions

Taken from the recommendations in [backlog.md](backlog.md#decisiones-pendientes) (provisional,
taken at night; they are in "Decisions taken" in the backlog):

| Question | Decision |
|---|---|
| Classes | No classes: the role is given by the equipped weapons. |
| Equipped weapons | Two slots with quick swap (CMB-24, phase 4). In phase 3 there is only sword and shield. |
| Numbers | **Integers** for health, stamina and damage. |
| Durations in the data | **Seconds** in the `.tres`, converted to ticks on load with `roundi(s · 60)`. The already converted catalog goes into the `sim_hash`. |
| Crits | **Positional, no randomness**: a melee hit from behind (more than 120° relative to the yaw of the victim's body) deals ×1.5. |
| Friendly fire | No. Hits pass through allies. |
| Defensive state with rewind | Protects if the defender was defending on the rewound tick or the current one, with the clarifications in §4.3. |
| Parry | Window of 6 ticks (100 ms) when pressing block, only against melee and with a cooldown. |
| Sprint and stamina | Sprinting does not spend stamina. |
| Own impact | Mixed: swing, trail and weapon sound on prediction; marker and number on confirmation (ENTITY_EVENT). Numbers are never predicted. Since quality wave 4 (decision 6, provisional) the spark, the impact sound and the animation hitstop (50 ms light, 80 ms heavy) are also predicted, as cosmetic only, with a local check of the hit sector against the drawn positions (`CombatFeedback._try_predict`); if the server confirms it as a normal hit they are not repeated. |
| Enemy health | On its nameplate when aiming at it or after damaging it in the last 5 s; boss bar for captains (phase 4). |
| Humanoid NPCs | `PlayerCharacter` with synthetic input (like `BotBrain`). |
| Collision between characters | None, as in phase 2. |
| Respawn | Fixed 10 s in phase 3, with a button; waves every 10 s at the Vado Gris with GUE-14 (phase 4). |
| Accumulated poise | Not in phase 3: only `hyper_armor` per attack and a chain of controls with immunity. |

---

## 1. What is predicted and what the server decides

| Data | Where it lives | Predicted | Travels in |
|---|---|---|---|
| Action, phase, start tick, combo, button press, charge, buffer, dodge direction | `CombatState` inside `PlayerState` | Yes | own state in the snapshot |
| Stamina and exhaustion | `CombatState` | Yes | own state |
| Controls (stagger, stun, knockback), guard break, death | `CombatState`, **imposed by the server** | No: the client adopts them on reconciliation | own state |
| Stamina cost of a blocked hit | `CombatState`, imposed by the server | No | own state |
| Health, "in combat", protection, chain of controls | `Combatant` on the server | No | extra block of the snapshot (own) and `health_q` of the record (others') |
| Hits, damage, crits, kills | `CombatResolver` on the server | No | ENTITY_EVENT |

Rule from networking.md §6.7: everything that the server decides and that changes the simulation goes into
`PlayerState`, so reconciliation absorbs it. Health does not change the simulation (except on
death, which is an action) and that is why it is not in `PlayerState`.

---

## 2. Combat catalog (CMB-02)

`scripts/shared/combat/`, data in `data/combat/` (`.tres` in text). All times are
**seconds since the start of the action** unless stated otherwise; when converting, each window
is an interval of ticks `[from, to)` counted from `action_tick`.

```gdscript
class_name HitShape extends Resource
@export var range_m: float = 2.6
@export var inner_m: float = 0.0
@export var angle_deg: float = 100.0
@export var height_min: float = 0.2          # relative to the attacker's feet
@export var height_max: float = 2.0

class_name AttackDefinition extends Resource
@export var id: StringName
@export var heavy: bool = false
@export var windup_s: float                  # windup (for the heavy: after release)
@export var active_s: float                  # active strike: the shape is tested every tick
@export var recovery_s: float
@export var combo_window_s: float            # last s of the recovery: chains the next light
@export var cancel_to_dodge_from_s: float    # since the start of the action
@export var stamina_cost: int                # 0–1000
@export var lunge_speed: float               # m/s forward during windup and active strike
@export var turn_rate: float                 # rad/s of turn toward the camera during windup and active
@export var move_speed_scale: float          # fraction of run_speed allowed
@export var shape: HitShape
@export var base_damage: int
@export var damage_type: int                 # DamageFormula.DamageType
@export var hyper_armor: bool                # during the active strike, immune to stagger and knockback
@export var stagger_s: float                 # stagger it causes (0 = none)
@export var knockback_speed: float           # knockback it causes (m/s, 0 = none)
@export var charge_min_s: float              # heavies only, counted from the button press
@export var charge_max_s: float
@export var charge_damage_scale: float       # multiplier at max charge (linear from ×1 at charge_min)
@export var charge_move_scale: float
@export var charge_turn_rate: float

class_name DodgeDefinition extends Resource
@export var duration_s: float
@export var invulnerable_from_s: float
@export var invulnerable_to_s: float
@export var distance_m: float
@export var speed_curve: Curve               # shape of the profile; normalized to distance_m
@export var stamina_cost: int
@export var cancel_to_attack_from_s: float

class_name WeaponDefinition extends Resource
@export var id: StringName
@export var light_combo: Array[AttackDefinition]   # 3 hits
@export var heavy_attack: AttackDefinition
@export var block_angle_deg: float                 # total frontal cone
@export var block_mitigation: float                # 1.0 = stops all frontal physical damage
@export var block_move_scale: float
@export var block_turn_rate: float
@export var block_stamina_per_damage: float
@export var dodge: DodgeDefinition

class_name CombatRules extends Resource            # data/combat/combat_rules.tres
# Predicted (they go into prediction_hash):
@export var stamina_max: int = 1000
@export var stamina_regen_per_tick: int = 3          # 180/s
@export var stamina_regen_delay_s: float = 0.6
@export var exhausted_regen_per_tick: int = 1        # 60/s
@export var exhausted_exit_threshold: int = 300
@export var hold_to_heavy_ticks: int = 8
@export var input_buffer_ticks: int = 8
@export var parry_window_ticks: int = 6
@export var parry_cooldown_ticks: int = 30
# Server only (they do not go in):
@export var health_max: int = 1000
@export var health_regen_per_s: int = 20             # out of combat
@export var in_combat_s: float = 10.0
@export var respawn_s: float = 10.0
@export var respawn_protection_s: float = 3.0
@export var cc_chain_window_s: float = 3.0
@export var cc_immunity_s: float = 2.0
@export var fall_damage_threshold: float = 15.0      # m/s
@export var fall_damage_per_mps: int = 70
@export var parry_stagger_s: float = 0.6
@export var guard_break_stun_s: float = 1.0
@export var backstab_angle_deg: float = 120.0
@export var crit_multiplier: float = 1.5
```

**`CombatCatalog`** (RefCounted, static, lazy loading): reads `data/combat/`, assigns u16 IDs
per type (attacks and weapons have separate spaces, **1..n in alphabetical order of `id`, 0 =
none**; a repeated `id` is an error), converts to ticks and bakes the dodge curve into a
table of speeds per tick (`PlayerState.to_f32`) that adds up to `distance_m`. It exposes
`attack(id) -> AttackTicks`, `weapon(id) -> WeaponTicks`, `rules() -> CombatRules` and
`prediction_hash() -> int`: SHA-256 of everything predicted (windows, movement, costs, baked
curve, cancels, block, predicted fields of `CombatRules`). It goes into
`NetProtocol.compute_sim_hash`. Damage, mitigation, crits, controls, health and respawn do not
go in.

Initial values for sword and shield (`data/combat/sword_shield.tres`, tuned in CMB-29):

| Attack | Windup | Active | Recov. | Combo window | To dodge from | Stamina | Damage | Advance | Move | Control |
|---|---|---|---|---|---|---|---|---|---|---|
| Light 1 | 0.20 | 0.10 | 0.30 | 0.15 | 0.40 | 0 | 90 | 1.5 m/s | ×0.3 | — |
| Light 2 | 0.18 | 0.10 | 0.30 | 0.15 | 0.38 | 0 | 90 | 1.5 | ×0.3 | — |
| Light 3 | 0.25 | 0.10 | 0.45 | — | 0.50 | 0 | 130 | 2.0 | ×0.2 | stagger 0.3 s |
| Heavy (charge 0.35–1.2 s from the press, ×1–×1.7) | 0.40 after release | 0.12 | 0.55 | — | 0.70 | 150 | 180 | 2.5 | ×0.2 (charge ×0.4) | stagger 0.5 s, knockback 4 m/s, `hyper_armor` |

Shape of all of them: reach 2.6 m, 100°, heights 0.2–2.0 m; turn 6 rad/s (charge 4). Dodge: 0.45 s,
invulnerable [0.05, 0.30), 4.5 m, fast-exit curve, 300 stamina, to attack from 0.30
s. Block: 120° cone, stops 100% of frontal physical damage, movement ×0.5, turn 8 rad/s,
1.0 stamina per point absorbed.

Light attacks (12 ticks of windup) cannot be reacted to over the network with 150 ms; the reactive parry and
dodge are designed against heavies, whose windup after release (0.40 s) is visible.

---

## 3. Action machine (CMB-03, CMB-04, CMB-06, CMB-13, CMB-14)

### 3.1 `CombatState` (in `PlayerState`, goes into `encode()`)

`PlayerState` gains `var combat: CombatState`; `PlayerCharacter` too, and `get_state()`/
`set_state()` copy it. `PlayerState.ENCODED_SIZE` goes from 35 to **69 B**:

| Offset | Type | Field | What it is |
|---|---|---|---|
| 35 | u8 | `action` | `Action`: 0 NONE, 1 LIGHT, 2 HEAVY, 3 CHARGE, 4 BLOCK, 5 DODGE, 6 STAGGER, 7 STUN, 8 DEAD |
| 36 | u16 | `action_id` | catalog attack (0 if it is not an attack) |
| 38 | u32 | `action_tick` | tick at which the action started |
| 42 | u8 | `combo_step` | 0–2: next light of the combo |
| 43 | u8 | `primary_held` | real ticks that PRIMARY has been held since its edge (0 = no live press; saturates at 255) |
| 44 | u8 | `charge_ticks` | charge ticks when the heavy is launched (read by the server for the damage) |
| 45 | u8 | `buffered` | bits 0–1 type (0 nothing, 1 PRIMARY, 2 DODGE), bits 2–5 ticks it has left |
| 46 | u16 | `stamina` | 0–`stamina_max` |
| 48 | u32 | `stamina_regen_tick` | first tick at which it regenerates again |
| 52 | u8 | `combat_flags` | bit0 exhausted, bit1 last attempt without stamina (for the interface), bit2 infinite stamina (command), bits 3–5 DODGE/BLOCK/PRIMARY buttons held on the previous tick, bit6 light of the live press (§11) |
| 53 | u16 | `action_dir` | quantized yaw (like `look_yaw`) of the dodge |
| 55 | u32 | `cc_until_tick` | end of the current control (exclusive) |
| 59 | s16 × 2 | `knockback` | horizontal knockback (x, z) in cm/s |
| 63 | u32 | `parry_ready_tick` | first tick at which another parry window can open |
| 67 | u16 | `weapon_id` | equipped weapon |

`PROTOCOL_VERSION` goes to 2 (and to 3 with the phase 3 review, which changes the predicted simulation:
bit 6 of `combat_flags`, charge canceled after the client goes silent, combo restarted when the link
expires and air movement of the controls). The absolute ticks make the state restore
unambiguously.

**Phase 4.** Version 5 of `CombatState` (76 B, `PlayerState` of 111 B) adds at the end the other weapon,
the cooldowns, the consumables and the movement effects, and `buffered` becomes bits 0–3 type
and 4–7 ticks: [abilities.md 3.1](abilities.md#31-combatstate-v5).

### 3.2 Substituted inputs (closes the note in networking.md §8.2)

`PlayerInput.SUBSTITUTED = 1 << 15`, outside `VALID_BUTTONS` (the client cannot set it: the
server applies the mask when decoding). `InputQueue.take()` and
`ClientPrediction._input_or_substitute()` set it on the substitute input, which keeps repeating all the
buttons. With that bit, the action machine:

- does not add to `primary_held`, does not turn a light into a charge nor launch the heavy on reaching
  max charge (the charge freezes until the next real input; a substituted one only
  *delays* the conversion, it does not lose it: the `FLAG_LIGHT_OF_PRESS` bit remembers which press
  the light belongs to, §11). The frozen charge lasts at most `input_buffer_ticks` after max
  charge: past that margin with the client still silent, it is **canceled** (to NONE, without launching or
  spending stamina), so that a client that stops sending with the connection alive cannot
  hold a max-charge heavy to release it instantly with the first real input;
- does not open parry windows;
- computes the edges without the bit (`prev_buttons` never stores it).

This way no loss invents a heavy or a parry. Whoever stops sending inputs with BLOCK
held keeps blocking as long as they are not kicked: with the connection alive there is no inactivity
limit (the ENet timeout only fires if the peer stops responding at the ENet level, not if it
stops sending `INPUT_BATCH`). It gives no advantage over an honest player, who can also
block without limit (it spends stamina when receiving hits), and it is accepted.

### 3.3 Rules per tick

`ActionMachine.step()` runs at the start of `simulate()`, before movement, with
`t = input.tick`. Fixed order:

1. **End of actions.** If the action has a duration and `t ≥ end`, it goes back to NONE (or chains the
   linked light, or the content of the buffer). STAGGER/STUN end at `cc_until_tick`.
2. **Stamina.** If `t ≥ stamina_regen_tick` and the action is not BLOCK, CHARGE or DODGE, it regenerates
   (`exhausted_regen` if exhausted). Exhaustion activates on reaching 0 and is removed on
   exceeding `exhausted_exit_threshold`. Every expense (also the one the server imposes) sets
   `stamina_regen_tick = t + delay`.
3. **Inputs** (edges without the SUBSTITUTED bit; priority DODGE > PRIMARY > BLOCK):
   - **DODGE** (edge): if the current action allows it (NONE, BLOCK, LIGHT/HEAVY from
     `cancel_to_dodge_from`, CHARGE), on the ground, with `stamina ≥ cost` and not exhausted: DODGE
     with `action_dir` = direction of `move` relative to `look_yaw` (backwards with no input). If
     the action does not allow it, it goes to the buffer; if it is because of stamina, bit1 is set.
   - **PRIMARY** (edge): `primary_held = 1`. If it can attack (NONE, BLOCK, DODGE from
     `cancel_to_attack_from`) and is on the ground: light `combo_step` starts with
     `action_tick = t`. If there is a light in progress and `t` is in its combo window (or up to
     `input_buffer_ticks` before): the next one is linked, and starts when the recovery ends.
     In any other case, to the buffer.
   - **PRIMARY held** (real): `primary_held += 1`. If it reaches `hold_to_heavy_ticks` and the
     action is a light in windup started by this press (or linked by it): if there is
     stamina ≥ heavy cost and it is not exhausted, it goes to CHARGE with the same `action_tick`
     (it has not struck yet: 12 windup ticks > 8); otherwise the light continues and bit1 is set.
   - **PRIMARY released**: `primary_held = 0`. In CHARGE: if the charge (ticks since `action_tick`)
     is less than `charge_min`, it is launched on reaching `charge_min`; otherwise it is launched now.
     **Launch** = HEAVY with `action_tick = t`, `charge_ticks` = charge, stamina expense.
   - **CHARGE** that reaches `charge_max` with real input: it is launched.
   - **BLOCK** (level): from NONE (or when an action ends with BLOCK held) it enters BLOCK,
     without exhaustion. If it is also a **real edge** and `t ≥ parry_ready_tick`, it opens a parry
     window `[t, t + parry_window)` and sets `parry_ready_tick = t + parry_cooldown`. Releasing BLOCK
     leaves BLOCK.
   - **Buffer**: stores the last PRIMARY or DODGE press not executed during
     `input_buffer_ticks`; it is executed on the first tick at which it can be, with priority over the
     new inputs of that tick. `primary_held` keeps counting in the meantime.
   - After light 3, `combo_step` returns to 0. If a recovery ends without a link, too.
     And also if the link never got executed: a light that ends in the air with a pending link press
     leaves it as a normal stored press, and when it expires (with no light in progress)
     the combo starts over; if it lands within the `input_buffer_ticks`, the link
     is executed as usual.
4. **Allowed movement** (used by `simulate()`):

| Action | Target horizontal speed | Turn | Jump | Sprint |
|---|---|---|---|---|
| NONE | the usual | the usual | yes | yes |
| LIGHT/HEAVY windup and active | `forward · lunge + wish · run_speed · move_scale` | toward `look_yaw` at `turn_rate` even if standing still; on the first tick, the yaw jumps to `look_yaw` | no | no |
| LIGHT/HEAVY recovery | `wish · run_speed · move_scale` | none | no | no |
| CHARGE | `wish · run_speed · charge_move_scale` | toward `look_yaw` at `charge_turn_rate`; on the first tick of the action (light that converts), it jumps | no | no |
| BLOCK | `wish · run_speed · block_move_scale` | toward `look_yaw` at `block_turn_rate` | yes (leaves BLOCK) | no |
| DODGE | **imposed**: `dir(action_dir) · curve[t − action_tick]`, no acceleration | none (the body keeps its yaw) | no | no |
| STAGGER | **imposed**: `knockback · (end − t) / (end − start)` if there is knockback; otherwise it brakes | none | no | no |
| STUN | brakes | none | no | no |
| DEAD | brakes; gravity continues | none | no | no |

Gravity and `move_and_slide` are always applied, so the dodge and the knockback respect walls
and bridge blocks. Actions with movement scaled to 0 (STUN, DEAD and STAGGER without knockback)
also brake in the air: the `simulate()` rule that keeps air momentum while
pushing forward does not apply to them, so the stick does not steer a corpse, a stunned
or a staggered character in mid-jump. No attacks, no dodge, no block in the air: a PRIMARY or DODGE in the
air goes to the buffer.

**Phase 4.** The machine gains abilities, consumables, weapon swap, channeling, knocked down,
getting up and finishing off, and the movement effects, with the order 0–6 of
[abilities.md 3.3](abilities.md#33-reglas-por-tick) and the movement table in its §3.4; that
part lives in `scripts/shared/combat/ability_rules.gd` (`ActionMachine` remains the entry point).

### 3.4 What the server imposes

`ActionMachine` API (static, on `CombatState`), always followed by rounding through
`PlayerState.decode(encode())`. All of them clear the buffer, `primary_held` and `combo_step`:

- `impose_stagger(c, t, until, knockback: Vector2)`, `impose_stun(c, t, until)`: STAGGER or STUN
  with `action_tick = t`, `cc_until_tick = until`.
- `impose_death(c, t)`: DEAD.
- `reset_for_respawn(c, t, rules)`: everything to its initial values (full stamina) except the
  weapon. In phase 4 it becomes `reset_for_respawn(c, t, weapon_1, weapon_2, charges)`, with the gear
  from the loadout, and the impositions in [abilities.md 3.5](abilities.md#35-lo-que-impone-el-servidor) are added.
- `drain_stamina(c, amount, t)`: subtracts, sets the delay and, if it reaches 0, the exhaustion.

Queries (used by the server and the animator): `phase(c, t)` (0 windup or charge, 1 active,
2 recovery, 3 no phases), `is_attack_active(c, t)`, `is_blocking(c, t)`,
`is_parry_window(c, t)`, `is_invulnerable(c, t)`, `defense_flags(c, t) -> int` (bits of
`StateHistory`) and `action_byte(c, t) -> int`: bits 0–3 the action, 4–5 the phase, 6–7 the step of the
combo of the light in progress. The byte that travels in the record is built by `ActionWire`
(`scripts/shared/net/action_wire.gd`, one per entity in the `Combatant`): it is the `action_byte` one
and, for the dodge, the stagger and the stun (which have no combo), bits 6–7 carry a
restart counter that goes up by 1 (modulo 4) with each new action. Without it, two dodges
chained through the buffer (the second starts on the tick the first ends, with no tick in
NONE) or two consecutive controls give the same byte and the remote does not restart the clip.

---

## 4. Hits on the server (CMB-05, CMB-07, CMB-09, TEC-14)

### 4.1 Geometry (`scripts/shared/combat/hit_shapes.gd`)

Pure math, no physics bodies:

- **Annular sector with height** against a vertical capsule (radius 0.4, height 1.8 from the feet):
  horizontal distance to the axis in `[inner − r, range + r]`, angle relative to the attacker's yaw
  within `angle/2 + asin(r / d)`, and overlap of `[height_min, height_max]` with
  `[0, 1.8]` above each one's feet.
- **Segment against capsule** (projectiles, phase 4) and **oriented box** (structures, phase 4).
- **Line of sight**: ray against the world layer (1) from the attacker's chest (1.4 m) to the
  center of the victim's capsule (0.9 m).

### 4.2 Server tick order

Replaces the comment "Phase 3: actions validated against StateHistory" in networking.md §8.1:

1. Simulate **all** entities with a body (players, fakes and NPCs) by `net_id`.
2. **Freeze**: store, for each entity, its state after `s` (position, yaw, `defense_flags`,
   action). It is the "sample of the current tick".
3. **Resolve** all attacks active on `s` against the frozen data and `StateHistory` (§4.3), without
   touching any state: all hits of a tick are simultaneous.
4. **Apply** the results by `net_id` of the attacker and then of the target: damage, stamina
   expense of the block, controls, deaths; then, lethal volumes, fall, deaths by
   y < −100 and expired or requested respawns.
5. Spawns, `_record_history(s)` (already with what was imposed), snapshots and events.

This way an exchange of blows on the same tick resolves both, and the snapshot of `s` already carries what
was imposed: the client reconciles from `s`.

### 4.3 Rewind (`CombatResolver`, `scripts/server/combat_resolver.gd`)

For each attacker in an active strike on `s`:

1. **Parameters.** `InputQueue.get_rewind_params(s) -> Vector2i(view_offset_q, lead)`: those of the
   real input of `s` or, if it was substituted, those of the last real one. Fake players and NPCs
   use `view_tick = s`. **They are read only once per strike**, on its first active tick: the
   rewind (`rewind = s₀ − view_tick₀`) is fixed in the `Combatant` next to `track_swing`, and
   on the other active ticks `view_tick = s − rewind` (it advances with the tick). Before, each active tick
   read its own `view_offset_q` and a modified client swept the window (0, 5, 10... 24) or
   removed the retroactive defenses with a 0 on the ticks that suited it.
2. **Cap.** `allowed` from networking.md §10, with a `lead` that the client does not choose at will: that of the
   strike's input, but at most the client's **usual** one plus 3
   (`InputQueue.get_typical_lead(s)`, the median of the first-copy leads of the
   real inputs of the last 60 ticks; 3 is the spread of an honest client with jitter) and never more
   than 8 (`_MAX_LEAD_CREDIT`: what an honest client keeps with `TickSync`, target margin ≤ 4
   plus the slack of its window). An honest client loses nothing (its view is `rtt + input lead
   + interpolation`, so with the lead of that input it never ends up above the
   cap), but a client that advances only the inputs of its strike by 14 ticks no longer raises the cap from
   12 to 24 with LAN RTT. If `view_offset_q / 16 > allowed + 8`
   (`CombatResolver.REWIND_REJECT_SLACK_TICKS`), the hit is **not tested**: it adds to the
   suspicion score and goes to the `--combat-log`. Otherwise, `view_tick = clamp(s − view_offset_q / 16, s − allowed, s)`:
   whatever exceeds the cap without reaching rejection is clipped. *(Phase 4 review, "cheats" lens: the
   rejection started at `allowed + 1` and an honest client with a hitch or low FPS, which chains up to 8 physics
   steps in one frame and declares the view of the last one drawn, lost the hit and added suspicion; see
   networking.md §10. The interpolation of the cap is now rounded up.)* **Minimum for the defense:**
   the retroactive defenses (invulnerable, parry, block; step 6) look back at least `max(0, rtt_floor + 4 − 2)` ticks
   (`ServerPeer.rtt_floor_ticks` is the ENet RTT, which the client does not control, and 4 the minimum
   interpolation delay), even if the hit asks for less: an honest client never sees the world with less
   delay, and asking for 0 no longer gets rid of them. The geometry (step 3) stays at the requested `view_tick`.
   *Known limits:* a cheater still chooses the rewind, once per strike, between that
   minimum and the cap; and with all its inputs advanced (up to the maximum of 8) and `interp_delay_q`
   at the maximum it reaches the global cap of 24 (an honest client with the same RTT, about 10-16): the server cannot
   verify the declared interpolation, so the cap of 24 ticks (400 ms) is the bound
   on the possible damage.
3. **Samples.** The attacker, always in its frozen state of `s`. Each candidate: if
   `view_tick ≤ s − 1`, `StateHistory.sample(id, view_tick)`; if it is between `s − 1` and `s`,
   interpolation between the track of `s − 1` and the frozen data of `s`; if it is `s`, the frozen data. A
   null sample (it appeared later) discards the candidate.
4. **Candidates**: hostile according to `FactionRules`, alive now (`Combatant.health > 0`) and without the
   "dead" bit at `view_tick`, without respawn protection at `s`, and without a safe zone in
   between at `s` (§5: neither the victim inside the safe zone of its own realm, nor the attacker
   inside that of its own realm). A target already hit (or blocked or parried) by this
   action is not tested again.
5. **Shape** with the victim's sample and **line of sight** against the current world.
6. **Defense**, in this order of precedence:
   - **Invulnerable** on some tick of `[floor(defense), s]` (`defense` = the `view_tick` or, if it is
     later, the minimum for the defense from step 2): no effect and it does **not** consume the hit (it may
     enter on a later active tick).
   - **Parry**: parry window in the sample at `view_tick` or in the one at `s`, with the attacker
     inside the defender's frontal cone in that sample (body yaw), melee only:
     no damage, stagger of `parry_stagger_s` on the attacker. Consumes the hit.
   - **Block**: blocking in the sample at `view_tick` or in the one at `s`, with the cone: mitigation and
     stamina expense. Consumes the hit.
   - The sample at `view_tick` only counts for parry and block if the defender has **not** lowered the
     shield afterwards: its action at `s` is different from BLOCK and NONE and has `action_tick > view_tick`
     (its own LIGHT, HEAVY, CHARGE and DODGE, but also imposed STAGGER, STUN or DEAD). Whoever
     drops the shield to attack, or whoever has it taken away by a control, stops being protected;
     whoever drops it for no reason (NONE keeps the block's `action_tick`) keeps what the
     attacker saw. Without this, a stunned character who was blocking 20 ticks ago "blocked" the light of a
     second attacker with rewind: with 0 stamina that is a guard break that
     lengthened its stun.
     **Phase 4** ([abilities.md 4.2](abilities.md#42-habilidades), package H3a): the rule becomes
     "it does not count if the action at `s` is not BLOCK and its `action_tick > view_tick`, **whether NONE or
     not**". NONE keeps the `action_tick` of what ends (`_to_none` and `impose_interrupt`): dropping
     the shield for no reason still counts, but returning to NONE after drinking, an interrupted potion or a
     released REVIVE (started after `view_tick`) no longer does. The shield wall (bit 7 of the history,
     `DEFENSE_WIDE_BLOCK`) blocks with the cone of `ability_block_angle_deg` in the sample that
     carries it.
     **Projectiles** ([abilities.md 4.4](abilities.md#44-proyectiles-projectilesystem-scriptsserverprojectile_systemgd),
     package H3b): the rewind of step 2 comes from `CombatResolver.compute_rewind` (factored out of
     `_swing_rewind`), is rounded to whole ticks and is fixed once per shot for the whole flight; the
     defenses are the ones here without parry, with the cone facing the direction the arrow comes from.
   - If none applies: **impact**.

`StateHistory` adds to its per-tick flags: bit 3 blocking, bit 4 parry window, bit 5
invulnerable, bit 6 dead (`ActionMachine.defense_flags`); in phase 4, bit 7 wide block (the shield
wall). Bits 0–2 are those of the record (`EntityRecord.HISTORY_FLAGS_MASK`): its bit 3 (weapon
slot 2) never goes in ([abilities.md 3.6](abilities.md#36-consultas)).

### 4.4 Damage (`scripts/shared/combat/damage_formula.gd`)

```
raw     = base × charge × crit
mitig.  = raw × block_mitigation          (only if blocked)
final   = roundi((raw − mitig.) × 1000 / (1000 + armor)),  minimum 1 if anything is left
```

- `charge = lerp(1, charge_damage_scale, (charge_ticks − charge_min) / (charge_max − charge_min))`
  for heavies; 1 for lights.
- Crit ×1.5 if the attacker is more than 120° from the yaw of the victim's body (from its
  sample).
- Damage types slashing, piercing, blunt, elemental, with resistances per type (0 in
  phase 3). Armor 0 in phase 3.
- **Block**: the defender spends `roundi(mitig. × block_stamina_per_damage)`. If it falls short, only the
  proportional part is absorbed, the rest goes through as damage and there is a **guard break**
  (stun of `guard_break_stun_s`).
- **Controls from the hit**: the attack's stagger and knockback, unless the victim is in an active strike
  of an attack with `hyper_armor` (parry and guard break always apply). Chain:
  `Combatant.cc_chain` counts the controls in `cc_chain_window_s`; the third does not apply and opens
  `cc_immunity_s` of immunity. CHARGE can be interrupted.

### 4.5 Anti-cheat (TEC-14)

The client only sends buttons; the server checks phases, stamina and rhythm with its own
simulation, so a modified client does not attack faster or without stamina. Substituted
inputs invent nothing (§3.2): neither a charged heavy that is held in silence, nor a parry.
The rewind is watched (§4.3, step 2: fixed per strike, with stable lead and a minimum for the
defense) with a **suspicion score** per peer (hits beyond the cap,
anomalous hit ratio) that in phase 3 is only logged. New modes of the cheating bot:
`rewind` (view_offset_q of 40 ticks), `reach` (attacks from 5 m) and `rate` (PRIMARY every tick):
none of them should do extra damage.

---

## 5. Health, events, death and respawn (CMB-10, CMB-15, CMB-41, GUE-03, GUE-05)

- **`Combatant`** (server, one per entity that takes damage): health and maximum, `in_combat_until`,
  `protected_until`, `death_tick`, `respawn_tick`, `cc_chain`, `DamageLedger` (900 ticks),
  `last_enemy_hit` (to credit falls), and whether it is immortal (dummy).
- **Health regeneration** out of combat. "In combat" lasts 10 s after dealing or taking damage.
- **Death**: health 0 → `impose_death`, `death_tick`, `respawn_tick = s + respawn_s`, a single
  DEATH (victim, author, attack) and a KILL (killer, attack, assistants with ≥ 10% of the damage in 900
  ticks; allies and self-harm do not count).
- **Respawn**: from `respawn_tick` the client can request it with **RESPAWN_REQUEST**
  (`point_index`); after 30 s without requesting it, automatic at the first point (with the phase 4 waves, in
  the first wave from then on: [fortress.md 5](fortress.md#5-avisos-reaparición-salida-y-atascado)). Points: nodes of the group
  `respawn_points` (or, if the zone has none, `spawn_points`) with `realm` metadata, in the order of the
  scene, which the client knows because it loads the same zone; in phase 4 the index becomes that of the
  **static** list of all points and the condition is added (the own fort, not under attack:
  [fortress.md 5](fortress.md#5-avisos-reaparición-salida-y-atascado)). On respawning: teleport (counter), `reset_for_respawn`, full health,
  `protected_until = s + 3 s` (lost when starting an attack), RESPAWN event.
- **Phase 4** ([abilities.md 4.5 and 4.6](abilities.md#45-derribado-levantar-y-rematar-downedsystem-scriptsserverdowned_systemgd),
  H3c): the killing blow of a **player** of another realm against a player in an RVR zone does not kill, it **downs**
  (DOWNED, 20 s of bleeding out, getting up and finishing off); against NPCs, the environment or the Hollows, direct death. A
  downed character is neither alive nor dead (`Combatant.is_downed`), does not respawn or heal, and its kill counts as a
  death first. Respawn sets the weapons and charges of its **loadout** (the one chosen with LOADOUT_SELECT or the
  default one) with LOADOUT.
- **Fall**: `PlayerCharacter.last_landing_speed = −velocity.y` measured **before**
  `move_and_slide()` on the tick when `grounded` becomes true (0 on the others). Damage
  `(v − 15) × 70` above 15 m/s: jumping from the 3 m walkway (14.0 m/s) does no damage; the
  12 m tower (23 m/s) takes 560. It is credited to the last enemy that hit in 10 s.
- **Lethal volumes**: `Area3D` of the group `lethal_volumes` (layer 2 mask) that the
  server checks every tick; they kill.
- **Below y = −100**: death and the body is taken to its spawn point (counter) with velocity
  0 while it is DEAD; `_check_motion` does not act on DEAD entities; a single DEATH per
  `death_tick`.
- **`FactionRules`** (`scripts/shared/war/faction_rules.gd`):
  `static func can_damage(attacker_realm: int, victim_realm: int, zone_id: StringName) -> bool`:
  no friendly fire, Hollows (code 0 with neutral faction) hostile to everyone, enemy realms only in
  RVR zones. `Zones.get_pvp_mode(zone_id) -> PvpMode` (SAFE or RVR; Vado Gris and test_world RVR).
  **Safe zones**: `Marker3D` of the group `safe_areas` with `realm` and `radius` (24 m) metadata at
  each Vado Gris camp. **It only protects its realm**: a player of that realm inside neither
  takes damage nor deals it (it is not possible to attack safely from inside; nor can its shield wall be used for
  arrows, abilities.md §4.4); an enemy intruder inside can be
  damaged, by the Gate Guardians of phase 4 (NPCs with `ignores_safe_area`).

---

## 6. Protocol (TEC-13): `PROTOCOL_VERSION = 2`

- **`PlayerState`** of 69 B (§3.1).
- **Other players' ENTITY_SPAWN**: its `PlayerState` goes with the weapon's neutral `CombatState` (full stamina,
  no flags, buffer, controls or parry), except the action in progress (`action`, and `action_id` and
  `action_tick` if it is not NONE) and the weapon, and with `prev_buttons` and the jump counters at 0: the rest is
  the enemy's private state (§1: stamina travels in the "own state") and must not be dumped on whoever
  enters the zone. The own SPAWN carries it whole. The format (69 B) does not change.
- **Own extra block**, in **every** snapshot with own state (bit 3 of `flags` ⇔ bit 0;
  `decode` rejects bit 3 without bit 0), after the own state: `u16 health`, `u16 max_health`, `u8
  status` (bit0 in combat, bit1 protected, bit2 dead), `u32 respawn_tick` (0 if alive). 9 B.
- **21 B entity record**: `u8 health_q` at the end, `0` if dead and otherwise
  `clampi((health · 255 + max − 1) / max, 1, 255)`. `EntityRecord.encode_character(bytes, offset,
  net_id, character, teleport_counter, action, health_q)`. Header with own state and block:
  13 + 69 + 9 + 1 = 92 B; with one section (2 B), ⌊(1200 − 94) / 21⌋ = **52 records**.
- **ENTITY_EVENT** (`0x23`, channel 3), format reserved in networking.md §5.6: `u8 type`, `u16 net_id`
  (the entity it is attached to: victim or respawning entity), `u32 tick`, `u8 event`, `u8 len`,
  data:
  - `1 HIT`: `u16 attacker`, `u16 amount`, `u8 damage_type`, `u8 flags` (bit0 crit, bit1
    blocked, bit2 parried, bit3 guard break, bit4 lethal), `u16 attack_id`. 17 B.
  - `2 DEATH`: `u16 killer` (0 = environment), `u16 attack_id`. 13 B.
  - `3 KILL`: `u16 killer`, `u16 attack_id`, `u8 n`, `n × u16` assistants. 14 + 2n B.
  - `4 RESPAWN`: `u8 point`. 10 B.
  - **Recipients**: the owners of the attacker and the victim (and of killer and assistants in
    KILL) and whoever has any of them as relevant.
  - **Timing**: an event is **own** if the local player is attacker, victim, killer
    or assistant; its marker, number and HUD are applied on arrival. The visual reaction of a remote
    (flash, shake, animation) is applied when its `render_tick` reaches `tick`. That also holds
    when the remote is the victim (or the dead one) of an own event: `CombatFeedback`
    applies on arrival what belongs to the local player and keeps the flash, the health nameplate
    (`entity_damaged`) and the remote's death or kill sound in its own queue until that
    `render_tick`. The same for the remote's `StatusTracker` (its icons on the nameplate): `NetClient` passes it
    the own events at that `render_tick`, in the queue of the others' (abilities.md §6.4; phase 4
    review).
- **RESPAWN_REQUEST** (`0x05`, C→S, channel 3): `u8 type`, `u8 point_index`. Out of time or with an
  invalid index it counts a warning.
- **DEBUG_COMMAND** (TEC-19) with fixed ids in `NetProtocol`: 1 `teleport` (unchanged), 2 `heal`,
  3 `kill`, 4 `stamina_inf` (bit2 of `combat_flags`: the machine does not spend), 5 `set_weapon`, 6
  `spawn_dummy`. Only with `--debug-commands`. `announce`, `kick` and `shutdown <s>` are **console
  only** (server stdin) until the GM roles (TEC-23). `CommandRegistry` (server)
  checks on registration that every network command has its id in the table; every use is left in the log.
- `sim_hash` includes `CombatCatalog.prediction_hash()`.
- **Bandwidth**: downstream = (94 + n · 21 + 40) B × 30/s (10 visible: ~10.3 KB/s; cap from 52
  visible: ~37 KB/s) plus the ENTITY_EVENTs (~27 B per recipient and hit). networking.md §5.5, §5.6, §9.3, §14 and
  `test_snapshot_builder` must be updated.

**Phase 4: protocol 6** ([abilities.md 5](abilities.md#5-protocolo-protocol_version--6), package H2).
`PlayerState` goes to 111 B (header with state and extra block of 134 B, **50 records** per snapshot;
downstream of ~11.6 KB/s with 10 visible and the same cap of ~36.8 KB/s from 50); the valid buttons, to bits
0–12; the `u16 attack_id` of HIT, DEATH, KILL and TELEGRAPH become a **source** (`CombatSource`: the
attacks of this phase keep their number); HIT gains bits 5 (interrupted) and 6 (downs); bit 3 of the
`status` of the extra block is "downed" and bit 3 of the record's `flags`, weapon slot 2; the other player's SPAWN
also shows the other weapon and the active slot; there are events 7–11 (STATUS, HEAL, LOADOUT, DOWNED,
INTERACT), LOADOUT_SELECT (`0x07`), the projectile SPAWN (kind 3, 32 B) with DESPAWN 4 and 5, and the
debug commands 13 `cooldowns_off`, 14 `apply_status`, 15 `down` and 16 `refill`. Formats in networking.md
§5 (marked "v6").

---

## 7. NPCs and dummy (MUN-02, CMB-11)

- `NPC` type in `NetEntity` with the 21 B record. Its body is a `PlayerCharacter` simulated
  by the server in the same loop as the players (by `net_id`) with inputs from an `NpcBrain`
  that enter its `InputQueue` like those of fake players; it is recorded in `StateHistory`.
- **Training dummy**: fixed NPC, **immortal** (health does not drop below 1, it emits neither DEATH nor
  KILL) that heals fully after 5 s without damage, with modes standing still, blocking and spinning (command
  `spawn_dummy`). One in `test_world` and one next to each Vado Gris camp (markers of the
  group `dummy_points`).
- **War NPCs (F4, MUN-07, MUN-08)**: the NPCs' weapons are `data/combat/npc_*.tres` (Hollow, realm guard,
  Captain, Guardian) and are requested by name. They go into the catalog, so, by alphabetical order, the `npc_*` come before
  the `sword_*` and the numbers change (`sword_shield` 1 to 5, `sword_heavy` 1 to 9...) and so does the `sim_hash`; the tests look up
  by `id`. `AttackDefinition.unblockable` (server only, not in the prediction hash, `AttackTicks.unblockable`) makes
  the `CombatResolver` give IMPACT even if the defender parries or blocks; the invulnerable dodge still works. `Combatant.ignores_safe_area`
  lets the Gate Guardian attack in the safe zone of its own realm. The brain (`HfsmBrain`) and the TELEGRAPH warning are
  in `docs/fortress.md` 8.3.
- **Combat log** (`--combat-log=<csv>`): `tick, attacker, target, attack, view_tick,
  rewind, result, damage`.
- **DPS meter** in the F3 panel: adds up the `amount` of own HITs in a 30 s window.

---

## 8. Client (UI-07, UI-10, UI-12, UI-13, UI-14, ART-06, ART-08, ART-09)

- **Action detection without signals**: `CombatFeedback` and `CharacterAnimator` compare, after
  each physics tick, `(action, action_id, action_tick)` of the displayed state with the last one they
  saw, and launch or cut the swing, trail and clip from there. No combat signal inside
  `simulate()`: replays do not duplicate or lose effects. A correction that only moves the
  start of the same action by up to `input_buffer_ticks` ticks (the server substituted the edge's input
  and dodged one tick later) is not a new action for `CombatFeedback`: it does not repeat the
  warning or the sound. Two chained dodges (27 ticks apart) are two.
- **`CombatFeedback`**: receives the already timed ENTITY_EVENTs and distributes impact marker and
  damage number (UI-12), flash and shake (ART-09), sound hooks (ART-11) and the DPS
  meter.
- **HUD** (UI-10): health (from the extra block) and stamina (from the local state) at the bottom center, ghost
  segment, blinking with bit1, damage direction arcs.
- **Nameplates** (UI-07, UI-13): name and realm color; health bar from `health_q` for enemies
  under the reticle or damaged in the last 5 s, and for allies always.
- **Death** (UI-14): dimmed HUD, who defeated you and with what, countdown to `respawn_tick`,
  Respawn button and list of points of your realm.
- **Animation** (ART-08): combat layer over locomotion, reading `action_byte` of the local
  state or of the remotes' record; clips from UAL1/UAL2 (`Sword_Attack`, `Roll`, `Hit_Chest`,
  `Death01`...) rescaled to each phase. Fine tuning is left to the user.
- **Weapons** (ART-06): provisional meshes (box for the sword, flattened cylinder for the shield)
  in `BoneAttachment3D` of the hands until the models arrive.

---

## 9. Packages and contracts

### 9.1 Packages

| Package | Contents | Depends on |
|---|---|---|
| **K1a · simulation** | `CombatState`, `HitShape`, `AttackDefinition`, `DodgeDefinition`, `WeaponDefinition`, `CombatRules`, `CombatCatalog`, `data/combat/*.tres`; `PlayerState`/`PlayerCharacter` with `combat`, `ActionMachine` (§3) and its call in `simulate()`; `last_landing_speed`; SUBSTITUTED bit in `PlayerInput`, `InputQueue.take()` and `ClientPrediction`; `sim_hash` with the catalog | phase 2 |
| **K1b · pure rules** | `hit_shapes.gd`, `damage_formula.gd`, `FactionRules`, `Zones.get_pvp_mode` | phase 2 |
| **K2 · protocol** | `PROTOCOL_VERSION = 2`, 21 B record, extra block, ENTITY_EVENT, RESPAWN_REQUEST, command ids, networking.md updated | phase 2 (uses `PlayerState.encode()` whatever its size) |
| **K3 · server** | `Combatant`, tick order (§4.2), `CombatResolver` (§4.3), `InputQueue.get_rewind_params`, flags in `StateHistory`, death, respawn and RESPAWN_REQUEST, fall, lethal volumes, safe zones, NPC and dummy, `CommandRegistry` and console, `--combat-log`, suspicion score | K1a, K1b, K2 |
| **K4 · client** | events by `render_tick`, `CombatFeedback`, health and stamina HUD, marker and numbers, nameplates with health, death screen with respawn, animation layer, provisional weapons, DPS in F3 | K1a, K2 |
| **K5 · integration** | loopback with NetSim rtt=150 (≥ 95% hit rate against a target moving sideways; 0 impacts with `view_offset_q` of 30 ticks against a stationary target; 40 since the phase 4 review, because of the rejection slack), cheating bot `rewind`/`reach`/`rate`, combat `BotBrain`, reconciliation with rtt=120 and 5% loss, load with melees of 32, 64 and 128 bots, player limit noted in networking.md, sandbox demo with the combo | K3, K4 |

K1a, K1b and K2 go in parallel; then K3 and K4 in parallel; K5 at the end.

Outside K1–K5, in another lane of the same phase: ART-10 (audio infrastructure, no sounds
until the packs arrive), UI-02, UI-09, UI-16, SOC-02, TEC-12. Left for the user: ART-04
(purchase of UAL1 Pro), final ART-06 and ART-07 (models and clip trimming), ART-09 and ART-11
with real assets. `AbilityDefinition` moves to CMB-19 (phase 4).

### 9.2 Contracts

```gdscript
# scripts/shared/combat/combat_state.gd
class_name CombatState extends RefCounted
enum Action { NONE, LIGHT, HEAVY, CHARGE, BLOCK, DODGE, STAGGER, STUN, DEAD }
const ENCODED_SIZE: int = 34
var action: int; var action_id: int; var action_tick: int; var combo_step: int
var primary_held: int; var charge_ticks: int; var buffered: int; var stamina: int
var stamina_regen_tick: int; var combat_flags: int; var action_dir: int; var cc_until_tick: int
var knockback: Vector2; var parry_ready_tick: int; var weapon_id: int
func encode_into(bytes: PackedByteArray, offset: int) -> void
static func decode_from(bytes: PackedByteArray, offset: int) -> CombatState
func duplicate_state() -> CombatState
static func initial(rules: CombatRules, weapon_id: int) -> CombatState

# scripts/shared/combat/action_machine.gd
class_name ActionMachine extends RefCounted
class Output:
	var move_scale: float = 1.0; var lunge_speed: float = 0.0
	var turn_rate: float = -1.0           # -1 = normal turn from simulate()
	var snap_yaw: bool = false            # the yaw jumps to look_yaw this tick
	var forced_velocity: bool = false; var velocity: Vector3 = Vector3.ZERO
	var allow_jump: bool = true; var allow_sprint: bool = true
static func step(c: CombatState, input: PlayerInput, grounded: bool) -> ActionMachine.Output
static func phase(c: CombatState, tick: int) -> int
static func is_attack_active(c: CombatState, tick: int) -> bool
static func is_blocking(c: CombatState, tick: int) -> bool
static func is_parry_window(c: CombatState, tick: int) -> bool
static func is_invulnerable(c: CombatState, tick: int) -> bool
static func defense_flags(c: CombatState, tick: int) -> int
static func action_byte(c: CombatState, tick: int) -> int
static func impose_stagger(c: CombatState, tick: int, until_tick: int, knockback: Vector2) -> void
static func impose_stun(c: CombatState, tick: int, until_tick: int) -> void
static func impose_death(c: CombatState, tick: int) -> void
static func reset_for_respawn(c: CombatState, tick: int) -> void
static func drain_stamina(c: CombatState, amount: int, tick: int) -> void

# scripts/shared/combat/hit_shapes.gd
class_name HitShapes extends RefCounted
static func sector_hits_capsule(origin: Vector3, yaw: float, shape: HitShape,
		capsule_feet: Vector3, radius: float, height: float) -> bool
static func segment_hits_capsule(a: Vector3, b: Vector3, capsule_feet: Vector3, radius: float,
		height: float) -> bool
static func has_line_of_sight(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> bool
static func is_in_front(defender_pos: Vector3, defender_yaw: float, attacker_pos: Vector3,
		cone_deg: float) -> bool

# scripts/shared/combat/damage_formula.gd
class_name DamageFormula extends RefCounted
enum DamageType { SLASH, PIERCE, BLUNT, ELEMENTAL }
class Result:
	var damage: int; var absorbed: int; var stamina_cost: int; var critical: bool
	var guard_break: bool
static func compute(attack: AttackTicks, charge_ticks: int, critical: bool, blocked: bool,
		block_mitigation: float, block_stamina_per_damage: float, defender_stamina: int,
		armor: int) -> DamageFormula.Result
static func is_backstab(attacker_pos: Vector3, victim_pos: Vector3, victim_yaw: float) -> bool

# scripts/shared/war/faction_rules.gd
class_name FactionRules extends RefCounted
static func can_damage(attacker_realm: int, victim_realm: int, zone_id: StringName) -> bool
```

---

## 10. Risks

- **Cost of `simulate()`**: the action machine adds work per character. Measured in K5: 69–72 µs
  per character, versus the 42–50 µs of phase 2 (networking.md 14); it is the bottleneck of melees.
- **Parry with latency**: a 6-tick window with 150 ms of RTT can be a lottery. It is measured in
  CMB-29 (12.7: the first pass only calculates it; it is decided with people); if it does not work, it becomes a
  shield ability.
- **Light attacks impossible to react to over the network** (12 ticks): intentional; the reactive defense is
  against heavies.
- **Animation**: the free clips cover neither impact on block nor sideways dodge (art.md). Substitutes
  are used and noted.
- **Bandwidth**: +34 B of state, +9 B of block and +1 B per record per snapshot (~2.7 KB/s
  more at the cap) and 52 records per snapshot instead of 57.

---

## 11. Changes during implementation

Gaps in the document that were closed when implementing (K1a, K1b, K2):

- **`combat_flags`**: besides bits 0–2, bit 3 DODGE, bit 4 BLOCK and bit 5 PRIMARY store
  whether the button was held on the previous tick; this way the edges do not depend on `prev_buttons` and
  a control imposed with the button held does not create a phantom attack. Bit 1 lasts one tick. Bit
  6 (`FLAG_LIGHT_OF_PRESS`) marks that the light in progress belongs to the live press (next
  point).
- **Buffer**: type 3 = combo link (the press in the link window waits for the end of the
  recovery; 4 bits were not enough for 9 + 8 ticks). A single slot; the press of tick `p`
  is valid on `p+1 … p+8`; the stored dodge uses `move`/`look_yaw` of the tick on which it is executed; a
  dodge rejected for stamina is discarded.
- **Conversion to charge**: "light started by this press" is told by bit 6 of `combat_flags`
  (`FLAG_LIGHT_OF_PRESS`): `_try_start_light` sets it when the light starts with the live press
  down (edge of that tick, or buffer or link that it left) and releasing PRIMARY, starting another
  action or a control clears it. Before, it was deduced from `action_tick ≥ t − primary_held + 1`, which is only valid without
  substituted inputs: `primary_held` does not count the substituted ones, and with a gap the server never
  converted the light (the client had predicted the charge). Now a substituted input between
  `p+1` and `p+7` delays the charge one tick for each one (it keeps counting real ticks and requires
  windup), it does not cancel it. Holding PRIMARY from the link window turns the next
  light into a charge. The encoded size does not change.
- **Movement in actions**: literal target speed `wish · run_speed · move_scale (+ advance)`
  without the backward, sideways or sprint multipliers (extra field `scaled_movement` in
  `Output`). BLOCK is left when the button is released or in the air. The parry window also requires that
  the BLOCK be the one that opened it.
- **`action_byte`**: NONE, BLOCK and DODGE carry phase 3 ("no phases"), so NONE is `0x30`;
  whoever reads the action uses `byte & 15`.
- **IDs**: alphabetical order; `sword_heavy` = 1, `sword_light_1..3` = 2..4. They are requested by name
  (`CombatCatalog.attack_id()`, `WeaponTicks.light_ids/heavy_id`).
- **`reset_for_respawn(c, tick)`** without `rules` (it takes them from the catalog).
- **`DamageFormula.compute`** receives the loose fields (`base_damage, charge_ticks,
  charge_min_ticks, charge_max_ticks, charge_damage_scale, critical, blocked, block_mitigation,
  block_stamina_per_damage, defender_stamina, armor, crit_multiplier`). The block does not distinguish
  elemental damage: `is_physical()` lets the server decide.
- **`HitShapes.has_line_of_sight(space, attacker_feet, victim_feet)`** adds the heights (1.4 and
  0.9 m); `is_ray_clear` for points already calculated.
- **`FactionRules`**: an unknown realm code neither damages nor takes damage; Hollows are
  hostile to realms in any zone, not to each other.
- **Extra block**: always present whenever the own state is (bit 0 ⇔ bit 3). Until `Combatant`
  exists, `NetEntity.set_health_view()` announces 1000/1000.
- **Measured cost** of `simulate()` (microbenchmark, one world): without action +4–5 µs compared to phase 2
  (16.9 µs standing still, 37.9 µs running); blocking 48 µs; mixed combat 44 µs.

Closed during K3 (server) and K4 (client):

- **Server classes**: `CombatDirector` (the combat step of the tick: freeze, resolve,
  apply, environment, respawns, publish), `CombatResolver` (only calculates: returns impacts),
  `CombatTiming` (deadlines in ticks), `Combatant`, `DamageLedger`, `SafeAreas`, `CommandRegistry`,
  `ServerConsole` and `NpcBrain` (extends `BotBrain`).
- **RESPAWN_REQUEST**: the index goes over `NetZones.get_respawn_points(zone, realm)`, the same list
  on server and client (`RespawnPointList` uses it as is). An index that is no longer valid uses the
  first point, without a warning. A request up to 12 ticks before `respawn_tick` stays pending;
  before that, or while alive, it is a warning. The automatic one arrives at 30 s **from death**.
  *(Phase 4 review: with waves (`respawn_wave_ticks`), the automatic one also falls in a wave, the first ≥
  death + 30 s (`Combatant.auto_respawn_tick`, `CombatTiming.auto_respawn_tick_for`); before, it came out at exactly 30 s,
  outside a wave. The server's fake players request respawn on dying
  (`Combatant.requests_respawn_on_death`, point 0) and the `--bot` as soon as the server's estimated tick reaches
  `respawn_tick` (it repeats it every second while still dead), like the `SwarmBot`: all respawn like
  someone pressing the button as soon as they can, at 10 s (or in their wave) and not at 30.)*
  *(Changed in F3, phase 4: the index goes over `NetZones.get_all_respawn_points(zone)`, the static list
  of all points; the server validates with `RespawnRules.points_for` and, if it is not valid, uses the first
  valid camp of the realm; see [fortress.md 8.3](fortress.md#83-lo-que-han-dejado-f0-f1-y-f2-añadidos-al-contrato-y-decisiones).
  `CombatDirector.get_respawn_points(realm)` no longer exists: they are `get_all_respawn_points()` and
  `get_valid_respawn_points(realm, tick)`.)*
- **Static targets (F3)**: `CombatResolver.structure_targets` (the fort gates,
  `StructureTarget`) is tested for each active attack before the rewind, with `Outcome.STRUCTURE`; the
  director applies the damage with the multipliers from `CombatRules` and announces it with `structure_hit`. The KILL
  goes to the whole zone. With any fortress in the zone, `CombatTiming.respawn_wave_ticks = 600`: respawn
  comes out in waves of 10 s.
- **Chain of controls**: it counts all controls (also the parry's stagger and the
  guard break). `hyper_armor` only cancels the stagger and knockback of impacts.
- **"In combat"**: a block, a parry and a fall also set it. Respawn protection
  is also lost when starting a charge.
- **Dummy**: neutral NPC "Maniquí", modes standing still, blocking and spinning, cap of 16; `ServerMain`
  puts one at each `dummy_points` (`--no-dummies` avoids it). Its HIT carries the full damage
  computed even though health stays at 1, so that the DPS meter counts it in full.
- **Fall and environment deaths**: HIT with attacker 0 and blunt type; DEATH with `attack_id` 0 and
  author the last enemy in 10 s; KILL only if there is an author.
- **Vado Gris safe zones**: at (0, 6.25, ±138), radius 24; dummies at (0, ±108). Added by
  hand to the `.tscn` and to the generator (which has not been run here).
- **Commands**: the network ones act on whoever sends them; malformed data = warning, impossible =
  rejected without a warning; everything is audited. Console over stdin **only with `--console`**; on Linux,
  with the input open, the process does not end after closing until it receives a line or Ctrl+D.
- **`--combat-log`**: header `tick,attacker,target,attack,view_tick,rewind,result,damage`
  and results `hit`, `blocked`, `guard_break`, `parried`, `invulnerable`, `rewind_rejected`.
- **Client**: events are own according to the ids; others' wait in `CombatEventQueue`
  (cap 512) until their `render_tick`. A late snapshot with "dead" posterior to a RESPAWN does not
  reopen the death screen. The countdown uses an estimated server tick (conservative). The
  "no stamina" bit is read in `_physics_process` and blinks for 0.6 s. The animation is a
  pure function of `(action, action_id, action_tick, tick)`; remotes count the time of each
  phase from when they see it enter. Health, stamina and DPS are in the F3 panel of the HUD.
- **Measured cost** of the combat step with melees of fake players (test_world): 32 →
  combat p50 0.44 ms / p99 2.8 ms; 64 → 0.64 / 6.1; 128 → 1.3 / 4.3 (`simulate()` dominates).

Closed during K5 (integration):

- **Rewind fixed per strike and bounded lead** (phase 3 review, R1): the rewind is
  read once, on the first active tick; the lead that credits the cap is that of the strike's input,
  bounded by the client's usual one plus 3 and by 8 (with each input's own, a client that
  advanced the inputs of its strike raised the cap to 24 with LAN RTT). For an honest client nothing
  changes: its view is `rtt + lead of that input + interpolation`, so the lead of its
  input is exactly what the cap needs (with the window minimum, on the other hand, an honest client with
  jitter ended up above the cap and the hit, with no second chance on the following active ticks,
  was rejected: `test_combat_reconciliation` showed it, from 47 hits down to 0). The K5 tests
  with rtt=150 and jitter=30 (`test_combat_loopback`) still confirm all their hits without suspicion. The
  minimum for the defense and its limits are in §4.3, step 2.
- **Rewind cap with jitter**: the window's RTT minimum (networking.md 10) falls below
  the trip of any given tick, and with `rtt=150,jitter=30` the cap rejected 20% of the active
  ticks of an honest bot (and added suspicion to it). The cap uses `max(minimum, maximum)` of the window
  (`ServerPeer.rtt_peak_ticks`), with the same client-independent bound. With 150 ms of RTT and 30
  of jitter the server confirms 100% of the hits the attacker saw within the arc (20 of 20;
  8 of them would have missed without rewinding) with an average rewind of 21.7 ticks; with 200 ms the cap
  of 24 ticks no longer covers an honest player (11 of 20): pending design decision (raise
  `MAX_REWIND_TICKS` or trim the `TickSync` margin).
- **Cheating bot modes**: `rewind` (fights with the combat brain and 40 ticks of view on all its
  inputs: no damage, one suspicion per hit), `reach` (`BotCheatBrain`: attacks from 5 m with legitimate
  inputs: no impact, no suspicion) and `rate` (mashes PRIMARY one tick out of two: 14 hits
  in 600 ticks, the combo cap is 17). The phase 3 suspicion score only goes up with the
  rewind; reach and rate are resolved by the server's own simulation with nothing
  to score.
- **Client combat brain**: `--bot-brain=combat` (`ClientBotBrains`, `BotEnemySight`): the
  closest enemy that its `RemoteWorld` draws and that the server would let it damage; it does not see the
  dummies (the cheating modes do) nor know the safe zones. The light bots of `--bots=N`
  ([SwarmBot]) fight the same without simulating: enemies from the ENTITY_SPAWNs, positions from a rotating
  fraction of each snapshot's records (1 in 6), real `view_offset_q` (their tick minus the
  drawn one) and RESPAWN_REQUEST on dying. With `--fake-brain=combat` the server's fake players
  fight (K3).
- **Corrections explained by combat** (closes a gap in §3.4 for the tests): what the
  server imposes (stagger, stun, knockback, stamina spent by a block, death,
  respawn) forces the client that suffers it to correct its prediction, and that is not a failure.
  `NetClient` notes the own events that impose state (HIT with it as victim or with its hit
  parried, DEATH, RESPAWN) and treats the correction whose snapshot falls on the event's tick or
  within the following 12 as explained (`COMBAT_EXPLAIN_TICKS`); the event goes over the reliable channel and may arrive
  after the snapshot, so a difference waits 90 ticks (`DIFF_SETTLE_TICKS`) for its event
  before counting as a failure (meanwhile `get_stats()` counts it according to what it knows). New
  statistic: `combat_diffs`. Phase 4 (H4, [abilities.md 5.4](abilities.md#54-entity_event-y-fuentes)): also
  a movement STATUS on oneself, its DOWNED, an INTERACT where it is the downed one or the one acting, and its
  LOADOUT. Phase 4 review (client): also a change of the fort gate for the own realm
  that arrives with the prediction already ahead (`gate_diffs`, [fortress.md 3.2](fortress.md#32-predicción-exacta)).
  Measured in a melee of 6 combat bots with rtt=120, jitter=20 and 5% loss
  (`test_combat_reconciliation`): 40 hits, 4 deaths, 2-4 corrections per bot, all explained
  (substitution or combat), no hard reset or resync and exact convergence once they stop
  moving.
- **Combat load** (TEC-15; figures and limit in networking.md 14): `load_test.gd --brawl` measures melees of 32, 64
  and 128 combatants (fakes with `--fake-brain=combat` in a ring, `--fake-center`, and 10 real bots with
  `--bot-brain=combat`). The server counts the sections `combat_resolve` (hits with
  rewind: 76–97 µs per shape and line-of-sight check) and `combat_events` (building and sending the
  ENTITY_EVENTs: 67–97 µs per event) separately, and the report carries `hit_tests`, `resolve_us`, `resolve_busy_ticks` and
  `event_bytes_sent` (0.5–1.6 KB/s of events across the whole server). **First player limit per
  battle with combat: 64** (tick p99 15.9 ms, no substitutions or rejected rewinds); with
  128 the server can no longer sustain real time and rejects the rewind of honest players. The combat
  cost is linear (about 0.14 hits per second per combatant) and is not the bottleneck: `simulate()`
  is.
- **Sandbox demo (CMB-06)**: `--demo --quit-after-demo` on a windowless client ends by itself with
  code 0 and no errors in test_world (803 ticks) and in the Vado Gris (2049 ticks). `ClientMain` notes the
  combat actions the character enters during the demo and writes them at the end
  ("Demo, acciones de combate: LIGHT x4, CHARGE x1, HEAVY x1, BLOCK x1, DODGE x1": the three lights of the combo
  plus the press that turns into the charge), so that `test_combat_demo` checks with a real
  process that the action machine goes through what the script says, not just that the script asks for it. In the Vado Gris
  a single warning comes out, "instance_reset_physics_interpolation() is deprecated", when adding the zone to the
  tree (`client_main.gd`, `add_child`): it is thrown by native code (probably Terrain3D), no script in the
  project calls that function, and it does not affect the demo.

---

## 12. First balance pass (CMB-29)

First pass with **sword and shield**, the only kit of phase 3. It is repeated when the abilities (CMB-21)
and the bow (CMB-23) arrive —done in H5: 12.8—; the two parts that depend on content that does not exist yet, the fort
gate (GUE-10) and the captain (MUN-11), remain pending (12.7). The figures come from
`tools/combat_balance.gd`, not from a hand calculation: it sets up a `ZoneServer` without network on `test_world`
(flat, no terrain or safe zones: damage does not depend on them), advances it tick by tick without waiting
for the engine and reads the data in `data/combat/`. **It uses no clock or network, so it is deterministic:** two
runs give the same JSON byte for byte, on any machine. It is launched with

```
godot --headless --path . -s res://tools/combat_balance.gd -- --duels=60 --seconds=30 --out=build/combat_balance.json
```

(about 20 s; `tests/test_combat_balance.gd` launches it in small and checks that the measured DPS is what the
`.tres` say).

### 12.1 Action sheet (what the data says)

Health 1000 and stamina 1000 for everyone; 1 tick = 1/60 s. This data is in `data/combat/`
(`sword_light_*.tres`, `sword_heavy.tres`, `sword_dodge.tres`, `sword_shield.tres`, `combat_rules.tres`).

| Action | Duration | Damage | Stamina | DPS against the dummy (measured) |
|---|---|---|---|---|
| Light 1 | 36 ticks (0.60 s), hit at tick 12 | 90 | 0 | 150.0 if repeated without linking |
| Light 2 | 35 ticks (0.58 s), hit at tick 11 | 90 | 0 | |
| Light 3 | 48 ticks (0.80 s), hit at tick 15 | 130, stagger of 0.3 s | 0 | |
| **Combo of 3 lights** | 119 ticks (1.98 s) | 310 | 0 | **156.3** |
| Heavy, minimum charge | 85 ticks (1.42 s): 21 of charge, 24 of windup, 7 active, 33 of recovery | 180, stagger of 0.5 s, knockback of 4 m/s | 150 | 127.1 |
| Heavy, maximum charge | 136 ticks (2.27 s): 72 of charge | 306 (×1.7) | 150 | 135.0 |
| Dodge | 27 ticks (0.45 s), 4.5 m; invulnerable from 0.05 s to 0.30 s | | 300 | |
| Block | 120 degrees, 100% mitigation | | 1 per point of blocked damage | |
| Parry | 6-tick window on pressing BLOCK, cooldown of 30 ticks | | 0 | |

- **The measured DPS equals the one calculated from the data** (156.3, 150.0, 127.1 and 135.0, with 45, 50, 21 and 13
  hits in 30 s, full cycles): the action machine, the link window and the charge do
  exactly what the `.tres` say; no ticks are lost when linking. What proves it is not
  the division (damage of whole cycles divided by their seconds always gives the calculated DPS, and the
  8-tick buffer absorbs one tick of delay per link without changing the hit count) but the **tick of
  each hit**: the tool exports it (`hit_ticks` versus `expected_hit_ticks`) and
  `test_combat_server` and `test_combat_balance` require them to match, with a control that lengthens light 1 by one
  tick and checks that it is detected.
- **Calculated ideal TTK:** 1000 health over 156.3 DPS is 6.4 s of continuous combo, or 7.4 s with
  heavies charged to the maximum. Measured with a perfect attacker (chained combo, from the first hit to
  death): **5.95 s and 10 hits against someone standing still** (the first hit lands 12 ticks after starting).

### 12.2 Stamina cost per action

- **Attacking is free; defending costs.** The three lights cost 0, the heavy 150 (6 in a row from a
  full bar) and the dodge 300 (**3 in a row**, with 100 left). The block costs 1 per point of damage it
  stops: the whole bar withstands 1000 damage, that is, a bit over 3 complete combos (310 each).
- **Regeneration:** 3 per tick (180/s) starting from 0.6 s without spending; whoever reaches 0 is left exhausted and
  regenerates 1 per tick (60/s) until exceeding 300. A bar with some stamina takes at most 5.6 s to
  fill; an exhausted one, about 9.5 s (0.6 s of waiting, 5 s up to 300 and 3.9 s more).
- **Blocking without parrying is neither dominant nor useless.** A perfect attacker breaks the guard of someone blocking
  without parrying at **5.95 s** (break: stun of 1 s) and kills them at **14.47 s**, with 23 hits (13
  blocked): 2.4 times what it takes against someone standing still. Blocking buys about 8.5 s, at the cost of not attacking.
- **The repeated light almost equals the combo** (150.0 versus 156.3 DPS, 4% less): since lights do not
  cost stamina, nothing rewards linking all three except the stagger of the third and its
  advance. See proposal P1.

### 12.3 TTK between equals with bots

60 duels between two combat bots (`BotBrain` in `COMBAT` mode: attacks every 26 to 34 ticks, of which 14%
block, 10% dodge and 12% charge a heavy; **it does not react to the opponent's attack**), of enemy
realms, with the same weapons, 4 m apart, until one dies:

| | First hit to death |
|---|---|
| Minimum / p10 | 5.8 s / 7.3 s |
| **Median** / mean | **10.7 s** / 11.4 s |
| p90 / maximum | 16.4 s / 20.7 s |

- Per duel: 15.0 hits that deal damage (1717 damage between the two), 2.8 blocked, 0.1 parries, 0.0
  guard breaks and 1.4 dodged. No draw by time; the first won 27 times and the second
  33 (no side advantage). The winner makes a median of 92.6 DPS: 59% of the ideal combo, because a
  bot that attacks at random intervals does not link the combo when it is its turn.
- **Reading:** the ideal against someone standing still (5.95 s) is the floor; the bots, which do not read the opponent, die
  in the lower half of what is intended between equals (12.5). With players who block, dodge and
  parry in time the TTK goes up; with armor and stats (PRG-01, PRG-06) it does too. That is why this figure
  is a **lower bound**.

### 12.4 Teams of 2 against 2 and 5 against 5

20 fights of each size with combat bots (Vardheim against Solmarch, in a line, at 4 m), until one
side has nobody left standing, with 10 s respawns in between and a cap of 60 s:

| | First kill (median, p10 / p90) | One side with nobody standing (median, p10 / p90) | Kills per fight |
|---|---|---|---|
| 2 against 2 | 5.0 s (3.8 / 7.0) | 8.4 s (6.1 / 13.8) | 2.5 |
| 5 against 5 | 3.0 s (2.4 / 5.3) | 8.6 s (5.6 / 11.1) | 6.8 |

None of the 40 fights reached the cap. With 5 against 5 a kill happens every 3 s and the whole fight lasts as
long as a duel: with no healing, no armor and no defensive abilities, a small fight is decided
immediately. **It is not a figure for the fort** (dozens of combatants, healing and gates): it is repeated when
CMB-21 and GUE-15 arrive.

### 12.5 Decisions of this pass

| Decision | Reason |
|---|---|
| **Target TTK between equals** with sword and shield and no armor: median of 10 to 15 s per duel, p10 not below 6 s and p90 not above 25 s. | The ideal against one standing still is 6 s (floor); the bots give median 10.7 s, p10 7.3 s, p90 16.4 s: within the margin and near the floor, which is what is expected from a lower bound. |
| **No `.tres` is changed** (health 1000, damage 90/90/130/180, costs 150/300, block 1:1, regeneration 180/s, parry of 6 ticks). | All the measured DPS matches the calculated one, the TTK falls within the margin and the figures that weigh most (armor, abilities, players who react) do not exist yet. Tweaking blindly against bots that do not react would be fitting to noise. |
| **The TTK is defended with health and base damage, not with stamina cost.** When armor arrives (PRG-06) the target TTK is kept by scaling the mitigation, not the damage or the health. | Lights cost no stamina: there is no stamina lever on the attack. |
| **The 6-tick parry stays in the kit.** | It could not be measured with latency (12.7). |

### 12.6 Unapplied proposals

- **P1. Reward the combo: `sword_light_3.base_damage` from 130 to 150.** Measured by changing the value only in one
  run of the tool (and reverting it): the combo goes from 310 to 330 damage (**166.4 DPS, 11%
  more than the repeated light** instead of 4%), the ideal TTK against one standing still does not change (5.95 s and
  10 hits), against one who blocks it drops from 14.5 s to 13.1 s (21 hits) and the median of the bot
  duels from 10.7 s to 10.5 s (p10 7.0, p90 16.4). It is a cheap improvement to the value of linking and does not touch the target
  TTK, but it is left until it is seen whether players link by choice: what was measured is bots.
- **P2. Heavy.** Its DPS (127–135) is 14–19% below the combo and it costs 150 stamina and
  up to 1.2 s of visible charge. It is compensated by `hyper_armor` (it is not staggered or pushed
  while striking), the knockback of 4 m/s, the stagger of 0.5 s and the fact that a blocked heavy costs the defender
  180–306 stamina at once (3.3 maximums break the guard). No changes while there is no player data.
- **P3. Lower bound of the 5-against-5 TTK.** If with healing and armor the first kill of a 5 against 5
  stays below 5 s, raise the base health or lower the base damage before touching the durations.

### 12.7 Pending from this pass (CMB-29 remains open)

- **Gate health and fort timings:** they depend on GUE-10 (destructible gate), GUE-15 (siege
  bots) and GUE-08 (capture). Reference to size them: each sword attacker does up to 156
  DPS before the structure multiplier; gate health = simultaneous attackers × 156 ×
  seconds it must hold × (1 − fraction of the time they are not hitting).
- **Ford Captain (MUN-11)**: boss TTK against groups of 5; there is no boss yet.
- **Parry with latency** (risk in §10): the bots parry by chance (0.1 per duel), so they
  prove nothing. Calculation, not measured: with 150 ms of RTT the defender sees an attack start
  between 142 and 275 ms later (75 ms of half RTT plus 4 to 12 ticks of interpolation) and their press
  takes another 75 ms to arrive, that is, 13 to 21 ticks after the start. A light hits at 12
  ticks: it can only be parried by anticipation. A heavy hits at 45 ticks at the earliest (21 of charge and 24 of
  windup), leaving 24 to 32 ticks to react. The 6-tick (100 ms) window asks a human
  to hit the moment within about ±50 ms. It is decided with people in the closed test (if it
  does not work, the parry becomes a shield ability).
- **People:** all the figures are from bots that do not react. A session of 2 against 2 and 5 against 5
  with players in the Vado Gris is missing to fix the real TTK.

### 12.8 Phase 4 kits (H5; docs/abilities.md, section 2.4)

The calculated sheet from [abilities.md 2.4](abilities.md#24-entrada-para-la-hoja-de-equilibrio-combatemd-12),
measured. It comes from the same tool, extended in H5 (deterministic: the same JSON on every run):

```
godot --headless --path . -s res://tools/combat_balance.gd -- --duels=60 --seconds=30 --reference --out=build/combat_balance.json
```

(about 3 min; `tests/test_combat_balance.gd` launches it in small and checks the bow's DPS, the ranges and the
wall). The combat bots already use the kit (`BotBrain` with its combat state, abilities.md 11.9): shield bash up close,
rush to close in, held wall for 1 to 3.3 s, potions below half health
or 30% stamina, weapon swap, bow with lead shot, and finishing off and getting up downed players.

**Bow against the dummy at 10 m** (30 s, full cycles, aimed like a bot):

| Action | Cycle | Damage | Calculated DPS (2.4) | Measured | Arrows that hit |
|---|---|---|---|---|---|
| Repeated quick shot | 37 ticks | 60 | 97.3 | **97.3** | 48 of 48 |
| Minimum draw | 21 + 22 = 43 ticks | 90 | 125.6 | **125.6** | 41 of 41 |
| Maximum draw | 60 + 22 = 82 ticks | 180 | 131.7 | **131.7** | 21 of 21 |

**Ranges** (5 arrows per distance and type; "aim" is how far the crosshair passes above the center of the target
to compensate for the drop; the measured flight goes from commitment to the impact tick, on the face of the capsule):

| Distance | Quick (45 m/s): hits, flight, aim | Maximum draw (70 m/s): hits, flight, aim | Calculated in 2.4 |
|---|---|---|---|
| 10 m | 5 of 5, 0.20 s, 0.15 m | 5 of 5, 0.13 s, 0.06 m | draw 0.14 s |
| 30 m | 5 of 5, 0.65 s, 1.33 m | 5 of 5, 0.42 s, 0.55 m | draw 0.43 s |
| 50 m | 5 of 5, 1.10 s, 3.71 m | 5 of 5, 0.70 s, 1.53 m | draw 0.71 s (1.5 m); quick 1.11 s (3.7 m) |

**Abilities** (one use against the dummy):

| Ability | Distance | Hits | Damage (data) | Per cooldown |
|---|---|---|---|---|
| Shield bash | 1.6 m | 1 | 60 (60), stuns 48 ticks | +5.0 DPS (12 s) |
| Rush | 5 m | 1 | 50 (50) | +3.1 DPS (16 s) |
| Shield wall | 2 m | 0 | 0 | — |
| Fan shot | 2 / 3 / 10 m | 3 / 2 / 1 | 165 / 110 / 55 (165) | +16.5 / +11.0 / +5.5 DPS (10 s) |
| Weighted arrow | 10 m | 1 | 60 (60) and `slowed` | +5.0 DPS (12 s) |
| Backflip shot | 10 m | 1 | 60 (60) | +4.3 DPS (14 s) |

- Sword and shield per cooldown: **+8.1 DPS** measured (5.0 + 3.1), as calculated, and 0.8 s of stun every
  12 s. Bow: **+25.8** only with the whole fan, which against a single target only happens at 2 m (at ±7° the side
  arrows spread ±0.37 m at 3 m and ±1.2 m at 10 m): at 10 m it adds +14.8. The fan is a group weapon, not a
  duel one.

**Shield wall** against the perfect combo (156.3 DPS per attacker), its 6 s raised:

| Attackers | Stamina they take from it | Do they break it? | Calculated in 2.4 |
|---|---|---|---|
| 1 | 558 in 6 s (9 blocked hits) | no | 563, no |
| 2 | 1000 (18 blocked) | **yes, at 5.4 s** | 1000 at 5.3 s |

**Bot duels** (60 of each, of enemy realms, until one falls):

| Duel | Distance | TTK min / p10 / **median** / p90 / max | Hits per duel | Winner's median DPS |
|---|---|---|---|---|
| Shield-bearer against shield-bearer, no abilities (the phase 3 brain, reference) | 4 m | 5.8 / 7.3 / **10.7** / 16.4 / 20.7 s | 15.0 | 92.6 |
| Shield-bearer against shield-bearer, with the kit | 4 m | 8.7 / 12.8 / **18.4** / 24.8 / 29.8 s | 20.4 (3.5 blocked) | 63.6 |
| Shield-bearer against shield-bearer, with the kit and no potions | 4 m | 7.7 / 10.5 / **14.9** / 18.4 / 23.1 s | 17.6 (2.9 blocked) | 67.0 |
| Archer against archer | 20 m | 10.1 / 15.3 / **18.9** / 24.2 / 36.1 s | 26.0 | 68.5 |
| Shield-bearer against archer | 20 m | 9.1 / 11.0 / **18.9** / 24.1 / 28.7 s | 20.8 | 62.6 (the archer wins 39 of 60) |

The reference without abilities gives exactly the figures of 12.3: the phase 3 brain has not changed.

**Teams** (20 fights of each, in a line at 4 m, with the kit):

| | First kill (median, p10 / p90) | One side with nobody standing (median, p10 / p90) | Kills per fight |
|---|---|---|---|
| 2 shield-bearers against 2 | 7.3 s (5.6 / 13.6) | 15.0 s (6.3 / 20.9) | 2.4 |
| 5 shield-bearers against 5 | 4.0 s (2.4 / 6.0) | 14.8 s (6.9 / 21.9) | 6.6 |
| **2 against 2 with both loadouts** (a shield-bearer and an archer per side) | 9.5 s (5.0 / 14.9) | 16.8 s (10.6 / 18.6) | 2.2 |

**Reading.**

- **What the data says holds true**: bow DPS, ranges, damage of each ability, stun and wall
  cost, everything as in the calculated sheet.
- **The kit lengthens bot duels**: the median goes from 10.7 s to 18.4 s, above the target of 12.5 (10–15
  s), and the winner's DPS drops from 92.6 to 63.6. What lengthens it is not the damage (the abilities add +8.1 DPS) but
  the time the bot does not attack —it drinks (0.8 s per potion), holds the wall (1 to 3.3 s) or throws itself with the
  rush— and what it heals: without potions (the same brain, with the charges at 0) the median drops to 14.9 s, within the target, and the
  damage needed per duel, from 2058 to 1750: in each duel on average one potion is drunk (300 health), about 3.5 s
  of median. In the 2 against 2 with both loadouts the first kill arrives at 9.5 s
  (within the target) and the fight ends at 16.8 s.
- **The archer beats the shield-bearer at 20 m** (39 of 60): it starts dealing free damage while the shield-bearer closes in, and
  up close it draws the sword and shield. With people the shield-bearer blocks arrows head-on (the bots only
  block 14% of their decisions) and the rush closes 6 m in 0.4 s.

**Decisions of this pass.**

| Decision | Reason |
|---|---|
| **The wall's cost stays at 0.6 per point.** | Two attackers break it (at 5.4 s): the counterplay from 2.4 (numerical superiority, unblockable shield bash, flank) works; abilities.md 2.4 asked to raise it to 0.8–1.0 only if two did not break it either. |
| **No `.tres` of the kit is changed.** | Everything measured matches what was calculated; the bots' TTK goes up because of how they spend their time (drinking, wall), which changes completely with people. As in 12.5, tweaking against bots that do not react would be fitting to noise. |
| **The target TTK (12.5) is kept** and measured again with people. | First kill of the 2 against 2 with both loadouts: 9.5 s; duels with the kit: 18.4 s (14.9 s without potions). |

**Unapplied proposals.**

- **P4. Potions.** If with people the duels also go beyond a 15 s median, lower `potion_regen` from 300 to 200
  (or the shared cooldown from 20 to 30 s) before touching the damage: without potions the bot duels with the kit already drop to 14.9 s.
- **P5. Fan shot.** If the bow falls short in duels, close the fan from ±7° to ±4° (at 10 m it would hit 2 of 3 instead
  of 1, +11 DPS per cooldown); today it is a weapon against groups.
- **Pending**: the parry and arrow blocking with people; the TTK with players (2 against 2 and 5 against 5 in the
  Vado Gris, with both loadouts); the fort figures (12.7).
