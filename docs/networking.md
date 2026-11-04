# Eldmark · Phase 2: network design

Final design for step 2 of the [roadmap](vision.md#hoja-de-ruta): authoritative dedicated server,
several players in one zone, prediction and reconciliation for the local player, interpolation of
the others, and realm selection.

It starts from the "simple first" proposal, the one all three judges chose, and grafts onto it the
best ideas from "scale first" and "security first". It fixes every technical error the judges
found; the summary is in the [annex](#annex-corrections-to-the-proposals).

It builds on the phase 1 code:

- `PlayerInput`: 12 B quantized.
- `PlayerState`: 35 B (69 B with the phase 3 combat state, [combate.md 3.1](combate.md#31-combatstate-en-playerstate-entra-en-encode), and 111 B with the abilities of protocol 6, [abilities.md 3.1](abilities.md#31-combatstate-v5); the figures in this document are those of protocol 6 where marked "v6" and, otherwise, those of phase 3).
- `PlayerCharacter.simulate()`: deterministic, one physics tick per call.
- `LocalPlayerController`.

Zones, their scenes and the `--zone` and `--realm` options are defined by `scripts/shared/zones.gd`,
which belongs to another workstream. They are used here, not redefined (see [1.5](#15-zones-and-realms-contact-with-zonesgd)).

---

## 0. Key decisions

- **Transport.** `ENetMultiplayerPeer` and `SceneMultiplayer` are used, but only for three things:
  - connecting;
  - authenticating (`auth_callback`, `send_auth`, `complete_auth`);
  - moving binary packets (`send_bytes` and the `peer_packet` signal).

  No RPCs, `MultiplayerSynchronizer` or `MultiplayerSpawner` are used: predicting, interpolating and
  rewinding require an explicit tick on every piece of data and exact control over the bytes.
  Everything goes through `NetTransport`, a thin layer. If an overhead is ever measured, it makes
  it possible to switch to a direct `ENetConnection` without touching anything else.
- **Everything in integer ticks at 60 Hz.** Simulation, protocol, queues and network simulator are
  all measured in ticks.
  - Nothing in `scripts/shared/` reads the clock (enforced by `test_architecture.gd`), and tests
    are reproducible with a seed.
  - Only the rendering of remote players (physics interpolation fraction) and the server metrics
    use real time.
- **Fixed order in every tick.** `multiplayer_poll = false`. Each process calls `poll()` at the
  start of its physics tick and `flush()` at the end: receive → simulate → send.
- **The input for tick T is applied on server tick T**, one per player per tick.
  - The client simulates ahead by just enough for its inputs to arrive on time: the server
    measures it and the client corrects it.
  - Other players are drawn between 70 and 200 ms in the past.
- **Bit-for-bit determinism** with the same binary and the same OS:
  - yaw is rounded to f32;
  - all state imposed by the server goes through `encode`/`decode`;
  - reconciliation compares the exact `encode()`.

  Across different platforms reconciliation still works, because it re-simulates on any
  difference.
- **Snapshots at 30 Hz**, staggered per client, at most 1200 B, with a priority accumulator. If
  everything does not fit, whatever has gone longest without being sent goes in first.
- **No collision between characters.** The `PlayerCharacter` mask is already world-only, so each
  player's simulation does not depend on the others.
- **Cheap security from the start:** input window, button mask, per-peer limiter, per-IP
  connection cap and validated realm. Handoff tickets and DTLS are left for phases 5 and 6, with
  their slot already reserved in the protocol.

---

## 1. Process model and local development

### 1.1 One process per zone and channel

- **One process per zone and channel.** Each server process serves one zone and one channel (a
  copy of the zone) on one UDP port. Eldrun is a single process, with no channels (`world.md`).
- **The client only has its own zone loaded.** In phase 2 there is one zone per session. The
  phase 6 handoff repeats the same entry: HELLO with ticket → WELCOME → load → CLIENT_READY. That
  is why spawning waits for CLIENT_READY and not for authentication.
- **A single executable.** Client and server are the same project; the server starts with
  `--headless -- --server`.
- **Ports.** 24600 by default. If several zone processes run on one machine, each uses its own
  `--port`. The directory of zones and channels (which host and port serves each one) arrives in
  phase 8.

### 1.2 Startup modes

`boot.gd` reads the user arguments (those after `--`). Priority: `--server` >
`--bots` > `--connect`/`--local`/`--bot` > sandbox. `boot.gd` only decides between server and client
and **names no class from `scripts/client/`** (the main scene is also run by the dedicated server,
and each class reference would drag in the script and, in a chain, the UI, the settings and the
audio): for the client it instantiates `scenes/client/client_launcher.tscn` by path
(`ClientLauncher`), which applies the rest of the priority and switches to the mode's scene.
`test_architecture` checks this by starting a process with `--server` and looking at which client
scripts it has loaded (none).

| Arguments | Mode | Scene |
|---|---|---|
| none, `--demo`, `--shots=`, `--quit-after-demo` | Phase 1 offline sandbox, unchanged | `scenes/client/client_main.tscn` |
| `--server [--port=24600] [--zone=<id>] [--max-players=N] [--max-per-ip=4] [--idle-quit=<s>] [--fake-players=N [--fake-layout=cluster\|spread] [--fake-churn=<ticks>]] [--debug-commands] [--dev-lock [--dev-lock-path=<path>]] [--stop-file=<path>]` | Dedicated server (always with `--headless`) | `scenes/server/server_main.tscn` |
| `--connect=<host>[:<port>] [--realm=<realm>] [--name=<name>]` | Networked client | `scenes/client/online_main.tscn` |
| `--local [--realm=…] [--name=…]` | Client against a local server, which is launched if there is none | `scenes/client/online_main.tscn` |
| `--bot --connect=… [--bot-seed=N] [--bot-brain=wander\|combat] [--bot-cheat=<mode>] [--bot-scenario=progress]` | A client that predicts, with no camera or HUD, driven by `BotBrain` (wanders, or fights with the combat brain); with `--bot-scenario=progress` it stands still, equips the bow from its bag, gives itself 50 gold and a potion through DEBUG_COMMAND and leaves (progression.md §19.22); when dead, it asks to respawn as soon as it can | `scenes/client/online_main.tscn` |
| `--bots=N --connect=… [--bot-seed=N] [--bot-brain=combat] [--quit-at-server-tick=N]` | Swarm of N lightweight clients that do not simulate, for load tests (with `combat`, they fight; with `--quit-at-server-tick`, they leave when any of them sees that server tick) | `scenes/client/bot_swarm.tscn` |
| Common | `--net-sim=rtt=120,jitter=20,loss=5,dup=0,seed=1`, `--quit-after-ticks=N`, `--report=<path.json>`, `--state-log=<path.csv>` | |

- **`--zone` and `--realm`** are read with the `zones.gd` utilities, through `NetZones`.
- **`--max-players`** is the process capacity (fake players count). Without it, the zone's capacity
  (`NetZones.max_players`: 40 in Vado Gris, the per-battle player limit with the phase 4 kit in
  section 14) or, if the zone has none of its own, 64 (H5 revision, abilities.md §11.10).
- **Realm selection.** If a networked mode starts without `--realm`, `OnlineMain` shows
  `RealmSelect`: three buttons (Vardheim, Solmarch, Askarra), the address field and "Entrar"
  (enter), with the texts in Spanish.
- **Name.** Without `--name`, the client uses `NameRules.default_name(seed)`: "Jugador" plus four
  letters (e.g. `Jugadorabcd`), which is a valid name (SOC-01; the old `Jugador-NNNN` no longer is).

### 1.3 Headless server settings

- **`Engine.max_fps = 120`.** In headless mode, the main loop sleeps
  `low_processor_usage_mode_sleep_usec` (6900 µs by default) between iterations, and the time of
  each tick could vary by about 10 ms. Measured by the judges on 4.7.2:

  | Setting | Tick time dispersion | Iterations per second |
  |---|---|---|
  | Default | ~10 ms | — |
  | `max_fps = 120` | ~0.5 ms | ~120 |
  | `low_processor_usage_mode_sleep_usec = 1000` | 1.9 ms | ~10 000 |

  Headless bots use the same setting.
- **`get_tree().physics_interpolation = false`**, because the server does not draw.
- **`get_tree().multiplayer_poll = false`**, because `NetTransport.poll()` is called by hand.
- **No visual part.** When each `PlayerCharacter` is created on the server, its `Visual` node
  (meshes and `AnimationTree`) is freed. Contract with the art workstream: everything that is
  visual-only hangs from `Visual`.
- **Terrain3D:** full collision and `set_physics_process(false)`, as fixed by
  `tests/test_terrain3d_headless.gd`. The client also uses full collision, for determinism (see
  [risks](#19-open-risks)).
- **Physics.** `project.godot` explicitly sets `physics/common/physics_ticks_per_second=60` and
  keeps `physics_jitter_fix=0`. `Engine.time_scale` and the ticks per second are never changed at
  runtime: they change the delta that `move_and_slide()` uses and break determinism.
- **Logging:** with Godot's `--log-file <path>` option.
- **How the server is stopped (finding S5).** There is an orderly shutdown (shutdown NOTICE to
  clients, `ZoneServer.stop`, the `--report` report and removal of the `--dev-lock` lock) with
  `--quit-after-ticks`, `--idle-quit` and `--stop-file=<path>`: the server checks every second
  whether that file exists (for example, a systemd `ExecStop` that creates it with `touch`),
  performs the same shutdown and deletes it; one that already existed at startup is left over from
  an earlier stop and is deleted.
  **`SIGTERM` and `SIGINT` (Ctrl+C, `docker stop`, `kill`) do not shut down in an orderly way**:
  GDScript cannot catch them and Godot ends the process instantly (exit code 143 or 130), with no
  NOTICE, no final report and with the `--dev-lock` lock left undeleted. To limit the damage, with
  `--report` the report is rewritten every 10 s (`"closed": false`) as well as on shutdown
  (`"closed": true`), just as the state log is flushed every second; and whoever reads the lock
  (`LocalServerLauncher`) must not trust that its pid is still the server.

### 1.4 Local workflow

```powershell
$godot = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64_console.exe"

# Server and two clients, each in its own terminal
& $godot --headless --path . -- --server --debug-commands
& $godot --path . -- --connect=127.0.0.1 --realm=vardheim --name=Ana
& $godot --path . -- --connect=127.0.0.1 --realm=solmarch --name=Bruno --net-sim=rtt=120,jitter=20,loss=3

# All in one: launches (or reuses) a local server
& $godot --path . -- --local

# Bots
& $godot --headless --path . -- --bot --connect=127.0.0.1 --bot-seed=3
& $godot --headless --path . -- --bots=32 --connect=127.0.0.1

# Network tests
& $godot --headless --path . -s res://tests/run_tests.gd -- --filter=net
```

**`--local` (`LocalServerLauncher`):**

1. It reads `user://dev_server.json` (`{pid, port}`), which is written by a server launched with
   `--dev-lock` (or the file given by `--dev-lock-path=<path>`). If
   `LocalServerLauncher.is_process_alive(pid)`, it connects to that server.
2. Otherwise, it launches the server and connects with a short ENet timeout (1 s), retrying for
   10 s. In an export (`OS.has_feature("template")`) `--path` is omitted:
   ```
   OS.create_process(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"),
       "--log-file", <user://logs/dev_server.log globalized>, "--", "--server", "--port=24600",
       "--idle-quit=30", "--dev-lock"])
   ```
3. The server shuts itself down after 30 s without players and deletes the lock file.
   - Several windows launched with `--local` share the same server.
   - If the client crashes, the server is not left orphaned.
   - The client never kills the server.

A server is not detected by trying to `bind` on the port: on Windows, UDP address reuse makes it
unreliable.

**Orphaned lock.** The server only deletes its lock on an orderly shutdown (`--quit-after-ticks`,
`--idle-quit`, closing the window). With `SIGTERM` (systemd, `docker stop`) or `SIGINT` (Ctrl+C)
the process dies abruptly, without notifying clients, without `--report` and without deleting the
lock: GDScript cannot catch POSIX signals. If the system reuses that pid, the lock would point to a
live process that is not the server. That is why `get_running_port` requires, where possible
(Linux), that `/proc/<pid>/cmdline` contain `--server` and `--dev-lock`
(`LocalServerLauncher.is_dev_server_process`); on Windows this cannot be checked and any live
process with that pid will do.

`OS.is_process_running(pid)` only knows the processes launched by the process itself (on Windows it
looks at its table of child processes, `process_map`; on Linux and macOS, with the pid of another
window it also logs an engine error): a second `--local` window never launched the first one's
server and would get `false`. `LocalServerLauncher.is_process_alive` uses `/proc/<pid>/stat` (or
`kill -0`) on Linux and macOS and, on Windows, `OS.is_process_running` for its own children and
`tasklist /FI "PID eq <pid>" /FO CSV /NH` for the rest (the second column of the row is read,
because the "no matches" notice comes out in the system language). Each failed connection attempt
is a new session in `OnlineMain` (`NetClient.connect_timeout_ms` sets the short wait time).

**From the editor:** *Debug ▸ Customize Run Instances*.

- Instance 1: `--headless -- --server --debug-commands`.
- Instances 2 and 3: `-- --connect=127.0.0.1 --realm=vardheim` and `--realm=solmarch`.

### 1.5 Zones and realms: contact with `zones.gd`

**`NetZones`** (`scripts/shared/net/net_zones.gd`) is the only network file that calls
`zones.gd`. From that registry it only needs:

- the default zone id;
- the scene path of each zone;
- the realms admitted in each zone;
- reading `--zone` and `--realm`;
- the spawn points of a zone (`get_spawn_points`, `find_spawn_point`) and the group that marks
  them (`spawn_group`).

`test_architecture` guards this boundary: in `scripts/server/`, `scripts/client/` and
`scripts/shared/net/` only `net_zones.gd` names `Zones.`, with three exceptions: `server_main.gd`
(the zone list in the unknown-zone warning and the realms with a camp for the fake players, see
section 19), `client_main.gd` (the phase 1 offline sandbox) and, outside those folders, `boot.gd`
and `scripts/world/zone_root.gd`.

The realms admitted per zone and the network code <-> realm id mapping come from `RealmCatalog`
(`scripts/shared/war/realm_catalog.gd`, GUE-02); `NetZones` only translates. If a zone is not in
the catalog, `NetZones` admits all realms. If at implementation time it does not exist yet,
`NetZones` returns `test_world`. That change is made only in this file.

**Format on the wire:**

- **Realm:** the `NetProtocol.Realm` codes (0 none, 1 Vardheim, 2 Solmarch, 3 Askarra),
  independent of how `zones.gd` represents them. `NetZones` translates in both directions.
- **Zone:** travels as the text id from `zones.gd`, in ASCII and at most 32 B.

**Spawn points:**

1. If the zone scene exposes per-realm spawn points (through `zones.gd` or the art workstream),
   those are used.
2. Otherwise, the `Marker3D` nodes of the `spawn_points` group with the `realm` metadata (realm
   name, e.g. `"vardheim"`) are used.
3. If none belongs to the realm, any one is used. If there are none, the origin, with a warning.

**Coordinates:** zone scenes are centered on the origin. Position quantization covers ±5.24 km, so
the 5 × 5 km of Eldrun's terrain fit.

---

## 2. Transport and channels

**Peer creation:**

- **Server:** `ENetMultiplayerPeer.create_server(port, max_players + 4, NetProtocol.CUSTOM_CHANNELS)`.
  The 4 extra slots make it possible to answer "server full" with a REJECT, instead of ENet
  rejecting the connection without saying anything.
- **Client:** `create_client(host, port, NetProtocol.CUSTOM_CHANNELS)`.
  - `CUSTOM_CHANNELS = 3`. `ENetMultiplayerPeer` reserves its system channels, and transfer
    channel N goes to ENet channel `SYSCH_MAX + N − 1`.
  - Both sides must use the same value, which is tied to `PROTOCOL_VERSION`.

**`SceneMultiplayer`:** one per `NetTransport`.

- Configuration: `server_relay = false`, `allow_object_decoding = false`, `auth_callback` on both
  sides and `auth_timeout = 10.0` (v7; 5 s up to v6): it counts from the connection, on both sides,
  and leaves room for the ticket claim, which the zone cuts off at 7 s (platform.md §5.2 and §5.4).
- It is registered with `get_tree().set_multiplayer(mp, transport.get_path())`. That way several
  instances fit in a single process (tests and bot swarm).
- **Packet filter on the server (`GuardedEnetPeer`, finding S1).** `SceneMultiplayer` processes
  everything that arrives inside `poll()`, and only delivers to the application the RAW packets of
  admitted peers. An ENet client without `SceneMultiplayer` that sent anything else, before the
  HELLO (`[3, 1]`, RPC, SIMPLIFY_PATH...) or after it (RPC, SPAWN, SYS commands...), made the
  engine log one error per packet with its GDScript trace (2000 packets: 742 KB of log and a
  28–37 ms tick), those packets did not go through the limiters or add up warnings, and before the
  HELLO only the 5 s `auth_timeout` cut them off (the attacker reconnects). That is why the
  server's `NetTransport` hands `SceneMultiplayer` a `MultiplayerPeerExtension`
  (`scripts/shared/net/guarded_enet_peer.gd`) that wraps the `ENetMultiplayerPeer` and filters
  before the engine sees anything:
  - for a peer that is not admitted, only authentication messages (`SYS` + `AUTH`: byte 0 & 7 = 7
    and byte 1 = 0) of at most 1200 B, 3 with content (the HELLO) and one 2 B confirmation;
  - for an admitted peer (both sides have confirmed: the wrapper sees the other side's pass by,
    and its own), only RAW packets (byte 0 & 7 = 3);
  - everything else is discarded, with no engine error, and at the end of `poll()`
    `NetTransport.packets_discarded(peer_id, count)` is emitted. `ZoneServer` adds one warning per
    packet (reason "packet foreign to the protocol"; with 50 in 600 ticks, a kick NOTICE and a
    disconnect);
  - a peer the server is already disconnecting (`disconnect_after_flush`) is silenced: whatever it
    keeps sending is discarded without being counted or processed;
  - at most 4096 packets are processed per `poll()` (the rest stay in the ENet queue): a flood
    cannot lengthen the tick without limit. Measured: with 2000 packets in one tick, the longest
    tick goes from 28–37 ms to ~1 ms.
  - **Shortcut for the hot path.** The RAW packets of peers that `SceneMultiplayer` has already
    truly admitted (`NetTransport._mp_connected`) are delivered directly to the application,
    without going through the engine queue. Those of a peer that is admitted in that same `poll()`
    go through the queue, behind its confirmation, so as not to lose ordering. Measured with 64
    clients and 48,000 packets (five alternating repetitions): 9.4 µs per packet without a filter,
    9.9 µs with filter and shortcut (+6%, the noise level) and 11.3 µs with filter and no shortcut
    (+25%).
  - **Coupling.** The filter knows the internal format of `SceneMultiplayer` (RAW = 3,
    SYS = 7, AUTH = 0 and the 2 B confirmations). If an engine version changed it, the
    handshake would stop completing and `tests/test_net_sim.gd` would detect it right away. The
    client has no filter.

**Timeouts:**

- After connecting: `get_peer(id).set_timeout(32, 3000, 8000)`, so a disconnection is detected in
  3–8 s.
- While the client is connecting: `set_timeout(32, connect_timeout_ms, connect_timeout_ms)`, so that
  `--local` detects in ~1.5 s that there is no server. The minimum and the maximum are equal on
  purpose: ENet only checks the deadline when a CONNECT retransmission expires (at 0.5, 1.5, 3.5
  and 7.5 s), and with the maximum at double, `connection_failed` arrived at 3.5 s with 1000 ms and
  at 7.5 s with 3000 ms (finding S7). Now it arrives at 1.5 s and at 3.5 s.

**Compression:** no ENet compression at first, to save CPU. Later `COMPRESS_RANGE_CODER` will be
tried, measuring.

| Channel | Transfer mode | Direction | Content |
|---|---|---|---|
| system | internal to `SceneMultiplayer`, reliable | both | Authentication: HELLO, WELCOME, REJECT |
| 1 `CH_INPUT` | `TRANSFER_MODE_UNRELIABLE` (unsequenced) | C→S | INPUT_BATCH. Unsequenced on purpose: a late packet may carry the only copy of an input |
| 2 `CH_SNAPSHOT` | `TRANSFER_MODE_UNRELIABLE_ORDERED` (sequenced) | S→C | SNAPSHOT. ENet discards the late ones |
| 3 `CH_RELIABLE` | `TRANSFER_MODE_RELIABLE` | both | CLIENT_READY, CLIENT_LEAVE, DEBUG_COMMAND, RESPAWN_REQUEST, ENTITY_SPAWN, ENTITY_DESPAWN, ENTITY_EVENT and NOTICE; since phase 4, also UNSTUCK_REQUEST, OBJECT_STATE and SCOREBOARD, and since protocol 5, CHAT_SEND, CHAT_MESSAGE and the PARTY_* messages |

Rules:

- **Blocking.** A lost reliable message only blocks channel 3, never the snapshots or the inputs.
- **Order between channels.** Channels 2 and 3 are not ordered relative to each other. To make that
  not matter:
  - the client ignores records of a `net_id` it does not know yet;
  - each spawn carries its `spawn_tick`, and records from before that tick or after the
    `despawn_tick` are ignored;
  - a released `net_id` is not reused for 10 s.
- **Size.** No packet exceeds **1200 B**. If ENet fragments an unreliable packet, losing one
  fragment drops the whole packet. The snapshot guarantees this through its builder
  ([9.3](#93-snapshot-construction)) and the other messages are small by format. With DTLS (platform.md
  P9c) each datagram carries 29 B more, which ENet does not see (it applies its 1392 B MTU to the plaintext): the full snapshot
  comes out at 1240 B of UDP (1211 in plaintext) and the largest datagram ENet can assemble, at 1421 B, is below the
  1500 of Ethernet with the IPv4 or IPv6 headers. The cap does not change ([14](#14-bandwidth-and-cpu-budget)).
- **Nothing before `peer_connected`.** Nothing is sent with `send_bytes` to a peer until
  `peer_connected` has arrived for it on that side (on the client, peer 1). Sending right after
  `complete_auth()` gives `ERR_BUG` ("Condition !connected_peers.has(p_to)", verified by the
  judges), because the authentication-completed notice arrives in a later packet.
- **Network simulator.** `NetTransport` applies `NetSim` ([13](#13-debugging-tools))
  on output and on input. It only adds delay to the authentication messages. That way the RTT
  measured in ticks includes the simulated latency.

---

## 3. Connection

```
Client                                          Server (tick S)
  │ ENet connection                                │
  │ peer_authenticating(1)          peer_authenticating(id)
  │ HELLO (send_auth) ────────────────────────────▶│ ServerAuth.validate()
  │◀────────────────────────────── WELCOME (send_auth) + complete_auth(id)
  │ complete_auth(1)                               │
  │ peer_connected(1)                peer_connected(id)
  │ loads the zone (thread, "Cargando…")           │
  │ CLIENT_READY (channel 3) ─────────────────────▶│ spawn at the end of tick S
  │◀──────── own ENTITY_SPAWN (S, state after S) + SPAWN of everything relevant
  │ neutral advance S+1 … P0−1, real inputs from P0
```

1. **HELLO.** The client connects. On receiving `peer_authenticating(1)` it sends HELLO with
   `send_auth(1, …)` and records `hello_local_tick`.
2. **Validation.** The server's `auth_callback(id, bytes)` decodes HELLO and passes it to
   `ServerAuth`, which checks:
   - magic and version;
   - `sim_hash`;
   - that the realm is valid and admitted in the zone;
   - that the name fits in the HELLO (24 characters and 48 B), complies with `NameRules` (3 to 16
     letters, no spaces or digits, initial capital, no reserved names) and is not already used by a
     connected player in the zone (SOC-01; REJECT `NAME`);
   - that there is room (with `--max-realm-diff`, filler fake players do not take up slots meant
     for people: if the server is full only because of them, one gives up its slot when the HELLO
     is accepted; GUE-43, docs/fortress.md, section 7);
   - that there are no more than 4 connections from the same IP (except loopback). This cap is
     already applied on connecting (`peer_authenticating`), not only when the HELLO arrives (see
     the note below);
   - the `AuthProvider`. In phase 2 it is `DevAuthProvider`, which accepts the realm and the name
     the client declares.

   Depending on the result:
   - **OK:** `send_auth(id, WELCOME)` and `complete_auth(id)`. The peer moves to `LOADING`.
   - **Error:** `send_auth(id, REJECT)`, `flush()` and `ENetPacketPeer.peer_disconnect_later()`,
     which lets whatever is queued go out first. As a safety net, if the peer is still there after
     60 ticks, a forced `disconnect_peer(id)`.
3. **Response on the client.** The client's `auth_callback(1, bytes)`:
   - **REJECT:** shows the text and closes.
   - **WELCOME:**
     1. Computes `rtt_hello = local_tick − hello_local_tick`.
     2. Checks that `tick_rate == Engine.physics_ticks_per_second`; if not, it disconnects with an
        error.
     3. Calls `complete_auth(1)`.
     4. When `peer_connected(1)` arrives, loads the zone `WELCOME.zone_id` (with `NetZones` and
        `ResourceLoader.load_threaded_request`, behind the "Cargando…" (loading) screen).
     5. When loading finishes, sends CLIENT_READY and records `ready_local_tick`.

   Loading does not compete with `auth_timeout`: READY has its own 60 s limit.
4. **Player spawn.** READY arrives in the poll of tick S and stays pending. At the end of tick S,
   after simulating ([8.1](#81-tick-order)), the server creates the `PlayerCharacter` at a spawn
   point of its realm.
   - **Its state is "the state after tick S":** position and yaw of the point, velocity 0,
     `grounded` according to the point and `last_input_tick = S`, rounded with
     `PlayerState.decode(state.encode())`.
   - **Its `InputQueue`** starts with `last_consumed = S` and
     `last_applied = NetProtocol.neutral_input(S, yaw)`.
   - **Messages:**
     - own ENTITY_SPAWN ("yours" bit, `spawn_tick = S`);
     - the SPAWNs of everything relevant to the newcomer;
     - the newcomer's SPAWN to whoever considers them relevant.
5. **Prediction startup.** With its own SPAWN, the client computes:
   - `rtt_ticks = min(rtt_hello, local_tick − ready_local_tick)`;
   - `P0 = S + rtt_ticks + target_margin + 1`.

   And it starts prediction ([6.3](#63-startup)).

**With DTLS** ([platform.md](platform.md) §10.2, P9c). The handshake comes before everything
above: ENet sends the CONNECT when DTLS is already ready, on its first retransmission, so connecting
takes about 0.6 s with a single client (16 at once, 1.6 s) instead of 0.2–0.3 s;
`peer_authenticating`, the HELLO deadline and `auth_timeout` count from afterwards. The exit changes in
one detail: the client sends CLIENT_LEAVE and does **not** start the ENet disconnect; the server
starts it on receiving it (if it does not arrive within 60 ticks, the client closes the whole
connection). If the client started it, its DTLS close notice would arrive when the server has already
forgotten the session and the server engine would log an error for every exit.

**Idle connections (finding S2).** ENet slots (`max_players + 4`) are limited, and a connection that
never sent the HELLO held one until the 5 s `auth_timeout` (and reopens within one RTT): a single IP
with about 68 sockets left the zone inaccessible, and legitimate clients did not even receive a
REJECT because ENet silently drops their connection. Therefore:

- **Per-IP cap on connect.** `ZoneServer._on_peer_authenticating` counts the connections from the
  same IP (those still authenticating count too) and, if there are already 4 and it is not
  loopback, answers `REJECT TOO_MANY_CONNECTIONS` and disconnects, without waiting for the HELLO.
  IPv6 addresses are counted by /64 prefix (`ServerAuth.address_group`): whoever has IPv6 has a
  whole /64, and each of their addresses would count as another IP.
- **Own deadline for the HELLO.** A peer still in `AUTHENTICATING` after 90 ticks (1.5 s;
  `ZoneServer.HELLO_TIMEOUT_TICKS`, checked every 10 ticks) is cut off with
  `disconnect_after_flush` and counted in `rejects` as "no HELLO in time". The 5 s of
  `SceneMultiplayer` remain as a safety net.
- **Remaining limit.** With several different IPs (a botnet) it is still possible to fill the
  slots; that is solved outside the process (firewall, DTLS in phases 5 and 6).

**`sim_hash`.** It rejects clients whose simulation, or whose catalogs with ids that travel on the
wire, differ from the server's: they would mispredict all the time or misread those ids. It covers
the simulation and the catalogs whose ids travel (`CombatCatalog`, `ItemDatabase`; v7,
[progression.md](progression.md) §12).

- It is the SHA-256 (`HashingContext`) of `var_to_bytes()` of an array with:
  - `PROTOCOL_VERSION`;
  - `physics_ticks_per_second`;
  - the name of the physics engine;
  - the `@export` variables of `PlayerCharacter`, sorted by name;
  - the `floor_*` values set by `_ready()`;
  - the capsule's radius, height and position;
  - the fingerprint of the predicted part of the combat catalog (`CombatCatalog.prediction_hash()`);
  - v7: that of the item database (`ItemDatabase.wire_hash()`, [progression.md](progression.md) §2.2),
    because the item net ids travel to the owner. Appearance is not included: an unknown index
    already falls back to the default one.
- The first 4 bytes are taken as a u32.
- It is computed on an instance that is already in the tree, after `_ready()`.
- The text of the `SIM_HASH` REJECT (v7) is "Los datos del juego no coinciden con los del servidor:
  actualiza el cliente" (the game data does not match the server's: update the client) (up to v6,
  "La simulación del cliente no coincide con la del servidor", the client simulation does not match
  the server's).

---

## 4. Ticks and clock

### 4.1 Server tick and application rule

- **`server_tick`** starts at 0 and goes up by 1 when each simulated tick begins. The first is 1;
  0 means "none". The u32 does not wrap in practice (828 days). For that range to be real, ticks are
  always stored in 64-bit integers (`int`, `PackedInt64Array`): a `PackedInt32Array` or a signed
  `Vector2i` would overflow after 414 days (2^31 ticks) and make the rewind history, the warning
  window and the interpolation clock unusable (finding N5; `StateHistory.Track.ticks`,
  `ServerPeer._strike_ticks` and `InterpolationClock` already use 64 bits).
- **Rule:** the input with `tick = T` is applied exactly on server tick T. The snapshot of tick S
  carries the state after simulating S (`last_input_tick == S`).
- **Lead of each input.** The server measures it on receiving the *first accepted copy*:
  `lead = input.tick − (server_tick + 1)`.
  - 0 means just in time; negative, late (it is discarded but counted).
  - Redundant copies do not count: they would bias the measurement downward.
- **Feedback in the snapshot:**
  - `input_margin`: the minimum lead since the previous snapshot to that client, clamped to
    [−127, 127]; −128 if there is no data.
  - `substitutions`: cumulative counter of substituted inputs.

  Loss and delay are not mixed: an input that never arrives does not lower the margin.

### 4.2 Client lead (`TickSync`)

On every physics tick, the client decides how many prediction steps to take:

| Steps | When |
|---|---|
| 1 | Normal |
| 2 | To get ahead |
| 0 | To fall back |
| N | Hard forward resync |

- **Double step:** two `ClientPrediction.step()` calls in the same physics tick. This is valid
  because `move_and_slide()` uses the fixed delta while `Engine.is_in_physics_frame()`; it is
  demonstrated by `test_replay_matches_recording_across_physics_frames`.
- **Target margin:** `M = clamp(1 + ceil(2 · jitter_ticks), 1, 4)`. The jitter is the arrival jitter
  of the snapshots, measured by `InterpolationClock`; it is assumed to be similar upstream and
  downstream.
- **Window:** the last 15 margin samples (~0.5 s). Their minimum is used.
- **Wait after an adjustment.** Samples are discarded until a snapshot arrives with
  `input_ack_tick ≥ (first tick after the adjustment) + 2`, that is, when the server has already
  received inputs generated after the adjustment. That way exactly the feedback delay is waited
  out, whatever the RTT, and there is no overshoot.
- **Proportional correction.** The debt is `M − minimum` ticks.
  - To get ahead, it is paid with one double step per tick, on consecutive ticks.
  - To fall back, with a null step every other tick, so the character does not freeze for several
    ticks in a row.
- **Hard forward resync** if the minimum is ≤ −8: on that same tick `1 + (M − minimum)` steps are
  taken, 30 at most.
- **Never backwards.** If the client is too far ahead, it falls back little by little. Jumping back
  would regenerate inputs that were already sent and, since the server keeps the first copy, there
  would be guaranteed mispredictions.
- **Presses on ticks with no step.** On the 0-step ticks,
  `LocalPlayerController.accumulate_presses()` stores the `just_pressed` events, and the next
  `build_input()` adds them. That way no short tap is lost.

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

### 4.3 Interpolation clock (`InterpolationClock`)

It is independent of `TickSync`: one sets when to simulate and the other which instant to draw, so
they do not fight each other.

**Local measurement, in ticks.** With each snapshot, `offset = server_tick − local_tick` is computed.

- `local_tick` counts the client's physics ticks. Packets are read at the start of each tick, so
  the resolution is one tick.
- `max_offset` is the maximum over the last 120 local ticks (2 s): the sample that has been delayed
  least, a robust estimator of the minimum latency.
- **Step down.** The 120-tick maximum is only a good estimator if the server clock does not run
  backwards relative to the client's. If the server loses ticks (a stall of more than 8 ticks, or an
  overloaded server that keeps losing ticks) or latency rises in a sustained way, the offsets drop
  suddenly and stay down. With the 2 s maximum, the target `local + max_offset − delay` would run
  `k` ticks ahead of the data that exists: it would extrapolate 6 ticks, the remote would stand still
  and, when the old sample expired, it would jump backwards (finding N3; measured: 98 ticks frozen
  after a 20-tick stall, and 316 of 1201 with continuous loss). Therefore, if the maximum of the
  full window exceeds that of the last `RECENT_TICKS` (30) local ticks by more than
  `STEP_DOWN_TICKS` (4) ticks, the samples older than those 30 ticks are discarded
  (`_drop_samples_before_a_step_down`). A dip shorter than 30 ticks is not a step and still counts as
  jitter. Offsets that rise are adopted instantly, as before.
- `jitter` is the exponential average (α = 0.1) of `max_offset − offset`.
- `delay = clamp(2 · SNAPSHOT_INTERVAL_TICKS + 2 · jitter, 4, 12)` ticks, that is, from 67 to
  200 ms.

```gdscript
func advance(local_tick: int) -> float:          # once per physics tick
	var target: float = float(local_tick + _max_offset) - _delay
	if not _started or absf(target - _render_tick) > 10.0:
		_render_tick = target
		_started = true
	else:
		var advanced: float = _render_tick + 1.0         # advance first, correct afterwards
		_render_tick = advanced + clampf((target - advanced) * 0.1, -0.05, 0.05)
	return _render_tick
```

Correcting against the already advanced value avoids a one-tick bias: the first version compared the
target with the previous render tick and converged 1 tick ahead, with an effective delay of
3 ticks instead of 4 (fixed during implementation).

Remote players are drawn in `_process`, at the instant
`render_tick + Engine.get_physics_interpolation_fraction()`. That way each frame uses its exact
time, without the half-tick bias that applying them on the physics tick would have.

---

## 5. Message formats

### 5.1 Conventions

- Everything is little-endian and encoded with the `encode_*` / `decode_*` methods of `PackedByteArray`.
- Authentication messages start with the magic `0x4D444C45` (the bytes "ELDM").
- All other messages go through `send_bytes` and their byte 0 is the type.
- Strings are UTF-8 with their length in front and are never null-terminated.
- Ticks are absolute u32 values. There are no wrapping sequence numbers.

### 5.2 Catalog

| Type | Message | Direction | Channel | Size |
|---|---|---|---|---|
| — | HELLO | C→S | authentication | 23 B + name + ticket |
| — | WELCOME | S→C | authentication | 18 B + zone id + 3 B (v3) |
| — | REJECT | S→C | authentication | 6 B + text |
| `0x01` | INPUT_BATCH | C→S | 1 | 11 + 10·n B (21–91) |
| `0x02` | CLIENT_READY | C→S | 3 | 2 B |
| `0x03` | CLIENT_LEAVE | C→S | 3 | 2 B |
| `0x04` | DEBUG_COMMAND | C→S | 3 | 2 B + data |
| `0x05` | RESPAWN_REQUEST | C→S | 3 | 2 B |
| `0x06` | UNSTUCK_REQUEST (v3) | C→S | 3 | 1 B |
| `0x07` | LOADOUT_SELECT (v6) | C→S | 3 | 2 B |
| `0x10` | SNAPSHOT | S→C | 2 | ≤ 1200 B (14 B header, or 134 B with own state and extra block (v6; 92 B up to v5), + 2 B per section + 21 B per record) |
| `0x20` | ENTITY_SPAWN | S→C | 3 | 10 B + data (PROJECTILE, v6: 32 B in total; PLAYER, v7: 9 B more after the name) |
| `0x21` | ENTITY_DESPAWN | S→C | 3 | 8 B (reasons 4 and 5 for projectiles, v6) |
| `0x22` | OBJECT_STATE (v3) | S→C | 3 | 8 B + fields (1 to 32; 3, 4 or 6 B each: ≤ 200 B) |
| `0x23` | ENTITY_EVENT | S→C | 3 | 9 B + data (HIT 17 B, DEATH 13 B, RESPAWN 10 B, KILL 14 + 2·n B, WAR 11 B, TELEGRAPH 26 B; v6: STATUS 18 B, HEAL 15 B, LOADOUT 15 B, DOWNED 13 B, INTERACT 16 B; v7: LEVEL_UP 10 B) |
| `0x30` | NOTICE | S→C | 3 | 3 B + text |
| `0x31` | HANDOFF (reserved, phase 6) | S→C | 3 | — |
| `0x32` | SCOREBOARD (v3) | S→C | 3 | 4 B + 18 B per row (up to 66 rows per message: ≤ 1192 B) |
| `0x40` | CHAT_SEND (v5) | C→S | 3 | 5 B + recipient + text (≤ 821 B). v7: the commands handled by the server go through channel 8 (GM) (`gm …`, `ignorar`, `designorar`, `reportar`, without the slash; [platform.md](platform.md) §9 and §19.12), with no change to the bytes |
| `0x41` | CHAT_MESSAGE (v5) | S→C | 3 | 11 B + sender + recipient + text (≤ 875 B) |
| `0x48` | PARTY_INVITE (v5) | C→S | 3 | 2 B + name |
| `0x49` | PARTY_RESPONSE (v5) | C→S | 3 | 3 B + name |
| `0x4A` | PARTY_LEAVE (v5) | C→S | 3 | 1 B |
| `0x4B` | PARTY_KICK (v5) | C→S | 3 | 2 B + name |
| `0x4C` | PARTY_LEADER (v5) | C→S | 3 | 2 B + name |
| `0x4D` | PARTY_INVITATION (v5) | S→C | 3 | 7 B + name |
| `0x4E` | PARTY_ROSTER (v5) | S→C | 3 | 3 B + 3 B and name per member (≤ 258 B) |
| `0x4F` | PARTY_STATUS (v5) | S→C | 3 | 2 B + 17 B per member (≤ 87 B), at 2 Hz |
| `0x50` | INVENTORY_REQUEST (v7) | C→S | 3 | 18 B |
| `0x51` | INVENTORY_DELTA (v7) | S→C | 3 | 10 B + entries (≤ 1120 B), owner only |
| `0x52` | INVENTORY_FULL (v7) | S→C | 3 | 9 B + entries (≤ 1089 B), owner only, in pages |
| `0x53` | INVENTORY_SYNC_REQUEST (v7) | C→S | 3 | 1 B |
| `0x54` | WALLET_UPDATE (v7) | S→C | 3 | 19 B, owner only |
| `0x55` | PROGRESS_UPDATE (v7) | S→C | 3 | 25 B, owner only |

"v3" marks what protocol 3 adds (phase 4, [fortress.md](fortress.md#2-replicación-con-estado-object_state-gue-09)).
"v5" marks what protocol 5 adds (chat and parties, [social.md](social.md#12-implementación-fase-4)).
"v6" marks what protocol 6 adds or changes (abilities, effects, weapon swap, projectiles, knocked-down state
and templates, [abilities.md 5](abilities.md#5-protocolo-protocol_version--6)).
"v7" marks what protocol 7 adds or changes, the phase 5 upgrade ([platform.md](platform.md) §5.4 and
[progression.md](progression.md) §12): each document writes here what its code adds.
The size of an ENTITY_SPAWN depends on `kind` (see 5.5).

The formats of `0x50`–`0x55` (v7) are from [progression.md](progression.md) §4.6 and §12 and live in
`scripts/shared/net/progress_messages.gd` (`ProgressMessages`), separate from `net_messages.gd`. `0x56` to `0x5F`
are reserved (phase 6 bank, trade and mail). `NetClient` decodes them and exposes them through signals; `SwarmBot`
decodes and discards them; both count as malformed only what fails to decode. Since progression.md
P5b the server uses them (§19.12 there): it handles `0x50` and `0x53` in the "poll" (their rates, in 12) and applies the
requests at the end of the tick; it sends INVENTORY_FULL, one WALLET_UPDATE per currency and one PROGRESS_UPDATE after the
own SPAWN, one INVENTORY_DELTA per request and for each change of its own (`request_id` 0: CONSUME after simulating, CAMP_REFILL on
camp refill), INVENTORY_FULL on each sync, and WALLET_UPDATE and PROGRESS_UPDATE grouped, at most one every 10
ticks.

### 5.3 Authentication

**HELLO** (C→S)

| Offset | Type | Field | Notes |
|---|---|---|---|
| 0 | u32 | magic | `0x4D444C45` |
| 4 | u16 | protocol_version | `NetProtocol.PROTOCOL_VERSION` (= 7, v7: 2 combat, 3 its revision, 4 the fort, 5 chat and parties, 6 abilities, 7 phase 5) |
| 6 | u32 | sim_hash | see [3](#3-connection) |
| 10 | u8 | realm | 0 none (rejected), 1 Vardheim, 2 Solmarch, 3 Askarra. With a ticket (v7), it is ignored: the one from the claim rules |
| 11 | u8 | flags | bit0 = bot; the rest, 0 |
| 12 | u64 | character_id | 0 in phase 2; with a ticket (v7), the one from the ticket |
| 20 | u8 | name_len | ≤ 48 B |
| 21 | n B | name | UTF-8, 3–24 characters. With a ticket (v7), it is ignored and not compared with the connected players (no `REJECT NAME`) |
| 21+n | u16 | ticket_len | 0 without platform; ≤ 256 |
| 23+n | t B | ticket | v7: the 52 B ticket from [platform.md](platform.md) §5.1 (`HandoffTicket`), with the `--platform` zone; also the handoff one (phase 6) |

**WELCOME** (S→C): 18 B + zone id + 3 B with the per-realm count (v3).

| Offset | Type | Field | Notes |
|---|---|---|---|
| 0 | u32 | magic | |
| 4 | u8 | result | 0 = accepted (distinguishes WELCOME from REJECT) |
| 5 | u16 | protocol_version | |
| 7 | u32 | server_tick | server tick when answering (informational only) |
| 11 | u8 | tick_rate | 60 |
| 12 | u8 | snapshot_interval | 2 |
| 13 | u8 | max_input_batch | 8 |
| 14 | u8 | max_rewind_ticks | 24 |
| 15 | u8 | realm | accepted realm (since phase 5, the character's) |
| 16 | u8 | channel | zone channel; 0 in phase 2 |
| 17 | u8 | zone_len | ≤ 32 |
| 18 | z B | zone_id | ASCII id from `zones.gd` |
| 18+z | u8 × 3 | realm_counts | players of Vardheim, Solmarch and Askarra in the zone (saturating at 255), so that realm selection offers the shortest one ([fortress.md 7](fortress.md#7-bots-que-asedian-gue-15-gue-16-gue-42)). People (not fake players) of each realm at the time of the HELLO, not counting the one joining; the server fills them in since GUE-42 (F6a) |

The size is exactly `21 + z`: a version 2 WELCOME (without the count) no longer decodes.

**REJECT** (S→C)

| Offset | Type | Field | Notes |
|---|---|---|---|
| 0 | u32 | magic | |
| 4 | u8 | result | 1 VERSION, 2 SIM_HASH, 3 REALM, 4 FULL, 5 TICKET, 6 MALFORMED, 7 TOO_MANY_CONNECTIONS, 8 NAME, 9 IMBALANCE (v3: the chosen realm has too many players, `--max-realm-diff`; checked after the identity provider); v7: 10 BUSY (the character is still in the world), 11 UNAVAILABLE (the platform does not respond, the zone is fenced off or the character could not be loaded), 12 BANNED (account suspended, expelled or with deletion requested) |
| 5 | u8 | text_len | |
| 6 | n B | text | UTF-8, in Spanish (`NetProtocol.result_text`). v7: for BANNED, the `message` of the 403 `account_blocked`, which the platform composes (≤ 255 B); for a TICKET without a ticket, "Entra desde el menú con tu cuenta" (enter from the menu with your account) |

**With the platform (v7, [platform.md](platform.md) §5.2):** a HELLO with a valid ticket does not
get an immediate answer: the peer waits in `ServerPeer.State.VERIFYING` (it counts toward the quota) while the zone
claims the ticket; with the 200 the WELCOME arrives with the character's realm and name, and otherwise a REJECT
(TICKET, BUSY, BANNED, REALM, FULL or UNAVAILABLE). If 7 s pass since the connection without an answer, REJECT
UNAVAILABLE: always before the 10 s `auth_timeout` on both sides.

### 5.4 Client → server

**INPUT_BATCH** (`0x01`, channel 1). Sent once per physics tick, including on the
0-step ticks.

| Offset | Type | Field | Notes |
|---|---|---|---|
| 0 | u8 | type | `0x01` |
| 1 | u32 | ack_snapshot_tick | `server_tick` of the newest snapshot received (0 = none). Used to measure the RTT on the server and, in the future, as the delta base |
| 5 | u8 | interp_delay_q | current interpolation delay × 8, in ticks (at most 96 = 12 ticks: anything beyond is a warning). Bounds the phase 3 rewind |
| 6 | u32 | newest_tick | tick of the newest input |
| 10 | u8 | count | 1..8 |
| 11 | count × 10 B | records | from oldest to newest; record *i* belongs to tick `newest_tick − count + 1 + i` |

Each input record (10 B):

| Offset | Type | Field | Notes |
|---|---|---|---|
| +0 | s8 | move.x | = `PlayerInput.encode()[4]` |
| +1 | s8 | move.y | `[5]` |
| +2 | u16 | look_yaw | `[6..7]` |
| +4 | s16 | look_pitch | `[8..9]` |
| +6 | u16 | buttons | `[10..11]`; the server applies `& NetProtocol.VALID_BUTTONS`: bits 0–12 (v6: 9 swap weapon, 10 left shoulder for aiming, 11 and 12 the potions; 0–8 up to v5). Bits 13–14 are reserved and 15 is the substituted mark, which the client cannot set |
| +8 | u16 | view_offset_q | `(tick − seen render_tick) × 16`, clamped to 0..65535. Goes per input: a redundant copy of an attack keeps its own value |

- **Implicit ticks.** The ticks of the records are derived from `newest_tick` and are consecutive, so
  a batch with gaps cannot even be written.
- **Decoding.** The 12 B are rebuilt with the tick in front and `PlayerInput.decode()` is called,
  which already normalizes out-of-range values. `player_input.gd` does not change.
- **Which inputs are sent:**
  - the oldest is `max(input_ack_tick + 1, newest − R + 1, first_real_tick)`, never going past
    `newest`;
  - R = 4 normally, and R = 8 if `substitutions` has risen in the last 120 ticks or if ENet
    measures more than 2% loss.

**CLIENT_READY** (`0x02`, channel 3): `u8 type`, `u8 flags` (reserved, 0).

**CLIENT_LEAVE** (`0x03`, channel 3): `u8 type`, `u8 reason` (0 leave, 1 error). Allows immediate
removal without waiting for the timeout.

**DEBUG_COMMAND** (`0x04`, channel 3): `u8 type`, `u8 command`, data.

- `command` 1 = TELEPORT, with `f32 × 3` of position (14 B in total).
- **Fixed ids** (`NetProtocol.DEBUG_*`), which are not reused or reordered: 1 `teleport`,
  2 `heal`, 3 `kill`, 4 `stamina_inf`, 5 `set_weapon`, 6 `spawn_dummy` and, since version 4
  ([fortress.md 1.6](fortress.md#16-controlador-gue-08-gue-12)), 7 `unstuck`, 8 `fort_reset`, 9
  `fort_owner`, 10 `fort_kill_captain`, 11 `fort_capture_speed` and 12 `npc_debug` and, since version
  6 ([abilities.md 5.1](abilities.md#51-entradas-y-mensajes-cs)), 13 `cooldowns_off`, 14
  `apply_status`, 15 `down` and 16 `refill` and, since version 7 ([progression.md](progression.md) §10), the
  progression GM ones, always on the player themself: 40 `item_give`, 41 `currency_add`, 42 `level_set` and 43
  `xp_add`. The data for 2 to 6 is defined by the server
  ([combate.md 6](combate.md#6-protocolo-tec-13-protocol_version--2)); `decode` only requires at most 64 B of
  data. Those for 7 to 16 and 40 to 43 are validated by `decode`: 7, 8, 10, 15 and 16, no data; 9, `u8` with the
  realm (0 to 3); 11, `u8` with the factor (1 to 255); 12 and 13, `u8` (0 turns off, 1 turns on); 14, `u8
  status_id` (1 to 255) and `u16` ticks (0 = the duration from the data); v7: 40, `u16` item net id (from 1; whether
  it exists is checked by the server) and `u16` quantity (1 to 999); 41, `u8` currency (1 gold, 2 merits) and `s32` amount
  (≠ 0; the `note` is "debug"); 42, `u8` level (1 to 40); 43, `u32` XP (1 to 10,000,000). A fixed id whose handler
  does not exist yet on the server is accepted without a warning and without effect (7 to 12 until F3 and F4 arrived; 13
  and 14 until H3a, 15 and 16 until H3c; 40 to 43 until progression.md P5d, which brings them). With `--platform`, the role that
  each one requires is from progression.md §10 and platform.md §9.1: `admin` for 5, 13, 16 and 40 to 43 (they create or
  keep value for the character itself or skip its equipment), `gm` for the rest; 16 and 40 to 43 then create
  a GM operation with `note` "debug" and a critical save. `NetProtocol.DEBUG_COMMAND_IDS` is the
  name → id table with which the server's command registry checks that every network command
  has its id. `announce`, `kick` and `shutdown` have no id: they are console commands and, with the platform, of `/gm`
  with the `admin` role (v7).
- It is only accepted if the server started with `--debug-commands`; otherwise it counts a warning
  (*strike*, see [12](#12-phase-2-security)). v7: with `--platform`, in addition the role of the claim
  has to reach the command's `min_role` (`gm` by default; [platform.md](platform.md) §9.1); otherwise
  it also counts a warning and is not executed.

**RESPAWN_REQUEST** (`0x05`, channel 3): `u8 type`, `u8 point_index`. The dead player asks to
respawn at point `point_index` of the list of points of their realm (since phase 4, the static list
of all the points in the zone, `NetZones.get_all_respawn_points`; the server checks
that it is valid for their realm, [fortress.md 8.3](fortress.md#83-lo-que-han-dejado-f0-f1-y-f2-añadidos-al-contrato-y-decisiones))
([combate.md 5](combate.md#5-vida-eventos-muerte-y-reaparición-cmb-10-cmb-15-cmb-41-gue-03-gue-05)).
Out of time or with an invalid index, the server counts a warning. It is sent by the button on the death
screen, by `SwarmBot` and, since the phase 4 revision, by `--bot` (point 0, as soon as the server's estimated tick
reaches the `respawn_tick` of the extra block, and every second while still dead); the server's fake players
have no network and request it on death (`Combatant.requests_respawn_on_death`).

**UNSTUCK_REQUEST** (`0x06`, channel 3, v3): 1 B, only `u8 type`. The player requests `/atascado` (stuck)
([fortress.md 5](fortress.md#5-avisos-reaparición-salida-y-atascado)). Valid without `--debug-commands`. Before
entering the world, or with any extra byte, it counts a warning; the 10 s channeling, the
reuse and the teleport belong to F3.

**LOADOUT_SELECT** (`0x07`, channel 3, v6): `u8 type`, `u8 template_id`. The equipment template for the
next spawn ([abilities.md 4.6](abilities.md#46-equipo-plantillas-y-consumibles)). Valid from
the WELCOME, also before CLIENT_READY (LOADING and IN_WORLD), and goes through the reliable-message limiter. 0 = the
default one, without a warning; an id that does not exist or is not `selectable` counts a warning. `decode` only
requires the 2 B and the type. The server (H3c) stores it in `ServerPeer.pending_template_id` and applies it when it spawns the
player (the SPAWN already goes out with their weapons) and on every respawn, with a LOADOUT ENTITY_EVENT.

### 5.5 Server → client

**SNAPSHOT** (`0x10`, channel 2)

| Offset | Type | Field | Notes |
|---|---|---|---|
| 0 | u8 | type | `0x10` |
| 1 | u32 | server_tick | state after simulating this tick |
| 5 | u32 | input_ack_tick | `max(highest contiguous tick received, last consumed)`. Never gets stuck after a substituted input |
| 9 | s8 | input_margin | see [4.1](#41-server-tick-and-application-rule); −128 = no data |
| 10 | u16 | substitutions | cumulative total of substituted inputs for this player (mod 65536). Robust to lost snapshots |
| 12 | u8 | flags | bit0 = includes own state; bits 1–2 = own teleport counter (mod 4); bit3 = includes own extra block; the rest, 0 |
| 13 | 111 B | own_state | unquantized `PlayerState.encode()`, if bit0. Base for reconciliation (v6; 69 B up to v5) |
| 124 | 9 B | own_extra | own extra block, if bit3 (see below); at 82 up to v5 |
| 133 (or 13) | u8 | section_count | at 91 up to v5 |
| … | | sections | each one: `u8 kind`, `u8 count` and `count` records of the fixed size of that `kind` |

**Own extra block** (9 B). Carries what the server decides and does not go into `PlayerState`
because it does not change the simulation ([combate.md 1](combate.md#1-qué-se-predice-y-qué-decide-el-servidor)):

| Offset | Type | Field | Notes |
|---|---|---|---|
| +0 | u16 | health | current health |
| +2 | u16 | max_health | maximum health; `health ≤ max_health` |
| +4 | u8 | status | bit0 in combat, bit1 protected (respawn), bit2 dead, bit3 knocked down (v6; never with bit2). When knocked down, `health` is the knocked-down health and `max_health` the rules' knocked-down maximum (400) |
| +5 | u32 | respawn_tick | first tick at which respawn can be requested; 0 if alive |

- **Bit 3 is present if and only if bit 0 is.** `Snapshot.decode` returns `null` if one is missing without
  the other, or if `health > max_health`.
- **Capacity.** With own state and extra block, the header (with `section_count`) takes 134 B (v6;
  92 B up to v5). With one players section, ⌊(1200 − 134 − 2) / 21⌋ = **50 records** fit (52
  up to v5).
- **The player themself** never appears among the records: that is what their state is for.

**Entity record** (`kind` 1 PLAYER; 2 NPC reuses the format), 21 B:

| Offset | Type | Field | Notes |
|---|---|---|---|
| 0 | u16 | net_id | |
| 2 | u64 | position | 20 bits per axis: `q = round(v · 100) + 2^19`, saturated to [0, 2^20 − 1]. x in bits 0–19, y in 20–39, z in 40–59; bits 60–63 at 0. 1 cm resolution, ±5.24 km |
| 10 | u16 | yaw | [0, TAU) → 0..65535, same as `PlayerInput.look_yaw` |
| 12 | s16 × 3 | velocity | cm/s, saturated (±327 m/s) |
| 18 | u8 | flags | bit0 = grounded; bits 1–2 = teleport counter (mod 4); bit3 = weapon slot 2 active (v6); the rest, 0 |
| 19 | u8 | action | combat action and phase (attack, block, dodge...; 0 = none). The bits are defined by `ActionMachine.action_byte` |
| 20 | u8 | health_q | quantized health: 0 if dead and otherwise `clampi((health · 255 + max − 1) / max, 1, 255)` (rounded up, never 0 while alive). Entities without health report 255 |

- **Teleport.** The 2-bit counter replaces a flag that lasts a single snapshot, which would be
  lost along with that snapshot. If it changes between two samples, there is no interpolation between them.
- **Active weapon (v6).** The remote player knows which weapon it carries from the weapon pair (SPAWN or LOADOUT) and bit 3:
  the one in slot 2 if it is set. The `action` byte has no free bits. The lag compensation history
  does not take this bit: there bit 3 is `DEFENSE_BLOCKING` and the history byte is `(flags &
  0b111) | defense` ([abilities.md 3.6](abilities.md#36-consultas)).
- **Animation.** Sprint does not travel: the client deduces it from the velocity.

**ENTITY_SPAWN** (`0x20`, channel 3)

| Offset | Type | Field | Notes |
|---|---|---|---|
| 0 | u8 | type | `0x20` |
| 1 | u16 | net_id | |
| 3 | u8 | kind | 1 PLAYER, 2 NPC, 3 PROJECTILE, 4 STRUCTURE |
| 4 | u32 | spawn_tick | tick of the included state |
| 8 | u8 | realm | |
| 9 | u8 | flags | bit0 = it is your character; bits 1–2 = teleport counter; bit3 = game staff (v7: moderator or above, for the label, SOC-14; PLAYER only). For a projectile (v6), 0. It is not bit 3 of the snapshot record flags (active slot 2) |
| 10 | … | payload | according to `kind` (below) |

Payload according to `kind`:

- **PLAYER** (1): `PlayerState` (111 B since v6, 69 B up to v5; state after `spawn_tick`), `u8
  name_len` and the name (≤ 48 B) and, v7 ([progression.md](progression.md) §7.3), **9 B** after the name: `u8 level`
  (1 to 40; **0 if the receiver is not from their realm**, because the enemy's level does not cross over, or if they have no
  progress, like a fake player) and the 8 B of `CharacterAppearance` (8 B at 0 = no appearance). Size: 10 +
  111 + 1 + n + 9 B. That is why the server encodes a player's SPAWN per receiving realm
  (`NetEntity.encode_spawn(tick, for_owner, receiver_realm)`): the player's own carries the real level; the newcomer's,
  one variant per realm (three at most) for those already there; those of the others toward the newcomer and those from
  interest, with the observer's realm. `decode` only checks the size and that the level does not exceed 40; an
  invalid appearance is replaced by the client with the race's default one.
- **NPC** (2): the same as a player without the level or the appearance (v7: unchanged) and, after the name, `u16
  npc_def_id` (v3): the id from the NPC catalog (`NpcCatalog`, alphabetical ids 1..n; 0 = no definition) so that
  the client picks the model, tabard and boss bar. Size: 10 + 111 + 1 + n + 2 B (v6).
- **STRUCTURE** (4, v3): `u8 def_len` (1–32), the definition id in printable ASCII (for
  example `vado_gris_fort`), `u8 field_count` (1–32) and the full fields, each one `u8 field_id,
  u8 value_type` and the value, as in OBJECT_STATE (without repeating type, net_id or tick). It carries no
  player state or name. The header's `realm` is 0: the `owner` field rules. For a
  fortress that is 98 B with the Vado Gris id (10 + 1 + 14 + 1 + 72).
- **PROJECTILE** (3, v6; [abilities.md 5.3](abilities.md#53-projectile-kind-3)): 22 B after the header,
  **32 B** in total. `net_id` is the projectile (from the `NetEntityRegistry` id space, without being an
  entity), `realm` the shooter's, `spawn_tick` the tick of the shot and the header flags are 0
  (never `is_yours`: your own arrow is the one whose `owner` equals your `net_id`). The client computes the flight
  with `Ballistics.position`; the snapshot carries no projectile records. **Recipients** (H3b): the
  SPAWN goes to the shooter's owner and to whoever has them as relevant on the tick of the shot; its DESPAWN (reason 4
  or 5), exactly to those who received the SPAWN, even if they no longer have the shooter as relevant. Whoever starts
  seeing the shooter later does not receive the arrows already in the air (they live 2 s at most).

| Offset | Type | Field | Notes |
|---|---|---|---|
| 10 | u16 | owner | `net_id` of the shooter |
| 12 | u16 | projectile_def_id | `ProjectileDefinition` from the combat catalog |
| 14 | u16 | source | source of the attack or ability (`CombatSource`, see ENTITY_EVENT) |
| 16 | u8 | volley_index | 0..n−1 within the shot (the fan fires three) |
| 17 | u8 | proj_flags | bit0 harmless (flies and collides with the world, does not test characters); the rest, 0 |
| 18 | u64 | position | `p0`, 20 bits per axis like the record (1 cm) |
| 26 | s16 × 3 | velocity | `v0` in cm/s (±327.67 m/s) |

`decode` returns `null` if the size does not match the lengths, a text is not valid, the `kind`
has no format or, for a structure, the definition id is not printable ASCII of 1 to 32 B, the
counter is not between 1 and 32, a field carries an unknown `value_type` or a `field_id` is repeated; for
a projectile (v6), if it does not take exactly 32 B, carries any flag in the header or a bit of
`proj_flags` that does not exist.

The `PlayerState` of the **own** SPAWN (bit0 = 1) goes in full. That of a **foreign** entity is public: it carries
position, velocity, turn and ground, and of the combat only the action in progress (with its attack and its start tick)
and the weapon; the rest of the `CombatState` (exact stamina, exhaustion, parry cooldown, buffer,
combo step, controls, push), the buttons of the last tick and the jump counters revert to their
initial values. The opposite would dump to anyone entering the zone the private state of each
enemy (combate.md 6). Since v6 the weapon in the other slot (`alt_weapon_id`) and the active
slot (bit 0 of `combat_flags2`) are also public: weapons are visible. Cooldowns, charges, the cooldown of
consumables, the movement-effect slots and the pressed-button bits revert to their initial
values ([abilities.md 5.2](abilities.md#52-estado-snapshot-y-registro)).

**ENTITY_DESPAWN** (`0x21`, channel 3)

| Offset | Type | Field | Notes |
|---|---|---|---|
| 0 | u8 | type | `0x21` |
| 1 | u16 | net_id | |
| 3 | u32 | despawn_tick | the client removes it when its `render_tick` reaches this |
| 7 | u8 | reason | 0 out of interest, 1 disconnection, 2 death, 3 handoff; v6, for projectiles: 4 impact (at `despawn_tick`, on the segment `[pos(n), pos(n + 1)]` with `n = despawn_tick − spawn_tick`) and 5 expired or withdrawn |

**ENTITY_EVENT** (`0x23`, channel 3). Combat facts that do not fit in a stream record
([combate.md 6](combate.md#6-protocolo-tec-13-protocol_version--2)). Reliable and ordered with the
other messages of channel 3.

| Offset | Type | Field | Notes |
|---|---|---|---|
| 0 | u8 | type | `0x23` |
| 1 | u16 | net_id | the entity it attaches to: the victim in HIT, DEATH and KILL; the one respawning in RESPAWN; the fortress in WAR; the NPC in TELEGRAPH; v6: the affected one in STATUS, the healed one in HEAL, the player in LOADOUT and the knocked-down one in DOWNED and INTERACT; v7: the one leveling up in LEVEL_UP |
| 3 | u32 | tick | server tick at which it happened |
| 7 | u8 | event | 1 HIT, 2 DEATH, 3 KILL, 4 RESPAWN, 5 WAR, 6 TELEGRAPH; v6: 7 STATUS, 8 HEAL, 9 LOADOUT, 10 DOWNED, 11 INTERACT; v7: 16 LEVEL_UP (12 to 15, free) |
| 8 | u8 | len | data bytes that follow |
| 9 | len B | data | according to `event` |

| `event` | Data | `len` | Total |
|---|---|---|---|
| 1 HIT | `u16 attacker`, `u16 amount`, `u8 damage_type`, `u8 flags`, `u16 attack_id` | 8 | 17 B |
| 2 DEATH | `u16 killer` (0 = the environment), `u16 attack_id` | 4 | 13 B |
| 3 KILL | `u16 killer`, `u16 attack_id`, `u8 n`, `n × u16` assistants | 5 + 2·n | 14 + 2·n B |
| 4 RESPAWN | `u8 point` | 1 | 10 B |
| 5 WAR (v3) | `u8 war_event` (1–7, `WarEvents`), `u8 realm` (0–3) | 2 | 11 B |
| 6 TELEGRAPH (v3) | `u16 attack_id`, `u8 shape` (0 circle, 1 sector), `u64 position`, `u16 yaw`, `u16 radius_cm`, `u16 impact_in_ticks` | 17 | 26 B |
| 7 STATUS (v6) | `u16 source_entity` (0 = no author), `u8 op` (1 applied or renewed, 2 removed), `u8 status_id`, `u8 stacks`, `u32 until_tick` (exclusive) | 9 | 18 B |
| 8 HEAL (v6) | `u16 healer` (0 = self), `u16 amount`, `u16 source` | 6 | 15 B |
| 9 LOADOUT (v6) | `u8 template_id`, `u16 weapon_1`, `u16 weapon_2` (in slot order; 0 = none), `u8 charges` (bits 0–3 potion 1, 4–7 potion 2; 0 for anyone who is not the owner) | 6 | 15 B |
| 10 DOWNED (v6) | `u16 attacker`, `u16 source` | 4 | 13 B |
| 11 INTERACT (v6) | `u16 actor`, `u8 op` (1 revive, 2 revive cancelled, 3 revived, 4 finish off, 5 finish off cancelled), `u32 end_tick` | 7 | 16 B |
| 16 LEVEL_UP (v7) | `u8 level` (1 to 40) | 1 | 10 B |

- **WAR**: the `net_id` is the fortress and the `realm` the realm that accompanies the notice
  (`FortressState.event_realm`). It goes to the whole zone and is applied on the render tick
  ([fortress.md 5](fortress.md#5-avisos-reaparición-salida-y-atascado)).
- **TELEGRAPH**: the `net_id` is the NPC preparing the attack. `position` is packed as in the
  entity record (20 bits per axis, 1 cm), `yaw` as in the record (0..65535 over [0, TAU)),
  `radius_cm` is the reach and `impact_in_ticks` the ticks remaining until the blow. It is applied on
  arrival: it is a warning. The blow lands at the server's `tick + impact_in_ticks` and is dodged by the input
  of that tick, so the client counts the deadline with its predicted tick, not with the arrival time
  (the marker, the bots; [fortress.md 5](fortress.md#5-avisos-reaparición-salida-y-atascado)).

- **HIT flags:** bit0 critical, bit1 blocked, bit2 parried, bit3 guard break, bit4
  lethal; v6: bit5 interrupted (drinking, a marked cast, reviving or finishing off) and bit6 knocks down.
- **Source (v6).** The `u16 attack_id` of HIT, DEATH, KILL and TELEGRAPH, and the `u16 source` of HEAL, DOWNED
  and of a projectile's SPAWN, are a source (`CombatSource`): bits 14–15 the class and 0–13 the id. 0 =
  none (the environment); `0x0000 | id` attack (those from phase 3 keep their number); `0x4000 | id`
  ability; `0x8000 | id` effect (a pulse); `0xC000 | 1` finisher and `0xC000 | 2` bleed-out. The ids
  are requested from the catalog by name: none is fixed.
- **STATUS, HEAL, LOADOUT, DOWNED and INTERACT (v6)**: recipients, timing and what they explain in
  prediction, in [abilities.md 5.4](abilities.md#54-entity_event-y-fuentes). DOWNED goes to the whole zone
  (kill feed); LOADOUT, to the owner and, if the weapons change, to whoever has it as relevant with
  `charges` = 0.
- **LEVEL_UP (v7)**: to the owner and to those of **their realm** who have it as relevant, for the visual effect; it does not
  reach the enemy ([progression.md](progression.md) §6.3). It imposes no state: it explains no corrections. The client gives the
  own one on arrival and an ally's on its render tick, like the other events.
- **Validation.** `decode` returns `null` if the type is not `0x23`, the `event` is unknown,
  `len` does not match the event or the real message size, `n` does not match `len` or
  `n > 16` (assistants do at least 10% of the damage, so there are never more than 10), a WAR carries
  a notice outside 1–7 or a realm greater than 3, a TELEGRAPH carries a shape that is neither 0 nor 1, a STATUS
  or an INTERACT carries an `op` out of range, or an applied STATUS carries 0 stacks (v6), or a LEVEL_UP carries
  a level outside 1 to 40 (v7).
  `encode` trims a KILL to 16 assistants.
- **Recipients and timing:** see [combate.md 6](combate.md#6-protocolo-tec-13-protocol_version--2).

**NOTICE** (`0x30`, channel 3): `u8 type`, `u8 code`, `u8 len` and the UTF-8 text (≤ 200 B).

- Codes: 0 informational, 1 kick, 2 server shutting down.
- With code 1, the server disconnects the peer after the `flush()`.

**OBJECT_STATE** (`0x22`, channel 3, v3). The replicated state of an object that is neither a player nor an
NPC, today a fortress ([fortress.md 2](fortress.md#2-replicación-con-estado-object_state-gue-09)).

| Offset | Type | Field | Notes |
|---|---|---|---|
| 0 | u8 | type | `0x22` |
| 1 | u16 | net_id | the structure |
| 3 | u32 | tick | server tick after which the state is valid |
| 7 | u8 | field_count | 1–32 |
| 8 | … | fields | each one: `u8 field_id`, `u8 value_type` (1 u8, 2 u16, 3 u32, 4 s32) and the value (1, 2, 4 or 4 B) |

- A message carries only the fields that have changed (at most one per fortress every 6 ticks); the
  full state travels in the structure's ENTITY_SPAWN. The field ids of a fortress are
  those of `FortressFields`.
- **Validation.** `decode` returns `null` if the size does not match, a `value_type` is unknown,
  `field_count` is not between 1 and 32 or a `field_id` is repeated. An unknown `field_id` with a valid
  type is kept and whoever interprets the object skips it (forward compatibility). A known
  field with a different value type than its own is not rejected by `decode` (it does not know which object it is for):
  `ObjectState.apply_to_fortress` skips it and `is_valid_for_fortress` flags it.

**SCOREBOARD** (`0x32`, channel 3, v3). The zone scoreboard, every 2 s to all players
([fortress.md 6](fortress.md#6-interfaz-ui-18-ui-21-ui-41-ui-42)).

| Offset | Type | Field | Notes |
|---|---|---|---|
| 0 | u8 | type | `0x32` |
| 1 | u8 | page_index | from 0 |
| 2 | u8 | page_count | total pages, 1–255 |
| 3 | u8 | row_count | 0–66 |
| 4 | row_count × 18 B | rows | `u16 net_id`, `u16 kills`, `u16 deaths`, `u16 assists`, `u32 damage to the gate`, `u16 seconds in the circle`, `u32 merits` |

- A page does not exceed **66 rows** (4 + 66 · 18 = 1192 B ≤ `MAX_PACKET_BYTES`). With more players the
  scoreboard is split into several messages (`Scoreboard.split`), which the client joins by `page_index`
  of `page_count`; with no players a single empty page is sent.
- Counters saturate at their maximum when encoding. `decode` returns `null` if the size is not
  exactly `4 + 18 · row_count`, `row_count > 66`, `page_count` is 0 or `page_index ≥ page_count`.

### 5.6 Reserved

- **HANDOFF** (`0x31`, phase 6): zone, channel, host, port and ticket.

Taking one of these types raises `PROTOCOL_VERSION`. ENTITY_EVENT (`0x23`) stopped being
reserved in phase 3 and OBJECT_STATE (`0x22`) in phase 4 (protocol 3): their formats are in
[5.5](#55-server--client).

### 5.7 Validation

- **Decoding.** Each `decode` returns `null` if the size, the type, the counters or the
  lengths do not match. It never logs engine errors (the test runner counts them
  as a failure).
- **Input batches.** `count` must be between 1 and 8, the size must be exactly
  `11 + 10 · count` and `newest_tick ≥ count`.
- **Warnings.** Malformed packets, types unexpected for the session state and
  rate excesses count warnings ([12](#12-phase-2-security)). So do packets that are
  not part of the `SceneMultiplayer` protocol (see [2](#2-transport-and-channels)): they no longer reach
  the point of logging engine errors.

---

## 6. Prediction and reconciliation

### 6.1 Requirements on the shared code

- **`PlayerCharacter.yaw` is rounded to f32** in its setter (`PlayerState.to_f32`).
  - It was the only state field in f64, and `PlayerState` encodes it in f32: the result of
    `atan2` does not survive the round trip.
  - Without the rounding, the server (f64) and the client (decoded f32) differ in the last bit
    while turning, and no exact comparison would pass.
- **`PlayerCharacter.events_enabled`:** during replays and neutral advance, `jumped` and `landed`
  are not emitted, to avoid duplicating sounds or animations.
- **`PlayerState.equals_exact(other)`** compares `encode()`.
- **The server rounds through `encode`/`decode`** every base state it imposes: spawn and
  teleport.

### 6.2 Client tick

A single `NetClient._physics_process` orchestrates everything (`process_physics_priority = -100`) and
`LocalPlayerController.auto_step = false`.

```gdscript
func _physics_process(_delta: float) -> void:
	_local_tick += 1
	_transport.poll(_local_tick)
	# _on_packet: reliable messages are applied immediately (SPAWN, DESPAWN, NOTICE). Each SNAPSHOT
	# goes to _interp_clock.on_snapshot() and to _remote_world; the newest is kept in _latest.
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

- **Late snapshots.** Those that arrive out of order (possible with `NetSim`) only feed
  the interpolators, never the reconciliation.
- **Drawing the remote players.** `RemoteWorld._process` draws the remote players and stores
  `last_drawn_render_tick`. The inputs of a physics tick are built before the
  `_process` of that frame, so the stored value is what the player was seeing.

### 6.3 Startup

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

- **While no real input has arrived**, the server substitutes each tick with
  `last_applied` (the neutral input from the spawn) with `move = 0`: it is the same input. That is why the
  two states match bit for bit from the first tick.
- **Neutral input:** movement 0, buttons 0, `look_yaw` equal to the yaw of the quantized state and
  pitch 0. With `move = 0` the view does not affect the simulation.
- **If the first real input arrives late**, the server substitutes that tick and
  reconciliation corrects it.

### 6.4 Prediction step and send

```gdscript
func step() -> PlayerInput:
	var t: int = _predicted_tick + 1
	var input: PlayerInput = _controller.build_input(t)   # quantized, with accumulated presses
	_character.simulate(input, _dt)
	_store(t, input, _character.get_state())
	_predicted_tick = t
	return input
```

- **Rings.** `_store(t, input, state)` writes into two rings of 256 slots indexed by
  `t % 256`, with the tick as a label. They replace the `pop_front()` (O(n)) of the current history.
- **Send.** `_send_input_batch()` builds the INPUT_BATCH of [5.4](#54-client--server) with the
  inputs from `_prediction.get_input(t)` and the `view_offset_q` values from `_view_offsets`. It sends it through
  `CH_INPUT` once per physics tick.

### 6.5 Reconciliation

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

- **The comparison is exact.** It also detects differences in `prev_buttons`,
  `last_input_tick` and the jump counters, which `is_close_to` did not look at.
- **Cost.** With 300 ms of RTT about 20 ticks are re-simulated, and only when there is some
  difference.
- **Across platforms** (server on Linux, client on Windows), a difference in the last bit
  of `sin`/`cos` causes an almost free replay and an offset below one millimeter. The
  "corrections" metric only counts those over 1 mm.
- **`_input_or_substitute(t)`** returns the stored input if its label matches and, otherwise, the
  server's substitution rule ([8.2](#82-input-queue-inputqueue)). It only happens after a
  `hard_reset`.
- **`hard_reset(tick, state)`** does `set_state(state)` and stores the state.
  - If `tick ≥ _predicted_tick`, it sets `_predicted_tick = tick`: `TickSync` recovers the lead.
  - Otherwise, it re-simulates up to `_predicted_tick` as above.
  - It always ends with `smoother.clear()` and `reset_physics_interpolation()`.

### 6.6 Correction smoothing (`CorrectionSmoother`)

- **The body is corrected at once**, because the server's collision rules.
- **The error is applied as an offset** to the local `Visual` and `CameraTarget` nodes, never to
  `Collision`. It is in local space, recomputed every tick because the yaw changes:
  `target.position = base_position + character.basis.inverse() * offset`.
  - `base_position` is the original local position of each node; `CameraTarget` is at
    (0, 1.6, 0).
- **It decays every physics tick** with a half-life of 6 ticks (100 ms) and is zeroed below
  1 mm.
- **Why the image does not jump.** It is written inside the physics tick, so physics interpolation
  interpolates it like everything else. On the correction tick, the body jumps from the old point to
  the new one and the offset goes from 0 to `old − new`: the visible position does not jump, and
  then converges without jerks.
  - The camera follows `CameraTarget` with `get_global_transform_interpolated()`, so it does not
    jump either.
  - `reset_physics_interpolation()` is not needed, and it would indeed cause a jerk.
- **Teleport.** With an error over 3 m or a change in the teleport counter: no
  smoothing and with `reset_physics_interpolation()`.
- **Yaw is not smoothed:** its corrections are tiny.

### 6.7 Why it converges

- **Same computation on both sides.** `simulate()` is deterministic and the client applies the
  same quantized inputs the server receives, starting from the same exact state.
- **Where differences come from.** Discrepancies only arise when:
  - the server uses a substitute input (lost or late);
  - since phase 3, there are effects that only the server decides (hits, pushes).

  Those effects will travel in an extended `PlayerState`, and `equals_exact` covers them unchanged.
- **Same physical world.** There is no collision between characters. The bodies of the others exist in
  the server's physics space and not in the client's, but they are not in the mask.
  `test_net_processes` checks that they do not alter Jolt queries either.

---

## 7. Interpolation of remote players

- **`RemoteWorld`** receives SPAWN, DESPAWN and the records of each snapshot, and creates one
  `RemotePlayerView` per entity.
- **`RemotePlayerView`** drives an instance of `player_character.tscn` that never calls
  `simulate()`:
  - `collision_layer = 0`, `collision_mask = 0`;
  - `set_physics_process(false)` and `physics_interpolation_mode = PHYSICS_INTERPOLATION_MODE_OFF`;
  - in `_process` it writes `global_position`, `yaw`, `velocity` and `grounded`;
  - it emits the body's `jumped` and `landed` when it detects those edges in the samples.

  That way the animation layer added by the art workstream animates local and remote players the same,
  reading the same fields and signals. For Eldrun it can be swapped for a visual-only scene, lighter,
  with the same interface.
- **`RemoteInterpolator`:** ring of 32 samples `(tick, EntityRecord)` ordered by tick.
  It discards duplicates and samples older than the window.
- **`sample(t)`**, with `t = render_tick + fraction`:
  - **Between two samples** with the same teleport counter: `lerp` of position and
    velocity, `lerp_angle` of the yaw (correct when crossing ±PI) and `grounded` from the nearest
    sample.
  - **If the counter changes between the two**, it stays on the first until t reaches the
    second (no interpolation).
  - **Ahead of the last sample:** it extrapolates horizontally with its velocity for up to
    **6 ticks** (100 ms); after that it stands still. Extrapolating further misleads when aiming.
- **Data returning after extrapolating.**
  - If the jump between what was drawn and the new data is between 5 cm and 1.5 m, it becomes an
    offset that decays in `_process` (100 ms half-life, real time).
  - If it exceeds 1.5 m, it jumps directly.
- **Appearance and disappearance, according to render time:**
  - the remote player is shown when `t ≥ spawn_tick`; the SPAWN provides the first sample;
  - it disappears when `t ≥ despawn_tick`, not when the message arrives, so that it does not vanish
    earlier than what is seen.
- **Linear interpolation.** It is enough: the server records every tick and snapshots arrive at 30 Hz. If
  the F4 ghost showed errors on curves, it can be switched to Hermite with the velocities
  that already travel, without changing the format.

---

## 8. Server loop

### 8.1 Tick order

`ZoneServer._physics_process` (`process_physics_priority = -100`). The server's characters
have no `_physics_process` of their own that simulates.

```gdscript
func _physics_process(delta: float) -> void:
	_metrics.begin_tick()
	_transport.poll(_tick)          # authentication, READY, LEAVE, INPUT_BATCH → InputQueue.push()
	_tick += 1
	var s: int = _tick
	_process_departures(s)          # disconnection or LEAVE → DESPAWN (reason 1) and quarantined id
	for entity: NetEntity in _registry.get_sorted():          # ascending net_id
		if entity.kind != NetProtocol.EntityKind.PLAYER:
			continue
		var character: PlayerCharacter = entity.get_character()
		var before: Vector3 = character.global_position
		character.simulate(_queue_of(entity).take(s), delta)
		_check_motion(entity, before)                        # |Δpos| > 1.5 m or y < -100
	# Phase 3: actions validated against StateHistory. Phase 4: NPCs, structures and capture.
	_process_arrivals(s)            # pending READYs: spawn with the state "after s" (see 3)
	_social.step(s)                 # expired invitations and PARTY_STATUS (social.md 12.2 and 12.4)
	_record_history(s)              # StateHistory.record() of all entities
	_snapshot_builder.begin(s, _registry.get_sorted())       # encodes each record once
	_update_interest(s)             # each peer, every 6 ticks, staggered by net_id
	for peer: ServerPeer in _peers_in_world:
		if s % NetProtocol.SNAPSHOT_INTERVAL_TICKS == peer.entity.net_id % NetProtocol.SNAPSHOT_INTERVAL_TICKS:
			_transport.send(peer.peer_id, NetProtocol.CH_SNAPSHOT, _snapshot_builder.build_for(peer))
	_transport.flush()
	_metrics.end_tick(s)
	tick_finished.emit(s)
```

This is a phase 2 sketch: the normative order, with all the steps that have been added since (NPC
brains, combat with abilities, projectiles, effects and the phase 4 knocked-down state
([abilities.md 4.1](abilities.md#41-orden-del-tick-completa-fuertemd-17)), forts, NPCs, the social step and the
per-section metrics), is the one in the header of `scripts/server/zone_server.gd`.

- **Staggered sends.** Each client receives its snapshot on the ticks matching the parity of its
  `net_id`, so the cost is spread across the two ticks of the interval. Each party's PARTY_STATUS
  goes out the same way, on its tick out of the interval's 30 (`(tick + party id) % 30 == 0`).
- **Spawns and removals.**
  - Spawns go after simulating, so the first simulation of a new player is that of
    tick `s + 1`, with no one-tick offset.
  - Removals go before simulating.
- **Movement check** (`_check_motion`). The server accepts no state from the client, so
  these checks only detect its own errors:
  - `|Δpos| > 1.5 m` in one tick: logged as a physics error (terminal velocity gives
    0.83 m per tick).
  - `y < −100`: respawns at its spawn point and raises its teleport counter.
- **Metrics.** Every 10 s the tick duration (p50, p99 and maximum in µs, per
  section), the bytes per second (`host.pop_statistic`), the number of players and the
  percentage of substituted inputs are logged.
- **Shutdown.** `--quit-after-ticks`, `--idle-quit` and `--stop-file` send a NOTICE with code 2,
  do `flush()` and close. `SIGTERM` and `SIGINT` never reach GDScript and do not shut down in an
  orderly way (see [1.3](#13-headless-server-settings)). With `--platform` (docs/platform.md §7.2 and
  §19.9), shutdown also sends each character's final save and waits up to 10 s for the
  platform to answer it; the heartbeat's `maintenance` is a fifth trigger, with warnings through NOTICE
  (code 0). When the platform closes the instance (§6.1), the final saves go out first and the NOTICE is
  a kick (code 1): "El servidor de la zona se ha reiniciado: vuelve a entrar" (the zone server has restarted: log in again). Neither the
  messages nor their bytes change.

### 8.2 Input queue (`InputQueue`)

One per player: a ring of 64 slots indexed by tick, with the tick as a label.

```gdscript
enum SlotState { EMPTY, RECEIVED, CONSUMED_REAL, SUBSTITUTED, LATE_SEEN }

func push(input: PlayerInput, view_offset_q: int, next_tick: int) -> PushResult:
	var t: int = input.tick
	if t > next_tick + MAX_LEAD_TICKS:                       # 30
		too_early_count += 1
		_note_lead(t - next_tick)                              # discarded, but the lead counts
		return PushResult.TOO_EARLY
	var slot: Slot = _slot(t)
	if t <= _last_consumed:
		if slot.tick == t and slot.state == SlotState.SUBSTITUTED:
			slot.state = SlotState.LATE_SEEN                   # late: counted once
			late_count += 1
			_note_lead(t - next_tick)
			return PushResult.LATE
		return PushResult.DUPLICATE                            # redundant copy already consumed
	if slot.tick == t and slot.state == SlotState.RECEIVED:
		return PushResult.DUPLICATE                            # the first copy wins
	slot.set_input(t, SlotState.RECEIVED, input, view_offset_q)
	_note_lead(t - next_tick)                                  # only the first copy
	return PushResult.ACCEPTED

func take(tick: int) -> PlayerInput:                         # never returns null
	var slot: Slot = _slot(tick)
	var input: PlayerInput
	if slot.tick == tick and slot.state == SlotState.RECEIVED:
		input = slot.input
		slot.state = SlotState.CONSUMED_REAL
		_last_real_tick = tick
	else:
		input = _last_applied.duplicate_input()                # repeats ALL the buttons
		input.tick = tick
		if tick - _last_real_tick > REPEAT_MOVE_TICKS:         # 6
			input.move = Vector2.ZERO
		slot.set_input(tick, SlotState.SUBSTITUTED, input, -1)
		substitutions_total += 1
	_last_applied = input
	_last_consumed = tick
	return input

func get_ack_tick() -> int:                                  # max(contiguous received, last consumed)
	var t: int = _last_consumed
	while t < _last_consumed + MAX_LEAD_TICKS and _slot(t + 1).tick == t + 1 \
			and _slot(t + 1).state == SlotState.RECEIVED:
		t += 1
	return t
```

- **The substitute never invents edges.**
  - It repeats the full mask of the last applied input. A JUMP, PRIMARY or DODGE
    held during a loss does not reappear as a new edge when the next real input
    arrives, because `prev_buttons` already contains it.
  - A press that starts during the loss enters as an edge in the first real input
    that carries it.
  - The worst that can happen is losing a very short tap, which prediction corrects. There is never
    an action the player did not perform.
  - After 6 ticks without real inputs, movement goes to 0 and the buttons are kept. A
    client silently disconnected stands still within 100 ms, instead of running until
    the ENet timeout expires.
  - What an action held through a long disconnection does (a charged attack, for
    example) is decided by phase 3, without breaking this rule.
  - **Substituted inputs in phase 3.** Resolved by
    [combate.md 3.2](combate.md#32-entradas-sustituidas-cierra-la-nota-de-redmd-82): the substitute
    carries the `PlayerInput.SUBSTITUTED` bit (bit 15, outside `VALID_BUTTONS`) and, with it, the
    action machine does not count the press, does not fire the heavy attack on reaching maximum
    charge and does not open parry windows. No loss invents a blow or a parry.
- **One input per tick.** Sending more does not make you run faster: no speedhack is possible. The server
  never waits for an input.
- **`pop_min_lead()`** returns the minimum lead since the previous call (`NO_MARGIN` if
  there is no data) and resets it. Each client's snapshot uses it.
- **Inputs that are too early also give margin.** They are discarded (`TOO_EARLY`), but their
  lead (saturated at 127) is still recorded. If the server loses ticks (a process stall:
  Godot only recovers 8 per frame), the client ends up more than 30 ticks ahead; without this
  measure `TickSync` would receive no samples, would never fall back and the server would substitute
  all inputs forever (finding N1 of the phase 2 review).
- **`get_view_offset_q(tick)`** returns the `view_offset_q` of the real input of that tick, or −1
  if it was substituted. Used by phase 3.

---

## 9. Entities and replication

### 9.1 Network entities

- **`NetEntity`** (server):
  - `net_id` u16, assigned by `NetEntityRegistry`; a released id is quarantined for 600 ticks
    (10 s) before being reused;
  - `kind`, `realm`, `spawn_tick`, `owner_peer`, `display_name`, `flags`, the node and
    `teleport_counter`;
  - `ALWAYS_RELEVANT` flag, for objects the whole zone sees;
  - its health as the snapshots see it: `health_q` (the last byte of the record) and the own
    extra block (`health`, `max_health`, `status`, `respawn_tick`). Whoever carries the health (the
    phase 3 `Combatant`) updates them every tick with `set_health_view()`; without it, the
    entity is healthy (`health_q` 255, 1000 of 1000).
- **Records.** `NetEntity.encode_record()` writes its record directly into a buffer, without
  creating objects.
- **Simulation order.** `NetEntityRegistry.get_sorted()` returns the entities by ascending
  `net_id`, with a cache invalidated on every spawn and removal. That is the fixed simulation
  order.

### 9.2 Two replication styles

1. **Streamed** (players, NPCs, projectiles):
   - fixed-size record in the SNAPSHOT, unreliable;
   - filtered by interest and with priority;
   - interpolated on the client and stored in the server history.
2. **Stateful** (fortresses, gates, banners, braziers; phase 4):
   - reliable OBJECT_STATE, complete on entry and afterwards only when it changes;
   - for the whole zone (`ALWAYS_RELEVANT`), because `world.md` requires seeing the state of all the
     fortresses on the map;
   - continuous values travel as a formula: capture is
     `(start_tick, rate, progress_at_start)` and the client computes it.

Adding an entity type takes three things: a record codec in `EntityRecord`, a view on
the client and raising `PROTOCOL_VERSION`.

### 9.3 Snapshot construction

**`SnapshotBuilder.begin(s, entities)`** runs once per tick. It encodes **each record
only once** into a shared buffer and stores the offset of each `net_id`. Encoding is
O(entities); per client there are only memory copies.

**`build_for(peer)`:**

1. Writes the header with:
   - `input_ack_tick = queue.get_ack_tick()`;
   - `input_margin = queue.pop_min_lead()`;
   - `substitutions = queue.substitutions_total & 0xFFFF`;
   - the own state (`character.get_state().encode()`), its teleport counter and the
     own extra block (health, max health, status and respawn tick of its `NetEntity`).
2. Gathers the candidates: the entities of `peer.relevant` except the player's own. To each one it adds
   `peer.priority[id] += interest_policy.priority_weight(observer, entity)` (in phase 2, 1.0).
3. If all fit in 1200 B, it writes them all (the normal case in phase 2). Otherwise, it picks
   those with the highest priority, breaking ties by `net_id`, until the budget is full: `sort_custom` in
   phase 2, and buckets or C++ in Eldrun if measurement demands it.
4. Sets the priority of the written ones to 0 and groups the records by `kind` into sections.

**Guarantee:** with N candidates and C slots, none goes more than ⌈N/C⌉ snapshots without being sent. With
63 visible players and 50 slots (the capacity from [5.5](#55-server--client) with the 111 B state of v6; 52 with the 69 B one), each entity goes out at least once every two snapshots (with the ~10
fort NPCs, 73 foreign ones, too; it becomes one in three with more than 100). Verified by
`test_snapshot_builder`.

### 9.4 Client side

- **Own SPAWN:** `NetClient` instantiates the local `PlayerCharacter` and starts prediction.
- **Foreign SPAWN:** `RemoteWorld.on_spawn()`, which creates the view with its first sample.
- **DESPAWN:** `view.schedule_despawn(tick)`.
- **SNAPSHOT:** for each record of a known `net_id` and within
  `[spawn_tick, despawn_tick)`, `view.push(server_tick, record)`.

---

## 10. History for lag compensation

- **`StateHistory`** (server) stores, per entity, a 64-tick track (~1 s):
  - position in `PackedVector3Array`, yaw in `PackedFloat32Array`, flags in `PackedByteArray` and
    tick labels in `PackedInt64Array` (ticks are u32: see [4.1](#41-server-tick-and-application-rule));
  - indexed by `tick % 64`;
  - created when the entity is spawned and written in place every tick, without allocating memory;
  - stores unquantized values and is recorded after every tick, whether or not anyone is interested.
- **`sample(net_id, tick: float)`** interpolates linearly between the two ticks surrounding that
  instant. If the teleport counter changes between them, it returns the earlier sample.
- **Phase 3.** For an attack whose input belongs to tick T:
  ```
  view_tick = T − view_offset_q / 16
  allowed   = min(MAX_REWIND_TICKS (24),
                  rtt_ticks + lead(T) + clamp(ceil(interp_delay_q / 8), 4, 12) + 2)
  if view_offset_q / 16 > allowed + 8: the hit is not tested (suspicion + 1)
  view_tick = clamp(view_tick, T − allowed, T)
  ```
  - **Rejection slack** (`CombatResolver.REWIND_REJECT_SLACK_TICKS` = 8; phase 4 review, "cheats"
    lens): whatever exceeds the cap up to `allowed + 8` is **clipped** to the cap; only above that is it rejected and
    does it add suspicion. It used to be `allowed + 1` and an honest client with a process hitch or low FPS exceeded it:
    when the engine chains several physics steps in one frame (up to `max_physics_steps_per_frame` = 8),
    step k declares the view of the last drawn frame (`RemoteWorld.get_last_drawn_render_tick`, what
    the player actually saw), k ticks older, and the inputs of that frame arrive with less lead
    (`lead(T)` and the cap go down). The whole hit was rejected (or the arrow came out harmless) and added suspicion:
    with a 150–200 ms `SIGSTOP` on the "rate" bot process in `test_net_processes`, 2 to 5 hits
    rejected per run, the exact signature of its intermittent failure (`s=647`, `vq=385` with a cap of 23); with
    the slack, 0 in four runs. Whoever declares too much stays at the cap, like an honest player, gaining nothing;
    the `rewind` cheater (40 ticks) is still above `24 + 8`. Measuring on the client with the render of the step itself would not
    be enough (it does not cover the drop in lead) and would falsify what the player saw. As a side effect, an
    honest player with more RTT than the cap of 24 covers (about 200 ms) no longer sees their hits rejected up to 32
    ticks: they are tested with 24, without suspicion (they may miss against someone who is moving; not measured). Suspicion only
    appears in the report (`ZoneServer`): it neither kicks nor sanctions anyone.
  - **`ceil` in the interpolation** (same review): truncating `interp_delay_q / 8` lost up to 7/8 of a tick from
    an honest player's view.
  - **`rtt_ticks`** is measured by the server without a clock: it is the minimum, over the last 120 ticks, of
    `s − ack_snapshot_tick` on the arrival of each INPUT_BATCH, **bounded by a source the client does not
    control** (finding S4): `ceil(PEER_ROUND_TRIP_TIME · 60 / 1000) + maximum delay of the
    server's own `NetSim` + 3` (`ZoneServer.RTT_SLACK_TICKS`: snapshots go out every 2
    ticks and have to be processed). Without the bound, a client that delayed its
    `ack_snapshot_tick` by 20 ticks (with no real lag) passed itself off as someone with 350 ms of RTT and got the
    24 ticks of rewind. The server's `--net-sim` does count (it is real delay for it); the client's
    does not: in production it would amount to faking lag, so to test with simulated lag the
    server's is used.
  - **With jitter, the minimum is not enough (K5).** An honest player's view goes back
    `lead + RTT at that moment + snapshot age + interpolation`; the window minimum stays
    below the trip of any given tick (with `rtt=150,jitter=30` the measured minimum is 7 ticks and
    the maximum 13-14), so with the minimum alone the cap rejected 20% of an honest
    bot's active ticks (and added suspicion). That is why the cap uses `rtt = max(minimum, maximum)` of the same
    window, **with the same independent bound** (`ServerPeer.rtt_peak_ticks`): delaying the acks gives no
    more than `PEER_ROUND_TRIP_TIME + NetSim delay + 3`, with minimum or with maximum.
  - **`lead(T)`** is the measured lead of that input (it cancels out with the client's: an input that
    arrives late over the network counts with less lead and more travel), **bounded** by the client's usual one
    plus 3 (`InputQueue.get_typical_lead`: the median of the first-copy leads of the
    real inputs of the last 60 ticks) and by 8. Without a bound, the lead of each input is chosen by
    the client: sending only the inputs of its hit 14 ticks early raised the cap from 12 to 24 with LAN
    RTT (phase 3 review, R1).
  - **The rewind is fixed once per hit** (first active tick) and advances with the tick. For
    retroactive defense (invulnerability, parry, block) the server looks back at least
    `rtt_floor + 4 − 2` ticks (`rtt_floor` = the ENet RTT, `ServerPeer.rtt_floor_ticks`), even if the
    client asks for less.
  - **`interp_delay_q`** does not exceed 96 (12 ticks × 8, the maximum of `InterpolationClock`): the
    server limits it and adds a warning for whoever sends more (`NetProtocol.MAX_INTERP_DELAY_Q`). The
    formula already bounds it with `clamp(…, 4, 12)`.
  - **Faking lag gives no more rewind** than real lag does: with delayed acks (RTT bound),
    lead (bounded by the usual one and by 8) or per-tick rewind (fixed per hit). What remains is
    the declared interpolation (`interp_delay_q`, up to 96 without a warning), which the server cannot
    verify: a cheater with all their inputs sent early and that declaration reaches the cap of 24
    ticks even if their RTT is LAN. The cap bounds the possible damage.
  - **Why 24 ticks.** The real rewind is RTT + margin + interpolation delay, about 20
    ticks with 200 ms of RTT. The 24-tick cap (400 ms) covers up to ~250 ms of RTT with the
    normal delay. **Measured in K5:** with 150 ms of RTT and 30 ms of jitter the bots request 20 to
    22.5 ticks (lead 5-8, interpolation 6-7, travel 9-11), so the cap of 24 covers
    at most about 170-180 ms of RTT with today's `TickSync` margin and interpolation delay,
    not 250 ms: with 200 ms of RTT an honest player already hits the cap (design decision
    pending: raise `MAX_REWIND_TICKS` or reduce the `TickSync` margin).
  - **Hit test.** The capsule is rebuilt from the sample and tested with
    math (capsule against arc and ray against capsule), or with `intersect_shape` on a
    loose shape. Bodies are never moved backwards.
  - **Line of sight:** raycast against the current world.
- **Phase 2 already records the history and tests it.**

---

## 11. Interest management

- **Hook.** `InterestPolicy` has two methods:
  - `is_relevant(observer, entity, was_relevant) -> bool`;
  - `priority_weight(observer, entity) -> float`.
- **When it is evaluated.** The server recomputes each peer's relevant set every 6 ticks,
  staggered (`(s + net_id) % 6 == 0`), and also on every spawn.
  - The result is stored in `ServerPeer.relevant`.
  - Each change generates a SPAWN or a DESPAWN with reason 0.
  - Entities with `ALWAYS_RELEVANT` do not go through the policy.
- **Phase 2:** the base policy always returns `true` and 1.0. The 1200 B budget and the
  priority already work, so 64 visible players do not break the cap.
- **Eldrun:** `GridInterestPolicy`.
  - Uniform 64 m grid (`Dictionary[Vector2i, PackedInt32Array]`); an entity only
    changes list when it changes cell.
  - Enters at 200 m and leaves at 230 m (hysteresis).
  - The weight depends on distance (`clamp(1 − d/R, 0.1, 1)`), with more weight if the entity
    is fighting the observer or has them as a target.
  - See [15](#eldrun).

---

## 12. Phase 2 security

The server never accepts client state, and every decoded value is bounded.

| Measure | Detail |
|---|---|
| Input window | Ticks in `(last consumed, s + 30]` are accepted. The first copy wins even if the second is different |
| One input per tick | No speedhack; substitutes never invent actions |
| Buttons | `buttons &= VALID_BUTTONS` (bits 0–12 since v6; 0–8 up to v5) |
| Batches | Consecutive ticks by format; `count` from 1 to 8 |
| Per-peer limiter (`RateLimiter`, in ticks) | Unreliable: 2 per tick (120/s), burst of 30. Reliable: 10/s, burst of 20. Bytes: 16 KB/s, burst of 4 KB. Whatever exceeds is discarded and adds a warning. With stall credit (see below) |
| Warnings | Malformed packet, type unexpected for the session state or rate excess. 50 warnings in 600 ticks → kick NOTICE and disconnection |
| Cooldown after a kick | 1800 ticks (30 s): their IP (IPv6, by /64) or, from loopback, their normalized name receive `REJECT TOO_MANY_CONNECTIONS` right on connecting (or when the HELLO arrives, for the name) |
| Connections per IP | 4 at most (`--max-per-ip`), except loopback, so that local bots work. Checked on connect, not only with the HELLO; IPv6 counts by /64 ([3](#3-connection)) |
| HELLO in time | 90 ticks from connecting; otherwise the connection is cut ([3](#3-connection)) |
| Packets foreign to the protocol | Before the HELLO only authentication is admitted; afterwards, only RAW. Everything else is discarded without an engine error and each packet adds a warning ([2](#2-transport-and-channels)) |
| Realm | Validated against the zone. In phase 2 the client declares it (`DevAuthProvider`); since phase 5 it comes from the character (the claim in platform.md §5) and the HELLO field is ignored |
| Rewind | Bounded by what is measured ([10](#10-history-for-lag-compensation)); the RTT the client declares with its acks is bounded by the ENet one plus the server's simulator + 3 ticks |
| Debug commands | Only with `--debug-commands` |
| Chat (protocol 5) | Each CHAT_SEND counts as one more reliable message and also has its per-peer buckets, which it spends before sanitizing: say, zone and party, 1 message/s with a burst of 5; whisper, 1/s with a burst of 3 and 5 new recipients per minute; a text equal to the previous one within 10 s and to the same place is discarded. The first ten discards in every 600 ticks are free and each subsequent one adds a warning: from about 6 messages per second sustained (the transport lets 10 through without warnings) it reaches a kick. Party invitations, the same. The server sanitizes the text (including invisible characters and combining marks) and never sends a client the text of another realm ([social.md](social.md#12-implementación-fase-4)) |
| Inventory (v7) | INVENTORY_REQUEST counts as one more reliable message and has its per-peer buckets, which are checked on arrival, before anything else: 8 requests/s with a burst of 16 and, in addition, 2 SPLIT or DESTROY/s with a burst of 10 (they spend ids). Whatever exceeds immediately receives its INVENTORY_DELTA with `result` 8 RATE and the real contents of its slots; the first ten discards in every 600 ticks are free and each subsequent one adds a warning, like chat. A request outside the world, malformed or INVALID adds a warning; INVENTORY_SYNC_REQUEST, one every 5 s (more, a warning and no response). Accepted ones are applied at the end of the tick, after the spawns, in arrival order ([progression.md](progression.md) §4.2 and §19.12) |

**Stall credit.** Limiters count in server ticks, and the tick does not advance while
the process is stopped. If the server loses `k` ticks (a stall, a virtual machine pause;
Godot only recovers 8 per frame), honest clients keep sending one batch per tick and everything
arrives together in the first poll, with the tick not having advanced: the bucket would not refill, only the
30 oldest would pass and the rest (the newest) would add warnings until the client is kicked (finding N2).
That is why `ZoneServer` measures with an integer clock of real ticks (`Time.get_ticks_usec()`, only in
`scripts/server/`) how many ticks were lost between two polls and, before `poll()`, calls
`ServerPeer.grant_stall_credit(tick, lost)`: `RateLimiter.grant()` refills first and adds
afterwards `rate × lost` without a cap, and the next refill limits the bucket to its burst again.
Since the clock is an integer, the total granted does not exceed the ticks that have really elapsed.
Limits: the credit covers what fits in one poll (ENet delivers everything pending from the socket, but
a stall of several seconds overflows the system buffer anyway), and a network burst without a
server stall (a Wi-Fi drop that delivers more than 30 batches at once) still counts as
a rate excess.

**Cooldown after a kick (finding S6).** Warnings and buckets live in the `ServerPeer`,
which is created new and full on every connection: a kicked client came back within one RTT with 0 warnings and
full bursts (measured: 10 kicks per second with the same name and the same IP, without any
REJECT). Now `ZoneServer._kick` records a 30 s `_kick_until` entry:

- **Key.** `ip:<group>` (`ServerAuth.address_group`) if the IP is not loopback; if it is (there is no per-IP
  cap), `name:<normalized name>` with the name it had already given. Kicks that are not the client's
  fault ("no room left in the zone") do not record it.
- **Where it is checked.** The IP, in `peer_authenticating` (before the per-IP cap); the name, when
  the HELLO arrives. In both cases `REJECT TOO_MANY_CONNECTIONS` is answered (a code that already
  existed: it does not raise `PROTOCOL_VERSION`).
- **Purge.** When a kick is recorded, expired entries are deleted, so the dictionary does not
  grow beyond the kicks of the last 30 s (`get_cooldown_count()`).
- **Limit.** It is a brake, not a ban: an attacker with several IPs or with another name from loopback
  still gets in, and whoever shares an IP with the kicked player (a NAT network) waits the same 30 s. The
  per-account ban arrives with phases 5 and 6. The same goes for the social buckets (`ChatPeerState`):
  they are per connection until phase 5 ([social.md](social.md#127-decisiones-y-pendiente-de-la-fase-4)).

**Names in the HELLO (phase 4).** Since the client chooses the name, the `REJECT NAME` for a name already
used by someone in the zone says whether that name is connected, whatever its realm; together with the whisper's "not
connected" it gives an enemy away. It is not covered up in phase 4 because the client also chooses its
realm (`DevAuthProvider`) and can enter the enemy's directly; since phase 5 the name and the
realm come from the ticket's character and that rejection disappears (details in
[social.md](social.md#127-decisiones-y-pendiente-de-la-fase-4)).

**Phases 5 and 6:**

- **`TicketAuthProvider`** with a **52 B** `HandoffTicket` (v7, done in platform.md P4; format and test vector
  in [platform.md](platform.md) §5.1; replaces the 47 B one that was foreseen here):
  - fields: version, key, world, `ticket_id`, `character_id`, zone fingerprint, channel, realm
    (informational), arrival point, flags, issuance and expiry (+10 s);
  - HMAC-SHA256 signature truncated to 16 B with a key that has an identifier (rotatable);
  - verification with `Crypto.constant_time_compare`; single use is guaranteed by the platform when
    claiming the ticket (`authenticate` returns `PENDING` and the peer waits in `VERIFYING`), and the
    realm comes from the character, not from the ticket.
- **DTLS** (`host.dtls_server_setup(TLSOptions.server(…))`), mandatory before public
  tests: in staging and production the platform does not register a zone without a certificate
  (platform.md §10.2). Done in platform.md P9c (§19.18): `NetTransport.host(…, dtls)` below
  `GuardedEnetPeer`, `--dtls-cert --dtls-key` on the zone and `--dtls-cert --dtls-name` on `--connect`, `--bot` and
  `--bots`; with DTLS the disconnect is always started by the server (the client sends CLIENT_LEAVE and waits). What remains:
  a garbage datagram from a new address is a failed handshake and an engine error in the log, below
  the S1 filter (bounded by journald and the firewall, TEC-40), and each handshake costs 2 to 4 ms
  of the zone thread (§14).

The slot already exists in HELLO and the `AuthProvider` interface is already there.

---

## 13. Debugging tools

**`NetSim`** (shared, in ticks, with its own seeded `RandomNumberGenerator`):

- **Format:** `--net-sim=rtt=120,jitter=20,loss=5,dup=0,seed=1`, in ms, ms, % and %.
- **Delay per direction:** `rtt/2 ± jitter` (uniform), in rounded ticks, with a
  resolution of 16.7 ms.
- **Loss and duplicates:** only on the unreliable channels (1 and 2). Reliable channels and
  authentication are only delayed and keep FIFO order per (peer, channel): dropping packets at
  application level would break ENet's reliability.
- **Where it is applied.** `NetTransport` applies it on output and on input (with the seeds
  `seed` and `seed + 1`), so setting it on one side only simulates the full RTT; on both, it
  doubles it.
  - The channel of an incoming packet is deduced from its type (`NetProtocol.channel_for_type`).
  - Snapshots reordered by the jitter are sorted out by the client, as explained in
    [6.2](#62-client-tick).
- **It is reproducible:** same seed, same sequence.

**`NetDebugOverlay`** (client):

- **F3:**
  - ENet RTT and RTT in ticks (the ENet one does not include `NetSim`), loss, KB/s up and
    down;
  - `input_margin`, target margin, `TickSync` adjustments per minute, substitutions;
  - corrections per minute, last and maximum correction, ticks re-simulated;
  - interpolation delay, jitter, visible entities and average bytes per snapshot.
- **F4:** translucent ghost at the position of the last own server state and marks on
  the remote players' non-interpolated samples.
- **Next to the HUD.** On the networked client, F3 toggles at once this panel (on the right) and the
  sandbox HUD's debug panel (on the left): `OnlineMain` starts them hidden and the overlay does not
  mark the event as handled. The sandbox without arguments does not change.

**Server:**

- `ServerMetrics` measures each section of the tick with `Time.get_ticks_usec()` (allowed in
  `scripts/server`).
- `Performance.add_custom_monitor("eldmark/…")` for remote debugging from the editor.
- `--report=<json>` on shutdown and, while running, every 600 ticks (10 s): if the server is killed
  (`SIGTERM`, `SIGINT`) the one from the last mark remains, with `"closed": false`. Building it costs
  a few milliseconds with many records; the write goes inside the tick that reaches the mark.
  - **Bounded memory** (finding S3). Each spawn left its record in the report forever with its
    `InputQueue`, its `ServerPeer` and its `NetEntity` (about 70 objects and 80 KB per cycle: ~3 GB/h with
    a client entering and leaving in a loop). Now the record drops those references when the player leaves,
    `player_list` keeps only the last 1000 records (`max_logged_players`) and `kicks`, the
    last 200 kicks (`max_logged_kicks`). Anything older is summarized in `players.archived`,
    `strikes.kicks_total` and in the totals of `inputs`/`players.fake`. The record of someone still
    inside is never removed from the ring.

**`--state-log=<csv>`:**

- on the server, `tick,net_id,substituted,hex(PlayerState)` per tick and player;
- on a bot, `server_tick,hex(predicted),hex(server)` per snapshot;
- `tools/compare_state_logs.gd` cross-checks them.

**Commands** (with `--debug-commands`): `teleport`. On Windows, clumsy is also useful for testing
with real UDP.

---

## 14. Bandwidth and CPU budget

Overhead per UDP packet: about 40 B (IPv4 20, UDP 8, ENet ~12).

| Flow | Calculation | Total |
|---|---|---|
| Upstream, normal (R = 4) | (11 + 4·10 + 40) B × 60/s | ~5.5 KB/s |
| Upstream, with loss (R = 8) | (11 + 8·10 + 40) B × 60/s | ~7.9 KB/s |
| Downstream, 10 visible (v6) | (136 + 10·21 + 40) B × 30/s | ~11.6 KB/s (~10.3 with v5) |
| Downstream, 30 visible (v6) | (136 + 30·21 + 40) B × 30/s | ~24.2 KB/s (~22.9 with v5) |
| Downstream, ≥ 50 visible (cap, v6; ≥ 52 with v5) | (1186 + 40) B × 30/s | ~36.8 KB/s (~295 kbit/s) |
| Projectiles (v6) | (32 + 8 + ~10 of ENet) B per arrow and recipient; 20 arrows per second in view | ~1 KB/s |
| Server output, 64 players and all visible | 64 × 37 KB/s (+ projectiles, v6) | ~2.4 MB/s (~19 Mbit/s); ~2.5 MB/s with arrows |
| Server input, 64 players | 64 × 5.5 KB/s | ~350 KB/s |
| Eldrun, 300 players with no further levers | 300 × 37 KB/s | ~11 MB/s (~89 Mbit/s): too much |

The downstream in this table is that of protocol 6 ([abilities.md 5.6](abilities.md#56-ancho-de-banda)):
136 B are the 134 of the header with own state (111 B) and extra block plus the 2 of the
section header; with v5 they were 94 (92 and 2). Below the cap, the 111 B state adds +42 B × 30/s = +1.26 KB/s
per client; at the cap the packet was already full and what is lost is 2 records per snapshot (50 instead of
52). Added to the downstream are the ENTITY_EVENT messages, about 27 B per recipient and hit
([combate.md 6](combate.md#6-protocolo-tec-13-protocol_version--2)), and the projectile SPAWN and DESPAWN
messages (v6). The measurements below are from phase 2 (20 B record and 35 B state), from phases 3 and 4 (69 B state)
and, the last one, from v6 with the phase 4 kit (H5, [abilities.md 7.3](abilities.md#73-pruebas-cada-una--30-s)): with
the 111 B state, each client downloads 36.1 KB/s with 64 combatants (35.3 with v5).

**CPU (phase 2):** the p99 of the tick must stay below 8 ms (half of the 16.7 ms) with
64 clustered bots. It is measured per section: network, simulation (µs per character), history,
snapshots. That figure is the first of the per-battle player limit that `vision.md` asks for.

**Phase 2 measurements** (`tools/load_test.gd --matrix`, TEC-11, revised after the adversarial review).
Vado Gris with its Terrain3D, the server and the `--bots` swarm on the same 4-core machine (with no other
load), unoptimized GDScript, **120 s of measurement per scenario**. Fake players are `--fake-players`; bots are
real clients over ENet on loopback that receive snapshots (the "rtt=100" one with the network simulator
`--net-sim=rtt=100`; the others, with no delay). Tick in ms, p50 / p99 / maximum of the last 34 s of
steady state. Substituted: bot inputs that the server had to substitute, over the whole session and within
the measurement window (without the startup, see below):

| Scenario | Players | Tick | `sim` p50 | `snapshot` p50 | Downstream per client | Substituted (session / window) |
|---|---|---|---|---|---|---|
| clustered, 64 fake and 2 bots | 66 | 4.9 / 8.2 / 20.0 | 4.0 | 0.5 | 35.2 KB/s | 0.07% / 0.00% |
| clustered, 64 fake and 10 bots | 74 | 6.2 / 9.7 / 17.2 | 4.3 | 1.2 | 35.3 KB/s | 0.03% / 0.00% |
| clustered, 64 fake and 50 bots | 114 | 15.3 / 26.5 / 36.5 | 6.4 | 7.0 | 34.9 KB/s | 0.05% / 0.00% |
| **clustered, 64 fake and 10 bots, rtt=100** | 74 | 6.5 / 10.6 / 21.6 | 4.5 | 1.3 | 35.3 KB/s | **0.36% / 0.00%** |
| spread, 64 fake and 10 bots | 74 | 6.8 / 11.4 / 20.5 | 4.9 | 1.3 | 35.3 KB/s | 0.03% / 0.00% |
| joins and leaves (1 per second), 64 fake and 10 bots | 74 | 6.7 / 10.7 / 15.4 | 4.6 | 1.5 | 35.3 KB/s | 0.08% / 0.00% |
| clustered, 128 fake and 10 bots | 138 | 11.3 / 19.7 / 24.2 | 8.3 | 2.1 | 35.2 KB/s | 0.03% / 0.00% |
| clustered, 256 fake and 10 bots | 266 | 15.9 / 24.8 / 79.7 | 15.1 | 0.0 | 25.4 KB/s | 97.3% / 100% |
| spread, 256 fake and 10 bots | 266 | 17.5 / 27.1 / 41.8 | 16.7 | 0.0 | 24.0 KB/s | 97.2% / 100% |

- **Substituted, with 100 ms of RTT (the criterion of §16).** With 64 clustered fake players and 10 bots with
  `rtt=100`: 277 of 76,012 inputs (**0.36%** of the session, under 1%) and none within the
  measurement window. Each bot loses about 27 inputs (19–20 arrive late) in the first few seconds,
  while `TickSync` looks for its lead: it is a fixed startup cost, so the session percentage
  depends on how long it lasts (with 30 s it comes out at 1.2%, with 120 s at 0.36%) and that of the measurement window
  (from the first metrics line after the bots enter to the last one before they leave, subtracting what had
  accumulated at the start) is the one that measures steady state. **Criterion met.** Without delay and up to 138
  players, at most 0.08% over the session. No scenario had warnings, kicks or physics
  errors. (The first results of this section, at 30 s and without delay, said 0.09–0.16%: they did not measure the
  criterion, which asks for 100 ms of RTT.) Pending review: the startup with 100 ms of RTT begins with little
  lead (19–20 late per bot).
- **128 and 256 fake players.** With 138 players the median tick takes 11.3 of the 16.7 ms and the p99
  (19.7 ms) exceeds it on occasion, but the server holds the 60 ticks/s (60.1) and does not substitute
  inputs. **With 266 the server does not sustain real time**: `simulate()` and its section take 15–17 ms at the
  median, the server runs at 44–47 ticks/s and almost all real-client inputs (97%) are
  substituted; the median of `snapshot` and `net` drops to a few microseconds (probably because the
  server chains ticks to catch up on the delay; not verified) and the downstream per client drops to
  24–25 KB/s. It is a server CPU result, not a network one: 266 players in an unoptimized GDScript process
  fall outside what this phase promises.
- **Bandwidth.** With 57 or more visible players each snapshot fills the packet (1191 B) and each client
  downloads about 35 KB/s (criterion: 37 KB/s at most) and uploads 2.3 to 3.7 KB/s (3.7 with 100 ms of RTT).
  Spread or clustered makes no difference: without grid interest everyone sees everyone.
- **`simulate()` per character: 42 to 50 µs** (measured around each call), above the 25 µs that
  lever 6 sets. The whole `sim` section (input queue, fake players' brain, movement
  check) comes to about 57–66 µs per character: with 64 players that is ~4 ms of the tick's 16.7 ms.
- **Building a snapshot** of 57 records costs 250 to 730 µs (the common encoding of the tick's records
  is shared among that tick's snapshots, so it comes out more expensive with few clients and with the
  server saturated). With N real clients, N/2 are built per tick: with 50, the `snapshot` section reaches
  7.0 ms at the median and is what saturates the tick (levers 2 to 5).
- **CPU criterion not met.** The tick p99 with 64 fake players and 2 bots (66 players) is 8.2 ms and with
  64 fake and 10 bots (74) 9.7 ms (criterion: under 8 ms with 64 players), with medians of 4.9 and
  6.2 ms; the earlier 30 s series, with exactly 64 players, gave 8.7 and 9.6 ms. With 74 players
  it goes past 10 ms (up to 11.4 ms spread) and with 114 (50 real) the median tick already takes 15.3 ms of the
  16.7: the server cannot handle 50 real clients plus 64 fake ones. The first bottleneck is `simulate()` in GDScript
  (lever 6, ~44 µs per character against the 25 µs threshold) and, with many real clients, the
  `SnapshotBuilder`.

**Phase 3 measurements: combat brawls** (`tools/load_test.gd --brawl`, TEC-15, K5). Vado Gris with
its Terrain3D, the server and a swarm of 10 real bots (`--bots=10 --bot-brain=combat`: they receive
snapshots and ENTITY_EVENT messages and send their `view_offset_q`, so the server really rewinds) on the same
4-core machine, **idle** (load average of 0.2 at the start and no other Godot running). The rest
of the combatants are `--fake-players` with `--fake-brain=combat` in a ring in the open field 18 m from the
Vardheim camp (`--fake-center=0,-96`; the camp's safe zone would keep them from fighting), half
from each realm. **60 s of measurement** after 12 s of approach. Tick in ms, p50 / p99 / maximum; the other
columns, p50 of each section:

| Combatants | Tick | `sim` | `combat` | `combat_resolve` | `combat_events` | `snapshot` | Downstream per client | Substituted (window) | Rewinds rejected |
|---|---|---|---|---|---|---|---|---|---|
| 32 (22 fake and 10 bots) | 4.9 / 8.9 / 17.2 | 3.1 | 0.35 | 0.016 | 0.18 | 0.84 | 23.6 KB/s | 0.00% | 0 |
| **64** (54 and 10) | 9.4 / 15.9 / 24.9 | 6.5 | 0.77 | 0.094 | 0.17 | 1.41 | 35.3 KB/s | 0.00% | 0 |
| 128 (118 and 10) | 17.5 / 30.0 / 36.3 | 13.3 | 1.41 | 0.067 | 0.19 | 2.16 | 31.4 KB/s | 0.10% | **153 (the 10 bots)** |

`combat_resolve` (hits with rewind) and `combat_events` (building and sending the ENTITY_EVENT messages) hang from
`combat` and have been measured separately since K5; `snapshot` rises as there are more real clients to serve,
but here there are always 10.

- **First per-battle player limit with combat: 64.** With 64 combatants the median tick takes
  9.4 ms of the 16.7, the p99 (15.9 ms) still fits in one tick, not a single input is substituted in steady state and
  no rewind is rejected; each client downloads 35 KB/s (criterion: 37). With 128 the server stops
  sustaining real time: the median (17.5 ms) already exceeds the tick, the p99 reaches 30 ms and the 10 honest
  bots receive between 12 and 18 rewind rejections each (153 of 10,239 checks, with their
  suspicion). It is a symptom of saturation (with 32 and 64 there is not even one): a server that misses its
  ticks stretches the round trip that clients measure and their view offset goes beyond the cap. The exact
  cause has not been investigated; the practical consequence is that **no more than 64 should be let into
  a battle**, because past the limit rewind starts failing honest players. Interpolating between
  the three measurements, the median tick reaches 16.7 ms at around 120 combatants and the p99 reaches 16.7 ms
  at around 66.
- **The phase 2 CPU criterion (p99 < 8 ms) is not met with combat beyond about 28
  combatants** (32 already comes out at 8.9 ms): the `vision.md` goal of 64 per side is still pending the
  levers below, just as without combat (the phase 2 measurement with 66 players gave a p99 of 8.2 ms
  with a median of 4.9; with combat, 64 give 15.9 and 9.4).
- **Combat is not the bottleneck: `simulate()` is.** At 64 combatants, `sim` takes 6.5 ms of the median's 9.4
  (69%) and `combat` plus `combat_events` 0.9 (10%). `simulate()` costs 69–72 µs per
  character, against the 42–50 µs of phase 2, and the whole `sim` section 97–104 µs per player, against
  57–66 µs: the action machine and the fake players' combat brain add about 25–40 µs per
  character (the "`simulate()` cost" risk in combate.md §10; figures from another session and another
  machine, so not comparable in detail). All the combat work grows linearly with
  the combatants: about 0.14 hits per second per combatant in the three brawls (260, 551 and 1044
  hits in 60 s), with 18, 50 and 96 deaths.
- **Hits with rewind: 76, 80 and 97 µs per check** (797, 3756 and 10,239 shape
  and line-of-sight checks; there is work only on 275, 945 and 1822 ticks of the 4970). The `combat_resolve` section
  is 8 to 17% of `combat` and its p99 does not exceed 0.69 ms: the rewind of 128 combatants fits in the
  budget with room to spare.
- **Events.** 319, 705 and 1329 events in 60 s (3.9, 8.5 and 16 per second), arriving as 2602, 5181 and
  8194 packets (an event goes to everyone who has the attacker or the victim as relevant) and costing
  97 to 67 µs of sending per event. In bandwidth they are **0.5, 1.0 and 1.6 KB/s across the whole server**, that
  is, 0.1–0.2 KB/s per client against the 31–35 KB/s of snapshots: the event channel does not
  change the budget (the 37 KB/s per-client limit is set by the snapshot, as in phase 2).
- **Levers.** The first is still 6 (porting `simulate()`, now at ~70 µs per character, almost three
  times the 25 µs threshold) and then 4 (`build_for` in parallel); grid interest (1) does not
  help in a brawl, because everyone sees everyone. The 8 ms p99 with 64 requires bringing `sim` below
  about 3 ms: half the current cost per character.

**Phase 4 measurements: sieges** (`tools/load_test.gd --siege`, GUE-16, F6a). Vado Gris with its Terrain3D, 120 s of measurement with
all the bots already at the gate and in the fort's circle (fake players with `--fake-brain=siege` and 10 real bots `--bot-brain=siege`, half from
each realm), on the same 4-core machine **with another agent running its suite at the same time** (`uptime` of 0.9 to 1.7). Without NPCs.
Tick in ms, p50 / p95 / p99 / maximum of the last 34 s stretch:

| Siege | Players | Tick | `sim` p50 | Downstream per client | Substituted (window) | Rewinds rejected |
|---|---|---|---|---|---|---|
| 32 vs 32 | 64 | 10.6 / 15.3 / 19.1 / 27.8 | 6.8 | 36.1 KB/s | 0.00% | 0 |
| 64 vs 64 | 128 in the window; **118 with no clients in the last stretch** | 14.8 / 22.0 / 26.4 / 42.8 (of 118; with the 128, p99 of the marks 32.5) | 12.0 (of 118) | 28.5 KB/s | 50.76% | 25 (6 suspicious) |

The 64 vs 64 row is not of 128 players (F6b review): the swarm closed on its own clock and the server, slower
than real time, ran the last stretch without the 10 real bots (its `snapshot` of 0.002 ms gives it away); since the review the swarm
closes on the server tick (`--quit-at-server-tick`) and the summary warns if the stretch lacks the player peak.
The full results and what happens in the battle are in [fortress.md 8.3](fortress.md#83-lo-que-han-dejado-f0-f1-y-f2-añadidos-al-contrato-y-decisiones). With 64 players
the 8 ms p99 criterion **is not met** (19.1 ms, with the median already at 10.6), just as in the phase 3 brawl (15.9 ms with 64
combatants on an idle machine), the KB/s per client are met (36.1 of 37) and not a single input is substituted; with 128 the
server does not sustain real time (half the clients' inputs are substituted and rewind fails honest players).
**The first per-battle player limit at the fort is still 64 (32 vs 32)** (without the phase 4 kit; with it, the 20 vs 20 measurement below). The cost of the fortresses (the `war` section)
is 0.1 ms at the median: the bottleneck is `simulate()` (lever 6).

Since GUE-44 (F6b) the siege bots wait for their own at their camp's exit and move in formation (fortress.md 8.3, F6b,
package C). For the load it changes little: the server counts allies with a per-realm list that it gathers once per tick, only
while someone is waiting, and each `SwarmBot` also decodes the records of those of its realm (the same ones it already read in turns).
But `SwarmBot`s that join when the fake players have already left may wait up to 30 s at the camp: the repetition with NPCs
(GUE-16, F6b) has to verify that they reach the gate before the measurement window. The measurements above predate this. In those of
F6b (below) the summary verifies it: the 10 real bots get within 25 m of the circle at 25–26.5 s with 32 vs 32 and at
54 s with 64 vs 64, before the window (59 s).

**Sieges with NPCs** (`load_test.gd --siege --npcs` or `--scenario=siege --npcs`, GUE-16, F6b): the server starts with the
Vado Gris NPCs (four Hollows, the Ford Captain, the owner's garrison and the four camp Guardians) and the fort runs on its own,
without `fort_kill_captain`; without `--npcs`, the F6a siege with `--no-npcs`. Two runs of each 32 vs 32 siege, alternating, on the
same 4-core machine **with no other suite running** (load average of 0.5 to 1.1), so they are not compared in detail with those of F6a.
The first 64 vs 64 run had the same defect as the F6a one (its percentiles are of 118 players with no clients at all); the second,
from the F6b review, was done with the swarm closed by the server tick and with another suite running (load of 0.7 to 1.8).
Tick in ms, p50 / p95 / p99 / maximum of the last 34 s stretch; `npc_brains` (the NPC brains) and `npc` (their spawners), p50:

| Siege | Players | Tick | `sim` p50 | `npc_brains` / `npc` | `war` p50 / p99 | Downstream per client | Substituted (window) | Rewinds rejected |
|---|---|---|---|---|---|---|---|---|
| 32 vs 32 with NPCs (two runs) | 64 | 10.6 / 14.8 / 17.4 / 27.5 and 9.4 / 13.5 / 15.2 / 23.0 | 7.0 and 6.1 | 0.22 / 0.06 and 0.20 / 0.06 | 0.08 / 1.1 | 36.2–36.3 KB/s | 0.03 and 0.00% | 0 |
| 32 vs 32 without NPCs (two runs) | 64 | 9.1 / 12.8 / 15.0 / 27.9 and 9.9 / 14.2 / 16.9 / 24.9 | 6.2 and 6.7 | 0.05 / 0 (the dummies) | 0.08–0.09 / 1.0–1.1 | 36.2 KB/s | 0.00% | 0 |
| 64 vs 64 with NPCs, 1st | 128 in the window; **118 with no clients in the last stretch** | 16.2 / 22.8 / 27.0 / 39.6 (of 118; with the 128, the marks give p50 19.6 and p99 33.5) | 13.5 (of 118) | 0.27 / 0.07 (of 118) | 0.09 / 2.1 (of 118) | 29.0 KB/s | 38.6% | 83 (10 suspicious) |
| 64 vs 64 with NPCs, 2nd (F6b review) | 128 (90% of the last stretch) | 17.2 / 24.2 / 30.0 / 72.3 | 12.3 | 0.23 / 0.06 | 0.08 / 1.9 | 32.1 KB/s | 0.00% | 44 (8 suspicious) |

The 9 war NPCs (the 5 of the fort and the 4 camp Guardians) cost about 1 ms of the tick while alive (their
brains, with a p99 of 0.8 to 1.1 ms per 10 s mark while the Hollows live; the spawners, 0.06 ms; their `simulate()`, about
0.55 ms inside `sim`), and ~0.5 ms when only the four Guardians remain. It is of the
order of the difference between two identical runs (0.8–1.2 ms of p50): with these figures the siege with NPCs cannot be told apart from the one without
them. The criteria do not change: with 64 players, **p99 of 15.2 to 17.4 ms, NOT met** (`simulate()` dominates); 36.2–36.3 KB/s per
client and at most 0.03% of substituted inputs, yes; with 128, no: the p99 exceeds 29 ms, the server does not reach real time
(81 and 87%), the clients' inputs are substituted or not depending on how far behind it falls (38.6% and 0.00% in the two runs) and
rewind fails honest players in both.
**The first per-battle player limit at the fort stays at 64 (32 vs 32), also with the NPCs** (without the phase 4 kit;
with it, the 20 vs 20 measurement below). The battle of each run
and the 20 vs 20 telemetry session are in [fortress.md 8.3](fortress.md#83-lo-que-han-dejado-f0-f1-y-f2-añadidos-al-contrato-y-decisiones) (F6b, package E).

**Phase 4 measurements: brawls with the kit** (`tools/load_test.gd --brawl`, H5;
[abilities.md 7.3](abilities.md#73-pruebas-cada-una--30-s)). Like those of phase 3 (Vado Gris with its Terrain3D, 10
real bots `--bot-brain=combat` and the rest fake combatants in the `--fake-center=0,-96` ring, 60 s of measurement after
12 s of approach), with protocol 6 and the phase 4 kit: the fake players use abilities, potions, knockdowns and
finishers, **half carry the marksman template** (`--fake-loadout=marksman:50`) and are pure archers
(`--fake-archers`: in a dense brawl everyone has an enemy within 5 m and a normal shooter draws the sword; the
first measurement gave 0 arrows), of which half fire at the sky (`--sky-archers=50`: their arrows live 2 s). The fort's
NPCs (Hollows, captain, garrison and Guardians) are in the zone. Same 4-core machine, with other agents
running at times (load average of 0.5 to 0.7 at the start of each scenario). Tick in ms, p50 / p99 / maximum; the rest, p50
(p99 in parentheses in `combat_projectiles`); arrows: shots in the server's 83 s and peak alive (cap 64):

| Combatants | Tick | `sim` | `combat` | `combat_projectiles` | `snapshot` | Downstream per client | Substituted (window) | Arrows | Rewinds rejected |
|---|---|---|---|---|---|---|---|---|---|
| 32 (22 fake and 10 bots) | 6.5 / 11.3 / 27.2 | 3.5 | 0.55 | 0.25 (0.98) | 1.14 | 30.7 KB/s | 0.00% | 105, peak 13 | 0 |
| **40** (30 and 10; review, idle machine) | 7.5 / **12.4** / 16.2 | 4.3 | 0.62 | 0.25 (**0.90**) | 1.21 | 35.4 KB/s | 0.00% | 97, peak 18 | 0 |
| 48 (38 and 10) | 9.7 / **17.0** / 50.6 | 6.2 | 0.80 | 0.27 (0.89) | 1.34 | 35.9 KB/s | 0.00% | 256, peak 24 | 0 |
| **64** (54 and 10) | 10.7 / **19.3** / 30.1 | 6.5 | 1.00 | 0.43 (**1.68**) | 1.18 | 36.1 KB/s | 0.00% | 286, peak 37 | 0 |
| 64, all archers at the sky (`--sky-archers=100`) | 11.4 / 19.5 / 28.8 | 7.0 | 1.09 | 0.51 (2.04) | 1.74 | 36.2 KB/s | 0.00% | 374, peak 54 | 0 |
| 64, **cap full**: all marksmen and at the sky (`--fake-loadout=marksman:100 --sky-archers=100`; review) | 13.7 / 23.2 / 53.8 | 8.1 | 2.52 | 1.29 (3.09) | 1.55 | 39.2 KB/s | 0.00% | 4755, peak **64**, 4603 evicted by the cap | 4 of hits, 0 of arrows |
| 128 (118 and 10) | 16.9 / 28.9 / 38.1 | 12.5 | 1.50 | 0.90 (2.94) | 0.00 | 27.4 KB/s | 100% | 572, peak 51 | 0 |

- **The phase 4 criterion is not met with 64** (tick p99 ≤ 16.7 ms and `combat_projectiles` p99 ≤ 1 ms,
  abilities.md §7.3 and §8): 19.3 ms and 1.68 ms. With 32 it is met with room to spare (11.3 and 0.98 ms) and with 48 the tick
  is at the edge (17.0 ms; projectiles 0.89 ms). With 40, measured in the review (abilities.md §11.10), it is met: 12.4 and
  0.90 ms (another review run, 14.1 and 0.84 ms); the projectile margin is short. In the battery's brawls
  the cap of 64 arrows never fills: neither with all the archers firing at the sky (peak of 54) nor
  with 128 combatants (51), because the archers also fall and take 30 s to return; the cost already exceeds the reserve
  before that.
- **With the cap full** (forced measurement from the review: the 54 fake marksmen, pure archers and at the sky, 57
  shots per second): peak of 64 alive and 4603 evicted by the cap (DESPAWN 5 of the oldest in the zone) without
  errors; `combat_projectiles` 1.29 ms at the median and 3.09 at p99 (1.36 ms per tick with arrows: about 315,000 segments
  and 89,000 SPAWN/DESPAWN messages, 21 KB/s for the whole server), and the tick, 23.2 ms at p99 with peaks of 54 ms, in which the
  server rejects 4 hit rewinds. The cap bounds the live arrows but not the cost per shot: with many
  archers the 1 ms reserve is not enough, whatever the cap.
- **What arrows cost on the Terrain3D**: 0.30 to 1.05 ms on average per tick with live arrows (32 and 128
  combatants), growing mostly with the combatants (preparing the swept boxes of all the candidates, about
  6–8 µs per player or NPC per tick) and less with the arrows (about 10 µs per live arrow: 11 to 19 on average with 64, from
  544 to 628 µs). A ray against the terrain costs 1.2 to 2.8 µs (separate probe): it is not the world. Firing (aimed
  point and convergence) is spread over a few ticks.
- **The rest of the kit is not noticeable**: `combat` goes from 0.77 ms (phase 3) to 1.00 ms at the median with 64; abilities,
  potions, effects, knockdowns and finishers (29 knockdowns, 14 finished off and 3 bled out in the 64 run) fit in there. The downstream per
  client does not change (36 KB/s, the snapshots; the arrows add ~1 KB/s across the whole server) and no
  rewind is rejected up to 64.
- **Per-battle player limit with the phase 4 kit: 40** (it was 64 in phase 3), **measured**: 12.4 ms p99
  of the tick and 0.90 for projectiles (met). With archers, 64 exceeds the 16.7 ms p99 and the 1 ms reserve for
  projectiles; 48 is already at the edge of the tick and 32 is met with room to spare. It is the Vado Gris server's default capacity
  (`Zones.MAX_PLAYERS`, `NetZones.max_players`: used by `ServerConfig` if `--max-players` is not passed; a zone without
  its own capacity stays at 64), and the 40 brawl is in the `--brawl` battery. To get back to 64 lever 6 is needed (`simulate()`, which is still 60% of the tick) and making the
  preparation of the arrow candidates cheaper (rebuilding the boxes only for whoever has moved, or a grid instead of the
  sweep in x). The fort sieges (F6a and F6b) were measured without the kit; with it, by the same reckoning and **unmeasured**
  (an estimate), the fort would go from 32 vs 32 to about 20 vs 20 (measured later, in the integration review:
  below).

**Integration of abilities onto F6b** (merge of phase 4 with F6b): the F6b sieges above (32 vs 32 and 64 vs
64, with and without NPCs) predate the kit. Since the merge the fake players and the siege bots fight with it (step 1 of their plan,
[abilities.md 11.9](abilities.md#119-h5--integración)). The integration gave the limit at the fort with the kit as 40 (20 vs
20), but that was the unmeasured estimate above, and the measurement it proposed (`load_test.gd --siege --npcs`) carried no archers: the
siege fake players come out with the default template and the `SwarmBot`s have no kit. The default capacity of the Vado Gris server is
40 (`Zones.MAX_PLAYERS`); the F6b tools and tests that measure more players (the `SIEGE_MATRIX` sieges, 32 vs 32 and
64 vs 64; `siege_battle.gd` and `SiegeRunner`) request their capacity with explicit `--max-players` or `ServerConfig.max_players`
(`load_test.gd`: `server_max_players`, the players plus 8), and so does any manual session with more than 40 players. See also
[fortress.md 8.3](fortress.md#83-lo-que-han-dejado-f0-f1-y-f2-añadidos-al-contrato-y-decisiones).

**20 vs 20 siege with the kit and the NPCs** (integration review; GUE-16): `load_test.gd --scenario=siege --fakes=30
--bots=10 --seconds=120 --npcs`, with the default template and with half marksmen (`--fake-loadout=marksman:50`; the siege bots'
bow, since the review, only fires with a line of fire). Same 4-core machine with no other suite (load of 0.5 to 0.9);
the 40 brawl from the table above, repeated in the same session, gives 7.4 / 11.3 / 13.2 / 22.7 ms. Tick in ms of the last
34 s stretch; sections, p50 (p99):

| 20 vs 20 siege with NPCs | Tick p50 / p95 / p99 / max | Window p50 / p99 | `sim` | `combat_projectiles` | Downstream per client | Substituted (window) | Arrows | Rewinds rejected |
|---|---|---|---|---|---|---|---|---|
| Default template (the squire) | 8.2 / 12.8 / **16.2** / 32.6 | 8.9 / 17.1 | 4.9 (9.9) | 0 | 34.4 KB/s | 0.00% | none | 0 |
| Half marksmen | 9.6 / 14.3 / **16.9** / 38.7 | 9.6 / 17.2 | 5.8 (10.5) | 0.26 (**1.01**) | 36.1 KB/s | 0.00% | 328, peak 11 | 0 |

**The fort with the kit is on the edge of the phase 4 criterion** (tick p99 ≤ 16.7 ms and `combat_projectiles` p99 ≤ 1 ms): with the
default template it is met (16.2 ms) and with half marksmen it is slightly exceeded (16.9 and 1.01 ms); the window marks
give 17.1–17.2 ms in both. It costs more than the 40 brawl in the open field because of `simulate()` (4.9–5.8 ms at the median versus 4.3,
~70–74 µs per character on the slopes and the fort's esplanade) and the NPC brains (0.2–0.4 ms). **The per-battle limit
at the fort with the kit stays at 40 (20 vs 20), measured and with no margin**: the capacity is not lowered over what separates a run from the
criterion (of the order of the noise between two identical runs, ~1 ms), and the lever for gaining margin is still 6 (`simulate()`,
TEC-35). Battle details for each run are in [fortress.md 8.3](fortress.md#83-lo-que-han-dejado-f0-f1-y-f2-añadidos-al-contrato-y-decisiones)
("Revisión de la integración de las habilidades", the ability integration review).

**Phase 5 measurements: DTLS** (TEC-27, [platform.md](platform.md) §10.2 and §19.18, P9c). `tools/load_test.gd
--dtls-compare --repeat=3`: Vado Gris with its Terrain3D and its NPCs, **64 real bots** (`--bots`, two swarms of 32
clustered at the Vardheim camp: each snapshot is full) and no fake players, 60 s of measurement, the same scenario without
and with DTLS (`--dtls-cert --dtls-key` on the zone, `--dtls-cert --dtls-name` on the swarms, with the test RSA
2048 certificate) alternating, on the same 4-core machine with no other suite (load of 0.5 to 0.8 at the start).
Tick in ms of the last 34 s stretch; sections, p50 (p99):

| Run | Tick p50 / p95 / p99 / max | `net` | `snapshot` | Downstream per client | Substituted (window) |
|---|---|---|---|---|---|
| without DTLS, 1st | 14.9 / 21.8 / 26.5 / 36.5 | 2.16 (5.95) | 6.79 (11.99) | 35.5 KB/s | 0.00% |
| with DTLS, 1st | 15.2 / 22.5 / 27.2 / 44.8 | 2.42 (7.10) | 6.92 (12.61) | 35.4 KB/s | 0.08% |
| without DTLS, 2nd | 15.3 / 22.8 / 28.2 / 40.1 | 2.17 (7.05) | 7.03 (12.62) | 35.4 KB/s | 0.00% |
| with DTLS, 2nd | 15.6 / 23.7 / 29.8 / 66.4 | 2.50 (8.36) | 7.17 (14.29) | 33.3 KB/s | 1.70% |
| without DTLS, 3rd | 14.7 / 21.6 / 26.2 / 90.4 | 2.09 (6.20) | 6.71 (11.82) | 35.5 KB/s | 0.00% |
| with DTLS, 3rd | 15.8 / 23.6 / 28.6 / 36.7 | 2.51 (8.07) | 7.24 (12.84) | 34.6 KB/s | 0.00% |
| **average without / with** | **15.0 / 26.9** → **15.5 / 28.5** (p50 / p99) | 2.14 → 2.48 (+16%) | 6.84 → 7.11 (+4%) | 35.5 → 34.4 KB/s | |

- **TEC-27 criterion (provisional, pending the user): met.** DTLS raises the tick p99 by **5.9%** (from
  26.9 to 28.5 ms on average) and the p50 by 3.7% (from 15.0 to 15.5 ms). It is of the order of the noise between identical runs (the
  p99 without DTLS ranges from 26.2 to 28.2 ms), but the three runs with DTLS land above their pair. **The absolute
  figure: p99 of 28.5 ms with DTLS and 64 real clients**, far from the 8 ms of the phase 2 criterion and above
  the tick's 16.7 ms: 64 real clients (each with its own snapshot) saturate the server without encrypting anything (p50
  of 15 ms; `snapshot`, 6.8 ms). The Vado Gris capacity stays at 40 (above); with 40, the measurement below.
- **With 40 real bots, the Vado Gris capacity** (`--dtls-compare --bots=40 --repeat=2`, same session): tick p99
  from 15.9 to **15.4 ms with DTLS** (−3.3%: within noise; runs of 16.2 and 15.6 without and of 15.4 and 15.3 with), p50 from
  9.0 to 9.0 ms (+0.6%) and `net` +8%. At capacity, DTLS cannot be told apart from noise and the p99 fits in the tick.
- **Where the cost goes.** Receiving and decrypting is in `net` (+0.34 ms of p50 with 64 clients sending one input per
  tick); encrypting, in the section that sends, because `ENetMultiplayerPeer.put_packet` flushes the host on every packet:
  `snapshot` (+0.27 ms with 32 snapshots per tick) and `combat_events`; `flush` stays at a few µs. Per packet (probe in one
  process, 16 clients, 1200 ticks, three rounds, no waits): receiving a 60 B input, from 6.8 to 9.0 µs (+2.2 µs);
  sending a 1200 B snapshot, from 7.2 to 12.3 µs (+5.1 µs); on the client, from 7.5 to 10.6 µs per packet. With 64
  clients that comes to about 0.3 ms per tick, half of what the median rises in the load test.
- **Bytes.** Measured with a UDP relay between client and server: **29 B more per datagram**, always the same
  (13 B record header and 16 B tag: ChaCha20-Poly1305, the suite negotiated by mbedtls and Godot). The
  full snapshot comes out at 1240 B of UDP (1211 in plaintext), 1268 B of IPv4 or 1288 of IPv6: it fits in the 1500 of
  Ethernet, and the largest datagram ENet can assemble (its 1392 B MTU applies to the plaintext) comes out at 1421 B.
  **The 1200 B cap does not change.** Per client, the real downstream rises 1.1 KB/s (about 39 datagrams per second) and the
  upstream 2.0 KB/s (about 69): the KB/s figures in this section, from the ENet counters, do not see it (the
  37 KB/s criterion is measured with them; on the wire it would be about 36.5 KB/s with DTLS).
- **Handshake.** It is done by the zone's main thread, inside `poll`: **4.3 ms of server CPU per
  client with RSA 2048 and 2.0 ms with EC P-256** (the client, 1.9 and 2.7 ms). A batch of joins at once is noticeable in
  the tick: for production, EC P-256 certificates (the command is in `platform/deploy/docker-compose.yml`). Connecting
  takes about 0.6 s with a single client and 1.6 s with 16 at once (0.2–0.3 s in plaintext): ENet sends the CONNECT on its
  first retransmission, when DTLS is already ready.
- **Incidentally: the server's UDP buffer fills up.** With 64 real clients on the same machine, on every
  40–70 ms server stall the receive buffer (212 KB by default on Linux) overflows and the system drops datagrams
  (`RcvbufErrors` in `/proc/net/snmp` rises by about 60 per run). Inputs are expendable (they carry redundancy) and reliable data
  is resent, but this way some authentication confirmation was lost and its CLIENT_READY, which goes through another ENet
  channel, arrived earlier and was dropped: in 2 of 3 runs a bot was left loading until it was kicked. Since P9c,
  `SwarmBot` sends CLIENT_READY 1 s after connecting, like a client that loads the zone. For the VPS (TEC-20):
  raise `net.core.rmem_default` (Godot does not allow touching the ENet socket buffer).

**Levers for Eldrun, in order,** decided with the measurements at the end of phase 2:

1. Grid interest.
2. Lower the budget to ~700 B per snapshot, with priority by distance. The goal is
   ≤ 20 KB/s per client, ~6 MB/s of output.
3. Delta against `ack_snapshot_tick`, with the invariant that the frame stored on the
   server is exactly the one the client reconstructs.
4. `build_for` in parallel per peer with `WorkerThreadPool.add_group_task`: it is pure over the
   frozen records of the tick.
5. Port `SnapshotBuilder` to C++ (GDExtension, with the same API) if with 100 bots it exceeds 3 ms
   per tick.
6. Port `simulate()` to C++ on both sides if it exceeds 25 µs per character.
7. Eldrun at 30 Hz, announced in `WELCOME.tick_rate`.

---

## 15. Extension points

### Phase 3: action combat

- **State.** `PlayerState` grows with the action machine (attack, block, dodge and their
  phases) and stamina, simulated in `simulate()` inside `scripts/shared`. That way it is also
  predicted.
  - `PROTOCOL_VERSION` goes up.
  - `equals_exact`, reconciliation and the snapshot do not change shape.
- **Inputs.** The PRIMARY, BLOCK and DODGE buttons already travel, and their edge is computed with
  `prev_buttons`, like the jump.
- **Hits:**
  - `InputQueue.get_view_offset_q(T)` and `StateHistory.sample()`, with the caps from
    [10](#10-history-for-lag-compensation);
  - server-side validation of stamina, cooldown, reach and line of sight.
- **Damage and deaths.** Reliable ENTITY_EVENT ([5.5](#55-server--client)).
  - Remote players' events are applied when the `render_tick` reaches their tick; the player's own,
    on arrival.
  - The player's own health and stamina go in an extra block after the own state (bit 3 of
    the snapshot `flags`).
- **Respawn:** teleport counter.
- **Remote player animation:** `action` byte of the record.

### Phase 4: capturable fort

- **The fort** is a `NetEntity` of type STRUCTURE with `ALWAYS_RELEVANT`. It is replicated through
  reliable OBJECT_STATE:
  - full state in the SPAWN and afterwards only the changes;
  - capture as a formula;
  - formats fixed in protocol 3 ([5.5](#55-server--client)): OBJECT_STATE, the STRUCTURE ENTITY_SPAWN and the
    WAR and TELEGRAPH ENTITY_EVENT messages.
- **NPC guards:** streamed entities (NPC type, same record), simulated in step 4 of
  [8.1](#81-tick-order) and interpolated on the client.
- **Announcements** ("¡Vado Gris capturado!", Vado Gris captured!): through NOTICE or ENTITY_EVENT, applied on the
  render tick.
- **Chat and parties** (protocol 5, [social.md](social.md#12-implementación-fase-4)): CHAT_SEND and
  CHAT_MESSAGE (`0x40` and `0x41`) through reliable channel 3. They are distributed by the social service's `ChatRouter`
  (`scripts/server/social/`), which `ZoneServer` only feeds with types `0x40` to `0x4F`. `NetClient`
  decodes the S→C ones (CHAT_MESSAGE and PARTY_*) and emits signals; `SwarmBot` decodes them and discards them without
  counting them as malformed ([social.md](social.md#12-implementación-fase-4), 12.7).

### Phases 5 and 6: accounts and handoffs

- **`character_id` and `ticket`** already travel in HELLO. `AuthProvider` is replaced by
  `TicketAuthProvider`, and `ZoneServer` changes: the `VERIFYING` state (the claim), the quota that counts
  those verifying and `start(…, platform)` ([platform.md](platform.md) §5.2 and §14.3).
- **The handoff** repeats the connection: HANDOFF → new connection with ticket → WELCOME → load →
  CLIENT_READY. The realm now comes from the character.

### Eldrun

- Grid interest with hysteresis.
- Priority by distance and combat.
- Per-snapshot budget (already exists).
- Staggered sends and single encoding per tick (already exist).
- Delta against the confirmed base (`ack_snapshot_tick` already travels).
- Visual-only remote scene.
- C++ levers according to measurement.
- `--bots=N` with spread, clustered and join-and-leave scenarios to measure before designing
  the sieges.

---

## 16. Test plan

Everything runs with the current runner (`godot --headless --path . -s res://tests/run_tests.gd`), which
fails on any engine error; each test lasts less than 30 s. The helpers are in
`tests/net_harness.gd`.

**Two suites at once** (two copies of the project, or two runs in the same folder) do not
step on each other: each test process starts looking for ports in its own slot according to its pid
(`NetHarness.first_port_for`), leaves the reports and logs of the processes it launches in
`build/<pid>/` (`NetHarness.build_path`; at startup, the folders of processes that no longer
exist are deleted) and the `--local` process test uses a lock of its own (`--dev-lock-path=<path>`,
with the server's log next to it) instead of the real `user://dev_server.json`, which is shared by
all copies of the project.

### Unit

- **`test_net_messages`**:
  - round trip of every message with the offsets and sizes in this document;
  - truncated messages, with extra bytes, of unknown type or with `count` out of range →
    `null`;
  - *fuzz* with 10,000 random buffers (seeded) without errors;
  - position quantized within ±5 km with an error ≤ 5 mm, and saturation out of range;
  - INPUT_BATCH: the decoded inputs equal `quantized()` of the originals, and the
    button mask is applied.
- **`test_input_queue`**:
  - acceptance window (late, too early, different duplicates: the
    first wins);
  - `get_ack_tick()` with gaps and after a substitution;
  - lead only with first copies, with the late ones and with the too-early ones
    (saturated at 127);
  - movement to 0 after 6 ticks.
  - **No invented edges:** with JUMP held and inputs 15–17 lost, input 18 with
    JUMP does not make the character jump again (with a real `PlayerCharacter`).
- **`test_tick_sync`**:
  - margin sequences → expected steps;
  - proportional debt and waiting until the ack after the adjustment;
  - forward resync and never backwards;
  - target margin according to jitter.
- **`test_interpolation_clock`**: converges to the delay with synthetic jitter and jumps with errors
  over 10 ticks; adopts within ≤ 40 ticks a sustained downward step of the offsets, does not
  mistake a short dip for a step and keeps working with ticks above 2^31.
- **`test_remote_interpolator`**:
  - `lerp`, and `lerp_angle` when crossing ±PI;
  - 6-tick extrapolation and stop;
  - teleport counter;
  - visibility according to `spawn_tick` and `despawn_tick`.
- **`test_state_history`**: fractional samples, ring overwrite, teleport and
  `forget`; ticks above 2^31.
- **`test_net_sim`**:
  - same seed → same sequence;
  - loss does not touch the reliable channels;
  - FIFO order of the reliable ones;
  - delay within `rtt/2 ± jitter`;
  - `NetTransport`: `connect_timeout_ms` (connection failure within ≤ double) and the filter for
    packets foreign to the protocol with a raw ENet client (`tests/raw_enet_attacker.gd`):
    discards before and after the HELLO without engine errors, a RAW that arrives together with the
    confirmation is not lost, bounded authentication messages, silenced peer.
- **`test_snapshot_builder`** (property test): 200 random entities for 600
  ticks.
  - No packet exceeds 1200 B.
  - With N relevant and C slots, no entity goes more than ⌈N/C⌉ snapshots without being sent.
  - The player themself never appears among the records.
  - What is built is decoded with `NetMessages.Snapshot.decode`.
- **`test_rate_limiter`** and **`test_server_auth`**: each REJECT reason and the per-IP cap with
  the loopback exception (and IPv6 by /64); stall credit of the limiters; warnings with
  ticks above 2^31.
- **`test_zone_server`** / **`test_zone_server_net`** (security and robustness): server stall
  without kicking an honest client; idle connections from one IP that do not exhaust the slots, and the
  HELLO deadline; cooldown after a kick; RTT bounded against a client that delays its
  acks; flood of packets foreign to the protocol before and after the HELLO (kick, tick < 16 ms); continuous
  joins and leaves without memory growth.

### Single-process integration

- **`test_prediction`** (no network). Server and client worlds in two `SubViewport` nodes with
  `own_world_3d = true` (separate physics spaces), with one `PlayerCharacter` in each.
  - Same inputs → `predicted[t].encode() == server[t].encode()` on every tick, turning,
    jumping and on the ramp (the feet touch the ground at more than 2 m: a jump on the flat reaches 1.5 m).
  - The copy of the client's substitution rule (`_input_or_substitute`, when replaying with gaps
    in the ring after a forward `hard_reset`) leaves, tick by tick, the same states as the real
    `InputQueue` with the same inputs and the same gap (of more than 6 ticks).
  - The server substitutes the input of tick X and the states arrive 6 ticks late → the
    client reconciles and ends up exactly equal from then on.
  - Smoothing:
    - at the transition, the global position of `Visual` does not jump more than 1 mm;
    - the offset falls below 1 mm within 30 ticks;
    - with more than 3 m, direct jump;
    - character turned 90°: the local offset is correct.
- **`test_net_loopback`** (real ENet over 127.0.0.1). `ZoneServer` and 3 `NetClient` bots, each
  in its own `SubViewport` with its own `SceneMultiplayer`; 600 ticks. Each scenario is a separate
  method:
  - **a)** Correct handshake, and REJECT for version, realm and `sim_hash`, without engine errors
    (no sends before `peer_connected`).
  - **b)** SPAWN and DESPAWN on connecting and disconnecting (LEAVE and cut).
  - **c)** Without `NetSim`:
    - 0 corrections from tick 60 on;
    - each bot draws the other two within 0.5 m of `StateHistory.sample()` at its
      `render_tick`.
  - **d)** With `rtt=150, jitter=30, loss=10`:
    - steady-state lead: the **minimum of the `TickSync` window** (`get_window_min()`, what
      the control loop regulates) in [0, 6], which is `MAX_TARGET` (4) + `SLOW_DOWN_THRESHOLD` (2): the
      mean of each bot in that range and at least 80% of the samples inside. It is not required of the
      `input_margin` of each individual snapshot: it is the minimum of two arrival ticks and, with ±30 ms of
      jitter, it lies by design between 2 and 4 ticks above the window minimum (in the
      measurements, 28–35% of each bot's snapshots exceed 6 and their mean is ~6.1). Requiring it
      would force lowering the lead target and accepting more late inputs;
    - less than 2% of late inputs;
    - each correction coincides with a rise in `substitutions`;
    - exact convergence after 60 idle ticks;
    - no hard resync after startup.
  - **e)** `DEBUG_COMMAND teleport`: the client jumps (without smoothing) and ends up exact.
  - **f)** Server stalls (40 ticks with one bot; 20 with two): `TickSync` recovers (the
    lead returns to normal, with no new substitutions or corrections) and remote players do not
    freeze for more than 15 ticks after the data returns.

### A separate process (`test_server_main`)

- The server as a process: `--quit-after-ticks`, `--idle-quit`, report, `--stop-file` (orderly shutdown
  and old stop file) and the periodic report that remains if the process is killed.

### Several processes (`test_net_processes`)

- **Launch.** `OS.create_process(OS.get_executable_path(), […])` launches:
  - the server: `--headless … -- --server --port=<free> --quit-after-ticks=900 --report=…`;
  - two `--bot` with `--quit-after-ticks=700 --report=…`.

  It waits at most 25 s, checking `OS.is_process_running`.
- **Determinism across processes.** Each bot compares, on every snapshot, its `predicted[S].encode()`
  with the bytes of the server's own state. Without `NetSim`: 0 unexplained differences (those
  that do not coincide with a rise in `substitutions`, a teleport or, since phase 3, an own
  combat event: what the server imposes on the player —stagger, stun, push,
  stamina spent on blocking, death, respawn— and the client does not predict; see
  [combate.md 11](combate.md#11-cambios-durante-la-implementación)).
- **Second pass with `--net-sim`** on the bots: exact final convergence (idle for the last
  60 ticks) and no hard resync.
- **Interference detection.** It also detects whether the server's foreign bodies or the
  Terrain3D collision alter Jolt queries.
- **Cheating bot** (`--bot-cheat=version|future|dupes|garbage|flood`, one method per mode):
  rejected or kicked, without the honest bot having unexplained differences or the server
  logging errors.
- **Combat cheating bot** (K5, TEC-14; `--bot-cheat=rewind|reach|rate`, all three at once
  against the `test_world` dummy): `rewind` fights with its view falsified to 40 ticks and the server
  does not test a single hit (suspicion per hit); `reach` attacks from 5 m and does not connect; `rate` mashes
  PRIMARY and hits only at the combo's pace. None deals extra damage. In a process with real ENet
  they are in `test_bot_cheat` (one per mode, with an honest control bot) and in
  `test_net_processes`.

### Load (manual)

`tools/load_test.gd`, outside the runner:

- Server with `--fake-players=N` (inputs injected into the `InputQueue`, without network) and
  `--bots=50` processes.
- 64, 128 and 256 players; spread, clustered (all within 60 m) and join-and-leave scenarios at 1
  per second; 120 s each. `--matrix` does it with 64 fake players (+ 2, 10 and 50 bots, spread and with
  joins and leaves), 128 clustered fake players and 256 fake players clustered and spread (+ 10 bots), and the bots of the
  criterion scenario with `--net-sim=rtt=100`.
- Phase 2 criterion, with 64 clustered bots:
  - tick p99 < 8 ms;
  - ≤ 37 KB/s per client;
  - less than 1% of inputs substituted with 100 ms of RTT, measured within the measurement window
    (without the startup); the tool also shows the percentage for the whole session.
- Combat brawls (TEC-15): `--brawl` (or `--scenario=brawl`) with 32, 64 and 128 combatants, fake players with
  `--fake-brain=combat` in a ring (`--fake-center`) plus 10 real combat bots, 60 s of measurement
  each. It measures per section (hits with rewind, events, snapshots) and the KB/s with the ENTITY_EVENT messages;
  results and the first per-battle player limit in 14.
- Fort sieges (GUE-16): `--siege` (or `--scenario=siege`) with 32 vs 32 and 64 vs 64, 120 s of measurement with the bots already at the
  gate and the circle; the fake players carry `--fake-brain=siege`, the real bots `--bot-brain=siege` and the server, without NPCs, opens the circle
  with `--run-at=<tick>:fort_kill_captain` and writes a battle log. With `--npcs` (F6b), with the zone's NPCs and without that command.
  Figures in 14.
  gate and the circle; the fake players carry `--fake-brain=siege`, the real bots `--bot-brain=siege` and the server opens the circle with
  `--run-at=<tick>:fort_kill_captain` and writes a battle log. Figures in 14.
- Brawls with the phase 4 kit (H5, [abilities.md 7.3](abilities.md#73-pruebas-cada-una--30-s)): `--brawl` has since
  then carried half of the fake players with the marksman template (`--fake-loadout=marksman:50`), pure archers (`--fake-archers`) of
  whom a share fires at the sky (`--sky-archers=<percentage>`, 50 by default; with 100, the maximum of live arrows), and the
  fort's NPCs in the zone. The summary adds the `combat_projectiles` section, the arrows and the kit, and the phase 4 criterion: tick p99
  ≤ 16.7 ms and `combat_projectiles` ≤ 1 ms. Figures and limit in 14.

### Architecture (`test_architecture`, extended)

- `scripts/shared/` (also `net/`, recursively) and `scripts/world/` (what the server loads)
  keep their rules: no `Time.get_`, `Input`, UI or client classes, no frame
  counters (`Engine.get_physics_frames`), no global randomness (`randf()`,
  `Array.pick_random()`, `shuffle()`, `rng.randomize()`), and every `RandomNumberGenerator` is created with
  its seed.
- The scenes the server loads (the zone ones, `player_character.tscn` and `server_main.tscn`) do not
  drag in client scripts, animations or character visuals.
- `scripts/server/` references no paths or classes from `scripts/client/`.
- `scripts/client/` references no paths or classes from `scripts/server/`. `LocalServerLauncher`
  only launches a process.
- The mandatory network scripts exist.

---

## 17. File plan

These are contracts for implementing in parallel. The signatures are public and stable; what is private
is left to the implementer's judgment.

- Static typing always.
- Identifiers in English; comments and texts in Spanish. (Superseded: comments and documentation are now in English; UI text and runtime log messages stay in Spanish until localization lands.)
- "Shared" = loaded by the server and not dependent on the client.

### 17.1 Split

| Package | Contents | Depends on |
|---|---|---|
| A · shared base | changes in `player_state.gd` and `player_character.gd`; `NetProtocol`, `NetMath`, `NetZones`, `EntityRecord`, `NetMessages`, `BotBrain`; `test_net_messages` | — |
| B · transport | `NetSim`, `NetTransport`; `test_net_sim` | A (constants) |
| C · server | all of `scripts/server/` and its unit tests | A, B |
| D · client simulation | `TickSync`, `InterpolationClock`, `ClientPrediction`, `CorrectionSmoother`, `RemoteInterpolator`; their tests and `test_prediction` | A |
| E · client application | `NetClient`, `RemoteWorld`, `RemotePlayerView`, `OnlineMain`, `ClientConfig`, `RealmSelect`, `NetDebugOverlay`, `LocalServerLauncher`, `BotSwarm`, `SwarmBot`; changes in `local_player_controller.gd` and `boot.gd`; scenes | A, B, D |
| F · integration | `NetHarness`, `test_net_loopback`, `test_net_processes`, `tools/`, `test_architecture` | all |

With the contracts of A fixed here, B, C, D and E can start at the same time.

### 17.2 `scripts/shared/` (shared)

```gdscript
# player_state.gd (changes)
## Rounds to a 32-bit float, the precision of PlayerState.encode().
static func to_f32(value: float) -> float
## true if encode() is identical byte for byte.
func equals_exact(other: PlayerState) -> bool

# player_character.gd (changes)
## If false, simulate() does not emit jumped or landed (replays and neutral advance).
var events_enabled: bool = true
## The yaw setter becomes: yaw = PlayerState.to_f32(value); basis = Basis(Vector3.UP, yaw)

# bot_brain.gd (new): used by client bots and the server's fake players
class_name BotBrain extends RefCounted
enum Pattern { WANDER, CIRCLE, IDLE, JUMPY }
func _init(seed: int, pattern: Pattern = Pattern.WANDER, home: Vector3 = Vector3.ZERO,
		radius: float = 30.0) -> void
## Unquantized input (the caller quantizes it). Deterministic with the seed: changes
## direction every 60–180 ticks, sometimes jumps and sprints, and returns toward home if it leaves the radius.
func next_input(tick: int, position: Vector3, yaw: float) -> PlayerInput
## From that tick on it only returns neutral inputs (convergence tests).
func set_idle_from(tick: int) -> void
```

### 17.3 `scripts/shared/net/` (shared; no `Time`, no `Input`)

```gdscript
# net_protocol.gd
class_name NetProtocol extends RefCounted
const PROTOCOL_VERSION: int = 7                      # 5 chat and parties (social.md 12), 6 abilities, 7 phase 5
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
const INTERP_DELAY_Q_SCALE: int = 8                  # interp_delay_q = delay in ticks × 8
const MAX_INTERP_DELAY_TICKS: int = 12
const MAX_INTERP_DELAY_Q: int = 96                   # anything beyond is a warning (S4)
const NO_MARGIN: int = -128
const VALID_BUTTONS: int = (1 << 13) - 1             # bits 0-12 (v6; 0-8 up to v5)
const MAX_NAME_BYTES: int = 48
const MIN_NAME_CHARS: int = 3
const MAX_NAME_CHARS: int = 24
const MAX_TICKET_BYTES: int = 256
const MAX_ZONE_ID_BYTES: int = 32
const MAX_DEFINITION_ID_BYTES: int = 32              # ASCII id of a structure's definition
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
const MSG_HANDOFF: int = 0x31        # reserved (phase 6)
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
const DEBUG_COOLDOWNS_OFF: int = 13                  # v6: u8 0 or 1
const DEBUG_APPLY_STATUS: int = 14                   # v6: u8 status_id, u16 ticks
const DEBUG_DOWN: int = 15                           # v6: no data
const DEBUG_REFILL: int = 16                         # v6: no data
const DEBUG_COMMAND_IDS: Dictionary[StringName, int]   # name -> id of each network command
enum Realm { NONE = 0, VARDHEIM = 1, SOLMARCH = 2, ASKARRA = 3 }
enum EntityKind { NONE = 0, PLAYER = 1, NPC = 2, PROJECTILE = 3, STRUCTURE = 4 }
enum Result { OK = 0, VERSION = 1, SIM_HASH = 2, REALM = 3, FULL = 4, TICKET = 5, MALFORMED = 6,
		TOO_MANY_CONNECTIONS = 7, NAME = 8, IMBALANCE = 9 }
enum DespawnReason { OUT_OF_INTEREST = 0, DISCONNECTED = 1, DEATH = 2, HANDOFF = 3, IMPACT = 4,
		EXPIRED = 5 }                                    # 4 and 5: projectiles (v6)
enum NoticeCode { INFO = 0, KICK = 1, SHUTDOWN = 2 }
static func channel_for_type(msg_type: int) -> int
static func transfer_mode(channel: int) -> MultiplayerPeer.TransferMode
static func is_unreliable_channel(channel: int) -> bool
## See section 3. The instance must be in the tree (after _ready()).
static func compute_sim_hash(character: PlayerCharacter) -> int
## Movement 0, buttons 0, look_yaw = quantized yaw, pitch 0. Already quantized.
static func neutral_input(tick: int, yaw: float) -> PlayerInput
static func realm_display_name(realm: int) -> String      # "Vardheim", "Solmarch", "Askarra"
static func result_text(result: int) -> String            # rejection reason, in Spanish

# net_zones.gd: only contact with scripts/shared/zones.gd
class_name NetZones extends RefCounted
static func default_zone_id() -> String
static func scene_path(zone_id: String) -> String                  # "" if it does not exist
static func allowed_realms(zone_id: String) -> PackedInt32Array    # Realm codes; empty = all
static func parse_zone_arg(args: PackedStringArray) -> String      # "" if absent
static func parse_realm_arg(args: PackedStringArray) -> int        # Realm.NONE if absent
static func realm_from_name(text: String) -> int
static func realm_name(realm: int) -> StringName                   # RealmCatalog id; "" if not playable
static func find_spawn_point(zone: Node, realm: int) -> Node3D     # the realm's or the first; null if there are none
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
static func quantize_velocity(value: float) -> int          # cm/s saturated to s16
static func dequantize_velocity(quantized: int) -> float

# entity_record.gd
class_name EntityRecord extends RefCounted
const SIZE: int = 21
const FLAG_GROUNDED: int = 1 << 0
const TELEPORT_SHIFT: int = 1
const TELEPORT_MASK: int = 0b11
const FLAG_SECOND_SLOT: int = 1 << 3                 # v6: weapon slot 2 active
const HISTORY_FLAGS_MASK: int = 0b111                # what the history takes (there bit 3 is the block)
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
## 0 if no health remains; otherwise clampi((health · 255 + max − 1) / max, 1, 255).
static func quantize_health(health: int, max_health: int) -> int
static func health_fraction(quantized: int) -> float
func encode_into(bytes: PackedByteArray, offset: int) -> void
static func decode_from(bytes: PackedByteArray, offset: int, kind: int) -> EntityRecord
## Server: writes the record without creating objects.
static func encode_character(bytes: PackedByteArray, offset: int, net_id: int,
		character: PlayerCharacter, teleport_counter: int, action: int, health_q: int) -> void
static func from_state(net_id: int, kind: int, state: PlayerState, teleport_counter: int,
		health_q: int = HEALTH_Q_FULL) -> EntityRecord
static func interpolate(a: EntityRecord, b: EntityRecord, t: float) -> EntityRecord

# net_messages.gd: each inner class has encode() -> PackedByteArray and
# static decode(bytes: PackedByteArray) -> <Class>, which returns null if malformed.
class_name NetMessages extends RefCounted
static func peek_type(bytes: PackedByteArray) -> int            # -1 if empty
static func peek_auth_result(bytes: PackedByteArray) -> int     # -1 without magic; 0 WELCOME; >0 REJECT
class Hello:
	var protocol_version: int; var sim_hash: int; var realm: int; var flags: int
	var character_id: int; var display_name: String; var ticket: PackedByteArray
class Welcome:
	var protocol_version: int; var server_tick: int; var tick_rate: int
	var snapshot_interval: int; var max_input_batch: int; var max_rewind_ticks: int
	var realm: int; var channel: int; var zone_id: String
	var realm_counts: PackedInt32Array      # 3 positions: Vardheim, Solmarch, Askarra (v3)
	func get_realm_count(realm_code: int) -> int
class Reject:
	var result: int; var text: String
class InputBatch:
	var ack_snapshot_tick: int; var interp_delay_q: int; var newest_tick: int
	var inputs: Array[PlayerInput]          # from oldest to newest, consecutive ticks
	var view_offsets_q: PackedInt32Array    # same size as inputs
class ClientReady:
	var flags: int
class ClientLeave:
	var reason: int
class DebugCommand:
	var command: int; var payload: PackedByteArray
	## Validates the data of commands 1 (12 B), 7 to 12 (v3) and 13 to 16 (v6); the rest, up to 64 B.
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
	var own_state: PlayerState              # null if absent
	var health: int; var max_health: int    # own extra block (only with own_state)
	var status: int; var respawn_tick: int
	var records: Array[EntityRecord]
	func is_in_combat() -> bool; func is_protected() -> bool; func is_dead() -> bool
	func is_downed() -> bool                             # v6: bit 3 of status
	## Used by SnapshotBuilder to write the header without creating the object. Returns the
	## offset where section_count starts. With own state it also writes the extra block.
	static func write_header(bytes: PackedByteArray, server_tick: int, input_ack_tick: int,
			input_margin: int, substitutions: int, own_teleport: int,
			own_state_bytes: PackedByteArray, health: int = 0, max_health: int = 0,
			status: int = 0, respawn_tick: int = 0) -> int
class EntitySpawn:
	var net_id: int; var kind: int; var spawn_tick: int; var realm: int
	var is_yours: bool; var teleport_counter: int; var state: PlayerState; var display_name: String
	var npc_def_id: int                                  # NPC (v3): u16 after the name
	var definition_id: String; var fields: Array[ObjectField]   # STRUCTURE (v3)
	const PROJECTILE_SIZE: int = 32; const PROJECTILE_FLAG_HARMLESS: int = 1 << 0   # PROJECTILE (v6)
	var owner_id: int; var projectile_def_id: int; var source: int; var volley_index: int
	var projectile_flags: int; var origin: Vector3; var velocity: Vector3
	static func for_fortress(net_id: int, spawn_tick: int, definition_id: String,
			state: FortressState) -> EntitySpawn         # realm 0, the 17 fields
	static func for_projectile(net_id: int, spawn_tick: int, shooter_realm: int, shooter_id: int,
			definition: int, source_of_shot: int, index_in_volley: int, harmless: bool, p0: Vector3,
			v0: Vector3) -> EntitySpawn
	func is_harmless() -> bool
	func to_object_state() -> ObjectState
class ObjectField:                                       # u8 field_id, u8 value_type, value
	enum ValueType { U8 = 1, U16 = 2, U32 = 3, S32 = 4 }
	var field_id: int; var value_type: int; var value: int
	static func make(id: int, type: int, field_value: int) -> ObjectField
	static func size_of_type(type: int) -> int           # 0 if it does not exist
class ObjectState:                                       # OBJECT_STATE (v3)
	var net_id: int; var tick: int; var fields: Array[ObjectField]
	static func from_fortress(object_id: int, state_tick: int, state: FortressState) -> ObjectState
	static func from_fortress_fields(object_id: int, state_tick: int, state: FortressState,
			field_ids: PackedInt32Array) -> ObjectState
	static func from_fortress_changes(object_id: int, state_tick: int, state: FortressState,
			previous: FortressState) -> ObjectState       # empty fields if nothing changed: nothing to send
	func add_field(field_id: int, type: int, field_value: int) -> void
	func get_field(field_id: int) -> ObjectField          # null if absent
	func get_value(field_id: int, default: int = 0) -> int
	func apply_to_fortress(state: FortressState) -> int   # fields applied; skips unknown ones and ones of another type
	func is_valid_for_fortress() -> bool
class EntityDespawn:
	var net_id: int; var despawn_tick: int; var reason: int
class Notice:
	var code: int; var text: String
class EntityEvent:
	enum Kind { HIT = 1, DEATH = 2, KILL = 3, RESPAWN = 4, WAR = 5, TELEGRAPH = 6, STATUS = 7, HEAL = 8,
			LOADOUT = 9, DOWNED = 10, INTERACT = 11 }                               # 7 to 11: v6
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
	var attack_id: int                                    # the source (CombatSource, v6) of HIT, DEATH, KILL, TELEGRAPH, HEAL and DOWNED
	var killer: int; var assistants: PackedInt32Array                               # DEATH, KILL
	var point: int                                                                  # RESPAWN
	var war_event: int; var war_realm: int                                          # WAR (v3)
	var shape: int; var position: Vector3; var yaw: float                           # TELEGRAPH (v3),
	var radius_cm: int; var impact_in_ticks: int                                    # with attack_id
	var source_entity: int; var op: int; var status_id: int; var stacks: int        # STATUS (v6)
	var until_tick: int; var healer: int                                            # STATUS, HEAL (v6)
	var template_id: int; var weapon_1: int; var weapon_2: int; var charges: int    # LOADOUT (v6)
	var actor: int; var end_tick: int                                               # INTERACT (v6), with op
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
	func get_source() -> int                                                        # 0 for those that do not carry one
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
## null if spec is empty. Format: "rtt=120,jitter=20,loss=5,dup=0,seed=1".
static func from_arg(spec: String, seed_offset: int = 0) -> NetSim
func configure(rtt_ms: int, jitter_ms: int, loss_percent: float, duplicate_percent: float,
		seed: int) -> void
func is_enabled() -> bool
## Maximum one-way delay, in ticks: rtt/2 + rounded jitter (S4).
func get_max_delay_ticks() -> int
func enqueue(packet: NetSim.Packet, now_tick: int) -> void
func pop_due(now_tick: int) -> Array[NetSim.Packet]
func describe() -> String

# net_transport.gd
class_name NetTransport extends Node
signal peer_authenticating(peer_id: int)
signal auth_received(peer_id: int, bytes: PackedByteArray)
signal peer_connected(peer_id: int)          # authentication completed on both sides
signal peer_disconnected(peer_id: int)
signal packet_received(peer_id: int, bytes: PackedByteArray)
signal connection_failed()
## Server only (S1): packets from a peer discarded for not being part of the protocol (see 2).
signal packets_discarded(peer_id: int, count: int)
const AUTH_TIMEOUT_SECONDS: float = 10.0     # v7 (5.0 up to v6): on both sides, from the connection
## Before host()/connect_to(). Empty = no simulator.
func set_net_sim_spec(spec: String) -> void
## With dtls (platform.md §10.2, P9c), dtls_server_setup(dtls) after create_server and before GuardedEnetPeer.
func host(port: int, max_peers: int, dtls: TLSOptions = null) -> Error
## With dtls (platform.md §10.2), dtls_client_setup(dtls_name, dtls) after create_client; without it, in plaintext.
func connect_to(address: String, port: int, connect_timeout_ms: int = 3000, dtls_name: String = "",
		dtls: TLSOptions = null) -> Error
func is_server() -> bool
func is_dtls() -> bool                       # P9c
## ERR_UNAVAILABLE if the peer is not connected yet.
func send(peer_id: int, channel: int, bytes: PackedByteArray) -> Error
func send_auth(peer_id: int, bytes: PackedByteArray) -> Error
func complete_auth(peer_id: int) -> Error
## Empties the queue and calls peer_disconnect_later(); forced disconnect_peer at 60 ticks. A client with DTLS does not
## start the disconnect: it waits for the server's (which answers this way to CLIENT_LEAVE) and at 60 ticks closes the whole
## connection (P9c, platform.md §19.18).
func disconnect_after_flush(peer_id: int) -> void
func poll(now_tick: int) -> void
func flush() -> void
func close() -> void
func get_rtt_ms(peer_id: int) -> float
## Maximum delay (ticks) that this transport's simulators add to a round trip (S4).
func get_sim_round_trip_ticks() -> int
func get_packet_loss(peer_id: int) -> float
func get_remote_address(peer_id: int) -> String
## {"app_in": int, "app_out": int, "wire_in": int, "wire_out": int} accumulated.
func get_byte_counters() -> Dictionary

# guarded_enet_peer.gd (S1): the peer that SceneMultiplayer sees on the server
class_name GuardedEnetPeer extends MultiplayerPeerExtension
signal packets_discarded(peer_id: int, count: int)     # at the end of each poll
var admitted: Dictionary                               # peers admitted by SceneMultiplayer (filled in by the owner)
var raw_sink: Callable                                 # (peer_id, payload) -> void: shortcut for RAW packets
func attach(inner: ENetMultiplayerPeer) -> void
func mute_peer(peer_id: int) -> void                   # discards without counting
func get_discarded_total() -> int
```

### 17.4 `scripts/server/` (server)

```gdscript
# server_config.gd
class_name ServerConfig extends RefCounted
var port: int = NetProtocol.DEFAULT_PORT
var zone_id: String = ""
const DEFAULT_MAX_PLAYERS: int = 64
var max_players: int = DEFAULT_MAX_PLAYERS   # from_args: that of NetZones.max_players(zone) if it has one
var max_connections_per_ip: int = 4
var idle_quit_seconds: int = 0
var quit_after_ticks: int = 0
var report_path: String = ""
var state_log_path: String = ""
var stop_file_path: String = ""     # S5: its existence requests orderly shutdown (checked every second)
var net_sim_spec: String = ""
var fake_players: int = 0
var debug_commands: bool = false
var dev_lock: bool = false
static func from_args(args: PackedStringArray) -> ServerConfig

# server_main.gd (+ scenes/server/server_main.tscn)
## Settings from 1.3, loads the zone with NetZones, prepares Terrain3D, creates NetTransport and
## ZoneServer, writes and deletes user://dev_server.json (with --dev-lock) and shuts down with
## --quit-after-ticks, --idle-quit or the appearance of the --stop-file file. With --report it rewrites
## the report every 600 ticks (S5). SIGTERM and SIGINT do not shut down in an orderly way (see 1.3).
class_name ServerMain extends Node
static var config: ServerConfig

# zone_server.gd
class_name ZoneServer extends Node
signal tick_finished(tick: int)
signal player_joined(peer_id: int, net_id: int)
signal player_left(peer_id: int, net_id: int)
var interest_policy: InterestPolicy = InterestPolicy.new()
## Tests only: deadlines and caps that get shortened (default values: the constants of the same name).
var loading_timeout_ticks: int = LOADING_TIMEOUT_TICKS
var hello_timeout_ticks: int = HELLO_TIMEOUT_TICKS      # S2: 90
var kick_cooldown_ticks: int = KICK_COOLDOWN_TICKS      # S6: 1800
var max_logged_players: int = MAX_LOGGED_PLAYERS        # S3: 1000
var max_logged_kicks: int = MAX_LOGGED_KICKS            # S3: 200
const RTT_SLACK_TICKS: int = 3                          # S4
var verify_timeout_ms: int = VERIFY_TIMEOUT_MS          # v7: 7000, VERIFYING deadline in real time
signal instance_closed(code: String)                    # v7: the platform closed the instance (platform.md §6.1)
func start(config: ServerConfig, world: Node3D, transport: NetTransport,
		auth_provider: AuthProvider, platform: ZonePlatform = null) -> Error   # v7: platform.md §14.3
func stop(notice_text: String = "") -> void
func get_tick() -> int
func get_peer(peer_id: int) -> ServerPeer
func get_peer_ids() -> PackedInt32Array
func get_player_count() -> int                          # v7: also counts VERIFYING
func get_registry() -> NetEntityRegistry
func get_history() -> StateHistory
func get_metrics() -> ServerMetrics
func get_cooldown_count() -> int                        # S6: cooldowns after kicks, not yet purged
## Networkless player: its inputs come from brain and go straight into its InputQueue.
func add_fake_player(brain: BotBrain, realm: int, template_id: int = 0) -> int   # v6: its template (0 = the default one)
## Authoritative teleport: raises the teleport counter.
func teleport(net_id: int, position: Vector3) -> void
func write_report(path: String) -> Error

# server_peer.gd
class_name ServerPeer extends RefCounted
enum State { AUTHENTICATING, VERIFYING, LOADING, IN_WORLD, LEAVING }   # VERIFYING (v7): claiming the ticket
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
var rtt_ticks: int = 0              # min. of (s - ack_snapshot_tick) over the last 120 ticks
var connected_tick: int = 0         # S2: for the HELLO deadline
var loading_since_tick: int = 0
var limiter_unreliable: RateLimiter
var limiter_reliable: RateLimiter
var limiter_bytes: RateLimiter
var pending_template_id: int = -1   # v6: the LOADOUT_SELECT template for the next spawn (-1 = none)
## Adds a warning; returns true if a kick is due (50 in 600 ticks).
func add_strike(now_tick: int, reason: String) -> bool
## N2: credit for the ticks the server did not simulate (a stall) for the three limiters.
func grant_stall_credit(now_tick: int, missed_ticks: int) -> void

# server_auth.gd
class_name ServerAuth extends RefCounted
func _init(config: ServerConfig, sim_hash: int, allowed_realms: PackedInt32Array,
		provider: AuthProvider) -> void
## Returns a NetProtocol.Result or AuthProvider.PENDING. v7: peer_id goes first (for the provider) and, with
## tickets (uses_tickets), neither the HELLO's realm nor its name is looked at, and there is no IMBALANCE.
func validate(peer_id: int, hello: NetMessages.Hello, remote_address: String, player_count: int,
		connections_from_address: int, filler_seats: int = 0) -> int
func uses_tickets() -> bool
func is_realm_allowed(realm: int) -> bool       # the zone looks at the realm of the claim
## SOC-01: source of the already-connected names (Callable with no arguments -> PackedStringArray).
func set_connected_names_source(source: Callable) -> void
func check_name(display_name: String) -> int   # NameRules.Reason (TAKEN if already connected)
## S2: key by which connections are counted per IP (IPv6 by /64 prefix, mapped IPv4 as IPv4).
static func address_group(remote_address: String) -> String

# auth_provider.gd
class_name AuthProvider extends RefCounted
## Identity and realm (platform.md §14.3). Base of DevAuthProvider and TicketAuthProvider
## (scripts/server/platform/).
const PENDING: int = -1
func authenticate(peer_id: int, hello: NetMessages.Hello) -> int   # OK, PENDING or reason (the base: TICKET)
func on_platform_event(event: PlatformEvent) -> bool              # true if it was its own (claim kind)
func take_completed() -> Array[AuthOutcome]
func cancel(peer_id: int) -> void
func uses_tickets() -> bool

# dev_auth_provider.gd
class_name DevAuthProvider extends AuthProvider   # immediately accepts the declared realm and name

# rate_limiter.gd: token bucket measured in ticks
class_name RateLimiter extends RefCounted
func _init(rate_per_tick: float, burst: float) -> void
func try_consume(now_tick: int, cost: float = 1.0) -> bool
## N2: adds tokens above the burst until the next refill (refills first, then adds).
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
var health_q: int = EntityRecord.HEALTH_Q_FULL     # last byte of the record
var health: int = DEFAULT_HEALTH; var max_health: int = DEFAULT_HEALTH   # own extra block
var status: int = 0; var respawn_tick: int = 0
## Called by whoever carries the health (Combatant) every tick; computes health_q.
func set_health_view(new_health: int, new_max_health: int, new_status: int,
		new_respawn_tick: int) -> void
func get_position() -> Vector3
func get_character() -> PlayerCharacter            # null if it is not a player
func encode_record(bytes: PackedByteArray, offset: int) -> void
func encode_spawn(tick: int, for_owner: bool) -> PackedByteArray

# net_entity_registry.gd
class_name NetEntityRegistry extends RefCounted
const ID_QUARANTINE_TICKS: int = 600
func allocate(kind: int, now_tick: int) -> NetEntity    # net_id 1..65535; null if none left
func release(net_id: int, now_tick: int) -> void
func get_entity(net_id: int) -> NetEntity
func get_sorted() -> Array[NetEntity]
func size() -> int
# v6 (abilities.md 4.4, H3b): projectile ids, from the same space and with the same quarantine
func allocate_transient_id(now_tick: int) -> int    # 0 if none left
func release_transient_id(net_id: int, now_tick: int) -> void

# spawn_picker.gd
class_name SpawnPicker extends RefCounted
func _init(world: Node) -> void
## Round-robin over the realm's points (see 1.5).
func pick(realm: int) -> Transform3D

# snapshot_builder.gd
class_name SnapshotBuilder extends RefCounted
func _init(policy: InterestPolicy) -> void
func begin(tick: int, entities: Array[NetEntity]) -> void
## Never returns more than MAX_PACKET_BYTES. Consumes pop_min_lead() from the peer's queue.
func build_for(peer: ServerPeer) -> PackedByteArray

# interest_policy.gd: the base considers everything relevant and with weight 1
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
func sample(net_id: int, tick: float) -> StateHistory.Sample     # null if out of range
# v6 (abilities.md 4.4, H3b): projectiles
func position_at(net_id: int, tick: int) -> Vector3     # Vector3.INF if absent; without creating objects
func swept_box(net_id: int) -> AABB     # 4 blocks of 8 ticks up to the last recorded; size.x < 0 with nothing

# server_metrics.gd
class_name ServerMetrics extends RefCounted
func register_monitors() -> void
func begin_tick() -> void
func begin_section(section: StringName) -> void
func end_section(section: StringName) -> void
func end_tick(tick: int) -> void
func add_counter(counter: StringName, amount: int) -> void
func summary() -> Dictionary     # p50/p99/max per section, KB/s, players, % substituted
```

### 17.5 `scripts/client/` (client)

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
var loadout: String = ""        # v6: --loadout=<template>; goes out in a LOADOUT_SELECT after the WELCOME
static func from_args(args: PackedStringArray) -> ClientConfig

# online_main.gd (+ scenes/client/online_main.tscn)
## Flow: RealmSelect if the realm is missing → NetTransport and NetClient.start() → welcomed: loads
## the zone in a thread → notify_zone_ready() → local_spawned: camera, HUD and overlay (in
## BOT mode, controller.set_bot() and nothing else). rejected/disconnected: notice in Spanish and back to
## RealmSelect (in BOT mode, exit with code 1). Settings: multiplayer_poll = false; in
## headless, max_fps = 120. It does not modify ClientMain: the sandbox stays the same.
class_name OnlineMain extends Node
static var config: ClientConfig

# net_client.gd
class_name NetClient extends Node
signal welcomed(welcome: NetMessages.Welcome)
signal rejected(result: int, text: String)
signal local_spawned(character: PlayerCharacter)
signal disconnected(text: String)
## v6 (abilities.md 5.3): the SPAWN is dispatched by kind before is_yours; projectiles are not
## characters and come out through here, with their DESPAWN.
signal projectile_spawned(spawn: NetMessages.EntitySpawn)
signal projectile_despawned(projectile_id: int, tick: int, reason: int)
func start(config: ClientConfig, transport: NetTransport,
		controller: LocalPlayerController) -> Error
## v6 (abilities.md 6, H4): LOADOUT_SELECT from the WELCOME; each entity's STATUS in its
## StatusTracker (a remote player's, on its render tick, the player's own too: phase 4 review);
## arrows in the ProjectileWorld (which enters the zone with the RemoteWorld).
func send_loadout_select(template_id: int) -> bool
func get_status_tracker(net_id: int) -> StatusTracker
func get_projectile_world() -> ProjectileWorld
func is_downed() -> bool
## Sends CLIENT_READY (only after peer_connected(1)). world_root receives the local character
## and RemoteWorld.
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
## Bots: snapshots with state, exact matches, explained differences (substitution,
## teleport, combat: combat_diffs, or the fort gate: gate_diffs) and unexplained ones, resyncs, TickSync adjustments and
## final state.
func write_report(path: String) -> Error

# client_prediction.gd
class_name ClientPrediction extends RefCounted
## v6 (H4): after each step() (never in replays); ProjectileWorld looks at the commitment there.
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
func get_input(tick: int) -> PlayerInput            # null if not in the ring
func get_predicted_state(tick: int) -> PlayerState  # null if not in the ring
func is_replaying() -> bool
func get_stats() -> Dictionary

# correction_smoother.gd
class_name CorrectionSmoother extends RefCounted
const HALF_LIFE_TICKS: float = 6.0
const MIN_OFFSET: float = 0.001
## Stores the base local position of each target (Visual and CameraTarget).
func setup(character: PlayerCharacter, targets: Array[Node3D]) -> void
func add_offset(world_offset: Vector3) -> void
func clear() -> void
## Inside the physics tick: decays and applies base + basis.inverse() * offset.
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
## Returns P0, the first tick with real input.
func start(spawn_tick: int, rtt_ticks: int) -> int
func set_jitter(jitter_ticks: float) -> void
func on_snapshot(input_ack_tick: int, input_margin: int) -> void
func next_steps(predicted_tick: int) -> int
func get_target_margin() -> int
func get_window_min() -> int        # NO_MARGIN if the window is empty

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
func sample(render_time: float) -> EntityRecord     # null if there are no samples
func get_newest_tick() -> int

# remote_world.gd
class_name RemoteWorld extends Node3D
func setup(clock: InterpolationClock) -> void
func on_spawn(msg: NetMessages.EntitySpawn) -> void
func on_despawn(msg: NetMessages.EntityDespawn) -> void
func on_snapshot(snapshot: NetMessages.Snapshot) -> void
func get_view(net_id: int) -> RemotePlayerView
func get_view_count() -> int
## render_tick + fraction used in the last _process.
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
func launch(port: int, extra_args: PackedStringArray) -> int    # pid, or -1

# net_debug_overlay.gd (+ scenes/ui/net_debug_overlay.tscn)
class_name NetDebugOverlay extends CanvasLayer
func bind(client: NetClient) -> void

# realm_select.gd (+ scenes/ui/realm_select.tscn)
class_name RealmSelect extends Control
signal realm_chosen(realm: int, address: String, display_name: String)
func setup(default_address: String, default_name: String, allowed: PackedInt32Array) -> void

# bot_swarm.gd (+ scenes/client/bot_swarm.tscn)
class_name BotSwarm extends Node
## Creates config.bot_count SwarmBot nodes, one every 5 ticks, each with its own NetTransport. With --dtls-cert and --dtls-name
## (platform.md P9c) it pins the certificate once and gives it to all of them; without a name or if unreadable, it exits with 1.
func start(config: ClientConfig) -> void

# swarm_bot.gd
## Lightweight bot that neither simulates nor loads the zone. It uses real TickSync and InterpolationClock, generates
## inputs with BotBrain (guided by the position of its state in the snapshot) and acknowledges
## snapshots. CLIENT_READY goes out 1 s after connecting (P9c, READY_DELAY_TICKS).
class_name SwarmBot extends Node
func setup(index: int, config: ClientConfig, dtls: TLSOptions = null) -> void
```

### 17.6 New scenes

| Scene | Root | Script |
|---|---|---|
| `scenes/server/server_main.tscn` | `Node` "ServerMain" | `server_main.gd` |
| `scenes/client/online_main.tscn` | `Node` "OnlineMain" | `online_main.gd` |
| `scenes/client/bot_swarm.tscn` | `Node` "BotSwarm" | `bot_swarm.gd` |
| `scenes/ui/realm_select.tscn` | `Control` | `realm_select.gd` |
| `scenes/ui/net_debug_overlay.tscn` | `CanvasLayer` | `net_debug_overlay.gd` |

Remote players reuse `scenes/characters/player_character.tscn`.

### 17.7 Existing files that change

- **`scripts/shared/player_state.gd`:** `to_f32()` and `equals_exact()`.
- **`scripts/shared/player_character.gd`:** yaw rounded in the setter and `events_enabled`. The
  phase 1 tests must keep passing.
- **`scripts/client/local_player_controller.gd`.** The sandbox does not change behavior:
  `input_generated`, `get_input_history()` and `get_tick()` are kept.
  ```gdscript
  ## true (sandbox): advances one tick per physics step as now. false: ClientPrediction advances it.
  var auto_step: bool = true
  ## Device, demo or bot, plus the accumulated presses; quantized; emits input_generated.
  ## It does not simulate.
  func build_input(tick: int) -> PlayerInput
  ## On ticks with no step: stores the just_pressed events for the next build_input().
  func accumulate_presses() -> void
  ## Inputs come from brain.next_input(tick, position, yaw).
  func set_bot(brain: BotBrain) -> void
  ```
- **`scripts/boot.gd`:** the modes of [1.2](#12-startup-modes). It fills `ServerMain.config`
  with `from_args()` and switches to the server scene; for the client it instantiates
  `scenes/client/client_launcher.tscn`, whose `ClientLauncher` (`scripts/client/client_launcher.gd`)
  fills `OnlineMain.config`, `BotSwarm.config` or the static variables of `ClientMain` and switches
  to the corresponding scene.
- **`project.godot`:** explicit `physics/common/physics_ticks_per_second=60`. The art workstream
  also touches it: it must be merged, not overwritten.
- **`tests/test_architecture.gd`:** the rules from [16](#architecture-test_architecture-extended)
  and the list of mandatory `net/` scripts.
- **`CLAUDE.md`:** one line with the rule "`scripts/server/` and `scripts/client/` do not depend on
  each other".

### 17.8 New tests and tools

- **`tests/net_harness.gd`** (`class_name NetHarness extends RefCounted`):
  ```gdscript
  static func free_udp_port(start: int = 24700) -> int
  static func make_world_viewport(parent: Node, world_scene_path: String) -> SubViewport  # own_world_3d
  static func start_server(viewport: SubViewport, config: ServerConfig) -> ZoneServer
  static func start_bot(viewport: SubViewport, port: int, realm: int, seed: int,
  		net_sim_spec: String = "") -> NetClient
  static func launch_process(user_args: PackedStringArray, log_name: String) -> int
  static func read_report(path: String) -> Dictionary
  # Added after the phase 2 review (A1, A5, A7):
  static func first_port_for(pid: int) -> int             # port slot of each test process
  static func get_build_dir() -> String                   # build/<pid>/, created; deletes those of dead processes
  static func build_path(file_name: String) -> String     # a file inside build/<pid>/
  static func clean_stale_build_dirs() -> int
  static func launch_script(script_path: String, user_args: PackedStringArray, log_name: String) -> int
  static func error_lines(log_path: String) -> PackedStringArray  # ERROR / SCRIPT ERROR lines of a log
  ```
  `tests/process_probe.gd` is the helper process of `launch_script` (it is not a test).
- **Tests:** `test_net_messages.gd`, `test_input_queue.gd`, `test_tick_sync.gd`,
  `test_interpolation_clock.gd`, `test_remote_interpolator.gd`, `test_state_history.gd`,
  `test_net_sim.gd`, `test_snapshot_builder.gd`, `test_rate_limiter.gd`, `test_server_auth.gd`,
  `test_prediction.gd`, `test_net_loopback.gd` and `test_net_processes.gd`.
- **Tools:** `tools/compare_state_logs.gd` and `tools/load_test.gd`, both `SceneTree`
  scripts. The computation of the load summary that needs no processes (the measurement window for
  substituted inputs) is in `tools/load_test_summary.gd` (`LoadTestSummary`), and
  `tests/test_load_test.gd` loads the tool and tests it.

---

## 18. Implementation order

1. **M1, pure pieces.** Packages A and B, plus the unit tests of C and D: `InputQueue`,
   `SnapshotBuilder`, `StateHistory`, `TickSync`, `InterpolationClock`, `RemoteInterpolator`.
   Everything with tests, without a network.
2. **M2, connect and see each other.** `NetTransport`, the handshake, `ZoneServer` with spawns, removals and
   snapshots, `RemoteWorld` and `OnlineMain`, with `test_net_loopback` a and b.
3. **M3, prediction.** `ClientPrediction`, `CorrectionSmoother` and `TickSync` integrated, with
   `test_prediction` and `test_net_loopback` c and e.
4. **M4, real conditions.** `NetSim` in the integrations (`test_net_loopback` d), F3 and F4
   overlay, `--local`, `RealmSelect`.
5. **M5, processes, load and security.** Bots, `test_net_processes`, `BotSwarm`, `load_test`,
   limiters, warnings and cheating bot. Measurements are recorded for Eldrun.

---

## 19. Open risks

- **Terrain3D.** The server and the client must generate the same collision: full mode on both
  sides. The dynamic mode depends on the camera and, chunked differently, could change the
  last bit of the queries.
  - Headless startup is already pinned down by `tests/test_terrain3d_headless.gd`.
  - `test_net_processes` validates it with the real zone.
- **Jolt across processes.** It is the same binary, but the server has other characters'
  bodies in its physics space and the client does not. They are not in the mask;
  `test_net_processes` confirms it.
- **Across platforms.** Jolt is not compiled in cross-platform deterministic mode in Godot, and
  libm changes. With a Linux server and Windows clients there will be last-bit differences, which
  reconciliation absorbs. Their frequency will be measured once there is a Linux server.
- **CPU in GDScript.** It is not yet known how much `simulate()` costs per character on the server.
  It is measured in M5 before fixing the size of battles.
- **Contract with the art workstream:**
  - visual-only things hang from `Visual`, and `CameraTarget` exists;
  - animation reads `velocity`, `grounded`, `yaw` and the `jumped`/`landed` signals;
  - `zones.gd` offers what `NetZones` asks for.

  If any of this changes, only `ServerMain`, `RemotePlayerView`,
  `CorrectionSmoother` or `NetZones` need to be touched.
- **Vertical quantization:** more than enough (±5.24 km). The horizontal one requires zones centered on the
  origin.

---

## Annex: corrections to the proposals

| Problem found by the judges | Correction in this design |
|---|---|
| Snapshot over 1200 B with 64 visible players (A and C) | Budget with a priority accumulator (57 records per packet in phase 2, 52 since phase 3, 50 since protocol 6); guarantee of being sent at least every ⌈N/C⌉ snapshots |
| `input_ack_tick` stuck after a substitution (A) | `max(contiguous received, last consumed)` |
| Reconciliation with `is_close_to`, without `prev_buttons` (A) | `equals_exact` over `encode()`, made possible by the f32 yaw |
| Yaw in f64 versus f32 on the wire (B and C did not see it) | Rounding in the `PlayerCharacter.yaw` setter |
| Neutral input with buttons at 0 (A) and `synthesized()` only with SPRINT/BLOCK (C): invented edges | The substitute repeats the full mask; after 6 ticks it only sets `move = 0` |
| Endless repetition of the last input (B) | Movement to 0 after 6 ticks without real inputs |
| Fixed margin band and ambiguous measurement (A) | Target according to jitter, minimum over a 15-sample window, first copies only, substitutions separate |
| Control loop with overshoot (B) | Wait until the ack after the adjustment and proportional debt |
| Hard resync backwards (A) | Forward only; if ahead, it falls back little by little |
| Presses lost on 0-step ticks (A, B) | `accumulate_presses()` and `build_input()` |
| Smoothing offset in world space (A) | `basis.inverse() * offset` recomputed every tick |
| `reset_physics_interpolation()` on every correction (B) | Offset on the physics tick; reset only when teleporting |
| 15-tick rewind cap that included the interpolation delay (A) | 24 absolute ticks plus a per-session cap with the RTT, the lead and the declared delay |
| `view_delay_q` per batch (A) | `view_offset_q` per input |
| Half-tick bias when drawing remote players (A) | Remote players in `_process` with physics interpolation off, at `render_tick + fraction` |
| One-tick offset on spawn (A) | Spawn after simulating tick S, with the state "after S"; first simulation at S+1 |
| Undefined startup (B) | P0 with two RTT measurements and a neutral advance identical to the server's substitution |
| `CLIENT_READY` or PING right after `complete_auth()` give `ERR_BUG` (A, C) | Nothing through `send_bytes` until `peer_connected` |
| `--local` slow to detect that there is no server (A) and orphaned with `OS.kill` (C) | Lock file with pid, short ENet timeout and `--idle-quit` |
| `low_processor_usage_mode_sleep_usec = 1000` (A) and false justification of `max_fps` (B, C) | `max_fps = 120`, with the measured reason |
| All snapshots on the same tick (A) | Staggered by `net_id` |
| `StateHistory` with one object per entity and tick (A) | Packed arrays per track, without allocating memory when recording |
| `CUSTOM_CHANNELS = 4` with 3 channels in use (A) | 3 |
| Underestimated upstream (A: 6 KB/s) | 5.5–7.9 KB/s with headers |
| `NetSim` and conditioners with wall clock (B, C) | Everything in ticks and seeded; it also delays authentication |
| ENet RTT of 500 ms before the first ack (B) | Startup uses RTT measured in ticks; the ENet one is only displayed |
| 0-based realm without NONE (C) | `Realm.NONE = 0` |
| `BotBrain` on the client (C) | In `scripts/shared/`, usable by the server's fake players |
| Excess scope in phase 2: tickets, DTLS, AuthProviders (C) | Only the `AuthProvider` interface and `DevAuthProvider`; ticket and DTLS in phases 5–6, with the slot reserved |
| Minimal security (A, B) | Per-peer limiter, warnings, per-IP cap, button mask and cheating bot in the tests |
