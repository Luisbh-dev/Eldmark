extends Node
## Ayudante de test_net_debug_overlay: escucha F3 en _unhandled_input, como hace el HUD, y lo apunta
## en la lista del metadato [code]seen[/code].


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"toggle_debug"):
		var seen: Array = get_meta(&"seen")
		seen.append(true)
