# Eldmark · Fase 2: diseño de red

Diseño definitivo del paso 2 de la [hoja de ruta](vision.md#hoja-de-ruta): servidor dedicado
autoritativo, varios jugadores en una zona, predicción y reconciliación del jugador local,
interpolación de los demás y elección de reino.

Parte de la propuesta «simple primero», la que eligieron los tres jueces, y le injerta las
mejores ideas de «escala primero» y «seguridad primero». Corrige todos los errores técnicos que
encontraron los jueces; el resumen está en el [anexo](#anexo-correcciones-respecto-a-las-propuestas).

Se apoya en el código de la fase 1:

- `PlayerInput`: 12 B cuantizados.
- `PlayerState`: 35 B.
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
`--bots` > `--connect`/`--local`/`--bot` > sandbox.

| Argumentos | Modo | Escena |
|---|---|---|
| ninguno, `--demo`, `--shots=`, `--quit-after-demo` | Sandbox sin red de la fase 1, sin cambios | `scenes/client/client_main.tscn` |
| `--server [--port=24600] [--zone=<id>] [--max-players=64] [--max-per-ip=4] [--idle-quit=<s>] [--fake-players=N [--fake-layout=cluster\|spread] [--fake-churn=<ticks>]] [--debug-commands] [--dev-lock [--dev-lock-path=<ruta>]] [--stop-file=<ruta>]` | Servidor dedicado (siempre con `--headless`) | `scenes/server/server_main.tscn` |
| `--connect=<host>[:<puerto>] [--realm=<reino>] [--name=<nombre>]` | Cliente en red | `scenes/client/online_main.tscn` |
| `--local [--realm=…] [--name=…]` | Cliente contra un servidor local, que se lanza si no hay ninguno | `scenes/client/online_main.tscn` |
| `--bot --connect=… [--bot-seed=N] [--bot-cheat=<modo>]` | Un cliente que predice, sin cámara ni HUD, guiado por `BotBrain` | `scenes/client/online_main.tscn` |
| `--bots=N --connect=… [--bot-seed=N]` | Enjambre de N clientes ligeros que no simulan, para pruebas de carga | `scenes/client/bot_swarm.tscn` |
| Comunes | `--net-sim=rtt=120,jitter=20,loss=5,dup=0,seed=1`, `--quit-after-ticks=N`, `--report=<ruta.json>`, `--state-log=<ruta.csv>` | |

- **`--zone` y `--realm`** se leen con las utilidades de `zones.gd`, a través de `NetZones`.
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
- leer `--zone` y `--realm`.

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
  dos lados y `auth_timeout = 5.0`.
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
| 3 `CH_RELIABLE` | `TRANSFER_MODE_RELIABLE` | ambos | CLIENT_READY, CLIENT_LEAVE, DEBUG_COMMAND, ENTITY_SPAWN, ENTITY_DESPAWN y NOTICE; más adelante, OBJECT_STATE y ENTITY_EVENT |

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
   - que hay sitio;
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
| — | WELCOME | S→C | autenticación | 18 B + id de zona |
| — | REJECT | S→C | autenticación | 6 B + texto |
| `0x01` | INPUT_BATCH | C→S | 1 | 11 + 10·n B (21–91) |
| `0x02` | CLIENT_READY | C→S | 3 | 2 B |
| `0x03` | CLIENT_LEAVE | C→S | 3 | 2 B |
| `0x04` | DEBUG_COMMAND | C→S | 3 | 2 B + datos |
| `0x10` | SNAPSHOT | S→C | 2 | ≤ 1200 B |
| `0x20` | ENTITY_SPAWN | S→C | 3 | 10 B + datos |
| `0x21` | ENTITY_DESPAWN | S→C | 3 | 8 B |
| `0x22` | OBJECT_STATE (reservado, fase 4) | S→C | 3 | — |
| `0x23` | ENTITY_EVENT (reservado, fase 3) | S→C | 3 | — |
| `0x30` | NOTICE | S→C | 3 | 3 B + texto |
| `0x31` | HANDOFF (reservado, fase 6) | S→C | 3 | — |

### 5.3 Autenticación

**HELLO** (C→S)

| Offset | Tipo | Campo | Notas |
|---|---|---|---|
| 0 | u32 | magic | `0x4D444C45` |
| 4 | u16 | protocol_version | `NetProtocol.PROTOCOL_VERSION` (= 1) |
| 6 | u32 | sim_hash | ver [3](#3-conexión) |
| 10 | u8 | realm | 0 ninguno (se rechaza), 1 Vardheim, 2 Solmarch, 3 Askarra |
| 11 | u8 | flags | bit0 = bot; resto, 0 |
| 12 | u64 | character_id | 0 en la fase 2; personaje guardado desde la fase 5 |
| 20 | u8 | name_len | ≤ 48 B |
| 21 | n B | name | UTF-8, 3–24 caracteres |
| 21+n | u16 | ticket_len | 0 en la fase 2; ≤ 256 |
| 23+n | t B | ticket | sesión o billete de traspaso (fases 5–6) |

**WELCOME** (S→C)

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

**REJECT** (S→C)

| Offset | Tipo | Campo | Notas |
|---|---|---|---|
| 0 | u32 | magic | |
| 4 | u8 | result | 1 VERSION, 2 SIM_HASH, 3 REALM, 4 FULL, 5 TICKET, 6 MALFORMED, 7 TOO_MANY_CONNECTIONS, 8 NAME |
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
| +6 | u16 | buttons | `[10..11]`; el servidor aplica `& NetProtocol.VALID_BUTTONS` |
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
- Solo se acepta si el servidor arrancó con `--debug-commands`; si no, cuenta un aviso
  (*strike*, ver [12](#12-seguridad-de-la-fase-2)).

### 5.5 Servidor → cliente

**SNAPSHOT** (`0x10`, canal 2)

| Offset | Tipo | Campo | Notas |
|---|---|---|---|
| 0 | u8 | type | `0x10` |
| 1 | u32 | server_tick | estado tras simular este tick |
| 5 | u32 | input_ack_tick | `max(mayor tick contiguo recibido, último consumido)`. Nunca se atasca tras una entrada sustituida |
| 9 | s8 | input_margin | ver [4.1](#41-tick-del-servidor-y-regla-de-aplicación); −128 = sin datos |
| 10 | u16 | substitutions | total acumulado de entradas sustituidas de este jugador (mod 65536). Robusto a snapshots perdidos |
| 12 | u8 | flags | bit0 = incluye el estado propio; bits 1–2 = contador de teletransporte propio (mod 4); resto, 0 |
| 13 | 35 B | own_state | `PlayerState.encode()` sin cuantizar, si bit0. Base de la reconciliación |
| 48 (o 13) | u8 | section_count | |
| … | | secciones | cada una: `u8 kind`, `u8 count` y `count` registros del tamaño fijo de ese `kind` |

- **Capacidad.** Con estado propio, la cabecera ocupa 49 B. Con una sección de jugadores caben
  ⌊(1200 − 49 − 2) / 20⌋ = **57 registros**.
- **El propio jugador** nunca aparece entre los registros: para eso está su estado.

**Registro de entidad** (`kind` 1 PLAYER; 2 NPC reutiliza el formato), 20 B:

| Offset | Tipo | Campo | Notas |
|---|---|---|---|
| 0 | u16 | net_id | |
| 2 | u64 | position | 20 bits por eje: `q = round(v · 100) + 2^19`, saturado a [0, 2^20 − 1]. x en los bits 0–19, y en 20–39, z en 40–59; los bits 60–63 a 0. 1 cm de resolución, ±5,24 km |
| 10 | u16 | yaw | [0, TAU) → 0..65535, igual que `PlayerInput.look_yaw` |
| 12 | s16 × 3 | velocity | cm/s, saturado (±327 m/s) |
| 18 | u8 | flags | bit0 = grounded; bits 1–2 = contador de teletransporte (mod 4); resto, 0 |
| 19 | u8 | action | 0 en la fase 2; desde la fase 3, acción y fase (ataque, bloqueo, esquiva) |

- **Teletransporte.** El contador de 2 bits sustituye a un flag de un solo snapshot, que se
  perdería con ese snapshot. Si cambia entre dos muestras, no se interpola entre ellas.
- **Animación.** El esprint no viaja: el cliente lo deduce de la velocidad.

**ENTITY_SPAWN** (`0x20`, canal 3)

| Offset | Tipo | Campo | Notas |
|---|---|---|---|
| 0 | u8 | type | `0x20` |
| 1 | u16 | net_id | |
| 3 | u8 | kind | 1 PLAYER, 2 NPC, 3 PROJECTILE, 4 STRUCTURE |
| 4 | u32 | spawn_tick | tick del estado incluido |
| 8 | u8 | realm | |
| 9 | u8 | flags | bit0 = es tu personaje; bits 1–2 = contador de teletransporte |
| 10 | … | payload | según `kind`. PLAYER: `PlayerState` (35 B, estado tras `spawn_tick`), `u8 name_len` y el nombre (≤ 48 B) |

**ENTITY_DESPAWN** (`0x21`, canal 3)

| Offset | Tipo | Campo | Notas |
|---|---|---|---|
| 0 | u8 | type | `0x21` |
| 1 | u16 | net_id | |
| 3 | u32 | despawn_tick | el cliente lo quita cuando su `render_tick` llega aquí |
| 7 | u8 | reason | 0 fuera de interés, 1 desconexión, 2 muerte, 3 traspaso |

**NOTICE** (`0x30`, canal 3): `u8 type`, `u8 code`, `u8 len` y el texto en UTF-8 (≤ 200 B).

- Códigos: 0 informativo, 1 expulsión, 2 servidor cerrándose.
- Con el código 1, el servidor desconecta al peer después del `flush()`.

### 5.6 Reservados

- **OBJECT_STATE** (`0x22`, fase 4): `u8 type`, `u16 object_id`, `u32 tick`, `u8 field_count`
  y, por campo, `u8 field_id`, `u8 value_type` y el valor.
- **ENTITY_EVENT** (`0x23`, fase 3): `u8 type`, `u16 net_id`, `u32 tick`, `u8 event`, `u8 len`
  y los datos.
- **HANDOFF** (`0x31`, fase 6): zona, canal, host, puerto y billete.

Ocupar uno de estos tipos sube `PROTOCOL_VERSION`.

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

- **Envíos escalonados.** Cada cliente recibe su snapshot en los ticks de la paridad de su
  `net_id`, así que el coste se reparte entre los dos ticks del intervalo.
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
  - flag `ALWAYS_RELEVANT`, para los objetos que ve toda la zona.
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
   - el estado propio (`character.get_state().encode()`) y su contador de teletransporte.
2. Reúne las candidatas: las entidades de `peer.relevant` salvo la propia. A cada una le suma
   `peer.priority[id] += interest_policy.priority_weight(observer, entity)` (en la fase 2, 1,0).
3. Si caben todas en 1200 B, las escribe todas (el caso normal de la fase 2). Si no, elige las
   de mayor prioridad, desempatando por `net_id`, hasta llenar el presupuesto: `sort_custom` en
   la fase 2, y cubos o C++ en Eldrun si la medida lo pide.
4. Pone a 0 la prioridad de las escritas y agrupa los registros por `kind` en secciones.

**Garantía:** con 63 jugadores visibles y 57 plazas, cada entidad sale al menos uno de cada dos
snapshots. Lo comprueba `test_snapshot_builder`.

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
                  rtt_ticks + lead(T) + clamp(interp_delay_q / 8, 4, 12) + 2)
  view_tick = clamp(view_tick, T − allowed, T)
  ```
  - **`rtt_ticks`** lo mide el servidor sin reloj: es el mínimo, en los últimos 120 ticks, de
    `s − ack_snapshot_tick` al llegar cada INPUT_BATCH, **acotado por una fuente que el cliente no
    controla** (hallazgo S4): `ceil(PEER_ROUND_TRIP_TIME · 60 / 1000) + retardo máximo del
    `NetSim` del propio servidor + 3` (`ZoneServer.RTT_SLACK_TICKS`: los snapshots salen cada 2
    ticks y hay que procesarlos). Sin la cota, un cliente que atrasara 20 ticks su
    `ack_snapshot_tick` (sin lag real) se hacía pasar por alguien con 350 ms de RTT y obtenía los
    24 ticks de rebobinado. El `--net-sim` del servidor sí cuenta (es retardo real para él); el del
    cliente no: en producción equivaldría a fingir lag, así que para probar con lag simulado se usa
    el del servidor.
  - **`lead(T)`** es la antelación medida de esa entrada.
  - **`interp_delay_q`** no pasa de 96 (12 ticks × 8, el máximo del `InterpolationClock`): el
    servidor lo limita y suma un aviso a quien envíe más (`NetProtocol.MAX_INTERP_DELAY_Q`). La
    fórmula ya lo acota con `clamp(…, 4, 12)`.
  - **Fingir lag no da más rebobinado.**
  - **Por qué 24 ticks.** El rebobinado real es RTT + margen + retardo de interpolación, unos 20
    ticks con 200 ms de RTT. El tope de 24 ticks (400 ms) cubre hasta ~250 ms de RTT con el
    retardo normal.
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
| Botones | `buttons &= VALID_BUTTONS` (bits 0–8) |
| Lotes | Ticks consecutivos por formato; `count` de 1 a 8 |
| Limitador por peer (`RateLimiter`, en ticks) | No fiables: 2 por tick (120/s), ráfaga de 30. Fiables: 10/s, ráfaga de 20. Bytes: 16 KB/s, ráfaga de 4 KB. Lo que sobra se descarta y suma un aviso. Con crédito por parón (ver abajo) |
| Avisos | Paquete malformado, tipo inesperado para el estado de la sesión o exceso de ritmo. 50 avisos en 600 ticks → NOTICE de expulsión y desconexión |
| Enfriamiento tras una expulsión | 1800 ticks (30 s): su IP (las IPv6, por /64) o, desde loopback, su nombre normalizado reciben `REJECT TOO_MANY_CONNECTIONS` nada más conectar (o al llegar el HELLO, para el nombre) |
| Conexiones por IP | 4 como mucho (`--max-per-ip`), salvo loopback, para que funcionen los bots locales. Se comprueba al conectar, no solo con el HELLO; las IPv6 cuentan por /64 ([3](#3-conexión)) |
| HELLO a tiempo | 90 ticks desde que conecta; si no, se corta la conexión ([3](#3-conexión)) |
| Paquetes ajenos al protocolo | Antes del HELLO solo se admite autenticación; después, solo RAW. Lo demás se descarta sin error del motor y cada paquete suma un aviso ([2](#2-transporte-y-canales)) |
| Reino | Validado contra la zona. En la fase 2 lo declara el cliente (`DevAuthProvider`); desde la fase 5 sale del personaje o del billete, y el campo de HELLO se ignora |
| Rebobinado | Acotado por lo medido ([10](#10-historial-para-la-compensación-de-latencia)); el RTT que declara el cliente con sus acks se acota con el de ENet más el simulador del servidor + 3 ticks |
| Comandos de depuración | Solo con `--debug-commands` |

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
  veto por cuenta llega con las fases 5 y 6.

**Fases 5 y 6:**

- **`TicketAuthProvider`** con `HandoffTicket` de 47 B:
  - campos: versión, `ticket_id`, `character_id`, reino, zona y canal de destino, punto de
    llegada, emisión, caducidad (+10 s) y flags;
  - firma HMAC-SHA256 truncada a 16 B con el secreto del clúster;
  - verificación con `Crypto.constant_time_compare`, de un solo uso.
- **DTLS** (`host.dtls_server_setup(TLSOptions.server(…))`), obligatorio antes de las pruebas
  públicas.

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
| Bajada, 10 visibles | (51 + 10·20 + 40) B × 30/s | ~8,7 KB/s |
| Bajada, 30 visibles | (51 + 30·20 + 40) B × 30/s | ~20,7 KB/s |
| Bajada, ≥ 57 visibles (tope) | (1191 + 40) B × 30/s | ~37 KB/s (~300 kbit/s) |
| Salida del servidor, 64 jugadores y todos visibles | 64 × 37 KB/s | ~2,4 MB/s (~19 Mbit/s) |
| Entrada del servidor, 64 jugadores | 64 × 5,5 KB/s | ~350 KB/s |
| Eldrun, 300 jugadores sin más palancas | 300 × 37 KB/s | ~11 MB/s (~89 Mbit/s): demasiado |

**CPU (fase 2):** el p99 del tick debe quedar por debajo de 8 ms (la mitad de los 16,7 ms) con
64 bots agrupados. Se mide por sección: red, simulación (µs por personaje), historial,
snapshots. Ese dato es el primero del límite de jugadores por batalla que pide `vision.md`.

**Medidas de la fase 2** (`tools/load_test.gd --matrix`, TEC-11). Vado Gris con su Terrain3D, el servidor y
el enjambre `--bots` en la misma máquina de 4 núcleos (con poca carga ajena), GDScript sin optimizar. Los
falsos son `--fake-players`; los bots, clientes reales por ENet en loopback que reciben snapshots. Tick en
ms, p50 / p99 / máximo de los últimos 34 s de régimen:

| Escenario | Jugadores | Tick | `sim` p50 | `snapshot` p50 | Bajada por cliente |
|---|---|---|---|---|---|
| agrupado, 62 falsos y 2 bots | 64 | 4,8 / 8,7 / 14,1 | 3,9 | 0,5 | 35,3 KB/s |
| agrupado, 54 falsos y 10 bots | 64 | 5,7 / 9,6 / 23,4 | 3,9 | 1,2 | 35,2 KB/s |
| agrupado, 64 falsos y 2 bots | 66 | 4,8 / 8,0 / 12,1 | 4,0 | 0,5 | 35,3 KB/s |
| agrupado, 64 falsos y 10 bots | 74 | 6,5 / 12,1 / 45,2 | 4,5 | 1,3 | 35,3 KB/s |
| agrupado, 64 falsos y 50 bots | 114 | 15,3 / 26,9 / 49,6 | 6,4 | 6,9 | 34,3 KB/s |
| disperso, 64 falsos y 10 bots | 74 | 6,7 / 11,2 / 19,2 | 4,8 | 1,3 | 35,3 KB/s |
| altas y bajas (1 por segundo), 64 falsos y 10 bots | 74 | 6,4 / 11,0 / 41,6 | 4,5 | 1,3 | 35,3 KB/s |

- **Sustituidas.** Entre 0,09 % y 0,16 % de las entradas (criterio: menos de un 1 %), sin avisos ni
  expulsiones ni errores de física en ningún escenario.
- **Ancho de banda.** Con 57 o más jugadores visibles cada snapshot llena el paquete (1191 B) y cada cliente
  baja unos 35 KB/s (criterio: 37 KB/s como mucho) y sube unos 2,5 KB/s. Dispersos o agrupados da igual: sin
  interés por rejilla todo el mundo ve a todo el mundo.
- **`simulate()` por personaje: 44 a 50 µs** (medido alrededor de cada llamada), por encima de los 25 µs que
  marcan la palanca 6. La sección `sim` entera (cola de entradas, cerebro de los falsos, comprobación de
  movimiento) sale a unos 60 µs por personaje: con 64 jugadores son ~4 ms de los 16,7 ms del tick.
- **Construir un snapshot** de 57 registros cuesta de 250 a 525 µs (la codificación común de los registros
  del tick se reparte entre los snapshots de ese tick, así que sale más caro con pocos clientes). Con N
  clientes reales se construyen N/2 por tick: con 50, la sección `snapshot` llega a 6,9 ms de mediana y es lo
  que satura el tick (palancas 2 a 5).
- **Criterio de CPU no cumplido.** El p99 del tick con 64 jugadores es de 8,7 a 9,6 ms (criterio: menos de
  8 ms), con una mediana de 4,8 a 5,7 ms. Con 66 jugadores y 2 clientes queda justo en 8,0 ms. Con 74
  jugadores pasa de 11 ms y con 114 (50 reales) el tick de mediana ya ocupa 15,3 ms de los 16,7: el servidor
  no aguanta 50 clientes reales más 64 falsos. El primer cuello es `simulate()` en GDScript (palanca 6,
  ~46 µs por personaje frente a los 25 µs de umbral) y, con muchos clientes reales, el `SnapshotBuilder`.

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
- **Daño y muertes.** ENTITY_EVENT fiable.
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
  - captura como fórmula.
- **Guardias PNJ:** entidades por flujo (tipo NPC, mismo registro), simuladas en el paso 4 de
  [8.1](#81-orden-del-tick) e interpoladas en el cliente.
- **Avisos** («¡Vado Gris capturado!»): por NOTICE o ENTITY_EVENT, aplicados en el tick de
  dibujo.

### Fases 5 y 6: cuentas y traspasos

- **`character_id` y `ticket`** ya viajan en HELLO. `AuthProvider` se sustituye sin tocar
  `ZoneServer`.
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
    saltando y por la rampa.
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
    - `input_margin` en [0, 6] en régimen;
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
  que no coinciden con una subida de `substitutions`).
- **Segunda pasada con `--net-sim`** en los bots: convergencia final exacta (quietos los últimos
  60 ticks) y ninguna resincronización dura.
- **Detección de interferencias.** También detecta si los cuerpos ajenos del servidor o la
  colisión de Terrain3D alteran las consultas de Jolt.
- **Bot tramposo** (`--bot-cheat=version|future|dupes|garbage|flood`, un método por modo):
  rechazado o expulsado, sin que el bot honrado tenga diferencias sin explicar ni el servidor
  registre errores.

### Carga (manual)

`tools/load_test.gd`, fuera del ejecutor:

- Servidor con `--fake-players=N` (entradas inyectadas en la `InputQueue`, sin red) y procesos
  `--bots=50`.
- 64, 128 y 256 jugadores; escenarios disperso, agrupado (todos en 60 m) y de altas y bajas a 1
  por segundo; 120 s cada uno.
- Criterio de la fase 2, con 64 bots agrupados:
  - p99 del tick < 8 ms;
  - ≤ 37 KB/s por cliente;
  - menos de un 1 % de entradas sustituidas con 100 ms de RTT.

### Arquitectura (`test_architecture`, ampliado)

- `scripts/shared/` (también `net/`, de forma recursiva) mantiene sus reglas: nada de `Time.get_`,
  `Input`, UI ni clases del cliente.
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
const PROTOCOL_VERSION: int = 1
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
const VALID_BUTTONS: int = (1 << 9) - 1
const MAX_NAME_BYTES: int = 48
const MIN_NAME_CHARS: int = 3
const MAX_NAME_CHARS: int = 24
const MAX_TICKET_BYTES: int = 256
const MAX_ZONE_ID_BYTES: int = 32
const MSG_INPUT_BATCH: int = 0x01
const MSG_CLIENT_READY: int = 0x02
const MSG_CLIENT_LEAVE: int = 0x03
const MSG_DEBUG_COMMAND: int = 0x04
const MSG_SNAPSHOT: int = 0x10
const MSG_ENTITY_SPAWN: int = 0x20
const MSG_ENTITY_DESPAWN: int = 0x21
const MSG_OBJECT_STATE: int = 0x22   # reservado (fase 4)
const MSG_ENTITY_EVENT: int = 0x23   # reservado (fase 3)
const MSG_NOTICE: int = 0x30
const MSG_HANDOFF: int = 0x31        # reservado (fase 6)
const DEBUG_TELEPORT: int = 1
enum Realm { NONE = 0, VARDHEIM = 1, SOLMARCH = 2, ASKARRA = 3 }
enum EntityKind { NONE = 0, PLAYER = 1, NPC = 2, PROJECTILE = 3, STRUCTURE = 4 }
enum Result { OK = 0, VERSION = 1, SIM_HASH = 2, REALM = 3, FULL = 4, TICKET = 5, MALFORMED = 6,
		TOO_MANY_CONNECTIONS = 7, NAME = 8 }
enum DespawnReason { OUT_OF_INTEREST = 0, DISCONNECTED = 1, DEATH = 2, HANDOFF = 3 }
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
const SIZE: int = 20
const FLAG_GROUNDED: int = 1 << 0
const TELEPORT_SHIFT: int = 1
const TELEPORT_MASK: int = 0b11
var net_id: int = 0
var kind: int = NetProtocol.EntityKind.PLAYER
var position: Vector3 = Vector3.ZERO
var yaw: float = 0.0
var velocity: Vector3 = Vector3.ZERO
var flags: int = 0
var action: int = 0
func is_grounded() -> bool
func get_teleport_counter() -> int
func encode_into(bytes: PackedByteArray, offset: int) -> void
static func decode_from(bytes: PackedByteArray, offset: int, kind: int) -> EntityRecord
## Servidor: escribe el registro sin crear objetos.
static func encode_character(bytes: PackedByteArray, offset: int, net_id: int,
		character: PlayerCharacter, teleport_counter: int, action: int) -> void
static func from_state(net_id: int, kind: int, state: PlayerState, teleport_counter: int) -> EntityRecord
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
class Snapshot:
	var server_tick: int; var input_ack_tick: int; var input_margin: int
	var substitutions: int; var own_teleport: int
	var own_state: PlayerState              # null si no viene
	var records: Array[EntityRecord]
	## Lo usa SnapshotBuilder para escribir la cabecera sin crear el objeto. Devuelve el
	## offset donde empieza section_count.
	static func write_header(bytes: PackedByteArray, server_tick: int, input_ack_tick: int,
			input_margin: int, substitutions: int, own_teleport: int,
			own_state_bytes: PackedByteArray) -> int
class EntitySpawn:
	var net_id: int; var kind: int; var spawn_tick: int; var realm: int
	var is_yours: bool; var teleport_counter: int; var state: PlayerState; var display_name: String
class EntityDespawn:
	var net_id: int; var despawn_tick: int; var reason: int
class Notice:
	var code: int; var text: String

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
var max_players: int = 64
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
func add_fake_player(brain: BotBrain, realm: int) -> int
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
func start(config: ClientConfig, transport: NetTransport,
		controller: LocalPlayerController) -> Error
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
## Bots: snapshots con estado, coincidencias exactas, diferencias explicadas y sin explicar,
## resincronizaciones, ajustes de TickSync y estado final.
func write_report(path: String) -> Error

# client_prediction.gd
class_name ClientPrediction extends RefCounted
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
  u `OnlineMain.config` con `from_args()` y cambia a la escena correspondiente.
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
  ```
- **Pruebas:** `test_net_messages.gd`, `test_input_queue.gd`, `test_tick_sync.gd`,
  `test_interpolation_clock.gd`, `test_remote_interpolator.gd`, `test_state_history.gd`,
  `test_net_sim.gd`, `test_snapshot_builder.gd`, `test_rate_limiter.gd`, `test_server_auth.gd`,
  `test_prediction.gd`, `test_net_loopback.gd` y `test_net_processes.gd`.
- **Herramientas:** `tools/compare_state_logs.gd` y `tools/load_test.gd`, ambas scripts
  `SceneTree`.

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
| Snapshot de más de 1200 B con 64 jugadores visibles (A y C) | Presupuesto con acumulador de prioridad (57 registros por paquete); garantía de envío al menos cada ⌈N/57⌉ snapshots |
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
