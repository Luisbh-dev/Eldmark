# Informe de la sesión nocturna

Sesión sin supervisión del 28 al 29 de octubre de 2026. Este archivo se actualiza en cada hito
y está siempre en la rama más reciente.

## Estado

| Trabajo | Rama | Estado |
|---|---|---|
| Backlog (`docs/backlog.md`) | `main` | Hecho y subido |
| Fase 2: red | `fase2-red` | En curso: paquetes A, B, C y D integrados (407 pruebas en verde); E (cliente en red) en marcha |

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
| E, F | Cliente en red, integración, procesos, bots y carga | Pendiente | |

Incidencia: el contenedor se reinició a mitad del paquete D; su trabajo a medias se recuperó de su
worktree y se terminó.

Primera medida orientativa (C2, Linux): Vado Gris con 64 jugadores falsos, tick p50 4,4 ms, p99
7,3 ms, máx. 11,7 ms; unos 100 µs por personaje (simulación + cerebro del bot). Se repetirá con
bots reales al final de la fase.

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
- Paquete C2: el `sim_hash` lo calcula `ZoneServer.start()`; un salto de más de 1,5 m en un tick
  se registra como aviso (no error) y en el contador `physics_errors` del informe.
