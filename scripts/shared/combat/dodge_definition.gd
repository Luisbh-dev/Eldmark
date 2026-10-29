class_name DodgeDefinition
extends Resource
## La esquiva de un arma (docs/combate.md, sección 2). Tiempos en segundos; el catálogo los
## convierte a ticks y hornea [member speed_curve] en una tabla de velocidades por tick.

## Duración total (s).
@export var duration_s: float = 0.45
## Inicio de la invulnerabilidad (s desde el inicio de la esquiva), inclusive.
@export var invulnerable_from_s: float = 0.05
## Fin de la invulnerabilidad (s), exclusivo.
@export var invulnerable_to_s: float = 0.3
## Distancia recorrida en suelo plano (m).
@export var distance_m: float = 4.5
## Forma del perfil de velocidad: x en [0, 1] (fracción de la duración), y velocidad relativa.
## Se normaliza para que la distancia total sea [member distance_m].
@export var speed_curve: Curve
## Coste de resistencia (0-1000).
@export_range(0, 1000) var stamina_cost: int = 300
## Instante (s desde el inicio de la esquiva) a partir del cual se puede cancelar a ataque.
@export var cancel_to_attack_from_s: float = 0.3
