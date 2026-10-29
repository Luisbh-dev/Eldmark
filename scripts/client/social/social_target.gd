class_name SocialTarget
extends RefCounted
## Quién está bajo el punto de mira para las acciones sociales (SOC-07, docs/social.md, sección 12.6). Como no
## hay selección de objetivo, las acciones sociales (invitar, susurrar...) salen del jugador al que apunta la
## retícula: un rayo contra la cápsula de cada jugador remoto que se está dibujando, como el que usan las
## placas de nombre ([Nameplates]), hasta [constant MAX_RANGE] m del jugador local. Gana el más cercano a lo
## largo del rayo.
## [br][br]
## Las opciones que ofrece cada objetivo salen de [method options_for], una función pura: un aliado ofrece
## invitar (si no está ya en el grupo y el grupo no está completo) y susurrar; un enemigo, ninguna, porque
## ni los grupos ni los susurros cruzan la frontera entre reinos (docs/social.md, sección 1) y el menú no
## enseña lo que no aplica.
## [br][br]
## Solo cliente.

## Distancia máxima (m) del jugador local al objetivo.
const MAX_RANGE: float = 20.0

const OPTION_INVITE: StringName = &"invite"
const OPTION_WHISPER: StringName = &"whisper"
const TEXT_INVITE: String = "Invitar al grupo"
const TEXT_WHISPER: String = "Susurrar"


## El jugador remoto al que apunta el rayo [param aim] ([code]{"origin", "direction"}[/code], el de
## [method CameraRig.get_aim_ray]) a [param max_range] m o menos de [param own_position]; null si no apunta
## a ninguno. Solo cuentan los jugadores (no los PNJ) que se están dibujando.
static func find(world: RemoteWorld, aim: Dictionary, own_position: Vector3,
		max_range: float = MAX_RANGE) -> RemotePlayerView:
	if world == null or not is_instance_valid(world):
		return null
	var origin: Vector3 = aim["origin"]
	var direction: Vector3 = aim["direction"]
	# La cámara va detrás del jugador: el rayo se alarga lo que ella se aleja para que alcance a los 20 m del jugador.
	var reach: float = max_range + origin.distance_to(own_position)
	var best: RemotePlayerView = null
	var best_along: float = INF
	for view: RemotePlayerView in world.get_views():
		if not view.is_drawn() or view.get_kind() != NetProtocol.EntityKind.PLAYER:
			continue
		var feet: Vector3 = view.get_drawn_position()
		if feet.distance_to(own_position) > max_range:
			continue
		if not HitShapes.segment_hits_capsule(origin, origin + direction * reach, feet,
				Nameplates.AIM_RADIUS, Nameplates.AIM_HEIGHT):
			continue
		var along: float = (feet - origin).dot(direction)
		if along < best_along:
			best_along = along
			best = view
	return best


## Las acciones sociales que ofrece un jugador de reino [param target_realm] y id [param target_id] a quien es de
## [param own_realm], con su [param party] (puede ser null). Cada opción es [code]{"id": StringName, "text":
## String}[/code] ([constant OPTION_INVITE], [constant OPTION_WHISPER]); vacío si no hay ninguna (un enemigo).
static func options_for(own_realm: int, target_realm: int, target_id: int, party: PartyState) -> Array[Dictionary]:
	var options: Array[Dictionary] = []
	if own_realm == NetProtocol.Realm.NONE or target_realm != own_realm:
		return options
	var can_invite: bool = true
	if party != null and party.is_in_party():
		can_invite = not party.has_member(target_id) and party.get_member_count() < NetProtocol.PARTY_MAX_SIZE
	if can_invite:
		options.append({"id": OPTION_INVITE, "text": TEXT_INVITE})
	options.append({"id": OPTION_WHISPER, "text": TEXT_WHISPER})
	return options
