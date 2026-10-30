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
5. Altas de jugadores y de PNJ, el paso social (invitaciones caducadas y PARTY_STATUS, social.md §12),
   historial, snapshots, OBJECT_STATE y eventos. El orden completo y normativo es el de la cabecera de
   `ZoneServer`.

Las habilidades lo completan ([habilidades.md 4.1](habilidades.md#41-orden-del-tick-completa-fuertemd-17),
paquete H3a): tras congelar, los disparos (H3b) y los efectos propios de quien está en su
compromiso; resolver incluye el vuelo de los proyectiles (H3b), y aplicar, los golpes de las habilidades y
de las flechas, los efectos al objetivo y las interrupciones; después, los pulsos y caducidades de los efectos de estado y (H3c) el derribado
(desangrado, levantar y rematar), antes del entorno, las reapariciones con su plantilla y la recarga de los consumibles en
el campamento. Todo dentro de `CombatDirector.process_tick`, antes de 4b. Un derribado no cuenta en el círculo (§1.2: no
está vivo) y sí impide reparar la puerta si está en el vano.

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
  un personaje solape el vano de la puerta rota**: se aplaza tick a tick hasta que quede libre. La de
  una puerta entera (dañada) no cambia la colisión y se hace en el acto (revisión de la fase 4).
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
- **Derribados** (H3c, [habilidades.md 4.5](habilidades.md#45-derribado-levantar-y-rematar-downedsystem-scriptsserverdowned_systemgd)):
  los PNJ no quedan derribados (su golpe mortal mata), pero rematan. En `HfsmBrain`, un jugador derribado
  hostil a ≤ 6 m es el objetivo preferido, antes que el más cercano en pie (también al notarlo en reposo o
  patrulla), y se le ataca con el ligero, sin escudo ni carga; pide su ficha de `AttackTokens` como cualquier
  objetivo. `NpcWorld` no cambia: un derribado ya es un objetivo válido (no está muerto).

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
  quedan Huecos, una vez por vida (la reaparición completa los retira y le devuelve la llamada). Al
  morir: `on_captain_died`.
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
  - Oleadas: `respawn_tick` = primer múltiplo de 600 ticks ≥ muerte + `respawn_s`. Quien no la pide
    reaparece solo en el primer múltiplo de 600 ≥ muerte + 30 s (`auto_respawn_tick`): con oleadas
    nadie reaparece fuera de una. Los jugadores falsos del servidor la piden al morir y el `--bot` en
    cuanto puede, como el `SwarmBot` y como quien pulsa el botón (revisión de la fase 4).
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
  fuerte para los bots que no cargan la zona; desde F6b, también el tamaño del recinto, `enclosure_size`, y la
  pasarela de GUE-45: su altura, su eje y sus dos rampas, `walkway_*`), compartido.
- **`SiegeView`** (compartido, puro): dueño, fase, captor, vida de la puerta y posiciones de la
  puerta y el círculo. La llena el servidor para `--fake-players` y el cliente (`FortressView` o,
  en `SwarmBot`, decodificando OBJECT_STATE) para `--bot` y `--bots`.
- `BotBrain` gana el patrón `SIEGE`: seguir la ruta de su reino hasta el fuerte, golpear la puerta
  si está cerrada, entrar en el círculo, defender el círculo si es el dueño y atacar al enemigo más cercano. La
  pasarela (GUE-45, F6b, paquete D): una cuarta parte de los bots, por su semilla, tiene su papel; los del dueño suben
  por una rampa (una ruta precalculada en `data/routes/vado_gris.tres`, comprobada con la malla de navegación de los
  PNJ) y guardan su puesto encima de la puerta, y los atacantes la recorren una vez al entrar. Desde ella no se
  alcanza con el arma a nadie del suelo, así que allí se pelea con quien sube (detalle en 8.3, F6b, paquete D). Los `SwarmBot`, que no simulan,
  siguen las rutas en línea recta entre puntos. Hecho en F6a (detalle en 8.3). En F6b pelea con los PNJ de verdad:
  busca primero a los PNJ que guardan el fuerte mientras el capitán vive, sale de la zona de los golpes avisados
  (TELEGRAPH) con una esquiva, deja las persecuciones que no le acercan y rodea la empalizada si se queda fuera a
  un lado (detalle en 8.3, F6b). Desde GUE-44 (F6b, paquete C) el atacante no sale solo de su campamento: espera a los
  suyos en la salida (8 de su reino, o 3 ya peleando en el fuerte, o como mucho la siguiente salida de un reloj común
  de 30 s) y el grupo va por la misma ruta; y en grupo cada bot lleva su hueco (formación), porque los personajes no
  chocan entre sí y los bots se apilaban en el mismo punto (detalle en 8.3, F6b, paquete C).
- Criterio: `--bots=20` por bando capturan y recapturan sin intervención. F6a lo cumple con jugadores falsos
  y la orden `fort_kill_captain` en lugar del capitán. En F6b, con los PNJ de verdad y sin ninguna orden: capturan el neutral
  siempre (86–88 s) y recapturan dentro del ciclo de 30 min con el capitán del reino en 7500 (de 6,7 a 27,6 min según la semilla);
  lo que alarga la recaptura es el círculo frente a los defensores (GUE-44), no los PNJ (8.3, F6b). Con la reunión y la formación
  de GUE-44, y cinco semillas: captura del neutral a los 80–89 s y **recaptura en 2,4 / 2,4 / 4,8 / 2,6 / 12,8 min** (mediana
  2,6 min; antes, con las mismas semillas, 6,7 / 27,6 / 24,5 / 4,4 / 5,6); con el capitán del reino en 15 000, también las cinco
  dentro del ciclo (de 2,6 a 17,4 min). Sigue dependiendo de la semilla (8.3, F6b, paquete C). Con el código final de F6b (tras su
  revisión: 8.3, «Revisión de F6b»), captura del neutral a los 75–83 s y recaptura en 3,4 / 6,7 / 2,5 / 2,5 / 2,4 min (mediana 2,5).
  Con el kit de la fase 4 en los bots (la integración de las habilidades y su revisión; con la plantilla por defecto, el escudero) y
  tres semillas: captura del neutral a los 80,0–82,4 s y recaptura en 156,1 / 146,9 / 295,6 s (8.3, «Revisión de la integración de
  las habilidades»).
  **Los «20 por bando» de todas estas medidas son jugadores falsos del servidor** (`siege_battle.gd` con `SiegeRunner`: el mismo
  `BotBrain` que `--bots` y `--bot`, con los buscadores del servidor), y así se lee el criterio desde F6a. Con `SwarmBot` por ENet hay
  pruebas cortas y la carga, pero no una batalla entera (8.3, «Lo que queda tras F6b»; backlog GUE-46).
- **Carga** (GUE-16): escenario de `load_test` con 32 contra 32 y 64 contra 64 en la puerta y el
  círculo durante 120 s (`--siege`; resultados en 8.3). Desde F6b, `--npcs` lo repite con los PNJ de la zona y el fuerte sin
  ayudas: los 9 PNJ de guerra (los 5 del fuerte y los 4 Guardianes de los campamentos) cuestan alrededor de 1 ms del tick, del orden de
  la diferencia entre dos pasadas iguales, y el límite sigue en 32 contra 32 (8.3, F6b, paquete E y su revisión). Medido sin el kit de
  la fase 4. Con él, el aforo del Vado Gris es 40 (el límite de la refriega con la mitad de tiradores, red.md 14); en el fuerte era una
  estimación hasta la revisión de la integración, que lo mide (8.3): 20 contra 20 con los PNJ da 16,2 ms de p99 con la plantilla por
  defecto y 16,9 ms (y 1,01 ms de proyectiles) con la mitad de tiradores, en el filo del criterio de la fase 4. El límite en el fuerte
  con el kit queda en 40, sin margen.
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
    Sin `--max-realm-diff` los falsos no se tocan (las pruebas de carga miden lo de siempre). *A quién se retira*
    (desde la revisión de la integración de las habilidades, también al que cede una plaza apartada, abajo): de los del
    reino que toca, el más antiguo **tranquilo**, ni derribado ni levantando o rematando a nadie (`FillerKeeper.calm_check`,
    `ZoneServer.is_fake_calm`); si ninguno lo está, el más antiguo. Y su baja **nunca es una muerte**, aunque esté
    derribado: solo el DESPAWN, sin DEATH ni KILL (`ZoneServer.retire_filler`). Antes, retirar a un derribado lo mataba
    desangrado con un KILL para quien lo derribó: la entrada de una persona sumaba una muerte a un bando.
  - *Plazas* (GUE-43, desde F6b). El relleno **no ocupa plazas de personas**: el FULL (y `--max-players`) solo cuenta
    a las personas y a los falsos que no son de relleno. Si llega el HELLO de una persona de *r* con el servidor lleno
    solo por el relleno, se acepta (pasadas las demás comprobaciones, IMBALANCE incluido) y **un falso de relleno le
    aparta su plaza**, pero no se va todavía: **se va cuando ella entra en el mundo** (desde la revisión de F6b; antes se
    iba al llegar el HELLO). Es el más antiguo del reino con más total (personas en el mundo más relleno) **contando a
    quien entra**, con lo que hay en ese momento; a igualdad, el de *r*, y si no, el de código más alto. Con los bandos
    igualados es siempre uno de *r* (la persona sustituye a un falso de su bando, como en el bando largo); si *r* ya
    no tiene relleno, cede el bando con más total, que es el que deja la batalla más igualada (la alternativa, «lleno»,
    es justo lo que GUE-43 quita). Ese falso cuenta como el que retira su entrada (sigue siendo uno por persona). Si se
    va sin llegar a entrar (corta o no termina de cargar), la plaza apartada se libera y **ningún falso se ha movido**:
    ni altas ni bajas para nadie. Mientras alguien carga en una plaza apartada el servidor tiene un jugador de más (ella y
    el falso que se la cede), y cada falso de relleno aparta como mucho una plaza: el FULL cuenta las apartadas como
    ocupadas. Las personas nunca pasan de `--max-players`: sin relleno que ceda, «lleno» como siempre.
- **Telemetría** (GUE-17): eventos de guerra y muertes en JSON Lines (`--battle-log`) y
  `tools/war/summarize_battle.gd` con el tiempo hasta la captura, las muertes por ruta y el tiempo
  hasta romper la puerta. Desde GUE-45 las muertes de PNJ también salen por sitio, y la pasarela cuenta su eje entero
  si las rutas la conocen. La sesión con los PNJ (F6b, paquete E): cinco batallas de 20 contra 20 con su registro y su resumen;
  con esos números los datos de `vado_gris.tres` no cambian (8.3, F6b, paquete E).

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

F0 (escena, capas, malla y rutas), F1 (fortaleza pura), F2 (protocolo 3), F3 (servidor del fuerte), F4 (PNJ), F5 (cliente) y F6
(F6a: bots que asedian, equilibrio de reinos y carga; F6b, por paquetes: GUE-43, los bots contra los PNJ, GUE-44, GUE-45 y la carga
y la telemetría con PNJ) están hechos; lo que queda está al final de F6b. Además de lo de 8.2, quien toque el fuerte (y lo que
toque a los PNJ) encontrará esto:

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
  o el plazo de 5 min cae sobre la **puerta rota** con alguien solapando el vano, el controlador **deshace la
  reparación**: la puerta conserva la vida rota (y la colisión abierta) en el estado y en el OBJECT_STATE, y
  se repara en el primer tick con el vano libre (`is_repair_pending`). Así cliente y servidor siguen simulando
  lo mismo. Solo cuentan personajes vivos (jugadores y PNJ) cuyos pies solapen la caja; quien pisa la pasarela
  de encima no la retiene. Una puerta entera (dañada o no) se repara en el acto aunque haya alguien en el vano:
  cerrarla no cambia su colisión. Un cambio de dueño con la puerta entera cambia las capas sin esperar (nadie
  queda atrapado en una puerta entera: solo cambia a quién para). *(Revisión de la fase 4: antes también se
  aplazaba la de la puerta entera, y la reparación aplazada se aplicaba al quedar libre el vano aunque la
  puerta hubiera recibido golpes después; un defensor quieto en el vano de su propia puerta la devolvía entera
  justo tras un asalto.)*
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
  la puerta está rota y alguien solapa el vano la reparación se aplaza como en cualquier otro cambio de dueño. `reset_to_neutral_s = 0`
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
  ventaja al objetivo actual. Un golpe recibido sin ver a nadie lleva derecho al combate; si quien le ha golpeado está más
  allá de su radio de pérdida (un arquero), le sube el radio hasta él más 4 m y va a por él (la correa o el atasco lo mandan al
  regreso inmune si no lo alcanza). Ataca solo con una ficha
  (`AttackTokens`, 2 por objetivo, caducan a 1 s sin renovar); sin ella rodea a 3,5 m (retrocede por debajo de 3,1 y se acerca por
  encima de 4,0). Antes de atacar decide el siguiente ataque (el especial cada `special_every`, si no bloqueo, fuerte o ligero según sus
  probabilidades) y lo recuerda hasta hacerlo; el fuerte se pide manteniendo PRIMARY durante la carga mínima. La correa es el radio
  desde su puesto: al pasarla (o al perder al objetivo, a los 3 s) pasa a REGRESO, **inmune** (`protected_until`) hasta llegar, y al
  llegar o al perder el combate junto a su puesto queda **regenerado**; si no llega en 60 s o se atasca tres veces, se teletransporta.
  Alertado desde lejos (grito) no pierde al objetivo hasta los 60 m. Su registro de estados (`get_state_log`, para las pruebas
  de determinismo) guarda las últimas 256 a 511 transiciones (`STATE_LOG_MAX`).
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
  compañeros vivos) y al bajar al 50 % de vida llama a dos Huecos junto a él, una vez por vida (volver regenerado a su puesto no
  rearma la llamada; la reaparición completa de los Huecos retira los refuerzos que queden y se la rearma) y también solo si queda
  alguno; nunca hay vivos más de dos refuerzos por fortaleza (los de un Capitán anterior cuentan). El TELEGRAPH se
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
  reaparición más 25–37 s de marcha; *revisión de la fase 4: decía «en oleadas de 10 s», pero los falsos del servidor no
  pedían la reaparición y salían por la automática, a los 30 s justos de morir y cada uno por su lado*) y el defensor, que está en el círculo a 11,5 m de la puerta, sale a por ellos
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
  con 32 contra 32 y de 32,5 ms con 64 contra 64; las máximas de un tick llegan a 72,5 ms. **La fila de 64 contra 64 no es de 128
  jugadores** (revisión de F6b): el enjambre se cerraba por su propio reloj y el servidor, más lento que el tiempo real, siguió sin los
  10 bots reales el último tramo, del que salen sus percentiles (lo delata el `snapshot` de 0,002 ms: no había ningún cliente al que
  mandarlos). Con los 128 vale el p99 de las marcas, 32,5 ms. Criterios de red.md (14 y 16):
  - **p99 < 8 ms con 64 jugadores: NO se cumple** (19,1 ms; el p50 ya es 10,6 ms). Es la misma situación que en la refriega de TEC-15
    (p99 15,9 ms con 64 combatientes en reposo): domina `simulate()` en GDScript (77 µs por personaje, 6,8 ms de `sim` de los 10,6),
    no el fuerte.
  - **≤ 37 KB/s por cliente: se cumple con 32 contra 32** (36,1 KB/s: el snapshot lleno de 1187 B a 30 por segundo); con 64 contra
    64 el servidor no llega a mandar todos (28,5).
  - **< 1 % de entradas sustituidas: se cumple con 64 jugadores (0,00 %) y no con 128 (50,76 %)**, y con 128 el rebobinado empieza a
    fallar a los honrados (25 rechazos, 6 sospechosos), como ya pasaba con 128 en la refriega. **Primer límite de jugadores por batalla
    en el fuerte: 64 (32 contra 32)**; 64 contra 64 queda fuera de lo que el servidor sostiene hoy. (Medido sin el kit de la fase 4;
    con arqueros y habilidades, la refriega de H5 baja el límite por batalla a 40: [red.md 14](red.md#14-presupuesto-de-ancho-de-banda-y-cpu).)
  - **El coste de las fortalezas es despreciable**: la sección `war` (paso 4b) cuesta de mediana 0,10–0,11 ms y de p99 1,4–2,4 ms
    (la presencia se recuenta cada 6 ticks con todos en el círculo), unos 300 `OBJECT_STATE` y 90 marcadores en los 3 minutos. El
    combate (`combat`) cuesta 0,9 ms de mediana con 64 y 1,5 con 128; los golpes con rebobinado, de 57 a 70 µs por comprobación.
  - Con 64 jugadores la batalla da 138 muertes y 1889 golpes en 175 s; con 128, 268 y 3476. La captura llega en ambos a los 74 s del
    ciclo (15 s desde la caída del capitán); la puerta se rompe 25,7 s (32 contra 32) y 12,6 s (64 contra 64) después del primer golpe.
- **GUE-17**: las sesiones de arriba están documentadas con su registro de batalla y su resumen
  (`summarize_battle.gd`); los números sirven para ajustar `vado_gris.tres` **cuando haya PNJ** (F6b): hoy no hay capitán ni
  guarnición, así que la duración de la puerta (9000) y la consolidación (120 s) no se tocan con estos datos. Hecho en F6b (paquete
  E, más abajo): con los PNJ tampoco cambian.

**Desviaciones y hallazgos de F6a**

- **Defender la pasarela** (7) se queda en **defender el círculo**: la pasarela está a 3,35 m, se sube por rampas y pide navegación
  (`NpcNavigation`, F4); un bot con rutas planas no sabe subir. Los bots dueños se quedan en el círculo, donde ya cuentan en la presencia y
  disputan la captura, y salen a por quien se acerca a menos de 12 m. Queda para F6b con la malla de navegación. Hecho en F6b
  (paquete D, GUE-45, más abajo), con una ruta precalculada que la malla da por buena.
- **Los bots que entran por la puerta tienen que alinearse con su eje**: el último punto de la ruta del puente está de lado
  (−25, −2) y tirar derecho al círculo desde ahí estrella al bot contra la empalizada (lo encontró la prueba de defensores). Con el eje
  de la puerta (`SIEGE_GATE_*`) entran todos.
- **Refuerzos a cuentagotas**: hoy cada bot sale solo cuando reaparece, y los defensores derrotan a los atacantes por partes
  (3,4 muertes del atacante por cada una del defensor en el 20 contra 20). Antes de ajustar `vado_gris.tres` con PNJ conviene decidir si el
  atacante espera a sus compañeros en la explanada o si es un efecto deseado (backlog GUE-44). Decidido en F6b (paquete C, más abajo): se
  reúnen en su campamento y van en formación; la causa de fondo era que los bots se apilan.
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
cuentan como enemigos a los PNJ con `npc_def_id`. Hecho todo en F6b (más abajo; la pasarela, con lo que permiten las armas cuerpo
a cuerpo), salvo que una persona juegue contra ellos.

**F6b** (la segunda mitad de la fase 6: extremo a extremo con los PNJ, GUE-43, GUE-44, GUE-45 y la carga con PNJ; se hace por
paquetes, y cada uno se anota aquí)

- **GUE-43, el relleno no ocupa plazas de personas** (regla exacta en la sección 7, *Plazas*). Archivos:
  - `RealmBalance.realm_to_yield_seat()`: qué reino cede la plaza (el de más total contando a quien entra; a igualdad, el suyo y luego
    el de código más alto).
  - `FillerKeeper.yield_seat(peer_id, realm)` (retira ya el falso y apunta la plaza a nombre de esa persona),
    `on_person_joined(realm, peer_id)` (no retira otro por quien ya tiene plaza cedida) y `on_seat_abandoned(peer_id)` (repone el
    falso si se va sin entrar). Desde la revisión de F6b, `reserve_seat`, `release_seat` y `reserved_count`: la plaza se aparta en el
    HELLO y el falso se retira en `on_person_joined` (ver «Revisión de F6b», más abajo).
  - `ServerAuth.validate(..., filler_seats)`: el FULL descuenta los falsos de relleno (desde la revisión, los que aún no han apartado
    su plaza a nadie).
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
    un falso que no es de relleno sigue ocupando su plaza; quien se va mientras carga recupera el falso (desde la revisión de F6b el
    falso no llega a irse: ver «Revisión de F6b»).
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
  de sus altas; `ClientBotBrains` (`--bot`) con `NetClient.telegraph_received` y `BotEnemySight(..., war_npcs_only)`. Desde la
  revisión de F6b solo guardan los avisos de quien les puede dañar, como el servidor (`SwarmBot`, los de los PNJ de guerra enemigos
  de sus altas; `--bot`, `BotThreatSight.is_hostile_view` con el reino del remoto): antes esquivaban también los fuertes de la
  guarnición de su propio reino.
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
    zona y a ninguno de los que salían le da el imbloqueable. Es determinista: en este paquete, puerta a los 17 s, capitán a los 35–38 s
    y captura medio segundo después; con GUE-44 y GUE-45, 19,8 / 42,4 / 42,9 s, y con el código final (tras la revisión de F6b),
    **puerta a los 19,8 s, capitán a los 36,6 s y captura a los 37,4 s**, con 3 golpes avisados. La fase de la prueba tarda unos 7 s con
    la máquina poco cargada y hasta 12 s con ella cargada.
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
  de reaparición, cada uno por su lado y fuera de oleada, más 25–37 s de marcha: revisión de la fase 4) y entran de uno en uno por un vano de 4 m. Es GUE-44, que decide si el atacante
  espera a los suyos o si es un efecto deseado; hasta entonces no se tocan los tiempos de `vado_gris.tres`.
- **Ajuste provisional (F6b)**: `data/npcs/realm_captain.tres`, vida **15 000 → 7500** (la mitad; un cuarto de la del Capitán del Vado). Es el
  único cambio de datos: con él la recaptura cabe en el ciclo de 30 min con las tres semillas, y sin él no. Las filas de 7500 se midieron con
  `--npc-health=realm_captain:7500`; la batalla con el dato ya cambiado da exactamente lo mismo (semilla 1000: Solmarch captura en el tick
  29 250). Se revisa con GUE-44 y, sobre todo, con personas (MUN-11 y GUE-11 piden 3–5 jugadores contra un capitán). Revisado en el
  paquete C: con GUE-44 los bots recapturan dentro del ciclo también con 15 000, así que el ajuste ya no hace falta para ellos; se deja en
  7500 hasta probarlo con personas.
- **Golpes avisados en la batalla larga**: con la esquiva, ningún golpe imbloqueable dio a un bot en la captura del neutral (14 sin salir
  de la zona, ver arriba); la versión corta de la suite comprueba que a ninguno de los que estaban saliendo le da.
- **Lo que no hace este paquete**: GUE-44 (los refuerzos se juntan antes de salir), GUE-45 (la pasarela), la carga con PNJ (GUE-16) y la
  batalla con telemetría completa. La batalla larga usa los jugadores falsos del servidor (el mismo `BotBrain` que `--bots` y `--bot`, con sus
  buscadores del servidor); con `SwarmBot` por ENet y PNJ solo hay pruebas unitarias de lo nuevo (`BotThreatSight`) y las de F6a sin PNJ.

**F6b, paquete C: GUE-44, la reunión y la formación de los bots de asedio** (pruebas nuevas en `test_bot_brain_rally`; ampliaciones de
`test_siege_zone` y `test_siege_clients`)

- **Decisión**: los refuerzos a cuentagotas **no** son un efecto deseado. Un atacante que empieza o reaparece en su campamento espera a
  los suyos y sale en grupo, y en grupo cada uno va en su hueco. Las dos cosas hacen falta: cada una por separado mejora poco o nada
  (tabla de abajo).
- **Hallazgo: los bots se apilan.** Los personajes no chocan entre sí (su máscara de colisión no lleva la capa de personajes), y los bots que
  siguen los mismos puntos (los cuatro puntos de reaparición del campamento, la ruta, el sitio desde el que golpean la puerta, el círculo)
  acaban exactamente en el mismo sitio. Un golpe que barre (el sector del arma) da a todo el montón a la vez. Con la reunión y sin
  huecos (semilla 2000), el primer grupo de Solmarch (20 bots en cuatro pilas de cinco, una por punto de reaparición, que delante de la
  puerta eran casi una sola) murió entero en 1,2 s sin matar a nadie: cada golpe de los defensores que salían daba a 19 a la vez (en esos
  40 s, 194 golpes de Vardheim contra 48). Esto, y no el círculo, es lo que
  daba a los defensores su 3 a 1: también ellos esperan apilados en el círculo, y quien golpea primero a la pila gana. Una persona no se
  apila; los bots sí, por eso la formación va en el cerebro y no en la simulación.
- **Reunión** (`BotBrain`, patrón SIEGE; determinista, sin generador). Al empezar y tras cada reaparición (un salto de más de 5 m), si es
  atacante (el fuerte no es suyo) y está a menos de 15 m del **punto de reunión** (la salida del campamento: el primer punto de sus
  rutas, `get_siege_rally_point()`; los cuatro puntos de reaparición quedan dentro), espera allí (tarea nueva `RALLY`, al final del enum)
  hasta que se cumple una de tres:
  - hay **8 de su reino** a menos de 15 m del punto (él incluido; `SIEGE_RALLY_GROUP_SIZE`);
  - hay **3 de los suyos a menos de 25 m del círculo** (`SIEGE_RALLY_JOIN_COUNT`, `SIEGE_RALLY_FORT_RADIUS`): un asalto en marcha no se
    deja sin refuerzos, porque entre una oleada y la siguiente el capitán se cura y la puerta se repara;
  - llega la siguiente **salida del reloj común**: una cada 30 s de partida (`SIEGE_RALLY_PERIOD_TICKS`), 5 s después de una oleada de
    reaparición (`SIEGE_RALLY_OFFSET_TICKS`; las oleadas caen en múltiplos de 600 ticks). *Revisión de la fase 4: hasta entonces los
    falsos del servidor no reaparecían en oleada (salían por la automática, a los 30 s justos), así que el desfase de 5 s no les servía
    de nada; ahora piden la reaparición al morir y sí.* El tick es común a todos los bots, así que los
    que esperan salen juntos sin hablarse (`next_rally_departure`).
  Todo el grupo va por **la misma ruta**: la de la vuelta del reloj en la que sale (`rally_route_index`, alternan), no la del generador de
  cada uno; las salidas del reloj caen a mitad de vuelta, así que unos ticks de diferencia entre clientes no la cambian. El dueño no espera
  (defiende en cuanto puede) y deja de esperar si su reino pasa a ser el dueño. Mientras espera pelea con quien se le acerque, como en
  la marcha. Los cuenta quien da `set_ally_counter(center, radius) -> int` (los jugadores vivos de su reino a esa distancia, sin él);
  **sin contador, o con `set_rally(1)` o menos, no espera ni va en formación: el comportamiento de F6a y del paquete B**, que es el de las
  pruebas del cerebro que no lo ponen.
- **Formación**: en grupo (con contador y reunión), cada bot tiene un hueco, un punto del disco unidad que sale de su semilla por la
  sucesión R2 (`slot_for_seed`; con veinte semillas seguidas el par más cercano queda de media a 0,19 y nunca a menos de 0,1 en las
  bases de 0 a 6000, aunque en una de cada diez bases baja de 0,18; lo comprueba `test_bot_brain_rally`), y lo suma a donde va: ±1 m de lado en la
  marcha, ±1,6 m a lo largo de la puerta al golpearla (mirándola de frente), hasta 2 m alrededor del centro del círculo y hasta 4 m
  alrededor del punto de reunión. Un intento de dar también a cada uno su carril del vano al cruzar la puerta salió peor (con la reunión
  de 8, semillas 1000 y 2000: 743 y 725 s frente a 145 y 143) y se quitó.
- **Contadores de aliados**: el servidor (`ZoneServer._count_allies`, con la lista de jugadores vivos por reino reunida una vez por tick,
  así que todos los que esperan en un tick ven el mismo recuento; personas y falsos, sin PNJ ni los cuerpos de GUE-41), `SwarmBot`
  (`--bots`: sigue a los jugadores de su reino por sus altas y los mismos registros de los snapshots que ya decodificaba para los
  enemigos) y `BotAllySight` (`--bot`: los remotos de su reino que dibuja su `RemoteWorld`). Un `SwarmBot` no ve lo que queda fuera de
  su interés: si no ve a los del fuerte, espera al grupo o al reloj.
- **Herramientas**: `SiegeRunner.set_rally(tamaño, vuelta)` y `rally_departures` (cada salida de la reunión); `siege_battle.gd --rally=N`
  (0 o 1: sin reunión ni formación, para comparar), `--rally-period=S` y, en el informe, las salidas en grupo de cada reino. Arreglado
  de paso en el informe: la captura que acaba una fase podía caer justo en el tick en que empieza la siguiente y salía en ella («captura
  a los 0,0 s» de la recaptura, con la semilla 4000).
- **Pruebas**: `test_bot_brain_rally` (quince, sin física: el punto de reunión; el reloj común y la ruta del grupo; sin contador sale ya;
  solo, espera al reloj; cuatro que llegan de uno en uno salen en el tick del cuarto por la misma ruta; tres que llegan en momentos
  distintos salen juntos con el reloj; vuelve a esperar al reaparecer; ni el que aparece lejos del campamento ni el dueño esperan; no
  espera si los suyos ya pelean en el fuerte; deja de esperar si su reino gana el fuerte; el grupo a 1 no espera; pelea mientras espera;
  determinismo; los huecos; en grupo golpean la puerta y guardan el círculo cada uno en su sitio). `test_siege_zone`: una nueva con el
  servidor de verdad (dos de Solmarch esperan, un tercero llega y salen los tres en el mismo tick y por la misma ruta; un bot del dueño
  ni espera ni cuenta), y la de las dos rutas quita la reunión (`set_rally(0)`) porque mide las dos rutas y la reunión manda a todos
  por la misma. `test_siege_clients`: cada `SwarmBot` cuenta a los otros dos de su reino.
- **Consecuencias**: con la reunión, `test_siege_zone` y `test_server_main` (cuatro falsos, dos por reino) salen a los 5 s (la primera
  salida del reloj) en lugar de en el primer tick. En `load_test.gd --siege` los falsos salen a la vez (son más de 8 por reino), pero los
  `SwarmBot` que entran después pueden esperar en el campamento hasta 30 s si no ven a los del fuerte: al repetir la carga con PNJ
  (GUE-16) hay que mirar que lleguen antes de la ventana de medida.

**Medido en F6b (paquete C)** con `siege_battle.gd --npcs --per-side=20 --minutes=28` y cinco semillas (las tres del paquete B y dos más),
el capitán del reino en 7500; tiempos de juego desde que salen los de Solmarch, en segundos (4 núcleos compartidos con otras suites: cada
batalla tardó de 1 a 7 min de reloj, y las de antes hasta 12):

| Recaptura (s) | 1000 | 2000 | 3000 | 4000 | 5000 | Mediana |
|---|---|---|---|---|---|---|
| Antes (`--rally=0`: sin reunión ni formación) | 399,4 | 1654,8 | 1471,8 | 266,0 | 334,4 | 399 (6,7 min) |
| Solo la reunión (8 o el reloj de 30 s), sin huecos | | 772,5 | | | | |
| Solo la formación, sin reunión | 419,1 | 472,7 | 610,4 | 538,1 | 748,5 | 538 (9,0 min) |
| Reunión (8 o el reloj) y formación, sin «ir a ayudar» | 145,0 | 142,5 | 1521,5 | 157,2 | no en 28 min | |
| Reunión de 12 y formación | 156,1 | 161,8 | 637,4 | 795,2 | 926,8 | 637 |
| Reunión de 20 (casi solo el reloj) y formación | no en 28 min | no en 28 min | no en 28 min | | | |
| Reunión solo al empezar (los refuerzos no esperan) y formación | 337,7 | 144,1 | 274,4 | 772,0 | 777,5 | 337 |
| **GUE-44 (reunión de 8, «ir a ayudar» con 3, reloj de 30 s, formación)** | **145,0** | **142,5** | **288,8** | **157,2** | **766,0** | **157 (2,6 min)** |
| Lo mismo con el capitán del reino en 15 000 | 153,8 | 162,1 | 691,4 | 897,8 | 1045,4 | 691 (11,5 min) |

- **Con GUE-44**: muertes de jugadores Solmarch / Vardheim 29 / 31, 29 / 33, 61 / 75, 37 / 38 y 194 / 93 (antes 117 / 33, 433 / 149,
  406 / 127, 59 / 56 y 93 / 45): de 2,7 a 1,3 muertes del atacante por cada una del defensor. Captura del neutral a los 84,7 / 89,0 /
  87,2 / 80,5 / 82,4 s, sin muertes de Vardheim (antes 86–88 s). La batalla de la semilla 4000 con el código final y `--battle-log` da lo
  mismo que la de la tabla (capturas a los 80,5 y 157,2 s del ciclo) y su resumen: 75 muertes de jugadores, 71 en la explanada y el
  patio, 4 en el vado, ninguna en el puente ni en la pasarela; la puerta se rompe 12,0 y 12,8 s después del primer golpe.
- **Dos regímenes**: o el primer grupo de 20 (que sale entero y por la misma ruta) gana la pelea de la puerta durante la consolidación de
  Vardheim, espera a que aparezca la guarnición y la mata enseguida (**2,4–2,6 min**: el suelo lo ponen los 120 s de consolidación), o la
  pierde y empieza un tira y afloja de oleadas (4,8 y 12,8 min). La batalla es caótica: un cambio pequeño (los carriles, el tamaño del
  grupo) cambia qué semillas caen en cada régimen, así que solo se comparan configuraciones con las cinco semillas.
- **Lo que no funciona**: esperar más. Con grupos de 12 o de 20 los refuerzos tardan más en volver que los del dueño (que reaparecen y
  vuelven sin esperar) y, entre oleada y oleada, el capitán se cura y la puerta se repara; con 20, ninguna de tres recaptura en 28 min. Por
  eso la regla de «ir a ayudar» y un grupo de 8. La reunión sin huecos tampoco basta (772,5 s con la semilla 2000), y los huecos sin
  reunión dan recapturas regulares pero lentas (7–12,5 min): el primer grupo sale partido entre las dos rutas.
- **El capitán del reino**: con GUE-44, en 15 000 los bots recapturan dentro del ciclo de 30 min las cinco veces (de 2,6 a 17,4 min); el
  ajuste provisional a 7500 del paquete B ya no hace falta para los bots, pero se deja hasta probarlo con personas (MUN-11, GUE-11).
- **Lo que no hace este paquete**: la defensa de la pasarela (GUE-45), la carga con PNJ (GUE-16) y la batalla de los `SwarmBot` por ENet
  con PNJ (la reunión de `--bots` y `--bot` se prueba con sus contadores, no en una batalla larga: el de `SwarmBot` en
  `test_siege_clients`; el de `--bot`, `BotAllySight`, no tenía prueba propia hasta la revisión de F6b, que añade `test_bot_ally_sight`
  y comprueba en `test_siege_clients` que el `--bot` lleva su contador, sus avisos y su buscador de defensores). Los defensores no se
  reúnen: el dueño vuelve a su fuerte en cuanto reaparece.

**F6b, paquete D: GUE-45, los bots dueños defienden la pasarela** (pruebas nuevas en `test_bot_brain_walkway`; ampliaciones de
`test_approach_routes`, `test_navmesh`, `test_siege_zone` y `test_battle_summary`)

- **Lo que se pedía y lo que se puede.** El encargo era que una parte del dueño subiese a la pasarela y golpease desde allí a los de la
  puerta. **Con armas cuerpo a cuerpo no se puede**: el sector del arma va de 0,2 a 2 m sobre los pies de quien golpea y la cápsula del
  blanco, de 0 a 1,8 m sobre los suyos, así que nadie alcanza a quien está más de 1,6 m por debajo o 2 m por encima; la pasarela está
  3,35 m por encima del patio y de la explanada, y quien golpea la puerta está 2,3 m por fuera de ella y el eje de la pasarela 1,2 m por
  dentro (unos 3,5 m en horizontal, con el parapeto en medio). Ni los de arriba alcanzan a los de abajo ni al revés. **Lo que hacen**:
  los del dueño con el papel de la pasarela suben y la guardan encima de la puerta, sin hacer caso a los de abajo, y pelean con quien
  sube; una parte de los atacantes la recorre al entrar en el fuerte (si no, nadie subiría y la telemetría no vería nunca una muerte
  allí). Desde la pasarela solo se podrá atacar a la puerta con armas a distancia (el arco, CMB-23), que no hay. (El arco
  llegó con la fase 4: desde la revisión de la integración de las habilidades, abajo, el guardia con arco tira desde la
  pasarela a quien tiene a tiro; lo que queda, en GUE-47.)
- **La subida, una ruta precalculada** (no `NpcNavigation` en cada consulta): el cerebro es compartido y lo usan los falsos del
  servidor, `SwarmBot` (`--bots`) y `--bot`, y la malla de navegación solo existe en el servidor. `ApproachRoutes` gana
  `walkway_height` (13,55 m: la meseta de 10,2 m más 3,35), `walkway_path` (el eje de la pasarela, de la cima de la rampa norte a la de
  la sur pasando por las dos esquinas de la cara oeste y encima de la puerta) y `walkway_ramps` (cada rampa como ruta desde el patio:
  un punto entre la puerta y la torre, el de delante de su pie y su cima, en el eje); los escribe `export_vado_gris_routes.gd`. Es
  determinista y la malla de los PNJ (MUN-06) la da por buena: `test_navmesh` comprueba que cada tramo, del círculo al puesto por cada
  rampa, tiene ruta en la malla y que esta no es más larga que el tramo recto por 1,2 más 1,5 m; `verify_vado_gris_routes.gd` la
  recorre ahora con el personaje de verdad desde los datos (93,0 m en 18,9 s desde la explanada, iguales por las dos rampas; acaba a
  3,36 m sobre la meseta).
- **Hallazgo: la subida no puede cruzar el círculo.** La primera ruta usaba los puntos del interior que ya recorría la verificación,
  (-6, ∓6) y (7, ∓5): el tramo desde la puerta pasaba a 4,7 m del centro del círculo, y los del dueño que volvían a subir tras
  reaparecer disputaban la captura al pasar y peleaban allí. Con ella la recaptura de 20 contra 20 pasó de una mediana de 2,6 a 7,1
  min (cinco de cinco semillas en el régimen lento). Ahora el primer punto es (-12, ∓9), a 9,6 m del centro (`test_approach_routes`
  comprueba que ningún tramo de las rampas pasa a menos del radio más 1 m).
- **El papel** (`BotBrain`, patrón SIEGE; determinista, sin generador). Lo da la semilla con la sucesión de Weyl del número áureo
  (`is_walkway_seed`), que reparte casi igual semillas seguidas o una de cada N: **una cuarta parte guarda la pasarela cuando su reino
  es el dueño** (`SIEGE_WALKWAY_SHARE`: de 4 a 6 de cada 20 semillas seguidas, 5 en más de la mitad de las bases; la base 2000 da 6) y
  **la mitad de esos la recorre cuando ataca** (`SIEGE_WALKWAY_SWEEP_SHARE`, 0,125: de 1 a 4 de cada 20, casi siempre 2 o 3). `set_walkway_role(guardar, recorrer)` y `set_walkway_share(parte)` lo cambian (con 0, como antes de GUE-45); sin datos
  de la pasarela en las rutas no hace nada.
  - *El dueño* (tarea nueva `WALKWAY`, al final del enum): si está fuera entra por su puerta como siempre; en el patio va al punto más
    cercano de la rampa de su lado y sube; en la pasarela va por su eje (en cada esquina, primero la esquina) hasta su puesto, encima de
    la puerta más su hueco a lo largo de ella (±4 m), y allí se queda mirando afuera. Si una pelea le aparta más de 0,5 m del eje, vuelve
    a él antes de seguir; si se cae o le empujan fuera de la rampa, vuelve al pie y sube otra vez.
  - *El atacante que la recorre*: una vez por vida, al entrar en el fuerte (con la puerta abierta para él) sube igual hasta ese puesto,
    peleando con quien encuentre, y luego salta al patio (3,35 m: sin daño, el daño por caída empieza a 15 m/s y son 12) y va al círculo.
  - *Niveles*: dentro del recinto (el patio es llano), quien está más de 1,6 m más arriba o más abajo no es un blanco ni un golpe avisado
    del que salir (`_siege_same_level`); fuera (las laderas) no cambia nada. Sin esto, un bot del patio que persiguiese a alguien de la
    pasarela podía quedarse debajo golpeando al aire (la persecución sin progreso solo se deja a más de 3 m), y los de la pasarela
    tirarse al patio detrás de los de abajo. En la pasarela no esquiva de lado
    (le tiraría al patio): la esquiva es hacia atrás, por el eje, con el mismo uso del generador.
  - *Más cercano con la altura pesada*: los buscadores de enemigos de los bots (el servidor, `SwarmBot` y `BotEnemySight`) eligen con
    `BotBrain.target_distance_squared`, la distancia horizontal más la vertical por 4: la pasarela queda a más de 13 m, más lejos que el
    alcance de pelea (12 m), así que el enemigo a tiro de su nivel va antes. Sin esto, el de la pasarela tapaba al del patio para quien
    estaba debajo, y al revés. Con los bots sin papel (`--walkway=0`) las semillas 1000, 2000 y 4000 dan la misma recaptura que en el
    paquete C (145,0, 142,5 y 157,2 s); la 3000 y la 5000 cambian (489,7 y 1243,3 s frente a 288,8 y 766,0): la batalla es caótica.
- **Telemetría**: `BattleSummary` ya tenía la clase `walkway` (alta y a menos de 30 m del círculo); ahora, si las rutas conocen la
  pasarela, también su eje entero (las esquinas del fondo quedan a más de 30 m), y cuenta las muertes de PNJ por sitio
  (`npcs_by_route`, «PNJ: pasarela N» en el texto). `SiegeRunner` apunta la posición de las muertes de PNJ, da `place_of(posición)` y
  `set_walkway_share`; `siege_battle.gd` gana `--walkway=F` y escribe dónde caen los jugadores y los PNJ, y de qué reino son los de la
  pasarela.
- **Pruebas**: `test_bot_brain_walkway` (catorce, sin física: un punto con alturas sencillas, el patio, las rampas y la pasarela sin
  barandilla por dentro): el reparto del papel; el puesto; el dueño sube por la rampa de su lado sin caerse ni salirse del eje (13,5 s
  desde el círculo) y guarda su puesto mirando afuera; desde fuera entra por el vano y sube; los que no tienen el papel siguen en el
  círculo; en la pasarela no hace caso a los de abajo y pelea con el que sube; dobla una esquina peleando y nunca esquiva de lado;
  el atacante la recorre una vez y salta al círculo, y otra vez tras reaparecer; sin papel o fuera no sube; desde el suelo el de la
  pasarela no es un blanco (y en la ladera de fuera sí); un golpe avisado de otro nivel no se esquiva; empujado fuera de la rampa
  vuelve a subir; la altura pesada; determinismo. `test_approach_routes` (los datos de la pasarela y sus cálculos), `test_navmesh` (la
  ruta en la malla de los PNJ), `test_battle_summary` (las clases y los PNJ por sitio) y `test_siege_zone`, con la física de la zona:
  de cuatro del dueño desde su campamento, dos en el círculo y **dos suben a su puesto de la pasarela** (a 13,55 m, a los 40,7 s de
  juego) y una muerte en la pasarela entre un guardia y uno de Solmarch que entra por la puerta rota y sube (2,2 s de reloj por fase).
  Las pruebas del cerebro sin altura (`test_bot_brain_siege`, `test_bot_brain_rally`) quitan el papel.
- **Medido** con `siege_battle.gd --npcs --per-side=20 --minutes=28` y las cinco semillas de GUE-44 (tiempos de juego desde que salen los
  de Solmarch; 4 núcleos compartidos con otras suites, de 1 a 7,5 min de reloj por batalla). La subida por fuera del círculo en todas
  salvo la segunda fila:

| Recaptura (s) y muertes en la pasarela | 1000 | 2000 | 3000 | 4000 | 5000 | Mediana |
|---|---|---|---|---|---|---|
| Sin nadie en la pasarela (`--walkway=0`) | 145,0 · 0 | 142,5 · 0 | 489,7 · 0 | 157,2 · 0 | 1243,3 · 0 | 157,2 (2,6 min) |
| Subida cruzando el círculo; recorren un 25 % de los atacantes | 428,5 · 6 | 465,3 · 0 | 275,7 · 11 | 305,7 · 12 | 510,4 · 4 | 428,5 (7,1 min) |
| Recorren un 25 % de los atacantes | 317,9 · 6 | 148,2 · 3 | 143,0 · 4 | 1139,1 · 11 | 325,9 · 9 | 317,9 (5,3 min) |
| Recorren solo con el círculo activo | 144,2 · 0 | 144,8 · 0 | 165,2 · 1 | 147,6 · 0 | 524,4 · 0 | 147,6 (2,5 min) |
| Recorren con el círculo activo o 6 de los suyos cerca de él | 468,4 · 6 | 148,2 · 3 | 143,0 · 4 | 415,0 · 4 | 259,6 · 1 | 259,6 (4,3 min) |
| **GUE-45: recorren un 12,5 % de los atacantes** | **263,6 · 2** | **146,3 · 6** | **264,8 · 3** | **159,5 · 4** | **160,2 · 1** | **160,2 (2,7 min)** |

- **Con GUE-45**: **muertes en la pasarela en las cinco batallas** (16 de jugadores: 11 de Solmarch, casi todos los que la recorren y
  topan con los guardias de Vardheim, cinco o seis según la semilla, y 5 de Vardheim, todos en la semilla 2000, donde ganan los que suben); ningún PNJ muere en
  ella. Recaptura de 2,4 a 4,4 min (mediana 2,7, la misma que sin pasarela, 2,6) y sin las colas largas de 8,2 y 20,7 min; muertes de
  jugadores Solmarch / Vardheim 51 / 44, 22 / 27, 65 / 43, 16 / 32 y 33 / 27. Captura del neutral a los 80–87 s, como antes. Las
  cinco batallas repetidas con el código final y `--battle-log` dan exactamente lo mismo (es determinista) y el resumen del registro
  (`summarize_battle.gd`) cuenta las mismas muertes en la pasarela.
- **Decisión**: recorre la pasarela la mitad de los que la guardan. Que la recorra el mismo 25 % saca del patio a unos cinco atacantes
  que suben de uno en uno contra los cinco o seis guardias y mueren allí (la recaptura se dobla); que solo lo hagan con el círculo activo apenas
  deja muertes en la pasarela (la captura acaba 15 s después) y no se cumpliría el criterio de GUE-45. Con armas cuerpo a cuerpo la
  pasarela no defiende nada (los guardias ni alcanzan la puerta ni cuentan en el círculo), así que para la defensa es una plaza de
  menos; se queda así, preparada para cuando haya arcos, y se revisa con personas. (Ya los hay: ver «Revisión de la
  integración de las habilidades», abajo, y GUE-47.)
- **Lo que no hace este paquete**: golpear desde la pasarela a los de la puerta (no se alcanza; necesita el arco), que los guardias bajen
  a disputar el círculo, la batalla de los `SwarmBot` por ENet con la pasarela (el mismo cerebro y los mismos datos, probado sin red y
  con los falsos del servidor) y la carga con PNJ (GUE-16).

**F6b, paquete E: la carga y la telemetría con los PNJ (GUE-16, GUE-17) y el cierre de F6b** (ampliaciones de `test_load_test` y
`test_siege_clients`)

- **`load_test.gd --npcs`** (con `--scenario=siege` o con la batería `--siege`): el servidor arranca con sus PNJ y el fuerte va solo,
  sin `fort_kill_captain`. Sin la opción es el asedio de F6a, que ahora pasa `--no-npcs` de forma explícita: desde que se fusionó F4 la
  herramienta arrancaba con los PNJ y además mataba al capitán por orden al empezar la ventana, una mezcla que no medía ni el asedio de
  F6a ni el de con PNJ. Lo decide `siege_server_args()`. El resumen gana las secciones `npc_brains` (los cerebros de los PNJ) y `npc` (los generadores), las dos
  y `war` con su media de toda la sesión (los percentiles del informe son de los últimos 34 s, y los PNJ del fuerte pueden haber muerto
  antes), lo que dice el informe de los PNJ (vivos al acabar, aparecidos, muertos, avisos) y cuántos bots reales habían llegado al
  fuerte antes de la ventana.
- **Servidor**: la línea de métricas de cada 10 s acaba en «N PNJ», los que se simulan en ese momento (los de guerra y los maniquíes).
  `LoadTestSummary.parse_tick_timeline` lo lee (-1 en las líneas de antes) y `timeline_window` da el mínimo y el máximo de la ventana.
- **Clientes**: `SwarmBot` apunta en su informe `fort_reached_tick`, el tick del servidor en que llega por primera vez a menos de 25 m
  del círculo (`BotBrain.SIEGE_RALLY_FORT_RADIUS`), y `LoadTestSummary.fort_arrivals` cuenta los que llegaron antes de la ventana. Lo
  pedía el paquete C: los `SwarmBot` que entran cuando los falsos ya han salido podían quedarse hasta 30 s esperando en el campamento.
  **Llegan todos antes de la ventana**: el último, a los 25–26,5 s de partida con 32 contra 32 (ticks 1499 a 1590) y a los 54 s con 64
  contra 64 (tick 3263; la ventana empieza en el 3530). Salen en cuanto ven a 3 de los suyos en el fuerte, o con el reloj.
- **Pruebas**: `test_load_test` (dos nuevas y una ampliada: las opciones del servidor con y sin `--npcs` y las secciones del resumen;
  la llegada de los bots reales; la línea de métricas con los PNJ y su mínimo y su máximo en la ventana) y `test_siege_clients` (el
  informe del `SwarmBot` dice -1 en el campamento y, al llegar, el tick).

**Medido en F6b (paquete E): la carga con PNJ** con `load_test.gd --scenario=siege --fakes=54 --bots=10 --seconds=120 [--npcs]` (32
contra 32). Dos pasadas de cada, alternadas, en la misma máquina de 4 núcleos **sin ninguna otra suite en marcha** (carga media de 0,5 a
1,1, solo estas medidas); F6a midió con otra suite a la vez, así que sus cifras no se comparan al detalle con estas. Tick en ms del
último tramo de 34 s del servidor; «ventana», la mediana de las marcas de 10 s de la ventana de medida (cada una, sobre los 34 s
anteriores); secciones de los PNJ y de las fortalezas en ms, con la media de la sesión entre paréntesis:

| Asedio | Tick p50 / p95 / p99 / máx | Ventana p50 / p99 | `sim` p50 | `npc_brains` p50 / p99 (media) | `npc` p50 / p99 (media) | `war` p50 / p99 | Bajada por cliente | Sustituidas (ventana) |
|---|---|---|---|---|---|---|---|---|
| **32 contra 32 con PNJ**, 1.ª | 10,6 / 14,8 / 17,4 / 27,5 | 10,5 / 17,4 | 7,0 | 0,22 / 0,41 (0,29) | 0,06 / 0,12 (0,07) | 0,08 / 1,1 | 36,2 KB/s | 0,03 % (18 de 66 000) |
| **32 contra 32 con PNJ**, 2.ª | 9,4 / 13,5 / 15,2 / 23,0 | 10,8 / 17,9 | 6,1 | 0,20 / 0,37 (0,31) | 0,06 / 0,13 (0,08) | 0,08 / 1,1 | 36,3 KB/s | 0,00 % |
| 32 contra 32 sin PNJ (F6a), 1.ª | 9,1 / 12,8 / 15,0 / 27,9 | 9,7 / 15,8 | 6,2 | 0,05 / 0,10 (0,05) | 0 | 0,08 / 1,0 | 36,2 KB/s | 0,00 % |
| 32 contra 32 sin PNJ (F6a), 2.ª | 9,9 / 14,2 / 16,9 / 24,9 | 10,7 / 17,8 | 6,7 | 0,05 / 0,12 (0,06) | 0 | 0,09 / 1,1 | 36,2 KB/s | 0,00 % |
| 64 contra 64 con PNJ, 1.ª: **no es de 128** (ver la revisión) | 16,2 / 22,8 / 27,0 / 39,6, de **118** jugadores sin ningún cliente | 19,6 / 33,5 (las 8 marcas con los 128; las 12, 19,6 / 33,7) | 13,5 (de 118) | 0,27 / 0,56 (0,38), de 118 | 0,07 / 0,15 (0,09), de 118 | 0,09 / 2,1, de 118 | 29,0 KB/s | **38,6 %**; 83 rebobinados rechazados (10 sospechosos) |
| 64 contra 64 con PNJ, 2.ª (revisión de F6b; con otra suite en marcha, carga de 0,7 a 1,8) | 17,2 / 24,2 / 30,0 / 72,3 (el 90 % del tramo con los 128) | 17,8 / 31,0 (12 marcas, todas con 128) | 12,3 | 0,23 / 0,46 (0,32) | 0,06 / 0,11 (0,07) | 0,08 / 1,9 | 32,1 KB/s | 0,00 % (3 de 66 000); 44 rebobinados rechazados (8 sospechosos) |

- **Qué pasa en la ventana** (de los 59 a los 177 s de partida). Con PNJ, los dos reinos atacan a la vez el fuerte neutral: la puerta
  cae a los 48,7 y 51,4 s, los cuatro Huecos entre los 58 y los 75 s, y el Capitán del Vado a los 106,0 y 143,9 s; captura Vardheim a
  los 121,9 s en la primera pasada y Solmarch a los 164,1 s en la segunda. Hay 11 PNJ (los 9 de guerra, que son los 4 Huecos, el
  Capitán del Vado y los 4 Guardianes de los campamentos, y los 2 maniquíes) hasta que caen los Huecos (58–75 s: la ventana empieza a
  los 59), 7 (el Capitán, los Guardianes y los maniquíes) hasta la caída del capitán y 6 después; los Huecos no vuelven mientras haya
  jugadores a menos de 40 m del fuerte, así que **casi toda la ventana tiene 7** (las marcas de los 80 s a la caída del capitán) o 6. La
  guarnición del dueño no llega a salir (sale al acabar la consolidación, 120 s después de la captura). 136 y 159 muertes de jugadores, 5 de PNJ y 7 y 9 avisos TELEGRAPH. Sin PNJ
  (con `fort_kill_captain` al empezar la ventana), captura a los 74–79 s.
- **Los PNJ cuestan alrededor de 1 ms del tick con los 9 de guerra vivos (los 5 del fuerte y los 4 Guardianes de los campamentos),
  del orden de la diferencia entre dos pasadas iguales.** Sus cerebros (`npc_brains`): 0,2 ms de mediana con 6 PNJ; en las marcas que
  abarcan la pelea con los Huecos (hasta los 80 s, casi todas antes de la ventana) el p99 de cada marca es de 0,8 a 1,1 ms, con 7 PNJ de
  0,5 a 0,9 ms y con 6 de 0,4 a 0,6 ms; de media en la sesión, 0,29–0,31 ms frente a 0,05–0,06 sin PNJ (los maniquíes). Los generadores
  (`npc`): 0,06 ms de mediana. Su `simulate()` va dentro de `sim`, a unos 62 µs por personaje (media de jugadores y PNJ): ~0,55 ms los 9
  de guerra. En total, ~1 ms con los 9 y ~0,5 ms cuando solo quedan los Guardianes. Entre dos pasadas iguales hay tanto o más: el p50 del último tramo da
  9,1 y 9,9 ms sin PNJ y 10,6 y 9,4 con ellos, y las medianas de la ventana se solapan (9,7–10,7 frente a 10,5–10,8). **Con estos
  números no se distingue el asedio con PNJ del de sin ellos.** La sección `war` cuesta lo mismo con y sin PNJ (0,08 ms de mediana,
  1,0–1,1 ms de p99, la presencia recontada cada 6 ticks con todos en el círculo).
- **Criterios** (red.md 14 y 16) con 64 jugadores y los PNJ: **p99 < 8 ms, no** (15,2–17,4 ms; domina `simulate()`, como en F6a);
  **≤ 37 KB/s por cliente, sí** (36,2–36,3); **< 1 % de sustituidas, sí** (0,00–0,03 %), y ningún rebobinado rechazado. Con 128 (64
  contra 64), no: con los 128 presentes el p99 del tick es de 29 a 35 ms y el servidor no llega al tiempo real (un 81 y un 87 % en las dos
  pasadas), así que los clientes van por delante y las entradas les llegan antes de tiempo; en la primera pasada se sustituyó el 38,6 %
  de sus entradas y en la segunda casi ninguna, y en las dos el rebobinado falla a los honrados (83 y 44 rechazos). **El primer límite
  de jugadores por batalla en el fuerte sigue en 64 (32 contra 32), también con los PNJ** (sin el kit de la fase 4; con él, 40: ver
«Integración de las habilidades sobre F6b», abajo). (La primera fila de 64 contra 64 se publicó
  como de 128 jugadores; la revisión de F6b vio que no lo era: ver abajo.)
- Frente a F6a sin PNJ (10,6 / 15,3 / 19,1 / 27,8 ms, con otra suite en marcha), las dos pasadas sin PNJ de ahora dan 9,1–9,9 /
  12,8–14,2 / 15,0–16,9 ms con la máquina tranquila: la diferencia es de la carga de la máquina, no del código.

**Medido en F6b (paquete E): la batalla con telemetría** (GUE-17) con `siege_battle.gd --npcs --per-side=20 --minutes=28 --seed=N
--battle-log=<ruta>` y las cinco semillas de GUE-44 y GUE-45, y el resumen de cada registro con `summarize_battle.gd` (también por
separado, con `--out` para el JSON). Tiempos de juego (no dependen de la máquina; cada batalla, de 72 a 122 s de reloj con tres a la
vez); los de la recaptura, desde que salen los de Solmarch, que es cuando Vardheim captura y empieza su consolidación de 120 s:

| Semilla | Neutral: primer golpe / puerta rota / Capitán del Vado / captura | Recaptura: primer golpe / puerta rota (desde el primer golpe) / capitán del reino / captura | Muertes de jugadores: total (explanada y patio, vado, pasarela) | Muertes de PNJ |
|---|---|---|---|---|
| 1000 | 25,9 / 36,5 / 72,2 / 87,2 s | 24,9 / 37,7 (12,8) / 234,7 / 263,6 s | 95 (82, 11, 2) | 8 |
| 2000 | 25,8 / 37,3 / 71,2 / 86,2 s | 24,6 / 106,1 (81,5) / 130,3 / 146,3 s | 49 (43, 0, 6) | 10 |
| 3000 | 25,7 / 37,3 / 67,6 / 82,9 s | 24,7 / 39,6 (14,9) / 150,9 / 264,8 s | 108 (99, 6, 3) | 10 |
| 4000 | 25,9 / 37,9 / 65,2 / 80,2 s | 24,8 / 36,3 (11,6) / 141,0 / 159,5 s | 48 (44, 0, 4) | 10 |
| 5000 | 26,1 / 37,2 / 65,9 / 80,9 s | 25,0 / 47,0 (22,1) / 143,2 / 160,2 s | 60 (59, 0, 1) | 10 |

- **Es exactamente lo del paquete D** (es determinista): recaptura en 263,6 / 146,3 / 264,8 / 159,5 / 160,2 s (de 2,4 a 4,4 min,
  mediana 2,7) y 2 / 6 / 3 / 4 / 1 muertes en la pasarela. Ninguna muerte en el puente (los grupos de la reunión van todos por él); de
  las 360 de jugadores, 327 en la explanada y el patio, 17 en el vado y 16 en la pasarela. De los 48 PNJ muertos, 47 en la explanada y
  el patio; el otro es el capitán del reino de la semilla 1000, que cae fuera del recinto, junto al camino del puente y a 25,6 m del
  círculo (su correa, `leash_radius`, es de 36 m).
- **Captura del neutral**: los 20 de Vardheim llegan juntos por el puente (de 25,6 a 27,1 s), rompen la puerta en 10,7–12,0 s, el
  Capitán del Vado cae 28–36 s después y la captura dura 15,0–15,3 s (cuatro o más en el círculo). Sin muertes de Vardheim salvo dos
  con la semilla 2000.
- **Recaptura**: los 20 de Solmarch golpean la puerta por primera vez a los 24,6–25,0 s, en plena consolidación de Vardheim, y la rompen
  en 11,6–22,1 s en cuatro de cinco (81,5 s con la 2000, en la que los defensores la aguantan). El círculo no se activa hasta que sale
  la guarnición (120 s) y cae su capitán, de 10 a 115 s después (a los 130–235 s); la captura en sí dura 15,0–18,5 s, y antes puede
  haber disputa (con la 3000 pasan 114 s desde la caída del capitán).
- **Decisión: los datos de `vado_gris.tres` no cambian.** Ninguna cifra queda claramente fuera con estos números:
  - `gate_health` 9000: sigue dando lo que pide GUE-10 (3 atacantes, unos 60 s; 54,8 s en F3). Con 20 cae en 11–12 s en el neutral y en
    12–22 s en la recaptura, pero en ninguna fase es lo que más tarda: en el neutral, el Capitán del Vado tarda 28–36 s más; en la
    recaptura la puerta cae durante la consolidación y los atacantes esperan igual a la guarnición. Para que contara en la recaptura con
    20 tendría que aguantar los ~95 s que van del primer golpe al final de la consolidación, unas ocho veces la vida de ahora, y 3
    atacantes tardarían más de 7 min: rompería GUE-10.
  - `consolidation_s` 120: es el suelo de la recaptura (ninguna antes de 146 s desde que salen) y hace lo que pide la decisión de §0
    (no hay recaptura inmediata). Los bots no dan motivo para moverla: no hay un tiempo objetivo de tenencia, y cuánto aguanta un dueño
    lo dirán las personas.
  - `captain_respawn_s` 300 y `guard_respawn_s` 180: de la caída del capitán del reino a la captura van de 16 a 114 s, nunca 300 (no
    reaparece); mueren de 2 a 4 guardias por batalla y su reaparición no pesa en ninguna captura.
  - `capture_s` 30: 15,0–18,5 s capturando (15 s con cuatro o más, como quiere 1.3).
  - `under_attack_s`, `gate_repair_after_s` y `reset_to_neutral_s` no intervienen (la puerta se repara al capturar y ninguna batalla
    llega al ciclo de 30 min).
  - Siguen provisionales (§0), como el capitán del reino en 7500 (paquete B), hasta probarlos con personas (MUN-10, MUN-11, GUE-11 y
    «Pendiente de probar mañana con ventana» del informe).
- **Para las pruebas con personas**: la puerta no protege la consolidación (en cuatro de cinco recapturas cae 12–22 s después del primer
  golpe, antes de que salga la guarnición). Si se quiere que la proteja, la palanca no es su vida (rompería GUE-10) sino una regla, por
  ejemplo que no se pueda dañar mientras se consolida: eso es código y otro elemento, no GUE-17.

**Revisión de F6b** (revisión adversarial del diff de F6b, con refutación; cada arreglo lleva una prueba que falla sin él):

- **Un atacante dentro del fuerte ya no «asalta» la puerta cerrada.** Si la puerta se reparaba con atacantes dentro (pasados
  `gate_repair_after_s` sin golpes, o al capturar, con los guardias de la pasarela del dueño anterior aún arriba), `_siege_input`
  elegía `ASSAULT` también desde dentro, y con la formación de GUE-44 el bot iba al hueco de fuera de la puerta y golpeaba mirando al
  patio (con 1 bot, la mitad de ritmo que sin formación; el guardia de la pasarela, golpeando el aire). Dejar el círculo ya pasaba en F6a.
  Ahora, dentro del recinto o en la pasarela, sigue con la pasarela y el círculo: la captura no necesita la puerta.
  `test_bot_brain_siege` (puerta reparada con el atacante en el círculo, con y sin formación) y `test_bot_brain_walkway` (el guardia
  de la pasarela cuyo reino pierde el fuerte baja al círculo).
- **La persecución mide persecuciones seguidas del mismo blanco.** La referencia (`_siege_chase_ref_*`) no se renovaba mientras peleaba
  a 3 m o menos ni al cambiar de blanco, y una salida a más de 3 m (una esquiva hacia atrás) a los 180 ticks del principio bloqueaba la
  persecución 600 ticks: en un duelo de dos bots, un 10 % del tiempo sin perseguir a un enemigo a 3–12 m. Ahora llegar a la distancia de
  pelea la reinicia, y también un blanco nuevo (del defensor al enemigo o al revés, o un salto de más de 5 m). `test_bot_brain_siege`
  (la esquiva de 4,5 m en el tick 150; el PNJ que huye y muere con un jugador a 9 m) y la de siempre, que deja la persecución sin
  progreso, sigue igual.
- **GUE-43: el relleno aparta la plaza y el falso se va cuando la persona entra en el mundo** (regla en la sección 7, *Plazas*). Con la
  retirada al llegar el HELLO, un HELLO seguido de una desconexión, en bucle y sin límite, retiraba al falso más antiguo (DESPAWN a
  todos; en algunos recuentos, del bando contrario) y creaba otro en su campamento (SPAWN a todos), unas 7 vueltas por segundo; y la
  reposición, sin contar a quien cargaba, dejaba los bandos en 3 contra 1. `FillerKeeper.reserve_seat`, `release_seat` y
  `reserved_count`; `ZoneServer` cuenta las plazas apartadas como ocupadas (`_occupied_seats`, también en `add_fake_player`).
  `test_realm_balance` (el bucle y los dos HELLO), `test_zone_server_net` (el bucle con ENet, cinco vueltas sin altas ni bajas para
  quien ya estaba, y los dos HELLO, uno por reino al final) y `test_server_main`.
- **Los bots del cliente solo esquivan los golpes de quien les puede dañar**, como los falsos del servidor (8.3, F6b, paquete B,
  *Clientes*). `test_bot_threat_sight` (la regla, `is_hostile_view` y un `SwarmBot` con el aviso de un guardia de su reino) y
  `test_siege_clients` (el `--bot` con un aviso de cada reino).
- **Pruebas del cableado de `--bot`**: `test_bot_ally_sight` (el contador de aliados de `--bot`: su reino, vivos, dibujados, en el radio,
  sin PNJ) y `test_siege_clients`, que comprueba que el `--bot` y los `SwarmBot` llevan sus avisos y su buscador de defensores.
- **La carga de 64 contra 64 se midió con 118 jugadores.** `load_test.gd` cerraba el enjambre por sus ticks locales (tiempo real),
  pero el servidor de 128 va más despacio: los 10 bots reales se iban en el tick 8390 de 10 850, y los percentiles del informe (los
  últimos 2048 ticks) eran de 118 jugadores sin ningún cliente (sin construir snapshots). Ahora el enjambre se cierra cuando el
  servidor llega a su tick de salida (`--quit-at-server-tick`, con `--quit-after-ticks` como cota) y el resumen dice cuántos jugadores
  había en ese tramo y en las marcas de la ventana, y avisa si no son los del pico (`LoadTestSummary.presence`). Repetida (tabla de
  arriba, 2.ª): 17,2 / 24,2 / 30,0 / 72,3 ms con el 90 % del tramo con los 128. Las de 32 contra 32 apenas cambian (los bots se iban en
  los últimos ~600 ticks). La de F6a de 64 contra 64 tenía el mismo defecto (8.3, F6a).
- **Documentación**: el relato de los PNJ de la carga (11 → 7 → 6, no 11 → 6) y «los 9 PNJ de guerra» en lugar de «del fuerte»; las
  cifras de `test_siege_npcs`; lo que garantiza el reparto por semillas (`slot_for_seed`, `is_walkway_seed`; las pruebas lo comprueban
  ahora en miles de bases); y que las medidas de 20 por bando son con falsos del servidor (sección 7, GUE-46).
- **Medido otra vez con el código final** (`siege_battle.gd --npcs --per-side=20 --minutes=28 --battle-log`, las cinco semillas; de dos
  en dos, con otra suite en marcha: de 65 a 153 s de reloj por batalla). Cambian por los dos arreglos del cerebro: sobre todo la
  persecución, que interviene en cada pelea; la puerta reparada con atacantes dentro solo puede hacerlo con la semilla 2000, la única en
  la que la puerta se repara durante la recaptura:

| Semilla | Neutral: Capitán del Vado / captura | Recaptura: puerta rota / capitán del reino / captura | Muertes de jugadores (en la pasarela) | Muertes de PNJ |
|---|---|---|---|---|
| 1000 | 61,7 / 76,7 s | 37,4 / 141,6 / **202,4 s** | 65 (2) | 10 |
| 2000 | 67,5 / 82,5 s | 37,7 / 312,1 / **399,8 s** (la puerta cae 2 veces) | 136 (3) | 12 |
| 3000 | 60,2 / 75,2 s | 39,5 / 135,6 / **151,4 s** | 56 (1) | 10 |
| 4000 | 63,7 / 78,7 s | 36,6 / 133,8 / **152,2 s** | 54 (2) | 10 |
| 5000 | 61,8 / 76,8 s | 37,4 / 129,2 / **144,3 s** | 39 (2) | 10 |

  Recaptura de 2,4 a 6,7 min, **mediana 152,2 s (2,5 min; antes 160,2)**; captura del neutral a los 75–83 s (antes 80–87), con el
  Capitán del Vado de 1,5 a 10,5 s antes (seguramente porque ya no dejan de perseguirle cuando se aparta un momento). Las muertes en la pasarela siguen en
  las cinco batallas (10, todas de Solmarch). La semilla 2000 pasa al régimen lento (antes 146,3 s) y las otras cuatro mejoran: la batalla
  sigue siendo caótica (riesgo de §9). `vado_gris.tres` sigue sin cambiar: ninguna recaptura antes de 144 s, y la consolidación (120 s)
  sigue siendo el suelo.

**Lo que queda tras F6b** (F6b está hecho):

- GUE-15: que una persona juegue contra los bots (el cliente de verdad contra `--bots` con los PNJ).
- MUN-10 y MUN-11: sus criterios con personas (los Huecos en 60–90 s con 2–3; el Capitán en 60–120 s con 3–5), y con ellos el capitán
  del reino en 7500 y los datos de `vado_gris.tres`, que siguen provisionales.
- El p99 < 8 ms con 64 jugadores (GUE-16 lo deja medido y no cumplido): es `simulate()`, palanca 6 de red.md 14 (TEC-35).
- Una batalla larga solo con `SwarmBot` por ENet, con los PNJ y la pasarela: el mismo cerebro y los mismos datos se prueban sin red y
  con los falsos del servidor, y en la carga los 10 bots reales pelean con los PNJ, pero no hay batalla entera solo con ellos (backlog
  GUE-46; no bloquea GUE-15, cuyo criterio se lee con los falsos del servidor desde F6a).
- La pasarela con armas a distancia (CMB-23) y que los guardias bajen a disputar el círculo. El arco ya tira desde la
  pasarela (revisión de la integración de las habilidades, abajo); medir su papel en una batalla queda en GUE-47.
- La recaptura sigue dependiendo de la semilla (riesgo de §9): cualquier ajuste se mide con cinco semillas o más.

**Integración de las habilidades sobre F6b** (la fase 4 de habilidades, H1a–H5, fusionada sobre F6b;
[habilidades.md 11.9](habilidades.md#119-h5--integración)). Las dos ramas salieron de la misma base y se tocaban en el cerebro de los
bots, el servidor de zona y la carga. Cómo quedan juntas:

- **Los bots de asedio pelean con el kit** en el paso 1 de su plan, como pedía H5 (habilidades por su papel, cambio de arma,
  pociones, arco con el tiro adelantado y remate de derribados), sin perder nada de F6b: golpes avisados, defensores primero,
  persecuciones, reunión, formación, pasarela y recinto. No levantan a nadie (siguen su plan) y la puerta se golpea como en la fase 3.
  Los falsos de asedio del servidor reciben a la vez los sentidos de F6b (`_find_threats`, el buscador de defensores,
  `_count_allies`) y los del kit (estado de combate, vida, `BotTarget` y aliados derribados); los `--bot` del cliente, los de
  `ClientBotBrains._make_siege` más `give_kit_senses`.
- **El blanco del kit es el de la pelea**: el PNJ defensor o el enemigo. El buscador de defensores devuelve también un `BotTarget`
  (`ZoneServer._find_enemy_target` con `npcs_only`, `BotEnemySight.find_target` con `war_npcs_only`) y el arco apunta al defensor con
  su velocidad; antes de la fusión el kit habría apuntado al enemigo de `set_enemy_finder` aunque peleara con el defensor.
- **El arquero no persigue**: con el arco en la mano todo `SIEGE_FIGHT_RANGE` (12 m) es distancia de tiro (guarda de 9 a 26 m), así
  que la regla de dejar una persecución que no le acerca no se le aplica; con la espada, igual que antes. (La revisión de la
  integración, abajo, lo completa: sin línea de tiro no tira, el arco llega a 20 m y rematar sí lleva la regla.)
- **La pasarela con el kit**: el arquero no se mueve en ella (ni de lado ni para guardar la distancia) y no esquiva, y nadie usa en
  ella las habilidades que avanzan en línea recta (la embestida, que avanza 6 m y empuja, y el salto atrás). Peleando en la pasarela
  el bot mira por su eje hacia el blanco (también sin el kit), así que acercarse, el paso de los golpes y la esquiva hacia atrás van
  por el eje (la revisión de la integración, abajo, lo cambia: mirando por el eje, el de al lado quedaba fuera del sector de la
  espada; ahora mira al blanco y lo que mueve va por el eje). Lo destapó `test_siege_zone` (la pelea en la pasarela): con el kit, la
  embestida del guardia los sacaba a los dos al patio y, sin ella, en las peleas largas (el muro, las pociones) una esquiva «hacia
  atrás» con el otro casi al lado, en perpendicular al eje, tiraba al atacante; la muerte salía en el patio. La regla de F6b («sin
  esquivar de lado») suponía que el blanco estaba delante, por el eje.
- **Un derribado no cuenta como aliado** en la reunión ni peleando en el fuerte (`_rebuild_ally_cache` usa `is_alive`). Aquí se
  dijo que era lo que ya veía el cliente, «para el que su vida dibujada es 0»: no lo era (un derribado publica su vida de derribado,
  que nunca es 0), y los `--bot` y `--bots` sí los contaban. La revisión de la integración lo iguala en el cliente (abajo).
- **La puerta cerrada corta los golpes en los dos sentidos**: las dos ramas habían hecho el mismo arreglo
  (`HitShapes.is_ray_clear` con `hit_from_inside`); queda uno, con la explicación de las dos.
- **El orden del tick** de la cabecera de `ZoneServer` lleva los pasos de las dos (§1.7 y habilidades.md 4.1): los falsos piensan
  justo antes de su simulación con su estado tras `s − 1`, y los TELEGRAPH salen al final del paso de combate, no en el de los PNJ.
- **Aforo**: el kit bajó el límite medido por batalla a 40 (en la refriega con la mitad de tiradores, red.md 14) y el servidor del
  Vado Gris tiene ese aforo por defecto (`Zones.MAX_PLAYERS`). Los asedios de F6b se midieron sin el kit, con 32 contra 32 y 64
  contra 64. Para el fuerte con el kit, 40 (20 contra 20) era **una estimación**, por la misma cuenta que la refriega y sin medir:
  la medida que se proponía aquí (`load_test.gd --siege --npcs`) no llevaba arqueros (los falsos de asedio salen con la plantilla
  por defecto y los `SwarmBot` no tienen kit). Medido en la revisión de la integración, con y sin la mitad de tiradores (abajo).
  Las herramientas y las pruebas de F6b que llevan más de 40 jugadores piden su aforo explícito: `load_test.gd` lanza el
  servidor con `--max-players` (`server_max_players`, los jugadores más 8; `test_load_test` comprueba que cabe cada escenario de las
  baterías) y `SiegeRunner` (`siege_battle.gd` y las pruebas de asedio) pone `ServerConfig.max_players`. Nota en
  [red.md 14](red.md#14-presupuesto-de-ancho-de-banda-y-cpu).
- **Pruebas**: `test_bot_brain_siege_kit` (nueva, 7: el kit contra el defensor, el arco que apunta al defensor por delante de él, el
  arquero que no deja de disparar y la espada que sí deja la persecución, la pasarela sin pasos de lado del arquero, mirando por el
  eje y sin embestidas, sin levantar a nadie, determinista; cada arreglo, comprobado deshaciéndolo) y `test_load_test` (+1, el aforo).
  Pasan las de asedio de F6b (`test_bot_brain_siege`, `test_bot_brain_rally`, `test_bot_brain_walkway`, `test_siege_zone`,
  `test_siege_npcs`, `test_siege_clients`) y las del kit (`test_bot_brain_kit` y las de habilidades, proyectiles y derribado).

**Revisión de la integración de las habilidades** (revisión adversarial de la integración, con sondas en el Vado Gris de verdad; cada
arreglo lleva una prueba que falla sin él):

- **El arco solo tira si la flecha llega.** Los tiradores de asedio (la plantilla `marksman`; `siege_battle.gd` y las pruebas de asedio
  van con la del escudero y no lo veían) tiraban a la madera: `_can_reach` es la regla del cuerpo a cuerpo (el mismo nivel y, con la
  puerta cerrada *para su reino*, el mismo lado) y, con el arco en la mano, nada le hacía dejar un blanco que no se alcanzaba. El
  dueño veía alcanzables a los de fuera de su puerta cerrada (no le cierra el paso a él), pero el cuerpo de vista de la puerta para las
  flechas en los dos sentidos y su flecha no daña su propia puerta (sonda: 70 de 70 flechas a ella en 30 s, mientras cuatro escuderos
  la bajaban a 3373 de 9000); con
  la puerta rota, un atacante tiraba a los de detrás de la empalizada (52 de 80 flechas al mundo; dos de cuatro sin entrar en 30 s).
  Ahora el arco pelea con quien tiene **a tiro**: lo que sabe del fuerte (la puerta entera corta el tiro entre dentro y fuera del
  recinto a todos los reinos, también al dueño; rota, solo se tira de un lado a otro por el vano, `SIEGE_BOW_GAP_HALF_WIDTH`; desde la
  pasarela o hacia ella decide la línea) y la **línea de tiro** de quien lo lleva (`BotBrain.set_line_of_sight`: el servidor y
  `--bot`, con `BotBrain.bow_sight_clear` en su mundo). La línea son dos rayos al centro del blanco: el de la cámara del hombro, que
  es el que elige el punto apuntado (`AimRay.aim_point`), y el de la boca. Con solo el de la boca, desde el vano y de lado, la mira
  del hombro daba en la jamba y la flecha iba a la jamba (5 de 21 al mundo; con los dos, 0 de 13). Se pregunta una vez por búsqueda
  del blanco (cada 4 ticks). Sin tiro no pelea con el arco: sigue su plan (o, muy cerca, saca la espada). Ir a rematar a un
  derribado es acercarse y lleva la regla de las persecuciones de F6b: antes, con el arco en la mano, se quedaba empujando la
  empalizada hasta que el derribado se desangraba. La regla que proponía la revisión de contar disparos sin HIT no hace falta con la
  línea de tiro (y el cerebro no se entera de los HIT): queda anotada en el riesgo de §9.
- **Distancias de arco.** Con los 12 m de la pelea cuerpo a cuerpo (`SIEGE_FIGHT_RANGE`) el cambio al arco, que pide más de 11 m,
  casi nunca llegaba, el arquero guardaba de 9 a 12 m y el que sacaba la espada no volvía al arco. Ahora el arco tira hasta
  `SIEGE_BOW_FIGHT_RANGE` (20 m) y, con la espada en la mano y el arco a la espalda, lo saca para quien está a tiro y lejos (más de
  11 m) o para quien la espada no alcanza (otro nivel, la empalizada en medio), sin acercarse mientras lo saca. **El filtro de nivel
  de GUE-45 es solo del cuerpo a cuerpo**: el guardia de la pasarela con arco tira al patio (y fuera, si la línea pasa por encima del
  parapeto: lo decide el rayo) y el del patio, a la pasarela. **La puerta se golpea con la espada**: a flechazos, cuatro tiradores
  le quitaban 1880 en 30 s (138 flechas, todas a ella) y cuatro escuderos, 4986; ahora el tirador saca la espada al empezar el
  asalto y los cuatro le quitan 5415, sin flechas. El arquero puro de las pruebas de carga (`kit_ranged_only`) no la saca.
- **En la pasarela mira al blanco y mueve por el eje.** La integración hacía mirar por el eje a cualquier bot que peleaba en ella,
  también sin el kit, y el sector de la espada (100°) no llegaba a quien estaba pegado de través (a 0,9 o 1,2 m de lado y casi nada a
  lo largo: lo miraba a 1,35–1,57 rad): una persona al lado de un guardia de la pasarela era intocable para él. En F6b le miraba y le
  daba. Ahora mira al blanco y lo que mueve (acercarse y la esquiva hacia atrás) va por el eje: el movimiento se pasa al marco de su
  mirada (`_siege_move_along`), porque la simulación mueve y esquiva relativo al yaw de la cámara. La embestida y el salto atrás
  siguen sin usarse en la pasarela; `test_bot_brain_walkway` cuenta las esquivas de lado por adónde van en el mundo.
- **Un derribado no cuenta en la reunión, tampoco en el cliente.** `Combatant.publish` da a un derribado su vida de derribado, que
  nunca es 0, y `BotAllySight` (`--bot`) y `SwarmBot` (`--bots`) solo miraban la vida: contaban a los derribados para el grupo de la
  reunión y para «los 3 de los suyos peleando en el fuerte», y salían del campamento a ayudarlos; los falsos del servidor no (lo que
  se dijo en la integración, que el cliente ya los veía con vida 0, era falso). Ahora miran también la acción dibujada, DOWNED
  (`SwarmBot.is_standing_record`: el byte 19 del registro).
- **GUE-43: el relleno que cede su sitio no muere.** `FillerKeeper._retire_oldest_of` quitaba al más antiguo del reino sin mirar su
  estado, y si estaba derribado `_remove_player` lo mataba desangrado con un KILL para quien lo derribó: que una persona entrase en la
  partida sumaba una muerte a su bando y una baja al otro, en el marcador y en el registro de batalla, y podía cortar un levantar o un
  rematar. Ahora se va el más antiguo tranquilo (`calm_check`: ni derribado ni levantando o rematando; si no hay, el más antiguo) y
  su baja es solo el DESPAWN (`ZoneServer.retire_filler`; regla en la sección 7, *Relleno*). Las demás bajas de un derribado (salir,
  desconectarse, `--fake-churn`) siguen siendo una muerte.
- **Aforo y sesiones a mano.** Con el aforo de 40 del Vado Gris, la guía de `informe_noche.md` «Con bots de asedio contra tu
  cliente» (40 falsos, 20 bots y dos personas) ya no cabía: los 20 del enjambre y las personas recibían FULL. Lleva
  `--max-players=64`. **Cualquier sesión a mano en el Vado Gris con más de 40 jugadores (falsos, bots y personas) necesita
  `--max-players`.**
- **El 40 del fuerte era una estimación** escrita como dato (red.md 14 decía «estimación» y la integración, «el límite en el fuerte
  es 40»), y la medida que se proponía no llevaba arqueros. Medido (abajo), con la plantilla por defecto y con la mitad de tiradores.
- **Pruebas**: `test_bot_brain_siege_kit` (nueve nuevas y una reescrita: mira al enemigo y mueve por el eje, la espada alcanza al
  de al lado, ni a través de la puerta cerrada ni de la propia, por el vano, la línea de tiro y una pregunta por búsqueda, el arco
  a 20 m, sacar el arco con la espada en la mano, tirar a otro nivel, la persecución al ir a rematar y la espada para la puerta),
  `test_siege_archers` (nueva, tres con la física del Vado Gris: las sondas de la revisión), `test_bot_brain_walkway` (las esquivas
  de lado, en el mundo), `test_bot_ally_sight` y `test_bot_swarm` (+1 cada una, el aliado derribado), `test_realm_balance` (+1, a
  quién se retira) y `test_downed` (+1, el relleno derribado se va sin DEATH ni KILL). Cada una falla con el código de antes.

**Medido otra vez con la integración y su revisión** (los bots de asedio con el kit; tiempos de juego, deterministas):
`siege_battle.gd --npcs --per-side=20 --minutes=28 --seed=N --battle-log`, tres semillas, con la plantilla por defecto (el escudero,
como todas las de F6b; de 81 a 144 s de reloj, las tres a la vez):

| Semilla | Neutral: puerta rota / Capitán del Vado / captura | Recaptura: puerta rota / capitán del reino / captura | Muertes de jugadores (en la pasarela) | Muertes de PNJ |
|---|---|---|---|---|
| 1000 | 36,5 / 67,4 / 82,4 s | 39,4 / 134,4 / **156,1 s** | 56 (0) | 10 |
| 2000 | 37,3 / 65,7 / 80,7 s | 40,7 / 131,7 / **146,9 s** | 33 (3) | 10 |
| 3000 | 37,3 / 65,0 / 80,0 s | 44,6 / 204,7 / **295,6 s** | 91 (3) | 9 |

- Captura del neutral a los 80,0–82,4 s (con el código final de F6b, 75,2–82,5 s con estas semillas) y recaptura en 156,1 / 146,9 /
  295,6 s (antes 202,4 / 399,8 / 151,4): de 2,4 a 4,9 min, dentro del ciclo y con la consolidación (120 s) como suelo. Las dos más
  lentas de antes van más deprisa y la 3000 más despacio (91 s de la caída del capitán a la captura, con el círculo disputado): la
  batalla sigue siendo caótica (§9) y tres semillas no dicen si el kit la acelera. Muertes en la pasarela en dos de tres (6, todas de
  Solmarch). `vado_gris.tres` no cambia.

**La carga de 20 contra 20 con el kit y los PNJ** (GUE-16, medida que la integración dejó pendiente): `load_test.gd --scenario=siege
--fakes=30 --bots=10 --seconds=120 --npcs`, 40 jugadores (el aforo del Vado Gris), con la plantilla por defecto y otra vez con la
mitad de tiradores (`--fake-loadout=marksman:50`; los `SwarmBot` no tienen kit, así que las flechas son de 15 de los 30 falsos). La
misma máquina de 4 núcleos, sin otra suite en marcha (carga media de 0,5 a 0,9); de referencia, en la misma sesión la refriega de 40
(`--scenario=brawl --fakes=30 --bots=10 --seconds=60`) da 7,4 / 11,3 / 13,2 / 22,7 ms, como en la revisión de H5 (12,4 de p99).
Tick en ms del último tramo de 34 s; «ventana», las marcas de 10 s de la ventana de medida; secciones en ms, p50 (p99):

| Asedio de 20 contra 20 con PNJ | Tick p50 / p95 / p99 / máx | Ventana p50 / p99 (la peor) | `sim` | `combat` | `combat_projectiles` | `npc_brains` | Bajada por cliente | Sustituidas (ventana) | Flechas |
|---|---|---|---|---|---|---|---|---|---|
| Plantilla por defecto (el escudero) | 8,2 / 12,8 / **16,2** / 32,6 | 8,9 / 17,1 (19,1) | 4,9 (9,9) | 0,91 (3,0) | 0 | 0,20 (0,47) | 34,4 KB/s | 0,00 % | ninguna |
| La mitad de tiradores | 9,6 / 14,3 / **16,9** / 38,7 | 9,6 / 17,2 (21,0) | 5,8 (10,5) | 1,04 (3,2) | 0,26 (**1,01**) | 0,40 (0,94) | 36,1 KB/s | 0,00 % | 328: 229 a personajes, 92 al mundo, 3 bloqueadas; pico de 11 |

- **El 20 contra 20 en el fuerte está en el filo del criterio de la fase 4** (p99 del tick ≤ 16,7 ms y de `combat_projectiles` ≤ 1 ms,
  habilidades.md §7.3): con la plantilla por defecto lo cumple por poco (16,2 ms), y con la mitad de tiradores se pasa por poco (16,9 y
  1,01 ms); las marcas de la ventana dan 17,1–17,2 ms de p99 en las dos. Es más caro que la refriega de 40 en campo abierto (13,2 ms en
  la misma sesión): `simulate()` sube de 4,3 a 4,9–5,8 ms de mediana (por las laderas y la explanada del fuerte, ~70–74 µs por
  personaje) y los PNJ suman sus cerebros (0,2–0,4 ms). Ninguna entrada sustituida en la ventana y ningún rebobinado rechazado; bajada de
  34–36 KB/s por cliente. **El límite por batalla en el fuerte con el kit queda en 40 (20 contra 20), medido y sin margen**: no se baja
  el aforo por 0,2 ms de una pasada (la diferencia entre dos pasadas iguales es de ~1 ms, paquete E), y la palanca para tener margen es
  la de siempre, `simulate()` (TEC-35, palanca 6 de red.md 14).
- **Qué pasa en la ventana** (los dos reinos contra el fuerte neutral). Con el escudero, la puerta cae 16,9 s después del primer golpe,
  cae el Capitán del Vado y empieza una captura que no acaba; 79 muertes de jugadores y 5 de PNJ. Con la mitad de tiradores la puerta no
  llega a caer: los dos bandos pelean entre sí en la explanada (el arco tira hasta 20 m) y ningún PNJ muere; 96 muertes de jugadores.
  Una sonda con `SiegeRunner` (15 falsos por reino, la mitad tiradores, PNJ, sin `SwarmBot`) rompe la puerta a los 69 s (97 s con el
  cerebro de la integración antes de la revisión; 55 s sin tiradores) pero tampoco captura en 4 min: la batalla con tiradores está
  sin medir (GUE-47). Las flechas al mundo de una pelea así son fallos: en esa sonda, de 308, la mayoría en el suelo y en las laderas
  y unas 60 en la cara de fuera de la empalizada y en la puerta, delante de las cuales se pelea; con la línea de tiro ninguno tira a
  quien está detrás de ellas (en las sondas de la empalizada y de la puerta, 0 al mundo).

**Revisión de la fase 4 (lente «guerra»)** (revisión adversarial de la fase 4, con refutación; cada arreglo lleva una prueba que falla
sin él):

- **La reaparición automática sale en oleada, y los bots piden la suya.** `_process_respawns` hacía la automática a los
  `death_tick + auto_respawn` (1800) justos, sin mirar `respawn_wave_ticks`: con oleadas, quien no pedía la reaparición salía fuera de
  ellas (muerte en el tick 101: reaparición en el 1901). Y nadie más que el botón del HUD y el `SwarmBot` la pedía: los falsos del
  servidor (`--fake-players`, `SiegeRunner` y `siege_battle.gd`, `load_test`, el relleno de GUE-42) y el `--bot` reaparecían siempre
  por la automática, a los 30 s, cada uno por su lado. **Todas las medidas de 20 por bando de F6a, F6b y la integración se hicieron
  así**, no con las oleadas de GUE-14 que tiene una persona que pulsa el botón (10–20 s). Ahora:
  - `CombatTiming.auto_respawn_tick_for(muerte)`: el primer múltiplo de la oleada ≥ muerte + 30 s (sin oleadas, muerte + 30 s), que
    `Combatant.mark_dead` guarda en `auto_respawn_tick` junto a `respawn_tick`; `_process_respawns` usa ese tick. Con oleadas nadie
    reaparece fuera de una, como dice el contrato de `respawn_wave_ticks`.
  - Los falsos del servidor piden la reaparición al morir: `Combatant.requests_respawn_on_death` (lo pone `add_fake_player`) deja
    `pending_respawn_point = 0` en `mark_dead`, así que reaparecen en `respawn_tick` (su oleada) y en el mismo sitio que la automática (el
    punto 0 o, si no vale para su reino, el primer campamento válido). Fuera de las zonas con fortaleza, a los 10 s en lugar de 30, como
    un `SwarmBot`.
  - El `--bot` (`OnlineMain`, también sin `--quit-after-ticks`) manda RESPAWN_REQUEST (punto 0) en cuanto el tick estimado del servidor
    llega al `respawn_tick` del bloque extra, y lo repite cada segundo (`BOT_RESPAWN_RETRY_TICKS`) mientras siga muerto.
  - Pruebas: `test_fortress_server` (quien no la pide reaparece solo en una oleada; un falso reaparece en su primera oleada),
    `test_combatant` (las cuentas de las dos oleadas y la petición al morir) y `test_online_main` (el `--bot` muerto reaparece al pedirlo,
    sin avisos del servidor). `test_combat_server` y `test_loadout_server`, que miden la automática o piden a mano, apagan la petición
    del falso.
- **Solo se aplaza la reparación de la puerta rota.** `_repair_if_due` aplazaba la reparación de los 5 min si alguien solapaba el vano
  y, desde entonces, reparaba en cuanto quedaba libre **sin volver a mirar el plazo**; `on_structure_hit` no anulaba el aplazamiento.
  El dueño cruza su propia puerta cerrada y dentro de la caja no le golpean: bastaba un defensor quieto en el vano cuando vencía el
  plazo para que los atacantes bajaran la puerta casi a 0 y, al salir él, volviera entera al tick siguiente (o se cerrara una puerta
  recién rota sin esperar sus 5 min). `_hold_repair_if_blocked` hacía lo mismo tras una captura o un reinicio con la puerta entera.
  Aplazar solo tiene sentido si reparar cambia la colisión, es decir, con la puerta rota (que ya no recibe daño, así que lo pendiente no
  se queda viejo): ahora la entera se repara en el acto, y un golpe que quita vida anula lo pendiente. `test_fortress_controller`
  (tres: plazo vencido con alguien en el vano y golpe nuevo; rotura después de que venciera el plazo; cambio de dueño con la puerta
  entera dañada y alguien en el vano).
- **Los refuerzos del Capitán del Vado, una vez por vida.** `_arrive_home` rearmaba la llamada cada vez que el Capitán volvía
  regenerado, y los refuerzos (`_extras`) solo se iban al morir o con `defenders_retired`: cada asalto fallido que le bajaba de la mitad
  sumaba dos Huecos más (2 → 4 → 6 → 8 en tres asaltos, y la reaparición completa los dejaba en 8), y como los refuerzos están en su
  grupo de alerta, contaban para el «solo si queda alguno». Ahora la llamada es una por vida del Capitán; la reaparición completa (los
  Huecos «vuelven enteros») retira los refuerzos que queden y le rearma la llamada (`HfsmBrain.rearm_reinforcements`); y
  `_spawn_reinforcements` no crea más de los que faltan para `reinforcement_count` vivos por fortaleza (los de un Capitán anterior
  cuentan). `test_npc_system` (dos: tres asaltos y la reaparición completa; un Capitán nuevo con los refuerzos del anterior vivos).

**Medido otra vez con los tres arreglos** (`siege_battle.gd --npcs --per-side=20 --minutes=28 --seed=N --battle-log`, las cinco semillas
de GUE-44; deterministas: el código de antes repite exactamente las cifras de la tabla de la integración con la semilla 1000; de dos en
dos, de 84 a 144 s de reloj por batalla). «Antes» es el código anterior a la revisión: las semillas 1000, 4000 y 5000 medidas otra vez
en esta revisión y la 2000 y la 3000, de la tabla de la integración. Recaptura, desde que salen los de Solmarch:

| Semilla | Antes: recaptura (muertes S / V) | Ahora: puerta rota / capitán del reino / **recaptura** | Ahora: muertes de jugadores S / V (pasarela) | Salidas en grupo de Solmarch |
|---|---|---|---|---|
| 1000 | 156,1 s (31 / 25) | 39,4 / 135,3 / **158,8 s** | 23 / 30 (2) | 3 (antes 4) |
| 2000 | 146,9 s (33 en total) | 40,7 / 126,8 / **162,8 s** | 15 / 42 (3) | 6 |
| 3000 | 295,6 s (91 en total) | 44,6 / 134,2 / **161,8 s** | 14 / 44 (3) | 6 |
| 4000 | 303,7 s (72 / 35) | 41,3 / 138,5 / **156,6 s** | 27 / 25 (1) | 4 (antes 14) |
| 5000 | 157,4 s (3 / 32) | 44,6 / 134,0 / **286,9 s** | 47 / 72 (2) | 14 (antes 3) |

- **Recaptura de 2,6 a 4,8 min, mediana 161,8 s (2,7 min; antes 157,4 con las mismas cinco semillas)**, con cuatro de cinco en el
  régimen rápido (antes tres): el que gana el primer grupo, que espera a la guarnición durante la consolidación (120 s, el suelo). La
  captura del neutral no cambia (80,0–82,4 s, sin muertes de Vardheim: nadie reaparece en esa fase). Muertes de jugadores 53, 57, 58,
  52 y 119 (antes 56, 33, 91, 107 y 35). La batalla sigue siendo caótica (§9): con la reaparición de verdad dos semillas pasan de lento a
  rápido y una de rápido a lento.
- Las conclusiones de GUE-44 y del paquete B se tomaron con la reaparición de antes. Repetida la comparación que decidió GUE-44, sin
  reunión ni formación (`--rally=0`) y con la reaparición nueva: 413,4 / 220,5 / 234,5 / 142,6 / 213,0 s (**mediana 220,5 s**; 112,
  85, 92, 41 y 91 muertes de jugadores). La reunión sigue ganando en cuatro de cinco semillas (todas salvo la 4000), así que la decisión
  de GUE-44 se mantiene. Las demás variantes de la tabla del paquete C (grupos de 12 y de 20, la reunión solo al empezar) no se han
  repetido; ahora los que reaparecen en la misma oleada salen juntos de verdad, y el reloj de la reunión, 5 s después de una oleada,
  hace lo que decía.
- `vado_gris.tres` y el capitán del reino (7500) no cambian: ninguna recaptura antes de 156 s y todas dentro del ciclo de 30 min.
- **La carga de 20 contra 20 con el kit y los PNJ, otra vez** (también usa falsos del servidor, que ahora vuelven a la pelea en su
  oleada y no a los 30 s): `load_test.gd --scenario=siege --fakes=30 --bots=10 --seconds=120 --npcs`, plantilla por defecto, el código
  de antes y el de ahora seguidos en la misma sesión y sin otras suites en marcha (carga media de 0,6 a 0,9). Último tramo de 34 s,
  p50 / p95 / p99 / máx: **8,2 / 12,1 / 14,6 / 32,7 ms antes y 8,7 / 13,4 / 17,5 / 29,9 ms ahora**; marcas de la ventana, p50 y p99:
  8,6 y 17,6 ms (la peor, 19,0) antes y 8,9 y 16,5 ms (19,8) ahora; 89 y 68 muertes de jugadores, ninguna entrada sustituida en la
  ventana, 34–35 KB/s por cliente. Cada una pasa del criterio (16,7 ms) en una de sus dos medidas y no en la otra: con una pasada de
  cada código la diferencia queda dentro del ruido (1–3 ms entre pasadas iguales), y **el límite de 40 por batalla en el fuerte sigue en
  el filo y sin margen**, ahora con la reaparición de verdad. La refriega de 40 (`--scenario=brawl --fakes=30 --bots=10 --seconds=60`)
  casi no tiene muertes en su minuto (15, casi todas rematadas) y da lo mismo: 14,5 y 14,6 ms de p99 del tick y 1,28 y 1,01 ms de
  `combat_projectiles` (las dos, por encima del milisegundo en esta pasada; en la revisión de H5, 0,90).

**Revisión de la fase 4 (lente «trampas»)** (misma revisión; cada arreglo lleva una prueba que falla sin él):

- **Un PNJ al que disparan desde más allá de su radio de pérdida va a por el arquero.** En COMBATE, `_choose_target` solo
  miraba a menos de `_lose_radius` (28 m el Hueco, 30 el guardia, 34 los capitanes; la flecha llega a unos 90 m): con el
  arquero más lejos no había objetivo, el PNJ se quedaba quieto y a los 3 s (`LOST_TARGET_TICKS`) volvía a REPOSO en su
  puesto **curado del todo** (`_arrive_home`), y el siguiente flechazo lo devolvía a COMBATE. Medido antes del arreglo: un
  Hueco con 6 arqueros a 33 m recibía 173 flechazos en 20 s sin moverse ni un centímetro (6 curas completas, 0 de daño a los
  arqueros); con 10, moría en 3,6 s sin moverse; el guardia del reino y el Capitán, igual (el Capitán, con 30 000 de vida y una
  cura cada 3,2 s, no bajaba de 28 200). Dos resultados degenerados: por debajo de unos 830 de DPS a distancia no se le podía
  matar y por encima moría sin reaccionar. Ahora (`HfsmBrain._reach_for_attacker`) quien le ha golpeado en el último segundo
  (`_recent_attacker`) desde más allá del radio se lo sube a su distancia más 4 m (`ATTACKER_RADIUS_MARGIN`), como el aviso de
  un compañero, al entrar en combate y en cada pensamiento de COMBATE sin objetivo; lo persigue, y si no lo alcanza la correa o
  el atasco lo mandan al regreso inmune, como contra quien huye. `test_hfsm_brain` (dos: tres arqueros a 33 m, a los que llega
  y hace daño sin volver curado a su puesto; tres a 55 m, más allá de la correa, que lo hacen perseguirlos hasta ella y
  regresar inmune).
- **El registro de estados de cada PNJ, acotado.** `_state_log` sumaba una entrada por transición durante toda la vida del
  PNJ y solo lo leen las pruebas: los dos Huecos que patrullan el fuerte neutral suman unas 10,5 por minuto cada uno (del
  orden de 1 MB al día por zona mientras nadie los mate). Ahora guarda entre `STATE_LOG_MAX` (256) y el doble: al llegar al
  doble se queda con las 256 últimas de golpe (sin copiar en cada transición). `test_hfsm_brain` (2560 transiciones).
- Los refuerzos del Capitán que se acumulaban con cada asalto fallido (otro hallazgo de esta lente) ya los arregló la lente
  «guerra» (más arriba: una llamada por vida y nunca más de dos vivos por fortaleza).
- El rebobinado que rechazaba los golpes y las flechas de un honrado con un tirón o pocos FPS (el fallo intermitente del
  tramposo «rate») está en red.md §10.
- **Medido**: la batalla de asedio con PNJ (`siege_battle.gd --npcs --per-side=20 --minutes=28`) repite al décimo de segundo las
  cifras de la tabla de la lente «guerra» con las semillas 1000 (39,4 / 135,3 / **158,8 s**, 23 / 30 muertes, 2 en la pasarela,
  3 salidas en grupo) y 5000 (44,6 / 134,0 / **286,9 s**, 47 / 72, 2, 14 salidas): los bots de asedio pelean a menos del radio
  de pérdida de los PNJ y el arreglo no les cambia nada.

---

## 9. Riesgos

- **Coste de los PNJ**: 5–10 PNJ más con `simulate()` y su cerebro. Medido en F4: unos 50 a 85 µs por PNJ y tick (8.3); con 10 a 20
  PNJ son de 0,5 a 1,7 ms del tick de 16,7 ms. F6a midió el asedio sin PNJ (8.3); F6b repitió la medida con los de F4 (8.3, paquete E):
  con los 9 PNJ de guerra del Vado Gris vivos (los 5 del fuerte y los 4 Guardianes de los campamentos), ~1 ms del tick en un asedio de 32
  contra 32 (cerebros con un p99 de 0,8–1,1 ms mientras viven los Huecos, generadores 0,06 ms y su `simulate()` ~0,55 ms), del orden de
  la diferencia entre dos pasadas iguales. Un castillo con más PNJ (F7) se vuelve a medir.
- **Generador de la zona** (resuelto en F0): `vado_gris.tscn` sale de un script y los assets que
  necesita sí están en el repo, así que se regenera (no se edita a mano); ver 8.3.
- **Arte**: Huecos, Capitán, tabardos, estandartes y efectos de la puerta definitivos son del
  usuario (ART-15, ART-16, ART-17); de momento, provisionales.
- **Batallas de bots caóticas** (F6b, GUE-44): la recaptura de 20 contra 20 cambia mucho con la semilla (de 2,4 a 12,8 min con
  GUE-44) y con cambios pequeños del cerebro. Un ajuste del fuerte o de los bots se mide con cinco semillas o más, nunca con una. Los
  bots se apilan porque los personajes no chocan entre sí: cualquier cerebro nuevo que lleve a muchos al mismo punto debe repartirlos
  (la formación de 8.3, F6b, paquete C).
- **Alturas y pasarela** (F6b, GUE-45): dentro del recinto los bots solo distinguen dos niveles (el patio y la pasarela, a más de
  1,6 m uno del otro) y suben por una ruta de puntos de los datos, no por la malla en cada consulta. Un fuerte o castillo con otra
  geometría (F7) necesita sus datos de pasarela, y con más niveles, otra regla. Con armas cuerpo a cuerpo los guardias de la pasarela no
  defienden nada (ni alcanzan la puerta ni cuentan en el círculo). Con el arco de la fase 4 (CMB-23) el guardia tira desde ella a
  quien tiene a tiro, también a los de abajo (revisión de la integración de las habilidades, 8.3), pero las batallas de bots se
  miden con la plantilla del escudero: el papel de la pasarela con arcos, sin medir, queda en GUE-47 y se revisa con personas.
- **Línea de tiro de los bots** (revisión de la integración de las habilidades): el arco de los bots de asedio tira con los dos
  rayos rectos que deciden un disparo del servidor (la mira del hombro y la boca); la caída de la flecha no cuenta. Un parapeto o
  una rama a media altura del arco podrían pararla igual: la sonda de la puerta rota dio 0 flechas al mundo de 13, y si hiciera
  falta, la regla de rendirse sería contar disparos sin HIT.

---

## 10. Ampliación del combate (otro diseño corto)

CMB-19 (habilidades con reutilización), CMB-21 (habilidades de espada y escudo), CMB-20 (efectos
de estado), CMB-22/23 (proyectiles con rebobinado y arco), CMB-24 (cambio de arma), CMB-28
(derribado), UI-11 (barra de acciones) y UI-45 (iconos de estados). Se diseña en
`docs/habilidades.md` cuando el bucle del fuerte funcione, porque toca `CombatState`.
