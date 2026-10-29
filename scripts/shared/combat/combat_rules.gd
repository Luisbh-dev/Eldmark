class_name CombatRules
extends Resource
## Reglas generales del combate (docs/combate.md, sección 2), en
## [code]data/combat/combat_rules.tres[/code].
## [br][br]
## Los campos «predichos» entran en [method CombatCatalog.prediction_hash] porque cambian lo que
## simulan cliente y servidor; el resto solo los lee el servidor.

# --- Predichas --------------------------------------------------------------------------------

## Resistencia máxima (0-65535: viaja en un u16).
@export var stamina_max: int = 1000
## Resistencia que se regenera cada tick (180/s con 3).
@export var stamina_regen_per_tick: int = 3
## Retardo (s) tras gastar resistencia antes de volver a regenerar.
@export var stamina_regen_delay_s: float = 0.6
## Regeneración por tick estando agotado.
@export var exhausted_regen_per_tick: int = 1
## Se sale del agotamiento al superar esta resistencia.
@export var exhausted_exit_threshold: int = 300
## Ticks de PRIMARY mantenido para pasar de ataque ligero a carga del fuerte.
@export var hold_to_heavy_ticks: int = 8
## Ticks que una pulsación sin ejecutar espera en el búfer (como mucho 15: ocupa 4 bits).
@export var input_buffer_ticks: int = 8
## Ticks de la ventana de parada al pulsar bloquear.
@export var parry_window_ticks: int = 6
## Ticks hasta que se puede abrir otra ventana de parada.
@export var parry_cooldown_ticks: int = 30

# --- Solo del servidor ------------------------------------------------------------------------

## Vida máxima.
@export var health_max: int = 1000
## Regeneración de vida por segundo fuera de combate.
@export var health_regen_per_s: int = 20
## Segundos «en combate» tras dar o recibir daño.
@export var in_combat_s: float = 10.0
## Segundos hasta poder reaparecer.
@export var respawn_s: float = 10.0
## Segundos de protección tras reaparecer.
@export var respawn_protection_s: float = 3.0
## Ventana (s) en la que se cuentan los controles encadenados.
@export var cc_chain_window_s: float = 3.0
## Inmunidad (s) a controles tras encadenar demasiados.
@export var cc_immunity_s: float = 2.0
## Velocidad de aterrizaje (m/s) a partir de la cual hay daño por caída.
@export var fall_damage_threshold: float = 15.0
## Daño por cada m/s por encima del umbral.
@export var fall_damage_per_mps: int = 70
## Tambaleo (s) que sufre el atacante al ser parado.
@export var parry_stagger_s: float = 0.6
## Aturdimiento (s) tras una rotura de guardia.
@export var guard_break_stun_s: float = 1.0
## Ángulo respecto al yaw de la víctima a partir del cual un golpe es por la espalda.
@export var backstab_angle_deg: float = 120.0
## Multiplicador del daño por la espalda.
@export var crit_multiplier: float = 1.5
## Multiplicadores del daño contra estructuras (la puerta de un fuerte, docs/fuerte.md, sección 3.3),
## por tipo de daño: cortante, perforante, contundente y elemental. Solo los usa el servidor.
@export var structure_slash_multiplier: float = 0.35
@export var structure_pierce_multiplier: float = 0.2
@export var structure_blunt_multiplier: float = 1.0
@export var structure_elemental_multiplier: float = 0.6


## Multiplicador del daño de tipo [param damage_type] ([enum DamageFormula.DamageType]) contra
## una estructura. 1 para un tipo desconocido.
func structure_multiplier(damage_type: int) -> float:
	match damage_type:
		DamageFormula.DamageType.SLASH:
			return structure_slash_multiplier
		DamageFormula.DamageType.PIERCE:
			return structure_pierce_multiplier
		DamageFormula.DamageType.BLUNT:
			return structure_blunt_multiplier
		DamageFormula.DamageType.ELEMENTAL:
			return structure_elemental_multiplier
	return 1.0
