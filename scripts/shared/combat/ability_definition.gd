class_name AbilityDefinition
extends Resource
## Una habilidad de arma o un consumible (docs/habilidades.md, sección 2.1). Todos los tiempos están
## en segundos desde el inicio de la acción y [CombatCatalog] los convierte a ticks con
## [code]roundi(s * 60)[/code] al cargar.
## [br][br]
## Fases: lanzamiento [code][0, cast)[/code], activo [code][cast, cast + active)[/code] y
## recuperación hasta el total. En una canalización, el activo es su tope y no hay recuperación. La
## reutilización empieza en el compromiso (el primer tick activo); la de una canalización, al acabar.
## [br][br]
## Los campos «predichos» entran en [method CombatCatalog.prediction_hash]; los de «solo servidor»
## los usa el resolutor (con ellos el catálogo sintetiza un [AttackTicks], el golpe de la habilidad).

## Identificador único (el catálogo le asigna un ID u16 por orden alfabético).
@export var id: StringName

# --- Predichos --------------------------------------------------------------------------------

## Lanzamiento (s).
@export var cast_s: float = 0.0
## Activo (s); en una canalización, su tope.
@export var active_s: float = 0.1
## Recuperación (s); 0 en las canalizaciones.
@export var recovery_s: float = 0.3
## Reutilización (s); 0 en los consumibles (usan la compartida de [CombatRules]).
@export var cooldown_s: float = 10.0
## true: el activo es una canalización.
@export var channel: bool = false
## Canalización: soltar el botón de su ranura la acaba.
@export var channel_hold: bool = true
## Canalización: moverse la acaba.
@export var channel_breaks_on_move: bool = false
## Instante (s desde el inicio) a partir del cual se puede cancelar a esquiva; -1 = desde la
## recuperación.
@export var cancel_to_dodge_from_s: float = -1.0
## Instante (s desde el inicio) a partir del cual se puede cancelar a ataque; -1 = desde la
## recuperación.
@export var cancel_to_attack_from_s: float = -1.0
## Fracción de la velocidad de carrera permitida.
@export var move_speed_scale: float = 0.3
## Giro hacia la cámara (rad/s) en lanzamiento, activo y canalización.
@export var turn_rate: float = 6.0
## Velocidad hacia delante (m/s) en lanzamiento y activo.
@export var lunge_speed: float = 0.0
## Avance impuesto (m; 0 = ninguno), horneado como la esquiva.
@export var dash_distance_m: float = 0.0
## Ventana del avance [desde, hasta) en s desde el inicio de la acción.
@export var dash_from_s: float = 0.0
@export var dash_to_s: float = 0.0
## Forma del perfil de velocidad del avance (null = plana); se normaliza a [member dash_distance_m].
@export var dash_curve: Curve
## Dirección del avance: 0 hacia look_yaw, 1 hacia atrás, 2 según el movimiento (como la esquiva).
@export var dash_direction: int = 0
## Se puede usar en el aire.
@export var usable_in_air: bool = false
## Resistencia que devuelve al comprometer (poción de resistencia).
@export var stamina_restore: int = 0
## La canalización bloquea (muro de escudos).
@export var blocks: bool = false
## Proyectil que sale en el compromiso (null = ninguno).
@export var projectile: ProjectileDefinition
## Proyectiles por disparo (1-5) y ángulo entre ellos (grados).
@export var projectile_count: int = 1
@export var projectile_spread_deg: float = 0.0
## Velocidad de salida del proyectil (m/s).
@export var projectile_speed_mps: float = 45.0

# --- Solo servidor ----------------------------------------------------------------------------

## Forma del golpe en cada tick activo (null = sin golpe).
@export var shape: HitShape
@export var base_damage: int = 0
## Tipo de daño ([enum DamageFormula.DamageType]).
@export var damage_type: int = 0
@export var stagger_s: float = 0.0
@export var stun_s: float = 0.0
@export var knockback_speed: float = 0.0
@export var hyper_armor: bool = false
@export var unblockable: bool = false
## Efecto a quien golpea (también con su proyectil).
@export var target_status: StatusEffectDefinition
## Efecto y curación propios, al comprometer.
@export var self_status: StatusEffectDefinition
@export var self_heal: int = 0
## Un golpe recibido en el lanzamiento la interrumpe (siempre true en los consumibles).
@export var interrupt_on_damage: bool = false
## Caja que para proyectiles mientras dura la canalización (semiejes en m; cero = ninguna).
@export var wall_half_extents: Vector3 = Vector3.ZERO
## Distancia (m) del centro de la caja delante de los pies.
@export var wall_forward_m: float = 0.7
