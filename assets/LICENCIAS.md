# Licencias de assets y addons

Registro de todo el contenido de terceros que hay en el repositorio. Cada pack que entra se anota
aquí (ver `CLAUDE.md` y `docs/arte.md`, sección 5). Los zips originales no se versionan: se
guardan fuera del repo, en `../Eldmark-raw/<pack>/`, y al repo solo pasan los glTF/GLB y las
texturas que se usan (las texturas de más de 2048 px se reducen antes de entrar).

Resumen: todo el arte es **CC0 1.0** (dominio público) y los dos addons son **MIT**. El MIT pide
conservar el aviso de copyright y la licencia: van dentro de cada carpeta del addon y deben
acompañar al juego exportado. Ningún asset exige atribución; los créditos de cortesía que piden
los autores están en la última sección.

## Addons (código)

### Terrain3D

| Campo | Valor |
|---|---|
| Autor | Cory Petkovsek y Roope Palmroos (TokisanGames) y colaboradores |
| Versión / archivo | 1.0.2 (`plugin.cfg`, `Terrain3D.version` = "1.0.2"). `Terrain3D_v1.0.2-stable.zip`, sha256 `a071850250ec5e596aa54da61c01d75768774eb379ee997584d426a45f4884a2` |
| URL | https://github.com/TokisanGames/Terrain3D/releases/download/v1.0.2-stable/Terrain3D_v1.0.2-stable.zip |
| Licencia | MIT, "Copyright (c) 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors" |
| Dónde se indica | `addons/terrain_3d/LICENSE.txt` |
| Carpeta en el repo | `addons/terrain_3d/` (sin los binarios de Android, iOS y web) |
| Créditos | Obligatorio conservar `LICENSE.txt` con el aviso de copyright |

### ProtonScatter

| Campo | Valor |
|---|---|
| Autor | HungryProton |
| Versión / archivo | 4.2.0 (`plugin.cfg`), rama main, commit `7198cc00078ebde61307578137c3f35223c6e438`. `scatter-7198cc00078ebde61307578137c3f35223c6e438.zip`, sha256 `485295fa4a97cb54bcd20d1b1304ed8a2fc0b28fe3215a07be62d26df9208d5f` |
| URL | https://github.com/HungryProton/scatter (archivo de ese commit) |
| Licencia | MIT, "Copyright (c) 2019 HungryProton" |
| Dónde se indica | `addons/proton_scatter/LICENSE` |
| Carpeta en el repo | `addons/proton_scatter/`, sin `demos/` (texturas de Textures.com, que no se pueden redistribuir) ni `tests/` |
| Créditos | Obligatorio conservar `LICENSE` con el aviso de copyright |
| Nota | Instalado y activado, pero el Vado Gris no lo usa (la vegetación sale de un script determinista). Los presets `presets/grass.tscn` y `presets/scatter_default.tscn` apuntan a `demos/`, que no está. |

## Personajes y animaciones

Los cuatro packs son de Quaternius, versión Standard (gratuita). Los zips no traen número de
versión; se anota la fecha del archivo usado dentro del zip.

### Universal Animation Library (UAL1), Standard

| Campo | Valor |
|---|---|
| Autor | Quaternius |
| Versión / archivo | `Universal Animation Library[Standard].zip` (sha256 `cc73fc4e495b82958207316596317a3f40b9fa38065bde1027937452da537724`). Archivo usado: `Unreal-Godot/UAL1_Standard.glb` (variante sin root motion), fechado el 17/06/2026 00:03 en el zip; coincide con la v3.0 |
| URL | https://quaternius.itch.io/universal-animation-library |
| Licencia | CC0 1.0 Universal |
| Dónde se indica | `License.txt` y `README.txt` dentro del zip; fila "Asset license" de itch |
| Carpeta en el repo | `assets/animations/ual1/` (y `assets/animations/rig/ual_humanoid_bone_map.tres`, propio) |
| Créditos | No obligatorios (cortesía: Quaternius) |

### Universal Animation Library 2 (UAL2), Standard

| Campo | Valor |
|---|---|
| Autor | Quaternius |
| Versión / archivo | `Universal Animation Library 2[Standard].zip` (sha256 `4008ea208a604773a2b2177d965f0f5d3195498b5bf838c3f5785d68e95f2a68`). Archivo usado: `Unreal-Godot/UAL2_Standard.glb` (sin root motion), fechado el 17/06/2026 00:12 en el zip. `docs/arte.md` esperaba la v2.2 (28/9/2026); con esa fecha no se puede confirmar la versión |
| URL | https://quaternius.itch.io/universal-animation-library-2 |
| Licencia | CC0 1.0 Universal |
| Dónde se indica | `License.txt` dentro del zip; descripción de itch |
| Carpeta en el repo | `assets/animations/ual2/` |
| Créditos | No obligatorios (cortesía: Quaternius) |

### Universal Base Characters, Standard

| Campo | Valor |
|---|---|
| Autor | Quaternius |
| Versión / archivo | `Universal Base Characters[Standard].zip` (sha256 `fdbf1804c90dfc1ea03e992bff7da2dfd1a79318e13270a660180f9308455f40`). Archivos usados: `Base Characters/Godot - UE/Superhero_Male_FullBody.gltf` (14/11/2025), **modificado**: solo se conserva la cabeza y el cuello (`tools/assets/split_head.py`) y se arreglan referencias de textura rotas, guardado como `Superhero_Male_Head.gltf`; `Hair_SimpleParted` y `Hair_Beard` de la carpeta glTF "Rigged to Head Bone"; texturas `T_Superhero_Male_*` (reducidas a 1024 px: solo cubren cabeza y cuello), `T_Eye_*` y `T_Hair_1_*` |
| URL | https://quaternius.itch.io/universal-base-characters |
| Licencia | CC0 1.0 Universal |
| Dónde se indica | `License_Standard.txt` dentro del zip; fila "Asset license" de itch |
| Carpeta en el repo | `assets/models/characters/base/` (los materiales de `materials/` son propios) |
| Créditos | No obligatorios (cortesía: Quaternius) |

### Modular Character Outfits - Fantasy, Standard

| Campo | Valor |
|---|---|
| Autor | Quaternius |
| Versión / archivo | `Modular Character Outfits - Fantasy[Standard].zip` (sha256 `c3468b18871cc8c8f05ab14df7712baf22cb9f389cbd870babf130e595187f70`). Archivos usados: `Exports/glTF (Godot-Unreal)/Outfits/Male_Ranger.gltf` y `.bin` (29/01/2026), texturas `T_Ranger_*` (reducidas de 4096 a 2048 px) y `T_Regular_Male_*` (piel de las manos, reducidas a 1024 px). **Versión sin confirmar:** el archivo más nuevo del zip es del 29/01/2026 y `docs/arte.md` pide la v2.1 (5/7/2026) o posterior; hay que volver a bajarlo de itch para confirmarla. **Modificado:** en `Male_Ranger.bin` se anulan (triángulos degenerados) los 118 triángulos de la parte trasera del cuello de `Male_Ranger_Body` que asomaban por la nuca de la cabeza Superhero (`tools/assets/fix_ranger_collar.py`); el `.gltf` no cambia |
| URL | https://quaternius.itch.io/modular-character-outfits-fantasy |
| Licencia | CC0 1.0 Universal |
| Dónde se indica | `License_Standard.txt` dentro del zip; fila "Asset license" de itch |
| Carpeta en el repo | `assets/models/characters/outfits/ranger/` (los materiales de `materials/` son propios) |
| Créditos | No obligatorios (cortesía: Quaternius) |

## Entorno

### Medieval Village MegaKit, Standard

| Campo | Valor |
|---|---|
| Autor | Quaternius |
| Versión / archivo | `Medieval Village MegaKit[Standard].zip`, sha256 `e60dea67c10f30dccccfbff92a7933f5ea5cfe99be0e2a0fa5118cceabeec5c4`. 12 piezas glTF (muros, suelos, ladrillos, chimenea, caja, carro, valla, tejado de torre) y sus texturas, reducidas a 1024 px como máximo |
| URL | https://quaternius.itch.io/medieval-village-megakit |
| Licencia | CC0 1.0 Universal |
| Dónde se indica | `License_Standard.txt` dentro del zip |
| Carpeta en el repo | `assets/models/environment/village/` (`meshes/*.tres` son mallas extraídas de esos glTF) |
| Créditos | No obligatorios (cortesía: Quaternius) |

### Stylized Nature MegaKit, Standard

| Campo | Valor |
|---|---|
| Autor | Quaternius |
| Versión / archivo | `Stylized Nature MegaKit[Standard].zip`, sha256 `298f6732b872e4cf7b30e6e7abf9641c7f6dc6b326df37ac089533ed7e3d58c9`. 31 modelos glTF (5 pinos, 5 caducifolios, 5 árboles muertos, 2 retorcidos, 3 rocas, 3 hierbas, un arbusto, un helecho, una planta grande, 2 guijarros, una seta y 2 losas de camino) y sus texturas, reducidas a 1024 px como máximo; `flowers.png` (1008 x 981 en el pack) llevada a 1024 x 1024. Los 16 primeros modelos entraron con la zona; los otros 15 (variantes de árbol, retorcidos y sotobosque) el 3 de noviembre de 2026 (ART-59) |
| URL | https://quaternius.itch.io/stylized-nature-megakit |
| Licencia | CC0 1.0 Universal |
| Dónde se indica | `License_Standard.txt` dentro del zip |
| Carpeta en el repo | `assets/models/environment/nature/` |
| Créditos | No obligatorios (cortesía: Quaternius) |
| Modificaciones | Los glTF no se tocan. La corteza de los árboles (terracota en el pack) y las hojas de los retorcidos (rojas) se sustituyen al importar por materiales propios que recolorean la misma textura (`assets/materials/vegetation/bark_*.tres`, `leaves_twisted.tres`, `leaves_green.tres`; los genera `tools/materials/build_realm_materials.gd` y los aplica `tools/assets/apply_nature_materials.gd`) |

### Castle Wall Kit

| Campo | Valor |
|---|---|
| Autor | loafbrr |
| Versión / archivo | `CastleWallKit_blend_fbx_gltf_textures.zip`, sha256 `815a4dc16f3b650c7c6fa1dc9e72612d2c47d86f7e5e63220246643235bd0376`. Usado: `castle_walls_kit.gltf` (buffer embebido en base64) y sus texturas |
| URL | https://loafbrr.itch.io/castle-wall-kit |
| Licencia | CC0 1.0, según el campo de licencia de la página de itch (anotado en `docs/arte.md`) |
| Dónde se indica | En itch. El `README.txt` del zip no nombra la CC0: dice que se puede usar en cualquier proyecto, personal o comercial, sin pedir permiso, y que la atribución no es obligatoria. **Pendiente:** guardar una copia de la página de itch con el campo de licencia |
| Carpeta en el repo | `assets/models/environment/castle_wall/` (`meshes/*.tres` extraídas del glTF) |
| Créditos | No obligatorios; el autor agradece la atribución (cortesía: loafbrr) |

### Castle Kit 2.0 (solo blockout)

| Campo | Valor |
|---|---|
| Autor | Kenney (www.kenney.nl) |
| Versión / archivo | Castle Kit 2.0 (creado el 27/03/2024). `kenney_castle-kit.zip`, sha256 `921f3f73927bb23106cae34bc21d5ab4b033a9fc120475e96f714a406e3169df`. Usados: `flag_banner_long.glb`, `tree_log.glb` y la textura `colormap` |
| URL | https://kenney.nl/assets/castle-kit |
| Licencia | CC0 1.0 Universal |
| Dónde se indica | `License.txt` dentro del zip |
| Carpeta en el repo | `assets/models/blockout/kenney_castle/` |
| Créditos | No obligatorios (cortesía: "Kenney" o "www.kenney.nl") |
| Nota | Solo blockout (estandartes provisionales); nunca arte final |

### Hand-Painted Watercolor Terrain Texture Pack (1024 px)

| Campo | Valor |
|---|---|
| Autor | Jonas Voland; distribuye Voxel Core Lab GmbH |
| Versión / archivo | `VoxelCoreLab_Watercolor_Terrain_Textures_1024px.zip`, sha256 `28d1aa7c2a206408462e94b55e431ef1fc8a6f70b41cb6eaadff2672d55d8519`. 7 texturas de hierba, tierra y piedra, **modificadas**: la altura (luminancia normalizada) va en el canal alfa (`*_alb_ht.png`), y `dirt_03` además va recoloreada (tono +9°, saturación ×0,6, valor ×1,35, en `tools/assets/copy_vado_gris_assets.gd`). `flat_normal_rough_256.png` es propia |
| URL | https://voxelcorelab.itch.io/watercolor-terrain-textures |
| Licencia | CC0 1.0 Universal |
| Dónde se indica | `LICENCE.txt` dentro del zip |
| Carpeta en el repo | `assets/textures/terrain/watercolor/` |
| Créditos | No obligatorios; si se acredita, el autor pide "Jonas Voland" |

### Kenney Impact Sounds (solo los pasos de hierba y de madera)

| Campo | Valor |
|---|---|
| Autor | Kenney Vleugels (www.kenney.nl) |
| Versión / archivo | Impact Sounds 1.0 (19-12-2019), `kenney_impact-sounds.zip`, sha256 `029d734af1582474edf3a694d1b0cebc97c1c152f2f39fa34d4c2bafc5de77f8`, descargado el 3 de noviembre de 2026. Usados, sin modificar (solo renombrados): `footstep_grass_000` a `004` como `assets/audio/sfx/step_grass/step_grass_01` a `05.ogg` y `footstep_wood_000` a `004` como `assets/audio/sfx/step_wood/step_wood_01` a `05.ogg` |
| URL | https://kenney.nl/assets/impact-sounds |
| Licencia | CC0 1.0 Universal |
| Dónde se indica | `License.txt` dentro del zip |
| Carpeta en el repo | `assets/audio/sfx/step_grass/` y `assets/audio/sfx/step_wood/` |
| Créditos | No obligatorios (cortesía: "Kenney" o "www.kenney.nl") |
| Nota | El resto de pasos y todos los sonidos de combate son de producción propia (ver más abajo). Los demás packs de audio descargados (Kenney RPG Audio, Still North Weapon Impacts, rubberduck 80 CC0 RPG SFX) solo se usan en la hoja de escucha `build/o4_hoja_escucha/` (`tools/audio/listening_sheet.py`), que no se versiona; si el usuario elige alguna de sus alternativas, se copia entonces al repo y se anota aquí. |

## Fuentes de la interfaz (UI-02)

Tres familias de Google Fonts, todas bajo la SIL Open Font License 1.1 (la OFL pide conservar el aviso
de copyright y la licencia dentro del juego exportado: los `OFL-*.txt` están junto a los archivos). Origen:
repositorio https://github.com/google/fonts (carpetas `ofl/cinzel`, `ofl/notosans` y `ofl/imfellenglishsc`,
rama main, descargadas el 2026-11-03 a `../Eldmark-raw/fuentes_google_fonts/`). Se renombraron al copiarlas
(sin corchetes en el nombre); no se modificaron.

| Uso | Familia y copyright | Archivo en el repo | Archivo de origen |
|---|---|---|---|
| Cuerpo de texto, números y placas | Noto Sans, (c) 2022 The Noto Project Authors (https://github.com/notofonts/latin-greek-cyrillic) | `assets/fonts/NotoSans-Variable.ttf`, licencia `OFL-NotoSans.txt` | `NotoSans[wdth,wght].ttf` (variable) |
| Títulos, nombres de jefe, avisos y pestañas | Cinzel, (c) 2020 The Cinzel Project Authors (https://github.com/NDISCOVER/Cinzel) | `assets/fonts/Cinzel-Variable.ttf`, licencia `OFL-Cinzel.txt` | `Cinzel[wght].ttf` (variable) |
| Rótulos de lugares del mapa | IM Fell English SC, (c) 2010 Igino Marini (mail@iginomarini.com) | `assets/fonts/IMFellEnglishSC-Regular.ttf`, licencia `OFL-IMFellEnglishSC.txt` | `IMFeENsc28P.ttf` |

`UIThemeBuilder` las cablea en el tema (`assets/ui/theme/eldmark_theme.tres`, se regenera con
`godot --headless --path . -s res://tools/ui/build_theme.gd`) y `UIFonts` se las da al código que dibuja
texto a mano. Las dos grandes son fuentes variables: la seminegrita y la negrita salen del eje `wght`.

## Contenido propio (no es de terceros)

Hecho para Eldmark a partir de los packs anteriores o desde cero. Es del proyecto, que todavía no
declara una licencia propia:

- Shaders `assets/materials/shaders/` (`realm_surface`, `water`, y los del torreón `fort_keep_*`) y materiales de
  `assets/materials/{realms,vegetation,water}/`.
- `assets/environments/vado_gris_frontier.tres` (ambiente).
- `assets/models/environment/custom/` (mallas generadas por script: el puente de piedra, con
  texturas del Castle Wall Kit, la hoja de la puerta del fuerte, las piedras y los troncos de la
  hoguera y los escombros) y las piezas de `scenes/world/props/` (empalizada, tiendas...).
- Materiales de personaje `assets/models/characters/**/materials/*.tres` y
  `assets/animations/rig/ual_humanoid_bone_map.tres`.
- Datos de terreno `scenes/world/zones/vado_gris/terrain/*.res`, generados por
  `tools/terrain/generate_vado_gris.gd`.
- Tema de interfaz `assets/ui/theme/eldmark_theme.tres` (generado por `tools/ui/build_theme.gd` a
  partir de `UIPalette`).
- Efectos de golpe (ART-09) `scenes/vfx/`: escenas (`hit_metal_spark`, `hit_flesh`, `hit_cloth`,
  `hit_block_wood`, `parry_flash`, `dust_kick`, `weapon_trail`, `charge_aura` y `shield_wall`), sombreadores
  `scenes/vfx/shaders/*.gdshader` (escritos a mano para Eldmark: formas de luz, chorros de sangre, polvo con
  luz y sombra, estela, brillo de la hoja y distorsión de calor), materiales `scenes/vfx/materials/*.tres` y
  texturas `scenes/vfx/textures/*.png`. No hay nada de terceros: las texturas se generan con
  `tools/vfx/make_vfx_textures.py` (numpy y PIL, semillas fijas, 12 PNG: destello de puntas, rayos, chispa
  con cola, resplandor, ruido, bocanadas con relieve, chorros de salpicadura en secuencia, esquirlas,
  tablillas de madera, hilachas, gotas y anillo de polvo) y las escenas y materiales con
  `tools/vfx/build_vfx_scenes.gd` (los números de cada efecto están ahí). Los scripts que los mueven están en
  `scripts/client/vfx/` y la escena de vista previa es `scenes/tests/vfx_preview.tscn`
  (`tools/vfx/render_strips.ps1` graba las tiras de fotogramas, la prueba a la sombra, la medición de una
  refriega y el vídeo en `build/vfx/`; ver `tools/vfx/README.md`). Orden para regenerarlo todo:
  `python tools/vfx/make_vfx_textures.py`, `godot --headless --path . --import`,
  `godot --headless --path . -s res://tools/vfx/build_vfx_scenes.gd` y otra vez `--import`.

- Sonidos `assets/audio/sfx/<categoría>/*.ogg` y `assets/audio/sfx/niveles.json` (ART-11): 89 efectos
  sintetizados desde cero, sin muestras de terceros ni grabaciones: barridos de espada (6 ligeros, 3
  fuertes), golpes de espada en carne, cuero, gambesón y malla, escudo de madera y bloqueo con acero,
  parada de acero con acero, pasos en tierra y en piedra (8 cada uno), caída de un cuerpo (3), esquiva,
  arco y flechas (tensar, soltar, impacto en carne y en madera), voces de los Huecos (heridas y muerte),
  poción, clic y confirmación de interfaz, y cuernos de fuerte ganado y perdido con un timbre por reino.
  Los genera `tools/audio/synth_sfx.py` con `sfx_dsp.py`, `sfx_combat.py` y `sfx_world.py` (síntesis con
  numpy, codificación con ffmpeg y libvorbis; salida idéntica byte a byte en cada ejecución) y los mide
  contra el listón de calidad y dibuja `tools/audio/analyze_sfx.py` (espectrogramas, hojas y comparativas
  en `build/audio/`, no versionados). `niveles.json` lleva la sonoridad de cada archivo, el recorte de
  volumen por grupo, el instante del pico (`pico_s`) para sincronizar los barridos con `data/combat` y el
  aleatorizador recomendado. Desde la oleada 4 de calidad los conecta `CombatAudio` (`scripts/client/audio/combat_audio.gd`) con los bancos
  de `CombatSoundBank`; a los pasos de tierra y de piedra se suman los de hierba y de madera de Kenney (arriba).

- Torreón del fuerte (ART-57), versión 2, modelado y pintado desde cero con código, sin fotos, IA ni
  texturas de terceros: `assets/models/environment/custom/fort_keep.glb` (tres niveles de detalle, el nodo
  `Estandarte` y la colisión de baja resolución en un solo glTF, con color de vértice y sin imágenes
  incrustadas), sus texturas propias en `assets/models/environment/custom/fort_keep/textures/` (piedra,
  piedra labrada, paño de sillería despiezada, madera, tablillas de tejado y los atlas de estandartes, estos
  últimos con los emblemas de `assets/emblems/` rasterizados), los shaders
  `assets/materials/shaders/fort_keep_surface.gdshader` y `fort_keep_cloth.gdshader` y sus materiales de
  reino (Eldrun, Vardheim, Solmarch y Askarra) en `assets/models/environment/custom/fort_keep/materials/`.
  Se regeneran con `bash tools/blender/regenerate_fort_keep.sh`, que encadena
  `tools/blender/make_fort_keep_textures.py` (numpy y Pillow: lavados de color, pinceladas, grietas y
  tablillas por código), `tools/blender/build_fort_keep.py` (Blender 5.2.3 con `bpy`, sin interfaz; el
  encabezado documenta la geometría, el color de vértice y los ajustes de importación del GLB que no son
  los de por defecto), `tools/assets/apply_texture_import_presets.gd` y
  `tools/materials/build_fort_keep_materials.gd`. Las herramientas de revisión son
  `tools/render/render_fort_keep_*.gd` y `tools/blender/compose_fort_keep_comparison.py`; la escena de vista
  previa es `scenes/tests/fort_keep_preview.tscn` (con `scripts/client/tools/fort_keep_preview.gd`).

- Espada de armas `assets/models/weapons/` (`sword_base.glb` y las variantes por reino
  `sword_vardheim.glb`, `sword_solmarch.glb` y `sword_askarra.glb`): modelada desde cero con Blender
  5.2 sin interfaz por `tools/blender/build_sword.py`, con las texturas (la hoja de cada reino con su
  acanaladura de runas, oro o grieta emisiva, el cuero y un atlas de metal con el canto pulido, todo
  ruido y degradados) generadas por código en `tools/blender/sword_textures.py`. Ninguna malla ni
  textura viene de un pack: las espadas de RPG Weapons Free solo se miraron para comparar calidad.
  La estela del golpe (`scripts/client/sword_trail.gd`) es una cinta propia con una textura de degradado generada por código al arrancar.
  Para regenerarlas: `blender --background --factory-startup --python tools/blender/build_sword.py`
  y `godot --headless --path . --import`. Los GLB llevan las texturas dentro (el `.import` las
  conserva embebidas, `gltf/embedded_image_handling=3`).
- Emblemas de bando `assets/emblems/*.svg` (lobo, sol partido, yunque y corona rota):
  **provisionales**, formas geométricas hechas para Eldmark con `tools/assets/make_emblems.py`; los
  sustituirá el arte final de ART-03 con los mismos nombres de archivo.
- Mapa de pergamino del Vado Gris `assets/maps/vado_gris_parchment.png` y su escala y lugares fijos en
  `assets/maps/vado_gris_parchment_map.tres` (UI-51): contenido propio, 2048 px sobre ±200 m (el valle
  jugable ocupa tres cuartos de la imagen). Pintado por capas en CPU (papel gris pardo desaturado, aguada,
  relieve a pluma con las rampas dobladas con ruido, río, calzadas unidas antes de entintar, murallas, torres
  y puertas en perspectiva oblicua, fuerte agrandado 1,5 veces con empalizada, torres y torreón, campamentos
  con el color de su reino, ruinas y capilla agrandadas, bosquetes como masas con contorno común, cordilleras
  a tinta que se apagan con la distancia al valle, cartelas con la rosa de los vientos y la escala) a partir de
  los datos reales de la zona, sin imágenes de terceros. Lo genera `tools/map/bake_parchment_map.gd` con
  `ParchmentMapBaker` y `ParchmentCanvas` (`tools/map/`); para regenerarlo:
  `godot --headless --path . -s res://tools/map/bake_parchment_map.gd` y después
  `godot --headless --path . --import`. Es determinista: misma escena, mismo mapa. La cabecera de
  `tools/map/bake_parchment_map.gd` anota qué cambiar para activarlo en el juego (hoy no está conectado).

- Iconos de la interfaz `assets/ui/icons/` (ART-12): 33 figuras de 128 px sin fondo
  (`assets/ui/icons/<nombre>.png`: ataque ligero y fuerte, disparo rápido y tensado, bloqueo, esquiva,
  las seis habilidades de espada y escudo y de arco, las dos pociones, cambiar de arma, los iconos de
  arma (espada y escudo, arco), interactuar, sangrado, regeneración, aturdimiento, ralentización,
  empuje, derribado, enraizado, fuerte, puerta, campamento y estandartes), las variantes pequeñas de
  los siete estados a su tamaño nativo de 14 y 26 px (`small/<estado>_14.png`, `_26.png`) y siete
  fondos por categoría a sangre y sin marco (`backgrounds/<categoría>.png`). Hechos enteros por código,
  sin nada de terceros ni de generación con IA. Herramientas: Python con numpy y PIL, y el
  rasterizador del propio motor (ThorVG). `tools/ui/icons/svgkit.py` (geometría, materiales y capas),
  `glyphs.py` (los dibujos), `paint.py` (grano, oclusión entre piezas, luz de borde y fondos),
  `make_icons.py` (orquestador) y `rasterize_icons.gd`; `build_icons.sh` lo regenera todo. Medidas
  y láminas de muestra: `qa.py`, `make_sheets.py` y `engine_test.gd` (salida en `build/iconos/`).

## Créditos de cortesía

Ninguno es obligatorio, pero los autores lo agradecen. Para la pantalla de créditos:

- Modelos y animaciones: **Quaternius** (quaternius.com).
- Murallas: **loafbrr**.
- Piezas de blockout: **Kenney** (www.kenney.nl).
- Texturas de terreno: **Jonas Voland**.
- Terreno: **Terrain3D**, de Cory Petkovsek, Roope Palmroos y colaboradores (MIT).
- Dispersión: **ProtonScatter**, de HungryProton (MIT).
