extends TestCase
## The new phase-4 keys (docs/habilidades.md, sections 0 and 3.2, H4): Q swaps weapon, R and T
## drink the potions (the player menu moves from T to G) and the [constant PlayerInput.AIM_LEFT] bit comes from the
## camera's effective shoulder (also after the automatic switch because of a wall), as a level.

const CAMERA_RIG_SCENE: String = "res://scenes/client/camera_rig.tscn"

var _nodes: Array[Node] = []


func before_each() -> void:
	InputBindings.ensure_defaults()


func after_each() -> void:
	for action: StringName in [&"swap_weapon", &"consumable_1", &"consumable_2", &"ability_1"]:
		Input.action_release(action)
	for node: Node in _nodes:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()
	_nodes.clear()
	await wait_process_frames()


func _key_of(action: StringName) -> Key:
	for event: InputEvent in InputMap.action_get_events(action):
		var key: InputEventKey = event as InputEventKey
		if key != null:
			return key.physical_keycode
	return KEY_NONE


func test_the_new_keys_are_q_r_and_t_and_the_player_menu_moves_to_g() -> void:
	assert_eq(_key_of(&"swap_weapon"), KEY_Q, "Q swaps weapon")
	assert_eq(_key_of(&"consumable_1"), KEY_R, "R, the health potion")
	assert_eq(_key_of(&"consumable_2"), KEY_T, "T, the stamina one")
	assert_eq(_key_of(&"social_menu"), KEY_G, "the player menu moves to G")
	# No InputBindings gameplay key is repeated.
	var taken: Dictionary = {}
	for action: StringName in [&"move_forward", &"move_back", &"move_left", &"move_right", &"jump",
			&"sprint", &"dodge", &"ability_1", &"ability_2", &"ability_3", &"interact", &"swap_weapon",
			&"consumable_1", &"consumable_2", &"free_cursor", &"toggle_cursor", &"shoulder_swap",
			&"toggle_debug", &"toggle_net_ghost", &"open_settings", &"open_map", &"map_zoom_in",
			&"map_zoom_out", &"scoreboard", &"party_accept", &"party_decline", &"social_menu"]:
		var key: Key = _key_of(action)
		if key == KEY_NONE:
			continue
		assert_false(taken.has(key), "%s and %s do not share a key" % [action, taken.get(key, "")])
		taken[key] = action
	assert_eq(LocalPlayerController.BUTTON_ACTIONS[&"swap_weapon"], PlayerInput.SWAP_WEAPON)
	assert_eq(LocalPlayerController.BUTTON_ACTIONS[&"consumable_1"], PlayerInput.CONSUMABLE_1)
	assert_eq(LocalPlayerController.BUTTON_ACTIONS[&"consumable_2"], PlayerInput.CONSUMABLE_2)


func test_the_controller_sends_the_new_buttons_and_aim_left_from_the_effective_shoulder() -> void:
	var rig: CameraRig = (load(CAMERA_RIG_SCENE) as PackedScene).instantiate() as CameraRig
	tree.root.add_child(rig)
	_nodes.append(rig)
	rig.set_scripted_look(false)
	var controller := LocalPlayerController.new()
	tree.root.add_child(controller)
	_nodes.append(controller)
	controller.auto_step = false
	controller.setup(null, rig)
	var input: PlayerInput = controller.build_input(1)
	assert_eq(input.buttons & PlayerInput.AIM_LEFT, 0, "right shoulder: without the bit")
	Input.action_press(&"swap_weapon")
	Input.action_press(&"consumable_2")
	input = controller.build_input(2)
	assert_true((input.buttons & PlayerInput.SWAP_WEAPON) != 0, "Q sets SWAP_WEAPON")
	assert_true((input.buttons & PlayerInput.CONSUMABLE_2) != 0, "T sets CONSUMABLE_2")
	assert_eq(input.buttons & PlayerInput.CONSUMABLE_1, 0)
	Input.action_release(&"swap_weapon")
	Input.action_release(&"consumable_2")
	rig.set_default_shoulder(-1)
	assert_eq(rig.get_effective_shoulder(), -1)
	input = controller.build_input(3)
	assert_true((input.buttons & PlayerInput.AIM_LEFT) != 0, "left shoulder: the bit, every tick (a level)")
	input = controller.build_input(4)
	assert_true((input.buttons & PlayerInput.AIM_LEFT) != 0)
	# The automatic switch because of a wall counts: it is the shoulder the ray comes from.
	rig.set_default_shoulder(1)
	rig._shoulder_override = -1.0
	assert_eq(rig.get_chosen_shoulder(), 1, "the chosen one is still the right one")
	assert_eq(rig.get_effective_shoulder(), -1, "but the view is from the left")
	input = controller.build_input(5)
	assert_true((input.buttons & PlayerInput.AIM_LEFT) != 0)
	# While typing in chat the input is suspended, but the shoulder still describes the view.
	controller.set_input_blocked(true, rig)
	Input.action_press(&"consumable_1")
	input = controller.build_input(6)
	assert_eq(input.buttons & PlayerInput.CONSUMABLE_1, 0, "suspended, no buttons")
	assert_true((input.buttons & PlayerInput.AIM_LEFT) != 0, "except the shoulder")
	controller.set_input_blocked(false, rig)
	# The bits travel (VALID_BUTTONS admits them).
	assert_eq(PlayerInput.decode(input.encode()).buttons & PlayerInput.AIM_LEFT, PlayerInput.AIM_LEFT)
	assert_true((NetProtocol.VALID_BUTTONS & PlayerInput.AIM_LEFT) != 0)
