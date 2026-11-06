# Eldmark: the world of La Corona Rota (the Broken Crown)

> Status: **world chosen**, La Corona Rota (proposal C), extended in phases 6-8 for the **level 60 cap**. This document
> covers the history, the realms, the war zone, the zones and their bands, the technical structure of the world, the
> visual identity of each realm and the plan to build it in Godot 4.7. Map: [world_map.svg](world_map.svg). One sheet
> per zone in [zones/](zones/): [Vado Gris](zones/vado_gris.md) and [Hondal](zones/hondal.md). The creatures and people
> that populate the zones are in [npcs.md](npcs.md).
>
> The figures of sections 3 to 14 are **provisional**: they are the starting values for the zone kit and the first
> zones, and the first measurement of each zone type fixes them.

## 0. Decisions

The ids W1-W17 are local to this document: other documents cite them with the file ("world.md W5"), because
[weapons.md](weapons.md) also numbers its decisions W1-W20.

| # | Decision | Why |
|---|---|---|
| W1 | **Six zones per realm**: capital, zone 1 (1-10), zone 2 (10-20), zone 3 (20-32), zone 4 (32-45) and the border (45-60). That is 18 realm zones plus Eldrun, **six shared instanced dungeons** and the Vado Gris: **26 maps** | A level 60 cap needs about one zone per band of 12 levels. Six per realm is the minimum that does not triple the work |
| W2 | **Playable sizes:** capital 1 × 1 km, PvE 1-20 1.5 × 1.5 km, PvE 20-45 2 × 2 km, border 3 × 1.5 km, Eldrun 3 × 3 km (4 × 4 if the measurement of TEC-34 allows it) | Dense maps and short walks at the start, bigger zones when each level costs more hours |
| W3 | **Three new zones:** Hrimvald Glacier (`hrimvald`), Vaucelle Heights (`vaucelle_heights`) and Qesh Salt Flats (`qesh_flats`) | One new zone per realm for the 32-45 band. "Corvanne Heights" was renamed because it clashed with the Seneschal Corvan of the story |
| W4 | **The border is the final zone (45-60)** and the center of war operations: the Bastion (garrison) sits next to the two gates. The wall kit is shared by two zones | The threat grows toward the Sundering, so the geography tells the progression, and level 60 players stay next to the gates |
| W5 | **Shared instanced dungeons:** one Eld map per dungeon with one entrance per realm. The Sealed Gate of Hrimgard in Hondal is a story point of interest, not a dungeon | Groups never mix realms, so six maps are built instead of 18, and the Eld ruins belong to the three peoples |
| W6 | **Each realm has its own open world;** there are no neutral PvE zones. The realms touch only in Eldrun | Keeps the identity of each realm. The savings come from templates, not from shared maps |
| W7 | **Fixed topology per realm** and passes validated by data | Allows generating, validating and documenting 18 zones with the same tools |
| W8 | **Zones are text data** (`ZoneLayout`) and the heavy parts are generated | Zones are produced by agents; a text diff can be reviewed and a regenerated binary cannot |
| W9 | **Generated zone data out of git** (terrain regions, navigation, MultiMesh, baked maps): **pending the user's decision P1**. Meanwhile grass is not saved and regions are versioned only when an increment closes | Terrain regions of 256 m weigh 2.5-2.65 MB each with grass inside; the finished world would add about 1.5 GB to a public repo without LFS. It changes a rule of `CLAUDE.md` |
| W10 | **Grass is not saved:** the client generates it around the camera | It is most of a region's weight and has no collision, so the server does not need it |
| W11 | **Scatter collisions go by 64 m cells as data** (arrays) and are created with `PhysicsServer3D` | A 2 km zone has tens of thousands of trunks and rocks; a node per trunk neither loads in 5 s nor fits the server's memory |
| W12 | **AI activity LOD (MUN-51) and radius or grid interest (TEC-32) are in phase 6** | A PvE zone has 150-300 NPCs; the cost does not fit in a tick if everything is relevant to everybody |
| W13 | **Vardheim first, Solmarch second, Askarra last;** then each band in the three realms at once | Vardheim already has pines, palisade and snow in the shader, and its signature pieces are the easiest to build by script. The RvR needs parity |
| W14 | **Fast travel only inside the realm** (poles, phase 7); mounts after launch, with hooks now. In phase 6, a **provisional pass from Hondal to the Vardheim camp of the Vado Gris** (minimum level 10) | The full border (45-60) is not needed for the vertical slice |
| W15 | **Vado Gris is a `SKIRMISH` zone** normalized from **level 10**; **Eldrun is entered from level 20**, normalized | With everything normalized, entering early only gives up mastery and talents, which are bounded |
| W16 | **Capital districts** include a **Hall of Arms** (the Master of the Orders and one mentor per specialization, six slots), a training yard and a crafts quarter | The class design of [advancement.md](advancement.md): the specialization is chosen and changed in the capital |
| W17 | **The simulation runs at 60 Hz** (`physics_ticks_per_second=60`, `WELCOME.tick_rate`); only the snapshots go at 30 Hz | Budgets in this document are given in ticks of 16.7 ms |

## 1. History


Three centuries ago the three peoples formed a single kingdom, **Eld**, ruled
from **Aldcor**, the citadel where the **Flame of Eld** burned: an ancient fire
that made the land fertile and bound the three lineages by oath.

The last king died without an heir and the three lineages claimed the throne. In the
battle of Aldcor the Flame exploded, the citadel sank and the land
cracked: **the Sundering** (in Spanish, "la Quiebra"). Each people shut itself behind its wall, blaming the
others.

The **Embers of Eld** ("Brasas de Eld"), shards of the Flame, still burn among the ruins and
grant power to whoever controls them. It is said that whoever gathers enough of them will rekindle the
Flame and wear the Broken Crown. The war zone is the corpse of the kingdom they
once were: a shared past that only one can inherit.

## 2. The three realms

### Vardheim, the clans of the north
- **Culture:** clans inspired by Norse and Anglo-Saxon cultures. A council of jarls
  elects the king. They were the Squires of Eld, guardians of the throne.
- **Landscape:** fjords, pine forests, tundra and glaciers; long winters and auroras.
- **Architecture:** dark-wood longhouses with plank roofs,
  palisades, rough stone towers and knotwork carvings.
- **Heraldry:** steel gray and ice blue. A white wolf on a gray field.
- **Capital:** Isenholm, a fortress at the head of a fjord.
- **Tone:** fatalistic and harsh. They swore to guard the throne and failed.

### Solmarch, the realm of the Dawn
- **Culture:** Gothic theocracy ruled by the Order of the Dawn and a chivalric
  nobility.
- **Landscape:** fertile valleys, vineyards and slow rivers; mild, rainy climate.
  To the east, swamps poisoned by the Sundering.
- **Architecture:** pale limestone, cathedrals with flying buttresses, castles with conical
  towers, blue slate and stained glass.
- **Heraldry:** white and gold. A radiant sun split in two.
- **Capital:** Valcorin, a cathedral city in a river bend.
- **Tone:** luminous faith that ends in fanaticism. They see the rebuilding of the
  Flame as a crusade.

### Askarra, the ash forges
- **Culture:** oligarchy of forge lords and merchants, with Byzantine
  and Mediterranean ideas without copying any real culture.
- **Landscape:** red canyons, plateaus, oases and volcanic fields; dry heat and
  ash rain. Here the cracks of the Sundering still burn.
- **Architecture:** red sandstone and terracotta, low domes, arches, terraced
  cities carved into the rock and forge chimneys.
- **Heraldry:** crimson and bronze. A bronze anvil over a burning crack.
- **Capital:** Kassar, "the city of a thousand steps", carved into a canyon.
- **Tone:** pragmatic and desperate. Their land is dying and only the Embers
  keep it alive.

**Assets:** a single modular low-poly CC0 kit, recolored per realm: dark
wood and gray stone for Vardheim, limestone and blue slate for Solmarch,
sandstone and terracotta for Askarra. The detail is in
[Visual identity](#7-visual-identity).

## 3. Geography

### 3.1 The map

![Schematic map of Eldmark](world_map.svg)

Schematic map, not to scale: [world_map.svg](world_map.svg). The real sizes of each zone are in [Scale](#63-scale).

The realms form a triangle: **Vardheim in the north, Solmarch in the southwest and
Askarra in the southeast**, with the war zone, **Eldrun**, in the center. Each
wall surrounds its whole realm. The outer stretches rest on the sea,
the mountains or the desert; the stretch facing Eldrun is the front and has two
gates. Between each pair of realms, an impassable mountain range runs down from the
coast to Eldrun, so the realms only touch each other through the war
zone. On the map the realms are sectors around Eldrun and the levels rise toward it.

| Realm | Wall | Gates |
|---|---|---|
| Vardheim | Muro de Escarcha (Frost Wall; dry stone and logs) | Puerta del Lobo (Wolf Gate), Puerta de Hrafn |
| Solmarch | Muralla del Alba (Dawn Wall; limestone and conical towers) | Puerta Áurea (Golden Gate), Puerta de los Penitentes (Gate of the Penitents) |
| Askarra | Cinturón de Bronce (Bronze Belt; reinforced sandstone) | Puerta de Ceniza (Ash Gate), Puerta del Cañón (Canyon Gate) |

### 3.2 Zones and levels by realm

Content levels overlap two levels with the previous zone. "New" is the zone added per realm for the level 60 cap.

| Band | Vardheim (north) | Solmarch (southwest) | Askarra (southeast) | Playable | Total terrain |
|---|---|---|---|---|---|
| Capital | Isenholm | Valcorin | Kassar | 1 × 1 km | 1.5 × 1.5 km |
| Zone 1 · 1-10 | Hondal: pine valley and farms | Campos de Ambre (Amber Fields): vineyards and wheat | Oasis de Thal (Thal Oasis): irrigated land between canyons | 1.5 × 1.5 km | 2 × 2 km |
| Zone 2 · 10-20 | Skarven: fjords and shipwrecks | Bosque de Lirien (Lirien Forest): deciduous forest and abbeys | Cañones de Ruhn (Ruhn Canyons): plateaus and mines | 1.5 × 1.5 km | 2 × 2 km |
| Zone 3 · 20-32 | Grimfell: high tundra and burial mounds | Ciénaga de Morvel (Morvel Marsh): corrupted swamp | Yermo de Ceniza (Ash Waste): volcanic fields and living cracks | 2 × 2 km | 2.5 × 2.5 km |
| Zone 4 · 32-45 (new) | **Hrimvald Glacier** | **Vaucelle Heights** | **Qesh Salt Flats** | 2 × 2 km | 2.5 × 2.5 km |
| Border · 45-60 | Marca del Lobo (Wolf March) | Llanos del Penitente (Penitent Plains) | Forjas de Ossar (Ossar Forges) | 3 × 1.5 km | 3.5 × 2 km |

The three new zones:

- **Hrimvald Glacier** (`hrimvald`): a glacier split by the Sundering, with ice caves, a frozen lake and embers burning under the
  ice. It reuses the snow layer of the realm shader, the pines and the cold palette of Grimfell, so it is cheap to produce.
  Own Blender pieces: ice rocks and seracs (procedural rocks with an ice material) and a rune stone shrine.
- **Vaucelle Heights** (`vaucelle_heights`): limestone plateaus with quarries, fortified monasteries of the Order of the Dawn
  and inquisition pyres; it is where the faith of Solmarch turns into fanaticism. The Village kit serves for the houses; the
  own pieces are the fortified monastery (from the same work as the cathedral of Valcorin) and the quarry crane.
- **Qesh Salt Flats** (`qesh_flats`): a dry sea and a "sea of glass" where the Flame vitrified the dunes, with caravans, wells and
  the wrecks of an Eld port. It is mostly painted terrain with almost no vegetation, so it is cheap to scatter. Own pieces:
  emissive glass dunes and a stranded ship.

The other zones change band but not idea. The border is recharged for the maximum level: the ash and the Hollow of the
Sundering seep through the wall and there are incursions (the second event of MUN-31), elite lairs and the entrances to D5
and D6.

**Zone ids** (`[a-z0-9_]`, at most 32; descriptive names in English and invented ones as they are, as
[localization.md](localization.md) asks): `isenholm`, `hondal`, `skarven`, `grimfell`, `hrimvald`, `wolf_march`, `valcorin`,
`amber_fields`, `lirien_forest`, `morvel_marsh`, `vaucelle_heights`, `penitent_plains`, `kassar`, `thal_oasis`, `ruhn_canyons`,
`ash_waste`, `qesh_flats`, `ossar_forges`, `eldrun` and `vado_gris`. Dungeons carry the prefix `dg_`. The visible name is an
English msgid with its entry in `es.po`, in the context `place`.

### 3.3 Topology of a realm

Each realm has five rings:

```
                         [Capital]            safe, travel center
                        /         \
            [Z1 1-10 · 1.5 km]   [Z2 10-20 · 1.5 km]──D1
                        \         /
                     [Z3 20-32 · 2 km]──D2
                              │
                     [Z4 32-45 · 2 km]──D3, D4
                              │
        [Border 45-60 · 3 × 1.5 km]──D5, D6   Bastion (garrison, travel, quartermaster)
            ║ Gate A                  ║ Gate B          (about 2 km apart)
        ════╩═════ front wall ═══════╩════════
                         E L D R U N
```

- **Passes:** capital ↔ zone 1, capital ↔ zone 2, zone 1 ↔ zone 3, zone 2 ↔ zone 3, zone 3 ↔ zone 4 and zone 4 ↔ border,
  plus the two gates of the border to Eldrun. All are round trips and the validator demands it. No zone of a realm connects
  with one of another realm: only the gates lead to the war zone. Minor towns and villages go inside the PvE zones; they
  are not zones of their own.
- **Within a realm the capital is at the far end,** next to the coast or the mountain, between zones 1 and 2; zone 3 sits in the
  middle and the border against the wall.
- **The path to war for a low-level player:** fast travel (phase 7) goes from the capital to the Bastion, and that destination
  is opened by the quest "Call to the front" on reaching the minimum level of Eldrun, so nobody at level 20 has to cross a
  45-60 zone on foot.
- **Phase 6 provisional pass:** before fast travel exists, the pass from **Hondal to the Vardheim camp of the Vado Gris**
  (minimum level 10) lets the vertical slice run the Baptism of Fire with no border zone. It stands in for the Wolf Gate
  until the Wolf March exists; Solmarch gets the equivalent pass from the Amber Fields with its own slice.
- **World map:** concentric rings around Eldrun, with impassable ranges at the joints between realms, keeping the layout
  of the schematic: Skarven west and Hondal east of Isenholm, Amber north and Lirien south of Valcorin, Ruhn north and Thal
  south of Kassar.

### 3.4 Where each band fits

| Band | Own world | RvR | Shared dungeon | For other domains |
|---|---|---|---|---|
| 1-10 | Capital + zone 1 | Vado Gris from level 10 (skirmish) | none | Main chain 1, which ends at m13 "Report from the Front" after the Baptism of Fire; "Call to the front" is a level 20 quest (Eldrun's minimum) |
| 10-20 | Zone 2 | **Eldrun from level 20**, normalized | D1 Ossuaries of Eld (15-19) | The specialization is chosen at level 10, in the capital |
| 20-32 | Zone 3 | Eldrun | D2 Sunken Aqueduct (24-29) | |
| 32-45 | Zone 4 | Eldrun | D3 Oath Archive (35-39) and D4 Flame Foundry (41-45) | |
| 45-60 | Border | Eldrun, next to the gates | D5 Sundering Roots (50-55) | Upgrades with Ember Shards in the Bastion |
| 60 | Border (elites, events, commissions) | Eldrun and Aldcor | D6 Last King's Chamber (60, hard) | End game |

**Hours of play** (the leveling curve of [advancement.md](advancement.md) fixes them; about 50 h to level 60): zone 1 about 3.5 h, zone 2 about
6.5 h (zone 3-4 h, D1, the Vado Gris, commissions), zone 3 about 10 h, zone 4 about 13 h and the border about 17 h with
dungeons, Eldrun and repeatables. The open world alone is roughly 22-25 h; the dungeons, Eldrun and the commissions fill the
rest, as a game whose heart is the war asks. If progression picks another duration, the level ranges of each zone move and
the maps do not: the level of an NPC comes from `ZoneDefinition` and each point of interest, not from the terrain.

## 4. War zone: Eldrun, the Broken Crown

**Biome:** broken, gray lands, bare hills, dead forests, dry rivers and
cracks glowing with orange embers. Remains of roads, aqueducts and
villages of the old kingdom. Ash in the air and a sky always stormy.

**Castles** (one between each pair of realms):
- **Grauholt** (Vardheim–Askarra): mountain castle above a gorge.
  It dominates the eastern pass.
- **Velmont** (Vardheim–Solmarch): river castle with a fortified bridge.
  It controls the fords.
- **Sarnath** (Solmarch–Askarra): fortress above a crack of embers. The one that
  produces the most resources.

**Forts** (two per front):
- **Atalaya de Brenn:** reveals nearby enemies on the map.
- **Cantera de Odd:** supplies materials for siege weapons.
- **Vado Gris:** shortens the route to Velmont.
- **Santuario de Ilse:** forward respawn point.
- **Mina de Kerth:** generates extra Embers.
- **Puente de Hadrin:** bottleneck between Solmarch and Askarra.

**Aldcor, the Broken Throne:** the ruined citadel at the center. It can only be
attacked by a realm that controls 2 of the 3 castles.

### 4.1 Domination mechanic: Ember Lines
- **Adjacency:** you can only attack a stronghold connected to your gate or to
  another stronghold of yours. If a realm loses a link in its chain, the
  strongholds left behind it become isolated and their defenders weaken.
- **Embers:** each stronghold produces Embers for its realm every minute. They are spent
  on siege weapons and on blessings for the whole realm (experience, loot,
  discounts).
- **Aldcor:** the realm that captures it rekindles the Flame for a few hours and
  receives a greater blessing. Meanwhile, the other two realms attack with a
  bonus, so that nobody runs away with an advantage.

Which fort sits on each front and which roads link the strongholds is detailed
in [Road network](#611-road-network-the-ember-lines).

### 4.2 Outline and walls

- **The outline:** the three front walls (their outer faces, the same kit as the border zones, see
  [6.6](#66-border-zones-wall-and-gates)) and the three foothills of the ranges between realms, at the foot of which stand the
  three castles. The northwest front repeats the valley of the Vado Gris (river, ford and bridge) at the scale of the test
  map, so what is learned there carries over.
- **Unique fortress ids across the world:** the Vado Gris fort of Eldrun cannot be called `vado_gris_fort` like the one of the
  skirmish map, because GUE-19 persists by id. The world validator watches it.
- **While Askarra is closed** (until its first slices exist), its two gates and forts exist in Eldrun but are held by the
  Hollow, and bots or fake players are used for tests.
- **Entry:** from level 20, with level, attributes and equipment normalized (see [Vado Gris](#5-the-skirmish-zone-the-vado-gris-phase-4)
  and [advancement.md](advancement.md)).

### 4.3 The PvE layer

Eldrun is not only a battlefield between strongholds. It carries a PvE layer for the people who wait for a siege:

- 9-12 camps of the Hollow away from the roads, with **normalized** stats (the reference of [npcs.md](npcs.md#1-scaling-by-level)),
- 6 arenas of the Ember Rain event (MUN-31, MUN-71),
- Ember ore nodes for the end game (Ember Shards for upgrades),
- and, later, war commissions and weekly orders (MUN-72).

The experience is paid by the real level of the player, which is progression's business. The layer is item MUN-73 and arrives
with Eldrun in phase 7. What happens to the Vado Gris map once Eldrun exists is MUN-74: retire it, keep it as a training front
for levels 10-19, or turn it into a rotating battleground.

## 5. The skirmish zone: the Vado Gris (phase 4)

With the level 60 cap the Vado Gris is a `SKIRMISH` zone: **normalized** (`ZoneDefinition.normalized = true`, level 60 rules for
everybody, see [advancement.md](advancement.md)) and entered **from level 10**, as the Baptism of Fire of the story. Its NPCs keep their literal
figures (`scales_with_level = false`, [npcs.md](npcs.md#12-formulas-shared-scriptssharedainpc_statsgd)). In phase 6 it is reached
through the provisional pass from [Hondal](zones/hondal.md#passes-arrivals-and-shrines); what happens to the map once Eldrun exists is
open (MUN-74). Sheet of the zone: [vado_gris.md](zones/vado_gris.md).

- **Map:** about 300 × 300 m. A valley between the Muro de Escarcha (Vardheim, to the
  north) and the Muralla del Alba (Solmarch, to the south). At each end, only the
  wall facade with its gate as a spawn point and a small
  camp.
- **Terrain:** a low hill in the center next to a shallow river. Two
  routes: a narrow, direct stone bridge, and a wide, exposed ford. On the
  flanks, ruins of a village of old Eld as cover.
- **Fort:** a log palisade about 40 m per side with a walkway and two
  ramps, a central two-story stone tower with the standard and a
  wooden gate with health that breaks under blows. Siege weapons arrive in
  phase 7.
- **Defenders:** at the start it is neutral and guarded by the **Hollow** (the "Huecos"), undead
  soldiers of Eld's old garrison: 4 guards and the **Ford Captain** (the "Capitán del Vado").
- **Capture:** killing the captain activates a circle under the standard; it has to
  be held for 30 s. It goes faster with more allies and freezes if there are enemies
  inside. When captured, flag and colors change, after 2 min guards of the
  owning realm appear and the fort becomes a respawn point.
- **Server state:** owner, capture progress, captain alive or dead,
  gate health and active guards.

## 6. Technical structure of the world

### 6.1 Independent zones

The world is not continuous. Each zone is a Godot scene with its own headless
server process, and the client only has loaded the zone it is in.
Zones are joined by **passes**: a road leaving the map, a port, a
dungeon entrance or a gate in the wall.

When crossing a pass:

1. The origin server checks that the player is inside the pass and out
   of combat, saves their state and hands them a single-use **handoff ticket**
   (destination zone, arrival point and an expiry of a few seconds).
2. The client shows the loading screen, loads the destination scene in a thread
   and connects to that zone's process presenting the ticket.
3. The destination server validates the ticket, loads the character and spawns them
   at the arrival point.

Goal: under 5 s of loading on an SSD. Each process has a player cap;
if a capital or a PvE zone fills up, another copy is opened (a
**channel**). Eldrun is never split into channels: it is a single battle.

The **wall gates** are the pass between a realm's border zone
and Eldrun. On the realm side they are a safe zone; on the Eldrun side they are the realm's
spawn point and the root of its Ember Lines. For now they cannot be
captured.

### 6.2 Zone types

| Type (`ZoneDefinition.Type`) | What it contains | Server | Examples |
|---|---|---|---|
| `CAPITAL` | Trade, crafting, quests, the Hall of Arms and trainers. Safe zone | One process per realm, with channels | Isenholm, Valcorin, Kassar |
| `PVE` | Open outdoors with a village or minor town, points of interest (camps, ruins, lairs), resources and dungeon entrances. Levels 1-45 | One process per zone, with channels | Hondal (1-10), Skarven (10-20), Grimfell (20-32), Hrimvald Glacier (32-45) |
| `DUNGEON` | Instanced interior for a group of 3-5 players of a single realm; **one shared Eld map per dungeon with an entrance in each realm** | On-demand instances: several per process, each in its own `World3D`, or one process per instance | D1-D6 ([6.7](#67-dungeons-d1-d6)) |
| `BORDER` | PvE zone 45-60 along the front wall, the final zone: two gates, the Bastion with the garrison, elite lairs and the entrances to D5 and D6 | One process per realm | Wolf March, Penitent Plains, Ossar Forges |
| `WARZONE` | PvP of the three realms: 6 forts, 3 castles and Aldcor, plus the PvE layer | A single process, no channels | Eldrun |
| `SKIRMISH` | Small normalized cutout of a front to test capture; entered from level 10 | One process | Vado Gris (phase 4) |
| `TEST` | Test scenes | One process | `test_world` |

Minor towns and villages go inside the PvE zones; they are not zones of their own. `SKIRMISH` and `WARZONE` zones are
**normalized** (`ZoneDefinition.normalized = true`): the same rules of level 60 for everybody, defined in [advancement.md](advancement.md).

### 6.3 Scale

Current character speeds: 5 m/s running and 7.5 m/s sprinting (`scripts/shared/player_character.gd`). One kilometer
running is about 3 min 20 s.

| Zone | Playable area | Total terrain | Regions of 256 m | Crossing it by road | Playable surface |
|---|---|---|---|---|---|
| Capital | 1 × 1 km | 1.5 × 1.5 km | 6 × 6 = 36 | 3-4 min | 1 km² |
| PvE 1-20 | 1.5 × 1.5 km | 2 × 2 km | 8 × 8 = 64 | about 5 min | 2.25 km² |
| PvE 20-45 | 2 × 2 km | 2.5 × 2.5 km | 10 × 10 = 100 | 7-8 min | 4 km² |
| Border 45-60 | 3 × 1.5 km | 3.5 × 2 km | 14 × 8 = 112 | 9-10 min along | 4.5 km² |
| Dungeon | 150-400 m of path | Interior | 0 (kit scenes) | 20-40 min the run | none |
| Eldrun | 3 × 3 km, and 4 × 4 if TEC-34 allows | 4 × 4 or 5 × 5 km | 256 or 400 | see the table below | 9 or 16 km² |
| Vado Gris (skirmish) | 300 × 300 m | 500 × 500 m | 2 × 2 = 4 | 1 min | 0.09 km² |

The **total terrain** includes a border of about 250 m that is not walked on (mountains, sea, cliffs) so that the horizon is not
left empty. The limit of the playable area is closed off by the terrain itself and, where that is not enough, by invisible
collisions.

- **Per realm:** about 18 km² playable. From the capital to the wall there are about 7.5 km of road: **about 25 min running
  and four loadings**; with fast travel (phase 7) it is a single loading.
- **Density:** a 1.5 km zone has about 23 places with something to do ([6.5](#65-leveled-pve-content-density)), one every
  310 m or about 60 s of walking; a 2 km zone, one every 365 m (about 75 s).
- **Respawn shrines** are within 450 m of any walkable point: coming back from a death costs 90 s at most. The validator checks it with a
  Voronoi over the navigation mesh.
- The precision rule stays (no zone larger than 8 × 8 km, [12.6](#126-numerical-precision)).

Road distances in Eldrun (4 × 4 km):

| Stretch | Distance | Running |
|---|---|---|
| Gate → nearby fort | 650 m | 2 min |
| Fort → fort on the same front | 750 m | 2.5 min |
| Fort → castle on its front | 550 m | 2 min |
| Castle → Aldcor | 1 km | 3.5 min |
| Gate → Aldcor | 2.2 km | 7-8 min |

Respawning at one's own strongholds (especially the Santuario de Ilse) shortens these times. If they turn out long in testing,
it drops to 3 × 3 km and everything shrinks by 25 %. The first version is 3 × 3 km.

### 6.4 Capitals and their districts

A capital is a 1 × 1 km safe zone with a city of 300-500 m (MUN-21). The districts:

| District | Contents | What for |
|---|---|---|
| Gate and arrival (two city gates) | Passes to zones 1 and 2, the central travel pole, stables (reserved for mounts) | MUN-33 and, later, MUN-40 |
| Market square | Merchants, bank and auctioneer | Trade of the realm |
| **Hall of Arms** | The **Master of the Orders** and **one mentor per specialization: six slots** (five specializations and the Sapper of phase 7) | Choosing the specialization at level 10, changing it and re-spending talents ([npcs.md](npcs.md#71-roles)) |
| **Training yard** | Practice dummies for each weapon family, a sparring ground, the weapon trainer | Combat teaching and the weapon families |
| **Crafts quarter** | 5-6 stations: smelter, forge, tannery, carpentry, alchemy and refining | Crafting |
| War room | Commission board, war map and realm panel | Connects the capital with Eldrun |
| Inn | Quest givers, social place | MUN-17 and MUN-19 |
| Realm landmark | Isenholm: the Jarl's great hall at the head of the fjord. Valcorin: the cathedral. Kassar: the monumental anvil | Own Blender piece (ART-22, 36, 37) |
| Residential filler | Houses of the Village kit recolored, closed doors | Visual layer only |

- **Ambient NPCs:** 60-120 following pre-recorded routes on the navigation mesh, without physics. The criterion of MUN-19 (40 NPCs
  in under 0.5 ms per tick, about 12 µs each) is reachable only without `simulate()`.
- **Channel:** starts at 64 players (the default) and the target once measured is 100. There is no combat in the capital.
- **Performance:** HLOD per block and baked occluders (ART-23), with the same budget of 2000 draw calls as MUN-21.
- The core of Isenholm for the first vertical slice is described in the appendix of [Hondal](zones/hondal.md#appendix-isenholm-core-district-first-vertical-slice).

### 6.5 Leveled PvE: content density

Starting figures per zone, so that points of interest, NPCs, items and quests have places to fill:

| | Zones 1 and 2 (1.5 km) | Zones 3 and 4 (2 km) | Border (3 × 1.5 km) |
|---|---|---|---|
| Villages or centers (givers, travel, shrine) | 2 | 3 | Bastion + 2 gate camps |
| Hostile points of interest ([6.9](#69-points-of-interest)) | 8-10 | 12-14 | 10-12 |
| Named elites | 3 | 5 | 6 |
| Zone boss (world boss) | 0-1 | 1 | 1-2 |
| Respawn shrines | 5-6 | 8-10 | 8 |
| Travel poles | 2 | 3 | 3 (Bastion and the two gates) |
| Watchtowers or lookouts (discovery) | 3 | 4 | 3 |
| Event arenas (MUN-31) | 1 | 1-2 | 2 |
| Dungeon entrances | 0-1 | 1-2 | 2 |
| Named places (discovery) | 10-14 | 14-18 | 12-16 |
| Hostile NPCs placed | 150-200 | 220-300 | 250-320 |
| Gathering slots | 120-180 | 180-260 | 180-240 |
| Quests (a guide figure for the quest domain) | 20-25 | 30-35 | 25-30 + dailies |
| Hours of the first run | 3-4 h | 5-6 h | about 5 h + repeatables |

- **Hub and spoke structure:** each quest hub groups 3-5 points of interest at 300-600 m. The main road joins the hubs and the
  passes, and the main chain goes from the entry pass to the exit pass. `ZoneLayout.hub_order` ([8.4](#84-zonelayout-tools-only))
  fixes that order and the validator checks it is respected along the road.
- **Identity:** each zone carries 2-3 own landmarks (Blender pieces made by script, like the fort tower) so that it does not
  look like the next one even if it shares a biome.
- **Biomes that are shared** to make it cheaper: Hondal and Wolf March (pine and burnt pine), Grimfell and Hrimvald (snow),
  Amber Fields and Penitent Plains (fields), Ash Waste and Ossar Forges (volcanic). That gives **4-5 biome profiles per realm**
  (ART-38/42/43 go from 3 to 4-5), plus Eldrun's and the dungeon interior.

### 6.6 Border zones, wall and gates

- **Layout:** the front wall runs along the long side (about 3 km) with its two gates about 2 km apart. The **Bastion**
  (the garrison) stands in the center, about 150 m from the wall, and has travel, quartermaster (PRG-33), board, war map,
  upgrade station, bank, respawn point and the entrances to D5 and D6. On the inner side of each gate there is a safe camp of
  30 m radius with Gate Guardians (MUN-12). The rest of the zone is 45-60 content.
- **The wall is a kit shared by two zones:** the same pieces form the inner face in the border and the outer face in Eldrun, so
  it looks the same from both sides. Vardheim and Solmarch already have a tower and a gate body in `scenes/world/props/walls/`;
  Askarra still lacks them ([art.md](art.md#75-the-frontier-wall-kit-art-82)). The fit to the terrain takes what ART-61 did for the Vado Gris.
- The outer stretches of the wall (toward the sea, the desert or the mountain) are only seen: they are scenery in the non-playable
  ring of the zones that face the edge of the realm.
- **Two steps without redoing the zone:** in the first, the `ZoneLayout` is generated at full size and only the Bastion, the gate and
  the road are dressed and populated; the rest is terrain with automatic scatter and no enemies, and the 45-60 content arrives with the
  tier T5 and its quests. This replaces the "reduced 1.2 × 0.8 km version" of MUN-23: as the terrain is generated, the final size costs
  hardly more and the arrival points do not change id.

### 6.7 Dungeons D1-D6

- **One map, three entrances:** the interior is Eld (the kit of ART-31 plus a new interior kit, [art.md](art.md#74-the-eld-dungeon-interior-kit-art-83)).
  In each realm the entrance is built with that realm's kit: in Vardheim you go down through a burial mound, in Solmarch through the crypt
  of an abbey and in Askarra through a mine shaft. All three reach the same buried rooms.
- **Instances:** one per group of 3-5, of a single realm. The `DUNGEON_ENTRANCE` pass requests the instance (TEC-38) and the exit
  returns to the arrival point of the entrance of its realm. A Vardheim group and a Solmarch group receive separate instances of
  the same map.

| Id | Name (provisional) | Levels | Entrance in | Theme |
|---|---|---|---|---|
| D1 `dg_ossuaries` | Ossuaries of Eld | 15-19 | Zone 2 | Crypts of the garrison: the Hollow |
| D2 `dg_sunken_aqueduct` | Sunken Aqueduct | 24-29 | Zone 3 | Eld canals, water and corruption |
| D3 `dg_oath_archive` | Oath Archive | 35-39 | Zone 4 | Where the oath of the three lineages was kept |
| D4 `dg_flame_foundry` | Flame Foundry | 41-45 | Zone 4 | Where the Embers were forged |
| D5 `dg_sundering_roots` | Sundering Roots | 50-55 | Border | Caverns of the rift |
| D6 `dg_last_king` | Last King's Chamber | 60 | Border | The finale, the hardest |

Each dungeon is built once (about 6 agent sessions) and then its three entrances are needed (half a session each). A dungeon open
under Aldcor for the dominant realm, in the style of Darkness Falls, is left for after launch as a proposal to the war domain.

### 6.8 Fast travel and mounts

- **A network per realm** (about 14 poles): capital (center), 2 in zone 1, 2 in zone 2, 3 in zone 3, 3 in zone 4 and 3 in the border.
  Each pole opens on discovery (interacting, MUN-16). The Bastion opens with "Call to the front". **Fast travel is phase 7
  (MUN-33)**; the markers exist from phase 6.
- **Gold cost per zone hop** (the values are PRG-12's): same zone ×1, adjacent ×2, farther ×3, and half toward the capital or the
  Bastion. **Return** to the capital or the inn is free every 20 min, with the timer saved like `/atascado` (CMB-30).
- Only out of combat. Travel inside the same zone is a server teleport; between zones it is a handoff to the arrival point of
  the pole. It never leads to Eldrun, where one respawns at one's own strongholds.
- **Hooks for mounts** (MUN-40, after launch): main roads 6 m wide and without stairs, city gates at least 4 m, and `no_mount`
  volumes in `ZoneLayout` (capital interiors, fortress radius and dungeons). When mounts arrive only data changes.

### 6.9 Points of interest

Each type is a `PoiTemplate` ([8.3](#83-poitemplate)) with a prefabricated scene per realm where needed, generated by script like
`tools/props/build_vado_gris_props.gd`. The scenes carry markers in groups that already exist (`npc_spawners`, `respawn_points`,
`screenshot_points`) and in new groups (`resource_nodes`, `quest_anchors`, `travel_points`, `interactables`).

| Type | Footprint (radius) | Generator slots | Resources | Quest anchors | Notes |
|---|---|---|---|---|---|
| Camp (bandits, deserters) | 25-35 m | 3-4 groups + optional boss | 0-2 | 2 | Tents, partial palisade, campfire, chest |
| Lair (wolves, bears, boars) | 20-30 m | 2-3 packs | herbs | 1 | Rock cave, bones |
| Eld ruin (the Hollow) | 30-50 m | 3-5 | stone | 2-3 | Readable inscriptions (MUN-16) |
| Sundering rift | 25-40 m | 3-4 + elite | Ember (high level) | 2 | Emissive rift |
| Village or center (friendly) | 60-120 m | guards | none | 6-10 | Givers, travel pole, shrine |
| Raided farm | 30-40 m | 2-3 | crops | 2 | none |
| Mine or quarry | 30-50 m | 3-4 | 6-10 veins | 2 | Optional short interior |
| Respawn shrine | 6-10 m | 0 | none | none | `respawn_points` with the zone's realm |
| Watchtower or lookout | 10-15 m | 0-1 | none | 1 | Discovery and a view for the capture |
| Elite lair | 30-40 m | elite + 2-4 | chest | 1 | Cleared arena |
| Dungeon entrance | 20-30 m | 0-2 | none | 1 | `DUNGEON_ENTRANCE` pass |
| Event arena | 60-80 m | by event | none | none | For MUN-31 |
| Landmark | variable | 0 | none | 1 story | Unique Blender piece |

Minimum separations: 120 m between hostile points of interest and 60 m from any spawner to an arrival point, a safe zone or a
pole. Maximum slope under the footprint: 12 degrees; the generator flattens with blending. A **story point of interest** such as
the Sealed Gate of Hrimgard is built from the landmark and Eld ruin templates and is not a dungeon.

### 6.10 Strongholds: forts, castles and Aldcor

Initial proposal; the numbers are adjusted when measured.

| | Fort | Castle | Aldcor |
|---|---|---|---|
| How many | 6, two per front | 3, one per front | 1, at the center |
| Size | 40–60 m per side | 150–200 m | About 400 m, in three rings of ruins |
| Defenses | Palisade or low wall with walkway, one gate and a tower with the standard | Outer and inner wall with towers, two gates and a keep | Rings of broken wall with breaches; the standard, in the chamber of the Flame |
| NPC defenders | 4 guards and the captain | 12–16 guards (archers on the battlements) and the castle lord | To be defined |
| Capture | Kill the captain and hold the circle 30 s | Break both gates, kill the lord and hold the circle 60 s | Only with 2 of 3 castles; the rest, to be defined |
| Siege | The gate falls to blows | The gates withstand blows; siege weapons are needed | To be defined |
| Target duration | 3–5 min | 20–30 min | 30–45 min |
| Embers per minute | ×1 | ×3 (Sarnath, ×4) | Greater blessing while the Flame burns |

### 6.11 Road network: the Ember Lines

A **front** is the strip of Eldrun between two realms. Each has one
castle and two forts, and each fort sits in front of the gate of one of the
two realms:

| Front | Castle | Fort on one side | Fort on the other side |
|---|---|---|---|
| Northwest (Vardheim–Solmarch) | Velmont | Vado Gris, in front of the Puerta del Lobo | Atalaya de Brenn, in front of the Puerta Áurea |
| Northeast (Vardheim–Askarra) | Grauholt | Cantera de Odd, in front of the Puerta de Hrafn | Mina de Kerth, in front of the Puerta del Cañón |
| South (Solmarch–Askarra) | Sarnath | Santuario de Ilse, in front of the Puerta de los Penitentes | Puente de Hadrin, in front of the Puerta de Ceniza |

All three fronts have the same roads:

- **Gate → its fort.**
- **Fort ↔ fort on the same front:** the cross road, which is the line of the
  front. In the northwest it crosses the river by the ford of the Vado Gris; in the south,
  the crack of embers by the bridge of the Puente de Hadrin; in the northeast, the mountain
  pass under Grauholt.
- **Each fort → the castle on its front.** The road from the Vado Gris to Velmont
  runs down the riverbank and is the shortest of the front.
- **Castle → Aldcor.**

There are no roads between castles: to reach the third front you have to go through
Aldcor. Consequences:

- At the start, all forts are neutral and guarded by the Hollow. Each
  realm can attack its two nearby forts from the first minute; the
  rival's, only once it holds its own.
- A castle can be attacked from either of the two forts on its front.
- Each realm touches two castles, so the natural path to Aldcor (2 of 3
  castles) is winning its two fronts.
- Isolation example: Solmarch holds the Atalaya de Brenn, the Vado Gris and
  Velmont. Vardheim retakes the Vado Gris from the Puerta del Lobo and, from there,
  takes the Atalaya. Velmont no longer has a chain to any Solmarch gate:
  it becomes isolated and its defenders weaken.
- Each road has braziers. They burn in the owner's color when they link two
  strongholds of theirs connected to their gate, and go out if the chain breaks.
  This way the state of the war can be read from the ground, without opening the map.
- The phase 4 map is a compressed version of the northwest front: only the
  Vado Gris and the two gates about 150 m away, without the Atalaya or Velmont, so
  both realms can attack it from the start.

## 7. Visual identity

### One kit and four palettes

- **One main kit**, modular low-poly CC0 in glTF, from a single family of
  packs so that the style matches. The specific choice of packs, their licenses and
  how they are imported are in [art.md](art.md). Before importing a pack its
  license is checked and where it comes from is recorded.
- **One scale:** 1 unit = 1 m (an adult is about 1.8 m tall). If a pack comes
  in another scale it is fixed at import, not by hand in each scene.
- **The same materials in all realms:** the pieces use a fixed set of
  materials (wall stone, detail stone, wood, roof, metal, cloth…), and
  each realm has its own version of each one. The same mesh serves all three and
  changing the materials recolors a whole city. Since multiplying the color
  only darkens, the change is made with a per-realm surface shader that
  adjusts hue, saturation and brightness and adds a layer (snow, moss, dust or
  ash); the detail is in [art.md](art.md).
- **Few custom pieces per realm** (3–5): the roof, the tower tops and
  a few landmarks. Walls, floors, stairs, doors, windows, crates, barrels,
  carts and fences are shared.
- **Side color kept separate:** banners, braziers and guard tabards
  take the owner's color through a per-instance shader parameter
  (`instance uniform`; in a MultiMesh, the per-instance color). Capturing a
  fort changes neither meshes nor materials.
- **Contrast:** the realms use medium, low-saturation colors; Eldrun is
  desaturated. There the only intense colors are the embers and the side
  colors, so that in combat you can see at a glance who is who.

### Palette by material

Target colors for each material; each realm's shader is tuned until it
gets close to them.

| Material | Vardheim | Solmarch | Askarra | Eldrun |
|---|---|---|---|---|
| Wall stone | Cold gray rough stone `#737A80` | Pale limestone `#DCD3C1` | Red sandstone `#A9583B` | Eld stone, desaturated greenish gray `#8C8D84` |
| Detail stone | Knotwork carvings `#8E959A` | Ashlar `#C8BDA6` | Light sandstone `#C98A5E` | Worn ashlar blocks `#A3A39A` |
| Structural wood | Almost black wood `#3A2F28` | Light oak of the half-timbering `#8A6A4A` | Reddish cedar `#7A4A2E` | Rotten gray wood `#5E5850` |
| Roof | Gray planks `#5E564E` | Blue slate `#4A5870` | Terracotta `#B9643A` | No roofs (ruin) |
| Plaster and ground | Mud and peat `#5C4A3A` | White plaster `#EDE6D6` | Ochre plaster `#D9A86C` | Ash `#8F8A82`, burnt earth `#5A4A3E` |
| Metal | Iron `#3F4448` | Wrought iron `#3B3B40` and gold `#C9A227` | Bronze `#A97B3D` with patina `#5B8F7B` | Rusted iron `#6E4A35` |
| Cloth | Furs `#7A5A3E` and gray wool `#8C8F92` | White `#F5F2E9` and gold `#C9A227` | Crimson `#8E1B26` and ochre `#C99A4A` | Gray rags `#9A948A` |
| Water | Cold water `#3E5A6A`, snow `#E6EDF1` | Greenish river `#5D7A6A` | Turquoise oasis `#3F8A86` | Gray river `#5F7A86` |
| Emissive | Braziers `#FFB060`, auroras `#5CE1B0` | Stained glass: cobalt `#2D56A8`, ruby `#A22F3A`, amber `#E4A436` | Forges and cracks `#FF7A1F` | Embers `#FF8A2A` |
| Extra layer | Snow on upward-facing surfaces | Moss and ivy | Dust and ash | Ash |

### Vardheim
- **Key pieces:** longhouse with a gabled plank roof that almost touches the
  ground and a ridge with carved heads; palisade of sharpened logs; square
  rough-stone tower with a wooden gallery; the log gate of the Muro
  de Escarcha; pier and beached ship (Skarven); runestone with knotwork
  carvings; burial mound (Grimfell).
- **Vegetation:** dark pine and fir, white-barked birch, purple heather,
  straw-colored tundra grass, moss and snow-covered rocks. In the Marca del Lobo,
  burnt trunks and ash.
- **Sky and light:** low sun (15–25° above the horizon) and cold white, bluish
  ambient light, low clouds and fog in the fjords. Long shadows. At night,
  green auroras.

### Solmarch
- **Key pieces:** conical slate tower; crenellated limestone wall of the
  Muralla del Alba; buttress with flying buttress; large window and rose window with stained glass;
  modular cathedral (nave, transept and apse) for Valcorin; half-timbered house;
  arch bridge; vineyard trellis; wayside cross of the Order of the Dawn.
- **Vegetation:** oaks and beeches, poplars along the rivers, vineyards in rows,
  golden wheat fields, hedges and flowering meadows. In the Ciénaga de Morvel, greenish
  brown water, dead willows, reeds and yellowish fog.
- **Sky and light:** mid-height sun (35–50°), big cumulus clouds, showers and
  river mist in the morning; golden sunsets. In Morvel, dense fog and
  sickly light.

### Askarra
- **Key pieces:** low terracotta dome; round arch; facade
  carved into the rock (wall panels with openings that attach to the
  cliffs); terraced platform; forge chimney with smoke; a
  monumental anvil as the landmark of Kassar; cloth awnings; oasis waterwheel; suspension bridge
  over a canyon.
- **Vegetation:** sparse. Palms and reeds in the oases, flat-topped acacias,
  dry scrub and agaves. In the Yermo de Ceniza, basalt, charred trees and
  glowing cracks, no grass.
- **Sky and light:** high, harsh sun (55–70°), pale sky with haze on the
  horizon, short shadows and air shimmering with heat. In the Yermo and the
  Forjas de Ossar, ash rain and columns of smoke.

### Eldrun
- **Architecture:** that of the old kingdom of Eld, which resembles no
  current realm: large ashlar blocks of greenish gray stone, round arches,
  aqueducts, paved roads and broken statues of the three lineages. All
  forts and castles use this kit; the forts mix a log palisade
  and a stone tower, like the Vado Gris. When a stronghold is captured only
  banners, braziers and guards change.
- **Aldcor:** monumental ruin sunk into the Sundering, with the chamber of the Flame
  at the center. Extinguished, there are only embers; rekindled, a column of fire in the
  color of the realm that holds it is visible from all over Eldrun.
- **Ground and vegetation:** burnt earth, ash, dead grass, dead forests,
  thorny scrub and fallen trunks. Next to each wall it blends with the
  neighboring biome: burnt pines in the north, abandoned vineyards in the southwest and
  red rock in the southeast.
- **Sky and light:** perpetual storm (clouds `#3C424B` and lightning), dim,
  desaturated directional light, orange fill from the cracks and ash
  in the air. Fog limits the view to 400–600 m, which also helps
  performance; the castles and Aldcor are tall enough to stand out against
  it and serve as reference points.

### Side colors

| Side | Color | Hex | Banner | Road braziers |
|---|---|---|---|---|
| Vardheim | Ice blue | `#7EC8E8` | White wolf on steel gray | Bluish-white flame |
| Solmarch | Gold | `#E9C341` | Golden split sun on white | Golden flame |
| Askarra | Crimson | `#C3242F` | Bronze anvil over a crack | Red flame |
| Neutral (Hollow) | Bone gray | `#BDB6A6` | Broken crown of Eld, faded | Extinguished |

The orange of the embers (`#FF8A2A`) is not used as a side color. The
banner always combines color and shape, so that it can also be told apart with
color blindness.

## 8. Data formats and validators

Everything is text `.tres`. The shared part loads nothing visual: client resources go as paths (`String`), never with `preload`,
so that the server does not load them (`scripts/shared/` depends on nothing in `scripts/client/` or `scripts/server/`).

### 8.1 `ZoneDefinition` (MUN-13)

`scripts/shared/world/zone_definition.gd`, one `.tres` per zone, gathered by the `WorldDefinition`:

```gdscript
class_name ZoneDefinition
extends Resource
enum Type { CAPITAL, PVE, BORDER, DUNGEON, WARZONE, SKIRMISH, TEST }

@export var id: StringName                         # [a-z0-9_]{1,32}
@export var name_msgid: String                     # English msgid, L10n context "place"
@export var type: Type
@export var realm: StringName                      # "" in Eldrun, dungeons and tests
@export var pvp_mode: int                          # Zones.PvpMode (SAFE in capital, PvE and border)
@export var level_min: int = 0                     # 0 = no levels (capital, RvR)
@export var level_max: int = 0
@export var normalized: bool = false               # Eldrun, Vado Gris, test_world: level 60 rules for everybody
@export var playable_size_m: Vector2
@export var terrain_size_m: Vector2i               # multiple of 256
@export_file("*.tscn") var gameplay_scene: String  # generated (9.3)
@export var visual_scene: String                   # client only; a path, never preload
@export var arrivals: PackedStringArray            # marker names; ticket arrival = index + 1 (at most 255)
@export var passes: Array[ZonePass]
@export var travel_points: Array[TravelPoint]
@export var dungeon_ids: Array[StringName]         # entrances in this zone
@export var admitted_realms: Array[StringName]     # empty = its own; Eldrun = all
@export var max_players_per_channel: int = 48
@export var max_channels: int = 4                  # 1 = no channels (Eldrun)
@export var instanced: bool = false                # dungeons
@export var day_night: bool = true                 # MUN-27 (false in Eldrun and Vado Gris)
@export var weather_set: StringName
@export var biome_profile: String                  # ART-24, client
@export var map_definition: String                 # UI-20
@export var world_map_anchor: Vector2              # position 0..1 on the world map (UI-32)
@export var budget: ZoneBudget                     # section 11
```

- `ZonePass`: `id` (the name of the pass volume in the gameplay layer), `kind` (ROAD, PORT, WALL_GATE, DUNGEON_ENTRANCE,
  DUNGEON_EXIT), `to_zone`, `to_arrival`, `min_level` (mandatory in WALL_GATE, set by PRG-31, which also covers the provisional pass
  to the skirmish map; elsewhere a warning when crossing) and `prompt_msgid` ("Cross to Hondal").
- `TravelPoint`: `id` (unique in the world, `<zone>/<pole>`), `marker`, `name_msgid`, `hub: bool`, `known_from_start: bool` and
  `unlock_quest: StringName`.
- `ZoneBudget`: `max_draw_calls`, `max_primitives`, `max_load_s`, `max_server_rss_mb`, `max_hostile_npcs`, `max_awake_npcs` and
  `max_generated_mb`.
- The ticket carries the arrival in a `u8`: 0 is the default point and n ≥ 1 is point n - 1 (`platform.md`), so a zone has at
  most 255 arrivals. The zone id on the wire has at most 32 B of ASCII (`NetZones`).

### 8.2 `WorldDefinition` and `DungeonDefinition`

`data/world/world.tres`: `level_cap: int = 60` (the validator demands it equals `LevelCurve.level_cap`), `zones:
Array[ZoneDefinition]`, `dungeons: Array[DungeonDefinition]`, `realm_entry`, `realm_capital`, `realm_border`
(`Dictionary[StringName, StringName]` from realm to zone), `warzone: StringName = &"eldrun"` and `travel_costs` (table of
[6.8](#68-fast-travel-and-mounts)). It is read by `ZoneCatalog` (`scripts/shared/world/zone_catalog.gd`), which replaces the constant
dictionaries of `Zones` (`SCENES`, `PVP_MODES`, `MAX_PLAYERS`) and `_ZONE_REALMS` of `RealmCatalog`. The group constants of `Zones` stay.

`DungeonDefinition` (`data/dungeons/<id>.tres`): `id`, `name_msgid`, `level_min`, `level_max`, `group_min = 3`, `group_max = 5`,
`zone_id` (its `ZoneDefinition`, of type `DUNGEON` and instanced), `entrances` (a `Dictionary` from realm to `<zone>/<pass>`) and
`target_minutes = (20, 40)`.

### 8.3 `PoiTemplate`

`data/world/poi_templates/<type>.tres`: `category` (the 13 types of [6.9](#69-points-of-interest)), `scenes: Dictionary[StringName,
String]` (realm → scene; the key `""` is the shared one), `footprint_radius`, `flatten_radius`, `clear_scatter_radius`,
`min_spacing`, `max_slope_deg`, `spawner_slots`, `resource_slots`, `review_camera` (offset and target) and `map_icon`.

### 8.4 `ZoneLayout` (tools only)

`data/zones/<id>/layout.tres`, classes in `tools/zones/layout/`. It is the source of truth of the geometry and generalizes
`tools/terrain/vado_gris_layout.gd` from code to data:

- `seed`, `terrain_size_m`, `playable_rect` and `biome`.
- `relief`: base height, noise layers (the `FastNoiseLite` parameters as data), edge ridge to close the outline (height 25 to 60 m,
  width) and `strokes` (polylines with height, width, falloff and mode SET, ADD, MAX or MIN, for valleys, plateaus and ridges).
- `water`: rivers (polyline, width, depth and ford stretches), lakes (polygon and level) and sea.
- `roads`: polyline, width (main 6 m, trail 3 m), type (MAIN, TRAIL, PAVED_ELD) and maximum slope (18° on main, 25° on trails).
- `areas`: polygon with ground type, density and the biome's scatter rule.
- `pois` (`PoiPlacement`: `id`, template, position, rotation, level, realm variant, the hub it belongs to, tags), `passes`,
  `places` (polygon and `name_msgid`), `landmarks`, `no_mount` and `extra_cameras`.
- `hub_order`: the order of the hubs for the main chain.

Before generating terrain, a **plan view** of a few seconds (`tools/zones/plan_view.gd`) draws roads, water, areas and points of
interest into a PNG. It is the first capture of every zone.

### 8.5 Places and discovery

`places` come out of the `ZoneLayout` to `scenes/world/zones/<id>/generated/places.tres` (a `PlaceSet` with id, name and polygon). The
server checks every 30 ticks whether each player is inside a polygon (about 15 per zone, negligible cost) and emits `PLACE_DISCOVERED`.
That event is used by quests ("reach an area", MUN-17), discovery experience (PRG-22), the map and achievements (PRG-42).

### 8.6 Validators

**A. `tests/test_world_data.gd`** (data, fast, in CI):

- Unique ids, at most 32 B of ASCII, existing files and `level_cap` equal to `LevelCurve`'s.
- Reciprocal passes; the `to_arrival` exists in the destination's `arrivals`, and there are at most 255 arrivals.
- Per realm: the graph is connected from the entry zone to the border; the union of the PvE and border ranges covers 1 to the cap
  with no gaps, with overlaps of at most 3 levels; `level_min` rises along the path. The one exception to isolation is the provisional
  Hondal → Vado Gris `WALL_GATE`, which carries a mandatory `min_level`.
- **Realm isolation:** no pass goes from a zone of one realm to one of another realm; only `WALL_GATE` leads to `WARZONE` or `SKIRMISH`.
- Each dungeon has exactly one entrance per open realm, and the level range of the zone of each entrance overlaps the dungeon's.
- Fortress ids unique across the world. PvP modes consistent with the zone type. Every zone has a budget. Each realm has a travel
  pole that is a hub in the capital and another in the Bastion.
- Optional and cheap: every name in `world.tres` appears in `docs/world_map.svg`, so that the map is not left behind.

**B. `tools/zones/validate_zone.gd <zone>`** (geometry, after generating; in CI over the generated zones):

- Arrivals, passes, centers of points of interest, poles and shrines reachable by navigation from the main arrival.
- Closed outline: navigation does not leave the playable rectangle plus 10 m, and rays every meter along the edge hit a collision or
  a drop greater than the jump.
- Roads: maximum slope respected and width free of gameplay collisions.
- The separations of 6.9, shrine coverage (≤ 450 m from any navigation polygon) and step-to-step road times within the expectation of 6.3.
- Estimated budget per cell (instances × LOD triangles) and the count of hostile NPCs; **kill capacity** of the camps.
- Output: `build/zones/<id>/validate.json` and **a plan image with the layers** (reach, shrine coverage, points out of budget), which
  is itself a capture of the increment.

**C. Visual measurement** (`tools/render/render_screenshot_points.gd -- --zone=<id>`): needs a window and a GPU, so it runs locally.
It gives the real figures of section 11 per camera, in `metrics.json`.

The spawn tables per point of interest (NPC definition, number, level offset, respawn) can live in CSV
(`data/zones/<id>/spawns.csv`) and pass through the CSV-to-`.tres` generator. Their validator checks that the NPCs exist, that levels
fall inside the zone's range ±2 and that the total fits the budget.

## 9. The zone kit

### 9.1 New code (MUN-13, MUN-05, MUN-14, MUN-45)

| Piece | File | Item |
|---|---|---|
| Definitions and catalog | `scripts/shared/world/{zone_definition,zone_pass,travel_point,zone_budget,world_definition,dungeon_definition,zone_catalog,world_graph}.gd` (`world_graph`: pure checks and hops between zones for the travel cost) | MUN-13 |
| Cell colliders | `scripts/world/cell_colliders.gd`: reads arrays (`PackedFloat32Array` of x, z, radius and height per cell) and creates the bodies with `PhysicsServer3D`, the same on client and server | MUN-45 |
| Client grass | `scripts/client/world/grass_field.gd`: grass around the camera from the control map and the Terrain3D height, with no saved instances | ART-81 |
| Passes and arrivals | `scripts/server/world/zone_portal_system.gd` (over the `ZonePortal` of TEC-30) | TEC-30 |
| Travel | `scripts/server/world/travel_service.gd` | MUN-33 |
| Discovery | `scripts/server/world/discovery_tracker.gd` | MUN-58 |
| Generator | `tools/zones/build_zone.gd -- --zone=<id> [--steps=terrain,water,roads,pois,scatter,markers,nav,map,cams]`, plus `terrain_builder`, `paint_builder`, `water_builder`, `road_builder`, `poi_placer`, `scatter_builder`, `marker_builder`, `review_cameras` and `plan_view`. `build_world.gd` generates every zone using the cache | MUN-14, MUN-45 |
| Validator | `tools/zones/validate_zone.gd` and `tests/test_world_data.gd` | MUN-45, MUN-13 |
| Export to the platform | `tools/world/export_world.gd` → `world_rules.json` (ids, types, capacities, realms and entry zone), like `progression_rules_export.gd` | MUN-61 |

Existing files that change: `scripts/shared/zones.gd`, `scripts/shared/net/net_zones.gd` and `scripts/shared/war/realm_catalog.gd`
read from `ZoneCatalog`; `scripts/world/zone_root.gd` no longer needs `strip_for_server()` once the visual layer is apart;
`scripts/server/zone_server.gd` loads only `gameplay_scene` (to coordinate with TEC-65); `scripts/client/client_main.gd` instantiates both
layers; `npc_navigation.gd` and `tools/bake_navmesh.gd` move to navigation tiles of 256 m with several connected regions; the zone map
tools take the zone as a parameter (a base image at 1 px/m plus 256 m tiles at 3 px/m for the minimap, generated and not versioned);
`tools/render/render_screenshot_points.gd` (`--zone`, metrics in JSON), `tools/quality/run.py` and `sc_mundo.gd` (`mundo --zone=<id>`);
`tools/terrain/generate_vado_gris.gd` and `vado_gris_layout.gd` become the first client of the kit with the same gameplay layer (the
criterion of MUN-14); `tests/test_architecture.gd` also checks that `scripts/` does not depend on `tools/zones/`; and
`platform/internal/config/config.go` makes the default `ELDMARK_ENTRY_ZONES` the zone 1 of each realm when it exists.

### 9.2 The two layers

Each zone is split into two layers (MUN-05 applied to every zone):

| Gameplay layer (server and client) | Visual layer (client only) |
|---|---|
| Terrain with collision, cell colliders, buildings with collision, deep water (until MUN-44), markers, passes, fortresses, navigation | Meshes, MultiMesh per cell with visibility range, grass, water, `Environment`, lights, audio, particles, HLOD, occluders |

`ZoneDefinition.budget.max_server_rss_mb` is measured with the server loading only the gameplay layer.

### 9.3 Generated zone data (pending decision P1)

> **Pending the user's decision (P1).** The recommendation is to take the generated data out of git; until it is decided, the
> interim rule below applies and `CLAUDE.md` is not changed.

**The problem.** A Terrain3D region of 256 m weighs today 2.5-2.65 MB, with the grass inside the instancer. Without grass it is
estimated at about 0.85 MB (height and control at 4 B per pixel, color in RGBA8 with mipmaps; K3 measures it). With the sizes of
[6.3](#63-scale) that is about 31 MB per capital, 54 MB per 1.5 km zone, 85 MB per 2 km zone and 95 MB per border: **about 400 MB per
realm and 1.5 GB with Eldrun**, not counting navigation or MultiMesh. Each regeneration makes git store another full copy of the
binary, which is not viable in a public repo without LFS (only Hondal and Isenholm would be about 260 MB with grass).

**The proposal (if P1 is accepted).**

- **Versioned:** `ZoneDefinition`, `ZoneLayout`, `PoiTemplate`, prefabricated scenes, the generator code, biome profiles and
  hand-painted masks at 4 m/px at most, if a zone needs them.
- **Generated** in `scenes/world/zones/<id>/generated/`, ignored by git: Terrain3D regions, `_gameplay.tscn`, `_visual.tscn`,
  navigation, collision cells, MultiMesh, `places.tres` and baked maps. As they are not versioned they can be binary (`.res`), which
  loads faster; the text rule of `CLAUDE.md` is for what is versioned.
- **Cache:** the key is the sha256 of the inputs plus the generator version. Locally it lives in `../Eldmark-cache/zones/<id>/<hash>/`,
  shared between worktrees so that 26 maps are not regenerated in each new worktree. In CI it uses `actions/cache`. The export
  (TEC-12) generates once and takes client and server from there.
- **`zone_build_hash`** (u32) in `WELCOME`: the client compares it with its own and, if it differs, refuses with "different zone
  version". It also covers the last-decimal difference between a generation on Windows and one on Linux that
  [vado_gris.md](zones/vado_gris.md) documents. It bumps `PROTOCOL_VERSION`.
- The Vado Gris stays versioned (10 MB) until the kit ports it; from then on it follows the same rule and the old blobs stay in
  the history. This is item TEC-67.

**Interim rule (until the user decides):** the **grass is not saved** (the client generates it, W10) and the Terrain3D regions are
**versioned only when an increment closes**, never at every intermediate regeneration. The first measurement (K3) of the zone kit
gives the real MB per region with and without grass; with grass dropped, Hondal and Isenholm come to about 85 MB.

## 10. Producing a zone with agents

Opus designs and reviews; Sonnet executes (the user's preference). Each step is a session, except where noted, and **ends with
captures**, archived before and after in `Eldmark-capturas`.

| Step | Who | Input | Output | Automatic check | Captures |
|---|---|---|---|---|---|
| P1 Sheet | Opus | This document and the main chain | `docs/zones/<id>.md`: identity, role in the story, ASCII plan, table of points of interest, hubs, passes, poles, shrines, Blender landmarks, NPC families and resources asked from other domains, manual cameras and risks | none | Plan view of the initial `ZoneLayout` |
| P2 Layout and gray model | Sonnet | The sheet | `layout.tres` and gray terrain (relief, water, roads, outline) | `test_world_data` and validator B on outline, slopes and road times | Plan, 4 aerials, baked map and a video of the bot walking the road |
| P3 Points of interest and markers | Sonnet | Templates ([6.9](#69-points-of-interest)) | Placed points, passes, arrivals, safe zones, shrines, poles, empty generators, resource slots, anchors, baked navigation | Full validator B | Review cameras of each point (gray model) and the layers image |
| P4 Scatter and painting | Sonnet | Biome profile (ART-24, 38, 42, 43) | Vegetation and rock cells with collision, painted terrain, water | Validator B (estimated budget) and the same gameplay layer in the playable part | Review cameras with metrics (section 11) |
| P5 Population (1-2 sessions) | Sonnet | Bestiary ([npcs.md](npcs.md)), loot and gathering tables | `spawns.csv` or `.tres`, elites, boss and nodes | Generator validator; a test with bots clearing a camp; tick p99 with bots | Combat at 3 points of interest and server metrics |
| P6 Quests and story (another domain) | none | Anchors, places and hub order | Quests (MUN-17, 28, 46) | Reference validator of MUN-28 | Video of the chain |
| P7 Ambience and polish | Sonnet, reviewed by Opus | Blender landmarks, audio, light | Final pass | Measured budget (C) | Before and after of all cameras, index |

- **Automatic review cameras** (step P3, `review_cameras.gd`): two per point of interest (approach at 1.7 m and three-quarter aerial),
  one per pass and pole, four corner aerials plus an overhead, and one every 300 m at player height along the main road. The manual ones
  of the `ZoneLayout` are added. All go in `screenshot_points` with the `fov` metadata, which already exists.
- **Capture bench:** `python tools/quality/run.py mundo --zone=<id> [--steps=plan,cameras,route,metrics]` saves to
  `build/zones/<id>/<step>/` and regenerates `index.md` and the contact sheet (`contact_sheet.py`).
- **Sessions per zone**, approximate and without quests: capital 7-9; 1.5 km PvE 6-7; 2 km PvE 8-9; border 3 (lite) + 6 (full);
  dungeon about 6 + 3 entrances. Templates make the second and third realm about 20 % cheaper. **For the whole world that is about
  160-200 agent sessions**, not counting the quest, NPC and item systems.

## 11. Performance budget per zone

Starting figures; the first measurement of each type fixes them. Client on the reference machine (1080p, a mid-range GPU); server
with ticks of 16.7 ms.

| | Capital | PvE 1.5 km | PvE 2 km | Border | Dungeon (instance) | Eldrun 3 km |
|---|---|---|---|---|---|---|
| Draw calls (any view) | ≤ 2000 | ≤ 1500 | ≤ 1500 | ≤ 1800 | ≤ 1200 | ≤ 2000 |
| Visible primitives | ≤ 2 M | ≤ 2 M | ≤ 2 M | ≤ 2 M | ≤ 1.5 M | ≤ 2 M |
| Load on SSD (handoff to CLIENT_READY) | ≤ 5 s | ≤ 5 s | ≤ 5 s | ≤ 5 s | ≤ 3 s | ≤ 8 s (with streaming, TEC-37) |
| Generated data on disk | ≤ 60 MB | ≤ 80 MB | ≤ 120 MB | ≤ 130 MB | ≤ 30 MB | ≤ 350 MB |
| Server RSS (gameplay layer only) | ≤ 400 MB | ≤ 400 MB | ≤ 512 MB | ≤ 512 MB | ≤ 150 MB | ≤ 1.5 GB |
| Hostile NPCs placed | 0 | ≤ 200 | ≤ 300 | ≤ 320 | ≤ 80 | 150 (MUN-29) |
| Ambient NPCs | ≤ 120 (on rails) | ≤ 40 | ≤ 50 | ≤ 60 | 0 | none |
| NPCs awake at most | 120 (2 Hz, no physics) | 90 | 110 | 110 | 25 | MUN-29 |
| Players per channel | 64, target 100 | **48**, target 64 | 48, target 64 | 64 | 5 | TEC-34 |
| Tick p99 with the channel full of bots | ≤ 10 ms | ≤ 12 ms | ≤ 12 ms | ≤ 12 ms | ≤ 2 ms per instance | TEC-34 |
| Download per client | ≤ 30 KB/s | ≤ 30 KB/s | ≤ 30 KB/s | ≤ 30 KB/s | ≤ 20 KB/s | ≤ 20 KB/s (TEC-33) |

**Why 48 per PvE channel.** The count: 48 players × 70 µs give 3.4 ms. About 30 NPCs in combat × 85 µs give 2.6 ms. About 60 NPCs
near and at rest × 10 µs (think at 2 Hz and no `simulate()` if they do not move) give 0.6 ms; ambient about 0.1 ms. With network,
snapshots and systems the median is about 9 ms and the p99 stays at or under 12 ms. To reach 64 players MUN-51 measured and probably
`simulate()` in C++ ([networking.md](networking.md) §14 lever 6) are needed. Kill capacity: 180 hostiles with a minimum respawn of 40 s
give up to 270 kills per minute against the 120 that 48 players need ([npcs.md](npcs.md#42-respawn)).

**AI activity levels** (what MUN-51 brings to phase 6): COMBAT (a target or a player within 50 m) thinks at 10 Hz and simulates every
tick; NEAR (a player within 150 m) thinks at 2 Hz and simulates only if it moves; ASLEEP (no players within 150 m, 30 m of
hysteresis) neither thinks nor simulates. Respawn timers keep running in absolute ticks.

**Processes.** At least about 22 are needed (18 realm zones, Eldrun, the Vado Gris and two dungeon hosts). Empty zones are stopped and
started on demand (TEC-38). At rest 6-8 GB of RAM is estimated in total, so for testing the whole world fits in a 16-32 GB VPS.

## 12. Technical plan in Godot 4.7

### 12.1 Scenes per zone

Each zone is split into two layers: what the server needs and what only the
client sees.

```
data/world/world.tres               WorldDefinition: zones, dungeons, costs
data/world/poi_templates/<type>.tres  point-of-interest templates
data/zones/<id>/layout.tres         ZoneLayout (tools only): the geometry as data
data/zones/<id>/spawns.csv          NPC generators of the zone
scenes/world/zones/<id>/generated/  generated, see 9.3:
    <id>_gameplay.tscn              terrain with collision, building collisions,
                                    cell colliders, navigation, spawn
                                    points, passes and strongholds
    <id>_visual.tscn                meshes, vegetation, environment, lights,
                                    particles and ambient audio
    places.tres                     PlaceSet for discovery
scenes/world/pieces/                kit pieces as scenes: mesh + simple collision
scenes/world/fortresses/            fort, castle and Aldcor
assets/models/environment/          kit .glb files, per pack
assets/materials/realms/<realm>/    materials of each realm
assets/materials/shaders/           per-realm surface shader, wind, water
assets/environments/                Environment of each biome (.tres)
```

The full structure of `assets/` and `addons/` is in [art.md](art.md).

- The server instantiates only `<id>_gameplay.tscn`; the client instantiates both
  layers from `scenes/client/`, and the sky, effects and audio go with the visual one.
  The gameplay layer carries everything that affects movement and
  hits (terrain, walls, trunks, large rocks), because the client
  predicts its movement with the same collisions as the server.
- `ZoneDefinition` (`scripts/shared/world/zone_definition.gd`, format in [8.1](#81-zonedefinition-mun-13)) is a `Resource`
  that depends on nothing in `scripts/client/` or `scripts/server/`, so the server loads it without
  problems. The stronghold logic also lives in `scripts/shared/`.
- `scenes/world/test_world.tscn` remains the movement and camera
  test scene.
- Each zone follows the same order: blockout with primitives and CSG, playtest,
  kit pieces, painted terrain and vegetation, and finally lighting and
  atmosphere. No CSG is left in the final version: it is replaced by the kit or
  converted to mesh.

### 12.2 Terrain

- **Recommended option: Terrain3D** (GDExtension, MIT license). Clipmap terrain
  with automatic LOD, regions (only what is painted takes memory), holes
  for caves, texture painting, collision and a vegetation instancer. Before
  adopting it we have to check that the published version works with Godot 4.7
  and on the headless server. The server has no camera, so the zone's full
  collision is used and not the dynamic one around the camera.
- Terrain3D stores each region as a binary `.res` and ships native binaries
  (`.dll`, `.so`, `.dylib`). Both are committed as normal binary files (Git LFS was used at first and dropped, see `.gitattributes`), and the region `.res` files
  need an explicit exception to the text-format rule of
  CLAUDE.md (detail in [art.md](art.md)). With the zones of 8 × 8 regions or more they stop being a
  reasonable thing to version: see [9.3](#93-generated-zone-data-pending-decision-p1), which is
  **pending the user's decision (P1)**.
- **Plan B** if Terrain3D fails in headless: HTerrain (MIT, pure GDScript) or a
  custom heightmap split into 64 × 64 m chunks, each with its mesh and
  its `HeightMapShape3D`, with LOD by visibility ranges. Either of the two
  is enough for 1.5 km zones.
- **Resolution:** one vertex per meter. Flat stylized textures (color with
  soft noise), not photographic, so that they match the low-poly kit.
- What a heightmap cannot do (vertical walls and overhangs of
  the Vardheim fjords and the Kassar canyon, rock arches) is solved with
  kit rock pieces placed on the terrain.

### 12.3 Vegetation and scattered objects

Two layers:

- **Decorative** (grass, flowers, small stones, shrubs with no collision): client
  only. **Grass is not saved:** `GrassField` generates it around the camera from the control map and the
  height of Terrain3D (ART-81), drawn up to 40–60 m. Flowers, stones and shrubs go in
  `MultiMeshInstance3D`s of the visual layer.
- **Gameplay** (trees and large rocks with collision): scattered by the zone generator from
  the `ZoneLayout` and a fixed seed, and the result is saved as data; nothing is scattered at runtime
  on the server. The same positions yield two things: the collisions, by **64 m cells as arrays** (x, z,
  radius and height per trunk or rock) that `CellColliders` turns into bodies with `PhysicsServer3D`,
  identical on client and server, in the gameplay layer (a node per trunk would not load in 5 s on a
  2 km zone), and the meshes in `MultiMeshInstance3D` in the visual layer, which only the
  client loads.

Rules:

- One `MultiMeshInstance3D` per 64 × 64 m cell, not one per zone: camera
  culling and LOD are decided with the AABB of the whole MultiMesh, so a
  giant one is always drawn entirely.
- Each cell uses `visibility_range_end` with fade, and distant trees switch
  to a low-poly version.
- A single wind shader (vertex sway) for all vegetation.
- Scattering is done with ProtonScatter (MIT) or with our own editor tool
  (`@tool`), from rules (slope, height, painted texture,
  distance to roads and buildings) and a fixed seed, so that it is
  reproducible. How to get baked collisions out of ProtonScatter that are identical on
  client and server is in [art.md](art.md).

### 12.4 LOD and performance

- **Automatic mesh LOD** on importing the glTFs (the generate-LOD option
  is on). The threshold is adjusted in the project, not piece by piece.
- **HLOD with visibility ranges:** each block of the capital, each castle
  and Aldcor have a merged low-poly mesh that replaces the
  whole from 200–300 m (`visibility_range_begin`,
  `visibility_range_end` and `visibility_parent`). A castle made of hundreds
  of pieces thus costs a single draw call from afar.
- **Occlusion:** baked `OccluderInstance3D` in the capitals, the Kassar
  canyon and the castles.
- **Shadows:** `DirectionalLight3D` with 4 splits and a maximum distance of
  150–200 m; small objects and grass cast no shadow.
- **Fog per biome**, which also cuts the draw distance (especially in
  Eldrun).
- **Global illumination:** outdoors, directional light and ambient light from the
  sky, nothing baked; `LightmapGI` only in interiors and dungeons.
- **Initial budget**, to be measured with the debugger monitors: 60 fps at
  1080p on a mid-range GPU from a few years ago, fewer than 2000 draw calls and
  fewer than 2 million visible triangles.

### 12.5 Streaming within a zone

- Capitals, PvE zones and border zones (up to 3 km of terrain) are loaded whole
  during the loading screen. No streaming: it is simpler and the server always has
  the full zone.
- Eldrun (5 × 5 km of terrain), on the client:
  - The terrain is handled by the Terrain3D clipmap.
  - The gameplay layer (collision, strongholds, roads) is loaded whole: it weighs little
    and the client needs it to predict.
  - Only the visual layer is loaded by 256 m cells. Cells within
    600 m (beyond the fog) are requested with
    `ResourceLoader.load_threaded_request` and unloaded past 800 m; the
    margin keeps them from constantly flipping in and out. The HLODs of the castles and of
    Aldcor are always loaded.
- The network does not depend on visual streaming. Each client receives the players and
  NPCs within a radius of 150–250 m, plus the state of all strongholds (owner,
  gate health, capture progress), which takes little space and is shown on the
  map.
- If a single process cannot handle all of Eldrun's players, the last
  resort is to split it into sectors with loading between them: the three fronts and
  Aldcor.

### 12.6 Numerical precision

- Godot stores positions (`Vector3`, `Transform3D`) in 32-bit floats.
  A GDScript `float` is 64-bit, but when put into a `Vector3` it becomes
  32.
- Each zone has its origin (0, 0, 0) at its center. In Eldrun (4 × 4 km) no
  playable coordinate exceeds 2 km, and at that distance the error is about
  a tenth of a millimeter: not noticeable in physics or in the camera.
- **Rule:** no zone larger than 8 × 8 km (±4 km, error below
  0.5 mm). This way there is no need to build with double precision, which would force
  recompiling the engine and every GDExtension, Terrain3D included.
- On the network, positions are quantized: 1 cm precision over ±2.6 km fits in
  19 bits per axis.
- Simulation time is counted in integer ticks and not by summing floats,
  because server processes run for days on end. In shaders, `TIME`
  resets to zero every so often (`rendering/limits/time/time_rollover_secs`);
  the wind and the embers must tolerate that jump.

## 13. Work order

It follows the roadmap in [vision.md](vision.md) and the production plan of the phases 6-8. The same rule holds throughout: **the
zone kit comes before any new zone**, and after the first slice each band is produced in the three realms at once (the RvR needs
parity: Eldrun normalizes, so what counts is that every realm has a route to the war, not that one reaches level 60 first).

1. **Requirements.** TEC-65 (the server split into `scripts/server/zone/`) and the protocol 8 (TEC-57) integrated in `main`.
2. **Phase 4, the Vado Gris** (done): small terrain, blockout and then kit. It validated the kit and the scale, the materials of
   two realms, the per-instance side color and the separation between the gameplay layer and the visual layer.
3. **Phase 6, the zone kit and the first slice.**
   - **K1** MUN-13: `ZoneDefinition`, `WorldDefinition` and `ZoneCatalog` with `vado_gris` and `test_world`; `Zones`, `NetZones` and
     `RealmCatalog` read from there; `test_world_data`.
   - **K2** MUN-05: the Vado Gris in two layers; the 10 review cameras identical before and after; the server RSS is measured.
   - **K3** MUN-14: `ZoneLayout`, terrain, water and road generator and the plan view. The Vado Gris is ported with the same gameplay
     layer hash and the **test valley** (`test_valley`, 1.5 km) is generated as a gray model. Measured: generation time, MB per
     region with and without grass, load time.
   - **K4** TEC-67: generated data out of git, cache, `build_world` and `zone_build_hash` (if P1 is accepted).
   - **K5** MUN-45: scatter by cells with colliders as data, client grass (ART-81) and the validator with its image.
   - **K6** MUN-57: the 13 point-of-interest templates as gray models and a gallery scene; contact sheet.
   - **K7** MUN-60: automatic cameras, `run.py mundo --zone`, metrics in JSON and the route demo.
   - **K8** MUN-51 and TEC-32 in PvE and the load test (TEC-68) in the test valley with 48 bots and 200 NPCs; the measured p99 fixes the
     channel capacity.
   - **Vardheim 1-10** (needs TEC-29, TEC-30, MUN-16 and UI-32): the Isenholm core (the [appendix of Hondal](zones/hondal.md#appendix-isenholm-core-district-first-vertical-slice)),
     [Hondal](zones/hondal.md) as a gray model with its points of interest and a 5 min road, the provisional pass to the Vado Gris, then
     scatter and biome (ART-24), population (bestiary T1 and camps, shrines, poles, discovery), the rest of Isenholm (Village kit, the
     longhouse, HLOD) and the quests 1-10. A video of a bot that goes from Isenholm to the Vado Gris through passes and back is the
     criterion of MUN-23.
   - **Solmarch 1-10:** the same template with Valcorin, the Amber Fields and its own provisional pass. From here the two sides of the
     Vado Gris have a PvE world and it can be played with friends.
4. **Phase 7, Eldrun.** First at 3 × 3 km with the 6 forts, the 3 castles and Aldcor (MUN-42, MUN-43, with navigation in tiles); then the
   PvE layer (MUN-73), streaming of the visual layer by cells (TEC-37), the gates of the borders leading to Eldrun, fast travel
   (MUN-33) and the measurement of how many players it holds, growing to 4 × 4 km if TEC-34 allows.
5. **Phase 8, the other realms and the other bands.**
   - Band 10-20 of Vardheim and Solmarch (Skarven, Lirien Forest), the dungeon kit and **D1**; swimming (MUN-44) goes before the fjords
     of Skarven.
   - **Askarra 1-20:** Kassar, the Thal Oasis, the Ruhn Canyons and a lite Ossar Forges. The realm opens (`ELDMARK_OPEN_REALMS`) and
     the third entrance of D1 appears. **Eldrun is complete with three realms.**
   - Then, across all realms: band 20-32 and D2; band 32-45 (the three new zones) with D3 and D4; the full borders 45-60 with D5 and D6;
     Eldrun at 4 × 4 km if TEC-34 allows.

## 14. Risks and open questions

| Risk | Mitigation |
|---|---|
| Repo size and regenerated binaries (9.3) | Artifacts out of git with a cache (P1); an MB cap in `ZoneBudget` |
| Server CPU in populated PvE zones | MUN-51 in phase 6, channel at 48, the load test at K8 and, if it is not enough, `simulate()` in C++ |
| "Everything is relevant" interest with hundreds of NPCs | TEC-32 in phase 6 |
| Volume of content (18 zones, about 160-200 sessions) | Templates, wide production, shared dungeons, growing in two steps (lite and full border) and level ranges that move without regenerating |
| Zones that look alike (procedural generation) | 2-3 own landmarks per zone, distinct biomes and the P1 sheet reviewed by Opus and by the user |
| Few free assets for Askarra and Solmarch (no palms, vines or cliffs) | Own vegetation and rocks in Blender ([art.md](art.md#73-own-vegetation-and-rocks-art-84)); Askarra last |
| Vertical terrain (Kassar, the fjords of Skarven) | Rock pieces over the terrain (see Terrain); Askarra last |
| Terrain3D generation and load in zones of 2.5 km or more | Measure at K3; levers: Terrain3D 1.1, no saved grass, a horizon of meshes instead of regions |
| Large navigation | Tiles of 256 m and baking per tile |
| Generating on Windows and on Linux is not identical | Client and server from the same build; `zone_build_hash` |
| Eldrun with Askarra closed | Gates and forts of Askarra held by the Hollow; bots for tests |
| If progression changes the hours, bands move | NPC levels by data (zone and point of interest); maps are not touched |
| How many processes are running | Zones on demand (TEC-38) |

Open questions for the user: **P1** (generated data out of git, 9.3), whether Vardheim is the first realm (recommended), whether
the Vado Gris map is retired, kept as a training front or rotated once Eldrun exists (MUN-74), the new zone and dungeon names, and
how many hours to level 60 (about 50 is assumed).
