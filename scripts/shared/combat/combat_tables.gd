class_name CombatTables
extends RefCounted
## Todo lo que [CombatCatalog] resuelve de un conjunto de recursos de combate: las reglas, los
## ataques, las armas, las habilidades, los efectos, los proyectiles y las plantillas ya convertidos
## a ticks, sus IDs, los problemas encontrados y la huella de la parte predicha.

## Reglas del combate (siempre hay unas: las de por defecto si faltan).
var rules: CombatRules = null
## Ticks de retardo de la regeneración de resistencia tras un gasto (de las reglas).
var regen_delay_ticks: int = 0
## Duraciones de las reglas en ticks (docs/habilidades.md, sección 2.1).
var swap_ticks: int = 0
var revive_ticks: int = 0
var execute_ticks: int = 0
var consumable_cooldown_ticks: int = 0
var downed_ticks: int = 0
## Ataques por ID: el ID [code]n[/code] está en el índice [code]n - 1[/code].
var attacks: Array[AttackTicks] = []
## Armas por ID (índice [code]id - 1[/code]).
var weapons: Array[WeaponTicks] = []
## Habilidades y consumibles por ID (índice [code]id - 1[/code]).
var abilities: Array[AbilityTicks] = []
## Efectos de estado por ID (índice [code]id - 1[/code]; caben en u8).
var statuses: Array[StatusTicks] = []
## Proyectiles por ID (índice [code]id - 1[/code]).
var projectiles: Array[ProjectileTicks] = []
## Plantillas de equipo por ID (índice [code]id - 1[/code]; caben en u8).
var templates: Array[EquipmentTemplate] = []
## Armas (IDs, en orden de ranura) y cargas empaquetadas ([member CombatState.consumable_charges])
## de cada plantilla, en el mismo índice que [member templates].
var template_weapon_ids: Array[PackedInt32Array] = []
var template_charges: PackedInt32Array = PackedInt32Array()
var attack_ids: Dictionary[StringName, int] = {}
var weapon_ids: Dictionary[StringName, int] = {}
var ability_ids: Dictionary[StringName, int] = {}
var status_ids: Dictionary[StringName, int] = {}
var projectile_ids: Dictionary[StringName, int] = {}
var template_ids: Dictionary[StringName, int] = {}
## IDs de las habilidades de [member CombatRules.consumables] en orden de botón (siempre 2 valores;
## 0 si no hay).
var consumable_ids: PackedInt32Array = PackedInt32Array([0, 0])
## ID de [member CombatRules.default_template] (0 si no hay).
var default_template_id: int = 0
## Problemas encontrados al cargar y validar (vacío si todo está bien).
var errors: PackedStringArray = PackedStringArray()
## Huella de la parte predicha (u32).
var prediction_hash: int = 0
## Contadores de consultas de [method weapon] y [method ability]: deterministas, solo para las
## pruebas que comprueban que el camino rápido de la simulación no busca nada en el catálogo.
var weapon_lookups: int = 0
var ability_lookups: int = 0


## El ataque con ese ID, o null si no existe.
func attack(id: int) -> AttackTicks:
	if id < 1 or id > attacks.size():
		return null
	return attacks[id - 1]


## El arma con ese ID, o null si no existe.
func weapon(id: int) -> WeaponTicks:
	weapon_lookups += 1
	if id < 1 or id > weapons.size():
		return null
	return weapons[id - 1]


## La habilidad (o el consumible) con ese ID, o null si no existe.
func ability(id: int) -> AbilityTicks:
	ability_lookups += 1
	if id < 1 or id > abilities.size():
		return null
	return abilities[id - 1]


## El efecto de estado con ese ID, o null si no existe.
func status(id: int) -> StatusTicks:
	if id < 1 or id > statuses.size():
		return null
	return statuses[id - 1]


## El proyectil con ese ID, o null si no existe.
func projectile(id: int) -> ProjectileTicks:
	if id < 1 or id > projectiles.size():
		return null
	return projectiles[id - 1]


## La plantilla con ese ID, o null si no existe.
func template(id: int) -> EquipmentTemplate:
	if id < 1 or id > templates.size():
		return null
	return templates[id - 1]


## IDs de las armas de la plantilla [param id] en orden de ranura (vacío si no existe).
func template_weapons(id: int) -> PackedInt32Array:
	if id < 1 or id > template_weapon_ids.size():
		return PackedInt32Array()
	return template_weapon_ids[id - 1]


## Cargas empaquetadas de la plantilla [param id] (0 si no existe).
func template_charges_of(id: int) -> int:
	if id < 1 or id > template_charges.size():
		return 0
	return template_charges[id - 1]


## true si no hubo ningún problema al cargar.
func is_valid() -> bool:
	return errors.is_empty()
