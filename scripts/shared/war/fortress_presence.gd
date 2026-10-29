class_name FortressPresence
extends RefCounted
## Quién está dentro del círculo de captura de una fortaleza (docs/fuerte.md, sección 1.2): una
## función pura que recibe los candidatos y devuelve el recuento por reino, para que el servidor
## solo la llame cada 6 ticks con lo que sabe de sus jugadores.
## [br][br]
## Un jugador [b]está presente[/b] si:
## [br]- está vivo, no derribado y no desconectado (los cuerpos que se quedan 15 s tras la baja,
## GUE-41, no cuentan);
## [br]- ha enviado una entrada real en los últimos 60 s ([constant INPUT_TIMEOUT_TICKS]);
## [br]- tiene los pies en el cilindro del círculo: distancia horizontal al centro como mucho el
## radio y [code]feet.y[/code] en [code][centro.y − 1, centro.y + altura)[/code] (el marcador está
## a ras de suelo).
## [br]Los PNJ no cuentan: el servidor solo pasa jugadores, y un candidato de un bando que no es un
## reino se ignora.
## [br][br]
## Compartido: no depende del cliente ni del servidor.

## Ticks sin una entrada real tras los que un jugador deja de contar (60 s a 60 ticks por segundo).
const INPUT_TIMEOUT_TICKS: int = 3600
## Cuánto por debajo del centro del círculo (m) pueden estar los pies.
const FLOOR_MARGIN_M: float = 1.0


## Un jugador candidato a contar en el círculo.
class Candidate extends RefCounted:
	## Código de red del reino (1 a 3).
	var realm: int = 0
	## Posición de los pies.
	var feet: Vector3 = Vector3.ZERO
	var alive: bool = true
	var downed: bool = false
	## false para el cuerpo que queda en el mundo tras una baja o una desconexión.
	var connected: bool = true
	## Tick de su última entrada real (no sustituida ni repetida por el servidor).
	var last_input_tick: int = 0

	static func make(p_realm: int, p_feet: Vector3, p_last_input_tick: int) -> Candidate:
		var candidate := Candidate.new()
		candidate.realm = p_realm
		candidate.feet = p_feet
		candidate.last_input_tick = p_last_input_tick
		return candidate


## Número de jugadores presentes de cada reino (posiciones 0 a 3; la 0, los Huecos, siempre 0) en el
## círculo de [param center] y [param radius], tal como están en [param tick].
## [param def] pone la altura del cilindro ([member FortressDefinition.circle_height_m]).
static func count(def: FortressDefinition, center: Vector3, radius: float,
		candidates: Array[Candidate], tick: int) -> PackedInt32Array:
	var counts := PackedInt32Array([0, 0, 0, 0])
	for candidate: Candidate in candidates:
		if is_present(def, center, radius, candidate, tick):
			counts[candidate.realm] += 1
	return counts


## true si [param candidate] cuenta en el círculo (ver la descripción de la clase).
static func is_present(def: FortressDefinition, center: Vector3, radius: float,
		candidate: Candidate, tick: int) -> bool:
	if candidate == null or not RealmCatalog.is_realm_code(candidate.realm):
		return false
	if not candidate.alive or candidate.downed or not candidate.connected:
		return false
	if tick - candidate.last_input_tick >= INPUT_TIMEOUT_TICKS:
		return false
	return is_inside_cylinder(center, radius, def.circle_height_m, candidate.feet)


## true si los pies en [param feet] están dentro del cilindro de [param center], [param radius] y
## [param height] (la base queda [constant FLOOR_MARGIN_M] por debajo del centro; el borde del radio
## y de la base cuentan dentro, el techo no).
static func is_inside_cylinder(center: Vector3, radius: float, height: float, feet: Vector3) -> bool:
	var offset := Vector2(feet.x - center.x, feet.z - center.z)
	if offset.length_squared() > radius * radius:
		return false
	return feet.y >= center.y - FLOOR_MARGIN_M and feet.y < center.y + height
