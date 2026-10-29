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

Las teclas de combate (clic izquierdo y derecho, Ctrl, 1-3, E) ya están asignadas, pero
todavía no hacen nada (fase 3).

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
  `test_world` es el guion fijo de la fase 1.
- `--shots=<carpeta absoluta>`: durante la demo guarda `shot_000.png`, `shot_001.png`...
  y, al terminar, una captura sin HUD desde cada cámara de revisión de la zona
  (`zona_<nombre>.png`, marcadores del grupo `screenshot_points`). Necesita ventana; en modo
  headless se omiten.
- `--quit-after-demo`: cierra el juego al terminar la demo.
- `--server`: servidor dedicado de una zona (ver «Servidor dedicado» más abajo).
- `--connect=<host>[:<puerto>]` y `--bot`: cliente en red (ver «Cliente en red» más abajo).

Las capturas y otros ficheros temporales pueden ir en `build/`, que Godot ignora.

### Integración continua

`.github/workflows/tests.yml` (GitHub Actions, `ubuntu-latest`) ejecuta la suite completa, red y
procesos incluidos, en cada push y en cada pull request: descarga Godot 4.7.2-stable para Linux
(con comprobación SHA-512 y en caché), baja los objetos de Git LFS (también en caché), importa el
proyecto y lanza `tests/run_tests.gd`, con un plazo de 20 minutos. Si falla, sube `build/` (logs e
informes) como artefacto `build-logs`. Para que una prueba rota bloquee el merge hay que marcar el
trabajo «Suite completa» como comprobación obligatoria en la protección de la rama. Se puede
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
`--fake-players=N` (jugadores sin red, para pruebas y carga), `--debug-commands` (admite el
teletransporte de depuración de los clientes), `--dev-lock` (escribe `user://dev_server.json`
para que `--local` reutilice el servidor), `--quit-after-ticks=N`, `--report=<ruta.json>`,
`--state-log=<ruta.csv>` (`tick,net_id,sustituida,estado` por tick y jugador) y
`--net-sim=rtt=120,jitter=20,loss=5,dup=0,seed=1`. El registro escribe las altas, las bajas, las
expulsiones y, cada 10 s, la duración del tick y el ancho de banda. El código de salida es 0 en un
cierre normal y 1 si no puede arrancar (zona desconocida, puerto ocupado).

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
`--connect`), `--realm=<reino>` (sin él entra como Vardheim, con un aviso: la pantalla de elección
de reino llega con TEC-45), `--name=<nombre>` (por defecto `Jugador-NNNN`), `--bot`,
`--bot-seed=N`, `--net-sim=rtt=120,jitter=20,loss=5,dup=0,seed=1`, `--quit-after-ticks=N` (ticks de
física locales desde que arranca la sesión, contando la conexión y la carga de la zona; los últimos
ticks el bot se queda quieto), `--report=<ruta.json>` (coincidencias exactas, diferencias
explicadas y sin explicar, reinicios y resincronizaciones, ajustes de TickSync y estado final) y
`--state-log=<ruta.csv>` (`server_tick,predicho,servidor` en hexadecimal por snapshot). Con
`--quit-after-ticks` el código de salida es 0 si el bot llegó a jugar y salió por su pie, y 1 si
fue rechazado, se desconectó o no llegó a entrar en la zona. `--local` y `--bots=N` todavía no
existen: avisan y cierran con código 1.

## Estructura

```
assets/        Modelos, animaciones, texturas, materiales y audio (binarios en Git LFS)
  LICENCIAS.md Procedencia y licencia de cada pack y addon de terceros
scenes/        Escenas de Godot (.tscn)
  boot.tscn    Escena principal: lee las opciones de arranque
  characters/  Personajes (PlayerCharacter) y su aspecto visual (solo cliente)
  client/      Raíces del cliente (sandbox y red) y cámara de acción
  ui/          Interfaz (HUD)
  world/       Zonas (zones/) y sus piezas (props/), y el circuito de pruebas
scripts/
  client/      Solo cliente: cámara, input, interfaz, visual y animación del personaje
  server/      Solo servidor: lógica autoritativa, IA, persistencia
  shared/      Compartido: datos, fórmulas, protocolo de red, simulación, registro de zonas
  world/       Nodos de las escenas de zona (ZoneRoot...), los cargan cliente y servidor
tests/         Pruebas automáticas (run_tests.gd y test_*.gd)
tools/         Scripts de generación (terreno, piezas, materiales, assets) y de revisión
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
