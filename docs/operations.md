# Operations: the test server

How to run Eldmark's closed-test environment on a VPS: what runs, how to set the machine up, which secrets and variables exist, how the exported client finds the platform and the zone, how to deploy, roll back and read the logs. It is the operational side of TEC-12 (executables) and TEC-20 (test server in containers). The platform's own design (database, backups, API) is in [platform.md](platform.md) §10 to §12; the zone's protocol is in [networking.md](networking.md).

Nothing in this document has been run against a real VPS yet: the VPS is a pending decision. What has been run, on GitHub's runners, is the same stack on one machine (section 9).

## 1. What runs

One Docker Compose project per environment (`staging`, later `production`), from `platform/deploy/docker-compose.yml`:

| Service | Image | Listens | Open to the Internet |
|---|---|---|---|
| `caddy` | `caddy:2.10.2` | 80, 443 (TCP and UDP) | TCP 443 (HTTPS to the platform's public API) |
| `platform` | `eldmark-platform` (Go) | 24680 public, 24681 internal | no: only Caddy reaches 24680, only the zones reach 24681 |
| `db` | `postgres:16-bookworm` | 5432 | no: it sits alone on an internal network |
| `zone-vado-gris` | `eldmark-zone` (the exported server) | UDP 24600 | UDP 24600 |

The zone container is the **exported** "Servidor Linux" preset (`tools/export.sh server`) on `debian:bookworm-slim`, running as uid 10001. It is built by `platform/deploy/zone.Dockerfile`. Its `ENTRYPOINT` is `platform/deploy/zone-entrypoint.sh`, which exists because Godot scripts cannot catch SIGTERM or SIGINT ([networking.md](networking.md) §1.3):

- it starts the server as a child with `--stop-file=/run/eldmark/stop --report=/run/eldmark/report.json`;
- on SIGTERM or SIGINT (`docker stop`, `docker compose down`, a deploy) it creates the stop file; the zone then sends the "servidor cerrándose" NOTICE to the players, saves every character, releases the leases, deregisters from the platform, writes a final report with `"closed": true` and exits with code 0; the entrypoint exits with the server's code;
- `docker stop` waits `stop_grace_period` (45 s) before it kills the container, which is enough for the final saves;
- the `HEALTHCHECK` (`zone-entrypoint.sh --healthcheck`) is healthy while the report was rewritten in the last 45 s; the zone rewrites it every 10 s, so a stuck tick loop turns the container unhealthy.

## 2. The VPS

Any small Linux VPS with Docker Engine and the Compose plugin. The zone is single-threaded for the simulation, so one fast core matters more than many (see [networking.md](networking.md) §14 for the budget): 2 vCPU and 4 GB are enough for the 2-hour test with a few dozen people.

1. **User.** Create a non-root user `eldmark`, add it to the `docker` group (it is root-equivalent: use it only for deploying), disable SSH password login and root login.
2. **Firewall.** Default deny incoming; allow exactly:
   - `22/tcp` from your own address (or another port for SSH);
   - `443/tcp`: the platform's HTTPS API through Caddy;
   - `24600/udp`: the zone.

   Port 80 and 443/udp can stay closed: Caddy obtains its certificate with the TLS-ALPN challenge on 443 and the API does not need HTTP/3. Docker publishes ports by editing iptables, which bypasses `ufw`: apply the rule in the provider's firewall (the simplest option) or in the `DOCKER-USER` chain, not only in `ufw`. Check from outside with `nmap -sS -p 22,80,443,5432,24600,24680,24681 <host>` and `nmap -sU -p 24600 <host>`: only 22, 443 and 24600/udp may answer.
3. **DNS.** Two names to the VPS: the API's (`ELDMARK_DOMAIN`, for Caddy's certificate) and the zone's (`ELDMARK_PUBLIC_HOST`, which the platform hands to the clients; it can be the same name).
4. **Logs.** Install `platform/deploy/journald-eldmark.conf` as `/etc/systemd/journald.conf.d/eldmark.conf` and restart `systemd-journald` (30 days at most; the compose file sends every container to journald).
5. **Time.** `timedatectl set-ntp true`: the platform compares its clock with the zone's.
6. **Folders.** `/opt/eldmark/staging/` with `staging.env`, `secrets/` and, later, the compose files that `deploy.yml` copies in; `/var/backups/eldmark-staging/` for the backups ([platform.md](platform.md) §11).

## 3. Secrets and variables

**Variables** are in `staging.env` (copy `platform/deploy/staging.env.example`; git ignores the real file): domain, ACME email, public host, minimum protocol, open realms and entry zones, image names. None of them is a secret, and the repository's CI fails if an `*.example` carries a secret's value (`tools/check_secrets.sh`).

**Secrets** are one file each in `secrets/` (`ELDMARK_SECRETS_DIR`), mounted as Docker secrets at `/run/secrets/<name>`. The folder is owned by root with mode 0700 and each file 0444, because inside the containers they are read by unprivileged users (eldmark 10001, postgres 999):

| File | What | How to create it |
|---|---|---|
| `postgres_password` | the `eldmark` role's password | `openssl rand -hex 24` |
| `database_url` | `postgres://eldmark:<password>@db:5432/eldmark?sslmode=disable` | built from the above |
| `ticket_keys` | `1:<base64 of 32 B>` (several, comma-separated, for rotation) | `echo "1:$(openssl rand -base64 32)"` |
| `zone_token_vado_gris` | the zone's token, in plain text | `openssl rand -hex 32` |
| `zone_tokens` | `1:vado_gris:0:<SHA-256 of the token in hex>` | `printf '1:vado_gris:0:%s' "$(printf %s "$TOKEN" \| sha256sum \| cut -d' ' -f1)"` |
| `vado_gris_dtls_cert`, `vado_gris_dtls_key` | the zone's self-signed certificate (the client pins it: the platform passes it to the client) and its key | the `openssl req -x509 -newkey ec ...` command in the header of `docker-compose.yml` |
| `email_hmac_key` | base64 of 32 B | `openssl rand -base64 32` |
| `smtp_url` | `smtp://user:password@host:587` | from the mail provider (still undecided) |

The `ticket_keys` file must be identical for the platform and the zones; rotation is `2:<new>,1:<old>` first, then removing `1` once the old tickets have expired ([platform.md](platform.md) §10.3).

**Repository secrets** (GitHub, only for `deploy.yml`): `DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_SSH_KEY` (a key used only for this), `DEPLOY_KNOWN_HOSTS` (`ssh-keyscan -t ed25519 <host>`, so the host key is pinned) and `DEPLOY_PATH` (`/opt/eldmark/staging`). Without all five the workflow does nothing.

## 4. How the exported client finds the platform and the zone

The client never needs the zone's address: it logs in to the **platform** over HTTPS, asks to enter, and the platform answers with the zone's host, port, ticket and certificate. Only the platform's URL has to be configured:

- the project setting `eldmark/platform/url` (default `http://127.0.0.1:24680`, the development platform);
- overridden **without rebuilding** by an `override.cfg` next to `Eldmark.exe`:

  ```ini
  [eldmark]
  platform/url="https://api.staging.example.org"
  ```

- or, for a single run, `Eldmark.exe --platform=https://api.staging.example.org` (a bot adds `--bot --login=<email> --password-file=<file> --character=<name>`).

The platform refuses a client whose protocol is lower than `ELDMARK_MIN_PROTOCOL` (HTTP 426: "actualiza el cliente"), so that variable and the build the testers download must move together. The build id of the downloaded client is in its `BUILD_ID` file, in the F3 panel (the "Build:" line), in the client `--report` and in the zone's `--report` (`build`); the platform stores the zone's in `zone_instances.build_id`. The three must be the same text.

## 5. Building the executables

On GitHub, `export.yml` (manual, or on a `v*` tag) downloads Godot 4.7.2 and its export templates (checking their SHA-512), exports both presets and uploads two artifacts for 7 days: `eldmark-windows-client` and `eldmark-linux-server`, each with its zip, `SHA256SUMS` and `BUILD_ID`. Its other jobs check the result (section 9). Locally, `tools/export.sh` / `tools/export.ps1` do the same with the templates installed in the editor ([getting-started.md](getting-started.md)).

Both scripts bake the git revision (`git describe --always --dirty`, or `ELDMARK_REVISION`) into `build_id.txt` for the time of the export; the file is git-ignored and removed afterwards, so the editor shows `dev`. The whole id is `eldmark-<version>-p<protocol>+<revision>`.

## 6. Deploying

The images are not published anywhere yet. When the owner decides to, there are two ways.

**By hand**, on the VPS, with a server exported on the laptop or taken from the artifact:

```bash
cd /opt/eldmark/staging
# the exported server, unzipped in exports/server of a checkout of the repository
docker compose --env-file staging.env build platform zone-vado-gris
docker compose --env-file staging.env up -d db
docker compose --env-file staging.env run --rm platform migrate up
docker compose --env-file staging.env --profile zonas up -d
```

**With `deploy.yml`** (switched off): *Actions > Deploy > Run workflow*, with `publish` ticked, the `export_run_id` of a green Export run and a `tag` (never `latest`). It pushes `ghcr.io/<owner>/eldmark-{zone,platform,ops}:<tag>`, copies the compose file and runs `tools/ci/remote_deploy.sh` on the VPS over SSH. That script writes `images.env` with the new tags (keeping the previous one as `images.env.previous`), pulls, applies the migrations, recreates what changed and waits for the zones to be healthy. A zone whose image changed gets SIGTERM, so the players receive the shutdown notice and nothing is lost.

**Rolling back:**

```bash
/opt/eldmark/staging/remote_deploy.sh /opt/eldmark/staging ghcr.io/<owner>/eldmark - rollback
```

(or copy `images.env.previous` over `images.env` and run `docker compose ... up -d`). Migrations are forward-only: a release that migrated the database can only be rolled back if the old binary still works with the new schema, which is a rule for whoever writes the migration ([platform.md](platform.md) §12).

## 7. Logs and health

- Everything goes to journald, tagged with the container name: `journalctl -t eldmark-staging-zone-vado-gris-1 -f`, `journalctl -t eldmark-staging-platform-1 --since "1 hour ago"`.
- Godot's own log files of the zone (`user://logs`) live in the `zone_vado_gris_logs` volume.
- `docker compose ps` shows the health of every service; `docker inspect --format '{{.State.Health.Status}}' <zone container>`.
- The zone's last report: `docker compose exec zone-vado-gris cat /run/eldmark/report.json`, or `docker cp`. It carries the tick percentiles, players, strikes, kicks and `build`.
- Stopping on purpose: `docker compose stop zone-vado-gris` and look for `Cierre del servidor: apareció el archivo de parada` and `Servidor cerrado` in the log.

## 8. Backups

Daily dumps, the weekly restore test and point-in-time recovery are in [platform.md](platform.md) §11 and `platform/deploy/backup.sh`, `restore_check.sh`, `pitr_check.sh`; the VPS cron entry is a pending item until the VPS exists.

## 9. What CI checks on every run of `export.yml`

| Job | Checks |
|---|---|
| Export | both presets export with the templates of the right version; the revision is inside both packs; `BUILD_ID` is the same in both |
| Smoke test | the exported server loads Vado Gris, simulates 1500 ticks, a SwarmBot plays on it (over DTLS and over plain UDP) and the report's `build` is `BUILD_ID`; the engine canary reports whether the crash below is still there (it never fails the run) |
| Determinism | the same seeded scenario (16 fake players with the combat brain, 3600 ticks) on Linux and on Windows, compared by `tools/diff_state_logs.gd`; the figures are in [networking.md](networking.md) §14 |
| Zone in a container | the image built from the exported server; with the database and the platform (`docker compose`, test secrets): a bot enters over DTLS with a ticket, plays the progress scenario (bow, 50 gold, potion), leaves; the same account comes back and sees it; `docker stop` with a bot inside gives code 0, the shutdown messages, a final save, a released lease, an instance in `stopped` and a report with `closed: true` |

**Known engine crash (found while building the smoke test, understood and avoided).** The exported *release* Linux server of
Godot 4.7.2 dies with SIGBUS (exit code 135) when it handles a DISCONNECT that a **plain-UDP** client started. A core dump from the
runner puts the main thread in the engine, in a loop that follows a pointer that is not canonical, always at the same address; it
is not a file or alignment problem and it is not in our scripts. It does not happen over DTLS (production), in the debug export,
in the editor or on Windows, nor when the server starts the disconnect. The game never triggers it: the client waits for the server
to cut ([networking.md section 3](networking.md#who-starts-the-disconnect-an-engine-crash-tec-12)). What this means for you:
plain UDP is for local and test servers; do not run a release server without a certificate on a machine that strangers can reach,
because a raw ENet DISCONNECT from anyone takes it down. `tools/ci/engine_canary.sh` runs on every CI run and tells (as a notice)
when an engine update fixes it.

`tools/ci/zone_container_check.sh <godot>` runs the last one on any machine with Docker, after `tools/export.sh server`.

## 10. The 2-hour test

TEC-20 is finished when a test with remote players holds for 2 hours without intervention. Before that, run the soak on the machine that will host it (nothing else running):

```bash
godot --headless --path . -s res://tools/load_test.gd -- --soak --seconds=7200
python -I tools/soak_chart.py build/load_test/soak_40f_8b_series.json
```

It runs 40 fake players and 8 clients that join and leave; the criterion is that, after the first 10 minutes, static memory and the object count grow by less than 10 %, the tick p99 drifts by less than 10 % and there are no kicks or errors. The chart (memory and p99 over time) is the SVG next to the series.

The scenario was tried for 150 s on 2026-11-06 (`--soak --seconds=150`): 40 fake players and 8 bots, up to 49 joins and 2 leaves, 0 kicks, 0 physics errors, 16 samples in the series and the chart written. The criterion itself needs more than the 10 minutes of warm-up, so that short run reports it as not met on purpose; the 2-hour run has not been done (its own night turn).
