class_name PartyFrames
extends VBoxContainer
## Marcos de grupo (SOC-08, docs/social.md, secciones 3 y 12.5): una columna de [PartyFrame], uno por
## miembro y en el orden de la lista del servidor (por antigüedad), con la corona en el del líder, la vida y
## la resistencia del último PARTY_STATUS, y atenuado el que está lejos o muerto. Se ven aunque el miembro esté
## fuera del radio de interés de los snapshots, porque los datos salen del estado de grupo a 2 Hz, no de los
## remotos que se dibujan.
## [br][br]
## Solo hay marcos con un grupo; sin él la columna se oculta. Se repinta cuando llega una lista o un estado
## ([signal PartyState.roster_changed], [signal PartyState.status_changed]) y, por la distancia (el jugador
## se mueve y los miembros no tienen por qué), cada [constant REFRESH_SECONDS] s. El color del nombre es el del
## reino del jugador (el grupo es de un solo reino).
## [br][br]
## Solo cliente.

## Segundos entre dos repintados por distancia.
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


## Conecta los marcos con el estado de grupo [param party] y el cliente [param client] (el jugador local, su
## posición y su reino).
func bind(party: PartyState, client: NetClient) -> void:
	_disconnect()
	_party = party
	_client = client
	if _party != null:
		_party.roster_changed.connect(refresh)
		_party.status_changed.connect(refresh)
	refresh()


## Avanza el reloj de los repintados por distancia.
func advance(delta: float) -> void:
	_since_refresh += delta
	if _since_refresh >= REFRESH_SECONDS:
		refresh()


## Rehace los marcos con lo que sabe el estado de grupo.
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


## Cuántos marcos hay.
func get_frame_count() -> int:
	return _frames.size()


## Los marcos, en orden.
func get_frames() -> Array[PartyFrame]:
	return _frames.duplicate()


## El marco del miembro [param net_id], o null.
func get_frame(net_id: int) -> PartyFrame:
	for frame: PartyFrame in _frames:
		if frame.get_net_id() == net_id:
			return frame
	return null


func _apply_visibility() -> void:
	visible = not _frames.is_empty()


# Posición del jugador local (null si no hay personaje).
func _own_position() -> Variant:
	if not is_instance_valid(_client):
		return null
	var character: PlayerCharacter = _client.get_character()
	if character == null or not is_instance_valid(character) or not character.is_inside_tree():
		return null
	return character.global_position


# Color del nombre: el del reino del jugador local (blanco si no se sabe).
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
