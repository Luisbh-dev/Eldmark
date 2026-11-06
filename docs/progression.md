# Eldmark · Phase 5: progression design

Design of what is saved for a character and what is played with it, in step 5 of the
[roadmap](vision.md#roadmap): items (PRG-02), what is saved and its invariants (PRG-10),
authoritative inventory (PRG-11), currencies and ledger (PRG-12), levels (PRG-13), races (PRG-14),
GM tools (PRG-16), persistent combat configuration (CMB-30), appearance (ART-19) and the
inventory and character window (UI-26).

Version 2: version 1 after the review by three reviewers (§18), later reconciled with platform.md (§13.1).
Whatever is marked "verified" comes from probes on this machine (Godot 4.7.2 headless, PostgreSQL 16, Go 1.24)
that are not committed.

It builds on [networking.md](networking.md), [combat.md](combat.md), [fortress.md](fortress.md), [social.md](social.md)
and `docs/abilities.md` (phase 4, already merged into `fase4-fuerte`). With **`docs/platform.md`**
(TEC-22 to TEC-28), written at the same time, the split is as follows:

- **platform.md**: service, accounts, ticket, claim, lease, `CharacterSaver` (when and
  how it saves), internal API, id blocks, purges and GDPR.
- **This document**: what goes in the `progress` section of the save (position, health and play time
  included), its invariants, its Go store (`platform/internal/progress/`, migration 0010 and the
  following progress ones, package P7) and what is played with it. What was agreed with platform.md is in
  [section 13](#13-interface-with-platformmd).
- **abilities.md**: weapons in `CombatState`, the LOADOUT event, `set_loadout`, `set_charges`, templates and
  potions. This document adds `ActionMachine.set_weapons` (§4.1) and changes the camp refill
  for anyone who has an inventory (§4.4).

## 0. Decisions

Provisional, **made overnight** (to be reviewed), like all the figures in the document (curve,
rewards, caps). The ones from the backlog recommendation and those left by the review are in
"Decisiones tomadas" (decisions made) in [backlog.md](backlog.md) with that mark.

| Question | Decision |
|---|---|
| What races does each realm have? | **One human people per realm, purely cosmetic**: hairstyles, beards, markings and the cut of the clothes. Same skeleton, same capsule, no racial stats (§7). Skin uses the full palette in all three realms |
| Slot-based or weight-based inventory? | **Slots in the bag** (30, expandable) and **weight only on worn equipment**, once armors arrive (PRG-06) |
| Currencies and bank per character or per account? | **Per character** (§5) |
| Spendable merits and realm points separate? | **Two counters with the same event** (fortress.md §0): spendable merits (currency) and realm points, which only go down when reverting the merits that gave them (I9) |
| Who gets XP and credit without target selection? | **Contribution**: everyone who deals ≥ 10 % of the damage in the last 900 ticks (`DamageLedger`, GUE-05), with a personal reward (§6) |
| Does level change stats in phase 5? | **No.** The base sheet is the same at any level until the PvE zone (PRG-22) and Eldrun normalization (PRG-31) enable it. Vado Gris is the only zone and it is RvR |
| What equipment is there in phase 5? | **The two weapons and the potions.** Armors, `StatBlock` and the derived sheet wait for PRG-01 and PRG-06, as in abilities.md §9. Equipment slots 2–6 exist and are reserved. *Provisional, made overnight* |
| Gold unit | A single integer, "gold", with no silver or copper |
| Can you equip in combat? | No: equip and unequip only out of combat and with no action in progress. Switching between the two weapons (Q, CMB-24) does work in combat |
| Phase 4 templates (PRG-07) | They become the **starter kit** (§2.5). The template is chosen **at creation** of the character (UI-24, platform.md §4.4) and is the kit of the first entry |
| Potions (PRG-08) | Stackable, bound items. The `CombatState` charges are the potions in the bag (cap 15). The camp refills the **total** to 3 health and 2 stamina, the squire's charges (§4.4) |
| Who owns CMB-30? Does time run offline? | **This document** (§8). **Yes**: long cooldowns are saved with their end in UTC. In phase 5 only `/atascado` (stuck) reaches 30 s. *Provisional, made overnight* |
| Loading, saving and idempotency | **Those of platform.md**: progress is the `progress` section of `CharacterSaver`, arrives in the claim before WELCOME and each save is applied once per `(lease_id, seq)` (platform.md §5.2 and §7; here, §9) |
| Position and health | They go in the record of §3.4; the rule for returning to the world is that of §8. In the RvR zones (all of those in phase 5) you return to the realm camp |
| Integers in JSON | **Ids as strings and the rest as numbers** (platform.md §4.1). Verified in Godot 4.7.2: `JSON.stringify` writes an exact int64, but `JSON.parse_string` returns `float` (it reads 2^53 + 1 as 2^53). Even so, all ids come from sequences and blocks that start at 1 and stay below 2^53 |
| Without platform | **Nothing is saved.** Every character is ephemeral, with an in-memory inventory. There is no local file mode. *Provisional, made overnight* |

The following remain **pending** (phase 6) and the model admits any answer: binding rules (the field
exists; starter items are bound), death penalty (durability exists and does not drop in
phase 5), format of the design data (in phase 5, hand-written `.tres`) and level in Eldrun.
`vision.md` ("To be defined: races") is updated on integration.

## 1. Who owns what

| Piece | Decided by | Where |
|---|---|---|
| Content of the `progress` section (race, appearance, position, health and play time included), invariants, items, inventory, ledger, levels, race and appearance rules, CMB-30, list of critical events, rule for returning to the world | This document | §2–§12 |
| Go progress store: migration 0010 and the following progress ones, checks S1–S8, ledger purge and retention, export, bodies of the operation and ledger routes, exported rules | This document (P7) | §3.3, §3.5, §13 |
| Service, ticket, claim, lease, `CharacterSaver` (when, `seq`, replies), internal API, id blocks, tombstone and purges, export file (GDPR) | platform.md | Its §5–§8 and §11 |
| Identity and name (`characters`); validation of race, appearance and template at creation | platform.md, with the rules exported from here | §7, §13.4 |
| Roles, audit, sanctions | platform.md and social.md | SOC-13, SOC-14, SOC-18 |
| Weapons in `CombatState`, LOADOUT, `set_loadout`, `set_charges`, templates, potions, refill | abilities.md (H1a–H3c) | For anyone with an inventory, §4.1 and §4.4 |
| Armors, `StatBlock`, derived sheet, visual ids per slot | PRG-01, PRG-05, PRG-06 and the rest of PRG-04: after phase 5, undesigned | §4.1, §7.3 |
| Merits: distribution and anti-farming | PRG-09 | Here they are only filtered and recorded (§6.2) |
| PvP stats; attributes, masteries, chosen abilities, rarity and affixes | platform.md (GUE-19); phase 6 (PRG-17 to PRG-20) | The item fields already exist (§2); their tables arrive with their entries |

**What is played in phase 5.** The player logs in with their account (UI-22) and creates a character (realm,
appearance of their people, template and name; UI-24). On first entry they appear in Vado Gris with the
kit of their template. They fight as in phase 4 and earn merits, realm points, XP and some gold from the
Hollow, the Ford Captain and captures. They level up (1–40), organize the bag, switch weapons out of
combat and drink the potions in their bag, which they refill at camp. On returning they find their weapons, their
currencies, their level, their health and the cooldown of `/atascado` (stuck). In Vado Gris they respawn at their
realm's camp.

## 2. Items (PRG-02)

### 2.1 Definition and instance

A **definition** is what an item is (design data in `data/items/<category>/<id>.tres`, in
the repo, with a stable `id`). An **instance** is a specific item that someone owns (a row of
`item_instances`, with a `uid` unique across the whole world and forever).

**`ItemDefinition`** (`scripts/shared/progression/item_definition.gd`, `Resource`):

| Field | Type | Rule |
|---|---|---|
| `id` | `StringName` | `[a-z0-9_]`, 3–32 characters, unique, never reused or renamed (the DB stores it) |
| `display_name`, `description` | `String` | Spanish; the name non-empty |
| `category` | `Category` | `WEAPON = 1`, `ARMOR = 2`, `CONSUMABLE = 3`, `MATERIAL = 4`, `QUEST = 5`, `MISC = 6` |
| `equip_slot` | `EquipSlot` | `NONE = 0`, `WEAPON = 1` (valid for both weapon slots), `HEAD = 2`, `CHEST = 3`, `HANDS = 4`, `LEGS = 5`, `FEET = 6` |
| `ref_id` | `StringName` | WEAPON → `WeaponDefinition.id` from `CombatCatalog`; ARMOR → the PRG-06 armor (no content in phase 5); CONSUMABLE → the consumable id in `CombatCatalog` (`potion_health`, `potion_stamina`); otherwise, empty |
| `max_stack` | `int` | 1 = not stackable; cap 999. Equippables and items with durability: 1 |
| `required_level` | `int` | 1–40 |
| `base_value` | `int` | Gold; ≥ 0. Basis of the phase 6 prices |
| `bind_rule` | `BindRule` | `NONE = 0`, `ON_EQUIP = 1`, `ON_PICKUP = 2` |
| `destroyable` | `bool` | false: the player cannot destroy it |
| `has_durability` | `bool` | The instance carries durability (per thousand) |
| `starter` | `bool` | Starter item (§2.5) |
| `camp_refill` | `int` | Total to which the camp refills that definition; 0 = not refilled (§4.4) |
| `icon_path` | `String` | `res://assets/icons/items/…`; client only. Empty: the slot cell draws the short name in the category color |
| `visual_paths` | `PackedStringArray` | Scene per body for armors (PRG-05); client only. Empty in phase 5: weapons are seen through their `CombatCatalog` id (abilities.md) |

Consistency required by the test: WEAPON ⇒ `equip_slot = WEAPON` and `ref_id` in `CombatCatalog`;
ARMOR ⇒ `equip_slot` from HEAD to FEET; CONSUMABLE ⇒ `equip_slot = NONE` and `ref_id` among the consumables of
`CombatCatalog`; equippable ⇒ `max_stack = 1`. `data/items/` has no armors in phase 5: the
ARMOR rule is tested with `tests/fixtures/items/`. `ItemDefinition` has no property of type
`Texture2D`, `PackedScene` or `Mesh`: the server preset trims `assets/` (TEC-12) and the server
must never try to load it.

**An item's net id never travels to another client.** What is seen of another player comes from their
`CombatState` (the weapons, public since abilities.md §5.2). The visible armors of PRG-05 and PRG-06
will carry their own visual id (`ItemDefinition.visual_id`, from an append-only visual catalog), which does not
allow deducing level, rarity or stats.

**`ItemInstance`** (`scripts/shared/progression/item_instance.gd`, `RefCounted`):

| Field | Type | Rule |
|---|---|---|
| `uid` | `int` | 1 … 2^53 − 1. Given by the zone's `IdAllocator` (§4.5) |
| `def_id` | `StringName` | Exists in `ItemDatabase` |
| `count` | `int` | 1 … `max_stack` |
| `durability` | `int` | 0–1000 (per thousand) if `has_durability`; otherwise −1 (NULL in the DB and in JSON, `0xFFFF` on the wire) |
| `rarity` | `int` | 0 common, 1 uncommon, 2 rare, 3 epic, 4 legendary. Phase 5: always 0 |
| `bound` | `bool` | Bound to the character |
| `seed` | `int` | u32 for the affixes (PRG-20); 0 = no affixes |
| `affixes` | `PackedInt32Array` | Up to 6 u16 affix ids (PRG-20). Phase 5: empty |

### 2.2 `ItemDatabase`

Like `CombatCatalog`: it reads `data/items/` (with subfolders) once, lazily, tolerates the
`.tres.remap` files of an exported project and logs errors only once.

- **Net id.** 1..n in alphabetical order of `id`; 0 = none. It changes when items are added, so it
  only travels on the wire to the owner and is never saved.
- **Fingerprint.** `wire_hash()`: u32 of the SHA-256 of the sorted list `(id, net_id, category,
  equip_slot, max_stack, has_durability)`. It enters `NetProtocol.compute_sim_hash` (§12): a client
  with a different catalog receives REJECT SIM_HASH. Cap: 65 535 definitions (u16).
- **Lookups.** `for_ref(category, ref_id)`: the item for that weapon or consumable (in phase 5 there is one
  per `ref_id`). `consumable_definition(index)`: the item of consumable `index` of
  `CombatCatalog.consumable_ids()` (0 health, R; 1 stamina, T).

### 2.3 Binary format (`ItemInstance.encode()`, version 1)

A single format for the network and the tests; the DB stores columns (§3), not this blob.

| Offset | Type | Field | Notes |
|---|---|---|---|
| 0 | u8 | format | 1. Any other value: `decode` returns null |
| 1 | u64 | uid | 1 … 2^53 − 1 |
| 9 | u16 | def | net id (≥ 1) |
| 11 | u16 | count | 1 … `max_stack` |
| 13 | u16 | durability | 0–1000; `0xFFFF` = no durability |
| 15 | u8 | rarity | 0–4 |
| 16 | u8 | flags | bit0 bound; the rest 0 |
| 17 | u32 | seed | |
| 21 | u8 | affix_count | 0–6 |
| 22 | n × u16 | affixes | |

Size: 22 + 2·n B (22–34). `decode(bytes, offset)` returns null if any byte is missing, the format
is not 1, the uid is 0 or reaches 2^53, the net id does not exist, the count is 0 or exceeds `max_stack`, the
durability does not match `has_durability`, the rarity exceeds 4, there are unknown flag bits or more
than 6 affixes. It never logs engine errors (networking.md §5.7).

### 2.4 Initial content (phase 5)

One item per weapon and per potion of phase 4. All carry `starter = true`, `bind_rule = ON_PICKUP`,
`required_level = 1` and `base_value = 0`:

| Items | Category | Stack | Notes |
|---|---|---|---|
| `sword_shield_vado` (sword and shield), `bow_vado` (bow) | WEAPON | 1 | `ref_id` = the `CombatCatalog` weapon; no durability; `destroyable = false` (in phase 5 there is no other way to obtain them) |
| `potion_health`, `potion_stamina` | CONSUMABLE | 15 | `ref_id` = the consumable; `camp_refill` 3 and 2 |

### 2.5 Starter kit and templates

On the **first entry** to the world (`starter_granted = false`), when the character is registered
(`ProgressService.on_arrival`), the zone creates the kit in a single STARTER_KIT operation and marks the save
as critical (`CharacterSaver.track` has already been called when creating the entity, platform.md §14.3). The template is, with platform, the `starter_template_id` of the record: it is chosen when creating the
character (UI-24), validated by the platform with `starter_templates` (the `EquipmentTemplate`s with
`selectable = true`, §13.4; platform.md §4.4) and stored in `character_progress`. For ephemeral
characters (§9.4) it is `ServerPeer.pending_template_id` (the one sent by LOADOUT_SELECT before CLIENT_READY;
abilities.md §4.6) or, if there is none, `default_template`:

1. Each weapon of the template → its item (`ItemDatabase.for_ref`), placed in equipment slots 0 and
   1 in the template's order.
2. Each starter item without `camp_refill` that was not equipped (the weapons of the other
   templates) → one unit in the bag, from slot 0 in `id` order.
3. Each item with `camp_refill > 0` → a stack with that quantity in the bag.

This preserves the phase 4 freedom (switching style) within the inventory. `starter_granted = true`
is saved. An unknown template uses the first in `id` order, with a warning in the
log.

For anyone with an inventory, LOADOUT_SELECT changes nothing after registration (an id that does not exist still
adds the warning of abilities.md §5.1) and respawning takes the weapons from their equipment, not from the
template. The client does not show the selector to anyone who enters with a ticket and, without platform, hides it after
the first appearance. The **fake players** (`--fake-players`) have no inventory: they keep their
template (`--fake-loadout`) and the refill from abilities.md §4.6.

## 3. The character that is saved (PRG-10)

### 3.1 What is saved (one owner per field)

The only table of who saves what; platform.md §3 cites it. Everything is columns: there is no `characters.state`
or state JSON.

| Group | Fields | Where | Owner |
|---|---|---|---|
| Identity | `character_id`, `account_id`, `world_id`, `realm`, `name`, `name_key`, dates, deletion with grace period, mandatory rename, tombstone | `characters` | platform.md |
| Race and appearance | `race_id`, `appearance` (exactly 8 B, §7.2) | `character_progress` | This document; the platform validates them at creation with the exported rules (§7.2, §13.4) |
| Position, yaw, health, play time | `last_zone_id`, `last_channel`, `pos_x`, `pos_y`, `pos_z`, `yaw`, `last_in_combat`, `health`, `played_seconds` (also for SOC-38) | `character_progress` | This document (§3.4, §8) |
| Level | `level`, the only copy (the character list, UI-23, reads it with `ProgressStore.Summaries`) | `character_progress` | This document |
| Progress | `xp_total`, `realm_points`, `bag_slots`, `starter_template_id`, `starter_granted` | `character_progress` | This document |
| Inventory | One row per instance | `item_instances` | This document |
| Currencies | Balance per currency and the ledger | `character_wallets`, `ledger_entries` | This document |
| Operations | Operations, participants, item events and reversals | `economy_ops`, `op_participants`, `item_events`, `op_reversals` | This document |
| Combat (CMB-30) | `active_weapon_slot` and long timers | `character_progress`, `character_timers` | This document (§8) |
| Save | `saved_at`, `save_version` | `character_progress` | The columns, this document; the rule, platform.md §7.3 (written by `Apply`, S8) |
| PvP | Totals | `character_pvp_stats` | platform.md (GUE-19) |
| Lease and id blocks | `lease_id`, `seq`, hash and `save_version` (`last_save_version`) of the last save; blocks given to each instance | `character_leases`, `id_blocks` | platform.md |

Chosen abilities are not saved (in phase 5 they are the weapon's fixed kit, abilities.md §2.3) nor
are potion charges (they are the potions in the bag, §4.4).

### 3.2 Invariants

They are checked by the zone when applying and by the service when saving (§13.3, S1–S8).

| # | Invariant |
|---|---|
| I1 | A `uid` identifies a single instance in the whole world and is never reused, not even after destroying it (the retired row stays). While it lives it keeps `def_id`, `seed`, `rarity` and `affixes`: only `count`, `durability`, `bound` (from false to true, I12), container and slot change |
| I2 | A live instance is in a single place: `(character_id, container, slot)` is unique. In phase 5 there are no ownerless items |
| I3 | `1 ≤ count ≤ max_stack ≤ 999` |
| I4 | **Conservation.** The total quantity of a definition only changes with an item event (source, sink, reversal or migration, §5.3). Moving, splitting, merging, swapping and equipping do not change it and leave no events |
| I5 | `0 ≤ balance ≤ cap` of its currency and `balance = Σ delta` of its entries |
| I6 | Entries and item events are immutable; each belongs to an operation, and `(op_id, character_id)` is applied only once |
| I7 | An operation is atomic and is never split across two saves |
| I8 | `level = curve.level_for(xp_total)`, between 1 and 40; at the cap no XP accumulates; `xp_total` only goes down with a GM or REVERSAL operation |
| I9 | `realm_points` goes up with each merit entry of reason 3–5 (gameplay) and by the same amount; it only goes down when reverting those entries |
| I10 | EQUIPMENT contains only weapons, in slots 0 and 1, and the active slot holds a weapon |
| I11 | The appearance is valid for its race and the race belongs to the character's realm |
| I12 | `starter_granted` never goes back to false; `bound` never goes from true to false; `bag_slots` does not change in phase 5 |
| I13 | A save is applied once: idempotency by `(lease_id, seq)` from platform.md §7.3 |

### 3.3 Schema (migration `0010_progress`)

It is the only progress DDL (platform.md §3 cites it); P7 writes it, with its `.down.sql` and the conservation
seed `internal/migrate/testdata/seed_0010.sql` (platform.md §2.4). No table carries
`world_id`: it comes from `characters`, which is not deleted while rows of the character remain (tombstone,
platform.md §11.2). The **state** tables hang from `characters` with `on delete cascade`. The **append-only**
ones reach `characters` through `op_participants`, with a foreign key **without cascade**: a `delete from
characters` with a ledger fails, never halfway, and they are deleted by retention (§3.5). Verified on PostgreSQL 16
with probes in `build/` (the one for this document and the one for platform.md §2.6): constraints, trigger,
two-character operation, retired uid that is not reused, slot swap with the deferred constraint,
tombstone and one-year retention.

```sql
create table character_progress (character_id bigint primary key references characters on delete cascade,
  race_id text not null, appearance bytea not null check (length(appearance) = 8),
  starter_template_id text not null, starter_granted boolean not null default false,
  level smallint not null default 1 check (level between 1 and 40),
  xp_total bigint not null default 0 check (xp_total >= 0),
  realm_points bigint not null default 0 check (realm_points >= 0),
  played_seconds bigint not null default 0 check (played_seconds >= 0),
  bag_slots smallint not null default 30 check (bag_slots between 1 and 120),
  health int check (health >= 0),                                               -- null: full
  active_weapon_slot smallint not null default 0 check (active_weapon_slot between 0 and 1),
  last_zone_id text, last_channel smallint, pos_x real, pos_y real, pos_z real, yaw real,   -- null: has never entered
  last_in_combat boolean not null default false,
  saved_at timestamptz,                                                         -- the platform's now() when applying
  save_version bigint not null default 0);                                      -- counter; it is not the idempotency
```

No `consumable_def_id` (potions are fixed, R and T) nor `updated_at` (it is `saved_at`). `characters` does not
gain `level` or `state`.

| Table | Columns | Keys and constraints |
|---|---|---|
| `character_wallets` | `character_id`, `currency smallint` (1 gold, 2 merits), `balance bigint`, `last_seq bigint` | PK (`character_id`, `currency`), cascading FK; CHECK `balance BETWEEN 0 AND 1000000000` |
| `item_instances` | `uid`, `character_id`, `container smallint` (0–3), `slot smallint` (0–119), `def_id text`, `count int` (1–999), `durability smallint` (0–1000; NULL = none), `rarity smallint` (0–4), `bound bool`, `seed bigint` (0 … 2^32 − 1), `affixes integer[]` (≤ 6, each 0–65535), `created_op bigint` (NULL = born from a split), `retired_at timestamptz` | PK `uid` (CHECK > 0), cascading FK; CHECK `(retired_at IS NULL) = (container IS NOT NULL AND slot IS NOT NULL)`; UNIQUE (`character_id`, `container`, `slot`) **DEFERRABLE INITIALLY DEFERRED**; index by `character_id` for the live ones |
| `character_timers` | `character_id`, `key text` (`^[a-z0-9_:]{1,48}$`), `ends_at timestamptz` | PK (`character_id`, `key`), cascading FK (§8) |
| `economy_ops` | `op_id`, `kind smallint` (§5.3), `actor_account_id` (NULL except GM and REVERSAL; also NULL in those when issued from the console), `ref_op_id` (the reverted one), `zone_id text` (that of the saving instance, `SaveKey.ZoneID`), `note text` (≤ 200), `detail jsonb`, `created_at` | PK `op_id` (CHECK > 0); CHECK `kind BETWEEN 1 AND 15`; CHECK: `kind` GM or REVERSAL ⇒ `note` non-empty. **Append-only** |
| `op_participants` | `op_id`, `character_id` | PK (`op_id`, `character_id`); FK `op_id` to `economy_ops` and `character_id` to `characters`, **without cascade**; index by `character_id`. **Append-only** |
| `ledger_entries` | `entry_id` (identity), `character_id`, `currency`, `seq bigint`, `op_id`, `delta bigint`, `balance_after bigint`, `reason smallint`, `ref_kind smallint`, `ref_id bigint`, `created_at` | UNIQUE (`character_id`, `currency`, `seq`); FK (`op_id`, `character_id`) to `op_participants`; CHECK `delta <> 0`, `balance_after` 0 … cap; index (`character_id`, `entry_id` desc). **Append-only** |
| `item_events` | `event_id` (identity), `op_id`, `character_id`, `def_id`, `uid bigint` (NULL = aggregate), `reason smallint`, `count_delta int`, `created_at` | FK (`op_id`, `character_id`) to `op_participants`; CHECK `count_delta <> 0`; index (`character_id`, `op_id`). **Append-only** |
| `op_reversals` | `op_id`, `reversal_op_id` | PK `op_id`; UNIQUE `reversal_op_id`; both FK to `economy_ops`: an operation is reverted once. **Append-only** |

`container`: 0 BAG, 1 EQUIPMENT, 2 BANK (PRG-25), 3 reserved; in phase 5 only 0 and 1. The slot constraint
is deferred so that a swap fits in one transaction. A `uid` that dies (destroyed
or merged into another) is not deleted: its row is left **retired** (`retired_at`, with no container or slot) and the
primary key prevents reusing it. Operations are multi-character from the start
(`op_participants`): phase 6 trading saves a single operation with both.

The trigger for the five append-only tables (`economy_ops`, `op_participants`, `ledger_entries`,
`item_events`, `op_reversals`):

```sql
create function eldmark_append_only() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' and coalesce(current_setting('eldmark.retention_purge', true), '') = 'on' then
    return old;                                                                 -- only the retention of §3.5
  end if;
  raise exception '% es de solo añadir', tg_table_name using errcode = 'P0001';
end $$;
create trigger append_only before update or delete on ledger_entries
  for each row execute function eldmark_append_only();   -- and the same on the other four
```

`0010_progress.down.sql` drops triggers, function and tables in reverse order. The tables for
attributes (PRG-17), masteries (PRG-18) and chosen abilities (PRG-19) arrive with their entries, in
their own migrations with the next free number (platform.md §2.4: the ranges only apply in phase 5).

### 3.4 `ProgressRecord` in JSON (`progress_format` 1)

It is the `progress` key of the claim (platform.md §6, complete) and, without the read-only fields and
with the journal, that of the body of each save (§9.3). It is built by `PlayerProgress.build_section` and read by
`ProgressRecord.from_dictionary`; the P7 store (`Load`) returns a newly created character with the
default values. `progress_format` is `ProgressRecord.FORMAT`, the `record_format` that the zone declares
when registering (platform.md §7.1). Every id (`uid`, `op_id`, `actor_account_id`, `ref_op_id`, `ref_id`,
`seed`) is a decimal string (platform.md §4.1) with an integer from 1 to 2^53 − 1 (`seed` and `ref_id`, from
0); the other integers are exact numbers (`v == floor(v)`; they are converted with `int()`). Otherwise, the zone
rejects the record.

```json
{"progress_format": 1, "race_id": "race_vardheim", "appearance": "AQAAAQEDAgE=",
 "starter_template_id": "squire", "starter_granted": true, "level": 8, "xp_total": 12345,
 "realm_points": 420, "played_seconds": 5400, "bag_slots": 30, "active_weapon_slot": 0, "health": 820,
 "location": {"zone_id": "vado_gris", "channel": 0, "x": 12.5, "y": 0.0, "z": -40.25, "yaw": 1.57,
              "in_combat": false, "saved_at_unix": 1793282400},
 "wallets": [{"currency": 1, "balance": 150}, {"currency": 2, "balance": 3200}],
 "items": [{"uid": "1025", "def_id": "sword_shield_vado", "container": 1, "slot": 0, "count": 1,
            "durability": null, "rarity": 0, "bound": true, "seed": "0", "affixes": []},
           {"uid": "1027", "def_id": "potion_health", "container": 0, "slot": 1, "count": 3,
            "durability": null, "rarity": 0, "bound": true, "seed": "0", "affixes": []}],
 "timers": [{"key": "unstuck", "ends_at_unix": 1793282700}]}
```

- `appearance`: the 8 B of §7.2 in base64. `health`: integer; null = full. `location`: null if it has never
  entered; otherwise, zone, channel, position and yaw (from the entity), "in combat" (from the `Combatant`) and
  `saved_at_unix`. `played_seconds`: the loaded value plus what was played since registration.
- **Only in the claim** (they are not in the save and S1 rejects them): `race_id`, `appearance`,
  `starter_template_id` and `location.saved_at_unix` (set by `Load` from `saved_at`). `to_dictionary` gives the
  save shape and `to_claim_dictionary(saved_at_unix)` the claim shape, with them: the round trip
  in the tests is `from_dictionary(to_claim_dictionary(t))`.
- `items` are the live instances. Timers are in Unix seconds. Chosen abilities are not
  saved in phase 5 (§8).
- `from_dictionary` returns null on a missing or unknown key, a mismatched type or an
  out-of-range value. Level and `xp_total` must satisfy I8. The validity of the appearance is checked by
  `ProgressService.prepare` (§7.2, §9.1).

### 3.5 Retention and purge

| What | How long | How |
|---|---|---|
| State: progress, balances, items (live and retired), timers | Until the character is purged | `ProgressStore.Purge` |
| Operations, participants, ledger, item events, reversals | While the character exists and **1 year** after its purge (PRG-39) | The `characters` tombstone and `ProgressStore.PurgeRetention` |

- **Purge.** That of platform.md §11.2 (character when `restore_until` expires, with the account, and in
  `reapply-purges`) calls, inside its transaction, with the lease and the `characters` row
  already locked and no live lease, `ProgressStore.Purge(ctx, tx, characterID)`, which
  deletes `character_progress`, `character_wallets`, `item_instances` (the retired ones too) and
  `character_timers` and leaves the append-only ones. Then the platform does its part: the `characters` row
  is left as a **tombstone** (name to null, `purged_at`) and is not deleted until the retention ends.
  It is the only tombstone: there is no other in progress, and the foreign key without cascade of `op_participants`
  prevents deleting it earlier (verified, platform.md §11.2).
- **Retention.** The hourly job of platform.md §2.5 calls `ProgressStore.PurgeRetention(ctx, tx)
  (deleted int64, emptied []int64, err error)` as long as `deleted` is greater than 0, one transaction at a time.
  Inside, `set local eldmark.retention_purge = 'on'` and it deletes, at most 10 000 entries per call, the
  entries, events and participations of characters with `purged_at < now() − 365 days`; then, the
  reversals and operations left without participants. `emptied` are the characters purged more
  than a year ago that no longer have rows in `op_participants` (also those that never had any): in the same
  transaction, the platform deletes only those `characters` rows, without looking at progress tables. Legal
  review of the year (§16).
- **Without the mark**, UPDATE and DELETE always fail (also after a transaction that set it: `set
  local` only applies inside it, verified). Correcting data means adding MIGRATION entries; a
  migration that had to delete sets the same mark and is reviewed by hand.
- **Pseudonyms, only after purging the account.** After the character is purged, `character_id` points to a
  nameless tombstone and no `detail.args` names it (the target goes by id, §10), but the tombstone is still
  tied to its account: while the account exists, that ledger belongs to the holder and is exported. It becomes a pseudonym
  when the account is also purged and becomes a tombstone. The victims' `ref_id`s are not rewritten (it would be an
  UPDATE on an append-only table). The `note` of GM and REVERSAL operations is staff text and
  is kept as moderation data (legal review, platform.md §11.1).
- **Export.** `ProgressStore.Export(ctx, q, characterID)` returns the record (`null` for a tombstone) and the
  character's own operations, entries and events; for GM and REVERSAL operations, the kind, the date, the entries and
  the events, without `actor_account_id`, `note` or `detail` (staff data). The platform puts it under
  `characters[i].progress` of the platform.md §11.2 archive, also for the account's tombstones with a
  retained ledger.

## 4. Authoritative inventory (PRG-11)

### 4.1 Containers and slots

| Container | Slots | Rules |
|---|---|---|
| 0 BAG | `bag_slots` (30; cap 120) | Any item; stacks merge |
| 1 EQUIPMENT | 7: 0 WEAPON_1, 1 WEAPON_2; 2 HEAD, 3 CHEST, 4 HANDS, 5 LEGS, 6 FEET reserved | One weapon per slot; in phase 5 slots 2–6 give CANNOT_EQUIP |

The worn equipment **is** the EQUIPMENT container. After each confirmed change to slots 0 or 1, the
zone imposes the weapons on the `CombatState`:

```gdscript
# scripts/shared/combat/action_machine.gd (extends abilities.md §7.2; added by P2)
## Sets the weapons of the two slots without resetting anything else. Only with action NONE: otherwise it does nothing
## and logs the error (the inventory never calls it then: NOT_NOW from §4.2).
static func set_weapons(c: CombatState, weapon_1: int, weapon_2: int, second_active: bool,
		ready_1: PackedInt64Array, ready_2: PackedInt64Array) -> void
```

- It sets `weapon_id` and `alt_weapon_id` according to `second_active`, `ability_ready[0..2]` with those of the
  active weapon and `[3..5]` with those of the other, and bit0 of `combat_flags2` = `second_active`.
- It does not touch `consumable_ready_tick`, the charges, the movement slots or the buttons.
- The `ready_*` are absolute ticks of each weapon (3 values; empty = 0). `PlayerProgress` keeps in
  memory those of a weapon that is removed (`stash_ready`) and returns them when it is put back: unequipping and
  equipping does not reset cooldowns. On spawn and respawn they are empty, as in `set_loadout`.
- `CombatDirector.commit_state` and LOADOUT (abilities.md §5.4, `template_id` 0 = the inventory
  equipment) follow, to the owner and, if the weapons change, to whoever has them in relevance (with `charges` 0).
- It is applied at the end of tick `s`, with the registrations; the simulation uses it from `s + 1`. The correction of the
  owner is explained by their own LOADOUT (`NetClient._note_imposed_state`, abilities.md §5.4).

With slot 0 empty and slot 1 active, `weapon_id` is that of slot 1 and `alt_weapon_id` 0 (there is no SWAP).

**The active slot has a single source: bit0 of `combat_flags2`** (CMB-24), which SWAP (Q, predicted and
valid in combat) and `set_weapons` change. `InventoryState` does not store it: `InventoryOps.Context.active_weapon_slot` carries it to
each request, and it is filled in by `PlayerProgress.apply_request` from the server's `CombatState` and by the client from its
predicted state. This way WEAPON_REQUIRED looks at the weapon that is actually in hand.

### 4.2 Operations

All are client intents that the server validates and applies whole or not at all.

| Op | Code | Effect |
|---|---|---|
| MOVE | 1 | To an empty slot: moves the stack. To a stack of the same stackable definition, with the same `bound` and room: **merges** `min(count, max − destination)` and what does not fit stays. In any other case (another definition, another `bound` or full destination stack): **swaps**. To or from EQUIPMENT it is **equip** or unequip |
| SPLIT | 2 | Takes out `n` (1 ≤ n < count) to an empty bag slot, with a new `uid` |
| DESTROY | 3 | Removes `n` (0 = the whole stack); if nothing is left, the `uid` dies |

When equipping an item with `ON_EQUIP` it becomes bound (`bound = true`) and the change travels in the delta.

**Validation, in this order; the first failure gives the code:**

| Code | Name | When | Text (`result_text`) |
|---|---|---|---|
| 0 | OK | Applied | — |
| 1 | INVALID | Unknown op, container or slot out of range (containers 2 and 3 in phase 5), impossible quantity (MOVE with `count ≠ 0`, SPLIT outside 1..count−1 or to a slot that is not in the bag), source equal to destination. **Adds a warning** (networking.md §12) | "Petición no válida" (invalid request) |
| 2 | STALE | The source is empty or its `uid` is not `expected_uid` | "Ese objeto ya no está ahí" (that item is no longer there) |
| 3 | NOT_NOW | No character or outside the world. The op touches EQUIPMENT and the character is dead, knocked down, in combat (`Combatant.is_in_combat`) or with an action (`CombatState.action ≠ NONE`: drinking, switching weapons, getting up and finishing included). DESTROY of a consumable while drinking one (otherwise the commit would subtract a charge from 0). SPLIT or DESTROY without ids for clients (§4.5). DESTROY with 256 or more unconfirmed operations in the journal (the platform is not responding: this keeps the save body from growing without limit, platform.md §7.3); `PlayerProgress.apply_request` checks it before `InventoryOps` | "Ahora no puedes hacerlo" (you cannot do that now); in combat, "No puedes cambiar el equipo en combate" (you cannot change equipment in combat) |
| 4 | CANNOT_EQUIP | Incompatible equipment slot, slot 2–6 in phase 5 or `required_level` above the level | "No puedes equipar eso ahí" (you cannot equip that there) or "Necesitas nivel N" (you need level N) |
| 5 | WEAPON_REQUIRED | It would leave the active weapon slot empty (`Context.active_weapon_slot`, §4.1) | "Necesitas un arma en la mano" (you need a weapon in hand) |
| 6 | NO_ROOM | SPLIT to an occupied slot | "No cabe" (it does not fit) |
| 7 | LOCKED | DESTROY of something equipped or of an item with `destroyable = false` | "Ese objeto no se puede destruir" (that item cannot be destroyed) |
| 8 | RATE | Checked on arrival, before everything else: more than 8 requests/s (burst 16), or more than 2 SPLIT and DESTROY per second (burst 10; they spend ids). After the first ten dropped in each 10 s, each adds a warning, like chat (social.md §5) | "Más despacio" (slow down) |

`InventoryOps.apply()` is **shared and pure**: the server uses it to decide and the client for its
optimistic intent (§11), so both validate identically. The server queues requests on arrival
(in `poll`) and applies them at the end of tick `s`, after the registrations (networking.md §8.1), in arrival order.

### 4.3 Transactional in memory and in the DB

- `InventoryOps.apply()` computes the result on a copy of the slots involved and only if everything
  is valid does it write it to the `InventoryState`.
- **Moving, splitting, merging, swapping and equipping create no events and spend no `op_id`**: their result
  goes in the save snapshot. SPLIT spends one `uid`. Only DESTROY (sink) produces an event, in a
  PLAYER operation.
- The `PlayerProgress` journal stores the operations with events or entries that a save has not yet confirmed.
  Each save sends the full snapshot and the journal operations that were not yet in any
  body (§9.2), and the service applies it in **one** transaction (I7).
- `kill -9`, SIGTERM or SIGINT (they do not reach GDScript, networking.md §1.3) lose whatever came after the last
  accepted save (60 s at most, platform.md §7.4), and both the change and its record at once: the DB
  never sees one without the other. TEC-25 tests it by killing the process (§15, P8).
- Each applied request leaves a line in the zone log (character, op, slots, uids,
  result).

### 4.4 What the server changes on its own

| Reason | When | Effect |
|---|---|---|
| `STARTER_KIT` | First entry | §2.5; standalone operation, critical save; then INVENTORY_FULL |
| `CAMP_REFILL` | Step 8 of the tick (abilities.md §4.1), every 60 ticks, if alive, out of combat and in the safe zone of its realm | For each definition with `camp_refill`: `missing = camp_refill − count_of(def)` (bag and equipment). If missing > 0, it is added to the stack of that definition with the lowest slot up to `max_stack` and the rest goes to a new stack in the first free slot, with a `uid` from the server range (§4.5; without one, that part waits for the next block). Bag full: it is not refilled and a NOTICE "Bolsa llena" (bag full) arrives, once per entry into the safe zone. Aggregate (§5.2). It **replaces** the refill from abilities.md §4.6 for anyone with an inventory |
| `CONSUME` | After step 1 (simulate), if a consumable's charge dropped: it is the commit of drinking (abilities.md §3.3, rule 5) | −1 per charge spent, from the stack of that definition with the lowest bag slot. An interrupted drink does not lower the charge and spends nothing. Aggregate |
| `GM_GRANT`, `GM_REMOVE`, `REVERSAL` | Commands from §10 | Standalone operation, critical save |

Splitting the stack does not give more potions: the refill looks at the definition's **total**.

**Charges.** For anyone with an inventory, each consumable's charge is `min(15, count_of(def))`, with
`def = ItemDatabase.consumable_definition(i)`. It is imposed with `ActionMachine.set_charges` (it only touches the
charges, abilities.md §3.5) and LOADOUT to the owner at two moments:

- after each confirmed change to the quantity of a consumable (CONSUME, CAMP_REFILL, DESTROY, GM,
  reversal);
- on registration and on respawn, as the `charges` argument of `set_loadout` and `reset_for_respawn`.

With more than 15 in the bag, after drinking the charge returns to 15 with a LOADOUT. Command 16 `refill`
(abilities.md §5.1), for anyone with an inventory, refills up to `camp_refill` without checking zone or combat. Without
platform it is a forced CAMP_REFILL (aggregate). **With platform** it requires `admin` and is one more GM command (§10):
a GM operation with a GM_GRANT (7) event for what is missing of each definition, `note` "debug", the actor and the
`detail` of the trace, and a critical save; this way S2 admits it and it stays in the audit. Fake players keep the
template and the refill from abilities.md.

### 4.5 `uid` and `op_id`: blocks

- With platform, a single generator, that of platform.md §6: `POST /internal/v1/id-blocks
  {zone_instance_id}` → `{"first": "1025", "count": 1024}` (global sequence `uid_block_seq` and table
  `id_blocks`), through `ZonePlatform.request_id_block()`. Both `uid`s and `op_id`s come from the same block,
  unique across all worlds. The service rejects (S2, S5) new ones that do not fall in a block of the
  instance that claimed.
- `IdAllocator` holds two blocks at most and requests another when fewer than 512 remain above the
  save reserve.
- **Three ranges.** The last `build_reserve` ids (2 × `max_players`: 128 with 64 seats) are only taken by
  `build_section`, to close aggregates when building a save. The 256 above them (`SERVER_RESERVE`) belong to the
  rest of the server (kit, new CAMP_REFILL stack, closing aggregates before a standalone operation, GM,
  reversal), which stops at `available() ≤ build_reserve`: GM and reversal reply with their warning without
  creating anything, the kit is not given (`starter_granted` stays false and arrives on the next entry) and CAMP_REFILL does not open
  the new stack until the next block. A client SPLIT or DESTROY with `build_reserve + 256` or fewer gives
  NOT_NOW. This way no client leaves another unable to drink nor the zone unable to save: with the platform down nothing goes out except the in-flight save, nobody new enters and each character
  builds at most two bodies (the next and the final), which the reserve covers.
- Aggregated operations take their `op_id` when building the save: drinking and refilling never wait for
  an id (except the new stack, which comes from the server range). If `build_section` still has no id (a
  bug: the reserve exists so it does not happen), it returns `{}` without touching anything and `CharacterSaver` does not send that
  save (platform.md §7.2).
- **First block**: it is part of the platform.md §8 startup (after the fortress GET and before
  opening the port, with the same retries); `startup_finished` waits for it and it reaches
  `ProgressService` as an `id_block` event, like the following ones.
- A half-used block lost in a crash leaves a gap: it does not matter, nothing is ever repeated.
- Without platform, `IdAllocator.local()` counts from 1 in memory (nothing is saved).

### 4.6 Network messages

Reliable channel 3, types `0x50`–`0x5F` (chat uses `0x40`–`0x47` and groups `0x48` onward).
No message exceeds 1200 B. INVENTORY_DELTA, INVENTORY_FULL, WALLET_UPDATE and PROGRESS_UPDATE only
go to the owner. `NetClient` decodes them and emits signals; `SwarmBot` decodes and discards them.
Neither counts them as malformed unless `decode` fails (§14.1, P4).

**INVENTORY_REQUEST** (`0x50`, C→S, 18 B)

| Offset | Type | Field | Notes |
|---|---|---|---|
| 0 | u8 | type | `0x50` |
| 1 | u16 | request_id | 1–65535; the client increments it on each request and skips 0 |
| 3 | u8 | op | 1 MOVE, 2 SPLIT, 3 DESTROY |
| 4 | u8 | from_container | 0 or 1 |
| 5 | u8 | from_slot | |
| 6 | u8 | to_container | `0xFF` in DESTROY |
| 7 | u8 | to_slot | `0xFF` in DESTROY |
| 8 | u16 | count | MOVE: 0. SPLIT: n. DESTROY: n (0 = whole stack) |
| 10 | u64 | expected_uid | The `uid` the client sees at the source |

**INVENTORY_DELTA** (`0x51`, S→C, 10 B + entries, ≤ 1120 B). Reply to a request or a server-side
change.

| Offset | Type | Field | Notes |
|---|---|---|---|
| 0 | u8 | type | `0x51` |
| 1 | u32 | revision | Inventory revision after applying; unchanged if `result ≠ 0` |
| 5 | u16 | request_id | 0 = change decided by the server |
| 7 | u8 | result | Code from §4.2 |
| 8 | u8 | reason | Reason (§5.3) of the server-side change; 0 in replies |
| 9 | u8 | entry_count | 0–30 |
| 10 | … | entries | `u8 container`, `u8 slot`, `u8 present` (0 empty, 1 with item) and, if `present`, `ItemInstance.encode()` |

With `result ≠ 0` the entries carry the **real** contents of the slots the request touched, so
the client reverts without guessing.

**INVENTORY_FULL** (`0x52`, S→C, ≤ 1089 B). On entering the world (after the owner's own SPAWN), after the starter
kit and in reply to a sync: `u8 type`, `u32 revision`, `u8 bag_slots` (1–120),
`u8 page_index`, `u8 page_count` (1–8), `u8 entry_count` (0–30) and, only for occupied slots,
`u8 container`, `u8 slot` and `ItemInstance.encode()`. The client gathers the pages of one
revision and only then replaces its state.

**INVENTORY_SYNC_REQUEST** (`0x53`, C→S, 1 B). Requests an INVENTORY_FULL. One every 5 s; more, a warning.

**Revision.** A u32 that starts at 1 with each session (not saved) and goes up by 1 with each applied change.
An applied delta (`result` 0) whose revision is not the confirmed one + 1 makes the client request a sync.

**`decode` validation:** exact size according to the counters, `entry_count ≤ 30`, `present` 0 or 1,
`page_index < page_count ≤ 8`, op between 1 and 3, containers 0–3 (destination `0xFF` in DESTROY; the server
rejects 2 and 3 in phase 5) and each item per §2.3. It returns null in any other case.

## 5. Currencies and ledger (PRG-12)

### 5.1 Currencies

| Code | Currency | Cap | Sources in phase 5 | Sinks in phase 5 |
|---|---|---|---|---|
| 1 | Gold | 1 000 000 000 | Defeated NPCs, captures, GM | GM only. Phase 6 opens trading, repair and skill-tree reset |
| 2 | Merits | 1 000 000 000 | PvP and objectives (PRG-09), GM | GM only. The quartermaster arrives in phase 7 (PRG-33) |

- **Per character**, `int64`, never negative (CHECK in the DB and `CurrencyRules` in the zone).
- **Realm points**: they are not a currency. They go up with each merit entry of reason 3–5, in the same
  operation and by the same amount (I9). GM merits do not move them.
- What is earned in phase 5 testing can be wiped when the phase 6 economy opens: a
  migration with reason `MIGRATION` leaves the balances at 0 with its entry.

### 5.2 Entry

- `op_id`: the operation (§4.5). `(op_id, character_id)` is applied once (I6).
- `currency`, `delta` (≠ 0), `balance_after` (balance after the entry), `reason` (§5.3; its sign must
  match its range) and `ref_kind`, `ref_id`: 0 none; 1 character (PvP victim: their
  `character_id`); 2 NPC and 3 fort (the u32 fingerprint of its text id: `HandoffTicket.zone_key_of(id)`,
  the same function as the `zone_key` of platform.md §5.1, and `tickets.ZoneKey` if Go needs it; the
  `NpcCatalog` ids change when NPCs are added); 4 operation (the reverted one). Example: `hollow` gives 3021413298
  (the test case here); `vado_gris`, 0x19efc013, the one from the platform.md vector.
- `seq` (1, 2, 3… per balance) is **set by the service**: `last_seq + 1` in journal order. The zone does not
  send it.
- In the operation: `actor_account_id` (the GM's account or null), `note` and `detail` (§10).

**Aggregation.** Gameplay gains and spends (merits, NPC and capture gold, CAMP_REFILL, CONSUME)
change the balance or the bag in memory immediately and are recorded when the save is built. They go in one
GAMEPLAY operation with one entry per (currency, reason, `ref_kind`, `ref_id`) and one event without `uid` per
(definition, reason). A player in battle leaves about five entries per minute, not one per second.

**Journal order.** Before creating a standalone operation (player DESTROY, kit, GM, reversal),
`PlayerProgress` closes the aggregated items as a GAMEPLAY. This way the journal is always in application order
and each `balance_after` comes from the balance already recorded. Example: 100 gold in the DB, +2 from an NPC and a
`currency_add +50` → GAMEPLAY (+2, 102) and then GM (+50, 152).

### 5.3 Reasons (`EconomyReason`, u8, fixed: never reused)

Range 1–63: **sources** (`delta > 0`). Range 64–127: **sinks** (`delta < 0`). Range 128–191:
**internal** (any sign).

| Code | Reason | Phase | Code | Reason | Phase |
|---|---|---|---|---|---|
| 1 | STARTER_KIT | 5 | 64 | PLAYER_DESTROY | 5 |
| 2 | CAMP_REFILL | 5 | 65 | CONSUME | 5 |
| 3 | PVP_KILL | 5 | 66 | GM_REMOVE | 5 |
| 4 | PVP_ASSIST | 5 | 67 | VENDOR_BUY | 6 |
| 5 | OBJECTIVE (circle, gate, capture, defense) | 5 | 68 | REPAIR | 6 |
| 6 | NPC_KILL | 5 | 69 | RESPEC | 6 |
| 7 | GM_GRANT | 5 | 70 | TRADE_OUT | 6 |
| 8 | LOOT | 6 | 71 | MAIL_OUT | 6 |
| 9 | QUEST | 6 | 72 | CRAFT_INPUT | 6 |
| 10 | VENDOR_SELL | 6 | 73 | QUARTERMASTER | 7 |
| 11 | TRADE_IN | 6 | 74 | MARKET_FEE | 8 |
| 12 | MAIL_IN | 6 | 128 | REVERSAL | 5 |
| 13 | CRAFT_OUTPUT | 6 | 129 | MIGRATION | 5 |

The same codes serve for item events. Operation kinds (`economy_ops.kind`,
`EconomyOp.Kind`): 1 PLAYER, 2 GAMEPLAY, 3 STARTER_KIT, 4 GM, 5 REVERSAL, 6 MIGRATION; 7 TRADE and 8 MAIL
(phase 6); 9–15 reserved.

### 5.4 Rules

- An operation that would leave a balance negative or above the cap is not applied whole (also in
  memory: `CurrencyRules.can_apply`). A gameplay gain that exceeds the cap is clamped to the cap.
- **Concurrency in the zone.** A character lives in a single zone (lease, TEC-25) and its
  operations are applied in order within the tick: there are no races.
- **Concurrency in the DB.** The save locks the lease (`for update`, platform.md §7.3),
  so two saves of the same character run in series. In addition, each balance is written with `UPDATE …
  SET balance = balance + delta WHERE … AND balance + delta >= 0`. Verified with PostgreSQL 16 and two
  simultaneous transactions that spend 60 from a balance of 100: the second waits for the lock, re-evaluates
  the condition, touches no row and aborts; the balance stays at 40 and the ledger sum is 40.
- **Reconstruction.** `balance = Σ delta` of its entries; checked by the test and, daily, by PRG-30.
- **Idempotency.** The save's is that of platform.md §7.3. Within progress, an operation
  repeated in a new save fails S2: an `op_id` that is already in `economy_ops` does not enter again.

## 6. Levels and experience (PRG-13)

### 6.1 Curve

`LevelCurve` (`data/progression/level_curve.tres`): `level_cap = 40`, `xp_to_next:
PackedInt32Array` of 39 values and `attribute_points_per_level = 1`. The values were generated with
`round((500 + 150 · (L − 1)^1.6) / 10) · 10`, but the data is the table, not the formula:

| Level | XP to next | Total XP to reach the next |
|---|---|---|
| 1 | 500 | 500 |
| 5 | 1 880 | 5 350 |
| 10 | 5 550 | 25 060 |
| 20 | 17 180 | 140 320 |
| 39 | 51 050 | 783 780 (cap) |

With about 3000 XP per hour of battle in Vado Gris, level 10 arrives in about 8 h. The real pace
and the hours per level are set by PRG-22 in phase 6 with the PvE zone.

### 6.2 Sources in phase 5

| Source | XP | Gold | Rule |
|---|---|---|---|
| PvP kills and assists | `merits × 10` | — | The PRG-09 merits (damage distribution and anti-farming included). **Only if the victim is a persistent character from another realm**; those of NPCs, fake players and ephemeral characters give no merits or PvP XP. No gold, so that gold cannot be bought by arranging deaths |
| Objectives | `merits × 10` | — | The PRG-09 objective merits (circle, gate, defense), with no victim |
| NPC | `NpcDefinition.xp_reward` | `NpcDefinition.gold_reward` | Each contributor with ≥ 10 % of the damage in 900 ticks receives the full reward (§0). No merits. Values: `hollow` 40 XP and 2 gold; `realm_guard` 60 and 3; `ford_captain` and `realm_captain` 400 and 50; `gate_guardian` 0 and 0 |
| Capture | 300 | 20 | To each player in the platform.md §8 list (of the capturing realm, present, alive and connected in the circle on the capture tick, with no invisible GMs or characters flagged by a GM command), the same one that `ScoreKeeper.captures` adds. **Once per character and fort every 30 min**: timer `capture:<fortress_id>` (§8). Critical save |
| GM | `xp_add` | `currency_add` | §10 |

- `xp_reward` and `gold_reward` are two new fields of `NpcDefinition`
  (`scripts/shared/ai/npc_definition.gd`, MUN-07), defaulting to 0, and are filled in `data/npcs/`.
- **With `--platform` and `--fake-players` the zone gives no persistent reward** and says so in the
  log at startup: the fakes could help capture or hold a circle. The options and their
  guard are from platform.md §5.5.
- **An invisible GM receives no rewards** (platform.md §9.1): no merits, no XP, no gold, not even the
  capture one. Nor do they count as an NPC contributor: they deal no damage, so they are not in `DamageLedger`.
- **With platform, whatever a fort command causes pays nothing persistent** (to anyone, not even the GM who
  uses it while standing in the circle). `fort_owner`, `fort_reset` and `fort_kill_captain` mark their change as
  **forced**, and a capture with `capture_rate_multiplier ≠ 1` (`fort_capture_speed`) is too.
  `ScoreKeeper.captures`, `on_capture`, `on_npc_killed` and the PRG-09 objective merits skip a forced
  change, just like everything with `--fake-players`. Without platform, as today (ephemeral characters).
- **With platform, a GM command that moves, heals or shows a character marks it as forced** until its
  next respawn: `/gm teleport` (the one moved), `/gm visible` (the GM) and DEBUG_COMMAND 1 `teleport`,
  2 `heal` and 4 `stamina_inf`. The mark is `NetEntity.gm_forced` (the field and its clearing on respawn, platform.md P6; setting it, platform.md P7b).
  While it lasts, the character does not enter the capture list (`ScoreKeeper.captures` and `on_capture`) nor collects in
  `on_merits` or `on_npc_killed`, just like with a forced fort change: a `gm` does not lead anyone, not even themselves,
  to collect with a command. Without platform, as today.
- Capture without defenders is not penalized yet: in Vado Gris the normal thing is to take it from the
  Hollow. Arranged captures and farming belong to GUE-35 (phase 7).
- Group XP sharing belongs to SOC-23 (phase 6).

### 6.3 Leveling up

- `ProgressionRules.add_xp(curve, level, xp_total, amount)` (pure, shared) returns the level,
  the total, the levels gained and what was applied. A single contribution can raise several levels. At the
  cap, 0 is applied and the total stays at `curve.total_to(40)`.
- **Attribute points** = `(level − 1) · attribute_points_per_level − Σ spent`. They are not saved:
  they are derived, so PRG-17 can change the distribution without migrating. In phase 5 they are shown and not spent.
- **What changes on leveling up:** nothing in the simulation or the sheet (§0). It shows in the character window and
  in the allies' nameplates, and unlocks items by `required_level`.
- **Notices:** PROGRESS_UPDATE to the owner (§12) and ENTITY_EVENT `16 LEVEL_UP` (`u8 level`, 10 B) to the owner
  and to those of the **same realm** who have it in relevance, for the visual effect; it does not reach the enemy
  (social.md §1). Leveling up marks the save as critical.
- PROGRESS_UPDATE is batched: at most one every 10 ticks per player, with the sum of what was gained.

## 7. Races and appearance (PRG-14, ART-19)

### 7.1 One people per realm

| Race (`id`) | Realm | Its own traits (extended by ART-20) |
|---|---|---|
| `race_vardheim` | Vardheim | Braids and manes, long beards, blue war paint and knot tattoos |
| `race_solmarch` | Solmarch | Short hair or tonsure, groomed beards, golden sun markings |
| `race_askarra` | Askarra | Tied-back hair, short beards, ash markings and forge scars |

The name of the people in the interface is provisional ("Gente de Vardheim", people of Vardheim) until the lore fixes it
(MUN-28). **Nothing changes in the simulation:** same `PlayerCharacter` scene, same 1.8 m
capsule, no stats; appearance does not enter the `sim_hash`. There is no height or build
control: the look must fill the same capsule that is used for hits, or the opponent would see a
body smaller than its hitbox. What changes is visual: hairstyles, beards, markings and, with PRG-05 and ART-27, the
cut and dye of the outfits. Askarra has its race in the data even though its realm cannot yet be
chosen (platform.md §0). Until ART-20, the three races share the pieces that are in the repo
(§7.4) and only the allowed colors change.

### 7.2 `CharacterAppearance`: 8 B

Indices into `AppearanceCatalog` (`data/characters/appearance_catalog.tres`), which has **append-only**
lists: `races`, `bodies`, `heads`, `hairs`, `beards`, `marks` (`AppearancePart`: `id`,
`display_name`, `scene_path: String` client-only and compatible `bodies`, empty = all) and
`skin_tones`, `hair_colors`, `eye_colors` (`AppearanceColor`: `id`, `display_name`, `color` and
`texture_path: String`, optional and client-only). The phase 5 catalog **only lists pieces that
exist** in the repo. `data/characters/appearance_ids.txt` freezes the order ("category index id" per
line), only grows, and the test requires the catalog to start with that list: nothing is reordered or
deleted (it is retired by removing it from the races). This way the 8 B stored in the DB remain valid after
any patch.

| Byte | Field | Value |
|---|---|---|
| 0 | race | index in `races` + 1 (0 is not valid) |
| 1 | body | index in `bodies` (in phase 5 only 0 exists; the female one arrives with ART-20, §16) |
| 2 | head | index in `heads` |
| 3 | hair | 0 no hair; otherwise index + 1 |
| 4 | beard | 0 no beard; otherwise index + 1 |
| 5 | skin | index in `skin_tones` |
| 6 | hair_color | index in `hair_colors` (hair, beard and eyebrows) |
| 7 | eyes and marks | bits 0–3: index in `eye_colors`; bits 4–7: 0 no marks or index in `marks` + 1 |

**`RaceDefinition`** (`data/characters/races/<id>.tres`): `id`, `realm` (`RealmCatalog` id),
`display_name`, lists of allowed indices per category, `allows_no_hair`, `allows_no_beard` and
`stat_modifiers` (must be empty: the test requires it). Marks take the realm's color.

**Validation** (`CharacterAppearance.validate(catalog, realm, race_id)`, with `realm` in the `NetProtocol.Realm`
code, the same as `claimed.realm` and `ValidateCreate`; inside it is translated with `RealmCatalog`): `race_id`
exists and belongs to the realm, and byte 0 is its index + 1 (the race is in both places and they must match); each index is in
the race's lists; each piece is compatible with the body (its `bodies`); a 0 for hair or beard only if
the race allows it (`allows_no_hair`, `allows_no_beard`). The rule is this one and two places apply it, with the
same data (the exported rules of §13.4 carry the pieces with their `bodies` and those two fields) and the
same cases: `tests/fixtures/progression/appearance_cases.json` (`[{realm, race_id, appearance, valid}]`,
with `realm` as a code (1–3) and `appearance` in base64 of the 8 B, as in the API; hand-written in P3, one or more
per rule), which are read by `test_character_appearance` and the Go test for
`ValidateCreate`. The platform, when creating the character, with `persistence.CreateValidator`, which implements
`*progress.Rules` (§13.2); until P3 and P7 exist, with the provisional one from platform.md §4.4 step 5 (`race_` + realm and any 8
B). The zone, when
loading it (`ProgressService.prepare`, with the claim's `race_id`): an invalid appearance is replaced
by `default_for(race)` and logged, without kicking the player.

### 7.3 In the SPAWN

The PLAYER payload of ENTITY_SPAWN (networking.md §5.5) grows by **9 B** after the name: `u8 level` and the 8 B of
appearance. `level` is 0 if the receiver is not of the player's realm (social.md §1: the enemy's level
does not cross over). That is why the SPAWN is encoded **per receiving realm**:

- `NetEntity.encode_spawn(tick, for_owner, receiver_realm)`; real `level` only if `for_owner` or
  `receiver_realm == realm`.
- `ZoneServer._announce_arrival` keeps at most three variants (one per realm) of the newcomer's
  SPAWN and sends each `other_peer` the one for its realm; the SPAWNs of the others toward the newcomer
  use the newcomer's realm. `_refresh_interest` uses the observer's realm.
- Today `_announce_arrival` encodes once and sends the same bytes to everyone: P4 changes the three
  places that call `encode_spawn` and `test_progress_messages` and `test_progress_loopback` test it.

There is no equipment block: the weapons already go in the public `PlayerState` (`weapon_id`, `alt_weapon_id`,
abilities.md §5.2) and change with LOADOUT. `decode` only checks the size; validity is checked by the
client (invalid → the race's `default_for`). The NPC payload does not change: `npc_def_id` stays right after
the name (networking.md §5.5), with no level or appearance. Bit 3 of `flags` (game staff) belongs to
platform.md §5.4 and goes in the same version.

### 7.4 On the client (Quaternius kit)

`AppearanceApplier` (client only) mounts onto `HumanoidVisual` (ART-01, a single `GeneralSkeleton`)
body, head, hair and beard as glTF scenes from Universal Base Characters and tints skin, eyes and hair per
material. Today the repo has `Superhero_Male_Head`, `Hair_SimpleParted` and `Hair_Beard` (Standard
version); the rest is the user's (§16). `HumanoidVisual` only mounts pieces in `_ready()`
(`_attach_part` is private), so it gains two public functions so that changing a piece does not recreate
the character:

```gdscript
# scripts/client/humanoid_visual.gd (extends; P6)
func set_part(slot: StringName, scene: PackedScene) -> void   # &"body", &"head", &"hair", &"beard", &"marks"
func clear_part(slot: StringName) -> void
```

PRG-05 equipment will hide hair and beard (hood, helmet) with the logic `HumanoidVisual` already has.

## 8. Persistent combat configuration (CMB-30)

It belongs to this document: platform.md only stores the `progress` section (§13.1). Here too is the only
rule for returning to the world (platform.md §0 and §7.1 cite it); `ProgressService.on_arrival` applies it.

| What | How it is saved | On load |
|---|---|---|
| The two weapons | They are EQUIPMENT objects 0 and 1 | `set_loadout` with their `CombatCatalog` weapons (abilities.md §3.5), at the place where H3c puts the template's |
| Active weapon | `active_weapon_slot` = bit0 of `combat_flags2` when building the save (CMB-24, the only source, §4.1): 0 WEAPON_1, 1 WEAPON_2; if that slot has no weapon (a DEBUG_COMMAND 5 on an empty WEAPON_1), the other, to satisfy I10 | On registration, after `set_loadout`, `set_weapons(…, second_active = true, [], [])` if it is 1. On respawn, `reset_for_respawn` leaves WEAPON_1 active; if WEAPON_1 is empty, `set_weapons(…, second_active = true, [], [])` right after, as on registration (both through `loadout_for`) |
| Chosen abilities | Not saved: in phase 5 they are the weapon's fixed kit (abilities.md §2.3). They arrive with PRG-19 | — |
| Consumables | The potions in the bag (§4.4) | Charges = `min(15, in the bag)` |
| Health | `health` of the record (§3.4), from the `Combatant`; null = full | `min(max, health + CombatRules.health_regen_per_s · (now_unix − saved_at_unix))`; with `health` null or 0, or without `location`, full |
| Cooldowns of 30 s or more | `timers`: key and `ends_at_unix` | `ready_tick = s + max(0, ends_at_unix − now_unix) · 60`; expired ones are discarded |
| Long effects | None in phase 5: the longest, `bleed`, lasts 6 s | When CMB-20 has one with `persists`, with key `effect:<id>` |
| Position | `location` of the record (§3.4): zone, channel, position and yaw of the entity and "in combat" of the `Combatant`. It is always saved: `enter` uses it (platform.md §4.5) | `PvpMode.RVR` zones (in phase 5, all of them: `vado_gris` and `test_world`): always the spawn point of its realm, the camp; this way nobody appears inside a fort that has changed owner. `SAFE` zones (from phase 6): the saved spot if `location.zone_id` and `channel` are those of this instance, `now_unix − saved_at_unix < 900`, `in_combat` is false, it was alive, it stands on ground and is not in another realm's safe zone; otherwise, the spawn point of its realm |

**Phase 5 timers:**

| Key | What | Who reads and writes it |
|---|---|---|
| `unstuck` | Cooldown of `/atascado` (5 min, fortress.md §5) | `UnstuckTracker.get_ready_at(player)` and `set_ready_at(player, tick)`, new; with platform, `player` is `"character:<id>"` instead of the normalized name |
| `capture:<fortress_id>` | Capture reward (30 min, §6.2) | `ProgressService` |
| `ability:<id>`, `consumable` | Reserved | No ability or consumable reaches 30 s (cooldowns range from 10 to 20 s). `test_player_progress` fails if one appears: its `ability_ready` would have to be imposed on spawn, only with the same weapon |

Time **runs offline** (decision §0). When building the save: `ends_at_unix = now_unix +
ceili((ready_tick - s) / 60.0)`, with `now_unix = ZonePlatform.now_unix()` (the corrected clock from
platform.md §6). In GDScript, `(ready_tick - s) / 60` between integers truncates before rounding and `ceil` returns
`float`: it would expire up to 1 s early and travel as a `float` in the JSON. `scripts/shared/` sees no dates and `scripts/server/progress/` does not read `Time`. Without
platform no timers are saved (ephemeral), so no other clock is needed.

**Nothing predicted per tick is saved**: not the rest of `CombatState` (stamina, action,
combo, controls, hitstop), nor the exact position between saves, nor cooldowns under
30 s (reconnecting resets them; §17).

**Handoffs (phase 6).** The ticket only carries the identity, and the CMB-30 data arrives with the final save and
the claim at the destination (platform.md §5.1). The origin zone performs a final save
with `release`. From the snapshot on, the character is **frozen**: inventory and currencies reply
NOT_NOW and it receives no rewards. The HANDOFF goes out only after the save's OK; if it fails, the handoff is
cancelled and unfrozen. The destination zone loads it in its claim.

## 9. Lifecycle in the zone

### 9.1 Loading and registration

1. HELLO with ticket → `TicketAuthProvider` → `VERIFYING` → claim (platform.md §5.2).
2. **Claim with 200** (`AuthOutcome.claimed: ClaimedCharacter`, with `progress: Dictionary`;
   platform.md §14.3). In the "poll" step, after checking the realm and the capacity and before the WELCOME (the
   order is that of platform.md §5.2), `ZoneServer` calls `progress.prepare(peer_id, claimed)`:
   - it decodes `ProgressRecord.from_dictionary(claimed.progress, ItemDatabase.shared())`;
   - it validates `appearance` with `race_id` and `claimed.realm` (invalid → `default_for`, warning);
   - it creates the peer's `PlayerProgress`.

   If it returns false, the zone replies REJECT `UNAVAILABLE` with "No se ha podido cargar el personaje" (the character could not be loaded),
   raises an alert in the log and releases (platform.md §5.2). This way nobody receives WELCOME without having passed the
   single use, the sanctions and the load.
3. WELCOME with the character's realm and `LOADING` (platform.md §5.2). If the peer leaves before
   CLIENT_READY (or is kicked), the zone calls `progress.cancel_prepared(peer_id)`, which discards the
   prepared `PlayerProgress`, and releases without saving (the `LOADING` departure of platform.md §5.2).
4. CLIENT_READY → `_process_arrivals`, which creates the entity and calls `CharacterSaver.track` (platform.md
   §14.3). Before the SPAWN, `progress.on_arrival(entity, peer, s)`:
   - binds the prepared `PlayerProgress` to the `net_id`;
   - starter kit if due (§2.5);
   - the rule for returning to the world (§8): places the entity and sets its health;
   - imposes the timers (`unstuck` with `set_ready_at`; expired ones are discarded);
   - `NetEntity.level` and `NetEntity.appearance`;
   - returns the `Loadout` (weapons, active slot and charges) that registration uses instead of the template.
5. After the owner's own SPAWN, `progress.after_spawn(entity, peer, s)`: INVENTORY_FULL, one WALLET_UPDATE per
   currency and one PROGRESS_UPDATE (state).

Without platform, step 2 does not exist: `on_arrival` creates an ephemeral character (§9.4).

### 9.2 The `progress` section of `CharacterSaver`

`ProgressService.setup` registers it with `CharacterSaver.register_section(&"progress", build, acknowledge,
is_dirty)` (signatures in platform.md §14.3):

| Call | What it does |
|---|---|
| `build(net_id, seq) -> Dictionary` | `PlayerProgress.build_section(seq)`: closes the aggregated items (one GAMEPLAY), takes position, yaw, health, "in combat", play time, `active_weapon_slot` and the timers (§8) and returns the snapshot (without the read-only fields) and **only the operations with `save_seq = 0`**, to which it sets `save_seq = seq` (§9.3). With no id to close the aggregates (`next_for_build`), it returns `{}` without touching anything (§4.5). It never resends one already marked: the final save built with another in flight does not repeat its operations (if the one in flight is applied, S2 would reject it; if it receives a definitive error, the final one is discarded along with it) |
| `acknowledge(net_id, seq)` | After 200 `applied` or `duplicate`: removes from the journal the operations with `save_seq ≤ seq`. On a `net_id` without `PlayerProgress`, nothing (after `finish` it is not called: platform.md §7.2) |
| `is_dirty(net_id) -> bool` | `PlayerProgress.is_dirty()`: some operation with `save_seq = 0`, some record field changed since the last confirmed one, position moved or different health |

There is no `restore`: `CharacterSaver` loads nothing (loading is `prepare` and `on_arrival`, §9.1).

- **When**: decided by platform.md §7.2 (every 60 s with changes, critical ones immediately, on exit with
  `release`, orderly shutdown). **The critical events** (the list is from here) are marked with
  `CharacterSaver.mark_critical(net_id, reason)`: `&"starter_kit"`, `&"level_up"`, `&"capture"` and `&"gm"`
  (every command in §10 that changes something, `op_revert` included); from phase 6, trading, mail and rare
  loot. `reason` only goes to the log and the metrics. Renaming is not critical: it does not change the body.
- **One `seq`, one body**: `build` is called once per `seq` and retries send the same body.
  Whatever changes while one is in flight goes in the next.
- **Exit**: in the order of platform.md §7.2: `CharacterSaver.finish(net_id, reason)` →
  `ScoreKeeper.forget` → `ProgressService.on_departure(net_id)`, which frees the state; on a `net_id` without
  `PlayerProgress` it does nothing. In `ZoneServer.stop`, `finish` of everyone before `_clear_players()` (today
  `stop()` empties the players in that same step).
- **Replies**: the table and the error rule are those of platform.md §7.3. Before `finish`, the
  section only receives `acknowledge` on 200, and on definitive errors (`lease_lost`, `stale_seq`, `seq_conflict`,
  `invalid_save` and any other 4xx) the zone performs the departure without save of platform.md §7.2: the body goes out
  immediately and `ProgressService.on_departure` discards the state without saving. After `finish`, replies no
  longer reach the section (platform.md §7.2).
- **Without `PlayerProgress`, nothing.** Every `ProgressService` hook that receives a `net_id` (`acknowledge`,
  `is_dirty`, `on_departure`, `loadout_for`, `on_merits`, `camp_step`, `on_capture` and `on_npc_killed` for each
  `net_id` in their list, `after_simulate` for each player) does nothing with one that has no `PlayerProgress`
  (`loadout_for` returns null and its caller uses the template, as with a fake).

### 9.3 The `progress` section of a save

It is the value of the `progress` key of the platform.md §7.3 body: the `ProgressRecord` of §3.4 without the
read-only fields, plus the journal (`ops`), in application order. It carries no zone: the save's zone is
that of the instance that claimed (`SaveKey.ZoneID`), which fills `economy_ops.zone_id` and against which S1
compares `location.zone_id`.

```json
{"progress_format": 1, "level": 8, "xp_total": 12345, "…": "rest of §3.4, without the read-only fields",
 "ops": [{"op_id": "5120", "kind": 2, "actor_account_id": null, "ref_op_id": null, "note": null, "detail": {},
          "ledger": [{"currency": 1, "delta": 2, "balance_after": 102, "reason": 6, "ref_kind": 2, "ref_id": "3021413298"},
                     {"currency": 2, "delta": 30, "balance_after": 3230, "reason": 3, "ref_kind": 1, "ref_id": "88"}],
          "items": [{"uid": null, "def_id": "potion_health", "count_delta": -1, "reason": 65}]},
         {"op_id": "5121", "kind": 4, "actor_account_id": "77", "ref_op_id": null, "note": "devolución del fallo 12",
          "detail": {"command": "currency_add", "source": "gm", "actor_character_id": "41", "at_unix": 1793282390,
                     "args": ["42", "oro", "50"]},
          "ledger": [{"currency": 1, "delta": 50, "balance_after": 152, "reason": 7, "ref_kind": 0, "ref_id": "0"}],
          "items": []}]}
```

- `items` of the snapshot: all live instances. `items` of an operation: its events (I4). An event
  carries `uid` when it concerns a specific instance (kit, GM, player DESTROY) and `null` when it is
  aggregated (CAMP_REFILL, CONSUME).
- The entries of each currency, in order. They carry no `seq` (§5.2).
- Idempotency is that of platform.md §7.3.

### 9.4 Without platform: ephemeral characters

- Without `--platform`, every player with a peer is ephemeral: `ProgressService.setup(zone, null, null, commands)`
  (there is no `CharacterSaver`) and `on_arrival` creates `ProgressRecord.new_character()` and the kit with the template
  from LOADOUT_SELECT (§2.5), with `IdAllocator.local()`. Nothing is saved and it is lost on exit: there is no
  `--progress-file` or other local store.
- Inventory, currencies, levels, potions and commands work the same, for testing locally (`--local`) and
  with bots (`--bot`, `--bots=N`).
- The journal stays in memory (the last 256 operations per character) for `op_show`,
  `ledger_show` and `op_revert`.
- With platform, all players with a peer are persistent (`AuthProvider.uses_tickets()`); fake
  players never have an inventory.
- Testing persistence locally requires the platform: `deploy/dev.sh` or its
  `docker-compose.yml` (platform.md §12).

## 10. GM tools (PRG-16)

Commands of the `CommandRegistry` (TEC-19): through the server console, through `/gm …` with a role (SOC-14,
platform.md §9.1: each command declares its `min_role`) and through DEBUG_COMMAND with the rules below. In
phase 5 the character must be connected in that zone; offline editing belongs to the moderation
panel (SOC-37, phase 8).

| Command | Arguments | Effect | Role | Network id |
|---|---|---|---|---|
| `item_give` | character def_id [quantity] | Creates in the first free bag slot (GM_GRANT); bag full → error | gm | 40: `u16 def`, `u16 count` (1–999) |
| `currency_add` | character oro\|meritos ±quantity reason… | GM_GRANT or GM_REMOVE entry; the written reason is the `note`, mandatory | gm | 41: `u8 currency` (1–2), `s32 amount` (≠ 0); `note` = "debug" |
| `level_set` | character level | Level and `xp_total = curve.total_to(level)` | gm | 42: `u8 level` (1–40) |
| `xp_add` | character quantity | As one more source | gm | 43: `u32 amount` (1–10 000 000) |
| `item_take` | character uid [quantity] | Destroys (GM_REMOVE) | gm | — |
| `mastery_set` | character weapon level | Reserved: "No disponible hasta la fase 6" (not available until phase 6) | gm | — |
| `inv_show` | character | Bag and equipment with uid, quantity and bound | gm | — |
| `ledger_show` | character [n = 20] | Last n entries: the unconfirmed journal and, with platform, `GET /internal/v1/characters/{id}/ledger` | gm | — |
| `op_show` | op_id | Entries and events of an operation (`GET /internal/v1/ops/{op_id}`) | gm | — |
| `op_revert` | op_id reason… | Reverts (below) | gm | — |

Ids 40–43 are fixed in `NetProtocol.DEBUG_*` and their `decode` validates size and ranges.

**DEBUG_COMMAND** (all ids, not just 40–43; always on the player themselves):

| Server | Rule |
|---|---|
| Without `--debug-commands` | Warning, as today (networking.md §12) |
| `--debug-commands`, without platform | As today: ephemeral characters, nothing is saved |
| `--debug-commands` and `--platform` | In addition, each command's `min_role` (platform.md §9.1) with the claim's role (`ClaimedCharacter.role`): `gm` or higher. Those that create or preserve value of a persistent character or bypass its equipment declare `admin`, because they always act on the player's own character (own-characters rule, below): ids 40–43; 5 `set_weapon` (sets a weapon that is not in its equipment, abilities.md §3.5); 13 `cooldowns_off` (drinks without spending potions, abilities.md §3.3); and 16 `refill` (creates potions, §4.4). Without a role: warning, and nothing is executed or saved |
| `--debug-commands`, `--platform` and `env` `staging` or `production` in the registry | The zone exits with code 1 (platform.md §5.5) |

**Trace of each command that changes something.** It creates a single operation: a GM one (even if it has no entries or
events) or, in `op_revert`, the REVERSAL (below). Both carry:

- `actor_account_id` (null only from the console);
- `note`: the written reason; "debug" for DEBUG_COMMAND; mandatory and non-empty;
- `detail`: `command`, `args`, `source` (`gm`, `console` or `debug`), `actor_character_id` (the GM's
  character; null from the console), `at_unix` (`ZonePlatform.now_unix()` when creating it: the time of its
  audit row and that of the actor's role in S2) and, if it touches level or XP, `level_before`, `level_after`, `xp_before`,
  `xp_after` and `xp_delta`. In `args`, the target character goes as its `character_id` as a string, never
  as the name the GM typed: the ledger is append-only and the purge could not remove it.

Its `audit_log` row is written by the save itself (§13.3, S8) with `event_key = "op:<op_id>"`, and the
entry in the zone's audit batch uses the same key and the same fields: whether it arrives before or after,
it is neither duplicated nor lost. The two-path rule and the fields are from platform.md §9.1 (`source` =
`console` if `detail.source` is `console`; otherwise, `zone`). Query commands (`inv_show`,
`ledger_show`, `op_show`, role `gm`) go to the audit batch like any other.

DEBUG_COMMANDs that change nothing saved (5 `set_weapon` and 13 `cooldowns_off`: they only touch the
`CombatState`) create no operation: they go only to the audit batch, with their key `<zone_instance_id>:<n>`. 16
`refill` does create one (§4.4).

**On a character of the GM's own account**, every command that changes something (also through
DEBUG_COMMAND, and `op_revert`) requires `admin`, with no exception per environment; otherwise, "No puedes usarlo sobre tus
personajes" (you cannot use it on your own characters). The service checks it again (S2, in the GM and REVERSAL operations). With an exception in `dev` or
`test`, the zone would accept the command, S2 would reject the save (`invalid_save`) and the character would lose whatever was
unsaved.

**Fenced zone** (platform.md §5.3): every command that changes something replies "El servicio de cuentas no
responde; inténtalo más tarde" (the accounts service is not responding; try again later) if `platform.is_fenced()`, without creating the operation. Critical gameplay events
(kit, level-up, capture) are not rejected: they are marked and go out as soon as possible.

**Reversal** (`op_revert op_id reason…`):

- Only of an already saved operation (with platform, it reads it from `GET /internal/v1/ops/{op_id}`; without
  platform, from the session journal) of a character connected in this zone. Not a REVERSAL, not a
  MIGRATION, not one already reverted (`op_reversals`, or a REVERSAL of it still unsaved in the journal: "Esa
  operación ya se está revirtiendo" (that operation is already being reverted)). One not yet saved: "Esa operación aún no está guardada; inténtalo
  en unos segundos" (that operation is not saved yet; try again in a few seconds).
- It closes the aggregates (§5.2) and creates a REVERSAL (the command's only operation) with `ref_op_id`, the
  reason as `note` and the actor and `detail` of the trace above. It is critical. All or nothing.
- **Entries**: another with the opposite `delta`, reason REVERSAL, `ref_kind` 4 and `ref_id` = the original.
  If a balance would go negative (they already spent it), nothing is reverted and the GM is told what is missing.
- **Events with `count_delta > 0`**: that quantity of the definition is removed. First from the event's `uid` if it is
  still alive, then from the bag stacks in slot order and, if it is equippable, from an equipment
  slot that is not the active one. Splitting or merging does not evade it. If the whole character does not
  have that much, nothing is reverted and the shortfall is stated.
- **Events with `count_delta < 0`**: that quantity is created with **other** `uid`s (I1), in stacks up to
  `max_stack`. If the event has a `uid`, the fields of its retired row are copied (the route returns it);
  otherwise, bound. Bag full: nothing is reverted.
- Reverted **merits** of reason 3–5: realm points go down by the same amount (I9).
- **XP**: the original's `detail.xp_delta` is subtracted from `xp_total` (without going below 0) and the
  level is recomputed.

## 11. Interface: inventory and character window (UI-26)

### 11.1 Windows

| Window | Key | Content |
|---|---|---|
| Inventory | I | 6-column grid with `bag_slots` cells (`InventorySlotView`, a `UIIconSlot` with drag); at the bottom, gold and merits |
| Character | C | 3D figure (SubViewport with `HumanoidVisual`, its appearance and its weapons; rotates on drag), the two weapon slots (the other five, grayed out with "Próximamente" (coming soon)), name, realm, level and XP bar, realm points, attribute points and the `CombatRules` sheet (maximum health and stamina). In phase 5 the sheet does not change with equipment |

Both use `UIWindow` (UI-09), open at the same time and free the cursor. You drag from one to the other.

### 11.2 Gestures

| Gesture | Request |
|---|---|
| Drag and drop | MOVE (move, merge, swap, equip, unequip) |
| Shift + drag | SPLIT, with a quantity dialog (default, half) |
| Double click or right click in the bag | Equip: a weapon, to WEAPON_2 if empty and otherwise to the inactive slot |
| Double click or right click on equipment | Unequip to the first free bag slot |
| Drop outside the windows | DESTROY after `UIConfirmDialog` ("¿Destruir Poción de vida ×3?" (destroy Health Potion ×3?), with quantity on stacks) |

**Tooltip** (`UITooltip`): name in its rarity's color, category and slot, required level (in
red if not met), what it provides (weapon: damage of its attacks and abilities from `CombatCatalog`; potion: its
effect), "Ligado" (bound), value and, on a weapon, the damage **comparison** with that slot's weapon (in green or
red).

### 11.3 Optimistic intent and rollback

`ClientInventory` (`scripts/client/inventory/`) stores the **confirmed state**, the list of
**pending requests** (8 at most; with 8, the interface waits) and a **view** that is the
confirmed state with the pending ones applied by `InventoryOps.apply()`, the same function as the server's.

1. **Gesture.** It is validated locally with `InventoryOps` (with the "in combat" state from the snapshot's
   extra block). If it fails, a warning with the code's text and nothing is sent.
2. **Send.** INVENTORY_REQUEST with the next `request_id`; it is added to pending and the view is
   recomputed: the item moves instantly. A stack created locally (SPLIT) carries a negative
   provisional `uid` (−`request_id`) and cannot be touched until the delta brings the real one.
3. **Delta.** Its entries are applied to the confirmed state, in arrival order; if it carries a `request_id`, that
   request leaves pending. The view is recomputed; a pending one that is no longer valid locally is
   removed (its own reply will arrive anyway).
4. **Rejection.** The delta carries the real contents of the slots: applied to the confirmed state, the item
   **returns to its cell**, with the code's warning.
5. **No reply in 5 s** (should not happen on a reliable channel): pending requests are emptied and
   INVENTORY_SYNC_REQUEST is sent; the FULL rebuilds everything.

What is **not** optimistic: the weapon in hand, the action bar (UI-11) and the charges change
with the **confirmed** state (LOADOUT and the own state), one RTT later; this way a rejection never
makes the weapon flicker.

## 12. Protocol

| What | Format |
|---|---|
| Version | **7**, that of platform.md §5.4: a single bump for the whole of phase 5, shared. It is bumped by platform.md P4 (which goes first in the joint order) with the complete line in `net_protocol.gd`; P4 here adds its part of the code without bumping it. What is here: +9 B of the PLAYER SPAWN, 0x50–0x55, ENTITY_EVENT 16 LEVEL_UP, DEBUG_COMMAND 40–43 and `ItemDatabase` in the `sim_hash`. What belongs to platform.md, in the same version: REJECT 10–12, 52 B ticket, `auth_timeout` of 10 s (`NetTransport.AUTH_TIMEOUT_SECONDS`) and bit 3 of the SPAWN header `flags`. In networking.md, each P4 writes the rows and the "v7" mark of its own part (the rule, platform.md §5.4): P4 here, §3 (`sim_hash` and the text of the REJECT `SIM_HASH`), §5.2 (0x50–0x55), §5.4 (40–43) and, in §5.5, the +9 B and LEVEL_UP |
| HELLO | Unchanged (platform.md §5.4) |
| PLAYER ENTITY_SPAWN | +9 B after the name: `u8 level` (0 if the receiver is not of its realm) and 8 B of appearance (§7.3) |
| `0x50`–`0x53` | INVENTORY_REQUEST (C→S, 18 B), INVENTORY_DELTA (S→C, ≤ 1120 B), INVENTORY_FULL (S→C, ≤ 1089 B), INVENTORY_SYNC_REQUEST (C→S, 1 B): §4.6 |
| `0x54` WALLET_UPDATE | S→C, 19 B: `u8 type`, `u8 currency`, `u64 balance`, `s64 delta` (0 in the initial state), `u8 reason`. At most one every 10 ticks per currency, with the delta summed |
| `0x55` PROGRESS_UPDATE | S→C, 25 B: `u8 type`, `u8 level`, `u32 xp_in_level`, `u32 xp_to_next` (0 at the cap), `u32 gained`, `u8 source` (0 state, 1 PvP, 2 NPC, 3 capture, 4 GM), `u64 realm_points`, `u16 attribute_points` |
| `0x56`–`0x5F` | Reserved (phase 6 bank, trading and mail) |
| ENTITY_EVENT `16 LEVEL_UP` | `u8 level`, 10 B. 16 leaves room for the phase 4 events (abilities.md uses 7 to 11) |
| ENTITY_EVENT `9 LOADOUT` | From abilities.md, unchanged: `template_id` 0 = the inventory equipment |
| DEBUG_COMMAND 40–43 | §10 |
| `sim_hash` | Adds `ItemDatabase.wire_hash()`, because item net ids travel. networking.md §3 comes to say "the simulation and the catalogs whose ids travel (`CombatCatalog`, `ItemDatabase`)" and the REJECT text, "Los datos del juego no coinciden con los del servidor: actualiza el cliente" (the game data does not match the server's: update the client). Appearance does **not** enter: an unknown index already falls back to the default appearance |

They live in `scripts/shared/net/progress_messages.gd` (`ProgressMessages`), apart from `net_messages.gd`
to avoid clashing with other lanes; over channel 3 and only to the owner except LEVEL_UP. A request before
being in the world adds a warning.

## 13. Interface with platform.md

### 13.1 Agreed with platform.md

The interface with platform.md, already reconciled. Each rule is written once, in the owning document;
the other cites it. The same table is in platform.md §17.

| Topic | Agreed | Owner | Cited by |
|---|---|---|---|
| Save idempotency | Only `(lease_id, seq)`: same `seq` and same SHA-256 → `duplicate` (applied, with the `save_version` stored in `character_leases`); another body → `seq_conflict`; lower → `stale_seq`. `save_version` is a counter that plays no part; `saved_at` and `save_version` are written by `Apply` (S8) | platform.md §7.3 | progression.md §5.4, §13.3 |
| Save body | Envelope with `save_format` 1 with one key per section: `progress` (the record without the read-only fields, with `ops`) and `pvp`. No `zone_id`: the zone is that of `claimed_by` | platform.md §7.1, §7.3 | progression.md §9.3 |
| Journal in the save | Each body carries only the operations with `save_seq = 0`, which `build` marks with its `seq`; `acknowledge(seq)` removes those with `save_seq ≤ seq`. A final save built with another in flight repeats nothing | progression.md §9.2 | platform.md §7.1, §7.2 |
| Formats | `progress.progress_format` is the `record_format` of the zone's registration (`ZonePlatform.RECORD_FORMAT`, from platform.md P4; `ProgressRecord.FORMAT` has the same value and progression.md P5a tests it): compatibility is decided at registration (409 `schema_mismatch`); in a save, another format is 400 `invalid_save` | platform.md §7.1 | progression.md §3.4 |
| `CharacterSaver` sections | `register_section(section, build, acknowledge, is_dirty)` with `build(net_id, seq)`, `acknowledge(net_id, seq)` and `is_dirty(net_id)`; no `restore`. `track(net_id, character_id, lease_id, tick)` when creating the entity, before `on_arrival`; `mark_critical(net_id, reason)`, `on_platform_event`, `save_rejected`, `drop(net_id, code)`. `CharacterSaver` assembles the whole envelope (`zone_instance_id` included); a `build` that returns `{}` defers that save (the final one does not wait: alert and `release`). Entries by `lease_id`, and each response, by the `lease_id` and `seq` of its request: after `finish` or `drop`, neither `acknowledge`, nor `is_dirty`, nor `save_rejected` | platform.md §7.2, §14.3 | progression.md §9.1, §9.2 |
| Critical events | Starter kit, level-up, capture and every GM command that changes something (`op_revert` included); from phase 6, trading, mail and rare loot. Renaming is not critical | progression.md §9.2 | platform.md §7.2 |
| When it saves | Every 60 s with any dirty section, in phases; one write in flight; the final one in `finish`. Exit: `finish` → `ScoreKeeper.forget` → `ProgressService.on_departure`; on stop, `release` of `LOADING`, `cancel` of `VERIFYING` and `finish` of everyone before `_clear_players()` | platform.md §7.2 | progression.md §9.2 |
| Departure without save | A definitive error before `finish` or a `revoked` `lease_lost`: `CharacterSaver.drop(net_id, code)` (with `release` except on `lease_lost`), kick with the body going out immediately (no combat logout), `ScoreKeeper.forget` and `ProgressService.on_departure`. Every `ProgressService` hook by `net_id` without `PlayerProgress` does nothing | platform.md §7.2 | progression.md §9.2, §14.2 |
| Departure in `LOADING` | Without save: `ZonePlatform.release(character_id, lease_id)` and `ProgressService.cancel_prepared(peer_id)`, also with a `revoked` | platform.md §5.2, §14.3 | progression.md §9.1, §14.2 |
| Save responses | One table and one error rule. Content or database that is not transient (`*persistence.InvalidSaveError`, SQLSTATE of class 22 or 23 or `P0001`, also at COMMIT): 400 `invalid_save` with `fields.check` and `fields.detail`. `40001` and `40P01` after retrying, no connection or timeout: 503. An envelope error: `invalid_save` with `check = "envelope"`. There is no `invalid_progress` or `progress.ErrFormat`. `instance_*`: shutdown with final saves. Any other 4xx is definitive, like `invalid_save`, also on release. `progress` is mandatory and `pvp` optional and without downgrade | platform.md §6.1, §7.3 | progression.md §9.2, §13.3 |
| Without platform | Nothing is saved: ephemeral characters; there is no `--progress-file` or progress repositories. `CharacterSaver` only exists with `--platform` and calls `ZonePlatform.save` | progression.md §0, §9.4 | platform.md §5.5, §7.5 |
| Claim | `{lease_id, instance_status, account, character, progress, pvp}`, only for a non-deleted character, with the account locked, with no other character of the account in the world and with `Load` in its transaction; in the zone, `AuthOutcome.claimed: ClaimedCharacter` with `progress: Dictionary`. There is no `CharacterRecord` class | platform.md §5.3, §6, §14.3 | progression.md §3.4, §9.1 |
| Before WELCOME | Realm → capacity → `ProgressService.prepare(peer_id, claimed)` → WELCOME with the character's realm; if anything fails, REJECT (`REALM`, `FULL` or `UNAVAILABLE`) and `release`. WELCOME does not change bytes | platform.md §5.2 | progression.md §9.1 |
| Record content | A single `ProgressRecord`, with race, appearance, `played_seconds`, `health` and `location`. Only in the claim: `race_id`, `appearance`, `starter_template_id` and `location.saved_at_unix` (`to_claim_dictionary` sets them). There is no `characters.state` or state JSON | progression.md §3.4 | platform.md §7.1 |
| Platform fake | `FakeZonePlatform` returns in the next claim the last applied data: `pvp` (platform.md P4) and `progress` without `ops`, with the read-only fields from the previous claim and `location.saved_at_unix` (progression.md P5a, with `claim_progress`). Its test API (`add_character`, `script_next`, `set_fenced`, `next_block_first`, `applied`, `sent`) is a single one, from platform.md P4 | platform.md §14.1, §14.3 | progression.md §14.1 |
| Returning to the world | RVR zones (all in phase 5): the realm camp. SAFE zones (phase 6): the saved spot if it is the same instance, under 15 min ago, out of combat and alive. Health regenerated with the elapsed time | progression.md §8 | platform.md §0, §7.1 |
| Who saves what | One table with all fields and their owner; `characters` only identity (it gains neither `level` nor `state`) | progression.md §3.1 | platform.md §3 |
| Progress tables | DDL of `0010_progress` only in progression.md, without `world_id`; the append-only ones, with a foreign key without cascade to `characters` through `op_participants`; trigger on all five; `actor_account_id` in the GM and REVERSAL operations | progression.md §3.3 | platform.md §3 |
| Migrations | In phase 5, 0001–0006 of the platform and 0010_progress (progression.md P7, with `.down.sql` and seed); afterwards, the next free number, whoever's it is. The runner applies in order and refuses a pending one below the highest applied. There is no P3b | platform.md §2.4 | progression.md §3.3 |
| Id blocks | `POST /internal/v1/id-blocks {zone_instance_id}` → `{first, count: 1024}`, in `starting` and `live`; `uid_block_seq` and `id_blocks` in 0003_zones; the first block, at startup; `Apply` rejects ids outside the blocks of `claimed_by` | platform.md §3, §6, §8 | progression.md §4.5, §13.3 |
| Purge and retention | The tombstone is the `characters` row. The purge locks the lease and the character row, and does not purge with a live lease; with the account and in `reapply-purges` (which runs before `serve` and deletes restored leases) a null `purged_at` suffices; `ProgressStore.Purge` deletes the progress state; `PurgeRetention` empties the ledger after a year and returns the empty tombstones, which the platform deletes; `reapply-purges` preserves `purged_at` | platform.md §11.1, §11.2 | progression.md §3.5 |
| Export | `ProgressStore.Export` of each non-purged character and of each account tombstone with a ledger (without record), under `characters[i].progress`; of GM and REVERSAL operations, without actor, `note` or `detail`. A tombstone's ledger is a pseudonym only after purging the account | platform.md §11.2 | progression.md §3.5 |
| `ProgressStore` in Go | `Create`, `Load`, `Apply`, `Summaries`, `Purge`, `PurgeRetention` (with the empty tombstones), `Export`, `Op` (with the instance) and `Ledger`, with raw JSON at the boundary; its errors (`InvalidSaveError`, `ErrNotFound`) and creation validation (`CreateValidator`, `*ValidationError`) in `internal/persistence`, from platform.md P2, which `*progress.Rules` implements. The platform does not read progress columns | progression.md §13.2 | platform.md §7.5 |
| Operation and ledger | `?zone_instance_id=` routes of the platform's internal router (checks from its §6.1), only with a lease on the instance (the character's, which the router checks; or that of some participant, which `Op` checks in its own query); otherwise, 404. Bodies from progression.md; `limit` from 1 to 100 | platform.md §6 | progression.md §13.2 |
| Ids in JSON | Decimal string for every `bigint` id, also in the claim and in the save (`jsonx.ID`, up to 2^63 − 1; progress ones, up to 2^53 − 1 by S1); number for quantities, balances, level, `seq`, codes and dates. Realms: text id in the public API and code in the internal one | platform.md §4.1 | progression.md §0, §3.4 |
| Save checks | S1–S8 of progression.md; lease and `seq` are steps 2 and 3 of the save, with no S number. S2 admits from the zones kinds 1–5 with their reasons, rejects an already saved `op_id` and checks the GM and REVERSAL actor with the role they had at `detail.at_unix` (the CLI `set-role` row, platform.md §9.1). S7 admits past dates | progression.md §13.3 | platform.md §6.1, §7.3 |
| Level | Only `character_progress.level`; the character list reads it with `Summaries` | progression.md §3.1 | platform.md §4.4 |
| Race and appearance | `race_vardheim`, `race_solmarch` and `race_askarra`; 8 B in `character_progress`, with byte 0 from `race_id`; validated by the platform at creation (`ValidateCreate` or the provisional one) and by the zone on load (`default_for`), with the same exported rules (pieces with their `bodies`, `allows_no_hair`, `allows_no_beard`) and the same cases (`appearance_cases.json`); the realm, in the `NetProtocol.Realm` code in `validate`, `ValidateCreate`, the rules and the cases | progression.md §7.2 | platform.md §4.4 |
| Starter template | Chosen at creation (`starter_template_id`, UI-24) among the `selectable` ones; it is the first entry's kit; with platform, LOADOUT_SELECT changes nothing | progression.md §2.5 | platform.md §4.4, §13.2 |
| Exported rules | One file (`platform/internal/gamedata/progression_rules.json`), one tool (`tools/progression/export_rules.gd`) and one test (`test_progression_rules_export.gd`); `protocol_version` and `names` are from platform.md. Test data shared with Go, under `tests/fixtures/` | progression.md §13.4 | platform.md §4.4 |
| Protocol | `PROTOCOL_VERSION = 7` for the whole of phase 5, with `AUTH_TIMEOUT_SECONDS = 10.0`; fixed split (5 chat and groups, 6 abilities.md); bumped by platform.md P4, after abilities.md, with the complete line in `net_protocol.gd`; progression.md P4 adds its own without bumping it. In networking.md each P4 writes the rows and the "v7" mark of what its code adds | platform.md §5.4 | progression.md §12 |
| CMB-30 | Belongs to progression.md; the platform stores the `progress` section | progression.md §8 | platform.md §7.1 |
| Ticket and handoffs | 52 B, identity only; the CMB-30 data arrives with the final save and the claim at the destination (phase 6) | platform.md §5.1 | progression.md §8 |
| DEBUG_COMMAND with platform | Each command's `min_role`; 40–43 and 5, 13 and 16 declare `admin` | progression.md §10 | platform.md §9.1 |
| Environment guard | The registry's `env` rules: with `staging` or `production`, development options make the zone exit | platform.md §5.5 | progression.md §10 |
| On own characters | Every command that changes something (`op_revert` included) requires `admin`, with no exception per environment; S2 repeats it in the GM and REVERSAL operations | progression.md §10 | platform.md §9.1 |
| GM queries | `inv_show`, `ledger_show` and `op_show` require `gm` and are audited | progression.md §10 | platform.md §9.1 |
| Audit | A command that creates an operation (a GM one, or the REVERSAL of `op_revert`) goes with `key = "op:<op_id>"` in the batch and in S8, with `on conflict do nothing` and the same fields: `actor_account_id`, `source` (`zone` or `console`), `args` with the target by id and `at` = `detail.at_unix`; `world_id` and `zone_id`, from the instance. Each batch entry is validated separately and against the instance that sends it: no other instance, no `cli` or `platform` rows, no `op_id` from other blocks (platform.md §6). No `audit_log` row carries emails or names in `args` | platform.md §9.1 | progression.md §10, §13.3 |
| Invisible GM | No merits, no XP, no gold, no capture reward | platform.md §9.1 | progression.md §6.2 |
| Fenced zone | Commands that change something are rejected without creating the operation; critical gameplay events are marked and go out later | platform.md §5.3 | progression.md §10 |
| Fake players | Options and guard, platform.md; with platform and fakes, no persistent reward | progression.md §6.2 | platform.md §5.5 |
| Fort and GM commands | With platform, whatever a fort command causes (`fort_owner`, `fort_reset`, `fort_kill_captain`, a capture with `fort_capture_speed`) pays nothing persistent nor adds to `ScoreKeeper`; `/gm teleport`, `/gm visible` and DEBUG_COMMAND 1, 2 and 4 mark the character (`gm_forced`) until its respawn: no captures, no merits, no NPCs | progression.md §6.2 | platform.md §8, §9.1 |
| Zone events | `take_events()` is distributed by `kind`, with one consumer each: `claim` (`auth_provider`), `save` (`saver`), `heartbeat` (the zone), `id_block`, `progress_op` and `progress_ledger` (`progress`), `fortress`, `ignore`, `report`, `sanction` and `instance_closed` (`ServerMain`); then `take_completed` and `prepare` | platform.md §14.3 | progression.md §14.2 |
| Zone requests | `ZonePlatform.request` sets `zone_instance_id` (the save carries it in the `CharacterSaver` envelope, and `save(character_id, lease_id, body, release_lease, context)` sends the bytes without touching them); `enqueue_batch`, the missing `key`; no body carries `world_id` (the platform sets it from the instance); `body` read with `JSON.new().parse` (never `parse_string`) | platform.md §14.3 | progression.md §13.2 |
| Captures | A list from `FortressController` (captor, present, alive, connected, no invisible or `gm_forced`-marked ones) for `ScoreKeeper.captures` and `ProgressService.on_capture`; a forced capture goes to neither | platform.md §8 | progression.md §6.2 |
| u32 fingerprint | `HandoffTicket.zone_key_of` for the ticket's `zone_key` and the NPC and fort `ref_id`s | platform.md §5.1 | progression.md §5.2 |
| Clock and size | `ZonePlatform.now_unix()` for the timers; body of 1 MB at most in the internal API | platform.md §6 | progression.md §8, §17 |
| Packages | The progress store is progression.md P7, with the dependencies of its §14.1; the `ProgressStore` interface, `CreateValidator` and their errors, platform.md P2; both documents wait for abilities.md; progression.md P5c, for platform.md P6 (capture list); one joint order for `zone_server.gd` | platform.md §14.1 | progression.md §14.1 |
| Tests | The store's, in progression.md P7; DEBUG_COMMAND 40–43, the own-characters rule and the fence with `item_give`, in progression.md P5d (platform.md P7b tests `min_role` with network and moderation commands); the end-to-end ones, with the platform.md P10 harness | progression.md §15 | platform.md §15 |
| Client | UI-23, UI-24 and the bot use `CharacterAppearance` and `AppearanceApplier` | platform.md §13.2, §13.3 | progression.md §7.2, §7.4 |

### 13.2 The Go store (P7, this document)

```go
// platform/internal/persistence/progress.go: the interface and its errors are defined by platform.md P2 with a fake;
// it is implemented by internal/progress (P7), which imports persistence (never the reverse). Everything runs inside the
// caller's transaction or connection.
type InvalidSaveError struct{ Check, Detail string }  // S1–S7 → 400 invalid_save with fields.check and fields.detail
func (e *InvalidSaveError) Error() string             // always returned as a pointer (errors.As with *InvalidSaveError)
var ErrNotFound = errors.New("not_found")             // Op and Ledger → 404
type CreateParams struct { RaceID string; Appearance [8]byte; StarterTemplateID string }
type SaveKey struct { WorldID int16; CharacterID int64; InstanceID [16]byte; ZoneID string }  // InstanceID: claimed_by
type Summary struct { RaceID string; Appearance [8]byte; Level int; LastZoneID string; LastChannel int
	PlayedSeconds int64 }
type Querier interface { // satisfied by pgx.Tx and *pgxpool.Pool
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}
type ProgressStore interface {
	Create(ctx context.Context, tx pgx.Tx, worldID int16, characterID int64, p CreateParams) error
	Load(ctx context.Context, q Querier, characterID int64) (json.RawMessage, error)     // §3.4, the claim's
	Apply(ctx context.Context, tx pgx.Tx, key SaveKey, progress json.RawMessage) (saveVersion int64, err error)  // S1–S8
	Summaries(ctx context.Context, q Querier, characterIDs []int64) (map[int64]Summary, error)  // list, enter, name
	Purge(ctx context.Context, tx pgx.Tx, characterID int64) error                      // §3.5
	PurgeRetention(ctx context.Context, tx pgx.Tx) (deleted int64, emptied []int64, err error)  // §3.5; emptied: tombstones without a ledger
	Export(ctx context.Context, q Querier, characterID int64) (json.RawMessage, error)   // §3.5
	Op(ctx context.Context, q Querier, opID int64, instance [16]byte) (json.RawMessage, error)  // operation route;
		// ErrNotFound if it does not exist or if no participant has character_leases.zone_instance_id = instance
		// (a join in the same query: the platform does not read op_participants)
	Ledger(ctx context.Context, q Querier, characterID int64, limit int,
		beforeEntryID int64) (json.RawMessage, error)                                    // limit 1–100; most recent first
}

// In the same file, also from platform.md P2 (its §7.5), with the provisional implementation of its §4.4 step 5:
type CreateValidator interface {
	ValidateCreate(realm int16, raceID string, appearance [8]byte, templateID string) error  // nil or *ValidationError
}
type ValidationError struct{ Fields map[string]string }  // → 400 validation with these fields; always as a pointer

// platform/internal/progress
package progress

type Rules struct{ /* from gamedata: progression_rules.json, §13.4 */ }
func LoadRules(raw []byte) (*Rules, error)
// Creation (platform.md §4.4 step 5): race of the realm, 8 valid B for the race and a selectable template.
// Implements persistence.CreateValidator; serve picks it instead of the provisional one.
func (r *Rules) ValidateCreate(realm int16, raceID string, appearance [8]byte, templateID string) error
	// &persistence.ValidationError{Fields: {"race_id": "wrong_realm"}}, {"appearance": "invalid"} or
	// {"starter_template_id": "not_selectable"}

type Store struct{ /* rules and injectable clock */ }
func New(rules *Rules, now func() time.Time) *Store   // implements persistence.ProgressStore; returns
                                                      // *persistence.InvalidSaveError and persistence.ErrNotFound
```

- Files: `store.go`, `checks.go` (S1–S7), `write.go` (S8), `summaries.go`, `retention.go`,
  `export.go` and their tests; migrations `internal/migrate/migrations/0010_progress.up.sql` and
  `.down.sql`, and the seed `internal/migrate/testdata/seed_0010.sql`. The rules, with `//go:embed
  progression_rules.json` in `internal/gamedata`.
- Raw JSON travels at the boundary; inside, strict decoding (`jsonx.Int`, `jsonx.ID`,
  `DisallowUnknownFields`).
- `Load` builds the §3.4 JSON from the tables (`location.saved_at_unix` from `saved_at`); a newly created
  character gives the record with the default values.
- `Summaries` is the only thing the platform reads from progress outside the save: race, appearance, level,
  last zone and channel, and play time, for the character list, `enter` and the name-reservation
  exception (platform.md §4.4 and §4.5).
- **Routes.** They are registered by the internal router of platform.md §6, with its checks (token,
  scope, `live` instance and lease on the instance: the character's in the ledger, which the router checks; that of some participant in the operation, which `Op` checks with the instance it receives; otherwise, 404),
  and they call `Op` and `Ledger`. The zone requests them with
  `ZonePlatform.request`, which sets `zone_instance_id` (platform.md §14.3). The bodies are from here (ids as
  strings):
  - `GET /internal/v1/ops/{op_id}?zone_instance_id=` → `{op: {op_id, kind, actor_account_id, ref_op_id,
    zone_id, note, detail, created_at_unix, participants: ["41", "42"], reversed_by, ledger: [{character_id,
    currency, seq, delta, balance_after, reason, ref_kind, ref_id}], items: [{character_id, uid,
    def_id, count_delta, reason}], instances: [{uid, def_id, count, durability, rarity, bound, seed,
    affixes, retired}]}}`, or 404.
  - `GET /internal/v1/characters/{id}/ledger?zone_instance_id=&limit=20&before_entry_id=` → `{entries:
    [{entry_id, op_id, currency, seq, delta, balance_after, reason, ref_kind, ref_id,
    created_at_unix}]}`; `limit` from 1 to 100 (20 by default), most recent first.
- The cases in `tests/fixtures/progression/` (those of §13.3 and `appearance_cases.json`) are read with
  `os.ReadFile("../../../tests/fixtures/…")` (not with `go:embed`, which does not allow `..`): the Go tests
  run in the package directory. It is the same root as the name cases of platform.md §4.4
  (`tests/fixtures/names/`).

### 13.3 Save checks (S1–S8)

Within step 4 of platform.md §7.3: the lease is already locked and checked and the `seq` is
new (steps 2 and 3, with no S number). Any failure of S1–S7 returns `&persistence.InvalidSaveError{Check,
Detail}` and the whole save is rolled back. A database error in S8 or at COMMIT follows the error rule of
platform.md §7.3 (classes 22 and 23 and `P0001` → `invalid_save` with `check = "S8"`; `40001`, `40P01` and no
connection → 503 and retry).

| # | Check |
|---|---|
| S1 | `progress_format` = 1. Known keys and none read-only (`race_id`, `appearance`, `starter_template_id`, `location.saved_at_unix`). Every id is a decimal string from 1 to 2^53 − 1 (`seed` and `ref_id`, from 0); the other integers, exact numbers. `location.zone_id` = `SaveKey.ZoneID` |
| S2 | **Operations.** Every `op_id` in the body falls in an `id_blocks` block given to `SaveKey.InstanceID` and **is not already in `economy_ops`**: an `op_id` saved before always fails, whatever its participant (I6). If two simultaneous saves bring the same one, both pass this read and the second collides in S8 with the primary key of `economy_ops`, which S8 inserts without `on conflict`: it exits with `check = "S8"` (platform.md §7.3). In phase 5 no operation has two participants; the trading one (phase 6) can only enter whole inside a single `SaveMany` (platform.md §7.3), with the same `kind`, `actor_account_id`, `note` and `detail` in both bodies, and that exception (with the `on conflict do nothing` that S8 will then need) is written with it. `kind` 1–5 in phase 5 (MIGRATION, 6, is only created by SQL migrations) and, per kind, only its reasons in entries and events: PLAYER 64; GAMEPLAY 2–6 and 65; STARTER_KIT 1; GM 7 and 66; REVERSAL 128. GM and REVERSAL, with a non-empty `note`; `detail.at_unix` an integer, not later than now + 60 s nor earlier by more than 60 s than the `granted_at` of the `id_blocks` block that contains its `op_id` (an operation is not older than its id); and `actor_account_id` with role `gm` or `admin` **at `detail.at_unix`** and `detail.actor_character_id` a character of that account, or `detail.source = "console"` with no actor or `actor_character_id`; on a character of the actor's account, only `admin`. The role at `detail.at_unix` is the `args.from` of the first CLI `set-role` row after that time (the fixed row of platform.md §9.1: `where source = 'cli' and command = 'set-role' and target_account_id = $actor and at > to_timestamp($at_unix) order by at, id limit 1`) or, if there is none, that of `accounts`: demoting a GM does not invalidate the still in-flight saves of the operations they created earlier. Only `cli` rows count: a zone cannot write them (platform.md §6, "Batches"). STARTER_KIT only if `starter_granted` was false in the DB. REVERSAL: `ref_op_id` exists, belongs to this character, is not REVERSAL or MIGRATION, is not in `op_reversals` and is not the `ref_op_id` of another REVERSAL in the same body |
| S3 | **Ledger.** Per currency and in order: `balance_after = previous + delta`, between 0 and the cap, with the sign of its reason's range; the last one is the snapshot's balance; a currency without entries does not change balance |
| S4 | **Items (I4).** Per definition: Σ live `count` in the DB + Σ `count_delta` of the events = Σ `count` of the snapshot. An event with `uid` and `count_delta > 0` is for a uid that was not in the DB; with `count_delta < 0`, for a live uid of this character in the DB |
| S5 | **Snapshot.** Non-repeating uids; container 0–1; unique slots, bag < `bag_slots`, equipment 0–1; definition in the rules; `count` 1 … `max_stack`; durability per `has_durability`; rarity 0 and no affixes in phase 5; in equipment, one WEAPON per slot and the active one holding a weapon (I10); a uid that was already live in the DB for this character keeps `def_id`, `seed`, `rarity` and `affixes` and its `bound` does not go to false (I1, I12): S4 counts per definition and would not see two uids swapping type. A new uid falls in an `id_blocks` block given to `SaveKey.InstanceID`; if it already exists in `item_instances` (live or retired, of any character) it collides with the primary key on insert (I1): it is a database error from S8 and exits with `check = "S8"` (platform.md §7.3) |
| S6 | **Progress.** `level = level_for(xp_total)` with the rules' curve; `xp_total` does not go down without a GM or REVERSAL in the save; new `realm_points` = old + Σ merit entries of reason 3–5 + Σ merit entries of the REVERSALs of operations with merits of reason 3–5; `bag_slots` does not change; `starter_granted` does not go back to false; `active_weapon_slot` 0–1; `played_seconds` does not go down; `health` null or between 0 and the maximum health from the rules (`combat`) |
| S7 | **Timers.** Keys `^[a-z0-9_:]{1,48}$`, 16 at most, `ends_at_unix ≤ now + 7 days`. **Past dates are valid**: a retried body can arrive minutes after being built (platform.md §6) and an expired timer is not an error (`on_arrival` discards expired ones) |
| S8 | **Writes.** The whole `character_progress`, with `saved_at = now()` and `save_version + 1`, which `Apply` returns; balances with their `last_seq`; items: inserts the new ones, updates those that change and retires those that are missing (`retired_at`, no container or slot); operations with `zone_id = SaveKey.ZoneID`, without `on conflict` (a repeated `op_id` is a 23505 of `economy_ops_pkey` and exits with `check = "S8"`, S2), participants, entries with their `seq`, events and `op_reversals`; one `audit_log` row per GM or REVERSAL operation (`event_key = "op:<op_id>"`, `on conflict (event_key) do nothing`) with `world_id` and `zone_id` of the instance (`SaveKey`), `at = to_timestamp(detail.at_unix)` and `source`, `command`, `actor_account_id`, `actor_character_id`, `target_character_id`, `target_account_id` and `args` taken from the operation (`args` is the `detail` object without `command`, `source`, `actor_character_id` or `at_unix`: `{"args": [...]}` and, if present, the level and XP fields; §19.17): the same fields and values as the batch entry (platform.md §9.1); timers (replaces the set). It does not touch `characters` |

S3 to S6 repeat in Go what `InventoryOps`, `CurrencyRules` and `PlayerProgress` already guarantee in
GDScript: they are the safety net against a zone bug, not the game rule. So that the two
implementations do not diverge, `tools/progression/write_fixtures.gd` generates with `PlayerProgress` the
cases in `tests/fixtures/progression/` (sequences of saves with their expected result, valid and
invalid, one per check; among them, two uids swapping `def_id` with balanced totals, which
fails S5). The cases are committed to the repo; `test_progression_fixtures.gd`
regenerates them in memory and fails if they differ, and the Go tests read them.

### 13.4 Exported rules

One file, `platform/internal/gamedata/progression_rules.json`, with sorted keys, generated by
`ProgressionRulesExport.build()` (`scripts/shared/progression/`, P3) and written by
`tools/progression/export_rules.gd`. A single test, `tests/test_progression_rules_export.gd`: `build()`
gives the same output twice and matches the repo file. There is no other generator, test or
`appearance_limits.json`.

| Section | Content | Defined by |
|---|---|---|
| `protocol_version` | `NetProtocol.PROTOCOL_VERSION` (the default `ELDMARK_MIN_PROTOCOL` in `dev` and `test`) | platform.md §2.3 |
| `names` | `NameRules`: lengths, letters, folding and reserved names | platform.md §4.4 |
| `races` | Ids, realm (the `NetProtocol.Realm` code, 1–3: `build()` translates `RaceDefinition.realm` with `RealmCatalog.code_of`), allowed lists per category, `allows_no_hair` and `allows_no_beard` (§7.1, §7.2) | This document |
| `appearance` | Per piece category (`heads`, `hairs`, `beards`, `marks`), the list of pieces with their compatible `bodies` (empty = all); for `bodies` and the color ones, the sizes (§7.2). With this Go applies the whole rule of `CharacterAppearance.validate` | This document |
| `starter_templates` | The `EquipmentTemplate`s with `selectable = true` (today `marksman` and `squire`) and their weapons (§2.5) | This document |
| `items` | Per definition: id, category, slot, stack, durability and `required_level` (§2) | This document |
| `level_curve` | The table of §6.1 | This document |
| `currencies` | Codes and caps (§5.1) | This document |
| `reasons` | Reason ranges and operation kinds (§5.3) | This document |
| `containers` | Containers and slots (§4.1) | This document |
| `combat` | Maximum health (`CombatRules`, for S6) | This document |

Whoever arrives first (platform.md P2 or P3 here) creates `build()`, the tool, the test and the file;
the other adds its sections. In Go, `internal/gamedata` embeds it with `//go:embed` (which does not read outside
`platform/`); `internal/names` reads `names` and `progress.LoadRules` the rest.

## 14. Packages and contracts

### 14.1 Packages

Everything starts with abilities.md merged (H1a to H3c for P2 and P5b, H4 for P6). The server
packages also wait for the platform.md ones named.

| Package | Content | Depends on |
|---|---|---|
| **P1 · items** | `ItemDefinition`, `ItemInstance` (encode/decode, `to_dictionary`/`from_dictionary`), `ItemDatabase`, `data/items/` (§2.4), `tests/fixtures/items/`; `test_item_database`, `test_item_instance` | `CombatCatalog` |
| **P2 · pure inventory** | `InventoryState`, `InventoryOps` (with `Context.active_weapon_slot`, §4.1), `ItemEvent`, `EconomyReason`, `Currency`, `CurrencyRules`, `StarterKit`, `ActionMachine.set_weapons`; `test_inventory_ops`, `test_inventory_properties`, `test_currency_rules`, `test_action_machine_weapons` | P1; H1b |
| **P3 · progress and appearance** | `LevelCurve` and its `.tres`, `ProgressionRules`, `CharacterAppearance`, `AppearanceCatalog`, `AppearancePart`, `AppearanceColor`, `RaceDefinition`, `data/characters/`, `ProgressionRulesExport` and `tools/progression/export_rules.gd` (§13.4, if platform.md P2 has not created them), `tests/fixtures/progression/appearance_cases.json` (§7.2); `test_level_curve`, `test_character_appearance`, `test_progression_rules_export` | — |
| **P4 · protocol** | `ProgressMessages` (0x50–0x55), LEVEL_UP, ids 40–43, `NetEntity.level`, `appearance` and `encode_spawn(…, receiver_realm)` with its three calls in `ZoneServer`, the part of version 7 belonging here (§12; bumped by platform.md P4), `sim_hash`; reception in `NetClient` (signals) and in `SwarmBot` (discard); in networking.md, the rows and the "v7" mark for this part (§12); `test_progress_messages` | P1, P3; H2 |
| **P5a · record and section** | `scripts/server/progress/`: `ProgressRecord` (with `to_claim_dictionary`), `LedgerEntry`, `EconomyOp`, `IdAllocator`, `PlayerProgress` (inventory, currencies, aggregation, journal with `save_seq`, `build_section`, `acknowledge`, `is_dirty`), `ProgressService.setup`, `start`, `prepare`, `cancel_prepared`, `on_departure` (discard the state) and `on_platform_event`; the section in `CharacterSaver` (`build`, `acknowledge`, `is_dirty`); the hook before WELCOME and the departure in `LOADING`; the `progress` part of `FakeZonePlatform` (the next claim from the last applied data, platform.md §14.1, and `claim_progress`; the rest of its test API is from platform.md P4, its §14.3); `tools/progression/write_fixtures.gd` and the cases; `test_progress_record` (with `ProgressRecord.FORMAT == ZonePlatform.RECORD_FORMAT`), `test_player_progress`, `test_progress_section`, `test_progression_fixtures` | P2, P3; platform.md P4 and P5 |
| **P5b · inventory in the zone** | Registration (`on_arrival` with the return-to-world rule of §8, `after_spawn`, `loadout_for`, where H3c puts the template), `handle_packet` in `_on_packet_received` (0x50–0x53, with RATE), `apply_pending` after `_process_arrivals` (the `CombatState` active slot in `Context`, the DESTROY cap), `set_weapons` and LOADOUT, respawn with an empty WEAPON_1 (§8), CONSUME (`after_simulate`, after step 1), CAMP_REFILL (`camp_step`, in step 8 instead of the refill), charges, `UnstuckTracker.get_ready_at`/`set_ready_at` and its key, the call to `on_departure` on exit (after `CharacterSaver.finish`) and on departure without save, hooks with no effect on a `net_id` without `PlayerProgress` (§9.2), ephemerals, `NetEntity.level`; `test_progress_service`. `test_bot_swarm` and `test_net_processes` keep 0 malformed | P5a, P4; H3c |
| **P5c · rewards** | `on_merits` (PRG-09), `on_npc_killed` (`xp_reward` and `gold_reward` in `NpcDefinition` and `data/npcs/`), `on_capture` (GUE-12) with its timer, XP, LEVEL_UP, PROGRESS_UPDATE, criticals, the rule for `--fake-players`, for forced fort changes and the `gm_forced` mark (§6.2); `test_progress_rewards` | P5b; platform.md P6 (capture list and forced-change mark); PRG-09, MUN-07, GUE-12 |
| **P5d · GM** | Commands of §10 with `min_role`, ids 40–43, DEBUG_COMMAND rules in `_handle_debug_command` (with `admin` on 40–43, 5, 13 and 16; with platform, 16 as a GM operation and 5 and 13 only in the audit, §4.4 and §10), `detail.at_unix`, own-characters rule, trace with the target by id, fenced zone, reversal (a single REVERSAL), `op_show` and `ledger_show` through the routes; `test_gm_progress`, with the tests for id 40 and own `item_give` (the `progress_op` and `progress_ledger` replies, with `FakeZonePlatform.script_next`, platform.md §14.3) | P5b; platform.md P7b (`min_role`); TEC-19 |
| **P6 · client** | `ClientInventory`, `InventoryWindow`, `CharacterWindow`, `InventorySlotView`, `SplitDialog`, `AppearanceApplier`, `HumanoidVisual.set_part`/`clear_part`, template selector hidden with a ticket (§2.5); `test_client_inventory`, `test_inventory_window`, `test_appearance_visual` | P2, P3, P4, UI-09; H4 |
| **P7 · Go store** | `platform/internal/progress/` (§13.2), `0010_progress` with its `.down.sql` and `seed_0010.sql`, S1–S8, `Summaries`, `ValidateCreate`, purge, retention, export, `Op` and `Ledger`; Go tests from §15 | platform.md P0 (`testdb`, `migrate`), P2 (`ProgressStore` interface) and P3 (routes); P3 here (exported rules); the P5a cases |
| **P8 · integration** | `test_progress_loopback`, `test_progress_platform_loopback`, the bot's `--bot-scenario=progress`, `platform/e2e/progress_test.go` (§15) | P5a–P5d, P6, P7; platform.md P8 and P10 |

P1 and P3 run in parallel; then P2 and P4; then P5a and P6 in parallel; then P5b; then P5c and P5d in
series. P7 starts as soon as platform.md P0, P2 and P3, P3 here and the P5a cases are available (which arrives after
platform.md P4 and P5); platform.md P9a and P10 wait for P7. P8 at the end. The protocol is bumped by platform.md
P4, which goes before P4 here; this one adds its part without bumping it (§12).
`zone_server.gd` is touched by both documents in the order of platform.md §14.1 (abilities.md H3c → platform.md
P4 → P4 → platform.md P5 → P5a → P5b → platform.md P6 → P5c → platform.md P7b → P5d).

### 14.2 GDScript contracts

Public and stable signatures; private details are left to whoever implements. The data fields are
those of §2.1, §3.4 and §7.2 with static types.

```gdscript
# scripts/shared/progression/ (shared: no Time, OS or Input)
class_name ItemDefinition extends Resource          # enums Category, EquipSlot, BindRule from §2.1

class_name ItemInstance extends RefCounted
const FORMAT: int = 1; const MAX_AFFIXES: int = 6; const NO_DURABILITY: int = -1
const MAX_UID: int = (1 << 53) - 1
var uid: int; var def_id: StringName; var count: int; var durability: int; var rarity: int
var bound: bool; var seed: int; var affixes: PackedInt32Array
func encode(db: ItemDatabase = null) -> PackedByteArray                  # null = shared()
static func decode(bytes: PackedByteArray, offset: int, db: ItemDatabase = null) -> ItemInstance
static func encoded_size_at(bytes: PackedByteArray, offset: int) -> int   # −1 if it does not fit
func to_dictionary(container: int, slot: int) -> Dictionary              # one entry of §3.4; ids with str()
static func from_dictionary(data: Dictionary, db: ItemDatabase) -> ItemInstance  # null if it does not match; ids: string with
		# is_valid_int() and to_int(); integers with int() (accepts 820.0)
func duplicate_instance() -> ItemInstance; func equals(other: ItemInstance) -> bool

class_name ItemDatabase extends RefCounted
const DATA_DIR: String = "res://data/items"
var errors: PackedStringArray
static func shared() -> ItemDatabase; static func build_from_directory(dir: String) -> ItemDatabase
func get_definition(id: StringName) -> ItemDefinition                    # null if it does not exist
func net_id_of(id: StringName) -> int; func definition_by_net_id(net_id: int) -> ItemDefinition
func for_ref(category: int, ref_id: StringName) -> ItemDefinition
func consumable_definition(index: int) -> ItemDefinition                 # CombatCatalog.consumable_ids()
func all_ids() -> Array[StringName]; func wire_hash() -> int

class_name InventoryState extends RefCounted
enum ContainerId { BAG = 0, EQUIPMENT = 1, BANK = 2 }   # not "Container": it is a native Godot class (§19.7)
enum EquipmentSlot { WEAPON_1 = 0, WEAPON_2 = 1, HEAD = 2, CHEST = 3, HANDS = 4, LEGS = 5, FEET = 6 }
const BAG_SLOTS_DEFAULT: int = 30; const BAG_SLOTS_MAX: int = 120; const EQUIPMENT_SLOTS: int = 7
const OPEN_EQUIPMENT_SLOTS: int = 2                                      # phase 5: weapons only
var bag_slots: int                                                       # no active slot: it is bit0 of combat_flags2 (§4.1)
func get_item(container: int, slot: int) -> ItemInstance                 # null if empty
func set_item(container: int, slot: int, item: ItemInstance) -> void     # null empties it
func first_free(container: int) -> int; func find_uid(uid: int) -> Vector2i   # −1 / (−1, −1)
func count_of(def_id: StringName) -> int                                 # bag and equipment
func all_items() -> Array[ItemInstance]; func duplicate_state() -> InventoryState
# P2 adds: slot_count, has_slot, free_count, occupied_slots, equals and OPEN_CONTAINERS (§19.7)

class_name InventoryOps extends RefCounted
enum Op { MOVE = 1, SPLIT = 2, DESTROY = 3 }
enum Result { OK = 0, INVALID = 1, STALE = 2, NOT_NOW = 3, CANNOT_EQUIP = 4,
		WEAPON_REQUIRED = 5, NO_ROOM = 6, LOCKED = 7, RATE = 8 }
class Request:
	var op: int; var from_container: int; var from_slot: int; var to_container: int
	var to_slot: int; var count: int; var expected_uid: int
class Context:
	var db: ItemDatabase; var level: int = 1
	var active_weapon_slot: int = 0               # bit0 of combat_flags2: from the CombatState (server) or the predicted one (client)
	var can_touch_equipment: bool = true          # false: dead, knocked down, in combat or with an action
	var drinking: bool = false                    # consumable ABILITY in progress
	var new_uid: Callable = Callable()            # () -> int; 0 = no ids for clients
class Outcome:
	var result: int; var changed: Array[Vector2i]; var events: Array[ItemEvent]
	var weapons_changed: bool                     # touched EQUIPMENT 0 or 1
	var new_id: int                               # P2: the id from new_uid (SPLIT: the new stack; DESTROY: its PLAYER op)
	var required_level: int; var bag_full: bool   # P2: "Necesitas nivel N" (you need level N); camp_refill with no room
static func apply(state: InventoryState, request: Request, context: Context) -> Outcome
static func result_text(result: int, required_level: int = 0, in_combat: bool = false) -> String  # Spanish (§4.2)
# P2 adds the server-side changes of §4.4 (§19.7): camp_refill(state, context), add_items(state, def_id,
# count, reason, context) and remove_items(state, def_id, count, reason, prefer_uid = 0) -> Outcome

class_name ItemEvent extends RefCounted
var uid: int                                      # 0 = aggregated (null in JSON)
var def_id: StringName; var count_delta: int; var reason: int
class_name EconomyReason extends RefCounted    # constants from §5.3; is_source, is_sink, is_internal
class_name Currency extends RefCounted         # enum Code { GOLD = 1, MERITS = 2 }; const CAP: int = 1_000_000_000
                                               # (in GDScript, ^ is XOR: 10^9 would be 3)
class_name CurrencyRules extends RefCounted
static func can_apply(balance: int, delta: int) -> bool
static func clamp_gain(balance: int, gain: int) -> int

class_name StarterKit extends RefCounted
## Places the kit of §2.5 in an empty inventory; returns the events (reason STARTER_KIT, with uid).
static func grant(state: InventoryState, template_id: StringName, db: ItemDatabase,
		new_uid: Callable) -> Array[ItemEvent]

class_name LevelCurve extends Resource
@export var level_cap: int = 40
@export var xp_to_next: PackedInt32Array
@export var attribute_points_per_level: int = 1
func total_to(level: int) -> int; func level_for(xp_total: int) -> int
class_name ProgressionRules extends RefCounted
const XP_PER_MERIT: int = 10
class XpResult:
	var level: int; var xp_total: int; var levels_gained: int; var applied: int
static func add_xp(curve: LevelCurve, level: int, xp_total: int, amount: int) -> XpResult
static func attribute_points(curve: LevelCurve, level: int, spent: int) -> int

class_name CharacterAppearance extends RefCounted   # fields from §7.2
const ENCODED_SIZE: int = 8
func encode() -> PackedByteArray
static func decode(bytes: PackedByteArray) -> CharacterAppearance       # null if it is not 8 B
func validate(catalog: AppearanceCatalog, realm: int, race_id: StringName) -> bool   # §7.2; realm: NetProtocol.Realm code
static func random(catalog: AppearanceCatalog, race_index: int,
		rng: RandomNumberGenerator) -> CharacterAppearance
static func default_for(catalog: AppearanceCatalog, race_index: int) -> CharacterAppearance

class_name ProgressionRulesExport extends RefCounted
static func build() -> Dictionary     # §13.4; sorted keys: the JSON comes out the same on every call

# scripts/shared/combat/action_machine.gd (extends): set_weapons from §4.1

# scripts/server/net_entity.gd (extends)
var level: int = 0; var appearance: PackedByteArray
func encode_spawn(tick: int, for_owner: bool, receiver_realm: int = 0) -> PackedByteArray

# scripts/server/unstuck_tracker.gd (extends)
func get_ready_at(player: String) -> int; func set_ready_at(player: String, tick: int) -> void

# scripts/server/progress/ (server; no Time: the UTC time is ZonePlatform.now_unix())
class_name ProgressRecord extends RefCounted     # the progress section of §3.4
const FORMAT: int = 1                                             # progress_format; equal to ZonePlatform.RECORD_FORMAT (test)
var race_id: StringName; var appearance: PackedByteArray          # 8 B
var level: int = 1; var xp_total: int; var realm_points: int; var played_seconds: int; var bag_slots: int = 30
var starter_template_id: StringName; var starter_granted: bool; var active_weapon_slot: int   # the record's (§8)
var health: int = -1                                              # −1 = full (null in JSON)
var location: Dictionary                                          # empty = null; §3.4
var inventory: InventoryState; var wallets: PackedInt64Array      # index = currency; [0] unused
var timers: Dictionary[String, int]                               # key → ends_at_unix
static func new_character() -> ProgressRecord                     # ephemerals (§9.4)
static func from_dictionary(data: Dictionary, db: ItemDatabase) -> ProgressRecord   # null if it does not match (§3.4)
func to_dictionary() -> Dictionary                                # the save's: without the read-only ones or ops
func to_claim_dictionary(saved_at_unix: int) -> Dictionary        # the claim's: with the read-only ones (tests)

class_name LedgerEntry extends RefCounted
var currency: int; var delta: int; var balance_after: int; var reason: int; var ref_kind: int
var ref_id: int
class_name EconomyOp extends RefCounted
enum Kind { PLAYER = 1, GAMEPLAY = 2, STARTER_KIT = 3, GM = 4, REVERSAL = 5, MIGRATION = 6 }
var op_id: int; var kind: int; var actor_account_id: int; var ref_op_id: int; var note: String
var detail: Dictionary; var ledger: Array[LedgerEntry]; var items: Array[ItemEvent]
var save_seq: int                                                 # 0 = not yet in any save
func to_dictionary() -> Dictionary; static func from_dictionary(data: Dictionary) -> EconomyOp  # ids as strings

class_name IdAllocator extends RefCounted
const BLOCK_SIZE: int = 1024; const REFILL_BELOW: int = 512; const SERVER_RESERVE: int = 256
var build_reserve: int = 128                                      # 2 × max_players; set by ProgressService.setup
static func local() -> IdAllocator                                # without platform: from 1, no blocks or ranges
func add_block(first: int, count: int) -> void
func needs_block() -> bool                                        # available() < build_reserve + REFILL_BELOW
func available() -> int
func next_for_client() -> int                                     # 0 if ≤ build_reserve + SERVER_RESERVE remain
func next_for_server() -> int                                     # 0 if ≤ build_reserve remain
func next_for_build() -> int                                      # build_section only; 0 if none remains

class_name PlayerProgress extends RefCounted   # authoritative state of one character in the zone
var record: ProgressRecord; var persistent: bool
var character_id: int; var account_id: int                        # 0 if ephemeral
func _init(record: ProgressRecord, persistent: bool, ids: IdAllocator, db: ItemDatabase) -> void
func apply_request(request: InventoryOps.Request, context: InventoryOps.Context) -> InventoryOps.Outcome
func begin_op(kind: int, actor_account_id: int, note: String, detail: Dictionary) -> EconomyOp  # closes the aggregates; null without an id
func add_items(op: EconomyOp, def_id: StringName, count: int, reason: int) -> bool              # false: does not fit and nothing changes
func remove_items(op: EconomyOp, def_id: StringName, count: int, reason: int,
		prefer_uid: int = 0) -> bool
func change_currency(op: EconomyOp, currency: int, delta: int, reason: int, ref_kind: int,
		ref_id: int) -> bool
func gain_currency(currency: int, amount: int, reason: int, ref_kind: int, ref_id: int) -> int  # aggregated; what was applied after the cap
func gain_items(def_id: StringName, count: int, reason: int) -> bool                            # aggregated (CAMP_REFILL)
func lose_items(def_id: StringName, count: int, reason: int) -> bool                             # aggregated (CONSUME)
func add_xp(amount: int, source: int) -> ProgressionRules.XpResult
func charges() -> int                                             # consumable_charges byte (§4.4)
func weapons() -> PackedInt32Array                                # CombatCatalog ids; 0 = empty
func stash_ready(weapon_id: int, ready: PackedInt64Array) -> void
func stashed_ready(weapon_id: int) -> PackedInt64Array
func build_section(seq: int) -> Dictionary                        # §9.3; only the operations with save_seq 0, which it marks;
		# {} without touching anything if there is no id to close the aggregates (§4.5)
func acknowledge(seq: int) -> void                                # removes those with save_seq ≤ seq
func is_dirty() -> bool                                           # journal, record, position or health (§9.2)
func journal() -> Array[EconomyOp]                                # without platform: the last 256
# P5a adds (§19.11): PlayerProgress.Live with live_source, arrival_tick, played_base, revision, pending_xp_gain and
# pending_xp_source, get_ids, confirm_current, discard_op, grant_starter_kit, camp_refill, pending_aggregate_count,
# unconfirmed_count, ends_at_unix_for and ready_tick_for; LedgerEntry.RefKind, create, to_dictionary, from_dictionary and
# equals; EconomyOp.create, KIND_REASONS, is_empty, is_consistent, equals and kind_name; IdAllocator.running_low,
# is_local and taken_count; ProgressRecord.equals and duplicate_record

class_name ProgressService extends RefCounted
class Loadout:
	var weapon_1: int; var weapon_2: int; var second_active: bool; var charges: int
func setup(zone: ZoneServer, platform: ZonePlatform, saver: CharacterSaver,
		commands: CommandRegistry) -> void                             # platform and saver null without platform
func start(s: int) -> void
func prepare(peer_id: int, claimed: ClaimedCharacter) -> bool       # §9.1 step 2; the order, platform.md §5.2
func cancel_prepared(peer_id: int) -> void   # departure in LOADING: discards what prepare did (§9.1 step 3); with nothing, nothing
func on_arrival(entity: NetEntity, peer: ServerPeer, s: int) -> Loadout   # kit, return to world (§8), timers
func after_spawn(entity: NetEntity, peer: ServerPeer, s: int) -> void
func loadout_for(net_id: int) -> Loadout                            # also on respawn (empty WEAPON_1: second_active)
func has_inventory(net_id: int) -> bool; func level_of(net_id: int) -> int
func handle_packet(peer: ServerPeer, bytes: PackedByteArray) -> void   # 0x50 and 0x53
func after_simulate(s: int) -> void                                 # CONSUME
func camp_step(entity: NetEntity, s: int) -> void                   # CAMP_REFILL
func apply_pending(s: int) -> void                                  # requests, after the registrations
func on_merits(net_id: int, amount: int, reason: int, victim_net_id: int, s: int) -> void
func on_npc_killed(npc: NpcDefinition, contributors: PackedInt32Array, s: int) -> void
func on_capture(fortress_id: StringName, owner_realm: int, in_circle: PackedInt32Array, s: int) -> void
		# in_circle: the platform.md §8 list, the same one that ScoreKeeper.captures adds
func on_platform_event(event: PlatformEvent) -> bool                # kind id_block, progress_op and progress_ledger
func on_departure(net_id: int) -> void        # after CharacterSaver.finish and ScoreKeeper.forget, or on departure without save
		# (platform.md §7.2). Every per-net_id hook, on one without PlayerProgress, does nothing (§9.2)
func flush(s: int) -> void                                          # WALLET_UPDATE and PROGRESS_UPDATE
# P5a adds (§19.11): SECTION, PREPARE_FAILED_TEXT, get_player, get_prepared, get_ids and get_stats; and in ZoneServer,
# get_progress and get_config
# P5b adds (§19.12): before_simulate (the charges before step 1, for after_simulate), force_refill (16 without
# platform), set_timer (unstuck; capture:<id> from P5c), character_id_of, pending_count, send_sink, strike_sink and
# notice_sink, BAG_FULL_TEXT, TIMER_UNSTUCK, the RATE paces and the warning texts; in PlayerProgress,
# take_items (lose_items with its Outcome), saved_active_slot and last_currency_reasons; in CombatDirector,
# equip_inventory, loadout_source and camp_step; and in ZoneServer, unstuck_key_of and place_returning
# P5c adds (§19.14): on_objective_ticks (the objective merits), rewards_blocked, level_up_sink,
# TIMER_CAPTURE_PREFIX, CRITICAL_LEVEL_UP, CRITICAL_CAPTURE, CAPTURE_XP, CAPTURE_GOLD, CAPTURE_COOLDOWN_S,
# OBJECTIVE_TICKS_PER_MERIT and FAKE_PLAYERS_TEXT; in DamageLedger, contributors; in FortressController, the signal
# objective_time and fortress_of_defender; in NpcDefinition, xp_reward and gold_reward
# P5d adds (§19.16): the ProgressCommands class (scripts/server/progress/progress_commands.gd: the commands of §10,
# net_refill and console_refill for 16, on_platform_event for progress_op and progress_ledger); in ProgressService,
# gm_commands, now_unix, reply_sink, clock_unix and what the commands use (find_connected, connected_net_id_of,
# is_connected_player, peer_of, player_net_ids, active_weapon_slot, can_change_weapons, is_alive, after_gm_change,
# after_level_change, mark_gm_critical, reply, log_line and notice); in PlayerProgress, abort_op, op_add_items,
# op_create_items and op_remove_items (with protected); in InventoryOps, create_items, count_outside and protected in
# remove_items; in CommandRegistry (platform.md P7b), network_min_role and Context.audit_at_unix and audit_deferred

# scripts/shared/net/progress_messages.gd (P4, §19.9): the formats of §4.6 and §12; the types, in NetProtocol.MSG_*
class_name ProgressMessages extends RefCounted
const MAX_LEVEL: int = 40; const MAX_ENTRIES: int = 30; const MAX_PAGES: int = 8; const NO_SLOT: int = 0xFF
enum XpSource { STATE = 0, PVP = 1, NPC = 2, CAPTURE = 3, GM = 4 }
class Entry: var container: int; var slot: int; var item: ItemInstance   # null = empty (only in a delta)
# InventoryRequest (from_request, to_request), InventoryDelta (for_slots), InventoryFull (split, assemble),
# InventorySyncRequest, WalletUpdate (make), ProgressUpdate (make): each with
#     func encode(db: ItemDatabase = null) -> PackedByteArray         # empty if decode would not accept it
#     static func decode(bytes: PackedByteArray, db: ItemDatabase = null) -> <Class>   # null if malformed
# (db only on those that carry items; null = ItemDatabase.shared())

# scripts/client/inventory/ (client)
class_name ClientInventory extends RefCounted
signal view_changed; signal confirmed_changed; signal request_rejected(result: int, text: String)
const MAX_PENDING: int = 8
func request(op: InventoryOps.Request) -> int                 # local Result; OK = sent
func on_delta(delta: ProgressMessages.InventoryDelta) -> void
func on_full_page(page: ProgressMessages.InventoryFull) -> void
func get_view() -> InventoryState; func get_confirmed() -> InventoryState
func tick(now_msec: int) -> void                              # 5 s timeout
# P6 adds (§19.19): has_inventory, validate, notify_rejected, equip_target, make_move/make_split/make_destroy,
# current_context, is_provisional; send_request, send_sync, context_provider, in_combat_provider and db are injected
# (NetClient owns it: get_inventory, inventory_context); ClientProgress (balances, level, XP) is new
class_name AppearanceApplier extends RefCounted
static func apply(visual: HumanoidVisual, appearance: CharacterAppearance,
		catalog: AppearanceCatalog) -> void
# P6 adds resolve(bytes, realm, catalog) and apply_bytes: the appearance that is valid or the realm's default
# humanoid_visual.gd: set_part and clear_part from §7.4; P6 adds set_tint, get_part_meshes and part_slots (§19.19)
```

`test_architecture` is extended:

- `scripts/shared/progression/` does not name `Time`, `OS`, `Input` or anything from `scripts/client/` or
  `scripts/server/`;
- no resource in `data/items/` or `data/characters/` has `Texture2D`, `PackedScene`
  or `Mesh` properties;
- `scripts/server/progress/` does not read `Time`;
- no `class_name` is repeated in `scripts/` or `tests/` (Godot silently registers only one of
  the two).

## 15. Tests

Each takes under 30 s with the current runner (`run_tests.gd`) or with `go test` (warm cache).

| Package | Test | What it checks |
|---|---|---|
| P1 | `test_item_database` | unique, well-formed ids; all `.tres` in text form (they start with `[gd_resource`); consistency of §2.1 (ARMOR with `tests/fixtures/items/`); `ref_id`s that exist; one item per template weapon and consumable; alphabetical net ids; `wire_hash` stable across two loads |
| P1 | `test_item_instance` | Round trip of 1000 seeded random instances, in binary and as a dictionary; null in each case of §2.3 (truncated, format 2, uid 0, uid 2^53, unknown net id, count 0 or > stack, 7 affixes) |
| P2 | `test_inventory_ops` | Table of cases: each op and each code of §4.2, in its order; partial merge; full destination stack → swap; bound on equip; slots 2–6 → CANNOT_EQUIP; DESTROY of a consumable while drinking → NOT_NOW; only DESTROY gives events; with `Context.active_weapon_slot` = 1 (after a SWAP), unequipping WEAPON_2 → WEAPON_REQUIRED and unequipping WEAPON_1, OK |
| P2 | `test_inventory_properties` | 20 seeds × 1000 random operations (valid and invalid), with incremental invariants (quantity per definition and live and dead uids, updated from each `Outcome`'s events) and the full check every 100 operations and at the end: quantity does not change without an event, no uid repeats or comes back, unique slots, the active one holds a weapon; after CAMP_REFILL, `count_of(def) ≤ max(camp_refill, before)`, with a table case for the split stack. Under 5 s measured. The long version (20 × 5000) only with `--filter=inventory_properties_long` |
| P2 | `test_currency_rules` | Caps, negatives, two operations in the same tick on one balance, reconstruction from the entries |
| P2 | `test_action_machine_weapons` | `set_weapons` preserves charges, `consumable_ready_tick` and movement slots; distributes `ability_ready` per weapon; with an action, does nothing |
| P3 | `test_level_curve` | 39 increasing values; `level_for(total_to(n)) = n`; several level-ups from a single contribution; cap |
| P3 | `test_character_appearance` | Round trip of 8 B; the cases of `appearance_cases.json` (the same ones Go reads); `validate` rejects each out-of-range index, the race of another realm, a byte 0 that is not `race_id`'s, a piece of another body and a 0 for hair or beard in a race that does not allow it; 100 valid random ones per race; `appearance_ids.txt` is a prefix of the catalog; the catalog only names scenes that exist; empty `stat_modifiers` |
| P3 | `test_progression_rules_export` | The file's only test (§13.4): `build()` gives the same output twice, contains the sections of §13.4 (the three races, the `selectable` templates, the items, the curve, the caps and the reason ranges) and matches `platform/internal/gamedata/progression_rules.json` |
| P4 | `test_progress_messages` | Round trip of 0x50–0x55, SPAWN with level and appearance and LEVEL_UP; null for each malformation; none exceeds 1200 B; DEBUG 40–43; `encode_spawn` with a receiver of another realm gives `level` 0 |
| P5a | `test_progress_record` | `ProgressRecord.FORMAT == ZonePlatform.RECORD_FORMAT`; round trip of `ProgressRecord` through `to_claim_dictionary`, `JSON.stringify`, `parse_string` and `from_dictionary`, field by field, with and without `location`; ids as strings (an id as a number → null) and integers rewritten as `820.0` accepted; null with a missing or unknown key, a non-integer id or one ≥ 2^53; `to_dictionary` carries no read-only fields |
| P5a | `test_player_progress` | Starter kit (by template and default); aggregation (one entry per currency, reason and reference); the closing before a standalone operation (gain, `currency_add`, save: S3 balances); `build_section` and `acknowledge`; with `n` in flight, `build_section(n + 1)` does not repeat the operations of `n` and `acknowledge(n)` does not remove those of `n + 1`; the three id ranges (with `build_reserve` free, CAMP_REFILL does not open a new stack and `build_section` still closes the aggregates; with none, it returns `{}` and changes nothing); DESTROY with 256 unconfirmed operations → NOT_NOW; no ability or consumable in `CombatCatalog` lasts 30 s or more; `ends_at_unix` comes out as an integer and rounds up (`ceili`) |
| P5a | `test_progress_section` | With `FakeZonePlatform` (platform.md P4): section registered; retry with the same body; `duplicate` confirms; `lease_lost` discards (`on_departure`); 400 `invalid_save` kicks and releases, and afterwards no `ProgressService` hook fails with that `net_id`; `is_dirty` with only moving or losing health; `prepare` with a broken `progress` → REJECT `UNAVAILABLE` and release; leaving in `LOADING` → `cancel_prepared` and release; the fake's next claim brings the last applied data; the final save built with a save in flight is applied after it without `invalid_save` |
| P5a | `test_progression_fixtures` | The cases in `tests/fixtures/progression/` match those generated by `write_fixtures.gd` |
| P5b | `test_progress_service` | Registration with the inventory's `Loadout` and the active slot; equipping and unequipping without resetting cooldowns; CONSUME on commit and not on interruption; CAMP_REFILL by total and at the abilities.md cadence; charges `min(15, bag)`; requests before the world → warning; a client sending 10 000 SPLITs and merges: no events, ids bounded by RATE and another player keeps drinking and saving; `/atascado` restored through its key; a dead character is saved to respawn (health and camp on return); a `squire` who puts the bow in WEAPON_2, switches to it (Q) and unequips WEAPON_1 dies and respawns with the bow active, and its next save passes S5 |
| P5c | `test_progress_rewards` | Merits from a persistent victim of another realm → entry and XP; killing a fake or an NPC gives no merits; NPC with two contributors → both collect; two captures within 30 min pay once; an invisible GM in the circle does not collect the capture; a character taken to the circle with `/gm teleport` or a GM who makes themselves visible in it with `/gm visible` collects no capture, merits or NPC reward until respawning, and afterwards does; a capture forced by a GM in the circle (`fort_owner` or with `fort_capture_speed`) and the captain killed with `fort_kill_captain` pay nobody; `--fake-players` with platform → nothing; level-up → LEVEL_UP only to the same realm and critical |
| P5d | `test_gm_progress` | Gives an item, splits it into 3 and 2, merges the 2 with another stack and reverts it: the total drops by 5 and the GM_GRANT, the REVERSAL and their entries are found; second reversal rejected, also the one that arrives before the first is saved; with a fake platform and role `player`, id 41 does not change the balance and adds a warning; DEBUG_COMMAND 40 without a role → warning, no item and no save; 16 with role `gm` → warning, and with `admin` it creates a GM operation with GM_GRANT and `note` "debug" that the save accepts; 5 and 13 with `admin` create no operation and leave their audit entry; `item_give` and `op_revert` by a `gm` on their own character, rejected (also with `env` `dev`); `detail.args` carries the target's `character_id`, not its name; with the zone fenced, `item_give` replies "El servicio de cuentas no responde…" and does not create the operation; `level_set` leaves `detail` with before and after and `at_unix` |
| P6 | `test_client_inventory`, `test_inventory_window` | Optimistic, confirmation, rejection that returns the item, interleaved server deltas, 5 s timeout; simulated drag, split and destroy generate the correct request |
| P6 | `test_appearance_visual` | All combinations of pieces that exist (body, head, hair and beard, with and without) with a random color each, and 100 random ones, applied to `HumanoidVisual` without engine errors; `set_part` does not recreate the node |
| P7 | Go: `TestCreateLoad` | Create, save, reload and compare field by field (PRG-10); `ValidateCreate` with the cases of `appearance_cases.json`, race of another realm and a template that is not `selectable`, each with its `*persistence.ValidationError` and its `fields` |
| P7 | Go: `TestApply*` | Each fixture case with its result; S1–S8 one by one; `saved_at` and `save_version` written; audit with `op:<op_id>` without duplicating, also for a REVERSAL; S7 accepts an expired timer on a late retry; a `uid` or `op_id` outside the instance's blocks → `*persistence.InvalidSaveError`; a MIGRATION, a reason of another kind, two REVERSALs of the same operation, a REVERSAL by a `gm` on their own account and an `op_id` already saved for another character → S2; a GM operation by an actor demoted to `player` by a `set-role` later than its `detail.at_unix` passes, and one created after the `set-role` does not; a `set-role` row with `source = 'zone'` does not count; a `detail.at_unix` earlier by more than 60 s than the `granted_at` of its block, or an `actor_character_id` of another account → S2; the audit row carries `at = detail.at_unix`; slot swap with the deferred constraint |
| P7 | Go: `TestDuplicateUid` | Two simultaneous saves of two characters with the same new `uid`: one fails with `check = "S8"` and nothing is duplicated. The same with the same `op_id`: one fails with `check = "S8"` and the operation is left with a single participant |
| P7 | Go: `TestWalletConcurrency` | Two simultaneous transactions on one balance (§5.4); balance reconstruction |
| P7 | Go: `TestTwoCharacterOp` | The schema, in SQL: an operation with two participants in one transaction; the same participant twice fails. Through `Apply`, the same operation in another character's save fails S2 (the `SaveMany` exception is for phase 6) |
| P7 | Go: `TestPurgeKeepsLedger`, `TestRetention` | Purge of a character with kit and entries inside the account purge: the `characters` row is left as a tombstone, without items and with the ledger; a `delete` of the ledger without the mark fails; with the clock at +366 days, `PurgeRetention` deletes it, returns the tombstone in `emptied` and leaves other characters' operations |
| P7 | Go: `TestSummaries`, `TestExport` | `Summaries` of several characters (with and without `location`); `Export` with the record and the character's own ledger entries; of a tombstone, without a record; GM and REVERSAL operations without actor, `note` or `detail` |
| P7 | Go: `TestOpLedger` | `Op` (with the retired rows, `reversed_by` and `participants`) and `Ledger` with pagination and `limit` from 1 to 100; `Op` with an instance in which no participant is present → `ErrNotFound`; 404 |
| P8 | `test_progress_loopback` | Two clients through `NetHarness`, without platform: equipping the bow from the bag changes the other's weapon via LOADOUT, the bar and 0 unexplained corrections; a rejection returns the item; a client of another realm receives `level` 0 and one of the same realm, the real one; drinking spends a potion from the bag |
| P8 | `test_progress_platform_loopback` | With `FakeZonePlatform` (platform.md §14.3: `add_character` with `claim_progress(&"race_vardheim", …, &"marksman")` and the ids from `next_block_first`) and test tickets: character created with `marksman` → kit; LOADOUT_SELECT ignored; drinking, refilling, `/atascado`; leaving and returning preserves uids, equipment, active weapon, balances and the 5 min cooldown (minus the elapsed time); returns to camp |
| P8 | Go: `platform/e2e/progress_test.go` | `TestProgressEndToEnd`, with the platform.md P10 harness (with `test_world` as the entry zone of both realms): platform in-process, ephemeral PostgreSQL, `test_world` with `--platform --debug-commands`, an `admin` account and `--bot --bot-scenario=progress --report=<path>` (equips the bow, gives 50 gold and a potion through DEBUG_COMMAND and exits); `Load` from the DB against the bot's report, field by field. `TestProgressCrash`: the same with `kill -9` on the zone after the gold delta; by SQL, Σ `delta` = balance, per definition Σ `count_delta` = Σ live `count`, and the bot re-enters with the same data |

**PostgreSQL on this machine (verified).** Docker is installed but has no daemon: the tests do not
depend on it. The harness is `internal/testdb` from platform.md §2.6: `initdb` does not run as root, so
each command goes with `runuser -u postgres --` on a folder of its own, and the server listens only on a
Unix socket with `fsync`, `synchronous_commit` and `full_page_writes` turned off. Measured with this
document's probe (cluster, §3.3 schema and the cases of §3.3 and §3.5): 0.9 s in total. Go 1.24 downloads
modules through the proxy.

## 16. Pending from the user

| What | What for | Meanwhile |
|---|---|---|
| Female body and more heads, hairstyles, beards and markings (ART-20): buy the Source of Universal Base Characters or import more Standard pieces from `../Eldmark-raw/` | The per-race variety of §7.1 and the `body = 1` index | The catalog only lists what exists: one body, one head, `Hair_SimpleParted` and `Hair_Beard`; the races differ in allowed colors |
| Icons for the four items (ART-12) | Inventory and tooltip | Empty `icon_path`: the slot cell draws the short name in the category color |
| Visual approval of the appearance and the two windows | UI-26, ART-19 | Anything provisional is marked with `# TODO(arte)` |
| Legal review of the one-year ledger retention after purge | GDPR, together with those in platform.md §11 | The figure is provisional |
| The provisional decisions of §0 | | They apply as they stand |

## 17. Risks

| Risk | Mitigation |
|---|---|
| Two validations (GDScript and Go) that diverge | The same cases, generated by `write_fixtures.gd`, committed to the repo and checked by both (§13.3) |
| JSON precision: an id of 2^53 or more is silently corrupted in Godot | Ids as strings (platform.md §4.1): `jsonx.ID` in Go and `to_int()` in GDScript, exact up to 2^63 − 1; also, progress ones come from sequences and blocks starting at 1, and the zone and the service reject any above 2^53 − 1 (§3.4, S1) |
| Alphabetical net ids: adding an item changes the others' | They enter the `sim_hash`; the DB never stores net ids; they never travel to other clients |
| Cooldowns under 30 s: reconnecting resets them | Limited by the reconnection time and, in combat, by the body that stays for 15 s (GUE-41); reviewed with telemetry |
| Fit with abilities.md: `set_weapons`, the charge distribution and the refill change depend on H1b, H3c and H4 | abilities.md names rule; if they change, §4.1, §4.4 and §8 are adjusted on integration |
| No local persistence without platform (the user develops on Windows) | `deploy/dev.sh` or the platform.md compose; without them, everything works as ephemeral |
| Abuse with splitting and merging, or with clients that spend ids | They leave no events (§4.3), RATE of 2/s for what spends ids and a server reserve (§4.5) |
| Save volume | About 40 items (~4 KB of JSON) and one GAMEPLAY per save; with 1000 players and one save per minute, ~70 KB/s toward the service; the internal API body, 1 MB at most (platform.md §6). Measured in TEC-25 |
| One-year retention: data of a purged character | Without names (tombstone and `detail.args` by id); while the account exists, tied to it and exportable; pseudonyms only after purging it (§3.5); legal review (§16) |

## 18. Review

Three reviewers (security, coherence and implementability): 41 findings on version 1, with
duplicates merged into one row. Verified against the code, platform.md (0f6781b) and abilities.md
(32e23af): all of them hold. In eight rows the solution differs from the proposed one or is only
partly applied ("partly", "differently"). The rows are the history of the review; what changed afterwards, when
reconciling with platform.md, is in the last four rows and in §13.1.

| Id | Severity | What it was | What was done |
|---|---|---|---|
| PR-SEG2 · PR-COH2 · PR-IMP1 | blocking | Two load and save pipelines incompatible with platform.md: WELCOME before the single use and the sanctions, `begin_load` without `lease_token`, two idempotencies (`save_id`/`base_version` versus `lease_id`/`seq`), two uid generators, different JSON (strings versus numbers, repeated fields in `state`), different race and appearance | Progress is the `progress` section of `CharacterSaver`; it arrives in the claim and `prepare` runs before WELCOME; idempotency `(lease_id, seq)`; `save_id`, `base_version`, VERSION_CONFLICT and the old S2 are gone (`save_version` remains as a counter that plays no part in idempotency, platform.md §7.3; reconciliation note); a single generator (`item_uid_blocks`); health, position and play time only in `state`; numbers < 2^53; `race_<realm>` and 8 B requested from platform.md (§0, §3, §9, §13.1). **Partly**: no `starter_template_id` at creation (the template is chosen on first entry) |
| PR-COH1 · PR-IMP2 | blocking | Two `class_name CharacterRecord` (Godot registers only one) | The one here is `ProgressRecord`; `CharacterRecord` belongs to platform.md and carries `progress`; `test_architecture` forbids repeated `class_name`s (§14.2) |
| PR-SEG1 · PR-COH4 · PR-IMP7 | blocking | The append-only trigger aborted the cascade from `characters`: neither hourly purge nor account deletion, and no path for "one year later" | Append-only tables without a foreign key; tombstone with `Purge`; one-year retention with `set local eldmark.retention_purge`; export; verified on PostgreSQL 16; Go tests (§3.3, §3.5, §15). **Partly**: `ref_id`s are not set to 0 (it would be an UPDATE on the ledger and they are already pseudonyms) |
| PR-COH3 · PR-IMP3 | blocking | Nobody designed the Go side of progress; overlapping schemas; nonexistent operation and ledger routes | P7 belongs here: `platform/internal/progress/`, migration 0010 with `world_id`, S1–S8, routes, retention and tests, with dependencies on platform.md P0 and P3; `character_progress` without what platform.md stores (§3.3, §13.2, §14.1) |
| PR-COH5 · PR-IMP4 | blocking | `EquipmentState`, `StatBlock`, derived sheet, armors and visual ids that abilities.md leaves out and nobody designs | Provisional decision: in phase 5 only weapons and potions; slots 2–6 reserved; `ActionMachine.set_weapons` that preserves cooldowns and charges, and LOADOUT with `template_id` 0; UI-26 criterion noted in the backlog (§0, §4.1, §11) |
| PR-SEG3 · PR-COH11 | important | With `--debug-commands` and `--platform`, anyone could give themselves gold, XP and persistent items; `currency_add` over the network without a reason | DEBUG_COMMAND with platform requires `gm` (40–43, `admin`); `ServerMain` does not start in staging or production with both; "debug" note; test in `test_gm_progress` (§10). **Partly**: no free text in id 41 |
| PR-SEG4 | important | GM commands without a DB trace or with a trace that could be lost; actor unchecked; GM who gifts themselves; differing roles | `note` and `detail` in `economy_ops`; S2 checks the role and the own account; the save writes the audit with `op:<op_id>`; queries for `gm` (§3.3, §10, §13.3) |
| PR-SEG5 | important | CAMP_REFILL per stack: splitting gave unlimited potions | Refill by the definition's total; property and table case (§4.4, §15) |
| PR-SEG6 | important | Splitting and merging spent ids and filled the ledger; a client exhausted the zone's blocks | Move, split and merge without events or `op_id`; RATE of 2/s for what spends ids; 256 reserve for the server; no `save_id`; test with 10 000 requests (§4.2, §4.3, §4.5) |
| PR-SEG7 | important | Merits and XP from fake or NPC victims; unthrottled captures | Kill merits only for persistent victims of another realm; NPCs only `xp_reward` and `gold_reward`; capture once every 30 min per fort; no rewards with `--fake-players` and platform (§6.2). **Partly**: capture without defenders still pays (in Vado Gris it is the Hollow's; GUE-35) |
| PR-SEG8 · PR-COH9 | important | SPAWN was encoded once for everyone: real level to the enemy; item net id as visual id | `encode_spawn(tick, for_owner, receiver_realm)` and three variants per realm; no equipment block or net ids toward others (weapons go in `CombatState`); `visual_id` planned for PRG-05 and PRG-06; tests (§2.1, §7.3) |
| PR-SEG9 | important | A two-character operation did not fit the schema; handoff without freezing | `op_participants` with S2 per `(op_id, character_id)`; handoff with freezing and HANDOFF after the OK (§3.3, §8) |
| PR-COH6 | important | Health, position, level, play time, race and appearance in two places with opposite rules | One owner per field (§3.1); platform.md rules for position and health; `characters.level` is written by P7 |
| PR-COH7 · PR-IMP8 | important | CMB-30 ownerless, with opposite semantics and nonexistent hooks | It belongs here; time runs (UTC with `ZonePlatform.now_unix()`); in phase 5 only `unstuck` and `capture:<id>`, with `get_ready_at`/`set_ready_at` per character; long effects deferred; 52 B ticket (§8). **Partly**: the `ability_ready` imposition is not written until a 30 s cooldown exists (a test watches for it) |
| PR-COH8 · PR-IMP5 | important | Potions against the abilities.md model: predicted charges, spending at start, free refill | Charges `min(15, bag)` with `set_charges`; CONSUME at commit; the abilities.md refill is replaced by CAMP_REFILL with its cadence; stack of 15 (§4.4) |
| PR-COH10 · PR-IMP9 | important | Creation without `starter_template_id`, different races, two rules files, appearance of 0–64 B; `go:embed` does not allow `..` | A single `progression_rules.json` inside `platform/internal/gamedata/`, written by the platform.md tool with `ProgressionRulesExport`; 8 B and `race_<realm>` requested (§13.1). **Partly**: no `starter_template_id` at creation. *Reconciliation*: the template is chosen at creation and is the first entry's kit (§2.5); the tool is `tools/progression/export_rules.gd`, with a single test (§13.4) |
| PR-COH12 | important | New messages that `NetClient` and `SwarmBot` counted as malformed; "ephemeral" poorly defined | Reception goes in P4; `test_bot_swarm` and `test_net_processes` stay at 0; ephemeral = without platform; fakes, without inventory (§4.6, §9.4) |
| PR-IMP6 | important | A standalone operation mid-minute broke S3 through unrecorded gains; nobody set `seq` | Aggregates are closed before each standalone operation; `seq` is set by the service; case in `test_player_progress` (§5.2) |
| PR-IMP10 | important | P5 too large, without hooks or dependencies, first block undefined | P5a to P5d with their `ZoneServer` hooks, dependencies on PRG-09, MUN-07 and GUE-12, and the first block before opening the port (§4.5, §9, §14.1) |
| PR-IMP11 | important | Tests that proved neither PRG-10 nor TEC-25; cases written by tests; Askarra closed | End-to-end test with PostgreSQL and `kill -9`; cases generated by a tool and committed; PRG-14 criterion noted in the backlog (§15) |
| PR-IMP12 | important | 20 × 5000 operations did not fit in 10 s | 20 × 1000 with incremental invariants, under 5 s; the long one, separate (§15) |
| PR-IMP13 | important | What needs the user unmarked; catalog with pieces that do not exist; `HumanoidVisual` without an API to change pieces | "Pending from the user" table; the catalog only lists what exists; `set_part` and `clear_part` (§7, §16) |
| PR-SEG10 | minor | The safety net let `starter_granted`, `bound` and `bag_slots` go backward, I8, I9 and uids outside the union | I12; S2, S4, S5 and S6 check them; conservation per definition over the DB, the snapshot and the events (§3.2, §13.3) |
| PR-SEG11 | minor | `--progress-file` persisted without authentication or locking and revealed realms | **Differently**: the mode is removed; without platform nothing is saved and local persistence uses `deploy/dev.sh` (§0, §9.4) |
| PR-SEG12 | minor | Splitting or merging evaded a reversal | The reversal removes the definition's quantity across the whole character (§10). **Partly**: no `parent_uid`, which is no longer needed |
| PR-COH13 | minor | Protocol version uncoordinated | A single one for phase 5, shared, with the rule of who bumps it (§12) |
| PR-COH14 | minor | Appearance in the `sim_hash` rejected clients for no reason | Removed; `ItemDatabase` stays and networking.md §3 and the REJECT text change (§12) |
| PR-COH15 | minor | PRG-13, the 47 B ticket, `escudero` and MUN-07 out of date | PRG-13 and the decision, in the backlog; 52 B; `squire`; MUN-07 in P5c |
| PR-IMP14 | minor | MOVE on a full stack, potions in two kit rules, `smallint[]`, texture in `data/characters/`, reason of id 41, realm in JSON | Swaps; rule 2 without `camp_refill`; `integer[]` 0–65535; `texture_path`; "debug"; no realm in `progress` (§2.5, §3.3, §4.2, §7.2, §10) |
| Reconciliation | blocking | After the reviews, this document (§13.1) and platform.md (§17) still had two request lists that did not match | Interface reconciled (§13.1): one rule per topic, in the owning document, and the citation in the other. Here: `save_version` and `saved_at` return to `character_progress` (§3.3); race, appearance, position, health and play time move to the record and to `character_progress`, with no `characters.state` or `characters.level` (§3.1, §3.4); the return-to-world rule is written here (§8); there is no `CharacterRecord` (the claim brings `progress`, §9.1); section without `restore` and with `is_dirty`, and platform.md §7.3 responses (§9.2); ids as strings (§0, §3.4, S1); `id_blocks` blocks from platform.md (§4.5, S2, S5); single tombstone in `characters`, no `progress_tombstones` (§3.5); tables without `world_id` and with a foreign key without cascade through `op_participants` (§3.3); `ProgressStore` with `Summaries` and `ValidateCreate`, without `ErrFormat` or `RegisterInternalRoutes` (§13.2); S7 admits past dates (§13.3); exported rules in §13.4; template at creation (§2.5); environment guard by the registry's `env` (§10) |
| Reconciliation review | blocking | Reviewers on the two already-reconciled documents (43 findings, several duplicated; all hold). Here: the final save repeated the in-flight save's operations; `op_revert` (REVERSAL) outside S2 and S8, MIGRATION from the zones, unchecked reasons and two unsaved reversals; `ValidateCreate` without the appearance rule's data or common cases; progress errors in `internal/progress` (import cycle); `ProgressRecord` round trip impossible; DEBUG_COMMAND 5, 13 and 16 with `gm`; `detail.args` with names; a tombstone's ledger not exported | Journal with `save_seq = 0` per body (§4.3, §9.2); a single REVERSAL with actor and `detail`, S2 with kinds 1–5 and their reasons, S8 for GM and REVERSAL (§3.3, §10, §13.3); byte 0 = `race_id`, rules with `bodies` and `allows_no_*`, `appearance_cases.json` (§7.2, §13.4); `persistence.InvalidSaveError` and `ErrNotFound` (§13.2); `to_claim_dictionary` and `cancel_prepared` (§3.4, §9.1, §14.2); `admin` on 5, 13 and 16 (§4.4, §10); target by id and export without staff data (§3.5, §10); `PurgeRetention` with `emptied` (§3.5); the protocol is bumped by platform.md P4 (§12, §14.1). §13.1 table up to date |
| Second reconciliation review | blocking | 30 findings on the two documents (several duplicated; all hold, and in four the solution differs in part from the proposed one). Here: realm points that "never go down"; two sources of the active slot and respawn with an empty WEAPON_1; `refill` as CAMP_REFILL or as GM; `ValidateCreate` without a seam; `Op` without the instance; S2 with the actor's role at apply time and with already-saved `op_id`s; audit time; fort commands that paid the GM; hooks on a `net_id` without progress; `10^9` and `ceil` in GDScript; P5c without platform.md P6 | I9 in §0 and in the backlog; the active slot is bit0 of `combat_flags2`, in `InventoryOps.Context`, and on respawn WEAPON_2 if WEAPON_1 is empty (§4.1, §8); `refill` with platform is a GM operation with GM_GRANT, and 5 and 13 go only to the audit (§4.4, §10); `CreateValidator` and `ValidationError` (§13.2); `Op(…, instance)` (§13.2); S2 with the role at `detail.at_unix` and without repeated `op_id`s (differently: in phase 5 it always fails; the `SaveMany` exception arrives with trading) (§13.3); `at_unix` in `detail` and in S8 (§10, §13.3); forced fort changes without reward (§6.2); hooks with no effect (§9.2); `CAP` and `ceili` (§8, §14.2); DESTROY cap (§4.2); dependencies of P5a and P5c (§14.1). platform.md, §17 |
| Third reconciliation review | blocking | The same 25 findings (23 distinct; platform.md §18). Here: an `op_id` repeated in two simultaneous saves got through S8's `on conflict do nothing`; a duplicate uid came out as S5 or as S8; `last_save_version` missing from §3.1; the realm in three representations; `build_section` without ids in a long outage; S2 without the fixed `set-role` row, without a lower bound on `at_unix` and without checking `actor_character_id`; a uid could change definition; `/gm teleport` and `/gm visible` paid out | S8 without `on conflict` on `economy_ops` and the duplicate uid as S8 (§13.3; tests in P7); §3.1; the realm as a `NetProtocol.Realm` code in `validate`, the rules and the cases (§7.2, §13.4, §14.2); three id ranges and `build_section` returning `{}` (§4.4, §4.5, §9.2, §14.2; **partly**: the final save does not wait for the next block, platform.md §7.2); S2 with the `cli` `set-role` row, the block's `granted_at` and the actor's character (§13.3); I1 and S5 with a fixed definition (§3.2, §13.3); `gm_forced` (§6.2); rows and "v7" marks for the parts here in networking.md (§12, §14.1); `FakeZonePlatform` API cited in P5a, P5d and P8 (§14.1, §15). §13.1 table up to date |

The interface with platform.md was reconciled after the review: §13.1 says what was agreed and in which
document each rule lives. What the rows above name and no longer exists (`item_uid_blocks`, `state`,
`characters.level`, `world_id` in the progress tables, `CharacterRecord`, append-only tables without a
foreign key, position and health rules in platform.md, `ServerMain` refusing to start, the platform.md
tool, the template on first entry) predates the reconciliation.

## 19. Implementation

What each package did, where it departs from this document and what was measured. Each package adds its
section when it finishes.

### 19.1 What platform.md P2 brought forward

platform.md P2 (its §19.3) arrived before P3 here, so it created what §13.4 gives to "whoever arrives first":

- **Exported rules.** `ProgressionRulesExport` (`scripts/shared/progression/progression_rules_export.gd`)
  with `build()` and `to_json()` (sorted keys, tabs and a trailing newline) and the two sections of
  platform.md, `protocol_version` and `names`; `tools/progression/export_rules.gd`, which writes
  `platform/internal/gamedata/progression_rules.json` (with `-- --check` it only compares); and the only test,
  `tests/test_progression_rules_export.gd`: deterministic `build()`, the file up to date, sorted keys and the
  platform.md sections. In Go, `internal/gamedata` embeds it and provides the whole `Raw()`.
- **The §13.2 boundary** in `platform/internal/persistence/progress.go`, with the signatures as they are
  (`ProgressStore`, `Querier`, `CreateParams`, `SaveKey`, `Summary`, `InvalidSaveError`, `ErrNotFound`,
  `CreateValidator` and `ValidationError`), the provisional validation (`ProvisionalValidator`) and the fake
  (`MemoryProgressStore`, in `memory.go`), which `serve` uses in `dev` and `test` until P7 exists (in `staging` and
  `production` it does not start with it).

**For P3 here:** each new section (`races`, `appearance`, `starter_templates`, `items`, `level_curve`,
`currencies`, `reasons`, `containers` and `combat`) enters `build()` with its own function, like `_names`, and its
checks go in the same test; then the file is re-exported and committed with the change.
`gamedata` does not look at keys that are not from platform.md, so nothing in Go breaks when adding them.
**For P7:** `progress.LoadRules(gamedata.Raw())`; `*progress.Rules` implements `persistence.CreateValidator` and
the store `persistence.ProgressStore`; `serve` picks them by changing only `progressStore()` in
`platform/cmd/eldmark-platform/services.go`. The platform already uses `Summaries` this way: an empty `LastZoneID` means "has never
entered", and a character that the store does not return shows up in the list with race, appearance and last zone as null and
level 1. `Purge` is already called from the character purge of platform.md (§11.2), inside its transaction and with
the lease and the character row locked.

### 19.2 What platform.md P3 left

platform.md P3 (its §19.4) built the internal API on the `ProgressStore` interface, so P7 only has to
implement it:

- **Routes of §13.2.** `GET /internal/v1/ops/{op_id}?zone_instance_id=` calls `Op(ctx, pool, opID,
  instance)` outside a transaction and replies with its JSON as is (or 404 with `ErrNotFound`); `GET
  /internal/v1/characters/{id}/ledger?zone_instance_id=&limit=&before_entry_id=` first checks the character's
  lease on the instance, validates `limit` (1–100, 20 by default) and `before_entry_id` (0 without it) and calls
  `Ledger(ctx, pool, …)`. Both require the `live` instance (platform.md §6.1).
- **Save.** `Apply(ctx, tx, key, progress)` runs in the transaction that already has the lease
  locked and the `seq` checked, with `key.ZoneID` from the `claimed_by` instance and `key.WorldID` from the
  lease; an `*InvalidSaveError` or a SQLSTATE of class 22 or 23 or `P0001` (also at COMMIT) are 400
  `invalid_save`, and a `40001` is retried with the whole transaction. A `duplicate` does not call `Apply`. Since the
  review of the platform.md implementation (its §19.7), class 22 (data the database does not accept: a NUL in
  a `jsonb`, a number or a date out of range) counts like 23: before it was a 500 that the zone retried
  endlessly.
- **Claim.** `Load(ctx, tx, characterID)` runs in the claim's transaction, with the
  lease just taken; a `Load` error is a 500.
- **The fake** (`MemoryProgressStore`) imitates a minimal S2 (an already applied `op_id` fails) and `Op` with the
  query of the participants' leases: the P7 tests with the real store are what
  say that S1–S8 and the `join` of `op_participants` do the same.

### 19.3 What platform.md P7a leaves

platform.md P7a (its §19.5) writes the `set-role` row that S2 reads (§13.3) and provides the finished query:

- **`sanctions.RoleAt(ctx, q, accountID, at)`** (`platform/internal/sanctions/roles.go`) is the S2 rule as
  is: the `args.from` of the first `audit_log` row with `source = 'cli'`, `command = 'set-role'` and
  `target_account_id` the account, with `at` later than the instant (`order by at, id`), or, if there is none, the
  role in `accounts`; "" if the account does not exist. P7 calls it inside `Apply` with `time.Unix(detail.at_unix, 0)`
  and the save's transaction. Its test (`TestRoleAtOnlyReadsCLI`) checks that a `set-role` row with another
  `source` does not count and that the zone's audit batch rejects entries with `source = 'cli'` or `command =
  'set-role'`.
- **The lock order:** `set-role` locks the `accounts` rows of the `--actor` and the target (`for no
  key update`, in id order) and writes the row with Go's time in the same transaction that changes the role.
- **Audit without personal data:** the CLI and platform rows never carry emails or names in
  `args` (platform.md §9.1); those of S8 follow the same rule (the target by id in `detail.args`, §10).

### 19.4 P3 · progress and appearance (PRG-13, PRG-14, ART-19)

**What exists.** What §14.1 P3 lists, in `scripts/shared/progression/` except where stated:

| Piece | Content |
|---|---|
| `LevelCurve` and `data/progression/level_curve.tres` | The table of §6.1 (39 values, cap 40, one attribute point per level). `shared()`, `total_to`, `level_for`, `xp_for_next` (the XP from the level to the next, 0 at the cap: what PROGRESS_UPDATE asks for) and `get_errors` |
| `ProgressionRules` | `XP_PER_MERIT`, `XpResult`, `add_xp` and `attribute_points` (§6.3) |
| `AppearancePart`, `AppearanceColor`, `RaceDefinition` | The resources of §7.2. Scenes and textures go as paths (`String`), never as loaded resources. `RaceDefinition` adds `description` (the people's own traits, for creation) and `allowed(category)` |
| `AppearanceCatalog` | `shared()`, `race_index`, `race_for_realm`, `entries`, `ids_of`, `fitting_indices` and `get_errors`: well-formed, non-repeating ids, sizes that fit in the 8 B (16 eye colors and 15 marks at most), at least one body, one head and one color of each kind, pieces with bodies that exist and, per people, playable realm, indices that exist without repeats, a head (and hair or beard if it does not allow going without them) for each allowed body and empty `stat_modifiers` |
| `CharacterAppearance` | The 8 B: `encode`, `decode`, `validate`, `random`, `default_for` and `equals` |
| `data/characters/` | `appearance_catalog.tres`; `races/race_vardheim.tres`, `race_solmarch.tres` and `race_askarra.tres`; `appearance_ids.txt` ("category index id", with three `#` comment lines at the start) |
| `ProgressionRulesExport` | The sections `races`, `appearance`, `level_curve`, `currencies`, `reasons`, `containers` and `combat`; the file exported again |
| `tests/fixtures/progression/appearance_cases.json` | 40 hand-written cases (7 valid), one or more per rule: race and realm, each out-of-range index, what each people does not allow, and sizes of 0, 7 and 9 B |
| `platform/internal/progress/rules.go` | The P7 package starts here: `LoadRules` (the seven sections, each strict with `jsonx.DecodeBytes`, and the same checks as the catalog's and curve's `get_errors`, plus those for currencies, reasons, containers and health), `ValidAppearance` (the rule of `validate`), `RaceIndex`, `TotalTo` and `LevelFor` |

**The phase 5 catalog** only has what is in the repo (§16): the body `body_male` (`Male_Ranger.gltf`, the
ranger outfit with its body), the head `head_superhero_male` (`Superhero_Male_Head.gltf`), the hairstyle
`hair_simple_parted` (`Hair_SimpleParted.gltf`) and the beard `beard_full` (`Hair_Beard.gltf`); no marks. The
head and the beard fit only body 0 and the hairstyle fits all, so that a female body (ART-20) does not
inherit a male head or beard. Colors: 8 skin tones (the full palette in the three realms, §0),
10 hair and 7 eye colors. What distinguishes the peoples (provisional, **made overnight**, until ART-20 and the visual
approval of §16):

| People | Hair (indices) | Eyes (indices) | No hair | No beard |
|---|---|---|---|---|
| `race_vardheim` | chestnut, mahogany, redhead, copper, blond, straw blond, ash, gray (2–9) | hazel, green, blue, gray, ice blue (1, 3–6) | no (braids and manes) | no (long beards) |
| `race_solmarch` | black, dark brown, chestnut, mahogany, blond, gray (0–3, 6, 9) | brown, hazel, amber, green, blue (0–4) | yes (tonsure) | yes |
| `race_askarra` | black, dark brown, mahogany, redhead, ash, gray (0, 1, 3, 4, 8, 9) | brown, amber, green, gray (0, 2, 3, 5) | no (tied-back hair) | yes |

**Format of the sections** (sorted keys, like the whole file):

- `races`: `[{id, realm, allows_no_hair, allows_no_beard, bodies, heads, hairs, beards, marks, skin_tones,
  hair_colors, eye_colors}]` in catalog order (the position is byte 0 − 1), with the realm as the
  `NetProtocol.Realm` code and the lists as indices from 0 (also hair and beard).
- `appearance`: `{body_count, heads, hairs, beards, marks, skin_tone_count, hair_color_count, eye_color_count}`, with
  each piece list as `[{id, bodies}]`.
- `level_curve`: `{level_cap, xp_to_next, attribute_points_per_level}`.
- `currencies`: `[{code, id, cap}]` (`gold` and `merits`, cap 10^9).
- `reasons`: `{ranges: {source, sink, internal}, codes, op_kinds}`, each range `{min, max}` and the reasons and operation
  kinds by lowercase name (`starter_kit`: 1…).
- `containers`: `{bag: {code, default_slots, max_slots}, equipment: {code, slots, open_slots}, open: [0, 1]}`.
- `combat`: `{health_max}`.

**Deviations and implementation decisions:**

- **No `items` or `starter_templates`.** §14.1 says P3 depends on nothing, but §13.4 and §15 put in its
  export the items (from `ItemDatabase`, P1, which runs in parallel) and the `selectable` templates (from
  `EquipmentTemplate`, abilities.md H1a, which is not yet in this branch: `wip/fase5-go` comes off `b4affb7`, before
  abilities). They enter with those packages, each with its function in `build()` and its checks in
  `test_progression_rules_export`; `LoadRules` ignores them until P7 reads them. Meanwhile, `*progress.Rules` does not
  implement `CreateValidator` and `serve` stays with the provisional validation from platform.md P2.
- **Currencies, reasons, containers and operation kinds are constants of `ProgressionRulesExport`**
  (`CURRENCIES`, `REASON_RANGES`, `REASON_CODES`, `OP_KINDS`, `CONTAINERS`): their classes (`Currency`,
  `EconomyReason` and `InventoryState` from P2; `EconomyOp.Kind` from P5a, in `scripts/server/`, which shared code
  cannot read) do not exist yet. `reasons` contains all the reasons of §5.3, including those of later phases, because
  their numbers are already fixed.
- **The shared cases carry a fifth key, `case`** (the rule they test), besides `{realm, race_id,
  appearance, valid}`: with 40 base64 cases, without it a failure is not understandable. Both tests require all five.
  Anything that is not 8 B is not valid, on both sides.
- **The body rule has no shared case:** with a single body in the repository one cannot write
  "a piece of another body" with the real data. Both tests check it with the same two-body catalog
  built in the test (`_two_body_catalog` in GDScript, `twoBodyRules` in Go).
- **Going without marks is always valid** (there is no `allows_no_marks`). Skin, hair color (also eyebrow color)
  and eye color are always required, whether or not there is hair and beard.
- **`default_for`** takes the first thing each list allows, with hair and beard if any is compatible and no marks;
  **`random`** is uniform in each field among what is compatible with the chosen body, with "none" among the options
  when it is allowed. Both return null for a race index that does not exist.
- **`add_xp`** with 0 or less applies nothing; a total above the cap is brought to the cap (I8).
  **`attribute_points`** never drops below 0 (after a reversal that removes levels).
- **`shared()`** (curve and catalog) loads once and, if the resource is missing, logs the error and returns an empty one
  (everyone at level 1; no appearance is valid). The catalog also logs its `get_errors`.
- **The examples in §3.4 and §9.3 did not satisfy I8** (level 7 with 12345 XP, which with this curve is level 8) **and their
  appearance was not valid** (marks 2, and there are no marks): they change to level 8 and to `AQAAAQEDAgE=`, which is in the shared
  cases.
- **`test_architecture`** gains three tests: shared progression does not name `Time`, `OS` or `Input` and
  `scripts/server/progress/` does not name `Time` (the folder does not exist yet: the rule is already there for P5a); no `.tres`
  in `data/characters/`, `data/items/` or `data/progression/` links to or has, declared or with a value, a texture,
  a scene or a mesh, not even in its subresources; and no `class_name` is repeated in `scripts/`, `tests/`,
  `tools/` or `addons/` (§14.2 said `scripts/` and `tests/`, but tools and add-ons also
  register classes).
- **`test_export_config`:** the catalog, a race and the curve are among what no filter can remove, and the
  catalog and the curve, in the server package.

**For the following packages.**

- **P1** adds `items` (`_items()` with `ItemDatabase`) and **the integration with abilities.md** `starter_templates`
  (the `EquipmentTemplate`s with `selectable`); each re-exports the file and extends
  `test_progression_rules_export` and `LoadRules`.
- **P2** makes `_currencies`, `_reasons` and `_containers` read from `Currency`, `EconomyReason` and
  `InventoryState`: the file must not change. **P5a** checks that `EconomyOp.Kind` matches
  `ProgressionRulesExport.OP_KINDS`.
- **P4:** the SPAWN carries `CharacterAppearance.encode()`; the client replaces an invalid one with `default_for`.
- **P5a:** in `ProgressService.prepare`, `CharacterAppearance.decode` and `validate(AppearanceCatalog.shared(),
  claimed.realm, race_id)`; if invalid, `default_for(catalog, catalog.race_index(race_id))`. `ProgressRecord`
  checks I8 with `LevelCurve.shared().level_for`, and `PlayerProgress.add_xp` uses `ProgressionRules.add_xp`.
- **P6 and platform.md P8:** `random` for "Aleatorio" (random), `display_name` of pieces, colors and peoples for creation;
  `AppearanceApplier` mounts `scene_path` and tints with `color`.
- **P7:** `progress.LoadRules(gamedata.Raw())` already reads and checks P3's content. What remains are `items` and `starter_templates`,
  `ValidateCreate` (`RaceIndex` and the realm for `{"race_id": "wrong_realm"}`, `ValidAppearance` for
  `{"appearance": "invalid"}`) and what S5 and S6 read (`LevelFor`, `Combat.HealthMax`, `Containers`,
  `Currencies`, `Reasons`).

**Tests.** In Godot: `test_level_curve` (9: resource in text form and without errors, 39 increasing values, the table of
§6.1 and its formula, `level_for(total_to(n)) = n` and one point before, several level-ups from a single contribution, the cap, contributions
of 0 or negative, attribute points and a broken curve); `test_character_appearance` (13: round trip of 200 random × 8 B
and of a known one field by field, other sizes, the 40 shared cases, each field out of range, race and
realm, going without hair or beard, the piece of another body, 100 valid random ones per race and `default_for`, one race per
realm in its file, no stats, `appearance_ids.txt` as a prefix, scenes that exist and catalog
errors); `test_progression_rules_export` (the 5 from platform.md P2 and 5 new ones, one per section or group);
`test_architecture` (3 new, above) and `test_export_config` (the new data). In Go, `internal/progress` (5):
the shared cases, the piece of another body, the embedded rules (races, curve, currencies, reasons,
containers, health), each byte out of range and 28 broken files that `LoadRules` rejects.

**Measured** (this machine, 4 cores, Godot 4.7.2 headless, Go 1.24.7):

| What | Result |
|---|---|
| The 30 new Godot tests | The slowest, 8 ms (`test_100_random_valid_per_race`); each file, about 7 s with the runner startup |
| `test_architecture` | 12 s (the three new ones, 0.8 s: almost all of it is `test_class_names_are_unique`) |
| Whole Godot suite | 1954 tests (1924 before), all passing, in 1042 s |
| `go test ./internal/progress` | 0.01 s (5 tests); whole `go test -p 2 -count=1 ./...`, 32 s |
| `progression_rules.json` | 4286 B (877 with only the platform.md sections) |

`--import` gives the same log as before (the usual leaks on exit) and the tool with `-- --check` exits
with 0.

**Not verified:** the pieces and colors on `HumanoidVisual` (`AppearanceApplier`, P6) and the visual approval
of each people's colors (§16); the body rule with real data (arrives with the female body of
ART-20).

**Left for later:** `items` (P1) and `starter_templates` (integration with abilities.md) in the exported
rules; `ValidateCreate` and the rest of the Go store (P7); the use of all this in the zone (P4, P5a, P5c) and in the
client (P6, platform.md P8).

### 19.5 What the platform.md implementation review changes

The platform.md review (its §19.7) touches three things that P7 sees:

- **The save error rule** (§13.1, "Save responses", changed identically in both documents):
  a SQLSTATE of class 22 is, like one of class 23, 400 `invalid_save` with `check = "S8"` (`db.Deterministic`).
  A `progress` with `\u0000` in a string that `Apply` stores in `jsonb`, or a number that does not fit its column,
  no longer leaves the character unable to save forever. Even so, S1–S7 should reject first whatever does not fit, with their
  own `check`.
- **`characters.last_entered_at`** is no longer written by the claim but by the first applied save of each
  lease (with the claim's time); `persistence.Store` does it after `Apply`, in the same
  transaction. P7 does not have to do anything.
- **`pvp`**: the envelope rejects (`envelope`) `int` totals above 2^31 − 1.

### 19.6 P1 · items (PRG-02)

**What exists.** What §14.1 P1 lists, in `scripts/shared/progression/` except where stated:

| Piece | Content |
|---|---|
| `ItemDefinition` | The fields of §2.1 with their enums (`Category`, `EquipSlot`, `BindRule`), `ID_PATTERN`, `MAX_STACK` and `is_equipable()`. Icon and scenes as paths (`String`), never as resources |
| `ItemInstance` | The fields of §2.1 and the constants of §14.2; `encode`, `decode` and `encoded_size_at` (§2.3, little endian like the rest of the protocol), `to_dictionary`/`from_dictionary` (§3.4), `duplicate_instance`, `equals`; plus `create(uid, definition, quantity)` (full durability and bound if the rule is `ON_PICKUP`), `is_valid(db)` (the `decode` rule over an in-memory instance) and `encoded_size()` |
| `ItemDatabase` | `shared()`, `build_from_directory` (with subfolders and `.tres.remap`), `build_from_definitions(definitions, combat)` (the one used by tests and cases), `get_definition`, `net_id_of`, `definition_by_net_id`, `for_ref`, `consumable_definition`, `all_ids`, `wire_hash` and `errors` |
| `ProgressJson` | Strict reading of the progress JSON, like `jsonx` in Go: `is_id` (canonical decimal string, ≤ 2^53 − 1), `id_value`, `id_text`, `is_int` (exact number, accepts `820.0`) and `is_bool`. `ProgressRecord`, `EconomyOp` and `LedgerEntry` (P5a) will use it too |
| `data/items/` | `weapon/sword_shield_vado.tres`, `weapon/bow_vado.tres`, `consumable/potion_health.tres` and `consumable/potion_stamina.tres` (§2.4) |
| `tests/fixtures/items/` | `armor/` (three valid armors: helmet and boots with durability, chest piece without it) and `broken/` (three invalid ones: in the weapon slot, without a slot and stackable) |
| `ProgressionRulesExport` | The sections `items` and `starter_templates`; the file exported again |
| `platform/internal/progress/rules.go` | `LoadRules` reads the two sections, strict like the others, with the `ItemDatabase` checks that make sense without the combat catalog; `Item(id)`, `SelectableTemplate(id)` and the constants `Category*`, `Slot*` and `MaxStack` |

**Format of the sections** (sorted keys):

- `items`: `[{id, category, equip_slot, max_stack, has_durability, required_level}]` in net id order
  (alphabetical), with category and slot as the numbers of §2.1. Go requires that order.
- `starter_templates`: `[{id, weapons}]`, the `EquipmentTemplate`s with `selectable = true` in the order of their id
  (today `marksman` and `squire`) and, in `weapons`, the **item ids** of their weapons in slot order
  (`["bow_vado", "sword_shield_vado"]` and `["sword_shield_vado"]`): the kit of rule 1 of §2.5. A weapon without an
  item would come out as `""` and `LoadRules` rejects the file.

**Deviations and implementation decisions:**

- **`starter_templates` enters here.** §19.4 left it for "the integration with abilities.md", which is not a
  package of §14.1; abilities.md is already in `main`, its weapons are items of this foundation and P7 needs it for
  `ValidateCreate`. `*progress.Rules` still does not implement `CreateValidator` (that is P7): it already has
  `RaceIndex`, `ValidAppearance` and `SelectableTemplate`.
- **Ids stricter than "`is_valid_int()` and `to_int()`"** (§14.2): `ProgressJson.is_id` requires the form of
  `jsonx.ParseID` (digits only, no sign or leading zeros) and at most 16 digits before calling
  `to_int()`, which with 20 digits logs an engine error. `"+5"`, `"007"`, `" 5"` and `"5.0"` are invalid on both
  sides.
- **`from_dictionary` requires the ten keys of the §3.4 entry**, also `container` and `slot` (exact integers
  from 0 to 65 535): their range depends on the container and `bag_slots`, and `ProgressRecord` (P5a) checks it.
  It does not enforce the phase 5 rules (rarity 0, no affixes): the model is the general one and S5 checks those.
- **`encode` of an instance that is not valid** (`is_valid` false: unknown definition, quantity, durability,
  rarity, seed or affixes out of range) returns an empty array without logging anything; whoever builds the
  message (P4) treats it as its own failure. **`encoded_size_at`** also gives −1 with another format or more than 6
  affixes: this way walking a list never mis-skips an entry.
- **Consistency rules in addition to those of §2.1:** `camp_refill` fits in a stack (rule 3 of the kit puts it
  in one); icon empty or under `res://assets/icons/items/`; scenes only on armors and under `res://assets/`;
  categories that are not weapon, armor or consumable go without slot or `ref_id`; and **two items for the
  same weapon or the same consumable are an error** ("in phase 5 there is one per `ref_id`", §2.2): the kit and
  CAMP_REFILL depend on `for_ref` not hesitating. If phase 6 brings variants of a weapon, the rule changes with
  them. `required_level` is checked against `LevelCurve.shared().level_cap`.
- **A repeated id** produces a warning and the one that arrives first stays (`build_from_directory` arrives in path order):
  `sort_custom` is not stable, so the order breaks ties by position.
- **`wire_hash`** is the SHA-256 of `var_to_bytes` of the list `[id, net_id, category, equip_slot, max_stack,
  has_durability]` per item, without a version. It does not yet enter `NetProtocol.compute_sim_hash`: P4 does that with the
  rest of version 7.
- **Folders in English** (`weapon/`, `consumable/`: the enum name in lowercase) and files named after
  the id; the test requires it for `data/items/`. Potions are destroyable (§2.4 only fixes the weapons).

**For the following packages.**

- **P2:** `StarterKit` with `for_ref(WEAPON, weapon)` and the definitions with `starter` and `camp_refill` from
  `all_ids()`; `ItemInstance.create` gives the kit instance (bound, because starter items are
  `ON_PICKUP`); binding on equip belongs to `InventoryOps`.
- **P4:** `ItemDatabase.wire_hash()` in `compute_sim_hash`; INVENTORY_DELTA and INVENTORY_FULL with `encode` and
  `encoded_size_at`/`decode` (an empty `encode` is a server error).
- **P5a:** `ProgressRecord.from_dictionary` reads `container` and `slot` and calls `ItemInstance.from_dictionary`;
  the record's other ids, with `ProgressJson`.
- **P7:** `ValidateCreate` with `SelectableTemplate` for `{"starter_template_id": "not_selectable"}`; S5 with
  `Item(def_id)` (definition in the rules, stack, durability, weapons in equipment).

**Tests.** In Godot: `test_item_database` (10: the data without errors and in order, unique well-formed ids and in
text form in `data/items/` and in the cases, the content of §2.4, `ref_id`s that exist, one item per weapon of each
template and per consumable, alphabetical net ids also with the armors interleaved, the stable fingerprint that
changes with what shapes it and not with anything else, the ARMOR rule with the cases, each consistency rule one by one
and a folder with something that is not an item); `test_item_instance` (8: round trip of 1000 seeded instances,
with and without durability and affixes, in binary, walked through a buffer with `encoded_size_at` and through the JSON text;
a known encoding byte by byte; null in each case of §2.3 and in each truncation; empty `encode` for what is not
valid; the §3.4 entry as is; `from_dictionary` with 38 broken entries, each missing key, one extra and
integers as `820.0`; `create`, `duplicate_instance` and `equals`; the default shared database);
`test_progression_rules_export` (2 new: `items` and `starter_templates`, and the exact sections);
`test_export_config` (two items among what no filter can remove and in the server package). In Go,
`internal/progress`: `TestEmbeddedItemsAndTemplates` and 25 more broken files in
`TestLoadRulesRejectsBrokenFiles`. The round-trip tests, the ARMOR one and the id ones were verified with the
mutation they should catch (without the flags check, the armor slot check or the leading-zeros check, they fail).

**Measured** (this machine, 4 cores, Godot 4.7.2 headless, Go 1.24.7):

| What | Result |
|---|---|
| `test_item_database` | 10 tests; the slowest, 18 ms (the first load of `data/items` with the combat catalog); the file, about 10 s with the runner startup |
| `test_item_instance` | 8 tests; the 1000-instance one, 131 ms (encode, decode and pass through JSON each one); the file, about 12 s |
| `test_architecture`, `test_export_config` | 19 and 10 tests, passing (18 and 27 s) |
| `go test -race ./internal/progress` | 1.2 s; whole `go test -race -count=1 ./...`, passing |
| `progression_rules.json` | 5066 B (4286 before) |

**Not verified:** `ItemDatabase` in a truly exported project (the `.tres.remap` files of subfolders): the
server package test checks that the items are inside, not that they load from it.

**Left for later:** `ItemDatabase` in the `sim_hash` and the inventory messages (P4); the inventory, the kit
and the currencies (P2); the record (P5a); `ValidateCreate` and S5 in Go (P7); the icons (ART-12, §16).

### 19.7 P2 · pure inventory (PRG-11, PRG-12)

**What exists.** What §14.1 P2 lists, in `scripts/shared/progression/` except where stated:

| Piece | Content |
|---|---|
| `InventoryState` | The enums and constants of §14.2 (with `ContainerId`, below) and `OPEN_CONTAINERS` (`[0, 1]`); `get_item`, `set_item`, `first_free`, `find_uid`, `count_of`, `all_items`, `duplicate_state` and also `slot_count`, `has_slot`, `free_count`, `occupied_slots` (in `all_items` order) and `equals`. `bag_slots` is bounded to 1–120 and on change keeps what fits |
| `InventoryOps` | `Request`, `Context`, `Outcome`, `apply` and `result_text` of §14.2, plus `make_request`, `fits_slot` and the server-side changes of §4.4: `camp_refill`, `add_items` and `remove_items`. `Outcome` gains `new_id`, `required_level`, `bag_full` and `is_ok()` |
| `ItemEvent` | The fields of §14.2, `create`, `equals` and the `items` entry of an operation (§9.3): `to_dictionary` and `from_dictionary` |
| `EconomyReason` | The 26 reasons of §5.3, the ranges, `CODES` (lowercase name → code), `is_source`, `is_sink`, `is_internal`, `is_known`, `sign_matches` (§5.2), `gives_realm_points` (I9: 3–5), `name_of` and `ranges()` |
| `Currency` | `Code`, `CAP` (1 000 000 000, written with `_`), `WALLET_SIZE` (3: index = currency), ids (`gold`, `merits`) and names in Spanish; `codes`, `is_valid`, `id_of`, `code_of`, `cap_of`, `display_name` |
| `CurrencyRules` | `can_apply` and `clamp_gain` of §14.2, without adding before comparing (a delta near 2^63 does not wrap around), and `replay(deltas, start = 0)`: the balance the entries leave in order, or −1 if any is 0 or goes out of 0–`CAP` at some step (the reconstruction of §5.4) |
| `StarterKit` | `grant` of §14.2, `template_for` (the template it uses) and `plan` (where each item goes) |
| `ActionMachine.set_weapons` | §4.1 as is, in `scripts/shared/combat/action_machine.gd` |
| `ProgressionRulesExport` | `_currencies`, `_reasons` and `_containers` read from `Currency`, `EconomyReason` and `InventoryState`; the constants `CURRENCIES`, `REASON_RANGES`, `REASON_CODES` and `CONTAINERS` are gone. `OP_KINDS` stays until `EconomyOp` (P5a). The file comes out byte-for-byte identical (5066 B; `-- --check` exits with 0) |

**Deviations and implementation decisions:**

- **`enum ContainerId`, not `Container`.** Godot will not compile `InventoryState` with a member named like
  a native class ("The member "Container" shadows a native class"). §14.2 already says so. The values are the same.
- **The order of §4.2, with two clarifications.** The quantity against the stack (SPLIT of `count` or more, DESTROY of more than
  what is there) is INVALID, but it is checked **after STALE**: without the item the client expected there is no stack to
  measure it against. And the id for SPLIT and DESTROY is requested **last**, when everything else is valid (after LOCKED): a
  rejected request never spends an id; in exchange, with NO_ROOM or LOCKED and no ids at the same time, NO_ROOM or LOCKED comes out.
  The rest, in the table's order; WEAPON_REQUIRED goes before LOCKED, so destroying the active weapon gives
  WEAPON_REQUIRED.
- **DESTROY takes its id in `apply`** (the `op_id` of its PLAYER operation, in `Outcome.new_id`), just as SPLIT takes the
  `uid` of the new stack: this way `PlayerProgress.apply_request` does not have to look at the ids before validating. RATE,
  "no character or outside the world" and the cap of 256 unconfirmed operations do not come from `apply` (§4.2: the
  server checks them).
- **`Outcome.changed` on a rejection** carries the slots that exist among those the request touched: those that the delta
  sends with their real contents (§4.6). A rejection never changes anything or gives events.
- **CANNOT_EQUIP looks at what enters** an equipment slot from another (also what comes back in a swap:
  unequipping onto a potion would put it into the weapon slot); what stays where it was is not looked at again.
  The level goes in `Outcome.required_level` and `result_text(result, required_level, in_combat)` gives "Necesitas nivel N"
  and the combat text; the caller knows whether it is in combat.
- **An instance already in the state is never changed**: what changes (quantity, bound) is a copy. The
  client (P6) can rebuild its view over a copy of the confirmed state without touching it. ON_EQUIP binds on entering the
  equipment, also in the kit.
- **Merging requires the same bound state** (§4.2); `camp_refill` and `add_items` add to stacks with the bound state the
  new ones would have (bound if the rule is ON_PICKUP).
- **Server-side changes** (not in §14.2; the property test needs CAMP_REFILL and those of P5a are
  the same calculations): `camp_refill` is the rule of §4.4 as is (since `camp_refill ≤ max_stack`, if any stack
  remains the one in the lowest slot has room for what is missing: a new stack is only needed with none;
  `bag_full` if it does not fit and nothing if the id is missing); `add_items` fills stacks with room and then new stacks, whole or
  nothing (NO_ROOM, or NOT_NOW if an id is missing); `remove_items` removes from `prefer_uid`, then from the bag by slot and
  last from equipment, whole or nothing (STALE if there are not that many), and **does not check I10**: removing an equipped weapon (GM,
  reversal) is up to the caller. Its events always carry the `uid`: aggregating them (`uid` null, §5.2) belongs to the P5a
  journal.
- **Kit**: rule 3 of §2.5 does not require `starter` (it says "each item with `camp_refill > 0`"); a template that exists
  but cannot be chosen counts as unknown (the first selectable by id, today `marksman`, with a warning); a weapon
  without an item is skipped and the next one takes its slot, so that WEAPON_1 is not left empty. With a non-empty inventory,
  no room in the bag or no templates it logs the error and gives nothing; without an id it gives nothing (the ones taken
  are lost). The uid order is the placement order: with the squire and ids from 1025 the example of §3.4 comes out.
- **`set_weapons`** does not clear combo, buffer or key press ("without resetting anything else"): there is only action NONE, the combo is
  bounded to the weapon in `_try_start_light` and the owner is corrected with the LOADOUT. With an action, `push_error` and nothing.
- **Advances for P5a**: `ItemEvent.to_dictionary`/`from_dictionary` (validates it without checking whether the definition
  exists: an old event may name one that no longer exists), `EconomyReason.gives_realm_points`,
  `Currency.WALLET_SIZE` and `code_of`.

**For the following packages.**

- **P4:** INVENTORY_REQUEST with `InventoryOps.make_request` (destination `NO_SLOT` in DESTROY); the containers, from
  `InventoryState.ContainerId`.
- **P5a:** `PlayerProgress.apply_request` fills the `Context` (active slot from the `CombatState`,
  `can_touch_equipment`, `drinking`, `new_uid = ids.next_for_client`) after checking the DESTROY cap, and uses
  `Outcome.new_id` as the PLAYER `op_id` (with a PLAYER_DESTROY event already made); `gain_items`/`lose_items` and
  `add_items`/`remove_items` over those of `InventoryOps`, aggregating their events; the kit with
  `StarterKit.grant(…, ids.next_for_server)`; `EconomyOp.from_dictionary` with `ItemEvent.from_dictionary`;
  `EconomyOp.Kind` equal to `ProgressionRulesExport.OP_KINDS`.
- **P5b:** `camp_step` with `InventoryOps.camp_refill` (`bag_full` → the NOTICE, once per entry); CONSUME with
  `remove_items(def, 1, CONSUME)`; `weapons_changed` → `set_weapons` with `stash_ready`; charges `min(15, count_of)`.
- **P6:** `ClientInventory` with `apply` and `result_text(result, required_level, in_combat)`; negative provisional
  ids in `new_uid` (anything but 0 works).

**Tests.** In Godot: `test_inventory_ops` (20: `InventoryState`; INVALID, STALE, NOT_NOW, CANNOT_EQUIP,
WEAPON_REQUIRED, NO_ROOM and LOCKED with their order and without changing anything; moving, partial and full merge, the three
swaps, splitting, destroying with the single event, binding on equip, what a rejection carries, the texts, the
server-side changes, `ItemEvent` in JSON with 13 broken entries and the kit of the two templates, with its failures);
`test_inventory_properties` (3: 20 seeds × 1000 operations with the invariants of §15, the long one behind the filter and the
split-stack table); `test_currency_rules` (6: currencies, caps and negatives, clamped gains, two
operations in the same tick and the example of §5.2, reconstruction with 20 random ledgers, ranges and signs of the
reasons); `test_action_machine_weapons` (6). Verified with the mutation they should catch: SPLIT reusing the
uid, CAMP_REFILL per stack, no WEAPON_REQUIRED, merging without a cap and DESTROY without an event (the properties); armors in
2–6 (the properties, after often sending each item to its slot: at random it almost never got there); merging without checking
the bound state, CANNOT_EQUIP after WEAPON_REQUIRED, STALE after the quantity, the id requested before validating and not binding on
equip (the table). Still passing: `test_progression_rules_export` (12), `test_architecture` (19),
`test_export_config` (10), `test_item_database` and `test_item_instance` (19) and `test_weapon_swap` (7); in Go,
`internal/progress` and `internal/gamedata` (the file does not change and Go is not touched). The whole Godot suite has not been
run.

**Measured** (this machine, 4 cores, Godot 4.7.2 headless):

| What | Result |
|---|---|
| `test_inventory_properties` | 20 × 1000 in 1.1–1.4 s (per seed, about 190 client requests applied and 430 rejected, with all seven codes; the rest, SWAP, CAMP_REFILL, CONSUME and GM); the long one, 20 × 5000 in 6.0 s |
| `test_inventory_ops` | 20 tests; the slowest, 12 ms (the first, with the database load) |
| `test_currency_rules`, `test_action_machine_weapons` | 6 and 6 tests; the slowest, 49 ms (the 20 random ledgers) |
| Each file | about 10–12 s with the runner startup |

**Not verified:** all of this in the zone and on the client (P5a, P5b and P6).

**Left for later:** the messages (P4); the journal, aggregation, ranged ids and the record (P5a); the
inventory in the zone, real CAMP_REFILL and CONSUME and `set_weapons` after each change (P5b); the client (P6); the
concurrency of balances in the DB (P7).

### 19.8 What platform.md P4 leaves

platform.md P4 (its §19.8) builds the zone side of the ticket and bumps the protocol to 7, with what the
packages here need:

- **P4 (protocol):** `PROTOCOL_VERSION` is already 7 with the whole line from platform.md §5.4 (which also names what is
  here: +9 B of the PLAYER SPAWN, 0x50–0x55, LEVEL_UP, 40–43 and `ItemDatabase` in the `sim_hash`); P4 adds its code
  without bumping it. Bit 3 of the ENTITY_SPAWN header `flags` already belongs to game staff
  (`NetMessages.SPAWN_FLAG_STAFF`) and networking.md has the "v7" legend in §5.2: P4 writes its rows with the mark.
  `progression_rules.json` is re-exported with `protocol_version` 7.
- **P5a:** the claim arrives as `ClaimedCharacter` with `progress: Dictionary` as is (after the round trip
  through JSON: numbers as `float`) in `AuthOutcome.claimed`. `ZoneServer._apply_auth_outcome` leaves step (3),
  between the capacity check and the WELCOME, for `ProgressService.prepare(peer_id, claimed)`, and `ZoneServer._leave_auth_states`
  (the departure in `LOADING`) that of `cancel_prepared(peer_id)`. `ZonePlatform.RECORD_FORMAT` (1) exists. In
  `FakeZonePlatform`, the claim comes from `_claim_answer` (today it returns the `progress` of `add_character`) and what was
  applied is stored in `_remember_save` (today only the `pvp` section): the `progress` part and
  `claim_progress` go there. The first id block comes out as an `id_block` event in the first `take_events()` after
  `startup_finished`, and `request_id_block()` requests the following ones.
- **P5d:** `ZonePlatform.request(kind, method, path, body, priority, context)` sets `zone_instance_id`; the
  responses come out as `progress_op` and `progress_ledger` events (in `ZoneServer._poll_platform`, today with no
  consumer). In the fake, 404 by default, and `script_next(kind, status, body, delay_s)` scripts them.
- **The clock:** `ZonePlatform.now_unix()` (in the fake, `fake_now_unix` if set).

**Not verified:** with the real Go platform (platform.md P10).

### 19.9 P4 · protocol (PRG-11, PRG-13, PRG-14, PRG-16, ART-19)

**What exists.** What §14.1 P4 lists on version 7 bumped by platform.md P4 (without bumping it again: `PROTOCOL_VERSION`
stays at 7 and its line already named all of this):

| Piece | Content |
|---|---|
| `ProgressMessages` (`scripts/shared/net/progress_messages.gd`, new) | The six messages of §4.6 and §12, each with `encode` and `decode`: `InventoryRequest` (0x50, with `from_request(id, InventoryOps.Request)` and `to_request()`; the DESTROY destination travels as `NO_SLOT`), `InventoryDelta` (0x51, with `Entry` and `for_slots(revision, request_id, result, reason, state, slots)`), `InventoryFull` (0x52, with `split(revision, state)` in pages of 30 and `assemble(pages)`), `InventorySyncRequest` (0x53), `WalletUpdate` (0x54, `make`) and `ProgressUpdate` (0x55, `make(curve, level, xp_total, gained, source, realm points, spent)`). Also `enum XpSource` (0 state, 1 PvP, 2 NPC, 3 capture, 4 GM), `MAX_LEVEL` (40), `MAX_ENTRIES` (30), `MAX_PAGES` (8), `NO_SLOT` (0xFF), `MAX_CONTAINER` (3) and `slot_in_range` |
| `NetProtocol` | `MSG_INVENTORY_REQUEST` … `MSG_PROGRESS_UPDATE` (0x50–0x55, in `channel_for_type` with the reliable ones); `DEBUG_ITEM_GIVE`, `DEBUG_CURRENCY_ADD`, `DEBUG_LEVEL_SET` and `DEBUG_XP_ADD` (40–43) in `DEBUG_COMMAND_IDS` (`item_give`, `currency_add`, `level_set`, `xp_add`); `ItemDatabase.shared().wire_hash()` in `compute_sim_hash`; the new REJECT `SIM_HASH` text |
| `NetMessages` | `EntitySpawn.level` and `appearance`: +9 B after the PLAYER's name (`PLAYER_SPAWN_TAIL_SIZE`); the NPC does not change. `EntityEvent.Kind.LEVEL_UP` (16, `u8 level`, 10 B; `level_up()`). `DebugCommand.item_give`, `currency_add`, `level_set` and `xp_add`, their readers (`get_item_net_id`, `get_item_count`, `get_currency`, `get_currency_amount`, `get_level`, `get_xp_amount`) and their validation in `decode` |
| `NetEntity` | `level` (0 by default), `appearance` (empty) and `encode_spawn(tick, for_owner, receiver_realm = NONE)`: the real level only with `for_owner` or with the receiving realm equal to its own |
| `ZoneServer` | The three calls of §7.3: in `_announce_arrival`, the owner's SPAWN, the newcomer's once per receiving realm (three variants at most) and those of the others with the newcomer's realm; in `_refresh_interest`, with the observer's |
| `NetClient` | Signals `inventory_delta_received`, `inventory_full_received`, `wallet_updated` and `progress_updated`; `send_inventory_request(ProgressMessages.InventoryRequest)` and `send_inventory_sync_request()` (in the world only); the own LEVEL_UP is an own event (`is_own_event`); counters in `get_stats` |
| `SwarmBot` | Decodes and discards 0x51, 0x52, 0x54 and 0x55 (`progress_messages_seen`); only what fails to decode counts as malformed (and the C→S ones, which the server never sends) |
| networking.md | §3 (the `sim_hash` with `CombatCatalog` and `ItemDatabase` and the REJECT text), §5.2 (0x50–0x55), §5.4 (40–43) and §5.5 (the PLAYER +9 B, the per-realm split and LEVEL_UP), with the "v7" mark |

**Deviations and implementation decisions:**

- **The types go in `NetProtocol`** (`MSG_*` and `DEBUG_*`, like those of chat) and the formats in `ProgressMessages`; the
  LEVEL_UP and the SPAWN and DEBUG_COMMAND changes cannot come out of `net_messages.gd` (they are its classes).
- **`decode` stricter than the §4.6 list**, so that nothing odd reaches whoever uses it: INVENTORY_REQUEST with
  `request_id` 0, or with destination `0xFF` outside a DESTROY (or a DESTROY with another destination), is null; a slot
  repeated in a delta or in a page, or one that does not exist (container 0–3; equipment, 0–6; bag, below
  `bag_slots` in a page and below 120 in a delta; 2 and 3, below 120), is null; a delta that answers
  a request (`request_id` ≠ 0) carries no reason, and a server one (`request_id` 0) carries OK and an
  `EconomyReason`; WALLET_UPDATE requires an existing currency, balance from 0 to the cap, |delta| up to the cap and reason 0 or
  known; PROGRESS_UPDATE, level from 1 to 40, source from 0 to 4 and `xp_in_level < xp_to_next` (0 at the cap).
  **The SPAWN rejects a level above 40** (§7.3 said `decode` only checks the size: of the appearance,
  yes). Each `encode` gives an empty array if `decode` would not accept it (a failure of whoever builds the message).
- **`MAX_LEVEL` is a protocol constant** (40, the DB `CHECK`): `decode` does not load the curve. The test
  requires it to be `LevelCurve.shared().level_cap`.
- **Without progress, level 0 and appearance 0.** Until P5b nobody sets `NetEntity.level` or `appearance`: every player
  SPAWN comes out with level 0 and 8 B at 0, which the client will take as "no appearance" (the default of the race of
  its realm, P6). Fake players stay this way forever. An `encode_spawn` without a receiving realm (`NONE`) gives level 0:
  this way a call that forgets the realm never leaks the level.
- **DEBUG_COMMAND 40–43 without a handler until P5d**: they are in `DEBUG_COMMAND_IDS`, so the server accepts them without a
  warning and without effect (as happened with 7–16), and `test_combat_server` and `test_hfsm_brain` expect those four in
  `missing_network_commands()` until P5d registers them. Their `decode`: 40, net id ≥ 1 (whether it exists is checked by the
  server) and quantity 1–999 (`MAX_ITEM_GIVE_COUNT`); 41, `Currency.is_valid` and quantity ≠ 0; 42, 1–`MAX_LEVEL`;
  43, 1–10 000 000 (`MAX_XP_ADD`). The factories saturate (`currency_add` to s32, `xp_add` to u32).
- **The server neither sends nor handles 0x50–0x55 yet**: a 0x50 or 0x53 from the client still counts as "unexpected message
  type" until P5b adds `handle_packet`.
- **LEVEL_UP on the client** goes out through `combat_event` like the other ENTITY_EVENTs (no signal of its own): the own one, on
  arrival; an ally's, on its draw tick. It imposes no state (it does not explain corrections).
- **Advances for P5b and P6** (not in §14.2): `InventoryDelta.for_slots`, `InventoryFull.split` and `assemble`,
  `WalletUpdate.make`, `ProgressUpdate.make` and the two `NetClient` sends. `ProgressUpdate.make` clamps an XP
  inconsistent with the level so that the message can be encoded (with I8 it never happens).
- networking.md §3 did not name `CombatCatalog.prediction_hash()` (it enters the `sim_hash` since v6): now it does.

**For the following packages.**

- **P5b:** in `handle_packet`, `ProgressMessages.InventoryRequest.decode` (null → warning) and `to_request()`; the
  reply, `InventoryDelta.for_slots(revision, request_id, outcome.result, 0, state, outcome.changed)`; server-side
  changes, with `request_id` 0 and their reason; `InventoryFull.split(revision, state)` after the owner's SPAWN, after the
  kit and with INVENTORY_SYNC_REQUEST; `NetEntity.level` and `appearance` in `on_arrival`, which has to go before
  `_announce_arrival` in `_process_arrivals` (today, right after `equip_template`). WALLET_UPDATE and PROGRESS_UPDATE with
  `make`.
- **P5c:** `EntityEvent.level_up` to the owner and to those of its realm who have it in relevance, and `NetEntity.level` when leveling up
  (for the following SPAWNs).
- **P5d:** the network handlers for 40–43 with the `DebugCommand` readers, and those four removed from what
  `test_combat_server` and `test_hfsm_brain` expect.
- **P6:** `ClientInventory.on_delta` and `on_full_page` with the `NetClient` signals (and `InventoryFull.assemble` to
  join pages); `send_inventory_request(InventoryRequest.from_request(id, request))`; `EntitySpawn.level` and
  `appearance` for the nameplate and `AppearanceApplier` (`CharacterAppearance.decode` and `validate`; if invalid or 0,
  `default_for` of `race_for_realm`).

**Tests.** In Godot, `test_progress_messages` (18): constants (types, channels, ids 40–43, `MAX_LEVEL` equal to the curve
cap); INVENTORY_REQUEST byte by byte, round trip with `InventoryOps.Request`, DESTROY with `0xFF` and
each field that `decode` does not accept; INVENTORY_DELTA byte by byte (with durability, rarity, seed and affixes, from the test
armors), server-side changes, rejections, headers and broken entries, repeated slots and invalid
items; the largest delta and page (1120 and 1089 B) and entry 31; INVENTORY_FULL with 122 items in 5 pages,
joined in another order, and what does not join (one missing, another revision, repeated, the bank); WALLET_UPDATE and
PROGRESS_UPDATE byte by byte, with `make` and with each range; the PLAYER SPAWN with level and appearance, the cap, the
unvalidated appearance and the unchanged NPC; `encode_spawn` per receiving realm (the owner, its realm, another, none, a
fake); LEVEL_UP; DEBUG_COMMAND 40–43 with their extremes; none exceeds 1200 B; each message truncated, with extra
bytes, with another type and against the other decoders; 6000 random buffers without engine errors; the `sim_hash` changes
with another `ItemDatabase` and returns with the usual one; `ZoneServer` (flat zone without network, hand-assembled peers and a
transport that records what was sent): each receiver gets its realm's variant in `_announce_arrival` and in
`_refresh_interest`; `NetClient` (signals, counters, the own LEVEL_UP immediately and another's queued, broken ones and
C→S ones as malformed) and `SwarmBot` (discard). Verified with the mutation they should catch: without the receiving realm
in the two `ZoneServer` calls and without `ItemDatabase` in the `sim_hash`, they fail. Adjusted to version 7:
`test_net_messages` (+9 B in the SPAWN and 20 ids), `test_net_messages_v3` and `_v6` (the PLAYER SPAWN size),
`test_command_registry` (ids 40–43), `test_combat_server` and `test_hfsm_brain` (the four without a handler until P5d) and
`test_architecture` (`net/progress_messages.gd` among the shared files that must exist). Also still passing:
`test_net_entity`, `test_net_client`, `test_bot_swarm`, `test_party_messages`, `test_loadout_server`,
`test_zone_server_net`, `test_npc_system`, `test_fortress_controller`, `test_ability_server`, `test_combat_wire`,
`test_fortress_net`, `test_projectile_world`, `test_net_loopback`, `test_zone_server_platform`, `test_export_config`,
`test_progression_rules_export`, `test_item_database`, `test_combat_catalog`, `test_combat_events`,
`test_fortress_loopback`, `test_siege_clients`, `test_net_processes` (separate processes, bots with 0 malformed),
`test_server_main`, `test_server_config`, `test_handoff_ticket` and `test_platform_client`; in Go, `internal/gamedata`
and `internal/progress` (Go does not change: `progression_rules.json` stays the same).

**Measured** (this machine, 4 cores, Godot 4.7.2 headless):

| What | Result |
|---|---|
| `test_progress_messages` | 18 tests; the slowest, the fuzz (95 ms), and the `ZoneServer` one, 62 ms; the file, about 12 s with the runner startup |
| Sizes | INVENTORY_DELTA ≤ 1120 B, INVENTORY_FULL ≤ 1089 B, the longest PLAYER SPAWN 179 B (170 up to v6), LEVEL_UP 10 B |
| `test_net_messages` (with `_v3` and `_v6`) | 95 tests, 12 s |

**Not verified:** the messages with the server actually sending them (P5b) and the client using them (P6); the whole
Godot suite has not been run.

**Left for later:** the inventory in the zone and the sending of 0x51–0x55 (P5b), LEVEL_UP and PROGRESS_UPDATE from
rewards (P5c), commands 40–43 (P5d) and the interface (P6).

### 19.10 What platform.md P5 leaves

platform.md P5 (its §19.9) puts `CharacterSaver` in the zone with the API of platform.md §14.3, with no section
registered:

- **P5a:** `ZoneServer.get_saver()` gives the `CharacterSaver` (null without platform). `ProgressService.setup` registers
  `&"progress"` **first**: it is the only one that can return `{}`, and `CharacterSaver` does not undo what another section
  built earlier in that attempt. `build`, `acknowledge` and `is_dirty` receive the `net_id`, and are never
  called after `finish` or `drop`. `track` goes in `_process_arrivals` as soon as the entity exists, before the
  `on_arrival` spot, and a `mark_critical(net_id, &"starter_kit")` done in `on_arrival` goes out in the `step` of that same
  tick (after "registrations"). `on_departure(net_id)` goes in `ZoneServer._remove_player` right after
  `_scores.forget(net_id)`. Through there pass the "Exit", the body withdrawn after a combat exit and the departure
  without save (`_on_save_rejected` and the `revoked` `lease_lost`), whose `finish` no longer does anything after the `drop`. In
  both shutdowns (`stop` and `close_instance`), the `finish` calls are in `ZoneServer._wind_down`, before
  `_clear_players()`. While there is no section, `finish` releases without saving, and with the `progress` one
  registered the final save carries the section. In `FakeZonePlatform`, each save with a 200 `applied` goes through
  `_remember_save`: the `progress` part that the next claim returns goes in there (the first is given by
  `claim_progress`).
- **P5c:** the level-up critical and the capture critical are `mark_critical(net_id, &"level_up")` and
  `&"capture"`. They go out in the `step` of the tick in which they are marked, or as soon as the one in flight gets a reply.
- **P5d:** with the zone fenced (`ZonePlatform.is_fenced()`) `CharacterSaver` keeps sending: rejecting commands that
  ask for a critical save belongs here. A command marks `&"gm"`.
- **Tests:** `tests/support/fake_save_section.gd` (`FakeSaveSection`) is the fake section of platform.md
  (registered as `pvp`); the progress ones use the real one.

**Not verified:** with the real `progress` section. Its `JSON.stringify` is the expensive part of the save (platform.md
§19.9: about 4 ms with 120 items and 256 operations, 89 KB).

### 19.11 P5a · record and section (PRG-10, PRG-11, PRG-12, CMB-30, TEC-25)

**What exists.** What §14.1 P5a lists, in `scripts/server/progress/` except where stated:

| Piece | Content |
|---|---|
| `ProgressRecord` | The fields of §14.2 and §3.4; `new_character`, `to_dictionary` (the save shape, without the read-only fields), `to_claim_dictionary(saved_at_unix)` (the claim's), `from_dictionary` (strict, without engine errors: §3.4 and below), `equals` and `duplicate_record`. `FORMAT` (1) is `ZonePlatform.RECORD_FORMAT` |
| `LedgerEntry` | The fields of §14.2, `RefKind` (0–4 of §5.2), `create`, `to_dictionary` and `from_dictionary` (§9.3, `ref_id` as a string from 0) and `equals` |
| `EconomyOp` | `Kind` (1–6, the numbers of `ProgressionRulesExport.OP_KINDS`), the fields of §14.2 with `save_seq` (does not travel), `create`, `to_dictionary` and `from_dictionary` (§9.3: ids as strings, `null` without actor, reference or note), `KIND_REASONS` (the reasons of each kind, S2), `is_consistent`, `is_empty`, `equals` and `kind_name` |
| `IdAllocator` | The three ranges of §4.5 (`next_for_client`, `next_for_server`, `next_for_build`), `add_block` (ignores with a warning an empty block, one outside 1 … 2^53 − 1 or one that overlaps), `needs_block`, `available`, `local()` and the `running_low` signal |
| `PlayerProgress` | The live record and the journal: `apply_request` (with the DESTROY cap), `begin_op` and `discard_op`, `add_items`, `remove_items` and `change_currency` inside an operation, the aggregates (`gain_currency`, `gain_items`, `lose_items` and `camp_refill`), `grant_starter_kit`, `add_xp`, `charges`, `weapons`, `stash_ready`/`stashed_ready`, `build_section`, `acknowledge`, `is_dirty`, `journal` and the timers in Unix time (`ends_at_unix_for`, `ready_tick_for`). What the body contributes to the snapshot arrives in a `PlayerProgress.Live` from `live_source` |
| `ProgressService` | `setup` (with platform, registers `progress` first and uses the blocks; without it, `IdAllocator.local()`), `start`, `prepare`, `cancel_prepared`, `on_arrival` (binds the progress to the body and gives the kit, below), `has_inventory`, `level_of`, `on_platform_event` (`id_block`; `progress_op` and `progress_ledger` are discarded until P5d) and `on_departure`; the section (`build`, `acknowledge`, `is_dirty` by `net_id`, with no effect on one without progress) |
| `ZoneServer` | `ProgressService` in `start` (before any other section), step (3) of `_apply_auth_outcome` (REJECT `UNAVAILABLE` with "No se ha podido cargar el personaje", alert and release), `cancel_prepared` in the departure in `LOADING`, `on_arrival` after `track`, `on_departure` after `ScoreKeeper.forget` and in `_clear_players`, the `id_block`, `progress_op` and `progress_ledger` events in "poll", `get_progress` and `get_config` |
| `tests/fake_zone_platform.gd` | The `progress` part (platform.md §14.1): `claim_progress(race_id, appearance, starter_template_id)`, `default_progress(realm)`, and in `_remember_save` the applied `progress` without `ops`, with the read-only fields of the previous claim and `location.saved_at_unix`, which the next claim returns |
| `tools/progression/save_fixtures.gd` (`SaveFixtures`), `tools/progression/write_fixtures.gd` and `tests/fixtures/progression/save_cases.json` | The cases of §13.3 (below) and their tool (`-- --check` only compares, like the rules one) |

**The §13.3 cases** (`save_cases.json`, 68 cases, 236 KB: compact, one case per line so the diff is
readable). Keys: `format` (1), `about`, `now_unix` (the clock), `world_id`, `zone_id`, `instance_id` (`claimed_by`),
`id_blocks` (`{instance_id, first, count, granted_at_unix}`: one of the instance, 1025–2048, and another of a different one, 3073–4096),
`accounts` (`{account_id, role}`: `player` 7 and 9, `gm` 77, `admin` 78), `characters` (`{character_id, account_id, realm,
race_id, appearance, starter_template_id}`: 40 the admin's, 41 the GM's, 42 and 43 and 49 the players') and `cases`, each
`{name, rule, steps: [{character_id, progress, expect}]}`. **Each case, in a fresh database** with everything above
created (the characters with `Create`); each step is an `Apply` of its `progress` with `SaveKey{world_id, character_id,
instance_id, zone_id}` in its own transaction, and `expect` is `applied` (it is committed) or the `check` of the
`*persistence.InvalidSaveError` or of the database error (`S8`), and then it is rolled back. The valid ones come from
`PlayerProgress`: the kit (STARTER_KIT), some play time (GAMEPLAY with CONSUME, CAMP_REFILL, gold from a Hollow with its
fingerprint and merits from a kill, PLAYER from a DESTROY and a GM of +50 gold), moving, equipping, splitting and merging without
events, expired timers and ones at exactly 7 days, a REVERSAL, a console GM, lowering XP with a GM
(`level_set`) and an admin on their own character. Each invalid one changes a single thing from a valid one so that exactly
the check it names fails: S1 (9: format, unknown key, three read-only ones, a uid as a number, an id of
2^53, an integer that is not one and another zone), S2 (17: op_id outside the blocks and from another instance, MIGRATION, a reason
of another kind, GM without a note, by a `player`, with another account's character, from the future, older than its block and without
`at_unix`, console with a character, op_id already saved, a second STARTER_KIT, a `gm` on their own character, two
REVERSALs in two saves and in one, and one of a REVERSAL), S3 (5), S4 (4), S5 (15, among them **two uids swapping
def_id with balanced totals**), S6 (7), S7 (3) and S8 (another character's kit with the same new uids
and another op_id). `test_progression_fixtures` repeats S3 and S4 as a reference: the valid ones satisfy them, those of S3
fail S3, those of S4 pass S3 and fail S4 and the rest pass both.

**Deviations and implementation decisions:**

- **P5a's registration binds the progress and gives the kit; the rest of registration belongs to P5b.** `on_arrival` binds the prepared `PlayerProgress`
  to the `net_id`, takes the body's snapshot as the confirmed one and, with `starter_granted` false, gives the kit of
  `starter_template_id` in a STARTER_KIT and marks `&"starter_kit"` (it goes out in that tick's `step`, §19.10). It returns
  null: the return-to-world rule, the timers, `NetEntity.level` and `appearance` and the `Loadout` belong to P5b,
  so until then the `CombatState` comes from the template (LOADOUT_SELECT or the default) even if the equipment
  is the kit of the one chosen at creation. The saved active slot is bit0 of `combat_flags2` with the rule of §8 (the
  other if that one is empty), so I10 holds anyway. **Without platform, P5a does nothing in the zone**: ephemerals
  (§9.4) belong to P5b; `ProgressService` exists with `IdAllocator.local()` and `on_arrival` creates nothing without a `prepare`.
  The kit goes here because without it a new character's first save would not satisfy I10 (S5) and because §19.10
  puts it in this package's registration.
- **`add_character` with empty `progress`** (`{}`) is a newly created character of its realm (`default_progress`: the
  realm's people, its default appearance and the first selectable template by id, today `marksman`), like the one
  `Load` returns: this way the ~30 calls in platform.md's tests remain valid. A broken record is passed
  as is (non-empty).
- **`is_dirty`.** Entering does not dirty: the registration snapshot is the confirmed one. These count: an operation with `save_seq` 0 or something
  aggregated, level, XP, realm points, currencies, `starter_granted`, `bag_slots`, the active slot (with the I10 rule),
  the inventory revision, the timers, health and moving **0.1 m or more** (or changing zone or channel). **Play
  time alone does not dirty** (otherwise every player would always be dirty): it goes with the next save. It is compared
  with the snapshot of the last confirmed save, not with that of the one built in flight.
- **`played_seconds`** = the loaded value plus the ticks since registration / 60, rounded down (`played_base`: it is not
  added to the previous snapshot).
- **Timers.** In P5a those of the record pass as they are; the snapshot drops the expired ones (with the platform's `now_unix`). `ends_at_unix_for` and `ready_tick_for` are the rule of §8 (`ceili`, integer); `unstuck` (P5b) and
  `capture:<id>` (P5c) write them into `record.timers`.
- **The journal.** `begin_op` puts the operation in the journal when opening it; what is added afterwards goes with it and
  `discard_op` removes the last one if it ended up empty (the "all or nothing" of §10: its id is lost). An operation that has already gone out in a
  body does not change (`add_items`, `remove_items` and `change_currency` give false). **`balance_after` comes from the recorded
  balance** (the DB's after the journal), not from the in-memory balance: an aggregated gain between opening a GM operation and recording it
  is closed in a GAMEPLAY behind it and S3 still balances; `change_currency` looks at both balances.
- **DESTROY** closes the aggregates after `InventoryOps.apply` (a rejected request spends no ids, §19.7) but the
  GAMEPLAY goes before the PLAYER in the journal. The PLAYER `op_id` (from the clients' range) may be lower than
  that GAMEPLAY's: ids are not in journal order and S1–S8 do not require it. **The cap of 256 unconfirmed only
  applies with platform**; without it the journal keeps the last 256 and is never confirmed, so the cap would give NOT_NOW
  forever.
- **The appearance in `prepare`.** One that is not valid is replaced by `default_for` of its race; if the race does not belong to the character's
  realm, by that of its realm's people (and `race_id` changes in memory: it is read-only, it is not saved); if the
  realm has no people, it stays as is with an alert. `prepare` only fails if the record cannot be read.
- **`from_dictionary` stricter than §3.4:** equipment only admits weapons in slots 0 and 1 (the active one holding a weapon is not
  required: a new character has none); the bag slot, below `bag_slots`; `health` up to the
  maximum health; `race_id`, `starter_template_id` (may be empty) and `location.zone_id` with the format `[a-z0-9_]{1,64}`;
  the appearance in canonical 12-character base64 (checked before calling `Marshalls`, which would log an engine
  error); at most 16 timers; `location.saved_at_unix` mandatory in the claim; a missing currency
  is 0. The patterns are compiled once (`static var`).
- **Ids.** `start(s)` gives the first block on request (requested by the `ZonePlatform` startup and arriving as an event in the
  first "poll"); afterwards, `running_low` requests another with at most one in flight. A block that is rejected or invalid is
  logged as an alert and requested again with the next id that is taken.
- **platform.md tests adjusted** (their behavior changes with the `progress` section, as its §19.9 announced):
  `test_zone_server_saves` counts saves from after the kit; in `test_zone_server_platform`, the body that
  leaves after a `revoked` that is not `lease_lost` is released with its final save (`release_lease`), not with a separate release;
  `test_zone_process_shutdown` claims with `default_progress`, counts the finals with `release_lease` as the
  release of whoever was in the world and answers saves with the same delay as the
  releases.
- **The case labels** are the reading of §13.3 from here: S4 and S5 look at this character's uids, so a new
  uid that already belongs to another character comes out through the primary key (`S8`); a negative balance is S3 (through its
  `balance_after`); an active slot without a weapon is S5 (I10). P7 can correct the file with the tool if its reading
  is different, and then note it here.
- `ProgressService.get_stats()` counts prepared, rejected, replaced appearances, registrations, kits, blocks and unbuilt
  saves; it does not yet go to the zone report.

**For the following packages.**

- **P5b:** `on_arrival` returns the `Loadout` (`weapons()`, the record's active slot, `charges()`) and applies the
  return-to-world rule, health (`record.health` and `location.saved_at_unix`), `unstuck` with `ready_tick_for` and `NetEntity.level`
  and `appearance`; creates the ephemerals (`ProgressRecord.new_character()` with the realm's people, `default_for` and the template
  from `pending_template_id`, `persistent` false, local `get_ids()`) and calls `confirm_current()` like the registration here;
  `apply_pending` with `PlayerProgress.apply_request` (filling the active slot, `can_touch_equipment` and `drinking` from the
  `CombatState`); `camp_step` with `camp_refill()` (`bag_full` → the NOTICE); CONSUME with
  `lose_items(def, 1, CONSUME)`; `revision` for the deltas.
- **P5c:** `gain_currency` with `LedgerEntry.RefKind`, `add_xp` (with `pending_xp_gain` and `pending_xp_source` for
  PROGRESS_UPDATE), `mark_critical` of `&"level_up"` and `&"capture"`, `capture:<id>` in `record.timers` with
  `ends_at_unix_for`.
- **P5d:** `begin_op`, `discard_op`, `add_items`, `remove_items` and `change_currency`; the REVERSAL sets `ref_op_id` and
  lowers realm points by hand (I9); `progress_op` and `progress_ledger` already reach `on_platform_event` (today they are
  discarded); `journal()` without platform.
- **P7:** `save_cases.json` with the format above (each case in a fresh database); the labels are from here.
- **platform.md P6:** `pvp` is registered behind `progress` (the first one is already there).

**Tests.** In Godot: `test_progress_record` (9: the format equal to `RECORD_FORMAT`, `new_character`, the round trip
through `to_claim_dictionary`, `JSON.stringify`, `parse_string` and `from_dictionary` field by field with and without position, the
§3.4 example as is, `to_dictionary` without the read-only fields, ids as strings with 11 invalid cases, integers
as `820.0`, and null without each key and with 49 breakages, one per rule); `test_player_progress` (15: the operation
kinds of the exported rules, `EconomyOp` and `LedgerEntry` in JSON with 13 breakages, the ranges and blocks of
`IdAllocator`, the kit by template, by default and without ids, aggregation, the closing before a standalone operation with
S3, the section and its confirmation, a body in flight, the three ranges (CAMP_REFILL without a new stack, `build_section` still
closing and `{}` without touching anything), DESTROY with 256 unconfirmed (and no cap for an ephemeral), aggregates before the
PLAYER, no 30 s cooldown, `ends_at_unix_for` and `is_dirty`, and stashed charges, weapons and cooldowns);
`test_progress_section` (9, with ENet and `FakeZonePlatform`: the section first and the critical kit on registration, the
retry with the same body and `duplicate`, `lease_lost` from the heartbeat and from a save, `invalid_save` with the hooks having no
effect afterwards, `is_dirty` on moving and on losing health, the broken record, the departure in LOADING, the next claim and the
final save after one in flight); `test_progression_fixtures` (4). Verified with the mutation they should catch: without
`cancel_prepared` in the departure in LOADING and with `build_section` repeating already sent operations, they fail. Still
passing `test_zone_server_saves` (10), `test_zone_server_platform` (13), `test_zone_process_shutdown` (5) (the three
adjusted, above), `test_handoff_ticket` (15), `test_character_saver` (14), `test_platform_client` (14),
`test_server_main` (15), `test_progress_messages` (18), `test_zone_server_net` (45), `test_net_loopback` (14),
`test_bot_swarm` (8), `test_architecture` (19), `test_export_config` (10) and `test_progression_rules_export` (12). The whole
Godot suite has not been run; Go does not change.

**Measured** (this machine, 4 cores, Godot 4.7.2 headless):

| What | Result |
|---|---|
| `build_section` of the largest character (120 items and 256 operations with one entry each) | 2.2–2.7 ms; its `JSON.stringify`, 4.1–4.6 ms (88 KB), as platform.md §19.9 measured with the fake section |
| `from_dictionary` of the 120-item claim (in `prepare`, once per entry) | 1.8–2.9 ms |
| `is_dirty` with 256 operations in the journal | 29–31 µs (`CharacterSaver` calls it in each character's phase) |
| `test_progress_record`, `test_player_progress`, `test_progress_section`, `test_progression_fixtures` | 12, 10, 16 and 13 s with the runner startup; the slowest, the final save after one in flight (0.8 s) |

**Not verified:** against the real Go platform (P7 and P10) and the cases with the Go store (P7); the
inventory over the network and the ephemerals (P5b).

**Left for later:** the rest of registration, the ephemerals, the inventory over the network, CONSUME, CAMP_REFILL and the charges
(P5b); rewards (P5c); GM commands and the reversal (P5d); the Go store with these cases (P7).

### 19.12 P5b · inventory in the zone (PRG-11, PRG-08, CMB-30, MUN-41)

**What exists.** What §14.1 P5b lists, in `scripts/server/` except where stated:

| Piece | Content |
|---|---|
| `ProgressService` (`progress/progress_service.gd`) | **Registration**: `on_arrival` binds the prepared one or, without platform, creates the ephemeral (§9.4: the realm's people with their default appearance and the kit of the LOADOUT_SELECT template or the default one), applies the return-to-world rule (spot and health), restores `unstuck`, takes the confirmed snapshot, gives the kit, sets `NetEntity.level` and `appearance` and returns the `Loadout`; `after_spawn` (INVENTORY_FULL, one WALLET_UPDATE per currency and one PROGRESS_UPDATE); `loadout_for` (respawn). **Network**: `handle_packet` (0x50 and 0x53: outside the world, malformed and RATE on arrival, with their warnings) and `apply_pending` (the queue in arrival order, the `CombatState` `Context`, the INVENTORY_DELTA, the imposed weapons and charges and one log line per applied request). **Server**: `before_simulate` and `after_simulate` (CONSUME), `camp_step` (CAMP_REFILL and "Bolsa llena"), `force_refill` (16 without platform) and `flush` (batched WALLET_UPDATE and PROGRESS_UPDATE). Also `set_timer`, `character_id_of`, `pending_count` and the sinks `send_sink`, `strike_sink` and `notice_sink` |
| `PlayerProgress` | `take_items` (`lose_items` with its `Outcome`: the slots of the CONSUME delta), `saved_active_slot` (the record's active slot with the I10 rule) and `last_currency_reasons` (the WALLET_UPDATE reason) |
| `CombatDirector` | `equip_inventory` (registration: `set_loadout` and, with slot 2 active, `set_weapons` without cooldowns; current template 0); `loadout_source` (the respawn of anyone with an inventory: their equipment and charges, without looking at templates or the peer's pending one) and `camp_step` (the step 8 refill: CAMP_REFILL instead of the template's, with the same conditions and cadence) |
| `ZoneServer` | The tick order (below); registration with the `Loadout` instead of the template and `after_spawn` after the SPAWN; 0x50 and 0x53 in `_on_packet_received`; LOADOUT_SELECT that changes nothing for anyone with an inventory; command 16 and the console `refill`; the /atascado key (`unstuck_key_of`: `character:<id>` with platform) and its timer on completion; `place_returning` (the rule for SAFE zones) |
| `UnstuckTracker` | `get_ready_at` and `set_ready_at` of §14.2 |
| `tests/test_progress_service.gd` | The nine P5b tests of §15 (below), without network: hand-assembled peers like the real registration, their inputs in their `InputQueue` and a transport that records what was sent; the ones that save, with `FakeZonePlatform` |

**The tick** (header of `zone_server.gd`): in "poll", INVENTORY_REQUEST and INVENTORY_SYNC_REQUEST (RATE and to the queue);
before step 1, `before_simulate`, and right after, `after_simulate` (CONSUME); in step 8, the refill calls
`camp_step` for anyone with an inventory; after the registrations, `apply_pending` and `flush`, and then `CharacterSaver.step`
(the save snapshot already carries the tick's requests).

**Deviations and implementation decisions:**

- **Without platform, every peer is ephemeral with an inventory** (§9.4), so abilities.md H3c's treatment of peers
  changes: LOADOUT carries template 0, the template chosen before CLIENT_READY is only the kit, LOADOUT_SELECT in the
  world changes nothing (a nonexistent id still adds its warning), respawn is with the equipment and the charges are the
  potions in the bag (3 and 2 for everyone: the marksman had 2 and 3 in their template). Fakes keep the template.
  Tests adjusted: `test_loadout_server` (registration with the marksman kit and respawn with the same equipment),
  `test_consumables_server` (template 0 in the bot's LOADOUT), `test_loadout_net` (Bruno equips the bow from his
  bag into WEAPON_2 with an INVENTORY_REQUEST instead of choosing the marksman in the world; the six switches with Q
  return to the sword) and `test_bot_cheat` (the second cheater has the excess potions removed from the bag to
  leave 1 and 0).
- **CONSUME with the charges from before step 1** (`before_simulate`, not in §14.2): during step 1 only the
  drink commit lowers a charge, so comparing with the earlier values is exact; following "the last imposed ones" would
  break with any path that imposes them and forgets to record it.
- **RATE replies on arrival**, in "poll", with its INVENTORY_DELTA (`result` 8 and the real contents of the slots),
  without going through the queue: it may go out before the reply to an earlier request in the same tick, but it does not raise the
  revision and the client applies the entries in arrival order. A request asks for a token from both buckets (the SPLIT and DESTROY one
  only if it is one) and spends none if one is lacking. Drops warn with the chat window
  (`ChatPeerState.FloodWindow`: the first ten of every 600 ticks are free). The buckets do not receive the stall credit from
  networking.md §12.
- **Warnings**: outside the world, malformed, INVALID and a sync before 5 s (which is not answered). The sync
  goes to the queue with the requests: its INVENTORY_FULL carries what the tick's earlier ones leave.
- **Only DESTROY imposes charges** among the requests (moving, splitting and merging do not change the quantity, I4); also
  CONSUME, CAMP_REFILL and 16. The LOADOUT to the owner goes out only if the charges change, except 16, which sends it
  always (like the template).
- **Cooldowns when changing weapons**: the `CombatState` ones are saved per weapon (those of its slot before the
  change, not the inventory's), so a weapon set with command 5 also keeps its own. The active slot
  stays the same; if it were left without a weapon (requests cannot: WEAPON_REQUIRED), the other one.
- **"Bolsa llena" once per entry**: an entry is a `camp_step` whose previous one for that player was not the
  refill 60 ticks earlier (leaving the safe zone, entering combat or dying in between count as leaving).
- **Command 16 and the console `refill` with platform are rejected** until P5d, where they are a GM operation; without
  platform they are a forced CAMP_REFILL (aggregated) and require being alive, as before.
- **The `unstuck` timer is written on completion** of /atascado (`set_timer` with `get_ready_at`), not when building
  the save: its end stays fixed and `is_dirty` does not change with the clock. On entry, expired ones leave the record
  before the confirmed snapshot (entering does not dirty) and the current one is restored with `set_ready_at`. Ephemerals have no
  timers (no clock), but their cooldown continues through their name's key, as before.
- **The registration order**: return to world, timers, confirmed snapshot and, afterwards, the kit (which does dirty and is
  critical). The SAFE zone rule is done (`place_returning` checks that the spot is finite, within
  bounds and with ground), but in phase 5 all zones are RVR: there the player is already at their realm's spawn point.
- **`flush` is done** (it is from §14.2 and nobody had it assigned): WALLET_UPDATE with the delta summed since the last one and the
  reason of the last change, and PROGRESS_UPDATE if there is pending XP or level, XP or realm points changed, one every
  10 ticks per player at most (staggered by `net_id`). In P5b nothing moves balances or XP: only those of registration go out.
- **The log** leaves one line per applied request (`Inventario: net_id N (personaje C | efímero) OP c:s -> c:s
  ×n uid U (nuevo X): OK`); rejected ones only count in `get_stats()` (`rejected`, `rate_limited`), so that a
  client cannot fill the log.
- **Cost per tick**: each session stores its `Combatant` (the same from registration to departure) and the steps of each tick
  walk a list of sessions, not `Dictionary.values()` (below, measured).

**For the following packages.**

- **P5c:** `gain_currency` and `add_xp` already reach the client through `flush` (with `last_currency_reasons` and
  `pending_xp_gain`/`pending_xp_source`); LEVEL_UP, `NetEntity.level` when leveling up and the critical, separately. The capture
  reward uses `set_timer(net_id, "capture:<id>", ready_tick, s)` or writes its end directly.
- **P5d:** 16 with platform (today `force_refill` returns false with platform) and the deltas of GM changes
  (`_send_server_delta` with the reason; the charges, with `_impose_charges`, and the weapons, with `_impose_weapons` if the
  change touches equipment).
- **P6:** the replies, rejections with their real contents, RATE ("Más despacio") and the FULL pages already arrive
  for real.
- **P8:** `test_progress_loopback` and `test_progress_platform_loopback` on top of this.

**Tests.** In Godot, `test_progress_service` (9): the registration of the ephemeral marksman (equipment, `Loadout`, template 0,
charges, level, appearance, SPAWN and then FULL, currencies and progress; LOADOUT_SELECT without effect and respawn with their
equipment) and that of a record with slot 1 active and 400 health (and at camp, not where it was saved); equipping and
unequipping without resetting cooldowns, swapping the weapons, WEAPON_REQUIRED and NOT_NOW with the real contents, two
requests in the same tick in order and INVALID with a warning; CONSUME on the commit tick and not on interruption, and the
charge returning to 15 with more than 15 in the bag; CAMP_REFILL by total (splitting gives no more) in the refill every 60
ticks, the fake with its template and "Bolsa llena" once per entry; warnings outside the world, malformed, a run of
syncs and RATE (16 queued, the rest RATE immediately and warnings after the first ten drops); 10 000 SPLITs and
merges without any event, with the abuser out through the warnings, ids bounded, the other one drinking and saving, and another who
splits at 3 per second without warnings and does not exceed RATE's 2 ids per second; /atascado restored through
`character:<id>` (with the offline time, and expired, out); the saved health with the offline-time regeneration and the dead character who
returns to camp with full health; and the squire who puts the bow in WEAPON_2, switches to
it, unequips WEAPON_1, dies and respawns with the bow active, saves a snapshot that passes S5 (`_s5_errors`, the part of
S5 that can be checked without a database) and returns with the same. Verified with the mutation they should catch: without `after_simulate`,
without saving the cooldowns of the weapon being removed, without the empty-WEAPON_1 rule on respawn, without re-warning
about the full bag, without the timer on completing /atascado, without the RATE warnings and without the id
bucket, they fail.

Tests of other packages adjusted (peer behavior changes, above): `test_loadout_server`,
`test_consumables_server`, `test_loadout_net`, `test_bot_cheat` (the second `potion` cheater) and
`test_projectile_loopback` (the archer appears with the marksman kit: template 0 and the bow in slot 0 of their
equipment). Also still passing: `test_player_progress` (15), `test_progress_section` (9), `test_progress_record`,
`test_progression_fixtures`, `test_progression_rules_export`, `test_inventory_ops`, `test_character_saver`,
`test_progress_messages`, `test_zone_server_saves`, `test_zone_server_platform`, `test_zone_process_shutdown`,
`test_zone_server`, `test_zone_server_net`, `test_net_loopback`, `test_net_client`, `test_net_harness`,
`test_net_messages` (with `_v3` and `_v6`), `test_net_processes` (separate processes, bots with 0 malformed),
`test_bot_swarm` (0 malformed), `test_combat_server`, `test_combat_director`, `test_combat_events`,
`test_combat_loopback`, `test_combat_processes`, `test_combat_reconciliation`, `test_combat_resolver`,
`test_combat_animation`, `test_combat_balance`, `test_combat_demo`, `test_combatant`, `test_abilities_reconciliation`,
`test_ability_server`, `test_status_effects`, `test_downed`, `test_projectiles`, `test_hud_combat`,
`test_command_registry`, `test_hfsm_brain`, `test_npc_brain`, `test_fortress_controller`, `test_fortress_loopback`,
`test_fortress_net`, `test_fortress_processes`, `test_fortress_server`, `test_gate_target`, `test_siege_clients`,
`test_chat_loopback`, `test_chat_router`, `test_party_demo`, `test_party_loopback`, `test_party_manager`,
`test_platform_client`, `test_server_main`, `test_online_main`, `test_local_server_launcher`, `test_realm_select`,
`test_snapshot_builder`, `test_state_logs`, `test_net_debug_overlay`, `test_rate_limiter`, `test_unstuck_tracker`,
`test_architecture` and `test_export_config`. The whole Godot suite has not been run; Go does not change.

**Measured** (this machine, 4 shared cores, Godot 4.7.2 headless; a probe that is not committed, with 64 ephemeral
players in the flat zone):

| What | Result |
|---|---|
| `before_simulate` + `after_simulate` (CONSUME) per tick | 107–112 µs with 64 (358 µs before storing the `Combatant` in the session and the session list) |
| `flush` per tick | 21–22 µs with 64 (with nothing to send) |
| One request in `apply_pending` | 56–60 µs (64 MOVEs in 3.6–3.9 ms): `InventoryOps.apply` 13 µs, the delta 13–14 µs, the log line 1.5 µs; with the cap of 8 per second per player, about 0.5 ms per tick with 64 who never stop |
| `camp_step` | 23 µs per player with nothing to refill (every 60 ticks and only at camp) and 70–76 µs refilling (with its delta, its charges and the LOADOUT, which walks the players in the world) |
| `test_progress_service` | 9 tests, about 20 s with the runner startup; the slowest, the 10 000 SPLIT one (3.4 s, with the second abuser's 30 s of play) |

**Not verified:** the SAFE zone rule with a real SAFE zone (there is none in phase 5); against the real Go
platform (P7 and P10); the client that uses the messages (P6, in `wip/fase5-cliente`).

**Left for later:** rewards, LEVEL_UP and whatever moves balances and XP (P5c); GM commands with their
deltas, 16 with platform and the reversal (P5d); the Go store (P7); end-to-end tests (P8).

### 19.13 What platform.md P6 leaves

platform.md P6 (its §19.11) puts the persistent war in the zone. What P5c uses:

- **The capture list:** `FortressController.fortress_captured(fortress_id, owner_realm, in_circle, tick)` goes out on
  every real capture with the platform.md §8 list (of the capturing realm, present, alive and connected in the
  circle on the capture tick, without `NetEntity.gm_forced`), sorted by `net_id`; it is the same one that
  `ScoreKeeper.captures` has already added. A forced capture does not go out. `ProgressService.on_capture` connects there (invisible
  GMs are removed from the candidates by platform.md P7b).
- **The forced-change mark (§6.2):** `FortressController.is_forced(fortress_id)`. It is set by `fort_owner`,
  `fort_reset`, `fort_kill_captain` (before killing the captain: its DEATH already comes out forced, so `on_npc_killed`
  can look at it at that moment) and `fort_capture_speed` with a factor other than 1 (and everything is forced while
  `capture_rate_multiplier ≠ 1`). It is cleared by the captain's death in combat, the garrison arriving on its own and the
  periodic reset. The capture that follows a `fort_kill_captain` and the consolidation that follows a forced capture
  are also forced.
- **`NetEntity.gm_forced`** exists (false by default) and respawn clears it; it is set by platform.md P7b.
  `on_merits` and `on_npc_killed` check it on each player.
- **The capture critical** (`mark_critical(net_id, &"capture")`) goes out like any other: the save already carries
  both sections, `progress` and `pvp` (with `captures` up to date).

**Not verified:** with the real Go platform (platform.md P10).

### 19.14 P5c · rewards (PRG-09, PRG-12, PRG-13, GUE-12, MUN-07)

**What exists.** What §14.1 P5c lists, in `scripts/server/` except where stated:

| Piece | Content |
|---|---|
| `ProgressService` (`progress/progress_service.gd`) | `on_merits` (PvP only with a persistent victim of another realm, entry with `ref_kind` 1 and the victim's `character_id`; OBJECTIVE without a victim), `on_objective_ticks` (the objective merits, with the fort as reference), `on_npc_killed` (to each contributor, `xp_reward` and `gold_reward` with NPC_KILL, `ref_kind` 2 and the id's fingerprint), `on_capture` (300 XP and 20 gold with OBJECTIVE and `ref_kind` 3, once per character and fort every 30 min with the `capture:<fortress_id>` timer, and the `capture` critical), `rewards_blocked` and the `--fake-players` rule. All XP goes through `PlayerProgress.add_xp`: leveling up sets `NetEntity.level`, sends the LEVEL_UP through `level_up_sink` and marks the `level_up` critical; what is earned reaches the owner through `flush` (WALLET_UPDATE and PROGRESS_UPDATE, from P5b) |
| `ZoneServer` | In `_track_battle`, an NPC's death (in its DEATH, `_reward_npc_death`) and the PvP merits of a player's KILL (`_reward_kill`); `_announce_level_up` (to the owner and to those of their realm who have it in relevance); `fortress_captured` and `objective_time` connected to `on_capture` and `on_objective_ticks` |
| `FortressController` | The signal `objective_time(fortress_id, net_id, ticks, tick)` on each count with the circle active, in a real cycle and without `gm_forced`, and `fortress_of_defender(net_id)` |
| `DamageLedger` | `contributors(tick)`: those who dealt at least 10 % of the window's damage, by id |
| `NpcDefinition` and `data/npcs/` (shared) | `xp_reward` and `gold_reward` (group "Recompensas", 0 by default) with the values of §6.2: `hollow` 40 and 2, `realm_guard` 60 and 3, `ford_captain` and `realm_captain` 400 and 50, `gate_guardian` 0 and 0; `NpcCatalog` errors on a negative one |
| `tests/test_progress_rewards.gd` | The P5c tests of §15 (below) |

**Deviations and implementation decisions:**

- **The merits are the scoreboard's provisional ones** (PRG-09 is not done): 10 per kill and 5 per assist
  (`ScoreKeeper.MERITS_PER_KILL` and `MERITS_PER_ASSIST`) and one per whole second in the active circle, with no distribution by
  damage or anti-farming; damage to the gate gives no merits, as on the scoreboard (fortress.md). Two players of different
  realms can farm kills off each other until PRG-09; in phase 5 merits are not spent and level does not change the sheet.
  With these values, being in the active circle gives 10 XP per second, much more than kills: it is reviewed with PRG-09 and
  telemetry (provisional figure, like all those in §6.2).
- **`on_objective_ticks` (not in §14.2):** objective merits do not go through `on_merits` because they carry the
  fort as the reference (`ref_kind` 3), not a victim. They are given by the `objective_time` signal of `FortressController`
  (6 ticks per count); every 60 accumulated ticks is one merit, and what does not reach a second is lost on leaving.
  `on_merits` with OBJECTIVE and without a victim remains valid (with `ref_kind` 0) for whoever needs it.
- **XP source** in PROGRESS_UPDATE: PVP for kills and assists, NPC for NPCs and CAPTURE for the capture and
  objective merits.
- **The NPC is paid on its DEATH, not on the KILL.** The DEATH reaches the zone before `FortressController` (the zone
  connects to `CombatDirector.event_emitted` first), so the defender is still registered (`fortress_of_defender`) and
  the forced-change mark is that of its death, the one `fort_kill_captain` sets before killing (platform.md P6).
  Contributors come from the victim's damage log (`contributors`), so a death by the
  environment with player damage in the window also pays, and the author of the killing blow only collects if they reach 10 %.
- **A defender of a fort in a forced cycle does not pay**: the Hollow, the guards and the captain, also those
  placed by `fort_owner` until the cycle stops being forced, and the captain killed in combat in that cycle (its DEATH
  still sees the mark, which that same death clears afterwards). An NPC that defends no fort always pays.
- **Forced changes do not pay without platform either**, just as platform.md P6 does not add captures or
  `defend_ticks` from a forced cycle (the forced capture does not emit `fortress_captured`): an ephemeral does not collect a forced
  cycle. §6.2 says "without platform, as today"; this way there is one rule and nothing persistent changes.
- **`--fake-players` is checked in `setup`** with the option (`ServerConfig.fake_players > 0`) and the platform, and is recorded
  in the log (`FAKE_PLAYERS_TEXT`). A fake that a test creates with `add_fake_player` blocks nothing (it is not
  `--fake-players`), and filler fakes do not exist with platform (`ServerMain` does not apply `--max-realm-diff`). Fakes
  never collect (they have no `PlayerProgress`) nor give merits when they die (they are not persistent).
- **Invisible GMs do not exist yet** (platform.md P7b), so their test ("an invisible GM in the circle does not
  collect the capture") is left for P7b: the invisible one will not be among the circle candidates (no capture or objective
  merits) nor deal damage (no contribution or PvP merits). `/gm teleport` and `/gm visible` are simulated by setting
  `gm_forced`, which is what they will do; each reward checks it in `_collector`, the place to also check the invisible
  if it were ever needed.
- **The capture timer** lives per session in ticks (`capture_ready`), so it also applies to
  ephemerals; with platform, it is also written to `record.timers` (`set_timer`) and comes back on entry with
  `ready_tick_for` (expired ones were already removed by registration). It is per fort. Only collecting is critical: whoever is waiting
  carries their `captures` of the `pvp` section at the next checkpoint.
- **LEVEL_UP**: one per contribution with the final level (a contribution can raise several), on the contribution's tick, over the reliable
  channel; the owner always receives it and those of their realm if they have it in relevance. It is counted in the report's
  ENTITY_EVENTs.
- **The body that stays** after a combat exit (GUE-41) keeps collecting what is due (it has
  `PlayerProgress` until its departure), although it cannot capture (it is not connected).

**For the following packages.**
- **platform.md P7b:** invisible GMs outside `_presence_candidates` and dealing no damage, and `gm_forced` with
  `/gm teleport`, `/gm visible` and DEBUG_COMMAND 1, 2 and 4: rewards already check `gm_forced` on each player, and
  the invisible-in-the-circle test can go in `test_progress_rewards` (its `_capture` already sets up the capture).
- **P5d:** `xp_add` and `level_set` level up as here (`NetEntity.level`, `level_up_sink` with the GM source and the
  critical; `_grant_xp` is private: either reuse it or repeat it with the GM operation).
- **PRG-09:** the damage distribution and anti-farming change what the zone passes to `on_merits` (today, in `_reward_kill`) and
  to `on_objective_ticks`; the filters here do not change.
- **P8:** `test_progress_loopback` and the `progress` bot can read the rewards through WALLET_UPDATE and PROGRESS_UPDATE.

**Tests.** In Godot, `test_progress_rewards` (9, without network: the flat zone with the test fort, hand-assembled peers
with their `FakeZonePlatform` claim and deaths provoked with the damage log already written): the
values of §6.2 in `data/npcs/` and `contributors` (≥ 10 %, by id, only the window); the kill of a persistent
victim of another realm (10 merits, 10 realm points and 100 XP to the killer, 5 and 50 to the assistant, no gold), its
WALLET_UPDATE and PROGRESS_UPDATE, the fake and the NPC that give no merits and the save's GAMEPLAY entries
with their references (victim `102` and the fingerprint of `hollow`); the NPC with two contributors who collect in full, the one with
less than 10 % who does not, and the one who dies from the environment; ephemerals without platform (the NPC in memory, PvP nothing);
two captures within 30 min that pay once, objective merits equal to the whole seconds in the active circle, the
`capture:<id>` timer that returns on leaving and re-entering at 10 min and the expired one that does not return at 30, and the
capture of another realm or another fort; the one marked with `gm_forced` who collects no capture, objective merits,
kill or NPC reward (and the other contributor does) and, after respawning, collects all three; the captain killed in combat who
pays 400 and 50, the `fort_kill_captain` one with the player's damage who does not pay, and the captures after
`fort_kill_captain` and with `fort_capture_speed 20` and `fort_owner` collecting nothing; `--fake-players` with platform
(nothing, the startup log and the scoreboard that does count); and the level-up (400 + 300 XP: level 2 in the
record and the entity, a LEVEL_UP to the owner and the ally and none to the enemy, the `level_up` critical with its
level 2 save, the PROGRESS_UPDATE and the SPAWN with the level only toward its realm). Verified with the mutation they
should catch: without checking `gm_forced`, without requiring a persistent victim, without skipping the NPC of a forced cycle, without
the capture wait, without restoring its timer, without checking the capturing realm, without filtering the LEVEL_UP realm,
without the `--fake-players` block, with objective merits in a forced cycle, without the level-up critical and without
`NetEntity.level`, they fail.

Adjusted: `test_progress_section` (the first: since platform.md P6, `start` also registers the real `pvp` section
behind `progress`, and the test expected only `progress`; it was already failing before P5c). Also still passing:
`test_progress_service` (9), `test_war_persistence` (15), `test_war_platform_process`, `test_fortress_*`
(151), `test_npc_*` (55), `test_damage_ledger`, `test_score*`, `test_architecture`, `test_player_progress`,
`test_progress_messages`, `test_progress_record`, `test_progression_*`, `test_zone_server*` (86),
`test_combat_server`, `test_combat_director`, `test_combat_loopback`, `test_net_loopback`, `test_bot_swarm`,
`test_net_processes` (separate processes, bots with 0 malformed), `test_siege_clients`, `test_hfsm_brain`,
`test_character_saver`, `test_net_client`, `test_battle*`, `test_downed`, `test_loadout*`, `test_consumables*` and
`test_unstuck*`. The whole Godot suite has not been run; Go does not change (the exported rules carry no NPCs).

**Measured** (this machine, 4 shared cores, Godot 4.7.2 headless; a probe that is not committed, with 64 ephemerals in the
circle of the flat zone; two passes):

| What | Result |
|---|---|
| `on_objective_ticks` of 64 players (one count, every 6 ticks) | 200–335 µs, with one merit paid per player every 10 counts: about 35–55 µs per tick |
| `on_capture` with 32 on the list | 0.6–1.1 ms collecting (timer, gold, XP, level-ups and their LEVEL_UP); 107–187 µs with all 32 waiting |
| `on_npc_killed` with 10 contributors | 128–234 µs |
| `on_merits` discarded (ephemeral victim) | 5–7 µs per call |
| `DamageLedger.contributors` with 200 hits in the window | 29–59 µs (once per rewarded NPC death) |
| LEVEL_UP to 64 peers | 52–96 µs |
| `test_progress_rewards` | 9 tests, about 18 s with the runner startup; the slowest, the captures one (2 s) |

**Not verified:** with the real Go platform (P7 and P10); with real NPCs and combat (the tests' deaths
are provoked with the damage log written; the order of the signals is the real one); the invisible GM (P7b); the
XP pace of Vado Gris (§6.1 assumed about 3000 per hour of battle).

**Left for later:** the invisible GM and `gm_forced` set by commands (platform.md P7b); GM commands,
`xp_add` and `level_set` (P5d); damage distribution and merit anti-farming (PRG-09); end-to-end tests
(P8).

### 19.15 What platform.md P7b leaves

platform.md P7b (its §19.12) puts moderation in the zone. What P5d uses:

- **`min_role`.** `CommandRegistry.register(name, usage, console, network, min_role)`, with `gm` by default; `/gm` goes through
  `execute_chat` with the claim's role and DEBUG_COMMAND, with platform, through `execute_network(…, role)` (without the
  role, `Result.FORBIDDEN`, which the zone counts as a warning and does not execute). 40–43 are not registered yet and 5,
  13 and 16 stay at `gm`: raising them to `admin` belongs to P5d (`ZoneServer._register_commands`).
- **A command's `Context`** carries `origin` (console, chat or network), `role`, `peer` (with its `claimed`) and `target`,
  which the handler sets when resolving the character: with that, the own-characters rule (§10) is checked. The
  audit batch entry is built by `ModerationService` (actor, `source` `zone` or `console`, target by id,
  `at_unix`); the command sets `ctx.audit_args` (no names: the target by `character_id` as a string) and, if it creates
  an operation, `ctx.audit_key = "op:<op_id>"` (the two paths of platform.md §9.1).
- **`gm_forced`** is already set by `/gm teleport`, `/gm visible` and DEBUG_COMMAND 1, 2 and 4 (and `teleport`, `heal`,
  `stamina_inf` and `unstuck` from the console), only with platform; **the invisible GM** (`NetEntity.gm_invisible`) is not
  in `_presence_candidates`, deals no damage (is not a contributor) and `_collector` does not pay them either. The test
  missing from §15 P5c ("an invisible GM in the circle does not collect the capture") is in `test_progress_rewards`.
- **Fenced zone:** ignore, report and sanction already answer "El servicio de cuentas no responde"; the commands of
  §10 that change something belong to P5d.

### 19.16 P5d · GM (PRG-16)

**What exists.** What §14.1 P5d lists, in `scripts/server/` except where stated:

| Piece | Content |
|---|---|
| `ProgressCommands` (`progress/progress_commands.gd`, new) | The ten commands of §10, registered by `ProgressService.setup` with `gm` (and `admin` through DEBUG_COMMAND for the four network ones): `item_give`, `item_take`, `currency_add`, `level_set`, `xp_add` (with their network handlers 40–43), `mastery_set` ("No disponible hasta la fase 6."), `inv_show`, `ledger_show`, `op_show` and `op_revert`; 16 with platform (`net_refill` and `console_refill`, which the zone calls); the replies of `progress_op` and `progress_ledger` (`on_platform_event`); `OpView` (the operation from the §13.2 route or from the journal) and `Actor` (who and through which path) |
| `PlayerProgress` | `abort_op` (all or nothing: `begin_op` saves the state from right after closing the aggregates); `op_add_items`, `op_create_items` and `op_remove_items` (with `protected`), which return the `Outcome` with the delta's slots (`add_items` and `remove_items` keep their `bool`); and the body events' uids according to what is saved (below) |
| `InventoryOps` (shared) | `create_items` (new stacks in the first free slots, copying the fields of a template), `count_outside` and `remove_items(…, protected)` (slots that are not touched) |
| `ProgressService` | `gm_commands`, `now_unix`, `reply_sink` (the `/gm` lines through the system channel), `clock_unix` (the time without platform) and what the commands use: `find_connected`, `connected_net_id_of`, `is_connected_player`, `peer_of`, `player_net_ids`, `active_weapon_slot`, `can_change_weapons`, `is_alive`, `after_gm_change` (the INVENTORY_DELTA with the reason, weapons and charges with LOADOUT), `after_level_change` (`NetEntity.level` and LEVEL_UP), `mark_gm_critical`, `reply`, `log_line` and `notice`; `progress_op` and `progress_ledger` are no longer discarded; `get_stats()["gm"]` |
| `CommandRegistry` (from platform.md P7b) | `register(…, min_role, network_min_role)` and `get_network_min_role`: the DEBUG_COMMAND role if it differs; in the `Context`, `audit_at_unix` (the batch entry's time) and `audit_deferred` (the command builds the entry later) |
| `ModerationService` | The batch entry with `audit_at_unix` if the command sets it, and none with `audit_deferred` |
| `ZoneServer` | `set_weapon` (5) and `cooldowns_off` (13) with `admin`; `refill` with `gm` through `/gm` and `admin` through DEBUG_COMMAND; with platform, 16 and the console and `/gm` `refill <player> <reason…>` are the GM operation of §4.4; `_progress_reply` and `clock_unix` |

**What each command is like** (console and `/gm`; through DEBUG_COMMAND, on whoever sends it and with `note` "debug"):

| Command | Usage | Does |
|---|---|---|
| `item_give` (40) | `item_give <player> <item> [quantity] <reason…>` | GM with one GM_GRANT per new stack (of `max_stack` at most) in the first free slots; without room, "La bolsa de X no tiene sitio." (X's bag has no room) |
| `item_take` | `item_take <player> <uid> [quantity] <reason…>` | GM_REMOVE of that uid (without quantity, the whole stack); not the only equipped weapon ("Es la única arma de X…", I10) |
| `currency_add` (41) | `currency_add <player> <oro\|meritos> <±quantity> <reason…>` | One GM_GRANT or GM_REMOVE entry; a balance that would go negative or exceed the cap, nothing |
| `level_set` (42) | `level_set <player> <level> <reason…>` | Level and `xp_total = total_to(level)` in a GM operation with no entries or events; `detail` with before and after |
| `xp_add` (43) | `xp_add <player> <quantity> <reason…>` | `PlayerProgress.add_xp` with the GM source (LEVEL_UP if it levels up); `detail` with before and after |
| `inv_show` | `inv_show <player>` | Level, XP, realm points, balances, equipment (with the active one) and bag with uid, quantity and bound, four items per line |
| `ledger_show` | `ledger_show <player> [n = 20]` | The n most recent: first those of the unconfirmed journal ("sin guardar", unsaved) and, with platform, those of `GET …/ledger?limit=n` |
| `op_show` | `op_show <op_id>` | From the journal if it is in one of this zone (with platform, "sin guardar"); otherwise, from `GET /internal/v1/ops/{op_id}` |
| `op_revert` | `op_revert <op_id> <reason…>` | §10 (below) |

**Deviations and implementation decisions:**

- **One role for `/gm` and another for the network.** The table of §10 gives `gm` to the commands and the DEBUG_COMMAND rule requires
  `admin` for 40–43 and 16: `CommandRegistry.register` gains `network_min_role` (empty: the `min_role`) and
  `execute_network` checks that one. 5 and 13 require `admin` through `/gm` as well (they are not §10 tools: they set a weapon
  that is not in the equipment or drink without spending); 16 through `/gm` is a GM operation like `item_give`, with `gm` and the
  own-characters rule.
- **The reason is mandatory** for everything that changes something through the console and `/gm` ("`note` … mandatory and non-empty";
  the table only wrote it for `currency_add` and `op_revert`), also without platform: one single rule. It goes in the `note`
  (up to 200 characters), **never in `args`**: the audit stores no free text (platform.md §19.12). The `valid_reversal`
  case of `save_cases.json` carries it in `args`; S2 does not care and it is left alone. `args` carries the target
  by its `character_id` (`"0"` for an ephemeral) and the arguments that are not text (`["42", "potion_health", "5"]`, the
  currency as `oro` or `meritos`, `[op_id]` in `op_revert`). From the console, `actor_character_id` goes as `null`
  (§10; the P5a cases omit it and `checks.go` admits both).
- **The batch entry and the S8 row, identical.** `_commit` sets `ctx.audit_key = "op:<op_id>"`, `ctx.audit_args`
  (whatever of `detail` S8 does not put in its column: `args` and, if present, level and XP) and `ctx.audit_at_unix =
  detail.at_unix`. `op_revert` with platform is asynchronous: its entry is built with the route's reply
  (`audit_deferred`), with the `op:<op_id>` of the REVERSAL or, if none is created, with the instance's key and its reason
  in the zone log; this way each use leaves a single entry.
- **`item_give` creates new stacks** ("in the first free slot": `InventoryOps.create_items`), without merging with those
  already there. 16 with platform merges like CAMP_REFILL (`op_add_items`).
- **The body events' uids against what is saved (a P5a fix).** S4 (§13.3 and `checks.go`) checks each
  event with a `uid` against what is live in the database: if it adds, the uid cannot be there; if it subtracts, it must be. Without this,
  16 (which adds to the saved stack), removing from the half of a SPLIT that has not been saved yet (a reversal,
  `item_take`) and also **the player's DESTROY of that half** (P2/P5a) would give `invalid_save` and departure without
  save. `PlayerProgress` stores the uids the platform will have when receiving the next body (those of the loaded
  record and, after each `build_section`, those of its snapshot: a character's bodies are applied in order) and the body
  carries `uid: null` in those events, like an aggregated one. Quantities do not change (S4 per definition still balances),
  the journal keeps the real uid and `save_cases.json` comes out the same.
- **All or nothing with `abort_op`.** `begin_op` saves inventory, balances, recorded balance, realm points, level, XP,
  revision and the pending part of PROGRESS_UPDATE from right after closing the aggregates; `abort_op` restores it and removes
  the operation (the closed aggregates stay, and the ids taken are lost). Also, what can be known beforehand
  (balances, what is missing, I10, the fenced zone, own characters) is checked before opening the operation, so as not to
  spend ids or close aggregates in vain.
- **Reversal.** First, what is in this zone is checked: a REVERSAL of it in a journal ("Esa operación ya se está
  revirtiendo"; without platform, "ya está revertida"), an `op_revert` of the same one waiting for its route (the same) and, with
  platform, the operation still in a journal ("aún no está guardada"). Then, the route (or the journal without platform):
  neither REVERSAL nor MIGRATION, nor with `reversed_by`, and the participant connected here. The own-characters rule
  is checked with the reply (beforehand it is not known whose it is). What is missing is stated before touching anything ("A Ana le faltan
  20 de oro: no se revierte nada.", "… 1 × bow_vado …"). What is removed respects the equipment's active slot **even
  if it is the event's uid** (I10: S5 rejects the active slot without a weapon), so reverting a kit with the weapon equipped says
  something is missing. What is recreated copies the retired row from the route (`instances`) or goes bound. Realm points go down
  with all of the REVERSAL's merits if the original had merits of reason 3–5 (the S6 rule in `checks.go`). XP
  subtracts `detail.xp_delta`, bounded to 0 … `total_to(40)`, with its level, and the REVERSAL also carries before and
  after. Without platform, a reversal that has already left the journal's 256 could be repeated: it is an ephemeral.
- **Equipment with an action in progress.** `ActionMachine.set_weapons` only works with action NONE: a command that touches the
  weapon slots with an action in progress answers "X está en plena acción…" (X is in the middle of an action) without doing anything.
- **What changes nothing creates no operation:** `level_set` to the same level with the same XP, `xp_add` at the cap and 16
  with nothing to refill (which sends the LOADOUT anyway, as always).
- **DEBUG_COMMAND refused for a reason** (bag full, fenced zone, no ids): REFUSED (no warning), with the reason in
  the audit and in a NOTICE to the player. Without the role, FORBIDDEN and a warning (platform.md P7b).
- **`/gm` replies**: one line per system-channel message (`reply_sink`); through the console, together in the
  log. Those that arrive with a route go to whoever asked if still in the world, or to the log from the console.
- **The time without platform** (the ephemerals' `at_unix`) is given by the zone (`clock_unix`, `ModerationService`'s):
  `scripts/server/progress/` does not read `Time`.

**For the following packages.**

- **P8:** the `progress` bot gives gold and a potion through DEBUG_COMMAND 41 and 40, which with platform require an `admin` account
  (§15 already provides one). `TestProgressEndToEnd` can also compare the GM operation with its `audit_log` row.
- **P7 and platform.md P10:** against the real Go platform, `op_revert` with the real route (`instances` and
  `reversed_by`) and `ledger_show`; S2 with these commands' `detail` (the `detailKeys` keys).

**Tests.** In Godot, `test_gm_progress` (11, the zone without network with `FakeZonePlatform`, hand-assembled peers and the
`/gm` commands through the GM channel; each save goes through the shape checks of S2, S4 and S5 that can be
done without a database): giving 5 potions, splitting them into 3 and 2, merging the 2 with the kit's stack and reverting with the
scripted route from what was saved (the total drops by 5, first from the given uid; the saved GM_GRANT and REVERSAL; one
`op:<op_id>` entry per operation with S8's args, `at_unix` and the target by id, without the name; a second with
`reversed_by`, "ya está revertida"); two simultaneous `op_revert`s and another with the REVERSAL in flight ("ya se está
revirtiendo", without asking for the route again), the opposite entry with `ref_kind` 4 and what was already spent ("le faltan 20 de
oro"); DEBUG_COMMAND with platform (41 from a `player`, 40, 16, 5 and 13 from a `gm`: warning, no item and no save; 16
from an `admin`: GM with GM_GRANT and "debug" that the save accepts, without the saved stack's uid, and its LOADOUT; 5 and
13 from an `admin`: no operation and with their entry; 40 from an `admin` on themselves); own characters with `env`
`dev` (`item_give` and `op_revert` from a `gm`, rejected; from an `admin`, accepted); the fenced zone (`item_give`, `level_set`
and `op_revert`, nothing; `inv_show`, yes); `level_set` and `xp_add` with their `detail`, LEVEL_UP and `NetEntity.level`, and the
reversal of `level_set`; reverting PvP merits (realm points go down, S6); `ledger_show` and `op_show` through the
routes (the "sin guardar" journal first, the route with its `limit` and the instance, one that does not exist, their audit) and
`mastery_set`; without platform, everything from the journal (two stacks of 15 and 5, `inv_show`, `op_show`, DEBUG_COMMAND without a role,
`ledger_show`, reverting, "ya está revertida", not reverting a REVERSAL, `item_take` and the only weapon, 16 as always);
and the base: the body's uids against what is saved (the split and destroyed half, adding to a saved one, the new stack)
and `abort_op` with protected slots. Verified with the mutation they should catch: without the own-characters
rule, without the fence, without the uids against what is saved, without the `op_revert` that waits for its route, 40 with `gm`, without
the deferred `op_revert` entry and without lowering realm points, they fail.

Adjusted: `test_combat_server` and `test_hfsm_brain` (no network command is missing any longer). Also still passing:
`test_command_registry` (13, one new: the network role different from `/gm`'s), `test_zone_moderation`,
`test_chat_moderation`, `test_progress_service`, `test_progress_rewards`, `test_progress_section`,
`test_player_progress`, `test_progression_fixtures` (`save_cases.json` comes out the same with the uids against what is saved),
`test_progress_messages`, `test_inventory_ops`, `test_inventory_properties`, `test_character_saver`,
`test_zone_server*` (86), `test_zone_process_shutdown`, `test_war_persistence`, `test_war_platform_process`,
`test_ability_server`, `test_consumables_server`, `test_loadout_server`, `test_loadout_net`, `test_combat_wire`,
`test_combat_director`, `test_net_loopback`, `test_bot_cheat`, `test_projectile_loopback`, `test_architecture` and
`test_export_config`. The whole Godot suite has not been run; Go does not change.

**Measured** (this machine, 4 shared cores, Godot 4.7.2 headless; a probe that is not committed, three passes):

| What | Result |
|---|---|
| `build_section` of the largest character (120 items and 256 operations) | 2.4–2.7 ms, as in P5a (2.2–2.7 ms): the uids against what is saved are not noticeable |
| `begin_op` with 120 items (the copy for `abort_op`) | 0.36–0.63 ms; with the kit's 4 items, 25–165 µs. Only in the kit, GM commands and reversal |
| A command through the console (ephemeral, 24 items) | `item_give` 0.2–0.65 ms, journal `op_revert` 0.25–0.42 ms, `currency_add` 0.11–0.21 ms, `level_set` 0.12–0.2 ms, `inv_show` 0.1–0.18 ms, `ledger_show 100` 23–67 µs |
| `test_gm_progress` | 11 tests, about 16 s with the runner startup; the slowest, the two-reversals one (3 s, with the save that takes 2 s) |

**Not verified:** against the real Go platform (P7 and platform.md P10): S2 with these commands' `detail` and
the actor's role at `at_unix`, the operation route with its `instances` and the real ledger; the bot that gives gold and potions
(P8).

**Left for later:** end-to-end tests (P8); `mastery_set` (phase 6); offline editing from the moderation
panel (SOC-37, phase 8).

### 19.17 P7 · Go store (PRG-10, PRG-12, PRG-14, PRG-16, TEC-25, TEC-43)

**What exists.** What §14.1 P7 lists, in `platform/` except where stated:

| Piece | Content |
|---|---|
| `internal/migrate/migrations/0010_progress.up.sql` and `.down.sql`, `internal/migrate/testdata/seed_0010.sql` | The DDL of §3.3: the four state tables (`character_progress`, `character_wallets`, `item_instances` with the deferred slot constraint `item_instances_slot_key`, `character_timers`) and the five append-only ones with `eldmark_append_only()` on each. The inverse drops triggers, function and tables in reverse order; the seed leaves one row in each new table (Aneira's progress, one live item and one retired, a GM operation and its REVERSAL, and a retained operation of the tombstone) |
| `progress.Rules` (`rules.go`) | `ValidateCreate` (implements `persistence.CreateValidator`) and what S2, S3 and S6 check, resolved by name in `LoadRules`: the operation kinds, the reasons of each kind (the zone's `EconomyOp.KIND_REASONS`), those that give realm points, the `merits` currency and the caps. A file missing any of those names does not load |
| `progress.Store` (`store.go`) | `New(rules, now)`, `Create`, `Load`, `Summaries` and `Purge` |
| `section.go` | S1: the strict reading of the section |
| `checks.go` | `Apply` (S1 → locked state → S2–S7 → S8) and S2–S7 |
| `write.go` | S8 |
| `retention.go` | `PurgeRetention`, with `Retention` (365 days) and `RetentionBatch` (10 000) |
| `export.go` | `Export`, `Op` and `Ledger` with the bodies of §3.5 and §13.2 |
| `cmd/eldmark-platform` | `serve` and the `admin` command use `progress.Store` and `*progress.Rules` in all environments: `errNoProgressStore` and the refusals of `purge-now` and `reapply-purges` in `staging` and `production` are gone |
| `internal/platformtest` | `NewWithProgress(t, newStore, validator)` sets up the platform with the real store; `ProgressStore` is the store in use, and `ValidAppearances`, 8 valid B per realm (`NewCharacter` uses them with it) |
| `deploy/restore_check.sh` | The "purged characters with personal data" query also looks at `character_progress`, `character_wallets`, `item_instances` and `character_timers` |

**The bodies decided here** (ids as strings, like everything):

- **`Load`**: the keys of §3.4, with a balance for each currency in the rules (0 without a row), live items by
  container and slot, timers by key and `location` from the columns (`saved_at_unix` from
  `saved_at`; null with `last_zone_id` null). Without a row in `character_progress` (it does not exist or is a tombstone),
  `persistence.ErrNotFound`.
- **`Export`**: `{"record": …, "ops": [{op_id, kind, zone_id, ref_op_id, created_at_unix, ledger: [{entry_id,
  currency, seq, delta, balance_after, reason, ref_kind, ref_id, created_at_unix}], items: [{uid, def_id,
  count_delta, reason}]}]}`, with `record` null for a tombstone, operations by `created_at` and `op_id`, and only the
  character's own entries and events. No operation carries `actor_account_id`, `note` or `detail` (those that are
  not GM or REVERSAL have none).
- **`Op`** and **`Ledger`**: those of §13.2; `instances` with `retired` and `Ledger` with `created_at_unix`.
- **S8's `audit_log` row**: `args` is the operation's `detail` without what has its own column
  (`command`, `source`, `actor_character_id`, `at_unix`): `{"args": ["42", "oro", "50"]}` and, in `level_set` or
  `xp_add`, also `level_before`, `level_after`, `xp_before`, `xp_after` and `xp_delta`. `source` is `console` with
  `detail.source = "console"` and `zone` with `gm` or `debug`; `target_account_id`, the account of the character being saved.
  §13.3 said "taken from the operation" without fixing the shape, and the zone's batch requires `args` to be an object.

**Deviations and implementation decisions:**

- **S1 only checks shape.** All keys of the section are mandatory (also `ops`) and the read-only ones
  come out with their own text; the ranges of each field are checked by the check that owns it (balances, S3;
  events, S4; items, S5; level, health and active slot, S6; timers, S7), because the cases expect it
  that way (a negative balance is S3; slot 30, S5). S1 also checks what has no other check and the database
  would not accept: the channel (`smallint`), coordinates (`real`) and that `detail` is an object that fits in `jsonb`.
- **S2, stricter than §13.3**, so that S8 does not write anything that cannot be read afterwards: an `op_id` only once
  per body; outside GM and REVERSAL, empty `detail` and no actor; `ref_op_id` only (and always) in the REVERSAL; the
  `note` up to 200 characters and without NUL; a single STARTER_KIT per body. The `detail` of GM and REVERSAL only admits
  `command` (the batch format, `^[a-z][a-z0-9_]{0,47}$`: never one from the CLI), `args` (a list of 32 strings of
  255 B at most), `source` (`gm`, `console` or `debug`; `debug` carries an actor, like `gm`), `at_unix`,
  `actor_character_id` (may be missing or null from the console, as in the cases) and the five level and XP keys, which
  are integers.
- **S3** requires the currency to exist and the snapshot to carry each currency of the rules once, and checks `ref_kind` (0–4).
  **S4** also checks the format of each event's `def_id`, `count_delta` (≠ 0, in `int`, with the sign of its
  reason) and that an event that subtracts belongs to a live uid **with that same item**. **S5** checks the seed (`u32`) and leaves
  to S6 an active slot outside 0–1; a "new" uid is one that is not live for this character, so a
  retired one of its own also collides with the primary key (S8, I1).
- **Realm points (S6)**: the old ones + the body's merit entries of reason 3–5 + the merit entries of
  each REVERSAL whose reverted operation gave this character merits of reason 3–5 (checked by S2's query on
  the reverted one). Reverting a GM's merits does not move them. `xp_total` does not exceed `total_to(40)`.
- **Locking.** `Apply` locks at the start (`for update`) the character's progress, balances and live items:
  two `Apply` calls for the same character run in series even if the caller does not have the lease locked (in the
  platform, it always does). Balances are written with the guard of §5.4, one statement per currency with entries
  (`balance = balance + Σ delta`, `last_seq = last_seq + n`, `where … and balance + Σ delta between 0 and cap`), and
  each entry takes its `seq` from the `last_seq` it returns; without a row, or with a balance different from the snapshot's, the
  save fails with S3 ("otro guardado lo ha cambiado", another save changed it). With the lock it does not happen; it is there in case someone writes balances
  through another path.
- **Times** (`saved_at`, `created_at` of operations, entries and events, `retired_at`, the "now" of S2 and S7 and the
  retention year) come from the store's clock (`New(rules, now)`; `time.Now` in `serve`), not from the database's `now()`:
  the tests fix the cases' one.
- **`created_op`** is the operation of the first event in the body that adds that uid; null if there is none (born
  from a split). **`Create`** also inserts a balance of 0 for each currency.
- **Retention**: each call deletes at most 10 000 entries, 10 000 events and 10 000 participations (those that no longer
  have entries or events), and in the same call the reversals and operations left without
  participants; it sets the mark with `set_config(…, true)` and clears it when done. `emptied` is sorted by id.
- **`ValidateCreate`**: a race that does not exist is `unknown` (like the provisional one) and one of another realm,
  `wrong_realm`; the appearance is only checked with a valid race (otherwise, the failure is the race's); the fields that
  fail all come out at once. `Ledger` with a `limit` outside 1–100 returns an error (the route validates it beforehand).
- **The §13.3 cases do not change**: all 68 pass exactly as the zone generates them, with the labels of §19.11.
- **`deploy/deploy_test.go`** (from platform.md P9b) sets up the `TestBackupAndRestoreCheck` platform with the
  real store: the backup carries the progress and `reapply-purges` (the binary) deletes it again.

**For the following packages.**

- **P5d:** the audit batch of a command that creates an operation carries `key = "op:<op_id>"` and the same fields as
  S8 (above): `args` = the `detail` without `command`, `source`, `actor_character_id` or `at_unix`; if they do not match, whichever
  arrives first wins. `detail` may only carry the keys above (any other is S2 and the character loses what was not
  saved). `op_show` and `ledger_show` read the `Op` and `Ledger` bodies; the reversal of a DESTROY copies the
  fields of `instances` (with `retired`).
- **platform.md P9a:** the hourly retention job calls `PurgeRetention` in a transaction while
  `deleted > 0` and deletes in it the `characters` rows of `emptied`; the account export puts
  `Export` under `characters[i].progress`, also for tombstones with a ledger.
- **platform.md P10 and P8 here:** `serve` already saves for real; end-to-end tests compare with
  `Load`.

**Tests.** In Go, `internal/progress` (18 new): `TestApplyFixtures` (the 68 cases of `save_cases.json`, each
in a fresh database and in parallel; it requires there to be `applied` cases and cases for S1 to S8); `TestCreateLoad` (the record of
a new character and, after the kit and some play time, the snapshot field by field with the read-only ones and
`saved_at_unix`); `TestValidateCreate` (the 8 B cases of `appearance_cases.json` with their `fields`, race of another
realm, race that does not exist, template that is not `selectable` and two simultaneous failures); `TestApplyWritesTheSave`
(`save_version`, `saved_at`, `last_seq` and `seq`, `created_op`, the operations' zone, the GM's audit row
field by field, the batch's one that arrives first and is neither duplicated nor overwritten, `op_reversals` and the console without an actor);
`TestApplyLateRetryKeepsExpiredTimers`; `TestApplyActorRoleAtTheTime` (the GM operation from before the `set-role` passes, the one from
after does not, and a `set-role` row with `source = 'zone'` does not count); `TestApplySwapsSlots` (a swap and a
three-way rotation); `TestDuplicateUid` (two simultaneous saves with the same new uid and with the same `op_id`: the
second waits, collides with `item_instances_pkey` or `economy_ops_pkey` and leaves nothing); `TestWalletConcurrency` (the
UPDATE guard with two transactions in SQL, two `Apply` calls spending 60 of 100 and the balance reconstruction);
`TestTwoCharacterOp`; `TestApplyReversalOfMeritsLowersRealmPoints`; `TestApplyOpShape` (11 S2 breakages that the
cases do not cover); `TestPurgeKeepsLedger` (the account purge with the `internal/characters` purger, the tombstone,
the ledger intact, P0001 on UPDATE, DELETE and TRUNCATE of the append-only tables, 23503 when deleting the tombstone and the
mark that does not survive its transaction); `TestRetention` (before the year nothing; at +366 days, the purged character's ledger, its empty
tombstones and that of one without a ledger, and the two-participant operation with the live one); `TestSummaries`;
`TestExport` (also for a tombstone); `TestOpLedger` (with and without a lease on the instance, the retired row of the
DESTROY, `reversed_by`, pagination and limits); and `TestThroughThePlatform` (the whole platform with the real store:
validated creation, claim with `Load`, `applied`, `duplicate` and S5 `invalid_save` saves through the internal
API, the list with `Summaries`, the next claim and the operation and ledger routes with 200 and 404).
Adjusted: `internal/migrate` (0010 among the embedded ones and its seed), `cmd/eldmark-platform` (`migrate status` with 7,
`down 2` undoes 0010 and 0006, `serve` rejects an appearance that the provisional validator admitted and saves to
`character_progress`, and in `staging` and `production` it sets up the services) and `deploy` (above). Verified with the
mutation they should catch: without the sign in S3, `s3_sign` fails; without the REVERSAL merit rule,
`TestApplyReversalOfMeritsLowersRealmPoints` fails; with a `Purge` that does not delete items or progress,
`TestPurgeKeepsLedger`, `TestExport` and `restore_check.sh` fail. In Godot, `test_progression_fixtures` and
`test_progression_rules_export` still pass (Godot does not change).

**Measured** (this machine, 4 cores, Go 1.24.7, PostgreSQL 16 on a Unix socket with `fsync` off):

| What | Result |
|---|---|
| `Apply` (with the COMMIT) after the kit: 1 GAMEPLAY / 32 / 256 (86 KB) | 3.7 / 8.0 / 49 ms |
| `Apply` with 1 / 32 / 256 GM operations (two queries per GM: the actor's character and their role) | 4.6 / 17 / 76 ms |
| `Load` of a character with the kit | 1.4–2.2 ms |
| `go test -count=1 ./internal/progress` | 11.8 s (with the cluster startup); the 68 cases, about 3 s in parallel |
| whole `go test -race -count=1 ./...` | passing, 37 s with `gofmt` and `go vet`; `internal/progress`, 8.7 s (19.6 s with the other packages at once in another pass) |

**Not verified:** against a real zone (P8 here and platform.md P10); retention with more than 10 000 rows
per table (the per-call cap is not exercised); the size of the export of a character with years of ledger.

**Left for later:** the hourly retention job and progress in the account export (platform.md
P9a); ledger telemetry (PRG-30) and the daily reconstruction of balances (§5.4); the `SaveMany` exception
for two-participant operations (phase 6).

### 19.18 What platform.md P9a leaves

platform.md P9a (its §19.15) puts to work what in §3.5 was waiting for the platform:

- **Ledger retention:** the hourly job `privacy_retention` (`internal/privacy`, `Service.PurgeLedger`) calls
  `PurgeRetention` in a transaction while `deleted > 0` and, in that same transaction, deletes the `characters`
  rows of `emptied` (tombstones only). The year is measured by the store's clock (`progress.New(rules, now)`).
  Verified with 10 050 entries of a tombstone (three passes), an operation shared with a live character who
  stays and a tombstone without a ledger that gets deleted.
- **Export:** `characters[i].progress` of the account archive is `Export`, in the export's transaction;
  for a tombstone without operations, `null`. `accounts` only sees `Export` (`accounts.ProgressExporter`).
- **Nothing changes here:** neither `internal/progress` nor Godot.

### 19.19 P6 · client (UI-26, ART-19, PRG-07)

**What exists.** What §14.1 P6 lists, in `scripts/client/inventory/` except where stated:

| Piece | Content |
|---|---|
| `ClientInventory` | §11.3 as is: the confirmed state, the pending requests (8 at most) and the view rebuilt with `InventoryOps.apply`; `request`, `on_delta`, `on_full_page`, `tick` (5 s timeout), `get_view`, `get_confirmed` and the three signals. Also `has_inventory`, `validate` (what `request` would say without sending or warning), `notify_rejected`, the gestures (`make_move`, `make_split`, `make_destroy`, `equip_target`), `current_context`, `is_provisional`, `is_syncing`, `get_stats` and `clear`. No nodes or network: it sends through `send_request` and `send_sync`, and the context reaches it through `context_provider` and `in_combat_provider` |
| `ClientProgress` (new) | The balances from WALLET_UPDATE and the level, the level's XP, realm and attribute points from PROGRESS_UPDATE; before the first one, the level from the owner's SPAWN; the own LEVEL_UP raises the level immediately |
| `InventorySlotView` | A `UIIconSlot` with drag and drop (`make_drag_data`, `accepts`, `drop`; Shift on start = split), `activated` (double click or right click) and `drag_cancelled` (nobody picked up the drag). `show_item` sets icon, stack, rarity, tooltip and the dimmed provisional stack; `locked` for slots 2–6. Static: `icon_for`, `short_name`, `tooltip_for`, `weapon_damage` |
| `SplitDialog` | Modal like `UIConfirmDialog`, with a `SpinBox` from 1 to the stack − 1 that starts at half (`default_amount`); `confirmed(amount)` and `canceled` |
| `InventoryWindow` | Key I: 6-column grid with `bag_slots` cells (scrolls from 6 rows) and, at the bottom, gold and merits with thousands separators. It resolves the gestures of its cells and those of the character window: `drop_item`, `activate_item`, `drop_outside` (with the `UIConfirmDialog` "¿Destruir Poción de vida ×3?"), `handle_drag_cancelled`, `is_over_drop_zone`, `present_slot` and `connect_slot` |
| `CharacterWindow` | Key C: the figure (a `SubViewport` with its own world, a still `PlayerCharacter` with `HumanoidVisual`, its appearance and its weapons, which rotates on drag and only draws while open), the seven slots (2–6 grayed out with "Próximamente"), name, realm, level, XP bar and text, realm and attribute points, and the maximum health and stamina from `CombatRules` |
| `AppearanceApplier` (`scripts/client/appearance_applier.gd`) | `apply` (§7.4: pieces with `set_part`/`clear_part` and skin, hair and eye tints), `resolve` (the 8 B if valid for the realm's people; otherwise, `default_for`), `apply_bytes` and `part_scene` |
| `HumanoidVisual` | `set_part` and `clear_part` of §7.4 (the base model's meshes are the `body` slot; those of `part_scenes`, those of `part_slots`), `get_part_meshes`, `get_part_path`, `set_tint`, `get_tint` and `clear_tints`. What is requested before `_ready` is applied on entering the tree |
| `NetClient` | Owns the `ClientInventory` and the `ClientProgress` (`get_inventory`, `get_progress`): passes them the four messages before its signal, runs the timeout on each tick and provides the context (`inventory_context`). It stores the 8 B of the owner's SPAWN (`get_own_appearance`) and carries an ally's LEVEL_UP to its view. The two requests do not go out without a transport |
| `RemoteWorld`, `RemotePlayerView`, `Nameplate`, `Nameplates` | Each remote player's appearance (`AppearanceApplier.apply_bytes` with their realm), their level (the SPAWN's and that of their LEVEL_UPs: `on_level_up`, `get_level`, `set_level`) and "Nv N" in gray before the allies' names |
| `OnlineMain`, `HUD`, `InputBindings` | The own character's appearance; the two windows (character on the left, inventory on the right), the two dialogs, the rejection warnings in chat, the hints "Inventario" and "Personaje", and the actions `open_inventory` (I) and `open_character` (C) |

**Deviations and implementation decisions:**

- **`ClientProgress` is new** (not in §14.2): the windows need the balances, level and XP, and the level
  is also the `InventoryOps.Context.level` of the requests. **`NetClient` owns both** (not the HUD): the
  INVENTORY_FULL arrives right after the owner's SPAWN, before anyone mounts the interface, and this way no message is
  lost.
- **A request's context** comes from the local character's predicted state: the active slot is bit0 of
  `combat_flags2`, "can touch equipment" requires alive, not knocked down, out of combat (the bit in the extra block) and without an
  action, and "drinking" is a consumable ABILITY in progress. Without a character, equipment is not touched.
- **What is rejected locally** warns with the text of `result_text` and does not go out: besides the `InventoryOps` codes,
  NOT_NOW without an inventory (before the first FULL), when touching a provisional stack (as source or
  destination) or if it could not be sent, and RATE ("Más despacio") with 8 in flight: the interface waits. Unequipping with a
  full bag warns "No cabe" (NO_ROOM) without requesting anything; a double click on something that cannot be equipped does nothing.
- **A pending request that stops being valid locally** (a server change took its item) stops being applied to the
  view but stays in the list until its reply: this way its rejection arrives with its text. DESTROY also takes its
  provisional id (−`request_id`, the `op_id` of its PLAYER operation in `InventoryOps`), which is not seen anywhere.
- **Sync:** one INVENTORY_SYNC_REQUEST every 5 s at most (what asks for more waits) and another if the FULL does not arrive
  within 5 s. Deltas prior to the first FULL are ignored (the FULL brings everything); entries for slots the
  client does not have (bank, bag above `bag_slots`) are too.
- **Gestures with a dialog are validated beforehand** (`validate`): splitting does not open the `SplitDialog` if splitting half does not
  work (something unstackable, an occupied cell) and dropping outside does not ask if the destruction is not valid (the
  indestructible, the equipped): the warning appears and nothing else. On confirming, the request carries the `uid` seen when
  opening the dialog (if it changed meanwhile, STALE locally). DESTROY sends the quantity shown (the whole stack),
  not 0.
- **Dropping outside** is a drag that nobody picks up (`gui_is_drag_successful` false at the end) with the mouse outside
  both open windows (`is_over_drop_zone`).
- **Tooltip:** a weapon's damage is the `base_damage` of each light attack, the uncharged heavy one's and that of the
  abilities that hit; the comparison (green or red) is the sum of the combo and the heavy against the weapon in the slot
  it would go to with a double click (with nothing in it, there is no comparison). The value always appears ("0 de oro" on the kit).
- **Provisional icon** (§16): the short name is the initials of the first and last word ("PV", "AV"), over
  the category color, with `PlaceholderIcon`.
- **Rejection warnings go to chat** as system text (there is no dedicated inventory warning yet).
- **Template selector (§2.5):** the death screen does not show it as soon as the client has an inventory (the
  first FULL), which covers anyone entering with a ticket (the zone with platform always sends the FULL) and, without
  platform, from the first spawn. Against a zone without progress (until P5b) it is still shown.
  `RealmSelect` keeps it: without platform each session is a new ephemeral character whose kit comes from the LOADOUT_SELECT
  sent before CLIENT_READY; with a ticket there is no `RealmSelect` (it is platform.md P8's `FrontMain`, which must not
  fill `config.loadout`).
- **`HumanoidVisual`:** the `part_scenes` slots are given by the new `part_slots` (by default `head`, `hair` and
  `beard`, the scene's order, which does not change); a scene already in the slot is not mounted again (the catalog's body
  and head are the scene's, so applying an appearance only touches hair, beard and tints). **Tints**
  go by the base material name of Universal Base Characters (`MI_Regular_` and `MI_Superhero_` skin, `MI_Hair` hair, beard
  and eyebrows, `MI_Eyes` eyes): `albedo_color` = the catalog's color, multiplied by
  the texture, on a copy shared per material and color (the imported material is never changed). `# TODO(arte)`
  until the ART-20 shaders.
- **A Godot 4.7.2 bug:** a `const Dictionary[StringName, PackedStringArray]` written with array literals
  stores an `Array` with the type of `PackedStringArray` and walking it reads empty strings or crashes (verified with a
  probe). `TINT_MATERIAL_PREFIXES` is untyped.
- **`AppearanceApplier.resolve`** takes the realm's people (`race_for_realm`: the SPAWN carries no `race_id`) and requires
  byte 0 to be theirs, like `validate`. `apply` does not validate: an index that does not exist leaves that slot as it was
  and a piece without a scene empties it.
- **The figure** carries the weapons from the character's combat state (`combat.weapon_id` and `alt_weapon_id`, which the
  LOADOUT imposes), not those of the optimistic view: a rejection does not make it flicker. Its framing and light are
  provisional (`# TODO(arte)`).

**For the following packages.**

- **P5b:** the client only has an inventory from the first INVENTORY_FULL (after the owner's SPAWN) and follows the revision
  order of §4.6; its context is the same one `PlayerProgress.apply_request` sets, so what the client
  considers valid the server does not reject except for what the client does not yet see (combat, action, a server
  change). `NetEntity.appearance` is what the client draws; at 0, the realm's default.
- **P5c:** WALLET_UPDATE and PROGRESS_UPDATE already reach the two windows; an ally's LEVEL_UP, their nameplate.
- **platform.md P8:** `CharacterAppearance.random` and `AppearanceApplier.apply` for creation and the selection view; with a ticket,
  the character's `config.realm` and no `config.loadout`.
- **P8 here:** `test_progress_loopback` uses these pieces (equipping the bow from the bag through `InventoryWindow`, the
  rejection that returns the item, the level on the nameplates).

**Tests.** In Godot: `test_client_inventory` (12: nothing before the first FULL and pages that join by
revision; optimistic and confirmed MOVE; the rejection that returns the item with its text, also the combat one and "Necesitas
nivel 12"; server changes interleaved with a request in flight, and the one that stops being valid and arrives rejected; the
provisional stack of a SPLIT and DESTROY; the 5 s timeout, the late reply and the repeated sync; revision
gaps with a sync every 5 s and the u32 wraparound; the cap of 8 and `request_id`s that skip 0; 600 random gestures
against a fake server that applies the same rule: the server rejects none of those the client considers valid
and the view ends up the same; the gestures' destinations; `ClientProgress`; and `NetClient`, which feeds the
inventory and provides the predicted state's context); `test_inventory_window` (9: the grid with the view and the currencies;
drag and drop in the bag and onto equipment, the weapon swap and WEAPON_REQUIRED; Shift with the dialog and its
half, cancel, and what cannot be split; double click and right click; dropping outside with confirmation, cancel and the
indestructible or equipped; the tooltip with damage, level in red, comparison and the potion's effect; the character
window with its slots, level, XP, sheet and figure; the HUD with I and C, the warning in chat and the template selector
hidden with an inventory, and present without one); `test_appearance_visual` (5: all combinations of catalog pieces
with random colors; 100 random ones per people; `set_part` does not recreate the node, the skeleton or the animator, the same
scene does not touch the meshes, tints and the hood apply to what is mounted afterwards; what is requested before `_ready`;
`resolve` with 8 B at 0, another size, another people and a valid one).
Verified with the mutation it should catch: with a client context that ignores the active slot, the fake server
rejects 11 of the random walk's gestures and the test fails. Still passing, among others, those touching
what changed: `test_hud_combat`, `test_net_client`, `test_remote_world`, `test_nameplates`, `test_online_main`,
`test_character_visual` (the draw budget with the pieces per slot), `test_progress_messages`,
`test_ability_input`, `test_party_hud`, `test_social_menu`, `test_chat_box`, `test_hints`, `test_ui_components`,
`test_ui_widgets`, `test_realm_select`, `test_architecture`, `test_export_config`, `test_combat_server`, the
`*_loopback` ones, `test_loadout_net`, `test_bot_swarm`, `test_siege_clients` and `test_net_processes` (59 files in total).
The whole Godot suite has not been run.

**Measured** (this machine, 4 cores, Godot 4.7.2 headless):

| What | Result |
|---|---|
| `test_client_inventory` | 12 tests; the slowest, the 600 random gestures (57 ms); the file, about 13 s with the runner startup |
| `test_inventory_window` | 9 tests; the slowest, the HUD with the two windows and the figure (174 ms); about 13 s |
| `test_appearance_visual` | 5 tests; the 300 random appearances, 341 ms (applying one, ~1 ms with the tints cached); about 12 s |

**Not verified:** with a zone that actually serves the requests (P5b) and end to end (P8); drag
with a real mouse (the tests call what `_get_drag_data`, `_drop_data` and the end of the drag do, not the viewport's
drag machinery); the figure drawn (in headless the viewport does not render); the visual approval of the two
windows, the provisional icon and the tints (§16).

**Left for later:** the inventory in the zone (P5b), the rewards that fill currencies and XP (P5c), creation and
selection with appearance (platform.md P8), the icons (ART-12) and the skin and eye shaders (ART-20).

### 19.20 Integration of the lanes

The phase 5 integration (the merges of `wip/fase5-almacen` and `wip/fase5-cliente` into `wip/fase5-zona`) is in
platform.md §19.17. What concerns this document:

- **Numbering.** P7 becomes §19.17, which leaves platform.md P9a at §19.18 and P6 at §19.19, with their citations in §14.3 and in
  the backlog.
- **No code changes.** The zone (P5a–P5d), the Go store (P7) and the client (P6) fit together just as each
  package left them: the 68 cases of `save_cases.json` keep passing in Go and the zone and client tests pass
  untouched.
- **End to end, by hand** (platform.md §19.17): with the real platform, the first entry's kit
  (STARTER_KIT), three console GM operations (`xp_add` raising from 1 to 11 at once, `item_give` and
  `currency_add`) in a critical save that passes S1–S8, their trace in `detail` and in the audit, and the next
  entry that loads what was saved. It is what P8 turns into tests (`test_progress_platform_loopback`,
  `platform/e2e/progress_test.go`).
- **Backlog.** PRG-13 (the level is saved), PRG-14 (creation offers each realm's people) and ART-19
  (the two halves of the criterion together) are closed; UI-24 stays open (two clients with a window and the visual approval).

**Status (6 November 2026):** P8 is done: `test_progress_loopback`, `test_progress_platform_loopback`, the
`--bot-scenario=progress` bot and `platform/e2e/progress_test.go` (`TestProgressEndToEnd` and `TestProgressCrash`) are
in `main` and pass, including in the "Plataforma e2e" job. CMB-30 is closed with them.

### 19.21 What platform.md P10 leaves

platform.md P10 (its §19.19) leaves the end-to-end harness that P8 uses for `platform/e2e/progress_test.go`:

- **The package:** `platform/e2e`, with the `e2e` tag (`ELDMARK_GODOT=<Godot> go test -tags e2e ./e2e`), a
  `TestMain` that imports the project and the "Plataforma e2e" CI job, which runs the whole package: a
  `progress_test.go` with the same tag enters on its own.
- **What P8 uses as is:** `New(t)` (the `serve` platform with P7's real store on a fresh database,
  `test_world` as the entry zone of both realms, 1 s heartbeat), `NewAccount`, `StartZone("--debug-commands", …)`,
  `StartBot(acc, "--bot-scenario=progress", …)`, `Bot.ReadReport` (the whole report in `Raw`), `Process.Kill` and
  `CheckBooks`, which already checks the books for `TestProgressCrash` (per definition, Σ `count_delta` = Σ `count` of
  the live items; per currency, Σ `delta` = balance; a single STARTER_KIT).
- **What P8 was missing (now in `progress_test.go`):** the `admin` account (SQL on `h.Pool` or the `admin` command) and the comparison with `Load`
  (`progress.New(rules, nil).Load` on `h.Pool`). `TestZoneCrash` already kills the zone with `--save-interval=5` and re-enters
  with the same character on another instance without repeating the kit.
