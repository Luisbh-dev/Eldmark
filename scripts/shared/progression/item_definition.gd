class_name ItemDefinition
extends Resource
## Lo que un objeto es (docs/progresion.md §2.1, PRG-02): datos de diseño en
## [code]data/items/<categoría>/<id>.tres[/code], con un [member id] estable que la base de datos guarda.
## Lo que alguien posee es un [ItemInstance]; [ItemDatabase] las indexa y comprueba su coherencia.
## [br][br]
## No tiene ninguna propiedad de tipo [Texture2D], [PackedScene] ni [Mesh]: el icono y las escenas van
## como rutas de texto, que solo lee el cliente (el preset del servidor recorta [code]assets/[/code] y el
## servidor nunca debe intentar cargarlas). Compartido: sin reloj ni azar.

## Categorías (en la base de datos y en las reglas exportadas, este número).
enum Category { WEAPON = 1, ARMOR = 2, CONSUMABLE = 3, MATERIAL = 4, QUEST = 5, MISC = 6 }
## Ranura de equipo. [code]WEAPON[/code] vale para las dos ranuras de arma.
enum EquipSlot { NONE = 0, WEAPON = 1, HEAD = 2, CHEST = 3, HANDS = 4, LEGS = 5, FEET = 6 }
## Cuándo queda ligado al personaje.
enum BindRule { NONE = 0, ON_EQUIP = 1, ON_PICKUP = 2 }

## Formato del id: [code][a-z0-9_][/code], de 3 a 32 caracteres.
const ID_PATTERN: String = "^[a-z0-9_]{3,32}$"
## Tope de una pila.
const MAX_STACK: int = 999

## Identificador estable: nunca se reutiliza ni se renombra (la base de datos lo guarda).
@export var id: StringName
## Nombre en español (no vacío).
@export var display_name: String = ""
## Descripción en español.
@export_multiline var description: String = ""
@export var category: Category = Category.MISC
@export var equip_slot: EquipSlot = EquipSlot.NONE
## WEAPON: el [code]id[/code] del arma en [CombatCatalog]; CONSUMABLE: el del consumible
## ([code]potion_health[/code], [code]potion_stamina[/code]); ARMOR: la armadura de PRG-06 (sin contenido
## en la fase 5); el resto, vacío.
@export var ref_id: StringName
## 1 = no apilable; tope [constant MAX_STACK]. Los equipables y los que llevan durabilidad, 1.
@export_range(1, 999) var max_stack: int = 1
## Nivel para equiparlo o usarlo (1 al tope de [LevelCurve]).
@export_range(1, 40) var required_level: int = 1
## Valor en oro (≥ 0): la base de los precios de la fase 6.
@export var base_value: int = 0
@export var bind_rule: BindRule = BindRule.NONE
## false: el jugador no puede destruirlo.
@export var destroyable: bool = true
## La instancia lleva durabilidad (por mil, 0–1000).
@export var has_durability: bool = false
## Objeto de inicio (docs/progresion.md §2.5).
@export var starter: bool = false
## Total al que el campamento repone esta definición (§4.4); 0 = no se repone. Cabe en una pila.
@export_range(0, 999) var camp_refill: int = 0
## Icono ([code]res://assets/icons/items/…[/code]); solo cliente. Vacío: el casillero pinta el nombre
## corto con el color de la categoría.
@export var icon_path: String = ""
## Escena por cuerpo (PRG-05); solo cliente y solo armaduras. Vacío en la fase 5: las armas se ven por su
## id de [CombatCatalog].
@export var visual_paths: PackedStringArray = PackedStringArray()


## Se puede poner en el equipo.
func is_equipable() -> bool:
	return equip_slot != EquipSlot.NONE
