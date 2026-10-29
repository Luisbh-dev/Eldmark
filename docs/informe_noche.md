# Informe de la sesión nocturna

Sesión sin supervisión del 28 al 29 de octubre de 2026. Este archivo se actualiza en cada hito
y está siempre en la rama más reciente (ahora `fase4-fuerte`; las ramas van encadenadas:
`main` → `fase2-red` → `fase3-combate` → `fase4-fuerte`, y nada está fusionado en `main` salvo el
backlog).

## Estado

| Trabajo | Rama | Estado |
|---|---|---|
| Backlog (`docs/backlog.md`) | `main` | Hecho y subido |
| Fase 2: red | `fase2-red` | Implementada (594 pruebas en verde, CI de GitHub en verde); revisión adversarial hecha y sus 19 hallazgos corregidos, cada uno con su prueba (656 pruebas en verde) |
| Fase 3: combate | `fase3-combate` (desde `fase2-red`, que está fusionada dentro) | Diseño revisado (`docs/combate.md`); K1–K5 y el carril de audio, tema, ajustes, documento social y exportación integrados; revisión adversarial hecha y sus 18 hallazgos corregidos con prueba (1262 pruebas en verde) |
| Fase 4: fuerte | `fase4-fuerte` (desde `fase3-combate`) | Diseño v2 revisado (`docs/fuerte.md`); F0 (escena, capas, navmesh, rutas), F1 (fortaleza pura) y F2 (protocolo 4) integrados; F3 (servidor) y F5 (cliente) en marcha |

## Entorno (Linux)

- Godot 4.7.2-stable Linux x86_64, siempre con `--headless`.
- Git LFS descargado (146 objetos); Terrain3D 1.0.2 carga sus `.so` de Linux.
- Suite de partida: 83 pruebas, todas correctas en Linux (46,8 s). No hay diferencias con Windows.

## Backlog

- 321 elementos: los 320 de los diseñadores, menos 33 duplicados, más 27 añadidos de la crítica y 7
  que salen de dividir otros (UI-46, MUN-47, MUN-48, ART-42, ART-43, PRG-44 y PRG-45).
- Se aplicaron las 90 correcciones y las 205 listas de dependencias de la crítica. Todas las
  dependencias citadas existen, no hay ciclos y cada elemento está en una sola fase.
- Única dependencia hacia una fase posterior: ART-03 (fase 2) depende de ART-13 (fase 4), que ya
  está hecho.
- 90 decisiones pendientes tras fusionar las repetidas. Las contradicciones que señalaba la crítica
  (nombres de enemigos, longitud de nombres, reaparición, primer reino, monturas, Brasas, poder en
  Eldrun) tienen una recomendación única.

## Fase 2: progreso

| Paquete de red.md §17 | Contenido | Estado | Pruebas |
|---|---|---|---|
| A | `PlayerState.to_f32`/`equals_exact`, yaw en f32, `events_enabled`, `NetProtocol`, `NetMath`, `NetZones`, `EntityRecord`, `NetMessages`, `BotBrain` | Hecho | `test_net_messages` (42) |
| B | `NetSim`, `NetTransport` (ENet + `SceneMultiplayer` propio, autenticación, canales, simulador) | Hecho | `test_net_sim` (22, con ENet real en 127.0.0.1) |
| C1 | Piezas del servidor: `InputQueue`, `SnapshotBuilder`, `StateHistory`, `NetEntity(Registry)`, `ServerAuth`, `RateLimiter`, `SpawnPicker`, `ServerConfig`, `ServerMetrics`... | Hecho | 12 archivos de prueba; `test_architecture` con las reglas server/client |
| D | `TickSync`, `InterpolationClock`, `ClientPrediction`, `CorrectionSmoother`, `RemoteInterpolator`, cambios en `LocalPlayerController` | Hecho | `test_tick_sync` (17), `test_interpolation_clock` (8), `test_remote_interpolator` (16), `test_prediction` (24, dos mundos de física separados) |
| C2 | `ZoneServer`, `ServerMain`, `--server`, `--fake-players`, `--report`, `--dev-lock`, `--idle-quit` | Hecho | `test_zone_server`, `test_zone_server_net` (15, ENet real), `test_server_main` (6, procesos aparte con la zona real) |
| E | `NetClient`, `RemoteWorld`, `RemotePlayerView` (con el humanoide animado), `OnlineMain` (`--connect`, `--bot`), `ClientConfig`, `NetHarness` | Hecho | `test_net_loopback` a, b, c, e (ENet real), `test_net_client`, `test_remote_world`, `test_online_main`, `test_net_harness` (procesos) |
| Carril 2 | GUE-02 `RealmCatalog`, SOC-01 `NameRules`, TEC-03 GitHub Actions, ART-05 validador de assets | Hecho | `test_realm_catalog`, `test_name_rules`, `test_assets` |
| F (M4–M5) | Escenario d con NetSim, `--local`, `RealmSelect`, overlay F3/F4, seguridad, bot tramposo (5 modos), `--state-log` y `compare_state_logs`, `test_net_processes`, `BotSwarm` (`--bots`), `load_test` | Hecho | `test_net_loopback` d (y corte de 24 ticks), `test_net_processes`, `test_local_server_launcher`, `test_realm_select`, `test_net_debug_overlay`, seguridad en `test_zone_server_net` |

**Primera prueba real en procesos separados** (servidor headless en el Vado Gris, 1800 ticks, y dos
`--bot`, sin NetSim): bot 1, 704 snapshots con estado, 703 coincidencias exactas, 0 diferencias
sin explicar, 1 reinicio duro (el proceso se paró en la VM; TickSync lo recuperó); bot 2, 707/707
coincidencias, 0 diferencias. Servidor: 0,32 % de entradas sustituidas, 0 avisos, 0 errores de
física. Cada bot vio al otro como remoto.

Incidencia: el contenedor se reinició a mitad del paquete D; su trabajo a medias se recuperó de su
worktree y se terminó.

Primera medida orientativa (C2, Linux): Vado Gris con 64 jugadores falsos, tick p50 4,4 ms, p99
7,3 ms, máx. 11,7 ms; unos 100 µs por personaje (simulación + cerebro del bot). Se repetirá con
bots reales al final de la fase.

### Prueba de aceptación de la fase 2 (procesos separados, sin ventana)

Servidor headless en el Vado Gris (4500 ticks = 75 s) y 3 `--bot` (2 de Vardheim y 1 de Solmarch,
4000 ticks cada uno), dos pasadas. Script: `build/real/run.sh` (no versionado; los comandos están
abajo). Cruce de registros con `tools/compare_state_logs.gd`: «CORRECTO» en los 6 casos, 0 ERROR en
los registros.

| Pasada | Bot | Snapshots con estado | Coincidencias exactas | Correcciones | Dif. sin explicar | Reinicios duros | Resinc. | Ajustes TickSync |
|---|---|---|---|---|---|---|---|---|
| Sin NetSim | 1 | 1956 | 1956 | 0 | 0 | 0 | 0 | 9 |
| Sin NetSim | 2 | 1957 | 1957 | 0 | 0 | 0 | 0 | 0 |
| Sin NetSim | 3 | 1955 | 1954 | 0 | 0 | 1 | 0 | 7 |
| rtt=120, jitter=20, loss=5 | 1 | 1730 | 1730 | 0 | 0 | 0 | 0 | 3 |
| rtt=120, jitter=20, loss=5 | 2 | 1725 | 1725 | 0 | 0 | 0 | 0 | 20 |
| rtt=120, jitter=20, loss=5 | 3 | 1728 | 1728 | 0 | 0 | 0 | 0 | 18 |

El reinicio duro del bot 3 es del arranque (llegó un snapshot por delante de su predicción al entrar
el tercero); no dejó diferencias. Con NetSim hubo 9–10 entradas sustituidas por bot y ninguna
produjo diferencia (la sustituta repetía la misma entrada). Servidor: 0 errores de física, 0 avisos;
`simulate()` 74–77 µs de media con 3 jugadores (incluye el arranque); snapshot medio de 91 B con 2
remotos.

### Medidas de §19 (`tools/load_test.gd --matrix`, máquina de 4 núcleos, 120 s por escenario)

Revisadas tras la revisión adversarial (hallazgo A4). Las primeras cifras de este informe (30 s, sin
retardo, sustituidas entre 0,09 % y 0,16 %) **no medían el criterio**, que pide 100 ms de RTT, y la
batería no tenía los tamaños de 128 y 256 ni los 120 s de §16. Ahora la batería usa 120 s por escenario,
un escenario con `rtt=100`, los de 128 y 256 jugadores falsos y calcula las sustituidas también dentro de
la ventana de medida (sin el arranque).

| Escenario | Jugadores | Tick p50 / p99 / máx (ms) | KB/s por cliente | Sustituidas (sesión / ventana) |
|---|---|---|---|---|
| 64 falsos agrupados + 2 bots | 66 | 4,9 / 8,2 / 20,0 | 35,2 | 0,07 % / 0,00 % |
| 64 falsos agrupados + 10 bots | 74 | 6,2 / 9,7 / 17,2 | 35,3 | 0,03 % / 0,00 % |
| 64 falsos agrupados + 50 bots | 114 | 15,3 / 26,5 / 36,5 | 34,9 | 0,05 % / 0,00 % |
| **64 falsos agrupados + 10 bots, rtt=100** | 74 | 6,5 / 10,6 / 21,6 | 35,3 | **0,36 % / 0,00 %** |
| 64 dispersos + 10 bots | 74 | 6,8 / 11,4 / 20,5 | 35,3 | 0,03 % / 0,00 % |
| Altas y bajas a 1/s + 10 bots | 74 | 6,7 / 10,7 / 15,4 | 35,3 | 0,08 % / 0,00 % |
| 128 falsos agrupados + 10 bots | 138 | 11,3 / 19,7 / 24,2 | 35,2 | 0,03 % / 0,00 % |
| 256 falsos agrupados + 10 bots | 266 | 15,9 / 24,8 / 79,7 | 25,4 | 97,3 % / 100 % |
| 256 dispersos + 10 bots | 266 | 17,5 / 27,1 / 41,8 | 24,0 | 97,2 % / 100 % |

- `simulate()` por personaje: **42–50 µs** (la sección de simulación entera, ~57–66 µs por personaje).
- Snapshot lleno (57 registros): 1191 B, 250–730 µs de construcción.
- Subida: 2,3–3,7 KB/s por cliente (3,7 con 100 ms de RTT).
- **Criterio de la fase 2**: bajada (≤ 37 KB/s) **cumplida**; sustituidas (< 1 %) **cumplida y ahora sí
  medida con 100 ms de RTT** (0,36 % de la sesión con 64 agrupados y 10 bots; 0 dentro de la ventana; cada
  bot pierde unas 27 entradas en el arranque, 19–20 tardías, así que con 30 s salía un 1,2 % y con 120 s un
  0,36 %); **p99 del tick < 8 ms con 64 jugadores agrupados NO se cumple** en esta máquina (8,2 ms con 66
  jugadores, 9,7 con 74; la serie anterior de 30 s con exactamente 64 daba 8,7–9,6 ms). Los cuellos son
  `simulate()` en GDScript (por encima de los 25 µs de la palanca 6 de red.md §14) y `SnapshotBuilder`
  con muchos clientes reales.
- **128 y 256 jugadores**: con 138 el tick de mediana ocupa 11,3 de los 16,7 ms (p99 19,7 ms) pero el
  servidor aguanta los 60 ticks/s y no sustituye entradas. **Con 266 el servidor no sostiene el tiempo
  real** (44–47 ticks/s) y sustituye el 97 % de las entradas de los clientes reales: 256 jugadores en un
  proceso de GDScript sin optimizar quedan fuera de lo que esta fase promete. Primer límite orientativo
  de jugadores por batalla: unos 60 en un servidor de esta clase sin optimizar. Está anotado en red.md §14.
- Observación pendiente: el arranque con 100 ms de RTT empieza con poca antelación (19–20 entradas tardías
  por bot en los primeros segundos); vale la pena mirarlo.

### Revisión adversarial de la fase 2

Tres revisores Opus (netcode frente al diseño; robustez y seguridad; arquitectura y pruebas) y un
verificador por lente que intentó refutar cada hallazgo, casi siempre reproduciéndolo con un
script. 20 hallazgos, 19 confirmados y 1 refutado (N4: era un artefacto del simulador de red, que
sella los paquetes entrantes con el tick del poll).

| Id | Gravedad | Hallazgo |
|---|---|---|
| N1 | alta | Si el cliente se adelanta más de 30 ticks (parón del servidor de ~0,6 s), las entradas TOO_EARLY no dan margen y TickSync nunca se recupera |
| N2 | media | Los limitadores se recargan por tick del servidor: tras un parón de ~1,3 s se expulsa a todos los clientes honrados |
| N3 | media | Tras perder ticks el servidor, el reloj de interpolación conserva el máximo viejo 120 ticks y los remotos se congelan ~1,3 s |
| N5 | baja | Ticks u32 guardados en int32 (historial, avisos, reloj): 414 días de rango en vez de 828 |
| S1 | alta | Paquetes de SceneMultiplayer que no son RAW registran errores del motor, se saltan los limitadores y alargan el tick |
| S2 | alta | El tope por IP solo se aplica en el HELLO: una IP ocupa todas las plazas con conexiones mudas |
| S3 | alta | Cada alta queda para siempre en el registro de jugadores (~80 KB por ciclo de conexión) |
| S4 | media | El RTT medido lo decide el cliente: «fingir lag» daría el rebobinado máximo en la fase 3 |
| S5 | media | SIGTERM/Ctrl+C matan el servidor sin informe ni cierre ordenado y dejan el bloqueo de `--local` |
| S6 | baja | Un expulsado vuelve en un RTT con los avisos a cero |
| S7 | baja | El tiempo de espera al conectar es 3,5 veces el documentado |
| A1 | alta | En Windows, `--local` nunca reconoce un servidor lanzado por otra ventana (`OS.is_process_running` solo ve hijos propios) |
| A2 | media | La prueba d mide el mínimo de la ventana de TickSync, no el margen de cada snapshot (se corrige el documento) |
| A3 | media | `test_architecture` deja pasar `pick_random`, `shuffle`, `randomize` y contadores de fotogramas |
| A4 | media | El criterio «< 1 % sustituidas con 100 ms» nunca se midió con 100 ms (con rtt=100 sale 1,2 %, sobre todo del arranque) |
| A5 | baja | Las pruebas de procesos no miran los registros de los bots |
| A6 | baja | `test_prediction` tiene aserciones débiles («por la rampa» pasa saltando en llano) |
| A7 | baja | Dos suites a la vez en la misma máquina chocan en puertos, rutas de `build/` y el bloqueo de `--local` |
| A8 | baja | `SpawnPicker` usa `Zones` directamente, contra la frontera de `NetZones` |

Ninguno afecta al juego normal en una red sana (la prueba de aceptación salió limpia), pero N1, N2,
S1, S2, S3 y A1 son fallos de verdad en producción o en el uso diario con `--local` en Windows.

**Los 19 están corregidos en `fase2-red`**, cada uno con una prueba que fallaba antes del arreglo
(656 pruebas en verde). Lo más relevante:

- N1: `InputQueue` anota la antelación también de las entradas demasiado adelantadas.
- N2: el servidor concede a los limitadores el crédito de los ticks que perdió en un parón.
- N3: el reloj de interpolación adopta en ~0,5 s un escalón sostenido de los offsets.
- S1: `GuardedEnetPeer` (un `MultiplayerPeerExtension` sobre ENet en el servidor) filtra los
  paquetes ajenos antes de `SceneMultiplayer`: sin errores del motor, con avisos y expulsión
  (+6 % de coste por paquete medido). Depende del formato interno de `SceneMultiplayer`
  (documentado; `test_net_sim` lo detectaría si cambia).
- S2: tope por IP al conectar (IPv6 por /64) y 90 ticks de plazo para el HELLO.
- S3: el registro de jugadores es un anillo y las fichas sueltan sus objetos al irse.
- S4: el RTT se acota con el de ENet; `interp_delay_q` se limita.
- S5: `--stop-file` para parar en orden e informe reescrito cada 10 s; en Linux, `--local`
  comprueba en `/proc/<pid>/cmdline` que el pid del bloqueo es un servidor.
- S6: 30 s de enfriamiento tras una expulsión. S7: plazo de conexión real.
- A1: en Windows, `tasklist` para pids ajenos (**sin probar: no hay Windows aquí**).
- A3, A5, A6, A7, A8: pruebas de arquitectura más estrictas, registros de los bots revisados,
  aserciones más fuertes, puertos y carpetas por pid y la frontera de `NetZones`.
- A4: la batería de carga mide el criterio con 100 ms (tabla de arriba).

## Fase 3: progreso

Diseño en [combate.md](combate.md): revisado con dos lentes antes de implementar (2 bloqueantes y
~25 importantes corregidos en la versión 2) y con una §11 que recoge lo que se cerró al implementar.

| Paquete | Contenido | Pruebas nuevas |
|---|---|---|
| K1a | `CombatState` (34 B; `PlayerState` de 69 B), catálogo en `data/combat/`, `ActionMachine` (combo, carga, búfer, cancelaciones, bloqueo, parada, esquiva, resistencia, controles), entradas sustituidas que no inventan acciones, `sim_hash` con el catálogo, `PROTOCOL_VERSION = 2` | `test_combat_catalog`, `test_combat_state`, `test_action_machine` |
| K1b | `HitShapes`, `DamageFormula`, `FactionRules`, modo PvP por zona | `test_hit_shapes`, `test_damage_formula`, `test_faction_rules` |
| K2 | Registro de 21 B con `health_q`, bloque extra de vida, ENTITY_EVENT (HIT, DEATH, KILL, RESPAWN), RESPAWN_REQUEST, ids de comandos | ampliaciones de `test_net_messages` y `test_snapshot_builder` |
| K3 | `CombatDirector` (orden del tick), `CombatResolver` con rebobinado y precedencia de defensas, `Combatant`, `DamageLedger`, muerte, reaparición, caída, volúmenes letales, zonas seguras, maniquíes, `CommandRegistry` y consola (`--console`), `--combat-log`, bots de combate (`--fake-brain=combat`) | 134 (resolutor, director, loopback ENet, procesos...) |
| K4 | Eventos temporizados, `CombatFeedback` (marcador, números, DPS), barras de vida y resistencia, placas con nombre y vida, pantalla de muerte con reaparición, capa de animación de combate con clips de UAL, armas provisionales, demo con el combo | 111 |

| K5 | Rebobinado con NetSim (20/20 golpes vistos confirmados con rtt=150 y jitter=30; 0 impactos con 30 ticks de desfase), bot tramposo `rewind`/`reach`/`rate` (sin daño de más), reconciliación con rtt=120 y 5 % de pérdida en refriega, carga con combate, demo, primera pasada de equilibrio (`tools/combat_balance.gd`) | `test_combat_loopback`, `test_combat_reconciliation`, `test_bot_cheat*`, `test_combat_balance` |
| Carril 3 | ART-10 audio (buses, `AudioDirector` con pools y límite de voces), UI-02 tema (`eldmark_theme.tres`, emblemas SVG provisionales, galería), UI-09 componentes, UI-16 ajustes (F10, `user://settings.cfg`), SOC-02 `docs/social.md`, TEC-12 `export_presets.cfg` y `tools/export.sh`/`.ps1` | 81 |

**Carga con combate** (K5, máquina en reposo, 60 s, 10 bots reales y el resto jugadores falsos con
cerebro de combate):

| Combatientes | Tick p50 / p99 / máx (ms) | simulate | combate | snapshots | KB/s por cliente |
|---|---|---|---|---|---|
| 32 | 4,9 / 8,9 / 17,2 | 3,1 | 0,35 | 0,84 | 23,6 |
| 64 | 9,4 / 15,9 / 24,9 | 6,5 | 0,77 | 1,41 | 35,3 |
| 128 | 17,5 / 30,0 / 36,3 | 13,3 | 1,41 | 2,16 | 31,4 |

- **Primer límite de jugadores por batalla con combate: 64** (cabe en el tick, 0 entradas
  sustituidas, 0 rebobinados rechazados). El criterio estricto de p99 < 8 ms solo se cumple hasta
  unos 28. El cuello es `simulate()` (69–72 µs por personaje con la máquina de acciones), no la
  resolución de golpes (76–97 µs por comprobación, pocas por tick). Con 128 el servidor se satura y
  los honrados empiezan a superar el tope del rebobinado.
- **Equilibrio** (bots que no reaccionan, cota baja): DPS medido = calculado (combo 156,3); muerte
  en 5,95 s contra uno quieto y 14,47 s contra uno que bloquea; mediana de 60 duelos de bots 10,7 s.
  No se ha cambiado ningún dato (propuesta: tercer ligero de 130 a 150, a decidir viendo jugar).

### Revisión adversarial de la fase 3

Tres lentes (combate frente al diseño; robustez, seguridad y trampas; arquitectura, pruebas y
cliente), con verificadores que intentaron refutar cada hallazgo: 19 hallazgos, 18 confirmados
(C2 y R3, y C3 y T6, son el mismo fallo visto dos veces) y 1 refutado (R5).

| Id | Gravedad | Hallazgo |
|---|---|---|
| C1 | alta | Una sola entrada sustituida durante la pulsación hace que el servidor convierta un fuerte en ligero |
| R1 | alta | El cliente controla el tope del rebobinado (antelación por entrada e `interp_delay_q`) y elige el tick a su favor |
| C2/R3 | media | La muestra rebobinada de bloqueo sigue protegiendo a un defensor aturdido: cada golpe le vuelve a romper la guardia |
| R2 | media | Quien deja de mandar entradas en plena carga mantiene un fuerte cargado indefinidamente |
| R4 | media | El SPAWN de un enemigo lleva su `CombatState` entero (resistencia exacta, búfer...) |
| T1 | media | Pantalla de muerte y ajustes se pisan el estado del cursor |
| T2 | media | Los remotos no reproducen una segunda esquiva o tambaleo seguidos |
| C3/T6 | baja | El destello de un remoto golpeado por el local sale antes de que se le dibuje en el tick del golpe |
| C4 | baja | Un cadáver o un aturdido en el aire conserva la velocidad y se dirige |
| C5 | baja | Si el enlace del combo no se ejecuta, el combo no vuelve a 0 |
| T3 | baja | El servidor dedicado compila 56 de 69 scripts del cliente |
| T4, T5 | baja | Pruebas de DPS y de reconciliación más débiles de lo que dicen |
| T7 | baja | Casillas del backlog F3 marcadas sin cumplir del todo |
| T8 | baja | Una parada perfecta enciende la viñeta de daño |

**Todos corregidos en `fase3-combate`**, con una prueba que fallaba antes (1262 en verde). Notas:

- C1: un bit nuevo (`combat_flags` bit 6) marca el ligero de la pulsación; una sustitución solo
  retrasa la carga un tick. Con C4, C5 y R2 cambia la simulación predicha: **protocolo 3**.
- R1, **cerrado solo en parte**: el rebobinado se fija una vez por golpe (primer tick activo) y la
  antelación que cuenta para el tope se acota con la mediana reciente + 3 (y 8 como máximo). Un
  tramposo con todas las entradas adelantadas e `interp_delay_q` al máximo todavía llega al tope
  de 24 ticks con ping de LAN, porque el servidor no puede comprobar la interpolación declarada.
  Documentado en combate.md §4.3 y red.md §10.
- R4: el SPAWN de un enemigo lleva un `CombatState` neutro (solo acción y arma).
- T2: los remotos ven una segunda esquiva o tambaleo seguidos gracias a un contador de reinicio
  en el byte de acción (`ActionWire`).
- T3: `boot.gd` ya no nombra clases del cliente; el servidor dedicado no compila scripts del
  cliente (lo comprueba `test_architecture` con un servidor real).
- Quedan sin tratar dos rarezas menores que el verificador anotó: un tambaleo corto que empieza y
  acaba dentro de la ventana de rebobinado deja contar la muestra vieja de bloqueo, y un ligero 3
  sobre un aturdido cambia el aturdimiento por un tambaleo más corto.

**Decisiones abiertas que dejo para el usuario** (no bloquean):
- Cómo cerrar del todo R1 (el cliente declara su retardo de interpolación): por ejemplo, fijar el
  retardo por zona y no aceptar el declarado.
- El tope de rebobinado de 24 ticks no cubre a un honrado con 200 ms de RTT (11 de 20 golpes):
  subir `MAX_REWIND_TICKS` o recortar el margen de TickSync. Importa para Latinoamérica.
- Bajar el coste de `simulate()` (palanca 6 de red.md §14: C++) si se quieren batallas de más de 64.

## Fase 4: progreso

Diseño en [fuerte.md](fuerte.md), revisado antes de implementar (22 hallazgos, 3 bloqueantes; varios
supuestos técnicos comprobados ejecutando Godot y Terrain3D).

| Paquete | Contenido | Estado |
|---|---|---|
| F0 | Escena y generador del Vado Gris (ejecutado aquí): nodo de fortaleza, puerta cerrada con dos cuerpos (movimiento por capas de reino, vista en la capa de estructuras), `respawn_points`, patrullas, `NpcSpawner`; navmesh horneada (0,3 MB, celda 0,25 m, verificada: sin salida con la puerta cerrada y sin cruzar el lecho del río); rutas en `data/routes/vado_gris.tres` | Hecho |
| F1 | `FortressState` con toda la tabla de captura, presencia, progreso en enteros, `WarEvents`, `RespawnRules`, `SiegeView` (44 pruebas de estado) | Hecho |
| F2 | Protocolo 4: OBJECT_STATE, SPAWN de estructuras y PNJ, WAR, TELEGRAPH, /atascado, SCOREBOARD, REJECT de desequilibrio | Hecho |
| F3 | Servidor del fuerte | En marcha (cortado por un segundo reinicio del contenedor y relanzado desde sus commits) |
| F5 | Cliente del fuerte | En marcha (ídem) |
| F4 | PNJ (navegación, IA, Huecos, Capitán, guarnición, Guardianes) | Pendiente |
| F6 | Bots de asedio, carga y prueba de extremo a extremo | Pendiente |

## Pendiente de probar mañana con ventana

Nada de lo que sigue se ha podido ver: aquí no hay GPU ni ventana. Todo lo de red está probado sin
ventana (pruebas, procesos y bots), pero falta el ojo humano.

En PowerShell, desde la raíz del repo y en la rama `fase2-red` (o en la más reciente, que la
contiene):

```powershell
$godot = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64_console.exe"
& $godot --headless --path . --import
& $godot --headless --path . -s res://tests/run_tests.gd        # ~7 min, 594 pruebas
```

1. **F5 sin argumentos** (o `& $godot --path .`): debe ser exactamente el sandbox de siempre en el
   Vado Gris. Comprobar también `-- --demo --quit-after-demo`.
2. **Servidor y dos clientes con ventana** (tres terminales):
   ```powershell
   & $godot --headless --path . -- --server --debug-commands
   & $godot --path . -- --connect=127.0.0.1 --realm=vardheim --name=Ana
   & $godot --path . -- --connect=127.0.0.1 --realm=solmarch --name=Bruno --net-sim=rtt=120,jitter=20,loss=3
   ```
   Mirar: que cada uno ve al otro moverse suave (animado, sin patinar ni tirones), que el propio
   responde al instante, que F3 muestra el panel de red y F4 el fantasma, y que no hay saltos
   visibles al corregir.
3. **Todo en uno**: `& $godot --path . -- --local`. Sin `--realm` debe salir la pantalla de
   elección de reino (comprobar su maquetación: no se ha visto nunca). Abrir una segunda ventana
   con `--local` y comprobar que reutiliza el mismo servidor.
4. **Bots contra tu cliente**: con el servidor del punto 2,
   `& $godot --headless --path . -- --bots=20 --connect=127.0.0.1` y mirar a 20 remotos a la vez.
5. **Servidor Linux, clientes Windows** (si hay VPS): la reconciliación debería absorber las
   diferencias de último bit; el panel F3 cuenta las correcciones.
6. **Combate** (rama `fase3-combate`): con el servidor y dos clientes del punto 2, atacar (clic
   izquierdo: toque = ligero, mantener = fuerte), bloquear (clic derecho), esquivar (Ctrl).
   Mirar: que el golpe propio sale al instante y el marcador al confirmarse; que el otro ve la
   animación; barras de vida y resistencia; placas; morir y reaparecer con el botón. Maniquí:
   en `test_world` y junto a cada campamento del Vado Gris. Vista previa de los clips:
   `& $godot --path . res://scenes/tests/combat_preview.tscn`. Las armas son una caja y un
   cilindro (provisionales).
7. **Interfaz**: tema (`scenes/tests/ui_gallery.tscn`), ajustes con F10, emblemas SVG
   provisionales. Faltan las fuentes OFL (ver `assets/LICENCIAS.md`).
8. **Exportación** (TEC-12): instalar las plantillas 4.7.2 desde el editor y lanzar
   `tools\export.ps1` (no se ha podido ejecutar aquí).
9. Desde el editor: *Depurar ▸ Personalizar instancias de ejecución* (instancia 1:
   `--headless -- --server --debug-commands`; 2 y 3: `-- --connect=127.0.0.1 --realm=vardheim` y
   `--realm=solmarch`).

- **Windows, sin probar en esta máquina (Linux):** la rama de Windows de
  `LocalServerLauncher.is_process_alive` (A1, `tasklist /FI "PID eq <pid>" /FO CSV /NH`) está escrita
  según el código de Godot 4.7.2 (`OS.is_process_running` solo conoce los procesos hijos propios). Sus
  pruebas corren en todas las plataformas (lectura de la salida de `tasklist`; un proceso hijo mira al
  ejecutor y el ejecutor mira a un nieto), pero hay que ejecutar en Windows la suite completa y, en
  particular, `--filter=test_local_server_launcher`, y abrir dos ventanas con `--local` para ver el mensaje
  «Servidor local ya en marcha … se reutiliza». También hay un trabajo `windows-latest` en
  `.github/workflows/tests.yml` (sin ejecutar aún: la primera ejecución en GitHub dirá si el paso de
  descarga y descompresión de Godot para Windows funciona).
- El bloqueo huérfano tras `SIGTERM`/`SIGINT` (S5) solo se mitiga en Linux (`/proc/<pid>/cmdline`); en
  Windows un bloqueo huérfano con el pid reutilizado seguiría engañando a `--local` durante un intento.

## Decisiones tomadas fuera del contrato

- Paquete A: `BotBrain._init(rng_seed, …)` en vez de `seed` (para no tapar la función global);
  `NetZones.allowed_realms` devuelve vacío (todos los reinos) porque `Zones` no registra reinos por
  zona; `NetZones` añade `realm_name()`, `find_spawn_point()`, `get_spawn_points()` y
  `spawn_group()` (estas dos últimas, tras la revisión, para que `SpawnPicker` no llame a `Zones`
  directamente: §1.5 y §17.3); los `decode` rechazan UTF-8 inválido sin registrar errores del motor.
  `ServerMain` sí llama a `Zones` (lista de zonas y reinos con campamento, §19) y
  `test_architecture` lo admite como excepción, igual que el sandbox `ClientMain`.
- **Criterio de antelación de la prueba d de `test_net_loopback` (red.md §16)**: el contrato decía
  «`input_margin` en [0, 6] en régimen». La prueba mide el **mínimo de la ventana de `TickSync`**
  (`get_window_min()`) en [0, 6] (`MAX_TARGET` 4 + `SLOW_DOWN_THRESHOLD` 2, la banda que regula el
  bucle de control), con la media de cada bot dentro y al menos un 80 % de las muestras. Razón: el
  `input_margin` de un snapshot suelto es el mínimo de las llegadas de dos ticks y, con
  rtt=150, jitter=30 y loss=10, queda por diseño 2–4 ticks por encima del mínimo de la ventana: con
  las mismas semillas, entre el 28 % y el 35 % de los snapshots de cada bot pasa de 6 (media 6,06–6,11,
  histograma de Botaaab {3:1, 4:4, 5:29, 6:66, 7:46, 8:5}), mientras que el mínimo de la ventana sale
  fuera de [0, 6] solo un 2,3 %, 0 % y 0 % de las veces. Pedir el 98 % de los snapshots dentro de
  [0, 6] obligaría a bajar el objetivo y a aceptar más entradas tardías. Revisión adversarial,
  hallazgo A2: la aserción no cambia; se corrige el texto de red.md §16 d.
- **Reloj de interpolación (red.md §4.3)**: el pseudocódigo normativo corregía contra el tick de
  dibujo anterior y convergía 1 tick por delante del objetivo (retardo efectivo de 3 ticks en vez
  de 4). Corregido en el código y en red.md: primero se avanza y luego se corrige.
- Paquete D: `ClientPrediction.get_stats()` usa las claves `matches`, `ignored`, `replays`,
  `corrections`, `resimulated_ticks`, `last_correction`, `max_correction` y `hard_resets`; el
  jitter por debajo de 0,001 ticks cuenta como 0.
- **Nombres** (SOC-01, provisional): 3–16 letras con tildes y ñ, mayúscula inicial, sin espacios
  ni dígitos, lista de reservados, únicos entre los conectados (sin tildes ni mayúsculas, y la ñ
  cuenta como n). Nombres por defecto «Jugador» + 4 letras y, para bots, «Bot» + 4 letras.
- **Reinos por zona** (GUE-02): el Vado Gris solo admite Vardheim y Solmarch (Askarra recibe
  REJECT REALM); `test_world`, los tres.
- **CI** (TEC-03): el checkout no baja LFS; se restaura la caché de `.git/lfs` y luego `git lfs
  pull`. Para que una prueba rota bloquee el merge hay que marcar «Suite completa» como
  comprobación obligatoria en la protección de la rama (solo desde GitHub).
- Paquete E: sin servidor, `--local` y `--bots` daban error (hasta M4–M5); en modo bot headless la
  zona se carga sin lo visual; el cliente también fuerza la colisión completa de Terrain3D.
- Paquete C2: el `sim_hash` lo calcula `ZoneServer.start()`; un salto de más de 1,5 m en un tick
  se registra como aviso (no error) y en el contador `physics_errors` del informe.
