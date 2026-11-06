extends TestCase
## Locally predicted hit (ART-09, review item C10): [method CombatFeedback._try_predict],
## [method CombatFeedback.is_valid_target] and the [signal CombatFeedback.hit_predicted] signal, driven with a fake
## [NetClient] whose drawn views are placed by hand: one inside the attack's sector, one outside, one dodging, one dead,
## an ally and an enemy realm.

const OWN_ID: int = 5
const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const ZONE: String = "vado_gris"


## Remote view with everything the prediction reads set by hand.
class FakeView extends RemotePlayerView:
	var fake_id: int = 0
	var fake_kind: int = NetProtocol.EntityKind.PLAYER
	var fake_realm: int = NetProtocol.Realm.SOLMARCH
	var fake_drawn: bool = true
	var fake_action: int = CombatState.Action.NONE
	var fake_position: Vector3 = Vector3.ZERO


	func get_net_id() -> int:
		return fake_id


	func get_kind() -> int:
		return fake_kind


	func get_realm() -> int:
		return fake_realm


	func is_drawn() -> bool:
		return fake_drawn


	func get_drawn_action() -> int:
		return fake_action


	func get_drawn_position() -> Vector3:
		return fake_position


## World that returns the fake views.
class FakeWorld extends RemoteWorld:
	var fake_views: Array[RemotePlayerView] = []


	func get_views() -> Array[RemotePlayerView]:
		return fake_views


## Client with a welcome and a world of fake views (it is never added to the tree: no sockets).
class FakeClient extends NetClient:
	var fake_world: FakeWorld = FakeWorld.new()
	var fake_welcome: NetMessages.Welcome = NetMessages.Welcome.new()


	func get_remote_world() -> RemoteWorld:
		return fake_world


	func get_welcome() -> NetMessages.Welcome:
		return fake_welcome


	func get_net_id() -> int:
		return OWN_ID


var _root: Node3D
var _client: FakeClient
var _feedback: CombatFeedback
var _character: PlayerCharacter
var _views: Array[FakeView] = []
var _predicted: Array = []


func before_each() -> void:
	_predicted.clear()
	_views.clear()
	_root = Node3D.new()
	tree.root.add_child(_root)
	_character = (load(CHARACTER_SCENE_PATH) as PackedScene).instantiate() as PlayerCharacter
	_root.add_child(_character)
	_character.global_position = Vector3.ZERO
	_character.yaw = 0.0
	_client = FakeClient.new()
	_client.fake_welcome.realm = NetProtocol.Realm.VARDHEIM
	_client.fake_welcome.zone_id = ZONE
	_feedback = CombatFeedback.new()
	_root.add_child(_feedback)
	_feedback.setup(_client, null, _character, null, null)
	_feedback.hit_predicted.connect(func(net_id: int, position: Vector3, heavy: bool) -> void:
		_predicted.append({"net_id": net_id, "position": position, "heavy": heavy}))


func after_each() -> void:
	for view: FakeView in _views:
		if is_instance_valid(view):
			view.free()
	_views.clear()
	if is_instance_valid(_client):
		_client.fake_world.free()
		_client.free()
	if is_instance_valid(_root):
		tree.root.remove_child(_root)
		_root.free()
	_root = null
	_client = null
	_feedback = null
	_character = null
	await wait_process_frames()


func _view(net_id: int, position: Vector3, realm: int = NetProtocol.Realm.SOLMARCH, action: int = 0,
		drawn: bool = true) -> FakeView:
	var view := FakeView.new()
	view.fake_id = net_id
	view.fake_position = position
	view.fake_realm = realm
	view.fake_action = action
	view.fake_drawn = drawn
	_views.append(view)
	_client.fake_world.fake_views.append(view)
	return view


func _swing(attack_name: StringName) -> CombatState:
	var state := CombatState.initial(CombatCatalog.rules(), CombatCatalog.default_weapon_id())
	state.action = CombatState.Action.LIGHT
	state.action_id = CombatCatalog.attack_id(attack_name)
	return state


func test_an_enemy_inside_the_sector_is_predicted_with_signal_and_counter() -> void:
	_view(21, Vector3(0.0, 0.0, -1.8))
	_feedback._try_predict(_character, _swing(&"sword_light_1"))
	assert_eq(_feedback.get_predictions_made(), 1, "one prediction made")
	assert_eq(_predicted.size(), 1, "hit_predicted fires once")
	assert_eq(int(_predicted[0]["net_id"]), 21, "for the enemy that was reached")
	assert_vec_near(_predicted[0]["position"], Vector3(0.0, 0.0, -1.8), 0.001, "at the enemy's drawn feet")
	assert_false(bool(_predicted[0]["heavy"]), "a light attack is not heavy")
	assert_eq(_feedback._predicted_attack, CombatCatalog.attack_id(&"sword_light_1"),
			"the attack is remembered so that the confirmed hit does not repeat the effects")
	assert_true(_feedback._predicted_this_swing, "and the swing is marked as predicted")


func test_a_heavy_attack_predicts_a_heavy_hit() -> void:
	_view(21, Vector3(0.0, 0.0, -2.0))
	var state := CombatState.initial(CombatCatalog.rules(), CombatCatalog.default_weapon_id())
	state.action = CombatState.Action.HEAVY
	state.action_id = CombatCatalog.attack_id(&"sword_heavy")
	_feedback._try_predict(_character, state)
	assert_eq(_predicted.size(), 1)
	assert_true(bool(_predicted[0]["heavy"]), "the signal says it is heavy")


func test_an_enemy_outside_the_sector_is_not_predicted() -> void:
	_view(21, Vector3(0.0, 0.0, -9.0))
	_view(22, Vector3(0.0, 0.0, 2.0))
	_feedback._try_predict(_character, _swing(&"sword_light_1"))
	assert_eq(_feedback.get_predictions_made(), 0, "too far and behind the attacker: nothing to predict")
	assert_eq(_predicted.size(), 0, "no signal")
	assert_false(_feedback._predicted_this_swing, "the swing stays open for a later frame")


func test_a_dodging_enemy_is_not_predicted() -> void:
	_view(21, Vector3(0.0, 0.0, -1.8), NetProtocol.Realm.SOLMARCH, CombatState.Action.DODGE)
	_feedback._try_predict(_character, _swing(&"sword_light_1"))
	assert_eq(_predicted.size(), 0, "whoever dodges does not receive the hit")


func test_dead_undrawn_and_allied_views_are_not_valid_targets() -> void:
	var dead: FakeView = _view(21, Vector3(0.0, 0.0, -1.8), NetProtocol.Realm.SOLMARCH, CombatState.Action.DEAD)
	var hidden: FakeView = _view(22, Vector3(0.0, 0.0, -1.8), NetProtocol.Realm.SOLMARCH, 0, false)
	var ally: FakeView = _view(23, Vector3(0.0, 0.0, -1.8), NetProtocol.Realm.VARDHEIM)
	var enemy: FakeView = _view(24, Vector3(0.0, 0.0, -1.8), NetProtocol.Realm.SOLMARCH)
	var npc: FakeView = _view(25, Vector3(0.0, 0.0, -1.8), RealmCatalog.NEUTRAL_CODE)
	assert_false(_feedback.is_valid_target(dead), "a corpse is not a target")
	assert_false(_feedback.is_valid_target(hidden), "a view that is not drawn is not a target")
	assert_false(_feedback.is_valid_target(ally), "nor an ally")
	assert_false(_feedback.is_valid_target(null), "nor nothing")
	assert_true(_feedback.is_valid_target(enemy), "an enemy realm is, in an RvR zone")
	assert_true(_feedback.is_valid_target(npc), "and the neutral side (the Hollow) always")
	_feedback._try_predict(_character, _swing(&"sword_light_1"))
	assert_eq(_predicted.size(), 1, "of all of them, only one prediction comes out")
	assert_true([24, 25].has(int(_predicted[0]["net_id"])), "and it is for a valid target")


func test_an_enemy_realm_is_not_a_target_in_a_safe_zone() -> void:
	_client.fake_welcome.zone_id = "no_such_zone"
	var enemy: FakeView = _view(24, Vector3(0.0, 0.0, -1.8), NetProtocol.Realm.SOLMARCH)
	assert_false(_feedback.is_valid_target(enemy), "enemy realms do not damage each other outside an RvR zone")
	_feedback._try_predict(_character, _swing(&"sword_light_1"))
	assert_eq(_predicted.size(), 0)


func test_the_local_player_never_predicts_a_hit_on_itself() -> void:
	_view(OWN_ID, Vector3(0.0, 0.0, -0.2))
	_feedback._try_predict(_character, _swing(&"sword_light_1"))
	assert_eq(_predicted.size(), 0, "the own view is skipped")


func test_observing_an_active_swing_predicts_once_per_swing() -> void:
	_view(21, Vector3(0.0, 0.0, -1.8))
	var combat := CombatState.initial(CombatCatalog.rules(), CombatCatalog.default_weapon_id())
	var input := PlayerInput.new()
	input.tick = 1000
	ActionMachine.step(combat, input, true)
	input.tick = 1001
	input.buttons = PlayerInput.PRIMARY
	ActionMachine.step(combat, input, true)
	input.buttons = 0
	# Walk the simulation until the swing's active window.
	var guard: int = 0
	while not ActionMachine.is_attack_active(combat, input.tick) and guard < 120:
		input.tick += 1
		ActionMachine.step(combat, input, true)
		guard += 1
	assert_true(ActionMachine.is_attack_active(combat, input.tick), "the swing reached its active phase")
	_character.combat.copy_from(combat)
	_character.last_input_tick = input.tick
	_feedback.observe_action()
	_feedback.observe_action()
	assert_eq(_predicted.size(), 1, "observed twice in the same swing: still one prediction")
	assert_eq(_feedback.get_predictions_made(), 1)
