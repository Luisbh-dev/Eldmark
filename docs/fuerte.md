# Eldmark · Fase 4: diseño del fuerte capturable

Diseño del paso 4 de la [hoja de ruta](vision.md#hoja-de-ruta): el primer objetivo jugable, el
fuerte del Vado Gris disputado entre Vardheim y Solmarch ([mundo.md](mundo.md),
[zona](zonas/vado_gris.md)). Se apoya en la red ([red.md](red.md)) y el combate
([combate.md](combate.md)).

Versión 2, tras una revisión escéptica que comprobó en Godot 4.7.2 y Terrain3D 1.0.2 los supuestos
técnicos (navegación, capas de colisión, mapa sin GPU) y cerró los huecos de las reglas de captura,
el protocolo y los contratos.

Dos bloques:

1. **El bucle del fuerte** (este documento): estado, captura, puerta, defensores PNJ con IA,
   avisos, reaparición en el fuerte, mapa y HUD de captura, y bots que asedian.
2. **La ampliación del combate** (§10): habilidades, arco, cambio de arma, efectos de estado y
   derribado, con su propio diseño corto (`docs/habilidades.md`).

---

## 0. Decisiones

Provisionales, tomadas de noche, de las recomendaciones de [backlog.md](backlog.md#decisiones-pendientes):

| Pregunta | Decisión |
|---|---|
| Círculo vacío | Tras 5 s sin nadie dentro, el progreso decae a un tercio de la velocidad base. |
| Recaptura inmediata | No: 2 min de consolidación (círculo inactivo, puerta dañable) hasta que llega la guarnición. |
| Arquitectura de IA | Máquina de estados jerárquica propia, parámetros en `NpcDefinition`. |
| Modelo de los Huecos | Plan B (cuerpo base, material de hueso); de momento, el humanoide con un material gris. |
| Campamento | Zona segura solo para su reino (combate.md §5) y dos Guardianes de la Puerta. |
| Estructura de partida | En pruebas, el fuerte vuelve a neutral cada 30 min. |
| Minimapa | Imagen cenital horneada sin GPU; enemigos solo si se revelan. |
| Méritos y puntos de reino | Dos contadores con el mismo evento (PRG-09); en la fase 4 solo se cuentan para el marcador. |
| Recurso de las habilidades | Solo reutilización en las armas físicas. |
| Proyectiles | Rayo de cámara canónico desde yaw, pitch y un bit de hombro. |
| Derribado | En PvP; muerte directa en PvE en solitario. |
| Colisión entre personajes | Sigue sin haber; el vano de la puerta rota no se puede taponar con el cuerpo. Se revisa con la telemetría de GUE-17. |
| Oleadas de reaparición | Cada 10 s (GUE-14). |

---

## 1. La fortaleza

### 1.1 Definición (GUE-07)

`FortressDefinition` (`scripts/shared/war/fortress_definition.gd`, `data/fortresses/vado_gris.tres`):

| Campo | Vado Gris |
|---|---|
| `id` | `&"vado_gris_fort"` |
| `capture_s` | 30 (con un atacante) |
| `decay_after_empty_s` | 5 |
| `circle_height_m` | 4 |
| `gate_health` | 9000 |
| `consolidation_s` | 120 |
| `captain_respawn_s` / `guard_respawn_s` | 300 / 180 |
| `under_attack_s` | 30 |
| `gate_repair_after_s` | 300 |
| `reset_to_neutral_s` | 1800 (solo en pruebas; 0 = nunca) |

El radio del círculo sale **solo** del metadato `radius` del marcador `CaptureCircle` (5 m).

### 1.2 Presencia en el círculo

Un jugador **está presente** si: vivo, no derribado, no desconectado (GUE-41), con una entrada real
en los últimos 60 s, y con los pies en el cilindro: distancia horizontal al centro ≤ radio y
`feet.y ∈ [centro.y − 1, centro.y + 4)` (el marcador está a ras de suelo; comprobado en la escena).
Los PNJ **no** cuentan. `presence` es un `PackedInt32Array` de 4 posiciones (reinos 0–3) con el
número de presentes.

### 1.3 Progreso en enteros

Progreso máximo `P = capture_ticks · 12` (30 s → 1800 ticks → 21 600). Velocidades en unidades por
tick, todas enteras: 1 atacante **12**, 2 **16**, 3 **20**, 4 o más **24**; decaimiento por vacío
**−4**; decaimiento cuando dentro solo hay no-captores **−24**. La captura viaja como fórmula
`progress(t) = clamp(p0 + rate · (t − t0), 0, P)`.

### 1.4 Estado (puro, en ticks)

`FortressState` (`scripts/shared/war/fortress_state.gd`, RefCounted, sin nodos):

`owner` (0 = neutral, Huecos), `phase` (`GARRISONED`, `VULNERABLE`, `CAPTURING`,
`CONSOLIDATING`), `phase_tick`, `captain_alive`, `captain_respawn_tick`, `guards_alive`,
`guards_respawn_tick`, `gate_health`, `gate_max`, `gate_last_damage_tick`, `capture_realm`,
`capture_start_tick`, `capture_rate`, `capture_progress_at_start`, `contested`, `empty_since_tick`,
`under_attack_until_tick`, `last_attack_notice_tick`, `last_contested_notice_tick`, `presence`
(los 4 recuentos, para la interfaz).

### 1.5 Tabla de decisión

Sea `A` el conjunto de reinos presentes distintos del dueño (atacantes) y `D` si hay presentes del
dueño (con un fuerte neutral, `D` es falso).

| Fase | Situación | Resultado |
|---|---|---|
| `GARRISONED` | muere el capitán (dueño o Huecos) | `VULNERABLE` |
| `VULNERABLE` | `A` = un reino y no `D` | `CAPTURING` con `capture_realm` = ese reino, `rate` según su número |
| `VULNERABLE` | `A` ≥ 2 reinos, o `A` y `D` | sigue `VULNERABLE`, `contested` |
| `VULNERABLE` | pasa `captain_respawn_s` sin captura | reaparece el capitán: `GARRISONED` |
| `CAPTURING` | solo el captor | `rate` = velocidad de su número |
| `CAPTURING` | captor y alguien más (dueño u otro reino) | `contested`, `rate = 0` |
| `CAPTURING` | sin el captor, con no-captores | `rate = −24` |
| `CAPTURING` | nadie, 5 s o más (`decay_after_empty_s`) | `rate = −4` (antes, 5 s congelado) |
| `CAPTURING` | progreso 0 y un único reino no dueño presente | ese reino pasa a ser el captor |
| `CAPTURING` | progreso 0 y ningún atacante | `VULNERABLE`, `capture_realm = 0` |
| `CAPTURING` | progreso `P` | `CONSOLIDATING`, `owner = capture_realm`, puerta reparada, PNJ del dueño anterior retirados |
| `CONSOLIDATING` | pasa `consolidation_s` | `GARRISONED` con la guarnición y el capitán del nuevo dueño |
| cualquiera | `reset_to_neutral_s` o comando `fort_reset` | `GARRISONED` neutral: Huecos y Capitán del Vado, puerta llena, progreso 0; los jugadores dentro no se mueven |

- Los guardias muertos reaparecen a los `guard_respawn_s` en `GARRISONED` y `VULNERABLE`.
- La «reaparición completa» de los Huecos (MUN-10) incluye al Capitán.
- `advance()` corre **cada tick** (las transiciones caen en ticks exactos); la presencia se recuenta
  cada 6 ticks (`s % 6 == 0`) y se mantiene entre recuentos.

### 1.6 Controlador (GUE-08, GUE-12)

`FortressController` (`scripts/server/war/fortress_controller.gd`) crea una `NetEntity`
`STRUCTURE` con `ALWAYS_RELEVANT` por cada nodo del grupo `fortresses` con metadato `definition`
(lo añade el generador, §8 F0), y en el paso 4b del tick (§1.7):

- recuenta la presencia, llama a `advance()`, aplica sus efectos (dueño, colisión de la puerta,
  retirada y aparición de PNJ) y emite OBJECT_STATE y avisos;
- los estandartes (`Estandarte`, `EstandartePuertaN`, `EstandartePuertaS`) se recolorean **solo
  en el cliente** (`FortressView`): el servidor no tiene mallas;
- comandos con ids fijos (`--debug-commands`): 8 `fort_reset`, 9 `fort_owner <reino>`, 10
  `fort_kill_captain`, 11 `fort_capture_speed <×>`. Sus datos, que valida
  `DebugCommand.decode` (F2): 8 y 10, ninguno; 9, `u8` con el reino (0 a 3); 11, `u8` con el factor
  (1 a 255).

### 1.7 Orden del tick (completa combate.md §4.2)

0. **Cerebros de PNJ**: con el estado tras `s − 1`, cada cerebro de PNJ (`HfsmBrain`, y el `NpcBrain`
   del maniquí) empuja su entrada de `s` a su `InputQueue` (el `HfsmBrain` piensa cada 6 ticks; entre
   medias repite su plan).
1. Simular a todos por `net_id` (jugadores, falsos y PNJ).
2. Congelar. 3. Resolver golpes (también contra las puertas, §3). 4. Aplicar resultados.
4b. `FortressController.step(s)`: presencia, `advance`, efectos. Los cambios de colisión de la
   puerta valen **desde `s + 1`** en el servidor y en el cliente.
5. Altas de jugadores y de PNJ, historial, snapshots, OBJECT_STATE y eventos.

---

## 2. Replicación con estado: OBJECT_STATE (GUE-09)

Ocupa el tipo `0x22` reservado en red.md §5.6 y sube **`PROTOCOL_VERSION`** (a 4: la 3 fue la revisión de la fase 3).

- **Formato**: `u8 type`, `u16 net_id`, `u32 tick` (el tick del servidor tras el que vale el
  estado), `u8 field_count` (1–32) y, por campo, `u8 field_id`, `u8 value_type` (1 u8, 2 u16, 3 u32,
  4 s32) y el valor. Canal fiable 3. Cabecera de 8 B; el estado completo de una fortaleza son 80 B.
- **Validación** (como red.md §5.7): `null` si el tamaño no cuadra, `value_type` desconocido,
  `field_count` fuera de rango o un campo repetido. Un `field_id` desconocido con tipo válido se
  salta (compatibilidad hacia delante).
- **Ritmo**: como mucho un OBJECT_STATE por fortaleza cada 6 ticks, con los campos cambiados en
  ese intervalo; `under_attack_until_tick` solo se envía si avanza al menos 60 ticks.
- **ENTITY_SPAWN de STRUCTURE**: payload `u8 def_len` (1–32), id de la definición (ASCII
  imprimible), `u8 field_count` (1–32) y los campos completos (sin repetir type, net_id ni tick). El
  `realm` de la cabecera es 0: manda el campo `owner`. Con el id del Vado Gris son 98 B.
- **ENTITY_SPAWN de NPC**: tras el `PlayerState` y el nombre, `u16 npc_def_id` (catálogo
  `NpcCatalog`, ids alfabéticos 1..n) para que el cliente elija modelo, tabardo y barra de jefe.
- El snapshot **no** lleva registros de `STRUCTURE`.
- **Campos del fuerte** (`FortressFields`, compartido): 1 owner, 2 phase, 3 phase_tick, 4
  captain_alive, 5 guards_alive, 6 gate_health, 7 gate_max, 8 capture_realm, 9
  capture_start_tick, 10 capture_rate, 11 capture_progress_at_start, 12 contested, 13
  under_attack_until_tick, 14–17 presencia por reino (u8).
- **Cliente**: `FortressView` (`scripts/client/war/fortress_view.gd`) guarda la historia de
  cambios. La **interfaz** y los estandartes los aplican cuando `render_tick` alcanza `tick`; la
  **colisión** de la puerta, no (§3).

---

## 3. La puerta (GUE-10)

### 3.1 Dos cuerpos

Sacar la puerta de la capa 1 rompería la línea de visión de los golpes, la cámara y el horneado
(comprobado). Por eso la puerta tiene dos cuerpos:

- **Movimiento**: `collision_layer` = capas de los reinos que **no** son el dueño (capas 5, 6 y 7
  para Vardheim, Solmarch y Askarra; las tres si es neutral). Cada `PlayerCharacter` añade a su
  máscara la capa de su reino con `PlayerCharacter.set_realm_collision(code)`, llamado **después**
  de `_ready()` (que reescribe la máscara).
- **Vista**: capa nueva 4, «estructuras», que entra en `HitShapes.LINE_OF_SIGHT_MASK`, en la
  máscara del `SpringArm3D` de la cámara y en el horneado de la navegación.

Rota (vida 0): los dos cuerpos sin capas. `FortGate.layers_for(owner: int, broken: bool) -> int`
(estática, compartida) da la capa de movimiento.

### 3.2 Predicción exacta

Un cambio de la puerta con `tick = s` vale desde `s + 1`. En el cliente, `ClientPrediction` gana
un gancho `before_simulate(t: int)` que `FortressView` usa para poner la capa de la puerta según su
historia de cambios **para el tick `t` que se simula**, también durante las repeticiones. Jolt
aplica un cambio de `collision_layer` en el siguiente `move_and_slide` del mismo tick
(comprobado), así que cliente y servidor simulan cada tick con la misma puerta.

### 3.3 Vida y reglas

- 9000 de vida, dañable por los enemigos del dueño (todos si es neutral). Multiplicadores contra
  estructuras (`CombatRules`, solo servidor): cortante ×0,35, perforante ×0,2, contundente ×1,0,
  elemental ×0,6. Con el combo de espada, tres atacantes la rompen en ~55 s (medido en F3: 54,8 s).
- **Blanco**: `HitShapes.sector_hits_box(origin, yaw, shape, box: Transform3D, half_extents:
  Vector3) -> bool`, en su posición actual, sin rebobinado ni críticos. El HIT lleva el `net_id` de
  la fortaleza. La línea de visión no cuenta la propia puerta. Golpearla pone «en combate» y
  actualiza `gate_last_damage_tick` y `under_attack_until_tick`.
- **Reparación** al cambiar de dueño, con `fort_reset` o tras 5 min sin daño, pero **no mientras
  un personaje solape el vano**: se aplaza tick a tick hasta que quede libre.
- Queda **cerrada por defecto** (corrige `docs/zonas/vado_gris.md`).

---

## 4. PNJ (MUN-06 … MUN-12, GUE-11)

### 4.1 Navegación (MUN-06)

`tools/bake_navmesh.gd` hornea con la puerta **cerrada**:

- geometría de Terrain3D con `generate_nav_mesh_source_geometry(aabb, false)` (con `true`, el valor
  por defecto, devuelve 0 caras porque no hay navegación pintada; comprobado);
- colisiones de las capas 1 | 3 | 4 (la 3 cierra el lecho profundo del río: con solo la 1 hay ruta
  por el lecho; comprobado);
- celda de 0,25 m y radio 0,4 (con celda de 0,5 el radio se redondea a 0,5 y la pasarela de 2 m
  deja 1 m útil);
- resultado en `scenes/world/zones/vado_gris/vado_gris_navmesh.tres` (texto).

Hecho en F0 (medido): se hornea en 2 s, el archivo pesa 0,3 MB (4223 vértices, 5930 polígonos) con
celda de 0,25 m (no hizo falta subirla a 0,3) y sale byte a byte igual en cada ejecución.
`tests/test_navmesh.gd` comprueba que desde cada `GuardSpawn` hay ruta a la pasarela (por las
rampas, sin salir), y, con un enlace por la puerta como el que crea el servidor, al vado y a los
dos puentes; que **sin el enlace no hay salida del fuerte**; que desde los campamentos se llega al
vado, a los puentes y a la explanada; y que el lecho profundo no se alcanza andando (hornear sin la
capa 3 lo rompe).

`NpcNavigation` (servidor, hecho en F4) crea un mapa propio de `NavigationServer3D` con **iteraciones
síncronas**, registra la región y un enlace por la puerta por RID (no desde la escena), y no da
rutas hasta que el mapa esté construido. **Comprobado en F0 (corrige lo anterior):** con
`map_set_use_async_iterations(false)` o sin ello, y con o sin `map_force_update`, la primera
iteración del mapa (`map_get_iteration_id(map) == 1`) sale **vacía** (las órdenes de la región se
aplican después) y las rutas buenas llegan unos pasos de física más tarde (iteración 2); consultar
el mapa antes de la primera sincronización registra un error del motor. Por eso `NpcNavigation`
tiene que esperar a que una consulta de prueba devuelva un punto de la malla (como
`_wait_for_map()` de `tests/test_navmesh.gd`), no solo a que `map_get_iteration_id(map) > 0`. El
enlace de la puerta está siempre activo, en la capa
de navegación del reino dueño; cada consulta (`NavigationPathQueryParameters3D`) filtra con
`navigation_layers` del reino del agente (inmediato, sin esperar iteraciones). API:
`get_path(from: Vector3, to: Vector3, realm: int) -> PackedVector3Array`.

### 4.2 IA (MUN-07, MUN-08)

- `NpcDefinition` (`scripts/shared/ai/npc_definition.gd`, datos en `data/npcs/*.tres`; compartido
  porque los nodos de la zona lo referencian): vida, `weapon_id` (las armas de los PNJ son
  `data/combat/npc_*.tres`, en el catálogo de combate: cambian los ids y el `sim_hash`, lo que va
  con la versión 3), velocidades, percepción (radio, cono), radio de alerta de grupo, correa,
  inmortal, `ignores_safe_area`, `is_boss`.
- `HfsmBrain` (`scripts/server/ai/hfsm_brain.gd`; `NpcBrain` sigue siendo el maniquí): **REPOSO →
  PATRULLA → ALERTA → COMBATE → REGRESO**; RNG con semilla por PNJ; produce `PlayerInput` sintéticas
  (§1.7 paso 0). Dos ejecuciones con las mismas entradas dan la misma secuencia de estados.
- Percepción por radio, cono y `HitShapes.has_line_of_sight`; amenaza por daño y proximidad;
  correa con regreso regenerado e inmune.
- Ataques legibles: armas de PNJ con anticipación ≥ 0,45 s (ligeros) y ≥ 0,70 s (fuertes).
  **Fichas**: como mucho 2 PNJ atacan a la vez al mismo jugador; el resto lo rodea a 3–4 m.
- Depuración: comando 12 `npc_debug` escribe estado, objetivo y ruta de los PNJ cercanos en el
  registro del servidor cada segundo (sin mensaje de red en la fase 4).

### 4.3 Generadores y defensores (MUN-09 … MUN-12, GUE-11)

- `NpcSpawner` (`scripts/world/npc_spawner.gd`, solo datos: marcador, `NpcDefinition`, máximo vivos,
  reaparición, grupo de alerta, condición `always` / `fort_neutral` / `fort_owner`) y
  `NpcSpawnerSystem` (servidor), que lee las condiciones de `FortressController`
  (`get_fortress_state(id) -> FortressState`) y avisa con la señal `npc_died(net_id, spawner,
  killer)`.
- **Huecos** (MUN-10): 4, en los `GuardSpawn` del patio; dos patrullan del patio a la pasarela
  (marcadores de patrulla nuevos en el generador). Alerta en grupo a 25 m, correa a la meseta,
  reaparición completa (con el Capitán) si el fuerte sigue neutral sin jugadores a 40 m durante
  2 min.
- **Capitán del Vado** (MUN-11): `CaptainSpawn` (dentro del círculo: no cuenta, los PNJ no cuentan).
  Barrido amplio bloqueable; golpe imbloqueable (`AttackDefinition.unblockable`, solo servidor)
  con aviso TELEGRAPH; grito que alerta a los Huecos vivos; 2 Huecos de refuerzo al 50 % si
  quedan Huecos. Al morir: `on_captain_died`.
- **Guarnición del reino** (GUE-11): 4 guardias y un capitán del dueño en los mismos marcadores al
  pasar a `GARRISONED`.
- **Guardianes de la Puerta** (MUN-12): 2 por campamento, `ignores_safe_area`, daño alto y alcance
  largo; atacan solo a enemigos dentro de la zona segura (un intruso muere en menos de 10 s).

---

## 5. Avisos, reaparición, salida y /atascado

- **ENTITY_EVENT `5 WAR`**: `net_id` = fortaleza, datos `u8 war_event`, `u8 realm` (11 B). Eventos
  fijos: 1 fuerte atacado (realm = atacante; 1 cada 60 s por fortaleza), 2 capitán caído (realm =
  quien lo mató), 3 captura iniciada (captor), 4 captura disputada (como mucho 1 cada 10 s), 5
  puerta rota (quien la rompió), 6 fuerte capturado (nuevo dueño), 7 fuerte reiniciado (0). A toda
  la zona, aplicados en el tick de dibujo. Textos en español en `WarEvents` (compartido).
- **ENTITY_EVENT `6 TELEGRAPH`**: `net_id` = PNJ, datos `u16 attack_id`, `u8 shape` (0 círculo, 1
  sector), `u64 posición` (20 bits por eje, como el registro), `u16 yaw`, `u16 radius_cm`, `u16
  impact_in_ticks`. Se aplica al llegar (es un aviso, debe verse cuanto antes).
- **Reaparición** (amplía combate.md §5):
  - Índice **estático** sobre todos los marcadores `respawn_points` de la escena, en orden de
    escena (campamentos incluidos: el generador añade los de cada campamento). Metadatos `realm` o
    `fortress`.
  - Válido para un jugador: su campamento, o un marcador de una fortaleza de su reino en
    `GARRISONED` con `s ≥ under_attack_until_tick`. El cliente calcula lo mismo con
    `RespawnRules.points_for(realm, fortresses, tick) -> PackedInt32Array` (compartido).
  - Si el punto pedido ya no vale, el servidor usa el campamento, sin aviso.
  - Oleadas: `respawn_tick` = primer múltiplo de 600 ticks ≥ muerte + `respawn_s`.
  - Los marcadores del fuerte, fuera del cilindro del círculo.
- **Salida en combate** (GUE-41): CLIENT_LEAVE o desconexión «en combate» dejan el cuerpo 15 s
  desde la baja (CLIENT_LEAVE o timeout de ENet) con entradas **neutras de verdad** (sin botones):
  quieto, sin bloquear, atacable, sin contar en el círculo. El nombre queda reservado esos 15 s
  (REJECT NAME). El menú del cliente muestra la cuenta atrás antes de salir.
- **/atascado** (MUN-41): mensaje propio `0x06 UNSTUCK_REQUEST` (C→S, canal 3, 1 B), válido sin
  `--debug-commands`: canalización de 10 s que el daño interrumpe, fuera de combate, 5 min de
  reutilización, teletransporte al punto de aparición más cercano del reino y registro.

---

## 6. Interfaz (UI-18 … UI-21, UI-41, UI-42)

- **HUD de captura** (UI-18): dueño (color y emblema), fase, barra de progreso con el color del
  captor, «disputado», presentes de cada bando y vida de la puerta, a menos de 80 m o al combatir
  por él; banners de los WAR; barra de jefe para los PNJ con `is_boss`.
- **Brújula y marcadores** (UI-19): fuerte, campamentos y pasos.
- **Mapa** (UI-20, UI-21): `tools/bake_zone_map.gd` (sin GPU, comprobado): sombreado de
  `Terrain3D.get_height`, agua de los vértices de su malla, contornos de las colisiones y de
  `BakedMultiMesh.instance_transforms` (las MultiMesh devuelven identidad en headless), guardado
  como `assets/maps/vado_gris.png` (por LFS) con su escala en un `.tres`. Minimapa circular y
  mapa a pantalla completa con la elección de reaparición.
- **Marcador** (UI-41, Tab): mensaje nuevo `0x32 SCOREBOARD` (S→C, canal 3, cada 2 s a toda la
  zona): cabecera `u8 type, u8 page_index, u8 page_count, u8 row_count` y, por jugador, `u16 net_id,
  u16 bajas, u16 muertes, u16 asistencias, u32 daño a la puerta, u16 s en el círculo, u32 méritos`
  (18 B). Una página lleva como mucho 66 filas (1192 B); con más jugadores el servidor parte el
  marcador en varios mensajes (`NetMessages.Scoreboard.split`) y el cliente los junta por página. El
  registro de bajas sale de los KILL, que en la fase 4 van a toda la zona.
- **Pistas** (UI-42): una vez por jugador, en `user://`, con opción para desactivarlas.

---

## 7. Bots que asedian (GUE-15, GUE-16, GUE-42)

- **Rutas como datos**: `data/routes/vado_gris.tres` (puntos de las rutas del puente y del vado
  por reino, sacados de `verify_vado_gris_routes.gd`, y, desde F6a, dónde están la puerta y el círculo del
  fuerte para los bots que no cargan la zona; desde F6b, también el tamaño del recinto, `enclosure_size`), compartido.
- **`SiegeView`** (compartido, puro): dueño, fase, captor, vida de la puerta y posiciones de la
  puerta y el círculo. La llena el servidor para `--fake-players` y el cliente (`FortressView` o,
  en `SwarmBot`, decodificando OBJECT_STATE) para `--bot` y `--bots`.
- `BotBrain` gana el patrón `SIEGE`: seguir la ruta de su reino hasta el fuerte, golpear la puerta
  si está cerrada, entrar en el círculo, defender el círculo si es el dueño (la pasarela, que pide
  navegación, queda para los PNJ de F4) y atacar al enemigo más cercano. Los `SwarmBot`, que no simulan,
  siguen las rutas en línea recta entre puntos. Hecho en F6a (detalle en 8.3). En F6b pelea con los PNJ de verdad:
  busca primero a los PNJ que guardan el fuerte mientras el capitán vive, sale de la zona de los golpes avisados
  (TELEGRAPH) con una esquiva, deja las persecuciones que no le acercan y rodea la empalizada si se queda fuera a
  un lado (detalle en 8.3, F6b).
- Criterio: `--bots=20` por bando capturan y recapturan sin intervención. F6a lo cumple con jugadores falsos
  y la orden `fort_kill_captain` en lugar del capitán. En F6b, con los PNJ de verdad y sin ninguna orden: capturan el neutral
  siempre (86–88 s) y recapturan dentro del ciclo de 30 min con el capitán del reino en 7500 (de 6,7 a 27,6 min según la semilla);
  lo que alarga la recaptura es el círculo frente a los defensores (GUE-44), no los PNJ (8.3, F6b).
- **Carga** (GUE-16): escenario de `load_test` con 32 contra 32 y 64 contra 64 en la puerta y el
  círculo durante 120 s (`--siege`; resultados en 8.3).
- **Equilibrio** (GUE-42, hecho en F6a): `--max-realm-diff=N` (por defecto 0 = sin límite); un REJECT nuevo,
  **9 IMBALANCE**, con texto propio. El recuento por reino para RealmSelect llega en el WELCOME (`u8 × 3` al
  final; lo rellena el servidor desde F6a). Regla exacta (`RealmBalance`, `FillerKeeper`, `ServerAuth`,
  `ServerMain`):
  - *Qué cuenta.* Solo **personas**: los clientes aceptados (cargando la zona o ya dentro). Los jugadores
    falsos y los cuerpos que quedan tras una baja en combate (GUE-41) no cuentan. Se compara con los reinos
    que la zona admite (`NetZones.allowed_realms`; el Vado Gris, Vardheim y Solmarch; una zona sin
    restricción, los tres).
  - *Rechazo.* Entrar en el reino *r* se rechaza si `personas[r] + 1 − min(personas[s])` es mayor que N, con
    *s* cada uno de los otros reinos admitidos. Se comprueba después de las demás validaciones y del
    proveedor de identidad, así que el orden es VERSION, SIM_HASH, REALM, NAME, FULL, TOO_MANY_CONNECTIONS,
    TICKET, IMBALANCE. Con N = 1 en el Vado Gris entra la primera persona de un reino (1 contra 0) y se
    rechaza la segunda hasta que haya alguien en el otro.
  - *WELCOME.* `realm_counts` son las personas de cada reino en ese momento, **sin contar a quien entra**.
  - *Relleno.* Con N > 0, los falsos de `--fake-players` de reino automático (todos salvo los de
    `--fake-layout=cluster` con el cerebro de paseo, que van al primer reino) son de relleno. El servidor los
    reparte al arrancar en el reino con menos total (personas más relleno; a igualdad, el de código más bajo:
    el reparto por turnos de siempre). Después: **entra una persona** en el reino *r* y el total de *r* pasa a
    ser mayor que el menor de los otros → se retira el falso de relleno más antiguo de *r* (uno por persona; si
    *r* era el bando corto, la persona ocupa un hueco y no se retira a nadie); **sale una persona** de *r* y el
    total de *r* queda por debajo del mayor de los otros, sin pasar del cupo de `--fake-players` → entra un
    falso nuevo en *r*. Nada más retira ni añade falsos, y el relleno no cuenta para rechazar a nadie.
    Sin `--max-realm-diff` los falsos no se tocan (las pruebas de carga miden lo de siempre).
  - *Plazas* (GUE-43, desde F6b). El relleno **no ocupa plazas de personas**: el FULL (y `--max-players`) solo cuenta
    a las personas y a los falsos que no son de relleno. Si llega el HELLO de una persona de *r* con el servidor lleno
    solo por el relleno, se acepta (pasadas las demás comprobaciones, IMBALANCE incluido) y **un falso de relleno le
    cede su plaza en ese momento**, antes de que cargue la zona: el más antiguo del reino con más total (personas
    más relleno) **contando a quien entra**; a igualdad, el de *r*, y si no, el de código más alto. Con los bandos
    igualados es siempre uno de *r* (la persona sustituye a un falso de su bando, como en el bando largo); si *r* ya
    no tiene relleno, cede el bando con más total, que es el que deja la batalla más igualada (la alternativa, «lleno»,
    es justo lo que GUE-43 quita). Ese falso cuenta como el que retira su entrada: al entrar en el mundo no se retira
    otro por ella (sigue siendo uno por persona). Si se va sin llegar a entrar (corta o no termina de cargar), vuelve
    un falso en el reino con menos total, sin pasar del cupo. Las personas nunca pasan de `--max-players`: sin
    relleno que ceda, «lleno» como siempre.
- **Telemetría** (GUE-17): eventos de guerra y muertes en JSON Lines (`--battle-log`) y
  `tools/war/summarize_battle.gd` con el tiempo hasta la captura, las muertes por ruta y el tiempo
  hasta romper la puerta.

---

## 8. Paquetes y contratos

### 8.1 Paquetes

| Paquete | Contenido | Depende de |
|---|---|---|
| **F0 · escena y generador** | En el generador del Vado Gris (y en el `.tscn`): nodo de fortaleza (grupo `fortresses`, metadato `definition`), puerta cerrada con los dos cuerpos, `respawn_points` de campamentos y fuerte, marcadores de patrulla, `NpcSpawner` de Huecos, Capitán y Guardianes, `dummy_points`; horneado de la navmesh; rutas en `data/routes/` | fase 3 |
| **F1 · fortaleza pura** | `FortressDefinition`, `FortressState`, `FortressFields`, `WarEvents`, `RespawnRules`, `SiegeView`, `FortGate.layers_for`, `PlayerCharacter.set_realm_collision`; pruebas de toda la tabla de §1.5 y de la fórmula | fase 3 |
| **F2 · protocolo v3** | OBJECT_STATE, SPAWN de STRUCTURE y de NPC, WAR, TELEGRAPH, UNSTUCK_REQUEST, SCOREBOARD, REJECT 9, recuento en el WELCOME, ids de comandos 7–12 | F1 |
| **F3 · servidor del fuerte** | `FortressController`, presencia, puerta (blanco, multiplicadores, capas, reparación), orden del tick, comandos, reaparición en el fuerte, GUE-41, /atascado, SCOREBOARD, `--battle-log` | F0, F1, F2, K3 |
| **F4 · PNJ** | `NpcNavigation`, `NpcDefinition`, `NpcCatalog`, `HfsmBrain`, fichas, `NpcSpawnerSystem`, armas de PNJ, Huecos, Capitán, guarnición, Guardianes | F0, F1 (`FortressState`, señales), K3 |
| **F5 · cliente** | `FortressView` y su gancho en `ClientPrediction`, HUD de captura, banners, barra de jefe, brújula, mapa horneado y minimapa, mapa con reaparición, marcador, pistas | F1, F2 |
| **F6 · bots, carga y extremo a extremo** | `SIEGE`, `SwarmBot` con rutas, `--max-realm-diff`, carga, prueba neutral → Vardheim → Solmarch con jugadores falsos | F3, F4, F5 |

F0 y F1 en paralelo; luego F2; luego F3, F4 y F5 (con cuidado en `zone_server.gd`, que tocan F3 y
F4); F6 al final.

### 8.2 Contratos

```gdscript
# scripts/shared/war/fortress_state.gd
class_name FortressState extends RefCounted
enum Phase { GARRISONED, VULNERABLE, CAPTURING, CONSOLIDATING }
static func initial(def: FortressDefinition, tick: int) -> FortressState
## Avanza al tick dado con la presencia actual; devuelve los WarEvents (ids) emitidos.
func advance(def: FortressDefinition, tick: int, presence: PackedInt32Array) -> PackedInt32Array
func on_captain_died(tick: int, killer_realm: int) -> PackedInt32Array
func on_gate_damaged(tick: int, amount: int, attacker_realm: int) -> PackedInt32Array
func on_defender_damaged(tick: int, attacker_realm: int) -> void
func set_guards_alive(count: int) -> void
func reset_to_neutral(def: FortressDefinition, tick: int) -> PackedInt32Array
func progress_at(tick: float) -> int
func changed_fields_since(other: FortressState) -> PackedInt32Array   # para OBJECT_STATE

# scripts/shared/war/respawn_rules.gd
class_name RespawnRules extends RefCounted
static func points_for(realm: int, points: Array[Node3D], fortresses: Dictionary, tick: int) -> PackedInt32Array

# scripts/world/fort_gate.gd (amplía)
static func layers_for(owner_realm: int, broken: bool) -> int
func set_state(owner_realm: int, broken: bool) -> void       # capas de los dos cuerpos y visual

# scripts/shared/player_character.gd (amplía)
const STRUCTURE_LAYER: int = 1 << 3
const REALM_LAYER_BASE: int = 4                                # capa 5 = Vardheim
func set_realm_collision(realm_code: int) -> void

# scripts/client/client_prediction.gd (amplía)
var before_simulate: Callable                                  # (tick: int) -> void
```

### 8.3 Lo que han dejado F0, F1 y F2 (añadidos al contrato y decisiones)

F0 (escena, capas, malla y rutas), F1 (fortaleza pura), F2 (protocolo 3), F3 (servidor del fuerte), F4 (PNJ), F5 (cliente) y la
primera mitad de F6 (F6a: bots que asedian, equilibrio de reinos y carga) están hechos; F6b (extremo a extremo con los PNJ) va por paquetes
(hechos: GUE-43 y los bots contra los PNJ; faltan GUE-44, GUE-45 y la carga con PNJ). Además
de lo de 8.2, quien siga con F6b (y con lo que toque a los PNJ) encontrará esto:

**F0**

- El generador del Vado Gris **se puede ejecutar aquí** (los assets están en el repo): la escena
  sale igual que la guardada salvo los `unique_id`, los identificadores de recurso y el ruido de la
  última cifra decimal de algunas transformaciones (Linux frente a Windows); los `.res` de región y
  la malla del agua sí salen con otros bytes, así que no se tocan (docs/zonas/vado_gris.md,
  «Cómo regenerar»). `vado_gris.tscn` se ha regenerado, no editado a mano.
- El nodo de la fortaleza es el propio `Fuerte` (grupo `fortresses`, metadato `definition`), y sus
  hijos llevan los nombres fijos `CaptureCircle`, `CaptainSpawn`, `GuardSpawn1..4`, `FortGate`,
  `Estandarte`, `EstandartePuertaN` y `EstandartePuertaS`. `Zones` ganó las constantes de los grupos
  y metadatos nuevos (`FORTRESS_GROUP`, `FORTRESS_DEFINITION_META`, `FORTRESS_META`,
  `NPC_SPAWNER_GROUP`, `PATROL_GROUP`, `PATROL_ROUTE_META`).
- `NpcSpawner` (`scripts/world/npc_spawner.gd`) guarda el **id** de la definición de PNJ (`npc_id`,
  el archivo de `data/npcs/` sin extensión) en lugar de una referencia a `NpcDefinition`, porque esa
  clase llegó con el paquete F4. Ids en uso: `hollow`, `ford_captain` y `gate_guardian` (más
  `realm_guard` y `realm_captain`, de la guarnición; los cinco están en `data/npcs/`). Los Huecos y el Capitán
  llevan `respawn_s = 0` (los repone la fortaleza); los Guardianes, 30 s. La guarnición del dueño
  (`FORT_OWNER`) no tiene generadores todavía.
- Los `respawn_points` del Vado Gris son 12: los 8 de los campamentos (con `realm`) y después los 4
  del patio del fuerte (con `fortress` y sin `realm`). Mientras `NetZones` no use `RespawnRules`, la
  lista de un reino son solo sus campamentos (los del fuerte no tienen `realm`), igual que antes.
- `FortGate`: el estado se pone con `set_state(dueño, rota)` (`get_owner_realm()`, `is_broken()`);
  además de `layers_for` hay `view_layer_for(rota)` (la capa del cuerpo de vista, 4 o 0) y
  `get_view_body()`. Ya no existe la propiedad `open` ni las colisiones de las hojas abiertas: rota,
  los dos cuerpos se quedan sin capas y las hojas cuelgan abiertas. `PlayerCharacter` ganó además
  `realm_layer(código)` (la máscara de un reino) y `set_realm_collision` sustituye a la anterior
  en cada llamada. El modo sin red no la llama: el personaje cruza la puerta cerrada.
- La navmesh sale de `tools/bake_navmesh.gd` en 2 s y pesa 0,3 MB con celda de 0,25 m. Ojo con el
  mapa de navegación: la primera iteración sale vacía (4.1).
- Las rutas son `ApproachRoutes` (`scripts/shared/war/approach_routes.gd`), con puntos (x, z) por
  ruta (`bridge`, `ford`) y reino; `data/routes/vado_gris.tres` lo escribe
  `tools/terrain/export_vado_gris_routes.gd` y lo lee `verify_vado_gris_routes.gd`.

**F1**

- `FortressDefinition` ganó `display_name` (para los textos de `WarEvents`) y los métodos
  `*_ticks()`. El radio del círculo sigue saliendo solo del marcador.
- `FortressState` guarda, además de los campos de 1.4, `progress_max`, `last_reset_tick` (de ahí
  cuenta el reinicio periódico) y copia de la definición los ticks que necesitan los métodos que no
  la reciben. Solo viajan los campos de `FortressFields`; el cliente reconstruye el resto con
  `FortressState.initial(def, tick)`.
- La velocidad decidida en el tick `s` vale desde `s` (el progreso de `s + 1` suma esa velocidad).
  Con el círculo vacío, el decaimiento a −4 empieza a los `decay_after_empty_s` justos (≥, no >).
  Al volver a VULNERABLE desde CAPTURING el capitán recibe un plazo nuevo de `captain_respawn_s`.
- Reglas que la tabla no cubre y que se han resuelto así: con el progreso en cero y varios reinos (o
  un reino y el dueño) dentro, la captura vuelve a VULNERABLE, disputada; la disputa avisa al entrar,
  no mientras sigue, y como mucho cada 10 s; los avisos de «atacado» salen como mucho cada 60 s por
  fortaleza (`claim_attack_notice`, que el controlador usa también para los golpes a defensores).
- Métodos añadidos a 8.2: `copy_from`/`duplicate_state`, `respawn_captain(tick)` (la reaparición
  completa de los Huecos trae al capitán), `guards_respawn_due(tick)` (el estado dice cuándo toca
  reponer a los guardias; quien los crea llama luego a `set_guards_alive`), `gate_repair_due(tick)`
  y `repair_gate()` (la reparación con el vano ocupado se aplaza en el controlador),
  `claim_attack_notice(tick)`, `event_realm(evento, reino_de_quien_llama)` (el reino que acompaña a
  cada aviso), `is_circle_active()` e `is_gate_broken()`. `advance` y los `on_*` devuelven solo los
  ids de los avisos.
- `FortressPresence.count(def, centro, radio, candidatos, tick)` es la presencia de 1.2 (con la
  clase interna `Candidate`); `FortressFields` da, además de los ids, el tipo de valor de cada campo
  (`value_type`), `get_value`/`set_value` sobre un `FortressState` y `fits`; `WarEvents.text(id,
  reino, nombre_del_fuerte)` da el texto en español.
- `RespawnRules.points_for` acepta las claves de `fortresses` como `StringName` o `String`.
  `SiegeView` se llena con `update_from_state` (servidor) o `update_from_fields` (campos de
  OBJECT_STATE) y responde `is_gate_closed_for`, `can_damage_gate`, `should_defend`,
  `should_attack`, `is_circle_active`, `is_capturing` e `is_in_circle`.

**F2** (protocolo 4 tras fusionar la revisión de la fase 3, que ocupó la 3: `PROTOCOL_VERSION = 4`; formatos en [red.md 5](red.md#5-formatos-de-los-mensajes))

- Todo está en `scripts/shared/net/`. `NetMessages` gana `ObjectField` (campo suelto: `field_id`,
  `value_type`, `value`; satura al codificar), `ObjectState` (OBJECT_STATE), `UnstuckRequest`,
  `ScoreRow` y `Scoreboard`; `EntitySpawn` gana `npc_def_id`, `definition_id` y `fields`;
  `EntityEvent` gana los tipos `WAR` y `TELEGRAPH`; `Welcome` gana `realm_counts`; `NetProtocol`
  gana `MSG_UNSTUCK_REQUEST` (0x06), `MSG_SCOREBOARD` (0x32), `Result.IMBALANCE` (9, con su texto),
  `MAX_DEFINITION_ID_BYTES` y los ids de depuración 7 a 12 (`DEBUG_UNSTUCK`, `DEBUG_FORT_RESET`,
  `DEBUG_FORT_OWNER`, `DEBUG_FORT_KILL_CAPTAIN`, `DEBUG_FORT_CAPTURE_SPEED`, `DEBUG_NPC_DEBUG`, también
  en `DEBUG_COMMAND_IDS`). Los tres tipos nuevos de mensaje van por el canal fiable 3.
- Utilidades para F3 y F5: `ObjectState.from_fortress(id, tick, state)` (estado completo, 17 campos),
  `from_fortress_changes(id, tick, state, previous)` (solo los de `changed_fields_since`; si no ha
  cambiado nada, `fields` queda vacío y `encode()` devuelve un búfer vacío: no hay nada que mandar),
  `from_fortress_fields` (lista de ids a medida), `apply_to_fortress(state)` (aplica los campos
  conocidos con su tipo y salta los ids desconocidos y los de otro tipo; devuelve cuántos aplicó),
  `EntitySpawn.for_fortress(net_id, tick, definition_id, state)` y `EntitySpawn.to_object_state()`
  (el cliente aplica los campos del alta igual que un OBJECT_STATE), `EntityEvent.war(...)` y
  `EntityEvent.telegraph(...)`, `Scoreboard.split(filas)`, `DebugCommand.simple/fort_owner/
  fort_capture_speed/npc_debug`. `NetEntity` gana `npc_def_id`, que su `encode_spawn` pone en el
  SPAWN de un PNJ.
- Reglas de validación que el documento no fijaba: un WAR exige un aviso de `WarEvents` (1–7) y un
  reino de 0 a 3; un TELEGRAPH, una forma 0 o 1; un `value_type` desconocido, un `field_id`
  repetido o un contador fuera de 1–32 invalidan un OBJECT_STATE y el SPAWN de una estructura (un
  `field_id` desconocido con un tipo válido, no); el SCOREBOARD añade un `row_count` al índice y
  total de páginas para poder exigir el tamaño exacto, con 66 filas como máximo.
- `ZoneServer` acepta `UNSTUCK_REQUEST` (un aviso si llega antes de entrar en el mundo o mal formado)
  y no suma avisos por un comando de depuración con id fijo (7 a 12) y datos válidos aunque aún no
  tenga manejador (F3 registró del 7 al 11 y F4 registró `npc_debug`). `NetClient`
  acepta `OBJECT_STATE`, `SCOREBOARD`, el SPAWN de estructuras y los eventos `WAR` y `TELEGRAPH` sin
  contarlos como malformados ni como eventos de combate, y los cuenta en `get_stats()`
  (`object_states`, `scoreboards`, `structure_spawns`, `war_events`, `telegraphs`); `SwarmBot`
  también acepta los dos mensajes sueltos. Quedan con `TODO(F3)`, `TODO(F5)` y `TODO(F6)` en el
  código.
- El WELCOME ya lleva `realm_counts`; `ZoneServer` lo manda a 0 hasta que F6a lo rellena (GUE-42).
- Cuidado con `String.to_ascii_buffer()`: con caracteres que no son ASCII registra un error del
  motor y los cambia por espacios. Los ids de definición se comprueban antes
  (`NetMessages.is_printable_ascii_text`).

**F3** (el servidor del fuerte; pruebas en `test_fortress_controller`, `test_gate_target`, `test_hit_shapes_box`,
`test_fortress_server`, `test_fortress_zone`, `test_fortress_net`, `test_battle_summary`, `test_score_keeper` y
`test_unstuck_tracker`)

- **Archivos**: `scripts/server/war/` (`FortressController`, `StructureTarget`, `ScoreKeeper`, `BattleLog`,
  `BattleSummary`), `scripts/server/unstuck_tracker.gd` y `tools/war/summarize_battle.gd`. `ZoneServer` solo
  cablea (`_setup_fortresses`, el paso 4b del tick y los manejadores de salida en combate, /atascado y
  marcador); `CombatResolver`/`CombatDirector` ganan los blancos estáticos. `NetEntity` gana
  `definition_id` y `fortress_state` (su SPAWN de STRUCTURE), `InputQueue.get_last_real_tick()` (la regla de
  inactividad de 60 s), `NetZones.get_fortress_nodes`/`get_all_respawn_points` (el servidor no nombra `Zones`),
  `FortGate.get_hit_box()`/`get_hit_half_extents()`/`get_body_rids()`, `HitShapes.sector_hits_box` y
  `capsule_overlaps_box`, `CombatRules.structure_*_multiplier` y `FortressState.capture_rate_multiplier`.
- **Interfaz con los PNJ (F4)**, en `FortressController` (`ZoneServer.get_fortresses()`):
  `get_fortress_state(id)` (el estado **vivo**, no una copia), `on_captain_died(id, tick, reino)`,
  `set_guards_alive(id, n)`, `register_captain(id, net_id)` y `register_defender(id, net_id)` (el controlador
  se entera solo por los DEATH y HIT del combate: la muerte del capitán abre el círculo y un golpe a un
  defensor marca el fuerte como atacado y da el aviso), y las señales `defenders_retired(id, tick)` (cambio de
  dueño o reinicio: retirar los PNJ de antes), `garrison_due(id, dueño, tick, completa)` (vuelve a estar
  GARRISONED: hacer aparecer la guarnición y el capitán del dueño, o los Huecos y el Capitán del Vado con
  dueño 0; `completa` false si solo reaparece el capitán) y `guards_respawn_due(id, tick)` (reponer los
  guardias que faltan y avisar con `set_guards_alive`). Al arrancar no hay señal: el fuerte es neutral y su
  generador lee el estado. **Doble de pruebas**: `ZoneServer.spawn_captain_double(id)` crea un PNJ mortal y
  quieto en el `CaptainSpawn`, del bando del dueño, ya registrado como capitán; se mata a golpes, con
  `kill` o con `fort_kill_captain`.
- **La puerta como blanco**: el golpe usa la caja de la puerta cerrada (`ColisionCerrada`), sin rebobinado
  (se prueba antes que el rebobinado del atacante, así que un rebobinado rechazado no libra de golpear la
  puerta pero sí se anota como sospechoso), sin crítico ni defensa, y la línea de visión desde el pecho hasta
  el punto de la caja más cercano excluye los dos cuerpos de la puerta. Daño de la fórmula por el
  multiplicador de su tipo, redondeado, mínimo 1, sin pasar de la vida que queda: **un ligero quita 31**
  (90 × 0,35 = 31,499… en coma flotante), el tercero del combo 45 y un fuerte cargado al máximo 107. Los
  números de §3.3 se cumplen: tres atacantes con el combo la rompen en **54,8 s** (`test_fortress_server`). El
  HIT lleva el `net_id` de la fortaleza y solo se manda al atacante (y a quien lo tenga relevante), no a toda
  la zona. Un atacante dentro de la zona segura de su reino no golpea la puerta.
- **Reparación y vano libre**: cuando la reparación que hace el estado (captura, `fort_reset`, `fort_owner`)
  o el plazo de 5 min cae con alguien solapando el vano, el controlador **deshace la reparación**: la puerta
  conserva la vida rota (y la colisión abierta) en el estado y en el OBJECT_STATE, y se repara en el primer
  tick con el vano libre (`is_repair_pending`). Así cliente y servidor siguen simulando lo mismo. Solo
  cuentan personajes vivos (jugadores y PNJ) cuyos pies solapen la caja; quien pisa la pasarela de encima no
  la retiene. Un cambio de dueño con la puerta entera cambia las capas sin esperar (nadie queda atrapado en
  una puerta entera: solo cambia a quién para).
- **OBJECT_STATE**: como mucho uno por fortaleza cada 6 ticks con los campos cambiados; **desviación**: si lo
  que cambia es la colisión de la puerta (dueño o rotura), sale en ese mismo tick, para que la historia de
  cambios del cliente tenga el tick exacto del cambio (con el estado agrupado, la puerta habría cambiado hasta
  5 ticks antes en el servidor que en el cliente). `under_attack_until_tick` solo viaja si avanza 60 ticks o
  más (o si retrocede por un reinicio). Todos van por el canal fiable a quien está dentro del mundo; quien
  entra recibe el estado completo en el SPAWN.
- **Reparto de los comandos**: los de red actúan sobre la fortaleza más cercana al que los envía (rechazados
  sin aviso si no hay ninguna, o si `fort_kill_captain` no encuentra al capitán guardando el fuerte); los de
  consola aceptan la fortaleza al final (`fort_owner vardheim test_fort`). `fort_owner` deja la fortaleza
  GARRISONED con ese dueño (guarnición y capitán, puerta llena, captura a cero) y manda `FORT_CAPTURED` (o
  `FORT_RESET` con 0). `fort_capture_speed` multiplica solo la velocidad positiva (`FortressState`
  `capture_rate_multiplier`, que no viaja: el cliente ve la velocidad ya multiplicada). `unstuck` (id 7) también
  está registrado y pasa por la misma canalización que el mensaje propio; `npc_debug` (12) lo registra F4 (`NpcSpawnerSystem`).
- **Reaparición**: `RESPAWN_REQUEST.point_index` y el `point` del evento RESPAWN son el índice de la lista
  **estática** (`NetZones.get_all_respawn_points`: todos los marcadores `respawn_points` en el orden de la
  escena, 12 en el Vado Gris; sin ninguno, los puntos de aparición). Vale lo que dice
  `RespawnRules.points_for` con los estados vivos (`CombatDirector.get_valid_respawn_points`). Si el punto ya
  no vale, el servidor usa el primer campamento válido de su reino, sin aviso, y si no hay ninguno, un punto
  de aparición. **Oleadas**: en las zonas con alguna fortaleza (`CombatTiming.respawn_wave_ticks = 600`) el
  `respawn_tick` es el primer múltiplo de 600 ≥ muerte + `respawn_s`; en las demás sigue siendo muerte +
  `respawn_s`. El cliente (F5) debe construir su lista con la misma función: mientras use la lista del reino de
  antes, Solmarch cae siempre en su primer campamento.
- **GUE-41**: `CLIENT_LEAVE` o la desconexión de quien está «en combate» y vivo (`ZoneServer.linger_ticks`, 900
  por defecto; las pruebas lo acortan) deja el cuerpo `linger_ticks` desde que se procesa la baja. El
  `Combatant` sigue vivo y atacable, sin peer (no rebobina), sus entradas son las neutras de `NetProtocol`
  (sin botones, quieto), no cuenta en el círculo (`connected = false`) y su nombre sigue en
  `get_connected_names()`, así que un HELLO con él recibe `REJECT NAME`. Si lo matan, la muerte y el KILL se
  acreditan como cualquier otra y el cuerpo se retira al tick siguiente; al vencer el plazo se retira con el
  DESPAWN de siempre. Fuera de combate o muerto, la baja es inmediata.
- **MUN-41**: `UnstuckTracker` (clave: el nombre normalizado, para que volver a entrar no salte la
  reutilización): 600 ticks de canalización (`channel_ticks`), 18 000 de reutilización (`cooldown_ticks`, solo
  tras completarla), rechazo en combate, muerto o ya canalizando, e interrupción si el jugador entra en
  combate (dar o recibir daño) o muere. Cada respuesta es un NOTICE informativo. El destino es el punto de
  reaparición **válido** más cercano de su reino (campamento o fuerte propio sin atacar); sin ninguno, un punto
  de aparición. Cada uso queda en el registro del servidor y en `war.unstuck.log` del informe (zona, origen,
  destino).
- **Marcador**: `ScoreKeeper` (bajas, muertes, asistencias, daño a la puerta y segundos con el círculo
  **activo**) y SCOREBOARD cada 120 ticks a todo el mundo, en páginas de 66 filas. **Méritos provisionales**
  (PRG-09 los sustituirá con antifarmeo y reparto por daño): `bajas × 10 + asistencias × 5 + segundos en el
  círculo`. Los PNJ no tienen fila. El KILL va a toda la zona (el DEATH sigue yendo a los implicados). Una
  baja o una asistencia es la de cualquier KILL cuyo asesino (o asistente) sea un jugador, también si la víctima
  es un PNJ, para que el marcador cuadre con el registro de bajas del cliente (cada KILL, una vez); las muertes
  son solo las de jugadores.
- **`--battle-log=<ruta>`** (JSON Lines, `BattleLog`): `battle_start` (zona y, por fortaleza, posiciones del
  fuerte, la puerta y el círculo), `war` (el aviso con su clave de `WarEvents`, el reino y el lugar),
  `gate_damage_started` (el primer golpe a la puerta desde su última reparación) y `death` (víctima, asesino,
  ataque y posición; `victim_kind` distingue jugadores de PNJ). `tools/war/summarize_battle.gd` (`godot
  --headless --path . -s res://tools/war/summarize_battle.gd -- batalla.jsonl [--json] [--out=resumen.json]`)
  saca el tiempo hasta la captura, la captura propiamente dicha, las muertes de jugadores por ruta (puente,
  vado, pasarela del fuerte u otras, a partir de `data/routes/<zona>.tres` y la altura sobre el círculo) y el
  tiempo desde el primer golpe a la puerta hasta romperla. El informe del servidor gana la sección `war`
  (fortalezas, OBJECT_STATE y marcadores enviados, salidas en combate y /atascado) y las métricas, la sección
  `war` del tick.
- **Reinicio a neutral**: lo hace el propio `FortressState.advance` cada `reset_to_neutral_s` desde el último
  reinicio (`last_reset_tick`: la creación de la fortaleza, un `fort_reset` o un `fort_owner` rearman el reloj);
  el controlador lo convierte en `FORT_RESET` (aviso a toda la zona con reino 0), `defenders_retired` y
  `garrison_due` (con el dueño 0 y `completa`: los Huecos y el Capitán del Vado vuelven enteros). Pasa en
  cualquier fase, también con una captura a medias, y **no mueve a nadie**: quien está en el círculo sigue donde
  estaba. La puerta se repara y las capas vuelven a las de neutral en ese mismo tick (valen desde `s + 1`), pero si
  alguien solapa el vano la reparación se aplaza como en cualquier otro cambio de dueño. `reset_to_neutral_s = 0`
  lo desactiva. El Vado Gris (1800 s = 108 000 ticks) lo trae activo
  mientras sea un mapa de pruebas; `tools/war/summarize_battle.gd` empieza un ciclo nuevo en cada `fort_reset` del
  registro, así que su resumen es el de cada partida de 30 min.
- **Medido (F3)**: el paso 4b (`FortressController.step`) cuesta de media 522 µs en los ticks de recuento (cada 6)
  y 50 µs en los demás con 64 jugadores falsos en el círculo, unos 130 µs por tick; en un proceso de verdad sobre el Vado
  Gris con 16 falsos de combate en el círculo, el p99 del tick fue de 4,7 a 6 ms y la sección `war` de 0,5 a 0,6 ms.
  Una sesión de humo con la consola (`fort_kill_captain` con los dos bandos dentro) dejó en el registro de batalla
  «capitán caído», «captura disputada» y, al morir los de Vardheim, «captura iniciada» de Solmarch, y
  `summarize_battle.gd` contó las 11 muertes por ruta. La sesión con bots que asedian, que da los números para
  ajustar `vado_gris.tres` (GUE-17), llegó con F6a (más abajo).
- Lo que **no** hace F3: nada del cliente (`FortressView`, HUD, mapa, `RespawnPointList`), ni PNJ reales (F4),
  ni bots que asedian ni `--max-realm-diff` (F6a los trae).

**F4** (los PNJ; pruebas en `test_npc_navigation`, `test_npc_catalog`, `test_hfsm_brain` y `test_npc_system`, y ampliaciones de
`test_combat_catalog`, `test_combat_resolver`, `test_combat_server`, `test_server_config` y `test_fortress_zone`)

- **Archivos**: `scripts/server/ai/` (`NpcNavigation`, `HfsmBrain`, `NpcWorld`, `AttackTokens`, `NpcSpawnerSystem`),
  `scripts/shared/ai/` (`NpcDefinition`, `NpcCatalog`), `data/npcs/` (`hollow`, `ford_captain`, `gate_guardian`, `realm_guard` y
  `realm_captain`) y `data/combat/npc_*.tres` (4 armas, 8 ataques y 5 formas). Cambios en lo ya hecho: `AttackDefinition.unblockable`
  (y `AttackTicks.unblockable`, solo servidor, fuera de la huella), `Combatant.ignores_safe_area`, `ServerConfig.no_npcs`
  (`--no-npcs`), `NetZones.navmesh_path` / `get_npc_spawners` / `get_patrol_route`, `CombatDirector.emit_event` y, en `ZoneServer`,
  `add_npc(..., definition)`, `get_npc_system`, `get_npc_ids`, `get_npc_brain`, `get_physics_space`, el paso 0 del tick
  (`_run_npc_brains`) y el aviso TELEGRAPH.
- **Navegación**: `NpcNavigation` monta un mapa propio (iteraciones síncronas), la región de `<escena>_navmesh.tres` (junto a la
  escena de la zona) y un enlace por el vano de cada puerta (2,5 m dentro y 3 m fuera del origen de `FortGate`). La región está en la
  capa de navegación 1; el enlace, en la del reino dueño (bit 1 el bando neutral de los Huecos, bits 2 a 4 los reinos 1 a 3) y en las de
  todos con la puerta rota; cada consulta pide la capa de la región más la de su reino, así que cruza por el enlace quien también
  cruza la puerta de verdad. `poll()` da el mapa por listo cuando una consulta de prueba (un vértice de la malla) devuelve un punto de
  ella, y hasta entonces `get_path` devuelve una ruta vacía sin tocar el servidor de navegación. `NpcSpawnerSystem` no genera PNJ hasta
  que está lista (como mucho 600 ticks; luego van en línea recta).
- **Números del catálogo** (`npc_def_id`, por orden alfabético): `ford_captain` 1, `gate_guardian` 2, `hollow` 3, `realm_captain` 4 y
  `realm_guard` 5. `BossInfo` (cliente) da los mismos nombres y `is_boss` (lo comprueba `test_npc_catalog`). Las armas de PNJ cambian
  los ids del catálogo de combate (los `npc_*` van antes que los `sword_*`: `sword_shield` pasa de 1 a 5, `sword_heavy` de 1 a 9...)
  y el `sim_hash`; nada dependía de un número fijo salvo `test_combat_catalog` y `test_action_machine`, que ahora buscan por nombre.
- **Armas** (anticipación → daño): Hueco `npc_hollow_swipe` (0,50 s → 70, alcance 2,4 m) y `npc_hollow_slam` (fuerte, 0,75 s → 160,
  tambaleo y empuje); guardia del reino `npc_guard_slash` (0,45 s → 85) y `npc_guard_bash` (0,70 s → 150); Capitán `npc_captain_sweep`
  (barrido de 170°, 0,60 s → 110, bloqueable) y `npc_captain_crush` (fuerte **imbloqueable**, 1,00 s → 300, alcance 3,5 m);
  Guardián `npc_guardian_halberd` (0,50 s → 260, alcance 3,6 m) y `npc_guardian_thrust` (no se usa). El combo de tres ligeros repite el
  mismo ataque (sin ventana de enlace: cada ataque es una decisión del cerebro). Vida: Hueco, guardia del reino y Guardián 2500,
  Capitán del Vado 30 000 y capitán del reino 15 000 (7500 desde F6b, provisional: ver F6b). El `CombatResolver` salta la parada y el bloqueo con `unblockable` (la esquiva
  invulnerable sigue valiendo) y no frena a un atacante con `ignores_safe_area` en la zona segura de su propio reino.
- **Cerebro** (`HfsmBrain`): piensa cada 6 ticks, escalonado por `net_id` (`THINK_INTERVAL_TICKS`), y en el paso 0 del tick (antes de
  simular a nadie). Percepción: radio, cono y rayo de línea de visión (más el «oído» de `awareness_radius`, que también necesita
  línea de visión); quien está a salvo en la zona segura de su reino no cuenta, y los Guardianes (`ignores_safe_area`) solo ven a los
  enemigos que están dentro de la del suyo. Amenaza: daño recibido de cada enemigo (el `DamageLedger`) más cercanía, con 60 puntos de
  ventaja al objetivo actual. Un golpe recibido sin ver a nadie lleva derecho al combate. Ataca solo con una ficha
  (`AttackTokens`, 2 por objetivo, caducan a 1 s sin renovar); sin ella rodea a 3,5 m (retrocede por debajo de 3,1 y se acerca por
  encima de 4,0). Antes de atacar decide el siguiente ataque (el especial cada `special_every`, si no bloqueo, fuerte o ligero según sus
  probabilidades) y lo recuerda hasta hacerlo; el fuerte se pide manteniendo PRIMARY durante la carga mínima. La correa es el radio
  desde su puesto: al pasarla (o al perder al objetivo, a los 3 s) pasa a REGRESO, **inmune** (`protected_until`) hasta llegar, y al
  llegar o al perder el combate junto a su puesto queda **regenerado**; si no llega en 60 s o se atasca tres veces, se teletransporta.
  Alertado desde lejos (grito) no pierde al objetivo hasta los 60 m.
- **Generadores** (`NpcSpawnerSystem`): un puesto por `NpcSpawner`; ALWAYS siempre, FORT_NEUTRAL con el fuerte neutral y FORT_OWNER con
  dueño (y fuera de CONSOLIDATING). Si el fuerte no tiene generadores FORT_OWNER, la guarnición sale de **los puestos de los Huecos**
  con la definición que cada una nombra en `garrison_id` (`hollow` → `realm_guard`, `ford_captain` → `realm_captain`), con su misma
  ruta de patrulla y su grupo de alerta: no hizo falta tocar la escena. Con `respawn_s > 0` reaparecen en el tick exacto (muerte +
  `respawn_s`); sin él los repone la fortaleza: `garrison_due` (completa o solo el capitán), `guards_respawn_due` (los guardias que
  faltan) y la reaparición completa de los Huecos. `defenders_retired` o pasar a inactivo retiran a los vivos y a los cadáveres.
  Los cadáveres se quedan 300 ticks (5 s) y el `CombatDirector` ya no reaparece solo a los PNJ. Registra al capitán
  (`register_captain`) y a los demás (`register_defender`) y cuenta los guardias vivos con `set_guards_alive`. La señal
  `npc_died(net_id, spawner, killer)` avisa de cada muerte (la fortaleza ya se entera sola por los DEATH).
- **Capitán**: el especial (`special_every = 3`) es el fuerte imbloqueable, que el `ZoneServer` avisa con un TELEGRAPH (sector, alcance
  3,5 m, `impact_in_ticks` = 60) en el tick en que lo lanza; grita al entrar en combate (alerta a todo su grupo a 60 m, solo si hay
  compañeros vivos) y al bajar al 50 % de vida llama a dos Huecos junto a él, una vez y también solo si queda alguno. El TELEGRAPH se
  manda para **todo** fuerte de un PNJ (no solo el imbloqueable): los ligeros no se avisan.
- **Decisiones donde el documento callaba**: la reaparición completa mide la distancia desde el centro del círculo y solo cuenta con el
  fuerte neutral y faltando algo; los Guardianes ven 38 m (toda su zona segura desde su puesto) y su correa es de 40 m; `--no-npcs` apaga
  el sistema (`test_fortress_zone`, que usa el doble del capitán, lo pone) y, sin él, `spawn_captain_double` sigue funcionando y
  sustituye al capitán registrado. `npc_debug` escribe una línea por PNJ de combate a menos de 60 m de quien lo pide (todos desde la
  consola) cada segundo: estado, objetivo, distancia, punto de la ruta, vida y si tiene ficha.
- **Medido** (en una máquina compartida con otra suite, así que son cotas altas): 3 bots de combate (que no esquivan ni bloquean con
  criterio) limpian los 4 Huecos del Vado Gris en unos **46 s** de juego (con el Capitán ya caído); 4 bots a los que se cura en cada
  tick derrotan al Capitán del Vado en unos **78 s** (sin curarlos, cuatro bots mueren antes de bajarle a la mitad y el Capitán regresa
  regenerado); un intruso en la zona segura muere en **4 a 5 s** con los dos Guardianes; con cuatro guardias contra uno nunca atacan más de
  dos a la vez (casi la mitad del tiempo atacan dos). Un bot que bloquea 550 ms después de ver empezar un fuerte (RTT 200 ms, 250 ms de
  reacción) bloquea todos los de un Hueco y de un guardia. Coste: el cerebro cuesta de **15 a 30 µs por PNJ y tick** (p50) y su
  `simulate()` de **32 a 55 µs**, es decir, unos **50 a 85 µs por PNJ y tick** (hasta ~100 µs en pleno combate); el sistema de
  generadores, unos 60 µs por tick con los 14 puestos del Vado Gris. Con los 9 PNJ del Vado Gris, 3 bots peleando y el resto de la
  zona, el tick tarda de media 1,3 ms.
- **Pendiente / fuera de F4**: el modelo, el tabardo y las animaciones propias de los Huecos y del Capitán (ART-15, ART-16: hoy
  se ven con el humanoide y el barrido de espada); jugarlo con personas para fijar los 60-90 s de los Huecos y los 60-120 s del
  Capitán (los bots no sirven de medida fina); el criterio de MUN-08 con `--net-sim=rtt=200` real por la red (aquí se emula el
  retardo en el bot); el LOD de IA y el sueño sin jugadores (MUN-29); `SwarmBot` y los bots que asedian lo harán en F6.

**F5** (cliente: todo en `scripts/client/`, `tools/` y `assets/maps/`; no toca `scripts/server` ni `scripts/shared`)

- **`FortressView`** (`scripts/client/war/fortress_view.gd`, nodo hijo de `NetClient`) y **`FortressTimeline`** (la historia
  de cambios, pura): guardan el SPAWN de la estructura y cada OBJECT_STATE con su tick y el estado acumulado
  (`FortressState.initial` más los campos de `FortressFields`; lo que no viaja sale de la definición). `state_at(t)` da el estado
  tras el tick `t`; `gate_layers_for_tick(t)` mira el estado tras `t − 1`, porque un cambio con `tick = s` vale desde `s + 1`.
  `advance(render_tick)` (lo llama `NetClient` cada tick de física) aplica estandartes (`faction_color` de `Estandarte`,
  `EstandartePuertaN` y `EstandartePuertaS`), la pose de la puerta y la señal `state_changed`; el progreso es la fórmula en el
  instante de dibujo. `ClientPrediction.before_simulate` es el gancho de 8.2: se llama antes de **cada** `simulate()` (aparición,
  paso y repeticiones). **Contrato con el servidor:** el dueño y la rotura de la puerta tienen que llegar con el tick en el que
  cambiaron de verdad (el controlador de F3 manda los que ven los clientes). `OnlineMain` enlaza la vista con la zona (`set_zone`).
- **Interfaz de guerra** (`WarHud`, hijo del `HUD` por debajo de la pantalla de muerte): `CapturePanel` (a menos de 80 m del
  fuerte o combatiendo a menos de 200 m), `WarBanners` (los siete WAR), `BossBar` (jefes por `npc_def_id` del SPAWN de NPC: `BossInfo`
  lee `data/npcs/*.tres` por orden alfabético, como `NpcCatalog`, y sin la carpeta no hay jefes), `TelegraphMarks` (malla plana provisional
  que se llena hasta el impacto), `Compass` y `WorldMarkers` (`MarkerSource` junta fuerte, puerta, círculo, campamentos y pasos),
  `Minimap`, `KillFeed` y `HintToasts`. El `HUD` monta además, por encima de la pantalla de muerte, `WorldMap` y `ScoreboardPanel`.
- **Mapa** (`tools/bake_zone_map.gd` y `ZoneMapBaker`): `assets/maps/vado_gris.png` (1024 x 1024 px, 0,6 MB, por LFS) y
  `vado_gris_map.tres` (`ZoneMapDefinition`: origen (−160, −160), 320 x 320 m y los lugares fijos); ver docs/zonas/vado_gris.md. El
  minimapa va abajo a la derecha (la esquina de arriba es del panel de depuración F3) y se acerca y aleja con `map_zoom_in` y
  `map_zoom_out`.
- **Reaparición:** `RespawnPointList.options` agrupa los marcadores contiguos del mismo sitio (los cuatro de un campamento, los del patio)
  en una opción y marca válidas las que da `RespawnRules`; la pantalla de muerte ofrece solo las válidas, se actualiza mientras está abierta
  y envía el **índice del marcador entre todos los de la zona** (repartido por `net_id` entre los de un mismo sitio), como pide la
  sección 5. «Elegir en el mapa» (o M con la pantalla abierta) abre `WorldMap` en modo de reaparición. Hasta que el servidor adopte el
  índice estático (F3), el de este árbol lo interpreta sobre los puntos de su reino.
- **Marcador y bajas:** `ScoreboardPanel` (Tab mantenida) pinta el último SCOREBOARD completo y `KillFeed` cada KILL (el evento llega a
  toda la zona); el nombre y el reino de cada id salen de `PlayerDirectory`, que recuerda cada SPAWN visto. **Límite:** quien nunca estuvo
  en el radio de interés sale como «Jugador N»; haría falta un mensaje con nombres.
- **Pistas:** `HintCatalog` (siete, con las teclas reales de `UIKeyGlyph`), `HintLog` (`user://hints.cfg`) y el ajuste «Pistas del juego»
  (`ClientSettings.HINTS`). Sin pantalla (headless: pruebas y procesos de prueba) el `HintLog` es solo de memoria y no escribe en `user://`.
- **Selección de reino:** `RealmSelect` enseña el recuento por reino del último WELCOME (no hay otro antes de conectar), recomienda el
  más corto y, tras un REJECT 9, deja el reino rechazado sin elegir y marcado, con el texto de `NetProtocol.result_text` y el reino corto
  ofrecido. El servidor rellena el recuento en F6.
- **Teclas nuevas** (`InputBindings`): `open_map` (M), `map_zoom_in` (+), `map_zoom_out` (−) y `scoreboard` (Tab).
- **Pendiente del usuario:** todo lo visual de esta interfaz son constantes provisionales (tamaños, colores, posiciones, duraciones,
  estilo del mapa, textos de pistas y banners, marca del TELEGRAPH, iconos de los marcadores); la dirección de arte es ART-12 y ART-17.
- Pruebas: `test_fortress_view`, `test_fortress_prediction` (dos mundos de física con la puerta y el cambio de dueño a mitad),
  `test_capture_hud`, `test_compass_markers`, `test_zone_map`, `test_world_map`, `test_scoreboard`, `test_hints`, y ampliaciones de
  `test_net_client`, `test_realm_select`, `test_client_settings` y `test_hud_combat`.

**F6a** (bots que asedian, equilibrio de reinos y carga: GUE-15, GUE-16, GUE-42 y la parte de GUE-17 que no necesita PNJ;
pruebas en `test_realm_balance`, `test_bot_brain_siege`, `test_siege_zone`, `test_siege_clients` y ampliaciones de `test_server_auth`,
`test_server_config`, `test_zone_server_net`, `test_server_main`, `test_siege_view`, `test_battle_summary`, `test_load_test` y
`test_server_metrics`)

- **Equilibrio de reinos (GUE-42)**: la regla exacta está en la sección 7. Archivos: `scripts/server/realm_balance.gd` (reglas
  puras), `filler_keeper.gd` (los falsos de relleno), `server_auth.gd` (IMBALANCE tras el proveedor de identidad),
  `ZoneServer.get_realm_counts()` (personas por reino: el recuento del WELCOME y del rechazo) y `ServerMain` (cablea las altas y
  bajas de personas con el `FillerKeeper`; desde F6b lo hace `ZoneServer.set_filler_keeper()`). `NetProtocol.Result.IMBALANCE` y
  el texto ya venían de F2. `RealmSelect` (F5) ya mostraba el recuento y el rechazo. Un `--max-realm-diff` sin `--fake-players`
  solo rechaza.
- **`BotBrain.Pattern.SIEGE`** (al final del enum; COMBAT y el resto no cambian: una prueba compara la huella de 600 ticks de COMBAT y
  de WANDER con la del código anterior). `set_siege(view, routes, realm)` le da un `SiegeView` (que puede compartirse entre bots: sus
  preguntas llevan el reino), las `ApproachRoutes` y su reino; el buscador de enemigos es el de COMBAT (`set_enemy_finder`). En cada tick
  decide por este orden, y `get_siege_task()` dice qué ha hecho (`FIGHT`, `MARCH`, `ASSAULT`, `HOLD`):
  1. **Pelea** con el enemigo que da el buscador si está a menos de 12 m y se puede alcanzar (no está tras una puerta que cierra el paso
     a su reino: un atacante ignora a los de dentro y un dueño sale a por los de fuera), con la misma máquina de decisiones que COMBAT.
  2. **Marcha** por la ruta de su reino, `bridge` o `ford`, que elige con su RNG con semilla al empezar y tras cada reaparición (un
     salto de posición de más de 5 m en un tick); esprinta por los tramos de más de 9 m si el último enemigo visto está a más de 25 m;
     da un punto por alcanzado a 2,5 m. Si está dentro del recinto no usa la ruta.
  3. **Asalto**: con la ruta recorrida y la puerta cerrada para su reino, se acerca a 2,3 m del centro del vano y la golpea (ligeros
     enlazados y un fuerte cargado de vez en cuando) mirándola; quieto mientras golpea.
  4. **Círculo**: con la puerta rota o suya, se alinea con el eje de la puerta (4,5 m por delante), la cruza y se queda a menos de la
     mitad del radio del centro del círculo mirando a la puerta. Atacantes y dueño hacen lo mismo: el círculo es lo que se captura y
     se defiende.
  - **Atasco**: caminando y sin avanzar 1 m en 180 ticks (3 s), un salto (dos pulsaciones en 40 ticks); si sigue igual otros 3 s, un
    desvío de ±1,2 rad durante 60 ticks, y vuelta a empezar. Pelear, golpear la puerta o esperar en el círculo no es estar atascado.
  - **Determinista**: solo usa su RNG; misma semilla y mismos mundos, mismas entradas (prueba de 4000 ticks con un enemigo que
    aparece y desaparece y una puerta que se rompe).
- **Datos**: `ApproachRoutes` gana `gate_point`, `circle_point` y `circle_radius` (el exportador los escribe y `test_siege_zone`
  comprueba que son los de la escena) y `SiegeView.set_places_from_routes()`: los `SwarmBot`, que no cargan la zona, no tienen otra
  manera de saber dónde está el fuerte. `FortressView` da las posiciones reales al bot que predice.
- **Servidor**: `ZoneServer.get_siege_view()` crea una vista por fortaleza (la primera de la zona por defecto), con las posiciones de
  la puerta y el círculo, y la pone al día en cada tick, al principio de la sección `sim` (el estado de después del tick anterior,
  como los cerebros de los PNJ de 1.7); `get_approach_routes()` carga `data/routes/<zona>.tres`. `add_fake_player` equipa a un cerebro
  SIEGE sin fortaleza (vista, rutas y buscador de enemigos). `ServerMain`: `--fake-brain=siege` (los falsos salen de su campamento,
  repartidos por turnos entre los reinos; `--fake-layout=cluster` no se aplica) y `--run-at=<tick>:<orden>` (repetible; ejecuta una
  orden de la consola, por ejemplo `fort_kill_captain`, al terminar ese tick; es lo que usan las pruebas de carga, que no tienen
  entrada estándar).
- **Clientes**: `--bot-brain=siege` vale para `--bots` y para `--bot` (no hizo falta `--swarm-brain`). `SwarmBot` no simula: sigue las
  rutas en línea recta entre puntos con las entradas de `BotBrain` y el servidor pone el suelo; su `SiegeView` lo llena a mano con los
  campos del ENTITY_SPAWN de la fortaleza y de cada OBJECT_STATE (`update_from_fields`) y sus enemigos son los jugadores de otro reino
  y los PNJ de guerra (los que traen `npc_def_id`; los maniquíes no). `--bot` lleva el `SiegeView` lleno desde `FortressView`
  (`ClientBotBrains`) y ve a los PNJ de guerra con `BotEnemySight`.
- **Herramientas**: `tools/war/siege_runner.gd` (`SiegeRunner`: el Vado Gris real en un proceso, sin red, avanzado deprisa; apunta
  llegadas a la puerta, avisos y muertes) y `tools/war/siege_battle.gd` (la batalla larga con informe y resumen del registro).
  `tools/load_test.gd --siege` (el escenario de GUE-16) y `LoadTestSummary.parse_tick_timeline/timeline_window`. El resumen del
  servidor gana el **p95**, y `BattleSummary` una clase de muerte nueva, `gate` («explanada y patio», a menos de 25 m del círculo):
  las dos rutas acaban ahí y sin ella casi todas las muertes del asalto salían como «vado».
- **Órdenes de arranque de los experimentos** (desde la raíz del proyecto; los logs y temporales, en `build/`):
  ```
  godot --headless --path . -s res://tools/war/siege_battle.gd -- --per-side=20 --minutes=15 --battle-log=build/siege20.jsonl
  godot --headless --path . -s res://tools/war/siege_battle.gd -- --scenario=war --per-side=20 --minutes=8
  godot --headless --path . -s res://tools/load_test.gd -- --siege --out=build/load_siege
  godot --headless --path . -s res://tools/war/summarize_battle.gd -- build/siege20.jsonl
  ```
  Las pruebas de la suite son versiones cortas (pocos bots, captura x30 con la orden 11, la puerta recortada en las de red).

**Medido en F6a** (sin PNJ: el capitán lo da por muerto `fort_kill_captain`, o lo matan los bots si es el doble de pruebas):

- **Llegada a la puerta desde el campamento** (con esprint, 5 y 7,5 m/s): por el **puente 24,3–25,1 s** y por el **vado 36,5–37,5 s**
  (20 por bando; seis bots de la prueba corta: 24,6 y 37,5 s). Solmarch, el reflejo exacto. Los 20 de cada bando llegan siempre por
  las dos rutas (con la semilla 1000 salieron 11 por el puente y 9 por el vado).
- **Puerta** (9000 de vida): rota **14,9 s después del primer golpe** con 20 atacantes, 21,9 s con 10 y 36,9 s con 6 (llegan
  escalonados, y los últimos del vado tardan 12 s más que los del puente).
- **Captura del fuerte neutral por Vardheim** (20 bots, captura a la velocidad de verdad): puerta rota a los 40 s, capitán caído a
  los 40 s, **capturado a los 55,9 s** de empezar (15,0 s capturando con cuatro o más en el círculo: 21 600 / 24 = 900 ticks).
- **Recaptura por Solmarch** (otros 20 que salen cuando Vardheim ya tiene el fuerte y lo defienden sus 20): **360 s (6,0 min)**, de
  los cuales la puerta cuesta **199,5 s** desde el primer golpe y, caído el capitán, el círculo cuesta 135,8 s hasta capturar
  (117,7 s de disputa dentro y 18,1 s capturando). Con 10 contra 10, 527 s (8,8 min; la puerta, 398,6 s). Los **dos bandos son
  iguales pero los defensores ganan por mucho**: 140 muertes de jugadores en esos 416 s, 108 de Solmarch y 32 de Vardheim (131 en la
  explanada y el patio, 9 en el vado, ninguna en el puente). Causa: los refuerzos del atacante llegan a cuentagotas (30 s de
  reaparición en oleadas de 10 s más 25–37 s de marcha) y el defensor, que está en el círculo a 11,5 m de la puerta, sale a por ellos
  a cada paquete (hallazgo, más abajo).
- **Versión corta de la suite** (`test_siege_zone`, seis bots por bando con la captura x30 de la orden 11, el Vado Gris real): neutral →
  Vardheim con `fort_kill_captain` en 64,0 s y → Solmarch 121,0 s después (la consolidación, 120 s, es casi todo); con el doble del
  capitán, los bots lo matan ellos y capturan a los 67,3 s.
- **Carga** (`load_test.gd --siege`, 120 s de medida con los bots ya en la puerta, el servidor en la misma máquina de **4 núcleos con
  otro agente ejecutando su propia suite de Godot a la vez**: `uptime` 0,87 al empezar y 1,66 al acabar, con dos procesos
  `run_tests.gd` ajenos en marcha; la primera pasada, sin el p95, dio los mismos cuadros con un p99 peor, 31 ms, y 0,9 a 2,2 de carga).
  Tick en µs del último tramo de 34 s del servidor; PNJ: **0** (todavía):

  | Asedio | Jugadores | Tick p50 / p95 / p99 / máx | `sim` p50 | `snapshot` p50 | `war` p50 / p99 | Bajada por cliente | Sustituidas (ventana) | Rebobinados rechazados |
  |---|---|---|---|---|---|---|---|---|
  | **32 contra 32** (54 falsos + 10 bots) | 64 | 10,6 / 15,3 / 19,1 / 27,8 ms | 6,8 ms | 1,6 ms | 0,11 / 1,4 ms | 36,1 KB/s | 0,00 % | 0 |
  | **64 contra 64** (118 falsos + 10 bots) | 128 | 14,8 / 22,0 / 26,4 / 42,8 ms | 12,0 ms | 0,002 ms | 0,10 / 2,4 ms | 28,5 KB/s | **50,76 %** | **25** (6 sospechosos) |

  Las marcas de 10 s del servidor (cada una sobre los 34 s anteriores) dan en la ventana un p99 mediano de 19,3 ms (el peor, 20,2 ms)
  con 32 contra 32 y de 32,5 ms con 64 contra 64; las máximas de un tick llegan a 72,5 ms. Criterios de red.md (14 y 16):
  - **p99 < 8 ms con 64 jugadores: NO se cumple** (19,1 ms; el p50 ya es 10,6 ms). Es la misma situación que en la refriega de TEC-15
    (p99 15,9 ms con 64 combatientes en reposo): domina `simulate()` en GDScript (77 µs por personaje, 6,8 ms de `sim` de los 10,6),
    no el fuerte.
  - **≤ 37 KB/s por cliente: se cumple con 32 contra 32** (36,1 KB/s: el snapshot lleno de 1187 B a 30 por segundo); con 64 contra
    64 el servidor no llega a mandar todos (28,5).
  - **< 1 % de entradas sustituidas: se cumple con 64 jugadores (0,00 %) y no con 128 (50,76 %)**, y con 128 el rebobinado empieza a
    fallar a los honrados (25 rechazos, 6 sospechosos), como ya pasaba con 128 en la refriega. **Primer límite de jugadores por batalla
    en el fuerte: 64 (32 contra 32)**; 64 contra 64 queda fuera de lo que el servidor sostiene hoy.
  - **El coste de las fortalezas es despreciable**: la sección `war` (paso 4b) cuesta de mediana 0,10–0,11 ms y de p99 1,4–2,4 ms
    (la presencia se recuenta cada 6 ticks con todos en el círculo), unos 300 `OBJECT_STATE` y 90 marcadores en los 3 minutos. El
    combate (`combat`) cuesta 0,9 ms de mediana con 64 y 1,5 con 128; los golpes con rebobinado, de 57 a 70 µs por comprobación.
  - Con 64 jugadores la batalla da 138 muertes y 1889 golpes en 175 s; con 128, 268 y 3476. La captura llega en ambos a los 74 s del
    ciclo (15 s desde la caída del capitán); la puerta se rompe 25,7 s (32 contra 32) y 12,6 s (64 contra 64) después del primer golpe.
- **GUE-17**: las sesiones de arriba están documentadas con su registro de batalla y su resumen
  (`summarize_battle.gd`); los números sirven para ajustar `vado_gris.tres` **cuando haya PNJ** (F6b): hoy no hay capitán ni
  guarnición, así que la duración de la puerta (9000) y la consolidación (120 s) no se tocan con estos datos.

**Desviaciones y hallazgos de F6a**

- **Defender la pasarela** (7) se queda en **defender el círculo**: la pasarela está a 3,35 m, se sube por rampas y pide navegación
  (`NpcNavigation`, F4); un bot con rutas planas no sabe subir. Los bots dueños se quedan en el círculo, donde ya cuentan en la presencia y
  disputan la captura, y salen a por quien se acerca a menos de 12 m. Queda para F6b con la malla de navegación.
- **Los bots que entran por la puerta tienen que alinearse con su eje**: el último punto de la ruta del puente está de lado
  (−25, −2) y tirar derecho al círculo desde ahí estrella al bot contra la empalizada (lo encontró la prueba de defensores). Con el eje
  de la puerta (`SIEGE_GATE_*`) entran todos.
- **Refuerzos a cuentagotas**: hoy cada bot sale solo cuando reaparece, y los defensores derrotan a los atacantes por partes
  (3,4 muertes del atacante por cada una del defensor en el 20 contra 20). Antes de ajustar `vado_gris.tres` con PNJ conviene decidir si el
  atacante espera a sus compañeros en la explanada o si es un efecto deseado (backlog GUE-44).
- **Los falsos de relleno ocupan plazas** (`FULL` cuenta todos los jugadores): con `--max-players` igual a `--fake-players` el servidor
  rechaza con «lleno» a la persona que debería sustituir a un falso (backlog GUE-43). Las pruebas dejan sitio. Resuelto en F6b (más
  abajo).
- **`FortressView` fallaba con una `FortressDefinition` en el metadato de la fortaleza** (`String(<recurso>)` no existe; solo pasaba con
  las escenas de prueba) y `test_fortress_loopback` fallaba ya en el `b2adb5c`; arreglado (`_definition_of_node`).
- **`test_combat_cheaters_in_real_processes...`** fallaba en el `b2adb5c` con la máquina cargada: los tres tramposos entran a los ~170
  ticks y su cuenta de 640 pasaba de los 760 del servidor, así que salían con el aviso de cierre y código 1. El servidor vive 960
  ticks (17 s la prueba).
- La clasificación de muertes de `BattleSummary` ganó la clase `gate`; el `ROUTE_MAX_DISTANCE` de 30 m seguía clasificando como «vado»
  el asalto entero.
- `SiegeView` desconocido (`known` false) es un fuerte entero; **conocido y con `gate_health` 0 es una puerta rota**: las
  pruebas que lo llenan a mano tienen que dar la vida de la puerta.
- En un `SceneTree` (`-s herramienta.gd`), los nodos añadidos a `root` en `_initialize()` no están dentro del árbol hasta el primer
  fotograma: `siege_battle.gd` espera `process_frame` antes de nada.

**Lo que no hace F6a (queda para F6b, después de F4)**: la prueba de extremo a extremo neutral → Vardheim → Solmarch con los PNJ de
verdad (Huecos, Capitán del Vado y guarnición), el criterio de `--bots=20` por bando sin ninguna intervención (hoy: con
`fort_kill_captain`), la defensa de la pasarela y la repetición de la carga con los PNJ. El cerebro ya está preparado: el buscador de
enemigos del servidor incluye a los PNJ no inmortales, así que los bots que entran en el patio atacan al más cercano del dueño (con el
doble del capitán de pruebas lo hacen: `test_bots_capture_the_neutral_fort_killing_the_captain_themselves`), y `SwarmBot`/`--bot`
cuentan como enemigos a los PNJ con `npc_def_id`.

**F6b** (la segunda mitad de la fase 6: extremo a extremo con los PNJ, GUE-43, GUE-44, GUE-45 y la carga con PNJ; se hace por
paquetes, y cada uno se anota aquí)

- **GUE-43, el relleno no ocupa plazas de personas** (regla exacta en la sección 7, *Plazas*). Archivos:
  - `RealmBalance.realm_to_yield_seat()`: qué reino cede la plaza (el de más total contando a quien entra; a igualdad, el suyo y luego
    el de código más alto).
  - `FillerKeeper.yield_seat(peer_id, realm)` (retira ya el falso y apunta la plaza a nombre de esa persona),
    `on_person_joined(realm, peer_id)` (no retira otro por quien ya tiene plaza cedida) y `on_seat_abandoned(peer_id)` (repone el
    falso si se va sin entrar).
  - `ServerAuth.validate(..., filler_seats)`: el FULL descuenta los falsos de relleno.
  - `ZoneServer.set_filler_keeper()`: el servidor lleva ahora el guardián entero. Le cuenta las altas y bajas de personas (antes las
    cableaba `ServerMain` con las señales `player_joined` y `player_left`), le pide la plaza tras un HELLO aceptado con el servidor
    lleno y le avisa de cada falso que se va (`forget`). Así un falso de relleno dado de baja por otra vía (la orden `kick` de la
    consola) ya no se queda apuntado como relleno.
  - `ServerMain` solo crea el guardián y se lo da.
- **`ZoneServer.get_player_count()` ya no cuenta a los falsos con la baja pedida** (`remove_fake_player`, que se van al empezar el
  siguiente tick), igual que no contaba a los peers que se van. Hacía falta para que dos HELLO del mismo `poll` vean la plaza que acaba
  de ceder un falso. Las altas de falsos por `--fake-churn` siguen en el tick siguiente a la baja, así que el pico no cambia.
- **Decisión**: si el reino de quien entra no tiene relleno, cede su plaza el bando con más total, no se rechaza con «lleno». Se elige
  entre todos los reinos por el total con la persona contada, y no siempre el suyo primero: con Vardheim 1 contra Solmarch 3 (todo
  relleno), una persona de Vardheim deja 2 contra 2 en lugar de 1 contra 3.
- Pruebas:
  - `test_realm_balance` (ocho nuevas: qué reino cede, uno por persona, dos HELLO a la vez, reposición si se va sin entrar). Su `Rig`
    usa ahora métodos en lugar de lambdas: el ciclo Rig → guardián → lambda dejaba objetos sin liberar al salir.
  - `test_server_auth` (FULL con relleno).
  - `test_zone_server_net`, con ENet: cuatro personas entran en un servidor de cuatro plazas lleno de relleno y la quinta recibe «lleno»;
    un falso que no es de relleno sigue ocupando su plaza; quien se va mientras carga recupera el falso.
  - `test_server_main` (el proceso real de GUE-42 arranca ahora con `--max-players=6` y seis falsos). Antes del cambio, las tres personas
    del enjambre recibían «Servidor lleno».

**F6b, paquete B: los bots contra los PNJ de verdad y GUE-15 de extremo a extremo** (pruebas nuevas en `test_siege_npcs` y
`test_bot_threat_sight`, y ampliaciones de `test_bot_brain_siege`, `test_fort_gate_collision`, `test_npc_system`, `test_siege_view` y
`test_siege_zone`)

- **Lo que ya estaba**: el buscador de enemigos de los falsos incluía a los PNJ no inmortales, así que 20 bots de Vardheim ya rompían la
  puerta, mataban a los Huecos y al Capitán del Vado y capturaban el fuerte neutral sin ninguna orden desde la primera batalla con
  `--npcs` (puerta a los 40 s, capitán a los 65 s, captura a los 80 s). Lo que no salía era la recaptura: en 20 min, ninguna.
- **Cerebro (`BotBrain`, patrón SIEGE)**. Todo determinista (sin el generador del bot, salvo lo que ya lo usaba); COMBAT y WANDER no
  cambian (la prueba de las huellas sigue igual):
  - *Golpes avisados.* `BotBrain.Threat` (origen, giro y alcance de un TELEGRAPH) y `set_threat_finder`. Si está en la zona (el semiplano de
    delante hasta el alcance, con 1 m de margen: el aviso no dice el ángulo y el del Capitán es de 120°), sale de ella en línea recta
    desde quien golpea, con una **esquiva** al empezar (4,5 m en 0,45 s, con invulnerabilidad) y esprintando, sin bloquear ni acabar
    lo que hacía; si sigue dentro, otra esquiva cada 15 ticks. Tarea nueva `EVADE`, al final del enum. Medido en la captura del
    neutral con 20 bots (semilla 1000): **sin salir de la zona, 14 golpes imbloqueables dan a alguien (4475 de daño) y mueren 7 bots; con
    la esquiva, ninguno y ninguna muerte**, a cambio de 5 s más para matar al Capitán (72,9 s frente a 67,7 s). Solo esprintando, sin la
    esquiva, salían tarde (11 de 16 golpes en una versión intermedia, todos a bots que estaban saliendo: a mitad de un ataque apenas se
    mueven). Se evitan todos los fuertes avisados de los PNJ (el aviso es igual para todos), no solo el imbloqueable.
  - *Los defensores primero.* `set_defender_finder`: mientras el círculo no está activo (el capitán vive), el PNJ enemigo más cercano a
    tiro va antes que cualquier jugador. Sin esto, en la recaptura los atacantes peleaban con los 20 defensores y casi nunca con el
    capitán. Con el círculo activo, el más cercano de todos.
  - *Persecuciones sin progreso.* Si persiguiendo a alguien a más de 3 m no se acerca 1 m en 180 ticks (un guardia tras un muro o en la
    pasarela), deja de perseguir a nadie que no esté a menos de 3 m durante 600 ticks. Antes «pelear» nunca era estar atascado y nueve
    bots se quedaron un minuto contra una pared persiguiendo a un guardia de patrulla al que no podían llegar.
  - *El recinto.* `ApproachRoutes.enclosure_size` (40 x 40 m en el Vado Gris; lo escribe el exportador), `SiegeView.enclosure_size` e
    `is_inside_enclosure()`. «Dentro del fuerte» era «al otro lado de la pared de la puerta y a menos de 30 m del círculo», que incluye
    las franjas de fuera de las paredes laterales y del fondo: un bot que una pelea dejaba pegado a la pared sur por fuera iba derecho al
    círculo contra la empalizada (seis de los veinte de Solmarch, durante más de un minuto, en una recaptura con PNJ). Ahora, fuera del
    recinto y a un lado o detrás, rodea la empalizada por sus esquinas (a 6 m) hasta la pared de la puerta; y pegado a la pared de la
    puerta pero fuera del vano (más de 1,6 m de su eje), vuelve primero delante de la puerta en lugar de cruzar en diagonal.
- **Servidor**: `ZoneServer` da a cada falso SIEGE el buscador de golpes (`_find_threats`: los fuertes en curso de los PNJ de un reino
  hostil, desde que empiezan hasta el final de su ventana activa, con la posición y el giro del PNJ en ese tick, porque gira mientras
  carga; se reúnen una vez por tick) y el de defensores (`_find_enemy_position(..., npcs_only)`). La vista de asedio toma el recinto de las
  rutas.
- **Clientes**: `BotThreatSight` (cliente) guarda los TELEGRAPH como amenazas hasta su impacto más 12 ticks (el tick con el que se
  pregunta es el de la entrada que se decide); `SwarmBot` (`--bots`) lo llena con los ENTITY_EVENT y busca los defensores entre los PNJ
  de sus altas; `ClientBotBrains` (`--bot`) con `NetClient.telegraph_received` y `BotEnemySight(..., war_npcs_only)`.
- **PNJ más débiles solo para una prueba**: `NpcSpawnerSystem.set_definition_override(id, definición)` / `get_definition(id)` sustituyen una
  definición en ese servidor (el catálogo, que comparte todo el proceso, no cambia; el `npc_def_id` sigue siendo el del catálogo).
  `SiegeRunner.set_npc_health(id, vida)` y `siege_battle.gd --npc-health=<id>:<vida>` lo usan.
- **Herramientas**: `SiegeRunner` apunta las muertes de PNJ (`npc_deaths`), da el cerebro de cada bot (`get_brain`) y los avisos desde un
  tick (`tick_of_war(..., desde)`, `count_war`). `siege_battle.gd` gana `--npcs` (con los PNJ y sin ninguna ayuda), `--npc-health`,
  `--verbose` (estado cada 10 s de juego) y los hitos de cada fase en el informe (primer golpe, puerta rota y cuántas veces, capitán
  caído y captura, contados desde que salen los bots de la fase).
- **Hallazgo y arreglo: se golpeaba desde dentro de la puerta cerrada.** El dueño cruza su puerta cerrada, y quien se quedaba con el pecho
  dentro de la caja de vista golpeaba hacia fuera sin que los de fuera pudieran golpearle a él: el rayo de la línea de visión que *empieza*
  dentro de una caja no la ve. En la primera recaptura con PNJ, los defensores apiñados en el vano mataron a los 20 atacantes en la
  explanada sin perder a nadie (y a 112 contra 4 en 6 min). `HitShapes.is_ray_clear` usa ahora `hit_from_inside`: dentro de la puerta
  cerrada ni se golpea ni te golpean (las mallas cóncavas y el terreno no cambian). `test_fort_gate_collision` lo comprueba y falla sin el
  cambio. Afecta también a la percepción de los PNJ y a las placas de nombre del cliente, que usan el mismo rayo.
- Pruebas:
  - `test_siege_npcs` (la versión corta de GUE-15 con PNJ): 12 bots de Vardheim delante de la puerta (la marcha ya la prueba
    `test_siege_zone`), captura x30 y, solo en ese servidor, el Capitán con 9000 de vida y los Huecos con 1000. Rompen la puerta, matan a los
    Huecos y al Capitán ellos solos (el aviso «capitán caído» es de Vardheim) y capturan; el Capitán avisa sus golpes, alguno sale de su
    zona y a ninguno de los que salían le da el imbloqueable. Puerta a los 17 s, capitán a los 35–38 s, captura medio segundo después; la
    fase de la prueba tarda de 8 a 12 s (con la máquina cargada).
  - `test_bot_brain_siege` (seis nuevas): la zona de un golpe; sale con una esquiva sin bloquear y antes del impacto; el PNJ antes que el
    jugador más cercano, y no el de tras la puerta; deja una persecución que no le acerca y vuelve a perseguir pasado el plazo; rodea el
    recinto en lugar de atravesar la empalizada (falla sin el cambio); determinismo con los dos buscadores nuevos.
  - `test_bot_threat_sight` (tres), `test_npc_system` (la sustitución solo cambia ese servidor), `test_siege_view` (el recinto, también
    con la puerta en otra pared) y `test_siege_zone` (la vista del servidor lleva el recinto de los datos).

**Medido en F6b (paquete B)** con `siege_battle.gd --npcs --per-side=20 --minutes=28` (20 de Vardheim capturan el fuerte neutral y, en cuanto
es suyo, salen 20 de Solmarch que lo recapturan mientras los de Vardheim lo defienden; nadie da órdenes). Tiempos de juego, así que no dependen
de la máquina (4 núcleos compartidos con otras suites: cada batalla tardó de 5 a 15 min de reloj); cambian con la semilla de los cerebros. Los
tiempos de la recaptura cuentan desde que salen los de Solmarch:

| Semilla, capitán del reino | Neutral → Vardheim: puerta rota / Capitán del Vado / captura | Recaptura: puerta rota / capitán del reino / captura | Muertes de jugadores (S / V) |
|---|---|---|---|
| 1000, 15 000 de vida | 40,2 / 72,9 / **87,9 s** | 181,5 / 300,9 / **404,8 s (6,7 min)** | 111 / 39 |
| 2000, 15 000 | 42,4 / 71,3 / 86,3 s | 111,8 / 978,9 s / **no en 28 min** (la puerta cae 3 veces) | 490 / 140 |
| 3000, 15 000 | 42,3 / 71,3 / 86,3 s | 233,1 / 960,9 s / **no en 28 min** (el capitán cae 2 veces) | 453 / 114 |
| 1000, **7500** | igual | 181,5 / 278,3 / **399,4 s (6,7 min)** | 117 / 33 |
| 2000, **7500** | igual | 111,8 / 441,9 / **1654,8 s (27,6 min)** (el capitán cae 3 veces) | 433 / 149 |
| 3000, **7500** | igual | 233,1 / 357,3 / **1471,8 s (24,5 min)** (el capitán cae 2 veces) | 406 / 127 |

- **La captura del neutral es firme**: con las tres semillas, puerta a los 40–42 s (la explanada se alcanza a los 25 s por el puente y a los
  37 s por el vado), los cuatro Huecos (y los refuerzos que llama el Capitán) y el Capitán del Vado (30 000) muertos a los 71–73 s y captura a los
  86–88 s, **sin ninguna muerte de Vardheim** en las tres. Es la medida de bots de MUN-10 y MUN-11, no la de personas.
- **La recaptura es lo difícil, y no por los PNJ.** El capitán del reino con 15 000 de vida bajaba hasta un 20 % y, al caer la oleada de
  atacantes, volvía a su puesto regenerado (lo que hace un jefe cuando pierde a todos sus enemigos); con 15 000, una recaptura de tres en el
  ciclo de 30 min del Vado Gris (`reset_to_neutral_s`). Con 7500, las tres, pero dos tardan 25–28 min: el capitán cae enseguida y lo que cuesta
  es quedarse solo en el círculo frente a los 20 defensores, que ganan las peleas 3 a 1 en muertes porque los atacantes llegan por partes (30 s
  de reaparición en oleadas de 10 s más 25–37 s de marcha) y entran de uno en uno por un vano de 4 m. Es GUE-44, que decide si el atacante
  espera a los suyos o si es un efecto deseado; hasta entonces no se tocan los tiempos de `vado_gris.tres`.
- **Ajuste provisional (F6b)**: `data/npcs/realm_captain.tres`, vida **15 000 → 7500** (la mitad; un cuarto de la del Capitán del Vado). Es el
  único cambio de datos: con él la recaptura cabe en el ciclo de 30 min con las tres semillas, y sin él no. Las filas de 7500 se midieron con
  `--npc-health=realm_captain:7500`; la batalla con el dato ya cambiado da exactamente lo mismo (semilla 1000: Solmarch captura en el tick
  29 250). Se revisa con GUE-44 y, sobre todo, con personas (MUN-11 y GUE-11 piden 3–5 jugadores contra un capitán).
- **Golpes avisados en la batalla larga**: con la esquiva, ningún golpe imbloqueable dio a un bot en la captura del neutral (14 sin salir
  de la zona, ver arriba); la versión corta de la suite comprueba que a ninguno de los que estaban saliendo le da.
- **Lo que no hace este paquete**: GUE-44 (los refuerzos se juntan antes de salir), GUE-45 (la pasarela), la carga con PNJ (GUE-16) y la
  batalla con telemetría completa. La batalla larga usa los jugadores falsos del servidor (el mismo `BotBrain` que `--bots` y `--bot`, con sus
  buscadores del servidor); con `SwarmBot` por ENet y PNJ solo hay pruebas unitarias de lo nuevo (`BotThreatSight`) y las de F6a sin PNJ.

---

## 9. Riesgos

- **Coste de los PNJ**: 5–10 PNJ más con `simulate()` y su cerebro. Medido en F4: unos 50 a 85 µs por PNJ y tick (8.3); con 10 a 20
  PNJ son de 0,5 a 1,7 ms del tick de 16,7 ms. F6a midió el asedio sin PNJ (8.3); F6b repite la medida con los de F4.
- **Generador de la zona** (resuelto en F0): `vado_gris.tscn` sale de un script y los assets que
  necesita sí están en el repo, así que se regenera (no se edita a mano); ver 8.3.
- **Arte**: Huecos, Capitán, tabardos, estandartes y efectos de la puerta definitivos son del
  usuario (ART-15, ART-16, ART-17); de momento, provisionales.

---

## 10. Ampliación del combate (otro diseño corto)

CMB-19 (habilidades con reutilización), CMB-21 (habilidades de espada y escudo), CMB-20 (efectos
de estado), CMB-22/23 (proyectiles con rebobinado y arco), CMB-24 (cambio de arma), CMB-28
(derribado), UI-11 (barra de acciones) y UI-45 (iconos de estados). Se diseña en
`docs/habilidades.md` cuando el bucle del fuerte funcione, porque toca `CombatState`.
