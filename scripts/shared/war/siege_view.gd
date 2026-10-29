class_name SiegeView
extends RefCounted
## Lo que un bot necesita saber de un fuerte para asediarlo (docs/fuerte.md, sección 7): dueño, fase,
## captor, vida de la puerta y dónde están la puerta y el círculo. Puro y sin nodos, así lo
## comparten todos los bots:
## [br]- el servidor lo llena con el [FortressState] de la fortaleza para los jugadores falsos
## ([code]--fake-players[/code], [method update_from_state]);
## [br]- el cliente lo llena con lo que sabe de la fortaleza para [code]--bot[/code]: con
## [code]FortressView[/code] o, en los bots que no simulan ([code]SwarmBot[/code]), decodificando
## OBJECT_STATE a mano ([method update_from_fields] con los campos de [FortressFields]).
## [br][br]
## Mientras no se ha recibido ningún estado ([member known] es false), el fuerte se considera
## neutral, entero y sin captura, y las preguntas dan la respuesta de un fuerte sin dueño.
## [br][br]
## Compartido: no depende del cliente ni del servidor.

## Id de la fortaleza.
var fortress_id: StringName = &""
## true si se ha llenado con algún estado.
var known: bool = false
## Dueño (código de red; 0 = neutral).
var owner: int = 0
## Fase ([enum FortressState.Phase]).
var phase: int = FortressState.Phase.GARRISONED
## Reino que captura (0 si nadie).
var capture_realm: int = 0
## Vida actual y máxima de la puerta.
var gate_health: int = 0
var gate_max: int = 0
## true si la captura está disputada.
var contested: bool = false
## Dónde están la puerta (el centro del vano, a ras de suelo) y el círculo de captura (centro y radio).
var gate_position: Vector3 = Vector3.ZERO
var circle_center: Vector3 = Vector3.ZERO
var circle_radius: float = 0.0
## Tamaño del recinto medido desde la puerta (profundidad hacia el círculo, ancho), como
## [member ApproachRoutes.enclosure_size]; (0, 0) = no se sabe.
var enclosure_size: Vector2 = Vector2.ZERO


## Dónde están la puerta y el círculo (de los marcadores de la escena).
func set_places(p_gate_position: Vector3, p_circle_center: Vector3, p_circle_radius: float) -> void:
	gate_position = p_gate_position
	circle_center = p_circle_center
	circle_radius = p_circle_radius


## Dónde están la puerta y el círculo según las rutas de la zona ([member ApproachRoutes.gate_point]...), para
## los bots que no cargan la escena. Los puntos son horizontales: la altura se pone a [param ground_height].
## Devuelve false (y no cambia nada) si las rutas no lo saben.
func set_places_from_routes(routes: ApproachRoutes, ground_height: float = 0.0) -> bool:
	if routes == null or not routes.has_places():
		return false
	set_places(Vector3(routes.gate_point.x, ground_height, routes.gate_point.y),
			Vector3(routes.circle_point.x, ground_height, routes.circle_point.y), routes.circle_radius)
	enclosure_size = routes.enclosure_size
	return true


## Si [param position] está dentro del recinto (con [param margin] metros de holgura hacia dentro de cada pared):
## 1 sí, 0 no y -1 si no se sabe (sin [member enclosure_size] o sin posiciones de la puerta y el círculo). El recinto
## es el rectángulo que empieza en la pared de la puerta, se adentra hacia el círculo [code]enclosure_size.x[/code]
## metros y tiene [code]enclosure_size.y[/code] de ancho con la puerta en medio.
func is_inside_enclosure(position: Vector3, margin: float = 0.0) -> int:
	var inward := Vector3(circle_center.x - gate_position.x, 0.0, circle_center.z - gate_position.z)
	if enclosure_size.x <= 0.0 or enclosure_size.y <= 0.0 or inward.length_squared() < 0.0001:
		return -1
	inward = inward.normalized()
	var offset := Vector3(position.x - gate_position.x, 0.0, position.z - gate_position.z)
	var along: float = offset.dot(inward)
	var lateral: float = absf(offset.dot(Vector3(-inward.z, 0.0, inward.x)))
	var inside: bool = along > margin and along < enclosure_size.x - margin \
			and lateral < enclosure_size.y * 0.5 - margin
	return 1 if inside else 0


## Copia del estado de la fortaleza lo que le interesa a un bot.
func update_from_state(state: FortressState) -> void:
	known = true
	owner = state.owner
	phase = state.phase
	capture_realm = state.capture_realm
	gate_health = state.gate_health
	gate_max = state.gate_max
	contested = state.contested


## Aplica los campos de un OBJECT_STATE ([param fields]: id de [FortressFields] -> valor). Los
## campos que no le interesan, o desconocidos, se ignoran.
func update_from_fields(fields: Dictionary) -> void:
	known = true
	for field_id: int in fields:
		var value: int = int(fields[field_id])
		match field_id:
			FortressFields.OWNER:
				owner = value
			FortressFields.PHASE:
				phase = value
			FortressFields.CAPTURE_REALM:
				capture_realm = value
			FortressFields.GATE_HEALTH:
				gate_health = value
			FortressFields.GATE_MAX:
				gate_max = value
			FortressFields.CONTESTED:
				contested = value != 0


## true si la puerta está rota (vida 0 en una fortaleza conocida).
func is_gate_broken() -> bool:
	return known and gate_health <= 0


## Vida de la puerta de 0 a 1 (1 si aún no se sabe).
func gate_health_fraction() -> float:
	if not known or gate_max <= 0:
		return 1.0
	return clampf(float(gate_health) / float(gate_max), 0.0, 1.0)


## true si la puerta cierra el paso a [param realm]: entera y de otro dueño (con el fuerte neutral,
## a todos los reinos). Hay que romperla a golpes o esperar a que otro la rompa.
func is_gate_closed_for(realm: int) -> bool:
	return not is_gate_broken() and owner != realm


## true si [param realm] puede dañar la puerta: está entera y no es suya.
func can_damage_gate(realm: int) -> bool:
	return is_gate_closed_for(realm)


## true si el círculo de captura está activo (el capitán ha caído y el fuerte no está consolidándose).
func is_circle_active() -> bool:
	return phase == FortressState.Phase.VULNERABLE or phase == FortressState.Phase.CAPTURING


## true si [param realm] es el dueño: le toca defender la pasarela y el círculo.
func should_defend(realm: int) -> bool:
	return owner == realm and realm != RealmCatalog.NEUTRAL_CODE


## true si [param realm] es de los que asedian: el fuerte no es suyo.
func should_attack(realm: int) -> bool:
	return owner != realm


## true si [param realm] está capturando ahora mismo.
func is_capturing(realm: int) -> bool:
	return phase == FortressState.Phase.CAPTURING and capture_realm == realm


## true si [param position] está dentro del círculo en horizontal (la altura la comprueba el servidor).
func is_in_circle(position: Vector3) -> bool:
	var offset := Vector2(position.x - circle_center.x, position.z - circle_center.z)
	return offset.length() <= circle_radius
