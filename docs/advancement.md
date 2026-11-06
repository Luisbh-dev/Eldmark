# Eldmark · Phases 6-8: character advancement design

Design of how a character grows once the game has PvE content: the level curve 1-60 and its XP sources (PRG-46, PRG-22),
what a level gives (PRG-47), attributes (PRG-17), weapon mastery (PRG-18), talent trees (PRG-19), specializations and
ultimates (PRG-49, PRG-50, CMB-56, PRG-64), what comes after level 60 (PRG-62, PRG-32, PRG-37), the power normalization of
Eldrun (PRG-31), the PvE scale contract that NPC design consumes, the persistence of the build (PRG-48) and the data tools
(PRG-51, PRG-52). It also fixes the quest reward table, because the XP curve decides it.

It supersedes the parts of [progression.md](progression.md) that fix the level cap at 40 (§6.1), the phase 5 XP sources (§6.2)
and the rule that level changes nothing (§0). Items, equipment, loot, crafting and the economy are in [items.md](items.md).
This document is the integrated design that closes the proposal of the content-design session; where a number differs from an
earlier proposal, the integrated one wins and the "Why" column says so.

It builds on what is merged: the save model, the ledger and the levels of phase 5 ([progression.md](progression.md) §3, §5,
§6), abilities, effects and `CombatState` v5 ([abilities.md](abilities.md) §2, §3), the damage formula and the first balance
pass ([combat.md](combat.md) §4.4, §12), the world by zones ([world.md](world.md)) and the platform store
([platform.md](platform.md) §7). Weapons, abilities and their catalog are in `weapons.md`; NPC ranks, bestiary and AI in
`npcs.md`; quests in `quests.md` (all written in the same pass). Code paths are relative to the repository root.

Clock note: the simulation runs at **60 Hz** and snapshots at 30 Hz ([networking.md](networking.md) §1,
`physics_ticks_per_second=60`). Durations in this document are seconds in the `.tres` files and become ticks on load with
`roundi(s · tick_rate)`, as [combat.md](combat.md) §0 requires, so they stay valid if a zone drops to 30 Hz.

Everything marked **provisional** is a first number to be measured (`tools/combat_balance.gd`, the leveling simulator, the bots),
not a promise.

---

## 0. Decisions

I01-I03 are the user's (2026-11-06); I64 was chosen for the content as a whole. The "#" column is the id of the integrated
design. Decisions that only the user can close are marked "user" in the Why column.

| # | Question | Decision | Why |
|---|---|---|---|
| I01 | Classes? | **Free weapons + specialization** at level 10: any weapon, two at once with Q; mastery and a talent tree per weapon family. Replaces "No classes" of [combat.md](combat.md) §0 | The user's choice: class identity without locking weapons |
| I02 | Level cap? | **60**. Replaces the provisional 40 of [progression.md](progression.md) §6.1 | The user's choice |
| I03 | Which specializations? | **Five** in phase 6: Vanguard, Linebreaker, Hunter, Healer, Arcanist. A sixth, the **Sapper**, in phase 7 with the siege (GUE-25) | They cover the five roles of a mass action war (line, breakthrough, range, support, area). A "Herald" (support and control) was proposed and dropped: the Vanguard banner and the Arcanist controls cover it, and each specialization costs ranks, an ultimate, VFX, a trial, a mentor and an icon |
| I04 | How are ranks earned? | **By character level**: I at 10, II at 20, III at 30, IV at 40 (improved ultimate), V at 50. In normalized zones, rank V | Changing specialization never forces re-leveling |
| I05 | Choosing and changing | The first choice is **free** and needs the role trial (quest "The Squire's Choice", level 10). After that it changes **only in a capital**, with the **Master of the Orders**, out of combat, for `8·L + 20` gold, no cooldown. One Master per capital and **one mentor per specialization** (gives the trial and the flavor) | The proposals asked for one instructor per specialization and for a single Master: both stay, with different roles. The price is 25-30 min of income at any level (§9) |
| I06 | What is an ultimate? | A **slot of its own**, key **F**, button `ULTIMATE` = bit 13 of `PlayerInput`; cooldown **150 s**, not reset on respawn and saved as timer `ability:<id>`; cap of **10 targets**; one generic summon clip and an ember VFX per specialization. The id travels in LOADOUT v2 and `ultimate_ready` in `CombatState` | 120 s was proposed: with 150 s and 150 players Eldrun gets one ultimate per second (2 with 300), which CPU and readability stand |
| I07 | Who sees the specialization? | **Allies only** (nameplate and party frame). The enemy sees the weapon and the ultimate when it is cast | Coherent with [social.md](social.md) §1 (the enemy's level and gear are hidden) |
| I08 | Attributes | Strength, Dexterity, Intelligence, Focus and Constitution (`str`, `dex`, `int`, `foc`, `con`); base 5, **2 points per level** (118 at level 60); damage factor `(1 + 0.004·P + 0.002·S) / 1.35`; CON +3 health per point and **never** a weapon attribute; thresholds 25/50/75/100. Respec free until level 19, then `5·L` gold | The weapons proposal gave the hammer CON as secondary: changed to Dexterity, because CON would count twice. The Focus mana-regeneration bonus is dropped (it would be a per-character predicted value, I21) |
| I09 | Mastery | **Per weapon family, levels 0-20** (21 110 XP), only from credit events (kills and merits, never hitting), split by contribution between the two weapons; one talent point per mastery level: **20 points** | The weapons proposal counted 19 points |
| I10 | Talent tree | 2 branches × 6 rows × 15 nodes (30 per weapon), a single capstone reachable with 20 points (11 + 9). Row *f* opens with points in the branch `[0, 2, 4, 6, 8, 10]` and level `[1, 1, 8, 14, 20, 25]`. Budget **≤ 8 %** of efficacy per tree | 10 % was asked: with 8 % the normalization closes (§10) |
| I11 | Abilities per weapon | **5 active** (3 base and 1 opened by each branch, in row 2) **plus up to 2 variants** (`<id>_2`, one per branch, row 4). Carry **3 per weapon**, chosen freely out of combat | Production: 50 actives at launch instead of 70. The other 20 sheets of the weapons proposal stay as data reserve (`ability_pool` admits 15) |
| I12 | Unlocks by level | Ability slots at levels 1, 3 and 6; 4th and 5th ability (row 2) from 8; specialization and ultimate at 10; rows 3-5 at 14, 20 and 25 (§3) | It is the "abilities unlocked by level" request. Weapon-level 5/15/30 was proposed: the tree rows are used instead |
| I13 | Curve | Generated: pace `r(L) = 6000·(1 + 0.1·(L − 1))` XP/h and minutes per level `m(L) = 8 + 8.5·√(L − 1)`; `xp_to_next = round10(r·m/60)`; **1 327 340 XP, about 50 h** (§1) | 59 h in four 15-level bands was proposed, and about 40 h by the world design. It is anchored on the content hours of each world band |
| I14 | XP sources | Fractions of `r(L)` (per hour): normal NPC 0.006, main quest 0.11, side 0.075, act finale 0.22, trial 0.12, daily 0.06, discovery 0.02, merit 0.0025, capture 0.05, dungeon 0.5. **Gold** in fractions of `g_ref(L)` (§2.6) | The quests proposal used fractions of `xp_to_next(L)`: with minutes per level growing, a 12-minute quest would be worth half an hour of pace at high level. In `r(L)` time is preserved |
| I15 | At the cap | The overflow XP goes to **veteran XP**: one Veteran Seal (currency 3, per character) per 40 000 XP; horizontal rewards and a few Ember Shards per week | The quests proposal turned quest XP into mastery at 60: dropped (two paths for the same thing). "Ember dust" for equipment is replaced by the Ember Shards of items.md |
| I16 | Group XP | Each member within 100 m with an action in the last 60 s receives the **whole** XP | Progression, NPC and quest proposals agree |
| I17 | War ranks | Realm points (PRG-32): 0 / 1 500 / 5 000 / 12 000 / 25 000 / 45 000 / 75 000 / 120 000 / 180 000 / 260 000; horizontal only | — |
| I18 | What anchors the balance? | The **reference character** is today's numbers: level 60, attributes 75/25 and CON 33 (143 in total), **item level 52** gear in every slot, medium armor. It gives health 1000, damage factor 1.0, stamina 1000, sword 90/90/130 and a TTK of 10.7 s. The weapon `.tres` are at the reference | Items (today's numbers at item level 1 and ×2.77 at 60), weapons (×1.47 at 60) and NPCs (health from 1000 to 3655) anchored today's numbers at level 1. With the anchor at 60, the normalized zones (Vado Gris, Eldrun) play exactly the balance measured in [combat.md](combat.md) §12 and no balance test changes |
| I19 | Item scale | See [items.md](items.md): item level 1-60 per instance, effective level `NOe = NO + upgrade`, all item stats multiplied by `k(NOe) / k(52)`; equipment score 600 at level 60 and 700 at most | One scale instead of the GS 100 → 500 → 600 of the earlier proposal |
| I20 | Health and mitigation | Base health `600 + round(301·(L − 1)/59)` (615 at level 1 with CON 5; 1000 the reference). Mitigation **relative to the reference**: `final = raw · (1000 + armor_ref) / (1000 + armor)`, with `armor_ref` = medium set at item level 52 (393 physical) | Health scaled by the item level was proposed and rejected: progression decides health |
| I21 | What may differ per character | Only the **weapons** (LOADOUT), the **ability slots** (`ability_picks`), the **ultimate**, **mana** (magic weapons only) and the **load class**. **Passives, talents, attributes, specialization and affixes touch server values only** (damage, mitigation, healing, effects, controls, block cost). Whatever must change a predicted field (cooldown, timings, displacement, projectiles) is a **catalog variant** | The earlier proposal sent per-character cooldowns in BUILD_STATE with the tick they apply: removed. Fewer prediction divergences |
| I22 | Normalization | In zones with `ZoneDefinition.normalized = true` (Eldrun, Vado Gris, `test_world`): effective level 60, **total attributes rescaled to 143** keeping proportions, `NOe_eff = clamp(52 + 0.2·(NOe − 50), 52, 54)`, non-attribute affixes and gems at ×0.25 with a **joint cap of 3 %**, PvE affixes at 0, real mastery and talents (≤ 8 %), elixirs and food inactive. Product of caps **1.139 ≤ 1.15**, measured with bots (§10) | The items proposal clamped the item level to [55, 65] and scaled affixes ×0.75: 11 % from gear alone, it did not close |
| I23 | Entry | Vado Gris from **level 10** (normalized skirmish, the "Baptism of fire" of the story); Eldrun from **level 20** (10 h of play), normalized | With everything normalized, entering early only gives up mastery and talents, which are bounded. 20 matches the end of zone 2 |
| I24 | PvE scale | A player "at their level" (60/20/20 split, own-level gear, medium armor) has offense `O(L)` and effective health `D(L)` relative to the reference (§11). **NPCs of level L have health ∝ O(L) and damage ∝ D(L)**; in normalized zones, the reference (1.0). A normal NPC dies in 8-12 s and kills an undefended player in 25-35 s | NPC design had a provisional health of 1000 to 3655 and a normal that killed in 20-33 s; progression had 35-50 s |
| I64 | Data format | **Numeric tables** (curve, XP sources, mastery, items, loot, recipes, vendors, affixes and, from T2, the bestiary figures) are written in **CSV** and a deterministic generator writes the `.tres` with a "generated" header, with a test that requires the repo to be its output. **Structured content** (weapons and abilities, trees, specializations, quests, dialogues, bosses, `ZoneLayout`) are typed `.tres` written by hand or scaffolded, with a validator and a round-trip CSV export for balancing | Each side is right in its field: weapons wanted the `.tres` as the single source, items the CSV. Closes "In what format are design data created and balanced?" |

---

## 1. The level curve 1-60 (PRG-46)

### 1.1 Pace

The generator (the data is the table; the formula only fills it in, as in [progression.md](progression.md) §6.1):

- **Reference pace** `r(L) = 6000 · (1 + 0.1 · (L − 1))` XP/h: what a typical player of level L earns in an hour (mix of quests,
  camps, events and war). 6000 at level 1, 41 400 at level 60.
- **Minutes per level** `m(L) = 8 + 8.5 · √(L − 1)`: 8 min from 1 to 2, 72.7 min from 59 to 60.
- `xp_to_next(L) = round10(r(L) · m(L) / 60)`, rounding to the nearest ten.

| Band | Zone | Hours | Cumulative | XP of the band | Content that fills it |
|---|---|---|---|---|---|
| 1-10 | Z1 (Hondal) | 3.5 h | 3.5 h | 31 080 | Act I: 13 main quests, 15 side quests, lore, board, Raid |
| 10-20 | Z2 (Skarven) | 6.5 h | 10.0 h | 92 730 | Zone 2 3-4 h, D1, Vado Gris, commissions |
| 20-32 | Z3 (Grimfell) | 10.0 h | 20.0 h | 208 090 | Zone 3 5-6 h, D2, Eldrun |
| 32-45 | Z4 (Hrimvald) | 12.9 h | 32.9 h | 365 650 | Zone 4 5-6 h, D3, D4, Eldrun |
| 45-60 | Frontier (Marca del Lobo) | 17.2 h | **50.1 h** | 629 790 | Frontier 5 h, D5, D6, Eldrun, repeatables |

Milestones: specialization and Vado Gris at 3.5 h; Eldrun (level 20) at 10 h; capstones (level 25) at 13.9 h; level 60 at about
50 h. The world design estimated 22-25 h of open world: the rest is filled by dungeons, Eldrun and repeatables, which is what a game
whose heart is the war needs. Whether 50 h is right is a question for the user (the curve is a table and is re-tuned with data
from real play).

### 1.2 The table (`data/progression/level_curve.tres`, `level_cap = 60`, 59 values)

| L → L+1 | XP | Total to reach L | Minutes at pace |
|---|---|---|---|
| 1 | 800 | 0 | 8.0 |
| 2 | 1 820 | 800 | 16.5 |
| 3 | 2 400 | 2 620 | 20.0 |
| 5 | 3 500 | 7 970 | 25.0 |
| 9 | 5 770 | 25 310 | 32.0 |
| 10 | 6 360 | 31 080 | 33.5 |
| 15 | 9 550 | 69 150 | 39.8 |
| 20 | 13 060 | 123 810 | 45.1 |
| 25 | 16 880 | 196 640 | 49.6 |
| 30 | 20 970 | 289 110 | 53.8 |
| 32 | 22 680 | 331 900 | 55.3 |
| 40 | 29 930 | 538 320 | 61.1 |
| 45 | 34 770 | 697 550 | 64.4 |
| 50 | 39 820 | 881 420 | 67.5 |
| 55 | 45 100 | 1 090 990 | 70.5 |
| 59 | 49 460 | 1 277 880 | 72.7 |
| **60** | — | **1 327 340** | — |

The 59 values, in full: 800, 1820, 2400, 2950, 3500, 4050, 4610, 5180, 5770, 6360, 6980, 7600, 8240, 8890, 9550, 10230, 10920,
11620, 12340, 13060, 13800, 14560, 15320, 16090, 16880, 17680, 18480, 19300, 20130, 20970, 21820, 22680, 23550, 24440, 25330,
26230, 27140, 28060, 28990, 29930, 30880, 31840, 32800, 33780, 34770, 35760, 36760, 37780, 38800, 39820, 40860, 41910, 42960,
44020, 45100, 46170, 47260, 48360, 49460. Total up to 60: **1 327 340**.

- It fits a `PackedInt32Array` and the `u32` of PROGRESS_UPDATE ([progression.md](progression.md) §12); `total_to(60)` = 1 327 340.
- **Generated, not typed**: `tools/progression/build_tables.gd` reads `data/progression/src/levels.csv` (level, pace, minutes,
  manual adjustment, `g_ref`, `O`, `D`, §11) and writes `level_curve.tres`, `level_rewards.tres`, `xp_sources.tres`,
  `mastery_curve.tres` and `pve_scale.tres`. Deterministic; `tests/test_progression_tables.gd` checks that the repo files are the
  tool's output (as the Vado Gris terrain is), so balancing is editing a spreadsheet (I64).
- **Migration from the cap 40** (migration 0011, §13): `character_progress.level` becomes `check (level between 1 and 60)` and the
  same migration **recomputes `level` from `xp_total`** with the new curve (a CTE of thresholds generated by `build_tables.gd`).
  Levels move in both directions (an old level 10, 25 060 XP, becomes 8; an old 40, 783 780 XP, becomes 47). They are phase 5
  test data, which [progression.md](progression.md) §5.1 already allows wiping; the level is recomputed anyway so that invariant
  I8 holds.

---

## 2. Experience sources (PRG-22)

### 2.1 Sources as fractions of `r(L)` (`data/progression/xp_sources.tres`, generated)

Everything is expressed through `r(L)`, so the pace of every source survives a change of the curve.

| Source | XP | Level 1 | Level 10 | Level 30 | Level 60 | Rule |
|---|---|---|---|---|---|---|
| Normal NPC (× rank × difference) | `0.006 · r(L)` | 36 | 68 | 140 | 248 | Credit by contribution ([progression.md](progression.md) §6.2); in a group, I16 |
| Main / side quest | `0.11 / 0.075 · r(L_quest)` | 660 / 450 | 1 254 / 855 | 2 574 / 1 755 | 4 554 / 3 105 | Level of the quest, not of the player |
| Act finale / trial | `0.22 / 0.12 · r(L_quest)` | 1 320 / 720 | 2 508 / 1 368 | — | — | Acts I-VI and the role trials |
| War merit | `rvr_xp_per_merit(L) = 0.0025 · r(L)` | 15 | 29 | 59 | 104 | Replaces `XP_PER_MERIT = 10`; same victim and forced-change conditions as [progression.md](progression.md) §6.2 |
| Daily commission / gold event | `0.06 / 0.12 · r(L)` | — | 684 / 1 368 | 1 404 / 2 808 | 2 484 / 4 968 | §2.6 |
| Discover a place | `0.02 · r(L)` | 120 | 228 | 468 | 828 | Once per character and place |
| Capture | `0.05 · r(L)` | 300 | 570 | 1 170 | 2 070 | Same `capture:<id>` timer of 30 min |
| Dungeon completed | `0.5 · r(L)` plus its kills | 3 000 | 5 700 | 11 700 | 20 700 | Once per instance |
| Gather a node | `0.002 · r(L)` | — | — | — | — | So that gathering is not wasted time, not to level |
| Craft a recipe for the first time | `0.03 · r(L)` | — | — | — | — | Only the first: crafting in series gives no XP (it would turn gold into XP) |
| GM | `xp_add` | | | | | [progression.md](progression.md) §10 |

`xp_reward > 0` in an `NpcDefinition` stays a fixed value (the Vado Gris ones). Values are rounded half up.

### 2.2 NPC rank multipliers

The eight ranks of `npcs.md` (I53); health ×0.4/1/2/6/10/25/45/120, XP and mastery as below. Mastery follows the XP proportion
(10 per normal, §6).

| Rank | XP × | Mastery XP | Normal-NPC XP at L1 | at L30 | at L60 |
|---|---|---|---|---|---|
| Minion | 0.25 | 3 | 9 | 35 | 62 |
| Normal | 1 | 10 | 36 | 140 | 248 |
| Strong | 2 | 20 | 72 | 281 | 497 |
| Elite | 6 | 60 | 216 | 842 | 1 490 |
| Named | 12 | 120 | 432 | 1 685 | 2 981 |
| Boss | 25 | 250 | 900 | 3 510 | 6 210 |
| Dungeon boss | 40 | 400 | 1 440 | 5 616 | 9 936 |
| World boss | 60 | 600 | 2 160 | 8 424 | 14 904 |

The minion's 2.5 mastery rounds up to 3.

### 2.3 Level difference (`NPC level − player level`)

Applies to NPC XP and to mastery XP. In combat the PvE damage adjustment is separate (±4 % per level beyond ±2, capped at ±40 %,
[combat.md](combat.md) / `npcs.md`).

| ≤ −8 (gray) | −7…−5 | −4…−3 | −2…−1 | 0 | +1…+2 | +3…+4 | ≥ +5 |
|---|---|---|---|---|---|---|---|
| **×0 (0 XP and 0 mastery)** | ×0.40 | ×0.70 | ×0.90 | ×1.00 | ×1.08 | ×1.15 | ×1.20 |

- Gray NPCs give nothing and do not attack first. The earlier proposal gave ×0.10: 0 is clearer and removes farming.
- **Quests** use the same table with a floor of ×0.25 and no gray: an old quest still serves the story.

### 2.4 Group, overflow and the war

- **Group (SOC-23, I16):** each member within 100 m with an action (damage, healing, blocked damage as the target) in the last 60 s
  receives the whole XP, with no splitting and no bonus. Splitting would punish grouping, and group content is already faster.
- **At the cap:** `ProgressionRules.add_xp` returns `overflow`, what does not fit in the curve, and it goes to `veteran_xp` (§9).
- **War:** the merit XP uses the real level also in normalized zones.

### 2.5 Expected mix and the leveling simulator

The mix is a check, not a rule: `tools/progression/simulate_leveling.gd` takes a player with this mix per band and fails if the
hours of a band differ more than ±10 % from §1.1. It runs also with the real sources of each zone when they exist.

| Band | Quests | Kills | Repeatables | Dungeons and events | War | Discover, gather, craft |
|---|---|---|---|---|---|---|
| 1-10 | 71 % | 24 % | — | — | — | 5 % |
| 10-20 | 35 % | 30 % | 15 % | 15 % | — | 5 % |
| 20-45 | 25-30 % | 30 % | 15 % | 15 % | 10 % | 5 % |
| 45-60 | 15 % | 30 % | 15 % | 15 % | 25 % | — |

Check with Hondal (the 29 quests of `quests.md`, in order, with the kills they ask for × 1.3 and 12 places discovered):

| Milestone | Level |
|---|---|
| m04 delivered | 4.4 |
| m07 delivered | 7.2 |
| m10 delivered (with every side quest up to 8) and the discoveries | ~9.8 |
| m11 ("The Squire's Choice", minimum level 10) | ~10.3 |
| m13 (end of Act I) | ~10.9 |

In 1-10 quests give 71 %, kills 24 % and discoveries 5 %. The main quests alone reach half of it: side quests, the board or
hunting are needed, as the quest design intends. The content time is about 4.8 h (12 min per main quest, 8 per side quest) against
3.5 h of the curve: the difference is the margin of the simulator and of the quest bot, which decide the final figure with real
runs.

Unique quests needed per realm if they give this share of the XP of their band (main 40 %, side 60 %):

| Band | Share of the XP | Unique quests | What fits (world design) |
|---|---|---|---|
| 1-10 | 55 % | 22 | 20-25 |
| 10-20 | 35 % | 25 | 20-25 |
| 20-32 | 30 % | 33 | 30-35 |
| 32-45 | 25 % | 36 | 30-35 |
| 45-60 | 15 % | 29 | 25-30 plus dailies |
| **Per realm** | | **≈ 146 + ~8 of capital ≈ 150** | |

About 450 across the three realms; acts V and VI share their structure between realms (−40 % cost). In 45-60 the XP comes mostly
from war (25 %), kills (30 %), repeatables (15 %) and dungeons and events (15 %).

### 2.6 Quest rewards (`data/progression/quest_rewards.tres`, owned here)

`quests.md` names the **kind** of a quest and this table gives its reward; a quest never carries a raw number of XP or gold. XP
is a fraction of `r(L_quest)` and gold a fraction of `g_ref(L_quest)` (gold per hour of the reference player, defined in
[items.md](items.md) §15; 138 g/h in 1-10 up to 1 152 in 51-60, interpolated linearly between band midpoints). Merits are fixed.

| Kind | XP (× `r`) | Gold (× `g_ref`) | Merits | Notes |
|---|---|---|---|---|
| Main quest | 0.11 | 0.08 | — | |
| Side quest | 0.075 | 0.05 | — | |
| Act finale | 0.22 | 0.16 | — | |
| Role trial | 0.12 | 0.08 | — | |
| Daily PvE commission | 0.06 | 0.04 | — | 6 per day, each with the whole reward (`quests.md`) |
| War commission | 0.05 | — | 50 | War merits do not raise realm points; ≤ 1 000 merits/week from quests |
| Call to arms | 0.05 | — | 40 | |
| Weekly order | 0.35 | 0.25 | +300 for war orders | |
| Bounty | 0.08 | 0.06 | — | |
| World event, bronze | 0.05 | 0.04 | — | Event reward tiers by participation |
| World event, silver | 0.08 | 0.06 | — | |
| World event, gold | 0.12 | 0.10 | — | |

Examples (XP): main quest 1 254 at level 10, 2 574 at 30, 4 554 at 60; weekly order 3 990 at level 10 and 14 490 at 60; gold
event 1 368 / 2 808 / 4 968. Gold examples with `g_ref(10) ≈ 195`, `g_ref(30) ≈ 546`, `g_ref(60) = 1 152`: main quest 16 / 44 / 92,
side quest 10 / 27 / 58, weekly order 49 / 137 / 288. Hondal (29 quests) pays about **320 gold** of quests and ~100 of kills in
~4.5 h, against 807 that a reward of `10 + 4L` per main quest would have given: 4 times what the economy foresees.

The quest proposal gave XP as fractions of `xp_to_next(L)`; with fractions of `r(L)` a quest is worth the same amount of
*time* at every level, which is what keeps the level at the end of Hondal on target.

---

## 3. What a level gives (PRG-47)

Every level gives **+2 attribute points** (§5) and base health (§4). In addition (`data/progression/level_rewards.tres`; in
normalized zones every row reads level 60):

| Level | Opens |
|---|---|
| 1 | Both weapon slots (Q), **ability slot 1**, potions (R, T) and mastery 0 in every family |
| 3 | **Ability slot 2** |
| 6 | **Ability slot 3** |
| 8 | Row 2 of the trees: the **4th and 5th ability** of each weapon (with 4 points in the branch) |
| 10 | **Specialization** (rank I) and the **ultimate (F)**; zone 2; **Vado Gris** |
| 14 | Row 3 |
| 15 | D1 Ossuaries of Eld |
| 20 | Row 4 (variants); **rank II**; **Eldrun**; zone 3; reassigning attributes stops being free |
| 25 | Row 5 (**capstones**) |
| 30 | **Rank III** |
| 32 | Zone 4 |
| 40 | **Rank IV** (improved ultimate) |
| 45 | Frontier |
| 50 | **Rank V**; upgrades +6…+10 on items of item level ≥ 50 |
| 60 | Cap: veteranship, equipment score up to 700 with upgrades |

- The level-up notice (UI-30) lists the row of that level; ENTITY_EVENT 16 LEVEL_UP does not change.
- **Bar:** 3 slots per weapon (keys 1-3) × 2 weapons (Q) + F = **7 active buttons**, as `PlayerInput` already foresees.
- Production at launch: 10 weapons × 5 = **50 actives**, ≤ 20 variants, 5 ultimates (+1 of the Sapper) and 300 talent nodes with
  about 40 passives from a closed set (§7.3).

---

## 4. Base health and the reference character (I18, I20)

- `base_health(L) = 600 + round(301 · (L − 1) / 59)`: 600 (level 1), 646 (10), 697 (20), 722 (25), 748 (30), 799 (40), 850 (50),
  **901 (60)**.
- `max_health = base_health(L) + 3 · CON + equipment health` (CON is the total, with the base 5): 615 at level 1 with CON 5.
- **Stamina is 1000 at every level** and for everyone: it is the defensive resource of an action game ([abilities.md](abilities.md)
  §0) and it is predicted. Only the equipment load changes dodge distance and regeneration delay ([items.md](items.md) §3).
- **Reference character** (`StatBlock.reference_for(weapon)`): level 60, main attribute 75, secondary 25, CON 33 and the other two at
  5 (sum 143), equipment of **item level 52** in all 11 slots, medium armor, no talents and no specialization. Health
  901 + 99 = **1000**, damage factor **1.0**: exactly today's figures. The weapon `.tres` are at the reference.
- `armor_ref` is the medium set at item level 52: 393 physical (and 347 elemental, derived by the same law from the elemental
  value of the set at item level 60). **Mitigation relative to the reference**:
  `final = raw · (1000 + armor_ref) / (1000 + armor)`, so that the reference character takes today's damage and the existing balance
  tests ([combat.md](combat.md) §12, [abilities.md](abilities.md) §2.4) give the same numbers byte for byte.
- Load classes against the reference: light (183 armor at item level 52) takes ×1.18 damage, heavy (612) ×0.86 ([items.md](items.md) §3).

---

## 5. Attributes (PRG-17)

`data/progression/attributes.tres`.

- Five: **Strength (`str`), Dexterity (`dex`), Intelligence (`int`), Focus (`foc`) and Constitution (`con`)**.
- **Base 5** and **2 points per level** from level 2: 118 to spend at level 60, 143 in total, 123 at most in one.
  `LevelCurve.attribute_points_per_level` goes from 1 to 2; free points stay derived ([progression.md](progression.md) §6.3), so
  there is no migration of points.
- **Each weapon scales with a primary and a secondary attribute** (`WeaponDefinition.primary_attribute`, `secondary_attribute`).
  CON is never a weapon attribute: it would count twice.

| Weapon | Primary | Secondary |
|---|---|---|
| Sword and shield | STR | DEX |
| Bow | DEX | STR |
| Hatchet | STR | DEX |
| Life staff | FOC | INT |
| Fire staff | INT | FOC |
| Crossbow | DEX | INT |
| Frost gauntlet | INT | FOC |
| War hammer | STR | DEX |
| Greatsword | STR | DEX |
| Spear | DEX | STR |
| Twin daggers (after launch) | DEX | INT |
| Great axe (after launch) | STR | DEX |

- **Damage (or healing) of the active weapon:** `factor_atr = (1 + 0.004 · P + 0.002 · S) / 1.35` (1.35 is the reference's). At level 1
  (5/5): 0.763. With everything in the primary: 1.113.
- **CON:** +3 health per point. The coefficient equals the marginal value of offense and defense at the reference (d ln O ≈
  d ln D ≈ 0.003 per point): the damage × health product of any complete split falls between −6 % and 0 % of the best. Splitting
  is choosing a role, not gaining power.
- **FOC** has no mana effect. The mana-regeneration bonus of the earlier proposal (+0.3 % per point) is removed, because mana
  regeneration would be a per-character predicted value (I21); its threshold at 50 becomes a server-only effect (below).

**Thresholds** (on the total of the attribute; small passives of the closed set of §7.3; magnitudes provisional):

| | 25 | 50 | 75 | 100 |
|---|---|---|---|---|
| STR | +5 % damage to structures | +0.1 s stagger on heavy targets | +4 % damage of heavy attacks | The guard break you cause stuns +0.2 s |
| DEX | Backstab ×1.5 → ×1.55 | +10 % duration of the slows you apply | Backstab ×1.6 | Your projectiles ignore 10 % of the armor |
| INT | +3 % elemental damage | Your damage over time lasts +1 pulse | +5 % elemental damage | Your elemental hits apply −5 % mitigation for 3 s (ICD 6 s per target) |
| FOC | +3 % healing | Allies you revive return with +5 % more health | +5 % healing | Healing an ally under 50 % heals +10 % |
| CON | +2 % mitigation | The immunity after a chain of controls lasts +0.5 s | +4 % max health | Under 30 % health, +10 % mitigation for 4 s (ICD 30 s) |

(ICD = internal cooldown, `icd_s`.) Backstab is the rule of [combat.md](combat.md) §0 (> 120° from behind).

- **Reassigning:** free until level 19; from level 20 it costs `5 · L` gold (300 at level 60), out of combat and anywhere. Ledger
  reason `RESPEC` (69, already reserved in [progression.md](progression.md) §5.3) with `ref_kind` 7 (attributes).
- The server validates every split: Σ spent ≤ `2 · (L − 1)` and each ≥ 0.

---

## 6. Weapon mastery (PRG-18)

`data/progression/mastery_curve.tres`.

- **Per weapon family** (`WeaponDefinition.family`: `sword_shield`, `bow`, `hatchet`…), not per item: every sword and shield shares
  mastery and tree.
- **Levels 0-20, one talent point per level** (**20 points** at mastery 20, I09). XP to the next level: 250, 290, 350, 420, 490, 570,
  660, 750, 850, 950, 1050, 1150, 1260, 1370, 1490, 1600, 1720, 1840, 1960, 2090: **21 110** in total, about **21 h of exclusive
  use** at ~1000/h.
- **Where it comes from** (independent of the character level, so mastery does not go faster at high level): the same credit events
  as XP, **never from hitting** (a dummy gives no mastery).

| Event | Mastery XP |
|---|---|
| Normal NPC | 10, scaled by the rank multipliers of §2.2 (3 / 10 / 20 / 60 / 120 / 250 / 400 / 600), × level difference (§2.3: gray = 0) |
| War merit (PvP and objectives) | 3 per merit (~900/h at war) |

- **Split between the two weapons:** proportional to the contribution made **with each family** in the credit window (the 900
  ticks of the `DamageLedger`): damage dealt plus healing done. If only one was used, it takes all. The ultimate counts for the
  active weapon when cast. `DamageLedger.record` gains the `weapon_family` of each entry.
- At mastery 20 the XP of that family is discarded (the character's overflow already goes to veteranship).
- Forecast: at 60 (~50 h, ~65 % in combat) the main weapon is around mastery 16-20 and the secondary 10-14. On entering Eldrun
  (level 20), mastery ~6 in the main weapon. At level 10 with one weapon: about 1 500 mastery XP, **mastery 4**; the 4th ability
  (row 2, which asks 4 points in the branch before the node) arrives between level 10 and 12.
- MASTERY_UPDATE (§14) to the owner, at most one every 10 ticks per family.
- **Resetting a tree** is §7.1.

---

## 7. Talent trees (PRG-19, CMB-55)

### 7.1 Shape (validated by structure)

- **Two branches** per family, **6 rows** each, **15 nodes per branch** (2 + 3 + 3 + 3 + 3 + 1), **30 per tree**. Each node costs 1 point.
  With 20 points you take 2/3 of the tree: one capstone (11 points in its branch) and 9 in the other. Both capstones do not fit
  (they would ask 22).
- **Row *f*** opens when `points in that branch ≥ [0, 2, 4, 6, 8, 10][f]` **and** `level ≥ [1, 1, 8, 14, 20, 25][f]`. Row 5 asks
  level 25, which is above the Eldrun entry (20) and so, in a normalized zone, level 60 is read and no node switches on or off.
- **Node types by row** (letters: **M** a modifier of an ability or attack, **P** a passive of §7.3, **A** opens an ability, **V** a
  catalog variant):

| Row | Nodes | Types |
|---|---|---|
| 0 | 2 | M + P |
| 1 | 3 | M + P + P |
| 2 | 3 | **A** (opens the 4th or 5th ability) + M of that ability (asks A) + P |
| 3 | 3 | M + P + P (one of the P with a trigger) |
| 4 | 3 | **V or M** + P + M. The slot is a catalog variant (`<id>_2`) **only when a predicted field changes**; otherwise it is an M |
| 5 | 1 | **Capstone**: a strong conditional P, ICD ≥ 20 s |

- **M nodes touch only server fields** (damage, stagger, stun, knockback, effects and their duration or magnitude when the field
  is S, hyper-armor, wall box, block cost, armor penetration). **There are no cooldown nodes**: cooldown, timings, displacement, projectile
  count and speed are predicted, so anything that changes them is a variant (I21). The validator rejects an M that touches a P
  field.
- **Abilities:** the 3 base ones of the weapon are usable from mastery 0; the 2 of row 2 open with their A node. Carry **3 per
  weapon** (the choice is saved per family, §13) and change them freely out of combat.
- **Tree passives** work only with **that weapon active**. They never give max health (it would change with every Q).
- **Variants** replace the base ability on the bar if you have the node; the bar holds the variant id (`ability_picks` indexes the
  `ability_pool`, which has up to 15 entries).
- **Resetting a family's tree:** free with mastery < 5 or level < 15; otherwise `4 · L + 10 · mastery` gold (440 at level 60 and
  mastery 20). Out of combat. `RESPEC` with `ref_kind` 8 (talents) and `ref_id` = the family's fingerprint.
- **Budget:** a complete tree (20 optimal points) cannot raise efficacy (§10) more than **8 %** against no node. Caps per node in §7.3.

### 7.2 The two trees that close PRG-19

The abilities are those of `weapons.md`: sword and shield has the base Shield Bash (`shield_bash`), Shield Rush (`shield_rush`) and
Shield Wall (`shield_wall`) and the branch abilities **Challenge** (`sword_challenge`: 360° and 8 m, taunts the NPCs it touches for
4 s, `fortified` 15 % on yourself for 4 s, cooldown 20 s) and **Rending Thrust** (`sword_rending_thrust`: 3.0 m, 40°, 110
piercing and `vulnerable` +10 % for 6 s, cooldown 12 s); the bow has Volley (`bow_volley`), Slowing Arrow (`bow_slowing_shot`) and
Evasive Shot (`bow_evasive_shot`) and the branch abilities **Piercing Arrow** (`bow_piercing_shot`: 70 m/s, 140 piercing, passes
through up to 3 enemies, cooldown 16 s) and **Poison Arrow** (`bow_poison_arrow`: 55 m/s, 50 piercing and `poisoned`, cooldown
14 s). Figures here are starting points, to measure with `tools/combat_balance.gd`. The states (`fortified`, `vulnerable`,
`poisoned`, `bleed`, `slowed`) are the server states of CMB-46.

**Sword and shield · Bulwark branch (defense and control)**

| Row | Node | Effect |
|---|---|---|
| 0 | M Shield Bash | Stun 0.8 → 1.0 s |
| 0 | P Solid Guard | Blocking costs 10 % less stamina |
| 1 | M Shield Rush | Knockback +2 m/s |
| 1 | P Hardness | +8 % damage of Shield Bash and Shield Rush |
| 1 | P Repression | After a parry, +15 % damage for 2 s (ICD 6 s) |
| 2 | **A Challenge** (`sword_challenge`) | Opens the 4th ability |
| 2 | M Challenge (asks A) | Your `fortified` is 15 → 20 % |
| 2 | P Firmness | Controls on you last 10 % less |
| 3 | M Shield Wall | Cost per blocked point 0.6 → 0.51 and the box +0.4 m wide |
| 3 | P Reprisal | Blocking a melee hit returns 30 blunt damage to the attacker (ICD 6 s) |
| 3 | P Firm Footing | While blocking, the knockback you take is halved |
| 4 | **V Charging Rush** (`shield_rush_2`) | Rush distance +25 % (a predicted field: a variant) |
| 4 | P Bastion | +6 % mitigation with health above 50 % |
| 4 | M Challenge | Taunt 4 → 6 s |
| 5 | **Capstone: Unbreakable** | If a hit leaves you under 30 %, `fortified` 25 % for 4 s (ICD 45 s) |

**Sword and shield · Edge branch (attack and bleeding)**

| Row | Node | Effect |
|---|---|---|
| 0 | M Final Slash | The third light attack applies 1 stack of `bleed` |
| 0 | P Sharp Edge | +3 % damage of light attacks |
| 1 | M Shield Bash | Damage 60 → 80 |
| 1 | P Punish | +6 % damage to staggered or stunned enemies |
| 1 | P From Behind | Backstab ×1.5 → ×1.6 |
| 2 | **A Rending Thrust** (`sword_rending_thrust`) | Opens the 5th ability |
| 2 | M Rending Thrust (asks A) | `vulnerable` +10 → +15 % |
| 2 | P Haemorrhage | The `bleed` you apply lasts +2 s (6 → 8, a multiple of the pulse) |
| 3 | M Shield Rush | +25 damage and applies `slowed` 2 s |
| 3 | P Momentum | After a dodge, +6 % damage for 3 s (ICD 8 s) |
| 3 | P Finisher | +8 % damage to enemies under 30 % |
| 4 | M Heavy | A fully charged heavy attack applies 2 stacks of `bleed` |
| 4 | P Ruthless | +2 % damage per stack of `bleed` on the target (max +6 %) |
| 4 | M Rending Thrust | Damage 110 → 130 |
| 5 | **Capstone: Thirst for Steel** | Knocking down or killing an enemy gives +12 % damage for 6 s (ICD 20 s) |

**Bow · Marksman branch (precision and distance)**

| Row | Node | Effect |
|---|---|---|
| 0 | M Drawn Shot | +10 % damage at full draw |
| 0 | P Steady Eye | +4 % damage beyond 25 m |
| 1 | M Volley | Damage 55 → 62 per arrow |
| 1 | P Flanking | Arrows that hit from behind (> 120°, the rule of [combat.md](combat.md) §0) deal ×1.25 |
| 1 | P Taut String | +5 % damage of fully drawn shots |
| 2 | **A Piercing Arrow** (`bow_piercing_shot`) | Opens the 4th ability |
| 2 | M Piercing Arrow (asks A) | Damage 140 → 160 |
| 2 | P Hawk Eye | +6 % damage of the bow abilities beyond 20 m |
| 3 | M Slowing Arrow | Damage 60 → 75 |
| 3 | P Steady Shooter | +6 % damage if you have not moved for 1 s |
| 3 | P Quick Hand | +5 % damage of quick (light) shots |
| 4 | M Piercing Arrow | Ignores 15 % of the armor |
| 4 | P Elite Aim | +4 % damage of the bow abilities |
| 4 | M Drawn Shot | At full draw ignores 15 % of the armor (`mitigation_penalty`, which `damage_formula` already accepts) |
| 5 | **Capstone: Killing Shot** | Fully drawn shots against targets under 35 % deal +18 % |

**Bow · Tracker branch (mobility and poison)**

| Row | Node | Effect |
|---|---|---|
| 0 | M Evasive Shot | Damage 60 → 75 |
| 0 | P Harass | +6 % damage of quick shots within 12 m |
| 1 | M Slowing Arrow | The `slowed` it applies lasts +1 s (its magnitude is a predicted field and is not touched) |
| 1 | P Elusive | After a dodge, +6 % damage for 3 s (ICD 8 s) |
| 1 | P Tainted Tip | Every 4th quick shot on the same target applies `poisoned` for 3 s (a counter, no chance: [combat.md](combat.md) §0) |
| 2 | **A Poison Arrow** (`bow_poison_arrow`) | Opens the 5th ability |
| 2 | M Poison Arrow (asks A) | `poisoned` lasts +2 s |
| 2 | P Toxins | +10 % of the damage over time you deal |
| 3 | M Volley | The arrows apply `poisoned` for 2 s |
| 3 | P Hit and Run | +6 % damage within 8 m |
| 3 | P Venom Rush | Downing or killing a poisoned enemy gives +8 % damage for 4 s (ICD 8 s) |
| 4 | **V Long Evasive Shot** (`bow_evasive_shot_2`) | The backward hop 4 → 5.5 m (a predicted field: a variant) |
| 4 | P Harrying | +2 % damage per distinct negative effect on the target (max +6 %) |
| 4 | M Poison Arrow | The poison pulse damage +25 % |
| 5 | **Capstone: Plague** | When a poisoned enemy dies, the poison jumps to up to 3 enemies within 5 m (ICD 20 s) |

The earlier cooldown nodes (Shield Bash 12 → 10 s, Rush 16 → 14 s, Volley 10 → 8 s…) are gone, and so is the "slow magnitude" node;
the later weapons (hatchet, life staff, fire staff, crossbow, frost gauntlet, hammer, greatsword, spear) arrive with a tree of the
same shape, 2 new abilities and 30 nodes each, which the validator accepts or rejects.

### 7.3 Passives: a closed set (`PassiveDefinition`)

Shared by talents, specialization ranks and attribute thresholds.

- **Kinds:** `STAT` (modifies a statistic while a condition holds) and `TRIGGER` (on an event, applies a status effect to oneself,
  the target or allies in a radius, with an ICD).
- **Statistics** (all server-side): DAMAGE (filter: light, heavy, ability, over time, damage type, all), MITIGATION, HEALING_DONE,
  HEALING_RECEIVED, MAX_HEALTH (specialization and attributes only), BLOCK_STAMINA, CC_TAKEN, STATUS_DURATION_GIVEN, BACKSTAB,
  STRUCTURE_DAMAGE, REVIVED_HEALTH, LIFESTEAL, ARMOR_PENETRATION, THREAT, AREA_TARGETS.
- **Conditions:** ALWAYS, WEAPON_ACTIVE (the default in trees), WEAPON_TAG, TARGET_HEALTH_BELOW, SELF_HEALTH_ABOVE/BELOW,
  TARGET_HAS_STATUS, TARGET_CONTROLLED, RANGE_ABOVE/BELOW, SELF_STILL, BLOCKING, FROM_BEHIND.
- **Events:** PARRY, BLOCK, DODGE, KILL_OR_DOWN, HEAL_GIVEN, HEALTH_BELOW, MULTI_HIT(n), DRAWN_SHOT_HIT.
- **Stacking:** percentages of the same statistic add; those of different statistics multiply.
- **Caps checked by the validator:** unconditional STAT ≤ 5 %; conditional ≤ 12 %; TRIGGER ≤ 20 %, ≤ 6 s and ICD ≥ 6 s; capstone ≤
  25 % with ICD ≥ 20 s; AREA_TARGETS ≤ +1.
- **Effects used:** `fortified` (reduces damage taken, the MITIGATION_UP of the first proposal), `vulnerable` (MITIGATION_DOWN),
  `weaken`, `healing_down`, `lifesteal` and `unstoppable` (immune to stagger and knockback). All server-only, like `DAMAGE_UP`
  ([abilities.md](abilities.md) §2.1); defined by CMB-46.
- No permanent auras (see §10): passives are unconditional or have a trigger with an internal cooldown ≥ 6 s. Only ultimates create areas,
  with a target cap.

---

## 8. Specializations (PRG-49, PRG-50, CMB-56, PRG-64)

### 8.1 Rules

- **Chosen from level 10** in a capital, with the **Master of the Orders** (one per capital; `npcs.md`). The quest "The Squire's
  Choice" (MUN-68) takes the player to the **mentor** of the specialization they want (one mentor per specialization), who gives the
  role trial and the flavor. The first choice is **free** (I05).
- **Changing it:** only in a capital, out of combat, for `8·L + 20` gold (100 at level 10, 500 at level 60), no cooldown. Ledger
  `RESPEC` with `ref_kind` 9 (specialization). On changing, the new ultimate starts with its whole cooldown (150 s).
- **Ranks by character level** (I04): I at 10, II at 20, III at 30, IV at 40 (improved ultimate), V at 50.
- **Favors without locking:** every specialization favors 2 **weapon tags** (`WeaponDefinition.tags`, server only). At least **40 %**
  of the value of each rank is general and works with any weapon; the rest asks for a weapon with the tag. The validator also checks
  that every weapon of the catalog is favored by at least one specialization.
- **Without specialization** (level ≥ 10 that did not pass through the capital): no ultimate and no passives; the Eldrun gate warns.
- **Visibility** (I07): an icon on the nameplate and party frame of allies; +1 B in the PLAYER ENTITY_SPAWN (0 toward another
  realm) and ENTITY_EVENT 17 SPEC_CHANGED to the own realm.
- **Suggested split** (`suggested_attributes`, five weights that add to 100, provisional): used by the normalization for unspent points
  (§10) and by the interface as a recommendation.

### 8.2 Weapon tags and the five specializations

Tags (`WeaponDefinition.tags`): sword and shield `melee, one_handed, shield`; bow `ranged`; hatchet `melee, one_handed, thrown`; life
staff `magic, staff, healing`; fire staff `magic, staff, elemental`; crossbow `ranged`; frost gauntlet `magic, elemental`; war hammer
`melee, two_handed`; greatsword `melee, two_handed`; spear `melee, two_handed, polearm`; twin daggers `melee, one_handed`; great axe
`melee, two_handed`.

| Specialization (msgid) | Fantasy | Favored tags | Favored weapons at launch | First vertical slice | Suggested split (str/dex/int/foc/con) | Ultimate |
|---|---|---|---|---|---|---|
| **Vanguard** | The first row of the realm: holds the line and protects its own | `shield`, `polearm` | Sword and shield, spear | Sword and shield | 30 / 10 / 5 / 5 / 50 | Bulwark Banner |
| **Linebreaker** | Charges that break formations and gates | `two_handed`, `thrown` | War hammer, greatsword, spear, hatchet | Hatchet | 50 / 10 / 5 / 5 / 30 | Ram's Charge |
| **Hunter** | Harries from the ridge and punishes whoever strays | `ranged`, `thrown` | Bow, crossbow, hatchet | Bow, hatchet | 30 / 50 / 5 / 5 / 10 | Hail of Shafts |
| **Healer** | Whoever heals decides who holds the siege | `healing`, `shield` | Life staff, sword and shield | Life staff, sword and shield | 5 / 5 / 10 / 50 / 30 | Prayer of the Flame |
| **Arcanist** | Masters the Embers of Eld: fire that denies zones | `elemental`, `staff` | Fire staff, frost gauntlet, life staff | — (arrives with the fire staff, right after the slice) | 5 / 5 / 50 / 30 / 10 | Ember Nova |
| *Sapper* (phase 7) | Opens breaches and sustains the siege machines | `two_handed`, `siege` | War hammer, greatsword | — | 50 / 10 / 5 / 5 / 30 | Breach Charge |

`SpecializationDefinition.available = false` for the Arcanist until the fire staff exists and for the Sapper until the siege
(GUE-25). English msgids: Vanguard, Linebreaker, Hunter, Healer, Arcanist, Sapper; Spanish in `es.po` (Vanguardia, Rompefilas,
Cazador, Sanador, Arcanista, Zapador).

### 8.3 Ranks (starting magnitudes)

| | I (10) | II (20) | III (30) | IV (40) | V (50) |
|---|---|---|---|---|---|
| **Vanguard** | +5 % max health; with a weapon that blocks, blocking costs 15 % less | Controls on you last 15 % less | After a parry, +15 % damage for 3 s (ICD 8 s) | Banner: radius 6 → 8 m and allies inside are immune to knockback | Under 30 %, `fortified` 20 % for 5 s (ICD 60 s); with `shield` or `polearm`, +6 % mitigation |
| **Linebreaker** | +6 % damage with `two_handed`; fully charged heavy attacks have hyper-armor in the active window | +8 % damage to enemies under 35 % | Hitting 3 or more with one blow gives +10 % damage for 4 s (ICD 10 s) | Charge: 10 → 14 m and ×3 against structures | Your hits heal you for 4 % of the damage done |
| **Hunter** | +6 % damage beyond 20 m; your slows last 25 % longer | With `ranged`, fully drawn shots apply `vulnerable` 6 % for 5 s | After a dodge, +12 % damage for 2 s (ICD 6 s) | Hail: radius 6 → 7.5 m and slow 30 → 45 % | +10 % damage to slowed or rooted targets |
| **Healer** | +8 % healing done | Allies you revive return with 40 % more health (300 → 420) | Healing an ally under 35 % heals 15 % more | Prayer: at the start it cleanses slow and root and gives 2 s of `unstoppable` | You heal 10 % of what you heal others; with `shield`, +6 % mitigation with health above 50 % |
| **Arcanist** | +6 % elemental damage | Your damage over time lasts 20 % longer (rounded to pulses) | +10 % damage to whoever suffers your damage over time | Nova: root 1.5 → 2.0 s and radius 7 → 8 m | With `staff`, +10 % damage of abilities; your areas affect +1 target |

All are passives of §7.3: none touches stamina, speed or timings. Where rank IV changes a predicted field (Ram's Charge distance, the
Hail slow magnitude) it swaps the ultimate for its `<id>_2` catalog variant; where it only changes a server value (radius, status
duration, immunities) it is an `ActionModifier` on the ultimate.

### 8.4 Ultimates

A slot of its own on the bar, key **F** (free today; remappable with UI-17), button `ULTIMATE` = bit 13 of `PlayerInput`
([abilities.md](abilities.md) §3.2 leaves it reserved). Cooldown **150 s** for all; saved as timer `ability:<id>`
([progression.md](progression.md) §8) and `reset_for_respawn` does not touch it, so dying is not a way to recharge it. **At most 10
targets.** Presentation: one generic summon clip of UAL for all but the Charge, which uses the rush clip, and an ember VFX per
specialization (own particles or the free pack of [art.md](art.md); nothing paid).

| Ultimate | Data | Pieces it uses |
|---|---|---|
| **Bulwark Banner** (Vanguard) | Cast 0.5 s, recovery 0.3 s. Plants a banner for 8 s: a 6 m area that every 1 s gives `fortified` 20 % (1.5 s) to allies inside, cap 10. `unstoppable` 3 s on the caster | Ground area (CMB-49) and the new effects of §7.3 |
| **Ram's Charge** (Linebreaker) | 0.3 s + 0.5 s charge of 10 m + 0.4 s. A 1.8 m, 140° sector on every active tick, cap 6: 180 blunt, knockback 8 m/s and stagger 0.6 s. Hyper-armor. ×2 against structures | Those of `shield_rush` and a new field `structure_damage_scale` |
| **Hail of Shafts** (Hunter) | Cast 0.6 s at a point ≤ 35 m from the aim ray (`AimRay`). A 6 m area with 6 pulses in 3 s: 50 piercing and `slowed` 30 %, cap 10 per pulse | Area at an aimed point (CMB-49) |
| **Prayer of the Flame** (Healer) | Cast 0.2 s and a channel up to 3 s (movement ×0.3). Every 0.5 s, allies within 10 m (cap 10) heal 4 % of their max health (24 % in total). `fortified` 20 % on the caster during the channel | Pulses on allies (CMB-47) |
| **Ember Nova** (Arcanist) | Cast 0.8 s, interruptible (phase 0 marked, [abilities.md](abilities.md) §0). A 7 m sphere around, cap 8: 220 fire and ROOT 1.5 s | Those that exist (360° shape, `rooted`) |
| *Breach Charge* (Sapper, phase 7) | Places a charge that after 3 s deals 1200 to structures; it can be defused | Siege weapons (GUE-25) |

Production starts with the Charge and the Nova because they wait for nobody (§17). The Spanish names are in `es.po`: Estandarte del
Baluarte, Carga del Ariete, Lluvia de Saetas, Plegaria de la Llama, Nova de Brasas, Carga de brecha.

### 8.5 Costs and the Respec ledger

| Change | Cost | Free when | Reason · `ref_kind` |
|---|---|---|---|
| Specialization (first time) | 0 | Always | — |
| Specialization (change) | `8·L + 20` gold | Never | `RESPEC` 69 · 9 |
| Attributes | `5·L` gold | Level ≤ 19 | `RESPEC` 69 · 7 |
| A family's talent tree | `4·L + 10·mastery` gold | Mastery < 5 or level < 15 | `RESPEC` 69 · 8 |
| Ability picks | 0 | Always (out of combat) | — |

Against the reference income (`g_ref`, [items.md](items.md) §15): a specialization change is 31 min at level 10 and 26 min at level 60;
an attribute reset 16 min at level 60; a tree reset 23 min. All go through `RESPEC` and raise the sink ratio to the 65-80 % the item
economy asks for.

---

## 9. After level 60 (PRG-62, PRG-32, PRG-37)

### 9.1 Veteranship

- The XP that overflows at the cap is added to `veteran_xp` (new column). Every **40 000** (≈ 1 h at `r(60)`) gives a **Veteran
  Seal**: currency 3, per character like the others ([progression.md](progression.md) §5.1), cap 10 000; ledger reason
  `VETERAN_SEAL` (18).
- Seals are spent on cosmetics and titles, on war consumables and on a few **Ember Shards** per week (a cap lower than the quartermaster's,
  provisional: 5 per week). Nothing that gives power outside what §10 compresses.
- The veteranship level (`veteran_xp / 40 000`) shows in the character window and the nameplate of allies.
- **Rested XP** (PRG-63, later): disconnected in a capital, 5 % of a level accumulates every 8 h (max 1.5 levels) and doubles the XP of
  kills until spent.

### 9.2 Equipment (contract with [items.md](items.md))

- Equipment score (PE) is 10 × the weighted mean of the effective item level: **600** at level 60 with no upgrades and **700** at most
  (upgrades +1…+10, [items.md](items.md) §11). It replaces the GS 100 → 500 → 600 of the first proposal.
- The factor of damage or armor of the equipment is `k(NOe) / k(52)` (1.0 at the reference, 1.10 at item level 60, 1.21 at NOe 70).
  Items decide the curve; the only condition from here is §10.

### 9.3 Mastery and war ranks (PRG-32)

- Masteries keep rising after 60 ([§6](#6-weapon-mastery-prg-18)): completing the weapons not used while leveling.
- **War ranks** with realm points (I9 of [progression.md](progression.md) §3.2), horizontal only, as PRG-32 asks:

| Rank | I | II | III | IV | V | VI | VII | VIII | IX | X |
|---|---|---|---|---|---|---|---|---|---|---|
| Realm points | 0 | 1 500 | 5 000 | 12 000 | 25 000 | 45 000 | 75 000 | 120 000 | 180 000 | 260 000 |
| Hours at ~300/h | 0 | 5 | 17 | 40 | 83 | 150 | 250 | 400 | 600 | 867 |

Rewards: title (II), insignia on the tabard (III), quartermaster tiers (II, IV, VI and VIII), buying siege (II), cosmetic standard (X). The
rank is visible also from the enemy realm ([social.md](social.md) §1).

---

## 10. Normalization of Eldrun (PRG-31)

### 10.1 What is measured

**Efficacy** E = DPS × effective health against a reference rival. In a duel the ratio of times to kill is exactly `E_A / E_B`: it is
measured by `tools/combat_balance.gd` with two identical bots, with no hand formulas. **Goal:** optimal veteran against the newcomer of
the gate, **E ≤ 1.15** (PRG-31's figure).

- *Veteran:* level 60, mastery 20 in both weapons, optimal talents, item level 70 (every upgrade) in every slot, optimal attributes and
  war rank X.
- *Newcomer:* the entry level (20 for Eldrun, 10 for Vado Gris), mastery 6 and 3, no talent of row 4 or later, gear of their level
  and unspent points.

### 10.2 The rule (I22)

In a zone with `ZoneDefinition.normalized = true` (world design, MUN-13): Eldrun, `vado_gris` and `test_world`.

| Source of power | In the normalized zone | Max difference between veteran and newcomer |
|---|---|---|
| Level (base health, slots, rows, ranks) | Effective level 60, rank V | 0 % |
| Attributes (spent and from affixes) | The **total** (base + spent + affixes) is **rescaled to 143** keeping proportions (largest remainders, deterministic); free points are placed first with the `suggested_attributes` of the specialization, or the weapon's reference split if none | 0 % of power (a worse split costs up to 6 %) |
| Base of the equipment | Each slot counts as `NOe_eff = clamp(52 + 0.2·(NOe − 50), 52, 54)`; an empty slot is a common piece of NOe 52 | `k(54)/k(52)` = **1.024** |
| Non-attribute affixes and gems | ×0.25 with a **joint cap of 3 % efficacy**; PvE affixes at 0 | **1.03** |
| Mastery and talents | Real (not touched; budget of §7.1) | **1.08** |
| Consumables | Only the fixed potions: elixirs, food and oils do nothing | 0 % |
| War rank, veteranship, cosmetics | Horizontal | 0 % |
| **Product** | | **1.139 ≤ 1.15** |

If the measure with bots goes above 1.15, the following are cut, **in this order**: the conditional passives of the trees, the affix cap
(3 % → 1.5 %) and the compression of the item level (0.2 → 0.1).

- **XP in a normalized zone uses the real level** (§2.1, merits).
- **The function is shared and pure:** `PowerNormalization.apply(input, rules) -> sheet`. The client computes the same sheet as the
  server and shows it as the **War Sheet** ("Hoja de guerra (normalizada a 60)" in Spanish); the test compares both field by field.
- **Entry** (`ZoneDefinition.min_level`): Eldrun **20**, Vado Gris **10**, `test_world` none (I23).
- **No cost per tick:** the sheet is computed on arrival and when equipment, attributes, talents or specialization change. Per hit
  only factor lookups and the active conditions are added: goal ≤ 2 µs per validated hit, measured in TEC-34.
- **Mass war:** no permanent auras; triggers with ICD ≥ 6 s; ultimates capped at 10 targets every 150 s: with 150 players that is ~1
  ultimate per second in the whole zone and ≤ 60 target tests per second (2 per second with 300 players). TEC-34 measures it with bots
  that cast the ultimate as soon as they have it.
- Elixirs, food and oils have no effect in a normalized zone; the potion-efficacy affix counts 0 there (the potions are fixed).

---

## 11. The PvE scale contract (I24)

This is the table `npcs.md` consumes (`data/progression/pve_scale.tres`, generated from `levels.csv`). A player "at their level"
(60/20/20 split of the points, common gear of the item level of their level, medium armor) has, against the reference:

| Level | O(L) offense | D(L) effective health | Health | Average armor | Health of a normal NPC |
|---|---|---|---|---|---|
| 1 | 0.30 | 0.51 | 615 | 155 | 302 |
| 5 | 0.35 | 0.54 | 640 | 174 | 345 |
| 10 | 0.40 | 0.58 | 672 | 197 | 402 |
| 20 | 0.52 | 0.66 | 735 | 244 | 522 |
| 30 | 0.65 | 0.74 | 798 | 290 | 653 |
| 45 | 0.87 | 0.87 | 892 | 360 | 867 |
| 60 | 1.10 | 1.01 | 987 | 430 | 1 103 |

- `O(L) = factor_atr(60/20/20) · k(L) / k(52)`; `D(L) = (health(L)/1000) · (1000 + armor_ref) / (1000 + armor(L))`.
- **NPCs of level L:** health ∝ `1000 · O(L)` (times the rank multiplier of `npcs.md`) and damage ∝ `D(L)`. The contract that is checked
  is the **time to kill**: the player's DPS is `O(L) × DPS`, so a normal NPC falls in the same time at any level: 10.8 s with the DPS
  of the bots (93), 8.3 s with a real player (~120) and 6.4 s with the ideal combo (156), inside the 8-12 s of I24. An elite falls in 25-40 s, and a normal kills an
  undefended player in 25-35 s. `tools/combat_balance.gd` measures one NPC per band.
- The hit of an NPC is always the same share of the player's health, the envelopes of `npcs.md` (a normal's light hit 5-7 %).
- **In normalized zones the NPCs use the reference (1.0):** the five of Vado Gris do not change.
- **Load classes against the reference** ([items.md](items.md) §3): light ×1.18, heavy ×0.86 damage taken.

---

## 12. Resources and tools

### 12.1 New resources (`scripts/shared/progression/`, data in `data/progression/`)

Seconds in the `.tres`, ticks on load. No resource holds a `Texture2D`, `PackedScene` or `Mesh`: icons go by path
([progression.md](progression.md) §2.1). The tables marked "generated" are written by `tools/progression/build_tables.gd` (§12.2).

```gdscript
class_name LevelRewards extends Resource          # data/progression/level_rewards.tres (generated)
@export var base_health: PackedInt32Array          # 60 values, index level − 1
@export var ability_slot_levels: PackedInt32Array = PackedInt32Array([1, 3, 6])
@export var talent_tier_levels: PackedInt32Array = PackedInt32Array([1, 1, 8, 14, 20, 25])
@export var talent_tier_points: PackedInt32Array = PackedInt32Array([0, 2, 4, 6, 8, 10])
@export var specialization_level: int = 10
@export var spec_rank_levels: PackedInt32Array = PackedInt32Array([10, 20, 30, 40, 50])
@export var attribute_reset_free_below: int = 20

class_name AttributeRules extends Resource        # data/progression/attributes.tres
@export var base_value: int = 5
@export var damage_per_primary: float = 0.004; @export var damage_per_secondary: float = 0.002
@export var health_per_con: int = 3
@export var reference_primary: int = 75; @export var reference_secondary: int = 25; @export var reference_con: int = 33
@export var thresholds: PackedInt32Array = PackedInt32Array([25, 50, 75, 100])
@export var threshold_passives: Array[PassiveDefinition]   # 5 × 4, in the order str, dex, int, foc, con
@export var reset_cost_per_level: int = 5

class_name XpTables extends Resource              # data/progression/xp_sources.tres (generated)
@export var npc_base_xp: PackedInt32Array          # 60 values: round(0.006 · r(L))
@export var npc_rank_xp: PackedFloat32Array        # 8: MINION, NORMAL, STRONG, ELITE, NAMED, BOSS, DUNGEON_BOSS, WORLD_BOSS
@export var npc_rank_mastery: PackedInt32Array = PackedInt32Array([3, 10, 20, 60, 120, 250, 400, 600])
@export var level_diff_factor: PackedFloat32Array  # differences −8 … +5 (−8 and below = 0)
@export var quest_diff_floor: float = 0.25
@export var rvr_xp_per_merit: PackedInt32Array     # 60
@export var capture_xp: PackedInt32Array; @export var discovery_xp: PackedInt32Array; @export var dungeon_xp: PackedInt32Array
@export var mastery_xp_per_merit: int = 3
@export var veteran_xp_per_seal: int = 40000

class_name QuestRewards extends Resource          # data/progression/quest_rewards.tres (generated; owned here, §2.6)
enum Kind { MAIN, SIDE, ACT_FINALE, TRIAL, DAILY, WAR_COMMISSION, CALL_TO_ARMS, WEEKLY, BOUNTY,
		EVENT_BRONZE, EVENT_SILVER, EVENT_GOLD }
@export var xp_fraction: PackedFloat32Array        # per Kind, of r(L_quest)
@export var gold_fraction: PackedFloat32Array      # per Kind, of g_ref(L_quest)
@export var merits: PackedInt32Array               # per Kind (fixed)
@export var weekly_war_bonus_merits: int = 300
@export var xp_pace: PackedInt32Array              # r(L), 60 values
@export var gold_pace: PackedInt32Array            # g_ref(L), 60 values (items.md §15)

class_name MasteryCurve extends Resource          # data/progression/mastery_curve.tres
@export var max_level: int = 20
@export var xp_to_next: PackedInt32Array           # 20 values

class_name TalentTree extends Resource            # data/progression/talents/<family>.tres (by hand or scaffold, validated)
@export var family: StringName
@export var branch_names: PackedStringArray        # 2 English msgids ("Bulwark", "Edge")
@export var nodes: Array[TalentNode]               # 30; the order is frozen: it is the wire bit

class_name TalentNode extends Resource            # sub-resource of the same .tres
@export var id: StringName                         # ^[a-z0-9_]{3,40}$, stable: it is what is saved
@export var branch: int; @export var tier: int; @export var column: int     # column only for the interface
@export var requires: StringName = &""
@export var display_name: String; @export var description: String           # English, with {parameters}
@export var unlock_ability: AbilityDefinition      # type A
@export var variant: AbilityDefinition             # type V: replaces its base ability (catalog variant, a predicted field changes)
@export var modifier: ActionModifier               # type M
@export var passives: Array[PassiveDefinition]     # type P (1-2)
@export var capstone: bool = false

class_name ActionModifier extends Resource        # improves an ability or an attack: server fields only (I21)
@export var ability: AbilityDefinition; @export var attack: AttackDefinition   # one of the two
@export var damage_add: int = 0; @export var damage_scale: float = 1.0
@export var stun_add_s: float = 0.0; @export var stagger_add_s: float = 0.0; @export var knockback_add: float = 0.0
@export var target_status: StatusEffectDefinition; @export var target_status_stacks: int = 0
@export var self_status: StatusEffectDefinition; @export var status_duration_add_s: float = 0.0
@export var status_magnitude_add: float = 0.0      # only of server-only statuses (fortified, vulnerable, poisoned)
@export var hyper_armor_in_recovery: bool = false; @export var armor_penetration: float = 0.0
@export var block_stamina_scale: float = 1.0; @export var wall_half_extents_add: Vector3 = Vector3.ZERO
@export var radius_add_m: float = 0.0              # areas of ultimates (rank IV)
# there is no cooldown_add_s: a cooldown is a predicted field (I21)

class_name PassiveDefinition extends Resource     # §7.3
enum Kind { STAT, TRIGGER }
@export var kind: Kind; @export var stat: int; @export var value: float; @export var damage_filter: int
@export var condition: int; @export var condition_value: float; @export var condition_tag: StringName
@export var condition_status: StatusEffectDefinition
@export var event: int; @export var event_value: int; @export var status: StatusEffectDefinition
@export var status_target: int; @export var radius_m: float = 0.0; @export var icd_s: float = 0.0
@export var description: String                    # English with {value}, {duration}, {icd}

class_name SpecializationDefinition extends Resource   # data/progression/specializations/<id>.tres
@export var id: StringName                         # vanguard, linebreaker, hunter, healer, arcanist, sapper
@export var display_name: String; @export var description: String; @export var role_hint: String
@export var favored_tags: Array[StringName]
@export var suggested_attributes: PackedInt32Array # 5 weights that add to 100 (str, dex, int, foc, con)
@export var ranks: Array[SpecRank]                 # 5 (level, passives, description)
@export var ultimate: AbilityDefinition            # in data/combat/, like the others
@export var ultimate_variant_rank4: AbilityDefinition   # when rank IV changes a predicted field (optional)
@export var ultimate_upgrade: ActionModifier       # rank IV, server fields
@export var icon_path: String                      # client only
@export var mentor_npc: StringName                 # the NPC that gives the trial
@export var available: bool = true                 # false: arcanist until the fire staff, sapper until phase 7

class_name NormalizationRules extends Resource    # data/progression/normalization.tres
@export var effective_level: int = 60; @export var attribute_total: int = 143
@export var noe_pivot: int = 50; @export var noe_floor: int = 52; @export var noe_cap: int = 54
@export var noe_compression: float = 0.2
@export var affix_scale: float = 0.25; @export var affix_cap: float = 0.03
@export var efficacy_cap: float = 1.15

class_name PveScale extends Resource              # data/progression/pve_scale.tres (generated, §11)
@export var offense: PackedFloat32Array            # O(L), 60 values
@export var defense: PackedFloat32Array            # D(L), 60 values
@export var normal_health: PackedInt32Array        # 1000 · O(L), 60 values

class_name WarRanks extends Resource              # data/progression/war_ranks.tres (PRG-32)
@export var thresholds: PackedInt64Array           # 10
```

Changes to existing resources:

- `LevelCurve`: `level_cap = 60`, 59 values and `attribute_points_per_level = 2`.
- `ItemDefinition.required_level`: `@export_range(1, 60)` (the rest of `ItemDefinition` is in [items.md](items.md) §17).
- `WeaponDefinition`: `family`, `tags: Array[StringName]`, `primary_attribute` and `secondary_attribute` (0-4) and
  `ability_pool: Array[AbilityDefinition]` (5 to 15: the actives and their variants). `abilities` stays as the 3 defaults
  ([abilities.md](abilities.md) §2.1).
- `AbilityDefinition`: `structure_damage_scale` (S) and `ultimate: bool`. The catalog accepts an ability that belongs to a single
  specialization as it does one that belongs to a single weapon ([abilities.md](abilities.md) §2.2).
- `StatusEffectDefinition.Kind`: the new server-only kinds of CMB-46 (`FORTIFY`, `VULNERABLE`, `WEAKEN`, `HEALING_DOWN`, `LIFESTEAL`,
  `UNSTOPPABLE`).
- `NpcDefinition`: `rank` (8 ranks), level and role (`npcs.md`); `xp_reward` and `gold_reward` stay as a fixed value if > 0.
- `ZoneDefinition`: `normalized` and `min_level` (world design, MUN-13).

### 12.2 Tools and validators (PRG-51, PRG-52)

- `tools/progression/build_tables.gd`: reads `data/progression/src/levels.csv` (level, pace, minutes, manual adjustment, `g_ref`, O, D)
  and the small CSVs of the other tables and writes `level_curve.tres`, `level_rewards.tres`, `xp_sources.tres`, `quest_rewards.tres`,
  `mastery_curve.tres` and `pve_scale.tres` with a "generated, do not edit" header. Deterministic; `tests/test_progression_tables.gd`
  regenerates in memory and fails if the repo differs. It is the progression half of PRG-52 and shares the header and the test pattern
  with `tools/content/build_items.gd` ([items.md](items.md) §17).
- `tools/progression/simulate_leveling.gd` (PRG-22): a player with the mix of §2.5 per band; it gives the hours of each band and fails
  if they differ more than ±10 % from §1.1.
- `tests/test_progression_data.gd` (the progression part of the PRG-29 validator): a strictly increasing curve of 59 values; tables of
  60; trees with the shape of §7.1, unique ids, parents in the same branch and in an earlier row, A nodes that open abilities of their
  family, M only with server fields, V only where a predicted field changes, no cooldown node, the caps of §7.3, and that every capstone
  is reachable with 20 points (11 + 9); specializations with 5 ranks at `spec_rank_levels`, an ultimate with cooldown ≥ 120 s and cap
  ≤ 10, ≥ 40 % of general value, a favored weapon for every weapon, and `available` consistent with the catalog; normalization with
  the static budget E ≤ 1.15.
- `tools/combat_balance.gd` gains `--sheet=<veteran|newcomer|reference>` and the measure of E (§10.1).
- **Texts:** English in the `.tres` and the translation in `es.po`, with the contexts `talent`, `talent_desc`, `specialization`,
  `specialization_desc`, `passive_desc`, `attribute` and `ability` / `ability_desc` (if they do not exist yet). Numbers come from the data
  as parameters ([localization.md](localization.md)); never a sentence with a placeholder noun. `ServerMessages` 700-749 are for
  build and specialization, with the parameter type 10 SPEC.
- **Icons:** those of the upgrades reuse their ability's icon with a mark; passives use ~12 glyphs per statistic (damage, defense,
  healing, control, bleeding…) tinted by branch. A tree asks for 2 new icons and the specializations 10 (emblem and ultimate), made as
  SVG with `tools/ui` (ART-12).

---

## 13. Persistence of the build (PRG-48)

### 13.1 What is saved (`progress_format` 2)

```json
"attributes": {"str": 30, "dex": 10, "int": 0, "foc": 0, "con": 8},
"masteries": [{"family": "sword_shield", "xp": 5580}, {"family": "bow", "xp": 1310}],
"talents": [{"family": "sword_shield", "nodes": ["ss_b0_bash_stun", "ss_b0_solid_guard", "ss_b1_rush"]}],
"loadouts": [{"family": "sword_shield", "abilities": ["shield_bash", "sword_challenge", "shield_wall"]}],
"specialization": {"id": "vanguard", "changes": 1},
"veteran_xp": 0
```

The ultimate's cooldown is a timer `ability:<id>` in the `timers` section ([progression.md](progression.md) §8), saved with its end in
UTC so that offline time counts. **There are no per-character cooldowns to save** (I21): the cooldown of a slot is the data of its
ability, and the picks only choose which ability is in which slot.

### 13.2 Invariants

The numbering continues that of [progression.md](progression.md) §3.2 (they are **invariants** I8 and I14-I19, not the integrated
decisions I14-I19 of §0).

| # | Invariant |
|---|---|
| I8 (changes) | `level = level_for(xp_total)`, **between 1 and 60** |
| I14 | Each spent attribute ≥ 0 and Σ ≤ `2 · (level − 1)` |
| I15 | Mastery XP ≥ 0 and ≤ the total of the curve; derived level; it only goes down with a GM or REVERSAL |
| I16 | Nodes of a tree that exists, without repeats, ≤ the mastery level, each with its row open by points of its branch and by level, and with its parent |
| I17 | Chosen abilities: ≤ 3, distinct, from the family's pool and open (base, or with their A or V node) |
| I18 | Specialization null, or `level ≥ 10` and `available` |
| I19 | `veteran_xp > 0` only at the cap |

### 13.3 Database (migration 0011, [platform.md](platform.md) §20)

The next free migration (0011 if nobody has taken it): changes the `check` of `level` to 1-60 and recomputes `level` from `xp_total`
(§1.2); adds to `character_progress` five columns `attr_*` (smallint 0-118), `specialization_id`, `spec_changes` and `veteran_xp`; admits
currency 3 in `character_wallets`; and creates `character_masteries`, `character_talents` (`nodes text[]`, ≤ 20) and
`character_loadouts` (`abilities text[]`, ≤ 3), all with a cascading foreign key to `characters`, like the state tables of
[progression.md](progression.md) §3.3. About 1 KB more of JSON per character (it fits in the 1 MB body).

### 13.4 Go checks

**S9** (invariant I14), **S10** (I15-I17, with the exported trees) and **S11** (I18-I19), with the same cases generated by
`write_fixtures.gd` that the zone reads ([progression.md](progression.md) §13.3). S6 uses the 60-level curve; S2 admits the new reasons
per operation kind (RESPEC 69 in PLAYER operations, VETERAN_SEAL 18 in GAMEPLAY; the full registry is in
[progression.md](progression.md) §5.3). The exported rules ([progression.md](progression.md) §13.4) gain `level_curve` of 59 values,
`attributes`, `mastery_curve`, `talent_trees` (ids, branch, row, parent, family, opened ability), `specializations` (ids, level,
`available`) and `currencies` with currency 3.

---

## 14. Protocol

Version: each lane that changes the format bumps `PROTOCOL_VERSION` when it integrates (I65), without reserving numbers per lane. The
message registry (types, ranges, reasons) is in [networking.md](networking.md) and the codes in [progression.md](progression.md) §5.3;
this section only defines the bytes of the messages of the build.

| What | Format |
|---|---|
| `0x60` BUILD_REQUEST (C→S, reliable) | `u8 op`, `u32 request_id` and its body: 1 SPEND_ATTRIBUTES (5 × `u8`), 2 RESET_ATTRIBUTES, 3 SET_TALENTS (`u16 family`, `u32` mask of 30 bits), 4 RESET_TALENTS (`u16`), 5 SET_ABILITIES (`u16` and 3 × `u16`), 6 CHOOSE_SPEC and 7 CHANGE_SPEC (`u8`) |
| `0x61` BUILD_STATE (S→C) | The answer (`request_id` and code) and the whole build: attributes; per family level, mastery XP, mask and picked abilities; specialization and rank; the derived sheet (max health, factors per slot, mitigation, healing); `normalized` and effective level. **No per-character cooldowns** (I21) |
| `0x62` MASTERY_UPDATE (S→C) | `u16 family`, `u8 level`, `u32 xp_in_level`, `u32 xp_to_next`, `u32 gained`; at most 1 every 10 ticks per family |
| PROGRESS_UPDATE | `source`: 5 quest, 6 discover, 7 event, 8 dungeon, 9 craft or gather; plus `u8 flags` (bit 0: veteranship) |
| PLAYER ENTITY_SPAWN | +1 B: specialization (0 toward another realm) |
| ENTITY_EVENT `17 SPEC_CHANGED` | `u8`, only to the own realm |
| `PlayerInput` | Button 13 `ULTIMATE`; `VALID_BUTTONS = (1 << 14) − 1` |
| `CombatState` v6 | ≤ +13 B (`PlayerState` 111 → 124 B): `ability_picks` 3 B, `ultimate_ready` u32, `mana` u16 and `mana_regen_tick` u32, `load_class` in 2 bits of `combat_flags2`. The id of the ultimate travels in LOADOUT v2. **50 records** still fit in a snapshot |
| `sim_hash` | The trees and specializations enter (their network ids travel in the masks) |

The picks, mana and load class are configuration applied out of combat and imposed at the end of the tick like `set_weapons`
([progression.md](progression.md) §4.1); the client keeps the previous configuration to simulate old ticks again.

---

## 15. Code systems and files

| Layer | New | Touches |
|---|---|---|
| Shared, progression | `level_rewards.gd`, `attribute_rules.gd`, `stat_block.gd` (PRG-01), `passive_definition.gd`, `mastery_curve.gd`, `mastery_rules.gd`, `talent_tree.gd`, `talent_node.gd`, `talent_rules.gd`, `action_modifier.gd`, `specialization_definition.gd`, `spec_rank.gd`, `xp_tables.gd`, `quest_rewards.gd`, `pve_scale.gd`, `power_normalization.gd`, `normalization_rules.gd`, `character_build.gd` (build with encode and decode), `war_ranks.gd` | `level_curve.gd` (comments), `progression_rules.gd` (`XpTables` instead of `XP_PER_MERIT`, `overflow`), `item_definition.gd`, `progression_rules_export.gd` (new sections), `progress_json.gd` |
| Shared, combat | — | `weapon_definition.gd`, `ability_definition.gd`, `status_effect_definition.gd`, `combat_state.gd` (v6), `action_machine.gd` and `ability_rules.gd` (picked abilities, slot F, `reset_for_respawn` without touching `ultimate_ready`), `combat_catalog.gd` and `combat_tables.gd` (validation), `damage_formula.gd` (relative mitigation), `player_input.gd` |
| Shared, network | — | `net_protocol.gd` (version, 0x60-0x62, buttons), `progress_messages.gd`, `net_messages.gd` (SPAWN +1 B, event 17) |
| Server | `progress/build_service.gd` (BUILD_REQUEST: validates, charges and answers), `passive_system.gd` (conditions and triggers with ICD) | `damage_ledger.gd` (family per entry and healing), `combatant.gd` (sheet), `combat_director.gd` (applies the build on equip and on arrival), `combat_resolver.gd` (factors and passive hooks), `status_system.gd` (new effects), `downed_system.gd` (health on revive), `progress/player_progress.gd`, `progress_record.gd` (format 2), `progress_service.gd` (sources, mastery, normalization, veteranship), `progress_commands.gd` (GM: `mastery_set`, `attr_reset`, `talents_reset`, `spec_set`, in the next free DEBUG_COMMAND), the message routing of the zone-server parts |
| Client | `talent_window.gd` (K, UI-30), `spec_dialog.gd`, `attribute_tab.gd` in the character window | `input_bindings.gd` (`ultimate` F, `open_abilities` K), `action_bar.gd` (slot F), `inventory/character_window.gd` (attributes and War Sheet), `inventory/client_progress.gd` (build and masteries), `nameplate.gd` (icon to allies), `client_prediction.gd` (configuration with tick) |
| Platform (Go) | The migration of §13.3 | `internal/progress` (`rules.go`, `checks.go` with S9-S11, record in format 2), `internal/gamedata/progression_rules.json` (regenerated), `rules_test.go` |
| Tools and tests | `build_tables.gd`, `simulate_leveling.gd`, `test_progression_data.gd`, `test_progression_tables.gd`, `test_attribute_rules.gd`, `test_stat_block.gd`, `test_mastery_rules.gd`, `test_talent_rules.gd`, `test_build_service.gd`, `test_ability_loadout_net.gd`, `test_ultimate.gd`, `test_passive_system.gd`, `test_power_normalization.gd` | `export_rules.gd`, `write_fixtures.gd`, `combat_balance.gd`; tests that fix the cap 40: `test_level_curve`, `test_progression_rules_export`, `test_progress_messages`, `test_client_inventory`, `test_inventory_window`; `test_player_progress` (today it fails if an ability reaches 30 s: it will require that the ultimate is saved) |

`scripts/shared/` still does not depend on the client or the server (`test_architecture.gd`): everything shared is pure.

---

## 16. Dependencies

| Domain | What advancement needs | What it gives |
|---|---|---|
| **Weapons** (CMB) | The 2 branch abilities per weapon with their `.tres`; `family`, `tags` and attributes of each weapon; trees of the later weapons with the shape of §7.1; ground areas and pulses on allies (CMB-47, CMB-49) for three ultimates; mana and picks in `CombatState` (CMB-45, CMB-48) | Shape and validator of the trees, `ActionModifier`, the closed passive set, slot F |
| **Items** ([items.md](items.md)) | The item level scale and PE; affixes that scale with the item level of the piece; conditional equipment effects inside the 3 % cap; food without effect in normalized zones; cheap practice weapons of each family in the capital | The reference and the ceiling of war, respec costs (gold, `RESPEC`), `g_ref` consumers |
| **Economy** | `g_ref(L)` ([items.md](items.md) §15): the costs of §8.5 are meant to be ~10-30 min of income and are re-tuned with it | New `RESPEC` sinks |
| **NPCs** | `NpcDefinition.rank`, level from the zone, the scale of §11, the Master of the Orders and mentors in each capital, dummies in the capital to try ultimates, healing credit | XP and mastery tables by rank and difference, the O/D table |
| **Quests** | ≈ 150 unique quests per realm (§2.5), the quest "The Squire's Choice" at level 10, a `quest_completed` event with its level and kind | The reward table of §2.6 |
| **World** | Bands 1-10/10-20/20-32/32-45/45-60, `ZoneDefinition.normalized` and `min_level`, and the Vado Gris gate from level 10 | Hours per band to size each zone |
| **War** (GUE-25, PRG-32, PRG-33) | Siege for the Sapper; quartermaster tiers | War ranks and the normalization rule |
| **Social** (SOC-08, SOC-23, SOC-29) | Whole XP per member within 100 m; specialization icon in the group; inspecting allies shows the build | — |
| **Technology** (TEC-34) | Bots with specialization and ultimate in the Eldrun load test | The budgets of §10.2 |

---

## 17. Production order (lane D)

Lane D of the vertical-slice plan: **PRG-46** (cap 60), **PRG-01** (stat sheet), **PRG-17** (attributes), **PRG-18** (mastery), **PRG-19**
(talent frame), **PRG-47** (level rewards), **PRG-48** (build persistence), **PRG-22** (XP sources), **PRG-51** (validator and simulator),
**PRG-31 v1** (normalization of Vado Gris), **UI-74** (attribute allocation) and **UI-30** (experience and abilities window). It starts
after the requirements (TEC-65 in `main` and the protocol 8 of TEC-57) and nothing else waits for it except lane I for the O/D table.
Lane H (specializations) follows: **PRG-49**, **PRG-50**, **CMB-56**, **UI-75**, **UI-76** and **ART-85**, after D, E and F, with lane J for
the Master of the Orders. Later: **PRG-62** veteranship (phase 8), **PRG-32** war ranks (phase 7), **PRG-63** rested XP and **PRG-64** the Sapper
(phase 7, with GUE-25). **PRG-52** is shared with lane L.

Small increments, each with its test and screenshot (with new text, the same screen in Spanish and in English):

| # | Increment | Checked with | Screenshot |
|---|---|---|---|
| N1 | Cap 60: table generator, `level_curve.tres`, `required_level` range, migration and Go | `test_level_curve`, Go tests, deterministic `build_tables` | Character window at level 25 with the XP bar after `xp_add` |
| N2 | `StatBlock` with base health by level; `test_world` and `vado_gris` normalized (level only) | `test_stat_block`: the reference gives today's numbers; the balance tests do not change | Health 615 at level 1 in a non-normalized zone against 1000 in Vado Gris |
| N3 | Attributes: rules, BUILD_REQUEST 1-2, cost, partial format 2 and attribute tab | `test_attribute_rules`, `test_build_service` | Before and after spending, with the damage numbers on the dummy |
| N4 | Mastery: `DamageLedger` with family, split, MASTERY_UPDATE and bars | `test_mastery_rules` (70/30 gives 70/30; healing counts) | Mastery bars rising when killing Hollows with each weapon |
| N5 | Picked abilities (still with today's 3) | `test_ability_loadout_net`, 0 corrections | Bar with reordered abilities |
| N6 | Passives (server) and the sword-and-shield tree with Challenge and Rending Thrust; window K | `test_talent_rules`, `test_passive_system`, validator | Tree with 10 points and the dummy with the damage of a node |
| N7 | Bow tree with Piercing Arrow and Poison Arrow | Validator and balance | Bow tree and the poison on a dummy |
| N8 | Specializations: data of the five, choice at 10 (in the camp or by GM until the capital exists), cost, icon to allies | `test_build_service`, SPAWN message | Choice dialog and the icon above an ally |
| N9 | Slot F (`CombatState` v6, protocol version) and Ram's Charge | `test_ultimate`, 0 corrections | The Charge on the bar and in action against dummies |
| N10 | Ember Nova; then Hail, Banner and Prayer when CMB-47 and CMB-49 are ready | Tests against dummies and the target cap | One screenshot per ultimate |
| N11 | XP sources and simulator (with Hondal and its quests) | `simulate_leveling` within ±10 % | Hours-per-band report and the XP bar in the zone |
| N12 | Full normalization (rescaled attributes, rank V, compression of the item level after PRG-20) and the E measure | `test_power_normalization`, `combat_balance --sheet` | War Sheet of a level-1 character in Vado Gris |
| N13 | War ranks (phase 7) | PRG-32 test | Tabard insignia seen from another client |
| N14 | Veteranship and seals (phase 8) | Veteranship test | Character window with the veteranship level |

N1-N5 wait for nobody. N6 and N7 wait for the weapons' abilities, N9 for the protocol version, N10 for the areas, N11 for the zone and
the quests, and N12 for the affixes. **Gate of CV1-a:** today's balance tests unchanged; 0 prediction corrections with slots, mana and
ultimate; the Hondal flow gives level 10 at m10 ± 0.5 and about 4 h ± 10 %.

---

## 18. Risks

| Risk | Mitigation |
|---|---|
| 50 h × 3 realms is a lot of content (≈ 450 quests) | The curve is a data table; the first slice only tunes band 1-10; 30 % of the XP comes from repeatables and template events; the simulator says where it falls short. If it does not reach, stretch the pace `r(L)` of the high bands rather than write quests in a rush |
| Prediction divergences from per-character values | Only weapons, picks, ultimate, mana and load class are predicted per character (I21), all applied out of combat with a test of 0 corrections |
| Explosion of passive combinations | A closed set, caps per kind, validator, the 8 % budget per tree and the telemetry of CMB-38 |
| The normalization feels unfair or leaks | E measured with bots, not estimated; cuts in a fixed order (§10.2); the War Sheet shows what counts |
| Eldrun CPU (triggers and ultimates) | No auras, ICD ≥ 6 s, target caps, sheet computed outside the tick; TEC-34 with bots that use everything |
| Illegibility with many ultimates at once | One VFX per specialization, a budget and LOD for remote ones (ART-35) |
| The specialization becomes a closed class in practice ("no Vanguard with a shield, no entry") | ≥ 40 % of general value, changing is cheap and weapons have no requirement |
| Re-anchoring the balance breaks what was measured | The reference character is today's numbers (I18); the current balance tests act as a net |
| Two validators (GDScript and Go) that diverge | The same fixtures, as already done ([progression.md](progression.md) §17) |
| Gold costs mis-scaled | They are formulas in the data and are re-tuned with the economy (PRG-29, PRG-30) |
| Cap changes from 40 to 60 shift existing test characters | They are phase 5 test data; the migration recomputes the level (§1.2) |
