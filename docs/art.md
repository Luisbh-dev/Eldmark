# Eldmark: art direction and asset plan

> This document is based on the verified research of 2026-10-28. I rechecked two facts on the web that decide purchases, and both are still unconfirmed:
> - **Strafe in UAL1 Pro.** The page does not say which version includes the "Locomotion in 8 directions" ([itch](https://quaternius.itch.io/universal-animation-library)).
> - **Skeleton in the Bestiary.** "Skeletons" only appears as a tag. The quaternius.com page says "7 Monsters" without naming them ([itch](https://quaternius.itch.io/bestiary-dungeon-monsters-kit), [quaternius.com](https://quaternius.com/packs/bestiarydungeonmonsterskit.html)).
>
> I have not downloaded anything. Downloads from itch.io have to be done by a person, by hand.

---

## 1. Chosen art direction

**Semi-realistic stylized with textures, from the Quaternius "Universal + MegaKit" family (2024–2026).** It is a single family for characters, environment and nature. Castles are completed with the Castle Wall Kit (CC0), retextured, and with custom pieces made with the same textures.

### Why this one and not KayKit

| Criterion | Quaternius Universal/MegaKit | KayKit |
|---|---|---|
| Characters and animation | Base body, modular outfits and UAL1/UAL2 share a single rig since UAL1 v2.0. Since then no retargeting is needed between them. | A single rig and the best free combat coverage, but the style is chibi. |
| Human-scale environment | Village MegaKit (about 300 modules with interiors), Fantasy Props and Stylized Nature. Same author, era, texturing and scale. | No human-scale village or castle kit. The Medieval Hexagon is a tabletop miniature. |
| New World tone | Human or heroic proportions. Block and heavy attack read well and hitboxes are human-sized. | Lighthearted and cartoonish. |
| Recolor per realm (world.md) | Grid-based pieces and few texture sets: they are recolored with a shader. | Gradient atlas, also recolorable, but with no buildings to walk around. |
| Extensible | The Source versions ($15 to $20, still CC0) ship the .blend files to model custom pieces with the same textures. | Same, but without an architectural base. |

On the downside, stated plainly:
- There is no Quaternius castle kit. In June 2025 he said it depends on a Patreon vote.
- The knight and the mage come in the Outfits Source ($20).
- No free pack in the family includes bow animations.
- It is not confirmed that the Bestiary includes a skeleton, and its license is QAL, not CC0.
- Each character is about 13,000 triangles plus clothing. In the war zone that is heavy, so it must be measured early.

### Minimum style rules

- Scale: 1 unit = 1 m. An adult human is about 1.8 m tall. Each pack is validated on import against a 1.8 m capsule.
- No photographic textures (Poly Haven, ambientCG) on foreground assets. They are only used as filler terrain, and always processed: desaturated and with less detail.
- A single surface shader per realm, recoloring the same kit:

| Realm | Stone | Wood | Roof | Accent | Extra layer |
|---|---|---|---|---|---|
| Vardheim | cold, rough gray | almost black | brownish-gray planks | ice blue | snow on upward-facing surfaces |
| Solmarch | cream limestone | light | blue slate | white and gold | moss or ivy (the kit includes vines) |
| Askarra | red sandstone | reddish | terracotta | crimson and bronze | dust or ash |
| Eldrun | the desaturated kit | gray | missing pieces (ruin) | emissive embers in the cracks | ash |

- Before importing in bulk, a **style test scene** is built (`scenes/tests/style_test.tscn`). It holds a character with an outfit, five Village pieces, a section of the Castle Wall Kit, Nature trees and the Watercolor terrain under the game's lighting. If something clashes, it is discarded before filling LFS.

---

## 2. Recommended download list

For every "name your own price" itch.io pack the method is the same. A person opens the page, clicks **Download Now** and chooses **"No thanks, just take me to the downloads"** (free version) or pays (paid versions). Then they download the indicated zip **to a folder outside the repo** (for example `../Eldmark-raw/<pack>/<version>/`). Only the glTF folder that is used goes into the repo, and the version and date are recorded in `assets/LICENCIAS.md`. Itch provides no stable direct URL.

Anything marked "QAL" or "not CC0" is flagged. Everything else is CC0 1.0.

### Priority 1: essential now

**1. Universal Animation Library (UAL1), Standard**
- **Author:** Quaternius
- **Page:** https://quaternius.itch.io/universal-animation-library
- **Download:** itch, Standard is free. Download the current version (v3.0, 2026-06-16 or later). **Do not use** the OpenGameArt copies or the one on the Godot Asset Store: they predate v2.0, which changed the bone names.
- **Size:** 15 MB
- **License:** CC0 1.0. Stated by the "Asset license" row on itch and quaternius.com/packs/universalanimationlibrary.html.
- **Contents:** 45 animations on the universal rig. Idle, walk, jog, sprint, 3-phase jump, Roll, Sword_Idle/Attack, Spell_*, Hit_Chest/Head, Death01 and A_TPose. v3.0 ships variants with and without root motion. Use the ones **without root motion**: the server decides movement. The page does not say which versions include both variants.
- **In the repo:** `assets/animations/ual1/`

**2. UAL1 Pro (paid, recommended)**
- **Price:** from $9.99
- **Size:** 41 MB
- **License:** CC0
- **Contents:** the 120+ animations. **Check before paying** that 8-direction strafe is included in Pro: this is a deduction, the page does not say so. If it only came in Source ($14.99), buy Source. Strafe is essential with the over-the-shoulder camera (phase 1).
- **In the repo:** `assets/animations/ual1/`

**3. Universal Animation Library 2 (UAL2), Standard**
- **Author:** Quaternius
- **Page:** https://quaternius.itch.io/universal-animation-library-2
- **Download:** itch, Standard is free. Download v2.2 (2026-09-28); the OpenGameArt copy is old.
- **Size:** 17 MB
- **License:** CC0. Stated by the itch description ("(CC0 License)") and quaternius.com/packs/universalanimationlibrary2.html.
- **Contents:** about 42 animations:
  - Sword combos SWORD_REGULAR_A, _COMBO, _COMBOB and _REC, plus SWORD_DASH. They serve as the basis for the light and heavy attack.
  - IDLE_SHIELD (block) and IDLE_SHIELD_BREAK (guard break).
  - KNOCKBACK, SLIDE and ZOMBIE_WALK_FWD (useful for the Hollow).
  - It is **not confirmed** that the skeleton is identical to UAL1's: bone names must be compared on import.
- **In the repo:** `assets/animations/ual2/`

**4. Universal Base Characters, Standard**
- **Author:** Quaternius
- **Page:** https://quaternius.itch.io/universal-base-characters
- **Download:** itch, Standard is free
- **Size:** 122 MB
- **License:** CC0 1.0, per the "Asset license" row on itch
- **Contents:** 2 base bodies and 5 hairstyles, of about 13,000 triangles, compatible with UAL. The formats are OBJ, FBX and glTF: import **only the glTF**.
- **In the repo:** `assets/models/characters/base/`

**5. Modular Character Outfits - Fantasy, Standard**
- **Author:** Quaternius
- **Page:** https://quaternius.itch.io/modular-character-outfits-fantasy
- **Download:** itch, Standard is free. Download v2.1 (2026-07-05) or later.
- **Size:** 280 MB
- **License:** CC0 1.0, per the "Asset license" row on itch
- **Contents:** Ranger and Peasant outfits in modular pieces, with 3 texture variants. They come as .gltf with loose .bin and textures: the whole folder must be imported. No weapons included.
- **In the repo:** `assets/models/characters/outfits/`

**6. Bestiary - Dungeon Monsters Kit, Standard (conditional: it is QAL, not CC0)**
- **Author:** Quaternius
- **Page:** https://quaternius.itch.io/bestiary-dungeon-monsters-kit
- **Download:** itch, file "Bestiary - Dungeon Monsters Kit[Standard].zip"
- **Size:** 45 MB
- **License:** **QAL v1.0** (2026-08-28), at https://quaternius.com/license.html. It allows commercial use and selling the game without attribution. Section 3(a) **forbids redistributing the loose files**. Note: the quaternius.com FAQ says "everything is CC0", which contradicts this license.
- **Contents:** 7 monsters with weapons and 3 colors each, on the UAL-compatible rig. No animations.
- **Condition:** download it and check whether the Standard includes a skeleton. If it does, it works for the Hollow (4 guards and the Captain in a different color). If not, apply plan B from section 4.8.
- **In the repo:** `assets/models/enemies/bestiary/`. This is fine while the repo is private. If it is made public, it must be removed before the repo goes public.

**7. Medieval Village MegaKit, Standard**
- **Author:** Quaternius
- **Page:** https://quaternius.itch.io/medieval-village-megakit (and https://quaternius.com/packs/medievalvillagemegakit.html)
- **Download:** itch, Standard is free
- **Size:** 153 MB
- **License:** CC0 1.0. Stated by itch, quaternius.com and the Godot Asset Store.
- **Contents:** about 170 of the 304 grid modules: walls, floors, stairs, roofs, doors, windows and vines. It is **the base kit that gets recolored per realm**. It has no confirmed towers, battlements or barbican, nor collisions (those come in Source).
- **In the repo:** `assets/models/environment/village/`

**8. Stylized Nature MegaKit, Standard**
- **Author:** Quaternius
- **Page:** https://quaternius.itch.io/stylized-nature-megakit
- **Download:** itch, Standard is free
- **Size:** 99 MB
- **License:** CC0 1.0 (itch and quaternius.com)
- **Contents:** 81 models including trees with 7 leaf types, plants, rocks, grass and bushes. No cliffs. The wind shaders are exclusive to Source.
- **In the repo:** `assets/models/environment/nature/`

**9. Castle Wall Kit**
- **Author:** loafbrr
- **Page:** https://loafbrr.itch.io/castle-wall-kit
- **Download:** itch, pay what you want from $0. Download `CastleWallKit_blend_fbx_gltf_textures.zip`; it is the good source. `CastleWall_Kit_Godot.zip` (35 MB) is only useful as a reference for the GridMap assembly: it does not say which Godot version it targets and may include binary resources.
- **Size:** 149 MB (zip with glTF)
- **License:** CC0 1.0, per the itch license field
- **Contents:**
  - 116 wall pieces of 6 × 6 m, with a door, 2 gates and windows.
  - 4 1K materials (brick and trimsheet) and about 8,000 triangles in total.
  - Used for the facades of the walls (Muro de Escarcha and Muralla del Alba), **retextured**.
  - **Drawbacks:** brick only, no confirmed towers or battlements. It is a recent listing by a small author.
- **In the repo:** `assets/models/environment/castle_wall/`

**10. Castle Kit 2.0 (blockout only)**
- **Author:** Kenney
- **Page:** https://kenney.nl/assets/castle-kit
- **Direct download:** https://kenney.nl/media/pages/assets/castle-kit/a395102d20-1711543616/kenney_castle-kit.zip ("Continue without donating" link)
- **Size:** 2.1 MB
- **License:** CC0. Stated by kenney.nl ("Creative Commons CC0"), itch and OpenGameArt.
- **Contents:** 75 models: walls, towers, gates, siege weapons, banners. It is **not verified** which siege weapons it includes or whether they have a destroyed version. Useful for assembling the Vado Gris fort in gray and as a siege reference. **Never as final art.**
- **In the repo:** `assets/models/blockout/kenney_castle/`

**11. Watercolor Terrain Textures**
- **Author:** Jonas Voland / Voxel Core Lab
- **Page:** https://voxelcorelab.itch.io/watercolor-terrain-textures
- **Download:** itch, pay what you want from $0, file `VoxelCoreLab_Watercolor_Terrain_Textures_1024px.zip`
- **Size:** 28 MB
- **License:** CC0 1.0, per the description and the itch license field. Attribution is optional; the author asks to be credited as "Jonas Voland".
- **Contents:** 16 seamlessly tileable 1024 px PNGs: 4 grass, 4 stone, 4 dirt and 4 water. Almost certainly color only, with no normals or roughness. They cover Vado Gris: grass, dirt, stone and shoreline.
- **In the repo:** `assets/textures/terrain/watercolor/`

The **priority 1 tools** are Terrain3D 1.0.2 and ProtonScatter (main). They are in section 3.

### Priority 2: soon (phase 3 combat and phase 4 fort)

**12. Fantasy Props MegaKit, Standard**
- **Author:** Quaternius
- **Page:** https://quaternius.itch.io/fantasy-props-megakit
- **Download:** itch, free
- **Size:** 143 MB
- **License:** CC0 1.0 (itch and Godot Asset Store)
- **Contents:** 94 models with only 4 texture sets: weapons (placeholder swords for phase 3), barrels, chests, market stalls and furniture. It is **not confirmed** to include shields or banners.
- **In the repo:** `assets/models/environment/props/`

**13. RPG Weapons, Free (and Pro)**
- **Author:** Binbun
- **Page:** https://binbun3d.itch.io/rpg-weapons
- **Download:** itch. Free is free; Pro at $3.99 or $7.99 (the page gives both prices).
- **Size:** Free 10 MB, Pro 12 MB
- **License:** CC0 1.0 on all versions, per the Licensing section and the itch License field
- **Contents:**
  - Free: 70 weapons, including spears and maces.
  - Pro: adds bows, arrows, staves and **2 shield types** (needed for blocking).
  - According to v1.1, it includes a Godot project: check that the resources are .tscn/.tres.
  - Check the style alongside the Outfits.
- **In the repo:** `assets/models/weapons/binbun_rpg/`

**14. KayKit Character Animations, Free 1.1 (supporting animations only)**
- **Author:** Kay Lousberg
- **Page:** https://kaylousberg.itch.io/kaykit-character-animations
- **Download:** itch, free. **Not** the "(Legacy)" version.
- **Size:** 14 MB
- **License:** CC0 1.0, per the itch "Asset license" field
- **Contents:** 161 animations with block, dodge, bow and spells. Used **only** to try retargeting the missing ones onto the UAL rig: block impact, directional dodge and bow. The author warns that outside KayKit it "may not look good".
- **In the repo:** `assets/animations/kaykit/` (only the approved clips)

**15. Hit FX and Battle FX, Free (Full from $3.49 each)**
- **Author:** Binbun
- **Pages:** https://binbun3d.itch.io/hit-fx and https://binbun3d.itch.io/battle-fx
- **Download:** itch
- **Size:** Hit FX 39 kB (Full 1.3 MB); Battle FX 985 kB (Full 1 MB)
- **License:** CC0 1.0 on all versions, per the itch License field
- **Contents:**
  - Godot 4 shaders and presets for impacts, slashes, sweeps and shields.
  - A commenter says Hit FX works on 4.7-stable.
  - Check that the resources are text and where the audio they include comes from.
- **In the repo:** `assets/vfx/binbun/`

**16. Particle Pack**
- **Author:** Kenney
- **Page:** https://kenney.nl/assets/particle-pack
- **Direct download:** https://kenney.nl/media/pages/assets/particle-pack/f8fe0f8cb8-1677578741/kenney_particle-pack.zip
- **Size:** the page does not state it
- **License:** CC0 (kenney.nl)
- **Contents:** 80 particle textures of 512 px: sparks, smoke, dodge dust and weapon trails.
- **In the repo:** `assets/vfx/kenney_particles/`

**17. RPG Audio and Impact Sounds**
- **Author:** Kenney
- **Pages:** https://kenney.nl/assets/rpg-audio and https://kenney.nl/assets/impact-sounds
- **Direct download:**
  - https://kenney.nl/media/pages/assets/rpg-audio/8e99002d76-1677590336/kenney_rpg-audio.zip
  - https://kenney.nl/media/pages/assets/impact-sounds/87b4ddecda-1677589768/kenney_impact-sounds.zip
- **Size:** RPG Audio 691 KB; Impact Sounds not stated
- **License:** CC0 (kenney.nl and OpenGameArt)
- **Contents:** 50 footstep, foley and weapon sounds, plus 130 impacts, in OGG (confirmed for RPG Audio).
- **In the repo:** `assets/audio/sfx/kenney/`

**18. Medieval SFX: Weapon Textures and Weapon Impacts**
- **Author:** Still North Media (Ben Jaszczak and Brian Nelson); uploaded by MedicineStorm
- **Pages:** https://opengameart.org/node/146862 and https://opengameart.org/node/146863
- **Download:** direct OpenGameArt links to 4 .7z files. They must be **unpacked outside the repo** and clips selected.
- **Size:** about 332 MB in total
- **License:** CC0 on OpenGameArt, but it relies on the quote "CC0 NO RIGHTS RESERVED" from the original website, which only survives on Archive.org.
- **Contents:** axe, dagger, saber and spear swings; unsheathing; longbow and recurve bow; crossbow; weapon-on-weapon clashes. No armor clashes or mace swing. The format is not confirmed.
- **In the repo:** `assets/audio/sfx/still_north/` (only the chosen clips, converted to OGG)

**19. 80 CC0 RPG SFX**
- **Author:** rubberduck
- **Page:** https://opengameart.org/content/80-cc0-rpg-sfx
- **Download:** direct OpenGameArt zip (`80-CC0-RPG-SFX.zip`)
- **Size:** 1.8 MB
- **License:** CC0, per the OpenGameArt License(s) field
- **Contents:** 22 creature sounds (wounds and deaths of the Hollow), spells, coins, locks and chains.
- **In the repo:** `assets/audio/sfx/rubberduck/`

**20. Medieval Village MegaKit Source (paid)**
- **Price:** from $14.99
- **Size:** 675 MB
- **License:** CC0
- **Contents:** all 304 models, optimized collisions, .blend files and a Godot 4.3 project. It saves the collision work and allows modeling custom pieces (palisade, fort tower, bridge) with the same textures.
- **In the repo:** `assets/models/environment/village/` (whatever is used). The .blend files go to `assets/models/environment/custom/src/`.

The **priority 2 tools** are Sky3D 2.1.0 and the toon water shader.

### Priority 3: later

- **Modular Character Outfits Source** ($20, 724 MB, CC0): all 12 outfits, including knight, mage and noble. When the classes are defined.
- **Universal Base Characters Source** ($19.99, 600 MB, CC0): all bodies, 20 hairstyles and skin and eye shaders (for the races).
- **UAL2 Source** ($14.99, 50 MB, CC0): 3- and 4-hit combos with recovery and Sword_Light.
- **RPG Weapons Pro**, if not bought earlier.
- **Elemental Magic FX** (Binbun, CC0, 916 kB; Full $3.49), if there are magic classes: https://binbun3d.itch.io/elemental-magic-fx
- **Interface Sounds and UI Audio** (Kenney, CC0):
  - https://kenney.nl/media/pages/assets/interface-sounds/fa43c1dd4d-1677589452/kenney_interface-sounds.zip
  - https://kenney.nl/media/pages/assets/ui-audio/490d233f68-1677590494/kenney_ui-audio.zip
  - They go to `assets/audio/ui/`.
- **Poly Haven** (CC0, https://polyhaven.com/license), to fill the gaps in the Watercolor set:
  - Snow for Vardheim (snow_01 to snow_05), sand and rock for Askarra, gray gravel for Eldrun.
  - 1k PNGs with nor_gl, run through the Terrain3D packer and desaturated.
  - They go to `assets/textures/terrain/polyhaven/`.
  - As an alternative, **ambientCG** (CC0, https://docs.ambientcg.com/license/).
- **Terrain3D 1.1.0 stable**, when it is released: it ships an ocean, height displacement and a slope-based colorizer.
- **Forest ambience** (CC0): https://opengameart.org/content/forest-ambience
- **KayKit Medieval Hexagon** (CC0, 33 MB), only if a 3D strategic map of Eldrun is wanted in the interface.

**Indicative budget:** the essentials cost about $10 (UAL1 Pro). The recommended short- and medium-term purchases (Outfits Source, Village Source, RPG Weapons Pro and 2 FX Full) add up to $45 to $50 more. Everything is still CC0, except the Bestiary.

---

## 3. Recommended Godot tools

| Tool | Version for 4.7 | License | Size | GDExtension | Installation |
|---|---|---|---|---|---|
| **Terrain3D** (TokisanGames). Clipmap terrain, painting with up to 32 textures, holes and a vegetation instancer. | **v1.0.2-stable** (2026-05-19, "Supports Godot 4.4-4.7"). v1.1.0-rc1 (2026-10-17, 4.5–4.8+) is preliminary: move to stable 1.1 when it is released. | MIT (repo LICENSE.txt) | 42.3 MB zip | **Yes**: native DLL/SO/dylib for Windows, Linux and macOS | Download https://github.com/TokisanGames/Terrain3D/releases/download/v1.0.2-stable/Terrain3D_v1.0.2-stable.zip (or AssetLib #3892). Copy only `addons/terrain_3d/` to `res://addons/`, open the editor (if it errors the first time, restart it) and enable it in Project > Project Settings > Plugins. Do not version `demo/`. |
| **ProtonScatter** (HungryProton). Distribution of trees, rocks and props **with collision**. | **main branch**. The fixes for 4.7 are from 2026-07-26 and 2026-02-25, and the Jolt one from 2026-09-27. **Do not use** AssetLib #1866: it predates those fixes. | MIT. The demo textures come from Textures.com: **do not version the demo**. | Repo of about 16 MB | No (GDScript) | Download https://github.com/HungryProton/scatter/archive/refs/heads/main.zip and **record the commit SHA** in LICENCIAS.md. Copy `addons/proton_scatter/` **without renaming it** and enable the plugin. |
| **Sky3D** (TokisanGames). Day and night cycle with sun, moon, stars, fog and clouds. | **v2.1.0** (2026-05-19, Godot 4.3+). Issue #120 on 4.7 is closed. | MIT code. The star textures are **CC BY 4.0** (ESO/S. Brunier) and **require credit**. The provenance of MoonMap.png is unclear: replace it before publishing. | 11.5 MB | No | Download https://github.com/TokisanGames/Sky3D/releases/download/v2.1.0/Sky3D_v2.1.0.zip (or AssetLib #5167). Copy `addons/sky_3d/` and enable it. **Client only**: instantiate it from `client_main`, not in the shared zone scene. The time of day is sent by the server. |
| **Terrain3D instancer** (included) for grass | Same as Terrain3D | MIT | — | — | The instances **have no collision**: only for grass and small details. |
| **Toon water shader** (Megalithium, godotshaders.com) | Tested on 4.3; a user says it works on 4.5.1. **It must be tested on 4.7**, especially the depth-based foam. | CC0 (the code; the images in the post are not) | A few KB | No | Copy the code from https://godotshaders.com/shader/toon-style-3d-water-shader-no-textures-needed/ to `assets/materials/shaders/water_toon.gdshader`, on a PlaneMesh with subdivisions. |
| **Godot 4.7 features** | Included | MIT | — | — | Occlusion culling (enable in Advanced Settings and bake `OccluderInstance3D`: walls are perfect occluders), visibility ranges with `visibility_parent` (HLOD for distant forts), automatic LOD on import and `MultiMeshInstance3D`. |

Notes on Terrain3D:
1. **It conflicts with two repo rules.** It stores each region as a binary `.res` (`terrain3d_XX_YY.res`) and ships native binaries. An explicit exception is needed in CLAUDE.md, and `*.res`, `*.dll`, `*.so` and `*.dylib` must be added to LFS (section 4.5).
2. **The headless server is not documented.** First task: verify that `godot --headless --path . --import` and a zone with terrain start without a window, and that collision responds. Use Full/Game collision on the server (it uses memory on large maps) or `Terrain3DData.get_height()`. The collision failure in #1043 only occurs in double-precision builds.
3. **Alternative if headless fails:** HTerrain (Zylann, MIT, pure GDScript, master branch for Godot 4.6+). It only receives fixes, but loads without problems in headless.

ProtonScatter and the server: with the `keep_static_colliders` option the collisions are created at runtime and not saved in the scene. For client and server to have **the same baked collision**, use the **Create Copies** mode with object scenes that carry their own `StaticBody3D` and `CollisionShape3D`, and leave the result saved in the zone scene. Check the addon's documentation panel for how the generated output is kept. No scattering of objects at runtime on the server.

---

## 4. Integration plan

### 4.1 Download workflow
1. A person downloads to `../Eldmark-raw/<pack>/<version>/`, outside the repo. Zips are never versioned.
2. It is recorded in `assets/LICENCIAS.md`: pack, author, version, date, URL, license, where it is stated, and the zip hash if possible. Mandatory credits (ESO/S. Brunier for the Sky3D stars) and courtesy credits (Jonas Voland, Kenney, Quaternius) go there too.
3. **Only** the glTF subfolder goes into the repo (Quaternius packs duplicate everything in FBX, OBJ and glTF), and only the pieces that are used.

### 4.2 glTF import in Godot 4.7
- **Static models:**
  - Enable "Generate LODs" and "Create Shadow Meshes" (enabled by default).
  - Collisions in *Advanced Import Settings* > mesh > Physics: Static Body with Box or Convex for most pieces, and Trimesh only for complex walls. If the Village Source is bought, use its collisions.
- **Materials:** extract them as **.tres** so they can be swapped per realm, never as .res. Textures in VRAM Compressed with mipmaps.
  - Godot's 3D detection (`detect_3d`) only acts inside the editor: in a headless import the glTF textures stay uncompressed and without mipmaps (more VRAM and glints on distant stone). `tools/assets/apply_texture_import_presets.gd` sets their `.import` files (VRAM compressed, mipmaps, normal compression on `*_normal.png`, `detect_3d/compress_to=0`) and `tests/test_character_visual.gd` checks that none is missing.
- **Many pieces:** an `EditorScenePostImport` script in `tools/import/` assigns collision and realm material uniformly.
- **Assembly:** one `.tscn` scene per piece plus snapping. If a GridMap is used for the walls, save the MeshLibrary as .tres and watch its size.
- **Scale:** check each pack against the 1.8 m capsule. The Kenney Castle Kit almost certainly needs rescaling.

### 4.3 Common skeleton and retargeting
1. **Characters (Base, Outfits, Bestiary):** in *Advanced Import Settings* > `Skeleton3D` > *Retarget* > *Bone Map* you must:
   - Create a `BoneMap` with the `SkeletonProfileHumanoid` profile and review the automatic mapping.
   - Save it as `assets/animations/rig/ual_humanoid_bone_map.tres` and reuse it on all Quaternius files.
   - Leave *Rename Bones* and *Make Unique Skeleton* enabled (name `GeneralSkeleton`), and in *Rest Fixer*: *Apply Node Transforms*, *Normalize Position Tracks* and *Overwrite Axis*.
   - This way all tracks point to `GeneralSkeleton:<ProfileBone>` and the libraries work for any humanoid.
2. **Animation files (UAL1, UAL2, KayKit clips):** import them with *Import As: Animation Library*. Apply the same BoneMap and mark looping on idle and locomotion.
   - In Godot each one ends up as a library in the AnimationPlayer or AnimationTree, with the prefixes `ual1/`, `ual2/` and `kaykit/`.
   - When loading UAL2, the bone names are checked against UAL1.
3. **References:**
   - The `Humanoid_map.tres` from the CC0 Codeberg addon (jamesonBradfield/Quaternius_IK_Rigged_with_animations) serves as a guide; there is no need to depend on it.
   - There is a known warning: the UpperChest bends too much when remapped. Map it the same at source and target, or leave it unmapped on both.
4. **Root motion:** use the **non-root-motion** variants. The displacement of the dodge or the charge is computed by shared, deterministic code in `scripts/shared/`, so that client-side prediction and server authority match.
5. **Server:** it does not play animations. The hit windows (anticipation, active hit and recovery) and the shapes of the weapon arc are **data** in `scripts/shared/`, not bone positions. This satisfies the rule that `scripts/shared` must not depend on `client`, and hitbox rewind stays cheap.

### 4.4 Recoloring per realm
- A shader `assets/materials/shaders/realm_surface.gdshader` with these parameters: color texture, hue shift, saturation, brightness, tint, layer color and amount (snow or ash according to the world-space normal) and ember emission.
  - With a `StandardMaterial3D` you can only multiply color, and that only darkens. Going from wood to limestone or sandstone requires changing the hue.
- Materials in `assets/materials/realms/{vardheim,solmarch,askarra,eldrun}/` (stone, wood, roof…), applied as an override when instantiating pieces or from the post-import script.
- Whatever the kit lacks is modeled in Blender with the kit's textures and grid, starting from the Source .blend files, and goes to `assets/models/environment/custom/`:
  - log palisade and the fort's 2-story tower;
  - stone bridge and longhouses;
  - cathedral and conical towers;
  - Askarra domes and arches;
  - ruined variants.

### 4.5 Git LFS and repo rules
Add to `.gitattributes`. It already covers glb, bin, fbx, obj, blend, png, jpg, wav and ogg.
```
# Terrain3D region data (exception to the text rule, see CLAUDE.md)
*.res filter=lfs diff=lfs merge=lfs -text
# GDExtension native binaries (Terrain3D)
*.dll filter=lfs diff=lfs merge=lfs -text
*.so filter=lfs diff=lfs merge=lfs -text
*.dylib filter=lfs diff=lfs merge=lfs -text
```
Add to `.gitignore`: `*.zip`, `*.7z`, `*.blend1` and `addons/*/demo/`.

`.gltf` (JSON), `.import`, `.uid`, `.tres` and `.tscn` files are versioned as text.

Add the exception to CLAUDE.md: "the Terrain3D region `.res` files are the only permitted exception to the text format".

LFS quota: the priority 1 zips add up to about 1.1 GB. Uploading only the glTF that is used, the repo should stay at a fraction of that. Check the LFS quota of your GitHub plan before the first big push.

### 4.6 Folder structure
```
addons/terrain_3d/  addons/proton_scatter/  addons/sky_3d/
assets/
  LICENCIAS.md
  animations/{rig,ual1,ual2,kaykit}/
  models/
    characters/{base,outfits}/
    enemies/{bestiary,huecos}/          # huecos = the enemy's own scenes
    environment/{village,props,nature,castle_wall,custom}/
    weapons/binbun_rpg/
    blockout/kenney_castle/
  materials/{realms/<realm>/,shaders/}
  textures/terrain/{watercolor,polyhaven}/
  vfx/{binbun,kenney_particles}/
  audio/{sfx/<pack>/,ui/,ambience/}
scenes/world/zones/vado_gris/           # zone scene + Terrain3D .res data
scenes/tests/style_test.tscn
tools/import/                           # EditorScenePostImport scripts
```

### 4.7 Dedicated server
- On export, use *Export as dedicated server* and mark `assets/models`, `textures`, `vfx` and `audio` as *Strip Visuals*. **Never *Remove*** for anything that references a zone scene (kit meshes, `vado_gris_terrain_assets.tres`, materials): zone scenes are shared and the server would not be able to load them. The server needs collisions and scenes, not textures. The `Servidor Linux` preset in `export_presets.cfg` (TEC-12) strips `assets/models`, `materials`, `audio` and `animations`; the terrain textures (`assets/textures/terrain`) are **not** stripped, because Terrain3D validates the format of every texture in its assets and logs an error for each stripped one (the server works the same, but with 28 error lines at startup), and that is why that preset exports textures with S3TC.
- After loading the zone, the server calls `ZoneRoot.strip_for_server()` (`scripts/world/zone_root.gd`): it frees meshes, MultiMesh, lights and environment and empties the Terrain3D instancer, and keeps collisions, terrain and markers. This is not done on detecting headless, because the tests and the windowless client also run headless.
- Sky3D, VFX, audio and grass are instantiated only from `scenes/client/`.

### 4.8 Risks and gaps

| Risk | Mitigation |
|---|---|
| Everything from Quaternius and Binbun is downloaded from itch by hand; the OpenGameArt and Godot Asset Store copies are **outdated** (bones from before v2.0). | Human download from itch and the version recorded in LICENCIAS.md. |
| It is not known whether strafe ships in UAL1 Pro (checked today, still unclear). | Confirm it in the devlog or the images before paying; if not, buy Source. |
| UAL2 might not have the same skeleton as UAL1. | Compare bone names on import. The common BoneMap absorbs small differences. |
| **The Hollow:** it is not known whether the Bestiary includes a skeleton, and it is QAL. | Plan B: in the meantime, a base body with the Peasant outfit, a desaturated gray bone material and emissive eyes. In the medium term, model a skeleton on the UAL rig from the Base Characters Source. If the repo is made public, remove whatever is QAL. |
| There is no free bow, block impact or directional dodge on the UAL rig. | Retarget clips from KayKit Character Animations (they may look exaggerated). Last resort: Mixamo (see section 5). |
| Terrain3D in headless is not documented; it also ships binary `.res` files and DLLs. | Test at the start (section 3). Plan B: HTerrain. Exception in CLAUDE.md and LFS. |
| Sky3D: CC BY 4.0 stars and a moon of doubtful provenance. | Credit ESO/S. Brunier or swap them for CC0 stars. Replace MoonMap.png before publishing. |
| ProtonScatter demo with Textures.com textures. | Do not version `demo/`. |
| Castle Wall Kit: small, recent author, brick only, Godot version unstated. | Use the glTF, retexture and validate in the style test scene. |
| The Kenney Castle Kit siege weapon list has not been verified. | Check the zip. It is blockout only; the final siege (phase 7) will be custom-modeled. |
| Still North's CC0 relies on an archived quote. | Low risk; choose few clips and record the provenance. |
| Performance: 13,000 triangles per character plus several clothing pieces, each with its own draw call. | Automatic LOD (check that it is applied to skinned meshes). Remote characters with pieces merged in Blender per preset. Measure in the war zone from phase 2, as vision.md requires. |
| Styles that may clash: Watercolor, Binbun and Castle Wall Kit. | The style test scene is the gate. |
| Prices on sale or contradictory (Binbun Pro at $3.99 or $7.99). | Check them at purchase time. |

### 4.9 Custom modeling with Blender: the sword

The first piece of final art made in-house (ART-06), and the template for the following ones (shields, bow, NPC weapons). Everything is modeled by script, without opening the interface, and the script is what gets versioned; the GLB comes out of it.

- **How to regenerate it.** `blender --background --factory-startup --python tools/blender/build_sword.py` (Blender 5.2) and then `godot --headless --path . --import`. It writes `assets/models/weapons/sword_base.glb` and one variant per realm (`sword_vardheim.glb`: crossguard of fangs curved toward the tip, wolf-head pommel in profile with an ice gem for an eye and blue leather; `sword_solmarch.glb`: half-sun crossguard (the split sun of the emblem, with the two long rays as quillons and the lower half solid), eight-ray sun pommel alternating long and short rays with a faceted sun stone, gold and white leather; `sword_askarra.glb`: straight forge crossguard, symmetric double-horned anvil pommel crossed by an ember crack, bronze and crimson leather). They share exactly the geometry and UVs of the blade (checked by `tests/test_sword_model.gd`) but each carries its own blade texture, so the realm reads from the game camera, where only the blade is visible: ice fuller with a row of white runes (Vardheim), inlaid gold with a diamond-pattern ribbon (Solmarch) or blackened steel with a vivid orange emissive crack (Askarra, emission 3.5).
- **Textures in code.** `tools/blender/sword_textures.py` (numpy, no photos) generates each realm's blade, the leather with the shadow between wraps painted in, and a three-band metal atlas (main metal, accent and polished edge); each with its own metallic and roughness texture (G and B of a single image, as glTF requires). The bevel faces created by `slab()` in `build_sword.py` are mapped to the polished-edge band, which is the same metal in a lighter, smoother version: this way every piece of the crossguard and pommel has light on its edges. The GLBs carry them inside and their `.import` leaves them embedded (`gltf/embedded_image_handling=3`) so as not to fill the repo with loose PNGs.
- **Weapon convention.** Origin at the center of the grip, blade along +Y, width along X, flat faces toward ±Z, 1 unit = 1 m. Two meshes, `Sword_LOD0` (about 2,900 triangles) and `Sword_LOD1` (about 750), and two markers, `TrailBase` and `TrailTip`, for the swing trail. The leather wraps and the fuller are in the LOD0 geometry.
- **Metal.** Under Vado Gris's gray sky a pure metal (metallic 1) reflects a flat gray and the shape is lost, so the blade uses metallic 0.6 and the contrast is painted by the albedo. **The contrast comes from a dark albedo, not a light one:** a blade of light steel from top to bottom blends into the gray sky (the first version got lost in the game camera and read worse than the box). The flat faces and the major bevel use a cold steel gray of 0.46 to 0.48, the fuller 0.20, and only the edge is a thin, light band (0.92 to 1.0, the last 14% of the half width), with a gradient along its length (darker near the guard, lighter toward the tip) and polish streaks of amplitude 0.012. The base colors of the hilt metal are also low (steel 0.50, bronze 0.62/0.32/0.11, gold 0.92/0.62/0.16 with metallic 0.94): the shine comes from the edges and the reflection, not the color. This is a style decision, not an oversight.
- **Heroic proportions.** The blade is about 10.8 cm wide and 3 cm thick at the spine (a real sword would be 8.9 and 1.4) for 0.94 m from the grip to the tip; the length is not touched because the swing's reach comes from the combat data (decision 8 of calidad.md). The central block of the crossguard is wider than the blade to cover the ricasso. The grip rotates 18° about the blade axis inside the hand (`WeaponProps.SWORD_ROLL_DEG`) so that at rest and from behind some of the flat face is visible instead of a thread.
- **In the game.** `scripts/client/sword_model.gd` (`SwordModel`) loads and distributes the LODs with the visibility ranges; `WeaponProps` hangs the model from the hand (`SWORD_GRIP_ROTATION_DEG` and `SWORD_GRIP_OFFSET` are the grip) and keeps the box if the GLB fails to load. `AppearanceApplier.apply_bytes` sets the sword of the player's realm (`HumanoidVisual.set_realm` and `WeaponProps.set_sword_variant`), on remote players too.
- **Swing trail.** `scripts/client/sword_trail.gd` (`SwordTrail`) is a ribbon hanging from the sword node between `TrailBase` and `TrailTip`, additively blended and with no lighting or shadow, tinted per realm and fading out in 0.13 s, with its outer edge extended 0.62 m beyond the tip to draw the real reach of the swing (about 2.2 m from the axis, decision 8) without touching the combat data. It is triggered by `CombatAnimationLayer.is_swing_active()`, which is the same check as `swing_active_changed` on the local player (`ActionMachine.is_attack_active`) and the active phase of the action byte on remote players; the animator signals it with `swing_active_changed` and `HumanoidVisual` carries it to the sword. `scenes/tests/sword_preview.tscn` takes the model's photos with the Vado Gris light and `tools/render/sword_hero_shots.gd` captures the hero at rest, striking and blocking.

---

## 5. What I do NOT recommend and why

- **Mixing families.** KayKit characters with Quaternius environment, or the other way around, clashes in proportions (chibi versus heroic), in textures (gradient atlas versus textures) and in skeleton. KayKit only comes in as a source of retargeted animation clips.
- **KayKit as the whole family.** It is very well done, but has no human-scale castle or village. The Medieval Hexagon is a tabletop miniature, useful at most for a strategic map. And the chibi tone drifts away from New World. It is plan B only if Quaternius animation turned out to be unworkable, and everything would have to change at once.
- **Kenney Castle Kit, Fantasy Town Kit and Nature Kit as final art.** They are flat colors with a toy look. The Nature Kit also uses many materials with no atlas. They are only good for blockout.
- **Old copies:** UAL on OpenGameArt or the Godot Asset Store (before v2.0), KayKit "(Legacy) Character Animations" and the KayKit v1.0 releases on GitHub and AssetLib.
- **Old Quaternius packs:** the RPG Character Pack (2020) has an old, incompatible rig. The LowPoly Medieval Weapons have flat colors, include no glTF, and the page gives 22 or 24 models depending on where you look.
- **Kenney Mini Characters and Animated Characters:** 7-joint rig and blocky style.
- **Mixamo, except as a last resort.** It is not CC0, requires an Adobe ID and forbids distributing the original FBX files. The official FAQ could not be read (it returned 403). If used, only with the repo private and without publishing the original files.
- **Sonniss GDC Bundle:** it forbids redistributing it "as sound effects" and forbids training AI on it (delicate with AI agents in the workflow), and takes up tens of GB. **Leohpaz RPG Essentials:** it is not CC0 and forbids redistributing the pack.
- **GDQuest godot-4-VFX-assets:** the art is CC-BY-NC-SA, that is, non-commercial. **REEBOO VFX** is MIT and legal, but it is a new repo made with AI help: only as a reference, with an MIT notice if anything is copied.
- **Spatial Gardener:** it breaks on Godot 4.5+ (issue #75, with the fix not merged). **HTerrain** only as an alternative. **TerraBrush** is in beta and **MTerrain** in alpha.
- **Simple Grass Textured:** it overlaps with the Terrain3D instancer, stores the MultiMesh and the height image inside the `.tscn` (huge text scenes) and has an open hang on 4.7.
- **Poly Haven and ambientCG as the main style:** they are photorealistic. Only for gaps (snow, sand) and processed.
- **Packs discarded by the research:** EmaceArt (contradictory license), Avraman (files withdrawn over license), Cenji (paid and not CC0; unverified), Gobkit (AI provenance), poly.pizza (mixed styles), Ultimate Fantasy RTS (RTS scale and no textures) and Explosive LLC RPG Animations (unstable version 0.1.0).

Sources for the new check: [UAL1 on itch](https://quaternius.itch.io/universal-animation-library), [Bestiary on itch](https://quaternius.itch.io/bestiary-dungeon-monsters-kit) and [Bestiary on quaternius.com](https://quaternius.com/packs/bestiarydungeonmonsterskit.html). The rest of the data comes from the verified research I received.
