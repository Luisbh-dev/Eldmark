class_name StructureTarget
extends RefCounted
## Blanco estático de los golpes: la puerta de una fortaleza (docs/fuerte.md, sección 3.3). Lo crea
## el [FortressController] y lo recorre el [CombatResolver] después de los jugadores y PNJ de cada
## ataque activo: sin rebobinado (las puertas no se mueven), sin críticos y sin defensa. La forma es
## una caja orientada ([method HitShapes.sector_hits_box]).
## [br][br]
## Guarda el [FortressState] [b]vivo[/b] de la fortaleza (no una copia): la vida de la puerta y el
## dueño son los de ahora mismo.

## Id de red de la fortaleza (el del [code]net_id[/code] que lleva el HIT).
var net_id: int = 0
## Id de la fortaleza ([member FortressDefinition.id]).
var fortress_id: StringName = &""
## Estado vivo de la fortaleza.
var state: FortressState = null
## Centro de la caja de la puerta (transformación global) y sus medias dimensiones.
var box: Transform3D = Transform3D.IDENTITY
var half_extents: Vector3 = Vector3.ONE
## Cuerpos de física de la puerta, que la línea de visión del golpe no cuenta.
var exclude: Array[RID] = []


## true si un atacante del bando [param attacker_realm] puede dañar la puerta ahora: está entera y el
## atacante es un reino distinto del dueño (con el fuerte neutral, cualquiera de los tres). Los
## Huecos y los PNJ del propio dueño no la dañan.
func can_be_hit_by(attacker_realm: int) -> bool:
	if state == null or state.is_gate_broken():
		return false
	if not RealmCatalog.is_realm_code(attacker_realm):
		return false
	return attacker_realm != state.owner


## Punto de la caja más cercano a [param point] (en el mundo): hacia donde se lanza la línea de
## visión de un golpe. Si el punto está dentro de la caja, es él mismo.
func closest_point(point: Vector3) -> Vector3:
	var local: Vector3 = box.affine_inverse() * point
	var clamped := Vector3(clampf(local.x, -half_extents.x, half_extents.x),
			clampf(local.y, -half_extents.y, half_extents.y),
			clampf(local.z, -half_extents.z, half_extents.z))
	return box * clamped
