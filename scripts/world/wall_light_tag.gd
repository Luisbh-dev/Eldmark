class_name WallLightTag
extends Node3D
## Marca todo lo visible bajo este nodo con la capa de luz de las murallas (ART-54).
##
## El sol del Vado Gris va en el plano X (para que las dos mitades reciban lo mismo), así que las
## fachadas de las murallas, que miran a +Z y a -Z, quedan de canto a su luz y solo reciben ambiente:
## grises y planas. El generador pone en la zona dos luces de relleno simétricas (una desde el
## suroeste y otra desde el noroeste, sin sombra) que solo iluminan la capa [constant LIGHT_LAYER]: la
## fachada interior de cada muralla recibe una y la luz rasante hace que se lea el relieve de los
## sillares, sin tocar el resto de la escena. Este nodo mete en esa capa (sin quitarla de la 1) las
## mallas de las murallas, incluidas las torres y las puertas, que son escenas instanciadas.
## [br][br]
## En el servidor (headless) no dibuja nada y poner la capa no cuesta nada.

## Capa de visualización de las murallas (la 20) y su máscara de luz.
const LIGHT_LAYER: int = 1 << 19


func _ready() -> void:
	tag(self)


## Pone la capa en cada [VisualInstance3D] bajo [param root] (también en el propio nodo si lo es).
static func tag(root: Node) -> void:
	var nodes: Array[Node] = root.find_children("*", "VisualInstance3D", true, false)
	if root is VisualInstance3D:
		nodes.append(root)
	for node: Node in nodes:
		var instance: VisualInstance3D = node as VisualInstance3D
		instance.layers |= LIGHT_LAYER
