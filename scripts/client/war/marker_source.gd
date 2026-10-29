class_name MarkerSource
extends RefCounted
## De dónde salen los [WorldMarker] de una zona (UI-19, docs/fuerte.md sección 6): los lugares fijos del
## mapa horneado ([ZoneMapDefinition]: campamentos y pasos) y lo que sabe el cliente de cada fortaleza
## ([FortressView]: el fuerte, su puerta y su círculo con el color del dueño o del captor). Puro: no
## dibuja ni lee la escena, solo junta datos.
## [br][br]
## [b]Colores.[/b] Los lugares de un reino llevan su color de bando; el fuerte, el de su dueño (los Huecos
## si es neutral); la puerta, el del dueño; el círculo, el del captor mientras se captura y el blanco
## de la interfaz mientras está activo sin captor. El círculo solo es un marcador mientras está activo
## (el capitán ha caído o hay una captura en marcha).

const CIRCLE_COLOR: Color = Color(1.0, 0.95, 0.8, 1.0)
const TEXT_GATE: String = "Puerta"
const TEXT_CIRCLE: String = "Círculo de captura"


## Marcadores de la zona. [param map] puede ser null (zona sin mapa horneado) y [param view] también
## (aún sin cliente): se usa lo que haya.
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
					# El del mapa solo vale mientras el cliente no conoce la fortaleza (sin dueño ni estado).
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


## Marcador de [param markers] cuyo id es [param id], o null.
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
