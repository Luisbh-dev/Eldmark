# Eldmark · Fase 5: diseño de la plataforma

Diseño del paso 5 de la [hoja de ruta](vision.md#hoja-de-ruta): cuentas, personajes y guardado en base de datos.
Cubre el servicio de plataforma y todo lo que pasa por él: TEC-22 a TEC-25, TEC-27, TEC-28, TEC-41, TEC-43, PRG-41,
SOC-13 a SOC-18, GUE-19 y el cliente de UI-22 a UI-24.

Se apoya en la red ([red.md](red.md): §3 conexión, §5.3 autenticación, §12 seguridad, §15 extensión, §17 contratos),
el combate ([combate.md](combate.md) §1 y §5), el fuerte ([fuerte.md](fuerte.md) §5) y lo social
([social.md](social.md) §8 a §11). Objetos, inventario, monedas, niveles, razas, apariencia y la configuración de
combate que se guarda (CMB-30) son de `docs/progresion.md` (PRG-02, PRG-10 a PRG-16, CMB-30, ART-19, en marcha a la
vez). Aquí están la frontera (§7.5) y lo que ese documento tiene que adoptar (§17). Revisado tras tres revisiones
(§18).

Lo que se da por comprobado se midió en esta máquina con sondas en `build/` (Go 1.24.7, PostgreSQL 16.15, Godot
4.7.2 headless; las de la revisión, en `build/probe_rev/`, que no se sube). Lo que no, está marcado «sin comprobar»
y en §16.

## 0. Decisiones

Provisionales, **tomadas de noche** con la recomendación del backlog; están en «Decisiones tomadas» de
[backlog.md](backlog.md) con esa marca.

| Pregunta | Decisión |
|---|---|
| Tecnología del servicio | **Go + PostgreSQL**, servicio propio. Sin ORM ni framework web: `net/http` de la biblioteca estándar, `pgx` y `x/crypto/argon2` |
| Estrategia de guardado | **Punto de control cada 60 s** si hubo cambios, más escritura inmediata de los eventos críticos, al salir y al cerrar la zona; con arrendamiento e idempotencia por `(lease_id, seq)` (§7) |
| Uno o varios mundos | **Un solo mundo** al lanzar (`world_id = 1`, «Eld»), con `world_id` en el esquema desde la primera migración |
| Cifrado cliente ↔ zona | **DTLS de ENet** si su coste medido (TEC-27) cabe; el certificado de la zona lo entrega la plataforma por HTTPS y el cliente lo ancla (§10.2). Sin DTLS no hay pruebas públicas: en `staging` y `production` la plataforma no registra una zona sin certificado |
| Reinos por cuenta | **Un reino por cuenta y mundo.** El cambio de toda la cuenta con 30 días de espera llega más adelante; en la fase 5 el reino solo se libera 30 días después de borrar el último personaje |
| Ignorar | **A la cuenta, en silencio** (social.md §10). El servidor filtra también los canales públicos (§9.3) |
| Retención del chat | **30 días** todos los canales, susurros incluidos; **1 año** lo copiado a un reporte o una sanción. Revisión legal antes de las pruebas públicas |

Decisiones de este documento que no estaban en el backlog (provisionales, de noche):

| Pregunta | Decisión |
|---|---|
| Inicio de sesión | Correo y contraseña; una sesión de juego activa por cuenta (la nueva cierra la anterior y expulsa a su personaje) |
| Contraseñas | argon2id, m = 19 456 KiB, t = 2, p = 1 (59 ms aquí); cadena PHC |
| Tokens | Opacos, aleatorios, guardados como SHA-256: acceso de 15 min y refresco que rota en la misma fila de `sessions`. La sesión dura 12 h desde el inicio de sesión: rotar no la alarga. El cliente los guarda solo en memoria |
| Edad mínima | 16 años, declarada al crear la cuenta. **Revisión legal** |
| Huecos | 6 personajes por cuenta y mundo, ampliables con derechos (§11.3); los borrados que aún se pueden restaurar ocupan hueco |
| Reinos abiertos | Vardheim y Solmarch: el Vado Gris no admite Askarra, que sale como «Próximamente» |
| Borrado | Personaje: restaurable 7 días; su nombre, reservado esos 7 días y 30 más. Cuenta: 14 días de gracia |
| HTTPS | La plataforma habla HTTP; Caddy delante pone HTTPS con Let's Encrypt (§10.1) |

Tomadas en la revisión (§18), **provisionales, tomadas de noche**:

| Pregunta | Decisión |
|---|---|
| Frontera con progresion.md | **Una sola tubería.** La reclamación trae el `CharacterRecord` de progresion.md antes del WELCOME. `CharacterSaver` (TEC-25, aquí) decide cuándo se guarda; `ProgressService` (progresion.md) decide qué. Idempotencia por `(lease_id, seq)`, sin `save_id` ni `base_version` (§7.5, §17) |
| Volver al mundo | **La regla de progresion.md §8**: el sitio guardado si es la misma zona y canal, hace menos de 15 min y sin combate; si no, el campamento. La vida se regenera con el tiempo pasado. Está también en «Decisiones tomadas» del backlog |
| Criterio de TEC-27 | **Relativo**: con 64 bots, DTLS no sube el p99 del tick más de un 10 % frente a la misma prueba sin DTLS, y la cifra absoluta se anota. El absoluto del backlog (8 ms) no se cumple ni sin DTLS (15,9 ms, red.md §14). **Pregunta para el usuario**; está en «Decisiones tomadas» del backlog |
| Libro mayor tras borrar | El personaje purgado queda como **lápida** sin datos personales; su libro y sus eventos de objeto, 1 año más y luego se borran (§11.1). **Revisión legal** |
| `auth_timeout` | **10 s** en los dos lados (antes 5 s), en la subida de protocolo de la fase 5: deja sitio a la reclamación (§5.2) |
| Instancia perdida que vuelve | Se cierra (expulsa con guardado final) y el orquestador la arranca de nuevo; no revive (§6.1) |

Quedan para el usuario: el modelo de negocio (PRG-41; el esquema admite cualquiera, §11.3), el proveedor y la región
del VPS, los textos legales definitivos, el dominio, **el proveedor SMTP y el DNS del correo** (SPF, DKIM y DMARC:
staging no arranca sin SMTP, §4.3), **la revisión visual de UI-22 a UI-24** (lista de comprobación de §15) y **el
criterio de TEC-27** (absoluto o relativo). El backlog lo marca «pendiente del usuario» en cada entrada.

## 1. Piezas y qué decide quién

El cliente habla HTTPS con la API pública de la plataforma (:24680) y UDP (ENet con DTLS) con la zona; la zona habla
HTTP con la API interna (:24681, red privada); solo la plataforma toca PostgreSQL 16.

| Qué | Lo decide | Notas |
|---|---|---|
| Identidad, contraseña y sesión | Plataforma | La zona nunca ve contraseñas ni tokens de sesión |
| Reino y nombre | Plataforma, al crear el personaje | En la zona, `HELLO.realm` y `HELLO.name` se ignoran: mandan los de la reclamación |
| Raza, apariencia y plantilla de inicio | progresion.md (qué valen); la plataforma las valida al crear (§4.4) | Con `progression_rules.json` |
| A qué zona entra | Plataforma (`enter`) | La última (`character_progress.last_zone_id`) si tiene una instancia viva que admite su reino; si no, la de entrada |
| Si el billete vale | Zona (formato, firma, zona, caducidad) y plataforma (un solo uso, arrendamiento) | §5 |
| Estado del personaje en juego | Zona | La plataforma aplica lo que le mandan con las comprobaciones S1–S9 de progresion.md (§7.3) |
| Cuándo se guarda, `seq`, reintentos | Zona: `CharacterSaver` (§7.2) | progresion.md da el contenido |
| Sanciones y roles | Plataforma | Comprueba el rol del autor (§9.5); la zona las aplica al entrar, con el latido y en `ChatRouter` |
| Estado de las fortalezas | Zona | La plataforma lo guarda y lo devuelve al arrancar (§8) |
| Esquema y migraciones | Plataforma (también las del progreso, P3b) | Las zonas no tienen credenciales de la base |

```
Cliente                         Plataforma                            Zona
                                 ◀── registro (starting), fortalezas ── antes de abrir el puerto
                                 ◀── …/live ─────────────────────────── puerto abierto
POST /v1/sessions ─────────────▶ sesión
POST /v1/characters/42/enter ──▶ sin arrendamiento vivo: billete
◀── host, puerto, billete (52 B), certificado DTLS
HELLO (character_id, billete) ────────────────────────────────────────▶ firma, zona, caducidad (VERIFYING)
                                ◀── POST /internal/v1/claims ──────────
                                consume el billete, arrendamiento ────▶ lease_id, cuenta y CharacterRecord
◀──────────────────────────────────────────────────────────── WELCOME (reino del personaje)
carga la zona, CLIENT_READY ──────────────────────────────────────────▶ alta con el registro (progresion.md §9.1)
                                ◀── PUT …/state (lease_id, seq): cada 60 s, críticos, al salir
```

## 2. El servicio (TEC-22)
### 2.1 Estructura
```
platform/            go.mod: module eldmark/platform, go 1.24.0, toolchain go1.24.7 · .gdignore (Godot no la escanea)
  cmd/eldmark-platform/   subcomandos serve, migrate, admin
  internal/  config logx db httpx (enrutador, errores, límites) jsonx (enteros e ids del JSON, §4.1) migrate
             (+ migrations/*.sql con embed) testdb passwords accounts names gamedata (progression_rules.json, §4.4)
             characters tickets zones persistence progress (P3b: tablas y S3–S9 de progresion.md) war social
             privacy mail
  e2e/  legal/ (terms-1.md, privacy-1.md, rules-1.md)  deploy/ (Dockerfile, docker-compose.yml, Caddyfile,
        journald-eldmark.conf, *.env.example, secrets/ (ignorada), dev.sh, backup.sh, restore_check.sh, pitr_check.sh)
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
| `ELDMARK_ZONE_TOKENS` | — | Secreto. Una entrada por despliegue de zona: `<mundo>:<zona>:<canal>:<SHA-256 en hex del token>`, separadas por comas; dos con el mismo alcance durante una rotación. Solo se guardan hashes (§6) |
| `ELDMARK_ZONE_HOSTS` | `127.0.0.1` | `public_host` que admite el registro, separados por comas |
| `ELDMARK_TRUSTED_PROXIES` | `127.0.0.1/32` | CIDR desde el que se lee `X-Real-IP`: el del contenedor de Caddy (§4.2) |
| `ELDMARK_TICKET_KEYS` · `ELDMARK_TICKET_SIGN_KEY` | — · la mayor | Secreto `1:<base64 de 32 B>,2:<…>` · id con el que se firma. Una clave de menos de 32 B no arranca; la del vector de §5.1 (`00 01 … 1f`) tampoco, salvo en `test` |
| `ELDMARK_EMAIL_HMAC_KEY` | — (en `dev` y `test`, una fija de pruebas) | Secreto de 32 B para `sanctioned_email_hashes` (§11.2) |
| `ELDMARK_ARGON2` | `m=19456,t=2,p=1` | En `test`, `m=8,t=1,p=1` |
| `ELDMARK_MIN_PROTOCOL` | `dev` y `test`: el `protocol_version` de `progression_rules.json` · `staging` y `production`: **obligatoria** | Por debajo, 426 |
| `ELDMARK_OPEN_REALMS` · `ELDMARK_ENTRY_ZONES` | `vardheim,solmarch` · `vardheim=vado_gris,solmarch=vado_gris` | Reinos en los que se crea · zona de entrada por reino |
| `ELDMARK_REQUIRE_VERIFIED_EMAIL` | `false` en dev y test; `true` en el resto | Para entrar al mundo |
| `ELDMARK_MAIL` · `ELDMARK_SMTP_URL` | `log` · — | `log` (tabla `outbound_mail`) o `smtp`; secreto `smtp://usuario:clave@host:587` |
| `ELDMARK_TLS_CERT_FILE` · `ELDMARK_TLS_KEY_FILE` | — | Opcional: HTTPS directo (pruebas del anclaje) |
| `ELDMARK_HEARTBEAT_S` · `ELDMARK_LEASE_TTL_S` | `5` · `30` | Una instancia sin latido durante 3 × `HEARTBEAT_S` se da por perdida; la zona se cerca a 2 × (§5.3) |
| `ELDMARK_LEGAL_DIR` | `platform/legal` | Textos legales versionados |

**Registro:** `log/slog` con `JSONHandler` a la salida estándar. Campos: `time`, `level`, `msg`, `req` (id de
petición, también en `X-Request-Id`), `route`, `status`, `ms`, y `account` y `character` cuando se conocen.
**Nunca** se registran contraseñas, tokens, billetes, cuerpos ni texto del chat; el correo va enmascarado
(`a***@example.org`).

### 2.4 Migraciones
- `internal/migrate/migrations/NNNN_nombre.up.sql` y `.down.sql`, embebidos. **0001 a 0009 son de este documento**
  (0001–0006 en §3; 0007–0009 reservadas). **0010 a 0019 son el progreso** (P3b: el DDL de §3 que traduce
  progresion.md §3.3). Después, por orden de llegada. Un número nunca se reutiliza.
- Tabla `schema_migrations (version int primary key, name text not null, checksum bytea not null, applied_at
  timestamptz not null default now())`. El ejecutor toma `pg_advisory_lock(4815162342)`, aplica cada archivo en su
  transacción y se niega a seguir si el SHA-256 de uno aplicado ha cambiado.
- `eldmark-platform migrate up|down N|status`. `serve` no migra: si la base no está en la última versión, no arranca
  y `/ready` dice por qué.
- **Expandir y luego contraer.** El binario N funciona con el esquema N + 1: lo nuevo entra con valor por defecto o
  nulo, y nada se borra ni se renombra en la misma versión que deja de usarlo. Así volver al tag anterior no pide
  `down`.
- **`down` es solo para desarrollo y CI.** En staging y producción se vuelve atrás restaurando la copia previa o
  arreglando hacia delante (§12). Una migración sin inversa (de datos, o que borra) lleva `-- irreversible` en su
  primera línea y su `.down.sql` hace `do $$ begin raise exception 'irreversible'; end $$;`.
- CI: `up` → `down` hasta la última irreversible (o 0) → `up`, con el esquema final (`pg_dump -s`) igual.
  **Conservación:** con una fila en cada tabla (semilla `internal/migrate/testdata/seed_NNNN.sql`, la del esquema de
  esa versión), aplicar la siguiente migración no cambia ningún `count(*)`.

### 2.5 Arranque y salud
- `GET /health`: 200 si el proceso vive (sin tocar la base). `GET /ready`: 200 si `select 1` responde en menos de 1
  s y las migraciones están al día; si no, 503 con el motivo.
- Al arrancar, `serve` da 30 s de gracia: `last_heartbeat_at = greatest(…, now())` en las instancias `starting` y
  `live`, y `expires_at = greatest(expires_at, now() + TTL)` en los arrendamientos. Una plataforma que vuelve tras
  caerse no da por muertas a las zonas que no pudieron latir.
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
- El esquema entero de §3 (0001–0006 y 0010) se aplicó así en la revisión: el intercambio de ranuras con la
  restricción diferida, la lápida, el disparador de solo añadir y la retención con `set local` funcionan
  (`build/probe_rev/pg/`).
- **CI:** trabajo «Plataforma» en `.github/workflows/tests.yml`: `actions/setup-go` con `go-version-file:
  platform/go.mod`, `GOTOOLCHAIN=local`, `ELDMARK_REQUIRE_PG=1` y, en `platform/`, `go vet ./...` y `go test -p 2
  ./...` con el PostgreSQL de `ubuntu-latest` (sin comprobar; si falta, `apt-get install postgresql-16`). El mismo
  trabajo comprueba los secretos (§10.3). El trabajo «Plataforma e2e» es de P10 (§15).

## 3. Esquema SQL

Las tablas del juego llevan `world_id`; las de la cuenta, no. Reinos en `smallint` con los códigos de
`NetProtocol.Realm` (1 Vardheim, 2 Solmarch, 3 Askarra); en JSON, su id de texto (`"vardheim"`). `ts` abrevia aquí
`timestamptz` y `now_ts` `timestamptz not null default now()`; en los archivos van escritos enteros. Este DDL se
aplicó entero en PostgreSQL 16 (§2.6).

**Quién guarda qué** (igual en progresion.md, §17):

| Dato | Tabla | Dueño |
|---|---|---|
| Identidad: nombre, reino, cuenta, borrado, renombrado, lápida | `characters` | Este documento |
| Raza, apariencia, plantilla, nivel, XP, puntos de reino, tiempo jugado, vida, arma activa, última zona, posición, `saved_at`, `save_version` | `character_progress` | progresion.md (columnas) · P3b (DDL) |
| Inventario, monedas, operaciones, libro, eventos de objeto, habilidades, temporizadores | Las demás tablas de 0010 | progresion.md · P3b |
| Estadísticas PvP (GUE-19) | `character_pvp_stats` | Este documento |
| `lease_id`, `seq`, hash del último guardado | `character_leases` | Este documento |

No hay columnas JSON de estado del personaje: lo que no tenga columna llega con una migración.

```sql
-- 0001_accounts
create table worlds (world_id smallint primary key, name text not null unique, created_at now_ts,
  status text not null default 'open' check (status in ('open','locked','maintenance')));
insert into worlds (world_id, name) values (1, 'Eld');
create table accounts (account_id bigint generated always as identity primary key, email text unique, password_hash text,  -- null: purgada o pendiente de restablecer
  email_verified_at ts, role text not null default 'player' check (role in ('player','moderator','gm','admin')),
  status text not null default 'active' check (status in ('active','pending_deletion','purged')), age_confirmed_at ts not null,
  deletion_requested_at ts, purge_after ts, purged_at ts, created_at now_ts);
create table sessions (session_id bigint generated always as identity primary key, account_id bigint not null references accounts on delete cascade,
  access_hash bytea not null unique, access_expires_at ts not null, refresh_hash bytea not null unique, prev_refresh_hash bytea unique,
  refresh_expires_at ts not null,                                               -- inicio de sesión + 12 h; rotar no lo alarga
  ip inet, user_agent text, client_protocol int, created_at now_ts, rotated_at ts, revoked_at ts,
  revoke_reason text check (revoke_reason in ('logout','replaced','password_changed','email_changed','email_reverted',
    'refresh_reuse','role_changed','deletion','admin')));
create index on sessions (account_id) where revoked_at is null;
create table account_tokens (token_hash bytea primary key, account_id bigint not null references accounts on delete cascade,
  purpose text not null check (purpose in ('verify_email','reset_password','change_email','revert_email')),
  email text,                                                                   -- change_email: el nuevo; revert_email: el viejo
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
  account_id bigint not null references accounts, name text, name_key text,     -- null solo en la lápida (§11.2)
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
create table enter_tickets (ticket_id bigint primary key, world_id smallint not null references worlds,   -- ticket_id: u64 con bit 63 a 0
  character_id bigint not null references characters on delete cascade, session_id bigint not null references sessions on delete cascade,
  zone_instance_id uuid not null references zone_instances on delete cascade, issued_at ts not null, expires_at ts not null, consumed_at ts);
create table character_leases (character_id bigint primary key references characters on delete cascade,
  world_id smallint not null references worlds, lease_id uuid not null,         -- solo cambia al reclamar (§5.3)
  zone_instance_id uuid references zone_instances on delete set null,           -- null: libre
  claimed_by uuid not null,                                                     -- la instancia que reclamó; no cambia al liberar
  session_id bigint references sessions on delete set null,                     -- la del billete: revocarla expulsa
  expires_at ts, last_seq bigint not null default 0, last_save_hash bytea,      -- SHA-256 del último cuerpo aplicado (§7.3)
  claimed_at now_ts, released_at ts);
create index on character_leases (zone_instance_id) where zone_instance_id is not null;

-- 0004_war
create table fortresses (world_id smallint not null references worlds, fortress_id text not null, zone_id text not null,
  record jsonb not null, version bigint not null default 0, updated_at now_ts, updated_by uuid references zone_instances on delete set null,
  primary key (world_id, fortress_id));
create table fortress_events (id bigint generated always as identity primary key, world_id smallint not null references worlds,
  fortress_id text not null, event smallint not null check (event between 1 and 7), realm smallint not null check (realm between 0 and 3),
  at ts not null, zone_instance_id uuid references zone_instances on delete set null, event_key text not null unique);
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

-- 0006_privacy
create table purge_log (kind text not null check (kind in ('account','character')), id bigint not null, purged_at now_ts,
  primary key (kind, id));                                                      -- sin datos personales (§11.2)
create table sanctioned_email_hashes (hmac bytea primary key, until ts not null);  -- HMAC-SHA256 del correo (§11.2)

-- 0010_progress (P3b): progresion.md §3.3 con sus nombres; sin last_save_id (lo sustituye seq, §7.3)
create table character_progress (character_id bigint primary key references characters on delete cascade,
  race_id text not null, appearance bytea not null check (length(appearance) = 8),
  level smallint not null default 1 check (level between 1 and 40), xp_total bigint not null default 0 check (xp_total >= 0),
  realm_points bigint not null default 0 check (realm_points >= 0), played_seconds bigint not null default 0 check (played_seconds >= 0),
  bag_slots smallint not null default 30 check (bag_slots between 1 and 120), starter_template_id text not null,
  starter_granted boolean not null default false, health int check (health >= 0),                     -- null: llena
  active_weapon_slot smallint not null default 0 check (active_weapon_slot between 0 and 1), consumable_def_id text,
  last_zone_id text, last_channel smallint, pos_x real, pos_y real, pos_z real, yaw real,
  last_in_combat boolean not null default false, saved_at ts, save_version bigint not null default 0);
create table character_wallets (character_id bigint not null references characters on delete cascade,
  currency smallint not null check (currency in (1, 2)), balance bigint not null default 0 check (balance between 0 and 1000000000),
  last_seq bigint not null default 0, primary key (character_id, currency));
create table economy_ops (op_id bigint primary key check (op_id > 0), character_id bigint not null references characters,  -- sin cascada
  kind smallint not null check (kind between 1 and 8), actor_account_id bigint, ref_op_id bigint, zone_id text not null, created_at now_ts);
create table ledger_entries (entry_id bigint generated always as identity primary key, character_id bigint not null references characters,
  currency smallint not null check (currency in (1, 2)), seq bigint not null, op_id bigint not null references economy_ops,
  delta bigint not null check (delta <> 0), balance_after bigint not null check (balance_after >= 0), reason smallint not null,
  ref_kind smallint not null default 0, ref_id bigint not null default 0, created_at now_ts,
  unique (character_id, currency, seq), unique (op_id, character_id, currency));
create table item_instances (uid bigint primary key check (uid > 0), character_id bigint not null references characters on delete cascade,
  container smallint not null check (container between 0 and 3), slot smallint not null check (slot >= 0), def_id text not null,
  count int not null check (count between 1 and 999), durability smallint check (durability between 0 and 1000),
  rarity smallint not null default 0 check (rarity between 0 and 4), bound boolean not null default false,
  seed bigint not null default 0, affixes smallint[] not null default '{}' check (cardinality(affixes) <= 6), created_op bigint not null,
  constraint item_slot_unique unique (character_id, container, slot) deferrable initially deferred);
create table item_events (event_id bigint generated always as identity primary key, op_id bigint not null references economy_ops,
  character_id bigint not null references characters, uid bigint not null, def_id text not null,
  event smallint not null check (event between 1 and 3), count_delta int not null, reason smallint not null, created_at now_ts);
create index on item_events (uid); create index on item_events (character_id, event_id);
create table op_reversals (op_id bigint primary key references economy_ops, reversal_op_id bigint not null unique references economy_ops);
create table character_ability_slots (character_id bigint not null references characters on delete cascade, weapon_id text not null,
  slot smallint not null check (slot between 0 and 2), ability_id text not null, primary key (character_id, weapon_id, slot));
create table character_timers (character_id bigint not null references characters on delete cascade, key text not null,
  ends_at ts not null, stacks smallint not null default 1, primary key (character_id, key));
create table character_attributes (character_id bigint not null references characters on delete cascade, attribute smallint not null,
  spent smallint not null check (spent >= 0), primary key (character_id, attribute));
create table character_masteries (character_id bigint not null references characters on delete cascade, weapon_family text not null,
  level smallint not null, xp bigint not null default 0, primary key (character_id, weapon_family));
create sequence uid_block_seq start 1 increment 1024;                          -- uid y op_id (progresion.md §4.5)
create table id_blocks (first_id bigint primary key, zone_instance_id uuid not null, granted_at now_ts);  -- [first_id, first_id + 1023]
create function eldmark_append_only() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' and coalesce(current_setting('eldmark.retention_purge', true), '') = 'on' then
    return old;                                                                 -- solo la retención de §11.1
  end if;
  raise exception '% es de solo añadir', tg_table_name;
end $$;
create trigger append_only before update or delete on economy_ops for each row execute function eldmark_append_only();
create trigger append_only before update or delete on ledger_entries for each row execute function eldmark_append_only();
create trigger append_only before update or delete on item_events for each row execute function eldmark_append_only();
create trigger append_only before update or delete on op_reversals for each row execute function eldmark_append_only();
create function progress_purge_character(p_character_id bigint) returns void language sql as $$
  delete from item_instances where character_id = p_character_id;
  delete from character_wallets where character_id = p_character_id;
  delete from character_ability_slots where character_id = p_character_id;
  delete from character_timers where character_id = p_character_id;
  delete from character_attributes where character_id = p_character_id;
  delete from character_masteries where character_id = p_character_id;
  delete from character_progress where character_id = p_character_id;
$$;
```

- Cada `.down.sql` deshace su `.up.sql` en orden inverso.
- **Las cuatro tablas de solo añadir** (`economy_ops`, `ledger_entries`, `item_events`, `op_reversals`) no tienen
  cascada: un `delete from characters` con apuntes falla por la clave ajena, nunca a medias. Por eso el personaje no
  se borra al purgarlo: queda como lápida (§11.2). La marca `eldmark.retention_purge` no es una barrera de
  seguridad (cualquier rol puede ponerla): solo evita borrados por error. Se pone con `set local` y no sobrevive a
  la transacción (comprobado).

## 4. API pública (cliente ↔ plataforma)
### 4.1 Convenciones
- HTTPS y JSON en UTF-8, prefijo `/v1`, cuerpo de 16 KB como mucho (413). Campos desconocidos: 400.
- Cabeceras: `Authorization: Bearer <acceso>`, `X-Eldmark-Protocol: <PROTOCOL_VERSION>`, `X-Eldmark-Build: <build
  id>`. Sin protocolo o por debajo de `ELDMARK_MIN_PROTOCOL`: 426.
- **Todo id `bigint` viaja como cadena decimal**, en las dos API (pública e interna): `character_id`, `account_id`,
  `ticket_id`, `uid`, `op_id`, `seed`, `ref_id`, `report_id`, `sanction_id`… `JSON.parse_string` de Godot lee
  todo número como `float` y corrompe sin avisar lo que pasa de 2^53 (comprobado: `8152839359930207727` →
  `8152839359930208256.0`). Los enteros pequeños (`world_id`, reinos, cantidades, `seq`, fechas Unix) van como
  número. Billete y apariencia, en base64 estándar.
- **Enteros que manda Godot.** Al volver a serializar lo que leyó, Godot escribe `820.0` (comprobado). En Go, todo
  campo entero usa `jsonx.Int` (acepta `4` y `4.0`; rechaza `4.5` y lo que pasa de 2^53) y todo id `jsonx.ID`
  (cadena decimal > 0; un número sin comillas es 400). Comprobado con Go 1.24.7 y `DisallowUnknownFields`. En GDScript,
  quien lee un cuerpo convierte con `int()` cada entero y con `String.to_int()` cada id.
- Error: `{"error": {"code": "name_taken", "message": "Ese nombre ya está en uso", "retry_after_s": 0, "fields":
  {"name": "taken"}}}`. El cliente traduce por `code` (UI-04) y, si no lo conoce, muestra `message`. Con 429 y 503
  va también `Retry-After`.
- **Fuera de `/v1`** solo están `/health`, `/ready` y las páginas de los enlaces de los correos (§4.3), que hablan
  HTML y formularios, sin la regla del 426.

| HTTP | `code` | Cuándo | Texto |
|---|---|---|---|
| 400 | `bad_request`, `validation` | JSON roto; campos que faltan o no valen (`fields`) | «Datos no válidos» |
| 401 | `unauthorized` | Token ausente, caducado o revocado: el cliente refresca una vez y, si no, vuelve al título | «Tu sesión ha caducado» |
| 401 | `invalid_credentials` | Correo o contraseña mal (no se dice cuál ni si la cuenta existe) | «Correo o contraseña incorrectos» |
| 403 | `account_suspended`, `account_banned` | Sanción (`until`, `reason`). En el inicio de sesión, **solo tras una contraseña correcta** | «Cuenta suspendida hasta el …: motivo» |
| 403 | `email_unverified`, `account_pending_deletion` | Entrar al mundo sin verificar (si se exige) o con el borrado pedido (el inicio de sesión sí funciona, para poder cancelarlo) | «Verifica tu correo para entrar» · «Tu cuenta se borrará el …» |
| 403 | `terms_required` | Versiones nuevas por aceptar (`documents`) | Pantalla de aceptación |
| 404 | `not_found` | No existe o no es de la cuenta | «No encontrado» |
| 409 | `name_taken` | Nombre en uso o reservado (no se dice cuál) | «Ese nombre ya está en uso» |
| 422 | `name_invalid` | `reason`: `too_short`, `too_long`, `has_space`, `has_digit`, `invalid_character`, `not_capitalized`, `reserved` (también la lista negra) | `NameRules.reason_text` |
| 409 | `realm_locked` · `realm_closed` | Otro reino que el de la cuenta (`realm`, `unlock_at`) · fuera de `ELDMARK_OPEN_REALMS` | «Tu cuenta es de Vardheim» · «Ese reino abre más adelante» |
| 409 | `slots_full` · `rename_required` | Sin huecos · renombrado forzado | «No te quedan huecos» · diálogo de nombre |
| 409 | `character_busy` | Arrendamiento vivo (`retry_after_s` = 3) | «Tu personaje está saliendo del mundo…» |
| 426 | `client_outdated` | Protocolo antiguo (`min_protocol`) | «Actualiza el cliente» |
| 429 | `rate_limited` | Límite de ritmo, también los fallos de contraseña (§4.2) (`retry_after_s`) | «Demasiados intentos; espera N s» |
| 503 | `maintenance` · `zone_unavailable` | Mantenimiento (`message`, `until`) · ninguna instancia viva de la zona | El mensaje · «La zona no está disponible» |
| 500 | `internal` | Cualquier otro fallo (con `X-Request-Id`) | «Error del servidor» |

No hay `email_taken` ni `account_locked`: los dos delataban qué correos tienen cuenta (§4.2).

### 4.2 Cuentas y sesiones (TEC-23)
| Ruta | Cuerpo | Respuesta |
|---|---|---|
| `GET /v1/status` (sin token) | — | `{status: "ok"\|"maintenance", message, maintenance_at, min_protocol, worlds: [{world_id, name, status, load: "low"\|"medium"\|"high"}], news: [{title, body, date}]}` |
| `GET /v1/legal` · `GET /v1/legal/{kind}` (sin token) | — | `{terms: {version, sha256}, privacy, rules}` · el texto Markdown vigente |
| `POST /v1/accounts` | `{email, password, age_confirmed: true, accept: {terms, privacy, rules}, consents: {crash_reports, analytics}}` | **Siempre 202 `{}`** si el cuerpo vale (ver abajo) |
| `POST /v1/sessions` | `{email, password}` | `{access_token, access_expires_in, refresh_token, refresh_expires_in, account}` |
| `POST /v1/sessions/refresh` · `DELETE /v1/sessions/current` | `{refresh_token}` · — | Un par nuevo (el viejo deja de valer) · 204 |
| `GET /v1/account` | — | `{account_id, email, email_verified, role, realms: {"1": "vardheim"}, slots, consents, pending: {terms_required, deletion_at}}` |
| `POST /v1/account/accept` · `PUT /v1/account/consents` | `{terms, privacy, rules}` (versiones) · `{crash_reports, analytics}` | 204 |

- **Registro sin delatar cuentas.** `POST /v1/accounts` responde 202 `{}` y el cliente dice «Te hemos enviado un
  correo». Correo nuevo: crea la cuenta y manda `verify_email`. Correo que ya tiene cuenta: no crea nada y manda
  `register_existing` («Ya tienes una cuenta: ¿has olvidado la contraseña?»). Correo en `sanctioned_email_hashes`
  (§11.2): no crea nada y manda `register_blocked` («No se puede crear una cuenta con este correo hasta el …»).
  Los tres caminos cuentan en el mismo límite de correos y tardan lo mismo (se calcula el hash de la contraseña en
  los tres). Iniciar sesión no exige el correo verificado; entrar al mundo sí, con
  `ELDMARK_REQUIRE_VERIFIED_EMAIL`.
- **Correo:** en minúsculas y sin espacios alrededor; 3–254 B; `net/mail.ParseAddress` lo devuelve igual (sin
  nombre visible); solo ASCII imprimible sin espacios ni controles (`^[\x21-\x7e]+$`); una sola `@`; dominio con al
  menos un punto y sin etiquetas `xn--` (los IDN se rechazan en la fase 5); único. Un CR, LF o espacio dentro da
  400 `validation`. Los correos se arman con cabeceras codificadas (`mime.QEncoding`) y el destinatario va en `RCPT
  TO` y en un `To:` codificado: no hay inyección de cabeceras.
- **Contraseña:** 10 a 128 caracteres (512 B como mucho), distinta del correo, sin normalizar. `passwords.Verify`
  dice `needsRehash` si los parámetros de la cadena PHC no son los actuales, y el inicio de sesión la reescribe.
  Como mucho `runtime.NumCPU()` cálculos a la vez (19 MiB cada uno). Con un correo inexistente se calcula un hash de
  relleno: el tiempo no delata cuentas.
- **Una sola función comprueba contraseñas:** `accounts.CheckPassword(ctx, accountID, password, ip) (ok bool, err
  error)`, con `accountID` 0 para un correo inexistente. La usan el inicio de sesión y las rutas con sesión que
  piden contraseña (`/v1/account/password`, `/email`, `/deletion`, `/export`), con los mismos contadores.
- **Fallos de contraseña** (en memoria; una sola instancia en la fase 5; LRU de 100 000 claves). La clave de cuenta
  es el `account_id` o, si el correo no existe, su SHA-256:

| Clave | Regla |
|---|---|
| Cuenta y grupo de IP | 5 fallos seguidos → 15 min sin intentos desde ese grupo; 10 → 1 h |
| Cuenta, desde cualquier IP | Tras 5 fallos seguidos, un intento cada 30 s |
| Acertar | Reinicia las dos de esa cuenta |
| Respuesta al frenar | 429 `rate_limited` con `retry_after_s`; igual exista o no la cuenta |
| Aviso | Al 5.º fallo seguido, correo `login_failures` al dueño (uno cada 24 h como mucho) |

  Así 5 intentos desde una IP no dejan sin entrar al dueño desde la suya (TEC-23: el bloqueo temporal es por
  cuenta y grupo de IP).
- **Estado de la cuenta:** `account_suspended` y `account_banned` solo salen **tras una contraseña correcta**; con
  una mala, `invalid_credentials`. Una cuenta `purged` responde como un correo inexistente.
- **Sesión única de juego:** iniciar sesión revoca las demás de la cuenta (`revoke_reason = 'replaced'`) y el latido
  expulsa a su personaje (§6).
- **Tokens:** 32 B de `crypto/rand` en base64url sin relleno (43 caracteres); en la base, su SHA-256. Una fila de
  `sessions` por inicio de sesión, con `refresh_expires_at` = inicio + 12 h, **absoluto**. Acceso de 15 min, sin
  pasar de `refresh_expires_at`.
- **Refresco**, en una transacción:
  1. `update sessions set prev_refresh_hash = refresh_hash, refresh_hash = $nuevo, access_hash = $nuevo_acceso,
     access_expires_at = least(now() + 15 min, refresh_expires_at), rotated_at = now() where refresh_hash = $dado
     and revoked_at is null and refresh_expires_at > now()`.
  2. Sin fila y `prev_refresh_hash = $dado` en una sesión viva: se revoca con `revoke_reason = 'refresh_reuse'`, fila
     en `auth_events` y 401. Sin fila en ningún caso: 401.
  - `session_id` no cambia en toda la sesión: el arrendamiento de §5.3 sigue atado a ella y refrescar en partida no
    expulsa. Un refresco de hace dos rotaciones da 401 sin revocar (ya no se distingue de uno inventado).
  - `PlatformApi` hace un solo refresco a la vez (§14.4): dos refrescos simultáneos del propio cliente no se
    toman por reutilización.
- **Aceptación:** el registro exige las versiones vigentes de los tres textos. Con una versión nueva, `GET
  /v1/account` lo dice y `enter` responde `terms_required` hasta aceptarla.
- **IP del cliente.** Caddy pone `header_up X-Real-IP {remote_host}`. La plataforma lee **solo** `X-Real-IP` y solo
  si la conexión llega de `ELDMARK_TRUSTED_PROXIES`; si no, la IP de la conexión. Nunca `X-Forwarded-For`. Las IPv6
  cuentan por /64, como `ServerAuth.address_group`.

| Límite | Valor | Dónde |
|---|---|---|
| Inicio de sesión · registro, por IP | 10/min, ráfaga 10 · 3 por hora | Memoria (cubo de fichas) |
| Contraseñas falladas | Tabla de arriba (también en las rutas con sesión) | Memoria |
| Correos (verificación, recuperación, cambio, registro) · exportar datos | 3 por cuenta y hora y 10 por IP y hora · 1 al día | Memoria y `auth_events` |
| Comprobar nombre · entrar al mundo | 30/min por sesión · 10/min por cuenta | Memoria |
| Crear personaje · borrar personaje | 5 por cuenta y día cada uno | `auth_events` (`character_create`, `character_delete`) |

`auth_events.kind`: `register`, `register_existing`, `login_ok`, `login_fail`, `login_throttled`, `password_fail`,
`refresh_reuse`, `character_create`, `character_delete`, `export`, `email_changed`, `email_reverted`.

### 4.3 Ciclo de vida (TEC-41)
| Ruta | Cuerpo | Efecto |
|---|---|---|
| `POST /v1/account/verify-email` (sin token) · `…/verify-email/resend` | `{token}` · — | Verifica · 202, correo nuevo; los anteriores dejan de valer |
| `POST /v1/account/password-reset` (sin token) | `{email}` | **Siempre 202**, exista o no la cuenta |
| `POST /v1/account/password-reset/confirm` (sin token) | `{token, new_password}` | Cambia, revoca todas las sesiones (`password_changed`) e invalida los enlaces |
| `POST /v1/account/password` | `{current_password, new_password}` | `CheckPassword`; cambia, revoca las demás sesiones (`password_changed`) e invalida los enlaces |
| `POST /v1/account/email` | `{new_email, password}` | `CheckPassword`; **siempre 202**. Al nuevo, `change_email` (o `register_existing` si ya tiene cuenta) |
| `POST /v1/account/email/confirm` (sin token) | `{token}` | Cambia y da el nuevo por verificado; revoca las demás sesiones (`email_changed`), invalida los enlaces y manda al **viejo** un aviso con un enlace `revert_email` |
| `POST /v1/account/email/revert` (sin token) | `{token}` | Vuelve el correo viejo, revoca todas las sesiones (`email_reverted`), `password_hash = null` y manda al correo viejo un enlace de recuperación |
| `POST /v1/account/deletion` · `DELETE /v1/account/deletion` | `{password}` · — | `CheckPassword`; 202 `{purge_at}` (+14 días; revoca las demás sesiones) · 204, cancela en plazo |
| `POST /v1/account/export` | `{password}` | `CheckPassword`; JSON descargable (§11.2) |

- Enlaces de un solo uso en `account_tokens` (SHA-256 del token): 24 h para verificar o cambiar el correo, 1 h para
  recuperar, **7 días** para `revert_email`. Usado o caducado: 400 `validation` con `fields.token = "used"` o
  `"expired"`, y nada cambia.
- **Invalidar los enlaces** es, en la misma transacción que el cambio: `update account_tokens set used_at = now()
  where account_id = $1 and used_at is null and purpose <> 'revert_email'`. Los `revert_email` solo caducan: quien
  robó la cuenta no puede quitarle al dueño la vuelta atrás cambiando el correo otra vez.
- Una cuenta con `password_hash` nulo no inicia sesión (`invalid_credentials`, con el hash de relleno) hasta
  recuperar la contraseña.
- **Cuentas sin verificar:** en `staging` y `production`, una cuenta sin `email_verified_at` a los 7 días de crearla
  se purga (§11.2) en el trabajo horario.
- **Páginas de los enlaces.** Los correos enlazan a `ELDMARK_PUBLIC_URL/verify?token=…`, `/reset?token=…` y
  `/revert?token=…`. El `GET` sirve un formulario HTML mínimo (`html/template`, sin JavaScript ni CSS) que hace
  `POST` `application/x-www-form-urlencoded` a la misma ruta (`/verify`, `/reset`, `/revert`), con el token en un
  campo oculto. La respuesta es HTML («Correo verificado. Ya puedes cerrar esta página»). El token se valida (43
  caracteres base64url) **antes** de pintarlo; si no vale, la página dice «Enlace no válido» sin repetirlo.
  Cabeceras: `Referrer-Policy: no-referrer`, `Cache-Control: no-store`, `Content-Security-Policy: default-src 'none';
  form-action 'self'`, `X-Frame-Options: DENY`. Por dentro llaman a las mismas funciones que `/v1`.
- Con `ELDMARK_MAIL=log`, el correo va a `outbound_mail` y al registro con el enlace entero: así las pruebas sacan
  el token. En `staging` y `production`, `log` no arranca.

### 4.4 Personajes y nombres (TEC-24, SOC-13)
| Ruta | Cuerpo | Respuesta |
|---|---|---|
| `GET /v1/worlds/{w}/characters` | — | `{realm, unlock_at, slots, used, characters: [{character_id, name, realm, race_id, appearance, level, last_zone_id, played_seconds, created_at, deleted_at, restore_until, must_rename}]}`; de `characters` con `character_progress` |
| `GET /v1/worlds/{w}/name-check?name=…` | — | `{available, code, reason}` |
| `POST /v1/worlds/{w}/characters` | `{name, realm, race_id, appearance, starter_template_id}` | 201 `{character}` |
| `DELETE /v1/characters/{id}` | `{confirm_name}` | `{restore_until}`; `confirm_name` con la misma clave de NameRules que el nombre |
| `POST /v1/characters/{id}/restore` | — | 200 en plazo, con el nombre libre |
| `POST /v1/characters/{id}/rename` | `{name}` | Solo con `must_rename`; el viejo queda reservado 30 días |
| `POST /v1/characters/{id}/enter` | — | §4.5 |

**Datos del juego: un solo archivo.** `platform/internal/gamedata/progression_rules.json`, generado por
`tools/progression/export_rules.gd` (progresion.md P3), versionado y leído con `//go:embed` (que no lee fuera de
`platform/`). Secciones: `protocol_version` (`NetProtocol.PROTOCOL_VERSION`), `names` (`{min_length, max_length,
upper_letters, lower_letters, folded, reserved}` de `NameRules`; la añade P2 de este documento) y las de
progresion.md §13 #6 (razas, límites de apariencia, plantillas de inicio, curva, topes, rangos de motivos). Lo crea
el primero de los dos paquetes que llegue; el otro añade su sección. `tests/test_progression_rules_export.gd` lo
regenera en memoria y falla si difiere. `internal/names` es `NameRules` en Go (`Validate`, `NormalizeKey`,
reservados). Los casos de los dos lados salen de `tests/data/name_rules_cases.json` (`[{name, reason, key}]`), que
leen `test_name_rules.gd` e `internal/names` (con `../tests/data/…`).

**Crear**, en una transacción `serializable` (reintento ante 40001):

1. Cuenta activa sin borrado pendiente; `realm` en `ELDMARK_OPEN_REALMS` (si no, `realm_closed`); menos de 5
   `character_create` en 24 h (si no, 429).
2. `account_realms`: sin fila, o con `unlock_at ≤ now()` y ningún personaje vivo, se fija este reino; si la cuenta
   tiene otro, `realm_locked`.
3. Huecos: 6 + `quantity` de los `character_slots` vigentes. **Ocupan hueco los vivos y los borrados en plazo** (los
   que aún se pueden restaurar).
4. Nombre: `names.Validate` (422), lista negra (422 `reserved`; la edita `admin names block|unblock <nombre>`) e
   `insert into character_names` con `status 'active'`. Una fila `reserved` vigente da `name_taken`; vencida, se
   reutiliza. Dos creaciones a la vez con el mismo nombre: una falla con 23505 en `character_names_pkey`
   (comprobado en una sonda con la misma clave) → `name_taken`.
5. Raza, apariencia y plantilla, con `progression_rules.json`: `race_id` de su reino (`race_vardheim`…), apariencia
   de **8 B** que pasa `progress.ValidateAppearance` (la regla de `CharacterAppearance.validate`, progresion.md §7.2)
   y `starter_template_id` de la lista de plantillas. Mientras falten esas secciones (PRG-14, ART-19, PRG-07):
   `race_id = "race_" + reino`, 8 B cualesquiera y plantilla que cumple `^[a-z0-9_]{1,32}$`.
6. `insert` en `characters` y `character_pvp_stats`, y `ProgressStore.Create` (§7.5) con la raza, la apariencia y
   la plantilla; `auth_events` `character_create`.

**Borrar:** con arrendamiento vivo, `character_busy`; 5 `character_delete` en 24 h, 429. `deleted_at = now()`,
`restore_until = now() + 7 d` y el nombre `reserved` hasta `restore_until + 30 d`. **Excepción:** un personaje con
menos de 24 h de vida y menos de 1 h jugada (`played_seconds < 3600`) reserva el nombre solo hasta `restore_until`.
Al vencer `restore_until`, la purga horaria lo deja como lápida (§11.2); el nombre sigue reservado lo que toque. Si
era el último vivo, `unlock_at = now() + 30 d`.

### 4.5 Entrar al mundo
`POST /v1/characters/{id}/enter`, sin cuerpo. Comprueba en orden: sesión, mantenimiento (503), sanciones (403),
borrado pendiente (403), textos por aceptar (403), correo verificado si se exige (403), personaje vivo de la cuenta
(404), `must_rename` (409), arrendamiento vivo (409). Elige la zona: la de `character_progress.last_zone_id` si
tiene una instancia `live` cuyo `realms` incluye el reino del personaje (en su `last_channel` si está vivo y con
sitio); si no, la de entrada de su reino. Dentro de la zona, el canal con menos jugadores bajo `max_players`; si no
hay ninguno vivo, 503 `zone_unavailable`. Inserta el billete en `enter_tickets` (10 s) y responde:

```json
{"zone": {"zone_id": "vado_gris", "channel": 0, "host": "203.0.113.5", "port": 24600,
          "dtls": {"cert_pem": "-----BEGIN CERTIFICATE-----…", "name": "vado-gris.eldmark"}},
 "ticket": "AQEBAAgHBgUEAwIBKgAAAAAAAAATwO8ZAAEAAQDSSWsK0klrcGHi9UqxoJb2YCRDcSPZ0Q==",
 "expires_in_s": 10, "character": {"character_id": "42", "name": "Aneira", "realm": "vardheim"}}
```

`dtls` es `null` si la zona no usa DTLS (solo en `dev` y `test`, §10.2). El cliente conecta enseguida; si el billete
caduca, pide otro.

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
| 25 | u8 | realm | código de `NetProtocol.Realm`; informativo (manda la reclamación) |
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

Esa clave solo vale en pruebas: fuera de `test`, la configuración la rechaza en la plataforma y en la zona (§2.3).
GDScript: `HMACContext` con `HASH_SHA256`, `"vado_gris".sha256_buffer().decode_u32(0)` y
`Crypto.constant_time_compare`. Go: `crypto/hmac` y `hmac.Equal`.

### 5.2 Comprobaciones en la zona
`TicketAuthProvider.authenticate(peer_id, hello)`, síncrono y sin red; cualquier fallo es REJECT `TICKET` y nada
llega a la plataforma:

1. Tamaño 52 y `version` 1; `key_id` conocido; `mac` correcto en tiempo constante.
2. `world_id`, `zone_key` y `channel` de esta zona («billete de otra zona»).
3. `issued_at ≤ ahora + 5` y `ahora ≤ expires_at + 5`, con «ahora» corregido por el reloj de la plataforma (§6).
4. `character_id` igual al del HELLO.
5. `ticket_id` no visto en los últimos 30 s («reutilizado»).

Antes del paso 1, una zona **cercada** (§5.3) responde REJECT `UNAVAILABLE`. Si pasa, devuelve `PENDING`: el peer
pasa al estado nuevo `ServerPeer.State.VERIFYING` y la zona pide la reclamación (`POST /internal/v1/claims`), que
garantiza de verdad el **un solo uso** y toma el arrendamiento.

- **Cupo.** `ZoneServer.get_player_count()` cuenta `VERIFYING`, `LOADING` e `IN_WORLD` (y los falsos): varias
  entradas a la vez no pasan de `max_players`. Al llegar el 200, si la cuenta (con él) pasa de `max_players`, REJECT
  `FULL` y `release`.
- **Plazo en tiempo real.** `VERIFY_TIMEOUT_MS = 7000` desde que el peer conectó (`peer_authenticating`;
  `ServerPeer.connected_at_msec` con `Time.get_ticks_msec()`, solo en `scripts/server/`), mirado en cada tick. Un
  plazo en ticks se descuadraba con el servidor atrasado.
- **`auth_timeout` de 10 s.** `SceneMultiplayer` corta a los `auth_timeout` segundos **desde la conexión, en los dos
  lados**, no desde el HELLO. Comprobado con `GuardedEnetPeer` en el servidor: con 5 s, HELLO a 1,4 s y respuesta a
  4,0 s, entra; con 10 s, HELLO a 1,5 s y respuesta a 8,5 s, entra; respuesta a 10,5 s, el cliente cae a los 10 s.
  `NetTransport.AUTH_TIMEOUT_SECONDS` pasa de 5 a 10 en la subida de protocolo de la fase 5 (§5.4), así que el
  REJECT a los 7 s siempre llega. Los 90 ticks del HELLO (red.md §3) siguen valiendo en `AUTHENTICATING`.

El resultado se aplica en el paso «poll» del tick (§14.3):

| Reclamación | La zona |
|---|---|
| 200 | Si la zona admite el reino del personaje y cabe, WELCOME con ese reino, `complete_auth` y `LOADING`; si no, `REALM` o `FULL` y `release` |
| 409 `ticket_invalid` (consumido, caducado, de otra instancia o de una sesión revocada) | REJECT `TICKET` |
| 409 `character_busy` | REJECT `BUSY` |
| 403 `account_blocked` (suspendida, expulsada, borrado pendiente) | REJECT `BANNED` con el texto de la plataforma |
| 409 `instance_*` | REJECT `UNAVAILABLE` y el cierre de §6.1 |
| 5xx, sin conexión o 7 s desde la conexión sin respuesta | REJECT `UNAVAILABLE`; si la reclamación llega después, se libera |

### 5.3 Arrendamiento
La reclamación, en una transacción: comprueba la cuenta (sanción o borrado → 403 `account_blocked`), consume el
billete y toma el arrendamiento. Comprobado en PostgreSQL 16:

```sql
-- 1. El billete: de esta instancia, sin usar, sin caducar y de una sesión sin revocar
update enter_tickets t set consumed_at = now() from sessions s
where t.ticket_id = $1 and t.character_id = $2 and t.zone_instance_id = $3 and t.consumed_at is null
  and t.expires_at > now() - interval '5 s' and s.session_id = t.session_id and s.revoked_at is null
returning t.session_id;                     -- sin fila: ticket_invalid y rollback
-- 2. El arrendamiento ($5 = session_id, $6 = lease_id nuevo de crypto/rand, $7 = TTL)
insert into character_leases (character_id, world_id, lease_id, zone_instance_id, claimed_by, session_id, expires_at)
values ($2, $4, $6, $3, $3, $5, now() + $7)
on conflict (character_id) do update set lease_id = excluded.lease_id, zone_instance_id = excluded.zone_instance_id,
  claimed_by = excluded.claimed_by, session_id = excluded.session_id, expires_at = excluded.expires_at,
  last_seq = 0, last_save_hash = null, claimed_at = now(), released_at = null
where character_leases.zone_instance_id is null or character_leases.expires_at < now()
returning lease_id;                         -- sin fila: character_busy y rollback (el billete no queda consumido)
```

- **Latido** cada 5 s, con su propia plaza (§6): `characters: [{character_id, lease_id}]` de los personajes en
  `VERIFYING`, `LOADING`, en el mundo, con el cuerpo tras una salida en combate o con el guardado final pendiente.
  Renueva solo lo que casa:

  ```sql
  update character_leases l set expires_at = now() + $4
  from unnest($2::bigint[], $3::uuid[]) as h(character_id, lease_id)
  where l.character_id = h.character_id and l.lease_id = h.lease_id and l.zone_instance_id = $1
  returning l.character_id;                 -- los que faltan vuelven en revoked con reason lease_lost
  ```

  Los que no van en la lista caducan solos (TTL 30 s).
- **Cercado.** Sin un latido aceptado en 2 × `HEARTBEAT_S` (10 s), la zona está cercada hasta el siguiente: no
  admite HELLO (REJECT `UNAVAILABLE`) ni operaciones que piden guardado crítico (comandos de GM que dan o quitan, y
  en la fase 6 comercio y correo: «El servicio de cuentas no responde; inténtalo más tarde»). No expulsa a nadie:
  el juego sigue y §7.4 vale.
- **Instancia perdida:** 15 s (3 × `HEARTBEAT_S`) sin latido → `lost` y sus arrendamientos libres
  (`zone_instance_id = null`; `lease_id` y `claimed_by` se quedan). Tras un `kill -9`, el personaje vuelve a entrar
  en 15 s como mucho. Si la instancia vuelve, §6.1.
- **Instancia nueva de la misma zona y canal.** Si la vieja latió hace menos de 3 × `HEARTBEAT_S`, el registro da 409
  `instance_alive` salvo con `"replace": true` (`--replace`), que deja una fila en `audit_log`. La zona sin
  `--replace` reintenta cada 2 s durante 60 s y luego sale con código 1. Al sustituir, la vieja pasa a `replaced` y
  sus arrendamientos se liberan; si seguía viva, hace el cierre de §6.1, y **sus guardados finales sí valen** si
  nadie ha reclamado a esos personajes (§7.3).
- **Salida en combate** (GUE-41): el arrendamiento dura hasta que el cuerpo se va y el guardado final llega. Entrar
  en esos 15 s da `character_busy` y el cliente reintenta solo cada 3 s durante 30 s: reconectar no acorta la salida
  en combate.
- **`lease_id` solo cambia al reclamar.** Liberar no lo cambia: un guardado tardío de la misma instancia se acepta
  si nadie ha reclamado al personaje desde entonces (§7.3).

### 5.4 Cambios en el protocolo
| Pieza | Cambio |
|---|---|
| `PROTOCOL_VERSION` | **Una sola subida para toda la fase 5**, compartida con progresion.md (el P4 de los dos documentos): la siguiente libre al integrar. Hoy el código de `fase4-fuerte` está en 4, el chat usa la 5 en su rama y habilidades.md fija la 6: **7** si esos dos llegan antes. Una línea en `net_protocol.gd`: «N: la fase 5 (docs/plataforma.md y docs/progresion.md): REJECT 10 a 12, billete de 52 B, auth_timeout de 10 s, bit GM del ENTITY_SPAWN y lo de progresion.md §12» |
| `NetTransport` | `AUTH_TIMEOUT_SECONDS` = 10.0 (antes 5.0), en los dos lados (§5.2) |
| HELLO | **Sin cambios de bytes.** Con billete van `character_id` y `ticket`; el cliente pone en `realm` y `name` los de su personaje y la zona los ignora |
| WELCOME | Sin cambios de bytes; `realm` es el del personaje |
| REJECT | `Result` añade `BUSY = 10`, `UNAVAILABLE = 11` y `BANNED = 12` (libres en todas las ramas; si otra ocupa alguno, los siguientes). `result_text`: «Tu personaje sigue en el mundo: espera unos segundos», «El servicio de cuentas no responde: inténtalo más tarde», «Tu cuenta está suspendida». El texto lo compone la zona (con la fecha de fin en `BANNED`) |
| ENTITY_SPAWN | Bit 3 del `flags` de la **cabecera** (offset 9; hoy bit0 «tuyo» y bits 1–2 teletransporte) = personal del juego (moderador o más), para la etiqueta (SOC-14). No es el `flags` del registro del snapshot, cuyo bit 3 usa habilidades.md |
| NOTICE | Sin códigos nuevos: «Has iniciado sesión desde otro lugar» o «Tu cuenta ha sido suspendida» van con el 1 (expulsión) |

Con `--platform`, `--max-realm-diff` (REJECT `IMBALANCE`) no se aplica: el reino ya no se elige al conectar (el
equilibrio de población es de GUE-36). El enfriamiento tras una expulsión usa la clave `character:<id>` en lugar del
nombre del HELLO.

### 5.5 Modos de arranque
| Modo | Fase 5 |
|---|---|
| F5 en el editor sin argumentos | Sandbox de la fase 1, igual (`OS.has_feature("editor")`) |
| Sin argumentos en una exportación · `--title [--platform=<url>]` | Pantalla de título (UI-22) contra `eldmark/platform/url` · lo mismo desde el editor |
| `--server` sin `--platform` | `DevAuthProvider` como hoy: reino y nombre del HELLO; guardado solo con `--progress-file` (progresion.md §9.4) |
| `--server --platform=<url interna>` | `TicketAuthProvider`; un HELLO sin billete recibe `TICKET` («Entra desde el menú con tu cuenta»). `--debug-commands`, `--fake-players`, `--fake-churn`, `--battle-log`, `--combat-log` y `--state-log` solo si el `env` del registro es `dev` o `test`; si no, la zona sale con código 1 y «Esa opción no se admite con la plataforma en staging/production» |
| `--fake-players`, `--fake-churn` | Nunca tocan la plataforma ni se guardan; se llaman `Bot-NN`, que no es un nombre válido y no choca con ningún personaje |
| `--connect`, `--local`, `--bot --connect` · con `--dtls-cert=<pem> --dtls-name=<cn>` | Igual, contra zonas sin plataforma; `RealmSelect` queda para desarrollo · con DTLS (§10.2) |
| `--bot --platform=<url> --login=<correo> --password-file=<ruta> [--character=<nombre>] [--realm=…]` | `AccountFlow` (§13.3): inicia sesión, crea el personaje si falta (`--character` o `NameRules.bot_name(semilla)`), pide `enter` y conecta. Sin `--login` o `--password-file`, sale con código 1 y un error claro |
| `--bots=N [--dtls-cert=<pem> --dtls-name=<cn>]` | Solo contra zonas sin plataforma (carga, y la medida de TEC-27 con DTLS); con `--platform`, sale con un error claro |

## 6. API interna (zona ↔ plataforma)

HTTP y JSON en `ELDMARK_INTERNAL_ADDR` (127.0.0.1 en desarrollo; red privada de Docker en el VPS), con
`Authorization: Bearer <token de zona>`.

- **Un token por despliegue de zona.** La plataforma calcula el SHA-256 del token y lo compara con
  `subtle.ConstantTimeCompare` con cada entrada de `ELDMARK_ZONE_TOKENS`; la que casa da su alcance (mundo, zona,
  canal). Sin entrada: 401 `bad_token`. El registro solo admite ese alcance y un `public_host` de
  `ELDMARK_ZONE_HOSTS` (si no, 403 `forbidden`). Toda otra petición lleva `zone_instance_id` (en el cuerpo, la
  ruta o la consulta), que tiene que ser una instancia de ese alcance (si no, 403 `forbidden`).
- **En `staging` y `production`** el registro sin `dtls_cert_pem` da 400 `validation`.
- Registro y latido traen `now_unix`: la zona guarda `offset = now_unix − su reloj` (`ZonePlatform.now_unix()`) y
  avisa si pasa de 2 s.

**`PlatformClient`** (en la zona, dentro de `ZonePlatform`) usa `HTTPRequest` (sin hilos), plazo de 3 s
(`timeout_s`, menor en las pruebas) y colas por prioridad. Los resultados se guardan al llegar y se aplican en el
paso «poll», nunca a mitad de tick:

| Prioridad | Peticiones | Reintento |
|---|---|---|
| 0 control | Registro, `live`, GET de fortalezas al arrancar, latido, baja | Registro, `live` y GET: 1, 2, 4… s hasta 60 s, luego la zona sale (§8). Latido: no (el siguiente sale a su hora; nunca dos en cola) |
| 1 entrada | Reclamación, liberación | Reclamación: **no** (la corta el plazo de §5.2). Liberación: como los guardados |
| 2 jugador | Guardados, bloques de ids, operación y libro, reportes, ignorados, sanciones | Guardados y bloques: el mismo cuerpo a 1, 2, 4, 8 y 15 s, luego cada 15 s mientras la zona viva. Los demás: no (el jugador o el GM ve «El servicio de cuentas no responde») |
| 3 fortaleza | PUT de fortaleza (una en vuelo por fortaleza) | A los 2 s, siempre con el registro más reciente |
| 4 lotes | Chat, auditoría, guerra | El mismo lote a 2, 4, 8 y 16 s, luego cada 30 s. Pasadas 20 000 entradas en cola se descarta el chat más viejo (con aviso); auditoría y guerra nunca, y van también al registro de la zona |

**Plazas:** una propia para la prioridad 0 y seis compartidas. Las prioridades 2 a 4 ocupan cuatro como mucho a la
vez, así que siempre quedan dos para la 1. Cuando se libera una plaza sale la petición de prioridad más alta; dentro
de cada prioridad, por orden de llegada. Un plazo vencido no es una respuesta: un guardado sigue siendo el mismo
cuerpo hasta tener una definitiva (§7.3).

| Ruta | Cuerpo | Respuesta |
|---|---|---|
| `POST /internal/v1/zone-instances` | `{world_id, zone_id, channel, public_host, public_port, realms: [1, 2], build_id, protocol_version, record_format, max_players, dtls_cert_pem, dtls_name, replace}` | `{zone_instance_id, env, heartbeat_s, lease_ttl_s, now_unix}`; la instancia queda en `starting` |
| `POST /internal/v1/zone-instances/{id}/live` | — | 204; pasa a `live` y `enter` ya la ofrece |
| `POST /internal/v1/zone-instances/{id}/heartbeat` | `{players, characters: [{character_id, lease_id}]}` | `{now_unix, revoked: [{character_id, reason, text}], mutes: [{account_id, until_unix}], maintenance: {at_unix, message} \| null}` |
| `DELETE /internal/v1/zone-instances/{id}` | — | 204; `stopped` y libera lo que quede |
| `POST /internal/v1/claims` | `{zone_instance_id, ticket_id, character_id}` | `{lease_id, instance_status, account: {account_id, role, muted_until_unix, ignored_account_ids}, record, pvp}`: `record` es el `CharacterRecord` de progresion.md §3.4 (`record_format` 1) y `pvp` los totales de §8 |
| `PUT /internal/v1/characters/{id}/state` | §7.3 | `{applied, duplicate, save_version, instance_status}` |
| `POST /internal/v1/saves` | `{zone_instance_id, saves: [§7.3]}` | Todos o ninguno (comercio y correo, fase 6): todos nuevos o todos repetidos; mezcla → 409 `seq_conflict` |
| `POST /internal/v1/characters/{id}/release` | `{zone_instance_id, lease_id}` | 204, sin guardar (el cliente no llegó a aparecer, o tras un `invalid_save`) |
| `POST /internal/v1/id-blocks` | `{zone_instance_id}` | `{"first": "1025", "count": 1024}`: `nextval('uid_block_seq')` y una fila en `id_blocks` |
| `GET /internal/v1/ops/{op_id}?zone_instance_id=` | — | `{op, ledger, items}` (progresion.md §13 #5, para `op_show` y la reversión) |
| `GET /internal/v1/characters/{id}/ledger?zone_instance_id=&limit=&before_entry_id=` | — | `{entries: [...]}`; `limit` ≤ 200 (para `ledger_show`) |
| `GET /internal/v1/fortresses?zone_instance_id=` · `PUT /internal/v1/fortresses/{id}` | — · `{zone_instance_id, expected_version, record}` | `{fortresses: [{fortress_id, record, version}]}` (lista vacía: sin registros) · `{version}`, o 409 `version_conflict` con `{version}` |
| `POST /internal/v1/war-events` · `…/chat` · `…/audit` | `{zone_instance_id, events\|messages\|entries: [{key, …}]}` (§8, §9) | 204 |
| `POST /internal/v1/reports` | `{zone_instance_id, world_id, …}` (§9.4) | `{report_id}` o 429 |
| `POST` · `DELETE /internal/v1/ignores` | `{zone_instance_id, world_id, character_id, target_name}` | `{ignored_account_id, name}` · 204 |
| `POST /internal/v1/sanctions` | `{zone_instance_id, world_id, author_character_id, target_name, kind, minutes, reason, report_ids}` | `{sanction_id, ends_at_unix}` o 403 `forbidden` (§9.5) |

- **Lotes** (chat, auditoría, guerra): cada 2 s o 200 entradas, 1 MB como mucho. Cada entrada lleva `key =
  "<zone_instance_id>:<secuencia>"` y se inserta con `on conflict do nothing`: reenviar un lote no duplica nada.
- **`revoked`** del latido:

| `reason` | Cuándo | La zona |
|---|---|---|
| `lease_lost` | El `(character_id, lease_id)` del latido no casa con un arrendamiento de esta instancia | Expulsa sin guardar y descarta el estado en memoria |
| `session_revoked` | La sesión del arrendamiento está revocada (`replaced`, `password_changed`, `email_changed`, `email_reverted`, `refresh_reuse`, `role_changed`, `logout`, `deletion`, `admin`) | Guardado final y expulsión con NOTICE («Has iniciado sesión desde otro lugar», «Tu cuenta ha cambiado: vuelve a entrar») |
| `suspended`, `banned`, `pending_deletion` | Sanción vigente o borrado pedido | Guardado final y expulsión con el motivo y la fecha |

### 6.1 Estados de la instancia y orden de las comprobaciones
Cada petición interna se comprueba **en este orden**, y el primer fallo da la respuesta: (1) token → 401
`bad_token`; (2) alcance de la instancia → 403 `forbidden`; (3) estado de la instancia (tabla); (4) arrendamiento
(`lease_id` y `claimed_by`) → 409 `lease_lost`; (5) `seq` → `duplicate`, 409 `stale_seq` o 409 `seq_conflict`; (6)
contenido (S3–S9) → 400 `invalid_save`.

| Petición | `starting` | `live` | `lost` | `replaced` | `stopped` |
|---|---|---|---|---|---|
| `live` | → `live` | 204 (repetida) | 409 `instance_lost` | 409 `instance_replaced` | 409 `instance_stopped` |
| Latido | 200 | 200 | 409 `instance_lost` | 409 `instance_replaced` | 409 `instance_stopped` |
| Reclamación | 409 `instance_not_live` | 200 o sus errores | 409 `instance_lost` | 409 `instance_replaced` | 409 `instance_stopped` |
| Guardado y liberación | §7.3 (no tiene arrendamientos: `lease_lost`) | §7.3 | §7.3: valen si `lease_id` y `claimed_by` casan (guardados finales) | ídem | ídem |
| Bloques de ids, operación y libro | 409 `instance_not_live` | 200 | 409 `instance_lost` | 409 `instance_replaced` | 409 `instance_stopped` |
| GET de fortalezas | 200 | 200 | 409 `instance_lost` | 409 `instance_replaced` | 409 `instance_stopped` |
| PUT de fortaleza | 409 `instance_not_live` | 200 o 409 `version_conflict` | 409 `instance_lost` | 409 `instance_replaced` | 409 `instance_stopped` |
| Lotes | 204 | 204 | 204 | 204 | 204 |
| Reportes, ignorados y sanciones | 409 `instance_not_live` | 200, o 403 `forbidden` | 409 `instance_lost` | 409 `instance_replaced` | 409 `instance_stopped` |

La respuesta de un guardado lleva `instance_status`: así la zona se entera aunque su latido vaya por detrás.
**Cierre por `instance_lost`, `instance_replaced` o `instance_stopped`** (en cualquier petición o en
`instance_status`): NOTICE de expulsión «El servidor de la zona se ha reiniciado: vuelve a entrar» a todos, guardado
final de todos (§7.2), `begin_flush` con 10 s como mucho y salida con código 3. El orquestador (compose, `restart:
unless-stopped`) arranca una instancia nueva; en desarrollo el proceso sale con ese mensaje. `instance_not_live` es
un error de orden de la zona: se registra.

**Errores internos:** 401 `bad_token`; 403 `forbidden`, `account_blocked`; 409 `instance_not_live`,
`instance_alive`, `instance_lost`, `instance_replaced`, `instance_stopped`, `lease_lost`, `stale_seq`,
`seq_conflict`, `ticket_invalid`, `character_busy`, `version_conflict`, `schema_mismatch` (solo en el registro: el
`record_format` o el `protocol_version` no los admite esta plataforma; la zona sale con código 1); 400
`bad_request`, `validation`, `invalid_save` (con `detail`: la comprobación y el campo). Cuerpo como en §4.1.

## 7. Persistencia del personaje (TEC-25)
### 7.1 Qué se guarda
La tabla «quién guarda qué» está en §3. En el guardado viajan:

| Parte | Qué | Quién la construye |
|---|---|---|
| `record` | El `CharacterRecord` de progresion.md §3.4 sin `character_id`, `realm`, `name`, `race_id` ni `appearance`: progreso, vida, arma activa, habilidades, temporizadores (CMB-30), `location` (zona, canal, posición, giro, en combate, `saved_at`), inventario y saldos | `ProgressService` (progresion.md) |
| `ops` | Las operaciones del diario aún no enviadas, con sus apuntes y eventos de objeto (progresion.md §9.3) | `ProgressService` |
| `pvp` | Totales de GUE-19 `{kills, deaths, assists, captures, gate_damage, defend_s}` | `ScoreKeeper` (§8) |
| **Nunca** | `PlayerState`, `CombatState` y lo que se predice por tick, la cola de entradas, el combate en curso, los avisos | — |

**Volver al mundo** (provisional, tomada de noche): la regla es la de progresion.md §8 y solo está allí. Posición:
el sitio guardado si es la misma zona y canal, `saved_at` tiene menos de 15 min, no estaba en combate ni muerto, pisa
suelo y no está en la zona segura de otro reino; si no, el punto de aparición del reino. Vida: la guardada más la
regeneración del tiempo pasado; muerto, llena en el campamento.

`record_format` y `save_format` son los de progresion.md (1). La zona declara el suyo al registrarse; si la
plataforma no lo admite, 409 `schema_mismatch` y la zona no arranca. Las filas son columnas: un formato nuevo es
código nuevo en P3b y, si hace falta, una migración (§2.4), no una conversión al leer.

### 7.2 Cuándo se guarda
| Momento | Cómo |
|---|---|
| Punto de control | Cada 60 s (`--save-interval=<s>`) si alguna sección está sucia (moverse y la vida cuentan). Cada personaje en su fase (`tick % interval == character_id % interval`): 64 jugadores dan ~1 guardado por segundo |
| Evento crítico | Los de progresion.md §9.2 (kit de inicio, subida de nivel, comandos de GM que dan o quitan, reversiones; desde la fase 6, comercio, correo y botín raro) y el renombrado: `CharacterSaver.mark_critical(net_id)`; sale en cuanto no haya otro en vuelo |
| Salida | Al irse el cuerpo (CLIENT_LEAVE, desconexión o fin de los 15 s en combate): `finish(net_id, LOGOUT)` con `release_lease`, **antes** de `ScoreKeeper.forget` y de soltar el estado de progresion.md |
| Cierre ordenado | Los cinco disparadores: `--stop-file`, `--quit-after-ticks`, `--idle-quit`, `shutdown` de la consola y el mantenimiento de la plataforma. Todos pasan por `ServerMain._shutdown` → `ZoneServer.stop`: `finish` de todos, `begin_flush` y espera hasta que `pending_count()` sea 0 y `is_flushed()`, con un tope de 600 ticks (10 s) |
| Expulsión de la plataforma | `revoked` del latido (§6) |
| Cierre de la instancia | §6.1 |

- **Una escritura en vuelo por personaje.** Mientras vuela, los cambios solo marcan la sección; al llegar la
  respuesta definitiva se construye el siguiente. La foto se toma **dentro del tick**, tras «altas».
- **El final se construye en el momento** (`finish`): el jugador ya no cambia, así que espera detrás del que vuela
  sin rehacerse. Como mucho uno en vuelo y un final esperando.
- **Un cuerpo enviado no cambia.** `CharacterSaver` guarda los bytes (`JSON.stringify` una vez) y los reintentos
  van byte a byte. `JSON.stringify` y el envío no bloquean el tick.
- **Cercado** (§5.3): los guardados siguen saliendo; las operaciones que piden guardado crítico se rechazan.

### 7.3 Versiones e idempotencia
```json
{"save_format": 1, "character_id": "41", "zone_instance_id": "…", "lease_id": "…", "seq": 17, "reason": 1,
 "release_lease": false,
 "record": {"…": "CharacterRecord de progresion.md §3.4 sin character_id, realm, name, race_id ni appearance"},
 "ops": [{"op_id": "5120", "kind": 6, "…": "progresion.md §9.3"}],
 "pvp": {"kills": 3, "deaths": 1, "assists": 0, "captures": 1, "gate_damage": 450, "defend_s": 120}}
```

`seq` empieza en 1 con cada arrendamiento y sube 1 en cada guardado; `reason`: 1 punto de control, 2 crítico, 3
salida, 4 cierre del servidor, 5 expulsión. La clave de idempotencia es **`(lease_id, seq)`**. La plataforma, en una
transacción:

1. `select … from character_leases where character_id = $1 for update` (y la fila de `character_progress`).
2. Otro `lease_id`, o `claimed_by` distinto de `zone_instance_id` → 409 `lease_lost`.
3. `seq = last_seq`: si el SHA-256 del cuerpo es `last_save_hash`, 200 `{applied: false, duplicate: true,
   save_version}`; si no, 409 `seq_conflict`. `seq < last_seq` → 409 `stale_seq`.
4. `ProgressStore.Apply` (S3–S9 de progresion.md §13 y los bloques de ids de §7.5) y `character_pvp_stats` (los
   totales no bajan); `last_seq = seq`, `last_save_hash`, `save_version += 1`; con `release_lease`,
   `zone_instance_id = null` y `released_at`. Si algo falla, **no se escribe nada** y 400 `invalid_save`.

| Respuesta | La zona |
|---|---|
| 200 `applied` o `duplicate` | Aplicado (un `duplicate` es un guardado que llegó y cuya respuesta se perdió): las secciones lo confirman y las `ops` enviadas salen del diario; si hay otro marcado o un final esperando, sale |
| 409 `lease_lost` | Definitivo: expulsa con NOTICE «Tu personaje ha entrado en otro servidor» si sigue, descarta el estado en memoria y el final que esperase; no libera |
| 409 `stale_seq` o `seq_conflict` · 400 `invalid_save` | Definitivo y error nuestro: registro de error, NOTICE «No se ha podido guardar tu personaje; vuelve a entrar», descarta el estado y llama a `release` sin guardar, para que el personaje no quede bloqueado |
| 409 `instance_*` | El cierre de §6.1 |
| 5xx, 401, sin conexión, plazo vencido | Reintento del **mismo** cuerpo (§6). No sale `seq + 1` hasta tener una de las respuestas de arriba |

Ejemplo: un guardado vence su plazo de 3 s pero la plataforma lo aplica tarde. El reintento lleva el mismo `seq` y
los mismos bytes: `duplicate`, que la zona trata como aplicado. El siguiente lleva `seq + 1` y solo las `ops`
nuevas, así que S3 («ningún `op_id` existe ya») pasa.

El arrendamiento hace a la zona la única escritora. Fuera de la zona nadie escribe el progreso en la fase 5 (la
edición sin conexión es de SOC-37, fase 8); quien lo haga en el futuro cambiará antes `lease_id`. **Regla de los
objetos:** toda operación que mueve objetos o monedas entre dos personajes se guarda en un solo `POST
/internal/v1/saves` con los dos; así un `uid` nunca está en dos filas (la clave primaria de `item_instances` lo
impide) y nada se duplica.

### 7.4 Si algo se cae
| Cae | Qué pasa | Se pierde |
|---|---|---|
| La zona (`kill -9`) | Arrendamientos libres a los 15 s (o al registrarse la instancia nueva) | Lo posterior al último guardado: **60 s como mucho**; lo crítico ya estaba |
| La plataforma | Nadie nuevo entra (`enter` falla; la zona se cerca a los 10 s; una reclamación en curso da `UNAVAILABLE`); quien juega sigue. La zona reintenta el guardado en vuelo y marca los demás; al volver, la gracia de §2.5 y todo se envía | Nada, si la zona no cae también |
| Las dos | Lo que no llegó | Desde el último guardado aceptado |
| La red entre ellas | Para la zona, como «la plataforma». Si el cliente sí llega a la plataforma, a los 15 s su personaje puede entrar en otra zona; al volver la red, la vieja recibe `instance_lost` y se cierra: los guardados finales de quien nadie ha reclamado valen, los demás dan `lease_lost` | Lo jugado en la zona aislada por quien entró en otra (§16) |

Deseable (no bloquea TEC-25): un cierre ordenado sin plataforma escribe lo pendiente en `user://pending_saves.jsonl`
y lo reenvía al arrancar; vale porque `lease_id` no cambia al liberar y `seq` lo ordena.

### 7.5 Frontera con `docs/progresion.md`
**En Go** (P3 define la interfaz y la usa con un falso; P3b la implementa en `internal/progress`):

```go
// internal/persistence/progress.go. Todo va dentro de la transacción de quien llama.
type CreateParams struct { RaceID string; Appearance [8]byte; StarterTemplateID string }
type SaveKey struct { CharacterID int64; InstanceID [16]byte }   // instancia que reclamó: dueña de los bloques de ids
type ProgressStore interface {
	Create(ctx context.Context, tx pgx.Tx, worldID int16, characterID int64, p CreateParams) error  // personaje nuevo
	Load(ctx context.Context, tx pgx.Tx, characterID int64) (progress.Record, error)              // «record» de la reclamación
	// S3–S9 y bloques; *progress.InvalidError → 400 invalid_save. Devuelve el save_version nuevo.
	Apply(ctx context.Context, tx pgx.Tx, key SaveKey, body progress.SaveBody) (int64, error)
	Purge(ctx context.Context, tx pgx.Tx, characterID int64) error                                // progress_purge_character
	Op(ctx context.Context, tx pgx.Tx, opID int64) (progress.OpView, error)
	Ledger(ctx context.Context, tx pgx.Tx, characterID int64, limit int, beforeEntryID int64) ([]progress.LedgerEntry, error)
}
```

`progress.Record`, `progress.SaveBody{Record, Ops}` y `progress.Op` son los tipos de progresion.md §3.4 y §9.3,
con `jsonx.Int` y `jsonx.ID`; no hay JSON opaco. S1 (arrendamiento) y S2 (`seq`) los hace `persistence.Store.Save`
antes de llamar a `Apply`. **Bloques de ids:** cada `op_id` y cada `uid` nuevo cae en un bloque de `id_blocks` dado a
`claimed_by`; si no, 400 `invalid_save` (una zona no puede inventar ids de otra).

**En la zona** (GDScript):

| Pieza | Documento | Hace |
|---|---|---|
| `ZonePlatform`, `PlatformClient` | Este (P4) | HTTP, colas, latido, reclamaciones, eventos |
| `ClaimedCharacter` | Este (P4) | Lo que trae la reclamación; `record` va tal cual a progresion.md |
| `CharacterSaver` | Este (P5) | Cuándo, `seq`, una en vuelo, final, respuestas de §7.3 |
| `PlatformProgressRepository extends ProgressRepository` | Este (P5) | `load_character` devuelve en el `poll` siguiente el `record` de la reclamación (sin HTTP); `save_character` → `ZonePlatform.save`; `request_id_block` → `POST /internal/v1/id-blocks` |
| `ProgressRepository`, `MemoryProgressRepository`, `FileProgressRepository` | progresion.md | La interfaz y los repositorios sin plataforma (pruebas y `--progress-file`), con la misma regla de `seq` |
| `ProgressService`, `PlayerProgress`, `CharacterRecord` | progresion.md | La carga y el alta (§9.1), las operaciones y la sección `progress` del guardado |

`CharacterSaver` habla siempre con un `ProgressRepository`: con plataforma, `PlatformProgressRepository`; sin
ella, los de progresion.md. Así hay **un solo** cauce de guardado. Las secciones: `&"progress"` (de
`ProgressService`: `record` y `ops`) y `&"pvp"` (de `ScoreKeeper`). Los cambios que esto pide en progresion.md están
en §17.

## 8. Guerra persistente (GUE-19)

Registro de una fortaleza (`fortresses.record`, esquema 1), escrito por `FortressPersistence` en
`scripts/server/war/` (nunca en `scripts/shared`, que no lee el reloj):

```json
{"schema": 1, "owner": 1, "phase": "consolidating", "phase_ends_at_unix": 1800000120,
 "captain_alive": false, "captain_respawn_at_unix": 1800000300, "gate_health": 2600,
 "capture_realm": 0, "capture_progress": 0, "last_reset_at_unix": 1799999000}
```

- **Arranque con plataforma**, en este orden (`ServerMain` y `ZonePlatform`):
  1. Registro (`starting`). 409 `instance_alive`: reintenta cada 2 s durante 60 s (§5.3). 403, 409
     `schema_mismatch` o 60 s sin respuesta: sale con código 1.
  2. Comprueba el `env` frente a las opciones de desarrollo (§5.5).
  3. `GET /internal/v1/fortresses` con reintentos (1, 2, 4, 8… s; a los 60 s sin respuesta, sale con código 1).
     **Sin respuesta no es «sin registro»:** solo una lista vacía lo es (primer arranque: el estado inicial de cada
     definición, sin aviso). Un registro con otro `schema`: el estado inicial con un aviso.
  4. `ZoneServer.start(…, platform)` aplica las fortalezas cargadas y **después** abre el puerto
     (`NetTransport.host`).
  5. `POST …/live`: desde aquí `enter` manda jugadores. Los latidos empiezan tras el paso 1.
- Cada `*_at_unix` vuelve a ticks con `tick + max(0, at − now_unix) · 60`. `CAPTURING` vuelve como `VULNERABLE` con
  su progreso (el círculo está vacío y decae); los guardias no se guardan (los repone el generador). Sin plataforma,
  como hoy.
- **Guardar:** en cada cambio de dueño o de fase y, si cambió algo (la vida de la puerta), cada 60 s. Un tick futuro
  `t` se escribe como `now_unix + ceil((t − tick) / 60)`. Una petición en vuelo por fortaleza, siempre con el
  registro más reciente y con `expected_version` (la última que devolvió la plataforma). 409 `version_conflict`: la
  zona toma la `version` del error y reenvía su registro (la instancia viva manda). Solo escribe la instancia
  `live` de esa zona.
- El reinicio a neutral cada 30 min cuenta desde `last_reset_at_unix` (reiniciar el proceso no reinicia el ciclo).
- **Historial:** los `WarEvents` 3 (captura iniciada), 6 (capturado) y 7 (reiniciado) van al lote de `war-events`
  (`{key, fortress_id, event, realm, at_unix}`) → `fortress_events`.
- **Por personaje.** `ScoreKeeper.Entry` (hoy `kills`, `deaths`, `assists`, `gate_damage` y `circle_ticks`) añade
  dos contadores (P6):

| Contador | Lo suma | Cuándo |
|---|---|---|
| `captures` | `FortressController`, al aplicar el cambio de dueño | A cada jugador del reino captor presente, vivo y conectado en el círculo en el tick de la captura |
| `defend_ticks` | `FortressController._recount` | A cada jugador del reino **dueño** presente con el círculo activo (`circle_ticks` sigue contando a todos, para los méritos) |

  La sección `pvp` de `CharacterSaver` manda los totales cargados (`ClaimedCharacter.pvp`) más los de la sesión
  (`defend_s` = cargado + `defend_ticks / 60`). Como `finish` construye la foto en el momento (§7.2), va antes de
  `ScoreKeeper.forget`.

## 9. Social y moderación (SOC-13 a SOC-18)
### 9.1 Roles y auditoría (SOC-14)
| Rol | Comandos | Sanciones que puede crear |
|---|---|---|
| `player` | Nada de moderación | — |
| `moderator` | `/gm silenciar`, `/gm aviso`, `/gm expulsar`; los de lectura de progresion.md §10 (`inv_show`, `ledger_show`, `op_show`); etiqueta visible | `warning`; `mute` hasta 7 días |
| `gm` | Lo anterior, `/gm suspender`, `/gm renombrar`, `/gm teleport`, `/gm invisible` y `/gm visible`, PRG-16 que cambia algo y los comandos del fuerte | Lo anterior; `suspension` hasta 7 días; `rename` |
| `admin` | Todo, también `/gm banear`, `/gm anuncio` y `/gm apagar` | Lo anterior; `suspension` de más de 7 días; `ban` |

- **El rol** lo pone `admin set-role <correo> <rol>` (auditado) y llega en la reclamación. `set-role` **revoca las
  sesiones de la cuenta** (`role_changed`): el latido expulsa al personaje en 5 s como mucho y vuelve a entrar con
  el rol nuevo. Bajar de rol a un GM conectado le quita el poder enseguida.
- **Permiso por comando.** Cada comando del `CommandRegistry` declara su `min_role`; sin permiso o desconocido:
  «Comando desconocido. Escribe /ayuda.». Sin plataforma, como hoy (consola, y DEBUG_COMMAND con
  `--debug-commands`).
- **DEBUG_COMMAND con plataforma** (solo en `dev` y `test`, §5.5) exige además el `min_role` del comando: `gm` para
  todos los de red (teletransporte, vida, fuerte, 40–43 de progresion.md). Sin el rol, suma un aviso como hoy y no
  se ejecuta ni se guarda nada.
- **Sobre los propios personajes.** `item_give`, `item_take`, `currency_add`, `level_set`, `xp_add` y `op_revert`
  sobre un personaje de la propia cuenta responden «No puedes usarlo sobre tus personajes», salvo con rol `admin` o
  con `env` `dev` o `test`. La auditoría guarda siempre `target_account_id`.
- **Invisible.** La entidad del GM no entra en el interés de los demás (`InterestPolicy`), su `Combatant` no hace
  ni recibe daño (`CombatResolver` lo salta), no cuenta en `_presence_candidates` (círculo), ni en `ScoreKeeper`, ni
  en las recompensas de progresion.md (méritos, XP, oro). `/gm visible` lo deshace; los dos van auditados.
- **Auditoría:** todo comando de GM, de consola o de depuración con plataforma va al lote de `audit` (`{key,
  actor_character_id, command, target_character_id, target_account_id, args, at_unix, source}`) y al registro de la
  zona; los de la CLI y las sanciones, directos a `audit_log`. **Las lecturas también:** `inv_show`, `ledger_show`
  y `op_show` (lote de la zona), y `admin reports list|show`, `admin audit` y `admin chat` (social.md §8: «registro
  de cada consulta»).
- **La CLI tiene identidad.** Toda orden `admin` exige `--actor <correo>` de una cuenta `admin` (o `moderator` para
  las de lectura: `reports list|show`, `audit`, `chat`); sin él, o con otra cuenta, no se ejecuta (código 2). Rellena
  `audit_log.actor_account_id` y guarda en `args.os_user` el valor de `$SUDO_USER` o `$USER`. Consulta: `admin
  --actor <correo> audit --since 2026-11-01 [--actor-name <nombre>] [--target <nombre>]`.

### 9.2 Registro del chat (SOC-15)
`ChatRouter` (SOC-04) pone cada mensaje ya saneado en el lote de `chat` (`{key, channel, sender_character_id,
target_character_id, text, sent_at_unix}`). Retención de 30 días (§11.1). Consulta: `admin --actor <correo> chat
--character <nombre> --from … --to …`, que queda auditada.

### 9.3 Ignorados (SOC-16)
- `/ignorar nombre` → zona → `POST /internal/v1/ignores` con el `character_id` de quien ignora: la plataforma
  comprueba que tiene arrendamiento en esa instancia, resuelve la cuenta del nombre (en ese `world_id`) y guarda
  `(cuenta, cuenta ignorada, personaje nombrado, nombre)`. Hasta 100. La lista que ve el jugador solo enseña los
  nombres que él escribió.
- La zona tiene, por jugador, las cuentas que ignora (llegan en la reclamación) y la cuenta de cada personaje. **El
  servidor descarta** los susurros, invitaciones y (fase 6) correo de una cuenta ignorada, y la quita de los
  destinatarios de los canales públicos: el cliente no puede ocultarla sin saber qué personajes comparten cuenta, y
  eso no se le dice. social.md §10 y SOC-16 lo dicen ya así.

### 9.4 Reportes (SOC-17)
`/reportar nombre categoría [comentario]` o el menú social. La zona adjunta los últimos 20 mensajes de ese personaje
que **recibió** quien reporta en 10 min (un anillo por receptor en `ChatRouter`), zona, posición y tick, y manda
`{zone_instance_id, world_id, reporter_character_id, target_name, category, comment, context, evidence:
[{sender_name, channel, text, sent_at_unix}]}`. La plataforma comprueba que quien reporta tiene arrendamiento en esa
instancia, impone 1 por objetivo cada 10 min y 10 por hora por cuenta (429), copia la prueba a `report_evidence` y la
zona contesta «Reporte enviado. Gracias.». Revisión: `admin --actor <correo> reports list|show|close` (auditadas).

### 9.5 Sanciones (SOC-18)
| Tipo | Dónde se aplica |
|---|---|
| Aviso | Al entrar, NOTICE con el motivo |
| Silencio | `ChatRouter` descarta y contesta «Estás silenciado N min más»; llega en la reclamación y en `mutes` del latido |
| Suspensión, expulsión permanente | Inicio de sesión (tras la contraseña) y `enter` (403 con fin y motivo), reclamación (`BANNED`) y latido (`revoked`: guardado final y expulsión) |
| Renombrado forzado | `characters.must_rename`: `enter` → 409 `rename_required` |

Toda sanción lleva motivo, autor, `ends_at` y sus reportes, con la escala de social.md §9. La crean `/gm …` (por
`POST /internal/v1/sanctions`) o `admin --actor <correo> sanction …`. **La plataforma autoriza**, en la transacción
de la sanción:

1. El autor (`author_character_id`) tiene arrendamiento en esa instancia (`zone_instance_id`).
2. Su cuenta tiene el rol mínimo de la tabla de §9.1 para ese `kind` y esa duración.
3. La cuenta objetivo (el `target_name` en ese `world_id`) tiene un rol **menor** que el del autor.

Si falla alguna: 403 `forbidden` y una fila en `audit_log` con `command = 'sanction_denied'`. La CLI pasa las mismas
comprobaciones con la cuenta de `--actor`. Un fallo de `CommandRegistry` o una zona comprometida no pueden sancionar
por su cuenta. Las normas se aceptan al crear la cuenta (§11.4).

## 10. Seguridad, cifrado y secretos (TEC-27)
### 10.1 HTTPS
- La plataforma sirve HTTP; en staging y producción, **Caddy** delante con Let's Encrypt y de 80 a 443
  (`platform/deploy/Caddyfile`, con `reverse_proxy platform:24680 { header_up X-Real-IP {remote_host} }` y **sin
  registro de accesos**). La API interna no pasa por Caddy.
- El cliente usa `TLSOptions.client()` (los certificados raíz de Godot) y rechaza `http://` salvo hacia loopback.
  Staging con certificado propio: `eldmark/platform/ca_cert` (ruta a un PEM).
- Comprobado en Godot 4.7.2: `HTTPRequest` con `TLSOptions.client(X509Certificate)` habla con un Go con certificado
  propio (200 en 63 ms) y un 400 trae su JSON. Sin anclar da `RESULT_TLS_HANDSHAKE_ERROR` **y el motor registra un
  ERROR**, que el ejecutor cuenta como fallo: ninguna prueba de Godot provoca un fallo de TLS (eso se prueba en Go).
  `RESULT_CANT_CONNECT` y `RESULT_TIMEOUT` no registran errores.

### 10.2 DTLS en ENet
- **Contrato en `scripts/shared/net/net_transport.gd`** (P9c): `host(port: int, max_peers: int, dtls: TLSOptions =
  null) -> Error` llama a `peer.host.dtls_server_setup(dtls)` tras `create_server` y antes de envolverlo en
  `GuardedEnetPeer`; `connect_to(address: String, port: int, connect_timeout_ms: int = 3000, dtls_name: String = "",
  dtls: TLSOptions = null) -> Error` llama a `peer.host.dtls_client_setup(dtls_name, dtls)` justo tras
  `create_client`. Sin `dtls`, como hoy. `NetTransport` no lee archivos: los PEM los cargan `ServerMain` y el
  cliente.
- La zona (`--dtls-cert=<pem> --dtls-key=<pem>`, con o sin plataforma) manda el PEM público y `dtls_name` (el `CN`
  del certificado) al registrarse. El cliente lo recibe en `enter` (por HTTPS, que lo autentica). Sin CA propia ni
  certificado empaquetado: rotarlo no pide parche del cliente. Sin plataforma, `--connect`, `--bot` y `--bots`
  aceptan `--dtls-cert=<pem> --dtls-name=<cn>`, y cada `SwarmBot` configura su `NetTransport` igual.
- En `staging` y `production` la plataforma no registra una zona sin certificado (§6): «sin DTLS no hay pruebas
  públicas» se cumple solo.
- Comprobado con `ENetMultiplayerPeer` en un proceso: conecta y entrega un paquete por DTLS. Salir sin `close()`
  hace que el motor registre un error de `bio_send`: se cierran los peers antes.
- **Sin comprobar:** DTLS con `GuardedEnetPeer` y la autenticación de `SceneMultiplayer`, y su coste. TEC-27 mide la
  CPU por paquete, los bytes de más por datagrama y el tope de 1200 B frente al MTU de ENet, con `--bots=64` con y
  sin `--dtls-cert` contra la misma zona. **Criterio** (provisional, tomado de noche; pregunta para el usuario, §0):
  DTLS no sube el p99 del tick más de un 10 % y la cifra absoluta se anota en red.md §14. El del backlog (p99 < 8 ms
  con 64 bots) no se cumple ni sin DTLS (15,9 ms).

### 10.3 Secretos
| Secreto | Dónde vive | Rotación |
|---|---|---|
| URL de la base | `ELDMARK_DATABASE_URL_FILE` (secreto de Docker) | `alter role … password`, secreto nuevo y reinicio |
| Claves del billete | `ELDMARK_TICKET_KEYS_FILE` en la plataforma y en cada zona | Clave nueva en las zonas → firmar con ella → quitar la vieja tras 1 min |
| Token de cada zona | `ELDMARK_ZONE_TOKENS_FILE` (plataforma: solo hashes con su alcance) y `ELDMARK_ZONE_TOKEN_FILE` (zona: el token) | Dos entradas con el mismo alcance durante el cambio |
| Clave DTLS de cada zona | Secreto de Docker | Certificado nuevo y reinicio; el cliente lo recibe en el siguiente `enter` |
| SMTP | `ELDMARK_SMTP_URL_FILE` | En el proveedor |
| Clave HMAC de correos | `ELDMARK_EMAIL_HMAC_KEY_FILE` | No se rota en la fase 5 (cambiarla vacía `sanctioned_email_hashes`) |

- La zona lee sus secretos solo de variables o archivos (`OS.get_environment`), nunca de la línea de órdenes, que se
  ve con `ps`. El compose los monta desde `platform/deploy/secrets/<nombre>` como secretos de Docker.
- **Nada entra en git.** Hoy `.gitignore` solo ignora `.env` (comprobado con `git check-ignore --no-index`:
  `platform/deploy/staging.env`, `secrets/ticket_keys` y `zone.key` no se ignoran). P0 añade `*.env`,
  `!*.env.example`, `platform/deploy/secrets/`, `*.pem`, `*.key` y `!tests/data/**/*.pem` (comprobado en un
  repositorio de prueba: ignora los reales y deja los ejemplos y los PEM de prueba).
- **CI** (trabajo «Plataforma»): falla si `git ls-files` lista algún `*.env`, algo bajo `secrets/` o un `*.pem` o
  `*.key` fuera de `tests/`, o si `grep -rE
  'ELDMARK_(TICKET_KEYS|ZONE_TOKENS?|SMTP_URL|DATABASE_URL|EMAIL_HMAC_KEY)=[^[:space:]]' platform/deploy/*.example`
  encuentra algo.

## 11. Privacidad y RGPD (TEC-43)
### 11.1 Datos y retenciones
Hay cuenta (correo, hash, fechas, rol, estado), sesiones y accesos (IP, agente), aceptaciones, consentimientos,
derechos, personajes (nombre, apariencia, progreso, estadísticas), ignorados, chat, reportes, sanciones y
auditoría. Ni nombre real, ni dirección, ni pagos (si los hay, son del proveedor).

| Dato | Se conserva | Cómo |
|---|---|---|
| `chat_messages` | 30 días | Trabajo horario, lotes de 10 000 |
| `report_evidence`, reportes cerrados, `audit_log` | 1 año (desde el cierre en los reportes) | Trabajo horario |
| `auth_events`; IP y agente de `sessions` | 30 días | Trabajo horario (la IP de la sesión pasa a null) |
| `sessions` y `account_tokens` caducados · `enter_tickets` · `zone_instances` paradas · `outbound_mail` | 7 días · 1 día · 30 días · 7 días | Trabajo horario |
| Cuenta sin verificar (`staging`, `production`) | 7 días | Purga (§11.2) |
| Personaje borrado | 7 días restaurable; luego lápida; el nombre, 30 días más (o nada, §4.4) | Purga horaria |
| Libro, operaciones y eventos de objeto de un personaje purgado | **1 año** desde la purga, sin datos personales (la lápida no tiene nombre) | Retención horaria con `set local eldmark.retention_purge = 'on'`; luego se borra la lápida. **Revisión legal** |
| Cuenta borrada | 14 días de gracia | Purga (§11.2) |
| Sanciones | Mientras exista la cuenta; tras la purga, 1 año sin datos personales | **Revisión legal** |
| `sanctioned_email_hashes` | Hasta el fin de la sanción, o 90 días tras ella; 1 año como mucho | Trabajo horario. **Revisión legal** |
| Copias diarias y semanales, WAL | 35 días; al restaurar se vuelven a aplicar las purgas (§12) | `backup.sh` y WAL-G |
| Registros de los contenedores (zona, plataforma) | 30 días: la zona escribe nombre e IP en cada conexión y rechazo | journald (`MaxRetentionSec=30day`, §12) |
| `fortress_events`, `realm_resources` | Sin límite: no son personales | — |

En `staging` y `production` con `--platform`, la zona no admite `--battle-log`, `--combat-log` ni `--state-log`
(escriben nombres sin plazo; §5.5).

### 11.2 Exportación y supresión
**Exportar:** `POST /v1/account/export {password}` (1 al día) da `eldmark-datos-<fecha>.json`: cuenta (sin el
hash), aceptaciones, consentimientos, sesiones y accesos de 30 días, derechos, personajes con progreso, inventario,
libro y estadísticas, ignorados (por nombre), sanciones propias, reportes **hechos** y chat enviado por sus
personajes en plazo. No da reportes recibidos ni notas de moderación (de terceros: **revisión legal**).

**Purgar un personaje** (al vencer `restore_until`, o con la cuenta), en una transacción:
`progress_purge_character(id)`, `delete from character_pvp_stats`, `character_leases` y `enter_tickets` de ese
personaje, `character_names.character_id = null`, `update characters set name = null, name_key = null, purged_at =
now()` y `insert into purge_log ('character', id)`. Queda la **lápida** (id, mundo, reino, cuenta y fechas) y lo de
solo añadir, que la retención de §11.1 borra al año. Comprobado: borrar la fila del personaje con apuntes falla
(clave ajena) y la lápida va bien.

**Suprimir la cuenta:** `POST /v1/account/deletion` → 14 días → purga en una transacción: sus personajes (como
arriba; nombres reservados 30 días), ignorados en los dos sentidos, sesiones, tokens, consentimientos, aceptaciones,
derechos y el chat de sus personajes no copiado a un reporte. La fila de `accounts` queda como lápida (`email` y
`password_hash` a null, `status = 'purged'`) para que auditoría y sanciones no apunten a nada; `purge_log
('account', id)`. `admin --actor <correo> purge-now <correo>` hace lo mismo sin esperar (petición expresa).

**Correos sancionados.** Si la cuenta tiene una suspensión o una expulsión vigente, o una sanción de los últimos 90
días, la purga guarda `HMAC-SHA256(ELDMARK_EMAIL_HMAC_KEY, correo normalizado)` en `sanctioned_email_hashes` con
`until` = fin de la sanción (o + 90 días), 1 año como mucho. El registro lo consulta (§4.2): la escala de social.md §9
sigue contando aunque el jugador pida la supresión y vuelva. **Revisión legal**; va también en `privacy-1.md`.

**Copias.** `backup.sh` copia `purge_log` a `purges.txt` junto a cada copia y conserva siempre el más reciente.
Restaurar es siempre `pg_restore` y luego `eldmark-platform admin --actor <correo> reapply-purges purges.txt` con el
`purges.txt` **más reciente** (no el de la copia): vuelve a purgar cuentas y personajes, y es idempotente.
`restore_check.sh` lo hace también.

### 11.3 Derechos de cuenta (PRG-41)
`entitlements` vale para compra única, suscripción o gratuito con tienda: huecos (`character_slots`), expansiones
(`expansion`, `ref` = id) y cosméticos (`cosmetic`, `ref` = id de PRG-40). **Ningún derecho llega a la simulación ni
al combate**; la zona solo recibirá cosméticos (fase 8). El modelo de negocio lo decide el usuario y se anota en
vision.md.

### 11.4 Textos legales y consentimientos
- `platform/legal/terms-1.md`, `privacy-1.md` y `rules-1.md` (las normas de social.md §9 y `docs/normas.md`,
  SOC-18): **borradores** con la cabecera «Borrador pendiente de revisión legal; no es asesoramiento jurídico». Al
  arrancar, la plataforma calcula su SHA-256 e inserta la versión en `legal_documents` si falta. `privacy-1.md`
  recoge la tabla de §11.1 entera.
- Edad: casilla «Tengo 16 años o más» (`age_confirmed_at`; **revisión legal**: en España es desde los 14).
  Consentimientos separados, desmarcados y cambiables en Ajustes: informes de fallos (TEC-42) y analítica (TEC-44).

## 12. Operación (TEC-28)

| Pieza | Aquí (automatizable) | En el VPS (usuario) |
|---|---|---|
| Desarrollo local | `deploy/dev.sh`: PostgreSQL efímero en `build/dev_pg` (como §2.6), `migrate up`, claves y un token por zona de desarrollo (`1:vado_gris:0`, `1:test_world:0`) en `build/dev_platform.env`, `admin create-account prueba@eldmark.test` (y una cuenta `admin` para `--actor`) y la orden de la zona con `--platform` | — |
| Imagen | `deploy/Dockerfile`: binario estático (`CGO_ENABLED=0`) sobre `debian:bookworm-slim`, usuario sin privilegios | Registro de imágenes (GHCR) |
| Compose | `docker-compose.yml` con `db` (postgres:16), `platform`, `caddy` y las zonas de TEC-20 (`restart: unless-stopped`); secretos desde `secrets/`; `logging: {driver: journald, options: {tag: "{{.Name}}"}}` en todos; `staging.env.example` y `production.env.example`. `docker compose config -q` lo valida sin demonio (comprobado) | Bases y secretos por entorno; staging desde `main`, producción desde tags (SSH); `journald-eldmark.conf` (`MaxRetentionSec=30day`, `SystemMaxUse=2G`) en `/etc/systemd/journald.conf.d/` (sin comprobar aquí: no hay systemd) |
| Mantenimiento | `admin --actor <correo> maintenance --in 10m --message "…"`: `/v1/status` lo anuncia, `enter` responde 503 salvo a `admin`, y el latido lo pasa a las zonas, que avisan por NOTICE a los 10, 5 y 1 min, 30 s y 10 s, guardan a todos y se paran solas. `admin maintenance off` lo quita | `deploy.sh`: copia previa, parar, `migrate up`, versión nueva, quitar el mantenimiento |
| Vuelta atrás | `down` solo en desarrollo y CI; migraciones de expandir y contraer (§2.4) | **Restaurar la copia previa** (con `reapply-purges`) o arreglar hacia delante; el tag anterior funciona con el esquema nuevo |
| Copias | `backup.sh`: `pg_dump -Fc` con 7 diarias y 4 semanales en un directorio, y `purges.txt` (§11.2) | Subirlas a S3 compatible (rclone o WAL-G) y el cron |
| WAL y recuperación a un instante | `pitr_check.sh`: clúster efímero con `archive_command`, `pg_basebackup`, `recovery_target_time` y `recovery.signal`: recupera las filas de antes de un borrado (comprobado en segundos) | `archive_command` a S3 con WAL-G; retención de 35 días |
| Restauración semanal | `restore_check.sh <copia> <purges.txt>`: clúster efímero, `pg_restore` (comprobado: 1000 filas en 188 ms), `reapply-purges`, `migrate status` al día y consultas de integridad (personajes sin cuenta, arrendamientos de instancias inexistentes, ids de `purge_log` con datos personales: 0) | Ejecutarlo cada semana y alertar si falla (TEC-31) |

## 13. Cliente (UI-22, UI-23, UI-24)
### 13.1 Flujo
```
título ──Entrar──▶ (aceptar textos nuevos) ──▶ selección ──Entrar──▶ OnlineMain con billete
  │ Crear cuenta · ¿Has olvidado la contraseña?      │ Crear ──▶ creación ──▶ selección
  └ Ajustes (F10) · Salir                            │ Borrar · Restaurar · Cerrar sesión ──▶ título
OnlineMain: rechazo o desconexión ──▶ selección con el motivo (la sesión sigue)
```

`FrontMain` (`scenes/client/front_main.tscn`) monta las pantallas y guarda la `AccountSession`. Al entrar, usa
`AccountFlow.enter` (§13.3) y pasa a `OnlineMain` el `ClientConfig` que devuelve (host, puerto, `character_id`,
billete, certificado DTLS, nombre y reino); con `config.from_front`, `OnlineMain` vuelve a `FrontMain` en vez de a
`RealmSelect`. Lo visual es **provisional**: tema de UI-02, `UIWindow`, `UIConfirmDialog`; el fondo, el logotipo y
la música son de ART-21.

### 13.2 Pantallas
| Pantalla | Contenido | Teclado |
|---|---|---|
| Título (UI-22) | Fondo provisional (captura fija del Vado Gris), «Eldmark» con la fuente de títulos, estado («En línea · Eld», «En mantenimiento hasta las 18:00», «Sin conexión con el servidor») y noticias de `/v1/status`; correo, contraseña, «Recordar correo» (`user://settings.cfg`, sección `account`; nunca la contraseña), Entrar, Crear cuenta, ¿Has olvidado la contraseña?, Ajustes, Salir | Intro entra; Tab recorre; Esc cierra el panel |
| Crear cuenta | Correo, contraseña dos veces (mínimo 10), «Tengo 16 años o más», tres casillas con enlace a cada texto (panel con desplazamiento) y los dos consentimientos opcionales. Al enviar: «Te hemos enviado un correo» (en `dev` y `test`, inicia sesión con lo escrito) | |
| Recuperar · aceptar textos | Correo → «Si existe una cuenta, te hemos enviado un enlace» · qué ha cambiado, Aceptar o Cerrar sesión | |
| Selección (UI-23) | Lista a la izquierda (nombre, emblema del reino, nivel, última zona; los borrados en gris con «Restaurar» y su fecha límite), vista 3D del elegido (`HumanoidVisual` con su apariencia y los colores de su reino), huecos libres («Los borrados que aún puedes restaurar ocupan hueco»), Entrar, Crear, Borrar (confirmación escribiendo el nombre), Cerrar sesión | Flechas eligen, Intro entra, Supr borra |
| Creación (UI-24) | 1) Reino: tarjetas con lore, emblema y capital; fijado al de la cuenta; Askarra «Próximamente». 2) Cuerpo y apariencia (cuerpo, cabeza, pelo, colores, aleatorio, cámara orbital con el ratón) con lo que haya de ART-19 y ART-20; sin ello, el humanoide con los colores del reino. 3) **Plantilla de inicio** (tarjetas de las plantillas de PRG-07: armas y estilo; progresion.md §2.5). 4) Nombre validado con `NameRules` al escribir y con `name-check` tras 500 ms quieto. Crear | Esc vuelve un paso |
| Renombrar · ocupado | Diálogo de nombre al recibir `rename_required` · «Tu personaje está saliendo del mundo…» con cuenta atrás; reintenta cada 3 s durante 30 s | |

Errores: el texto de §4.1 bajo el formulario; sin conexión o fallo de TLS, «No se puede conectar con el servidor de
cuentas». Los REJECT nuevos vuelven a la selección con su texto.

### 13.3 Configuración, `AccountFlow` y archivos
`ClientConfig` añade `platform_url` (`--platform=`), `login` (`--login=`), `password_file` (`--password-file=`),
`character_name` (`--character=`), `world_id` (`--world=`, 1), `title` (`--title`), `dtls_cert_path`
(`--dtls-cert=`) y `dtls_name` (`--dtls-name=`) y, para `OnlineMain`, `character_id`, `ticket: PackedByteArray`,
`dtls_cert_pem` y `from_front`; y el modo `TITLE`. Prioridad: `--bots` > `--bot` > `--connect`/`--local` >
`--title`/`--platform` > sin argumentos (sandbox en el editor, título exportado). Ajuste de proyecto
`eldmark/platform/url` (`http://127.0.0.1:24680`; la exportación de pruebas lo cambia).

**`AccountFlow`** (`scripts/client/platform/account_flow.gd`, sin interfaz) hace el camino de la cuenta: `login`,
`ensure_character` y `enter`, que devuelve el `ClientConfig` con billete. Lo usan `FrontMain` y `OnlineMain` en modo
`BOT` cuando `config.platform_url` no está vacío: el bot lee la contraseña de `--password-file`, inicia sesión, crea
el personaje si no existe (con la primera plantilla y la apariencia por defecto de su raza) y conecta. Un fallo
(credenciales, `character_busy` tras 30 s, `zone_unavailable`) sale con código 1 y el `code` en el informe. Sin
plataforma, el bot conecta como hoy a `--connect` (o a 127.0.0.1:24600).

Nuevos: `scripts/client/platform/` (`platform_api.gd`, `api_result.gd`, `account_session.gd`, `account_flow.gd`,
`platform_errors.gd`), `scripts/client/front_main.gd` y `scripts/client/ui/` `title_screen.gd`,
`register_panel.gd`, `terms_panel.gd`, `character_select.gd`, `character_create.gd`, `rename_dialog.gd` (escenas en
`scenes/ui/`). `ClientLauncher` lleva `TITLE` a `FrontMain`; `NetClient` pone en el HELLO `character_id`, `ticket`,
`realm` y `name` de `ClientConfig` y pasa el certificado a `NetTransport.connect_to` (§10.2).

## 14. Paquetes y contratos
### 14.1 Paquetes
| Paquete | Contenido | Depende de |
|---|---|---|
| **P0 · esqueleto** (TEC-22) | `platform/`, config, `logx`, `db`, `jsonx`, `migrate` y 0001–0006, `testdb`, `/health`, `/ready`, `serve`/`migrate`, `.gdignore`, filtro de exportación, `.gitignore` (§10.3), trabajo de CI con la comprobación de secretos | TEC-03 |
| **P1 · cuentas** (TEC-23, TEC-41, aceptación de TEC-43) | `passwords`, `accounts` (`CheckPassword`, fallos por cuenta y grupo), sesiones con rotación en la fila, límites, ciclo de vida, `revert_email`, `mail`, páginas `/verify`, `/reset`, `/revert`, `/v1/status`, `/v1/legal`, purga de cuentas sin verificar | P0 |
| **P2 · personajes** (TEC-24, SOC-13, PRG-41) | `names`, `gamedata` (sección `names` de `progression_rules.json` y su embed), personajes, reinos, huecos, límites de crear y borrar, `enter`, `tickets` | P1; progresion.md P3 para validar raza, apariencia y plantilla (sin él, §4.4 paso 5) |
| **P3 · API interna** (TEC-24, TEC-25) | `zones` (tokens por despliegue, registro, `live`, latido, perdidas, sustitución, estados de §6.1), reclamación, guardado (S1–S2, `seq`, hash), liberación, lotes, rutas de bloques, fortalezas; `ProgressStore` con un falso en las pruebas | P2 |
| **P3b · progreso en el servicio** (PRG-10, PRG-12, TEC-25) | 0010_progress (§3), `internal/progress` (Create, Load, Apply con S3–S9 y bloques, Purge, Op, Ledger), rutas de operación y libro | P3; los casos de `tests/fixtures/progression/` (progresion.md P5) cuando existan |
| **P4 · billete en la zona** (TEC-24) | `HandoffTicket`, `TicketAuthProvider`, `AuthProvider` y `ServerAuth` ampliados, `VERIFYING` (cupo y plazo), REJECT 10–12, `PROTOCOL_VERSION` y `AUTH_TIMEOUT_SECONDS` (una subida con progresion.md P4), bit GM, `ZonePlatform`, `PlatformClient` (prioridades), `ClaimedCharacter`, `AuthOutcome`, `tests/fake_zone_platform.gd`, `tests/support/fake_http_server.gd`, opciones de `ServerConfig`, arranque de §8 (registro, `env`, `live`), cercado | Los contratos de P3 (no su código: usa los falsos) |
| **P5 · guardado en la zona** (TEC-25; ganchos de CMB-30 y GUE-19) | `CharacterSaver`, `PlatformProgressRepository`, salida en combate, cierre ordenado (`begin_flush`, `_drain_stop` ampliado, `SHUTDOWN_MAX_FRAMES`), `revoked`, cierre de §6.1 | P4; la interfaz `ProgressRepository` y la sección `progress` de progresion.md P5 (sin ella, una sección falsa) |
| **P6 · guerra** (GUE-19) | `FortressPersistence`, carga al arrancar, `expected_version`, eventos, `ScoreKeeper.captures` y `defend_ticks`, sección `pvp` | P3, P5 |
| **P7a · moderación en Go** (SOC-14 a SOC-18) | Roles, `set-role` que revoca, auditoría (también de lecturas), chat, ignorados, reportes, sanciones con autorización, CLI `admin` con `--actor` | P3 |
| **P7b · moderación en la zona** (SOC-14 a SOC-18) | `min_role` en `CommandRegistry`, DEBUG_COMMAND con rol, `/gm`, invisible, regla de los propios personajes, filtrado de ignorados, anillo de reportes, silencios, lotes de chat y auditoría | P5, P7a; SOC-03, SOC-04 |
| **P8 · cliente** (UI-22 a UI-24) | `ClientConfig`, `PlatformApi` (un refresco a la vez), `AccountSession`, `AccountFlow`, `FrontMain`, pantallas, `NetClient` y `OnlineMain` con billete, bot con cuenta | Contratos de P1 y P2 (con `request_hook` hasta tenerlos); ART-19 y ART-20 para la creación completa |
| **P9a · privacidad** (TEC-43) | Exportación, purgas (lápidas, `purge_log`), retenciones, `sanctioned_email_hashes`, `reapply-purges`, borradores legales | P1–P3b |
| **P9b · operación** (TEC-28) | Caddy, compose (journald, secretos), `dev.sh`, `backup.sh` con `purges.txt`, `restore_check`, `pitr_check` | P9a; TEC-20 para las imágenes de las zonas |
| **P9c · DTLS** (TEC-27) | `NetTransport.host`/`connect_to` con `TLSOptions`, `--dtls-*` en `ServerConfig` y `ClientConfig`, `SwarmBot`, campaña de medida y su anotación en red.md §14 | P4 |
| **P10 · extremo a extremo** | `platform/e2e` y su trabajo de CI (§15) | P3, P3b, P4, P5, P8 |

P0 primero; P1 y P4 a la vez (P4 contra los falsos); luego P2, P3, P3b y P8; luego P5, P6, P7a y P7b; P9a, P9b, P9c
y P10 al final. `zone_server.gd` lo tocan P4, P5, P6 y P7b, en ese orden.

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
// internal/accounts
func (s *Service) CheckPassword(ctx context.Context, accountID int64, password string, ip netip.Addr) (bool, error)  // ErrThrottled → 429
// internal/jsonx: type Int int64 (acepta 4 y 4.0); type ID int64 (cadena decimal > 0)
// internal/names: func Validate(name string) Reason (valores de NameRules.Reason); func NormalizeKey(name string) string
// internal/testdb: func Main(m *testing.M) int (en TestMain); func New(t testing.TB) *pgxpool.Pool (base nueva)
// internal/zones
type Scope struct { WorldID int16; ZoneID string; Channel int16 }
func (r *Registry) Authenticate(bearer string) (Scope, bool)         // SHA-256 y subtle.ConstantTimeCompare
// internal/persistence
func (s *Store) Claim(ctx context.Context, instance [16]byte, ticketID, characterID int64) (ClaimResult, error)
func (s *Store) Save(ctx context.Context, characterID int64, raw []byte, req SaveRequest) (SaveResult, error)  // raw: para el hash
func (s *Store) SaveMany(ctx context.Context, instance [16]byte, raws [][]byte, reqs []SaveRequest) ([]SaveResult, error)  // todo o nada
func (s *Store) Release(ctx context.Context, characterID int64, instance, leaseID [16]byte) error
// internal/persistence/progress.go: ProgressStore (§7.5); internal/progress la implementa (P3b)
```

### 14.3 Contratos en GDScript (zona)
```gdscript
# scripts/server/auth_provider.gd (amplía; DevAuthProvider: OK al instante, uses_tickets() false y on_platform_event false)
const PENDING: int = -1
func authenticate(peer_id: int, hello: NetMessages.Hello) -> int  # OK, PENDING o motivo de REJECT
func on_platform_event(event: PlatformEvent) -> bool  # true si era suyo (reclamaciones y liberaciones)
func take_completed() -> Array[AuthOutcome]     # los PENDING resueltos, en orden de llegada
func cancel(peer_id: int) -> void               # el peer se fue esperando: libera si llegó a reclamar
func uses_tickets() -> bool                     # true: ServerAuth no mira reino ni nombre del HELLO
# scripts/server/platform/auth_outcome.gd
class_name AuthOutcome extends RefCounted
var peer_id: int; var result: int; var text: String; var claimed: ClaimedCharacter   # text vacío: result_text
# scripts/server/platform/handoff_ticket.gd: un var int por campo de §5.1, con su nombre
class_name HandoffTicket extends RefCounted
const SIZE: int = 52
static func zone_key_of(zone_id: String) -> int
static func decode(bytes: PackedByteArray) -> HandoffTicket      # null si tamaño o versión no valen
func verify(bytes: PackedByteArray, keys: Dictionary[int, PackedByteArray]) -> bool
func sign(key: PackedByteArray) -> PackedByteArray                # pruebas y el falso
# scripts/server/platform/claimed_character.gd (P4)
class_name ClaimedCharacter extends RefCounted
var character_id: int; var account_id: int; var world_id: int; var realm: int; var display_name: String
var role: StringName; var lease_id: String; var muted_until_unix: int; var ignored_accounts: PackedInt64Array
var record: Dictionary        # el CharacterRecord de progresion.md §3.4 tal cual; lo lee CharacterRecord.from_dictionary
var pvp: Dictionary           # {kills, deaths, assists, captures, gate_damage, defend_s} ya con int()
static func from_claim(body: Dictionary) -> ClaimedCharacter      # null si falta algo; ids con to_int() y enteros con int()
# scripts/server/platform/zone_platform.gd (tests/fake_zone_platform.gd: class_name FakeZonePlatform extends ZonePlatform)
class_name ZonePlatform extends Node
signal startup_finished(ok: bool, error: String)                  # tras el registro y las fortalezas (§8)
var timeout_s: float = 3.0
func start(config: ServerConfig, secrets: Dictionary) -> void     # registro (starting), latidos, GET de fortalezas
func fortress_records() -> Array[Dictionary]                      # las cargadas en start
func env() -> StringName                                          # &"dev", &"test", &"staging" o &"production"
func go_live() -> void                                            # POST …/live, tras abrir el puerto
func claim(peer_id: int, ticket: HandoffTicket) -> void
func claimed(character_id: int) -> ClaimedCharacter               # la última reclamación de ese personaje
func release(character_id: int, lease_id: String) -> void
func save(character_id: int, body: PackedByteArray, context: Variant) -> void   # el mismo cuerpo hasta una respuesta definitiva
func request_id_block() -> void
func put_fortress(fortress_id: StringName, record: Dictionary) -> void  # una en vuelo por fortaleza; la más reciente
func enqueue_batch(kind: StringName, entry: Dictionary) -> void   # &"chat", &"audit", &"war"
func request(kind: StringName, method: HTTPClient.Method, path: String, body: Dictionary, priority: int,
		context: Variant) -> void
func take_events() -> Array[PlatformEvent]                        # en el paso «poll»
func begin_flush() -> void                                        # cierre: lotes y guardados pendientes salen ya
func is_flushed() -> bool                                         # nada en cola ni en vuelo
func is_fenced() -> bool                                          # sin latido aceptado en 2 × heartbeat_s
func is_live() -> bool
func now_unix() -> int                                            # reloj corregido
# scripts/server/platform/character_saver.gd (P5)
class_name CharacterSaver extends RefCounted
enum Reason { CHECKPOINT = 1, CRITICAL = 2, LOGOUT = 3, SHUTDOWN = 4, KICK = 5 }
signal save_rejected(net_id: int, character_id: int, code: String)   # lease_lost, invalid_save…: la zona expulsa
func _init(repository: ProgressRepository, interval_ticks: int = 3600) -> void
## build(net_id) -> Variant (la parte del cuerpo); acknowledge(net_id, save_version) -> void; is_dirty(net_id) -> bool
func register_section(section: StringName, build: Callable, acknowledge: Callable, is_dirty: Callable) -> void
func track(net_id: int, character_id: int, lease_id: String, tick: int) -> void   # tras el alta
func mark_critical(net_id: int) -> void
func step(tick: int) -> void                                          # tras «altas»
func finish(net_id: int, reason: int) -> void                         # foto en el momento, con release_lease
func drop(net_id: int) -> void                                        # sin guardar (lease_lost, invalid_save)
func pending_count() -> int
# scripts/server/platform/platform_progress_repository.gd (P5)
class_name PlatformProgressRepository extends ProgressRepository      # §7.5
func _init(platform: ZonePlatform) -> void
func on_platform_event(event: PlatformEvent) -> bool                  # guardados y bloques
```

- `PlatformEvent` (`kind`, `context`, `transport_ok`, `status`, `body`, `error_code`) es el resultado de una
  petición, con `body` ya leído (ids con `to_int()`, enteros con `int()`).
- `ServerConfig` añade `--platform=<url interna>`, `--world=<id>` (1), `--channel=<n>` (0),
  `--public-address=<host>[:<puerto>]` (127.0.0.1 y su puerto), `--save-interval=<s>` (60), `--replace`,
  `--dtls-cert=` y `--dtls-key=`.
- `ZoneServer.start(config, world, transport, auth_provider, platform: ZonePlatform = null)`: con plataforma, aplica
  `platform.fortress_records()` antes de `_transport.host`. `ServerMain` elige el `AuthProvider`, espera
  `startup_finished`, llama a `start` y, si va bien, a `platform.go_live()`. `ServerAuth.validate` recibe el `peer_id`
  como primer argumento para pasárselo.
- `ZoneServer.get_player_count()` cuenta `VERIFYING` (§5.2). `_drain_stop` no pasa a `STOPPED` mientras
  `saver.pending_count() > 0` o `not platform.is_flushed()`, con un tope de 600 ticks; `ServerMain.SHUTDOWN_MAX_FRAMES`
  pasa de 90 a 720. `HTTPRequest` avanza con el bucle principal, que sigue vivo mientras `ServerMain` espera con
  `await get_tree().physics_frame`: no hay esperas síncronas.
- **Orden del tick** (amplía zone_server.gd): en `poll`, tras el transporte, `platform.take_events()` se reparte
  (`auth_provider.on_platform_event`, luego `repository.on_platform_event`, `revoked` y silencios a la zona,
  fortalezas a `FortressPersistence`) y luego `auth_provider.take_completed()`; en cada tick, los `VERIFYING`
  vencidos (7 s en tiempo real); tras `altas`, `CharacterSaver.step(s)`.

### 14.4 Contratos en GDScript (cliente)
```gdscript
# scripts/client/platform/platform_api.gd
class_name PlatformApi extends Node
signal session_lost(code: String)               # refresco imposible: vuelta al título
var base_url: String
var request_hook: Callable = Callable()         # pruebas: (method, path, body) -> ApiResult
## Corrutina: var r: ApiResult = await api.call_api(HTTPClient.METHOD_POST, "/v1/sessions", {…}, false)
## Un solo refresco en vuelo: las llamadas que lo necesitan esperan su resultado (señal interna refreshed).
func call_api(method: HTTPClient.Method, path: String, body: Variant = null, auth: bool = true) -> ApiResult
# scripts/client/platform/api_result.gd y account_session.gd
class_name ApiResult extends RefCounted
var ok: bool; var status: int; var data: Dictionary; var code: String; var message: String; var retry_after_s: int
class_name AccountSession extends RefCounted
var access_token: String; var refresh_token: String; var access_expires_msec: int; var account: Dictionary
func needs_refresh(now_msec: int) -> bool       # a 60 s de caducar
func clear() -> void
# scripts/client/platform/account_flow.gd
class_name AccountFlow extends RefCounted
func _init(api: PlatformApi) -> void
func login(email: String, password: String) -> ApiResult                  # corrutina; guarda la AccountSession
func ensure_character(world_id: int, name: String, realm: StringName) -> ApiResult   # data.character; lo crea si falta
func enter(character_id: int, base: ClientConfig) -> ApiResult            # data.config: ClientConfig con billete
```

## 15. Pruebas

Cada prueba, menos de 30 s (Go con la caché caliente), salvo las de P10 (abajo). Go: `cd platform && go test ./...`;
Godot: el ejecutor de siempre, que falla ante cualquier error del motor. El reloj de Go es inyectable (`clock.Now`)
para los plazos.

| Paquete | Pruebas |
|---|---|
| P0 | `migrate`: up, down hasta la irreversible y up con el esquema igual; una irreversible no baja; conservación con las semillas; suma alterada → error; dos ejecutores a la vez (bloqueo). `config`: variable que falta → no arranca; clave de billete de 31 B → no arranca; la del vector fuera de `test` → no arranca; `MIN_PROTOCOL` ausente en `production` → no arranca. `/ready` con la base parada → 503. `jsonx`: `4.0` vale, `4.5` y un id sin comillas no |
| P1 | Contraseña buena, mala y correo inexistente (mismo código y cuerpo); 5 fallos desde la IP B → 429 en B y el dueño entra desde A; los fallos por `/v1/account/password` cuentan igual (el sexto → 429); suspendida con contraseña mala → `invalid_credentials`, con buena → `account_suspended`; 11 intentos por IP → 429; el registro con un correo existente, uno sancionado y uno nuevo da el mismo cuerpo (y su correo en `outbound_mail`); acceso caducado → 401 y refresco; reutilizar el refresco anterior → sesión revocada; uno de hace dos rotaciones → 401 sin revocar; los 12 h no se alargan al rotar; segunda sesión revoca la primera; enlaces caducados y usados; tras cambiar la contraseña o el correo, el enlace de recuperación anterior falla y el `revert_email` sigue valiendo; `revert_email` devuelve el correo y obliga a recuperar; exportar sin contraseña → 400; un correo con `\r\nBcc:` → 400 `validation`; `X-Forwarded-For: 1.2.3.4` y `X-Real-IP` desde un origen no fiable no cambian la IP del límite; el formulario de `/verify` enviado como un navegador (`application/x-www-form-urlencoded`, sin cabeceras de `/v1`) verifica; `/verify?token=<script>` no lo repite; borrado y cancelación en plazo; cuenta sin verificar purgada a los 7 días (reloj); `needsRehash` |
| P2 | `names` con `tests/data/name_rules_cases.json` y `test_progression_rules_export.gd` (Godot); dos creaciones simultáneas del mismo nombre (una `name_taken`); «Anéira» frente a «ANEIRA» y «Aneira» (`name_taken` por tildes y mayúsculas); reino bloqueado; huecos (un borrado en plazo ocupa); el sexto personaje creado en un día → 429; crear y borrar enseguida libera el nombre en `restore_until`; plantilla y raza de otro reino → 400; borrar, restaurar y nombre reservado; `enter` sin zona viva → 503; `enter` elige la última zona si admite el reino; vector del billete de §5.1 |
| P3 | El token de `1:vado_gris:0` no registra `vado_gris:1` ni un host fuera de la lista, ni late por otra instancia (403); registro sin `replace` con la vieja latiendo → 409 `instance_alive`; con `replace` → `replaced` y fila en la auditoría; la sustituida manda su guardado final y vale; instancia `lost` que late → 409 `instance_lost`; latido con un `lease_id` viejo → `revoked` `lease_lost` y sin renovar; reclamación a una `starting` → `instance_not_live`; billete consumido, caducado, de otra instancia y de sesión revocada (no queda consumido); `character_busy` no consume el billete; refrescar la sesión con el personaje arrendado no lo pone en `revoked`; dos zonas a la vez (una gana); libre a los 15 s sin latido (plazos cortos); `seq`: plazo vencido con el commit tardío y reintento → `duplicate`, y el siguiente se aplica sin fallar S3; mismo `seq` con otro cuerpo → `seq_conflict`; `seq` menor → `stale_seq`; ajeno → `lease_lost`; tardío tras liberar (vale) y tras otra reclamación (no vale); `invalid_save` del falso → nada escrito; un guardado con `"kills": 4.0` se aplica; registro sin certificado en `staging` → 400; PUT de fortaleza con `expected_version` viejo → `version_conflict`; 100 guardados concurrentes del mismo personaje: `save_version` = aplicados |
| P3b | S1–S9 con los casos de `tests/fixtures/progression/`; crear, guardar, recargar y comparar campo a campo; **dos guardados a la vez de dos personajes con el mismo `uid`: uno falla y nada se duplica**; un `uid` u `op_id` fuera de los bloques de la instancia → 400; intercambio de ranuras con la restricción diferida; purga de un personaje con kit de inicio y apuntes → lápida, sin objetos y con el libro; la retención al año (reloj) borra libro, operaciones y lápida; un `delete` del libro sin la marca falla; rutas de operación y libro |
| P4 | `test_handoff_ticket.gd`: vector, firma alterada, clave desconocida, otra zona, caducado, desfase de 5 s, reutilizado; `test_net_messages`: REJECT 10–12 y bit GM; `test_zone_server_platform.gd` con `FakeZonePlatform` y ENet real: billete → `VERIFYING` → WELCOME; sin billete → `TICKET`; **cupo de 4 con 5 en `VERIFYING` → `FULL`**; HELLO retrasado 1,4 s con `GuardedEnetPeer` y reclamación a 5 s → WELCOME (`auth_timeout` de 10 s); plataforma muda → `UNAVAILABLE` a los 7 s (reloj real); zona cercada → `UNAVAILABLE`; peer que se va en `VERIFYING` → liberación; `BUSY` y `BANNED` con su texto; `--platform --debug-commands` con `env = production` → la zona sale; `ClaimedCharacter.from_claim` con un `ticket_id` y un `character_id` > 2^53 en ida y vuelta. `test_platform_client.gd` con `FakeHttpServer` (TCPServer en el mismo proceso, respuestas y retrasos guionizados): plazo vencido y reintento con los mismos bytes; la reclamación no se reintenta; **un latido no espera detrás de 4 guardados lentos**; una reclamación sale aunque haya 4 guardados en vuelo; orden por prioridad |
| P5 | Con el falso (que hace `JSON.stringify` y `parse_string` de ida y vuelta): punto de control (intervalo de prueba de 120 ticks), fases repartidas, crítico al instante, una escritura en vuelo, el final espera detrás de la que vuela, `duplicate` cuenta como aplicado, `invalid_save` expulsa y libera sin guardar, `lease_lost` expulsa sin liberar, `instance_lost` cierra la zona con guardados finales, salida en combate guarda al irse el cuerpo, muerto se guarda para reaparecer, **el cierre ordenado espera** con el falso contestando a los 2 s (con cada uno de los cinco disparadores), cercado rechaza un `item_give`; la reconexión conserva `pvp` |
| P6 | Ida y vuelta de `FortressPersistence` (ticks ↔ Unix con reloj fijo); arrancar con `CONSOLIDATING` a medias conserva dueño y plazo; `CAPTURING` vuelve como `VULNERABLE`; **plataforma caída al arrancar: el puerto no se abre y el dueño guardado no se pisa**; lista vacía → estado inicial sin aviso; `version_conflict` → reenvío con la versión nueva; capturas y `defend_ticks` (solo el dueño); el final se construye antes de `ScoreKeeper.forget`; lote de eventos reenviado sin duplicar |
| P7a | Un moderador que pide `ban` → 403 y fila `sanction_denied`; un GM no sanciona a un admin; sancionar sin arrendamiento en la instancia → 403; caducidad de cada tipo de sanción (aviso, silencio, suspensión, expulsión, renombrado) con el reloj inyectado; `set-role` revoca las sesiones y el latido expulsa (≤ 5 s); `admin reports show` sin `--actor` → error, y con él, fila en la auditoría; `admin chat` entre dos fechas y lo caducado desaparece |
| P7b | Sin rol → «Comando desconocido»; DEBUG_COMMAND 40 sin rol → aviso, ni objeto ni guardado; un GM invisible no hace daño, no lo recibe y no cuenta en el círculo ni en el marcador; `item_give` sobre un personaje propio → rechazado en `production`; un ignorado no susurra, no invita ni llega a su canal de zona; reporte con prueba y límite de 1 cada 10 min; silencio con su tiempo restante; renombrado forzado |
| P8 | `test_client_config`: modos y prioridad, `--dtls-*`; `PlatformApi` con `request_hook` (refresco ante 401; dos llamadas que caducan a la vez hacen un solo refresco; mapa de errores); `AccountFlow` con `request_hook` (login, crear si falta, enter → `ClientConfig` con billete); `--bot --platform` sin `--login` → código 1; pantallas con datos falsos (nombre, borrado escribiendo el nombre, Entrar desactivado sin personaje, plantilla); `NetClient` pone el billete en el HELLO |
| P9a | Exportación con todas las secciones; la purga deja las lápidas; las retenciones borran lo caducado y nada más; una copia tomada antes de purgar, restaurada y con `reapply-purges`, deja la lápida; purgar una cuenta suspendida y registrar el mismo correo → no se crea la cuenta |
| P9b | `restore_check.sh` sobre una copia de la base de prueba con `purges.txt`; `docker compose config -q`; la comprobación de secretos de la CI con un `staging.env` de prueba en el índice → falla |
| P9c | Loopback con DTLS y `GuardedEnetPeer` (servidor y cliente en un proceso, cierre limpio sin errores del motor); `SwarmBot` con certificado |
| P10 | Abajo |

**P10, extremo a extremo** (`go test -tags e2e ./e2e`):

- **Arnés.** `ELDMARK_GODOT` (ruta del ejecutable de Godot 4.7.2; si falta, `t.Skip`). `TestMain` hace una vez
  `godot --headless --path .. --import` (con LFS ya bajado). Plataforma en el proceso de la prueba, PostgreSQL
  efímero (§2.6), `ELDMARK_HEARTBEAT_S=1` y `ELDMARK_LEASE_TTL_S=6`.
- **`TestEnterAndSave`:** `test_world` con `--platform`, un `--bot` con cuenta: entra, guarda, sale; `save_version
  > 0` y `character_progress.saved_at` puesto.
- **`TestZoneCrash`:** `--save-interval=5`; se espera a un `saved_at`, se apunta la hora y `kill -9` a la zona. Se
  arranca otra instancia (se registra cuando la vieja pasa a `lost`, a los 3 s) y **un segundo proceso `--bot`** con
  la misma cuenta entra en ella. Comprueba: `kill − saved_at < 5 s + 1 s de margen` y que el personaje está en la
  instancia nueva. El primer bot no hace falta que reconecte.
- **CI:** trabajo «Plataforma e2e» en `tests.yml`, que reutiliza la caché de Godot y de LFS del trabajo de Godot y
  exporta `ELDMARK_GODOT`.
- **Tiempo: sin medir.** Dos arranques de zona y uno o dos de bot: la meta es < 30 s por prueba. Si P10 mide más,
  el tope de P10 sube a 60 s y se anota aquí y en la entrada del backlog.

**Revisión visual de UI-22 a UI-24 (usuario).** Contra `deploy/dev.sh`: el título arranca con el estado y las
noticias; se crea una cuenta y se inicia sesión; se crean dos personajes (reino, apariencia, plantilla y nombre con
un error de nombre a la vista); la vista 3D de la selección cambia al elegir; se borra uno escribiendo el nombre y se
restaura; se entra en el mundo con la apariencia elegida y otro cliente la ve igual; un REJECT vuelve a la selección
con su texto.

## 16. Riesgos

| Riesgo | Mitigación |
|---|---|
| Relojes de zona y plataforma desfasados (billetes de 10 s) | `now_unix` en cada respuesta, 5 s de margen y aviso a partir de 2 s |
| Partición entre zona y plataforma con el cliente llegando a las dos: el personaje entra en otra zona | Cercado a los 10 s (nadie nuevo entra); a los 15 s, `lost`; al volver, la vieja se cierra y sus guardados finales solo valen para quien nadie reclamó; se pierde lo jugado allí por quien entró en otra. Raro en un mismo centro de datos; se revisa con TEC-29 |
| `HTTPRequest` en el servidor de zona: coste y orden de las señales | Colas por prioridad, plaza propia del latido, lotes, resultados solo en «poll»; `ServerMetrics` mide la sección `platform`; `FakeHttpServer` lo prueba de verdad |
| Un fallo de TLS registra un ERROR del motor | Ninguna prueba de Godot lo provoca (§10.1); TLS se prueba en Go |
| DTLS con `GuardedEnetPeer` y `SceneMultiplayer`, y su coste, sin comprobar | P9c lo prueba en un proceso; TEC-27 lo mide con el criterio relativo de §10.2; sin DTLS no hay pruebas públicas (la plataforma lo impone) |
| Versiones de Go y PostgreSQL de la CI (`ubuntu-latest`, sin comprobar) | Versiones fijas y `GOTOOLCHAIN=local` (§2.2); `ELDMARK_REQUIRE_PG=1` hace evidente que falta PostgreSQL |
| Una sola instancia de la plataforma (punto único de fallo; límites y fallos de contraseña en memoria) | Vale para pruebas cerradas; quien juega sigue si cae (§7.4); reiniciar la plataforma reinicia los contadores. Varias instancias con TEC-38 |
| progresion.md y este documento se escriben a la vez | Frontera única (§7.5) y lista de cambios para progresion.md (§17); migraciones de P3b; si allí se elige otro nombre, se cambia aquí y en las pruebas al integrar |
| Una zona comprometida (Godot recibe UDP de Internet) | Token con alcance, `public_host` de una lista, autorización de sanciones en la plataforma, ids solo de sus bloques, S1–S9 en Go |
| Textos legales, edad, retenciones (libro, correos sancionados) y exportación | Borradores marcados; revisión humana antes de cualquier prueba pública |
| `zone_server.gd` lo tocan P4, P5, P6 y P7b (y la fase 4 aún lo cambia) | Orden fijo y pasos del tick con nombre (§14.3) |
| P10 puede pasar de 30 s | Se mide; si pasa, tope explícito de 60 s (§15) |

## 17. Interfaz con progresion.md

Lo que progresion.md tiene que adoptar para que haya una sola tubería. Hasta que lo haga, manda esta tabla; los
nombres de allí que no se citan aquí se quedan como están.

| # | progresion.md | Cambio | Hallazgo (§18) |
|---|---|---|---|
| 1 | §3.2 I12, §3.3 (`last_save_id`), §9.2, §9.3, §13 S2 | Idempotencia por `(lease_id, seq)` (§7.3): fuera `save_id`, `base_version`, `last_save_id` y `VERSION_CONFLICT`. `save_version` sigue como contador que devuelve la plataforma. Un guardado enviado se reintenta byte a byte; `duplicate` = aplicado. S2 pasa a ser el paso 3 de §7.3 | PL-SEG1, PL-COH1, PL-IMP1, PL-IMP2 |
| 2 | §9.1 | El registro llega en la reclamación, antes del WELCOME, y el WELCOME lleva el reino del personaje (no el del billete). `begin_load(peer_id, character_id, lease_id)`: `lease_token` pasa a `lease_id`; con plataforma, `PlatformProgressRepository` lo entrega en el `poll` siguiente | PL-COH1, PL-IMP1 |
| 3 | §9.2 | Cuándo se guarda lo decide `CharacterSaver` (§7.2): fuera `next_checkpoint_tick`, «32 por zona» y los reintentos de 30 s. `ProgressService` llama a `CharacterSaver.mark_critical` en sus críticos y da la sección `&"progress"` (`build`: `{record, ops}` con las `ops` no enviadas; `acknowledge(net_id, save_version)` las saca del diario; `is_dirty`, que cuenta moverse y la vida). `on_departure` no guarda: lo hace `finish` | PL-COH1, PL-IMP1 |
| 4 | §9.3 | El cuerpo es el de §7.3: añade `zone_instance_id`, `lease_id`, `seq` y `pvp`; `reason` 5 = expulsión; `release_lease` igual | PL-COH1 |
| 5 | §9.4, §14.2 `ProgressRepository` | `save_character(character_id: int, body: PackedByteArray) -> int` (cuerpo ya serializado); `Result` sin `VERSION_CONFLICT`; `character_saved(request_id, result, save_version)` da `OK` también con `duplicate`. `PlatformProgressRepository` lo hace P5 de este documento; Memory y File aplican la misma regla de `seq` | PL-COH1, PL-IMP1 |
| 6 | §14.2 `CharacterRecord.from_dictionary` | Convierte con `int()` cada entero y con `String.to_int()` cada id en cadena: Godot lee todo número como `float` y lo reescribe como `820.0` | PL-IMP3 |
| 7 | §3.4, §0 | Ids como cadena en las dos API, también `account_id` y `actor_account_id` (§4.1) | PL-COH14 |
| 8 | §4.5, §13 #4 | Bloques: `POST /internal/v1/id-blocks` → `{"first": "1025", "count": 1024}` de `uid_block_seq`; la plataforma apunta el bloque en `id_blocks` y rechaza ids nuevos fuera de los bloques de la instancia (400) | PL-SEG1, PL-COH2 |
| 9 | §13 #1, §14.1 P7 | Las tablas las escribe P3b de este documento (0010_progress, §3): sin `last_save_id`; `economy_ops`, `ledger_entries`, `item_events` y `op_reversals` sin cascada y con `eldmark_append_only`, que solo deja borrar con `eldmark.retention_purge`; `progress_purge_character`. Su P7 es P3b | PL-COH2, PL-COH3, PL-IMP2 |
| 10 | §13 #8 | Retención: el personaje purgado queda como lápida y el libro y los eventos de objeto, 1 año tras la purga; luego se borran (§11.1, revisión legal) | PL-COH3 |
| 11 | §13 #6, §14.1 P3 | Un solo archivo de datos: `platform/internal/gamedata/progression_rules.json` (no `data/generated/`: `go:embed` no lee fuera de `platform/`), con las secciones `protocol_version` y `names` además de las suyas; lo crea el primero de los dos paquetes que llegue | PL-COH6, PL-IMP2 |
| 12 | §1, §8 | CMB-30 es suyo (habilidades.md lo deja fuera, §9 de ese documento). Su regla de posición y vida es la única; aquí se cita (§7.1) | PL-COH4, PL-COH5 |
| 13 | §8 «Traspasos» | El billete tiene 52 B (§5.1) | PL-COH12 |
| 14 | §10 | DEBUG_COMMAND 40–43 con plataforma solo en `dev` y `test` y con rol `gm`; los comandos que cambian algo no valen sobre personajes de la propia cuenta salvo `admin`; `inv_show`, `ledger_show` y `op_show` se auditan (§9.1) | PL-SEG2, PL-SEG11 |
| 15 | §6.2 y recompensas | El GM invisible no recibe méritos, XP ni oro (§9.1) | PL-SEG11 |
| 16 | §12 | Una sola subida de `PROTOCOL_VERSION` para la fase 5, compartida, que incluye `AUTH_TIMEOUT_SECONDS` = 10 (§5.4) | PL-COH13, PL-IMP4 |
| 17 | §14.1 P8 | «`PlatformProgressRepository` con TEC-25» pasa a P5 de este documento; la prueba de duplicados con PostgreSQL es de P3b | PL-IMP9, PL-IMP13 |

## 18. Revisión

Tres revisores (seguridad, coherencia e implementabilidad) presentaron 45 hallazgos sobre la versión 0f6781b.
Comprobados en el código y en los documentos, todos se sostienen; las sondas de la revisión están en
`build/probe_rev/` (Godot: `auth_timeout` con `GuardedEnetPeer` y JSON; Go: `jsonx`; PostgreSQL: el esquema entero,
la lápida, el disparador, la reclamación y el latido; git: el `.gitignore`). Lo que pide cambios en progresion.md
está en §17.

| Id | Gravedad | Qué era | Qué se hizo |
|---|---|---|---|
| PL-SEG1 | bloqueante | Dos contratos de idempotencia incompatibles (`(lease_id, seq)` aquí, `save_id` + `base_version` allí); `duplicate`, 400 y reintentos sin definir; dos fuentes de ids | Un contrato (§7.3): cuerpo inmutable reintentado byte a byte, `duplicate` = aplicado, `stale_seq`, `seq_conflict` con hash, `invalid_save` definitivo con `release`; bloques de la secuencia de 1024 con `first` en cadena (§6); prueba en P3. progresion.md, §17 #1 y #8 |
| PL-SEG2 | importante | Con plataforma se podían usar `--debug-commands`, `--fake-players` y sin DTLS; DEBUG_COMMAND sin rol; clave de prueba válida | `env` en el registro y salida de la zona fuera de `dev`/`test` (§5.5); DEBUG_COMMAND con `min_role` (§9.1); registro sin certificado → 400 en staging y producción (§6); claves de < 32 B y la del vector rechazadas (§2.3); pruebas en P0 y P4 |
| PL-SEG3 | importante | Un token común abría toda la API interna; registro de cualquier zona y host; la sustituida «sin guardar» contradecía §5.3 | Token por despliegue con alcance y hashes, `ELDMARK_ZONE_HOSTS`, `zone_instance_id` comprobado, `claimed_by`, `replace` con auditoría, guardados finales de la sustituida (§5.3, §6, §6.1); pruebas en P3 |
| PL-SEG4 | importante | Sin definir qué pasa con una instancia `lost` que vuelve; latido sin filtro por `lease_id`; latido en la cola común | Latido con `(character_id, lease_id)` y SQL (§5.3, comprobado), `instance_lost` y cierre (§6.1), cercado a los 10 s, plaza propia del latido (§6). Matiz: el cercado rechaza las operaciones que piden guardado crítico, no los guardados, que siguen saliendo |
| PL-SEG5 | importante | La rotación del refresco con `family` expulsaba en el primer refresco; 12 h sin fijar; la SQL de la reclamación no miraba la sesión | Una fila por sesión rotada en el sitio con `prev_refresh_hash`, 12 h absolutos, un refresco a la vez en `PlatformApi`, reclamación con `join` a `sessions` y rollback sin arrendamiento (§3, §4.2, §5.3; comprobado); pruebas en P1, P3 y P8 |
| PL-SEG6 | importante | La plataforma creaba la sanción sin comprobar el rol ni la zona; bajar de rol no quitaba el poder | Cuerpos con `zone_instance_id` y `world_id`; autorización en tres pasos y `sanction_denied` (§9.5); `set-role` revoca las sesiones (§9.1); pruebas en P7a |
| PL-SEG7 | importante | Rutas con contraseña sin límite; cambios que no invalidaban enlaces; aviso al correo viejo sin vuelta atrás; exportar solo con el token | `CheckPassword` común, invalidación en la transacción (salvo `revert_email`), `revert_email` de 7 días, exportar con contraseña (§4.2, §4.3); pruebas en P1 |
| PL-SEG8 | importante | `email_taken` y `account_locked` delataban cuentas; el bloqueo por cuenta era un arma; sanciones antes de la contraseña; cuentas sin verificar eternas | Registro y cambio de correo siempre 202; fallos por cuenta y grupo de IP con freno en las demás y 429; estados solo tras una contraseña buena; correo de aviso; purga a los 7 días sin verificar (§4.1–§4.3, §11.1); pruebas en P1 |
| PL-SEG9 | importante | Copias, WAL y registros guardaban datos purgados sin plazo | `purge_log`, `purges.txt` y `reapply-purges` (§11.2, §12); filas de copias, WAL y registros en §11.1; journald a 30 días; Caddy sin registro de accesos; sin `--battle-log` y similares en staging y producción; prueba en P9a |
| PL-SEG10 | importante | El `.gitignore` solo ignoraba `.env` (comprobado) | Patrones nuevos en P0 (comprobados en un repositorio de prueba), secretos desde `secrets/` y comprobación en la CI (§10.3); prueba en P9b |
| PL-SEG11 | importante | GM invisible que pegaba y capturaba; comandos sobre los propios personajes; CLI sin identidad; lecturas sin auditar | Invisible sin daño, sin círculo, sin marcador ni recompensas; regla de los propios personajes; `--actor` obligatorio; lecturas auditadas (§9.1); pruebas en P7a y P7b. progresion.md, §17 #14 y #15 |
| PL-SEG12 | importante | Reservar nombres sin límite creando y borrando | 5 creaciones y 5 borrados por cuenta y día, los borrados en plazo ocupan hueco y los personajes de prueba no reservan 30 días más (§4.2, §4.4); pruebas en P2 |
| PL-SEG13 | menor | `X-Forwarded-For` sin regla clara | Solo `X-Real-IP` desde `ELDMARK_TRUSTED_PROXIES`, puesto por Caddy (§4.2, §10.1); prueba en P1 |
| PL-SEG14 | menor | Correo con CR/LF (inyección de cabeceras) y páginas con el token sin escapar ni cabeceras | Validación estricta y `mime.QEncoding` (§4.2); `html/template`, token validado y cuatro cabeceras (§4.3); pruebas en P1 |
| PL-SEG15 | menor | La supresión borraba la reincidencia | `sanctioned_email_hashes` con HMAC y clave propia, consultada en el registro, con revisión legal (§2.3, §3, §11.1, §11.2); prueba en P9a |
| PL-COH1 | bloqueante | Dos tuberías de carga y guardado, y dos `class_name CharacterRecord` | Una tubería: la reclamación trae el registro, `CharacterSaver` con secciones sobre `ProgressRepository`, `ClaimedCharacter` aquí, una tabla de errores (§6.1, §7.3, §7.5); `PlatformProgressRepository` pasa a P5. progresion.md, §17 #1–#5 |
| PL-COH2 | bloqueante | El mismo dato en dos esquemas; dos fuentes de `uid`; nadie escribía las migraciones del progreso | Tabla «quién guarda qué» (§3); `characters` solo identidad, sin JSON de estado; una sola fuente de ids (§6); P3b con 0010_progress (DDL comprobado), S3–S9 y las rutas de operación y libro (§14.1). progresion.md, §17 #8 y #9 |
| PL-COH3 | bloqueante | La purga en cascada chocaba con el disparador del libro (comprobado por el revisor) | Lápida sin cascada en las tablas de solo añadir, disparador con `set local eldmark.retention_purge`, retención de 1 año y `progress_purge_character` (§3, §11.1, §11.2; comprobado); prueba en P3b. progresion.md, §17 #10 |
| PL-COH4 | importante | CMB-30 asignado a habilidades.md, que lo deja fuera | Quitados `state.combat` y la frontera con habilidades.md; CMB-30 es de progresion.md §8 (introducción, §7.1, §16) |
| PL-COH5 | importante | Dos reglas de volver al mundo y dos campos de última zona | La de progresion.md §8, citada en §7.1 y marcada provisional (§0); `enter` lee `character_progress.last_zone_id` (§4.5) |
| PL-COH6 | importante | Creación incompatible: id de raza, dos generadores, sin plantilla, `Create` sin datos | Ids `race_<reino>`, un solo archivo y una herramienta, `starter_template_id` en la ruta y en UI-24, `CreateParams`, apariencia de 8 B (§4.4, §7.5, §13.2). progresion.md, §17 #11 |
| PL-COH7 | importante | Rotación del refresco contra el arrendamiento atado a la sesión | Igual que PL-SEG5 (la sesión no cambia de fila); prueba en P3 |
| PL-COH8 | importante | `VERIFYING` fuera del cupo; reclamaciones detrás de los guardados; `auth_timeout` contado desde la conexión | `VERIFYING` cuenta y `FULL` se mira al 200; plazas para la entrada; `auth_timeout` de 10 s y plazo de 7 s en tiempo real (§5.2, §6; comprobado); pruebas en P4 |
| PL-COH9 | importante | Arranque sin plataforma que pisaba el dueño; registro antes del puerto; reinos sin guardar | Orden fijo con `starting` y `live`, GET con reintentos que distingue vacío de mudo, `expected_version`, `realms` en el registro (§3, §6, §8); prueba en P6 |
| PL-COH10 | importante | `flush_and_wait` síncrono imposible; el cierre de hoy no espera; disparadores incompletos | `begin_flush` e `is_flushed`, `_drain_stop` hasta 600 ticks y `SHUTDOWN_MAX_FRAMES` 720, los cinco disparadores (§7.2, §14.3); prueba en P5 |
| PL-COH11 | importante | Nadie hacía el inicio de sesión del bot con cuenta | `AccountFlow` sin interfaz, que usan `FrontMain` y el bot; `--bot --platform` sin `--login` sale con código 1 (§5.5, §13.3, §14.4); pruebas en P8 |
| PL-COH12 | importante | Criterios y reglas de otros documentos sin tocar | backlog: TEC-24 (reino del personaje), TEC-27 (criterio provisional), SOC-16 (filtro en el servidor) y «pendiente del usuario»; red.md §12 y §17 (billete de 52 B, `PENDING`); social.md §0, §8 y §10. progresion.md, §17 #2 y #13 |
| PL-COH13 | menor | La versión 5 ya era del chat (y la 6 de habilidades.md); dos subidas en la fase 5 | Una sola subida compartida, la siguiente libre (hoy 7) (§5.4); `ELDMARK_MIN_PROTOCOL` obligatoria en staging y producción (§2.3). progresion.md, §17 #16 |
| PL-COH14 | menor | `ticket_id` de 63 bits como número JSON | Todo id `bigint` como cadena en las dos API (§4.1; comprobado en Godot); prueba de ida y vuelta en P4. progresion.md, §17 #7 |
| PL-COH15 | menor | `ScoreKeeper` no tenía capturas ni tiempo defendiendo; orden frente a `forget` | `captures` y `defend_ticks` con quién y cuándo, sección `pvp`, `finish` antes de `forget` (§8); pruebas en P6 |
| PL-IMP1 | bloqueante | El mismo tramo de la zona definido dos veces (clase, carga, guardado, CMB-30) | Igual que PL-COH1 y PL-COH4: frontera de §7.5 y §17 |
| PL-IMP2 | bloqueante | Contrato Go y esquema que no casaban; migraciones sin dueño; purga imposible | Igual que PL-SEG1, PL-COH2, PL-COH3, PL-COH6 y PL-COH14: `CreateParams`, `Apply` con tipos de progresion.md, una fuente de ids, cadenas, un generador, lápida y P3b (§3, §7.5, §14.1) |
| PL-IMP3 | importante | Godot reescribe `820.0` y Go lo rechaza en un `int` (comprobado) | `jsonx.Int` y `jsonx.ID` en Go; `int()` y `to_int()` al leer en GDScript; el falso hace ida y vuelta por JSON (§4.1, §14.3); pruebas en P0, P3 y P5. progresion.md, §17 #6 |
| PL-IMP4 | importante | El plazo de 240 ticks no cabía en el `auth_timeout` contado desde la conexión | Comprobado con `GuardedEnetPeer`: 10 s en los dos lados y plazo de 7 s en tiempo real (§5.2, §5.4); prueba con el HELLO a 1,4 s en P4 |
| PL-IMP5 | importante | Cola de `PlatformClient` sin prioridades ni reglas; PUT de fortaleza sin versión; arranque mudo; sin prueba del HTTP real | Tabla de prioridades y reintentos (§6), una en vuelo por fortaleza con `expected_version` y arranque de §8; `FakeHttpServer` en P4 |
| PL-IMP6 | importante | Igual que PL-SEG5 y PL-COH7 | Igual que PL-SEG5 |
| PL-IMP7 | importante | Máquina de estados de la instancia incompleta | Orden fijo de comprobaciones y tabla por estado y petición (§6.1); `lost` que vuelve se cierra; pruebas en P3 |
| PL-IMP8 | importante | `AuthProvider` sin entrada para la reclamación; cupo; falso sin herencia; cómo llega `ZonePlatform`; clase en otro paquete | `on_platform_event`, `get_player_count` con `VERIFYING`, `FakeZonePlatform extends ZonePlatform`, `ZoneServer.start(…, platform)`, `ClaimedCharacter` en P4 (§14.1, §14.3) |
| PL-IMP9 | importante | Pruebas que no demostraban su criterio | Duplicados en P3b con tablas reales; `saved_at` para medir la pérdida; «ANEIRA» y «Aneira»; reconexión con `pvp` en P5 y caducidad de cada sanción en P7a (§15). progresion.md, §17 #17 |
| PL-IMP10 | importante | `TestZoneCrash` no se podía ejecutar | Arnés con `ELDMARK_GODOT` e importación en `TestMain`, trabajo de CI, segundo proceso `--bot`, `saved_at` frente a la hora del `kill`, tope de tiempo explícito si pasa de 30 s (§15) |
| PL-IMP11 | importante | TEC-27 no se podía medir; `NetTransport` sin contrato DTLS; criterio cambiado sin marcarlo | `host` y `connect_to` con `TLSOptions`, `--dtls-*` en `--connect`, `--bot` y `--bots` (§10.2, §13.3); criterio provisional con pregunta al usuario en §0 y en el backlog; P9c |
| PL-IMP12 | importante | Vuelta atrás con `down` que borraba datos | `down` solo en desarrollo y CI, irreversibles marcadas, expandir y contraer, prueba de conservación (§2.4, §12) |
| PL-IMP13 | importante | Dependencias que faltaban y paquetes demasiado grandes | `ClaimedCharacter` en P4; P6 y P7b dependen de P5; P7 en P7a y P7b; P9 en P9a, P9b y P9c (P9c sin TEC-20); P3b nuevo (§14.1) |
| PL-IMP14 | menor | Los formularios de los correos no podían usar `/v1` | `GET` y `POST` urlencoded en `/verify`, `/reset` y `/revert`, fuera de `/v1` y sin el 426 (§4.1, §4.3); prueba en P1 |
| PL-IMP15 | menor | Faltaban pendientes del usuario | SMTP y DNS, revisión visual de UI-22 a UI-24 con lista y criterio de TEC-27 en §0 y en el backlog; lista de comprobación en §15 |
