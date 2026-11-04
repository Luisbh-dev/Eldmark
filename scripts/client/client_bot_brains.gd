class_name ClientBotBrains
extends RefCounted
## The brain a networked client bot plays with ([code]--bot[/code]; see [OnlineMain] and
## [NetHarness]), according to its configuration:
## [br]- with a cheating-bot combat mode ([BotCheater.COMBAT_MODES]): the brain of that mode
## ([method BotCheater.make_brain]), which also sees NPCs (the dummies) as enemies;
## [br]- with [code]--bot-brain=combat[/code]: [constant BotBrain.Pattern.COMBAT], which looks for the
## nearest enemy drawn by its [RemoteWorld] ([BotEnemySight]), approaches, attacks, blocks and dodges;
## [br]- with [code]--bot-brain=siege[/code] (GUE-15): [constant BotBrain.Pattern.SIEGE]. Besieges or
## defends the zone's fort: the [SiegeView] is filled by [FortressView] (what the client draws of the
## fortress) and, as a fallback, by the positions in [code]data/routes/<zone>.tres[/code]; the enemies
## are the remote ones drawn by its [RemoteWorld], also the war NPCs ([BotEnemySight]), which it
## targets first; the telegraphed hits (TELEGRAPH) it avoids reach it through
## [signal NetClient.telegraph_received] ([BotThreatSight], only those of NPCs that can hurt it:
## [method BotThreatSight.is_hostile_view]); it counts its own side at its camp's rally point with
## [BotAllySight] (GUE-44); and the kit's bow only fires if the arrow gets through, using the ray of
## [method BotBrain.bow_sight_clear] in the client's world ([method BotBrain.set_line_of_sight]);
## [br]- otherwise, [constant BotBrain.Pattern.WANDER]: it strolls around its spawn point.
## [br][br]
## The combat and siege brains fight with the phase 4 kit (H5; docs/habilidades.md, section 7.1,
## [method give_kit_senses]): they read the character's predicted combat state, the extra block's
## health, the enemies with their drawn velocity and knockdown, and the downed allies drawn by the
## [RemoteWorld]. The cheating bot's brains do not: they play as in phase 3 (cheating is a different
## matter).


## Creates the brain of bot [param client] (in the world, with its character) for configuration
## [param config]; [param home] is the point it strolls around and [param radius] the stroll radius.
static func make(client: NetClient, config: ClientConfig, home: Vector3, radius: float) -> BotBrain:
	var cheater: BotCheater = client.get_cheater()
	if cheater != null and cheater.is_combat_mode():
		var cheat_sight := BotEnemySight.new(client, true)
		return cheater.make_brain(func(position: Vector3) -> Variant: return cheat_sight.find(position),
				home, radius)
	if config.bot_brain == ClientConfig.BOT_BRAIN_SIEGE:
		return _make_siege(client, config, home, radius)
	if config.bot_brain == ClientConfig.BOT_BRAIN_COMBAT:
		var sight := BotEnemySight.new(client)
		var brain := BotBrain.new(config.bot_seed, BotBrain.Pattern.COMBAT, home, radius)
		give_kit_senses(brain, client, sight)
		return brain
	return BotBrain.new(config.bot_seed, BotBrain.Pattern.WANDER, home, radius)


## Gives [param brain] what the phase 4 kit (H5) needs: the enemies of [param sight] as [BotTarget]
## (drawn position and velocity, and knockdown), the predicted combat state of [param client]'s
## character (the one after the last prediction step, which is used to decide the next step's input),
## its extra block health and the downed allies it draws.
static func give_kit_senses(brain: BotBrain, client: NetClient, sight: BotEnemySight) -> void:
	brain.set_enemy_finder(func(position: Vector3) -> Variant: return sight.find_target(position))
	brain.set_ally_finder(func(position: Vector3) -> Variant: return sight.find_downed_ally(position))
	brain.set_combat_source(func() -> CombatState:
		var character: PlayerCharacter = client.get_character()
		return character.combat if is_instance_valid(character) else null)
	brain.set_health_source(func() -> float:
		if not client.has_health() or client.get_max_health() <= 0:
			return 1.0
		return float(client.get_health()) / float(client.get_max_health()))


# The siege brain of a client bot: its realm is the WELCOME's, the routes are the zone's, and the
# SiegeView is updated every time FortressView shows a new state.
static func _make_siege(client: NetClient, config: ClientConfig, home: Vector3, radius: float) -> BotBrain:
	var welcome: NetMessages.Welcome = client.get_welcome()
	var realm: int = welcome.realm if welcome != null else config.realm
	var routes: ApproachRoutes = null
	if welcome != null:
		var path: String = "res://data/routes/%s.tres" % welcome.zone_id
		if ResourceLoader.exists(path):
			routes = load(path) as ApproachRoutes
	var view := SiegeView.new()
	view.set_places_from_routes(routes)
	var fortress_view: FortressView = client.get_fortress_view()
	_refresh_siege_view(view, fortress_view)
	fortress_view.state_changed.connect(func(_net_id: int, _state: FortressState,
			_previous: FortressState) -> void: _refresh_siege_view(view, fortress_view))
	var sight := BotEnemySight.new(client, false, true)
	var defenders := BotEnemySight.new(client, false, true, true)
	# Only the telegraphed hits from whoever can hurt it (like the server's fake ones): not those of its realm's garrison.
	var zone_id: StringName = StringName(welcome.zone_id) if welcome != null else &""
	var threats := BotThreatSight.new(func(net_id: int) -> bool:
		return BotThreatSight.is_hostile_view(client.get_remote_world(), realm, zone_id, net_id))
	client.telegraph_received.connect(threats.note)
	var prediction: ClientPrediction = client.get_prediction()
	var brain := BotBrain.new(config.bot_seed, BotBrain.Pattern.SIEGE, home, radius)
	give_kit_senses(brain, client, sight)
	brain.set_defender_finder(func(position: Vector3) -> Variant: return defenders.find_target(position))
	brain.set_threat_finder(func(_position: Vector3) -> Array[BotBrain.Threat]:
		return threats.find(prediction.get_predicted_tick()))
	var allies := BotAllySight.new(client)
	brain.set_ally_counter(func(center: Vector3, radius: float) -> int: return allies.count(center, radius))
	# The bow only fires if the arrow gets through: the same ray as the server, in the client's world (its
	# FortGate closes and opens with the fortress state).
	brain.set_line_of_sight(func(from_feet: Vector3, to_feet: Vector3, left_shoulder: bool) -> bool:
		var character: PlayerCharacter = client.get_character()
		if not is_instance_valid(character) or not character.is_inside_tree():
			return true
		return BotBrain.bow_sight_clear(character.get_world_3d().direct_space_state, from_feet, to_feet,
				left_shoulder))
	brain.set_siege(view, routes, realm)
	return brain


# Copies to [param view] the state that [param fortress_view] draws for its first fortress and, if the
# scene is linked, the real positions of the gate and the circle.
static func _refresh_siege_view(view: SiegeView, fortress_view: FortressView) -> void:
	var net_id: int = fortress_view.get_primary_id()
	if net_id == 0:
		return
	var state: FortressState = fortress_view.get_displayed_state(net_id)
	if state != null:
		view.update_from_state(state)
	var gate: Vector3 = fortress_view.get_gate_position(net_id)
	var circle: Vector3 = fortress_view.get_circle_center(net_id)
	var circle_radius: float = fortress_view.get_circle_radius(net_id)
	if gate.is_finite() and circle.is_finite() and circle_radius > 0.0:
		view.set_places(gate, circle, circle_radius)
