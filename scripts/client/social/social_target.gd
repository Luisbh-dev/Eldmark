class_name SocialTarget
extends RefCounted
## Who is under the crosshair for social actions (SOC-07, docs/social.md, section 12.6). Since there is
## no target selection, social actions (invite, whisper...) apply to the player the reticle points at: a
## ray against the capsule of each remote player being drawn, like the one used by the nameplates
## ([Nameplates]), up to [constant MAX_RANGE] m from the local player. The closest along the ray wins.
## [br][br]
## [b]Only allies that can be seen count[/b] ([method is_social_target] and the occlusion in
## [method find]): a player of the same realm, alive, with a person's name and no wall between the camera
## and their head (the same test that hides their nameplate, [method Nameplates.is_head_hidden]). An
## enemy, a dead player or someone occluded is the same as aiming at nobody: this way, pressing the key
## against a wall does not reveal whether there is an enemy behind it.
## [br][br]
## [b]Fake players.[/b] Player bodies that the server creates without a connection (load tests and
## faction filling, [code]ZoneServer.add_fake_player[/code]) cannot receive invitations or whispers: the
## server replies "no está conectado" (not connected). They carry no mark in the ENTITY_SPAWN, but their
## name ("Bot-01", with a hyphen and digits) does not satisfy [NameRules], and a person's always does
## because [code]ServerAuth[/code] requires it in the HELLO; that is why a name that does not satisfy it
## is not a target.
## [br][br]
## The options each target offers come from [method options_for], a pure function: an ally offers
## invite (if not already in the party and the party is not full) and whisper; an enemy, none, because
## neither parties nor whispers cross the border between realms (docs/social.md, section 1) and the menu
## does not show what does not apply.
## [br][br]
## Client only.

## Maximum distance (m) from the local player to the target.
const MAX_RANGE: float = 20.0

const OPTION_INVITE: StringName = &"invite"
const OPTION_WHISPER: StringName = &"whisper"
const TEXT_INVITE: String = "Invitar al grupo"
const TEXT_WHISPER: String = "Susurrar"


## The ally pointed at by ray [param aim] ([code]{"origin", "direction"}[/code], that of
## [method CameraRig.get_aim_ray], whose origin is the camera) at [param max_range] m or less from
## [param own_position], for someone of [param own_realm]; null if it points at none. Only those that
## support social actions ([method is_social_target]) and are being drawn count, and anyone the world
## hides as seen from the camera is discarded ([method Nameplates.is_head_hidden] in the physics space
## [param space]; with null it is not checked, as with nameplates outside the tree).
static func find(world: RemoteWorld, aim: Dictionary, own_position: Vector3, own_realm: int,
		space: PhysicsDirectSpaceState3D, max_range: float = MAX_RANGE) -> RemotePlayerView:
	if world == null or not is_instance_valid(world):
		return null
	var origin: Vector3 = aim["origin"]
	var direction: Vector3 = aim["direction"]
	# The camera sits behind the player: the ray is lengthened by how far it is from them so that it reaches 20 m from the player.
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


## true if [param view] supports social actions from someone of [param own_realm]: a player (not an NPC)
## of the same realm, alive and with a name that satisfies [NameRules] (not a server fake player). It
## does not check distance or occlusion ([method find] does).
static func is_social_target(view: RemotePlayerView, own_realm: int) -> bool:
	if view == null or own_realm == NetProtocol.Realm.NONE:
		return false
	if view.get_kind() != NetProtocol.EntityKind.PLAYER or view.get_realm() != own_realm:
		return false
	if view.get_drawn_health_q() == EntityRecord.HEALTH_Q_DEAD:
		return false
	return NameRules.is_valid(view.get_display_name())


## The social actions offered by a player of realm [param target_realm] and id [param target_id] to
## someone of [param own_realm], with their [param party] (may be null). Each option is
## [code]{"id": StringName, "text": String}[/code] ([constant OPTION_INVITE], [constant OPTION_WHISPER]);
## empty if there is none (an enemy).
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
