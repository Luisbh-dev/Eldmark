# Asset and addon licenses

Register of all third-party content in the repository. Every pack that comes in is recorded here
(see `CLAUDE.md` and `docs/art.md`, section 5). The original zips are not versioned: they are
kept outside the repo, in `../Eldmark-raw/<pack>/`, and only the glTF/GLB files and the textures
that are used make it into the repo (textures larger than 2048 px are downscaled before they come
in).

Summary: all the art is **CC0 1.0** (public domain) and the two addons are **MIT**. The MIT
requires keeping the copyright notice and the license: they live inside each addon's folder and
must accompany the exported game. No asset requires attribution; the courtesy credits that the
authors ask for are in the last section.

## Addons (code)

### Terrain3D

| Field | Value |
|---|---|
| Author | Cory Petkovsek and Roope Palmroos (TokisanGames) and contributors |
| Version / file | 1.0.2 (`plugin.cfg`, `Terrain3D.version` = "1.0.2"). `Terrain3D_v1.0.2-stable.zip`, sha256 `a071850250ec5e596aa54da61c01d75768774eb379ee997584d426a45f4884a2` |
| URL | https://github.com/TokisanGames/Terrain3D/releases/download/v1.0.2-stable/Terrain3D_v1.0.2-stable.zip |
| License | MIT, "Copyright (c) 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors" |
| Where it is stated | `addons/terrain_3d/LICENSE.txt` |
| Folder in the repo | `addons/terrain_3d/` (without the Android, iOS and web binaries) |
| Credits | Mandatory to keep `LICENSE.txt` with the copyright notice |

### ProtonScatter

| Field | Value |
|---|---|
| Author | HungryProton |
| Version / file | 4.2.0 (`plugin.cfg`), main branch, commit `7198cc00078ebde61307578137c3f35223c6e438`. `scatter-7198cc00078ebde61307578137c3f35223c6e438.zip`, sha256 `485295fa4a97cb54bcd20d1b1304ed8a2fc0b28fe3215a07be62d26df9208d5f` |
| URL | https://github.com/HungryProton/scatter (archive of that commit) |
| License | MIT, "Copyright (c) 2019 HungryProton" |
| Where it is stated | `addons/proton_scatter/LICENSE` |
| Folder in the repo | `addons/proton_scatter/`, without `demos/` (Textures.com textures, which cannot be redistributed) or `tests/` |
| Credits | Mandatory to keep `LICENSE` with the copyright notice |
| Note | Installed and enabled, but Vado Gris does not use it (the vegetation comes from a deterministic script). The presets `presets/grass.tscn` and `presets/scatter_default.tscn` point to `demos/`, which is not there. |

## Characters and animations

All four packs are by Quaternius, Standard (free) version. The zips carry no version number; the
date of the file used inside the zip is recorded.

### Universal Animation Library (UAL1), Standard

| Field | Value |
|---|---|
| Author | Quaternius |
| Version / file | `Universal Animation Library[Standard].zip` (sha256 `cc73fc4e495b82958207316596317a3f40b9fa38065bde1027937452da537724`). File used: `Unreal-Godot/UAL1_Standard.glb` (variant without root motion), dated 17/06/2026 00:03 in the zip; matches v3.0 |
| URL | https://quaternius.itch.io/universal-animation-library |
| License | CC0 1.0 Universal |
| Where it is stated | `License.txt` and `README.txt` inside the zip; "Asset license" row on itch |
| Folder in the repo | `assets/animations/ual1/` (and `assets/animations/rig/ual_humanoid_bone_map.tres`, own work) |
| Credits | Not mandatory (courtesy: Quaternius) |

### Universal Animation Library 2 (UAL2), Standard

| Field | Value |
|---|---|
| Author | Quaternius |
| Version / file | `Universal Animation Library 2[Standard].zip` (sha256 `4008ea208a604773a2b2177d965f0f5d3195498b5bf838c3f5785d68e95f2a68`). File used: `Unreal-Godot/UAL2_Standard.glb` (without root motion), dated 17/06/2026 00:12 in the zip. `docs/art.md` expected v2.2 (28/9/2026); with that date the version cannot be confirmed |
| URL | https://quaternius.itch.io/universal-animation-library-2 |
| License | CC0 1.0 Universal |
| Where it is stated | `License.txt` inside the zip; itch description |
| Folder in the repo | `assets/animations/ual2/` |
| Credits | Not mandatory (courtesy: Quaternius) |

### Universal Base Characters, Standard

| Field | Value |
|---|---|
| Author | Quaternius |
| Version / file | `Universal Base Characters[Standard].zip` (sha256 `fdbf1804c90dfc1ea03e992bff7da2dfd1a79318e13270a660180f9308455f40`). Files used: `Base Characters/Godot - UE/Superhero_Male_FullBody.gltf` (14/11/2025), **modified**: only the head and neck are kept (`tools/assets/split_head.py`) and broken texture references are fixed, saved as `Superhero_Male_Head.gltf`; `Hair_SimpleParted` and `Hair_Beard` from the glTF folder "Rigged to Head Bone"; textures `T_Superhero_Male_*` (downscaled to 1024 px: they only cover head and neck), `T_Eye_*` and `T_Hair_1_*` |
| URL | https://quaternius.itch.io/universal-base-characters |
| License | CC0 1.0 Universal |
| Where it is stated | `License_Standard.txt` inside the zip; "Asset license" row on itch |
| Folder in the repo | `assets/models/characters/base/` (the materials in `materials/` are own work) |
| Credits | Not mandatory (courtesy: Quaternius) |

### Modular Character Outfits - Fantasy, Standard

| Field | Value |
|---|---|
| Author | Quaternius |
| Version / file | `Modular Character Outfits - Fantasy[Standard].zip` (sha256 `c3468b18871cc8c8f05ab14df7712baf22cb9f389cbd870babf130e595187f70`). Files used: `Exports/glTF (Godot-Unreal)/Outfits/Male_Ranger.gltf` and `.bin` (29/01/2026), textures `T_Ranger_*` (downscaled from 4096 to 2048 px) and `T_Regular_Male_*` (hand skin, downscaled to 1024 px). **Version unconfirmed:** the newest file in the zip is dated 29/01/2026 and `docs/art.md` asks for v2.1 (5/7/2026) or later; it has to be downloaded again from itch to confirm it. **Modified:** in `Male_Ranger.bin`, the 118 triangles of the back of the neck of `Male_Ranger_Body` that poked out at the nape of the Superhero head are nullified (degenerate triangles) (`tools/assets/fix_ranger_collar.py`); the `.gltf` does not change |
| URL | https://quaternius.itch.io/modular-character-outfits-fantasy |
| License | CC0 1.0 Universal |
| Where it is stated | `License_Standard.txt` inside the zip; "Asset license" row on itch |
| Folder in the repo | `assets/models/characters/outfits/ranger/` (the materials in `materials/` are own work) |
| Credits | Not mandatory (courtesy: Quaternius) |

## Environment

### Medieval Village MegaKit, Standard

| Field | Value |
|---|---|
| Author | Quaternius |
| Version / file | `Medieval Village MegaKit[Standard].zip`, sha256 `e60dea67c10f30dccccfbff92a7933f5ea5cfe99be0e2a0fa5118cceabeec5c4`. 12 glTF pieces (walls, floors, bricks, chimney, crate, cart, fence, tower roof) and their textures, downscaled to 1024 px at most |
| URL | https://quaternius.itch.io/medieval-village-megakit |
| License | CC0 1.0 Universal |
| Where it is stated | `License_Standard.txt` inside the zip |
| Folder in the repo | `assets/models/environment/village/` (`meshes/*.tres` are meshes extracted from those glTFs) |
| Credits | Not mandatory (courtesy: Quaternius) |

### Stylized Nature MegaKit, Standard

| Field | Value |
|---|---|
| Author | Quaternius |
| Version / file | `Stylized Nature MegaKit[Standard].zip`, sha256 `298f6732b872e4cf7b30e6e7abf9641c7f6dc6b326df37ac089533ed7e3d58c9`. 31 glTF models (5 pines, 5 deciduous trees, 5 dead trees, 2 twisted ones, 3 rocks, 3 grasses, a shrub, a fern, a large plant, 2 pebbles, a mushroom and 2 path slabs) and their textures, downscaled to 1024 px at most; `flowers.png` (1008 x 981 in the pack) brought to 1024 x 1024. The first 16 models came in with the zone; the other 15 (tree variants, twisted ones and undergrowth) on November 3, 2026 (ART-59) |
| URL | https://quaternius.itch.io/stylized-nature-megakit |
| License | CC0 1.0 Universal |
| Where it is stated | `License_Standard.txt` inside the zip |
| Folder in the repo | `assets/models/environment/nature/` |
| Credits | Not mandatory (courtesy: Quaternius) |
| Modifications | The glTFs are not touched. The bark of the trees (terracotta in the pack) and the leaves of the twisted ones (red) are replaced on import with own materials that recolor the same texture (`assets/materials/vegetation/bark_*.tres`, `leaves_twisted.tres`, `leaves_green.tres`; generated by `tools/materials/build_realm_materials.gd` and applied by `tools/assets/apply_nature_materials.gd`) |

### Castle Wall Kit

| Field | Value |
|---|---|
| Author | loafbrr |
| Version / file | `CastleWallKit_blend_fbx_gltf_textures.zip`, sha256 `815a4dc16f3b650c7c6fa1dc9e72612d2c47d86f7e5e63220246643235bd0376`. Used: `castle_walls_kit.gltf` (buffer embedded in base64) and its textures |
| URL | https://loafbrr.itch.io/castle-wall-kit |
| License | CC0 1.0, according to the license field of the itch page (recorded in `docs/art.md`) |
| Where it is stated | On itch. The zip's `README.txt` does not name CC0: it says it can be used in any project, personal or commercial, without asking permission, and that attribution is not mandatory. **Pending:** save a copy of the itch page with the license field |
| Folder in the repo | `assets/models/environment/castle_wall/` (`meshes/*.tres` extracted from the glTF) |
| Credits | Not mandatory; the author appreciates attribution (courtesy: loafbrr) |

### Castle Kit 2.0 (blockout only)

| Field | Value |
|---|---|
| Author | Kenney (www.kenney.nl) |
| Version / file | Castle Kit 2.0 (created on 27/03/2024). `kenney_castle-kit.zip`, sha256 `921f3f73927bb23106cae34bc21d5ab4b033a9fc120475e96f714a406e3169df`. Used: `flag_banner_long.glb`, `tree_log.glb` and the `colormap` texture |
| URL | https://kenney.nl/assets/castle-kit |
| License | CC0 1.0 Universal |
| Where it is stated | `License.txt` inside the zip |
| Folder in the repo | `assets/models/blockout/kenney_castle/` |
| Credits | Not mandatory (courtesy: "Kenney" or "www.kenney.nl") |
| Note | Blockout only (provisional banners); never final art |

### Hand-Painted Watercolor Terrain Texture Pack (1024 px)

| Field | Value |
|---|---|
| Author | Jonas Voland; distributed by Voxel Core Lab GmbH |
| Version / file | `VoxelCoreLab_Watercolor_Terrain_Textures_1024px.zip`, sha256 `28d1aa7c2a206408462e94b55e431ef1fc8a6f70b41cb6eaadff2672d55d8519`. 7 grass, dirt and stone textures, **modified**: the height (normalized luminance) goes in the alpha channel (`*_alb_ht.png`), and `dirt_03` is also recolored (hue +9°, saturation ×0.6, value ×1.35, in `tools/assets/copy_vado_gris_assets.gd`). `flat_normal_rough_256.png` is own work |
| URL | https://voxelcorelab.itch.io/watercolor-terrain-textures |
| License | CC0 1.0 Universal |
| Where it is stated | `LICENCE.txt` inside the zip |
| Folder in the repo | `assets/textures/terrain/watercolor/` |
| Credits | Not mandatory; if credited, the author asks for "Jonas Voland" |

### Poly Haven terrain textures (ART-55)

| Field | Value |
|---|---|
| Authors | Dimitrios Savva (`damp_beach_sand`, and photography of `rock_boulder_dry`), eye-candy.xyz (`dirt_floor`), Charlotte Baglioni (`forest_ground_06`, `grass_ground`), Rob Tuytel (`ground_grey`, `snow_02`), Rico Cilliers (processing of `rock_boulder_dry`), Amal Kumar (`rocky_trail`) |
| Version / file | All eight at 2K, downloaded on November 3, 2026 to `../Eldmark-raw/texturas_polyhaven_2k/` (md5 checked against the Poly Haven API; see its `FUENTE.txt`). **Modified**: rescaled to 1024 px, desaturated, with the contrast compressed and part of the ambient occlusion baked into the color; the height goes in the albedo alpha (`*_alb_ht.png`) and the roughness in the alpha of the OpenGL normal (`*_nrm_rough.png`). Script: `tools/assets/process_terrain_textures.py` |
| URL | https://polyhaven.com/textures (each one at https://polyhaven.com/a/<id>) |
| License | CC0 1.0 (public domain), https://polyhaven.com/license |
| Where it is stated | Poly Haven license page (the files carry no license of their own) |
| Folder in the repo | `assets/textures/terrain/polyhaven/` |
| Credits | Not mandatory (courtesy: "Poly Haven") |
| Note | They replace the watercolor ones and the flat normal on the Vado Gris terrain; the watercolor ones remain in the repo in case another zone uses them |

### Sky3D 2.1.0: discarded (ART-54)

The Vado Gris sky is own work (`assets/materials/shaders/storm_sky.gdshader`, a sky shader with
procedural clouds): Sky3D (TokisanGames, MIT) brings a full day and night cycle that is not needed
here, drags in the moon of doubtful provenance (MoonMap.png) and the stars from ESO/S. Brunier
(CC BY 4.0, which would require crediting them), and its cycle would have to be kept switched off on
the server. Nothing from Sky3D has been copied into the repo, so there is nothing to credit for it.
If the day and night cycle is ever wanted (pending decision in the backlog), it will have to be
reassessed and ESO credited then.

### Kenney Impact Sounds (only the grass and wood footsteps)

| Field | Value |
|---|---|
| Author | Kenney Vleugels (www.kenney.nl) |
| Version / file | Impact Sounds 1.0 (19-12-2019), `kenney_impact-sounds.zip`, sha256 `029d734af1582474edf3a694d1b0cebc97c1c152f2f39fa34d4c2bafc5de77f8`, downloaded on November 3, 2026. Used, unmodified (only renamed): `footstep_grass_000` to `004` as `assets/audio/sfx/step_grass/step_grass_01` to `05.ogg` and `footstep_wood_000` to `004` as `assets/audio/sfx/step_wood/step_wood_01` to `05.ogg` |
| URL | https://kenney.nl/assets/impact-sounds |
| License | CC0 1.0 Universal |
| Where it is stated | `License.txt` inside the zip |
| Folder in the repo | `assets/audio/sfx/step_grass/` and `assets/audio/sfx/step_wood/` |
| Credits | Not mandatory (courtesy: "Kenney" or "www.kenney.nl") |
| Note | The remaining footsteps and all the combat sounds are in-house productions (see below). The other audio packs downloaded (Kenney RPG Audio, Still North Weapon Impacts, rubberduck 80 CC0 RPG SFX) are only used in the listening sheet `build/o4_hoja_escucha/` (`tools/audio/listening_sheet.py`), which is not versioned; if the user picks any of their alternatives, it is then copied into the repo and recorded here. |

## UI fonts (UI-02)

Three Google Fonts families, all under the SIL Open Font License 1.1 (the OFL requires keeping the
copyright notice and the license inside the exported game: the `OFL-*.txt` files sit next to the
font files). Origin: repository https://github.com/google/fonts (folders `ofl/cinzel`, `ofl/notosans`
and `ofl/imfellenglishsc`, main branch, downloaded on 2026-11-03 to `../Eldmark-raw/fuentes_google_fonts/`).
They were renamed when copied (no brackets in the name); they were not modified.

| Use | Family and copyright | File in the repo | Source file |
|---|---|---|---|
| Body text, numbers and nameplates | Noto Sans, (c) 2022 The Noto Project Authors (https://github.com/notofonts/latin-greek-cyrillic) | `assets/fonts/NotoSans-Variable.ttf`, license `OFL-NotoSans.txt` | `NotoSans[wdth,wght].ttf` (variable) |
| Titles, boss names, notices and tabs | Cinzel, (c) 2020 The Cinzel Project Authors (https://github.com/NDISCOVER/Cinzel) | `assets/fonts/Cinzel-Variable.ttf`, license `OFL-Cinzel.txt` | `Cinzel[wght].ttf` (variable) |
| Map place labels | IM Fell English SC, (c) 2010 Igino Marini (mail@iginomarini.com) | `assets/fonts/IMFellEnglishSC-Regular.ttf`, license `OFL-IMFellEnglishSC.txt` | `IMFeENsc28P.ttf` |

`UIThemeBuilder` wires them into the theme (`assets/ui/theme/eldmark_theme.tres`, regenerated with
`godot --headless --path . -s res://tools/ui/build_theme.gd`) and `UIFonts` hands them to the code that draws
text by hand. The two large ones are variable fonts: semibold and bold come from the `wght` axis.

## Own content (not third-party)

Made for Eldmark from the packs above or from scratch. It belongs to the project, which does not
yet declare a license of its own:

- Shaders `assets/materials/shaders/` (`realm_surface`, `water`, and the `fort_keep_*` ones for the keep) and materials in
  `assets/materials/{realms,vegetation,water}/`.
- `assets/environments/vado_gris_frontier.tres` (environment).
- `assets/models/environment/custom/` (script-generated meshes: the stone bridge, with
  Castle Wall Kit textures, the fort gate leaf, the campfire stones and logs and the rubble) and the pieces in
  `scenes/world/props/` (palisade, tents...).
- Character materials `assets/models/characters/**/materials/*.tres` and
  `assets/animations/rig/ual_humanoid_bone_map.tres`.
- Terrain data `scenes/world/zones/vado_gris/terrain/*.res`, generated by
  `tools/terrain/generate_vado_gris.gd`.
- UI theme `assets/ui/theme/eldmark_theme.tres` (generated by `tools/ui/build_theme.gd` from
  `UIPalette`).
- Hit effects (ART-09) `scenes/vfx/`: scenes (`hit_metal_spark`, `hit_flesh`, `hit_cloth`,
  `hit_block_wood`, `parry_flash`, `dust_kick`, `weapon_trail`, `charge_aura` and `shield_wall`), shaders
  `scenes/vfx/shaders/*.gdshader` (handwritten for Eldmark: light shapes, blood jets, dust with
  light and shadow, trail, blade shine and heat distortion), materials `scenes/vfx/materials/*.tres` and
  textures `scenes/vfx/textures/*.png`. There is nothing third-party: the textures are generated with
  `tools/vfx/make_vfx_textures.py` (numpy and PIL, fixed seeds, 12 PNGs: point flash, rays, spark
  with tail, glow, noise, puffs with relief, splash jets in sequence, shards,
  wood splinters, shreds, drops and dust ring) and the scenes and materials with
  `tools/vfx/build_vfx_scenes.gd` (the numbers for each effect are there). The scripts that drive them are in
  `scripts/client/vfx/` and the preview scene is `scenes/tests/vfx_preview.tscn`
  (`tools/vfx/render_strips.ps1` records the frame strips, the shadow test, the measurement of a
  melee and the video in `build/vfx/`; see `tools/vfx/README.md`). Order to regenerate everything:
  `python tools/vfx/make_vfx_textures.py`, `godot --headless --path . --import`,
  `godot --headless --path . -s res://tools/vfx/build_vfx_scenes.gd` and `--import` again.

- Sounds `assets/audio/sfx/<category>/*.ogg` and `assets/audio/sfx/niveles.json` (ART-11): 89 effects
  synthesized from scratch, with no third-party samples or recordings: sword swishes (6 light, 3
  heavy), sword hits on flesh, leather, gambeson and mail, wooden shield and block with steel,
  steel-on-steel parry, footsteps on dirt and on stone (8 each), a body falling (3), dodge,
  bow and arrows (draw, release, impact on flesh and on wood), Hollow voices (wounds and death),
  potion, UI click and confirmation, and horns for a fort won and lost with one timbre per realm.
  They are generated by `tools/audio/synth_sfx.py` with `sfx_dsp.py`, `sfx_combat.py` and `sfx_world.py` (synthesis with
  numpy, encoding with ffmpeg and libvorbis; output identical byte for byte on every run) and measured
  against the quality bar and drawn by `tools/audio/analyze_sfx.py` (spectrograms, sheets and comparisons
  in `build/audio/`, not versioned). `niveles.json` carries the loudness of each file, the volume trim
  per group, the peak instant (`pico_s`) to synchronize the swishes with `data/combat` and the recommended
  randomizer. Since quality wave 4, `CombatAudio` (`scripts/client/audio/combat_audio.gd`) connects them with the banks
  of `CombatSoundBank`; the dirt and stone footsteps are joined by the Kenney grass and wood ones (above).

- Fort keep (ART-57), version 2, modeled and painted from scratch with code, without photos, AI or
  third-party textures: `assets/models/environment/custom/fort_keep.glb` (three levels of detail, the node
  `Estandarte` and the low-resolution collision in a single glTF, with vertex color and no embedded
  images), its own textures in `assets/models/environment/custom/fort_keep/textures/` (stone,
  carved stone, cloth of dressed ashlar, wood, roof shingles and the banner atlases, the latter
  with the emblems from `assets/emblems/` rasterized), the shaders
  `assets/materials/shaders/fort_keep_surface.gdshader` and `fort_keep_cloth.gdshader` and their realm materials
  (Eldrun, Vardheim, Solmarch and Askarra) in `assets/models/environment/custom/fort_keep/materials/`.
  They are regenerated with `bash tools/blender/regenerate_fort_keep.sh`, which chains
  `tools/blender/make_fort_keep_textures.py` (numpy and Pillow: color washes, brush strokes, cracks and
  shingles by code), `tools/blender/build_fort_keep.py` (Blender 5.2.3 with `bpy`, no UI; the
  header documents the geometry, the vertex color and the GLB import settings that are not
  the defaults), `tools/assets/apply_texture_import_presets.gd` and
  `tools/materials/build_fort_keep_materials.gd`. The review tools are
  `tools/render/render_fort_keep_*.gd` and `tools/blender/compose_fort_keep_comparison.py`; the preview
  scene is `scenes/tests/fort_keep_preview.tscn` (with `scripts/client/tools/fort_keep_preview.gd`).

- Weapon sword `assets/models/weapons/` (`sword_base.glb` and the per-realm variants
  `sword_vardheim.glb`, `sword_solmarch.glb` and `sword_askarra.glb`): modeled from scratch with Blender
  5.2 without UI by `tools/blender/build_sword.py`, with the textures (each realm's blade with its
  groove of runes, gold or emissive crack, the leather and a metal atlas with a polished edge, all
  noise and gradients) generated by code in `tools/blender/sword_textures.py`. No mesh or
  texture comes from a pack: the RPG Weapons Free swords were only looked at to compare quality.
  The hit trail (`scripts/client/sword_trail.gd`) is a custom ribbon with a gradient texture generated by code at startup.
  To regenerate them: `blender --background --factory-startup --python tools/blender/build_sword.py`
  and `godot --headless --path . --import`. The GLBs carry the textures inside (the `.import` keeps
  them embedded, `gltf/embedded_image_handling=3`).
- Faction emblems `assets/emblems/*.svg` (wolf, split sun, anvil and broken crown):
  **provisional**, geometric shapes made for Eldmark with `tools/assets/make_emblems.py`; the final
  art of ART-03 will replace them with the same file names.
- Vado Gris parchment map `assets/maps/vado_gris.png` and its scale and fixed places in
  `assets/maps/vado_gris_map.tres` (UI-51): own content, 2048 px over ±200 m (the playable valley
  takes up three quarters of the image). Painted in layers on the CPU (desaturated grayish-brown paper, wash,
  pen-style relief with ramps folded with noise, river, roads joined before inking, walls, towers
  and gates in oblique perspective, fort enlarged 1.5 times with palisade, towers and keep, camps
  in their realm's color, ruins and chapel enlarged, groves as masses with a common outline, ink
  mountain ranges that fade with distance from the valley, cartouches with the compass rose and the scale) from
  the real zone data, with no third-party images. It is generated by `tools/map/bake_parchment_map.gd` with
  `ParchmentMapBaker` and `ParchmentCanvas` (`tools/map/`); to regenerate it:
  `godot --headless --path . -s res://tools/map/bake_parchment_map.gd` and then
  `godot --headless --path . --import`. It is deterministic: same scene, same map. The header of
  `tools/map/bake_parchment_map.gd` notes what to change to enable it in the game (today it is not connected).

- UI icons `assets/ui/icons/` (ART-12): 33 shapes of 128 px with no background
  (`assets/ui/icons/<name>.png`: light and heavy attack, quick and drawn shot, block, dodge,
  the six sword-and-shield and bow abilities, the two potions, weapon swap, the
  weapon icons (sword and shield, bow), interact, bleeding, regeneration, stun, slow,
  push, knocked down, rooted, fort, gate, camp and banners), the small variants of
  the seven states at their native size of 14 and 26 px (`small/<state>_14.png`, `_26.png`) and seven
  per-category backgrounds in blood and without a frame (`backgrounds/<category>.png`). Made entirely by code,
  with nothing third-party and no AI generation. Tools: Python with numpy and PIL, and the
  engine's own rasterizer (ThorVG). `tools/ui/icons/svgkit.py` (geometry, materials and layers),
  `glyphs.py` (the drawings), `paint.py` (grain, occlusion between pieces, rim light and backgrounds),
  `make_icons.py` (orchestrator) and `rasterize_icons.gd`; `build_icons.sh` regenerates everything. Measurements
  and sample sheets: `qa.py`, `make_sheets.py` and `engine_test.gd` (output in `build/iconos/`).

## Courtesy credits

None is mandatory, but the authors appreciate it. For the credits screen:

- Models and animations: **Quaternius** (quaternius.com).
- Walls: **loafbrr**.
- Blockout pieces: **Kenney** (www.kenney.nl).
- Terrain textures: **Jonas Voland** and **Poly Haven** (Dimitrios Savva, eye-candy.xyz, Charlotte Baglioni, Rob Tuytel, Rico Cilliers, Amal Kumar).
- Terrain: **Terrain3D**, by Cory Petkovsek, Roope Palmroos and contributors (MIT).
- Scattering: **ProtonScatter**, by HungryProton (MIT).
