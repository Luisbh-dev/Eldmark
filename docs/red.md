# Eldmark · Fase 2: diseño de red

Diseño definitivo del paso 2 de la [hoja de ruta](vision.md#hoja-de-ruta): servidor dedicado
autoritativo, varios jugadores en una zona, predicción y reconciliación del jugador local,
interpolación de los demás y elección de reino.

Parte de la propuesta «simple primero», la que eligieron los tres jueces, y le injerta las
mejores ideas de «escala primero» y «seguridad primero». Corrige todos los errores técnicos que
encontraron los jueces; el resumen está en el [anexo](#anexo-correcciones-respecto-a-las-propuestas).

Se apoya en el código de la fase 1:

- `PlayerInput`: 12 B cuantizados.
- `PlayerState`: 35 B (69 B con el estado de combate de la fase 3, [combate.md 3.1](combate.md#31-combatstate-en-playerstate-entra-en-encode), y 111 B con las habilidades del protocolo 6, [habilidades.md 3.1](habilidades.md#31-combatstate-v5); las cifras de este documento son las del protocolo 6 donde se marcan «v6» y, si no, las de la fase 3).
- `PlayerCharacter.simulate()`: determinista, un tick de física por llamada.
- `LocalPlayerController`.

Las zonas, sus escenas y las opciones `--zone` y `--realm` las define `scripts/shared/zones.gd`,
que añade otro flujo de trabajo. Aquí se usan, no se redefinen (ver [1.5](#15-zonas-y-reinos-contacto-con-zonesgd)).

---

## 0. Decisiones clave

- **Transporte.** Se usan `ENetMultiplayerPeer` y `SceneMultiplayer`, pero solo para tres cosas:
  - conectar;
  - autenticar (`auth_callback`, `send_auth`, `complete_auth`);
  - mover paquetes binarios (`send_bytes` y la señal `peer_packet`).

  No se usan RPC, `MultiplayerSynchronizer` ni `MultiplayerSpawner`: predecir, interpolar y
  rebobinar exigen un tick explícito en cada dato y control exacto de los bytes. Todo pasa por
  `NetTransport`, una capa fina. Si algún día se mide un sobrecoste, permite cambiar a
  `ENetConnection` directo sin tocar nada más.
- **Todo en ticks enteros a 60 Hz.** Simulación, protocolo, colas y simulador de red se miden
  en ticks.
  - Nada de `scripts/shared/` lee el reloj (lo exige `test_architecture.gd`), y las pruebas son
    reproducibles con una semilla.
  - Solo usan tiempo real el dibujo de los remotos (fracción de interpolación de física) y las
    métricas del servidor.
- **Orden fijo en cada tick.** `multiplayer_poll = false`. Cada proceso hace `poll()` al empezar
  su tick de física y `flush()` al terminarlo: recibir → simular → enviar.
- **La entrada del tick T se aplica en el tick T del servidor**, una sola por jugador y tick.
  - El cliente simula por delante lo justo para que sus entradas lleguen a tiempo: lo mide el
    servidor y lo corrige el cliente.
  - A los demás jugadores los dibuja entre 70 y 200 ms en el pasado.
- **Determinismo bit a bit** con el mismo binario y el mismo SO:
  - el yaw se redondea a f32;
  - todo estado que impone el servidor pasa por `encode`/`decode`;
  - la reconciliación compara `encode()` exacto.

  Entre plataformas distintas la reconciliación sigue funcionando, porque vuelve a simular ante
  cualquier diferencia.
- **Snapshots a 30 Hz**, escalonados por cliente, de 1200 B como mucho, con acumulador de
  prioridad. Si no cabe todo, entra primero lo que más tiempo lleva sin enviarse.
- **Sin colisión entre personajes.** La máscara de `PlayerCharacter` ya es solo el mundo, así
  que la simulación de cada jugador no depende de los demás.
- **Seguridad barata desde ya:** ventana de entradas, máscara de botones, limitador por peer,
  tope de conexiones por IP y reino validado. Los billetes de traspaso y DTLS quedan para las
  fases 5 y 6, con su hueco ya reservado en el protocolo.

---

## 1. Modelo de procesos y desarrollo local

### 1.1 Un proceso por zona y canal

- **Un proceso por zona y canal.** Cada proceso de servidor sirve una zona y un canal (una
  copia de la zona) en un puerto UDP. Eldrun es un único proceso, sin canales (`mundo.md`).
- **El cliente solo tiene cargada su zona.** En la fase 2 hay una zona por sesión. El traspaso
  de la fase 6 repite la misma entrada: HELLO con billete → WELCOME → carga → CLIENT_READY. Por
  eso la aparición espera a CLIENT_READY y no a la autenticación.
- **Un solo ejecutable.** Cliente y servidor son el mismo proyecto; el servidor arranca con
  `--headless -- --server`.
- **Puertos.** Por defecto, 24600. Si en un equipo corren varios procesos de zona, cada uno usa
  su propio `--port`. El directorio de zonas y canales (qué host y puerto sirve cada uno) llega
  en la fase 8.

### 1.2 Modos de arranque

`boot.gd` lee los argumentos de usuario (los que van tras `--`). Prioridad: `--server` >
`--bots` > `--connect`/`--local`/`--bot` > sandbox. `boot.gd` solo decide entre servidor y cliente y
**no nombra ninguna clase de `scripts/client/`** (la escena principal la ejecuta también el
servidor dedicado, y cada referencia de clase arrastraría el script y, en cadena, la interfaz, los
ajustes y el audio): para el cliente instancia por su ruta `scenes/client/client_launcher.tscn`
(`ClientLauncher`), que aplica el resto de la prioridad y cambia a la escena del modo. Lo comprueba
`test_architecture` arrancando un proceso con `--server` y mirando qué scripts del cliente ha cargado
(ninguno).

| Argumentos | Modo | Escena |
|---|---|---|
| ninguno, `--demo`, `--shots=`, `--quit-after-demo` | Sandbox sin red de la fase 1, sin cambios | `scenes/client/client_main.tscn` |
| `--server [--port=24600] [--zone=<id>] [--max-players=N] [--max-per-ip=4] [--idle-quit=<s>] [--fake-players=N [--fake-layout=cluster\|spread] [--fake-churn=<ticks>]] [--debug-commands] [--dev-lock [--dev-lock-path=<ruta>]] [--stop-file=<ruta>]` | Servidor dedicado (siempre con `--headless`) | `scenes/server/server_main.tscn` |
| `--connect=<host>[:<puerto>] [--realm=<reino>] [--name=<nombre>]` | Cliente en red | `scenes/client/online_main.tscn` |
| `--local [--realm=…] [--name=…]` | Cliente contra un servidor local, que se lanza si no hay ninguno | `scenes/client/online_main.tscn` |
| `--bot --connect=… [--bot-seed=N] [--bot-brain=wander\|combat] [--bot-cheat=<modo>]` | Un cliente que predice, sin cámara ni HUD, guiado por `BotBrain` (pasea, o pelea con el cerebro de combate); muerto, pide reaparecer en cuanto puede | `scenes/client/online_main.tscn` |
| `--bots=N --connect=… [--bot-seed=N] [--bot-brain=combat] [--quit-at-server-tick=N]` | Enjambre de N clientes ligeros que no simulan, para pruebas de carga (con `combat`, pelean; con `--quit-at-server-tick`, se van cuando alguno ve ese tick del servidor) | `scenes/client/bot_swarm.tscn` |
| Comunes | `--net-sim=rtt=120,jitter=20,loss=5,dup=0,seed=1`, `--quit-after-ticks=N`, `--report=<ruta.json>`, `--state-log=<ruta.csv>` | |

- **`--zone` y `--realm`** se leen con las utilidades de `zones.gd`, a través de `NetZones`.
- **`--max-players`** es el aforo del proceso (los falsos cuentan). Sin él, el de la zona
  (`NetZones.max_players`: 40 en el Vado Gris, el límite de jugadores por batalla con el kit de la fase 4 de la
  sección 14) o, si la zona no tiene uno propio, 64 (revisión de H5, habilidades.md §11.10).
- **Elección de reino.** Si un modo en red arranca sin `--realm`, `OnlineMain` muestra
  `RealmSelect`: tres botones (Vardheim, Solmarch, Askarra), el campo de dirección y «Entrar»,
  con los textos en español.
- **Nombre.** Sin `--name`, el cliente usa `NameRules.default_name(semilla)`: «Jugador» más cuatro
  letras (p. ej. `Jugadorabcd`), que es un nombre válido (SOC-01; el antiguo `Jugador-NNNN` ya no lo es).

### 1.3 Ajustes del servidor headless

- **`Engine.max_fps = 120`.** En headless, el bucle principal duerme
  `low_processor_usage_mode_sleep_usec` (6900 µs por defecto) entre iteraciones, y la hora de
  cada tick llegaba a variar unos 10 ms. Medido por los jueces en 4.7.2:

  | Ajuste | Dispersión de la hora del tick | Iteraciones por segundo |
  |---|---|---|
  | Por defecto | ~10 ms | — |
  | `max_fps = 120` | ~0,5 ms | ~120 |
  | `low_processor_usage_mode_sleep_usec = 1000` | 1,9 ms | ~10 000 |

  Los bots headless usan el mismo ajuste.
- **`get_tree().physics_interpolation = false`**, porque el servidor no dibuja.
- **`get_tree().multiplayer_poll = false`**, porque `NetTransport.poll()` se llama a mano.
- **Sin parte visual.** Al crear cada `PlayerCharacter` en el servidor se libera su nodo
  `Visual` (mallas y `AnimationTree`). Contrato con el flujo de arte: todo lo que sea solo
  visual cuelga de `Visual`.
- **Terrain3D:** colisión completa y `set_physics_process(false)`, como fija
  `tests/test_terrain3d_headless.gd`. El cliente también usa colisión completa, por el
  determinismo (ver [riesgos](#19-riesgos-abiertos)).
- **Física.** `project.godot` fija `physics/common/physics_ticks_per_second=60` de forma
  explícita y mantiene `physics_jitter_fix=0`. Nunca se cambian en ejecución
  `Engine.time_scale` ni los ticks por segundo: cambian el delta que usa `move_and_slide()` y
  rompen el determinismo.
- **Registro:** con la opción `--log-file <ruta>` de Godot.
- **Cómo se para el servidor (hallazgo S5).** Hay cierre ordenado (NOTICE de cierre a los
  clientes, `ZoneServer.stop`, informe de `--report` y borrado del bloqueo de `--dev-lock`) con
  `--quit-after-ticks`, `--idle-quit` y `--stop-file=<ruta>`: el servidor mira cada segundo si ese
  archivo existe (por ejemplo, un `ExecStop` de systemd que lo cree con `touch`), hace el mismo
  cierre y lo borra; uno que ya existiera al arrancar es de una parada anterior y se borra.
  **`SIGTERM` y `SIGINT` (Ctrl+C, `docker stop`, `kill`) no cierran de forma ordenada**: GDScript
  no puede atraparlas y Godot termina el proceso al instante (código de salida 143 o 130), sin
  NOTICE, sin informe final y con el bloqueo de `--dev-lock` sin borrar. Para limitar el daño, con
  `--report` el informe se reescribe cada 10 s (`"closed": false`) además de al cerrar
  (`"closed": true`), igual que el registro de estados se vuelca cada segundo; y quien lee el
  bloqueo (`LocalServerLauncher`) no debe fiarse de que su pid siga siendo el servidor.

### 1.4 Flujo de trabajo local

```powershell
$godot = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64_console.exe"

# Servidor y dos clientes, cada uno en su terminal
& $godot --headless --path . -- --server --debug-commands
& $godot --path . -- --connect=127.0.0.1 --realm=vardheim --name=Ana
& $godot --path . -- --connect=127.0.0.1 --realm=solmarch --name=Bruno --net-sim=rtt=120,jitter=20,loss=3

# Todo en uno: lanza (o reutiliza) un servidor local
& $godot --path . -- --local

# Bots
& $godot --headless --path . -- --bot --connect=127.0.0.1 --bot-seed=3
& $godot --headless --path . -- --bots=32 --connect=127.0.0.1

# Pruebas de red
& $godot --headless --path . -s res://tests/run_tests.gd -- --filter=net
```

**`--local` (`LocalServerLauncher`):**

1. Lee `user://dev_server.json` (`{pid, port}`), que escribe un servidor lanzado con
   `--dev-lock` (o el archivo de `--dev-lock-path=<ruta>`). Si
   `LocalServerLauncher.is_process_alive(pid)`, se conecta a ese servidor.
2. Si no, lanza el servidor y se conecta con un timeout corto de ENet (1 s), reintentando
   durante 10 s. En una exportación (`OS.has_feature("template")`) se omite `--path`:
   ```
   OS.create_process(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"),
       "--log-file", <user://logs/dev_server.log globalizado>, "--", "--server", "--port=24600",
       "--idle-quit=30", "--dev-lock"])
   ```
3. El servidor se cierra solo tras 30 s sin jugadores y borra el archivo de bloqueo.
   - Varias ventanas lanzadas con `--local` comparten el mismo servidor.
   - Si el cliente se cae, el servidor no se queda huérfano.
   - El cliente nunca mata el servidor.

No se detecta un servidor intentando `bind` en el puerto: en Windows, la reutilización de
direcciones UDP lo hace poco fiable.

**Bloqueo huérfano.** El servidor solo borra su bloqueo en un cierre ordenado (`--quit-after-ticks`,
`--idle-quit`, cerrar la ventana). Con `SIGTERM` (systemd, `docker stop`) o `SIGINT` (Ctrl+C) el
proceso muere de golpe, sin avisar a los clientes, sin `--report` y sin borrar el bloqueo: GDScript no
puede atrapar señales POSIX. Si el sistema reutiliza ese pid, el bloqueo apuntaría a un proceso vivo
que no es el servidor. Por eso `get_running_port` exige, donde se puede (Linux), que
`/proc/<pid>/cmdline` lleve `--server` y `--dev-lock` (`LocalServerLauncher.is_dev_server_process`);
en Windows no se puede comprobar y vale cualquier proceso vivo con ese pid.

`OS.is_process_running(pid)` solo conoce los procesos que lanzó el propio proceso (en Windows mira
su tabla de procesos hijos, `process_map`; en Linux y macOS, con el pid de otra ventana registra además
un error del motor): una segunda ventana `--local` nunca lanzó el servidor de la primera y obtendría
`false`. `LocalServerLauncher.is_process_alive` usa `/proc/<pid>/stat` (o `kill -0`) en Linux y macOS y,
en Windows, `OS.is_process_running` para los hijos propios y `tasklist /FI "PID eq <pid>" /FO CSV /NH`
para el resto (se lee la segunda columna de la fila, porque el aviso de «sin coincidencias» sale en el
idioma del sistema). Cada intento de conexión fallido es una
sesión nueva en `OnlineMain` (`NetClient.connect_timeout_ms` fija el tiempo de espera corto).

**Desde el editor:** *Depurar ▸ Personalizar instancias de ejecución*.

- Instancia 1: `--headless -- --server --debug-commands`.
- Instancias 2 y 3: `-- --connect=127.0.0.1 --realm=vardheim` y `--realm=solmarch`.

### 1.5 Zonas y reinos: contacto con `zones.gd`

**`NetZones`** (`scripts/shared/net/net_zones.gd`) es el único archivo de red que llama a
`zones.gd`. De ese registro solo necesita:

- el id de la zona por defecto;
- la ruta de escena de cada zona;
- los reinos admitidos en cada zona;
- leer `--zone` y `--realm`;
- los puntos de aparición de una zona (`get_spawn_points`, `find_spawn_point`) y el grupo que los
  marca (`spawn_group`).

`test_architecture` vigila esta frontera: en `scripts/server/`, `scripts/client/` y
`scripts/shared/net/` solo `net_zones.gd` nombra `Zones.`, con tres excepciones: `server_main.gd`
(la lista de zonas del aviso de zona desconocida y los reinos con campamento de los jugadores
falsos, ver la sección 19), `client_main.gd` (el sandbox sin red de la fase 1) y, fuera de esas
carpetas, `boot.gd` y `scripts/world/zone_root.gd`.

Los reinos admitidos por zona y la correspondencia código de red <-> id de reino salen de
`RealmCatalog` (`scripts/shared/war/realm_catalog.gd`, GUE-02); `NetZones` solo traduce. Si una zona
no figura en el catálogo, `NetZones` admite todos los reinos. Si al implementar todavía no existe, `NetZones` devuelve `test_world`. Ese
cambio se hace solo en este archivo.

**Formato en la red:**

- **Reino:** los códigos de `NetProtocol.Realm` (0 ninguno, 1 Vardheim, 2 Solmarch, 3 Askarra),
  independientes de cómo los represente `zones.gd`. `NetZones` traduce en los dos sentidos.
- **Zona:** viaja como el id de texto de `zones.gd`, en ASCII y con 32 B como mucho.

**Puntos de aparición:**

1. Si la escena de zona expone puntos de aparición por reino (a través de `zones.gd` o del
   flujo de arte), se usan esos.
2. Si no, se usan los `Marker3D` del grupo `spawn_points` con el metadato `realm` (nombre del
   reino, p. ej. `"vardheim"`).
3. Si ninguno es del reino, se usa cualquiera. Si no hay ninguno, el origen, con un aviso.

**Coordenadas:** las escenas de zona van centradas en el origen. La cuantización de posición
cubre ±5,24 km, así que caben los 5 × 5 km de terreno de Eldrun.

---

## 2. Transporte y canales

**Creación del peer:**

- **Servidor:** `ENetMultiplayerPeer.create_server(port, max_players + 4, NetProtocol.CUSTOM_CHANNELS)`.
  Las 4 plazas de más permiten contestar «servidor lleno» con un REJECT, en vez de que ENet
  rechace la conexión sin decir nada.
- **Cliente:** `create_client(host, port, NetProtocol.CUSTOM_CHANNELS)`.
  - `CUSTOM_CHANNELS = 3`. `ENetMultiplayerPeer` reserva sus canales de sistema, y el canal de
    transferencia N va al canal ENet `SYSCH_MAX + N − 1`.
  - Los dos lados deben usar el mismo valor, que va ligado a `PROTOCOL_VERSION`.

**`SceneMultiplayer`:** uno propio por cada `NetTransport`.

- Configuración: `server_relay = false`, `allow_object_decoding = false`, `auth_callback` en los
  dos lados y `auth_timeout = 5.0` (10 s desde la subida de protocolo de la fase 5, plataforma.md
  §5.4: cuenta desde la conexión y deja sitio a la reclamación del billete).
- Se registra con `get_tree().set_multiplayer(mp, transport.get_path())`. Así caben varias
  instancias en un mismo proceso (pruebas y enjambre de bots).
- **Filtro de paquetes en el servidor (`GuardedEnetPeer`, hallazgo S1).** `SceneMultiplayer`
  procesa dentro de `poll()` todo lo que llega, y solo entrega a la aplicación los paquetes RAW
  de los peers admitidos. Un cliente ENet sin `SceneMultiplayer` que mandase otra cosa, antes del
  HELLO (`[3, 1]`, RPC, SIMPLIFY_PATH...) o después (RPC, SPAWN, órdenes SYS...), hacía que el
  motor registrase un error por paquete con su traza de GDScript (2000 paquetes: 742 KB de
  registro y un tick de 28–37 ms), que esos paquetes no pasasen por los limitadores ni sumaran
  avisos, y antes del HELLO solo los cortaba el `auth_timeout` de 5 s (el atacante reconecta).
  Por eso el `NetTransport` del servidor entrega a `SceneMultiplayer` un
  `MultiplayerPeerExtension` (`scripts/shared/net/guarded_enet_peer.gd`) que envuelve al
  `ENetMultiplayerPeer` y filtra antes de que el motor vea nada:
  - a un peer sin admitir, solo mensajes de autenticación (`SYS` + `AUTH`: byte 0 & 7 = 7 y
    byte 1 = 0) de como mucho 1200 B, 3 con contenido (el HELLO) y una confirmación de 2 B;
  - a un peer admitido (los dos lados han confirmado: el envoltorio ve pasar la del otro lado y
    la propia), solo paquetes RAW (byte 0 & 7 = 3);
  - lo demás se descarta, sin error del motor, y al final de `poll()` se emite
    `NetTransport.packets_discarded(peer_id, count)`. `ZoneServer` suma un aviso por paquete
    (motivo «paquete ajeno al protocolo»; con 50 en 600 ticks, NOTICE de expulsión y corte);
  - un peer al que el servidor ya está cortando (`disconnect_after_flush`) se silencia: lo que
    siga mandando se descarta sin contarlo ni procesarlo;
  - como mucho se procesan 4096 paquetes por `poll()` (lo demás se queda en la cola de ENet): la
    inundación no puede alargar el tick sin límite. Medido: con 2000 paquetes en un tick, el
    tick más largo pasa de 28–37 ms a ~1 ms.
  - **Atajo para el camino caliente.** Los RAW de los peers que `SceneMultiplayer` ya ha admitido
    de verdad (`NetTransport._mp_connected`) se entregan directamente a la aplicación, sin pasar
    por la cola del motor. Los de un peer que se admite en ese mismo `poll()` van por la cola,
    detrás de su confirmación, para no perder el orden. Medido con 64 clientes y 48 000 paquetes
    (cinco repeticiones alternadas): 9,4 µs por paquete sin filtro, 9,9 µs con filtro y atajo
    (+6 %, el nivel del ruido) y 11,3 µs con filtro y sin atajo (+25 %).
  - **Acoplamiento.** El filtro conoce el formato interno de `SceneMultiplayer` (RAW = 3,
    SYS = 7, AUTH = 0 y las confirmaciones de 2 B). Si una versión del motor lo cambiara, el
    apretón de manos dejaría de completarse y `tests/test_net_sim.gd` lo detectaría enseguida. El
    cliente no lleva filtro.

**Timeouts:**

- Tras conectar: `get_peer(id).set_timeout(32, 3000, 8000)`, de modo que una desconexión se
  detecta en 3–8 s.
- Mientras el cliente conecta: `set_timeout(32, connect_timeout_ms, connect_timeout_ms)`, para que
  `--local` detecte en ~1,5 s que no hay servidor. El mínimo y el máximo son iguales a propósito:
  ENet solo comprueba el plazo cuando vence una retransmisión del CONNECT (a los 0,5, 1,5, 3,5 y
  7,5 s), y con el máximo al doble `connection_failed` llegaba a los 3,5 s con 1000 ms y a los
  7,5 s con 3000 ms (hallazgo S7). Ahora llega a los 1,5 s y a los 3,5 s.

**Compresión:** sin compresión de ENet al principio, por CPU. Más adelante se prueba
`COMPRESS_RANGE_CODER`, midiendo.

| Canal | Modo de transferencia | Sentido | Contenido |
|---|---|---|---|
| sistema | interno de `SceneMultiplayer`, fiable | ambos | Autenticación: HELLO, WELCOME, REJECT |
| 1 `CH_INPUT` | `TRANSFER_MODE_UNRELIABLE` (sin secuencia) | C→S | INPUT_BATCH. Sin secuencia a propósito: un paquete atrasado puede traer la única copia de una entrada |
| 2 `CH_SNAPSHOT` | `TRANSFER_MODE_UNRELIABLE_ORDERED` (secuenciado) | S→C | SNAPSHOT. ENet descarta los atrasados |
| 3 `CH_RELIABLE` | `TRANSFER_MODE_RELIABLE` | ambos | CLIENT_READY, CLIENT_LEAVE, DEBUG_COMMAND, RESPAWN_REQUEST, ENTITY_SPAWN, ENTITY_DESPAWN, ENTITY_EVENT y NOTICE; desde la fase 4, también UNSTUCK_REQUEST, OBJECT_STATE y SCOREBOARD, y desde el protocolo 5, CHAT_SEND, CHAT_MESSAGE y los PARTY_* |

Reglas:

- **Bloqueos.** Un mensaje fiable perdido solo bloquea el canal 3, nunca los snapshots ni las
  entradas.
- **Orden entre canales.** Los canales 2 y 3 no están ordenados entre sí. Para que no importe:
  - el cliente ignora los registros de un `net_id` que todavía no conoce;
  - cada alta lleva su `spawn_tick` y se ignoran los registros de antes de ese tick o de después
    del `despawn_tick`;
  - un `net_id` liberado no se reutiliza en 10 s.
- **Tamaño.** Ningún paquete pasa de **1200 B**. Si ENet fragmenta un paquete no fiable, perder
  un fragmento tira el paquete entero. El snapshot lo garantiza su constructor
  ([9.3](#93-construcción-del-snapshot)) y los demás mensajes son pequeños por formato.
- **Nada antes de `peer_connected`.** No se envía nada con `send_bytes` a un peer hasta que ha
  llegado `peer_connected` para él en ese lado (en el cliente, el peer 1). Enviar justo después
  de `complete_auth()` da `ERR_BUG` («Condition !connected_peers.has(p_to)», comprobado por los
  jueces), porque el aviso de autenticación completada llega en un paquete posterior.
- **Simulador de red.** `NetTransport` aplica `NetSim` ([13](#13-herramientas-de-depuración))
  a la salida y a la entrada. A los mensajes de autenticación solo les añade retardo. Así el RTT
  medido en ticks incluye la latencia simulada.

---

## 3. Conexión

```
Cliente                                         Servidor (tick S)
  │ conexión ENet                                  │
  │ peer_authenticating(1)          peer_authenticating(id)
  │ HELLO (send_auth) ────────────────────────────▶│ ServerAuth.validate()
  │◀────────────────────────────── WELCOME (send_auth) + complete_auth(id)
  │ complete_auth(1)                               │
  │ peer_connected(1)                peer_connected(id)
  │ carga la zona (hilo, «Cargando…»)              │
  │ CLIENT_READY (canal 3) ───────────────────────▶│ alta al final del tick S
  │◀──────── ENTITY_SPAWN propio (S, estado tras S) + SPAWN de todo lo relevante
  │ avance neutro S+1 … P0−1, entradas reales desde P0
```

1. **HELLO.** El cliente conecta. Al recibir `peer_authenticating(1)` envía HELLO con
   `send_auth(1, …)` y apunta `hello_local_tick`.
2. **Validación.** El `auth_callback(id, bytes)` del servidor decodifica HELLO y pasa
   `ServerAuth`, que comprueba:
   - magic y versión;
   - `sim_hash`;
   - que el reino es válido y está admitido en la zona;
   - que el nombre cabe en el HELLO (24 caracteres y 48 B), cumple `NameRules` (3 a 16 letras,
     sin espacios ni dígitos, mayúscula inicial, sin reservados) y no lo lleva ya un jugador conectado
     en la zona (SOC-01; REJECT `NAME`);
   - que hay sitio (con `--max-realm-diff`, los falsos de relleno no ocupan plazas de personas: si el servidor
     solo está lleno por ellos, uno cede la suya al aceptar el HELLO; GUE-43, docs/fuerte.md, sección 7);
   - que no hay más de 4 conexiones desde la misma IP (salvo loopback). Este tope se aplica ya al
     conectar (`peer_authenticating`), no solo al llegar el HELLO (ver la nota de debajo);
   - el `AuthProvider`. En la fase 2 es `DevAuthProvider`, que acepta el reino y el nombre que
     declara el cliente.

   Según el resultado:
   - **Bien:** `send_auth(id, WELCOME)` y `complete_auth(id)`. El peer pasa a `LOADING`.
   - **Error:** `send_auth(id, REJECT)`, `flush()` y `ENetPacketPeer.peer_disconnect_later()`,
     que deja salir antes lo encolado. Como red de seguridad, si el peer sigue ahí a los 60
     ticks, `disconnect_peer(id)` forzado.
3. **Respuesta en el cliente.** El `auth_callback(1, bytes)` del cliente:
   - **REJECT:** muestra el texto y cierra.
   - **WELCOME:**
     1. Calcula `rtt_hello = local_tick − hello_local_tick`.
     2. Comprueba que `tick_rate == Engine.physics_ticks_per_second`; si no, se desconecta con
        un error.
     3. Llama a `complete_auth(1)`.
     4. Al llegar `peer_connected(1)`, carga la zona `WELCOME.zone_id` (con `NetZones` y
        `ResourceLoader.load_threaded_request`, tras la pantalla «Cargando…»).
     5. Al terminar la carga, envía CLIENT_READY y apunta `ready_local_tick`.

   La carga no compite con `auth_timeout`: READY tiene su propio límite de 60 s.
4. **Alta del jugador.** El READY llega en el poll del tick S y queda pendiente. Al final del
   tick S, después de simular ([8.1](#81-orden-del-tick)), el servidor crea el
   `PlayerCharacter` en un punto de aparición de su reino.
   - **Su estado es «el estado tras el tick S»:** posición y yaw del punto, velocidad 0,
     `grounded` según el punto y `last_input_tick = S`, redondeado con
     `PlayerState.decode(state.encode())`.
   - **Su `InputQueue`** empieza con `last_consumed = S` y
     `last_applied = NetProtocol.neutral_input(S, yaw)`.
   - **Mensajes:**
     - ENTITY_SPAWN propio (bit «tuyo», `spawn_tick = S`);
     - los SPAWN de todo lo relevante para el recién llegado;
     - el SPAWN del recién llegado a quien lo tenga por relevante.
5. **Arranque de la predicción.** Con el SPAWN propio, el cliente calcula:
   - `rtt_ticks = min(rtt_hello, local_tick − ready_local_tick)`;
   - `P0 = S + rtt_ticks + target_margin + 1`.

   Y arranca la predicción ([6.3](#63-arranque)).

**Conexiones ociosas (hallazgo S2).** Las plazas de ENet (`max_players + 4`) son limitadas, y una
conexión que nunca manda el HELLO ocupaba una hasta los 5 s de `auth_timeout` (y se reabre en un
RTT): una sola IP con unos 68 sockets dejaba la zona sin acceso, y los clientes legítimos no
recibían ni un REJECT porque ENet descarta su conexión en silencio. Por eso:

- **Tope por IP al conectar.** `ZoneServer._on_peer_authenticating` cuenta las conexiones de la
  misma IP (las que se autentican también cuentan) y, si ya hay 4 y no es loopback, contesta
  `REJECT TOO_MANY_CONNECTIONS` y corta, sin esperar al HELLO. Las IPv6 se cuentan por prefijo
  /64 (`ServerAuth.address_group`): quien tiene IPv6 tiene un /64 entero, y cada dirección suya
  sería otra IP.
- **Plazo propio para el HELLO.** Un peer que sigue en `AUTHENTICATING` pasados 90 ticks (1,5 s;
  `ZoneServer.HELLO_TIMEOUT_TICKS`, comprobado cada 10 ticks) se corta con
  `disconnect_after_flush` y se cuenta en `rejects` como «sin HELLO a tiempo». Los 5 s de
  `SceneMultiplayer` quedan como red de seguridad.
- **Límite que queda.** Con varias IP distintas (una botnet) sigue siendo posible llenar las
  plazas; eso se resuelve fuera del proceso (cortafuegos, DTLS en las fases 5 y 6).

**`sim_hash`.** Rechaza a los clientes cuya simulación difiere de la del servidor, que
predecirían mal todo el tiempo.

- Es el SHA-256 (`HashingContext`) de `var_to_bytes()` de un array con:
  - `PROTOCOL_VERSION`;
  - `physics_ticks_per_second`;
  - el nombre del motor de física;
  - los `@export` de `PlayerCharacter`, ordenados por nombre;
  - los valores `floor_*` que fija `_ready()`;
  - el radio, la altura y la posición de la cápsula.
- Se toman los 4 primeros bytes como u32.
- Se calcula sobre una instancia que ya está en el árbol, después de `_ready()`.

---

## 4. Ticks y reloj

### 4.1 Tick del servidor y regla de aplicación

- **`server_tick`** empieza en 0 y sube 1 al empezar cada tick simulado. El primero es el 1; el
  0 significa «ninguno». El u32 no da la vuelta en la práctica (828 días). Para que ese rango sea
  real, los ticks se guardan siempre en enteros de 64 bits (`int`, `PackedInt64Array`): un
  `PackedInt32Array` o un `Vector2i` con signo se desbordarían a los 414 días (2^31 ticks) y
  dejarían inservibles el historial de rebobinado, la ventana de avisos y el reloj de
  interpolación (hallazgo N5; `StateHistory.Track.ticks`, `ServerPeer._strike_ticks` e
  `InterpolationClock` usan ya 64 bits).
- **Regla:** la entrada con `tick = T` se aplica exactamente en el tick T del servidor. El
  snapshot del tick S lleva el estado tras simular S (`last_input_tick == S`).
- **Antelación de cada entrada.** El servidor la mide al recibir la *primera copia aceptada*:
  `lead = input.tick − (server_tick + 1)`.
  - 0 significa justo a tiempo; negativo, tarde (se descarta pero se cuenta).
  - Las copias redundantes no cuentan: sesgarían la medida a la baja.
- **Realimentación en el snapshot:**
  - `input_margin`: la antelación mínima desde el snapshot anterior a ese cliente, limitada a
    [−127, 127]; −128 si no hay datos.
  - `substitutions`: contador acumulado de entradas sustituidas.

  La pérdida y el retraso no se mezclan: una entrada que nunca llega no baja el margen.

### 4.2 Antelación del cliente (`TickSync`)

En cada tick de física, el cliente decide cuántos pasos de predicción da:

| Pasos | Cuándo |
|---|---|
| 1 | Lo normal |
| 2 | Para adelantarse |
| 0 | Para retrasarse |
| N | Resincronización dura hacia delante |

- **Paso doble:** dos `ClientPrediction.step()` en el mismo tick de física. Es válido porque
  `move_and_slide()` usa el delta fijo mientras `Engine.is_in_physics_frame()`; lo demuestra
  `test_replay_matches_recording_across_physics_frames`.
- **Margen objetivo:** `M = clamp(1 + ceil(2 · jitter_ticks), 1, 4)`. El jitter es el de llegada
  de los snapshots, que mide `InterpolationClock`; se supone parecido en subida y en bajada.
- **Ventana:** las últimas 15 muestras de margen (~0,5 s). Se usa su mínimo.
- **Espera tras un ajuste.** Se descartan las muestras hasta que llega un snapshot con
  `input_ack_tick ≥ (primer tick posterior al ajuste) + 2`, es decir, cuando el servidor ya ha
  recibido entradas generadas después del ajuste. Así se espera exactamente el retardo de la
  realimentación, sea cual sea el RTT, y no hay sobreimpulso.
- **Corrección proporcional.** La deuda es `M − mínimo` ticks.
  - Para adelantarse, se paga con un paso doble por tick, en ticks seguidos.
  - Para retrasarse, con un paso nulo cada dos ticks, para que el personaje no se congele
    varios ticks seguidos.
- **Resincronización dura hacia delante** si el mínimo es ≤ −8: en ese mismo tick se dan
  `1 + (M − mínimo)` pasos, 30 como mucho.
- **Nunca hacia atrás.** Si el cliente va demasiado adelantado, se retrasa poco a poco. Saltar
  atrás regeneraría entradas ya enviadas y, como el servidor se queda con la primera copia,
  habría predicciones fallidas seguras.
- **Pulsaciones en ticks sin paso.** En los ticks de 0 pasos,
  `LocalPlayerController.accumulate_presses()` guarda los `just_pressed`, y el siguiente
  `build_input()` los suma. Así no se pierde ningún toque corto.

```gdscript
func on_snapshot(input_ack_tick: int, margin: int) -> void:
	if margin == NetProtocol.NO_MARGIN or input_ack_tick < _ignore_until_ack:
		return
	_window.push_back(margin)
	if _window.size() > WINDOW_SAMPLES:
		_window.pop_front()

func next_steps(predicted_tick: int) -> int:
	if _debt == 0 and not _window.is_empty():
		var low: int = _window.min()
		if low <= RESYNC_BEHIND:                       # -8
			var jump: int = mini(_target - low, MAX_RESYNC_STEPS - 1)
			_after_adjust(predicted_tick + 1 + jump)
			return 1 + jump
		if low < _target:
			_debt = _target - low
		elif _window.size() == WINDOW_SAMPLES and low > _target + 2:
			_debt = -(low - _target)
	if _debt > 0:
		_debt -= 1
		if _debt == 0:
			_after_adjust(predicted_tick + 2)
		return 2
	if _debt < 0:
		_slow_toggle = not _slow_toggle
		if not _slow_toggle:
			return 1
		_debt += 1
		if _debt == 0:
			_after_adjust(predicted_tick + 1)
		return 0
	return 1

func _after_adjust(first_new_tick: int) -> void:
	_window.clear()
	_ignore_until_ack = first_new_tick + 2
	adjustments += 1
```

### 4.3 Reloj de interpolación (`InterpolationClock`)

Es independiente de `TickSync`: uno fija cuándo se simula y el otro qué instante se dibuja, así
que no se pelean.

**Medida local, en ticks.** Con cada snapshot se calcula `offset = server_tick − local_tick`.

- `local_tick` cuenta los ticks de física del cliente. Los paquetes se leen al principio de
  cada tick, así que la resolución es de un tick.
- `max_offset` es el máximo de los últimos 120 ticks locales (2 s): la muestra que menos se ha
  retrasado, un estimador robusto de la latencia mínima.
- **Escalón hacia abajo.** El máximo de 120 ticks solo es un buen estimador si el reloj del
  servidor no retrocede respecto al del cliente. Si el servidor pierde ticks (un parón de más de
  8 ticks, o un servidor sobrecargado que pierde ticks sin parar) o la latencia sube de forma
  sostenida, los offsets bajan de golpe y se quedan abajo. Con el máximo de 2 s, el objetivo
  `local + max_offset − delay` iría `k` ticks por delante de los datos que existen: se
  extrapolaría 6 ticks, el remoto se quedaría quieto y al caducar la muestra vieja saltaría hacia
  atrás (hallazgo N3; medido: 98 ticks congelados tras un parón de 20, y 316 de 1201 con pérdida
  continua). Por eso, si el máximo de la ventana completa supera en más de `STEP_DOWN_TICKS` (4)
  ticks al de los últimos `RECENT_TICKS` (30) ticks locales, se descartan las muestras anteriores
  a esos 30 ticks (`_drop_samples_before_a_step_down`). Un bache más corto que 30 ticks no es un
  escalón y sigue contando como jitter. Los offsets que suben se adoptan al instante, como antes.
- `jitter` es la media exponencial (α = 0,1) de `max_offset − offset`.
- `delay = clamp(2 · SNAPSHOT_INTERVAL_TICKS + 2 · jitter, 4, 12)` ticks, es decir, de 67 a
  200 ms.

```gdscript
func advance(local_tick: int) -> float:          # una vez por tick de física
	var target: float = float(local_tick + _max_offset) - _delay
	if not _started or absf(target - _render_tick) > 10.0:
		_render_tick = target
		_started = true
	else:
		var advanced: float = _render_tick + 1.0         # primero avanza, después corrige
		_render_tick = advanced + clampf((target - advanced) * 0.1, -0.05, 0.05)
	return _render_tick
```

Corregir contra el valor ya avanzado evita un sesgo de un tick: la primera versión comparaba el
objetivo con el tick de dibujo anterior y convergía 1 tick por delante, con un retardo efectivo de
3 ticks en vez de 4 (corregido durante la implementación).

Los remotos se dibujan en `_process`, en el instante
`render_tick + Engine.get_physics_interpolation_fraction()`. Así cada fotograma usa su tiempo
exacto, sin el sesgo de medio tick que tendría aplicarlos en el tick de física.

---

## 5. Formatos de los mensajes

### 5.1 Convenciones

- Todo va en little-endian y se codifica con los `encode_*` / `decode_*` de `PackedByteArray`.
- Los mensajes de autenticación empiezan con el magic `0x4D444C45` (los bytes «ELDM»).
- El resto de mensajes van por `send_bytes` y su byte 0 es el tipo.
- Las cadenas van en UTF-8 con su longitud delante y nunca terminan en nulo.
- Los ticks son u32 absolutos. No hay números de secuencia con vuelta.

### 5.2 Catálogo

| Tipo | Mensaje | Sentido | Canal | Tamaño |
|---|---|---|---|---|
| — | HELLO | C→S | autenticación | 23 B + nombre + billete |
| — | WELCOME | S→C | autenticación | 18 B + id de zona + 3 B (v3) |
| — | REJECT | S→C | autenticación | 6 B + texto |
| `0x01` | INPUT_BATCH | C→S | 1 | 11 + 10·n B (21–91) |
| `0x02` | CLIENT_READY | C→S | 3 | 2 B |
| `0x03` | CLIENT_LEAVE | C→S | 3 | 2 B |
| `0x04` | DEBUG_COMMAND | C→S | 3 | 2 B + datos |
| `0x05` | RESPAWN_REQUEST | C→S | 3 | 2 B |
| `0x06` | UNSTUCK_REQUEST (v3) | C→S | 3 | 1 B |
| `0x07` | LOADOUT_SELECT (v6) | C→S | 3 | 2 B |
| `0x10` | SNAPSHOT | S→C | 2 | ≤ 1200 B (cabecera de 14 B, o de 134 B con estado y bloque extra propios (v6; 92 B hasta la v5), + 2 B por sección + 21 B por registro) |
| `0x20` | ENTITY_SPAWN | S→C | 3 | 10 B + datos (PROJECTILE, v6: 32 B en total) |
| `0x21` | ENTITY_DESPAWN | S→C | 3 | 8 B (motivos 4 y 5 de los proyectiles, v6) |
| `0x22` | OBJECT_STATE (v3) | S→C | 3 | 8 B + campos (de 1 a 32; 3, 4 o 6 B cada uno: ≤ 200 B) |
| `0x23` | ENTITY_EVENT | S→C | 3 | 9 B + datos (HIT 17 B, DEATH 13 B, RESPAWN 10 B, KILL 14 + 2·n B, WAR 11 B, TELEGRAPH 26 B; v6: STATUS 18 B, HEAL 15 B, LOADOUT 15 B, DOWNED 13 B, INTERACT 16 B) |
| `0x30` | NOTICE | S→C | 3 | 3 B + texto |
| `0x31` | HANDOFF (reservado, fase 6) | S→C | 3 | — |
| `0x32` | SCOREBOARD (v3) | S→C | 3 | 4 B + 18 B por fila (hasta 66 filas por mensaje: ≤ 1192 B) |
| `0x40` | CHAT_SEND (v5) | C→S | 3 | 5 B + destinatario + texto (≤ 821 B) |
| `0x41` | CHAT_MESSAGE (v5) | S→C | 3 | 11 B + emisor + destinatario + texto (≤ 875 B) |
| `0x48` | PARTY_INVITE (v5) | C→S | 3 | 2 B + nombre |
| `0x49` | PARTY_RESPONSE (v5) | C→S | 3 | 3 B + nombre |
| `0x4A` | PARTY_LEAVE (v5) | C→S | 3 | 1 B |
| `0x4B` | PARTY_KICK (v5) | C→S | 3 | 2 B + nombre |
| `0x4C` | PARTY_LEADER (v5) | C→S | 3 | 2 B + nombre |
| `0x4D` | PARTY_INVITATION (v5) | S→C | 3 | 7 B + nombre |
| `0x4E` | PARTY_ROSTER (v5) | S→C | 3 | 3 B + 3 B y nombre por miembro (≤ 258 B) |
| `0x4F` | PARTY_STATUS (v5) | S→C | 3 | 2 B + 17 B por miembro (≤ 87 B), a 2 Hz |

«v3» marca lo que añade el protocolo 3 (fase 4, [fuerte.md](fuerte.md#2-replicación-con-estado-object_state-gue-09)).
«v5» marca lo que añade el protocolo 5 (chat y grupos, [social.md](social.md#12-implementación-fase-4)).
«v6» marca lo que añade o cambia el protocolo 6 (habilidades, efectos, cambio de arma, proyectiles, derribado
y plantillas, [habilidades.md 5](habilidades.md#5-protocolo-protocol_version--6)).
El tamaño de un ENTITY_SPAWN depende de `kind` (ver 5.5).

### 5.3 Autenticación

**HELLO** (C→S)

| Offset | Tipo | Campo | Notas |
|---|---|---|---|
| 0 | u32 | magic | `0x4D444C45` |
| 4 | u16 | protocol_version | `NetProtocol.PROTOCOL_VERSION` (= 6: 2 combate, 3 su revisión, 4 el fuerte, 5 el chat y los grupos, 6 las habilidades) |
| 6 | u32 | sim_hash | ver [3](#3-conexión) |
| 10 | u8 | realm | 0 ninguno (se rechaza), 1 Vardheim, 2 Solmarch, 3 Askarra |
| 11 | u8 | flags | bit0 = bot; resto, 0 |
| 12 | u64 | character_id | 0 en la fase 2; personaje guardado desde la fase 5 |
| 20 | u8 | name_len | ≤ 48 B |
| 21 | n B | name | UTF-8, 3–24 caracteres |
| 21+n | u16 | ticket_len | 0 en la fase 2; ≤ 256 |
| 23+n | t B | ticket | sesión o billete de traspaso (fases 5–6) |

**WELCOME** (S→C): 18 B + id de zona + 3 B con el recuento por reino (v3).

| Offset | Tipo | Campo | Notas |
|---|---|---|---|
| 0 | u32 | magic | |
| 4 | u8 | result | 0 = aceptado (distingue WELCOME de REJECT) |
| 5 | u16 | protocol_version | |
| 7 | u32 | server_tick | tick del servidor al responder (solo informativo) |
| 11 | u8 | tick_rate | 60 |
| 12 | u8 | snapshot_interval | 2 |
| 13 | u8 | max_input_batch | 8 |
| 14 | u8 | max_rewind_ticks | 24 |
| 15 | u8 | realm | reino aceptado (desde la fase 5, el del personaje) |
| 16 | u8 | channel | canal de la zona; 0 en la fase 2 |
| 17 | u8 | zone_len | ≤ 32 |
| 18 | z B | zone_id | id ASCII de `zones.gd` |
| 18+z | u8 × 3 | realm_counts | jugadores de Vardheim, Solmarch y Askarra en la zona (saturan a 255), para que la selección de reino ofrezca el más corto ([fuerte.md 7](fuerte.md#7-bots-que-asedian-gue-15-gue-16-gue-42)). Personas (no jugadores falsos) de cada reino en el momento del HELLO, sin contar a quien entra; el servidor los rellena desde GUE-42 (F6a) |

El tamaño es exactamente `21 + z`: un WELCOME de la versión 2 (sin el recuento) ya no se decodifica.

**REJECT** (S→C)

| Offset | Tipo | Campo | Notas |
|---|---|---|---|
| 0 | u32 | magic | |
| 4 | u8 | result | 1 VERSION, 2 SIM_HASH, 3 REALM, 4 FULL, 5 TICKET, 6 MALFORMED, 7 TOO_MANY_CONNECTIONS, 8 NAME, 9 IMBALANCE (v3: el reino elegido tiene demasiados jugadores, `--max-realm-diff`; se comprueba después del proveedor de identidad) |
| 5 | u8 | text_len | |
| 6 | n B | text | UTF-8, en español (`NetProtocol.result_text`) |

### 5.4 Cliente → servidor

**INPUT_BATCH** (`0x01`, canal 1). Se envía una vez por tick de física, también en los ticks de
0 pasos.

| Offset | Tipo | Campo | Notas |
|---|---|---|---|
| 0 | u8 | type | `0x01` |
| 1 | u32 | ack_snapshot_tick | `server_tick` del snapshot más nuevo recibido (0 = ninguno). Sirve para medir el RTT en el servidor y, en el futuro, como base del delta |
| 5 | u8 | interp_delay_q | retardo de interpolación actual × 8, en ticks (como mucho 96 = 12 ticks: lo que pase es un aviso). Acota el rebobinado de la fase 3 |
| 6 | u32 | newest_tick | tick de la entrada más nueva |
| 10 | u8 | count | 1..8 |
| 11 | count × 10 B | records | de la más antigua a la más nueva; el registro *i* es del tick `newest_tick − count + 1 + i` |

Cada registro de entrada (10 B):

| Offset | Tipo | Campo | Notas |
|---|---|---|---|
| +0 | s8 | move.x | = `PlayerInput.encode()[4]` |
| +1 | s8 | move.y | `[5]` |
| +2 | u16 | look_yaw | `[6..7]` |
| +4 | s16 | look_pitch | `[8..9]` |
| +6 | u16 | buttons | `[10..11]`; el servidor aplica `& NetProtocol.VALID_BUTTONS`: bits 0–12 (v6: 9 cambiar de arma, 10 hombro izquierdo de la puntería, 11 y 12 las pociones; 0–8 hasta la v5). Los bits 13–14 están reservados y el 15 es la marca de sustituida, que el cliente no puede poner |
| +8 | u16 | view_offset_q | `(tick − render_tick visto) × 16`, limitado a 0..65535. Va por entrada: una copia redundante de un ataque conserva su propio valor |

- **Ticks implícitos.** Los ticks de los registros salen de `newest_tick` y van seguidos, así
  que un lote con huecos no se puede ni escribir.
- **Decodificación.** Se reconstruyen los 12 B con el tick delante y se llama a
  `PlayerInput.decode()`, que ya normaliza los valores fuera de rango. `player_input.gd` no
  cambia.
- **Qué entradas se envían:**
  - la más antigua es `max(input_ack_tick + 1, newest − R + 1, first_real_tick)`, sin pasar de
    `newest`;
  - R = 4 normalmente, y R = 8 si en los últimos 120 ticks ha subido `substitutions` o si ENet
    mide más de un 2 % de pérdida.

**CLIENT_READY** (`0x02`, canal 3): `u8 type`, `u8 flags` (reservado, 0).

**CLIENT_LEAVE** (`0x03`, canal 3): `u8 type`, `u8 reason` (0 salir, 1 error). Permite la baja
inmediata sin esperar al timeout.

**DEBUG_COMMAND** (`0x04`, canal 3): `u8 type`, `u8 command`, datos.

- `command` 1 = TELEPORT, con `f32 × 3` de posición (14 B en total).
- **Ids fijos** (`NetProtocol.DEBUG_*`), que no se reutilizan ni se reordenan: 1 `teleport`,
  2 `heal`, 3 `kill`, 4 `stamina_inf`, 5 `set_weapon`, 6 `spawn_dummy` y, desde la versión 4
  ([fuerte.md 1.6](fuerte.md#16-controlador-gue-08-gue-12)), 7 `unstuck`, 8 `fort_reset`, 9
  `fort_owner`, 10 `fort_kill_captain`, 11 `fort_capture_speed` y 12 `npc_debug` y, desde la versión
  6 ([habilidades.md 5.1](habilidades.md#51-entradas-y-mensajes-cs)), 13 `cooldowns_off`, 14
  `apply_status`, 15 `down` y 16 `refill`. Los datos de 2 a 6 los define el servidor
  ([combate.md 6](combate.md#6-protocolo-tec-13-protocol_version--2)); el `decode` solo exige 64 B de
  datos como mucho. Los de 7 a 16 los valida el `decode`: 7, 8, 10, 15 y 16, sin datos; 9, `u8` con el
  reino (0 a 3); 11, `u8` con el factor (1 a 255); 12 y 13, `u8` (0 apaga, 1 activa); 14, `u8
  status_id` (1 a 255) y `u16` ticks (0 = la duración del dato). Un id fijo cuyo manejador aún no
  existe en el servidor se acepta sin aviso y sin efecto (los de 7 a 12 hasta que llegaron F3 y F4; 13
  y 14 hasta H3a, 15 y 16 hasta H3c). `NetProtocol.DEBUG_COMMAND_IDS` es la tabla
  nombre → id con la que el registro de comandos del servidor comprueba que todo comando de red
  tiene su id. `announce`, `kick` y `shutdown` son solo de consola.
- Solo se acepta si el servidor arrancó con `--debug-commands`; si no, cuenta un aviso
  (*strike*, ver [12](#12-seguridad-de-la-fase-2)).

**RESPAWN_REQUEST** (`0x05`, canal 3): `u8 type`, `u8 point_index`. El jugador muerto pide
reaparecer en el punto `point_index` de la lista de puntos de su reino (desde la fase 4, la lista
estática de todos los puntos de la zona, `NetZones.get_all_respawn_points`; el servidor comprueba
que valga para su reino, [fuerte.md 8.3](fuerte.md#83-lo-que-han-dejado-f0-f1-y-f2-añadidos-al-contrato-y-decisiones))
([combate.md 5](combate.md#5-vida-eventos-muerte-y-reaparición-cmb-10-cmb-15-cmb-41-gue-03-gue-05)).
Fuera de plazo o con un índice inválido, el servidor cuenta un aviso. La mandan el botón de la pantalla de
muerte, el `SwarmBot` y, desde la revisión de la fase 4, el `--bot` (punto 0, en cuanto el tick estimado del
servidor llega al `respawn_tick` del bloque extra, y cada segundo mientras siga muerto); los jugadores falsos
del servidor no tienen red y la piden al morir (`Combatant.requests_respawn_on_death`).

**UNSTUCK_REQUEST** (`0x06`, canal 3, v3): 1 B, solo `u8 type`. El jugador pide `/atascado`
([fuerte.md 5](fuerte.md#5-avisos-reaparición-salida-y-atascado)). Vale sin `--debug-commands`. Antes
de entrar en el mundo, o con algún byte más, cuenta un aviso; la canalización de 10 s, la
reutilización y el teletransporte son de F3.

**LOADOUT_SELECT** (`0x07`, canal 3, v6): `u8 type`, `u8 template_id`. La plantilla de equipo para la
siguiente aparición ([habilidades.md 4.6](habilidades.md#46-equipo-plantillas-y-consumibles)). Vale desde
el WELCOME, también antes de CLIENT_READY (LOADING e IN_WORLD), y pasa por el limitador de fiables. 0 = la
de por defecto, sin aviso; un id que no existe o no es `selectable` cuenta un aviso. El `decode` solo
exige los 2 B y el tipo. El servidor (H3c) la guarda en `ServerPeer.pending_template_id` y la aplica al dar de
alta al jugador (el SPAWN ya sale con sus armas) y en cada reaparición, con un ENTITY_EVENT LOADOUT.

### 5.5 Servidor → cliente

**SNAPSHOT** (`0x10`, canal 2)

| Offset | Tipo | Campo | Notas |
|---|---|---|---|
| 0 | u8 | type | `0x10` |
| 1 | u32 | server_tick | estado tras simular este tick |
| 5 | u32 | input_ack_tick | `max(mayor tick contiguo recibido, último consumido)`. Nunca se atasca tras una entrada sustituida |
| 9 | s8 | input_margin | ver [4.1](#41-tick-del-servidor-y-regla-de-aplicación); −128 = sin datos |
| 10 | u16 | substitutions | total acumulado de entradas sustituidas de este jugador (mod 65536). Robusto a snapshots perdidos |
| 12 | u8 | flags | bit0 = incluye el estado propio; bits 1–2 = contador de teletransporte propio (mod 4); bit3 = incluye el bloque extra propio; resto, 0 |
| 13 | 111 B | own_state | `PlayerState.encode()` sin cuantizar, si bit0. Base de la reconciliación (v6; 69 B hasta la v5) |
| 124 | 9 B | own_extra | bloque extra propio, si bit3 (ver abajo); en el 82 hasta la v5 |
| 133 (o 13) | u8 | section_count | en el 91 hasta la v5 |
| … | | secciones | cada una: `u8 kind`, `u8 count` y `count` registros del tamaño fijo de ese `kind` |

**Bloque extra propio** (9 B). Lleva lo que el servidor decide y no entra en `PlayerState`
porque no cambia la simulación ([combate.md 1](combate.md#1-qué-se-predice-y-qué-decide-el-servidor)):

| Offset | Tipo | Campo | Notas |
|---|---|---|---|
| +0 | u16 | health | vida actual |
| +2 | u16 | max_health | vida máxima; `health ≤ max_health` |
| +4 | u8 | status | bit0 en combate, bit1 protegido (reaparición), bit2 muerto, bit3 derribado (v6; nunca con el bit2). Derribado, `health` es la vida de derribado y `max_health` la de derribado de las reglas (400) |
| +5 | u32 | respawn_tick | primer tick en que se puede pedir la reaparición; 0 si está vivo |

- **El bit 3 va si y solo si va el bit 0.** `Snapshot.decode` devuelve `null` si uno falta sin el
  otro, o si `health > max_health`.
- **Capacidad.** Con estado propio y bloque extra, la cabecera (con `section_count`) ocupa 134 B (v6;
  92 B hasta la v5). Con una sección de jugadores caben ⌊(1200 − 134 − 2) / 21⌋ = **50 registros** (52
  hasta la v5).
- **El propio jugador** nunca aparece entre los registros: para eso está su estado.

**Registro de entidad** (`kind` 1 PLAYER; 2 NPC reutiliza el formato), 21 B:

| Offset | Tipo | Campo | Notas |
|---|---|---|---|
| 0 | u16 | net_id | |
| 2 | u64 | position | 20 bits por eje: `q = round(v · 100) + 2^19`, saturado a [0, 2^20 − 1]. x en los bits 0–19, y en 20–39, z en 40–59; los bits 60–63 a 0. 1 cm de resolución, ±5,24 km |
| 10 | u16 | yaw | [0, TAU) → 0..65535, igual que `PlayerInput.look_yaw` |
| 12 | s16 × 3 | velocity | cm/s, saturado (±327 m/s) |
| 18 | u8 | flags | bit0 = grounded; bits 1–2 = contador de teletransporte (mod 4); bit3 = ranura de arma 2 activa (v6); resto, 0 |
| 19 | u8 | action | acción y fase del combate (ataque, bloqueo, esquiva...; 0 = ninguna). Los bits los define `ActionMachine.action_byte` |
| 20 | u8 | health_q | vida cuantizada: 0 si está muerto y, si no, `clampi((vida · 255 + máx − 1) / máx, 1, 255)` (hacia arriba, nunca 0 con vida). Las entidades sin vida anuncian 255 |

- **Teletransporte.** El contador de 2 bits sustituye a un flag de un solo snapshot, que se
  perdería con ese snapshot. Si cambia entre dos muestras, no se interpola entre ellas.
- **Arma activa (v6).** El remoto sabe qué arma lleva con la pareja de armas (SPAWN o LOADOUT) y el bit 3:
  la de la ranura 2 si está puesto. El byte `action` no tiene bits libres. El historial de la compensación
  de latencia no toma este bit: allí el bit 3 es `DEFENSE_BLOCKING` y el byte del historial es `(flags &
  0b111) | defensa` ([habilidades.md 3.6](habilidades.md#36-consultas)).
- **Animación.** El esprint no viaja: el cliente lo deduce de la velocidad.

**ENTITY_SPAWN** (`0x20`, canal 3)

| Offset | Tipo | Campo | Notas |
|---|---|---|---|
| 0 | u8 | type | `0x20` |
| 1 | u16 | net_id | |
| 3 | u8 | kind | 1 PLAYER, 2 NPC, 3 PROJECTILE, 4 STRUCTURE |
| 4 | u32 | spawn_tick | tick del estado incluido |
| 8 | u8 | realm | |
| 9 | u8 | flags | bit0 = es tu personaje; bits 1–2 = contador de teletransporte. En un proyectil (v6), 0 |
| 10 | … | payload | según `kind` (abajo) |

Payload según `kind`:

- **PLAYER** (1): `PlayerState` (111 B desde la v6, 69 B hasta la v5; estado tras `spawn_tick`), `u8
  name_len` y el nombre (≤ 48 B).
- **NPC** (2): lo mismo que un jugador y, tras el nombre, `u16 npc_def_id` (v3): el id del catálogo
  de PNJ (`NpcCatalog`, ids alfabéticos 1..n; 0 = sin definición) para que el cliente elija modelo,
  tabardo y barra de jefe. Tamaño: 10 + 111 + 1 + n + 2 B (v6).
- **STRUCTURE** (4, v3): `u8 def_len` (1–32), el id de la definición en ASCII imprimible (por
  ejemplo `vado_gris_fort`), `u8 field_count` (1–32) y los campos completos, cada uno `u8 field_id,
  u8 value_type` y el valor, como en OBJECT_STATE (sin repetir type, net_id ni tick). No lleva
  estado de jugador ni nombre. El `realm` de la cabecera es 0: manda el campo `owner`. Para una
  fortaleza son 98 B con el id del Vado Gris (10 + 1 + 14 + 1 + 72).
- **PROJECTILE** (3, v6; [habilidades.md 5.3](habilidades.md#53-projectile-kind-3)): 22 B tras la cabecera,
  **32 B** en total. `net_id` es el proyectil (del espacio de ids de `NetEntityRegistry`, sin ser una
  entidad), `realm` el del tirador, `spawn_tick` el tick del disparo y los flags de la cabecera van a 0
  (`is_yours` nunca: la flecha propia es la de `owner` igual a tu `net_id`). El cliente calcula el vuelo
  con `Ballistics.position`; el snapshot no lleva registros de proyectiles. **Destinatarios** (H3b): el
  SPAWN va al dueño del tirador y a quien lo tiene relevante en el tick del disparo; su DESPAWN (motivo 4
  o 5), exactamente a quienes recibieron el SPAWN, aunque ya no tengan relevante al tirador. Quien empieza
  a ver al tirador después no recibe las flechas que ya están en el aire (viven 2 s como mucho).

| Offset | Tipo | Campo | Notas |
|---|---|---|---|
| 10 | u16 | owner | `net_id` del tirador |
| 12 | u16 | projectile_def_id | `ProjectileDefinition` del catálogo de combate |
| 14 | u16 | source | fuente del ataque o la habilidad (`CombatSource`, ver ENTITY_EVENT) |
| 16 | u8 | volley_index | 0..n−1 dentro del disparo (el abanico lanza tres) |
| 17 | u8 | proj_flags | bit0 inofensiva (vuela y choca con el mundo, no prueba personajes); resto, 0 |
| 18 | u64 | position | `p0`, 20 bits por eje como el registro (1 cm) |
| 26 | s16 × 3 | velocity | `v0` en cm/s (±327,67 m/s) |

`decode` devuelve `null` si el tamaño no cuadra con las longitudes, un texto no es válido, el `kind`
no tiene formato o, en una estructura, el id de definición no es ASCII imprimible de 1 a 32 B, el
contador no está entre 1 y 32, un campo trae un `value_type` desconocido o se repite un `field_id`; en
un proyectil (v6), si no ocupa exactamente 32 B, trae algún flag en la cabecera o un bit de
`proj_flags` que no existe.

El `PlayerState` del SPAWN **propio** (bit0 = 1) va entero. El de una entidad **ajena** es público: lleva
posición, velocidad, giro y suelo, y del combate solo la acción en curso (con su ataque y su tick de inicio)
y el arma; el resto del `CombatState` (resistencia exacta, agotamiento, enfriamiento de la parada, búfer,
paso del combo, controles, empuje), los botones del último tick y los contadores de salto vuelven a sus
valores iniciales. Lo contrario volcaba a cualquiera que entrara en la zona el estado privado de cada
enemigo (combate.md 6). Desde la v6 es público además el arma de la otra ranura (`alt_weapon_id`) y la
ranura activa (bit 0 de `combat_flags2`): las armas se ven. Reutilizaciones, cargas, la reutilización de
los consumibles, las ranuras de efectos de movimiento y los bits de botones pulsados vuelven a sus valores
iniciales ([habilidades.md 5.2](habilidades.md#52-estado-snapshot-y-registro)).

**ENTITY_DESPAWN** (`0x21`, canal 3)

| Offset | Tipo | Campo | Notas |
|---|---|---|---|
| 0 | u8 | type | `0x21` |
| 1 | u16 | net_id | |
| 3 | u32 | despawn_tick | el cliente lo quita cuando su `render_tick` llega aquí |
| 7 | u8 | reason | 0 fuera de interés, 1 desconexión, 2 muerte, 3 traspaso; v6, de los proyectiles: 4 impacto (en `despawn_tick`, en el segmento `[pos(n), pos(n + 1)]` con `n = despawn_tick − spawn_tick`) y 5 caducado o retirado |

**ENTITY_EVENT** (`0x23`, canal 3). Hechos del combate que no caben en un registro de flujo
([combate.md 6](combate.md#6-protocolo-tec-13-protocol_version--2)). Fiable y ordenado con los
demás mensajes del canal 3.

| Offset | Tipo | Campo | Notas |
|---|---|---|---|
| 0 | u8 | type | `0x23` |
| 1 | u16 | net_id | la entidad a la que se ata: la víctima en HIT, DEATH y KILL; la que reaparece en RESPAWN; la fortaleza en WAR; el PNJ en TELEGRAPH; v6: el afectado en STATUS, el curado en HEAL, el jugador en LOADOUT y el derribado en DOWNED e INTERACT |
| 3 | u32 | tick | tick del servidor en que ocurrió |
| 7 | u8 | event | 1 HIT, 2 DEATH, 3 KILL, 4 RESPAWN, 5 WAR, 6 TELEGRAPH; v6: 7 STATUS, 8 HEAL, 9 LOADOUT, 10 DOWNED, 11 INTERACT |
| 8 | u8 | len | bytes de datos que siguen |
| 9 | len B | datos | según `event` |

| `event` | Datos | `len` | Total |
|---|---|---|---|
| 1 HIT | `u16 attacker`, `u16 amount`, `u8 damage_type`, `u8 flags`, `u16 attack_id` | 8 | 17 B |
| 2 DEATH | `u16 killer` (0 = el entorno), `u16 attack_id` | 4 | 13 B |
| 3 KILL | `u16 killer`, `u16 attack_id`, `u8 n`, `n × u16` asistentes | 5 + 2·n | 14 + 2·n B |
| 4 RESPAWN | `u8 point` | 1 | 10 B |
| 5 WAR (v3) | `u8 war_event` (1–7, `WarEvents`), `u8 realm` (0–3) | 2 | 11 B |
| 6 TELEGRAPH (v3) | `u16 attack_id`, `u8 shape` (0 círculo, 1 sector), `u64 position`, `u16 yaw`, `u16 radius_cm`, `u16 impact_in_ticks` | 17 | 26 B |
| 7 STATUS (v6) | `u16 source_entity` (0 = sin autor), `u8 op` (1 aplicado o renovado, 2 quitado), `u8 status_id`, `u8 stacks`, `u32 until_tick` (exclusivo) | 9 | 18 B |
| 8 HEAL (v6) | `u16 healer` (0 = sí mismo), `u16 amount`, `u16 source` | 6 | 15 B |
| 9 LOADOUT (v6) | `u8 template_id`, `u16 weapon_1`, `u16 weapon_2` (en orden de ranura; 0 = ninguna), `u8 charges` (bits 0–3 poción 1, 4–7 poción 2; 0 para quien no es el dueño) | 6 | 15 B |
| 10 DOWNED (v6) | `u16 attacker`, `u16 source` | 4 | 13 B |
| 11 INTERACT (v6) | `u16 actor`, `u8 op` (1 levantar, 2 levantar cortado, 3 levantado, 4 rematar, 5 rematar cortado), `u32 end_tick` | 7 | 16 B |

- **WAR**: el `net_id` es la fortaleza y el `realm` el reino que acompaña al aviso
  (`FortressState.event_realm`). Va a toda la zona y se aplica en el tick de dibujo
  ([fuerte.md 5](fuerte.md#5-avisos-reaparición-salida-y-atascado)).
- **TELEGRAPH**: el `net_id` es el PNJ que prepara el ataque. `position` va empaquetada como en el
  registro de entidad (20 bits por eje, 1 cm), `yaw` como en el registro (0..65535 sobre [0, TAU)),
  `radius_cm` es el alcance y `impact_in_ticks` los ticks que faltan para el golpe. Se aplica al
  llegar: es un aviso. El golpe cae en `tick + impact_in_ticks` del servidor y lo esquiva la entrada
  de ese tick, así que el cliente cuenta el plazo con su tick predicho, no con la hora de llegada
  (la marca, los bots; [fuerte.md 5](fuerte.md#5-avisos-reaparición-salida-y-atascado)).

- **Flags de HIT:** bit0 crítico, bit1 bloqueado, bit2 parado, bit3 rotura de guardia, bit4
  mortal; v6: bit5 interrumpido (beber, un lanzamiento marcado, levantar o rematar) y bit6 derriba.
- **Fuente (v6).** Los `u16 attack_id` de HIT, DEATH, KILL y TELEGRAPH, y el `u16 source` de HEAL, DOWNED
  y del SPAWN de un proyectil, son una fuente (`CombatSource`): bits 14–15 la clase y 0–13 el id. 0 =
  ninguna (el entorno); `0x0000 | id` ataque (los de la fase 3 conservan su número); `0x4000 | id`
  habilidad; `0x8000 | id` efecto (un pulso); `0xC000 | 1` remate y `0xC000 | 2` desangrado. Los ids
  se piden al catálogo por nombre: ninguno es fijo.
- **STATUS, HEAL, LOADOUT, DOWNED e INTERACT (v6)**: destinatarios, temporización y qué explican en la
  predicción, en [habilidades.md 5.4](habilidades.md#54-entity_event-y-fuentes). DOWNED va a toda la zona
  (registro de bajas); LOADOUT, al dueño y, si cambian las armas, a quien lo tenga relevante con
  `charges` = 0.
- **Validación.** `decode` devuelve `null` si el tipo no es `0x23`, el `event` es desconocido,
  `len` no cuadra con el evento o con el tamaño real del mensaje, `n` no cuadra con `len` o
  `n > 16` (los asistentes hacen al menos el 10 % del daño, así que nunca son más de 10), un WAR trae
  un aviso fuera de 1–7 o un reino mayor que 3, un TELEGRAPH trae una forma que no es 0 ni 1, un STATUS
  o un INTERACT traen un `op` fuera de rango, o un STATUS aplicado trae 0 acumulaciones (v6).
  `encode` recorta un KILL a 16 asistentes.
- **Destinatarios y temporización:** ver [combate.md 6](combate.md#6-protocolo-tec-13-protocol_version--2).

**NOTICE** (`0x30`, canal 3): `u8 type`, `u8 code`, `u8 len` y el texto en UTF-8 (≤ 200 B).

- Códigos: 0 informativo, 1 expulsión, 2 servidor cerrándose.
- Con el código 1, el servidor desconecta al peer después del `flush()`.

**OBJECT_STATE** (`0x22`, canal 3, v3). El estado replicado de un objeto que no es un jugador ni un
PNJ, hoy una fortaleza ([fuerte.md 2](fuerte.md#2-replicación-con-estado-object_state-gue-09)).

| Offset | Tipo | Campo | Notas |
|---|---|---|---|
| 0 | u8 | type | `0x22` |
| 1 | u16 | net_id | la estructura |
| 3 | u32 | tick | tick del servidor tras el que vale el estado |
| 7 | u8 | field_count | 1–32 |
| 8 | … | campos | cada uno: `u8 field_id`, `u8 value_type` (1 u8, 2 u16, 3 u32, 4 s32) y el valor (1, 2, 4 o 4 B) |

- Un mensaje trae solo los campos que han cambiado (como mucho uno por fortaleza cada 6 ticks); el
  estado completo viaja en el ENTITY_SPAWN de la estructura. Los ids de campo de una fortaleza son
  los de `FortressFields`.
- **Validación.** `decode` devuelve `null` si el tamaño no cuadra, un `value_type` es desconocido,
  `field_count` no está entre 1 y 32 o se repite un `field_id`. Un `field_id` desconocido con un tipo
  válido se conserva y quien interpreta el objeto lo salta (compatibilidad hacia delante). Un campo
  conocido con otro tipo de valor que el suyo no lo rechaza el `decode` (no sabe de qué objeto es):
  `ObjectState.apply_to_fortress` lo salta e `is_valid_for_fortress` lo señala.

**SCOREBOARD** (`0x32`, canal 3, v3). El marcador de la zona, cada 2 s a todos los jugadores
([fuerte.md 6](fuerte.md#6-interfaz-ui-18-ui-21-ui-41-ui-42)).

| Offset | Tipo | Campo | Notas |
|---|---|---|---|
| 0 | u8 | type | `0x32` |
| 1 | u8 | page_index | desde 0 |
| 2 | u8 | page_count | total de páginas, 1–255 |
| 3 | u8 | row_count | 0–66 |
| 4 | row_count × 18 B | filas | `u16 net_id`, `u16 bajas`, `u16 muertes`, `u16 asistencias`, `u32 daño a la puerta`, `u16 segundos en el círculo`, `u32 méritos` |

- Una página no pasa de **66 filas** (4 + 66 · 18 = 1192 B ≤ `MAX_PACKET_BYTES`). Con más jugadores el
  marcador se parte en varios mensajes (`Scoreboard.split`), que el cliente junta por `page_index`
  de `page_count`; sin jugadores se manda una sola página vacía.
- Los contadores saturan a su máximo al codificar. `decode` devuelve `null` si el tamaño no es
  exactamente `4 + 18 · row_count`, `row_count > 66`, `page_count` es 0 o `page_index ≥ page_count`.

### 5.6 Reservados

- **HANDOFF** (`0x31`, fase 6): zona, canal, host, puerto y billete.

Ocupar uno de estos tipos sube `PROTOCOL_VERSION`. ENTITY_EVENT (`0x23`) dejó de estar
reservado en la fase 3 y OBJECT_STATE (`0x22`) en la fase 4 (protocolo 3): sus formatos están en
[5.5](#55-servidor--cliente).

### 5.7 Validación

- **Decodificación.** Cada `decode` devuelve `null` si el tamaño, el tipo, los contadores o las
  longitudes no cuadran. Nunca registra errores del motor (el ejecutor de pruebas los cuenta
  como fallo).
- **Lotes de entradas.** `count` debe estar entre 1 y 8, el tamaño debe ser exactamente
  `11 + 10 · count` y `newest_tick ≥ count`.
- **Avisos.** Los paquetes malformados, los tipos inesperados para el estado de la sesión y los
  excesos de ritmo cuentan avisos ([12](#12-seguridad-de-la-fase-2)). También los paquetes que no
  son del protocolo de `SceneMultiplayer` (ver [2](#2-transporte-y-canales)): ya no llegan a
  registrar errores del motor.

---

## 6. Predicción y reconciliación

### 6.1 Requisitos en el código compartido

- **`PlayerCharacter.yaw` se redondea a f32** en su setter (`PlayerState.to_f32`).
  - Era el único campo del estado en f64, y `PlayerState` lo codifica en f32: el resultado de
    `atan2` no sobrevive a la ida y vuelta.
  - Sin el redondeo, el servidor (f64) y el cliente (f32 decodificado) difieren en el último bit
    mientras se gira, y ninguna comparación exacta pasaría.
- **`PlayerCharacter.events_enabled`:** durante las repeticiones y el avance neutro no se emiten
  `jumped` ni `landed`, para no duplicar sonidos ni animaciones.
- **`PlayerState.equals_exact(other)`** compara `encode()`.
- **El servidor redondea por `encode`/`decode`** todo estado base que impone: aparición y
  teletransporte.

### 6.2 Tick del cliente

Un único `NetClient._physics_process` lo orquesta todo (`process_physics_priority = -100`) y
`LocalPlayerController.auto_step = false`.

```gdscript
func _physics_process(_delta: float) -> void:
	_local_tick += 1
	_transport.poll(_local_tick)
	# _on_packet: los fiables se aplican al momento (SPAWN, DESPAWN, NOTICE). Cada SNAPSHOT
	# va a _interp_clock.on_snapshot() y a _remote_world; el más nuevo se guarda en _latest.
	if _prediction.is_started():
		if _latest != null and _latest.server_tick > _last_snapshot_tick:
			_last_snapshot_tick = _latest.server_tick
			_tick_sync.set_jitter(_interp_clock.get_jitter_ticks())
			_tick_sync.on_snapshot(_latest.input_ack_tick, _latest.input_margin)
			_input_ack_tick = _latest.input_ack_tick
			if _latest.own_state != null:
				var teleported: bool = _latest.own_teleport != _own_teleport
				_own_teleport = _latest.own_teleport
				_prediction.on_server_state(_latest.server_tick, _latest.own_state, teleported)
		_latest = null
		var steps: int = _tick_sync.next_steps(_prediction.get_predicted_tick())
		if steps == 0:
			_controller.accumulate_presses()
		for i: int in steps:
			var tick: int = _prediction.get_predicted_tick() + 1
			_view_offsets[tick % HISTORY_SIZE] = tick - _remote_world.get_last_drawn_render_tick()
			_prediction.step()
		_send_input_batch()
	_interp_clock.advance(_local_tick)
	_smoother.physics_step()
	_transport.flush()
```

- **Snapshots atrasados.** Los que llegan desordenados (posible con `NetSim`) solo alimentan a
  los interpoladores, nunca a la reconciliación.
- **Dibujo de los remotos.** `RemoteWorld._process` dibuja a los remotos y guarda
  `last_drawn_render_tick`. Las entradas de un tick de física se construyen antes del
  `_process` de ese fotograma, así que el valor guardado es lo que el jugador estaba viendo.

### 6.3 Arranque

```gdscript
func start(spawn_tick: int, spawn_state: PlayerState, first_real_tick: int) -> void:
	_character.set_state(spawn_state)
	_character.reset_physics_interpolation()
	_store(spawn_tick, null, spawn_state)
	_predicted_tick = spawn_tick
	_first_real_tick = first_real_tick
	var neutral: PlayerInput = NetProtocol.neutral_input(0, spawn_state.yaw)
	_character.events_enabled = false
	for t: int in range(spawn_tick + 1, first_real_tick):
		var input: PlayerInput = neutral.duplicate_input()
		input.tick = t
		_character.simulate(input, _dt)
		_store(t, input, _character.get_state())
		_predicted_tick = t
	_character.events_enabled = true
```

- **Mientras no llega ninguna entrada real**, el servidor sustituye cada tick por
  `last_applied` (la entrada neutra del alta) con `move = 0`: es la misma entrada. Por eso los
  dos estados coinciden bit a bit desde el primer tick.
- **Entrada neutra:** movimiento 0, botones 0, `look_yaw` igual al yaw del estado cuantizado y
  pitch 0. Con `move = 0` la vista no afecta a la simulación.
- **Si la primera entrada real llega tarde**, el servidor sustituye ese tick y la
  reconciliación lo corrige.

### 6.4 Paso de predicción y envío

```gdscript
func step() -> PlayerInput:
	var t: int = _predicted_tick + 1
	var input: PlayerInput = _controller.build_input(t)   # cuantizada, con pulsaciones acumuladas
	_character.simulate(input, _dt)
	_store(t, input, _character.get_state())
	_predicted_tick = t
	return input
```

- **Anillos.** `_store(t, input, state)` escribe en dos anillos de 256 huecos indexados por
  `t % 256`, con el tick como etiqueta. Sustituyen al `pop_front()` (O(n)) del historial actual.
- **Envío.** `_send_input_batch()` arma el INPUT_BATCH de [5.4](#54-cliente--servidor) con las
  entradas de `_prediction.get_input(t)` y los `view_offset_q` de `_view_offsets`. Lo envía por
  `CH_INPUT` una vez por tick de física.

### 6.5 Reconciliación

```gdscript
func on_server_state(server_tick: int, server: PlayerState, teleported: bool) -> int:
	if server_tick <= _last_reconciled:
		return Result.IGNORED
	_last_reconciled = server_tick
	if server_tick > _predicted_tick or not _has_state(server_tick):
		hard_reset(server_tick, server)
		return Result.HARD_RESET
	if not teleported and _states[server_tick % HISTORY_SIZE].equals_exact(server):
		return Result.MATCH
	var before: Vector3 = _character.global_position
	_character.set_state(server)
	_states[server_tick % HISTORY_SIZE] = server
	_replaying = true
	_character.events_enabled = false
	for t: int in range(server_tick + 1, _predicted_tick + 1):
		_character.simulate(_input_or_substitute(t), _dt)
		_states[t % HISTORY_SIZE] = _character.get_state()
	_character.events_enabled = true
	_replaying = false
	var error: Vector3 = before - _character.global_position
	if teleported or error.length() > SNAP_DISTANCE:          # 3 m
		_smoother.clear()
		_character.reset_physics_interpolation()
	elif not error.is_zero_approx():
		_smoother.add_offset(error)
	_stats.record_correction(error.length())
	return Result.CORRECTED
```

- **La comparación es exacta.** Detecta también las diferencias de `prev_buttons`,
  `last_input_tick` y los contadores de salto, que `is_close_to` no miraba.
- **Coste.** Con 300 ms de RTT se vuelven a simular unos 20 ticks, y solo cuando hay alguna
  diferencia.
- **Entre plataformas** (servidor en Linux, cliente en Windows), una diferencia en el último bit
  de `sin`/`cos` provoca una repetición casi gratis y un desfase inferior al milímetro. La
  métrica «correcciones» solo cuenta las de más de 1 mm.
- **`_input_or_substitute(t)`** devuelve la entrada guardada si su etiqueta coincide y, si no, la
  regla de sustitución del servidor ([8.2](#82-cola-de-entradas-inputqueue)). Solo pasa tras un
  `hard_reset`.
- **`hard_reset(tick, state)`** hace `set_state(state)` y guarda el estado.
  - Si `tick ≥ _predicted_tick`, pone `_predicted_tick = tick`: `TickSync` recupera la antelación.
  - Si no, vuelve a simular hasta `_predicted_tick` como arriba.
  - Siempre termina con `smoother.clear()` y `reset_physics_interpolation()`.

### 6.6 Suavizado de la corrección (`CorrectionSmoother`)

- **El cuerpo se corrige de golpe**, porque manda la colisión del servidor.
- **El error se aplica como desfase** a los nodos locales `Visual` y `CameraTarget`, nunca a
  `Collision`. Va en espacio local, recalculado cada tick porque el yaw cambia:
  `target.position = base_position + character.basis.inverse() * offset`.
  - `base_position` es la posición local original de cada nodo; `CameraTarget` está en
    (0, 1,6, 0).
- **Decae cada tick de física** con una semivida de 6 ticks (100 ms) y se anula por debajo de
  1 mm.
- **Por qué no salta la imagen.** Se escribe dentro del tick de física, así que la interpolación
  física lo interpola como todo lo demás. En el tick de la corrección, el cuerpo salta del punto
  viejo al nuevo y el desfase pasa de 0 a `viejo − nuevo`: la posición visible no salta, y
  después converge sin tirones.
  - La cámara sigue a `CameraTarget` con `get_global_transform_interpolated()`, así que tampoco
    salta.
  - No hace falta `reset_physics_interpolation()`, que sí daría un tirón.
- **Teletransporte.** Con un error de más de 3 m o un cambio del contador de teletransporte: sin
  suavizado y con `reset_physics_interpolation()`.
- **El yaw no se suaviza:** sus correcciones son minúsculas.

### 6.7 Por qué converge

- **Mismo cálculo en los dos lados.** `simulate()` es determinista y el cliente aplica las
  mismas entradas cuantizadas que recibe el servidor, partiendo del mismo estado exacto.
- **De dónde salen las diferencias.** Solo hay discrepancias cuando:
  - el servidor usa una entrada sustituta (perdida o tardía);
  - desde la fase 3, hay efectos que solo decide el servidor (golpes, empujones).

  Esos efectos viajarán en un `PlayerState` ampliado, y `equals_exact` los cubre sin cambios.
- **Mismo mundo físico.** No hay colisión entre personajes. Los cuerpos de los demás existen en
  el espacio de física del servidor y no en el del cliente, pero no están en la máscara.
  `test_net_processes` comprueba que tampoco alteran las consultas de Jolt.

---

## 7. Interpolación de los jugadores remotos

- **`RemoteWorld`** recibe SPAWN, DESPAWN y los registros de cada snapshot, y crea una
  `RemotePlayerView` por entidad.
- **`RemotePlayerView`** gobierna una instancia de `player_character.tscn` que nunca llama a
  `simulate()`:
  - `collision_layer = 0`, `collision_mask = 0`;
  - `set_physics_process(false)` y `physics_interpolation_mode = PHYSICS_INTERPOLATION_MODE_OFF`;
  - en `_process` escribe `global_position`, `yaw`, `velocity` y `grounded`;
  - emite `jumped` y `landed` del cuerpo cuando detecta esos flancos en las muestras.

  Así la capa de animación que añade el flujo de arte anima igual a locales y remotos, leyendo
  los mismos campos y señales. Para Eldrun se podrá cambiar por una escena solo visual, más
  ligera, con la misma interfaz.
- **`RemoteInterpolator`:** anillo de 32 muestras `(tick, EntityRecord)` ordenadas por tick.
  Descarta duplicados y muestras más antiguas que la ventana.
- **`sample(t)`**, con `t = render_tick + fracción`:
  - **Entre dos muestras** con el mismo contador de teletransporte: `lerp` de posición y
    velocidad, `lerp_angle` del yaw (correcto al cruzar ±PI) y `grounded` de la muestra más
    cercana.
  - **Si el contador cambia entre las dos**, se queda en la primera hasta que t alcanza la
    segunda (sin interpolar).
  - **Por delante de la última muestra:** extrapola en horizontal con su velocidad hasta
    **6 ticks** (100 ms); después se queda quieto. Extrapolar más engaña al apuntar.
- **Vuelta de los datos tras extrapolar.**
  - Si el salto entre lo dibujado y lo nuevo está entre 5 cm y 1,5 m, se convierte en un
    desfase que decae en `_process` (semivida de 100 ms, tiempo real).
  - Si pasa de 1,5 m, se salta directamente.
- **Aparición y desaparición, según el tiempo de dibujo:**
  - el remoto se muestra cuando `t ≥ spawn_tick`; el SPAWN aporta la primera muestra;
  - desaparece cuando `t ≥ despawn_tick`, no cuando llega el mensaje, para que no se esfume
    antes de lo que se ve.
- **Interpolación lineal.** Basta: el servidor graba cada tick y los snapshots llegan a 30 Hz. Si
  el fantasma de F4 mostrara errores en las curvas, se puede pasar a Hermite con las velocidades
  que ya viajan, sin cambiar el formato.

---

## 8. Bucle del servidor

### 8.1 Orden del tick

`ZoneServer._physics_process` (`process_physics_priority = -100`). Los personajes del servidor
no tienen `_physics_process` propio que simule.

```gdscript
func _physics_process(delta: float) -> void:
	_metrics.begin_tick()
	_transport.poll(_tick)          # autenticación, READY, LEAVE, INPUT_BATCH → InputQueue.push()
	_tick += 1
	var s: int = _tick
	_process_departures(s)          # desconexión o LEAVE → DESPAWN (motivo 1) e id en cuarentena
	for entity: NetEntity in _registry.get_sorted():          # net_id ascendente
		if entity.kind != NetProtocol.EntityKind.PLAYER:
			continue
		var character: PlayerCharacter = entity.get_character()
		var before: Vector3 = character.global_position
		character.simulate(_queue_of(entity).take(s), delta)
		_check_motion(entity, before)                        # |Δpos| > 1,5 m o y < -100
	# Fase 3: acciones validadas contra StateHistory. Fase 4: PNJ, estructuras y captura.
	_process_arrivals(s)            # READY pendientes: alta con el estado «tras s» (ver 3)
	_social.step(s)                 # invitaciones caducadas y PARTY_STATUS (social.md 12.2 y 12.4)
	_record_history(s)              # StateHistory.record() de todas las entidades
	_snapshot_builder.begin(s, _registry.get_sorted())       # codifica cada registro una vez
	_update_interest(s)             # cada peer, cada 6 ticks, escalonado por net_id
	for peer: ServerPeer in _peers_in_world:
		if s % NetProtocol.SNAPSHOT_INTERVAL_TICKS == peer.entity.net_id % NetProtocol.SNAPSHOT_INTERVAL_TICKS:
			_transport.send(peer.peer_id, NetProtocol.CH_SNAPSHOT, _snapshot_builder.build_for(peer))
	_transport.flush()
	_metrics.end_tick(s)
	tick_finished.emit(s)
```

Es un esbozo de la fase 2: el orden normativo, con todos los pasos que se han ido sumando (cerebros de
PNJ, combate con las habilidades, los proyectiles, los efectos y el derribado de la fase 4
([habilidades.md 4.1](habilidades.md#41-orden-del-tick-completa-fuertemd-17)), fuertes, PNJ, el paso social y las
métricas por sección), es el de la cabecera de `scripts/server/zone_server.gd`.

- **Envíos escalonados.** Cada cliente recibe su snapshot en los ticks de la paridad de su
  `net_id`, así que el coste se reparte entre los dos ticks del intervalo. El PARTY_STATUS de cada grupo
  sale igual, en su tick de los 30 del intervalo (`(tick + id del grupo) % 30 == 0`).
- **Altas y bajas.**
  - Las altas van después de simular, así que la primera simulación de un jugador nuevo es la
    del tick `s + 1`, sin desfase de un tick.
  - Las bajas van antes de simular.
- **Comprobación de movimiento** (`_check_motion`). El servidor no acepta estado del cliente, así
  que estas comprobaciones solo detectan errores propios:
  - `|Δpos| > 1,5 m` en un tick: se registra como error de física (la velocidad terminal da
    0,83 m por tick).
  - `y < −100`: reaparece en su punto de aparición y sube su contador de teletransporte.
- **Métricas.** Cada 10 s se registran la duración del tick (p50, p99 y máximo en µs, por
  sección), los bytes por segundo (`host.pop_statistic`), el número de jugadores y el
  porcentaje de entradas sustituidas.
- **Cierre.** `--quit-after-ticks`, `--idle-quit` y `--stop-file` envían un NOTICE con el código 2,
  hacen `flush()` y cierran. `SIGTERM` y `SIGINT` no llegan a GDScript y no cierran de forma
  ordenada (ver [1.3](#13-ajustes-del-servidor-headless)).

### 8.2 Cola de entradas (`InputQueue`)

Una por jugador: anillo de 64 huecos indexado por tick, con el tick como etiqueta.

```gdscript
enum SlotState { EMPTY, RECEIVED, CONSUMED_REAL, SUBSTITUTED, LATE_SEEN }

func push(input: PlayerInput, view_offset_q: int, next_tick: int) -> PushResult:
	var t: int = input.tick
	if t > next_tick + MAX_LEAD_TICKS:                       # 30
		too_early_count += 1
		_note_lead(t - next_tick)                              # se descarta, pero la antelación cuenta
		return PushResult.TOO_EARLY
	var slot: Slot = _slot(t)
	if t <= _last_consumed:
		if slot.tick == t and slot.state == SlotState.SUBSTITUTED:
			slot.state = SlotState.LATE_SEEN                   # tardía: se cuenta una vez
			late_count += 1
			_note_lead(t - next_tick)
			return PushResult.LATE
		return PushResult.DUPLICATE                            # copia redundante ya consumida
	if slot.tick == t and slot.state == SlotState.RECEIVED:
		return PushResult.DUPLICATE                            # gana la primera copia
	slot.set_input(t, SlotState.RECEIVED, input, view_offset_q)
	_note_lead(t - next_tick)                                  # solo la primera copia
	return PushResult.ACCEPTED

func take(tick: int) -> PlayerInput:                         # nunca devuelve null
	var slot: Slot = _slot(tick)
	var input: PlayerInput
	if slot.tick == tick and slot.state == SlotState.RECEIVED:
		input = slot.input
		slot.state = SlotState.CONSUMED_REAL
		_last_real_tick = tick
	else:
		input = _last_applied.duplicate_input()                # repite TODOS los botones
		input.tick = tick
		if tick - _last_real_tick > REPEAT_MOVE_TICKS:         # 6
			input.move = Vector2.ZERO
		slot.set_input(tick, SlotState.SUBSTITUTED, input, -1)
		substitutions_total += 1
	_last_applied = input
	_last_consumed = tick
	return input

func get_ack_tick() -> int:                                  # max(contiguo recibido, último consumido)
	var t: int = _last_consumed
	while t < _last_consumed + MAX_LEAD_TICKS and _slot(t + 1).tick == t + 1 \
			and _slot(t + 1).state == SlotState.RECEIVED:
		t += 1
	return t
```

- **La sustituta nunca inventa flancos.**
  - Repite la máscara completa de la última entrada aplicada. Un JUMP, PRIMARY o DODGE
    mantenido durante una pérdida no reaparece como flanco nuevo cuando llega la siguiente
    entrada real, porque `prev_buttons` ya lo contiene.
  - Una pulsación que empieza durante la pérdida entra como flanco en la primera entrada real
    que la lleve.
  - Lo peor que puede pasar es perder un toque muy corto, que la predicción corrige. Nunca hay
    una acción que el jugador no hizo.
  - Tras 6 ticks sin entradas reales, el movimiento pasa a 0 y se conservan los botones. Un
    cliente desconectado en silencio se queda quieto en 100 ms, en vez de correr hasta que
    venza el timeout de ENet.
  - Qué hace una acción mantenida durante una desconexión larga (un ataque cargado, por
    ejemplo) lo decide la fase 3, sin romper esta regla.
  - **Entradas sustituidas en la fase 3.** Lo resuelve
    [combate.md 3.2](combate.md#32-entradas-sustituidas-cierra-la-nota-de-redmd-82): la sustituta
    lleva el bit `PlayerInput.SUBSTITUTED` (bit 15, fuera de `VALID_BUTTONS`) y, con él, la
    máquina de acciones no cuenta la pulsación, no lanza el golpe fuerte al llegar a la carga
    máxima ni abre ventanas de parada. Ninguna pérdida inventa un golpe ni una parada.
- **Una entrada por tick.** Enviar más no hace correr más: no hay speedhack posible. El servidor
  nunca espera a una entrada.
- **`pop_min_lead()`** devuelve la antelación mínima desde la llamada anterior (`NO_MARGIN` si
  no hay datos) y la reinicia. La usa el snapshot de cada cliente.
- **Las entradas demasiado tempranas también dan margen.** Se descartan (`TOO_EARLY`), pero su
  antelación (saturada a 127) se anota igual. Si el servidor pierde ticks (un parón del proceso:
  Godot solo recupera 8 por fotograma), el cliente pasa a ir más de 30 ticks por delante; sin esta
  medida `TickSync` no recibiría ninguna muestra, nunca se retrasaría y el servidor sustituiría
  todas las entradas para siempre (hallazgo N1 de la revisión de la fase 2).
- **`get_view_offset_q(tick)`** devuelve el `view_offset_q` de la entrada real de ese tick, o −1
  si fue sustituida. Lo usa la fase 3.

---

## 9. Entidades y replicación

### 9.1 Entidades de red

- **`NetEntity`** (servidor):
  - `net_id` u16, que asigna `NetEntityRegistry`; un id liberado queda en cuarentena 600 ticks
    (10 s) antes de reutilizarse;
  - `kind`, `realm`, `spawn_tick`, `owner_peer`, `display_name`, `flags`, el nodo y
    `teleport_counter`;
  - flag `ALWAYS_RELEVANT`, para los objetos que ve toda la zona;
  - su vida tal y como la ven los snapshots: `health_q` (el último byte del registro) y el bloque
    extra propio (`health`, `max_health`, `status`, `respawn_tick`). Quien lleva la vida (el
    `Combatant` de la fase 3) los actualiza cada tick con `set_health_view()`; sin él, la
    entidad está sana (`health_q` 255, 1000 de 1000).
- **Registros.** `NetEntity.encode_record()` escribe su registro directamente en un búfer, sin
  crear objetos.
- **Orden de simulación.** `NetEntityRegistry.get_sorted()` devuelve las entidades por `net_id`
  ascendente, con una caché que se invalida en cada alta y cada baja. Ese es el orden fijo de
  simulación.

### 9.2 Dos estilos de replicación

1. **Por flujo** (jugadores, PNJ, proyectiles):
   - registro de tamaño fijo en el SNAPSHOT, no fiable;
   - filtrado por interés y con prioridad;
   - interpolado en el cliente y guardado en el historial del servidor.
2. **Con estado** (fortalezas, puertas, estandartes, braseros; fase 4):
   - OBJECT_STATE fiable, completo al entrar y después solo cuando cambia;
   - para toda la zona (`ALWAYS_RELEVANT`), porque `mundo.md` exige ver en el mapa el estado de
     todas las fortalezas;
   - los valores continuos viajan como fórmula: la captura es
     `(start_tick, rate, progress_at_start)` y el cliente la calcula.

Añadir un tipo de entidad supone tres cosas: un códec de registro en `EntityRecord`, una vista en
el cliente y subir `PROTOCOL_VERSION`.

### 9.3 Construcción del snapshot

**`SnapshotBuilder.begin(s, entities)`** se ejecuta una vez por tick. Codifica **cada registro
una sola vez** en un búfer compartido y guarda el offset de cada `net_id`. Codificar es
O(entidades); por cliente solo hay copias de memoria.

**`build_for(peer)`:**

1. Escribe la cabecera con:
   - `input_ack_tick = queue.get_ack_tick()`;
   - `input_margin = queue.pop_min_lead()`;
   - `substitutions = queue.substitutions_total & 0xFFFF`;
   - el estado propio (`character.get_state().encode()`), su contador de teletransporte y el
     bloque extra propio (vida, vida máxima, estado y tick de reaparición de su `NetEntity`).
2. Reúne las candidatas: las entidades de `peer.relevant` salvo la propia. A cada una le suma
   `peer.priority[id] += interest_policy.priority_weight(observer, entity)` (en la fase 2, 1,0).
3. Si caben todas en 1200 B, las escribe todas (el caso normal de la fase 2). Si no, elige las
   de mayor prioridad, desempatando por `net_id`, hasta llenar el presupuesto: `sort_custom` en
   la fase 2, y cubos o C++ en Eldrun si la medida lo pide.
4. Pone a 0 la prioridad de las escritas y agrupa los registros por `kind` en secciones.

**Garantía:** con N candidatas y C plazas, ninguna pasa más de ⌈N/C⌉ snapshots sin enviarse. Con
63 jugadores visibles y 50 plazas (la capacidad de [5.5](#55-servidor--cliente) con el estado de
111 B de la v6; 52 con el de 69 B), cada entidad sale al menos uno de cada dos snapshots (con los ~10
PNJ del fuerte, 73 ajenos, también; pasa a uno de cada tres con más de 100). Lo comprueba
`test_snapshot_builder`.

### 9.4 Lado del cliente

- **SPAWN propio:** `NetClient` instancia el `PlayerCharacter` local y arranca la predicción.
- **SPAWN ajeno:** `RemoteWorld.on_spawn()`, que crea la vista con su primera muestra.
- **DESPAWN:** `view.schedule_despawn(tick)`.
- **SNAPSHOT:** para cada registro de un `net_id` conocido y dentro de
  `[spawn_tick, despawn_tick)`, `view.push(server_tick, record)`.

---

## 10. Historial para la compensación de latencia

- **`StateHistory`** (servidor) guarda, por entidad, una pista de 64 ticks (~1 s):
  - posición en `PackedVector3Array`, yaw en `PackedFloat32Array`, flags en `PackedByteArray` y
    etiquetas de tick en `PackedInt64Array` (los ticks son u32: ver [4.1](#41-tick-del-servidor-y-regla-de-aplicación));
  - indexada por `tick % 64`;
  - se crea al dar de alta la entidad y se escribe en el sitio cada tick, sin asignar memoria;
  - guarda valores sin cuantizar y se graba tras cada tick, haya interés o no.
- **`sample(net_id, tick: float)`** interpola linealmente entre los dos ticks que rodean ese
  instante. Si el contador de teletransporte cambia entre ellos, devuelve la muestra anterior.
- **Fase 3.** Para un ataque cuya entrada es del tick T:
  ```
  view_tick = T − view_offset_q / 16
  allowed   = min(MAX_REWIND_TICKS (24),
                  rtt_ticks + lead(T) + clamp(ceil(interp_delay_q / 8), 4, 12) + 2)
  si view_offset_q / 16 > allowed + 8: el golpe no se prueba (sospecha + 1)
  view_tick = clamp(view_tick, T − allowed, T)
  ```
  - **Holgura del rechazo** (`CombatResolver.REWIND_REJECT_SLACK_TICKS` = 8; revisión de la fase 4, lente
    «trampas»): lo que pasa del tope hasta `allowed + 8` se **recorta** al tope; solo por encima se rechaza y
    suma sospecha. Antes era `allowed + 1` y un cliente honrado con un tirón del proceso o pocos FPS lo pasaba:
    cuando el motor encadena varios pasos de física en un fotograma (hasta `max_physics_steps_per_frame` = 8),
    el paso k declara la vista del último fotograma dibujado (`RemoteWorld.get_last_drawn_render_tick`, lo que
    el jugador vio de verdad), k ticks más vieja, y las entradas de ese fotograma llegan con menos antelación
    (`lead(T)` y el tope bajan). El golpe entero se rechazaba (o la flecha salía inofensiva) y sumaba sospecha:
    con un `SIGSTOP` de 150–200 ms al proceso del bot «rate» de `test_net_processes`, de 2 a 5 golpes
    rechazados por pasada, la firma exacta de su fallo intermitente (`s=647`, `vq=385` con un tope de 23); con
    la holgura, 0 en cuatro pasadas. Quien declara de más se queda en el tope, como un honrado, sin ganar nada;
    el tramposo `rewind` (40 ticks) sigue por encima de `24 + 8`. Medir en el cliente con el render del propio
    paso no bastaría (no cubre la caída de la antelación) y falsearía lo que vio el jugador. De rebote, un
    honrado con más RTT del que cubre el tope de 24 (unos 200 ms) ya no ve sus golpes rechazados hasta los 32
    ticks: se prueban con 24, sin sospecha (pueden fallar contra quien se mueve; no medido). La sospecha solo
    sale en el informe (`ZoneServer`): no expulsa ni sanciona a nadie.
  - **`ceil` en la interpolación** (misma revisión): truncar `interp_delay_q / 8` perdía hasta 7/8 de tick de
    la vista de un honrado.
  - **`rtt_ticks`** lo mide el servidor sin reloj: es el mínimo, en los últimos 120 ticks, de
    `s − ack_snapshot_tick` al llegar cada INPUT_BATCH, **acotado por una fuente que el cliente no
    controla** (hallazgo S4): `ceil(PEER_ROUND_TRIP_TIME · 60 / 1000) + retardo máximo del
    `NetSim` del propio servidor + 3` (`ZoneServer.RTT_SLACK_TICKS`: los snapshots salen cada 2
    ticks y hay que procesarlos). Sin la cota, un cliente que atrasara 20 ticks su
    `ack_snapshot_tick` (sin lag real) se hacía pasar por alguien con 350 ms de RTT y obtenía los
    24 ticks de rebobinado. El `--net-sim` del servidor sí cuenta (es retardo real para él); el del
    cliente no: en producción equivaldría a fingir lag, así que para probar con lag simulado se usa
    el del servidor.
  - **Con jitter, el mínimo no basta (K5).** La vista de un jugador honrado va atrás
    `lead + RTT de ese momento + edad del snapshot + interpolación`; el mínimo de la ventana se queda
    por debajo del viaje de un tick cualquiera (con `rtt=150,jitter=30` el mínimo medido es 7 ticks y
    el máximo 13-14), así que con el mínimo solo el tope rechazaba un 20 % de los ticks activos de un
    bot honrado (y le sumaba sospecha). Por eso el tope usa `rtt = max(mínimo, máximo)` de la misma
    ventana, **con la misma cota independiente** (`ServerPeer.rtt_peak_ticks`): atrasar los acks no da
    más que `PEER_ROUND_TRIP_TIME + retardo del NetSim + 3`, con mínimo o con máximo.
  - **`lead(T)`** es la antelación medida de esa entrada (se cancela con la del cliente: la entrada que
    llega tarde por la red cuenta con menos antelación y con más viaje), **acotada** por la habitual del
    cliente más 3 (`InputQueue.get_typical_lead`: la mediana de las antelaciones de primera copia de las
    entradas reales de los últimos 60 ticks) y por 8. Sin cota, la antelación de cada entrada la escoge
    el cliente: mandar solo las entradas de su golpe 14 ticks antes subía el tope de 12 a 24 con RTT de
    LAN (revisión de la fase 3, R1).
  - **El rebobinado se fija una vez por golpe** (primer tick activo) y avanza con el tick. Para la
    defensa retroactiva (invulnerabilidad, parada, bloqueo) el servidor mira atrás al menos
    `rtt_floor + 4 − 2` ticks (`rtt_floor` = el RTT de ENet, `ServerPeer.rtt_floor_ticks`), aunque el
    cliente pida menos.
  - **`interp_delay_q`** no pasa de 96 (12 ticks × 8, el máximo del `InterpolationClock`): el
    servidor lo limita y suma un aviso a quien envíe más (`NetProtocol.MAX_INTERP_DELAY_Q`). La
    fórmula ya lo acota con `clamp(…, 4, 12)`.
  - **Fingir lag no da más rebobinado** más allá de lo que da lag de verdad: con acks atrasados (cota
    del RTT), antelación (acotada por la habitual y por 8) o rebobinado por tick (fijado por golpe). Queda
    la interpolación declarada (`interp_delay_q`, hasta 96 sin aviso), que el servidor no puede
    comprobar: un tramposo con todas sus entradas adelantadas y esa declaración llega al tope de 24
    ticks aunque su RTT sea de LAN. El tope es la cota del daño posible.
  - **Por qué 24 ticks.** El rebobinado real es RTT + margen + retardo de interpolación, unos 20
    ticks con 200 ms de RTT. El tope de 24 ticks (400 ms) cubre hasta ~250 ms de RTT con el
    retardo normal. **Medido en K5:** con 150 ms de RTT y 30 ms de jitter los bots piden de 20 a
    22,5 ticks (antelación 5-8, interpolación 6-7, viaje 9-11), de modo que el tope de 24 cubre
    como mucho unos 170-180 ms de RTT con el margen de `TickSync` y el retardo de interpolación de
    hoy, no 250 ms: con 200 ms de RTT un jugador honrado ya choca con el tope (decisión de diseño
    pendiente: subir `MAX_REWIND_TICKS` o reducir el margen de `TickSync`).
  - **Prueba del golpe.** La cápsula se reconstruye a partir de la muestra y se prueba con
    matemática (cápsula contra arco y rayo contra cápsula), o con `intersect_shape` sobre una
    forma suelta. Nunca se mueven cuerpos hacia atrás.
  - **Línea de visión:** raycast contra el mundo actual.
- **La fase 2 ya graba el historial y lo prueba.**

---

## 11. Gestión de interés

- **Gancho.** `InterestPolicy` tiene dos métodos:
  - `is_relevant(observer, entity, was_relevant) -> bool`;
  - `priority_weight(observer, entity) -> float`.
- **Cuándo se evalúa.** El servidor recalcula el conjunto relevante de cada peer cada 6 ticks,
  escalonado (`(s + net_id) % 6 == 0`), y además en cada alta.
  - El resultado se guarda en `ServerPeer.relevant`.
  - Cada cambio genera un SPAWN o un DESPAWN con motivo 0.
  - Las entidades con `ALWAYS_RELEVANT` no pasan por la política.
- **Fase 2:** la política base devuelve siempre `true` y 1,0. El presupuesto de 1200 B y la
  prioridad ya funcionan, así que 64 jugadores visibles no rompen el tope.
- **Eldrun:** `GridInterestPolicy`.
  - Rejilla uniforme de 64 m (`Dictionary[Vector2i, PackedInt32Array]`); una entidad solo
    cambia de lista al cambiar de celda.
  - Entra a 200 m y sale a 230 m (histéresis).
  - El peso depende de la distancia (`clamp(1 − d/R, 0,1, 1)`), con más peso si la entidad
    combate con el observador o lo tiene como objetivo.
  - Ver [15](#eldrun).

---

## 12. Seguridad de la fase 2

El servidor nunca acepta estado del cliente, y todo valor decodificado está acotado.

| Medida | Detalle |
|---|---|
| Ventana de entradas | Se aceptan los ticks en `(último consumido, s + 30]`. Gana la primera copia aunque la segunda sea distinta |
| Una entrada por tick | No hay speedhack; las sustitutas nunca inventan acciones |
| Botones | `buttons &= VALID_BUTTONS` (bits 0–12 desde la v6; 0–8 hasta la v5) |
| Lotes | Ticks consecutivos por formato; `count` de 1 a 8 |
| Limitador por peer (`RateLimiter`, en ticks) | No fiables: 2 por tick (120/s), ráfaga de 30. Fiables: 10/s, ráfaga de 20. Bytes: 16 KB/s, ráfaga de 4 KB. Lo que sobra se descarta y suma un aviso. Con crédito por parón (ver abajo) |
| Avisos | Paquete malformado, tipo inesperado para el estado de la sesión o exceso de ritmo. 50 avisos en 600 ticks → NOTICE de expulsión y desconexión |
| Enfriamiento tras una expulsión | 1800 ticks (30 s): su IP (las IPv6, por /64) o, desde loopback, su nombre normalizado reciben `REJECT TOO_MANY_CONNECTIONS` nada más conectar (o al llegar el HELLO, para el nombre) |
| Conexiones por IP | 4 como mucho (`--max-per-ip`), salvo loopback, para que funcionen los bots locales. Se comprueba al conectar, no solo con el HELLO; las IPv6 cuentan por /64 ([3](#3-conexión)) |
| HELLO a tiempo | 90 ticks desde que conecta; si no, se corta la conexión ([3](#3-conexión)) |
| Paquetes ajenos al protocolo | Antes del HELLO solo se admite autenticación; después, solo RAW. Lo demás se descarta sin error del motor y cada paquete suma un aviso ([2](#2-transporte-y-canales)) |
| Reino | Validado contra la zona. En la fase 2 lo declara el cliente (`DevAuthProvider`); desde la fase 5 sale del personaje (la reclamación de plataforma.md §5) y el campo de HELLO se ignora |
| Rebobinado | Acotado por lo medido ([10](#10-historial-para-la-compensación-de-latencia)); el RTT que declara el cliente con sus acks se acota con el de ENet más el simulador del servidor + 3 ticks |
| Comandos de depuración | Solo con `--debug-commands` |
| Chat (protocolo 5) | Cada CHAT_SEND cuenta como un mensaje fiable más y además tiene sus cubos por peer, que gasta antes de sanear: decir, zona y grupo, 1 mensaje/s con ráfaga de 5; susurro, 1/s con ráfaga de 3 y 5 destinatarios nuevos por minuto; un texto igual al anterior en 10 s y al mismo sitio se descarta. Los diez primeros descartes de cada 600 ticks son gratis y cada uno de los siguientes suma un aviso: desde unos 6 mensajes por segundo sostenidos (el transporte deja pasar 10 sin avisos) se llega a la expulsión. Las invitaciones de grupo, igual. El servidor sanea el texto (también invisibles y marcas combinantes) y nunca manda a un cliente el de otro reino ([social.md](social.md#12-implementación-fase-4)) |

**Crédito por parón.** Los limitadores cuentan en ticks del servidor, y el tick no avanza mientras
el proceso está parado. Si el servidor pierde `k` ticks (un parón, una pausa de la máquina virtual;
Godot solo recupera 8 por fotograma), los clientes honrados siguen mandando un lote por tick y todo
llega junto en el primer poll, con el tick sin avanzar: el cubo no se recargaría, solo pasarían los
30 más antiguos y el resto (los más nuevos) sumaría avisos hasta expulsar al cliente (hallazgo N2).
Por eso `ZoneServer` mide con un reloj entero de ticks reales (`Time.get_ticks_usec()`, solo en
`scripts/server/`) cuántos ticks se han perdido entre dos polls y, antes de `poll()`, llama a
`ServerPeer.grant_stall_credit(tick, perdidos)`: `RateLimiter.grant()` recarga primero y suma
después `tasa × perdidos` sin tope, y la siguiente recarga vuelve a limitar el cubo a su ráfaga.
Como el reloj es entero, lo concedido en total no supera los ticks que han transcurrido de verdad.
Límites: el crédito cubre lo que cabe en un poll (ENet entrega todo lo pendiente del socket, pero
un parón de varios segundos desborda de todos modos el búfer del sistema), y una ráfaga de red sin
parón del servidor (un corte de Wi-Fi que entrega de golpe más de 30 lotes) sigue contando como
exceso de ritmo.

**Enfriamiento tras una expulsión (hallazgo S6).** Los avisos y los cubos viven en el `ServerPeer`,
que se crea nuevo y lleno en cada conexión: un cliente expulsado volvía en un RTT con 0 avisos y las
ráfagas llenas (medido: 10 expulsiones por segundo con el mismo nombre y la misma IP, sin ningún
REJECT). Ahora `ZoneServer._kick` apunta una entrada `_kick_until` de 30 s:

- **Clave.** `ip:<grupo>` (`ServerAuth.address_group`) si la IP no es loopback; si lo es (no hay tope
  por IP), `name:<nombre normalizado>` con el nombre que ya había dado. Los kicks que no son culpa
  del cliente («no queda sitio en la zona») no la apuntan.
- **Dónde se comprueba.** La IP, en `peer_authenticating` (antes que el tope por IP); el nombre, al
  llegar el HELLO. En los dos casos se contesta `REJECT TOO_MANY_CONNECTIONS` (un código que ya
  existía: no sube `PROTOCOL_VERSION`).
- **Purga.** Al apuntar una expulsión se borran las entradas vencidas, así que el diccionario no
  crece más que las expulsiones de los últimos 30 s (`get_cooldown_count()`).
- **Límite.** Es un freno, no un veto: el atacante con varias IP o con otro nombre desde loopback
  sigue entrando, y quien comparte IP con el expulsado (una red con NAT) espera los mismos 30 s. El
  veto por cuenta llega con las fases 5 y 6. Lo mismo vale para los cubos sociales (`ChatPeerState`):
  son por conexión hasta la fase 5 ([social.md](social.md#127-decisiones-y-pendiente-de-la-fase-4)).

**Nombres en el HELLO (fase 4).** Como el cliente elige el nombre, el `REJECT NAME` por un nombre que ya
lleva alguien en la zona dice si ese nombre está conectado, sea del reino que sea; junto con el «no está
conectado» del susurro delata a un enemigo. No se tapa en la fase 4 porque el cliente también elige su
reino (`DevAuthProvider`) y puede entrar directamente en el del enemigo; desde la fase 5 el nombre y el
reino salen del personaje del billete y ese rechazo desaparece (detalle en
[social.md](social.md#127-decisiones-y-pendiente-de-la-fase-4)).

**Fases 5 y 6:**

- **`TicketAuthProvider`** con `HandoffTicket` de **52 B** (formato y vector de prueba en
  [plataforma.md](plataforma.md) §5.1; sustituye al de 47 B que se preveía aquí):
  - campos: versión, clave, mundo, `ticket_id`, `character_id`, huella de la zona, canal, reino
    (informativo), punto de llegada, flags, emisión y caducidad (+10 s);
  - firma HMAC-SHA256 truncada a 16 B con una clave con identificador (rotable);
  - verificación con `Crypto.constant_time_compare`; el un solo uso lo garantiza la plataforma al
    reclamar el billete (`authenticate` devuelve `PENDING` y el peer espera en `VERIFYING`), y el
    reino sale del personaje, no del billete.
- **DTLS** (`host.dtls_server_setup(TLSOptions.server(…))`), obligatorio antes de las pruebas
  públicas: en staging y producción la plataforma no registra una zona sin certificado
  (plataforma.md §10.2).

El hueco ya existe en HELLO y la interfaz `AuthProvider` ya está.

---

## 13. Herramientas de depuración

**`NetSim`** (compartido, en ticks, con su propio `RandomNumberGenerator` con semilla):

- **Formato:** `--net-sim=rtt=120,jitter=20,loss=5,dup=0,seed=1`, en ms, ms, % y %.
- **Retardo por sentido:** `rtt/2 ± jitter` (uniforme), en ticks redondeados, con una
  resolución de 16,7 ms.
- **Pérdida y duplicados:** solo en los canales no fiables (1 y 2). Los fiables y la
  autenticación solo se retrasan y mantienen el orden FIFO por (peer, canal): tirar paquetes a
  nivel de aplicación rompería la fiabilidad de ENet.
- **Dónde se aplica.** `NetTransport` lo aplica a la salida y a la entrada (con las semillas
  `seed` y `seed + 1`), así que ponerlo en un solo lado simula el RTT completo; en los dos, lo
  duplica.
  - El canal de un paquete entrante se deduce de su tipo (`NetProtocol.channel_for_type`).
  - Los snapshots desordenados por el jitter los ordena el cliente, como se explica en
    [6.2](#62-tick-del-cliente).
- **Es reproducible:** misma semilla, misma secuencia.

**`NetDebugOverlay`** (cliente):

- **F3:**
  - RTT de ENet y RTT en ticks (el de ENet no incluye `NetSim`), pérdida, KB/s de subida y de
    bajada;
  - `input_margin`, margen objetivo, ajustes de `TickSync` por minuto, sustituciones;
  - correcciones por minuto, última y máxima corrección, ticks vueltos a simular;
  - retardo de interpolación, jitter, entidades visibles y bytes medios por snapshot.
- **F4:** fantasma translúcido en la posición del último estado propio del servidor y marcas en
  las muestras sin interpolar de los remotos.
- **Junto al HUD.** En el cliente en red, F3 alterna a la vez este panel (a la derecha) y el panel de
  depuración del HUD del sandbox (a la izquierda): `OnlineMain` los empieza ocultos y el overlay no
  marca el evento como gestionado. El sandbox sin argumentos no cambia.

**Servidor:**

- `ServerMetrics` mide cada sección del tick con `Time.get_ticks_usec()` (en `scripts/server`
  está permitido).
- `Performance.add_custom_monitor("eldmark/…")` para la depuración remota desde el editor.
- `--report=<json>` al cerrar y, mientras corre, cada 600 ticks (10 s): si matan al servidor
  (`SIGTERM`, `SIGINT`) queda el de la última marca, con `"closed": false`. Construirlo cuesta
  unos milisegundos con muchas fichas; la escritura va dentro del tick que cumple la marca.
  - **Memoria acotada** (hallazgo S3). Cada alta dejaba para siempre su ficha en el informe con su
    `InputQueue`, su `ServerPeer` y su `NetEntity` (unos 70 objetos y 80 KB por ciclo: ~3 GB/h con
    un cliente que entra y sale en bucle). Ahora la ficha suelta esas referencias al irse el jugador,
    `player_list` conserva solo las últimas 1000 fichas (`max_logged_players`) y `kicks`, las
    últimas 200 expulsiones (`max_logged_kicks`). Lo anterior se resume en `players.archived`,
    `strikes.kicks_total` y en los totales de `inputs`/`players.fake`. Nunca se saca del anillo la
    ficha de quien sigue dentro.

**`--state-log=<csv>`:**

- en el servidor, `tick,net_id,substituted,hex(PlayerState)` por tick y jugador;
- en un bot, `server_tick,hex(predicho),hex(servidor)` por snapshot;
- `tools/compare_state_logs.gd` los cruza.

**Comandos** (con `--debug-commands`): `teleport`. En Windows también sirve clumsy para probar
con UDP real.

---

## 14. Presupuesto de ancho de banda y CPU

Sobrecoste por paquete UDP: unos 40 B (IPv4 20, UDP 8, ENet ~12).

| Flujo | Cálculo | Total |
|---|---|---|
| Subida, normal (R = 4) | (11 + 4·10 + 40) B × 60/s | ~5,5 KB/s |
| Subida, con pérdida (R = 8) | (11 + 8·10 + 40) B × 60/s | ~7,9 KB/s |
| Bajada, 10 visibles (v6) | (136 + 10·21 + 40) B × 30/s | ~11,6 KB/s (~10,3 con la v5) |
| Bajada, 30 visibles (v6) | (136 + 30·21 + 40) B × 30/s | ~24,2 KB/s (~22,9 con la v5) |
| Bajada, ≥ 50 visibles (tope, v6; ≥ 52 con la v5) | (1186 + 40) B × 30/s | ~36,8 KB/s (~295 kbit/s) |
| Proyectiles (v6) | (32 + 8 + ~10 de ENet) B por flecha y destinatario; 20 flechas por segundo a la vista | ~1 KB/s |
| Salida del servidor, 64 jugadores y todos visibles | 64 × 37 KB/s (+ los proyectiles, v6) | ~2,4 MB/s (~19 Mbit/s); ~2,5 MB/s con flechas |
| Entrada del servidor, 64 jugadores | 64 × 5,5 KB/s | ~350 KB/s |
| Eldrun, 300 jugadores sin más palancas | 300 × 37 KB/s | ~11 MB/s (~89 Mbit/s): demasiado |

La bajada de esta tabla es la del protocolo 6 ([habilidades.md 5.6](habilidades.md#56-ancho-de-banda)):
136 B son los 134 de la cabecera con estado (111 B) y bloque extra propios más los 2 de la cabecera de la
sección; con la v5 eran 94 (92 y 2). Por debajo del tope, el estado de 111 B suma +42 B × 30/s = +1,26 KB/s
por cliente; en el tope el paquete ya iba lleno y lo que se pierde son 2 registros por snapshot (50 en vez de
52). A la bajada se suman los ENTITY_EVENT, unos 27 B por destinatario y golpe
([combate.md 6](combate.md#6-protocolo-tec-13-protocol_version--2)), y los SPAWN y DESPAWN de los proyectiles
(v6). Las medidas de abajo son de la fase 2 (registro de 20 B y estado de 35 B), de las fases 3 y 4 (estado de 69 B)
y, la última, de la v6 con el kit de la fase 4 (H5, [habilidades.md 7.3](habilidades.md#73-pruebas-cada-una--30-s)): con
el estado de 111 B, cada cliente baja 36,1 KB/s con 64 combatientes (35,3 con la v5).

**CPU (fase 2):** el p99 del tick debe quedar por debajo de 8 ms (la mitad de los 16,7 ms) con
64 bots agrupados. Se mide por sección: red, simulación (µs por personaje), historial,
snapshots. Ese dato es el primero del límite de jugadores por batalla que pide `vision.md`.

**Medidas de la fase 2** (`tools/load_test.gd --matrix`, TEC-11, revisadas tras la revisión adversarial).
Vado Gris con su Terrain3D, el servidor y el enjambre `--bots` en la misma máquina de 4 núcleos (sin más
carga), GDScript sin optimizar, **120 s de medida por escenario**. Los falsos son `--fake-players`; los
bots, clientes reales por ENet en loopback que reciben snapshots (el de «rtt=100» con el simulador de red
`--net-sim=rtt=100`; los demás, sin retardo). Tick en ms, p50 / p99 / máximo de los últimos 34 s de
régimen. Sustituidas: entradas de los bots que el servidor tuvo que sustituir, en toda la sesión y dentro
de la ventana de medida (sin el arranque, ver más abajo):

| Escenario | Jugadores | Tick | `sim` p50 | `snapshot` p50 | Bajada por cliente | Sustituidas (sesión / ventana) |
|---|---|---|---|---|---|---|
| agrupado, 64 falsos y 2 bots | 66 | 4,9 / 8,2 / 20,0 | 4,0 | 0,5 | 35,2 KB/s | 0,07 % / 0,00 % |
| agrupado, 64 falsos y 10 bots | 74 | 6,2 / 9,7 / 17,2 | 4,3 | 1,2 | 35,3 KB/s | 0,03 % / 0,00 % |
| agrupado, 64 falsos y 50 bots | 114 | 15,3 / 26,5 / 36,5 | 6,4 | 7,0 | 34,9 KB/s | 0,05 % / 0,00 % |
| **agrupado, 64 falsos y 10 bots, rtt=100** | 74 | 6,5 / 10,6 / 21,6 | 4,5 | 1,3 | 35,3 KB/s | **0,36 % / 0,00 %** |
| disperso, 64 falsos y 10 bots | 74 | 6,8 / 11,4 / 20,5 | 4,9 | 1,3 | 35,3 KB/s | 0,03 % / 0,00 % |
| altas y bajas (1 por segundo), 64 falsos y 10 bots | 74 | 6,7 / 10,7 / 15,4 | 4,6 | 1,5 | 35,3 KB/s | 0,08 % / 0,00 % |
| agrupado, 128 falsos y 10 bots | 138 | 11,3 / 19,7 / 24,2 | 8,3 | 2,1 | 35,2 KB/s | 0,03 % / 0,00 % |
| agrupado, 256 falsos y 10 bots | 266 | 15,9 / 24,8 / 79,7 | 15,1 | 0,0 | 25,4 KB/s | 97,3 % / 100 % |
| disperso, 256 falsos y 10 bots | 266 | 17,5 / 27,1 / 41,8 | 16,7 | 0,0 | 24,0 KB/s | 97,2 % / 100 % |

- **Sustituidas, con 100 ms de RTT (el criterio de §16).** Con 64 falsos agrupados y 10 bots con
  `rtt=100`: 277 de 76 012 entradas (**0,36 %** de la sesión, menos de un 1 %) y ninguna dentro de la
  ventana de medida. Cada bot pierde unas 27 entradas (19–20 llegan tarde) en los primeros segundos,
  mientras `TickSync` busca su antelación: es un coste fijo de arranque, así que el porcentaje de la
  sesión depende de cuánto dure (con 30 s sale un 1,2 %, con 120 s un 0,36 %) y el de la ventana de medida
  (de la primera línea de métricas tras entrar los bots a la última antes de que se vayan, restando lo
  acumulado al empezar) es el que mide el régimen. **Criterio cumplido.** Sin retardo y hasta 138
  jugadores, como mucho un 0,08 % en la sesión. Ningún escenario tuvo avisos, expulsiones ni errores de
  física. (Los primeros resultados de esta sección, de 30 s y sin retardo, decían 0,09–0,16 %: no medían el
  criterio, que pide 100 ms de RTT.) Pendiente de mirar: el arranque con 100 ms de RTT empieza con poca
  antelación (19–20 tardías por bot).
- **128 y 256 jugadores falsos.** Con 138 jugadores el tick de mediana ocupa 11,3 de los 16,7 ms y el p99
  (19,7 ms) los rebasa en alguna ocasión, pero el servidor aguanta los 60 ticks/s (60,1) y no sustituye
  entradas. **Con 266 el servidor no sostiene el tiempo real**: `simulate()` y su sección ocupan 15–17 ms de
  mediana, el servidor va a 44–47 ticks/s y casi todas las entradas de los clientes reales (el 97 %) se
  sustituyen; la mediana de `snapshot` y de `net` cae a unos microsegundos (probablemente porque el
  servidor encadena ticks para recuperar el retraso; no se ha comprobado) y la bajada por cliente cae a
  24–25 KB/s. Es un resultado de CPU del servidor, no de la red: 266 jugadores en un proceso de GDScript sin
  optimizar quedan fuera de lo que esta fase promete.
- **Ancho de banda.** Con 57 o más jugadores visibles cada snapshot llena el paquete (1191 B) y cada cliente
  baja unos 35 KB/s (criterio: 37 KB/s como mucho) y sube de 2,3 a 3,7 KB/s (3,7 con 100 ms de RTT).
  Dispersos o agrupados da igual: sin interés por rejilla todo el mundo ve a todo el
  mundo.
- **`simulate()` por personaje: 42 a 50 µs** (medido alrededor de cada llamada), por encima de los 25 µs que
  marcan la palanca 6. La sección `sim` entera (cola de entradas, cerebro de los falsos, comprobación de
  movimiento) sale a unos 57–66 µs por personaje: con 64 jugadores son ~4 ms de los 16,7 ms del tick.
- **Construir un snapshot** de 57 registros cuesta de 250 a 730 µs (la codificación común de los registros
  del tick se reparte entre los snapshots de ese tick, así que sale más caro con pocos clientes y con el
  servidor saturado). Con N clientes reales se construyen N/2 por tick: con 50, la sección `snapshot` llega
  a 7,0 ms de mediana y es lo que satura el tick (palancas 2 a 5).
- **Criterio de CPU no cumplido.** El p99 del tick con 64 falsos y 2 bots (66 jugadores) es de 8,2 ms y con
  64 falsos y 10 bots (74) de 9,7 ms (criterio: menos de 8 ms con 64 jugadores), con medianas de 4,9 y
  6,2 ms; la serie anterior de 30 s, con exactamente 64 jugadores, daba 8,7 y 9,6 ms. Con 74 jugadores
  pasa de 10 ms (hasta 11,4 ms dispersos) y con 114 (50 reales) el tick de mediana ya ocupa 15,3 ms de los
  16,7: el servidor no aguanta 50 clientes reales más 64 falsos. El primer cuello es `simulate()` en GDScript
  (palanca 6, ~44 µs por personaje frente a los 25 µs de umbral) y, con muchos clientes reales, el
  `SnapshotBuilder`.

**Medidas de la fase 3: refriegas de combate** (`tools/load_test.gd --brawl`, TEC-15, K5). Vado Gris con
su Terrain3D, el servidor y un enjambre de 10 bots reales (`--bots=10 --bot-brain=combat`: reciben
snapshots y ENTITY_EVENT y mandan su `view_offset_q`, así que el servidor rebobina de verdad) en la misma
máquina de 4 núcleos, **en reposo** (carga media de 0,2 al empezar y ningún otro Godot en marcha). El resto
de los combatientes son `--fake-players` con `--fake-brain=combat` en un corro en campo abierto a 18 m del
campamento de Vardheim (`--fake-center=0,-96`; la zona segura del campamento les impediría pelear), la
mitad de cada reino. **60 s de medida** tras 12 s de aproximación. Tick en ms, p50 / p99 / máximo; el resto
de columnas, p50 de cada sección:

| Combatientes | Tick | `sim` | `combat` | `combat_resolve` | `combat_events` | `snapshot` | Bajada por cliente | Sustituidas (ventana) | Rebobinados rechazados |
|---|---|---|---|---|---|---|---|---|---|
| 32 (22 falsos y 10 bots) | 4,9 / 8,9 / 17,2 | 3,1 | 0,35 | 0,016 | 0,18 | 0,84 | 23,6 KB/s | 0,00 % | 0 |
| **64** (54 y 10) | 9,4 / 15,9 / 24,9 | 6,5 | 0,77 | 0,094 | 0,17 | 1,41 | 35,3 KB/s | 0,00 % | 0 |
| 128 (118 y 10) | 17,5 / 30,0 / 36,3 | 13,3 | 1,41 | 0,067 | 0,19 | 2,16 | 31,4 KB/s | 0,10 % | **153 (los 10 bots)** |

`combat_resolve` (golpes con rebobinado) y `combat_events` (armar y mandar los ENTITY_EVENT) cuelgan de
`combat` y se miden aparte desde K5; `snapshot` sube a medida que hay más clientes reales que servir,
pero aquí son siempre 10.

- **Primer límite de jugadores por batalla con combate: 64.** Con 64 combatientes el tick de mediana ocupa
  9,4 ms de los 16,7, el p99 (15,9 ms) todavía cabe en un tick, no se sustituye ni una entrada en régimen y
  no se rechaza ningún rebobinado; cada cliente baja 35 KB/s (criterio: 37). Con 128 el servidor deja de
  sostener el tiempo real: la mediana (17,5 ms) ya rebasa el tick, el p99 llega a 30 ms y los 10 bots
  honrados reciben entre 12 y 18 rechazos de rebobinado cada uno (153 de 10 239 comprobaciones, con su
  sospecha). Es un síntoma de la saturación (con 32 y 64 no hay ni uno): un servidor que no cumple sus
  ticks estira el viaje de ida y vuelta que miden los clientes y su desfase de vista sale del tope. No se
  ha investigado la causa exacta; la consecuencia práctica es que **no hay que dejar entrar a más de 64 en
  una batalla**, porque pasado el límite el rebobinado empieza a fallar a los honrados. Interpolando entre
  las tres medidas, la mediana del tick llega a los 16,7 ms hacia los 120 combatientes y el p99 a 16,7 ms
  hacia los 66.
- **El criterio de CPU de la fase 2 (p99 < 8 ms) no se cumple con combate más que hasta unos 28
  combatientes** (32 ya sale a 8,9 ms): el objetivo de `vision.md` de 64 por bando sigue pendiente de las
  palancas de abajo, igual que sin combate (la medida de la fase 2 con 66 jugadores daba un p99 de 8,2 ms
  con una mediana de 4,9; con combate, 64 dan 15,9 y 9,4).
- **El combate no es el cuello: lo es `simulate()`.** A 64 combatientes, `sim` ocupa 6,5 ms de los 9,4 de la
  mediana (el 69 %) y `combat` más `combat_events` 0,9 (el 10 %). `simulate()` cuesta 69–72 µs por
  personaje, frente a los 42–50 µs de la fase 2, y la sección `sim` entera 97–104 µs por jugador, frente a
  57–66 µs: la máquina de acciones y el cerebro de combate de los falsos suman unos 25–40 µs por
  personaje (el riesgo «Coste de `simulate()`» de combate.md §10; cifras de otra sesión y de otra
  máquina, así que no son comparables al detalle). Todo el trabajo de combate crece de forma lineal con
  los combatientes: unos 0,14 golpes por segundo y combatiente en las tres refriegas (260, 551 y 1044
  golpes en 60 s), con 18, 50 y 96 muertes.
- **Golpes con rebobinado: 76, 80 y 97 µs por comprobación** (797, 3756 y 10 239 comprobaciones de forma
  y línea de visión; solo hay trabajo en 275, 945 y 1822 ticks de los 4970). La sección `combat_resolve`
  es del 8 al 17 % de `combat` y su p99 no pasa de 0,69 ms: el rebobinado de 128 combatientes cabe en el
  presupuesto con holgura.
- **Eventos.** 319, 705 y 1329 eventos en 60 s (3,9, 8,5 y 16 por segundo), que llegan como 2602, 5181 y
  8194 paquetes (un evento va a todos los que tienen relevante al atacante o a la víctima) y cuestan de
  97 a 67 µs de envío por evento. En ancho de banda son **0,5, 1,0 y 1,6 KB/s en todo el servidor**, es
  decir, 0,1–0,2 KB/s por cliente frente a los 31–35 KB/s de los snapshots: el canal de eventos no
  cambia el presupuesto (el límite de 37 KB/s por cliente lo marca el snapshot, igual que en la fase 2).
- **Palancas.** La primera sigue siendo la 6 (portar `simulate()`, ahora a ~70 µs por personaje, casi el
  triple del umbral de 25 µs) y después la 4 (`build_for` en paralelo); el interés por rejilla (1) no
  ayuda en una refriega, porque todos ven a todos. El p99 de 8 ms con 64 pide dejar `sim` por debajo de
  unos 3 ms: la mitad del coste actual por personaje.

**Medidas de la fase 4: asedios** (`tools/load_test.gd --siege`, GUE-16, F6a). El Vado Gris con su Terrain3D, 120 s de medida con
todos los bots ya en la puerta y el círculo del fuerte (falsos con `--fake-brain=siege` y 10 bots reales `--bot-brain=siege`, mitad de
cada reino), en la misma máquina de 4 núcleos **con otro agente ejecutando su suite a la vez** (`uptime` de 0,9 a 1,7). Sin PNJ.
Tick en ms, p50 / p95 / p99 / máximo del último tramo de 34 s:

| Asedio | Jugadores | Tick | `sim` p50 | Bajada por cliente | Sustituidas (ventana) | Rebobinados rechazados |
|---|---|---|---|---|---|---|
| 32 contra 32 | 64 | 10,6 / 15,3 / 19,1 / 27,8 | 6,8 | 36,1 KB/s | 0,00 % | 0 |
| 64 contra 64 | 128 en la ventana; **118 sin clientes en el último tramo** | 14,8 / 22,0 / 26,4 / 42,8 (de 118; con los 128, p99 de las marcas 32,5) | 12,0 (de 118) | 28,5 KB/s | 50,76 % | 25 (6 sospechosos) |

La fila de 64 contra 64 no es de 128 jugadores (revisión de F6b): el enjambre se cerraba por su propio reloj y el servidor, más lento
que el tiempo real, siguió el último tramo sin los 10 bots reales (su `snapshot` de 0,002 ms lo delata); desde la revisión el enjambre
se cierra por el tick del servidor (`--quit-at-server-tick`) y el resumen avisa si el tramo no tiene el pico de jugadores.
Los resultados completos y lo que pasa en la batalla están en [fuerte.md 8.3](fuerte.md#83-lo-que-han-dejado-f0-f1-y-f2-añadidos-al-contrato-y-decisiones). Con 64 jugadores
el criterio de 8 ms de p99 **no se cumple** (19,1 ms, con la mediana ya en 10,6), igual que en la refriega de la fase 3 (15,9 ms con 64
combatientes en una máquina en reposo), los KB/s por cliente se cumplen (36,1 de 37) y no se sustituye ni una entrada; con 128 el
servidor no sostiene el tiempo real (la mitad de las entradas de los clientes se sustituye y el rebobinado falla a los honrados).
**El primer límite de jugadores por batalla en el fuerte sigue siendo 64 (32 contra 32)** (sin el kit de la fase 4; con él, la medida de 20 contra 20 de abajo). El coste de las fortalezas (la sección `war`)
es de 0,1 ms de mediana: el cuello es `simulate()` (palanca 6).

Desde GUE-44 (F6b) los bots de asedio esperan a los suyos en la salida de su campamento y van en formación (fuerte.md 8.3, F6b,
paquete C). Para la carga cambia poco: el servidor cuenta a los aliados con una lista por reino que reúne una vez por tick, solo
mientras alguien espera, y cada `SwarmBot` decodifica también los registros de los de su reino (los mismos que ya leía por turnos).
Pero los `SwarmBot` que entran cuando los falsos ya han salido pueden esperar hasta 30 s en el campamento: la repetición con PNJ
(GUE-16, F6b) tiene que comprobar que llegan a la puerta antes de la ventana de medida. Las medidas de arriba son de antes. En las de
F6b (abajo) lo comprueba el resumen: los 10 bots reales llegan a menos de 25 m del círculo a los 25–26,5 s con 32 contra 32 y a los
54 s con 64 contra 64, antes de la ventana (59 s).

**Asedios con los PNJ** (`load_test.gd --siege --npcs` o `--scenario=siege --npcs`, GUE-16, F6b): el servidor arranca con los PNJ del
Vado Gris (cuatro Huecos, el Capitán del Vado, la guarnición del dueño y los cuatro Guardianes de los campamentos) y el fuerte va solo,
sin `fort_kill_captain`; sin `--npcs`, el asedio de F6a con `--no-npcs`. Dos pasadas de cada asedio de 32 contra 32, alternadas, en la
misma máquina de 4 núcleos **sin otra suite en marcha** (carga media de 0,5 a 1,1), así que no se comparan al detalle con las de F6a.
La primera de 64 contra 64 tenía el mismo defecto que la de F6a (sus percentiles son de 118 jugadores sin ningún cliente); la segunda,
de la revisión de F6b, se hizo con el enjambre cerrado por el tick del servidor y con otra suite en marcha (carga de 0,7 a 1,8).
Tick en ms, p50 / p95 / p99 / máximo del último tramo de 34 s; `npc_brains` (los cerebros de los PNJ) y `npc` (sus generadores), p50:

| Asedio | Jugadores | Tick | `sim` p50 | `npc_brains` / `npc` | `war` p50 / p99 | Bajada por cliente | Sustituidas (ventana) | Rebobinados rechazados |
|---|---|---|---|---|---|---|---|---|
| 32 contra 32 con PNJ (dos pasadas) | 64 | 10,6 / 14,8 / 17,4 / 27,5 y 9,4 / 13,5 / 15,2 / 23,0 | 7,0 y 6,1 | 0,22 / 0,06 y 0,20 / 0,06 | 0,08 / 1,1 | 36,2–36,3 KB/s | 0,03 y 0,00 % | 0 |
| 32 contra 32 sin PNJ (dos pasadas) | 64 | 9,1 / 12,8 / 15,0 / 27,9 y 9,9 / 14,2 / 16,9 / 24,9 | 6,2 y 6,7 | 0,05 / 0 (los maniquíes) | 0,08–0,09 / 1,0–1,1 | 36,2 KB/s | 0,00 % | 0 |
| 64 contra 64 con PNJ, 1.ª | 128 en la ventana; **118 sin clientes en el último tramo** | 16,2 / 22,8 / 27,0 / 39,6 (de 118; con los 128, las marcas dan p50 19,6 y p99 33,5) | 13,5 (de 118) | 0,27 / 0,07 (de 118) | 0,09 / 2,1 (de 118) | 29,0 KB/s | 38,6 % | 83 (10 sospechosos) |
| 64 contra 64 con PNJ, 2.ª (revisión de F6b) | 128 (el 90 % del último tramo) | 17,2 / 24,2 / 30,0 / 72,3 | 12,3 | 0,23 / 0,06 | 0,08 / 1,9 | 32,1 KB/s | 0,00 % | 44 (8 sospechosos) |

Los 9 PNJ de guerra (los 5 del fuerte y los 4 Guardianes de los campamentos) cuestan alrededor de 1 ms del tick mientras viven (sus
cerebros, con un p99 de 0,8 a 1,1 ms por marca de 10 s mientras viven los Huecos; los generadores, 0,06 ms; su `simulate()`, unos
0,55 ms dentro de `sim`), y ~0,5 ms cuando solo quedan los cuatro Guardianes. Es del
orden de la diferencia entre dos pasadas iguales (0,8–1,2 ms de p50): con estas cifras no se distingue el asedio con PNJ del de sin
ellos. Los criterios no cambian: con 64 jugadores, **p99 de 15,2 a 17,4 ms, NO se cumple** (domina `simulate()`); 36,2–36,3 KB/s por
cliente y como mucho un 0,03 % de entradas sustituidas, sí; con 128, no: el p99 pasa de 29 ms, el servidor no llega al tiempo real
(81 y 87 %), las entradas de los clientes se sustituyen o no según cuánto se retrasa (38,6 % y 0,00 % en las dos pasadas) y el
rebobinado falla a los honrados en las dos.
**El primer límite de jugadores por batalla en el fuerte sigue en 64 (32 contra 32), también con los PNJ** (sin el kit de la fase 4;
con él, la medida de 20 contra 20 de abajo). La batalla de cada pasada
y la sesión de telemetría de 20 contra 20, en [fuerte.md 8.3](fuerte.md#83-lo-que-han-dejado-f0-f1-y-f2-añadidos-al-contrato-y-decisiones) (F6b, paquete E).

**Medidas de la fase 4: refriegas con el kit** (`tools/load_test.gd --brawl`, H5;
[habilidades.md 7.3](habilidades.md#73-pruebas-cada-una--30-s)). Como las de la fase 3 (Vado Gris con su Terrain3D, 10
bots reales `--bot-brain=combat` y el resto falsos de combate en el corro de `--fake-center=0,-96`, 60 s de medida tras
12 s de aproximación), con el protocolo 6 y el kit de la fase 4: los falsos usan habilidades, pociones, derribos y
remates, **la mitad lleva la plantilla del tirador** (`--fake-loadout=marksman:50`) y son arqueros puros
(`--fake-archers`: en una refriega densa todos tienen un enemigo a menos de 5 m y un tirador normal saca la espada; la
primera medida dio 0 flechas), de los que la mitad dispara al cielo (`--sky-archers=50`: sus flechas viven 2 s). Los PNJ
del fuerte (Huecos, capitán, guarnición y Guardianes) están en la zona. Misma máquina de 4 núcleos, con otros agentes
en marcha a ratos (carga media de 0,5 a 0,7 al empezar cada escenario). Tick en ms, p50 / p99 / máximo; el resto, p50
(p99 entre paréntesis en `combat_projectiles`); flechas: disparos en los 83 s del servidor y pico de vivas (tope 64):

| Combatientes | Tick | `sim` | `combat` | `combat_projectiles` | `snapshot` | Bajada por cliente | Sustituidas (ventana) | Flechas | Rebobinados rechazados |
|---|---|---|---|---|---|---|---|---|---|
| 32 (22 falsos y 10 bots) | 6,5 / 11,3 / 27,2 | 3,5 | 0,55 | 0,25 (0,98) | 1,14 | 30,7 KB/s | 0,00 % | 105, pico 13 | 0 |
| **40** (30 y 10; revisión, máquina en reposo) | 7,5 / **12,4** / 16,2 | 4,3 | 0,62 | 0,25 (**0,90**) | 1,21 | 35,4 KB/s | 0,00 % | 97, pico 18 | 0 |
| 48 (38 y 10) | 9,7 / **17,0** / 50,6 | 6,2 | 0,80 | 0,27 (0,89) | 1,34 | 35,9 KB/s | 0,00 % | 256, pico 24 | 0 |
| **64** (54 y 10) | 10,7 / **19,3** / 30,1 | 6,5 | 1,00 | 0,43 (**1,68**) | 1,18 | 36,1 KB/s | 0,00 % | 286, pico 37 | 0 |
| 64, todos los arqueros al cielo (`--sky-archers=100`) | 11,4 / 19,5 / 28,8 | 7,0 | 1,09 | 0,51 (2,04) | 1,74 | 36,2 KB/s | 0,00 % | 374, pico 54 | 0 |
| 64, **el tope lleno**: todos tiradores y al cielo (`--fake-loadout=marksman:100 --sky-archers=100`; revisión) | 13,7 / 23,2 / 53,8 | 8,1 | 2,52 | 1,29 (3,09) | 1,55 | 39,2 KB/s | 0,00 % | 4755, pico **64**, 4603 echadas por el tope | 4 de golpe, 0 de flecha |
| 128 (118 y 10) | 16,9 / 28,9 / 38,1 | 12,5 | 1,50 | 0,90 (2,94) | 0,00 | 27,4 KB/s | 100 % | 572, pico 51 | 0 |

- **El criterio de la fase 4 no se cumple con 64** (p99 del tick ≤ 16,7 ms y de `combat_projectiles` ≤ 1 ms,
  habilidades.md §7.3 y §8): 19,3 ms y 1,68 ms. Con 32 se cumple con holgura (11,3 y 0,98 ms) y con 48 el tick roza el
  límite (17,0 ms; proyectiles 0,89 ms). Con 40, medido en la revisión (habilidades.md §11.10), se cumple: 12,4 y
  0,90 ms (otra ejecución de la revisión, 14,1 y 0,84 ms); el margen de los proyectiles es corto. En las refriegas de
  la batería el tope de 64 flechas no llega a llenarse: ni con todos los arqueros disparando al cielo (pico de 54) ni
  con 128 combatientes (51), porque los arqueros también caen y tardan 30 s en volver; el coste ya pasa de la reserva
  antes.
- **Con el tope lleno** (medida forzada de la revisión: los 54 falsos tiradores, arqueros puros y al cielo, 57
  disparos por segundo): pico de 64 vivas y 4603 echadas por el tope (DESPAWN 5 de la más vieja de la zona) sin
  errores; `combat_projectiles` 1,29 ms de mediana y 3,09 de p99 (1,36 ms por tick con flechas: unos 315 000 segmentos
  y 89 000 SPAWN/DESPAWN, 21 KB/s del servidor entero), y el tick, 23,2 ms de p99 con picos de 54 ms, en los que el
  servidor rechaza 4 rebobinados de golpes. El tope acota las flechas vivas pero no el coste por disparo: con muchos
  arqueros la reserva de 1 ms no da, sea cual sea el tope.
- **Lo que cuestan las flechas sobre el Terrain3D**: de 0,30 a 1,05 ms de media por tick con flechas vivas (32 y 128
  combatientes), creciendo sobre todo con los combatientes (preparar las cajas barridas de todos los candidatos, unos
  6–8 µs por jugador o PNJ y tick) y menos con las flechas (unos 10 µs por flecha viva: de 11 a 19 de media con 64, de
  544 a 628 µs). Un rayo contra el terreno cuesta de 1,2 a 2,8 µs (sonda aparte): no es el mundo. Disparar (punto
  apuntado y convergencia) se reparte en pocos ticks.
- **El resto del kit no se nota**: `combat` pasa de 0,77 ms (fase 3) a 1,00 ms de mediana con 64; habilidades,
  pociones, efectos, derribos y remates (29 derribos, 14 rematados y 3 desangrados en la de 64) caben ahí. La bajada por
  cliente no cambia (36 KB/s, los snapshots; las flechas suman ~1 KB/s en el servidor entero) y no se rechaza ningún
  rebobinado hasta 64.
- **Límite de jugadores por batalla con el kit de la fase 4: 40** (era 64 en la fase 3), **medido**: 12,4 ms de p99
  del tick y 0,90 de los proyectiles (cumple). Con arqueros, 64 pasa de los 16,7 ms de p99 y de la reserva de 1 ms de
  los proyectiles; 48 ya roza el tick y 32 cumple con holgura. Es el aforo por defecto del servidor del Vado Gris
  (`Zones.MAX_PLAYERS`, `NetZones.max_players`: lo usa `ServerConfig` si no se pasa `--max-players`; una zona sin
  aforo propio sigue en 64), y la refriega de 40 está en la batería `--brawl`. Para volver a 64 hacen falta la palanca 6 (`simulate()`, que sigue siendo el 60 % del tick) y abaratar la
  preparación de los candidatos de las flechas (rehacer las cajas solo de quien se ha movido, o una rejilla en lugar del
  barrido en x). Los asedios del fuerte (F6a y F6b) se midieron sin el kit; con él, por la misma cuenta y **sin medir**
  (estimación), el fuerte pasaría de 32 contra 32 a unos 20 contra 20 (medido después, en la revisión de la integración:
  abajo).

**Integración de las habilidades sobre F6b** (fusión de la fase 4 con F6b): los asedios de F6b de arriba (32 contra 32 y 64 contra
64, con y sin PNJ) son de antes del kit. Desde la fusión los falsos y los bots de asedio pelean con él (el paso 1 de su plan,
[habilidades.md 11.9](habilidades.md#119-h5--integración)). La integración dio el límite en el fuerte con el kit como 40 (20 contra
20), pero era la estimación de arriba, sin medir, y la medida que proponía (`load_test.gd --siege --npcs`) no llevaba arqueros: los
falsos de asedio salen con la plantilla por defecto y los `SwarmBot` no tienen kit. El aforo por defecto del servidor del Vado Gris es
40 (`Zones.MAX_PLAYERS`); las herramientas y las pruebas de F6b que miden más jugadores (los asedios de `SIEGE_MATRIX`, 32 contra 32 y
64 contra 64; `siege_battle.gd` y `SiegeRunner`) piden su aforo con `--max-players` o `ServerConfig.max_players` explícitos
(`load_test.gd`: `server_max_players`, los jugadores más 8), y también cualquier sesión a mano con más de 40 jugadores. Nota también en
[fuerte.md 8.3](fuerte.md#83-lo-que-han-dejado-f0-f1-y-f2-añadidos-al-contrato-y-decisiones).

**Asedio de 20 contra 20 con el kit y los PNJ** (revisión de la integración; GUE-16): `load_test.gd --scenario=siege --fakes=30
--bots=10 --seconds=120 --npcs`, con la plantilla por defecto y con la mitad de tiradores (`--fake-loadout=marksman:50`; el arco de
los bots de asedio, desde la revisión, solo tira con línea de tiro). Misma máquina de 4 núcleos sin otra suite (carga de 0,5 a 0,9);
la refriega de 40 de la tabla de arriba, repetida en la misma sesión, da 7,4 / 11,3 / 13,2 / 22,7 ms. Tick en ms del último tramo de
34 s; secciones, p50 (p99):

| Asedio de 20 contra 20 con PNJ | Tick p50 / p95 / p99 / máx | Ventana p50 / p99 | `sim` | `combat_projectiles` | Bajada por cliente | Sustituidas (ventana) | Flechas | Rebobinados rechazados |
|---|---|---|---|---|---|---|---|---|
| Plantilla por defecto (el escudero) | 8,2 / 12,8 / **16,2** / 32,6 | 8,9 / 17,1 | 4,9 (9,9) | 0 | 34,4 KB/s | 0,00 % | ninguna | 0 |
| La mitad de tiradores | 9,6 / 14,3 / **16,9** / 38,7 | 9,6 / 17,2 | 5,8 (10,5) | 0,26 (**1,01**) | 36,1 KB/s | 0,00 % | 328, pico 11 | 0 |

**El fuerte con el kit está en el filo del criterio de la fase 4** (p99 del tick ≤ 16,7 ms y de `combat_projectiles` ≤ 1 ms): con la
plantilla por defecto lo cumple (16,2 ms) y con la mitad de tiradores se pasa por poco (16,9 y 1,01 ms); las marcas de la ventana
dan 17,1–17,2 ms en las dos. Cuesta más que la refriega de 40 en campo abierto por `simulate()` (4,9–5,8 ms de mediana frente a 4,3,
~70–74 µs por personaje en las laderas y la explanada del fuerte) y los cerebros de los PNJ (0,2–0,4 ms). **El límite por batalla
en el fuerte con el kit queda en 40 (20 contra 20), medido y sin margen**: no se baja el aforo por lo que separa una pasada del
criterio (del orden del ruido entre dos pasadas iguales, ~1 ms), y la palanca para tener margen sigue siendo la 6 (`simulate()`,
TEC-35). Detalle de la batalla en cada pasada, en [fuerte.md 8.3](fuerte.md#83-lo-que-han-dejado-f0-f1-y-f2-añadidos-al-contrato-y-decisiones)
(«Revisión de la integración de las habilidades»).

**Palancas para Eldrun, por orden,** decididas con las medidas del final de la fase 2:

1. Interés por rejilla.
2. Bajar el presupuesto a ~700 B por snapshot, con prioridad por distancia. El objetivo es
   ≤ 20 KB/s por cliente, ~6 MB/s de salida.
3. Delta contra `ack_snapshot_tick`, con la invariante de que el fotograma guardado en el
   servidor es exactamente el que reconstruye el cliente.
4. `build_for` en paralelo por peer con `WorkerThreadPool.add_group_task`: es puro sobre los
   registros congelados del tick.
5. Portar `SnapshotBuilder` a C++ (GDExtension, con la misma API) si con 100 bots pasa de 3 ms
   por tick.
6. Portar `simulate()` a C++ en los dos lados si pasa de 25 µs por personaje.
7. Eldrun a 30 Hz, anunciado en `WELCOME.tick_rate`.

---

## 15. Puntos de extensión

### Fase 3: combate de acción

- **Estado.** `PlayerState` crece con la máquina de acciones (ataque, bloqueo, esquiva y sus
  fases) y la resistencia, simulada en `simulate()` dentro de `scripts/shared`. Así también se
  predice.
  - Sube `PROTOCOL_VERSION`.
  - `equals_exact`, la reconciliación y el snapshot no cambian de forma.
- **Entradas.** Los botones PRIMARY, BLOCK y DODGE ya viajan, y su flanco se calcula con
  `prev_buttons`, como el salto.
- **Golpes:**
  - `InputQueue.get_view_offset_q(T)` y `StateHistory.sample()`, con los topes de
    [10](#10-historial-para-la-compensación-de-latencia);
  - validación de resistencia, tiempo de reutilización, alcance y línea de visión en el servidor.
- **Daño y muertes.** ENTITY_EVENT fiable ([5.5](#55-servidor--cliente)).
  - Los eventos de los remotos se aplican cuando el `render_tick` alcanza su tick; los propios,
    al llegar.
  - La vida y la resistencia propias van en un bloque extra tras el estado propio (bit 3 de
    `flags` del snapshot).
- **Reaparición:** contador de teletransporte.
- **Animación de los remotos:** byte `action` del registro.

### Fase 4: fuerte capturable

- **El fuerte** es una `NetEntity` de tipo STRUCTURE con `ALWAYS_RELEVANT`. Se replica por
  OBJECT_STATE fiable:
  - estado completo en el SPAWN y después solo los cambios;
  - captura como fórmula;
  - formatos fijados en el protocolo 3 ([5.5](#55-servidor--cliente)): OBJECT_STATE, ENTITY_SPAWN de
    STRUCTURE y los ENTITY_EVENT WAR y TELEGRAPH.
- **Guardias PNJ:** entidades por flujo (tipo NPC, mismo registro), simuladas en el paso 4 de
  [8.1](#81-orden-del-tick) e interpoladas en el cliente.
- **Avisos** («¡Vado Gris capturado!»): por NOTICE o ENTITY_EVENT, aplicados en el tick de
  dibujo.
- **Chat y grupos** (protocolo 5, [social.md](social.md#12-implementación-fase-4)): CHAT_SEND y
  CHAT_MESSAGE (`0x40` y `0x41`) por el canal fiable 3. Los reparte el `ChatRouter` del servicio social
  (`scripts/server/social/`), que `ZoneServer` solo alimenta con los tipos `0x40` a `0x4F`. `NetClient`
  decodifica los S→C (CHAT_MESSAGE y PARTY_*) y emite señales; `SwarmBot` los decodifica y los descarta sin
  contarlos como mal formados ([social.md](social.md#12-implementación-fase-4), 12.7).

### Fases 5 y 6: cuentas y traspasos

- **`character_id` y `ticket`** ya viajan en HELLO. `AuthProvider` se sustituye por
  `TicketAuthProvider`, y `ZoneServer` cambia: el estado `VERIFYING` (la reclamación), el cupo que cuenta a
  los que verifican y `start(…, platform)` ([plataforma.md](plataforma.md) §5.2 y §14.3).
- **El traspaso** repite la conexión: HANDOFF → nueva conexión con billete → WELCOME → carga →
  CLIENT_READY. El reino pasa a salir del personaje.

### Eldrun

- Interés por rejilla con histéresis.
- Prioridad por distancia y combate.
- Presupuesto por snapshot (ya existe).
- Envíos escalonados y codificación única por tick (ya existen).
- Delta contra la base confirmada (`ack_snapshot_tick` ya viaja).
- Escena remota solo visual.
- Palancas de C++ según la medida.
- `--bots=N` con escenarios dispersos, agrupados y de altas y bajas para medir antes de diseñar
  los asedios.

---

## 16. Plan de pruebas

Todo corre con el ejecutor actual (`godot --headless --path . -s res://tests/run_tests.gd`), que
falla ante cualquier error del motor; cada prueba dura menos de 30 s. Los ayudantes van en
`tests/net_harness.gd`.

**Dos suites a la vez** (dos copias del proyecto, o dos ejecuciones en la misma carpeta) no se
pisan: cada proceso de pruebas empieza a buscar puertos en su propia ranura según su pid
(`NetHarness.first_port_for`), deja los informes y registros de los procesos que lanza en
`build/<pid>/` (`NetHarness.build_path`; al empezar se borran las carpetas de procesos que ya no
existen) y la prueba de procesos de `--local` usa un bloqueo propio (`--dev-lock-path=<ruta>`,
junto a él va el registro del servidor) en vez del `user://dev_server.json` real, que comparten
todas las copias del proyecto.

### Unitarias

- **`test_net_messages`**:
  - ida y vuelta de cada mensaje con los offsets y tamaños de este documento;
  - mensajes truncados, con bytes de sobra, de tipo desconocido o con `count` fuera de rango →
    `null`;
  - *fuzz* con 10 000 búferes aleatorios (con semilla) sin errores;
  - posición cuantizada en ±5 km con un error ≤ 5 mm, y saturación fuera de rango;
  - INPUT_BATCH: las entradas decodificadas son iguales a `quantized()` de las originales, y la
    máscara de botones se aplica.
- **`test_input_queue`**:
  - ventana de aceptación (tardías, demasiado adelantadas, duplicadas distintas: gana la
    primera);
  - `get_ack_tick()` con huecos y tras una sustitución;
  - antelación solo con primeras copias, con las tardías y con las demasiado tempranas
    (saturada a 127);
  - movimiento a 0 tras 6 ticks.
  - **Sin flancos inventados:** con JUMP mantenido y entradas 15–17 perdidas, la entrada 18 con
    JUMP no hace saltar otra vez (con un `PlayerCharacter` real).
- **`test_tick_sync`**:
  - secuencias de margen → pasos esperados;
  - deuda proporcional y espera hasta el ack posterior al ajuste;
  - resincronización hacia delante y nunca hacia atrás;
  - margen objetivo según el jitter.
- **`test_interpolation_clock`**: converge al retardo con jitter sintético y salta con errores
  de más de 10 ticks; adopta en ≤ 40 ticks un escalón sostenido hacia abajo de los offsets, no
  confunde un bache corto con un escalón y sigue bien con ticks por encima de 2^31.
- **`test_remote_interpolator`**:
  - `lerp`, y `lerp_angle` al cruzar ±PI;
  - extrapolación de 6 ticks y parada;
  - contador de teletransporte;
  - visibilidad según `spawn_tick` y `despawn_tick`.
- **`test_state_history`**: muestras fraccionarias, sobrescritura del anillo, teletransporte y
  `forget`; ticks por encima de 2^31.
- **`test_net_sim`**:
  - misma semilla → misma secuencia;
  - la pérdida no toca los canales fiables;
  - orden FIFO de los fiables;
  - retardo dentro de `rtt/2 ± jitter`;
  - `NetTransport`: `connect_timeout_ms` (fallo de conexión en ≤ el doble) y el filtro de
    paquetes ajenos al protocolo con un cliente ENet en bruto (`tests/raw_enet_attacker.gd`):
    descartes antes y después del HELLO sin errores del motor, un RAW que llega junto a la
    confirmación no se pierde, mensajes de autenticación acotados, peer silenciado.
- **`test_snapshot_builder`** (prueba de propiedades): 200 entidades aleatorias durante 600
  ticks.
  - Ningún paquete pasa de 1200 B.
  - Con N relevantes y C plazas, ninguna entidad pasa más de ⌈N/C⌉ snapshots sin enviarse.
  - El propio jugador nunca aparece entre los registros.
  - Lo que se construye se decodifica con `NetMessages.Snapshot.decode`.
- **`test_rate_limiter`** y **`test_server_auth`**: cada motivo de REJECT y el tope por IP con
  la excepción de loopback (y las IPv6 por /64); crédito por parón de los limitadores; avisos con
  ticks por encima de 2^31.
- **`test_zone_server`** / **`test_zone_server_net`** (seguridad y robustez): parón del servidor
  sin expulsar a un cliente honrado; conexiones ociosas de una IP que no agotan las plazas y plazo
  del HELLO; enfriamiento tras una expulsión; RTT acotado frente a un cliente que atrasa sus
  acks; inundación de paquetes ajenos antes y después del HELLO (expulsión, tick < 16 ms); altas y
  bajas continuas sin crecimiento de memoria.

### Integración en un proceso

- **`test_prediction`** (sin red). Mundos de servidor y de cliente en dos `SubViewport` con
  `own_world_3d = true` (espacios de física separados), con un `PlayerCharacter` en cada uno.
  - Mismas entradas → `predicted[t].encode() == servidor[t].encode()` en cada tick, girando,
    saltando y por la rampa (los pies pisan el suelo a más de 2 m: un salto en llano llega a 1,5 m).
  - La copia de la regla de sustitución del cliente (`_input_or_substitute`, al repetir con huecos
    en el anillo tras un `hard_reset` hacia delante) deja, tick a tick, los mismos estados que la
    `InputQueue` real con las mismas entradas y el mismo hueco (de más de 6 ticks).
  - El servidor sustituye la entrada del tick X y los estados llegan con 6 ticks de retraso → el
    cliente reconcilia y queda exactamente igual a partir de ahí.
  - Suavizado:
    - en la transición, la posición global de `Visual` no salta más de 1 mm;
    - el desfase baja de 1 mm en 30 ticks;
    - con más de 3 m, salto directo;
    - personaje girado 90°: el desfase local es correcto.
- **`test_net_loopback`** (ENet real sobre 127.0.0.1). `ZoneServer` y 3 `NetClient` bots, cada
  uno en su `SubViewport` con su `SceneMultiplayer`; 600 ticks. Cada escenario es un método
  aparte:
  - **a)** Handshake correcto, y REJECT por versión, reino y `sim_hash`, sin errores del motor
    (no hay envíos antes de `peer_connected`).
  - **b)** SPAWN y DESPAWN al conectar y desconectar (LEAVE y corte).
  - **c)** Sin `NetSim`:
    - 0 correcciones a partir del tick 60;
    - cada bot dibuja a los otros dos a menos de 0,5 m de `StateHistory.sample()` en su
      `render_tick`.
  - **d)** Con `rtt=150, jitter=30, loss=10`:
    - antelación en régimen: el **mínimo de la ventana de `TickSync`** (`get_window_min()`, lo que
      regula el bucle de control) en [0, 6], que es `MAX_TARGET` (4) + `SLOW_DOWN_THRESHOLD` (2): la
      media de cada bot en ese rango y al menos un 80 % de las muestras dentro. No se exige al
      `input_margin` de cada snapshot suelto: es el mínimo de dos ticks de llegada y, con ±30 ms de
      jitter, queda por diseño entre 2 y 4 ticks por encima del mínimo de la ventana (en las
      mediciones, un 28–35 % de los snapshots de cada bot pasa de 6 y su media es ~6,1). Exigirlo
      obligaría a bajar el objetivo de antelación y a aceptar más entradas tardías;
    - menos de un 2 % de entradas tardías;
    - cada corrección coincide con una subida de `substitutions`;
    - convergencia exacta tras 60 ticks quietos;
    - ninguna resincronización dura después del arranque.
  - **e)** `DEBUG_COMMAND teleport`: el cliente salta (sin suavizado) y queda exacto.
  - **f)** Parones del servidor (40 ticks con un bot; 20 con dos): `TickSync` se recupera (la
    antelación vuelve a la normal, sin sustituciones ni correcciones nuevas) y los remotos no
    se congelan más de 15 ticks tras volver los datos.

### Un proceso aparte (`test_server_main`)

- El servidor como proceso: `--quit-after-ticks`, `--idle-quit`, informe, `--stop-file` (cierre
  ordenado y archivo de parada viejo) y el informe periódico que queda si matan al proceso.

### Varios procesos (`test_net_processes`)

- **Lanzamiento.** `OS.create_process(OS.get_executable_path(), […])` lanza:
  - el servidor: `--headless … -- --server --port=<libre> --quit-after-ticks=900 --report=…`;
  - dos `--bot` con `--quit-after-ticks=700 --report=…`.

  Espera como mucho 25 s comprobando `OS.is_process_running`.
- **Determinismo entre procesos.** Cada bot compara, en cada snapshot, su `predicted[S].encode()`
  con los bytes del estado propio del servidor. Sin `NetSim`: 0 diferencias sin explicar (las
  que no coinciden con una subida de `substitutions`, un teletransporte ni, desde la fase 3, un
  evento de combate propio: lo que el servidor impone al jugador —tambaleo, aturdimiento, empuje,
  resistencia gastada al bloquear, muerte, reaparición— y el cliente no predice; ver
  [combate.md 11](combate.md#11-cambios-durante-la-implementación)).
- **Segunda pasada con `--net-sim`** en los bots: convergencia final exacta (quietos los últimos
  60 ticks) y ninguna resincronización dura.
- **Detección de interferencias.** También detecta si los cuerpos ajenos del servidor o la
  colisión de Terrain3D alteran las consultas de Jolt.
- **Bot tramposo** (`--bot-cheat=version|future|dupes|garbage|flood`, un método por modo):
  rechazado o expulsado, sin que el bot honrado tenga diferencias sin explicar ni el servidor
  registre errores.
- **Bot tramposo de combate** (K5, TEC-14; `--bot-cheat=rewind|reach|rate`, los tres a la vez
  contra el maniquí de `test_world`): `rewind` pelea con la vista falseada a 40 ticks y el servidor
  no prueba ni un golpe (sospecha por golpe); `reach` ataca desde 5 m y no conecta; `rate` machaca
  PRIMARY y pega solo al ritmo del combo. Ninguno hace daño de más. En un proceso con ENet real
  están en `test_bot_cheat` (uno por modo, con un bot honrado de control) y en
  `test_net_processes`.

### Carga (manual)

`tools/load_test.gd`, fuera del ejecutor:

- Servidor con `--fake-players=N` (entradas inyectadas en la `InputQueue`, sin red) y procesos
  `--bots=50`.
- 64, 128 y 256 jugadores; escenarios disperso, agrupado (todos en 60 m) y de altas y bajas a 1
  por segundo; 120 s cada uno. `--matrix` lo hace con 64 falsos (+ 2, 10 y 50 bots, dispersos y con
  altas y bajas), 128 falsos agrupados y 256 falsos agrupados y dispersos (+ 10 bots), y los bots del
  escenario del criterio con `--net-sim=rtt=100`.
- Criterio de la fase 2, con 64 bots agrupados:
  - p99 del tick < 8 ms;
  - ≤ 37 KB/s por cliente;
  - menos de un 1 % de entradas sustituidas con 100 ms de RTT, medido dentro de la ventana de medida
    (sin el arranque); la herramienta muestra también el porcentaje de toda la sesión.
- Refriegas de combate (TEC-15): `--brawl` (o `--scenario=brawl`) con 32, 64 y 128 combatientes, falsos con
  `--fake-brain=combat` en un corro (`--fake-center`) más 10 bots reales de combate, 60 s de medida
  cada una. Mide por sección (golpes con rebobinado, eventos, snapshots) y los KB/s con los ENTITY_EVENT;
  resultados y primer límite de jugadores por batalla en 14.
- Asedios de fuerte (GUE-16): `--siege` (o `--scenario=siege`) con 32 contra 32 y 64 contra 64, 120 s de medida con los bots ya en la
  puerta y el círculo; los falsos llevan `--fake-brain=siege`, los bots reales `--bot-brain=siege` y el servidor, sin PNJ, abre el círculo
  con `--run-at=<tick>:fort_kill_captain` y escribe un registro de batalla. Con `--npcs` (F6b), con los PNJ de la zona y sin esa orden.
  Cifras en 14.
  puerta y el círculo; los falsos llevan `--fake-brain=siege`, los bots reales `--bot-brain=siege` y el servidor abre el círculo con
  `--run-at=<tick>:fort_kill_captain` y escribe un registro de batalla. Cifras en 14.
- Refriegas con el kit de la fase 4 (H5, [habilidades.md 7.3](habilidades.md#73-pruebas-cada-una--30-s)): `--brawl` lleva desde
  entonces la mitad de los falsos con la plantilla del tirador (`--fake-loadout=marksman:50`), arqueros puros (`--fake-archers`) de los
  que una parte dispara al cielo (`--sky-archers=<porcentaje>`, 50 por defecto; con 100, el máximo de flechas vivas), y los
  PNJ del fuerte en la zona. El resumen añade la sección `combat_projectiles`, las flechas y el kit, y el criterio de la fase 4: p99 del
  tick ≤ 16,7 ms y de `combat_projectiles` ≤ 1 ms. Cifras y límite en 14.

### Arquitectura (`test_architecture`, ampliado)

- `scripts/shared/` (también `net/`, de forma recursiva) y `scripts/world/` (lo que carga el
  servidor) mantienen sus reglas: nada de `Time.get_`, `Input`, UI ni clases del cliente, ni
  contadores de fotogramas (`Engine.get_physics_frames`), ni aleatoriedad global (`randf()`,
  `Array.pick_random()`, `shuffle()`, `rng.randomize()`), y todo `RandomNumberGenerator` se crea con
  su semilla.
- Las escenas que carga el servidor (las de zona, `player_character.tscn` y `server_main.tscn`) no
  arrastran scripts del cliente, animaciones ni visuales de personaje.
- `scripts/server/` no referencia rutas ni clases de `scripts/client/`.
- `scripts/client/` no referencia rutas ni clases de `scripts/server/`. `LocalServerLauncher`
  solo lanza un proceso.
- Los scripts de red obligatorios existen.

---

## 17. Plan de archivos

Son contratos para implementar en paralelo. Las firmas son públicas y estables; lo privado
queda a criterio de quien implemente.

- Tipado estático siempre.
- Identificadores en inglés; comentarios y textos en español.
- «Compartido» = lo carga el servidor y no depende del cliente.

### 17.1 Reparto

| Paquete | Contenido | Depende de |
|---|---|---|
| A · base compartida | cambios en `player_state.gd` y `player_character.gd`; `NetProtocol`, `NetMath`, `NetZones`, `EntityRecord`, `NetMessages`, `BotBrain`; `test_net_messages` | — |
| B · transporte | `NetSim`, `NetTransport`; `test_net_sim` | A (constantes) |
| C · servidor | todo `scripts/server/` y sus pruebas unitarias | A, B |
| D · simulación del cliente | `TickSync`, `InterpolationClock`, `ClientPrediction`, `CorrectionSmoother`, `RemoteInterpolator`; sus pruebas y `test_prediction` | A |
| E · aplicación cliente | `NetClient`, `RemoteWorld`, `RemotePlayerView`, `OnlineMain`, `ClientConfig`, `RealmSelect`, `NetDebugOverlay`, `LocalServerLauncher`, `BotSwarm`, `SwarmBot`; cambios en `local_player_controller.gd` y `boot.gd`; escenas | A, B, D |
| F · integración | `NetHarness`, `test_net_loopback`, `test_net_processes`, `tools/`, `test_architecture` | todos |

Con los contratos de A fijados aquí, B, C, D y E pueden empezar a la vez.

### 17.2 `scripts/shared/` (compartido)

```gdscript
# player_state.gd (cambios)
## Redondea a float de 32 bits, la precisión de PlayerState.encode().
static func to_f32(value: float) -> float
## true si encode() es idéntico byte a byte.
func equals_exact(other: PlayerState) -> bool

# player_character.gd (cambios)
## Si es false, simulate() no emite jumped ni landed (repeticiones y avance neutro).
var events_enabled: bool = true
## El setter de yaw pasa a ser: yaw = PlayerState.to_f32(value); basis = Basis(Vector3.UP, yaw)

# bot_brain.gd (nuevo): lo usan los bots del cliente y los jugadores falsos del servidor
class_name BotBrain extends RefCounted
enum Pattern { WANDER, CIRCLE, IDLE, JUMPY }
func _init(seed: int, pattern: Pattern = Pattern.WANDER, home: Vector3 = Vector3.ZERO,
		radius: float = 30.0) -> void
## Entrada sin cuantizar (la cuantiza quien llama). Determinista con la semilla: cambia de
## dirección cada 60–180 ticks, salta y esprinta a veces y vuelve hacia home si sale del radio.
func next_input(tick: int, position: Vector3, yaw: float) -> PlayerInput
## Desde ese tick solo devuelve entradas neutras (pruebas de convergencia).
func set_idle_from(tick: int) -> void
```

### 17.3 `scripts/shared/net/` (compartido; sin `Time`, sin `Input`)

```gdscript
# net_protocol.gd
class_name NetProtocol extends RefCounted
const PROTOCOL_VERSION: int = 6                      # 5 el chat y los grupos (social.md 12), 6 las habilidades
const MAGIC: int = 0x4D444C45
const DEFAULT_PORT: int = 24600
const CUSTOM_CHANNELS: int = 3
const CH_INPUT: int = 1
const CH_SNAPSHOT: int = 2
const CH_RELIABLE: int = 3
const MAX_PACKET_BYTES: int = 1200
const SNAPSHOT_INTERVAL_TICKS: int = 2
const MAX_INPUTS_PER_BATCH: int = 8
const INPUT_REDUNDANCY: int = 4
const INPUT_REDUNDANCY_LOSSY: int = 8
const MAX_INPUT_LEAD_TICKS: int = 30
const REPEAT_MOVE_TICKS: int = 6
const MAX_REWIND_TICKS: int = 24
const INTERP_DELAY_Q_SCALE: int = 8                  # interp_delay_q = retardo en ticks × 8
const MAX_INTERP_DELAY_TICKS: int = 12
const MAX_INTERP_DELAY_Q: int = 96                   # lo que pase es un aviso (S4)
const NO_MARGIN: int = -128
const VALID_BUTTONS: int = (1 << 13) - 1             # bits 0-12 (v6; 0-8 hasta la v5)
const MAX_NAME_BYTES: int = 48
const MIN_NAME_CHARS: int = 3
const MAX_NAME_CHARS: int = 24
const MAX_TICKET_BYTES: int = 256
const MAX_ZONE_ID_BYTES: int = 32
const MAX_DEFINITION_ID_BYTES: int = 32              # id ASCII de la definición de una estructura
const MSG_INPUT_BATCH: int = 0x01
const MSG_CLIENT_READY: int = 0x02
const MSG_CLIENT_LEAVE: int = 0x03
const MSG_DEBUG_COMMAND: int = 0x04
const MSG_RESPAWN_REQUEST: int = 0x05
const MSG_UNSTUCK_REQUEST: int = 0x06
const MSG_LOADOUT_SELECT: int = 0x07                 # v6
const MSG_SNAPSHOT: int = 0x10
const MSG_ENTITY_SPAWN: int = 0x20
const MSG_ENTITY_DESPAWN: int = 0x21
const MSG_OBJECT_STATE: int = 0x22
const MSG_ENTITY_EVENT: int = 0x23
const MSG_NOTICE: int = 0x30
const MSG_HANDOFF: int = 0x31        # reservado (fase 6)
const MSG_SCOREBOARD: int = 0x32
const DEBUG_TELEPORT: int = 1
const DEBUG_HEAL: int = 2
const DEBUG_KILL: int = 3
const DEBUG_STAMINA_INF: int = 4
const DEBUG_SET_WEAPON: int = 5
const DEBUG_SPAWN_DUMMY: int = 6
const DEBUG_UNSTUCK: int = 7
const DEBUG_FORT_RESET: int = 8
const DEBUG_FORT_OWNER: int = 9
const DEBUG_FORT_KILL_CAPTAIN: int = 10
const DEBUG_FORT_CAPTURE_SPEED: int = 11
const DEBUG_NPC_DEBUG: int = 12
const DEBUG_COOLDOWNS_OFF: int = 13                  # v6: u8 0 o 1
const DEBUG_APPLY_STATUS: int = 14                   # v6: u8 status_id, u16 ticks
const DEBUG_DOWN: int = 15                           # v6: sin datos
const DEBUG_REFILL: int = 16                         # v6: sin datos
const DEBUG_COMMAND_IDS: Dictionary[StringName, int]   # nombre -> id de cada comando de red
enum Realm { NONE = 0, VARDHEIM = 1, SOLMARCH = 2, ASKARRA = 3 }
enum EntityKind { NONE = 0, PLAYER = 1, NPC = 2, PROJECTILE = 3, STRUCTURE = 4 }
enum Result { OK = 0, VERSION = 1, SIM_HASH = 2, REALM = 3, FULL = 4, TICKET = 5, MALFORMED = 6,
		TOO_MANY_CONNECTIONS = 7, NAME = 8, IMBALANCE = 9 }
enum DespawnReason { OUT_OF_INTEREST = 0, DISCONNECTED = 1, DEATH = 2, HANDOFF = 3, IMPACT = 4,
		EXPIRED = 5 }                                    # 4 y 5: proyectiles (v6)
enum NoticeCode { INFO = 0, KICK = 1, SHUTDOWN = 2 }
static func channel_for_type(msg_type: int) -> int
static func transfer_mode(channel: int) -> MultiplayerPeer.TransferMode
static func is_unreliable_channel(channel: int) -> bool
## Ver la sección 3. La instancia debe estar en el árbol (después de _ready()).
static func compute_sim_hash(character: PlayerCharacter) -> int
## Movimiento 0, botones 0, look_yaw = yaw cuantizado, pitch 0. Ya cuantizada.
static func neutral_input(tick: int, yaw: float) -> PlayerInput
static func realm_display_name(realm: int) -> String      # «Vardheim», «Solmarch», «Askarra»
static func result_text(result: int) -> String            # motivo de rechazo en español

# net_zones.gd: único contacto con scripts/shared/zones.gd
class_name NetZones extends RefCounted
static func default_zone_id() -> String
static func scene_path(zone_id: String) -> String                  # "" si no existe
static func allowed_realms(zone_id: String) -> PackedInt32Array    # códigos Realm; vacío = todos
static func parse_zone_arg(args: PackedStringArray) -> String      # "" si no viene
static func parse_realm_arg(args: PackedStringArray) -> int        # Realm.NONE si no viene
static func realm_from_name(text: String) -> int
static func realm_name(realm: int) -> StringName                   # id de RealmCatalog; "" si no es jugable
static func find_spawn_point(zone: Node, realm: int) -> Node3D     # el del reino o el primero; null si no hay
static func get_spawn_points(zone: Node, realm: int = NetProtocol.Realm.NONE) -> Array[Node3D]
static func spawn_group() -> StringName

# net_math.gd
class_name NetMath extends RefCounted
const POSITION_SCALE: float = 100.0
const POSITION_BIAS: int = 1 << 19
const POSITION_MAX: int = (1 << 20) - 1
static func pack_position(position: Vector3) -> int
static func unpack_position(packed: int) -> Vector3
static func quantize_yaw16(yaw: float) -> int
static func dequantize_yaw16(quantized: int) -> float
static func quantize_velocity(value: float) -> int          # cm/s saturado a s16
static func dequantize_velocity(quantized: int) -> float

# entity_record.gd
class_name EntityRecord extends RefCounted
const SIZE: int = 21
const FLAG_GROUNDED: int = 1 << 0
const TELEPORT_SHIFT: int = 1
const TELEPORT_MASK: int = 0b11
const FLAG_SECOND_SLOT: int = 1 << 3                 # v6: ranura de arma 2 activa
const HISTORY_FLAGS_MASK: int = 0b111                # lo que toma el historial (allí el bit 3 es el bloqueo)
const HEALTH_Q_DEAD: int = 0
const HEALTH_Q_FULL: int = 255
var net_id: int = 0
var kind: int = NetProtocol.EntityKind.PLAYER
var position: Vector3 = Vector3.ZERO
var yaw: float = 0.0
var velocity: Vector3 = Vector3.ZERO
var flags: int = 0
var action: int = 0
var health_q: int = HEALTH_Q_FULL
func is_grounded() -> bool
func get_teleport_counter() -> int
func is_second_slot() -> bool                        # v6
## 0 si no queda vida; si no, clampi((health · 255 + max − 1) / max, 1, 255).
static func quantize_health(health: int, max_health: int) -> int
static func health_fraction(quantized: int) -> float
func encode_into(bytes: PackedByteArray, offset: int) -> void
static func decode_from(bytes: PackedByteArray, offset: int, kind: int) -> EntityRecord
## Servidor: escribe el registro sin crear objetos.
static func encode_character(bytes: PackedByteArray, offset: int, net_id: int,
		character: PlayerCharacter, teleport_counter: int, action: int, health_q: int) -> void
static func from_state(net_id: int, kind: int, state: PlayerState, teleport_counter: int,
		health_q: int = HEALTH_Q_FULL) -> EntityRecord
static func interpolate(a: EntityRecord, b: EntityRecord, t: float) -> EntityRecord

# net_messages.gd: cada clase interna tiene encode() -> PackedByteArray y
# static decode(bytes: PackedByteArray) -> <Clase>, que devuelve null si está malformado.
class_name NetMessages extends RefCounted
static func peek_type(bytes: PackedByteArray) -> int            # -1 si vacío
static func peek_auth_result(bytes: PackedByteArray) -> int     # -1 sin magic; 0 WELCOME; >0 REJECT
class Hello:
	var protocol_version: int; var sim_hash: int; var realm: int; var flags: int
	var character_id: int; var display_name: String; var ticket: PackedByteArray
class Welcome:
	var protocol_version: int; var server_tick: int; var tick_rate: int
	var snapshot_interval: int; var max_input_batch: int; var max_rewind_ticks: int
	var realm: int; var channel: int; var zone_id: String
	var realm_counts: PackedInt32Array      # 3 posiciones: Vardheim, Solmarch, Askarra (v3)
	func get_realm_count(realm_code: int) -> int
class Reject:
	var result: int; var text: String
class InputBatch:
	var ack_snapshot_tick: int; var interp_delay_q: int; var newest_tick: int
	var inputs: Array[PlayerInput]          # de la más antigua a la más nueva, ticks seguidos
	var view_offsets_q: PackedInt32Array    # mismo tamaño que inputs
class ClientReady:
	var flags: int
class ClientLeave:
	var reason: int
class DebugCommand:
	var command: int; var payload: PackedByteArray
	## Valida los datos de los comandos 1 (12 B), 7 a 12 (v3) y 13 a 16 (v6); el resto, hasta 64 B.
	static func simple(command_id: int) -> DebugCommand
	static func fort_owner(realm_code: int) -> DebugCommand
	static func fort_capture_speed(factor: int) -> DebugCommand
	static func npc_debug(enabled: bool) -> DebugCommand
	static func cooldowns_off(enabled: bool) -> DebugCommand                     # v6
	static func apply_status(status_id: int, ticks: int = 0) -> DebugCommand     # v6
	func get_status_id() -> int; func get_status_ticks() -> int
class Snapshot:
	var server_tick: int; var input_ack_tick: int; var input_margin: int
	var substitutions: int; var own_teleport: int
	var own_state: PlayerState              # null si no viene
	var health: int; var max_health: int    # bloque extra propio (solo con own_state)
	var status: int; var respawn_tick: int
	var records: Array[EntityRecord]
	func is_in_combat() -> bool; func is_protected() -> bool; func is_dead() -> bool
	func is_downed() -> bool                             # v6: bit 3 de status
	## Lo usa SnapshotBuilder para escribir la cabecera sin crear el objeto. Devuelve el
	## offset donde empieza section_count. Con estado propio escribe también el bloque extra.
	static func write_header(bytes: PackedByteArray, server_tick: int, input_ack_tick: int,
			input_margin: int, substitutions: int, own_teleport: int,
			own_state_bytes: PackedByteArray, health: int = 0, max_health: int = 0,
			status: int = 0, respawn_tick: int = 0) -> int
class EntitySpawn:
	var net_id: int; var kind: int; var spawn_tick: int; var realm: int
	var is_yours: bool; var teleport_counter: int; var state: PlayerState; var display_name: String
	var npc_def_id: int                                  # NPC (v3): u16 tras el nombre
	var definition_id: String; var fields: Array[ObjectField]   # STRUCTURE (v3)
	const PROJECTILE_SIZE: int = 32; const PROJECTILE_FLAG_HARMLESS: int = 1 << 0   # PROJECTILE (v6)
	var owner_id: int; var projectile_def_id: int; var source: int; var volley_index: int
	var projectile_flags: int; var origin: Vector3; var velocity: Vector3
	static func for_fortress(net_id: int, spawn_tick: int, definition_id: String,
			state: FortressState) -> EntitySpawn         # reino 0, los 17 campos
	static func for_projectile(net_id: int, spawn_tick: int, shooter_realm: int, shooter_id: int,
			definition: int, source_of_shot: int, index_in_volley: int, harmless: bool, p0: Vector3,
			v0: Vector3) -> EntitySpawn
	func is_harmless() -> bool
	func to_object_state() -> ObjectState
class ObjectField:                                       # u8 field_id, u8 value_type, valor
	enum ValueType { U8 = 1, U16 = 2, U32 = 3, S32 = 4 }
	var field_id: int; var value_type: int; var value: int
	static func make(id: int, type: int, field_value: int) -> ObjectField
	static func size_of_type(type: int) -> int           # 0 si no existe
class ObjectState:                                       # OBJECT_STATE (v3)
	var net_id: int; var tick: int; var fields: Array[ObjectField]
	static func from_fortress(object_id: int, state_tick: int, state: FortressState) -> ObjectState
	static func from_fortress_fields(object_id: int, state_tick: int, state: FortressState,
			field_ids: PackedInt32Array) -> ObjectState
	static func from_fortress_changes(object_id: int, state_tick: int, state: FortressState,
			previous: FortressState) -> ObjectState       # fields vacío si nada cambió: no hay nada que mandar
	func add_field(field_id: int, type: int, field_value: int) -> void
	func get_field(field_id: int) -> ObjectField          # null si no está
	func get_value(field_id: int, default: int = 0) -> int
	func apply_to_fortress(state: FortressState) -> int   # campos aplicados; salta desconocidos y de otro tipo
	func is_valid_for_fortress() -> bool
class EntityDespawn:
	var net_id: int; var despawn_tick: int; var reason: int
class Notice:
	var code: int; var text: String
class EntityEvent:
	enum Kind { HIT = 1, DEATH = 2, KILL = 3, RESPAWN = 4, WAR = 5, TELEGRAPH = 6, STATUS = 7, HEAL = 8,
			LOADOUT = 9, DOWNED = 10, INTERACT = 11 }                               # 7 a 11: v6
	enum StatusOp { APPLIED = 1, REMOVED = 2 }                                     # v6
	enum InteractOp { REVIVE = 1, REVIVE_CUT = 2, REVIVED = 3, EXECUTE = 4, EXECUTE_CUT = 5 }   # v6
	const SHAPE_CIRCLE: int = 0; const SHAPE_SECTOR: int = 1
	const MAX_ASSISTANTS: int = 16
	const HIT_FLAG_CRITICAL: int = 1 << 0; const HIT_FLAG_BLOCKED: int = 1 << 1
	const HIT_FLAG_PARRIED: int = 1 << 2; const HIT_FLAG_GUARD_BREAK: int = 1 << 3
	const HIT_FLAG_LETHAL: int = 1 << 4
	const HIT_FLAG_INTERRUPTED: int = 1 << 5; const HIT_FLAG_DOWNED: int = 1 << 6  # v6
	var net_id: int; var tick: int; var event: int
	var attacker: int; var amount: int; var damage_type: int; var hit_flags: int   # HIT (DOWNED: attacker; HEAL: amount)
	var attack_id: int                                    # la fuente (CombatSource, v6) de HIT, DEATH, KILL, TELEGRAPH, HEAL y DOWNED
	var killer: int; var assistants: PackedInt32Array                               # DEATH, KILL
	var point: int                                                                  # RESPAWN
	var war_event: int; var war_realm: int                                          # WAR (v3)
	var shape: int; var position: Vector3; var yaw: float                           # TELEGRAPH (v3),
	var radius_cm: int; var impact_in_ticks: int                                    # con attack_id
	var source_entity: int; var op: int; var status_id: int; var stacks: int        # STATUS (v6)
	var until_tick: int; var healer: int                                            # STATUS, HEAL (v6)
	var template_id: int; var weapon_1: int; var weapon_2: int; var charges: int    # LOADOUT (v6)
	var actor: int; var end_tick: int                                               # INTERACT (v6), con op
	static func hit(victim_id: int, event_tick: int, attacker_id: int, damage: int,
			type_of_damage: int, flags: int, id_of_attack: int) -> EntityEvent
	static func death(victim_id: int, event_tick: int, killer_id: int, id_of_attack: int) -> EntityEvent
	static func kill(victim_id: int, event_tick: int, killer_id: int, id_of_attack: int,
			assistant_ids: PackedInt32Array) -> EntityEvent
	static func respawn(entity_id: int, event_tick: int, point_index: int) -> EntityEvent
	static func war(fortress_id: int, event_tick: int, war_event_id: int, realm_code: int) -> EntityEvent
	static func telegraph(npc_id: int, event_tick: int, id_of_attack: int, area_shape: int,
			origin: Vector3, area_yaw: float, area_radius_cm: int, ticks_to_impact: int) -> EntityEvent
	static func status(target_id: int, event_tick: int, author_id: int, operation: int, id_of_status: int,
			stack_count: int, ends_at: int) -> EntityEvent                         # v6
	static func heal(target_id: int, event_tick: int, healer_id: int, healed_amount: int,
			source: int) -> EntityEvent                                            # v6
	static func loadout(player_id: int, event_tick: int, id_of_template: int, first_weapon: int,
			second_weapon: int, consumable_charges: int) -> EntityEvent            # v6
	static func downed(victim_id: int, event_tick: int, attacker_id: int, source: int) -> EntityEvent   # v6
	static func interact(downed_id: int, event_tick: int, actor_id: int, operation: int,
			ends_at: int) -> EntityEvent                                           # v6
	func get_source() -> int                                                        # 0 en los que no la llevan
class RespawnRequest:
	var point_index: int
class UnstuckRequest:                                    # UNSTUCK_REQUEST (v3), 1 B
	pass
class LoadoutSelect:                                     # LOADOUT_SELECT (v6), 2 B
	var template_id: int
	static func make(id_of_template: int) -> LoadoutSelect
class ScoreRow:                                          # 18 B
	var net_id: int; var kills: int; var deaths: int; var assists: int
	var gate_damage: int; var circle_seconds: int; var merits: int
class Scoreboard:                                        # SCOREBOARD (v3)
	const MAX_ROWS: int = 66
	var page_index: int; var page_count: int; var rows: Array[ScoreRow]
	static func split(all_rows: Array[ScoreRow]) -> Array[Scoreboard]

# net_sim.gd
class_name NetSim extends RefCounted
class Packet:
	var peer_id: int; var channel: int; var bytes: PackedByteArray; var is_auth: bool
	var due_tick: int
## null si spec está vacío. Formato: "rtt=120,jitter=20,loss=5,dup=0,seed=1".
static func from_arg(spec: String, seed_offset: int = 0) -> NetSim
func configure(rtt_ms: int, jitter_ms: int, loss_percent: float, duplicate_percent: float,
		seed: int) -> void
func is_enabled() -> bool
## Retardo máximo de un sentido, en ticks: rtt/2 + jitter redondeado (S4).
func get_max_delay_ticks() -> int
func enqueue(packet: NetSim.Packet, now_tick: int) -> void
func pop_due(now_tick: int) -> Array[NetSim.Packet]
func describe() -> String

# net_transport.gd
class_name NetTransport extends Node
signal peer_authenticating(peer_id: int)
signal auth_received(peer_id: int, bytes: PackedByteArray)
signal peer_connected(peer_id: int)          # autenticación completada en ambos lados
signal peer_disconnected(peer_id: int)
signal packet_received(peer_id: int, bytes: PackedByteArray)
signal connection_failed()
## Solo servidor (S1): paquetes de un peer descartados por no ser del protocolo (ver 2).
signal packets_discarded(peer_id: int, count: int)
## Antes de host()/connect_to(). Vacío = sin simulador.
func set_net_sim_spec(spec: String) -> void
func host(port: int, max_peers: int) -> Error
func connect_to(address: String, port: int, connect_timeout_ms: int = 3000) -> Error
func is_server() -> bool
## ERR_UNAVAILABLE si el peer aún no está conectado.
func send(peer_id: int, channel: int, bytes: PackedByteArray) -> Error
func send_auth(peer_id: int, bytes: PackedByteArray) -> Error
func complete_auth(peer_id: int) -> Error
## Vacía la cola y llama a peer_disconnect_later(); disconnect_peer forzado a los 60 ticks.
func disconnect_after_flush(peer_id: int) -> void
func poll(now_tick: int) -> void
func flush() -> void
func close() -> void
func get_rtt_ms(peer_id: int) -> float
## Retardo máximo (ticks) que los simuladores de este transporte añaden a un viaje de ida y vuelta (S4).
func get_sim_round_trip_ticks() -> int
func get_packet_loss(peer_id: int) -> float
func get_remote_address(peer_id: int) -> String
## {"app_in": int, "app_out": int, "wire_in": int, "wire_out": int} acumulados.
func get_byte_counters() -> Dictionary

# guarded_enet_peer.gd (S1): el peer que ve SceneMultiplayer en el servidor
class_name GuardedEnetPeer extends MultiplayerPeerExtension
signal packets_discarded(peer_id: int, count: int)     # al final de cada poll
var admitted: Dictionary                               # peers admitidos por SceneMultiplayer (lo rellena el dueño)
var raw_sink: Callable                                 # (peer_id, payload) -> void: atajo de los RAW
func attach(inner: ENetMultiplayerPeer) -> void
func mute_peer(peer_id: int) -> void                   # descarta sin contar
func get_discarded_total() -> int
```

### 17.4 `scripts/server/` (servidor)

```gdscript
# server_config.gd
class_name ServerConfig extends RefCounted
var port: int = NetProtocol.DEFAULT_PORT
var zone_id: String = ""
const DEFAULT_MAX_PLAYERS: int = 64
var max_players: int = DEFAULT_MAX_PLAYERS   # from_args: el de NetZones.max_players(zona) si lo tiene
var max_connections_per_ip: int = 4
var idle_quit_seconds: int = 0
var quit_after_ticks: int = 0
var report_path: String = ""
var state_log_path: String = ""
var stop_file_path: String = ""     # S5: su existencia pide el cierre ordenado (se mira cada segundo)
var net_sim_spec: String = ""
var fake_players: int = 0
var debug_commands: bool = false
var dev_lock: bool = false
static func from_args(args: PackedStringArray) -> ServerConfig

# server_main.gd (+ scenes/server/server_main.tscn)
## Ajustes de 1.3, carga la zona con NetZones, prepara Terrain3D, crea NetTransport y
## ZoneServer, escribe y borra user://dev_server.json (con --dev-lock) y cierra con
## --quit-after-ticks, --idle-quit o la aparición del archivo de --stop-file. Con --report reescribe
## el informe cada 600 ticks (S5). SIGTERM y SIGINT no cierran de forma ordenada (ver 1.3).
class_name ServerMain extends Node
static var config: ServerConfig

# zone_server.gd
class_name ZoneServer extends Node
signal tick_finished(tick: int)
signal player_joined(peer_id: int, net_id: int)
signal player_left(peer_id: int, net_id: int)
var interest_policy: InterestPolicy = InterestPolicy.new()
## Solo pruebas: plazos y topes que se acortan (valores por defecto: las constantes del mismo nombre).
var loading_timeout_ticks: int = LOADING_TIMEOUT_TICKS
var hello_timeout_ticks: int = HELLO_TIMEOUT_TICKS      # S2: 90
var kick_cooldown_ticks: int = KICK_COOLDOWN_TICKS      # S6: 1800
var max_logged_players: int = MAX_LOGGED_PLAYERS        # S3: 1000
var max_logged_kicks: int = MAX_LOGGED_KICKS            # S3: 200
const RTT_SLACK_TICKS: int = 3                          # S4
func start(config: ServerConfig, world: Node3D, transport: NetTransport,
		auth_provider: AuthProvider) -> Error
func stop(notice_text: String = "") -> void
func get_tick() -> int
func get_peer(peer_id: int) -> ServerPeer
func get_peer_ids() -> PackedInt32Array
func get_player_count() -> int
func get_registry() -> NetEntityRegistry
func get_history() -> StateHistory
func get_metrics() -> ServerMetrics
func get_cooldown_count() -> int                        # S6: enfriamientos tras expulsiones sin purgar
## Jugador sin red: sus entradas salen de brain y entran directamente en su InputQueue.
func add_fake_player(brain: BotBrain, realm: int, template_id: int = 0) -> int   # v6: su plantilla (0 = la de por defecto)
## Teletransporte autoritativo: sube el contador de teletransporte.
func teleport(net_id: int, position: Vector3) -> void
func write_report(path: String) -> Error

# server_peer.gd
class_name ServerPeer extends RefCounted
enum State { AUTHENTICATING, LOADING, IN_WORLD, LEAVING }
var peer_id: int
var state: State = State.AUTHENTICATING
var realm: int
var display_name: String
var remote_address: String
var entity: NetEntity
var input_queue: InputQueue
var relevant: Dictionary[int, bool] = {}
var priority: Dictionary[int, float] = {}
var ack_snapshot_tick: int = 0
var interp_delay_q: int = 0
var rtt_ticks: int = 0              # mín. de (s - ack_snapshot_tick) en los últimos 120 ticks
var connected_tick: int = 0         # S2: para el plazo del HELLO
var loading_since_tick: int = 0
var limiter_unreliable: RateLimiter
var limiter_reliable: RateLimiter
var limiter_bytes: RateLimiter
var pending_template_id: int = -1   # v6: la plantilla de LOADOUT_SELECT para la siguiente aparición (-1 = ninguna)
## Suma un aviso; devuelve true si hay que expulsar (50 en 600 ticks).
func add_strike(now_tick: int, reason: String) -> bool
## N2: crédito de los ticks que el servidor no ha simulado (un parón) para los tres limitadores.
func grant_stall_credit(now_tick: int, missed_ticks: int) -> void

# server_auth.gd
class_name ServerAuth extends RefCounted
func _init(config: ServerConfig, sim_hash: int, allowed_realms: PackedInt32Array,
		provider: AuthProvider) -> void
## Devuelve un NetProtocol.Result.
func validate(hello: NetMessages.Hello, remote_address: String, player_count: int,
		connections_from_address: int) -> int
## SOC-01: fuente de los nombres ya conectados (Callable sin argumentos -> PackedStringArray).
func set_connected_names_source(source: Callable) -> void
func check_name(display_name: String) -> int   # NameRules.Reason (TAKEN si ya está conectado)
## S2: clave con la que se cuentan las conexiones por IP (IPv6 por prefijo /64, IPv4 mapeada como IPv4).
static func address_group(remote_address: String) -> String

# auth_provider.gd
class_name AuthProvider extends RefCounted
## Identidad y reino: OK o TICKET. Base de DevAuthProvider y del futuro TicketAuthProvider.
func authenticate(hello: NetMessages.Hello) -> int
## Desde la fase 5 (plataforma.md §14.3): authenticate(peer_id, hello) -> int (OK, PENDING = -1 o
## motivo), on_platform_event(event) -> bool, take_completed() -> Array[AuthOutcome],
## cancel(peer_id) y uses_tickets() -> bool.

# dev_auth_provider.gd
class_name DevAuthProvider extends AuthProvider   # acepta el reino y el nombre declarados

# rate_limiter.gd: cubo de fichas medido en ticks
class_name RateLimiter extends RefCounted
func _init(rate_per_tick: float, burst: float) -> void
func try_consume(now_tick: int, cost: float = 1.0) -> bool
## N2: suma fichas por encima de la ráfaga hasta la siguiente recarga (primero recarga, después suma).
func grant(now_tick: int, extra: float) -> void

# input_queue.gd
class_name InputQueue extends RefCounted
enum PushResult { ACCEPTED, DUPLICATE, LATE, TOO_EARLY }
const CAPACITY: int = 64
var late_count: int = 0
var too_early_count: int = 0
var substitutions_total: int = 0
func reset(spawn_tick: int, neutral: PlayerInput) -> void
func push(input: PlayerInput, view_offset_q: int, next_tick: int) -> PushResult
func take(tick: int) -> PlayerInput
func get_ack_tick() -> int
func pop_min_lead() -> int
func get_view_offset_q(tick: int) -> int
func get_last_consumed() -> int

# net_entity.gd
class_name NetEntity extends RefCounted
const FLAG_ALWAYS_RELEVANT: int = 1 << 0
var net_id: int
var kind: int
var realm: int
var spawn_tick: int
var owner_peer: int = 0
var display_name: String
var flags: int = 0
var node: Node3D
var teleport_counter: int = 0
const DEFAULT_HEALTH: int = 1000
var health_q: int = EntityRecord.HEALTH_Q_FULL     # último byte del registro
var health: int = DEFAULT_HEALTH; var max_health: int = DEFAULT_HEALTH   # bloque extra propio
var status: int = 0; var respawn_tick: int = 0
## Lo llama quien lleva la vida (Combatant) cada tick; calcula health_q.
func set_health_view(new_health: int, new_max_health: int, new_status: int,
		new_respawn_tick: int) -> void
func get_position() -> Vector3
func get_character() -> PlayerCharacter            # null si no es un jugador
func encode_record(bytes: PackedByteArray, offset: int) -> void
func encode_spawn(tick: int, for_owner: bool) -> PackedByteArray

# net_entity_registry.gd
class_name NetEntityRegistry extends RefCounted
const ID_QUARANTINE_TICKS: int = 600
func allocate(kind: int, now_tick: int) -> NetEntity    # net_id 1..65535; null si no queda
func release(net_id: int, now_tick: int) -> void
func get_entity(net_id: int) -> NetEntity
func get_sorted() -> Array[NetEntity]
func size() -> int
# v6 (habilidades.md 4.4, H3b): ids de los proyectiles, del mismo espacio y con la misma cuarentena
func allocate_transient_id(now_tick: int) -> int    # 0 si no queda
func release_transient_id(net_id: int, now_tick: int) -> void

# spawn_picker.gd
class_name SpawnPicker extends RefCounted
func _init(world: Node) -> void
## Reparte en rueda los puntos del reino (ver 1.5).
func pick(realm: int) -> Transform3D

# snapshot_builder.gd
class_name SnapshotBuilder extends RefCounted
func _init(policy: InterestPolicy) -> void
func begin(tick: int, entities: Array[NetEntity]) -> void
## Nunca devuelve más de MAX_PACKET_BYTES. Consume pop_min_lead() de la cola del peer.
func build_for(peer: ServerPeer) -> PackedByteArray

# interest_policy.gd: la base lo considera todo relevante y con peso 1
class_name InterestPolicy extends RefCounted
func is_relevant(observer: NetEntity, entity: NetEntity, was_relevant: bool) -> bool
func priority_weight(observer: NetEntity, entity: NetEntity) -> float

# state_history.gd
class_name StateHistory extends RefCounted
const LENGTH_TICKS: int = 64
class Sample:
	var position: Vector3; var yaw: float; var flags: int
func add_entity(net_id: int) -> void
func forget(net_id: int) -> void
func record(tick: int, net_id: int, position: Vector3, yaw: float, flags: int) -> void
func has_tick(net_id: int, tick: int) -> bool
func sample(net_id: int, tick: float) -> StateHistory.Sample     # null si está fuera de rango
# v6 (habilidades.md 4.4, H3b): proyectiles
func position_at(net_id: int, tick: int) -> Vector3     # Vector3.INF si no está; sin crear objetos
func swept_box(net_id: int) -> AABB     # 4 bloques de 8 ticks hasta el último grabado; size.x < 0 sin nada

# server_metrics.gd
class_name ServerMetrics extends RefCounted
func register_monitors() -> void
func begin_tick() -> void
func begin_section(section: StringName) -> void
func end_section(section: StringName) -> void
func end_tick(tick: int) -> void
func add_counter(counter: StringName, amount: int) -> void
func summary() -> Dictionary     # p50/p99/máx por sección, KB/s, jugadores, % sustituidas
```

### 17.5 `scripts/client/` (cliente)

```gdscript
# client_config.gd
class_name ClientConfig extends RefCounted
enum Mode { OFFLINE, ONLINE, LOCAL, BOT, SWARM }
var mode: Mode = Mode.OFFLINE
var address: String = "127.0.0.1"
var port: int = NetProtocol.DEFAULT_PORT
var realm: int = NetProtocol.Realm.NONE
var display_name: String = ""
var net_sim_spec: String = ""
var bot_seed: int = 1
var bot_count: int = 0
var bot_cheat: String = ""
var quit_after_ticks: int = 0
var report_path: String = ""
var state_log_path: String = ""
var loadout: String = ""        # v6: --loadout=<plantilla>; sale en un LOADOUT_SELECT tras el WELCOME
static func from_args(args: PackedStringArray) -> ClientConfig

# online_main.gd (+ scenes/client/online_main.tscn)
## Flujo: RealmSelect si falta el reino → NetTransport y NetClient.start() → welcomed: carga
## la zona en un hilo → notify_zone_ready() → local_spawned: cámara, HUD y overlay (en modo
## BOT, controller.set_bot() y nada más). rejected/disconnected: aviso en español y vuelta a
## RealmSelect (en modo BOT, salir con código 1). Ajustes: multiplayer_poll = false; en
## headless, max_fps = 120. No modifica ClientMain: el sandbox sigue igual.
class_name OnlineMain extends Node
static var config: ClientConfig

# net_client.gd
class_name NetClient extends Node
signal welcomed(welcome: NetMessages.Welcome)
signal rejected(result: int, text: String)
signal local_spawned(character: PlayerCharacter)
signal disconnected(text: String)
## v6 (habilidades.md 5.3): el SPAWN se reparte por kind antes que por is_yours; los proyectiles no son
## personajes y salen por aquí, con su DESPAWN.
signal projectile_spawned(spawn: NetMessages.EntitySpawn)
signal projectile_despawned(projectile_id: int, tick: int, reason: int)
func start(config: ClientConfig, transport: NetTransport,
		controller: LocalPlayerController) -> Error
## v6 (habilidades.md 6, H4): LOADOUT_SELECT desde el WELCOME; los STATUS de cada entidad en su
## StatusTracker (el de un remoto, en su tick de dibujo, también los propios: revisión de la fase 4);
## las flechas en el ProjectileWorld (que entra en la zona con el RemoteWorld).
func send_loadout_select(template_id: int) -> bool
func get_status_tracker(net_id: int) -> StatusTracker
func get_projectile_world() -> ProjectileWorld
func is_downed() -> bool
## Envía CLIENT_READY (solo tras peer_connected(1)). world_root recibe al personaje local
## y a RemoteWorld.
func notify_zone_ready(world_root: Node3D) -> void
func leave() -> void
func send_debug_command(command: int, payload: PackedByteArray) -> void
func get_character() -> PlayerCharacter
func get_prediction() -> ClientPrediction
func get_remote_world() -> RemoteWorld
func get_tick_sync() -> TickSync
func get_interpolation_clock() -> InterpolationClock
func get_local_tick() -> int
func get_last_server_state() -> PlayerState
func get_stats() -> Dictionary
## Bots: snapshots con estado, coincidencias exactas, diferencias explicadas (sustitución,
## teletransporte, combate: combat_diffs, o la puerta del fuerte: gate_diffs) y sin explicar, resincronizaciones, ajustes de TickSync y
## estado final.
func write_report(path: String) -> Error

# client_prediction.gd
class_name ClientPrediction extends RefCounted
## v6 (H4): tras cada step() (nunca en las repeticiones); ProjectileWorld mira ahí el compromiso.
signal stepped(tick: int, input: PlayerInput, state: PlayerState)
enum Result { IGNORED, MATCH, CORRECTED, HARD_RESET }
const HISTORY_SIZE: int = 256
const SNAP_DISTANCE: float = 3.0
const CORRECTION_REPORT_DISTANCE: float = 0.001
func setup(character: PlayerCharacter, controller: LocalPlayerController,
		smoother: CorrectionSmoother, delta: float) -> void
func start(spawn_tick: int, spawn_state: PlayerState, first_real_tick: int) -> void
func is_started() -> bool
func step() -> PlayerInput
func on_server_state(server_tick: int, state: PlayerState, teleported: bool) -> int
func hard_reset(tick: int, state: PlayerState) -> void
func get_predicted_tick() -> int
func get_first_real_tick() -> int
func get_input(tick: int) -> PlayerInput            # null si no está en el anillo
func get_predicted_state(tick: int) -> PlayerState  # null si no está en el anillo
func is_replaying() -> bool
func get_stats() -> Dictionary

# correction_smoother.gd
class_name CorrectionSmoother extends RefCounted
const HALF_LIFE_TICKS: float = 6.0
const MIN_OFFSET: float = 0.001
## Guarda la posición local base de cada destino (Visual y CameraTarget).
func setup(character: PlayerCharacter, targets: Array[Node3D]) -> void
func add_offset(world_offset: Vector3) -> void
func clear() -> void
## Dentro del tick de física: decae y aplica base + basis.inverse() * offset.
func physics_step() -> void
func get_offset() -> Vector3

# tick_sync.gd
class_name TickSync extends RefCounted
const WINDOW_SAMPLES: int = 15
const MIN_TARGET: int = 1
const MAX_TARGET: int = 4
const RESYNC_BEHIND: int = -8
const MAX_RESYNC_STEPS: int = 30
var adjustments: int = 0
## Devuelve P0, el primer tick con entrada real.
func start(spawn_tick: int, rtt_ticks: int) -> int
func set_jitter(jitter_ticks: float) -> void
func on_snapshot(input_ack_tick: int, input_margin: int) -> void
func next_steps(predicted_tick: int) -> int
func get_target_margin() -> int
func get_window_min() -> int        # NO_MARGIN si la ventana está vacía

# interpolation_clock.gd
class_name InterpolationClock extends RefCounted
const WINDOW_TICKS: int = 120
func on_snapshot(server_tick: int, local_tick: int) -> void
func advance(local_tick: int) -> float
func get_render_tick() -> float
func get_delay_ticks() -> float
func get_jitter_ticks() -> float

# remote_interpolator.gd
class_name RemoteInterpolator extends RefCounted
const BUFFER_SIZE: int = 32
const MAX_EXTRAPOLATION_TICKS: int = 6
func push(tick: int, record: EntityRecord) -> void
func sample(render_time: float) -> EntityRecord     # null si no hay muestras
func get_newest_tick() -> int

# remote_world.gd
class_name RemoteWorld extends Node3D
func setup(clock: InterpolationClock) -> void
func on_spawn(msg: NetMessages.EntitySpawn) -> void
func on_despawn(msg: NetMessages.EntityDespawn) -> void
func on_snapshot(snapshot: NetMessages.Snapshot) -> void
func get_view(net_id: int) -> RemotePlayerView
func get_view_count() -> int
## render_tick + fracción usado en el último _process.
func get_last_drawn_render_tick() -> float

# remote_player_view.gd
class_name RemotePlayerView extends Node
func setup(body: PlayerCharacter, spawn: NetMessages.EntitySpawn) -> void
func push(tick: int, record: EntityRecord) -> void
func apply(render_time: float, real_delta: float) -> void
func schedule_despawn(tick: int) -> void
func is_expired(render_time: float) -> bool
func get_drawn_position() -> Vector3

# local_server_launcher.gd
class_name LocalServerLauncher extends RefCounted
const LOCK_PATH: String = "user://dev_server.json"
static func build_args(port: int, extra_args: PackedStringArray) -> PackedStringArray
static func find_running(port: int) -> bool
func launch(port: int, extra_args: PackedStringArray) -> int    # pid, o -1

# net_debug_overlay.gd (+ scenes/ui/net_debug_overlay.tscn)
class_name NetDebugOverlay extends CanvasLayer
func bind(client: NetClient) -> void

# realm_select.gd (+ scenes/ui/realm_select.tscn)
class_name RealmSelect extends Control
signal realm_chosen(realm: int, address: String, display_name: String)
func setup(default_address: String, default_name: String, allowed: PackedInt32Array) -> void

# bot_swarm.gd (+ scenes/client/bot_swarm.tscn)
class_name BotSwarm extends Node
## Crea config.bot_count SwarmBot, uno cada 5 ticks, cada uno con su NetTransport.
func start(config: ClientConfig) -> void

# swarm_bot.gd
## Bot ligero que no simula ni carga la zona. Usa TickSync e InterpolationClock reales, genera
## entradas con BotBrain (guiado por la posición de su estado en el snapshot) y confirma
## snapshots.
class_name SwarmBot extends Node
func setup(index: int, config: ClientConfig) -> void
```

### 17.6 Escenas nuevas

| Escena | Raíz | Script |
|---|---|---|
| `scenes/server/server_main.tscn` | `Node` «ServerMain» | `server_main.gd` |
| `scenes/client/online_main.tscn` | `Node` «OnlineMain» | `online_main.gd` |
| `scenes/client/bot_swarm.tscn` | `Node` «BotSwarm» | `bot_swarm.gd` |
| `scenes/ui/realm_select.tscn` | `Control` | `realm_select.gd` |
| `scenes/ui/net_debug_overlay.tscn` | `CanvasLayer` | `net_debug_overlay.gd` |

Los remotos reutilizan `scenes/characters/player_character.tscn`.

### 17.7 Archivos existentes que cambian

- **`scripts/shared/player_state.gd`:** `to_f32()` y `equals_exact()`.
- **`scripts/shared/player_character.gd`:** yaw redondeado en el setter y `events_enabled`. Las
  pruebas de la fase 1 deben seguir pasando.
- **`scripts/client/local_player_controller.gd`.** El sandbox no cambia de comportamiento:
  `input_generated`, `get_input_history()` y `get_tick()` se mantienen.
  ```gdscript
  ## true (sandbox): avanza un tick por paso de física como ahora. false: lo avanza ClientPrediction.
  var auto_step: bool = true
  ## Dispositivo, demo o bot, más las pulsaciones acumuladas; cuantizada; emite input_generated.
  ## No simula.
  func build_input(tick: int) -> PlayerInput
  ## En ticks sin paso: guarda los just_pressed para el siguiente build_input().
  func accumulate_presses() -> void
  ## Las entradas salen de brain.next_input(tick, posición, yaw).
  func set_bot(brain: BotBrain) -> void
  ```
- **`scripts/boot.gd`:** los modos de [1.2](#12-modos-de-arranque). Rellena `ServerMain.config`
  con `from_args()` y cambia a la escena del servidor; para el cliente instancia
  `scenes/client/client_launcher.tscn`, cuyo `ClientLauncher` (`scripts/client/client_launcher.gd`)
  rellena `OnlineMain.config`, `BotSwarm.config` o las variables estáticas de `ClientMain` y cambia
  a la escena correspondiente.
- **`project.godot`:** `physics/common/physics_ticks_per_second=60` explícito. Lo toca también el
  flujo de arte: hay que fusionar, no sobrescribir.
- **`tests/test_architecture.gd`:** las reglas de [16](#arquitectura-test_architecture-ampliado)
  y la lista de scripts obligatorios de `net/`.
- **`CLAUDE.md`:** una línea con la regla «`scripts/server/` y `scripts/client/` no dependen el
  uno del otro».

### 17.8 Pruebas y herramientas nuevas

- **`tests/net_harness.gd`** (`class_name NetHarness extends RefCounted`):
  ```gdscript
  static func free_udp_port(start: int = 24700) -> int
  static func make_world_viewport(parent: Node, world_scene_path: String) -> SubViewport  # own_world_3d
  static func start_server(viewport: SubViewport, config: ServerConfig) -> ZoneServer
  static func start_bot(viewport: SubViewport, port: int, realm: int, seed: int,
  		net_sim_spec: String = "") -> NetClient
  static func launch_process(user_args: PackedStringArray, log_name: String) -> int
  static func read_report(path: String) -> Dictionary
  # Añadidos tras la revisión de la fase 2 (A1, A5, A7):
  static func first_port_for(pid: int) -> int             # ranura de puertos de cada proceso de pruebas
  static func get_build_dir() -> String                   # build/<pid>/, creada; borra las de procesos muertos
  static func build_path(file_name: String) -> String     # un archivo dentro de build/<pid>/
  static func clean_stale_build_dirs() -> int
  static func launch_script(script_path: String, user_args: PackedStringArray, log_name: String) -> int
  static func error_lines(log_path: String) -> PackedStringArray  # ERROR / SCRIPT ERROR de un registro
  ```
  `tests/process_probe.gd` es el proceso auxiliar de `launch_script` (no es una prueba).
- **Pruebas:** `test_net_messages.gd`, `test_input_queue.gd`, `test_tick_sync.gd`,
  `test_interpolation_clock.gd`, `test_remote_interpolator.gd`, `test_state_history.gd`,
  `test_net_sim.gd`, `test_snapshot_builder.gd`, `test_rate_limiter.gd`, `test_server_auth.gd`,
  `test_prediction.gd`, `test_net_loopback.gd` y `test_net_processes.gd`.
- **Herramientas:** `tools/compare_state_logs.gd` y `tools/load_test.gd`, ambas scripts
  `SceneTree`. El cálculo del resumen de carga que no necesita procesos (la ventana de medida de las
  entradas sustituidas) está en `tools/load_test_summary.gd` (`LoadTestSummary`), y
  `tests/test_load_test.gd` carga la herramienta y lo prueba.

---

## 18. Orden de implementación

1. **M1, piezas puras.** Paquetes A y B, más las unitarias de C y D: `InputQueue`,
   `SnapshotBuilder`, `StateHistory`, `TickSync`, `InterpolationClock`, `RemoteInterpolator`.
   Todo con pruebas, sin red.
2. **M2, conectar y verse.** `NetTransport`, el handshake, `ZoneServer` con altas, bajas y
   snapshots, `RemoteWorld` y `OnlineMain`, con `test_net_loopback` a y b.
3. **M3, predicción.** `ClientPrediction`, `CorrectionSmoother` y `TickSync` integrados, con
   `test_prediction` y `test_net_loopback` c y e.
4. **M4, condiciones reales.** `NetSim` en las integraciones (`test_net_loopback` d), overlay F3
   y F4, `--local`, `RealmSelect`.
5. **M5, procesos, carga y seguridad.** Bots, `test_net_processes`, `BotSwarm`, `load_test`,
   limitadores, avisos y bot tramposo. Se anotan las medidas para Eldrun.

---

## 19. Riesgos abiertos

- **Terrain3D.** El servidor y el cliente deben generar la misma colisión: modo completo en los
  dos lados. El modo dinámico depende de la cámara y troceado de otra forma podría cambiar el
  último bit de las consultas.
  - El arranque headless ya lo fija `tests/test_terrain3d_headless.gd`.
  - `test_net_processes` lo valida con la zona real.
- **Jolt entre procesos.** Es el mismo binario, pero el servidor tiene cuerpos de otros
  personajes en su espacio de física y el cliente no. No están en la máscara;
  `test_net_processes` lo confirma.
- **Entre plataformas.** Jolt no se compila en modo determinista multiplataforma en Godot, y la
  libm cambia. Con un servidor Linux y clientes Windows habrá diferencias en el último bit, que
  la reconciliación absorbe. Se medirá su frecuencia cuando haya servidor Linux.
- **CPU en GDScript.** No se sabe aún cuánto cuesta `simulate()` por personaje en el servidor.
  Se mide en M5 antes de fijar el tamaño de las batallas.
- **Contrato con el flujo de arte:**
  - lo solo visual cuelga de `Visual`, y existe `CameraTarget`;
  - la animación lee `velocity`, `grounded`, `yaw` y las señales `jumped`/`landed`;
  - `zones.gd` ofrece lo que pide `NetZones`.

  Si algo de esto cambia, solo hay que tocar `ServerMain`, `RemotePlayerView`,
  `CorrectionSmoother` o `NetZones`.
- **Cuantización vertical:** sobrada (±5,24 km). La horizontal exige zonas centradas en el
  origen.

---

## Anexo: correcciones respecto a las propuestas

| Problema detectado por los jueces | Corrección en este diseño |
|---|---|
| Snapshot de más de 1200 B con 64 jugadores visibles (A y C) | Presupuesto con acumulador de prioridad (57 registros por paquete en la fase 2, 52 desde la fase 3, 50 desde el protocolo 6); garantía de envío al menos cada ⌈N/C⌉ snapshots |
| `input_ack_tick` atascado tras una sustitución (A) | `max(contiguo recibido, último consumido)` |
| Reconciliación con `is_close_to`, sin `prev_buttons` (A) | `equals_exact` sobre `encode()`, posible gracias al yaw en f32 |
| Yaw en f64 frente a f32 en la red (B y C no lo veían) | Redondeo en el setter de `PlayerCharacter.yaw` |
| Entrada neutra con botones a 0 (A) y `synthesized()` solo con SPRINT/BLOCK (C): flancos inventados | La sustituta repite la máscara completa; tras 6 ticks solo pone `move = 0` |
| Repetición sin fin de la última entrada (B) | Movimiento a 0 tras 6 ticks sin entradas reales |
| Banda de margen fija y medida ambigua (A) | Objetivo según el jitter, mínimo en una ventana de 15 muestras, solo primeras copias, sustituciones aparte |
| Lazo de control con sobreimpulso (B) | Espera hasta el ack posterior al ajuste y deuda proporcional |
| Resincronización dura hacia atrás (A) | Solo hacia delante; si va adelantado, se retrasa poco a poco |
| Pulsaciones perdidas en los ticks de 0 pasos (A, B) | `accumulate_presses()` y `build_input()` |
| Desfase del suavizado en espacio de mundo (A) | `basis.inverse() * offset` recalculado cada tick |
| `reset_physics_interpolation()` en cada corrección (B) | Desfase en el tick de física; reset solo al teletransportarse |
| Tope de rebobinado de 15 ticks que incluía el retardo de interpolación (A) | 24 ticks absolutos más un tope por sesión con el RTT, la antelación y el retardo declarado |
| `view_delay_q` por lote (A) | `view_offset_q` por entrada |
| Sesgo de medio tick al dibujar los remotos (A) | Remotos en `_process` con interpolación de física apagada, en `render_tick + fracción` |
| Desfase de un tick en la aparición (A) | Alta tras simular el tick S, con el estado «tras S»; primera simulación en S+1 |
| Arranque sin definir (B) | P0 con dos medidas de RTT y avance neutro idéntico a la sustitución del servidor |
| `CLIENT_READY` o PING justo tras `complete_auth()` dan `ERR_BUG` (A, C) | Nada por `send_bytes` hasta `peer_connected` |
| `--local` lento al detectar que no hay servidor (A) y huérfano con `OS.kill` (C) | Archivo de bloqueo con pid, timeout corto de ENet e `--idle-quit` |
| `low_processor_usage_mode_sleep_usec = 1000` (A) y justificación falsa de `max_fps` (B, C) | `max_fps = 120`, con el motivo medido |
| Todos los snapshots en el mismo tick (A) | Escalonados por `net_id` |
| `StateHistory` con un objeto por entidad y tick (A) | Arrays empaquetados por pista, sin asignar memoria al grabar |
| `CUSTOM_CHANNELS = 4` con 3 canales en uso (A) | 3 |
| Subida subestimada (A: 6 KB/s) | 5,5–7,9 KB/s con cabeceras |
| `NetSim` y acondicionadores con reloj de pared (B, C) | Todo en ticks y con semilla; también retrasa la autenticación |
| RTT de ENet de 500 ms antes del primer ack (B) | El arranque usa RTT medido en ticks; el de ENet solo se muestra |
| Reino en base 0 sin NONE (C) | `Realm.NONE = 0` |
| `BotBrain` en el cliente (C) | En `scripts/shared/`, usable por los jugadores falsos del servidor |
| Alcance de más en la fase 2: billetes, DTLS, AuthProviders (C) | Solo la interfaz `AuthProvider` y `DevAuthProvider`; billete y DTLS en las fases 5–6, con el hueco reservado |
| Seguridad mínima (A, B) | Limitador por peer, avisos, tope por IP, máscara de botones y bot tramposo en las pruebas |
