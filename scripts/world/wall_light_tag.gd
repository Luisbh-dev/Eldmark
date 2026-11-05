class_name WallLightTag
extends Node3D
## Marks everything visible under this node with the walls' light layer (ART-54).
##
## The Vado Gris sun runs in the X plane (so both halves receive the same), so the
## wall facades, which face +Z and -Z, sit edge-on to its light and only receive ambient:
## gray and flat. The generator puts two symmetric fill lights in the zone (one from the
## southwest and one from the northwest, with no shadow) that only light the [constant LIGHT_LAYER] layer: the
## inner facade of each wall receives one and the grazing light makes the relief of the
## ashlar blocks readable, without touching the rest of the scene. This node puts the meshes of the walls
## into that layer (without removing them from layer 1), including the towers and the gates, which are instanced scenes.
## [br][br]
## On the server (headless) it draws nothing and setting the layer costs nothing.

## Walls' visual layer (the 20th) and its light mask.
const LIGHT_LAYER: int = 1 << 19


func _ready() -> void:
	tag(self)


## Sets the layer on every [VisualInstance3D] under [param root] (also on the node itself if it is one).
static func tag(root: Node) -> void:
	var nodes: Array[Node] = root.find_children("*", "VisualInstance3D", true, false)
	if root is VisualInstance3D:
		nodes.append(root)
	for node: Node in nodes:
		var instance: VisualInstance3D = node as VisualInstance3D
		instance.layers |= LIGHT_LAYER
