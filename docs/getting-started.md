# Getting started

How to build, run, test and operate every part of Eldmark: the client, the dedicated server, bots and load tests, the Go platform service, the test suite, continuous integration and exports. For the big picture, read the [README](../README.md) and [architecture.md](architecture.md) first.

Notes on language: the in-game interface, chat commands and the runtime log lines of the game are in Spanish for now (an English localization is planned). Quoted UI strings below keep the Spanish text, with an English gloss where it helps.

Contents:

1. [Requirements](#requirements)
2. [Running Godot from the terminal](#running-godot-from-the-terminal)
3. [Offline sandbox and startup options](#offline-sandbox-and-startup-options)
4. [Player settings (F10)](#player-settings-f10)
5. [Zones](#zones)
6. [Dedicated server](#dedicated-server)
7. [Network client](#network-client)
8. [Bots, swarms and cheating bots](#bots-swarms-and-cheating-bots)
9. [State logs and comparison](#state-logs-and-comparison)
10. [Load tests](#load-tests)
11. [Combat balance pass](#combat-balance-pass)
12. [Platform service (Go)](#platform-service-go)
13. [Running the tests](#running-the-tests)
14. [Continuous integration](#continuous-integration)
15. [Quality capture bench](#quality-capture-bench)
16. [Interface and audio notes](#interface-and-audio-notes)
17. [Export](#export)

## Requirements

- Godot 4.7 (standard build, GDScript). CI uses 4.7.2-stable.
- Git. Models, textures, audio, terrain region files and native binaries are normal files in the repository (see `.gitattributes`); Git LFS is not used.
- For the platform service: Go 1.26 (1.26.10, `GOTOOLCHAIN=local`) and PostgreSQL 16 binaries.
- For the capture bench: Python 3 with Pillow, and a machine with a window and a GPU.

```bash
git clone https://github.com/Luisbh-dev/Eldmark
cd Eldmark
```

Open `project.godot` in Godot and press F5 to start the offline sandbox. Controls are listed in the [README](../README.md#controls).

A few keys are easy to miss: **M** opens the map window (mouse wheel zooms, dragging pans, a double click shows the whole zone), **=** and **-** (the two keys right of 0 on a US layout) zoom the minimap, and holding **Alt** frees the cursor and also shows the names of the markers in the world. The marker of the current objective is always visible; the others appear with their name only near the crosshair or while Alt is held.

## Running Godot from the terminal

Every command below assumes `godot` is the Godot 4.7 **console** executable. On Windows, a winget install may not put it on the `PATH`; the console build is at:

```
%LOCALAPPDATA%\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64_console.exe
```

Useful basics:

```bash
# Import resources and validate the project (run once after cloning or after changing assets)
godot --headless --path . --import

# Run the main scene without a window for 120 frames (quick smoke test)
godot --headless --path . --quit-after 120
```

Arguments for the game itself go after `--`. Screenshots and other temporary files can go in `build/`, which Git does not track (Godot imports whatever you leave there, so for `.csv` files see the note below).

## Offline sandbox and startup options

With no arguments, the game starts the offline sandbox (a client with no network) in the Vado Gris. From a command line:

```bash
# Play as Solmarch in the Vado Gris
godot --path . -- --realm=solmarch

# Scripted demo in the Vado Gris (about 33 s), one PNG every 90 ticks, then the review cameras, then exit
godot --path . -- --zone=vado_gris --demo --shots=C:/absolute/path/captures --quit-after-demo

# The phase-1 movement test circuit (about 10 s)
godot --path . -- --zone=test_world --demo --quit-after-demo
```

Options (after `--`):

- `--zone=<id>`: zone to load (`vado_gris` by default, or `test_world`).
- `--realm=<realm>`: the player's realm (`vardheim` by default, or `solmarch`); it decides the spawn point.
- `--demo`: the character and camera follow a script instead of the keyboard and mouse. In the Vado Gris it walks the bridge route of its realm: leaves camp, sprints and jumps along the road, crosses the bridge, jumps twice at the foot of the fort, side-steps, circles the palisade to the gate (facing the ford) and the camera makes a full turn. In `test_world` it is the fixed phase-1 script. Both finish with about five seconds of combat (a three-hit light combo, a charged heavy attack, a block and a dodge) and the demo prints the actions it performed, for example `Demo, acciones de combate: LIGHT x4, CHARGE x1, HEAVY x1, BLOCK x1, DODGE x1` (the fourth light press is the one that turns into the charge).
- `--shots=<absolute folder>`: during the demo, saves `shot_000.png`, `shot_001.png`... and, at the end, one HUD-less capture from each review camera of the zone (`zona_<name>.png`, markers of the `screenshot_points` group). It needs a window; in headless mode it is skipped.
- `--quit-after-demo`: close the game when the demo ends.
- `--server`: dedicated server of one zone (see [Dedicated server](#dedicated-server)).
- `--connect=<host>[:<port>]`, `--local` and `--bot`: network client (see [Network client](#network-client)).
- `--bots=N`: swarm of N lightweight clients for load tests (see [Bots](#bots-swarms-and-cheating-bots)).
- `--title` and `--platform=<url>`: the title screen with account login. An exported build with no arguments also opens it; from the editor, no arguments still gives the sandbox.
- `--locale=<en|es|pseudo>`: interface language for this run, never saved and stronger than the saved setting. `pseudo` is English with accents, padding and `¦…¦` marks, for looking for cut texts ([localization.md](localization.md)). `--l10n-strict` (debug) logs every lookup that has no Spanish entry.

In the sandbox the main scene (`scenes/boot.tscn`, script `scripts/boot.gd`) reads the arguments and decides the mode; `--server` has priority over everything else and any other case is resolved by the client launcher.

## Player settings (F10)

**F10** opens and closes the settings window, both in the offline sandbox and in the network client (Esc also closes it; while it is open the cursor is free). It has four tabs:

| Tab | Settings |
|---|---|
| Graphics | window mode (windowed, borderless fullscreen or exclusive), resolution (windowed only), vsync, FPS limit, render scale, shadows (off, low, medium, high), grass distance (0 removes it) and anti-aliasing (none, FXAA, MSAA 2x or 4x) |
| Audio | volume of each bus: Master, Music, Effects, Ambience, Interface and Voices |
| Camera | mouse sensitivity, invert the vertical axis, field of view and default shoulder |
| Interface | language (Automatic, English or Español; Automatic is Spanish for now), damage numbers, nameplates, game hints and the controls help line (F1) |

Changes apply live, are saved when the window closes to `user://settings.cfg` (on Linux `~/.local/share/godot/app_userdata/Eldmark/`, on Windows `%APPDATA%\Godot\app_userdata\Eldmark\`) and are applied at startup. Only what the player touched is written, so a client without a `settings.cfg` starts exactly as before, with the Vado Gris, the window and the anti-aliasing of the project. "Restore tab" (Spanish: "Restaurar pestaña") and "Restore all" ("Restaurar todo") bring back the defaults of every setting except the language and remove those keys from the file. The file is plain text (`[graphics]`, `[audio]`, `[camera]`, `[interface]`) and can be edited by hand; anything invalid is ignored and the default stays. It is implemented in `ClientSettings` (`scripts/client/ui/client_settings.gd`, which also documents every setting) and `SettingsMenu`.

Other client debug keys: **F3** toggles the debug panels and **F4** the network ghost (see [Network debugging](#network-debugging-f3-and-f4)).

## Zones

The world is split into independent zones (see [world.md](world.md)). The zone registry is `scripts/shared/zones.gd` (`Zones`), shared by client and server:

| Zone | Scene | What it is |
|---|---|---|
| `vado_gris` (default) | `scenes/world/zones/vado_gris/vado_gris.tscn` | The phase-4 frontier: a capturable fort between Vardheim (north) and Solmarch (south). See [zones/vado_gris.md](zones/vado_gris.md). Admits Vardheim and Solmarch; 40 players by default |
| `test_world` | `scenes/world/test_world.tscn` | Movement and camera test circuit of phase 1; admits all three realms |

The player spawns at the first spawn point of the chosen realm (markers in the `spawn_points` group carry a `realm` metadata value); if the zone has no point for that realm, at the first point of the zone. Zones have a PvP mode: in a `SAFE` zone enemy realms cannot damage each other, in an `RVR` zone they can (both registered zones are `RVR`), and realm camps are safe areas for their own realm only.

## Dedicated server

One process of the same project, always with `--headless`, serves one zone on a UDP port (design in [networking.md](networking.md)). For example, the Vado Gris with 8 fake players for 30 s and a JSON report on exit:

```bash
godot --headless --path . --log-file build/server.log -- --server --zone=vado_gris \
    --port=24600 --fake-players=8 --quit-after-ticks=1800 --report=build/report.json
```

Options (after `--`):

- `--server`, `--zone=<id>`, `--port=24600`, `--max-players=64` (the Vado Gris defaults to 40, the measured per-battle limit), `--max-per-ip=4`.
- `--idle-quit=<s>`: exit after that many seconds with no players.
- `--fake-players=N`: network-less players for tests and load, with `--fake-layout=cluster|spread` (all clustered within 60 m, or spread over the zone) and `--fake-churn=<ticks>` (every so many ticks the oldest leaves and a new one joins; 60 means one join and one leave per second). `--fake-brain=combat`, `--fake-center=x,z`, `--fake-archers=N` and `--fake-loadout=` give fake players combat behavior.
- `--no-npcs` and `--no-dummies`: start the zone without NPCs or training dummies.
- `--debug-commands`: accept the debug teleport of clients.
- `--dev-lock`: write `user://dev_server.json` so that `--local` reuses the server; `--dev-lock-path=<path>` writes it elsewhere, and `--local --dev-lock-path=<path>` reads it from there.
- `--quit-after-ticks=N`.
- `--report=<path.json>`: a JSON report at exit.
- `--state-log=<path.txt>`: `tick,net_id,substituted,state` for every tick and player (see [State logs](#state-logs-and-comparison)).
- `--net-sim=rtt=120,jitter=20,loss=5,dup=0,seed=1`: simulate a bad network.
- `--battle-log`, `--combat-log`: extra logs of fortress battles and combat.
- `--console`: read commands from standard input, including the progression commands (`item_give`, `xp_add`, `inv_show`, ... see [progression.md](progression.md) section 10).

The log records joins, leaves, kicks and, every 10 s, the tick duration and bandwidth. The report contains, beside the counters, the p50/p99/max of the tick and of every section, the microseconds of each `simulate()`, and the size and cost of building snapshots. The exit code is 0 on a normal shutdown and 1 if it cannot start (unknown zone, port in use).

**With the platform service** ([below](#platform-service-go), [platform.md](platform.md) section 8) the zone registers itself with the internal API and only admits clients holding a ticket:

- `--platform=<internal url>`: without it, every client enters with a throwaway character that is lost on exit ([progression.md](progression.md) section 9.4).
- `--world=<id>` (1) and `--channel=<n>` (0), `--public-address=<host>[:<port>]` (where clients connect), `--save-interval=<s>` (checkpoint of saves, 60) and `--replace` (replace a live instance of the same zone and channel).
- The zone token and the ticket keys go in `ELDMARK_ZONE_TOKEN` and `ELDMARK_TICKET_KEYS`, or in the files named by `ELDMARK_ZONE_TOKEN_FILE` and `ELDMARK_TICKET_KEYS_FILE`. `platform/deploy/dev.sh` prepares them and writes the whole command.
- With a platform, the zone exits with 1 if it cannot register and with 3 if the platform closes the instance.

**DTLS.** With `--dtls-cert=<pem> --dtls-key=<pem>` (with or without a platform; [platform.md](platform.md) section 10.2) the zone opens the port over DTLS and, with a platform, sends the certificate and its CN in the registration so the client receives and pins it. The certificate is self-signed, with a CN, and the key has no passphrase (EC P-256 makes the handshake cheaper; the OpenSSL command is in `platform/deploy/docker-compose.yml`). If either file is missing, unreadable, has no CN or the key does not match, the zone exits with 1. Without a platform, a client or swarm connects with `--dtls-cert=<pem> --dtls-name=<cn>`. In staging and production the platform does not register a zone without a certificate.

**Server self-defense** ([networking.md](networking.md) section 12): the server limits packets per tick and per second and bytes per peer, counts a warning for every malformed packet, packet of an unexpected type for the session state, or packet above the rate, and kicks with a NOTICE any peer that reaches 50 warnings in 600 ticks. It also accepts at most `--max-per-ip` connections per IP (except from loopback).

## Network client

With a server already running, `--connect` connects to it; the zone is dictated by the server. A bot is the same client without camera or HUD, driven by a deterministic `BotBrain`.

```bash
# Play against a local server
godot --path . -- --connect=127.0.0.1 --realm=solmarch --name=Ana

# A headless bot: 25 s of play, a JSON report at the end and a state log
godot --headless --path . -- --bot --connect=127.0.0.1:24600 --bot-seed=3 \
    --quit-after-ticks=1500 --report=build/bot_3.json --state-log=build/bot_3.txt
```

Options (after `--`): `--connect=<host>[:<port>]`, `--port=<port>` (wins over the one in `--connect`), `--realm=<realm>` (without it, a windowed client shows the realm-selection screen; a bot or windowless client joins as Vardheim, with a warning), `--name=<name>` (by default "Jugador" plus four random letters), `--local`, `--bot`, `--bot-seed=N`, `--bot-brain=`, `--loadout=`, `--bot-cheat=version|future|dupes|garbage|flood` (cheating bot, below), `--net-sim=rtt=120,jitter=20,loss=5,dup=0,seed=1`, `--quit-after-ticks=N` (local physics ticks since the session starts, counting the connection and the zone load; during the last ticks the bot stands still), `--report=<path.json>` (exact matches, explained and unexplained differences, resets and resyncs, TickSync adjustments and final state) and `--state-log=<path.txt>` (`server_tick,predicted,server` in hex per snapshot). With `--quit-after-ticks` the exit code is 0 if the bot got to play and left on its own, and 1 if it was rejected, disconnected or never entered the zone.

Paths for `--report` and `--state-log` may be inside `build/`, but with `--state-log` inside the project use the `.txt` extension: the Godot importer turns `.csv` files into translations.

### One command: `--local`

```bash
godot --path . -- --local --realm=vardheim --name=Ana
```

`--local` needs no server: it reads `user://dev_server.json` (`{pid, port}`, written by a server started with `--dev-lock`) and, if that process is alive, connects to it. Otherwise it launches the server as a separate process (`--headless --server --port=24600 --idle-quit=30 --dev-lock`, logging to `user://logs/dev_server.log`) and retries connecting for 10 s with a short ENet timeout (1 s). Several windows started with `--local` therefore share one server. The server exits on its own after 30 s without players, and the client never closes it: if the client crashes the server is not orphaned. `--zone=<id>`, `--debug-commands`, `--fake-players=N` and `--max-players=N` are forwarded to the server it launches (an already running server is used as is). `--port=<port>` picks the port of the launched server.

### Realm selection

A windowed client that starts without `--realm` opens the selection screen: three buttons (Vardheim, Solmarch, Askarra; realms the zone does not admit are disabled), the server address fields (`host` or `host:port`; not editable with `--local`) and the character name, and "Entrar" (enter). The name is validated by the naming rules (3 to 16 letters, no spaces or digits, starting with a capital) and the reason is shown next to the field before connecting; while anything is invalid, "Entrar" stays disabled. After a rejection, a connection failure or a disconnect, the client returns to this screen with the reason as a notice and can retry without closing the game.

### Client with an account (`--title`, `--bot --platform`)

Against the platform ([platform.md](platform.md) section 13), the client starts on the title screen: login, character selection and creation, and "Entrar" requests a ticket and connects to the zone the platform says. Without `--platform` it uses the project setting `eldmark/platform/url` (`http://127.0.0.1:24680`). Only `https://` is accepted or, towards this machine, `http://`; `eldmark/platform/ca_cert` pins a self-signed certificate (staging).

```bash
# The title screen against the local platform
godot --path . -- --title --platform=http://127.0.0.1:24680

# A bot with an account: logs in, creates "Probador" if it does not exist, requests a ticket and enters
godot --headless --path . -- --bot --platform=http://127.0.0.1:24680 --login=bot@eldmark.test \
    --password-file=build/bot.pw --character=Probador --realm=solmarch --quit-after-ticks=1500 \
    --report=build/bot.json
```

The bot's password always goes in a file (`--password-file`), never on the command line. Without `--login` or `--password-file`, or if the account fails (credentials, `character_busy` after 30 s, `zone_unavailable`), the bot exits with code 1 and the platform `code` in the report (`platform.code`). `--world=N` picks the world (1). `--bots` does not accept `--platform`.

### Network debugging (F3 and F4)

In the network client, **F3** shows and hides the HUD debug panel (left, the same one as the sandbox) and the network panel (right) together; both start hidden. The network panel shows: ENet RTT (without the network simulator) and in ticks, ENet loss, upload and download KB/s, `input_margin` (last and minimum of the TickSync window) and target margin, TickSync adjustments, substitutions and corrections (with their per-minute rate once there are 10 s of history), last and maximum correction, resimulated ticks, interpolation delay, jitter, visible entities and average bytes per snapshot. **F4** draws a translucent ghost at the position of the last own state the server sent, and a mark on every non-interpolated sample of the remote players. The sandbox is unchanged: F3 still toggles only its own panel, which starts visible.

## Bots, swarms and cheating bots

### Swarm (`--bots=N`)

`--bots=N` starts one process with N lightweight clients (`BotSwarm` and `SwarmBot`) that do not load the zone or simulate: they join one every 5 ticks, predict with the real `TickSync`, walk driven by their `BotBrain` and acknowledge snapshots. They load the server without the load generator becoming the bottleneck.

```bash
godot --headless --path . -- --bots=32 --connect=127.0.0.1:24600 --realm=vardheim \
    --bot-seed=1000 --quit-after-ticks=3600 --report=build/swarm.json
```

With `--quit-at-server-tick=N` the swarm leaves when any of its bots receives a snapshot of server tick N, even if the server runs slower than real time (used by `tools/load_test.gd`). Each bot is named "Bot" plus four letters derived from `--bot-seed` plus its index (or, with `--bot-names=Ana,Beto,...`, by the valid names of that list in order, as the quality bench does), so two swarms against the same server need different seeds. Without `--realm` they split between Vardheim and Solmarch. The report has the upload and download bytes of each client, snapshots received and their average size. Exit code 0 if all were playing at the end and 1 if any was rejected or dropped. Against a DTLS zone, use `--dtls-cert=<pem> --dtls-name=<cn>` (without the name, or with an unreadable certificate, it exits with 1 without connecting in the clear).

### Cheating bot (`--bot-cheat`)

A `--bot` with `--bot-cheat=<mode>` cheats while still predicting with its honest inputs. It checks that the server does not fall for it ([networking.md](networking.md) section 12):

| Mode | What it does | What must happen |
|---|---|---|
| `version` | HELLO with another protocol version | REJECT for version |
| `future` | input batches with ticks far ahead of the window | discarded and counted; no effect or advantage |
| `dupes` | different copies of the same inputs | the first copy wins |
| `garbage` | random packets on the input and reliable channels | warnings and a kick |
| `flood` | more packets per tick than the limiters allow | rate warnings and a kick |

## State logs and comparison

With `--state-log` the server writes every player's state at every tick (`tick,net_id,substituted,state`) and the bot writes the state it predicted and the one that arrived with each snapshot (`server_tick,predicted,server`). `tools/compare_state_logs.gd` cross-checks them and classifies every bot snapshot: bit-exact match, explained difference (the server substituted an input) or unexplained difference (a determinism bug). It exits with code 1 if any is unexplained:

```bash
godot --headless --path . -s res://tools/compare_state_logs.gd -- build/server.txt build/bot.txt [net_id]
```

## Load tests

`tools/load_test.gd` launches a server with fake players and `--bots` processes, waits for them to finish and summarizes what the server measures: p50/p99/max tick per section, microseconds of `simulate()` per character, snapshot size, KB/s per client and substituted inputs (for the whole session and for the measurement window, without the warm-up), against the phase-2 criteria (with 64 clustered players and 100 ms RTT: p99 tick below 8 ms, 37 KB/s per client, under 1 % substituted in the window). Scenarios: `cluster` (clustered within 60 m), `spread` and `churn` (joins and leaves at one per second). It is documented in the script header:

```bash
# One scenario: 64 clustered fakes and 10 real clients
godot --headless --path . -s res://tools/load_test.gd -- --scenario=cluster --fakes=64 --bots=10
# The phase-2 battery: 64, 128 and 256 fake players and the criterion at 100 ms RTT, 120 s of
# measurement each (about 25 minutes; keep the machine free)
godot --headless --path . -s res://tools/load_test.gd -- --matrix
```

Reports are written to `build/load_test/` (`summary.txt` and `summary.json`).

With `--dtls` the server and swarms use DTLS (with the test certificate, or with `--dtls-cert`, `--dtls-key` and `--dtls-name`). `--dtls-compare` runs the same scenario without and with DTLS, alternating (by default 64 real bots clustered in two swarms, 60 s, `--repeat=2`), and reports how much each figure rises and the criterion (the p99 tick may not rise more than 10 %). Results are in [networking.md](networking.md) section 14:

```bash
godot --headless --path . -s res://tools/load_test.gd -- --dtls-compare --repeat=3
```

With combat, `--scenario=brawl` gathers the fakes with the combat brain (`--fake-brain=combat`, in a ring around `--fake-center=x,z`) and real fighting bots (`--bot-brain=combat`) and also measures the combat sections (rewound hits, events), the microseconds per hit check and the KB/s of events. `--brawl` runs the battery of 32, 64 and 128 combatants (60 s each, about 6 minutes, reports in `build/load_test/`; change the folder with `--out`). Results and the per-battle player limit are in [networking.md](networking.md) section 14 (currently 40 for the Vado Gris with the full ability kit).

```bash
godot --headless --path . -s res://tools/load_test.gd -- --brawl
godot --headless --path . -s res://tools/load_test.gd -- --scenario=brawl --fakes=54 --bots=10
```

For fort sieges, `tools/war/siege_battle.gd` and `siege_runner.gd` run siege bots against the fort; see [fortress.md](fortress.md) section 7.

## Combat balance pass

`tools/combat_balance.gd` builds a network-less server on `test_world`, advances it tick by tick by hand and measures with it the DPS against the dummy, the time to kill (TTK) of a perfect attacker, duels between combat bots and 2v2 and 5v5 fights, in about 20 s and with the same result on any machine (it uses no clock or network). The figures and decisions are in [combat.md](combat.md#12-first-balance-pass-cmb-29), section 12.

```bash
godot --headless --path . -s res://tools/combat_balance.gd -- --duels=60 --seconds=30 --out=build/combat_balance.json
```

## Platform service (Go)

`platform/` is the accounts, characters and persistence service, in Go 1.26 on PostgreSQL 16 (design in [platform.md](platform.md); what is implemented, in its section 19). Godot does not scan or export it (`platform/.gdignore`). It is configured with `ELDMARK_*` environment variables (section 2.3 of the design).

```bash
cd platform
go test ./...                                   # starts an ephemeral PostgreSQL with initdb (no Docker)
go run ./cmd/eldmark-platform migrate status    # or migrate up, migrate down N (dev and test only)
go run ./cmd/eldmark-platform serve             # public API on :24680 and internal API on :24681
```

The tests need the PostgreSQL binaries (`ELDMARK_PG_BIN`, `pg_config` or `/usr/lib/postgresql/*/bin`; if absent they are skipped) or a server in `ELDMARK_TEST_DATABASE_URL`. As root, `initdb` runs through `runuser -u postgres`, which must be able to enter `TMPDIR`.

The end-to-end tests (`platform/e2e`, [platform.md](platform.md) P10) carry the `e2e` build tag and start the platform inside the test process against a `test_world` zone and real Godot bots; without `ELDMARK_GODOT` they are skipped. They import the project at start and take under a minute:

```bash
cd platform
ELDMARK_GODOT=<path to Godot 4.7.2> go test -tags e2e -count=1 -v ./e2e
# ELDMARK_E2E_ARTIFACTS=<folder> keeps the platform, zone and bot logs
```

In development (`ELDMARK_MAIL=log`, the default) account emails are not sent: they go to the `outbound_mail` table and to the log with the complete link (`/verify`, `/reset` or `/revert` over `ELDMARK_PUBLIC_URL`). The legal texts accepted at registration are the drafts in `platform/legal/`, embedded in the binary (`ELDMARK_LEGAL_DIR` replaces them with those of another folder). They are placeholders for development, not legal advice.

Characters (`/v1/worlds/{w}/characters`, `POST /v1/characters/{id}/enter`) keep their progress in PostgreSQL (the `0010_progress` tables and `platform/internal/progress`, [progression.md](progression.md) P7): on creation the race, appearance and template are validated with the exported rules, and every zone save passes the S1 to S8 checks ([progression.md](progression.md) section 13.3). `enter` only gives a ticket if a live zone instance admits the realm. The naming rules and the default minimum protocol come from `platform/internal/gamedata/progression_rules.json`, which is generated from Godot, like the races, the appearance (`data/characters/`), the level curve (`data/progression/`), the items (`data/items/`), starter templates, currencies, reasons, containers and maximum health. After changing any of that data, export it again (the test `test_progression_rules_export.gd` warns when it is stale):

```bash
godot --headless --path . -s res://tools/progression/export_rules.gd             # write it
godot --headless --path . -s res://tools/progression/export_rules.gd -- --check  # only compare
```

The internal API (`/internal/v1`, on `ELDMARK_INTERNAL_ADDR`, for zones only) requires the token of a zone deployment on every request: `ELDMARK_ZONE_TOKENS` stores its SHA-256 with the scope `<world>:<zone>:<channel>`. To try it by hand with the token `secret` for `1:vado_gris:0` (`protocol_version` is the one in `progression_rules.json`):

```bash
export ELDMARK_ZONE_TOKENS="1:vado_gris:0:$(printf %s secret | sha256sum | cut -d' ' -f1)"
curl -s -H 'Authorization: Bearer secret' -d '{"world_id": 1, "zone_id": "vado_gris", "channel": 0,
  "public_host": "127.0.0.1", "public_port": 24600, "realms": [1, 2], "build_id": "dev", "protocol_version": 7,
  "record_format": 1, "max_players": 64, "dtls_cert_pem": null, "dtls_name": null, "replace": false}' \
  http://127.0.0.1:24681/internal/v1/zone-instances
```

An instance that stops sending heartbeats for 3 x `ELDMARK_HEARTBEAT_S` is considered lost and its characters are released. `ELDMARK_LEASE_TTL_S` must exceed 3 x `ELDMARK_HEARTBEAT_S` + min(5, `ELDMARK_HEARTBEAT_S`) seconds (with 5 and 30, the defaults, there is room to spare); otherwise `serve` does not start.

Every hour, `serve` purges accounts and characters whose grace period has expired and deletes what has expired according to the retention table in [platform.md](platform.md) section 11.1 (chat after 30 days, audit and closed reports after a year, the ledger of a purged character after a year...). The data export of an account (`POST /v1/account/export`) also includes the progress of its characters.

Moderation and staff accounts go through the `admin` command, with the same configuration as `serve`. Every command takes `--actor`, the email of an `admin` account (or `moderator` for read-only ones), and leaves a row in the audit log (`audit_log`, without emails or names); the first `admin` account is created with `bootstrap`. The password of new accounts is read from a file, never from the command line:

```bash
go run ./cmd/eldmark-platform admin bootstrap boss@eldmark.test --password-file pass.txt
go run ./cmd/eldmark-platform admin --actor boss@eldmark.test create-account test@eldmark.test --password-file pass.txt
go run ./cmd/eldmark-platform admin --actor boss@eldmark.test set-role gm@eldmark.test gm     # revokes its sessions
go run ./cmd/eldmark-platform admin --actor boss@eldmark.test reports list
go run ./cmd/eldmark-platform admin --actor boss@eldmark.test chat --character Bran --from 2026-11-01 --to 2026-11-02
go run ./cmd/eldmark-platform admin --actor boss@eldmark.test sanction add Bran mute --duration 24h --reason "insults"
go run ./cmd/eldmark-platform admin help                                                       # all commands
```

### Local platform and deployment

`platform/deploy/dev.sh` brings up the development platform without Docker (Linux, macOS or WSL, with the PostgreSQL 16 binaries and Go): its own PostgreSQL in `build/dev_pg` (on 127.0.0.1:24682), the migrations, keys and one token per development zone (`vado_gris` and `test_world`) in `build/dev_secrets/`, an `admin@eldmark.test` account and a `prueba@eldmark.test` account (development-only passwords set in the script; never reuse them), and it writes the zone command with `--platform`. Data persists between runs:

```bash
platform/deploy/dev.sh                # prepares everything and starts serve; Ctrl-C stops serve and PostgreSQL
platform/deploy/dev.sh prepare        # the same without serve (PostgreSQL stays up; dev.sh stop stops it)
eval "$(platform/deploy/dev.sh env)"  # the variables to use eldmark-platform by hand
platform/deploy/dev.sh reset          # delete the development database, keys and accounts
```

Staging and production use `platform/deploy/docker-compose.yml` (database, platform, Caddy with Let's Encrypt HTTPS, zones and backups), a `staging.env` or `production.env` made from its `.example`, and secrets as files in `platform/deploy/secrets/` (ignored by Git). The compose header lists the commands and the secrets, and [platform.md](platform.md) sections 12 and 19.13 cover the rest. Backups: `backup.sh` (daily, with `purges.txt`), `restore_check.sh` (weekly test restore, with `reapply-purges`) and `pitr_check.sh` (point-in-time recovery); the three run locally against an ephemeral PostgreSQL or in the compose `ops` container. After restoring a real backup, and before starting `serve`: `eldmark-platform admin --actor <email> reapply-purges <backup folder>/purges.txt`.

The private keys in `tests/fixtures/dtls/` are throwaway fixtures for the DTLS tests. Never use them anywhere else.

## Running the tests

From the project root:

```bash
# Import resources and validate the project
godot --headless --path . --import

# All automated tests (exit code 0 if everything passes)
godot --headless --path . -s res://tests/run_tests.gd
# Only the tests whose name contains a text ("file::method")
godot --headless --path . -s res://tests/run_tests.gd -- --filter=replay
# Only part 2 of 4 of the test files (distributed round-robin, as in CI)
godot --headless --path . -s res://tests/run_tests.gd -- --shard=2/4
```

How it works: `tests/run_tests.gd` discovers `res://tests/test_*.gd` (each extends `TestCase`), runs every method starting with `test_` (they may use `await`) with optional `before_each()` and `after_each()`, prints PASS or FAIL per test and a summary, and exits with 0 if everything passes or 1 if anything fails. A test also fails if a script or engine error is logged while it runs (unless it calls `allow_logged_errors()`, which tolerates engine errors only). It never hangs: every phase has a timeout and there is a global timer. `--shard=K/N` runs only part K (1 to N) of the test files, distributed round-robin in alphabetical order. Before each test the runner forces the interface language to English (`L10n.force("en")`, whatever the machine or its `settings.cfg` says), turns on strict mode (a lookup with no Spanish entry in `locale/es.po` fails the test) and points `ClientSettings` to an empty temporary file; a test that checks the Spanish on purpose calls `with_locale("es")`. The tests that start client processes pass `--locale=en`.

There are 223 test files and 3,027 test methods, plus about 300 Go tests under `platform/`. Many of them start servers and clients inside a single process (each in its own `SubViewport` with its own physics world) or launch real Godot processes, so the whole suite takes several minutes on a four-core machine. Two suites can run at once on the same machine: each process picks its own port slot and writes its reports to its own `build/<pid>/` folder. Some tests also need Python with Pillow or the Go toolchain and skip themselves when it is missing.

`tests/test_architecture.gd`, part of the suite, enforces the dependency rules between `scripts/shared`, `scripts/server` and `scripts/client` ([architecture.md](architecture.md#dependency-rules)).

## Continuous integration

`.github/workflows/tests.yml` (GitHub Actions) runs on every push to `main`, on every pull request, and by hand from the Actions tab (`workflow_dispatch`). A new push to the same branch cancels the run still in progress. It has these jobs:

- **Suite K/4** (`ubuntu-latest`, four in parallel): downloads Godot 4.7.2-stable for Linux (SHA-512 checked and cached), imports the project and runs `tests/run_tests.gd -- --shard=K/4` with a 15-minute step limit. If one fails it uploads its `build/` folder (logs and reports) as the artifact `build-logs-K`.
- **Suite completa** (full suite): a single check that passes only if the four shards pass. To make a broken test block merging, mark it as a required status check in the branch protection rules; that cannot be configured from the workflow file.
- **Windows (LocalServerLauncher)**: Windows is the main development platform, and there `OS.is_process_running` only knows the process's own children, so this job runs the `LocalServerLauncher` tests (with their helper processes). The complete suite is run by hand on Windows.
- **Plataforma**: checks that no secrets are in the Git index (`tools/check_secrets.sh`) and runs `gofmt`, `go vet` and `go test` for the platform service against an ephemeral PostgreSQL, plus the deployment-script checks (backup and restore scripts, shellcheck, `docker compose config`).
- **Plataforma e2e**: the Go platform in the test process against real `test_world` zones and real Godot bots with accounts (`platform/e2e`, tag `e2e`).

The workflow and job names (`Pruebas`, `Suite completa`, `Plataforma`) are still in Spanish.

Three more files in `.github/` protect the public repository (TEC-66):

- **Security analysis** (`workflows/codeql.yml`): CodeQL for Go and for the workflow files, and `govulncheck` over `platform/`, on pushes to `main`, pull requests and once a week. Findings appear in the repository's Security tab.
- **Nightly** (`workflows/nightly.yml`, also by hand): the whole suite on `windows-latest` in two parts and `tools/load_test.gd --brawl` on Linux. The load test has no threshold yet; its report is kept as an artifact to follow the trend, and the step fails only if the tool did not produce its summary.
- **Dependabot** (`dependabot.yml`): weekly pull requests for the GitHub Actions (pinned by commit SHA), the Go modules of `platform/` and the platform's Docker base images.

## Quality capture bench

The visual quality plan ([quality.md](quality.md)) is verified with captures, not by eye: the bench in `tools/quality/` regenerates, with one command per area, the captures and strips that prove each criterion, at the same resolution and with the same framing, so a before and an after can be shown. It needs a **window and GPU** (it does not work with `--headless`), Python 3 with Pillow (`pip install pillow`) and the Godot console executable (it looks for it in `GODOT`, in the winget install and in the `PATH`; or pass `--godot <path>`). If `override.cfg` exists at the root (ignored by Git), windows open on the second monitor. It uses no accounts or passwords: the server runs with `--debug-commands` and the capture client joins with a throwaway character.

```bash
# One command per area (all write to build/calidad, or the --out folder, and regenerate their indice.md)
python tools/quality/run.py animacion --out build/calidad    # 12-frame strips in the sandbox: player and NPCs
python tools/quality/run.py mapa                             # M map, minimap and compass
python tools/quality/run.py interfaz                         # HUD, windows, title, creation, gallery and chat
python tools/quality/run.py mundo                            # 66 player-height views, review cameras and demo
python tools/quality/run.py combate                          # skirmishes, hit on block and isolated remotes
python tools/quality/run.py video --seconds 60               # a minute of combat with --write-movie
python tools/quality/run.py todo --port 24721                # the six areas in a row
python tools/quality/run.py indice --out build/calidad       # only regenerate the index
python tools/quality/run.py listar                           # areas and steps
```

Each command starts what it needs (the sandbox, or a Vado Gris server on `--port`, 24711 by default, with its bots and the client driven by `online_driver.gd`), collects the captures in `<out>/<area>/`, joins strips into grids, writes `<out>/indice.md` (what each file shows, with which clips, since when) and, when done or interrupted, closes the Godot processes it launched. Options: `--steps a,b` (only some steps of the area, see `listar`), `--only <ids>` (in `animacion`, only those actions), `--phases hueco,capitan,guardia,guardian` (in `combate --steps pnj`, only those phases), `--bots N` (siege bots per realm), `--resolution WxH` (1920x1080), `--sin-capsulas` (in `mundo`, review cameras without the scale capsules), `--clean-raw` (delete the loose frames of `raw/` and keep their `meta.json`) and `--godot`.

| Area | What it launches | What it leaves in `<out>` |
|---|---|---|
| `animacion` (animation) | `anim_strips.gd` on `test_world` (real character, `HumanoidVisual`, `CameraRig` and `LocalPlayerController`; the input scripts are in `anim_actions.gd`) | `animacion/{camara_juego,lado,frente}/<action>.png`: `loc_*`, `com_*`, `arc_*` and `npc_*` (Hollow, Captain, realm guard and Gate Guardian, with attacks, block, stagger and death) |
| `mapa` (map) | a server with 2 x 6 siege bots and `sc_mapa.gd` | `mapa/minimapa_*`, `brujula_*`, `mapa_m_*` and the baked Vado Gris image |
| `interfaz` (interface) | the same server with `sc_interfaz.gd` and `sc_extras.gd`; without a server `sc_front.gd` (title, selection and creation with fake data), `sc_gallery.gd` and `chat_preview.tscn` | `interfaz/*.png` and the `recorte_*.png` crops of `crops.py` |
| `mundo` (world) | a server with no NPCs or bots (`--no-npcs --no-dummies`), `sc_mundo.gd` as Vardheim and as Solmarch, `tools/render/render_screenshot_points.gd` and the sandbox demo | `mundo/jugador_{vardheim,solmarch}/` (33 views each), `mundo/camaras_revision/` (with `metricas.txt`) and `mundo/demo_sandbox/` |
| `combate` (combat) | `sc_combate.gd` with 2 x 6 bots; then a server with no NPCs and **a single** combat bot, and another with the Vado Gris NPCs and no bots | `combate/pelea_*` and `bloqueo_recibiendo_*`, and the remote strips in `animacion/remoto/` and `animacion/remoto_lado/` |
| `video` | a server with the fort NPCs and a combat bot, and `sc_video.gd` with `--write-movie` | `video/combate.avi` (and `.mp4` with `--mp4` if ffmpeg is present) and `video/video.json` |

**Strips of other characters (`rem_*`).** The capture client fights a bot or an NPC ([`spar.gd`](../tools/quality/spar.gd): light and heavy attacks, block, knockback...) and [`strip_recorder.gd`](../tools/quality/strip_recorder.gd) saves every 50 ms the last 4.5 s of the followed character. When the wanted action happens (the rising edge of `BLOCK`, `DODGE`, `DEAD`...) the strip is cut from the ring with the start of the action and discarded if it fails its validation (for example, a "light attack" that turns into a charge). Each strip also has its own side view at 5 m (`remoto_lado`) and marks as `TAPADO` (occluded) the frames with another body in front of the game camera. The `meta.json` of each strip stores, per frame, the combat action, the phase, the speed and **the clip the remote's animation layer plays** (`clip`, `clip_t`, `clip_speed`).

**Video (`video`).** `run.py video` starts the client with Godot's `--write-movie combate.avi --fixed-fps 60` (Movie Maker: it records every frame and the audio of the master bus, stereo PCM at 48 kHz). The video is the size of the project window (1600x900, `window_width_override`), not the `--resolution`. The engine advances one 1/60 s frame per iteration without looking at the clock, so the video is exactly 60 frames per second even when recording runs slower than real time; the server, which does not know it is being recorded, keeps real time and the client compensates as with any bad connection. The duration is that of the script in frames (`--seconds`, 60 by default; about 8 MB per second of video). By hand:

```bash
godot --path . --resolution 1600x900 --write-movie build/calidad/video/combate.avi --fixed-fps 60 \
    -s res://tools/quality/online_driver.gd -- --connect=127.0.0.1:24711 --realm=vardheim --name=Cronista \
    --scenario=res://tools/quality/sc_video.gd --out=build/calidad --tag=video --seconds=60
```

**Before and after.** `tools/quality/compare_before_after.py`, `compare_pairs.py` and `compare_triple.py` join captures of two or three runs side by side (same file name in each folder), which is how each wave of the quality pass was reviewed.

The tests of this bench (`tests/test_quality_tools.gd`) check without a window that all scripts load, that every catalog NPC has its set of strips, that remote strips are well formed, the recorder logic and, if Python with Pillow exists, the Python pieces with fake data.

## Interface and audio notes

- The global theme (`assets/ui/theme/eldmark_theme.tres`, assigned in `project.godot` with `gui/theme/custom`) is generated by `tools/ui/build_theme.gd` from the `UIPalette` palette. To change the look, change the palette or `UIThemeBuilder` and run it again: `godot --headless --path . -s res://tools/ui/build_theme.gd`. The faction emblems in `assets/emblems/` are provisional (`tools/assets/make_emblems.py`).
- Fonts: `assets/fonts/` has Cinzel (titles, war notices, boss names), Noto Sans (text, numbers, nameplates) and IM Fell English SC (map place names), with their OFL files. `UIThemeBuilder` wires the first two into the theme and `UIFonts` gives all three to code that draws text by hand; a test fails if code asks the engine for its default font instead. The two big families are variable fonts, so semibold and bold come from the `wght` axis.
- Icons: the original icons in `assets/ui/icons/` (action bar, potions, status effects, banners, map symbols) come from `tools/ui/icons/`; `GameIcon` draws each figure over the background of its category (`assets/ui/icons/backgrounds/`).
- The UI gallery shows every theme style and the shared components (icon slots with rarity and reuse, key glyphs, tooltip, confirmation dialog, focus): `godot --path . res://scenes/tests/ui_gallery.tscn`.
- Key glyphs (the HUD help line, the slots) read the real `InputMap` assignment, so they reflect any rebound key.
- Audio is client-only: `default_bus_layout.tres` defines the buses (Master with a limiter, Music, Effects, Ambience, Interface and Voices) and `AudioDirector` distributes sounds in pools with a voice limit per category. The sound effects in `assets/audio/sfx/` are synthesized by `tools/audio/synth_sfx.py` (except the grass and wood footsteps, which are Kenney's CC0 Impact Sounds); `CombatAudio` plays them from banks of variants per material, and footsteps follow the surface under the feet (a `surface` metadata value on the collider, or the name of the Terrain3D texture). `tools/audio/listening_sheet.py` builds a sheet to compare alternative sounds by ear.
- The zone map shown in the minimap and the **M** window is a parchment image baked from the scene. After changing the terrain or the props, bake it again and re-import: `godot --headless --path . -s res://tools/map/bake_parchment_map.gd` and then `godot --headless --path . --import`.
- The Vado Gris terrain, textures, grass and environment are generated by `tools/terrain/generate_vado_gris.gd`. The ground textures (Poly Haven, CC0) are processed by `tools/assets/process_terrain_textures.py` and the grass materials by `tools/assets/build_grass_materials.py`. Animation clip trims for the combat layer can be inspected with `tools/animation/list_clips.gd`, `analyze_clip.gd` and `phase_speeds.gd`.

## Export

`export_presets.cfg` (text, versioned) defines two targets, and `tools/export.sh` (Linux and macOS) or `tools/export.ps1` (Windows) export them to `exports/` (not versioned):

| Preset | Platform | Output | What it contains |
|---|---|---|---|
| `Cliente Windows` | Windows x86_64 | `exports/windows/Eldmark.exe` (plus `Eldmark.pck` and the Terrain3D DLL) | All resources; the .pck is separate from the executable |
| `Servidor Linux` | Linux x86_64, dedicated server | `exports/server/eldmark-server.x86_64` (plus its .pck and the Terrain3D `.so`) and `run-server.sh` | Models, materials, audio and animations stripped (no visual layer, but the scene still loads); terrain textures are kept because Terrain3D validates them |

Both leave out `build/`, `docs/`, `tests/`, `tools/`, `exports/`, `.github/` and `scenes/tests/`, and keep the addon licenses, the project's own `LICENSE` and `LICENSE-ASSETS.md` (which carries the godot-cpp notice for the Terrain3D binaries) and the asset license records (the MIT license requires them).

**Steps (once, on your machine):**

1. Install the **4.7.2 export templates** (they do not ship with the editor): open Godot 4.7.2, menu *Editor > Manage Export Templates > Download and Install*, or download `Godot_v4.7.2-stable_export_templates.tpz` from the release page and use *Install from File*. They end up in `%APPDATA%\Godot\export_templates\4.7.2.stable` (Windows) or `~/.local/share/godot/export_templates/4.7.2.stable` (Linux). Without them the script stops and says so.
2. Use a current checkout: the binaries are normal files now, and the script refuses to export if the terrain is still a Git LFS pointer (a clone from before the change; update it or clone again).
3. Export:

```bash
tools/export.sh                  # both targets
tools/export.sh server --zip     # only the server, and zip it
tools/export.sh --pack-only      # only the .pck files: does NOT need the templates (to check filters and stripping)
tools/export.sh --dry-run        # show what it would do
```

```powershell
tools\export.ps1                 # Windows equivalent: -Target client|server|all, -DebugBuild, -PackOnly, -Zip, -DryRun
```

The exported server starts with `./run-server.sh --zone=vado_gris --port=24600` (the launcher adds `--headless`: an exported server without a display needs that option; then come the server options from [Dedicated server](#dedicated-server)). The build id (`eldmark-<version>-p<protocol>+<git describe>`, `BuildInfo`) is baked into `build_id.txt` when exporting and written whole to `BUILD_ID` next to the export; the F3 panel, the client, swarm and zone `--report` files and the platform show the same one. In the editor it is `...+dev`.

**What is verified and how.**

- *In CI* (`.github/workflows/export.yml`, by hand or on a `v*` tag; it downloads Godot and the templates checking their SHA-512, so nothing has to be installed): both presets export, the artifacts carry `BUILD_ID` and `SHA256SUMS`, the exported server loads Vado Gris and a SwarmBot plays on it (over DTLS and over plain UDP), the zone image runs with the database and the platform and shuts down in order on `docker stop`, and the same seeded scenario runs on Linux and Windows to measure the last-bit differences ([networking.md section 14](networking.md#14-bandwidth-and-cpu-budget)).
- *On a developer machine with the templates and Docker* (done once, 2026-11-06, build `eldmark-0.1.0-p7+a7d3c7f`): `tools/export.ps1` exported the Windows client and the Linux server, the server ran in a container built from `platform/deploy/zone.Dockerfile`, and the exported Windows `--bot` played on it over DTLS and over plain UDP; both sides reported the same build id and `docker stop` ended the zone with code 0 and `closed: true`. See [operations.md](operations.md) for the rest.

Exporting to Windows from Linux only gives an executable without icon or metadata (`application/modify_resources=false`: it does not depend on `rcedit`).
