# Eldmark: the world of La Corona Rota (the Broken Crown)

> Status: **world chosen**, La Corona Rota (proposal C). This document covers
> the history, the realms, the war zone, the technical structure of the world,
> the visual identity of each realm and the plan to build it in Godot 4.7.
> Map: [world_map.svg](world_map.svg).

## History

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

## The three realms

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
[Visual identity](#visual-identity).

## Geography

![Schematic map of Eldmark](world_map.svg)

Schematic map, not to scale: [world_map.svg](world_map.svg). The real sizes
of each zone are in [Scale](#scale).

The realms form a triangle: **Vardheim in the north, Solmarch in the southwest and
Askarra in the southeast**, with the war zone, **Eldrun**, in the center. Each
wall surrounds its whole realm. The outer stretches rest on the sea,
the mountains or the desert; the stretch facing Eldrun is the front and has two
gates. Between each pair of realms, an impassable mountain range runs down from the
coast to Eldrun, so the realms only touch each other through the war
zone.

| Realm | Wall | Gates |
|---|---|---|
| Vardheim | Muro de Escarcha (Frost Wall; dry stone and logs) | Puerta del Lobo (Wolf Gate), Puerta de Hrafn |
| Solmarch | Muralla del Alba (Dawn Wall; limestone and conical towers) | Puerta Áurea (Golden Gate), Puerta de los Penitentes (Gate of the Penitents) |
| Askarra | Cinturón de Bronce (Bronze Belt; reinforced sandstone) | Puerta de Ceniza (Ash Gate), Puerta del Cañón (Canyon Gate) |

| Level | Vardheim | Solmarch | Askarra |
|---|---|---|---|
| Capital | Isenholm | Valcorin | Kassar |
| 1–10 | Hondal: pine valley and farms | Campos de Ambre: vineyards and wheat fields | Oasis de Thal: irrigated land between canyons |
| 10–20 | Skarven: fjords and shipwrecks | Bosque de Lirien: deciduous forest and abbeys | Cañones de Ruhn: plateaus and mines |
| 20–30 | Grimfell: high tundra and burial mounds | Ciénaga de Morvel: corrupted swamp | Yermo de Ceniza: volcanic fields and living cracks |
| 30–40 | Marca del Lobo: burnt forest next to the wall | Llanos del Penitente: crusade camps | Forjas de Ossar: border foundries |

## War zone: Eldrun, the Broken Crown

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

### Domination mechanic: Ember Lines
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
in [Road network](#road-network-the-ember-lines).

## First border zone (phase 4): the Vado Gris

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

## Technical structure of the world

### Independent zones

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

### Zone types

| Type | What it contains | Server | Examples |
|---|---|---|---|
| Capital | Trade, crafting, quests and trainers. Safe zone | One process per realm, with channels | Isenholm, Valcorin, Kassar |
| Leveled PvE | Open outdoors with a village or minor town, 3–5 points of interest (camps, ruins, lairs), resources and dungeon entrances | One process per zone, with channels | Hondal (1–10), Skarven (10–20), Grimfell (20–30) |
| Dungeon | Instanced interior for a group of 3–5 players | On-demand instances: several per process, each in its own `World3D`, or one process per instance | To be defined (e.g. Grimfell burial mounds, Ruhn mines, Lirien abbeys) |
| Border | PvE zone 30–40 along the front wall, with its two gates and the realm's garrison | One process per realm | Marca del Lobo, Llanos del Penitente, Forjas de Ossar |
| War zone | PvP of the three realms: 6 forts, 3 castles and Aldcor | A single process, no channels | Eldrun |
| Border test | Small cutout of a front to test capture | One process | Vado Gris (phase 4) |

Within each realm, the capital is at the far end, next to the coast or the mountain,
between zones 1–10 and 10–20; the 20–30 sits in the middle and the border, against the
wall. Passes: the capital connects to the 1–10 and the 10–20, both of those
connect to the 20–30, and that one to the border. Minor towns and villages go
inside the PvE zones; they are not zones of their own.

### Scale

Current character speeds: 5 m/s running and 7.5 m/s sprinting
(`scripts/shared/player_character.gd`). One kilometer running is about
3 min 20 s.

| Zone | Playable area | Total terrain | Notes |
|---|---|---|---|
| Capital | 1 × 1 km | 1.5 × 1.5 km | The city takes up 300–500 m; the rest is outskirts and countryside |
| PvE (1–30) | 1.5 × 1.5 km | 2 × 2 km | Crossing it running: about 5 min |
| Border (30–40) | 2.5 × 1.2 km | 3 × 1.7 km | Elongated along the wall; its two gates about 2 km apart |
| Dungeon | 150–400 m of path | Interior | Runs of 20–40 min |
| Eldrun | 4 × 4 km (first version: 3 × 3 km) | 5 × 5 km | Distances in the following table |
| Vado Gris (test) | 300 × 300 m | 500 × 500 m | Phase 4 |

The **total terrain** includes a border of about 250 m that is not walked on (mountains,
sea, cliffs) so that the horizon is not left empty. The limit of the playable area
is closed off by the terrain itself and, where that is not enough, by invisible collisions.

A complete realm adds up to about 11 km² playable (capital, three PvE zones and
border). From the capital to the wall it is about 20 min running.

Road distances in Eldrun (4 × 4 km):

| Stretch | Distance | Running |
|---|---|---|
| Gate → nearby fort | 650 m | 2 min |
| Fort → fort on the same front | 750 m | 2.5 min |
| Fort → castle on its front | 550 m | 2 min |
| Castle → Aldcor | 1 km | 3.5 min |
| Gate → Aldcor | 2.2 km | 7–8 min |

Respawning at one's own strongholds (especially the Santuario de Ilse) shortens
these times. If they turn out long in testing, it drops to 3 × 3 km and everything
shrinks by 25 %.

### Strongholds: forts, castles and Aldcor

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

### Road network: the Ember Lines

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

## Visual identity

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

## Technical plan in Godot 4.7

### Scenes per zone

Each zone is split into two layers: what the server needs and what only the
client sees.

```
data/zones/<zona>.tres              ZoneDefinition: id, type, realm, levels,
                                    size, scenes and passes
scenes/world/zones/<zona>/
    <zona>_gameplay.tscn            terrain with collision, building collisions,
                                    trunks and rocks, navigation, spawn
                                    points, passes and strongholds
    <zona>_visual.tscn              meshes, vegetation, environment, lights,
                                    particles and ambient audio
scenes/world/pieces/                kit pieces as scenes: mesh + simple collision
scenes/world/fortresses/            fort, castle and Aldcor
assets/models/environment/          kit .glb files (Git LFS), per pack
assets/materials/realms/<reino>/    materials of each realm
assets/materials/shaders/           per-realm surface shader, wind, water
assets/environments/                Environment of each biome (.tres)
```

The full structure of `assets/` and `addons/` is in [art.md](art.md).

- The server instantiates only `<zona>_gameplay.tscn`; the client instantiates both
  layers from `scenes/client/`, and the sky, effects and audio go with the visual one.
  The gameplay layer carries everything that affects movement and
  hits (terrain, walls, trunks, large rocks), because the client
  predicts its movement with the same collisions as the server.
- `ZoneDefinition` (`scripts/shared/world/zone_definition.gd`) is a `Resource`
  that depends on nothing in `scripts/client/`, so the server loads it without
  problems. The stronghold logic also lives in `scripts/shared/`.
- `scenes/world/test_world.tscn` remains the movement and camera
  test scene.
- Each zone follows the same order: blockout with primitives and CSG, playtest,
  kit pieces, painted terrain and vegetation, and finally lighting and
  atmosphere. No CSG is left in the final version: it is replaced by the kit or
  converted to mesh.

### Terrain

- **Recommended option: Terrain3D** (GDExtension, MIT license). Clipmap terrain
  with automatic LOD, regions (only what is painted takes memory), holes
  for caves, texture painting, collision and a vegetation instancer. Before
  adopting it we have to check that the published version works with Godot 4.7
  and on the headless server. The server has no camera, so the zone's full
  collision is used and not the dynamic one around the camera.
- Terrain3D stores each region as a binary `.res` and ships native binaries
  (`.dll`, `.so`, `.dylib`). Both go through Git LFS, and the region `.res` files
  need an explicit exception to the text-format rule of
  CLAUDE.md (detail in [art.md](art.md)).
- **Plan B** if Terrain3D fails in headless: HTerrain (MIT, pure GDScript) or a
  custom heightmap split into 64 × 64 m chunks, each with its mesh and
  its `HeightMapShape3D`, with LOD by visibility ranges. Either of the two
  is enough for 1.5 km zones.
- **Resolution:** one vertex per meter. Flat stylized textures (color with
  soft noise), not photographic, so that they match the low-poly kit.
- What a heightmap cannot do (vertical walls and overhangs of
  the Vardheim fjords and the Kassar canyon, rock arches) is solved with
  kit rock pieces placed on the terrain.

### Vegetation and scattered objects

Two layers:

- **Decorative** (grass, flowers, small stones, shrubs with no collision): client
  only, with the Terrain3D instancer (its instances have no
  collision) or with custom `MultiMeshInstance3D`s. Grass is only drawn up to
  40–60 m.
- **Gameplay** (trees and large rocks with collision): scattered in the editor
  and the result is saved in the zone; nothing is scattered at runtime
  on the server. The same positions yield two things: the simple
  collisions (one capsule per trunk) in the gameplay layer, which client and
  server load, and the meshes in `MultiMeshInstance3D` in the visual layer, which only the
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

### LOD and performance

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

### Streaming within a zone

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

### Numerical precision

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

### Work order

It follows the roadmap in [vision.md](vision.md):

1. **Phase 4, the Vado Gris:** small terrain, blockout and then kit. It serves
   to validate the kit and the scale and to test the materials of the two realms,
   the per-instance side color and the separation between the gameplay layer and
   the visual layer.
2. **Phase 6, the first realm:** preferably Vardheim or Solmarch, the two of the Vado
   Gris, to reuse what was done in phase 4. Capital, one PvE zone and the
   border with its wall and a gate. It tests the pass between zones with a handoff
   ticket, 1.5 km terrain and the scattering tool.
3. **Phase 7, Eldrun:** first at 3 × 3 km with the 6 forts, the 3 castles and
   Aldcor. We measure how many players it holds and, if it goes well, it grows to 4 × 4 km.
   Visual streaming by cells comes in here.
4. **Phase 8, the other two realms:** the same process with their materials, their
   key pieces, their vegetation and their atmosphere.
