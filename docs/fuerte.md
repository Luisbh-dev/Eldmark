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

0. **Cerebros de PNJ**: con el estado tras `s − 1`, cada `NpcBrain` empuja su entrada de `s` a su
   `InputQueue` (piensan cada 6 ticks; entre medias repiten su plan).
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

`NpcNavigation` (servidor) crea un mapa propio de `NavigationServer3D` con **iteraciones
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
- `NpcBrain` (`scripts/server/ai/npc_brain.gd`): **REPOSO → PATRULLA → ALERTA → COMBATE →
  REGRESO**; RNG con semilla por PNJ; produce `PlayerInput` sintéticas (§1.7 paso 0). Dos
  ejecuciones con las mismas entradas dan la misma secuencia de estados.
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
  por reino, sacados de `verify_vado_gris_routes.gd`), compartido.
- **`SiegeView`** (compartido, puro): dueño, fase, captor, vida de la puerta y posiciones de la
  puerta y el círculo. La llena el servidor para `--fake-players` y el cliente (`FortressView` o,
  en `SwarmBot`, decodificando OBJECT_STATE) para `--bot` y `--bots`.
- `BotBrain` gana el patrón `SIEGE`: seguir la ruta de su reino hasta el fuerte, golpear la puerta
  si está cerrada, entrar en el círculo, defender la pasarela si es el dueño y atacar al enemigo
  más cercano. Los `SwarmBot`, que no simulan, siguen las rutas en línea recta entre puntos.
- Criterio: `--bots=20` por bando capturan y recapturan sin intervención.
- **Carga** (GUE-16): escenario de `load_test` con 32 contra 32 y 64 contra 64 en la puerta y el
  círculo durante 120 s.
- **Equilibrio** (GUE-42): `--max-realm-diff=N`; un REJECT nuevo, **9 IMBALANCE**, con texto propio.
  El recuento por reino para RealmSelect llega en el WELCOME (`u8 × 3` al final; sube la versión
  con el resto; el formato ya está en F2 y el servidor lo rellena en F6, hasta entonces va a 0). Los jugadores falsos de `--fake-players` rellenan el bando corto y se retiran al
  entrar personas.
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
| **F4 · PNJ** | `NpcNavigation`, `NpcDefinition`, `NpcCatalog`, `NpcBrain`, fichas, `NpcSpawnerSystem`, armas de PNJ, Huecos, Capitán, guarnición, Guardianes | F0, F1 (`FortressState`, señales), K3 |
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

F0 (escena, capas, malla y rutas), F1 (fortaleza pura) y F2 (protocolo 3) están hechos. Además de lo de
8.2, quien siga con F3 a F6 encontrará esto:

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
  clase llega con el paquete F4. Ids en uso: `hollow`, `ford_captain` y `gate_guardian`; F4 tiene que
  crear `data/npcs/hollow.tres`, `ford_captain.tres` y `gate_guardian.tres`. Los Huecos y el Capitán
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
  tenga manejador (F3 registró del 7 al 11 y F4 registrará `npc_debug`; `test_combat_server` lista los pendientes). `NetClient`
  acepta `OBJECT_STATE`, `SCOREBOARD`, el SPAWN de estructuras y los eventos `WAR` y `TELEGRAPH` sin
  contarlos como malformados ni como eventos de combate, y los cuenta en `get_stats()`
  (`object_states`, `scoreboards`, `structure_spawns`, `war_events`, `telegraphs`); `SwarmBot`
  también acepta los dos mensajes sueltos. Quedan con `TODO(F3)`, `TODO(F5)` y `TODO(F6)` en el
  código.
- El WELCOME ya lleva `realm_counts`, pero `ZoneServer` lo manda a 0 hasta GUE-42 (F6).
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
  está registrado y pasa por la misma canalización que el mensaje propio; `npc_debug` (12) es de F4.
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
  círculo`. Los PNJ no tienen fila. El KILL va a toda la zona (el DEATH sigue yendo a los implicados).
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
  reinicio; el controlador lo convierte en `FORT_RESET`, `defenders_retired` y `garrison_due`. El Vado Gris
  (1800 s) lo trae activo.
- Lo que **no** hace F3: nada del cliente (`FortressView`, HUD, mapa, `RespawnPointList`), ni PNJ reales (F4),
  ni bots que asedian ni `--max-realm-diff` (F6).

---

## 9. Riesgos

- **Coste de los PNJ**: 5–10 PNJ más con `simulate()` y su cerebro; se mide en F6.
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
