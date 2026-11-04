class_name RespawnPointList
extends RefCounted
## List of respawn points offered by the death screen and the map (docs/combate.md, section 5;
## docs/fortress.md, section 5; UI-14, UI-21).
## [br][br]
## [b]Valid options (phase 4).[/b] A point's index is its position in the list of [i]all[/i] the markers
## of the zone's respawn group, in scene order, and it is the one that travels in the RESPAWN_REQUEST.
## The client computes which points are valid with the same rule as the server
## ([method RespawnRules.points_for]: the realm's camp, or the interior of an owned fort that is idle
## and not under attack) and [method options] groups them for the player: contiguous markers at the same
## place (the four points of a camp, those of a fort's courtyard) are [b]a single option[/b], whose index
## is spread among its points according to the player ([method Option.index_for]) so that they do not all
## respawn on top of one another. If the zone has no respawn markers, the realm's spawn markers are used,
## as the server does.
## [br][br]
## [b]Old list.[/b] [method list] and [method labels] still give the realm-filtered list from phase 3
## (used by the server until it adopts [RespawnRules] and by zones without fortresses).

## Group of a zone's respawn points (optional: without it, the spawn points are used).
const GROUP: StringName = NetZones.RESPAWN_GROUP
## Metadata with a point's realm.
const REALM_META: StringName = &"realm"
## Optional metadata with the name shown in the list.
const TITLE_META: StringName = &"title"
## Metadata with the id of the fortress of a point inside a fort.
const FORTRESS_META: StringName = &"fortress"
## Maximum meters between two points for them to count as the same place.
const SAME_PLACE_METERS: float = 20.0
const TEXT_CAMP: String = "Campamento de %s"
const TEXT_FORTRESS: String = "%s"


## A place where one can respawn: one or several contiguous markers.
class Option extends RefCounted:
	## Indices (in the list of all the zone's markers) of its markers, in order.
	var members: PackedInt32Array = PackedInt32Array()
	var label: String = ""
	## Center of its markers.
	var position: Vector3 = Vector3.ZERO
	## true if the player can respawn here now.
	var valid: bool = false
	## Realm of the camp (network code) or 0; and the fortress if it is the interior of a fort.
	var realm: int = 0
	var fortress_id: StringName = &""


	## Index sent to the server: one of [member members], spread according to [param seed] (the player's
	## network id) so that those who respawn together do not stack up.
	func index_for(spread_seed: int) -> int:
		if members.is_empty():
			return 0
		return members[posmod(spread_seed, members.size())]


	## true if marker [param point_index] is one of this option's.
	func has_member(point_index: int) -> bool:
		return members.has(point_index)


## Points of realm [param realm_code] (an [enum NetProtocol.Realm]) in [param world] (in the tree).
## It is exactly the server's list ([method NetZones.get_respawn_points]), so that the index in the
## RESPAWN_REQUEST means the same on both sides. If empty, the server uses its realm spawn point, and the
## screen offers a single option.
static func list(world: Node, realm_code: int) -> Array[Node3D]:
	if world == null or not world.is_inside_tree():
		var empty: Array[Node3D] = []
		return empty
	return NetZones.get_respawn_points(world, realm_code)


## Name of [param point] for the list: its [constant TITLE_META] metadata or, if it has none, the node's
## name with underscores as spaces (and the capital letters of "CampamentoVardheim" separated).
static func label_of(point: Node) -> String:
	var title: String = String(point.get_meta(TITLE_META, ""))
	if not title.is_empty():
		return title
	return _label_from_name(String(point.name))


## Names of [param points], in the same order.
static func labels(points: Array[Node3D]) -> PackedStringArray:
	var result := PackedStringArray()
	for point: Node3D in points:
		result.append(label_of(point))
	return result


## All the respawn markers of [param world] (in the tree), in scene order: each one's index is its
## respawn index.
static func all_points(world: Node) -> Array[Node3D]:
	var points: Array[Node3D] = []
	if world == null or not world.is_inside_tree():
		return points
	for node: Node in world.get_tree().get_nodes_in_group(GROUP):
		var point: Node3D = node as Node3D
		if point != null and (point == world or world.is_ancestor_of(point)):
			points.append(point)
	return points


## Respawn options of realm [param realm_code] at server tick [param tick], valid or not (the map shows
## the invalid ones greyed out), in scene order. [param fortresses] maps each fortress's id to its
## [FortressState] ([method FortressView.get_states_by_definition]) and [param fortress_names] its
## interface name (empty = the node's). Without respawn markers the realm's spawn markers are offered, all
## valid.
static func options(world: Node, realm_code: int, fortresses: Dictionary, tick: int,
		fortress_names: Dictionary = {}) -> Array[Option]:
	var result: Array[Option] = []
	var points: Array[Node3D] = all_points(world)
	if points.is_empty():
		# No group of its own: the realm's spawn points, one index each, all valid.
		var fallback: Array[Node3D] = list(world, realm_code)
		for index: int in fallback.size():
			var option := Option.new()
			option.members = PackedInt32Array([index])
			option.label = label_of(fallback[index])
			option.position = _position_of(fallback[index])
			option.valid = true
			option.realm = realm_code
			result.append(option)
		return result
	var valid: PackedInt32Array = RespawnRules.points_for(realm_code, points, fortresses, tick)
	var keys: Array[String] = []
	for index: int in points.size():
		var point: Node3D = points[index]
		var position: Vector3 = _position_of(point)
		var key: String = _group_key(point)
		var found: int = -1
		for i: int in result.size():
			if keys[i] == key and result[i].position.distance_to(position) <= SAME_PLACE_METERS:
				found = i
				break
		if found < 0:
			var option := Option.new()
			option.position = position
			option.label = _option_label(point, fortress_names)
			option.realm = RealmCatalog.code_of(StringName(point.get_meta(REALM_META, &"")))
			option.fortress_id = StringName(point.get_meta(FORTRESS_META, &""))
			result.append(option)
			keys.append(key)
			found = result.size() - 1
		var member_count: int = result[found].members.size()
		result[found].position = (result[found].position * float(member_count) + position) / float(member_count + 1) \
				if member_count > 0 else position
		result[found].members.append(index)
		result[found].valid = result[found].valid or valid.has(index)
	return result


## Only the valid options from [method options].
static func valid_options(world: Node, realm_code: int, fortresses: Dictionary, tick: int,
		fortress_names: Dictionary = {}) -> Array[Option]:
	var found: Array[Option] = []
	for option: Option in options(world, realm_code, fortresses, tick, fortress_names):
		if option.valid:
			found.append(option)
	return found


## Names of [param options_list] for the death screen's list, in the same order.
static func option_labels(options_list: Array[Option]) -> PackedStringArray:
	var result := PackedStringArray()
	for option: Option in options_list:
		result.append(option.label)
	return result


## Indices sent to the server for each option in [param options_list], for network player
## [param spread_seed].
static func option_indices(options_list: Array[Option], spread_seed: int) -> PackedInt32Array:
	var result := PackedInt32Array()
	for option: Option in options_list:
		result.append(option.index_for(spread_seed))
	return result


static func _position_of(point: Node3D) -> Vector3:
	return point.global_position if point.is_inside_tree() else point.position


# Contiguous markers at the same place: same realm or fortress and same name without the trailing number.
static func _group_key(point: Node3D) -> String:
	var stem: String = String(point.name).rstrip("0123456789 _")
	return "%s|%s|%s" % [String(point.get_meta(REALM_META, &"")), String(point.get_meta(FORTRESS_META, &"")), stem]


static func _option_label(point: Node3D, fortress_names: Dictionary) -> String:
	var title: String = String(point.get_meta(TITLE_META, ""))
	if not title.is_empty():
		return title
	var fortress_id: StringName = StringName(point.get_meta(FORTRESS_META, &""))
	if fortress_id != &"" and fortress_names.has(fortress_id):
		return String(fortress_names[fortress_id])
	var realm_id: StringName = StringName(point.get_meta(REALM_META, &""))
	var stem: String = String(point.name).rstrip("0123456789 _")
	if realm_id != &"" and fortress_id == &"" and stem.to_lower().begins_with("campamento") \
			and RealmCatalog.has_faction(realm_id):
		return TEXT_CAMP % RealmCatalog.display_name(realm_id)
	return _label_from_name(stem if not stem.is_empty() else String(point.name))


# "Campamento_Norte" -> "Campamento Norte"; "FuerteVadoGris" -> "Fuerte Vado Gris".
static func _label_from_name(node_name: String) -> String:
	if node_name.contains("_"):
		return node_name.replace("_", " ")
	return node_name.capitalize()
