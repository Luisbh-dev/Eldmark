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

Abre `project.godot` desde Godot y pulsa F5.

## Estructura

```
assets/        Modelos, texturas, audio y fuentes (en Git LFS)
scenes/        Escenas de Godot (.tscn)
  world/       Mapas y zonas
scripts/
  client/      Solo cliente: cámara, input, interfaz
  server/      Solo servidor: lógica autoritativa, IA, persistencia
  shared/      Compartido: datos, fórmulas, protocolo de red
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
