class_name CombatTables
extends RefCounted
## Todo lo que [CombatCatalog] resuelve de un conjunto de recursos de combate: las reglas, los
## ataques y las armas ya convertidos a ticks, sus IDs, los problemas encontrados y la huella de
## la parte predicha.

## Reglas del combate (siempre hay unas: las de por defecto si faltan).
var rules: CombatRules = null
## Ticks de retardo de la regeneración de resistencia tras un gasto (de las reglas).
var regen_delay_ticks: int = 0
## Ataques por ID: el ID [code]n[/code] está en el índice [code]n - 1[/code].
var attacks: Array[AttackTicks] = []
## Armas por ID (índice [code]id - 1[/code]).
var weapons: Array[WeaponTicks] = []
var attack_ids: Dictionary[StringName, int] = {}
var weapon_ids: Dictionary[StringName, int] = {}
## Problemas encontrados al cargar y validar (vacío si todo está bien).
var errors: PackedStringArray = PackedStringArray()
## Huella de la parte predicha (u32).
var prediction_hash: int = 0


## El ataque con ese ID, o null si no existe.
func attack(id: int) -> AttackTicks:
	if id < 1 or id > attacks.size():
		return null
	return attacks[id - 1]


## El arma con ese ID, o null si no existe.
func weapon(id: int) -> WeaponTicks:
	if id < 1 or id > weapons.size():
		return null
	return weapons[id - 1]


## true si no hubo ningún problema al cargar.
func is_valid() -> bool:
	return errors.is_empty()
