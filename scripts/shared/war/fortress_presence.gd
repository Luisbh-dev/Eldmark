class_name FortressPresence
extends RefCounted
## Who is inside a fort's capture circle (docs/fuerte.md, section 1.2): a pure function that
## receives the candidates and returns the count per realm, so that the server only calls it every
## 6 ticks with what it knows about its players.
## [br][br]
## A player is [b]present[/b] if:
## [br]- they are alive, not knocked down and not disconnected (bodies that remain 15 s after a
## death, GUE-41, do not count);
## [br]- they have sent a real input in the last 60 s ([constant INPUT_TIMEOUT_TICKS]);
## [br]- their feet are in the circle's cylinder: horizontal distance to the center at most the
## radius and [code]feet.y[/code] in [code][center.y − 1, center.y + height)[/code] (the marker is
## at ground level).
## [br]NPCs do not count: the server only passes players, and a candidate of a side that is not a
## realm is ignored.
## [br][br]
## Shared: depends on neither the client nor the server.

## Ticks without a real input after which a player stops counting (60 s at 60 ticks per second).
const INPUT_TIMEOUT_TICKS: int = 3600
## How far below the circle's center (m) the feet may be.
const FLOOR_MARGIN_M: float = 1.0


## A player candidate to count in the circle.
class Candidate extends RefCounted:
	## Realm network code (1 to 3).
	var realm: int = 0
	## Position of the feet.
	var feet: Vector3 = Vector3.ZERO
	var alive: bool = true
	var downed: bool = false
	## false for the body that stays in the world after a death or a disconnection.
	var connected: bool = true
	## Tick of their last real input (not substituted or repeated by the server).
	var last_input_tick: int = 0

	static func make(p_realm: int, p_feet: Vector3, p_last_input_tick: int) -> Candidate:
		var candidate := Candidate.new()
		candidate.realm = p_realm
		candidate.feet = p_feet
		candidate.last_input_tick = p_last_input_tick
		return candidate


## Number of players present from each realm (positions 0 to 3; position 0, the Hollow, always 0)
## in the circle of [param center] and [param radius], as they are at [param tick].
## [param def] sets the cylinder's height ([member FortressDefinition.circle_height_m]).
static func count(def: FortressDefinition, center: Vector3, radius: float,
		candidates: Array[Candidate], tick: int) -> PackedInt32Array:
	var counts := PackedInt32Array([0, 0, 0, 0])
	for candidate: Candidate in candidates:
		if is_present(def, center, radius, candidate, tick):
			counts[candidate.realm] += 1
	return counts


## true if [param candidate] counts in the circle (see the class description).
static func is_present(def: FortressDefinition, center: Vector3, radius: float,
		candidate: Candidate, tick: int) -> bool:
	if candidate == null or not RealmCatalog.is_realm_code(candidate.realm):
		return false
	if not candidate.alive or candidate.downed or not candidate.connected:
		return false
	if tick - candidate.last_input_tick >= INPUT_TIMEOUT_TICKS:
		return false
	return is_inside_cylinder(center, radius, def.circle_height_m, candidate.feet)


## true if the feet at [param feet] are inside the cylinder of [param center], [param radius] and
## [param height] (the base is [constant FLOOR_MARGIN_M] below the center; the edge of the radius
## and of the base count as inside, the ceiling does not).
static func is_inside_cylinder(center: Vector3, radius: float, height: float, feet: Vector3) -> bool:
	var offset := Vector2(feet.x - center.x, feet.z - center.z)
	if offset.length_squared() > radius * radius:
		return false
	return feet.y >= center.y - FLOOR_MARGIN_M and feet.y < center.y + height
