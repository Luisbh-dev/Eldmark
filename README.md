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

Abre `project.godot` desde Godot y pulsa F5. Arranca el sandbox de la fase 1: un
personaje de prueba en un circuito de movimiento con la cámara de acción.

Controles: WASD para moverse, Espacio para saltar, Mayús para esprintar, ratón para
mirar. Alt libera el cursor mientras se mantiene, Esc lo suelta hasta hacer clic,
V cambia de hombro, la rueda acerca o aleja la cámara y F3 muestra u oculta el panel
de depuración.

## Pruebas y demo

Desde la raíz del proyecto (`godot` es el ejecutable de consola de Godot 4.7):

```bash
# Importar recursos y validar el proyecto
godot --headless --path . --import

# Pruebas automáticas (código de salida 0 si todo pasa)
godot --headless --path . -s res://tests/run_tests.gd
# Solo las pruebas cuyo nombre contiene un texto
godot --headless --path . -s res://tests/run_tests.gd -- --filter=replay

# Demo guionizada (unos 10 s) con una captura PNG cada 90 ticks y salida al terminar
godot --path . -- --demo --shots=C:/ruta/absoluta/capturas --quit-after-demo
```

Opciones de arranque (van después de `--`):

- `--demo`: el personaje y la cámara siguen un guion fijo en lugar del teclado y el ratón.
- `--shots=<carpeta absoluta>`: durante la demo guarda `shot_000.png`, `shot_001.png`...
  (necesita ventana; en modo headless se omiten).
- `--quit-after-demo`: cierra el juego al terminar la demo.
- `--server`: servidor dedicado (pendiente, fase 2).

Las capturas y otros ficheros temporales pueden ir en `build/`, que Godot ignora.

## Estructura

```
assets/        Modelos, texturas, audio y fuentes (en Git LFS)
scenes/        Escenas de Godot (.tscn)
  boot.tscn    Escena principal: lee las opciones de arranque
  characters/  Personajes (PlayerCharacter)
  client/      Raíz del cliente y cámara de acción
  ui/          Interfaz (HUD)
  world/       Mapas y zonas
scripts/
  client/      Solo cliente: cámara, input, interfaz
  server/      Solo servidor: lógica autoritativa, IA, persistencia
  shared/      Compartido: datos, fórmulas, protocolo de red, simulación del movimiento
tests/         Pruebas automáticas (run_tests.gd y test_*.gd)
docs/          Diseño y documentación técnica
addons/        Plugins de terceros
```

Cliente y servidor viven en el mismo proyecto. El servidor dedicado se ejecuta
con Godot en modo headless.

## Hoja de ruta

1. Personaje y cámara: movimiento con WASD y cámara de acción por encima del hombro
2. Red: servidor dedicado, varios jugadores, predicción e interpolación, elección de reino
3. Combate de acción: ataques, bloqueo, esquiva, resistencia, compensación de latencia, muerte y reaparición
4. Primer fuerte capturable en un mapa de frontera pequeño
5. Cuentas, personajes y guardado en base de datos
6. Primer reino: ciudad capital, una zona PvE, muralla y puerta
7. Zona de guerra completa: varios fuertes y castillos, armas de asedio y recompensas
8. Los tres reinos completos y escalado a varios servidores
