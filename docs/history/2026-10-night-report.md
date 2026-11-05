> Historical record: this report captures the project state as of October 29-30, 2026. It is kept as written
> (translated from the Spanish original) and is not updated; later work is tracked in `docs/backlog.md`.

# Night session report

> Note from November 1, 2026: this report describes the state as of October 29. Afterwards, all branches
> were merged into `main` (PRs 1 to 9) and the tasks listed here as pending for phase 5 were done.

Unsupervised session from October 28 to 29, 2026, **closed at the user's request** on the afternoon of the
29th. This file is on the most recent branch (`fase5-cuentas`) and on `fase4-fuerte`. The branches are
chained: `main` → `fase2-red` → `fase3-combate` → `fase4-fuerte` → `fase5-cuentas`, and nothing is merged
into `main` except the backlog. Separately, `fase4-chat-grupos` (branching off `fase4-fuerte` at a150b78)
has chat and parties **unreviewed and unmerged**.

## Status

| Work | Branch | Status |
|---|---|---|
| Backlog (`docs/backlog.md`) | `main` | Done and pushed |
| Phase 2: networking | `fase2-red` | Implemented (594 tests green, GitHub CI green); adversarial review done and its 19 findings fixed, each with its test (656 tests green) |
| Phase 3: combat | `fase3-combate` (from `fase2-red`, which is merged into it) | Design reviewed (`docs/combat.md`); K1–K5 and the audio, theme, settings, social document and export lanes integrated; adversarial review done and its 18 findings fixed with tests (1262 tests green) |
| Phase 4: fort | `fase4-fuerte` (from `fase3-combate`) | Design v2 reviewed (`docs/fortress.md`); F0 to F5 and F6a integrated (scene, pure fortress, protocol 4, fort server, NPCs, client, siege bots, realm balance, load). Full suite green with F4 and F6a (1747 tests). Ability design reviewed (`docs/abilities.md`), not implemented. F6b done on the `wip/f6b` branch (packages A to E, unmerged). Abilities (H1–H5) and the adversarial review of phase 4 are missing |
| Phase 4: chat and parties | `fase4-chat-grupos` (from `fase4-fuerte` a150b78) | SOC-03 to SOC-08 implemented (protocol 5, `ChatRouter`, chat box, `PartyManager`, party frames, social menu), with their suite; **without the adversarial review and unmerged** (the session was closed during the review) |
| Phase 5: design | `fase5-cuentas` (from `fase4-fuerte`) | `docs/platform.md` and `docs/progression.md` written and reviewed through three lenses each (45 and 41 findings); **they still need to be reconciled with each other** (each lists in its interface section what it asks of the other). No code |

## Environment (Linux)

- Godot 4.7.2-stable Linux x86_64, always with `--headless`.
- Git LFS downloaded (146 objects); Terrain3D 1.0.2 loads its Linux `.so` files.
- Starting suite: 83 tests, all passing on Linux (46.8 s). No differences from Windows.

## Backlog

- 321 items: the 320 from the designers, minus 33 duplicates, plus 27 added from the critique and 7
  that come from splitting others (UI-46, MUN-47, MUN-48, ART-42, ART-43, PRG-44 and PRG-45).
- The 90 corrections and the 205 dependency lists from the critique were applied. All cited
  dependencies exist, there are no cycles, and every item is in exactly one phase.
- The only dependency on a later phase: ART-03 (phase 2) depends on ART-13 (phase 4), which is already
  done.
- 90 decisions pending after merging the repeated ones. The contradictions the critique pointed out
  (enemy names, name length, respawn, first realm, mounts, Embers, power in Eldrun) have a single
  recommendation.

## Phase 2: progress

| Package of networking.md §17 | Contents | Status | Tests |
|---|---|---|---|
| A | `PlayerState.to_f32`/`equals_exact`, yaw in f32, `events_enabled`, `NetProtocol`, `NetMath`, `NetZones`, `EntityRecord`, `NetMessages`, `BotBrain` | Done | `test_net_messages` (42) |
| B | `NetSim`, `NetTransport` (ENet + own `SceneMultiplayer`, authentication, channels, simulator) | Done | `test_net_sim` (22, with real ENet on 127.0.0.1) |
| C1 | Server pieces: `InputQueue`, `SnapshotBuilder`, `StateHistory`, `NetEntity(Registry)`, `ServerAuth`, `RateLimiter`, `SpawnPicker`, `ServerConfig`, `ServerMetrics`... | Done | 12 test files; `test_architecture` with the server/client rules |
| D | `TickSync`, `InterpolationClock`, `ClientPrediction`, `CorrectionSmoother`, `RemoteInterpolator`, changes to `LocalPlayerController` | Done | `test_tick_sync` (17), `test_interpolation_clock` (8), `test_remote_interpolator` (16), `test_prediction` (24, two separate physics worlds) |
| C2 | `ZoneServer`, `ServerMain`, `--server`, `--fake-players`, `--report`, `--dev-lock`, `--idle-quit` | Done | `test_zone_server`, `test_zone_server_net` (15, real ENet), `test_server_main` (6, separate processes with the real zone) |
| E | `NetClient`, `RemoteWorld`, `RemotePlayerView` (with the animated humanoid), `OnlineMain` (`--connect`, `--bot`), `ClientConfig`, `NetHarness` | Done | `test_net_loopback` a, b, c, e (real ENet), `test_net_client`, `test_remote_world`, `test_online_main`, `test_net_harness` (processes) |
| Lane 2 | GUE-02 `RealmCatalog`, SOC-01 `NameRules`, TEC-03 GitHub Actions, ART-05 asset validator | Done | `test_realm_catalog`, `test_name_rules`, `test_assets` |
| F (M4–M5) | Scenario d with NetSim, `--local`, `RealmSelect`, F3/F4 overlay, security, cheating bot (5 modes), `--state-log` and `compare_state_logs`, `test_net_processes`, `BotSwarm` (`--bots`), `load_test` | Done | `test_net_loopback` d (and 24-tick cut), `test_net_processes`, `test_local_server_launcher`, `test_realm_select`, `test_net_debug_overlay`, security in `test_zone_server_net` |

**First real test in separate processes** (headless server in Vado Gris, 1800 ticks, and two
`--bot`, no NetSim): bot 1, 704 snapshots with state, 703 exact matches, 0 unexplained differences,
1 hard reset (the process stalled in the VM; TickSync recovered it); bot 2, 707/707
matches, 0 differences. Server: 0.32 % of inputs substituted, 0 warnings, 0 physics
errors. Each bot saw the other as a remote.

Incident: the container restarted in the middle of package D; its half-finished work was recovered from
its worktree and completed.

First rough measurement (C2, Linux): Vado Gris with 64 fake players, tick p50 4.4 ms, p99
7.3 ms, max 11.7 ms; about 100 µs per character (simulation + bot brain). It will be repeated with
real bots at the end of the phase.

### Phase 2 acceptance test (separate processes, no window)

Headless server in Vado Gris (4500 ticks = 75 s) and 3 `--bot` (2 from Vardheim and 1 from Solmarch,
4000 ticks each), two passes. Script: `build/real/run.sh` (not versioned; the commands are
below). State logs cross-checked with `tools/compare_state_logs.gd`: "CORRECTO" in all 6 cases, 0 ERROR in
the logs.

| Pass | Bot | Snapshots with state | Exact matches | Corrections | Unexplained diff. | Hard resets | Resyncs | TickSync adjustments |
|---|---|---|---|---|---|---|---|---|
| No NetSim | 1 | 1956 | 1956 | 0 | 0 | 0 | 0 | 9 |
| No NetSim | 2 | 1957 | 1957 | 0 | 0 | 0 | 0 | 0 |
| No NetSim | 3 | 1955 | 1954 | 0 | 0 | 1 | 0 | 7 |
| rtt=120, jitter=20, loss=5 | 1 | 1730 | 1730 | 0 | 0 | 0 | 0 | 3 |
| rtt=120, jitter=20, loss=5 | 2 | 1725 | 1725 | 0 | 0 | 0 | 0 | 20 |
| rtt=120, jitter=20, loss=5 | 3 | 1728 | 1728 | 0 | 0 | 0 | 0 | 18 |

Bot 3's hard reset happened at startup (a snapshot arrived ahead of its prediction when the third bot
joined); it left no differences. With NetSim there were 9–10 substituted inputs per bot and none
produced a difference (the substitute repeated the same input). Server: 0 physics errors, 0 warnings;
`simulate()` 74–77 µs on average with 3 players (including startup); average snapshot of 91 B with 2
remotes.

### §19 measurements (`tools/load_test.gd --matrix`, 4-core machine, 120 s per scenario)

Revised after the adversarial review (finding A4). The first figures in this report (30 s, no
delay, substituted between 0.09 % and 0.16 %) **did not measure the criterion**, which asks for 100 ms of RTT, and
the battery lacked the 128 and 256 sizes and the 120 s from §16. The battery now uses 120 s per scenario,
a scenario with `rtt=100`, the 128 and 256 fake-player ones, and also computes the substituted inputs inside
the measurement window (without startup).

| Scenario | Players | Tick p50 / p99 / max (ms) | KB/s per client | Substituted (session / window) |
|---|---|---|---|---|
| 64 clustered fakes + 2 bots | 66 | 4.9 / 8.2 / 20.0 | 35.2 | 0.07 % / 0.00 % |
| 64 clustered fakes + 10 bots | 74 | 6.2 / 9.7 / 17.2 | 35.3 | 0.03 % / 0.00 % |
| 64 clustered fakes + 50 bots | 114 | 15.3 / 26.5 / 36.5 | 34.9 | 0.05 % / 0.00 % |
| **64 clustered fakes + 10 bots, rtt=100** | 74 | 6.5 / 10.6 / 21.6 | 35.3 | **0.36 % / 0.00 %** |
| 64 scattered + 10 bots | 74 | 6.8 / 11.4 / 20.5 | 35.3 | 0.03 % / 0.00 % |
| Joins and leaves at 1/s + 10 bots | 74 | 6.7 / 10.7 / 15.4 | 35.3 | 0.08 % / 0.00 % |
| 128 clustered fakes + 10 bots | 138 | 11.3 / 19.7 / 24.2 | 35.2 | 0.03 % / 0.00 % |
| 256 clustered fakes + 10 bots | 266 | 15.9 / 24.8 / 79.7 | 25.4 | 97.3 % / 100 % |
| 256 scattered + 10 bots | 266 | 17.5 / 27.1 / 41.8 | 24.0 | 97.2 % / 100 % |

- `simulate()` per character: **42–50 µs** (the whole simulation section, ~57–66 µs per character).
- Full snapshot (57 records): 1191 B, 250–730 µs to build.
- Upload: 2.3–3.7 KB/s per client (3.7 with 100 ms of RTT).
- **Phase 2 criterion**: download (≤ 37 KB/s) **met**; substituted inputs (< 1 %) **met and now actually
  measured with 100 ms of RTT** (0.36 % of the session with 64 clustered and 10 bots; 0 inside the window; each
  bot loses about 27 inputs at startup, 19–20 late, so with 30 s it came out at 1.2 % and with 120 s at
  0.36 %); **tick p99 < 8 ms with 64 clustered players is NOT met** on this machine (8.2 ms with 66
  players, 9.7 with 74; the earlier 30 s series with exactly 64 gave 8.7–9.6 ms). The bottlenecks are
  `simulate()` in GDScript (above the 25 µs of lever 6 of networking.md §14) and `SnapshotBuilder`
  with many real clients.
- **128 and 256 players**: with 138 the median tick takes 11.3 of the 16.7 ms (p99 19.7 ms) but the
  server holds 60 ticks/s and does not substitute inputs. **With 266 the server cannot sustain real
  time** (44–47 ticks/s) and substitutes 97 % of the real clients' inputs: 256 players in an
  unoptimized GDScript process are outside what this phase promises. First rough limit of
  players per battle: about 60 on a server of this class without optimization. It is noted in networking.md §14.
- Pending observation: startup with 100 ms of RTT begins with little lead time (19–20 late inputs
  per bot in the first seconds); worth looking into.

### Adversarial review of phase 2

Three Opus reviewers (netcode against the design; robustness and security; architecture and tests) and one
verifier per lens who tried to refute each finding, almost always by reproducing it with a
script. 20 findings, 19 confirmed and 1 refuted (N4: it was an artifact of the network simulator, which
stamps incoming packets with the poll tick).

| Id | Severity | Finding |
|---|---|---|
| N1 | high | If the client gets more than 30 ticks ahead (a server stall of ~0.6 s), TOO_EARLY inputs give no margin and TickSync never recovers |
| N2 | medium | The limiters refill per server tick: after a stall of ~1.3 s all honest clients are kicked |
| N3 | medium | After the server loses ticks, the interpolation clock keeps the old maximum for 120 ticks and remotes freeze for ~1.3 s |
| N5 | low | u32 ticks stored in int32 (history, warnings, clock): 414 days of range instead of 828 |
| S1 | high | SceneMultiplayer packets that are not RAW log engine errors, skip the limiters and lengthen the tick |
| S2 | high | The per-IP cap is only applied at HELLO: one IP takes all the slots with silent connections |
| S3 | high | Every join stays forever in the player registry (~80 KB per connection cycle) |
| S4 | medium | The measured RTT is decided by the client: "faking lag" would give the maximum rewind in phase 3 |
| S5 | medium | SIGTERM/Ctrl+C kill the server without a report or orderly shutdown and leave the `--local` lock behind |
| S6 | low | A kicked player returns within one RTT with the warnings reset to zero |
| S7 | low | The connection timeout is 3.5 times the documented one |
| A1 | high | On Windows, `--local` never recognizes a server launched from another window (`OS.is_process_running` only sees own children) |
| A2 | medium | Test d measures the minimum of the TickSync window, not the margin of each snapshot (the document is corrected) |
| A3 | medium | `test_architecture` lets `pick_random`, `shuffle`, `randomize` and frame counters through |
| A4 | medium | The criterion "< 1 % substituted with 100 ms" was never measured with 100 ms (with rtt=100 it comes out at 1.2 %, mostly from startup) |
| A5 | low | The process tests do not look at the bots' logs |
| A6 | low | `test_prediction` has weak assertions ("up the ramp" passes by jumping on flat ground) |
| A7 | low | Two suites at once on the same machine clash on ports, `build/` paths and the `--local` lock |
| A8 | low | `SpawnPicker` uses `Zones` directly, against the `NetZones` boundary |

None affects normal play on a healthy network (the acceptance test came out clean), but N1, N2,
S1, S2, S3 and A1 are real failures in production or in daily use of `--local` on Windows.

**All 19 are fixed in `fase2-red`**, each with a test that failed before the fix
(656 tests green). The most relevant:

- N1: `InputQueue` records the lead time of too-early inputs as well.
- N2: the server grants the limiters credit for the ticks it lost in a stall.
- N3: the interpolation clock adopts a sustained step in the offsets within ~0.5 s.
- S1: `GuardedEnetPeer` (a `MultiplayerPeerExtension` over ENet on the server) filters foreign
  packets before `SceneMultiplayer`: no engine errors, with warnings and kicks
  (+6 % cost per packet measured). It depends on the internal format of `SceneMultiplayer`
  (documented; `test_net_sim` would detect it if it changes).
- S2: per-IP cap on connect (IPv6 by /64) and a 90-tick deadline for HELLO.
- S3: the player registry is a ring and the records release their objects when they leave.
- S4: the RTT is bounded by ENet's; `interp_delay_q` is clamped.
- S5: `--stop-file` for an orderly stop and a report rewritten every 10 s; on Linux, `--local`
  checks in `/proc/<pid>/cmdline` that the lock's pid is a server.
- S6: 30 s of cooldown after a kick. S7: real connection timeout.
- A1: on Windows, `tasklist` for foreign pids (**untested: there is no Windows here**).
- A3, A5, A6, A7, A8: stricter architecture tests, bot logs reviewed,
  stronger assertions, per-pid ports and folders, and the `NetZones` boundary.
- A4: the load battery measures the criterion with 100 ms (table above).

## Phase 3: progress

Design in [combat.md](../combat.md): reviewed through two lenses before implementing (2 blockers and
~25 important issues fixed in version 2) and with a §11 that records what was settled during implementation.

| Package | Contents | New tests |
|---|---|---|
| K1a | `CombatState` (34 B; `PlayerState` of 69 B), catalog in `data/combat/`, `ActionMachine` (combo, charge, buffer, cancels, block, hitstop, dodge, stamina, controls), substituted inputs that do not invent actions, `sim_hash` with the catalog, `PROTOCOL_VERSION = 2` | `test_combat_catalog`, `test_combat_state`, `test_action_machine` |
| K1b | `HitShapes`, `DamageFormula`, `FactionRules`, per-zone PvP mode | `test_hit_shapes`, `test_damage_formula`, `test_faction_rules` |
| K2 | 21 B record with `health_q`, extra health block, ENTITY_EVENT (HIT, DEATH, KILL, RESPAWN), RESPAWN_REQUEST, command ids | extensions to `test_net_messages` and `test_snapshot_builder` |
| K3 | `CombatDirector` (tick order), `CombatResolver` with rewind and defense precedence, `Combatant`, `DamageLedger`, death, respawn, falling, lethal volumes, safe zones, dummies, `CommandRegistry` and console (`--console`), `--combat-log`, combat bots (`--fake-brain=combat`) | 134 (resolver, director, ENet loopback, processes...) |
| K4 | Timed events, `CombatFeedback` (marker, numbers, DPS), health and stamina bars, nameplates with name and health, death screen with respawn, combat animation layer with UAL clips, provisional weapons, demo with the combo | 111 |

| K5 | Rewind with NetSim (20/20 seen hits confirmed with rtt=150 and jitter=30; 0 hits with a 30-tick offset), cheating bot `rewind`/`reach`/`rate` (no extra damage), reconciliation with rtt=120 and 5 % loss in a melee, load with combat, demo, first balance pass (`tools/combat_balance.gd`) | `test_combat_loopback`, `test_combat_reconciliation`, `test_bot_cheat*`, `test_combat_balance` |
| Lane 3 | ART-10 audio (buses, `AudioDirector` with pools and voice limit), UI-02 theme (`eldmark_theme.tres`, provisional SVG emblems, gallery), UI-09 components, UI-16 settings (F10, `user://settings.cfg`), SOC-02 `docs/social.md`, TEC-12 `export_presets.cfg` and `tools/export.sh`/`.ps1` | 81 |

**Load with combat** (K5, idle machine, 60 s, 10 real bots and the rest fake players with a combat
brain):

| Combatants | Tick p50 / p99 / max (ms) | simulate | combat | snapshots | KB/s per client |
|---|---|---|---|---|---|
| 32 | 4.9 / 8.9 / 17.2 | 3.1 | 0.35 | 0.84 | 23.6 |
| 64 | 9.4 / 15.9 / 24.9 | 6.5 | 0.77 | 1.41 | 35.3 |
| 128 | 17.5 / 30.0 / 36.3 | 13.3 | 1.41 | 2.16 | 31.4 |

- **First limit of players per battle with combat: 64** (fits in the tick, 0 substituted inputs,
  0 rejected rewinds). The strict criterion of p99 < 8 ms is only met up to about 28. The bottleneck is
  `simulate()` (69–72 µs per character with the action machine), not hit resolution (76–97 µs per
  check, few per tick). With 128 the server saturates and honest players start to exceed the rewind
  cap.
- **Balance** (bots that do not react, a lower bound): measured DPS = calculated (combo 156.3); death
  in 5.95 s against a standing target and 14.47 s against one that blocks; median of 60 bot duels 10.7 s.
  No data has been changed (proposal: third light attack from 130 to 150, to be decided after watching play).

### Adversarial review of phase 3

Three lenses (combat against the design; robustness, security and cheats; architecture, tests and
client), with verifiers who tried to refute each finding: 19 findings, 18 confirmed
(C2 and R3, and C3 and T6, are the same defect seen twice) and 1 refuted (R5).

| Id | Severity | Finding |
|---|---|---|
| C1 | high | A single substituted input during the key press makes the server turn a heavy attack into a light one |
| R1 | high | The client controls the rewind cap (per-input lead time and `interp_delay_q`) and picks the tick in its favor |
| C2/R3 | medium | The rewound block sample keeps protecting a stunned defender: every hit breaks his guard again |
| R2 | medium | A player who stops sending inputs in the middle of a charge keeps a heavy attack charged indefinitely |
| R4 | medium | An enemy's SPAWN carries its entire `CombatState` (exact stamina, buffer...) |
| T1 | medium | Death screen and settings overwrite each other's cursor state |
| T2 | medium | Remotes do not play a second consecutive dodge or stagger |
| C3/T6 | low | The flash of a remote hit by the local player appears before it is drawn at the hit tick |
| C4 | low | A corpse or a stunned player in the air keeps its velocity and can steer |
| C5 | low | If the combo link does not run, the combo does not return to 0 |
| T3 | low | The dedicated server compiles 56 of the 69 client scripts |
| T4, T5 | low | DPS and reconciliation tests are weaker than they claim |
| T7 | low | Backlog F3 checkboxes ticked without being fully met |
| T8 | low | A perfect parry lights up the damage vignette |

**All fixed in `fase3-combate`**, each with a test that failed before (1262 green). Notes:

- C1: a new bit (`combat_flags` bit 6) marks the light attack of the key press; a substitution only
  delays the charge by one tick. Together with C4, C5 and R2 it changes the predicted simulation: **protocol 3**.
- R1, **only partly closed**: the rewind is fixed once per hit (first active tick) and the
  lead time that counts toward the cap is bounded by the recent median + 3 (and 8 at most). A
  cheater with all inputs early and `interp_delay_q` at the maximum still reaches the cap
  of 24 ticks with LAN ping, because the server cannot verify the declared interpolation.
  Documented in combat.md §4.3 and networking.md §10.
- R4: an enemy's SPAWN carries a neutral `CombatState` (only action and weapon).
- T2: remotes see a second consecutive dodge or stagger thanks to a reset counter
  in the action byte (`ActionWire`).
- T3: `boot.gd` no longer names client classes; the dedicated server does not compile client
  scripts (checked by `test_architecture` with a real server).
- Two minor oddities the verifier noted remain untreated: a short stagger that starts and
  ends inside the rewind window lets the old block sample count, and a light attack 3
  on a stunned target swaps the stun for a shorter stagger.

**Open decisions I leave for the user** (they do not block):
- How to fully close R1 (the client declares its interpolation delay): for example, fix the
  delay per zone and not accept the declared one.
- The 24-tick rewind cap does not cover an honest player with 200 ms of RTT (11 of 20 hits):
  raise `MAX_REWIND_TICKS` or trim the TickSync margin. It matters for Latin America.
- Lower the cost of `simulate()` (lever 6 of networking.md §14: C++) if battles of more than 64 are wanted.

## Phase 4: progress

Design in [fortress.md](../fortress.md), reviewed before implementing (22 findings, 3 blockers; several
technical assumptions checked by running Godot and Terrain3D).

| Package | Contents | Status |
|---|---|---|
| F0 | Vado Gris scene and generator (run here): fortress node, closed gate with two bodies (movement by realm layers, view on the structures layer), `respawn_points`, patrols, `NpcSpawner`; baked navmesh (0.3 MB, 0.25 m cell, verified: no way out with the gate closed and no crossing of the riverbed); routes in `data/routes/vado_gris.tres` | Done |
| F1 | `FortressState` with the whole capture table, presence, progress in integers, `WarEvents`, `RespawnRules`, `SiegeView` (44 state tests) | Done |
| F2 | Protocol 4: OBJECT_STATE, SPAWN of structures and NPCs, WAR, TELEGRAPH, /atascado, SCOREBOARD, REJECT for imbalance | Done |
| F3 | Fort server: `FortressController` (presence, `advance`, effects, OBJECT_STATE and WAR), the gate as a target (multipliers, layers by realm, repair), commands 8–11, respawn at the fort, GUE-41 (leaving combat), /atascado, SCOREBOARD, KILL to the whole zone, `--battle-log` and `tools/war/summarize_battle.gd` | Done |
| F5 | Fort client: `FortressView` with the `before_simulate` hook (the gate identical on client and server at every tick), capture HUD, banners, boss bar, TELEGRAPH marks, compass, baked map (`assets/maps/vado_gris.png`), minimap, full map with respawn, scoreboard (Tab) and kill feed, hints, per-realm count on the selection screen | Done |
| F4 | NPCs: `NpcNavigation` (own map, gate link per realm), `NpcDefinition`/`NpcCatalog` (`data/npcs/`), NPC weapons and the Captain's unblockable hit with TELEGRAPH, `HfsmBrain` (idle, patrol, alert, combat, return; tokens: never more than 2 attack at once), `NpcSpawnerSystem` (the Hollow, the Ford Captain, the garrison of the owning realm, 2 Guardians per camp), `--no-npcs`, command 12 `npc_debug` | Done (MUN-10 and MUN-11 remain "in progress": they still need to be played by people) |
| F6a | Siege bots (`BotBrain` SIEGE, `--fake-brain=siege`, `--bot-brain=siege` for `--bot` and `--bots`), `--max-realm-diff` with REJECT 9 and real count in the WELCOME, filler fakes, `--run-at`, `siege` scenario of `load_test`, `tools/war/siege_runner.gd` and `siege_battle.gd` | Done (GUE-42; GUE-15/16/17 remain "in progress" until F6b). Measured without NPCs |
| F6b | End-to-end test neutral → Vardheim → Solmarch with the real NPCs, GUE-43/44/45, load and telemetry with NPCs | Done, by packages (the assignment is in "Closing"; the detail, in fortress.md 8.3): GUE-43; bots against the NPCs and end to end; GUE-44 (gathering and formation: recapture with a median of 2.6 min, still depending on the seed); GUE-45 (part of the owner guards the walkway; with melee weapons the gate cannot be reached from it: it fights whoever comes up); load with NPCs (GUE-16: 32 against 32, tick p99 15.2–17.4 ms, 36.2 KB/s per client, the NPCs ~1 ms; the limit stays at 32 against 32) and telemetry (GUE-17: five battles with log and summary; `vado_gris.tres` does not change). GUE-15 remains "in progress" pending someone playing against them. Review of F6b with its fixes (fortress.md 8.3, "Review of F6b"); GUE-46 remains (long battle with `SwarmBot` only) |
| Abilities | Short design `docs/abilities.md` (CMB-19 to 24, CMB-28, PRG-04/07/08, UI-11, UI-45), reviewed through three skeptical lenses (41 findings, 3 blockers; 34 applied, 4 partly rejected with the reason in its "Review" section) | Design done; implementation after merging F4 (packages H1 to H5) |
| Social | Chat (SOC-03 to SOC-05) and parties (SOC-06 to SOC-08) | Implemented on the `fase4-chat-grupos` branch; the adversarial review (three lenses with refutation) was cut off at closing: it still needs review and merge |
| Phase 5 (design) | `docs/platform.md` (Go service + PostgreSQL, accounts, tickets, saving, GDPR, GM) and `docs/progression.md` (items, inventory, currencies, levels, races): draft, skeptical review and correction | Done in `fase5-cuentas`; the reconciliation between the two was cut off at closing |

### F6a measurements (siege without NPCs; 4 cores with another suite running, `uptime` 0.87 → 1.66)

| Measurement | Value |
|---|---|
| From the camp to the gate (sprinting) | bridge 24–25 s; ford 36.5–37.5 s |
| Breaking the gate (9000 health) from the first hit | 14.9 s with 20 attackers; 21.9 s with 10; 36.9 s with 6 |
| Capture of the neutral with 20 from Vardheim (captain with `fort_kill_captain`) | 55.9 s (gate broken at 39.5 s) |
| Recapture by 20 from Solmarch | 6.0 min (gate 199.5 s, 117.7 s of contest in the circle); with 10 per side, 8.8 min |
| Load 32 against 32 (64 players, 120 s at the gate and the circle) | tick p50/p95/p99/max 10.6 / 15.3 / 19.1 / 27.8 ms; 36.1 KB/s per client; 0 % substituted |
| Load 64 against 64 (128) | 14.8 / 22.0 / 26.4 / 42.8 ms, but **with 118 players and no clients** (the swarm left early; with all 128, p99 of the marks 32.5 ms: F6b review); 28.5 KB/s; **50.8 % substituted** |

**The criterion of p99 < 8 ms with 64 players is not met** (19.1 ms); `simulate()` dominates
(77 µs per character); the `war` section costs 0.1 ms. First battle limit at the fort:
**32 against 32**. The unbalanced recapture (reinforcements arrive one by one) is left to GUE-44.

### F6b measurements (bots against the real NPCs, no orders; game times, 20 per side, three seeds)

| Measurement | Value |
|---|---|
| Capture of the neutral by Vardheim | gate at 40–42 s, the Hollow and the Ford Captain at 71–73 s, **capture at 86–88 s**, no Vardheim deaths |
| Captain's unblockable hit (20 bots) | without leaving the zone, 14 hits and 7 deaths; with the dodge, 0 and 0 (the Captain falls 5 s later) |
| Recapture by Solmarch against 20 defenders and their garrison | realm captain 15,000: one of three in 30 min (6.7 min); **7500 (provisional): 6.7, 24.5 and 27.6 min** |
| Short version of the suite (`test_siege_npcs`, 12 bots, weaker NPCs; deterministic) | with the final code, gate at 19.8 s, captain at 36.6 s and capture at 37.4 s of game time (in package B, 17 / 35–38 s; with GUE-44 and GUE-45, 19.8 / 42.4 / 42.9); the phase takes about 7 s of wall clock (up to 12 with the machine loaded) |
| Recapture with GUE-44 (gathering and formation; five seeds, realm captain 7500) | **2.4 / 2.4 / 4.8 / 2.6 / 12.8 min** (median 2.6); before, with the same ones, 6.7 / 27.6 / 24.5 / 4.4 / 5.6. Attacker deaths per defender death: 1.3 (before 2.7) |
| The same with the realm captain at 15,000 | 2.6 / 2.7 / 11.5 / 15.0 / 17.4 min: all five within the 30-min cycle |
| With GUE-45 (walkway: 25 % of the owner guards it and 12.5 % of the attackers walk it; five seeds) | recapture 4.4 / 2.4 / 4.4 / 2.7 / 2.7 min (median 2.7); deaths on the walkway in all five (2, 6, 3, 4 and 1) |
| Load 32 against 32 with the NPCs (`load_test.gd --npcs`; two passes with NPCs and two without, alternated, machine without another suite) | tick p50/p95/p99/max 10.6 / 14.8 / 17.4 / 27.5 and 9.4 / 13.5 / 15.2 / 23.0 ms (without NPCs, 9.1–9.9 / 12.8–14.2 / 15.0–16.9 / 24.9–27.9); 36.2–36.3 KB/s per client; 0.00–0.03 % substituted; the 9 war NPCs (the 5 at the fort and the 4 camp Guardians), ~1 ms of the tick (brains p99 0.8–1.1 ms while the Hollow live, spawners 0.06 ms, `simulate()` ~0.55 ms); `war` 0.08 ms |
| Load 64 against 64 with the NPCs | 1st: 16.2 / 22.8 / 27.0 / 39.6 ms, but **with 118 players and no clients** (with all 128, the marks give p50 19.6 and p99 33.5); 29.0 KB/s; **38.6 % substituted** and 83 rejected rewinds. 2nd (F6b review, swarm closed by the server tick, another suite running): 17.2 / 24.2 / 30.0 / 72.3 ms; 32.1 KB/s; 0.00 % substituted and 44 rejected |
| F6b review: the five battles with the final code | neutral at 75–83 s; recapture at 202.4 / 399.8 / 151.4 / 152.2 / 144.3 s (median 2.5 min; before 2.7); deaths on the walkway in all five |
| Telemetry (GUE-17): five battles with `--battle-log` and `summarize_battle.gd` | identical to those of GUE-45 (deterministic); neutral at 80–87 s (gate 11–12 s after the first hit); recapture at 146–265 s (gate 12–22 s, once 81.5 s); 360 player deaths (327 on the forecourt and courtyard, 17 at the ford, 16 on the walkway, 0 on the bridge) and 48 NPC deaths. **`vado_gris.tres` does not change** (fortress.md 8.3, package E) |

What lengthens the recapture is not the NPCs but the circle in front of the defenders (GUE-44). Bug fixed: whoever was
inside their closed gate hit outward without being hit back. With GUE-44 (package C) the underlying cause showed up: characters
do not collide with each other and bots that follow the same points pile up, and a sweeping hit lands on the whole pile (20 attackers
dead in 1.2 s without killing anyone). Now the attackers gather at their camp before setting out and each bot takes its own slot.
With the 32 against 32 load and the NPCs, the tick p99 is still far from 8 ms and the first battle limit at the fort stays at
**32 against 32**: the NPCs cost about as much as the variation from one pass to another. With the telemetry of the five battles, no figure in
`vado_gris.tres` is clearly out of range: the gate (9000) meets GUE-10 and is not what takes longest, and consolidation (120 s) is the floor
of the recapture, which is what its decision asks for. They remain provisional until tested with people.

### F4 measurements (machine shared with other suites: upper bounds)

| Measurement | Value |
|---|---|
| `HfsmBrain` per NPC per tick (p50, thinks every 6 ticks staggered) | 15–30 µs |
| `simulate()` of one NPC | 32–56 µs (up to ~100 µs with the brain in full combat) |
| `npc` section (`NpcSpawnerSystem`, 14 posts of Vado Gris) | ~60 µs/tick |
| Tick with the 9 NPCs of Vado Gris and 3 bots fighting | p50 1.0–1.3 ms, p99 2–2.4 ms |
| 3 combat bots clear the 4 Hollow | ~46.5 s |
| 4 bots (healed every tick) defeat the Ford Captain (30,000 HP) | ~77.5 s; without healing them they die first |
| An intruder in the safe zone facing the 2 Guardians | dies in 4.2–5.2 s (criterion < 10 s) |

The fine criteria of MUN-10 (60–90 s with 2–3 people) and MUN-11 (60–120 s with 3–5) need
people: bots are not a good measure. NPC health and damage adjusted so the criteria can
be measured (provisional; see `docs/fortress.md` §8.3).

### Adversarial review of phase 4

Four lenses (war: fortress, gate, NPCs and siege; cheats and robustness; fort client; abilities), with one
verifier per lens who tried to refute each finding. Chat and parties already had their review (social.md §12): here
only their crossings with everything else were examined. 19 findings and none refuted:
17 confirmed and 2 partly confirmed (TR2 and CL5). GU3 and TR2 are the same defect seen twice, so that leaves 18.

| Id | Severity | Finding |
|---|---|---|
| GU1 | medium | Automatic respawn does not respect waves: the server's fakes and `--bot` never respawn in a wave |
| GU2 | medium | A deferred gate repair is applied even if the gate took new damage: the owner heals it fully by standing in the doorway |
| GU3/TR2 | medium | The Ford Captain's reinforcements accumulate without limit: he calls them again on every regeneration and the full respawn does not remove them (TR2, "every combat that restarts adds 2 Hollow", partly confirmed) |
| TR1 | medium | Rewind false positive (the intermittent failure of the "rate" cheater): with several physics ticks in one frame, `view_offset_q` is measured against a stale `render_tick` |
| TR3 | medium | An NPC attacked from beyond its leash radius stands still and only heals every 3 s: under ranged fire it dies without moving or damaging anyone |
| TR4 | low | `HfsmBrain._state_log` grows without bound over the whole life of each NPC |
| CL1 | medium | The scoreboard (Tab) requires exact modifiers: it does not open while running with Shift and stays open if Tab is released with Shift held |
| CL2 | medium | The TELEGRAPH mark fills with the arrival clock: it finishes filling one RTT plus the margin after the last tick at which a dodge is still possible |
| CL3 | low | Hints are counted as seen even if the death screen or the map covers them (the respawn one, always): UI-42 ticked without meeting "sees each hint once" |
| CL4 | low | `TelegraphMarks` (and its hint) draw as danger the heavy attacks of the garrison and the captain of the player's own realm |
| CL5 | low | With the social menu open, Space (jump) presses "Invitar al grupo" (invite to party), which has focus when it opens (partly: the Enter case is not a bug, it confirms the focused button as in any window) |
| CL6 | low | On the death screen, after pressing a point or a template, Tab moves the focus instead of opening the scoreboard |
| CL7 | low | Prediction corrections caused by the gate changing (broken or changing owner) are counted as unexplained prediction failures |
| HA1 | medium | The shield wall of someone in their realm's safe zone stops enemy arrows: it spends stamina, suffers the guard break and ends up "in combat" inside the camp |
| HA2 | low | A shield wall tap shorter than its cast leaves a single NONE tick between two uses with the same action byte (what RP3 wanted to avoid) |
| HA3 | low | Slow (STRONGEST) renewed by another player keeps the author of the first application: the STATUS comes out with the wrong author and the first one's death removes what the second renewed |
| HA4 | low | Client: a deferred foreign STATUS erases from the `StatusTracker` a newer effect the local player just applied |
| HA5 | low | Knocked-down notice: cutting off another interaction erases "¡Te rematan!" ("You are being finished off!") even though the finishing blow continues |

Refuted: none. None is serious in a normal match, but GU1 changes what all the bot battles of F6a and F6b measured,
and TR1 made honest players lose hits after a hitch (and added suspicion to them).

**All 18 are fixed in `wip/revision-fase4`**, each with a test that failed before the fix (commits
dc15ed9 war, e666a8e cheats, 34a0c93 client and b152e5b abilities). The most relevant:

- GU1: automatic respawn falls on the first wave 30 s or more after death (`CombatTiming.auto_respawn_tick_for`,
  `Combatant.auto_respawn_tick`); the server's fakes request respawn on death and `--bot` as soon as it can,
  like `SwarmBot`. Outside the zones with a fortress the fakes return after 10 s, not 30. The five battles
  measured again: recapture 158.8 / 162.8 / 161.8 / 156.6 / 286.9 s (median 161.8; before 157.4) and the capture of the
  neutral the same. GUE-44 stands: without gathering the median rises to 220.5 s. The 20 against 20 load with NPCs and the
  40-player melee do not change (fortress.md 8.3).
- GU2: only the repair of the broken gate (the one that changes collision) is deferred; that of an intact one happens at once
  and a hit that removes health cancels the pending one.
- GU3/TR2: the Captain calls his reinforcements once per life; the full respawn removes them and rearms the
  call, and there are never more alive than `reinforcement_count` per fortress.
- TR1: `CombatResolver.compute_rewind` clamps to the cap whatever exceeds it by up to 8 ticks
  (`REWIND_REJECT_SLACK_TICKS`) and only rejects, with suspicion, above that; `allowed_rewind` rounds the
  interpolation up. Whoever declares too much stays at the cap, like an honest player; the `rewind` cheater (40 ticks) is still
  rejected. With real hitches (SIGSTOP of 150–200 ms on the "rate" bot), 2 to 5 false rejections with the earlier code
  and 0 in four passes with the current one. Side effect (deduced, not measured): an honest player with about 200 ms of RTT no
  longer loses hits up to 32 ticks; they are checked against 24 and without suspicion (networking.md §10).
- TR3: whoever hits an NPC from beyond its leash radius extends it to them and the NPC chases; the leash or being stuck
  sends it to an immune return if it cannot reach them. TR4: `_state_log` bounded (`STATE_LOG_MAX`).
- CL1: no exact modifier matching; the scoreboard opened with the key closes on its own only if its release does not arrive.
- CL2 and CL4: `TelegraphMarks` fills with the predicted tick (it fills exactly at the last tick at which leaving still avoids the
  hit, is removed when the active window ends and an expired warning is not drawn) and only draws the hits of whoever can
  damage the player (`TelegraphMarks.threatens`, with the `FactionRules` rule).
- CL3: the HUD mounts the hints above the death screen and below the map and the scoreboard; they wait while
  covered, are recorded after 4 s in view, and the respawn one is withdrawn if the screen closes before it is read.
- CL5: `InputBindings` removes Space from `ui_accept` (Enter still confirms). CL6: no control on the death screen takes
  focus. CL7: `NetClient` counts as explained the corrections of the ticks predicted with the old gate
  before the OBJECT_STATE that changes it.
- HA1: the arrow passes through the wall of whoever is in their safe zone, like their capsule (it does not cover allies
  outside either: inside no damage is received or dealt). HA2: releasing or breaking a channel without committing leaves the margin of
  `REARM_TICKS` in its slot (shared, predicted code; no protocol change). HA3: a STRONGEST renewed with a
  later end passes to the author of that end. HA4: a remote's `StatusTracker` receives its own events at its
  draw tick, at the tail of the foreign ones. HA5: `DownedNotice` stores each interaction with its actor and only the end or the
  cut of that actor removes it.

**Full suite after the fixes** (commit b152e5b), in two halves at once on the 4-core machine
(`--shard=1/2` and `--shard=2/2`): **2291 tests, all passing on the first try** (1107 in 817 s and 1184 in 491 s); no
further round was needed.

## Closing of the session: what remains and in what order

The session was closed at the user's request. The running jobs were stopped and everything they
had left was pushed; nothing has been lost except F6b, which had no commits yet.

1. **Full suite of `fase4-fuerte` after F6a** (see the result at the end of this section). With F4
   already merged it gave 1687 of 1687. After merging F6a, the filtered tests that touch its code passed
   (`siege` 35, `server_main` 15, `realm_balance` 18, `bot_brain` 27). The integration needed two
   fixes (4bb0eab): `HfsmBrain` (F4) and `BotBrain` (F6a) declared the same members, and
   the F6a tests, written without NPCs, now start with `--no-npcs`.
2. **Chat and parties** (`fase4-chat-grupos`): the adversarial review is missing (privacy between realms,
   server and protocol, client) and so is merging it into `fase4-fuerte`. It takes `PROTOCOL_VERSION = 5`. It clashes
   with `zone_server.gd`, `hud.gd` and `input_bindings.gd` of F4/F6a: it has to be resolved by hand and the
   suite passed. What is implemented and what is pending is in `docs/social.md` §12.
3. **F6b**, the assignment that was cut off. **Done** in full (packages A to E; fortress.md 8.3, F6b), except what needs people:
   - **Bots against the NPCs.** The SIEGE bots kill the Hollow and the Ford Captain without commands.
     They attack the nearest NPC of the owner and respect the unblockable hit. **Done** (fortress.md 8.3, F6b).
   - **GUE-15 criterion.** "`--bots=20` per side capture and recapture without intervention", with real
     NPCs: neutral → Vardheim → Solmarch.
     - A long tool outside the suite.
     - A short version inside, without `fort_kill_captain`.
     - If they do not capture, minimal, provisional adjustments noted in `fortress.md` §8.3.
     - **Done**: `siege_battle.gd --npcs` and `test_siege_npcs`; realm captain at 7500 (provisional). The recapture still
       depends on the seed (GUE-44); with GUE-44, from 2.4 to 12.8 min with five seeds.
   - **GUE-43, GUE-44 and GUE-45.**
     - GUE-43: the filler fake yields its slot to a person.
     - GUE-44: reinforcements gather before setting out. **Done** (fortress.md 8.3, F6b, package C): gathering at the camp exit (8 of their realm, 3 already
       fighting at the fort or the 30 s clock), same route and formation.
     - GUE-45: the owner's SIEGE bots defend the walkway. **Done** (fortress.md 8.3, F6b, package D): with melee weapons
       the gate cannot be reached from it, so they guard it and fight whoever comes up; deaths on the walkway in all five battles.
   - **Load with NPCs.** `load_test.gd --siege` with 32 against 32. **Done** (package E): `load_test.gd --npcs`; with the NPCs, tick
     p99 from 15.2 to 17.4 ms, 36.2 KB/s per client and at most 0.03 % of inputs substituted; the 9 war NPCs (the 5 at the
     fort and the 4 camp Guardians), ~1 ms of the tick.
     The limit stays at 32 against 32.
   - **Battle with telemetry.** A full battle with `--battle-log` and its summary. **Done** (package E): five, with 20 per side
     and the NPCs, and their summary; with those numbers `vado_gris.tres` does not change (provisional).
   - **Tools.** `SiegeRunner.start(..., with_npcs = true)` starts with the NPCs. **Done** (and
     `siege_battle.gd --npcs`, `--npc-health`).
4. **Abilities** (`docs/abilities.md` §7). It starts with F4 and chat merged.
   - Two lanes: H1a → H1b → H3a → H3b → H3c, and at the same time H2 → H4 → H5.
   - Protocol 6.
5. **Full adversarial review of phase 4** (three lenses with refutation, like those of phases 2
   and 3) and its fixes with tests. **Done**: four lenses and 18 findings fixed with tests ("Adversarial review
   of phase 4", above).
6. **Phase 5**:
   - First, reconcile `platform.md` and `progression.md`. Each lists in its interface section
     what it asks of the other: table names, ids in JSON, who owns CMB-30, 52 B ticket.
   - Fix `PROTOCOL_VERSION = 7` (5 belongs to chat and 6 to abilities).
   - Then implement in `fase5-cuentas` following its packages.
   - This machine has Go 1.24 and PostgreSQL 16. The service tests use an ephemeral `initdb`
     with `runuser -u postgres`, verified.

**Full suite of `fase4-fuerte` after F6a** (commit 4bb0eab, later ones are documents only): **1747 tests, all passing** (1046 s).

What the user has to decide is in "Open decisions" at the end.

## Pending to try tomorrow with a window

None of what follows could be seen: there is no GPU or window here. Everything about networking is tested without a
window (tests, processes and bots), but the human eye is missing.

In PowerShell, from the repo root and on the `fase2-red` branch (or the most recent one, which
contains it):

```powershell
$godot = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64_console.exe"
& $godot --headless --path . --import
& $godot --headless --path . -s res://tests/run_tests.gd        # ~17 min on fase4-fuerte, about 1720 tests
```

1. **F5 with no arguments** (or `& $godot --path .`): it must be exactly the usual sandbox in
   Vado Gris. Also check `-- --demo --quit-after-demo`.
2. **Server and two clients with a window** (three terminals):
   ```powershell
   & $godot --headless --path . -- --server --debug-commands
   & $godot --path . -- --connect=127.0.0.1 --realm=vardheim --name=Ana
   & $godot --path . -- --connect=127.0.0.1 --realm=solmarch --name=Bruno --net-sim=rtt=120,jitter=20,loss=3
   ```
   Look at: that each one sees the other move smoothly (animated, no skating or jerks), that your own
   character responds instantly, that F3 shows the network panel and F4 the ghost, and that there are no visible
   jumps when correcting.
3. **All in one**: `& $godot --path . -- --local`. Without `--realm` the realm selection screen
   should appear (check its layout: it has never been seen). Open a second window
   with `--local` and check that it reuses the same server.
4. **Bots against your client**: with the server from step 2,
   `& $godot --headless --path . -- --bots=20 --connect=127.0.0.1` and watch 20 remotes at once.
5. **Linux server, Windows clients** (if there is a VPS): reconciliation should absorb the
   last-bit differences; the F3 panel counts the corrections.
6. **Combat** (`fase3-combate` branch): with the server and two clients from step 2, attack (left
   click: tap = light, hold = heavy), block (right click), dodge (Ctrl).
   Look at: that your own hit goes out instantly and the marker on confirmation; that the other sees the
   animation; health and stamina bars; nameplates; dying and respawning with the button. Dummy:
   in `test_world` and next to every camp in Vado Gris. Clip preview:
   `& $godot --path . res://scenes/tests/combat_preview.tscn`. The weapons are a box and a
   cylinder (provisional).
7. **Interface**: theme (`scenes/tests/ui_gallery.tscn`), settings with F10, provisional SVG
   emblems. The OFL fonts are missing (see `assets/LICENSES.md`).
8. **Export** (TEC-12): install the 4.7.2 templates from the editor and run
   `tools\export.ps1` (it could not be run here).
9. From the editor: *Debug ▸ Customize Run Instances* (instance 1:
   `--headless -- --server --debug-commands`; 2 and 3: `-- --connect=127.0.0.1 --realm=vardheim` and
   `--realm=solmarch`).

10. **The Vado Gris fort** (`fase4-fuerte` branch). In three terminals:
    ```powershell
    & $godot --headless --path . -- --server --zone=vado_gris --debug-commands
    & $godot --path . -- --connect=127.0.0.1 --realm=vardheim --name=Ana
    & $godot --path . -- --connect=127.0.0.1 --realm=solmarch --name=Bruno
    ```
    Look at:
    - the capture HUD on approach (owner, phase, progress, "Disputado" (contested), gate health) and the
      banners;
    - the Ford Captain's boss bar and the ground mark of his unblockable hit;
    - the compass, the minimap and the map (M), with the respawn choice on death;
    - the scoreboard (Tab), the hints and the banners, which change color on capture;
    - the Hollow patrolling and fighting; the Guardians killing an intruder in the foreign camp.

    Server console commands: `fort_kill_captain`, `fort_owner vardheim`, `fort_reset`,
    `fort_capture_speed 20`, `npc_debug`.

    With siege bots against your client (40 fakes, 20 bots and the two people make 62 players: `--max-players=64`
    is needed):
    ```powershell
    & $godot --headless --path . -- --server --zone=vado_gris --max-players=64 --fake-players=40 --fake-brain=siege
    & $godot --headless --path . -- --bots=20 --bot-brain=siege --connect=127.0.0.1
    ```
    Since the integration of abilities Vado Gris has a default capacity of 40 (`Zones.MAX_PLAYERS`, the
    limit with the phase 4 kit): **any manual session in Vado Gris with more than 40 players (fakes, bots and
    people) needs `--max-players`**. Without it, the 40 fakes (which are not filler without `--max-realm-diff`) fill
    the server and the 20 of the swarm and the two people receive "lleno" (full, FULL). With more than 40 the tick no longer meets the
    criterion (docs/networking.md 14): it is for looking, not for measuring.
    Everything visual in phase 4 is provisional and unseen: Hollow with the humanoid, banners,
    gate effects, ground marks, baked map, HUD colors and sizes.
11. **Chat and parties** (`fase4-chat-grupos` branch, with the server and the two clients from step 2):
    - Enter opens the line and Esc closes it.
    - Try `/d`, `/z`, `/s Bruno hola` (across realms it should say "no está conectado" (is not connected)) and `/r`.
    - Invite from the social menu, aiming at an ally less than 20 m away.
    - Look at the party frames.

- **Windows, untested on this (Linux) machine:** the Windows branch of
  `LocalServerLauncher.is_process_alive` (A1, `tasklist /FI "PID eq <pid>" /FO CSV /NH`) is written
  according to the Godot 4.7.2 code (`OS.is_process_running` only knows its own child processes). Its
  tests run on all platforms (reading the `tasklist` output; a child process looks at the
  runner and the runner looks at a grandchild), but the full suite must be run on Windows and, in
  particular, `--filter=test_local_server_launcher`, and two windows opened with `--local` to see the message
  "Servidor local ya en marcha … se reutiliza" (local server already running … reused). There is also a `windows-latest` job in
  `.github/workflows/tests.yml` (not run yet: the first run on GitHub will tell whether the step that
  downloads and unpacks Godot for Windows works).
- The orphaned lock after `SIGTERM`/`SIGINT` (S5) is only mitigated on Linux (`/proc/<pid>/cmdline`); on
  Windows an orphaned lock with a reused pid would keep fooling `--local` for one attempt.

## Decisions taken outside the contract

- **Phase 4, integration**:
  - `FortressView` accepts the fortress definition as a resource or as a path, like the
    server.
  - The cheaters test in processes leaves 5.3 s of margin between the bots and the server.
  - The members of the SIEGE pattern in `BotBrain` carry the `_siege_` prefix, because the NPCs inherit
    from `BotBrain`.
  - `SiegeRunner` starts without NPCs unless asked.
- **F4**:
  - NPC health and damage adjusted so the criteria can be measured. Hollow, guard and Guardian
    have 2500 health, the Ford Captain 30,000 and the realm captain 15,000 (7500 since F6b, provisional:
    with 15,000, 20 bots only recaptured one time in three within the 30-min cycle).
  - The realm's garrison comes from mirrors of the Hollow's posts (`garrison_id`), without touching
    the scene.
  - TELEGRAPH for every heavy attack of an NPC.
  - New option `--no-npcs`.
- **F6b, load and telemetry with NPCs (package E)**:
  - `load_test.gd` gains `--npcs` (the NPCs and the fort without aids). Without it, the F6a siege now passes `--no-npcs`: since the
    merge of F4 it started with the NPCs and also killed the captain by order when the window began.
  - The server's metrics line ends in "N NPCs", and the `SwarmBot` report says when it reached the fort
    (`fort_reached_tick`), to check what GUE-44 left pending: the 10 real bots arrive before the window.
  - `vado_gris.tres` is not touched: no figure is clearly out of range with the numbers of the five battles (fortress.md 8.3).
- **F6b, GUE-45**:
  - The gate's defenders cannot be hit from the walkway (the weapon does not reach): the guards guard it and fight whoever comes up.
  - The climb is a route precomputed in the route data, checked against the NPC mesh, not `NpcNavigation` on every
    query (the brain is also used by `--bots` and `--bot`, which do not have the mesh).
  - Half of those who guard it (12.5 %) walk the walkway when attacking: with the same 25 % the recapture doubled.
  - The bots' enemy finders weigh height by 4, and inside the compound an enemy more than 1.6 m higher is not a
    target.
- **F6b, GUE-44**:
  - The attackers also gather when the battle starts, not only when respawning; the group takes the same route, the one of the clock lap
    on which it sets out (before, each one chose its own with its generator).
  - Formation: each siege bot in a group adds to its destinations a slot derived from its seed. It was not in the assignment; without it the
    gathering barely improved the recapture, because the bots pile up.
  - "Go help" rule: it does not wait if 3 of its own are already fighting at the fort (always waiting let the captain heal).
  - The two-routes test of `test_siege_zone` removes the gathering (`set_rally(0)`) to keep measuring the two routes.
  - The realm captain stays at 7500: with GUE-44 15,000 would also fit, but it is decided with people.
- **F6a**:
  - `--max-realm-diff` only counts people. Entry into realm r is rejected if
    `people[r] + 1 − min(others) > N`.
  - Filler fakes are withdrawn one for each person who enters the larger side.
  - New option `--run-at=<tick>:<command>`.
  - Death class `gate` in the battle summary.
  - "Defend the walkway" stays as defending the circle (GUE-45).
- **Protocol versions allotted**: 4 the fort, 5 chat and parties, 6 abilities and 7
  phase 5. If the merge order changes, they are renumbered.
- **Phase 4 and 5 designs**: the pending decisions that blocked were taken with the
  backlog's recommendation and are in "Decisions taken", marked "provisional, taken at night".
  - Abilities: reuse only (mana on the staffs), canonical camera ray with a shoulder bit,
    knocked down only in PvP, and action HUD.
  - Phase 5: Go + PostgreSQL, saving with a 60 s checkpoint plus critical events, a single
    world with `world_id`, DTLS if possible, one realm per account, ignore per account and chat 30 days.
  - Progression: one human town per realm, slot-based bag, currencies per character, merits and
    realm points separate, and XP by contribution.

- Package A: `BotBrain._init(rng_seed, …)` instead of `seed` (so as not to shadow the global function);
  `NetZones.allowed_realms` returns empty (all realms) because `Zones` does not register realms per
  zone; `NetZones` adds `realm_name()`, `find_spawn_point()`, `get_spawn_points()` and
  `spawn_group()` (the last two, after the review, so that `SpawnPicker` does not call `Zones`
  directly: §1.5 and §17.3); the `decode` functions reject invalid UTF-8 without logging engine errors.
  `ServerMain` does call `Zones` (list of zones and realms with a camp, §19) and
  `test_architecture` admits it as an exception, like the `ClientMain` sandbox.
- **Lead-time criterion of test d of `test_net_loopback` (networking.md §16)**: the contract said
  "`input_margin` in [0, 6] in steady state". The test measures the **minimum of the `TickSync` window**
  (`get_window_min()`) in [0, 6] (`MAX_TARGET` 4 + `SLOW_DOWN_THRESHOLD` 2, the band the
  control loop regulates), with each bot's mean inside and at least 80 % of the samples. Reason: the
  `input_margin` of a single snapshot is the minimum of the arrivals of two ticks and, with
  rtt=150, jitter=30 and loss=10, it ends up by design 2–4 ticks above the window minimum: with
  the same seeds, between 28 % and 35 % of each bot's snapshots go above 6 (mean 6.06–6.11,
  histogram of Botaaab {3:1, 4:4, 5:29, 6:66, 7:46, 8:5}), while the window minimum falls
  outside [0, 6] only 2.3 %, 0 % and 0 % of the time. Requiring 98 % of the snapshots inside
  [0, 6] would force lowering the target and accepting more late inputs. Adversarial review,
  finding A2: the assertion does not change; the text of networking.md §16 d is corrected.
- **Interpolation clock (networking.md §4.3)**: the normative pseudocode corrected against the previous draw tick and
  converged 1 tick ahead of the target (effective delay of 3 ticks instead
  of 4). Fixed in the code and in networking.md: first advance, then correct.
- Package D: `ClientPrediction.get_stats()` uses the keys `matches`, `ignored`, `replays`,
  `corrections`, `resimulated_ticks`, `last_correction`, `max_correction` and `hard_resets`;
  jitter below 0.001 ticks counts as 0.
- **Names** (SOC-01, provisional): 3–16 letters with accents and ñ, initial capital, no spaces
  or digits, a reserved list, unique among those connected (ignoring accents and case, and ñ
  counts as n). Default names "Jugador" + 4 letters and, for bots, "Bot" + 4 letters.
- **Realms per zone** (GUE-02): Vado Gris only admits Vardheim and Solmarch (Askarra receives
  REJECT REALM); `test_world`, all three.
- **CI** (TEC-03; LFS was dropped later, so none of this applies now): the checkout does not download LFS; the `.git/lfs` cache is restored and then `git lfs
  pull`. For a failing test to block the merge, "Suite completa" (full suite) must be marked as a required
  check in the branch protection (only from GitHub).
- Package E: without a server, `--local` and `--bots` gave an error (until M4–M5); in headless bot mode the
  zone is loaded without the visuals; the client also forces full Terrain3D collision.
- Package C2: `sim_hash` is computed by `ZoneServer.start()`; a jump of more than 1.5 m in one tick
  is logged as a warning (not an error) and in the report's `physics_errors` counter.

## Open decisions for the user

- **Fort load**: with 32 against 32 the tick p99 is 19.1 ms, against the 8 ms criterion.
  `simulate()` dominates, at 77 µs per character. The first battle limit stays at 32 against 32.
  With the NPCs (F6b) it does not change: 15.2–17.4 ms on a quiet machine, and the NPCs cost ~1 ms.
  To raise it: `simulate()` in C++ (GDExtension) or a per-zone budget.
- **Combat**: `MAX_REWIND_TICKS` for a 200 ms RTT and the P1 balance of
  `combat.md` §12 remain open.
- **Phase 5**:
  - the business model (PRG-41);
  - the VPS provider and region;
  - the domain;
  - the legal texts and the GDPR review (minimum age 16 provisional, retention periods);
  - uploading backups to S3.
- **Art**: the visuals of phases 3 and 4 are provisional. Missing:
  - the OFL fonts;
  - the 4.7.2 export templates;
  - the models of the Hollow, guards and Captain (ART-15/16/17);
  - the bow (ART-41).
- **Criteria that need people**: MUN-10 (60–90 s to clear the Hollow with 2–3 people) and
  MUN-11 (60–120 s for the Captain with 3–5).
