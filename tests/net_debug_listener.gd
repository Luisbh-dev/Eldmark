extends Node
## Helper for test_net_debug_overlay: listens for F3 in _unhandled_input, as the HUD does, and
## records it in the list in the [code]seen[/code] metadata.


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"toggle_debug"):
		var seen: Array = get_meta(&"seen")
		seen.append(true)
