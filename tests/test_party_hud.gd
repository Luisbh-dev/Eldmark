extends TestCase
## Tests of the client's party interface (SOC-08, docs/social.md section 12.5) with synthetic messages and a
## fake client: the party state ([PartyState]: list, leader, 2 Hz state, invitations and their expiry),
## the frames ([PartyFrames], [PartyFrame]: a demo with four grouped bots), the invitation prompt with
## accept and decline by keyboard ([PartyInvitePrompt]) and the mounting in the [HUD] with the chat commands.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const OWN_ID: int = 101
const HUD_SCENE_PATH: String = "res://scenes/ui/hud.tscn"
const CAMERA_RIG_SCENE_PATH: String = "res://scenes/client/camera_rig.tscn"
const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"


## Network client that connects to nothing: it gives the local player, the server tick and records what
## it is asked to send.
class FakeClient extends NetClient:
	var fake_config: ClientConfig = ClientConfig.new()
	var fake_character: PlayerCharacter = null
	var fake_tick: int = 1000
	var fake_net_id: int = 0
	var sent: Array[Array] = []
	## If true, the reply to an invitation does not go out (like NetClient outside the world or with the
	## connection lost): it returns false without recording anything or removing the invitation.
	var fail_responses: bool = false

	func get_config() -> ClientConfig:
		return fake_config

	func get_character() -> PlayerCharacter:
		return fake_character

	func get_estimated_server_tick() -> int:
		return fake_tick

	func get_net_id() -> int:
		return fake_net_id

	func send_party_invite(target_name: String) -> bool:
		sent.append(["invite", target_name])
		return true

	func send_party_kick(target_name: String) -> bool:
		sent.append(["kick", target_name])
		return true

	func send_party_leader(target_name: String) -> bool:
		sent.append(["leader", target_name])
		return true

	func send_party_leave() -> bool:
		sent.append(["leave"])
		return true

	func send_party_response(inviter: String, accept: bool) -> bool:
		if fail_responses:
			return false
		sent.append(["response", inviter, accept])
		get_party().remove_invitation(inviter)
		return true


var _nodes: Array[Node] = []
var _client: FakeClient = null
var _party: PartyState = null


func before_each() -> void:
	_nodes.clear()
	_client = _track(FakeClient.new()) as FakeClient
	_client.fake_config.display_name = "Ana"
	_client.fake_config.realm = VARDHEIM
	_client.fake_net_id = OWN_ID
	_party = _client.get_party()
	InputBindings.ensure_defaults()


func after_each() -> void:
	for node: Node in _nodes:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()
	_nodes.clear()
	await wait_process_frames()


# --- Helpers ----------------------------------------------------------------------------------

func _track(node: Node) -> Node:
	tree.root.add_child(node)
	_nodes.append(node)
	return node


func _roster(names: Array[String], leader_index: int = 0, first_id: int = OWN_ID) -> NetMessages.PartyRoster:
	var roster := NetMessages.PartyRoster.new()
	roster.leader_index = leader_index
	for i: int in names.size():
		roster.members.append(NetMessages.PartyRoster.Member.make(first_id + i, names[i]))
	return roster


# A list with explicit ids: [[id, name], ...].
func _roster_of(entries: Array[Array], leader_index: int = 0) -> NetMessages.PartyRoster:
	var roster := NetMessages.PartyRoster.new()
	roster.leader_index = leader_index
	for entry: Array in entries:
		roster.members.append(NetMessages.PartyRoster.Member.make(entry[0], entry[1]))
	return roster


func _status(entries: Array[Dictionary]) -> NetMessages.PartyStatus:
	var status := NetMessages.PartyStatus.new()
	for entry: Dictionary in entries:
		status.members.append(NetMessages.PartyStatus.MemberStatus.make(entry["id"], entry.get("health", 255),
				entry.get("stamina", 255), entry.get("status", 0), entry.get("position", Vector3.ZERO)))
	return status


func _offer(inviter: String, expire_tick: int) -> NetMessages.PartyInvitation:
	var invitation := NetMessages.PartyInvitation.new()
	invitation.inviter = inviter
	invitation.tick = expire_tick
	return invitation


func _key(keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	event.keycode = keycode
	event.pressed = true
	return event


## Presses and releases [param keycode] (with its [param unicode] character) through the window's real
## input, like the keyboard: the key goes through the windows, the interface and everyone's _unhandled_input.
func _press(keycode: Key, unicode: int) -> void:
	var down: InputEventKey = _key(keycode)
	down.unicode = unicode
	tree.root.push_input(down)
	var up: InputEventKey = _key(keycode)
	up.pressed = false
	tree.root.push_input(up)


func _net_hud() -> Array:
	var rig: CameraRig = _track((load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate()) as CameraRig
	var hud: HUD = _track((load(HUD_SCENE_PATH) as PackedScene).instantiate()) as HUD
	var character: PlayerCharacter = (load(CHARACTER_SCENE_PATH) as PackedScene).instantiate() as PlayerCharacter
	_track(character)
	_client.fake_character = character
	hud.bind(character, rig)
	hud.bind_net(_client, null)
	return [hud, rig]


# --- PartyState -------------------------------------------------------------------------------

func test_state_follows_the_roster_and_keeps_the_status_of_who_stays() -> void:
	var changes: Array[int] = [0]
	_party.roster_changed.connect(func() -> void: changes[0] += 1)
	assert_false(_party.is_in_party(), "starts without a party")
	_party.apply_roster(_roster(["Ana", "Bruno", "Cora"], 1))
	assert_true(_party.is_in_party(), "with a party")
	assert_eq(_party.get_member_count(), 3, "three members")
	assert_eq(_party.get_leader_id(), OWN_ID + 1, "Bruno is in charge")
	assert_true(_party.is_leader(OWN_ID + 1), "is_leader")
	assert_false(_party.is_leader(OWN_ID), "Ana is not")
	assert_false(_party.is_leader(0), "ni el id 0")
	assert_eq(_party.get_member(OWN_ID + 2).display_name, "Cora", "by id")
	assert_null(_party.get_member(999), "one that is not there")
	assert_false(_party.get_member(OWN_ID).has_status, "no state until the first PARTY_STATUS")
	assert_eq(changes[0], 1, "roster_changed")

	_party.apply_status(_status([{"id": OWN_ID + 2, "health": 100, "stamina": 50, "position": Vector3(1, 2, 3),
			"status": NetMessages.STATUS_IN_COMBAT}]))
	var cora: PartyState.Member = _party.get_member(OWN_ID + 2)
	assert_true(cora.has_status, "now has state")
	assert_near(cora.get_health_fraction(), 100.0 / 255.0, 1e-6, "health")
	assert_near(cora.get_stamina_fraction(), 50.0 / 255.0, 1e-6, "stamina")
	assert_vec_near(cora.position, Vector3(1.0, 2.0, 3.0), 1e-6, "position")
	assert_true(cora.is_in_combat(), "in combat")
	assert_false(cora.is_dead(), "alive")
	# A new list (Bruno leaves) keeps Cora's state and takes the new order.
	_party.apply_roster(_roster_of([[OWN_ID, "Ana"], [OWN_ID + 2, "Cora"]], 1))
	assert_eq(_party.get_member_count(), 2, "two")
	assert_eq(_party.get_leader_id(), OWN_ID + 2, "Cora is in charge")
	var kept: PartyState.Member = _party.get_member(OWN_ID + 2)
	assert_true(kept.has_status, "Cora keeps her state")
	assert_near(kept.get_health_fraction(), 100.0 / 255.0, 1e-6, "and her health")
	assert_null(_party.get_member(OWN_ID + 1), "Bruno is no longer there")
	# A state for someone who is not there is ignored.
	var status_changes: Array[int] = [0]
	_party.status_changed.connect(func() -> void: status_changes[0] += 1)
	_party.apply_status(_status([{"id": 777, "health": 10}]))
	assert_eq(status_changes[0], 0, "an unknown member changes nothing")
	# An empty list means leaving the party.
	_party.apply_roster(NetMessages.PartyRoster.new())
	assert_false(_party.is_in_party(), "without a party")
	assert_eq(_party.get_leader_id(), 0, "without a leader")


func test_dead_members_and_status_bits() -> void:
	_party.apply_roster(_roster(["Ana", "Bruno"]))
	_party.apply_status(_status([{"id": OWN_ID + 1, "health": 0, "status": NetMessages.STATUS_DEAD}]))
	assert_true(_party.get_member(OWN_ID + 1).is_dead(), "dead")
	assert_eq(_party.get_member(OWN_ID + 1).get_health_fraction(), 0.0, "without health")
	assert_false(_party.get_member(OWN_ID).is_dead(), "Ana, without data, is not recorded as dead")


func test_invitations_are_replaced_removed_and_expire() -> void:
	var changes: Array[int] = [0]
	_party.invitation_changed.connect(func() -> void: changes[0] += 1)
	_party.apply_invitation(_offer("Bruno", 2000))
	_party.apply_invitation(_offer("Cora", 3000))
	assert_eq(_party.get_invitations().size(), 2, "two pending")
	assert_eq(_party.get_current_invitation().inviter, "Bruno", "the oldest is shown")
	_party.apply_invitation(_offer("BRUNO", 2500))
	assert_eq(_party.get_invitations().size(), 2, "a new one from the same player replaces the previous one")
	assert_eq(_party.get_current_invitation().inviter, "Cora", "and goes to the end")
	var cancelled := NetMessages.PartyInvitation.new()
	cancelled.state = NetMessages.PartyInvitation.State.CANCELLED
	cancelled.inviter = "cora"
	_party.apply_invitation(cancelled)
	assert_eq(_party.get_invitations().size(), 1, "a cancelled one is removed")
	var expired := NetMessages.PartyInvitation.new()
	expired.state = NetMessages.PartyInvitation.State.EXPIRED
	expired.inviter = "Bruno"
	_party.apply_invitation(expired)
	assert_null(_party.get_current_invitation(), "an expired one too")
	# Expiry by tick, in case the notice is lost.
	_party.apply_invitation(_offer("Dani", 1500))
	assert_eq(_party.prune_expired(1499), 0, "one tick earlier it is still there")
	assert_eq(_party.prune_expired(1500), 1, "when the tick arrives, it is removed")
	assert_false(_party.remove_invitation("Dani"), "it is no longer there")
	_party.apply_invitation(_offer("Eva", 9000))
	assert_true(_party.remove_invitation("eva"), "it is removed on replying")
	_party.apply_invitation(_offer("Eva", 9000))
	_party.clear()
	assert_null(_party.get_current_invitation(), "clear empties everything")
	assert_true(changes[0] >= 6, "invitation_changed notifies each change (%d)" % changes[0])


# --- Frames -----------------------------------------------------------------------------------

func _frames() -> PartyFrames:
	var frames: PartyFrames = _track(PartyFrames.new()) as PartyFrames
	frames.bind(_party, _client)
	return frames


## The backlog demo: four bots grouped with the local player (five frames, the maximum). It takes each one to a place:
## Bruno near and at half health, Cora far away, Dani dead and Eva with no data yet.
func test_a_party_of_five_shows_the_right_frames() -> void:
	var character: PlayerCharacter = (load(CHARACTER_SCENE_PATH) as PackedScene).instantiate() as PlayerCharacter
	_track(character)
	character.global_position = Vector3.ZERO
	_client.fake_character = character
	var frames: PartyFrames = _frames()
	assert_false(frames.visible, "without a party there are no frames")
	assert_eq(frames.get_frame_count(), 0, "none")

	_party.apply_roster(_roster(["Ana", "Bruno", "Cora", "Dani", "Eva"], 1))
	_party.apply_status(_status([
		{"id": OWN_ID, "health": 255, "stamina": 255, "position": Vector3.ZERO},
		{"id": OWN_ID + 1, "health": 128, "stamina": 200, "position": Vector3(10.0, 0.0, 0.0)},
		{"id": OWN_ID + 2, "health": 255, "stamina": 100, "position": Vector3(250.0, 0.0, 0.0)},
		{"id": OWN_ID + 3, "health": 0, "stamina": 0, "status": NetMessages.STATUS_DEAD,
				"position": Vector3(20.0, 0.0, 0.0)},
	]))
	assert_true(frames.visible, "with a party, yes")
	assert_eq(frames.get_frame_count(), 5, "one frame per member")
	var names: PackedStringArray = PackedStringArray()
	for frame: PartyFrame in frames.get_frames():
		names.append(frame.get_name_text())
	assert_eq(names, PackedStringArray(["Ana", "Bruno", "Cora", "Dani", "Eva"]), "in the server's order")

	var own: PartyFrame = frames.get_frame(OWN_ID)
	assert_true(own.is_own(), "the first is the player itself")
	assert_false(own.is_leader_shown(), "without a crown")
	assert_false(own.is_dimmed(), "nor dimmed")
	var bruno: PartyFrame = frames.get_frame(OWN_ID + 1)
	assert_true(bruno.is_leader_shown(), "the crown belongs to the leader, Bruno")
	assert_eq(frames.get_frames().filter(func(frame: PartyFrame) -> bool: return frame.is_leader_shown()).size(), 1,
			"and only to one")
	assert_near(bruno.get_health_fraction(), 128.0 / 255.0, 1e-6, "its health")
	assert_near(bruno.get_stamina_fraction(), 200.0 / 255.0, 1e-6, "its stamina")
	assert_near(bruno.get_distance(), 10.0, 1e-3, "a 10 m")
	assert_false(bruno.is_far(), "near")
	assert_near(bruno.modulate.a, 1.0, 1e-6, "opaque")
	var cora: PartyFrame = frames.get_frame(OWN_ID + 2)
	assert_true(cora.is_far(), "Cora is at 250 m")
	assert_true(cora.is_dimmed(), "dimmed")
	assert_near(cora.modulate.a, PartyFrame.DIM_ALPHA, 1e-6, "with the opacity of the dimmed ones")
	var dani: PartyFrame = frames.get_frame(OWN_ID + 3)
	assert_true(dani.is_dead(), "Dani is dead")
	assert_true(dani.is_dimmed(), "dimmed")
	assert_eq(dani.get_health_fraction(), 0.0, "without health")
	var eva: PartyFrame = frames.get_frame(OWN_ID + 4)
	assert_false(eva.has_data(), "Eva does not have data yet")
	assert_true(eva.is_dimmed(), "dimmed and without data")
	var colors: Dictionary = {}
	for frame: PartyFrame in frames.get_frames():
		colors[frame.get_name_color()] = true
	assert_eq(colors.size(), 1, "all with the realm's color")
	assert_eq(bruno.get_name_color(), UIPalette.faction_color_of_code(VARDHEIM).lightened(0.25), "that of Vardheim")

	# Cora gets closer: she stops being dimmed on repaint.
	_party.apply_status(_status([{"id": OWN_ID + 2, "health": 255, "position": Vector3(40.0, 0.0, 0.0)}]))
	assert_false(frames.get_frame(OWN_ID + 2).is_far(), "at 40 m she is no longer far")
	assert_false(frames.get_frame(OWN_ID + 2).is_dimmed(), "nor dimmed")
	# And the local player moves away: the distance clock repaints the frames.
	character.global_position = Vector3(-200.0, 0.0, 0.0)
	frames.advance(PartyFrames.REFRESH_SECONDS + 0.01)
	assert_true(frames.get_frame(OWN_ID + 1).is_far(), "as the player moves away, Bruno ends up far (210 m)")


func test_frames_follow_the_roster() -> void:
	var frames: PartyFrames = _frames()
	_party.apply_roster(_roster(["Ana", "Bruno", "Cora"], 0))
	assert_eq(frames.get_frame_count(), 3, "three frames")
	_party.apply_roster(_roster(["Ana", "Cora"], 1))
	assert_eq(frames.get_frame_count(), 2, "one leaves")
	assert_true(frames.get_frame(OWN_ID + 1).is_leader_shown(), "the crown changes with the leader")
	assert_false(frames.get_frame(OWN_ID).is_leader_shown(), "and is removed from the previous one")
	_party.apply_roster(NetMessages.PartyRoster.new())
	assert_eq(frames.get_frame_count(), 0, "without a party, without frames")
	assert_false(frames.visible, "and the column is hidden")


# --- Invitation -------------------------------------------------------------------------------

func _prompt() -> PartyInvitePrompt:
	var prompt: PartyInvitePrompt = _track(PartyInvitePrompt.new()) as PartyInvitePrompt
	prompt.bind(_party, _client)
	return prompt


func test_the_invitation_prompt_shows_who_and_how_long() -> void:
	var prompt: PartyInvitePrompt = _prompt()
	assert_false(prompt.visible, "without an invitation it is not shown")
	_party.apply_invitation(_offer("Bruno", _client.fake_tick + 3600))
	assert_true(prompt.visible, "with an invitation, it is")
	assert_eq(prompt.get_title_text(), "Bruno te invita a su grupo", "who")
	assert_eq(prompt.get_seconds_left(), 60, "60 s")
	assert_eq(prompt.get_timer_text(), "60 s", "they are shown")
	_client.fake_tick += 1830
	prompt.refresh()
	assert_eq(prompt.get_seconds_left(), 30, "after 30.5 s, 30 remain")
	_party.apply_invitation(_offer("Cora", _client.fake_tick + 3000))
	assert_eq(prompt.get_title_text(), "Bruno te invita a su grupo (+1 más)", "with one more, it says so")
	# The expiry by tick removes the notice even if the server's message does not arrive.
	_client.fake_tick += 1800
	prompt.refresh()
	assert_eq(prompt.get_title_text(), "Cora te invita a su grupo", "Bruno's expired: Cora's remains")
	_client.fake_tick += 5000
	prompt.refresh()
	assert_false(prompt.visible, "all expired, it is hidden")
	assert_eq(prompt.get_seconds_left(), 0, "0 s")


func test_the_prompt_shows_the_real_keys_and_responds_from_the_keyboard() -> void:
	var prompt: PartyInvitePrompt = _prompt()
	_party.apply_invitation(_offer("Bruno", _client.fake_tick + 3600))
	assert_eq(prompt.get_accept_glyph().action, &"party_accept", "the accept glyph")
	assert_eq(prompt.get_decline_glyph().action, &"party_decline", "and the decline one")
	assert_true(InputMap.has_action(&"party_accept") and InputMap.has_action(&"party_decline"),
			"the actions exist")
	# Accepting with the key.
	prompt._unhandled_input(_key(KEY_Y))
	assert_eq(_client.sent.size(), 1, "a reply sent")
	assert_eq(_client.sent[0], ["response", "Bruno", true], "Bruno is accepted")
	assert_false(prompt.visible, "and the prompt is removed at once")
	assert_null(_party.get_current_invitation(), "without invitations")
	# Declining with the other one.
	_party.apply_invitation(_offer("Cora", _client.fake_tick + 3600))
	prompt._unhandled_input(_key(KEY_N))
	assert_eq(_client.sent[1], ["response", "Cora", false], "Cora is declined")
	# With no prompt in sight, the keys do nothing.
	prompt._unhandled_input(_key(KEY_Y))
	prompt._unhandled_input(_key(KEY_N))
	assert_eq(_client.sent.size(), 2, "without an invitation nothing is sent")
	assert_false(prompt.respond(true), "respond without an invitation returns false")


func test_a_response_that_does_not_go_out_keeps_the_invitation() -> void:
	var prompt: PartyInvitePrompt = _prompt()
	_party.apply_invitation(_offer("Bruno", _client.fake_tick + 3600))
	_client.fail_responses = true
	assert_false(prompt.respond(true), "if the reply does not go out, respond says so")
	assert_eq(_client.sent.size(), 0, "nothing has gone out")
	assert_not_null(_party.get_current_invitation(), "the invitation remains")
	prompt.refresh()
	assert_true(prompt.visible, "and the prompt too")
	_client.fail_responses = false
	assert_true(prompt.respond(true), "when it does go out, yes")
	assert_eq(_client.sent, [["response", "Bruno", true]] as Array[Array], "accepted")
	assert_null(_party.get_current_invitation(), "and it is removed")


func test_the_invite_keys_wait_while_another_window_holds_the_cursor() -> void:
	var pair: Array = _net_hud()
	var hud: HUD = pair[0]
	var rig: CameraRig = pair[1]
	var prompt: PartyInvitePrompt = hud.get_party_hud().get_prompt()
	_party.apply_invitation(_offer("Cora", _client.fake_tick + 3600))
	prompt.refresh()
	assert_true(prompt.visible, "the prompt is shown")
	# The social menu open (with its first button focused): Y does not accept.
	var menu: SocialMenu = hud.get_social_menu()
	menu.open()
	assert_true(rig.is_ui_holding_cursor(), "the menu has the cursor")
	_press(KEY_Y, 121)
	_press(KEY_N, 110)
	assert_eq(_client.sent.size(), 0, "with the social menu open, Y and N do not respond")
	menu.close()
	# Any other window (settings, the map...): neither.
	hud.get_world_map().open()
	_press(KEY_N, 110)
	assert_eq(_client.sent.size(), 0, "with the map open, N does not decline")
	hud.get_world_map().close()
	var window := UIWindow.new()
	_track(window)
	window.bind_camera(rig)
	window.open()
	_press(KEY_Y, 121)
	assert_eq(_client.sent.size(), 0, "nor with another window")
	window.close()
	# With the chat line open, the letter is for the text.
	hud.get_chat().open()
	_press(KEY_Y, 121)
	assert_eq(_client.sent.size(), 0, "typing in the chat, neither")
	hud.get_chat().close()
	# Without windows, Y accepts.
	assert_false(rig.is_ui_holding_cursor(), "nobody has the cursor")
	_press(KEY_Y, 121)
	assert_eq(_client.sent, [["response", "Cora", true]] as Array[Array], "without windows, Y accepts")


func test_the_invite_keys_answer_from_the_death_screen() -> void:
	var pair: Array = _net_hud()
	var hud: HUD = pair[0]
	var rig: CameraRig = pair[1]
	_party.apply_invitation(_offer("Dani", _client.fake_tick + 3600))
	hud.get_party_hud().get_prompt().refresh()
	hud.get_death_screen().open("Has caído.", _client.fake_tick + 600, PackedStringArray(["Campamento"]))
	assert_true(rig.is_ui_holding_cursor(), "the death screen has the cursor")
	_press(KEY_N, 110)
	assert_eq(_client.sent, [["response", "Dani", false]] as Array[Array],
			"with the death screen you can reply: it uses no letters")
	# But the map open on top of it does stop them.
	_party.apply_invitation(_offer("Eva", _client.fake_tick + 3600))
	hud.get_party_hud().get_prompt().refresh()
	hud.get_world_map().open(true)
	_press(KEY_Y, 121)
	assert_eq(_client.sent.size(), 1, "with the map on top, Y does not accept")
	hud.get_world_map().close()
	hud.get_death_screen().close()


# --- Mounting in the HUD ----------------------------------------------------------------------

func test_the_hud_mounts_the_party_interface_and_the_chat_commands_reach_the_server() -> void:
	var rig: CameraRig = _track((load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate()) as CameraRig
	var hud: HUD = _track((load(HUD_SCENE_PATH) as PackedScene).instantiate()) as HUD
	var character: PlayerCharacter = (load(CHARACTER_SCENE_PATH) as PackedScene).instantiate() as PlayerCharacter
	_track(character)
	_client.fake_character = character
	hud.bind(character, rig)
	assert_null(hud.get_party_hud(), "the sandbox has no party")
	hud.bind_net(_client, null)
	var party_hud: PartyHud = hud.get_party_hud()
	if not assert_not_null(party_hud, "online, it does"):
		return
	assert_true(party_hud.get_index() < hud.get_death_screen().get_index(), "below the death screen")
	assert_not_null(party_hud.get_frames(), "with frames")
	assert_not_null(party_hud.get_prompt(), "and prompt")
	# An invitation and a list reach the frames and the prompt.
	_party.apply_invitation(_offer("Bruno", _client.fake_tick + 3600))
	assert_true(party_hud.get_prompt().visible, "the prompt is shown")
	_party.apply_roster(_roster(["Ana", "Bruno"], 0))
	assert_eq(party_hud.get_frames().get_frame_count(), 2, "and the two frames")
	# The chat commands go to the client.
	var chat: ChatBox = hud.get_chat()
	chat.submit("/invitar Cora")
	chat.submit("/expulsar Bruno")
	chat.submit("/lider bruno")
	chat.submit("/salir")
	assert_eq(_client.sent.size(), 4, "four requests")
	assert_eq(_client.sent[0], ["invite", "Cora"], "/invitar")
	assert_eq(_client.sent[1], ["kick", "Bruno"], "/expulsar")
	assert_eq(_client.sent[2], ["leader", "bruno"], "/lider")
	assert_eq(_client.sent[3], ["leave"], "/salir")
	assert_true(chat.get_log().get_count() == 0, "and the chat does not complain about unknown commands")
	# A second call rebuilds the interface without duplicating it.
	hud.bind_net(_client, null)
	assert_eq(hud.get_children().filter(func(child: Node) -> bool: return child is PartyHud).size(), 1, "only one")
	# The nameplates know about the party.
	assert_true(hud.get_nameplates().get_party() == _party, "the nameplates receive the party state")
