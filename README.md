# Eldmark

MMORPG 3D de fantasía medieval hecho con [Godot 4](https://godotengine.org/).
Tres reinos en guerra por el control de los fuertes y castillos de una zona
central. Visión completa en [docs/vision.md](docs/vision.md).

> Estado: prototipo temprano.

## Requisitos

- Godot 4.7 (versión estándar, GDScript)
- Git y [Git LFS](https://git-lfs.com/)

## Cómo empezar

```bash
git clone https://github.com/Luisbh-dev/Eldmark
cd Eldmark
git lfs install
git lfs pull
```

Abre `project.godot` desde Godot y pulsa F5. Arranca el cliente (todavía sin red) en
el **Vado Gris**, la primera zona de frontera: el héroe animado aparece en el campamento
de Vardheim, delante de su muralla, con el fuerte al otro lado del río.

Controles:

| Acción | Tecla |
|---|---|
| Moverse | WASD |
| Mirar | Ratón |
| Saltar | Espacio |
| Esprintar | Mayús (mantener) |
| Liberar el cursor mientras se mantiene | Alt |
| Soltar el cursor hasta hacer clic | Esc |
| Cambiar de hombro | V |
| Acercar / alejar la cámara | Rueda del ratón |
| Panel de depuración | F3 |
| Ajustes (gráficos, audio, cámara e interfaz) | F10 |

Las teclas de combate (clic izquierdo y derecho, Ctrl, 1-3, E) ya están asignadas, pero
todavía no hacen nada (fase 3).

## Ajustes del jugador (F10)

**F10** abre y cierra la ventana de ajustes, tanto en el sandbox sin red como en el cliente en red
(Esc también la cierra; mientras está abierta el cursor queda libre). Tiene cuatro pestañas:

| Pestaña | Ajustes |
|---|---|
| Gráficos | modo de ventana (ventana, pantalla completa sin bordes o exclusiva), resolución (solo en modo ventana), sincronía vertical, límite de FPS, escala de render, sombras (desactivadas, bajas, medias o altas), distancia de la hierba (0 la quita) y suavizado de bordes (ninguno, FXAA, MSAA 2x o 4x) |
| Audio | volumen de cada bus: General, Música, Efectos, Ambiente, Interfaz y Voces |
| Cámara | sensibilidad del ratón, invertir el eje vertical, campo de visión y hombro por defecto |
| Interfaz | números de daño y placas de nombre |

Los cambios se aplican en vivo, se guardan al cerrar la ventana en `user://settings.cfg` (en Linux,
`~/.local/share/godot/app_userdata/Eldmark/`; en Windows, `%APPDATA%\Godot\app_userdata\Eldmark\`) y se
aplican al arrancar. Solo se escribe lo que el jugador ha tocado: un cliente sin `settings.cfg` arranca
exactamente igual que siempre, con el Vado Gris, la ventana y el suavizado del proyecto. «Restaurar
pestaña» y «Restaurar todo» devuelven los valores por defecto (y quitan esas claves del archivo). El
archivo es texto (`[graphics]`, `[audio]`, `[camera]` y `[interface]`) y se puede editar a mano: lo que
no sea válido se ignora y queda el valor por defecto. Está implementado en `ClientSettings`
(`scripts/client/ui/client_settings.gd`, que también describe cada ajuste) y `SettingsMenu`.

## Interfaz y audio

- El tema global (`assets/ui/theme/eldmark_theme.tres`, asignado en `project.godot` con
  `gui/theme/custom`) lo genera `tools/ui/build_theme.gd` a partir de la paleta `UIPalette`; para
  cambiar el aspecto se cambia la paleta o `UIThemeBuilder` y se vuelve a ejecutar
  (`godot --headless --path . -s res://tools/ui/build_theme.gd`). Aún no hay fuentes en el repositorio
  (usa la del motor): las ranuras de Noto Sans y Cinzel están preparadas y las instrucciones para
  añadirlas, en `assets/LICENCIAS.md`. Los emblemas de bando de `assets/emblems/` son provisionales
  (`tools/assets/make_emblems.py`).
- La galería de la interfaz muestra todos los estilos del tema y los componentes comunes (casillas
  de icono con rareza y reutilización, glifos de tecla, tooltip, diálogo de confirmación, foco):
  `godot --path . res://scenes/tests/ui_gallery.tscn`.
- Los glifos de tecla (la línea de ayuda del HUD, las casillas) leen la asignación real del
  `InputMap`, así que reflejan cualquier tecla reasignada.
- El audio es solo del cliente: `default_bus_layout.tres` define los buses (General con limitador,
  Música, Efectos, Ambiente, Interfaz y Voces) y `AudioDirector` reparte los sonidos en pools con un
  límite de voces por categoría. `CombatAudio` conecta el combate y los pasos con los bancos de `assets/audio/sfx/`
  (`CombatSoundBank`): impactos por material, barridos, esquivas y pasos por superficie, también los de los demás
  jugadores. `python tools/audio/listening_sheet.py` genera en `build/o4_hoja_escucha/` una hoja de escucha (un OGG
  por categoría con las opciones A y B seguidas) para elegir de oído entre lo sintetizado en casa y los packs CC0
  descargados.

## Zonas

El mundo se divide en zonas independientes (ver [docs/mundo.md](docs/mundo.md)). El registro
de zonas está en `scripts/shared/zones.gd` (`Zones`), que comparten cliente y servidor:

| Zona | Escena | Qué es |
|---|---|---|
| `vado_gris` (por defecto) | `scenes/world/zones/vado_gris/vado_gris.tscn` | Frontera de la fase 4: fuerte capturable entre Vardheim (norte) y Solmarch (sur). Ver [docs/zonas/vado_gris.md](docs/zonas/vado_gris.md) |
| `test_world` | `scenes/world/test_world.tscn` | Circuito de pruebas de movimiento y cámara de la fase 1 |

Se aparece en el primer punto de aparición del reino elegido (los marcadores del grupo
`spawn_points` llevan el metadato `realm`); si la zona no tiene puntos de ese reino, en el
primero de la zona.

## Pruebas y demo

Desde la raíz del proyecto (`godot` es el ejecutable de consola de Godot 4.7):

```bash
# Importar recursos y validar el proyecto
godot --headless --path . --import

# Pruebas automáticas (código de salida 0 si todo pasa)
godot --headless --path . -s res://tests/run_tests.gd
# Solo las pruebas cuyo nombre contiene un texto
godot --headless --path . -s res://tests/run_tests.gd -- --filter=replay
# Solo la parte 2 de 4 de los archivos de prueba (repartidos por turnos, como en la CI)
godot --headless --path . -s res://tests/run_tests.gd -- --shard=2/4

# Arrancar el cliente sin ventana durante 300 fotogramas (comprobación rápida)
godot --headless --path . --quit-after 300

# Jugar con Solmarch en el Vado Gris
godot --path . -- --realm=solmarch

# Demo guionizada en el Vado Gris (unos 33 s) con una captura PNG cada 90 ticks, las capturas
# de las cámaras de revisión de la zona al final y salida al terminar
godot --path . -- --zone=vado_gris --demo --shots=C:/ruta/absoluta/capturas --quit-after-demo

# Demo de la fase 1 en el circuito de pruebas (unos 10 s)
godot --path . -- --zone=test_world --demo --quit-after-demo
```

Opciones de arranque (van después de `--`):

- `--zone=<id>`: zona que se carga (`vado_gris` por defecto o `test_world`).
- `--realm=<reino>`: reino del jugador (`vardheim` por defecto o `solmarch`); decide el
  punto de aparición.
- `--demo`: el personaje y la cámara siguen un guion en lugar del teclado y el ratón. En el
  Vado Gris recorre la ruta del puente de su reino: sale del campamento, esprinta con un salto
  por la calzada, cruza el puente, salta dos veces al pie del fuerte, da un paso lateral, rodea
  la empalizada hasta la puerta (frente al vado) y la cámara da una vuelta completa. En
  `test_world` es el guion fijo de la fase 1. Los dos acaban con un combate de unos 5 s (combo de tres
  ligeros, fuerte cargado, bloqueo y esquiva) y la demo escribe al terminar las acciones que recorrió
  el personaje («Demo, acciones de combate: LIGHT x4, CHARGE x1, HEAVY x1, BLOCK x1, DODGE x1»; el
  cuarto ligero es la pulsación que se convierte en la carga).
- `--shots=<carpeta absoluta>`: durante la demo guarda `shot_000.png`, `shot_001.png`...
  y, al terminar, una captura sin HUD desde cada cámara de revisión de la zona
  (`zona_<nombre>.png`, marcadores del grupo `screenshot_points`). Necesita ventana; en modo
  headless se omiten.
- `--quit-after-demo`: cierra el juego al terminar la demo.
- `--server`: servidor dedicado de una zona (ver «Servidor dedicado» más abajo).
- `--connect=<host>[:<puerto>]`, `--local` y `--bot`: cliente en red (ver «Cliente en red» más
  abajo).
- `--bots=N`: enjambre de N clientes ligeros para pruebas de carga (ver «Enjambre de bots»).
- `--title` y `--platform=<url>`: la pantalla de título con cuenta (ver «Cliente con cuenta»). Una
  exportación sin argumentos también la abre; desde el editor, sin argumentos sigue el sandbox.

Las capturas y otros ficheros temporales pueden ir en `build/`, que Godot ignora.

### Banco de capturas de calidad (`tools/quality/`)

El plan de calidad visual ([docs/calidad.md](docs/calidad.md)) se comprueba con capturas, no a ojo: el banco regenera con
una orden por área las capturas y tiras que demuestran cada criterio del listón, en la misma resolución y con los mismos
encuadres, para poder enseñar un antes y un después. Necesita **ventana y GPU** (no sirve en `--headless`), Python 3 con
Pillow (`pip install pillow`) y el ejecutable de consola de Godot (lo busca en `GODOT`, en la instalación de winget y en el
`PATH`; o `--godot <ruta>`). Si existe `override.cfg` en la raíz (lo ignora Git), las ventanas se abren en la segunda pantalla.
No usa cuentas ni contraseñas: el servidor va con `--debug-commands` y el cliente de captura entra con un personaje efímero.

```bash
# Una orden por área (todas escriben en build/calidad, o en la carpeta de --out, y regeneran su indice.md)
python tools/quality/run.py animacion --out build/calidad    # tiras de 12 fotogramas en el sandbox: jugador y PNJ
python tools/quality/run.py mapa                             # mapa M, minimapa y brújula
python tools/quality/run.py interfaz                         # HUD, ventanas, título, creación, galería y chat
python tools/quality/run.py mundo                            # 66 vistas a altura de jugador, cámaras de revisión y demo
python tools/quality/run.py combate                          # refriegas, golpe en bloqueo y remotos aislados
python tools/quality/run.py video --seconds 60               # un minuto de combate con --write-movie
python tools/quality/run.py todo --port 24721                # las seis áreas seguidas
python tools/quality/run.py indice --out build/calidad       # solo regenera el índice
python tools/quality/run.py listar                           # áreas y pasos
```

Para comparar dos pasadas con los mismos encuadres (antes y después de un cambio), `python tools/quality/compare_before_after.py
<carpeta_antes> <carpeta_después> --out <carpeta> --pattern "pelea_*.png"` deja cada pareja lado a lado con su rótulo.
El vídeo de `video` lleva el sonido del bus maestro (`--mp4` lo pasa a MP4 con ffmpeg); con `ELDMARK_FEEL_LOG=1` el cliente
imprime al cerrar cuántos golpes predijo en local y cuántos sonidos pidió de cada grupo.

Cada orden arranca lo que necesita (el sandbox, o un servidor del Vado Gris en `--port`, 24711 por defecto, con sus bots y el
cliente conducido por `online_driver.gd`), recoge las capturas en `<out>/<área>/`, une las tiras en rejillas, escribe
`<out>/indice.md` (qué enseña cada archivo, con qué clips, desde cuándo) y, al acabar o al interrumpirla, cierra los procesos de
Godot que lanzó. Opciones: `--steps a,b` (solo algunos pasos del área, ver `listar`), `--only <ids>` (en `animacion`, solo esas
acciones), `--phases hueco,capitan,guardia,guardian` (en `combate --steps pnj`, solo esas fases), `--bots N` (bots de asedio por reino), `--resolution WxH` (1920x1080), `--sin-capsulas` (en `mundo`, las cámaras de
revisión sin las cápsulas de escala), `--clean-raw` (borra los fotogramas sueltos de `raw/` y deja sus `meta.json`) y `--godot`.

| Área | Qué lanza | Qué deja en `<out>` |
|---|---|---|
| `animacion` | `anim_strips.gd` sobre `test_world` (personaje, `HumanoidVisual`, `CameraRig` y `LocalPlayerController` de verdad; los guiones de entradas están en `anim_actions.gd`) | `animacion/{camara_juego,lado,frente}/<acción>.png`: `loc_*`, `com_*`, `arc_*` y `npc_*` (Hueco, Capitán, guardia de reino y Guardián de la Puerta, con ataques, bloqueo, tambaleo y muerte) |
| `mapa` | servidor con 2 x 6 bots de asedio y `sc_mapa.gd` | `mapa/minimapa_*`, `brujula_*`, `mapa_m_*` e `imagen_horneada_vado_gris.png` |
| `interfaz` | el mismo servidor con `sc_interfaz.gd` y `sc_extras.gd`, y sin servidor `sc_front.gd` (título, selección y creación con datos de mentira), `sc_gallery.gd` y `chat_preview.tscn` | `interfaz/*.png` y los `recorte_*.png` de `crops.py` (las mismas regiones de píxeles de la auditoría) |
| `mundo` | servidor sin PNJ ni bots (`--no-npcs --no-dummies`), `sc_mundo.gd` como Vardheim y como Solmarch, `tools/render/render_screenshot_points.gd` y la demo del sandbox | `mundo/jugador_{vardheim,solmarch}/` (33 vistas cada uno), `mundo/camaras_revision/` (con `metricas.txt`) y `mundo/demo_sandbox/` |
| `combate` | `sc_combate.gd` con 2 x 6 bots; después un servidor sin PNJ con **un solo bot** de combate (`sc_remotos_bot.gd` y `sc_bloqueo.gd`) y otro con los PNJ del Vado Gris sin bots (`sc_remotos_pnj.gd`) | `combate/pelea_*` y `bloqueo_recibiendo_*`, y las tiras de remotos en `animacion/remoto/` y `animacion/remoto_lado/` |
| `video` | servidor con los PNJ del fuerte y un bot de combate, y `sc_video.gd` con `--write-movie` | `video/combate.avi` (y `.mp4` con `--mp4` si hay ffmpeg) y `video/video.json` |

**Tiras de otros personajes (`rem_*`).** El cliente de captura pelea con un bot o un PNJ ([`spar.gd`](tools/quality/spar.gd):
ligeros, fuertes, bloqueo, retroceso...) y [`strip_recorder.gd`](tools/quality/strip_recorder.gd) guarda cada 50 ms los últimos
4,5 s del personaje seguido. Cuando ocurre la acción buscada (el borde de subida de `BLOCK`, `DODGE`, `DEAD`...) la tira sale del
anillo con el principio de la acción y se descarta si no cumple su validación (por ejemplo, un «ataque ligero» que se convierte en
carga). El bot va **solo** (servidor sin PNJ ni maniquíes y un único bot completo, que usa habilidades, bloqueo y esquiva), así que
nadie lo tapa; cada tira lleva además una vista lateral propia a 5 m (`remoto_lado`) y marca `TAPADO` los fotogramas con otro
cuerpo delante de la cámara del juego. El `meta.json` de cada tira guarda por fotograma la acción de combate, la fase, la
velocidad y **el clip que reproduce la capa de animación del remoto** (`clip`, `clip_t`, `clip_speed`), y el índice resume cuántos
fotogramas de acción tienen clip (por ejemplo, `0/9` en el ataque de un PNJ que ataca andando). Las tiras que ya existen son las
del bot (`rem_bot_*`), el Hueco, el Capitán, el guardia de reino, el Guardián de la Puerta y el golpe recibido en bloqueo
(`com_bloqueo_recibir_golpe*`: lleva en cada fotograma la marca del golpe que vio el cliente: `BLOQUEADO`, `PARADA`...).

**Vídeo (`video`).** `run.py video` lanza el cliente con el `--write-movie combate.avi --fixed-fps 60` del motor (Movie
Maker: graba cada fotograma y el audio del bus maestro, PCM estéreo a 48 kHz). El vídeo sale al tamaño de la ventana del proyecto
(1600x900, `window_width_override`), no al de `--resolution`. El motor avanza un fotograma de 1/60 s por iteración sin mirar el
reloj, así que el vídeo sale a 60 fotogramas por segundo exactos aunque la grabación vaya más lenta que el tiempo real (en el
equipo de desarrollo, al 34 %: el JPEG de cada fotograma pesa); el servidor, que no sabe que se graba, sigue en tiempo real y el
cliente lo compensa como con cualquier mala conexión. Cuando la máquina llega, el conductor frena el juego a tiempo real. La
duración es la del guion en fotogramas (`--seconds`, 60 por defecto; unos 8 MB por segundo de vídeo): la mitad contra los Huecos y
el Capitán del patio del fuerte y el resto contra un bot enemigo, con ligeros, fuertes, habilidades, esquivas y bloqueos. A mano:

```bash
godot --path . --resolution 1600x900 --write-movie build/calidad/video/combate.avi --fixed-fps 60     -s res://tools/quality/online_driver.gd -- --connect=127.0.0.1:24711 --realm=vardheim --name=Cronista     --scenario=res://tools/quality/sc_video.gd --out=build/calidad --tag=video --seconds=60
```

Mientras `assets/audio/` esté vacío la pista de audio saldrá en silencio; el vídeo sirve ya para juzgar la fluidez y la parada
de golpe. Las pruebas de este banco (`tests/test_quality_tools.gd`) comprueban sin ventana que todos los scripts cargan, que
cada PNJ del catálogo tiene su juego de tiras, que las tiras de remotos están bien formadas, la lógica de la grabadora y, si hay
Python con Pillow, las piezas de Python con datos de mentira.

### Integración continua

`.github/workflows/tests.yml` (GitHub Actions, `ubuntu-latest`) ejecuta la suite completa, red y
procesos incluidos, en cada push a `main` y en cada pull request: descarga Godot 4.7.2-stable para Linux
(con comprobación SHA-512 y en caché), baja los objetos de Git LFS (también en caché), importa el
proyecto y lanza `tests/run_tests.gd` repartido en cuatro partes a la vez (`--shard=K/4`), cada una
con un plazo de 20 minutos. Si una falla, sube su `build/` (logs e informes) como artefacto
`build-logs-K`. El trabajo «Suite completa» solo pasa si pasan las cuatro: para que una prueba rota
bloquee el merge hay que marcarlo como comprobación obligatoria en la protección de la rama. Se puede
lanzar a mano desde la pestaña Actions (`workflow_dispatch`). El trabajo «Plataforma», aparte, comprueba
que no haya secretos en el índice (`tools/check_secrets.sh`) y pasa `gofmt`, `go vet` y `go test` del
servicio de plataforma (abajo).

## Servidor dedicado

Un proceso del mismo proyecto, siempre con `--headless`, sirve una zona en un puerto UDP (diseño
en `docs/red.md`). Por ejemplo, el Vado Gris con 8 jugadores falsos durante 30 s y un informe
JSON al cerrar:

```bash
godot --headless --path . --log-file build/servidor.log -- --server --zone=vado_gris \
    --port=24600 --fake-players=8 --quit-after-ticks=1800 --report=build/informe.json
```

Opciones (después de `--`): `--server`, `--zone=<id>`, `--port=24600`, `--max-players=64`,
`--max-per-ip=4`, `--idle-quit=<s>` (se cierra tras esos segundos sin jugadores),
`--fake-players=N` (jugadores sin red, para pruebas y carga) con `--fake-layout=cluster|spread`
(todos agrupados en un punto, a menos de 60 m, o repartidos por la zona) y `--fake-churn=<ticks>`
(cada tantos ticks sale el más antiguo y entra uno nuevo: 60 = una alta y una baja por segundo),
`--debug-commands` (admite el teletransporte de depuración de los clientes), `--dev-lock` (escribe
`user://dev_server.json` para que `--local` reutilice el servidor; `--dev-lock-path=<ruta>` lo escribe
en otro sitio, y `--local --dev-lock-path=<ruta>` lo lee de ahí), `--quit-after-ticks=N`,
`--report=<ruta.json>`, `--state-log=<ruta.txt>` (`tick,net_id,sustituida,estado` por tick y
jugador; ver «Registros de estado») y `--net-sim=rtt=120,jitter=20,loss=5,dup=0,seed=1`. El
registro escribe las altas, las bajas, las expulsiones y, cada 10 s, la duración del tick y el
ancho de banda. El informe lleva, además de los contadores, el p50/p99/máximo del tick y de cada
sección, los µs de cada `simulate()` y el tamaño y el coste de construir los snapshots. El código
de salida es 0 en un cierre normal y 1 si no puede arrancar (zona desconocida, puerto ocupado).

Con la plataforma (`docs/plataforma.md` §8 y «Servicio de plataforma», abajo) la zona se registra en la API
interna y solo admite clientes con billete: `--platform=<url interna>` (sin ella, cada cliente entra con un
personaje efímero que se pierde al salir, `docs/progresion.md` §9.4), `--world=<id>` (1) y `--channel=<n>` (0),
`--public-address=<host>[:<puerto>]` (a dónde conectan los clientes), `--save-interval=<s>` (el punto de control
de los guardados, 60) y `--replace` (sustituye a una instancia viva de la misma zona y canal). El token de la zona
y las claves de los billetes van en `ELDMARK_ZONE_TOKEN` y `ELDMARK_TICKET_KEYS` o en los archivos que nombran
`ELDMARK_ZONE_TOKEN_FILE` y `ELDMARK_TICKET_KEYS_FILE` (`platform/deploy/dev.sh` los prepara y escribe la orden
entera). Con plataforma, la zona sale con 1 si no puede registrarse y con 3 si la plataforma cierra la
instancia. `--console` lee comandos de la entrada estándar, también los del progreso (`item_give`, `xp_add`,
`inv_show`…, `docs/progresion.md` §10).

Con `--dtls-cert=<pem> --dtls-key=<pem>` (con o sin plataforma, `docs/plataforma.md` §10.2) la zona abre el puerto
por DTLS y, con plataforma, manda el certificado y su CN en el registro: el cliente lo recibe en `enter` y lo ancla.
El certificado es autofirmado, con CN y con la clave sin contraseña (EC P-256 hace el apretón de manos más barato;
la orden de OpenSSL está en `platform/deploy/docker-compose.yml`); si falta uno de los dos, no se lee, no tiene CN o
la clave no es la suya, la zona sale con 1. Sin plataforma, un cliente o un enjambre entran con `--dtls-cert=<pem>
--dtls-name=<cn>` (el certificado y el nombre de la zona); en staging y producción la plataforma no registra una
zona sin certificado.

El servidor se defiende de los clientes (docs/red.md, sección 12): limita los paquetes por tick y
por segundo y los bytes de cada peer, cuenta un aviso por cada paquete mal formado, de un tipo
inesperado para el estado de la sesión o por encima del ritmo, y expulsa con un NOTICE al que
suma 50 avisos en 600 ticks; además admite como mucho `--max-per-ip` conexiones por IP (salvo
desde loopback).

## Servicio de plataforma (Go)

`platform/` es el servicio de cuentas, personajes y guardado de la fase 5, en Go 1.24 sobre PostgreSQL 16
(diseño en `docs/plataforma.md`; lo hecho, en su §19). Godot no lo escanea (`platform/.gdignore`) ni lo
exporta. Se configura con variables `ELDMARK_*` (§2.3):

```bash
cd platform
go test ./...                                   # levanta un PostgreSQL efímero con initdb (sin Docker)
go run ./cmd/eldmark-platform migrate status    # o migrate up, migrate down N (solo dev y test)
go run ./cmd/eldmark-platform serve             # API pública en :24680 e interna en :24681
```

Las pruebas necesitan los binarios de PostgreSQL (`ELDMARK_PG_BIN`, `pg_config` o
`/usr/lib/postgresql/*/bin`; si no hay, se saltan) o un servidor en `ELDMARK_TEST_DATABASE_URL`. Como root,
`initdb` corre con `runuser -u postgres`, que tiene que poder entrar en `TMPDIR`.

Las de extremo a extremo (`platform/e2e`, `docs/plataforma.md` P10) llevan la etiqueta `e2e` y arrancan la
plataforma en el proceso de la prueba contra una zona `test_world` y bots de Godot de verdad; sin `ELDMARK_GODOT` se
saltan. Importan el proyecto al empezar (con los objetos de LFS bajados) y tardan menos de un minuto:

```bash
cd platform
ELDMARK_GODOT=<ruta de Godot 4.7.2> go test -tags e2e -count=1 -v ./e2e
# ELDMARK_E2E_ARTIFACTS=<carpeta> conserva los registros de la plataforma, las zonas y los bots
```

En desarrollo (`ELDMARK_MAIL=log`, por defecto) los correos de las cuentas no salen: van a la tabla
`outbound_mail` y al registro con el enlace entero (`/verify`, `/reset` o `/revert` sobre `ELDMARK_PUBLIC_URL`).
Los textos legales que se aceptan al registrarse son los borradores de `platform/legal/`, que van dentro del
binario (`ELDMARK_LEGAL_DIR` los cambia por los de otra carpeta).

Los personajes (`/v1/worlds/{w}/characters`, `POST /v1/characters/{id}/enter`) guardan su progreso en
PostgreSQL (las tablas de `0010_progress` y `platform/internal/progress`, `docs/progresion.md` P7): al crearlos se
validan raza, apariencia y plantilla con las reglas exportadas, y cada guardado de la zona pasa las comprobaciones
S1–S8 (`docs/progresion.md` §13.3). `enter` solo da billete si hay una instancia de zona viva que admite el reino.
Las reglas de los nombres y el protocolo mínimo por defecto salen de
`platform/internal/gamedata/progression_rules.json`, que se genera desde Godot, igual que las razas, la apariencia
(`data/characters/`), la curva de niveles (`data/progression/`), los objetos (`data/items/`), las plantillas de
inicio, las monedas, los motivos, los contenedores y la vida máxima. Tras cambiar cualquiera de esos datos hay que volver a exportarlo (la prueba
`test_progression_rules_export.gd` avisa si se ha quedado viejo):

```bash
godot --headless --path . -s res://tools/progression/export_rules.gd             # lo escribe
godot --headless --path . -s res://tools/progression/export_rules.gd -- --check  # solo lo compara
```

La API interna (`/internal/v1`, en `ELDMARK_INTERNAL_ADDR`, solo para las zonas) pide en cada petición el
token de un despliegue de zona: `ELDMARK_ZONE_TOKENS` guarda su SHA-256 con el alcance
`<mundo>:<zona>:<canal>`. Para probarla a mano con el token `secreto` de `1:vado_gris:0` (`protocol_version`, el
de `progression_rules.json`):

```bash
export ELDMARK_ZONE_TOKENS="1:vado_gris:0:$(printf %s secreto | sha256sum | cut -d' ' -f1)"
curl -s -H 'Authorization: Bearer secreto' -d '{"world_id": 1, "zone_id": "vado_gris", "channel": 0,
  "public_host": "127.0.0.1", "public_port": 24600, "realms": [1, 2], "build_id": "dev", "protocol_version": 5,
  "record_format": 1, "max_players": 64, "dtls_cert_pem": null, "dtls_name": null, "replace": false}' \
  http://127.0.0.1:24681/internal/v1/zone-instances
```

Una instancia que deja de latir 3 × `ELDMARK_HEARTBEAT_S` se da por perdida y sus personajes quedan libres.
`ELDMARK_LEASE_TTL_S` tiene que pasar de 3 × `ELDMARK_HEARTBEAT_S` + min(5, `ELDMARK_HEARTBEAT_S`) segundos (con 5 y
30, los valores por defecto, sobra); si no, `serve` no arranca.

Cada hora, `serve` purga las cuentas y los personajes que han cumplido su plazo y borra lo caducado según la tabla de
retenciones de `docs/plataforma.md` §11.1 (el chat a los 30 días, la auditoría y los reportes cerrados al año, el
libro de un personaje al año de purgarlo…). La exportación de datos de una cuenta (`POST /v1/account/export`) lleva
también el progreso de sus personajes.

La moderación y las cuentas del equipo van por la orden `admin`, con la misma configuración que `serve`. Toda
orden lleva `--actor` con el correo de una cuenta `admin` (o `moderator` para las de lectura) y deja su fila en
la auditoría (`audit_log`, sin correos ni nombres); la primera cuenta `admin` se crea con `bootstrap`. La
contraseña de las cuentas nuevas se lee de un archivo, nunca de la línea de órdenes:

```bash
go run ./cmd/eldmark-platform admin bootstrap jefa@eldmark.test --password-file clave.txt
go run ./cmd/eldmark-platform admin --actor jefa@eldmark.test create-account prueba@eldmark.test --password-file clave.txt
go run ./cmd/eldmark-platform admin --actor jefa@eldmark.test set-role gm@eldmark.test gm     # revoca sus sesiones
go run ./cmd/eldmark-platform admin --actor jefa@eldmark.test reports list
go run ./cmd/eldmark-platform admin --actor jefa@eldmark.test chat --character Bran --from 2026-11-01 --to 2026-11-02
go run ./cmd/eldmark-platform admin --actor jefa@eldmark.test sanction add Bran mute --duration 24h --reason "insultos"
go run ./cmd/eldmark-platform admin help                                                       # todas las órdenes
```

### Plataforma en local y despliegue

`platform/deploy/dev.sh` levanta la plataforma de desarrollo sin Docker (Linux, macOS o WSL, con los binarios de
PostgreSQL 16 y Go): un PostgreSQL propio en `build/dev_pg` (en 127.0.0.1:24682), las migraciones, claves y un
token por zona de desarrollo (`vado_gris` y `test_world`) en `build/dev_secrets/`, una cuenta `admin@eldmark.test`
y otra `prueba@eldmark.test` (contraseñas `eldmark-admin-dev` y `eldmark-prueba-dev`), y escribe la orden de la
zona con `--platform`. Los datos se conservan entre arranques:

```bash
platform/deploy/dev.sh                # lo prepara todo y arranca serve; Ctrl-C para serve y PostgreSQL
platform/deploy/dev.sh prepare        # lo mismo sin serve (PostgreSQL queda en marcha; dev.sh stop lo para)
eval "$(platform/deploy/dev.sh env)"  # las variables para usar eldmark-platform a mano
platform/deploy/dev.sh reset          # borra la base, las claves y las cuentas de desarrollo
```

Staging y producción van con `platform/deploy/docker-compose.yml` (base, plataforma, Caddy con HTTPS de Let's
Encrypt, zonas y copias), un `staging.env` o `production.env` sacado de su `.example` y los secretos como archivos
en `platform/deploy/secrets/` (ignorada por git); la cabecera del compose tiene las órdenes y la lista de
secretos, y `docs/plataforma.md` §12 y §19.13, el resto. Las copias: `backup.sh` (diaria, con `purges.txt`),
`restore_check.sh` (restauración de prueba semanal, con `reapply-purges`) y `pitr_check.sh` (recuperación a un
instante); los tres corren en local contra un PostgreSQL efímero o en el contenedor `ops` del compose. Tras
restaurar una copia de verdad, y antes de arrancar `serve`:
`eldmark-platform admin --actor <correo> reapply-purges <carpeta de copias>/purges.txt`.

## Exportación (cliente Windows y servidor Linux)

`export_presets.cfg` (en texto, versionado) define dos destinos, y `tools/export.sh` (Linux y macOS) o
`tools/export.ps1` (Windows) los exportan a `exports/` (que no se versiona):

| Preset | Plataforma | Salida | Qué lleva |
|---|---|---|---|
| `Cliente Windows` | Windows x86_64 | `exports/windows/Eldmark.exe` (más `Eldmark.pck` y la DLL de Terrain3D) | Todos los recursos; el .pck va aparte del ejecutable |
| `Servidor Linux` | Linux x86_64, servidor dedicado | `exports/server/eldmark-server.x86_64` (más su .pck y el `.so` de Terrain3D) y `run-server.sh` | Los modelos, materiales, audio y animaciones recortados («strip»: sin la capa visual, pero la escena sigue cargando); las texturas del terreno se conservan porque Terrain3D las valida |

Los dos dejan fuera `build/`, `docs/`, `tests/`, `tools/`, `exports/`, `.github/` y `scenes/tests/`, y
conservan las licencias de los addons y `assets/LICENCIAS.md` (la MIT las exige).

**Pasos (una vez, en tu máquina):**

1. Instala las **plantillas de exportación 4.7.2** (no vienen con el editor): abre Godot 4.7.2, menú
   *Editor > Administrar plantillas de exportación > Descargar e instalar*, o descarga
   `Godot_v4.7.2-stable_export_templates.tpz` de la página de la versión y usa *Instalar desde archivo*.
   Quedan en `%APPDATA%\Godot\export_templates\4.7.2.stable` (Windows) o
   `~/.local/share/godot/export_templates/4.7.2.stable` (Linux). Sin ellas el script se detiene y lo dice.
2. Baja los objetos de Git LFS (`git lfs pull`): el terreno y las texturas van por LFS y el script se
   niega a exportar si son punteros.
3. Exporta:

```bash
tools/export.sh                  # los dos destinos
tools/export.sh server --zip     # solo el servidor, y lo comprime
tools/export.sh --pack-only      # solo los .pck: NO necesita las plantillas (para comprobar filtros y recorte)
tools/export.sh --dry-run        # muestra lo que haría
```

```powershell
tools\export.ps1                 # equivalente en Windows: -Target client|server|all, -DebugBuild, -PackOnly, -Zip, -DryRun
```

El servidor exportado se lanza con `./run-server.sh --zone=vado_gris --port=24600` (el lanzador pone
`--headless`: un servidor exportado sin pantalla necesita esa opción; después van las del servidor de
la sección anterior). El identificador de la compilación (`git describe`) se guarda en `BUILD_ID` junto
a lo exportado.

**Estado de TEC-12.** Hecho y comprobado aquí: los presets (`godot --export-pack` de los dos funciona y
sus filtros están probados en `tests/test_export_config.gd`, que exporta el paquete del servidor en un
proceso aparte) y un servidor emulado (el binario del editor con el .pck exportado y el `.so` de
Terrain3D al lado) que carga el Vado Gris y simula 180 ticks sin errores. Sin hacer, porque necesita las
plantillas o una máquina Windows: exportar el ejecutable de verdad, el `--bot` de Windows contra el
servidor Linux y medir con `--state-log` las diferencias de último bit entre las dos plataformas; el
identificador de compilación visible en el cliente y en el informe del servidor; y el trabajo de CI por
etiqueta que publica los artefactos (descargaría las plantillas en el trabajo; falta fijar la
distribución). La exportación a Windows desde Linux solo da el ejecutable sin icono ni
metadatos (`application/modify_resources=false`: no se depende de `rcedit`).

## Cliente en red

Con un servidor ya arrancado, `--connect` conecta con él; la zona la dicta el servidor. Un bot es el
mismo cliente sin cámara ni HUD, guiado por un `BotBrain` determinista (útil para pruebas y carga):

```bash
# Jugar contra un servidor local
godot --path . -- --connect=127.0.0.1 --realm=solmarch --name=Ana

# Un bot sin ventana: 25 s de juego, informe JSON al terminar y registro de estados
godot --headless --path . -- --bot --connect=127.0.0.1:24600 --bot-seed=3 \
    --quit-after-ticks=1500 --report=build/bot_3.json --state-log=build/bot_3.csv
```

Opciones (después de `--`): `--connect=<host>[:<puerto>]`, `--port=<puerto>` (gana al de
`--connect`), `--realm=<reino>` (sin él, un cliente con ventana muestra la pantalla de elección de
reino; un bot o un cliente sin ventana entra como Vardheim, con un aviso), `--name=<nombre>` (por
defecto «Jugador» y cuatro letras al azar), `--local`, `--bot`, `--bot-seed=N`, `--bot-cheat=version|future|dupes|garbage|flood` (bot
tramposo, ver más abajo),
`--net-sim=rtt=120,jitter=20,loss=5,dup=0,seed=1`, `--quit-after-ticks=N` (ticks de física locales
desde que arranca la sesión, contando la conexión y la carga de la zona; los últimos ticks el bot se
queda quieto), `--report=<ruta.json>` (coincidencias exactas, diferencias explicadas y sin
explicar, reinicios y resincronizaciones, ajustes de TickSync y estado final) y
`--state-log=<ruta.txt>` (`server_tick,predicho,servidor` en hexadecimal por snapshot). Con
`--quit-after-ticks` el código de salida es 0 si el bot llegó a jugar y salió por su pie, y 1 si
fue rechazado, se desconectó o no llegó a entrar en la zona.

Las rutas de `--report` y `--state-log` pueden ir en `build/`, pero con `--state-log` dentro del
proyecto usa la extensión `.txt`: el importador de Godot convierte los `.csv` en traducciones.

### Cliente con cuenta (`--title`, `--bot --platform`)

Contra la plataforma (docs/plataforma.md §13), el cliente arranca en la pantalla de título: inicio de
sesión, selección y creación de personaje, y «Entrar» pide el billete y conecta con la zona que diga la
plataforma. Sin `--platform` usa el ajuste de proyecto `eldmark/platform/url` (`http://127.0.0.1:24680`).
Solo admite `https://` o, hacia esta máquina, `http://`; `eldmark/platform/ca_cert` ancla un certificado
propio (staging).

```bash
# El título contra la plataforma local
godot --path . -- --title --platform=http://127.0.0.1:24680

# Un bot con cuenta: inicia sesión, crea «Probador» si no existe, pide el billete y entra
godot --headless --path . -- --bot --platform=http://127.0.0.1:24680 --login=bot@eldmark.test \
    --password-file=build/bot.pw --character=Probador --realm=solmarch --quit-after-ticks=1500 \
    --report=build/bot.json
```

La contraseña del bot va siempre en un archivo (`--password-file`), nunca en la línea de órdenes. Sin
`--login` o `--password-file`, o si la cuenta falla (credenciales, `character_busy` tras 30 s,
`zone_unavailable`), el bot sale con código 1 y el `code` de la plataforma en el informe
(`platform.code`). `--world=N` elige el mundo (1). `--bots` no admite `--platform`.

### Enjambre de bots (`--bots=N`)

`--bots=N` lanza un proceso con N clientes ligeros (`BotSwarm`/`SwarmBot`) que no cargan la zona ni
simulan: entran uno cada 5 ticks, predicen con el `TickSync` de verdad, caminan guiados por su
`BotBrain` y confirman los snapshots. Sirven para cargar el servidor sin que el generador de carga
sea el cuello de botella:

```bash
godot --headless --path . -- --bots=32 --connect=127.0.0.1:24600 --realm=vardheim \
    --bot-seed=1000 --quit-after-ticks=3600 --report=build/enjambre.json
```

Con `--quit-at-server-tick=N` el enjambre se va cuando alguno de sus bots recibe un snapshot del tick N
del servidor, aunque el servidor vaya más despacio que el tiempo real (lo usa `tools/load_test.gd`).
Cada bot se llama `Bot` más cuatro letras según `--bot-seed` más su índice, así que dos enjambres
contra el mismo servidor necesitan semillas distintas. Sin `--realm` se reparten entre Vardheim y
Solmarch. El informe trae los bytes de subida y de bajada de cada cliente, los snapshots recibidos
y su tamaño medio. Código de salida 0 si todos jugaban al terminar y 1 si alguno fue rechazado o se
cayó. Contra una zona con DTLS, `--dtls-cert=<pem> --dtls-name=<cn>` (sin el nombre, o con un certificado que no
se puede leer, sale con 1 sin conectar en claro).

### Bot tramposo (`--bot-cheat`)

Un `--bot` con `--bot-cheat=<modo>` hace trampa sin dejar de predecir con sus entradas honradas;
sirve para comprobar que el servidor no se deja (docs/red.md, sección 12):

| Modo | Qué hace | Qué debe pasar |
|---|---|---|
| `version` | HELLO con otra versión del protocolo | REJECT por versión |
| `future` | lotes de entradas con ticks muy por delante de la ventana | se descartan y se cuentan; sin efecto ni ventaja |
| `dupes` | copias distintas de las mismas entradas | gana la primera copia |
| `garbage` | paquetes al azar por el canal de entradas y el fiable | avisos y expulsión |
| `flood` | más paquetes por tick de los que admiten los limitadores | avisos por exceso de ritmo y expulsión |

### Registros de estado y comparación

Con `--state-log` el servidor escribe el estado de cada jugador en cada tick
(`tick,net_id,sustituida,estado`) y el bot el estado que predijo y el que le llegó en cada snapshot
(`server_tick,predicho,servidor`). `tools/compare_state_logs.gd` los cruza y clasifica cada
snapshot del bot: coincide bit a bit, diferencia explicada (el servidor sustituyó una entrada) o
diferencia sin explicar (un fallo de determinismo). Sale con código 1 si hay alguna sin explicar:

```bash
godot --headless --path . -s res://tools/compare_state_logs.gd -- build/servidor.txt build/bot.txt [net_id]
```

### Pruebas de carga

`tools/load_test.gd` lanza un servidor con jugadores falsos y procesos `--bots`, espera a que
terminen y resume lo que mide el servidor: p50/p99/máximo del tick por sección, µs de `simulate()`
por personaje, tamaño de los snapshots, KB/s por cliente y entradas sustituidas (las de toda la
sesión y las de la ventana de medida, sin el arranque), con el criterio de la fase 2 (con 64
agrupados y 100 ms de RTT: p99 del tick por debajo de 8 ms, 37 KB/s por cliente, menos de un 1 %
sustituidas en la ventana). Escenarios: `cluster` (agrupados en 60 m), `spread` (dispersos) y `churn`
(altas y bajas a 1 por segundo). Está documentado en la cabecera del script:

```bash
# Un escenario: 64 falsos agrupados y 10 clientes reales
godot --headless --path . -s res://tools/load_test.gd -- --scenario=cluster --fakes=64 --bots=10
# La batería de la fase 2: 64, 128 y 256 jugadores falsos y el criterio con 100 ms de RTT, 120 s
# de medida cada escenario (unos 25 minutos; con la máquina libre)
godot --headless --path . -s res://tools/load_test.gd -- --matrix
```

Los informes quedan en `build/load_test/` (`summary.txt` y `summary.json`).

Con `--dtls` el servidor y los enjambres van por DTLS (con el certificado de las pruebas, o con `--dtls-cert`,
`--dtls-key` y `--dtls-name`). `--dtls-compare` es la campaña de TEC-27: el mismo escenario sin y con DTLS,
alternados (por defecto 64 bots reales agrupados en dos enjambres, 60 s, `--repeat=2`), y al final cuánto sube cada
cifra y el criterio (el p99 del tick no sube más de un 10 %). Resultados en `docs/red.md` §14:

```bash
godot --headless --path . -s res://tools/load_test.gd -- --dtls-compare --repeat=3
```

Con combate (TEC-15), `--scenario=brawl` junta a los falsos con el cerebro de combate
(`--fake-brain=combat`, en un corro alrededor de `--fake-center=x,z`) y a bots reales que pelean
(`--bot-brain=combat`) y mide además las secciones de combate (golpes con rebobinado, eventos), los
µs por comprobación de golpe y los KB/s de eventos; `--brawl` lanza la batería de 32, 64 y 128
combatientes (60 s cada una, unos 6 minutos, informes en `build/load_test/`; cambia la carpeta con
`--out`). Resultados y límite de jugadores por batalla en `docs/red.md` §14.

```bash
godot --headless --path . -s res://tools/load_test.gd -- --brawl
godot --headless --path . -s res://tools/load_test.gd -- --scenario=brawl --fakes=54 --bots=10
```

### Pasada de equilibrio del combate

`tools/combat_balance.gd` (CMB-29) monta un servidor sin red sobre `test_world`, lo avanza a mano tick a
tick y mide con él el DPS contra el maniquí, el tiempo de muerte (TTK) de un atacante perfecto, duelos
entre bots de combate y combates de 2 contra 2 y de 5 contra 5, en unos 20 s y con el mismo resultado
en cualquier máquina. Las cifras y las decisiones están en `docs/combate.md` §12.

```bash
godot --headless --path . -s res://tools/combat_balance.gd -- --duels=60 --seconds=30 --out=build/combat_balance.json
```


### Todo en uno: `--local`

```bash
godot --path . -- --local --realm=vardheim --name=Ana
```

`--local` no necesita un servidor arrancado: lee `user://dev_server.json` (`{pid, port}`, lo
escribe un servidor lanzado con `--dev-lock`) y, si ese proceso sigue vivo, se conecta a él. Si no,
lanza el servidor como proceso aparte (`--headless --server --port=24600 --idle-quit=30
--dev-lock`, con su registro en `user://logs/dev_server.log`) y reintenta conectar durante 10 s con
un tiempo de espera corto de ENet (1 s). Así varias ventanas lanzadas con `--local` comparten el
mismo servidor. El servidor se cierra solo tras 30 s sin jugadores, y el cliente nunca lo cierra:
si el cliente se cae, el servidor no queda huérfano. `--zone=<id>`, `--debug-commands`,
`--fake-players=N` y `--max-players=N` se reenvían al servidor que se lanza (si ya había uno en
marcha, se usa tal cual). `--port=<puerto>` elige el puerto del servidor que se lanza.

### Elegir reino (`RealmSelect`)

Un cliente con ventana que arranca sin `--realm` abre la pantalla de elección: tres botones
(Vardheim, Solmarch, Askarra; los que la zona no admite salen desactivados), los campos de
dirección del servidor (`host` o `host:puerto`; en `--local` no se edita) y de nombre del personaje,
y «Entrar». El nombre se valida con las reglas de nombres (de 3 a 16 letras, sin espacios ni
números, empezando por mayúscula) y el motivo se muestra junto al campo antes de conectar; mientras
algo no valga, «Entrar» queda desactivado. Tras un rechazo del servidor, un fallo de conexión o una
desconexión se vuelve a esta pantalla, con el motivo como aviso, y se puede reintentar sin cerrar el
juego.

### Depuración de red (F3 y F4)

En el cliente en red, **F3** muestra y oculta a la vez el panel de depuración del HUD (a la izquierda,
el mismo del sandbox) y el panel de red (a la derecha); los dos empiezan ocultos. El panel de red
enseña: RTT de ENet (sin el simulador de red) y en ticks, pérdida de ENet, KB/s de subida y de
bajada, `input_margin` (último y mínimo de la ventana de TickSync) y margen objetivo, ajustes de
TickSync, sustituciones y correcciones (con su tasa por minuto cuando hay 10 s de historia), última y
máxima corrección, ticks vueltos a simular, retardo de interpolación, jitter, entidades visibles y
bytes medios por snapshot. **F4** enciende un fantasma translúcido en la posición del último estado
propio que mandó el servidor y una marca en cada muestra, sin interpolar, de los jugadores remotos.
El sandbox sin argumentos no cambia: F3 sigue alternando solo su panel, que empieza visible.

## Estructura

```
assets/        Modelos, animaciones, texturas, materiales, audio y fuentes (binarios en Git LFS),
               más el tema de la interfaz (ui/) y los emblemas de bando (emblems/)
  LICENCIAS.md Procedencia y licencia de cada pack y addon de terceros
default_bus_layout.tres  Buses de audio (General con limitador, Música, Efectos, Ambiente, Interfaz, Voces)
scenes/        Escenas de Godot (.tscn)
  boot.tscn    Escena principal: lee las opciones de arranque
  characters/  Personajes (PlayerCharacter) y su aspecto visual (solo cliente)
  client/      Raíces del cliente (sandbox y red) y cámara de acción
  ui/          Interfaz (HUD, elección de reino, depuración de red)
  world/       Zonas (zones/) y sus piezas (props/), y el circuito de pruebas
scripts/
  client/      Solo cliente: cámara, input, interfaz (ui/), audio (audio/), visual y animación del personaje
  server/      Solo servidor: lógica autoritativa, IA, persistencia
  shared/      Compartido: datos, fórmulas, protocolo de red, simulación, registro de zonas
  world/       Nodos de las escenas de zona (ZoneRoot...), los cargan cliente y servidor
tests/         Pruebas automáticas (run_tests.gd y test_*.gd)
tools/         Scripts de generación (terreno, piezas, materiales, assets), de revisión, de
               comparación de registros de estado (compare_state_logs.gd) y de carga (load_test.gd)
docs/          Diseño y documentación técnica
addons/        Plugins de terceros (Terrain3D, ProtonScatter)
```

Cliente y servidor viven en el mismo proyecto. El servidor dedicado se ejecuta
con Godot en modo headless.

## Hoja de ruta

Tareas, dependencias y decisiones pendientes: [docs/backlog.md](docs/backlog.md).

1. Personaje y cámara: movimiento con WASD y cámara de acción por encima del hombro
2. Red: servidor dedicado, varios jugadores, predicción e interpolación, elección de reino
3. Combate de acción: ataques, bloqueo, esquiva, resistencia, compensación de latencia, muerte y reaparición
4. Primer fuerte capturable en un mapa de frontera pequeño
5. Cuentas, personajes y guardado en base de datos
6. Primer reino: ciudad capital, una zona PvE, muralla y puerta
7. Zona de guerra completa: varios fuertes y castillos, armas de asedio y recompensas
8. Los tres reinos completos y escalado a varios servidores
