class_name RespawnRules
extends RefCounted
## Dónde puede reaparecer un jugador (docs/fuerte.md, sección 5; amplía docs/combate.md, sección 5).
## Una función pura que el servidor usa para validar la elección y el cliente para ofrecer solo
## puntos válidos: los dos calculan lo mismo con la misma lista de marcadores.
## [br][br]
## El índice de un punto es su posición en la lista de [i]todos[/i] los marcadores del grupo
## [constant Zones.RESPAWN_GROUP] de la escena, en el orden de la escena (campamentos primero; el
## generador del Vado Gris lo mantiene estable), no en una lista filtrada por reino.
## [br][br]
## Un punto vale para un jugador de [param realm] si es:
## [br]- de su campamento: el marcador lleva el metadato [constant Zones.REALM_META] con su reino;
## [br]- del interior de una fortaleza (metadato [constant Zones.FORTRESS_META] con el id de la
## fortaleza) que es de su reino, está en GARRISONED y no está «atacada»
## ([code]tick ≥ under_attack_until_tick[/code]).
## [br]Los campamentos de otros reinos y las fortalezas ajenas, neutrales, en otra fase o atacadas no
## valen. Los marcadores sin ninguno de los dos metadatos no se ofrecen nunca.
## [br][br]
## Compartido: no depende del cliente ni del servidor.


## Índices (de [param points]) de los puntos en los que puede reaparecer un jugador del reino
## [param realm] (código de red) en el tick [param tick], en orden. [param fortresses] asocia el id
## de cada fortaleza (el metadato [code]fortress[/code] de sus marcadores, como [StringName] o
## [String]) con su [FortressState]; una fortaleza que falta aquí no vale.
static func points_for(realm: int, points: Array[Node3D], fortresses: Dictionary, tick: int) -> PackedInt32Array:
	var valid := PackedInt32Array()
	for index: int in points.size():
		if is_point_valid(realm, points[index], fortresses, tick):
			valid.append(index)
	return valid


## true si [param point] vale para el reino [param realm] en el tick [param tick] (ver la clase).
static func is_point_valid(realm: int, point: Node3D, fortresses: Dictionary, tick: int) -> bool:
	if point == null or not RealmCatalog.is_realm_code(realm):
		return false
	if point.has_meta(Zones.REALM_META):
		return RealmCatalog.code_of(Zones.get_spawn_realm(point)) == realm
	if not point.has_meta(Zones.FORTRESS_META):
		return false
	var fortress_id: StringName = StringName(point.get_meta(Zones.FORTRESS_META, &""))
	var state: FortressState = _state_of(fortresses, fortress_id)
	if state == null:
		return false
	return state.owner == realm and state.phase == FortressState.Phase.GARRISONED \
			and tick >= state.under_attack_until_tick


static func _state_of(fortresses: Dictionary, fortress_id: StringName) -> FortressState:
	var found: Variant = fortresses.get(fortress_id, fortresses.get(String(fortress_id), null))
	return found as FortressState
