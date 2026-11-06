# Eldmark · Phases 6-8: quests, commissions and world events

Design of the quest core (MUN-17), the journal and tracker (UI-29), side quests and lore (MUN-46), daily commissions
(MUN-32), world events (MUN-31), the links with the war and with specialization, the localizable data format and the
tools to produce hundreds of quests. The story they tell is in [story.md](story.md); the first complete chain
(Hondal, levels 1-10) is its section 6.

Every figure here (rewards, caps, times, event sizes) is **provisional**: it is the starting point that the flow
simulator (section 13.4) and real matches adjust. Whatever is a rule (closed objective catalog, data-only quests,
ids that are never reused) is not.

It builds on [progression.md](progression.md) (ledger, `ProgressService`, save), [platform.md](platform.md)
(`CharacterSaver`, claim, Go store), [networking.md](networking.md) (messages), [localization.md](localization.md)
(text) and [social.md](social.md) (parties). Three documents written at the same time own pieces this one uses:
`advancement.md` (level curve 1-60, XP sources and the reward table of section 3.6), `npcs.md` (NPC data, interaction
and dialogue) and `items.md` (the QUEST container and item choices). Until they are merged, their numbers are the ones
quoted here.

**Assumptions.**

- Level cap 60 and about 50 hours to reach it. The simulation runs at **60 ticks/s** and sends snapshots at 30 Hz;
  every time in the data is in **seconds** and becomes ticks on load with `roundi(s · tick_rate)`, so it is valid if a
  zone drops to 30 Hz.
- Vardheim is the first realm built. The complete example is Hondal. Quest ids carry a realm prefix (`vdh`, `sol`,
  `ask`).
- Quests are written by act and level band, not by zone name, so moving a band does not rewrite them (the band table
  is in [world.md](world.md) and `docs/story.md`).

## 0. Decisions

| # | Decision | Why |
|---|---|---|
| D1 | Quests are typed data (`.tres` in `data/quests/`), written by hand or by agents from templates, with a validator. No intermediate JSON and no Dialogic | Closes the pending decision "In what format are quests and dialogues written?" of [backlog.md](backlog.md): the text lives in the repo, the server loads it without the UI, there is no conversion step and one source of truth |
| D2 | **Closed catalog of 21 objective types** (section 3.2) and no code per quest | With agents producing hundreds of quests, code per quest cannot be audited. A new type is tested once and serves all of them |
| D3 | `GameEventBus` on the server: a single point where the zone publishes kills, items, interactions, areas, merits, captures and combat actions | Quests, commissions, events and achievements (PRG-42) listen to the same thing, instead of four systems hooked one by one into `zone_server.gd` |
| D4 | Persistence in a new `quests` section of the save, in the same transaction as `progress`; a turn-in stores the `op_id` of its reward | The reward (gold, items) and "quest completed" cannot be separated: both or neither. [platform.md](platform.md) §7.3 already applies the whole envelope in one transaction |
| D5 | **Rewards are fractions of the hourly rate**: XP as a fraction of `r(L)` and gold as a fraction of `g_ref(L)`, both from the table that `advancement.md` owns (section 3.6) | Time is conserved: a quest worth 12 minutes pays 12 minutes of progress at any level, and it rescales by itself when the curve changes. Fractions of `xp_to_next(L)` would pay up to half an hour at high levels, because the minutes per level grow |
| D6 | **At the cap the surplus XP goes to veteran XP**, not to mastery. A Veteran Seal (coin 3, per character) is earned every 40 000 XP | Two paths for the same thing is one too many; the veteran rules are `advancement.md`'s |
| D7 | No *phasing* and no per-quest instances. At most **personal interactables** (a clue you already examined, a chest only you open) | Phasing multiplies server and test cost. Personal interactables are per-player state, like personal loot |
| D8 | Quest items live in their own **container** (`4 QUEST`), bound and worthless, and are erased on turn-in or abandon | A full bag never blocks a quest, and they stay out of trade and out of the gold validator |
| D9 | In a group: quests are shared inside a zone and kill credit goes to members within 100 m with an action in the last 60 s; quest items are rolled per person | Matches the 10 % contribution rule, the party of 5 and the 100 m radius of [social.md](social.md) |
| D10 | No war objective in the main thread ever blocks: it is always `any_of` with an alternative that is met by losing or playing solo | A realm in the minority or an hour with nobody online cannot leave anyone without a story |
| D11 | War credit for quests comes **only** from events that already gave merits (PRG-09, with its anti-farming and its filters for GMs, fakes and forced captures) | Reuses the abuse defense that exists instead of inventing another |
| D12 | The merits quests give do not raise realm points (rule I9 of [progression.md](progression.md) §3.2: only reasons 3-5) | Realm rank is earned fighting, not turning in papers |
| D13 | Specialization: the first choice requires the trial of the chosen role; changing it later in the capital needs no quest (it costs gold, section 11) | Gives weight to the moment of choosing without punishing whoever wants to try another |
| D14 | Quests unlock no weapon abilities and no specialization passives by level; only the initial specialization and its ultimate, through "The Squire's Choice" | If power depended on quests, changing specialization or making an alt would force repeating them, and Eldrun's normalization would gain another variable |
| D15 | Daily commissions are drawn **deterministically** per (realm, board, day): `hash(realm, board_id, day_index)` | Every zone and channel sees the same draw with no central service and nothing persisted |
| D16 | Daily reset at **04:00 UTC**, weekly reset on **Monday** at 04:00 UTC | 05:00-06:00 in Spain: nobody is playing, and it is the custom of the genre |
| D17 | Quest ids are text (`vdh_hondal_m04`), never reused or renamed; a withdrawn quest is marked `retired` and stays in the catalog | Persistence and requirements point at ids; same rule as the ledger reason codes of [progression.md](progression.md) §5.3 |
| D18 | The story is linear per realm with small choices that only leave cosmetic flags (a title, a different line of dialogue) | Branches cost double content; flags are cheap and give a sense of agency |
| D19 | No recorded or generated voices: text, gestures and sound | Cost and license; the art direction rules out generative AI |
| D20 | The Echoes of Eld (visions on touching an Ember) carry the main lore: text with a screen effect, no cutscene | Cheap to produce (text, VFX, audio) and collectible (PRG-42) |
| D21 | Two quests of the Vado Gris chain (the Baptism of Fire) open at **level 10** through the provisional pass from Hondal to the Vardheim camp; the zone is normalized, so level 10 is not at a disadvantage | Resolves the safe-road question: no corridor through levels 30-40 is needed for the first slice |
| D22 | Eldrun opens at **level 20**, the end of Act II (about 10 hours in) | One rule across the war thread, the commissions and Ember Rain |

## 1. Summary

1. **Quests are 100 % data.** Not one line of GDScript per quest: a `QuestDefinition` (`.tres`) with stages,
   objectives from a closed catalog of 21 types, requirements and rewards by formula.
2. **The core can start now**, in the Vado Gris: NPC kills, areas, captures, merits and level already emit events on
   the server (`ProgressService.on_npc_killed`, `on_capture`, `on_merits`, `on_objective_ticks`). Talking and
   interacting arrive with the interaction and dialogue systems (MUN-16, MUN-18), each adding its objective type.
3. **One game event bus** feeds quests, commissions, world events and achievements.
4. **Persistence** is the `quests` section of the save, applied in the same transaction as `progress`.
5. **Text** has an English `msgid` and `es.po`, one context per field, and a hard rule: a sentence is never built
   around a noun placeholder.
6. **The story is never blocked by the war** (D10).
7. **Specialization at level 10** is a quest, "The Squire's Choice", plus one trial per role built from objective
   filters (blocking, healing, killing at range, killing with a two-handed weapon), with no custom mechanics.
8. **Hondal 1-10** has 13 main quests, 15 side quests, 21 lore texts, a Granvik board of 6 commissions and the Hollow
   Incursion event.
9. **Production at scale:** archetype templates, a reference and feasibility validator, a bilingual review sheet, a
   flow simulator and a bot that completes chains by itself.

## 2. Quest model (MUN-17)

### 2.1 Kinds

| `Kind` | Code | Purpose | Repeat | Counts toward the active cap |
|---|---|---|---|---|
| MAIN | 1 | The realm's main thread, by act | Once | No |
| SIDE | 2 | Side quests of a zone or capital | Once | Yes |
| TRIAL | 3 | Specialization trial | Once per specialization | No |
| COMMISSION | 4 | Board commission, generated from a template (section 8) | Daily | Yes (at most 3 at a time) |
| WAR | 5 | War commission, call to arms | Daily or per trigger | Yes |
| WEEKLY | 6 | Weekly orders | Weekly | Yes |
| BOUNTY | 7 | "Wanted" poster for a named rare | Cooldown (20 h) | Yes |
| EVENT | 8 | Internal: the credit of a world event (section 9) is earned, not accepted | Per event | n/a |

Cap: **25 active quests** that count, plus MAIN and TRIAL, which do not, so the story never gets blocked. Up to 5
are tracked on the HUD.

### 2.2 States

| State | On the server | Travels | Notes |
|---|---|---|---|
| UNAVAILABLE | Computed | No | Requirements not met |
| AVAILABLE | Computed | In QUEST_AVAILABLE (section 4.1) | For the "!" over the giver |
| ACTIVE | Saved: stage and counters | QUEST_UPDATE | |
| READY | Saved | QUEST_UPDATE | Objectives done; turn-in pending (or automatic with `auto_turn_in`) |
| COMPLETED | Saved: times, date and period | Completed list | Repeatables go back to AVAILABLE when the period changes |
| FAILED | Saved | QUEST_UPDATE | Only with `time_limit_s` (events); everything else never fails |

Abandoning returns the quest to AVAILABLE, erases its quest items and saves nothing else. Dying fails nothing.

### 2.3 Requirements

All in `QuestRequirements` (sub-resource), evaluated by the pure shared `QuestRules.can_accept`:

| Requirement | Field | Example |
|---|---|---|
| Minimum level | `min_level` (default `level − 2`, at least 1) | The Squire's Choice: 10 |
| Realm | `realm_mask` (bits 1-3; 0 = all) | Vardheim thread: 1 |
| Previous quests | `requires_all`, `requires_any` | M04 requires M03 |
| Exclusive | `excludes` | The role trials among themselves |
| Not completed | implicit if not repeatable | |
| Flags | `flags_all`, `flags_none` | `vdh_spared_deserter` |
| Specialization | `specialization` (`none`, `any`, id) | The mentors' quests |
| War state | `realm_holds` (fortress ids) | "Supplies to Odd's Quarry" only if your realm holds it (phase 7, GUE-29) |
| Time window | `window` (seasonal events, later) | |

`QuestRules` does not read the clock (`scripts/shared` has no `Time`): it receives `now_unix` and the period from
the server (`ZonePlatform.now_unix()`).

### 2.4 Stages, chains and offers

- A quest is an ordered list of `QuestStage`. Each stage has objectives that must all be met, or `any_of = N` (N of
  M). Meeting the last stage turns the quest READY.
- Stage actions are closed like the objectives: `GIVE_ITEM`, `TAKE_ITEM`, `SET_FLAG`, `UNLOCK_LORE`, `SHOW_ECHO`,
  `NOTICE` (an id of `ServerMessages`). Nothing else.
- `chain` and `chain_order` group quests (for the journal and the validator). `offer_next` offers the next quest on
  turn-in, in the same window, if the giver is the same NPC or the next one is `auto_offer` (it arrives as a notice):
  fewer round trips.
- `starts_from_item`: a quest that starts by reading an item (a letter on a corpse).
- `revision` (integer). If the structure of a published quest changes, it is raised: whoever has it active goes back
  to the start of their current stage with counters at 0 and a notice (`quest.restarted`). Appending objectives at the
  end does not require raising it.

### 2.5 Group rules

| What | Rule |
|---|---|
| Sharing | Any member offers an active `shareable` quest to the members **in the same zone**. It reaches whoever meets the requirements and has not done it; on accepting, it starts at stage 0. One offer every 3 s per player |
| KILL | Contributors (at least 10 % of the damage, [progression.md](progression.md) §6.2) plus the living party members within 100 m of the death with an action in the last 60 s and the objective active |
| COLLECT | Every eligible player rolls their own drop; nobody takes anything from anybody |
| INTERACT with `group_credit_m` | Members within that distance with the objective active (lighting a brazier, opening a seal) |
| REACH, TALK, DELIVER | Individual |
| EVENT and war | By each one's own participation |
| Turn-in | Each one in person |

The same 100 m and 60 s rule gives party XP: see [social.md](social.md) section 3.

### 2.6 Coexistence rules

- **Changing data.** Ids are not reused or renamed (D17). With `retired = true`, whoever has the quest active loses it
  on entering (with a notice); completed ones still count as requirements.
- **Zones.** The state travels with the character on a handoff (TEC-30). An objective with `zone` only advances in
  that zone; the others, anywhere.
- **Alts.** Each character plays their own story (coins and progress are per character). An optional veteran shortcut
  (MUN-87, phase 9) skips M01-M02 if the account has a character of the same realm at level 10 or more.

## 3. Objectives, requirements and rewards

### 3.1 The objective

`QuestObjective` (sub-resource): `type`, `target` (id) or `target_tag` (tag), `count`, `zone`, `area`, `distinct`,
filters, `drop` (for COLLECT), `group_credit_m`, `marker` and `text`. Counters are `u16` (up to 65 535, enough for
amounts of healing or damage).

### 3.2 The catalog of 21 objective types

| # | Type | Event source | Parameters and filters | Arrives with |
|---|---|---|---|---|
| 1 | KILL | NPC dead with the player among the contributors (≥ 10 % in 900 ticks) or in their group within 100 m | `target` (an `NpcDefinition` id) or `target_tag` (family: `wolf`, `hollow`, `deserter`); filters `area`, `weapon_family`, `weapon_tag`, `min_distance_m` | MUN-17 (today: `on_npc_killed`) |
| 2 | COLLECT | Item in the bag or in the QUEST container | `item`; `drop = {from, chance, pity}`; `consume_on_turn_in` | MUN-17 (own quest drops) |
| 3 | INTERACT | Interactable used | `target` or `target_tag`, `distinct`, `group_credit_m` (e.g. 30) | MUN-16 |
| 4 | TALK | Dialogue node reached | NPC or role, node | MUN-18 |
| 5 | REACH | Entering an area (checked at 2 Hz) | `area` from the zone index | MUN-17 |
| 6 | DELIVER | Hand items to an NPC (TALK + removal) | `npc`, `item`, `count` | MUN-18 |
| 7 | USE_ITEM_AT | Use a quest item inside an area | `item`, `area` | MUN-16 |
| 8 | GATHER | Resource node harvested | resource or tag | PRG-26 |
| 9 | CRAFT | Item crafted | item or tag | PRG-27 |
| 10 | ECONOMY | Purchase, sale, deposit, repair | ledger reason (`EconomyReason`) | PRG-23, PRG-24, PRG-25 |
| 11 | COMBAT_ACTION | Block, parry, dodge through a hit, heal, stun, swap weapon, light or heavy hit on a target, damage to a structure | `action` (BLOCK, PARRY, DODGE_THROUGH, HEAL_AMOUNT, CONTROL, WEAPON_SWAP, LIGHT_HIT, HEAVY_HIT, STRUCTURE_DAMAGE), `target_tag`, `weapon_family`, `weapon_tag` | MUN-17 (`CombatDirector` events) |
| 12 | LEVEL | Reach a level, mastery or specialization | `level`, `mastery`, `specialization` | MUN-17 / PRG-18 |
| 13 | WAR_CAPTURE | Be on the capture list (`fortress_captured`) | `target` (fortress), `target_tag` (`fort`, `castle`) or any | MUN-17 (today: `on_capture`) |
| 14 | WAR_MERITS | Merits earned (objective or PvP) in a zone or fortress | reasons 3-5, `zone`, `target` | MUN-17 (today: `on_merits`, `on_objective_ticks`) |
| 15 | WAR_KILLS | Takedowns or assists that gave merits | `zone` | MUN-17 |
| 16 | EVENT | Take part in a world event with credit (tier at least bronze) or the event succeeds | `event`, `tier`, `success_only` | MUN-31 |
| 17 | COMMISSION | Complete N commissions (for the weeklies) | `count` | MUN-32 |
| 18 | QUEST_DONE | Complete another quest (or one from a list) | `targets`, `any` | MUN-17 (The Squire's Choice) |
| 19 | DISCOVER | Discover a point of interest | place id | PRG-22 |
| 20 | READ | Read a lore entry | `LoreEntry` id | MUN-16 |
| 21 | ESCORT | Keep an NPC alive along a route | n/a | Reserved (phase 8): needs NPCs that follow routes with players |

`weapon_tag` filters by the weapon tags of `weapons.md` (`two_handed`, `thrown`, `ranged`...), which the role trials
(section 10) use. `STRUCTURE_DAMAGE` counts damage to a structure with health (a gate, a training palisade).

**Quest drops.** `chance` per kill with **pity**: after `pity` consecutive failures the next one drops for sure. Rolled
with an RNG seeded by `(character_id, quest_id, kill_index)`, reproducible in tests. Starting figures: 0.6 and pity 2
for items "from every wolf", 0.5 and pity 3 for "rare" items, 1.0 for boss items.

### 3.3 Item choices

Each reward option carries weapon tags or an armor weight; the window highlights the one that fits what is equipped,
but any can be chosen (weapons are free).

### 3.4 Unlocks

`unlocks`: specialization, travel point (MUN-33), title, recipe. Each one is saved by **its own system**; the quest
only calls `grant_unlock`.

### 3.5 Time and levels

A quest has a `level` (the zone's band), and every NPC objective is within ±3 of it. Commissions use `Lp`, the player's
level clamped to the board's or zone's band.

### 3.6 Rewards

Rewards are **fractions of the hourly rate**. `r(L)` is the XP rate per hour of level `L` and `g_ref(L)` the reference
gold income per hour, both from `advancement.md` (`r(L) = 6000 · (1 + 0.1 · (L − 1))`; `g_ref` is 138 g/h at levels
1-10, 264 at 11-20, 441 at 21-30, 675, 896 and 1 152 at 51-60). `L` is the quest's level; `Lp` the player's, clamped
to the band. XP rounds to 10 and gold to 1. The table lives in `data/progression/quest_rewards.tres`, owned by the
progression domain:

| Kind | XP | Gold | Merits | Items |
|---|---|---|---|---|
| Main | 0.11 · r(L) | 0.08 · g_ref(L) | n/a | One in three: choose 1 of 3-4 |
| Act finale | 0.22 · r(L) | 0.16 · g_ref(L) | n/a | Choose 1 of 4, higher rarity |
| Side | 0.075 · r(L) | 0.05 · g_ref(L) | n/a | Consumables; sometimes a piece |
| Trial | 0.12 · r(L) | 0.08 · g_ref(L) | n/a | Specialization unlock, title |
| Daily PvE commission | 0.06 · r(Lp) | 0.04 · g_ref(Lp) | n/a | Zone material |
| War commission | 0.05 · r(Lp) | n/a | 50 | n/a |
| Call to arms | 0.05 · r(Lp) | n/a | 40 | n/a |
| War weekly | 0.35 · r(Lp) | 0.25 · g_ref(Lp) | 300 | War chest (PRG-33) |
| PvE weekly | 0.35 · r(Lp) | 0.25 · g_ref(Lp) | n/a | Choose 1 of 3 |
| Bounty | 0.08 · r(L) | 0.06 · g_ref(L) | n/a | Trophy of the rare (chance) |
| Event bronze / silver / gold | 0.05 / 0.08 / 0.12 · r(Lp) | 0.04 / 0.08 / 0.12 · g_ref(Lp) | In Eldrun 20 / 30 / 50 | Material (Ember Shard in the Ember Rain) |

- The event gold column keeps the proportions of the earlier draft on the new scale (0.5 / 1 / 1.5 times a main
  quest's gold); it is the least checked figure of the table.
- **Caps.** 6 daily commissions with full reward per day and character; the merits from commissions, calls to arms and
  weekly orders are at most **1 000 per week**.
- **Ledger.** Everything goes with reason `QUEST` (9, reserved in [progression.md](progression.md) §5.3) in one
  operation per turn-in, with `ref_kind` **5 = quest** (`ref_id` = u32 fingerprint of the id, the same function as
  `HandoffTicket.zone_key_of`). Events use the reason `WORLD_EVENT` (14) and `ref_kind` 6. Quest items are given with
  `QUEST` and withdrawn with the sink reason `QUEST_TURN_IN` (75). These codes are fixed in the common registry of
  [progression.md](progression.md) §5.3 and `advancement.md`.
- **Level 60.** The XP of a quest goes to veteran XP (D6).
- An override (`xp_override`, `gold_override`) passes the validator only between 0.5x and 2x of the formula.
- A quest with an empty reward ("by formula") pays the table's value for its kind and level. Example: a main quest
  at level 3 pays 790 XP and 11 gold.

## 4. Code systems

### 4.1 New pieces

| Layer | File | What |
|---|---|---|
| shared | `scripts/shared/quests/quest_definition.gd` | `QuestDefinition`, with `Kind`, `Repeat`, text fields, requirements, stages and rewards |
| shared | `quest_stage.gd`, `quest_objective.gd`, `quest_requirements.gd`, `quest_reward.gd`, `quest_item_choice.gd` | Sub-resources |
| shared | `quest_catalog.gd` | Loads `data/quests/**`, indexes by id, `wire_id` u16 in alphabetical order and `wire_hash()` (joins `NetProtocol.compute_sim_hash`, like `ItemDatabase.wire_hash()`) |
| shared | `quest_state.gd` | Pure state of a character: actives (stage, counters), completed (times, period), flags, lore read, tracked, period metadata |
| shared | `quest_rules.gd` | Pure: `can_accept`, `accept`, `apply_event`, `can_turn_in`, `turn_in` (returns the computed reward), `abandon`, `period_of(now_unix)` |
| shared | `quest_event.gd` | Normalized event: `kind`, `actor`, `target_id`, `tags`, `amount`, `zone`, `area`, `weapon_family`, `distance` |
| shared | `quest_validator.gd` | The validator (section 13.2), used by the test and the tool |
| shared | `scripts/shared/lore/lore_entry.gd`, `lore_catalog.gd` | `LoreEntry`: id, category (history, Echo, bestiary, letter), title, text, source |
| shared | `scripts/shared/events/world_event_definition.gd` (+ `event_phase.gd`, `event_wave.gd`) | World event definition (section 9) |
| shared | `scripts/shared/quests/commission_template.gd`, `commission_board.gd` | Templates and boards (section 8) |
| shared | `scripts/shared/net/quest_messages.gd` | Formats of section 5 |
| server | `scripts/server/game_event_bus.gd` | The bus (section 4.2) |
| server | `scripts/server/quests/quest_service.gd` | Like `ProgressService`: `setup(zone, platform, saver, commands)`, `prepare` with the claim, `on_arrival`, save section, requests, batched sending, listener index |
| server | `quests/player_quests.gd` | Live state of a player + the index `listen[type][key] → objectives` |
| server | `quests/quest_area_index.gd` | Grid of the zone's active areas, checked at 2 Hz |
| server | `quests/quest_commands.gd` | GM commands (section 4.6) |
| server | `quests/commission_service.gd` | Draw, boards, caps |
| server | `scripts/server/events/world_event_director.gd` | Schedules and runs the zone's events (section 9) |
| client | `scripts/client/quests/client_quests.gd` | State mirror, like `ClientProgress` |
| client | `scripts/client/quests/quest_tracker.gd`, `quest_journal.gd`, `quest_offer_panel.gd`, `quest_markers.gd`, `codex_view.gd`, `commission_board_window.gd`, `world_event_hud.gd` | UI (section 8) |
| client | `scripts/client/l10n/quest_text.gd` | Renders quest texts with context and markers |
| client | `scripts/client/bot_quest_scenario.gd` | `--bot-scenario=quests` (section 13.5) |
| tools | `tools/quests/` | Scaffold, review sheet, simulator and telemetry summary (section 13) |
| Go | `platform/internal/quests/` + migration | Store (section 6) |

`scripts/shared/quests`, `lore` and `events` enter the shared rules of `tests/test_architecture.gd`: they depend on
nothing in `scripts/server/` or `scripts/client/`.

### 4.2 The game event bus

`GameEventBus.emit(event: QuestEvent, actors: PackedInt32Array)`, synchronous inside the tick. Subscribers:
`QuestService`, `CommissionService` (inside the former), `WorldEventDirector` (credit) and, later, achievements
(PRG-42).

| Event | Emitted by | Where it hooks today |
|---|---|---|
| NPC_KILLED (def, contributors, position) | zone | Next to `_progress.on_npc_killed` (`zone_server.gd`) |
| PVP_MERITS (actor, amount, reason, victim) | zone | Next to `_progress.on_merits` |
| OBJECTIVE_TICKS, CAPTURED | `FortressController` | The `objective_time` and `fortress_captured` signals |
| LEVEL_UP | `ProgressService` | `after_level_change` and `_grant_xp` |
| ITEM_GAINED / ITEM_LOST | `ProgressService` | The inventory operations |
| COMBAT (HIT with result, HEAL, CONTROL, DODGE, SWAP, STRUCTURE_DAMAGE) | `CombatDirector.event_emitted` | Connected only while someone in the zone has a COMBAT_ACTION objective |
| INTERACTED, TALKED | MUN-16, MUN-18 | New |
| AREA_ENTERED | `QuestAreaIndex` | New, at 2 Hz |
| GATHERED, CRAFTED, ECONOMY | PRG-26, PRG-27, PRG-23 | New |
| EVENT_RESOLVED (event, participants with tier) | `WorldEventDirector` | New |

After TEC-65 (the split of `zone_server.gd` into `scripts/server/zone/`), the hooks go to the module that owns each
call; the bus does not change.

**Flow example.** A wolf dies in Hondal; two players of the same party, A (60 % of the damage) and B (at 40 m, no
damage, with an action in the last 60 s):

1. The zone already computes the contributors for XP. It adds the party members within 100 m and emits NPC_KILLED with
   `[A, B]`.
2. `QuestService` looks at `listen[KILL]["wolf"]` and `listen[KILL]["npc:wolf_grey"]` for A and for B: O(1) per player.
3. If the COLLECT objective of M03 is active, each one rolls their drop with their own seed.
4. The change is marked; QUEST_UPDATE leaves at most once every 10 ticks per player, like PROGRESS_UPDATE
   ([progression.md](progression.md) §6.3), and the `quests` section is dirty for the next save.

### 4.3 Performance budget

| Measure | Target | How it is measured |
|---|---|---|
| `QuestService` per tick, 200 players in Eldrun | ≤ 0.1 ms average, ≤ 0.5 ms p99 | `quests` section in `ServerMetrics` |
| Area checks | At 2 Hz and only for players with an active REACH in that zone; ≤ 5 areas per player | Test with 200 fake players |
| `WorldEventDirector` | ≤ 0.2 ms per tick, not counting the events' NPC AI (that goes in the AI section) | `ServerMetrics` |
| Messages | ≤ 1 QUEST_UPDATE every 10 ticks per player; the rest on change | Rate test |
| Saving | Typical delta section < 1 KB; a turn-in with reward = critical save | Size test |

Everything is per event: nothing walks all the quests of all the players every tick.

### 4.4 Existing files that change

| File | Change |
|---|---|
| `scripts/server/zone_server.gd` (or its modules after TEC-65) | Creates `GameEventBus`, `QuestService` and `WorldEventDirector`; emits at the hooks of section 4.2; routes QUEST_REQUEST |
| `scripts/server/progress/progress_service.gd`, `player_progress.gd` | `grant_quest_reward(net_id, reward, quest_id)` in one operation with reason QUEST; quest items; `XpSource.QUEST`; surplus XP to veteran XP at the cap |
| `scripts/shared/progression/economy_reason.gd` | 14 WORLD_EVENT, 75 QUEST_TURN_IN (and `ref_kind` 5 and 6 in the ledger) |
| `scripts/shared/progression/inventory_state.gd`, `inventory_ops.gd` | QUEST container (items domain) |
| `scripts/shared/ai/npc_definition.gd` | `tags` (family) and `level` (NPC domain; KILL by family asks for them) |
| `scripts/shared/net/net_protocol.gd`, `net_messages.gd` | Types 0x58-0x5D, version bump, catalog `wire_hash` |
| `scripts/shared/net/server_messages.gd` | Range 600-699 and the QUEST and EVENT parameter kinds |
| `scripts/server/platform/claimed_character.gd`, `zone_platform.gd` | The claim's `quests` key |
| `platform/...` (Go) | Envelope, claim, export, new store |
| `scripts/client/net_client.gd`, `hud.gd`, `marker_source.gd`, map and compass | Messages, tracker, markers |
| `tools/i18n` | The field table of [localization.md](localization.md) §8.1 |

### 4.5 Tests and architecture checks

Headless tests complete one quest of each implemented objective type with real zone events; the pure `QuestRules` has
table tests (accept, events, stages, any_of, turn-in, abandon, periods); `QuestValidator` runs on the whole catalog in
CI (section 13.2).

### 4.6 GM commands

With `--debug-commands` or the GM role, audited like those of [progression.md](progression.md) §10: `quest_give <id>`,
`quest_stage <id> <n>`, `quest_complete <id>`, `quest_reset <id>`, `quest_show [player]`, `quest_flag <flag>`,
`event_start <id>`, `event_stop`, `commission_day <offset>` (simulates the day change) and `lore_read <id>`. As with
the fortress commands, what they cause **pays nothing persistent** with a platform (marked "forced").

## 5. Protocol

Protocol version: **every lane that changes the format raises `PROTOCOL_VERSION` when it merges** (9, 10...); version 8
belongs to the server messages of [localization.md](localization.md) (L4a, TEC-57). The quest messages ship with the
next bump after it (TEC-69). All of them are reliable, on the same channel as the inventory messages 0x50-0x55.

### 5.1 Messages

| Type | Name | Dir. | Content |
|---|---|---|---|
| 0x58 | QUEST_LOG_FULL | S→C | On entry and on resync: actives (`u16 wire_id, u8 status, u8 stage, u8 n, n × u16`), tracked (≤ 5 × u16) and a page of completed (≤ 500 × u16, `u8 page, u8 pages`) |
| 0x59 | QUEST_UPDATE | S→C | `u8 count` + entries as above (≤ 22 B each) |
| 0x5A | QUEST_AVAILABLE | S→C | `u16 n` + wire ids available at the givers of this zone; recomputed on entry, on level up, on completing or abandoning and when the war state changes |
| 0x5B | QUEST_REQUEST | C→S | `u8 op` (1 ABANDON, 2 SHARE, 3 ACCEPT_SHARED, 4 DECLINE_SHARED, 5 TRACK_SET, 6 ACCEPT_BOARD), `u16 wire_id` (+ a list in TRACK_SET). Limit 4/s |
| 0x5C | QUEST_SHARE_OFFER | S→C | `u16 wire_id`, name of whoever shares it |
| 0x5D | COMMISSION_BOARD | S→C | On opening a board: `u16 board`, `u32 day`, drawn entries (template, parameters) and the state of each |

- **0x5E-0x5F are free.** The neighbors are 0x24-0x28 (interaction and dialogue) and 0x60-0x67 (build).
- Accepting and turning in at an NPC goes through the dialogue option of MUN-18 (the client sends the option index and,
  on turn-in, the index of the chosen reward; the server validates everything).
- World events use **OBJECT_STATE** (GUE-09) with a new type EVENT and a STRUCTURE for the event's center (section 9.5).
  No snapshot records.

### 5.2 Server messages

New range **600-699** in `ServerMessages` ([localization.md](localization.md) §7.1) and two new parameter kinds:
**8 QUEST** (u16; the client puts the title with context `quest`) and **9 EVENT** (u16; context `event`).

| Id | Key | Parameters | English template |
|---|---|---|---|
| 600 | `quest.accepted` | quest | Quest accepted: {quest} |
| 601 | `quest.objective_done` | quest | Objective complete: {quest} |
| 602 | `quest.completed` | quest | Quest complete: {quest} |
| 603 | `quest.shared` | name, quest | {name} shares a quest: {quest} |
| 604 | `quest.log_full` | n/a | Your quest log is full. |
| 605 | `quest.restarted` | quest | {quest} has changed and restarts its current step. |
| 610 | `commission.daily_cap` | n/a | You have finished today's commissions. Come back tomorrow. |
| 620 | `event.warning` | event, seconds | {event} begins in {seconds}. |
| 621 | `event.started` | event | {event} has begun! |
| 622 | `event.succeeded` | event | {event}: victory! |
| 623 | `event.failed` | event | {event} has failed. |
| 624 | `event.won_by` | event, realm | {realm} wins {event}. |
| 630 | `war.call` | quest | Call to arms: {quest} |

Those sentences hold a title as a parameter, never as a noun inside a sentence, so the Spanish gender is always right.

### 5.3 Ledger codes and containers

The registry that fixes these numbers for every document (details in [progression.md](progression.md) §5.3):

| What | Code |
|---|---|
| Source reason `WORLD_EVENT` | 14 |
| Sink reason `QUEST_TURN_IN` | 75 |
| `ref_kind` quest / world event | 5 / 6 |
| Container `QUEST` | 4 (0 BAG, 1 EQUIPMENT, 2 BANK, 3 LOOT_SATCHEL) |

## 6. Persistence

### 6.1 The `quests` section

Registered with `CharacterSaver.register_section(&"quests", build, acknowledge, is_dirty)`
([platform.md](platform.md) §14.3). It is a **delta** since the last confirmed `seq`, like the `ops` of `progress`; the
claim carries the full state and `QuestService.prepare` loads it before the WELCOME.

```json
"quests": {
  "quests_format": 1,
  "upsert": [{"id": "vdh_hondal_m04", "state": 1, "stage": 1, "counters": [3, 2], "rev": 1,
              "accepted_at_unix": 1793987200}],
  "completed": [{"id": "vdh_hondal_m03", "completions": 1, "completed_at_unix": 1793986000,
                 "period": 0, "reward_op": "48213"}],
  "removed": ["vdh_hondal_s05"],
  "flags_add": ["vdh_spared_deserter"],
  "lore_add": ["vdh_hondal_l07"],
  "meta": {"tracked": ["vdh_hondal_m04"], "daily_period": 20398, "daily_done": 3,
           "weekly_period": 2914, "weekly_merits": 250}
}
```

`state` in `upsert`: 1 ACTIVE, 2 READY, 3 FAILED; the completed ones go in their own list and the abandoned in
`removed`. The envelope also gains the `quests` section next to `progress` (database migration: the next free number
after the build's, with the items one following; the registry is in `advancement.md`).

### 6.2 Go store

`platform/internal/quests/`:

| Table | Key | Columns |
|---|---|---|
| `character_quests` | (`character_id`, `quest_id` text) | `state` smallint, `stage` smallint, `counters` smallint[], `rev` smallint, `accepted_at`, `completed_at`, `completions` int, `period` int, `reward_op_id` bigint null |
| `character_quest_flags` | (`character_id`, `flag` text) | `set_at` |
| `character_lore` | (`character_id`, `lore_id` text) | `read_at` |
| `character_quest_meta` | `character_id` | `tracked` text[], `daily_period`, `daily_done`, `weekly_period`, `weekly_merits` |

- It is applied in step 4 of [platform.md](platform.md) §7.3, **after** `ProgressStore.Apply` and in the same
  transaction. The envelope is strict (`DisallowUnknownFields`): the `quests` key is added to the Go envelope.
- **Checks Q1-Q6.** Q1 format and ids (`^[a-z0-9_]{3,48}$`); Q2 a completed non-repeatable quest never goes back to
  ACTIVE nor raises `completions` above 1 (the zone exports `quest_rules.json` with the repeatables and their period,
  like the rules of [progression.md](progression.md) §13.4); Q3 `counters` ≤ 8 and ≥ 0; Q4 `reward_op` exists in the
  `ops` of this body or in `economy_ops`; Q5 sizes (≤ 30 actives, ≤ 64 flags and ≤ 64 lore per body); Q6
  `daily_done` ≤ 6 per period.
- GDPR export ([platform.md](platform.md) §11.2): the four tables. Purge: with the character.
- **Critical save** ([progression.md](progression.md) §9.2 keeps the list): a turn-in with gold or items, the
  specialization chosen and an act finale. The rest goes in the 60 s checkpoint.
- With no platform, the state is in memory, like the ephemeral inventory ([progression.md](progression.md) §9.4).

## 7. Text and data format

### 7.1 Files and ids

```
data/quests/<realm>/<zone>/<id>.tres     vardheim, solmarch, askarra; zone = ZoneDefinition id
data/quests/shared/spec/<id>.tres        specialization trials (all realms)
data/quests/war/<id>.tres                war commissions, weekly orders and calls to arms
data/quests/_templates/<archetype>.tres  templates (not loaded in the game)
data/commissions/<board_id>.tres         boards and their templates
data/lore/<realm>/<zone>/<id>.tres
data/events/<event_id>.tres
data/progression/quest_rewards.tres      table of section 3.6 (progression)
```

Id convention: `<realm>_<zone>_<letter><nn>`, with `m` main, `s` side, `b` bounty, `c` commission, `l` lore. The
realm prefix is `vdh`, `sol` or `ask`. Trials are `all_spec_<role>` and war quests `war_<zone>_<nn>`. Examples:
`vdh_hondal_m04`, `vdh_isenholm_s13`, `vdh_hondal_l07`, `all_spec_vanguard`, `war_vado_gris_01`.

### 7.2 Text fields and contexts

They are the quest rows of the table in [localization.md](localization.md) §8.1; each `.tres` keeps the English and
the Spanish goes in `locale/es.po`.

| Script | Field | Context | Limit |
|---|---|---|---|
| `QuestDefinition` | `title` | `quest` | 32 characters |
| | `summary` (one line for the journal) | `quest_summary` | 90 |
| | `description` (the offer) | `quest_desc` | 600 |
| | `progress_text` (if you come back unfinished) | `quest_progress` | 200 |
| | `completion_text` (on turn-in) | `quest_done` | 400 |
| | `translator_note` | n/a (comes out as `#.`) | Who speaks, tone, where it is seen |
| `QuestObjective` | `text` | `quest_obj` | 48, with `{count}` and `{total}` if it counts |
| `QuestStage` | `text` (optional) | `quest_stage` | 90 |
| `LoreEntry` | `title`, `text` | `lore_title`, `lore` | 40, 1200 |
| `DialogueDefinition` | line, option | `dialogue`, `dialogue_option` | 300, 60 |
| `WorldEventDefinition` | `display_name`, `description`, phase text | `event`, `event_desc`, `event_phase` | 32, 300, 90 |
| `CommissionTemplate` (each entry of the pool) | `title`, objective | `commission`, `quest_obj` | 32, 48 |
| `NpcDefinition` / named NPC | `display_name`, `title` | `npc`, `npc_title` | n/a |

### 7.3 Text rules

1. **Never build a sentence around a noun placeholder.** "Hunt {count} {target}" does not translate well ("Caza 8
   lobos", but "Caza 8 jabalíes", "Mata a 8 desertores"). Each entry carries its whole sentence and only numbers:
   `Wolves hunted: {count}/{total}` → `Lobos cazados: {count}/{total}`. Person names only as a NAME parameter.
2. One context per field (above); the extractor does not mix them.
3. The validator checks the markers: an objective with `count > 1` carries `{count}` and `{total}`; one with 1,
   neither.
4. Text with balance numbers: markers filled from the data (rule 6 of [localization.md](localization.md) §8.1).
5. The translator note is mandatory on dialogues and descriptions: who speaks and in what tone.
6. Invented names stay (Granvik, Hondal, Eldhald); descriptive ones are translated (los Desjurados → the Forsworn).
   The glossary is in [localization.md](localization.md) §8.2.

### 7.4 Example

`data/quests/vardheim/hondal/vdh_hondal_m04.tres` (abridged to the shape; the real file declares every sub-resource):

```
[resource]
script = ExtResource("1_def")
id = &"vdh_hondal_m04"
kind = 1
chain = &"vdh_act1"
chain_order = 4
zone = &"hondal"
level = 3
giver = &"hondal_ingrid"
turn_in = &"hondal_ingrid"
shareable = true
offer_next = true
requirements = SubResource("req")
stages = Array[ExtResource("2_stage")]([SubResource("stage_1"), SubResource("stage_2")])
reward = SubResource("rew")
title = "The Asbjorn Farm"
summary = "Find out what happened at the Asbjorn farm."
description = "Nobody has come down from the Asbjorn farm in three days. Their cart is still in the square and their dog will not stop howling. Go up the north road and tell me it was wolves, Squire. Tell me anything but what I fear."
progress_text = "Well? Was it wolves?"
completion_text = "Gray rags and no blood... The dead do not come down from Eldhald. They have not done so since my grandmother was a girl."
translator_note = "Speaker: Ingrid, Granvik's reeve. Tired, practical, frightened underneath. Addresses the player as Squire."
```

Its stage 1 has a REACH objective (`area = &"hondal_area_asbjorn_farm"`, text "Reach the Asbjorn farm") and an
INTERACT one (`target_tag = &"hondal_farm_clue"`, `count = 3`, `distinct = true`, text "Clues examined:
{count}/{total}"); stage 2, a TALK with Kari and a KILL of 5 `hollow` in the farm area (text "Hollow destroyed:
{count}/{total}").

The matching part of `locale/es.po`, generated by the extractor and filled by hand or by an agent:

```
#. Speaker: Ingrid, Granvik's reeve. Tired, practical, frightened underneath. Addresses the player as Squire.
#: data/quests/vardheim/hondal/vdh_hondal_m04.tres
msgctxt "quest"
msgid "The Asbjorn Farm"
msgstr "La granja de Asbjorn"

msgctxt "quest_obj"
msgid "Clues examined: {count}/{total}"
msgstr "Pistas examinadas: {count}/{total}"
```

## 8. Journal, tracker and commissions

### 8.1 Journal and tracking (UI-29, UI-82)

| Piece | What it does | Reuses |
|---|---|---|
| Tracker (HUD, right) | Up to 5 tracked quests: title, objectives of the stage with counter and distance to the nearest marker; met ones are struck through for 2 s and disappear. At 30 % opacity in combat | `UiPalette`, UI-55 composition |
| Journal (L) | Tabs: Active (by act and zone), Completed, Commissions, Chronicle. Detail with description, objectives, rewards and the buttons Track, Share and Abandon (with confirmation) | UI-09 |
| Chronicle | The lore read and the Echoes, by realm and zone, with the gaps that remain ("3 of 5 in Eldhald") | `LoreCatalog` |
| Offer and turn-in | Inside the dialogue (UI-28): description, objectives, rewards with the item choice, Accept/Decline; on turn-in, the closing text and the choice | MUN-18 |
| Markers | Over the giver: "!" available, "?" ready to turn in, gray if you lack the level (2 levels). Objectives of tracked quests on compass and screen; areas as circles on the map and minimap | `WorldMarker`, `MarkerSource`, `Compass` (UI-19), map (UI-21) |
| Notices | Accepted, objective done, completed, shared, log full | `NotificationCenter` (UI-08) |
| World event | A band with phase, time, wave and progress; the event marker on compass and map | Section 9.5 |

The end of UI-29 per the backlog: a quest of a PvE zone is accepted, tracked and turned in with the interface alone.
The first version (increment Q4) already shows the tracker with the Vado Gris quests, before NPCs with dialogue exist.
The journal, the Chronicle and the markers move to UI-82; the offer and the turn-in close with UI-28.

### 8.2 Boards

| Board | Where | What it offers | Phase |
|---|---|---|---|
| Granvik | Hondal | 3 PvE commissions of levels 1-10 | 6 |
| Isenholm | Market square | 3 commissions of the player's band (Hondal 1-10, Skarven 10-20) | 6 |
| Wolf Gate garrison | Border | 2 war commissions of the Vado Gris (phase 6) and of Eldrun (phase 7) + weekly orders | 6-7 |
| One per town of each PvE zone | Zones 10-60 | 3 PvE of the zone | 8 |

- **Draw.** Deterministic (D15): `day_index = floor((now_unix − 4 · 3600) / 86400)`; week = `floor((day_index − 4) / 7)`
  (Unix day 0 was a Thursday and day 4 a Monday, so the week starts on Monday). Each board takes 3 entries from its
  pool with the seed `hash(realm, board_id, day_index)`.
- Up to 3 can be accepted at once; **full reward for the first 6 of the day** (on any board); after that the board says
  "come back tomorrow" (notice 610). No reroll.
- The period counters live in `meta` (section 6.1); the day change resets what was not turned in.

### 8.3 Templates

`CommissionTemplate`: one entry per possible commission, with its whole text (rule 7.3.1), objective type, target,
quantity per band (`count_by_level`) and zone. The draw produces a "virtual" `QuestDefinition` in memory
(`c_<board>_<entry>_<day>`) that the core treats like any other quest; it is persisted as template + day.

Pool of the Vado Gris war board:

| Entry | Objective | Quantity |
|---|---|---|
| Defend the Ford | WAR_MERITS of objective type in `vado_gris` | 30 |
| Break the Gate | COMBAT_ACTION `STRUCTURE_DAMAGE` (the enemy fort's gate) | 3 000 |
| Blood of the Front | WAR_KILLS in `vado_gris` | 3 |
| Take the Fort | WAR_CAPTURE `vado_gris` | 1 |
| The Captain's Head | KILL `ford_captain` or `realm_captain` | 1 |

### 8.4 Weekly orders, bounties and calls to arms

- **Weekly orders** at the garrison: one of war (e.g. "earn 300 objective merits at the front", "take part in 3
  captures") and one PvE (complete 10 commissions). Reward in section 3.6 (0.35 r and 0.25 g_ref, 300 merits for war).
- **Bounties** next to the lair of each named rare: kill the rare, cooldown 20 h, a trophy with some probability. In
  Hondal: Greyfang and Fencebreaker.
- **Calls to arms** (phase 7, with GUE-29): when a fortress of your realm is under attack, everyone in the realm at
  level 20 or more (Eldrun's minimum) gets an offer (notice 630) that expires after 15 min: earn 20 objective merits at
  that fortress. 40 merits and 0.05 r of XP; at most 3 a day. Since the credit comes from real defense merits (D11), an
  agreed attack pays no more than it already would (and GUE-35 watches it).

## 9. World events (MUN-31)

### 9.1 Framework

`WorldEventDefinition`: id, zones, schedule (`interval_min_s`, `interval_max_s`, seed), possible points (markers of
the zone index), radius, phases, waves, phase objectives, scaling, credit and rewards by outcome and by participation
tier.

| Phase | What | Duration |
|---|---|---|
| WARNING | Notice to the whole zone (620), marker and a visible effect | Per event |
| ACTIVE | Sub-phases with event objectives: waves, protect a structure, hold a circle, destroy objects, kill a boss | Per event, capped |
| RESOLUTION | Result (622/623/624), distribution, NPC cleanup (the living leave in 10 s) | 10 s |

- **Scaling.** Wave size and boss health depend on `P`, the living players within 80 m of the center at the start of
  each wave, capped.
- **Credit.** Participation points for at least 60 s in the radius during ACTIVE **and** at least one action (at least
  1 % of the damage to an event NPC, a heal on a participant or 5 objective merits). Bronze = 1 sub-phase with credit,
  silver = 2, gold = all (+ success or the realm's victory). Without an action, merely being there does not count
  (anti-AFK).
- **Schedule.** The next one starts `random(interval_min, interval_max)` after the previous one ends, with the zone's
  seed; it is not persisted (a zone restart reschedules). Only with at least 1 player in the zone.
- **Reuses** `NpcSpawnerSystem` with dynamic spawn groups, the circle logic of `FortressPresence`, structures with health
  (GUE-10) and OBJECT_STATE.

### 9.2 Ember Rain (Eldrun, phase 7)

| Parameter | Starting value |
|---|---|
| Frequency | Every 45-90 min (MUN-71) |
| Points | 6 neutral, at least 150 m from any fortress and 300 m from the gates |
| Warning | 180 s: a trail in the sky visible from all of Eldrun, a notice in Eldrun and, with GUE-29, in the zones of the three realms |
| Waves | 3, one every 120 s; size `clamp(4 + floor(P / 2), 4, 16)`; in the 3rd, a **Hollow Herald** (elite) |
| NPC cap | 24 alive at once (AI budget of MUN-29) |
| Domination | 180 s in a 20 m circle under the Ember: each second the realm with the most living players inside scores 1 point (tie: nobody) |
| Victory | The realm with the most points: **+30 Embers** to the treasury (GUE-22; a fort gives 1 per minute) |
| Participants | Merits 20 / 30 / 50 (those of the winning realm, gold tier), XP of section 3.6, 1 **Ember Shard** (upgrade material, PRG-37) |
| Cap | One Rain reward per hour and character |

Eldrun opens at level 20 and is normalized, so the same rewards are earned at any level above that.

### 9.3 The Hollow Incursion (Hondal, phase 6)

| Parameter | Starting value |
|---|---|
| Frequency | Every 90-150 min with at least one player in the zone |
| Warning | 120 s: Granvik's bell and the notice "The Hollow are coming down from Eldhald" |
| Objective | Protect the **Granvik Pillar** (structure, 20 000 health) and defeat 3 waves and the **Hollow Standard-Bearer** within 8 min |
| Waves | Every 150 s; size `clamp(3 + P, 3, 10)`; the Hollow go for the Pillar if no player is within 8 m |
| Success | Rewards of section 3.6 and "Granvik's Gratitude": +10 % NPC XP for 30 min (PvE zones only) |
| Failure | A Hollow camp occupies the square for 15 min or until it is cleared; meanwhile Granvik's merchants close |

### 9.4 Templates for the next zones (phase 8, MUN-86)

Same framework, five archetypes: defense of a place (like the Incursion), rare world boss (an announced beast), rift
(close 3 points with channeling under waves: Askarra, Ash Wastes), caravan (once ESCORT exists) and contested gathering
(a rare resource that blooms in a clearing). One event per PvE zone.

### 9.5 Network and HUD

One STRUCTURE per active event (ENTITY_SPAWN with the definition's id) and an OBJECT_STATE of type EVENT with the
fields: 1 phase, 2 phase end (tick), 3 wave, 4 total waves, 5 progress (0-255), 6 structure health, 7 maximum health,
8-10 points per realm. Like the forts: at most one every 6 ticks with what changed. The HUD band (UI-84) reads them.

## 10. Quests and the war

| Moment | Level | What | Non-blocking alternative |
|---|---|---|---|
| Baptism of Fire (Act I, M12) | 10 | First visit to the front: the Vado Gris, by the provisional pass from Hondal | `any_of`: a capture, 30 objective merits or 5 fort defenders (the Hollow or enemy guards) |
| War commissions | From 10 | Garrison board (section 8.3) | Optional |
| End of Act II | 20 | Entry to Eldrun with the realm | `any_of`: a capture, a defense with 20 merits or an Ember Rain with credit |
| End of Act IV | 45 | First siege of a castle (GUE-23, phase 7) | `any_of`: 100 merits at a castle or 2 weekly orders |
| Act V (borders) | 45-55 | Frontier war thread | `any_of`: an assault with merits or 2 weekly orders |
| Act VI | 55-60 | Aldcor (GUE-31) | `any_of`: enter the first ring during an assault, or the gold credit of an Ember Rain |
| Calls to arms | Eldrun's minimum (20) | Defense of an attacked fortress of your own | Optional, 3 a day |

The acts map to the zone bands as in [story.md](story.md) section 3; the war moments of Acts II-VI are a first
proposal and are fixed when their zones are built.

Rules:

- Credit only from events that gave merits (D11), and never with `--fake-players`, GM-forced changes or marked
  characters ([progression.md](progression.md) §6.2).
- **Normalization** (PRG-31) does not touch rewards, which go to the character. Items from war quests come from the
  quartermaster's tables (PRG-33), already normalized.
- **The Vado Gris at level 10.** Level does not matter there (the zone is normalized at effective level 60), so a level
  10 is not at a disadvantage. The provisional pass from Hondal to the Vardheim camp opens at minimum level 10 (D21).
- **Availability by war state** (`realm_holds`): quests that only exist while your realm holds a fortress (phase 7).
- **Askarra** has no test front (the Vado Gris is between Vardheim and Solmarch): its Baptism waits for Eldrun or for
  its own cut of the south front. Until then its M12 uses the PvE alternative.

## 11. Quests and specialization

The number and names of the specializations are in `advancement.md`: **Vanguard, Linebreaker, Hunter, Healer and
Arcanist**, plus the **Sapper** in phase 7. The first choice is free and requires a role trial; afterwards it is
changed only in the capital, with the **Master of the Orders**, out of combat, for `8·L + 20` gold with no cooldown
(about 25-30 minutes of income at any level). There is one Master per capital and **one mentor per specialization**,
who gives the trial and the flavor.

### 11.1 "The Squire's Choice"

M11 of each realm (in Vardheim "The Squire's Choice"; in Solmarch "The Vow"; in Askarra "The Contract"), minimum level
10, in the Hall of Arms of the capital:

1. Stage 1, TALK with the Master of the Orders: the dialogue presents the specializations; choosing one accepts its
   trial (trials are `excludes` among themselves; abandoning a trial allows choosing another).
2. Stage 2, QUEST_DONE of the chosen trial.
3. Stage 3, TALK: the dialogue action `CHOOSE_SPECIALIZATION` grants the specialization and its ultimate. Reward: a
   title ("Squire of Isenholm"), a tabard trim for the role and an item choice.

### 11.2 The trials

Shared by the three realms (`all_spec_*`), giver by role `role:spec_mentor`. Four trials in the first slice:

| Role | Trial | Objectives | Needs |
|---|---|---|---|
| Vanguard | Hold the Line | COMBAT_ACTION BLOCK 15 hits from hostile NPCs; CONTROL 3 enemies | CMB-12, CMB-13 |
| Hunter | The Hunter's Path | KILL 6 with `min_distance_m = 15`; KILL 1 named beast | CMB-23, MUN-24 |
| Healer | Hands of the Guard | COMBAT_ACTION HEAL_AMOUNT 4 000 to allies, including the wounded allied NPCs of the Hall of Arms infirmary | CMB-47 (healing to allies), curable NPCs |
| Linebreaker | Break the Palisade | COMBAT_ACTION HEAVY_HIT 10; KILL 8 with `weapon_tag = two_handed` or `thrown`; COMBAT_ACTION STRUCTURE_DAMAGE 2 000 on a training palisade | CMB-53, weapon tags |

- The **Arcanist** trial ("The Spark of Eld": KILL 10 with `weapon_family = fire_staff`; destroy 3 corrupted totems)
  arrives with the fire staff (CMB-35), right after the first slice.
- The trial of the other specializations stays as an optional quest for their title and trim.
- Changing later: in the capital, with no quest, for the gold cost above (D13).
- Role mastery quests at levels 25, 40 and 55: cosmetic (title, look) and lore of the role; nothing of power (D14).
- The mentors and the Master are named NPCs of the capital's Hall of Arms; the infirmary has the allied wounded that
  the Healer trial needs (a healing target the server treats as an ally, not an enemy).

## 12. The story in numbers and the first chain

The story bible and the full Hondal chain (cast, places, 13 main quests, 15 side quests, 21 lore texts, the Granvik
board and the Incursion) are in [story.md](story.md) section 6. Their reward figures follow section 3.6:

- Main quests at levels 1-10 pay 0.11 · r(L): from 660 XP and 11 gold (level 1) to 1 250 XP (level 10); the act
  finale (m13) pays 2 510 XP and 22 gold; the trial, 1 370 XP and 11 gold.
- The side quests pay 0.075 · r(L): from 500 to 770 XP and 7 gold each.
- Together the 28 quests are about **23 600 XP** and about 270 gold (with the trial). With the kills they ask for and
  the discoveries, a new character reaches level 4.4 on delivering m04, 7.2 on m07, 9.8 on m10 (with every side quest
  up to level 8 and the discovered places), 10.3 on m11 (level 10 required) and 10.9 on m13.
- Split in 1-10: quests 71 %, kills 24 %, discovery 5 %. With the main quests alone a character gets about half of what
  is needed: side quests, the board or hunting are required. The main thread teaches; it does not suffice.
- Time: about 4.8 h of content (12 minutes per main quest, 8 per side quest) against 3.5 h of the reference curve; the
  gap is the margin of the simulator and of the quest bot, which decide the final figure with real runs.

Unique quests needed per band if they give this share of the band's XP (main 40 %, side 60 %):

| Band | Share of the XP | Unique quests | Fit of the zones |
|---|---|---|---|
| 1-10 | 55 % | 22 | 20-25 |
| 10-20 | 35 % | 25 | 20-25 |
| 20-32 | 30 % | 33 | 30-35 |
| 32-45 | 25 % | 36 | 30-35 |
| 45-60 | 15 % | 29 | 25-30 + dailies |
| **Per realm** | | **about 146 + about 8 of the capital, about 150** | |

About 450 across the three realms; Acts V and VI share structure between realms (about 40 % less cost). From level 45
the XP comes mostly from war (25 %), kills (30 %), repeatables (15 %) and dungeons and events (15 %).

## 13. Tools to produce at scale

### 13.1 Archetype templates

`data/quests/_templates/` with eight commented archetypes (hunt, collect with drop, investigate with stages, deliver,
explore and read, named boss, trial, war). `tools/quests/quest_new.gd` (headless) copies one with id, zone, level,
giver and texts, and saves it with `ResourceSaver` so the `.tres` always comes out valid.

### 13.2 Validator (`QuestValidator`, `tests/test_quest_catalog.gd`)

| Group | Checks |
|---|---|
| Ids | Unique; the convention of section 7.1; never deleted: `data/quests/published_ids.txt` (like `data/characters/appearance_ids.txt`) lists the published ones, and one missing from the catalog fails (it is marked `retired`, not deleted) |
| References | NPCs, families, items, interactables, areas and markers (zone index, section 13.8), zones, fortresses, dialogues, lore, events, specializations |
| Graph | Requirements without cycles; every main quest reachable from the realm's first; no orphans; symmetric `excludes`; consistent `offer_next` |
| Levels | `level` within the zone's band; requirements with level ≤ its own; target NPCs within ±3 of the quest level; `min_level` ≤ `level` |
| Rewards | By formula or override between 0.5x and 2x; items with `required_level` ≤ level + 1; repeatables without a gold cycle (what is bought to deliver is not worth more than what is paid; hook of PRG-29) |
| Text | Limits of section 7.2; correct `{count}`/`{total}` markers; msgid that does not look Spanish; entry in `es.po` (strict mode); translator note on descriptions and dialogues |
| Feasibility | A KILL has spawners of that family in the area with `alive_max` and `respawn_s` that allow finishing in ≤ 10 min alone; a COLLECT needs on average ≤ 2.5 × `count` kills; areas and interactables reachable by the navigation mesh (the zone validator of MUN-45) |
| Commissions | Every entry of every pool produces a valid quest at all its levels |

It fails in CI. Smoke test: a quest with a deliberately seeded broken reference must fail.

### 13.3 Bilingual review sheet

`tools/quests/quest_sheet.gd` generates, per chain, an HTML (or Markdown) with: the chain diagram, one card per quest
with level, giver, objectives, computed rewards and the text in English and Spanish side by side (read from `es.po`).
It is what the user reviews (in Spanish) and what is captured for the devlog.

### 13.4 Flow simulator

`tools/quests/quest_flow_sim.gd`: walks the quests in order of availability, adds XP from quests, from the kills they
require (XP per NPC from PRG-22) and from discovery, estimates the time (distances between markers of the index at 5 m/s
plus the kill time of `tools/combat_balance.gd`) and gives level and hour at each main quest. It outputs CSV and a
chart. Criterion per zone: with main + side + discovery, the entry level of the next band ± 0.5, and The Squire's Choice
available at level 10 with nothing more. The overall leveling simulator (`simulate_leveling.gd`) fails if a band
drifts more than ±10 %.

### 13.5 Quest bot

`--bot-scenario=quests` (pattern of `BotProgressScenario`): follows the journal, goes to the marker, kills, interacts,
talks and turns in. Two modes: `teleport` (with a teleport DEBUG_COMMAND; fast, for CI: checks logic and references)
and `walk` (walks with the navigation mesh; nightly: checks reach and times). JSON report with each quest, time and
failures. It is the criterion of MUN-28 and MUN-46.

### 13.6 Telemetry

`quest_log.jsonl` on the server (accepted, objective, turned in, abandoned, with times), like the battle log of
GUE-17, and `tools/quests/summarize_quests.gd`: abandonment rate and median time per quest. It feeds TEC-44 and MUN-70.

### 13.7 Checklist of a finished quest

1. `.tres` from a template; 2. extractor and `es.po`; 3. validator green; 4. review sheet; 5. bot in `teleport` mode;
6. capture of the offer, objective and turn-in in Spanish and English (archived in `Eldmark-capturas`). Expected pace:
5-7 quests per agent session; a zone (about 30 quests + lore + board) in 5-6 sessions.

### 13.8 The zone index

The validator and the server read a baked **zone index** (markers, areas, interactables, spawners, named NPCs) without
loading the scene (MUN-62, coordinated with MUN-45). It is also what the quest bot uses to find its way.

## 14. Dependencies with other domains

| Domain | What is needed | For |
|---|---|---|
| Progression | Level curve to 60 (`LevelCurve`); owner of `quest_rewards.tres`; reasons 14 and 75 and `ref_kind` 5 and 6; surplus XP to veteran XP; `grant_unlock` and where unlocks are saved | Section 3.6, D6 |
| Classes and weapons | Specialization catalog and the `CHOOSE_SPECIALIZATION` action; weapon families and tags for the filters (`fire_staff`, `two_handed`...); healing to allied NPCs (CMB-47); no ability depends on quests | Section 11, D14 |
| Items | QUEST container; quest item category (bound, worthless); choice sets per band (weapons and armor weights); Ember Shard; item level per quest level | D8, section 3.6 |
| NPCs | `NpcDefinition.tags` and `level`; non-hostile roles (giver, Master of the Orders, mentor, board); MUN-18 with the quest conditions and actions (below); named NPCs placed; curable wounded soldiers; named rares (MUN-25); event elites (Herald, Standard-Bearer); event AI within the budget of MUN-29 | Sections 3.2, 9 |
| World | `ZoneDefinition` with a level band (MUN-13); **baked zone index** read by the server and the validator; the places of Hondal (MUN-22), Isenholm (MUN-21), the provisional pass (MUN-23); discovery and travel points (PRG-22, MUN-33) | Story section 6, section 13.2 |
| War | GUE-29 (war state in all zones) for calls and `realm_holds`; merit filters (PRG-09, GUE-35); the Embers treasury (GUE-22); Eldrun's minimum level; Aldcor (GUE-31) | Section 10 |
| Social | SOC-06 (parties), SOC-23 (party credit), SOC-22 (cross-zone parties) | Section 2.5 |
| Platform | Envelope and claim with `quests`, store, export; TEC-30 (handoff); TEC-57 (`ServerMessages`) | Sections 5, 6 |
| Localization | TEC-55 (extractor) with the field table; the glossary | Section 7 |
| Interface | UI-27, UI-28, UI-19, UI-21, UI-08, UI-42 | Section 8 |
| Art | ART-26 (civilian NPCs; only Peasant and Ranger are free), quest icons (ART-12), Echo, Ember and Ember Rain VFX, ART-79 and ART-80 | Sections 8, 9 |

**Contract with the dialogue (MUN-18).** Conditions: `QUEST_STATE(id, state)`, `QUEST_STAGE(id, n)`, `FLAG(id)`,
`LEVEL(min)`, `SPECIALIZATION(id|none|any)`, `REALM_HOLDS(fortress)`. Actions: `OFFER(quest)`, `TURN_IN(quest, choice)`,
`TALK_OBJECTIVE(quest, objective)`, `SET_FLAG(flag)`, `OPEN_BOARD(board)`, `CHOOSE_SPECIALIZATION(spec)`, `OPEN_SHOP`
and `TRAVEL`. All of them go through `QuestRules`, which the server evaluates before executing.

## 15. Backlog and production order

### 15.1 Items

Rewritten (existing ids): **MUN-17** Quest core on the server (F6); **MUN-28** Zone 1-10 quests and realm story;
**MUN-46** Side quests and lore of zone 1-10; **MUN-31** World events (the framework and the Hollow Incursion, F6; Ember
Rain moves to MUN-71, F7); **MUN-32** Daily and repeatable commissions (PvE in F6; Eldrun in MUN-72, F7); **UI-29** is
split (tracker and notices stay; the journal, Chronicle and markers go to UI-82; the offer and turn-in close with
UI-28); **PRG-22** gets the 55 % target of quests in 1-10 and the simulator of section 13.4; **PRG-42** uses
`GameEventBus` and the Echo collection.

New ids:

| Id | Title | Phase |
|---|---|---|
| MUN-62 | Zone index bake for quests | F6 |
| MUN-63 | Quest persistence: `quests` section and Go store | F6 |
| MUN-64 | Quest data tools: templates, scaffold, validator and bilingual review sheet | F6 |
| MUN-65 | Quest flow simulator | F6 |
| MUN-66 | Quest bot scenario | F6 |
| MUN-67 | Group quests: sharing and group credit | F6 |
| MUN-68 | "The Squire's Choice" and the role trials | F6 |
| MUN-69 | Lore codex and Echoes of Eld | F6 |
| MUN-70 | Quest telemetry | F6 |
| MUN-71 | Ember Rain in Eldrun | F7 |
| MUN-72 | War commissions, weekly orders and calls to arms | F7 |
| MUN-83 | Main story Act II | F8 |
| MUN-84 | Acts III-IV | F8 |
| MUN-85 | Acts V-VI | F8-F9 |
| MUN-86 | One world event per PvE zone | F8 |
| MUN-87 | Veteran shortcut for alts | F9 |
| TEC-69 | Quest protocol and `ServerMessages` 600-699 | F6 |
| UI-82 | Quest journal, codex and markers | F6 |
| UI-83 | Commission board | F6 |
| UI-84 | World event HUD | F6 |
| ART-79 | Quest presentation | F6 |
| ART-80 | Named NPCs of Hondal and Isenholm | F6 |

### 15.2 Increments

Each increment fits one or two sessions and ends with green tests and its captures (Spanish and English wherever there
is text), archived in `Eldmark-capturas`.

| # | Increment | Needs | Checked with |
|---|---|---|---|
| Q1 | Data model, catalog, validator v0 and 4 Vado Gris quests ("Clear the Ford", "The Ford Captain", "Scout the Front", "Baptism of Fire") | n/a | `test_quest_catalog`; capture of the review sheet |
| Q2 | Pure `QuestState` and `QuestRules` with table tests | Q1 | Tests |
| Q3 | `GameEventBus`, `QuestService` in the zone, rewards with `ProgressService`, GM commands | Q2 | Headless test with bots in the Vado Gris; chat notice capture |
| Q4 | Protocol, `ClientQuests` and the HUD tracker | Q3, TEC-57 | Capture of the tracker "Hollow destroyed: 3/5" in the Vado Gris, in es and en |
| Q5 | Persistence: `quests` section, Go store, Q1-Q6 | Q3 | End-to-end reconnect test; capture of the same progress on return |
| Q6 | Journal, empty Chronicle, markers on compass and map | Q4 | Captures of the journal and marker |
| Q7 | Tools: templates, sheet, simulator, bot in `teleport` mode | Q4 | Simulator chart; bot report |
| Q8 | Group: sharing and credit | Q3, SOC-06 | Two bots; capture of the shared offer |
| Q9 | INTERACT, TALK, DELIVER and the offer and turn-in in the dialogue | MUN-16, MUN-18, UI-27, UI-28 | Capture of the offer window with the item choice |
| Q10 | Hondal m01-m05 | MUN-22 (layout and spawners), MUN-24 | Bot in `walk`; one capture per quest (giver, objective, turn-in) |
| Q11 | Hondal m06-m10, Eldhald lore and Echo I | Q10, Chronicle | Captures of the Echo and the boss |
| Q12 | Isenholm: m08-m09, s13, s15 | MUN-21, TEC-30 | Captures of the walk |
| Q13 | The Squire's Choice and the four trials | Specialization (classes) | Capture of the choice |
| Q14 | m12-m13: the Baptism in the Vado Gris | MUN-23 | Capture of the tracker at the fort |
| Q15 | Hondal side quests | Q11 | The bot completes them all (MUN-46 criterion) |
| Q16 | PvE boards of Granvik and Isenholm | MUN-32 | Board capture; day-change test |
| Q17 | Event framework and the Hollow Incursion | MUN-31 | Captures of the warning, waves and success |
| Q18 | (F7) Ember Rain | GUE-22, MUN-29 | Bots of three realms; capture of the trail and the circle |
| Q19 | (F7) Eldrun war commissions, weekly orders and calls to arms | GUE-20, GUE-29 | Capture of the call in the capital |
| Q20+ | (F8) Act I of Solmarch and Askarra, then Acts II-VI | Their zones | Validator, bot and simulator per zone |

## 16. Risks

| Risk | Mitigation |
|---|---|
| Volume (about 150 quests per realm from 1 to 60, about 450 in all) exceeds what can be produced | Templates, generated commissions, Acts V-VI with shared structure, tools before content; one complete realm 1-10 before opening the next |
| Custom quests sneak in (code per quest) | D2: the validator and the review reject any quest that is not data; a new objective type is a backlog item |
| Many phase 6 dependencies (MUN-16, MUN-18, MUN-19, MUN-22, MUN-25, TEC-30) delay everything | Q1-Q8 are done in the Vado Gris with what exists; Hondal's content starts when its zone has spawners |
| Weak text or rigid translation (English msgid, Spanish-speaking author) | Tone guide, mandatory translator note, bilingual sheet reviewed by the user in Spanish |
| Data change while players are mid-quest | `revision`, `retired`, ids never reused, objectives appended at the end |
| Duplicate rewards from retries or crashes | Turn-in and reward in the same transaction with `reward_op` and idempotence `(lease_id, seq)` |
| Gold loops with repeatables | Validator (section 13.2) and PRG-29 |
| Farming of war quests (agreed kills, uncontested captures) | D11: only what gave merits counts; weekly cap of 1 000; GUE-35 |
| Story blocked by the war state or the population | D10, `any_of` alternatives |
| Performance in Eldrun with 200 players and events | Everything per event, areas at 2 Hz, events capped at 24 NPCs and measured in `ServerMetrics` |
| Few free outfits to tell named NPCs apart | Hairstyles, beards, dyes and accessories of ART-19; own silhouette only for the 3-4 important ones |
| The Healer trial needs to heal allied NPCs, which does not exist today | Explicit dependency on CMB-47; meanwhile the trial counts healing to party players |
