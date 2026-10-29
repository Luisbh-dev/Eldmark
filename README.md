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
  límite de voces por categoría. Todavía no hay sonidos reales en `assets/audio/`.

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

Las capturas y otros ficheros temporales pueden ir en `build/`, que Godot ignora.

### Integración continua

`.github/workflows/tests.yml` (GitHub Actions, `ubuntu-latest`) ejecuta la suite completa, red y
procesos incluidos, en cada push y en cada pull request: descarga Godot 4.7.2-stable para Linux
(con comprobación SHA-512 y en caché), baja los objetos de Git LFS (también en caché), importa el
proyecto y lanza `tests/run_tests.gd` repartido en cuatro partes a la vez (`--shard=K/4`), cada una
con un plazo de 20 minutos. Si una falla, sube su `build/` (logs e informes) como artefacto
`build-logs-K`. El trabajo «Suite completa» solo pasa si pasan las cuatro: para que una prueba rota
bloquee el merge hay que marcarlo como comprobación obligatoria en la protección de la rama. Se puede
lanzar a mano desde la pestaña Actions (`workflow_dispatch`).

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

El servidor se defiende de los clientes (docs/red.md, sección 12): limita los paquetes por tick y
por segundo y los bytes de cada peer, cuenta un aviso por cada paquete mal formado, de un tipo
inesperado para el estado de la sesión o por encima del ritmo, y expulsa con un NOTICE al que
suma 50 avisos en 600 ticks; además admite como mucho `--max-per-ip` conexiones por IP (salvo
desde loopback).

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

### Enjambre de bots (`--bots=N`)

`--bots=N` lanza un proceso con N clientes ligeros (`BotSwarm`/`SwarmBot`) que no cargan la zona ni
simulan: entran uno cada 5 ticks, predicen con el `TickSync` de verdad, caminan guiados por su
`BotBrain` y confirman los snapshots. Sirven para cargar el servidor sin que el generador de carga
sea el cuello de botella:

```bash
godot --headless --path . -- --bots=32 --connect=127.0.0.1:24600 --realm=vardheim \
    --bot-seed=1000 --quit-after-ticks=3600 --report=build/enjambre.json
```

Cada bot se llama `Bot` más cuatro letras según `--bot-seed` más su índice, así que dos enjambres
contra el mismo servidor necesitan semillas distintas. Sin `--realm` se reparten entre Vardheim y
Solmarch. El informe trae los bytes de subida y de bajada de cada cliente, los snapshots recibidos
y su tamaño medio. Código de salida 0 si todos jugaban al terminar y 1 si alguno fue rechazado o se
cayó.

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
