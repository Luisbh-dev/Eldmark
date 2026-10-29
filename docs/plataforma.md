# Eldmark · Fase 5: diseño de la plataforma

Diseño del paso 5 de la [hoja de ruta](vision.md#hoja-de-ruta): cuentas, personajes y guardado en base de datos.
Cubre el servicio de plataforma y todo lo que pasa por él: TEC-22 a TEC-25, TEC-27, TEC-28, TEC-41, TEC-43, PRG-41,
SOC-13 a SOC-18, GUE-19 y el cliente de UI-22 a UI-24.

Se apoya en la red ([red.md](red.md): §3 conexión, §5.3 autenticación, §12 seguridad, §15 extensión, §17 contratos),
el combate ([combate.md](combate.md) §1 y §5), el fuerte ([fuerte.md](fuerte.md) §5) y lo social
([social.md](social.md) §8 a §11). Objetos, inventario, monedas, niveles y razas son de `docs/progresion.md`
(PRG-02, PRG-10 a PRG-14, en marcha a la vez); aquí solo la frontera (§7.5). La configuración de combate que se
guarda (CMB-30) es de `docs/habilidades.md`; aquí solo su hueco.

Lo que se da por comprobado se midió en esta máquina con sondas en `build/` (Go 1.24.7, PostgreSQL 16.15, Godot
4.7.2 headless). Lo que no, está marcado «sin comprobar» y en §16.

## 0. Decisiones

Provisionales, **tomadas de noche** con la recomendación del backlog; están en «Decisiones tomadas» de
[backlog.md](backlog.md) con esa marca.

| Pregunta | Decisión |
|---|---|
| Tecnología del servicio | **Go + PostgreSQL**, servicio propio. Sin ORM ni framework web: `net/http` de la biblioteca estándar, `pgx` y `x/crypto/argon2` |
| Estrategia de guardado | **Punto de control cada 60 s** si hubo cambios, más escritura inmediata de los eventos críticos, al salir y al cerrar la zona; con arrendamiento, secuencia e idempotencia (§7) |
| Uno o varios mundos | **Un solo mundo** al lanzar (`world_id = 1`, «Eld»), con `world_id` en el esquema desde la primera migración |
| Cifrado cliente ↔ zona | **DTLS de ENet** si su coste medido (TEC-27) cabe; el certificado de la zona lo entrega la plataforma por HTTPS y el cliente lo ancla (§10.2). Sin DTLS no hay pruebas públicas |
| Reinos por cuenta | **Un reino por cuenta y mundo.** El cambio de toda la cuenta con 30 días de espera llega más adelante; en la fase 5 el reino solo se libera 30 días después de borrar el último personaje |
| Ignorar | **A la cuenta, en silencio** (social.md §10). El servidor filtra también los canales públicos (§9.3) |
| Retención del chat | **30 días** todos los canales, susurros incluidos; **1 año** lo copiado a un reporte o una sanción. Revisión legal antes de las pruebas públicas |

Decisiones de este documento que no estaban en el backlog (provisionales, de noche):

| Pregunta | Decisión |
|---|---|
| Inicio de sesión | Correo y contraseña; una sesión de juego activa por cuenta (la nueva cierra la anterior y expulsa a su personaje) |
| Contraseñas | argon2id, m = 19 456 KiB, t = 2, p = 1 (59 ms aquí); cadena PHC |
| Tokens | Opacos, aleatorios, guardados como SHA-256: acceso de 15 min y refresco de 12 h que rota. El cliente los guarda solo en memoria |
| Edad mínima | 16 años, declarada al crear la cuenta. **Revisión legal** |
| Huecos | 6 personajes por cuenta y mundo, ampliables con derechos (§11.3) |
| Reinos abiertos | Vardheim y Solmarch: el Vado Gris no admite Askarra, que sale como «Próximamente» |
| Borrado | Personaje: restaurable 7 días; su nombre, reservado esos 7 días y 30 más. Cuenta: 14 días de gracia |
| HTTPS | La plataforma habla HTTP; Caddy delante pone HTTPS con Let's Encrypt (§10.1) |

Quedan para el usuario: el modelo de negocio (PRG-41; el esquema admite cualquiera, §11.3), el proveedor y la región
del VPS, los textos legales definitivos y el dominio.

## 1. Piezas y qué decide quién

El cliente habla HTTPS con la API pública de la plataforma (:24680) y UDP (ENet con DTLS) con la zona; la zona habla
HTTP con la API interna (:24681, red privada); solo la plataforma toca PostgreSQL 16.

| Qué | Lo decide | Notas |
|---|---|---|
| Identidad, contraseña y sesión | Plataforma | La zona nunca ve contraseñas ni tokens de sesión |
| Reino, nombre, raza y apariencia | Plataforma, al crear el personaje | En la zona, `HELLO.realm` y `HELLO.name` se ignoran: mandan los del arrendamiento |
| A qué zona entra | Plataforma (`enter`) | La última si tiene un proceso vivo; si no, la de entrada de su reino |
| Si el billete vale | Zona (formato, firma, zona, caducidad) y plataforma (un solo uso, arrendamiento) | §5 |
| Estado del personaje en juego | Zona | La plataforma guarda lo que le mandan y no lo interpreta salvo §7.1 |
| Sanciones y roles | Plataforma | La zona los aplica al entrar, con el latido y en `ChatRouter` |
| Estado de las fortalezas | Zona | La plataforma lo guarda y lo devuelve al arrancar (§8) |
| Esquema y migraciones | Plataforma | Las zonas no tienen credenciales de la base |

```
Cliente                         Plataforma                            Zona
POST /v1/sessions ─────────────▶ sesión
POST /v1/characters/42/enter ──▶ sin arrendamiento vivo: billete
◀── host, puerto, billete (52 B), certificado DTLS
HELLO (character_id, billete) ────────────────────────────────────────▶ firma, zona, caducidad (VERIFYING)
                                ◀── POST /internal/v1/claims ────────── 
                                consume el billete, arrendamiento ────▶ personaje y lease_id
◀──────────────────────────────────────────────────────────── WELCOME (reino del personaje)
carga la zona, CLIENT_READY ──────────────────────────────────────────▶ alta con el estado guardado
                                ◀── PUT …/state: cada 60 s, críticos, al salir (release)
```

## 2. El servicio (TEC-22)
### 2.1 Estructura
```
platform/            go.mod: module eldmark/platform, go 1.24.0, toolchain go1.24.7 · .gdignore (Godot no la escanea)
  cmd/eldmark-platform/   subcomandos serve, migrate, admin
  internal/  config logx db httpx (enrutador, errores, límites) migrate (+ migrations/*.sql con embed) testdb
             passwords accounts names gamedata (*.json generados desde Godot) characters tickets zones
             persistence war social privacy mail
  e2e/  legal/ (terms-1.md, privacy-1.md, rules-1.md)  deploy/ (Dockerfile, docker-compose.yml, Caddyfile,
        *.env.example, dev.sh, backup.sh, restore_check.sh, pitr_check.sh)
```

`export_presets.cfg` añade `platform/*` al `exclude_filter` de los dos destinos y `test_export_config.gd` lo
comprueba como con `build/*`.

### 2.2 Dependencias
Tres, con versión fija: `github.com/jackc/pgx/v5` **v5.8.0** (driver y `pgxpool`), `golang.org/x/crypto` **v0.45.0**
(`argon2.IDKey`) y, indirecta, `golang.org/x/text` v0.31.0; las tres declaran `go 1.24.0`. **Las últimas no
sirven:** pgx v5.9+ pide Go 1.25 y x/crypto v0.50+ pide 1.25 o 1.26, y con `GOTOOLCHAIN=auto` Go intentaría bajarse
otro toolchain (comprobado). Las pruebas y la CI usan `GOTOOLCHAIN=local`. Los UUID salen de `crypto/rand` con
formato propio.

### 2.3 Configuración
Variables de entorno; cada secreto admite `<NOMBRE>_FILE` con la ruta de un archivo (secretos de Docker). Un valor
que falta o no se entiende **impide arrancar** con un mensaje en español.

| Variable | Por defecto | Notas |
|---|---|---|
| `ELDMARK_ENV` · `ELDMARK_DATABASE_URL` | `dev` · — | `dev`, `test`, `staging` o `production` · secreto |
| `ELDMARK_PUBLIC_ADDR` · `ELDMARK_INTERNAL_ADDR` · `ELDMARK_PUBLIC_URL` | `127.0.0.1:24680` · `127.0.0.1:24681` · `http://127.0.0.1:24680` | La interna, nunca en una interfaz pública · base de los enlaces de los correos |
| `ELDMARK_ZONE_TOKENS` | — | Secreto; lista separada por comas (dos durante una rotación) |
| `ELDMARK_TICKET_KEYS` · `ELDMARK_TICKET_SIGN_KEY` | — · la mayor | Secreto `1:<base64 de 32 B>,2:<…>` · id con el que se firma |
| `ELDMARK_ARGON2` | `m=19456,t=2,p=1` | En `test`, `m=8,t=1,p=1` |
| `ELDMARK_MIN_PROTOCOL` | el `PROTOCOL_VERSION` de la fase 5 | Por debajo, 426 |
| `ELDMARK_OPEN_REALMS` · `ELDMARK_ENTRY_ZONES` | `vardheim,solmarch` · `vardheim=vado_gris,solmarch=vado_gris` | Reinos en los que se crea · zona de entrada por reino |
| `ELDMARK_REQUIRE_VERIFIED_EMAIL` | `false` en dev y test; `true` en el resto | Para entrar al mundo |
| `ELDMARK_MAIL` · `ELDMARK_SMTP_URL` | `log` · — | `log` (tabla `outbound_mail`) o `smtp`; secreto `smtp://usuario:clave@host:587` |
| `ELDMARK_TLS_CERT_FILE` · `ELDMARK_TLS_KEY_FILE` | — | Opcional: HTTPS directo (pruebas del anclaje) |
| `ELDMARK_HEARTBEAT_S` · `ELDMARK_LEASE_TTL_S` | `5` · `30` | Una instancia sin latido durante 3 × `HEARTBEAT_S` se da por perdida |
| `ELDMARK_LEGAL_DIR` | `platform/legal` | Textos legales versionados |

**Registro:** `log/slog` con `JSONHandler` a la salida estándar. Campos: `time`, `level`, `msg`, `req` (id de
petición, también en `X-Request-Id`), `route`, `status`, `ms`, y `account` y `character` cuando se conocen.
**Nunca** se registran contraseñas, tokens, billetes, cuerpos ni texto del chat; el correo va enmascarado
(`a***@example.org`).

### 2.4 Migraciones
- `internal/migrate/migrations/NNNN_nombre.up.sql` y `.down.sql`, embebidos. 0001 a 0009 son de este documento (§3);
  **0010 a 0029, de `docs/progresion.md`**; después, por orden de llegada. Un número nunca se reutiliza.
- Tabla `schema_migrations (version int primary key, name text not null, checksum bytea not null, applied_at
  timestamptz not null default now())`. El ejecutor toma `pg_advisory_lock(4815162342)`, aplica cada archivo en su
  transacción y se niega a seguir si el SHA-256 de uno aplicado ha cambiado.
- `eldmark-platform migrate up|down N|status`. `serve` no migra: si la base no está en la última versión, no arranca
  y `/ready` dice por qué.
- CI: `up` → `down` hasta 0 → `up` en una base efímera, con el esquema final (`pg_dump -s`) igual.

### 2.5 Arranque y salud
- `GET /health`: 200 si el proceso vive (sin tocar la base). `GET /ready`: 200 si `select 1` responde en menos de 1
  s y las migraciones están al día; si no, 503 con el motivo.
- Al arrancar, `serve` da 30 s de gracia: `last_heartbeat_at = greatest(…, now())` en las instancias vivas y
  `expires_at = greatest(expires_at, now() + TTL)` en los arrendamientos. Una plataforma que vuelve tras caerse no
  da por muertas a las zonas que no pudieron latir.
- Trabajos periódicos en el mismo proceso (`time.Ticker` y `pg_try_advisory_lock`): zonas perdidas (5 s),
  retenciones y purgas (1 h).

### 2.6 Pruebas con una base de datos real efímera
Paquete `internal/testdb`. **No hace falta Docker** (aquí su demonio no corre). Comprobado:

| Paso | Cómo | Tiempo |
|---|---|---|
| Binarios | `ELDMARK_PG_BIN`; si no, `pg_config --bindir`; si no, el mayor `/usr/lib/postgresql/*/bin` | — |
| Usuario | `initdb` se niega a correr como root. Si `os.Geteuid() == 0`, cada orden va con `runuser -u postgres --` (o `ELDMARK_PG_USER`) y la carpeta se le cede con `chown` | — |
| Clúster | `initdb -D <tmp>/data -U eldmark --auth=trust -E UTF8 --no-locale --no-sync` en `os.MkdirTemp("", "eldpg-")` (ruta corta: el socket admite 107 B) | 0,6 s |
| Servidor | `pg_ctl -w -s start -o "-k <tmp> -c listen_addresses= -c fsync=off -c synchronous_commit=off -c full_page_writes=off"`: solo socket Unix, sin puertos que choquen entre suites | 0,12 s |
| Plantilla | Base `tmpl` con todas las migraciones, una vez por paquete en `TestMain` | — |
| Cada prueba | `create database t_<n> template tmpl` y `drop` al terminar | 60 ms |

- `testdb.Main(m)` en el `TestMain`; `testdb.New(t)` da un `*pgxpool.Pool` limpio; al acabar, `pg_ctl stop -m
  immediate` y se borra la carpeta. Sin binarios, `t.Skip`, salvo con `ELDMARK_REQUIRE_PG=1` (la CI), que falla;
  `ELDMARK_TEST_DATABASE_URL` usa un servidor ya levantado. La primera compilación con pgx tarda ~18 s: los < 30 s
  por paquete son con la caché caliente.
- **CI:** trabajo «Plataforma» en `.github/workflows/tests.yml`: `actions/setup-go` con `go-version-file:
  platform/go.mod`, `GOTOOLCHAIN=local`, `ELDMARK_REQUIRE_PG=1` y, en `platform/`, `go vet ./...` y `go test -p 2
  ./...` con el PostgreSQL de `ubuntu-latest` (sin comprobar; si falta, `apt-get install postgresql-16`).

## 3. Esquema SQL

Las tablas del juego llevan `world_id`; las de la cuenta, no. Reinos en `smallint` con los códigos de
`NetProtocol.Realm` (1 Vardheim, 2 Solmarch, 3 Askarra); en JSON, su id de texto (`"vardheim"`). `ts` abrevia aquí
`timestamptz` y `now_ts` `timestamptz not null default now()`; en los archivos van escritos enteros.

```sql
-- 0001_accounts
create table worlds (world_id smallint primary key, name text not null unique, created_at now_ts,
  status text not null default 'open' check (status in ('open','locked','maintenance')));
insert into worlds (world_id, name) values (1, 'Eld');
create table accounts (account_id bigint generated always as identity primary key, email text unique, password_hash text, -- null tras la purga
  email_verified_at ts, role text not null default 'player' check (role in ('player','moderator','gm','admin')),
  status text not null default 'active' check (status in ('active','pending_deletion','purged')), age_confirmed_at ts not null,
  failed_logins int not null default 0, locked_until ts, deletion_requested_at ts, purge_after ts, purged_at ts, created_at now_ts);
create table sessions (session_id bigint generated always as identity primary key, account_id bigint not null references accounts on delete cascade,
  family uuid not null, access_hash bytea not null unique, access_expires_at ts not null, refresh_hash bytea not null unique,
  refresh_expires_at ts not null, ip inet, user_agent text, client_protocol int, created_at now_ts, revoked_at ts, revoke_reason text);
create index on sessions (account_id) where revoked_at is null;
create table account_tokens (token_hash bytea primary key, account_id bigint not null references accounts on delete cascade,
  purpose text not null check (purpose in ('verify_email','reset_password','change_email')), new_email text,
  expires_at ts not null, used_at ts, created_at now_ts);
create table auth_events (id bigint generated always as identity primary key, account_id bigint references accounts on delete set null,
  kind text not null, ip inet, user_agent text, at now_ts);                    -- kind: register, login_ok, login_fail, locked…
create index on auth_events (at); create index on auth_events (account_id, at);
create table legal_documents (kind text not null check (kind in ('terms','privacy','rules')), version int not null, sha256 bytea not null,
  published_at now_ts, primary key (kind, version));
create table legal_acceptances (account_id bigint not null references accounts on delete cascade, kind text not null, version int not null,
  accepted_at now_ts, primary key (account_id, kind, version), foreign key (kind, version) references legal_documents);
create table consents (account_id bigint not null references accounts on delete cascade, granted boolean not null, updated_at now_ts,
  purpose text not null check (purpose in ('crash_reports','analytics')), primary key (account_id, purpose));
create table entitlements (entitlement_id bigint generated always as identity primary key,                       -- PRG-41
  account_id bigint not null references accounts on delete cascade, world_id smallint references worlds,      -- null: todos los mundos
  kind text not null check (kind in ('character_slots','expansion','cosmetic')), ref text not null default '',
  quantity int not null default 1 check (quantity > 0), source text not null check (source in ('grant','purchase','promo')),
  granted_at now_ts, expires_at ts, revoked_at ts);
create table outbound_mail (id bigint generated always as identity primary key, to_email text not null, template text not null,
  body text not null, created_at now_ts);                                       -- solo con ELDMARK_MAIL=log

-- 0002_characters
create table account_realms (account_id bigint not null references accounts on delete cascade, world_id smallint not null references worlds,
  realm smallint not null check (realm between 1 and 3), unlock_at ts, primary key (account_id, world_id));
create table characters (character_id bigint generated always as identity primary key, world_id smallint not null references worlds,
  account_id bigint not null references accounts, name text not null, name_key text not null,
  realm smallint not null check (realm between 1 and 3), race_id text not null, appearance bytea not null check (length(appearance) <= 64),
  level smallint not null default 1, played_s bigint not null default 0, state_schema smallint not null default 1,
  state_version bigint not null default 0, state jsonb not null default '{}', progress jsonb not null default '{}',  -- progress: hasta PRG-10
  must_rename boolean not null default false, created_at now_ts, last_entered_at ts, deleted_at ts, restore_until ts);
create index on characters (account_id, world_id);
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
  build_id text not null, protocol_version int not null, dtls_cert_pem text, dtls_name text, max_players int not null,
  players int not null default 0, status text not null check (status in ('live','stopped','lost','replaced')),
  started_at now_ts, last_heartbeat_at now_ts);
create unique index on zone_instances (world_id, zone_id, channel) where status = 'live';
create table enter_tickets (ticket_id bigint primary key, world_id smallint not null references worlds,   -- ticket_id: u64 con bit 63 a 0
  character_id bigint not null references characters on delete cascade, session_id bigint not null references sessions on delete cascade,
  zone_instance_id uuid not null references zone_instances, issued_at ts not null, expires_at ts not null, consumed_at ts);
create table character_leases (character_id bigint primary key references characters on delete cascade,
  world_id smallint not null references worlds, lease_id uuid not null,         -- lease_id solo cambia al reclamar (§5.3)
  zone_instance_id uuid references zone_instances,                              -- null: libre
  session_id bigint references sessions on delete set null,                     -- la del billete: revocarla expulsa
  expires_at ts, last_seq bigint not null default 0, claimed_at now_ts, released_at ts);
create index on character_leases (zone_instance_id) where zone_instance_id is not null;
create table item_uid_blocks (world_id smallint primary key references worlds, next_uid bigint not null default 1);  -- uid de PRG-02

-- 0004_war
create table fortresses (world_id smallint not null references worlds, fortress_id text not null, zone_id text not null,
  record jsonb not null, version bigint not null default 0, updated_at now_ts, updated_by uuid references zone_instances,
  primary key (world_id, fortress_id));
create table fortress_events (id bigint generated always as identity primary key, world_id smallint not null references worlds,
  fortress_id text not null, event smallint not null check (event between 1 and 7), realm smallint not null check (realm between 0 and 3),
  at ts not null, zone_instance_id uuid references zone_instances, event_key text not null unique);
create table realm_resources (world_id smallint not null references worlds, realm smallint not null check (realm between 1 and 3),
  resource text not null, amount bigint not null default 0 check (amount >= 0), primary key (world_id, realm, resource));  -- fase 7

-- 0005_social
create table chat_messages (id bigint generated always as identity primary key, world_id smallint not null references worlds,
  zone_id text not null, channel smallint not null, sender_character_id bigint not null, sender_account_id bigint not null,
  target_character_id bigint, text text not null check (length(text) <= 255), sent_at ts not null, message_key text not null unique);
create index on chat_messages (sent_at); create index on chat_messages (sender_character_id, sent_at);
create table ignores (account_id bigint not null references accounts on delete cascade,
  ignored_account_id bigint not null references accounts on delete cascade, ignored_character_id bigint,
  ignored_name text not null, created_at now_ts, primary key (account_id, ignored_account_id));
create table reports (report_id bigint generated always as identity primary key, world_id smallint not null references worlds,
  reporter_account_id bigint references accounts on delete set null, reporter_character_id bigint,
  target_account_id bigint references accounts on delete set null, target_character_id bigint, target_name text not null,
  category text not null check (category in ('language','harassment','cheating','bot','offensive_name','other')),
  comment text not null default '' check (length(comment) <= 500), context jsonb not null,             -- zona, posición, tick
  status text not null default 'open' check (status in ('open','in_review','actioned','dismissed')),
  handled_by bigint references accounts on delete set null, resolution text, created_at now_ts, closed_at ts);
create index on reports (status, created_at); create index on reports (reporter_account_id, created_at);
create table report_evidence (report_id bigint not null references reports on delete cascade, seq smallint not null,
  sender_name text not null, channel smallint not null, text text not null, sent_at ts not null, primary key (report_id, seq));
create table sanctions (sanction_id bigint generated always as identity primary key, account_id bigint not null references accounts on delete cascade,
  world_id smallint references worlds, character_id bigint, kind text not null check (kind in ('warning','mute','suspension','ban','rename')),
  reason text not null, author_account_id bigint references accounts on delete set null, starts_at now_ts, ends_at ts,  -- null: permanente
  revoked_at ts, revoked_by bigint references accounts on delete set null, created_at now_ts);
create index on sanctions (account_id) where revoked_at is null;
create table sanction_reports (sanction_id bigint not null references sanctions on delete cascade,
  report_id bigint not null references reports on delete cascade, primary key (sanction_id, report_id));
create table audit_log (id bigint generated always as identity primary key, world_id smallint,                   -- sin claves ajenas
  source text not null check (source in ('zone','console','platform','cli')), actor_account_id bigint, actor_character_id bigint,
  zone_id text, command text not null, target_account_id bigint, target_character_id bigint, args jsonb not null default '{}',
  at now_ts, event_key text unique);
create index on audit_log (at); create index on audit_log (target_character_id, at);
```

Cada `.down.sql` deshace su `.up.sql` en orden inverso. Las tablas de progreso (objetos con `uid`, inventario, libro
mayor, niveles) son de `docs/progresion.md` (0010+), con `world_id` y `references characters on delete cascade`.

## 4. API pública (cliente ↔ plataforma)
### 4.1 Convenciones
- HTTPS y JSON en UTF-8, prefijo `/v1`, cuerpo de 16 KB como mucho (413). Campos desconocidos: 400.
- Cabeceras: `Authorization: Bearer <acceso>`, `X-Eldmark-Protocol: <PROTOCOL_VERSION>`, `X-Eldmark-Build: <build
  id>`. Sin protocolo o por debajo de `ELDMARK_MIN_PROTOCOL`: 426.
- Ids como números JSON (caben en 2^53); billete y apariencia en base64 estándar.
- Error: `{"error": {"code": "name_taken", "message": "Ese nombre ya está en uso", "retry_after_s": 0, "fields":
  {"name": "taken"}}}`. El cliente traduce por `code` (UI-04) y, si no lo conoce, muestra `message`. Con 429 y 503
  va también `Retry-After`.

| HTTP | `code` | Cuándo | Texto |
|---|---|---|---|
| 400 | `bad_request`, `validation` | JSON roto; campos que faltan o no valen (`fields`) | «Datos no válidos» |
| 401 | `unauthorized` | Token ausente, caducado o revocado: el cliente refresca una vez y, si no, vuelve al título | «Tu sesión ha caducado» |
| 401 | `invalid_credentials` | Correo o contraseña mal (no se dice cuál) | «Correo o contraseña incorrectos» |
| 403 | `account_locked` | Demasiados fallos (`retry_after_s`) | «Cuenta bloqueada durante N min» |
| 403 | `account_suspended`, `account_banned` | Sanción (`until`, `reason`) | «Cuenta suspendida hasta el …: motivo» |
| 403 | `email_unverified`, `account_pending_deletion` | Entrar al mundo sin verificar (si se exige) o con el borrado pedido | «Verifica tu correo para entrar» · «Tu cuenta se borrará el …» |
| 403 | `terms_required` | Versiones nuevas por aceptar (`documents`) | Pantalla de aceptación |
| 404 | `not_found` | No existe o no es de la cuenta | «No encontrado» |
| 409 | `email_taken` · `name_taken` | Correo con cuenta · nombre en uso o reservado (no se dice cuál) | «Ese correo ya tiene cuenta» · «Ese nombre ya está en uso» |
| 422 | `name_invalid` | `reason`: `too_short`, `too_long`, `has_space`, `has_digit`, `invalid_character`, `not_capitalized`, `reserved` (también la lista negra) | `NameRules.reason_text` |
| 409 | `realm_locked` · `realm_closed` | Otro reino que el de la cuenta (`realm`, `unlock_at`) · fuera de `ELDMARK_OPEN_REALMS` | «Tu cuenta es de Vardheim» · «Ese reino abre más adelante» |
| 409 | `slots_full` · `rename_required` | Sin huecos · renombrado forzado | «No te quedan huecos» · diálogo de nombre |
| 409 | `character_busy` | Arrendamiento vivo (`retry_after_s` = 3) | «Tu personaje está saliendo del mundo…» |
| 426 | `client_outdated` | Protocolo antiguo (`min_protocol`) | «Actualiza el cliente» |
| 429 | `rate_limited` | Límite de ritmo (`retry_after_s`) | «Demasiados intentos; espera N s» |
| 503 | `maintenance` · `zone_unavailable` | Mantenimiento (`message`, `until`) · ninguna instancia viva de la zona | El mensaje · «La zona no está disponible» |
| 500 | `internal` | Cualquier otro fallo (con `X-Request-Id`) | «Error del servidor» |

### 4.2 Cuentas y sesiones (TEC-23)
| Ruta | Cuerpo | Respuesta |
|---|---|---|
| `GET /v1/status` (sin token) | — | `{status: "ok"\|"maintenance", message, maintenance_at, min_protocol, worlds: [{world_id, name, status, load: "low"\|"medium"\|"high"}], news: [{title, body, date}]}` |
| `GET /v1/legal` · `GET /v1/legal/{kind}` (sin token) | — | `{terms: {version, sha256}, privacy, rules}` · el texto Markdown vigente |
| `POST /v1/accounts` | `{email, password, age_confirmed: true, accept: {terms, privacy, rules}, consents: {crash_reports, analytics}}` | 201 `{account_id}` y correo de verificación |
| `POST /v1/sessions` | `{email, password}` | `{access_token, access_expires_in, refresh_token, refresh_expires_in, account}` |
| `POST /v1/sessions/refresh` · `DELETE /v1/sessions/current` | `{refresh_token}` · — | Un par nuevo (el viejo deja de valer) · 204 |
| `GET /v1/account` | — | `{account_id, email, email_verified, role, realms: {"1": "vardheim"}, slots, consents, pending: {terms_required, deletion_at}}` |
| `POST /v1/account/accept` · `PUT /v1/account/consents` | `{terms, privacy, rules}` (versiones) · `{crash_reports, analytics}` | 204 |

- **Correo:** en minúsculas y sin espacios alrededor, 3–254 B, una `@` con algo a cada lado; único.
- **Contraseña:** 10 a 128 caracteres (512 B como mucho), distinta del correo, sin normalizar. `passwords.Verify`
  dice `needsRehash` si los parámetros de la cadena PHC no son los actuales, y el inicio de sesión la reescribe.
  Como mucho `runtime.NumCPU()` cálculos a la vez (19 MiB cada uno). Con un correo inexistente se calcula un hash de
  relleno: el tiempo no delata cuentas.
- **Sesión única de juego:** iniciar sesión revoca las demás de la cuenta (`revoke_reason = 'replaced'`) y el latido
  expulsa a su personaje (§6).
- **Tokens:** 32 B de `crypto/rand` en base64url sin relleno; en la base, su SHA-256. Acceso 15 min; refresco 12 h
  que rota en cada uso; usar uno ya rotado revoca toda la `family`.
- **Aceptación:** el registro exige las versiones vigentes de los tres textos. Con una versión nueva, `GET
  /v1/account` lo dice y `enter` responde `terms_required` hasta aceptarla.

| Límite | Valor | Dónde |
|---|---|---|
| Inicio de sesión · registro, por IP | 10/min, ráfaga 10 · 3 por hora | Memoria (cubo de fichas; una sola instancia en la fase 5) |
| Fallos por cuenta | 5 seguidos → 15 min; 10 → 1 h; acertar reinicia | `accounts.failed_logins`, `locked_until` |
| Correos de verificación o recuperación · exportar datos | 3 por cuenta y hora y 10 por IP y hora · 1 al día | Memoria y `auth_events` |
| Comprobar nombre · entrar al mundo | 30/min por sesión · 10/min por cuenta | Memoria |

Las IPv6 cuentan por /64, como `ServerAuth.address_group`. Detrás de Caddy, la IP sale de `X-Forwarded-For` solo si
la conexión llega de `127.0.0.1` o de la red del proxy.

### 4.3 Ciclo de vida (TEC-41)
| Ruta | Cuerpo | Efecto |
|---|---|---|
| `POST /v1/account/verify-email` (sin token) · `…/verify-email/resend` | `{token}` · — | Verifica · 202, correo nuevo; los anteriores dejan de valer |
| `POST /v1/account/password-reset` (sin token) | `{email}` | **Siempre 202**, exista o no la cuenta |
| `POST /v1/account/password-reset/confirm` (sin token) | `{token, new_password}` | Cambia, revoca todas las sesiones y desbloquea |
| `POST /v1/account/password` | `{current_password, new_password}` | Cambia y revoca las demás sesiones |
| `POST /v1/account/email` · `…/email/confirm` (sin token) | `{new_email, password}` · `{token}` | Enlace al nuevo y aviso al antiguo · cambia y lo da por verificado |
| `POST /v1/account/deletion` · `DELETE /v1/account/deletion` | `{password}` · — | 202 `{purge_at}` (+14 días; revoca las demás sesiones) · 204, cancela en plazo |
| `GET /v1/account/export` | — | JSON descargable (§11.2) |

- Enlaces de un solo uso en `account_tokens` (SHA-256 del token): 24 h para verificar o cambiar el correo, 1 h para
  recuperar. Usado o caducado: 400 `validation` con `fields.token = "used"` o `"expired"`, y nada cambia.
- Los correos enlazan a `ELDMARK_PUBLIC_URL/verify?token=…` y `/reset?token=…`: páginas HTML mínimas, sin
  JavaScript, servidas por la plataforma (un formulario que hace el `POST`).
- Con `ELDMARK_MAIL=log`, el correo va a `outbound_mail` y al registro con el enlace entero: así las pruebas sacan
  el token. En `staging` y `production`, `log` no arranca.

### 4.4 Personajes y nombres (TEC-24, SOC-13)
| Ruta | Cuerpo | Respuesta |
|---|---|---|
| `GET /v1/worlds/{w}/characters` | — | `{realm, unlock_at, slots, used, characters: [{character_id, name, realm, race_id, appearance, level, last_zone_id, played_s, created_at, deleted_at, restore_until, must_rename}]}` |
| `GET /v1/worlds/{w}/name-check?name=…` | — | `{available, code, reason}` |
| `POST /v1/worlds/{w}/characters` | `{name, realm, race_id, appearance}` | 201 `{character}` |
| `DELETE /v1/characters/{id}` | `{confirm_name}` | `{restore_until}`; `confirm_name` con la misma clave de NameRules que el nombre |
| `POST /v1/characters/{id}/restore` | — | 200 en plazo, con el nombre libre y un hueco |
| `POST /v1/characters/{id}/rename` | `{name}` | Solo con `must_rename`; el viejo queda reservado 30 días |
| `POST /v1/characters/{id}/enter` | — | §4.5 |

**Nombres.** `internal/names` es `NameRules` en Go (`Validate`, `NormalizeKey`, reservados) con sus datos en
`internal/gamedata/name_rules.json` (`{min_length, max_length, upper_letters, lower_letters, folded, reserved}`). Lo
genera `tools/platform/export_gamedata.gd` desde `NameRules` y se versiona; `tests/test_platform_gamedata.gd` lo
regenera en memoria y falla si difiere. Los casos de los dos lados salen de `tests/data/name_rules_cases.json`
(`[{name, reason, key}]`), que leen `test_name_rules.gd` e `internal/names` (con `../tests/data/…`).

**Crear**, en una transacción `serializable` (reintento ante 40001):

1. Cuenta activa sin borrado pendiente; `realm` en `ELDMARK_OPEN_REALMS` (si no, `realm_closed`).
2. `account_realms`: sin fila, o con `unlock_at ≤ now()` y ningún personaje vivo, se fija este reino; si la cuenta
   tiene otro, `realm_locked`.
3. Huecos: 6 + `quantity` de los `character_slots` vigentes; los borrados en plazo no ocupan.
4. Nombre: `names.Validate` (422), lista negra (422 `reserved`; la edita `admin names block|unblock <nombre>`) e
   `insert into character_names` con `status 'active'`. Una fila `reserved` vigente da `name_taken`; vencida, se
   reutiliza. Dos creaciones a la vez con el mismo nombre: una falla con 23505 en `character_names_pkey`
   (comprobado en una sonda con la misma clave) → `name_taken`.
5. Raza y apariencia: `race_id` de su reino y apariencia que decodifica con los rangos de
   `internal/gamedata/appearance_limits.json` (generado igual desde `RaceDefinition` y `CharacterAppearance`, PRG-14
   y ART-19). Mientras no existan: `race_id = "<reino>_humano"` y apariencia de 0 a 64 B sin validar.
6. `insert` en `characters` y `character_pvp_stats`, y `ProgressStore.Create` (§7.5).

**Borrar:** `deleted_at = now()`, `restore_until = now() + 7 d` y el nombre `reserved` hasta `restore_until + 30 d`.
Con arrendamiento vivo, `character_busy`. Al vencer `restore_until`, la purga horaria borra la fila; el nombre sigue
reservado. Si era el último vivo, `unlock_at = now() + 30 d`.

### 4.5 Entrar al mundo
`POST /v1/characters/{id}/enter`, sin cuerpo. Comprueba en orden: sesión, mantenimiento (503), sanciones (403),
borrado pendiente (403), textos por aceptar (403), correo verificado si se exige (403), personaje vivo de la cuenta
(404), `must_rename` (409), arrendamiento vivo (409). Elige la zona: la de `state.zone_id` si es de entrada o
restaurable y tiene una instancia `live` que admite el reino; si no, la de entrada de su reino, en el canal con
menos jugadores bajo `max_players`; si no hay ninguna viva, 503 `zone_unavailable`. Inserta el billete en
`enter_tickets` (10 s) y responde:

```json
{"zone": {"zone_id": "vado_gris", "channel": 0, "host": "203.0.113.5", "port": 24600,
          "dtls": {"cert_pem": "-----BEGIN CERTIFICATE-----…", "name": "vado-gris.eldmark"}},
 "ticket": "AQEBAAgHBgUEAwIBKgAAAAAAAAATwO8ZAAEAAQDSSWsK0klrcGHi9UqxoJb2YCRDcSPZ0Q==",
 "expires_in_s": 10, "character": {"character_id": 42, "name": "Aneira", "realm": "vardheim"}}
```

`dtls` es `null` si la zona no usa DTLS. El cliente conecta enseguida; si el billete caduca, pide otro.

## 5. Billete y entrada en la zona (TEC-24)
### 5.1 Formato del billete (52 B, little-endian)
Sustituye al de 47 B de red.md §12: añade el mundo y cambia la zona en texto por una huella de 4 B. Va en el campo
`ticket` del HELLO (≤ 256 B).

| Offset | Tipo | Campo | Notas |
|---|---|---|---|
| 0 | u8 | version | 1 |
| 1 | u8 | key_id | clave de `ELDMARK_TICKET_KEYS` (1–255) |
| 2 | u16 | world_id | |
| 4 | u64 | ticket_id | aleatorio, bit 63 a 0; clave de `enter_tickets` |
| 12 | u64 | character_id | igual que `HELLO.character_id` |
| 20 | u32 | zone_key | los 4 primeros bytes, como u32 LE, del SHA-256 del id ASCII de la zona |
| 24 | u8 | channel | |
| 25 | u8 | realm | código de `NetProtocol.Realm`; informativo (manda el arrendamiento) |
| 26 | u8 | arrival | 0 = lo decide la zona; n ≥ 1 = punto n − 1 (traspasos, fase 6) |
| 27 | u8 | flags | bit0 entrada desde el menú; bit1 traspaso (fase 6); resto 0 |
| 28 | u32 | issued_at | Unix, s |
| 32 | u32 | expires_at | `issued_at + 10` |
| 36 | 16 B | mac | HMAC-SHA256(clave, bytes 0..35), 16 primeros bytes |

**Vector de prueba** (Go y GDScript dan lo mismo, comprobado): clave `00 01 … 1f`, mundo 1, `ticket_id`
`0x0102030405060708`, personaje 42, `vado_gris` (`zone_key` `0x19efc013`), canal 0, reino 1, `arrival` 0, `flags` 1,
`issued_at` 1800000000 y `expires_at` 1800000010:

```
0101010008070605040302012a0000000000000013c0ef190001000100d2496b0ad2496b7061e2f54ab1a096f66024437123d9d1
```

GDScript: `HMACContext` con `HASH_SHA256`, `"vado_gris".sha256_buffer().decode_u32(0)` y
`Crypto.constant_time_compare`. Go: `crypto/hmac` y `hmac.Equal`.

### 5.2 Comprobaciones en la zona
`TicketAuthProvider.authenticate`, síncrono y sin red; cualquier fallo es REJECT `TICKET` y nada llega a la
plataforma:

1. Tamaño 52 y `version` 1; `key_id` conocido; `mac` correcto en tiempo constante.
2. `world_id`, `zone_key` y `channel` de esta zona («billete de otra zona»).
3. `issued_at ≤ ahora + 5` y `ahora ≤ expires_at + 5`, con «ahora» corregido por el reloj de la plataforma (§6).
4. `character_id` igual al del HELLO.
5. `ticket_id` no visto en los últimos 30 s («reutilizado»).

Si pasa, devuelve `PENDING`: el peer pasa al estado nuevo `ServerPeer.State.VERIFYING` y la zona pide la reclamación
(`POST /internal/v1/claims`), que garantiza de verdad el **un solo uso** y toma el arrendamiento. El resultado se
aplica en el paso «poll» del tick (§14.3):

| Reclamación | La zona |
|---|---|
| 200 | Si la zona admite el reino del personaje, WELCOME con ese reino, `complete_auth` y `LOADING`; si no, `REALM` y libera |
| 409 `ticket_invalid` (consumido, caducado, de otra instancia o de una sesión revocada) | REJECT `TICKET` |
| 409 `character_busy` | REJECT `BUSY` |
| 403 `account_blocked` (suspendida, expulsada, borrado pendiente) | REJECT `BANNED` con el texto de la plataforma |
| 5xx, sin conexión o `VERIFY_TIMEOUT_TICKS` = 240 (4 s) sin respuesta | REJECT `UNAVAILABLE`; si la reclamación llega después, se libera |

Contestar el HELLO segundos después funciona: `SceneMultiplayer` espera hasta su `auth_timeout` de 5 s (comprobado
con 1,5 s y sin `GuardedEnetPeer`, que solo filtra tipos de paquete). Los 90 ticks del HELLO (red.md §3) siguen
valiendo solo en `AUTHENTICATING`.

### 5.3 Arrendamiento
La reclamación, en una transacción, consume el billete (con su sesión sin revocar) y toma el arrendamiento:

```sql
update enter_tickets set consumed_at = now() where ticket_id = $1 and character_id = $2
  and zone_instance_id = $3 and consumed_at is null and expires_at > now() - interval '5 s' returning session_id;
insert into character_leases (character_id, world_id, lease_id, zone_instance_id, session_id, expires_at)
values ($1, $2, $3, $4, $5, now() + $6)
on conflict (character_id) do update set lease_id = excluded.lease_id,
  zone_instance_id = excluded.zone_instance_id, session_id = excluded.session_id,
  expires_at = excluded.expires_at, last_seq = 0, claimed_at = now(), released_at = null
where character_leases.zone_instance_id is null or character_leases.expires_at < now()
returning lease_id;                       -- sin fila: character_busy (condición probada con dos zonas)
```

- **Latido** cada 5 s con los personajes arrendados (en `VERIFYING`, `LOADING`, en el mundo, con el cuerpo tras una
  salida en combate o con el guardado final pendiente); renueva sus `expires_at`. Los que no van en la lista caducan
  solos (TTL 30 s).
- **Instancia perdida:** 15 s sin latido → `lost` y sus arrendamientos libres. Tras un `kill -9`, el personaje
  vuelve a entrar en 15 s como mucho.
- **Instancia nueva de la misma zona y canal:** al registrarse, la vieja pasa a `replaced` y sus arrendamientos se
  liberan. Si seguía viva, su siguiente petición recibe 409 `instance_replaced` y hace un cierre ordenado sin
  guardar nada más.
- **Salida en combate** (GUE-41): el arrendamiento dura hasta que el cuerpo se va y el guardado final llega. Entrar
  en esos 15 s da `character_busy` y el cliente reintenta solo cada 3 s durante 30 s: reconectar no acorta la salida
  en combate.
- **`lease_id` solo cambia al reclamar.** Liberar no lo cambia: un guardado tardío de la misma zona se acepta si
  nadie ha reclamado al personaje desde entonces (§7.3).

### 5.4 Cambios en el protocolo
| Pieza | Cambio |
|---|---|
| `PROTOCOL_VERSION` | Sube a la siguiente libre al fusionar TEC-24: hoy vale 4 en `fase4-fuerte`, así que **5** si el chat (SOC-03) y las habilidades no la suben antes; si no, la que siga. Línea nueva en `net_protocol.gd`: «5: la plataforma (docs/plataforma.md): REJECT 10 a 12, billete de 52 B y bit GM del ENTITY_SPAWN» |
| HELLO | **Sin cambios de bytes.** Con billete van `character_id` y `ticket`; el cliente pone en `realm` y `name` los de su personaje y la zona los ignora |
| WELCOME | Sin cambios de bytes; `realm` es el del personaje |
| REJECT | `Result` añade `BUSY = 10`, `UNAVAILABLE = 11` y `BANNED = 12` (si otra rama ocupó alguno, los siguientes libres). `result_text`: «Tu personaje sigue en el mundo: espera unos segundos», «El servicio de cuentas no responde: inténtalo más tarde», «Tu cuenta está suspendida». El texto lo compone la zona (con la fecha de fin en `BANNED`) |
| ENTITY_SPAWN | `flags` bit 3 = personal del juego (moderador o más), para la etiqueta (SOC-14). La apariencia en el payload es de ART-19 y va en la misma subida si se fusionan juntos |
| NOTICE | Sin códigos nuevos: «Has iniciado sesión desde otro lugar» o «Tu cuenta ha sido suspendida» van con el 1 (expulsión) |

Con `--platform`, `--max-realm-diff` (REJECT `IMBALANCE`) no se aplica: el reino ya no se elige al conectar (el
equilibrio de población es de GUE-36). El enfriamiento tras una expulsión usa la clave `character:<id>` en lugar del
nombre del HELLO.

### 5.5 Sin plataforma, todo sigue como hoy
| Modo | Fase 5 |
|---|---|
| F5 en el editor sin argumentos | Sandbox de la fase 1, igual (`OS.has_feature("editor")`) |
| Sin argumentos en una exportación · `--title [--platform=<url>]` | Pantalla de título (UI-22) contra `eldmark/platform/url` · lo mismo desde el editor |
| `--server` sin `--platform` | `DevAuthProvider` como hoy: reino y nombre del HELLO, sin guardado |
| `--server --platform=<url interna>` | `TicketAuthProvider`; un HELLO sin billete recibe `TICKET` («Entra desde el menú con tu cuenta») |
| `--fake-players`, `--fake-churn` | Igual con y sin plataforma: nunca la tocan ni se guardan; se llaman `Bot-NN`, que no es un nombre válido y no choca con ningún personaje |
| `--connect`, `--local`, `--bot --connect` | Igual, contra zonas sin plataforma; `RealmSelect` queda para desarrollo |
| `--bot --platform=<url> --login=<correo> --password-file=<ruta> [--character=<nombre>] [--realm=…]` | El bot entra con cuenta; sin personaje, lo crea (`--character` o `NameRules.bot_name(semilla)`) |
| `--bots=N` | Solo contra zonas sin plataforma (carga); con `--platform`, sale con un error claro |

## 6. API interna (zona ↔ plataforma)

HTTP y JSON en `ELDMARK_INTERNAL_ADDR` (127.0.0.1 en desarrollo; red privada de Docker en el VPS), con
`Authorization: Bearer <token de zona>`. En la zona, `PlatformClient` usa `HTTPRequest` (sin hilos), 4 peticiones en
vuelo como mucho, plazo de 3 s y cola; los resultados se guardan al llegar y se aplican en el paso «poll», nunca a
mitad de tick. Los guardados se reintentan a 1, 2, 4, 8 y 15 s mientras la zona viva. Registro y latido traen
`now_unix`: la zona guarda `offset = now_unix − su reloj` (`ZonePlatform.now_unix()`) y avisa si pasa de 2 s.

| Ruta | Cuerpo | Respuesta |
|---|---|---|
| `POST /internal/v1/zone-instances` | `{world_id, zone_id, channel, public_host, public_port, build_id, protocol_version, max_players, dtls_cert_pem, dtls_name}` | `{zone_instance_id, heartbeat_s, lease_ttl_s, now_unix}` |
| `POST /internal/v1/zone-instances/{id}/heartbeat` | `{players, characters: [ids]}` | `{now_unix, revoked: [{character_id, reason, text}], mutes: [{account_id, until_unix}], maintenance: {at_unix, message} \| null}` |
| `DELETE /internal/v1/zone-instances/{id}` | — | 204; libera lo que quede |
| `POST /internal/v1/claims` | `{zone_instance_id, ticket_id, character_id}` | `{lease_id, account: {account_id, role, muted_until_unix, ignored_account_ids}, character: {character_id, world_id, name, realm, race_id, appearance, level, played_s, state_schema, state_version, state, progress}}` |
| `PUT /internal/v1/characters/{id}/state` | §7.3 | `{applied, duplicate, state_version}` |
| `POST /internal/v1/saves` | `{zone_instance_id, saves: [§7.3 con character_id]}` | Todos o ninguno (comercio y correo, fase 6) |
| `POST /internal/v1/characters/{id}/release` | `{lease_id}` | 204, sin guardar (el cliente no llegó a aparecer) |
| `POST /internal/v1/item-uid-blocks` | `{world_id, count}` (≤ 100 000) | `{first, count}` con `update item_uid_blocks set next_uid = next_uid + $n … returning next_uid - $n` |
| `GET /internal/v1/fortresses?world_id=&zone_id=` · `PUT /internal/v1/fortresses/{id}` | — · `{zone_instance_id, world_id, zone_id, record}` | `{fortresses: [{fortress_id, record, version}]}` · `{version}` |
| `POST /internal/v1/war-events` · `…/chat` · `…/audit` | `{zone_instance_id, events\|messages\|entries: [{key, …}]}` (§8, §9) | 204 |
| `POST /internal/v1/reports` | §9.4 | `{report_id}` o 429 |
| `POST` · `DELETE /internal/v1/ignores` | `{account_id, target_name}` | `{ignored_account_id, name}` · 204 |
| `POST /internal/v1/sanctions` | `{author_character_id, target_name, kind, minutes, reason}` | `{sanction_id, ends_at_unix}` |

- **Errores:** 401 `bad_token`; 409 `instance_replaced`, `lease_lost`, `ticket_invalid`, `character_busy`,
  `schema_mismatch`; 403 `account_blocked`. Cuerpo como en §4.1.
- **Lotes** (chat, auditoría, guerra): cada 2 s o 200 entradas, 1 MB como mucho. Cada entrada lleva `key =
  "<zone_instance_id>:<secuencia>"` y se inserta con `on conflict do nothing`: reenviar un lote no duplica nada.
- **`revoked`** sale de los arrendamientos de la instancia cuya `session_id` está revocada (sesión sustituida,
  cambio de contraseña) o cuya cuenta tiene una suspensión o expulsión vigente o el borrado pedido.

## 7. Persistencia del personaje (TEC-25)
### 7.1 Qué se guarda
| Dato | Dónde | Al volver |
|---|---|---|
| Zona, posición, giro | `state.zone_id`, `state.position` `[x, y, z]`, `state.yaw` | Solo si es la misma zona y `NetZones.restores_position(zone_id)` (zonas `SAFE` de `Zones.get_pvp_mode`, fase 6); en las de guerra (Vado Gris, `test_world`, Eldrun), el campamento del reino |
| Vida | `state.health` | La guardada; muerto (también si murió el cuerpo tras salir) se guarda como «reaparece en el campamento con la vida llena» |
| Tiempo jugado, nivel | `state.played_s` y `state.level`, copiados a sus columnas | `played_s` para SOC-38 (fase 6); `level` lo da PRG-13 y la lista lo enseña |
| Combate (CMB-30) | `state.combat`: objeto opaco de `docs/habilidades.md`, ≤ 4 KB; reutilizaciones de más de 30 s y efectos largos en **segundos restantes** | Se pasan a ticks en `scripts/server/` |
| PvP (GUE-19) | `state.pvp` `{kills, deaths, assists, captures, gate_damage, defend_s}`, **totales**, copiados a `character_pvp_stats` | Siguen sumando |
| Progreso (PRG-10) | `progress`, de `docs/progresion.md` | `ProgressStore` (§7.5) |
| **Nunca** | `PlayerState`, `CombatState` (ticks de la zona), la cola de entradas, el combate en curso, los avisos | — |

`state_schema` = 1. Solo se acepta el actual (409 `schema_mismatch`: la zona lo registra como error y conserva el
guardado en memoria); las filas viejas se convierten al leerlas (`persistence.upgradeState(schema, raw)`) y una
migración de datos las reescribe.

### 7.2 Cuándo se guarda
| Momento | Cómo |
|---|---|
| Punto de control | Cada 60 s (`--save-interval=<s>`) si algo guardado cambió (moverse cuenta). Cada personaje en su fase (`tick % 3600 == character_id % 3600`): 64 jugadores dan ~1 guardado por segundo |
| Evento crítico | Al instante: subida de nivel (PRG-13), recompensa de captura, comandos de GM que dan o quitan (PRG-16), renombrado; desde la fase 6, comercio, correo y botín raro |
| Salida | Al irse el cuerpo (CLIENT_LEAVE, desconexión o fin de los 15 s en combate): guardado final con `release: true` |
| Cierre ordenado | `--stop-file`, `shutdown` de la consola o el mantenimiento: guardado final de todos y hasta 10 s esperando las respuestas |
| Expulsión de la plataforma | `revoked` del latido: guardado final y expulsión con NOTICE |

**Una escritura en vuelo por personaje:** si toca otra, se marca y al volver la respuesta sale la foto más reciente
(cada guardado es completo). La foto se toma **dentro del tick**, tras «altas»; `JSON.stringify` y el envío no
bloquean el tick.

### 7.3 Versiones e idempotencia
```json
{"zone_instance_id": "…", "lease_id": "…", "seq": 17, "reason": "checkpoint", "release": false,
 "state_schema": 1, "state": {"zone_id": "vado_gris", "position": [12.5, 3.0, -40.25], "yaw": 1.5708,
 "health": 820, "level": 1, "played_s": 3600, "combat": {}, "pvp": {"kills": 3, "deaths": 1,
 "assists": 0, "captures": 1, "gate_damage": 450, "defend_s": 120}}, "progress": {}}
```

`seq` empieza en 1 con cada arrendamiento y sube en cada guardado; `reason` es `checkpoint`, `critical`, `logout`,
`shutdown` o `kick`. La plataforma, en una transacción:

1. `select … from character_leases where character_id = $1 for update`.
2. Otro `lease_id` → 409 `lease_lost`: otro lo reclamó; la zona expulsa al jugador si sigue y **nunca** reintenta
   ese guardado.
3. `seq ≤ last_seq` → 200 `{applied: false, duplicate: true}` (reintento, o uno más viejo que otro ya aplicado).
4. Si no, escribe `state`, `level`, `played_s`, `character_pvp_stats` y `ProgressStore.Apply`; `state_version += 1`,
   `last_seq = seq`; con `release`, `zone_instance_id = null` y `released_at`. Si algo falla (un `uid` repetido, un
   JSON que no vale), **no se escribe nada** y 400.

El arrendamiento hace a la zona la única escritora (no necesita `state_version`); un GM que edita desde la CLI
necesita que no haya arrendamiento vivo, y en el juego lo hace por la zona. **Regla de los objetos:** toda operación
que mueve objetos o monedas entre dos personajes se guarda en un solo `POST /internal/v1/saves` con los dos; así un
`uid` nunca está en dos filas (la clave primaria de PRG-10 lo impide) y nada se duplica.

### 7.4 Si algo se cae
| Cae | Qué pasa | Se pierde |
|---|---|---|
| La zona (`kill -9`) | Arrendamientos libres a los 15 s (o al registrarse la instancia nueva) | Lo posterior al último guardado: **60 s como mucho**; lo crítico ya estaba |
| La plataforma | Nadie nuevo entra (`enter` falla; una reclamación en curso da `UNAVAILABLE`); quien juega sigue. La zona guarda la última foto de cada personaje (también de los que salen) y reintenta; al volver, la gracia de §2.5 y todo se envía | Nada, si la zona no cae también |
| Las dos | Lo que no llegó | Desde el último guardado aceptado |
| La red entre ellas | Para la zona, como «la plataforma». Si el cliente sí llega a la plataforma, a los 15 s su personaje puede entrar en otra zona; al volver la red, la vieja recibe `lease_lost` y lo expulsa sin guardar | Lo jugado en la zona aislada (§16) |

Deseable (no bloquea TEC-25): un cierre ordenado sin plataforma escribe lo pendiente en `user://pending_saves.jsonl`
y lo reenvía al arrancar; vale porque `lease_id` no cambia al liberar y `seq` lo ordena.

### 7.5 Frontera con `docs/progresion.md`
```go
// internal/persistence/progress.go. Todo va dentro de la transacción de quien llama.
type SaveKey struct { LeaseID [16]byte; Seq int64 }
type ProgressStore interface {
	Create(ctx context.Context, tx pgx.Tx, worldID int16, characterID int64) error            // personaje nuevo
	Load(ctx context.Context, tx pgx.Tx, characterID int64) (json.RawMessage, error)          // «progress» de la reclamación
	// Idempotente con la misma SaveKey; si devuelve error, se deshace el guardado entero.
	Apply(ctx context.Context, tx pgx.Tx, worldID int16, characterID int64, progress json.RawMessage, key SaveKey) error
}
```

Hasta PRG-10, `jsonProgressStore` guarda el objeto tal cual en `characters.progress` (≤ 192 KB). En la zona, el
gancho es `CharacterSaver.register_section(&"progress", build, restore)` (§14.3).

## 8. Guerra persistente (GUE-19)

Registro de una fortaleza (`fortresses.record`, esquema 1), escrito por `FortressPersistence` en
`scripts/server/war/` (nunca en `scripts/shared`, que no lee el reloj):

```json
{"schema": 1, "owner": 1, "phase": "consolidating", "phase_ends_at_unix": 1800000120,
 "captain_alive": false, "captain_respawn_at_unix": 1800000300, "gate_health": 2600,
 "capture_realm": 0, "capture_progress": 0, "last_reset_at_unix": 1799999000}
```

- **Guardar:** en cada cambio de dueño o de fase y, si cambió algo (la vida de la puerta), cada 60 s. Un tick futuro
  `t` se escribe como `now_unix + ceil((t − tick) / 60)`.
- **Arrancar,** antes de abrir el puerto: `GET /internal/v1/fortresses`; cada `*_at_unix` vuelve a ticks con `tick +
  max(0, at − now_unix) · 60`. `CAPTURING` vuelve como `VULNERABLE` con su progreso (el círculo está vacío y decae);
  los guardias no se guardan (los repone el generador). Sin registro, o con otro esquema, el estado inicial de la
  definición con un aviso. Sin plataforma, como hoy.
- El reinicio a neutral cada 30 min cuenta desde `last_reset_at_unix` (reiniciar el proceso no reinicia el ciclo).
  Solo escribe la instancia `live` de esa zona.
- **Historial:** los `WarEvents` 3 (captura iniciada), 6 (capturado) y 7 (reiniciado) van al lote de `war-events`
  (`{key, fortress_id, event, realm, at_unix}`) → `fortress_events`.
- **Por personaje:** `ScoreKeeper` cuenta la sesión; `CharacterSaver` suma esos contadores a los totales cargados y
  los manda en `state.pvp` (bajas, muertes, asistencias, capturas, daño a puertas y segundos en el círculo de una
  fortaleza propia).

## 9. Social y moderación (SOC-13 a SOC-18)
### 9.1 Roles y auditoría (SOC-14)
| Rol | Puede |
|---|---|
| `player` | Nada de moderación |
| `moderator` | `/gm silenciar`, `/gm aviso`, `/gm expulsar`; etiqueta visible |
| `gm` | Lo anterior, `/gm suspender` hasta 7 días, `/gm teleport`, `/gm invisible`, PRG-16 y los comandos del fuerte |
| `admin` | Todo, también `/gm banear`, `/gm anuncio` y `/gm apagar` |

- El rol lo pone `admin set-role <correo> <rol>` (auditado); llega en la reclamación y vale hasta salir. Cada
  comando del `CommandRegistry` declara su `min_role`; sin permiso o desconocido: «Comando desconocido. Escribe
  /ayuda.». Sin plataforma, como hoy. **Invisible:** la entidad del GM no entra en el interés de los demás
  (`InterestPolicy`).
- **Auditoría:** todo comando de GM, de consola o de depuración con plataforma va al lote de `audit` (`{key,
  actor_character_id, command, target_character_id, args, at_unix, source}`) y al registro de la zona; los de la CLI
  y las sanciones, directos a `audit_log`. Consulta: `eldmark-platform admin audit --since 2026-11-01 [--actor
  <nombre>] [--target <nombre>]`.

### 9.2 Registro del chat (SOC-15)
`ChatRouter` (SOC-04) pone cada mensaje ya saneado en el lote de `chat` (`{key, channel, sender_character_id,
target_character_id, text, sent_at_unix}`). Retención de 30 días (§11.1). Consulta: `admin chat --character <nombre>
--from … --to …`, que también queda auditada.

### 9.3 Ignorados (SOC-16)
- `/ignorar nombre` → zona → `POST /internal/v1/ignores`: la plataforma resuelve la cuenta del nombre y guarda
  `(cuenta, cuenta ignorada, personaje nombrado, nombre)`. Hasta 100. La lista que ve el jugador solo enseña los
  nombres que él escribió.
- La zona tiene, por jugador, las cuentas que ignora (llegan en la reclamación) y la cuenta de cada personaje. **El
  servidor descarta** los susurros, invitaciones y (fase 6) correo de una cuenta ignorada, y la quita de los
  destinatarios de los canales públicos: el cliente no puede ocultarla sin saber qué personajes comparten cuenta, y
  eso no se le dice (precisa social.md §10).

### 9.4 Reportes (SOC-17)
`/reportar nombre categoría [comentario]` o el menú social. La zona adjunta los últimos 20 mensajes de ese personaje
que **recibió** quien reporta en 10 min (un anillo por receptor en `ChatRouter`), zona, posición y tick, y manda
`{reporter_character_id, target_name, category, comment, context, evidence: [{sender_name, channel, text,
sent_at_unix}]}`. La plataforma impone 1 por objetivo cada 10 min y 10 por hora por cuenta (429), copia la prueba a
`report_evidence` y la zona contesta «Reporte enviado. Gracias.». Revisión: `admin reports list|show|close`.

### 9.5 Sanciones (SOC-18)
| Tipo | Dónde se aplica |
|---|---|
| Aviso | Al entrar, NOTICE con el motivo |
| Silencio | `ChatRouter` descarta y contesta «Estás silenciado N min más»; llega en la reclamación y en `mutes` del latido |
| Suspensión, expulsión permanente | Inicio de sesión y `enter` (403 con fin y motivo), reclamación (`BANNED`) y latido (`revoked`: guardado final y expulsión) |
| Renombrado forzado | `characters.must_rename`: `enter` → 409 `rename_required` |

Toda sanción lleva motivo, autor, `ends_at` y sus reportes, con la escala de social.md §9. La crean `/gm …` (por
`POST /internal/v1/sanctions`) o `admin sanction …`. Las normas se aceptan al crear la cuenta (§11.4).

## 10. Seguridad, cifrado y secretos (TEC-27)
### 10.1 HTTPS
- La plataforma sirve HTTP; en staging y producción, **Caddy** delante con Let's Encrypt y de 80 a 443
  (`platform/deploy/Caddyfile`). La API interna no pasa por Caddy.
- El cliente usa `TLSOptions.client()` (los certificados raíz de Godot) y rechaza `http://` salvo hacia loopback.
  Staging con certificado propio: `eldmark/platform/ca_cert` (ruta a un PEM).
- Comprobado en Godot 4.7.2: `HTTPRequest` con `TLSOptions.client(X509Certificate)` habla con un Go con certificado
  propio (200 en 63 ms) y un 400 trae su JSON. Sin anclar da `RESULT_TLS_HANDSHAKE_ERROR` **y el motor registra un
  ERROR**, que el ejecutor cuenta como fallo: ninguna prueba de Godot provoca un fallo de TLS (eso se prueba en Go).
  `RESULT_CANT_CONNECT` y `RESULT_TIMEOUT` no registran errores.

### 10.2 DTLS en ENet
- La zona (`--dtls-cert=<pem> --dtls-key=<pem>`) llama a `host.dtls_server_setup(TLSOptions.server(clave, cert))`
  tras `create_server` y manda el PEM público y `dtls_name` (el `CN` del certificado) al registrarse. El cliente lo
  recibe en `enter` (por HTTPS, que lo autentica) y llama a `host.dtls_client_setup(dtls_name,
  TLSOptions.client(cert))` justo tras `create_client`. Sin CA propia ni certificado empaquetado: rotarlo no pide
  parche del cliente.
- Comprobado con `ENetMultiplayerPeer` en un proceso: conecta y entrega un paquete por DTLS. Salir sin `close()`
  hace que el motor registre un error de `bio_send`: se cierran los peers antes.
- **Sin comprobar:** DTLS con `GuardedEnetPeer` y la autenticación de `SceneMultiplayer`, y su coste. TEC-27 mide la
  CPU por paquete, los bytes de más por datagrama y el tope de 1200 B frente al MTU de ENet. El criterio del backlog
  (p99 < 8 ms con 64 bots) ya no se cumple sin DTLS (red.md §14: 15,9 ms con 64 combatientes); aquí es **relativo:
  DTLS no sube el p99 más de un 10 %**.

### 10.3 Secretos
| Secreto | Dónde vive | Rotación |
|---|---|---|
| URL de la base | `ELDMARK_DATABASE_URL_FILE` (secreto de Docker) | `alter role … password`, secreto nuevo y reinicio |
| Claves del billete | `ELDMARK_TICKET_KEYS_FILE` en la plataforma y en cada zona | Clave nueva en las zonas → firmar con ella → quitar la vieja tras 1 min |
| Token de zona | `ELDMARK_ZONE_TOKENS_FILE` (plataforma) y `ELDMARK_ZONE_TOKEN_FILE` (zona) | Dos tokens a la vez durante el cambio |
| Clave DTLS de cada zona | Secreto de Docker | Certificado nuevo y reinicio; el cliente lo recibe en el siguiente `enter` |
| SMTP | `ELDMARK_SMTP_URL_FILE` | En el proveedor |

La zona lee sus secretos solo de variables o archivos (`OS.get_environment`), nunca de la línea de órdenes, que se
ve con `ps`. Nada entra en git (`.env` ya está en `.gitignore`; los `deploy/*.env.example` van sin valores).

## 11. Privacidad y RGPD (TEC-43)
### 11.1 Datos y retenciones
Hay cuenta (correo, hash, fechas, rol, estado), sesiones y accesos (IP, agente), aceptaciones, consentimientos,
derechos, personajes (nombre, apariencia, estado, progreso, estadísticas), ignorados, chat, reportes, sanciones y
auditoría. Ni nombre real, ni dirección, ni pagos (si los hay, son del proveedor).

| Dato | Se conserva | Cómo |
|---|---|---|
| `chat_messages` | 30 días | Trabajo horario, lotes de 10 000 |
| `report_evidence`, reportes cerrados, `audit_log` | 1 año (desde el cierre en los reportes) | Trabajo horario |
| `auth_events`; IP y agente de `sessions` | 30 días | Trabajo horario (la IP de la sesión pasa a null) |
| `sessions` y `account_tokens` caducados · `enter_tickets` · `zone_instances` paradas · `outbound_mail` | 7 días · 1 día · 30 días · 7 días | Trabajo horario |
| Personaje borrado | 7 días restaurable; el nombre, 30 más | Purga horaria |
| Cuenta borrada | 14 días de gracia | Purga (§11.2) |
| Sanciones | Mientras exista la cuenta; tras la purga, 1 año sin datos personales | **Revisión legal** |
| `fortress_events`, `realm_resources` | Sin límite: no son personales | — |

### 11.2 Exportación y supresión
**Exportar:** `GET /v1/account/export` (1 al día) da `eldmark-datos-<fecha>.json`: cuenta (sin el hash),
aceptaciones, consentimientos, sesiones y accesos de 30 días, derechos, personajes con estado, progreso y
estadísticas, ignorados (por nombre), sanciones propias, reportes **hechos** y chat enviado por sus personajes en
plazo. No da reportes recibidos ni notas de moderación (de terceros: **revisión legal**).

**Suprimir:** `POST /v1/account/deletion` → 14 días → purga en una transacción: personajes (nombres reservados 30
días), ignorados en los dos sentidos, sesiones, tokens, consentimientos, aceptaciones, derechos y el chat de sus
personajes no copiado a un reporte. La fila de `accounts` queda como lápida (`email` y `password_hash` a null,
`status = 'purged'`) para que auditoría y sanciones no apunten a nada. `admin purge-now <correo>` hace lo mismo sin
esperar (petición expresa).

### 11.3 Derechos de cuenta (PRG-41)
`entitlements` vale para compra única, suscripción o gratuito con tienda: huecos (`character_slots`), expansiones
(`expansion`, `ref` = id) y cosméticos (`cosmetic`, `ref` = id de PRG-40). **Ningún derecho llega a la simulación ni
al combate**; la zona solo recibirá cosméticos (fase 8). El modelo de negocio lo decide el usuario y se anota en
vision.md.

### 11.4 Textos legales y consentimientos
- `platform/legal/terms-1.md`, `privacy-1.md` y `rules-1.md` (las normas de social.md §9 y `docs/normas.md`,
  SOC-18): **borradores** con la cabecera «Borrador pendiente de revisión legal; no es asesoramiento jurídico». Al
  arrancar, la plataforma calcula su SHA-256 e inserta la versión en `legal_documents` si falta.
- Edad: casilla «Tengo 16 años o más» (`age_confirmed_at`; **revisión legal**: en España es desde los 14).
  Consentimientos separados, desmarcados y cambiables en Ajustes: informes de fallos (TEC-42) y analítica (TEC-44).

## 12. Operación (TEC-28)

| Pieza | Aquí (automatizable) | En el VPS (usuario) |
|---|---|---|
| Desarrollo local | `deploy/dev.sh`: PostgreSQL efímero en `build/dev_pg` (como §2.6), `migrate up`, claves y token de desarrollo en `build/dev_platform.env`, `admin create-account prueba@eldmark.test` y la orden de la zona con `--platform` | — |
| Imagen | `deploy/Dockerfile`: binario estático (`CGO_ENABLED=0`) sobre `debian:bookworm-slim`, usuario sin privilegios | Registro de imágenes (GHCR) |
| Compose | `docker-compose.yml` con `db` (postgres:16), `platform`, `caddy` y las zonas de TEC-20; `staging.env.example` y `production.env.example`. `docker compose config -q` lo valida sin demonio (comprobado) | Bases y secretos por entorno; staging desde `main`, producción desde tags (SSH) |
| Mantenimiento | `admin maintenance --in 10m --message "…"`: `/v1/status` lo anuncia, `enter` responde 503 salvo a `admin`, y el latido lo pasa a las zonas, que avisan por NOTICE a los 10, 5 y 1 min, 30 s y 10 s, guardan a todos y se paran solas. `admin maintenance off` lo quita | `deploy.sh`: copia previa, parar, `migrate up`, versión nueva, quitar el mantenimiento |
| Vuelta atrás | Cada migración con su `down`, probada en CI | Tag anterior tras `migrate down`, o restaurar la copia previa |
| Copias | `backup.sh`: `pg_dump -Fc` con 7 diarias y 4 semanales en un directorio | Subirlas a S3 compatible (rclone o WAL-G) y el cron |
| WAL y recuperación a un instante | `pitr_check.sh`: clúster efímero con `archive_command`, `pg_basebackup`, `recovery_target_time` y `recovery.signal`: recupera las filas de antes de un borrado (comprobado en segundos) | `archive_command` a S3 con WAL-G |
| Restauración semanal | `restore_check.sh <copia>`: clúster efímero, `pg_restore` (comprobado: 1000 filas en 188 ms), `migrate status` al día y consultas de integridad (personajes sin cuenta, arrendamientos de instancias inexistentes: 0) | Ejecutarlo cada semana y alertar si falla (TEC-31) |

## 13. Cliente (UI-22, UI-23, UI-24)
### 13.1 Flujo
```
título ──Entrar──▶ (aceptar textos nuevos) ──▶ selección ──Entrar──▶ OnlineMain con billete
  │ Crear cuenta · ¿Has olvidado la contraseña?      │ Crear ──▶ creación ──▶ selección
  └ Ajustes (F10) · Salir                            │ Borrar · Restaurar · Cerrar sesión ──▶ título
OnlineMain: rechazo o desconexión ──▶ selección con el motivo (la sesión sigue)
```

`FrontMain` (`scenes/client/front_main.tscn`) monta las pantallas y guarda la `AccountSession`. Al entrar, pasa a
`OnlineMain` un `ClientConfig` con host, puerto, `character_id`, billete, certificado DTLS, nombre y reino; con
`config.from_front`, `OnlineMain` vuelve a `FrontMain` en vez de a `RealmSelect`. Lo visual es **provisional**: tema
de UI-02, `UIWindow`, `UIConfirmDialog`; el fondo, el logotipo y la música son de ART-21.

### 13.2 Pantallas
| Pantalla | Contenido | Teclado |
|---|---|---|
| Título (UI-22) | Fondo provisional (captura fija del Vado Gris), «Eldmark» con la fuente de títulos, estado («En línea · Eld», «En mantenimiento hasta las 18:00», «Sin conexión con el servidor») y noticias de `/v1/status`; correo, contraseña, «Recordar correo» (`user://settings.cfg`, sección `account`; nunca la contraseña), Entrar, Crear cuenta, ¿Has olvidado la contraseña?, Ajustes, Salir | Intro entra; Tab recorre; Esc cierra el panel |
| Crear cuenta | Correo, contraseña dos veces (mínimo 10), «Tengo 16 años o más», tres casillas con enlace a cada texto (panel con desplazamiento) y los dos consentimientos opcionales | |
| Recuperar · aceptar textos | Correo → «Si existe una cuenta, te hemos enviado un enlace» · qué ha cambiado, Aceptar o Cerrar sesión | |
| Selección (UI-23) | Lista a la izquierda (nombre, emblema del reino, nivel, última zona; los borrados en gris con «Restaurar» y su fecha límite), vista 3D del elegido (`HumanoidVisual` con su apariencia y los colores de su reino), huecos libres, Entrar, Crear, Borrar (confirmación escribiendo el nombre), Cerrar sesión | Flechas eligen, Intro entra, Supr borra |
| Creación (UI-24) | 1) Reino: tarjetas con lore, emblema y capital; fijado al de la cuenta; Askarra «Próximamente». 2) Cuerpo y apariencia (cuerpo, cabeza, pelo, colores, aleatorio, cámara orbital con el ratón) con lo que haya de ART-19 y ART-20; sin ello, el humanoide con los colores del reino. 3) Nombre validado con `NameRules` al escribir y con `name-check` tras 500 ms quieto. Crear | Esc vuelve un paso |
| Renombrar · ocupado | Diálogo de nombre al recibir `rename_required` · «Tu personaje está saliendo del mundo…» con cuenta atrás; reintenta cada 3 s durante 30 s | |

Errores: el texto de §4.1 bajo el formulario; sin conexión o fallo de TLS, «No se puede conectar con el servidor de
cuentas». Los REJECT nuevos vuelven a la selección con su texto.

### 13.3 Configuración y archivos
`ClientConfig` añade `platform_url` (`--platform=`), `login` (`--login=`), `password_file` (`--password-file=`),
`character_name` (`--character=`), `world_id` (`--world=`, 1), `title` (`--title`) y, para `OnlineMain`,
`character_id`, `ticket: PackedByteArray`, `dtls_cert_pem`, `dtls_name` y `from_front`; y el modo `TITLE`.
Prioridad: `--bots` > `--bot` > `--connect`/`--local` > `--title`/`--platform` > sin argumentos (sandbox en el
editor, título exportado). Ajuste de proyecto `eldmark/platform/url` (`http://127.0.0.1:24680`; la exportación de
pruebas lo cambia).

Nuevos: `scripts/client/platform/` (`platform_api.gd`, `api_result.gd`, `account_session.gd`, `platform_errors.gd`),
`scripts/client/front_main.gd` y `scripts/client/ui/` `title_screen.gd`, `register_panel.gd`, `terms_panel.gd`,
`character_select.gd`, `character_create.gd`, `rename_dialog.gd` (escenas en `scenes/ui/`). `ClientLauncher` lleva
`TITLE` a `FrontMain`; `NetClient` pone en el HELLO `character_id`, `ticket`, `realm` y `name` de `ClientConfig` y
llama a `dtls_client_setup` si hay certificado.

## 14. Paquetes y contratos
### 14.1 Paquetes
| Paquete | Contenido | Depende de |
|---|---|---|
| **P0 · esqueleto** (TEC-22) | `platform/`, config, `logx`, `db`, `migrate` y 0001–0005, `testdb`, `/health`, `/ready`, `serve`/`migrate`, `.gdignore`, filtro de exportación, trabajo de CI | TEC-03 |
| **P1 · cuentas** (TEC-23, TEC-41, aceptación de TEC-43) | `passwords`, `accounts`, sesiones, límites, ciclo de vida, `mail`, `/verify`, `/reset`, `/v1/status`, `/v1/legal` | P0 |
| **P2 · personajes** (TEC-24, SOC-13, PRG-41) | `names`, `gamedata` y `tools/platform/export_gamedata.gd`, personajes, reinos, huecos, `enter`, `tickets` | P1; ART-19 y PRG-14 para validar la apariencia (sin ellos, §4.4 paso 5) |
| **P3 · API interna** (TEC-24, TEC-25) | `zones` (registro, latido, perdidas), reclamación, guardado, liberación, lotes, `item-uid-blocks`, `jsonProgressStore` | P2 |
| **P4 · billete en la zona** (TEC-24) | `HandoffTicket`, `TicketAuthProvider`, `AuthProvider` y `ServerAuth` ampliados, `VERIFYING`, REJECT 10–12, `PROTOCOL_VERSION`, bit GM, `ZonePlatform`, `PlatformClient`, `tests/fake_zone_platform.gd`, opciones de `ServerConfig` | Los contratos de P3 (no su código: usa el falso) |
| **P5 · guardado en la zona** (TEC-25; ganchos de CMB-30 y GUE-19) | `CharacterSaver`, `CharacterRecord`, restauración al aparecer, salida en combate, cierre ordenado, `revoked` | P4 |
| **P6 · guerra** (GUE-19) | `FortressPersistence`, carga al arrancar, fortalezas y eventos, `state.pvp` | P3, P4 |
| **P7 · moderación** (SOC-14 a SOC-18) | Roles en `CommandRegistry`, `/gm`, auditoría, chat, ignorados, reportes, sanciones, `admin …` | P3, P4; SOC-03, SOC-04 |
| **P8 · cliente** (UI-22 a UI-24) | `ClientConfig`, `PlatformApi`, `AccountSession`, `FrontMain`, pantallas, `NetClient` y `OnlineMain` con billete, bot con cuenta | Contratos de P1 y P2 (con `request_hook` hasta tenerlos); ART-19 y ART-20 para la creación completa |
| **P9 · privacidad y operación** (TEC-43, TEC-27, TEC-28) | Exportación, purgas, retenciones, borradores legales, Caddy, compose, `dev.sh`, copias, `restore_check`, `pitr_check`, DTLS | P1–P3; TEC-20 |
| **P10 · extremo a extremo** | `platform/e2e` (§15) | P3, P4, P5, P8 |

P0 primero; P1 y P4 a la vez (P4 contra el falso); luego P2, P3 y P8; luego P5, P6 y P7; P9 y P10 al final.
`zone_server.gd` lo tocan P4, P5 y P7, en ese orden.

### 14.2 Contratos en Go
```go
// internal/tickets
const Size = 52
type Ticket struct { Version, KeyID uint8; WorldID uint16; TicketID, CharacterID uint64; ZoneKey uint32
	Channel, Realm, Arrival, Flags uint8; IssuedAt, ExpiresAt uint32 }
func ZoneKey(zoneID string) uint32                                   // sha256(zoneID)[0:4] en LE
func (t Ticket) Sign(key []byte) [Size]byte
func Parse(b []byte, keys map[uint8][]byte) (Ticket, error)          // ErrSize, ErrVersion, ErrKey, ErrMAC
// internal/passwords
type Params struct { MemoryKiB, Time uint32; Threads uint8 }
func Hash(password string, p Params) (string, error)                 // $argon2id$v=19$m=…,t=…,p=…$sal$hash
func Verify(password, phc string, current Params) (ok, needsRehash bool, err error)
// internal/names: func Validate(name string) Reason (valores de NameRules.Reason); func NormalizeKey(name string) string
// internal/testdb: func Main(m *testing.M) int (en TestMain); func New(t testing.TB) *pgxpool.Pool (base nueva)
// internal/persistence
func (s *Store) Claim(ctx context.Context, zone [16]byte, ticketID, characterID int64) (ClaimResult, error)
func (s *Store) Save(ctx context.Context, characterID int64, req SaveRequest) (SaveResult, error)
func (s *Store) SaveMany(ctx context.Context, zone [16]byte, reqs []SaveRequest) ([]SaveResult, error)  // todo o nada
func (s *Store) Release(ctx context.Context, characterID int64, leaseID [16]byte) error
```

### 14.3 Contratos en GDScript (zona)
```gdscript
# scripts/server/auth_provider.gd (amplía; DevAuthProvider: OK al instante y uses_tickets() false)
const PENDING: int = -1
func authenticate(peer_id: int, hello: NetMessages.Hello) -> int  # OK, PENDING o motivo de REJECT
func take_completed() -> Array[AuthOutcome]     # los PENDING resueltos, en orden de llegada
func cancel(peer_id: int) -> void               # el peer se fue esperando: libera si llegó a reclamar
func uses_tickets() -> bool                     # true: ServerAuth no mira reino ni nombre del HELLO
# scripts/server/platform/auth_outcome.gd
class_name AuthOutcome extends RefCounted
var peer_id: int; var result: int; var text: String; var record: CharacterRecord   # text vacío: result_text
# scripts/server/platform/handoff_ticket.gd: un var int por campo de §5.1, con su nombre
class_name HandoffTicket extends RefCounted
const SIZE: int = 52
static func zone_key_of(zone_id: String) -> int
static func decode(bytes: PackedByteArray) -> HandoffTicket      # null si tamaño o versión no valen
func verify(bytes: PackedByteArray, keys: Dictionary[int, PackedByteArray]) -> bool
func sign(key: PackedByteArray) -> PackedByteArray                # pruebas y el falso
# scripts/server/platform/character_record.gd
class_name CharacterRecord extends RefCounted
var character_id: int; var account_id: int; var world_id: int; var realm: int; var display_name: String
var role: StringName; var appearance: PackedByteArray; var lease_id: String; var state_version: int
var state: Dictionary; var progress: Dictionary; var muted_until_unix: int; var ignored_accounts: PackedInt64Array
static func from_claim(body: Dictionary) -> CharacterRecord       # null si falta algo
# scripts/server/platform/zone_platform.gd (tests/fake_zone_platform.gd tiene la misma interfaz)
class_name ZonePlatform extends Node
func start(config: ServerConfig, secrets: Dictionary) -> void     # registro y latidos
func claim(peer_id: int, ticket: HandoffTicket) -> void
func save(character_id: int, body: Dictionary) -> void            # una en vuelo por personaje
func release(character_id: int, lease_id: String) -> void
func enqueue_batch(kind: StringName, entry: Dictionary) -> void   # &"chat", &"audit", &"war"
func request(kind: StringName, path: String, body: Dictionary, context: Variant) -> void
func take_events() -> Array[PlatformEvent]                        # en el paso «poll»
func flush_and_wait(max_ms: int) -> bool
func now_unix() -> int                                            # reloj corregido
func is_registered() -> bool
# scripts/server/platform/character_saver.gd
class_name CharacterSaver extends RefCounted
func _init(platform: ZonePlatform, interval_ticks: int = 3600) -> void
func register_section(section: StringName, build: Callable, restore: Callable) -> void
func track(net_id: int, record: CharacterRecord, tick: int) -> void   # tras el alta; llama a restore
func mark_critical(net_id: int, reason: StringName) -> void
func step(tick: int) -> void                                          # tras «altas»
func finish(net_id: int, reason: StringName) -> void                  # guardado final con release
func on_event(event: PlatformEvent) -> void
func pending_count() -> int
```

`PlatformEvent` (`kind`, `context`, `transport_ok`, `status`, `body`, `error_code`) es el resultado de una petición.
`ServerConfig` añade `--platform=<url interna>`, `--world=<id>` (1), `--channel=<n>` (0),
`--public-address=<host>[:<puerto>]` (127.0.0.1 y su puerto), `--save-interval=<s>` (60), `--dtls-cert=` y
`--dtls-key=`; `ServerMain` elige el `AuthProvider` y `ServerAuth.validate` recibe el `peer_id` como primer
argumento para pasárselo. **Orden del tick** (amplía zone_server.gd): en `poll`, tras el
transporte, `platform.take_events()` se reparte (reclamaciones al proveedor, guardados a `CharacterSaver`, `revoked`
y silencios a la zona, fortalezas a `FortressPersistence`) y luego `auth_provider.take_completed()`; cada 10 ticks,
los `VERIFYING` vencidos; tras `altas`, `CharacterSaver.step(s)`.

### 14.4 Contratos en GDScript (cliente)
```gdscript
# scripts/client/platform/platform_api.gd
class_name PlatformApi extends Node
signal session_lost(code: String)               # refresco imposible: vuelta al título
var base_url: String
var request_hook: Callable = Callable()         # pruebas: (method, path, body) -> ApiResult
## Corrutina: var r: ApiResult = await api.call_api(HTTPClient.METHOD_POST, "/v1/sessions", {…}, false)
func call_api(method: HTTPClient.Method, path: String, body: Variant = null, auth: bool = true) -> ApiResult
# scripts/client/platform/api_result.gd y account_session.gd
class_name ApiResult extends RefCounted
var ok: bool; var status: int; var data: Dictionary; var code: String; var message: String; var retry_after_s: int
class_name AccountSession extends RefCounted
var access_token: String; var refresh_token: String; var access_expires_msec: int; var account: Dictionary
func needs_refresh(now_msec: int) -> bool       # a 60 s de caducar
func clear() -> void
```

## 15. Pruebas

Cada prueba, menos de 30 s (Go con la caché caliente). Go: `cd platform && go test ./...`; Godot: el ejecutor de
siempre, que falla ante cualquier error del motor. El reloj de Go es inyectable (`clock.Now`) para los plazos.

| Paquete | Pruebas |
|---|---|
| P0 | `migrate`: up, down a 0 y up con el esquema igual; suma alterada → error; dos ejecutores a la vez (bloqueo). `config`: variable que falta → no arranca. `/ready` con la base parada → 503 |
| P1 | Contraseña buena, mala y correo inexistente (mismo código); 5 fallos → bloqueo y desbloqueo al vencer; 11 intentos por IP → 429; acceso caducado → 401 y refresco; refresco rotado reutilizado → familia revocada; segunda sesión revoca la primera; enlaces de verificación, recuperación y cambio de correo caducados y usados; borrado y cancelación en plazo; `needsRehash` |
| P2 | `names` con `tests/data/name_rules_cases.json` y `test_platform_gamedata.gd` (Godot); dos creaciones simultáneas del mismo nombre (una `name_taken`); «Anéira» frente a «aneira»; reino bloqueado; huecos; borrar, restaurar y nombre reservado; `enter` sin zona viva → 503; vector del billete de §5.1 |
| P3 | Reclamación con billete consumido, caducado, de otra instancia y de sesión revocada; dos zonas a la vez (una gana); libre a los 15 s sin latido (plazos cortos); instancia sustituida; guardado repetido (`duplicate`), viejo (`seq` menor), ajeno (`lease_lost`), tardío tras liberar (vale) y tras otra reclamación (no vale); `SaveMany` con un `uid` repetido no escribe nada; 100 guardados concurrentes del mismo personaje: `state_version` = aplicados |
| P4 | `test_handoff_ticket.gd`: vector, firma alterada, clave desconocida, otra zona, caducado, desfase de 5 s, reutilizado; `test_net_messages`: REJECT 10–12 y bit GM; `test_zone_server_platform.gd` con `FakeZonePlatform` y ENet real: billete → `VERIFYING` → WELCOME; sin billete → `TICKET`; plataforma muda 240 ticks → `UNAVAILABLE`; peer que se va en `VERIFYING` → liberación; `BUSY` y `BANNED` con su texto |
| P5 | Con el falso: punto de control (intervalo de prueba de 120 ticks), fases repartidas, crítico al instante, una escritura en vuelo, salida en combate guarda al irse el cuerpo, muerto se guarda para reaparecer, el cierre ordenado espera, `lease_lost` expulsa, restauración de vida y secciones |
| P6 | Ida y vuelta de `FortressPersistence` (ticks ↔ Unix con reloj fijo); arrancar con `CONSOLIDATING` a medias conserva dueño y plazo; `CAPTURING` vuelve como `VULNERABLE`; lote de eventos reenviado sin duplicar |
| P7 | Sin rol → «Comando desconocido»; auditoría consultable; un ignorado no susurra, no invita ni llega a su canal de zona; reporte con prueba y límite de 1 cada 10 min; silencio con su tiempo restante; suspensión expulsa por el latido y rechaza `enter`; renombrado forzado |
| P8 | `test_client_config`: modos y prioridad; `PlatformApi` con `request_hook` (refresco ante 401, mapa de errores); pantallas con datos falsos (nombre, borrado escribiendo el nombre, Entrar desactivado sin personaje); `NetClient` pone el billete en el HELLO |
| P9 | Exportación con todas las secciones; la purga deja la lápida; las retenciones borran lo caducado y nada más; `restore_check.sh` sobre una copia de la base de prueba |
| P10 | `go test -tags e2e ./e2e` (con Godot importado): `TestEnterAndSave` (plataforma en el proceso, PostgreSQL efímero, `test_world` con `--platform` y un `--bot` con cuenta: entra, guarda, sale, `state_version > 0`); `TestZoneCrash` (`--save-interval=5`, TTL de 6 s y latido de 1 s: `kill -9` a la zona; la posición guardada tiene menos de 5 s más el margen y el bot vuelve a entrar en una instancia nueva). Cada una < 30 s |

## 16. Riesgos

| Riesgo | Mitigación |
|---|---|
| Relojes de zona y plataforma desfasados (billetes de 10 s) | `now_unix` en cada respuesta, 5 s de margen y aviso a partir de 2 s |
| Partición entre zona y plataforma con el cliente llegando a las dos: el personaje entra en otra zona | La vieja recibe `lease_lost` y lo expulsa sin guardar; se pierde lo jugado allí. Raro en un mismo centro de datos; se revisa con TEC-29 |
| `HTTPRequest` en el servidor de zona: coste y orden de las señales | Cola de 4 en vuelo, lotes, resultados solo en «poll»; `ServerMetrics` mide la sección `platform` |
| Un fallo de TLS registra un ERROR del motor | Ninguna prueba de Godot lo provoca (§10.1); TLS se prueba en Go |
| DTLS con `GuardedEnetPeer` y `SceneMultiplayer`, y su coste, sin comprobar | TEC-27 lo mide con el criterio relativo de §10.2; sin DTLS no hay pruebas públicas |
| Versiones de Go y PostgreSQL de la CI (`ubuntu-latest`, sin comprobar) | Versiones fijas y `GOTOOLCHAIN=local` (§2.2); `ELDMARK_REQUIRE_PG=1` hace evidente que falta PostgreSQL |
| Una sola instancia de la plataforma (punto único de fallo; límites en memoria) | Vale para pruebas cerradas; quien juega sigue si cae (§7.4). Varias instancias con TEC-38 |
| El JSON de `state` y `progress` cambia | `state_schema` y `upgradeState`; el progreso de verdad va a tablas (PRG-10) |
| `progresion.md` y `habilidades.md` se escriben a la vez | Frontera en §7.1 y §7.5, migraciones 0010+ para PRG, `state.combat` opaco para CMB-30 |
| Textos legales, edad, retenciones y exportación | Borradores marcados; revisión humana antes de cualquier prueba pública |
| `zone_server.gd` lo tocan P4, P5 y P7 (y la fase 4 aún lo cambia) | Orden fijo P4 → P5 → P7 y pasos del tick con nombre (§14.3) |
