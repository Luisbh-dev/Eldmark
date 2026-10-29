# Vado Gris (fase 4)

> Primera zona real de Eldmark. Es la prueba de frontera de [mundo.md](../mundo.md): una versión
> comprimida del frente noroeste, con el fuerte del Vado Gris y las dos puertas a unos 150 m. Aquí
> se prueban la captura del fuerte, el kit, la escala, los materiales de reino y el terreno
> Terrain3D en cliente y servidor.

- **Escena:** `scenes/world/zones/vado_gris/vado_gris.tscn` (raíz `VadoGris`, script `ZoneRoot`).
- **Terreno:** 500 × 500 m en 2 × 2 regiones de 256 m de Terrain3D, un vértice por metro. Datos
  en `scenes/world/zones/vado_gris/terrain/` (los `.res` de región, por Git LFS).
- **Área jugable:** 300 × 300 m en el centro (x y z entre -150 y 150), cerrada por las dos
  murallas al norte y al sur y por paredes invisibles al este y al oeste. Fuera, unos 100 m de
  montañas y colinas que cierran el horizonte.
- **Coordenadas:** origen en el centro del fuerte, 1 unidad = 1 m, **norte = -Z**. Vardheim
  (Muro de Escarcha) al norte, Solmarch (Muralla del Alba) al sur.

## Trazado

### El río en herradura

El río rodea la colina del fuerte como un meandro: entra por el este, corre hacia el oeste por
el **brazo norte** (z = -62), da la vuelta alrededor de la colina por el oeste y vuelve al este
por el **brazo sur** (z = +62). El fuerte queda en la península del centro, que solo se toca por
el este, fuera del área jugable. Así **los dos reinos tienen que cruzar el río** para llegar al
fuerte, y lo cruzan en sitios equivalentes.

- **Dos puentes de piedra**, uno en cada brazo, justo en la línea recta puerta–fuerte (x = 0):
  la **ruta directa y estrecha**. Tablero de 4 m, 24 m de largo, pretiles de 0,95 m y un arco
  rebajado sobre el agua. Cada reino tiene el suyo, en espejo.
- **Un vado ancho y expuesto** en el vértice oeste de la curva (x = -62, z = 0), sobre el eje de
  simetría: unos 34 m de cauce entre los dos cierres del cauce, de los que los 28 m centrales
  tienen 0,3 m de agua sobre grava gris (el "vado gris"); en los 3 m de cada extremo el lecho baja
  hacia el cauce profundo. Orillas muy suaves (10°). Lo marcan dos hileras de postes de madera
  (sobre los 9 m centrales). Está a 40 m de la puerta del fuerte, sin cobertura, delante de la
  pasarela: es la **ruta ancha y expuesta**, la misma para los dos reinos.
- Fuera del puente y del vado el agua es profunda (1,6 m) y su borde no se cruza: una colisión
  baja corre a lo largo de las dos orillas (`Limites/OrillasProfundas`) y termina justo en la cara
  exterior de cada puente, y dos paredes cierran el cauce a los dos lados del vado (`CierreCauce*`),
  así que por el lecho profundo no se va del vado a los puentes. Sobre los pretiles de los puentes
  hay un bloqueo invisible de 1,7 m (`BloqueoSalto`): no se puede saltar al cauce. El agua es solo
  visual; en el vado se pisa el lecho del terreno.
- Los bloqueos invisibles (límites del área jugable, orillas, cierres del cauce y pretiles) están
  en la **capa 3** (`PlayerCharacter.PLAYER_BLOCKER_LAYER`), que mira el personaje pero no la
  cámara: junto a una orilla o una pared invisible la cámara no se pega a la cabeza.

### El fuerte

Sobre una colina baja (meseta a 10,2 m, 6 m por encima del valle, laderas de 12–18°):

- **Empalizada de troncos** de 40 × 40 m y 4,6 m de alto, con puntas.
- **Pasarela** interior de 2 m de ancho a 3,35 m de altura (el parapeto queda a 1,3 m, a la altura
  del pecho, y el pivote de la cámara por encima de las puntas) y **dos rampas** de madera de unos
  26°, una al norte y otra al sur (simétricas), al este de la torre. La pasarela pasa por encima
  del vano de la puerta (sin pies derechos en el vano).
- **Puerta de madera** de 4 m en la cara oeste, mirando al vado: dos hojas de tablones con flejes
  de hierro, cuadradas hasta el dintel. Es su propia escena (`FortGate`, grupo `fort_gate`, script
  `scripts/world/fort_gate.gd`) para que tenga vida y se rompa a golpes (docs/fuerte.md, §3).
  **Se guarda cerrada** y con dos cuerpos: el propio nodo es el de **movimiento** (capas de reino
  5 a 7: Vardheim, Solmarch y Askarra, menos la del dueño; neutral, las tres) y su hijo `Vista` es
  el de **vista** (capa 4, «estructuras»), que ven la cámara, la línea de visión de los golpes y
  el horneado de la navegación pero no el movimiento. Cada personaje de la simulación añade a su
  máscara la capa de su reino con `PlayerCharacter.set_realm_collision()`, así que la puerta
  cerrada para a los enemigos del dueño y deja pasar a los suyos; rota (`set_state(dueño, true)`),
  los dos cuerpos se quedan sin capas y las hojas cuelgan abiertas. Un personaje sin capa de
  reino (el modo sin red, `F5` sin argumentos) no la nota: sigue pudiendo entrar al patio, las
  rampas, la pasarela y el círculo.
- Patio: cajas de la vieja guarnición en espejo norte-sur (las dos pilas dan el mismo atajo a la
  pasarela) y una hoguera sobre el eje, al este de la torre. Dos estandartes neutrales flanquean la
  puerta por fuera.
- **Torre central de piedra** de dos plantas (6 × 6 × 12 m, terraza almenada) con el mástil del
  estandarte neutral (gris hueso, `faction_color` por instancia).
- El nodo `Fuerte` es el **nodo de la fortaleza**: está en el grupo `fortresses` y lleva el metadato
  `definition` con la ruta de `data/fortresses/vado_gris.tres` (`FortressDefinition`, id
  `vado_gris_fort`). Sus hijos son los marcadores que lee el controlador del fuerte:
  - `CaptureCircle` (grupo `capture_points`; metadato `radius` = 5 m, el único sitio de donde sale
    el radio; centro en x = -8,5, entre la puerta y la torre, con el borde a 0,5 m de la torre),
    `CaptainSpawn` (dentro del círculo) y cuatro `GuardSpawn` (patio, fuera del círculo).
  - `FortGate` y los estandartes `Estandarte` (torre), `EstandartePuertaN` y `EstandartePuertaS`.
  - Seis marcadores de **patrulla** (grupo `patrol_points`, metadato `route`, en orden de escena
    dentro de cada ruta): `hollow_north` (`PatrolNorth1..3`) y `hollow_south` (`PatrolSouth1..3`),
    del patio por la rampa norte o sur a la pasarela y por ella hacia la puerta.
  - Cinco **generadores de PNJ** (`NpcSpawner`, `scripts/world/npc_spawner.gd`, grupo
    `npc_spawners`, solo datos): `HollowSpawner1..4` en los `GuardSpawn` (id `hollow`, activos con
    el fuerte neutral, grupo de alerta `vado_gris_hollows`; los dos del este, junto a las rampas,
    patrullan por `hollow_north` y `hollow_south`) y `FordCaptainSpawner` en el `CaptainSpawn` (id
    `ford_captain`, mismo grupo de alerta). No reaparecen uno a uno: los repone la fortaleza. La
    guarnición del reino dueño (condición `fort_owner`) la añade el paquete de PNJ.

### Murallas, puertas y campamentos

- **Muro de Escarcha** (z = -152) y **Muralla del Alba** (z = +152): fachada de 12 m de alto más
  almenas, con la puerta en el centro entre dos torres de 18 m. La muralla sigue 180 m a cada
  lado y se hunde en las montañas.
  - Vardheim: piedra gris fría con nieve en las caras que miran arriba, cadalsos de madera casi
    negra en las torres y en tramos alternos de la muralla, estandartes azul hielo. Torres cada
    48 m.
  - Solmarch: caliza crema con musgo, torres cada 36 m con tejado cónico de pizarra azul y
    remate dorado, estandartes de oro. Rastrillo dorado.
- **Campamento** delante de cada puerta (radio 24 m, llano): tiendas, cajas, carro, vallas,
  hoguera y dos estandartes que marcan su borde. Los cuatro **puntos de aparición** de cada reino
  están en el campamento (x = ±2,5 y ±7,5, a 14 m de la muralla) y miran al fuerte.
- **Puntos de reaparición** (`RespawnPoints`, grupo `respawn_points`): doce marcadores en un
  **orden de escena que no se debe alterar** (es el índice que usan cliente y servidor):
  `CampamentoVardheim1..4` y `CampamentoSolmarch1..4` (en el sitio de los puntos de aparición,
  metadato `realm`) y después `FuerteVadoGris1..4` (patio del fuerte, a 11 m al este de la torre,
  fuera del círculo y mirando a la puerta; metadato `fortress` = `vado_gris_fort` y sin `realm`,
  porque valen para el reino que sea dueño del fuerte). Mientras la zona no pida más, la lista de
  un reino son solo sus campamentos.
- **Guardianes de la Puerta** (`NpcSpawners/GateGuardian<Reino>1..2`): dos generadores `NpcSpawner`
  por campamento (id `gate_guardian`, siempre activos, reaparición de 30 s, grupo de alerta
  `camp_<reino>`) a los lados de la puerta de su muralla (x = ±11, a 9,5 m de la muralla), dentro de
  su zona segura.
- **Zona segura** de cada campamento (`SafeAreas/CampamentoVardheim` y `CampamentoSolmarch`, un
  `Marker3D` del grupo `safe_areas` con los metadatos `realm` y `radius = 24`): centrada en el centro
  de los cuatro puntos de aparición de su reino (x = 0, z = ∓138) y con el radio del campamento.
  **Solo protege a su reino** (docs/combate.md, sección 5): dentro de ella un jugador de ese reino ni
  recibe ni hace daño, y un intruso enemigo sí es dañable (lo lee el `CombatResolver`).
- **Maniquí de entrenamiento** junto a cada campamento (`DummyPoints/MunecoVardheim` y
  `MunecoSolmarch`, un `Marker3D` del grupo `dummy_points` a 30 m del centro de la zona segura, es
  decir, fuera de ella, mirando al campamento): el servidor coloca en cada marcador un PNJ inmortal
  del bando neutral que se cura a los 5 s sin daño (`ZoneServer.spawn_zone_dummies()`; en
  `ServerMain`, salvo con `--no-dummies`). El mundo de pruebas lleva uno en `DummyPoints/Dummy1`.

### Ruinas del viejo Eld

- **Aldea de Eld** en la orilla oeste, a ambos lados de la vieja calzada que llega al vado:
  seis casas en ruinas por lado (en espejo), con muros derrumbados a distintas alturas (o se saltan,
  con la cima a 1,2 m o menos, o tapan, a 1,9 m o más), algunos vencidos, remate de piedra en vez de
  durmiente de madera, suelos rotos, una chimenea y escombros al pie de los muros caídos. Las
  puertas no se hunden: el dintel queda a más de 2 m. Dan cobertura a quien se acerca al vado. La
  vieja calle acaba antes del borde oeste en dos pilares de una puerta caída y escombros.
- **Capilla** en ruinas en la península, al este del fuerte, sobre el eje: muros laterales con
  ventanas, puerta al oeste, cabecera hundida y dos pilares.

### Vegetación y borde

- **Cobertura de juego** (con colisión, guardada en la escena): bosquetes de pinos al norte y de
  caducifolios al sur, árboles muertos sueltos en la franja central (Eldrun) y grupos de rocas.
  Se generan en la mitad norte y se reflejan: **las mismas 50 colisiones de tronco y 17 de roca
  en cada mitad**, en las mismas posiciones.
- **Decorativa** (instanciador de Terrain3D, sin colisión): unas 51.000 matas de hierba (visibles
  hasta 60 m), arbustos en las orillas y losas de la vieja calzada.
- **Borde:** montañas de pinos y roca detrás del Muro de Escarcha (hasta 80 m de altura, con un
  paso detrás de la puerta), colinas suaves de caducifolios detrás de la Muralla del Alba y
  montañas a los lados que empiezan 15 m dentro del área jugable (la pared invisible queda en una
  ladera de unos 40°, no en mitad del prado). Bosque en grupos que sube por las laderas de hasta
  62°, cada vez más claro (coníferas a 1,5–2,2 veces el modelo del kit), canchales de rocas en las caras más
  empinadas y relieve fino en las laderas. El río sale por el este entre dos lomas.

### Mapa

Vista cenital esquemática, norte arriba. Cada columna son 5 m en X y cada fila 10 m en Z (por eso
el fuerte, de 40 × 40 m, sale ancho y bajo).

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

`#` muralla (`H` puerta) · `S` puntos de aparición · `c` campamento · `.` calzadas · `~` río ·
`=` puente · `:` vado · `P` empalizada (`G` puerta del fuerte) · `T` torre · `r` ruinas ·
`^` pinos · `o` caducifolios · `*` árboles muertos. Norte arriba: Vardheim; sur abajo: Solmarch.

## Rutas, distancias y equidad

Medido con `tools/terrain/verify_vado_gris_routes.gd`: un `PlayerCharacter` real corre (5 m/s,
sin esprintar) desde un punto de aparición hasta la explanada de la puerta del fuerte. Los puntos de
paso de cada ruta y reino son datos compartidos, `data/routes/vado_gris.tres` (`ApproachRoutes`,
`scripts/shared/war/approach_routes.gd`), que escribe `tools/terrain/export_vado_gris_routes.gd` (las de
Solmarch son el reflejo exacto de las de Vardheim) y que leen la verificación y los bots de asedio.

| Ruta | Recorrido | Vardheim | Solmarch | Diferencia |
|---|---|---|---|---|
| Puente (directa, estrecha) | Campamento → puente propio → ladera → esquina del fuerte → puerta | 148,9 m · 30,1 s | 148,9 m · 30,1 s | 0,00 % |
| Vado (ancha, expuesta) | Campamento → llanura del flanco oeste → aldea → vado → puerta | 236,5 m · 47,8 s | 236,5 m · 47,8 s | 0,00 % |

- En línea recta, cada puerta está a 152 m del centro del fuerte.
- El puente ahorra unos 18 s pero es un embudo de 4 m de ancho que los defensores cubren desde la
  pasarela norte o sur. El vado es más largo, pero ancho (34 m), con cobertura en la aldea hasta
  la orilla y luego 40 m al descubierto ante la puerta.
- El mismo script comprueba que el río **no** se puede cruzar por otros sitios (brazos este y
  curvas noroeste y suroeste): el personaje se queda en la orilla.

Por qué es justo:

- **Simetría de espejo norte–sur** (z → -z) de todo lo que afecta al juego: alturas del área
  jugable (el ruido del relieve se suma con su reflejo, así que no hay costura en el eje), río,
  puentes, calzadas, campamentos, zonas seguras, maniquíes, puntos de aparición, ruinas y colisiones de
  árboles y rocas.
  Solo cambian los modelos (pinos al norte, caducifolios al sur) y los materiales de cada reino.
- Lo que no tiene pareja está **sobre el eje** y es común a los dos: el fuerte, su puerta, el
  vado, la calle de la aldea y la capilla.
- Cada reino tiene **las dos rutas**: su propio puente (equivalente simétrico) y el mismo vado.
- **Luz:** el sol viene exactamente del oeste (a lo largo de +X), así que no da de lleno en
  ninguna de las dos fachadas de muralla (miran a +Z y a -Z); las dos reciben la misma luz de dos
  rellenos simétricos sin sombra, uno desde el sur y otro desde el norte, con la misma energía.

## Técnica

- **Colisión de Terrain3D `FULL_GAME`** (modo 3) en la capa 1, igual en cliente y servidor.
  `ZoneRoot` (`scripts/world/zone_root.gd`) desactiva el `_physics_process` de Terrain3D al
  cargar (sin cámara daría un error en el servidor) y, en el cliente, en cuanto hay cámara se la
  asigna al terreno y lo reactiva para que el clipmap la siga. También da
  `get_spawn_points(realm)`.
- **Todas las colisiones están guardadas en la escena** (capa 1, salvo la puerta del fuerte, que
  usa las capas 4 y 5 a 7): terreno, empalizada, pasarela, rampas, torre, puentes (forma cóncava del tablero y los pretiles), murallas, torres,
  tiendas, cajas, carros, vallas, hogueras, ruinas, postes del vado, troncos y rocas (cilindros),
  orillas profundas y límites invisibles. Nada se dispersa en tiempo de ejecución.
- **Instancias repetidas solo visuales** (troncos de la empalizada, hiladas de las murallas,
  postes) con `BakedMultiMesh` (`scripts/world/baked_multimesh.gd`): guarda las transformaciones
  en la escena como texto, porque en headless el búfer de un `MultiMesh` no se guarda.
- **Materiales de reino:** un solo shader, `assets/materials/shaders/realm_surface.gdshader`, que
  recolorea la textura del kit (tono, saturación, brillo y "colorear" hacia el color objetivo de
  la paleta de mundo.md conservando el detalle), añade la capa de las caras que miran arriba
  (nieve en Vardheim, musgo en Solmarch, ceniza en Eldrun) y el color de bando por instancia
  (`instance uniform faction_color`). Con `StandardMaterial3D` solo se puede multiplicar, y eso
  no pasa de ladrillo gris a caliza crema ni de teja roja a pizarra azul. Los materiales están en
  `assets/materials/realms/{eldrun,vardheim,solmarch}/` y salen de
  `tools/materials/build_realm_materials.gd`.
- **Agua:** `assets/materials/shaders/water.gdshader`, color por profundidad leída del búfer de
  profundidad (vado claro, cauce oscuro), espuma en orillas y postes, ondas que corren a lo largo
  del río. La malla es una cinta a lo largo del cauce (`vado_gris_river_water.tres`).
- **Ambiente:** `assets/environments/vado_gris_frontier.tres`: cielo cubierto de la frontera de
  Eldrun (degradado gris con una capa de nubes procedural, `sky_cover`), niebla de 0,0015 más algo
  de niebla baja, SSAO y saturación al 88 %. Sol del oeste a 32°, blanco frío y velado (1,2), con
  sombras blandas de 2 cortes hasta 120 m, y los dos rellenos norte y sur (0,42) sin sombra.
- **Texturas del terreno:** la tierra de acuarela (Dirt_03, un pardo rojizo muy saturado que se
  veía casi negro) se corrige al copiarla (`copy_vado_gris_assets.gd`: tono +9°, saturación ×0,6,
  valor ×1,35) hacia la tierra quemada y la ceniza de Eldrun. Las calzadas tienen un núcleo de
  grava gris que pasa a tierra y se funde con la hierba en un borde roto por ruido, con mezcla
  fraccionaria; el material de Terrain3D usa `blend_sharpness` 0,45 y variación de color a gran
  escala.
- **Hierba:** en matas agrupadas por ruido (prado y claros, sin hileras), con material
  `realm_surface` que la desatura hacia un verde gris y un pajizo de Eldrun.
- **Losas de la calzada:** se inclinan con el terreno y se hunden hasta quedar a ras; en
  pendientes de más de 7° no se ponen.
- **Todo en una escena por ahora.** El servidor dedicado quita la capa visual al cargarla con
  `ZoneRoot.strip_for_server()` (probado en `test_vado_gris_zone.gd`). La separación en
  `vado_gris_gameplay.tscn` y `vado_gris_visual.tscn` de mundo.md queda pendiente (ver más abajo).

### Rendimiento medido

`tools/render/render_screenshot_points.gd` a 1600 × 900, Forward+, sin vsync, en una RTX 5090
Laptop (no es la GPU de gama media del presupuesto; sirve para comparar vistas):

| Vista | FPS | Llamadas de dibujo | Primitivas |
|---|---|---|---|
| Desde la puerta de Vardheim | 382 | 520 | 0,91 M |
| Desde la puerta de Solmarch | 385 | 530 | 0,84 M |
| Fuerte de cerca | 389 | 514 | 0,97 M |
| Puente norte | 350 | 694 | 1,10 M |
| Vado | 338 | 681 | 1,18 M |
| Ruinas de la aldea | 347 | 781 | 1,19 M |
| Muralla de Vardheim | 466 | 645 | 0,60 M |
| Campamento de Solmarch | 437 | 606 | 0,82 M |
| Vista aérea | 481 | 336 | 0,55 M |
| Puerta del fuerte | 546 | 509 | 0,95 M |

Todas muy por debajo del presupuesto de mundo.md (2000 llamadas, 2 M de triángulos). Respecto a la
primera versión de la zona, las llamadas de dibujo bajan a la mitad: sombras de 2 cortes hasta
120 m (antes 4 hasta 190 m), 8 variantes de árbol en vez de 12, arbustos sin sombra, suelos y
escombros de las ruinas en MultiMesh, piedras de hogueras y escombros fundidas en una malla,
distancia de dibujo en las piezas pequeñas y troncos y lonas con cull_back. Las texturas de los
kits van comprimidas (BPTC/S3TC) con mipmaps en vez de RGBA sin comprimir, y cargar la zona
headless cuesta ahora unos 72 MB de memoria estática (antes unos 150 MB).

## Jugar en la zona

Es la zona por defecto del cliente (`Zones.DEFAULT_ZONE` en `scripts/shared/zones.gd`):

```
godot --path . -- --realm=vardheim     # o --realm=solmarch
godot --path . -- --zone=vado_gris --demo --shots=<ruta absoluta> --quit-after-demo
```

- El jugador aparece en el primer punto de aparición de su reino (`Vardheim1` o `Solmarch1`),
  mirando al fuerte.
- La demo (`RouteDemoInput.vado_gris()` en `scripts/client/route_demo_input.gd`) sigue la ruta
  del puente de `verify_vado_gris_routes.gd`: campamento, calzada con esprint y salto, puente
  propio, dos saltos al pie del fuerte, paso lateral, esquina de la empalizada, explanada de la
  puerta y vuelta de cámara. Dura unos 1970 ticks (33 s) y Solmarch recorre el reflejo exacto.
- Con `--shots` también guarda, al final, una captura sin HUD desde cada marcador de
  `ScreenshotPoints` (`zona_<nombre>.png`).

## Cómo regenerar

Con el editor cerrado, desde la raíz del proyecto (`godot` es el ejecutable de consola):

```
godot --headless --path . -s res://tools/assets/copy_vado_gris_assets.gd     # copia y reescala desde ../Eldmark-raw
godot --headless --path . --import
godot --headless --path . -s res://tools/assets/extract_kit_meshes.gd        # mallas de kit a .tres
godot --headless --path . -s res://tools/materials/build_realm_materials.gd  # materiales de reino y agua
godot --headless --path . --import
godot --headless --path . -s res://tools/props/build_vado_gris_props.gd      # scenes/world/props/ (fuerte, puerta, marcadores de PNJ)
godot --headless --path . -s res://tools/terrain/generate_vado_gris.gd       # terreno + vado_gris.tscn
godot --headless --path . -s res://tools/bake_navmesh.gd                     # vado_gris_navmesh.tres (2 s)
```

Comprobaciones:

```
godot --headless --path . -s res://tests/run_tests.gd                         # incluye test_vado_gris_zone.gd
godot --headless --path . --fixed-fps 60 -s res://tools/terrain/verify_vado_gris_routes.gd
godot --path . -s res://tools/render/render_screenshot_points.gd -- --out=<ruta>/build/vado_gris
```

- Hay que volver a hornear la malla de navegación de los PNJ (`tools/bake_navmesh.gd`, ver
  docs/fuerte.md 4.1) cada vez que cambia la geometría de juego: rampas, pasarela, puerta, puentes,
  murallas, bloqueos... `tests/test_navmesh.gd` lo recuerda con rutas rotas.
- Los dos primeros pasos solo hacen falta si cambian los assets. Para cambiar el trazado se edita
  `tools/terrain/vado_gris_layout.gd` (posiciones, río, calzadas, función de alturas) y se
  vuelve a lanzar el generador; la vegetación, la pintura y las escenas de piezas, en sus scripts.
- Todo es determinista (semillas fijas): repetirlo en la misma máquina deja los mismos datos de
  región, malla del agua y assets del terreno, byte a byte. En las escenas `.tscn` solo cambian los
  `unique_id` que Godot asigna a cada nodo al guardar. Entre plataformas (se generó en Windows y se
  ha repetido en Linux) hay ruido: los `.res` de región y la malla del agua salen con otros bytes y
  las escenas con diferencias de la última cifra decimal en algunas transformaciones (seno y
  coseno), además de los identificadores de recurso. Si el cambio no toca el terreno, se restauran
  del repositorio los `.res` y la malla del agua, y de las escenas regeneradas se descartan los
  identificadores y el ruido para que el diff solo lleve lo que cambió de verdad.
- **No se edita `vado_gris.tscn` a mano:** el generador la reescribe entera.

## Pendientes

- Separar capa de juego y capa visual (`_gameplay.tscn` / `_visual.tscn`). Mientras tanto el
  servidor carga la escena entera y luego llama a `ZoneRoot.strip_for_server()`.
- Desde la pasarela, con el parapeto a 1,3 m, la franja de unos 8 m al pie de la empalizada sigue
  sin verse salvo asomándose en las esquinas: falta una plataforma sobre la puerta.
- Piezas propias en Blender con las texturas del kit (mundo.md/arte.md): la empalizada y el puente
  son mallas propias generadas por script; la torre del fuerte y las murallas usan el Castle Wall
  Kit, y las tiendas son prismas. Cuando llegue la Source del Village MegaKit, sustituirlas.
- La puerta del fuerte está cerrada pero aún sin vida: falta la lógica de la fase 4 (vida, golpes y
  reparación, `FortressController`) y los estados de rotura de las hojas (ART-17).
- Los estandartes son la bandera del Kenney Castle Kit (blockout) recoloreada.
- Sin viento en la vegetación, sin LOD propio de los árboles (solo el automático) ni HLOD.
- Los braseros de las calzadas (estado de las Líneas de Brasa) aún no existen.
- El borde del agua es una colisión invisible; cuando haya nado, sustituirla.
