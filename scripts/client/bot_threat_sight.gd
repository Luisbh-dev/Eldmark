class_name BotThreatSight
extends RefCounted
## The telegraphed attacks that a client bot knows about (the [code]threat_finder[/code] of
## [constant BotBrain.Pattern.SIEGE], F6b): it stores each TELEGRAPH that reaches it (ENTITY_EVENT
## 6, docs/fortress.md section 5) as a [BotBrain.Threat] and treats it as active until its impact
## and the attack's active window have passed. It is used by [SwarmBot] ([code]--bots[/code]) and
## [ClientBotBrains] ([code]--bot[/code]).
## [br][br]
## The telegraph carries only the origin, the facing and the zone's reach, and the time left until
## impact; the tick it is queried with is that of the input being decided (the one the server will
## simulate it with), so a bot that is ahead of the server counts the attack as past at the same
## moment it happens. An NPC that telegraphs another attack replaces the previous one.
## [br][br]
## It stores only the attacks of whoever can damage the bot (the contract of [method BotBrain.set_threat_finder]), just like the server's fake players
## ([code]ZoneServer._find_threats[/code], which keeps the NPCs of a hostile realm): the server
## telegraphs the attacks of all NPCs, including those of the bot's own garrison, and those need
## not be dodged. Whoever creates it provides the rule ([code]is_hostile[/code]): [SwarmBot], the
## enemy war NPCs it knows from their spawns; [ClientBotBrains], [method is_hostile_view] with its
## [RemoteWorld]. Without a rule it stores all of them.

## Ticks the attack stays active after impact (the active window of the Captain's attack lasts 12).
const ACTIVE_TICKS: int = 12

# net_id of the NPC -> attack, and tick until which it lasts.
var _threats: Dictionary[int, BotBrain.Threat] = {}
var _until: Dictionary[int, int] = {}
# (net_id: int) -> bool: true if whoever telegraphs can damage the bot. Without it, all count.
var _is_hostile: Callable = Callable()


## [param is_hostile] ([code](net_id: int) -> bool[/code]) says whether the NPC that telegraphs
## can damage the bot; the others' telegraphs are ignored. Without it (the class's tests) all are stored.
func _init(is_hostile: Callable = Callable()) -> void:
	_is_hostile = is_hostile


## true if the remote [param net_id] drawn by [param world] can damage a bot of realm [param realm] in zone [param zone_id] ([method FactionRules.can_damage]). One whose spawn has not
## arrived does not count: the server only telegraphs to whoever already has it, so it is not
## known whose it is.
static func is_hostile_view(world: RemoteWorld, realm: int, zone_id: StringName, net_id: int) -> bool:
	if world == null:
		return false
	var view: RemotePlayerView = world.get_view(net_id)
	return view != null and FactionRules.can_damage(view.get_realm(), realm, zone_id)


## Records [param event] if it is a TELEGRAPH from whoever can damage the bot (other events do nothing).
func note(event: NetMessages.EntityEvent) -> void:
	if event == null or event.event != NetMessages.EntityEvent.Kind.TELEGRAPH:
		return
	if _is_hostile.is_valid() and not bool(_is_hostile.call(event.net_id)):
		return
	_threats[event.net_id] = BotBrain.Threat.new(event.position, event.yaw, event.get_radius())
	_until[event.net_id] = event.tick + event.impact_in_ticks + ACTIVE_TICKS


## The attacks still active at tick [param tick]; it forgets those that have already passed.
func find(tick: int) -> Array[BotBrain.Threat]:
	var active: Array[BotBrain.Threat] = []
	for net_id: int in _until.keys():
		if tick > _until[net_id]:
			_until.erase(net_id)
			_threats.erase(net_id)
		else:
			active.append(_threats[net_id])
	return active


## Forgets an NPC (its DESPAWN).
func forget(net_id: int) -> void:
	_until.erase(net_id)
	_threats.erase(net_id)


## How many attacks it remembers (active or not yet checked).
func size() -> int:
	return _until.size()
