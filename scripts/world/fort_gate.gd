@tool
class_name FortGate
extends StaticBody3D
## Puerta de madera del fuerte del Vado Gris (grupo [code]fort_gate[/code]). Escena compartida:
## la cargan igual el cliente y el servidor, y no depende de nada de [code]scripts/client/[/code].
##
## Dos hojas de tablones con bisagra en los postes del vano. Cerrada, una caja bloquea el paso;
## abierta, las hojas giran hacia fuera (hacia la explanada, para no chocar con la pasarela que
## pasa por encima del vano por dentro) y cada una tiene su colisión fina.
## [br][br]
## Hasta que la fase 4 le dé vida y la rompa a golpes, la escena se guarda abierta para que se
## pueda probar el interior del fuerte (patio, rampas, pasarela y círculo de captura).
## [br][br]
## Nodos que espera (los crea tools/props/build_vado_gris_props.gd): [code]Hoja1[/code] (norte,
## bisagra en z = -[constant HALF_WIDTH]) y [code]Hoja2[/code] (sur), [code]ColisionCerrada[/code],
## [code]ColisionHoja1[/code] y [code]ColisionHoja2[/code]. Origen: centro del vano a ras de
## suelo; cerrada, ocupa el plano x = 0 y el interior del fuerte queda hacia +X.

## Medio ancho del vano (m).
const HALF_WIDTH: float = 2.0
## Alto de las hojas (m).
const LEAF_HEIGHT: float = 4.3
## Grosor de la colisión de cada hoja abierta (m).
const LEAF_THICKNESS: float = 0.18
## Giro de las hojas abiertas (rad, unos 95°: algo más allá de la perpendicular).
const OPEN_ANGLE: float = 1.658

## Abierta (paso libre) o cerrada (bloquea el vano).
@export var open: bool = true:
	set(value):
		open = value
		if is_node_ready():
			_apply()


func _ready() -> void:
	_apply()


## Giro (rad) de la hoja [param index] (0 = norte, 1 = sur) en el estado actual.
func get_leaf_angle(index: int) -> float:
	if not open:
		return 0.0
	return -OPEN_ANGLE if index == 0 else OPEN_ANGLE


func _apply() -> void:
	var closed_shape: CollisionShape3D = get_node_or_null(^"ColisionCerrada") as CollisionShape3D
	if closed_shape != null:
		closed_shape.disabled = open
	for i: int in 2:
		var hinge: Vector3 = Vector3(0.0, 0.0, -HALF_WIDTH if i == 0 else HALF_WIDTH)
		var leaf_basis: Basis = Basis(Vector3.UP, get_leaf_angle(i))
		var leaf: Node3D = get_node_or_null(NodePath("Hoja%d" % (i + 1))) as Node3D
		if leaf != null:
			# La malla de la hoja va de la bisagra hacia +Z: la sur es la misma girada 180°.
			var mesh_basis: Basis = Basis() if i == 0 else Basis(Vector3.UP, PI)
			leaf.transform = Transform3D(leaf_basis * mesh_basis, hinge)
		var leaf_shape: CollisionShape3D = get_node_or_null(NodePath("ColisionHoja%d" % (i + 1))) as CollisionShape3D
		if leaf_shape != null:
			leaf_shape.disabled = not open
			# La hoja va de la bisagra hacia el centro del vano (+Z la norte, -Z la sur).
			var along: float = HALF_WIDTH * 0.5 if i == 0 else -HALF_WIDTH * 0.5
			leaf_shape.transform = Transform3D(leaf_basis, hinge + leaf_basis * Vector3(0.0, LEAF_HEIGHT * 0.5, along))
