# Eldmark · Phase 4: design of the capturable fort

Design of step 4 of the [roadmap](vision.md#roadmap): the first playable objective, the
fort of the Vado Gris contested between Vardheim and Solmarch ([world.md](world.md),
[zone](zones/vado_gris.md)). It builds on the networking ([networking.md](networking.md)) and the combat
([combat.md](combat.md)).

Version 2, after a skeptical review that checked the technical assumptions (navigation, collision
layers, GPU-less map) in Godot 4.7.2 and Terrain3D 1.0.2 and closed the gaps in the capture rules,
the protocol and the contracts.

Two blocks:

1. **The fort loop** (this document): state, capture, gate, AI-driven NPC defenders,
   notices, respawn at the fort, map and capture HUD, and bots that lay siege.
2. **The combat expansion** (§10): abilities, bow, weapon swap, status effects and
   knocked-down state, with its own short design (`docs/abilities.md`).

---

## 0. Decisions

Provisional, made overnight, from the recommendations in [backlog.md](backlog.md#pending-decisions):

| Question | Decision |
|---|---|
| Empty circle | After 5 s with nobody inside, progress decays at a third of the base speed. |
| Immediate recapture | No: 2 min of consolidation (circle inactive, gate damageable) until the garrison arrives. |
| AI architecture | Own hierarchical state machine, parameters in `NpcDefinition`. |
| Model of the Hollow | Plan B (base body, bone material); for now, the humanoid with a gray material. |
| Camp | Safe zone for its own realm only (combat.md §5) and two Gate Guardians. |
| Match structure | In tests, the fort returns to neutral every 30 min. |
| Minimap | Top-down image baked without a GPU; enemies only if revealed. |
| Merits and realm points | Two counters from the same event (PRG-09); in phase 4 they are only counted for the scoreboard. |
| Ability resource | Cooldown only on physical weapons. |
| Projectiles | Canonical camera ray from yaw, pitch and a shoulder bit. |
| Knocked down | In PvP; direct death in solo PvE. |
| Collision between characters | Still none; the doorway of the broken gate cannot be plugged with a body. To be reviewed with GUE-17 telemetry. |
| Respawn waves | Every 10 s (GUE-14). |

---

## 1. The fortress

### 1.1 Definition (GUE-07)

`FortressDefinition` (`scripts/shared/war/fortress_definition.gd`, `data/fortresses/vado_gris.tres`):

| Field | Vado Gris |
|---|---|
| `id` | `&"vado_gris_fort"` |
| `capture_s` | 30 (with one attacker) |
| `decay_after_empty_s` | 5 |
| `circle_height_m` | 4 |
| `gate_health` | 9000 |
| `consolidation_s` | 120 |
| `captain_respawn_s` / `guard_respawn_s` | 300 / 180 |
| `under_attack_s` | 30 |
| `gate_repair_after_s` | 300 |
| `reset_to_neutral_s` | 1800 (tests only; 0 = never) |

The circle's radius comes **only** from the `radius` metadata of the `CaptureCircle` marker (5 m).

### 1.2 Presence in the circle

A player is **present** if: alive, not knocked down, not disconnected (GUE-41), with a real input
within the last 60 s, and with their feet in the cylinder: horizontal distance to the center ≤ radius and
`feet.y ∈ [center.y − 1, center.y + 4)` (the marker is at ground level; checked in the scene).
NPCs do **not** count. `presence` is a `PackedInt32Array` of 4 positions (realms 0–3) with the
number of those present.

### 1.3 Progress in integers

Maximum progress `P = capture_ticks · 12` (30 s → 1800 ticks → 21,600). Speeds in units per
tick, all integers: 1 attacker **12**, 2 **16**, 3 **20**, 4 or more **24**; decay when
empty **−4**; decay when only non-capturers are inside **−24**. The capture travels as the formula
`progress(t) = clamp(p0 + rate · (t − t0), 0, P)`.

### 1.4 State (pure, in ticks)

`FortressState` (`scripts/shared/war/fortress_state.gd`, RefCounted, no nodes):

`owner` (0 = neutral, the Hollow), `phase` (`GARRISONED`, `VULNERABLE`, `CAPTURING`,
`CONSOLIDATING`), `phase_tick`, `captain_alive`, `captain_respawn_tick`, `guards_alive`,
`guards_respawn_tick`, `gate_health`, `gate_max`, `gate_last_damage_tick`, `capture_realm`,
`capture_start_tick`, `capture_rate`, `capture_progress_at_start`, `contested`, `empty_since_tick`,
`under_attack_until_tick`, `last_attack_notice_tick`, `last_contested_notice_tick`, `presence`
(the 4 counts, for the interface).

### 1.5 Decision table

Let `A` be the set of distinct realms present other than the owner (attackers) and `D` whether there are present players of the
owner (with a neutral fort, `D` is false).

| Phase | Situation | Result |
|---|---|---|
| `GARRISONED` | the captain dies (owner or Hollow) | `VULNERABLE` |
| `VULNERABLE` | `A` = one realm and not `D` | `CAPTURING` with `capture_realm` = that realm, `rate` according to its number |
| `VULNERABLE` | `A` ≥ 2 realms, or `A` and `D` | stays `VULNERABLE`, `contested` |
| `VULNERABLE` | `captain_respawn_s` passes without capture | the captain respawns: `GARRISONED` |
| `CAPTURING` | only the capturer | `rate` = speed for their number |
| `CAPTURING` | capturer and someone else (owner or another realm) | `contested`, `rate = 0` |
| `CAPTURING` | without the capturer, with non-capturers | `rate = −24` |
| `CAPTURING` | nobody, 5 s or more (`decay_after_empty_s`) | `rate = −4` (before, 5 s frozen) |
| `CAPTURING` | progress 0 and a single non-owner realm present | that realm becomes the capturer |
| `CAPTURING` | progress 0 and no attacker | `VULNERABLE`, `capture_realm = 0` |
| `CAPTURING` | progress `P` | `CONSOLIDATING`, `owner = capture_realm`, gate repaired, NPCs of the previous owner withdrawn |
| `CONSOLIDATING` | `consolidation_s` passes | `GARRISONED` with the garrison and captain of the new owner |
| any | `reset_to_neutral_s` or the `fort_reset` command | neutral `GARRISONED`: the Hollow and the Ford Captain, gate full, progress 0; players inside are not moved |

- Dead guards respawn after `guard_respawn_s` in `GARRISONED` and `VULNERABLE`.
- The "full respawn" of the Hollow (MUN-10) includes the Captain.
- `advance()` runs **every tick** (transitions land on exact ticks); presence is recounted
  every 6 ticks (`s % 6 == 0`) and kept between recounts.

### 1.6 Controller (GUE-08, GUE-12)

`FortressController` (`scripts/server/war/fortress_controller.gd`) creates a `STRUCTURE`
`NetEntity` with `ALWAYS_RELEVANT` for each node of the `fortresses` group with a `definition` metadata
(added by the generator, §8 F0), and in step 4b of the tick (§1.7):

- recounts presence, calls `advance()`, applies its effects (owner, gate collision,
  withdrawal and spawning of NPCs) and emits OBJECT_STATE and notices;
- the banners (`Estandarte`, `EstandartePuertaN`, `EstandartePuertaS`) are recolored **only
  on the client** (`FortressView`): the server has no meshes;
- commands with fixed ids (`--debug-commands`): 8 `fort_reset`, 9 `fort_owner <realm>`, 10
  `fort_kill_captain`, 11 `fort_capture_speed <×>`. Their data, validated by
  `DebugCommand.decode` (F2): 8 and 10, none; 9, `u8` with the realm (0 to 3); 11, `u8` with the factor
  (1 to 255).

### 1.7 Tick order (completes combat.md §4.2)

0. **NPC brains**: with the state after `s − 1`, each NPC brain (`HfsmBrain`, and the dummy's
   `NpcBrain`) pushes its input for `s` into its `InputQueue` (the `HfsmBrain` thinks every 6 ticks; in
   between it repeats its plan).
1. Simulate everyone by `net_id` (players, fakes and NPCs).
2. Freeze. 3. Resolve hits (also against the gates, §3). 4. Apply results.
4b. `FortressController.step(s)`: presence, `advance`, effects. Gate collision changes take effect
   **from `s + 1`** on the server and on the client.
5. Player and NPC additions, the social step (expired invitations and PARTY_STATUS, social.md §12),
   history, snapshots, OBJECT_STATE and events. The full, normative order is that of the
   `ZoneServer` header.

Abilities complete it ([abilities.md 4.1](abilities.md#41-tick-order-completes-fortressmd-17),
package H3a): after freezing, the shots (H3b) and the own effects of whoever is in their
commitment; resolving includes projectile flight (H3b), and applying includes ability hits and
arrow hits, effects on the target and interruptions; then, the pulses and expirations of status effects and (H3c) the knocked-down state
(bleed-out, revive and finish), before the environment, respawns with their template and the reload of consumables at
the camp. All inside `CombatDirector.process_tick`, before 4b. A knocked-down player does not count in the circle (§1.2: they are not
alive) and does prevent repairing the gate if they are in the doorway.

---

## 2. Stateful replication: OBJECT_STATE (GUE-09)

It takes the type `0x22` reserved in networking.md §5.6 and bumps **`PROTOCOL_VERSION`** (to 4: 3 was the phase 3 revision).

- **Format**: `u8 type`, `u16 net_id`, `u32 tick` (the server tick after which the
  state is valid), `u8 field_count` (1–32) and, per field, `u8 field_id`, `u8 value_type` (1 u8, 2 u16, 3 u32,
  4 s32) and the value. Reliable channel 3. 8 B header; a fortress's full state is 80 B.
- **Validation** (as networking.md §5.7): `null` if the size does not match, unknown `value_type`,
  `field_count` out of range or a repeated field. An unknown `field_id` with a valid type is
  skipped (forward compatibility).
- **Rate**: at most one OBJECT_STATE per fortress every 6 ticks, with the fields changed in
  that interval; `under_attack_until_tick` is only sent if it advances at least 60 ticks.
- **STRUCTURE ENTITY_SPAWN**: payload `u8 def_len` (1–32), the definition id (printable
  ASCII), `u8 field_count` (1–32) and the full fields (without repeating type, net_id or tick). The
  header's `realm` is 0: the `owner` field decides. With the Vado Gris id it is 98 B.
- **NPC ENTITY_SPAWN**: after the `PlayerState` and the name, `u16 npc_def_id` (`NpcCatalog`
  catalog, alphabetical ids 1..n) so the client picks model, tabard and boss bar.
- The snapshot carries **no** `STRUCTURE` records.
- **Fort fields** (`FortressFields`, shared): 1 owner, 2 phase, 3 phase_tick, 4
  captain_alive, 5 guards_alive, 6 gate_health, 7 gate_max, 8 capture_realm, 9
  capture_start_tick, 10 capture_rate, 11 capture_progress_at_start, 12 contested, 13
  under_attack_until_tick, 14–17 presence per realm (u8).
- **Client**: `FortressView` (`scripts/client/war/fortress_view.gd`) keeps the history of
  changes. The **interface** and the banners apply them when `render_tick` reaches `tick`; the gate's
  **collision** does not (§3).

---

## 3. The gate (GUE-10)

### 3.1 Two bodies

Taking the gate off layer 1 would break the line of sight for hits, the camera and the baking
(checked). That is why the gate has two bodies:

- **Movement**: `collision_layer` = the layers of the realms that are **not** the owner (layers 5, 6 and 7
  for Vardheim, Solmarch and Askarra; all three if neutral). Each `PlayerCharacter` adds to its
  mask the layer of its realm with `PlayerCharacter.set_realm_collision(code)`, called **after**
  `_ready()` (which rewrites the mask).
- **Sight**: new layer 4, "structures", which goes into `HitShapes.LINE_OF_SIGHT_MASK`, into the
  camera's `SpringArm3D` mask and into the navigation baking.

Broken (health 0): both bodies with no layers. `FortGate.layers_for(owner: int, broken: bool) -> int`
(static, shared) gives the movement layer.

### 3.2 Exact prediction

A gate change with `tick = s` takes effect from `s + 1`. On the client, `ClientPrediction` gains
a hook `before_simulate(t: int)` that `FortressView` uses to set the gate's layer according to its
change history **for the tick `t` being simulated**, also during replays. Jolt
applies a `collision_layer` change on the next `move_and_slide` of the same tick
(checked), so client and server simulate each tick with the same gate.

That holds for replays, but the OBJECT_STATE of tick `s` arrives one trip later and the
prediction is ahead: the ticks from `s + 1` to the one predicted on receipt (`P`) were already simulated with the
old gate. If the player was pushing it (or entering the doorway) in them, the snapshot does not match and there is
**one expected correction**, which the replay gets right. `NetClient` counts it as explained by the
gate (`gate_diffs`, inside `explained_diffs`) if the change touches the layer of the player's own realm: it holds for
snapshots from `s + 1` to `P + 12` (phase 4 review, client). In tests, `NetHarness.start_bot`
gives the bot's `FortressView` its own zone (`set_zone`), like `OnlineMain`; without that, with server and
client in the same process, the client's hook moved the server's gate.

### 3.3 Health and rules

- 9000 health, damageable by the owner's enemies (everyone if neutral). Multipliers against
  structures (`CombatRules`, server only): slashing ×0.35, piercing ×0.2, blunt ×1.0,
  elemental ×0.6. With the sword combo, three attackers break it in ~55 s (measured in F3: 54.8 s).
- **Target**: `HitShapes.sector_hits_box(origin, yaw, shape, box: Transform3D, half_extents:
  Vector3) -> bool`, at its current position, no rewind and no crits. The HIT carries the fortress's
  `net_id`. Line of sight does not count the gate itself. Hitting it sets "in combat" and
  updates `gate_last_damage_tick` and `under_attack_until_tick`.
- **Repair** on owner change, with `fort_reset` or after 5 min without damage, but **not while
  a character overlaps the doorway of the broken gate**: it is postponed tick by tick until it is free. The repair of
  a whole (damaged) gate does not change the collision and is done immediately (phase 4 review).
- It is **closed by default** (corrects `docs/zones/vado_gris.md`).

---

## 4. NPCs (MUN-06 … MUN-12, GUE-11)

### 4.1 Navigation (MUN-06)

`tools/bake_navmesh.gd` bakes with the gate **closed**:

- Terrain3D geometry with `generate_nav_mesh_source_geometry(aabb, false)` (with `true`, the default
  value, it returns 0 faces because there is no painted navigation; checked);
- collisions of layers 1 | 3 | 4 (3 closes off the deep riverbed: with only 1 there is a route
  along the bed; checked);
- 0.25 m cell and 0.4 radius (with a 0.5 cell the radius rounds up to 0.5 and the 2 m walkway
  leaves 1 m usable);
- result in `scenes/world/zones/vado_gris/vado_gris_navmesh.tres` (text).

Done in F0 (measured): it bakes in 2 s, the file weighs 0.3 MB (4223 vertices, 5930 polygons) with a
0.25 m cell (it was not necessary to raise it to 0.3) and comes out byte for byte identical on each run.
`tests/test_navmesh.gd` checks that from every `GuardSpawn` there is a route to the walkway (via the
ramps, without leaving), and, with a link through the gate like the one the server creates, to the ford and the
two bridges; that **without the link there is no way out of the fort**; that from the camps you can reach the
ford, the bridges and the esplanade; and that the deep riverbed cannot be reached on foot (baking without
layer 3 breaks it).

`NpcNavigation` (server, done in F4) creates its own `NavigationServer3D` map with **synchronous
iterations**, registers the region and a link through the gate by RID (not from the scene), and gives no
routes until the map is built. **Checked in F0 (corrects the above):** with
`map_set_use_async_iterations(false)` or without it, and with or without `map_force_update`, the first
iteration of the map (`map_get_iteration_id(map) == 1`) comes out **empty** (the region's orders
are applied later) and good routes arrive a few physics steps later (iteration 2); querying
the map before the first synchronization logs an engine error. That is why `NpcNavigation`
has to wait until a test query returns a point on the mesh (like
`_wait_for_map()` in `tests/test_navmesh.gd`), not just until `map_get_iteration_id(map) > 0`. The
gate link is always active, on the navigation layer
of the owner realm; each query (`NavigationPathQueryParameters3D`) filters with
`navigation_layers` of the agent's realm (immediate, without waiting for iterations). API:
`get_path(from: Vector3, to: Vector3, realm: int) -> PackedVector3Array`.

### 4.2 AI (MUN-07, MUN-08)

- `NpcDefinition` (`scripts/shared/ai/npc_definition.gd`, data in `data/npcs/*.tres`; shared
  because the zone's nodes reference it): health, `weapon_id` (NPC weapons are
  `data/combat/npc_*.tres`, in the combat catalog: the ids and the `sim_hash` change, which goes
  with version 3), speeds, perception (radius, cone), group alert radius, leash,
  immortal, `ignores_safe_area`, `is_boss`.
- `HfsmBrain` (`scripts/server/ai/hfsm_brain.gd`; `NpcBrain` remains the dummy): **IDLE →
  PATROL → ALERT → COMBAT → RETURN**; per-NPC seeded RNG; produces synthetic `PlayerInput`
  (§1.7 step 0). Two runs with the same inputs give the same sequence of states.
- Perception by radius, cone and `HitShapes.has_line_of_sight`; threat from damage and proximity;
  leash with regenerated, immune return.
- Readable attacks: NPC weapons with wind-up ≥ 0.45 s (light) and ≥ 0.70 s (heavy).
  **Tokens**: at most 2 NPCs attack the same player at once; the rest circle them at 3–4 m.
- Debugging: command 12 `npc_debug` writes the state, target and route of nearby NPCs to the
  server log every second (no network message in phase 4).
- **Knocked down** (H3c, [abilities.md 4.5](abilities.md#45-knocked-down-reviving-and-executing-downedsystem-scriptsserverdowned_systemgd)):
  NPCs do not end up knocked down (their killing blow kills), but they finish off. In `HfsmBrain`, a hostile knocked-down
  player within ≤ 6 m is the preferred target, before the closest standing one (also on noticing them in idle or
  patrol), and is attacked with the light attack, without shield or charge; it asks for its `AttackTokens` token like any
  target. `NpcWorld` does not change: a knocked-down player is already a valid target (they are not dead).

### 4.3 Spawners and defenders (MUN-09 … MUN-12, GUE-11)

- `NpcSpawner` (`scripts/world/npc_spawner.gd`, data only: marker, `NpcDefinition`, max alive,
  respawn, alert group, condition `always` / `fort_neutral` / `fort_owner`) and
  `NpcSpawnerSystem` (server), which reads the conditions from `FortressController`
  (`get_fortress_state(id) -> FortressState`) and notifies with the signal `npc_died(net_id, spawner,
  killer)`.
- **Hollow** (MUN-10): 4, at the courtyard's `GuardSpawn`s; two patrol from the courtyard to the walkway
  (new patrol markers in the generator). Group alert at 25 m, leash to the plateau,
  full respawn (with the Captain) if the fort stays neutral with no players within 40 m for
  2 min.
- **Ford Captain** (MUN-11): `CaptainSpawn` (inside the circle: it does not count, NPCs do not count).
  Wide, blockable sweep; unblockable blow (`AttackDefinition.unblockable`, server only)
  with a TELEGRAPH notice; shout that alerts the living Hollow; 2 reinforcement Hollow at 50 % if
  any Hollow remain, once per life (the full respawn withdraws them and gives the call back). On
  death: `on_captain_died`.
- **Realm garrison** (GUE-11): 4 guards and a captain of the owner at the same markers on
  switching to `GARRISONED`.
- **Gate Guardians** (MUN-12): 2 per camp, `ignores_safe_area`, high damage and long
  reach; they attack only enemies inside the safe zone (an intruder dies in under 10 s).

---

## 5. Notices, respawn, leaving and /atascado

- **ENTITY_EVENT `5 WAR`**: `net_id` = fortress, data `u8 war_event`, `u8 realm` (11 B). Fixed
  events: 1 fort attacked (realm = attacker; 1 every 60 s per fortress), 2 captain down (realm =
  whoever killed them), 3 capture started (capturer), 4 capture contested (at most 1 every 10 s), 5
  gate broken (whoever broke it), 6 fort captured (new owner), 7 fort reset (0). To the whole
  zone, applied at the render tick. Texts in Spanish in `WarEvents` (shared).
- **ENTITY_EVENT `6 TELEGRAPH`**: `net_id` = NPC, data `u16 attack_id`, `u8 shape` (0 circle, 1
  sector), `u64 position` (20 bits per axis, like the record), `u16 yaw`, `u16 radius_cm`, `u16
  impact_in_ticks`. It is applied on arrival (it is a warning, it must be seen as soon as possible). The blow lands at
  `tick + impact_in_ticks` and is dodged by the player's input for that tick, which the client generates with its
  predicted tick: the ground mark (`TelegraphMarks`) fills with that clock (on arrival an RTT and the
  TickSync margin are already ahead), is full exactly on the last tick at which leaving still avoids the blow, and
  is removed when the attack's active window ends. It is only drawn for whoever the NPC can damage (`FactionRules`,
  the bots' rule): the garrison and captain of the owner realm paint no danger for their defenders
  (phase 4 review, client).
- **Respawn** (extends combat.md §5):
  - **Static** index over all the `respawn_points` markers in the scene, in
    scene order (camps included: the generator adds those of each camp). Metadata `realm` or
    `fortress`.
  - Valid for a player: their camp, or a marker of a fortress of their realm in
    `GARRISONED` with `s ≥ under_attack_until_tick`. The client computes the same with
    `RespawnRules.points_for(realm, fortresses, tick) -> PackedInt32Array` (shared).
  - If the requested point is no longer valid, the server uses the camp, without notice.
  - Waves: `respawn_tick` = first multiple of 600 ticks ≥ death + `respawn_s`. Whoever does not request it
    respawns on their own at the first multiple of 600 ≥ death + 30 s (`auto_respawn_tick`): with waves
    nobody respawns outside one. The server's fake players request it on death and the `--bot` as soon as it
    can, like the `SwarmBot` and like someone pressing the button (phase 4 review).
  - The fort's markers, outside the circle's cylinder.
- **Leaving in combat** (GUE-41): CLIENT_LEAVE or a disconnect "in combat" leave the body for 15 s
  from the removal (CLIENT_LEAVE or ENet timeout) with **truly neutral** inputs (no buttons):
  still, not blocking, attackable, not counting in the circle. The name stays reserved those 15 s
  (REJECT NAME). The client menu shows the countdown before leaving.
- **/atascado** (stuck) (MUN-41): its own message `0x06 UNSTUCK_REQUEST` (C→S, channel 3, 1 B), valid without
  `--debug-commands`: a 10 s channeling interrupted by damage, out of combat, 5 min
  cooldown, teleport to the nearest spawn point of the realm and logging.

---

## 6. Interface (UI-18 … UI-21, UI-41, UI-42)

- **Capture HUD** (UI-18): owner (color and emblem), phase, progress bar in the
  capturer's color, "contested", those present from each side and gate health, within 80 m or when fighting
  for it; WAR banners; boss bar for NPCs with `is_boss`.
- **Compass and markers** (UI-19): fort, camps and passes.
- **Map** (UI-20, UI-21): `tools/bake_zone_map.gd` (no GPU, checked): shading from
  `Terrain3D.get_height`, water from its mesh's vertices, outlines of the collisions and of
  `BakedMultiMesh.instance_transforms` (MultiMeshes return identity in headless), saved
  as `assets/maps/vado_gris.png` with its scale in a `.tres`. Circular minimap and
  full-screen map with the respawn choice.
- **Scoreboard** (UI-41, Tab): new message `0x32 SCOREBOARD` (S→C, channel 3, every 2 s to the whole
  zone): header `u8 type, u8 page_index, u8 page_count, u8 row_count` and, per player, `u16 net_id,
  u16 kills, u16 deaths, u16 assists, u32 gate damage, u16 s in the circle, u32 merits`
  (18 B). A page carries at most 66 rows (1192 B); with more players the server splits the
  scoreboard into several messages (`NetMessages.Scoreboard.split`) and the client joins them by page. The
  kill log comes from the KILLs, which in phase 4 go to the whole zone. Tab opens and closes with
  any modifier pressed (Shift is sprint and Ctrl is dodge); if its release does not arrive, it closes
  on seeing the key up. The death screen is operated with the mouse and none of its controls takes
  focus, so Tab remains the scoreboard and Enter does not press "Reaparecer" (Respawn) (phase 4 review, client).
- **Hints** (UI-42): once per player, in `user://`, with an option to disable them. They go on top of
  the death screen without dimming (the respawn one belongs to that screen) and below the map and the
  scoreboard, which cover them: while those are open none shows and the one that was visible goes back to the queue if
  it had not been read yet. They count as seen after 4 s in view (or when their time runs out). The
  TELEGRAPH one only shows with a mark from someone who can damage you within its radius plus 20 m, and expires with
  it; the respawn one is withdrawn if the death screen closes before it is read (phase 4
  review, client).

---

## 7. Bots that lay siege (GUE-15, GUE-16, GUE-42)

- **Routes as data**: `data/routes/vado_gris.tres` (route points for the bridge and the ford
  per realm, taken from `verify_vado_gris_routes.gd`, and, since F6a, where the gate and the fort's circle are
  for bots that do not load the zone; since F6b, also the enclosure size, `enclosure_size`, and the
  walkway of GUE-45: its height, its axis and its two ramps, `walkway_*`), shared.
- **`SiegeView`** (shared, pure): owner, phase, capturer, gate health and the positions of the
  gate and the circle. It is filled by the server for `--fake-players` and by the client (`FortressView` or,
  in `SwarmBot`, decoding OBJECT_STATE) for `--bot` and `--bots`.
- `BotBrain` gains the `SIEGE` pattern: follow its realm's route to the fort, hit the gate
  if closed, enter the circle, defend the circle if it is the owner and attack the nearest enemy. The
  walkway (GUE-45, F6b, package D): a quarter of the bots, by their seed, have their role; the owner's go up
  by a ramp (a precomputed route in `data/routes/vado_gris.tres`, checked against the NPC navigation mesh) and
  hold their post above the gate, and the attackers walk it once on entering. From there nobody on the ground
  can be reached with the weapon, so there they fight whoever climbs up (detail in 8.3, F6b, package D). The `SwarmBot`s, which do not simulate,
  follow the routes in a straight line between points. Done in F6a (detail in 8.3). In F6b it fights the real NPCs:
  it first looks for the NPCs guarding the fort while the captain lives, leaves the zone of telegraphed blows
  (TELEGRAPH) with a dodge, drops chases that do not get it closer and goes around the palisade if it ends up outside on
  one side (detail in 8.3, F6b). Since GUE-44 (F6b, package C) the attacker does not leave its camp alone: it waits for its
  own at the exit (8 of its realm, or 3 already fighting at the fort, or at most the next exit of a shared
  30 s clock) and the group goes by the same route; and in a group each bot takes its own slot (formation), because characters
  do not collide with each other and the bots piled up on the same point (detail in 8.3, F6b, package C).
- Criterion: `--bots=20` per side capture and recapture without intervention. F6a meets it with fake players
  and the `fort_kill_captain` command in place of the captain. In F6b, with the real NPCs and no command: they always capture
  the neutral (86–88 s) and recapture within the 30 min cycle with the realm captain at 7500 (from 6.7 to 27.6 min depending on the seed);
  what lengthens the recapture is the circle against the defenders (GUE-44), not the NPCs (8.3, F6b). With the gathering and formation
  of GUE-44, and five seeds: neutral capture at 80–89 s and **recapture in 2.4 / 2.4 / 4.8 / 2.6 / 12.8 min** (median
  2.6 min; before, with the same seeds, 6.7 / 27.6 / 24.5 / 4.4 / 5.6); with the realm captain at 15,000, all five also
  within the cycle (from 2.6 to 17.4 min). It still depends on the seed (8.3, F6b, package C). With F6b's final code (after its
  review: 8.3, "F6b review"), neutral capture at 75–83 s and recapture in 3.4 / 6.7 / 2.5 / 2.5 / 2.4 min (median 2.5).
  With the phase 4 kit in the bots (the abilities integration and its review; with the default template, the squire) and
  three seeds: neutral capture at 80.0–82.4 s and recapture in 156.1 / 146.9 / 295.6 s (8.3, "Abilities integration review").
  **The "20 per side" of all these measurements are server fake players** (`siege_battle.gd` with `SiegeRunner`: the same
  `BotBrain` as `--bots` and `--bot`, with the server's finders), and that is how the criterion has been read since F6a. With `SwarmBot` over ENet there are
  short tests and the load, but not a whole battle (8.3, "What remains after F6b"; backlog GUE-46).
- **Load** (GUE-16): `load_test` scenario with 32 against 32 and 64 against 64 at the gate and the
  circle for 120 s (`--siege`; results in 8.3). Since F6b, `--npcs` repeats it with the zone's NPCs and the fort without
  aids: the 9 war NPCs (the 5 of the fort and the 4 camp Guardians) cost about 1 ms of the tick, of the order of
  the difference between two identical runs, and the limit stays at 32 against 32 (8.3, F6b, package E and its review). Measured without the kit of
  phase 4. With it, the Vado Gris capacity is 40 (the limit of the melee with half the shooters, networking.md 14); at the fort it was an
  estimate until the integration review, which measures it (8.3): 20 against 20 with the NPCs gives 16.2 ms of p99 with the default
  template and 16.9 ms (and 1.01 ms of projectiles) with half the shooters, on the edge of the phase 4 criterion. The limit at the fort
  with the kit stays at 40, with no margin.
- **Balance** (GUE-42, done in F6a): `--max-realm-diff=N` (default 0 = no limit); a new REJECT,
  **9 IMBALANCE**, with its own text. The per-realm count for RealmSelect arrives in the WELCOME (`u8 × 3` at the
  end; filled by the server since F6a). Exact rule (`RealmBalance`, `FillerKeeper`, `ServerAuth`,
  `ServerMain`):
  - *What counts.* Only **people**: accepted clients (loading the zone or already inside). Fake players
    and the bodies left after a removal in combat (GUE-41) do not count. It is compared against the realms
    the zone admits (`NetZones.allowed_realms`; for the Vado Gris, Vardheim and Solmarch; a zone with no
    restriction, all three).
  - *Rejection.* Entering realm *r* is rejected if `people[r] + 1 − min(people[s])` is greater than N, with
    *s* each of the other admitted realms. It is checked after the other validations and the
    identity provider, so the order is VERSION, SIM_HASH, REALM, NAME, FULL, TOO_MANY_CONNECTIONS,
    TICKET, IMBALANCE. With N = 1 in the Vado Gris the first person of a realm enters (1 against 0) and the second is
    rejected until someone is on the other side.
  - *WELCOME.* `realm_counts` are the people of each realm at that moment, **not counting whoever is entering**.
  - *Filler.* With N > 0, the `--fake-players` fakes with automatic realm (all except those of
    `--fake-layout=cluster` with the walking brain, which go to the first realm) are filler. The server
    distributes them at startup into the realm with the lowest total (people plus filler; on a tie, the lowest code:
    the usual round-robin distribution). Afterwards: **a person enters** realm *r* and *r*'s total becomes
    greater than the lowest of the others → the oldest filler fake of *r* is withdrawn (one per person; if
    *r* was the short side, the person takes a slot and nobody is withdrawn); **a person leaves** *r* and
    *r*'s total falls below the highest of the others, without exceeding the `--fake-players` quota → a new
    fake enters *r*. Nothing else withdraws or adds fakes, and filler does not count for rejecting anyone.
    Without `--max-realm-diff` the fakes are not touched (load tests measure what they always did). *Who is withdrawn*
    (since the abilities integration review, also the one who gives up a reserved slot, below): of those of the
    realm concerned, the oldest **calm** one, neither knocked down nor reviving or finishing anyone (`FillerKeeper.calm_check`,
    `ZoneServer.is_fake_calm`); if none is, the oldest. And its removal **is never a death**, even if it is
    knocked down: only the DESPAWN, with no DEATH or KILL (`ZoneServer.retire_filler`). Before, withdrawing a knocked-down one killed it by
    bleed-out with a KILL for whoever knocked it down: a person's entry added a death to a side.
  - *Slots* (GUE-43, since F6b). Filler **does not take up people's slots**: FULL (and `--max-players`) only counts
    people and fakes that are not filler. If the HELLO of a person of *r* arrives with the server full
    only because of filler, it is accepted (after the other checks, IMBALANCE included) and **a filler fake sets
    aside its slot for them**, but does not leave yet: **it leaves when they enter the world** (since the F6b review; before it
    left when the HELLO arrived). It is the oldest of the realm with the highest total (people in the world plus filler) **counting
    whoever is entering**, with what there is at that moment; on a tie, *r*'s, and otherwise, the one with the highest code. With the sides
    balanced it is always one of *r*'s (the person replaces a fake of their side, as on the long side); if *r* no
    longer has filler, it yields the side with the highest total, which is the one that leaves the battle most balanced (the alternative, "full",
    is exactly what GUE-43 removes). That fake counts as the one their entry withdraws (still one per person). If they
    leave without managing to enter (they cut off or never finish loading), the reserved slot is released and **no fake has moved**:
    no additions or removals for anyone. While someone loads into a reserved slot the server has one player too many (them and
    the fake yielding the slot), and each filler fake sets aside at most one slot: FULL counts the reserved ones as
    occupied. People never exceed `--max-players`: with no filler to yield, "full" as always.
- **Telemetry** (GUE-17): war events and deaths in JSON Lines (`--battle-log`) and
  `tools/war/summarize_battle.gd` with the time to capture, deaths per route and the time
  to break the gate. Since GUE-45 NPC deaths are also broken down by place, and the walkway counts its whole axis
  if the routes know it. The session with the NPCs (F6b, package E): five 20 against 20 battles with their log and summary;
  with those numbers the data in `vado_gris.tres` does not change (8.3, F6b, package E).

---

## 8. Packages and contracts

### 8.1 Packages

| Package | Content | Depends on |
|---|---|---|
| **F0 · scene and generator** | In the Vado Gris generator (and in the `.tscn`): fortress node (group `fortresses`, metadata `definition`), closed gate with the two bodies, `respawn_points` for camps and fort, patrol markers, `NpcSpawner` for Hollow, Captain and Guardians, `dummy_points`; navmesh baking; routes in `data/routes/` | phase 3 |
| **F1 · pure fortress** | `FortressDefinition`, `FortressState`, `FortressFields`, `WarEvents`, `RespawnRules`, `SiegeView`, `FortGate.layers_for`, `PlayerCharacter.set_realm_collision`; tests of the whole §1.5 table and of the formula | phase 3 |
| **F2 · protocol v3** | OBJECT_STATE, SPAWN for STRUCTURE and NPC, WAR, TELEGRAPH, UNSTUCK_REQUEST, SCOREBOARD, REJECT 9, count in the WELCOME, command ids 7–12 | F1 |
| **F3 · fort server** | `FortressController`, presence, gate (target, multipliers, layers, repair), tick order, commands, respawn at the fort, GUE-41, /atascado, SCOREBOARD, `--battle-log` | F0, F1, F2, K3 |
| **F4 · NPCs** | `NpcNavigation`, `NpcDefinition`, `NpcCatalog`, `HfsmBrain`, tokens, `NpcSpawnerSystem`, NPC weapons, Hollow, Captain, garrison, Guardians | F0, F1 (`FortressState`, signals), K3 |
| **F5 · client** | `FortressView` and its hook in `ClientPrediction`, capture HUD, banners, boss bar, compass, baked map and minimap, map with respawn, scoreboard, hints | F1, F2 |
| **F6 · bots, load and end to end** | `SIEGE`, `SwarmBot` with routes, `--max-realm-diff`, load, neutral → Vardheim → Solmarch test with fake players | F3, F4, F5 |

F0 and F1 in parallel; then F2; then F3, F4 and F5 (with care in `zone_server.gd`, which F3 and
F4 touch); F6 last.

### 8.2 Contracts

```gdscript
# scripts/shared/war/fortress_state.gd
class_name FortressState extends RefCounted
enum Phase { GARRISONED, VULNERABLE, CAPTURING, CONSOLIDATING }
static func initial(def: FortressDefinition, tick: int) -> FortressState
## Advances to the given tick with the current presence; returns the WarEvents (ids) emitted.
func advance(def: FortressDefinition, tick: int, presence: PackedInt32Array) -> PackedInt32Array
func on_captain_died(tick: int, killer_realm: int) -> PackedInt32Array
func on_gate_damaged(tick: int, amount: int, attacker_realm: int) -> PackedInt32Array
func on_defender_damaged(tick: int, attacker_realm: int) -> void
func set_guards_alive(count: int) -> void
func reset_to_neutral(def: FortressDefinition, tick: int) -> PackedInt32Array
func progress_at(tick: float) -> int
func changed_fields_since(other: FortressState) -> PackedInt32Array   # for OBJECT_STATE

# scripts/shared/war/respawn_rules.gd
class_name RespawnRules extends RefCounted
static func points_for(realm: int, points: Array[Node3D], fortresses: Dictionary, tick: int) -> PackedInt32Array

# scripts/world/fort_gate.gd (extends)
static func layers_for(owner_realm: int, broken: bool) -> int
func set_state(owner_realm: int, broken: bool) -> void       # layers of both bodies and visual

# scripts/shared/player_character.gd (extends)
const STRUCTURE_LAYER: int = 1 << 3
const REALM_LAYER_BASE: int = 4                                # layer 5 = Vardheim
func set_realm_collision(realm_code: int) -> void

# scripts/client/client_prediction.gd (extends)
var before_simulate: Callable                                  # (tick: int) -> void
```

### 8.3 What F0, F1 and F2 left behind (additions to the contract and decisions)

F0 (scene, layers, mesh and routes), F1 (pure fortress), F2 (protocol 3), F3 (fort server), F4 (NPCs), F5 (client) and F6
(F6a: bots that lay siege, realm balance and load; F6b, by packages: GUE-43, the bots against the NPCs, GUE-44, GUE-45 and load
and telemetry with NPCs) are done; what remains is at the end of F6b. Besides what is in 8.2, whoever touches the fort (and whatever
touches the NPCs) will find this:

**F0**

- The Vado Gris generator **can be run here** (the assets are in the repo): the scene
  comes out the same as the saved one except for the `unique_id`s, the resource identifiers and the noise in the
  last decimal digit of some transforms (Linux versus Windows); the region `.res` files and
  the water mesh do come out with other bytes, so they are not touched (docs/zones/vado_gris.md,
  "Cómo regenerar", how to regenerate). `vado_gris.tscn` has been regenerated, not hand-edited.
- The fortress node is the `Fuerte` itself (group `fortresses`, metadata `definition`), and its
  children carry the fixed names `CaptureCircle`, `CaptainSpawn`, `GuardSpawn1..4`, `FortGate`,
  `Estandarte`, `EstandartePuertaN` and `EstandartePuertaS`. `Zones` gained the constants for the new groups
  and metadata (`FORTRESS_GROUP`, `FORTRESS_DEFINITION_META`, `FORTRESS_META`,
  `NPC_SPAWNER_GROUP`, `PATROL_GROUP`, `PATROL_ROUTE_META`).
- `NpcSpawner` (`scripts/world/npc_spawner.gd`) stores the **id** of the NPC definition (`npc_id`,
  the `data/npcs/` file without extension) instead of a reference to `NpcDefinition`, because that
  class arrived with package F4. Ids in use: `hollow`, `ford_captain` and `gate_guardian` (plus
  `realm_guard` and `realm_captain`, for the garrison; all five are in `data/npcs/`). The Hollow and the Captain
  carry `respawn_s = 0` (the fortress replenishes them); the Guardians, 30 s. The owner's garrison
  (`FORT_OWNER`) has no spawners yet.
- The Vado Gris `respawn_points` are 12: the 8 of the camps (with `realm`) and then the 4
  of the fort courtyard (with `fortress` and no `realm`). While `NetZones` does not use `RespawnRules`, a
  realm's list is only its camps (the fort ones have no `realm`), as before.
- `FortGate`: the state is set with `set_state(owner, broken)` (`get_owner_realm()`, `is_broken()`);
  besides `layers_for` there is `view_layer_for(broken)` (the sight body's layer, 4 or 0) and
  `get_view_body()`. The `open` property and the collisions of the open leaves no longer exist: broken,
  both bodies are left without layers and the leaves hang open. `PlayerCharacter` also gained
  `realm_layer(code)` (a realm's mask) and `set_realm_collision` replaces the previous one
  on each call. The offline mode does not call it: the character walks through the closed gate.
- The navmesh comes out of `tools/bake_navmesh.gd` in 2 s and weighs 0.3 MB with a 0.25 m cell. Watch out for the
  navigation map: the first iteration comes out empty (4.1).
- The routes are `ApproachRoutes` (`scripts/shared/war/approach_routes.gd`), with (x, z) points per
  route (`bridge`, `ford`) and realm; `data/routes/vado_gris.tres` is written by
  `tools/terrain/export_vado_gris_routes.gd` and read by `verify_vado_gris_routes.gd`.

**F1**

- `FortressDefinition` gained `display_name` (for the `WarEvents` texts) and the
  `*_ticks()` methods. The circle's radius still comes only from the marker.
- `FortressState` stores, besides the fields in 1.4, `progress_max`, `last_reset_tick` (the periodic reset
  counts from there) and copies from the definition the ticks that the methods which do not receive it
  need. Only the `FortressFields` fields travel; the client rebuilds the rest with
  `FortressState.initial(def, tick)`.
- The speed decided at tick `s` applies from `s` (the progress of `s + 1` adds that speed).
  With the circle empty, the decay to −4 starts at exactly `decay_after_empty_s` (≥, not >).
  When going back to VULNERABLE from CAPTURING the captain gets a new `captain_respawn_s` deadline.
- Rules the table does not cover and which were resolved this way: with progress at zero and several realms (or
  a realm and the owner) inside, the capture goes back to VULNERABLE, contested; the dispute notifies on entry,
  not while it continues, and at most every 10 s; "attacked" notices go out at most every 60 s per
  fortress (`claim_attack_notice`, which the controller also uses for hits on defenders).
- Methods added to 8.2: `copy_from`/`duplicate_state`, `respawn_captain(tick)` (the full respawn
  of the Hollow brings back the captain), `guards_respawn_due(tick)` (the state says when it is time to
  replenish the guards; whoever creates them then calls `set_guards_alive`), `gate_repair_due(tick)`
  and `repair_gate()` (repair with the doorway occupied is postponed in the controller),
  `claim_attack_notice(tick)`, `event_realm(event, caller_realm)` (the realm that accompanies
  each notice), `is_circle_active()` and `is_gate_broken()`. `advance` and the `on_*` return only the
  ids of the notices.
- `FortressPresence.count(def, center, radius, candidates, tick)` is the presence of 1.2 (with the
  inner class `Candidate`); `FortressFields` gives, besides the ids, each field's value type
  (`value_type`), `get_value`/`set_value` on a `FortressState` and `fits`; `WarEvents.text(id,
  realm, fort_name)` gives the text in Spanish.
- `RespawnRules.points_for` accepts the keys of `fortresses` as `StringName` or `String`.
  `SiegeView` is filled with `update_from_state` (server) or `update_from_fields` (OBJECT_STATE
  fields) and answers `is_gate_closed_for`, `can_damage_gate`, `should_defend`,
  `should_attack`, `is_circle_active`, `is_capturing` and `is_in_circle`.

**F2** (protocol 4 after merging the phase 3 review, which took 3: `PROTOCOL_VERSION = 4`; formats in [networking.md 5](networking.md#5-message-formats))

- Everything is in `scripts/shared/net/`. `NetMessages` gains `ObjectField` (single field: `field_id`,
  `value_type`, `value`; saturates when encoding), `ObjectState` (OBJECT_STATE), `UnstuckRequest`,
  `ScoreRow` and `Scoreboard`; `EntitySpawn` gains `npc_def_id`, `definition_id` and `fields`;
  `EntityEvent` gains the `WAR` and `TELEGRAPH` types; `Welcome` gains `realm_counts`; `NetProtocol`
  gains `MSG_UNSTUCK_REQUEST` (0x06), `MSG_SCOREBOARD` (0x32), `Result.IMBALANCE` (9, with its text),
  `MAX_DEFINITION_ID_BYTES` and the debug ids 7 to 12 (`DEBUG_UNSTUCK`, `DEBUG_FORT_RESET`,
  `DEBUG_FORT_OWNER`, `DEBUG_FORT_KILL_CAPTAIN`, `DEBUG_FORT_CAPTURE_SPEED`, `DEBUG_NPC_DEBUG`, also
  in `DEBUG_COMMAND_IDS`). The three new message types go over reliable channel 3.
- Utilities for F3 and F5: `ObjectState.from_fortress(id, tick, state)` (full state, 17 fields),
  `from_fortress_changes(id, tick, state, previous)` (only those from `changed_fields_since`; if nothing
  has changed, `fields` is left empty and `encode()` returns an empty buffer: there is nothing to send),
  `from_fortress_fields` (custom list of ids), `apply_to_fortress(state)` (applies the
  known fields with their type and skips unknown ids and those of another type; returns how many it applied),
  `EntitySpawn.for_fortress(net_id, tick, definition_id, state)` and `EntitySpawn.to_object_state()`
  (the client applies the spawn's fields the same as an OBJECT_STATE), `EntityEvent.war(...)` and
  `EntityEvent.telegraph(...)`, `Scoreboard.split(rows)`, `DebugCommand.simple/fort_owner/
  fort_capture_speed/npc_debug`. `NetEntity` gains `npc_def_id`, which its `encode_spawn` puts in the
  SPAWN of an NPC.
- Validation rules that the document did not fix: a WAR requires a `WarEvents` notice (1–7) and a
  realm from 0 to 3; a TELEGRAPH, a shape of 0 or 1; an unknown `value_type`, a repeated `field_id`
  or a counter outside 1–32 invalidate an OBJECT_STATE and the SPAWN of a structure (an unknown
  `field_id` with a valid type does not); the SCOREBOARD adds a `row_count` to the page index and
  total so that the exact size can be required, with 66 rows at most.
- `ZoneServer` accepts `UNSTUCK_REQUEST` (a warning if it arrives before entering the world or malformed)
  and adds no warnings for a debug command with a fixed id (7 to 12) and valid data even if it does not
  have a handler yet (F3 registered 7 to 11 and F4 registered `npc_debug`). `NetClient`
  accepts `OBJECT_STATE`, `SCOREBOARD`, the structure SPAWN and the `WAR` and `TELEGRAPH` events without
  counting them as malformed or as combat events, and counts them in `get_stats()`
  (`object_states`, `scoreboards`, `structure_spawns`, `war_events`, `telegraphs`); `SwarmBot`
  also accepts the two standalone messages. They are marked `TODO(F3)`, `TODO(F5)` and `TODO(F6)` in the
  code.
- The WELCOME already carries `realm_counts`; `ZoneServer` sends it as 0 until F6a fills it in (GUE-42).
- Careful with `String.to_ascii_buffer()`: with non-ASCII characters it logs an engine
  error and replaces them with spaces. Definition ids are checked beforehand
  (`NetMessages.is_printable_ascii_text`).

**F3** (the fort server; tests in `test_fortress_controller`, `test_gate_target`, `test_hit_shapes_box`,
`test_fortress_server`, `test_fortress_zone`, `test_fortress_net`, `test_battle_summary`, `test_score_keeper` and
`test_unstuck_tracker`)

- **Files**: `scripts/server/war/` (`FortressController`, `StructureTarget`, `ScoreKeeper`, `BattleLog`,
  `BattleSummary`), `scripts/server/unstuck_tracker.gd` and `tools/war/summarize_battle.gd`. `ZoneServer` only
  wires (`_setup_fortresses`, tick step 4b and the handlers for leaving in combat, /atascado and
  scoreboard); `CombatResolver`/`CombatDirector` gain the static targets. `NetEntity` gains
  `definition_id` and `fortress_state` (its STRUCTURE SPAWN), `InputQueue.get_last_real_tick()` (the
  60 s inactivity rule), `NetZones.get_fortress_nodes`/`get_all_respawn_points` (the server does not name `Zones`),
  `FortGate.get_hit_box()`/`get_hit_half_extents()`/`get_body_rids()`, `HitShapes.sector_hits_box` and
  `capsule_overlaps_box`, `CombatRules.structure_*_multiplier` and `FortressState.capture_rate_multiplier`.
- **Interface with the NPCs (F4)**, in `FortressController` (`ZoneServer.get_fortresses()`):
  `get_fortress_state(id)` (the **live** state, not a copy), `on_captain_died(id, tick, realm)`,
  `set_guards_alive(id, n)`, `register_captain(id, net_id)` and `register_defender(id, net_id)` (the controller
  finds out on its own from combat's DEATH and HIT: the captain's death opens the circle and a hit on a
  defender marks the fort as attacked and gives the notice), and the signals `defenders_retired(id, tick)` (owner
  change or reset: withdraw the previous NPCs), `garrison_due(id, owner, tick, full)` (it is GARRISONED
  again: spawn the owner's garrison and captain, or the Hollow and the Ford Captain with
  owner 0; `full` false if only the captain respawns) and `guards_respawn_due(id, tick)` (replenish the
  missing guards and notify with `set_guards_alive`). At startup there is no signal: the fort is neutral and its
  spawner reads the state. **Test double**: `ZoneServer.spawn_captain_double(id)` creates a mortal, still NPC
  at the `CaptainSpawn`, on the owner's side, already registered as captain; it is killed by hitting it,
  with `kill` or with `fort_kill_captain`.
- **The gate as a target**: the hit uses the closed gate's box (`ColisionCerrada`), without rewind
  (it is tried before the attacker's rewind, so a rejected rewind does not spare hitting the
  gate but is noted as suspicious), without crit or defense, and the line of sight from the chest to
  the nearest point of the box excludes the gate's two bodies. Formula damage times the
  multiplier of its type, rounded, minimum 1, not exceeding the remaining health: **a light attack removes 31**
  (90 × 0.35 = 31.499… in floating point), the third of the combo 45 and a heavy charged to the maximum 107. The
  numbers in §3.3 hold: three attackers with the combo break it in **54.8 s** (`test_fortress_server`). The
  HIT carries the fortress's `net_id` and is only sent to the attacker (and to whoever has it as relevant), not to the whole
  zone. An attacker inside their realm's safe zone does not hit the gate.
- **Repair and free doorway**: when the repair done by the state (capture, `fort_reset`, `fort_owner`)
  or the 5 min deadline falls on the **broken gate** with someone overlapping the doorway, the controller **undoes the
  repair**: the gate keeps the broken health (and the open collision) in the state and in the OBJECT_STATE, and
  is repaired on the first tick with the doorway free (`is_repair_pending`). That way client and server keep simulating
  the same thing. Only living characters (players and NPCs) whose feet overlap the box count; whoever stands on the walkway
  above does not hold it back. A whole gate (damaged or not) is repaired immediately even if someone is in the doorway:
  closing it does not change its collision. An owner change with the gate whole changes the layers without waiting (nobody
  is trapped in a whole gate: it only changes who it stops). *(Phase 4 review: before, the repair of the whole gate was also
  postponed, and the postponed repair was applied when the doorway became free even if the
  gate had received hits afterwards; a defender standing still in the doorway of their own gate returned it whole
  right after an assault.)*
- **OBJECT_STATE**: at most one per fortress every 6 ticks with the changed fields; **deviation**: if what
  changes is the gate's collision (owner or breakage), it goes out on that same tick, so that the client's
  change history has the exact tick of the change (with the grouped state, the gate would have changed up to
  5 ticks earlier on the server than on the client). `under_attack_until_tick` only travels if it advances 60 ticks or
  more (or if it goes back because of a reset). All go over the reliable channel to whoever is inside the world; whoever
  enters receives the full state in the SPAWN.
- **Command dispatch**: network ones act on the fortress closest to the sender (rejected
  without notice if there is none, or if `fort_kill_captain` does not find the captain guarding the fort); console
  ones accept the fortress at the end (`fort_owner vardheim test_fort`). `fort_owner` leaves the fortress
  GARRISONED with that owner (garrison and captain, gate full, capture at zero) and sends `FORT_CAPTURED` (or
  `FORT_RESET` with 0). `fort_capture_speed` multiplies only the positive speed (`FortressState`
  `capture_rate_multiplier`, which does not travel: the client sees the already multiplied speed). `unstuck` (id 7) is also
  registered and goes through the same channeling as the dedicated message; `npc_debug` (12) is registered by F4 (`NpcSpawnerSystem`).
- **Respawn**: `RESPAWN_REQUEST.point_index` and the RESPAWN event's `point` are the index of the **static**
  list (`NetZones.get_all_respawn_points`: all the `respawn_points` markers in scene
  order, 12 in the Vado Gris; with none, the spawn points). What `RespawnRules.points_for` says with the live states
  holds (`CombatDirector.get_valid_respawn_points`). If the point is no longer valid, the server uses the first valid camp of their
  realm, without notice, and if there is none, a spawn point. **Waves**: in zones with any fortress (`CombatTiming.respawn_wave_ticks = 600`) the
  `respawn_tick` is the first multiple of 600 ≥ death + `respawn_s`; in the others it is still death +
  `respawn_s`. The client (F5) must build its list with the same function: as long as it uses the realm
  list from before, Solmarch always lands in its first camp.
- **GUE-41**: `CLIENT_LEAVE` or the disconnection of someone who is "in combat" and alive (`ZoneServer.linger_ticks`, 900
  by default; tests shorten it) leaves the body for `linger_ticks` from when the removal is processed. The
  `Combatant` stays alive and attackable, without a peer (no rewind), its inputs are `NetProtocol`'s neutral ones
  (no buttons, still), it does not count in the circle (`connected = false`) and its name stays in
  `get_connected_names()`, so a HELLO with it receives `REJECT NAME`. If it is killed, the death and the KILL are
  credited like any other and the body is withdrawn on the next tick; when the deadline expires it is withdrawn with the
  usual DESPAWN. Out of combat or dead, the removal is immediate.
- **MUN-41**: `UnstuckTracker` (key: the normalized name, so that re-entering does not skip the
  cooldown): 600 ticks of channeling (`channel_ticks`), 18,000 of cooldown (`cooldown_ticks`, only
  after completing it), rejection when in combat, dead or already channeling, and interruption if the player enters
  combat (dealing or receiving damage) or dies. Each response is an informational NOTICE. The destination is the nearest
  **valid** respawn point of their realm (camp or own fort not under attack); with none, a spawn
  point. Each use is recorded in the server log and in the report's `war.unstuck.log` (zone, origin,
  destination).
- **Scoreboard**: `ScoreKeeper` (kills, deaths, assists, gate damage and seconds with the circle
  **active**) and SCOREBOARD every 120 ticks to everyone, in pages of 66 rows. **Provisional merits**
  (PRG-09 will replace them with anti-farming and damage-based sharing): `kills × 10 + assists × 5 + seconds in the
  circle`. NPCs have no row. The KILL goes to the whole zone (the DEATH still goes to those involved). A
  kill or an assist is that of any KILL whose killer (or assistant) is a player, also if the victim
  is an NPC, so that the scoreboard matches the client's kill log (each KILL, once); deaths
  are only those of players.
- **`--battle-log=<path>`** (JSON Lines, `BattleLog`): `battle_start` (zone and, per fortress, positions of the
  fort, the gate and the circle), `war` (the notice with its `WarEvents` key, the realm and the place),
  `gate_damage_started` (the first hit on the gate since its last repair) and `death` (victim, killer,
  attack and position; `victim_kind` distinguishes players from NPCs). `tools/war/summarize_battle.gd` (`godot
  --headless --path . -s res://tools/war/summarize_battle.gd -- batalla.jsonl [--json] [--out=resumen.json]`)
  extracts the time to capture, the capture itself, player deaths per route (bridge,
  ford, fort walkway or others, from `data/routes/<zone>.tres` and the height above the circle) and the
  time from the first hit on the gate until it breaks. The server report gains the `war` section
  (fortresses, OBJECT_STATE and scoreboards sent, exits in combat and /atascado) and the metrics, the tick's
  `war` section.
- **Reset to neutral**: done by `FortressState.advance` itself every `reset_to_neutral_s` since the last
  reset (`last_reset_tick`: the fortress's creation, a `fort_reset` or a `fort_owner` re-arm the clock);
  the controller turns it into `FORT_RESET` (notice to the whole zone with realm 0), `defenders_retired` and
  `garrison_due` (with owner 0 and `full`: the Hollow and the Ford Captain return whole). It happens in
  any phase, also with a half-finished capture, and **moves nobody**: whoever is in the circle stays where
  they were. The gate is repaired and the layers return to the neutral ones on that same tick (valid from `s + 1`), but if
  the gate is broken and someone overlaps the doorway the repair is postponed as in any other owner change. `reset_to_neutral_s = 0`
  disables it. The Vado Gris (1800 s = 108,000 ticks) has it active
  while it is a test map; `tools/war/summarize_battle.gd` starts a new cycle at each `fort_reset` in the
  log, so its summary is that of each 30 min match.
- **Measured (F3)**: step 4b (`FortressController.step`) costs on average 522 µs on the recount ticks (every 6)
  and 50 µs on the others with 64 fake players in the circle, about 130 µs per tick; in a real process on the Vado
  Gris with 16 combat fakes in the circle, the tick p99 was 4.7 to 6 ms and the `war` section 0.5 to 0.6 ms.
  A smoke session with the console (`fort_kill_captain` with both sides inside) left in the battle log
  "captain down", "capture contested" and, when Vardheim's died, Solmarch's "capture started", and
  `summarize_battle.gd` counted the 11 deaths per route. The session with bots laying siege, which gives the numbers to
  tune `vado_gris.tres` (GUE-17), arrived with F6a (below).
- What F3 does **not** do: nothing on the client (`FortressView`, HUD, map, `RespawnPointList`), no real NPCs (F4),
  no bots laying siege and no `--max-realm-diff` (F6a brings them).

**F4** (the NPCs; tests in `test_npc_navigation`, `test_npc_catalog`, `test_hfsm_brain` and `test_npc_system`, and extensions of
`test_combat_catalog`, `test_combat_resolver`, `test_combat_server`, `test_server_config` and `test_fortress_zone`)

- **Files**: `scripts/server/ai/` (`NpcNavigation`, `HfsmBrain`, `NpcWorld`, `AttackTokens`, `NpcSpawnerSystem`),
  `scripts/shared/ai/` (`NpcDefinition`, `NpcCatalog`), `data/npcs/` (`hollow`, `ford_captain`, `gate_guardian`, `realm_guard` and
  `realm_captain`) and `data/combat/npc_*.tres` (4 weapons, 8 attacks and 5 shapes). Changes to what already existed: `AttackDefinition.unblockable`
  (and `AttackTicks.unblockable`, server only, outside the fingerprint), `Combatant.ignores_safe_area`, `ServerConfig.no_npcs`
  (`--no-npcs`), `NetZones.navmesh_path` / `get_npc_spawners` / `get_patrol_route`, `CombatDirector.emit_event` and, in `ZoneServer`,
  `add_npc(..., definition)`, `get_npc_system`, `get_npc_ids`, `get_npc_brain`, `get_physics_space`, tick step 0
  (`_run_npc_brains`) and the TELEGRAPH notice.
- **Navigation**: `NpcNavigation` mounts its own map (synchronous iterations), the region from `<scene>_navmesh.tres` (next to the
  zone's scene) and a link through each gate's doorway (2.5 m inside and 3 m outside the `FortGate` origin). The region is on
  navigation layer 1; the link, on the owner realm's (bit 1 the Hollow's neutral side, bits 2 to 4 realms 1 to 3) and on those of
  everyone with the gate broken; each query asks for the region's layer plus that of its realm, so whoever also
  crosses the gate for real crosses through the link. `poll()` marks the map as ready when a test query (a mesh vertex) returns a point on
  it, and until then `get_path` returns an empty route without touching the navigation server. `NpcSpawnerSystem` does not spawn NPCs until
  it is ready (at most 600 ticks; after that they go in a straight line).
- **Catalog numbers** (`npc_def_id`, in alphabetical order): `ford_captain` 1, `gate_guardian` 2, `hollow` 3, `realm_captain` 4 and
  `realm_guard` 5. `BossInfo` (client) gives the same names and `is_boss` (checked by `test_npc_catalog`). NPC weapons change
  the combat catalog ids (the `npc_*` come before the `sword_*`: `sword_shield` goes from 1 to 5, `sword_heavy` from 1 to 9...)
  and the `sim_hash`; nothing depended on a fixed number except `test_combat_catalog` and `test_action_machine`, which now look up by name.
- **Weapons** (wind-up → damage): Hollow `npc_hollow_swipe` (0.50 s → 70, reach 2.4 m) and `npc_hollow_slam` (heavy, 0.75 s → 160,
  stagger and push); realm guard `npc_guard_slash` (0.45 s → 85) and `npc_guard_bash` (0.70 s → 150); Captain `npc_captain_sweep`
  (170° sweep, 0.60 s → 110, blockable) and `npc_captain_crush` (**unblockable** heavy, 1.00 s → 300, reach 3.5 m);
  Guardian `npc_guardian_halberd` (0.50 s → 260, reach 3.6 m) and `npc_guardian_thrust` (unused). The three-light combo repeats the
  same attack (no link window: each attack is a decision of the brain). Health: Hollow, realm guard and Guardian 2500,
  Ford Captain 30,000 and realm captain 15,000 (7500 since F6b, provisional: see F6b). The `CombatResolver` skips the parry and the block with `unblockable` (the invulnerable
  dodge still holds) and does not stop an attacker with `ignores_safe_area` in the safe zone of their own realm.
- **Brain** (`HfsmBrain`): thinks every 6 ticks, staggered by `net_id` (`THINK_INTERVAL_TICKS`), and in tick step 0 (before
  simulate anyone). Perception: radius, cone and line-of-sight ray (plus the "hearing" of `awareness_radius`, which also needs
  line of sight); whoever is safe in their realm's safe zone does not count, and the Guardians (`ignores_safe_area`) only see
  enemies who are inside their own. Threat: damage received from each enemy (the `DamageLedger`) plus proximity, with a 60 point
  advantage for the current target. A hit received without seeing anyone leads straight to combat; if whoever hit it is beyond
  its loss radius (an archer), it raises the radius up to them plus 4 m and goes after them (the leash or being stuck send it to
  immune return if it does not reach them). It attacks only with a token
  (`AttackTokens`, 2 per target, expiring after 1 s without renewal); without one it circles at 3.5 m (backs off below 3.1 and closes in
  above 4.0). Before attacking it decides the next attack (the special every `special_every`, otherwise block, heavy or light according to its
  probabilities) and remembers it until it is done; the heavy is requested by holding PRIMARY during the minimum charge. The leash is the radius
  from its post: on exceeding it (or on losing the target, after 3 s) it goes to RETURN, **immune** (`protected_until`) until it arrives, and
  on arriving or on losing combat next to its post it is **regenerated**; if it does not arrive within 60 s or gets stuck three times, it teleports.
  Alerted from afar (shout) it does not lose the target until 60 m. Its state log (`get_state_log`, for determinism
  tests) stores the last 256 to 511 transitions (`STATE_LOG_MAX`).
- **Spawners** (`NpcSpawnerSystem`): one post per `NpcSpawner`; ALWAYS always, FORT_NEUTRAL with the fort neutral and FORT_OWNER with an
  owner (and outside CONSOLIDATING). If the fort has no FORT_OWNER spawners, the garrison comes from **the Hollow's posts**
  with the definition each names in `garrison_id` (`hollow` → `realm_guard`, `ford_captain` → `realm_captain`), with the same
  patrol route and alert group: the scene did not need touching. With `respawn_s > 0` they respawn on the exact tick (death +
  `respawn_s`); without it the fortress replenishes them: `garrison_due` (full or only the captain), `guards_respawn_due` (the missing
  guards) and the full respawn of the Hollow. `defenders_retired` or becoming inactive withdraw the living and the corpses.
  Corpses stay for 300 ticks (5 s) and the `CombatDirector` no longer respawns NPCs on its own. It registers the captain
  (`register_captain`) and the others (`register_defender`) and counts living guards with `set_guards_alive`. The signal
  `npc_died(net_id, spawner, killer)` reports each death (the fortress already finds out on its own from the DEATHs).
- **Captain**: the special (`special_every = 3`) is the unblockable heavy, which `ZoneServer` announces with a TELEGRAPH (sector, reach
  3.5 m, `impact_in_ticks` = 60) on the tick it launches it; it shouts on entering combat (alerts its whole group within 60 m, only if there are
  living companions) and on dropping to 50 % health it calls two Hollow next to it, once per life (returning regenerated to its post does not
  re-arm the call; the full respawn of the Hollow withdraws any remaining reinforcements and re-arms it) and also only if any
  remain; there are never more than two reinforcements alive per fortress (those of a previous Captain count). The TELEGRAPH is
  sent for **every** heavy attack of an NPC (not only the unblockable): light ones are not announced.
- **Decisions where the document was silent**: the full respawn measures distance from the circle's center and only counts with the
  fort neutral and something missing; the Guardians see 38 m (their whole safe zone from their post) and their leash is 40 m; `--no-npcs` turns off
  the system (`test_fortress_zone`, which uses the captain double, sets it) and, without it, `spawn_captain_double` keeps working and
  replaces the registered captain. `npc_debug` writes one line per combat NPC within 60 m of whoever requests it (all from the
  console) every second: state, target, distance, route point, health and whether it has a token.
- **Measured** (on a machine shared with another suite, so these are high bounds): 3 combat bots (which neither dodge nor block with
  judgment) clear the 4 Hollow of the Vado Gris in about **46 s** of play (with the Captain already down); 4 bots healed on every
  tick defeat the Ford Captain in about **78 s** (without healing them, four bots die before bringing it to half and the Captain returns
  regenerated); an intruder in the safe zone dies in **4 to 5 s** to the two Guardians; with four guards against one they never attack more than
  two at once (almost half the time two attack). A bot that blocks 550 ms after seeing a heavy attack start (RTT 200 ms, 250 ms of
  reaction) blocks all of a Hollow's and a guard's. Cost: the brain costs **15 to 30 µs per NPC per tick** (p50) and its
  `simulate()` **32 to 55 µs**, that is, about **50 to 85 µs per NPC per tick** (up to ~100 µs in the thick of combat); the spawner
  system, about 60 µs per tick with the 14 posts of the Vado Gris. With the 9 NPCs of the Vado Gris, 3 bots fighting and the rest of the
  zone, the tick takes 1.3 ms on average.
- **Pending / outside F4**: the Hollow's and the Captain's own model, tabard and animations (ART-15, ART-16: today
  they are seen with the humanoid and the sword sweep); playing it with people to set the 60-90 s of the Hollow and the 60-120 s of the
  Captain (bots are no fine measure); the MUN-08 criterion with a real `--net-sim=rtt=200` over the network (here the
  delay is emulated in the bot); AI LOD and sleeping with no players (MUN-29); `SwarmBot` and bots that lay siege will do it in F6.

**F5** (client: everything in `scripts/client/`, `tools/` and `assets/maps/`; it does not touch `scripts/server` or `scripts/shared`)

- **`FortressView`** (`scripts/client/war/fortress_view.gd`, child node of `NetClient`) and **`FortressTimeline`** (the change
  history, pure): they store the structure's SPAWN and each OBJECT_STATE with its tick and the accumulated state
  (`FortressState.initial` plus the `FortressFields` fields; what does not travel comes from the definition). `state_at(t)` gives the state
  after tick `t`; `gate_layers_for_tick(t)` looks at the state after `t − 1`, because a change with `tick = s` takes effect from `s + 1`.
  `advance(render_tick)` (called by `NetClient` every physics tick) applies banners (`faction_color` of `Estandarte`,
  `EstandartePuertaN` and `EstandartePuertaS`), the gate's pose and the `state_changed` signal; progress is the formula at the
  render instant. `ClientPrediction.before_simulate` is the hook from 8.2: it is called before **every** `simulate()` (spawn,
  step and replays). **Contract with the server:** the owner and the gate's breakage have to arrive with the tick at which they
  really changed (the F3 controller sends those the clients see). `OnlineMain` links the view to the zone (`set_zone`),
  and in tests `NetHarness.start_bot` does too. Ticks predicted before receiving the OBJECT_STATE were simulated with the old
  gate: that correction counts as explained (`gate_diffs`, section 3.2).
- **War interface** (`WarHud`, child of the `HUD` below the death screen): `CapturePanel` (within 80 m of the
  fort or fighting within 200 m), `WarBanners` (the seven WAR events), `BossBar` (bosses by `npc_def_id` of the NPC SPAWN: `BossInfo`
  reads `data/npcs/*.tres` in alphabetical order, like `NpcCatalog`, and without the folder there are no bosses), `TelegraphMarks` (provisional flat mesh
  that fills up to the impact with the predicted clock, only for whoever can damage you; section 5), `Compass` and `WorldMarkers` (`MarkerSource`
  gathers fort, gate, circle, camps and passes), `Minimap` and `KillFeed`. The `HUD` also mounts, above the death screen,
  `HintToasts` (without dimming), `WorldMap` and `ScoreboardPanel`, in that order.
- **Map** (`tools/bake_zone_map.gd` and `ZoneMapBaker`): `assets/maps/vado_gris.png` (1024 x 1024 px, 0.6 MB) and
  `vado_gris_map.tres` (`ZoneMapDefinition`: origin (−160, −160), 320 x 320 m and the fixed places); see docs/zones/vado_gris.md. The
  minimap goes bottom right (the top corner belongs to the F3 debug panel) and zooms in and out with `map_zoom_in` and
  `map_zoom_out`.
- **Respawn:** `RespawnPointList.options` groups contiguous markers of the same site (the four of a camp, those of the courtyard)
  into one option and marks as valid those given by `RespawnRules`; the death screen offers only the valid ones, updates while open
  and sends the **marker's index among all those in the zone** (spread by `net_id` among those of the same site), as section 5
  requires. "Elegir en el mapa" (Choose on the map) (or M with the screen open) opens `WorldMap` in respawn mode. Until the server adopts the
  static index (F3), this tree's interprets it over the points of its realm.
- **Scoreboard and kills:** `ScoreboardPanel` (Tab held) draws the last complete SCOREBOARD and `KillFeed` each KILL (the event reaches
  the whole zone); each id's name and realm come from `PlayerDirectory`, which remembers each SPAWN seen. **Limit:** whoever was never
  in the interest radius shows up as "Jugador N" (Player N); a message with names would be needed.
- **Hints:** `HintCatalog` (seven, with the real keys from `UIKeyGlyph`), `HintLog` (`user://hints.cfg`) and the setting "Pistas del juego" (game hints)
  (`ClientSettings.HINTS`). Without a screen (headless: tests and test processes) the `HintLog` is memory-only and does not write to `user://`.
  `HintToasts.is_covered` (the map or the scoreboard open) leaves them waiting; they are recorded after `MIN_SEEN_SECONDS` (4 s) in view or on
  removing them with `dismiss`; `withdraw` removes one without recording it; `request(id, lifetime)` expires if it does not show in time (section 6).
- **Realm selection:** `RealmSelect` shows the per-realm count from the last WELCOME (there is no other before connecting), recommends the
  shortest side and, after a REJECT 9, leaves the rejected realm unselected and marked, with the text from `NetProtocol.result_text` and the short
  realm offered. The server fills in the count in F6.
- **New keys** (`InputBindings`): `open_map` (M), `map_zoom_in` (+), `map_zoom_out` (−) and `scoreboard` (Tab).
- **Pending for the user:** everything visual in this interface is provisional constants (sizes, colors, positions, durations,
  map style, hint and banner texts, TELEGRAPH mark, marker icons); the art direction is ART-12 and ART-17.
- Tests: `test_fortress_view`, `test_fortress_prediction` (two physics worlds with the gate and the owner change midway),
  `test_capture_hud`, `test_compass_markers`, `test_zone_map`, `test_world_map`, `test_scoreboard`, `test_hints`, and extensions of
  `test_net_client`, `test_realm_select`, `test_client_settings` and `test_hud_combat`.

**F6a** (bots that lay siege, realm balance and load: GUE-15, GUE-16, GUE-42 and the part of GUE-17 that needs no NPCs;
tests in `test_realm_balance`, `test_bot_brain_siege`, `test_siege_zone`, `test_siege_clients` and extensions of `test_server_auth`,
`test_server_config`, `test_zone_server_net`, `test_server_main`, `test_siege_view`, `test_battle_summary`, `test_load_test` and
`test_server_metrics`)

- **Realm balance (GUE-42)**: the exact rule is in section 7. Files: `scripts/server/realm_balance.gd` (pure
  rules), `filler_keeper.gd` (the filler fakes), `server_auth.gd` (IMBALANCE after the identity provider),
  `ZoneServer.get_realm_counts()` (people per realm: the WELCOME and rejection count) and `ServerMain` (wires the additions and
  removals of people to the `FillerKeeper`; since F6b `ZoneServer.set_filler_keeper()` does it). `NetProtocol.Result.IMBALANCE` and
  the text already came from F2. `RealmSelect` (F5) already showed the count and the rejection. A `--max-realm-diff` without `--fake-players`
  only rejects.
- **`BotBrain.Pattern.SIEGE`** (at the end of the enum; COMBAT and the rest do not change: a test compares the 600-tick fingerprint of COMBAT and
  of WANDER with the previous code's). `set_siege(view, routes, realm)` gives it a `SiegeView` (which can be shared among bots: its
  questions carry the realm), the `ApproachRoutes` and its realm; the enemy finder is COMBAT's (`set_enemy_finder`). On each tick
  it decides in this order, and `get_siege_task()` says what it did (`FIGHT`, `MARCH`, `ASSAULT`, `HOLD`):
  1. **Fight** the enemy given by the finder if it is within 12 m and can be reached (not behind a gate that blocks the way
     to its realm: an attacker ignores those inside and an owner goes out after those outside), with the same decision machine as COMBAT.
  2. **March** along its realm's route, `bridge` or `ford`, which it chooses with its seeded RNG at the start and after each respawn (a
     position jump of more than 5 m in one tick); it sprints through stretches longer than 9 m if the last enemy seen is more than 25 m away;
     it counts a point as reached at 2.5 m. If it is inside the enclosure it does not use the route.
  3. **Assault**: with the route done and the gate closed for its realm, it approaches to 2.3 m from the center of the doorway and hits it (chained
     light attacks and an occasional charged heavy) while looking at it; still while hitting.
  4. **Circle**: with the gate broken or its own, it aligns with the gate's axis (4.5 m in front), crosses it and stays within less than
     half the radius of the circle's center looking at the gate. Attackers and owner do the same: the circle is what is captured and
     defended.
  - **Stuck**: walking and not advancing 1 m in 180 ticks (3 s), a jump (two presses in 40 ticks); if still the same for another 3 s, a
    detour of ±1.2 rad for 60 ticks, and start over. Fighting, hitting the gate or waiting in the circle is not being stuck.
  - **Deterministic**: it only uses its RNG; same seed and same worlds, same inputs (4000-tick test with an enemy that
    appears and disappears and a gate that breaks).
- **Data**: `ApproachRoutes` gains `gate_point`, `circle_point` and `circle_radius` (the exporter writes them and `test_siege_zone`
  checks they are the scene's) and `SiegeView.set_places_from_routes()`: the `SwarmBot`s, which do not load the zone, have no other
  way of knowing where the fort is. `FortressView` gives the real positions to the bot that predicts.
- **Server**: `ZoneServer.get_siege_view()` creates a view per fortress (the zone's first by default), with the positions of
  the gate and the circle, and updates it on each tick, at the start of the `sim` section (the state after the previous tick,
  like the NPC brains in 1.7); `get_approach_routes()` loads `data/routes/<zone>.tres`. `add_fake_player` equips a SIEGE brain
  without a fortress (view, routes and enemy finder). `ServerMain`: `--fake-brain=siege` (fakes leave their camp,
  distributed round-robin among the realms; `--fake-layout=cluster` does not apply) and `--run-at=<tick>:<command>` (repeatable; runs a
  console command, for example `fort_kill_captain`, at the end of that tick; it is what the load tests use, which have no
  standard input).
- **Clients**: `--bot-brain=siege` works for `--bots` and for `--bot` (`--swarm-brain` was not needed). `SwarmBot` does not simulate: it follows the
  routes in a straight line between points with the `BotBrain` inputs and the server supplies the ground; its `SiegeView` is filled by hand from the
  fields of the fortress's ENTITY_SPAWN and of each OBJECT_STATE (`update_from_fields`) and its enemies are players of another realm
  and the war NPCs (those carrying `npc_def_id`; dummies do not). `--bot` has its `SiegeView` filled from `FortressView`
  (`ClientBotBrains`) and sees the war NPCs with `BotEnemySight`.
- **Tools**: `tools/war/siege_runner.gd` (`SiegeRunner`: the real Vado Gris in one process, no network, advanced quickly; records
  arrivals at the gate, notices and deaths) and `tools/war/siege_battle.gd` (the long battle with a report and log summary).
  `tools/load_test.gd --siege` (the GUE-16 scenario) and `LoadTestSummary.parse_tick_timeline/timeline_window`. The server
  summary gains the **p95**, and `BattleSummary` a new death class, `gate` ("esplanade and courtyard", within 25 m of the circle):
  both routes end there and without it almost all assault deaths came out as "ford".
- **Experiment launch commands** (from the project root; logs and temporaries in `build/`):
  ```
  godot --headless --path . -s res://tools/war/siege_battle.gd -- --per-side=20 --minutes=15 --battle-log=build/siege20.jsonl
  godot --headless --path . -s res://tools/war/siege_battle.gd -- --scenario=war --per-side=20 --minutes=8
  godot --headless --path . -s res://tools/load_test.gd -- --siege --out=build/load_siege
  godot --headless --path . -s res://tools/war/summarize_battle.gd -- build/siege20.jsonl
  ```
  The suite's tests are short versions (few bots, capture x30 with command 11, the gate trimmed in the network ones).

**Measured in F6a** (without NPCs: the captain is taken as dead by `fort_kill_captain`, or killed by the bots if it is the test double):

- **Arrival at the gate from the camp** (with sprint, 5 and 7.5 m/s): by the **bridge 24.3–25.1 s** and by the **ford 36.5–37.5 s**
  (20 per side; six bots of the short test: 24.6 and 37.5 s). Solmarch, the exact mirror. The 20 of each side always arrive by
  both routes (with seed 1000, 11 went by the bridge and 9 by the ford).
- **Gate** (9000 health): broken **14.9 s after the first hit** with 20 attackers, 21.9 s with 10 and 36.9 s with 6 (they arrive
  staggered, and the last ones from the ford take 12 s longer than those from the bridge).
- **Capture of the neutral fort by Vardheim** (20 bots, capture at real speed): gate broken at 40 s, captain down at
  40 s, **captured at 55.9 s** from the start (15.0 s capturing with four or more in the circle: 21,600 / 24 = 900 ticks).
- **Recapture by Solmarch** (another 20 who leave when Vardheim already has the fort and its 20 defend it): **360 s (6.0 min)**, of
  which the gate costs **199.5 s** from the first hit and, with the captain down, the circle costs 135.8 s until capture
  (117.7 s of dispute inside and 18.1 s capturing). With 10 against 10, 527 s (8.8 min; the gate, 398.6 s). The **two sides are
  equal but the defenders win by a lot**: 140 player deaths in those 416 s, 108 of Solmarch and 32 of Vardheim (131 in the
  esplanade and the courtyard, 9 at the ford, none at the bridge). Cause: the attacker's reinforcements arrive in a trickle (30 s of
  respawn plus 25–37 s of marching; *phase 4 review: it said "in waves of 10 s", but the server's fakes did not
  request the respawn and left by the automatic one, exactly 30 s after dying and each on their own*) and the defender, who is in the circle 11.5 m from the gate, goes out after them
  at each batch (finding, below).
- **Short version of the suite** (`test_siege_zone`, six bots per side with capture x30 from command 11, the real Vado Gris): neutral →
  Vardheim with `fort_kill_captain` in 64.0 s and → Solmarch 121.0 s later (the consolidation, 120 s, is almost all of it); with the captain
  double, the bots kill it themselves and capture at 67.3 s.
- **Load** (`load_test.gd --siege`, 120 s of measurement with the bots already at the gate, the server on the same **4-core machine with
  another agent running its own Godot suite at the same time**: `uptime` 0.87 at the start and 1.66 at the end, with two foreign
  `run_tests.gd` processes running; the first pass, without the p95, gave the same frames with a worse p99, 31 ms, and 0.9 to 2.2 of load).
  Tick in µs of the server's last 34 s stretch; NPCs: **0** (still):

  | Siege | Players | Tick p50 / p95 / p99 / max | `sim` p50 | `snapshot` p50 | `war` p50 / p99 | Downstream per client | Substituted (window) | Rewinds rejected |
  |---|---|---|---|---|---|---|---|---|
  | **32 against 32** (54 fakes + 10 bots) | 64 | 10.6 / 15.3 / 19.1 / 27.8 ms | 6.8 ms | 1.6 ms | 0.11 / 1.4 ms | 36.1 KB/s | 0.00 % | 0 |
  | **64 against 64** (118 fakes + 10 bots) | 128 | 14.8 / 22.0 / 26.4 / 42.8 ms | 12.0 ms | 0.002 ms | 0.10 / 2.4 ms | 28.5 KB/s | **50.76 %** | **25** (6 suspicious) |

  The server's 10 s marks (each over the previous 34 s) give a median p99 in the window of 19.3 ms (the worst, 20.2 ms)
  with 32 against 32 and 32.5 ms with 64 against 64; single-tick maxima reach 72.5 ms. **The 64 against 64 row is not 128
  players** (F6b review): the swarm shut down on its own clock and the server, slower than real time, continued without the
  10 real bots for the last stretch, from which its percentiles come (betrayed by the `snapshot` of 0.002 ms: there was no client to
  send them to). With all 128 the marks' p99 holds, 32.5 ms. Criteria from networking.md (14 and 16):
  - **p99 < 8 ms with 64 players: NOT met** (19.1 ms; the p50 is already 10.6 ms). It is the same situation as in the TEC-15 melee
    (p99 15.9 ms with 64 combatants at rest): `simulate()` in GDScript dominates (77 µs per character, 6.8 ms of `sim` out of the 10.6),
    not the fort.
  - **≤ 37 KB/s per client: met with 32 against 32** (36.1 KB/s: the full snapshot of 1187 B at 30 per second); with 64 against
    64 the server does not manage to send them all (28.5).
  - **< 1 % of inputs substituted: met with 64 players (0.00 %) and not with 128 (50.76 %)**, and with 128 the rewind starts to
    fail honest players (25 rejections, 6 suspicious), as already happened with 128 in the melee. **First player limit per battle
    at the fort: 64 (32 against 32)**; 64 against 64 is beyond what the server sustains today. (Measured without the phase 4 kit;
    with archers and abilities, the H5 melee lowers the per-battle limit to 40: [networking.md 14](networking.md#14-bandwidth-and-cpu-budget).)
  - **The cost of the fortresses is negligible**: the `war` section (step 4b) costs a median of 0.10–0.11 ms and a p99 of 1.4–2.4 ms
    (presence is recounted every 6 ticks with everyone in the circle), about 300 `OBJECT_STATE`s and 90 scoreboards in the 3 minutes. Combat
    (`combat`) costs a median of 0.9 ms with 64 and 1.5 with 128; hits with rewind, 57 to 70 µs per check.
  - With 64 players the battle gives 138 deaths and 1889 hits in 175 s; with 128, 268 and 3476. Capture arrives in both at 74 s of the
    cycle (15 s from the captain's fall); the gate breaks 25.7 s (32 against 32) and 12.6 s (64 against 64) after the first hit.
- **GUE-17**: the sessions above are documented with their battle log and summary
  (`summarize_battle.gd`); the numbers serve to tune `vado_gris.tres` **when there are NPCs** (F6b): today there is no captain or
  garrison, so the gate duration (9000) and the consolidation (120 s) are not touched with this data. Done in F6b (package
  E, below): with the NPCs they do not change either.

**F6a deviations and findings**

- **Defending the walkway** (7) is reduced to **defending the circle**: the walkway is at 3.35 m, is climbed by ramps and needs navigation
  (`NpcNavigation`, F4); a bot with flat routes cannot climb. The owner bots stay in the circle, where they already count in presence and
  dispute the capture, and go out after whoever comes within 12 m. It is left for F6b with the navigation mesh. Done in F6b
  (package D, GUE-45, below), with a precomputed route that the mesh accepts.
- **Bots entering through the gate have to align with its axis**: the last point of the bridge route is off to the side
  (−25, −2) and heading straight for the circle from there slams the bot into the palisade (found by the defenders test). With the gate
  axis (`SIEGE_GATE_*`) they all get in.
- **Reinforcements in a trickle**: today each bot leaves alone when it respawns, and the defenders defeat the attackers piecemeal
  (3.4 attacker deaths for each defender one in the 20 against 20). Before tuning `vado_gris.tres` with NPCs we should decide whether the
  attacker waits for their companions on the esplanade or whether it is a desired effect (backlog GUE-44). Decided in F6b (package C, below): they
  gather at their camp and go in formation; the underlying cause was that the bots pile up.
- **Filler fakes take up slots** (`FULL` counts all players): with `--max-players` equal to `--fake-players` the server
  rejects with "full" the person who should replace a fake (backlog GUE-43). Tests leave room. Resolved in F6b (below).
- **`FortressView` failed with a `FortressDefinition` in the fortress's metadata** (`String(<resource>)` does not exist; it only happened with
  the test scenes) and `test_fortress_loopback` was already failing at `b2adb5c`; fixed (`_definition_of_node`).
- **`test_combat_cheaters_in_real_processes...`** failed at `b2adb5c` with the machine loaded: the three cheaters enter at about tick 170
  and their count of 640 exceeded the server's 760, so they left with the shutdown notice and code 1. The server lives 960
  ticks (17 s the test).
- `BattleSummary`'s death classification gained the `gate` class; the `ROUTE_MAX_DISTANCE` of 30 m still classified the whole assault
  as "ford".
- An unknown `SiegeView` (`known` false) is a whole fort; **known and with `gate_health` 0 is a broken gate**: tests that
  fill it by hand have to give the gate's health.
- In a `SceneTree` (`-s tool.gd`), nodes added to `root` in `_initialize()` are not inside the tree until the first
  frame: `siege_battle.gd` waits for `process_frame` before anything else.

**What F6a does not do (left for F6b, after F4)**: the end-to-end neutral → Vardheim → Solmarch test with the real NPCs
(Hollow, Ford Captain and garrison), the `--bots=20` per side criterion with no intervention (today: with
`fort_kill_captain`), defense of the walkway and repeating the load with the NPCs. The brain is already ready: the server's enemy
finder includes non-immortal NPCs, so bots entering the courtyard attack the owner's nearest (with the test
captain double they do: `test_bots_capture_the_neutral_fort_killing_the_captain_themselves`), and `SwarmBot`/`--bot`
count NPCs with `npc_def_id` as enemies. All done in F6b (below; the walkway, with what melee weapons allow), unless
a person plays against them.

**F6b** (the second half of phase 6: end to end with the NPCs, GUE-43, GUE-44, GUE-45 and load with NPCs; it is done in
packages, and each one is noted here)

- **GUE-43, filler does not take up people's slots** (exact rule in section 7, *Slots*). Files:
  - `RealmBalance.realm_to_yield_seat()`: which realm yields the slot (the one with the highest total counting whoever enters; on a tie, theirs and then
    the one with the highest code).
  - `FillerKeeper.yield_seat(peer_id, realm)` (withdraws the fake immediately and records the slot in that person's name),
    `on_person_joined(realm, peer_id)` (does not withdraw another for someone who already has a yielded slot) and `on_seat_abandoned(peer_id)` (restores the
    fake if they leave without entering). Since the F6b review, `reserve_seat`, `release_seat` and `reserved_count`: the slot is set aside at the
    HELLO and the fake is withdrawn in `on_person_joined` (see "F6b review", below).
  - `ServerAuth.validate(..., filler_seats)`: FULL discounts the filler fakes (since the review, those that have not yet set aside
    their slot for anyone).
  - `ZoneServer.set_filler_keeper()`: the server now carries the whole keeper. It counts people's additions and removals for it (before they were
    wired by `ServerMain` with the `player_joined` and `player_left` signals), requests the slot after an accepted HELLO with the server
    full and notifies it of each fake that leaves (`forget`). That way a filler fake removed by another route (the console's `kick`
    command) no longer stays recorded as filler.
  - `ServerMain` just creates the keeper and hands it over.
- **`ZoneServer.get_player_count()` no longer counts fakes with a removal requested** (`remove_fake_player`, which leave at the start of the
  next tick), just as it did not count peers that are leaving. It was needed so that two HELLOs in the same `poll` see the slot just
  yielded by a fake. Fake additions through `--fake-churn` still happen on the tick after the removal, so the peak does not change.
- **Decision**: if the entering person's realm has no filler, the side with the highest total yields its slot, it is not rejected with "full". It is chosen
  among all realms by the total with the person counted, and not always theirs first: with Vardheim 1 against Solmarch 3 (all
  filler), a Vardheim person leaves 2 against 2 instead of 1 against 3.
- Tests:
  - `test_realm_balance` (eight new: which realm yields, one per person, two simultaneous HELLOs, restoration if they leave without entering). Its `Rig`
    now uses methods instead of lambdas: the Rig → keeper → lambda cycle left objects unfreed on exit.
  - `test_server_auth` (FULL with filler).
  - `test_zone_server_net`, with ENet: four people enter a four-slot server full of filler and the fifth gets "full";
    a fake that is not filler still takes up its slot; whoever leaves while loading gets the fake back (since the F6b review the
    fake does not get to leave: see "F6b review").
  - `test_server_main` (GUE-42's real process now starts with `--max-players=6` and six fakes). Before the change, the swarm's three people
    got "Servidor lleno" (Server full).

**F6b, package B: the bots against the real NPCs and GUE-15 end to end** (new tests in `test_siege_npcs` and
`test_bot_threat_sight`, and extensions of `test_bot_brain_siege`, `test_fort_gate_collision`, `test_npc_system`, `test_siege_view` and
`test_siege_zone`)

- **What was already there**: the fakes' enemy finder included non-immortal NPCs, so 20 Vardheim bots already broke the
  gate, killed the Hollow and the Ford Captain and captured the neutral fort with no command from the first battle with
  `--npcs` (gate at 40 s, captain at 65 s, capture at 80 s). What did not come out was the recapture: in 20 min, none.
- **Brain (`BotBrain`, SIEGE pattern)**. All deterministic (without the bot's generator, except what already used it); COMBAT and WANDER do not
  change (the fingerprint test stays the same):
  - *Telegraphed blows.* `BotBrain.Threat` (origin, turn and reach of a TELEGRAPH) and `set_threat_finder`. If it is in the zone (the half-plane in
    front up to the reach, with 1 m of margin: the notice does not give the angle and the Captain's is 120°), it leaves it in a straight line
    away from whoever is hitting, with a **dodge** at the start (4.5 m in 0.45 s, with invulnerability) and sprinting, without blocking or finishing
    what it was doing; if still inside, another dodge every 15 ticks. New task `EVADE`, at the end of the enum. Measured in the neutral
    capture with 20 bots (seed 1000): **without leaving the zone, 14 unblockable blows hit someone (4475 damage) and 7 bots die; with
    the dodge, none and no deaths**, at the cost of 5 s more to kill the Captain (72.9 s versus 67.7 s). Only sprinting, without the
    dodge, they left too late (11 of 16 blows in an intermediate version, all on bots that were leaving: in the middle of an attack they barely
    move). All telegraphed heavy attacks of the NPCs are avoided (the notice is the same for all), not just the unblockable.
  - *Defenders first.* `set_defender_finder`: while the circle is not active (the captain lives), the nearest enemy NPC in
    range goes before any player. Without this, in the recapture the attackers fought the 20 defenders and almost never the
    captain. With the circle active, the nearest of all.
  - *Chases without progress.* If, chasing someone more than 3 m away, it does not get 1 m closer in 180 ticks (a guard behind a wall or on the
    walkway), it stops chasing anyone who is not within 3 m for 600 ticks. Before, "fighting" was never being stuck and nine
    bots stayed a minute against a wall chasing a patrolling guard they could not reach.
  - *The enclosure.* `ApproachRoutes.enclosure_size` (40 x 40 m in the Vado Gris; written by the exporter), `SiegeView.enclosure_size` and
    `is_inside_enclosure()`. "Inside the fort" used to be "on the other side of the gate's wall and within 30 m of the circle", which includes
    the strips outside the side and back walls: a bot that a fight left stuck to the south wall from outside went straight to the
    circle against the palisade (six of Solmarch's twenty, for over a minute, in a recapture with NPCs). Now, outside the
    enclosure and to one side or behind, it goes around the palisade by its corners (at 6 m) to the gate wall; and when stuck to the gate
    wall but outside the doorway (more than 1.6 m from its axis), it first goes back in front of the gate instead of crossing diagonally.
- **Server**: `ZoneServer` gives each SIEGE fake the blow finder (`_find_threats`: the ongoing heavy attacks of NPCs of a hostile
  realm, from when they start until the end of their active window, with the NPC's position and turn on that tick, because it turns while
  charging; gathered once per tick) and the defender finder (`_find_enemy_position(..., npcs_only)`). The siege view takes the enclosure from the
  routes.
- **Clients**: `BotThreatSight` (client) stores TELEGRAPHs as threats until their impact plus 12 ticks (the tick it is
  queried with is that of the input being decided); `SwarmBot` (`--bots`) fills it with ENTITY_EVENTs and looks for defenders among the NPCs
  of its spawns; `ClientBotBrains` (`--bot`) with `NetClient.telegraph_received` and `BotEnemySight(..., war_npcs_only)`. Since the
  F6b review they only store the notices of whoever can damage them, like the server (`SwarmBot`, those of the hostile war NPCs
  among its spawns; `--bot`, `BotThreatSight.is_hostile_view` with the remote's realm): before, they also dodged the heavy attacks of their own
  realm's garrison.
- **Weaker NPCs for a test only**: `NpcSpawnerSystem.set_definition_override(id, definition)` / `get_definition(id)` replace a
  definition on that server (the catalog, shared by the whole process, does not change; the `npc_def_id` is still the catalog's).
  `SiegeRunner.set_npc_health(id, health)` and `siege_battle.gd --npc-health=<id>:<health>` use it.
- **Tools**: `SiegeRunner` records NPC deaths (`npc_deaths`), gives each bot's brain (`get_brain`) and the notices from a
  tick (`tick_of_war(..., from)`, `count_war`). `siege_battle.gd` gains `--npcs` (with the NPCs and no aids), `--npc-health`,
  `--verbose` (state every 10 s of play) and the milestones of each phase in the report (first hit, gate broken and how many times, captain
  down and capture, counted from when the phase's bots leave).
- **Finding and fix: hits landed from inside the closed gate.** The owner crosses their closed gate, and whoever stayed with their chest
  inside the sight box hit outward without those outside being able to hit them: the line-of-sight ray that *starts*
  inside a box does not see it. In the first recapture with NPCs, the defenders crowded in the doorway killed all 20 attackers on the
  esplanade without losing anyone (and at 112 against 4 in 6 min). `HitShapes.is_ray_clear` now uses `hit_from_inside`: inside the closed
  gate you neither hit nor get hit (concave meshes and terrain do not change). `test_fort_gate_collision` checks it and fails without the
  change. It also affects NPC perception and the client's nameplates, which use the same ray.
- Tests:
  - `test_siege_npcs` (the short version of GUE-15 with NPCs): 12 Vardheim bots in front of the gate (the march is already tested by
    `test_siege_zone`), capture x30 and, only on that server, the Captain with 9000 health and the Hollow with 1000. They break the gate, kill the
    Hollow and the Captain by themselves (the "captain down" notice is Vardheim's) and capture; the Captain telegraphs its blows, some leave its
    zone and the unblockable hits none of those who were leaving. It is deterministic: in this package, gate at 17 s, captain at 35–38 s
    and capture half a second later; with GUE-44 and GUE-45, 19.8 / 42.4 / 42.9 s, and with the final code (after the F6b review),
    **gate at 19.8 s, captain at 36.6 s and capture at 37.4 s**, with 3 telegraphed blows. The test's phase takes about 7 s with
    the machine lightly loaded and up to 12 s with it loaded.
  - `test_bot_brain_siege` (six new): a blow's zone; it leaves with a dodge without blocking and before the impact; the NPC before the
    nearest player, and not the one behind the gate; it drops a chase that does not get it closer and chases again after the deadline; it goes around the
    enclosure instead of crossing the palisade (fails without the change); determinism with the two new finders.
  - `test_bot_threat_sight` (three), `test_npc_system` (the substitution only changes that server), `test_siege_view` (the enclosure, also
    with the gate on another wall) and `test_siege_zone` (the server's view carries the enclosure from the data).

**Measured in F6b (package B)** with `siege_battle.gd --npcs --per-side=20 --minutes=28` (20 Vardheim capture the neutral fort and, as soon as
it is theirs, 20 Solmarch leave and recapture it while Vardheim defends it; nobody gives orders). Play times, so they do not depend
on the machine (4 cores shared with other suites: each battle took 5 to 15 min of wall clock); they change with the brains' seed. The
recapture times count from when Solmarch leaves:

| Seed, realm captain | Neutral → Vardheim: gate broken / Ford Captain / capture | Recapture: gate broken / realm captain / capture | Player deaths (S / V) |
|---|---|---|---|
| 1000, 15,000 health | 40.2 / 72.9 / **87.9 s** | 181.5 / 300.9 / **404.8 s (6.7 min)** | 111 / 39 |
| 2000, 15,000 | 42.4 / 71.3 / 86.3 s | 111.8 / 978.9 s / **not in 28 min** (the gate falls 3 times) | 490 / 140 |
| 3000, 15,000 | 42.3 / 71.3 / 86.3 s | 233.1 / 960.9 s / **not in 28 min** (the captain falls 2 times) | 453 / 114 |
| 1000, **7500** | same | 181.5 / 278.3 / **399.4 s (6.7 min)** | 117 / 33 |
| 2000, **7500** | same | 111.8 / 441.9 / **1654.8 s (27.6 min)** (the captain falls 3 times) | 433 / 149 |
| 3000, **7500** | same | 233.1 / 357.3 / **1471.8 s (24.5 min)** (the captain falls 2 times) | 406 / 127 |

- **The capture of the neutral is solid**: with all three seeds, gate at 40–42 s (the esplanade is reached at 25 s by the bridge and at
  37 s by the ford), the four Hollow (and the reinforcements the Captain calls) and the Ford Captain (30,000) dead at 71–73 s and capture at
  86–88 s, **with no Vardheim deaths** in all three. It is the bot measurement of MUN-10 and MUN-11, not the people one.
- **The recapture is the hard part, and not because of the NPCs.** The realm captain with 15,000 health went down to 20 % and, when the wave of
  attackers fell, returned to its post regenerated (what a boss does when it loses all its enemies); with 15,000, one recapture out of three within the
  Vado Gris's 30 min cycle (`reset_to_neutral_s`). With 7500, all three, but two take 25–28 min: the captain falls quickly and what is costly
  is being left alone in the circle against the 20 defenders, who win the fights 3 to 1 in deaths because the attackers arrive piecemeal (30 s
  of respawn, each on their own and outside a wave, plus 25–37 s of marching: phase 4 review) and enter one at a time through a 4 m doorway. This is GUE-44, which decides whether the attacker
  waits for their own or whether it is a desired effect; until then the times in `vado_gris.tres` are not touched.
- **Provisional adjustment (F6b)**: `data/npcs/realm_captain.tres`, health **15,000 → 7500** (half; a quarter of the Ford Captain's). It is the
  only data change: with it the recapture fits in the 30 min cycle with all three seeds, and without it not. The 7500 rows were measured with
  `--npc-health=realm_captain:7500`; the battle with the data already changed gives exactly the same (seed 1000: Solmarch captures at tick
  29,250). It is reviewed with GUE-44 and, above all, with people (MUN-11 and GUE-11 ask for 3–5 players against a captain). Reviewed in
  package C: with GUE-44 the bots recapture within the cycle also with 15,000, so the adjustment is no longer needed for them; it is left at
  7500 until tested with people.
- **Telegraphed blows in the long battle**: with the dodge, no unblockable blow hit a bot in the neutral capture (14 without leaving
  the zone, see above); the suite's short version checks that it hits none of those who were leaving.
- **What this package does not do**: GUE-44 (reinforcements gather before leaving), GUE-45 (the walkway), load with NPCs (GUE-16) and the
  battle with full telemetry. The long battle uses the server's fake players (the same `BotBrain` as `--bots` and `--bot`, with its
  server finders); with `SwarmBot` over ENet and NPCs there are only unit tests of what is new (`BotThreatSight`) and the F6a ones without NPCs.

**F6b, package C: GUE-44, the gathering and formation of the siege bots** (new tests in `test_bot_brain_rally`; extensions of
`test_siege_zone` and `test_siege_clients`)

- **Decision**: reinforcements in a trickle are **not** a desired effect. An attacker who starts or respawns at their camp waits for
  their own and leaves as a group, and in a group each goes in their own slot. Both are needed: each one separately improves little or nothing
  (table below).
- **Finding: bots pile up.** Characters do not collide with each other (their collision mask does not carry the characters layer), and bots that
  follow the same points (the four camp respawn points, the route, the spot from which they hit the gate, the circle)
  end up in exactly the same place. A sweeping blow (the weapon's sector) hits the whole pile at once. With the gathering and without
  slots (seed 2000), Solmarch's first group (20 bots in four piles of five, one per respawn point, which in front of the
  gate were almost a single one) died entirely in 1.2 s without killing anyone: each blow from the defenders coming out hit 19 at once (in those
  40 s, 194 Vardheim hits against 48). This, and not the circle, is what
  gave the defenders their 3 to 1: they too wait piled up in the circle, and whoever hits the pile first wins. A person does not
  pile up; bots do, which is why the formation lives in the brain and not in the simulation.
- **Gathering** (`BotBrain`, SIEGE pattern; deterministic, no generator). At the start and after each respawn (a jump of more than 5 m), if it is
  an attacker (the fort is not theirs) and is within 15 m of the **rally point** (the camp exit: the first point of its
  routes, `get_siege_rally_point()`; the four respawn points are inside), it waits there (new task `RALLY`, at the end of the enum)
  until one of three conditions is met:
  - there are **8 of its realm** within 15 m of the point (itself included; `SIEGE_RALLY_GROUP_SIZE`);
  - there are **3 of its own within 25 m of the circle** (`SIEGE_RALLY_JOIN_COUNT`, `SIEGE_RALLY_FORT_RADIUS`): an assault under way is not
    left without reinforcements, because between one wave and the next the captain heals and the gate is repaired;
  - the next **shared clock departure** arrives: one every 30 s of match (`SIEGE_RALLY_PERIOD_TICKS`), 5 s after a respawn
    wave (`SIEGE_RALLY_OFFSET_TICKS`; waves fall on multiples of 600 ticks). *Phase 4 review: until then the server's
    fakes did not respawn in waves (they left by the automatic one, at exactly 30 s), so the 5 s offset was of no use to
    them; now they request the respawn on death and it is.* The tick is shared by all the bots, so those
    waiting leave together without talking to each other (`next_rally_departure`).
  The whole group goes by **the same route**: that of the clock lap in which it leaves (`rally_route_index`, they alternate), not that of each one's
  generator; clock departures fall mid-lap, so a few ticks of difference between clients does not change it. The owner does not wait
  (defends as soon as it can) and stops waiting if its realm becomes the owner. While waiting it fights whoever comes near, as in
  the march. Those present are counted by whatever supplies `set_ally_counter(center, radius) -> int` (the living players of its realm at that distance, not itself);
  **without a counter, or with `set_rally(1)` or less, it neither waits nor goes in formation: the behavior of F6a and package B**, which is that of the
  brain tests that do not set it.
- **Formation**: in a group (with counter and gathering), each bot has a slot, a point of the unit disc that comes from its seed through the
  R2 sequence (`slot_for_seed`; with twenty consecutive seeds the closest pair stays on average at 0.19 and never under 0.1 on the
  bases from 0 to 6000, although in one of every ten bases it drops below 0.18; checked by `test_bot_brain_rally`), and adds it to where it is going: ±1 m sideways on the
  march, ±1.6 m along the gate when hitting it (facing it head on), up to 2 m around the circle's center and up to 4 m
  around the rally point. An attempt to also give each one their doorway lane when crossing the gate came out worse (with the gathering
  of 8, seeds 1000 and 2000: 743 and 725 s versus 145 and 143) and was removed.
- **Ally counters**: the server (`ZoneServer._count_allies`, with the list of living players per realm gathered once per tick,
  so everyone waiting on a tick sees the same count; people and fakes, no NPCs or GUE-41 bodies), `SwarmBot`
  (`--bots`: follows the players of its realm through its spawns and the same snapshot records it already decoded for
  enemies) and `BotAllySight` (`--bot`: the remotes of its realm drawn by its `RemoteWorld`). A `SwarmBot` does not see what is outside
  its interest: if it does not see those at the fort, it waits for the group or the clock.
- **Tools**: `SiegeRunner.set_rally(size, lap)` and `rally_departures` (each gathering departure); `siege_battle.gd --rally=N`
  (0 or 1: no gathering or formation, for comparison), `--rally-period=S` and, in the report, each realm's group departures. Fixed
  along the way in the report: the capture that ends a phase could fall exactly on the tick where the next begins and show up in it ("capture
  at 0.0 s" of the recapture, with seed 4000).
- **Tests**: `test_bot_brain_rally` (fifteen, no physics: the rally point; the shared clock and the group's route; without a counter it leaves right away;
  alone, it waits for the clock; four arriving one by one leave on the fourth's tick by the same route; three arriving at
  different moments leave together with the clock; it waits again on respawning; neither one that appears far from the camp nor the owner waits; it does not
  wait if its own are already fighting at the fort; it stops waiting if its realm wins the fort; a group of 1 does not wait; it fights while waiting;
  determinism; the slots; in a group they hit the gate and guard the circle each in their own place). `test_siege_zone`: a new one with the
  real server (two Solmarch wait, a third arrives and all three leave on the same tick and by the same route; an owner's bot
  neither waits nor counts), and the two-routes one removes the gathering (`set_rally(0)`) because it measures the two routes and the gathering sends everyone
  by the same one. `test_siege_clients`: each `SwarmBot` counts the other two of its realm.
- **Consequences**: with the gathering, `test_siege_zone` and `test_server_main` (four fakes, two per realm) leave at 5 s (the first
  clock departure) instead of on the first tick. In `load_test.gd --siege` the fakes leave at once (there are more than 8 per realm), but the
  `SwarmBot`s that enter afterwards may wait at the camp for up to 30 s if they do not see those at the fort: when repeating the load with NPCs
  (GUE-16) we must check that they arrive before the measurement window.

**Measured in F6b (package C)** with `siege_battle.gd --npcs --per-side=20 --minutes=28` and five seeds (the three from package B and two more),
the realm captain at 7500; play times from when Solmarch leaves, in seconds (4 cores shared with other suites: each
battle took 1 to 7 min of wall clock, and the earlier ones up to 12):

| Recapture (s) | 1000 | 2000 | 3000 | 4000 | 5000 | Median |
|---|---|---|---|---|---|---|
| Before (`--rally=0`: no gathering or formation) | 399.4 | 1654.8 | 1471.8 | 266.0 | 334.4 | 399 (6.7 min) |
| Gathering only (8 or the 30 s clock), no slots | | 772.5 | | | | |
| Formation only, no gathering | 419.1 | 472.7 | 610.4 | 538.1 | 748.5 | 538 (9.0 min) |
| Gathering (8 or the clock) and formation, no "go help" | 145.0 | 142.5 | 1521.5 | 157.2 | not in 28 min | |
| Gathering of 12 and formation | 156.1 | 161.8 | 637.4 | 795.2 | 926.8 | 637 |
| Gathering of 20 (almost only the clock) and formation | not in 28 min | not in 28 min | not in 28 min | | | |
| Gathering only at the start (reinforcements do not wait) and formation | 337.7 | 144.1 | 274.4 | 772.0 | 777.5 | 337 |
| **GUE-44 (gathering of 8, "go help" with 3, 30 s clock, formation)** | **145.0** | **142.5** | **288.8** | **157.2** | **766.0** | **157 (2.6 min)** |
| The same with the realm captain at 15,000 | 153.8 | 162.1 | 691.4 | 897.8 | 1045.4 | 691 (11.5 min) |

- **With GUE-44**: player deaths Solmarch / Vardheim 29 / 31, 29 / 33, 61 / 75, 37 / 38 and 194 / 93 (before 117 / 33, 433 / 149,
  406 / 127, 59 / 56 and 93 / 45): from 2.7 to 1.3 attacker deaths per defender one. Capture of the neutral at 84.7 / 89.0 /
  87.2 / 80.5 / 82.4 s, with no Vardheim deaths (before 86–88 s). The battle of seed 4000 with the final code and `--battle-log` gives
  the same as the table (captures at 80.5 and 157.2 s of the cycle) and its summary: 75 player deaths, 71 on the esplanade and the
  courtyard, 4 at the ford, none at the bridge or the walkway; the gate breaks 12.0 and 12.8 s after the first hit.
- **Two regimes**: either the first group of 20 (which leaves whole and by the same route) wins the gate fight during Vardheim's
  consolidation, waits for the garrison to appear and kills it right away (**2.4–2.6 min**: the floor is set by the 120 s of consolidation), or it
  loses it and a tug of war of waves begins (4.8 and 12.8 min). The battle is chaotic: a small change (the lanes, the group
  size) changes which seeds fall in each regime, so only configurations with all five seeds are compared.
- **What does not work**: waiting longer. With groups of 12 or 20 the reinforcements take longer to come back than the owner's (who respawn and
  return without waiting) and, between wave and wave, the captain heals and the gate is repaired; with 20, none of three recaptures in 28 min. Hence
  the "go help" rule and a group of 8. Gathering without slots is not enough either (772.5 s with seed 2000), and slots without
  gathering give regular but slow recaptures (7–12.5 min): the first group leaves split between the two routes.
- **The realm captain**: with GUE-44, at 15,000 the bots recapture within the 30 min cycle all five times (from 2.6 to 17.4 min); the
  provisional adjustment to 7500 from package B is no longer needed for the bots, but is left until tested with people (MUN-11, GUE-11).
- **What this package does not do**: walkway defense (GUE-45), load with NPCs (GUE-16) and the `SwarmBot` battle over ENet
  with NPCs (the gathering of `--bots` and `--bot` is tested with their counters, not in a long battle: `SwarmBot`'s in
  `test_siege_clients`; `--bot`'s, `BotAllySight`, had no test of its own until the F6b review, which adds `test_bot_ally_sight`
  and checks in `test_siege_clients` that the `--bot` carries its counter, its notices and its defender finder). Defenders do not
  gather: the owner returns to their fort as soon as they respawn.

**F6b, package D: GUE-45, the owner bots defend the walkway** (new tests in `test_bot_brain_walkway`; extensions of
`test_approach_routes`, `test_navmesh`, `test_siege_zone` and `test_battle_summary`)

- **What was asked for and what is possible.** The brief was that part of the owner would climb onto the walkway and hit the people at the
  gate from there. **With melee weapons this is not possible**: the weapon's sector runs from 0.2 to 2 m above the feet of whoever hits and the
  target's capsule from 0 to 1.8 m above theirs, so nobody reaches someone more than 1.6 m below or 2 m above; the walkway is
  3.35 m above the courtyard and the esplanade, and whoever hits the gate is 2.3 m outside it and the walkway's axis 1.2 m
  inside (about 3.5 m horizontally, with the parapet in between). Neither can those above reach those below nor the reverse. **What they do**:
  the owner's bots with the walkway role climb and guard it above the gate, ignoring those below, and fight whoever
  climbs up; some of the attackers walk it on entering the fort (otherwise nobody would climb and the telemetry would never see a death
  there). From the walkway the gate can only be attacked with ranged weapons (the bow, CMB-23), which do not exist. (The bow
  arrived with phase 4: since the abilities integration review, below, the guard with a bow shoots from the
  walkway at whoever is in range; what remains is in GUE-47.)
- **The climb, a precomputed route** (not `NpcNavigation` on each query): the brain is shared and is used by the server's fakes,
  `SwarmBot` (`--bots`) and `--bot`, and the navigation mesh only exists on the server. `ApproachRoutes` gains
  `walkway_height` (13.55 m: the 10.2 m plateau plus 3.35), `walkway_path` (the walkway's axis, from the top of the north ramp to that of
  the south one passing through the two corners of the west face and above the gate) and `walkway_ramps` (each ramp as a route from the courtyard:
  a point between the gate and the tower, the one in front of its foot and its top, on the axis); written by `export_vado_gris_routes.gd`. It is
  deterministic and the NPC mesh (MUN-06) accepts it: `test_navmesh` checks that each leg, from the circle to the post by each
  ramp, has a route in the mesh and that this is no longer than the straight leg by 1.2 plus 1.5 m; `verify_vado_gris_routes.gd` now
  walks it with the real character from the data (93.0 m in 18.9 s from the esplanade, the same by both ramps; it ends
  3.36 m above the plateau).
- **Finding: the climb cannot cross the circle.** The first route used the interior points that the verification already walked,
  (-6, ∓6) and (7, ∓5): the leg from the gate passed 4.7 m from the circle's center, and owner bots coming back up after
  respawning disputed the capture in passing and fought there. With it the 20 against 20 recapture went from a median of 2.6 to 7.1
  min (five out of five seeds in the slow regime). Now the first point is (-12, ∓9), 9.6 m from the center (`test_approach_routes`
  checks that no ramp leg passes within less than the radius plus 1 m).
- **The role** (`BotBrain`, SIEGE pattern; deterministic, no generator). It is given by the seed through the Weyl sequence of the golden ratio
  (`is_walkway_seed`), which distributes almost equally consecutive seeds or one in every N: **a quarter guard the walkway when their realm
  is the owner** (`SIEGE_WALKWAY_SHARE`: 4 to 6 out of every 20 consecutive seeds, 5 in more than half of the bases; base 2000 gives 6) and
  **half of those walk it when attacking** (`SIEGE_WALKWAY_SWEEP_SHARE`, 0.125: 1 to 4 out of every 20, almost always 2 or 3). `set_walkway_role(guard, sweep)` and `set_walkway_share(share)` change it (with 0, as before GUE-45); without walkway data
  in the routes it does nothing.
  - *The owner* (new task `WALKWAY`, at the end of the enum): if outside it enters through its gate as usual; in the courtyard it goes to the nearest
    point of the ramp on its side and climbs; on the walkway it follows its axis (at each corner, the corner first) to its post, above
    the gate plus its slot along it (±4 m), and stays there looking outward. If a fight pushes it more than 0.5 m off the axis, it returns
    to it before continuing; if it falls or is pushed off the ramp, it returns to the foot and climbs again.
  - *The attacker who walks it*: once per life, on entering the fort (with the gate open for them) it climbs the same way to that post,
    fighting whoever it finds, and then jumps into the courtyard (3.35 m: no damage, fall damage starts at 15 m/s and it is 12) and goes to the circle.
  - *Levels*: inside the enclosure (the courtyard is flat), whoever is more than 1.6 m higher or lower is neither a target nor a telegraphed blow
    to leave (`_siege_same_level`); outside (the slopes) nothing changes. Without this, a courtyard bot that chased someone on the
    walkway could end up underneath swinging at the air (the chase without progress is only dropped beyond 3 m), and those on the walkway
    would jump into the courtyard after those below. On the walkway it does not dodge sideways
    (it would throw it into the courtyard): the dodge is backward, along the axis, with the same use of the generator.
  - *Nearest with height weighted*: the bots' enemy finders (the server, `SwarmBot` and `BotEnemySight`) choose with
    `BotBrain.target_distance_squared`, horizontal distance plus vertical times 4: the walkway ends up more than 13 m away, farther than the
    fight reach (12 m), so the enemy in range on its own level goes first. Without this, the one on the walkway covered the one in the courtyard for whoever
    was below, and vice versa. With role-less bots (`--walkway=0`) seeds 1000, 2000 and 4000 give the same recapture as in
    package C (145.0, 142.5 and 157.2 s); 3000 and 5000 change (489.7 and 1243.3 s versus 288.8 and 766.0): the battle is chaotic.
- **Telemetry**: `BattleSummary` already had the `walkway` class (spawn and within 30 m of the circle); now, if the routes know the
  walkway, also its whole axis (the back corners are more than 30 m away), and it counts NPC deaths per place
  (`npcs_by_route`, "PNJ: pasarela N" in the text). `SiegeRunner` records the position of NPC deaths, gives `place_of(position)` and
  `set_walkway_share`; `siege_battle.gd` gains `--walkway=F` and writes where players and NPCs fall, and which realm those on the
  walkway belong to.
- **Tests**: `test_bot_brain_walkway` (fourteen, no physics: a point with simple heights, the courtyard, the ramps and the walkway with no
  inner railing): the role distribution; the post; the owner climbs the ramp on its side without falling or leaving the axis (13.5 s
  from the circle) and guards its post looking outward; from outside it enters through the doorway and climbs; those without the role stay in the
  circle; on the walkway it ignores those below and fights the one climbing; it turns a corner fighting and never dodges sideways;
  the attacker walks it once and jumps to the circle, and again after respawning; without a role or outside it does not climb; from the ground the one on the
  walkway is not a target (and on the outside slope it is); a telegraphed blow from another level is not dodged; pushed off the ramp
  it climbs again; height weighting; determinism. `test_approach_routes` (the walkway data and its calculations), `test_navmesh` (the
  route on the NPC mesh), `test_battle_summary` (the classes and NPCs per place) and `test_siege_zone`, with the zone's physics:
  of four owner bots from their camp, two in the circle and **two climb to their walkway post** (at 13.55 m, at 40.7 s of
  play) and one death on the walkway between a guard and a Solmarch bot who enters through the broken gate and climbs (2.2 s of wall clock per phase).
  The brain tests without height (`test_bot_brain_siege`, `test_bot_brain_rally`) remove the role.
- **Measured** with `siege_battle.gd --npcs --per-side=20 --minutes=28` and the five GUE-44 seeds (play times from when
  Solmarch leaves; 4 cores shared with other suites, 1 to 7.5 min of wall clock per battle). The climb outside the circle in all
  but the second row:

| Recapture (s) and deaths on the walkway | 1000 | 2000 | 3000 | 4000 | 5000 | Median |
|---|---|---|---|---|---|---|
| Nobody on the walkway (`--walkway=0`) | 145.0 · 0 | 142.5 · 0 | 489.7 · 0 | 157.2 · 0 | 1243.3 · 0 | 157.2 (2.6 min) |
| Climb crossing the circle; 25 % of attackers walk it | 428.5 · 6 | 465.3 · 0 | 275.7 · 11 | 305.7 · 12 | 510.4 · 4 | 428.5 (7.1 min) |
| 25 % of attackers walk it | 317.9 · 6 | 148.2 · 3 | 143.0 · 4 | 1139.1 · 11 | 325.9 · 9 | 317.9 (5.3 min) |
| They walk it only with the circle active | 144.2 · 0 | 144.8 · 0 | 165.2 · 1 | 147.6 · 0 | 524.4 · 0 | 147.6 (2.5 min) |
| They walk it with the circle active or 6 of their own near it | 468.4 · 6 | 148.2 · 3 | 143.0 · 4 | 415.0 · 4 | 259.6 · 1 | 259.6 (4.3 min) |
| **GUE-45: 12.5 % of attackers walk it** | **263.6 · 2** | **146.3 · 6** | **264.8 · 3** | **159.5 · 4** | **160.2 · 1** | **160.2 (2.7 min)** |

- **With GUE-45**: **deaths on the walkway in all five battles** (16 of players: 11 of Solmarch, almost all those who walk it and
  run into the Vardheim guards, five or six depending on the seed, and 5 of Vardheim, all on seed 2000, where those who climb win); no NPC dies on
  it. Recapture from 2.4 to 4.4 min (median 2.7, the same as without a walkway, 2.6) and without the long tails of 8.2 and 20.7 min; player
  deaths Solmarch / Vardheim 51 / 44, 22 / 27, 65 / 43, 16 / 32 and 33 / 27. Capture of the neutral at 80–87 s, as before. The
  five battles repeated with the final code and `--battle-log` give exactly the same (it is deterministic) and the log summary
  (`summarize_battle.gd`) counts the same deaths on the walkway.
- **Decision**: half of those who guard it walk the walkway. Having the same 25 % walk it pulls about five attackers out of the courtyard
  who climb one by one against the five or six guards and die there (the recapture doubles); having them do it only with the circle active leaves
  barely any deaths on the walkway (the capture ends 15 s later) and the GUE-45 criterion would not be met. With melee weapons the
  walkway defends nothing (the guards neither reach the gate nor count in the circle), so for defense it is one slot
  less; it stays so, ready for when there are bows, and is reviewed with people. (There are already: see "Abilities integration
  review", below, and GUE-47.)
- **What this package does not do**: hitting those at the gate from the walkway (out of reach; needs the bow), having the guards come down
  to dispute the circle, the `SwarmBot` battle over ENet with the walkway (the same brain and the same data, tested without network and
  with the server's fakes) and load with NPCs (GUE-16).

**F6b, package E: load and telemetry with the NPCs (GUE-16, GUE-17) and the closing of F6b** (extensions of `test_load_test` and
`test_siege_clients`)

- **`load_test.gd --npcs`** (with `--scenario=siege` or with the `--siege` battery): the server starts with its NPCs and the fort runs on its own,
  without `fort_kill_captain`. Without the option it is F6a's siege, which now passes `--no-npcs` explicitly: since F4 was merged the
  tool started with the NPCs and also killed the captain by command at the start of the window, a mix that measured neither F6a's siege
  nor the one with NPCs. `siege_server_args()` decides it. The summary gains the `npc_brains` (the NPC brains) and `npc` (the spawners) sections, both
  and `war` with their average over the whole session (the report's percentiles are from the last 34 s, and the fort's NPCs may have died
  before), what the NPC report says (alive at the end, spawned, dead, notices) and how many real bots had reached the
  fort before the window.
- **Server**: the metrics line every 10 s ends in "N PNJ" (NPCs), those simulated at that moment (war ones and dummies).
  `LoadTestSummary.parse_tick_timeline` reads it (-1 on earlier lines) and `timeline_window` gives the minimum and maximum of the window.
- **Clients**: `SwarmBot` records in its report `fort_reached_tick`, the server tick at which it first gets within 25 m
  of the circle (`BotBrain.SIEGE_RALLY_FORT_RADIUS`), and `LoadTestSummary.fort_arrivals` counts those that arrived before the window. Package C
  asked for it: `SwarmBot`s that enter when the fakes have already left could stay up to 30 s waiting at the camp.
  **They all arrive before the window**: the last one, at 25–26.5 s of the match with 32 against 32 (ticks 1499 to 1590) and at 54 s with 64
  against 64 (tick 3263; the window starts at 3530). They leave as soon as they see 3 of their own at the fort, or with the clock.
- **Tests**: `test_load_test` (two new and one extended: the server options with and without `--npcs` and the summary sections;
  the arrival of the real bots; the metrics line with the NPCs and their minimum and maximum in the window) and `test_siege_clients` (the
  `SwarmBot` report says -1 at the camp and, on arriving, the tick).

**Measured in F6b (package E): load with NPCs** with `load_test.gd --scenario=siege --fakes=54 --bots=10 --seconds=120 [--npcs]` (32
against 32). Two passes of each, alternated, on the same 4-core machine **with no other suite running** (average load 0.5 to
1.1, only these measurements); F6a measured with another suite at the same time, so its figures are not compared in detail with these. Tick in ms of the
server's last 34 s stretch; "window", the median of the 10 s marks in the measurement window (each over the previous 34 s);
NPC and fortress sections in ms, with the session average in parentheses:

| Siege | Tick p50 / p95 / p99 / max | Window p50 / p99 | `sim` p50 | `npc_brains` p50 / p99 (average) | `npc` p50 / p99 (average) | `war` p50 / p99 | Downstream per client | Substituted (window) |
|---|---|---|---|---|---|---|---|---|
| **32 against 32 with NPCs**, 1st | 10.6 / 14.8 / 17.4 / 27.5 | 10.5 / 17.4 | 7.0 | 0.22 / 0.41 (0.29) | 0.06 / 0.12 (0.07) | 0.08 / 1.1 | 36.2 KB/s | 0.03 % (18 of 66,000) |
| **32 against 32 with NPCs**, 2nd | 9.4 / 13.5 / 15.2 / 23.0 | 10.8 / 17.9 | 6.1 | 0.20 / 0.37 (0.31) | 0.06 / 0.13 (0.08) | 0.08 / 1.1 | 36.3 KB/s | 0.00 % |
| 32 against 32 without NPCs (F6a), 1st | 9.1 / 12.8 / 15.0 / 27.9 | 9.7 / 15.8 | 6.2 | 0.05 / 0.10 (0.05) | 0 | 0.08 / 1.0 | 36.2 KB/s | 0.00 % |
| 32 against 32 without NPCs (F6a), 2nd | 9.9 / 14.2 / 16.9 / 24.9 | 10.7 / 17.8 | 6.7 | 0.05 / 0.12 (0.06) | 0 | 0.09 / 1.1 | 36.2 KB/s | 0.00 % |
| 64 against 64 with NPCs, 1st: **it is not 128** (see the review) | 16.2 / 22.8 / 27.0 / 39.6, of **118** players with no client | 19.6 / 33.5 (the 8 marks with the 128; the 12, 19.6 / 33.7) | 13.5 (of 118) | 0.27 / 0.56 (0.38), of 118 | 0.07 / 0.15 (0.09), of 118 | 0.09 / 2.1, of 118 | 29.0 KB/s | **38.6 %**; 83 rewinds rejected (10 suspicious) |
| 64 against 64 with NPCs, 2nd (F6b review; with another suite running, load 0.7 to 1.8) | 17.2 / 24.2 / 30.0 / 72.3 (90 % of the stretch with the 128) | 17.8 / 31.0 (12 marks, all with 128) | 12.3 | 0.23 / 0.46 (0.32) | 0.06 / 0.11 (0.07) | 0.08 / 1.9 | 32.1 KB/s | 0.00 % (3 of 66,000); 44 rewinds rejected (8 suspicious) |

- **What happens in the window** (from 59 to 177 s of the match). With NPCs, the two realms attack the neutral fort at the same time: the gate
  falls at 48.7 and 51.4 s, the four Hollow between 58 and 75 s, and the Ford Captain at 106.0 and 143.9 s; Vardheim captures at
  121.9 s in the first pass and Solmarch at 164.1 s in the second. There are 11 NPCs (the 9 war ones, which are the 4 Hollow, the
  Ford Captain and the 4 camp Guardians, and the 2 dummies) until the Hollow fall (58–75 s: the window starts at
  59), 7 (the Captain, the Guardians and the dummies) until the captain falls and 6 after; the Hollow do not come back while there are
  players within 40 m of the fort, so **almost the whole window has 7** (the marks from 80 s to the captain's fall) or 6. The
  owner's garrison does not get to spawn (it spawns when the consolidation ends, 120 s after the capture). 136 and 159 player deaths, 5 NPC deaths and 7 and 9 TELEGRAPH notices. Without NPCs
  (with `fort_kill_captain` at the start of the window), capture at 74–79 s.
- **The NPCs cost about 1 ms of the tick with all 9 war ones alive (the 5 of the fort and the 4 camp Guardians),
  of the order of the difference between two identical passes.** Their brains (`npc_brains`): 0.2 ms median with 6 NPCs; in the marks that
  cover the fight with the Hollow (up to 80 s, almost all before the window) each mark's p99 is 0.8 to 1.1 ms, with 7 NPCs
  0.5 to 0.9 ms and with 6 0.4 to 0.6 ms; session average, 0.29–0.31 ms versus 0.05–0.06 without NPCs (the dummies). The spawners
  (`npc`): 0.06 ms median. Their `simulate()` goes inside `sim`, at about 62 µs per character (average of players and NPCs): ~0.55 ms for the 9
  war ones. In total, ~1 ms with the 9 and ~0.5 ms when only the Guardians remain. Between two identical passes there is as much or more: the p50 of the last stretch gives
  9.1 and 9.9 ms without NPCs and 10.6 and 9.4 with them, and the window medians overlap (9.7–10.7 versus 10.5–10.8). **With these
  numbers the siege with NPCs cannot be told apart from the one without them.** The `war` section costs the same with and without NPCs (0.08 ms median,
  1.0–1.1 ms p99, presence recounted every 6 ticks with everyone in the circle).
- **Criteria** (networking.md 14 and 16) with 64 players and the NPCs: **p99 < 8 ms, no** (15.2–17.4 ms; `simulate()` dominates, as in F6a);
  **≤ 37 KB/s per client, yes** (36.2–36.3); **< 1 % substituted, yes** (0.00–0.03 %), and no rewind rejected. With 128 (64
  against 64), no: with all 128 present the tick p99 is 29 to 35 ms and the server does not reach real time (81 and 87 % in the two
  passes), so the clients run ahead and inputs reach the server ahead of time; in the first pass 38.6 % of
  their inputs were substituted and in the second almost none, and in both the rewind fails honest players (83 and 44 rejections). **The first limit
  on players per battle at the fort stays at 64 (32 against 32), also with the NPCs** (without the phase 4 kit; with it, 40: see
  "Abilities integration on top of F6b", below). (The first 64 against 64 row was published
  as 128 players; the F6b review saw that it was not: see below.)
- Compared to F6a without NPCs (10.6 / 15.3 / 19.1 / 27.8 ms, with another suite running), the two passes without NPCs now give 9.1–9.9 /
  12.8–14.2 / 15.0–16.9 ms with the machine quiet: the difference is the machine's load, not the code.

**Measured in F6b (package E): the battle with telemetry** (GUE-17) with `siege_battle.gd --npcs --per-side=20 --minutes=28 --seed=N
--battle-log=<path>` and the five seeds of GUE-44 and GUE-45, and the summary of each log with `summarize_battle.gd` (also
separately, with `--out` for the JSON). Play times (they do not depend on the machine; each battle, 72 to 122 s of wall clock with three at the
same time); those of the recapture, from when Solmarch leaves, which is when Vardheim captures and starts its 120 s consolidation:

| Seed | Neutral: first hit / gate broken / Ford Captain / capture | Recapture: first hit / gate broken (from the first hit) / realm captain / capture | Player deaths: total (esplanade and courtyard, ford, walkway) | NPC deaths |
|---|---|---|---|---|
| 1000 | 25.9 / 36.5 / 72.2 / 87.2 s | 24.9 / 37.7 (12.8) / 234.7 / 263.6 s | 95 (82, 11, 2) | 8 |
| 2000 | 25.8 / 37.3 / 71.2 / 86.2 s | 24.6 / 106.1 (81.5) / 130.3 / 146.3 s | 49 (43, 0, 6) | 10 |
| 3000 | 25.7 / 37.3 / 67.6 / 82.9 s | 24.7 / 39.6 (14.9) / 150.9 / 264.8 s | 108 (99, 6, 3) | 10 |
| 4000 | 25.9 / 37.9 / 65.2 / 80.2 s | 24.8 / 36.3 (11.6) / 141.0 / 159.5 s | 48 (44, 0, 4) | 10 |
| 5000 | 26.1 / 37.2 / 65.9 / 80.9 s | 25.0 / 47.0 (22.1) / 143.2 / 160.2 s | 60 (59, 0, 1) | 10 |

- **It is exactly package D's** (it is deterministic): recapture in 263.6 / 146.3 / 264.8 / 159.5 / 160.2 s (from 2.4 to 4.4 min,
  median 2.7) and 2 / 6 / 3 / 4 / 1 deaths on the walkway. No deaths on the bridge (the gathering groups all go by it); of
  the 360 player deaths, 327 on the esplanade and the courtyard, 17 at the ford and 16 on the walkway. Of the 48 NPCs dead, 47 on the esplanade and
  the courtyard; the other is the realm captain of seed 1000, who falls outside the enclosure, next to the bridge road and 25.6 m from the
  circle (its leash, `leash_radius`, is 36 m).
- **Capture of the neutral**: the 20 Vardheim arrive together by the bridge (25.6 to 27.1 s), break the gate in 10.7–12.0 s, the
  Ford Captain falls 28–36 s later and the capture lasts 15.0–15.3 s (four or more in the circle). No Vardheim deaths except two
  with seed 2000.
- **Recapture**: the 20 Solmarch hit the gate for the first time at 24.6–25.0 s, in the middle of Vardheim's consolidation, and break it
  in 11.6–22.1 s in four out of five (81.5 s with 2000, where the defenders hold it). The circle does not activate until
  the garrison spawns (120 s) and its captain falls, 10 to 115 s later (at 130–235 s); the capture itself lasts 15.0–18.5 s, and before that there may
  be a dispute (with 3000, 114 s pass from the captain's fall).
- **Decision: the data in `vado_gris.tres` does not change.** No figure is clearly out with these numbers:
  - `gate_health` 9000: still gives what GUE-10 asks (3 attackers, about 60 s; 54.8 s in F3). With 20 it falls in 11–12 s in the neutral and in
    12–22 s in the recapture, but in no phase is it what takes longest: in the neutral, the Ford Captain takes 28–36 s more; in the
    recapture the gate falls during the consolidation and the attackers wait for the garrison anyway. For it to count in the recapture with
    20 it would have to hold the ~95 s from the first hit to the end of the consolidation, about eight times today's health, and 3
    attackers would take more than 7 min: it would break GUE-10.
  - `consolidation_s` 120: it is the floor of the recapture (none before 146 s from when they leave) and does what the §0 decision asks
    (no immediate recapture). The bots give no reason to move it: there is no target holding time, and how long an owner
    holds out will be told by people.
  - `captain_respawn_s` 300 and `guard_respawn_s` 180: from the realm captain's fall to the capture it is 16 to 114 s, never 300 (it
    does not respawn); 2 to 4 guards die per battle and their respawn weighs on no capture.
  - `capture_s` 30: 15.0–18.5 s capturing (15 s with four or more, as 1.3 wants).
  - `under_attack_s`, `gate_repair_after_s` and `reset_to_neutral_s` do not intervene (the gate is repaired on capture and no battle
    reaches the 30 min cycle).
  - They remain provisional (§0), like the realm captain at 7500 (package B), until tested with people (MUN-10, MUN-11, GUE-11 and
    "Pendiente de probar mañana con ventana" (Pending: to test tomorrow with a window) in the report).
- **For the tests with people**: the gate does not protect the consolidation (in four out of five recaptures it falls 12–22 s after the first
  hit, before the garrison spawns). If you want it to protect it, the lever is not its health (it would break GUE-10) but a rule, for
  example that it cannot be damaged while consolidating: that is code and another element, not GUE-17.

**F6b review** (adversarial review of the F6b diff, with refutation; each fix carries a test that fails without it):

- **An attacker inside the fort no longer "assaults" the closed gate.** If the gate was repaired with attackers inside (after
  `gate_repair_after_s` without hits, or on capture, with the previous owner's walkway guards still up), `_siege_input`
  chose `ASSAULT` from inside too, and with GUE-44's formation the bot went to the slot outside the gate and hit facing the
  courtyard (with 1 bot, half the rate of without formation; the walkway guard, hitting the air). Leaving the circle already happened in F6a.
  Now, inside the enclosure or on the walkway, it carries on with the walkway and the circle: the capture does not need the gate.
  `test_bot_brain_siege` (gate repaired with the attacker in the circle, with and without formation) and `test_bot_brain_walkway` (the walkway guard
  whose realm loses the fort goes down to the circle).
- **The chase measures consecutive chases of the same target.** The reference (`_siege_chase_ref_*`) was not renewed while it fought
  at 3 m or less nor on changing target, and a trip beyond 3 m (a backward dodge) 180 ticks after the start blocked the
  chase for 600 ticks: in a duel between two bots, 10 % of the time without chasing an enemy at 3–12 m. Now reaching fight distance
  resets it, and so does a new target (from defender to enemy or the reverse, or a jump of more than 5 m). `test_bot_brain_siege`
  (the 4.5 m dodge at tick 150; the fleeing NPC that dies with a player 9 m away) and the usual one, which drops the chase without
  progress, stays the same.
- **GUE-43: filler sets the slot aside and the fake leaves when the person enters the world** (rule in section 7, *Slots*). With the
  withdrawal on HELLO arrival, a HELLO followed by a disconnect, in a loop and without limit, withdrew the oldest fake (DESPAWN to
  everyone; in some counts, from the opposing side) and created another at its camp (SPAWN to everyone), about 7 laps per second; and the
  restoration, without counting the one loading, left the sides at 3 against 1. `FillerKeeper.reserve_seat`, `release_seat` and
  `reserved_count`; `ZoneServer` counts reserved slots as occupied (`_occupied_seats`, also in `add_fake_player`).
  `test_realm_balance` (the loop and the two HELLOs), `test_zone_server_net` (the loop with ENet, five laps without additions or removals for
  anyone already there, and the two HELLOs, one per realm at the end) and `test_server_main`.
- **The client's bots only dodge the blows of whoever can damage them**, like the server's fakes (8.3, F6b, package B,
  *Clients*). `test_bot_threat_sight` (the rule, `is_hostile_view` and a `SwarmBot` with a notice from a guard of its realm) and
  `test_siege_clients` (the `--bot` with a notice from each realm).
- **`--bot` wiring tests**: `test_bot_ally_sight` (`--bot`'s ally counter: its realm, alive, drawn, within the radius,
  no NPCs) and `test_siege_clients`, which checks that the `--bot` and the `SwarmBot`s carry their notices and their defender finder.
- **The 64 against 64 load was measured with 118 players.** `load_test.gd` closed the swarm by its local ticks (real time),
  but the 128-player server runs slower: the 10 real bots left at tick 8390 of 10,850, and the report's percentiles (the
  last 2048 ticks) were of 118 players with no client (without building snapshots). Now the swarm closes when the
  server reaches its exit tick (`--quit-at-server-tick`, with `--quit-after-ticks` as a bound) and the summary says how many players
  there were in that stretch and in the window's marks, and warns if they are not the peak's (`LoadTestSummary.presence`). Repeated (table
  above, 2nd): 17.2 / 24.2 / 30.0 / 72.3 ms with 90 % of the stretch with the 128. The 32 against 32 ones barely change (the bots left in
  the last ~600 ticks). F6a's 64 against 64 had the same defect (8.3, F6a).
- **Documentation**: the account of the load's NPCs (11 → 7 → 6, not 11 → 6) and "the 9 war NPCs" instead of "the fort's"; the
  figures of `test_siege_npcs`; what the distribution by seeds guarantees (`slot_for_seed`, `is_walkway_seed`; the tests now check it
  over thousands of bases); and that the 20-per-side measurements are with server fakes (section 7, GUE-46).
- **Measured again with the final code** (`siege_battle.gd --npcs --per-side=20 --minutes=28 --battle-log`, the five seeds; two
  at a time, with another suite running: 65 to 153 s of wall clock per battle). They change because of the two brain fixes: mostly the
  chase, which intervenes in every fight; the gate repaired with attackers inside can only do so with seed 2000, the only one in
  which the gate is repaired during the recapture:

| Seed | Neutral: Ford Captain / capture | Recapture: gate broken / realm captain / capture | Player deaths (on the walkway) | NPC deaths |
|---|---|---|---|---|
| 1000 | 61.7 / 76.7 s | 37.4 / 141.6 / **202.4 s** | 65 (2) | 10 |
| 2000 | 67.5 / 82.5 s | 37.7 / 312.1 / **399.8 s** (the gate falls 2 times) | 136 (3) | 12 |
| 3000 | 60.2 / 75.2 s | 39.5 / 135.6 / **151.4 s** | 56 (1) | 10 |
| 4000 | 63.7 / 78.7 s | 36.6 / 133.8 / **152.2 s** | 54 (2) | 10 |
| 5000 | 61.8 / 76.8 s | 37.4 / 129.2 / **144.3 s** | 39 (2) | 10 |

  Recapture from 2.4 to 6.7 min, **median 152.2 s (2.5 min; before 160.2)**; capture of the neutral at 75–83 s (before 80–87), with the
  Ford Captain 1.5 to 10.5 s earlier (probably because they no longer stop chasing it when it steps aside for a moment). Deaths on the walkway continue in
  all five battles (10, all Solmarch's). Seed 2000 moves to the slow regime (before 146.3 s) and the other four improve: the battle
  is still chaotic (risk in §9). `vado_gris.tres` still does not change: no recapture before 144 s, and the consolidation (120 s)
  is still the floor.

**What remains after F6b** (F6b is done):

- GUE-15: having a person play against the bots (the real client against `--bots` with the NPCs).
- MUN-10 and MUN-11: their criteria with people (the Hollow in 60–90 s with 2–3; the Captain in 60–120 s with 3–5), and with them the realm
  captain at 7500 and the data in `vado_gris.tres`, which remain provisional.
- The p99 < 8 ms with 64 players (GUE-16 leaves it measured and not met): it is `simulate()`, lever 6 of networking.md 14 (TEC-35).
- A long battle with only `SwarmBot`s over ENet, with the NPCs and the walkway: the same brain and the same data are tested without network and
  with the server's fakes, and in the load the 10 real bots fight the NPCs, but there is no whole battle with only them (backlog
  GUE-46; it does not block GUE-15, whose criterion has been read with the server's fakes since F6a).
- The walkway with ranged weapons (CMB-23) and having the guards come down to dispute the circle. The bow already shoots from the
  walkway (abilities integration review, below); measuring its role in a battle remains in GUE-47.
- The recapture still depends on the seed (risk in §9): any adjustment is measured with five seeds or more.

**Abilities integration on top of F6b** (the abilities phase 4, H1a–H5, merged on top of F6b;
[abilities.md 11.9](abilities.md#119-h5--integration)). The two branches came from the same base and touched each other in the bots'
brain, the zone server and the load. How they fit together:

- **The siege bots fight with the kit** in step 1 of their plan, as H5 asked (abilities by their role, weapon swap,
  potions, bow with lead aiming and finishing of knocked-down players), losing nothing from F6b: telegraphed blows, defenders first,
  chases, gathering, formation, walkway and enclosure. They do not revive anyone (they follow their plan) and the gate is hit as in phase 3.
  The server's siege fakes receive at once the F6b senses (`_find_threats`, the defender finder,
  `_count_allies`) and the kit's (combat state, health, `BotTarget` and knocked-down allies); the client's `--bot`s, those of
  `ClientBotBrains._make_siege` plus `give_kit_senses`.
- **The kit's target is the fight's**: the defender NPC or the enemy. The defender finder also returns a `BotTarget`
  (`ZoneServer._find_enemy_target` with `npcs_only`, `BotEnemySight.find_target` with `war_npcs_only`) and the bow aims at the defender with
  its velocity; before the merge the kit would have aimed at `set_enemy_finder`'s enemy even if it was fighting the defender.
- **The archer does not chase**: with the bow in hand all of `SIEGE_FIGHT_RANGE` (12 m) is shooting distance (it holds 9 to 26 m), so
  the rule of dropping a chase that does not get it closer does not apply to it; with the sword, as before. (The integration review,
  below, completes it: without a line of fire it does not shoot, the bow reaches 20 m and finishing does carry the rule.)
- **The walkway with the kit**: the archer does not move on it (neither sideways nor to keep distance) and does not dodge, and nobody uses on
  it the abilities that advance in a straight line (the charge, which advances 6 m and pushes, and the back jump). Fighting on the walkway
  the bot looks along its axis toward the target (also without the kit), so approaching, the stepping of blows and the backward dodge go
  along the axis (the integration review, below, changes this: looking along the axis, the one next to it ended up outside the sword's
  sector; now it looks at the target and what moves goes along the axis). `test_siege_zone` (the fight on the walkway) uncovered it: with the kit, the
  guard's charge took both out to the courtyard and, without it, in long fights (the wall, the potions) a "backward" dodge with the
  other almost beside, perpendicular to the axis, threw the attacker off; the death came out in the courtyard. F6b's rule ("no
  dodging sideways") assumed the target was in front, along the axis.
- **A knocked-down player does not count as an ally** in the gathering or when fighting at the fort (`_rebuild_ally_cache` uses `is_alive`). It
  was said here that this was what the client already saw, "for whom their drawn health is 0": it was not (a knocked-down player publishes their knocked-down health,
  which is never 0), and `--bot` and `--bots` did count them. The integration review makes the client match (below).
- **The closed gate cuts blows in both directions**: the two branches had made the same fix
  (`HitShapes.is_ray_clear` with `hit_from_inside`); one remains, with the explanation of both.
- **The tick order** in `ZoneServer`'s header carries the steps of both (§1.7 and abilities.md 4.1): the fakes think
  right before their simulation with their state after `s − 1`, and TELEGRAPHs go out at the end of the combat step, not in the NPC one.
- **Capacity**: the kit lowered the measured limit per battle to 40 (in the melee with half the shooters, networking.md 14) and the
  Vado Gris server has that capacity by default (`Zones.MAX_PLAYERS`). F6b's sieges were measured without the kit, with 32 against 32 and 64
  against 64. For the fort with the kit, 40 (20 against 20) was **an estimate**, by the same reckoning as the melee and unmeasured:
  the measurement proposed here (`load_test.gd --siege --npcs`) carried no archers (the siege fakes come out with the default
  template and the `SwarmBot`s have no kit). Measured in the integration review, with and without half the shooters (below).
  F6b tools and tests that carry more than 40 players request their capacity explicitly: `load_test.gd` launches the
  server with `--max-players` (`server_max_players`, the players plus 8; `test_load_test` checks that each scenario of the
  batteries fits) and `SiegeRunner` (`siege_battle.gd` and the siege tests) sets `ServerConfig.max_players`. Note in
  [networking.md 14](networking.md#14-bandwidth-and-cpu-budget).
- **Tests**: `test_bot_brain_siege_kit` (new, 7: the kit against the defender, the bow that aims at the defender ahead of it, the
  archer that does not stop shooting and the sword that does drop the chase, the walkway with no archer side steps, looking along the
  axis and with no charges, reviving no one, deterministic; each fix checked by undoing it) and `test_load_test` (+1, the capacity).
  F6b's siege tests pass (`test_bot_brain_siege`, `test_bot_brain_rally`, `test_bot_brain_walkway`, `test_siege_zone`,
  `test_siege_npcs`, `test_siege_clients`) and the kit's (`test_bot_brain_kit` and those of abilities, projectiles and knocked-down state).

**Abilities integration review** (adversarial review of the integration, with probes in the real Vado Gris; each
fix carries a test that fails without it):

- **The bow only shoots if the arrow arrives.** The siege shooters (the `marksman` template; `siege_battle.gd` and the siege tests
  go with the squire's and did not see it) shot at the wood: `_can_reach` is the melee rule (same level and, with the
  gate closed *for its realm*, the same side) and, with the bow in hand, nothing made it drop a target that could not be reached. The
  owner saw as reachable those outside their closed gate (it does not block them), but the gate's sight body stops
  arrows in both directions and its arrow does not damage its own gate (probe: 70 of 70 arrows at it in 30 s, while four squires
  brought it down to 3373 of 9000); with
  the gate broken, an attacker shot at those behind the palisade (52 of 80 arrows to the world; two of four without entering in 30 s).
  Now the bow fights whoever it has **in range**: what it knows about the fort (the whole gate cuts the shot between inside and outside the
  enclosure for all realms, the owner too; broken, one only shoots from one side to the other through the doorway, `SIEGE_BOW_GAP_HALF_WIDTH`; from the
  walkway or toward it the line decides) and the **line of fire** of whoever carries it (`BotBrain.set_line_of_sight`: the server and
  `--bot`, with `BotBrain.bow_sight_clear` in their world). The line is two rays to the target's center: the shoulder camera's, which
  is the one that chooses the aimed point (`AimRay.aim_point`), and the muzzle's. With only the muzzle's, from the doorway and sideways, the shoulder
  sight hit the jamb and the arrow went to the jamb (5 of 21 to the world; with both, 0 of 13). It is queried once per target
  search (every 4 ticks). Without a shot it does not fight with the bow: it follows its plan (or, very close, draws the sword). Going to finish a
  knocked-down player is approaching and carries F6b's chase rule: before, with the bow in hand, it stayed pushing against the
  palisade until the knocked-down player bled out. The rule the review proposed of counting shots without a HIT is not needed with the
  line of fire (and the brain does not learn of HITs): it is noted in the risk in §9.
- **Bow distances.** With the 12 m of the melee fight (`SIEGE_FIGHT_RANGE`) the switch to the bow, which asks for more than 11 m,
  almost never arrived, the archer held 9 to 12 m and the one who drew the sword did not return to the bow. Now the bow shoots up to
  `SIEGE_BOW_FIGHT_RANGE` (20 m) and, with the sword in hand and the bow on the back, it draws it for whoever is in range and far (more than
  11 m) or for whoever the sword cannot reach (another level, the palisade in between), without approaching while drawing it. **GUE-45's level filter
  is melee only**: the walkway guard with a bow shoots into the courtyard (and outside, if the line passes above the
  parapet: the ray decides) and the courtyard one, at the walkway. **The gate is hit with the sword**: by arrow, four shooters
  took 1880 off it in 30 s (138 arrows, all at it) and four squires, 4986; now the shooter draws the sword at the start of the
  assault and the four take 5415 off it, with no arrows. The pure archer of the load tests (`kit_ranged_only`) does not draw it.
- **On the walkway it looks at the target and moves along the axis.** The integration made any bot fighting on it look along the axis,
  also without the kit, and the sword's sector (100°) did not reach whoever was stuck sideways (0.9 or 1.2 m to the side and almost nothing
  along: it looked at them at 1.35–1.57 rad): a person next to a walkway guard was untouchable for it. In F6b it looked at them and
  hit them. Now it looks at the target and what it moves (approaching and the backward dodge) goes along the axis: the movement is converted to the frame of its
  gaze (`_siege_move_along`), because the simulation moves and dodges relative to the camera's yaw. The charge and the back jump
  remain unused on the walkway; `test_bot_brain_walkway` counts sideways dodges by where they go in the world.
- **A knocked-down player does not count in the gathering, on the client either.** `Combatant.publish` gives a knocked-down player their knocked-down health, which
  is never 0, and `BotAllySight` (`--bot`) and `SwarmBot` (`--bots`) only looked at health: they counted the knocked-down for the
  gathering group and for "the 3 of their own fighting at the fort", and left the camp to help them; the server's fakes did not (what
  was said in the integration, that the client already saw them with health 0, was false). Now they also look at the drawn action, DOWNED
  (`SwarmBot.is_standing_record`: byte 19 of the record).
- **GUE-43: the filler that yields its place does not die.** `FillerKeeper._retire_oldest_of` removed the oldest of the realm without looking at its
  state, and if it was knocked down `_remove_player` killed it by bleed-out with a KILL for whoever knocked it down: a person entering the
  match added a death to their side and a kill to the other, on the scoreboard and in the battle log, and could cut a revive or a
  finish. Now the oldest calm one leaves (`calm_check`: neither knocked down nor reviving or finishing; if there is none, the oldest) and
  its removal is only the DESPAWN (`ZoneServer.retire_filler`; rule in section 7, *Filler*). The other removals of a knocked-down player (leaving,
  disconnecting, `--fake-churn`) are still a death.
- **Capacity and hand-run sessions.** With the Vado Gris capacity of 40, the guide in `history/2026-10-night-report.md` "Con bots de asedio contra tu
  cliente" (With siege bots against your client) (40 fakes, 20 bots and two people) no longer fit: the swarm's 20 and the people received FULL. It now carries
  `--max-players=64`. **Any hand-run session in the Vado Gris with more than 40 players (fakes, bots and people) needs
  `--max-players`.**
- **The fort's 40 was an estimate** written as data (networking.md 14 said "estimate" and the integration, "the limit at the fort
  is 40"), and the proposed measurement carried no archers. Measured (below), with the default template and with half shooters.
- **Tests**: `test_bot_brain_siege_kit` (nine new and one rewritten: looks at the enemy and moves along the axis, the sword reaches the
  one at the side, neither through the closed gate nor through its own, through the doorway, the line of fire and one query per search, the bow
  at 20 m, drawing the bow with the sword in hand, shooting at another level, the chase when going to finish and the sword for the gate),
  `test_siege_archers` (new, three with the Vado Gris physics: the review's probes), `test_bot_brain_walkway` (sideways dodges,
  in the world), `test_bot_ally_sight` and `test_bot_swarm` (+1 each, the knocked-down ally), `test_realm_balance` (+1, who
  is withdrawn) and `test_downed` (+1, the knocked-down filler leaves with no DEATH or KILL). Each fails with the earlier code.

**Measured again with the integration and its review** (the siege bots with the kit; play times, deterministic):
`siege_battle.gd --npcs --per-side=20 --minutes=28 --seed=N --battle-log`, three seeds, with the default template (the squire,
like all of F6b's; 81 to 144 s of wall clock, all three at once):

| Seed | Neutral: gate broken / Ford Captain / capture | Recapture: gate broken / realm captain / capture | Player deaths (on the walkway) | NPC deaths |
|---|---|---|---|---|
| 1000 | 36.5 / 67.4 / 82.4 s | 39.4 / 134.4 / **156.1 s** | 56 (0) | 10 |
| 2000 | 37.3 / 65.7 / 80.7 s | 40.7 / 131.7 / **146.9 s** | 33 (3) | 10 |
| 3000 | 37.3 / 65.0 / 80.0 s | 44.6 / 204.7 / **295.6 s** | 91 (3) | 9 |

- Capture of the neutral at 80.0–82.4 s (with F6b's final code, 75.2–82.5 s with these seeds) and recapture in 156.1 / 146.9 /
  295.6 s (before 202.4 / 399.8 / 151.4): from 2.4 to 4.9 min, within the cycle and with the consolidation (120 s) as the floor. The two
  slowest from before go faster and 3000 slower (91 s from the captain's fall to the capture, with the circle disputed): the
  battle is still chaotic (§9) and three seeds do not say whether the kit speeds it up. Deaths on the walkway in two of three (6, all
  Solmarch's). `vado_gris.tres` does not change.

**The 20 against 20 load with the kit and the NPCs** (GUE-16, a measurement the integration left pending): `load_test.gd --scenario=siege
--fakes=30 --bots=10 --seconds=120 --npcs`, 40 players (the Vado Gris capacity), with the default template and again with
half shooters (`--fake-loadout=marksman:50`; the `SwarmBot`s have no kit, so the arrows are from 15 of the 30 fakes). The
same 4-core machine, with no other suite running (average load 0.5 to 0.9); for reference, in the same session the 40 melee
(`--scenario=brawl --fakes=30 --bots=10 --seconds=60`) gives 7.4 / 11.3 / 13.2 / 22.7 ms, as in the H5 review (12.4 p99).
Tick in ms of the last 34 s stretch; "window", the 10 s marks of the measurement window; sections in ms, p50 (p99):

| 20 against 20 siege with NPCs | Tick p50 / p95 / p99 / max | Window p50 / p99 (the worst) | `sim` | `combat` | `combat_projectiles` | `npc_brains` | Downstream per client | Substituted (window) | Arrows |
|---|---|---|---|---|---|---|---|---|---|
| Default template (the squire) | 8.2 / 12.8 / **16.2** / 32.6 | 8.9 / 17.1 (19.1) | 4.9 (9.9) | 0.91 (3.0) | 0 | 0.20 (0.47) | 34.4 KB/s | 0.00 % | none |
| Half shooters | 9.6 / 14.3 / **16.9** / 38.7 | 9.6 / 17.2 (21.0) | 5.8 (10.5) | 1.04 (3.2) | 0.26 (**1.01**) | 0.40 (0.94) | 36.1 KB/s | 0.00 % | 328: 229 at characters, 92 at the world, 3 blocked; peak of 11 |

- **The 20 against 20 at the fort is on the edge of the phase 4 criterion** (tick p99 ≤ 16.7 ms and `combat_projectiles` ≤ 1 ms,
  abilities.md §7.3): with the default template it meets it narrowly (16.2 ms), and with half shooters it misses narrowly (16.9 and
  1.01 ms); the window marks give 17.1–17.2 ms p99 in both. It is more expensive than the 40 melee in open field (13.2 ms in
  the same session): `simulate()` rises from 4.3 to 4.9–5.8 ms median (because of the fort's slopes and esplanade, ~70–74 µs per
  character) and the NPCs add their brains (0.2–0.4 ms). No inputs substituted in the window and no rewind rejected; downstream of
  34–36 KB/s per client. **The per-battle limit at the fort with the kit stays at 40 (20 against 20), measured and with no margin**: the
  capacity is not lowered for 0.2 ms from one pass (the difference between two identical passes is ~1 ms, package E), and the lever to gain margin is
  the usual one, `simulate()` (TEC-35, lever 6 of networking.md 14).
- **What happens in the window** (the two realms against the neutral fort). With the squire, the gate falls 16.9 s after the first hit,
  the Ford Captain falls and a capture begins that does not finish; 79 player deaths and 5 NPC ones. With half shooters the gate does not
  get to fall: the two sides fight each other on the esplanade (the bow shoots up to 20 m) and no NPC dies; 96 player deaths.
  A probe with `SiegeRunner` (15 fakes per realm, half shooters, NPCs, no `SwarmBot`) breaks the gate at 69 s (97 s with the
  integration's brain before the review; 55 s without shooters) but does not capture in 4 min either: the battle with shooters is
  unmeasured (GUE-47). The arrows to the world in a fight like that are misses: in that probe, of 308, most at the ground and the slopes
  and about 60 at the outside face of the palisade and at the gate, in front of which the fight takes place; with the line of fire none shoots at
  whoever is behind them (in the palisade and gate probes, 0 to the world).

**Phase 4 review ("war" lens)** (adversarial review of phase 4, with refutation; each fix carries a test that fails
without it):

- **Automatic respawn goes out in a wave, and bots request theirs.** `_process_respawns` did the automatic one at exactly
  `death_tick + auto_respawn` (1800), without looking at `respawn_wave_ticks`: with waves, whoever did not request the respawn left outside
  them (death at tick 101: respawn at 1901). And nobody besides the HUD button and the `SwarmBot` requested it: the server's fakes
  (`--fake-players`, `SiegeRunner` and `siege_battle.gd`, `load_test`, GUE-42's filler) and the `--bot` always respawned
  by the automatic one, at 30 s, each on their own. **All the 20-per-side measurements of F6a, F6b and the integration were made
  this way**, not with the GUE-14 waves that a person pressing the button has (10–20 s). Now:
  - `CombatTiming.auto_respawn_tick_for(death)`: the first multiple of the wave ≥ death + 30 s (without waves, death + 30 s), which
    `Combatant.mark_dead` stores in `auto_respawn_tick` next to `respawn_tick`; `_process_respawns` uses that tick. With waves nobody
    respawns outside one, as the `respawn_wave_ticks` contract says.
  - The server's fakes request the respawn on death: `Combatant.requests_respawn_on_death` (set by `add_fake_player`) leaves
    `pending_respawn_point = 0` in `mark_dead`, so they respawn at `respawn_tick` (their wave) and at the same place as the automatic one (point
    0 or, if invalid for their realm, the first valid camp). Outside zones with a fortress, at 10 s instead of 30, like
    a `SwarmBot`.
  - The `--bot` (`OnlineMain`, also without `--quit-after-ticks`) sends RESPAWN_REQUEST (point 0) as soon as the estimated server tick
    reaches the `respawn_tick` of the extra block, and repeats it every second (`BOT_RESPAWN_RETRY_TICKS`) while still dead.
  - Tests: `test_fortress_server` (whoever does not request respawns only in a wave; a fake respawns in its first wave),
    `test_combatant` (the counts of the two waves and the request on death) and `test_online_main` (the dead `--bot` respawns when it asks,
    with no server warnings). `test_combat_server` and `test_loadout_server`, which measure the automatic one or request by hand, turn off the fake's
    request.
- **Only the repair of the broken gate is postponed.** `_repair_if_due` postponed the 5 min repair if someone overlapped the doorway
  and, from then on, repaired as soon as it was free **without looking at the deadline again**; `on_structure_hit` did not cancel the postponement.
  The owner crosses their own closed gate and inside the box they are not hit: a defender standing still in the doorway when the
  deadline expired was enough for attackers to bring the gate down almost to 0 and, when he left, for it to come back whole on the next tick (or for a
  freshly broken gate to close without waiting its 5 min). `_hold_repair_if_blocked` did the same after a capture or a reset with the gate whole.
  Postponing only makes sense if repairing changes the collision, that is, with the gate broken (which no longer takes damage, so what is pending
  does not go stale): now the whole one is repaired on the spot, and a hit that removes health cancels what is pending. `test_fortress_controller`
  (three: deadline expired with someone in the doorway and a new hit; breakage after the deadline expired; owner change with the damaged whole
  gate and someone in the doorway).
- **The Ford Captain's reinforcements, once per life.** `_arrive_home` re-armed the call every time the Captain returned
  regenerated, and the reinforcements (`_extras`) only left on death or with `defenders_retired`: each failed assault that brought it below half
  added two more Hollow (2 → 4 → 6 → 8 in three assaults, and the full respawn left them at 8), and since the reinforcements are in its
  alert group, they counted for the "only if any remain". Now the call is once per Captain's life; the full respawn (the
  Hollow "return whole") withdraws any remaining reinforcements and re-arms the call (`HfsmBrain.rearm_reinforcements`); and
  `_spawn_reinforcements` creates no more than are missing for `reinforcement_count` alive per fortress (those of a previous Captain
  count). `test_npc_system` (two: three assaults and the full respawn; a new Captain with the previous one's reinforcements alive).

**Measured again with the three fixes** (`siege_battle.gd --npcs --per-side=20 --minutes=28 --seed=N --battle-log`, the five GUE-44
seeds; deterministic: the earlier code exactly repeats the figures in the integration table with seed 1000; two
at a time, 84 to 144 s of wall clock per battle). "Before" is the code prior to the review: seeds 1000, 4000 and 5000 measured again
in this review and 2000 and 3000 from the integration table. Recapture, from when Solmarch leaves:

| Seed | Before: recapture (deaths S / V) | Now: gate broken / realm captain / **recapture** | Now: player deaths S / V (walkway) | Solmarch group departures |
|---|---|---|---|---|
| 1000 | 156.1 s (31 / 25) | 39.4 / 135.3 / **158.8 s** | 23 / 30 (2) | 3 (before 4) |
| 2000 | 146.9 s (33 total) | 40.7 / 126.8 / **162.8 s** | 15 / 42 (3) | 6 |
| 3000 | 295.6 s (91 total) | 44.6 / 134.2 / **161.8 s** | 14 / 44 (3) | 6 |
| 4000 | 303.7 s (72 / 35) | 41.3 / 138.5 / **156.6 s** | 27 / 25 (1) | 4 (before 14) |
| 5000 | 157.4 s (3 / 32) | 44.6 / 134.0 / **286.9 s** | 47 / 72 (2) | 14 (before 3) |

- **Recapture from 2.6 to 4.8 min, median 161.8 s (2.7 min; before 157.4 with the same five seeds)**, with four of five in the
  fast regime (before three): the one the first group wins, waiting for the garrison during the consolidation (120 s, the floor). The
  capture of the neutral does not change (80.0–82.4 s, with no Vardheim deaths: nobody respawns in that phase). Player deaths 53, 57, 58,
  52 and 119 (before 56, 33, 91, 107 and 35). The battle is still chaotic (§9): with the real respawn two seeds go from slow to
  fast and one from fast to slow.
- The conclusions of GUE-44 and package B were taken with the earlier respawn. The comparison that decided GUE-44 repeated, without
  gathering or formation (`--rally=0`) and with the new respawn: 413.4 / 220.5 / 234.5 / 142.6 / 213.0 s (**median 220.5 s**; 112,
  85, 92, 41 and 91 player deaths). The gathering still wins in four of five seeds (all but 4000), so GUE-44's decision
  stands. The other variants of package C's table (groups of 12 and 20, gathering only at the start) have not been
  repeated; now those who respawn in the same wave really do leave together, and the gathering clock, 5 s after a wave,
  does what it said.
- `vado_gris.tres` and the realm captain (7500) do not change: no recapture before 156 s and all within the 30 min cycle.
- **The 20 against 20 load with the kit and the NPCs, again** (it also uses server fakes, which now return to the fight in their
  wave and not at 30 s): `load_test.gd --scenario=siege --fakes=30 --bots=10 --seconds=120 --npcs`, default template, the earlier
  code and the current one back to back in the same session and with no other suites running (average load 0.6 to 0.9). Last 34 s stretch,
  p50 / p95 / p99 / max: **8.2 / 12.1 / 14.6 / 32.7 ms before and 8.7 / 13.4 / 17.5 / 29.9 ms now**; window marks, p50 and p99:
  8.6 and 17.6 ms (the worst, 19.0) before and 8.9 and 16.5 ms (19.8) now; 89 and 68 player deaths, no input substituted in the
  window, 34–35 KB/s per client. Each exceeds the criterion (16.7 ms) in one of its two measurements and not in the other: with one pass of
  each code the difference is within noise (1–3 ms between identical passes), and **the limit of 40 per battle at the fort is still on
  the edge and with no margin**, now with the real respawn. The 40 melee (`--scenario=brawl --fakes=30 --bots=10 --seconds=60`)
  has almost no deaths in its minute (15, almost all finished off) and gives the same: 14.5 and 14.6 ms of tick p99 and 1.28 and 1.01 ms of
  `combat_projectiles` (both above the millisecond in this pass; in the H5 review, 0.90).

**Phase 4 review ("cheats" lens)** (same review; each fix carries a test that fails without it):

- **An NPC shot from beyond its loss radius goes after the archer.** In COMBAT, `_choose_target` only
  looked within `_lose_radius` (28 m the Hollow, 30 the guard, 34 the captains; the arrow reaches about 90 m): with the
  archer farther there was no target, the NPC stood still and after 3 s (`LOST_TARGET_TICKS`) went back to IDLE at its
  post **fully healed** (`_arrive_home`), and the next arrow sent it back to COMBAT. Measured before the fix: a
  Hollow with 6 archers at 33 m received 173 arrows in 20 s without moving a centimeter (6 full heals, 0 damage to the
  archers); with 10, it died in 3.6 s without moving; the realm guard and the Captain, the same (the Captain, with 30,000 health and a
  heal every 3.2 s, did not drop below 28,200). Two degenerate outcomes: below about 830 ranged DPS it could not be
  killed and above it it died without reacting. Now (`HfsmBrain._reach_for_attacker`) whoever hit it in the last second
  (`_recent_attacker`) from beyond the radius raises it to their distance plus 4 m (`ATTACKER_RADIUS_MARGIN`), like a
  companion's alert, on entering combat and on every COMBAT thought with no target; it chases them, and if it does not reach them the leash or
  getting stuck sends it to immune return, as against someone fleeing. `test_hfsm_brain` (two: three archers at 33 m, whom it reaches
  and damages without returning healed to its post; three at 55 m, beyond the leash, which make it chase them up to it
  and return immune).
- **Each NPC's state log, bounded.** `_state_log` added an entry per transition during the NPC's whole life and only tests read it:
  the two Hollow patrolling the neutral fort add about 10.5 per minute each (of the order of 1 MB per day per zone while nobody
  kills them). Now it keeps between `STATE_LOG_MAX` (256) and double: on reaching double it keeps the last 256 at once (without copying on each
  transition). `test_hfsm_brain` (2560 transitions).
- The Captain's reinforcements that accumulated with each failed assault (another finding of this lens) were already fixed by the
  "war" lens (above: one call per life and never more than two alive per fortress).
- The rewind that rejected an honest player's hits and arrows with a hitch or low FPS (the intermittent failure of the
  "rate" cheater) is in networking.md §10.
- **Measured**: the siege battle with NPCs (`siege_battle.gd --npcs --per-side=20 --minutes=28`) repeats to the tenth of a second the
  figures of the "war" lens table with seeds 1000 (39.4 / 135.3 / **158.8 s**, 23 / 30 deaths, 2 on the walkway,
  3 group departures) and 5000 (44.6 / 134.0 / **286.9 s**, 47 / 72, 2, 14 departures): the siege bots fight within the NPCs'
  loss radius and the fix changes nothing for them.

---

## 9. Risks

- **NPC cost**: 5–10 more NPCs with `simulate()` and their brain. Measured in F4: about 50 to 85 µs per NPC per tick (8.3); with 10 to 20
  NPCs it is 0.5 to 1.7 ms of the 16.7 ms tick. F6a measured the siege without NPCs (8.3); F6b repeated the measurement with those of F4 (8.3, package E):
  with the Vado Gris's 9 war NPCs alive (the 5 of the fort and the 4 camp Guardians), ~1 ms of the tick in a 32
  against 32 siege (brains with a p99 of 0.8–1.1 ms while the Hollow live, spawners 0.06 ms and their `simulate()` ~0.55 ms), of the order of
  the difference between two identical passes. A castle with more NPCs (F7) is measured again.
- **Zone generator** (resolved in F0): `vado_gris.tscn` comes from a script and the assets it
  needs are in the repo, so it is regenerated (not hand-edited); see 8.3.
- **Art**: the final Hollow, Captain, tabards, banners and gate effects are the
  user's (ART-15, ART-16, ART-17); for now, provisional.
- **Chaotic bot battles** (F6b, GUE-44): the 20 against 20 recapture varies a lot with the seed (from 2.4 to 12.8 min with
  GUE-44) and with small changes to the brain. A fort or bot adjustment is measured with five seeds or more, never with one. Bots
  pile up because characters do not collide with each other: any new brain that leads many to the same point must spread them
  out (the formation in 8.3, F6b, package C).
- **Heights and walkway** (F6b, GUE-45): inside the enclosure the bots only distinguish two levels (the courtyard and the walkway, more than
  1.6 m apart) and climb by a route of points from the data, not by the mesh on each query. A fort or castle with another
  geometry (F7) needs its walkway data, and with more levels, another rule. With melee weapons the walkway guards
  defend nothing (they neither reach the gate nor count in the circle). With phase 4's bow (CMB-23) the guard shoots from it at
  whoever is in range, also those below (abilities integration review, 8.3), but bot battles are
  measured with the squire template: the walkway's role with bows, unmeasured, remains in GUE-47 and is reviewed with people.
- **Bots' line of fire** (abilities integration review): the siege bots' bow shoots with the two straight rays that decide a server
  shot (the shoulder sight and the muzzle); the arrow's drop does not count. A parapet or a branch at mid-height of the bow's arc could
  stop it all the same: the broken-gate probe gave 0 arrows to the world out of 13, and if it were needed,
  the give-up rule would be counting shots without a HIT.

---

## 10. Combat expansion (another short design)

CMB-19 (abilities with cooldown), CMB-21 (sword and shield abilities), CMB-20 (status
effects), CMB-22/23 (projectiles with rewind and bow), CMB-24 (weapon swap), CMB-28
(knocked down), UI-11 (action bar) and UI-45 (status icons). It is designed in
`docs/abilities.md` when the fort loop works, because it touches `CombatState`.
