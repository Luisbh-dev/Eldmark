class_name EquipmentTemplate
extends Resource
## Una plantilla de equipo (PRG-07; docs/habilidades.md, sección 2.1): las armas y las cargas de los
## consumibles con las que aparece un personaje. La impone el servidor al aparecer, así que no entra
## en la huella de predicción.

## Identificador único (el catálogo le asigna un ID u8 por orden alfabético).
@export var id: StringName
## false: solo para pruebas y PNJ (un jugador no la puede elegir).
@export var selectable: bool = true
## Una o dos armas, en orden de ranura (la primera es la activa al aparecer).
@export var weapons: Array[WeaponDefinition] = []
## Cargas de cada consumible de [member CombatRules.consumables] (dos valores, 0-15 cada uno).
@export var consumable_charges: PackedInt32Array = PackedInt32Array([3, 2])
