# Informe de la sesión nocturna

Sesión sin supervisión del 28 al 29 de octubre de 2026, **cerrada a petición del usuario** el 29 por
la tarde. Este archivo está en la rama más reciente (`fase5-cuentas`) y en `fase4-fuerte`. Las ramas
van encadenadas: `main` → `fase2-red` → `fase3-combate` → `fase4-fuerte` → `fase5-cuentas`, y nada
está fusionado en `main` salvo el backlog. Aparte, `fase4-chat-grupos` (sale de `fase4-fuerte` en
a150b78) tiene el chat y los grupos **sin revisar ni fusionar**.

## Estado

| Trabajo | Rama | Estado |
|---|---|---|
| Backlog (`docs/backlog.md`) | `main` | Hecho y subido |
| Fase 2: red | `fase2-red` | Implementada (594 pruebas en verde, CI de GitHub en verde); revisión adversarial hecha y sus 19 hallazgos corregidos, cada uno con su prueba (656 pruebas en verde) |
| Fase 3: combate | `fase3-combate` (desde `fase2-red`, que está fusionada dentro) | Diseño revisado (`docs/combate.md`); K1–K5 y el carril de audio, tema, ajustes, documento social y exportación integrados; revisión adversarial hecha y sus 18 hallazgos corregidos con prueba (1262 pruebas en verde) |
| Fase 4: fuerte | `fase4-fuerte` (desde `fase3-combate`) | Diseño v2 revisado (`docs/fuerte.md`); F0 a F5 y F6a integrados (escena, fortaleza pura, protocolo 4, servidor del fuerte, PNJ, cliente, bots de asedio, equilibrio de reinos, carga). Suite completa en verde con F4 (1687 pruebas); con F6a, ver «Cierre». Diseño de habilidades revisado (`docs/habilidades.md`), sin implementar. Falta F6b, las habilidades (H1–H5) y la revisión adversarial de la fase 4 |
| Fase 4: chat y grupos | `fase4-chat-grupos` (desde `fase4-fuerte` a150b78) | SOC-03 a SOC-08 implementados (protocolo 5, `ChatRouter`, caja de chat, `PartyManager`, marcos de grupo, menú social), con su suite; **sin la revisión adversarial y sin fusionar** (la sesión se cerró durante la revisión) |
| Fase 5: diseño | `fase5-cuentas` (desde `fase4-fuerte`) | `docs/plataforma.md` y `docs/progresion.md` escritos y revisados por tres lentes cada uno (45 y 41 hallazgos); **falta conciliarlos entre sí** (cada uno lista en su sección de interfaz lo que pide al otro). Sin código |

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
| F3 | Servidor del fuerte: `FortressController` (presencia, `advance`, efectos, OBJECT_STATE y WAR), la puerta como blanco (multiplicadores, capas por reino, reparación), comandos 8–11, reaparición en el fuerte, GUE-41 (salida en combate), /atascado, SCOREBOARD, KILL a toda la zona, `--battle-log` y `tools/war/summarize_battle.gd` | Hecho |
| F5 | Cliente del fuerte: `FortressView` con el gancho `before_simulate` (la puerta igual en cliente y servidor en cada tick), HUD de captura, banners, barra de jefe, marcas de TELEGRAPH, brújula, mapa horneado (`assets/maps/vado_gris.png`), minimapa, mapa completo con la reaparición, marcador (Tab) y registro de bajas, pistas, recuento por reino en la selección | Hecho |
| F4 | PNJ: `NpcNavigation` (mapa propio, enlace de la puerta por reino), `NpcDefinition`/`NpcCatalog` (`data/npcs/`), armas de PNJ y golpe imbloqueable del Capitán con TELEGRAPH, `HfsmBrain` (reposo, patrulla, alerta, combate, regreso; fichas: nunca más de 2 atacan a la vez), `NpcSpawnerSystem` (Huecos, Capitán del Vado, guarnición del reino dueño, 2 Guardianes por campamento), `--no-npcs`, comando 12 `npc_debug` | Hecho (MUN-10 y MUN-11 siguen «en curso»: falta jugarlos con personas) |
| F6a | Bots de asedio (`BotBrain` SIEGE, `--fake-brain=siege`, `--bot-brain=siege` para `--bot` y `--bots`), `--max-realm-diff` con REJECT 9 y recuento real en el WELCOME, falsos de relleno, `--run-at`, escenario `siege` de `load_test`, `tools/war/siege_runner.gd` y `siege_battle.gd` | Hecho (GUE-42; GUE-15/16/17 siguen «en curso» hasta F6b). Medido sin PNJ |
| F6b | Prueba de extremo a extremo neutral → Vardheim → Solmarch con los PNJ de verdad, GUE-43/44/45, carga con PNJ | Pendiente (se cortó al cerrar la sesión, sin commits; el encargo está en «Cierre») |
| Habilidades | Diseño corto `docs/habilidades.md` (CMB-19 a 24, CMB-28, PRG-04/07/08, UI-11, UI-45), revisado por tres lentes escépticas (41 hallazgos, 3 bloqueantes; 34 aplicados, 4 rechazados en parte con motivo en su sección «Revisión») | Diseño hecho; implementación tras fusionar F4 (paquetes H1 a H5) |
| Social | Chat (SOC-03 a SOC-05) y grupos (SOC-06 a SOC-08) | Implementado en la rama `fase4-chat-grupos`; la revisión adversarial (tres lentes con refutación) se cortó al cerrar: falta revisar y fusionar |
| Fase 5 (diseño) | `docs/plataforma.md` (servicio en Go + PostgreSQL, cuentas, billetes, guardado, RGPD, GM) y `docs/progresion.md` (objetos, inventario, monedas, niveles, razas): borrador, revisión escéptica y corrección | Hecho en `fase5-cuentas`; la conciliación entre los dos se cortó al cerrar |

### Medidas de F6a (asedio sin PNJ; 4 núcleos con otra suite en marcha, `uptime` 0,87 → 1,66)

| Medida | Valor |
|---|---|
| Del campamento a la puerta (con esprint) | puente 24–25 s; vado 36,5–37,5 s |
| Romper la puerta (9000 de vida) desde el primer golpe | 14,9 s con 20 atacantes; 21,9 s con 10; 36,9 s con 6 |
| Captura del neutral con 20 de Vardheim (capitán con `fort_kill_captain`) | 55,9 s (puerta rota a los 39,5 s) |
| Recaptura por 20 de Solmarch | 6,0 min (puerta 199,5 s, 117,7 s de disputa en el círculo); con 10 por bando, 8,8 min |
| Carga 32 contra 32 (64 jugadores, 120 s en la puerta y el círculo) | tick p50/p95/p99/máx 10,6 / 15,3 / 19,1 / 27,8 ms; 36,1 KB/s por cliente; 0 % sustituidas |
| Carga 64 contra 64 (128) | 14,8 / 22,0 / 26,4 / 42,8 ms; 28,5 KB/s; **50,8 % sustituidas** |

**El criterio de p99 < 8 ms con 64 jugadores no se cumple** (19,1 ms); domina `simulate()`
(77 µs por personaje); la sección `war` cuesta 0,1 ms. Primer límite de batalla en el fuerte:
**32 contra 32**. La recaptura desequilibrada (los refuerzos llegan de uno en uno) queda en GUE-44.

### Medidas de F4 (máquina compartida con otras suites: cotas altas)

| Medida | Valor |
|---|---|
| Cerebro `HfsmBrain` por PNJ y tick (p50, piensa cada 6 ticks escalonado) | 15–30 µs |
| `simulate()` de un PNJ | 32–56 µs (hasta ~100 µs con cerebro en pleno combate) |
| Sección `npc` (`NpcSpawnerSystem`, 14 puestos del Vado Gris) | ~60 µs/tick |
| Tick con los 9 PNJ del Vado Gris y 3 bots peleando | p50 1,0–1,3 ms, p99 2–2,4 ms |
| 3 bots de combate limpian los 4 Huecos | ~46,5 s |
| 4 bots (curados cada tick) derrotan al Capitán del Vado (30 000 PV) | ~77,5 s; sin curarlos mueren antes |
| Un intruso en la zona segura ante los 2 Guardianes | muere en 4,2–5,2 s (criterio < 10 s) |

Los criterios finos de MUN-10 (60–90 s con 2–3 personas) y MUN-11 (60–120 s con 3–5) necesitan
personas: los bots no son buena medida. Vida y daño de los PNJ ajustados para que los criterios se
puedan medir (provisionales; ver `docs/fuerte.md` §8.3).

## Cierre de la sesión: qué queda y en qué orden

La sesión se cerró a petición del usuario. Se pararon los trabajos en marcha y se subió todo lo que
habían dejado; nada se ha perdido salvo F6b, que aún no tenía commits.

1. **Suite completa de `fase4-fuerte` tras F6a** (ver el resultado al final de esta sección). Con F4
   ya fusionado dio 1687 de 1687. Tras fusionar F6a pasaron las pruebas filtradas que tocan su código
   (`siege` 35, `server_main` 15, `realm_balance` 18, `bot_brain` 27). La integración necesitó dos
   arreglos (4bb0eab): `HfsmBrain` (F4) y `BotBrain` (F6a) declaraban los mismos miembros, y las
   pruebas de F6a, escritas sin PNJ, ahora arrancan con `--no-npcs`.
2. **Chat y grupos** (`fase4-chat-grupos`): falta la revisión adversarial (privacidad entre reinos,
   servidor y protocolo, cliente) y fusionarla en `fase4-fuerte`. Toma `PROTOCOL_VERSION = 5`. Choca
   con `zone_server.gd`, `hud.gd` e `input_bindings.gd` de F4/F6a: hay que resolver a mano y pasar la
   suite. Lo implementado y lo pendiente está en `docs/social.md` §12.
3. **F6b**, el encargo que se cortó:
   - **Bots contra los PNJ.** Los SIEGE matan a los Huecos y al Capitán del Vado sin comandos.
     Atacan al PNJ del dueño más cercano y respetan el golpe imbloqueable.
   - **Criterio de GUE-15.** «`--bots=20` por bando capturan y recapturan sin intervención», con PNJ
     reales: neutral → Vardheim → Solmarch.
     - Una herramienta larga fuera de la suite.
     - Una versión corta dentro, sin `fort_kill_captain`.
     - Si no capturan, ajustes mínimos y provisionales anotados en `fuerte.md` §8.3.
   - **GUE-43, GUE-44 y GUE-45.**
     - GUE-43: el falso de relleno cede su plaza a una persona.
     - GUE-44: los refuerzos se juntan antes de salir.
     - GUE-45: los SIEGE del dueño defienden la pasarela.
   - **Carga con PNJ.** `load_test.gd --siege` con 32 contra 32.
   - **Batalla con telemetría.** Una batalla completa con `--battle-log` y su resumen.
   - **Herramientas.** `SiegeRunner.start(..., with_npcs = true)` arranca con los PNJ.
4. **Habilidades** (`docs/habilidades.md` §7). Se empieza con F4 y el chat fusionados.
   - Dos carriles: H1a → H1b → H3a → H3b → H3c, y a la vez H2 → H4 → H5.
   - Protocolo 6.
5. **Revisión adversarial de la fase 4** entera (tres lentes con refutación, como las de las fases 2
   y 3) y sus arreglos con prueba.
6. **Fase 5**:
   - Primero, conciliar `plataforma.md` y `progresion.md`. Cada uno lista en su sección de interfaz
     lo que pide al otro: nombres de tablas, ids en JSON, quién es dueño de CMB-30, billete de 52 B.
   - Fijar `PROTOCOL_VERSION = 7` (la 5 es del chat y la 6 de habilidades).
   - Luego, implementar en `fase5-cuentas` siguiendo sus paquetes.
   - En esta máquina hay Go 1.24 y PostgreSQL 16. Las pruebas del servicio usan un `initdb` efímero
     con `runuser -u postgres`, comprobado.

**Suite completa de `fase4-fuerte` tras F6a**: en marcha al cerrar (las 617 primeras, sin fallos).

Lo que tiene que decidir el usuario está en «Decisiones abiertas» al final.

## Pendiente de probar mañana con ventana

Nada de lo que sigue se ha podido ver: aquí no hay GPU ni ventana. Todo lo de red está probado sin
ventana (pruebas, procesos y bots), pero falta el ojo humano.

En PowerShell, desde la raíz del repo y en la rama `fase2-red` (o en la más reciente, que la
contiene):

```powershell
$godot = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64_console.exe"
& $godot --headless --path . --import
& $godot --headless --path . -s res://tests/run_tests.gd        # ~17 min en fase4-fuerte, unas 1720 pruebas
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

10. **El fuerte del Vado Gris** (rama `fase4-fuerte`). En tres terminales:
    ```powershell
    & $godot --headless --path . -- --server --zone=vado_gris --debug-commands
    & $godot --path . -- --connect=127.0.0.1 --realm=vardheim --name=Ana
    & $godot --path . -- --connect=127.0.0.1 --realm=solmarch --name=Bruno
    ```
    Mirar:
    - el HUD de captura al acercarse (dueño, fase, progreso, «Disputado», vida de la puerta) y los
      banners;
    - la barra de jefe del Capitán del Vado y la marca en el suelo de su golpe imbloqueable;
    - la brújula, el minimapa y el mapa (M), con la elección de reaparición al morir;
    - el marcador (Tab), las pistas y los estandartes, que cambian de color al capturar;
    - los Huecos patrullando y peleando; los Guardianes matando a un intruso en el campamento ajeno.

    Comandos de la consola del servidor: `fort_kill_captain`, `fort_owner vardheim`, `fort_reset`,
    `fort_capture_speed 20`, `npc_debug`.

    Con bots de asedio contra tu cliente:
    ```powershell
    & $godot --headless --path . -- --server --zone=vado_gris --fake-players=40 --fake-brain=siege
    & $godot --headless --path . -- --bots=20 --bot-brain=siege --connect=127.0.0.1
    ```
    Todo lo visual de la fase 4 es provisional y está sin ver: Huecos con el humanoide, estandartes,
    efectos de la puerta, marcas en el suelo, mapa horneado, colores y tamaños del HUD.
11. **Chat y grupos** (rama `fase4-chat-grupos`, con el servidor y los dos clientes del punto 2):
    - Intro abre la línea y Esc la cierra.
    - Probar `/d`, `/z`, `/s Bruno hola` (entre reinos debe decir «no está conectado») y `/r`.
    - Invitar desde el menú social, apuntando a un aliado a menos de 20 m.
    - Ver los marcos de grupo.

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

- **Fase 4, integración**:
  - `FortressView` acepta la definición de la fortaleza como recurso o como ruta, igual que el
    servidor.
  - La prueba de los tramposos en procesos deja 5,3 s de margen entre los bots y el servidor.
  - Los miembros del patrón SIEGE en `BotBrain` llevan el prefijo `_siege_`, porque los PNJ heredan
    de `BotBrain`.
  - `SiegeRunner` arranca sin PNJ salvo que se le pida.
- **F4**:
  - Vida y daño de los PNJ ajustados para poder medir los criterios. Hueco, guardia y Guardián
    tienen 2500 de vida, el Capitán del Vado 30 000 y el capitán del reino 15 000.
  - La guarnición del reino sale de espejos de los puestos de los Huecos (`garrison_id`), sin tocar
    la escena.
  - TELEGRAPH para todo golpe fuerte de un PNJ.
  - Opción nueva `--no-npcs`.
- **F6a**:
  - `--max-realm-diff` solo cuenta personas. Se rechaza entrar en el reino r si
    `personas[r] + 1 − min(otros) > N`.
  - Los falsos de relleno se retiran uno por cada persona que entra en el bando largo.
  - Opción nueva `--run-at=<tick>:<orden>`.
  - Clase de muerte `gate` en el resumen de batalla.
  - «Defender la pasarela» se queda en defender el círculo (GUE-45).
- **Versiones del protocolo repartidas**: 4 el fuerte, 5 el chat y los grupos, 6 las habilidades y 7
  la fase 5. Si cambia el orden de fusión, se renumeran.
- **Diseños de la fase 4 y la 5**: las decisiones pendientes que bloqueaban se tomaron con la
  recomendación del backlog y están en «Decisiones tomadas» marcadas «provisional, tomada de noche».
  - Habilidades: solo reutilización (maná en los bastones), rayo de cámara canónico con bit de
    hombro, derribado solo en PvP y HUD de acción.
  - Fase 5: Go + PostgreSQL, guardado con punto de control de 60 s más eventos críticos, un solo
    mundo con `world_id`, DTLS si cabe, un reino por cuenta, ignorar por cuenta y chat 30 días.
  - Progresión: un pueblo humano por reino, bolsa por ranuras, monedas por personaje, méritos y
    puntos de reino separados, y XP por contribución.

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

## Decisiones abiertas para el usuario

- **Carga del fuerte**: con 32 contra 32 el p99 del tick es 19,1 ms, frente al criterio de 8 ms.
  Domina `simulate()`, con 77 µs por personaje. El primer límite de batalla queda en 32 contra 32.
  Para subirlo: `simulate()` en C++ (GDExtension) o un presupuesto por zona.
- **Combate**: siguen abiertos `MAX_REWIND_TICKS` para un RTT de 200 ms y el equilibrio P1 de
  `combate.md` §12.
- **Fase 5**:
  - el modelo de negocio (PRG-41);
  - el proveedor y la región del VPS;
  - el dominio;
  - los textos legales y la revisión RGPD (edad mínima 16 provisional, retenciones);
  - la subida de copias a S3.
- **Arte**: lo visual de las fases 3 y 4 es provisional. Faltan:
  - las fuentes OFL;
  - las plantillas de exportación 4.7.2;
  - los modelos de Huecos, guardias y Capitán (ART-15/16/17);
  - el arco (ART-41).
- **Criterios que necesitan personas**: MUN-10 (60–90 s para limpiar los Huecos con 2–3 personas) y
  MUN-11 (60–120 s para el Capitán con 3–5).
