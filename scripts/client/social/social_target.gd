class_name SocialTarget
extends RefCounted
## Quién está bajo el punto de mira para las acciones sociales (SOC-07, docs/social.md, sección 12.6). Como no
## hay selección de objetivo, las acciones sociales (invitar, susurrar...) salen del jugador al que apunta la
## retícula: un rayo contra la cápsula de cada jugador remoto que se está dibujando, como el que usan las
## placas de nombre ([Nameplates]), hasta [constant MAX_RANGE] m del jugador local. Gana el más cercano a lo
## largo del rayo.
## [br][br]
## [b]Solo cuentan los aliados que se ven[/b] ([method is_social_target] y la oclusión de [method find]): un
## jugador del propio reino, vivo, con nombre de persona y sin una pared entre la cámara y su cabeza (la misma
## prueba que oculta su placa, [method Nameplates.is_head_hidden]). Un enemigo, un muerto o alguien tapado dan lo
## mismo que no apuntar a nadie: así pulsar la tecla contra una pared no dice si hay un enemigo detrás.
## [br][br]
## [b]Jugadores falsos.[/b] Los cuerpos de jugador que crea el servidor sin conexión (pruebas de carga y relleno
## de bandos, [code]ZoneServer.add_fake_player[/code]) no pueden recibir invitaciones ni susurros: el servidor
## contesta «no está conectado». No llevan ninguna marca en el ENTITY_SPAWN, pero su nombre («Bot-01», con
## guion y cifras) no cumple [NameRules], y el de una persona siempre la cumple porque [code]ServerAuth[/code]
## la exige en el HELLO; por eso un nombre que no la cumple no es objetivo.
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


## El aliado al que apunta el rayo [param aim] ([code]{"origin", "direction"}[/code], el de
## [method CameraRig.get_aim_ray], cuyo origen es la cámara) a [param max_range] m o menos de
## [param own_position], para quien es de [param own_realm]; null si no apunta a ninguno. Solo cuentan los que
## admiten acciones sociales ([method is_social_target]) y se están dibujando, y se descarta a quien tapa el
## mundo visto desde la cámara ([method Nameplates.is_head_hidden] en el espacio de física [param space]; con
## null no se comprueba, como en las placas fuera del árbol).
static func find(world: RemoteWorld, aim: Dictionary, own_position: Vector3, own_realm: int,
		space: PhysicsDirectSpaceState3D, max_range: float = MAX_RANGE) -> RemotePlayerView:
	if world == null or not is_instance_valid(world):
		return null
	var origin: Vector3 = aim["origin"]
	var direction: Vector3 = aim["direction"]
	# La cámara va detrás del jugador: el rayo se alarga lo que ella se aleja para que alcance a los 20 m del jugador.
	var reach: float = max_range + origin.distance_to(own_position)
	var best: RemotePlayerView = null
	var best_along: float = INF
	for view: RemotePlayerView in world.get_views():
		if not view.is_drawn() or not is_social_target(view, own_realm):
			continue
		var feet: Vector3 = view.get_drawn_position()
		if feet.distance_to(own_position) > max_range:
			continue
		if not HitShapes.segment_hits_capsule(origin, origin + direction * reach, feet,
				Nameplates.AIM_RADIUS, Nameplates.AIM_HEIGHT):
			continue
		var along: float = (feet - origin).dot(direction)
		if along >= best_along:
			continue
		if space != null and Nameplates.is_head_hidden(space, origin,
				feet + Vector3(0.0, Nameplates.HEAD_HEIGHT, 0.0)):
			continue
		best_along = along
		best = view
	return best


## true si [param view] admite acciones sociales de quien es de [param own_realm]: un jugador (no un PNJ) del
## mismo reino, vivo y con un nombre que cumple [NameRules] (no un jugador falso del servidor). No mira la
## distancia ni la oclusión ([method find] lo hace).
static func is_social_target(view: RemotePlayerView, own_realm: int) -> bool:
	if view == null or own_realm == NetProtocol.Realm.NONE:
		return false
	if view.get_kind() != NetProtocol.EntityKind.PLAYER or view.get_realm() != own_realm:
		return false
	if view.get_drawn_health_q() == EntityRecord.HEALTH_Q_DEAD:
		return false
	return NameRules.is_valid(view.get_display_name())


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
