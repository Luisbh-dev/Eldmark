class_name HitShape
extends Resource
## Forma de un golpe cuerpo a cuerpo: un sector anular con altura delante del atacante
## (docs/combate.md, sección 2). La geometría que la prueba contra una cápsula vive en
## [code]hit_shapes.gd[/code]; aquí solo están los datos.
## [br][br]
## Es un dato solo del servidor: no entra en [method CombatCatalog.prediction_hash].

## Alcance máximo desde el eje del atacante (m).
@export var range_m: float = 2.6
## Alcance mínimo (m); 0 = sector entero, sin hueco central.
@export var inner_m: float = 0.0
## Ángulo total del sector (grados), centrado en el yaw del atacante.
@export var angle_deg: float = 100.0
## Altura mínima del golpe sobre los pies del atacante (m).
@export var height_min: float = 0.2
## Altura máxima del golpe sobre los pies del atacante (m).
@export var height_max: float = 2.0
