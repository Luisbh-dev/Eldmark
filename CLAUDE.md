# Eldmark

MMORPG 3D de fantasía medieval en Godot 4.7 (GDScript). Combate de acción en tercera persona estilo New World: cámara por encima del hombro, punto de mira, bloqueo y esquiva.

Tres reinos, cada uno con sus zonas, ciudades y una muralla que lo rodea, más una zona de guerra central con fuertes y castillos capturables. Diseño y hoja de ruta en `docs/vision.md`: léelo antes de tomar decisiones de diseño.

## Arquitectura

- Un solo proyecto de Godot para cliente y servidor. El servidor dedicado corre en modo headless.
- Mundo dividido en zonas independientes (cada zona, su mapa y su proceso de servidor), no un mundo continuo.
- Servidor autoritativo: el cliente envía intenciones (input, habilidades) y el servidor decide el resultado.
- Combate de acción en red: predicción en el cliente para el jugador local, interpolación para los demás y compensación de latencia (rebobinado de hitboxes) en el servidor para comprobar golpes.
- `scripts/shared/` no puede depender de nada de `scripts/client/` (cámara, UI, input) para que el servidor lo cargue sin problemas.
- `scripts/shared/` tampoco depende de `scripts/server/`, y `scripts/server/` y `scripts/client/` no dependen el uno del otro (lo comprueba `tests/test_architecture.gd`).

## Convenciones

- Sigue la guía de estilo oficial de GDScript: archivos y variables en `snake_case`, `class_name` en `PascalCase`, tabs.
- Tipado estático siempre (`var speed: float = 5.0`, `func move(dir: Vector3) -> void`).
- Identificadores en inglés; comentarios, documentación y textos de la interfaz en español.
- Escenas y recursos en formato texto (`.tscn`, `.tres`). Nada de `.scn`/`.res` binarios. Única excepción: los `.res` de regiones de Terrain3D, que van por Git LFS.
- Los binarios grandes (modelos, texturas, audio, DLL de GDExtension) van por Git LFS; ver `.gitattributes`.

## Assets

- Dirección artística: familia Quaternius "Universal + MegaKit" (estilizado con texturas, proporciones heroicas), un único kit recoloreado por reino. Detalle en `docs/arte.md`.
- Los zips originales se guardan fuera del repo, en `../Eldmark-raw/<pack>/`. Al repo solo pasan los glTF y texturas que se usan.
- Cada pack que entra en el repo se anota en `assets/LICENCIAS.md` (autor, versión, fecha, URL, licencia).
- Animaciones: variantes sin root motion. El movimiento lo decide la simulación compartida, no la animación. El servidor no reproduce animaciones.

## Ejecutar Godot desde la terminal

El alias `godot` de winget puede no estar en el PATH. El ejecutable de consola está en:

```
%LOCALAPPDATA%\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64_console.exe
```

- Importar recursos y validar el proyecto: `godot --headless --path . --import`
- Ejecutar la escena principal sin ventana: `godot --headless --path . --quit-after 120`
