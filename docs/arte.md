# Eldmark: dirección artística y plan de assets

> Este documento parte de la investigación verificada del 28/10/2026. Volví a comprobar en la web dos datos que deciden compras, y los dos siguen sin confirmar:
> - **Strafe en UAL1 Pro.** La página no dice en qué versión está la "Locomotion in 8 directions" ([itch](https://quaternius.itch.io/universal-animation-library)).
> - **Esqueleto en el Bestiary.** "Skeletons" solo aparece como etiqueta. La página de quaternius.com dice "7 Monsters" sin nombrarlos ([itch](https://quaternius.itch.io/bestiary-dungeon-monsters-kit), [quaternius.com](https://quaternius.com/packs/bestiarydungeonmonsterskit.html)).
>
> No he descargado nada. Las descargas de itch.io las tiene que hacer una persona a mano.

---

## 1. Dirección artística elegida

**Estilizado semirrealista con texturas, de la familia Quaternius "Universal + MegaKit" (2024–2026).** Es una única familia para personajes, entorno y naturaleza. Los castillos se completan con el Castle Wall Kit (CC0) retexturizado y con piezas propias hechas con las mismas texturas.

### Por qué esta y no KayKit

| Criterio | Quaternius Universal/MegaKit | KayKit |
|---|---|---|
| Personajes y animación | Cuerpo base, trajes modulares y UAL1/UAL2 comparten un solo rig desde la v2.0 de UAL1. Desde entonces no hace falta retargeting entre ellos. | Un solo rig y la mejor cobertura de combate gratis, pero el estilo es chibi. |
| Entorno a escala humana | Village MegaKit (unos 300 módulos con interiores), Fantasy Props y Stylized Nature. Mismo autor, época, texturizado y escala. | No tiene kit de aldea ni de castillo a escala humana. El Medieval Hexagon es una miniatura de tablero. |
| Tono New World | Proporciones humanas o heroicas. El bloqueo y el golpe fuerte se leen bien y las hitboxes son de tamaño humano. | Desenfadado y cartoon. |
| Recolorear por reino (mundo.md) | Piezas en rejilla y pocos juegos de texturas: se recolorean con un shader. | Atlas de degradado, también recoloreable, pero sin edificios que pasear. |
| Ampliable | Las versiones Source (de 15 a 20 $, siguen siendo CC0) traen los .blend para modelar piezas propias con las mismas texturas. | Igual, pero sin una base arquitectónica. |

En contra, y lo digo claramente:
- No existe kit de castillo de Quaternius. En junio de 2025 dijo que depende de una votación en Patreon.
- El caballero y el mago vienen en la Source de Outfits (20 $).
- Ningún pack gratis de la familia trae animaciones de arco.
- No está confirmado que el Bestiary traiga un esqueleto, y su licencia es QAL, no CC0.
- Cada personaje tiene unos 13.000 triángulos más la ropa. En la zona de guerra eso pesa, así que hay que medir pronto.

### Reglas de estilo mínimas

- Escala: 1 unidad = 1 m. Un humano adulto mide unos 1,8 m. Cada pack se valida al importar contra una cápsula de 1,8 m.
- Nada de texturas fotográficas (Poly Haven, ambientCG) en assets de primer plano. Solo se usan como terreno de relleno, y siempre procesadas: desaturadas y con menos detalle.
- Un solo shader de superficie por reino, recoloreando el mismo kit:

| Reino | Piedra | Madera | Tejado | Acento | Capa extra |
|---|---|---|---|---|---|
| Vardheim | gris frío y tosco | casi negra | tablas gris parduzco | azul hielo | nieve en las caras que miran hacia arriba |
| Solmarch | caliza crema | clara | pizarra azul | blanco y oro | musgo o hiedra (el kit trae enredaderas) |
| Askarra | arenisca roja | rojiza | terracota | carmesí y bronce | polvo o ceniza |
| Eldrun | el kit desaturado | gris | piezas que faltan (ruina) | brasas emisivas en las grietas | ceniza |

- Antes de importar en masa, se monta una **escena de prueba de estilo** (`scenes/tests/style_test.tscn`). Lleva un personaje con traje, cinco piezas del Village, un tramo del Castle Wall Kit, árboles del Nature y el terreno Watercolor bajo la iluminación del juego. Si algo desentona, se descarta antes de llenar LFS.

---

## 2. Lista de descargas recomendada

Para todos los packs de itch.io "name your own price" el método es el mismo. Una persona abre la página, pulsa **Download Now** y elige **"No thanks, just take me to the downloads"** (versión gratis) o paga (versiones de pago). Después baja el zip indicado **a una carpeta fuera del repo** (por ejemplo `../Eldmark-raw/<pack>/<versión>/`). Al repo solo pasa la carpeta glTF que se use, y se anotan la versión y la fecha en `assets/LICENCIAS.md`. Itch no da URL directa estable.

Lo que diga "QAL" o "no CC0" va marcado. Todo lo demás es CC0 1.0.

### Prioridad 1: imprescindible ahora

**1. Universal Animation Library (UAL1), Standard**
- **Autor:** Quaternius
- **Página:** https://quaternius.itch.io/universal-animation-library
- **Descarga:** itch, Standard gratis. Hay que bajar la versión actual (v3.0, 16/6/2026 o posterior). **No usar** las copias de OpenGameArt ni la de Godot Asset Store: son anteriores a la v2.0, que cambió los nombres de huesos.
- **Tamaño:** 15 MB
- **Licencia:** CC0 1.0. Lo indican la fila "Asset license" de itch y quaternius.com/packs/universalanimationlibrary.html.
- **Contenido:** 45 animaciones en el rig universal. Idle, caminar, trotar, sprint, salto en 3 fases, Roll, Sword_Idle/Attack, Spell_*, Hit_Chest/Head, Death01 y A_TPose. La v3.0 trae variantes con y sin root motion. Usar las **sin root motion**: el servidor decide el movimiento. La página no dice qué versiones traen las dos variantes.
- **En el repo:** `assets/animations/ual1/`

**2. UAL1 Pro (de pago, recomendado)**
- **Precio:** desde 9,99 $
- **Tamaño:** 41 MB
- **Licencia:** CC0
- **Contenido:** las más de 120 animaciones. **Comprueba antes de pagar** que el strafe en 8 direcciones viene en Pro: es una deducción, la página no lo dice. Si solo viniera en Source (14,99 $), compra Source. El strafe es esencial con la cámara al hombro (fase 1).
- **En el repo:** `assets/animations/ual1/`

**3. Universal Animation Library 2 (UAL2), Standard**
- **Autor:** Quaternius
- **Página:** https://quaternius.itch.io/universal-animation-library-2
- **Descarga:** itch, Standard gratis. Bajar la v2.2 (28/9/2026); la copia de OpenGameArt es antigua.
- **Tamaño:** 17 MB
- **Licencia:** CC0. Lo dice la descripción de itch ("(CC0 License)") y quaternius.com/packs/universalanimationlibrary2.html.
- **Contenido:** unas 42 animaciones:
  - Combos de espada SWORD_REGULAR_A, _COMBO, _COMBOB y _REC, más SWORD_DASH. Sirven de base para el golpe ligero y el fuerte.
  - IDLE_SHIELD (bloqueo) e IDLE_SHIELD_BREAK (rotura de guardia).
  - KNOCKBACK, SLIDE y ZOMBIE_WALK_FWD (útil para los Huecos).
  - **No está confirmado** que el esqueleto sea idéntico al de UAL1: hay que comparar los nombres de huesos al importar.
- **En el repo:** `assets/animations/ual2/`

**4. Universal Base Characters, Standard**
- **Autor:** Quaternius
- **Página:** https://quaternius.itch.io/universal-base-characters
- **Descarga:** itch, Standard gratis
- **Tamaño:** 122 MB
- **Licencia:** CC0 1.0, según la fila "Asset license" de itch
- **Contenido:** 2 cuerpos base y 5 peinados, de unos 13.000 triángulos, compatibles con UAL. Los formatos son OBJ, FBX y glTF: importar **solo el glTF**.
- **En el repo:** `assets/models/characters/base/`

**5. Modular Character Outfits - Fantasy, Standard**
- **Autor:** Quaternius
- **Página:** https://quaternius.itch.io/modular-character-outfits-fantasy
- **Descarga:** itch, Standard gratis. Bajar la v2.1 (5/7/2026) o posterior.
- **Tamaño:** 280 MB
- **Licencia:** CC0 1.0, según la fila "Asset license" de itch
- **Contenido:** trajes Ranger y Peasant en piezas modulares, con 3 variantes de textura. Vienen en .gltf con .bin y texturas sueltas: hay que importar la carpeta entera. No trae armas.
- **En el repo:** `assets/models/characters/outfits/`

**6. Bestiary - Dungeon Monsters Kit, Standard (condicional: es QAL, no CC0)**
- **Autor:** Quaternius
- **Página:** https://quaternius.itch.io/bestiary-dungeon-monsters-kit
- **Descarga:** itch, archivo "Bestiary - Dungeon Monsters Kit[Standard].zip"
- **Tamaño:** 45 MB
- **Licencia:** **QAL v1.0** (28/8/2026), en https://quaternius.com/license.html. Permite uso comercial y vender el juego sin atribución. La sección 3(a) **prohíbe redistribuir los archivos sueltos**. Ojo: el FAQ de quaternius.com dice "todo es CC0", y eso contradice esta licencia.
- **Contenido:** 7 monstruos con armas y 3 colores cada uno, en el rig compatible con UAL. Sin animaciones.
- **Condición:** descárgalo y comprueba si la Standard trae un esqueleto. Si lo trae, sirve para los Huecos (4 guardias y el Capitán en otro color). Si no, aplica el plan B de la sección 4.8.
- **En el repo:** `assets/models/enemies/bestiary/`. Mientras el repo sea privado vale. Si se hace público, hay que sacarlo antes del repo público.

**7. Medieval Village MegaKit, Standard**
- **Autor:** Quaternius
- **Página:** https://quaternius.itch.io/medieval-village-megakit (y https://quaternius.com/packs/medievalvillagemegakit.html)
- **Descarga:** itch, Standard gratis
- **Tamaño:** 153 MB
- **Licencia:** CC0 1.0. Lo indican itch, quaternius.com y Godot Asset Store.
- **Contenido:** unos 170 de los 304 módulos en rejilla: muros, suelos, escaleras, tejados, puertas, ventanas y enredaderas. Es **el kit base que se recolorea por reino**. No trae torres, almenas ni barbacana confirmadas, ni colisiones (vienen en Source).
- **En el repo:** `assets/models/environment/village/`

**8. Stylized Nature MegaKit, Standard**
- **Autor:** Quaternius
- **Página:** https://quaternius.itch.io/stylized-nature-megakit
- **Descarga:** itch, Standard gratis
- **Tamaño:** 99 MB
- **Licencia:** CC0 1.0 (itch y quaternius.com)
- **Contenido:** 81 modelos entre árboles con 7 tipos de hoja, plantas, rocas, hierba y arbustos. No trae acantilados. Los shaders de viento son exclusivos de Source.
- **En el repo:** `assets/models/environment/nature/`

**9. Castle Wall Kit**
- **Autor:** loafbrr
- **Página:** https://loafbrr.itch.io/castle-wall-kit
- **Descarga:** itch, precio libre desde 0 $. Bajar `CastleWallKit_blend_fbx_gltf_textures.zip`; es la fuente buena. `CastleWall_Kit_Godot.zip` (35 MB) solo sirve como referencia del montaje con GridMap: no dice para qué versión de Godot es y puede traer recursos binarios.
- **Tamaño:** 149 MB (zip con glTF)
- **Licencia:** CC0 1.0, según el campo de licencia de itch
- **Contenido:**
  - 116 piezas de muro de 6 × 6 m, con puerta, 2 portones y ventanas.
  - 4 materiales de 1K (ladrillo y trimsheet) y unos 8.000 triángulos en total.
  - Sirve para las fachadas de las murallas (Muro de Escarcha y Muralla del Alba) **retexturizadas**.
  - **Pegas:** solo ladrillo, sin torres ni almenas confirmadas. Es un listado reciente de un autor pequeño.
- **En el repo:** `assets/models/environment/castle_wall/`

**10. Castle Kit 2.0 (solo blockout)**
- **Autor:** Kenney
- **Página:** https://kenney.nl/assets/castle-kit
- **Descarga directa:** https://kenney.nl/media/pages/assets/castle-kit/a395102d20-1711543616/kenney_castle-kit.zip (enlace de "Continue without donating")
- **Tamaño:** 2,1 MB
- **Licencia:** CC0. Lo indican kenney.nl ("Creative Commons CC0"), itch y OpenGameArt.
- **Contenido:** 75 modelos: muros, torres, puertas, armas de asedio, banderas. **No está verificado** qué armas de asedio trae ni si tienen versión destruida. Sirve para montar en gris el fuerte del Vado Gris y como referencia de asedio. **Nunca como arte final.**
- **En el repo:** `assets/models/blockout/kenney_castle/`

**11. Watercolor Terrain Textures**
- **Autor:** Jonas Voland / Voxel Core Lab
- **Página:** https://voxelcorelab.itch.io/watercolor-terrain-textures
- **Descarga:** itch, precio libre desde 0 $, archivo `VoxelCoreLab_Watercolor_Terrain_Textures_1024px.zip`
- **Tamaño:** 28 MB
- **Licencia:** CC0 1.0, según la descripción y el campo de licencia de itch. La atribución es opcional; el autor pide que se le acredite como "Jonas Voland".
- **Contenido:** 16 PNG de 1024 px que encajan sin costuras: 4 de hierba, 4 de piedra, 4 de tierra y 4 de agua. Casi seguro que solo traen color, sin normales ni rugosidad. Cubren el Vado Gris: hierba, tierra, piedra y orilla.
- **En el repo:** `assets/textures/terrain/watercolor/`

Las **herramientas de prioridad 1** son Terrain3D 1.0.2 y ProtonScatter (main). Están en la sección 3.

### Prioridad 2: pronto (combate de la fase 3 y fuerte de la fase 4)

**12. Fantasy Props MegaKit, Standard**
- **Autor:** Quaternius
- **Página:** https://quaternius.itch.io/fantasy-props-megakit
- **Descarga:** itch, gratis
- **Tamaño:** 143 MB
- **Licencia:** CC0 1.0 (itch y Godot Asset Store)
- **Contenido:** 94 modelos con solo 4 juegos de texturas: armas (espadas provisionales para la fase 3), barriles, cofres, puestos de mercado y muebles. **No se confirma** que traiga escudos ni estandartes.
- **En el repo:** `assets/models/environment/props/`

**13. RPG Weapons, Free (y Pro)**
- **Autor:** Binbun
- **Página:** https://binbun3d.itch.io/rpg-weapons
- **Descarga:** itch. Free gratis; Pro a 3,99 o 7,99 $ (la página da los dos precios).
- **Tamaño:** Free 10 MB, Pro 12 MB
- **Licencia:** CC0 1.0 en todas las versiones, según la sección Licensing y el campo License de itch
- **Contenido:**
  - Free: 70 armas, entre ellas lanzas y mazas.
  - Pro: añade arcos, flechas, bastones y **2 tipos de escudo** (necesarios para el bloqueo).
  - Según la v1.1, trae un proyecto Godot: comprobar que los recursos sean .tscn/.tres.
  - Comprobar el estilo junto a los Outfits.
- **En el repo:** `assets/models/weapons/binbun_rpg/`

**14. KayKit Character Animations, Free 1.1 (solo animaciones de apoyo)**
- **Autor:** Kay Lousberg
- **Página:** https://kaylousberg.itch.io/kaykit-character-animations
- **Descarga:** itch, gratis. **No** la versión "(Legacy)".
- **Tamaño:** 14 MB
- **Licencia:** CC0 1.0, según el campo "Asset license" de itch
- **Contenido:** 161 animaciones con bloqueo, esquiva, arco y hechizos. Se usan **solo** para probar a retargetear al rig UAL las que faltan: impacto en bloqueo, esquiva direccional y arco. El autor avisa de que fuera de KayKit "may not look good".
- **En el repo:** `assets/animations/kaykit/` (solo los clips aprobados)

**15. Hit FX y Battle FX, Free (Full desde 3,49 $ cada uno)**
- **Autor:** Binbun
- **Páginas:** https://binbun3d.itch.io/hit-fx y https://binbun3d.itch.io/battle-fx
- **Descarga:** itch
- **Tamaño:** Hit FX 39 kB (Full 1,3 MB); Battle FX 985 kB (Full 1 MB)
- **Licencia:** CC0 1.0 en todas las versiones, según el campo License de itch
- **Contenido:**
  - Shaders y presets de Godot 4 para impactos, cortes, barridos y escudos.
  - Un comentarista dice que Hit FX funciona en 4.7-stable.
  - Comprobar que los recursos sean texto y de dónde sale el audio que incluyen.
- **En el repo:** `assets/vfx/binbun/`

**16. Particle Pack**
- **Autor:** Kenney
- **Página:** https://kenney.nl/assets/particle-pack
- **Descarga directa:** https://kenney.nl/media/pages/assets/particle-pack/f8fe0f8cb8-1677578741/kenney_particle-pack.zip
- **Tamaño:** la página no lo indica
- **Licencia:** CC0 (kenney.nl)
- **Contenido:** 80 texturas de partículas de 512 px: chispas, humo, polvo de esquiva y trazos de arma.
- **En el repo:** `assets/vfx/kenney_particles/`

**17. RPG Audio e Impact Sounds**
- **Autor:** Kenney
- **Páginas:** https://kenney.nl/assets/rpg-audio y https://kenney.nl/assets/impact-sounds
- **Descarga directa:**
  - https://kenney.nl/media/pages/assets/rpg-audio/8e99002d76-1677590336/kenney_rpg-audio.zip
  - https://kenney.nl/media/pages/assets/impact-sounds/87b4ddecda-1677589768/kenney_impact-sounds.zip
- **Tamaño:** RPG Audio 691 KB; Impact Sounds sin indicar
- **Licencia:** CC0 (kenney.nl y OpenGameArt)
- **Contenido:** 50 sonidos de pasos, foley y armas, más 130 impactos, en OGG (confirmado para RPG Audio).
- **En el repo:** `assets/audio/sfx/kenney/`

**18. Medieval SFX: Weapon Textures y Weapon Impacts**
- **Autor:** Still North Media (Ben Jaszczak y Brian Nelson); los subió MedicineStorm
- **Páginas:** https://opengameart.org/node/146862 y https://opengameart.org/node/146863
- **Descarga:** enlaces directos de OpenGameArt a 4 archivos .7z. Hay que **descomprimirlos fuera del repo** y elegir clips.
- **Tamaño:** unos 332 MB en total
- **Licencia:** CC0 en OpenGameArt, pero se apoya en la cita "CC0 NO RIGHTS RESERVED" de la web original, que solo sobrevive en Archive.org.
- **Contenido:** barridos de hacha, daga, sable y lanza; desenvainar; arco largo y recurvo; ballesta; choques arma contra arma. No trae choques de armadura ni barrido de maza. El formato no está confirmado.
- **En el repo:** `assets/audio/sfx/still_north/` (solo los clips elegidos, pasados a OGG)

**19. 80 CC0 RPG SFX**
- **Autor:** rubberduck
- **Página:** https://opengameart.org/content/80-cc0-rpg-sfx
- **Descarga:** zip directo de OpenGameArt (`80-CC0-RPG-SFX.zip`)
- **Tamaño:** 1,8 MB
- **Licencia:** CC0, según el campo License(s) de OpenGameArt
- **Contenido:** 22 sonidos de criaturas (heridas y muertes de los Huecos), hechizos, monedas, cerraduras y cadenas.
- **En el repo:** `assets/audio/sfx/rubberduck/`

**20. Medieval Village MegaKit Source (de pago)**
- **Precio:** desde 14,99 $
- **Tamaño:** 675 MB
- **Licencia:** CC0
- **Contenido:** los 304 modelos, colisiones optimizadas, .blend y proyecto de Godot 4.3. Ahorra el trabajo de colisiones y permite modelar piezas propias (empalizada, torre del fuerte, puente) con las mismas texturas.
- **En el repo:** `assets/models/environment/village/` (lo que se use). Los .blend van a `assets/models/environment/custom/src/`.

Las **herramientas de prioridad 2** son Sky3D 2.1.0 y el shader de agua toon.

### Prioridad 3: más adelante

- **Modular Character Outfits Source** (20 $, 724 MB, CC0): los 12 trajes, entre ellos caballero, mago y noble. Cuando se definan las clases.
- **Universal Base Characters Source** (19,99 $, 600 MB, CC0): todos los cuerpos, 20 peinados y shaders de piel y ojos (para las razas).
- **UAL2 Source** (14,99 $, 50 MB, CC0): combos de 3 y 4 golpes con recuperación y Sword_Light.
- **RPG Weapons Pro**, si no se compró antes.
- **Elemental Magic FX** (Binbun, CC0, 916 kB; Full 3,49 $), si hay clases mágicas: https://binbun3d.itch.io/elemental-magic-fx
- **Interface Sounds y UI Audio** (Kenney, CC0):
  - https://kenney.nl/media/pages/assets/interface-sounds/fa43c1dd4d-1677589452/kenney_interface-sounds.zip
  - https://kenney.nl/media/pages/assets/ui-audio/490d233f68-1677590494/kenney_ui-audio.zip
  - Van a `assets/audio/ui/`.
- **Poly Haven** (CC0, https://polyhaven.com/license), para los huecos del Watercolor:
  - Nieve para Vardheim (snow_01 a snow_05), arena y roca para Askarra, gravilla gris para Eldrun.
  - PNG de 1k con nor_gl, pasados por el empaquetador de Terrain3D y desaturados.
  - Van a `assets/textures/terrain/polyhaven/`.
  - Como alternativa, **ambientCG** (CC0, https://docs.ambientcg.com/license/).
- **Terrain3D 1.1.0 estable**, cuando salga: trae océano, desplazamiento de altura y colorizador por pendiente.
- **Forest ambience** (CC0): https://opengameart.org/content/forest-ambience
- **KayKit Medieval Hexagon** (CC0, 33 MB), solo si se quiere un mapa estratégico en 3D de Eldrun en la interfaz.

**Presupuesto orientativo:** lo imprescindible cuesta unos 10 $ (UAL1 Pro). Las compras recomendadas a corto y medio plazo (Outfits Source, Village Source, RPG Weapons Pro y 2 FX Full) suman entre 45 y 50 $ más. Todo sigue siendo CC0, salvo el Bestiary.

---

## 3. Herramientas de Godot recomendadas

| Herramienta | Versión para 4.7 | Licencia | Tamaño | GDExtension | Instalación |
|---|---|---|---|---|---|
| **Terrain3D** (TokisanGames). Terreno con clipmap, pintura con hasta 32 texturas, huecos e instanciador de vegetación. | **v1.0.2-stable** (19/5/2026, "Supports Godot 4.4-4.7"). La v1.1.0-rc1 (17/10/2026, 4.5–4.8+) es preliminar: pasar a la 1.1 estable cuando salga. | MIT (LICENSE.txt del repo) | Zip de 42,3 MB | **Sí**: DLL/SO/dylib nativos para Windows, Linux y macOS | Bajar https://github.com/TokisanGames/Terrain3D/releases/download/v1.0.2-stable/Terrain3D_v1.0.2-stable.zip (o AssetLib #3892). Copiar solo `addons/terrain_3d/` a `res://addons/`, abrir el editor (si da errores la primera vez, reiniciarlo) y activarlo en Proyecto > Configuración > Plugins. No versionar `demo/`. |
| **ProtonScatter** (HungryProton). Distribución de árboles, rocas y props **con colisión**. | **Rama main**. Los arreglos para 4.7 son del 26/7/2026 y del 25/2/2026, y el de Jolt del 27/9/2026. **No usar** AssetLib #1866: es anterior a esos arreglos. | MIT. Las texturas de la demo vienen de Textures.com: **no versionar la demo**. | Repo de unos 16 MB | No (GDScript) | Bajar https://github.com/HungryProton/scatter/archive/refs/heads/main.zip y **anotar el SHA del commit** en LICENCIAS.md. Copiar `addons/proton_scatter/` **sin renombrarla** y activar el plugin. |
| **Sky3D** (TokisanGames). Ciclo de día y noche con sol, luna, estrellas, niebla y nubes. | **v2.1.0** (19/5/2026, Godot 4.3+). El issue #120 en 4.7 está cerrado. | Código MIT. Las texturas de estrellas son **CC BY 4.0** (ESO/S. Brunier) y **obligan a acreditar**. La procedencia de MoonMap.png no está clara: sustituirla antes de publicar. | 11,5 MB | No | Bajar https://github.com/TokisanGames/Sky3D/releases/download/v2.1.0/Sky3D_v2.1.0.zip (o AssetLib #5167). Copiar `addons/sky_3d/` y activarlo. **Solo en el cliente**: instanciarlo desde `client_main`, no en la escena de zona compartida. La hora la manda el servidor. |
| **Instanciador de Terrain3D** (incluido) para la hierba | Igual que Terrain3D | MIT | — | — | Las instancias **no tienen colisión**: solo para hierba y detalles pequeños. |
| **Shader de agua toon** (Megalithium, godotshaders.com) | Probado en 4.3; un usuario dice que va en 4.5.1. **Hay que probarlo en 4.7**, sobre todo la espuma por profundidad. | CC0 (el código; las imágenes del post no) | Unos pocos KB | No | Copiar el código de https://godotshaders.com/shader/toon-style-3d-water-shader-no-textures-needed/ a `assets/materials/shaders/water_toon.gdshader`, sobre un PlaneMesh con subdivisiones. |
| **Funciones de Godot 4.7** | Incluidas | MIT | — | — | Occlusion culling (activar en Configuración avanzada y hornear `OccluderInstance3D`: las murallas son oclusores perfectos), visibility ranges con `visibility_parent` (HLOD para fuertes lejanos), LOD automático al importar y `MultiMeshInstance3D`. |

Notas sobre Terrain3D:
1. **Choca con dos reglas del repo.** Guarda cada región como `.res` binario (`terrain3d_XX_YY.res`) y trae binarios nativos. Hace falta una excepción explícita en CLAUDE.md y añadir `*.res`, `*.dll`, `*.so` y `*.dylib` a LFS (sección 4.5).
2. **El servidor headless no está documentado.** Primera tarea: comprobar que `godot --headless --path . --import` y una zona con terreno arrancan sin ventana, y que la colisión responde. Usar colisión Full/Game en el servidor (gasta memoria en mapas grandes) o `Terrain3DData.get_height()`. El fallo de colisión del #1043 solo ocurre en compilaciones de doble precisión.
3. **Alternativa si el headless fallara:** HTerrain (Zylann, MIT, GDScript puro, rama master para Godot 4.6+). Solo recibe correcciones, pero carga sin problema en headless.

ProtonScatter y el servidor: con la opción `keep_static_colliders` las colisiones se crean en tiempo de ejecución y no se guardan en la escena. Para que cliente y servidor tengan **la misma colisión horneada**, usar el modo **Create Copies** con escenas de objeto que lleven su propio `StaticBody3D` y `CollisionShape3D`, y dejar el resultado guardado en la escena de la zona. Comprueba en el panel de documentación del addon cómo se conserva lo generado. Nada de distribuir objetos en tiempo de ejecución en el servidor.

---

## 4. Plan de integración

### 4.1 Flujo de descarga
1. Una persona descarga a `../Eldmark-raw/<pack>/<versión>/`, fuera del repo. Los zips nunca se versionan.
2. Se anota en `assets/LICENCIAS.md`: pack, autor, versión, fecha, URL, licencia, dónde se indica, y el hash del zip si se puede. Ahí van también los créditos obligatorios (ESO/S. Brunier por las estrellas de Sky3D) y los de cortesía (Jonas Voland, Kenney, Quaternius).
3. Al repo pasa **solo** la subcarpeta glTF (los packs de Quaternius duplican todo en FBX, OBJ y glTF) y únicamente las piezas que se usen.

### 4.2 Importación glTF en Godot 4.7
- **Modelos estáticos:**
  - Activar "Generate LODs" y "Create Shadow Meshes" (vienen activados por defecto).
  - Colisiones en *Advanced Import Settings* > malla > Physics: Static Body con Box o Convex para la mayoría de piezas, y Trimesh solo para muros complejos. Si se compra la Source del Village, usar sus colisiones.
- **Materiales:** extraerlos como **.tres** para poder sustituirlos por reino, nunca como .res. Las texturas, en VRAM Compressed con mipmaps.
  - La detección 3D de Godot (`detect_3d`) solo actúa dentro del editor: en una importación headless las texturas de los glTF se quedan sin comprimir y sin mipmaps (más VRAM y brillos en la piedra lejana). `tools/assets/apply_texture_import_presets.gd` fija sus `.import` (VRAM comprimida, mipmaps, compresión de normales en `*_normal.png`, `detect_3d/compress_to=0`) y `tests/test_character_visual.gd` comprueba que no falte ninguna.
- **Muchas piezas:** un script `EditorScenePostImport` en `tools/import/` asigna colisión y material de reino de forma uniforme.
- **Montaje:** una escena `.tscn` por pieza más snapping. Si se usa GridMap para los muros, guardar la MeshLibrary como .tres y vigilar su tamaño.
- **Escala:** comprobar cada pack contra la cápsula de 1,8 m. El Kenney Castle Kit casi seguro necesita reescalarse.

### 4.3 Esqueleto común y retargeting
1. **Personajes (Base, Outfits, Bestiary):** en *Advanced Import Settings* > `Skeleton3D` > *Retarget* > *Bone Map* hay que:
   - Crear un `BoneMap` con perfil `SkeletonProfileHumanoid` y revisar el mapeo automático.
   - Guardarlo como `assets/animations/rig/ual_humanoid_bone_map.tres` y reutilizarlo en todos los archivos de Quaternius.
   - Dejar activados *Rename Bones* y *Make Unique Skeleton* (nombre `GeneralSkeleton`), y en *Rest Fixer*: *Apply Node Transforms*, *Normalize Position Tracks* y *Overwrite Axis*.
   - Así todas las pistas apuntan a `GeneralSkeleton:<HuesoDelPerfil>` y las librerías sirven para cualquier humanoide.
2. **Archivos de animación (UAL1, UAL2, clips KayKit):** importarlos con *Import As: Animation Library*. Aplicar el mismo BoneMap y marcar el bucle en idle y en la locomoción.
   - En Godot cada uno queda como una librería del AnimationPlayer o AnimationTree, con prefijos `ual1/`, `ual2/` y `kaykit/`.
   - Al cargar UAL2 se comprueban los nombres de huesos frente a UAL1.
3. **Referencias:**
   - El `Humanoid_map.tres` del addon CC0 de Codeberg (jamesonBradfield/Quaternius_IK_Rigged_with_animations) sirve de guía; no hay que depender de él.
   - Hay un aviso conocido: el UpperChest se dobla demasiado al reasignar. Mapéalo igual en origen y destino, o déjalo sin mapear en ambos.
4. **Root motion:** usar las variantes **sin root motion**. El desplazamiento de la esquiva o la embestida lo calcula código compartido y determinista en `scripts/shared/`, para que coincidan la predicción del cliente y la autoridad del servidor.
5. **Servidor:** no reproduce animaciones. Las ventanas de golpe (anticipación, golpe activo y recuperación) y las formas del arco del arma son **datos** en `scripts/shared/`, no posiciones de huesos. Así se cumple la regla de que `scripts/shared` no dependa de `client`, y el rebobinado de hitboxes sigue siendo barato.

### 4.4 Recoloreado por reino
- Un shader `assets/materials/shaders/realm_surface.gdshader` con estos parámetros: textura de color, desplazamiento de tono, saturación, brillo, tinte, color y cantidad de capa (nieve o ceniza según la normal en espacio mundo) y emisión de brasas.
  - Con un `StandardMaterial3D` solo se puede multiplicar color, y eso solo oscurece. Para pasar de madera a caliza o a arenisca hace falta cambiar el tono.
- Materiales en `assets/materials/realms/{vardheim,solmarch,askarra,eldrun}/` (piedra, madera, tejado…), aplicados como override al instanciar piezas o desde el script de post-importación.
- Lo que el kit no tiene se modela en Blender con las texturas y la rejilla del kit, partiendo de los .blend de la Source, y va a `assets/models/environment/custom/`:
  - empalizada de troncos y torre de 2 plantas del fuerte;
  - puente de piedra y casas largas;
  - catedral y torres cónicas;
  - cúpulas y arcos de Askarra;
  - variantes en ruina.

### 4.5 Git LFS y reglas del repo
Añadir a `.gitattributes`. Ya cubre glb, bin, fbx, obj, blend, png, jpg, wav y ogg.
```
# Datos de región de Terrain3D (excepción a la regla de texto, ver CLAUDE.md)
*.res filter=lfs diff=lfs merge=lfs -text
# Binarios nativos de GDExtension (Terrain3D)
*.dll filter=lfs diff=lfs merge=lfs -text
*.so filter=lfs diff=lfs merge=lfs -text
*.dylib filter=lfs diff=lfs merge=lfs -text
```
Añadir a `.gitignore`: `*.zip`, `*.7z`, `*.blend1` y `addons/*/demo/`.

Los `.gltf` (JSON), `.import`, `.uid`, `.tres` y `.tscn` se versionan como texto.

Añadir en CLAUDE.md la excepción: "los `.res` de regiones de Terrain3D son la única excepción permitida al formato texto".

Cuota de LFS: los zips de prioridad 1 suman cerca de 1,1 GB. Subiendo solo el glTF usado, el repo debería quedarse en una fracción de eso. Comprueba la cuota de LFS de tu plan de GitHub antes del primer push grande.

### 4.6 Estructura de carpetas
```
addons/terrain_3d/  addons/proton_scatter/  addons/sky_3d/
assets/
  LICENCIAS.md
  animations/{rig,ual1,ual2,kaykit}/
  models/
    characters/{base,outfits}/
    enemies/{bestiary,huecos}/          # huecos = escenas propias del enemigo
    environment/{village,props,nature,castle_wall,custom}/
    weapons/binbun_rpg/
    blockout/kenney_castle/
  materials/{realms/<reino>/,shaders/}
  textures/terrain/{watercolor,polyhaven}/
  vfx/{binbun,kenney_particles}/
  audio/{sfx/<pack>/,ui/,ambience/}
scenes/world/zones/vado_gris/           # escena de zona + datos .res de Terrain3D
scenes/tests/style_test.tscn
tools/import/                           # scripts EditorScenePostImport
```

### 4.7 Servidor dedicado
- Al exportar, usar *Export as dedicated server* y marcar `assets/models`, `textures`, `vfx` y `audio` como *Strip Visuals*. **Nunca *Remove*** para nada que referencie una escena de zona (mallas de kit, `vado_gris_terrain_assets.tres`, materiales): las escenas de zona son compartidas y el servidor no podría cargarlas. El servidor necesita colisiones y escenas, no texturas. El preset `Servidor Linux` de `export_presets.cfg` (TEC-12) recorta `assets/models`, `materials`, `audio` y `animations`; las texturas del terreno (`assets/textures/terrain`) **no** se recortan, porque Terrain3D valida el formato de cada textura de sus assets y registra un error por cada una recortada (el servidor funciona igual, pero con 28 líneas de error al arrancar), y por eso ese preset exporta texturas con S3TC.
- Tras cargar la zona, el servidor llama a `ZoneRoot.strip_for_server()` (`scripts/world/zone_root.gd`): libera mallas, MultiMesh, luces y entorno y vacía el instanciador de Terrain3D, y conserva colisiones, terreno y marcadores. No se hace al detectar headless, porque las pruebas y el cliente sin ventana también corren headless.
- Sky3D, los VFX, el audio y la hierba se instancian solo desde `scenes/client/`.

### 4.8 Riesgos y huecos

| Riesgo | Mitigación |
|---|---|
| Todo lo de Quaternius y Binbun se baja de itch a mano; las copias de OpenGameArt y Godot Asset Store están **desactualizadas** (huesos anteriores a la v2.0). | Descarga humana desde itch y versión anotada en LICENCIAS.md. |
| No se sabe si el strafe viene en UAL1 Pro (revisado hoy, sin aclarar). | Confirmarlo en el devlog o en las imágenes antes de pagar; si no, comprar Source. |
| UAL2 podría no tener el mismo esqueleto que UAL1. | Comparar los nombres de huesos al importar. El BoneMap común absorbe diferencias pequeñas. |
| **Huecos:** no se sabe si el Bestiary trae esqueleto, y es QAL. | Plan B: mientras tanto, un cuerpo base con el traje Peasant, material de hueso gris desaturado y ojos emisivos. A medio plazo, modelar un esqueleto sobre el rig UAL a partir de la Source de Base Characters. Si el repo se hace público, sacar lo que sea QAL. |
| No hay arco, impacto en bloqueo ni esquiva direccional gratis en el rig UAL. | Retargetear clips de KayKit Character Animations (pueden verse exagerados). Último recurso: Mixamo (ver sección 5). |
| Terrain3D en headless no está documentado; además trae `.res` binarios y DLL. | Prueba al principio (sección 3). Plan B: HTerrain. Excepción en CLAUDE.md y LFS. |
| Sky3D: estrellas CC BY 4.0 y luna de procedencia dudosa. | Acreditar a ESO/S. Brunier o cambiarlas por estrellas CC0. Sustituir MoonMap.png antes de publicar. |
| Demo de ProtonScatter con texturas de Textures.com. | No versionar `demo/`. |
| Castle Wall Kit: autor pequeño y reciente, solo ladrillo, versión de Godot sin indicar. | Usar el glTF, retexturizar y validar en la escena de prueba de estilo. |
| No se ha verificado la lista de armas de asedio del Kenney Castle Kit. | Revisar el zip. Solo es blockout; el asedio final (fase 7) será modelado propio. |
| El CC0 de Still North se apoya en una cita archivada. | Riesgo bajo; elegir pocos clips y anotar la procedencia. |
| Rendimiento: 13.000 triángulos por personaje más varias piezas de ropa, cada una con su draw call. | LOD automático (comprobar que se aplica a las mallas con skin). Personajes remotos con piezas fusionadas en Blender por preset. Medir en la zona de guerra desde la fase 2, como pide vision.md. |
| Estilos que pueden chocar: Watercolor, Binbun y Castle Wall Kit. | La escena de prueba de estilo es la puerta de entrada. |
| Precios con oferta o contradictorios (Binbun Pro a 3,99 o 7,99 $). | Comprobarlos al comprar. |

### 4.9 Modelado propio con Blender: la espada

Primera pieza de arte final hecha en casa (ART-06), y la plantilla para las siguientes (escudos, arco, armas de PNJ). Todo se modela por script, sin abrir la interfaz, y el script es lo que se versiona; el GLB sale de él.

- **Cómo se regenera.** `blender --background --factory-startup --python tools/blender/build_sword.py` (Blender 5.2) y después `godot --headless --path . --import`. Escribe `assets/models/weapons/sword_base.glb` y una variante por reino (`sword_vardheim.glb`: lobo y cuero azul; `sword_solmarch.glb`: guarda de sol, oro y cuero blanco; `sword_askarra.glb`: bronce, cuero carmesí y yunque con brasas) que comparten exactamente la misma hoja (lo comprueba `tests/test_sword_model.gd`).
- **Texturas por código.** `tools/blender/sword_textures.py` (numpy, sin fotos) genera acero con degradado y brillo de filo, cuero con la sombra entre vueltas pintada y un atlas de metal; cada una con su textura de metálico y rugosidad (G y B de una sola imagen, como pide glTF). Los GLB las llevan dentro y su `.import` las deja embebidas (`gltf/embedded_image_handling=3`) para no llenar el repo de PNG sueltos.
- **Convención de las armas.** Origen en el centro de la empuñadura, hoja por +Y, ancho por X, caras planas hacia ±Z, 1 unidad = 1 m. Dos mallas, `Sword_LOD0` (unos 2.900 triángulos) y `Sword_LOD1` (unos 750), y dos marcas, `TrailBase` y `TrailTip`, para la estela del golpe. Las vueltas del cuero y la acanaladura están en la geometría del LOD0.
- **Metal.** Con el cielo gris del Vado Gris un metal puro (metálico 1) refleja un gris liso y no se ve la forma, así que el acero va con metálico 0,7 a 0,8 y el contraste lo pinta el albedo (acanaladura oscura, bisel claro). Es una decisión de estilo, no un descuido.
- **En el juego.** `scripts/client/sword_model.gd` (`SwordModel`) carga y reparte los LOD con los rangos de visibilidad; `WeaponProps` cuelga el modelo de la mano (`SWORD_GRIP_ROTATION_DEG` y `SWORD_GRIP_OFFSET` son el agarre) y deja la caja si el GLB no carga. `scenes/tests/sword_preview.tscn` hace las fotos del modelo con la luz del Vado Gris y `tools/render/sword_hero_shots.gd` captura al héroe en reposo, golpeando y bloqueando.

---

## 5. Lo que NO recomiendo y por qué

- **Mezclar familias.** Personajes KayKit con entorno Quaternius, o al revés, choca en proporciones (chibi frente a heroico), en texturas (atlas de degradado frente a texturas) y en esqueleto. KayKit solo entra como fuente de clips de animación retargeteados.
- **KayKit como familia entera.** Está muy bien resuelto, pero no tiene castillo ni aldea a escala humana. El Medieval Hexagon es una miniatura de tablero, útil como mucho para un mapa estratégico. Y el tono chibi se aleja de New World. Es el plan B solo si la animación de Quaternius resultara inviable, y habría que cambiar todo a la vez.
- **Kenney Castle Kit, Fantasy Town Kit y Nature Kit como arte final.** Son colores planos con aspecto de juguete. El Nature Kit además usa muchos materiales sin atlas. Solo sirven para blockout.
- **Las copias antiguas:** UAL en OpenGameArt o Godot Asset Store (anteriores a la v2.0), KayKit "(Legacy) Character Animations" y las v1.0 de KayKit en GitHub y AssetLib.
- **Packs antiguos de Quaternius:** el RPG Character Pack (2020) tiene un rig antiguo incompatible. Las LowPoly Medieval Weapons tienen colores planos, no traen glTF y la página da 22 o 24 modelos según dónde se mire.
- **Kenney Mini Characters y Animated Characters:** rig de 7 articulaciones y estilo de bloques.
- **Mixamo, salvo como último recurso.** No es CC0, exige un Adobe ID y prohíbe distribuir los FBX originales. El FAQ oficial no se pudo leer (devolvía 403). Si se usa, solo con el repo privado y sin publicar los archivos originales.
- **Sonniss GDC Bundle:** prohíbe redistribuirlo "as sound effects" y prohíbe entrenar IA con él (delicado con agentes de IA en el flujo de trabajo), y ocupa decenas de GB. **Leohpaz RPG Essentials:** no es CC0 y prohíbe redistribuir el pack.
- **GDQuest godot-4-VFX-assets:** el arte es CC-BY-NC-SA, es decir, no comercial. **REEBOO VFX** es MIT y legal, pero es un repo nuevo hecho con ayuda de IA: solo como referencia, con aviso MIT si se copia algo.
- **Spatial Gardener:** se rompe en Godot 4.5+ (issue #75, sin que se haya integrado el arreglo). **HTerrain** solo como alternativa. **TerraBrush** está en beta y **MTerrain** en alfa.
- **Simple Grass Textured:** se solapa con el instanciador de Terrain3D, guarda el MultiMesh y la imagen de alturas dentro del `.tscn` (escenas de texto enormes) y tiene un cuelgue abierto en 4.7.
- **Poly Haven y ambientCG como estilo principal:** son fotorrealistas. Solo para huecos (nieve, arena) y procesados.
- **Packs descartados por la investigación:** EmaceArt (licencia contradictoria), Avraman (archivos retirados por licencia), Cenji (de pago y no CC0; sin verificar), Gobkit (procedencia de IA), poly.pizza (estilos mezclados), Ultimate Fantasy RTS (escala RTS y sin texturas) y Explosive LLC RPG Animations (versión 0.1.0 inestable).

Fuentes de la nueva comprobación: [UAL1 en itch](https://quaternius.itch.io/universal-animation-library), [Bestiary en itch](https://quaternius.itch.io/bestiary-dungeon-monsters-kit) y [Bestiary en quaternius.com](https://quaternius.com/packs/bestiarydungeonmonsterskit.html). El resto de datos viene de la investigación verificada que recibí.