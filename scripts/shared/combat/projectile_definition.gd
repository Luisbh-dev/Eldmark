class_name ProjectileDefinition
extends Resource
## La balística de un proyectil (docs/habilidades.md, sección 2.1). Entra entera en la huella de
## predicción: el cliente dibuja su flecha predicha y las ajenas con la misma
## [method Ballistics.position] que vuela el servidor. La velocidad de salida la pone quien dispara
## (el ataque o la habilidad).

## Identificador único (el catálogo le asigna un ID u16 por orden alfabético).
@export var id: StringName
## Gravedad (m/s², hacia abajo).
@export var gravity: float = 6.0
## Radio (m) que se suma al de la cápsula del blanco.
@export var radius_m: float = 0.05
## Vida (s) antes de caducar.
@export var lifetime_s: float = 2.0
