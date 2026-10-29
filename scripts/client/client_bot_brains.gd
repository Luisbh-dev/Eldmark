class_name ClientBotBrains
extends RefCounted
## El cerebro con el que juega un bot del cliente en red ([code]--bot[/code]; ver [OnlineMain] y
## [NetHarness]), según su configuración:
## [br]- con un modo de combate del bot tramposo ([BotCheater.COMBAT_MODES]): el cerebro de ese modo
## ([method BotCheater.make_brain]), que ve también a los PNJ (los maniquíes) como enemigos;
## [br]- con [code]--bot-brain=combat[/code]: [constant BotBrain.Pattern.COMBAT], que busca al enemigo
## más cercano que dibuja su [RemoteWorld] ([BotEnemySight]), se acerca, ataca, bloquea y esquiva;
## [br]- si no, [constant BotBrain.Pattern.WANDER]: pasea alrededor de su punto de aparición.


## Crea el cerebro del bot [param client] (en el mundo, con su personaje) para la configuración
## [param config]; [param home] es el punto alrededor del que pasea y [param radius] el radio del paseo.
static func make(client: NetClient, config: ClientConfig, home: Vector3, radius: float) -> BotBrain:
	var cheater: BotCheater = client.get_cheater()
	if cheater != null and cheater.is_combat_mode():
		var cheat_sight := BotEnemySight.new(client, true)
		return cheater.make_brain(func(position: Vector3) -> Variant: return cheat_sight.find(position),
				home, radius)
	if config.bot_brain == ClientConfig.BOT_BRAIN_COMBAT:
		var sight := BotEnemySight.new(client)
		var brain := BotBrain.new(config.bot_seed, BotBrain.Pattern.COMBAT, home, radius)
		brain.set_enemy_finder(func(position: Vector3) -> Variant: return sight.find(position))
		return brain
	return BotBrain.new(config.bot_seed, BotBrain.Pattern.WANDER, home, radius)
