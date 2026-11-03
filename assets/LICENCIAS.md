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
| Versión / archivo | `Stylized Nature MegaKit[Standard].zip`, sha256 `298f6732b872e4cf7b30e6e7abf9641c7f6dc6b326df37ac089533ed7e3d58c9`. 16 modelos glTF (3 pinos, 3 caducifolios, 2 árboles muertos, 3 rocas, 2 hierbas, un arbusto y 2 losas de camino) y sus texturas, reducidas a 1024 px como máximo; `flowers.png` (1008 x 981 en el pack) llevada a 1024 x 1024 |
| URL | https://quaternius.itch.io/stylized-nature-megakit |
| Licencia | CC0 1.0 Universal |
| Dónde se indica | `License_Standard.txt` dentro del zip |
| Carpeta en el repo | `assets/models/environment/nature/` |
| Créditos | No obligatorios (cortesía: Quaternius) |

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

## Fuentes (pendientes: tarea del usuario)

`assets/fonts/` está vacío: **faltan las fuentes OFL elegidas** para la interfaz (decisión del
backlog, UI-02) y por ahora el tema usa la fuente por defecto del motor. No se han podido bajar con
garantías de licencia desde el entorno de desarrollo, así que quedan pendientes de añadir a mano:

| Uso | Fuente elegida | Licencia | Archivo esperado |
|---|---|---|---|
| Cuerpo de texto y números | Noto Sans (Google / Noto Project) | SIL OFL 1.1 | `assets/fonts/NotoSans-Regular.ttf` |
| Títulos y pestañas | Cinzel (Natanael Gama) o Alegreya SC (Juan Pablo del Peral) | SIL OFL 1.1 | `assets/fonts/Cinzel-Regular.ttf` |

Pasos: descargar cada familia de su origen oficial (Google Fonts o el repositorio del autor), copiar el
`.ttf` con el nombre de la tabla (los `.ttf` van por Git LFS, ver `.gitattributes`) junto con su
`OFL.txt`, anotar aquí autor, versión, fecha, URL y licencia (como en los demás packs), comprobar que
la `ñ` y las tildes salen bien y ejecutar `godot --headless --path . -s res://tools/ui/build_theme.gd`
para que el tema las cablee (`UIThemeBuilder` carga esas rutas si existen). Si se elige Alegreya SC,
basta cambiar `UIThemeBuilder.TITLE_FONT_PATH`. La OFL pide conservar el aviso de copyright y la
licencia de cada familia dentro del juego exportado.

## Contenido propio (no es de terceros)

Hecho para Eldmark a partir de los packs anteriores o desde cero. Es del proyecto, que todavía no
declara una licencia propia:

- Shaders `assets/materials/shaders/` (`realm_surface`, `water`) y materiales de
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
  `hit_block_wood`, `parry_flash`, `dust_kick`, `weapon_trail` y `charge_aura`), sombreadores
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
- Emblemas de bando `assets/emblems/*.svg` (lobo, sol partido, yunque y corona rota):
  **provisionales**, formas geométricas hechas para Eldmark con `tools/assets/make_emblems.py`; los
  sustituirá el arte final de ART-03 con los mismos nombres de archivo.

## Créditos de cortesía

Ninguno es obligatorio, pero los autores lo agradecen. Para la pantalla de créditos:

- Modelos y animaciones: **Quaternius** (quaternius.com).
- Murallas: **loafbrr**.
- Piezas de blockout: **Kenney** (www.kenney.nl).
- Texturas de terreno: **Jonas Voland**.
- Terreno: **Terrain3D**, de Cory Petkovsek, Roope Palmroos y colaboradores (MIT).
- Dispersión: **ProtonScatter**, de HungryProton (MIT).
