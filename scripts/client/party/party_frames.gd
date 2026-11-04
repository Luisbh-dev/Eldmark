class_name PartyFrames
extends VBoxContainer
## Party frames (SOC-08, docs/social.md, sections 3 and 12.5): a column of [PartyFrame]s, one per
## member and in the order of the server's list (by seniority), with the crown on the leader's, health and
## stamina from the last PARTY_STATUS, and dimmed for one who is far away or dead. They are visible even if the member is
## outside the snapshots' interest radius, because the data comes from the party state at 2 Hz, not from the
## remotes being drawn.
## [br][br]
## There are only frames with a party; without one the column is hidden. It is redrawn when a roster or a status arrives
## ([signal PartyState.roster_changed], [signal PartyState.status_changed]) and, because of distance (the player
## moves and the members need not), every [constant REFRESH_SECONDS] s. The name color is that of the
## player's realm (a party belongs to a single realm).
## [br][br]
## Client only.

## Seconds between two distance-based redraws.
const REFRESH_SECONDS: float = 0.2

var _party: PartyState = null
var _client: NetClient = null
var _frames: Array[PartyFrame] = []
var _since_refresh: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_constant_override(&"separation", 4)
	_apply_visibility()


func _process(delta: float) -> void:
	advance(delta)


func _exit_tree() -> void:
	_disconnect()


## Connects the frames to the party state [param party] and the client [param client] (the local player, their
## position and their realm).
func bind(party: PartyState, client: NetClient) -> void:
	_disconnect()
	_party = party
	_client = client
	if _party != null:
		_party.roster_changed.connect(refresh)
		_party.status_changed.connect(refresh)
	refresh()


## Advances the clock of the distance-based redraws.
func advance(delta: float) -> void:
	_since_refresh += delta
	if _since_refresh >= REFRESH_SECONDS:
		refresh()


## Rebuilds the frames with what the party state knows.
func refresh() -> void:
	_since_refresh = 0.0
	var members: Array[PartyState.Member] = _party.get_members() if _party != null else []
	while _frames.size() < members.size():
		var frame := PartyFrame.new()
		frame.name = "Marco%d" % _frames.size()
		add_child(frame)
		_frames.append(frame)
	while _frames.size() > members.size():
		var extra: PartyFrame = _frames.pop_back()
		remove_child(extra)
		extra.queue_free()
	var own_id: int = _client.get_net_id() if is_instance_valid(_client) else 0
	var own_position: Variant = _own_position()
	var color: Color = _name_color()
	for i: int in members.size():
		var member: PartyState.Member = members[i]
		var distance: float = INF
		if own_position is Vector3 and member.has_status:
			distance = (own_position as Vector3).distance_to(member.position)
		_frames[i].configure(member, _party.is_leader(member.net_id), member.net_id == own_id, distance, color)
	_apply_visibility()


## How many frames there are.
func get_frame_count() -> int:
	return _frames.size()


## The frames, in order.
func get_frames() -> Array[PartyFrame]:
	return _frames.duplicate()


## The frame of member [param net_id], or null.
func get_frame(net_id: int) -> PartyFrame:
	for frame: PartyFrame in _frames:
		if frame.get_net_id() == net_id:
			return frame
	return null


func _apply_visibility() -> void:
	visible = not _frames.is_empty()


# Position of the local player (null if there is no character).
func _own_position() -> Variant:
	if not is_instance_valid(_client):
		return null
	var character: PlayerCharacter = _client.get_character()
	if character == null or not is_instance_valid(character) or not character.is_inside_tree():
		return null
	return character.global_position


# Name color: that of the local player's realm (white if unknown).
func _name_color() -> Color:
	if not is_instance_valid(_client) or _client.get_config() == null:
		return UIPalette.TEXT
	return UIPalette.faction_color_of_code(_client.get_config().realm).lightened(0.25)


func _disconnect() -> void:
	if _party != null:
		if _party.roster_changed.is_connected(refresh):
			_party.roster_changed.disconnect(refresh)
		if _party.status_changed.is_connected(refresh):
			_party.status_changed.disconnect(refresh)
