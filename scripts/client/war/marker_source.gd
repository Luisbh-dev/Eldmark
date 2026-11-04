class_name MarkerSource
extends RefCounted
## Where a zone's [WorldMarker]s come from (UI-19, docs/fuerte.md section 6): the fixed places of the baked
## map ([ZoneMapDefinition]: camps and passes) and what the client knows about each fortress
## ([FortressView]: the fort, its gate and its circle with the owner's or the capturer's color). Pure: it
## neither draws nor reads the scene, it only gathers data.
## [br][br]
## [b]Colors.[/b] A realm's places carry its faction color; the fort, its owner's (the Hollow's if it is
## neutral); the gate, the owner's; the circle, the capturer's while being captured and the interface's
## white while active with no capturer. The circle is only a marker while active (the captain has fallen
## or a capture is in progress).

const CIRCLE_COLOR: Color = Color(1.0, 0.95, 0.8, 1.0)
const TEXT_GATE: String = "Puerta"
const TEXT_CIRCLE: String = "Círculo de captura"


## The zone's markers. [param map] may be null (a zone with no baked map) and so may [param view] (no client
## yet): whatever is available is used.
static func build(map: ZoneMapDefinition, view: FortressView) -> Array[WorldMarker]:
	var markers: Array[WorldMarker] = []
	var fort_ids: Array[int] = []
	if view != null:
		fort_ids = view.get_fortress_ids()
	var seen_forts: Dictionary[StringName, bool] = {}
	for net_id: int in fort_ids:
		_add_fortress(markers, view, net_id)
		seen_forts[StringName(view.get_definition_id(net_id))] = true
	if map != null:
		for landmark: MapLandmark in map.landmarks:
			match landmark.kind:
				MapLandmark.KIND_FORT:
					# The map's one only applies while the client does not know the fortress (no owner or state).
					if not seen_forts.has(landmark.fortress_id):
						markers.append(WorldMarker.make(StringName("fort_%s" % landmark.fortress_id),
								WorldMarker.Kind.FORT, landmark.label, landmark.position,
								UIPalette.faction_color_of_code(RealmCatalog.NEUTRAL_CODE)))
				MapLandmark.KIND_CAMP:
					markers.append(WorldMarker.make(StringName("camp_%d" % landmark.realm),
							WorldMarker.Kind.CAMP, landmark.label, landmark.position,
							UIPalette.faction_color_of_code(landmark.realm), landmark.realm))
				MapLandmark.KIND_PASS:
					markers.append(WorldMarker.make(StringName("pass_%s" % landmark.label.to_snake_case()),
							WorldMarker.Kind.PASS, landmark.label, landmark.position,
							UIPalette.faction_color_of_code(landmark.realm), landmark.realm))
	return markers


## Marker from [param markers] whose id is [param id], or null.
static func find(markers: Array[WorldMarker], id: StringName) -> WorldMarker:
	for marker: WorldMarker in markers:
		if marker.id == id:
			return marker
	return null


static func _add_fortress(markers: Array[WorldMarker], view: FortressView, net_id: int) -> void:
	var definition: FortressDefinition = view.get_definition(net_id)
	var state: FortressState = view.get_displayed_state(net_id)
	var owner_code: int = state.owner if state != null else RealmCatalog.NEUTRAL_CODE
	var owner_color: Color = UIPalette.faction_color_of_code(owner_code)
	var anchor: Vector3 = view.get_anchor_position(net_id)
	if anchor != Vector3.INF:
		markers.append(WorldMarker.make(StringName("fort_%d" % net_id), WorldMarker.Kind.FORT,
				definition.display_name if definition != null else "Fuerte", anchor, owner_color, owner_code))
	var gate: Vector3 = view.get_gate_position(net_id)
	if gate != Vector3.INF:
		markers.append(WorldMarker.make(StringName("gate_%d" % net_id), WorldMarker.Kind.GATE,
				TEXT_GATE, gate, owner_color, owner_code))
	var circle: Vector3 = view.get_circle_center(net_id)
	if circle != Vector3.INF and state != null and state.is_circle_active():
		var color: Color = UIPalette.faction_color_of_code(state.capture_realm) \
				if state.phase == FortressState.Phase.CAPTURING else CIRCLE_COLOR
		markers.append(WorldMarker.make(StringName("circle_%d" % net_id), WorldMarker.Kind.CIRCLE,
				TEXT_CIRCLE, circle, color, state.capture_realm))
