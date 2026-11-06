# Eldmark · Phases 6-8: items, equipment, loot, crafting and economy

Design of everything a character wears, finds, makes and spends once the game has PvE content: equipment slots, armor categories
and load (PRG-05, PRG-06), item level and the stat scale (PRG-55), rarity and affixes (PRG-20, PRG-53), loot and its delivery
(PRG-21), durability (PRG-24), merchants (PRG-23), consumables (PRG-56, PRG-57), bag and bank expansions (PRG-25, PRG-60),
professions with gathering, refining and crafting (PRG-26, PRG-27, PRG-43), upgrades, gems, reforging and salvage (PRG-58, PRG-59),
the economy and its telemetry (PRG-29, PRG-30, PRG-61), the visual sets per realm and the data format (PRG-52).

It extends the item model, the authoritative inventory and the ledger of [progression.md](progression.md) (§2, §4, §5), which stay
the reference for what is not said here, and builds on the damage formula and the dodge by data of [combat.md](combat.md) (§2, §4.4),
the consumables of [abilities.md](abilities.md), the art direction and the per-realm recoloring of [art.md](art.md) and the
localization of content data of [localization.md](localization.md). Character growth (curve, attributes, mastery, talents,
specializations, normalization of Eldrun) is in [advancement.md](advancement.md); weapons and abilities are in [weapons.md](weapons.md); NPCs and
their loot tables in [npcs.md](npcs.md); quests in [quests.md](quests.md). Code paths are relative to the repository root.

Clock note: the simulation runs at **60 Hz** and snapshots at 30 Hz ([networking.md](networking.md) §1). Durations below are seconds and
become ticks on load, as [combat.md](combat.md) §0 requires.

Everything marked **provisional** is a first number to be measured, not a promise.

---

## 0. Decisions

The "#" column is the id of the integrated design (it has the same numbers in [advancement.md](advancement.md) §0). The stat law of I19 and
the normalization of I22 are decided in that document; they are repeated here only as far as items need them.

| # | Question | Decision | Why |
|---|---|---|---|
| I19 | How do item stats scale? | **Item level per instance (ilvl) 1-60** and effective level `eff_ilvl = ilvl + upgrade` (0-10); `k(eff_ilvl) = 1 + 0.03·(eff_ilvl − 1)`; all the stats of an item are multiplied by **`k(eff_ilvl) / k(52)`** (0.40 at item level 1, 1.10 at 60, 1.21 at eff_ilvl 70). The CSV values are still written "at item level 60". **Equipment score (ES)** = 10 × the weighted mean of eff_ilvl: 600 at level 60 and 700 at most | One scale for armor, damage, affixes and gems. Upgrades do not invent a second progression: they raise eff_ilvl. It replaces the GS 100 → 500 → 600 of the earlier proposal. The reference character wears item level 52 (advancement.md I18) |
| I34 | How many slots? | **11**: 2 weapons, head, chest, hands, legs, feet, amulet, 2 rings and earring; tabard reserved. Sword and shield is still one object. Gathering tools take no slot: the best one in the bag is used | Jewelry is not seen, so it gives affix depth at no art cost. With tools in the bag no interface or replication is needed for them |
| I35 | Armor categories | **Three** (cloth, leather, plate), weight only on worn armor. Load: light ≤ 13.0, medium ≤ 21.0, heavy > 21.0. Dodge 5.5 / 4.5 / 3.0 m for 250 / 300 / 350 stamina; regeneration delay 0.5 / 0.6 / 0.8 s; traits: light +10 % damage, medium +5 %, heavy −15 % stamina when blocking and −15 % control duration. Speed does not change | The "New World" identity PRG-06 asks for. Weapons weigh nothing: the weapon never pushes you toward a load. Against the reference (medium) light takes ×1.18 and heavy ×0.86 (§3.3) |
| I36 | What does rarity change? | **Only affixes** (0 / 1 / 2 / 3 / 3 + trait) and sockets. Affixes have a **fixed magnitude per eff_ilvl**; a catalog of u16 ids, append-only; an own **PCG32**; every transformation retires the `uid` and creates another | An epic of item level 30 does not crush a common of 40: level is vertical, rarity is horizontal. No "perfect roll" and no endless rerolling |
| I37 | How does loot arrive? | **Personal loot** (contribution ≥ 10 %) **straight into the bag**; if it is full, into a **satchel** (container 3, 24 slots, take-out only); personal chests with a lock; **in RvR zones NPCs drop no gear**; no skinning: hides come from loot | Saves entities, interactions and network. The NPC proposal had a "loot bag" and "skinning" as interactions: removed |
| I38 | Death penalty | **Durability**: −10 % in PvE and −5 % in RvR; use wears down but never below 1 ‰ (nothing breaks in combat) | Closes the pending decision. No stat changes in mid-combat, so prediction is not disturbed |
| I39 | Binding | Bind on equip in general; bind on pickup for war gear, quest rewards, legendaries and Ember Shards; from +6, bound. What is bought with merits, essences, rough gems and Ember Shards cannot be sold | Closes the pending decision. Binding at +6 avoids laundering Shards by selling items |
| I40 | Economy | **Per realm**, currencies per character: gold 1, merits 2, **veteran seals 3** | Closes the pending decision |
| I41 | Professions | **8** (Mining, Logging, Gathering; Smithing, Leatherworking, Carpentry, Alchemy, Jewelcrafting), level 1-60, materials **G1-G6 by bands of 10 *item* levels** (not zone levels) | Each zone places the nodes of the grades its level range covers (§10.1) |
| I42 | Upgrades | +1…+10 with guaranteed success; +6…+10 from item level 50 with **Ember Shards** (bound, from Eldrun); gems 7 × 5 qualities; reforging one affix; salvage | Predictable gold sinks without the frustration of failing. Shards tie the end of the game to the war without touching the Embers of the realm treasury (GUE-22) |
| I43 | Which affixes exist? | **Removed:** stamina regeneration, dodge cost and ability cooldown (they are predicted, advancement.md I21). **Added:** "ability damage of ‹family›" and "block cost". The base of the **earring** is now tenacity (−‰ duration of controls); the **emerald** is block cost. A complete epic set at item level 60 gives at most **+35 % PvE efficacy** over a common one of the same level (validator) | Affixes touch server values only. Fewer prediction divergences |
| I44 | Gold | Income and sinks per band (§15, 138 g/h in 1-10 up to 1 152 in 51-60); NPC death `G(L)`; quest gold in fractions of `g_ref(L)` (main 0.08, side 0.05, finale 0.16); the specialization and talent sinks of advancement.md | Quests gave `10 + 4L` gold per main quest: 807 gold in Hondal, 4 times the economy. With `g_ref` it is about 320 |
| I22 | Normalization | **Defined in [advancement.md](advancement.md) §10.** In normalized zones each slot counts as `eff_ilvl = clamp(52 + 0.2·(eff_ilvl − 50), 52, 54)`; non-attribute affixes and gems ×0.25 with a joint cap of 3 %; PvE affixes 0; **elixirs and food do nothing** | The earlier [55, 65] clamp and ×0.75 affixes are removed: they gave 11 % from gear alone |
| I62 | Names | **Ember Shard** (Esquirla de Brasa in `es.po`), the bound material of Eldrun for upgrades | Quests called the same material "Ember Fragment": one name |
| I64 | Data format | Numeric tables are **CSV** and a deterministic generator writes the `.tres`, with a test that requires the repo to be its output; unique items (legendaries, quest items) are hand-written | About 350 definitions can only be balanced in a spreadsheet, and the `.tres` stays reviewable text |
| I66 | Registry | Containers **3 LOOT_SATCHEL** and **4 QUEST**; the ledger reasons and operation kinds of [progression.md](progression.md) §5.3; messages 0x68-0x6D | One registry for all documents |
| — | Visual identity | Item data is realm-independent; its appearance follows the **wearer's** realm (an "Iron Cuirass" is one definition, drawn with the palette and pieces of the wearer's realm) | Content is made once, not three times. The economy is per realm, so items do not cross realms |
| — | Crafted rarity | **Deterministic**: crafted gear is uncommon; with essences it becomes rare or epic; with an affix seal one affix is chosen | Crafting gives control and loot gives chance, so they do not compete |

---

## 1. Scope: the first vertical slice and what comes later

The first vertical slice (CV1, "Hondal: from Granvik to the Choice") needs only the equipment loop. The rest is designed here so that
nothing is redone, but it is built later.

| In the first vertical slice | After it |
|---|---|
| 11 slots | Gathering, refining and crafting with professions (G1-G2 first, in Isenholm) |
| Armor G1: light, medium and heavy; jewelry G1 | Upgrades +1…+5, gems, reforging and salvage (phase 6, after the slice); +6…+10 with Ember Shards and war gear (phases 7-8) |
| Load classes (dodge, regeneration delay, traits) | Bank and bag expansions |
| Rarity and affixes; item level per instance | Long consumables (elixirs, rations, oils, gatherer's brew) and the `USE` operation |
| Personal loot, satchel and notices | Legendaries with traits, sets with 2- and 4-piece bonuses (phase 8) |
| Durability and repair | Armor grades G2-G6 and their visual grades (with each band of the world) |
| Merchant: buy, sell and buy back | Market of the realm (PRG-36), trade and mail |
| Health potions by grade and the tonic | |

Visuals in the slice: light and medium with the free Quaternius Peasant and Ranger pieces; heavy plate of Vardheim, visual grade I,
made in Blender (§16).

---

## 2. Equipment slots

The EQUIPMENT container goes from 7 to **11 slots** (`InventoryState.EQUIPMENT_SLOTS`). Slots 0-6 keep their number (the schema already
admits `slot` up to 119).

| Slot | `EquipmentSlot` | `ItemDefinition.EquipSlot` | Visible | Durability | Weight |
|---|---|---|---|---|---|
| 0, 1 Weapon 1 and 2 | WEAPON_1, WEAPON_2 | WEAPON (1) | Yes (as today) | Yes | 0 |
| 2 Head | HEAD | HEAD (2) | Yes (hides hair, or hair and beard, §16) | Yes | By category |
| 3 Chest | CHEST | CHEST (3) | Yes | Yes | By category |
| 4 Hands | HANDS | HANDS (4) | Yes | Yes | By category |
| 5 Legs | LEGS | LEGS (5) | Yes | Yes | By category |
| 6 Feet | FEET | FEET (6) | Yes | Yes | By category |
| 7 Amulet | AMULET | AMULET (7) | No | No | 0 |
| 8, 9 Rings | RING_1, RING_2 | RING (8), valid in both | No | No | 0 |
| 10 Earring | EARRING | EARRING (9) | No | No | 0 |
| (reserved) 11 Tabard | TABARD | TABARD (10) | Yes, over the chest | No | 0 |

- The tabard is reserved for PRG-40 and SOC-33 (heraldry). In Eldrun it always reads on top (PRG-40).
- Invariant I10 of [progression.md](progression.md) §3.2 is rewritten: "EQUIPMENT contains in each slot only definitions of its
  `EquipSlot`; the active weapon slot holds a weapon".
- CANNOT_EQUIP (code 4 of [progression.md](progression.md) §4.2) also fires when the instance's `item_level` is above the character's level (the
  `required_level` of the definition becomes the minimum of its band).
- Equipping stays out of combat and with no action in progress ([progression.md](progression.md) §0). When armor changes, the server
  recalculates the load and the derived sheet (PRG-01, PRG-04) and imposes it at the end of the tick, like `set_weapons`.

---

## 3. Armor: categories, weight and load (PRG-06)

### 3.1 Pieces

5 slots × 3 categories × 6 grades = **90 generated armor definitions**. Piece names (the English goes into the `.tres`, the Spanish into `es.po`):

| Slot | Light (cloth) | Medium (leather) | Heavy (plate) |
|---|---|---|---|
| Head | Hood | Leather Cap | Helm |
| Chest | Tunic | Jerkin | Cuirass |
| Hands | Gloves | Bracers | Gauntlets |
| Legs | Breeches | Leggings | Greaves |
| Feet | Shoes | Boots | Sabatons |

The name carries the material of its grade: "Linen Tunic", "Tanned Leather Jerkin", "Iron Cuirass" (§10.1).

### 3.2 Weight (in tenths, integer) and armor at item level 60

| Slot | Weight L / M / H | Physical armor L / M / H | Elemental armor L / M / H |
|---|---|---|---|
| Head | 15 / 25 / 40 | 30 / 65 / 101 | 48 / 57 / 60 |
| Chest | 35 / 60 / 90 | 70 / 151 / 234 | 112 / 133 / 140 |
| Hands | 10 / 15 / 30 | 28 / 60 / 94 | 45 / 53 / 56 |
| Legs | 25 / 40 / 60 | 44 / 95 / 147 | 70 / 84 / 88 |
| Feet | 15 / 20 / 30 | 28 / 60 / 94 | 45 / 53 / 56 |
| **Full set** | **100 / 160 / 250** | **200 / 430 / 670** | **320 / 380 / 400** |

The armor of each piece is `round(value_60 × k(eff_ilvl) / k(60))`, with k(60) = 2.77 (the same law as I19 with the reference at 52). Physical
armor applies to SLASHING, PIERCING and BLUNT, and elemental armor to the elemental types (fire, frost, light), with the formula that
already exists: `damage × 1000 / (1000 + armor)`, now **relative to the reference**: `final = raw · (1000 + armor_ref) / (1000 + armor)`,
with `armor_ref` = the medium set at eff_ilvl 52 (393 physical; 347 elemental by the same law) (advancement.md I20). The parameter `armor` of
`DamageFormula.compute` is split in two by `is_physical` (CMB-31). The table below is the absolute reduction of the full set (physical /
elemental), all pieces of the same eff_ilvl; what the player feels is the ratio to the reference.

| eff_ilvl | Light | Medium | Heavy |
|---|---|---|---|
| 1 | 6.7 % / 10.4 % | 13.4 % / 12.0 % | 19.5 % / 12.6 % |
| 20 | 10.2 % / 15.3 % | 19.6 % / 17.7 % | 27.5 % / 18.5 % |
| 40 | 13.6 % / 20.1 % | 25.2 % / 23.0 % | 34.4 % / 23.8 % |
| 60 | 16.7 % / 24.2 % | 30.1 % / 27.5 % | 40.1 % / 28.6 % |
| 70 (+10) | 18.2 % / 26.2 % | 32.3 % / 29.6 % | 42.6 % / 30.7 % |

Light protects more against the elemental: it is a niche against the Arcanist and the staves.

### 3.3 Load

| Load | Total weight (tenths) | Dodge | Duration | Invulnerable | Cost | Stamina regeneration delay | Trait |
|---|---|---|---|---|---|---|---|
| Light | ≤ 130 | Roll of 5.5 m | 0.45 s | 0.05-0.33 s | 250 | 0.5 s | +10 % damage dealt |
| Medium | 131-210 | 4.5 m (today's `sword_dodge.tres`) | 0.45 s | 0.05-0.30 s | 300 | 0.6 s (today) | +5 % damage dealt |
| Heavy | > 210 | Step of 3.0 m | 0.50 s | 0.05-0.25 s | 350 | 0.8 s | −15 % stamina per blocked point and −15 % duration of controls received |

- Mixes have margin: light with a medium cuirass weighs 125 and is still light. Medium with a heavy cuirass and greaves weighs 210 and
  is still medium. Adding the heavy helm makes 225 and it becomes heavy.
- **Running speed does not change** with the load: prediction is simpler and nobody runs faster than another in the RvR.
- **What is predicted:** the dodge and the regeneration delay (stamina is predicted). They travel in `CombatState` as `load_class` (bits 10-11 of the
  `mana` u16, [abilities.md](abilities.md) §3.1), which the server imposes when it confirms an equipment change, like `set_weapons`. The load tables go in
  `CombatRules.load_classes` and enter `prediction_hash`. Damage and controls are resolved by the server only. The `DodgeDefinition` of
  each weapon becomes the medium base and the load applies its factors.
- **Against the reference** (medium, 393 armor at eff_ilvl 52): light (183 armor) takes ×1.18 damage and heavy (612) ×0.86 (advancement.md §11).
- A short step clip is needed for the heavy one (ART-49): UAL only brings `Roll`.
- **Balance:** the weapon `.tres` are at the reference, so a medium character at eff_ilvl 52 plays today's balance; light and heavy are balanced
  against it by CMB-31 with three example sets, lowering `armor_*_60` in the CSV without touching code if the TTK drifts.

---

## 4. Item level, scale and equipment score (PRG-55)

### 4.1 One scale

`k(eff_ilvl) = 1 + 0.03 × (eff_ilvl − 1)`; the stat factor against the reference is `k(eff_ilvl) / k(52)`.

| eff_ilvl | 1 | 10 | 20 | 30 | 40 | 50 | 52 | 54 | 60 | 70 |
|---|---|---|---|---|---|---|---|---|---|---|
| k | 1.00 | 1.27 | 1.57 | 1.87 | 2.17 | 2.47 | 2.53 | 2.59 | 2.77 | 3.07 |
| k / k(52) | 0.40 | 0.50 | 0.62 | 0.74 | 0.86 | 0.98 | 1.00 | 1.02 | 1.10 | 1.21 |

Going from +0 to +10 at item level 60 gives +10.8 % in stats.

| What scales with k(eff_ilvl) | How |
|---|---|
| Weapon power | `raw = base × load × crit × damage_scale × k(eff_ilvl of the weapon)/k(52)`. The weapon `.tres` hold today's numbers, which are the reference, so a weapon at eff_ilvl 52 deals exactly today's damage |
| Armor | §3.2: `round(value_60 × k(eff_ilvl)/k(60))` |
| Jewelry base and affixes | `round(value_60 × k(eff_ilvl)/k(60))`: at item level 1 they are 36 % of the value at 60 and at eff_ilvl 70 111 % |
| NPC of level L | Its weapon uses k(L) (decided by NPC design, coherent with this) |

Gems do not scale: their value depends on their quality (§11.3). Armor, jewelry and affixes are written in the CSV "at item level 60";
weapons are written at the reference. Both are the same law: the factor against the reference is `k(eff_ilvl)/k(52)`.

### 4.2 Item level of an instance

- Loot gives `ilvl = clamp(npc_level + d, band_min, 60)`, with d ∈ [−2, +1] on ordinary creatures and [0, +2] on bosses. Quests and merchants
  give a fixed ilvl. Crafting gives the ilvl of §10.5.
- `required_level = the instance's ilvl`, which does not rise with upgrades.
- Grade of a definition = `ceil(ilvl / 10)`. Definition G*n* covers item levels 10n − 9 to 10n.

### 4.3 Equipment score (ES)

`ES = round(10 × Σ(slot_weight × eff_ilvl_slot) / Σ slot_weight)`. Weights: each weapon 2; chest 1.5; the rest of the armor 1; each jewel
0.75 (Σ = 12.5). An empty slot counts 0, and a broken item counts its eff_ilvl (it counts for ES although it gives no stats). It is the
number shown to compare ("Equipment 583"), the one zones recommend (≈ 10 × level) and the one PRG-31 reads. At level 60 it is 600 with
no upgrades and 700 at most. In a normalized zone ES is shown as the compressed one (advancement.md §10).

---

## 5. Rarity and affixes (PRG-20)

### 5.1 Rarities

| Rarity | Affixes | Sockets | Value multiplier | Repair multiplier | Color (UI-50) |
|---|---|---|---|---|---|
| 0 Common | 0 | 0 | ×1 | ×1.0 | Gray |
| 1 Uncommon | 1 (attribute) | 0 | ×2 | ×1.25 | Green |
| 2 Rare | 2 (attribute + 1) | 1 | ×4 | ×1.5 | Blue |
| 3 Epic | 3 (attribute + 2) | 1 | ×8 | ×2.0 | Purple |
| 4 Legendary | 3 fixed + a unique trait | 2 | ×16 | ×2.5 | Orange |

The first affix always comes from the attribute group (the five of PRG-17), biased by category: heavy favors STR and CON, medium DEX
and CON, light INT and FOC, and jewelry has no bias. It is rolled even if PRG-17 is not there yet: until then it does nothing.
Legendaries are hand-written definitions with their affixes and trait. The trait is an affix of family TRAIT and fits in the 6 of
`ItemInstance` (4 used at most).

### 5.2 Affix catalog (values at item level 60; ‰ unless said otherwise)

Ids `u16`, **append-only**, frozen in `data/items/affix_ids.txt` like `appearance_ids.txt` (the database stores the ids in
`affixes integer[]`).

| Family | Value at 60 | Slots | Weight | In normalized zones |
|---|---|---|---|---|
| +Strength / Dexterity / Intelligence / Focus / Constitution | +8 points | All | (attribute group) | Counted in the total, which is rescaled to 143 |
| Max health | +40 ‰ | Chest, legs, amulet | 10 | ×0.25, joint cap |
| Physical armor | +60 ‰ | Armor | 10 | ×0.25 |
| Elemental armor | +80 ‰ | Armor, earring | 8 | ×0.25 |
| Resistance to slashing / piercing / blunt / elemental | +50 ‰ each | Armor, earring | 6 each | ×0.25 (closes what CMB-07 lacked: resistances by type) |
| Block cost | −80 ‰ | Hands, chest, weapons with a shield | 6 | ×0.25 |
| Tenacity (duration of controls received) | −80 ‰ | Head, chest | 5 | ×0.25 |
| Damage with ‹weapon family› | +50 ‰ | Weapon of that family, rings, hands | 10 | ×0.25 |
| Ability damage of ‹weapon family› | +80 ‰ | Weapon of that family, head, amulet | 6 | ×0.25 |
| Heavy attack damage | +60 ‰ | Weapons, rings | 6 | ×0.25 |
| Backstab damage | +80 ‰ | Weapons, rings | 5 | ×0.25 |
| Healing done | +60 ‰ | Life staff, amulet, rings | 6 | ×0.25 |
| Healing received | +50 ‰ | Chest, amulet | 5 | ×0.25 |
| Potion efficacy | +80 ‰ | Hands, amulet | 5 | 0 (potions are fixed) |
| Damage against ‹NPC family› | +80 ‰ | Weapons, rings | 8 | **0** (PvE only) |
| Damage received from ‹NPC family› | −60 ‰ | Armor | 8 | **0** |
| Durability loss | −150 ‰ | Anything with durability | 3 | — |
| Gathering speed / yield | +100 ‰ / +80 ‰ | Tools only | — | — |

- The same family does not repeat on an item (exclusive group). With the weapon families ([weapons.md](weapons.md)) and 4-5 NPC families ([npcs.md](npcs.md))
  there are about 50 ids.
- **No affix touches a predicted value** (advancement.md I21): the old affixes of stamina regeneration, dodge cost and ability cooldown
  are gone. Equipment changes only out of combat anyway (§9), but the predicted state is kept free of per-character values.
- Legendary traits use **deterministic triggers** ([combat.md](combat.md) §0: no chance in combat): on closing the combo, on dodging a hit in
  the invulnerable frames, on a parry, on releasing a fully charged heavy attack, on a knockdown or below 30 % health (once every 60 s). Their
  effects are states that already exist (`bleed`, `slowed`, `rooted`, `damage_up`). They need a trigger system on the server, the passive
  system of advancement.md §7.3.
- **Validator:** a complete epic set at item level 60 gives at most **+35 % PvE efficacy** over a common set of the same item level.

### 5.3 Generation

The generator is pure and shared (`ItemRoller`): with the seed, the context (source, NPC item level, profile and the player's families)
and the catalogs it returns definition, ilvl, rarity and affixes. It uses an own **PCG32** (`SeededRng`, with test vectors) and not
`RandomNumberGenerator`, so as not to depend on the engine not changing between versions. The seed is saved (`seed` u32) for audit and
tests. The results (ilvl, rarity and affixes) are saved too, so changing the algorithm does not alter items that already exist.

---

## 6. Jewelry

3 types × 6 grades = 18 definitions (made by Jewelcrafting; loot gives them too). Base at item level 60:

| Jewel | Base stat | Affixes it admits |
|---|---|---|
| Amulet | +40 ‰ max health | Health, healing, ability damage, potions and attributes |
| Ring (×2) | +30 ‰ damage with all weapons | Damage by family, heavy, backstab, PvE and attributes |
| Earring | **Tenacity** −50 ‰ duration of controls received (provisional) | Resistances, elemental armor, block cost and attributes |

The earring no longer admits the tenacity affix (it is its base). The stamina regeneration of the earlier proposal is gone (I43).

---

## 7. Weapons as items

The weapon domain fixes the families, their kits and their trees ([weapons.md](weapons.md)). From the item side:

- One weapon definition per **family × grade** (`ref_id` = the weapon of `CombatCatalog`; the kit does not change between grades). With 10
  families at launch that is up to 60 definitions; the grade gives `k(eff_ilvl)` and the affixes.
- Weapons with a shield ("sword and shield") remain one object. If weapon design separates the shield, a secondary-hand slot will be needed
  (open question, recommendation: keep one object while there is no second one-handed weapon).
- Metal weapons are made in Smithing; bows and staves in Carpentry. Staves also carry a jewel or catalyst from Jewelcrafting, to give it
  demand.
- The appearance per grade travels as `visual_id` (§16), separate from the `weapon_id` of `CombatState`.
- A cheap practice weapon of each family is sold in the capital (advancement.md §16).

---

## 8. Loot (PRG-21)

### 8.1 Rarity profiles (weights)

| Profile | Common | Uncommon | Rare | Epic | Legendary |
|---|---|---|---|---|---|
| `trash` (normal creature) | 70 | 24 | 5 | 1 | 0 |
| `elite` (elite or named) | 0 | 55 | 35 | 9 | 1* |
| `boss` (zone or dungeon boss) | 0 | 0 | 60 | 35 | 5* |
| `chest` (point-of-interest chest) | 40 | 40 | 17 | 3 | 0 |

\* Only if the table has a named legendary; otherwise it is added to epic.

### 8.2 What each type drops

| NPC type | Gold | Gear | Materials | Notes |
|---|---|---|---|---|
| Normal | G(L), always | 6 % (1 `trash` roll) | 35 %: those of its family (hides on beasts, scraps on humans, Hollow Ash on the Hollows) | |
| Elite | 3 × G(L) | 40 % `elite` | 1-2, always | |
| Named | 10 × G(L) | 1 `elite` and a 25 % of another | 2-3 | Respawns every 20-40 min |
| Boss | 25 × G(L) | 2 `boss` and a 10 % of the named item | 3-5 and a 20 % of a rough gem | Per-character lock (timer `boss:<id>`) |
| RvR zone NPC | G(L) | **Never** (I37) | Hollow Ash and a 5 % of an Ember Shard (Eldrun only) | The captain and the capture hand out a chest (PRG-35) |

`G(L) = max(1, round(0.5 + 0.035 × L^1.3))`: 1 (L1-10), 2 (L15-20), 3 (L30), 5 (L40), 6 (L50), 8 (L60). It is coherent with today's
figures (Hollow 2, captain 50); in the NPC tables it is adjusted by category.

### 8.3 Smart loot

Of the gear that drops, 50 % of the weapons are of one of the two families the player has equipped and 50 % of the armor is of their
current load category. The rest is random. It is decided with the same seed, so it is reproducible.

### 8.4 Delivery

- **Straight into the bag** when the NPC dies, for each living or dead contributor who is still in the zone. Gold goes directly. The owner
  receives LOOT_NOTICE with a notice in the rarity color; from rare, also a cosmetic flash over the corpse that only they see.
- **Bag full** → the **satchel** (container 3, 24 slots). Items are taken out to the bag with MOVE; nothing can be put in. If the satchel is
  also full, the item of least base value is lost with the event LOOT_LOST (reason 84) and a notice.
- **Chests** (MUN-16) are personal. Each character opens each chest once per lock (30 min at points of interest and daily at the end
  of a dungeon; timer `chest:<id>` in `character_timers`).
- **Quests** ([quests.md](quests.md)) pick 1 of up to 3 items with a fixed ilvl, uncommon (side quests) or rare (story), bind on pickup. Quest objects live in
  container 4 QUEST.
- **Group:** each contributing member makes their own roll (SOC-23 only shares XP and credit).

---

## 9. Durability and repair (PRG-24)

| Rule | Value |
|---|---|
| Range | 0-1000 ‰ (already in the instance). Jewels have no durability |
| Death in PvE (executed included) | −100 ‰ to everything equipped with durability |
| Death in an RvR zone (Vado Gris, Eldrun) | −50 ‰ |
| Use | Active weapon −1 ‰ every 10 hits that deal damage; each armor piece −1 ‰ every 10 hits received. **It does not go below 1 ‰** |
| Tools | −2 ‰ per gathering (500 uses) |
| Broken (0 ‰) | Gives no stats: armor 0, affixes 0 and a weapon at k = 1 with no affixes. It is still seen and used. Warnings at 250 ‰ (yellow) and 0 (red) |
| Repair cost | `ceil(missing_‰ × common_base_value(ilvl, slot) × MR[rarity] × (1 + 0.1 × upgrade) / 1000)` at the armorer |
| Repair kit | +250 ‰ to everything equipped of ilvl ≤ 10 × the kit's grade, out of combat and anywhere (§12) |
| Network | Durability changes are grouped in DURABILITY_UPDATE (at most one every 30 s, when crossing 250 or 0 and on death); they do not go in INVENTORY_DELTA |

Cost of repairing at item level 60 after a PvE death (2 weapons and 5 pieces): 95 gold common, 143 rare, 190 epic. In RvR, half. A
common item-level-60 cuirass that is broken costs 156 to repair and an epic one 312.

---

## 10. Professions: gathering, refining and crafting (PRG-26, PRG-27, PRG-43)

Built after the first vertical slice (§1), G1-G2 first.

### 10.1 The ladder of materials

Grades G1-G6 follow **item levels** in bands of 10 (G*n* covers item levels 10n − 9 to 10n). Each zone places the nodes of the grades its
level range covers; moving a band does not change systems, only rows of the generator.

| Grade (item levels) | Mining: ore → ingot | Logging: log → plank | Gathering: fiber → cloth | Gathering: herb | Beast loot: hide → leather |
|---|---|---|---|---|---|
| G1 (1-10) | Iron | Pine | Linen | Yarrow | Raw Hide → Tanned Leather |
| G2 (11-20) | Black Iron | Ash | Hemp | Bloodwort | Thick Hide → Thick Leather |
| G3 (21-30) | Crag Steel | Yew | Wild Silk | Bitterroot | Crag Hide → Hardened Leather |
| G4 (31-40) | Orichalcum | Ironoak | Frostcotton | Frostbloom | Warg Hide → Warg Leather |
| G5 (41-50) | Moonsilver | Ebony | Ash Fiber | Ashlily | Ash Hide → Ash Leather |
| G6 (51-60) | Emberite (max-level zone and Eldrun) | Emberwood | Ember Thread | Embermoss | Scorched Hide → Ember Leather |

Which tiers each zone places (world design, [advancement.md](advancement.md) §1.1 bands):

| Band | Vardheim | Solmarch | Askarra | Tiers placed | Dungeon |
|---|---|---|---|---|---|
| 1-10 | Hondal | Amber Fields | Thal Oasis | G1 | — |
| 10-20 | Skarven | Lirien Forest | Ruhn Canyons | G1-G2 | D1 (15-19) |
| 20-32 | Grimfell | Morvel Marsh | Ash Waste | G3-G4 | D2 (24-29) |
| 32-45 | Hrimvald Glacier | Vaucelle Heights | Qesh Salt Flats | G4-G5 | D3 (35-39), D4 (41-45) |
| 45-60 | Wolf March | Penitent Plains | Ossar Forges | G5-G6 | D5 (50-55), D6 (60) |

Besides: **rough gems** (7 types, from veins), merchant **reagents** (Flux, Tannin, Resin, Mordant, Distilled Water; 2 gold each),
salvage **essences** (lesser, rare, epic and legendary), **Tempering Stone** (merchant, 15 gold), the **Ember Shard** (Eldrun, bound) and
**Hollow Ash** (from the Hollows; for alchemy).

### 10.2 Refining

- G1: 4 raw material + 1 reagent → 1 refined.
- G*n* ≥ 2: 4 raw of G*n* + 1 refined of G*n*−1 + reagents (1 in G1-G2, 2 in G3-G4, 3 in G5-G6) → 1 refined.
- Done in batches (up to 50) at the station: Smelter for metal, Tannery and Loom for leather and cloth, Sawmill for wood.

### 10.3 Gathering nodes

| Node | Profession | Tool (from the bag, grade ≥ the node's) | Channel (cut by damage) | Yield | Respawn | XP |
|---|---|---|---|---|---|---|
| Vein | Mining | Pickaxe | 3.0 s | 2-4 ore; 4 % of a rough gem | 300 s | 15 × G |
| Fellable tree | Logging | Axe | 3.0 s | 2-4 logs | 240 s | 15 × G |
| Fiber plant | Gathering | Gatherer's knife | 2.0 s | 2-3 fibers | 180 s | 12 × G |
| Herb | Gathering | Gatherer's knife | 2.0 s | 1-2 herbs | 240 s | 15 × G |

- Each tool grade above the node's takes 8 % off the channel (at most −40 %).
- Gathering a node of G*n* asks a profession level ≥ 10·(*n* − 1) + 1. Nodes are shared and their state travels by OBJECT_STATE (GUE-09).
- The yield may vary at random: the "no chance" rule of [combat.md](combat.md) §0 is for combat only.

### 10.4 Professions and stations

| Profession | Station (capital, MUN-21) | Refines | Makes |
|---|---|---|---|
| Smithing | Smelter and Forge | Ingots | Heavy armor, metal weapons, pickaxes and axes, metal repair kits; **upgrade +N** is done at the Forge (no profession requirement) |
| Leatherworking | Tannery and Loom | Leather, cloth | Light and medium armor, bag expansions, leather repair kits |
| Carpentry | Sawmill and Workshop | Planks | Bows, staves, gatherer's knives, siege pieces (PRG-35) |
| Alchemy | Alchemy Table | — | Potions, elixirs, rations, oils, tonics and the reforging catalyst |
| Jewelcrafting | Jeweler's Bench | Gem cutting | Jewels, gems, affix seals; socketing and reforging (no requirement) |

### 10.5 Level, XP and quality (PRG-43)

- Curve: `xp_to_next(p) = round(50 × p^1.3)`, for p from 1 to 59. Cumulative: 4 845 up to level 11, 22 599 up to 21, 56 369 up to 31, 108 229 up
  to 41, 179 798 up to 51 and 262 187 up to 60.
- XP per action: gathering, the table; refining 6 × G per unit; gear 60 × G; consumable 25 × G. With a level 15 or more above what the
  recipe or node asks, 25 %; with 25 or more, 0.
- Expected gathering pace: about 150 nodes/h. That is 2.2 h up to level 11, 11 h up to 31 and **29 h up to 60**.
- **Recipes** unlock by level (G*n* from level 10·(*n* − 1) + 1). Named plans come from loot or merchants.
- **ilvl of the result:** `band_min + min(profession_level − required_level, 9)`. A smith of level 51 makes item level 51 in G6 and one of
  level 60 makes item level 60.
- **Rarity** (deterministic): uncommon by default; + 2 rare Essences → rare; + 2 epic Essences → epic. **Affix seal** (Jewelcrafting: 1 epic
  Essence + 2 refined of the grade; the seal instance stores the chosen family in `affixes`): fixes one non-attribute affix. The rest comes
  from the seed.
- **Station fee** (sink): `max(1, round(0.05 × base_value of the result))`, ledger reason `STATION_FEE` (80).
- Crafted gear sets the flag `crafted` of the instance.

---

## 11. Upgrades (PRG-58, PRG-59, PRG-37)

### 11.1 Upgrade +N (Forge)

Guaranteed success. Each +1 raises eff_ilvl by 1. Up to +5 on anything with durability; +6 to +10 only with item level ≥ 50. From +6 the item
becomes bound (I39). The base value does not change (so there is no loop with the merchant).

| Step | Gold at item level 60 | Refined of the item's grade | Tempering Stones | Ember Shards |
|---|---|---|---|---|
| +1 | 60 | 2 | 1 | — |
| +2 | 120 | 3 | 1 | — |
| +3 | 200 | 4 | 2 | — |
| +4 | 300 | 6 | 2 | — |
| +5 | 450 | 8 | 3 | — |
| +6 | 650 | 10 (G6) | 3 | 1 |
| +7 | 900 | 12 | 3 | 2 |
| +8 | 1 250 | 15 | 4 | 3 |
| +9 | 1 700 | 18 | 4 | 5 |
| +10 | 2 300 | 22 | 5 | 8 |

- Below item level 60, the gold of +1…+5 scales by `base_value(ilvl)/base_value(60)`. From +1 to +5 it adds up to 109 at item level 10, 434 at 30
  and 1 130 at 60.
- From +0 to +10 at item level 60 is 7 930 gold and 19 Ember Shards per item. For 11 slots, about 87 000 gold and 209 Shards: it is the long
  sink of the end game. Gold goes out with reason `UPGRADE` (77).

### 11.2 Sources of Ember Shards (for the war domain)

| Source | Shards |
|---|---|
| Capturing a fort or castle (each participant on the capture list) | 3 or 8 |
| Ember Rain (MUN-31), per participation | 5 |
| Daily war commission (MUN-32) | 5 |
| Eldrun NPC | 5 % per kill |
| War quartermaster (PRG-33) | 1 per 200 merits, weekly cap 20 |
| Veteran Seals (advancement.md §9.1) | A few per week (provisional cap 5) |

Goal: about 12 per hour of active war, so +10 on one piece is about 2 h and the whole set about 18 h. Shards are bound, not sold, and half of
the ones used in +6…+10 come back on salvage. They enter the ledger with the reason of their source (`LOOT` 8 for NPCs, `WORLD_EVENT` 14 for events and captures, `QUEST` 9 for commissions).

### 11.3 Gems and sockets (Jewelcrafting)

| Gem | Effect at quality 5 | Counts in normalized zones |
|---|---|---|
| Ruby | +4.0 % damage with all weapons | ×0.25, joint cap |
| Sapphire | +5.0 % elemental resistance | ×0.25, joint cap |
| Onyx | +4.0 % physical resistance | ×0.25, joint cap |
| Topaz | +4.0 % max health | ×0.25, joint cap |
| Emerald | **−6.0 % block cost** | ×0.25, joint cap |
| Amber | +6.0 % healing done | ×0.25, joint cap |
| Eld Stone (only G5-G6 veins) | +6 % damage against NPCs and −6 % damage they deal | 0 (PvE only) |

- 5 qualities (Chipped, Cut, Polished, Brilliant and Perfect), with factors 0.25 / 0.45 / 0.65 / 0.85 / 1.0. Cutting a rough gem gives quality
  `1 + floor((jewelcrafting_level − 1) / 12)`, and 3 gems of quality *q* make 1 of *q* + 1.
- Socketing a gem of quality *q* asks an item of ilvl ≥ 12·(*q* − 1) + 1. Socketing is free except for the transformation (reason `SOCKET`, 79).
  **Unsocketing:** either the gem is destroyed free or 50 % of its reference value is paid to recover it (5, 20, 60, 150 and 350 gold by
  quality). That is 7 × 5 = 35 gem definitions plus 7 rough ones.

### 11.4 Reforging (Jewelcrafting)

Changes **one** non-attribute affix, chosen by the player, for another of its slot's group that the item does not already have. Cost: 1
Reforge Catalyst (Alchemy: 2 essences of the item's rarity + 1 refined of its grade) + gold = 50 % of the item's base value (an epic item-level-60
chest: 624; reason `REFORGE`, 78). Legendary traits are not reforged.

### 11.5 Salvage (any station)

| Rarity | Refined of the grade (by category: heavy and metal weapons → ingot, medium → leather, light → cloth, jewel → ingot) | Essence |
|---|---|---|
| Common | 1 | — |
| Uncommon | 1 | 1 lesser |
| Rare | 2 | 1 rare |
| Epic | 2 | 1 epic |
| Legendary | 3 | 1 legendary |

Socketed gems come back, and half of the Ember Shards used in +6…+10 return, rounded down. Essences are not sold to the merchant (I39). The
validator checks that what is obtained by selling the salvage never exceeds what is obtained by selling the item. The input goes out with
reason `SALVAGE_INPUT` (76) and the outputs come in with `SALVAGE_OUTPUT` (16).

### 11.6 Discarded

Upgrades with a chance of failure or destruction (they frustrate and put chance into gold). Random affix values (I36). Infusion as a system
of its own (it overlaps gems and reforging).

---

## 12. Consumables (PRG-56, PRG-57)

| Family | Use | Duration | One active per | Examples and effect | Source |
|---|---|---|---|---|---|
| Health potion (R) | In combat, shared cooldown of 20 s ([abilities.md](abilities.md)) | 6 pulses in 3 s | — | Field: 30 % of max health (today's, now in %); G1-G6: 30 %…35 % | Camp refill in RvR (only the field one, bound); merchant G1-G3; Alchemy |
| **Tonic** (T) | Same | Instant | — | **+400 stamina and +300 mana** (ungraded: its effect is predicted). Replaces the stamina potion | Same |
| Elixir | Out of combat | 30 min, continues after death and with offline time (CMB-30) | Elixir | +4 / +6 / +8 to one attribute (5 types) or +5 % health or armor; grades G2, G4 and G6 | Alchemy |
| Ration | Out of combat | 20 min | Food | ×2 out-of-combat health regeneration, plus +2…+4 to an attribute from G3 | Alchemy (herb + merchant Provisions) |
| Weapon oil | Out of combat | 15 min | Oil | +6 % damage against one NPC family (PvE only) | Alchemy (Hollow Ash, herbs) |
| Repair kit | Out of combat | Instant | — | +250 ‰ to what is equipped (§9) | Smithing or Leatherworking; merchant G1 |
| Gatherer's brew | Out of combat | 30 min | Brew | +15 % gathering speed | Alchemy |
| Bag expansion | Out of combat | Permanent | — | +6 slots (§14) | Merchant or Leatherworking |

- **Keys R and T** use the highest-grade potion of their family that the player carries and can use by level. A client setting may
  prefer the field ones. The charges become `min(15, total of the family)`, not those of a definition. This changes
  `consumable_definition(i)` ([progression.md](progression.md) §2.2) to a family, a dependency of CMB.
- **The tonic** is the mana source of the magic weapons (mana is 1000, regenerates 1 per tick after 1.5 s without spending, shared between the
  two weapons; [weapons.md](weapons.md)). The "gatherer's tonic" of the earlier proposal is renamed *brew* so that "tonic" means one thing.
- **Using** is a new operation, `INVENTORY_REQUEST op 4 USE`: the same 18 B, `to_*` = `0xFF`. It is validated like a DESTROY of 1 plus "out
  of combat, alive, no action". Long effects are saved as timers `elixir:<def>`, `food:<def>`, `oil:<def>` and `brew:<def>` in
  `character_timers` (the key fits `^[a-z0-9_:]{1,48}$`). Using one of the same family replaces the previous.
- **In normalized zones** ([advancement.md](advancement.md) §10): elixirs, food and oils do nothing; only the fixed potions and the tonic act.
- About 60 definitions.

---

## 13. Merchants (PRG-23)

| Rule | Value |
|---|---|
| Buy price | `base_value` (×1) |
| Price when selling to the merchant | `floor(0.2 × base_value)`, at least 1 if `base_value > 0`; with `base_value = 0` it cannot be sold (I39) |
| Buy back | The last 10 items sold in the session, at the selling price |
| Limited stock | Only one-time purchases (the first bag expansion) and plans |

`base_value(ilvl, slot, rarity) = round(2 + 0.5 × ilvl^1.4) × slot_mult × MV[rarity]`. Common values with multiplier 1: 3 (ilvl 1), 15 (10),
35 (20), 60 (30), 89 (40), 122 (50), 156 (60). Slot multiplier: weapon 1.2; chest 1.0; amulet 0.9; legs, ring and earring 0.8; head 0.7;
hands and feet 0.6. Refined materials: 2, 4, 8, 14, 22 and 32 from G1 to G6; raw ones, a quarter.

| Capital merchant | Sells | Services |
|---|---|---|
| Armorer | Common armor G1-G2 (fixed ilvl 5 and 15), Tempering Stone | Repair |
| Provisioner | Potions G1-G3 and tonics, rations G1-G2, Provisions (ingredient), Leather Bag | — |
| Toolsmith | Pickaxe, axe and knife G1-G2, repair kit G1, the 5 reagents | — |
| Jeweler | — | Socket, unsocket and reforge |
| Forge | — | Upgrade +N |
| War quartermaster (PRG-33, for merits, at gates and own forts) | War gear item level 60 rare, with 2 fixed PvP affixes and bind on pickup; field potions; cosmetics | — |

Everyone sells for gold except the quartermaster. In the slice (§1): the armorer and the provisioner, with buy, sell and buy back; the
merchant window is opened by the service NPC of [npcs.md](npcs.md) (MUN-55) and the dialog of MUN-16. Ledger reasons `VENDOR_BUY` (67),
`VENDOR_SELL` (10), `REPAIR` (68); operation kind 10 VENDOR.

---

## 14. Bag and bank expansions

- **Bag:** 30 slots at base and +6 with each expansion, up to 60. Each is used in its order: Leather Bag (merchant, 250 gold), Reinforced
  Satchel (Leatherworking G2), Field Pack (G3), Merchant's Haversack (G4) and Travel Chest (G5). `bag_slots` only rises, with the new reason
  `BAG_EXPAND` (81) (invariant I12 of [progression.md](progression.md) is relaxed in phase 6).
- **Bank** (PRG-25, container 2): 40 slots at base and +10 per purchase up to 120, for 300, 800, 1 500, 3 000, 6 000, 12 000, 20 000 and
  30 000 gold (73 600 in total); reason `BANK_EXPAND` (82).
- **Satchel** (container 3) and **quest container** (4) do not grow: 24 slots, and 30 provisional slots for quest objects that cannot be
  sold, traded or destroyed except by the quest ([progression.md](progression.md) §4.1).

---

## 15. Economy: sources and sinks (PRG-29, PRG-30, PRG-61)

### 15.1 Targets per band (solo player, active PvE, gold per hour)

Model: 90 kills/h, 6 % gear, `trash` rarity mix, sell at 20 %; quests give 30 % of the income; 1 death/h; 6 potions and 2 long effects per
hour; 2 fast travels. **`g_ref(L)`** is the income column interpolated linearly between band midpoints (5.5, 15.5, …, 55.5); the
quest gold fractions, the respec costs and the simulator read it ([advancement.md](advancement.md) §2.6, §8.5).

| Band | Kills | Junk sold | Quests | **Income** | Repair | Potions | Elixir and ration | Travel | Fees and reagents | **Fixed sinks** | Ratio |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1-10 | 90 | 6 | 41 | **138** | 9 | 24 | 12 | 10 | 14 | **69** | 0.50 |
| 11-20 | 153 | 32 | 79 | **264** | 33 | 48 | 24 | 18 | 26 | **150** | 0.57 |
| 21-30 | 252 | 57 | 132 | **441** | 65 | 72 | 36 | 26 | 44 | **243** | 0.55 |
| 31-40 | 378 | 95 | 203 | **675** | 101 | 96 | 48 | 34 | 68 | **347** | 0.51 |
| 41-50 | 495 | 132 | 269 | **896** | 143 | 120 | 60 | 42 | 90 | **454** | 0.51 |
| 51-60 | 630 | 177 | 346 | **1 152** | 187 | 144 | 72 | 50 | 115 | **568** | 0.49 |

- **Goal:** fixed sinks take 50-60 % of the income when leveling. Upgrades +1…+5, expansions, market fees and the specialization change raise the
  total to **65-80 %**. At the end of the game, upgrades +6…+10 and reforging absorb what is saved.
- In the first slice: a player reaches level 10 with ~250 gold (just the first bag expansion); with all the sinks of 1-10 (69 g/h) about 110 is
  left. Hondal pays about 310 gold of quests and ~100 of kills in ~4.5 h; repairs and potions are the slice's sinks (about 33 g/h).
- Recommendations for other domains (they decide): quest gold in fractions of `g_ref` ([advancement.md](advancement.md) §2.6). Fast travel
  `round(3 + 0.4·L)` per jump (MUN-33, reason `TRAVEL` 83). Market: 2 % to list plus 5 % on sale (PRG-36). Mail: 2 gold plus 2 per attachment
  (SOC-28). The costs of changing specialization and resetting talents are in the same count of sinks ([advancement.md](advancement.md) §8.5).
  Turning in a quest item is the sink `QUEST_TURN_IN` (75).

### 15.2 Rules against loops (checked by the validator)

1. Selling to the merchant (20 %) is always below buying (100 %).
2. In every recipe whose inputs are all bought from the merchant (directly or in a chain): selling the result < Σ buying the inputs + fee.
3. Salvage: Σ selling what comes out ≤ selling the item.
4. What is bought with merits, essences, rough gems and Ember Shards is not sold (`base_value = 0`).
5. Upgrades do not change `base_value`.
6. Every `ref` of the loot, recipe and merchant tables exists; ilvl and levels match the band; each slot has at least 6 affix families in its
   group; affix and appearance ids are only appended.

### 15.3 Telemetry (PRG-30)

Daily aggregates per reason: gold created per source and destroyed per sink, against the table of §15.1 per level band. Items by rarity and
ilvl. Gems, essences and Shards created and consumed. Alerts: the daily sink ratio outside 0.45-0.9; a character with an hourly income more than 5
times the median of its band; a repeated `uid` (PRG-30 already asks for it). Tool `tools/economy/simulate_economy.gd` (PRG-61): with the tables and the
level curve (PRG-22) it reproduces the table of §15.1; the test demands that each band's ratio falls in 0.45-0.65.

---

## 16. Visual sets per realm with the Quaternius kit

### 16.1 What is free (CC0, already downloaded in `../Eldmark-raw/`)

| Pack | Useful pieces | Used for |
|---|---|---|
| Modular Character Outfits – Fantasy (Standard) | **Ranger**: hood, body, arms, legs, boots and shoulder piece. **Peasant**: body, arms, legs and feet. Each in male and female, with 3 texture variants | Light: Peasant with the Ranger hood. Medium: Ranger with shoulder piece. The realm's "no armor" (tinted Peasant). The inner layer of the heavy |
| Universal Base Characters (Standard) | 2 bodies (male and female) and 5 hairstyles | The base body. The female one is not in the repo yet (ART-20) |
| RPG Weapons Free (Binbun) | 70 weapons: swords, saber, spear, dagger, mace, **pickaxe**, **axe**, hammer, shovel; 7 variants of each | Tools: pickaxe and axe. The dagger as gatherer's knife. Weapons per grade (weapon domain) |
| Stylized Nature MegaKit (Standard) | Rocks, trees, ferns and plants | Nodes: veins are rocks with inlays made by script; fellable trees and plants, recolored |
| game-icons.net (CC BY 3.0; credit by author; Viscious Speed and Zeromancer are CC0) | 4 180 SVG icons | Icons of materials, consumables, gems and jewels, with the credits file its license asks (do not use the 2 of `various-artists`) |

Nothing is bought: the knight and the mage are in the (paid) Outfits Source, and the decision is "free versions of everything".

### 16.2 What has to be made (Blender by script, with the flow of [art.md](art.md) §4.9)

| Piece | Amount | How |
|---|---|---|
| Heavy plates: helm, breastplate with pauldrons, gauntlets, greaves and sabatons | 5 types × 3 realms × 3 visual grades = 45 meshes | Rigid, with **weight 1 to a single bone** and not as BoneAttachment, so they can be merged with the rest of the character (ART-35). Silhouettes per realm: nasal helm with wolf crest (Vardheim), great helm with sun visor (Solmarch), sallet with bronze crest (Askarra). Textures by numpy (`tools/blender/*_textures.py`) |
| Leather cap for the medium | 3 grades | Same |
| Trims per grade (rivets, edging, wolf, sun or anvil emblem) | About 12 | Small rigid pieces |
| Icons of armor and weapons | One per `visual_id` | A tool that makes thumbnails by rendering in Godot (`tools/icons/bake_item_icons.gd`), no AI |

### 16.3 Visual grades and readability

- **3 visual grades** per category (what ART-27 asks): I (ilvl 1-20) is only recolored; II (21-40) adds edging and a second color; III
  (41-60) adds the realm emblem and metal detail, with a faint emissive in Askarra. Light and medium are made **with shader and masks** from the
  base texture (like `realm_surface`, [art.md](art.md) §4.4), no new textures per realm and grade. The heavy carries its meshes.
- **The category reads** at a glance (cloth, leather or plate): in RvR it matters to know whether the rival is heavy. The look never reveals
  rarity or affixes. It does roughly reveal the level band, through the visual grade (open question: acceptable, since in Eldrun the level
  is normalized).
- **Catalog:** `data/items/visuals/armor_visual_catalog.tres`, append-only and frozen by `armor_visual_ids.txt`. Each entry holds id, slot,
  category, visual grade, the scene per body and realm, its layers, `hides_hair` and `hides_beard`. `ItemDefinition.visual_id` replaces
  `visual_paths`, which becomes obsolete.
- **Appearance block** in the PLAYER SPAWN: 7 × u16 = **14 B** (5 of armor and 2 of weapon, appearance index + 1; 0 = the realm's base
  clothes), the same for all realms, and the `EQUIPMENT_VISUAL` event with the same 14 B when it changes (§17.5).
- Reuse: realm guards and bandits (NPC domain) can wear these same sets.

---

## 17. Data format (PRG-52)

### 17.1 Source tables (`tools/content/tables/`, outside the export because `tools/*` is excluded)

| CSV | One row per | Key columns |
|---|---|---|
| `armor.csv` | Slot × category × grade | id, name_en, name_es, slot, class, tier, weight_t, armor_phys_60, armor_elem_60, visual_id, attr_bias |
| `jewelry.csv`, `weapons.csv`, `tools.csv` | Type × grade | id, name_en, name_es, slot, tier, ref_id, base_stat, visual_id |
| `materials.csv` | Material | id, name_en, name_es, tier, line, stack, base_value, sellable |
| `consumables.csv` | Consumable | id, name_en, name_es, family, tier, effect, magnitude, duration_s, required_level |
| `affixes.csv` | Affix family | affix_id (u16, frozen), family, value_60, unit, slots, weight, exclusive_group, pvp_scale |
| `loot_tables.csv` | Entry | table_id, kind (ITEM/GEAR/TABLE/GOLD/NOTHING), ref, weight (0 = guaranteed), count_min, count_max, min_level, max_level, rarity_profile |
| `recipes.csv` | Recipe | id, profession, station, req_level, output, out_count, inputs ("iron_ingot:4;flux:1"), xp, fee_override |
| `vendors.csv` | Article | vendor_id, item, price_override, stock, restock_s, currency |
| `gather_nodes.csv` | Node type | id, profession, tier, tool_kind, channel_s, yield, rare_drop, respawn_s, xp |

The generator `tools/content/build_items.gd` (deterministic, sorted by id) writes `data/items/<category>/<id>.tres`, `data/loot/*.tres`,
`data/crafting/recipes/*.tres`, `data/vendors/*.tres` and `data/gathering/*.tres`, each with the header `; generated by
tools/content/build_items.gd: do not edit`. It adds the `item` and `item_desc` entries to `es.po` with the tool of TEC-55. The test
`tests/test_content_tables.gd` regenerates in memory and compares with the repo, like `test_progression_rules_export`. Unique objects
(legendaries, quest items) are hand-written `.tres` in `data/items/unique/`, and the validator walks them the same way. English is in the
`.tres` and the CSV `name_es` feeds `es.po` (Spanish appears only there).

### 17.2 Resources (GDScript, shared)

```gdscript
# item_definition.gd (extends progression.md §2.1)
@export_range(1, 60) var required_level: int = 1        # goes from 40 to 60; the minimum of the band
@export_range(0, 6) var tier: int = 0                   # 0 = no grade
@export_range(0, 60) var item_level_min: int = 0        # 0 = no ilvl (materials, consumables)
@export_range(0, 60) var item_level_max: int = 0
@export var stats: ItemStats                             # null if it has none
@export var affix_pool: StringName = &""                 # generator group; empty = no affixes
@export var max_sockets: int = -1                        # -1 = that of its rarity (§5.1)
@export var visual_id: StringName = &""                  # §16.3; replaces visual_paths
@export var salvage_material: StringName = &""
@export var use_effect: UseEffect                        # out-of-combat consumables (§12)
@export var tool_kind: ToolKind = ToolKind.NONE          # PICKAXE, AXE, KNIFE
@export var quick_family: StringName = &""               # &"health", &"tonic" (R/T)
@export var tags: PackedStringArray                      # "war_gear", "legendary"...

# item_stats.gd
@export var armor_class: ArmorClass = ArmorClass.NONE    # NONE, LIGHT, MEDIUM, HEAVY
@export_range(0, 200) var weight_tenths: int = 0
@export var armor_physical_60: int = 0
@export var armor_elemental_60: int = 0
@export var base_lines: PackedInt32Array                 # pairs (affix_id, value_60): the base of the jewelry

# affix_definition.gd, in data/items/affixes.tres (append-only catalog)
@export var id: int                                      # u16, frozen in affix_ids.txt
@export var family: StringName
@export var value_60: int                                # ‰ or points
@export var slots: PackedInt32Array
@export var weight: int
@export var exclusive_group: StringName
@export var pvp_scale_permille: int = 1000               # 0 = PvE only; 250 = the normalized-zone factor (advancement.md §10)

# loot_table.gd and loot_entry.gd: rolls, entries[kind, ref, weight, count_min, count_max, min_level, max_level, rarity_profile]
# recipe_definition.gd: id, profession, station, required_level, inputs[{def, count}], output, output_count, xp
# vendor_definition.gd: id, currency, entries[{def, price, stock, restock_s}], services (REPAIR, UPGRADE, SOCKET, REFORGE)
# gather_node_definition.gd: id, profession, tier, tool_kind, channel_s, yield_min, yield_max, rare_drop, respawn_s, xp
# profession_definition.gd: id (fixed u8), kind (GATHER/CRAFT), stations; curve in data/progression/profession_curve.tres
```

None holds a `Texture2D`, `PackedScene` or `Mesh` (the rule of [progression.md](progression.md) §2.1). Icons and scenes go by path.

### 17.3 `ItemInstance` format 2

| Offset | Type | Field | Notes |
|---|---|---|---|
| 0 | u8 | format | **2** (`decode` still reads 1, with ilvl 0, upgrade 0 and no gems) |
| 1 | u64 | uid | |
| 9 | u16 | def | net id |
| 11 | u16 | count | |
| 13 | u16 | durability | |
| 15 | u8 | rarity | 0-4 |
| 16 | u8 | flags | bit0 bound, bit1 crafted |
| 17 | u32 | seed | |
| 21 | u8 | item_level | 0 = does not apply; 1-60, inside the definition's band |
| 22 | u8 | upgrade | 0-10; ≤ 5 if ilvl < 50 |
| 23 | u8 | affix_count | 0-6; matches the rarity rule except on unique items |
| 24 | n × u16 | affixes | They exist in the catalog and are valid for the slot |
| … | u8 | gem_count | 0-2, ≤ sockets |
| … | m × u16 | gems | net id of gem definitions |

Size: 25 to 41 B. **Network caps:** with 41 B per item, 30 entries do not fit in 1 200 B, so INVENTORY_DELTA and INVENTORY_FULL go to **25
entries** per message or page (25 × 44 + 10 = 1 110 B). With 120 + 11 + 24 slots that is 7 pages, inside the cap of 8. JSON
(`progress_format` 2): the usual keys plus `"item_level"`, `"upgrade"` and `"gems": ["gem_ruby_5"]`. Invariant I1 of
[progression.md](progression.md) §3.2 holds with a refinement: every transformation (upgrade, socketing, reforging) retires the old `uid` and
creates another in the same operation, with two events per transformation.

### 17.4 Database, ledger and checks

- **Migration** (the next free after the build's 0011; [platform.md](platform.md) §20): `item_instances` gains `item_level smallint not null default 0 check
  (0..60)`, `upgrade smallint not null default 0 check (0..10)`, `gems text[] not null default '{}' check (cardinality ≤ 2)` and `crafted bool not
  null default false`. The `container` check admits 2 (bank), 3 (satchel, 24 slots) and 4 (quest objects). New table `character_professions
  (character_id, profession smallint, level smallint check (1..60), xp_total bigint)`, primary key (`character_id`, `profession`) and cascade.
- **Registry of codes** ([progression.md](progression.md) §5.3 is the single registry): source reasons 14 WORLD_EVENT, **15 GATHER, 16 SALVAGE_OUTPUT, 17
  TRANSFORM_OUTPUT**, 18 VETERAN_SEAL; sinks 75 QUEST_TURN_IN, 76 SALVAGE_INPUT, 77 UPGRADE, 78 REFORGE, 79 SOCKET, 80 STATION_FEE, 81
  BAG_EXPAND, 82 BANK_EXPAND, 83 TRAVEL, **84 LOOT_LOST**; operation kinds **9 CRAFT** (refine, make, salvage, transform) and **10 VENDOR** (buy, sell,
  buy back, repair). Containers: 0 BAG, 1 EQUIPMENT (11 slots), 2 BANK, **3 LOOT_SATCHEL**, **4 QUEST**. Currency 3 veteran seals.
- **Save checks** (extending S4 and S5 of [progression.md](progression.md) §13.3; the numbers continue after S11 of [advancement.md](advancement.md)):
  **S12** ilvl inside the definition's band and upgrade ≤ 5 below ilvl 50; **S13** affix count by rarity (except unique items), affix ids in the exported
  catalog and valid for the slot, gems and sockets; **S14** nothing enters the satchel with MOVE (only with a LOOT event) and the quest container
  holds only quest items; **S15** professions: level 1-60, XP non-decreasing, only with GATHER or CRAFT operations. The exported rules gain
  `affixes`, `item_level`, `tier` and `sockets` in `items`, `professions` and `containers.3` / `containers.4`.

### 17.5 Network (the protocol version is bumped by lane L when it integrates, I65)

- **PLAYER SPAWN:** +14 B, 7 × u16 appearance index + 1 (5 armor and 2 weapon; 0 = the realm's base clothes). The block is the same for every
  realm. The event `ENTITY_EVENT EQUIPMENT_VISUAL` carries the same 14 B when it changes. (The +1 B of specialization is in
  [advancement.md](advancement.md) §14.)
- **Range 0x68-0x6F** (economy services; 0x70-0x77 stay for bank, trade and mail; the registry is in [networking.md](networking.md)):
  - `0x68` SERVICE_REQUEST: request_id, service (buy, sell, buy back, repair, craft, salvage, upgrade, socket, unsocket, reforge), net id of the NPC
    or station, ref, quantity, up to 4 entries (container, slot, uid) and the seal family.
  - `0x69` SERVICE_REPLY.
  - `0x6A` LOOT_NOTICE.
  - `0x6B` VENDOR_STOCK.
  - `0x6C` DURABILITY_UPDATE.
  - `0x6D` PROFESSION_UPDATE.
- `ServerMessages` 750-799 are for loot and economy services.
- The consequence on the inventory still arrives by INVENTORY_DELTA (with its `reason`) and WALLET_UPDATE. Gathering is an interaction (MUN-16,
  INTERACT button) with a channel.

---

## 18. Code systems

### 18.1 New

| File | Layer | What it does |
|---|---|---|
| `scripts/shared/progression/item_stats.gd`, `affix_definition.gd`, `affix_catalog.gd` | Shared | §17.2 |
| `scripts/shared/progression/item_stat_rules.gd` | Shared, pure | k(eff_ilvl), armor, contribution to the sheet (for StatBlock, PRG-01), ES, base value, sale, repair, upgrade costs |
| `scripts/shared/progression/equipment_load.gd` | Shared, pure | Weight → load |
| `scripts/shared/progression/seeded_rng.gd` | Shared | PCG32 with vectors |
| `scripts/shared/progression/item_roller.gd` | Shared, pure | §5.3 |
| `scripts/shared/progression/loot_table.gd`, `loot_entry.gd`, `loot_roller.gd` | Shared | Tables and roll |
| `scripts/shared/progression/recipe_definition.gd`, `crafting_rules.gd`, `profession_definition.gd`, `profession_rules.gd` | Shared | Recipes, ilvl and rarity of the result, XP |
| `scripts/shared/progression/vendor_definition.gd`, `gather_node_definition.gd`, `use_effect.gd` | Shared | Data |
| `scripts/shared/progression/transform_rules.gd` | Shared, pure | Upgrade, socket, reforge and salvage: inputs → outputs (the client tests them for its optimistic attempt) |
| `scripts/server/progress/loot_service.gd` | Server | On NPC death: contributors, roll, delivery and satchel |
| `scripts/server/progress/economy_services.gd` | Server | SERVICE_REQUEST: distance to the NPC or station, out of combat, whole CRAFT/VENDOR operation or nothing |
| `scripts/server/progress/durability_system.gd` | Server | Hit counters, loss on death, DURABILITY_UPDATE |
| `scripts/server/world/gather_system.gd` | Server | Nodes, channel, respawn and OBJECT_STATE |
| `scripts/client/equipment_visual.gd` | Client | PRG-05: mounts the pieces of each `visual_id` on `HumanoidVisual` by realm and body |
| `scripts/client/inventory/item_tooltip.gd`, `loot_toasts.gd`, `crafting_window.gd`, `vendor_window.gd` | Client | UI |
| `tools/content/build_items.gd`, `tools/content/validate_economy.gd`, `tools/economy/simulate_economy.gd`, `tools/icons/bake_item_icons.gd`, `tools/blender/build_plate_armor.py` | Tools | §17.1, §15, §16 |

### 18.2 Touched

- `item_definition.gd`, `item_instance.gd` (format 2), `item_database.gd` (`for_ref` with several definitions per `ref_id`: the lowest grade
  for the kit; `wire_hash` with `tier` and `max_sockets`).
- `inventory_state.gd` (11 slots, containers 3 and 4), `inventory_ops.gd` (validate armor and jewelry slots, the instance's ilvl, USE and the
  satchel), `economy_reason.gd`, `progress_json.gd`, `progression_rules_export.gd`, `starter_kit.gd` (unchanged in the slice: the kit stays
  without armor unless advancement decides otherwise).
- `combat_state.gd` and `action_machine.gd` (`load_class` and its imposition), `combat_rules.gd` (`load_classes`), `damage_formula.gd` (physical
  and elemental armor, resistances by type, weapon power and the relative mitigation), `combat_catalog.gd` (`prediction_hash`).
- `npc_definition.gd` (`level`, `family`, `loot_table`; gold comes from the curve G(L) by default).
- `progress_messages.gd` and `net_protocol.gd` (caps of 25, messages 0x68-0x6D), `net_entity.gd` (appearance block in the SPAWN).
- `player_progress.gd` (CRAFT and VENDOR operations, LOOT with uid inside the aggregated GAMEPLAY), `progress_service.gd`.
- `scripts/client/humanoid_visual.gd` and `appearance_applier.gd`; the inventory window of UI-26.
- Go: `platform/internal/progress` (migration, S12-S15, `LoadRules`) and `progression_rules.json`.

---

## 19. Dependencies

| Domain | What items need | What items give |
|---|---|---|
| Advancement ([advancement.md](advancement.md)) | The 60-level curve and the level check; the base health by level; the attribute scale (affixes of +8 at 60 assume ~59 points of level); `StatBlock` consuming the contribution of `ItemStatRules`; the normalization rule (advancement.md §10). If the specialization passives touch the load, they read `load_class` | ES, eff_ilvl, the scale k and the contribution of stats; `g_ref(L)` |
| Weapons (CMB) | The weapon families (for the affixes by family and the recipes); whether the shield is a separate slot; the potion charges per family; the trigger system for the legendary traits (advancement.md §7.3); the split of armor into physical and elemental; the short-step clip (ART-49) | The weapon power by ilvl, the load tables and the affixes of ability damage and block cost |
| NPCs (MUN-24, MUN-25) | `NpcDefinition.level`, the family and the loot table; the NPC families for affixes and oils; that RvR NPCs drop no gear | The loot tables, G(L) and the visual sets for guards and bandits |
| Quests (MUN-17, MUN-28) | "1 of 3" rewards with a fixed ilvl, the quest gold from `g_ref` and the profession quests (first recipe, first node) | The reward definitions and the quest objects (container 4) |
| World (MUN-13, MUN-22, MUN-45) | Level bands per zone, the placement of nodes by grade, and the stations and merchants in the capital (MUN-21, MUN-19) | The material grade per zone and the node lists |
| War (GUE-20/22, PRG-33/35) | Sources of Ember Shards (§11.2), capture chests and capture gold | War gear and Shards |
| Network and platform | Protocol version by integration, range 0x68, migration and S12-S15 in Go | The formats of §17 |
| Art (ART-27, ART-35) | Merging the meshes per character for Eldrun and the step clip | The appearance catalog and the piece list |
| Interface (UI-26/28/44) | Tooltip with comparison, crafting, merchant and transformation windows, and notices | The data for each view |
| Social (SOC-23, SOC-28) | That loot stays personal; the mail cost | — |

---

## 20. Backlog items

### 20.1 Rewritten

- **PRG-05** Equipment appearance: `visual_id` from an append-only catalog, the 14 B block in the SPAWN, the EQUIPMENT_VISUAL event and the look by the
  wearer's realm. Done when two clients of different realms see the same "Iron Cuirass" each with its palette and changing a piece does not
  recreate the character.
- **PRG-06** Armor and load: 90 generated definitions (5 × 3 × 6), weights and thresholds 130/210, the load table of §3.3 and `load_class` in
  `CombatState`. Done when each load gives the expected dodge distance, equal on client and server, and changing armor causes no corrections.
- **PRG-20** Rarity, affixes and ilvl: ilvl per instance 1-60, eff_ilvl, an append-only affix catalog, fixed magnitude per eff_ilvl, own PCG32 and
  `ItemInstance` format 2. Done with 10 000 rolls inside ±1.5 points of each profile and a reproducibility vector.
- **PRG-21** Loot and delivery: direct delivery, satchel (container 3), personal chests with a lock, smart loot and no gear in RvR. Done with a
  seeded roll, two contributors with independent rolls and the loss with a full satchel.
- **PRG-23** Merchants: buy at 100 %, sell at 20 %, buy back of 10, the reagents and the list of §13.
- **PRG-24** Durability: −10 % / −5 %, wear that does not go below 1 ‰, the repair formula and the kits.
- **PRG-25** Bank: 40 + 10 per purchase up to 120, with the price table.
- **PRG-26** Gathering: 3 professions, the tool in the bag and the nodes of §10.3.
- **PRG-27** Crafting and refining: 5 professions, the stations, the refining ratios, rarity with essences and the fee.
- **PRG-43** Professions: level 1-60, the curve 50·p^1.3, ilvl by level and the affix seal.
- **PRG-29** Validator: the CSV → `.tres` generator and the 6 rules of §15.2.
- **PRG-30** Telemetry: the targets of §15.1 and the alerts of §15.3.
- **PRG-37** End game: +6…+10 with Shards, sets with a 2- and 4-piece bonus, and legendaries with a trait.
- **PRG-38, PRG-44, PRG-45** Items of each realm: they become "visual sets of the realm (§16) and named and legendary items of its bosses".
  The generic data is common.
- **PRG-33** Quartermaster: war gear item level 60 rare with fixed affixes, bound, `base_value` 0, and the conversion to Shards with a cap.
- **ART-27** Equipment appearance by realm and level: with the free pieces and the plates made in Blender, without buying the Outfits Source.

### 20.2 New

**PRG-52** Content tables from CSV: deterministic generator · **PRG-53** `ItemInstance` format 2 and item migration · **PRG-54** Equipment slots:
11 slots, G1 armor and jewelry · **PRG-55** Item stat scale: item level, equipment score and `ItemStatRules` · **PRG-56** Potion families, charges
per family and the tonic · **PRG-57** Out-of-combat consumables · **PRG-58** Item transformations: upgrades, gems and reforging · **PRG-59** Salvage
and essences · **PRG-60** Bag expansions · **PRG-61** Gold flow simulator per level band · **TEC-70** Items v2 protocol: appearance block and
economy services · **CMB-31** Armor split and weapon power in `DamageFormula` · **CMB-57** Damage types and physical and elemental armor ·
**ART-73** Heavy plate armor · **ART-74** Light and medium armor with the realm mask shader · **ART-75** Item thumbnails and icon credits ·
**ART-76** Gathering tools and nodes · **UI-79** Item tooltip with comparison · **UI-80** Loot notices and satchel · **UI-81** Transformation and
salvage windows.

---

## 21. Production order (lane L)

Lane L of the vertical-slice plan: PRG-52, PRG-53, TEC-70, PRG-54, PRG-05, ART-74, PRG-06, CMB-31, PRG-55, PRG-20, UI-79, PRG-21, UI-80,
PRG-24, PRG-23 (and UI-28 for trade), PRG-56, ART-73 and ART-75. It depends on the requirements (H0), on lane D for the stat sheet, on lane E
for the load bits of `CombatState` (E reserves them, L fills them) and on lane J for the NPC that opens the merchant. Each increment closes with its tests in CI and
screenshots archived in `Eldmark-capturas` (before and after). **"Slice"** marks what the first vertical slice needs.

| # | Increment | Size | Depends on | Done when | Screenshot | |
|---|---|---|---|---|---|---|
| 1 | CSV generator and validator v0, which regenerates today's 4 items identical | S | — | `test_content_tables` | — | Slice |
| 2 | Format 2, `progress_format` 2, migration and protocol (caps of 25) | M | 1 | Round trip of 1 000 instances v1 and v2, and Go with the same cases | — | Slice |
| 3 | 11 slots; armor and jewelry G1 (18 definitions); `item_give` with ilvl and rarity; light and medium G1 with Peasant and Ranger; the SPAWN block | M | 2 | Equip, unequip and reject by slot, level or combat; two clients see each other | Character window with light and with medium; a remote in Vardheim and in Solmarch | Slice |
| 4 | Load (PRG-06) | M | 3 | The dodge of each load falls within ±0.05 m of what is expected and with 0 corrections at 100 ms | The three dodges with distance marks; "Load: heavy" in the window | Slice |
| 5 | Item stats in the sheet (needs PRG-01): armor, resistances by type and weapon power | M | 4, PRG-01 | Table tests; `combat_balance` with 3 sets inside the TTK goal | Numbers against the dummy with each set | Slice |
| 6 | Rarity and affix generator, PCG32, affix catalog and tooltip with comparison | M | 5 | Distribution of 10 000 rolls and a reproducible vector | Tooltips in Spanish and English | Slice |
| 7 | Loot tables, direct delivery, satchel and notices | M | 6, MUN-25 or a test zone | Seeded test; full satchel with LOOT_LOST | Rarity notices and the satchel window | Slice |
| 8 | Durability, loss on death, DURABILITY_UPDATE and notices | S | 3 | Exact losses and use never breaks anything | Equipment doll with yellow and red pieces | Slice |
| 9 | Merchants and repair (need MUN-16 and MUN-19) | M | 8 | Buy, sell, buy back and repair, consistent with the server | Merchant window | Slice |
| 10 | Gathering G1-G2 (needs MUN-22 and MUN-45) | M | 9 | Three node types placed; the channel is cut by damage | Channel bar; depleted node | After |
| 11 | Refining and crafting G1 at stations (needs MUN-21) | M | 10 | Refine and make a weapon, a consumable and a kit | Crafting window | After |
| 12 | Professions: level, XP and ilvl by level | S | 11 | Leveling unlocks a recipe and changes the ilvl reproducibly | Professions window | After |
| 13 | Salvage, essences and crafted rarity | S | 12 | Salvage rule of the validator | Before and after the salvage | After |
| 14 | Upgrade +1…+5, gems and reforging | M | 13 | Transformation with a new uid and two events; exact costs | Tooltip +0 versus +5 with a gem | After |
| 15 | Health potions by grade and the tonic (slice); out-of-combat consumables (after) | M | 9, CMB | USE validated; timers that survive reconnecting | Active-effect icons | Slice (potions, tonic) |
| 16 | Bag and bank expansions | S | 9, PRG-25 | BAG_EXPAND in order and only upward | Bag of 36 | After |
| 17 | Full validator and simulator (PRG-29, PRG-30) | M | 11-16 | Detects a seeded gold loop and each band gives a ratio of 0.45-0.65 | Simulator report | After |
| 18 | Heavy plates (in parallel from 3) | L | 3 | Asset validator (ART-05); tests with 200 characters | The three realms in heavy, grades I to III | Slice (Vardheim grade I) |
| 19 | +6…+10 with Shards, war gear, sets and legendaries (phases 7 and 8) | L | 14, GUE-20, PRG-33 | PRG-37 | A piece at +10; set bonus active | After |

---

## 22. Risks

| Risk | Mitigation |
|---|---|
| Content explosion (about 350 definitions and 300 recipes) | CSV with a deterministic generator, a validator in CI, and compound names only inside the generator (each item has its full msgid) |
| Coupling of the balance with PRG-01, PRG-17 and CMB-31 (health by level, attribute scale) | Figures are defined "at item level 60" and scale with k: if advancement changes its scale, two constants of the generator are touched. `combat_balance` per band |
| Predicted state drifting when changing equipment | Equipping only out of combat; load and the derived sheet are imposed by the server; wear never breaks in combat (I38) |
| Messages above 1 200 B with format 2 | Caps of 25 entries (§17.3) and a test with the worst case (6 affixes and 2 gems in every slot) |
| Draw calls in Eldrun from loose pieces | Rigid pieces weighted to a bone so they can be merged, LOD and per-realm impostor, load at distance (ART-35) |
| The visual grade lets the enemy guess the level band | Acceptable: the category must read and in Eldrun the level is normalized (open question for the user) |
| Inflation if sinks fall short | Telemetry per band with alerts; figures are adjusted in the CSV, not in code |
| Selling gold for real money and laundering with items | Binding (I39), non-sellable merit purchases, PRG-39 |
| The generator algorithm changing | The results are saved; the seed only serves for audit |
| Quaternius pieces not fitting the 5 slots (for example "Body" with sleeves) | Try it in increment 3 before generating the 90; if it does not fit, cut it in Blender by script (like `fix_ranger_collar.py`) |
| Only the male body is in the repo | Import the female variants in ART-20; the catalog already carries a scene per body |
| CC BY 3.0 license of game-icons.net | A credits file per author from the first icon; prefer the CC0 ones when they serve |
