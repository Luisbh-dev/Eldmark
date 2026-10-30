# Eldmark · Fase 5: diseño de la plataforma

Diseño del paso 5 de la [hoja de ruta](vision.md#hoja-de-ruta): cuentas, personajes y guardado en base de datos.
Cubre el servicio de plataforma y todo lo que pasa por él: TEC-22 a TEC-25, TEC-27, TEC-28, TEC-41, TEC-43, PRG-41,
SOC-13 a SOC-18, GUE-19 y el cliente de UI-22 a UI-24.

Se apoya en la red ([red.md](red.md): §3 conexión, §5.3 autenticación, §12 seguridad, §15 extensión, §17 contratos),
el combate ([combate.md](combate.md) §1 y §5), el fuerte ([fuerte.md](fuerte.md) §5) y lo social
([social.md](social.md) §8 a §11). Objetos, inventario, monedas, niveles, razas, apariencia y la configuración de
combate que se guarda (CMB-30) son de `docs/progresion.md` (PRG-02, PRG-10 a PRG-16, CMB-30, ART-19, en marcha a la
vez). Aquí está la frontera (§7.5); lo acordado con ese documento y dónde está cada regla, en §17. Revisado tras tres
revisiones y conciliado después con progresion.md (§18).

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
| Retención del chat | **30 días** todos los canales, susurros incluidos; **1 año** lo copiado a un reporte (`report_evidence`, §11.1). Revisión legal antes de las pruebas públicas |

Decisiones de este documento que no estaban en el backlog (provisionales, de noche):

| Pregunta | Decisión |
|---|---|
| Inicio de sesión | Correo y contraseña; una sesión de juego activa por cuenta (la nueva cierra la anterior y expulsa a su personaje) y un solo personaje en el mundo por cuenta y mundo (§4.5, §5.3). Una cuenta suspendida o expulsada solo recibe, tras la contraseña, una sesión de privacidad para exportar o borrar sus datos (§4.2) |
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
| Frontera con progresion.md | **Una sola tubería.** La reclamación trae la sección `progress` (progresion.md §3.4) antes del WELCOME. `CharacterSaver` (TEC-25, aquí) decide cuándo se guarda; `ProgressService` (progresion.md) decide qué. Idempotencia por `(lease_id, seq)`, sin `save_id` ni `base_version` (§7.3, §7.5, §17) |
| Volver al mundo | **La regla es la de progresion.md §8.** Está también en «Decisiones tomadas» del backlog |
| Criterio de TEC-27 | **Relativo**: con 64 bots, DTLS no sube el p99 del tick más de un 10 % frente a la misma prueba sin DTLS, y la cifra absoluta se anota. El absoluto del backlog (8 ms) no se cumple ni sin DTLS (15,9 ms, red.md §14). **Pregunta para el usuario**; está en «Decisiones tomadas» del backlog |
| Libro mayor tras borrar | El personaje purgado queda como **lápida** sin nombre; su libro y sus eventos de objeto, 1 año más y luego se borran (§11.1). Mientras la cuenta exista siguen ligados a ella y se exportan; son seudónimos solo tras purgarla. **Revisión legal** |
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
| Raza, apariencia y plantilla de inicio | progresion.md (qué valen); la plataforma las valida al crear (§4.4) | Con `progression_rules.json` y `persistence.CreateValidator`, que implementa `*progress.Rules` (§7.5, progresion.md §13.2) |
| A qué zona entra | Plataforma (`enter`) | La última (`ProgressStore.Summaries`) si tiene una instancia viva que admite su reino; si no, la de entrada |
| Si el billete vale | Zona (formato, firma, zona, caducidad) y plataforma (un solo uso, arrendamiento) | §5 |
| Estado del personaje en juego | Zona | La plataforma aplica lo que le mandan con las comprobaciones S1–S8 de progresion.md §13.3 (§7.3) |
| Cuándo se guarda, `seq`, reintentos | Zona: `CharacterSaver` (§7.2) | progresion.md da el contenido |
| Sanciones y roles | Plataforma | Comprueba el rol del autor (§9.5); la zona las aplica al entrar, con el latido y en `ChatRouter` |
| Estado de las fortalezas | Zona | La plataforma lo guarda y lo devuelve al arrancar (§8) |
| Esquema y migraciones | El marco, aquí (§2.4); las del progreso, progresion.md P7 | Las zonas no tienen credenciales de la base |

```
Cliente                         Plataforma                            Zona
                                 ◀── registro, fortalezas, bloque ───── antes de abrir el puerto
                                 ◀── …/live ─────────────────────────── puerto abierto
POST /v1/sessions ─────────────▶ sesión
POST /v1/characters/42/enter ──▶ sin arrendamiento vivo: billete
◀── host, puerto, billete (52 B), certificado DTLS
HELLO (character_id, billete) ────────────────────────────────────────▶ firma, zona, caducidad (VERIFYING)
                                ◀── POST /internal/v1/claims ──────────
                                consume el billete, arrendamiento ────▶ lease_id, cuenta, personaje y progress
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
             characters tickets zones persistence progress (progresion.md P7) war social privacy mail
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
| `ELDMARK_HEARTBEAT_S` · `ELDMARK_LEASE_TTL_S` | `5` · `30` | Una instancia sin latido durante 3 × `HEARTBEAT_S` se da por perdida; la zona se cerca a 2 × (§5.3). `LEASE_TTL_S` tiene que pasar de 3 × `HEARTBEAT_S` + min(5 s, `HEARTBEAT_S`) (20 s con los valores por defecto): si no, un arrendamiento caduca antes de que su instancia sin latido se dé por perdida |
| `ELDMARK_LEGAL_DIR` | `platform/legal` | Textos legales versionados |

**Registro:** `log/slog` con `JSONHandler` a la salida estándar. Campos: `time`, `level`, `msg`, `req` (id de
petición, también en `X-Request-Id`), `route`, `status`, `ms`, y `account` y `character` cuando se conocen.
**Nunca** se registran contraseñas, tokens, billetes, cuerpos ni texto del chat; el correo va enmascarado
(`a***@example.org`).

### 2.4 Migraciones
- `internal/migrate/migrations/NNNN_nombre.up.sql` y `.down.sql`, embebidos. En la fase 5, **0001–0006 son de este
  documento** (§3) y **0010_progress, del progreso** (progresion.md §3.3, su P7, con su `.down.sql` y su semilla);
  0007–0009 quedan sin usar. Después, cada migración nueva, sea de quien sea, toma el siguiente número libre por
  encima de la mayor del repositorio. Un número nunca se reutiliza.
- Tabla `schema_migrations (version int primary key, name text not null, checksum bytea not null, applied_at
  timestamptz not null default now())`. El ejecutor toma `pg_advisory_lock(4815162342)`, aplica los pendientes en
  orden de número, cada uno en su transacción, y se niega a seguir si el SHA-256 de uno aplicado ha cambiado o si
  hay uno pendiente por debajo del mayor aplicado («La migración NNNN está pendiente por debajo de la MMMM ya
  aplicada: renumérala»). `down N` deshace las N mayores aplicadas, en orden inverso.
- `eldmark-platform migrate up|down N|status`. `serve` no migra: si falta por aplicar alguno de sus archivos
  embebidos, no arranca y `/ready` dice por qué. Una base con migraciones posteriores sí vale (expandir y contraer,
  abajo).
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
  `live`, y `expires_at = greatest(expires_at, now() + TTL)` en sus arrendamientos que seguían vivos en el último
  latido (`expires_at ≥ last_heartbeat_at`, mirado antes de subirlo): uno que ya había caducado antes de la caída no
  resucita. Una plataforma que vuelve tras caerse no da por muertas a las zonas que no pudieron latir.
- Trabajos periódicos en el mismo proceso (`time.Ticker` y `pg_try_advisory_lock`): zonas perdidas (cada
  `min(5 s, HEARTBEAT_S)`),
  retenciones y purgas (1 h; la del libro, `ProgressStore.PurgeRetention`, progresion.md §3.5).

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
  immediate` y se borra la carpeta; si el proceso muere antes (un pánico, el plazo de `go test`, un Ctrl-C), lo hace
  un vigilante: un `sh` en su propio grupo de procesos que espera en una tubería y limpia al cerrarse. Sin binarios, `t.Skip`, salvo con `ELDMARK_REQUIRE_PG=1` (la CI), que falla;
  `ELDMARK_TEST_DATABASE_URL` usa un servidor ya levantado. La primera compilación con pgx tarda ~18 s: los < 30 s
  por paquete son con la caché caliente.
- Los esquemas de §3 (0001–0006) y del progreso (progresion.md §3.3) se aplicaron así en las revisiones: el
  intercambio de ranuras con la restricción diferida, la lápida, el disparador de solo añadir y la retención con
  `set local` funcionan (`build/probe_rev/pg/`).
- **CI:** trabajo «Plataforma» en `.github/workflows/tests.yml`: `actions/setup-go` con `go-version-file:
  platform/go.mod`, `GOTOOLCHAIN=local`, `ELDMARK_REQUIRE_PG=1` y, en `platform/`, `go vet ./...` y `go test -p 2
  ./...` con el PostgreSQL de `ubuntu-latest` (sin comprobar; si falta, `apt-get install postgresql-16`). El mismo
  trabajo comprueba los secretos (§10.3). El trabajo «Plataforma e2e» es de P10 (§15).

## 3. Esquema SQL

Las tablas del juego llevan `world_id` (`id_blocks` y las del progreso lo toman de `zone_instances` y de
`characters`); las de la cuenta, no. Reinos en `smallint` con los códigos de `NetProtocol.Realm` (1 Vardheim, 2
Solmarch, 3 Askarra); en JSON, la regla de §4.1 (texto en la API pública, código en la interna). `ts` abrevia aquí `timestamptz` y `now_ts`
`timestamptz not null default now()`; en los archivos van escritos enteros. Este DDL se aplicó entero en PostgreSQL
16 (§2.6), salvo `sessions.scope`, `chat_messages.zone_channel` y el índice `(target_account_id, command, at)` de
`audit_log`, añadidos después (sin comprobar).

**Quién guarda qué:** la tabla única, con todos los campos del personaje y su dueño, está en progresion.md §3.1. De
este documento son la identidad (`characters`), las estadísticas PvP (`character_pvp_stats`, GUE-19), el
arrendamiento (`character_leases`: `lease_id`, `seq`, hash y `save_version` del último guardado) y los bloques de ids (`id_blocks`);
de progresion.md, `character_progress` y el resto de `0010_progress` (su §3.3). No hay columnas JSON de estado del
personaje: lo que no tenga columna llega con una migración.

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
  scope text not null default 'game' check (scope in ('game','privacy')),          -- privacy: cuenta sancionada (§4.2)
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
  last_save_version bigint not null default 0,                                  -- el save_version que devolvió Apply (§7.3)
  claimed_at now_ts, released_at ts);
create index on character_leases (zone_instance_id) where zone_instance_id is not null;
create sequence uid_block_seq start 1 increment 1024;                          -- uid y op_id (progresion.md §4.5)
create table id_blocks (first_id bigint primary key,                           -- [first_id, first_id + 1023]
  zone_instance_id uuid not null references zone_instances on delete cascade, granted_at now_ts);  -- cae con la retención de §11.1

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
  zone_id text not null, zone_channel smallint not null,                        -- la copia: el channel de la instancia
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
create index on audit_log (target_account_id, command, at);                    -- S2: el set-role de §9.1

-- 0006_privacy
create table purge_log (kind text not null check (kind in ('account','character')), id bigint not null, purged_at now_ts,
  primary key (kind, id));                                                      -- sin datos personales (§11.2)
create table sanctioned_email_hashes (hmac bytea primary key, until ts not null);  -- HMAC-SHA256 del correo (§11.2)
```

- `0010_progress` es de progresion.md: su DDL está solo en su §3.3 y lo escribe su P7, con el `.down.sql` y la
  semilla de conservación. Las migraciones posteriores del progreso toman el siguiente número libre (§2.4).
- Cada `.down.sql` deshace su `.up.sql` en orden inverso.
- **Las tablas de solo añadir del progreso** llegan a `characters` por `op_participants`, con clave ajena **sin
  cascada** (progresion.md §3.3): un `delete from characters` con apuntes falla, nunca a medias. Por eso el
  personaje no se borra al purgarlo: queda como lápida (§11.2) hasta que la retención vacía su libro. La marca
  `eldmark.retention_purge` del disparador `eldmark_append_only` no es una barrera de seguridad (cualquier rol puede
  ponerla): solo evita borrados por error. Se pone con `set local` y no sobrevive a la transacción (comprobado).

## 4. API pública (cliente ↔ plataforma)
### 4.1 Convenciones
- HTTPS y JSON en UTF-8, prefijo `/v1`, cuerpo de 16 KB como mucho (413). Campos desconocidos: 400.
- Cabeceras: `Authorization: Bearer <acceso>`, `X-Eldmark-Protocol: <PROTOCOL_VERSION>`, `X-Eldmark-Build: <build
  id>`. Sin protocolo o por debajo de `ELDMARK_MIN_PROTOCOL`: 426.
- **Todo id `bigint` viaja como cadena decimal**, en las dos API (pública e interna), también en la reclamación y
  en el guardado: `character_id`, `account_id`, `actor_account_id`, `ignored_account_ids`, `ticket_id`, `uid`,
  `op_id`, `ref_op_id`, `ref_id`, `seed`, `entry_id`, `report_id`, `sanction_id` y el `first` de un bloque de ids.
  `JSON.parse_string` de Godot lee todo número como `float` y corrompe sin avisar lo que pasa de 2^53 (comprobado:
  `8152839359930207727` → `8152839359930208256.0`). Van como número las cantidades, saldos, XP, puntos de reino,
  nivel, `seq`, `currency`, `reason`, `kind`, `world_id` y fechas Unix (todos < 2^53). Billete y apariencia, en
  base64 estándar. Así un error falla en voz alta en lugar de corromper en silencio.
- **Reinos.** En la API pública (`/v1`: cuerpos, respuestas y errores como `realm_locked`), el id de texto
  (`"vardheim"`, como en `ELDMARK_OPEN_REALMS`); en la interna (registro, reclamación, lotes), el código numérico de
  `NetProtocol.Realm` (1–3). La plataforma convierte en la frontera; dentro (`ValidateCreate`, la base) es el código.
- **Enteros que manda Godot.** Al volver a serializar lo que leyó, Godot escribe `820.0` (comprobado). En Go, todo
  campo entero usa `jsonx.Int` (acepta `4` y `4.0`; rechaza `4.5` y lo que pasa de 2^53) y todo id `jsonx.ID`
  (cadena decimal de 0 a 2^63 − 1; un número sin comillas es 400). Comprobado con Go 1.24.7 y
  `DisallowUnknownFields`. En una cadena no se pierde precisión: Go la lee con `strconv.ParseInt` y Godot con
  `String.to_int()` (int64), así que el `ticket_id` de 63 bits (§5.1) viaja entero. El tope de 2^53 − 1 de los ids
  del progreso es una regla de progresion.md (§3.4, S1), no de `jsonx`. En GDScript, quien escribe un cuerpo pone
  cada id con `str()`, y quien lo lee exige cadena (`is_valid_int()`), la convierte con `String.to_int()` y
  convierte con `int()` cada entero.
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
| 403 | `account_suspended`, `account_banned` | Sanción (`until`, `reason`), en `enter` y en toda ruta que no admite la sesión de privacidad. El inicio de sesión no lo da: tras una contraseña correcta abre esa sesión (§4.2) | «Cuenta suspendida hasta el …: motivo» |
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
| `POST /v1/sessions` | `{email, password}` | `{access_token, access_expires_in, refresh_token, refresh_expires_in, scope, restriction, account}`; `scope` `"game"` o `"privacy"`, y `restriction` null o `{code, until, reason}` (abajo) |
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
- **Una sola función comprueba contraseñas:** `accounts.CheckPassword(ctx, accountID, email, password, ip) (ok
  bool, err error)`, con `accountID` 0 para un correo inexistente y `email` el normalizado. La usan el inicio de
  sesión y las rutas con sesión que piden contraseña (`/v1/account/password`, `/email`, `/deletion`, `/export`, que
  pasan el correo actual de la cuenta), con los mismos contadores. **Los intentos de una misma clave van de uno en
  uno:** el freno se mira, la contraseña se comprueba y el fallo se anota con el turno de la clave tomado, así que N
  intentos a la vez cuentan como N seguidos. Sin el turno, todos pasaban la comprobación antes de que se anotara el
  primer fallo, y el freno de 30 s y el bloqueo del grupo admitían ráfagas.
- **Fallos de contraseña** (en memoria; una sola instancia en la fase 5; LRU de 100 000 claves). La clave de cuenta
  la calcula `CheckPassword`: el `account_id` si no es 0 o, si el correo no existe, el SHA-256 del correo
  normalizado. Así cada correo inexistente tiene su propio contador y frenar uno no delata a los demás:

| Clave | Regla |
|---|---|
| Cuenta y grupo de IP | 5 fallos seguidos → 15 min sin intentos desde ese grupo; 10 → 1 h |
| Cuenta, desde cualquier IP | Tras 5 fallos seguidos, un intento cada 30 s |
| Acertar | Reinicia las dos de esa cuenta |
| Respuesta al frenar | 429 `rate_limited` con `retry_after_s`; igual exista o no la cuenta |
| Aviso | Al 5.º fallo seguido, correo `login_failures` al dueño (uno cada 24 h como mucho) |

  Así 5 intentos desde una IP no dejan sin entrar al dueño desde la suya (TEC-23: el bloqueo temporal es por
  cuenta y grupo de IP).
- **Estado de la cuenta:** con una contraseña mala, `invalid_credentials`, esté o no sancionada la cuenta; una cuenta
  `purged` responde como un correo inexistente. Con una buena, una cuenta suspendida o expulsada recibe una **sesión
  de privacidad** (`scope: "privacy"`, en la respuesta y en `sessions.scope`, con `restriction: {code:
  "account_suspended"|"account_banned", until, reason}`). Solo admite `GET /v1/account`, `POST /v1/account/export`,
  `POST` y `DELETE /v1/account/deletion`, `POST /v1/sessions/refresh` y `DELETE /v1/sessions/current`; cualquier
  otra ruta, `enter` incluido, da 403 con ese `code`, y sin `enter` no hay billete ni reclamación. Así exportar y pedir
  la supresión (§11.2) no dependen de no estar sancionado. El refresco conserva el `scope`.
- **Sesión única de juego:** iniciar sesión revoca las demás de la cuenta (`revoke_reason = 'replaced'`) y el latido
  expulsa a su personaje (§6). Además, solo un personaje de la cuenta puede estar en el mundo (§4.5, §5.3).
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
`refresh_reuse`, `character_create`, `character_delete`, `export`, `email_changed`, `email_reverted`,
`password_reset` (con la cuenta o, sin ella, con `account_id` nulo).

### 4.3 Ciclo de vida (TEC-41)
| Ruta | Cuerpo | Efecto |
|---|---|---|
| `POST /v1/account/verify-email` (sin token) · `…/verify-email/resend` | `{token}` · — | Verifica · 202, correo nuevo; los anteriores dejan de valer |
| `POST /v1/account/password-reset` (sin token) | `{email}` | **Siempre 202**, exista o no la cuenta, y sin esperar a la base: tras el límite de correos, buscar la cuenta, guardar el enlace y mandarlo siguen en segundo plano (los dos caminos dejan su fila `password_reset` en `auth_events`). Así el tiempo tampoco delata qué correos tienen cuenta |
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
  where account_id = $1 and used_at is null and purpose <> 'revert_email'`. Los `revert_email` no se invalidan así:
  quien robó la cuenta no puede quitarle al dueño la vuelta atrás cambiando el correo otra vez.
- **Una cadena de cambios.** Gastar un `revert_email` anula, en la misma transacción, los de la cuenta emitidos
  después (`created_at` mayor; en una cuenta no se repite: uno nuevo va como poco 1 µs detrás del anterior). Quien
  sabe la contraseña y cambia el correo dos veces (A→B→C) recibe en B un `revert_email`; el del dueño, el que llegó
  a A, es siempre el más antiguo, así que gastarlo deja muerto el de B, y el de B, gastado antes, no toca el de A.
  Sin esta regla, el de B, vivo 7 días, devolvía la cuenta al ladrón después de que el dueño la recuperara.
- **El correo viejo queda reservado** mientras viva su `revert_email` (sin usar y sin caducar): un registro o el
  cambio de correo de otra cuenta hacia él reciben lo mismo que hacia un correo con cuenta (`register_existing`), y
  un `change_email` pendiente hacia él, de otra cuenta, no vale (`fields.token = "unavailable"`). Si no, una cuenta
  nueva sin verificar con ese correo bloqueaba la vuelta atrás hasta que el enlace caducaba.
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
| `GET /v1/worlds/{w}/characters` | — | `{realm, unlock_at, slots, used, characters: [{character_id, name, realm, race_id, appearance, level, last_zone_id, played_seconds, created_at, deleted_at, restore_until, must_rename}]}`; de `characters` y, para raza, apariencia, nivel, última zona y tiempo jugado, `ProgressStore.Summaries` |
| `GET /v1/worlds/{w}/name-check?name=…` | — | `{available, code, reason}` |
| `POST /v1/worlds/{w}/characters` | `{name, realm, race_id, appearance, starter_template_id}` | 201 `{character}` |
| `DELETE /v1/characters/{id}` | `{confirm_name}` | `{restore_until}`; `confirm_name` con la misma clave de NameRules que el nombre |
| `POST /v1/characters/{id}/restore` | — | 200 en plazo, con el nombre libre |
| `POST /v1/characters/{id}/rename` | `{name}` | Solo con `must_rename`; el viejo queda reservado 30 días |
| `POST /v1/characters/{id}/enter` | — | §4.5 |

**Datos del juego: un solo archivo**, `platform/internal/gamedata/progression_rules.json`, con las reglas de
progresion.md §13.4: lo genera `ProgressionRulesExport.build()`, lo escribe `tools/progression/export_rules.gd`, lo
comprueba una sola prueba (`tests/test_progression_rules_export.gd`) y se lee con `//go:embed` (que no lee fuera de
`platform/`). De este documento son dos secciones: `protocol_version` (`NetProtocol.PROTOCOL_VERSION`) y `names`
(`{min_length, max_length, upper_letters, lower_letters, folded, reserved}` de `NameRules`; la añade P2); las demás
(`races`, `appearance`, `starter_templates`, `items`, `level_curve`, `currencies`, `reasons`, `containers` y
`combat`), de progresion.md. Quien llegue antes (P2 de aquí o progresion.md P3) crea `build()`, la herramienta, la
prueba y el archivo; el otro añade sus secciones. `internal/names` lee `names` y es `NameRules` en Go (`Validate`,
`NormalizeKey`, reservados); `progress.LoadRules` lee el resto. Los casos de nombres de los dos lados salen de
`tests/fixtures/names/name_rules_cases.json` (`[{name, reason, key}]`), que leen `test_name_rules.gd` e
`internal/names` (con `os.ReadFile("../../../tests/fixtures/names/…")`: las pruebas de Go corren en el directorio del
paquete). Todos los datos de prueba que comparten Godot y Go van bajo `tests/fixtures/` (los del progreso, en
`tests/fixtures/progression/`, progresion.md §13.2).

**Crear**, en una transacción `serializable` (reintento ante 40001):

1. Cuenta activa sin borrado pendiente; `realm` en `ELDMARK_OPEN_REALMS` (si no, `realm_closed`); menos de 5
   `character_create` en 24 h (si no, 429).
2. `account_realms`: sin fila, o con `unlock_at ≤ now()` y ningún personaje vivo, se fija este reino; si la cuenta
   tiene otro, `realm_locked`.
3. Huecos: 6 + `quantity` de los `character_slots` vigentes. **Ocupan hueco los vivos y los borrados en plazo** (los
   que aún se pueden restaurar).
4. Nombre: `names.Validate` (422), lista negra (422 `reserved`; la edita `admin --actor <correo> names
   block|unblock <nombre>`, §9.1) e
   `insert into character_names` con `status 'active'`. Una fila `reserved` vigente da `name_taken`; vencida, se
   reutiliza. Dos creaciones a la vez con el mismo nombre: una falla con 23505 en `character_names_pkey`
   (comprobado en una sonda con la misma clave) → `name_taken`.
5. Raza, apariencia y plantilla: `persistence.CreateValidator.ValidateCreate(realm, race_id, appearance,
   starter_template_id)` (§7.5; la regla, progresion.md §13.2): `race_id` de su reino (`race_vardheim`…),
   apariencia de **8 B** válida para su raza (la regla de `CharacterAppearance.validate`, progresion.md §7.2) y
   `starter_template_id` de `starter_templates` (las plantillas `selectable`). Si no, devuelve
   `*persistence.ValidationError` y la respuesta es 400 `validation` con sus `fields` (`{"race_id":
   "wrong_realm"}`, `{"appearance": "invalid"}`, `{"starter_template_id": "not_selectable"}`). `serve` elige la
   implementación: hasta tener progresion.md P3 y P7, la provisional de P2 (`race_id = "race_" + reino`, 8 B
   cualesquiera y plantilla que cumple `^[a-z0-9_]{1,32}$`; la zona corrige al cargar una apariencia que no valga,
   progresion.md §7.2); después, `*progress.Rules`.
6. `insert` en `characters` y `character_pvp_stats`, y `ProgressStore.Create` (§7.5) con la raza, la apariencia y
   la plantilla; `auth_events` `character_create`.

**Borrar**, en una transacción que bloquea primero la fila de la cuenta (`select … from accounts where account_id =
$1 for no key update`, el orden de la reclamación, §5.3, y de la purga de la cuenta): con arrendamiento vivo,
`character_busy`; 5 `character_delete` en 24 h, 429. Así el borrado y la reclamación de ese personaje van en serie:
queda borrado y sin arrendamiento o vivo y con él, nunca borrado y en el mundo. `deleted_at = now()`,
`restore_until = now() + 7 d` y el nombre `reserved` hasta `restore_until + 30 d`. **Excepción:** un personaje con
menos de 24 h de vida y menos de 1 h jugada (`PlayedSeconds < 3600` de `Summaries`) reserva el nombre solo hasta
`restore_until`. Al vencer `restore_until`, la purga horaria lo deja como lápida (§11.2); el nombre sigue reservado lo
que toque. Si era el último vivo, `unlock_at = now() + 30 d`.

**Restaurar**, igual, bloquea la fila de la cuenta y después la de `characters` (`for no key update`, como la purga)
y vuelve a mirar `restore_until > now()` y `purged_at` nulo: una restauración en el límite y la purga horaria no se cruzan (§11.2).

### 4.5 Entrar al mundo
`POST /v1/characters/{id}/enter`, sin cuerpo. Comprueba en orden: sesión, mantenimiento (503), sanciones (403),
borrado pendiente (403), textos por aceptar (403), correo verificado si se exige (403), personaje vivo de la cuenta
(404), `must_rename` (409), arrendamiento vivo de ese personaje **o de otro de la cuenta en ese mundo** (409
`character_busy`: un solo personaje en el mundo por cuenta; la reclamación lo vuelve a mirar, §5.3). Elige la zona: la última (`LastZoneID` de
`ProgressStore.Summaries`) si tiene una instancia `live` cuyo `realms` incluye el reino del personaje (en su
`LastChannel` si está vivo y con sitio); si no, la de entrada de su reino. Dentro de la zona, el canal con menos
jugadores bajo `max_players`; si no hay ninguno vivo, 503 `zone_unavailable`. Inserta el billete en `enter_tickets` (10 s) y responde:

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
`ticket` del HELLO (≤ 256 B). Solo lleva identidad: en un traspaso (fase 6), lo demás (CMB-30 incluido) llega con el
guardado final del origen y la reclamación en el destino (progresion.md §8).

| Offset | Tipo | Campo | Notas |
|---|---|---|---|
| 0 | u8 | version | 1 |
| 1 | u8 | key_id | clave de `ELDMARK_TICKET_KEYS` (1–255) |
| 2 | u16 | world_id | |
| 4 | u64 | ticket_id | aleatorio, bit 63 a 0; clave de `enter_tickets`; en JSON, cadena de hasta 2^63 − 1 (§4.1) |
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
| 200 | En orden: (1) la zona admite `claimed.realm` (si no, `REALM`); (2) cabe bajo `max_players` (si no, `FULL`); (3) `ProgressService.prepare(peer_id, claimed)` (progresion.md §9.1: decodifica, valida la apariencia y crea el `PlayerProgress`) y, si devuelve false, `UNAVAILABLE` con «No se ha podido cargar el personaje» (`AuthOutcome.text`) y una alerta en el registro; si falla alguno, `release(character_id, lease_id)`. (4) WELCOME con `claimed.realm`, `complete_auth` y `LOADING` |
| 409 `ticket_invalid` (consumido, caducado, de otra instancia o de una sesión revocada) | REJECT `TICKET` |
| 409 `character_busy` | REJECT `BUSY` |
| 403 `account_blocked` (suspendida, expulsada, borrado pendiente) | REJECT `BANNED` con el `message` del cuerpo (§6.1) |
| 409 `instance_lost`, `instance_replaced` o `instance_stopped` | REJECT `UNAVAILABLE` y el cierre de §6.1 |
| Cualquier otra (409 `instance_not_live`, otro 4xx, 5xx), sin conexión o 7 s desde la conexión sin respuesta | REJECT `UNAVAILABLE` (un 4xx, con alerta en el registro); si la reclamación llega después, se libera |

**Baja en `LOADING`.** Entre el WELCOME y CLIENT_READY el personaje tiene arrendamiento y un `PlayerProgress`
preparado, pero no cuerpo ni entrada en `CharacterSaver`. Si el peer sale de `LOADING` sin llegar al mundo
(CLIENT_LEAVE, desconexión, el plazo de CLIENT_READY, una expulsión o un `revoked` del latido), la zona llama a
`ZonePlatform.release(character_id, lease_id)` sin guardar y a `ProgressService.cancel_prepared(peer_id)`
(progresion.md §9.1); un `revoked` expulsa con su NOTICE y sin guardado final, que aquí no existe.

### 5.3 Arrendamiento
La reclamación, en una transacción: bloquea la fila de la cuenta y mira su estado y sus sanciones, comprueba el
personaje (`deleted_at` y `purged_at` nulos y del mundo de la instancia; si no, 409 `ticket_invalid`), bloquea el
billete (si no vale, 409 `ticket_invalid`) y **solo entonces**, con la cuenta suspendida, expulsada o con el borrado
pedido, responde 403 `account_blocked`: sin un billete válido de ese personaje para esa instancia no se sabe nada de
la cuenta (ni el motivo ni la fecha de una sanción, de este mundo o de otro). Si no, consume el billete, mira que
ningún otro personaje de la cuenta esté en el mundo, toma el arrendamiento y, tras el `insert …
on conflict`, lee la sección `progress` con `ProgressStore.Load` en la misma transacción (con la fila del
arrendamiento bloqueada, ningún guardado se cruza). El orden de bloqueos es cuenta → billete → arrendamiento; la
purga de una cuenta también bloquea antes su fila (§11.2). Comprobado en PostgreSQL 16, salvo los pasos 0 y 2:

```sql
-- 0. La cuenta del personaje ($8): serializa las reclamaciones de una misma cuenta
select status from accounts where account_id = $8 for no key update;   -- y sus sanciones, sin responder aún
-- 1. El billete: de esta instancia, sin usar, sin caducar y de una sesión sin revocar
select t.session_id from enter_tickets t join sessions s on s.session_id = t.session_id
where t.ticket_id = $1 and t.character_id = $2 and t.zone_instance_id = $3 and t.consumed_at is null
  and t.expires_at > now() - interval '5 s' and s.revoked_at is null
for update of t;                            -- sin fila: ticket_invalid y rollback
-- (cuenta bloqueada: ahora el 403 account_blocked y rollback; si no:)
update enter_tickets set consumed_at = now() where ticket_id = $1;
-- 2. Un solo personaje en el mundo por cuenta y mundo
select 1 from character_leases l join characters c using (character_id)
where c.account_id = $8 and c.world_id = $4 and l.character_id <> $2
  and l.zone_instance_id is not null and l.expires_at > now();   -- con fila: character_busy y rollback
-- 3. El arrendamiento ($5 = session_id, $6 = lease_id nuevo de crypto/rand, $7 = TTL)
insert into character_leases (character_id, world_id, lease_id, zone_instance_id, claimed_by, session_id, expires_at)
values ($2, $4, $6, $3, $3, $5, now() + $7)
on conflict (character_id) do update set lease_id = excluded.lease_id, zone_instance_id = excluded.zone_instance_id,
  claimed_by = excluded.claimed_by, session_id = excluded.session_id, expires_at = excluded.expires_at,
  last_seq = 0, last_save_hash = null, claimed_at = now(), released_at = null
where character_leases.zone_instance_id is null or character_leases.expires_at < now()
returning lease_id;                         -- sin fila: character_busy y rollback (el billete no queda consumido)
```

- **Latido** cada 5 s, con su propia plaza (§6): `characters: [{character_id, lease_id}]`, el conjunto que mantiene
  `ZonePlatform` (§14.3). Un personaje entra con el 200 de su reclamación, cambia de `lease_id` con otra reclamación
  suya y sale con `release()` o con la respuesta definitiva (200 o definitivo) de un guardado con `release_lease`, si
  sigue siendo ese `lease_id`. Así cubre `LOADING`, el mundo, el cuerpo tras una salida en combate y el guardado
  final pendiente, y deja de latir por quien ya se fue. Los de `VERIFYING` no van: aún no tienen `lease_id`. Renueva
  solo lo que casa y sigue vivo (uno caducado ya lo dan por libre la reclamación, `enter` y el borrado; renovarlo
  dejaba dos personajes de la cuenta en el mundo, o uno borrado dentro):

  ```sql
  update character_leases l set expires_at = now() + $4
  from unnest($2::bigint[], $3::uuid[]) as h(character_id, lease_id)
  where l.character_id = h.character_id and l.lease_id = h.lease_id and l.zone_instance_id = $1
    and l.expires_at > now()
  returning l.character_id;                 -- los que faltan vuelven en revoked con reason lease_lost
  ```

  Los que no van en la lista caducan solos (TTL 30 s). Cada entrada de `revoked` lleva su `lease_id` (§6).
- **Cercado.** Sin un latido aceptado en 2 × `HEARTBEAT_S` (10 s), la zona está cercada hasta el siguiente: no
  admite HELLO (REJECT `UNAVAILABLE`) ni operaciones que piden guardado crítico (los comandos de GM que cambian
  algo, progresion.md §10, y en la fase 6 comercio y correo: «El servicio de cuentas no responde; inténtalo más
  tarde»). No expulsa a nadie: el juego sigue y §7.4 vale.
- **Instancia perdida:** 15 s (3 × `HEARTBEAT_S`) sin latido → `lost` y sus arrendamientos libres
  (`zone_instance_id = null`; `lease_id` y `claimed_by` se quedan). Tras un `kill -9`, el personaje vuelve a entrar
  en 15 s como mucho. Si la instancia vuelve, §6.1.
- **Instancia nueva de la misma zona y canal.** Si la vieja latió hace menos de 3 × `HEARTBEAT_S`, el registro da 409
  `instance_alive` salvo con `"replace": true` (`--replace`), que deja una fila en `audit_log`. La zona sin
  `--replace` reintenta cada 2 s durante 60 s y luego sale con código 1. Si la vieja lleva 3 × `HEARTBEAT_S` o
  más sin latir pero sigue `starting` o `live` (el trabajo de perdidas aún no ha pasado), el registro, en su
  transacción, la pasa a `lost` y libera sus arrendamientos como el trabajo, y después inserta la nueva: nunca
  choca con el índice único parcial. Al sustituir, la vieja pasa a `replaced` y **sus arrendamientos no se liberan
  en ese momento**: los libera el guardado final de cada uno (`release_lease`) o caducan con el TTL, porque la vieja
  ya no los renueva (su latido da `instance_replaced`). Si seguía viva, hace el cierre de §6.1 y **sus guardados
  finales valen** (§7.3); mientras, quien intenta volver a entrar recibe `character_busy` y el cliente reintenta,
  así que carga el final y no el guardado anterior. Una instancia `lost` sí los libera al instante (puede estar
  muerta); por eso el cierre de §6.1 expulsa solo después de mandar los finales.
- **Salida en combate** (GUE-41): el arrendamiento dura hasta que el cuerpo se va y el guardado final llega. Entrar
  en esos 15 s da `character_busy` y el cliente reintenta solo cada 3 s durante 30 s: reconectar no acorta la salida
  en combate.
- **`lease_id` solo cambia al reclamar.** Liberar no lo cambia: un guardado tardío de la misma instancia se acepta
  si nadie ha reclamado al personaje desde entonces (§7.3).

### 5.4 Cambios en el protocolo
| Pieza | Cambio |
|---|---|
| `PROTOCOL_VERSION` | **7**, una sola subida para toda la fase 5, compartida con progresion.md (4 el fuerte, 5 el chat y los grupos, 6 habilidades.md). El reparto es fijo: la 5 ya está en main y P4 de aquí espera a que habilidades.md suba la 6 (§14.1). La sube P4, que va antes que progresion.md P4 en el orden de §14.1, con la línea completa en `net_protocol.gd`: «7: la fase 5 (docs/plataforma.md y docs/progresion.md): REJECT 10–12, billete de 52 B, `auth_timeout` de 10 s, bit 3 del `flags` de la cabecera del ENTITY_SPAWN (personal del juego), +9 B del SPAWN de PLAYER (nivel y apariencia), mensajes 0x50–0x55, ENTITY_EVENT 16 LEVEL_UP, DEBUG_COMMAND 40–43 e `ItemDatabase` en el `sim_hash`». **En red.md, cada P4 documenta lo que añade su código**, con sus filas y su marca «v7»: P4 de aquí, «= 7» y §5.3 (REJECT 10–12, billete de 52 B, `auth_timeout` de 10 s) y el bit 3 de §5.5; progresion.md P4, §3 (`sim_hash` con `ItemDatabase` y el texto nuevo del REJECT `SIM_HASH`), §5.2 (0x50–0x55), §5.4 (DEBUG_COMMAND 40–43) y lo suyo de §5.5 (+9 B del PLAYER, que no cambian el payload de NPC; LEVEL_UP), como dice progresion.md §12. progresion.md P4 añade su parte del código sin subir la versión |
| `NetTransport` | `AUTH_TIMEOUT_SECONDS` = 10.0 (antes 5.0), en los dos lados (§5.2), en la misma subida |
| HELLO | **Sin cambios de bytes.** Con billete van `character_id` y `ticket`; el cliente pone en `realm` y `name` los de su personaje y la zona los ignora |
| WELCOME | Sin cambios de bytes; `realm` es el del personaje |
| REJECT | `Result` añade `BUSY = 10`, `UNAVAILABLE = 11` y `BANNED = 12` (libres en todas las ramas; si otra ocupa alguno, los siguientes). `result_text`: «Tu personaje sigue en el mundo: espera unos segundos», «El servicio de cuentas no responde: inténtalo más tarde» y, en `BANNED`, el `message` del 403 `account_blocked`, que compone la plataforma (§6.1); «Tu cuenta está suspendida» solo si falta |
| ENTITY_SPAWN | Bit 3 del `flags` de la **cabecera** (offset 9; hoy bit0 «tuyo» y bits 1–2 teletransporte) = personal del juego (moderador o más), para la etiqueta (SOC-14). No es el `flags` del registro del snapshot, cuyo bit 3 usa habilidades.md |
| NOTICE | Sin códigos nuevos: «Has iniciado sesión desde otro lugar» o «Tu cuenta ha sido suspendida» van con el 1 (expulsión) |

Con `--platform`, `--max-realm-diff` (REJECT `IMBALANCE`) no se aplica: el reino ya no se elige al conectar (el
equilibrio de población es de GUE-36). El enfriamiento tras una expulsión usa la clave `character:<id>` en lugar del
nombre del HELLO. Con billete (`uses_tickets()`), `ServerAuth` no compara el nombre del HELLO con los conectados, así
que no hay `REJECT NAME`: el HELLO deja de delatar si un nombre está en la zona (la limitación de la fase 4 de
social.md 12.7; prueba en P4).

### 5.5 Modos de arranque
| Modo | Fase 5 |
|---|---|
| F5 en el editor sin argumentos | Sandbox de la fase 1, igual (`OS.has_feature("editor")`) |
| Sin argumentos en una exportación · `--title [--platform=<url>]` | Pantalla de título (UI-22) contra `eldmark/platform/url` · lo mismo desde el editor |
| `--server` sin `--platform` | `DevAuthProvider` como hoy: reino y nombre del HELLO; personajes efímeros, nada se guarda (progresion.md §9.4) |
| `--server --platform=<url interna>` | `TicketAuthProvider`; un HELLO sin billete recibe `TICKET` («Entra desde el menú con tu cuenta»). `--debug-commands`, `--fake-players`, `--fake-churn`, `--battle-log`, `--combat-log` y `--state-log` solo si el `env` del registro es `dev` o `test`; si no, la zona sale con código 1 y «Esa opción no se admite con la plataforma en staging/production» |
| `--fake-players`, `--fake-churn` | Nunca tocan la plataforma ni se guardan; se llaman `Bot-NN`, que no es un nombre válido y no choca con ningún personaje. Con plataforma, la zona no da recompensas persistentes (progresion.md §6.2) |
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
  ruta o la consulta), que tiene que ser una instancia de ese alcance (si no, 403 `forbidden`). En la zona lo pone
  `ZonePlatform` (§14.3) en la reclamación, la liberación, el latido, los bloques de ids, las fortalezas, los lotes y
  `request`, no quien arma la petición. El guardado es la excepción: su sobre entero, `zone_instance_id` incluido, lo
  arma `CharacterSaver` antes de serializarlo (§7.3).
- **Cuerpo de 1 MB como mucho** en toda la API interna (413), también guardados y reclamaciones: sobra para 120
  ranuras, el equipo y el diario de un minuto. Ids en cadena, enteros y reinos (código) como en §4.1.
- **En `staging` y `production`** el registro sin `dtls_cert_pem` da 400 `validation`.
- Registro y latido traen `now_unix`: la zona guarda `offset = now_unix − su reloj` (`ZonePlatform.now_unix()`) y
  avisa si pasa de 2 s.

**`PlatformClient`** (en la zona, dentro de `ZonePlatform`) usa `HTTPRequest` (sin hilos), plazo de 3 s
(`timeout_s`, menor en las pruebas) y colas por prioridad. Los resultados se guardan al llegar y se aplican en el
paso «poll», nunca a mitad de tick:

| Prioridad | Peticiones | Reintento |
|---|---|---|
| 0 control | Registro, `live`, GET de fortalezas y primer bloque de ids al arrancar, latido, baja | Registro, `live`, GET y primer bloque: 1, 2, 4… s hasta 60 s, luego la zona sale (§8). Latido: no (el siguiente sale a su hora; nunca dos en cola) |
| 1 entrada | Reclamación, liberación | Reclamación: **no** (la corta el plazo de §5.2). Liberación: como los guardados, hasta una respuesta definitiva (un 4xx lo es, §7.3) |
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
| `POST /internal/v1/zone-instances/{id}/heartbeat` | `{players, characters: [{character_id, lease_id}]}` | `{now_unix, revoked: [{character_id, lease_id, reason, text}], mutes: [{account_id, until_unix}], maintenance: {at_unix, message} \| null}` |
| `DELETE /internal/v1/zone-instances/{id}` | — | 204; `stopped` y libera lo que quede |
| `POST /internal/v1/claims` | `{zone_instance_id, ticket_id, character_id}` | `{lease_id, instance_status, account: {account_id, role, muted_until_unix, ignored_account_ids}, character: {character_id, world_id, realm, name}, progress, pvp}`: `realm` es el código (§4.1), `progress` el `ProgressRecord` completo de progresion.md §3.4 (`ProgressStore.Load`, `progress_format` 1) y `pvp` los totales de §8 |
| `PUT /internal/v1/characters/{id}/state` | §7.3 | `{applied, duplicate, save_version, instance_status}` |
| `POST /internal/v1/saves` | `{zone_instance_id, saves: [§7.3]}` | Todos o ninguno (comercio y correo, fase 6): todos nuevos o todos repetidos; mezcla → 409 `seq_conflict` |
| `POST /internal/v1/characters/{id}/release` | `{zone_instance_id, lease_id}` | 204, sin guardar (el cliente no llegó a aparecer: tras el 200 de la reclamación o en `LOADING`, §5.2; o tras un `invalid_save`) |
| `POST /internal/v1/id-blocks` | `{zone_instance_id}` | `{"first": "1025", "count": 1024}`: `nextval('uid_block_seq')` y una fila en `id_blocks`; en `starting` y en `live`. `uid` y `op_id` salen de los mismos bloques y son únicos en todos los mundos |
| `GET /internal/v1/ops/{op_id}?zone_instance_id=` | — | `ProgressStore.Op(…, opID, instance)`; respuesta de progresion.md §13.2 (para `op_show` y la reversión), o 404 (también si ningún participante tiene arrendamiento en la instancia) |
| `GET /internal/v1/characters/{id}/ledger?zone_instance_id=&limit=&before_entry_id=` | — | `ProgressStore.Ledger`; respuesta de progresion.md §13.2; `limit` de 1 a 100 (20 por defecto), más recientes primero (para `ledger_show`); 404 si el personaje no tiene arrendamiento en la instancia |
| `GET /internal/v1/fortresses?zone_instance_id=` · `PUT /internal/v1/fortresses/{id}` | — · `{zone_instance_id, expected_version, record}` | `{fortresses: [{fortress_id, record, version}]}`, solo las de la zona de la instancia (lista vacía: sin registros) · `{version}`, 409 `version_conflict` con `{version}` o 403 `forbidden` (fortaleza de otra zona, abajo) |
| `POST /internal/v1/war-events` · `…/chat` · `…/audit` | `{zone_instance_id, events\|messages\|entries: [{key, …}]}` (§8, §9) | 204; si alguna entrada no vale, 200 `{rejected: [key…]}` y las demás se insertan |
| `POST /internal/v1/reports` | `{zone_instance_id, …}` (§9.4) | `{report_id}` o 429 |
| `POST` · `DELETE /internal/v1/ignores` | `{zone_instance_id, character_id, target_name}` | `{ignored_account_id, name}` · 204 |
| `POST /internal/v1/sanctions` | `{zone_instance_id, author_character_id, target_name, kind, minutes, reason, report_ids}` | `{sanction_id, ends_at_unix}` o 403 `forbidden` (§9.5) |

- **Operación y libro:** las registra el enrutador interno de este documento, con las comprobaciones de §6.1
  (token, alcance, instancia `live` y arrendamiento); el mundo sale de la instancia. Como las demás rutas de la
  zona, exigen arrendamiento en esa instancia (`character_leases.zone_instance_id` igual a la instancia): el libro,
  del personaje (lo mira el enrutador en `character_leases`); una operación, de alguno de sus participantes, que lo
  mira `ProgressStore.Op` con la instancia en su propia consulta (un `join` de `op_participants` con
  `character_leases`), así que la plataforma no lee tablas del progreso. Si no, 404: una zona no lee el libro de
  quien no tiene dentro (progresion.md §10). Los cuerpos son los de progresion.md §13.2, con `participants`,
  `reversed_by` e `instances` (las filas retiradas que necesita `op_revert`).
- **El mundo lo pone la instancia.** Reportes, ignorados y sanciones resuelven `target_name` en el `world_id` de
  `zone_instance_id`, como los lotes: los cuerpos no lo traen (un `world_id` en el cuerpo es un campo desconocido,
  400) y una zona no alcanza a nadie de otro mundo.
- **Fortalezas de una zona.** El primer PUT de un `fortress_id` crea su fila con el `zone_id` de la instancia. Un PUT
  de una fortaleza que ya existe con otro `zone_id` da 403 `forbidden`, un evento de guerra de esa fortaleza va a
  `rejected` y el GET solo devuelve las de la zona de la instancia: una zona no puede pisar el registro ni el
  historial de otra.
- **Lotes** (chat, auditoría, guerra): cada 2 s o 200 entradas, 1 MB como mucho. Cada entrada lleva su `key`
  (`ZonePlatform.enqueue_batch` pone `"<zone_instance_id>:<secuencia>"` si la entrada no trae una; la auditoría de
  un comando que crea una operación trae `op:<op_id>`, §9.1) y se inserta con `on conflict do nothing`: reenviar un
  lote no duplica nada. `world_id` y `zone_id` los pone la plataforma desde la instancia, y en el chat también
  `zone_channel` (el `channel` de la instancia) y `sender_account_id`, desde `characters`. **Cada entrada se valida
  por separado y contra la instancia que la manda.** Se rechaza la que no trae un campo; la de `key`
  `"<uuid>:<n>"` cuyo uuid no es el `zone_instance_id` del lote; la de `key` `op:<op_id>` cuyo `op_id` no cae en un
  bloque de `id_blocks` dado a esa instancia; y, en la auditoría, la de `source` distinto de `zone` y `console`
  (las filas `cli` y `platform` solo las escribe la plataforma) o con un `command` de la CLI o de la plataforma
  (`set-role`, `sanction_denied`). También la que trae algo que la base no guarda: un `args` con UTF-8 roto,
  `\u0000` o un suplente suelto (como `context` en un reporte y `record` en una fortaleza, que dan 400), o una fecha
  (`at_unix`, `sent_at_unix`) de más de 253402300799 (9999-12-31). Y si aun así una fila falla en la base con un
  error determinista (SQLSTATE de clase 22 o 23), se rechaza solo esa. Lo rechazado se registra, las demás se insertan y la respuesta lista las
  claves rechazadas, que la zona no reintenta. Así una zona no escribe en nombre de otra instancia ni de la CLI,
  y un error de la zona no bloquea la cola de auditoría, que nunca se descarta.
- **`revoked`** del latido. Cada entrada lleva el `lease_id` (el del latido en `lease_lost`; el del arrendamiento
  en las demás) y la zona ignora la que no casa con el arrendamiento actual de ese personaje: un latido construido
  antes de una salida y una nueva entrada en la misma instancia no expulsa al que acaba de entrar. Un personaje en
  `LOADING` no tiene guardado final: se libera sin guardar (§5.2).

| `reason` | Cuándo | La zona |
|---|---|---|
| `lease_lost` | El `(character_id, lease_id)` del latido no casa con un arrendamiento de esta instancia | La baja sin guardado de §7.2, sin `release` (en `LOADING`, la baja de §5.2) |
| `session_revoked` | La sesión del arrendamiento está revocada (`replaced`, `password_changed`, `email_changed`, `email_reverted`, `refresh_reuse`, `role_changed`, `logout`, `deletion`, `admin`) | Guardado final y expulsión con NOTICE («Has iniciado sesión desde otro lugar», «Tu cuenta ha cambiado: vuelve a entrar») |
| `suspended`, `banned`, `pending_deletion` | Sanción vigente o borrado pedido | Guardado final y expulsión con el motivo y la fecha |

### 6.1 Estados de la instancia y orden de las comprobaciones
Cada petición interna se comprueba **en este orden**, y el primer fallo da la respuesta: (1) token → 401
`bad_token`; (2) alcance de la instancia → 403 `forbidden`; (3) estado de la instancia (tabla); (4) arrendamiento
(`lease_id` y `claimed_by`) → 409 `lease_lost`; en operación y libro, arrendamiento en la instancia → 404; (5)
`seq` → `duplicate`, 409 `stale_seq` o 409 `seq_conflict`; (6) contenido (S1–S8 de progresion.md §13.3) y errores
de la base, con la regla de §7.3.

| Petición | `starting` | `live` | `lost` | `replaced` | `stopped` |
|---|---|---|---|---|---|
| `live` | → `live` | 204 (repetida) | 409 `instance_lost` | 409 `instance_replaced` | 409 `instance_stopped` |
| Latido | 200 | 200 | 409 `instance_lost` | 409 `instance_replaced` | 409 `instance_stopped` |
| Reclamación | 409 `instance_not_live` | 200 o sus errores | 409 `instance_lost` | 409 `instance_replaced` | 409 `instance_stopped` |
| Guardado y liberación | §7.3 (no tiene arrendamientos: `lease_lost`) | §7.3 | §7.3: valen si `lease_id` y `claimed_by` casan (guardados finales) | ídem | ídem |
| Bloques de ids | 200 (el primero es del arranque, §8) | 200 | 409 `instance_lost` | 409 `instance_replaced` | 409 `instance_stopped` |
| Operación y libro | 409 `instance_not_live` | 200 o 404 | 409 `instance_lost` | 409 `instance_replaced` | 409 `instance_stopped` |
| GET de fortalezas | 200 | 200 | 409 `instance_lost` | 409 `instance_replaced` | 409 `instance_stopped` |
| PUT de fortaleza | 409 `instance_not_live` | 200 o 409 `version_conflict` | 409 `instance_lost` | 409 `instance_replaced` | 409 `instance_stopped` |
| Lotes | 204 (o 200 con `rejected`, §6) | ídem | ídem | ídem | ídem |
| Reportes, ignorados y sanciones | 409 `instance_not_live` | 200, o 403 `forbidden` | 409 `instance_lost` | 409 `instance_replaced` | 409 `instance_stopped` |

La respuesta de un guardado lleva `instance_status`: así la zona se entera aunque su latido vaya por detrás.
**Cierre por `instance_lost`, `instance_replaced` o `instance_stopped`** (en cualquier petición o en
`instance_status`; `ZonePlatform` lo convierte en el evento `instance_closed`, que atiende `ServerMain`, §14.3):
primero el guardado final de todos (`finish`, §7.2) y la liberación de los de `LOADING`, sin echar a nadie: la
zona deja de leer sus entradas y de dar recompensas. Después `begin_flush` y espera a `is_flushed()`, con 10 s como
mucho. **Solo entonces** NOTICE de expulsión «El servidor de la zona se ha reiniciado: vuelve a entrar» a todos,
desconexión y salida con código 3. Así quien vuelve a entrar enseguida (sus arrendamientos pueden estar ya libres
tras un `lost`) carga su guardado final y no el anterior. El orquestador (compose, `restart:
unless-stopped`) arranca una instancia nueva; en desarrollo el proceso sale con ese mensaje. `instance_not_live` es
un error de orden de la zona: se registra.

**Errores internos:** 401 `bad_token`; 403 `forbidden`, `account_blocked`; 409 `instance_not_live`,
`instance_alive`, `instance_lost`, `instance_replaced`, `instance_stopped`, `lease_lost`, `stale_seq`,
`seq_conflict`, `ticket_invalid`, `character_busy`, `version_conflict`, `schema_mismatch` (solo en el registro: el
`record_format` o el `protocol_version` no los admite esta plataforma; la zona sale con código 1); 400
`bad_request`, `validation`, `invalid_save` (con `fields: {check: "S4", detail: "…"}`: la comprobación de
progresion.md §13.3 y lo que falló, de `*persistence.InvalidSaveError`, `envelope` para un error del sobre o un
error de la base que no es pasajero, §7.3); 404 `not_found` (`persistence.ErrNotFound`, y operación o libro sin arrendamiento); 503 `db_unavailable` (la
base no responde o la transacción chocó con otra más veces de las que se reintenta, §7.3). Cuerpo como en §4.1.

**`account_blocked`** añade al cuerpo de §4.1 el tipo, el fin y el motivo: `{"error": {"code": "account_blocked",
"message": "…", "kind": "suspension"|"ban"|"pending_deletion", "until_unix": 1800000000, "reason": "…"}}`
(`until_unix` null en una expulsión permanente; en `pending_deletion`, el `purge_after`). **El texto para el
jugador lo compone la plataforma**, igual que el `text` de `revoked` en el latido: `message` según `kind` («Tu
cuenta está suspendida hasta el 3/11/2026 18:00 UTC: motivo», «Tu cuenta está expulsada: motivo», «Tu cuenta se
borrará el …»), cortado en un carácter entero a 255 B (el `text_len` del REJECT). La zona lo pone tal cual en
`AuthOutcome.text`; `kind`, `until_unix` y `reason` van a su registro.

## 7. Persistencia del personaje (TEC-25)
### 7.1 Qué se guarda
La tabla «quién guarda qué» está en progresion.md §3.1. El cuerpo del guardado (§7.3) lleva una clave por sección
registrada en `CharacterSaver`, con su nombre:

| Sección | Qué | Quién la construye |
|---|---|---|
| `progress` | La sección de progresion.md §3.4 y §9.3: el `ProgressRecord` sin los campos de solo lectura, con `ops` (las operaciones del diario aún no incluidas en ningún cuerpo, progresion.md §9.2, con sus apuntes y eventos de objeto) | `ProgressService` (progresion.md) |
| `pvp` | Totales de GUE-19 `{kills, deaths, assists, captures, gate_damage, defend_s}` | `ScoreKeeper` (§8) |
| **Nunca** | `PlayerState`, `CombatState` y lo que se predice por tick, la cola de entradas, el combate en curso, los avisos | — |

**Volver al mundo** (provisional, tomada de noche): la regla es la de progresion.md §8. **CMB-30** (las dos armas, el
arma activa, la vida y las reutilizaciones largas) también es de progresion.md §8 y viaja dentro de `progress`: aquí
no tiene sección propia.

**Formatos.** `save_format` (1) versiona el sobre de §7.3 y es de este documento. `progress.progress_format` (1)
versiona la sección y es el `record_format` que la zona declara al registrarse: `ZonePlatform.RECORD_FORMAT` (1),
que existe desde P4 aunque `ProgressRecord` llegue en progresion.md P5a; `ProgressRecord.FORMAT` (progresion.md
§3.4) vale lo mismo y una prueba de P5a lo exige. La compatibilidad se decide solo en el registro: si la plataforma no admite ese
`record_format`, 409 `schema_mismatch` y la zona sale con código 1 (§8). En un guardado, un `progress_format`
distinto es un error nuestro: 400 `invalid_save` (S1). Las filas son columnas: un formato nuevo es código nuevo en
`internal/progress` (progresion.md P7) y, si hace falta, una migración (§2.4), no una conversión al leer.

### 7.2 Cuándo se guarda
| Momento | Cómo |
|---|---|
| Punto de control | Cada 60 s (`--save-interval=<s>`) si alguna sección está sucia (su `is_dirty`; en `progress`, moverse y la vida cuentan). Cada personaje en su fase (`tick % interval == character_id % interval`): 64 jugadores dan ~1 guardado por segundo |
| Evento crítico | Los de progresion.md §9.2, que es quien mantiene la lista: `CharacterSaver.mark_critical(net_id, reason)`; sale en cuanto no haya otro en vuelo |
| Salida | Al irse el cuerpo (CLIENT_LEAVE, desconexión o fin de los 15 s en combate), en este orden: `CharacterSaver.finish(net_id, LOGOUT)` con `release_lease` → `ScoreKeeper.forget` → `ProgressService.on_departure(net_id)` |
| Baja sin guardado | Un definitivo antes de `finish` (`save_rejected`, §7.3) o un `revoked` `lease_lost` de alguien en el mundo, en este orden: (1) `CharacterSaver.drop(net_id, code)`, que desata la entrada, descarta el final que esperase y llama a `release` salvo en `lease_lost`; (2) NOTICE y expulsión con el cuerpo fuera **en el acto** (`_remove_player`, sin `_should_linger`: la salida en combate no vale aquí, porque el arrendamiento ya no es de la zona o se acaba de liberar); (3) `ScoreKeeper.forget` y `ProgressService.on_departure(net_id)`. No pasa por la «Salida»: `finish` sobre un `net_id` sin entrada no hace nada |
| Cierre ordenado | Los cinco disparadores: `--stop-file`, `--quit-after-ticks`, `--idle-quit`, `shutdown` de la consola y el mantenimiento de la plataforma (`maintenance` del latido: NOTICE a los 10, 5 y 1 min, a los 30 s y a los 10 s, y cierre a su `at_unix`, §12). Todos pasan por `ServerMain._shutdown` → `ZoneServer.stop`: `release` de los peers en `LOADING` y `auth_provider.cancel` de los de `VERIFYING`, `finish` de todos los del mundo antes de `_clear_players()`, `begin_flush` y espera hasta que `pending_count()` sea 0 y `is_flushed()`, con un tope de 600 ticks (10 s) |
| Expulsión de la plataforma | `revoked` del latido (§6) |
| Cierre de la instancia | §6.1 |

- **Una escritura en vuelo por personaje.** Mientras vuela, los cambios solo marcan la sección; al llegar la
  respuesta definitiva se construye el siguiente. La foto se toma **dentro del tick**, tras «altas».
- **El final se construye en el momento** (`finish`): el jugador ya no cambia, así que espera detrás del que vuela
  sin rehacerse. Como mucho uno en vuelo y un final esperando. Lleva solo las operaciones que aún no iban en ningún
  cuerpo (progresion.md §9.2): si el que vuela se aplica, el final no repite nada; si el que vuela recibe un
  definitivo, el final se descarta con él.
- **Una sección que devuelve `{}`** no puede construirse ahora (la de `progress`, sin id para cerrar lo agregado,
  algo que su reserva evita: progresion.md §4.5). Ese guardado no sale ni gasta `seq`: un punto de control o un
  crítico se vuelve a intentar en el `step` siguiente. Un final no puede esperar, porque tras `finish` el estado
  del jugador ya no existe: alerta en el registro y `release` sin guardar, como tras un definitivo.
- **Entradas por `lease_id`.** `CharacterSaver` guarda sus entradas por `lease_id`, que es único por reclamación,
  con dos índices aparte: `character_id` → `lease_id` actual y, hasta `finish` o `drop`, `net_id` → `lease_id`. El
  `net_id` se reutiliza a los 600 ticks (red.md §9.1) y el mismo personaje puede volver a esta instancia con otra
  reclamación mientras su final se sigue reintentando minutos. Cada respuesta se asocia por el `lease_id` y el `seq`
  de su propia petición (el `context` de `ZonePlatform.save`), nunca por `character_id` ni por `net_id`; un `track`
  con otro `lease_id` no toca la entrada vieja.
- **Tras `finish` (o `drop`), la entrada ya no es del `net_id`.** Las respuestas del que volaba y del final no llaman
  a `acknowledge` ni a `is_dirty` de las secciones (su estado ya no existe) ni emiten `save_rejected`: un 200 cierra
  la entrada; un definitivo solo se registra (y, si no es `lease_lost`, `CharacterSaver` llama a `release` de ese
  `lease_id`), sin expulsar a nadie ni volver a llamar a `on_departure`. Si el personaje ya volvió a entrar, el
  `release` del arrendamiento viejo da `lease_lost` en la plataforma y no toca el nuevo.
- **Baja en `LOADING`:** no pasa por `CharacterSaver` (§5.2).
- **Un cuerpo enviado no cambia.** `CharacterSaver` arma el sobre entero de §7.3 (también `zone_instance_id`),
  guarda los bytes (`JSON.stringify` una vez) y los reintentos van byte a byte. `JSON.stringify` y el envío no
  bloquean el tick.
- **Cercado** (§5.3): los guardados siguen saliendo; las operaciones que piden guardado crítico (comandos de GM que
  cambian algo; en la fase 6, comercio y correo) se rechazan. Los críticos del juego (kit, subida de nivel, captura)
  no: se marcan y salen en cuanto se pueda.

### 7.3 Versiones e idempotencia
```json
{"save_format": 1, "character_id": "41", "zone_instance_id": "…", "lease_id": "…", "seq": 17, "reason": 1,
 "release_lease": false,
 "progress": {"progress_format": 1, "level": 7, "…": "ProgressRecord de progresion.md §3.4 sin los campos de solo lectura",
              "ops": [{"op_id": "5120", "kind": 2, "…": "progresion.md §9.3"}]},
 "pvp": {"kills": 3, "deaths": 1, "assists": 0, "captures": 1, "gate_damage": 450, "defend_s": 120}}
```

Es el cuerpo de `PUT /internal/v1/characters/{id}/state`: el sobre (`save_format` 1) con una clave por sección
registrada en `CharacterSaver` (§7.1). **Lo arma entero `CharacterSaver`**, con `zone_instance_id =
platform.instance_id()`, `lease_id` y `character_id` en cadena, antes del único `JSON.stringify`; `ZonePlatform.save`
manda esos bytes sin tocarlos (§14.3). La sección `progress` no lleva zona: la del guardado es la de la instancia
`claimed_by` (`SaveKey.ZoneID`). `seq` empieza en 1 con cada arrendamiento y sube 1 en cada guardado; `reason`: 1
punto de control, 2 crítico, 3 salida, 4 cierre del servidor, 5 expulsión. La clave de idempotencia es **`(lease_id,
seq)`**, y solo ella.

**Secciones.** `progress` es obligatoria. `pvp` es opcional: sin ella, `character_pvp_stats` no cambia; con ella,
cada total se lee con `jsonx.Int` ≥ 0 y se escribe con `greatest(columna, nuevo)`, sin error: los totales no bajan.
Cada uno tiene que caber en su columna: 2^31 − 1 en las cinco `int` (`gate_damage` es `bigint`); si no, `envelope`.
**El sobre** se decodifica estricto (`DisallowUnknownFields`, `jsonx`): `save_format` = 1, `character_id` igual al
`{id}` de la ruta, ids y `seq` válidos, `reason` 1–5 y `progress` presente. Cualquier fallo es 400 `invalid_save` con
`check = "envelope"`, antes de tocar la base. Después, la plataforma, en una transacción:

1. `select … from character_leases where character_id = $1 for update`.
2. Sin fila (el personaje se purgó, §11.2), otro `lease_id`, o `claimed_by` distinto de `zone_instance_id` → 409
   `lease_lost`.
3. `seq = last_seq`: si el SHA-256 del cuerpo es `last_save_hash`, 200 `{applied: false, duplicate: true,
   save_version}` con el `last_save_version` del arrendamiento (el de cuando se aplicó: la plataforma no lee
   `character_progress`); si no, 409 `seq_conflict`. `seq < last_seq` → 409 `stale_seq`.
4. `ProgressStore.Apply(ctx, tx, key, progress)` con las comprobaciones S1–S8 de progresion.md §13.3 (los bloques de
   ids de la instancia incluidos), que escribe `saved_at = now()` y `save_version + 1` en `character_progress` (S8) y
   devuelve el `save_version` nuevo; `character_pvp_stats` con `greatest`, si llega `pvp`; `last_seq = seq`,
   `last_save_hash`, `last_save_version`; con `release_lease`, `zone_instance_id = null` y `released_at`. Si algo
   falla, **no se escribe nada** y la respuesta sale de la regla de abajo.

**Errores del guardado** (la única regla; progresion.md §13.3 la cita):

| Error, en el sobre, en `Apply` o en el COMMIT | Respuesta |
|---|---|
| Error del sobre (arriba) | 400 `invalid_save` con `check = "envelope"` |
| `*persistence.InvalidSaveError` (S1–S7) | 400 `invalid_save` con su `check` y su `detail` |
| SQLSTATE de clase 22 (un dato que la base no admite: un NUL en `jsonb`, un número o una fecha fuera de rango) o 23 (clave primaria, único, clave ajena, CHECK, también los diferidos que salta el COMMIT, como el de ranuras) o `P0001` (el disparador de solo añadir) | 400 `invalid_save` con `check = "S8"` y en `detail` el SQLSTATE y la restricción: es un error determinista, reintentarlo no lo arregla |
| `40001` o `40P01` | Se reintenta la transacción entera dentro de la plataforma (tres veces, como al crear personajes); después, 503 `db_unavailable` |
| Sin conexión con la base, plazo de sentencia vencido | 503 `db_unavailable` |
| Cualquier otro | 500 `internal` |

La zona reintenta el mismo cuerpo ante un 5xx o un 401 y da por definitivo cualquier otro 4xx (tabla de abajo), así
que un fallo pasajero nunca expulsa y uno determinista nunca se reintenta para siempre.

`save_version` es un contador monótono por personaje que **no interviene en la idempotencia**: va en la respuesta
`{applied, duplicate, save_version, instance_status}` y solo lo usan registros, métricas y pruebas; las secciones
confirman por `seq`.

| Respuesta | La zona |
|---|---|
| 200 `applied` o `duplicate` | Aplicado (un `duplicate` es un guardado que llegó y cuya respuesta se perdió): antes de `finish`, cada sección recibe `acknowledge(net_id, seq)` (en `progress`, las `ops` de ese cuerpo y anteriores salen del diario); si hay otro marcado o un final esperando, sale |
| 409 `lease_lost` | Definitivo: la baja sin guardado de §7.2, sin `release`, con NOTICE «Tu personaje ha entrado en otro servidor» |
| 409 `stale_seq` o `seq_conflict` · 400 `invalid_save` | Definitivo y error nuestro: alerta en el registro (con `check` y `detail` en un `invalid_save`) y la baja sin guardado de §7.2, con `release` para que el personaje no quede bloqueado y NOTICE «No se ha podido guardar tu personaje; vuelve a entrar» |
| 409 `instance_lost`, `instance_replaced` o `instance_stopped` | El cierre de §6.1, con guardados finales de todos (los de una instancia sustituida valen si nadie ha reclamado al personaje, §5.3) |
| Cualquier otro 4xx (400 `bad_request` o `validation`, 403, 404, 413, un 409 desconocido) | Definitivo, como `invalid_save`: alerta, NOTICE y la baja sin guardado con `release`. Vale también para la respuesta de una liberación, que entonces no se repite |
| 5xx, 401, sin conexión, plazo vencido | Reintento del **mismo** cuerpo (§6). No sale `seq + 1` hasta tener una de las respuestas de arriba |

Antes de `finish`, los definitivos llegan a la zona con `CharacterSaver.save_rejected(net_id, character_id, code)`:
la zona hace la baja sin guardado de §7.2 (progresion.md §9.2). Después de `finish`, la regla de §7.2: solo se
registran. Esta tabla es la única: progresion.md la cita.

**Tamaño.** Con la plataforma caída, el guardado en vuelo se reintenta y nada más sale, así que el diario solo crece
con las operaciones sueltas; las de GM se rechazan con la zona cercada (§5.3) y DESTROY responde NOT_NOW con 256
operaciones o más sin confirmar (progresion.md §4.2). Así ningún cuerpo llega al 1 MB de §6.

Ejemplo: un guardado vence su plazo de 3 s pero la plataforma lo aplica tarde. El reintento lleva el mismo `seq` y
los mismos bytes: `duplicate`, que la zona trata como aplicado. El siguiente lleva `seq + 1` y solo las `ops`
nuevas, así que S2 de progresion.md (un `op_id` que ya está en `economy_ops` falla) pasa.

El arrendamiento hace a la zona la única escritora. Fuera de la zona nadie escribe el progreso en la fase 5 (la
edición sin conexión es de SOC-37, fase 8); quien lo haga en el futuro cambiará antes `lease_id`. **Regla de los
objetos:** toda operación que mueve objetos o monedas entre dos personajes se guarda en un solo `POST
/internal/v1/saves` con los dos (una sola operación con dos participantes, `op_participants` de progresion.md §3.3);
así un `uid` nunca está en dos filas (la clave primaria de `item_instances` lo impide) y nada se duplica.

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
**En Go.** La interfaz `persistence.ProgressStore` (`internal/persistence/progress.go`) la define P2 de este documento
con un falso, **junto con sus errores** (`*persistence.InvalidSaveError` → 400 `invalid_save`;
`persistence.ErrNotFound` → 404): así P2, P3 y el falso los usan antes de que exista `internal/progress`, que los
devuelve e importa `persistence` (nunca al revés: no hay ciclo). La implementa `internal/progress` (progresion.md
P7). Sus tipos, errores y firmas (`CreateParams`, `SaveKey`, `Summary`, `InvalidSaveError`, `ErrNotFound`, `Create`,
`Load`, `Apply`, `Summaries`, `Purge`, `PurgeRetention`, `Export`, `Op` y `Ledger`) están en progresion.md §13.2 y no
se repiten aquí. En la frontera viaja JSON crudo; dentro, `internal/progress` decodifica estricto (`jsonx.Int`,
`jsonx.ID`, `DisallowUnknownFields`).

- **Validación de la creación.** En el mismo archivo, P2 define `persistence.CreateValidator` y
  `*persistence.ValidationError` (firmas en progresion.md §13.2; el manejador de personajes pasa sus `Fields` tal
  cual a los `fields` del 400 `validation`), con la implementación provisional de §4.4 paso 5. `*progress.Rules` la
  implementa y `serve` elige cuál usar: progresion.md P7 no toca el manejador de personajes.

- **La plataforma no lee columnas del progreso** con SQL propio: la lista de personajes, `enter` y la excepción de la
  reserva del nombre usan `Summaries` (P2 llega antes que la migración 0010); el `save_version` de un `duplicate`
  sale de `character_leases` (§7.3) y las lápidas que ya puede borrar, de `PurgeRetention` (§11.1).
- Arrendamiento y `seq` (pasos 2 y 3 de §7.3) los hace `persistence.Store.Save` antes de llamar a `Apply`.
- **Bloques de ids:** cada `op_id` del cuerpo y cada `uid` nuevo cae en un bloque de `id_blocks` dado a `claimed_by`
  (`SaveKey.InstanceID`); si no, 400 `invalid_save` (S2 y S5: una zona no puede inventar ids de otra).

**En la zona** (GDScript):

| Pieza | Documento | Hace |
|---|---|---|
| `ZonePlatform`, `PlatformClient` | Este (P4) | HTTP, colas, latido, reclamaciones, bloques de ids, eventos |
| `ClaimedCharacter`, `AuthOutcome` | Este (P4) | Lo que trae la reclamación; `progress` va tal cual a `ProgressRecord.from_dictionary` |
| `CharacterSaver` | Este (P5) | Cuándo, `seq`, una en vuelo, final, el sobre entero, respuestas de §7.3 y la baja sin guardado (`drop`); llama directamente a `ZonePlatform.save` |
| `ProgressService`, `PlayerProgress`, `ProgressRecord` | progresion.md | La carga (`prepare`, §5.2) y el alta (`on_arrival`), las operaciones y la sección `progress` |

`CharacterSaver` solo existe con `--platform`: sin plataforma nada se guarda, todo jugador es efímero y
`ProgressService.setup(zone, null, null, commands)` (progresion.md §9.4). Las secciones son `&"progress"`
(`ProgressService.setup`) y `&"pvp"` (`ScoreKeeper`, P6), con la API de §14.3. Las pruebas usan `FakeZonePlatform`,
que hace la ida y vuelta por JSON igual que `PlatformClient` (§14.3) y devuelve en la reclamación siguiente lo último
aplicado (§14.1). Lo acordado con progresion.md está en §17.

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
  3b. `POST /internal/v1/id-blocks`: el primer bloque de ids (progresion.md §4.5), con los mismos reintentos.
     `startup_finished` espera a tenerlo y el bloque llega a `ProgressService` como evento `id_block`.
  4. `ZoneServer.start(…, platform)` aplica las fortalezas cargadas y **después** abre el puerto
     (`NetTransport.host`).
  5. `POST …/live`: desde aquí `enter` manda jugadores. Los latidos empiezan tras el paso 1.
- Cada `*_at_unix` vuelve a ticks con `tick + max(0, at − now_unix) · 60`. `CAPTURING` vuelve como `VULNERABLE` con
  su progreso (el círculo está vacío y decae); los guardias no se guardan (los repone el generador). Sin plataforma,
  como hoy.
- **Guardar:** en cada cambio de dueño o de fase y, si cambió algo (la vida de la puerta), cada 60 s. Un tick futuro
  `t` se escribe como `now_unix + ceili((t - tick) / 60.0)` (en GDScript, `(t - tick) / 60` entre enteros trunca
  antes de redondear y `ceil` devuelve `float`). Una petición en vuelo por fortaleza, siempre con el registro más
  reciente y con `expected_version` (la última que devolvió la plataforma). 409 `version_conflict`: la zona toma la
  `version` del error y reenvía su registro (la instancia viva manda). Solo escribe la instancia `live` de esa zona,
  y la plataforma no deja escribir una fortaleza de otra zona (§6).
- El reinicio a neutral cada 30 min cuenta desde `last_reset_at_unix` (reiniciar el proceso no reinicia el ciclo).
- **Historial:** los `WarEvents` 3 (captura iniciada), 6 (capturado) y 7 (reiniciado) van al lote de `war-events`
  (`{key, fortress_id, event, realm, at_unix}`) → `fortress_events`.
- **Por personaje.** `ScoreKeeper.Entry` (hoy `kills`, `deaths`, `assists`, `gate_damage` y `circle_ticks`) añade
  dos contadores (P6):

| Contador | Lo suma | Cuándo |
|---|---|---|
| `captures` | `FortressController`, al aplicar el cambio de dueño | A cada jugador del reino captor presente, vivo y conectado en el círculo en el tick de la captura, sin GM invisibles ni personajes marcados por un comando de GM (`gm_forced`, progresion.md §6.2). La lista se calcula una vez y la misma va a `ProgressService.on_capture` (la recompensa de progresion.md §6.2). Una captura forzada por un comando del fuerte no suma ni paga (progresion.md §6.2) |
| `defend_ticks` | `FortressController._recount` | A cada jugador del reino **dueño** presente con el círculo activo (`circle_ticks` sigue contando a todos, para los méritos) |

  La sección `pvp` de `CharacterSaver` manda los totales cargados (`ClaimedCharacter.pvp`) más los de la sesión
  (`defend_s` = cargado + `defend_ticks / 60`). Como `finish` construye la foto en el momento (§7.2), va antes de
  `ScoreKeeper.forget`.

## 9. Social y moderación (SOC-13 a SOC-18)
### 9.1 Roles y auditoría (SOC-14)
| Rol | Comandos | Sanciones que puede crear |
|---|---|---|
| `player` | Nada de moderación | — |
| `moderator` | `/gm silenciar`, `/gm aviso`, `/gm expulsar`; etiqueta visible | `warning`; `mute` hasta 7 días |
| `gm` | Lo anterior, `/gm suspender`, `/gm renombrar`, `/gm teleport`, `/gm invisible` y `/gm visible`, los de progresion.md §10 (PRG-16, también las consultas `inv_show`, `ledger_show` y `op_show`) y los comandos del fuerte (con plataforma, lo que provocan no paga nada persistente a nadie, tampoco al GM, y `/gm teleport` y `/gm visible` marcan al personaje que mueven o muestran, que no cobra hasta reaparecer: progresion.md §6.2) | Lo anterior; `suspension` hasta 7 días; `rename` |
| `admin` | Todo, también `/gm banear`, `/gm anuncio` y `/gm apagar` | Lo anterior; `suspension` de más de 7 días; `ban` |

- **El rol** lo pone `admin --actor <correo> set-role <correo> <rol>` y llega en la reclamación. `set-role` **revoca
  las sesiones de la cuenta** (`role_changed`): el latido expulsa al personaje en 5 s como mucho y vuelve a entrar
  con el rol nuevo. Bajar de rol a un GM conectado le quita el poder enseguida. **Su fila de `audit_log` es fija,
  porque S2 la busca:** `source = 'cli'`, `command = 'set-role'`, `actor_account_id` la del `--actor`,
  `target_account_id` la cuenta, `args = {"from": "gm", "to": "player", "os_user": "…"}` y `at = now()`. Con ella,
  S2 da por bueno el actor de una operación que el GM creó antes de perder el rol y que aún se está guardando
  (progresion.md §13.3). S2 solo lee filas `cli`, que una zona no puede escribir (§6, «Lotes»); el índice
  `(target_account_id, command, at)` de 0005 la encuentra.
- **Permiso por comando.** Cada comando del `CommandRegistry` declara su `min_role`; sin permiso o desconocido:
  «Comando desconocido. Escribe /ayuda.». Sin plataforma, como hoy (consola, y DEBUG_COMMAND con
  `--debug-commands`).
- **DEBUG_COMMAND con plataforma** (solo en `dev` y `test`, §5.5) exige además el `min_role` del comando: `gm` para
  los de red (teletransporte, vida, fuerte); `admin` para los que crean o conservan valor de un personaje persistente
  o se saltan su equipo: los 40–43 y el 5, el 13 y el 16 (la lista es de progresion.md §10). Sin el rol, suma un
  aviso como hoy y no se ejecuta ni se guarda nada.
- **Sobre los propios personajes.** Todo comando de progresion.md §10 que cambia algo (`item_give`, `item_take`,
  `currency_add`, `level_set`, `xp_add`, `op_revert`, también por DEBUG_COMMAND) sobre un personaje de la propia
  cuenta exige `admin`, sin excepción por entorno; si no, «No puedes usarlo sobre tus personajes». La regla es de
  progresion.md §10 y S2 la repite en Go, en las operaciones GM y en la REVERSAL de `op_revert`. La auditoría guarda
  siempre `target_account_id`.
- **Invisible.** La entidad del GM no entra en el interés de los demás (`InterestPolicy`), su `Combatant` no hace
  ni recibe daño (`CombatResolver` lo salta), no cuenta en `_presence_candidates` (círculo), ni en `ScoreKeeper`, ni
  en las recompensas de progresion.md (méritos, XP, oro, captura; su §6.2). `/gm visible` lo deshace; los dos van
  auditados.
- **Auditoría:** todo comando de GM, de consola o de depuración con plataforma va al lote de `audit` (`{key,
  actor_account_id, actor_character_id, command, target_character_id, target_account_id, args, at_unix, source}`)
  y al registro de la zona; los de la CLI y las sanciones, directos a `audit_log`. En la entrada:
  `actor_account_id`, la cuenta del GM (la de su reclamación; null desde la consola); `source`, con el vocabulario
  de `audit_log`: `console` desde la consola y `zone` en lo demás (`/gm` y DEBUG_COMMAND), la misma regla que S8;
  `args`, los argumentos con el objetivo por `character_id` en cadena (progresion.md §10); `at_unix`, la hora de la
  zona (`ZonePlatform.now_unix()`). `world_id` y `zone_id` los pone la plataforma desde la instancia (§6). **Las
  lecturas también:** `inv_show`, `ledger_show` y `op_show` (lote de la zona), y `admin reports list|show`, `admin
  audit` y `admin chat` (social.md §8: «registro de cada consulta»).
- **Sin datos personales en la auditoría.** Una regla para toda fila de `audit_log`, sea de la zona, la consola, la
  CLI o la plataforma: el objetivo va en `target_account_id` y `target_character_id`, y `args` nunca lleva un correo
  ni el nombre de un personaje (salvo el término de `names block|unblock`, que ya vive en `name_blacklist`). La CLI
  resuelve correos y nombres a ids antes de escribir (`set-role`, `purge-now`, `chat --character`, `audit
  --target`…) y `sanction_denied` guarda el id resuelto, no el `target_name`. Así la purga (§11.2) no deja correos
  ni nombres en la auditoría ni en las copias.
- **Dos vías, una fila.** La entrada del lote lleva `key = "<zone_instance_id>:<secuencia>"`, salvo la de un comando
  que crea una operación (progresion.md §10: una GM, o la REVERSAL de `op_revert`), que lleva `key = "op:<op_id>"`:
  el guardado escribe la misma fila en su transacción (S8 de progresion.md §13.3) y las dos van con `on conflict
  (event_key) do nothing`, así que, llegue antes una u otra, ni se duplica ni se pierde. Para que coincidan, las dos
  llevan los mismos campos con los mismos valores: S8 los saca de la operación (`world_id` y `zone_id` de la
  instancia, `SaveKey`; `source` con la regla de arriba; `command`, `args`, `actor_character_id` y `at_unix` de
  `detail`; `actor_account_id`, `target_character_id` y `target_account_id`) y la zona los pone igual en el lote.
  `audit_log.at` es `to_timestamp(detail.at_unix)` en las dos: la hora en que la zona creó la operación, no la de
  aplicarla, que con reintentos puede llegar minutos después.
- **La CLI tiene identidad.** Toda orden `admin` exige `--actor <correo>` de una cuenta `admin` (o `moderator` para
  las de lectura: `reports list|show`, `audit`, `chat`); sin él, o con otra cuenta, no se ejecuta (código 2). Sus
  filas llevan `source = 'cli'`, en `command` el nombre de la orden (`set-role`, `purge-now`, `reports show`…) y en
  `actor_account_id` la cuenta del `--actor`, y guardan en `args.os_user` el valor de `$SUDO_USER` o `$USER`. Consulta: `admin
  --actor <correo> audit --since 2026-11-01 [--actor-name <nombre>] [--target <nombre>]`.

### 9.2 Registro del chat (SOC-15)
`ChatRouter` (SOC-04) pone cada mensaje ya saneado en el lote de `chat` (`{key, channel, sender_character_id,
target_character_id, text, sent_at_unix}`); la plataforma rellena `world_id`, `zone_id` y `zone_channel` (la copia
de la zona, el `channel` de la instancia) desde la instancia y `sender_account_id` desde `characters` (§6). Así se
sabe el alcance de «zona» (esa zona y esa copia, social.md §2) y el destinatario de un susurro; el de «grupo» (qué
grupo) no se guarda: en la fase 5 un grupo no tiene identidad persistente. Retención de 30 días (§11.1). Consulta:
`admin --actor <correo> chat --character <nombre> --from … --to …`, que queda auditada (con el personaje por id).

**Ritmos del chat por personaje.** Con plataforma, `ChatRouter` guarda el `ChatPeerState` (cubos, último texto,
descartes y destinatarios recientes; social.md 12.7) por `character_id`, no por conexión: al irse el personaje lo
conserva `KNOWN_RECIPIENT_TICKS` (5 min) y, si vuelve a entrar en esta instancia, se lo reengancha. Así salir y
volver a entrar no rellena las ráfagas. Sin plataforma, por conexión, como en la fase 4.

### 9.3 Ignorados (SOC-16)
- `/ignorar nombre` → zona → `POST /internal/v1/ignores` con el `character_id` de quien ignora: la plataforma
  comprueba que tiene arrendamiento en esa instancia, resuelve la cuenta del nombre (en el mundo de la instancia, §6) y guarda
  `(cuenta, cuenta ignorada, personaje nombrado, nombre)`. Hasta 100. La lista que ve el jugador solo enseña los
  nombres que él escribió.
- La zona tiene, por jugador, las cuentas que ignora (llegan en la reclamación) y la cuenta de cada personaje. **El
  servidor descarta** los susurros, invitaciones y (fase 6) correo de una cuenta ignorada, y la quita de los
  destinatarios de los canales públicos: el cliente no puede ocultarla sin saber qué personajes comparten cuenta, y
  eso no se le dice. social.md §10 y SOC-16 lo dicen ya así.

### 9.4 Reportes (SOC-17)
`/reportar nombre categoría [comentario]` o el menú social. La zona adjunta los últimos 20 mensajes de ese personaje
que **recibió** quien reporta en 10 min (un anillo por receptor en `ChatRouter`), zona, posición y tick, y manda
`{zone_instance_id, reporter_character_id, target_name, category, comment, context, evidence:
[{sender_name, channel, text, sent_at_unix}]}`. La plataforma comprueba que quien reporta tiene arrendamiento en esa
instancia, impone 1 por objetivo cada 10 min y 10 por hora por cuenta (429), copia la prueba a `report_evidence` y la
zona contesta «Reporte enviado. Gracias.». Revisión: `admin --actor <correo> reports list|show|close` (auditadas).

### 9.5 Sanciones (SOC-18)
| Tipo | Dónde se aplica |
|---|---|
| Aviso | Al entrar, NOTICE con el motivo: la reclamación trae los avisos que la cuenta no ha visto y el primer guardado del arrendamiento los da por vistos (`characters.last_entered_at` = la hora de la reclamación). Si la zona suelta al personaje sin que llegue al mundo (`REALM`, `FULL`, `prepare` o la baja en `LOADING`), salen en la reclamación siguiente |
| Silencio | `ChatRouter` descarta y contesta «Estás silenciado N min más»; llega en la reclamación y en `mutes` del latido |
| Suspensión, expulsión permanente | Inicio de sesión (tras la contraseña, solo la sesión de privacidad de §4.2) y `enter` (403 con fin y motivo), reclamación (`BANNED`) y latido (`revoked`: guardado final y expulsión) |
| Renombrado forzado | `characters.must_rename`: `enter` → 409 `rename_required` |

Toda sanción lleva motivo, autor, `ends_at` y sus reportes, con la escala de social.md §9. La crean `/gm …` (por
`POST /internal/v1/sanctions`) o `admin --actor <correo> sanction …`. **La plataforma autoriza**, en la transacción
de la sanción:

1. El autor (`author_character_id`) tiene arrendamiento en esa instancia (`zone_instance_id`).
2. Su cuenta tiene el rol mínimo de la tabla de §9.1 para ese `kind` y esa duración.
3. La cuenta objetivo (el `target_name` en el mundo de la instancia) tiene un rol **menor** que el del autor.

Si falla alguna: 403 `forbidden` y una fila en `audit_log` con `command = 'sanction_denied'` (el objetivo, por id;
§9.1). La CLI pasa las mismas
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
  `!*.env.example`, `platform/deploy/secrets/`, `*.pem`, `*.key` y `!tests/fixtures/**/*.pem` (comprobado en un
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
| `report_evidence`, reportes cerrados, `audit_log` | 1 año (desde el cierre en los reportes) | Trabajo horario. Un reporte sin cerrar al año de crearse pasa a `dismissed` (`closed_at = now()`, `resolution = 'caducado'`) y cuenta desde ahí |
| `auth_events`; IP y agente de `sessions` | 30 días | Trabajo horario (la IP de la sesión pasa a null) |
| `sessions` y `account_tokens` caducados · `enter_tickets` · `zone_instances` paradas · `outbound_mail` | 7 días · 1 día · 30 días · 7 días | Trabajo horario |
| Cuenta sin verificar (`staging`, `production`) | 7 días | Purga (§11.2) |
| Personaje borrado | 7 días restaurable; luego lápida; el nombre, 30 días más (o nada, §4.4) | Purga horaria |
| Libro, operaciones y eventos de objeto de un personaje vivo, también el `actor_account_id`, la `note` y el `detail` de las operaciones GM y REVERSAL (una segunda huella de esos comandos de GM, aparte de `audit_log`) | Mientras exista el personaje; tras su purga, la fila de abajo | Ninguno: son de solo añadir (progresion.md §3.5). La exportación los da sin los datos del personal (§11.2). **Revisión legal** (también de `note` y de que no tenga plazo) |
| Libro, operaciones y eventos de objeto de un personaje purgado | **1 año** desde la purga. Sin nombres: la lápida no lo tiene y `detail.args` nombra al objetivo por id (progresion.md §10). Mientras la cuenta exista, ligados a ella y exportables (§11.2); seudónimos solo tras purgarla. La `note` de las operaciones GM y REVERSAL se conserva como dato de moderación | Retención horaria: `ProgressStore.PurgeRetention` (progresion.md §3.5), con `set local eldmark.retention_purge = 'on'`; luego se borran las lápidas que devuelve vacías. **Revisión legal** (también de `note`) |
| Cuenta borrada | 14 días de gracia | Purga (§11.2) |
| Sanciones | Mientras exista la cuenta; al purgarla, sin motivo, y 1 año más | La purga vacía `reason`; el trabajo horario borra las de las cuentas con `purged_at` de hace más de 1 año. **Revisión legal** |
| `sanctioned_email_hashes` | Hasta el fin de la sanción, o 90 días tras ella; 1 año como mucho | Trabajo horario. **Revisión legal** |
| Copias diarias y semanales, WAL | 35 días; al restaurar se vuelven a aplicar las purgas (§12) | `backup.sh` y WAL-G |
| Registros de los contenedores (zona, plataforma) | 30 días: la zona escribe nombre e IP en cada conexión y rechazo | journald (`MaxRetentionSec=30day`, §12) |
| `fortress_events`, `realm_resources` | Sin límite: no son personales | — |

En `staging` y `production` con `--platform`, la zona no admite `--battle-log`, `--combat-log` ni `--state-log`
(escriben nombres sin plazo; §5.5).

### 11.2 Exportación y supresión
**Exportar:** `POST /v1/account/export {password}` (1 al día; también con la sesión de privacidad de una cuenta
sancionada, §4.2) da `eldmark-datos-<fecha>.json`: cuenta (sin el
hash), aceptaciones, consentimientos, sesiones y accesos de 30 días, derechos, personajes con su progreso (por cada
personaje no purgado, `ProgressStore.Export` bajo `characters[i].progress`: registro, operaciones, apuntes y eventos
propios; y por cada lápida de la cuenta con libro retenido, lo mismo sin registro; progresion.md §3.5) y
estadísticas, ignorados (por nombre), sanciones propias, reportes **hechos** y chat enviado por sus personajes en
plazo. No da reportes recibidos ni notas de moderación (de terceros: **revisión legal**): de las operaciones GM y
REVERSAL da el tipo, la fecha, los apuntes y los eventos, sin `actor_account_id`, `note` ni `detail`.

**Purgar un personaje** (al vencer `restore_until`, con la cuenta, o en `reapply-purges`), en una transacción:

1. `select … from character_leases where character_id = $1 for update`, si hay fila.
2. `select … from characters where character_id = $1 for no key update`, y vuelve a mirar si toca, según el
   camino. **Al vencer `restore_until`**: `deleted_at` no nulo, `restore_until ≤ now()` y `purged_at` nulo (si lo
   han restaurado o ya está purgado, no hace nada). **Con la cuenta y en `reapply-purges`**: solo `purged_at`
   nulo, porque manda la cuenta o `purge_log`: los personajes vivos de una cuenta que se purga nunca se borraron, y
   una copia anterior al borrado los trae con `deleted_at` nulo.
3. Con un arrendamiento vivo (`zone_instance_id` no nulo y `expires_at > now()`), no purga (ni la cuenta que lo
   incluye): la purga horaria lo vuelve a intentar en la hora siguiente. No vale en `reapply-purges`, que corre sin
   arrendamientos (abajo).
4. `ProgressStore.Purge(ctx, tx, id)` (progresion.md §3.5: borra el estado del progreso y deja lo de solo añadir),
   `delete from character_pvp_stats`, `character_leases` y `enter_tickets` de ese personaje,
   `character_names.character_id = null`, `update characters set name = null, name_key = null, purged_at = $t` e
   `insert into purge_log ('character', id, $t)`, con `$t = now()` (en `reapply-purges`, el de `purges.txt`).

El orden de los bloqueos es el de `persistence.Store.Save` (primero el arrendamiento; la fila de `characters` el
guardado solo la toca con la clave ajena de `op_participants`, que `for no key update` no bloquea): no hay
interbloqueo, la purga ve todo lo que un guardado confirmó antes, y un guardado que llega después no encuentra
arrendamiento (409 `lease_lost`, §7.3). Restaurar bloquea la cuenta y la misma fila de `characters` (§4.4) y la reclamación
exige `deleted_at` y `purged_at` nulos (§5.3). Queda la **lápida** (id, mundo, reino, cuenta y fechas) y lo de solo
añadir, que la retención de §11.1 borra al año; después se borra la fila de `characters`. Es la única lápida del
personaje (no hay otra en el progreso). Comprobado: borrar la fila del personaje con apuntes falla (clave ajena) y la
lápida va bien.

**Suprimir la cuenta:** `POST /v1/account/deletion` (también con la sesión de privacidad) → 14 días → purga en una
transacción, que bloquea primero la fila de `accounts` (cuenta → arrendamientos → personajes, el orden de la
reclamación, §5.3): sus personajes (como arriba; nombres reservados 30 días), ignorados en los dos sentidos, sesiones, tokens, consentimientos, aceptaciones,
derechos, el `reason` de sus sanciones y el chat de sus personajes no copiado a un reporte. La fila de `accounts`
queda como lápida (`email` y `password_hash` a null, `status = 'purged'`, `purged_at`) para que auditoría y sanciones
no apunten a nada; `purge_log ('account', id)`. `admin --actor <correo> purge-now <correo>` hace lo mismo sin esperar
(petición expresa): antes revoca las sesiones (`deletion`), espera hasta 30 s a que se liberen los arrendamientos
(el latido expulsa con guardado final) y, si alguno sigue vivo, responde `character_busy` y no purga nada.

**Correos sancionados.** Si la cuenta tiene una suspensión o una expulsión vigente, o una sanción de los últimos 90
días, la purga guarda `HMAC-SHA256(ELDMARK_EMAIL_HMAC_KEY, correo normalizado)` en `sanctioned_email_hashes` con
`until` = fin de la sanción (o + 90 días), 1 año como mucho desde la purga. El registro lo consulta (§4.2): la escala
de social.md §9 sigue contando aunque el jugador pida la supresión y vuelva. **Revisión legal**; va también en
`privacy-1.md`.

**Copias.** `backup.sh` copia `purge_log` (con `purged_at`) a `purges.txt` junto a cada copia y conserva siempre el
más reciente. Restaurar es siempre `pg_restore` y luego `eldmark-platform admin --actor <correo> reapply-purges
purges.txt` con el `purges.txt` **más reciente** (no el de la copia): vuelve a purgar cuentas y personajes con el
`purged_at` de `purge_log`, no con `now()`, y de él salen el año del libro, el de las sanciones y el tope de
`sanctioned_email_hashes`: restaurar no alarga ninguna retención. Corre con las zonas paradas y **antes de
arrancar `serve`** (la gracia de §2.5 alargaría los arrendamientos restaurados): primero borra todos los
`character_leases` y `enter_tickets` de la copia, que ya no son de nadie, y después purga. Es idempotente y sale con
código distinto de 0 si algún id de `purges.txt` queda sin purgar. `restore_check.sh` lo hace también.

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
| Restauración semanal | `restore_check.sh <copia> <purges.txt>`: clúster efímero, `pg_restore` (comprobado: 1000 filas en 188 ms), `reapply-purges`, `migrate status` al día y consultas de integridad (personajes sin cuenta, arrendamientos de instancias inexistentes, ids de `purge_log` con datos personales: 0; y ninguna fila de `audit_log` cuyo `args` contenga el correo de una cuenta de `purges.txt`, que lee de la copia antes de `reapply-purges`) | Ejecutarlo cada semana y alertar si falla (TEC-31) |

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
| Cuenta sancionada | Con la sesión de privacidad (§4.2): el motivo y la fecha de fin, y solo Descargar mis datos, Borrar la cuenta y Cerrar sesión | Esc cierra sesión |
| Selección (UI-23) | Lista a la izquierda (nombre, emblema del reino, nivel, última zona; los borrados en gris con «Restaurar» y su fecha límite), vista 3D del elegido (`HumanoidVisual` con su apariencia, `CharacterAppearance.decode` y `AppearanceApplier.apply` de progresion.md P3 y P6, y los colores de su reino; mientras falten, el humanoide con esos colores), huecos libres («Los borrados que aún puedes restaurar ocupan hueco»), Entrar, Crear, Borrar (confirmación escribiendo el nombre), Cerrar sesión | Flechas eligen, Intro entra, Supr borra |
| Creación (UI-24) | 1) Reino: tarjetas con lore, emblema y capital; fijado al de la cuenta; Askarra «Próximamente». 2) Cuerpo y apariencia (cuerpo, cabeza, pelo, colores, aleatorio con `CharacterAppearance.random`, cámara orbital con el ratón) con lo que haya de ART-19 y ART-20 (`AppearanceApplier.apply`); sin ello, el humanoide con los colores del reino. 3) **Plantilla de inicio** (tarjetas de las plantillas de `starter_templates`, las `selectable` de PRG-07: armas y estilo; es el kit de la primera entrada, progresion.md §2.5). 4) Nombre validado con `NameRules` al escribir y con `name-check` tras 500 ms quieto. Crear | Esc vuelve un paso |
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
el personaje si no existe (con la primera plantilla por `id` de las reglas y `CharacterAppearance.default_for(catalog,
raza)`) y conecta. Un fallo
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
| **P1 · cuentas** (TEC-23, TEC-41, aceptación de TEC-43) | `passwords`, `accounts` (`CheckPassword`, fallos por cuenta y grupo), sesiones con rotación en la fila, límites, ciclo de vida, `revert_email`, `mail`, páginas `/verify`, `/reset`, `/revert`, `/v1/status`, `/v1/legal`, purga de cuentas sin verificar, sesión de privacidad de las cuentas sancionadas (`sessions.scope`, §4.2) | P0 |
| **P2 · personajes** (TEC-24, SOC-13, PRG-41) | `names` y `tests/fixtures/names/`, `gamedata` (sección `names` de `progression_rules.json` y su embed), la interfaz `ProgressStore` con sus errores (`InvalidSaveError`, `ErrNotFound`) y su falso, `CreateValidator` con `ValidationError` y la validación provisional (§4.4 paso 5, §7.5), personajes, reinos, huecos, límites de crear y borrar, borrar y restaurar con el bloqueo de la cuenta (§4.4), `enter` (un personaje en el mundo por cuenta), `tickets` | P1 (progresion.md P7 aporta `*progress.Rules` y el almacén con `Summaries`; `serve` los elige sin tocar los manejadores) |
| **P3 · API interna** (TEC-24, TEC-25) | `zones` (tokens por despliegue, registro, `live`, latido, perdidas, sustitución, estados de §6.1), reclamación (bloqueo de la cuenta y un personaje en el mundo por cuenta, §5.3), guardado (sobre estricto, arrendamiento, `seq`, hash, `last_save_version`, `pvp` con `greatest`, errores de §7.3), liberación, lotes (con rechazo por entrada y `zone_channel` en el chat), `uid_block_seq` e `id_blocks`, rutas de bloques, operación y libro (con arrendamiento) sobre la interfaz `ProgressStore`, fortalezas (solo las de la zona de la instancia, §6); el falso de `ProgressStore` en las pruebas | P2 |
| **P4 · billete en la zona** (TEC-24) | `HandoffTicket`, `TicketAuthProvider`, `AuthProvider` y `ServerAuth` ampliados, `VERIFYING` (cupo y plazo), baja en `LOADING` (§5.2), REJECT 10–12, `PROTOCOL_VERSION` 7 y `AUTH_TIMEOUT_SECONDS` (la subida de toda la fase 5; progresion.md P4 añade lo suyo sin subirla, §5.4), bit GM, red.md (lo de aquí de la v7, §5.4), `ZonePlatform` (con `RECORD_FORMAT`, el conjunto del latido, `save` con `lease_id` y `release_lease`, y los `kind` de `PlatformEvent`, §14.3), `PlatformClient` (prioridades), `ClaimedCharacter`, `AuthOutcome`, `tests/fake_zone_platform.gd` con su API de pruebas (§14.3; guarda por personaje lo último aplicado de cada sección y lo devuelve en la reclamación siguiente: `pvp` aquí; `progress` sin `ops`, con los campos de solo lectura de la reclamación anterior y `location.saved_at_unix` puesto, lo añade progresion.md P5a), `tests/support/fake_http_server.gd`, opciones de `ServerConfig`, arranque de §8 (registro, `env`, `live`), cercado, sin `REJECT NAME` con billete (§5.4) | habilidades.md fusionado: H2 (protocolo 6) y H3c (lo último de habilidades.md en `zone_server.gd`). Los contratos de P3 (no su código: usa los falsos) |
| **P5 · guardado en la zona** (TEC-25; ganchos de CMB-30 y GUE-19) | `CharacterSaver` (secciones, sobre entero, entradas por `lease_id`, `track` al crear la entidad, `on_platform_event`, `save_rejected`, `drop`), salida en combate, baja sin guardado (§7.2), cierre ordenado (`begin_flush`, `_drain_stop` ampliado, `SHUTDOWN_MAX_FRAMES`, liberación de `LOADING` y `VERIFYING`), cuenta atrás del mantenimiento, `revoked`, cierre de §6.1 (`instance_closed` en `ServerMain`) | P4 (se prueba con una sección falsa; la de `progress` es de progresion.md P5a) |
| **P6 · guerra** (GUE-19) | `FortressPersistence`, carga al arrancar, `expected_version`, eventos, `ScoreKeeper.captures` (sin las forzadas por un comando ni los personajes con `gm_forced`, progresion.md §6.2) y `defend_ticks`, la marca de cambio forzado en `FortressController`, el campo `NetEntity.gm_forced` (falso por defecto; la reaparición lo quita), sección `pvp` | P3, P5 |
| **P7a · moderación en Go** (SOC-14 a SOC-18) | Roles, `set-role` que revoca (con su fila fija de §9.1), auditoría (también de lecturas, sin correos ni nombres, §9.1), chat, ignorados, reportes, sanciones con autorización, CLI `admin` con `--actor` | P3 |
| **P7b · moderación en la zona** (SOC-14 a SOC-18) | `min_role` en `CommandRegistry` y DEBUG_COMMAND con rol (probados con comandos de red y de moderación; los 40–43, el `admin` del 5, el 13 y el 16 y la regla de los propios personajes son de progresion.md P5d), `/gm`, invisible, poner `gm_forced` con `/gm teleport`, `/gm visible` y los DEBUG_COMMAND 1, 2 y 4 (progresion.md §6.2), filtrado de ignorados, anillo de reportes, silencios, lotes de chat y auditoría, respuestas de `ignore`, `report` y `sanction`, `ChatPeerState` por `character_id`, conservado `KNOWN_RECIPIENT_TICKS` tras la baja y reenganchado al entrar (§9.2) | P5, P7a; SOC-03, SOC-04 |
| **P8 · cliente** (UI-22 a UI-24) | `ClientConfig`, `PlatformApi` (un refresco a la vez), `AccountSession`, `AccountFlow`, `FrontMain`, pantallas, `NetClient` y `OnlineMain` con billete, pantalla de cuenta sancionada (sesión de privacidad), bot con cuenta | Contratos de P1 y P2 (con `request_hook` hasta tenerlos); progresion.md P3 y P6 (apariencia), ART-19 y ART-20 para la creación completa |
| **P9a · privacidad** (TEC-43) | Exportación (también las lápidas con libro), purgas (bloqueos, lápidas, `purge_log`), retenciones (reportes sin cerrar, sanciones de cuentas purgadas), `sanctioned_email_hashes`, `reapply-purges` con el `purged_at` original, borradores legales | P1–P3; progresion.md P7 (`Purge`, `PurgeRetention`, `Export`) |
| **P9b · operación** (TEC-28) | Caddy, compose (journald, secretos), `dev.sh`, `backup.sh` con `purges.txt`, `restore_check`, `pitr_check` | P9a; TEC-20 para las imágenes de las zonas |
| **P9c · DTLS** (TEC-27) | `NetTransport.host`/`connect_to` con `TLSOptions`, `--dtls-*` en `ServerConfig` y `ClientConfig`, `SwarmBot`, campaña de medida y su anotación en red.md §14 | P4 |
| **P10 · extremo a extremo** | `platform/e2e` y su trabajo de CI (§15) | P3, P4, P5, P8; progresion.md P7 |

P0 primero; luego P1 y, en cuanto habilidades.md esté fusionado, P4 (contra los falsos); luego P2, P3 y P8; luego P5,
P6, P7a y P7b; P9a, P9b, P9c y P10 al final. El almacén del progreso (0010, `internal/progress`) es progresion.md P7,
con las dependencias de su §14.1 (entre ellas, los casos de progresion.md P5a, que llega después de P4 y P5 de aquí);
P9a y P10 lo esperan. P4 de aquí sube el protocolo a 7, sobre la 6 de habilidades.md, y progresion.md P4 añade lo
suyo (§5.4). **`zone_server.gd`**, con los tres documentos, en este orden: habilidades.md H3c → P4 → progresion.md P4
→ P5 → progresion.md P5a → progresion.md P5b → P6 → progresion.md P5c → P7b → progresion.md P5d. Entre documentos se
cita siempre con el nombre delante («plataforma.md P4»).

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
func (s *Service) CheckPassword(ctx context.Context, accountID int64, email string, password string,
	ip netip.Addr) (bool, error)  // ErrThrottled → 429; clave: accountID si ≠ 0, si no SHA-256(email normalizado)
// internal/jsonx: type Int int64 (acepta 4 y 4.0); type ID int64 (cadena decimal de 0 a 2^63 − 1; sin comillas, error)
// internal/names: func Validate(name string) Reason (valores de NameRules.Reason); func NormalizeKey(name string) string
//   casos: os.ReadFile("../../../tests/fixtures/names/name_rules_cases.json")
// internal/testdb: func Main(m *testing.M) int (en TestMain); func New(t testing.TB) *pgxpool.Pool (base nueva)
// internal/zones
type Scope struct { WorldID int16; ZoneID string; Channel int16 }
func (r *Registry) Authenticate(bearer string) (Scope, bool)         // SHA-256 y subtle.ConstantTimeCompare
// internal/persistence
func (s *Store) Claim(ctx context.Context, instance [16]byte, ticketID, characterID int64) (ClaimResult, error)
func (s *Store) Save(ctx context.Context, characterID int64, raw []byte, req SaveRequest) (SaveResult, error)  // raw: para el hash
func (s *Store) SaveMany(ctx context.Context, instance [16]byte, raws [][]byte, reqs []SaveRequest) ([]SaveResult, error)  // todo o nada
func (s *Store) Release(ctx context.Context, characterID int64, instance, leaseID [16]byte) error
// internal/persistence/progress.go (P2): ProgressStore, InvalidSaveError, ErrNotFound, CreateValidator y
//   ValidationError (progresion.md §13.2), con el falso del almacén y la validación provisional (§4.4 paso 5);
//   los implementa internal/progress (progresion.md P7), que importa persistence
```

### 14.3 Contratos en GDScript (zona)
```gdscript
# scripts/server/auth_provider.gd (amplía; DevAuthProvider: OK al instante, uses_tickets() false y on_platform_event false)
const PENDING: int = -1
func authenticate(peer_id: int, hello: NetMessages.Hello) -> int  # OK, PENDING o motivo de REJECT
func on_platform_event(event: PlatformEvent) -> bool  # true si era suyo (kind claim)
func take_completed() -> Array[AuthOutcome]     # los PENDING resueltos, en orden de llegada
func cancel(peer_id: int) -> void               # el peer se fue en VERIFYING: libera si llegó a reclamar
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
var progress: Dictionary      # la sección progress tal cual llega; la lee ProgressRecord.from_dictionary (progresion.md §14.2)
var pvp: Dictionary           # {kills, deaths, assists, captures, gate_damage, defend_s} ya con int()
static func from_claim(body: Dictionary) -> ClaimedCharacter      # null si falta algo; ids con to_int() y enteros con int()
# scripts/server/platform/zone_platform.gd (tests/fake_zone_platform.gd: class_name FakeZonePlatform extends ZonePlatform)
class_name ZonePlatform extends Node
signal startup_finished(ok: bool, error: String)                  # tras el registro, las fortalezas y el primer bloque (§8)
const RECORD_FORMAT: int = 1                                      # record_format del registro (§7.1) = ProgressRecord.FORMAT
var timeout_s: float = 3.0
func start(config: ServerConfig, secrets: Dictionary) -> void     # registro (starting), latidos, fortalezas, primer bloque
func fortress_records() -> Array[Dictionary]                      # las cargadas en start
func env() -> StringName                                          # &"dev", &"test", &"staging" o &"production"
func instance_id() -> String                                      # zone_instance_id; "" antes del registro
func go_live() -> void                                            # POST …/live, tras abrir el puerto
## Conjunto del latido {character_id: lease_id} (§5.3): entra con el 200 de claim, cambia con otro claim del mismo
## personaje y sale con release() o con la respuesta definitiva de un save con release_lease, si sigue siendo ese lease_id.
func claim(peer_id: int, ticket: HandoffTicket) -> void
func claimed(character_id: int) -> ClaimedCharacter               # la última reclamación de ese personaje
func release(character_id: int, lease_id: String) -> void         # pendientes por lease_id; un 4xx es definitivo (§7.3)
func save(character_id: int, lease_id: String, body: PackedByteArray, release_lease: bool,
		context: Variant) -> void   # body: el sobre entero de CharacterSaver, que se manda sin tocar hasta una definitiva
func request_id_block() -> void                                   # el resultado, evento id_block para ProgressService
func put_fortress(fortress_id: StringName, record: Dictionary) -> void  # una en vuelo por fortaleza; la más reciente
func enqueue_batch(kind: StringName, entry: Dictionary) -> void   # &"chat", &"audit", &"war"; pone key si la entrada no
		# trae una ("<zone_instance_id>:<n>"); la que la trae (op:<op_id>) la conserva
func request(kind: StringName, method: HTTPClient.Method, path: String, body: Dictionary, priority: int,
		context: Variant) -> void                                 # pone zone_instance_id: en la consulta de un GET, en
		# el cuerpo de los demás; quien llama no lo pone. kind: &"progress_op", &"progress_ledger", &"ignore",
		# &"report" o &"sanction"
func take_events() -> Array[PlatformEvent]                        # en el paso «poll»; los kind de abajo
func begin_flush() -> void                                        # cierre: lotes y guardados pendientes salen ya
func is_flushed() -> bool                                         # nada en cola ni en vuelo
func is_fenced() -> bool                                          # sin latido aceptado en 2 × heartbeat_s
func is_live() -> bool
func now_unix() -> int                                            # reloj corregido
# tests/fake_zone_platform.gd (P4): sin red; ida y vuelta por JSON como PlatformClient y respuestas en el «poll»
# siguiente (o tras delay_s). Es la única API de pruebas: la usan las de los dos documentos.
class_name FakeZonePlatform extends ZonePlatform
var fake_env: StringName = &"test"                                # el env del registro falso
var next_block_first: int = 1025                                  # cada bloque (uno dentro de start, antes de
		# startup_finished, y uno por request_id_block) sale como evento id_block {first, count: 1024} y sube 1024
func add_character(character_id: int, account_id: int, role: StringName, realm: int, progress: Dictionary,
		pvp: Dictionary = {}, display_name: String = "") -> void   # lo que devuelve su reclamación (lease_id nuevo en
		# cada una; sin nombre, NameRules.bot_name(id)); sin él, 409 ticket_invalid
func script_next(kind: StringName, status: int, body: Variant, delay_s: float = 0.0) -> void
		# la siguiente petición de ese kind (claim, save, release, heartbeat, id_block, progress_op, progress_ledger,
		# ignore, report, sanction…) recibe esa respuesta, una vez; status 0 = sin conexión (transport_ok false);
		# body FakeZonePlatform.DEFAULT = la respuesta por defecto con ese estado y ese retraso (P4, §19.8)
func set_fenced(fenced: bool) -> void                             # is_fenced() lo devuelve hasta cambiarlo
func applied(character_id: int) -> Dictionary                     # el último cuerpo aplicado; {} si ninguno
func sent(kind: StringName) -> Array[Dictionary]                  # los cuerpos recibidos de ese kind, en orden
## Por defecto: claim → 200 con lo de add_character y, si hubo guardados, lo último aplicado de cada sección (§14.1);
## save → 200 applied con save_version que sube; release → 204; heartbeat → 200 sin revoked; progress_op y
## progress_ledger → 404; lotes → 204. progresion.md P5a añade solo la parte progress de la reclamación siguiente y
## static func claim_progress(race_id: StringName, appearance: PackedByteArray, starter_template_id: StringName)
## -> Dictionary, que la construye con ProgressRecord.new_character() y to_claim_dictionary(now_unix()).
# scripts/server/platform/character_saver.gd (P5)
class_name CharacterSaver extends RefCounted
enum Reason { CHECKPOINT = 1, CRITICAL = 2, LOGOUT = 3, SHUTDOWN = 4, KICK = 5 }
signal save_rejected(net_id: int, character_id: int, code: String)   # lease_lost, invalid_save…: la zona expulsa.
		# Solo antes de finish: después, el definitivo solo se registra (§7.2)
func _init(platform: ZonePlatform, interval_ticks: int = 3600) -> void   # solo con --platform
## Entradas por lease_id, con los índices character_id → lease_id actual y, hasta finish o drop, net_id → lease_id;
## cada respuesta se asocia por el lease_id y el seq de su context (§7.2). Arma el sobre entero de §7.3.
## build(net_id: int, seq: int) -> Dictionary: una vez por seq; el cuerpo serializado se guarda y se reenvía byte a byte;
##   {} = no se puede construir ahora (§7.2)
## acknowledge(net_id: int, seq: int) -> void: tras 200 applied o duplicate, solo antes de finish
## is_dirty(net_id: int) -> bool: si hay algo que guardar en el punto de control; solo antes de finish
func register_section(section: StringName, build: Callable, acknowledge: Callable, is_dirty: Callable) -> void
func track(net_id: int, character_id: int, lease_id: String, tick: int) -> void   # al crear la entidad, antes de on_arrival
func mark_critical(net_id: int, reason: StringName) -> void           # reason: solo registro y métricas (progresion.md §9.2)
func step(tick: int) -> void                                          # tras «altas»
func finish(net_id: int, reason: int) -> void                         # foto en el momento, con release_lease; desata el
		# net_id. Sobre un net_id sin entrada (ya pasó por drop), nada
func drop(net_id: int, code: String) -> void                         # baja sin guardado (§7.2): desata, descarta el final
		# que esperase y llama a release salvo con code lease_lost. Sobre un net_id sin entrada, nada
func on_platform_event(event: PlatformEvent) -> bool                  # true si era la respuesta de un guardado
func pending_count() -> int
```

- `PlatformEvent` (`kind`, `context`, `transport_ok`, `status`, `body`, `error_code`) es el resultado de una
  petición, con `body` ya leído: `null` si el cuerpo está vacío o el estado es 204; si no, `JSON.new().parse(texto)`
  y, si falla, `body = null` y `error_code = "bad_json"`. Nunca `JSON.parse_string`, que escribe un ERROR del motor
  ante un cuerpo vacío o roto (`battle_summary.gd` ya lo evita así) y el ejecutor lo cuenta como fallo.
  `FakeZonePlatform` lee igual. Cada lector convierte lo suyo (ids con `to_int()`, enteros con `int()`):
  `ClaimedCharacter.from_claim` la cuenta, el personaje y `pvp`; la sección `progress` llega tal cual a
  `ProgressRecord.from_dictionary`, que hace lo mismo (progresion.md §3.4).
- **`PlatformEvent.kind`** es uno de estos, y cada uno tiene un solo consumidor:

  | `kind` | Qué | Lo atiende |
  |---|---|---|
  | `&"claim"` | Respuesta de una reclamación | `auth_provider` (P4) |
  | `&"save"` | Respuesta de un guardado | `CharacterSaver` (P5) |
  | `&"heartbeat"` | Respuesta del latido: `revoked`, `mutes` y `maintenance` | `ZoneServer` (P5: expulsiones y la cuenta atrás del mantenimiento de §7.2; P7b: silencios) |
  | `&"id_block"`, `&"progress_op"`, `&"progress_ledger"` | Bloques de ids, operación y libro | `ProgressService` (progresion.md P5a y P5d) |
  | `&"fortress"` | Respuesta de un PUT de fortaleza | `FortressPersistence` (P6) |
  | `&"ignore"`, `&"report"`, `&"sanction"` | Respuestas de `/ignorar`, `/reportar` y `/gm` | `ChatRouter` y la moderación (P7b) |
  | `&"instance_closed"` | `instance_lost`, `instance_replaced` o `instance_stopped` en cualquier respuesta o en `instance_status` (una vez) | `ServerMain`: el cierre de §6.1 (P5) |

  Las respuestas de la liberación y de los lotes no salen de `ZonePlatform`: reintenta hasta una definitiva y
  registra los rechazos. Las respuestas del registro y del GET de fortalezas acaban en `startup_finished`. La
  del primer bloque también, y además sale como evento `id_block` para `ProgressService` (§8). La de `live`
  solo se registra y, si se agotan sus reintentos, la zona sale (§6). Un `instance_not_live` solo se registra
  (§6.1).
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
- **Orden del tick** (amplía zone_server.gd): en `poll`, tras el transporte, `platform.take_events()` se reparte por
  `kind` (tabla de arriba), en el orden en que llegaron; `instance_closed` se atiende al final del reparto. Después,
  `auth_provider.take_completed()` y, para cada 200, los pasos de §5.2 (`ProgressService.prepare` incluido). En cada
  tick, los `VERIFYING` vencidos (7 s en tiempo real); tras `altas`, `CharacterSaver.step(s)`. Las peticiones del progreso salen por
  `ZonePlatform.request_id_block()` y `ZonePlatform.request(kind, …)`.
- **Altas y bajas.** `_process_arrivals` llama a `saver.track(net_id, character_id, lease_id, s)` en cuanto crea la
  entidad y antes de `progress.on_arrival` (que da el kit de inicio y lo marca crítico, progresion.md §2.5): así ese
  crítico sale al instante. Una baja en `VERIFYING` llama a `auth_provider.cancel(peer_id)`; una en `LOADING`, a
  `platform.release(character_id, lease_id)` y `progress.cancel_prepared(peer_id)` (§5.2); una en el mundo, a la
  salida de §7.2, y una por `save_rejected` o `revoked` `lease_lost`, a la baja sin guardado de §7.2.
  `ZoneServer.stop` hace lo de §7.2 («Cierre ordenado») antes de `begin_flush`; el cierre de §6.1 es
  `ZoneServer.close_instance(code)`, que `ServerMain` llama con el código de `instance_closed` (P5, §19.9).

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
| P0 | `migrate`: up, down hasta la irreversible y up con el esquema igual; una irreversible no baja; conservación con las semillas; suma alterada → error; dos ejecutores a la vez (bloqueo). `config`: variable que falta → no arranca; clave de billete de 31 B → no arranca; la del vector fuera de `test` → no arranca; `MIN_PROTOCOL` ausente en `production` → no arranca. `/ready` con la base parada → 503. `jsonx`: `4.0` vale, `4.5` y un id sin comillas no; un id de 2^63 − 1 en cadena vale y uno mayor no. `migrate`: una pendiente por debajo de la mayor aplicada → se niega; `serve` con una migración posterior a las suyas arranca |
| P1 | Contraseña buena, mala y correo inexistente (mismo código y cuerpo); 5 fallos desde la IP B → 429 en B y el dueño entra desde A; 5 fallos con el correo inexistente A desde el grupo X, y después el inexistente B y el existente C desde X (contraseña mala) reciben lo mismo (`invalid_credentials`, no 429); los fallos por `/v1/account/password` cuentan igual (el sexto → 429); suspendida con contraseña mala → `invalid_credentials`, con buena → sesión `privacy` con el motivo; con la de una cuenta expulsada, la supresión y cerrar sesión valen y las demás rutas (también `enter`) dan 403 `account_banned`; 11 intentos por IP → 429; el registro con un correo existente, uno sancionado y uno nuevo da el mismo cuerpo (y su correo en `outbound_mail`); acceso caducado → 401 y refresco; reutilizar el refresco anterior → sesión revocada; uno de hace dos rotaciones → 401 sin revocar; los 12 h no se alargan al rotar; segunda sesión revoca la primera; enlaces caducados y usados; tras cambiar la contraseña o el correo, el enlace de recuperación anterior falla y el `revert_email` sigue valiendo; `revert_email` devuelve el correo y obliga a recuperar; exportar sin contraseña → 400; un correo con `\r\nBcc:` → 400 `validation`; `X-Forwarded-For: 1.2.3.4` y `X-Real-IP` desde un origen no fiable no cambian la IP del límite; el formulario de `/verify` enviado como un navegador (`application/x-www-form-urlencoded`, sin cabeceras de `/v1`) verifica; `/verify?token=<script>` no lo repite; borrado y cancelación en plazo; cuenta sin verificar purgada a los 7 días (reloj); `needsRehash` |
| P2 | `names` con `tests/fixtures/names/name_rules_cases.json` y `test_progression_rules_export.gd` (Godot); dos creaciones simultáneas del mismo nombre (una `name_taken`); «Anéira» frente a «ANEIRA» y «Aneira» (`name_taken` por tildes y mayúsculas); reino bloqueado; huecos (un borrado en plazo ocupa); el sexto personaje creado en un día → 429; crear y borrar enseguida libera el nombre en `restore_until`; plantilla y raza de otro reino → 400; borrar, restaurar y nombre reservado; `enter` sin zona viva → 503; `enter` elige la última zona si admite el reino; vector del billete de §5.1 |
| P3 | El token de `1:vado_gris:0` no registra `vado_gris:1` ni un host fuera de la lista, ni late por otra instancia (403); registro sin `replace` con la vieja latiendo → 409 `instance_alive`; con la vieja aún `live` pero sin latir desde hace 3 × `HEARTBEAT_S` → la pasa a `lost`, libera sus arrendamientos y registra la nueva (sin 500); con `replace` → `replaced` y fila en la auditoría; la sustituida manda su guardado final y vale; tras `replace`, reclamar un personaje de la vieja da `character_busy` hasta su final con `release_lease` (o hasta el TTL) y después la reclamación trae ese final; instancia `lost` que late → 409 `instance_lost`; latido con un `lease_id` viejo → `revoked` `lease_lost` y sin renovar; reclamación a una `starting` → `instance_not_live`; billete consumido, caducado, de otra instancia y de sesión revocada (no queda consumido); `character_busy` no consume el billete; refrescar la sesión con el personaje arrendado no lo pone en `revoked`; dos zonas a la vez (una gana); libre a los 15 s sin latido (plazos cortos); `seq`: plazo vencido con el commit tardío y reintento → `duplicate`, y el siguiente se aplica sin fallar S2 (progresion.md §13.3); mismo `seq` con otro cuerpo → `seq_conflict`; `seq` menor → `stale_seq`; ajeno → `lease_lost`; sin fila de arrendamiento (purgado) → `lease_lost`; un `duplicate` devuelve el `save_version` de cuando se aplicó; tardío tras liberar (vale) y tras otra reclamación (no vale); `invalid_save` del falso (`*persistence.InvalidSaveError`) → nada escrito; un 23505 en el COMMIT (la restricción diferida de ranuras) → `invalid_save`; un 40001 que se repite → 503 `db_unavailable` y nada escrito; un guardado con `"kills": 4.0` se aplica; una reclamación con un `ticket_id` > 2^53 vale; reclamar un personaje borrado → `ticket_invalid`; con la cuenta suspendida, expulsada o con el borrado pedido → 403 `account_blocked` con su `kind`, `until_unix`, `reason` y un `message` de 255 B como mucho (con un motivo largo); un DELETE y una reclamación del mismo personaje a la vez dejan o un borrado sin arrendamiento o un vivo con él; dos reclamaciones simultáneas de dos personajes de la misma cuenta: solo una gana y la otra da `character_busy` (y `enter` del segundo con el primero en el mundo, también); sobre con un campo desconocido, `save_format` 2 o un `character_id` distinto del de la ruta → `invalid_save` `envelope`; un guardado sin `pvp` no cambia `character_pvp_stats` y uno con `kills` menor no lo baja; el latido no lleva los de `VERIFYING` y `revoked` trae el `lease_id`; libro de un personaje sin arrendamiento en la instancia y operación sin participantes en ella → 404; un lote de auditoría con una entrada mala inserta las demás y devuelve su clave; una entrada con `source = 'cli'`, con la `key` `<uuid>:<n>` de otra instancia o con un `op:<op_id>` de un bloque de otra instancia, en `rejected`; registro sin certificado en `staging` → 400; PUT de fortaleza con `expected_version` viejo → `version_conflict`; PUT de una fortaleza de otra zona → 403 y su evento de guerra, en `rejected`; el GET solo da las de la zona; un reporte, un ignorado o una sanción con `world_id` en el cuerpo → 400, y sin él resuelven el nombre en el mundo de la instancia; 100 guardados concurrentes del mismo personaje: `save_version` = aplicados |
| P4 | `test_handoff_ticket.gd`: vector, firma alterada, clave desconocida, otra zona, caducado, desfase de 5 s, reutilizado; `test_net_messages`: REJECT 10–12 y bit GM; `test_zone_server_platform.gd` con `FakeZonePlatform` y ENet real: billete → `VERIFYING` → WELCOME; sin billete → `TICKET`; **cupo de 4 con 5 en `VERIFYING` → `FULL`**; HELLO retrasado 1,4 s con `GuardedEnetPeer` y reclamación a 5 s → WELCOME (`auth_timeout` de 10 s); plataforma muda → `UNAVAILABLE` a los 7 s (reloj real); zona cercada → `UNAVAILABLE`; peer que se va en `VERIFYING` → liberación; peer que se va en `LOADING` (y `revoked` en `LOADING`) → liberación sin guardar; un `revoked` con un `lease_id` viejo no expulsa; `BUSY` con su texto y `BANNED` con el `message` del 403 (§6.1) en suspensión, expulsión y borrado pendiente; `test_hello_cannot_probe_an_enemy_name` (con ENet, un HELLO con billete de otro personaje y el nombre de un enemigo conectado no recibe `NAME`; social.md 12.7); `--platform --debug-commands` con `env = production` → la zona sale; `ticket_id` > 2^53 en el cuerpo de la reclamación (Go y `FakeZonePlatform`) y `character_id` > 2^53 en `from_claim`. `test_platform_client.gd` con `FakeHttpServer` (TCPServer en el mismo proceso, respuestas y retrasos guionizados): plazo vencido y reintento con los mismos bytes; la reclamación no se reintenta; **un latido no espera detrás de 4 guardados lentos**; una reclamación sale aunque haya 4 guardados en vuelo; orden por prioridad; un 204, un cuerpo vacío y uno roto → `body` null (`bad_json` en el roto) sin errores del motor; `request` pone `zone_instance_id` y `enqueue_batch` la `key` que falta sin tocar `op:<op_id>`; `save` manda los bytes sin tocarlos; el conjunto del latido: entra con la reclamación, cambia con otra del mismo personaje y sale con `release` o con la respuesta definitiva del final, no con la de un guardado sin `release_lease`; un `instance_lost` en la respuesta de un bloque de ids da un solo `instance_closed`; una liberación con 403 no se repite |
| P5 | Con el falso (que hace la ida y vuelta por JSON como `PlatformClient`): punto de control (intervalo de prueba de 120 ticks), fases repartidas, crítico al instante, una escritura en vuelo, el final espera detrás de la que vuela, `duplicate` cuenta como aplicado, `invalid_save` expulsa y libera sin guardar, `lease_lost` expulsa sin liberar, `instance_lost` cierra la zona con guardados finales y la NOTICE de expulsión sale después de ellos (un jugador echado por `instance_lost` o `instance_replaced` que vuelve a entrar enseguida carga su final), salida en combate guarda al irse el cuerpo, **la baja sin guardado** (un `invalid_save` con el jugador en combate: el cuerpo sale en el acto, se libera una vez, la «Salida» no manda nada y ningún gancho de `ProgressService` falla; un `revoked` `lease_lost`, igual sin liberar), un 403 o un 413 del guardado es definitivo, **el cierre ordenado espera** con el falso contestando a los 2 s (con cada uno de los cinco disparadores) y libera a los de `LOADING` y `VERIFYING`; el `maintenance` del latido avisa a los 10, 5 y 1 min, 30 s y 10 s y cierra; la reconexión devuelve lo último aplicado de la sección falsa; un crítico marcado justo tras `track` sale al instante; **un `net_id` reutilizado con el final del anterior aún en vuelo**: el nuevo no recibe `acknowledge` ni `save_rejected` del viejo, y un `invalid_save` tardío del viejo solo se registra y libera; **el mismo personaje vuelve a esta instancia mientras su final, ya aplicado, se reintenta**: la entrada vieja recibe `lease_lost` y solo se registra, y la nueva no se expulsa |
| P6 | Ida y vuelta de `FortressPersistence` (ticks ↔ Unix con reloj fijo); arrancar con `CONSOLIDATING` a medias conserva dueño y plazo; `CAPTURING` vuelve como `VULNERABLE`; **plataforma caída al arrancar: el puerto no se abre y el dueño guardado no se pisa**; lista vacía → estado inicial sin aviso; `version_conflict` → reenvío con la versión nueva; capturas y `defend_ticks` (solo el dueño); una captura forzada por un comando no suma; la reconexión conserva `pvp`; el final se construye antes de `ScoreKeeper.forget`; lote de eventos reenviado sin duplicar |
| P7a | Un moderador que pide `ban` → 403 y fila `sanction_denied`; un GM no sanciona a un admin; sancionar sin arrendamiento en la instancia → 403; caducidad de cada tipo de sanción (aviso, silencio, suspensión, expulsión, renombrado) con el reloj inyectado; `set-role` revoca las sesiones y el latido expulsa (≤ 5 s); `admin reports show` sin `--actor` → error, y con él, fila en la auditoría; `admin chat` entre dos fechas (con `zone_channel`) y lo caducado desaparece; ninguna fila de `audit_log` de la CLI (`set-role`, `purge-now`, `chat --character`) ni un `sanction_denied` lleva un correo o un nombre de personaje en `args`; `set-role` deja la fila de §9.1 (`source = 'cli'`, `command = 'set-role'`, `target_account_id` y `args` con `from`, `to` y `os_user`); un lote de auditoría con una entrada `source = 'cli'` o `command = 'set-role'` la rechaza y S2 no la ve |
| P7b | Sin rol → «Comando desconocido»; DEBUG_COMMAND 1 (`teleport`) sin rol → aviso y no se mueve; `/gm silenciar` de un `player` → «Comando desconocido» y de un `moderator`, aplicado; un GM invisible no hace daño, no lo recibe y no cuenta en el círculo ni en el marcador; `/gm teleport` y `/gm visible` ponen `gm_forced` al personaje que mueven o muestran, y la reaparición lo quita; la entrada de auditoría lleva `actor_account_id` y `source` `zone`; un ignorado no susurra, no invita ni llega a su canal de zona; reporte con prueba y límite de 1 cada 10 min; silencio con su tiempo restante; renombrado forzado; salir y volver a entrar en 5 min no rellena las ráfagas del chat (`ChatPeerState` por personaje) y pasados 5 min sí |
| P8 | `test_client_config`: modos y prioridad, `--dtls-*`; `PlatformApi` con `request_hook` (refresco ante 401; dos llamadas que caducan a la vez hacen un solo refresco; mapa de errores); `AccountFlow` con `request_hook` (login, crear si falta, enter → `ClientConfig` con billete); `--bot --platform` sin `--login` → código 1; pantallas con datos falsos (nombre, borrado escribiendo el nombre, Entrar desactivado sin personaje, plantilla); `NetClient` pone el billete en el HELLO |
| P9a | Exportación con todas las secciones, también el libro de una lápida, y las operaciones GM sin `note` ni actor; la purga deja las lápidas; con un arrendamiento vivo no purga y `purge-now` responde `character_busy`; una restauración en el límite y la purga horaria a la vez: gana una y el personaje queda entero o purgado; las retenciones borran lo caducado y nada más (también un reporte abierto al año y las sanciones de una cuenta purgada hace más de un año); una copia tomada antes de purgar, restaurada y con `reapply-purges`, deja la lápida con el `purged_at` original; una tomada antes de borrar un personaje y antes de un `purge-now` de su cuenta deja, tras `reapply-purges`, todos sus personajes como lápida (también los que nunca se borraron), sin arrendamientos ni billetes restaurados, y `reapply-purges` sale con error si un id de `purges.txt` queda sin purgar; purgar una cuenta deja como lápida a sus personajes vivos; purgar una cuenta suspendida y registrar el mismo correo → no se crea la cuenta; una cuenta expulsada exporta y pide la supresión con su sesión de privacidad, y se purga; tras `purge-now`, ninguna fila de `audit_log` tiene su correo, y `restore_check.sh` falla si alguna lo tiene |
| P9b | `restore_check.sh` sobre una copia de la base de prueba con `purges.txt`; `docker compose config -q`; la comprobación de secretos de la CI con un `staging.env` de prueba en el índice → falla |
| P9c | Loopback con DTLS y `GuardedEnetPeer` (servidor y cliente en un proceso, cierre limpio sin errores del motor); `SwarmBot` con certificado |
| P10 | Abajo |

Las del almacén del progreso (S1–S8 con sus casos, dos guardados con el mismo `uid`, ids fuera de los bloques de la
instancia, intercambio diferido, purga con lápida, retención al año, `delete` del libro sin la marca, `Summaries`,
`Export`, operación y libro) son de progresion.md §15 P7. DEBUG_COMMAND 40–43, la regla de los propios personajes
(id 40 sin rol, `item_give` propio sin `admin`) y el cercado con `item_give` son de progresion.md P5d.

**P10, extremo a extremo** (`go test -tags e2e ./e2e`):

- **Arnés.** `ELDMARK_GODOT` (ruta del ejecutable de Godot 4.7.2; si falta, `t.Skip`). `TestMain` hace una vez
  `godot --headless --path .. --import` (con LFS ya bajado). Plataforma en el proceso de la prueba, PostgreSQL
  efímero (§2.6), `ELDMARK_HEARTBEAT_S=1`, `ELDMARK_LEASE_TTL_S=6`, el token `1:test_world:0` en
  `ELDMARK_ZONE_TOKENS` y `ELDMARK_ENTRY_ZONES=vardheim=test_world,solmarch=test_world` (un personaje nuevo entra
  en la de su reino, y las pruebas solo arrancan `test_world`). progresion.md P8 usa el mismo arnés.
- **`TestEnterAndSave`:** `test_world` con `--platform`, un `--bot` con cuenta: entra, guarda, sale; `save_version
  > 0` y `character_progress.saved_at` puesto.
- **`TestZoneCrash`:** `--save-interval=5`; se espera a un `saved_at`, se apunta la hora y `kill -9` a la zona. Se
  arranca otra instancia (su registro da 409 `instance_alive` y reintenta cada 2 s hasta que la vieja lleva 3 s sin
  latir; entonces la pasa a `lost` él mismo, §5.3) y **un segundo proceso `--bot`** con
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
| Una zona comprometida (Godot recibe UDP de Internet) | Token con alcance, `public_host` de una lista, autorización de sanciones en la plataforma, lotes validados contra la instancia (§6), ids solo de sus bloques, S1–S8 en Go (progresion.md §13.3). **Riesgo que queda:** S1–S8 acotan la forma, los topes, los ids y el actor de las GM, no las cantidades; son la red contra una zona con un error, no contra una comprometida, que aún puede acuñar oro, méritos y XP con GAMEPLAY o con `source = console` sobre los personajes que tiene dentro. Lo detectan PRG-30 y PRG-39 |
| Textos legales, edad, retenciones (libro, correos sancionados) y exportación | Borradores marcados; revisión humana antes de cualquier prueba pública |
| `zone_server.gd` lo tocan nueve paquetes de los dos documentos (y antes habilidades.md) | Orden conjunto fijo, que empieza tras habilidades.md H3c (§14.1), y pasos del tick con nombre (§14.3) |
| P10 puede pasar de 30 s | Se mide; si pasa, tope explícito de 60 s (§15) |

## 17. Interfaz con progresion.md (conciliada)

Lo acordado con progresion.md tras conciliar los dos documentos. Cada regla está escrita una sola vez, en el
documento dueño; el otro la cita. La misma tabla está en progresion.md §13.1.

| Tema | Acordado | Dueño | Lo cita |
|---|---|---|---|
| Idempotencia del guardado | Solo `(lease_id, seq)`: mismo `seq` y mismo SHA-256 → `duplicate` (aplicado, con el `save_version` guardado en `character_leases`); otro cuerpo → `seq_conflict`; menor → `stale_seq`. `save_version` es un contador que no interviene; `saved_at` y `save_version` los escribe `Apply` (S8) | plataforma.md §7.3 | progresion.md §5.4, §13.3 |
| Cuerpo del guardado | Sobre `save_format` 1 con una clave por sección: `progress` (el registro sin los campos de solo lectura, con `ops`) y `pvp`. Sin `zone_id`: la zona es la de `claimed_by` | plataforma.md §7.1, §7.3 | progresion.md §9.3 |
| Diario en el guardado | Cada cuerpo lleva solo las operaciones con `save_seq = 0`, que `build` marca con su `seq`; `acknowledge(seq)` quita las de `save_seq ≤ seq`. Un final construido con otro en vuelo no repite nada | progresion.md §9.2 | plataforma.md §7.1, §7.2 |
| Formatos | `progress.progress_format` es el `record_format` del registro de la zona (`ZonePlatform.RECORD_FORMAT`, de plataforma.md P4; `ProgressRecord.FORMAT` vale lo mismo y lo prueba progresion.md P5a): la compatibilidad se decide al registrarse (409 `schema_mismatch`); en un guardado, otro formato es 400 `invalid_save` | plataforma.md §7.1 | progresion.md §3.4 |
| Secciones de `CharacterSaver` | `register_section(section, build, acknowledge, is_dirty)` con `build(net_id, seq)`, `acknowledge(net_id, seq)` e `is_dirty(net_id)`; sin `restore`. `track(net_id, character_id, lease_id, tick)` al crear la entidad, antes de `on_arrival`; `mark_critical(net_id, reason)`, `on_platform_event`, `save_rejected`, `drop(net_id, code)`. `CharacterSaver` arma el sobre entero (`zone_instance_id` incluido); un `build` que devuelve `{}` aplaza ese guardado (el final no espera: alerta y `release`). Entradas por `lease_id`, y cada respuesta, por el `lease_id` y el `seq` de su petición: tras `finish` o `drop`, ni `acknowledge`, ni `is_dirty`, ni `save_rejected` | plataforma.md §7.2, §14.3 | progresion.md §9.1, §9.2 |
| Eventos críticos | Kit de inicio, subida de nivel, captura y todo comando de GM que cambia algo (`op_revert` incluido); desde la fase 6, comercio, correo y botín raro. El renombrado no es crítico | progresion.md §9.2 | plataforma.md §7.2 |
| Cuándo se guarda | Cada 60 s con alguna sección sucia, en fases; una escritura en vuelo; el final en `finish`. Salida: `finish` → `ScoreKeeper.forget` → `ProgressService.on_departure`; al parar, `release` de `LOADING`, `cancel` de `VERIFYING` y `finish` de todos antes de `_clear_players()` | plataforma.md §7.2 | progresion.md §9.2 |
| Baja sin guardado | Un definitivo antes de `finish` o un `revoked` `lease_lost`: `CharacterSaver.drop(net_id, code)` (con `release` salvo en `lease_lost`), expulsión con el cuerpo fuera en el acto (sin salida en combate), `ScoreKeeper.forget` y `ProgressService.on_departure`. Todo gancho de `ProgressService` por `net_id` sin `PlayerProgress` no hace nada | plataforma.md §7.2 | progresion.md §9.2, §14.2 |
| Baja en `LOADING` | Sin guardado: `ZonePlatform.release(character_id, lease_id)` y `ProgressService.cancel_prepared(peer_id)`, también con un `revoked` | plataforma.md §5.2, §14.3 | progresion.md §9.1, §14.2 |
| Respuestas del guardado | Una tabla y una regla de errores. Contenido o base que no es pasajero (`*persistence.InvalidSaveError`, SQLSTATE de clase 22 o 23 o `P0001`, también en el COMMIT): 400 `invalid_save` con `fields.check` y `fields.detail`. `40001` y `40P01` tras reintentar, sin conexión o plazo: 503. Un error del sobre: `invalid_save` con `check = "envelope"`. No hay `invalid_progress` ni `progress.ErrFormat`. `instance_*`: cierre con guardados finales. Cualquier otro 4xx es definitivo, como `invalid_save`, también en la liberación. `progress` es obligatoria y `pvp`, opcional y sin bajar | plataforma.md §6.1, §7.3 | progresion.md §9.2, §13.3 |
| Sin plataforma | Nada se guarda: personajes efímeros; no hay `--progress-file` ni repositorios de progreso. `CharacterSaver` solo existe con `--platform` y llama a `ZonePlatform.save` | progresion.md §0, §9.4 | plataforma.md §5.5, §7.5 |
| Reclamación | `{lease_id, instance_status, account, character, progress, pvp}`, solo de un personaje no borrado, con la cuenta bloqueada, sin otro personaje de la cuenta en el mundo y con `Load` en su transacción; en la zona, `AuthOutcome.claimed: ClaimedCharacter` con `progress: Dictionary`. No hay clase `CharacterRecord` | plataforma.md §5.3, §6, §14.3 | progresion.md §3.4, §9.1 |
| Antes del WELCOME | Reino → cupo → `ProgressService.prepare(peer_id, claimed)` → WELCOME con el reino del personaje; si algo falla, REJECT (`REALM`, `FULL` o `UNAVAILABLE`) y `release`. El WELCOME no cambia de bytes | plataforma.md §5.2 | progresion.md §9.1 |
| Contenido del registro | Un solo `ProgressRecord`, con raza, apariencia, `played_seconds`, `health` y `location`. Solo en la reclamación: `race_id`, `appearance`, `starter_template_id` y `location.saved_at_unix` (`to_claim_dictionary` los pone). No hay `characters.state` ni JSON de estado | progresion.md §3.4 | plataforma.md §7.1 |
| Falso de la plataforma | `FakeZonePlatform` devuelve en la reclamación siguiente lo último aplicado: `pvp` (plataforma.md P4) y `progress` sin `ops`, con los campos de solo lectura de la reclamación anterior y `location.saved_at_unix` (progresion.md P5a, con `claim_progress`). Su API de pruebas (`add_character`, `script_next`, `set_fenced`, `next_block_first`, `applied`, `sent`) es una sola, de plataforma.md P4 | plataforma.md §14.1, §14.3 | progresion.md §14.1 |
| Volver al mundo | Zonas RVR (todas en la fase 5): el campamento del reino. Zonas SAFE (fase 6): el sitio guardado si es la misma instancia, hace menos de 15 min, sin combate y vivo. Vida regenerada con el tiempo pasado | progresion.md §8 | plataforma.md §0, §7.1 |
| Quién guarda qué | Una tabla con todos los campos y su dueño; `characters` solo identidad (no gana `level` ni `state`) | progresion.md §3.1 | plataforma.md §3 |
| Tablas del progreso | DDL de `0010_progress` solo en progresion.md, sin `world_id`; las de solo añadir, con clave ajena sin cascada a `characters` por `op_participants`; disparador en las cinco; `actor_account_id` en las GM y REVERSAL | progresion.md §3.3 | plataforma.md §3 |
| Migraciones | En la fase 5, 0001–0006 de la plataforma y 0010_progress (progresion.md P7, con `.down.sql` y semilla); después, el siguiente número libre, sea de quien sea. El ejecutor aplica en orden y se niega ante una pendiente por debajo de la mayor aplicada. No hay P3b | plataforma.md §2.4 | progresion.md §3.3 |
| Bloques de ids | `POST /internal/v1/id-blocks {zone_instance_id}` → `{first, count: 1024}`, en `starting` y `live`; `uid_block_seq` e `id_blocks` en 0003_zones; el primer bloque, en el arranque; `Apply` rechaza ids fuera de los bloques de `claimed_by` | plataforma.md §3, §6, §8 | progresion.md §4.5, §13.3 |
| Purga y retención | La lápida es la fila de `characters`. La purga bloquea el arrendamiento y la fila del personaje, y no purga con un arrendamiento vivo; con la cuenta y en `reapply-purges` (que corre antes de `serve` y borra los arrendamientos restaurados) basta `purged_at` nulo; `ProgressStore.Purge` borra el estado del progreso; `PurgeRetention` vacía el libro al año y devuelve las lápidas vacías, que la plataforma borra; `reapply-purges` conserva el `purged_at` | plataforma.md §11.1, §11.2 | progresion.md §3.5 |
| Exportación | `ProgressStore.Export` de cada personaje no purgado y de cada lápida de la cuenta con libro (sin registro), bajo `characters[i].progress`; de las operaciones GM y REVERSAL, sin actor, `note` ni `detail`. El libro de una lápida es seudónimo solo tras purgar la cuenta | plataforma.md §11.2 | progresion.md §3.5 |
| `ProgressStore` en Go | `Create`, `Load`, `Apply`, `Summaries`, `Purge`, `PurgeRetention` (con las lápidas vacías), `Export`, `Op` (con la instancia) y `Ledger`, con JSON crudo en la frontera; sus errores (`InvalidSaveError`, `ErrNotFound`) y la validación de la creación (`CreateValidator`, `*ValidationError`) en `internal/persistence`, de plataforma.md P2, que `*progress.Rules` implementa. La plataforma no lee columnas del progreso | progresion.md §13.2 | plataforma.md §7.5 |
| Operación y libro | Rutas `?zone_instance_id=` del enrutador interno de la plataforma (comprobaciones de su §6.1), solo con arrendamiento en la instancia (el del personaje, que mira el enrutador; o el de algún participante, que mira `Op` en su propia consulta); si no, 404. Cuerpos de progresion.md; `limit` de 1 a 100 | plataforma.md §6 | progresion.md §13.2 |
| Ids en JSON | Cadena decimal para todo id `bigint`, también en la reclamación y en el guardado (`jsonx.ID`, hasta 2^63 − 1; los del progreso, hasta 2^53 − 1 por S1); número para cantidades, saldos, nivel, `seq`, códigos y fechas. Reinos: id de texto en la API pública y código en la interna | plataforma.md §4.1 | progresion.md §0, §3.4 |
| Comprobaciones del guardado | S1–S8 de progresion.md; arrendamiento y `seq` son los pasos 2 y 3 del guardado, sin número S. S2 admite de las zonas los tipos 1–5 con sus motivos, rechaza un `op_id` ya guardado y comprueba el actor de GM y REVERSAL con el rol que tenía en `detail.at_unix` (la fila `set-role` de la CLI, plataforma.md §9.1). S7 admite fechas pasadas | progresion.md §13.3 | plataforma.md §6.1, §7.3 |
| Nivel | Solo `character_progress.level`; la lista de personajes lo lee con `Summaries` | progresion.md §3.1 | plataforma.md §4.4 |
| Raza y apariencia | `race_vardheim`, `race_solmarch` y `race_askarra`; 8 B en `character_progress`, con el byte 0 de `race_id`; valida la plataforma al crear (`ValidateCreate` o la provisional) y la zona al cargar (`default_for`), con las mismas reglas exportadas (piezas con sus `bodies`, `allows_no_hair`, `allows_no_beard`) y los mismos casos (`appearance_cases.json`); el reino, en el código de `NetProtocol.Realm` en `validate`, `ValidateCreate`, las reglas y los casos | progresion.md §7.2 | plataforma.md §4.4 |
| Plantilla de inicio | Se elige al crear (`starter_template_id`, UI-24) entre las `selectable`; es el kit de la primera entrada; con plataforma, LOADOUT_SELECT no cambia nada | progresion.md §2.5 | plataforma.md §4.4, §13.2 |
| Reglas exportadas | Un archivo (`platform/internal/gamedata/progression_rules.json`), una herramienta (`tools/progression/export_rules.gd`) y una prueba (`test_progression_rules_export.gd`); `protocol_version` y `names` son de plataforma.md. Los datos de prueba compartidos con Go, bajo `tests/fixtures/` | progresion.md §13.4 | plataforma.md §4.4 |
| Protocolo | `PROTOCOL_VERSION = 7` para toda la fase 5, con `AUTH_TIMEOUT_SECONDS = 10.0`; reparto fijo (5 chat y grupos, 6 habilidades.md); lo sube plataforma.md P4, tras habilidades.md, con la línea completa en `net_protocol.gd`; progresion.md P4 añade lo suyo sin subirla. En red.md cada P4 escribe las filas y la marca «v7» de lo que añade su código | plataforma.md §5.4 | progresion.md §12 |
| CMB-30 | Es de progresion.md; la plataforma guarda la sección `progress` | progresion.md §8 | plataforma.md §7.1 |
| Billete y traspasos | 52 B, solo identidad; lo de CMB-30 llega con el guardado final y la reclamación en el destino (fase 6) | plataforma.md §5.1 | progresion.md §8 |
| DEBUG_COMMAND con plataforma | El `min_role` de cada comando; declaran `admin` los 40–43 y el 5, el 13 y el 16 | progresion.md §10 | plataforma.md §9.1 |
| Guardia de entorno | Manda el `env` del registro: con `staging` o `production`, las opciones de desarrollo hacen salir a la zona | plataforma.md §5.5 | progresion.md §10 |
| Sobre los propios personajes | Todo comando que cambia algo (`op_revert` incluido) exige `admin`, sin excepción por entorno; S2 lo repite en las GM y las REVERSAL | progresion.md §10 | plataforma.md §9.1 |
| Consultas de GM | `inv_show`, `ledger_show` y `op_show` piden `gm` y se auditan | progresion.md §10 | plataforma.md §9.1 |
| Auditoría | Un comando que crea una operación (una GM, o la REVERSAL de `op_revert`) va con `key = "op:<op_id>"` en el lote y en S8, con `on conflict do nothing` y los mismos campos: `actor_account_id`, `source` (`zone` o `console`), `args` con el objetivo por id y `at` = `detail.at_unix`; `world_id` y `zone_id`, de la instancia. Cada entrada del lote se valida por separado y contra la instancia que la manda: ni otra instancia, ni filas `cli` o `platform`, ni `op_id` de otros bloques (plataforma.md §6). Ninguna fila de `audit_log` lleva correos ni nombres en `args` | plataforma.md §9.1 | progresion.md §10, §13.3 |
| GM invisible | Ni méritos, ni XP, ni oro, ni recompensa de captura | plataforma.md §9.1 | progresion.md §6.2 |
| Zona cercada | Los comandos que cambian algo se rechazan sin crear la operación; los críticos del juego se marcan y salen después | plataforma.md §5.3 | progresion.md §10 |
| Jugadores falsos | Opciones y guardia, plataforma.md; con plataforma y falsos, ninguna recompensa persistente | progresion.md §6.2 | plataforma.md §5.5 |
| Comandos del fuerte y de GM | Con plataforma, lo que provoca un comando del fuerte (`fort_owner`, `fort_reset`, `fort_kill_captain`, una captura con `fort_capture_speed`) no paga nada persistente ni suma en `ScoreKeeper`; `/gm teleport`, `/gm visible` y los DEBUG_COMMAND 1, 2 y 4 marcan al personaje (`gm_forced`) hasta su reaparición: ni capturas, ni méritos, ni PNJ | progresion.md §6.2 | plataforma.md §8, §9.1 |
| Eventos en la zona | `take_events()` se reparte por `kind`, con un consumidor cada uno: `claim` (`auth_provider`), `save` (`saver`), `heartbeat` (la zona), `id_block`, `progress_op` y `progress_ledger` (`progress`), `fortress`, `ignore`, `report`, `sanction` e `instance_closed` (`ServerMain`); después `take_completed` y `prepare` | plataforma.md §14.3 | progresion.md §14.2 |
| Peticiones de la zona | `ZonePlatform.request` pone `zone_instance_id` (el guardado lo lleva en el sobre de `CharacterSaver`, y `save(character_id, lease_id, body, release_lease, context)` manda los bytes sin tocarlos); `enqueue_batch`, la `key` que falta; ningún cuerpo lleva `world_id` (lo pone la plataforma desde la instancia); `body` leído con `JSON.new().parse` (nunca `parse_string`) | plataforma.md §14.3 | progresion.md §13.2 |
| Capturas | Una lista de `FortressController` (captor, presentes, vivos, conectados, sin invisibles ni marcados con `gm_forced`) para `ScoreKeeper.captures` y `ProgressService.on_capture`; una captura forzada no va a ninguno | plataforma.md §8 | progresion.md §6.2 |
| Huella u32 | `HandoffTicket.zone_key_of` para el `zone_key` del billete y los `ref_id` de PNJ y fortaleza | plataforma.md §5.1 | progresion.md §5.2 |
| Reloj y tamaño | `ZonePlatform.now_unix()` para los temporizadores; cuerpo de 1 MB como mucho en la API interna | plataforma.md §6 | progresion.md §8, §17 |
| Paquetes | El almacén del progreso es progresion.md P7, con las dependencias de su §14.1; la interfaz `ProgressStore`, `CreateValidator` y sus errores, plataforma.md P2; los dos documentos esperan a habilidades.md; progresion.md P5c, a plataforma.md P6 (lista de capturas); un orden conjunto para `zone_server.gd` | plataforma.md §14.1 | progresion.md §14.1 |
| Pruebas | Las del almacén, en progresion.md P7; DEBUG_COMMAND 40–43, la regla de los propios personajes y el cercado con `item_give`, en progresion.md P5d (plataforma.md P7b prueba `min_role` con comandos de red y de moderación); las de extremo a extremo, con el arnés de plataforma.md P10 | progresion.md §15 | plataforma.md §15 |
| Cliente | UI-23, UI-24 y el bot usan `CharacterAppearance` y `AppearanceApplier` | plataforma.md §13.2, §13.3 | progresion.md §7.2, §7.4 |

## 18. Revisión

Tres revisores (seguridad, coherencia e implementabilidad) presentaron 45 hallazgos sobre la versión 0f6781b.
Comprobados en el código y en los documentos, todos se sostienen; las sondas de la revisión están en
`build/probe_rev/` (Godot: `auth_timeout` con `GuardedEnetPeer` y JSON; Go: `jsonx`; PostgreSQL: el esquema entero,
la lápida, el disparador, la reclamación y el latido; git: el `.gitignore`). Las filas son la historia de la
revisión; lo que cambió después, al conciliar con progresion.md, está en las cuatro últimas filas y en §17.

| Id | Gravedad | Qué era | Qué se hizo |
|---|---|---|---|
| PL-SEG1 | bloqueante | Dos contratos de idempotencia incompatibles (`(lease_id, seq)` aquí, `save_id` + `base_version` allí); `duplicate`, 400 y reintentos sin definir; dos fuentes de ids | Un contrato (§7.3): cuerpo inmutable reintentado byte a byte, `duplicate` = aplicado, `stale_seq`, `seq_conflict` con hash, `invalid_save` definitivo con `release`; bloques de la secuencia de 1024 con `first` en cadena (§6); prueba en P3. progresion.md, §17 |
| PL-SEG2 | importante | Con plataforma se podían usar `--debug-commands`, `--fake-players` y sin DTLS; DEBUG_COMMAND sin rol; clave de prueba válida | `env` en el registro y salida de la zona fuera de `dev`/`test` (§5.5); DEBUG_COMMAND con `min_role` (§9.1); registro sin certificado → 400 en staging y producción (§6); claves de < 32 B y la del vector rechazadas (§2.3); pruebas en P0 y P4 |
| PL-SEG3 | importante | Un token común abría toda la API interna; registro de cualquier zona y host; la sustituida «sin guardar» contradecía §5.3 | Token por despliegue con alcance y hashes, `ELDMARK_ZONE_HOSTS`, `zone_instance_id` comprobado, `claimed_by`, `replace` con auditoría, guardados finales de la sustituida (§5.3, §6, §6.1); pruebas en P3 |
| PL-SEG4 | importante | Sin definir qué pasa con una instancia `lost` que vuelve; latido sin filtro por `lease_id`; latido en la cola común | Latido con `(character_id, lease_id)` y SQL (§5.3, comprobado), `instance_lost` y cierre (§6.1), cercado a los 10 s, plaza propia del latido (§6). Matiz: el cercado rechaza las operaciones que piden guardado crítico, no los guardados, que siguen saliendo |
| PL-SEG5 | importante | La rotación del refresco con `family` expulsaba en el primer refresco; 12 h sin fijar; la SQL de la reclamación no miraba la sesión | Una fila por sesión rotada en el sitio con `prev_refresh_hash`, 12 h absolutos, un refresco a la vez en `PlatformApi`, reclamación con `join` a `sessions` y rollback sin arrendamiento (§3, §4.2, §5.3; comprobado); pruebas en P1, P3 y P8 |
| PL-SEG6 | importante | La plataforma creaba la sanción sin comprobar el rol ni la zona; bajar de rol no quitaba el poder | Cuerpos con `zone_instance_id` y `world_id`; autorización en tres pasos y `sanction_denied` (§9.5); `set-role` revoca las sesiones (§9.1); pruebas en P7a |
| PL-SEG7 | importante | Rutas con contraseña sin límite; cambios que no invalidaban enlaces; aviso al correo viejo sin vuelta atrás; exportar solo con el token | `CheckPassword` común, invalidación en la transacción (salvo `revert_email`), `revert_email` de 7 días, exportar con contraseña (§4.2, §4.3); pruebas en P1. En la revisión de la implementación (§19.7): gastar un `revert_email` anula los emitidos después, su correo queda reservado mientras vive y los intentos de contraseña de una cuenta van de uno en uno |
| PL-SEG8 | importante | `email_taken` y `account_locked` delataban cuentas; el bloqueo por cuenta era un arma; sanciones antes de la contraseña; cuentas sin verificar eternas | Registro y cambio de correo siempre 202; fallos por cuenta y grupo de IP con freno en las demás y 429; estados solo tras una contraseña buena; correo de aviso; purga a los 7 días sin verificar (§4.1–§4.3, §11.1); pruebas en P1 |
| PL-SEG9 | importante | Copias, WAL y registros guardaban datos purgados sin plazo | `purge_log`, `purges.txt` y `reapply-purges` (§11.2, §12); filas de copias, WAL y registros en §11.1; journald a 30 días; Caddy sin registro de accesos; sin `--battle-log` y similares en staging y producción; prueba en P9a |
| PL-SEG10 | importante | El `.gitignore` solo ignoraba `.env` (comprobado) | Patrones nuevos en P0 (comprobados en un repositorio de prueba), secretos desde `secrets/` y comprobación en la CI (§10.3); prueba en P9b |
| PL-SEG11 | importante | GM invisible que pegaba y capturaba; comandos sobre los propios personajes; CLI sin identidad; lecturas sin auditar | Invisible sin daño, sin círculo, sin marcador ni recompensas; regla de los propios personajes; `--actor` obligatorio; lecturas auditadas (§9.1); pruebas en P7a y P7b. progresion.md, §17 |
| PL-SEG12 | importante | Reservar nombres sin límite creando y borrando | 5 creaciones y 5 borrados por cuenta y día, los borrados en plazo ocupan hueco y los personajes de prueba no reservan 30 días más (§4.2, §4.4); pruebas en P2 |
| PL-SEG13 | menor | `X-Forwarded-For` sin regla clara | Solo `X-Real-IP` desde `ELDMARK_TRUSTED_PROXIES`, puesto por Caddy (§4.2, §10.1); prueba en P1 |
| PL-SEG14 | menor | Correo con CR/LF (inyección de cabeceras) y páginas con el token sin escapar ni cabeceras | Validación estricta y `mime.QEncoding` (§4.2); `html/template`, token validado y cuatro cabeceras (§4.3); pruebas en P1 |
| PL-SEG15 | menor | La supresión borraba la reincidencia | `sanctioned_email_hashes` con HMAC y clave propia, consultada en el registro, con revisión legal (§2.3, §3, §11.1, §11.2); prueba en P9a |
| PL-COH1 | bloqueante | Dos tuberías de carga y guardado, y dos `class_name CharacterRecord` | Una tubería: la reclamación trae el registro, `CharacterSaver` con secciones sobre `ProgressRepository`, `ClaimedCharacter` aquí, una tabla de errores (§6.1, §7.3, §7.5); `PlatformProgressRepository` pasa a P5. progresion.md, §17 |
| PL-COH2 | bloqueante | El mismo dato en dos esquemas; dos fuentes de `uid`; nadie escribía las migraciones del progreso | Tabla «quién guarda qué» (§3); `characters` solo identidad, sin JSON de estado; una sola fuente de ids (§6); P3b con 0010_progress (DDL comprobado), S3–S9 y las rutas de operación y libro (§14.1). progresion.md, §17 |
| PL-COH3 | bloqueante | La purga en cascada chocaba con el disparador del libro (comprobado por el revisor) | Lápida sin cascada en las tablas de solo añadir, disparador con `set local eldmark.retention_purge`, retención de 1 año y `progress_purge_character` (§3, §11.1, §11.2; comprobado); prueba en P3b. progresion.md, §17 |
| PL-COH4 | importante | CMB-30 asignado a habilidades.md, que lo deja fuera | Quitados `state.combat` y la frontera con habilidades.md; CMB-30 es de progresion.md §8 (introducción, §7.1, §16) |
| PL-COH5 | importante | Dos reglas de volver al mundo y dos campos de última zona | La de progresion.md §8, citada en §7.1 y marcada provisional (§0); `enter` lee `character_progress.last_zone_id` (§4.5) |
| PL-COH6 | importante | Creación incompatible: id de raza, dos generadores, sin plantilla, `Create` sin datos | Ids `race_<reino>`, un solo archivo y una herramienta, `starter_template_id` en la ruta y en UI-24, `CreateParams`, apariencia de 8 B (§4.4, §7.5, §13.2). progresion.md, §17 |
| PL-COH7 | importante | Rotación del refresco contra el arrendamiento atado a la sesión | Igual que PL-SEG5 (la sesión no cambia de fila); prueba en P3 |
| PL-COH8 | importante | `VERIFYING` fuera del cupo; reclamaciones detrás de los guardados; `auth_timeout` contado desde la conexión | `VERIFYING` cuenta y `FULL` se mira al 200; plazas para la entrada; `auth_timeout` de 10 s y plazo de 7 s en tiempo real (§5.2, §6; comprobado); pruebas en P4 |
| PL-COH9 | importante | Arranque sin plataforma que pisaba el dueño; registro antes del puerto; reinos sin guardar | Orden fijo con `starting` y `live`, GET con reintentos que distingue vacío de mudo, `expected_version`, `realms` en el registro (§3, §6, §8); prueba en P6 |
| PL-COH10 | importante | `flush_and_wait` síncrono imposible; el cierre de hoy no espera; disparadores incompletos | `begin_flush` e `is_flushed`, `_drain_stop` hasta 600 ticks y `SHUTDOWN_MAX_FRAMES` 720, los cinco disparadores (§7.2, §14.3); prueba en P5 |
| PL-COH11 | importante | Nadie hacía el inicio de sesión del bot con cuenta | `AccountFlow` sin interfaz, que usan `FrontMain` y el bot; `--bot --platform` sin `--login` sale con código 1 (§5.5, §13.3, §14.4); pruebas en P8 |
| PL-COH12 | importante | Criterios y reglas de otros documentos sin tocar | backlog: TEC-24 (reino del personaje), TEC-27 (criterio provisional), SOC-16 (filtro en el servidor) y «pendiente del usuario»; red.md §12 y §17 (billete de 52 B, `PENDING`); social.md §0, §8 y §10. progresion.md, §17 |
| PL-COH13 | menor | La versión 5 ya era del chat (y la 6 de habilidades.md); dos subidas en la fase 5 | Una sola subida compartida, la siguiente libre (hoy 7) (§5.4); `ELDMARK_MIN_PROTOCOL` obligatoria en staging y producción (§2.3). progresion.md, §17 |
| PL-COH14 | menor | `ticket_id` de 63 bits como número JSON | Todo id `bigint` como cadena en las dos API (§4.1; comprobado en Godot); prueba de ida y vuelta en P4. progresion.md, §17 |
| PL-COH15 | menor | `ScoreKeeper` no tenía capturas ni tiempo defendiendo; orden frente a `forget` | `captures` y `defend_ticks` con quién y cuándo, sección `pvp`, `finish` antes de `forget` (§8); pruebas en P6 |
| PL-IMP1 | bloqueante | El mismo tramo de la zona definido dos veces (clase, carga, guardado, CMB-30) | Igual que PL-COH1 y PL-COH4: frontera de §7.5 y §17 |
| PL-IMP2 | bloqueante | Contrato Go y esquema que no casaban; migraciones sin dueño; purga imposible | Igual que PL-SEG1, PL-COH2, PL-COH3, PL-COH6 y PL-COH14: `CreateParams`, `Apply` con tipos de progresion.md, una fuente de ids, cadenas, un generador, lápida y P3b (§3, §7.5, §14.1) |
| PL-IMP3 | importante | Godot reescribe `820.0` y Go lo rechaza en un `int` (comprobado) | `jsonx.Int` y `jsonx.ID` en Go; `int()` y `to_int()` al leer en GDScript; el falso hace ida y vuelta por JSON (§4.1, §14.3); pruebas en P0, P3 y P5. progresion.md, §17 |
| PL-IMP4 | importante | El plazo de 240 ticks no cabía en el `auth_timeout` contado desde la conexión | Comprobado con `GuardedEnetPeer`: 10 s en los dos lados y plazo de 7 s en tiempo real (§5.2, §5.4); prueba con el HELLO a 1,4 s en P4 |
| PL-IMP5 | importante | Cola de `PlatformClient` sin prioridades ni reglas; PUT de fortaleza sin versión; arranque mudo; sin prueba del HTTP real | Tabla de prioridades y reintentos (§6), una en vuelo por fortaleza con `expected_version` y arranque de §8; `FakeHttpServer` en P4 |
| PL-IMP6 | importante | Igual que PL-SEG5 y PL-COH7 | Igual que PL-SEG5 |
| PL-IMP7 | importante | Máquina de estados de la instancia incompleta | Orden fijo de comprobaciones y tabla por estado y petición (§6.1); `lost` que vuelve se cierra; pruebas en P3 |
| PL-IMP8 | importante | `AuthProvider` sin entrada para la reclamación; cupo; falso sin herencia; cómo llega `ZonePlatform`; clase en otro paquete | `on_platform_event`, `get_player_count` con `VERIFYING`, `FakeZonePlatform extends ZonePlatform`, `ZoneServer.start(…, platform)`, `ClaimedCharacter` en P4 (§14.1, §14.3) |
| PL-IMP9 | importante | Pruebas que no demostraban su criterio | Duplicados en P3b con tablas reales; `saved_at` para medir la pérdida; «ANEIRA» y «Aneira»; reconexión con `pvp` en P5 y caducidad de cada sanción en P7a (§15). progresion.md, §17 |
| PL-IMP10 | importante | `TestZoneCrash` no se podía ejecutar | Arnés con `ELDMARK_GODOT` e importación en `TestMain`, trabajo de CI, segundo proceso `--bot`, `saved_at` frente a la hora del `kill`, tope de tiempo explícito si pasa de 30 s (§15) |
| PL-IMP11 | importante | TEC-27 no se podía medir; `NetTransport` sin contrato DTLS; criterio cambiado sin marcarlo | `host` y `connect_to` con `TLSOptions`, `--dtls-*` en `--connect`, `--bot` y `--bots` (§10.2, §13.3); criterio provisional con pregunta al usuario en §0 y en el backlog; P9c |
| PL-IMP12 | importante | Vuelta atrás con `down` que borraba datos | `down` solo en desarrollo y CI, irreversibles marcadas, expandir y contraer, prueba de conservación (§2.4, §12) |
| PL-IMP13 | importante | Dependencias que faltaban y paquetes demasiado grandes | `ClaimedCharacter` en P4; P6 y P7b dependen de P5; P7 en P7a y P7b; P9 en P9a, P9b y P9c (P9c sin TEC-20); P3b nuevo (§14.1) |
| PL-IMP14 | menor | Los formularios de los correos no podían usar `/v1` | `GET` y `POST` urlencoded en `/verify`, `/reset` y `/revert`, fuera de `/v1` y sin el 426 (§4.1, §4.3); prueba en P1 |
| PL-IMP15 | menor | Faltaban pendientes del usuario | SMTP y DNS, revisión visual de UI-22 a UI-24 con lista y criterio de TEC-27 en §0 y en el backlog; lista de comprobación en §15 |
| Conciliación | bloqueante | Tras las revisiones, este documento (§17) y progresion.md (§13.1) seguían con dos listas de peticiones que no casaban: idempotencia y `save_version`, cuerpo del guardado, API de secciones, `CharacterRecord`, repositorios y `--progress-file`, tablas y migraciones del progreso, bloques de ids, lápida, formato de los ids, plantilla de inicio, reglas exportadas, roles y auditoría | Interfaz conciliada (§17): una regla por tema, en el documento dueño, y la cita en el otro. Aquí: el DDL de 0010 y P3b pasan a progresion.md (§3.3, P7); `save_version` queda como contador (§7.3); el cuerpo lleva la sección `progress` (§7.1, §7.3); `CharacterSaver` sin repositorios ni `restore` (§7.5, §14.3); la reclamación trae `character` y `progress` y `prepare` corre antes del WELCOME (§5.2, §6); `id_blocks` en 0003 y el primer bloque en el arranque (§3, §8); la lápida es solo la fila de `characters`, con `ProgressStore.Purge` y `PurgeRetention` (§11); S1–S8; `Summaries` y `ValidateCreate` (§4.4, §4.5); propios personajes sin excepción de entorno y consultas para `gm` (§9.1); auditoría `op:<op_id>` (§9.1); protocolo 7 (§5.4); orden conjunto de paquetes (§14.1) |
| Revisión de la conciliación | bloqueante | Revisores sobre los dos documentos ya conciliados (43 hallazgos, varios repetidos; todos se sostienen): `ticket_id` de 63 bits contra `jsonx.ID` de 2^53; el final repetía las operaciones del guardado en vuelo; errores del progreso en un paquete que llegaba tarde y con ciclo; respuestas del final por un `net_id` reutilizable; baja en `LOADING` sin liberar; reinos en JSON con dos reglas; latido con `lease_id` de `VERIFYING`; auditoría por lote sin actor ni `source` fijo; rutas de operación y libro sin arrendamiento; errores de la base sin clasificar; purga sin orden de bloqueos; retenciones sin mecanismo; libro retenido sin exportar; franjas de migraciones; piezas y pruebas de P7b que eran de progresion.md P5d | `jsonx.ID` hasta 2^63 − 1 y reinos por API (§4.1); baja en `LOADING` y claim con personaje no borrado y `Load` en su transacción (§5.2, §5.3); latido y `revoked` con `lease_id` (§5.3, §6); lotes con rechazo por entrada y campos de S8 (§6, §9.1, §9.2); operación y libro con arrendamiento (§6, §6.1); entradas de `CharacterSaver` por `character_id` tras `finish` y `track` antes de `on_arrival` (§7.2, §14.3); regla de errores del guardado y `last_save_version` (§3, §7.3); errores en `internal/persistence` (§7.5); purga con bloqueos, lápidas en la exportación, reportes y sanciones con plazo, `reapply-purges` con el `purged_at` original (§11); migraciones con el siguiente número libre (§2.4); P4 sube el protocolo y P7b sin lo de P5d (§5.4, §14.1, §15); `body` sin `parse_string`, `instance_id()`, `world_id()` y `key` en `enqueue_batch` (§14.3); casos bajo `tests/fixtures/` (§4.4); social.md §8, red.md §15, habilidades.md §4.6 y backlog. Tabla de §17 al día |
| Segunda revisión de la conciliación | bloqueante | 30 hallazgos sobre los dos documentos (varios repetidos; todos se sostienen, y en cuatro la solución difiere en parte de la propuesta). Aquí: P4 subía a 7 sin esperar a la 6; promesas de la fase 5 de social.md y red.md sin paquete; la expulsión tras un definitivo dejaba el cuerpo 15 s y mandaba un final tras `drop`; quién pone `zone_instance_id` en el guardado; el latido sin conjunto definido; entradas por `character_id` que chocaban al volver a la misma instancia; respuestas 4xx sin clasificar; `ValidateCreate` sin costura; eventos sin `kind` ni consumidor; la ruta de operación sin participantes; secciones ausentes y `pvp` que baja; dependencias entre documentos; `^` y `ceil` en GDScript; varios personajes de una cuenta en el mundo; comandos del fuerte que pagaban al GM; cuentas sancionadas sin exportar; correos y nombres en la auditoría; fortalezas de otra zona; hora de la auditoría; alcance del chat | P4 tras habilidades.md y reparto fijo (§5.4, §14.1); `ChatPeerState` por personaje y sin `REJECT NAME` con billete (§5.4, §9.2); baja sin guardado con el cuerpo fuera en el acto y `drop(net_id, code)` (§7.2, §14.3); el sobre lo arma `CharacterSaver` (§6, §7.3); conjunto del latido en `ZonePlatform` y `save` con `lease_id` y `release_lease` (§5.3, §14.3); entradas por `lease_id` (§7.2); sobre estricto (`envelope`), otro 4xx definitivo y tope de DESTROY (§7.3); `CreateValidator` (§4.4, §7.5); `PlatformEvent.kind` con un consumidor cada uno, `instance_closed` y la cuenta atrás del mantenimiento (§7.2, §14.3); `Op` con la instancia (§6); `progress` obligatoria y `pvp` con `greatest` (§7.3); `RECORD_FORMAT` (§7.1); `ceili` (§8); un personaje en el mundo por cuenta (§4.5, §5.3); sesión de privacidad (§4.2); auditoría sin datos personales y con `at_unix` (§9.1); `zone_channel` (§3, §9.2); fortalezas por zona (§6); pruebas de P5 en P6 y progresion.md P5b (§15). progresion.md, §13.1 |
| Tercera revisión de la conciliación | bloqueante | 25 hallazgos sobre los dos documentos, 23 distintos: 22 se arreglan (en tres, en parte o de otra forma) y uno no es del texto. Aquí: respuestas del arranque sin el evento `id_block`; las marcas «v7» de red.md, reclamadas por los dos P4; la fila de `set-role` sin `command` ni `source`; `FakeZonePlatform` sin API de pruebas; `CheckPassword` sin el correo (oráculo de cuentas); arnés de P10 sin zona de entrada y registro sobre una instancia `live` sin latido; quién compone el texto de `BANNED`; lotes sin atar a la instancia; borrar sin bloqueo frente a la reclamación; la purga de una cuenta y `reapply-purges` que se saltaban a los personajes no borrados; el cierre de §6.1, que echaba antes de mandar los finales con los arrendamientos ya libres; el `world_id` de la zona en reportes, ignorados y sanciones; el riesgo que queda con una zona comprometida; el libro de un personaje vivo sin fila de retención; `/gm teleport` y `/gm visible` que pagaban; un guardado sin ids | Respuestas del arranque y API de `FakeZonePlatform` (§14.3); cada P4 escribe en red.md lo suyo (§5.4); fila fija de `set-role` y `source` y `command` de la CLI (§9.1), con índice en 0005 (§3); `CheckPassword` con el correo (§4.2, §14.2); el registro pasa a `lost` una instancia sin latido, trabajo de perdidas a `min(5 s, HEARTBEAT_S)` y arnés con `test_world` (§2.5, §5.3, §15); cuerpo de `account_blocked` (§6.1; **de otra forma**: el texto lo compone la plataforma, como el `text` de `revoked`, no la zona); lotes validados contra la instancia y el mundo, de la instancia, sin `world_id()` (§6, §14.3); borrar y restaurar bloquean la cuenta (§4.4); la purga mira lo que toca según el camino y `reapply-purges` corre antes de `serve` y sin arrendamientos (§11.2); el cierre de §6.1 expulsa tras los finales y `replace` ya no libera los arrendamientos de la vieja (§5.3, §6.1; **en parte**: se echa a todos a la vez tras `begin_flush`, no a cada uno tras su final); riesgo que queda (§16); retención del libro de un personaje vivo (§11.1, social.md §8); una sección que devuelve `{}` (§7.2; **en parte**: el final no espera al siguiente bloque, porque su estado ya no existe; lo evita la reserva de progresion.md §4.5); `gm_forced` (§8, §9.1); backlog TEC-25. **No es del texto:** social.md 12.7, `ChatPeerState`, `KNOWN_RECIPIENT_TICKS` y «la 5 ya está en main» existen en la línea principal (protocolo 5), de la que este trabajo va por detrás; cuadran al rebasar sobre ella |

La interfaz con progresion.md quedó conciliada después de las tres revisiones: §17 dice qué se acordó y en qué
documento está cada regla. Lo que las filas de arriba nombran y ya no existe (P3b, S3–S9, `progress_purge_character`,
`ProgressRepository`, `PlatformProgressRepository`, el `world_id` de los cuerpos de reportes, ignorados y sanciones y
`ZonePlatform.world_id()`) es anterior a la conciliación o a su última revisión.

## 19. Implementación

Lo que hizo cada paquete, en qué se aparta de este documento y lo que se midió. Cada paquete añade su
apartado al terminar.

### 19.1 P0 · esqueleto (TEC-22)

**Qué hay.** El módulo `platform/` (`eldmark/platform`, `go 1.24.0`, `toolchain go1.24.7`) con `.gdignore`:

| Pieza | Contenido |
|---|---|
| `cmd/eldmark-platform` | `serve`, `migrate up`, `migrate down N`, `migrate status` y `help`; salida 0 bien, 1 error, 2 uso. `status` sale con 1 si falta alguna migración del binario. `down` se niega en `staging` y `production` (§2.4, §12) |
| `internal/config` | Toda la tabla de §2.3, con `<NOMBRE>_FILE` en los cinco secretos. `Load` (serve) y `LoadDatabase` (migrate: solo `ELDMARK_ENV` y la base). Los problemas salen todos a la vez, uno por línea, sin repetir ningún secreto; `Config` se registra con `LogValue`, también sin secretos. `Realm` (códigos de `NetProtocol.Realm` e ids de texto) y `ZoneToken` (alcance y SHA-256) |
| `internal/logx` | `slog` con `JSONHandler`, `MaskEmail` (`a***@example.org`), id de petición y `SetAccount`/`SetCharacter` para los campos `account` y `character` |
| `internal/db` | `Open` (sin conectar todavía; `application_name` y `timezone = UTC`), `Ping`, `Classify` con la regla de §7.3 (`KindIntegrity`: clase 23 y `P0001`; `KindRetryable`: `40001` y `40P01`; `KindUnavailable`: sin conexión, `57014`, `57P01`–`57P03`, clase 08, `53300`), `SQLState`, `Constraint` e `InTx`, que repite la transacción entera ante `40001`/`40P01` (también en el COMMIT) y, agotada, devuelve `ErrConflict` |
| `internal/jsonx` | `Int`, `ID`, `ParseID`, `Decode` y `DecodeBytes` de §4.1. `Int` analiza el número sin pasar por `float64` y admite hasta ±(2^53 − 1); `ID` exige cadena de dígitos sin signo ni ceros a la izquierda, de 0 a 2^63 − 1 |
| `internal/httpx` | El cuerpo de error de §4.1 (`Error`, con `Extra` para el `account_blocked` de §6.1), `Retry-After` en 429 y 503, `DecodeJSON` con los límites de 16 KB y 1 MB (413 y 400 `bad_request`), el registro de cada petición (`req`, `route` con el patrón y nunca la ruta real ni la consulta, `status`, `ms`; nunca el cuerpo), pánico → 500 `internal`, `Health` y `Ready` |
| `internal/app` | El proceso de `serve`: las dos API, `/health` y `/ready` en las dos, `HandlePublic` y `HandleInternal` para los paquetes siguientes, la espera del esquema y la gracia de arranque de §2.5 |
| `internal/migrate` | El ejecutor de §2.4 y `migrations/0001`–`0006` (el DDL de §3 tal cual); `testdata/seed_0001`–`seed_0006.sql` |
| `internal/testdb` | El arnés de §2.6: `Main`, `New`, `NewEmpty`, `ConnString`, `DumpSchema`, `Exec` y `Tables` |

Fuera de `platform/`: `.gitignore` con los patrones de §10.3 (comprobado con `git check-ignore --no-index`:
ignora `platform/deploy/staging.env`, `secrets/ticket_keys`, `zone.key` y un `*.pem` fuera de `tests/`; deja
`staging.env.example` y `tests/fixtures/**/*.pem`); `platform/*` en el `exclude_filter` de los dos destinos de
`export_presets.cfg` y en `test_export_config.gd` (más una prueba de que `platform/` lleva `.gdignore`);
`tools/check_secrets.sh` y el trabajo «Plataforma» de `.github/workflows/tests.yml` (abajo); y un apartado
«Servicio de plataforma (Go)» en el README con las órdenes.

**Para los paquetes siguientes.** Las rutas nuevas se añaden con `App.HandlePublic("POST /v1/sessions", h)` y
`App.HandleInternal(…)`; un cuerpo se lee con `httpx.DecodeJSON(w, r, httpx.PublicBodyLimit, &body)` y un error
se escribe con `httpx.WriteError`. Las pruebas con base llevan `func TestMain(m *testing.M) {
os.Exit(testdb.Main(m)) }` y `pool := testdb.New(t)`. Una migración nueva va en `internal/migrate/migrations/`
con su `.down.sql` y, si crea tablas, su `testdata/seed_NNNN.sql` (la de progresion.md P7 es `seed_0010.sql`): la
prueba de conservación la recoge sola y falla si alguna tabla se queda sin filas.

**Desviaciones y decisiones de la implementación:**

- **`internal/app`**, que §2.1 no nombra: monta `serve` para que `httpx` quede genérico y para probarlo con
  puertos `:0`.
- **`serve` con migraciones pendientes** (§2.4: «no arranca y `/ready` dice por qué»): el proceso sigue vivo,
  `/health` da 200, `/ready` da 503 con el motivo y el arranque espera, mirando el esquema cada 2 s; con el
  esquema al día hace la gracia y pasa a listo sin reiniciar. `/ready` exige además el arranque hecho («La
  plataforma está arrancando»). Cada motivo nuevo se registra una vez, no en cada vuelta.
- **La gracia de §2.5 ya está en P0** (sus tablas existen desde 0003); los trabajos periódicos (perdidas,
  retenciones, purgas) llegan con P3 y P9a.
- **`/ready` es público** (Caddy pasa todo a :24680), así que su motivo no lleva detalles de la base («La base
  de datos no responde»; el de las migraciones solo nombra archivos del repositorio). El detalle va al
  registro. Los sondeos que van bien se registran en `DEBUG` y los que no, en `WARN`.
- **Obligatorias en `serve`** en todos los entornos: `ELDMARK_DATABASE_URL`, `ELDMARK_ZONE_TOKENS` y
  `ELDMARK_TICKET_KEYS` (las de «—» en §2.3); en `staging` y `production`, además, `ELDMARK_MIN_PROTOCOL`,
  `ELDMARK_EMAIL_HMAC_KEY` y SMTP. Detalles que §2.3 no fijaba: las claves (billete y HMAC) en base64 estándar
  de al menos 32 B; la clave HMAC fija de pruebas, como la del vector, no se admite fuera de `dev` y `test`;
  `LEASE_TTL_S` mayor que `HEARTBEAT_S`; cada reino abierto con zona de entrada; un token con dos alcances es un
  error; `ELDMARK_X` y `ELDMARK_X_FILE` a la vez, también; una variable vacía cuenta como ausente.
- **`ELDMARK_MIN_PROTOCOL` en `dev` y `test`:** sin la variable queda `MinProtocol = 0` y
  `Config.ResolveMinProtocol(protocol_version)` da el de las reglas, porque `progression_rules.json` aún no
  existe (lo crea P2 o progresion.md P3). Quien monte el 426 lo resuelve al arrancar.
- **migrate:** la suma SHA-256 es la del `.up.sql` (arreglar un `.down.sql` no rompe nada). `Down` mira todas
  las que va a deshacer (que estén en el binario, con su suma y no irreversibles) antes de tocar nada.
  `Load` exige pares completos, nombres `NNNN_[a-z0-9_]+` desde 0001 y el `raise exception 'irreversible'` en
  el `.down.sql` de una irreversible.
- **Conservación:** la prueba sube versión a versión sobre una base: en cada versión aplica su semilla (si la
  hay), exige al menos una fila en cada tabla y comprueba que la migración siguiente no cambia ningún
  `count(*)`. Cada semilla solo llena las tablas nuevas de su versión.
- **testdb:** el clúster lo levanta la primera prueba que pide una base (un paquete sin pruebas de base no paga
  nada); `NewEmpty` da una base sin migrar (para migrate). Si la ruta del socket pasa de los 107 B (un `TMPDIR`
  largo), el servidor escucha en 127.0.0.1 con un puerto libre, y reintenta si otro proceso se lo quita
  (comprobado con una ruta de 137 B). Un `owner.pid` en la carpeta deja borrar al arrancar los clústeres de
  ejecuciones que murieron sin llegar al final de `Main` (desde la revisión, §19.7, eso lo hace antes un vigilante;
  `owner.pid` queda para un sistema sin `sh`). Un `ELDMARK_PG_BIN` sin `initdb` no busca en otro
  sitio. Las bases se llaman `eldt<pid>_tmpl` y `eldt<pid>_t<n>`, así que valen también contra un servidor
  compartido (`ELDMARK_TEST_DATABASE_URL`, comprobado), donde `Main` las borra al acabar. `DumpSchema` usa
  `pg_dump --schema-only --no-owner --no-privileges` y quita las líneas `\restrict`/`\unrestrict`, que
  PostgreSQL 16.10 y siguientes ponen con una clave distinta en cada volcado. `max_connections = 200`.
- **`TMPDIR` tiene que ser accesible para el usuario `postgres`** cuando las pruebas corren como root. En esta
  máquina, bajo el scratchpad de la sesión el servidor cae a media prueba (`/tmp/claude-0` vuelve a 0700
  mientras corre); con el `TMPDIR` por defecto (`/tmp`) va bien.
- **`db.InTx`:** «tres veces» de §7.3 son tres reintentos, cuatro intentos en total (`MaxAttempts`).
- **413:** código `too_large` («La petición es demasiado grande»), que §4.1 no nombraba.
- **Secretos:** la comprobación de §10.3 está en `tools/check_secrets.sh [raíz]`, que se puede correr en local;
  la CI la corre la primera. Probada en un repositorio desechable: limpio → 0; un `staging.env`, un
  `secrets/ticket_keys` o un `zone.key` en el índice → 1 y los nombra; un `ELDMARK_TICKET_KEYS=…` en un
  `*.example` → 1 sin repetir el valor. `ELDMARK_X_FILE=` no cuenta.
- **CI:** el trabajo «Plataforma» corre aparte de los de Godot (sin tocarlos): checkout sin LFS, la comprobación
  de secretos, `actions/setup-go@v5` con `go-version-file: platform/go.mod`, el PostgreSQL de `ubuntu-latest`
  (o `apt-get install postgresql-16` si falta), `gofmt -l`, `go vet ./...` y `go test -p 2 ./...` con
  `GOTOOLCHAIN=local` y `ELDMARK_REQUIRE_PG=1`. Para que bloquee el merge hay que marcarlo como obligatorio.
- **`.gitignore`** ignora también el binario `platform/eldmark-platform`.
- **Dependencias:** las de §2.2 que hacen falta ya (pgx v5.8.0 y x/text v0.31.0); pgx trae además, indirectas,
  `jackc/puddle/v2` v2.2.2, `golang.org/x/sync` v0.18.0, `pgpassfile` y `pgservicefile` (todas con `go` ≤
  1.24.0). x/crypto entra con P1 (argon2).

**Medido** (esta máquina, 4 núcleos, Go 1.24.7, PostgreSQL 16.15):

| Qué | Tiempo |
|---|---|
| `go test ./...` con la caché de compilación vacía | 44 s de reloj, casi todo compilación |
| `go test -p 2 ./...` con la caché caliente (como la CI) | 11 s; ningún paquete pasa de 5 s |
| `go test -race ./...` | 50 s, sin carreras |
| Clúster (`initdb` y arranque) más la plantilla con 0001–0006 | 1,3 s, una vez por paquete |
| Base de una prueba (`create database … template`) | 85–105 ms (§2.6 decía 60 ms) |
| `eldmark-platform migrate up` de 0001–0006 en una base vacía · `migrate down 6` (la orden entera) | 125–145 ms · 45–60 ms |
| Binario (`go build`) | 15,7 MB |

Comprobado a mano con el binario contra un clúster efímero: `serve` sin migrar da `/health` 200 y `/ready` 503
(«la base no tiene migraciones; ejecuta «eldmark-platform migrate up»»); tras `migrate up`, `/ready` 200 en las
dos API en la siguiente vuelta; una ruta desconocida, 404 `not_found` con `X-Request-Id`; SIGTERM cierra con
código 0. Godot: `--import` da el mismo registro con y sin `platform/`; `test_export_config` (10),
`test_assets` (7) y `test_architecture` (16) pasan.

**Sin comprobar:** el trabajo «Plataforma» en GitHub (el PostgreSQL de `ubuntu-latest` y que `setup-go` lea la
línea `toolchain`); `serve` con HTTPS directo (`ELDMARK_TLS_*`: está el código, sin prueba).

**Queda para después:** la orden `admin` (P1 y P7a), las rutas de `/v1` y de `/internal/v1` (P1–P3), los
trabajos periódicos (P3, P9a), los textos legales en `legal_documents` al arrancar (P1) y `deploy/` (P9b),
donde irá el compose de desarrollo que nombra TEC-22.

### 19.2 P1 · cuentas (TEC-23, TEC-41, aceptación de TEC-43)

**Qué hay.** Las cuentas y las sesiones de §4.1 a §4.3, montadas en `serve`:

| Pieza | Contenido |
|---|---|
| `internal/passwords` | `Params`, `Hash`, `Verify` (con `needsRehash`) y `Filler` (el hash de relleno) de §14.2: argon2id en cadena PHC, sal de 16 B y hash de 32 B. Como mucho `runtime.NumCPU()` cálculos a la vez en todo el proceso; una cadena que pide más de 1 GiB o 64 pasadas es `ErrFormat` |
| `internal/accounts` | El servicio y sus rutas (abajo): `CheckPassword` con los fallos por cuenta y grupo de IP, registro sin delatar cuentas, inicio de sesión con la sesión de privacidad, refresco que rota en la fila, ciclo de vida con enlaces de un solo uso, exportación, purga de cuentas, páginas `/verify`, `/reset` y `/revert`, `/v1/status` y `/v1/legal` |
| `internal/mail` | Las ocho plantillas en español (`verify_email`, `register_existing`, `register_blocked`, `reset_password`, `change_email`, `email_changed`, `email_reverted`, `login_failures`), `LogSender` (`outbound_mail` y el registro con el enlace entero), `SMTPSender` (cola en segundo plano, STARTTLS obligatorio salvo hacia loopback, `smtps://` con TLS directo, dos reintentos), `BuildMIME` (`mime.QEncoding`, quoted-printable) y `Recorder` para pruebas |
| `internal/ratelimit` | Cubo de fichas por clave y LRU de 100 000 claves (§4.2) |
| `internal/clock` | El reloj inyectable de §15 (`clock.Fake` en las pruebas): todo plazo de cuentas se compara con la hora de Go pasada como parámetro, no con `now()` |
| `platform/legal` | `terms-1.md`, `privacy-1.md` (con la tabla de §11.1) y `rules-1.md` (la escala de social.md §9), borradores con la cabecera de §11.4, embebidos en el binario; `Load`, `Current` y `Sync` (inserta en `legal_documents` las versiones que faltan) |
| `internal/httpx` | `ClientIP` (`X-Real-IP` solo desde `ELDMARK_TRUSTED_PROXIES`), `AddrGroup` (IPv4 entera, IPv6 por /64), `RequireProtocol` (426 `client_outdated` con `min_protocol`) y `Fail` (un error de la base no disponible → 503; cualquier otro → 500, registrado con el id de la petición) |
| `internal/app` | `OnBoot` (lo que corre al arrancar con el esquema al día: la publicación de los textos), `AddJob` (trabajos periódicos con `pg_try_advisory_lock`) y 503 en las rutas de los paquetes hasta que el arranque termina |
| `cmd/eldmark-platform` | `mountServices` (`services.go`): textos, correo según `ELDMARK_MAIL`, el servicio, sus rutas y el trabajo `accounts_purge` cada hora |

Rutas: las de §4.2 y §4.3 tal cual, todas con la regla del 426. La sesión de privacidad admite solo `GET
/v1/account`, `POST /v1/account/export`, `POST` y `DELETE /v1/account/deletion` y `DELETE /v1/sessions/current`
(y el refresco, que no lleva token de acceso); el resto, con la sesión de privacidad o con una sanción vigente, da
403 `account_suspended` o `account_banned` con `until` y `reason`.

**Para los paquetes siguientes.** P2 monta sus rutas con `httpx.RequireProtocol(min, api.RequireSession(false,
h))` y lee la sesión con `accounts.SessionFrom(ctx)` (cuenta, rol, estado y ámbito); así `enter` da ya el 403 de
una sanción. Para el resto de comprobaciones de `enter` (§4.5) tiene `accounts.ActiveRestriction`,
`Service.MissingAcceptances` (los textos por aceptar: `terms_required`) y `Service.Slots` (6 más los derechos
`character_slots`). P3 compone el `message` de `account_blocked` con `Restriction.Message()` (cortado a 255 B).
La purga de los personajes de una cuenta entra por `accounts.CharacterPurger` (P2 o P9a).

**Desviaciones y decisiones de la implementación:**

- **Textos legales en el binario.** `platform/legal` es un paquete de Go con `//go:embed *.md`, y
  `ELDMARK_LEGAL_DIR` vacía (antes `platform/legal`) significa «los del binario»: la ruta relativa dependía de
  dónde se arrancara (el README arranca `serve` desde `platform/` y la imagen solo lleva el binario). Con la
  variable, se leen de esa carpeta. Una versión publicada cuyo texto cambia no arranca en `staging` ni en
  `production` (la cuenta aceptó el anterior: un texto nuevo es un archivo nuevo); en `dev` y `test` se
  actualiza su SHA-256 con un aviso.
- **Los borradores llegan ya en P1** (§14.1 los ponía en P9a): el registro exige aceptarlos. P9a los revisa;
  hasta que se publiquen en staging, cambiarlos no pide versión nueva.
- **`ELDMARK_MAIL_FROM`**, nueva: el remitente (por defecto `no-reply@<máquina de ELDMARK_PUBLIC_URL>`, o
  `no-reply@localhost` si es una IP).
- **Protocolo mínimo.** Hasta que exista `progression_rules.json` (P2), en `dev` y `test` sin
  `ELDMARK_MIN_PROTOCOL` el mínimo es 0: vale cualquier cabecera con un entero positivo, y `/v1/status` da
  `min_protocol: 0`. Sin la cabecera, 426 siempre.
- **`/verify` confirma también el cambio de correo:** el correo `change_email` enlaza a `/verify`, que mira el
  propósito del enlace (§4.3 solo nombra tres páginas). Confirmar el cambio revoca **todas** las sesiones, no
  «las demás»: el enlace llega sin sesión.
- **Cuerpos que §4.2 no fijaba.** `GET /v1/account` da `realms` y `slots` como mapas por mundo (`{"1": 6}`),
  `pending` con `terms_required`, `documents` (los tipos por aceptar) y `deletion_at`, y además `restriction`
  (`null` o como en el inicio de sesión). El refresco devuelve el par con `scope`. Verificar, confirmar y
  revertir dan 204; las fechas van en Unix.
- **Códigos nuevos:** 409 `deletion_expired` al cancelar un borrado con el plazo vencido antes de que pase la
  purga horaria (sin borrado pedido, cancelar da 204); 503 `unavailable` cuando la base no responde, una
  transacción choca demasiadas veces o la plataforma está arrancando (§4.1 no tenía código para eso); 413
  `too_large` (de P0). `auth_events.kind` añade `register_blocked`.
- **Fallos de contraseña.** Tras 5 fallos seguidos desde un grupo, cada fallo más vuelve a bloquear 15 min, y
  desde el 10.º, 1 h. El freno de la cuenta (un intento cada 30 s) cuenta desde el último fallo. Un intento
  frenado no mira la contraseña ni cuenta como fallo. Con el correo sin cuenta (o la cuenta sin contraseña)
  se hace la misma consulta (con el id 0) y la comprobación contra el relleno. Desde la revisión (§19.7), los
  intentos de una misma clave van de uno en uno.
- **Límite de correos.** «3 por cuenta y hora» va por destinatario (el SHA-256 del correo), así que pesa igual
  exista o no la cuenta; el cambio de correo gasta además de la cuenta que lo pide. Cubo de fichas: ráfaga de 3
  y una ficha cada 20 min (igual con el resto de límites por hora).
- **Purga de cuentas ya en P1**, la de §11.2 en lo que es de la cuenta: la usan las cuentas sin verificar
  (staging y production) y las de borrado vencido (en todos los entornos). Borra además `auth_events`,
  `account_realms` y `outbound_mail` de la cuenta. Sin `CharacterPurger`, una cuenta con personajes sin
  purgar no se purga y se registra («tiene personajes»), y la vuelta siguiente lo reintenta.
- **Huella de los correos sancionados**, ya en P1 porque la purga la necesita: cada sanción sin revocar cuenta
  hasta 90 días después de su fin (un aviso o un renombrado, sin duración, desde que se puso; una expulsión
  permanente, el tope), con 1 año como mucho desde la purga. P9a la revisa con la tabla de §11.1.
- **Exportación ya en P1** (§4.3 la pone en el ciclo de vida y §15 P1 la prueba): cuenta sin hash,
  aceptaciones, consentimientos, sesiones y accesos de 30 días, derechos, reinos, personajes con sus
  estadísticas PvP, ignorados por nombre, sanciones sin autor, reportes hechos y chat enviado. Falta el
  progreso de cada personaje (`ProgressStore.Export`, P9a). Las fechas van en RFC 3339: es un archivo para
  personas.
- **Correo:** además de §4.2, las etiquetas del dominio solo admiten `[a-z0-9-]`, sin guion al principio ni al
  final. Se quitan los espacios de alrededor, no otros blancos: un salto de línea al final no vale.
- **Páginas:** `/reset` pide la contraseña dos veces; un enlace usado, caducado o con el correo ya en uso lo
  dice la página (400) sin repetir el token. No hay protección CSRF aparte: el token de un solo uso lo es.

**Pruebas** (`internal/accounts`, con la base efímera y el reloj falso): todas las de §15 P1, más el bloqueo
de 1 h tras 10 fallos, el freno de 6 s del cubo por IP, los cuerpos que no valen (CR/LF, IDN, nombre visible,
dos @, contraseña corta, larga o igual al correo, versiones viejas, campos desconocidos, 1.5 en una versión,
413), el límite de registros y de correos (también con un correo sin cuenta, que no recibe nada), la
recuperación (revoca todas las sesiones e invalida los enlaces), el cambio de correo hacia uno con cuenta
(`register_existing`), una versión nueva de un texto (`terms_required` hasta aceptarla; el registro la exige),
consentimientos, huecos con derechos, `/v1/status` con la carga y `/v1/legal`, la página `/verify` con un
cambio de correo, `/reset` y `/revert`, la exportación (una al día) y la purga de una cuenta sancionada, cuyo
correo ya no se registra. Además: `passwords`, `mail` (con un servidor SMTP falso), `ratelimit`, `legal`
(`Sync` estricto y no), `httpx` (IP del cliente, 426, `Fail`), `app` (ganchos, trabajos y su bloqueo, 503
hasta arrancar) y `serve` montado de verdad (textos publicados al arrancar y un registro con su correo).

**Medido** (esta máquina, 4 núcleos, Go 1.24.7, PostgreSQL 16.15):

| Qué | Tiempo |
|---|---|
| argon2id con los parámetros de producción (`m=19456,t=2,p=1`) | 32 ms por comprobación (§0 decía 59 ms en las sondas) |
| `go test -p 2 -count=1 ./...` con la caché de compilación caliente | 18 s; `internal/accounts`, el más lento, 10 s (30 pruebas) |
| `go test -race -p 2 ./...` | 34 s, sin carreras |
| Binario | 19,6 MB (15,7 MB en P0) |

Godot: `--import` da el mismo registro con y sin `platform/`.

**Sin comprobar:** el envío por un servidor SMTP real (STARTTLS y autenticación: la prueba usa un servidor
falso en loopback, sin TLS); la exportación y la purga con personajes (P2 y P9a).

**Queda para después:** en `enter`, `terms_required`, `email_unverified` y `account_pending_deletion` (P2, con
lo de arriba); los límites de comprobar nombres y de entrar (P2); la orden `admin` (P7a), con la que se
crearán la primera cuenta `admin` y las de prueba (`dev.sh`, P9b); el mantenimiento programado y las noticias
de `/v1/status` (TEC-28; hoy `status` solo mira `worlds.status`); las retenciones horarias (P9a); el progreso
en la exportación (P9a); y el cliente (P8).

### 19.3 P2 · personajes (TEC-24, SOC-13, PRG-41)

**Qué hay.** Los personajes y la entrada al mundo de §4.4 y §4.5, montados en `serve`, y lo que comparten Go y
Godot (reglas exportadas, casos de nombres y vectores del billete):

| Pieza | Contenido |
|---|---|
| `internal/gamedata` | `progression_rules.json` con `//go:embed`. `Load` y `MustLoad` leen y comprueban `protocol_version` y `names`; las demás secciones no se miran aquí (son de progresion.md) y `Raw` da el archivo entero para `progress.LoadRules` |
| `internal/names` | `NameRules` en Go (§14.2): `Validate` (con los valores de `NameRules.Reason` y su código de la API, `too_short`…), `NormalizeKey`, `IsReserved` y `ReasonText`, todo leído de la sección `names`; `names.Validate` y `names.NormalizeKey` usan las reglas incrustadas |
| `internal/tickets` | El billete de §5.1: `Ticket`, `ZoneKey`, `Sign`, `Parse` (comprueba, en este orden, tamaño, versión, clave y firma: `ErrSize`, `ErrVersion`, `ErrKey`, `ErrMAC`), `NewID` (de 1 a 2^63 − 1) y `Lifetime` (10 s) |
| `internal/persistence` | `progress.go`, la frontera de §7.5 con las firmas de progresion.md §13.2 (`ProgressStore`, `CreateParams`, `SaveKey`, `Summary`, `Querier`, `InvalidSaveError`, `ErrNotFound`, `CreateValidator`, `ValidationError`) y `ProvisionalValidator` (§4.4 paso 5); `memory.go`, el falso: `MemoryProgressStore` |
| `internal/characters` | El servicio y sus rutas (`List`, `NameCheck`, `Create`, `Delete`, `Restore`, `Rename`, `Enter`) y la purga de personajes (`Purger`: `PurgeExpired`, el trabajo horario, y `PurgeAccountCharacters`, el `accounts.CharacterPurger` de P1) |
| `internal/accounts` | `Service.Event` (la fila de `auth_events` en la transacción de quien llama) y `ErrCharactersBusy`, que la purga de cuentas registra como aviso |
| `cmd/eldmark-platform` | `serve` resuelve el protocolo mínimo con `progression_rules.json`, elige el almacén del progreso y la validación (`progressStore`, §7.5), monta los personajes y añade el trabajo `characters_purge` (cada hora) |
| Godot | `ProgressionRulesExport` (`scripts/shared/progression/`, secciones `protocol_version` y `names`), `tools/progression/export_rules.gd` (con `-- --check` no escribe) y `tests/test_progression_rules_export.gd`. En `NameRules`, `FOLDED` (antes `_FOLDED`, privada), `REASON_CODES`, `reason_code` y `reason_from_code` |
| Datos de prueba | `tests/fixtures/names/name_rules_cases.json` (119 casos `{name, reason, key}`, con el motivo en su código de la API), que leen `test_name_rules.gd` e `internal/names`; `tests/fixtures/tickets/handoff_ticket_vectors.json`, para `HandoffTicket` (P4) |

Rutas: las de §4.4 tal cual, todas con la regla del 426 y `RequireSession(false)` (una cuenta sancionada recibe
403 con el motivo). Cuerpos que §4.4 no fijaba: crear (201), restaurar y renombrar responden `{character}`;
borrar, `{restore_until}`; la lista, `{realm, unlock_at, slots, used, characters}` con `realm` null si la cuenta
aún no tiene reino en ese mundo. Un personaje trae `race_id`, `appearance` (base64) y `last_zone_id` a null
(y el nivel a 1) si el almacén no lo tiene. `name-check` da `code` y `reason` vacíos cuando no aplican. En los
errores, `name_invalid` lleva `reason`; `realm_locked`, `realm` y `unlock_at`; `terms_required`, `documents`;
`account_pending_deletion`, `deletion_at`; y `maintenance`, `until` (null hasta TEC-28). Las fechas, en Unix.

**Para los paquetes siguientes.**

- **P3** tiene la interfaz y el falso: `MemoryProgressStore.SetApplyHook` decide el resultado de `Apply` (un
  `*InvalidSaveError`, un error de la base…), `Load` devuelve lo último aplicado sin `ops` y con los campos de
  solo lectura, y `Apply` saca del cuerpo el nivel, el tiempo jugado y la última zona del resumen. El billete
  queda en `enter_tickets` con `session_id`, `zone_instance_id` y `expires_at` (emisión + 10 s, con el reloj de
  Go). `characters.last_entered_at` no se escribe: puede ponerlo la reclamación.
- **P4** comprueba `HandoffTicket` con los vectores compartidos (ids en cadena, `String.to_int()`).
- **progresion.md P3** añade sus secciones a `ProgressionRulesExport.build()` (una función por sección, como
  `_names`) y comprueba las suyas en la misma prueba; **P7** implementa `ProgressStore` y `CreateValidator`
  (`*progress.Rules`) y cambia solo `progressStore()` de `cmd/eldmark-platform/services.go`, que dejará de
  negarse en `staging` y `production`.
- **P7a**: `admin names block|unblock` escribe `name_blacklist` con `names.NormalizeKey`; la sanción `rename`
  pone `characters.must_rename`, y P2 ya responde `rename_required` en `enter` y deja renombrar.
- **P9a** tiene ya la purga de personajes (abajo); le quedan `reapply-purges`, la retención del libro con
  `PurgeRetention` y el borrado de las lápidas vacías, y el progreso en la exportación.

**Desviaciones y decisiones de la implementación:**

- **Crear no es serializable** (§4.4 lo pedía): bloquea primero la fila de la cuenta, como borrar y restaurar,
  y eso pone en serie todo lo que es de la cuenta (reino, huecos y límite diario); el nombre lo decide la clave
  primaria de `character_names` con `insert … on conflict do update … where` la fila está reservada y vencida.
  **Medido:** con serializable, 8 cuentas creando a la vez personajes de nombres distintos recibían 503 en 4 de
  20 ejecuciones de la prueba (SSI con bloqueos de predicado sobre tablas pequeñas, que agotaban los 4 intentos
  de `db.InTx`); con la fila de la cuenta, en ninguna de 25, y las dos creaciones del mismo nombre siguen dando
  una sola fila y `name_taken` a las demás (25 de 25).
- **El falso en `serve`.** Hasta progresion.md P7, `serve` usa `MemoryProgressStore` y `ProvisionalValidator` en
  `dev` y `test`, con un aviso en el registro: el progreso (raza, apariencia, nivel…) se pierde al reiniciar. En
  `staging` y `production` no arranca («el almacén del progreso (docs/progresion.md P7) aún no existe…»).
- **La purga de personajes llega ya en P2** (§14.1 la ponía en P9a): la de §11.2 en sus dos caminos de ahora
  (plazo vencido, en el trabajo horario, y con la cuenta, en la purga de P1), con los bloqueos del arrendamiento
  y de la fila del personaje, la lápida, `purge_log` y `ProgressStore.Purge`, y sin purgar con un arrendamiento
  vivo (la vuelta siguiente lo reintenta; con la cuenta, `accounts.ErrCharactersBusy` y la cuenta tampoco se
  purga). Con la cuenta, el nombre de un personaje vivo queda reservado 30 días; el de uno borrado conserva su
  reserva. Sin ella, la purga de P1 dejaba sin purgar toda cuenta con personajes.
- **Restaurar** un personaje que no está borrado lo devuelve tal cual (200); fuera de plazo o purgado, 404.
  **Borrar** uno ya borrado, 404.
- **Renombrar** sin `must_rename` da 409 `rename_not_required` (código nuevo); con el personaje en el mundo,
  `character_busy`; al mismo nombre con otras mayúsculas o tildes, `name_taken`.
- **Validación provisional:** una raza de otro reino es `wrong_realm` y una que no existe, `unknown`; una
  apariencia que no es base64 de 8 B o un reino desconocido son 400 `validation` (`appearance` o `realm:
  invalid`) antes de abrir la transacción, como un campo que falta (`required`).
- **`enter`.** El mantenimiento (`worlds.status = 'maintenance'`, 503 `maintenance` salvo para `admin`) se mira
  después de las sanciones, que ya mira `RequireSession`, y no antes como en §4.5. `worlds.status = 'locked'`
  no hace nada todavía. La última zona vale si tiene un canal vivo que admite el reino **y con sitio**; si todos
  están llenos, la de entrada (§4.5 no lo decía). No se ofrece una instancia con un canal fuera de 0–255 (el
  billete lo lleva en un u8). No mira el latido: dar por perdida una instancia es del trabajo de P3. Un
  `ticket_id` que choca con la clave primaria se cambia por otro (hasta tres intentos).
- **Límites:** `name-check`, 30 por minuto y sesión, y `enter`, 10 por minuto y cuenta, en memoria; crear y
  borrar, 5 al día con `auth_events`. El 429 de crear y borrar lleva lo que falta para que salga de las 24 h la
  más vieja de las 5.
- **`NormalizeKey`** pasa cada carácter a minúscula con `unicode.ToLower`, como `String.to_lower()`; los 119
  casos compartidos (con invisibles, combinantes, cirílico y anchura completa) dan lo mismo en los dos lados.
- **`progression_rules.json`** lo crea este paquete (§4.4: «quien llegue antes»), con `protocol_version` 5, la de
  main (la sube P4), y `names`. Una prueba de Go comprueba que su `protocol_version` es el de
  `net_protocol.gd`. En `dev` y `test` sin `ELDMARK_MIN_PROTOCOL`, el mínimo pasa de 0 (P1) a ese número.
- **Vectores del billete:** `handoff_ticket_vectors.json` lo genera la prueba de Go (`go test ./internal/tickets
  -run TestSharedVectors -update`) y la prueba falla si el archivo no coincide. Lleva las dos claves en
  hexadecimal, cinco huellas de zona, el vector de §5.1 (también en el base64 de §4.5), uno con `ticket_id` 2^63
  − 1 y `character_id` 2^53 + 1, uno de traspaso (mundo 513, canal 255, fechas al final del u32) y 9 inválidos
  con el error que toca (`mac`, `key`, `version` o `size`).

**Pruebas** (`internal/characters`, con la base efímera, el reloj falso y el falso del progreso; 26): todas las
de §15 P2 (casos de nombres en Go y en Godot; dos creaciones simultáneas del mismo nombre, en tres rondas de 8
cuentas; «Anéira» frente a «ANEIRA» y «Aneira»; reino bloqueado; huecos con un borrado en plazo; el sexto
personaje del día; crear y borrar enseguida libera el nombre en `restore_until`; raza y plantilla que no valen;
borrar, restaurar y nombre reservado; `enter` sin zona viva; `enter` elige la última zona; el vector del
billete), y además: creaciones simultáneas de cuentas distintas, lista negra, reino que se libera a los 30 días
y se cambia, derechos de huecos (también revocados), un borrado fuera de plazo que deja de ocupar, campos que
faltan o sobran, cuenta con el borrado pedido y cuenta suspendida (403 en todas las rutas), límite de
`name-check`, confirmación del borrado, borrar con el personaje en el mundo y el límite de borrados, personajes
de otra cuenta (404), renombrado forzado (también en el mundo), el billete de `enter` leído con `tickets.Parse`
y su fila en `enter_tickets`, DTLS, la elección de zona y canal (último canal, lleno, reino que no admite,
parada), las comprobaciones de `enter` en orden (correo, textos, borrado pendiente, mantenimiento y `admin`,
borrado, límite), un solo personaje de la cuenta en el mundo, la purga horaria (con arrendamiento vivo, lápida,
nombre reservado, repetida), una restauración que gana a la purga y la purga de una cuenta con personajes.
Además: `names` (casos compartidos, reglas de otros datos, UTF-8 roto), `tickets` (vector, errores, 1000 idas y
vueltas, `NewID`, vectores compartidos), `persistence` (errores, validación provisional, el falso), `gamedata`
y `serve` (personajes montados, protocolo mínimo de las reglas, y se niega con el falso en `staging` y
`production`). En Godot: `test_progression_rules_export.gd` (5) y dos pruebas nuevas en `test_name_rules.gd`.

**Medido** (esta máquina, 4 núcleos, Go 1.24.7, PostgreSQL 16.15):

| Qué | Tiempo |
|---|---|
| `go test -p 2 -count=1 ./...` con la caché de compilación caliente | 14 s; `internal/characters`, 3 s (26 pruebas) |
| `go test -race` de los paquetes nuevos y de `accounts` | 20 s, sin carreras |
| Las dos pruebas de concurrencia, 25 veces seguidas | 14 s, sin fallos |
| Binario | 19,8 MB (19,6 MB en P1) |

Godot: `--import` da los mismos avisos y errores con y sin los cambios (las fugas al salir de siempre), y la suite
entera pasa (1924 pruebas en 1048 s). Un script de GDScript desechable leyó los vectores del billete con
`JSON.new().parse`: las huellas (`sha256_buffer().decode_u32(0)`), las firmas con la clave 1 (`HMACContext`) y el
`ticket_id` de más de 2^53 (`String.to_int()`) dan lo mismo que en Go.

**Sin comprobar:** `enter` contra una zona de verdad (la reclamación es de P3; el billete en la zona, de P4; los
dos juntos, de P10); `NormalizeKey` con caracteres cuyo paso a minúsculas difiera entre las tablas Unicode de Go
y de Godot (ninguno de los casos lo hace).

**Queda para después:** la reclamación que consume el billete y `last_entered_at` (P3); `HandoffTicket` con los
vectores (P4); `admin names block|unblock` y la sanción `rename` (P7a); el cliente (P8); `reapply-purges`, la
retención del libro, el borrado de las lápidas vacías y el progreso en la exportación (P9a); las secciones de
progresion.md en las reglas exportadas y `*progress.Rules` con el almacén de verdad (progresion.md P3 y P7).

### 19.4 P3 · API interna (TEC-24, TEC-25)

**Qué hay.** La API interna de §6 entera, montada en `serve` sobre `ELDMARK_INTERNAL_ADDR`, con el trabajo de
instancias perdidas:

| Pieza | Contenido |
|---|---|
| `internal/zones` | `Registry` (`Authenticate`: SHA-256 del token y `subtle.ConstantTimeCompare` con todas las entradas), `Scope`, `Instance` y la tabla de estados de §6.1 (`Instance.Check` por petición), `Guard` (los pasos 1 a 3 de §6.1: 401 `bad_token`, 403 `forbidden` y el 409 del estado), `Fail` (503 `db_unavailable`), los UUID (`NewUUID` de `crypto/rand`, `FormatUUID`, `ParseUUID`), el servicio (`Register` con sustitución y perdida al registrar, `Live`, `Heartbeat`, `Stop`, `MarkLost`, `IDBlock`) y sus rutas; para los lotes, `DecodeBatch`, `ParseEntry`, `KeyChecker` (key `<uuid>:<n>` de la instancia u `op:<op_id>` de sus bloques) e `InsertEach` |
| `internal/persistence` | `store.go`: `Store` con `Claim`, `Save`, `SaveMany` y `Release` de §14.2, `ParseEnvelope` (el sobre estricto) y `SaveError` (la regla de errores de §7.3); `api.go`: las rutas de reclamación, guardado, lote de guardados, liberación, operación y libro. `memory.go` (el falso) añade lo de abajo |
| `internal/war` | Fortalezas (GET de la zona de la instancia, PUT con versión) y el lote de eventos de guerra |
| `internal/social` | Los lotes de chat y de auditoría, ignorados, reportes y sanciones con la autorización de §9.5 |
| `internal/sanctions` | Hoja nueva: la restricción vigente (`Active`, `ActiveMany`), los silencios (`Mutes`), los textos para el jugador (`Restriction.Message`, `PendingDeletionMessage`, `Truncate` a 255 B), `Rank` y `MinRole` (§9.1) |
| `internal/platformtest` | Para las pruebas: la plataforma entera en el proceso (base efímera, reloj falso, progreso en memoria, las dos API) con ayudas de cliente (`NewPlayer`, `NewCharacter`, `MustEnter`) y de zona (`Zone.Start`, `Join`, `Heartbeat`, `SaveBody`, `Save`…) |
| `internal/accounts` | `ActiveRestriction` y `Restriction.Message` usan `internal/sanctions`: un solo texto para el 403 de la API pública, el `account_blocked` de la reclamación y el `text` del latido |
| `cmd/eldmark-platform` | `mountInternal` (`services.go`): zonas, almacén, guerra y lo social, y el trabajo `zones_lost` cada `min(5 s, HEARTBEAT_S)` |

Todas las rutas de la tabla de §6, en el orden de comprobaciones de §6.1. Cuerpos que §6 no fijaba:
`POST /internal/v1/saves` responde `{instance_status, saves: [{character_id, applied, duplicate,
save_version}]}` en el orden del lote, y un error de uno lleva además su `character_id`; `DELETE
/internal/v1/ignores` lleva el mismo cuerpo que el `POST` y da 204 aunque no hubiera nada; la sanción responde
`{sanction_id, ends_at_unix}`; un reporte, `{report_id}`. Códigos nuevos: 409 `ignore_list_full` (100
ignorados) y el `not_found` de un nombre que no existe en el mundo de la instancia.

**Para los paquetes siguientes.**

- **P4** (la zona): los cuerpos y errores son los de §6 con lo de arriba. La reclamación da
  `muted_until_unix` 0 sin silencio y `253402300799` (`sanctions.NoEndUnix`) en uno sin fin; `revoked` trae
  `text` compuesto por la plataforma (también en `lease_lost`: «Tu personaje ha entrado en otro servidor»);
  `account_blocked` trae `message` de 255 B como mucho. `maintenance` del latido es siempre null (TEC-28).
- **P5**: el guardado acepta `release_lease` ausente (false); `seq` empieza en 1 y puede saltar números; un
  `duplicate` no vuelve a llamar a `Apply`.
- **P6**: el primer PUT de una fortaleza lleva `expected_version` 0; una que no existe con otro valor es 409
  `version_conflict` con `version` 0. El GET devuelve el registro como lo guarda `jsonb` (claves reordenadas).
- **P7a**: las rutas internas de ignorados, reportes y sanciones ya están (abajo). Quedan la CLI `admin`
  (`set-role` con su fila, `reports list|show|close`, `audit`, `chat`, `names block|unblock`, `sanction`,
  `purge-now`), las consultas auditadas y las pruebas de caducidad de cada sanción.
- **progresion.md P7**: la ruta de operación llama a `Op(ctx, pool, opID, instance)` sin transacción y la del
  libro a `Ledger(ctx, pool, …)` después de mirar el arrendamiento del personaje en la instancia; `Apply`
  recibe `SaveKey` con `ZoneID` de la instancia `claimed_by` y `WorldID` del arrendamiento, dentro de la
  transacción que ya tiene el arrendamiento bloqueado y el `seq` comprobado.
- **P9a**: las retenciones de `enter_tickets` (1 día), `zone_instances` paradas (30 días), `chat_messages` y
  `audit_log`.

**Desviaciones y decisiones de la implementación:**

- **Ignorados, reportes y sanciones ya en P3** (§14.1 los ponía en P7a): §15 P3 los prueba (el mundo lo pone
  la instancia) y la tabla de §6.1 los incluye. Están enteros, con la autorización de las sanciones en tres
  pasos y la fila `sanction_denied`.
- **Paquetes nuevos que §2.1 no nombra:** `internal/sanctions`, una hoja, para que ni `zones` ni `persistence`
  importen `accounts` (cuando P9a lleve `ProgressStore.Export` a la exportación de `accounts`, `accounts →
  persistence → accounts` sería un ciclo), y `internal/platformtest`, el arnés de las pruebas de la API interna.
- **El reloj.** Todas las horas de P3 salen del reloj inyectable de Go (`started_at`, `last_heartbeat_at`,
  `expires_at` de los arrendamientos, `consumed_at`, `granted_at`…), no de `now()`: las pruebas adelantan el
  reloj en lugar de esperar los 15 s de una instancia perdida o los 30 s del TTL. La gracia de arranque de P0
  sigue con `now()` (en `serve` los dos relojes son el mismo).
- **Reclamación.** Bloquea antes la fila de la instancia (`for share`): el orden es instancia → cuenta → billete
  → arrendamiento, y el trabajo de perdidas y el latido (que la actualizan) no se cruzan con una reclamación en
  curso. Lee la cuenta del personaje antes de bloquearla y vuelve a mirar el personaje después. Un personaje de
  otro mundo que el de la instancia o de una cuenta purgada es `ticket_invalid`. Toma un arrendamiento con
  `expires_at ≤ ahora` (§5.3 decía `<`: así «caducado» es justo lo contrario de «vivo», `expires_at > ahora`,
  que miran `enter`, borrar y la propia reclamación). Escribía `characters.last_entered_at`; desde la revisión
  (§19.7) lo escribe el primer guardado del arrendamiento, y el 403 `account_blocked` sale después de validar el
  billete.
- **Latido.** Prioridad de `revoked` por cuenta: `banned` > `suspended` > `pending_deletion` >
  `session_revoked`. Los textos de `session_revoked`: «Has iniciado sesión desde otro lugar» (`replaced`), «Has
  cerrado la sesión» (`logout`), «Un administrador ha cerrado tu sesión» (`admin`) y «Tu cuenta ha cambiado:
  vuelve a entrar» (el resto). Los expulsados se siguen renovando: la zona aún manda su guardado final. Un
  `lease_lost` sale una vez por personaje aunque el latido lo repita.
- **Registro.** `protocol_version` por debajo del protocolo mínimo de los clientes, o `record_format` distinto
  de 1: 409 `schema_mismatch`. El certificado se lee como X.509 en PEM y con él `dtls_name` es obligatorio.
  Dos registros a la vez del mismo alcance: el segundo choca con el índice único parcial y recibe
  `instance_alive`. La fila de `replace` en `audit_log`: `source = 'platform'`, `command = 'zone_replace'`,
  `args = {replaced, by, channel}`. Con `replace` sobre una instancia que ya lleva 3 × `HEARTBEAT_S` sin latir,
  esa pasa a `lost` (no a `replaced`) y sus arrendamientos quedan libres.
- **Baja** (`DELETE`): de una `replaced`, libera lo que le quede y sigue `replaced`; de una `lost`, 409
  `instance_lost`; repetida, 204.
- **`zone_instance_id` que no es un UUID canónico** (en minúsculas): 400 `validation`, no 403.
- **Sobre del guardado.** `release_lease` es opcional; `pvp` exige sus seis totales; `seq` desde 1; un `{id}`
  de la ruta que no es un id es `envelope`. El `detail` de un `invalid_save` se corta a 500 B. Los
  `invalid_save`, `seq_conflict` y `stale_seq` se registran como aviso.
- **Lote de guardados.** Bloquea los arrendamientos en orden de `character_id`; el mismo personaje dos veces o
  un sobre de otra instancia es `envelope`.
- **Liberación** de un arrendamiento ya libre con el mismo `lease_id`: 204.
- **Libro:** el arrendamiento en la instancia es `zone_instance_id` igual a ella, sin mirar `expires_at`; un
  `limit` fuera de 1–100 o un `before_entry_id` que no es un id, 400 `validation`; un `op_id` que no es un id,
  404.
- **Eventos de guerra** de una fortaleza que aún no tiene fila valen (su primer PUT va por otra cola y puede
  llegar después); los de una fortaleza de otra zona, a `rejected`.
- **Claves de los lotes:** `<uuid>:<n>` sin ceros a la izquierda; `op:<op_id>` solo en la auditoría (en el chat
  y la guerra va a `rejected`). Las filas válidas se insertan en una ida y vuelta (`pgx.Batch`); si alguna
  choca con una restricción, se insertan de una en una para rechazar solo esa.
- **Auditoría:** `command` con la forma `^[a-z][a-z0-9_]{0,47}$` (los de la CLI llevan guiones o espacios) y
  fuera de los de la plataforma (`sanction_denied`, `sanction`, `zone_replace`); `console` sin actor ni
  `actor_character_id`, `zone` con `actor_account_id`.
- **Chat:** el emisor tiene que ser un personaje del mundo de la instancia; el texto, 255 caracteres como
  mucho y sin NUL. El registro solo lleva las claves rechazadas, nunca el texto.
- **Ignorados:** a uno mismo, 400; el nombre que se guarda es el del personaje; dejar de ignorar borra la
  cuenta del nombre y la fila guardada con ese nombre (el ignorado puede haberse renombrado).
- **Reportes:** el objetivo tiene que existir (404) y no ser la propia cuenta (400); los límites se cuentan en
  `reports` (en la base, no en memoria), en serie por la fila de la cuenta, y «por objetivo» es por personaje.
- **Sanciones:** `minutes` ≥ 1 en silencio y suspensión, 0 en las demás (la expulsión es permanente); los
  `report_ids` tienen que ser reportes del mundo de la instancia (400); un renombrado pone `must_rename`;
  sancionarse a uno mismo es `target_role`. Cada sanción creada deja una fila `sanction` en `audit_log` y cada
  denegada una `sanction_denied` con `args.denied` (`no_lease`, `role` o `target_role`), sin nombres ni correos.
- **El falso (`MemoryProgressStore`)** gana `SetApplyTxHook` (corre dentro de la transacción del guardado),
  `AddOp` (y `Op` mira los arrendamientos de los participantes con la misma consulta que hará el almacén de
  verdad), una S2 de juguete (un `op_id` ya aplicado falla), `SaveVersion` y `Applied`. Sigue sin ver las
  transacciones: si el COMMIT falla, lo suyo queda escrito; las pruebas de «nada escrito» miran las tablas de
  la plataforma.

**Pruebas** (51 nuevas, con la base efímera, el reloj falso y el falso del progreso): todas las de §15 P3 y
además el token sin alcance y la instancia que no existe, los campos del registro, el certificado en
`staging`, live repetido y la baja, la tabla de estados de §6.1 petición a petición en los cinco estados,
los bloques de ids (1, 1025, 2049), la renovación y los textos de cada `revoked`, los silencios del latido, el
billete de otro personaje, `character_busy` sin consumir el billete, el lote de guardados, la liberación
repetida, el op_id repetido (S2 del falso), el 40P01 que se arregla al reintentar, el arrendamiento de la
sustituida que caduca con el TTL, dos instancias que reclaman a la vez, eventos de guerra con todos los motivos
de rechazo, fortalezas de otro mundo, el chat de una instancia perdida, ignorados (tope de 100 y renombrados),
los dos límites de los reportes, la autorización de las sanciones (moderador que pide `ban`, GM contra admin,
sin arrendamiento, a sí mismo) con el silencio en el latido y la reclamación y el renombrado, `InsertEach` con
una fila mala y `serve` con la API interna por HTTP.

**Medido** (esta máquina, 4 núcleos, Go 1.24.7, PostgreSQL 16.15):

| Qué | Resultado |
|---|---|
| `go test -p 2 -count=1 ./...` con la caché caliente | 30 s; `internal/persistence` 6–8 s (28 pruebas), `internal/zones` 4–5 s |
| `go test -race` de los paquetes nuevos, `accounts`, `characters` y `serve` | 30 s, sin carreras |
| `DELETE` y reclamación a la vez, 8 rondas | 3 borrados sin arrendamiento y 5 reclamados vivos; ninguna mezcla |
| 100 guardados del mismo personaje, 8 a la vez con `seq` crecientes | 70–75 aplicados y el resto `stale_seq`; `save_version` = aplicados en todas |
| Binario | 20,3 MB (19,8 MB en P2) |

Godot: `--import` da el mismo registro que antes (no se ha tocado nada fuera de `platform/` salvo la
documentación).

**Sin comprobar:** contra una zona de verdad (P4) y con el almacén de verdad (progresion.md P7: S1–S8, la
restricción diferida de las ranuras de `0010_progress`, que aquí se simula con una tabla de prueba); lotes y
latidos con cientos de personajes. (El trabajo `zones_lost` dentro de `serve`, que aquí quedaba sin comprobar, tiene
prueba desde la revisión, §19.7.)

**Queda para después:** el mantenimiento en el latido (TEC-28); la zona (P4–P6, P7b); la CLI de P7a; las
retenciones de P9a; la prueba de extremo a extremo (P10).

### 19.5 P7a · moderación en Go (SOC-14 a SOC-18)

**Qué hay.** La orden `admin` con identidad (§9.1), las consultas auditadas, los avisos en la reclamación, la
retención del chat y una sola autorización de las sanciones para la zona y la CLI:

| Pieza | Contenido |
|---|---|
| `internal/admin` | Nuevo: el servicio de la orden. `Authorize` (el `--actor`: cuenta activa, sin sanción vigente y con el rol de la orden; si no, `ActorError`), `SetRole`, `CreateAccount`, `Bootstrap`, `PurgeNow`, `Reports`, `Report`, `CloseReport`, `Audit`, `Chat`, `Sanction`, `Sanctions`, `RevokeSanction`, `BlockName` y `UnblockName`. Cada orden deja su fila en `audit_log` (`source = 'cli'`, `actor_account_id` del `--actor`, `args.os_user`, el objetivo por id), en la misma transacción que lo que hace o lee; las que cambian algo vuelven a mirar el rol del `--actor` con su fila bloqueada |
| `cmd/eldmark-platform` | `admin.go`: la orden `admin` (argumentos leídos y comprobados antes de conectar, tablas con `tabwriter`, códigos 0, 1 y 2) con la configuración de `serve`; `admin help`. `serve` añade el trabajo `chat_retention` (cada hora) |
| `internal/sanctions` | `Create` (la autorización de §9.5 y la sanción, que estaban en `social`: ahora la usan la zona y la CLI), `RoleAt` (el rol de una cuenta en un instante: la consulta de S2, progresion.md §13.3), `PendingWarnings` y `Warning.Text`, `Timed`, `Roles` y las constantes de `source` y `command` |
| `internal/social` | `Sanction` sobre `sanctions.Create` (mismo comportamiento y mismas pruebas de P3); `PurgeChat` y `ChatRetentionJob` |
| `internal/persistence` | La reclamación trae `account.warnings` (abajo) |
| `internal/accounts` | `RevokeSessions`, `PurgeNow` (la purga de §11.2 sin esperar), `CreateAccount` (cuentas verificadas del equipo y de prueba) y `LookupAccount` |
| `internal/db` · `internal/testdb` | `MinPoolConns` (16) en `Open` · 10 conexiones por base de prueba (antes 4) |
| `internal/platformtest` | `Admin` (con `os_user` «prueba») |

Órdenes (`eldmark-platform admin --actor <correo> <orden>`; «L», lectura, basta `moderator`; el resto, `admin`):

| Orden | Hace | Fila de `audit_log` (`command`; objetivo; `args` además de `os_user`) |
|---|---|---|
| `set-role <correo> <rol>` | Cambia el rol y revoca todas las sesiones de la cuenta (`role_changed`): el latido siguiente expulsa a su personaje con guardado final y vuelve a entrar con el rol nuevo | `set-role`; la cuenta; `{from, to}` (la fila fija de §9.1) |
| `create-account <correo> --password-file <ruta> [--role player]` | Cuenta verificada, con la edad confirmada y los textos vigentes aceptados | `create-account`; la cuenta; `{role}` |
| `bootstrap <correo> --password-file <ruta>` | Sin `--actor`: la primera cuenta `admin`, solo si no hay ninguna | `bootstrap`; la cuenta; sin actor |
| `purge-now <correo> [--wait 30s]` | Revoca las sesiones (`deletion`), espera a que se liberen los arrendamientos y purga (§11.2); si alguno sigue vivo, `character_busy` y nada | `purge-now`; la cuenta |
| `reports list [--status …] [--limit N]` (L) | La cola, del más viejo al más nuevo | `reports list`; —; `{status, limit}` |
| `reports show <id>` (L) | El reporte con su prueba y sus sanciones | `reports show`; el objetivo del reporte; `{report_id}` |
| `reports close <id> actioned\|dismissed [--resolution …]` | Cierra (`handled_by`, `resolution`, `closed_at`) | `reports close`; el objetivo; `{report_id, status}` |
| `audit --since <fecha> [--until] [--actor-name] [--target] [--command] [--world] [--limit]` (L) | La auditoría con los nombres de ahora de los personajes | `audit`; el de `--target`; `{since, until, actor_account_id, command, limit}` |
| `chat --character <nombre> --from <fecha> --to <fecha> [--world] [--limit]` (L) | Lo que mandó el personaje y los susurros que recibió, con zona y copia | `chat`; el personaje; `{from, to, limit}` |
| `sanction add <nombre> <tipo> [--duration 1h\|7d] --reason … [--report id]… [--world]` | `sanctions.Create` con la cuenta del `--actor` | `sanction` o `sanction_denied` (como la zona, con `source = 'cli'`) |
| `sanction revoke <id>` | La levanta (`revoked_at`, `revoked_by`) | `sanction revoke`; el sancionado; `{sanction_id, kind}` |
| `sanction list <nombre> [--world]` (L) | Las sanciones de la cuenta con su estado (vigente, caducada, revocada, anotada, pendiente, cumplida) | `sanction list`; el personaje |
| `names block <nombre> [--reason …]` · `names unblock <nombre>` | La clave de `NameRules` entra en (o sale de) `name_blacklist`; avisa de quien ya se llama así | `names block` · `names unblock`; —; `{term}` |

Un personaje se nombra por su nombre en el mundo (`--world`, 1) o por `#<id>`; las fechas, en UTC
(`2026-11-01`, `2026-11-01T18:00` o RFC 3339).

**Para los paquetes siguientes.**

- **P4 y P7b (la zona):** la reclamación trae `account.warnings: [{sanction_id, text, at_unix}]` (lista vacía si
  no hay): los avisos que la cuenta no ha visto, con el texto para el jugador ya compuesto («Has recibido un aviso
  de la moderación: motivo», 255 B como mucho). La zona manda un NOTICE con cada `text` al entrar (§9.5). Un
  `set-role` llega como `session_revoked` en el latido («Tu cuenta ha cambiado: vuelve a entrar») y el rol nuevo,
  en la reclamación siguiente. Las sanciones de `/gm` siguen siendo `POST /internal/v1/sanctions`.
- **progresion.md P7 (S2):** `sanctions.RoleAt(ctx, tx, actorAccountID, time.Unix(at_unix, 0))` es la consulta
  de su §13.3 (el `args.from` de la primera fila `set-role` con `source = 'cli'` posterior, o el rol de
  `accounts`); devuelve "" si la cuenta no existe.
- **P9a:** `purge-now` ya existe; `reapply-purges` entra en `parseAdmin` igual que las demás (`Authorize` con
  `admin`, su fila `cli`). La retención del chat ya corre; quedan las de `audit_log`, reportes, sanciones,
  `auth_events` y demás de §11.1.
- **P9b:** `dev.sh` crea la primera cuenta con `admin bootstrap <correo> --password-file …` y las de prueba con
  `admin --actor <ese correo> create-account prueba@eldmark.test --password-file …`.

**Desviaciones y decisiones de la implementación:**

- **La autorización de las sanciones pasa a `internal/sanctions`** (`Create`): la zona (`social.Sanction`) y la
  CLI (`admin sanction add`) usan el mismo código y las mismas filas. La CLI pasa las tres comprobaciones de §9.5
  salvo el arrendamiento, que no tiene (no hay instancia), y exige `admin` para cualquier tipo (§9.1: toda orden
  que cambia algo es de `admin`). Sus filas usan los `command` de la plataforma (`sanction`,
  `sanction_denied`) con `source = 'cli'` y `os_user`, sin `zone_id` ni `actor_character_id`.
- **`sanction` son tres órdenes:** `add`, `revoke` (levantar una sanción: el esquema ya tenía `revoked_at` y
  `revoked_by`) y `list` (una lectura más para `moderator`, auditada). Un renombrado revocado quita
  `must_rename` salvo que haya otro sin revocar puesto después: no se guarda cuándo se renombró, así que no se
  sabe si uno anterior ya está cumplido.
- **Avisos en la reclamación** (§6 no tenía campo y §9.5 pide el NOTICE al entrar): `account.warnings`, los avisos
  sin revocar de la cuenta (de ese mundo o de todos) puestos después de la última entrada al mundo de cualquiera
  de sus personajes (`characters.last_entered_at`, leída antes de escribir la de esta reclamación), los 5 más
  recientes. Así cada aviso sale una vez. Desde la revisión (§19.7), la marca la pone el primer guardado del
  arrendamiento, con la hora de la reclamación: si la zona suelta al personaje sin que llegue al mundo (`REALM`,
  `FULL`, `prepare` o la baja en `LOADING`), el aviso sale otra vez en la reclamación siguiente.
- **La caducidad de cada sanción,** tal como se prueba: el aviso sale una vez y queda anotado (cuenta para la
  reincidencia y para `sanctioned_email_hashes`); el silencio y la suspensión acaban en `ends_at` (los mira cada
  consulta con la hora de Go); la expulsión no caduca (solo `sanction revoke`); el renombrado se cumple al
  renombrar.
- **`bootstrap`** es nueva: §12 pide «una cuenta `admin` para `--actor`» sin decir cómo nace la primera. Solo
  vale sin ninguna cuenta `admin` sin purgar (con `pg_advisory_xact_lock`) y siempre crea una cuenta nueva (un
  correo con cuenta es un error: a una existente se le da el rol con `set-role`, que deja su fila para S2).
- **`create-account`** crea la cuenta con los textos vigentes ya aceptados (cuentas del equipo y de prueba: el bot
  de §13.3 no sabe aceptar textos) y publica antes los textos que falten en `legal_documents`, como `serve`, para
  poder correr antes del primer arranque. La contraseña solo llega por `--password-file` (la línea de órdenes se
  ve con `ps`). No mira `sanctioned_email_hashes`.
- **`set-role`** sobre la propia cuenta es un error (nadie se queda sin `admin` por un descuido) y al mismo rol no
  hace nada ni deja fila. Bloquea las filas del `--actor` y del objetivo en orden de id, como `sanctions.Create`:
  dos `admin` que se quitan el rol a la vez no se quedan los dos sin él (gana uno; el otro sale con 2). La hora
  de la fila es la del reloj de Go (en `serve` y en la CLI, la del sistema).
- **`purge-now` llega aquí** (§14.1 no lo ponía en ningún paquete y §15 P7a lo prueba): revoca las sesiones y deja
  su fila en una transacción, espera en tiempo real hasta `--wait` (30 s) mirando los arrendamientos vivos cada
  500 ms y llama a la purga de cuentas de P1 (que vuelve a mirarlos con la fila bloqueada). Sobre la propia
  cuenta, error. En `staging` y `production` se niega mientras no exista el almacén del progreso, como `serve`.
- **`chat`** da también los susurros que recibió el personaje (el historial de un acoso). **`audit`**: `--target`
  casa con el personaje o con su cuenta; `--actor-name`, con la cuenta del personaje como actor; `--until`,
  `--command` y `--limit` (200 por defecto, 5000 como mucho) son nuevos. Los nombres que se escriben en un filtro
  no se guardan: el objetivo va en `target_*` y el actor del filtro como id en `args`.
- **`names block`** solo admite términos de letras (la clave de un nombre válido no tiene otra cosa) y no
  renombra a nadie: lista a quien ya se llama así para ponerle un renombrado.
- **La retención del chat llega aquí** (§14.1 la ponía en P9a), porque SOC-15 y §15 P7a piden que lo caducado
  desaparezca: el trabajo `chat_retention`, cada hora, borra por `sent_at` (la hora de la zona) lo de más de 30
  días en lotes de 10 000.
- **Pool de conexiones.** Con un cuarto trabajo periódico, los cuatro tenían cada uno una conexión con su
  `pg_try_advisory_lock` y esperaban otra para su trabajo: con el pool de pgx (`max(4, núcleos)`, 4 en un VPS de 4
  núcleos) se bloqueaban entre ellos y a las API hasta el plazo del más corto (los 5 s de `zones_lost`). `db.Open`
  pone ahora 16 conexiones si la cadena no trae `pool_max_conns`, y `testdb`, 10 por base. Medido:
  `TestServeMountsTheInternalAPI` pasó de 5,2 s a 0,4 s con el cuarto trabajo.
- **`admin` lee la configuración entera de `serve`** (`config.Load`: en el contenedor tiene las mismas variables)
  y se niega con el esquema sin migrar. Códigos: 0 bien; 1 error de la orden (también `character_busy` y una
  sanción no autorizada); 2 uso o `--actor` que no vale (si falta, antes de conectar).

**Pruebas** (`internal/admin`, 17, con la plataforma entera de `platformtest`): todas las de §15 P7a —un
moderador que pide `ban` y un GM contra un admin siguen en `social` (P3) y además un admin contra otro admin por la
CLI (`sanction_denied` con `source = 'cli'`); sin arrendamiento, en `social`; la caducidad de cada tipo con el reloj
(`TestWarningIsShownOnce`, `TestMuteExpires`, `TestSuspensionExpires`, `TestBanUntilRevoked`,
`TestRenameUntilRenamed`); `set-role` que revoca, la fila fija y el latido que expulsa (`TestSetRole`); `reports
show` sin `--actor` (en `cmd`, código 2) y con él, su fila; `chat` entre dos fechas con `zone_channel` y la
retención (`TestChatHistoryAndRetention`); ninguna fila de la CLI ni `sanction_denied` con correos o nombres
(`TestAuditHasNoPersonalData`, que corre todas las órdenes); un lote con `source = 'cli'` o `command = 'set-role'`
rechazado y `RoleAt` que no lo ve (`TestRoleAtOnlyReadsCLI`)— y además `--actor` (TestAuthorize, también el rol
perdido a mitad de una orden), dos `set-role` cruzados (8 rondas), lista negra, `reports list|close`, `audit` con
filtros, `purge-now` con un personaje dentro y fuera, `create-account` y `bootstrap`. En `cmd`: `TestAdminUsage` (15
errores de uso sin base), `TestAdminCommands` (las órdenes por la línea de órdenes, con `os_user` de `$USER`) y
`TestServeRunsTheChatRetention`. En `sanctions` y `db`, una prueba cada uno.

**Medido** (esta máquina, 4 núcleos, Go 1.24.7, PostgreSQL 16.15):

| Qué | Resultado |
|---|---|
| `go test -p 2 -count=1 ./...` con la caché de pruebas vacía | 26–30 s (30 s en P3: el pool más grande quita la espera de 5 s a las pruebas de `serve`); `internal/admin` 3–4 s (17 pruebas) |
| `go test -race` de `admin`, `sanctions`, `social`, `persistence`, `accounts`, `db`, `app` y `cmd` | 30 s, sin carreras |
| `internal/admin` 10 veces seguidas (`-count=10`) | 34 s, sin fallos |
| Binario | 20,6 MB (20,3 MB en P3) |

Godot: `--import` da el mismo registro que antes (las fugas al salir de siempre); fuera de `platform/` solo cambia
la documentación.

**Sin comprobar:** `set-role` y `purge-now` con una zona de verdad que expulsa y manda su guardado final (aquí la
zona de prueba libera a mano; es de P4 y P5); `audit` y `chat` con volúmenes grandes; la CLI dentro del contenedor
(P9b).

**Queda para después:** la zona de la moderación (P7b: `min_role`, `/gm`, invisible, NOTICE de los avisos,
silencios en `ChatRouter`, filtro de ignorados, anillo de reportes, lotes de chat y auditoría); `reapply-purges` y
el resto de retenciones (P9a); `admin maintenance` (TEC-28); `dev.sh` con `bootstrap` y `create-account` (P9b).

### 19.6 Lo que trae progresion.md P3

progresion.md P3 (su §19.4) añade sus secciones a `progression_rules.json` y empieza `internal/progress`:

- **`progression_rules.json`** tiene ya `races`, `appearance`, `level_curve`, `currencies`, `reasons`,
  `containers` y `combat`. `internal/gamedata` no cambia (sigue mirando solo `protocol_version` y `names`) y sus
  pruebas siguen pasando. Faltan `items` (progresion.md P1) y `starter_templates` (las plantillas de
  habilidades.md, que aún no están en esta rama).
- **`progress.LoadRules(gamedata.Raw())`** lee y comprueba esas secciones y da `ValidAppearance(realm, raceID,
  [8]byte)`, la regla de §4.4 paso 5 para la apariencia, con los casos compartidos
  (`tests/fixtures/progression/appearance_cases.json`). `*progress.Rules` aún no implementa `CreateValidator` (le
  faltan las plantillas): `serve` sigue con `ProvisionalValidator` hasta progresion.md P7, y nada de lo que hay en
  `cmd/` cambia.
- **Para P7:** las pruebas de `internal/characters` crean personajes con 8 B que no valen con las reglas de verdad
  (`appearance` de `harness_test.go`: cabeza 2, sin barba en Vardheim y marcas 2). Al cambiar `progressStore()` por
  `*progress.Rules` hay que darles una que valga para cada reino, como las de los casos compartidos
  (`AQAAAQEDAgE=` en Vardheim, `AgAAAAAHAAA=` en Solmarch).

### 19.7 Revisión de la implementación

Una revisión con tres enfoques (seguridad, corrección y pruebas) sobre P0–P7a y progresion.md P3 (de72147) dejó 14
hallazgos, todos confirmados con sondas. Cada uno se arregla con una prueba que fallaba antes del arreglo; en los de
cobertura, con la mutación que el hallazgo dejaba pasar, que ahora falla. Cinco eran huecos de este documento, que
se corrige donde toca: §2.3, §2.5, §2.6, §4.2, §4.3, §5.3, §6, §7.3, §9.5, §17 (y progresion.md §13.1, igual) y §18.

| Hallazgo | Gravedad | Qué era | Qué se hizo | Prueba |
|---|---|---|---|---|
| `revert_email` en cadena | alta | Con A→B→C, el `revert_email` que llegaba a B vivía 7 días: después de que el dueño recuperara la cuenta con el suyo, el ladrón revertía a B, dejaba la cuenta sin contraseña y recibía la recuperación. Hueco de §4.3 («solo caducan») | Gastar uno anula los de la cuenta emitidos después (`invalidateLaterReverts`, por `created_at`). El de un `revert_email` nuevo va como poco 1 µs detrás del anterior de la cuenta (`revertCreatedAt`): sin empates aunque el reloj se repita o retroceda. §4.3 | `TestRevertEmailChain`: el dueño primero, el de B da `used`; el ladrón primero, el del dueño sigue valiendo y la recuperación que le llegó al ladrón muere |
| Carrera en `CheckPassword` | alta | El freno se miraba con un cerrojo y el fallo se anotaba con otro tras argon2: los intentos simultáneos pasaban todos, y el freno de 30 s y el bloqueo de 15 min del grupo admitían ráfagas | Un turno por clave de cuenta (`failureTracker.turn`: un canal de capacidad 1, fuera del LRU para que no se expulse en uso, que respeta el contexto). Freno, consulta, argon2 y anotar van juntos; las claves distintas no se esperan. El correo `login_failures` y la reescritura del hash salen ya sin el turno. §4.2 | `TestConcurrentAttemptsRespectTheThrottle`: tras 5 fallos y 31 s, 30 a la vez desde 30 IP dan 1×401 y 29×429 (antes, 22×401); 10 a la vez desde un grupo, 5 y 5 (antes, 8 o 9×401); igual con un correo sin cuenta |
| Correo viejo ocupado | media | Tras A→B, un `POST /v1/accounts` con A (sin autenticar, 202) creaba una cuenta sin verificar con A, y el `revert_email` del dueño daba `token=unavailable` hasta caducar (la purga de las sin verificar llega después) | El correo de un `revert_email` vivo queda reservado (`emailReserved`): el registro y el cambio de correo de otra cuenta lo tratan como con cuenta (`register_existing`), un `change_email` pendiente de otra cuenta da `unavailable` y `admin create-account`, `ErrEmailReserved`. Sin índice nuevo (abajo). §4.3 | `TestOldEmailIsReservedWhileRevertLives` (también con el `change_email` pedido antes y con el enlace ya caducado) y un caso en `TestCreateAccountAndBootstrap` |
| La reclamación delataba sanciones | baja | El 403 `account_blocked` (con `reason`, `until_unix` y el texto) salía antes de mirar el mundo y el billete: con un `ticket_id` inventado, una zona leía las sanciones y la fecha de purga de cualquier personaje de cualquier mundo. Era el orden de §5.3 | El billete se bloquea y se valida antes (`select … for update of t`); el 403 sale solo con un billete válido de ese personaje para esa instancia, y el billete se consume después. Mismo orden de bloqueos: cuenta → billete → arrendamiento. §5.3 | `TestClaimRevealsNothingWithoutATicket`: billete inventado o de otro personaje, cuenta suspendida, expulsada (otro mundo) o con el borrado pedido dan el mismo cuerpo que un personaje que no existe |
| Oráculo de tiempo en `password-reset` | baja | Con cuenta se confirmaba una escritura (y su fsync); sin ella, solo se leía. Con fsync, 572 µs frente a 202 µs de mediana, sin solaparse | La respuesta no espera a la base: tras validar y gastar el límite de correos, buscar la cuenta, guardar el enlace y mandarlo siguen en segundo plano (`Service.Wait`, que `serve` llama al parar antes de cerrar la cola de correo y el arnés tras cada petición). Los dos caminos dejan su fila `password_reset` en `auth_events` (sin cuenta, `account_id` nulo). Un fallo de la base ya no da 503: se registra. §4.2, §4.3 | `TestPasswordResetWritesEitherWay`: las dos filas, y con la tabla `accounts` bloqueada la respuesta vuelve igual |
| El latido resucitaba arrendamientos | media | Renovaba un arrendamiento caducado que la reclamación, `enter` y el borrado ya daban por libre: dos personajes de una cuenta en el mundo, o uno borrado dentro. Lo evitaba solo que `zones_lost` llegara antes que el TTL, y la configuración admitía 10/20. La gracia de arranque alargaba también los caducados antes de la caída. Era la SQL de §5.3 y la regla de §2.5 | El latido renueva solo `expires_at > ahora` (lo demás, `lease_lost`). `config.Load` exige `LEASE_TTL_S > 3 × HEARTBEAT_S + min(5 s, HEARTBEAT_S)` (`Config.LostDetected`; `zones.LostAfter` y `LostEvery` salen de `config`). La gracia alarga solo los arrendamientos de las instancias `starting` y `live` con `expires_at ≥ last_heartbeat_at`, antes de subir el latido. §2.3, §2.5, §5.3 | `TestLateHeartbeatDoesNotRenewExpiredLeases` (también con el borrado), `TestLeaseTTLCoversLostInstances` y un caso en `TestStartupGrace` |
| Datos que la base rechaza tumbaban los lotes | media | `InsertEach` solo aislaba la clase 23: un NUL en `args`, UTF-8 roto o una fecha fuera de rango daban 500 al lote entero, y la zona lo reintentaba sin fin (la auditoría y la guerra nunca se descartan) | `db.KindData` (clase 22) y `db.Deterministic`, que `InsertEach` aísla por fila igual que la 23. `zones.IsJSONObject` (UTF-8, sin `\u0000` ni suplentes sueltos) en `args`, `context` y `record`; fechas hasta `zones.MaxUnix` (253402300799) en chat, auditoría, guerra y las pruebas de un reporte. Un error de clase 22 que llegue a la respuesta es 400 `validation` en la API interna (`zones.Fail`) e `invalid_save` S8 en el guardado (`SaveError`). §6, §7.3, §17 | `TestAuditBatch`, `TestChatBatch`, `TestWarEvents`, `TestReportLimits`, `TestFortresses`, `TestInsertEachIsolatesTheBadRow`, `TestIsJSONObject`, `TestFailDataErrorIs400` y tres casos en `TestClassifyRealErrors` |
| Totales pvp de más de `int4` | baja | `kills`, `deaths`, `assists`, `captures` y `defend_s` son `int`: un total de más de 2^31 − 1 no se podía codificar, daba 500 y la zona reintentaba ese guardado (o el lote) para siempre | `ParseEnvelope` los acota a 2^31 − 1 (`envelope`, definitivo); `gate_damage`, `bigint`, sigue hasta 2^53 − 1. §7.3 | `TestEnvelopeErrors`, `TestSavePvP` (el tope de cada columna vale) y `TestSaveMany` |
| Avisos perdidos | baja | La reclamación escribía `last_entered_at`: si la zona soltaba al personaje sin dejarle entrar (`REALM`, `FULL`, `prepare` o la baja en `LOADING`), el aviso quedaba visto sin NOTICE | Lo escribe el primer guardado aplicado del arrendamiento (`last_seq` 0), con su `claimed_at`: un aviso puesto entre la reclamación y ese guardado sale en la siguiente. §9.5 y §19.5 | `TestWarningSurvivesARejectedEntry`; `TestClaim` y `TestWarningIsShownOnce`, cuya salida es ya un guardado final |
| El refresco en el latido, sin probar | media | `TestHeartbeatRevocations` refrescaba otra sesión y quitaba a mano las revocaciones: «el latido expulsa una sesión rotada» o «el refresco revoca su fila» pasaban toda la suite | `Player.Refresh` y `Platform.RefreshSession` en `platformtest`; la prueba refresca dos veces la sesión del billete y comprueba que el arrendamiento sigue atado a ella | Las dos mutaciones fallan |
| `zones_lost` en `serve`, sin probar | baja | Quitar `AddJob("zones_lost", …)` dejaba todo en verde (§19.4 lo daba por «sin comprobar») | `TestServeRunsTheLostInstances`: `serve` con `HEARTBEAT_S` 1 y `LEASE_TTL_S` 5; la instancia pasa a `lost` y el arrendamiento queda libre en unos 4 s | La mutación falla |
| `TestAuditBatch` y la fila de S8 | baja | La fila «de S8» tenía otra clave: un `on conflict do update` que la pisara pasaba | La fila previa con la misma `op:<op_id>` y otros campos; sigue intacta tras el lote y el reenvío, y no va a `rejected` | La mutación falla |
| STARTTLS, sin probar | baja | La prueba solo miraba `isLoopback`; sin la guarda de `deliver`, el correo (con enlaces de un solo uso) salía en claro | `SMTPSender.dial` inyectable (por defecto `net.Dialer.DialContext`; `smtps` hace el saludo TLS sobre esa conexión). La prueba manda a `smtp.example.org`, desviado al servidor falso: «el servidor SMTP no ofrece STARTTLS» y ni `MAIL FROM`, ni `RCPT`, ni `DATA`; con `smtps`, tampoco | La mutación falla |
| `testdb` dejaba el servidor vivo | baja | Un pánico, el plazo de `go test` o un Ctrl-C dejaban el postmaster y su carpeta hasta otra ejecución con el mismo `TMPDIR` | Un vigilante por clúster (`watchdog_unix.go`, antes de `initdb`): un `sh` en su propio grupo de procesos con la entrada en una tubería que solo tiene abierta el proceso de pruebas; si se cierra sin «done», `pg_ctl stop -m immediate` y `rm -rf`. Fuera de Unix no hay vigilante (queda `reapStale`). §2.6 | `TestClusterDiesWithTheProcess`: un hijo que entra en pánico; su clúster desaparece en menos de un segundo (sin vigilante, sigue a los 15 s) |

**Decisiones de los arreglos:**

- **Turno por cuenta** (la opción B del hallazgo) frente a reservar intentos en vuelo: cuenta exacto y es corto. El
  coste es que los intentos de una misma cuenta esperan al argon2 del anterior; una ráfaga contra una cuenta
  frenada sale enseguida con 429 (el freno se mira con el turno y sin argon2), así que el dueño espera como mucho
  unos pocos cálculos.
- **`password-reset` en segundo plano** y no un trabajo de relleno: escribir en los dos caminos dejaba aún 519 µs
  frente a 406 µs (la clave ajena del enlace y la fila con cuenta), con las distribuciones solapadas pero
  distinguibles. La goroutine usa el contexto de la petición sin cancelación, con 30 s de plazo, y registra el
  fallo con el id de la petición.
- **Sin índice para la reserva del correo:** `account_tokens` es pequeña (lo caducado se borra a los 7 días, §11.1),
  y una migración nueva tomaría el número 0007, que §2.4 deja sin usar en la fase 5. Si crece, el índice parcial
  `(email) where purpose = 'revert_email' and used_at is null` va en la siguiente migración.
- **La gracia de arranque ya no alarga los arrendamientos de una instancia `replaced`:** caducan con su TTL, como
  dice §5.3; su guardado final vale mientras nadie reclame al personaje.
- **El orden de los `revert_email`** va por `created_at` (la tabla no tiene id secuencial) con el empuje de 1 µs, en
  lugar de una columna nueva.

**Medido** (esta máquina, 4 núcleos, Go 1.24.7, PostgreSQL 16.15):

| Qué | Resultado |
|---|---|
| `go test -race -count=1 ./...` | 33 s, sin carreras |
| `go test -p 2 -count=1 ./...` | 37 s; el commit anterior, en la misma máquina y a la vez, 34 s (las dos pruebas nuevas que esperan de verdad, `serve` con `zones_lost` y el hijo de `testdb`, suman unos 7 s) |
| Las pruebas nuevas de cuentas, 10 veces seguidas | Sin fallos; la de intentos simultáneos, además, con `-race` y argon2 de producción (3 de 3) |
| `password-reset`, mediana de 200 pares con y sin cuenta (servidor con fsync) | Antes, 572 µs y 202 µs; escribiendo en los dos caminos, 519 y 406 µs; en segundo plano, 2,5 y 2,4 µs |
| Binario | 20,5 MB |

Godot: `--import` da el mismo registro que antes (las fugas al salir de siempre); `test_export_config` (10),
`test_architecture` (19), `test_progression_rules_export` (10) y `test_name_rules` (12) pasan. Fuera de `platform/`
solo cambia la documentación.

**Sin comprobar:** el vigilante de `testdb` fuera de Linux (usa `sh` y `Setpgid`, que macOS también tiene); la
reserva del correo con una `account_tokens` grande; el envío con un servidor SMTP de verdad (STARTTLS sigue
probándose con el falso).

### 19.8 P4 · billete en la zona (TEC-24)

**Qué hay.** El lado de la zona de §5 y §6: el billete, la reclamación antes del WELCOME, la `ZonePlatform` con su
cliente HTTP y el protocolo 7. Sin `--platform` todo sigue como antes (`DevAuthProvider`, personajes efímeros):

| Pieza | Contenido |
|---|---|
| `scripts/server/platform/` | `HandoffTicket` (§5.1: `decode`, `verify` en tiempo constante, `sign`, `zone_key_of`), `TicketAuthProvider` (los cinco pasos de §5.2 y la tabla de respuestas de la reclamación), `ZonePlatform` (arranque de §8, latido con su conjunto, cercado, reloj, reclamación, liberación, guardado, bloques, fortalezas, lotes, `request` y los `kind` de `PlatformEvent`), `PlatformClient` (las plazas y prioridades de §6 con los reintentos de cada clase), `PlatformEvent`, `ClaimedCharacter`, `AuthOutcome` y `PlatformJson` (ids de 0 a 2^63 − 1 y enteros exactos, como `jsonx`) |
| `auth_provider.gd` · `dev_auth_provider.gd` · `server_auth.gd` | La API de §14.3 (`PENDING`, `authenticate(peer_id, hello)`, `on_platform_event`, `take_completed`, `cancel`, `uses_tickets`); `validate(peer_id, …)`, que con billetes no mira reino ni nombre (sin `REJECT NAME` ni `IMBALANCE`) |
| `server_peer.gd` | `State.VERIFYING`, `connected_at_msec` (tiempo real), `character_id`, `claimed` y `drop_body_at_once` |
| `zone_server.gd` | `start(…, platform)`; en «poll», los eventos por `kind` (`claim` al proveedor, `heartbeat` a la zona, `instance_closed` al final, como la señal `instance_closed`), los finales (reino → cupo → WELCOME con el reino y el nombre del personaje) y los `VERIFYING` vencidos a los 7 s; `get_player_count()` con `VERIFYING`; bajas en `VERIFYING` (`cancel`) y en `LOADING` (`release`); los `revoked` del latido; el bit del personal en el SPAWN; el enfriamiento por `character:<id>`; la sección `platform` de las métricas |
| `server_config.gd` · `server_main.gd` | `--platform`, `--world`, `--channel`, `--public-address`, `--save-interval`, `--replace`, `--dtls-cert`, `--dtls-key` y `platform_dev_options()`; con plataforma, los secretos del entorno, el arranque, `TicketAuthProvider`, `go_live`, la salida con código 1 (arranque) o 3 (`instance_closed`) y, al cerrar, lo pendiente y la baja |
| Protocolo 7 | `PROTOCOL_VERSION = 7` con la línea entera de §5.4, REJECT 10–12 con sus textos, `NetTransport.AUTH_TIMEOUT_SECONDS = 10.0`, bit 3 del `flags` de la cabecera del ENTITY_SPAWN (`NetMessages.SPAWN_FLAG_STAFF`, `EntitySpawn.is_staff`, `NetEntity.is_staff`); `progression_rules.json` reexportado con `protocol_version` 7; red.md con sus marcas «v7» |
| Pruebas | `tests/fake_zone_platform.gd` (`FakeZonePlatform`, la API de §14.3) y `tests/support/fake_http_server.gd` (`FakeHttpServer`, un `TCPServer` con respuestas y retrasos guionizados) |

**Para los paquetes siguientes.**

- **progresion.md P4:** la versión ya es la 7 y la línea de `net_protocol.gd` ya nombra lo suyo; añade su código sin
  subirla y sus filas «v7» en red.md (la leyenda de §5.2 ya está).
- **P5:** `CharacterSaver` llama a `ZonePlatform.save(character_id, lease_id, bytes, release_lease, context)`; la
  respuesta definitiva sale como evento `save` (el `match` de `_poll_platform` le deja el sitio) y saca al personaje
  del latido si llevaba `release_lease`. Hasta entonces, **provisional**: quien sale del mundo libera su arrendamiento
  cuando se va el cuerpo (`_claims_by_net`, en `_remove_player`, también tras la salida en combate y en
  `_clear_players`); un `revoked` que no es `lease_lost` expulsa con su NOTICE y sin guardado final; `instance_closed`
  cierra como cualquier otro cierre y sale con código 3 (el cierre de §6.1, con los finales primero y su NOTICE, es de
  P5); el `maintenance` del latido no se mira; `SHUTDOWN_MAX_FRAMES` sigue en 90 y `_drain_platform` espera a
  `is_flushed()` como mucho eso antes y después de la baja.
- **progresion.md P5a:** el paso (3) de `_apply_auth_outcome` es el sitio de `ProgressService.prepare` y
  `_leave_auth_states` (LOADING) el de `cancel_prepared`; `ZonePlatform.RECORD_FORMAT` ya existe; en
  `FakeZonePlatform`, `_claim_answer` y `_remember_save` son donde entra la parte `progress` y `claim_progress`.
- **P6:** `ZonePlatform.fortress_records()` trae lo del GET del arranque (`{fortress_id, record, version}`), que
  `ZoneServer.start` aún no aplica; `put_fortress` ya lleva una en vuelo por fortaleza con `expected_version` y el
  reenvío tras `version_conflict`; el falso tiene `fake_fortresses`.
- **P7b:** `ClaimedCharacter` trae `role`, `muted_until_unix`, `ignored_accounts` y `warnings`; `ServerPeer.claimed`
  sigue puesto en el mundo; los `mutes` del latido no tienen consumidor; `enqueue_batch` y `request` ya están.
- **P9c:** el registro manda `dtls_cert_pem` y `dtls_name` a null: el `X509Certificate` de Godot no da el CN, así que
  P9c tendrá que leerlo del DER o pedir `--dtls-name`.

**Desviaciones y decisiones de la implementación:**

- **Los reintentos viven en `PlatformClient`** y el transporte de un intento es un método aparte (`_perform`): el
  `HTTPRequest` de verdad o, en `FakeZonePlatform`, un `FakeClient` que contesta sin red. Así el falso corre toda la
  lógica de `ZonePlatform` (conjunto del latido, `instance_closed`, reintentos, lotes) y solo cambia el cable; sus
  reintentos van 20 veces más rápido (`fake_retry_scale` 0,05).
- **API de más en `ZonePlatform`** (§14.3 no la nombra): la señal `fatal_error` (`live` agotado), `deregister()`
  (la baja), `get_client()`, `heartbeat_set()`, `heartbeat_interval_s()`, `send_heartbeat_now()`, `log_sink`,
  `player_count_source` y las estáticas `read_secrets()`, `parse_ticket_keys()`, `env_guard_error()`,
  `registration_body()`, `build_id()` y `describe()`. Las clases de petición propias, que no salen como evento:
  `register`, `live`, `fortresses`, `release`, `stop` y los lotes (`chat`, `audit`, `war`).
- **El paso 2 de §8 lo hace `ZonePlatform`**, tras el registro: con un `env` de `staging` o `production` y alguna opción
  de desarrollo, o con la clave del vector de §5.1 fuera de `test` (la regla de §2.3 en la zona), se da de baja y
  emite `startup_finished(false, motivo)`; `ServerMain` vacía la cola y sale con código 1.
- **`ClaimedCharacter`** añade `instance_status` y `warnings` (los `account.warnings` de §19.5) a los campos de §14.3
  e `is_staff()`. Un cuerpo que no se entiende es `UNAVAILABLE` con alerta, y el `lease_id` que traiga se libera.
- **`FakeZonePlatform`:** `script_next(kind, status, FakeZonePlatform.DEFAULT, delay_s)` contesta lo de por defecto con
  ese estado y retraso; `add_character` admite un `display_name` al final (§14.3 no da el nombre; sin él,
  `NameRules.bot_name(id)`); `fake_heartbeat_s` (1 s), `fake_now_unix`, `fake_fortresses`; `sent()` de un GET es
  `{"path": …}`; `ignore`, `report` y `sanction` dan 404 por defecto, como `progress_op`.
- **El latido:** solo los 200 salen como evento `heartbeat`; un `revoked` `lease_lost` saca al personaje del conjunto
  (si no, se latiría por él para siempre); `players` es `get_player_count()` (con `VERIFYING` y los falsos); la zona
  está cercada también antes del registro.
- **Bajas:** la de `VERIFYING` y la de `LOADING` se hacen en `_mark_leaving`, por donde pasan todas (desconexión,
  CLIENT_LEAVE, expulsión, REJECT, plazo de carga), y en `stop()`. Un `lease_lost` no libera nada y saca el cuerpo en el
  acto (`drop_body_at_once`), también en `LOADING` (§6 dice «sin release»).
- **Con plataforma, `--max-realm-diff` no se aplica** (§5.4): `ServerAuth` no da `IMBALANCE` con billetes y
  `ServerMain` no crea los falsos de relleno (lo dice en el registro).
- **REJECT:** el informe cuenta los rechazos por el texto de `result_text`, no por el propio (el de `BANNED` lleva el
  motivo de cada cuenta); un HELLO sin billete recibe `TICKET` con «Entra desde el menú con tu cuenta». El WELCOME
  lleva el `channel` de la configuración (antes, siempre 0).
- **`build_id`** del registro: `eldmark-<versión del proyecto>-p<protocolo>`.
- **`FakeHttpServer`** contesta con `Connection: close` y descarta la respuesta si el cliente ya cortó (plazo
  vencido): no escribe en un socket cerrado.

**Pruebas** (Godot): `test_handoff_ticket.gd` (15: los vectores de Go, las huellas, los 9 inválidos, y
`TicketAuthProvider` con firma alterada, clave desconocida, sin billete, otra zona, mundo o canal, caducado y el
desfase de 5 s a los dos lados, reutilizado durante 30 s, otro personaje, zona cercada, la tabla de respuestas de la
reclamación, el 200 que llega tarde y se libera, un cuerpo que no se entiende, `from_claim` con ids de más de 2^53 y
cuerpos rotos, `ELDMARK_TICKET_KEYS` y la guardia del `env`, y el falso que devuelve el `pvp` aplicado y sube los
bloques); `test_zone_server_platform.gd` (13, con ENet: billete → `VERIFYING` → WELCOME con el reino y el nombre del
personaje, el `ticket_id` > 2^53 en la reclamación y el bit del personal; sin billete → `TICKET`; cupo de 4 con 5 en
`VERIFYING` → `FULL`; HELLO a 1,4 s con la reclamación a 5 s → WELCOME; plataforma muda → `UNAVAILABLE` a los 7 s y
liberación de la que llega tarde; zona cercada; bajas en `VERIFYING` y en `LOADING`; `revoked` en `LOADING`; en el
mundo, un `lease_id` viejo no expulsa, el de ahora sí y `lease_lost` no libera; `BUSY` y `BANNED` en suspensión,
expulsión y borrado pendiente; `test_hello_cannot_probe_an_enemy_name`; `--debug-commands` con `production`);
`test_platform_client.gd` (14, con `FakeHttpServer`: el arranque, plazo vencido y reintento con los mismos bytes, la
reclamación sin reintento, el latido y la reclamación con cuatro guardados lentos en vuelo, el orden por prioridad,
204, vacío, roto y sin UTF-8 → `body` null sin errores del motor, `zone_instance_id` y `key`, el conjunto del latido,
un solo `instance_closed`, la liberación con 403 que no se repite y con 503 que sí, el registro que reintenta cada 2 s
con `instance_alive`, y el servidor de zona de verdad en otro proceso: registro, fortalezas, bloque, `live`, latidos y
baja con código 0, y con `production` y `--debug-commands`, baja y código 1); además dos en `test_net_messages.gd`
(REJECT 10–12 y bit 3), una en `test_server_auth.gd` y otra en `test_server_config.gd`. Go: la suite entera pasa con
`protocol_version` 7 (`internal/gamedata` lo compara con `net_protocol.gd`); el `ticket_id` > 2^53 en la reclamación
ya lo probaba P3 (`TestClaimBigTicketID`).

**Medido** (esta máquina, 4 núcleos, Godot 4.7.2):

| Qué | Resultado |
|---|---|
| `test_zone_server_platform.gd` | 32 s las 13; la del HELLO tardío, 6,6 s (WELCOME a ~6,4 s de la conexión) y la de la plataforma muda, 8,1 s (REJECT a ~7,0 s) |
| `test_platform_client.gd` | 26 s las 14; el proceso de zona con `--platform`, 3,1 s de arranque a baja, y el de `production`, 1,9 s |
| `test_handoff_ticket.gd` | 15 pruebas en menos de 1 s (sin contar la carga del ejecutor) |

**Sin comprobar:** contra la plataforma de Go de verdad (P10; aquí, el falso y `FakeHttpServer` con las rutas y los
cuerpos de §6); `PlatformClient` con cientos de personajes en el latido y lotes llenos; DTLS (P9c).

**Queda para después:** `CharacterSaver` y el cierre de §6.1 (P5); `prepare` y la sección `progress` (progresion.md
P5a); las fortalezas cargadas y la sección `pvp` (P6); silencios, avisos, `/gm` y lotes de chat y auditoría (P7b);
`NetClient` con billete y `AccountFlow` (P8); DTLS (P9c); la prueba de extremo a extremo (P10).

### 19.9 P5 · guardado en la zona (TEC-25)

**Qué hay.** `CharacterSaver` y lo que lo rodea en la zona (§7.2, §7.3 y el cierre de §6.1). Sin `--platform` no
cambia nada: no hay `CharacterSaver` y los personajes siguen siendo efímeros (progresion.md §9.4).

| Pieza | Contenido |
|---|---|
| `scripts/server/platform/character_saver.gd` | `CharacterSaver` de §14.3: secciones en el orden en que se registran (una con el mismo nombre sustituye a la anterior); entradas por `lease_id` con los índices `character_id` → `lease_id` y, hasta `finish` o `drop`, `net_id` → `lease_id`; el sobre entero de §7.3 serializado una vez; el punto de control en la fase del personaje (`tick % interval == character_id % interval`) solo con alguna sección sucia; los críticos en el primer `step` sin nada en vuelo; una escritura en vuelo; el final construido en `finish`, que espera detrás del que vuela; `drop`; la tabla de respuestas de §7.3 y `save_rejected`. Además, `pending_count`, `tracked_net_ids`, `is_tracked`, `net_id_of`, `lease_of`, `entry_count`, `section_names`, `interval_ticks`, `get_stats` y `log_sink` |
| `zone_server.gd` | Con plataforma, `CharacterSaver` (cada `--save-interval` × 60 ticks) y `get_saver()`. `track` en cuanto existe la entidad; `step(s)` tras «altas»; los eventos `save` en «poll». La «Salida» en `_remove_player`: `finish` antes de `ScoreKeeper.forget`, también cuando se retira el cuerpo de una salida en combate. La baja sin guardado: `_on_save_rejected` y el `revoked` `lease_lost`, también del cuerpo que se queda. Los demás `revoked`, con guardado final. La cuenta atrás del `maintenance` del latido. `stop()` con los finales de todos y la espera; `close_instance(code)`, el cierre de §6.1. `saves` en el informe |
| `server_peer.gd` · `server_main.gd` | `ServerPeer.kicked` (el motivo 5 del final). `SHUTDOWN_MAX_FRAMES` 720; `instance_closed` → `close_instance` y salida con código 3 |
| Pruebas | `tests/support/fake_save_section.gd` (`FakeSaveSection`, la sección falsa con la forma de `pvp`, que `FakeZonePlatform` devuelve en la reclamación siguiente), `tests/support/raw_ticket_client.gd` (`RawTicketClient`, el cliente con billete que vivía dentro de `test_zone_server_platform.gd`) y `FakeZonePlatform.fake_maintenance` (el `maintenance` de los latidos por defecto) |

**Para los paquetes siguientes.**

- **progresion.md P5a:** `ProgressService.setup` registra `&"progress"` con `zone.get_saver().register_section(…)`
  **la primera** (es la única que puede devolver `{}`, y `CharacterSaver` no deshace lo que haya construido una
  sección anterior en ese intento). `on_arrival` va detrás de `track` en `_process_arrivals` (el sitio ya está), y
  un `mark_critical(net_id, &"starter_kit")` hecho ahí sale en el `step` de ese mismo tick. `on_departure(net_id)` va
  en `_remove_player` justo después de `_scores.forget(net_id)`: por ahí pasan la «Salida», el cuerpo que se retira
  tras una salida en combate y la baja sin guardado, cuyo `finish` ya no hace nada tras el `drop`. En los dos
  cierres, `_wind_down` hace los `finish` antes de `_clear_players()`. Mientras no haya ninguna sección,
  `CharacterSaver` libera sin guardar (abajo). En `FakeZonePlatform`, la parte `progress` de lo aplicado se guarda
  en `_remember_save` (lo llama `_answer` con cada 200 `applied`).
- **P6:** `ScoreKeeper` registra `&"pvp"`. Las pruebas de P5 registran después su `FakeSaveSection` con ese mismo
  nombre, que sustituye a la de verdad: siguen valiendo sin tocarlas.
- **P7b y progresion.md P5d:** con la zona cercada, `mark_critical` y los guardados siguen saliendo; rechazar los
  comandos que piden guardado crítico es de ellos.
- **P10:** `--save-interval=5` da puntos de control cada 300 ticks; el `kill -9` pierde lo posterior al último
  aplicado.

**Desviaciones y decisiones de la implementación:**

- **Sin secciones no hay nada que guardar.** Hasta progresion.md P5a (`progress`) y P6 (`pvp`) la zona no registra
  ninguna, y la plataforma exige `progress` (un sobre sin ella es `invalid_save` `envelope`). Así que, sin
  secciones, el punto de control nunca está sucio, un crítico no manda nada y `finish` libera sin guardar: contra
  la plataforma de verdad la zona hace lo mismo que en P4 (`_claims_by_net`, que desaparece).
- **El cierre de §6.1 es `ZoneServer.close_instance(code)`** (§14.3 solo nombraba a `ServerMain`). Los de
  AUTHENTICATING y VERIFYING reciben REJECT `UNAVAILABLE` (aún no pueden recibir un NOTICE) y los de LOADING se
  liberan. Después salen los finales de todos con el motivo 4 y la zona espera, como mucho `save_drain_ticks` (600).
  Solo entonces manda el NOTICE de expulsión (código 1) a todos. `ServerMain._shutdown` recibe el código y elige
  `close_instance` en lugar de `stop`.
- **La espera vive en `ZoneServer`.** `_drain_stop` sondea la red y la plataforma hasta que `pending_count()` es 0 y
  `is_flushed()` (o pasan 600 ticks) y los peers se han ido (o pasan 30 ticks desde su NOTICE). En ese tiempo
  atiende las respuestas de los guardados y las reclamaciones que llegan tarde, que se liberan; el latido ya no
  expulsa ni avisa. `stop()` sin peers y sin nada pendiente sigue terminando en el acto, así que las pruebas sin
  plataforma no cambian. `ServerMain` espera después, como antes, a `is_flushed()` y a la baja.
- **Un cierre a mitad de tick corta el tick.** `instance_closed` (en «poll»), la cuenta atrás de la consola o la del
  mantenimiento pueden cerrar el servidor dentro del tick. Desde ahí, el resto del tick no corre sobre el mundo ya
  vaciado.
- **Motivo del final:** 3 (salida); 5 si la zona echó al jugador (`ServerPeer.kicked`: avisos, consola, `revoked`,
  plazo de carga); 4 en los dos cierres. El cuerpo que se queda tras una salida en combate conserva el motivo hasta
  que se retira.
- **Un 409 `instance_*` en un guardado** no culpa al jugador. La plataforma no lo da: los guardados valen en
  cualquier estado y el cierre llega en `instance_status`. Si aun así llega, se reenvía el mismo cuerpo hasta 3
  veces (`MAX_CLOSING_RESENDS`) y después es definitivo: un final de una instancia cerrada no se pierde por eso.
- **Liberar después de lo que vuela.** Un final que no se puede construir y la baja sin guardado liberan cuando el
  guardado en vuelo, si lo hay, tiene respuesta: si no, otra zona podría reclamar y cargar el estado de antes de
  ese guardado. Tras un `lease_lost` (del latido, de un guardado o en `drop`), esa entrada ya no libera nunca.
- **`save_rejected` sin baja:** si nadie llama a `drop` al recibirla, `CharacterSaver` la hace solo, y la entrada no
  se queda atada a un cuerpo que ya no guarda. Un `track` sobre un `net_id` que aún tenía entrada (la zona no llamó
  a `finish` ni a `drop`) suelta la vieja con `drop` y una alerta.
- **Alertas:** van al registro y además con `push_warning`. Son el definitivo de un guardado (con `check` y `detail`
  de un `invalid_save`), el final que no se pudo construir y un `track` que no cuadra. El ejecutor de pruebas no
  cuenta los WARNING como fallos.
- **Textos.** La baja sin guardado manda «No se ha podido guardar tu personaje; vuelve a entrar» y un `lease_lost`
  de un guardado, «Tu personaje ha entrado en otro servidor»; el de un `revoked` lleva el `text` de la plataforma.
  El mantenimiento dice «El servidor se cerrará por mantenimiento en 10 min: <message>» (minutos redondeados hacia
  arriba desde 60 s). Los avisos que ya pasaron cuando llega el anuncio se juntan en uno con lo que queda.
  Un `maintenance` que vuelve a null tras algún aviso da «Mantenimiento cancelado: el servidor sigue abierto», y
  uno cuya hora ya llegó no se dispara otra vez aunque el latido lo repita. La hora es `ZonePlatform.now_unix()`.
- **Los cinco disparadores con el proceso de verdad** (`--platform` contra `FakeHttpServer`): como la zona aún no
  tiene secciones, lo que esperan es la liberación de cada uno, también la del final de quien está en el mundo. Los
  guardados de verdad con su espera se prueban en el proceso de las pruebas, con `FakeSaveSection`.

**Pruebas** (Godot):

- **`test_character_saver.gd`** (14, sin red, con `FakeZonePlatform`): el punto de control en su fase y solo con
  algo sucio (tres personajes, intervalo de 120 ticks); el crítico al instante, también justo tras `track`; una
  escritura en vuelo; el final que espera detrás de la que vuela sin rehacerse; el sobre entero (con un
  `character_id` > 2^53) y el mismo cuerpo en los reintentos; `duplicate` como aplicado; una sección que devuelve
  `{}` sin gastar `seq`. Además: el final que no se puede construir, sin secciones, ocho respuestas definitivas
  antes de `finish` (`invalid_save`, `stale_seq`, `seq_conflict`, 403, 413, 404, un 409 desconocido y `lease_lost`,
  este sin liberar) y la baja que hace solo; los
  409 `instance_*` con su tope; tras `finish`, un definitivo que solo se registra y libera; un `net_id` reutilizado
  con el final del anterior en vuelo; el mismo personaje que vuelve mientras su final se reintenta.
- **`test_zone_server_saves.gd`** (10, con ENet): el crítico del alta en el tick del alta y los puntos de control en
  su fase; la salida en combate que guarda al irse el cuerpo; la baja sin guardado (un `invalid_save` en combate:
  el cuerpo fuera en el acto, una liberación, la «Salida» sin nada y la sección sin más llamadas; y un `revoked`
  `lease_lost` en combate, sin liberar); un `revoked` con guardado final y motivo 5. El cierre de §6.1 con
  `instance_lost` en el latido y con `instance_replaced` en el `instance_status` de un guardado: los finales antes
  del NOTICE, la liberación del de LOADING, y quien vuelve a entrar carga su final. El cierre ordenado espera la
  respuesta del final a los 2 s y libera a los de LOADING y VERIFYING. El `maintenance` da los cinco avisos, el
  cierre y la cancelación. La reconexión trae lo último aplicado, y el mismo personaje vuelve mientras su final se
  reintenta.
- **`test_zone_process_shutdown.gd`** (5, el servidor de zona en otro proceso): `--stop-file`,
  `--quit-after-ticks`, `--idle-quit`, `shutdown` de la consola (con `--run-at`) y `maintenance`. En cada uno, la
  baja de la instancia llega después de la última respuesta (a los 2 s) de lo que quedaba de cada uno (en el
  mundo, en LOADING y en VERIFYING), con código 0 y sin errores.

`test_zone_server_platform.gd` (13) pasa igual con `RawTicketClient`. Comprobadas con la mutación que deberían pillar:
sin la espera de `_drain_stop` fallan el cierre ordenado y los dos de §6.1, y con `SHUTDOWN_MAX_FRAMES` en 90 y la
espera de la zona en 30 ticks falla el de `--stop-file`.

**Medido** (esta máquina, 4 núcleos, Godot 4.7.2 headless):

| Qué | Resultado |
|---|---|
| `test_character_saver.gd` | 14 pruebas en 3,9 s (la más lenta, 1,1 s: ocho respuestas con sus esperas) |
| `test_zone_server_saves.gd` | 10 pruebas en 11,7 s; la del cierre ordenado, 2,3 s (termina tras la respuesta del final, a los 2 s de `stop`) |
| `test_zone_process_shutdown.gd` | 5 pruebas en 35 s: de 5 a 8 s cada una, con el arranque del proceso |
| `CharacterSaver.step` con 64 cuerpos y nada que guardar | 0,4 µs por tick: solo mira la fase del tick y los pendientes (recorrer las 64 entradas en cada tick costaba ~40 µs) |
| `JSON.stringify` del sobre de un personaje grande (120 objetos y 256 operaciones, 89 KB) | 3,7–4,6 ms (con otra carga en la máquina) |

**Sin comprobar:** contra la plataforma de Go de verdad (P10); con cientos de personajes y la sección `progress` de
verdad (progresion.md P5a), cuyo `JSON.stringify` es lo caro del guardado (arriba): con 64 jugadores sale uno por
segundo y en el tick.

**Queda para después:** las secciones `progress` (progresion.md P5a) y `pvp` (P6); rechazar con la zona cercada los
comandos que piden guardado crítico (progresion.md P5d, P7b); el `kill -9` de extremo a extremo (P10); el
`maintenance` que pone `admin maintenance` en la plataforma (TEC-28).

### 19.10 Lo que deja progresion.md P5a

progresion.md P5a (su §19.11) registra la sección `progress` y prepara el registro antes del WELCOME. Lo que cambia aquí:

- **Siempre hay una sección.** `ZoneServer.start` crea `ProgressService`, que registra `progress` la primera; con
  plataforma, todo final lleva el guardado y libera con `release_lease` (la liberación sin guardar de §19.9 queda para
  la baja en LOADING, la baja sin guardado y un final que no se pueda construir). El primer guardado de un personaje
  nuevo es el crítico del kit, en el tick de su alta.
- **`prepare` en el paso (3).** Un registro que no se puede leer da REJECT `UNAVAILABLE` con «No se ha podido cargar el
  personaje», una alerta y la liberación; la baja en LOADING llama a `cancel_prepared`.
- **`FakeZonePlatform`:** la parte `progress` de la reclamación siguiente (§14.1), `claim_progress` y
  `default_progress(realm)`; `add_character` con `progress` vacío da un personaje recién creado de su reino (antes, un
  `{}` que ahora `prepare` rechazaría).
- **Pruebas de aquí ajustadas:** `test_zone_server_saves` cuenta los guardados desde después del kit;
  `test_zone_server_platform`, en `test_revoked_in_the_world_only_with_the_current_lease`, espera el final con
  `release_lease` en lugar de la liberación; `test_zone_process_shutdown` reclama con `default_progress` y cuenta como
  liberación de quien estaba en el mundo su final con `release_lease` (contestado con el mismo retraso).
- **P6:** `pvp` se registra detrás de `progress`. **P10:** los guardados de extremo a extremo llevan ya la sección
  `progress` (con el almacén de verdad, progresion.md P7).

### 19.11 P9b · operación (TEC-28)

**Qué hay.** `platform/deploy/` con lo de §10.1, §10.3 y §12 que se puede automatizar aquí, más `admin
reapply-purges`, que se trae de P9a (abajo):

| Pieza | Contenido |
|---|---|
| `dev.sh` | `up` (por defecto), `prepare`, `env`, `stop` y `reset`. Un PostgreSQL propio en `build/dev_pg` (`initdb`, y `runuser -u postgres` como root, como `testdb`) que se conserva entre arranques, en 127.0.0.1:24682 (`ELDMARK_DEV_PG_PORT`). Claves del billete, un token por zona de desarrollo (`1:vado_gris:0` y `1:test_world:0`) y las contraseñas en `build/dev_secrets/` (0600), y `build/dev_platform.env` con las variables `*_FILE`. `migrate up`, `admin bootstrap admin@eldmark.test` si no hay ninguna admin y `admin --actor … create-account prueba@eldmark.test`. Escribe la orden de la zona con `--platform` (y las del cliente y el bot de P8). `up` arranca `serve` en primer plano: Ctrl-C o TERM paran `serve` y PostgreSQL. Compila el binario con Go o usa `ELDMARK_PLATFORM_BIN` |
| `backup.sh` | `pg_dump -Fc` a `daily/eldmark-<UTC con ms>.dump` (comprobado con `pg_restore --list`) y después `purge_log` a su `.purges.txt` y a `<carpeta>/purges.txt` (cambiado de golpe con `mv`, nunca rotado): `kind<TAB>id<TAB>purged_at`, el texto de COPY en UTC con microsegundos, sin datos personales. Semanal (enlace duro) si la última semanal tiene casi 7 días o no hay; rota 7 diarias y 4 semanales (`ELDMARK_BACKUP_DAILY`, `…_WEEKLY`), cada una con su `purges.txt`. La base, de `ELDMARK_DATABASE_URL` o `…_FILE` (o las `PG*`), sin escribirla nunca en la salida. Si algo falla no deja archivos a medias y sale con 1 |
| `restore_check.sh` | `<copia> <purges.txt>`, o `--dir <carpeta>` (la copia más reciente de `daily/` y `weekly/` y su `purges.txt`). Clúster efímero (como `testdb`, solo socket), `pg_restore`, los correos que la copia aún tiene de las cuentas de `purges.txt` (en un esquema aparte del clúster de prueba), `migrate up` si a la copia le faltan migraciones, `admin --actor <admin de la copia> reapply-purges`, `migrate status` y las consultas de integridad, que tienen que dar 0 (abajo). Sale con 1 si algo falla y con 2 si el uso no vale; borra el clúster al salir |
| `pitr_check.sh` | El de §12: un primario con `archive_command` a una carpeta, `pg_basebackup`, 500 filas que solo están en el WAL, la hora objetivo, un borrado y `pg_switch_wal` (espera a que el segmento esté archivado); la copia base con `restore_command`, `recovery_target_time`, `recovery_target_action = 'promote'` y `recovery.signal` tiene que tener las 1500 filas de antes del borrado y ninguna otra. Solo `fsync=off`: el WAL y las escrituras de página completa, como en el VPS |
| `pglib.sh` | Lo común de los tres que levantan PostgreSQL: los binarios (`ELDMARK_PG_BIN`, `pg_config` o el mayor `/usr/lib/postgresql/*/bin`), `runuser` como root (`ELDMARK_PG_USER`), `initdb`, arranque, parada y la ruta del socket (107 B) |
| `Dockerfile` | `build` (golang:1.24.7-bookworm, `CGO_ENABLED=0`, `GOTOOLCHAIN=local`), `platform` (debian:bookworm-slim con `ca-certificates` y `tzdata`, usuario 10001, `serve`, las dos API en 0.0.0.0 dentro del contenedor) y `ops` (postgres:16-bookworm con el binario y los scripts). Contexto `platform/`, con `platform/.dockerignore` (secretos, copias, `*.env`, `*.pem`, `*.key` y el binario fuera) |
| `docker-compose.yml` | `db` (postgres:16), `platform`, `caddy`, `zone-vado-gris` (perfil `zonas`) y `backup`, `restore-check` y `pitr-check` (perfil `ops`; los dos últimos sin red). Todos con `logging: {driver: journald, options: {tag: "{{.Name}}"}}`; los de servicio, `restart: unless-stopped`. Nueve secretos de archivo en `ELDMARK_SECRETS_DIR`, montados en `/run/secrets` y leídos con las `*_FILE`. Redes `edge` (Caddy, con IP fija: la única de `ELDMARK_TRUSTED_PROXIES`), `zones` (las zonas y la API interna) y `data` (interna: la base no sale a Internet). Solo Caddy (80, 443 y 443/udp) y la zona (24600/udp) publican puertos. WAL con WAL-G configurable (`ELDMARK_DB_IMAGE`, `ELDMARK_PG_ARCHIVE_MODE`, `ELDMARK_PG_ARCHIVE_COMMAND`); nombre de proyecto `eldmark-<entorno>` |
| `Caddyfile` | §10.1: `reverse_proxy platform:24680 { header_up X-Real-IP {remote_host} }` (pisa cualquier `X-Real-IP` del cliente), sin directiva `log` (sin registro de accesos), HSTS, `nosniff` y sin `Server`. Validado con Caddy 2.10.2 (`caddy validate` y `adapt`: sin `logs`) |
| `staging.env.example`, `production.env.example` | Las variables del compose: entorno, dominio y correo ACME, imágenes de GHCR, `public_host` y `ELDMARK_ZONE_HOSTS`, protocolo mínimo, remitente, reinos, carpetas de secretos y copias, WAL y la red de Caddy. Ningún secreto (la CI lo comprueba) |
| `journald-eldmark.conf` | `Storage=persistent`, `MaxRetentionSec=30day` y `SystemMaxUse=2G` (§11.1), para `/etc/systemd/journald.conf.d/` |
| CI | `ELDMARK_REQUIRE_DEPLOY_TOOLS=1` en «Plataforma»: sin bash, git, shellcheck o `docker compose`, las pruebas de `deploy` fallan en lugar de saltarse (Caddy es opcional: la CI no lo trae) |

**`reapply-purges` llega aquí** (§14.1 lo pone en P9a, de la que depende P9b): sin él no se puede probar
`restore_check.sh`. `eldmark-platform admin --actor <correo> reapply-purges <purges.txt>` (pide `admin`; deja la
fila `reapply-purges` con los recuentos y sin ids) hace lo de §11.2: en una transacción borra todos los
`character_leases` y `enter_tickets` de la copia; después, en orden de `purged_at` (a igual hora, los personajes
antes que su cuenta), purga cada línea en su propia transacción con el `purged_at` del archivo: las cuentas con la
purga de P1 (`accounts.Service.ReapplyPurge`, motivo nuevo `reapply-purges`: basta que no esté purgada, como en
`purge-now`) y los personajes con el camino de la cuenta (`characters.Purger.ReapplyPurge`). La huella del correo,
el año de las sanciones y del libro y los 30 días del nombre salen de ese `purged_at`. Al final comprueba que no
queda ningún id sin purgar (`admin.UnpurgedError`, código 1); uno que la copia no tiene cuenta como purgado. Es
idempotente. `admin.ParsePurges` lee el formato de `backup.sh` (y RFC 3339) y nombra la línea mala. Como
`purge-now`, en `staging` y `production` se niega mientras no exista el almacén del progreso (progresion.md P7). El
paso 3 de la purga (no con un arrendamiento vivo) se sigue mirando, aunque no encuentra nada: si aparece uno, hay
una zona o `serve` en marcha contra la base, y la orden para con un error que lo dice. **A P9a le queda** lo demás:
la exportación con el progreso, las retenciones horarias que faltan, la del libro con el borrado de las lápidas
vacías y sus pruebas que no son de `reapply-purges`; las de `reapply-purges` de §15 P9a ya están (abajo).

**Desviaciones y decisiones de la implementación:**

- **`dev.sh` escucha en TCP** (127.0.0.1, sin socket): la ruta de `build/dev_pg` en un repositorio con una ruta larga
  pasa de los 107 B del socket. Tiene más órdenes que §12 (`prepare`, `env`, `stop` y `reset`) y contraseñas
  fijas de desarrollo (`eldmark-admin-dev` y `eldmark-prueba-dev`, también en `build/dev_secrets/`), que se
  teclean en la revisión visual de §15. Las cuentas se crean con `bootstrap` y `create-account` (§19.5).
- **`restore_check.sh` migra antes de `reapply-purges`** si a la copia le faltan migraciones del binario (una copia
  de antes de un despliegue; `admin` se niega con el esquema sin migrar; expandir y contraer lo permite, §2.4), y
  después `migrate status` tiene que salir con 0. El binario corre con una configuración de usar y tirar
  (`env -i`, `ELDMARK_ENV=dev` y claves aleatorias): solo ve la base de prueba. El `--actor` es
  `ELDMARK_RESTORE_ACTOR` o la primera cuenta admin activa, sin suspensión ni expulsión, que no está en
  `purges.txt`; si la copia no tiene ninguna admin, una de usar y tirar con `bootstrap`.
- **Las consultas de integridad** de §12, más las que comprueban `reapply-purges`: personajes sin cuenta;
  arrendamientos de instancias inexistentes; arrendamientos y billetes que siguen de la copia; líneas de
  `purges.txt` sin fila en `purge_log` (de las cuentas y personajes que la copia tiene); `purged_at` distinto del
  de `purges.txt`; cuentas de `purge_log` o de `purges.txt` con datos personales (correo, hash o estado, o filas
  en sesiones, enlaces, accesos, consentimientos, aceptaciones, derechos, reinos, ignorados en los dos sentidos,
  chat enviado o sanciones con motivo: lo que borra la purga de P1); sus personajes, o los purgados sueltos, con
  nombre, estadísticas, arrendamiento, billete o nombre ligado; correos de esas cuentas en `outbound_mail`; y filas
  de `audit_log` con el correo de una cuenta de `purges.txt` (solo se busca en las filas con «@»). Van por
  conjuntos: con un `exists` por fila, 1000 purgas sobre 100 000 mensajes tardaban 22 s.
- **`backup.sh`:** el nombre lleva milisegundos (dos copias seguidas no se pisan y el nombre ordena por fecha); la
  semanal sale de la antigüedad de la última semanal, no de un día fijo (aguanta días sin copia); el
  `purges.txt` de cada copia rota con ella y el de la carpeta no rota nunca. Subirlas a S3 es del VPS.
- **La imagen `ops`** (§12 no la tiene): PostgreSQL 16 con los scripts y el mismo binario, para correr las copias
  y sus comprobaciones en un contenedor desechable con la versión de la base. `docker compose run --rm
  restore-check` es la restauración semanal de TEC-28.
- **Las zonas en el compose** van con el perfil `zonas` hasta que existan su imagen (TEC-20) y sus opciones
  (`--platform`, `--world`, `--channel` y `--public-address` de P4; `--dtls-*` de P9c).
- **Permisos de los secretos:** Compose sin swarm monta cada archivo con sus permisos del host y dentro lo leen
  usuarios sin privilegios (eldmark 10001, postgres 999): 0444 dentro de una carpeta 0700 de root.
- **`platformtest.Attach`** (la plataforma sobre una base ya hecha, como una restaurada) y **`testdb.BinDir`** (la
  carpeta de `pg_dump` y `pg_restore` de las pruebas) son nuevos, para las pruebas.

**Pruebas.** `platform/deploy` es un paquete de Go sin código (`doc.go`) con sus pruebas, que corren los scripts
con bash: `TestBackupAndRestoreCheck` (la de §15 P9b: copia antes de un `purge-now` y del borrado de un personaje,
restaurada con el `purges.txt` más reciente → purgada y las consultas a 0; la más reciente con `--dir`; una copia
cuya auditoría guarda el correo de una cuenta purgada después → 1 y lo nombra; rotación), `TestRestoreCheckUsage`,
`TestPitrCheck`, `TestDevScript` (`prepare` dos veces, `env`, `up` hasta `/ready` y TERM con PostgreSQL parado,
`reset`), `TestComposeConfig` (`docker compose config -q` con los dos ejemplos y no sin ellos; journald en todos,
puertos solo en Caddy y la zona, la base sola en `data`, ningún secreto en claro, `ELDMARK_TRUSTED_PROXIES` con
la IP de Caddy), `TestCaddyfile`, `TestCheckSecrets` (la de §15 P9b: los ejemplos de verdad pasan; un
`staging.env`, un `secrets/ticket_keys` o un ejemplo con el valor de un secreto en el índice → 1, sin repetir el
valor; y el índice de este repositorio pasa) y `TestScriptsPassShellcheck` (`bash -n` y shellcheck 0.10 sin
avisos). En `internal/admin`: `TestParsePurges`, `TestReapplyPurgesAfterRestore` (las dos de §15 P9a sobre
`reapply-purges`: con `pg_dump` y `pg_restore` de verdad, el `purged_at` original en las lápidas, también la de un
personaje que nunca se borró; sin arrendamientos ni billetes de la copia; `purge_log`, la huella del correo y la
reserva del nombre como en la base original; la fila de auditoría; y una segunda vuelta que no cambia nada) y
`TestReapplyPurgesReportsWhatStaysUnpurged` (con una purga que no purga, `UnpurgedError` con el id). En `cmd`, la
orden por la línea de órdenes (uso, un `purges.txt` mal formado o que no existe → 1).

**Medido** (esta máquina, 4 núcleos, Go 1.24.7, PostgreSQL 16.15):

| Qué | Resultado |
|---|---|
| `pitr_check.sh` | 3,0–3,2 s (copia base 0,65 s, recuperación 0,15 s) |
| `backup.sh` | 0,1 s con una base de prueba (76 KB); 0,3 s con 10 000 cuentas, 20 000 personajes, 100 000 mensajes y 50 000 filas de auditoría (43 MB de base, 1,6 MB de copia) |
| `restore_check.sh` | 1,3–1,5 s con una base de prueba. Con la grande y 1000 cuentas en `purges.txt`: `pg_restore` 0,64 s, `reapply-purges` 18,6 s, todo 20,3 s |
| `reapply-purges`, por cuenta con 2 personajes | 18 ms; 10 ms con un índice en `chat_messages (sender_account_id)`, que el esquema no tiene: la purga de una cuenta borra su chat recorriendo la tabla entera (igual en la purga horaria y en `purge-now`). **Para una migración futura** (fuera de la fase 5, §2.4) |
| `go test -race -count=1 ./...` | 34 s, sin carreras; `deploy`, 14 s (con la compilación del binario) |
| Binario | 20,5 MB |

Godot: fuera de `platform/` solo cambian la documentación y la CI (`platform/` lleva `.gdignore` y está fuera de las
exportaciones).

**Sin comprobar (en el VPS, del usuario):** construir las imágenes (aquí el demonio de Docker no corre: `docker
compose config` sí, `build` no) y arrancar el compose; Let's Encrypt con un dominio de verdad; los secretos
montados y leídos por usuarios sin privilegios; journald con `MaxRetentionSec` (aquí no hay systemd); la imagen de
la base con WAL-G, S3 y el `restore_command` de verdad; el cron de `backup` y `restore-check` con su alerta
(TEC-31); `dev.sh` en macOS y en WSL con la zona en Windows; `serve`, `purge-now` y `reapply-purges` en staging y
producción, que esperan al almacén del progreso (progresion.md P7); la zona en el compose (TEC-20, P4 y P9c); y el
trabajo «Plataforma» en GitHub con las herramientas obligatorias (shellcheck y `docker compose` de
`ubuntu-latest`).

**Queda para después:** `admin maintenance` y `deploy.sh` (copia previa, parar, `migrate up`, versión nueva, quitar
el mantenimiento), de TEC-28 y sin paquete aquí; publicar las imágenes en GHCR; la imagen y el despliegue de las
zonas (TEC-20); el resto de P9a.

### 19.12 Lo que deja progresion.md P7

progresion.md P7 (su §19.12) pone el almacén del progreso de verdad (`internal/progress` sobre `0010_progress`) y la
validación de la creación con las reglas exportadas, y cambia lo de aquí que lo esperaba:

- **`serve` y la orden `admin`** usan `progress.Store` y `*progress.Rules` en todos los entornos. Ya no hay
  `errNoProgressStore`: `serve` arranca en `staging` y `production`, y `purge-now` y `reapply-purges` purgan allí
  el estado del progreso con `ProgressStore.Purge`. `MemoryProgressStore` y `ProvisionalValidator` quedan para las
  pruebas.
- **`platformtest.NewWithProgress(t, newStore, validator)`** monta la plataforma con el almacén de verdad
  (`ProgressStore` es el que esté en uso; `Progress`, el falso, es nil entonces) y `NewCharacter` crea con
  `platformtest.ValidAppearances`. `TestBackupAndRestoreCheck` (P9b) ya la usa, y `restore_check.sh` comprueba que
  los personajes purgados no tienen filas en `character_progress`, `character_wallets`, `item_instances` ni
  `character_timers`.
- **P9a:** el trabajo horario de la retención del libro llama a `ProgressStore.PurgeRetention` en una transacción
  mientras devuelva `deleted > 0` y borra en ella las filas de `characters` de `emptied`; la exportación pone
  `ProgressStore.Export` (`{"record", "ops"}`, sin datos del personal) bajo `characters[i].progress`, también de las
  lápidas con libro.
- **P7b y progresion.md P5d (auditoría):** la fila de `audit_log` que escribe S8 lleva en `args` el `detail` de la
  operación sin `command`, `source`, `actor_character_id` ni `at_unix` (`{"args": [...]}`, y las claves de nivel y
  XP si las hay); la entrada del lote con `key = "op:<op_id>"` tiene que llevar lo mismo.
- **P10:** las pruebas de extremo a extremo pueden comparar con `Load` (el registro de progresion.md §3.4).

**Sin comprobar:** con una zona de verdad (P10).
