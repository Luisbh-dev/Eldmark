class_name ClientBotBrains
extends RefCounted
## El cerebro con el que juega un bot del cliente en red ([code]--bot[/code]; ver [OnlineMain] y
## [NetHarness]), según su configuración:
## [br]- con un modo de combate del bot tramposo ([BotCheater.COMBAT_MODES]): el cerebro de ese modo
## ([method BotCheater.make_brain]), que ve también a los PNJ (los maniquíes) como enemigos;
## [br]- con [code]--bot-brain=combat[/code]: [constant BotBrain.Pattern.COMBAT], que busca al enemigo
## más cercano que dibuja su [RemoteWorld] ([BotEnemySight]), se acerca, ataca, bloquea y esquiva;
## [br]- con [code]--bot-brain=siege[/code] (GUE-15): [constant BotBrain.Pattern.SIEGE]. Asedia o defiende el fuerte
## de la zona: el [SiegeView] lo llena [FortressView] (lo que el cliente dibuja de la fortaleza) y, de
## respaldo, las posiciones de [code]data/routes/<zona>.tres[/code]; los enemigos son los remotos que dibuja su
## [RemoteWorld], también los PNJ de guerra ([BotEnemySight]), a los que busca primero, los golpes avisados
## (TELEGRAPH) que evita le llegan por [signal NetClient.telegraph_received] ([BotThreatSight], solo los de PNJ que le
## pueden dañar: [method BotThreatSight.is_hostile_view]) y a los suyos los cuenta
## en el punto de reunión de su campamento con [BotAllySight] (GUE-44);
## [br]- si no, [constant BotBrain.Pattern.WANDER]: pasea alrededor de su punto de aparición.
## [br][br]
## Los cerebros de combate y de asedio pelean con el kit de la fase 4 (H5; docs/habilidades.md, sección 7.1,
## [method give_kit_senses]): leen el estado de combate predicho del personaje, la vida del bloque extra, los
## enemigos con su velocidad dibujada y su derribo y los aliados derribados que dibuja el [RemoteWorld]. Los del
## bot tramposo no: juegan como en la fase 3 (lo tramposo es otra cosa).


## Crea el cerebro del bot [param client] (en el mundo, con su personaje) para la configuración
## [param config]; [param home] es el punto alrededor del que pasea y [param radius] el radio del paseo.
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


## Le da a [param brain] lo que necesita el kit de la fase 4 (H5): los enemigos de [param sight] como
## [BotTarget] (posición y velocidad dibujadas y derribo), el estado de combate predicho del personaje de
## [param client] (el de después del último paso de la predicción, con el que se decide la entrada del
## siguiente), su vida del bloque extra y los aliados derribados que dibuja.
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


# El cerebro de asedio de un bot del cliente: su reino es el del WELCOME, las rutas las de la zona y el
# SiegeView se pone al día cada vez que FortressView muestra un estado nuevo.
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
	# Solo los golpes avisados de quien puede dañarle (como los falsos del servidor): no los de la guarnición de su reino.
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
	brain.set_siege(view, routes, realm)
	return brain


# Copia a [param view] el estado que dibuja [param fortress_view] de su primera fortaleza y, si la escena está
# enlazada, las posiciones reales de la puerta y el círculo.
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
