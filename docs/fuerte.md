# Eldmark · Fase 4: diseño del fuerte capturable

Diseño del paso 4 de la [hoja de ruta](vision.md#hoja-de-ruta): el primer objetivo jugable, el
fuerte del Vado Gris disputado entre Vardheim y Solmarch ([mundo.md](mundo.md), [zona](zonas/vado_gris.md)).
Se apoya en la red ([red.md](red.md)) y el combate ([combate.md](combate.md)).

Esta fase tiene dos bloques:

1. **El bucle del fuerte** (este documento): estado de la fortaleza, captura, puerta, defensores
   PNJ con IA, avisos, reaparición en el fuerte, mapa y HUD de captura, y bots que asedian.
2. **La ampliación del combate** (§9): habilidades, arco y proyectiles, cambio de arma, efectos de
   estado y derribado. Tiene su propio diseño corto antes de implementarse.

---

## 0. Decisiones

De las recomendaciones de [backlog.md](backlog.md#decisiones-pendientes) (provisionales, tomadas de
noche):

| Pregunta | Decisión |
|---|---|
| Círculo vacío | El progreso decae a un tercio de la velocidad de captura tras 5 s vacío. |
| Recaptura inmediata | No: 2 min de consolidación (círculo inactivo, puerta dañable) hasta que llega la guarnición. |
| Arquitectura de IA | Máquina de estados jerárquica propia en GDScript, parámetros en `NpcDefinition`. |
| Modelo de los Huecos | Plan B: cuerpo base con traje sencillo, material de hueso y ojos emisivos (lo compone el usuario; de momento, el humanoide con un material gris). |
| Campamento | Zona segura (fase 3) y dos Guardianes de la Puerta PNJ. |
| Estructura de partida | En pruebas, el fuerte vuelve a neutral cada 30 min con un resumen. |
| Minimapa | Imagen cenital horneada por una herramienta desde el terreno; enemigos solo si se revelan. |
| Recurso de las habilidades | Solo reutilización (armas físicas). |
| Proyectiles | Rayo de cámara canónico desde yaw, pitch y un bit de hombro. |
| Derribado | Sí en PvP; muerte directa en PvE en solitario. |

---

## 1. La fortaleza

### 1.1 Definición (GUE-07)

`FortressDefinition` (`scripts/shared/war/fortress_definition.gd`, datos en
`data/fortresses/vado_gris.tres`):

| Campo | Valor del Vado Gris |
|---|---|
| `id` | `&"vado_gris_fort"` |
| `capture_s` | 30 (con un aliado) |
| `capture_speed_max` | ×2 (con 4 o más) |
| `decay_after_empty_s` / `decay_rate` | 5 s / un tercio de la velocidad base |
| `circle_radius_m` / `circle_height_m` | 5 / 4 (cilindro sobre `CaptureCircle`) |
| `gate_health` | 9000 |
| `consolidation_s` | 120 |
| `guard_respawn_s` | 180 |
| `under_attack_s` | 30 (ventana de «en combate» del fuerte) |
| `reset_to_neutral_s` | 1800 (solo en pruebas, 0 = nunca) |

### 1.2 Estado (puro, en ticks)

`FortressState` (`scripts/shared/war/fortress_state.gd`, RefCounted, sin nodos):

| Campo | Qué es |
|---|---|
| `owner` | código de reino (0 = neutral, los Huecos) |
| `phase` | `GARRISONED`, `VULNERABLE`, `CAPTURING`, `CONSOLIDATING` |
| `phase_tick` | tick en que empezó la fase |
| `captain_alive`, `guards_alive` | defensores |
| `gate_health`, `gate_max` | vida de la puerta (0 = rota) |
| `capture_realm` | reino que captura (0 = nadie) |
| `capture_start_tick`, `capture_rate`, `capture_progress_at_start` | la captura como fórmula: `progress(t) = clamp(p0 + rate · (t − t0), 0, 10000)`; `rate` en diezmilésimas por tick, con signo (negativo al decaer) |
| `contested` | hay un enemigo vivo dentro: la fórmula se congela (`rate = 0`) |
| `under_attack_until_tick` | último daño enemigo a la puerta o a los defensores + 30 s |

Transiciones:

```
GARRISONED ──(muere el capitán)──▶ VULNERABLE ──(entra un reino ≠ dueño)──▶ CAPTURING
CAPTURING ──(progreso 10000)──▶ CONSOLIDATING (dueño = capture_realm, puerta reparada)
CAPTURING ──(progreso 0 y nadie dentro)──▶ VULNERABLE
CONSOLIDATING ──(120 s)──▶ GARRISONED (aparece la guarnición del dueño)
```

- Al empezar la zona: `owner = 0`, `GARRISONED` con los Huecos y el Capitán del Vado.
- Velocidad: `rate = base · min(1 + (n − 1) / 3, 2)` con `n` atacantes vivos dentro (×2 con 4).
  Si hay a la vez dentro alguien del dueño o de otro reino atacante, `contested`.
- Círculo vacío: tras 5 s sin atacantes dentro, `rate = −base / 3` hasta 0.
- Si el fuerte es de un reino y entran **sus** jugadores con progreso de otro reino a medias, el
  progreso decae al doble de la velocidad base (defender limpia el círculo).
- Toda transición se calcula con funciones puras `FortressState.advance(def, tick, counts) ->
  Array[int]` (devuelve los eventos de guerra del tick). La prueba exige que la fórmula dé el
  mismo progreso que simular tick a tick.

### 1.3 Controlador en el servidor (GUE-08, GUE-12)

`FortressController` (`scripts/server/war/fortress_controller.gd`) crea al arrancar una
`NetEntity` de tipo `STRUCTURE` con `ALWAYS_RELEVANT` por cada fortaleza de la escena (nodo con el
grupo `fortresses` y el metadato `definition`), y corre en el paso de PNJ del tick (tras resolver
el combate, combate.md §4.2):

- Cada 6 ticks cuenta los jugadores **vivos y activos** de cada reino dentro del cilindro. No cuenta
  quien lleva 60 s sin enviar entradas reales (`InputQueue`: último tick real).
- Llama a `advance()`, aplica los efectos (dueño, estandartes, puerta, guarnición) y emite los
  OBJECT_STATE de los campos que cambian y los avisos de guerra.
- Al cambiar de dueño: estandartes de la escena (`Estandarte`, `EstandartePuerta`) al
  `faction_color` del reino en el servidor y, por OBJECT_STATE, en el cliente; puerta reparada;
  Huecos retirados; consolidación.
- Comandos (`CommandRegistry`, solo con `--debug-commands`): `fort_reset`, `fort_owner <reino>`,
  `fort_kill_captain`, `fort_capture_speed <×>`.

---

## 2. Replicación con estado: OBJECT_STATE (GUE-09)

Ocupa el tipo reservado `0x22` de red.md §5.6 y sube **`PROTOCOL_VERSION` a 3**:

`u8 type`, `u16 net_id`, `u32 tick`, `u8 field_count` y, por campo, `u8 field_id`, `u8 value_type`
(1 u8, 2 u16, 3 u32, 4 s32) y el valor. Canal fiable 3. Genérico: lo reutilizarán puertas, cofres,
nodos de recurso y clima.

- **ENTITY_SPAWN** de un `STRUCTURE`: payload `u8 def_len`, el id de la definición (ASCII) y un
  OBJECT_STATE completo embebido (todos los campos).
- El snapshot **no** lleva registros de `STRUCTURE`.
- Campos del fuerte (`FortressFields`, compartido): 1 owner, 2 phase, 3 phase_tick, 4
  captain_alive, 5 guards_alive, 6 gate_health, 7 gate_max, 8 capture_realm, 9
  capture_start_tick, 10 capture_rate, 11 capture_progress_at_start, 12 contested, 13
  under_attack_until_tick.
- **Cliente**: `FortressView` (`scripts/client/war/fortress_view.gd`) aplica cada OBJECT_STATE
  cuando su `render_tick` alcanza `tick` (como los eventos de los remotos), calcula el progreso
  con la fórmula en `render_tick` y emite señales para la interfaz (`owner_changed`,
  `phase_changed`, `progress_changed`, `gate_changed`).

---

## 3. La puerta (GUE-10)

- **Vida** en `FortressState` (9000). Golpes contra una **caja orientada** (`HitShapes.
  sector_hits_box`, matemática pura) en su posición actual, sin rebobinado: es estática.
- La dañan los enemigos del dueño (todos si es neutral). Multiplicadores por tipo de daño contra
  estructuras (`CombatRules`): cortante ×0,35, perforante ×0,2, contundente ×1,0, elemental ×0,6.
  Con el combo de espada (156 DPS × 0,35) tres atacantes la rompen en ~55 s.
- **Colisión por reino.** La puerta debe parar a los enemigos y dejar pasar al dueño. Se reservan
  las capas de física 5, 6 y 7 para Vardheim, Solmarch y Askarra: cada `PlayerCharacter` añade a su
  máscara la capa de su reino, y la puerta pone en su `collision_layer` las capas de todos los
  reinos salvo el dueño (las tres si es neutral). Es determinista en los dos lados: el cliente
  conoce el dueño por OBJECT_STATE y la predicción usa la misma regla.
- **Rota** (vida 0): hojas caídas (visual) y sin colisión para nadie. Se repara al cambiar de dueño
  o tras 5 min sin daño. Queda **cerrada por defecto** (corrige `docs/zonas/vado_gris.md`).
- Los cambios de colisión de la puerta se aplican en el servidor en el tick del cambio y en el
  cliente al recibir el OBJECT_STATE; si un cliente predijo contra la puerta vieja, la
  reconciliación lo absorbe.

---

## 4. PNJ (MUN-06 … MUN-12, GUE-11)

### 4.1 Navegación (MUN-06)

- `tools/bake_navmesh.gd` hornea una `NavigationMesh` desde la capa de juego (Terrain3D con
  `generate_nav_mesh_source_geometry`, colisiones estáticas, rampas, pasarela, puentes y vado;
  agua profunda excluida) con celda de 0,5 m y la guarda como `.tres` de texto junto a la zona.
- `NpcNavigation` (servidor) registra la malla en un mapa propio de `NavigationServer3D` y da
  rutas (`get_path(from, to) -> PackedVector3Array`). La puerta del fuerte es un
  `NavigationLink3D` que se activa según el dueño y la vida de la puerta.

### 4.2 IA (MUN-07, MUN-08)

- `NpcDefinition` (`data/npcs/*.tres`): vida, arma (un `WeaponDefinition` propio con
  anticipaciones largas), velocidades, radios de percepción y de alerta, cono, correa, puntos de
  patrulla, si es inmortal, nivel de amenaza.
- `NpcBrain` (`scripts/server/ai/npc_brain.gd`): máquina de estados jerárquica **REPOSO →
  PATRULLA → ALERTA → COMBATE → REGRESO**, que piensa cada 6 ticks y produce cada tick una
  `PlayerInput` sintética (movimiento hacia el siguiente punto de la ruta, mirada al objetivo,
  botones de ataque, bloqueo y esquiva). El cuerpo es un `PlayerCharacter` con la misma máquina de
  acciones que los jugadores (combate.md §7). Con RNG con semilla por PNJ: dos ejecuciones con las
  mismas entradas dan la misma secuencia de estados.
- **Percepción**: radio, cono y línea de visión (`HitShapes.has_line_of_sight`). **Amenaza**: daño
  recibido más proximidad. **Correa**: si se aleja más de `leash_m` de su puesto, REGRESO con
  vida regenerada e inmune mientras vuelve.
- **Ataques legibles**: anticipación ≥ 0,45 s en los ligeros y ≥ 0,70 s en los fuertes (absorben
  RTT y retardo de interpolación). **Fichas**: como mucho 2 PNJ atacan a la vez al mismo jugador;
  los demás lo rodean a 3–4 m.
- **Depuración** (`--debug-commands`): el comando `npc_debug` hace que el servidor envíe al que lo
  pide, por NOTICE informativo cada segundo, el estado, el objetivo y la ruta de los PNJ cercanos;
  el overlay F3 lo muestra.

### 4.3 Generadores y defensores (MUN-09 … MUN-12, GUE-11)

- `NpcSpawner` (nodo de la capa de juego, `scripts/world/npc_spawner.gd`, sin lógica: solo datos)
  y `NpcSpawnerSystem` (servidor): marcador, `NpcDefinition`, máximo vivos, reaparición en ticks,
  grupo de alerta y condición (`always`, `fort_neutral`, `fort_owner:<reino>`).
- **Huecos** (MUN-10): 4 en los `GuardSpawn` (2 en la explanada, 2 patrullando la pasarela),
  alerta en grupo a 25 m, correa a la meseta, reaparición completa si el fuerte sigue neutral sin
  jugadores a 40 m durante 2 min.
- **Capitán del Vado** (MUN-11): barrido amplio bloqueable, golpe imbloqueable con aviso en el
  suelo (`AttackDefinition.unblockable`, solo servidor, y evento `TELEGRAPH` con posición y
  radio), grito que alerta a los Huecos vivos y 2 Huecos de refuerzo al 50 % si quedan Huecos. Al
  morir, el controlador pasa a VULNERABLE. Solo con el fuerte neutral.
- **Guarnición del reino** (GUE-11): al acabar la consolidación, 4 guardias y un capitán del reino
  dueño (tabardo con `faction_color`) en los mismos marcadores; su capitán abre el círculo al
  morir, como el de los Huecos.
- **Guardianes de la Puerta** (MUN-12): dos por campamento, de daño alto y alcance largo, que solo
  atacan a enemigos dentro de la zona segura (un intruso muere en menos de 10 s).

---

## 5. Avisos, reaparición y salida (GUE-13, GUE-14, GUE-41, MUN-41)

- **Avisos de guerra**: ENTITY_EVENT `5 WAR` (`u8 war_event`, `u8 realm`, `u16 fortress`) a toda
  la zona, aplicado en el tick de dibujo: fuerte atacado (como mucho 1 cada 60 s por fortaleza),
  capitán caído, captura iniciada, captura disputada, puerta rota, fuerte capturado, fuerte
  reiniciado. Textos en español en `WarEvents` (compartido).
- **Reaparición** (amplía combate.md §5): puntos válidos = el campamento del reino (siempre) y los
  marcadores `respawn_points` con metadato `fortress` de las fortalezas propias que no estén
  `under_attack`. El cliente calcula la misma lista con el estado replicado. Oleadas: se reaparece
  en el primer múltiplo de 10 s (600 ticks) tras `respawn_tick`. El servidor valida el índice.
- **Salida en combate** (GUE-41): un CLIENT_LEAVE o una desconexión «en combate» dejan el cuerpo 15
  s quieto y atacable antes del DESPAWN; fuera de combate, inmediato.
- **/atascado** (MUN-41): comando de chat cuando exista el chat; mientras tanto, `DEBUG_COMMAND`
  7 `unstuck` sin `--debug-commands`: canalización de 10 s que el daño interrumpe, fuera de
  combate, 5 min de reutilización, teletransporte al punto de aparición más cercano del reino y
  registro de zona y posición.

---

## 6. Interfaz (UI-18 … UI-21, UI-41, UI-42)

- **HUD de captura** (UI-18): arriba al centro, el estado del fuerte (dueño con su color y
  emblema, fase, barra de progreso con el color del reino que captura, «disputado», vida de la
  puerta) cuando se está a menos de 80 m o se combate por él; banners de los avisos de guerra.
- **Brújula y marcadores** (UI-19): brújula arriba con el fuerte, los campamentos y los pasos;
  marcador en pantalla del fuerte con distancia.
- **Mapa** (UI-20, UI-21): `tools/bake_zone_map.gd` genera, sin GPU, una imagen cenital de la
  zona (sombreado del mapa de alturas de Terrain3D, agua, caminos y contornos de la escena) en
  `assets/maps/<zona>.png` con su metadato de escala; minimapa circular con iconos (fuerte con
  color del dueño, aliados de grupo cuando existan, jugador) y mapa a pantalla completa con la
  elección de reaparición.
- **Registro de bajas y marcador** (UI-41, Tab): de los KILL y de las cifras del servidor.
- **Pistas** (UI-42): una vez por jugador (`user://`), con los glifos reales.

---

## 7. Bots que asedian (GUE-15, GUE-16, GUE-42)

- `BotBrain` gana el patrón `SIEGE` con un objetivo por reino: ir al fuerte por el puente o por el
  vado, golpear la puerta, entrar en el círculo, defender la pasarela y atacar al enemigo más
  cercano. Para `--bots`, `--bot` y `--fake-players`.
- Criterio: `--bots=20` por bando capturan y recapturan sin intervención.
- **Carga** (GUE-16): escenario de `load_test` con 32 contra 32 y 64 contra 64 en la puerta y el
  círculo durante 120 s.
- **Equilibrio** (GUE-42): `--max-realm-diff=N` rechaza entrar en el reino que va N por delante
  (REJECT FULL con texto), y los jugadores falsos rellenan el bando corto.

---

## 8. Paquetes

| Paquete | Contenido | Depende de |
|---|---|---|
| **F1 · fortaleza pura** | `FortressDefinition`, `FortressState`, `FortressFields`, `WarEvents`, datos del Vado Gris, pruebas de todas las transiciones y de la fórmula | fase 3 |
| **F2 · protocolo v3** | OBJECT_STATE, SPAWN de STRUCTURE, ENTITY_EVENT WAR y TELEGRAPH, DEBUG 7 `unstuck` | F1 |
| **F3 · servidor del fuerte** | `FortressController`, conteo del círculo con inactividad, puerta con caja y multiplicadores, capas de colisión por reino, estandartes, consolidación, comandos | F1, F2 |
| **F4 · PNJ** | navmesh horneada, `NpcNavigation`, `NpcDefinition`, `NpcBrain`, fichas, `NpcSpawner`, Huecos, Capitán, guarnición, Guardianes | fase 3 (K3) |
| **F5 · cliente** | `FortressView`, HUD de captura, banners, brújula, mapa horneado y minimapa, mapa con reaparición, registro de bajas, pistas | F2 |
| **F6 · bots y carga** | `SIEGE`, `--max-realm-diff`, escenarios de carga, prueba de extremo a extremo neutral → Vardheim → Solmarch | F3, F4, F5 |

F1 y F4 pueden empezar a la vez; F2 tras F1; F3 y F5 en paralelo; F6 al final.

---

## 9. Ampliación del combate (otro diseño corto)

CMB-19 (habilidades con reutilización), CMB-21 (habilidades de espada y escudo), CMB-20 (efectos
de estado), CMB-22/23 (proyectiles con rebobinado y arco), CMB-24 (cambio de arma), CMB-28
(derribado), UI-11 (barra de acciones) y UI-45 (iconos de estados). Se diseña en
`docs/habilidades.md` cuando esté el bucle del fuerte, porque toca la máquina de acciones y el
estado predicho (`CombatState`).

---

## 10. Riesgos

- **Navegación en headless**: hay que comprobar que `NavigationServer3D` funciona sin ventana y
  que Terrain3D genera la geometría de origen sin cámara. Si no, la malla se hornea en el editor.
- **Coste de los PNJ**: 5–10 PNJ más con `simulate()` y su cerebro; se mide en F6.
- **Puerta con colisión por reino**: si la predicción contra la puerta da muchas correcciones al
  cambiar de dueño, se adelanta el cambio de capa al tick del OBJECT_STATE en el cliente.
- **Arte**: Huecos, Capitán, tabardos y estandartes definitivos son del usuario (ART-15, ART-16,
  ART-17); de momento, materiales y mallas provisionales.
