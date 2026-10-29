# Informe de la sesión nocturna

Sesión sin supervisión del 28 al 29 de octubre de 2026. Este archivo se actualiza en cada hito
y está siempre en la rama más reciente.

## Estado

| Trabajo | Rama | Estado |
|---|---|---|
| Backlog (`docs/backlog.md`) | `main` | Hecho y subido |
| Fase 2: red | `fase2-red` | Implementada (594 pruebas en verde, CI de GitHub en verde); revisión adversarial en marcha |

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

### Medidas de §19 (carril B, `tools/load_test.gd --matrix`, máquina de 4 núcleos compartida)

| Escenario | Jugadores | Tick p50 / p99 / máx (ms) | KB/s por cliente | Sustituidas |
|---|---|---|---|---|
| 64 falsos agrupados + 2 bots | 66 | 4,8 / 8,0 / 12,1 | 35,3 | 0,09 % |
| 62 falsos + 2 bots | 64 | 4,8 / 8,7 / 14,1 | | |
| 54 falsos + 10 bots | 64 | 5,7 / 9,6 / 23,4 | | |
| 64 falsos agrupados + 10 bots | 74 | 6,5 / 12,1 / 45,2 | 35,3 | 0,14 % |
| 64 falsos agrupados + 50 bots | 114 | 15,3 / 26,9 / 49,6 | 34,3 | 0,16 % |
| 64 dispersos + 10 bots | 74 | 6,7 / 11,2 / 19,2 | | |
| Altas y bajas a 1/s + 10 bots | 74 | 6,4 / 11,0 / 41,6 | | |

- `simulate()` por personaje: **44–50 µs** (la sección de simulación entera, ~60 µs por personaje).
- Snapshot lleno (57 registros): 1191 B, 250–525 µs de construcción.
- Subida: 2,2–2,7 KB/s por cliente.
- **Criterio de la fase 2**: bajada (≤ 37 KB/s) y sustituidas (< 1 %) se cumplen; **p99 del tick
  < 8 ms con 64 jugadores agrupados NO se cumple** en esta máquina (8,7–9,6 ms). Los cuellos son
  `simulate()` en GDScript (por encima de los 25 µs de la palanca 6 de red.md §14) y
  `SnapshotBuilder` con muchos clientes reales. Primer límite orientativo de jugadores por batalla:
  unos 60 en un servidor de esta clase sin optimizar. Está anotado en red.md §14.

## Pendiente de probar mañana con ventana

(Se completa al terminar la fase 2.)

## Decisiones tomadas fuera del contrato

- Paquete A: `BotBrain._init(rng_seed, …)` en vez de `seed` (para no tapar la función global);
  `NetZones.allowed_realms` devuelve vacío (todos los reinos) porque `Zones` no registra reinos por
  zona; `NetZones` añade `realm_name()` y `find_spawn_point()`; los `decode` rechazan UTF-8
  inválido sin registrar errores del motor.
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
