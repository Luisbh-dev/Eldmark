# Eldmark · Phase 5: platform design

Design of step 5 of the [roadmap](vision.md#roadmap): accounts, characters and saving to a database.
It covers the platform service and everything that goes through it: TEC-22 to TEC-25, TEC-27, TEC-28, TEC-41, TEC-43,
PRG-41, SOC-13 to SOC-18, GUE-19 and the client side of UI-22 to UI-24.

It builds on networking ([networking.md](networking.md): §3 connection, §5.3 authentication, §12 security, §15 extension, §17
contracts), combat ([combate.md](combate.md) §1 and §5), the fort ([fortress.md](fortress.md) §5) and social features
([social.md](social.md) §8 to §11). Items, inventory, currencies, levels, races, appearance and the saved combat
configuration (CMB-30) belong to `docs/progression.md` (PRG-02, PRG-10 to PRG-16, CMB-30, ART-19, in progress at the
same time). The boundary is here (§7.5); what was agreed with that document and where each rule lives is in §17.
Revised after three reviews and later reconciled with progression.md (§18).

What is taken as verified was measured on this machine with probes in `build/` (Go 1.24.7, PostgreSQL 16.15, Godot
4.7.2 headless; the review probes are in `build/probe_rev/`, which is not committed). Whatever was not is marked
"unverified" and listed in §16.

## 0. Decisions

Provisional, **made overnight** with the backlog's recommendation; they are in "Decisiones tomadas" (decisions made)
in [backlog.md](backlog.md) with that mark.

| Question | Decision |
|---|---|
| Service technology | **Go + PostgreSQL**, a dedicated service. No ORM or web framework: standard-library `net/http`, `pgx` and `x/crypto/argon2` |
| Save strategy | **Checkpoint every 60 s** if anything changed, plus an immediate write for critical events, on exit and when the zone closes; with a lease and idempotency by `(lease_id, seq)` (§7) |
| One world or several | **A single world** at launch (`world_id = 1`, "Eld"), with `world_id` in the schema from the first migration |
| Client ↔ zone encryption | **ENet DTLS** if its measured cost (TEC-27) fits; the platform delivers the zone's certificate over HTTPS and the client pins it (§10.2). Without DTLS there are no public tests: in `staging` and `production` the platform does not register a zone without a certificate |
| Realms per account | **One realm per account and world.** Switching the whole account, with a 30-day wait, comes later; in phase 5 the realm is only released 30 days after the last character is deleted |
| Ignore | **Per account, silently** (social.md §10). The server also filters the public channels (§9.3) |
| Chat retention | **30 days** for all channels, whispers included; **1 year** for what is copied into a report (`report_evidence`, §11.1). Legal review before public tests |

Decisions in this document that were not in the backlog (provisional, made overnight):

| Question | Decision |
|---|---|
| Login | Email and password; one active game session per account (the new one closes the previous one and kicks its character) and a single character in the world per account and world (§4.5, §5.3). A suspended or banned account only receives, after the password, a privacy session to export or delete its data (§4.2) |
| Passwords | argon2id, m = 19 456 KiB, t = 2, p = 1 (59 ms here); PHC string |
| Tokens | Opaque, random, stored as SHA-256: 15-minute access token and a refresh token that rotates in the same `sessions` row. The session lasts 12 h from login: rotating does not extend it. The client keeps them in memory only |
| Minimum age | 16 years, declared when creating the account. **Legal review** |
| Slots | 6 characters per account and world, expandable with entitlements (§11.3); deleted characters that can still be restored take up a slot |
| Open realms | Vardheim and Solmarch: Vado Gris does not admit Askarra, which shows up as "Próximamente" (coming soon) |
| Deletion | Character: restorable for 7 days; its name is reserved for those 7 days plus 30 more. Account: 14-day grace period |
| HTTPS | The platform speaks HTTP; Caddy in front provides HTTPS with Let's Encrypt (§10.1) |

Made during the review (§18), **provisional, made overnight**:

| Question | Decision |
|---|---|
| Boundary with progression.md | **A single pipeline.** The claim brings the `progress` section (progression.md §3.4) before WELCOME. `CharacterSaver` (TEC-25, here) decides when to save; `ProgressService` (progression.md) decides what. Idempotency by `(lease_id, seq)`, no `save_id` or `base_version` (§7.3, §7.5, §17) |
| Returning to the world | **The rule is the one in progression.md §8.** It is also in the backlog's "Decisiones tomadas" |
| TEC-27 criterion | **Relative**: with 64 bots, DTLS does not raise the tick p99 by more than 10 % compared with the same test without DTLS, and the absolute figure is recorded. The backlog's absolute criterion (8 ms) is not met even without DTLS (15.9 ms, networking.md §14). **Question for the user**; it is in the backlog's "Decisiones tomadas" |
| Ledger after deletion | The purged character remains as a nameless **tombstone**; its ledger and its item events are kept 1 more year and then deleted (§11.1). While the account exists they stay linked to it and are exported; they become pseudonymous only after it is purged. **Legal review** |
| `auth_timeout` | **10 s** on both sides (previously 5 s), in the phase 5 protocol bump: it leaves room for the claim (§5.2) |
| Lost instance that comes back | It is closed (kicked with a final save) and the orchestrator starts it again; it does not revive (§6.1) |

Left for the user: the business model (PRG-41; the schema supports any, §11.3), the VPS provider and region, the final
legal texts, the domain, **the SMTP provider and the mail DNS** (SPF, DKIM and DMARC: staging does not start without
SMTP, §4.3), **the visual review of UI-22 to UI-24** (checklist in §15) and **the TEC-27 criterion** (absolute or
relative). The backlog marks each of these entries "pendiente del usuario" (pending on the user).

## 1. Pieces and who decides what

The client speaks HTTPS to the platform's public API (:24680) and UDP (ENet with DTLS) to the zone; the zone speaks
HTTP to the internal API (:24681, private network); only the platform touches PostgreSQL 16.

| What | Decided by | Notes |
|---|---|---|
| Identity, password and session | Platform | The zone never sees passwords or session tokens |
| Realm and name | Platform, when creating the character | In the zone, `HELLO.realm` and `HELLO.name` are ignored: those from the claim take precedence |
| Race, appearance and starting template | progression.md (what they are worth); the platform validates them on creation (§4.4) | With `progression_rules.json` and `persistence.CreateValidator`, which implements `*progress.Rules` (§7.5, progression.md §13.2) |
| Which zone it enters | Platform (`enter`) | The last one (`ProgressStore.Summaries`) if it has a live instance that admits its realm; otherwise, the entry zone |
| Whether the ticket is valid | Zone (format, signature, zone, expiry) and platform (single use, lease) | §5 |
| State of the character in play | Zone | The platform applies what it is sent, with checks S1–S8 of progression.md §13.3 (§7.3) |
| When to save, `seq`, retries | Zone: `CharacterSaver` (§7.2) | progression.md provides the content |
| Sanctions and roles | Platform | It checks the author's role (§9.5); the zone applies them on entry, with the heartbeat and in `ChatRouter` |
| State of the fortresses | Zone | The platform stores it and returns it on startup (§8) |
| Schema and migrations | The framework, here (§2.4); the progress ones, progression.md P7 | Zones have no database credentials |

```
Client                          Platform                              Zone
                                 ◀── registration, fortresses, block ── before opening the port
                                 ◀── …/live ─────────────────────────── port open
POST /v1/sessions ─────────────▶ session
POST /v1/characters/42/enter ──▶ no live lease: ticket
◀── host, port, ticket (52 B), DTLS certificate
HELLO (character_id, ticket) ─────────────────────────────────────────▶ signature, zone, expiry (VERIFYING)
                                ◀── POST /internal/v1/claims ──────────
                                consumes the ticket, lease ───────────▶ lease_id, account, character and progress
◀──────────────────────────────────────────────────────────── WELCOME (character's realm)
loads the zone, CLIENT_READY ─────────────────────────────────────────▶ registration with the registry (progression.md §9.1)
                                ◀── PUT …/state (lease_id, seq): every 60 s, critical events, on exit
```

## 2. The service (TEC-22)
### 2.1 Structure
```
platform/            go.mod: module eldmark/platform, go 1.24.0, toolchain go1.24.7 · .gdignore (Godot does not scan it)
  cmd/eldmark-platform/   subcommands serve, migrate, admin
  internal/  config logx db httpx (router, errors, limits) jsonx (JSON integers and ids, §4.1) migrate
             (+ migrations/*.sql with embed) testdb passwords accounts names gamedata (progression_rules.json, §4.4)
             characters tickets zones persistence progress (progression.md P7) war social privacy mail
             services (what serve wires up; also the e2e/ harness, P10)
  e2e/  legal/ (terms-1.md, privacy-1.md, rules-1.md)  deploy/ (Dockerfile, docker-compose.yml, Caddyfile,
        journald-eldmark.conf, *.env.example, secrets/ (ignored), dev.sh, backup.sh, restore_check.sh, pitr_check.sh)
```

`export_presets.cfg` adds `platform/*` to the `exclude_filter` of both targets and `test_export_config.gd` checks it
the same way as `build/*`.

### 2.2 Dependencies
Three, with pinned versions: `github.com/jackc/pgx/v5` **v5.8.0** (driver and `pgxpool`), `golang.org/x/crypto`
**v0.45.0** (`argon2.IDKey`) and, indirectly, `golang.org/x/text` v0.31.0; all three declare `go 1.24.0`. **The latest
versions will not do:** pgx v5.9+ requires Go 1.25 and x/crypto v0.50+ requires 1.25 or 1.26, and with
`GOTOOLCHAIN=auto` Go would try to download another toolchain (verified). Tests and CI use `GOTOOLCHAIN=local`. UUIDs
come from `crypto/rand` with a custom format.

### 2.3 Configuration
Environment variables; each secret accepts `<NAME>_FILE` with the path to a file (Docker secrets). A missing or
unintelligible value **prevents startup** with a message in Spanish.

| Variable | Default | Notes |
|---|---|---|
| `ELDMARK_ENV` · `ELDMARK_DATABASE_URL` | `dev` · — | `dev`, `test`, `staging` or `production` · secret |
| `ELDMARK_PUBLIC_ADDR` · `ELDMARK_INTERNAL_ADDR` · `ELDMARK_PUBLIC_URL` | `127.0.0.1:24680` · `127.0.0.1:24681` · `http://127.0.0.1:24680` | The internal one, never on a public interface · base for the links in emails |
| `ELDMARK_ZONE_TOKENS` | — | Secret. One entry per zone deployment: `<world>:<zone>:<channel>:<hex SHA-256 of the token>`, comma-separated; two with the same scope during a rotation. Only hashes are stored (§6) |
| `ELDMARK_ZONE_HOSTS` | `127.0.0.1` | `public_host` values that registration admits, comma-separated |
| `ELDMARK_TRUSTED_PROXIES` | `127.0.0.1/32` | CIDR from which `X-Real-IP` is read: that of the Caddy container (§4.2) |
| `ELDMARK_TICKET_KEYS` · `ELDMARK_TICKET_SIGN_KEY` | — · the highest | Secret `1:<base64 of 32 B>,2:<…>` · id used for signing. A key shorter than 32 B does not start; neither does the one from the §5.1 vector (`00 01 … 1f`), except in `test` |
| `ELDMARK_EMAIL_HMAC_KEY` | — (in `dev` and `test`, a fixed test one) | 32 B secret for `sanctioned_email_hashes` (§11.2) |
| `ELDMARK_ARGON2` | `m=19456,t=2,p=1` | In `test`, `m=8,t=1,p=1` |
| `ELDMARK_MIN_PROTOCOL` | `dev` and `test`: the `protocol_version` from `progression_rules.json` · `staging` and `production`: **required** | Below it, 426 |
| `ELDMARK_OPEN_REALMS` · `ELDMARK_ENTRY_ZONES` | `vardheim,solmarch` · `vardheim=vado_gris,solmarch=vado_gris` | Realms in which characters can be created · entry zone per realm |
| `ELDMARK_REQUIRE_VERIFIED_EMAIL` | `false` in dev and test; `true` elsewhere | To enter the world |
| `ELDMARK_MAIL` · `ELDMARK_SMTP_URL` | `log` · — | `log` (`outbound_mail` table) or `smtp`; secret `smtp://user:password@host:587` |
| `ELDMARK_TLS_CERT_FILE` · `ELDMARK_TLS_KEY_FILE` | — | Optional: direct HTTPS (pinning tests) |
| `ELDMARK_HEARTBEAT_S` · `ELDMARK_LEASE_TTL_S` | `5` · `30` | An instance with no heartbeat for 3 × `HEARTBEAT_S` is considered lost; the zone is fenced at 2 × (§5.3). `LEASE_TTL_S` must exceed 3 × `HEARTBEAT_S` + min(5 s, `HEARTBEAT_S`) (20 s with the defaults): otherwise a lease expires before its heartbeat-less instance is considered lost |
| `ELDMARK_LEGAL_DIR` | `platform/legal` | Versioned legal texts |

**Logging:** `log/slog` with `JSONHandler` to standard output. Fields: `time`, `level`, `msg`, `req` (request id, also
in `X-Request-Id`), `route`, `status`, `ms`, and `account` and `character` when known. Passwords, tokens, tickets,
bodies and chat text are **never** logged; the email is masked (`a***@example.org`).

### 2.4 Migrations
- `internal/migrate/migrations/NNNN_name.up.sql` and `.down.sql`, embedded. In phase 5, **0001–0006 belong to this
  document** (§3) and **0010_progress, to progress** (progression.md §3.3, its P7, with its `.down.sql` and its seed);
  0007–0009 are left unused. After that, each new migration, whoever owns it, takes the next free number above the
  highest in the repository. A number is never reused.
- Table `schema_migrations (version int primary key, name text not null, checksum bytea not null, applied_at
  timestamptz not null default now())`. The runner takes `pg_advisory_lock(4815162342)`, applies pending migrations
  in number order, each in its own transaction, and refuses to continue if the SHA-256 of an applied one has changed
  or if one is pending below the highest applied ("La migración NNNN está pendiente por debajo de la MMMM ya
  aplicada: renumérala", i.e. migration NNNN is pending below the already applied MMMM: renumber it). `down N` undoes
  the N highest applied, in reverse order.
- `eldmark-platform migrate up|down N|status`. `serve` does not migrate: if any of its embedded files is still to be
  applied, it does not start and `/ready` says why. A database with later migrations is fine (expand and contract,
  below).
- **Expand, then contract.** Binary N works with schema N + 1: new things come in with a default or null value, and
  nothing is dropped or renamed in the same version that stops using it. This way going back to the previous tag does
  not require `down`.
- **`down` is for development and CI only.** In staging and production you roll back by restoring the previous backup
  or by fixing forward (§12). A migration with no inverse (data migrations, or ones that delete) carries
  `-- irreversible` on its first line and its `.down.sql` does `do $$ begin raise exception 'irreversible'; end $$;`.
- CI: `up` → `down` to the last irreversible one (or 0) → `up`, with the final schema (`pg_dump -s`) identical.
  **Preservation:** with one row in each table (seed `internal/migrate/testdata/seed_NNNN.sql`, the one for that
  version's schema), applying the next migration changes no `count(*)`.

### 2.5 Startup and health
- `GET /health`: 200 if the process is alive (without touching the database). `GET /ready`: 200 if `select 1`
  answers in under 1 s and migrations are up to date; otherwise 503 with the reason.
- On startup, `serve` grants a 30 s grace period: `last_heartbeat_at = greatest(…, now())` on `starting` and `live`
  instances, and `expires_at = greatest(expires_at, now() + TTL)` on their leases that were still alive at the last
  heartbeat (`expires_at ≥ last_heartbeat_at`, checked before bumping it): one that had already expired before the
  crash does not resurrect. A platform that comes back after crashing does not declare dead the zones that could not
  send heartbeats.
- Periodic jobs in the same process (`time.Ticker` and `pg_try_advisory_lock`): lost zones (every
  `min(5 s, HEARTBEAT_S)`),
  retention and purges (1 h; the ledger one, `ProgressStore.PurgeRetention`, progression.md §3.5).

### 2.6 Tests with a real, ephemeral database
Package `internal/testdb`. **Docker is not needed** (its daemon does not run here). Verified:

| Step | How | Time |
|---|---|---|
| Binaries | `ELDMARK_PG_BIN`; otherwise `pg_config --bindir`; otherwise the highest `/usr/lib/postgresql/*/bin` | — |
| User | `initdb` refuses to run as root. If `os.Geteuid() == 0`, each command goes through `runuser -u postgres --` (or `ELDMARK_PG_USER`) and the folder is handed over to it with `chown` | — |
| Cluster | `initdb -D <tmp>/data -U eldmark --auth=trust -E UTF8 --no-locale --no-sync` in `os.MkdirTemp("", "eldpg-")` (short path: the socket allows 107 B) | 0.6 s |
| Server | `pg_ctl -w -s start -o "-k <tmp> -c listen_addresses= -c fsync=off -c synchronous_commit=off -c full_page_writes=off"`: Unix socket only, no ports that clash between suites | 0.12 s |
| Template | Database `tmpl` with all migrations, once per package in `TestMain` | — |
| Each test | `create database t_<n> template tmpl` and `drop` when finished | 60 ms |

- `testdb.Main(m)` in `TestMain`; `testdb.New(t)` gives a clean `*pgxpool.Pool`; at the end, `pg_ctl stop -m
  immediate` and the folder is deleted; if the process dies first (a panic, the `go test` timeout, a Ctrl-C), a
  watchdog does it: a `sh` in its own process group that waits on a pipe and cleans up when it closes. Without
  binaries, `t.Skip`, except with `ELDMARK_REQUIRE_PG=1` (CI), which fails; `ELDMARK_TEST_DATABASE_URL` uses an
  already running server. The first compilation with pgx takes ~18 s: the < 30 s per package figures are with a warm
  cache.
- The schemas of §3 (0001–0006) and of progress (progression.md §3.3) were applied this way in the reviews: slot
  swapping with the deferred constraint, the tombstone, the append-only trigger and retention with `set local` all
  work (`build/probe_rev/pg/`).
- **CI:** "Plataforma" job in `.github/workflows/tests.yml`: `actions/setup-go` with `go-version-file:
  platform/go.mod`, `GOTOOLCHAIN=local`, `ELDMARK_REQUIRE_PG=1` and, in `platform/`, `go vet ./...` and `go test -p 2
  ./...` with the PostgreSQL of `ubuntu-latest` (unverified; if missing, `apt-get install postgresql-16`). The same
  job checks the secrets (§10.3). The "Plataforma e2e" job belongs to P10 (§15).

## 3. SQL schema

Game tables carry `world_id` (`id_blocks` and the progress ones take it from `zone_instances` and from `characters`);
account ones do not. Realms are `smallint` with the codes of `NetProtocol.Realm` (1 Vardheim, 2 Solmarch, 3 Askarra);
in JSON, the rule of §4.1 (text in the public API, code in the internal one). `ts` abbreviates `timestamptz` here and
`now_ts` abbreviates `timestamptz not null default now()`; in the files they are written out in full. This DDL was
applied in full on PostgreSQL 16 (§2.6), except `sessions.scope`, `chat_messages.zone_channel` and the
`(target_account_id, command, at)` index of `audit_log`, added later (unverified).

**Who stores what:** the single table, with all the character's fields and its owner, is in progression.md §3.1. This
document owns identity (`characters`), PvP statistics (`character_pvp_stats`, GUE-19), the lease (`character_leases`:
`lease_id`, `seq`, hash and `save_version` of the last save) and the id blocks (`id_blocks`); progression.md owns
`character_progress` and the rest of `0010_progress` (its §3.3). There are no JSON columns for character state: what
has no column arrives with a migration.

```sql
-- 0001_accounts
create table worlds (world_id smallint primary key, name text not null unique, created_at now_ts,
  status text not null default 'open' check (status in ('open','locked','maintenance')));
insert into worlds (world_id, name) values (1, 'Eld');
create table accounts (account_id bigint generated always as identity primary key, email text unique, password_hash text,  -- null: purged or pending reset
  email_verified_at ts, role text not null default 'player' check (role in ('player','moderator','gm','admin')),
  status text not null default 'active' check (status in ('active','pending_deletion','purged')), age_confirmed_at ts not null,
  deletion_requested_at ts, purge_after ts, purged_at ts, created_at now_ts);
create table sessions (session_id bigint generated always as identity primary key, account_id bigint not null references accounts on delete cascade,
  access_hash bytea not null unique, access_expires_at ts not null, refresh_hash bytea not null unique, prev_refresh_hash bytea unique,
  refresh_expires_at ts not null,                                               -- login + 12 h; rotating does not extend it
  scope text not null default 'game' check (scope in ('game','privacy')),          -- privacy: sanctioned account (§4.2)
  ip inet, user_agent text, client_protocol int, created_at now_ts, rotated_at ts, revoked_at ts,
  revoke_reason text check (revoke_reason in ('logout','replaced','password_changed','email_changed','email_reverted',
    'refresh_reuse','role_changed','deletion','admin')));
create index on sessions (account_id) where revoked_at is null;
create table account_tokens (token_hash bytea primary key, account_id bigint not null references accounts on delete cascade,
  purpose text not null check (purpose in ('verify_email','reset_password','change_email','revert_email')),
  email text,                                                                   -- change_email: the new one; revert_email: the old one
  expires_at ts not null, used_at ts, created_at now_ts);
create table auth_events (id bigint generated always as identity primary key, account_id bigint references accounts on delete set null,
  kind text not null, ip inet, user_agent text, at now_ts);                     -- kind: §4.2
create index on auth_events (at); create index on auth_events (account_id, kind, at);
create table legal_documents (kind text not null check (kind in ('terms','privacy','rules')), version int not null, sha256 bytea not null,
  published_at now_ts, primary key (kind, version));
create table legal_acceptances (account_id bigint not null references accounts on delete cascade, kind text not null, version int not null,
  accepted_at now_ts, primary key (account_id, kind, version), foreign key (kind, version) references legal_documents);
create table consents (account_id bigint not null references accounts on delete cascade, granted boolean not null, updated_at now_ts,
  purpose text not null check (purpose in ('crash_reports','analytics')), primary key (account_id, purpose));
create table entitlements (entitlement_id bigint generated always as identity primary key,                       -- PRG-41
  account_id bigint not null references accounts on delete cascade, world_id smallint references worlds,      -- null: all worlds
  kind text not null check (kind in ('character_slots','expansion','cosmetic')), ref text not null default '',
  quantity int not null default 1 check (quantity > 0), source text not null check (source in ('grant','purchase','promo')),
  granted_at now_ts, expires_at ts, revoked_at ts);
create table outbound_mail (id bigint generated always as identity primary key, to_email text not null, template text not null,
  body text not null, created_at now_ts);                                       -- only with ELDMARK_MAIL=log

-- 0002_characters
create table account_realms (account_id bigint not null references accounts on delete cascade, world_id smallint not null references worlds,
  realm smallint not null check (realm between 1 and 3), unlock_at ts, primary key (account_id, world_id));
create table characters (character_id bigint generated always as identity primary key, world_id smallint not null references worlds,
  account_id bigint not null references accounts, name text, name_key text,     -- null only in the tombstone (§11.2)
  realm smallint not null check (realm between 1 and 3), must_rename boolean not null default false, created_at now_ts,
  last_entered_at ts, deleted_at ts, restore_until ts, purged_at ts,
  check ((purged_at is null) = (name is not null and name_key is not null)));
create index on characters (account_id, world_id) where purged_at is null;
create table character_names (world_id smallint not null references worlds, name_key text not null,
  character_id bigint references characters on delete set null, status text not null check (status in ('active','reserved')),
  reserved_until ts, primary key (world_id, name_key));
create table name_blacklist (name_key text primary key, reason text not null, added_by bigint references accounts on delete set null,
  added_at now_ts);
create table character_pvp_stats (character_id bigint primary key references characters on delete cascade,
  world_id smallint not null references worlds, kills int not null default 0, deaths int not null default 0, assists int not null default 0,
  captures int not null default 0, gate_damage bigint not null default 0, defend_s int not null default 0, updated_at now_ts);

-- 0003_zones
create table zone_instances (zone_instance_id uuid primary key, world_id smallint not null references worlds, zone_id text not null,
  channel smallint not null default 0, public_host text not null, public_port int not null check (public_port between 1 and 65535),
  realms smallint[] not null, build_id text not null, protocol_version int not null, record_format smallint not null,
  dtls_cert_pem text, dtls_name text, max_players int not null, players int not null default 0,
  status text not null check (status in ('starting','live','stopped','lost','replaced')),
  started_at now_ts, live_at ts, last_heartbeat_at now_ts, ended_at ts);
create unique index on zone_instances (world_id, zone_id, channel) where status in ('starting','live');
create table enter_tickets (ticket_id bigint primary key, world_id smallint not null references worlds,   -- ticket_id: u64 with bit 63 at 0
  character_id bigint not null references characters on delete cascade, session_id bigint not null references sessions on delete cascade,
  zone_instance_id uuid not null references zone_instances on delete cascade, issued_at ts not null, expires_at ts not null, consumed_at ts);
create table character_leases (character_id bigint primary key references characters on delete cascade,
  world_id smallint not null references worlds, lease_id uuid not null,         -- only changes on claim (§5.3)
  zone_instance_id uuid references zone_instances on delete set null,           -- null: free
  claimed_by uuid not null,                                                     -- the instance that claimed; does not change on release
  session_id bigint references sessions on delete set null,                     -- the ticket's session: revoking it kicks the character
  expires_at ts, last_seq bigint not null default 0, last_save_hash bytea,      -- SHA-256 of the last body applied (§7.3)
  last_save_version bigint not null default 0,                                  -- the save_version that Apply returned (§7.3)
  claimed_at now_ts, released_at ts);
create index on character_leases (zone_instance_id) where zone_instance_id is not null;
create sequence uid_block_seq start 1 increment 1024;                          -- uid and op_id (progression.md §4.5)
create table id_blocks (first_id bigint primary key,                           -- [first_id, first_id + 1023]
  zone_instance_id uuid not null references zone_instances on delete cascade, granted_at now_ts);  -- dropped by the retention job of §11.1

-- 0004_war
create table fortresses (world_id smallint not null references worlds, fortress_id text not null, zone_id text not null,
  record jsonb not null, version bigint not null default 0, updated_at now_ts, updated_by uuid references zone_instances on delete set null,
  primary key (world_id, fortress_id));
create table fortress_events (id bigint generated always as identity primary key, world_id smallint not null references worlds,
  fortress_id text not null, event smallint not null check (event between 1 and 7), realm smallint not null check (realm between 0 and 3),
  at ts not null, zone_instance_id uuid references zone_instances on delete set null, event_key text not null unique);
create table realm_resources (world_id smallint not null references worlds, realm smallint not null check (realm between 1 and 3),
  resource text not null, amount bigint not null default 0 check (amount >= 0), primary key (world_id, realm, resource));  -- phase 7

-- 0005_social
create table chat_messages (id bigint generated always as identity primary key, world_id smallint not null references worlds,
  zone_id text not null, zone_channel smallint not null,                        -- the copy: the instance's channel
  channel smallint not null, sender_character_id bigint not null, sender_account_id bigint not null,
  target_character_id bigint, text text not null check (length(text) <= 255), sent_at ts not null, message_key text not null unique);
create index on chat_messages (sent_at); create index on chat_messages (sender_character_id, sent_at);
create table ignores (account_id bigint not null references accounts on delete cascade,
  ignored_account_id bigint not null references accounts on delete cascade, ignored_character_id bigint,
  ignored_name text not null, created_at now_ts, primary key (account_id, ignored_account_id));
create table reports (report_id bigint generated always as identity primary key, world_id smallint not null references worlds,
  reporter_account_id bigint references accounts on delete set null, reporter_character_id bigint,
  target_account_id bigint references accounts on delete set null, target_character_id bigint, target_name text not null,
  category text not null check (category in ('language','harassment','cheating','bot','offensive_name','other')),
  comment text not null default '' check (length(comment) <= 500), context jsonb not null,             -- zone, position, tick
  status text not null default 'open' check (status in ('open','in_review','actioned','dismissed')),
  handled_by bigint references accounts on delete set null, resolution text, created_at now_ts, closed_at ts);
create index on reports (status, created_at); create index on reports (reporter_account_id, created_at);
create table report_evidence (report_id bigint not null references reports on delete cascade, seq smallint not null,
  sender_name text not null, channel smallint not null, text text not null, sent_at ts not null, primary key (report_id, seq));
create table sanctions (sanction_id bigint generated always as identity primary key, account_id bigint not null references accounts on delete cascade,
  world_id smallint references worlds, character_id bigint, kind text not null check (kind in ('warning','mute','suspension','ban','rename')),
  reason text not null, author_account_id bigint references accounts on delete set null, starts_at now_ts, ends_at ts,  -- null: permanent
  revoked_at ts, revoked_by bigint references accounts on delete set null, created_at now_ts);
create index on sanctions (account_id) where revoked_at is null;
create table sanction_reports (sanction_id bigint not null references sanctions on delete cascade,
  report_id bigint not null references reports on delete cascade, primary key (sanction_id, report_id));
create table audit_log (id bigint generated always as identity primary key, world_id smallint,                   -- no foreign keys
  source text not null check (source in ('zone','console','platform','cli')), actor_account_id bigint, actor_character_id bigint,
  zone_id text, command text not null, target_account_id bigint, target_character_id bigint, args jsonb not null default '{}',
  at now_ts, event_key text unique);
create index on audit_log (at); create index on audit_log (target_character_id, at);
create index on audit_log (target_account_id, command, at);                    -- S2: the set-role of §9.1

-- 0006_privacy
create table purge_log (kind text not null check (kind in ('account','character')), id bigint not null, purged_at now_ts,
  primary key (kind, id));                                                      -- no personal data (§11.2)
create table sanctioned_email_hashes (hmac bytea primary key, until ts not null);  -- HMAC-SHA256 of the email (§11.2)
```

- `0010_progress` belongs to progression.md: its DDL is only in its §3.3 and is written by its P7, with the `.down.sql`
  and the preservation seed. Later progress migrations take the next free number (§2.4).
- Each `.down.sql` undoes its `.up.sql` in reverse order.
- **The append-only progress tables** reach `characters` through `op_participants`, with a foreign key **without
  cascade** (progression.md §3.3): a `delete from characters` with ledger entries fails, never halfway. That is why the
  character is not deleted when purged: it stays as a tombstone (§11.2) until retention empties its ledger. The
  `eldmark.retention_purge` flag of the `eldmark_append_only` trigger is not a security barrier (any role can set it):
  it only prevents accidental deletions. It is set with `set local` and does not outlive the transaction (verified).

## 4. Public API (client ↔ platform)
### 4.1 Conventions
- HTTPS and JSON in UTF-8, `/v1` prefix, body of 16 KB at most (413). Unknown fields: 400.
- Headers: `Authorization: Bearer <access>`, `X-Eldmark-Protocol: <PROTOCOL_VERSION>`, `X-Eldmark-Build: <build
  id>`. Without a protocol or below `ELDMARK_MIN_PROTOCOL`: 426.
- **Every `bigint` id travels as a decimal string**, in both APIs (public and internal), also in the claim and in the
  save: `character_id`, `account_id`, `actor_account_id`, `ignored_account_ids`, `ticket_id`, `uid`, `op_id`,
  `ref_op_id`, `ref_id`, `seed`, `entry_id`, `report_id`, `sanction_id` and the `first` of an id block. Godot's
  `JSON.parse_string` reads every number as a `float` and silently corrupts anything above 2^53 (verified:
  `8152839359930207727` → `8152839359930208256.0`). Quantities, balances, XP, realm points, level, `seq`, `currency`,
  `reason`, `kind`, `world_id` and Unix dates (all < 2^53) travel as numbers. Ticket and appearance, in standard
  base64. This way a bug fails loudly instead of corrupting silently.
- **Realms.** In the public API (`/v1`: bodies, responses and errors such as `realm_locked`), the text id
  (`"vardheim"`, as in `ELDMARK_OPEN_REALMS`); in the internal one (registration, claim, batches), the numeric code of
  `NetProtocol.Realm` (1–3). The platform converts at the boundary; inside (`ValidateCreate`, the database) it is the
  code.
- **Integers sent by Godot.** When it serializes again what it read, Godot writes `820.0` (verified). In Go, every
  integer field uses `jsonx.Int` (accepts `4` and `4.0`; rejects `4.5` and anything above 2^53) and every id
  `jsonx.ID` (decimal string from 0 to 2^63 − 1; an unquoted number is 400). Verified with Go 1.24.7 and
  `DisallowUnknownFields`. In a string no precision is lost: Go reads it with `strconv.ParseInt` and Godot with
  `String.to_int()` (int64), so the 63-bit `ticket_id` (§5.1) travels whole. The 2^53 − 1 cap on progress ids is a rule
  of progression.md (§3.4, S1), not of `jsonx`. In GDScript, whoever writes a body puts each id through `str()`, and
  whoever reads one requires a string (`is_valid_int()`), converts it with `String.to_int()` and converts each integer
  with `int()`.
- Error: `{"error": {"code": "name_taken", "message": "Ese nombre ya está en uso", "retry_after_s": 0, "fields":
  {"name": "taken"}}}`. The client translates by `code` (UI-04) and, if it does not know it, shows `message`. With 429
  and 503 `Retry-After` is also sent.
- **Outside `/v1`** there are only `/health`, `/ready` and the pages for the links in emails (§4.3), which speak HTML
  and forms, without the 426 rule.

The "Text" column is the user-facing UI text, which stays in Spanish for now.

| HTTP | `code` | When | Text |
|---|---|---|---|
| 400 | `bad_request`, `validation` | Broken JSON; missing or invalid fields (`fields`) | "Datos no válidos" |
| 401 | `unauthorized` | Missing, expired or revoked token: the client refreshes once and, if that fails, returns to the title screen | "Tu sesión ha caducado" |
| 401 | `invalid_credentials` | Wrong email or password (it does not say which, nor whether the account exists) | "Correo o contraseña incorrectos" |
| 403 | `account_suspended`, `account_banned` | Sanction (`until`, `reason`), in `enter` and in every route that does not admit the privacy session. Login does not return it: after a correct password it opens that session (§4.2) | "Cuenta suspendida hasta el …: motivo" |
| 403 | `email_unverified`, `account_pending_deletion` | Entering the world unverified (if required) or with deletion requested (login does work, so it can be cancelled) | "Verifica tu correo para entrar" · "Tu cuenta se borrará el …" |
| 403 | `terms_required` | New versions to accept (`documents`) | Acceptance screen |
| 404 | `not_found` | It does not exist or does not belong to the account | "No encontrado" |
| 409 | `name_taken` | Name in use or reserved (it does not say which) | "Ese nombre ya está en uso" |
| 422 | `name_invalid` | `reason`: `too_short`, `too_long`, `has_space`, `has_digit`, `invalid_character`, `not_capitalized`, `reserved` (also the blacklist) | `NameRules.reason_text` |
| 409 | `realm_locked` · `realm_closed` | A realm other than the account's (`realm`, `unlock_at`) · outside `ELDMARK_OPEN_REALMS` | "Tu cuenta es de Vardheim" · "Ese reino abre más adelante" |
| 409 | `slots_full` · `rename_required` | No free slots · forced rename | "No te quedan huecos" · name dialog |
| 409 | `character_busy` | Live lease (`retry_after_s` = 3) | "Tu personaje está saliendo del mundo…" |
| 426 | `client_outdated` | Old protocol (`min_protocol`) | "Actualiza el cliente" |
| 429 | `rate_limited` | Rate limit, also password failures (§4.2) (`retry_after_s`) | "Demasiados intentos; espera N s" |
| 503 | `maintenance` · `zone_unavailable` | Maintenance (`message`, `until`) · no live instance of the zone | The message · "La zona no está disponible" |
| 500 | `internal` | Any other failure (with `X-Request-Id`) | "Error del servidor" |

There is no `email_taken` or `account_locked`: both would reveal which emails have an account (§4.2).

### 4.2 Accounts and sessions (TEC-23)
| Route | Body | Response |
|---|---|---|
| `GET /v1/status` (no token) | — | `{status: "ok"\|"maintenance", message, maintenance_at, min_protocol, worlds: [{world_id, name, status, load: "low"\|"medium"\|"high"}], news: [{title, body, date}]}` |
| `GET /v1/legal` · `GET /v1/legal/{kind}` (no token) | — | `{terms: {version, sha256}, privacy, rules}` · the current Markdown text |
| `POST /v1/accounts` | `{email, password, age_confirmed: true, accept: {terms, privacy, rules}, consents: {crash_reports, analytics}}` | **Always 202 `{}`** if the body is valid (see below) |
| `POST /v1/sessions` | `{email, password}` | `{access_token, access_expires_in, refresh_token, refresh_expires_in, scope, restriction, account}`; `scope` is `"game"` or `"privacy"`, and `restriction` is null or `{code, until, reason}` (below) |
| `POST /v1/sessions/refresh` · `DELETE /v1/sessions/current` | `{refresh_token}` · — | A new pair (the old one stops working) · 204 |
| `GET /v1/account` | — | `{account_id, email, email_verified, role, realms: {"1": "vardheim"}, slots, consents, pending: {terms_required, deletion_at}}` |
| `POST /v1/account/accept` · `PUT /v1/account/consents` | `{terms, privacy, rules}` (versions) · `{crash_reports, analytics}` | 204 |

- **Registration without revealing accounts.** `POST /v1/accounts` answers 202 `{}` and the client says "Te hemos
  enviado un correo" (we have sent you an email). New email: creates the account and sends `verify_email`. Email that
  already has an account: creates nothing and sends `register_existing` ("Ya tienes una cuenta: ¿has olvidado la
  contraseña?", i.e. you already have an account: forgot your password?). Email in `sanctioned_email_hashes` (§11.2):
  creates nothing and sends `register_blocked` ("No se puede crear una cuenta con este correo hasta el …", i.e. an
  account cannot be created with this email until …). The three paths count against the same email limit and take the
  same time (the password hash is computed on all three). Logging in does not require a verified email; entering the
  world does, with `ELDMARK_REQUIRE_VERIFIED_EMAIL`.
- **Email:** lowercase and with no surrounding whitespace; 3–254 B; `net/mail.ParseAddress` returns it unchanged (no
  display name); printable ASCII only, with no spaces or control characters (`^[\x21-\x7e]+$`); a single `@`; domain
  with at least one dot and no `xn--` labels (IDNs are rejected in phase 5); unique. A CR, LF or space inside gives 400
  `validation`. Emails are built with encoded headers (`mime.QEncoding`) and the recipient goes in `RCPT TO` and in an
  encoded `To:`: there is no header injection.
- **Password:** 10 to 128 characters (512 B at most), different from the email, not normalized. `passwords.Verify`
  reports `needsRehash` if the PHC string's parameters are not the current ones, and login rewrites it. At most
  `runtime.NumCPU()` computations at a time (19 MiB each). With a non-existent email a dummy hash is computed: timing
  does not reveal accounts.
- **A single function checks passwords:** `accounts.CheckPassword(ctx, accountID, email, password, ip) (ok bool, err
  error)`, with `accountID` 0 for a non-existent email and `email` the normalized one. Login and the routes with a
  session that ask for a password (`/v1/account/password`, `/email`, `/deletion`, `/export`, which pass the account's
  current email) use it, with the same counters. **Attempts on the same key go one at a time:** the throttle is
  checked, the password is verified and the failure is recorded with the key's turn taken, so N simultaneous attempts
  count as N consecutive ones. Without the turn, all of them passed the check before the first failure was recorded,
  and the 30 s throttle and the group lockout admitted bursts.
- **Password failures** (in memory; a single instance in phase 5; LRU of 100 000 keys). The account key is computed by
  `CheckPassword`: the `account_id` if it is not 0 or, if the email does not exist, the SHA-256 of the normalized
  email. This way every non-existent email has its own counter and throttling one does not reveal the others:

| Key | Rule |
|---|---|
| Account and IP group | 5 consecutive failures → 15 min with no attempts from that group; 10 → 1 h |
| Account, from any IP | After 5 consecutive failures, one attempt every 30 s |
| Success | Resets both for that account |
| Response when throttling | 429 `rate_limited` with `retry_after_s`; the same whether or not the account exists |
| Notice | On the 5th consecutive failure, `login_failures` email to the owner (at most one every 24 h) |

  This way 5 attempts from one IP do not lock the owner out from theirs (TEC-23: the temporary lockout is per account
  and IP group).
- **Account state:** with a wrong password, `invalid_credentials`, whether or not the account is sanctioned; a `purged`
  account answers like a non-existent email. With a correct one, a suspended or banned account receives a **privacy
  session** (`scope: "privacy"`, in the response and in `sessions.scope`, with `restriction: {code:
  "account_suspended"|"account_banned", until, reason}`). It only admits `GET /v1/account`, `POST /v1/account/export`,
  `POST` and `DELETE /v1/account/deletion`, `POST /v1/sessions/refresh` and `DELETE /v1/sessions/current`; any other
  route, `enter` included, gives 403 with that `code`, and without `enter` there is no ticket or claim. This way
  exporting and requesting erasure (§11.2) do not depend on not being sanctioned. Refresh keeps the `scope`.
- **Single game session:** logging in revokes the account's other sessions (`revoke_reason = 'replaced'`) and the
  heartbeat kicks their character (§6). In addition, only one character of the account can be in the world (§4.5,
  §5.3).
- **Tokens:** 32 B from `crypto/rand` in unpadded base64url (43 characters); in the database, their SHA-256. One
  `sessions` row per login, with `refresh_expires_at` = login + 12 h, **absolute**. 15-minute access token, never
  beyond `refresh_expires_at`.
- **Refresh**, in one transaction:
  1. `update sessions set prev_refresh_hash = refresh_hash, refresh_hash = $new, access_hash = $new_access,
     access_expires_at = least(now() + 15 min, refresh_expires_at), rotated_at = now() where refresh_hash = $given
     and revoked_at is null and refresh_expires_at > now()`.
  2. No row and `prev_refresh_hash = $given` on a live session: it is revoked with `revoke_reason = 'refresh_reuse'`,
     a row in `auth_events` and 401. No row in any other case: 401.
  - `session_id` does not change during the whole session: the lease of §5.3 stays tied to it and refreshing
    mid-game does not kick. A refresh from two rotations ago gives 401 without revoking (it is no longer
    distinguishable from a made-up one).
  - `PlatformApi` does a single refresh at a time (§14.4): two simultaneous refreshes from the client itself are not
    mistaken for reuse.
- **Acceptance:** registration requires the current versions of the three texts. With a new version, `GET
  /v1/account` says so and `enter` answers `terms_required` until it is accepted.
- **Client IP.** Caddy sets `header_up X-Real-IP {remote_host}`. The platform reads **only** `X-Real-IP` and only if
  the connection comes from `ELDMARK_TRUSTED_PROXIES`; otherwise, the connection's IP. Never `X-Forwarded-For`. IPv6
  counts by /64, like `ServerAuth.address_group`.

| Limit | Value | Where |
|---|---|---|
| Login · registration, per IP | 10/min, burst 10 · 3 per hour | Memory (token bucket) |
| Failed passwords | Table above (also on routes with a session) | Memory |
| Emails (verification, recovery, change, registration) · data export | 3 per account and hour and 10 per IP and hour · 1 per day | Memory and `auth_events` |
| Check name · enter the world | 30/min per session · 10/min per account | Memory |
| Create character · delete character | 5 per account and day each | `auth_events` (`character_create`, `character_delete`) |

`auth_events.kind`: `register`, `register_existing`, `login_ok`, `login_fail`, `login_throttled`, `password_fail`,
`refresh_reuse`, `character_create`, `character_delete`, `export`, `email_changed`, `email_reverted`,
`password_reset` (with the account or, without one, with a null `account_id`).

### 4.3 Lifecycle (TEC-41)
| Route | Body | Effect |
|---|---|---|
| `POST /v1/account/verify-email` (no token) · `…/verify-email/resend` | `{token}` · — | Verifies · 202, new email; the previous ones stop working |
| `POST /v1/account/password-reset` (no token) | `{email}` | **Always 202**, whether or not the account exists, and without waiting for the database: after the email limit, looking up the account, storing the link and sending it continue in the background (both paths leave their `password_reset` row in `auth_events`). This way timing does not reveal which emails have an account either |
| `POST /v1/account/password-reset/confirm` (no token) | `{token, new_password}` | Changes it, revokes all sessions (`password_changed`) and invalidates the links |
| `POST /v1/account/password` | `{current_password, new_password}` | `CheckPassword`; changes it, revokes the other sessions (`password_changed`) and invalidates the links |
| `POST /v1/account/email` | `{new_email, password}` | `CheckPassword`; **always 202**. To the new address, `change_email` (or `register_existing` if it already has an account) |
| `POST /v1/account/email/confirm` (no token) | `{token}` | Changes it and marks the new one as verified; revokes the other sessions (`email_changed`), invalidates the links and sends the **old** address a notice with a `revert_email` link |
| `POST /v1/account/email/revert` (no token) | `{token}` | Restores the old email, revokes all sessions (`email_reverted`), sets `password_hash = null` and sends the old email a recovery link |
| `POST /v1/account/deletion` · `DELETE /v1/account/deletion` | `{password}` · — | `CheckPassword`; 202 `{purge_at}` (+14 days; revokes the other sessions) · 204, cancels within the grace period |
| `POST /v1/account/export` | `{password}` | `CheckPassword`; downloadable JSON (§11.2) |

- Single-use links in `account_tokens` (SHA-256 of the token): 24 h to verify or change the email, 1 h to recover,
  **7 days** for `revert_email`. Used or expired: 400 `validation` with `fields.token = "used"` or `"expired"`, and
  nothing changes.
- **Invalidating the links** means, in the same transaction as the change: `update account_tokens set used_at = now()
  where account_id = $1 and used_at is null and purpose <> 'revert_email'`. `revert_email` links are not invalidated
  this way: whoever stole the account cannot take the way back away from the owner by changing the email again.
- **A chain of changes.** Spending a `revert_email` voids, in the same transaction, the account's links issued after
  it (greater `created_at`; within one account it never repeats: a new one comes at least 1 µs after the previous
  one). Someone who knows the password and changes the email twice (A→B→C) receives a `revert_email` at B; the
  owner's, the one that arrived at A, is always the oldest, so spending it kills B's, and B's, spent earlier, does not
  touch A's. Without this rule, B's, alive for 7 days, returned the account to the thief after the owner had
  recovered it.
- **The old email stays reserved** while its `revert_email` lives (unused and unexpired): a registration or another
  account's email change towards it gets the same as towards an email that has an account (`register_existing`), and a
  pending `change_email` towards it, from another account, is not valid (`fields.token = "unavailable"`). Otherwise a
  new unverified account with that email blocked the way back until the link expired.
- An account with a null `password_hash` cannot log in (`invalid_credentials`, with the dummy hash) until the password
  is recovered.
- **Unverified accounts:** in `staging` and `production`, an account without `email_verified_at` 7 days after its
  creation is purged (§11.2) by the hourly job.
- **Link pages.** Emails link to `ELDMARK_PUBLIC_URL/verify?token=…`, `/reset?token=…` and `/revert?token=…`. `GET`
  serves a minimal HTML form (`html/template`, no JavaScript or CSS) that does a `POST`
  `application/x-www-form-urlencoded` to the same route (`/verify`, `/reset`, `/revert`), with the token in a hidden
  field. The response is HTML ("Correo verificado. Ya puedes cerrar esta página", i.e. email verified, you can close
  this page). The token is validated (43 base64url characters) **before** rendering it; if invalid, the page says
  "Enlace no válido" (invalid link) without repeating it. Headers: `Referrer-Policy: no-referrer`, `Cache-Control:
  no-store`, `Content-Security-Policy: default-src 'none'; form-action 'self'`, `X-Frame-Options: DENY`. Internally
  they call the same functions as `/v1`.
- With `ELDMARK_MAIL=log`, the email goes to `outbound_mail` and to the log with the full link: this is how tests get
  the token. In `staging` and `production`, `log` does not start.

### 4.4 Characters and names (TEC-24, SOC-13)
| Route | Body | Response |
|---|---|---|
| `GET /v1/worlds/{w}/characters` | — | `{realm, unlock_at, slots, used, characters: [{character_id, name, realm, race_id, appearance, level, last_zone_id, played_seconds, created_at, deleted_at, restore_until, must_rename}]}`; from `characters` and, for race, appearance, level, last zone and played time, `ProgressStore.Summaries` |
| `GET /v1/worlds/{w}/name-check?name=…` | — | `{available, code, reason}` |
| `POST /v1/worlds/{w}/characters` | `{name, realm, race_id, appearance, starter_template_id}` | 201 `{character}` |
| `DELETE /v1/characters/{id}` | `{confirm_name}` | `{restore_until}`; `confirm_name` with the same NameRules key as the name |
| `POST /v1/characters/{id}/restore` | — | 200 within the grace period, with the name free |
| `POST /v1/characters/{id}/rename` | `{name}` | Only with `must_rename`; the old one stays reserved for 30 days |
| `POST /v1/characters/{id}/enter` | — | §4.5 |

**Game data: a single file**, `platform/internal/gamedata/progression_rules.json`, with the rules of progression.md
§13.4: it is generated by `ProgressionRulesExport.build()`, written by `tools/progression/export_rules.gd`, checked by
a single test (`tests/test_progression_rules_export.gd`) and read with `//go:embed` (which does not read outside
`platform/`). Two sections belong to this document: `protocol_version` (`NetProtocol.PROTOCOL_VERSION`) and `names`
(`{min_length, max_length, upper_letters, lower_letters, folded, reserved}` from `NameRules`; P2 adds it); the rest
(`races`, `appearance`, `starter_templates`, `items`, `level_curve`, `currencies`, `reasons`, `containers` and
`combat`) belong to progression.md. Whoever gets there first (P2 here or progression.md P3) creates `build()`, the tool,
the test and the file; the other adds their sections. `internal/names` reads `names` and is `NameRules` in Go
(`Validate`, `NormalizeKey`, reserved names); `progress.LoadRules` reads the rest. The name test cases for both sides
come from `tests/fixtures/names/name_rules_cases.json` (`[{name, reason, key}]`), which `test_name_rules.gd` and
`internal/names` read (with `os.ReadFile("../../../tests/fixtures/names/…")`: Go tests run in the package
directory). All test data shared by Godot and Go lives under `tests/fixtures/` (the progress ones, in
`tests/fixtures/progression/`, progression.md §13.2).

**Create**, in a `serializable` transaction (retry on 40001):

1. Active account with no pending deletion; `realm` in `ELDMARK_OPEN_REALMS` (otherwise, `realm_closed`); fewer than 5
   `character_create` in 24 h (otherwise, 429).
2. `account_realms`: with no row, or with `unlock_at ≤ now()` and no living character, this realm is set; if the
   account has another one, `realm_locked`.
3. Slots: 6 + the `quantity` of the current `character_slots`. **Living characters and those deleted within the grace
   period take up a slot** (the ones that can still be restored).
4. Name: `names.Validate` (422), blacklist (422 `reserved`; edited by `admin --actor <email> names block|unblock
   <name>`, §9.1) and `insert into character_names` with `status 'active'`. A current `reserved` row gives
   `name_taken`; an expired one is reused. Two creations at the same time with the same name: one fails with 23505 on
   `character_names_pkey` (verified in a probe with the same key) → `name_taken`.
5. Race, appearance and template: `persistence.CreateValidator.ValidateCreate(realm, race_id, appearance,
   starter_template_id)` (§7.5; the rule, progression.md §13.2): `race_id` of its realm (`race_vardheim`…), **8 B**
   appearance valid for its race (the rule of `CharacterAppearance.validate`, progression.md §7.2) and
   `starter_template_id` from `starter_templates` (the `selectable` templates). Otherwise it returns
   `*persistence.ValidationError` and the response is 400 `validation` with its `fields` (`{"race_id":
   "wrong_realm"}`, `{"appearance": "invalid"}`, `{"starter_template_id": "not_selectable"}`). `serve` picks the
   implementation: until progression.md P3 and P7 exist, the provisional one from P2 (`race_id = "race_" + realm`, any
   8 B and a template matching `^[a-z0-9_]{1,32}$`; the zone corrects an invalid appearance on load, progression.md
   §7.2); afterwards, `*progress.Rules`.
6. `insert` into `characters` and `character_pvp_stats`, and `ProgressStore.Create` (§7.5) with the race, the
   appearance and the template; `auth_events` `character_create`.

**Delete**, in a transaction that first locks the account row (`select … from accounts where account_id = $1 for no
key update`, the claim's order, §5.3, and that of the account purge): with a live lease, `character_busy`; 5
`character_delete` in 24 h, 429. This way deletion and the claim for that character go in series: it ends up deleted
and without a lease or alive and with one, never deleted and in the world. `deleted_at = now()`, `restore_until =
now() + 7 d` and the name `reserved` until `restore_until + 30 d`. **Exception:** a character less than 24 h old and
with less than 1 h played (`PlayedSeconds < 3600` from `Summaries`) reserves the name only until `restore_until`.
When `restore_until` expires, the hourly purge leaves it as a tombstone (§11.2); the name stays reserved for as long
as applies. If it was the last living one, `unlock_at = now() + 30 d`.

**Restore**, likewise, locks the account row and then the `characters` one (`for no key update`, like the purge) and
checks again that `restore_until > now()` and `purged_at` is null: a restore at the limit and the hourly purge do not
cross paths (§11.2).

### 4.5 Entering the world
`POST /v1/characters/{id}/enter`, no body. It checks in order: session, maintenance (503), sanctions (403), pending
deletion (403), texts to accept (403), verified email if required (403), living character of the account (404),
`must_rename` (409), live lease of that character **or of another character of the account in that world** (409
`character_busy`: a single character in the world per account; the claim checks again, §5.3). It picks the zone: the
last one (`LastZoneID` from `ProgressStore.Summaries`) if it has a `live` instance whose `realms` includes the
character's realm (in its `LastChannel` if alive and with room); otherwise, the entry zone of its realm. Within the
zone, the channel with the fewest players below `max_players`; if none is live, 503 `zone_unavailable`. It inserts the
ticket into `enter_tickets` (10 s) and responds:

```json
{"zone": {"zone_id": "vado_gris", "channel": 0, "host": "203.0.113.5", "port": 24600,
          "dtls": {"cert_pem": "-----BEGIN CERTIFICATE-----…", "name": "vado-gris.eldmark"}},
 "ticket": "AQEBAAgHBgUEAwIBKgAAAAAAAAATwO8ZAAEAAQDSSWsK0klrcGHi9UqxoJb2YCRDcSPZ0Q==",
 "expires_in_s": 10, "character": {"character_id": "42", "name": "Aneira", "realm": "vardheim"}}
```

`dtls` is `null` if the zone does not use DTLS (only in `dev` and `test`, §10.2). The client connects right away; if
the ticket expires, it asks for another.

## 5. Ticket and entering the zone (TEC-24)
### 5.1 Ticket format (52 B, little-endian)
Replaces the 47 B one in networking.md §12: it adds the world and replaces the text zone with a 4 B fingerprint. It goes in
the HELLO's `ticket` field (≤ 256 B). It carries identity only: in a handoff (phase 6), everything else (CMB-30
included) arrives with the origin's final save and the claim at the destination (progression.md §8).

| Offset | Type | Field | Notes |
|---|---|---|---|
| 0 | u8 | version | 1 |
| 1 | u8 | key_id | key from `ELDMARK_TICKET_KEYS` (1–255) |
| 2 | u16 | world_id | |
| 4 | u64 | ticket_id | random, bit 63 at 0; key of `enter_tickets`; in JSON, a string up to 2^63 − 1 (§4.1) |
| 12 | u64 | character_id | same as `HELLO.character_id` |
| 20 | u32 | zone_key | the first 4 bytes, as u32 LE, of the SHA-256 of the zone's ASCII id |
| 24 | u8 | channel | |
| 25 | u8 | realm | `NetProtocol.Realm` code; informative (the claim decides) |
| 26 | u8 | arrival | 0 = the zone decides; n ≥ 1 = point n − 1 (handoffs, phase 6) |
| 27 | u8 | flags | bit0 entry from the menu; bit1 handoff (phase 6); rest 0 |
| 28 | u32 | issued_at | Unix, s |
| 32 | u32 | expires_at | `issued_at + 10` |
| 36 | 16 B | mac | HMAC-SHA256(key, bytes 0..35), first 16 bytes |

**Test vector** (Go and GDScript give the same result, verified): key `00 01 … 1f`, world 1, `ticket_id`
`0x0102030405060708`, character 42, `vado_gris` (`zone_key` `0x19efc013`), channel 0, realm 1, `arrival` 0, `flags` 1,
`issued_at` 1800000000 and `expires_at` 1800000010:

```
0101010008070605040302012a0000000000000013c0ef190001000100d2496b0ad2496b7061e2f54ab1a096f66024437123d9d1
```

That key is only valid in tests: outside `test`, the configuration rejects it in the platform and in the zone (§2.3).
GDScript: `HMACContext` with `HASH_SHA256`, `"vado_gris".sha256_buffer().decode_u32(0)` and
`Crypto.constant_time_compare`. Go: `crypto/hmac` and `hmac.Equal`.

### 5.2 Checks in the zone
`TicketAuthProvider.authenticate(peer_id, hello)`, synchronous and with no network; any failure is REJECT `TICKET` and
nothing reaches the platform:

1. Size 52 and `version` 1; known `key_id`; correct `mac` in constant time.
2. `world_id`, `zone_key` and `channel` of this zone ("billete de otra zona", i.e. ticket from another zone).
3. `issued_at ≤ now + 5` and `now ≤ expires_at + 5`, with "now" corrected by the platform's clock (§6).
4. `character_id` equal to the HELLO's.
5. `ticket_id` not seen in the last 30 s ("reutilizado", i.e. reused).

Before step 1, a **fenced** zone (§5.3) answers REJECT `UNAVAILABLE`. If it passes, it returns `PENDING`: the peer
moves to the new state `ServerPeer.State.VERIFYING` and the zone requests the claim (`POST /internal/v1/claims`),
which truly guarantees **single use** and takes the lease.

- **Capacity.** `ZoneServer.get_player_count()` counts `VERIFYING`, `LOADING` and `IN_WORLD` (and the fake ones):
  several simultaneous entries do not exceed `max_players`. When the 200 arrives, if the count (including it) exceeds
  `max_players`, REJECT `FULL` and `release`.
- **Real-time deadline.** `VERIFY_TIMEOUT_MS = 7000` from when the peer connected (`peer_authenticating`;
  `ServerPeer.connected_at_msec` with `Time.get_ticks_msec()`, only in `scripts/server/`), checked every tick. A
  deadline in ticks got out of step when the server fell behind.
- **`auth_timeout` of 10 s.** `SceneMultiplayer` cuts off after `auth_timeout` seconds **from the connection, on both
  sides**, not from the HELLO. Verified with `GuardedEnetPeer` on the server: with 5 s, HELLO at 1.4 s and response at
  4.0 s, it gets in; with 10 s, HELLO at 1.5 s and response at 8.5 s, it gets in; response at 10.5 s, the client drops
  at 10 s. `NetTransport.AUTH_TIMEOUT_SECONDS` goes from 5 to 10 in the phase 5 protocol bump (§5.4), so the REJECT at
  7 s always arrives. The HELLO's 90 ticks (networking.md §3) still apply in `AUTHENTICATING`.

The result is applied in the "poll" step of the tick (§14.3):

| Claim | The zone |
|---|---|
| 200 | In order: (1) the zone admits `claimed.realm` (otherwise, `REALM`); (2) it fits under `max_players` (otherwise, `FULL`); (3) `ProgressService.prepare(peer_id, claimed)` (progression.md §9.1: decodes, validates the appearance and creates the `PlayerProgress`) and, if it returns false, `UNAVAILABLE` with "No se ha podido cargar el personaje" (`AuthOutcome.text`, i.e. the character could not be loaded) and an alert in the log; if any step fails, `release(character_id, lease_id)`. (4) WELCOME with `claimed.realm`, `complete_auth` and `LOADING` |
| 409 `ticket_invalid` (consumed, expired, from another instance or from a revoked session) | REJECT `TICKET` |
| 409 `character_busy` | REJECT `BUSY` |
| 403 `account_blocked` (suspended, banned, pending deletion) | REJECT `BANNED` with the body's `message` (§6.1) |
| 409 `instance_lost`, `instance_replaced` or `instance_stopped` | REJECT `UNAVAILABLE` and the shutdown of §6.1 |
| Any other (409 `instance_not_live`, another 4xx, 5xx), offline, or 7 s from the connection with no response | REJECT `UNAVAILABLE` (a 4xx, with an alert in the log); if the claim arrives later, it is released |

**Drop in `LOADING`.** Between WELCOME and CLIENT_READY the character has a lease and a prepared `PlayerProgress`, but
no body or entry in `CharacterSaver`. If the peer leaves `LOADING` without reaching the world (CLIENT_LEAVE,
disconnection, the CLIENT_READY deadline, a kick or a heartbeat `revoked`), the zone calls
`ZonePlatform.release(character_id, lease_id)` without saving and `ProgressService.cancel_prepared(peer_id)`
(progression.md §9.1); a `revoked` kicks with its NOTICE and no final save, which does not exist here.

### 5.3 Lease
The claim, in one transaction: it locks the account row and checks its state and its sanctions, checks the character
(`deleted_at` and `purged_at` null and from the instance's world; otherwise, 409 `ticket_invalid`), locks the ticket
(if invalid, 409 `ticket_invalid`) and **only then**, with the account suspended, banned or with deletion requested,
answers 403 `account_blocked`: without a valid ticket for that character and that instance, nothing about the account
is known (neither the reason nor the date of a sanction, in this world or another). Otherwise, it consumes the
ticket, checks that no other character of the account is in the world, takes the lease and, after the `insert …
on conflict`, reads the `progress` section with `ProgressStore.Load` in the same transaction (with the lease row
locked, no save can interleave). The lock order is account → ticket → lease; purging an account also locks its row
first (§11.2). Verified on PostgreSQL 16, except steps 0 and 2:

```sql
-- 0. The character's account ($8): serializes claims for the same account
select status from accounts where account_id = $8 for no key update;   -- and its sanctions, without answering yet
-- 1. The ticket: from this instance, unused, unexpired and from an unrevoked session
select t.session_id from enter_tickets t join sessions s on s.session_id = t.session_id
where t.ticket_id = $1 and t.character_id = $2 and t.zone_instance_id = $3 and t.consumed_at is null
  and t.expires_at > now() - interval '5 s' and s.revoked_at is null
for update of t;                            -- no row: ticket_invalid and rollback
-- (account blocked: now the 403 account_blocked and rollback; otherwise:)
update enter_tickets set consumed_at = now() where ticket_id = $1;
-- 2. A single character in the world per account and world
select 1 from character_leases l join characters c using (character_id)
where c.account_id = $8 and c.world_id = $4 and l.character_id <> $2
  and l.zone_instance_id is not null and l.expires_at > now();   -- with a row: character_busy and rollback
-- 3. The lease ($5 = session_id, $6 = new lease_id from crypto/rand, $7 = TTL)
insert into character_leases (character_id, world_id, lease_id, zone_instance_id, claimed_by, session_id, expires_at)
values ($2, $4, $6, $3, $3, $5, now() + $7)
on conflict (character_id) do update set lease_id = excluded.lease_id, zone_instance_id = excluded.zone_instance_id,
  claimed_by = excluded.claimed_by, session_id = excluded.session_id, expires_at = excluded.expires_at,
  last_seq = 0, last_save_hash = null, claimed_at = now(), released_at = null
where character_leases.zone_instance_id is null or character_leases.expires_at < now()
returning lease_id;                         -- no row: character_busy and rollback (the ticket is not left consumed)
```

- **Heartbeat** every 5 s, with its own slot (§6): `characters: [{character_id, lease_id}]`, the set that
  `ZonePlatform` maintains (§14.3). A character enters with the 200 of its claim, changes `lease_id` with another
  claim of its own and leaves with `release()` or with the definitive answer (200 or definitive) to a save with
  `release_lease`, if it is still that `lease_id`. This covers `LOADING`, the world, the body after a combat logout
  and the pending final save, and stops sending heartbeats for whoever has already left. Those in `VERIFYING` are not
  included: they have no `lease_id` yet. It renews only what matches and is still alive (an expired one is already
  considered free by the claim, `enter` and deletion; renewing it left two characters of the account in the world, or
  a deleted one inside):

  ```sql
  update character_leases l set expires_at = now() + $4
  from unnest($2::bigint[], $3::uuid[]) as h(character_id, lease_id)
  where l.character_id = h.character_id and l.lease_id = h.lease_id and l.zone_instance_id = $1
    and l.expires_at > now()
  returning l.character_id;                 -- the missing ones come back in revoked with reason lease_lost
  ```

  Those not in the list expire on their own (TTL 30 s). Each `revoked` entry carries its `lease_id` (§6).
- **Fencing.** Without an accepted heartbeat in 2 × `HEARTBEAT_S` (10 s), the zone is fenced until the next one: it
  admits no HELLO (REJECT `UNAVAILABLE`) and no operations that require a critical save (GM commands that change
  something, progression.md §10, and in phase 6 trade and mail: "El servicio de cuentas no responde; inténtalo más
  tarde", i.e. the accounts service is not responding, try again later). It kicks nobody: the game goes on and §7.4
  applies.
- **Lost instance:** 15 s (3 × `HEARTBEAT_S`) without a heartbeat → `lost` and its leases freed
  (`zone_instance_id = null`; `lease_id` and `claimed_by` stay). After a `kill -9`, the character can re-enter within
  15 s at most. If the instance comes back, §6.1.
- **New instance of the same zone and channel.** If the old one sent a heartbeat less than 3 × `HEARTBEAT_S` ago,
  registration gives 409 `instance_alive` unless `"replace": true` (`--replace`), which leaves a row in `audit_log`.
  A zone without `--replace` retries every 2 s for 60 s and then exits with code 1. If the old one has gone 3 ×
  `HEARTBEAT_S` or more without a heartbeat but is still `starting` or `live` (the lost-instances job has not run
  yet), registration, in its transaction, moves it to `lost` and frees its leases like the job does, and then inserts
  the new one: it never collides with the partial unique index. When replacing, the old one becomes `replaced` and
  **its leases are not freed at that moment**: each one's final save (`release_lease`) frees them, or they expire
  with the TTL, because the old one no longer renews them (its heartbeat gives `instance_replaced`). If it was still
  alive, it performs the shutdown of §6.1 and **its final saves are valid** (§7.3); meanwhile, anyone trying to
  re-enter receives `character_busy` and the client retries, so it loads the final save and not the previous one. A
  `lost` instance does free them instantly (it may be dead); that is why the shutdown of §6.1 kicks only after
  sending the final saves.
- **Combat logout** (GUE-41): the lease lasts until the body leaves and the final save arrives. Entering during those
  15 s gives `character_busy` and the client retries on its own every 3 s for 30 s: reconnecting does not shorten the
  combat logout.
- **`lease_id` only changes on claim.** Releasing does not change it: a late save from the same instance is accepted
  if nobody has claimed the character since (§7.3).

### 5.4 Protocol changes
| Piece | Change |
|---|---|
| `PROTOCOL_VERSION` | **7**, a single bump for the whole of phase 5, shared with progression.md (4 the fort, 5 chat and groups, 6 abilities.md). The split is fixed: 5 is already in main and P4 here waits for abilities.md to bump to 6 (§14.1). It is bumped by P4, which goes before progression.md P4 in the order of §14.1, with the full line in `net_protocol.gd`: "7: phase 5 (docs/platform.md and docs/progression.md): REJECT 10–12, 52 B ticket, 10 s `auth_timeout`, bit 3 of the `flags` of the ENTITY_SPAWN header (game staff), +9 B of the PLAYER SPAWN (level and appearance), messages 0x50–0x55, ENTITY_EVENT 16 LEVEL_UP, DEBUG_COMMAND 40–43 and `ItemDatabase` in the `sim_hash`". **In networking.md, each P4 documents what its code adds**, with its rows and its "v7" mark: P4 here, "= 7" and §5.3 (REJECT 10–12, 52 B ticket, 10 s `auth_timeout`) and bit 3 of §5.5; progression.md P4, §3 (`sim_hash` with `ItemDatabase` and the new REJECT `SIM_HASH` text), §5.2 (0x50–0x55), §5.4 (DEBUG_COMMAND 40–43) and its part of §5.5 (+9 B of the PLAYER, which do not change the NPC payload; LEVEL_UP), as progression.md §12 says. progression.md P4 adds its part of the code without bumping the version |
| `NetTransport` | `AUTH_TIMEOUT_SECONDS` = 10.0 (previously 5.0), on both sides (§5.2), in the same bump |
| HELLO | **No byte changes.** With a ticket, `character_id` and `ticket` are sent; the client puts its character's values in `realm` and `name` and the zone ignores them |
| WELCOME | No byte changes; `realm` is the character's |
| REJECT | `Result` adds `BUSY = 10`, `UNAVAILABLE = 11` and `BANNED = 12` (free in all branches; if another branch takes one, the next ones). `result_text`: "Tu personaje sigue en el mundo: espera unos segundos" (your character is still in the world: wait a few seconds), "El servicio de cuentas no responde: inténtalo más tarde" and, in `BANNED`, the `message` of the 403 `account_blocked`, composed by the platform (§6.1); "Tu cuenta está suspendida" (your account is suspended) only if it is missing |
| ENTITY_SPAWN | Bit 3 of the **header** `flags` (offset 9; today bit0 "yours" and bits 1–2 teleport) = game staff (moderator or higher), for the label (SOC-14). It is not the snapshot record's `flags`, whose bit 3 is used by abilities.md |
| NOTICE | No new codes: "Has iniciado sesión desde otro lugar" (you have logged in from another place) or "Tu cuenta ha sido suspendida" (your account has been suspended) go with 1 (kick) |

With `--platform`, `--max-realm-diff` (REJECT `IMBALANCE`) does not apply: the realm is no longer chosen when
connecting (population balance belongs to GUE-36). The cooldown after a kick uses the key `character:<id>` instead of
the HELLO's name. With a ticket (`uses_tickets()`), `ServerAuth` does not compare the HELLO's name with the connected
ones, so there is no `REJECT NAME`: the HELLO no longer reveals whether a name is in the zone (the phase 4 limitation
of social.md 12.7; test in P4).

### 5.5 Startup modes
| Mode | Phase 5 |
|---|---|
| F5 in the editor with no arguments | Phase 1 sandbox, as before (`OS.has_feature("editor")`) |
| No arguments in an export · `--title [--platform=<url>]` | Title screen (UI-22) against `eldmark/platform/url` · the same from the editor |
| `--server` without `--platform` | `DevAuthProvider` as today: the HELLO's realm and name; ephemeral characters, nothing is saved (progression.md §9.4) |
| `--server --platform=<internal url>` | `TicketAuthProvider`; a HELLO without a ticket receives `TICKET` ("Entra desde el menú con tu cuenta", i.e. enter from the menu with your account). `--debug-commands`, `--fake-players`, `--fake-churn`, `--battle-log`, `--combat-log` and `--state-log` only if the registration's `env` is `dev` or `test`; otherwise the zone exits with code 1 and "Esa opción no se admite con la plataforma en staging/production" (that option is not supported with the platform in staging/production) |
| `--fake-players`, `--fake-churn` | They never touch the platform and are never saved; they are called `Bot-NN`, which is not a valid name and does not collide with any character. With the platform, the zone gives no persistent rewards (progression.md §6.2) |
| `--connect`, `--local`, `--bot --connect` · with `--dtls-cert=<pem> --dtls-name=<cn>` | The same, against zones without the platform; `RealmSelect` remains for development · with DTLS (§10.2) |
| `--bot --platform=<url> --login=<email> --password-file=<path> [--character=<name>] [--realm=…]` | `AccountFlow` (§13.3): logs in, creates the character if missing (`--character` or `NameRules.bot_name(seed)`), requests `enter` and connects. Without `--login` or `--password-file`, it exits with code 1 and a clear error |
| `--bots=N [--dtls-cert=<pem> --dtls-name=<cn>]` | Only against zones without the platform (load, and the TEC-27 measurement with DTLS); with `--platform`, it exits with a clear error |

## 6. Internal API (zone ↔ platform)

HTTP and JSON on `ELDMARK_INTERNAL_ADDR` (127.0.0.1 in development; Docker's private network on the VPS), with
`Authorization: Bearer <zone token>`.

- **One token per zone deployment.** The platform computes the SHA-256 of the token and compares it with
  `subtle.ConstantTimeCompare` against each entry of `ELDMARK_ZONE_TOKENS`; the one that matches gives its scope
  (world, zone, channel). No entry: 401 `bad_token`. Registration admits only that scope and a `public_host` from
  `ELDMARK_ZONE_HOSTS` (otherwise, 403 `forbidden`). Every other request carries `zone_instance_id` (in the body, the
  path or the query), which must be an instance of that scope (otherwise, 403 `forbidden`). In the zone,
  `ZonePlatform` (§14.3) sets it in the claim, the release, the heartbeat, the id blocks, the fortresses, the batches
  and `request`, not whoever builds the request. Saving is the exception: its whole envelope, `zone_instance_id`
  included, is built by `CharacterSaver` before serializing it (§7.3).
- **Body of 1 MB at most** across the whole internal API (413), saves and claims included: plenty for 120 slots, the
  equipment and a minute of journal. Ids as strings, integers and realms (code) as in §4.1.
- **In `staging` and `production`** registration without `dtls_cert_pem` gives 400 `validation`.
- Registration and heartbeat carry `now_unix`: the zone stores `offset = now_unix − its clock`
  (`ZonePlatform.now_unix()`) and warns if it exceeds 2 s.

**`PlatformClient`** (in the zone, inside `ZonePlatform`) uses `HTTPRequest` (no threads), a 3 s timeout (`timeout_s`,
shorter in tests) and priority queues. Results are stored on arrival and applied in the "poll" step, never in the
middle of a tick:

| Priority | Requests | Retry |
|---|---|---|
| 0 control | Registration, `live`, fortress GET and first id block at startup, heartbeat, deregistration | Registration, `live`, GET and first block: 1, 2, 4… s up to 60 s, then the zone exits (§8). Heartbeat: no (the next one goes out on schedule; never two queued) |
| 1 entry | Claim, release | Claim: **no** (the deadline of §5.2 cuts it off). Release: like saves, until a definitive response (a 4xx is one, §7.3) |
| 2 player | Saves, id blocks, operation and ledger, reports, ignores, sanctions | Saves and blocks: the same body at 1, 2, 4, 8 and 15 s, then every 15 s while the zone lives. The rest: no (the player or GM sees "El servicio de cuentas no responde") |
| 3 fortress | Fortress PUT (one in flight per fortress) | After 2 s, always with the most recent record |
| 4 batches | Chat, audit, war | The same batch at 2, 4, 8 and 16 s, then every 30 s. Beyond 20 000 queued entries the oldest chat is discarded (with a warning); audit and war never are, and they also go to the zone's log |

**Slots:** one of its own for priority 0 and six shared. Priorities 2 to 4 take four at most at once, so two are always
left for 1. When a slot frees up, the request of the highest priority goes out; within each priority, in arrival
order. An expired deadline is not a response: a save remains the same body until a definitive one arrives (§7.3).

| Route | Body | Response |
|---|---|---|
| `POST /internal/v1/zone-instances` | `{world_id, zone_id, channel, public_host, public_port, realms: [1, 2], build_id, protocol_version, record_format, max_players, dtls_cert_pem, dtls_name, replace}` | `{zone_instance_id, env, heartbeat_s, lease_ttl_s, now_unix}`; the instance is left in `starting` |
| `POST /internal/v1/zone-instances/{id}/live` | — | 204; becomes `live` and `enter` already offers it |
| `POST /internal/v1/zone-instances/{id}/heartbeat` | `{players, characters: [{character_id, lease_id}]}` | `{now_unix, revoked: [{character_id, lease_id, reason, text}], mutes: [{account_id, until_unix}], maintenance: {at_unix, message} \| null}` |
| `DELETE /internal/v1/zone-instances/{id}` | — | 204; `stopped` and frees whatever is left |
| `POST /internal/v1/claims` | `{zone_instance_id, ticket_id, character_id}` | `{lease_id, instance_status, account: {account_id, role, muted_until_unix, ignored_account_ids}, character: {character_id, world_id, realm, name}, progress, pvp}`: `realm` is the code (§4.1), `progress` the complete `ProgressRecord` of progression.md §3.4 (`ProgressStore.Load`, `progress_format` 1) and `pvp` the totals of §8 |
| `PUT /internal/v1/characters/{id}/state` | §7.3 | `{applied, duplicate, save_version, instance_status}` |
| `POST /internal/v1/saves` | `{zone_instance_id, saves: [§7.3]}` | All or none (trade and mail, phase 6): all new or all repeated; a mix → 409 `seq_conflict` |
| `POST /internal/v1/characters/{id}/release` | `{zone_instance_id, lease_id}` | 204, without saving (the client never got to appear: after the claim's 200 or in `LOADING`, §5.2; or after an `invalid_save`) |
| `POST /internal/v1/id-blocks` | `{zone_instance_id}` | `{"first": "1025", "count": 1024}`: `nextval('uid_block_seq')` and a row in `id_blocks`; in `starting` and in `live`. `uid` and `op_id` come from the same blocks and are unique across all worlds |
| `GET /internal/v1/ops/{op_id}?zone_instance_id=` | — | `ProgressStore.Op(…, opID, instance)`; response from progression.md §13.2 (for `op_show` and reversal), or 404 (also if no participant has a lease on the instance) |
| `GET /internal/v1/characters/{id}/ledger?zone_instance_id=&limit=&before_entry_id=` | — | `ProgressStore.Ledger`; response from progression.md §13.2; `limit` from 1 to 100 (20 by default), most recent first (for `ledger_show`); 404 if the character has no lease on the instance |
| `GET /internal/v1/fortresses?zone_instance_id=` · `PUT /internal/v1/fortresses/{id}` | — · `{zone_instance_id, expected_version, record}` | `{fortresses: [{fortress_id, record, version}]}`, only those of the instance's zone (empty list: no records) · `{version}`, 409 `version_conflict` with `{version}` or 403 `forbidden` (fortress of another zone, below) |
| `POST /internal/v1/war-events` · `…/chat` · `…/audit` | `{zone_instance_id, events\|messages\|entries: [{key, …}]}` (§8, §9) | 204; if any entry is invalid, 200 `{rejected: [key…]}` and the others are inserted |
| `POST /internal/v1/reports` | `{zone_instance_id, …}` (§9.4) | `{report_id}` or 429 |
| `POST` · `DELETE /internal/v1/ignores` | `{zone_instance_id, character_id, target_name}` | `{ignored_account_id, name}` · 204 |
| `POST /internal/v1/sanctions` | `{zone_instance_id, author_character_id, target_name, kind, minutes, reason, report_ids}` | `{sanction_id, ends_at_unix}` or 403 `forbidden` (§9.5) |

- **Operation and ledger:** registered by this document's internal router, with the checks of §6.1 (token, scope,
  `live` instance and lease); the world comes from the instance. Like the zone's other routes, they require a lease
  on that instance (`character_leases.zone_instance_id` equal to the instance): the ledger, of the character (the
  router checks it in `character_leases`); an operation, of one of its participants, which `ProgressStore.Op` checks
  with the instance in its own query (a `join` of `op_participants` with `character_leases`), so the platform does
  not read progress tables. Otherwise, 404: a zone does not read the ledger of someone it does not have inside
  (progression.md §10). The bodies are those of progression.md §13.2, with `participants`, `reversed_by` and `instances`
  (the withdrawn rows that `op_revert` needs).
- **The instance sets the world.** Reports, ignores and sanctions resolve `target_name` in the `world_id` of
  `zone_instance_id`, like batches: bodies do not carry it (a `world_id` in the body is an unknown field, 400) and a
  zone cannot reach anyone in another world.
- **A zone's fortresses.** The first PUT of a `fortress_id` creates its row with the instance's `zone_id`. A PUT to a
  fortress that already exists with another `zone_id` gives 403 `forbidden`, a war event for that fortress goes to
  `rejected` and the GET returns only those of the instance's zone: a zone cannot overwrite another's record or
  history.
- **Batches** (chat, audit, war): every 2 s or 200 entries, 1 MB at most. Each entry carries its `key`
  (`ZonePlatform.enqueue_batch` sets `"<zone_instance_id>:<sequence>"` if the entry does not bring one; the audit of a
  command that creates an operation brings `op:<op_id>`, §9.1) and is inserted with `on conflict do nothing`:
  resending a batch duplicates nothing. `world_id` and `zone_id` are set by the platform from the instance, and in
  chat also `zone_channel` (the instance's `channel`) and `sender_account_id`, from `characters`. **Each entry is
  validated separately and against the instance that sends it.** Rejected are: one missing a field; one with key
  `"<uuid>:<n>"` whose uuid is not the batch's `zone_instance_id`; one with key `op:<op_id>` whose `op_id` does not
  fall in an `id_blocks` block given to that instance; and, in audit, one with `source` other than `zone` and
  `console` (the `cli` and `platform` rows are written only by the platform) or with a `command` of the CLI or the
  platform (`set-role`, `sanction_denied`). Also one carrying something the database does not store: an `args` with
  broken UTF-8, `\u0000` or a lone surrogate (like `context` in a report and `record` in a fortress, which give 400),
  or a date (`at_unix`, `sent_at_unix`) above 253402300799 (9999-12-31). And if a row still fails in the database
  with a deterministic error (SQLSTATE class 22 or 23), only that one is rejected. What is rejected is logged, the
  rest are inserted and the response lists the rejected keys, which the zone does not retry. This way a zone does not
  write on behalf of another instance or the CLI, and a zone error does not block the audit queue, which is never
  discarded.
- **`revoked`** in the heartbeat. Each entry carries the `lease_id` (the heartbeat's in `lease_lost`; the lease's in
  the others) and the zone ignores any that does not match that character's current lease: a heartbeat built before a
  departure and a new entry on the same instance does not kick the one who just entered. A character in `LOADING`
  has no final save: it is released without saving (§5.2).

| `reason` | When | The zone |
|---|---|---|
| `lease_lost` | The heartbeat's `(character_id, lease_id)` does not match a lease of this instance | The drop without saving of §7.2, without `release` (in `LOADING`, the drop of §5.2) |
| `session_revoked` | The lease's session is revoked (`replaced`, `password_changed`, `email_changed`, `email_reverted`, `refresh_reuse`, `role_changed`, `logout`, `deletion`, `admin`) | Final save and kick with NOTICE ("Has iniciado sesión desde otro lugar", "Tu cuenta ha cambiado: vuelve a entrar", i.e. your account has changed: log in again) |
| `suspended`, `banned`, `pending_deletion` | Current sanction or deletion requested | Final save and kick with the reason and the date |

### 6.1 Instance states and order of checks
Every internal request is checked **in this order**, and the first failure gives the response: (1) token → 401
`bad_token`; (2) instance scope → 403 `forbidden`; (3) instance state (table); (4) lease (`lease_id` and
`claimed_by`) → 409 `lease_lost`; for operation and ledger, lease on the instance → 404; (5) `seq` → `duplicate`, 409
`stale_seq` or 409 `seq_conflict`; (6) content (S1–S8 of progression.md §13.3) and database errors, with the rule of
§7.3.

| Request | `starting` | `live` | `lost` | `replaced` | `stopped` |
|---|---|---|---|---|---|
| `live` | → `live` | 204 (repeated) | 409 `instance_lost` | 409 `instance_replaced` | 409 `instance_stopped` |
| Heartbeat | 200 | 200 | 409 `instance_lost` | 409 `instance_replaced` | 409 `instance_stopped` |
| Claim | 409 `instance_not_live` | 200 or its errors | 409 `instance_lost` | 409 `instance_replaced` | 409 `instance_stopped` |
| Save and release | §7.3 (it has no leases: `lease_lost`) | §7.3 | §7.3: valid if `lease_id` and `claimed_by` match (final saves) | same | same |
| Id blocks | 200 (the first is for startup, §8) | 200 | 409 `instance_lost` | 409 `instance_replaced` | 409 `instance_stopped` |
| Operation and ledger | 409 `instance_not_live` | 200 or 404 | 409 `instance_lost` | 409 `instance_replaced` | 409 `instance_stopped` |
| Fortress GET | 200 | 200 | 409 `instance_lost` | 409 `instance_replaced` | 409 `instance_stopped` |
| Fortress PUT | 409 `instance_not_live` | 200 or 409 `version_conflict` | 409 `instance_lost` | 409 `instance_replaced` | 409 `instance_stopped` |
| Batches | 204 (or 200 with `rejected`, §6) | same | same | same | same |
| Reports, ignores and sanctions | 409 `instance_not_live` | 200, or 403 `forbidden` | 409 `instance_lost` | 409 `instance_replaced` | 409 `instance_stopped` |

A save's response carries `instance_status`: this way the zone finds out even if its heartbeat lags behind.
**Shutdown on `instance_lost`, `instance_replaced` or `instance_stopped`** (in any request or in `instance_status`;
`ZonePlatform` turns it into the `instance_closed` event, which `ServerMain` handles, §14.3): first the final save of
everyone (`finish`, §7.2) and the release of those in `LOADING`, without kicking anyone: the zone stops reading their
inputs and stops giving rewards. Then `begin_flush` and wait for `is_flushed()`, 10 s at most. **Only then** a NOTICE
kicking everyone, "El servidor de la zona se ha reiniciado: vuelve a entrar" (the zone server has restarted: log in
again), disconnection and exit with code 3. This way anyone who re-enters right away (their leases may already be
free after a `lost`) loads their final save and not the previous one. The orchestrator (compose, `restart:
unless-stopped`) starts a new instance; in development the process exits with that message. `instance_not_live` is a
zone ordering error: it is logged.

**Internal errors:** 401 `bad_token`; 403 `forbidden`, `account_blocked`; 409 `instance_not_live`, `instance_alive`,
`instance_lost`, `instance_replaced`, `instance_stopped`, `lease_lost`, `stale_seq`, `seq_conflict`, `ticket_invalid`,
`character_busy`, `version_conflict`, `schema_mismatch` (only in registration: this platform does not admit the
`record_format` or the `protocol_version`; the zone exits with code 1); 400 `bad_request`, `validation`, `invalid_save`
(with `fields: {check: "S4", detail: "…"}`: the progression.md §13.3 check and what failed, from
`*persistence.InvalidSaveError`, `envelope` for an envelope error or a database error that is not transient, §7.3);
404 `not_found` (`persistence.ErrNotFound`, and operation or ledger without a lease); 503 `db_unavailable` (the
database does not respond or the transaction collided with another more times than it is retried, §7.3). Body as in
§4.1.

**`account_blocked`** adds to the body of §4.1 the kind, the end and the reason: `{"error": {"code":
"account_blocked", "message": "…", "kind": "suspension"|"ban"|"pending_deletion", "until_unix": 1800000000, "reason":
"…"}}` (`until_unix` null for a permanent ban; in `pending_deletion`, the `purge_after`). **The text for the player is
composed by the platform**, like the `text` of `revoked` in the heartbeat: `message` according to `kind` ("Tu cuenta
está suspendida hasta el 3/11/2026 18:00 UTC: motivo", "Tu cuenta está expulsada: motivo", "Tu cuenta se borrará el
…"), cut at a whole character to 255 B (the REJECT's `text_len`). The zone puts it as is in `AuthOutcome.text`;
`kind`, `until_unix` and `reason` go to its log.

## 7. Character persistence (TEC-25)
### 7.1 What is saved
The "who stores what" table is in progression.md §3.1. The save body (§7.3) carries one key per section registered in
`CharacterSaver`, with its name:

| Section | What | Built by |
|---|---|---|
| `progress` | The section of progression.md §3.4 and §9.3: the `ProgressRecord` without the read-only fields, with `ops` (the journal's operations not yet included in any body, progression.md §9.2, with their ledger entries and item events) | `ProgressService` (progression.md) |
| `pvp` | GUE-19 totals `{kills, deaths, assists, captures, gate_damage, defend_s}` | `ScoreKeeper` (§8) |
| **Never** | `PlayerState`, `CombatState` and whatever is predicted per tick, the input queue, combat in progress, telegraphs | — |

**Returning to the world** (provisional, made overnight): the rule is the one in progression.md §8. **CMB-30** (the two
weapons, the active weapon, health and long cooldowns) is also in progression.md §8 and travels inside `progress`: it
has no section of its own here.

**Formats.** `save_format` (1) versions the envelope of §7.3 and belongs to this document. `progress.progress_format`
(1) versions the section and is the `record_format` that the zone declares on registration:
`ZonePlatform.RECORD_FORMAT` (1), which exists since P4 even though `ProgressRecord` arrives in progression.md P5a;
`ProgressRecord.FORMAT` (progression.md §3.4) has the same value and a P5a test enforces it. Compatibility is decided
only at registration: if the platform does not admit that `record_format`, 409 `schema_mismatch` and the zone exits
with code 1 (§8). In a save, a different `progress_format` is a bug on our side: 400 `invalid_save` (S1). Rows are
columns: a new format is new code in `internal/progress` (progression.md P7) and, if needed, a migration (§2.4), not a
conversion on read.

### 7.2 When it is saved
| Moment | How |
|---|---|
| Checkpoint | Every 60 s (`--save-interval=<s>`) if any section is dirty (its `is_dirty`; in `progress`, moving and health count). Each character in its own phase (`tick % interval == character_id % interval`): 64 players give ~1 save per second |
| Critical event | Those of progression.md §9.2, which maintains the list: `CharacterSaver.mark_critical(net_id, reason)`; it goes out as soon as there is no other in flight |
| Exit | When the body leaves (CLIENT_LEAVE, disconnection or end of the 15 s in combat), in this order: `CharacterSaver.finish(net_id, LOGOUT)` with `release_lease` → `ScoreKeeper.forget` → `ProgressService.on_departure(net_id)` |
| Drop without saving | A definitive response before `finish` (`save_rejected`, §7.3) or a `lease_lost` `revoked` for someone in the world, in this order: (1) `CharacterSaver.drop(net_id, code)`, which unties the entry, discards the final save it was waiting on and calls `release` except on `lease_lost`; (2) NOTICE and kick with the body removed **immediately** (`_remove_player`, without `_should_linger`: combat logout does not apply here, because the lease is no longer the zone's or was just released); (3) `ScoreKeeper.forget` and `ProgressService.on_departure(net_id)`. It does not go through "Exit": `finish` on a `net_id` with no entry does nothing |
| Orderly shutdown | The five triggers: `--stop-file`, `--quit-after-ticks`, `--idle-quit`, the console's `shutdown` and the platform's maintenance (`maintenance` in the heartbeat: NOTICE at 10, 5 and 1 min, at 30 s and at 10 s, and shutdown at its `at_unix`, §12). All go through `ServerMain._shutdown` → `ZoneServer.stop`: `release` of the peers in `LOADING` and `auth_provider.cancel` of those in `VERIFYING`, `finish` of everyone in the world before `_clear_players()`, `begin_flush` and wait until `pending_count()` is 0 and `is_flushed()`, with a cap of 600 ticks (10 s) |
| Kick by the platform | `revoked` in the heartbeat (§6) |
| Instance shutdown | §6.1 |

- **One write in flight per character.** While it is in flight, changes only mark the section; when the definitive
  response arrives the next one is built. The snapshot is taken **inside the tick**, after "spawns".
- **The final save is built on the spot** (`finish`): the player no longer changes, so it waits behind the one in flight
  without being rebuilt. At most one in flight and one final waiting. It carries only the operations that were not yet
  in any body (progression.md §9.2): if the one in flight is applied, the final one repeats nothing; if the one in
  flight receives a definitive response, the final one is discarded with it.
- **A section that returns `{}`** cannot be built right now (that of `progress`, with no id to close what was
  aggregated, something its reservation prevents: progression.md §4.5). That save does not go out or spend a `seq`: a
  checkpoint or a critical save is retried on the next `step`. A final save cannot wait, because after `finish` the
  player's state no longer exists: an alert in the log and `release` without saving, as after a definitive response.
- **Entries by `lease_id`.** `CharacterSaver` keeps its entries by `lease_id`, which is unique per claim, with two
  separate indexes: `character_id` → current `lease_id` and, until `finish` or `drop`, `net_id` → `lease_id`. The
  `net_id` is reused after 600 ticks (networking.md §9.1) and the same character can come back to this instance with another
  claim while its final save is still being retried for minutes. Each response is matched by the `lease_id` and the
  `seq` of its own request (the `context` of `ZonePlatform.save`), never by `character_id` or `net_id`; a `track` with
  another `lease_id` does not touch the old entry.
- **After `finish` (or `drop`), the entry no longer belongs to the `net_id`.** The responses of the one that was in
  flight and of the final one do not call `acknowledge` or the sections' `is_dirty` (their state no longer exists) nor
  emit `save_rejected`: a 200 closes the entry; a definitive response is only logged (and, if it is not `lease_lost`,
  `CharacterSaver` calls `release` for that `lease_id`), without kicking anyone or calling `on_departure` again. If the
  character has already re-entered, the old lease's `release` gives `lease_lost` on the platform and does not touch the
  new one.
- **Drop in `LOADING`:** does not go through `CharacterSaver` (§5.2).
- **A sent body does not change.** `CharacterSaver` builds the whole envelope of §7.3 (also `zone_instance_id`), keeps
  the bytes (`JSON.stringify` once) and retries go byte for byte. `JSON.stringify` and sending do not block the tick.
- **Fenced** (§5.3): saves keep going out; operations that require a critical save (GM commands that change something;
  in phase 6, trade and mail) are rejected. The game's critical saves (kit, level-up, capture) are not: they are
  marked and go out as soon as possible.

### 7.3 Versions and idempotency
```json
{"save_format": 1, "character_id": "41", "zone_instance_id": "…", "lease_id": "…", "seq": 17, "reason": 1,
 "release_lease": false,
 "progress": {"progress_format": 1, "level": 7, "…": "ProgressRecord from progression.md §3.4 without the read-only fields",
              "ops": [{"op_id": "5120", "kind": 2, "…": "progression.md §9.3"}]},
 "pvp": {"kills": 3, "deaths": 1, "assists": 0, "captures": 1, "gate_damage": 450, "defend_s": 120}}
```

This is the body of `PUT /internal/v1/characters/{id}/state`: the envelope (`save_format` 1) with one key per section
registered in `CharacterSaver` (§7.1). **`CharacterSaver` builds all of it**, with `zone_instance_id =
platform.instance_id()`, `lease_id` and `character_id` as strings, before the single `JSON.stringify`;
`ZonePlatform.save` sends those bytes untouched (§14.3). The `progress` section carries no zone: the save's zone is
that of the `claimed_by` instance (`SaveKey.ZoneID`). `seq` starts at 1 with each lease and goes up by 1 on each save;
`reason`: 1 checkpoint, 2 critical, 3 exit, 4 server shutdown, 5 kick. The idempotency key is **`(lease_id, seq)`**,
and only that.

**Sections.** `progress` is mandatory. `pvp` is optional: without it, `character_pvp_stats` does not change; with it,
each total is read with `jsonx.Int` ≥ 0 and written with `greatest(column, new)`, without error: totals never go
down. Each one must fit in its column: 2^31 − 1 in the five `int` ones (`gate_damage` is `bigint`); otherwise,
`envelope`. **The envelope** is decoded strictly (`DisallowUnknownFields`, `jsonx`): `save_format` = 1,
`character_id` equal to the route's `{id}`, valid ids and `seq`, `reason` 1–5 and `progress` present. Any failure is
400 `invalid_save` with `check = "envelope"`, before touching the database. After that, the platform, in one
transaction:

1. `select … from character_leases where character_id = $1 for update`.
2. No row (the character was purged, §11.2), another `lease_id`, or `claimed_by` different from `zone_instance_id` →
   409 `lease_lost`.
3. `seq = last_seq`: if the body's SHA-256 is `last_save_hash`, 200 `{applied: false, duplicate: true, save_version}`
   with the lease's `last_save_version` (the one from when it was applied: the platform does not read
   `character_progress`); otherwise, 409 `seq_conflict`. `seq < last_seq` → 409 `stale_seq`.
4. `ProgressStore.Apply(ctx, tx, key, progress)` with checks S1–S8 of progression.md §13.3 (the instance's id blocks
   included), which writes `saved_at = now()` and `save_version + 1` in `character_progress` (S8) and returns the new
   `save_version`; `character_pvp_stats` with `greatest`, if `pvp` arrives; `last_seq = seq`, `last_save_hash`,
   `last_save_version`; with `release_lease`, `zone_instance_id = null` and `released_at`. If anything fails, **nothing
   is written** and the response comes from the rule below.

**Save errors** (the single rule; progression.md §13.3 cites it):

| Error, in the envelope, in `Apply` or in COMMIT | Response |
|---|---|
| Envelope error (above) | 400 `invalid_save` with `check = "envelope"` |
| `*persistence.InvalidSaveError` (S1–S7) | 400 `invalid_save` with its `check` and its `detail` |
| SQLSTATE class 22 (data the database does not admit: a NUL in `jsonb`, a number or date out of range) or 23 (primary key, unique, foreign key, CHECK, also the deferred ones that COMMIT triggers, like the slot one) or `P0001` (the append-only trigger) | 400 `invalid_save` with `check = "S8"` and the SQLSTATE and constraint in `detail`: it is a deterministic error, retrying does not fix it |
| `40001` or `40P01` | The whole transaction is retried inside the platform (three times, as when creating characters); afterwards, 503 `db_unavailable` |
| No connection to the database, statement timeout | 503 `db_unavailable` |
| Anything else | 500 `internal` |

The zone retries the same body on a 5xx or a 401 and treats any other 4xx as definitive (table below), so a transient
failure never kicks and a deterministic one is never retried forever.

`save_version` is a monotonic per-character counter that **plays no part in idempotency**: it goes in the response
`{applied, duplicate, save_version, instance_status}` and is only used by logs, metrics and tests; sections confirm by
`seq`.

| Response | The zone |
|---|---|
| 200 `applied` or `duplicate` | Applied (a `duplicate` is a save that arrived and whose response was lost): before `finish`, each section receives `acknowledge(net_id, seq)` (in `progress`, the `ops` of that body and earlier ones leave the journal); if another is marked or a final one is waiting, it goes out |
| 409 `lease_lost` | Definitive: the drop without saving of §7.2, without `release`, with NOTICE "Tu personaje ha entrado en otro servidor" (your character has entered another server) |
| 409 `stale_seq` or `seq_conflict` · 400 `invalid_save` | Definitive and our own bug: an alert in the log (with `check` and `detail` in an `invalid_save`) and the drop without saving of §7.2, with `release` so the character is not left blocked and NOTICE "No se ha podido guardar tu personaje; vuelve a entrar" (your character could not be saved; log in again) |
| 409 `instance_lost`, `instance_replaced` or `instance_stopped` | The shutdown of §6.1, with final saves of everyone (those of a replaced instance are valid if nobody has claimed the character, §5.3) |
| Any other 4xx (400 `bad_request` or `validation`, 403, 404, 413, an unknown 409) | Definitive, like `invalid_save`: alert, NOTICE and the drop without saving with `release`. It also applies to the response of a release, which is then not repeated |
| 5xx, 401, offline, expired deadline | Retry of the **same** body (§6). No `seq + 1` goes out until one of the responses above arrives |

Before `finish`, definitive responses reach the zone through `CharacterSaver.save_rejected(net_id, character_id,
code)`: the zone does the drop without saving of §7.2 (progression.md §9.2). After `finish`, the rule of §7.2: they are
only logged. This table is the only one: progression.md cites it.

**Size.** With the platform down, the save in flight is retried and nothing else goes out, so the journal only grows
with loose operations; GM ones are rejected with the zone fenced (§5.3) and DESTROY answers NOT_NOW with 256 or more
unconfirmed operations (progression.md §4.2). This way no body reaches the 1 MB of §6.

Example: a save exceeds its 3 s deadline but the platform applies it late. The retry carries the same `seq` and the
same bytes: `duplicate`, which the zone treats as applied. The next one carries `seq + 1` and only the new `ops`, so
S2 of progression.md (an `op_id` already in `economy_ops` fails) passes.

The lease makes the zone the only writer. Outside the zone nobody writes progress in phase 5 (offline editing belongs
to SOC-37, phase 8); whoever does so in the future will change `lease_id` first. **Item rule:** every operation that
moves items or currencies between two characters is saved in a single `POST /internal/v1/saves` with both (a single
operation with two participants, `op_participants` of progression.md §3.3); this way a `uid` is never in two rows (the
primary key of `item_instances` prevents it) and nothing is duplicated.

### 7.4 If something goes down
| What goes down | What happens | What is lost |
|---|---|---|
| The zone (`kill -9`) | Leases freed after 15 s (or when the new instance registers) | Whatever came after the last save: **60 s at most**; the critical events were already saved |
| The platform | Nobody new enters (`enter` fails; the zone is fenced after 10 s; a claim in progress gives `UNAVAILABLE`); those playing carry on. The zone retries the save in flight and marks the others; when it comes back, the grace period of §2.5 applies and everything is sent | Nothing, unless the zone goes down too |
| Both | Whatever did not arrive | Everything since the last accepted save |
| The network between them | For the zone, like "the platform". If the client does reach the platform, after 15 s its character can enter another zone; when the network returns, the old one receives `instance_lost` and shuts down: final saves of anyone nobody has claimed are valid, the rest give `lease_lost` | What was played in the isolated zone by someone who entered another (§16) |

Desirable (does not block TEC-25): an orderly shutdown without the platform writes what is pending to
`user://pending_saves.jsonl` and resends it on startup; this works because `lease_id` does not change on release and
`seq` orders it.

### 7.5 Boundary with `docs/progression.md`
**In Go.** The `persistence.ProgressStore` interface (`internal/persistence/progress.go`) is defined by P2 of this
document with a fake, **together with its errors** (`*persistence.InvalidSaveError` → 400 `invalid_save`;
`persistence.ErrNotFound` → 404): this way P2, P3 and the fake use them before `internal/progress` exists, which
returns them and imports `persistence` (never the other way round: there is no cycle). It is implemented by
`internal/progress` (progression.md P7). Its types, errors and signatures (`CreateParams`, `SaveKey`, `Summary`,
`InvalidSaveError`, `ErrNotFound`, `Create`, `Load`, `Apply`, `Summaries`, `Purge`, `PurgeRetention`, `Export`, `Op`
and `Ledger`) are in progression.md §13.2 and are not repeated here. Raw JSON travels across the boundary; inside,
`internal/progress` decodes strictly (`jsonx.Int`, `jsonx.ID`, `DisallowUnknownFields`).

- **Creation validation.** In the same file, P2 defines `persistence.CreateValidator` and
  `*persistence.ValidationError` (signatures in progression.md §13.2; the character handler passes its `Fields` as is to
  the 400 `validation`'s `fields`), with the provisional implementation of §4.4 step 5. `*progress.Rules` implements it
  and `serve` picks which to use: progression.md P7 does not touch the character handler.

- **The platform does not read progress columns** with its own SQL: the character list, `enter` and the name
  reservation exception use `Summaries` (P2 arrives before migration 0010); the `save_version` of a `duplicate` comes
  from `character_leases` (§7.3) and the tombstones it can already delete, from `PurgeRetention` (§11.1).
- Lease and `seq` (steps 2 and 3 of §7.3) are handled by `persistence.Store.Save` before calling `Apply`.
- **Id blocks:** each `op_id` in the body and each new `uid` falls in an `id_blocks` block given to `claimed_by`
  (`SaveKey.InstanceID`); otherwise, 400 `invalid_save` (S2 and S5: a zone cannot make up ids belonging to another).

**In the zone** (GDScript):

| Piece | Document | Does |
|---|---|---|
| `ZonePlatform`, `PlatformClient` | This one (P4) | HTTP, queues, heartbeat, claims, id blocks, events |
| `ClaimedCharacter`, `AuthOutcome` | This one (P4) | What the claim brings; `progress` goes as is to `ProgressRecord.from_dictionary` |
| `CharacterSaver` | This one (P5) | When, `seq`, one in flight, final save, the whole envelope, responses of §7.3 and the drop without saving (`drop`); it calls `ZonePlatform.save` directly |
| `ProgressService`, `PlayerProgress`, `ProgressRecord` | progression.md | The load (`prepare`, §5.2) and the spawn (`on_arrival`), operations and the `progress` section |

`CharacterSaver` only exists with `--platform`: without the platform nothing is saved, every player is ephemeral and
`ProgressService.setup(zone, null, null, commands)` (progression.md §9.4). The sections are `&"progress"`
(`ProgressService.setup`) and `&"pvp"` (`ScoreKeeper`, P6), with the API of §14.3. Tests use `FakeZonePlatform`, which
does the JSON round trip just like `PlatformClient` (§14.3) and returns in the next claim whatever was last applied
(§14.1). What was agreed with progression.md is in §17.

## 8. Persistent war (GUE-19)

Record of a fortress (`fortresses.record`, schema 1), written by `FortressPersistence` in `scripts/server/war/` (never
in `scripts/shared`, which does not read the clock):

```json
{"schema": 1, "owner": 1, "phase": "consolidating", "phase_ends_at_unix": 1800000120,
 "captain_alive": false, "captain_respawn_at_unix": 1800000300, "gate_health": 2600,
 "capture_realm": 0, "capture_progress": 0, "last_reset_at_unix": 1799999000}
```

- **Startup with the platform**, in this order (`ServerMain` and `ZonePlatform`):
  1. Registration (`starting`). 409 `instance_alive`: retries every 2 s for 60 s (§5.3). 403, 409 `schema_mismatch` or
     60 s without a response: exits with code 1.
  2. Checks the `env` against the development options (§5.5).
  3. `GET /internal/v1/fortresses` with retries (1, 2, 4, 8… s; after 60 s without a response, exits with code 1).
     **No response is not "no record":** only an empty list is (first startup: the initial state of each definition,
     with no warning). A record with another `schema`: the initial state with a warning.
  3b. `POST /internal/v1/id-blocks`: the first id block (progression.md §4.5), with the same retries.
     `startup_finished` waits until it has it and the block reaches `ProgressService` as an `id_block` event.
  4. `ZoneServer.start(…, platform)` applies the loaded fortresses and **then** opens the port (`NetTransport.host`).
  5. `POST …/live`: from here `enter` sends players. Heartbeats start after step 1.
- Each `*_at_unix` is converted back to ticks with `tick + max(0, at − now_unix) · 60`. `CAPTURING` comes back as
  `VULNERABLE` with its progress (the circle is empty and decays); guards are not saved (the spawner replenishes
  them). Without the platform, as today.
- **Saving:** on every change of owner or phase and, if something changed (the gate's health), every 60 s. A future
  tick `t` is written as `now_unix + ceili((t - tick) / 60.0)` (in GDScript, `(t - tick) / 60` between integers
  truncates before rounding and `ceil` returns `float`). One request in flight per fortress, always with the most
  recent record and with `expected_version` (the last one the platform returned). 409 `version_conflict`: the zone
  takes the error's `version` and resends its record (the live instance wins). Only the `live` instance of that zone
  writes, and the platform does not let a fortress of another zone be written (§6).
- The reset to neutral every 30 min counts from `last_reset_at_unix` (restarting the process does not restart the
  cycle).
- **History:** `WarEvents` 3 (capture started), 6 (captured) and 7 (reset) go to the `war-events` batch (`{key,
  fortress_id, event, realm, at_unix}`) → `fortress_events`.
- **Per character.** `ScoreKeeper.Entry` (today `kills`, `deaths`, `assists`, `gate_damage` and `circle_ticks`) adds
  two counters (P6):

| Counter | Added by | When |
|---|---|---|
| `captures` | `FortressController`, when applying the owner change | To each player of the capturing realm present, alive and connected in the circle on the capture tick, excluding invisible GMs and characters flagged by a GM command (`gm_forced`, progression.md §6.2). The list is computed once and the same one goes to `ProgressService.on_capture` (the reward of progression.md §6.2). A capture forced by a fort command neither counts nor pays (progression.md §6.2) |
| `defend_ticks` | `FortressController._recount` | To each player of the **owning** realm present with the circle active (`circle_ticks` keeps counting everyone, for merits) |

  The `pvp` section of `CharacterSaver` sends the loaded totals (`ClaimedCharacter.pvp`) plus the session's
  (`defend_s` = loaded + `defend_ticks / 60`). Since `finish` builds the snapshot on the spot (§7.2), it goes before
  `ScoreKeeper.forget`.

## 9. Social and moderation (SOC-13 to SOC-18)
### 9.1 Roles and audit (SOC-14)
| Role | Commands | Sanctions it can create |
|---|---|---|
| `player` | No moderation | — |
| `moderator` | `/gm silenciar`, `/gm aviso`, `/gm expulsar`; visible label | `warning`; `mute` up to 7 days |
| `gm` | The above, `/gm suspender`, `/gm renombrar`, `/gm teleport`, `/gm invisible` and `/gm visible`, those of progression.md §10 (PRG-16, also the `inv_show`, `ledger_show` and `op_show` queries) and the fort commands (with the platform, what they cause pays nothing persistent to anyone, the GM included, and `/gm teleport` and `/gm visible` flag the character they move or show, who does not get paid until respawning: progression.md §6.2) | The above; `suspension` up to 7 days; `rename` |
| `admin` | Everything, also `/gm banear`, `/gm anuncio` and `/gm apagar` | The above; `suspension` of more than 7 days; `ban` |

- **The role** is set by `admin --actor <email> set-role <email> <role>` and arrives in the claim. `set-role` **revokes
  the account's sessions** (`role_changed`): the heartbeat kicks the character within 5 s at most and it re-enters with
  the new role. Demoting a connected GM removes their power right away. **Its `audit_log` row is fixed, because S2
  looks for it:** `source = 'cli'`, `command = 'set-role'`, `actor_account_id` that of `--actor`, `target_account_id`
  the account, `args = {"from": "gm", "to": "player", "os_user": "…"}` and `at = now()`. With it, S2 accepts the actor
  of an operation that the GM created before losing the role and that is still being saved (progression.md §13.3). S2
  only reads `cli` rows, which a zone cannot write (§6, "Batches"); the `(target_account_id, command, at)` index of
  0005 finds it.
- **Permission per command.** Each command in `CommandRegistry` declares its `min_role`; without permission or unknown:
  "Comando desconocido. Escribe /ayuda." (unknown command, type /ayuda). Without the platform, as today (console, and
  DEBUG_COMMAND with `--debug-commands`).
- **DEBUG_COMMAND with the platform** (only in `dev` and `test`, §5.5) additionally requires the command's `min_role`:
  `gm` for network ones (teleport, health, fort); `admin` for those that create or keep value on a persistent
  character or bypass its equipment: 40–43 and 5, 13 and 16 (the list belongs to progression.md §10). Without the role,
  it adds a warning as today and nothing is executed or saved.
- **On one's own characters.** Every progression.md §10 command that changes something (`item_give`, `item_take`,
  `currency_add`, `level_set`, `xp_add`, `op_revert`, also via DEBUG_COMMAND) on a character of the user's own account
  requires `admin`, with no exception per environment; otherwise, "No puedes usarlo sobre tus personajes" (you cannot
  use it on your own characters). The rule belongs to progression.md §10 and S2 repeats it in Go, in GM operations and
  in the REVERSAL of `op_revert`. The audit always stores `target_account_id`.
- **Invisible.** The GM's entity does not enter anyone else's interest (`InterestPolicy`), its `Combatant` neither
  deals nor receives damage (`CombatResolver` skips it), it does not count in `_presence_candidates` (circle), nor in
  `ScoreKeeper`, nor in progression.md's rewards (merits, XP, gold, capture; its §6.2). `/gm visible` undoes it; both
  are audited.
- **Audit:** every GM, console or debug command with the platform goes to the `audit` batch (`{key,
  actor_account_id, actor_character_id, command, target_character_id, target_account_id, args, at_unix, source}`) and
  to the zone's log; CLI ones and sanctions go directly to `audit_log`. In the entry: `actor_account_id`, the GM's
  account (that of their claim; null from the console); `source`, with the vocabulary of `audit_log`: `console` from
  the console and `zone` in everything else (`/gm` and DEBUG_COMMAND), the same rule as S8; `args`, the arguments with
  the target by `character_id` as a string (progression.md §10); `at_unix`, the zone's time
  (`ZonePlatform.now_unix()`). `world_id` and `zone_id` are set by the platform from the instance (§6). **Reads too:**
  `inv_show`, `ledger_show` and `op_show` (zone batch), and `admin reports list|show`, `admin audit` and `admin chat`
  (social.md §8: "registro de cada consulta", i.e. a log of every query).
- **No personal data in the audit.** One rule for every `audit_log` row, whether from the zone, the console, the CLI or
  the platform: the target goes in `target_account_id` and `target_character_id`, and `args` never carries an email or
  a character name (except the term of `names block|unblock`, which already lives in `name_blacklist`). The CLI
  resolves emails and names to ids before writing (`set-role`, `purge-now`, `chat --character`, `audit --target`…) and
  `sanction_denied` stores the resolved id, not the `target_name`. This way the purge (§11.2) leaves no emails or names
  in the audit or in the backups.
- **Two paths, one row.** The batch entry carries `key = "<zone_instance_id>:<sequence>"`, except that of a command
  that creates an operation (progression.md §10: a GM one, or the REVERSAL of `op_revert`), which carries `key =
  "op:<op_id>"`: the save writes the same row in its transaction (S8 of progression.md §13.3) and both go with `on
  conflict (event_key) do nothing`, so whichever arrives first, it is neither duplicated nor lost. For them to match,
  both carry the same fields with the same values: S8 takes them from the operation (`world_id` and `zone_id` from the
  instance, `SaveKey`; `source` with the rule above; `command`, `args`, `actor_character_id` and `at_unix` from
  `detail`; `actor_account_id`, `target_character_id` and `target_account_id`) and the zone sets them the same way in
  the batch. `audit_log.at` is `to_timestamp(detail.at_unix)` in both: the time at which the zone created the
  operation, not the time of applying it, which with retries can be minutes later.
- **The CLI has an identity.** Every `admin` command requires `--actor <email>` of an `admin` account (or `moderator`
  for read ones: `reports list|show`, `audit`, `chat`); without it, or with another account, it is not executed (code
  2). Its rows carry `source = 'cli'`, the command's name in `command` (`set-role`, `purge-now`, `reports show`…) and
  the `--actor`'s account in `actor_account_id`, and store the value of `$SUDO_USER` or `$USER` in `args.os_user`.
  Query: `admin --actor <email> audit --since 2026-11-01 [--actor-name <name>] [--target <name>]`.

### 9.2 Chat log (SOC-15)
`ChatRouter` (SOC-04) puts each already sanitized message into the `chat` batch (`{key, channel,
sender_character_id, target_character_id, text, sent_at_unix}`); the platform fills in `world_id`, `zone_id` and
`zone_channel` (the zone's copy, the instance's `channel`) from the instance and `sender_account_id` from `characters`
(§6). This way the "zone" scope is known (that zone and that copy, social.md §2) and so is a whisper's recipient; the
"group" one (which group) is not stored: in phase 5 a group has no persistent identity. Retention of 30 days (§11.1).
Query: `admin --actor <email> chat --character <name> --from … --to …`, which is audited (with the character by id).

**Per-character chat rates.** With the platform, `ChatRouter` keeps the `ChatPeerState` (buckets, last text, drops and
recent recipients; social.md 12.7) by `character_id`, not by connection: when the character leaves it keeps it for
`KNOWN_RECIPIENT_TICKS` (5 min) and, if it re-enters on this instance, reattaches it. This way logging out and back in
does not refill the bursts. Without the platform, by connection, as in phase 4.

### 9.3 Ignores (SOC-16)
- `/ignorar nombre` → zone → `POST /internal/v1/ignores` with the `character_id` of the one ignoring: the platform
  checks that they have a lease on that instance, resolves the account of the name (in the instance's world, §6) and
  stores `(account, ignored account, named character, name)`. Up to 100. The list the player sees only shows the names
  they typed.
- The zone has, per player, the accounts they ignore (they arrive in the claim) and each character's account. **The
  server discards** whispers, invitations and (phase 6) mail from an ignored account, and removes it from the
  recipients of public channels: the client cannot hide it without knowing which characters share an account, and
  that is not told to it. social.md §10 and SOC-16 already say so.

### 9.4 Reports (SOC-17)
`/reportar nombre categoría [comentario]` or the social menu. The zone attaches the last 20 messages from that
character that the reporter **received** within 10 min (a ring per receiver in `ChatRouter`), zone, position and tick,
and sends `{zone_instance_id, reporter_character_id, target_name, category, comment, context, evidence: [{sender_name,
channel, text, sent_at_unix}]}`. The platform checks that the reporter has a lease on that instance, imposes 1 per
target every 10 min and 10 per hour per account (429), copies the evidence to `report_evidence` and the zone answers
"Reporte enviado. Gracias." (report sent, thanks). Review: `admin --actor <email> reports list|show|close` (audited).

### 9.5 Sanctions (SOC-18)
| Type | Where it is applied |
|---|---|
| Warning | On entry, NOTICE with the reason: the claim brings the warnings the account has not seen and the lease's first save marks them as seen (`characters.last_entered_at` = the claim's time). If the zone drops the character before it reaches the world (`REALM`, `FULL`, `prepare` or the drop in `LOADING`), they come out in the next claim |
| Mute | `ChatRouter` discards and answers "Estás silenciado N min más" (you are muted for N more min); it arrives in the claim and in the heartbeat's `mutes` |
| Suspension, permanent ban | Login (after the password, only the privacy session of §4.2) and `enter` (403 with end and reason), claim (`BANNED`) and heartbeat (`revoked`: final save and kick) |
| Forced rename | `characters.must_rename`: `enter` → 409 `rename_required` |

Every sanction carries a reason, author, `ends_at` and its reports, with the scale of social.md §9. It is created by
`/gm …` (through `POST /internal/v1/sanctions`) or `admin --actor <email> sanction …`. **The platform authorizes**, in
the sanction's transaction:

1. The author (`author_character_id`) has a lease on that instance (`zone_instance_id`).
2. Their account has the minimum role in the table of §9.1 for that `kind` and that duration.
3. The target account (the `target_name` in the instance's world) has a role **lower** than the author's.

If any fails: 403 `forbidden` and a row in `audit_log` with `command = 'sanction_denied'` (the target, by id; §9.1).
The CLI passes the same checks with the `--actor`'s account. A `CommandRegistry` failure or a compromised zone cannot
sanction on their own. The rules are accepted when creating the account (§11.4).

## 10. Security, encryption and secrets (TEC-27)
### 10.1 HTTPS
- The platform serves HTTP; in staging and production, **Caddy** in front with Let's Encrypt and 80 to 443
  (`platform/deploy/Caddyfile`, with `reverse_proxy platform:24680 { header_up X-Real-IP {remote_host} }` and **no
  access log**). The internal API does not go through Caddy.
- The client uses `TLSOptions.client()` (Godot's root certificates) and rejects `http://` except towards loopback.
  Staging with its own certificate: `eldmark/platform/ca_cert` (path to a PEM).
- Verified in Godot 4.7.2: `HTTPRequest` with `TLSOptions.client(X509Certificate)` talks to a Go server with its own
  certificate (200 in 63 ms) and a 400 brings its JSON. Without pinning it gives `RESULT_TLS_HANDSHAKE_ERROR` **and
  the engine logs an ERROR**, which the runner counts as a failure: no Godot test provokes a TLS failure (that is
  tested in Go). `RESULT_CANT_CONNECT` and `RESULT_TIMEOUT` do not log errors.

### 10.2 DTLS in ENet
- **Contract in `scripts/shared/net/net_transport.gd`** (P9c): `host(port: int, max_peers: int, dtls: TLSOptions =
  null) -> Error` calls `peer.host.dtls_server_setup(dtls)` after `create_server` and before wrapping it in
  `GuardedEnetPeer`; `connect_to(address: String, port: int, connect_timeout_ms: int = 3000, dtls_name: String = "",
  dtls: TLSOptions = null) -> Error` calls `peer.host.dtls_client_setup(dtls_name, dtls)` right after `create_client`.
  Without `dtls`, as today. `NetTransport` reads no files: the PEMs are loaded by `ServerMain` and the client.
- The zone (`--dtls-cert=<pem> --dtls-key=<pem>`, with or without the platform) sends the public PEM and `dtls_name`
  (the certificate's `CN`) on registration. The client receives it in `enter` (over HTTPS, which authenticates it).
  No private CA or bundled certificate: rotating it requires no client patch. Without the platform, `--connect`,
  `--bot` and `--bots` accept `--dtls-cert=<pem> --dtls-name=<cn>`, and each `SwarmBot` configures its `NetTransport`
  the same way.
- In `staging` and `production` the platform does not register a zone without a certificate (§6): "no DTLS, no public
  tests" is enforced by itself.
- Verified with `ENetMultiplayerPeer` in one process: it connects and delivers a packet over DTLS. Exiting without
  `close()` makes the engine log a `bio_send` error: peers are closed first.
- **Verified in P9c** (§19.18): DTLS with `GuardedEnetPeer` and `SceneMultiplayer` authentication, in one process and
  with the dedicated server; the disconnect is always started by the server (a DTLS client that started it would make
  the server engine log an error per exit). TEC-27 measures CPU per packet, the extra bytes per datagram and the
  1200 B cap against ENet's MTU, with `--bots=64` with and without `--dtls-cert` against the same zone
  (`tools/load_test.gd --dtls-compare`). **Criterion** (provisional, made overnight; question for the user, §0): DTLS
  does not raise the tick p99 by more than 10 % and the absolute figure is recorded in networking.md §14. The backlog's one
  (p99 < 8 ms with 64 bots) is not met even without DTLS (15.9 ms). What was measured is in networking.md §14 and §19.18.

### 10.3 Secrets
| Secret | Where it lives | Rotation |
|---|---|---|
| Database URL | `ELDMARK_DATABASE_URL_FILE` (Docker secret) | `alter role … password`, new secret and restart |
| Ticket keys | `ELDMARK_TICKET_KEYS_FILE` on the platform and on each zone | New key on the zones → sign with it → remove the old one after 1 min |
| Each zone's token | `ELDMARK_ZONE_TOKENS_FILE` (platform: only hashes with their scope) and `ELDMARK_ZONE_TOKEN_FILE` (zone: the token) | Two entries with the same scope during the change |
| Each zone's DTLS key | Docker secret | New certificate and restart; the client receives it on the next `enter` |
| SMTP | `ELDMARK_SMTP_URL_FILE` | At the provider |
| Email HMAC key | `ELDMARK_EMAIL_HMAC_KEY_FILE` | Not rotated in phase 5 (changing it empties `sanctioned_email_hashes`) |

- The zone reads its secrets only from variables or files (`OS.get_environment`), never from the command line, which
  is visible with `ps`. Compose mounts them from `platform/deploy/secrets/<name>` as Docker secrets.
- **Nothing goes into git.** Today `.gitignore` only ignores `.env` (verified with `git check-ignore --no-index`:
  `platform/deploy/staging.env`, `secrets/ticket_keys` and `zone.key` are not ignored). P0 adds `*.env`,
  `!*.env.example`, `platform/deploy/secrets/`, `*.pem`, `*.key` and `!tests/fixtures/**/*.pem` (verified in a test
  repository: it ignores the real ones and leaves the examples and the test PEMs).
- **CI** ("Plataforma" job): fails if `git ls-files` lists any `*.env`, anything under `secrets/` or a `*.pem` or
  `*.key` outside `tests/`, or if `grep -rE
  'ELDMARK_(TICKET_KEYS|ZONE_TOKENS?|SMTP_URL|DATABASE_URL|EMAIL_HMAC_KEY)=[^[:space:]]' platform/deploy/*.example`
  finds anything.

## 11. Privacy and GDPR (TEC-43)
### 11.1 Data and retention
There is account data (email, hash, dates, role, state), sessions and logins (IP, agent), acceptances, consents,
entitlements, characters (name, appearance, progress, statistics), ignores, chat, reports, sanctions and audit. No
real name, no address, no payments (if there are any, they belong to the provider).

| Data | Kept | How |
|---|---|---|
| `chat_messages` | 30 days | Hourly job, batches of 10 000 |
| `report_evidence`, closed reports, `audit_log` | 1 year (from the closing, for reports) | Hourly job. A report still open one year after creation becomes `dismissed` (`closed_at = now()`, `resolution = 'caducado'`, i.e. expired) and counts from there |
| `auth_events`; IP and agent in `sessions` | 30 days | Hourly job (the session's IP becomes null) |
| Expired `sessions` and `account_tokens` · `enter_tickets` · finished `zone_instances` (stopped, lost or replaced) · `outbound_mail` | 7 days · 1 day · 30 days · 7 days | Hourly job |
| Unverified account (`staging`, `production`) | 7 days | Purge (§11.2) |
| Deleted character | 7 days restorable; then tombstone; the name, 30 more days (or none, §4.4) | Hourly purge; the `reserved` row of `character_names`, the hourly job on expiry |
| Ledger, operations and item events of a living character, also the `actor_account_id`, the `note` and the `detail` of GM and REVERSAL operations (a second trace of those GM commands, besides `audit_log`) | As long as the character exists; after its purge, the row below | None: they are append-only (progression.md §3.5). The export gives them without the staff's data (§11.2). **Legal review** (also of `note` and of its having no deadline) |
| Ledger, operations and item events of a purged character | **1 year** from the purge. Without names: the tombstone has none and `detail.args` names the target by id (progression.md §10). While the account exists, linked to it and exportable (§11.2); pseudonymous only after purging it. The `note` of GM and REVERSAL operations is kept as moderation data | Hourly retention: `ProgressStore.PurgeRetention` (progression.md §3.5), with `set local eldmark.retention_purge = 'on'`; then the tombstones it returns empty are deleted. **Legal review** (also of `note`) |
| Deleted account | 14-day grace period | Purge (§11.2) |
| Sanctions | As long as the account exists; when purged, without the reason, and 1 more year | The purge empties `reason`; the hourly job deletes those of accounts with `purged_at` more than 1 year ago. **Legal review** |
| `sanctioned_email_hashes` | Until the sanction ends, or 90 days after it; 1 year at most | Hourly job. **Legal review** |
| Daily and weekly backups, WAL | 35 days; when restoring, purges are applied again (§12) | `backup.sh` and WAL-G |
| Container logs (zone, platform) | 30 days: the zone writes name and IP on every connection and rejection | journald (`MaxRetentionSec=30day`, §12) |
| `fortress_events`, `realm_resources` | No limit: they are not personal | — |

The "hourly job" in the table is `privacy_retention` (`internal/privacy`, P9a, §19.15), except for chat
(`chat_retention`, P7a) and the purges (`accounts_purge` and `characters_purge`, P1 and P2).

In `staging` and `production` with `--platform`, the zone does not admit `--battle-log`, `--combat-log` or
`--state-log` (they write names with no deadline; §5.5).

### 11.2 Export and erasure
**Export:** `POST /v1/account/export {password}` (1 per day; also with the privacy session of a sanctioned account,
§4.2) gives `eldmark-datos-<date>.json`: account (without the hash), acceptances, consents, 30 days of sessions and
logins, entitlements, characters with their progress (for each unpurged character, `ProgressStore.Export` under
`characters[i].progress`: record, operations, ledger entries and own events; and for each tombstone of the account
with a retained ledger, the same without the record; progression.md §3.5) and statistics, ignores (by name), own
sanctions, reports **made** and chat sent by their characters within the retention period. It does not give reports
received or moderation notes (third parties' data: **legal review**): for GM and REVERSAL operations it gives the
type, the date, the ledger entries and the events, without `actor_account_id`, `note` or `detail`.

**Purging a character** (when `restore_until` expires, with the account, or in `reapply-purges`), in one transaction:

1. `select … from character_leases where character_id = $1 for update`, if there is a row.
2. `select … from characters where character_id = $1 for no key update`, and check again whether it applies,
   depending on the path. **When `restore_until` expires**: `deleted_at` not null, `restore_until ≤ now()` and
   `purged_at` null (if it has been restored or is already purged, it does nothing). **With the account and in
   `reapply-purges`**: only `purged_at` null, because the account or `purge_log` decides: the living characters of an
   account being purged were never deleted, and a backup from before the deletion brings them with `deleted_at` null.
3. With a live lease (`zone_instance_id` not null and `expires_at > now()`), it does not purge (nor the account that
   includes it): the hourly purge retries within the next hour. It does not apply in `reapply-purges`, which runs
   without leases (below).
4. `ProgressStore.Purge(ctx, tx, id)` (progression.md §3.5: deletes the progress state and leaves the append-only
   data), `delete from character_pvp_stats`, `character_leases` and `enter_tickets` of that character,
   `character_names.character_id = null`, `update characters set name = null, name_key = null, purged_at = $t` and
   `insert into purge_log ('character', id, $t)`, with `$t = now()` (in `reapply-purges`, that from `purges.txt`).

The lock order is that of `persistence.Store.Save` (the lease first; the `characters` row is only touched by a save
through the foreign key of `op_participants`, which `for no key update` does not block): there is no deadlock, the
purge sees everything a save confirmed before, and a save arriving afterwards finds no lease (409 `lease_lost`, §7.3).
Restoring locks the account and the same `characters` row (§4.4) and the claim requires `deleted_at` and `purged_at`
to be null (§5.3). What remains is the **tombstone** (id, world, realm, account and dates) and the append-only data,
which the retention job of §11.1 deletes after a year; afterwards the `characters` row is deleted. It is the
character's only tombstone (there is no other in progress). Verified: deleting the character row with ledger entries
fails (foreign key) and the tombstone works fine.

**Erasing the account:** `POST /v1/account/deletion` (also with the privacy session) → 14 days → purge in one
transaction, which first locks the `accounts` row (account → leases → characters, the claim's order, §5.3): its
characters (as above; names reserved 30 days), ignores in both directions, sessions, tokens, consents, acceptances,
entitlements, the `reason` of its sanctions and the chat of its characters not copied into a report. The `accounts` row
remains as a tombstone (`email` and `password_hash` set to null, `status = 'purged'`, `purged_at`) so that audit and
sanctions point to nothing; `purge_log ('account', id)`. `admin --actor <email> purge-now <email>` does the same
without waiting (express request): first it revokes the sessions (`deletion`), waits up to 30 s for the leases to be
released (the heartbeat kicks with a final save) and, if any is still alive, answers `character_busy` and purges
nothing.

**Sanctioned emails.** If the account has a current suspension or ban, or a sanction within the last 90 days, the
purge stores `HMAC-SHA256(ELDMARK_EMAIL_HMAC_KEY, normalized email)` in `sanctioned_email_hashes` with `until` = end of
the sanction (or + 90 days), 1 year at most from the purge. Registration consults it (§4.2): the scale of social.md §9
keeps counting even if the player requests erasure and comes back. **Legal review**; it is also in `privacy-1.md`.

**Backups.** `backup.sh` copies `purge_log` (with `purged_at`) to `purges.txt` next to each backup and always keeps the
most recent one. Restoring is always `pg_restore` and then `eldmark-platform admin --actor <email> reapply-purges
purges.txt` with the **most recent** `purges.txt` (not the backup's): it purges accounts and characters again with the
`purged_at` from `purge_log`, not with `now()`, and from it come the ledger's year, the sanctions' one and the cap of
`sanctioned_email_hashes`: restoring does not lengthen any retention. It runs with the zones stopped and **before
starting `serve`** (the grace period of §2.5 would extend the restored leases): first it deletes all the backup's
`character_leases` and `enter_tickets`, which now belong to nobody, and then it purges. It is idempotent and exits
with a non-zero code if any id in `purges.txt` remains unpurged. `restore_check.sh` does it too.

### 11.3 Account entitlements (PRG-41)
`entitlements` works for a one-time purchase, a subscription or free-with-store: slots (`character_slots`), expansions
(`expansion`, `ref` = id) and cosmetics (`cosmetic`, `ref` = PRG-40 id). **No entitlement reaches the simulation or
combat**; the zone will only receive cosmetics (phase 8). The business model is decided by the user and noted in
vision.md.

### 11.4 Legal texts and consents
- `platform/legal/terms-1.md`, `privacy-1.md` and `rules-1.md` (the rules of social.md §9 and `docs/normas.md`,
  SOC-18): **drafts** with the header "Borrador pendiente de revisión legal; no es asesoramiento jurídico" (draft
  pending legal review; not legal advice). On startup, the platform computes their SHA-256 and inserts the version
  into `legal_documents` if missing. `privacy-1.md` includes the whole table of §11.1.
- Age: checkbox "Tengo 16 años o más" (I am 16 or older) (`age_confirmed_at`; **legal review**: in Spain it is from
  14). Separate consents, unchecked and changeable in Settings: crash reports (TEC-42) and analytics (TEC-44).

## 12. Operations (TEC-28)

| Piece | Here (automatable) | On the VPS (user) |
|---|---|---|
| Local development | `deploy/dev.sh`: ephemeral PostgreSQL in `build/dev_pg` (as in §2.6), `migrate up`, keys and one token per development zone (`1:vado_gris:0`, `1:test_world:0`) in `build/dev_platform.env`, `admin create-account prueba@eldmark.test` (and an `admin` account for `--actor`) and the zone's command with `--platform` | — |
| Image | `deploy/Dockerfile`: static binary (`CGO_ENABLED=0`) on `debian:bookworm-slim`, unprivileged user | Image registry (GHCR) |
| Compose | `docker-compose.yml` with `db` (postgres:16), `platform`, `caddy` and the TEC-20 zones (`restart: unless-stopped`); secrets from `secrets/`; `logging: {driver: journald, options: {tag: "{{.Name}}"}}` on all; `staging.env.example` and `production.env.example`. `docker compose config -q` validates it without a daemon (verified) | Databases and secrets per environment; staging from `main`, production from tags (SSH); `journald-eldmark.conf` (`MaxRetentionSec=30day`, `SystemMaxUse=2G`) in `/etc/systemd/journald.conf.d/` (unverified here: there is no systemd) |
| Maintenance | `admin --actor <email> maintenance --in 10m --message "…"`: `/v1/status` announces it, `enter` answers 503 except to `admin`, and the heartbeat passes it to the zones, which warn by NOTICE at 10, 5 and 1 min, 30 s and 10 s, save everyone and stop on their own. `admin maintenance off` removes it | `deploy.sh`: previous backup, stop, `migrate up`, new version, remove maintenance |
| Rollback | `down` only in development and CI; expand-and-contract migrations (§2.4) | **Restore the previous backup** (with `reapply-purges`) or fix forward; the previous tag works with the new schema |
| Backups | `backup.sh`: `pg_dump -Fc` with 7 daily and 4 weekly in a directory, and `purges.txt` (§11.2) | Upload them to S3-compatible storage (rclone or WAL-G) and the cron job |
| WAL and point-in-time recovery | `pitr_check.sh`: ephemeral cluster with `archive_command`, `pg_basebackup`, `recovery_target_time` and `recovery.signal`: recovers the rows from before a deletion (verified in seconds) | `archive_command` to S3 with WAL-G; 35-day retention |
| Weekly restore | `restore_check.sh <backup> <purges.txt>`: ephemeral cluster, `pg_restore` (verified: 1000 rows in 188 ms), `reapply-purges`, `migrate status` up to date and integrity queries (characters without an account, leases of non-existent instances, `purge_log` ids with personal data: 0; and no `audit_log` row whose `args` contains the email of an account in `purges.txt`, which it reads from the backup before `reapply-purges`) | Run it every week and alert on failure (TEC-31) |

## 13. Client (UI-22, UI-23, UI-24)
### 13.1 Flow
```
title ──Entrar──▶ (accept new texts) ──▶ selection ──Entrar──▶ OnlineMain with ticket
  │ Crear cuenta · ¿Has olvidado la contraseña?      │ Create ──▶ creation ──▶ selection
  └ Ajustes (F10) · Salir                            │ Borrar · Restaurar · Cerrar sesión ──▶ title
OnlineMain: rejection or disconnection ──▶ selection with the reason (the session continues)
```

(The labels in Spanish are the UI buttons, which stay in Spanish for now.)

`FrontMain` (`scenes/client/front_main.tscn`) mounts the screens and keeps the `AccountSession`. On entering, it uses
`AccountFlow.enter` (§13.3) and passes to `OnlineMain` the `ClientConfig` it returns (host, port, `character_id`,
ticket, DTLS certificate, name and realm); with `config.from_front`, `OnlineMain` returns to `FrontMain` instead of to
`RealmSelect`. The visuals are **provisional**: UI-02 theme, `UIWindow`, `UIConfirmDialog`; the background, logo and
music belong to ART-21.

### 13.2 Screens
The contents quote the UI texts, which are in Spanish.

| Screen | Content | Keyboard |
|---|---|---|
| Title (UI-22) | Provisional background (still capture of Vado Gris), "Eldmark" in the title font, status ("En línea · Eld", "En mantenimiento hasta las 18:00", "Sin conexión con el servidor") and news from `/v1/status`; email, password, "Recordar correo" (remember email) (`user://settings.cfg`, section `account`; never the password), Entrar, Crear cuenta, ¿Has olvidado la contraseña?, Ajustes, Salir | Enter submits; Tab cycles; Esc closes the panel |
| Create account | Email, password twice (minimum 10), "Tengo 16 años o más", three checkboxes with a link to each text (scrolling panel) and the two optional consents. On submit: "Te hemos enviado un correo" (in `dev` and `test`, it logs in with what was typed) | |
| Recover · accept texts | Email → "Si existe una cuenta, te hemos enviado un enlace" (if an account exists, we have sent you a link) · what has changed, Aceptar or Cerrar sesión | |
| Sanctioned account | With the privacy session (§4.2): the reason and the end date, and only Descargar mis datos, Borrar la cuenta and Cerrar sesión | Esc logs out |
| Selection (UI-23) | List on the left (name, realm emblem, level, last zone; deleted ones in gray with "Restaurar" and their deadline), 3D view of the chosen one (`HumanoidVisual` with its appearance, `CharacterAppearance.decode` and `AppearanceApplier.apply` from progression.md P3 and P6, and its realm's colors; until they exist, the humanoid with those colors), free slots ("Los borrados que aún puedes restaurar ocupan hueco", i.e. deleted characters you can still restore take up a slot), Entrar, Crear, Borrar (confirmation by typing the name), Cerrar sesión | Arrows choose, Enter enters, Del deletes |
| Creation (UI-24) | 1) Realm: cards with lore, emblem and capital; fixed to the account's; Askarra "Próximamente". 2) Body and appearance (body, head, hair, colors, random with `CharacterAppearance.random`, orbit camera with the mouse) with whatever ART-19 and ART-20 provide (`AppearanceApplier.apply`); without them, the humanoid with the realm's colors. 3) **Starting template** (cards for the `starter_templates` templates, the `selectable` ones of PRG-07: weapons and style; it is the kit for the first entry, progression.md §2.5). 4) Name validated with `NameRules` while typing and with `name-check` after 500 ms of stillness. Crear | Esc goes back one step |
| Rename · busy | Name dialog on receiving `rename_required` · "Tu personaje está saliendo del mundo…" with a countdown; retries every 3 s for 30 s | |

Errors: the text from §4.1 under the form; offline or on a TLS failure, "No se puede conectar con el servidor de
cuentas" (cannot connect to the accounts server). The new REJECTs return to the selection with their text.

### 13.3 Configuration, `AccountFlow` and files
`ClientConfig` adds `platform_url` (`--platform=`), `login` (`--login=`), `password_file` (`--password-file=`),
`character_name` (`--character=`), `world_id` (`--world=`, 1), `title` (`--title`), `dtls_cert_path`
(`--dtls-cert=`) and `dtls_name` (`--dtls-name=`) and, for `OnlineMain`, `character_id`, `ticket: PackedByteArray`,
`dtls_cert_pem` and `from_front`; and the `TITLE` mode. Priority: `--bots` > `--bot` > `--connect`/`--local` >
`--title`/`--platform` > no arguments (sandbox in the editor, title when exported). Project setting
`eldmark/platform/url` (`http://127.0.0.1:24680`; the test export changes it).

**`AccountFlow`** (`scripts/client/platform/account_flow.gd`, no interface) does the account path: `login`,
`ensure_character` and `enter`, which returns the `ClientConfig` with a ticket. `FrontMain` and `OnlineMain` in `BOT`
mode use it when `config.platform_url` is not empty: the bot reads the password from `--password-file`, logs in,
creates the character if it does not exist (with the first template by `id` from the rules and
`CharacterAppearance.default_for(catalog, race)`) and connects. A failure (credentials, `character_busy` after 30 s,
`zone_unavailable`) exits with code 1 and the `code` in the report. Without the platform, the bot connects as today to
`--connect` (or to 127.0.0.1:24600).

New: `scripts/client/platform/` (`platform_api.gd`, `api_result.gd`, `account_session.gd`, `account_flow.gd`,
`platform_errors.gd`), `scripts/client/front_main.gd` and `scripts/client/ui/` `title_screen.gd`, `register_panel.gd`,
`terms_panel.gd`, `character_select.gd`, `character_create.gd`, `rename_dialog.gd` (scenes in `scenes/ui/`).
`ClientLauncher` takes `TITLE` to `FrontMain`; `NetClient` puts the `ClientConfig`'s `character_id`, `ticket`, `realm`
and `name` in the HELLO and passes the certificate to `NetTransport.connect_to` (§10.2).

## 14. Packages and contracts
### 14.1 Packages
| Package | Content | Depends on |
|---|---|---|
| **P0 · skeleton** (TEC-22) | `platform/`, config, `logx`, `db`, `jsonx`, `migrate` and 0001–0006, `testdb`, `/health`, `/ready`, `serve`/`migrate`, `.gdignore`, export filter, `.gitignore` (§10.3), CI job with the secrets check | TEC-03 |
| **P1 · accounts** (TEC-23, TEC-41, acceptance part of TEC-43) | `passwords`, `accounts` (`CheckPassword`, failures per account and group), sessions with rotation in the row, limits, lifecycle, `revert_email`, `mail`, pages `/verify`, `/reset`, `/revert`, `/v1/status`, `/v1/legal`, purge of unverified accounts, privacy session for sanctioned accounts (`sessions.scope`, §4.2) | P0 |
| **P2 · characters** (TEC-24, SOC-13, PRG-41) | `names` and `tests/fixtures/names/`, `gamedata` (the `names` section of `progression_rules.json` and its embed), the `ProgressStore` interface with its errors (`InvalidSaveError`, `ErrNotFound`) and its fake, `CreateValidator` with `ValidationError` and the provisional validation (§4.4 step 5, §7.5), characters, realms, slots, create and delete limits, delete and restore with the account lock (§4.4), `enter` (one character in the world per account), `tickets` | P1 (progression.md P7 provides `*progress.Rules` and the store with `Summaries`; `serve` picks them without touching the handlers) |
| **P3 · internal API** (TEC-24, TEC-25) | `zones` (per-deployment tokens, registration, `live`, heartbeat, lost instances, replacement, states of §6.1), claim (account lock and one character in the world per account, §5.3), save (strict envelope, lease, `seq`, hash, `last_save_version`, `pvp` with `greatest`, errors of §7.3), release, batches (with per-entry rejection and `zone_channel` in chat), `uid_block_seq` and `id_blocks`, routes for blocks, operation and ledger (with lease) over the `ProgressStore` interface, fortresses (only those of the instance's zone, §6); the `ProgressStore` fake in tests | P2 |
| **P4 · ticket in the zone** (TEC-24) | `HandoffTicket`, `TicketAuthProvider`, extended `AuthProvider` and `ServerAuth`, `VERIFYING` (capacity and deadline), drop in `LOADING` (§5.2), REJECT 10–12, `PROTOCOL_VERSION` 7 and `AUTH_TIMEOUT_SECONDS` (the bump for all of phase 5; progression.md P4 adds its part without bumping it, §5.4), GM bit, networking.md (the v7 part from here, §5.4), `ZonePlatform` (with `RECORD_FORMAT`, the heartbeat set, `save` with `lease_id` and `release_lease`, and the `kind`s of `PlatformEvent`, §14.3), `PlatformClient` (priorities), `ClaimedCharacter`, `AuthOutcome`, `tests/fake_zone_platform.gd` with its test API (§14.3; it stores per character the last applied value of each section and returns it in the next claim: `pvp` here; `progress` without `ops`, with the read-only fields of the previous claim and `location.saved_at_unix` set, added by progression.md P5a), `tests/support/fake_http_server.gd`, `ServerConfig` options, startup of §8 (registration, `env`, `live`), fencing, no `REJECT NAME` with a ticket (§5.4) | abilities.md merged: H2 (protocol 6) and H3c (the last of abilities.md in `zone_server.gd`). The contracts of P3 (not its code: it uses the fakes) |
| **P5 · saving in the zone** (TEC-25; CMB-30 and GUE-19 hooks) | `CharacterSaver` (sections, whole envelope, entries by `lease_id`, `track` when creating the entity, `on_platform_event`, `save_rejected`, `drop`), combat logout, drop without saving (§7.2), orderly shutdown (`begin_flush`, extended `_drain_stop`, `SHUTDOWN_MAX_FRAMES`, release of `LOADING` and `VERIFYING`), maintenance countdown, `revoked`, shutdown of §6.1 (`instance_closed` in `ServerMain`) | P4 (tested with a fake section; the `progress` one belongs to progression.md P5a) |
| **P6 · war** (GUE-19) | `FortressPersistence`, loading at startup, `expected_version`, events, `ScoreKeeper.captures` (excluding those forced by a command and characters with `gm_forced`, progression.md §6.2) and `defend_ticks`, the forced-change flag in `FortressController`, the `NetEntity.gm_forced` field (false by default; respawning clears it), `pvp` section | P3, P5 |
| **P7a · moderation in Go** (SOC-14 to SOC-18) | Roles, `set-role` that revokes (with its fixed row of §9.1), audit (also of reads, without emails or names, §9.1), chat, ignores, reports, sanctions with authorization, `admin` CLI with `--actor` | P3 |
| **P7b · moderation in the zone** (SOC-14 to SOC-18) | `min_role` in `CommandRegistry` and DEBUG_COMMAND with role (tested with network and moderation commands; 40–43, the `admin` of 5, 13 and 16 and the rule on one's own characters belong to progression.md P5d), `/gm`, invisible, setting `gm_forced` with `/gm teleport`, `/gm visible` and DEBUG_COMMAND 1, 2 and 4 (progression.md §6.2), ignore filtering, report ring, mutes, chat and audit batches, responses for `ignore`, `report` and `sanction`, `ChatPeerState` per `character_id`, with `KNOWN_RECIPIENT_TICKS` kept after the drop and reattached on entry (§9.2) | P5, P7a; SOC-03, SOC-04 |
| **P8 · client** (UI-22 to UI-24) | `ClientConfig`, `PlatformApi` (one refresh at a time), `AccountSession`, `AccountFlow`, `FrontMain`, screens, `NetClient` and `OnlineMain` with ticket, sanctioned-account screen (privacy session), bot with an account | Contracts of P1 and P2 (with `request_hook` until they exist); progression.md P3 and P6 (appearance), ART-19 and ART-20 for the full creation screen |
| **P9a · privacy** (TEC-43) | Export (also tombstones with a ledger), purges (locks, tombstones, `purge_log`), retention (unclosed reports, sanctions of purged accounts), `sanctioned_email_hashes`, `reapply-purges` with the original `purged_at`, legal drafts | P1–P3; progression.md P7 (`Purge`, `PurgeRetention`, `Export`) |
| **P9b · operations** (TEC-28) | Caddy, compose (journald, secrets), `dev.sh`, `backup.sh` with `purges.txt`, `restore_check`, `pitr_check` | P9a; TEC-20 for the zone images |
| **P9c · DTLS** (TEC-27) | `NetTransport.host`/`connect_to` with `TLSOptions`, `--dtls-*` in `ServerConfig` and `ClientConfig`, `SwarmBot`, measurement campaign and its entry in networking.md §14 | P4 |
| **P10 · end to end** | `platform/e2e` and its CI job (§15) | P3, P4, P5, P8; progression.md P7 |

P0 first; then P1 and, as soon as abilities.md is merged, P4 (against the fakes); then P2, P3 and P8; then P5, P6,
P7a and P7b; P9a, P9b, P9c and P10 at the end. The progress store (0010, `internal/progress`) is progression.md P7,
with the dependencies in its §14.1 (among them, the cases of progression.md P5a, which comes after P4 and P5 here); P9a
and P10 wait for it. P4 here bumps the protocol to 7, on top of abilities.md's 6, and progression.md P4 adds its part
(§5.4). **`zone_server.gd`**, with the three documents, in this order: abilities.md H3c → P4 → progression.md P4 →
P5 → progression.md P5a → progression.md P5b → P6 → progression.md P5c → P7b → progression.md P5d. Between documents, the
name always goes first ("platform.md P4").

### 14.2 Contracts in Go
```go
// internal/tickets
const Size = 52
type Ticket struct { Version, KeyID uint8; WorldID uint16; TicketID, CharacterID uint64; ZoneKey uint32
	Channel, Realm, Arrival, Flags uint8; IssuedAt, ExpiresAt uint32 }
func ZoneKey(zoneID string) uint32                                   // sha256(zoneID)[0:4] in LE
func (t Ticket) Sign(key []byte) [Size]byte
func Parse(b []byte, keys map[uint8][]byte) (Ticket, error)          // ErrSize, ErrVersion, ErrKey, ErrMAC
// internal/passwords
type Params struct { MemoryKiB, Time uint32; Threads uint8 }
func Hash(password string, p Params) (string, error)                 // $argon2id$v=19$m=…,t=…,p=…$salt$hash
func Verify(password, phc string, current Params) (ok, needsRehash bool, err error)
// internal/accounts
func (s *Service) CheckPassword(ctx context.Context, accountID int64, email string, password string,
	ip netip.Addr) (bool, error)  // ErrThrottled → 429; key: accountID if ≠ 0, otherwise SHA-256(normalized email)
// internal/jsonx: type Int int64 (accepts 4 and 4.0); type ID int64 (decimal string from 0 to 2^63 − 1; unquoted, error)
// internal/names: func Validate(name string) Reason (values of NameRules.Reason); func NormalizeKey(name string) string
//   cases: os.ReadFile("../../../tests/fixtures/names/name_rules_cases.json")
// internal/testdb: func Main(m *testing.M) int (in TestMain); func New(t testing.TB) *pgxpool.Pool (new database)
// internal/zones
type Scope struct { WorldID int16; ZoneID string; Channel int16 }
func (r *Registry) Authenticate(bearer string) (Scope, bool)         // SHA-256 and subtle.ConstantTimeCompare
// internal/persistence
func (s *Store) Claim(ctx context.Context, instance [16]byte, ticketID, characterID int64) (ClaimResult, error)
func (s *Store) Save(ctx context.Context, characterID int64, raw []byte, req SaveRequest) (SaveResult, error)  // raw: for the hash
func (s *Store) SaveMany(ctx context.Context, instance [16]byte, raws [][]byte, reqs []SaveRequest) ([]SaveResult, error)  // all or nothing
func (s *Store) Release(ctx context.Context, characterID int64, instance, leaseID [16]byte) error
// internal/persistence/progress.go (P2): ProgressStore, InvalidSaveError, ErrNotFound, CreateValidator and
//   ValidationError (progression.md §13.2), with the store's fake and the provisional validation (§4.4 step 5);
//   they are implemented by internal/progress (progression.md P7), which imports persistence
```

### 14.3 Contracts in GDScript (zone)
```gdscript
# scripts/server/auth_provider.gd (extends; DevAuthProvider: OK instantly, uses_tickets() false and on_platform_event false)
const PENDING: int = -1
func authenticate(peer_id: int, hello: NetMessages.Hello) -> int  # OK, PENDING or a REJECT reason
func on_platform_event(event: PlatformEvent) -> bool  # true if it was its own (kind claim)
func take_completed() -> Array[AuthOutcome]     # the resolved PENDING ones, in arrival order
func cancel(peer_id: int) -> void               # the peer left in VERIFYING: releases if it got to claim
func uses_tickets() -> bool                     # true: ServerAuth does not look at the HELLO's realm or name
# scripts/server/platform/auth_outcome.gd
class_name AuthOutcome extends RefCounted
var peer_id: int; var result: int; var text: String; var claimed: ClaimedCharacter   # empty text: result_text
# scripts/server/platform/handoff_ticket.gd: one var int per field of §5.1, with its name
class_name HandoffTicket extends RefCounted
const SIZE: int = 52
static func zone_key_of(zone_id: String) -> int
static func decode(bytes: PackedByteArray) -> HandoffTicket      # null if size or version are invalid
func verify(bytes: PackedByteArray, keys: Dictionary[int, PackedByteArray]) -> bool
func sign(key: PackedByteArray) -> PackedByteArray                # tests and the fake
# scripts/server/platform/claimed_character.gd (P4)
class_name ClaimedCharacter extends RefCounted
var character_id: int; var account_id: int; var world_id: int; var realm: int; var display_name: String
var role: StringName; var lease_id: String; var muted_until_unix: int; var ignored_accounts: PackedInt64Array
var progress: Dictionary      # the progress section as it arrives; read by ProgressRecord.from_dictionary (progression.md §14.2)
var pvp: Dictionary           # {kills, deaths, assists, captures, gate_damage, defend_s} already with int()
static func from_claim(body: Dictionary) -> ClaimedCharacter      # null if anything is missing; ids with to_int() and integers with int()
# scripts/server/platform/zone_platform.gd (tests/fake_zone_platform.gd: class_name FakeZonePlatform extends ZonePlatform)
class_name ZonePlatform extends Node
signal startup_finished(ok: bool, error: String)                  # after registration, the fortresses and the first block (§8)
const RECORD_FORMAT: int = 1                                      # registration's record_format (§7.1) = ProgressRecord.FORMAT
var timeout_s: float = 3.0
func start(config: ServerConfig, secrets: Dictionary) -> void     # registration (starting), heartbeats, fortresses, first block
func fortress_records() -> Array[Dictionary]                      # those loaded in start
func env() -> StringName                                          # &"dev", &"test", &"staging" or &"production"
func instance_id() -> String                                      # zone_instance_id; "" before registration
func go_live() -> void                                            # POST …/live, after opening the port
## Heartbeat set {character_id: lease_id} (§5.3): enters with the claim's 200, changes with another claim of the same
## character and leaves with release() or with the definitive response of a save with release_lease, if it is still that lease_id.
func claim(peer_id: int, ticket: HandoffTicket) -> void
func claimed(character_id: int) -> ClaimedCharacter               # the last claim for that character
func release(character_id: int, lease_id: String) -> void         # pending by lease_id; a 4xx is definitive (§7.3)
func save(character_id: int, lease_id: String, body: PackedByteArray, release_lease: bool,
		context: Variant) -> void   # body: CharacterSaver's whole envelope, sent untouched until a definitive response
func request_id_block() -> void                                   # the result, an id_block event for ProgressService
func put_fortress(fortress_id: StringName, record: Dictionary) -> void  # one in flight per fortress; the most recent
func enqueue_batch(kind: StringName, entry: Dictionary) -> void   # &"chat", &"audit", &"war"; sets key if the entry has
		# none ("<zone_instance_id>:<n>"); one that has it (op:<op_id>) keeps it
func request(kind: StringName, method: HTTPClient.Method, path: String, body: Dictionary, priority: int,
		context: Variant) -> void                                 # sets zone_instance_id: in a GET's query, in
		# the body of the others; the caller does not set it. kind: &"progress_op", &"progress_ledger", &"ignore",
		# &"report" or &"sanction"
func take_events() -> Array[PlatformEvent]                        # in the "poll" step; the kinds are below
func begin_flush() -> void                                        # shutdown: pending batches and saves go out now
func is_flushed() -> bool                                         # nothing queued or in flight
func is_fenced() -> bool                                          # no heartbeat accepted in 2 × heartbeat_s
func is_live() -> bool
func now_unix() -> int                                            # corrected clock
# tests/fake_zone_platform.gd (P4): no network; JSON round trip like PlatformClient and responses in the next "poll"
# (or after delay_s). It is the only test API: the tests of both documents use it.
class_name FakeZonePlatform extends ZonePlatform
var fake_env: StringName = &"test"                                # the fake registration's env
var next_block_first: int = 1025                                  # each block (one inside start, before
		# startup_finished, and one per request_id_block) goes out as an id_block event {first, count: 1024} and goes up by 1024
func add_character(character_id: int, account_id: int, role: StringName, realm: int, progress: Dictionary,
		pvp: Dictionary = {}, display_name: String = "") -> void   # what its claim returns (new lease_id on
		# each one; without a name, NameRules.bot_name(id)); without it, 409 ticket_invalid
func script_next(kind: StringName, status: int, body: Variant, delay_s: float = 0.0) -> void
		# the next request of that kind (claim, save, release, heartbeat, id_block, progress_op, progress_ledger,
		# ignore, report, sanction…) receives that response, once; status 0 = offline (transport_ok false);
		# body FakeZonePlatform.DEFAULT = the default response with that status and that delay (P4, §19.8)
func set_fenced(fenced: bool) -> void                             # is_fenced() returns it until changed
func applied(character_id: int) -> Dictionary                     # the last body applied; {} if none
func sent(kind: StringName) -> Array[Dictionary]                  # the bodies received of that kind, in order
## By default: claim → 200 with what add_character gave and, if there were saves, the last applied value of each section (§14.1);
## save → 200 applied with a rising save_version; release → 204; heartbeat → 200 without revoked; progress_op and
## progress_ledger → 404; batches → 204; ignore, report and sanction resolve target_name among the registered
## characters (P7b, §19.12: with set_account_state(character_id, muted_until_unix, ignored, warnings) and queued(kind)).
## progression.md P5a adds only the progress part of the next claim and
## static func claim_progress(race_id: StringName, appearance: PackedByteArray, starter_template_id: StringName)
## -> Dictionary, which builds it with ProgressRecord.new_character() and to_claim_dictionary(now_unix()).
# scripts/server/platform/character_saver.gd (P5)
class_name CharacterSaver extends RefCounted
enum Reason { CHECKPOINT = 1, CRITICAL = 2, LOGOUT = 3, SHUTDOWN = 4, KICK = 5 }
signal save_rejected(net_id: int, character_id: int, code: String)   # lease_lost, invalid_save…: the zone kicks.
		# Only before finish: afterwards, the definitive response is only logged (§7.2)
func _init(platform: ZonePlatform, interval_ticks: int = 3600) -> void   # only with --platform
## Entries by lease_id, with the indexes character_id → current lease_id and, until finish or drop, net_id → lease_id;
## each response is matched by the lease_id and the seq of its context (§7.2). Builds the whole envelope of §7.3.
## build(net_id: int, seq: int) -> Dictionary: once per seq; the serialized body is kept and resent byte for byte;
##   {} = cannot be built right now (§7.2)
## acknowledge(net_id: int, seq: int) -> void: after 200 applied or duplicate, only before finish
## is_dirty(net_id: int) -> bool: whether there is anything to save at the checkpoint; only before finish
func register_section(section: StringName, build: Callable, acknowledge: Callable, is_dirty: Callable) -> void
func track(net_id: int, character_id: int, lease_id: String, tick: int) -> void   # when creating the entity, before on_arrival
func mark_critical(net_id: int, reason: StringName) -> void           # reason: only logs and metrics (progression.md §9.2)
func step(tick: int) -> void                                          # after "spawns"
func finish(net_id: int, reason: int) -> void                         # snapshot on the spot, with release_lease; unties the
		# net_id. On a net_id with no entry (already went through drop), nothing
func drop(net_id: int, code: String) -> void                         # drop without saving (§7.2): unties, discards the final save
		# it was waiting on and calls release except with code lease_lost. On a net_id with no entry, nothing
func on_platform_event(event: PlatformEvent) -> bool                  # true if it was a save's response
func pending_count() -> int
```

- `PlatformEvent` (`kind`, `context`, `transport_ok`, `status`, `body`, `error_code`) is the result of a request, with
  `body` already read: `null` if the body is empty or the status is 204; otherwise, `JSON.new().parse(text)` and, if
  it fails, `body = null` and `error_code = "bad_json"`. Never `JSON.parse_string`, which writes an engine ERROR on an
  empty or broken body (`battle_summary.gd` already avoids it this way) and the runner counts it as a failure.
  `FakeZonePlatform` reads the same way. Each reader converts its own part (ids with `to_int()`, integers with
  `int()`): `ClaimedCharacter.from_claim` the account, the character and `pvp`; the `progress` section reaches
  `ProgressRecord.from_dictionary` as is, which does the same (progression.md §3.4).
- **`PlatformEvent.kind`** is one of these, and each has a single consumer:

  | `kind` | What | Handled by |
  |---|---|---|
  | `&"claim"` | Response to a claim | `auth_provider` (P4) |
  | `&"save"` | Response to a save | `CharacterSaver` (P5) |
  | `&"heartbeat"` | Heartbeat response: `revoked`, `mutes` and `maintenance` | `ZoneServer` (P5: kicks and the maintenance countdown of §7.2; P7b: mutes) |
  | `&"id_block"`, `&"progress_op"`, `&"progress_ledger"` | Id blocks, operation and ledger | `ProgressService` (progression.md P5a and P5d) |
  | `&"fortress"` | Response to a fortress PUT | `FortressPersistence` (P6) |
  | `&"ignore"`, `&"report"`, `&"sanction"` | Responses to `/ignorar` and `/designorar`, `/reportar` and the `/gm` sanctions | `ModerationService` (P7b) |
  | `&"instance_closed"` | `instance_lost`, `instance_replaced` or `instance_stopped` in any response or in `instance_status` (once) | `ServerMain`: the shutdown of §6.1 (P5) |

  The responses to release and to batches do not come out of `ZonePlatform`: it retries until a definitive one and
  logs rejections. The responses to registration and to the fortresses GET end up in `startup_finished`. The first
  block's too, and in addition it goes out as an `id_block` event for `ProgressService` (§8). The `live` one is only
  logged and, if its retries run out, the zone exits (§6). An `instance_not_live` is only logged (§6.1).
- `ServerConfig` adds `--platform=<internal url>`, `--world=<id>` (1), `--channel=<n>` (0),
  `--public-address=<host>[:<port>]` (127.0.0.1 and its port), `--save-interval=<s>` (60), `--replace`, `--dtls-cert=`
  and `--dtls-key=`.
- `ZoneServer.start(config, world, transport, auth_provider, platform: ZonePlatform = null)`: with a platform, it
  applies `platform.fortress_records()` before `_transport.host`. `ServerMain` picks the `AuthProvider`, waits for
  `startup_finished`, calls `start` and, if all goes well, `platform.go_live()`. `ServerAuth.validate` receives the
  `peer_id` as its first argument to pass it on.
- `ZoneServer.get_player_count()` counts `VERIFYING` (§5.2). `_drain_stop` does not move to `STOPPED` while
  `saver.pending_count() > 0` or `not platform.is_flushed()`, with a cap of 600 ticks; `ServerMain.SHUTDOWN_MAX_FRAMES`
  goes from 90 to 720. `HTTPRequest` advances with the main loop, which stays alive while `ServerMain` waits with
  `await get_tree().physics_frame`: there are no synchronous waits.
- **Tick order** (extends zone_server.gd): in `poll`, after the transport, `platform.take_events()` is distributed by
  `kind` (table above), in the order they arrived; `instance_closed` is handled at the end of the distribution. Then,
  `auth_provider.take_completed()` and, for each 200, the steps of §5.2 (`ProgressService.prepare` included). On every
  tick, the expired `VERIFYING` ones (7 s in real time); after `spawns`, `CharacterSaver.step(s)`. Progress requests go
  out through `ZonePlatform.request_id_block()` and `ZonePlatform.request(kind, …)`.
- **Spawns and drops.** `_process_arrivals` calls `saver.track(net_id, character_id, lease_id, s)` as soon as it
  creates the entity and before `progress.on_arrival` (which gives the starting kit and marks it critical,
  progression.md §2.5): this way that critical save goes out at once. A drop in `VERIFYING` calls
  `auth_provider.cancel(peer_id)`; one in `LOADING`, `platform.release(character_id, lease_id)` and
  `progress.cancel_prepared(peer_id)` (§5.2); one in the world, the exit of §7.2, and one through `save_rejected` or a
  `lease_lost` `revoked`, the drop without saving of §7.2. `ZoneServer.stop` does what §7.2 says ("Orderly shutdown")
  before `begin_flush`; the shutdown of §6.1 is `ZoneServer.close_instance(code)`, which `ServerMain` calls with the
  code of `instance_closed` (P5, §19.9).

### 14.4 Contracts in GDScript (client)
```gdscript
# scripts/client/platform/platform_api.gd
class_name PlatformApi extends Node
signal session_lost(code: String)               # refresh impossible: back to the title screen
var base_url: String
var request_hook: Callable = Callable()         # tests: (method, path, body) -> ApiResult
## Coroutine: var r: ApiResult = await api.call_api(HTTPClient.METHOD_POST, "/v1/sessions", {…}, false)
## A single refresh in flight: calls that need it wait for its result (internal signal refreshed).
func call_api(method: HTTPClient.Method, path: String, body: Variant = null, auth: bool = true) -> ApiResult
# scripts/client/platform/api_result.gd and account_session.gd
class_name ApiResult extends RefCounted
var ok: bool; var status: int; var data: Dictionary; var code: String; var message: String; var retry_after_s: int
class_name AccountSession extends RefCounted
var access_token: String; var refresh_token: String; var access_expires_msec: int; var account: Dictionary
func needs_refresh(now_msec: int) -> bool       # within 60 s of expiring
func clear() -> void
# scripts/client/platform/account_flow.gd
class_name AccountFlow extends RefCounted
func _init(api: PlatformApi) -> void
func login(email: String, password: String) -> ApiResult                  # coroutine; stores the AccountSession
func ensure_character(world_id: int, name: String, realm: StringName) -> ApiResult   # data.character; creates it if missing
func enter(character_id: int, base: ClientConfig) -> ApiResult            # data.config: ClientConfig with a ticket
```

## 15. Tests

Each test, under 30 s (Go with a warm cache), except those of P10 (below). Go: `cd platform && go test ./...`; Godot:
the usual runner, which fails on any engine error. Go's clock is injectable (`clock.Now`) for deadlines.

| Package | Tests |
|---|---|
| P0 | `migrate`: up, down to the irreversible one and up with the same schema; an irreversible one does not go down; preservation with the seeds; altered checksum → error; two runners at once (lock). `config`: missing variable → does not start; 31 B ticket key → does not start; the vector's key outside `test` → does not start; `MIN_PROTOCOL` absent in `production` → does not start. `/ready` with the database stopped → 503. `jsonx`: `4.0` is accepted, `4.5` and an unquoted id are not; a 2^63 − 1 id as a string is accepted and a larger one is not. `migrate`: one pending below the highest applied → refuses; `serve` with a migration later than its own starts |
| P1 | Good password, bad password and non-existent email (same code and body); 5 failures from IP B → 429 at B and the owner gets in from A; 5 failures with non-existent email A from group X, and afterwards non-existent B and existing C from X (bad password) get the same thing (`invalid_credentials`, not 429); failures through `/v1/account/password` count the same (the sixth → 429); suspended with a bad password → `invalid_credentials`, with a good one → `privacy` session with the reason; with that of a banned account, erasure and logging out work and the other routes (also `enter`) give 403 `account_banned`; 11 attempts per IP → 429; registration with an existing email, a sanctioned one and a new one gives the same body (and its email in `outbound_mail`); expired access token → 401 and refresh; reusing the previous refresh token → session revoked; one from two rotations ago → 401 without revoking; the 12 h do not lengthen when rotating; a second session revokes the first; expired and used links; after changing the password or the email, the previous recovery link fails and the `revert_email` remains valid; `revert_email` restores the email and forces recovery; export without a password → 400; an email with `\r\nBcc:` → 400 `validation`; `X-Forwarded-For: 1.2.3.4` and `X-Real-IP` from an untrusted origin do not change the limit's IP; the `/verify` form submitted like a browser (`application/x-www-form-urlencoded`, without `/v1` headers) verifies; `/verify?token=<script>` does not repeat it; deletion and cancellation within the grace period; unverified account purged after 7 days (clock); `needsRehash` |
| P2 | `names` with `tests/fixtures/names/name_rules_cases.json` and `test_progression_rules_export.gd` (Godot); two simultaneous creations of the same name (one `name_taken`); "Anéira" versus "ANEIRA" and "Aneira" (`name_taken` by accents and case); locked realm; slots (a character deleted within the grace period takes one); the sixth character created in a day → 429; creating and deleting right away frees the name at `restore_until`; template and race of another realm → 400; delete, restore and reserved name; `enter` with no live zone → 503; `enter` picks the last zone if it admits the realm; ticket vector of §5.1 |
| P3 | The `1:vado_gris:0` token does not register `vado_gris:1` or a host outside the list, nor send heartbeats for another instance (403); registration without `replace` with the old one beating → 409 `instance_alive`; with the old one still `live` but without a heartbeat for 3 × `HEARTBEAT_S` → it moves it to `lost`, frees its leases and registers the new one (no 500); with `replace` → `replaced` and a row in the audit; the replaced one sends its final save and it is valid; after `replace`, claiming a character of the old one gives `character_busy` until its final save with `release_lease` (or until the TTL) and then the claim brings that final save; `lost` instance that sends a heartbeat → 409 `instance_lost`; heartbeat with an old `lease_id` → `revoked` `lease_lost` and not renewed; claim to a `starting` one → `instance_not_live`; ticket consumed, expired, from another instance and from a revoked session (it is not left consumed); `character_busy` does not consume the ticket; refreshing the session with the character leased does not put it in `revoked`; two zones at once (one wins); freed after 15 s without a heartbeat (short deadlines); `seq`: expired deadline with a late commit and retry → `duplicate`, and the next one is applied without failing S2 (progression.md §13.3); same `seq` with another body → `seq_conflict`; lower `seq` → `stale_seq`; someone else's → `lease_lost`; no lease row (purged) → `lease_lost`; a `duplicate` returns the `save_version` from when it was applied; late after release (valid) and after another claim (not valid); `invalid_save` from the fake (`*persistence.InvalidSaveError`) → nothing written; a 23505 at COMMIT (the slots' deferred constraint) → `invalid_save`; a 40001 that repeats → 503 `db_unavailable` and nothing written; a save with `"kills": 4.0` is applied; a claim with a `ticket_id` > 2^53 is accepted; claiming a deleted character → `ticket_invalid`; with the account suspended, banned or with deletion requested → 403 `account_blocked` with its `kind`, `until_unix`, `reason` and a `message` of 255 B at most (with a long reason); a DELETE and a claim for the same character at once leave either a deleted one without a lease or a living one with it; two simultaneous claims for two characters of the same account: only one wins and the other gives `character_busy` (and `enter` for the second with the first in the world, too); envelope with an unknown field, `save_format` 2 or a `character_id` different from the route's → `invalid_save` `envelope`; a save without `pvp` does not change `character_pvp_stats` and one with a lower `kills` does not lower it; the heartbeat does not carry those in `VERIFYING` and `revoked` brings the `lease_id`; ledger of a character without a lease on the instance and operation without participants on it → 404; an audit batch with one bad entry inserts the rest and returns its key; an entry with `source = 'cli'`, with the `<uuid>:<n>` `key` of another instance or with an `op:<op_id>` from another instance's block, in `rejected`; registration without a certificate in `staging` → 400; fortress PUT with an old `expected_version` → `version_conflict`; PUT of a fortress of another zone → 403 and its war event, in `rejected`; the GET only gives those of the zone; a report, an ignore or a sanction with `world_id` in the body → 400, and without it they resolve the name in the instance's world; 100 concurrent saves of the same character: `save_version` = applied ones |
| P4 | `test_handoff_ticket.gd`: vector, altered signature, unknown key, another zone, expired, 5 s skew, reused; `test_net_messages`: REJECT 10–12 and GM bit; `test_zone_server_platform.gd` with `FakeZonePlatform` and real ENet: ticket → `VERIFYING` → WELCOME; no ticket → `TICKET`; **capacity of 4 with 5 in `VERIFYING` → `FULL`**; HELLO delayed 1.4 s with `GuardedEnetPeer` and claim at 5 s → WELCOME (10 s `auth_timeout`); silent platform → `UNAVAILABLE` at 7 s (real clock); fenced zone → `UNAVAILABLE`; peer that leaves in `VERIFYING` → release; peer that leaves in `LOADING` (and `revoked` in `LOADING`) → release without saving; a `revoked` with an old `lease_id` does not kick; `BUSY` with its text and `BANNED` with the 403's `message` (§6.1) on suspension, ban and pending deletion; `test_hello_cannot_probe_an_enemy_name` (with ENet, a HELLO with another character's ticket and the name of a connected enemy does not receive `NAME`; social.md 12.7); `--platform --debug-commands` with `env = production` → the zone exits; `ticket_id` > 2^53 in the claim body (Go and `FakeZonePlatform`) and `character_id` > 2^53 in `from_claim`. `test_platform_client.gd` with `FakeHttpServer` (TCPServer in the same process, scripted responses and delays): expired deadline and retry with the same bytes; the claim is not retried; **a heartbeat does not wait behind 4 slow saves**; a claim goes out even with 4 saves in flight; priority order; a 204, an empty body and a broken one → `body` null (`bad_json` for the broken one) without engine errors; `request` sets `zone_instance_id` and `enqueue_batch` the missing `key` without touching `op:<op_id>`; `save` sends the bytes untouched; the heartbeat set: enters with the claim, changes with another one for the same character and leaves with `release` or with the final save's definitive response, not with that of a save without `release_lease`; an `instance_lost` in the response to an id block gives a single `instance_closed`; a release with 403 is not repeated |
| P5 | With the fake (which does the JSON round trip like `PlatformClient`): checkpoint (test interval of 120 ticks), staggered phases, critical save at once, one write in flight, the final save waits behind the one in flight, `duplicate` counts as applied, `invalid_save` kicks and releases without saving, `lease_lost` kicks without releasing, `instance_lost` closes the zone with final saves and the kick NOTICE goes out after them (a player thrown out by `instance_lost` or `instance_replaced` who re-enters right away loads their final save), combat logout saves when the body leaves, **the drop without saving** (an `invalid_save` with the player in combat: the body leaves at once, it is released once, the "Exit" sends nothing and no `ProgressService` hook fails; a `revoked` `lease_lost`, the same without releasing), a 403 or a 413 on the save is definitive, **the orderly shutdown waits** with the fake answering at 2 s (with each of the five triggers) and releases those in `LOADING` and `VERIFYING`; the heartbeat's `maintenance` warns at 10, 5 and 1 min, 30 s and 10 s and shuts down; reconnection returns the last applied value of the fake section; a critical save marked right after `track` goes out at once; **a reused `net_id` with the previous one's final save still in flight**: the new one receives neither `acknowledge` nor `save_rejected` from the old one, and a late `invalid_save` from the old one is only logged and released; **the same character returns to this instance while its final save, already applied, is being retried**: the old entry receives `lease_lost` and it is only logged, and the new one is not kicked |
| P6 | `FortressPersistence` round trip (ticks ↔ Unix with a fixed clock); starting with `CONSOLIDATING` halfway keeps owner and deadline; `CAPTURING` comes back as `VULNERABLE`; **platform down at startup: the port does not open and the saved owner is not overwritten**; empty list → initial state with no warning; `version_conflict` → resend with the new version; captures and `defend_ticks` (owner only); a capture forced by a command does not count; reconnection keeps `pvp`; the final save is built before `ScoreKeeper.forget`; event batch resent without duplicating |
| P7a | A moderator requesting `ban` → 403 and a `sanction_denied` row; a GM does not sanction an admin; sanctioning without a lease on the instance → 403; expiry of each sanction type (warning, mute, suspension, ban, rename) with the injected clock; `set-role` revokes the sessions and the heartbeat kicks (≤ 5 s); `admin reports show` without `--actor` → error, and with it, a row in the audit; `admin chat` between two dates (with `zone_channel`) and what has expired disappears; no CLI `audit_log` row (`set-role`, `purge-now`, `chat --character`) nor a `sanction_denied` carries an email or a character name in `args`; `set-role` leaves the row of §9.1 (`source = 'cli'`, `command = 'set-role'`, `target_account_id` and `args` with `from`, `to` and `os_user`); an audit batch with an entry `source = 'cli'` or `command = 'set-role'` rejects it and S2 does not see it |
| P7b | Without a role → "Comando desconocido"; DEBUG_COMMAND 1 (`teleport`) without a role → warning and it does not move; `/gm silenciar` from a `player` → "Comando desconocido" and from a `moderator`, applied; an invisible GM deals no damage, receives none and does not count in the circle or the scoreboard; `/gm teleport` and `/gm visible` set `gm_forced` on the character they move or show, and respawning clears it; the audit entry carries `actor_account_id` and `source` `zone`; an ignored player does not whisper, does not invite and does not reach their zone channel; report with evidence and limit of 1 every 10 min; mute with its remaining time; forced rename; leaving and re-entering within 5 min does not refill chat bursts (`ChatPeerState` per character) and after 5 min it does |
| P8 | `test_client_config`: modes and priority, `--dtls-*`; `PlatformApi` with `request_hook` (refresh on 401; two calls expiring at once make a single refresh; error map); `AccountFlow` with `request_hook` (login, create if missing, enter → `ClientConfig` with a ticket); `--bot --platform` without `--login` → code 1; screens with fake data (name, deletion by typing the name, Entrar disabled without a character, template); `NetClient` puts the ticket in the HELLO |
| P9a | Export with all sections, also a tombstone's ledger, and GM operations without `note` or actor; the purge leaves tombstones; with a live lease it does not purge and `purge-now` answers `character_busy`; a restore at the limit and the hourly purge at once: one wins and the character ends up whole or purged; retention deletes what has expired and nothing else (also a report open for a year and the sanctions of an account purged more than a year ago); a backup taken before purging, restored and with `reapply-purges`, leaves the tombstone with the original `purged_at`; one taken before deleting a character and before a `purge-now` of its account leaves, after `reapply-purges`, all its characters as tombstones (also those that were never deleted), without restored leases or tickets, and `reapply-purges` exits with an error if an id in `purges.txt` remains unpurged; purging an account leaves its living characters as tombstones; purging a suspended account and registering the same email → the account is not created; a banned account exports and requests erasure with its privacy session, and is purged; after `purge-now`, no `audit_log` row has its email, and `restore_check.sh` fails if any does |
| P9b | `restore_check.sh` on a backup of the test database with `purges.txt`; `docker compose config -q`; the CI secrets check with a test `staging.env` in the index → fails |
| P9c | Loopback with DTLS and `GuardedEnetPeer` (server and client in one process, clean shutdown with no engine errors); `SwarmBot` with a certificate |
| P10 | Below |

The progress store's tests (S1–S8 with their cases, two saves with the same `uid`, ids outside the instance's blocks,
deferred swap, purge with a tombstone, one-year retention, a ledger `delete` without the flag, `Summaries`, `Export`,
operation and ledger) belong to progression.md §15 P7. DEBUG_COMMAND 40–43, the rule on one's own characters (id 40
without a role, own `item_give` without `admin`) and fencing with `item_give` belong to progression.md P5d.

**P10, end to end** (`go test -tags e2e ./e2e`):

- **Harness.** `ELDMARK_GODOT` (path to the Godot 4.7.2 executable; if missing, `t.Skip`). `TestMain` runs
  `godot --headless --path .. --import` once (with LFS already pulled). Platform in the test's process, ephemeral
  PostgreSQL (§2.6), `ELDMARK_HEARTBEAT_S=1`, `ELDMARK_LEASE_TTL_S=6`, the `1:test_world:0` token in
  `ELDMARK_ZONE_TOKENS` and `ELDMARK_ENTRY_ZONES=vardheim=test_world,solmarch=test_world` (a new character enters its
  realm's zone, and the tests only start `test_world`). progression.md P8 uses the same harness.
- **`TestEnterAndSave`:** `test_world` with `--platform`, a `--bot` with an account: enters, saves, leaves; `save_version
  > 0` and `character_progress.saved_at` set.
- **`TestZoneCrash`:** `--save-interval=5`; waits for a `saved_at`, notes the time and `kill -9` on the zone. Another
  instance is started (its registration gives 409 `instance_alive` and retries every 2 s until the old one has gone 3 s
  without a heartbeat; then it moves it to `lost` itself, §5.3) and **a second `--bot` process** with the same account
  enters it. It checks: `kill − saved_at < 5 s + 1 s margin` and that the character is in the new instance. The first
  bot does not need to reconnect.
- **CI:** "Plataforma e2e" job in `tests.yml`, which reuses the Godot and LFS cache from the Godot job and exports
  `ELDMARK_GODOT`.
- **Time** (measured in P10, §19.19): `TestEnterAndSave` 11–13 s and `TestZoneCrash` 25–27 s, within the goal of
  < 30 s per test; the 60 s cap is not needed. If a change exceeds it, P10's cap goes up to 60 s and is noted here and
  in the backlog entry.

**Visual review of UI-22 to UI-24 (user).** Against `deploy/dev.sh`: the title screen starts with the status and the
news; an account is created and logged into; two characters are created (realm, appearance, template and name, with a
name error in view); the selection's 3D view changes on choosing; one is deleted by typing the name and restored; the
world is entered with the chosen appearance and another client sees it the same; a REJECT returns to the selection with
its text.

## 16. Risks

| Risk | Mitigation |
|---|---|
| Zone and platform clocks out of step (10 s tickets) | `now_unix` in every response, 5 s margin and a warning from 2 s |
| Partition between zone and platform with the client reaching both: the character enters another zone | Fencing at 10 s (nobody new enters); at 15 s, `lost`; on return, the old one shuts down and its final saves are valid only for those nobody claimed; what was played there by someone who entered another is lost. Rare within one data center; reviewed with TEC-29 |
| `HTTPRequest` on the zone server: cost and signal order | Priority queues, the heartbeat's own slot, batches, results only in "poll"; `ServerMetrics` measures the `platform` section; `FakeHttpServer` tests it for real |
| A TLS failure logs an engine ERROR | No Godot test provokes it (§10.1); TLS is tested in Go |
| DTLS with `GuardedEnetPeer` and `SceneMultiplayer`, and its cost | Verified and measured in P9c (§19.18, networking.md §14); without DTLS there are no public tests (the platform enforces it). **Remaining risk:** each junk datagram from a new address is a failed handshake and an engine error in the log (below `GuardedEnetPeer`); it is bounded by journald's limit and, outside the process, the firewall (TEC-40). Each handshake costs 2 ms (EC P-256) or 4 ms (RSA 2048) of the zone's main thread |
| Go and PostgreSQL versions in CI (`ubuntu-latest`, unverified) | Pinned versions and `GOTOOLCHAIN=local` (§2.2); `ELDMARK_REQUIRE_PG=1` makes a missing PostgreSQL obvious |
| A single platform instance (single point of failure; limits and password failures in memory) | Fine for closed tests; those playing carry on if it goes down (§7.4); restarting the platform resets the counters. Several instances with TEC-38 |
| A compromised zone (Godot receives UDP from the Internet) | Scoped token, `public_host` from a list, sanction authorization on the platform, batches validated against the instance (§6), ids only from its blocks, S1–S8 in Go (progression.md §13.3). **Remaining risk:** S1–S8 bound the shape, the caps, the ids and the GM actor, not the quantities; they are a net against a zone with a bug, not against a compromised one, which can still mint gold, merits and XP with GAMEPLAY or with `source = console` on the characters it has inside. PRG-30 and PRG-39 detect it |
| Legal texts, age, retention (ledger, sanctioned emails) and export | Marked drafts; human review before any public test |
| `zone_server.gd` is touched by nine packages of the two documents (and before that abilities.md) | A fixed joint order, starting after abilities.md H3c (§14.1), and named tick steps (§14.3) |
| P10 may exceed 30 s | Measured in P10 (§19.19): about 12 s and 25 s; if it goes over, an explicit 60 s cap (§15) |

## 17. Interface with progression.md (reconciled)

What was agreed with progression.md after reconciling the two documents. Each rule is written once, in the owning
document; the other cites it. The same table is in progression.md §13.1.

| Topic | Agreed | Owner | Cited by |
|---|---|---|---|
| Save idempotency | Only `(lease_id, seq)`: same `seq` and same SHA-256 → `duplicate` (applied, with the `save_version` stored in `character_leases`); another body → `seq_conflict`; lower → `stale_seq`. `save_version` is a counter that plays no part; `saved_at` and `save_version` are written by `Apply` (S8) | platform.md §7.3 | progression.md §5.4, §13.3 |
| Save body | `save_format` 1 envelope with one key per section: `progress` (the record without the read-only fields, with `ops`) and `pvp`. No `zone_id`: the zone is that of `claimed_by` | platform.md §7.1, §7.3 | progression.md §9.3 |
| Journal in the save | Each body carries only the operations with `save_seq = 0`, which `build` marks with its `seq`; `acknowledge(seq)` removes those with `save_seq ≤ seq`. A final save built with another in flight repeats nothing | progression.md §9.2 | platform.md §7.1, §7.2 |
| Formats | `progress.progress_format` is the zone registration's `record_format` (`ZonePlatform.RECORD_FORMAT`, from platform.md P4; `ProgressRecord.FORMAT` has the same value and progression.md P5a tests it): compatibility is decided at registration (409 `schema_mismatch`); in a save, another format is 400 `invalid_save` | platform.md §7.1 | progression.md §3.4 |
| `CharacterSaver` sections | `register_section(section, build, acknowledge, is_dirty)` with `build(net_id, seq)`, `acknowledge(net_id, seq)` and `is_dirty(net_id)`; no `restore`. `track(net_id, character_id, lease_id, tick)` when creating the entity, before `on_arrival`; `mark_critical(net_id, reason)`, `on_platform_event`, `save_rejected`, `drop(net_id, code)`. `CharacterSaver` builds the whole envelope (`zone_instance_id` included); a `build` that returns `{}` postpones that save (the final one does not wait: alert and `release`). Entries by `lease_id`, and each response by the `lease_id` and the `seq` of its request: after `finish` or `drop`, no `acknowledge`, no `is_dirty`, no `save_rejected` | platform.md §7.2, §14.3 | progression.md §9.1, §9.2 |
| Critical events | Starting kit, level-up, capture and every GM command that changes something (`op_revert` included); from phase 6, trade, mail and rare loot. Renaming is not critical | progression.md §9.2 | platform.md §7.2 |
| When it is saved | Every 60 s with any dirty section, in phases; one write in flight; the final one in `finish`. Exit: `finish` → `ScoreKeeper.forget` → `ProgressService.on_departure`; on stopping, `release` of `LOADING`, `cancel` of `VERIFYING` and `finish` of everyone before `_clear_players()` | platform.md §7.2 | progression.md §9.2 |
| Drop without saving | A definitive response before `finish` or a `lease_lost` `revoked`: `CharacterSaver.drop(net_id, code)` (with `release` except on `lease_lost`), kick with the body removed at once (no combat logout), `ScoreKeeper.forget` and `ProgressService.on_departure`. Every `ProgressService` hook by `net_id` without a `PlayerProgress` does nothing | platform.md §7.2 | progression.md §9.2, §14.2 |
| Drop in `LOADING` | Without saving: `ZonePlatform.release(character_id, lease_id)` and `ProgressService.cancel_prepared(peer_id)`, also on a `revoked` | platform.md §5.2, §14.3 | progression.md §9.1, §14.2 |
| Save responses | One table and one error rule. Content or database error that is not transient (`*persistence.InvalidSaveError`, SQLSTATE class 22 or 23 or `P0001`, also at COMMIT): 400 `invalid_save` with `fields.check` and `fields.detail`. `40001` and `40P01` after retrying, no connection or timeout: 503. An envelope error: `invalid_save` with `check = "envelope"`. There is no `invalid_progress` or `progress.ErrFormat`. `instance_*`: shutdown with final saves. Any other 4xx is definitive, like `invalid_save`, also on release. `progress` is mandatory and `pvp` optional and never lowered | platform.md §6.1, §7.3 | progression.md §9.2, §13.3 |
| Without the platform | Nothing is saved: ephemeral characters; there is no `--progress-file` or progress repositories. `CharacterSaver` only exists with `--platform` and calls `ZonePlatform.save` | progression.md §0, §9.4 | platform.md §5.5, §7.5 |
| Claim | `{lease_id, instance_status, account, character, progress, pvp}`, only for a non-deleted character, with the account locked, without another character of the account in the world and with `Load` in its transaction; in the zone, `AuthOutcome.claimed: ClaimedCharacter` with `progress: Dictionary`. There is no `CharacterRecord` class | platform.md §5.3, §6, §14.3 | progression.md §3.4, §9.1 |
| Before WELCOME | Realm → capacity → `ProgressService.prepare(peer_id, claimed)` → WELCOME with the character's realm; if anything fails, REJECT (`REALM`, `FULL` or `UNAVAILABLE`) and `release`. WELCOME does not change its bytes | platform.md §5.2 | progression.md §9.1 |
| Record content | A single `ProgressRecord`, with race, appearance, `played_seconds`, `health` and `location`. Only in the claim: `race_id`, `appearance`, `starter_template_id` and `location.saved_at_unix` (`to_claim_dictionary` sets them). There is no `characters.state` or state JSON | progression.md §3.4 | platform.md §7.1 |
| Platform fake | `FakeZonePlatform` returns in the next claim the last applied value: `pvp` (platform.md P4) and `progress` without `ops`, with the read-only fields of the previous claim and `location.saved_at_unix` (progression.md P5a, with `claim_progress`). Its test API (`add_character`, `script_next`, `set_fenced`, `next_block_first`, `applied`, `sent`) is a single one, from platform.md P4 | platform.md §14.1, §14.3 | progression.md §14.1 |
| Returning to the world | RvR zones (all in phase 5): the realm's camp. SAFE zones (phase 6): the saved spot if it is the same instance, less than 15 min ago, out of combat and alive. Health regenerated with the elapsed time | progression.md §8 | platform.md §0, §7.1 |
| Who stores what | One table with all the fields and their owner; `characters` is identity only (it gains no `level` or `state`) | progression.md §3.1 | platform.md §3 |
| Progress tables | `0010_progress` DDL only in progression.md, without `world_id`; the append-only ones, with a foreign key without cascade to `characters` through `op_participants`; trigger on all five; `actor_account_id` on GM and REVERSAL | progression.md §3.3 | platform.md §3 |
| Migrations | In phase 5, 0001–0006 of the platform and 0010_progress (progression.md P7, with `.down.sql` and seed); afterwards, the next free number, whoever owns it. The runner applies in order and refuses one pending below the highest applied. There is no P3b | platform.md §2.4 | progression.md §3.3 |
| Id blocks | `POST /internal/v1/id-blocks {zone_instance_id}` → `{first, count: 1024}`, in `starting` and `live`; `uid_block_seq` and `id_blocks` in 0003_zones; the first block, at startup; `Apply` rejects ids outside `claimed_by`'s blocks | platform.md §3, §6, §8 | progression.md §4.5, §13.3 |
| Purge and retention | The tombstone is the `characters` row. The purge locks the lease and the character row, and does not purge with a live lease; with the account and in `reapply-purges` (which runs before `serve` and deletes the restored leases) `purged_at` null suffices; `ProgressStore.Purge` deletes the progress state; `PurgeRetention` empties the ledger after a year and returns the empty tombstones, which the platform deletes; `reapply-purges` keeps the `purged_at` | platform.md §11.1, §11.2 | progression.md §3.5 |
| Export | `ProgressStore.Export` of each unpurged character and of each tombstone of the account with a ledger (without a record), under `characters[i].progress`; of GM and REVERSAL operations, without actor, `note` or `detail`. A tombstone's ledger is pseudonymous only after the account is purged | platform.md §11.2 | progression.md §3.5 |
| `ProgressStore` in Go | `Create`, `Load`, `Apply`, `Summaries`, `Purge`, `PurgeRetention` (with the empty tombstones), `Export`, `Op` (with the instance) and `Ledger`, with raw JSON at the boundary; its errors (`InvalidSaveError`, `ErrNotFound`) and creation validation (`CreateValidator`, `*ValidationError`) in `internal/persistence`, from platform.md P2, which `*progress.Rules` implements. The platform does not read progress columns | progression.md §13.2 | platform.md §7.5 |
| Operation and ledger | `?zone_instance_id=` routes of the platform's internal router (its §6.1 checks), only with a lease on the instance (the character's, which the router checks; or that of some participant, which `Op` checks in its own query); otherwise, 404. Bodies from progression.md; `limit` from 1 to 100 | platform.md §6 | progression.md §13.2 |
| Ids in JSON | Decimal string for every `bigint` id, also in the claim and in the save (`jsonx.ID`, up to 2^63 − 1; progress ones, up to 2^53 − 1 by S1); number for quantities, balances, level, `seq`, codes and dates. Realms: text id in the public API and code in the internal one | platform.md §4.1 | progression.md §0, §3.4 |
| Save checks | S1–S8 of progression.md; lease and `seq` are steps 2 and 3 of the save, with no S number. S2 admits from zones types 1–5 with their reasons, rejects an already saved `op_id` and checks the GM and REVERSAL actor with the role they had at `detail.at_unix` (the CLI's `set-role` row, platform.md §9.1). S7 admits past dates | progression.md §13.3 | platform.md §6.1, §7.3 |
| Level | Only `character_progress.level`; the character list reads it with `Summaries` | progression.md §3.1 | platform.md §4.4 |
| Race and appearance | `race_vardheim`, `race_solmarch` and `race_askarra`; 8 B in `character_progress`, with byte 0 of `race_id`; validated by the platform on creation (`ValidateCreate` or the provisional one) and by the zone on load (`default_for`), with the same exported rules (pieces with their `bodies`, `allows_no_hair`, `allows_no_beard`) and the same cases (`appearance_cases.json`); the realm, in the `NetProtocol.Realm` code in `validate`, `ValidateCreate`, the rules and the cases | progression.md §7.2 | platform.md §4.4 |
| Starting template | Chosen on creation (`starter_template_id`, UI-24) among the `selectable` ones; it is the first entry's kit; with the platform, LOADOUT_SELECT changes nothing | progression.md §2.5 | platform.md §4.4, §13.2 |
| Exported rules | One file (`platform/internal/gamedata/progression_rules.json`), one tool (`tools/progression/export_rules.gd`) and one test (`test_progression_rules_export.gd`); `protocol_version` and `names` belong to platform.md. Test data shared with Go, under `tests/fixtures/` | progression.md §13.4 | platform.md §4.4 |
| Protocol | `PROTOCOL_VERSION = 7` for all of phase 5, with `AUTH_TIMEOUT_SECONDS = 10.0`; fixed split (5 chat and groups, 6 abilities.md); bumped by platform.md P4, after abilities.md, with the full line in `net_protocol.gd`; progression.md P4 adds its part without bumping it. In networking.md each P4 writes the rows and the "v7" mark for what its code adds | platform.md §5.4 | progression.md §12 |
| CMB-30 | Belongs to progression.md; the platform stores the `progress` section | progression.md §8 | platform.md §7.1 |
| Ticket and handoffs | 52 B, identity only; CMB-30's data arrives with the final save and the claim at the destination (phase 6) | platform.md §5.1 | progression.md §8 |
| DEBUG_COMMAND with the platform | Each command's `min_role`; 40–43 and 5, 13 and 16 declare `admin` | progression.md §10 | platform.md §9.1 |
| Environment guard | The registration's `env` decides: with `staging` or `production`, development options make the zone exit | platform.md §5.5 | progression.md §10 |
| On one's own characters | Every command that changes something (`op_revert` included) requires `admin`, with no exception per environment; S2 repeats it in GM and REVERSAL operations | progression.md §10 | platform.md §9.1 |
| GM queries | `inv_show`, `ledger_show` and `op_show` require `gm` and are audited | progression.md §10 | platform.md §9.1 |
| Audit | A command that creates an operation (a GM one, or the REVERSAL of `op_revert`) goes with `key = "op:<op_id>"` in the batch and in S8, with `on conflict do nothing` and the same fields: `actor_account_id`, `source` (`zone` or `console`), `args` with the target by id and `at` = `detail.at_unix`; `world_id` and `zone_id`, from the instance. Each batch entry is validated separately and against the instance that sends it: no other instance, no `cli` or `platform` rows, no `op_id` from other blocks (platform.md §6). No `audit_log` row carries emails or names in `args` | platform.md §9.1 | progression.md §10, §13.3 |
| Invisible GM | No merits, no XP, no gold, no capture reward | platform.md §9.1 | progression.md §6.2 |
| Fenced zone | Commands that change something are rejected without creating the operation; the game's critical saves are marked and go out later | platform.md §5.3 | progression.md §10 |
| Fake players | Options and guard, platform.md; with the platform and fakes, no persistent reward | progression.md §6.2 | platform.md §5.5 |
| Fort and GM commands | With the platform, what a fort command causes (`fort_owner`, `fort_reset`, `fort_kill_captain`, a capture with `fort_capture_speed`) pays nothing persistent and adds nothing to `ScoreKeeper`; `/gm teleport`, `/gm visible` and DEBUG_COMMAND 1, 2 and 4 flag the character (`gm_forced`) until it respawns: no captures, no merits, no NPCs | progression.md §6.2 | platform.md §8, §9.1 |
| Events in the zone | `take_events()` is distributed by `kind`, with one consumer each: `claim` (`auth_provider`), `save` (`saver`), `heartbeat` (the zone), `id_block`, `progress_op` and `progress_ledger` (`progress`), `fortress`, `ignore`, `report`, `sanction` and `instance_closed` (`ServerMain`); then `take_completed` and `prepare` | platform.md §14.3 | progression.md §14.2 |
| Zone requests | `ZonePlatform.request` sets `zone_instance_id` (the save carries it in `CharacterSaver`'s envelope, and `save(character_id, lease_id, body, release_lease, context)` sends the bytes untouched); `enqueue_batch`, the missing `key`; no body carries `world_id` (the platform sets it from the instance); `body` read with `JSON.new().parse` (never `parse_string`) | platform.md §14.3 | progression.md §13.2 |
| Captures | One list from `FortressController` (capturer, present, alive, connected, without invisible or `gm_forced`-flagged ones) for `ScoreKeeper.captures` and `ProgressService.on_capture`; a forced capture goes to neither | platform.md §8 | progression.md §6.2 |
| u32 fingerprint | `HandoffTicket.zone_key_of` for the ticket's `zone_key` and the NPC and fortress `ref_id`s | platform.md §5.1 | progression.md §5.2 |
| Clock and size | `ZonePlatform.now_unix()` for timers; body of 1 MB at most on the internal API | platform.md §6 | progression.md §8, §17 |
| Packages | The progress store is progression.md P7, with the dependencies in its §14.1; the `ProgressStore` interface, `CreateValidator` and their errors, platform.md P2; both documents wait for abilities.md; progression.md P5c, for platform.md P6 (capture list); one joint order for `zone_server.gd` | platform.md §14.1 | progression.md §14.1 |
| Tests | The store's, in progression.md P7; DEBUG_COMMAND 40–43, the rule on one's own characters and fencing with `item_give`, in progression.md P5d (platform.md P7b tests `min_role` with network and moderation commands); the end-to-end ones, with the platform.md P10 harness | progression.md §15 | platform.md §15 |
| Client | UI-23, UI-24 and the bot use `CharacterAppearance` and `AppearanceApplier` | platform.md §13.2, §13.3 | progression.md §7.2, §7.4 |

## 18. Review

Three reviewers (security, consistency and implementability) presented 45 findings on version 0f6781b. Checked against
the code and the documents, all hold up; the review probes are in `build/probe_rev/` (Godot: `auth_timeout` with
`GuardedEnetPeer` and JSON; Go: `jsonx`; PostgreSQL: the whole schema, the tombstone, the trigger, the claim and the
heartbeat; git: the `.gitignore`). The rows are the history of the review; what changed afterwards, when reconciling
with progression.md, is in the last four rows and in §17.

| Id | Severity | What it was | What was done |
|---|---|---|---|
| PL-SEG1 | blocking | Two incompatible idempotency contracts (`(lease_id, seq)` here, `save_id` + `base_version` there); `duplicate`, 400 and retries undefined; two sources of ids | One contract (§7.3): immutable body retried byte for byte, `duplicate` = applied, `stale_seq`, `seq_conflict` with a hash, definitive `invalid_save` with `release`; blocks from the 1024 sequence with `first` as a string (§6); test in P3. progression.md, §17 |
| PL-SEG2 | important | With the platform, `--debug-commands`, `--fake-players` and no DTLS could be used; DEBUG_COMMAND without a role; valid test key | `env` in the registration and the zone exits outside `dev`/`test` (§5.5); DEBUG_COMMAND with `min_role` (§9.1); registration without a certificate → 400 in staging and production (§6); keys of < 32 B and the vector's rejected (§2.3); tests in P0 and P4 |
| PL-SEG3 | important | One shared token opened the whole internal API; registration of any zone and host; the replaced one "without saving" contradicted §5.3 | Per-deployment token with scope and hashes, `ELDMARK_ZONE_HOSTS`, checked `zone_instance_id`, `claimed_by`, `replace` with audit, final saves of the replaced one (§5.3, §6, §6.1); tests in P3 |
| PL-SEG4 | important | Undefined what happens with a `lost` instance that comes back; heartbeat without filtering by `lease_id`; heartbeat in the shared queue | Heartbeat with `(character_id, lease_id)` and SQL (§5.3, verified), `instance_lost` and shutdown (§6.1), fencing at 10 s, the heartbeat's own slot (§6). Nuance: fencing rejects operations that require a critical save, not saves, which keep going out |
| PL-SEG5 | important | Refresh rotation with `family` kicked on the first refresh; 12 h not fixed; the claim's SQL did not check the session | One row per session rotated in place with `prev_refresh_hash`, absolute 12 h, one refresh at a time in `PlatformApi`, claim with a `join` to `sessions` and rollback without a lease (§3, §4.2, §5.3; verified); tests in P1, P3 and P8 |
| PL-SEG6 | important | The platform created the sanction without checking the role or the zone; lowering a role did not remove the power | Bodies with `zone_instance_id` and `world_id`; three-step authorization and `sanction_denied` (§9.5); `set-role` revokes the sessions (§9.1); tests in P7a |
| PL-SEG7 | important | Password routes without a limit; changes that did not invalidate links; notice to the old email with no way back; export with the token only | Shared `CheckPassword`, invalidation in the transaction (except `revert_email`), 7-day `revert_email`, export with a password (§4.2, §4.3); tests in P1. In the implementation review (§19.7): spending a `revert_email` voids those issued after it, its email stays reserved while it lives and an account's password attempts go one at a time |
| PL-SEG8 | important | `email_taken` and `account_locked` revealed accounts; the per-account lockout was a weapon; sanctions before the password; unverified accounts forever | Registration and email change always 202; failures per account and IP group with throttling on the others and 429; states only after a good password; notice email; purge after 7 days unverified (§4.1–§4.3, §11.1); tests in P1 |
| PL-SEG9 | important | Backups, WAL and logs kept purged data with no deadline | `purge_log`, `purges.txt` and `reapply-purges` (§11.2, §12); backup, WAL and log rows in §11.1; journald at 30 days; Caddy without an access log; no `--battle-log` and similar in staging and production; test in P9a |
| PL-SEG10 | important | `.gitignore` only ignored `.env` (verified) | New patterns in P0 (verified in a test repository), secrets from `secrets/` and a check in CI (§10.3); test in P9b |
| PL-SEG11 | important | Invisible GM that hit and captured; commands on one's own characters; CLI without identity; unaudited reads | Invisible without damage, circle, scoreboard or rewards; rule on one's own characters; mandatory `--actor`; audited reads (§9.1); tests in P7a and P7b. progression.md, §17 |
| PL-SEG12 | important | Reserving names without limit by creating and deleting | 5 creations and 5 deletions per account and day, characters deleted within the grace period take up a slot and test characters do not reserve 30 more days (§4.2, §4.4); tests in P2 |
| PL-SEG13 | minor | `X-Forwarded-For` without a clear rule | Only `X-Real-IP` from `ELDMARK_TRUSTED_PROXIES`, set by Caddy (§4.2, §10.1); test in P1 |
| PL-SEG14 | minor | Email with CR/LF (header injection) and pages with the token unescaped and without headers | Strict validation and `mime.QEncoding` (§4.2); `html/template`, validated token and four headers (§4.3); tests in P1 |
| PL-SEG15 | minor | Erasure deleted the history of repeat offenders | `sanctioned_email_hashes` with HMAC and its own key, consulted at registration, with legal review (§2.3, §3, §11.1, §11.2); test in P9a |
| PL-COH1 | blocking | Two load-and-save pipelines, and two `class_name CharacterRecord` | One pipeline: the claim brings the record, `CharacterSaver` with sections over `ProgressRepository`, `ClaimedCharacter` here, one error table (§6.1, §7.3, §7.5); `PlatformProgressRepository` moves to P5. progression.md, §17 |
| PL-COH2 | blocking | The same data in two schemas; two sources of `uid`; nobody wrote the progress migrations | "Who stores what" table (§3); `characters` is identity only, with no state JSON; a single source of ids (§6); P3b with 0010_progress (DDL verified), S3–S9 and the operation and ledger routes (§14.1). progression.md, §17 |
| PL-COH3 | blocking | Cascading purge collided with the ledger trigger (verified by the reviewer) | Tombstone without cascade in the append-only tables, trigger with `set local eldmark.retention_purge`, 1-year retention and `progress_purge_character` (§3, §11.1, §11.2; verified); test in P3b. progression.md, §17 |
| PL-COH4 | important | CMB-30 assigned to abilities.md, which leaves it out | Removed `state.combat` and the boundary with abilities.md; CMB-30 belongs to progression.md §8 (introduction, §7.1, §16) |
| PL-COH5 | important | Two rules for returning to the world and two last-zone fields | The one from progression.md §8, cited in §7.1 and marked provisional (§0); `enter` reads `character_progress.last_zone_id` (§4.5) |
| PL-COH6 | important | Incompatible creation: race id, two generators, no template, `Create` without data | `race_<realm>` ids, a single file and one tool, `starter_template_id` in the route and in UI-24, `CreateParams`, 8 B appearance (§4.4, §7.5, §13.2). progression.md, §17 |
| PL-COH7 | important | Refresh rotation against the lease tied to the session | Same as PL-SEG5 (the session does not change row); test in P3 |
| PL-COH8 | important | `VERIFYING` outside the capacity; claims behind saves; `auth_timeout` counted from the connection | `VERIFYING` counts and `FULL` is checked at the 200; slots for entry; 10 s `auth_timeout` and 7 s real-time deadline (§5.2, §6; verified); tests in P4 |
| PL-COH9 | important | Startup without the platform that overwrote the owner; registration before the port; realms not saved | Fixed order with `starting` and `live`, GET with retries that distinguishes empty from silent, `expected_version`, `realms` in registration (§3, §6, §8); test in P6 |
| PL-COH10 | important | Synchronous `flush_and_wait` impossible; today's shutdown does not wait; incomplete triggers | `begin_flush` and `is_flushed`, `_drain_stop` up to 600 ticks and `SHUTDOWN_MAX_FRAMES` 720, the five triggers (§7.2, §14.3); test in P5 |
| PL-COH11 | important | Nobody did the bot's login with an account | `AccountFlow` without an interface, used by `FrontMain` and the bot; `--bot --platform` without `--login` exits with code 1 (§5.5, §13.3, §14.4); tests in P8 |
| PL-COH12 | important | Criteria and rules in other documents untouched | backlog: TEC-24 (character's realm), TEC-27 (provisional criterion), SOC-16 (server-side filter) and "pendiente del usuario"; networking.md §12 and §17 (52 B ticket, `PENDING`); social.md §0, §8 and §10. progression.md, §17 |
| PL-COH13 | minor | Version 5 already belonged to chat (and 6 to abilities.md); two bumps in phase 5 | A single shared bump, the next free one (today 7) (§5.4); `ELDMARK_MIN_PROTOCOL` mandatory in staging and production (§2.3). progression.md, §17 |
| PL-COH14 | minor | 63-bit `ticket_id` as a JSON number | Every `bigint` id as a string in both APIs (§4.1; verified in Godot); round-trip test in P4. progression.md, §17 |
| PL-COH15 | minor | `ScoreKeeper` had no captures or defending time; order against `forget` | `captures` and `defend_ticks` with who and when, `pvp` section, `finish` before `forget` (§8); tests in P6 |
| PL-IMP1 | blocking | The same stretch of the zone defined twice (class, load, save, CMB-30) | Same as PL-COH1 and PL-COH4: boundary of §7.5 and §17 |
| PL-IMP2 | blocking | Go contract and schema that did not match; migrations without an owner; impossible purge | Same as PL-SEG1, PL-COH2, PL-COH3, PL-COH6 and PL-COH14: `CreateParams`, `Apply` with progression.md types, one source of ids, strings, one generator, tombstone and P3b (§3, §7.5, §14.1) |
| PL-IMP3 | important | Godot rewrites `820.0` and Go rejects it in an `int` (verified) | `jsonx.Int` and `jsonx.ID` in Go; `int()` and `to_int()` when reading in GDScript; the fake does a JSON round trip (§4.1, §14.3); tests in P0, P3 and P5. progression.md, §17 |
| PL-IMP4 | important | The 240-tick deadline did not fit in the `auth_timeout` counted from the connection | Verified with `GuardedEnetPeer`: 10 s on both sides and a 7 s real-time deadline (§5.2, §5.4); test with HELLO at 1.4 s in P4 |
| PL-IMP5 | important | `PlatformClient` queue without priorities or rules; fortress PUT without a version; silent startup; no test of the real HTTP | Table of priorities and retries (§6), one in flight per fortress with `expected_version` and the startup of §8; `FakeHttpServer` in P4 |
| PL-IMP6 | important | Same as PL-SEG5 and PL-COH7 | Same as PL-SEG5 |
| PL-IMP7 | important | Incomplete instance state machine | Fixed order of checks and a table by state and request (§6.1); a returning `lost` one is closed; tests in P3 |
| PL-IMP8 | important | `AuthProvider` without an entry point for the claim; capacity; fake without inheritance; how `ZonePlatform` arrives; class in another package | `on_platform_event`, `get_player_count` with `VERIFYING`, `FakeZonePlatform extends ZonePlatform`, `ZoneServer.start(…, platform)`, `ClaimedCharacter` in P4 (§14.1, §14.3) |
| PL-IMP9 | important | Tests that did not demonstrate their criterion | Duplicates in P3b with real tables; `saved_at` to measure the loss; "ANEIRA" and "Aneira"; reconnection with `pvp` in P5 and expiry of each sanction in P7a (§15). progression.md, §17 |
| PL-IMP10 | important | `TestZoneCrash` could not be run | Harness with `ELDMARK_GODOT` and import in `TestMain`, CI job, second `--bot` process, `saved_at` against the `kill` time, explicit time cap if it exceeds 30 s (§15) |
| PL-IMP11 | important | TEC-27 could not be measured; `NetTransport` without a DTLS contract; criterion changed without marking it | `host` and `connect_to` with `TLSOptions`, `--dtls-*` in `--connect`, `--bot` and `--bots` (§10.2, §13.3); provisional criterion with a question to the user in §0 and in the backlog; P9c |
| PL-IMP12 | important | Rollback with `down` that deleted data | `down` only in development and CI, irreversible ones marked, expand and contract, preservation test (§2.4, §12) |
| PL-IMP13 | important | Missing dependencies and packages that were too big | `ClaimedCharacter` in P4; P6 and P7b depend on P5; P7 into P7a and P7b; P9 into P9a, P9b and P9c (P9c without TEC-20); new P3b (§14.1) |
| PL-IMP14 | minor | The email forms could not use `/v1` | `GET` and urlencoded `POST` on `/verify`, `/reset` and `/revert`, outside `/v1` and without the 426 (§4.1, §4.3); test in P1 |
| PL-IMP15 | minor | User-pending items were missing | SMTP and DNS, visual review of UI-22 to UI-24 with a checklist and the TEC-27 criterion in §0 and in the backlog; checklist in §15 |
| Reconciliation | blocking | After the reviews, this document (§17) and progression.md (§13.1) still had two lists of requests that did not match: idempotency and `save_version`, save body, section API, `CharacterRecord`, repositories and `--progress-file`, progress tables and migrations, id blocks, tombstone, id format, starting template, exported rules, roles and audit | Reconciled interface (§17): one rule per topic, in the owning document, and the citation in the other. Here: the 0010 DDL and P3b move to progression.md (§3.3, P7); `save_version` stays as a counter (§7.3); the body carries the `progress` section (§7.1, §7.3); `CharacterSaver` without repositories or `restore` (§7.5, §14.3); the claim brings `character` and `progress` and `prepare` runs before WELCOME (§5.2, §6); `id_blocks` in 0003 and the first block at startup (§3, §8); the tombstone is only the `characters` row, with `ProgressStore.Purge` and `PurgeRetention` (§11); S1–S8; `Summaries` and `ValidateCreate` (§4.4, §4.5); own characters with no environment exception and queries for `gm` (§9.1); `op:<op_id>` audit (§9.1); protocol 7 (§5.4); joint package order (§14.1) |
| Reconciliation review | blocking | Reviewers on the two already reconciled documents (43 findings, several repeated; all hold up): 63-bit `ticket_id` against the 2^53 `jsonx.ID`; the final save repeated the in-flight save's operations; progress errors in a package that arrived late and with a cycle; final-save responses by a reusable `net_id`; drop in `LOADING` without releasing; realms in JSON with two rules; heartbeat with the `lease_id` of `VERIFYING`; per-batch audit without a fixed actor or `source`; operation and ledger routes without a lease; unclassified database errors; purge without a lock order; retention without a mechanism; retained ledger not exported; migration number ranges; P7b pieces and tests that belonged to progression.md P5d | `jsonx.ID` up to 2^63 − 1 and realms per API (§4.1); drop in `LOADING` and claim with a non-deleted character and `Load` in its transaction (§5.2, §5.3); heartbeat and `revoked` with `lease_id` (§5.3, §6); batches with per-entry rejection and S8's fields (§6, §9.1, §9.2); operation and ledger with a lease (§6, §6.1); `CharacterSaver` entries by `character_id` after `finish` and `track` before `on_arrival` (§7.2, §14.3); save error rule and `last_save_version` (§3, §7.3); errors in `internal/persistence` (§7.5); purge with locks, tombstones in the export, reports and sanctions with a deadline, `reapply-purges` with the original `purged_at` (§11); migrations with the next free number (§2.4); P4 bumps the protocol and P7b without P5d's part (§5.4, §14.1, §15); `body` without `parse_string`, `instance_id()`, `world_id()` and `key` in `enqueue_batch` (§14.3); cases under `tests/fixtures/` (§4.4); social.md §8, networking.md §15, abilities.md §4.6 and backlog. §17 table brought up to date |
| Second reconciliation review | blocking | 30 findings on the two documents (several repeated; all hold up, and in four the solution differs in part from the proposal). Here: P4 bumped to 7 without waiting for 6; phase 5 promises in social.md and networking.md without a package; the kick after a definitive response left the body 15 s and sent a final save after `drop`; who sets `zone_instance_id` in the save; the heartbeat without a defined set; entries by `character_id` that collided when returning to the same instance; unclassified 4xx responses; `ValidateCreate` without a seam; events without `kind` or consumer; the operation route without participants; absent sections and a `pvp` that goes down; dependencies between documents; `^` and `ceil` in GDScript; several characters of one account in the world; fort commands that paid the GM; sanctioned accounts that could not export; emails and names in the audit; fortresses of another zone; audit time; chat scope | P4 after abilities.md and a fixed split (§5.4, §14.1); `ChatPeerState` per character and no `REJECT NAME` with a ticket (§5.4, §9.2); drop without saving with the body removed at once and `drop(net_id, code)` (§7.2, §14.3); the envelope is built by `CharacterSaver` (§6, §7.3); heartbeat set in `ZonePlatform` and `save` with `lease_id` and `release_lease` (§5.3, §14.3); entries by `lease_id` (§7.2); strict envelope (`envelope`), any other 4xx definitive and the DESTROY cap (§7.3); `CreateValidator` (§4.4, §7.5); `PlatformEvent.kind` with one consumer each, `instance_closed` and the maintenance countdown (§7.2, §14.3); `Op` with the instance (§6); `progress` mandatory and `pvp` with `greatest` (§7.3); `RECORD_FORMAT` (§7.1); `ceili` (§8); one character in the world per account (§4.5, §5.3); privacy session (§4.2); audit without personal data and with `at_unix` (§9.1); `zone_channel` (§3, §9.2); fortresses per zone (§6); P5 tests moved to P6 and progression.md P5b (§15). progression.md, §13.1 |
| Third reconciliation review | blocking | 25 findings on the two documents, 23 distinct: 22 are fixed (three in part or differently) and one is not about the text. Here: startup responses without the `id_block` event; networking.md's "v7" marks, claimed by both P4s; the `set-role` row without `command` or `source`; `FakeZonePlatform` without a test API; `CheckPassword` without the email (account oracle); P10 harness without an entry zone and registration over a `live` instance without a heartbeat; who composes the `BANNED` text; batches not tied to the instance; deleting without a lock against the claim; account purge and `reapply-purges` that skipped non-deleted characters; the shutdown of §6.1, which kicked before sending final saves with the leases already free; the zone's `world_id` in reports, ignores and sanctions; the remaining risk with a compromised zone; a living character's ledger without a retention row; `/gm teleport` and `/gm visible` that paid; a save without ids | Startup responses and `FakeZonePlatform` API (§14.3); each P4 writes its part in networking.md (§5.4); fixed `set-role` row and the CLI's `source` and `command` (§9.1), with an index in 0005 (§3); `CheckPassword` with the email (§4.2, §14.2); registration moves an instance without a heartbeat to `lost`, lost-instances job at `min(5 s, HEARTBEAT_S)` and harness with `test_world` (§2.5, §5.3, §15); `account_blocked` body (§6.1; **differently**: the text is composed by the platform, like `revoked`'s `text`, not the zone); batches validated against the instance and the instance's world, without `world_id()` (§6, §14.3); delete and restore lock the account (§4.4); the purge checks what applies depending on the path and `reapply-purges` runs before `serve` and without leases (§11.2); the shutdown of §6.1 kicks after the final saves and `replace` no longer frees the old one's leases (§5.3, §6.1; **in part**: everyone is kicked at once after `begin_flush`, not each one after their final save); remaining risk (§16); retention of a living character's ledger (§11.1, social.md §8); a section that returns `{}` (§7.2; **in part**: the final save does not wait for the next block, because its state no longer exists; the reservation in progression.md §4.5 prevents it); `gm_forced` (§8, §9.1); backlog TEC-25. **Not about the text:** social.md 12.7, `ChatPeerState`, `KNOWN_RECIPIENT_TICKS` and "5 is already in main" exist on the main line (protocol 5), which this work trails behind; they match when rebased onto it |
The interface with progression.md was reconciled after the three reviews: §17 says what was agreed and in which
document each rule lives. What the rows above name and no longer exists (P3b, S3–S9, `progress_purge_character`,
`ProgressRepository`, `PlatformProgressRepository`, the `world_id` in the bodies of reports, ignores and sanctions and
`ZonePlatform.world_id()`) predates the reconciliation or its last review.

## 19. Implementation

What each package did, where it departs from this document and what was measured. Each package adds its section when
it finishes.

### 19.1 P0 · skeleton (TEC-22)

**What exists.** The `platform/` module (`eldmark/platform`, `go 1.24.0`, `toolchain go1.24.7`) with `.gdignore`:

| Piece | Content |
|---|---|
| `cmd/eldmark-platform` | `serve`, `migrate up`, `migrate down N`, `migrate status` and `help`; exit 0 ok, 1 error, 2 usage. `status` exits with 1 if any of the binary's migrations is missing. `down` refuses in `staging` and `production` (§2.4, §12) |
| `internal/config` | The whole table of §2.3, with `<NAME>_FILE` on the five secrets. `Load` (serve) and `LoadDatabase` (migrate: only `ELDMARK_ENV` and the database). Problems all come out at once, one per line, without repeating any secret; `Config` is logged with `LogValue`, also without secrets. `Realm` (`NetProtocol.Realm` codes and text ids) and `ZoneToken` (scope and SHA-256) |
| `internal/logx` | `slog` with `JSONHandler`, `MaskEmail` (`a***@example.org`), request id and `SetAccount`/`SetCharacter` for the `account` and `character` fields |
| `internal/db` | `Open` (does not connect yet; `application_name` and `timezone = UTC`), `Ping`, `Classify` with the rule of §7.3 (`KindIntegrity`: class 23 and `P0001`; `KindRetryable`: `40001` and `40P01`; `KindUnavailable`: no connection, `57014`, `57P01`–`57P03`, class 08, `53300`), `SQLState`, `Constraint` and `InTx`, which repeats the whole transaction on `40001`/`40P01` (also at COMMIT) and, when exhausted, returns `ErrConflict` |
| `internal/jsonx` | `Int`, `ID`, `ParseID`, `Decode` and `DecodeBytes` of §4.1. `Int` parses the number without going through `float64` and admits up to ±(2^53 − 1); `ID` requires a string of digits with no sign or leading zeros, from 0 to 2^63 − 1 |
| `internal/httpx` | The error body of §4.1 (`Error`, with `Extra` for the `account_blocked` of §6.1), `Retry-After` on 429 and 503, `DecodeJSON` with the 16 KB and 1 MB limits (413 and 400 `bad_request`), the log of each request (`req`, `route` with the pattern and never the real path or the query, `status`, `ms`; never the body), panic → 500 `internal`, `Health` and `Ready` |
| `internal/app` | The `serve` process: the two APIs, `/health` and `/ready` on both, `HandlePublic` and `HandleInternal` for the following packages, the schema wait and the startup grace period of §2.5 |
| `internal/migrate` | The runner of §2.4 and `migrations/0001`–`0006` (the DDL of §3 as is); `testdata/seed_0001`–`seed_0006.sql` |
| `internal/testdb` | The harness of §2.6: `Main`, `New`, `NewEmpty`, `ConnString`, `DumpSchema`, `Exec` and `Tables` |

Outside `platform/`: `.gitignore` with the patterns of §10.3 (verified with `git check-ignore --no-index`: it ignores
`platform/deploy/staging.env`, `secrets/ticket_keys`, `zone.key` and a `*.pem` outside `tests/`; it leaves
`staging.env.example` and `tests/fixtures/**/*.pem`); `platform/*` in the `exclude_filter` of both targets in
`export_presets.cfg` and in `test_export_config.gd` (plus a test that `platform/` carries `.gdignore`);
`tools/check_secrets.sh` and the "Plataforma" job of `.github/workflows/tests.yml` (below); and a "Servicio de
plataforma (Go)" (platform service) section in the README with the commands.

**For the following packages.** New routes are added with `App.HandlePublic("POST /v1/sessions", h)` and
`App.HandleInternal(…)`; a body is read with `httpx.DecodeJSON(w, r, httpx.PublicBodyLimit, &body)` and an error is
written with `httpx.WriteError`. Tests with a database carry `func TestMain(m *testing.M) {
os.Exit(testdb.Main(m)) }` and `pool := testdb.New(t)`. A new migration goes in `internal/migrate/migrations/` with
its `.down.sql` and, if it creates tables, its `testdata/seed_NNNN.sql` (progression.md P7's is `seed_0010.sql`): the
preservation test picks it up by itself and fails if any table is left without rows.

**Deviations and implementation decisions:**

- **`internal/app`**, which §2.1 does not name: it mounts `serve` so that `httpx` stays generic and so it can be
  tested with `:0` ports.
- **`serve` with pending migrations** (§2.4: "does not start and `/ready` says why"): the process stays alive,
  `/health` gives 200, `/ready` gives 503 with the reason and startup waits, checking the schema every 2 s; once the
  schema is up to date it does the grace period and becomes ready without restarting. `/ready` also requires startup
  to be done ("La plataforma está arrancando", i.e. the platform is starting). Each new reason is logged once, not on
  every loop.
- **The grace period of §2.5 is already in P0** (its tables exist since 0003); the periodic jobs (lost instances,
  retention, purges) arrive with P3 and P9a.
- **`/ready` is public** (Caddy passes everything to :24680), so its reason carries no database details ("La base de
  datos no responde", i.e. the database does not respond; the migration one only names repository files). The detail
  goes to the log. Probes that go well are logged at `DEBUG` and those that do not, at `WARN`.
- **Mandatory in `serve`** in all environments: `ELDMARK_DATABASE_URL`, `ELDMARK_ZONE_TOKENS` and
  `ELDMARK_TICKET_KEYS` (those with "—" in §2.3); in `staging` and `production`, in addition,
  `ELDMARK_MIN_PROTOCOL`, `ELDMARK_EMAIL_HMAC_KEY` and SMTP. Details that §2.3 did not fix: keys (ticket and HMAC) in
  standard base64 of at least 32 B; the fixed test HMAC key, like the vector one, is not admitted outside `dev` and
  `test`; `LEASE_TTL_S` greater than `HEARTBEAT_S`; each open realm with an entry zone; a token with two scopes is an
  error; `ELDMARK_X` and `ELDMARK_X_FILE` at once, too; an empty variable counts as absent.
- **`ELDMARK_MIN_PROTOCOL` in `dev` and `test`:** without the variable, `MinProtocol = 0` and
  `Config.ResolveMinProtocol(protocol_version)` gives the rules' one, because `progression_rules.json` does not exist
  yet (P2 or progression.md P3 creates it). Whoever mounts the 426 resolves it at startup.
- **migrate:** the SHA-256 checksum is that of the `.up.sql` (fixing a `.down.sql` breaks nothing). `Down` checks all
  those it will undo (that they are in the binary, with their checksum and not irreversible) before touching anything.
  `Load` requires complete pairs, names `NNNN_[a-z0-9_]+` from 0001 and the `raise exception 'irreversible'` in the
  `.down.sql` of an irreversible one.
- **Preservation:** the test climbs version by version on one database: at each version it applies its seed (if any),
  requires at least one row in each table and checks that the next migration changes no `count(*)`. Each seed only
  fills the new tables of its version.
- **testdb:** the cluster is started by the first test that asks for a database (a package without database tests
  pays nothing); `NewEmpty` gives an unmigrated database (for migrate). If the socket path exceeds 107 B (a long
  `TMPDIR`), the server listens on 127.0.0.1 with a free port, and retries if another process takes it (verified with
  a 137 B path). An `owner.pid` in the folder lets startup delete the clusters of runs that died before reaching the
  end of `Main` (since the review, §19.7, a watchdog does that first; `owner.pid` remains for a system without `sh`).
  An `ELDMARK_PG_BIN` without `initdb` does not search elsewhere. Databases are named `eldt<pid>_tmpl` and
  `eldt<pid>_t<n>`, so they also work against a shared server (`ELDMARK_TEST_DATABASE_URL`, verified), where `Main`
  deletes them at the end. `DumpSchema` uses `pg_dump --schema-only --no-owner --no-privileges` and removes the
  `\restrict`/`\unrestrict` lines, which PostgreSQL 16.10 and later put with a different key in every dump.
  `max_connections = 200`.
- **`TMPDIR` must be accessible to the `postgres` user** when tests run as root. On this machine, under the session's
  scratchpad the server dies mid-test (`/tmp/claude-0` goes back to 0700 while it runs); with the default `TMPDIR`
  (`/tmp`) it works fine.
- **`db.InTx`:** the "three times" of §7.3 are three retries, four attempts in total (`MaxAttempts`).
- **413:** code `too_large` ("La petición es demasiado grande", i.e. the request is too large), which §4.1 did not
  name.
- **Secrets:** the check of §10.3 is in `tools/check_secrets.sh [root]`, which can be run locally; CI runs it first.
  Tested in a disposable repository: clean → 0; a `staging.env`, a `secrets/ticket_keys` or a `zone.key` in the index
  → 1 and it names them; an `ELDMARK_TICKET_KEYS=…` in an `*.example` → 1 without repeating the value.
  `ELDMARK_X_FILE=` does not count.
- **CI:** the "Plataforma" job runs apart from the Godot ones (without touching them): checkout without LFS, the
  secrets check, `actions/setup-go@v5` with `go-version-file: platform/go.mod`, `ubuntu-latest`'s PostgreSQL (or
  `apt-get install postgresql-16` if missing), `gofmt -l`, `go vet ./...` and `go test -p 2 ./...` with
  `GOTOOLCHAIN=local` and `ELDMARK_REQUIRE_PG=1`. For it to block merging it must be marked as required.
- **`.gitignore`** also ignores the `platform/eldmark-platform` binary.
- **Dependencies:** those of §2.2 that are needed already (pgx v5.8.0 and x/text v0.31.0); pgx also brings, indirectly,
  `jackc/puddle/v2` v2.2.2, `golang.org/x/sync` v0.18.0, `pgpassfile` and `pgservicefile` (all with `go` ≤ 1.24.0).
  x/crypto comes in with P1 (argon2).

**Measured** (this machine, 4 cores, Go 1.24.7, PostgreSQL 16.15):

| What | Time |
|---|---|
| `go test ./...` with an empty build cache | 44 s wall clock, almost all compilation |
| `go test -p 2 ./...` with a warm cache (like CI) | 11 s; no package exceeds 5 s |
| `go test -race ./...` | 50 s, no races |
| Cluster (`initdb` and startup) plus the template with 0001–0006 | 1.3 s, once per package |
| A test's database (`create database … template`) | 85–105 ms (§2.6 said 60 ms) |
| `eldmark-platform migrate up` of 0001–0006 on an empty database · `migrate down 6` (the whole command) | 125–145 ms · 45–60 ms |
| Binary (`go build`) | 15.7 MB |

Checked by hand with the binary against an ephemeral cluster: `serve` without migrating gives `/health` 200 and
`/ready` 503 ("la base no tiene migraciones; ejecuta "eldmark-platform migrate up"", i.e. the database has no
migrations; run `eldmark-platform migrate up`); after `migrate up`, `/ready` 200 on both APIs on the next loop; an
unknown route, 404 `not_found` with `X-Request-Id`; SIGTERM shuts down with code 0. Godot: `--import` gives the same
log with and without `platform/`; `test_export_config` (10), `test_assets` (7) and `test_architecture` (16) pass.

**Unverified:** the "Plataforma" job on GitHub (`ubuntu-latest`'s PostgreSQL and that `setup-go` reads the `toolchain`
line); `serve` with direct HTTPS (`ELDMARK_TLS_*`: the code is there, without a test).

**Left for later:** the `admin` command (P1 and P7a), the `/v1` and `/internal/v1` routes (P1–P3), the periodic jobs
(P3, P9a), the legal texts in `legal_documents` at startup (P1) and `deploy/` (P9b), where the development compose
that TEC-22 names will go.

### 19.2 P1 · accounts (TEC-23, TEC-41, acceptance part of TEC-43)

**What exists.** The accounts and sessions of §4.1 to §4.3, mounted in `serve`:

| Piece | Content |
|---|---|
| `internal/passwords` | `Params`, `Hash`, `Verify` (with `needsRehash`) and `Filler` (the dummy hash) of §14.2: argon2id as a PHC string, 16 B salt and 32 B hash. At most `runtime.NumCPU()` computations at a time across the whole process; a string asking for more than 1 GiB or 64 passes is `ErrFormat` |
| `internal/accounts` | The service and its routes (below): `CheckPassword` with failures per account and IP group, registration without revealing accounts, login with the privacy session, refresh that rotates in the row, lifecycle with single-use links, export, account purge, pages `/verify`, `/reset` and `/revert`, `/v1/status` and `/v1/legal` |
| `internal/mail` | The eight templates, in Spanish (`verify_email`, `register_existing`, `register_blocked`, `reset_password`, `change_email`, `email_changed`, `email_reverted`, `login_failures`), `LogSender` (`outbound_mail` and the log with the full link), `SMTPSender` (background queue, STARTTLS mandatory except towards loopback, `smtps://` with direct TLS, two retries), `BuildMIME` (`mime.QEncoding`, quoted-printable) and `Recorder` for tests |
| `internal/ratelimit` | Token bucket per key and an LRU of 100 000 keys (§4.2) |
| `internal/clock` | The injectable clock of §15 (`clock.Fake` in tests): every accounts deadline is compared with Go's time passed as a parameter, not with `now()` |
| `platform/legal` | `terms-1.md`, `privacy-1.md` (with the table of §11.1) and `rules-1.md` (the scale of social.md §9), drafts with the header of §11.4, embedded in the binary; `Load`, `Current` and `Sync` (inserts into `legal_documents` the versions that are missing) |
| `internal/httpx` | `ClientIP` (`X-Real-IP` only from `ELDMARK_TRUSTED_PROXIES`), `AddrGroup` (whole IPv4, IPv6 by /64), `RequireProtocol` (426 `client_outdated` with `min_protocol`) and `Fail` (an unavailable-database error → 503; any other → 500, logged with the request id) |
| `internal/app` | `OnBoot` (what runs at startup with the schema up to date: publishing the texts), `AddJob` (periodic jobs with `pg_try_advisory_lock`) and 503 on the packages' routes until startup finishes |
| `cmd/eldmark-platform` | `mountServices` (`services.go`): texts, mail according to `ELDMARK_MAIL`, the service, its routes and the `accounts_purge` job every hour |

Routes: those of §4.2 and §4.3 as is, all with the 426 rule. The privacy session admits only `GET /v1/account`, `POST
/v1/account/export`, `POST` and `DELETE /v1/account/deletion` and `DELETE /v1/sessions/current` (and refresh, which
carries no access token); the rest, with the privacy session or with a current sanction, gives 403 `account_suspended`
or `account_banned` with `until` and `reason`.

**For the following packages.** P2 mounts its routes with `httpx.RequireProtocol(min, api.RequireSession(false, h))`
and reads the session with `accounts.SessionFrom(ctx)` (account, role, state and scope); this way `enter` already
gives the 403 of a sanction. For the rest of `enter`'s checks (§4.5) it has `accounts.ActiveRestriction`,
`Service.MissingAcceptances` (the texts to accept: `terms_required`) and `Service.Slots` (6 plus the
`character_slots` entitlements). P3 composes the `message` of `account_blocked` with `Restriction.Message()` (cut at
255 B). The purge of an account's characters enters through `accounts.CharacterPurger` (P2 or P9a).

**Deviations and implementation decisions:**

- **Legal texts in the binary.** `platform/legal` is a Go package with `//go:embed *.md`, and an empty
  `ELDMARK_LEGAL_DIR` (previously `platform/legal`) means "those in the binary": the relative path depended on where it
  was started from (the README starts `serve` from `platform/` and the image only carries the binary). With the
  variable, they are read from that folder. A published version whose text changes does not start in `staging` or
  `production` (the account accepted the previous one: a new text is a new file); in `dev` and `test` its SHA-256 is
  updated with a warning.
- **The drafts already arrive in P1** (§14.1 put them in P9a): registration requires accepting them. P9a reviews them;
  until they are published in staging, changing them does not require a new version.
- **`ELDMARK_MAIL_FROM`**, new: the sender (by default `no-reply@<host of ELDMARK_PUBLIC_URL>`, or `no-reply@localhost`
  if it is an IP).
- **Minimum protocol.** Until `progression_rules.json` exists (P2), in `dev` and `test` without `ELDMARK_MIN_PROTOCOL`
  the minimum is 0: any header with a positive integer is valid, and `/v1/status` gives `min_protocol: 0`. Without the
  header, always 426.
- **`/verify` also confirms the email change:** the `change_email` email links to `/verify`, which looks at the
  purpose of the link (§4.3 only names three pages). Confirming the change revokes **all** sessions, not "the other
  ones": the link arrives without a session.
- **Bodies that §4.2 did not fix.** `GET /v1/account` gives `realms` and `slots` as maps by world (`{"1": 6}`),
  `pending` with `terms_required`, `documents` (the types to accept) and `deletion_at`, and in addition `restriction`
  (`null` or as at login). Refresh returns the pair with `scope`. Verify, confirm and revert give 204; dates are in
  Unix.
- **New codes:** 409 `deletion_expired` when cancelling a deletion whose deadline has passed before the hourly purge
  runs (with no deletion requested, cancelling gives 204); 503 `unavailable` when the database does not respond, a
  transaction collides too many times or the platform is starting (§4.1 had no code for that); 413 `too_large` (from
  P0). `auth_events.kind` adds `register_blocked`.
- **Password failures.** After 5 consecutive failures from a group, each further failure locks again for 15 min, and
  from the 10th, 1 h. The account throttle (one attempt every 30 s) counts from the last failure. A throttled attempt
  does not check the password or count as a failure. With an email that has no account (or an account without a
  password) the same query is made (with id 0) and the check is run against the dummy hash. Since the review (§19.7),
  attempts on the same key go one at a time.
- **Email limit.** "3 per account and hour" goes per recipient (the email's SHA-256), so it weighs the same whether or
  not the account exists; an email change also spends from the requesting account. Token bucket: burst of 3 and one
  token every 20 min (the same for the other per-hour limits).
- **Account purge already in P1**, that of §11.2 as far as the account is concerned: used by unverified accounts
  (staging and production) and by accounts whose deletion has expired (in all environments). It also deletes the
  account's `auth_events`, `account_realms` and `outbound_mail`. Without `CharacterPurger`, an account with unpurged
  characters is not purged and is logged ("tiene personajes", i.e. has characters), and the next round retries.
- **Fingerprint of sanctioned emails**, already in P1 because the purge needs it: each unrevoked sanction counts up
  to 90 days after its end (a warning or a rename, with no duration, from when it was set; a permanent ban, the cap),
  with 1 year at most from the purge. P9a reviews it with the table of §11.1.
- **Export already in P1** (§4.3 puts it in the lifecycle and §15 P1 tests it): account without hash, acceptances,
  consents, 30 days of sessions and logins, entitlements, realms, characters with their PvP statistics, ignores by
  name, sanctions without author, reports made and chat sent. The progress of each character is missing
  (`ProgressStore.Export`, P9a). Dates are in RFC 3339: it is a file for people.
- **Email:** in addition to §4.2, domain labels only admit `[a-z0-9-]`, with no hyphen at the start or end.
  Surrounding spaces are removed, not other whitespace: a trailing line break is not valid.
- **Pages:** `/reset` asks for the password twice; a used, expired link or one whose email is already in use is
  reported by the page (400) without repeating the token. There is no separate CSRF protection: the single-use token
  is one.

**Tests** (`internal/accounts`, with the ephemeral database and the fake clock): all of those in §15 P1, plus the 1 h
lockout after 10 failures, the 6 s throttle of the per-IP bucket, invalid bodies (CR/LF, IDN, display name, two @,
short, long or email-equal password, old versions, unknown fields, 1.5 in a version, 413), the registration and email
limits (also with an email without an account, which receives nothing), recovery (revokes all sessions and invalidates
the links), an email change towards one with an account (`register_existing`), a new version of a text
(`terms_required` until accepted; registration requires it), consents, slots with entitlements, `/v1/status` with the
load and `/v1/legal`, the `/verify` page with an email change, `/reset` and `/revert`, export (one per day) and the
purge of a sanctioned account, whose email is no longer registered. In addition: `passwords`, `mail` (with a fake SMTP
server), `ratelimit`, `legal` (strict and non-strict `Sync`), `httpx` (client IP, 426, `Fail`), `app` (hooks, jobs and
their lock, 503 until started) and `serve` really mounted (texts published at startup and a registration with its
email).

**Measured** (this machine, 4 cores, Go 1.24.7, PostgreSQL 16.15):

| What | Time |
|---|---|
| argon2id with the production parameters (`m=19456,t=2,p=1`) | 32 ms per check (§0 said 59 ms in the probes) |
| `go test -p 2 -count=1 ./...` with a warm build cache | 18 s; `internal/accounts`, the slowest, 10 s (30 tests) |
| `go test -race -p 2 ./...` | 34 s, no races |
| Binary | 19.6 MB (15.7 MB in P0) |

Godot: `--import` gives the same log with and without `platform/`.

**Unverified:** sending through a real SMTP server (STARTTLS and authentication: the test uses a fake server on
loopback, without TLS); export and purge with characters (P2 and P9a).

**Left for later:** in `enter`, `terms_required`, `email_unverified` and `account_pending_deletion` (P2, with the
above); the limits for checking names and for entering (P2); the `admin` command (P7a), with which the first `admin`
account and the test ones will be created (`dev.sh`, P9b); scheduled maintenance and the news in `/v1/status`
(TEC-28; today `status` only looks at `worlds.status`); the hourly retention jobs (P9a); progress in the export (P9a);
and the client (P8).

### 19.3 P2 · characters (TEC-24, SOC-13, PRG-41)

**What exists.** The characters and the entry to the world of §4.4 and §4.5, mounted in `serve`, and what Go and Godot
share (exported rules, name cases and ticket vectors):

| Piece | Content |
|---|---|
| `internal/gamedata` | `progression_rules.json` with `//go:embed`. `Load` and `MustLoad` read and check `protocol_version` and `names`; the other sections are not examined here (they belong to progression.md) and `Raw` gives the whole file for `progress.LoadRules` |
| `internal/names` | `NameRules` in Go (§14.2): `Validate` (with the values of `NameRules.Reason` and their API code, `too_short`…), `NormalizeKey`, `IsReserved` and `ReasonText`, all read from the `names` section; `names.Validate` and `names.NormalizeKey` use the embedded rules |
| `internal/tickets` | The ticket of §5.1: `Ticket`, `ZoneKey`, `Sign`, `Parse` (checks, in this order, size, version, key and signature: `ErrSize`, `ErrVersion`, `ErrKey`, `ErrMAC`), `NewID` (from 1 to 2^63 − 1) and `Lifetime` (10 s) |
| `internal/persistence` | `progress.go`, the boundary of §7.5 with the signatures of progression.md §13.2 (`ProgressStore`, `CreateParams`, `SaveKey`, `Summary`, `Querier`, `InvalidSaveError`, `ErrNotFound`, `CreateValidator`, `ValidationError`) and `ProvisionalValidator` (§4.4 step 5); `memory.go`, the fake: `MemoryProgressStore` |
| `internal/characters` | The service and its routes (`List`, `NameCheck`, `Create`, `Delete`, `Restore`, `Rename`, `Enter`) and character purging (`Purger`: `PurgeExpired`, the hourly job, and `PurgeAccountCharacters`, P1's `accounts.CharacterPurger`) |
| `internal/accounts` | `Service.Event` (the `auth_events` row in the caller's transaction) and `ErrCharactersBusy`, which the account purge logs as a warning |
| `cmd/eldmark-platform` | `serve` resolves the minimum protocol with `progression_rules.json`, picks the progress store and the validation (`progressStore`, §7.5), mounts the characters and adds the `characters_purge` job (every hour) |
| Godot | `ProgressionRulesExport` (`scripts/shared/progression/`, sections `protocol_version` and `names`), `tools/progression/export_rules.gd` (with `-- --check` it does not write) and `tests/test_progression_rules_export.gd`. In `NameRules`, `FOLDED` (previously private `_FOLDED`), `REASON_CODES`, `reason_code` and `reason_from_code` |
| Test data | `tests/fixtures/names/name_rules_cases.json` (119 cases `{name, reason, key}`, with the reason as its API code), read by `test_name_rules.gd` and `internal/names`; `tests/fixtures/tickets/handoff_ticket_vectors.json`, for `HandoffTicket` (P4) |

Routes: those of §4.4 as is, all with the 426 rule and `RequireSession(false)` (a sanctioned account receives 403 with
the reason). Bodies that §4.4 did not fix: create (201), restore and rename respond `{character}`; delete,
`{restore_until}`; the list, `{realm, unlock_at, slots, used, characters}` with `realm` null if the account has no
realm in that world yet. A character brings `race_id`, `appearance` (base64) and `last_zone_id` as null (and the level
as 1) if the store does not have it. `name-check` gives empty `code` and `reason` when they do not apply. In errors,
`name_invalid` carries `reason`; `realm_locked`, `realm` and `unlock_at`; `terms_required`, `documents`;
`account_pending_deletion`, `deletion_at`; and `maintenance`, `until` (null until TEC-28). Dates are in Unix.

**For the following packages.**

- **P3** has the interface and the fake: `MemoryProgressStore.SetApplyHook` decides the result of `Apply` (an
  `*InvalidSaveError`, a database error…), `Load` returns the last applied value without `ops` and with the read-only
  fields, and `Apply` takes the level, played time and last zone for the summary from the body. The ticket is left in
  `enter_tickets` with `session_id`, `zone_instance_id` and `expires_at` (issue + 10 s, with Go's clock).
  `characters.last_entered_at` is not written: the claim may set it.
- **P4** checks `HandoffTicket` with the shared vectors (ids as strings, `String.to_int()`).
- **progression.md P3** adds its sections to `ProgressionRulesExport.build()` (one function per section, like `_names`)
  and checks its own in the same test; **P7** implements `ProgressStore` and `CreateValidator` (`*progress.Rules`) and
  changes only `progressStore()` of `cmd/eldmark-platform/services.go`, which will stop refusing in `staging` and
  `production`.
- **P7a**: `admin names block|unblock` writes `name_blacklist` with `names.NormalizeKey`; the `rename` sanction sets
  `characters.must_rename`, and P2 already answers `rename_required` in `enter` and allows renaming.
- **P9a** already has character purging (below); it is left with `reapply-purges`, ledger retention with
  `PurgeRetention` and deleting empty tombstones, and progress in the export.

**Deviations and implementation decisions:**

- **Create is not serializable** (§4.4 asked for it): it first locks the account row, like delete and restore, and
  that puts everything account-related in series (realm, slots and daily limit); the name is decided by the primary
  key of `character_names` with `insert … on conflict do update … where` the row is reserved and expired.
  **Measured:** with serializable, 8 accounts creating characters with different names at once received 503 in 4 of 20
  runs of the test (SSI with predicate locks on small tables, which exhausted the 4 attempts of `db.InTx`); with the
  account row, in none of 25, and two creations of the same name still give a single row and `name_taken` to the
  others (25 of 25).
- **The fake in `serve`.** Until progression.md P7, `serve` uses `MemoryProgressStore` and `ProvisionalValidator` in
  `dev` and `test`, with a log warning: progress (race, appearance, level…) is lost on restart. In `staging` and
  `production` it does not start ("el almacén del progreso (docs/progression.md P7) aún no existe…", i.e. the progress
  store does not exist yet).
- **Character purging already arrives in P2** (§14.1 put it in P9a): that of §11.2 in its two paths for now (expired
  deadline, in the hourly job, and with the account, in P1's purge), with the lease and character-row locks, the
  tombstone, `purge_log` and `ProgressStore.Purge`, and not purging with a live lease (the next round retries; with
  the account, `accounts.ErrCharactersBusy` and the account is not purged either). With the account, the name of a
  living character stays reserved 30 days; that of a deleted one keeps its reservation. Without it, P1's purge left
  every account with characters unpurged.
- **Restoring** a character that is not deleted returns it as is (200); out of the grace period or purged, 404.
  **Deleting** one already deleted, 404.
- **Renaming** without `must_rename` gives 409 `rename_not_required` (new code); with the character in the world,
  `character_busy`; to the same name with other case or accents, `name_taken`.
- **Provisional validation:** a race of another realm is `wrong_realm` and one that does not exist, `unknown`; an
  appearance that is not 8 B of base64 or an unknown realm are 400 `validation` (`appearance` or `realm: invalid`)
  before opening the transaction, like a missing field (`required`).
- **`enter`.** Maintenance (`worlds.status = 'maintenance'`, 503 `maintenance` except for `admin`) is checked after
  sanctions, which `RequireSession` already checks, and not before as in §4.5. `worlds.status = 'locked'` does nothing
  yet. The last zone is valid if it has a live channel that admits the realm **and has room**; if all are full, the
  entry zone (§4.5 did not say). An instance with a channel outside 0–255 is not offered (the ticket carries it in a
  u8). It does not check the heartbeat: declaring an instance lost is P3's job. A `ticket_id` that collides with the
  primary key is replaced by another (up to three attempts).
- **Limits:** `name-check`, 30 per minute and session, and `enter`, 10 per minute and account, in memory; create and
  delete, 5 per day with `auth_events`. The 429 for create and delete carries what is left for the oldest of the 5 to
  leave the 24 h.
- **`NormalizeKey`** lowercases each character with `unicode.ToLower`, like `String.to_lower()`; the 119 shared cases
  (with invisibles, combining characters, Cyrillic and full width) give the same on both sides.
- **`progression_rules.json`** is created by this package (§4.4: "whoever gets there first"), with `protocol_version`
  5, main's (P4 bumps it), and `names`. A Go test checks that its `protocol_version` is that of `net_protocol.gd`. In
  `dev` and `test` without `ELDMARK_MIN_PROTOCOL`, the minimum goes from 0 (P1) to that number.
- **Ticket vectors:** `handoff_ticket_vectors.json` is generated by the Go test (`go test ./internal/tickets -run
  TestSharedVectors -update`) and the test fails if the file does not match. It carries the two keys in
  hexadecimal, five zone fingerprints, the vector of §5.1 (also in the base64 of §4.5), one with `ticket_id` 2^63 − 1
  and `character_id` 2^53 + 1, a handoff one (world 513, channel 255, dates at the end of the u32) and 9 invalid ones
  with the corresponding error (`mac`, `key`, `version` or `size`).

**Tests** (`internal/characters`, with the ephemeral database, the fake clock and the progress fake; 26): all of those
in §15 P2 (name cases in Go and in Godot; two simultaneous creations of the same name, in three rounds of 8 accounts;
"Anéira" versus "ANEIRA" and "Aneira"; locked realm; slots with a character deleted within the grace period; the
sixth character of the day; creating and deleting right away frees the name at `restore_until`; invalid race and
template; delete, restore and reserved name; `enter` without a live zone; `enter` picks the last zone; the ticket
vector), and in addition: simultaneous creations from different accounts, blacklist, realm that is freed after 30 days
and changed, slot entitlements (also revoked), a deletion outside the grace period that stops taking a slot, missing
or extra fields, account with deletion requested and suspended account (403 on all routes), `name-check` limit,
deletion confirmation, deleting with the character in the world and the deletion limit, characters of another account
(404), forced rename (also in the world), the `enter` ticket read with `tickets.Parse` and its row in `enter_tickets`,
DTLS, the zone and channel choice (last channel, full, realm not admitted, stopped), the `enter` checks in order
(email, texts, pending deletion, maintenance and `admin`, deletion, limit), a single character of the account in the
world, the hourly purge (with a live lease, tombstone, reserved name, repeated), a restore that beats the purge and the
purge of an account with characters. In addition: `names` (shared cases, rules from other data, broken UTF-8),
`tickets` (vector, errors, 1000 round trips, `NewID`, shared vectors), `persistence` (errors, provisional validation,
the fake), `gamedata` and `serve` (characters mounted, minimum protocol from the rules, and it refuses with the fake in
`staging` and `production`). In Godot: `test_progression_rules_export.gd` (5) and two new tests in
`test_name_rules.gd`.

**Measured** (this machine, 4 cores, Go 1.24.7, PostgreSQL 16.15):

| What | Time |
|---|---|
| `go test -p 2 -count=1 ./...` with a warm build cache | 14 s; `internal/characters`, 3 s (26 tests) |
| `go test -race` of the new packages and `accounts` | 20 s, no races |
| The two concurrency tests, 25 times in a row | 14 s, no failures |
| Binary | 19.8 MB (19.6 MB in P1) |

Godot: `--import` gives the same warnings and errors with and without the changes (the usual leaks on exit), and the
whole suite passes (1924 tests in 1048 s). A disposable GDScript script read the ticket vectors with
`JSON.new().parse`: the fingerprints (`sha256_buffer().decode_u32(0)`), the signatures with key 1 (`HMACContext`) and
the `ticket_id` above 2^53 (`String.to_int()`) give the same as in Go.

**Unverified:** `enter` against a real zone (the claim belongs to P3; the ticket in the zone, to P4; both together, to
P10); `NormalizeKey` with characters whose lowercasing differs between Go's and Godot's Unicode tables (none of the
cases does).

**Left for later:** the claim that consumes the ticket and `last_entered_at` (P3); `HandoffTicket` with the vectors
(P4); `admin names block|unblock` and the `rename` sanction (P7a); the client (P8); `reapply-purges`, ledger retention,
deleting empty tombstones and progress in the export (P9a); progression.md's sections in the exported rules and
`*progress.Rules` with the real store (progression.md P3 and P7).

### 19.4 P3 · internal API (TEC-24, TEC-25)

**What exists.** The whole internal API of §6, mounted in `serve` on `ELDMARK_INTERNAL_ADDR`, with the lost-instances
job:

| Piece | Content |
|---|---|
| `internal/zones` | `Registry` (`Authenticate`: SHA-256 of the token and `subtle.ConstantTimeCompare` against all entries), `Scope`, `Instance` and the state table of §6.1 (`Instance.Check` per request), `Guard` (steps 1 to 3 of §6.1: 401 `bad_token`, 403 `forbidden` and the state's 409), `Fail` (503 `db_unavailable`), UUIDs (`NewUUID` from `crypto/rand`, `FormatUUID`, `ParseUUID`), the service (`Register` with replacement and loss on registration, `Live`, `Heartbeat`, `Stop`, `MarkLost`, `IDBlock`) and its routes; for batches, `DecodeBatch`, `ParseEntry`, `KeyChecker` (`<uuid>:<n>` key of the instance or `op:<op_id>` from its blocks) and `InsertEach` |
| `internal/persistence` | `store.go`: `Store` with `Claim`, `Save`, `SaveMany` and `Release` of §14.2, `ParseEnvelope` (the strict envelope) and `SaveError` (the error rule of §7.3); `api.go`: the routes for claim, save, save batch, release, operation and ledger. `memory.go` (the fake) adds what is below |
| `internal/war` | Fortresses (GET for the instance's zone, PUT with a version) and the war-event batch |
| `internal/social` | The chat and audit batches, ignores, reports and sanctions with the authorization of §9.5 |
| `internal/sanctions` | New leaf package: the current restriction (`Active`, `ActiveMany`), mutes (`Mutes`), the texts for the player (`Restriction.Message`, `PendingDeletionMessage`, `Truncate` to 255 B), `Rank` and `MinRole` (§9.1) |
| `internal/platformtest` | For tests: the whole platform in-process (ephemeral database, fake clock, in-memory progress, both APIs) with client helpers (`NewPlayer`, `NewCharacter`, `MustEnter`) and zone helpers (`Zone.Start`, `Join`, `Heartbeat`, `SaveBody`, `Save`…) |
| `internal/accounts` | `ActiveRestriction` and `Restriction.Message` use `internal/sanctions`: a single text for the public API's 403, the claim's `account_blocked` and the heartbeat's `text` |
| `cmd/eldmark-platform` | `mountInternal` (`services.go`): zones, store, war and social, and the `zones_lost` job every `min(5 s, HEARTBEAT_S)` |

All the routes in the table of §6, in the order of checks of §6.1. Bodies that §6 did not fix: `POST
/internal/v1/saves` responds `{instance_status, saves: [{character_id, applied, duplicate, save_version}]}` in batch
order, and an error from one also carries its `character_id`; `DELETE /internal/v1/ignores` carries the same body as
the `POST` and gives 204 even if there was nothing; the sanction responds `{sanction_id, ends_at_unix}`; a report,
`{report_id}`. New codes: 409 `ignore_list_full` (100 ignores) and the `not_found` of a name that does not exist in
the instance's world.

**For the following packages.**

- **P4** (the zone): bodies and errors are those of §6 with the above. The claim gives `muted_until_unix` 0 without a
  mute and `253402300799` (`sanctions.NoEndUnix`) for one without an end; `revoked` brings a `text` composed by the
  platform (also on `lease_lost`: "Tu personaje ha entrado en otro servidor"); `account_blocked` brings a `message` of
  255 B at most. The heartbeat's `maintenance` is always null (TEC-28).
- **P5**: the save accepts an absent `release_lease` (false); `seq` starts at 1 and may skip numbers; a `duplicate`
  does not call `Apply` again.
- **P6**: the first PUT of a fortress carries `expected_version` 0; one that does not exist with another value is 409
  `version_conflict` with `version` 0. The GET returns the record as `jsonb` stores it (keys reordered).
- **P7a**: the internal routes for ignores, reports and sanctions already exist (below). What remains is the `admin`
  CLI (`set-role` with its row, `reports list|show|close`, `audit`, `chat`, `names block|unblock`, `sanction`,
  `purge-now`), the audited queries and the expiry tests for each sanction.
- **progression.md P7**: the operation route calls `Op(ctx, pool, opID, instance)` without a transaction and the ledger
  one `Ledger(ctx, pool, …)` after checking the character's lease on the instance; `Apply` receives `SaveKey` with the
  `ZoneID` of the `claimed_by` instance and the `WorldID` of the lease, inside the transaction that already has the
  lease locked and the `seq` checked.
- **P9a**: the retention jobs for `enter_tickets` (1 day), stopped `zone_instances` (30 days), `chat_messages` and
  `audit_log`.

**Deviations and implementation decisions:**

- **Ignores, reports and sanctions already in P3** (§14.1 put them in P7a): §15 P3 tests them (the instance sets the
  world) and the table of §6.1 includes them. They are complete, with sanction authorization in three steps and the
  `sanction_denied` row.
- **New packages that §2.1 does not name:** `internal/sanctions`, a leaf, so that neither `zones` nor `persistence`
  import `accounts` (when P9a takes `ProgressStore.Export` to `accounts`' export, `accounts → persistence → accounts`
  would be a cycle), and `internal/platformtest`, the internal API test harness.
- **The clock.** All of P3's times come from Go's injectable clock (`started_at`, `last_heartbeat_at`, leases'
  `expires_at`, `consumed_at`, `granted_at`…), not from `now()`: tests advance the clock instead of waiting for the 15
  s of a lost instance or the 30 s of the TTL. P0's startup grace period still uses `now()` (in `serve` the two clocks
  are the same).
- **Claim.** It first locks the instance's row (`for share`): the order is instance → account → ticket → lease, and
  the lost-instances job and the heartbeat (which update it) do not cross with a claim in progress. It reads the
  character's account before locking it and checks the character again afterwards. A character from a world other than
  the instance's or from a purged account is `ticket_invalid`. It takes a lease with `expires_at ≤ now` (§5.3 said
  `<`: this way "expired" is exactly the opposite of "alive", `expires_at > now`, which `enter`, delete and the claim
  itself check). It used to write `characters.last_entered_at`; since the review (§19.7) the lease's first save writes
  it, and the 403 `account_blocked` comes after validating the ticket.
- **Heartbeat.** Priority of `revoked` per account: `banned` > `suspended` > `pending_deletion` >
  `session_revoked`. The texts for `session_revoked`: "Has iniciado sesión desde otro lugar" (`replaced`), "Has
  cerrado la sesión" (`logout`), "Un administrador ha cerrado tu sesión" (`admin`) and "Tu cuenta ha cambiado: vuelve a
  entrar" (the rest). Kicked characters keep being renewed: the zone still sends its final save. A `lease_lost` comes
  out once per character even if the heartbeat repeats it.
- **Registration.** `protocol_version` below the clients' minimum protocol, or `record_format` other than 1: 409
  `schema_mismatch`. The certificate is read as PEM X.509 and with it `dtls_name` is mandatory. Two simultaneous
  registrations of the same scope: the second collides with the partial unique index and receives `instance_alive`.
  The `replace` row in `audit_log`: `source = 'platform'`, `command = 'zone_replace'`, `args = {replaced, by,
  channel}`. With `replace` over an instance that has already gone 3 × `HEARTBEAT_S` without a heartbeat, it moves to
  `lost` (not `replaced`) and its leases are freed.
- **Deregistration** (`DELETE`): of a `replaced` one, frees whatever it has left and stays `replaced`; of a `lost` one,
  409 `instance_lost`; repeated, 204.
- **A `zone_instance_id` that is not a canonical UUID** (lowercase): 400 `validation`, not 403.
- **Save envelope.** `release_lease` is optional; `pvp` requires its six totals; `seq` from 1; a route `{id}` that is
  not an id is `envelope`. An `invalid_save`'s `detail` is cut at 500 B. `invalid_save`, `seq_conflict` and
  `stale_seq` are logged as a warning.
- **Save batch.** It locks the leases in `character_id` order; the same character twice or an envelope from another
  instance is `envelope`.
- **Releasing** an already free lease with the same `lease_id`: 204.
- **Ledger:** the lease on the instance is `zone_instance_id` equal to it, without looking at `expires_at`; a `limit`
  outside 1–100 or a `before_entry_id` that is not an id, 400 `validation`; an `op_id` that is not an id, 404.
- **War events** of a fortress that has no row yet are accepted (its first PUT goes through another queue and may
  arrive later); those of a fortress of another zone go to `rejected`.
- **Batch keys:** `<uuid>:<n>` without leading zeros; `op:<op_id>` only in audit (in chat and war it goes to
  `rejected`). Valid rows are inserted in one round trip (`pgx.Batch`); if any collides with a constraint, they are
  inserted one at a time to reject only that one.
- **Audit:** `command` of the form `^[a-z][a-z0-9_]{0,47}$` (CLI ones carry hyphens or spaces) and outside the
  platform's own (`sanction_denied`, `sanction`, `zone_replace`); `console` without an actor or `actor_character_id`,
  `zone` with `actor_account_id`.
- **Chat:** the sender must be a character of the instance's world; the text, 255 characters at most and without NUL.
  The log only carries the rejected keys, never the text.
- **Ignores:** oneself, 400; the name stored is the character's; un-ignoring deletes the account by name and the row
  stored with that name (the ignored player may have been renamed).
- **Reports:** the target must exist (404) and not be the reporter's own account (400); limits are counted in `reports`
  (in the database, not in memory), in series by the account row, and "per target" means per character.
- **Sanctions:** `minutes` ≥ 1 for mute and suspension, 0 for the others (a ban is permanent); `report_ids` must be
  reports of the instance's world (400); a rename sets `must_rename`; sanctioning oneself is `target_role`. Each
  sanction created leaves a `sanction` row in `audit_log` and each denied one a `sanction_denied` with `args.denied`
  (`no_lease`, `role` or `target_role`), without names or emails.
- **The fake (`MemoryProgressStore`)** gains `SetApplyTxHook` (runs inside the save's transaction), `AddOp` (and `Op`
  checks the participants' leases with the same query the real store will use), a toy S2 (an already applied `op_id`
  fails), `SaveVersion` and `Applied`. It still does not see transactions: if COMMIT fails, its data stays written;
  the "nothing written" tests look at the platform's tables.

**Tests** (51 new, with the ephemeral database, the fake clock and the progress fake): all of those in §15 P3 and in
addition the scopeless token and the instance that does not exist, the registration fields, the certificate in
`staging`, repeated live and deregistration, the state table of §6.1 request by request in the five states, id blocks
(1, 1025, 2049), renewal and the texts of each `revoked`, the heartbeat's mutes, another character's ticket,
`character_busy` without consuming the ticket, the save batch, repeated release, the repeated op_id (the fake's S2),
the 40P01 that is fixed by retrying, the replaced instance's lease that expires with the TTL, two instances claiming at
once, war events with all the rejection reasons, fortresses of another world, a lost instance's chat, ignores (cap of
100 and renamed players), the two report limits, sanction authorization (moderator requesting `ban`, GM against admin,
without a lease, oneself) with the mute in the heartbeat and the claim and the rename, `InsertEach` with one bad row
and `serve` with the internal API over HTTP.

**Measured** (this machine, 4 cores, Go 1.24.7, PostgreSQL 16.15):

| What | Result |
|---|---|
| `go test -p 2 -count=1 ./...` with a warm cache | 30 s; `internal/persistence` 6–8 s (28 tests), `internal/zones` 4–5 s |
| `go test -race` of the new packages, `accounts`, `characters` and `serve` | 30 s, no races |
| `DELETE` and claim at once, 8 rounds | 3 deletions without a lease and 5 claimed alive; no mixture |
| 100 saves of the same character, 8 at a time with increasing `seq` | 70–75 applied and the rest `stale_seq`; `save_version` = applied in all |
| Binary | 20.3 MB (19.8 MB in P2) |

Godot: `--import` gives the same log as before (nothing outside `platform/` was touched except documentation).

**Unverified:** against a real zone (P4) and with the real store (progression.md P7: S1–S8, the deferred constraint of
the slots in `0010_progress`, which is simulated here with a test table); batches and heartbeats with hundreds of
characters. (The `zones_lost` job inside `serve`, which was unverified here, has a test since the review, §19.7.)

**Left for later:** maintenance in the heartbeat (TEC-28); the zone (P4–P6, P7b); P7a's CLI; P9a's retention;
the end-to-end test (P10).

### 19.5 P7a · moderation in Go (SOC-14 to SOC-18)

**What exists.** The `admin` command with identity (§9.1), the audited queries, the warnings in the claim, chat
retention and a single sanction authorization for the zone and the CLI:

| Piece | Content |
|---|---|
| `internal/admin` | New: the command's service. `Authorize` (the `--actor`: active account, no current sanction and with the command's role; otherwise, `ActorError`), `SetRole`, `CreateAccount`, `Bootstrap`, `PurgeNow`, `Reports`, `Report`, `CloseReport`, `Audit`, `Chat`, `Sanction`, `Sanctions`, `RevokeSanction`, `BlockName` and `UnblockName`. Each command leaves its row in `audit_log` (`source = 'cli'`, `actor_account_id` of the `--actor`, `args.os_user`, the target by id), in the same transaction as what it does or reads; those that change something check the `--actor`'s role again with its row locked |
| `cmd/eldmark-platform` | `admin.go`: the `admin` command (arguments read and checked before connecting, tables with `tabwriter`, codes 0, 1 and 2) with `serve`'s configuration; `admin help`. `serve` adds the `chat_retention` job (every hour) |
| `internal/sanctions` | `Create` (the authorization of §9.5 and the sanction, which were in `social`: now used by the zone and the CLI), `RoleAt` (an account's role at an instant: S2's query, progression.md §13.3), `PendingWarnings` and `Warning.Text`, `Timed`, `Roles` and the `source` and `command` constants |
| `internal/social` | `Sanction` over `sanctions.Create` (same behavior and same P3 tests); `PurgeChat` and `ChatRetentionJob` |
| `internal/persistence` | The claim brings `account.warnings` (below) |
| `internal/accounts` | `RevokeSessions`, `PurgeNow` (the purge of §11.2 without waiting), `CreateAccount` (verified accounts for staff and testing) and `LookupAccount` |
| `internal/db` · `internal/testdb` | `MinPoolConns` (16) in `Open` · 10 connections per test database (previously 4) |
| `internal/platformtest` | `Admin` (with `os_user` "prueba") |

Commands (`eldmark-platform admin --actor <email> <command>`; "R", read, `moderator` suffices; the rest, `admin`):

| Command | Does | `audit_log` row (`command`; target; `args` besides `os_user`) |
|---|---|---|
| `set-role <email> <role>` | Changes the role and revokes all the account's sessions (`role_changed`): the next heartbeat kicks its character with a final save and it re-enters with the new role | `set-role`; the account; `{from, to}` (the fixed row of §9.1) |
| `create-account <email> --password-file <path> [--role player]` | Verified account, with age confirmed and the current texts accepted | `create-account`; the account; `{role}` |
| `bootstrap <email> --password-file <path>` | Without `--actor`: the first `admin` account, only if there is none | `bootstrap`; the account; no actor |
| `purge-now <email> [--wait 30s]` | Revokes sessions (`deletion`), waits for the leases to be released and purges (§11.2); if any is still alive, `character_busy` and nothing | `purge-now`; the account |
| `reports list [--status …] [--limit N]` (R) | The queue, oldest to newest | `reports list`; —; `{status, limit}` |
| `reports show <id>` (R) | The report with its evidence and its sanctions | `reports show`; the report's target; `{report_id}` |
| `reports close <id> actioned\|dismissed [--resolution …]` | Closes (`handled_by`, `resolution`, `closed_at`) | `reports close`; the target; `{report_id, status}` |
| `audit --since <date> [--until] [--actor-name] [--target] [--command] [--world] [--limit]` (R) | The audit with the characters' current names | `audit`; the `--target` one; `{since, until, actor_account_id, command, limit}` |
| `chat --character <name> --from <date> --to <date> [--world] [--limit]` (R) | What the character sent and the whispers it received, with zone and copy | `chat`; the character; `{from, to, limit}` |
| `sanction add <name> <type> [--duration 1h\|7d] --reason … [--report id]… [--world]` | `sanctions.Create` with the `--actor`'s account | `sanction` or `sanction_denied` (like the zone, with `source = 'cli'`) |
| `sanction revoke <id>` | Lifts it (`revoked_at`, `revoked_by`) | `sanction revoke`; the sanctioned player; `{sanction_id, kind}` |
| `sanction list <name> [--world]` (R) | The account's sanctions with their state (current, expired, revoked, noted, pending, served) | `sanction list`; the character |
| `names block <name> [--reason …]` · `names unblock <name>` | The `NameRules` key enters (or leaves) `name_blacklist`; warns about whoever already has that name | `names block` · `names unblock`; —; `{term}` |

A character is named by its name in the world (`--world`, 1) or by `#<id>`; dates in UTC (`2026-11-01`,
`2026-11-01T18:00` or RFC 3339).

**For the following packages.**

- **P4 and P7b (the zone):** the claim brings `account.warnings: [{sanction_id, text, at_unix}]` (empty list if there
  are none): the warnings the account has not seen, with the player-facing text already composed ("Has recibido un
  aviso de la moderación: motivo", 255 B at most). The zone sends a NOTICE with each `text` on entry (§9.5). A
  `set-role` arrives as `session_revoked` in the heartbeat ("Tu cuenta ha cambiado: vuelve a entrar") and the new role,
  in the next claim. `/gm` sanctions remain `POST /internal/v1/sanctions`.
- **progression.md P7 (S2):** `sanctions.RoleAt(ctx, tx, actorAccountID, time.Unix(at_unix, 0))` is the query of its
  §13.3 (the `args.from` of the first later `set-role` row with `source = 'cli'`, or the role in `accounts`); it
  returns "" if the account does not exist.
- **P9a:** `purge-now` already exists; `reapply-purges` enters `parseAdmin` like the others (`Authorize` with `admin`,
  its `cli` row). Chat retention already runs; what remains are those for `audit_log`, reports, sanctions,
  `auth_events` and others in §11.1.
- **P9b:** `dev.sh` creates the first account with `admin bootstrap <email> --password-file …` and test ones with
  `admin --actor <that email> create-account prueba@eldmark.test --password-file …`.

**Deviations and implementation decisions:**

- **Sanction authorization moves to `internal/sanctions`** (`Create`): the zone (`social.Sanction`) and the CLI
  (`admin sanction add`) use the same code and the same rows. The CLI passes the three checks of §9.5 except the lease,
  which it does not have (there is no instance), and requires `admin` for any type (§9.1: every command that changes
  something belongs to `admin`). Its rows use the platform's `command`s (`sanction`, `sanction_denied`) with `source =
  'cli'` and `os_user`, without `zone_id` or `actor_character_id`.
- **`sanction` is three commands:** `add`, `revoke` (lifting a sanction: the schema already had `revoked_at` and
  `revoked_by`) and `list` (one more read for `moderator`, audited). A revoked rename removes `must_rename` unless
  there is another unrevoked one set afterwards: the time of renaming is not stored, so it is not known whether an
  earlier one has already been served.
- **Warnings in the claim** (§6 had no field and §9.5 asks for the NOTICE on entry): `account.warnings`, the account's
  unrevoked warnings (from that world or all) set after the last entry to the world of any of its characters
  (`characters.last_entered_at`, read before writing this claim's), the 5 most recent. This way each warning comes out
  once. Since the review (§19.7), the mark is set by the lease's first save, with the claim's time: if the zone drops
  the character before it reaches the world (`REALM`, `FULL`, `prepare` or the drop in `LOADING`), the warning comes
  out again in the next claim.
- **Expiry of each sanction,** as tested: a warning comes out once and stays noted (it counts for recidivism and for
  `sanctioned_email_hashes`); mute and suspension end at `ends_at` (each query checks them with Go's time); a ban does
  not expire (only `sanction revoke`); a rename is served by renaming.
- **`bootstrap`** is new: §12 asks for "an `admin` account for `--actor`" without saying how the first one is born. It
  only works with no unpurged `admin` account (with `pg_advisory_xact_lock`) and always creates a new account (an email
  that has an account is an error: an existing one is given the role with `set-role`, which leaves its row for S2).
- **`create-account`** creates the account with the current texts already accepted (staff and test accounts: the bot of
  §13.3 does not know how to accept texts) and first publishes any missing texts to `legal_documents`, like `serve`, so
  it can run before the first startup. The password only arrives through `--password-file` (the command line is
  visible with `ps`). It does not check `sanctioned_email_hashes`.
- **`set-role`** on one's own account is an error (nobody is left without `admin` by accident) and to the same role it
  does nothing and leaves no row. It locks the `--actor`'s and the target's rows in id order, like
  `sanctions.Create`: two `admin`s removing each other's role at once do not both end up without it (one wins; the
  other exits with 2). The row's time is Go's clock (in `serve` and in the CLI, the system's).
- **`purge-now` arrives here** (§14.1 did not put it in any package and §15 P7a tests it): it revokes the sessions and
  leaves its row in one transaction, waits in real time up to `--wait` (30 s) checking live leases every 500 ms and
  calls P1's account purge (which checks them again with the row locked). On one's own account, error. In `staging`
  and `production` it refuses while the progress store does not exist, like `serve`.
- **`chat`** also gives the whispers the character received (the history of harassment). **`audit`**: `--target`
  matches the character or its account; `--actor-name`, with the character's account as actor; `--until`,
  `--command` and `--limit` (200 by default, 5000 at most) are new. Names typed into a filter are not stored: the
  target goes in `target_*` and the filter's actor as an id in `args`.
- **`names block`** only admits terms made of letters (a valid name's key has nothing else) and renames nobody: it
  lists whoever already has that name so they can be given a rename.
- **Chat retention arrives here** (§14.1 put it in P9a), because SOC-15 and §15 P7a ask for what has expired to
  disappear: the `chat_retention` job, every hour, deletes by `sent_at` (the zone's time) anything older than 30 days
  in batches of 10 000.
- **Connection pool.** With a fourth periodic job, the four each had a connection with their `pg_try_advisory_lock`
  and waited for another for their work: with pgx's pool (`max(4, cores)`, 4 on a 4-core VPS) they blocked each other
  and the APIs until the shortest one's deadline (the 5 s of `zones_lost`). `db.Open` now sets 16 connections if the
  string carries no `pool_max_conns`, and `testdb`, 10 per database. Measured: `TestServeMountsTheInternalAPI` went
  from 5.2 s to 0.4 s with the fourth job.
- **`admin` reads the whole of `serve`'s configuration** (`config.Load`: in the container it has the same variables)
  and refuses with an unmigrated schema. Codes: 0 ok; 1 command error (also `character_busy` and an unauthorized
  sanction); 2 usage or an invalid `--actor` (if missing, before connecting).

**Tests** (`internal/admin`, 17, with the whole `platformtest` platform): all of those in §15 P7a —a moderator
requesting `ban` and a GM against an admin remain in `social` (P3) and in addition an admin against another admin
through the CLI (`sanction_denied` with `source = 'cli'`); without a lease, in `social`; the expiry of each type with
the clock (`TestWarningIsShownOnce`, `TestMuteExpires`, `TestSuspensionExpires`, `TestBanUntilRevoked`,
`TestRenameUntilRenamed`); `set-role` that revokes, the fixed row and the heartbeat that kicks (`TestSetRole`);
`reports show` without `--actor` (in `cmd`, code 2) and with it, its row; `chat` between two dates with
`zone_channel` and retention (`TestChatHistoryAndRetention`); no CLI row or `sanction_denied` with emails or names
(`TestAuditHasNoPersonalData`, which runs all the commands); a batch with `source = 'cli'` or `command = 'set-role'`
rejected and `RoleAt` not seeing it (`TestRoleAtOnlyReadsCLI`)— and in addition `--actor` (TestAuthorize, also the role
lost halfway through a command), two crossed `set-role`s (8 rounds), blacklist, `reports list|close`, `audit` with
filters, `purge-now` with a character inside and outside, `create-account` and `bootstrap`. In `cmd`:
`TestAdminUsage` (15 usage errors without a database), `TestAdminCommands` (the commands through the command line,
with `os_user` from `$USER`) and `TestServeRunsTheChatRetention`. In `sanctions` and `db`, one test each.

**Measured** (this machine, 4 cores, Go 1.24.7, PostgreSQL 16.15):

| What | Result |
|---|---|
| `go test -p 2 -count=1 ./...` with an empty test cache | 26–30 s (30 s in P3: the larger pool removes the 5 s wait from the `serve` tests); `internal/admin` 3–4 s (17 tests) |
| `go test -race` of `admin`, `sanctions`, `social`, `persistence`, `accounts`, `db`, `app` and `cmd` | 30 s, no races |
| `internal/admin` 10 times in a row (`-count=10`) | 34 s, no failures |
| Binary | 20.6 MB (20.3 MB in P3) |

Godot: `--import` gives the same log as before (the usual leaks on exit); outside `platform/` only documentation
changes.

**Unverified:** `set-role` and `purge-now` with a real zone that kicks and sends its final save (here the test zone
releases by hand; it belongs to P4 and P5); `audit` and `chat` with large volumes; the CLI inside the container (P9b).

**Left for later:** the moderation zone side (P7b: `min_role`, `/gm`, invisible, warning NOTICEs, mutes in
`ChatRouter`, ignore filter, report ring, chat and audit batches); `reapply-purges` and the rest of the retention jobs
(P9a); `admin maintenance` (TEC-28); `dev.sh` with `bootstrap` and `create-account` (P9b).

### 19.6 What progression.md P3 brings

progression.md P3 (its §19.4) adds its sections to `progression_rules.json` and starts `internal/progress`:

- **`progression_rules.json`** already has `races`, `appearance`, `level_curve`, `currencies`, `reasons`,
  `containers` and `combat`. `internal/gamedata` does not change (it still only looks at `protocol_version` and
  `names`) and its tests keep passing. `items` (progression.md P1) and `starter_templates` (abilities.md's templates,
  which are not yet on this branch) are missing.
- **`progress.LoadRules(gamedata.Raw())`** reads and checks those sections and gives `ValidAppearance(realm, raceID,
  [8]byte)`, the rule of §4.4 step 5 for appearance, with the shared cases
  (`tests/fixtures/progression/appearance_cases.json`). `*progress.Rules` does not yet implement `CreateValidator`
  (the templates are missing): `serve` stays with `ProvisionalValidator` until progression.md P7, and nothing in `cmd/`
  changes.
- **For P7:** the `internal/characters` tests create characters with 8 B that are not valid under the real rules
  (`appearance` in `harness_test.go`: head 2, no beard in Vardheim and marks 2). When replacing `progressStore()` with
  `*progress.Rules`, they must be given one that is valid for each realm, like those in the shared cases
  (`AQAAAQEDAgE=` in Vardheim, `AgAAAAAHAAA=` in Solmarch).

### 19.7 Implementation review

A review with three approaches (security, correctness and tests) over P0–P7a and progression.md P3 (de72147) left 14
findings, all confirmed with probes. Each one is fixed with a test that failed before the fix; for the coverage ones,
with the mutation the finding let through, which now fails. Five were gaps in this document, which is corrected where
applicable: §2.3, §2.5, §2.6, §4.2, §4.3, §5.3, §6, §7.3, §9.5, §17 (and progression.md §13.1, likewise) and §18.

| Finding | Severity | What it was | What was done | Test |
|---|---|---|---|---|
| Chained `revert_email` | high | With A→B→C, the `revert_email` that arrived at B lived 7 days: after the owner recovered the account with theirs, the thief reverted to B, left the account without a password and received the recovery. A gap in §4.3 ("they only expire") | Spending one voids the account's later-issued ones (`invalidateLaterReverts`, by `created_at`). A new `revert_email`'s goes at least 1 µs after the account's previous one (`revertCreatedAt`): no ties even if the clock repeats or goes back. §4.3 | `TestRevertEmailChain`: the owner first, B's gives `used`; the thief first, the owner's remains valid and the recovery that reached the thief dies |
| Race in `CheckPassword` | high | The throttle was checked with one lock and the failure recorded with another after argon2: simultaneous attempts all passed, and the 30 s throttle and the group's 15 min lockout admitted bursts | One turn per account key (`failureTracker.turn`: a capacity-1 channel, outside the LRU so it is not evicted in use, which respects the context). Throttle, query, argon2 and recording go together; distinct keys do not wait for each other. The `login_failures` email and the hash rewrite already go out without the turn. §4.2 | `TestConcurrentAttemptsRespectTheThrottle`: after 5 failures and 31 s, 30 at once from 30 IPs give 1×401 and 29×429 (before, 22×401); 10 at once from one group, 5 and 5 (before, 8 or 9×401); the same with an email without an account |
| Old email taken | medium | After A→B, a `POST /v1/accounts` with A (unauthenticated, 202) created an unverified account with A, and the owner's `revert_email` gave `token=unavailable` until it expired (the purge of unverified accounts comes later) | The email of a live `revert_email` stays reserved (`emailReserved`): registration and another account's email change treat it as one with an account (`register_existing`), a pending `change_email` from another account gives `unavailable` and `admin create-account`, `ErrEmailReserved`. No new index (below). §4.3 | `TestOldEmailIsReservedWhileRevertLives` (also with the `change_email` requested earlier and with the link already expired) and a case in `TestCreateAccountAndBootstrap` |
| The claim revealed sanctions | low | The 403 `account_blocked` (with `reason`, `until_unix` and the text) came before checking the world and the ticket: with an invented `ticket_id`, a zone read the sanctions and purge date of any character in any world. It was the order of §5.3 | The ticket is locked and validated first (`select … for update of t`); the 403 only comes with a valid ticket for that character and that instance, and the ticket is consumed afterwards. Same lock order: account → ticket → lease. §5.3 | `TestClaimRevealsNothingWithoutATicket`: invented ticket or another character's, account suspended, banned (other world) or with deletion requested give the same body as a character that does not exist |
| Timing oracle in `password-reset` | low | With an account, a write (and its fsync) was confirmed; without one, it was only read. With fsync, 572 µs versus 202 µs median, without overlap | The response does not wait for the database: after validating and spending the email limit, looking up the account, storing the link and sending it continue in the background (`Service.Wait`, which `serve` calls on stopping before closing the mail queue and the harness after each request). Both paths leave their `password_reset` row in `auth_events` (without an account, null `account_id`). A database failure no longer gives 503: it is logged. §4.2, §4.3 | `TestPasswordResetWritesEitherWay`: both rows, and with the `accounts` table locked the response comes back the same |
| The heartbeat resurrected leases | medium | It renewed an expired lease that the claim, `enter` and deletion already considered free: two characters of one account in the world, or a deleted one inside. Only `zones_lost` arriving before the TTL prevented it, and the configuration admitted 10/20. The startup grace period also extended those that had expired before the crash. It was §5.3's SQL and §2.5's rule | The heartbeat renews only `expires_at > now` (the rest, `lease_lost`). `config.Load` requires `LEASE_TTL_S > 3 × HEARTBEAT_S + min(5 s, HEARTBEAT_S)` (`Config.LostDetected`; `zones.LostAfter` and `LostEvery` come from `config`). The grace period extends only the leases of `starting` and `live` instances with `expires_at ≥ last_heartbeat_at`, before bumping the heartbeat. §2.3, §2.5, §5.3 | `TestLateHeartbeatDoesNotRenewExpiredLeases` (also with deletion), `TestLeaseTTLCoversLostInstances` and a case in `TestStartupGrace` |
| Data the database rejects brought down batches | medium | `InsertEach` only isolated class 23: a NUL in `args`, broken UTF-8 or an out-of-range date gave 500 for the whole batch, and the zone retried it endlessly (audit and war are never discarded) | `db.KindData` (class 22) and `db.Deterministic`, which `InsertEach` isolates per row like 23. `zones.IsJSONObject` (UTF-8, without `\u0000` or lone surrogates) on `args`, `context` and `record`; dates up to `zones.MaxUnix` (253402300799) in chat, audit, war and a report's evidence. A class 22 error that reaches the response is 400 `validation` in the internal API (`zones.Fail`) and `invalid_save` S8 in the save (`SaveError`). §6, §7.3, §17 | `TestAuditBatch`, `TestChatBatch`, `TestWarEvents`, `TestReportLimits`, `TestFortresses`, `TestInsertEachIsolatesTheBadRow`, `TestIsJSONObject`, `TestFailDataErrorIs400` and three cases in `TestClassifyRealErrors` |
| pvp totals above `int4` | low | `kills`, `deaths`, `assists`, `captures` and `defend_s` are `int`: a total above 2^31 − 1 could not be encoded, gave 500 and the zone retried that save (or batch) forever | `ParseEnvelope` caps them at 2^31 − 1 (`envelope`, definitive); `gate_damage`, `bigint`, still goes up to 2^53 − 1. §7.3 | `TestEnvelopeErrors`, `TestSavePvP` (each column's cap is accepted) and `TestSaveMany` |
| Lost warnings | low | The claim wrote `last_entered_at`: if the zone dropped the character without letting it in (`REALM`, `FULL`, `prepare` or the drop in `LOADING`), the warning was left seen without a NOTICE | It is written by the lease's first applied save (`last_seq` 0), with its `claimed_at`: a warning set between the claim and that save comes out in the next one. §9.5 and §19.5 | `TestWarningSurvivesARejectedEntry`; `TestClaim` and `TestWarningIsShownOnce`, whose exit is now a final save |
| Refresh in the heartbeat, untested | medium | `TestHeartbeatRevocations` refreshed another session and removed the revocations by hand: "the heartbeat kicks a rotated session" or "refresh revokes its row" passed the whole suite | `Player.Refresh` and `Platform.RefreshSession` in `platformtest`; the test refreshes the ticket's session twice and checks that the lease remains tied to it | Both mutations fail |
| `zones_lost` in `serve`, untested | low | Removing `AddJob("zones_lost", …)` left everything green (§19.4 gave it as "unverified") | `TestServeRunsTheLostInstances`: `serve` with `HEARTBEAT_S` 1 and `LEASE_TTL_S` 5; the instance becomes `lost` and the lease is freed in about 4 s | The mutation fails |
| `TestAuditBatch` and S8's row | low | S8's row had another key: an `on conflict do update` that overwrote it passed | The prior row with the same `op:<op_id>` and other fields; it stays intact after the batch and the resend, and does not go to `rejected` | The mutation fails |
| STARTTLS, untested | low | The test only looked at `isLoopback`; without `deliver`'s guard, the email (with single-use links) went out in the clear | `SMTPSender.dial` is injectable (by default `net.Dialer.DialContext`; `smtps` does the TLS handshake over that connection). The test sends to `smtp.example.org`, diverted to the fake server: "el servidor SMTP no ofrece STARTTLS" (the SMTP server does not offer STARTTLS) and neither `MAIL FROM`, nor `RCPT`, nor `DATA`; with `smtps`, neither | The mutation fails |
| `testdb` left the server alive | low | A panic, `go test`'s timeout or a Ctrl-C left the postmaster and its folder until another run with the same `TMPDIR` | One watchdog per cluster (`watchdog_unix.go`, before `initdb`): a `sh` in its own process group with its input on a pipe that only the test process has open; if it closes without "done", `pg_ctl stop -m immediate` and `rm -rf`. Outside Unix there is no watchdog (`reapStale` remains). §2.6 | `TestClusterDiesWithTheProcess`: a child that panics; its cluster disappears in under a second (without the watchdog, it is still there after 15 s) |

**Fix decisions:**

- **A per-account turn** (the finding's option B) rather than reserving in-flight attempts: it counts exactly and is
  short. The cost is that attempts on the same account wait for the previous one's argon2; a burst against a throttled
  account comes out at once with 429 (the throttle is checked with the turn and without argon2), so the owner waits at
  most a few computations.
- **`password-reset` in the background** and not a filler job: writing on both paths still left 519 µs versus 406 µs
  (the link's foreign key and the row with an account), with overlapping but distinguishable distributions. The
  goroutine uses the request's context without cancellation, with a 30 s deadline, and logs the failure with the
  request id.
- **No index for the email reservation:** `account_tokens` is small (what has expired is deleted after 7 days, §11.1),
  and a new migration would take number 0007, which §2.4 leaves unused in phase 5. If it grows, the partial index
  `(email) where purpose = 'revert_email' and used_at is null` goes in the next migration.
- **The startup grace period no longer extends a `replaced` instance's leases:** they expire with their TTL, as §5.3
  says; its final save is valid as long as nobody claims the character.
- **The order of `revert_email`s** goes by `created_at` (the table has no sequential id) with the 1 µs nudge, instead
  of a new column.

**Measured** (this machine, 4 cores, Go 1.24.7, PostgreSQL 16.15):

| What | Result |
|---|---|
| `go test -race -count=1 ./...` | 33 s, no races |
| `go test -p 2 -count=1 ./...` | 37 s; the previous commit, on the same machine and at the same time, 34 s (the two new tests that really wait, `serve` with `zones_lost` and `testdb`'s child, add about 7 s) |
| The new accounts tests, 10 times in a row | No failures; the simultaneous attempts one, also with `-race` and production argon2 (3 of 3) |
| `password-reset`, median of 200 pairs with and without an account (server with fsync) | Before, 572 µs and 202 µs; writing on both paths, 519 and 406 µs; in the background, 2.5 and 2.4 µs |
| Binary | 20.5 MB |

Godot: `--import` gives the same log as before (the usual leaks on exit); `test_export_config` (10),
`test_architecture` (19), `test_progression_rules_export` (10) and `test_name_rules` (12) pass. Outside `platform/`
only documentation changes.

**Unverified:** `testdb`'s watchdog outside Linux (it uses `sh` and `Setpgid`, which macOS also has); the email
reservation with a large `account_tokens`; sending with a real SMTP server (STARTTLS is still tested with the fake).

### 19.8 P4 · ticket in the zone (TEC-24)

**What exists.** The zone side of §5 and §6: the ticket, the claim before WELCOME, `ZonePlatform` with its HTTP client
and protocol 7. Without `--platform` everything stays as before (`DevAuthProvider`, ephemeral characters):

| Piece | Content |
|---|---|
| `scripts/server/platform/` | `HandoffTicket` (§5.1: `decode`, constant-time `verify`, `sign`, `zone_key_of`), `TicketAuthProvider` (the five steps of §5.2 and the claim response table), `ZonePlatform` (startup of §8, heartbeat with its set, fencing, clock, claim, release, save, blocks, fortresses, batches, `request` and the `kind`s of `PlatformEvent`), `PlatformClient` (the slots and priorities of §6 with each class's retries), `PlatformEvent`, `ClaimedCharacter`, `AuthOutcome` and `PlatformJson` (ids from 0 to 2^63 − 1 and exact integers, like `jsonx`) |
| `auth_provider.gd` · `dev_auth_provider.gd` · `server_auth.gd` | The API of §14.3 (`PENDING`, `authenticate(peer_id, hello)`, `on_platform_event`, `take_completed`, `cancel`, `uses_tickets`); `validate(peer_id, …)`, which with tickets does not look at the realm or name (no `REJECT NAME` or `IMBALANCE`) |
| `server_peer.gd` | `State.VERIFYING`, `connected_at_msec` (real time), `character_id`, `claimed` and `drop_body_at_once` |
| `zone_server.gd` | `start(…, platform)`; in "poll", events by `kind` (`claim` to the provider, `heartbeat` to the zone, `instance_closed` last, as the `instance_closed` signal), the finals (realm → capacity → WELCOME with the character's realm and name) and the `VERIFYING` ones expired at 7 s; `get_player_count()` with `VERIFYING`; drops in `VERIFYING` (`cancel`) and in `LOADING` (`release`); the heartbeat's `revoked`; the staff bit in the SPAWN; the cooldown by `character:<id>`; the metrics' `platform` section |
| `server_config.gd` · `server_main.gd` | `--platform`, `--world`, `--channel`, `--public-address`, `--save-interval`, `--replace`, `--dtls-cert`, `--dtls-key` and `platform_dev_options()`; with the platform, the environment's secrets, startup, `TicketAuthProvider`, `go_live`, exit with code 1 (startup) or 3 (`instance_closed`) and, on shutdown, what is pending and the deregistration |
| Protocol 7 | `PROTOCOL_VERSION = 7` with the whole line of §5.4, REJECT 10–12 with their texts, `NetTransport.AUTH_TIMEOUT_SECONDS = 10.0`, bit 3 of the ENTITY_SPAWN header's `flags` (`NetMessages.SPAWN_FLAG_STAFF`, `EntitySpawn.is_staff`, `NetEntity.is_staff`); `progression_rules.json` re-exported with `protocol_version` 7; networking.md with its "v7" marks |
| Tests | `tests/fake_zone_platform.gd` (`FakeZonePlatform`, the API of §14.3) and `tests/support/fake_http_server.gd` (`FakeHttpServer`, a `TCPServer` with scripted responses and delays) |

**For the following packages.**

- **progression.md P4:** the version is already 7 and the `net_protocol.gd` line already names its part; it adds its
  code without bumping it and its "v7" rows in networking.md (the legend of §5.2 is already there).
- **P5:** `CharacterSaver` calls `ZonePlatform.save(character_id, lease_id, bytes, release_lease, context)`; the
  definitive response comes out as a `save` event (the `match` in `_poll_platform` leaves room for it) and takes the
  character out of the heartbeat if it carried `release_lease`. Until then, **provisional**: whoever leaves the world
  releases their lease
  when the body leaves (`_claims_by_net`, in `_remove_player`, also after combat logout and in `_clear_players`); a
  `revoked` that is not `lease_lost` kicks with its NOTICE and without a final save; `instance_closed` closes like any
  other shutdown and exits with code 3 (the shutdown of §6.1, with final saves first and its NOTICE, belongs to P5);
  the heartbeat's `maintenance` is not looked at; `SHUTDOWN_MAX_FRAMES` stays at 90 and `_drain_platform` waits for
  `is_flushed()` at most that long before and after deregistration.
- **progression.md P5a:** step (3) of `_apply_auth_outcome` is the place for `ProgressService.prepare` and
  `_leave_auth_states` (LOADING) the one for `cancel_prepared`; `ZonePlatform.RECORD_FORMAT` already exists; in
  `FakeZonePlatform`, `_claim_answer` and `_remember_save` are where the `progress` part and `claim_progress` go in.
- **P6:** `ZonePlatform.fortress_records()` brings the startup GET's data (`{fortress_id, record, version}`), which
  `ZoneServer.start` does not apply yet; `put_fortress` already carries one in flight per fortress with
  `expected_version` and the resend after `version_conflict`; the fake has `fake_fortresses`.
- **P7b:** `ClaimedCharacter` brings `role`, `muted_until_unix`, `ignored_accounts` and `warnings`; `ServerPeer.claimed`
  stays set in the world; the heartbeat's `mutes` have no consumer; `enqueue_batch` and `request` already exist.
- **P9c:** registration sends `dtls_cert_pem` and `dtls_name` as null: Godot's `X509Certificate` does not give the CN,
  so P9c will have to read it from the DER or ask for `--dtls-name`.

**Deviations and implementation decisions:**

- **Retries live in `PlatformClient`** and the transport of one attempt is a separate method (`_perform`): the real
  `HTTPRequest` or, in `FakeZonePlatform`, a `FakeClient` that answers without a network. This way the fake runs all of
  `ZonePlatform`'s logic (heartbeat set, `instance_closed`, retries, batches) and only the wire changes; its retries go
  20 times faster (`fake_retry_scale` 0.05).
- **Extra API in `ZonePlatform`** (§14.3 does not name it): the `fatal_error` signal (`live` exhausted),
  `deregister()` (the deregistration), `get_client()`, `heartbeat_set()`, `heartbeat_interval_s()`,
  `send_heartbeat_now()`, `log_sink`, `player_count_source` and the statics `read_secrets()`, `parse_ticket_keys()`,
  `env_guard_error()`, `registration_body()`, `build_id()` and `describe()`. The request classes of its own, which do
  not come out as an event: `register`, `live`, `fortresses`, `release`, `stop` and the batches (`chat`, `audit`,
  `war`).
- **Step 2 of §8 is done by `ZonePlatform`**, after registration: with an `env` of `staging` or `production` and any
  development option, or with the vector key of §5.1 outside `test` (the rule of §2.3 in the zone), it deregisters and
  emits `startup_finished(false, reason)`; `ServerMain` empties the queue and exits with code 1.
- **`ClaimedCharacter`** adds `instance_status` and `warnings` (the `account.warnings` of §19.5) to the fields of §14.3
  and `is_staff()`. A body that is not understood is `UNAVAILABLE` with an alert, and the `lease_id` it carries is
  released.
- **`FakeZonePlatform`:** `script_next(kind, status, FakeZonePlatform.DEFAULT, delay_s)` answers the default with that
  status and delay; `add_character` admits a `display_name` at the end (§14.3 does not give the name; without it,
  `NameRules.bot_name(id)`); `fake_heartbeat_s` (1 s), `fake_now_unix`, `fake_fortresses`; a GET's `sent()` is
  `{"path": …}`; `ignore`, `report` and `sanction` give 404 by default, like `progress_op`.
- **The heartbeat:** only 200s come out as a `heartbeat` event; a `lease_lost` `revoked` takes the character out of the
  set (otherwise heartbeats would be sent for it forever); `players` is `get_player_count()` (with `VERIFYING` and the
  fakes); the zone is fenced before registration too.
- **Drops:** that of `VERIFYING` and that of `LOADING` are done in `_mark_leaving`, which all go through (disconnection,
  CLIENT_LEAVE, kick, REJECT, load deadline), and in `stop()`. A `lease_lost` releases nothing and removes the body at
  once (`drop_body_at_once`), also in `LOADING` (§6 says "without release").
- **With the platform, `--max-realm-diff` does not apply** (§5.4): `ServerAuth` gives no `IMBALANCE` with tickets and
  `ServerMain` does not create filler fakes (it says so in the log).
- **REJECT:** the report counts rejections by the text from `result_text`, not by the code itself (`BANNED`'s carries
  each account's reason); a HELLO without a ticket receives `TICKET` with "Entra desde el menú con tu cuenta". WELCOME
  carries the configuration's `channel` (previously, always 0).
- **`build_id`** of the registration: `eldmark-<project version>-p<protocol>`.
- **`FakeHttpServer`** answers with `Connection: close` and discards the response if the client has already cut off
  (expired deadline): it does not write to a closed socket.

**Tests** (Godot): `test_handoff_ticket.gd` (15: Go's vectors, the fingerprints, the 9 invalid ones, and
`TicketAuthProvider` with altered signature, unknown key, no ticket, another zone, world or channel, expired and the
5 s skew on both sides, reused within 30 s, another character, fenced zone, the claim response table, the 200 that
arrives late and is released, a body that is not understood, `from_claim` with ids above 2^53 and broken bodies,
`ELDMARK_TICKET_KEYS` and the `env` guard, and the fake that returns the applied `pvp` and raises the blocks);
`test_zone_server_platform.gd` (13, with ENet: ticket → `VERIFYING` → WELCOME with the character's realm and name, the
`ticket_id` > 2^53 in the claim and the staff bit; no ticket → `TICKET`; capacity of 4 with 5 in `VERIFYING` → `FULL`;
HELLO at 1.4 s with the claim at 5 s → WELCOME; silent platform → `UNAVAILABLE` at 7 s and release of the one that
arrives late; fenced zone; drops in `VERIFYING` and in `LOADING`; `revoked` in `LOADING`; in the world, an old
`lease_id` does not kick, the current one does and `lease_lost` does not release; `BUSY` and `BANNED` on suspension,
ban and pending deletion; `test_hello_cannot_probe_an_enemy_name`; `--debug-commands` with `production`);
`test_platform_client.gd` (14, with `FakeHttpServer`: startup, expired deadline and retry with the same bytes, the
claim without a retry, the heartbeat and the claim with four slow saves in flight, priority order, 204, empty, broken
and non-UTF-8 → `body` null without engine errors, `zone_instance_id` and `key`, the heartbeat set, a single
`instance_closed`, the release with 403 that is not repeated and with 503 that is, the registration that retries every
2 s on `instance_alive`, and the real zone server in another process: registration, fortresses, block, `live`,
heartbeats and deregistration with code 0, and with `production` and `--debug-commands`, deregistration and code 1);
plus two in `test_net_messages.gd` (REJECT 10–12 and bit 3), one in `test_server_auth.gd` and another in
`test_server_config.gd`. Go: the whole suite passes with `protocol_version` 7 (`internal/gamedata` compares it with
`net_protocol.gd`); the `ticket_id` > 2^53 in the claim was already tested by P3 (`TestClaimBigTicketID`).

**Measured** (this machine, 4 cores, Godot 4.7.2):

| What | Result |
|---|---|
| `test_zone_server_platform.gd` | 32 s for the 13; the late HELLO one, 6.6 s (WELCOME at ~6.4 s from the connection) and the silent platform one, 8.1 s (REJECT at ~7.0 s) |
| `test_platform_client.gd` | 26 s for the 14; the zone process with `--platform`, 3.1 s from startup to deregistration, and the `production` one, 1.9 s |
| `test_handoff_ticket.gd` | 15 tests in under 1 s (not counting the runner's loading) |

**Unverified:** against the real Go platform (P10; here, the fake and `FakeHttpServer` with the routes and bodies of
§6); `PlatformClient` with hundreds of characters in the heartbeat and full batches; DTLS (P9c).

**Left for later:** `CharacterSaver` and the shutdown of §6.1 (P5); `prepare` and the `progress` section (progression.md
P5a); the loaded fortresses and the `pvp` section (P6); mutes, warnings, `/gm` and chat and audit batches (P7b);
`NetClient` with a ticket and `AccountFlow` (P8); DTLS (P9c); the end-to-end test (P10).

### 19.9 P5 · saving in the zone (TEC-25)

**What exists.** `CharacterSaver` and what surrounds it in the zone (§7.2, §7.3 and the shutdown of §6.1). Without
`--platform` nothing changes: there is no `CharacterSaver` and characters are still ephemeral (progression.md §9.4).

| Piece | Content |
|---|---|
| `scripts/server/platform/character_saver.gd` | `CharacterSaver` of §14.3: sections in the order they are registered (one with the same name replaces the previous one); entries by `lease_id` with the indexes `character_id` → `lease_id` and, until `finish` or `drop`, `net_id` → `lease_id`; the whole envelope of §7.3 serialized once; the checkpoint in the character's phase (`tick % interval == character_id % interval`) only with a dirty section; criticals in the first `step` with nothing in flight; one write in flight; the final save built in `finish`, which waits behind the one in flight; `drop`; the response table of §7.3 and `save_rejected`. In addition, `pending_count`, `tracked_net_ids`, `is_tracked`, `net_id_of`, `lease_of`, `entry_count`, `section_names`, `interval_ticks`, `get_stats` and `log_sink` |
| `zone_server.gd` | With the platform, `CharacterSaver` (every `--save-interval` × 60 ticks) and `get_saver()`. `track` as soon as the entity exists; `step(s)` after "spawns"; `save` events in "poll". The "Exit" in `_remove_player`: `finish` before `ScoreKeeper.forget`, also when the body of a combat logout is removed. The drop without saving: `_on_save_rejected` and the `lease_lost` `revoked`, also for the body that stays. The other `revoked`, with a final save. The countdown for the heartbeat's `maintenance`. `stop()` with everyone's final saves and the wait; `close_instance(code)`, the shutdown of §6.1. `saves` in the report |
| `server_peer.gd` · `server_main.gd` | `ServerPeer.kicked` (reason 5 of the final save). `SHUTDOWN_MAX_FRAMES` 720; `instance_closed` → `close_instance` and exit with code 3 |
| Tests | `tests/support/fake_save_section.gd` (`FakeSaveSection`, the fake section shaped like `pvp`, which `FakeZonePlatform` returns in the next claim), `tests/support/raw_ticket_client.gd` (`RawTicketClient`, the ticket client that used to live inside `test_zone_server_platform.gd`) and `FakeZonePlatform.fake_maintenance` (the `maintenance` of the default heartbeats) |

**For the following packages.**

- **progression.md P5a:** `ProgressService.setup` registers `&"progress"` with `zone.get_saver().register_section(…)`
  **first** (it is the only one that can return `{}`, and `CharacterSaver` does not undo what an earlier section has
  built in that attempt). `on_arrival` goes after `track` in `_process_arrivals` (the slot is already there), and a
  `mark_critical(net_id, &"starter_kit")` made there goes out in that same tick's `step`. `on_departure(net_id)` goes
  in `_remove_player` right after `_scores.forget(net_id)`: the "Exit", the body removed after a combat logout and the
  drop without saving all pass through there, whose `finish` no longer does anything after the `drop`. In both
  shutdowns, `_wind_down` does the `finish`es before `_clear_players()`. While there is no section, `CharacterSaver`
  releases without saving (below). In `FakeZonePlatform`, the `progress` part of what is applied is stored in
  `_remember_save` (called by `_answer` with each 200 `applied`).
- **P6:** `ScoreKeeper` registers `&"pvp"`. P5's tests later register their `FakeSaveSection` with that same name, which
  replaces the real one: they stay valid without touching them.
- **P7b and progression.md P5d:** with the zone fenced, `mark_critical` and saves keep going out; rejecting the commands
  that ask for a critical save is theirs.
- **P10:** `--save-interval=5` gives checkpoints every 300 ticks; `kill -9` loses what came after the last applied one.

**Deviations and implementation decisions:**

- **Without sections there is nothing to save.** Until progression.md P5a (`progress`) and P6 (`pvp`) the zone registers
  none, and the platform requires `progress` (an envelope without it is `invalid_save` `envelope`). So, without
  sections, the checkpoint is never dirty, a critical save sends nothing and `finish` releases without saving: against
  the real platform the zone does the same as in P4 (`_claims_by_net`, which disappears).
- **The shutdown of §6.1 is `ZoneServer.close_instance(code)`** (§14.3 only named `ServerMain`). Those in
  AUTHENTICATING and VERIFYING receive REJECT `UNAVAILABLE` (they cannot receive a NOTICE yet) and those in LOADING are
  released. Then everyone's final saves go out with reason 4 and the zone waits, at most `save_drain_ticks` (600). Only
  then does it send the kick NOTICE (code 1) to everyone. `ServerMain._shutdown` receives the code and picks
  `close_instance` instead of `stop`.
- **The wait lives in `ZoneServer`.** `_drain_stop` polls the network and the platform until `pending_count()` is 0 and
  `is_flushed()` (or 600 ticks pass) and the peers have left (or 30 ticks pass since their NOTICE). During that time
  it handles the responses to saves and the claims that arrive late, which are released; the heartbeat no longer kicks
  or warns. `stop()` with no peers and nothing pending still ends at once, so tests without the platform do not change.
  `ServerMain` then waits, as before, for `is_flushed()` and for the deregistration.
- **A shutdown in the middle of a tick cuts the tick short.** `instance_closed` (in "poll"), the console's countdown
  or the maintenance one can close the server inside the tick. From there, the rest of the tick does not run on the
  already emptied world.
- **Final save reason:** 3 (exit); 5 if the zone kicked the player (`ServerPeer.kicked`: warnings, console,
  `revoked`, load deadline); 4 in both shutdowns. The body that remains after a combat logout keeps the reason until
  it is removed.
- **A 409 `instance_*` on a save** does not blame the player. The platform does not give it: saves are valid in any
  state and the shutdown arrives in `instance_status`. If it arrives anyway, the same body is resent up to 3 times
  (`MAX_CLOSING_RESENDS`) and then it is definitive: a closed instance's final save is not lost because of this.
- **Release after what is in flight.** A final save that cannot be built and the drop without saving release when the
  in-flight save, if there is one, has a response: otherwise another zone could claim and load the state from before
  that save. After a `lease_lost` (from the heartbeat, a save or in `drop`), that entry never releases again.
- **`save_rejected` without a drop:** if nobody calls `drop` on receiving it, `CharacterSaver` does it itself, and the
  entry is not left tied to a body that no longer saves. A `track` on a `net_id` that still had an entry (the zone
  called neither `finish` nor `drop`) releases the old one with `drop` and an alert.
- **Alerts:** they go to the log and also with `push_warning`. They are a save's definitive response (with the
  `check` and `detail` of an `invalid_save`), the final save that could not be built and a `track` that does not add
  up. The test runner does not count WARNINGs as failures.
- **Texts.** The drop without saving sends "No se ha podido guardar tu personaje; vuelve a entrar" and a save's
  `lease_lost`, "Tu personaje ha entrado en otro servidor"; that of a `revoked` carries the platform's `text`.
  Maintenance says "El servidor se cerrará por mantenimiento en 10 min: <message>" (the server will shut down for
  maintenance in 10 min; minutes rounded up from 60 s). Warnings that have already passed when the announcement
  arrives are merged into one with what remains. A `maintenance` that goes back to null after some warning gives
  "Mantenimiento cancelado: el servidor sigue abierto" (maintenance cancelled: the server stays open), and one whose
  time has already arrived does not fire again even if the heartbeat repeats it. The time is
  `ZonePlatform.now_unix()`.
- **The five triggers with the real process** (`--platform` against `FakeHttpServer`): since the zone has no sections
  yet, what they wait for is each one's release, also that of the final save of whoever is in the world. Real saves
  with their wait are tested in the test process, with `FakeSaveSection`.

**Tests** (Godot):

- **`test_character_saver.gd`** (14, no network, with `FakeZonePlatform`): the checkpoint in its phase and only with
  something dirty (three characters, interval of 120 ticks); the critical save at once, also right after `track`; one
  write in flight; the final save that waits behind the one in flight without being rebuilt; the whole envelope (with
  a `character_id` > 2^53) and the same body on retries; `duplicate` as applied; a section that returns `{}` without
  spending `seq`. In addition: the final save that cannot be built, without sections, eight definitive responses
  before `finish` (`invalid_save`, `stale_seq`, `seq_conflict`, 403, 413, 404, an unknown 409 and `lease_lost`, this
  one without releasing) and the drop it does on its own; the 409 `instance_*` with their cap; after `finish`, a
  definitive response that is only logged and releases; a reused `net_id` with the previous one's final save in
  flight; the same character coming back while its final save is retried.
- **`test_zone_server_saves.gd`** (10, with ENet): the spawn's critical save in the spawn tick and checkpoints in
  their phase; the combat logout that saves when the body leaves; the drop without saving (an `invalid_save` in combat:
  the body out at once, one release, the "Exit" with nothing and the section with no further calls; and a
  `lease_lost` `revoked` in combat, without releasing); a `revoked` with a final save and reason 5. The shutdown of
  §6.1 with `instance_lost` in the heartbeat and with `instance_replaced` in a save's `instance_status`: the final
  saves before the NOTICE, the release of the one in LOADING, and whoever re-enters loads their final save. The
  orderly shutdown waits for the final save's response at 2 s and releases those in LOADING and VERIFYING.
  `maintenance` gives the five warnings, the shutdown and the cancellation. Reconnection brings the last applied value,
  and the same character returns while its final save is retried.
- **`test_zone_process_shutdown.gd`** (5, the zone server in another process): `--stop-file`, `--quit-after-ticks`,
  `--idle-quit`, the console's `shutdown` (with `--run-at`) and `maintenance`. In each, the instance's deregistration
  arrives after the last response (at 2 s) for whatever remained of each (in the world, in LOADING and in VERIFYING),
  with code 0 and no errors.

`test_zone_server_platform.gd` (13) passes the same with `RawTicketClient`. Checked with the mutation they should
catch: without `_drain_stop`'s wait the orderly shutdown and the two of §6.1 fail, and with `SHUTDOWN_MAX_FRAMES` at
90 and the zone's wait at 30 ticks the `--stop-file` one fails.

**Measured** (this machine, 4 cores, Godot 4.7.2 headless):

| What | Result |
|---|---|
| `test_character_saver.gd` | 14 tests in 3.9 s (the slowest, 1.1 s: eight responses with their waits) |
| `test_zone_server_saves.gd` | 10 tests in 11.7 s; the orderly shutdown one, 2.3 s (it ends after the final save's response, 2 s after `stop`) |
| `test_zone_process_shutdown.gd` | 5 tests in 35 s: 5 to 8 s each, with the process startup |
| `CharacterSaver.step` with 64 bodies and nothing to save | 0.4 µs per tick: it only looks at the tick's phase and the pending ones (walking the 64 entries every tick cost ~40 µs) |
| `JSON.stringify` of a large character's envelope (120 objects and 256 operations, 89 KB) | 3.7–4.6 ms (with other load on the machine) |

**Unverified:** against the real Go platform (P10); with hundreds of characters and the real `progress` section
(progression.md P5a), whose `JSON.stringify` is the expensive part of saving (above): with 64 players one comes out per
second and within the tick.

**Left for later:** the `progress` (progression.md P5a) and `pvp` (P6) sections; rejecting, with the zone fenced, the
commands that ask for a critical save (progression.md P5d, P7b); the end-to-end `kill -9` (P10); the `maintenance` that
`admin maintenance` sets on the platform (TEC-28).

### 19.10 What progression.md P5a leaves

progression.md P5a (its §19.11) registers the `progress` section and prepares the record before WELCOME. What changes
here:

- **There is always a section.** `ZoneServer.start` creates `ProgressService`, which registers `progress` first; with
  the platform, every final save carries the save and releases with `release_lease` (the release without saving of
  §19.9 remains for the drop in LOADING, the drop without saving and a final save that cannot be built). A new
  character's first save is the kit's critical save, in the tick of its spawn.
- **`prepare` in step (3).** A record that cannot be read gives REJECT `UNAVAILABLE` with "No se ha podido cargar el
  personaje", an alert and the release; the drop in LOADING calls `cancel_prepared`.
- **`FakeZonePlatform`:** the `progress` part of the next claim (§14.1), `claim_progress` and
  `default_progress(realm)`; `add_character` with an empty `progress` gives a newly created character of its realm
  (before, a `{}` that `prepare` would now reject).
- **Tests here adjusted:** `test_zone_server_saves` counts saves from after the kit; `test_zone_server_platform`, in
  `test_revoked_in_the_world_only_with_the_current_lease`, waits for the final save with `release_lease` instead of
  the release; `test_zone_process_shutdown` claims with `default_progress` and counts as the release of whoever was in
  the world their final save with `release_lease` (answered with the same delay).
- **P6:** `pvp` is registered after `progress`. **P10:** end-to-end saves already carry the `progress` section (with
  the real store, progression.md P7).

### 19.11 P6 · war (GUE-19)

**What exists.** Persistent war in the zone (§8): each fortress's record on the platform, its loading at startup, the
history, per-character captures and defending time and the `pvp` section of saves. Without `--platform` there is no
`FortressPersistence` or `pvp` section; the scoreboard, captures and the forced-change flag work the same in memory.

| Piece | Content |
|---|---|
| `scripts/server/war/fortress_persistence.gd` | `FortressPersistence`: the record of §8 (`to_record`, `from_record` with its `Loaded` and the reason if invalid), ticks and Unix time (`unix_of` = `now_unix + ceili((t − tick) / 60.0)`; `tick_until` = `tick + max(0, at − now) · 60` for deadlines; `tick_since` = `tick − max(0, now − at) · 60` for the last reset, which is in the past), `load_records` (inside `ZoneServer.start`, before the port and the NPCs), `step` (change of owner, phase or cycle right away; the rest every 60 s), `flush` (orderly shutdown), `close` (shutdown of §6.1), `on_platform_event` (kind `fortress`), `on_war_event` (3, 6 and 7 to the `war` batch), `describe` and `get_stats` |
| `fortress_controller.gd` | `restore_state` (the loaded state, with the gate and what was sent brought up to date), `get_consolidation_end_tick`, the forced-change flag (`is_forced`), the capture list with the signal `fortress_captured(fortress_id, owner_realm, in_circle, tick)`, `captures` and `defend_ticks` in the `ScoreKeeper` and `PlayerCandidate.gm_forced` |
| `score_keeper.gd` | `Entry.captures`, `Entry.defend_ticks`, `add_capture`, `add_defend_ticks`; the `pvp` section: `SECTION`, `attach`, `load_totals` (the claim's base), `pvp_totals`, `build_section`, `acknowledge_section` and `is_section_dirty`, with the columns' caps |
| `net_entity.gd` | `gm_forced` (false by default) |
| `zone_server.gd` | `ScoreKeeper.attach` after `progress`; `FortressPersistence` in `start` (after creating the fortresses, before the NPCs and opening the port); its `step` after `FortressController.step`; `fortress` events in "poll"; `load_totals` at spawn, before `track`; respawning (RESPAWN) clears `gm_forced`; `_presence_candidates` with `gm_forced`; `flush` in `stop` and `close` in `close_instance`; `get_fortress_persistence()`; `war.persistence` in the report |
| `npc_spawner_system.gd` | The captain's post is not filled while the captain is down (a fort loaded in VULNERABLE or CAPTURING): he returns with the garrison or with the Hollow's full respawn |
| `zone_platform.gd` | `startup_limit_s` (60 s; tests lower it) |
| Tests | `tests/test_war_persistence.gd` (15) and `tests/test_war_platform_process.gd` (1, with Vado Gris in another process) |

**The record.** Schema 1 with the fields of §8. `phase_ends_at_unix` is the end of consolidation or, in VULNERABLE, the
captain's return; `captain_respawn_at_unix`, that return; both are null when no deadline is running. `capture_realm`
and `capture_progress` (the progress at the tick when it is written) only in CAPTURING. When reading, each field is
checked (exact integers, like `jsonx`; times, null or from 0 to 253402300799); one that is missing or does not add up
(CONSOLIDATING without an owner, CAPTURING without a capturer or with the owner as capturer) is treated as another
schema: the initial state with a warning. `captain_alive` is checked but comes from the phase. A gate health greater
than the definition's is clamped.

**When it is written.** What goes out right away: owner, phase, the phase's start and the last reset (a reset of a
neutral fort changes neither the owner nor the phase, but starts another 30 min cycle). What goes out every 60 s if it
changed: gate health, the captain, the capturer, the progress and the end of consolidation. Comparison is in ticks,
not Unix time, which moves with the clock. Only with the instance `live`: whatever changes before goes out once it is
live. The first startup (no record) writes the initial state as soon as the instance is live; an invalid record is
not overwritten until the first change, with the version the GET brought. The orderly shutdown writes whatever remains;
that of §6.1 writes nothing more (the one in charge is another instance).

**Deviations and implementation decisions:**

- **CAPTURING comes back as CAPTURING, not as VULNERABLE.** §8 says "`CAPTURING` comes back as `VULNERABLE` with its
  progress (the circle is empty and decays)", but in fortress.md §1.5's state machine a progress that decays on its own
  only exists in CAPTURING: in VULNERABLE the capture starts at 0. So it returns with its capturer and its progress,
  the circle empty (`empty_since_tick` at the load tick): it waits the `decay_after_empty_s` delay, decays at −4 and, if
  nobody returns, at 0 moves to VULNERABLE with a new deadline for the captain (the test checks it). If the capturers
  return, they continue from what is left; if another realm returns, what §1.5's table dictates.
- **The controller carries the end of consolidation.** `phase_tick` travels in OBJECT_STATE as a u32 and the start of a
  half-loaded consolidation would be negative: the state carries the load tick and `FortressController` stores the end
  (`restore_state`); at that tick it sets the start that makes `advance` close it, and the garrison arrives through
  `garrison_due`, as always. There are no changes in `scripts/shared`.
- **A damaged gate** is repaired `gate_repair_after_s` after startup (the time of the last hit is not stored).
  `under_attack_until_tick`, warnings and presence start from zero; `capture_rate_multiplier` (a debug command) is not
  stored.
- **Forced change** (progression.md §6.2; `is_forced`): the cycle is marked by `fort_owner`, `fort_reset`,
  `fort_kill_captain` (before killing, so the captain's death already comes out forced for whoever is paid for it) and
  `fort_capture_speed` with a factor other than 1; in addition, with `capture_rate_multiplier ≠ 1` everything is
  forced. The flag is cleared by the next real change: the captain's death in combat (or via `on_captain_died`), the
  garrison arriving on its own (end of consolidation or the captain's return) or the periodic reset. **Decision:** the
  capture that follows a `fort_kill_captain` is also forced, and so is the consolidation that follows a forced capture
  (until its garrison): "what a fort command causes pays nothing persistent", and without the command the circle would
  not have opened. In a forced cycle neither captures nor `defend_ticks` are added (`circle_ticks`, which belongs to the
  in-memory scoreboard, are). The flag is not stored: a restart loses it.
- **The capture list** is computed once, on the capture tick, with that tick's candidates (not the last recount, which
  can be up to 5 ticks old): of the capturing realm, present according to `FortressPresence` (alive, not knocked down,
  connected and with a recent entry) and without `gm_forced`. It adds `captures` and goes out through
  `fortress_captured`, sorted by `net_id`; a forced capture neither adds nor goes out. Invisible GMs will be removed
  from the candidates by P7b.
- **`defend_ticks`:** the owning realm (never the Hollow) present with the circle active, on each recount (6 ticks),
  without `gm_forced` and outside a forced cycle. `defend_s` = loaded + `defend_ticks / 60` (integer).
- **The `pvp` section** never returns `{}`; it is dirty while the totals are not those of the last confirmed body (or
  the loaded ones), so entering does not make it dirty. Each total is clamped to 2^31 − 1 (`gate_damage`, to 2^53 −
  1): a larger total would be `envelope` on the platform, and with `greatest` clamping lowers nothing.
- **History:** notices 3, 6 and 7 go to the `war` batch also when a command causes them (it is history, not reward),
  with the time from `ZonePlatform.now_unix()`. They are also sent before the instance is live (batches are valid in
  `starting`).
- **Extra API** (§14.3 does not detail it): `FortressPersistence.Loaded`, `describe`, `get_stats`, `flush` and
  `close`; `FortressController.restore_state`, `get_consolidation_end_tick`, `is_forced` and the signal
  `fortress_captured`; `ScoreKeeper.SECTION`, `attach`, `load_totals`, `pvp_totals` and the section's three functions;
  `ZoneServer.get_fortress_persistence()`; `ZonePlatform.startup_limit_s`.

**For the following packages.**

- **progression.md P5c:** `on_capture` connects to `FortressController.fortress_captured` (the same list that adds
  `ScoreKeeper.captures`; a forced capture does not go out). For `on_npc_killed` and objective merits,
  `FortressController.is_forced(fortress_id)` (the captain's death with `fort_kill_captain` already comes out forced)
  and each contributor's `NetEntity.gm_forced`.
- **P7b:** sets `NetEntity.gm_forced` (respawning already clears it) and removes invisible GMs from
  `ZoneServer._presence_candidates` (they do not count in the circle or the list).
- **P10:** restarting the zone with the real store (here, `FakeHttpServer` with versions like the platform).

**Tests** (Godot):

- **`test_war_persistence.gd`** (15, no network, with `FakeZonePlatform` and a fixed clock): the record's round trip
  (CONSOLIDATING at 50.5 s of 120 writes the end at 70 s and comes back at 60 s ten seconds later, through JSON;
  VULNERABLE with the captain's deadline, also one that has already passed; CAPTURING with its progress; GARRISONED
  without deadlines) and eight invalid records with their reason; starting with CONSOLIDATING halfway (owner, phase,
  gate, 60-tick deadline, Solmarch's gate, the fortress spawn being encoded, nothing written on load and the phase
  change's PUT with the GET's version and the previous last reset); CAPTURING that returns with its progress, waits
  for the delay and, with nobody, decays to VULNERABLE with a new deadline; capturers who return and finish from what
  was saved; the platform that does not answer the GET (startup fails after retrying, without a first block or PUT);
  the empty list (initial state without a warning, written once when live); another schema (initial state with a
  warning, not overwritten until a change, and then with the version that was there); `version_conflict` (resend of
  the same record with the error's version and the next one with the 200's); captures and `defend_ticks` (both
  capturers in the circle add, the flagged one and the one outside do not; the list goes out once; the owner defends
  with the circle active and the attacker does not; respawning clears `gm_forced`); captures forced by
  `fort_capture_speed`, `fort_owner` and `fort_kill_captain` against a real one, and the flag cleared by the garrison
  arriving on its own and by the captain's death in combat; the captain's death with `fort_kill_captain` that already
  comes out forced; the `pvp` section (the claim's base, the kit's critical save with `progress` and `pvp`, the
  session, the final save built before `forget`, reconnection that brings it and continues); the section clean after
  its `acknowledge` and the caps; and the event batch resent after a 503 with the same keys, only notices 3, 6 and 7.
- **`test_war_platform_process.gd`** (1, Vado Gris in another process against `FakeHttpServer`): a first process writes
  the initial state, the owner (`fort_owner solmarch` at tick 30) and the phase (`fort_kill_captain` at 60); a second
  starts with the platform not answering the fortresses GET twice: with it silent the UDP port stays closed, then it
  opens and it considers itself live, loads "owner Solmarch, phase vulnerable; the captain respawns in 292 s" and
  writes nothing (the saved owner is not overwritten).

In addition `test_fortress_*` (151), `test_npc_system`, `test_zone_server_saves` (its fake section is called `pvp` and
replaces the real one), `test_character_saver`, `test_zone_server_platform`, `test_zone_process_shutdown`,
`test_platform_client`, `test_progress_service`, `test_score*` and `test_architecture` remain correct. Checked with the
mutation they should catch: without the `gm_forced` filter in the list, without `load_totals` at spawn, with `forget`
before `finish`, without skipping forced captures, without the controller's end of consolidation, without clearing
`gm_forced` on respawn and without the `fort_kill_captain` flag before killing, they fail.

**Measured** (this machine, 4 shared cores, Godot 4.7.2 headless; costs, with a probe that is not committed):

| What | Result |
|---|---|
| `test_war_persistence.gd` | 15 tests in about 31 s with the runner's startup; the slowest, the forced captures one (6.4 s of 2-tick steps with frames in between) and the captures and `defend_ticks` one (3.9 s) |
| `test_war_platform_process.gd` | 14.4 s: two Vado Gris processes (the second waits 3 s of retries) |
| `FortressPersistence.step` with no changes (one fortress) | 1.8 µs per tick |
| A capture's list with 64 players in the circle | 77 µs (once per capture: that tick's candidates) |
| `to_record` · `from_record` | 4 µs · 16 µs |
| `pvp` section: `is_dirty` · `build` | 5 µs · 5 µs per character (one per checkpoint or critical save) |

**Unverified:** against the real Go platform (P10; here, `FakeZonePlatform` and `FakeHttpServer` with the same version
rule as `internal/war`); with several fortresses per zone (GUE-20, phase 7).

**Left for later:** the capture reward and what a forced cycle pays or not (progression.md P5c); setting `gm_forced` and
invisible GMs (P7b); end to end (P10).

### 19.12 P7b · moderation in the zone (SOC-14 to SOC-18)

**What exists.** The zone half of §9: roles per command, `/gm`, the invisible GM, the commands' `gm_forced` flag,
ignores, reports with their evidence, mutes, warnings on entry and the chat and audit batches. Without `--platform`
everything stays as in phase 4: there are no roles, `/gm` answers "Comando desconocido" and chat is per connection.

| Piece | Content |
|---|---|
| `command_registry.gd` | Roles (`ROLES`, `role_rank`, `role_allows`), `min_role` in `register` (`gm` by default), `get_min_role`, `can_use`, `get_names_for`; `Result.FORBIDDEN`; `Origin` (console, chat, network) in the `Context`, with `role`, `target`, `audit_args` and `audit_key`; `execute_network(…, role)` (empty: without the platform, it does not look at the role); `execute_chat(peer, line, role)` (`/gm`: the console handler; unknown or without permission, "Comando desconocido. Escribe /ayuda."; `ayuda` lists those for the role); `audit_entry_sink`, with each use that gets to execute |
| `social/moderation_service.gd` (new) | `ModerationService`: the chat's GM channel (`handle_command`: `gm`, `ignorar`, `designorar`, `reportar`), `/gm`'s moderation commands, the `ignore`, `report` and `sanction` responses, the heartbeat's `mutes`, warnings on entry, the audit batch entry and the chat batch one; `parse_minutes` and `date_text` |
| `social/chat_router.gd` | `command_sink` (the GM channel, after spending its token and without the repeat check), the mute ("Estás silenciado N min más.", `MUTED`), the ignore filter on all channels (in a whisper the sender's copy goes out), the ring of what was received (`keep_received`), `log_sink` and `clock_unix` |
| `social/chat_peer_state.gd` | `account_id`, `ignored_accounts`, `ignored_by_name`, `muted_until_unix`, `mute_changed_msec`, the `received` ring (100 per receiver, `Received`, `received_from`) and recent reports |
| `social/social_service.gd` · `social_peers.gd` · `party_manager.gd` | `on_peer_joined` (the chat state per character, kept `KNOWN_RECIPIENT_TICKS` after the drop and reattached; account, ignores and mute from the claim) and the purge in `step`; `find_any_by_name` and `ignores`; the invitation from someone who ignores to the one who invites, silently discarded |
| Combat | `NetEntity.gm_invisible` and `Combatant.is_gm_invisible()`: `CombatResolver` skips it as an attacker and as a candidate (gates too), `ProjectileSystem` does not let it shoot or take it as a target, `CombatDirector` applies no pulses, falls or lethal volumes to it (the void does, which only returns the body), `DownedSystem` does not let it revive or finish off and `NpcWorld` does not take it as a target; `ProgressService._collector` does not pay it |
| `zone_server.gd` | `ModerationService` in `start` (after `SocialService`); `ignore`, `report` and `sanction` in "poll"; the heartbeat's `mutes`; `on_peer_joined` and warnings at spawn; `_is_relevant` leaves the invisible one out with any policy; also out of `_presence_candidates`, the scoreboard, bots' targets and allies and bodies that prevent closing the gate; `set_gm_invisible` (DESPAWN or SPAWN at once), `kick_peer`, `send_notice`, `get_world_peers` and `get_moderation`; each command's `min_role`, `anuncio` and `apagar`; DEBUG_COMMAND with the claim's role (without it, a warning); `_mark_gm_forced` in DEBUG_COMMAND 1, 2 and 4 and in `teleport`, `heal`, `stamina_inf` and `unstuck` from the console and `/gm`; `teleport <player> <other>`; each command's target in `ctx.target`; `moderation` in the report |
| `zone_platform.gd` | The heartbeat's context: `{characters, sent_msec}` (who it was sent for and when) |
| Client | `ChatCommandParser.Kind.SERVER`: `/ignorar`, `/designorar` and `/reportar` (in the help) and `/gm` (not in it) are sent as is through the GM channel; `ChatBox` sends them |
| Tests | `FakeZonePlatform`: `set_account_state` (mute, ignores and warnings of the claim), `queued(kind)` and default responses for `ignore`, `report` and `sanction` that resolve the name among registered characters (before, 404) |

`/gm` commands (those that are not moderation are the console's and the fort's, with `gm` by default):

| Command | Role | Does |
|---|---|---|
| `aviso <player> <reason>` | moderator | `warning` sanction; if they are in the zone, a NOTICE with the reason right away |
| `silenciar <player> <duration> <reason>` | moderator | `mute` sanction (`30`, `30m`, `2h`, `7d`; more than 7 days, the platform asks for admin); if they are in the zone, muted right away and a NOTICE |
| `expulsar <player> [reason]` | moderator | Kicks them from the zone with a final save and a cooldown; through `/gm`, only someone with a lower role |
| `suspender <player> <duration> <reason>` | gm | `suspension` sanction; requests a heartbeat at once (its `revoked` kicks them) |
| `renombrar <player> <reason>` | gm | `rename` sanction; if they are in the zone, kicks them with a final save so they pick another name |
| `invisible` · `visible` | gm | On whoever types it (from the console, `invisible <player>`); `visible` flags with `gm_forced` |
| `teleport <player> <x> <y> <z>` · `teleport <player> <other>` | gm | Flags the one moved with `gm_forced` |
| `banear <player> <reason>` · `anuncio <text>` · `apagar <s>\|cancelar` | admin | `ban` sanction (heartbeat at once) · `announce` · `shutdown` (`kick`, `announce` and `shutdown` also belong to admin) |

**Deviations and decisions:**

- **Commands go through channel 8 (GM) of CHAT_SEND.** Protocol 7 had no message for `/gm`, `/ignorar`, `/designorar`
  or `/reportar`, and the version no longer bumps. The client sends the line without the slash through that channel
  (without changing the bytes) and the response arrives through the system channel. It spends the speaking token, does
  not go through the repeat check and a muted player can use it (it is not chat). networking.md and social.md say so.
- **Sanctions do not come from the console** ("Desde la consola, usa "admin sanction" de la plataforma", i.e. from the
  console, use the platform's `admin sanction`): the platform requires an author with a lease on the instance (§9.5)
  and the console has no character.
- **What the zone does with a sanction's 200** (§9.5 did not say, for someone who is inside): the mute is applied at
  once, without waiting for the heartbeat, with a NOTICE "Un moderador te ha silenciado 30 min: motivo" (a moderator
  has muted you for 30 min: reason); the warning goes out at once in a NOTICE (and again on the next entry, because the
  platform considers it seen with the first save of the next lease, §19.7); the rename kicks the character with its
  final save; suspension and ban request a heartbeat at once, whose `revoked` kicks them with the platform's text.
- **The heartbeat's `mutes`.** The response brings the current mutes of the accounts the heartbeat was sent for;
  without the account, it is not muted (a lifted sanction). So as not to lift the mute of someone who entered after the
  heartbeat went out or undo a later sanction from this zone, `ZonePlatform` passes `{characters, sent_msec}` as the
  heartbeat's context and the zone only touches those characters with their `lease_id` and only if there was no local
  change afterwards.
- **Reports.** The zone already throttles to 1 per target every 10 min and 10 per hour (per character, in its
  `ChatPeerState`; the platform checks again per account and its 429 says how long to wait); one that the platform does
  not accept (a name that does not exist, an error) does not spend the limit. The evidence is the last 20 messages from
  the reported player in the reporter's 100-entry ring, within 10 min (in a zone with a lot of chat it can fall short:
  the ring is per receiver, not per sender). `context` carries `zone_id`, `zone_channel`, `tick`, `reporter_position`
  and, if they are in the zone, `target_position`. Categories are written in Spanish (`lenguaje`, `acoso`, `trampas`,
  `bot`, `nombre`, `otro`).
- **Ignores.** The POST's response gives the account, which enters the filter at once; the DELETE answers 204 without
  it, so `/designorar` removes the one ignored in this session with that name and the character's if they are in the
  zone (the rest, with the next claim). The filter applies on all channels, also the group one; a whisper to someone
  who ignores you goes out as usual for the sender, and an invitation stays pending until it expires without reaching
  the invitee, who cannot accept it: the one ignoring does not give themselves away.
- **Audit.** Each use that gets to execute goes to the batch (not unknown ones or those without permission, which only
  stay in the zone's log). `args` never carries free text or names: what the handler sets (`{kind, minutes}` in a
  sanction, `{position}` in a teleport) or, if it sets nothing, the numeric arguments (`values`) or, in a
  DEBUG_COMMAND, the `payload` in hexadecimal. The target, by id, if they are in the zone (a DEBUG_COMMAND acts on
  whoever sends it); the target of a sanction on someone outside stays in the platform's `sanction` row.
  `Context.audit_key` is for progression.md P5d's `op:<op_id>`.
- **Invisible.** Applied by `ZoneServer._is_relevant` and not `InterestPolicy`, so that it holds with any policy
  (Eldrun's grid will replace it). In addition to what §9.1 says, it is not a target for NPCs or bots, does not count
  as an ally in their gatherings or prevent closing the gate, neither revives nor finishes off and suffers no falls or
  lethal volumes. It stays in its own group's `PARTY_STATUS` and its `/decir` is heard by those nearby: these are its
  own decisions. It is not stored (re-entering leaves it visible) and respawning does not clear it.
- **`gm_forced`** is also set by the console and `/gm` with `teleport`, `heal`, `stamina_inf` and `unstuck` (§9.1
  names `/gm teleport`, `/gm visible` and DEBUG_COMMAND 1, 2 and 4: they are the same handlers). Only with the
  platform.
- **Per-character chat state.** When reattaching it, the name key is recomputed and the account, ignores and mute are
  taken from the new claim; the ring and recent reports come back with it. Without a claim (without the platform)
  nothing is kept.
- **5, 13 and 16 remain at `gm`**: raising them to `admin` belongs to progression.md P5d, with its tests.
- **`FakeZonePlatform`** answers `ignore`, `report` and `sanction` by default by resolving the name among registered
  characters (404 if not found; 400 with one's own account on ignore and report), instead of P4's 404.
- **Minimal client.** Only the parser and chat sending; the social menu's ignore and report options (SOC-07) and the
  staff label (P8) are left out.

**For the following packages.**

- **progression.md P5d:** registers its commands with `_commands.register(name, usage, console, network, min_role)` and
  raises 5, 13 and 16 to `admin` (`register` in `zone_server.gd`). The rule on one's own characters has in the
  `Context` the role (`ctx.role`), who sends it (`ctx.peer.claimed`) and the target the handler resolves
  (`ctx.target`, which also puts the target in the audit). A command that creates an operation sets `ctx.audit_key =
  "op:<op_id>"` and its `ctx.audit_args` with the target by id; `ModerationService._audit_entry` builds the rest (actor,
  `source`, `at_unix`). With the zone fenced, `ModerationService` already answers "El servicio de cuentas no responde"
  to ignore, report and sanction.
- **P10:** `/gm silenciar` against the real store and the chat batch that `admin chat` reads.

**Tests** (Godot):

- **`test_zone_moderation.gd`** (10, the zone without a network with `FakeZonePlatform`): `/gm` from a player (and
  `ayuda`, a command that does not exist and one of another role) → "Comando desconocido" and nothing to the platform;
  a moderator mutes (body of §6, text with the date, muted at once with its NOTICE and "Estás silenciado 30 min más.")
  and the audit entry (`source` `zone`, actor, target by id, `args`, no names or reason); DEBUG_COMMAND 1 without a
  role → warning and it does not move, and with `gm` it moves, is flagged and audited on oneself, and 2 and 4 also
  flag; `/gm teleport` (to coordinates and next to another) flags the one moved, `/gm invisible` sends the DESPAWN to
  everyone and interest does not put it back in, out of the circle, the scoreboard and bots' targets, and `/gm visible`
  returns it with its SPAWN and flags it, and respawning clears the flags; an ignored player does not whisper, invite
  or reach the zone (and the sender does not notice), `/designorar`, oneself, a name that does not exist, the full list
  and the claim's ignores; the report with its evidence (what was received from the reported player, without others'),
  the context, the zone's limit, the platform's 429, the name that does not exist without spending the limit and the
  usage; the heartbeat's `mutes` (lifts, sets, does not touch someone who did not send a heartbeat and does not undo a
  later sanction); the forced rename with its final save (reason 5), `/gm expulsar` with the target's role and the
  platform's 403; the claim's warning on entry and a new one at once; the whisper in the chat batch and leaving and
  coming back without refilling bursts; without the platform, an unknown `/gm` and ignore and report without an
  accounts service, and a sanction from the console.
- **`test_chat_moderation.gd`** (7, `SocialService` without a network): the ignored player in say, zone and whisper;
  the invitation silently discarded; the mute on each channel with the minutes and without an end; the GM channel to
  `command_sink` without the repeat check and with the speaking token; the ring (order, window, limit, own not) and
  the batch; per-character state (leaving and returning does not refill, after 5 min it does, the purge) and what is
  taken from the new claim.
- **`test_command_registry.gd`** (+3: roles, `min_role` on the network with the audit, `/gm` with its help),
  **`test_combat_resolver.gd`** (+1: the invisible one neither hits nor is hit), **`test_progress_rewards.gd`** (+1, the
  one from progression.md §15 P5c that was missing: an invisible GM in the circle gets no capture pay, nor a kill),
  **`test_chat_command_parser.gd`** (+1) and **`test_chat_box.gd`** (adjusted: `/gm` goes out through the GM channel).

Checked with the mutation they should catch: without removing the invisible one from `_presence_candidates` or from
interest, without the role in `execute_network`, without the chat's or invitations' ignore filter, without
reattaching the `ChatPeerState`, without `gm_forced` in `/gm teleport`, without the local report limit and without the
heartbeat's `mute_changed_msec` guard, they fail. `test_zone_server*` (86, with the platform and save ones),
`test_chat_*` (111), `test_party_*`, `test_combat_*` (290), `test_downed`, `test_npc_*`, `test_hfsm_brain`,
`test_character_saver`, `test_war_*`, `test_platform_client`, `test_progress_*`, `test_score*`, `test_unstuck*`,
`test_loadout*`, `test_consumables*`, `test_ability*`, `test_fortress_*` (151), `test_net_loopback`, `test_net_client`,
`test_bot_swarm`, `test_bot_cheat`, `test_online_main`, `test_handoff_ticket`, `test_zone_process_shutdown` and
`test_architecture` remain correct; `test_combat_server` with the new use of `teleport` in the console. The entire
Godot suite has not been run; Go does not change.

**Measured** (this machine, 4 shared cores, Godot 4.7.2 headless; a probe that is not committed, two passes):

| What | Result |
|---|---|
| A zone message to 64 receivers (`ChatRouter.route`: rate, mute, sanitizing, filter and 64 sends) | 135–155 µs without ring or batch, with or without 100 ignored accounts per receiver (the filter is a dictionary lookup per copy and is not noticeable); 180–210 µs with the ring and the batch (one `Received` per message recorded in 64 rings) |
| `SocialService.on_peer_joined` with 100 ignores | 20 µs |
| `ChatPeerState.received_from` over a full ring | 25–31 µs (once per report) |
| `test_zone_moderation.gd` · `test_chat_moderation.gd` | 10 tests in about 18 s and 7 in about 15 s, with the runner's startup |

**Unverified:** against the real Go platform (P10; here, `FakeZonePlatform` with the routes' bodies of §6 and the errors
of `internal/social`); Eldrun's chat with hundreds of receivers and its ring; staff seeing an invisible GM (not needed
in phase 5).

**Left for later:** progression.md §10's commands with `admin` on 5, 13 and 16 and the rule on one's own characters
(progression.md P5d); the social menu's ignore and report options and the ignore list on the client (SOC-07); end to
end (P10).

### 19.13 P9b · operations (TEC-28)

**What exists.** `platform/deploy/` with what of §10.1, §10.3 and §12 can be automated here, plus `admin
reapply-purges`, which is brought forward from P9a (below):

| Piece | Content |
|---|---|
| `dev.sh` | `up` (default), `prepare`, `env`, `stop` and `reset`. A dedicated PostgreSQL in `build/dev_pg` (`initdb`, and `runuser -u postgres` as root, like `testdb`) that is kept between startups, on 127.0.0.1:24682 (`ELDMARK_DEV_PG_PORT`). Ticket keys, one token per development zone (`1:vado_gris:0` and `1:test_world:0`) and the passwords in `build/dev_secrets/` (0600), and `build/dev_platform.env` with the `*_FILE` variables. `migrate up`, `admin bootstrap admin@eldmark.test` if there is no admin account and `admin --actor … create-account prueba@eldmark.test`. It writes the zone's command with `--platform` (and the client's and bot's, from P8). `up` starts `serve` in the foreground: Ctrl-C or TERM stop `serve` and PostgreSQL. It compiles the binary with Go or uses `ELDMARK_PLATFORM_BIN` |
| `backup.sh` | `pg_dump -Fc` to `daily/eldmark-<UTC with ms>.dump` (checked with `pg_restore --list`) and then `purge_log` to its `.purges.txt` and to `<folder>/purges.txt` (swapped in one go with `mv`, never rotated): `kind<TAB>id<TAB>purged_at`, COPY's text in UTC with microseconds, without personal data. Weekly (hard link) if the last weekly one is almost 7 days old or there is none; rotates 7 daily and 4 weekly (`ELDMARK_BACKUP_DAILY`, `…_WEEKLY`), each with its `purges.txt`. The database, from `ELDMARK_DATABASE_URL` or `…_FILE` (or the `PG*`), never written to the output. If anything fails it leaves no half files and exits with 1 |
| `restore_check.sh` | `<backup> <purges.txt>`, or `--dir <folder>` (the most recent backup from `daily/` and `weekly/` and its `purges.txt`). Ephemeral cluster (like `testdb`, socket only), `pg_restore`, the emails the backup still has for the accounts in `purges.txt` (in a separate schema of the test cluster), `migrate up` if the backup lacks migrations, `admin --actor <the backup's admin> reapply-purges`, `migrate status` and the integrity queries, which must give 0 (below). Exits with 1 if anything fails and with 2 if the usage is invalid; deletes the cluster on exit |
| `pitr_check.sh` | The one in §12: a primary with `archive_command` to a folder, `pg_basebackup`, 500 rows that are only in the WAL, the target time, a deletion and `pg_switch_wal` (waits for the segment to be archived); the base backup with `restore_command`, `recovery_target_time`, `recovery_target_action = 'promote'` and `recovery.signal` must have the 1500 rows from before the deletion and no others. Only `fsync=off`: the WAL and full-page writes, as on the VPS |
| `pglib.sh` | What is common to the three that start PostgreSQL: the binaries (`ELDMARK_PG_BIN`, `pg_config` or the highest `/usr/lib/postgresql/*/bin`), `runuser` as root (`ELDMARK_PG_USER`), `initdb`, start, stop and the socket path (107 B) |
| `Dockerfile` | `build` (golang:1.24.7-bookworm, `CGO_ENABLED=0`, `GOTOOLCHAIN=local`), `platform` (debian:bookworm-slim with `ca-certificates` and `tzdata`, user 10001, `serve`, both APIs on 0.0.0.0 inside the container) and `ops` (postgres:16-bookworm with the binary and the scripts). Context `platform/`, with `platform/.dockerignore` (secrets, backups, `*.env`, `*.pem`, `*.key` and the binary excluded) |
| `docker-compose.yml` | `db` (postgres:16), `platform`, `caddy`, `zone-vado-gris` (profile `zonas`) and `backup`, `restore-check` and `pitr-check` (profile `ops`; the last two without a network). All with `logging: {driver: journald, options: {tag: "{{.Name}}"}}`; the service ones, `restart: unless-stopped`. Nine file secrets in `ELDMARK_SECRETS_DIR`, mounted at `/run/secrets` and read with the `*_FILE`. Networks `edge` (Caddy, with a fixed IP: the only one in `ELDMARK_TRUSTED_PROXIES`), `zones` (the zones and the internal API) and `data` (internal: the database does not reach the Internet). Only Caddy (80, 443 and 443/udp) and the zone (24600/udp) publish ports. WAL with configurable WAL-G (`ELDMARK_DB_IMAGE`, `ELDMARK_PG_ARCHIVE_MODE`, `ELDMARK_PG_ARCHIVE_COMMAND`); project name `eldmark-<environment>` |
| `Caddyfile` | §10.1: `reverse_proxy platform:24680 { header_up X-Real-IP {remote_host} }` (overwrites any client `X-Real-IP`), no `log` directive (no access log), HSTS, `nosniff` and no `Server`. Validated with Caddy 2.10.2 (`caddy validate` and `adapt`: no `logs`) |
| `staging.env.example`, `production.env.example` | The compose's variables: environment, domain and ACME email, GHCR images, `public_host` and `ELDMARK_ZONE_HOSTS`, minimum protocol, sender, realms, secrets and backup folders, WAL and Caddy's network. No secrets (CI checks it) |
| `journald-eldmark.conf` | `Storage=persistent`, `MaxRetentionSec=30day` and `SystemMaxUse=2G` (§11.1), for `/etc/systemd/journald.conf.d/` |
| CI | `ELDMARK_REQUIRE_DEPLOY_TOOLS=1` in "Plataforma": without bash, git, shellcheck or `docker compose`, the `deploy` tests fail instead of being skipped (Caddy is optional: CI does not bring it) |

**`reapply-purges` arrives here** (§14.1 puts it in P9a, on which P9b depends): without it `restore_check.sh` cannot be
tested. `eldmark-platform admin --actor <email> reapply-purges <purges.txt>` (requires `admin`; leaves the
`reapply-purges` row with the counts and without ids) does what §11.2 says: in one transaction it deletes all of the
backup's `character_leases` and `enter_tickets`; then, in `purged_at` order (at equal time, characters before their
account), it purges each line in its own transaction with the file's `purged_at`: accounts with P1's purge
(`accounts.Service.ReapplyPurge`, new reason `reapply-purges`: it is enough that it is not purged, as in `purge-now`)
and characters with the account's path (`characters.Purger.ReapplyPurge`). The email fingerprint, the year of
sanctions and of the ledger and the 30 days of the name come from that `purged_at`. At the end it checks that no id
remains unpurged (`admin.UnpurgedError`, code 1); one that the backup does not have counts as purged. It is
idempotent. `admin.ParsePurges` reads `backup.sh`'s format (and RFC 3339) and names the bad line. Like `purge-now`, in
`staging` and `production` it refuses while the progress store does not exist (progression.md P7). Step 3 of the purge
(not with a live lease) is still checked, although it finds nothing: if one appears, a zone or `serve` is running
against the database, and the command stops with an error that says so. **P9a is left** with the rest: the export with
progress, the missing hourly retention jobs, the ledger one with the deletion of empty tombstones and its tests that
are not about `reapply-purges`; those for `reapply-purges` in §15 P9a already exist (below).

**Deviations and implementation decisions:**
- **`dev.sh` listens on TCP** (127.0.0.1, no socket): the path of `build/dev_pg` in a repository with a long path
  exceeds the socket's 107 B. It has more commands than §12 (`prepare`, `env`, `stop` and `reset`) and fixed
  development passwords (`eldmark-admin-dev` and `eldmark-prueba-dev`, also in `build/dev_secrets/`), which are typed
  in the visual review of §15. Accounts are created with `bootstrap` and `create-account` (§19.5).
- **`restore_check.sh` migrates before `reapply-purges`** if the backup lacks the binary's migrations (a backup from
  before a deployment; `admin` refuses with an unmigrated schema; expand and contract allows it, §2.4), and afterwards
  `migrate status` must exit with 0. The binary runs with a throwaway configuration (`env -i`, `ELDMARK_ENV=dev` and
  random keys): it only sees the test database. The `--actor` is `ELDMARK_RESTORE_ACTOR` or the first active admin
  account, without suspension or ban, that is not in `purges.txt`; if the backup has no admin, a throwaway one with
  `bootstrap`.
- **The integrity queries** of §12, plus those that check `reapply-purges`: characters without an account; leases of
  non-existent instances; leases and tickets still from the backup; `purges.txt` lines without a row in `purge_log`
  (of the accounts and characters the backup has); `purged_at` different from `purges.txt`'s; accounts in `purge_log`
  or `purges.txt` with personal data (email, hash or state, or rows in sessions, links, logins, consents, acceptances,
  entitlements, realms, ignores in both directions, sent chat or sanctions with a reason: what P1's purge deletes);
  their characters, or standalone purged ones, with a name, statistics, lease, ticket or linked name; emails of those
  accounts in `outbound_mail`; and `audit_log` rows with the email of an account in `purges.txt` (only rows with "@"
  are searched). They go by sets: with an `exists` per row, 1000 purges over 100 000 messages took 22 s.
- **`backup.sh`:** the name carries milliseconds (two consecutive backups do not overwrite each other and the name
  sorts by date); the weekly one comes from the age of the last weekly, not from a fixed day (it tolerates days
  without a backup); each backup's `purges.txt` rotates with it and the folder's never rotates. Uploading them to S3
  belongs to the VPS.
- **The `ops` image** (§12 does not have it): PostgreSQL 16 with the scripts and the same binary, to run backups and
  their checks in a disposable container with the database's version. `docker compose run --rm restore-check` is
  TEC-28's weekly restore.
- **The zones in the compose** go under the `zonas` profile until their image (TEC-20) and their options (`--platform`,
  `--world`, `--channel` and `--public-address` from P4; `--dtls-*` from P9c) exist.
- **Secret permissions:** Compose without swarm mounts each file with its host permissions and inside it unprivileged
  users read them (eldmark 10001, postgres 999): 0444 inside a 0700 folder owned by root.
- **`platformtest.Attach`** (the platform over an already built database, like a restored one) and
  **`testdb.BinDir`** (the folder of the tests' `pg_dump` and `pg_restore`) are new, for tests.

**Tests.** `platform/deploy` is a Go package without code (`doc.go`) with its tests, which run the scripts with bash:
`TestBackupAndRestoreCheck` (the one of §15 P9b: a backup before a `purge-now` and before deleting a character,
restored with the most recent `purges.txt` → purged and the queries at 0; the most recent with `--dir`; a backup whose
audit keeps the email of an account purged later → 1 and it names it; rotation), `TestRestoreCheckUsage`,
`TestPitrCheck`, `TestDevScript` (`prepare` twice, `env`, `up` up to `/ready` and TERM with PostgreSQL stopped,
`reset`), `TestComposeConfig` (`docker compose config -q` with the two examples and not without them; journald on all,
ports only on Caddy and the zone, the database alone in `data`, no cleartext secret, `ELDMARK_TRUSTED_PROXIES` with
Caddy's IP), `TestCaddyfile`, `TestCheckSecrets` (the one of §15 P9b: the real examples pass; a `staging.env`, a
`secrets/ticket_keys` or an example with a secret's value in the index → 1, without repeating the value; and this
repository's index passes) and `TestScriptsPassShellcheck` (`bash -n` and shellcheck 0.10 without warnings). In
`internal/admin`: `TestParsePurges`, `TestReapplyPurgesAfterRestore` (the two of §15 P9a about `reapply-purges`: with
real `pg_dump` and `pg_restore`, the original `purged_at` on the tombstones, also that of a character that was never
deleted; without the backup's leases or tickets; `purge_log`, the email fingerprint and the name reservation as in the
original database; the audit row; and a second round that changes nothing) and
`TestReapplyPurgesReportsWhatStaysUnpurged` (with a purge that does not purge, `UnpurgedError` with the id). In `cmd`,
the command through the command line (usage, a malformed or non-existent `purges.txt` → 1).

**Measured** (this machine, 4 cores, Go 1.24.7, PostgreSQL 16.15):

| What | Result |
|---|---|
| `pitr_check.sh` | 3.0–3.2 s (base backup 0.65 s, recovery 0.15 s) |
| `backup.sh` | 0.1 s with a test database (76 KB); 0.3 s with 10 000 accounts, 20 000 characters, 100 000 messages and 50 000 audit rows (43 MB database, 1.6 MB backup) |
| `restore_check.sh` | 1.3–1.5 s with a test database. With the large one and 1000 accounts in `purges.txt`: `pg_restore` 0.64 s, `reapply-purges` 18.6 s, all 20.3 s |
| `reapply-purges`, per account with 2 characters | 18 ms; 10 ms with an index on `chat_messages (sender_account_id)`, which the schema does not have: purging an account deletes its chat by scanning the whole table (the same in the hourly purge and in `purge-now`). **For a future migration** (outside phase 5, §2.4) |
| `go test -race -count=1 ./...` | 34 s, no races; `deploy`, 14 s (with the binary's compilation) |
| Binary | 20.5 MB |

Godot: outside `platform/` only documentation and CI change (`platform/` carries `.gdignore` and is excluded from
exports).

**Unverified (on the VPS, the user's):** building the images (here the Docker daemon does not run: `docker compose
config` does, `build` does not) and starting the compose; Let's Encrypt with a real domain; secrets mounted and read by
unprivileged users; journald with `MaxRetentionSec` (here there is no systemd); the database image with WAL-G, S3 and
the real `restore_command`; the `backup` and `restore-check` cron with its alert (TEC-31); `dev.sh` on macOS and on
WSL with the zone on Windows; `serve`, `purge-now` and `reapply-purges` in staging and production, which wait for the
progress store (progression.md P7); the zone in the compose (TEC-20, P4 and P9c); and the "Plataforma" job on GitHub
with the mandatory tools (`ubuntu-latest`'s shellcheck and `docker compose`).

**Left for later:** `admin maintenance` and `deploy.sh` (previous backup, stop, `migrate up`, new version, remove
maintenance), from TEC-28 and without a package here; publishing the images to GHCR; the zones' image and deployment
(TEC-20); the rest of P9a.

### 19.14 What progression.md P7 leaves

progression.md P7 (its §19.17) puts in the real progress store (`internal/progress` over `0010_progress`) and creation
validation with the exported rules, and changes what here was waiting for it:

- **`serve` and the `admin` command** use `progress.Store` and `*progress.Rules` in all environments. There is no
  `errNoProgressStore` any more: `serve` starts in `staging` and `production`, and `purge-now` and `reapply-purges`
  purge the progress state there with `ProgressStore.Purge`. `MemoryProgressStore` and `ProvisionalValidator` remain
  for tests.
- **`platformtest.NewWithProgress(t, newStore, validator)`** mounts the platform with the real store (`ProgressStore`
  is whichever is in use; `Progress`, the fake, is nil then) and `NewCharacter` creates with
  `platformtest.ValidAppearances`. `TestBackupAndRestoreCheck` (P9b) already uses it, and `restore_check.sh` checks
  that purged characters have no rows in `character_progress`, `character_wallets`, `item_instances` or
  `character_timers`.
- **P9a:** the hourly ledger retention job calls `ProgressStore.PurgeRetention` in one transaction as long as it
  returns `deleted > 0` and deletes in it the `characters` rows of `emptied`; the export puts `ProgressStore.Export`
  (`{"record", "ops"}`, without staff data) under `characters[i].progress`, also for tombstones with a ledger.
- **P7b and progression.md P5d (audit):** the `audit_log` row that S8 writes carries in `args` the operation's `detail`
  without `command`, `source`, `actor_character_id` or `at_unix` (`{"args": [...]}`, and the level and XP keys if
  there are any); the batch entry with `key = "op:<op_id>"` must carry the same.
- **P10:** end-to-end tests can compare with `Load` (progression.md §3.4's record).

**Unverified:** with a real zone (P10).

### 19.15 P9a · privacy (TEC-43)

**What exists.** What §11 had left after P1 (account export, account purge and email fingerprint), P2 (character
purge), P7a (`purge-now` and chat retention), P9b (`reapply-purges`) and progression.md P7 (the real `Purge`,
`PurgeRetention` and `Export`):

| Piece | Content |
|---|---|
| `internal/privacy` | New (the one from §2.1): `Service` with `Run` (one round of §11.1's retention jobs with the injectable clock's time), `Job` (the hourly `privacy_retention` job, which logs how much each step deleted, without ids) and `PurgeLedger` (ledger retention). Deadlines are constants (`AuthEventsRetention`, `ReportRetention`…); `Result` gives what each step of `Steps` touched |
| `internal/accounts` | `Options.Progress` (`ProgressExporter`, the `Export` part of `ProgressStore`) and `characters[i].progress` in the export (below) |
| `cmd/eldmark-platform` | `serve` passes the store to the export and adds the `privacy_retention` job, every hour (the fifth: the 16-connection pool of §19.5 is more than enough) |
| `internal/platformtest` | `Platform.Privacy` (with the fake clock) and the store in the export |
| `platform/legal/privacy-1.md` | Revised (below); `TestEmbeddedDrafts` looks for a few more figures and phrases |

**The retention jobs.** One round does the steps in this order, each in its own statements (those for growing tables,
in batches of 10 000 until nothing remains); one that fails does not stop the others and the round returns the errors
together:

| Step | What it deletes (or changes) |
|---|---|
| `reports_closed` | Reports `open` or `in_review` created more than a year ago become `dismissed`, `closed_at` = now and `resolution = 'caducado'`: they count from there |
| `reports` | Those closed (`actioned` or `dismissed`) more than a year ago, with their `report_evidence` and their `sanction_reports` (cascading) |
| `audit_log` | What is more than a year old (`at`) |
| `sanctions` | Those of accounts purged more than a year ago (with their `sanction_reports`); those of a living account do not expire |
| `sanctioned_emails` | Fingerprints with `until ≤ now`, which registration no longer looks at |
| `auth_events` | What is more than 30 days old |
| `session_access` | IP and agent set to null on sessions opened more than 30 days ago |
| `sessions` | Those expired (`refresh_expires_at`) more than 7 days ago; their tickets cascade and the lease that has it is left without a session |
| `account_tokens` | Those expired (`expires_at`) more than 7 days ago |
| `enter_tickets` | Those expired more than a day ago |
| `zone_instances` | Those ended (`stopped`, `lost` or `replaced`, all three with `ended_at`) more than 30 days ago, with their `id_blocks` and tickets cascading; leases, fortresses and war events that name them are set to null |
| `outbound_mail` | What is more than 7 days old |
| `character_names` | `reserved` rows with `reserved_until ≤ now` |
| `ledger` and `ledger_tombstones` | `ProgressStore.PurgeRetention` in a transaction as long as it deletes something and, in it, `delete from characters` for those in `emptied` (with `purged_at`: a living character is never deleted here). The year is measured by the store's clock |

**The export.** `characters[i].progress` is the character's `ProgressStore.Export`, in the same transaction
(`repeatable read`, read-only) as the rest of the file: for an unpurged one, `{"record", "ops"}`; for a tombstone,
`{"record": null, "ops"}` if a ledger remains and `null` if not any more. For GM and REVERSAL operations the type,
date, ledger entries and events come out, without actor, `note` or `detail` (stripped by `Export`).
**What was reviewed** (§14.1 put it all in P9a):

- **Purges** (locks, tombstones, `purge_log`): those of P1 and P2 as is. Their §15 P9a tests were already there
  (below) and the restore-at-the-limit one was missing, which now exists.
- **`sanctioned_email_hashes`:** P1's rule stays (each unrevoked sanction counts up to 90 days after its end; a
  warning or a rename, from when it was set; a permanent ban, the cap), with 1 year at most from the purge (in
  `reapply-purges`, the original one). It is the reading of "until the sanction ends, or 90 days after it" in §11.1
  that matches "a sanction within the last 90 days" in §11.2 and the recidivism of social.md §9. What was missing was
  deleting the expired ones (`sanctioned_emails`).
- **`reapply-purges`** (P9b): unchanged. Since ledger retention and sanctions' retention count from `purged_at`, a
  restored backup lengthens none.
- **`privacy-1.md`:** "finished zone instances"; a purged character's history lasts one year from the purge (it said
  "from when it is deleted"); a test character's name is only reserved while it can be restored; staff corrections
  (actor, note and command) follow the history and their note is kept as moderation data; the email fingerprint, 90
  days after the end of the last sanction (a ban, the whole year); backups purge again with the original date; and what
  the download carries (progress and history, also that of purged characters that is retained) and what it does not
  (who made a correction and their note). It is still version 1: it has not been published in staging (§19.2).

**Deviations and implementation decisions:**

- **"Stopped `zone_instances`" means finished ones:** `stopped`, `lost` and `replaced` set `ended_at` and none serves
  again; §11.1's table already says so. A lease whose `claimed_by` was one of them does not change (it has no foreign
  key) and is only valid for `Apply` while its instance lives.
- **Reserved names:** §11.1 said "the name, 30 more days" without a mechanism. Create and restore already treat an
  expired `reserved` row as free, but the row kept the name forever; now the job deletes it (§11.1 corrected).
- **Sessions:** "expired" is `refresh_expires_at` (12 h from login; revoking does not change it), so a session lives at
  most 7 and a half days. With that, the 30-day rule for IP and agent never gets applied today (it stays in case
  sessions get longer), and the export gives the sessions of those 7 and a half days. A lease of a character that has
  been in the world longer than that is left without a session (the heartbeat can no longer kick it through it; it
  could not anyway: expired is not revoked).
- **A report's evidence goes with its report** (`report_evidence` cascades): that of one that was open for a year lasts
  up to two, as the table says ("from the closing").
- **A tombstone without a ledger** gives `progress: null` in the export (§11.2 only asks for those that have one).
- **`audit_log` at one year** also deletes the old `set-role` rows that `sanctions.RoleAt` (S2) reads: it only changes
  anything for a GM operation with a `detail.at_unix` more than a year old, which would be checked against the later
  role.
- **Clocks:** ledger retention uses the store's (`progress.New`) and the rest the service's; in `serve` both are the
  system time and in `platformtest`, the same fake clock.

**Tests.** `internal/privacy` (5, the whole platform with the real store): `TestExportHasEverySectionAndTheProgress`
(the twelve sections with data; Aneira with record and her two operations, the GM one with only its seven keys and its
ledger entry; Brenna's tombstone with a ledger and without a record; Cora's, without a ledger, `null`; neither the
GM's email, nor their note, nor `currency_add`, nor `detail`); `TestRetentionsDeleteWhatExpiredAndNothingElse` (each
row of the table with a row one minute outside the deadline and another one minute inside: each step's contents exact,
the cascades and the nulls, the open report that gets closed and the one that does not, the sanctions of an account
purged a year and a minute ago, of another that is a minute short of the year and of a living one, the chat that is
not this job's; a second round deletes nothing; the expired report is deleted a year after being closed);
`TestLedgerRetentionEmptiesAndRemovesTombstones` (10 050 ledger entries in three passes, the operation shared with a
living character that stays, a tombstone without a ledger, the one purged two days later that stays, nothing before the
year and the flag that does not survive); `TestRestoreAtTheLimitRacesTheHourlyPurge` (10 rounds with the restore in the
last second and the purge, with its own clock, in the first one after; in the measured run, 2 restored and 8 purged,
all whole or tombstone); and `TestSanctionedAccountsArePurgedAndTheirEmailWaits` (the banned one exports with the
privacy session, with progress, requests erasure and is purged; their email cannot be registered until the year, when
retention deletes the fingerprint; the suspended one, with `purge-now`, until 90 days after the end). In `cmd`,
`TestServeRunsThePrivacyRetention` (`serve` deletes on startup a login from 31 days ago and a ledgerless tombstone from
366, and leaves yesterday's). Checked with the mutation they should catch: without `exportProgress`, without the job in
`serve`, without deleting empty tombstones and without closing reports at one year, they fail.

§15 P9a's, one by one: export (`TestExportHasEverySectionAndTheProgress`); the purge leaves tombstones
(`TestPurgeExpiredLeavesATombstone`, P2); live lease and `character_busy` (the same and `TestPurgeNow`, P7a); restore
and purge at once (`TestRestoreAtTheLimitRacesTheHourlyPurge`); retention
(`TestRetentionsDeleteWhatExpiredAndNothingElse`, `TestLedgerRetentionEmptiesAndRemovesTombstones`); the two for
`reapply-purges` (`TestReapplyPurgesAfterRestore` and `TestReapplyPurgesReportsWhatStaysUnpurged`, P9b); purging an
account leaves tombstones for its living characters (`TestAccountPurgeWithCharacters`, P2); the suspended one and its
email and the banned one that exports, is erased and is purged (`TestSanctionedAccountsArePurgedAndTheirEmailWaits`);
and the audit without its email after `purge-now` (`TestAuditHasNoPersonalData`, P7a) with `restore_check.sh` failing
if it has it (`TestBackupAndRestoreCheck`, P9b).

**Measured** (this machine, 4 cores, Go 1.24.7, PostgreSQL 16 with `fsync` off):

| What | Result |
|---|---|
| One round with 200 000 logins and 100 000 expired audit rows (and another 150 000 that stay) and a tombstone with 60 000 ledger rows | 1.2 s; the next round, with nothing to delete, 7.5 ms |
| Deleting expired sessions with 50 000 leases · finished instances with 200 000 war events | 3 ms per session · 15 ms per instance: the foreign key with `on delete set null` scans all of `character_leases` (no index on `session_id`) or `fortress_events` (no index on `zone_instance_id`) for each deleted row. About a thousand sessions per hour is 3 s of work. **For a future migration** (outside phase 5, §2.4): those two indexes |
| `go test -count=1 ./internal/privacy` | 2.5 s (3.9 s with `-race`) |
| `go test -race -count=1 ./...` | 51 s, no races |
| Binary | 20.9 MB (20.8 MB before) |

Godot: outside `platform/` only documentation changes.

**Unverified:** retention with millions of rows (the 10 000-row batches yes, with 200 000); the job in staging.

**Left for later:** legal review of the texts, the minimum age and the deadlines marked in §11.1 (user, §16); the
controller's contact in `privacy-1.md`.

### 19.16 P8 · client (UI-22, UI-23, UI-24)

**What exists.** The player side of §13: the title screen with an account, character selection and creation, entry
with a ticket and the bot with an account. Without the platform, the client stays as before (sandbox from the editor,
`--connect`, `--local`, `--bot`, `--bots`):

| Piece | Content |
|---|---|
| `scripts/client/platform/` | `PlatformApi` (§14.4: headers of §4.1, refresh a minute before expiring or after a 401 `unauthorized` with the call repeated, **a single refresh in flight** with the `refreshed` signal, `session_lost` if refresh gives 401, `request_hook` for tests, `parse_response` without engine errors), `ApiResult` (plus `text` and `headers`, and `success`, `failure` and `no_response` for tests), `AccountSession` (plus `scope`, `restriction`, `refresh_expires_msec` and `realm_in`), `AccountFlow` (`login`, `logout`, `fetch_account`, `list_characters`, `create_character`, `ensure_character`, `enter` with `character_busy` retries, `config_from_enter`, `parse_id`, `decode_base64`, `starter_templates`) and `PlatformErrors` (the texts of §4.1 by `code`, with dates in local time) |
| `scripts/client/front_main.gd` · `scenes/client/front_main.tscn` | `FrontMain`: the screens, the `AccountSession` between scenes (`FrontMain.session`), the remembered email, data export, entry towards `OnlineMain` and the return with the reason (`return_notice`); with `ClientServices` (F10) |
| `scripts/client/ui/` · `scenes/ui/` | `TitleScreen` (with the recover panel), `RegisterPanel`, `TermsPanel`, `SanctionedPanel`, `CharacterSelect`, `CharacterCreate`, `RenameDialog`, and also `FrontScreen` (the common base) and `CharacterFigure` (the 3D figure with an orbit camera for selection and creation) |
| `ClientConfig` | `--title`, `--platform`, `--login`, `--password-file`, `--character`, `--world`, `--dtls-cert`, `--dtls-name`; `character_id`, `ticket`, `dtls_cert_pem` and `from_front`; the `TITLE` mode with the priority of §13.3 (`from_args(args, exported)`); `platform_url_error`, `url_host`, `is_loopback_host`, `has_ticket`, `has_dtls` and `duplicate_config` |
| `ClientLauncher` · `boot.gd` · `project.godot` | `TITLE` leads to `FrontMain`; an export with no arguments opens the title screen (the editor, the sandbox); `boot.gd` does not warn about the new options; settings `eldmark/platform/url` (`http://127.0.0.1:24680`) and `eldmark/platform/ca_cert` |
| `NetClient` · `NetTransport` | The HELLO with `character_id` and ticket; the DTLS certificate from `enter` (or from `--dtls-cert`) to `connect_to(…, dtls_name, dtls)`, which calls `dtls_client_setup`; `report_extra` and `character_id` in the report |
| `OnlineMain` · `BotSwarm` | With a ticket there is no realm choice; with `from_front`, a rejection or disconnection returns to `FrontMain` with the reason; the bot with `--platform` does the account path and exits with code 1 and `platform.code` in the report if it fails; `--bots --platform` exits with code 1 |
| Tests | `tests/fake_public_platform.gd` (`FakePublicPlatform`: the fake public API for `request_hook`) and five files (below) |

**For the following packages.**

- **P9c:** the client already passes the certificate to `NetTransport.connect_to` with the contract of §10.2 (the
  client side is done, untested against a zone with DTLS): what remains is `host(…, dtls)`, `SwarmBot` and the
  measurement.
- **P10:** the bot with an account is `--bot --platform=<url> --login=<email> --password-file=<path>
  [--character=<name>] [--realm=…] --quit-after-ticks=N --report=<path>`; the report brings `character_id` and
  `platform` (`code` empty if it got in, `created`, `character_id`). It exits with 0 if it got to play.
- **progression.md P5a:** with a ticket, the client draws the appearance from its own SPAWN (P6); creation sends the 8 B
  chosen and the template, so UI-24's criterion (another client sees it the same) depends on the zone loading it.
- **Visual review (user):** the §15 checklist with `deploy/dev.sh` (P9b) and `--title`.

**Deviations and implementation decisions:**

- **Screens are built in code** (like `UIWindow` and `TemplateSelector`) over a common base, `FrontScreen`; their
  `scenes/ui/` scenes are only the root with the script. This way they are tested without a window and `FrontMain`
  mounts them by path. Two files that §13.3 does not name: `front_screen.gd` and `character_figure.gd`; and
  `sanctioned_panel.gd`, the sanctioned-account screen of §13.2, which §13.3 did not list.
- **Extra API** (§14.4 does not name it): `PlatformApi.session` (the session lives in the API; `AccountFlow` sets it on
  login), `clock` (tests), `timeout_s` (15 s), `build_id()` (the same format as the zone's: the client cannot depend
  on `scripts/server/`), `request_headers`, `parse_response`, `get_refresh_count`; `ApiResult.text` (the Markdown of
  `/v1/legal/{kind}` and the export's JSON) and `headers`. On an error, `ApiResult.data` is the body's `error` object
  (with `until`, `reason`, `fields`, `realm`…).
- **Refresh is considered impossible only on a 401**: with no response (network, timeout) the call fails with `network`
  ("No se puede conectar con el servidor de cuentas") and the session continues.
- **The email is lowercased and trimmed** on the client (like `NormalizeEmail` in Go).
- **Create account logs in on its own only against a platform on this machine** (`FrontMain.is_dev_platform`: the URL
  is loopback), which is how the client knows it is in `dev` or `test` (§13.2): `/v1/status` does not say the
  environment. Elsewhere, logging in with what was typed would reveal whether the email already had an account (with
  another person's password it would give `invalid_credentials`).
- **The `character_busy` wait** is done by `AccountFlow.enter` (every `busy_retry_s` = 3 s for `busy_timeout_s` = 30 s,
  with the `busy_waiting` signal for the countdown and `cancel_enter`), for the selection and for the bot.
- **`ensure_character`** looks for the character by the `NameRules` key ("aneira" finds "Anéira") and restores one
  deleted within the grace period instead of trying to create it (it would give `name_taken`). Without a requested
  realm it uses the account's in that world and, if it has none, Vardheim.
- **The export** is saved in Downloads (or, if there is none, in `user://`) with the `Content-Disposition` name
  cleaned (only letters, digits, `.`, `-` and `_`, ending in `.json`; otherwise, `eldmark-datos.json`).
- **An invalid platform URL** (`http://` outside this machine, without a scheme…) is kept in
  `ClientConfig` with a warning: the bot fails with its reason (`bad_url`) instead of entering without the platform, and
  the title screen says so. No call goes out.
- **DTLS without a readable certificate:** `NetClient.start` returns `ERR_INVALID_DATA` and does not connect in the
  clear.
- **Askarra always shows "Próximamente"** in creation (§0): the client does not know `ELDMARK_OPEN_REALMS`; if the
  platform opens it before the client, creation gives `realm_closed`.
- **Emblems, capital and lore** in creation are provisional text (from world.md) with the faction's color: the SVGs of
  `RealmCatalog.emblem_path` do not exist yet (UI-02, ART-21).
- **The character's zone in the list:** "Vado Gris" and "Mundo de pruebas" by id; any other, the capitalized id (there
  are no zone names in the shared data yet).

**Tests** (Godot, all new or extended):

| File | Tests | What |
|---|---|---|
| `test_client_config.gd` | 9 new (26) | Modes and priority with `--title`/`--platform` (editor: sandbox; export: title), options for the bot with an account, `--world`, `--dtls-*`, URL rules (https, http only to loopback, "127.0.0.1.example.org" is not), `duplicate_config` and that `boot.gd` does not warn |
| `test_platform_api.gd` | 14 | Refresh on 401 and the call repeated; early refresh; **two calls that expire at once** (and two with 401 at once) make a single refresh; refresh rejected → `session_lost` once and session forgotten; with no network, the session continues; without a session nothing goes out; `AccountSession`; the error map of §4.1; odd responses (204, broken JSON, non-UTF-8, Markdown, `Retry-After`) without engine errors; with `FakeHttpServer`, the headers (`Authorization`, `X-Eldmark-Protocol`, `X-Eldmark-Build`, `Content-Type`) and the bodies; `http://` outside this machine does not go out; closed port → `network` |
| `test_account_flow.gd` | 16 | `login` (normalized email), `ensure_character` (by the name's key, creates with a people, valid default appearance and the first template, the account's realm or the requested one, restores a deleted one), `enter` → `ClientConfig` with a ticket (id > 2^53, DTLS, without `loadout`, the original one untouched), `character_busy` retried, deadline and cancellation, responses that are not understood, strict ids and base64; the bot: without `--login` → 1 and `missing_login`, unreadable password, bad credentials and `zone_unavailable` → 1 with the `code`, suspended account → 1; **end to end in the process**: the bot creates its character and enters with the signed ticket in a `ZoneServer` with `FakeZonePlatform` and `TicketAuthProvider` (the claim carries its id) and exits with 0; `--bots --platform` → 1 |
| `test_front_screens.gd` | 13 | Title (Entrar only with email and password, Enter, status, recover and Esc), create account (password, age, the three texts and the exact body), new texts, sanctioned account, selection (names, level and zone, deleted ones in gray, slots, figure with its appearance, **Entrar disabled without a character**, **delete by typing the name**, restore, arrows, Enter, Del, countdown), creation (realm fixed, Askarra, valid appearances on changing each field and 50 random ones per people, **template**, name with `NameRules` and `name-check`, Esc) and rename |
| `test_front_main.gd` | 12 | With the real scene: title → selection and the remembered email without the password or tokens; bad password; sanctioned account (export to a file, delete, log out); new texts accepted with the versions from `/v1/legal`; Entrar → `OnlineMain` with a ticket and `from_front`; forced rename; `character_busy` countdown; create (with `name-check`), delete and restore; log out and lost session; registration that only logs in against a local platform; the return from the zone with the reason; `OnlineMain` with `from_front` that returns to `FrontMain` and never to `RealmSelect` |
| `test_net_client.gd` | 2 new | **The HELLO carries the ticket**, the `character_id` (> 2^53), the character's realm and name; an unreadable DTLS certificate does not connect |
| `test_client_launcher.gd` | 1 new | The project started with `--title --platform=<closed port>` mounts `FrontMain` without errors and says "Sin conexión con el servidor" |

Checked with the mutation it should catch: without the in-flight refresh guard, the two simultaneous-call tests fail
(two refreshes). Tests touching what changed remain correct: `test_online_main`, `test_realm_select`, `test_bot_swarm`,
`test_architecture`, `test_export_config`, `test_client_settings`, `test_ui_components`, `test_net_loopback`,
`test_net_harness`, `test_net_processes`, `test_local_server_launcher`, `test_bot_cheat`, `test_loadout_net`,
`test_server_main`, `test_zone_server_platform`, `test_platform_client` and `test_handoff_ticket`. The entire Godot
suite has not been run. Go does not change (`gofmt` and `go vet` clean).

**Against the real platform** (by hand, `scratchpad/p8/real_platform.sh`, not in the repository): ephemeral PostgreSQL
16, `migrate up`, `admin bootstrap` and `create-account`, `serve` with `ELDMARK_HEARTBEAT_S=1`, a `test_world` zone
with `--platform` and three `--bot --platform` bots: the first logs in, creates "Probador" in Solmarch
(`--realm=solmarch`) and enters; the second finds it and enters again (two tickets, both consumed; on exit, the lease
is left free); the third, with a bad password, exits with 1 and `invalid_credentials` in the report. The windowless
title screen against that platform reads the status ("En línea · Eld"). All of the client's requests give 2xx (except
the intended 401).

**Measured** (this machine, 4 cores, Godot 4.7.2 headless, Go 1.24.7, PostgreSQL 16.15):

| What | Result |
|---|---|
| The bot's login, list, creation and `enter` against the real platform (production argon2id) | 229 ms; with the character already created, 145 ms |
| `test_account_flow.gd` | 16 tests in 21 s; the end-to-end one, 6.9 s |
| `test_front_main.gd` · `test_front_screens.gd` · `test_platform_api.gd` | 20 s · 14 s · 14 s (each file with the runner's startup, about 11 s) |
| The return from `OnlineMain` to `FrontMain` after failing to connect | 3.5 s (ENet's connection deadline) |

**Unverified:** the title screen with a window and mouse (headless does not draw: the figure, dragging and Tab focus
belong to §15's visual review); TLS with the pinned certificate (`eldmark/platform/ca_cert`: a TLS failure logs an
engine error, §10.1, so it has no Godot test); real DTLS (P9c); refresh against the Go platform (the token lasts 15
min and the tests use the fake one).

**Left for later:** the title screen's background, logo and music (ART-21) and its visual review (user); more
appearance pieces and bodies (ART-20); the zone loading the chosen appearance (progression.md P5a, UI-24's criterion);
DTLS in the zone and its measurement (P9c); the end-to-end test with the Go platform (P10).

### 19.17 Integration of the phase 5 lanes

**What exists.** `wip/fase5-zona` (P4, P5, P6 and P7b from here; P1, P2, P4 and P5a–P5d from progression.md) brings the
other two lanes together with two `--no-ff` merges: `wip/fase5-almacen` (P9b, progression.md P7 and P9a, up to
`1972199`) and `wip/fase5-cliente` (progression.md P6 and P8, up to `c755f7b`). No code file changed in two lanes at the
same time: the conflicts were all documentation and were resolved keeping both sides.

- **§19 sections.** Each lane's were numbered from the last one it saw; they stay in the order of the merges and with
  their references up to date (in this document, in progression.md, in backlog.md, in README.md and in progression.md
  §14.3's comments). Here: §19.13 P9b (was §19.11), §19.14 what progression.md P7 leaves (§19.12), §19.15 P9a (§19.13)
  and §19.16 P8 (§19.9); in progression.md, §19.17 P7 (§19.12), §19.18 what P9a leaves (§19.13) and §19.19 P6 (§19.10).
  The backlog's citations "platform.md §19, "P8 · cliente"" become §19.16.
- **Backlog.** Where the two lanes added their "Hecho" (done) to the same item (PRG-07, PRG-12, PRG-16, SOC-14, SOC-17,
  SOC-18, TEC-25 and TEC-27) both go, in package order; in TEC-25 the two "Faltan" (missing) are merged into one
  ("Falta la prueba del kill -9"). With the three lanes together, three "Terminado cuando" (done when) that none met
  alone are met and closed: PRG-13 (the level is now saved), PRG-14 (creation offers each realm's people) and ART-19
  (applying 100 at random and the server not letting out-of-range indexes through). UI-24 and TEC-25 gain their note
  and stay open.
- **Fixes.** There was no need to touch the game's code or the platform's: `--import` changes nothing (the `.uid`s came
  from each lane) and all tests pass as they are. What goes stale on merging: `platform/deploy/dev.sh`'s help said that
  the zone's `--platform` and the client with an account "would arrive" with P4 and P8, and README.md did not describe
  the zone options with the platform (`--platform`, `--world`, `--channel`, `--public-address`, `--save-interval`,
  `--replace`, the secrets and the exit codes 1 and 3), which it now has in "Servidor dedicado" (dedicated server).

**Checked by hand against the real platform** (`scratchpad/int/real_platform.sh`, not in the repository: the one from
§19.16 on this branch, with the zone's console through a FIFO): ephemeral PostgreSQL 16 with `migrate up` (up to
`0010_progress`), `serve` with the real progress store, a `test_world` zone with `--platform`, `--console` and
`--save-interval=5`, and three `--bot --platform` bots.

1. The first logs in, creates "Probador" in Solmarch (`race_solmarch` and its 8 B in `character_progress`) and enters:
   the zone gives it the kit (STARTER_KIT operation with its four item events) and the bot receives the
   INVENTORY_FULL, two WALLET_UPDATE and a PROGRESS_UPDATE, with no malformed packet.
2. With the bot inside, the zone's console sends `xp_add Probador 30000`, `item_give Probador potion_health 2` and
   `currency_add Probador gold 75`: three GM operations with `source: console`, note and `detail` (in `xp_add`,
   `level_before` 1 and `level_after` 11), which go out in the critical save and pass S1–S8. The database ends with
   level 11 and 30 000 XP, the two new potions in slot 2 of the bag (event with its uid), 75 gold with its ledger entry
   and their three `op:<op_id>` rows in `audit_log` (target by `character_id`, `args` without names); the bot receives
   one more INVENTORY_DELTA, WALLET_UPDATE and PROGRESS_UPDATE.
3. On exit, the final save and the release (`save_version` 4, lease free). The second bot finds the character, enters
   with another ticket and the claim brings what was saved: same level, items and balances, and leaving saves it again
   changing nothing but the played time (`save_version` 7).
4. The third, with a bad password, exits with 1 and `invalid_credentials`; the windowless title screen reads the
   status.

**Tests.** Go: `gofmt -l` and `go vet` clean and `go test -race -count=1 ./...` entirely green (28 packages with tests;
the slowest, `platform/deploy`, 17–19 s), after the first merge and at the end, with `dev.sh` touched up. Godot, after
`--import`, by filters (each run loads all test files, so none fails to compile): the areas the lanes touch,
`platform` (67), `progress` (109), `save` (41), `auth` (31), `test_zone_server` (86), `inventory` (48),
`net_messages` (95), `test_front` (26), `test_account_flow` (16), `test_client_` (74), `test_online_main` (15),
`test_net_client` (34), `test_appearance` (6), `hud` (82), `test_character_` (36) and `test_architecture` (19); and
the files that a lane changed or that use what changed, `test_loadout`, `test_consumables_server`, `test_bot_cheat`,
`test_projectile_loopback`, `test_combat_resolver`, `test_combat_server`, `test_hfsm_brain`, `test_chat`,
`test_command_registry`, `test_war_`, `test_zone_moderation`, `test_zone_process_shutdown`, `test_handoff_ticket`,
`test_server_`, `test_item_`, `test_currency_rules`, `test_action_machine_weapons`, `test_level_curve`,
`test_progression`, `test_bot_swarm`, `test_net_processes`, `test_realm_select`, `test_remote_world`,
`test_nameplates`, `test_export_config`, `test_local_server_launcher`, `test_net_loopback`, `test_net_harness`,
`test_siege_clients`, `test_ui_`, `test_social_menu`, `test_hints`, `test_ability_input`, `test_party_`,
`test_combat_loopback` and `test_fortress_loopback`. In total, 1317 distinct tests from 118 files, all correct on the
first try. The entire Godot suite has not been run.

**Left for later:** the end-to-end progress tests (progression.md P8: `test_progress_loopback`,
`test_progress_platform_loopback`, `--bot-scenario=progress` and `platform/e2e/progress_test.go`), DTLS in the zone
(P9c) and the end-to-end test in CI (P10); what is pending on the user for each package (visual review, legal texts,
the VPS).

### 19.18 P9c · DTLS (TEC-27)

**What exists.** The zone side of the contract of §10.2 (the client side was left by P8, §19.16), the swarm with a
certificate and the TEC-27 measurement campaign:

| Piece | Content |
|---|---|
| `NetTransport` | `host(port, max_peers, dtls: TLSOptions = null)`: `dtls_server_setup(dtls)` right after `create_server` and before `GuardedEnetPeer`, which filters what arrives already decrypted in the same way. `is_dtls()`. **A DTLS client does not start the disconnect** (below) |
| `ZoneDtls` (`scripts/server/zone_dtls.gd`, new) | `load_files(cert, key)` and `from_pem`: the PEM as is (`certificate_pem`, with its chain if it has one), the CN (`common_name`) and `server_options` (`TLSOptions.server`), or `error` with the reason. It reads the CN from the DER with a minimal ASN.1 reader (`certificate_fields`, `pem_blocks`), checks that the key is the certificate's (the `subjectPublicKeyInfo` against `CryptoKey.save_to_string(true)`) and does not hand Godot a PEM it has not understood first (Godot logs an engine error with a broken one) |
| `ServerConfig` · `ServerMain` · `ZoneServer` | `ServerConfig.dtls: ZoneDtls` (not set from arguments). `ServerMain._load_dtls` loads it from `--dtls-cert` and `--dtls-key` before loading the zone, with or without the platform; if one is missing, it is not read, has no CN or the key is not its own, it exits with code 1. `ZoneServer.start` opens the port with `config.dtls.server_options`; its report gains `dtls`; the "listening on the port" line says "con DTLS" |
| `ZonePlatform.registration_body` | `dtls_cert_pem` (the PEM) and `dtls_name` (the CN); without DTLS, null as before |
| `BotSwarm` · `SwarmBot` | `--bots` admits `--dtls-cert=<pem> --dtls-name=<cn>`: the swarm pins the certificate once (`NetClient.dtls_options`) and each `SwarmBot.setup(index, config, dtls)` passes it to `connect_to`. Without `--dtls-name` or with an unreadable certificate, code 1 without connecting in the clear. The report gains `dtls` |
| `tools/load_test.gd` | `--dtls` (with the tests' certificate, or `--dtls-cert`, `--dtls-key` and `--dtls-name`) and `--dtls-compare`, the campaign: the scenario without and with DTLS, alternating, `--repeat` times (by default, 64 real bots grouped into two swarms, no fakes, 60 s, two of each), and `dtls_comparison` with the criterion |
| `tests/fixtures/dtls/` | Test PEMs (OpenSSL 3.0, 100 years): `zone_*` (RSA 2048, CN and SAN `zona-pruebas.eldmark.test`), `other_*` (EC P-256) and `no_cn_cert.pem`. `.gitignore` already lets them in (`!tests/fixtures/**/*.pem`) and `check_secrets.sh` does not look in `tests/` |
| `platform/deploy/docker-compose.yml` | It already passed `--dtls-*` (P9b); the secrets' comment says how to make the certificate |

**The disconnect is started by the server.** Godot's DTLS server (`ENetDTLSServer` in
`thirdparty/enet/enet_godot.cpp`) forgets a peer's session as soon as ENet considers it disconnected. If the
disconnect is started by the client (`peer_disconnect_later`), the server receives its DISCONNECT, acknowledges it and
forgets the session; a round trip later the client's DTLS close alert arrives (when its `ENetMultiplayerPeer` closes),
the server takes it for a
new handshake and the engine logs `TLS handshake error: -30464` (`MBEDTLS_ERR_SSL_UNEXPECTED_MESSAGE`). Measured with
the one-process probe: 6 of 6 disconnects started by the client give the error; 0 of 6 started by the server (its
DISCONNECT, the client's acknowledgment and its close alert arrive together) and 0 of 6 with the client closing
abruptly (`close`: the DISCONNECT and the alert go out in the same send). That is why, in `NetTransport`, **a DTLS
client does not call `peer_disconnect_later`**: `disconnect_after_flush` empties its queue and waits; the server
answers the CLIENT_LEAVE with its own `disconnect_after_flush` (it already did). If the server does not cut off within
`FORCE_DISCONNECT_TICKS` (60), the client closes the whole connection (`_close_enet_keeping_events`: the real
`ENetMultiplayerPeer.close()`, without losing the `peer_disconnected` that comes out in that `poll`). In the clear
nothing changes. The same in tests: closing the server before its clients makes the client's close alert go to an
already closed port and the next send fail with `bio_send` (the error that §10.2 already warned about): clients are
closed first.

**Deviations and implementation decisions:**

- **The name is read from the DER** (§19.8 left the choice between that and asking the zone for `--dtls-name`): the
  zone only has `--dtls-cert` and `--dtls-key`, as §10.2 says, and there is no way for the registration's name and the
  certificate's to differ. A certificate without a CN is not valid, even if it carries `subjectAltName` (mbedtls would
  compare against the SAN, but §10.2 dictates the CN).
- **`ServerConfig.dtls`** (§14.3 does not name it): the loaded certificate travels with the configuration, which
  already reaches `ZoneServer.start` and `ZonePlatform.registration_body`; `ZoneServer.start` does not change its
  signature. It is the only change in `zone_server.gd` (the call to `host` and the report field), after progression.md
  P5d.
- **Extra API** (§14.3 and networking.md §17 do not name it): `NetTransport.is_dtls()`, `SwarmBot.setup(…, dtls)`, all of
  `ZoneDtls`, the `dtls` field of the zone and swarm reports, and in `NetHarness.start_bot` a `configure: Callable`
  at the end (for the test bot's certificate).
- **`SwarmBot` sends CLIENT_READY 1 s after connecting** (`READY_DELAY_TICKS`), like a client loading the zone. The
  campaign uncovered it, in the clear: in 2 of 3 passes of 64 bots, a bot was left loading until the zone kicked it at
  60 s ("se agotó el tiempo de carga", i.e. the load time ran out) with a "packet foreign to the protocol" warning.
  SceneMultiplayer's authentication acknowledgment goes on ENet channel 0 and CLIENT_READY on 3, which are not ordered
  with respect to each other; with 64 bots on the machine the server's UDP buffer (212 KB by default) fills up during
  its 40–70 ms stalls (the `RcvbufErrors` counter in `/proc/net/snmp` rises during the campaign), a lost
  acknowledgment arrives after its CLIENT_READY and `GuardedEnetPeer` (as SceneMultiplayer would) drops the
  CLIENT_READY. A real client sends CLIENT_READY after loading the zone, seconds later. It is not about DTLS, but it
  invalidated the passes (63 players instead of 64).
- **The cost of encrypting what is sent falls in the section that sends**, not in `flush`:
  `ENetMultiplayerPeer.put_packet` flushes the host on every packet. In the zone, that of snapshots is in the
  `snapshot` section and that of events in `combat_events`; `flush` stays at a few µs.

**Tests** (Godot, new):

| File | Tests | What |
|---|---|---|
| `test_dtls_loopback.gd` | 7 | **Loopback with DTLS and `GuardedEnetPeer`** (§15): handshake, 1200 B packets over the unreliable channels and a reliable 3000 B one (fragmented) in both directions, intact and with no filter discards; the exit with CLIENT_LEAVE (the server cuts off, before the deadline) and 30 more ticks with no engine errors. A client whose exit nobody answers does not start the disconnect, closes everything at 60 ticks, both see it and it reconnects. Another certificate, another name or in the clear: it does not connect and the server never gets to see a peer (the only one that admits engine errors: the handshake's). `ZoneServer` with `config.dtls` and a predicting `NetClient` (`--dtls-cert`/`--dtls-name`): plays, receives snapshots and exits with CLIENT_LEAVE. **The swarm with a certificate** (§15): 4 bots enter, play, the report says `dtls`, exit with code 0 and the zone is left empty. Without `--dtls-name` or with an unreadable certificate, code 1 and no bot. **The real dedicated server** in another process with `--dtls-cert --dtls-key` (and `--stop-file`): loads the certificate, listens "con DTLS", a swarm of 2 enters, the report says `dtls` and its log has no errors |
| `test_zone_dtls.gd` | 11 | `ZoneDtls`: the CN and the key of the test certificate; an EC one with the CN in front; a key that is not its own (both ways); without a CN; missing files and broken PEMs, each with its reason and no engine errors; a DER cut every 7 B or with an impossible length does not break the reader; strings and bad base64. The registration with the PEM and the CN (and null without DTLS), JSON round trip. Two servers in another process that exit with 1 and say so (missing key; another certificate's key). `dtls_comparison` (averages, increase, criterion, no passes) and the options that `load_test` passes |

The ones touching what changed remain correct: `test_net_sim` (30), `test_net_loopback` (14), `test_net_client` (34),
`test_bot_swarm` (8), `test_siege_clients` (3), `test_bot_threat_sight`, `test_progress_messages`,
`test_server_config`, `test_server_main` (15), `test_net_processes` (10), `test_account_flow` (16),
`test_zone_process_shutdown`, `test_war_platform_process`, `test_platform_client` (14), `test_zone_server_platform`
(13), `test_load_test` (18) and `test_architecture` (19). The entire Godot suite has not been run. Go does not change
(the platform already validated and stored the certificate, P3).

**Measured** (this machine, 4 cores, Godot 4.7.2 headless; detail in networking.md §14). Cost per packet, bytes, the
handshake and the disconnects, with one-process probes that are not in the repository (`scratchpad/p9c/`:
`probe_cost.gd`, `probe_relay.gd` and `probe_loopback.gd`); the load, with `tools/load_test.gd --dtls-compare`:

| What | Result |
|---|---|
| TEC-27: 64 real bots, three passes without and three with DTLS (`--dtls-compare --repeat=3`) | tick p99 from 26.9 to **28.5 ms (+5.9 %, meets the provisional 10 % criterion)**; p50 from 15.0 to 15.5 ms; `net` +16 %, `snapshot` +4 % |
| The same with 40 bots (Vado Gris's capacity), two passes of each | p99 from 15.9 to 15.4 ms (−3.3 %, noise); p50 from 9.0 to 9.0 ms |
| CPU per packet (probe, 16 clients) | receiving an input: +2.2 µs (6.8 → 9.0); sending a 1200 B snapshot: +5.1 µs (7.2 → 12.3) |
| Bytes per datagram (UDP relay) | +29 B (ChaCha20-Poly1305); full snapshot at 1240 B of UDP; the 1200 B cap does not change |
| Handshake | Zone CPU per client: 4.3 ms with RSA 2048, 2.0 ms with EC P-256; connecting, 0.6 s (16 at once, 1.6 s) |
| `--filter=dtls` (these two files and the 2 from P8) | 20 tests in 35 s with the runner's load; the longest, the dedicated server with the swarm, 7 s |

**Unverified:** against the real Go platform with `staging` (registration with a certificate is tested by P3 in Go and
here `registration_body`; the `enter` that returns it, by P2); the client with a window connecting over DTLS to a
remote zone (the real network, with losses: the disconnect that the server starts is designed for that, but it has
only been measured on loopback); IPv6.

**Left for later:** the user choosing TEC-27's criterion (§0: relative, met; absolute, not met even without DTLS); the
real certificates for each zone on the VPS (TEC-20, with the compose command) and a high `net.core.rmem_default`
there; the end-to-end test (P10).

### 19.19 P10 · end to end

**What exists.** The two tests of §15 with the real platform (that of `serve`) in the test's process, an ephemeral
PostgreSQL and real Godot processes (a `test_world` zone with `--platform` and bots with an account), and their CI
job. No change in Godot or in what the platform does:

| Piece | Content |
|---|---|
| `platform/e2e/` | Build tag `e2e` (`go test -tags e2e ./e2e`): `harness_test.go` (the harness), `platform_test.go` (`TestEnterAndSave` and `TestZoneCrash`) and `proc_linux_test.go` (`Pdeathsig`: the kernel kills zones and bots if the test dies without stopping them; outside Linux, `proc_other_test.go` does nothing). `doc.go`, without a tag, so that the package exists with `go vet ./...` |
| `TestMain` | `ELDMARK_GODOT` (without it, `t.Skip`; with `ELDMARK_REQUIRE_GODOT=1`, CI, it fails), `godot --headless --path <root> --import` once (if it fails, all tests fail with the end of its log) and `testdb.Main` |
| `New(t)` | New database (`testdb.New`) and the configuration of §15 through `config.Load`: `ELDMARK_ENV=test`, a random `1:test_world:0` token, a random ticket key, `ELDMARK_ENTRY_ZONES=vardheim=test_world,solmarch=test_world`, `ELDMARK_HEARTBEAT_S=1`, `ELDMARK_LEASE_TTL_S=6` (and the `Option`s that change any). It mounts `serve`'s services (`services.Mount`), opens both APIs on free ports and returns with startup done. When the test ends it stops, in this order, the Godot processes still alive, the platform and the database; if the test failed, it copies the end of each log to its output |
| Accounts, zones and bots | `NewAccount` (registration through the public API with the three texts accepted and the password in a 0600 file); `StartZone(args…)` (`--server --zone=test_world --world=1 --port=<free UDP> --platform=<internal API> --stop-file --report`, with `ELDMARK_ZONE_TOKEN` and `ELDMARK_TICKET_KEYS` in the environment and no other inherited `ELDMARK_*`); `Zone.WaitLive` (the `live` instance with its `public_port`); `Zone.Stop` (the orderly shutdown through `--stop-file`, with its exit code); `Process.Kill` (SIGKILL, returns the time from before the signal); `StartBot(acc, args…)` (`--bot --platform=<public API> --login --password-file --report`); `Bot.ReadReport` (the report's `platform` and the whole report in `Raw`) |
| Queries | `WaitFor` (every 100 ms, with a deadline), `WaitCharacter`, `Scalar`, `Exists`, `PlatformLogContains`, `Process.LogContains` and **`CheckBooks`**: by definition, Σ `count_delta` of `item_events` = Σ `count` of living items; per currency, Σ `delta` of `ledger_entries` = balance; a single STARTER_KIT operation and some living item |
| Logs | Each test leaves `plataforma.log` (`slog` JSON, INFO level), `zonaN.log`/`.json` and `botN.log`/`.json` in a temporary folder or, with `ELDMARK_E2E_ARTIFACTS=<folder>`, in `<folder>/<test>/` (emptied at the start), where they remain |
| `internal/services` (new) | `Mount` and `ProgressStore`, which were `mountServices` and `progressStore` in `cmd/eldmark-platform/services.go` (file moved; `serve`, `admin` and their tests call them there): this way the harness mounts exactly what `serve` does, without copying it. §2.1 names it |
| CI | "Plataforma e2e" job in `tests.yml`: checkout without LFS, the LFS and Godot caches with the Godot jobs' keys (`git lfs pull` fetches what is missing; Godot is only downloaded if the cache misses), `setup-go`, `ubuntu-latest`'s PostgreSQL, `ELDMARK_GODOT`, `ELDMARK_REQUIRE_PG=1`, `ELDMARK_REQUIRE_GODOT=1` and `go test -tags e2e -count=1 -v -timeout 14m ./e2e`; the logs, in `$RUNNER_TEMP/e2e` (outside the project, which Godot imports), are uploaded as an artifact on failure and the result and timing lines go to the summary. The "Plataforma" job adds `go vet -tags e2e ./e2e` |

**The tests.**

- **`TestEnterAndSave`:** the zone becomes `live`; a bot creates "Viajera", enters, plays 300 ticks and exits with code
  0 (report without `code` and with `created`). Then, with no wait longer than 20 s: the lease is left free
  (`zone_instance_id` null, `released_at` set) with `last_save_version > 0`; `character_progress` with `save_version
  > 0`, `saved_at` set and `last_zone_id = 'test_world'`; the lease was claimed by that instance; a single ticket
  consumed; `CheckBooks`; and the orderly shutdown exits with 0 and leaves the instance `stopped`.
- **`TestZoneCrash`:** zone with `--save-interval=5`; a bot creates "Superviviente" and plays. After its first
  `saved_at` (the kit's critical save, on arrival) it waits 7 s (more than 5 s + 1 s), `kill -9` on the zone (and on
  the bot, which does not have to reconnect) and starts another with `--save-interval=5`. With the new one `live`: it
  is another instance, the old one is `lost`, and the last `saved_at` is **later than the first** (it came from a
  checkpoint) and **`kill − saved_at` < 5 s + 1 s**; `CheckBooks` (what the old one left, with nothing half done). A
  second bot with the same account enters and its character ends up leased **by the new instance**; it exits with 0,
  its report brings the same `character_id` without `created`; the new one's orderly shutdown exits with 0 and
  `CheckBooks` again (the kit is not repeated on returning).
- **That they catch what they should** (hand mutations, not kept in the repository): with `--save-interval=60` on the
  old zone, `TestZoneCrash` fails ("no checkpoint after the first save", `kill − saved_at` = 7.1 s); with an extra
  living item inserted by hand, `CheckBooks` fails ("potion_health: 3 in the ledger and 4 saved").

**For the following packages.**

- **progression.md P8:** `platform/e2e/progress_test.go` goes in this package, with the `e2e` tag, and uses the harness
  as is: `New(t)`, `NewAccount`, `StartZone("--debug-commands", …)`, `StartBot(acc, "--bot-scenario=progress", …)`,
  `Bot.ReadReport` (the whole report in `Raw`), `Process.Kill` and `CheckBooks` (the accounts for its
  `TestProgressCrash`). The `admin` account has no helper: SQL on `h.Pool` or the `admin` command with `--actor`.
  `Load` is compared with `progress.New(rules, nil).Load` on `h.Pool` (or with the next claim).

**Deviations and implementation decisions:**

- **`--path`:** §15 says `godot --headless --path ..`, but the tests run in `platform/e2e/`; the harness uses the
  repository root (`../..`, where `project.godot` is) for the import, zones and bots.
- **The kill does not go right after the first `saved_at`:** that first one is the arrival's critical save (the kit),
  and a kill right away would satisfy `kill − saved_at < 6 s` with no checkpoint at all. The test waits 7 s and also
  requires a `saved_at` later than the first, so without checkpoints it fails (checked above).
- **Who moves the old one to `lost`:** in all passes the new one's registration got a 409 `instance_alive` and retried
  at 2 s, but before that the lost-instances job (every `min(5 s, HEARTBEAT_S)` = 1 s) had already declared it lost
  ("instancia perdida: sin latido", i.e. lost instance: no heartbeat); the path in which the registration itself moves
  it to `lost` (§5.3) does not occur with `HEARTBEAT_S=1`. Both are valid and the test requires neither: it notes which
  in its output. That path is tested by P3 in Go.
- **Extra, which §15 did not ask for:** `CheckBooks` in both tests (TEC-25's "without duplicating anything"), the
  release, the consumed ticket, the claiming instance and the orderly shutdown with `stopped` in `TestEnterAndSave`,
  and the second bot's report in `TestZoneCrash`. New variables: `ELDMARK_REQUIRE_GODOT` and `ELDMARK_E2E_ARTIFACTS`.
- **The bots only play as much as needed:** 300 ticks for `TestEnterAndSave`'s and 240 for `TestZoneCrash`'s second one
  (with 600, the test took 32 s).

**Tests.** The two new ones pass in seven consecutive runs (one with `-race`, no races). Without `ELDMARK_GODOT` they
are skipped, and with `ELDMARK_REQUIRE_GODOT=1` they fail. The whole Go suite passes with the `internal/services` fix
(`gofmt -l` and `go vet` clean, also with `-tags e2e`; `go test -race -count=1 ./...` green, 28 packages with tests).
Godot does not change: `TestMain`'s import touches no file in the repository.

**Measured** (this machine, 4 cores, Go 1.24.7, PostgreSQL 16, Godot 4.7.2 headless):

| What | Result |
|---|---|
| `TestEnterAndSave` | 11.2–12.5 s (seven runs): platform ready in 0.1–1.1 s, zone `live` about 2 s after launching it, the 300-tick bot from launch to exit 8–9 s, orderly shutdown 0.3–0.9 s |
| `TestZoneCrash` | 24.8–26.2 s (six runs with the second bot at 240 ticks): first save about 3.5–4 s after launching the bot; the new one `live` about 4.3 s after the kill (a 409 and the retry at 2 s); `kill − saved_at` from 0.47 to 1.14 s; the second bot, inside about 3.5 s after launching it |
| Both with `-race` | 12.5 s and 25.1 s |
| `TestMain`'s import | 6.5–10.7 s with the project already imported (in CI, without `.godot/`, unmeasured) |
| `go test -tags e2e ./e2e` as a whole | 44–46 s with the compilation cached and the import |

Both are below the goal of 30 s per test (§15): the 60 s cap is not needed.

**Unverified:** the "Plataforma e2e" job on GitHub (`ubuntu-latest` without root, the whole import without the
`.godot/` cache and the timings there); end-to-end DTLS (the zone with `--dtls-*` and the bot that pins it: P9c tested
it against the fake and a dedicated server, not against the Go platform).

**Left for later:** `platform/e2e/progress_test.go` (progression.md P8); seeing "Plataforma e2e" green on GitHub and
marking it as a required check in the branch protection (user).
