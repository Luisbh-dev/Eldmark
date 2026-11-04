class_name MarkerIcons
extends RefCounted
## Placeholder icons for the [WorldMarker]s (UI-19, UI-20): simple shapes drawn with [CanvasItem]
## primitives (no textures) so that the compass, the world markers, the minimap and the map use the same
## drawing. Each kind ([enum WorldMarker.Kind]) has a shape:
## [br]- fort: a diamond; gate: an arch of two posts and a lintel; capture circle: a ring with a dot; camp:
## a tent (triangle); pass: an upward arrow.
## [br][br]
## The final art (ART-12) will replace them. Client only.

const OUTLINE_COLOR: Color = Color(0.04, 0.04, 0.05, 0.9)


## Draws the icon of [param kind] centered at [param center] with color [param color]; [param size] is its
## radius in pixels.
static func draw(item: CanvasItem, kind: int, center: Vector2, color: Color, size: float) -> void:
	_draw_shape(item, kind, center, OUTLINE_COLOR, size + 1.5)
	_draw_shape(item, kind, center, color, size)


## Draws an arrow pointing toward [param angle] (radians, 0 = up, positive to the right) at
## [param center]: the one for markers that are off screen.
static func draw_arrow(item: CanvasItem, center: Vector2, angle: float, color: Color, size: float) -> void:
	var points := PackedVector2Array([Vector2(0.0, -size), Vector2(size * 0.8, size * 0.7), Vector2(0.0, size * 0.25),
			Vector2(-size * 0.8, size * 0.7)])
	var rotated := PackedVector2Array()
	for point: Vector2 in points:
		rotated.append(center + point.rotated(angle))
	item.draw_colored_polygon(rotated, color)
	rotated.append(rotated[0])
	item.draw_polyline(rotated, OUTLINE_COLOR, 1.5)


static func _draw_shape(item: CanvasItem, kind: int, center: Vector2, color: Color, size: float) -> void:
	match kind:
		WorldMarker.Kind.FORT:
			item.draw_colored_polygon(PackedVector2Array([center + Vector2(0.0, -size), center + Vector2(size, 0.0),
					center + Vector2(0.0, size), center + Vector2(-size, 0.0)]), color)
		WorldMarker.Kind.GATE:
			var post: float = maxf(size * 0.35, 1.5)
			item.draw_rect(Rect2(center + Vector2(-size, -size), Vector2(post, size * 2.0)), color)
			item.draw_rect(Rect2(center + Vector2(size - post, -size), Vector2(post, size * 2.0)), color)
			item.draw_rect(Rect2(center + Vector2(-size, -size), Vector2(size * 2.0, post)), color)
		WorldMarker.Kind.CIRCLE:
			item.draw_arc(center, size, 0.0, TAU, 20, color, maxf(size * 0.3, 1.5))
			item.draw_circle(center, maxf(size * 0.25, 1.0), color)
		WorldMarker.Kind.CAMP:
			item.draw_colored_polygon(PackedVector2Array([center + Vector2(0.0, -size), center + Vector2(size, size * 0.8),
					center + Vector2(-size, size * 0.8)]), color)
		WorldMarker.Kind.PASS:
			item.draw_colored_polygon(PackedVector2Array([center + Vector2(0.0, -size), center + Vector2(size * 0.8, 0.0),
					center + Vector2(size * 0.3, 0.0), center + Vector2(size * 0.3, size),
					center + Vector2(-size * 0.3, size), center + Vector2(-size * 0.3, 0.0),
					center + Vector2(-size * 0.8, 0.0)]), color)
		_:
			item.draw_circle(center, size, color)
