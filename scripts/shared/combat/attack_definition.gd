class_name AttackDefinition
extends Resource
## Un ataque cuerpo a cuerpo o un disparo (docs/combate.md, sección 2; docs/habilidades.md, sección
## 2.1). Todos los tiempos están en segundos y
## [CombatCatalog] los convierte a ticks con [code]roundi(s * 60)[/code] al cargar.
## [br][br]
## Las ventanas se cuentan desde el inicio de la acción ([code]action_tick[/code]): anticipación
## [code][0, windup)[/code], golpe activo y recuperación a continuación. En el ataque fuerte, la
## anticipación empieza al soltar la carga.

## Identificador único del ataque (el catálogo le asigna un ID u16 por orden alfabético).
@export var id: StringName
## true en el ataque fuerte (se carga manteniendo el botón).
@export var heavy: bool = false
## Anticipación (s); en el fuerte, tras soltar la carga.
@export var windup_s: float = 0.2
## Golpe activo (s): la forma se prueba en cada tick.
@export var active_s: float = 0.1
## Recuperación (s).
@export var recovery_s: float = 0.3
## Últimos segundos de la recuperación en los que una pulsación enlaza el siguiente ligero.
@export var combo_window_s: float = 0.0
## Instante (s desde el inicio de la acción) a partir del cual se puede cancelar a esquiva.
@export var cancel_to_dodge_from_s: float = 0.4
## Coste de resistencia (0-1000).
@export_range(0, 1000) var stamina_cost: int = 0
## Velocidad hacia delante (m/s) en anticipación y golpe activo.
@export var lunge_speed: float = 0.0
## Giro hacia la cámara (rad/s) en anticipación y golpe activo.
@export var turn_rate: float = 6.0
## Fracción de la velocidad de carrera permitida mientras dura el ataque.
@export var move_speed_scale: float = 0.3
## Forma del golpe (solo servidor). Con [member projectile] puede ser null: el ataque dispara en su
## primer tick activo.
@export var shape: HitShape
## Daño base (entero, solo servidor).
@export var base_damage: int = 0
## Tipo de daño (0 cortante, 1 perforante, 2 contundente, 3 elemental; solo servidor).
@export var damage_type: int = 0
## true: en el golpe activo es inmune a tambaleo y empuje (solo servidor).
@export var hyper_armor: bool = false
## true: el golpe no se puede bloquear ni parar (solo se evita esquivándolo): el bloqueo y la parada del
## defensor no lo detienen y recibe el daño completo (solo servidor; es el golpe del Capitán del Vado).
@export var unblockable: bool = false
## Tambaleo que causa (s; 0 = ninguno; solo servidor).
@export var stagger_s: float = 0.0
## Empuje que causa (m/s; 0 = ninguno; solo servidor).
@export var knockback_speed: float = 0.0
## Solo fuertes: carga mínima (s), contada desde la pulsación.
@export var charge_min_s: float = 0.0
## Solo fuertes: carga máxima (s), contada desde la pulsación.
@export var charge_max_s: float = 0.0
## Solo fuertes: multiplicador del daño a carga máxima (lineal desde x1 en la mínima; solo
## servidor).
@export var charge_damage_scale: float = 1.0
## Solo fuertes: fracción de la velocidad de carrera permitida mientras se carga.
@export var charge_move_scale: float = 0.4
## Solo fuertes: giro hacia la cámara (rad/s) mientras se carga.
@export var charge_turn_rate: float = 4.0
## Proyectil que sale en el primer tick activo (null = ninguno; docs/habilidades.md, sección 4.4).
@export var projectile: ProjectileDefinition
## Velocidad de salida del proyectil (m/s); en el fuerte, a carga mínima.
@export var projectile_speed_mps: float = 45.0
## Solo fuertes con proyectil: multiplicador de la velocidad de salida a carga máxima (lineal desde
## x1 en la mínima).
@export var charge_speed_scale: float = 1.0
## Aturdimiento que causa (s; 0 = ninguno; solo servidor).
@export var stun_s: float = 0.0
## Efecto a quien golpea (null = ninguno; solo servidor).
@export var on_hit_status: StatusEffectDefinition
