# Hondal (zone 1-10 of Vardheim)

> The P1 sheet ("sheet", step 1 of the [production steps](../world.md#10-producing-a-zone-with-agents)) of the first
> PvE zone of Eldmark, and the model for every sheet that follows. It is where a new Vardheim character plays Act I,
> from the pine village of Granvik to the Squire's Choice, and the first zone built with the zone kit
> ([world.md](../world.md#9-the-zone-kit)). Format of this sheet: [vado_gris.md](vado_gris.md).
> Everything here is **provisional**: positions, counts and levels are the starting figures for the layout (P2) and
> the population pass (P5), and the validators ([world.md](../world.md#86-validators)) have the last word.

- **Id:** `hondal` (`ZoneDefinition.type = PVE`, realm `vardheim`, `level_min = 1`, `level_max = 10`).
- **Name msgid:** "Hondal" (context `place`; an invented name, not translated).
- **Playable area:** 1.5 × 1.5 km (x and z between -750 and 750); terrain 2 × 2 km in 8 × 8 Terrain3D regions of 256 m,
  generated, not drawn by hand ([Generated zone data](../world.md#93-generated-zone-data-pending-decision-p1)).
- **Coordinates:** origin at the center of the zone, 1 unit = 1 m, **north = -Z**, like Vado Gris.
- **Biome profile:** pine valley with farms (Hondal and Wolf March share the pine and burnt-pine profile). Low sun,
  cold white ambient light, mist in the river hollow (see [Visual identity](../world.md#7-visual-identity)).
- **Channels:** 48 players per channel, target 64 (budget in [Budgets](#budgets-and-risks)).
- **Hours of the first run:** 3-4 h of zone play; the Act I quests alone are about 4.5 h, in line with the curve of
  [world.md](../world.md#34-where-each-band-fits).

## Identity and role in Act I

Hondal is the valley below the Frost Wall where the Squires of Eld, the old guard of the throne, farmed and kept
watch. Three centuries on it is a poor, cold and stubborn place of pine farms and log longhouses, with the old
Eld ruins at Eldhald half buried in its eastern woods. A new Vardheim character arrives from Isenholm already sworn to
nothing: the valley teaches them to fight, to read the runestones and to doubt the Hollow, and sends them back to the
capital with the first Ember.

| Act I step | Where | What the zone teaches |
|---|---|---|
| m01-m02 (level 1) | Granvik | Moving, camera, interaction, light and heavy attacks, dodge, the weapon swap (Q), the free choice of a second weapon |
| m03 (level 2) | Fang Pines | Block and dodge against a pack, personal loot |
| m04-m05 (levels 3-4) | Asbjorn Farm, Granvik | Multi-stage quests, interaction with objects, the Hollow, the first chronicle entry |
| m06 (level 5) | Deserter Camp | A named enemy, healers and archers in a mixed group |
| m07 (level 6) | Eldhald Ruins | An elite, a channel interaction, the first Ember and Echo I |
| m08-m09 (levels 7-8) | Isenholm | The pass to the capital, the services, the council |
| m10 (level 9) | Hrimgard Sealed Gate | A two-phase boss with adds, group credit on the braziers |
| m11 (level 10) | Isenholm | The Squire's Choice: the specialization trial |
| m12-m13 (level 10) | Provisional pass, Vado Gris | Baptism of fire in the skirmish, the report to the Jarla |

The sheet does not write the quests (that is [quests.md](../quests.md)); it reserves their anchors and guarantees that the main
chain walks the zone in the order of `hub_order`.

## Layout

### Plan

Schematic top-down view, north up. Each column is 25 m in X and each row is 50 m in Z (so the zone comes out wide and
short). Positions are provisional.

```
       x: -750   -600   -450   -300   -150      0    150    300    450    600    750
 -750                                           ~
 -700                                           ~
 -650              ^^                           ~
 -600              ^^ ^^^  ^    ^^              ~~
 -550          ^ ^  ^  ^  ^  ^                   ~
 -500           ^  ^  ^ ^  ^  ^                  ~
 -450          ^ ^  ^ F^  ^  ^ ^    ^^           ~       .H
 -400          ^^^ ^^ ^^^ ^^ ^^                  ~      ..
 -350           ^  ^ .^ +  ^  ^                  ~      +
 -300            ^  ^. ^  ^  ^^^                 ~     ..
 -250      ^^       . ^ ^                        ~    ..         ?
 -200              ..                            ~   ..
 -150     ^^       .                   .D        ~  ..
 -100              .                 ............~=.M
  -50              .          .......            ~  .
    0             +. ..........                  ~+ .
   50 I............G.         .                 ~~  ..
  100               ..        .                 ~    w
  150        ^^      ..  t    b                 ~    ..
  200                 ..                       s~     .
  250                  ..                       ~     E
  300                   .+                      ~
  350                    ..                     ~  +
  400     ^^              A.                    ~
  450                      ..                   ~
  500                       ..                  ~~
  550           ^^           ..                  ~
  600                         ..                 ~
  650                          ..                ~~
  700                           .V                ~
```

`I` pass to Isenholm (west edge) · `V` provisional pass to Vado Gris (south edge) · `?` edge reserved for the future pass
to Grimfell · `G` Granvik · `F` Fang Pines · `A` Asbjorn Farm · `D` Deserter Camp · `M` Mill Crossing · `E` Eldhald Ruins ·
`H` Hrimgard Sealed Gate · `b` Boar Meadows · `t` Bonefield graveyard · `s` River Shrine · `w` Mill Wood edge ·
`+` respawn shrine · `.` roads · `~` river · `=` bridge · `^` pines.

- **Terrain:** a shallow valley that opens to the west, toward the fjord of Isenholm, closed by pine ridges to the
  north and by the foothills of the Frost Wall (not walkable) along the south edge. The playable border is a
  rock and pine ridge of 25-60 m, as in Vado Gris, with the invisible wall on a slope and not in the middle of a meadow.
- **The river** ("the Hondal") enters from the north at x = 300, bends southeast and leaves through a gap at the south
  edge. It is walkable only at the ford of Mill Crossing and over the bridge next to it; the rest is deep water with a
  low collision on the banks (as in Vado Gris, until swimming exists). It splits the zone into a west half (Granvik,
  Fang Pines, the farm, the deserters) and an east half (Mill Crossing, Eldhald, Hrimgard).
- **Roads:** the **Fjord Road** (main, 6 m) from the pass to Isenholm through Granvik to the pass to Vado Gris past
  Asbjorn Farm, about 1.3 km (4-5 min running); the **Mill Road** (main, 6 m) from Granvik to the Deserter Camp junction,
  over the bridge to Mill Crossing and on to Eldhald and Hrimgard; and trails (3 m) to Fang Pines, Boar Meadows and
  the river. Maximum slope 18 degrees on main roads and 25 degrees on trails. The roads are wide enough for a mount
  (hook for MUN-40) and the Granvik gate is at least 4 m.
- **Hub order** (`ZoneLayout.hub_order`): `granvik`, `fang_pines`, `asbjorn_farm`, `deserter_camp`, `eldhald`,
  `hrimgard_gate`. Two centers: **Granvik** (the village, with the three POIs at 300-600 m: Fang Pines 490 m,
  Asbjorn Farm 390 m, Deserter Camp 550 m) and **Mill Crossing** (the hamlet at the ford, with Eldhald 330 m and Hrimgard
  420 m).

### Distances

| From | To | Straight line | By road | Running |
|---|---|---|---|---|
| Pass to Isenholm | Granvik | 330 m | 340 m | 1 min |
| Granvik | Fang Pines | 490 m | 520 m | 1 min 45 s |
| Granvik | Asbjorn Farm | 390 m | 420 m | 1 min 25 s |
| Granvik | Deserter Camp | 550 m | 600 m | 2 min |
| Granvik | Mill Crossing | 820 m | 880 m | 3 min |
| Mill Crossing | Eldhald Ruins | 330 m | 360 m | 1 min 15 s |
| Mill Crossing | Hrimgard Sealed Gate | 420 m | 460 m | 1 min 35 s |
| Pass to Isenholm | Pass to Vado Gris | 1.2 km | 1.3 km | 4 min 20 s |

## Places, hubs and points of interest

### Points of interest

The five POIs of the vertical slice plus the village, with the families of the T1 sheets of [npcs.md](../npcs.md#33-tier-t1-the-18-sheets).
"Level" is the camp level (`NpcCamp.level`); each definition adds its own offset of 0-1. A camp holds at most 14 alive,
2 elites and 1 boss.

| POI (template) | Marker id | Position (x, z) | Level | Families and sheets | Live | Anchors |
|---|---|---|---|---|---|---|
| Granvik, the pine village (village) | `hondal_granvik` | (-420, 60) | 1 (safe) | Village guards (not hostile), ~12 ambient and 8 service NPCs | - | 8: the givers, the board, Granvik Pillar, shrine |
| Fang Pines (lair) | `hondal_fang_pines` | (-330, -420) | 3 | Wolves: `wolf` x6, `wolf_alpha` x1 (plus 3 of the pack); rare `old_fang` (Greyfang) | 10 + rare | 1 (m03, s03) |
| Asbjorn Farm (raided farm) | `hondal_asbjorn_farm` | (-230, 400) | 4 | Hollow: `hollow_wanderer` x5, `hollow_archer` x2 | 7 | 2 (m04: three clues, Kari) |
| Deserter Camp (camp) | `hondal_deserter_camp` | (100, -120) | 5-6 | Deserters: `bandit_swordsman` x4, `bandit_archer` x3, `bandit_brute` x2, `bandit_healer` x1, `bandit_lieutenant` x1; named Gunnar Halfhand | 12 | 2 (m06, s10) |
| Eldhald Ruins (Eld ruin) | `hondal_eldhald` | (470, 270) | 7 | Hollow: `hollow_wanderer` x3, `hollow_soldier` x3, `hollow_archer` x2, `hollow_ashcaller` x2, `hollow_standard` x1; elite Eldhald Guardian | 14 | 3 (m07, Echo I, s08) |
| Hrimgard Sealed Gate (story POI) | `hondal_hrimgard_gate` | (560, -440) | 9 | The Forsworn: zealot x3, emberbinder x2, warden x1; 3 braziers; boss Hjalmar the Forsworn | 7 + boss | 2 (m10) |

- The **Hrimgard Sealed Gate** is a **story POI, not a dungeon**: it uses the landmark and Eld ruin
  templates and a sealed door that never opens. [The dungeons D1-D6](../world.md#67-dungeons-d1-d6) are shared Eld maps with
  entrances in zone 2 and above; none is in Hondal.
- The Forsworn (3 variants), the Eldhald Guardian, Gunnar Halfhand and Hjalmar are derived from the 18 T1 sheets in the
  [Hondal additions](../npcs.md#34-hondal-additions-derived-from-the-t1-sheets). They are not extra families.
- `bandit_chief` and `hollow_ruin_captain` are T1 sheets that Hondal does not place in the slice: the boss of the
  zone is Hjalmar, whose script reuses the chief's two-phase shape.

### Secondary sites

They fill the hostile-POI count (8-10 for a 1.5 km zone) and the quest places, with smaller camps and field groups.

| Site (template) | Marker id | Position | Level | Families | Live | Used by |
|---|---|---|---|---|---|---|
| Boar Meadows (lair) | `hondal_boar_meadows` | (-130, 160) | 3-4 | `boar` x5, `deer` x3; rare `fencebreaker` (Ketil's farm hand shouts about it) | 8 + rare | s04, s14 |
| Bonefield graveyard (Eld ruin, small) | `hondal_bonefield` | (-260, 190) | 5-6 | `hollow_wanderer` x6 that rise from the graves | 6 | s09 |
| River Shrine (camp, small) | `hondal_river_shrine` | (280, 230) | 7 | `bandit_swordsman` x3, `bandit_archer` x2 (looters) | 5 | s11 |
| Mill Wood edge (Eld ruin, small) | `hondal_mill_wood` | (430, 130) | 6 | `hollow_wanderer` x3, `hollow_archer` x1 | 4 | s07 |
| Field groups | `hondal_field_*` | along the roads | 1-8 by distance from Granvik | wolf pairs, boar pairs, deer herds, Hollow strays | ~56 in 14 groups | travel, filler |

Totals (provisional): about 150 hostiles placed (the budget is 150-200), of which about 90 can be awake at once, and
capacity of about 220 kills per minute at the minimum respawn times, against the 120 per minute (2.5 times the players)
that a channel of 48 needs.

### Passes, arrivals and shrines

| Pass | Kind | To | Arrival | Min level | Notes |
|---|---|---|---|---|---|
| `hondal_pass_isenholm` | ROAD | `isenholm` | `from_hondal` | - | West edge, 330 m from Granvik. Round trip, in combat it is blocked |
| `hondal_pass_border` | WALL_GATE (provisional) | `vado_gris` | `vardheim_camp` | 10 | South edge. The provisional pass of phase 6: it stands in for the future Wolf March gate until the border zone exists; the arrival is the Vardheim camp of the skirmish |
| (Grimfell) | ROAD | `grimfell` | - | - | Not declared. The `?` mark on the plan reserves the northeast edge; the pass is added with the Grimfell zone, as the validator demands reciprocity |

Arrivals of Hondal (`arrivals`, index + 1 in the ticket): `from_isenholm` (default), `from_vado_gris`, `respawn_*`.

**Respawn shrines** (6, at most 450 m from any walkable point, checked by the validator): Granvik (-440, 20), Fang Pines
approach (-300, -340), Asbjorn Farm approach (-260, 330), Mill Crossing (360, 10), Eldhald approach (380, 360) and
Hrimgard approach (500, -340). Granvik's shrine is the first and default. They stand at least 60 m from any spawner.

**Travel posts** (fast travel itself is phase 7; the markers exist from phase 6): `hondal/granvik` (hub, known from the
start) and `hondal/mill_crossing` (opens by discovery).

### Named places (discovery)

Twelve places with a polygon in the `PlaceSet`, which emit `PLACE_DISCOVERED` (quests, discovery XP, map):
Granvik, Fang Pines, Boar Meadows, Bonefield, Asbjorn Farm, Deserter Camp, River Shrine, Mill Crossing, Mill Wood,
Eldhald Ruins, Hrimgard Sealed Gate and the Fjord Road overlook (a watchtower, the lookout of the zone). Names are
msgids in English with an entry in `es.po`.

## Landmarks and custom pieces

Three or more hand-made pieces so that the zone does not look like the next one (Blender by script, in the flow of
[art.md](../art.md#49-custom-modeling-with-blender-the-sword)):

| Piece | Where | Notes |
|---|---|---|
| **Longhouse** (gable plank roof almost to the ground, carved ridge heads) | Granvik hall, and a smaller one in Mill Crossing | The signature of Vardheim; also used in Isenholm |
| **Runestone** (knotwork carving, readable text) | Roadside, one per POI | Interactable `Read` (the eight `Stones That Speak` of s08 use four of them) |
| **Granvik Pillar** | Granvik square | A tall rune pillar and the brazier where the toast to the Wall is told; the landmark seen from the Fjord Road |
| Rough stone tower | Fjord Road overlook | Watchtower and discovery place |
| Sealed gate of Hrimgard | `hondal_hrimgard_gate` | Stone door with rune seals that dim when the braziers go out |

Everything else comes from the Village MegaKit (wooden walls and roofs, recolored), the Stylized Nature pines and
rocks, and the Ranger and Peasant outfits for the NPCs.

## Resources asked from other domains

| Domain | What Hondal needs |
|---|---|
| NPCs ([npcs.md](../npcs.md)) | The 18 T1 sheets and their [Hondal additions](../npcs.md#34-hondal-additions-derived-from-the-t1-sheets) (Forsworn, Eldhald Guardian, Gunnar Halfhand, Hjalmar); `NpcCamp` prefabs for the six camp types; village guards; the service and ambient NPCs of Granvik; the quadruped placeholders for wolves, boars and deer |
| Quests ([quests.md](../quests.md), [story.md](../story.md)) | Anchors (`quest_anchors`) at every POI, the places, the Act I chain m01-m13, 15 side quests, 18 lore texts, Echo I at Eldhald, the Granvik board and the Hollow Incursion event (arena at the Granvik palisade) |
| Items ([items.md](../items.md)) | G1 gathering nodes (120-180 slots: firewood, resin, hides, herbs, iron scrap), the `LootTable` per family, chests (one per camp, personal lock) and the vendor stock of the provisions merchant and the armorer |
| Combat ([weapons.md](../weapons.md), [abilities.md](../abilities.md)) | Ground-area telegraphs for the emberbinder, line telegraphs for the boar charge and the archers, the dummy of Granvik |
| Progression ([advancement.md](../advancement.md)) | The leveling simulator's targets for the zone (about 3.5 h at the reference pace) and the discovery XP for the 12 places |
| Art ([art.md](../art.md)) | The pine and farmland biome profile, the longhouse, runestone and pillar pieces, Vardheim outfits for the Granvik NPCs, the quadruped rig (pending P4), the Eld ruin kit for Eldhald |
| Technology | The handoff to Isenholm and to Vado Gris, the AI activity LOD and radius interest (a zone with 150 hostiles), and the load test with 48 bots and 200 NPCs |

## Review cameras

Automatic ones (generated by P3, in `screenshot_points` with the metadata `fov`): two per POI (approach at 1.7 m and
three-quarter aerial), one per pass and per travel post, four corner aerials plus one overhead, and one every 300 m at
player height along the Fjord Road. Manual ones (added in `ZoneLayout.extra_cameras`):

| Camera | What it shows |
|---|---|
| `granvik_square` | The Pillar, the longhouse and the board at dawn |
| `fang_pines_den` | The wolves' den from the trail, with the pack in view |
| `eldhald_ruins_gate` | The inscription "No blood alone" over the arch |
| `hrimgard_braziers` | The three braziers and the sealed gate |
| `ford_mill` | The ford, the bridge and the mill with fog on the water |
| `fjord_overlook` | The valley from the watchtower, toward the fjord |

## Budgets and risks

Provisional budget (`ZoneBudget`), from the [performance table](../world.md#11-performance-budget-per-zone) for a
1.5 km PvE zone:

| Budget | Hondal |
|---|---|
| Draw calls / primitives in any view | 1500 / 2 M |
| Load on SSD (handoff to CLIENT_READY) | 5 s |
| Generated data on disk | 80 MB |
| Server RSS (gameplay layer only) | 400 MB |
| Hostiles placed / awake at most | 200 (planned about 150) / 90 |
| Ambient NPCs | 40 |
| Players per channel | 48, target 64 |
| Tick p99 with the channel full of bots | 12 ms |

| Risk | Mitigation |
|---|---|
| The river splits the zone and the east half is far (the last POI is 1.3 km from the pass) | A second shrine and travel post at Mill Crossing; the quests send you east only after Granvik is done |
| Terrain3D generation and load for 8 × 8 regions is not measured | K3 measures it on the test valley before Hondal; levers: no saved grass, fewer regions in the gray model |
| 150 hostiles in 1.5 km hit the CPU budget | AI activity LOD and the load test (K8) come before population; camps sleep beyond 150 m |
| Eldhald and Hrimgard are too alike (both Hollow-adjacent) | Eldhald is open ruins of Eld and Hollow soldiers; Hrimgard is a walled sanctum with fire and cult. Different biomes: dead pines and stone at Eldhald, glacial rock at Hrimgard |
| Quest anchors move when the layout is regenerated | Markers keep their ids; positions come from `ZoneLayout`, and the quest validator reads ids, not positions |
| The provisional pass to Vado Gris is removed once Wolf March exists | It is a data entry in `ZoneDefinition.passes` and `world.tres`; the arrival keeps its id |

## Appendix: Isenholm core district (first vertical slice)

Hondal is only half of the slice: Act I needs a capital to go to. The vertical slice builds the **core of Isenholm**, the
safe zone where m08-m09, m11 and m13 happen, about **300 m dressed** and the rest as a gray model (the full capital is
MUN-21, after the slice). Isenholm (`isenholm`, `type = CAPITAL`, 1 × 1 km, terrain 1.5 × 1.5 km) is the fortress at the
head of the fjord.

### Plan of the core

```
                 fjord and quays (gray model: Jarl Sten)
                                   ~~~~~~~~
             +-------------------------------------+
             |        Jarl's great hall            |
             |        (the signature piece)        |
             +--------------+----------------------+
                            |  steps
       Hall of Arms         |             Crafts quarter
       (Master of the       |             (gray model,
        Orders + mentors)---+--- Market square -----  stations post-slice)
       Training yard        |  merchants, board, well
                            |
        Barracks yard       === City gate ===  (arrival of the pass from Hondal)
       (gray model: Thane Gudrun)
```

| Piece | Dressed | Contents in the slice |
|---|---|---|
| **City gate** | Yes | Arrival `from_hondal` (default), the pass to Hondal as a gate, two guards, the central travel post (marker only) |
| **Market square** | Yes | The provisions merchant, the armorer (repairs), Jarl Ase's stand, the notice board (post-slice), the well, 12 ambient NPCs; reserved slots for the banker and the auctioneer |
| **Hall of Arms** | Yes | The **Master of the Orders** and **one mentor per specialization**: four in the slice (Vanguard, Linebreaker, Hunter, Healer), the Arcanist and Sapper slots reserved, so **six slots** |
| **Training yard** | Yes | Dummies for each weapon family, a sparring ground, an area where Hakon, the Master of the Orders (the Hall of Arms' master at arms in the Act I quests), gives the combat teaching |
| **Jarl's great hall** | Yes | Jarla Ragnhild, the steward Einar, the council table; the signature landmark of the capital (a Blender piece, longhouse language scaled up) |
| Crafts quarter | Gray model | Station posts for later (forge, tannery, carpentry, alchemy, refining) |
| Quays | Gray model, walkable | Jarl Sten Hrafnsson (m09) |
| Barracks yard | Gray model, walkable | Thane Gudrun (m09), the wall of names (s15) |

- The three voices of m09 are all reachable: the market (dressed), the quay and the barracks (gray, but walkable with
  their markers).
- **Services** use the roles of [npcs.md](../npcs.md#7-service-and-ambient-npcs): the Master of the Orders and the
  mentors do the specialization choice and the role trials; the merchant and armorer open vendor and repair windows. The
  bank (needed by the side quest "Gold, Steel and Vault") comes after the slice; its slot is reserved in the square.
- About 20 ambient NPCs (up to 120 in the finished capital), on rails and without physics, and no hostiles: the capital
  is a safe zone with no combat.
- The district weighs on the budget like a capital: 2000 draw calls and 2 M primitives at most, with an HLOD per block
  once the full capital exists. Pieces: Village MegaKit walls recolored (dark wood, gray stone), longhouses, the Jarl's
  hall, rune pillars.
- Review cameras: gate, square, Hall of Arms interior door, training yard, great hall steps, and the fjord from the
  quay.
