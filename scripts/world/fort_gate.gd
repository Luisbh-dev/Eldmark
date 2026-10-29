@tool
class_name FortGate
extends StaticBody3D
## Puerta de madera del fuerte del Vado Gris (grupo [code]fort_gate[/code]). Escena compartida:
## la cargan igual el cliente y el servidor, y no depende de nada de [code]scripts/client/[/code].
##
## Dos hojas de tablones con bisagra en los postes del vano. Se guarda [b]cerrada[/b] y solo la
## abre la rotura (vida 0): entonces las hojas cuelgan hacia fuera, hacia la explanada, para no
## chocar con la pasarela que pasa por encima del vano por dentro.
## [br][br]
## [b]Dos cuerpos[/b] (docs/fuerte.md, sección 3.1). Sacar la puerta de la capa del mundo rompería
## la línea de visión de los golpes, la cámara y el horneado de la navegación, así que:
## [br]- el propio nodo es el cuerpo de [b]movimiento[/b]: su capa son las capas de reino 5 a 7 de
## los reinos que [b]no[/b] son el dueño ([method layers_for]). Cada personaje añade a su máscara
## la capa de su reino ([method PlayerCharacter.set_realm_collision]), así que la puerta cerrada
## para a los enemigos del dueño y deja pasar a los suyos; si el fuerte es neutral las para a todas;
## [br]- el hijo [code]Vista[/code] es el cuerpo de [b]vista[/b], en la capa 4 de estructuras
## ([constant PlayerCharacter.STRUCTURE_LAYER]): no para a nadie, pero la cámara y la línea de
## visión no atraviesan la puerta (aunque el dueño pueda cruzarla).
## [br]Rota, los dos cuerpos se quedan sin capas.
## [br][br]
## El servidor y el cliente deben poner el mismo estado en cada tick con [method set_state]
## (dueño y rotura); la vida y los golpes son cosa del controlador de la fortaleza.
## [br][br]
## Nodos que espera (los crea tools/props/build_vado_gris_props.gd): [code]Hoja1[/code] (norte,
## bisagra en z = -[constant HALF_WIDTH]) y [code]Hoja2[/code] (sur), [code]ColisionCerrada[/code]
## (forma del cuerpo de movimiento) y [code]Vista[/code] con su [code]ColisionVista[/code]. Origen:
## centro del vano a ras de suelo; cerrada, ocupa el plano x = 0 y el interior del fuerte queda
## hacia +X.

## Medio ancho del vano (m).
const HALF_WIDTH: float = 2.0
## Alto de las hojas (m).
const LEAF_HEIGHT: float = 4.3
## Giro de las hojas rotas (rad, unos 95°: algo más allá de la perpendicular).
const OPEN_ANGLE: float = 1.658
## Hijo con el cuerpo de vista (capa de estructuras).
const VIEW_BODY: NodePath = ^"Vista"
## Hijo con la forma de la puerta cerrada (la caja que golpean los ataques y que ocupa el vano).
const CLOSED_SHAPE: NodePath = ^"ColisionCerrada"
## Caja de la puerta cerrada si la escena no tiene [code]ColisionCerrada[/code]: tamaño y centro
## (en el espacio local de la puerta).
const DEFAULT_BOX_SIZE: Vector3 = Vector3(0.5, 4.3, 4.0)
const DEFAULT_BOX_CENTER: Vector3 = Vector3(0.0, 2.15, 0.0)
## Códigos de los reinos jugables (los de [RealmCatalog]) que tienen capa de movimiento.
const _REALM_CODES: Array[int] = [1, 2, 3]

var _owner_realm: int = 0
var _broken: bool = false


func _ready() -> void:
	_apply()


## Capas de colisión del cuerpo de movimiento de una puerta que pertenece a [param owner_realm]
## (0 = fuerte neutral): las capas de reino de los demás reinos. Con [param broken] (vida 0), 0:
## no para a nadie. Estática y compartida: el cliente y el servidor calculan lo mismo.
static func layers_for(owner_realm: int, broken: bool) -> int:
	if broken:
		return 0
	var layers: int = 0
	for code: int in _REALM_CODES:
		if code != owner_realm:
			layers |= PlayerCharacter.realm_layer(code)
	return layers


## Capa del cuerpo de vista: la de estructuras mientras la puerta está entera, 0 rota.
static func view_layer_for(broken: bool) -> int:
	return 0 if broken else PlayerCharacter.STRUCTURE_LAYER


## Pone el estado de la puerta: dueño del fuerte ([param owner_realm], 0 si es neutral) y si está
## rota. Cambia las capas de los dos cuerpos y la pose de las hojas.
func set_state(owner_realm: int, broken: bool) -> void:
	_owner_realm = owner_realm
	_broken = broken
	_apply()


## Reino dueño de la puerta (0 = neutral).
func get_owner_realm() -> int:
	return _owner_realm


## true si la puerta está rota (vida 0): sin colisión de ningún tipo y con las hojas colgando.
func is_broken() -> bool:
	return _broken


## Giro (rad) de la hoja [param index] (0 = norte, 1 = sur) en el estado actual.
func get_leaf_angle(index: int) -> float:
	if not _broken:
		return 0.0
	return -OPEN_ANGLE if index == 0 else OPEN_ANGLE


## Cuerpo de vista (capa de estructuras), o null si la escena no lo tiene.
func get_view_body() -> StaticBody3D:
	return get_node_or_null(VIEW_BODY) as StaticBody3D


## Transformación (en el mundo) del [b]centro[/b] de la caja de la puerta cerrada: es lo que golpean los
## ataques ([method HitShapes.sector_hits_box]) y lo que ocupa el vano
## ([method HitShapes.capsule_overlaps_box]). Sale de la forma [code]ColisionCerrada[/code] de la
## escena o, si no la tiene, de [constant DEFAULT_BOX_CENTER]. Solo vale con la puerta en el árbol.
func get_hit_box() -> Transform3D:
	var base: Transform3D = global_transform if is_inside_tree() else transform
	var shape_node: CollisionShape3D = get_node_or_null(CLOSED_SHAPE) as CollisionShape3D
	if shape_node != null:
		return base * shape_node.transform
	return base * Transform3D(Basis(), DEFAULT_BOX_CENTER)


## Medias dimensiones de la caja de [method get_hit_box].
func get_hit_half_extents() -> Vector3:
	var shape_node: CollisionShape3D = get_node_or_null(CLOSED_SHAPE) as CollisionShape3D
	if shape_node != null:
		var box: BoxShape3D = shape_node.shape as BoxShape3D
		if box != null:
			return box.size * 0.5
	return DEFAULT_BOX_SIZE * 0.5


## Cuerpos de física de la puerta (movimiento y vista): la línea de visión de los golpes a la
## propia puerta los excluye.
func get_body_rids() -> Array[RID]:
	var rids: Array[RID] = [get_rid()]
	var view: StaticBody3D = get_view_body()
	if view != null:
		rids.append(view.get_rid())
	return rids


func _apply() -> void:
	collision_layer = layers_for(_owner_realm, _broken)
	var view: StaticBody3D = get_view_body()
	if view != null:
		view.collision_layer = view_layer_for(_broken)
	for i: int in 2:
		var hinge: Vector3 = Vector3(0.0, 0.0, -HALF_WIDTH if i == 0 else HALF_WIDTH)
		var leaf_basis: Basis = Basis(Vector3.UP, get_leaf_angle(i))
		var leaf: Node3D = get_node_or_null(NodePath("Hoja%d" % (i + 1))) as Node3D
		if leaf != null:
			# La malla de la hoja va de la bisagra hacia +Z: la sur es la misma girada 180°.
			var mesh_basis: Basis = Basis() if i == 0 else Basis(Vector3.UP, PI)
			leaf.transform = Transform3D(leaf_basis * mesh_basis, hinge)
