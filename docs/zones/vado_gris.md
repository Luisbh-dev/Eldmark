# Vado Gris (phase 4)

> Eldmark's first real zone. It is the frontier test for [world.md](../world.md): a compressed
> version of the northwest front, with the Vado Gris fort and the two gates about 150 m away. This
> is where fort capture, the kit, scale, realm materials and Terrain3D terrain are tested on both
> client and server.

- **Scene:** `scenes/world/zones/vado_gris/vado_gris.tscn` (root `VadoGris`, script `ZoneRoot`).
- **Terrain:** 500 × 500 m in 2 × 2 Terrain3D regions of 256 m, one vertex per meter. Data in
  `scenes/world/zones/vado_gris/terrain/` (the region `.res` files, via Git LFS).
- **Playable area:** 300 × 300 m in the center (x and z between -150 and 150), closed off by the
  two walls to the north and south and by invisible walls to the east and west. Outside it, about
  100 m of mountains and hills close off the horizon.
- **Coordinates:** origin at the center of the fort, 1 unit = 1 m, **north = -Z**. Vardheim
  (Frost Wall) to the north, Solmarch (Dawn Wall) to the south.

## Layout

### The horseshoe river

The river wraps around the fort's hill like a meander: it enters from the east, runs west along the
**north arm** (z = -62), bends around the hill on the west side and returns east along the **south
arm** (z = +62). The fort sits on the peninsula in the middle, which can only be reached from the
east, outside the playable area. This way **both realms have to cross the river** to reach the
fort, and they cross it at equivalent places.

- **Two stone bridges**, one on each arm, right on the straight gate-to-fort line (x = 0): the
  **direct, narrow route**. 4 m deck, 24 m long, 0.95 m parapets and a shallow arch over the
  water. Each realm has its own, mirrored.
- **One wide, exposed ford** at the west vertex of the bend (x = -62, z = 0), on the axis of
  symmetry: about 34 m of channel between the two channel closures, of which the central 28 m
  have 0.3 m of water over gray gravel (the "gray ford", *vado gris*); in the 3 m at each end the
  bed drops toward the deep channel. Very gentle banks (10°). Two rows of wooden posts mark it
  (over the central 9 m). It is 40 m from the fort gate, with no cover, in front of the
  walkway: it is the **wide, exposed route**, the same for both realms.
- Outside the bridge and the ford the water is deep (1.6 m) and its edge cannot be crossed: a low
  collision runs along both banks (`Limites/OrillasProfundas`) and ends right at the outer face of
  each bridge, and two walls close the channel on both sides of the ford (`CierreCauce*`), so you
  cannot get from the ford to the bridges along the deep bed. Over the bridge parapets there is a
  1.7 m invisible blocker (`BloqueoSalto`): you cannot jump into the channel. The water is purely
  visual; at the ford you walk on the terrain bed.
- The invisible blockers (playable-area limits, banks, channel closures and parapets) are on
  **layer 3** (`PlayerCharacter.PLAYER_BLOCKER_LAYER`), which the character sees but the camera
  does not: next to a bank or an invisible wall the camera does not stick to the character's head.

### The fort

On a low hill (plateau at 10.2 m, 6 m above the valley, slopes of 12–18°):

- **Log palisade** of 40 × 40 m and 4.6 m high, with pointed tips.
- Interior **walkway** 2 m wide at a height of 3.35 m (the parapet is at 1.3 m, chest height, and
  the camera pivot above the tips) and **two wooden ramps** of about 26°, one to the north and one
  to the south (symmetric), east of the tower. The walkway passes over the gate opening (no posts
  in the opening).
- **Wooden gate** of 4 m on the west face, looking at the ford: two plank leaves with iron straps,
  square up to the lintel. It is its own scene (`FortGate`, group `fort_gate`, script
  `scripts/world/fort_gate.gd`) so that it can have health and be broken by hits (docs/fortress.md,
  §3). **It is kept closed** and with two bodies: the node itself is the **movement** body (realm
  layers 5 to 7: Vardheim, Solmarch and Askarra, minus the owner's; neutral, all three) and its
  child `Vista` is the **view** body (layer 4, "structures"), which the camera, the line of sight
  of hits and the navigation bake see but movement does not. Each simulation character adds its
  realm's layer to its mask with `PlayerCharacter.set_realm_collision()`, so the closed gate stops
  the owner's enemies and lets the owner's own people through; when broken
  (`set_state(owner, true)`), both bodies are left without layers and the leaves hang open. A
  character with no realm layer (offline mode, `F5` with no arguments) does not notice it: it can
  still enter the courtyard, the ramps, the walkway and the circle.
- Courtyard: crates from the old garrison mirrored north-south (the two piles give the same
  shortcut to the walkway) and a campfire on the axis, east of the tower. Two neutral banners
  flank the gate on the outside.
- **Central keep** (ART-57): the custom model `assets/models/environment/custom/fort_keep.glb`
  (26 m with the flagpole, hipped roof, scaffold, three LODs and a cloth banner with an emblem) in
  the scene `fort_keep.tscn` (`FortKeep`, `scripts/world/fort_keep.gd`: realm materials, LOD
  ranges and collision layer). It replaces the two-story 6 × 6 m tower. Its collision is the
  low-resolution mesh of the glb itself (268 faces, conical body of 9.9 × 9.7 m at the base), whose
  footprint enters 1.4 m into the east edge of the capture circle (the center and the markers do
  not move; the Captain's spawn point is 1.07 m from the collision). The `Estandarte` banner hangs
  from the glb; `FortressView` finds it by name and gives it the owner's color per instance.
- The `Fuerte` node is the **fortress node**: it is in the group `fortresses` and carries the
  `definition` metadata with the path to `data/fortresses/vado_gris.tres` (`FortressDefinition`,
  id `vado_gris_fort`). Its children are the markers that the fort controller reads:
  - `CaptureCircle` (group `capture_points`; `radius` metadata = 5 m, the only place the radius
    comes from; center at x = -8.5, between the gate and the tower, with the edge 0.5 m from the
    tower), `CaptainSpawn` (inside the circle) and four `GuardSpawn` (courtyard, outside the
    circle).
  - `FortGate` and the banners `Estandarte` (tower), `EstandartePuertaN` and `EstandartePuertaS`.
  - Six **patrol** markers (group `patrol_points`, metadata `route`, in scene order within each
    route): `hollow_north` (`PatrolNorth1..3`) and `hollow_south` (`PatrolSouth1..3`), from the
    courtyard up the north or south ramp to the walkway and along it toward the gate.
  - Five **NPC spawners** (`NpcSpawner`, `scripts/world/npc_spawner.gd`, group `npc_spawners`,
    data only): `HollowSpawner1..4` on the `GuardSpawn` markers (id `hollow`, active while the
    fort is neutral, alert group `vado_gris_hollows`; the two in the east, next to the ramps,
    patrol along `hollow_north` and `hollow_south`) and `FordCaptainSpawner` on the `CaptainSpawn`
    (id `ford_captain`, same alert group). They do not respawn one by one: the fortress replenishes
    them. The garrison of the owning realm has no spawners of its own: it comes out of these same
    five posts with the NPC definition that each one names in `garrison_id` (the Hollow give realm
    guards and the Ford Captain gives the realm captain), with its patrol route and its alert
    group (`NpcSpawnerSystem`, fortress.md 8.3 F4).

### Walls, gates and camps

- **Frost Wall** (z = -152) and **Dawn Wall** (z = +152): 12 m high facade plus battlements, with
  the gate in the center between two 18 m towers. The wall extends 180 m to each side and sinks
  into the mountains.
  - Vardheim: cold gray stone with snow on the upward-facing surfaces, almost-black wooden
    scaffolds on the towers and on alternating wall sections, ice-blue banners. Towers every 48 m.
  - Solmarch: cream limestone with moss, towers every 36 m with a conical blue-slate roof and a
    gilded finial, gold banners. Gilded portcullis.
- **Camp** in front of each gate (radius 24 m, flat): tents, crates, cart, fences, campfire and
  two banners that mark its edge. The four **spawn points** of each realm are in the camp
  (x = ±2.5 and ±7.5, 14 m from the wall) and face the fort.
- **Respawn points** (`RespawnPoints`, group `respawn_points`): twelve markers in a **scene order
  that must not be altered** (it is the index used by client and server): `CampamentoVardheim1..4`
  and `CampamentoSolmarch1..4` (at the spot of the spawn points, `realm` metadata) and then
  `FuerteVadoGris1..4` (fort courtyard, 11 m east of the tower, outside the circle and facing the
  gate; `fortress` metadata = `vado_gris_fort` and no `realm`, because they are valid for
  whichever realm owns the fort). As long as the zone does not ask for more, a realm's list is
  just its camps.
- **Gate Guardians** (`NpcSpawners/GateGuardian<Realm>1..2`): two `NpcSpawner` spawners per camp
  (id `gate_guardian`, always active, 30 s respawn, alert group `camp_<realm>`) on either side of
  the gate in its wall (x = ±11, 9.5 m from the wall), inside its safe zone. They attack enemies
  that enter it (not those outside) and kill an intruder in about 5 s.
- **Safe zone** of each camp (`SafeAreas/CampamentoVardheim` and `CampamentoSolmarch`, a `Marker3D`
  in the group `safe_areas` with the metadata `realm` and `radius = 24`): centered on the center of
  its realm's four spawn points (x = 0, z = ∓138) and with the camp's radius. **It only protects
  its own realm** (docs/combat.md, section 5): inside it a player of that realm neither takes nor
  deals damage, and an enemy intruder can be damaged (read by the `CombatResolver`).
- **Training dummy** next to each camp (`DummyPoints/MunecoVardheim` and `MunecoSolmarch`, a
  `Marker3D` in the group `dummy_points` 30 m from the center of the safe zone, that is, outside
  it, facing the camp): the server places an immortal NPC of the neutral side on each marker that
  heals itself after 5 s without damage (`ZoneServer.spawn_zone_dummies()`; in `ServerMain`,
  except with `--no-dummies`). The test world has one at `DummyPoints/Dummy1`.

### Ruins of old Eld

- **Village of Eld** on the west bank, on both sides of the old road that reaches the ford: six
  ruined houses per side (mirrored), with collapsed walls at different heights (you either jump
  over them, with the top at 1.2 m or less, or they block you, at 1.9 m or more), some toppled,
  stone capping instead of a wooden sill, broken floors, a chimney and rubble at the foot of the
  fallen walls. The doors do not sink: the lintel stays above 2 m. They give cover to anyone
  approaching the ford. The old street ends before the west edge at two pillars of a fallen gate
  and rubble.
- Ruined **chapel** on the peninsula, east of the fort, on the axis: side walls with windows, door
  to the west, sunken chancel and two pillars.

### Vegetation and edge

- **Gameplay cover** (with collision, saved in the scene): pine groves to the north and deciduous
  groves to the south, scattered dead trees in the central strip (Eldrun) and groups of rocks.
  They are generated in the north half and mirrored: **the same 50 trunk collisions and 17 rock
  collisions in each half**, in the same positions.
- **Decorative** (Terrain3D instancer, no collision): about 51,000 grass tufts (visible up to
  60 m), shrubs on the banks, slabs of the old road and undergrowth (ferns, plants, mushrooms,
  tall grass and pebbles, from 30 to 60 m) at the foot of the gameplay trees and rocks and of some
  at the edge. Five variants of pine, deciduous and dead tree, and two twisted ones in the central
  strip of the edge (from the Stylized Nature pack already downloaded; see
  `assets/LICENSES.md`).
- **Grounding in the terrain** (ART-58): each tree sinks `tan(slope)` times the radius of its base
  (measured on the mesh) on top of the usual amount, and rocks tilt toward the terrain normal and
  sink a fraction of their height plus the gap left by the missing tilt (14% for gameplay rocks,
  so that the drawing follows the height of its collision; 45% for the loose rocks at the edge and
  the scree). There are no trees above 45°: scree goes there instead. **The 132 collisions (100
  trunks and 32 rocks) are where they were**: only the drawing changes, and for that the
  undergrowth, the pebbles and the model variety come from a second random number generator
  (`_decor_rng`) that does not move the gameplay cover.
- **Bark and leaves** (ART-59): the kit's bark is terracotta and in the valley it looked salmon.
  The tree glTFs replace it on import with a custom material (`bark_tree`, `bark_twisted` and
  `bark_dead`, recolored toward grayish brown with `realm_surface_closed`), and the red leaves of
  the twisted ones with `leaves_twisted` (olive green). This is done by
  `tools/assets/apply_nature_materials.gd` with the external material of the `.import`, without
  touching the glTFs.
- **Edge:** pine and rock mountains behind the Frost Wall (up to 80 m high, with a pass behind the
  gate), gentle deciduous hills behind the Dawn Wall and mountains on the sides that start 15 m
  inside the playable area (the invisible wall sits on a slope of about 40°, not in the middle of
  the meadow). Forest in groups that climbs the slopes of up to 45°, getting sparser (conifers at
  1.5–2.2 times the kit model), scree of tilted, half-buried rocks on the steepest faces and fine
  relief on the slopes. The river leaves to the east between two hillocks.

### Map

Schematic top-down view, north up. Each column is 5 m in X and each row is 10 m in Z (which is why
the 40 × 40 m fort comes out wide and short).

```
       x: -150      -100       -50         0        50       100       150
      |         |         |         |         |         |         |
 -150 ##############################H##############################
 -140                          ccc SSS ccc                         
 -130               ^^^^       ccc  .  ccc       ^^^     ^^^       
 -120      ^^^^      ^^             .           ^^^^^              
 -110     ^^^^^^                ... .             ^                
 -100      ^^^              ...     .                     ^^^^^    
  -90                     ..        .     ^^^             ^^^^     
  -80                  ..           .                              
  -70    ***         ..           ~~=~~~~~~~~~~~~~~                
  -60   *****       .        ~~~~~~~=~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  -50              .      ~~~~~~~   =               ~~~~~~~~~~~~~~ 
  -40             .      ~~~~~    ..                               
  -30    rr    r  . r   ~~~~   ...                                 
  -20             .    ~~~~   ..PPPPPPPPP                          
  -10   r  rr   rr.   ::::    . P       P                          
    0 ................::::......G   T   P           rr             
   10   r  rr   rr.   ::::    . P       P                          
   20             .    ~~~~   ..PPPPPPPPP                          
   30    rr    r  . r   ~~~~   ...                                 
   40             .      ~~~~~    ..                               
   50              .      ~~~~~~~   =               ~~~~~~~~~~~~~~ 
   60   *****       .        ~~~~~~~=~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
   70    ***         ..           ~~=~~~~~~~~~~~~~~                
   80                  ..           .                              
   90                     ..        .     ooo             oooo     
  100      ooo              ...     .                     ooooo    
  110     oooooo                ... .             o                
  120      oooo      oo             .           ooooo              
  130               oooo       ccc  .  ccc       ooo     ooo       
  140                          ccc SSS ccc                         
  150 ##############################H##############################
```

`#` wall (`H` gate) · `S` spawn points · `c` camp · `.` roads · `~` river ·
`=` bridge · `:` ford · `P` palisade (`G` fort gate) · `T` tower · `r` ruins ·
`^` pines · `o` deciduous trees · `*` dead trees. North up: Vardheim; south down: Solmarch.

## Routes, distances and fairness

Measured with `tools/terrain/verify_vado_gris_routes.gd`: a real `PlayerCharacter` runs (5 m/s,
without sprinting) from a spawn point to the esplanade of the fort gate. The waypoints of each
route and realm are shared data, `data/routes/vado_gris.tres` (`ApproachRoutes`,
`scripts/shared/war/approach_routes.gd`), written by `tools/terrain/export_vado_gris_routes.gd`
(Solmarch's are the exact mirror of Vardheim's; it also stores where the fort's gate and circle
are, for the bots that do not load the zone) and read by the verification and the siege bots. The
siege bots (`BotBrain.Pattern.SIEGE`) sprint along them: sprinting, they reach the gate in about
25 s by the bridge and about 37 s by the ford (docs/fortress.md, 8.3).

| Route | Path | Vardheim | Solmarch | Difference |
|---|---|---|---|---|
| Bridge (direct, narrow) | Camp → own bridge → slope → fort corner → gate | 148.9 m · 30.1 s | 148.9 m · 30.1 s | 0.00 % |
| Ford (wide, exposed) | Camp → west flank plain → village → ford → gate | 236.5 m · 47.8 s | 236.5 m · 47.8 s | 0.00 % |

- In a straight line, each gate is 152 m from the center of the fort.
- The bridge saves about 18 s but it is a 4 m wide funnel that the defenders cover from the north
  or south walkway. The ford is longer, but wide (34 m), with cover in the village up to the bank
  and then 40 m in the open in front of the gate.
- The same script checks that the river **cannot** be crossed anywhere else (east arms and
  northwest and southwest bends): the character stays on the bank.
- Since GUE-45 the same data carries the climb to the walkway that the siege bots follow (its
  height, 13.55 m; its axis, from the top of the north ramp to the top of the south one over the
  gate, and the two ramps from the courtyard, outside the capture circle). The script walks it
  along both ramps: 93.0 m and 18.9 s from the esplanade to the post above the gate, at 3.36 m
  above the plateau, identical via the north and via the south.

Why it is fair:

- **North–south mirror symmetry** (z → -z) of everything that affects gameplay: heights of the
  playable area (the terrain noise is added to its reflection, so there is no seam on the axis),
  river, bridges, roads, camps, safe zones, dummies, spawn points, ruins and tree and rock
  collisions. Only the models (pines to the north, deciduous trees to the south) and the materials
  of each realm change.
- What has no counterpart is **on the axis** and common to both: the fort, its gate, the ford, the
  village street and the chapel.
- Each realm has **both routes**: its own bridge (symmetric equivalent) and the same ford.
- **Light:** the sun comes exactly from the west (along +X), at 28° and with long shadows, so it
  does not hit either wall facade head-on (they face +Z and -Z): both receive the same light.
  What faces west (tower faces, palisade, trees) gets sun and what faces east stays in shadow,
  with a luminance ratio of 4 to 5 between the two faces of a tower. Since the wall facades are
  edge-on and only receive ambient light (gray and flat), the generator adds two fill lights that
  are **mirrors of each other** (one from the southwest and one from the northwest, no shadow,
  energy 0.9) that only light layer 20, and `WallLightTag` puts the walls, towers and gates on that
  layer: each interior facade receives a raking light and the relief of the masonry reads, without
  touching the rest of the scene. The north-south symmetry does not change (ART-54).
- **Sky and weather (ART-54):** a storm that is clearing (provisional quality decision, quality.md,
  section 6). `storm_sky.gdshader` is a custom sky shader (not Sky3D: see `assets/LICENSES.md`):
  broken clouds over a cold gradient, dark to the east and at the zenith, with a clearing toward
  the west around the low sun, a silver rim on the edge of the clouds that faces the sun and the
  sun disc where the directional light is (`LIGHT0_DIRECTION`, so sky and light do not decouple).
  No `TIME`, so that the radiance map is not regenerated every frame. It is an `Environment`
  resource: the headless server does not draw it and loads no addon. Each half looks different
  (ART-62): depending on the camera's `z`, the horizon and the sun's halo cool down (Vardheim) or
  warm up (Solmarch); only in the full-screen pass, so the ambient light of both halves is
  identical.

## Technique

- **Terrain3D `FULL_GAME` collision** (mode 3) on layer 1, the same on client and server.
  `ZoneRoot` (`scripts/world/zone_root.gd`) disables Terrain3D's `_physics_process` on load
  (without a camera it would raise an error on the server) and, on the client, as soon as there is
  a camera it assigns it to the terrain and re-enables it so that the clipmap follows it. It also
  provides `get_spawn_points(realm)`.
- **All collisions are saved in the scene** (layer 1, except the fort gate, which uses layers 4
  and 5 to 7): terrain, palisade, walkway, ramps, tower, bridges (concave shape of the deck and the
  parapets), walls, towers, tents, crates, carts, fences, campfires, ruins, ford posts, trunks and
  rocks (cylinders), deep banks and invisible limits. Nothing is scattered at runtime.
- **Repeated visual-only instances** (palisade logs, wall courses, posts) with `BakedMultiMesh`
  (`scripts/world/baked_multimesh.gd`): it stores the transforms in the scene as text, because in
  headless mode a `MultiMesh` buffer is not saved.
- **Realm materials:** a single shader, `assets/materials/shaders/realm_surface.gdshader`, that
  recolors the kit's texture (hue, saturation, brightness and "colorize" toward the target color
  of the palette in world.md while keeping the detail), adds the layer for upward-facing surfaces
  (snow in Vardheim, moss in Solmarch, ash in Eldrun) and the faction color per instance
  (`instance uniform faction_color`). With `StandardMaterial3D` you can only multiply, and that
  does not get you from gray brick to cream limestone or from red tile to blue slate. The materials
  are in `assets/materials/realms/{eldrun,vardheim,solmarch}/` and come out of
  `tools/materials/build_realm_materials.gd`.
- **Water:** `assets/materials/shaders/water.gdshader`, color by depth read from the depth buffer
  (light ford, dark channel), foam on banks and posts, ripples that run along the river. The mesh
  is a ribbon along the channel (`vado_gris_river_water.tres`).
- **Environment:** `assets/environments/vado_gris_frontier.tres`: custom sky (above), cold distance
  fog of 0.0016 with sun scattering, light volumetric fog (density 0.0012, 120 m, with the sun
  light inside: the shadows of the towers and the clouds leave shafts), SSAO and SSIL
  (screen-space bounce in the fort courtyard and at the foot of the walls), AgX tonemapper with no
  global desaturation, soft glow. Western sun at 28°, warm (`#ffe6c4`) and with energy 2.6, with
  4-split shadows up to 110 m with no blending between splits; ambient sky light at 0.55. No SDFGI
  (cost and flicker on a 512 m terrain): it remains as an optional improvement.
- **Terrain textures (ART-55):** ten Terrain3D slots with the eight CC0 Poly Haven textures (grass,
  dirt, gravel, cobble rock, gravel with stones, wet sand, snow and forest floor), processed by
  `tools/assets/process_terrain_textures.py` (1024 px, desaturated, with the height in the albedo
  alpha and the OpenGL normal with the roughness in the alpha; see `assets/LICENSES.md`). Dry
  grass and green grass reuse the grass one with a different tint. The tiles measure 2 to 4.5 m
  (`uv_scale` of 0.24 to 0.5), each texture's rotation offset breaks the repetition and the slopes
  project the texture sideways (`enable_projection`, threshold 0.6) instead of stretching the rock
  into streaks. The roads have a core of gray gravel that turns into dirt with an edge broken up by
  noise, and the banks carry mud. Identity of each half (ART-62, paint only): patchy snow, dark
  forest floor under the conifers and snow on the peaks to the north; lush green grass to the
  south.
- **Grass (ART-59):** tufts clustered by noise (meadow and clearings, no rows), 1 to 3 per 1 m
  cell, visible up to 48 m. Custom material `grass_blade.gdshader` (five variants of
  `grass_blade_*.tres`, from `tools/assets/build_grass_materials.py`): the base of the blades has
  the color of the terrain and rises to that of the tip, some backlit translucency and wind sway
  that grows with height. Variant per zone: frosted to the north, dry and gray in the central
  strip, lush green to the south. The thin-bladed one (190 triangles) is used only in a small
  proportion.
- **Road slabs:** they tilt with the terrain and sink until flush; on slopes of more than 7° they
  are not placed.
- **Everything in one scene for now.** The dedicated server removes the visual layer on load with
  `ZoneRoot.strip_for_server()` (tested in `test_vado_gris_zone.gd`). The split into
  `vado_gris_gameplay.tscn` and `vado_gris_visual.tscn` from world.md is still pending (see below).

### Measured performance

`tools/render/render_screenshot_points.gd` at 1920 × 1080, Forward+, no vsync, on an RTX 5090
Laptop (not the mid-range GPU of the budget; it is useful for comparing views). Before → after
ART-53, 54, 55, 58 and 59 (November 3, 2026). The FPS figures come from two consecutive passes on
the same machine, one with the previous zone and one with the current one, and they vary a lot
from pass to pass (the GPU is a laptop one): they serve to show there is no drop, not to pin down
a figure.

| View | FPS | Draw calls | Primitives |
|---|---|---|---|
| From the Vardheim gate | 192 → 220 | 524 → 603 | 0.98 M → 1.08 M |
| From the Solmarch gate | 190 → 221 | 535 → 618 | 0.90 M → 1.02 M |
| Fort up close | 183 → 208 | 521 → 717 | 1.04 M → 1.47 M |
| North bridge | 162 → 167 | 704 → 887 | 1.20 M → 1.48 M |
| Ford | 162 → 187 | 692 → 1023 | 1.27 M → 1.85 M |
| Village ruins | 147 → 191 | 789 → 1151 | 1.28 M → 1.93 M |
| Vardheim wall | 185 → 266 | 652 → 916 | 0.66 M → 0.92 M |
| Solmarch camp | 194 → 241 | 607 → 972 | 0.87 M → 1.26 M |
| Aerial view | 225 → 240 | 340 → 378 | 0.61 M → 0.66 M |
| Fort gate | 268 → 314 | 517 → 628 | 1.02 M → 1.34 M |

All within the world.md budget (2000 calls, 2 M triangles), but with little margin on the
primitives of the ford and the ruins: the increase comes mostly from the 4-split shadows and from
the trees and rocks that cast shadows. If something has to be trimmed, the first thing is the
shadow distance (with 2 splits up to 120 m it was about 0.5 M less) and then the reach of the
undergrowth. Compared with the first version of the zone, draw calls remain far below: 8 tree
variants instead of 12 (now 17, because of ART-59), shrubs without shadows, ruin floors and rubble
in MultiMesh, campfire stones and rubble merged into one mesh, draw distance on small pieces and
trunks and tarps with cull_back. The kit textures are compressed (BPTC/S3TC) with mipmaps instead
of uncompressed RGBA, and loading the zone headless costs about 72 MB of static memory (before,
about 150 MB).

## Playing in the zone

It is the client's default zone (`Zones.DEFAULT_ZONE` in `scripts/shared/zones.gd`):

```
godot --path . -- --realm=vardheim     # or --realm=solmarch
godot --path . -- --zone=vado_gris --demo --shots=<absolute path> --quit-after-demo
```

- The player appears at the first spawn point of their realm (`Vardheim1` or `Solmarch1`), facing
  the fort.
- The demo (`RouteDemoInput.vado_gris()` in `scripts/client/route_demo_input.gd`) follows the
  bridge route of `verify_vado_gris_routes.gd`: camp, road with sprint and jump, own bridge, two
  jumps at the foot of the fort, sidestep, corner of the palisade, gate esplanade and camera turn.
  It lasts about 1970 ticks (33 s) and Solmarch runs the exact mirror.
- With `--shots` it also saves, at the end, a screenshot without HUD from each marker of
  `ScreenshotPoints` (`zona_<name>.png`).

## How to regenerate

With the editor closed, from the project root (`godot` is the console executable):

```
godot --headless --path . -s res://tools/assets/copy_vado_gris_assets.gd     # copies and rescales from ../Eldmark-raw
godot --headless --path . --import
godot --headless --path . -s res://tools/assets/extract_kit_meshes.gd        # kit meshes to .tres
godot --headless --path . -s res://tools/materials/build_realm_materials.gd  # realm materials, water, bark and leaves
godot --headless --path . -s res://tools/assets/apply_nature_materials.gd    # custom bark and leaves on the tree glTFs
godot --headless --path . --import
godot --headless --path . -s res://tools/props/build_vado_gris_props.gd      # scenes/world/props/ (fort, gate, NPC markers)
godot --headless --path . -s res://tools/terrain/generate_vado_gris.gd       # terrain + vado_gris.tscn
godot --headless --path . -s res://tools/bake_navmesh.gd                     # vado_gris_navmesh.tres (2 s)
godot --headless --path . -s res://tools/bake_zone_map.gd                    # assets/maps/vado_gris.png and vado_gris_map.tres
godot --headless --path . --import                                           # imports the new PNG
```

Checks:

```
godot --headless --path . -s res://tests/run_tests.gd                         # includes test_vado_gris_zone.gd
godot --headless --path . --fixed-fps 60 -s res://tools/terrain/verify_vado_gris_routes.gd
godot --path . -s res://tools/render/render_screenshot_points.gd -- --out=<path>/build/vado_gris
```

- The NPC navigation mesh has to be re-baked (`tools/bake_navmesh.gd`, see docs/fortress.md 4.1)
  every time the gameplay geometry changes: ramps, walkway, gate, bridges, walls, blockers...
  `tests/test_navmesh.gd` reminds you with broken routes.
- The map for the minimap and the full-screen map (`assets/maps/vado_gris.png`, via LFS, and its
  scale and fixed places in `vado_gris_map.tres`) is baked without a GPU with
  `tools/bake_zone_map.gd`: shaded relief from `Terrain3D.data.get_height`, water from the river
  mesh and outlines of the collisions and the `BakedMultiMesh` nodes. It covers the playable area
  with a 10 m margin (320 x 320 m, 1024 px, 3.2 px/m, north up) and comes out identical on every run
  (about 8 s). It has to be repeated if the relief, the water or the collisions change, or the
  camps, the fort and the passes it marks (`tests/test_zone_map.gd` reminds you).
- Only the first two steps are needed if the assets change. In a git worktree the packs folder is
  not next to the repo: it is passed with `-- --raw=<path to Eldmark-raw>` to
  `copy_vado_gris_assets.gd`, and a new worktree brings the terrain `.res` files as LFS pointers:
  `git lfs checkout` fills them in before importing. To change the layout, edit
  `tools/terrain/vado_gris_layout.gd` (positions, river, roads, height function) and run the
  generator again; the vegetation, the painting and the piece scenes are in their own scripts.
- Everything is deterministic (fixed seeds): repeating it on the same machine leaves the same
  region data, water mesh and terrain assets, byte for byte. In the `.tscn` scenes only the
  `unique_id` that Godot assigns to each node on save changes. Across platforms (it was generated
  on Windows and has been repeated on Linux) there is noise: the region `.res` files and the water
  mesh come out with different bytes and the scenes with last-decimal differences in some
  transforms (sine and cosine), besides the resource identifiers. If the change does not touch the
  terrain, the `.res` files and the water mesh are restored from the repository, and from the
  regenerated scenes the identifiers and the noise are discarded so that the diff carries only what
  really changed.
- **`vado_gris.tscn` is not edited by hand:** the generator rewrites it entirely.

## Pending items

- Split the gameplay layer and the visual layer (`_gameplay.tscn` / `_visual.tscn`). Meanwhile the
  server loads the whole scene and then calls `ZoneRoot.strip_for_server()`.
- From the walkway, with the parapet at 1.3 m, the strip of about 8 m at the foot of the palisade
  is still not visible except by leaning out at the corners: a platform above the gate is missing.
- Custom pieces in Blender with the kit's textures (world.md/arte.md): the palisade and the bridge
  are custom meshes generated by script; the fort tower and the walls use the Castle Wall Kit, and
  the tents are prisms. When the Village MegaKit Source arrives, replace them.
- The fort gate is closed but still lifeless: the phase 4 logic is missing (health, hits and
  repair, `FortressController`) and the break states of the leaves (ART-17).
- The banners are the Kenney Castle Kit flag (blockout), recolored.
- No wind on the vegetation, no custom tree LOD (only the automatic one) and no HLOD.
- The road braziers (state of the Ember Lines) do not exist yet.
- The water's edge is an invisible collision; when swimming exists, replace it.
