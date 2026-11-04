class_name MapLabelPlacer
extends RefCounted
## Colocación de rótulos del mapa sin que se pisen (UI-53). Puro: recibe los rótulos con su punto de anclaje, su
## tamaño y su prioridad, y devuelve dónde va cada uno. Los de más prioridad eligen primero; cada rótulo prueba una
## serie de posiciones alrededor de su icono (derecha, izquierda, encima, debajo y las diagonales) y, si todas
## chocan, dos coronas más lejos unidas al icono con una línea guía. Si tampoco cabe, se oculta.
## [br][br]
## Cada elemento de entrada es [code]{"id", "anchor": Vector2, "size": Vector2, "priority": int, "area": bool}[/code].
## Con [code]radius[/code] (px) se cambia el hueco del icono. Las zonas ([code]area[/code]) se centran sobre su anclaje y no tienen más posiciones. La salida añade
## [code]placed: bool[/code], [code]rect: Rect2[/code] y [code]leader: bool[/code] (línea guía hasta el icono). Solo
## cliente.

## Hueco (px) entre el icono y el rótulo en la primera corona, y en la segunda (con línea guía).
const GAP_NEAR: float = 8.0
const GAP_FAR: float = 34.0
## Hueco (px) de la tercera y última corona, también con línea guía.
const GAP_FARTHEST: float = 66.0
## Margen (px) que se deja libre alrededor de cada rótulo ya colocado.
const PADDING: float = 3.0
## Radio (px) del hueco que ocupa cada icono para los rótulos de los demás.
const ICON_RADIUS: float = 9.0


## Coloca [param items] dentro de [param bounds]; [param extra_obstacles] son rectángulos que ningún rótulo puede
## tapar (el jugador, la leyenda...). Devuelve los mismos elementos en el mismo orden, anotados.
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


## Posiciones que prueba un rótulo, por orden: [code]{"rect": Rect2, "leader": bool}[/code].
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
		# Derecha, izquierda, encima, debajo y las cuatro diagonales.
		found.append({"rect": Rect2(at + Vector2(d, -size.y * 0.5), size), "leader": leader})
		found.append({"rect": Rect2(at + Vector2(-d - size.x, -size.y * 0.5), size), "leader": leader})
		found.append({"rect": Rect2(at + Vector2(-size.x * 0.5, -d - size.y), size), "leader": leader})
		found.append({"rect": Rect2(at + Vector2(-size.x * 0.5, d), size), "leader": leader})
		found.append({"rect": Rect2(at + Vector2(d, -d - size.y), size), "leader": leader})
		found.append({"rect": Rect2(at + Vector2(d, d), size), "leader": leader})
		found.append({"rect": Rect2(at + Vector2(-d - size.x, -d - size.y), size), "leader": leader})
		found.append({"rect": Rect2(at + Vector2(-d - size.x, d), size), "leader": leader})
	return found


## true si [param rect] (con su margen) toca alguno de [param others].
static func _hits(rect: Rect2, others: Array[Rect2]) -> bool:
	var grown: Rect2 = rect.grow(PADDING)
	for other: Rect2 in others:
		if grown.intersects(other):
			return true
	return false
