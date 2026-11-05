class_name MapLabelPlacer
extends RefCounted
## Placement of map labels so that they do not overlap (UI-53). Pure: it receives the labels with their anchor point, their
## size and their priority, and returns where each goes. Those with higher priority choose first; each label tries a
## series of positions around its icon (right, left, above, below and the diagonals) and, if all
## collide, two farther rings joined to the icon by a leader line. If it does not fit either, it is hidden.
## [br][br]
## Each input element is [code]{"id", "anchor": Vector2, "size": Vector2, "priority": int, "area": bool}[/code].
## With [code]radius[/code] (px) the icon's gap is changed. Areas ([code]area[/code]) are centered on their anchor and have no other positions. The output adds
## [code]placed: bool[/code], [code]rect: Rect2[/code] and [code]leader: bool[/code] (leader line to the icon). Client
## only.

## Gap (px) between the icon and the label in the first ring, and in the second (with a leader line).
const GAP_NEAR: float = 8.0
const GAP_FAR: float = 34.0
## Gap (px) of the third and last ring, also with a leader line.
const GAP_FARTHEST: float = 66.0
## Margin (px) left free around each label already placed.
const PADDING: float = 3.0
## Radius (px) of the gap each icon occupies for the other labels.
const ICON_RADIUS: float = 9.0


## Places [param items] inside [param bounds]; [param extra_obstacles] are rectangles that no label may
## cover (the player, the legend...). Returns the same elements in the same order, annotated.
static func place(items: Array[Dictionary], bounds: Rect2, extra_obstacles: Array[Rect2] = []) -> Array[Dictionary]:
	var order: Array[int] = []
	for i: int in items.size():
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool:
		var pa: int = int(items[a].get("priority", 0))
		var pb: int = int(items[b].get("priority", 0))
		return pa > pb if pa != pb else a < b)
	var obstacles: Array[Rect2] = extra_obstacles.duplicate()
	for item: Dictionary in items:
		if not bool(item.get("area", false)):
			var at: Vector2 = item["anchor"]
			var radius: float = float(item.get("radius", ICON_RADIUS))
			obstacles.append(Rect2(at - Vector2.ONE * radius, Vector2.ONE * radius * 2.0))
	var taken: Array[Rect2] = []
	var result: Array[Dictionary] = []
	result.resize(items.size())
	for index: int in order:
		var out: Dictionary = items[index].duplicate()
		out["placed"] = false
		out["leader"] = false
		out["rect"] = Rect2()
		for candidate: Dictionary in candidates(items[index]):
			var rect: Rect2 = candidate["rect"]
			if not bounds.encloses(rect):
				continue
			if _hits(rect, taken) or _hits(rect, obstacles):
				continue
			out["placed"] = true
			out["rect"] = rect
			out["leader"] = bool(candidate["leader"])
			taken.append(rect)
			break
		result[index] = out
	return result


## Positions a label tries, in order: [code]{"rect": Rect2, "leader": bool}[/code].
static func candidates(item: Dictionary) -> Array[Dictionary]:
	var at: Vector2 = item["anchor"]
	var size: Vector2 = item["size"]
	var found: Array[Dictionary] = []
	if bool(item.get("area", false)):
		found.append({"rect": Rect2(at - size * 0.5, size), "leader": false})
		return found
	for ring: int in 3:
		var gap: float = [GAP_NEAR, GAP_FAR, GAP_FARTHEST][ring]
		var leader: bool = ring > 0
		var d: float = float(item.get("radius", ICON_RADIUS)) + gap
		# Right, left, above, below and the four diagonals.
		found.append({"rect": Rect2(at + Vector2(d, -size.y * 0.5), size), "leader": leader})
		found.append({"rect": Rect2(at + Vector2(-d - size.x, -size.y * 0.5), size), "leader": leader})
		found.append({"rect": Rect2(at + Vector2(-size.x * 0.5, -d - size.y), size), "leader": leader})
		found.append({"rect": Rect2(at + Vector2(-size.x * 0.5, d), size), "leader": leader})
		found.append({"rect": Rect2(at + Vector2(d, -d - size.y), size), "leader": leader})
		found.append({"rect": Rect2(at + Vector2(d, d), size), "leader": leader})
		found.append({"rect": Rect2(at + Vector2(-d - size.x, -d - size.y), size), "leader": leader})
		found.append({"rect": Rect2(at + Vector2(-d - size.x, d), size), "leader": leader})
	return found


## true if [param rect] (with its margin) touches any of [param others].
static func _hits(rect: Rect2, others: Array[Rect2]) -> bool:
	var grown: Rect2 = rect.grow(PADDING)
	for other: Rect2 in others:
		if grown.intersects(other):
			return true
	return false
