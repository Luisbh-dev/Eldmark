class_name WeaponDefinition
extends Resource
## Un arma equipable (docs/combate.md, sección 2): sus ataques, su bloqueo, su esquiva y sus
## habilidades (docs/habilidades.md, sección 2.1).

## Identificador único del arma (el catálogo le asigna un ID u16 por orden alfabético).
@export var id: StringName
## Combo de golpes ligeros, en orden (de 1 a 3 golpes).
@export var light_combo: Array[AttackDefinition] = []
## Golpe fuerte (se carga manteniendo el botón de ataque).
@export var heavy_attack: AttackDefinition
## Cono frontal total del bloqueo (grados; solo servidor).
@export var block_angle_deg: float = 120.0
## Fracción del daño físico frontal que para el bloqueo (1,0 = todo; solo servidor).
@export var block_mitigation: float = 1.0
## Fracción de la velocidad de carrera permitida al bloquear.
@export var block_move_scale: float = 0.5
## Giro hacia la cámara (rad/s) al bloquear.
@export var block_turn_rate: float = 8.0
## Resistencia que cuesta cada punto de daño absorbido (solo servidor).
@export var block_stamina_per_damage: float = 1.0
## Esquiva del arma.
@export var dodge: DodgeDefinition
## Habilidades (0-3); la posición es la ranura (ABILITY_1-3).
@export var abilities: Array[AbilityDefinition] = []
## false: el arma no bloquea (el arco); BLOCK no hace nada.
@export var can_block: bool = true
