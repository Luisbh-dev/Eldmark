class_name DownedNotice
extends Control
## Knocked-down notices (CMB-28, docs/habilidades.md, section 6.5), at the top center of the screen:
## [br]- Knocked down: "Derribado" (knocked down) with the countdown of the knocked-down health (that of the extra block, which drops
## 1 every [code]downed_s / downed_health[/code] s and with enemy damage).
## [br]- "Ana te está levantando" (Ana is reviving you) with the bar of her INTERACT 1, or "¡Te rematan!" (you are being finished off!) with that of her INTERACT 4.
## [br]- Standing and near a knocked-down ally (drawn positions and DOWNED action in its record):
## "Mantén E para levantar a Ana" (hold E to revive Ana); and while reviving someone, "Levantando a Ana" (reviving Ana) with its bar.
## [br][br]
## It does not read the network: the [HUD] passes it the combat events ([method handle_event]: INTERACT, DOWNED, DEATH and
## RESPAWN) and, every frame, if the player is knocked down, their health, the estimated server tick and who
## can be revived ([method update_view]). Names are given by [member name_of]. Client only.
## [br][br]
## The server lets one ally revive and one or more enemies finish off the same knocked-down player at once: each
## interaction on the local player is stored with its actor and only the end or interruption of that actor removes it
## (or standing up, dying or respawning); the finisher is shown before the revive (phase 4 review).

## What is being done to the local player or what they are doing.
enum Interaction { NONE, BEING_REVIVED, BEING_EXECUTED, REVIVING, EXECUTING }

const TITLE_FONT_SIZE: int = 34
const TEXT_FONT_SIZE: int = 20
const BAR_SIZE: Vector2 = Vector2(320.0, 12.0)
## Width of the text column, centered on the screen.
const COLUMN_WIDTH: float = BAR_SIZE.x + 80.0
const DOWNED_COLOR: Color = Color(0.78, 0.74, 0.92, 1.0)
const REVIVE_COLOR: Color = Color(0.4, 0.85, 0.45, 1.0)
const EXECUTE_COLOR: Color = Color(0.95, 0.2, 0.15, 1.0)
const BAR_BACK: Color = Color(0.03, 0.03, 0.04, 0.75)
## From the top of the screen (px). Below the boss bar (BossBar.TOP_OFFSET 316 + about 52 of height) and the notice band (WarBanners.TOP_OFFSET),
## which shows throughout the fort, so that the countdown does not overlap with it.
const TOP_OFFSET: float = 374.0

## Ticks after the expected end of an interaction after which it is forgotten if its end event does not arrive.
const FORGET_AFTER_TICKS: int = 30

## Name of an entity by its net_id ([code]func(net_id: int) -> String[/code]); empty if unknown.
var name_of: Callable = Callable()

var _own_id: int = 0
# Reviving and finishing off on the local player, each with its actor (in the order they started).
var _on_me: Array[_Ongoing] = []
# What the local player is doing (reviving or finishing off another), or null.
var _mine: _Ongoing = null
var _column: VBoxContainer = null
var _title: Label = null
var _countdown: Label = null
var _detail: Label = null
var _bar: ProgressBar = null
var _prompt: Label = null


# An interaction in progress: what it is ([enum Interaction]), with whom (who acts on the local player or who
# the local player revives or finishes off) and its ticks.
class _Ongoing:
	var interaction: int = Interaction.NONE
	var other_id: int = 0
	var start_tick: int = 0
	var end_tick: int = 0


func _init() -> void:
	name = "AvisoDerribado"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()


## Network id of the local player.
func set_own_id(net_id: int) -> void:
	_own_id = net_id


## An already timed ENTITY_EVENT: the INTERACTs where the local player is the knocked-down one or the actor
## start or end reviving and finishing off (the end or interruption removes only that of its actor; revived, all those that
## there were on them); their DOWNED, DEATH or RESPAWN clears everything.
func handle_event(event: NetMessages.EntityEvent) -> void:
	if event == null or _own_id == 0:
		return
	match event.event:
		NetMessages.EntityEvent.Kind.INTERACT:
			var on_me: bool = event.net_id == _own_id
			var by_me: bool = event.actor == _own_id
			if not on_me and not by_me:
				return
			match event.op:
				NetMessages.EntityEvent.InteractOp.REVIVE:
					_start(Interaction.BEING_REVIVED if on_me else Interaction.REVIVING, event)
				NetMessages.EntityEvent.InteractOp.EXECUTE:
					_start(Interaction.BEING_EXECUTED if on_me else Interaction.EXECUTING, event)
				NetMessages.EntityEvent.InteractOp.REVIVED:
					if on_me:
						# Standing: they are no longer being revived or finished off.
						_on_me.clear()
					else:
						_end_mine(Interaction.REVIVING, event.net_id)
				NetMessages.EntityEvent.InteractOp.REVIVE_CUT:
					if on_me:
						_end_on_me(Interaction.BEING_REVIVED, event.actor)
					else:
						_end_mine(Interaction.REVIVING, event.net_id)
				NetMessages.EntityEvent.InteractOp.EXECUTE_CUT:
					if on_me:
						_end_on_me(Interaction.BEING_EXECUTED, event.actor)
					else:
						_end_mine(Interaction.EXECUTING, event.net_id)
		NetMessages.EntityEvent.Kind.DOWNED, NetMessages.EntityEvent.Kind.DEATH, \
				NetMessages.EntityEvent.Kind.RESPAWN:
			if event.net_id == _own_id:
				_on_me.clear()
				_mine = null


## Brings the notice up to date: [param downed] if the player is knocked down, with [param downed_health] of
## knocked-down health; [param tick], the estimated server tick; [param revive_target], the knocked-down ally
## that can be revived (0 = none; only counts while standing).
func update_view(downed: bool, downed_health: int, tick: int, revive_target: int = 0) -> void:
	_forget_stale(tick)
	_title.visible = downed
	_countdown.visible = downed
	_prompt.visible = false
	_detail.visible = false
	_bar.visible = false
	if downed:
		_countdown.text = CombatText.TEXT_DOWNED_COUNTDOWN % seconds_left(downed_health)
		var shown: _Ongoing = _shown_on_me()
		if shown != null and shown.interaction == Interaction.BEING_REVIVED:
			var who: String = _name(shown.other_id)
			_show_bar(CombatText.TEXT_BEING_REVIVED_BY % who if not who.is_empty()
					else CombatText.TEXT_BEING_REVIVED, REVIVE_COLOR, tick, shown)
		elif shown != null and shown.interaction == Interaction.BEING_EXECUTED:
			_show_bar(CombatText.TEXT_BEING_EXECUTED, EXECUTE_COLOR, tick, shown)
	elif _mine != null and _mine.interaction == Interaction.REVIVING:
		_show_bar(CombatText.TEXT_REVIVING % _name_or_ally(_mine.other_id), REVIVE_COLOR, tick, _mine)
	elif revive_target != 0:
		_prompt.visible = true
		_prompt.text = CombatText.TEXT_REVIVE_PROMPT % [UIKeyGlyph.label_for_action(&"interact"),
				_name_or_ally(revive_target)]
	visible = _title.visible or _prompt.visible or _detail.visible


## Seconds (rounded up) left to a knocked-down player with [param downed_health] of knocked-down health
## at the pace of the bleed-out ([member CombatRules.downed_s] for [member CombatRules.downed_health]).
static func seconds_left(downed_health: int) -> int:
	var rules: CombatRules = CombatCatalog.rules()
	var ticks_per_point: float = float(CombatCatalog.tables().downed_ticks) / float(maxi(rules.downed_health, 1))
	return ceili(float(maxi(downed_health, 0)) * ticks_per_point / float(Engine.physics_ticks_per_second))


## The nearest knocked-down ally that [param own_feet] can revive: a remote of their realm that is
## drawn with the DOWNED action, at [member CombatRules.interact_range_m] or less horizontally and with
## [code]|Δy| ≤ 1.5[/code] (the same the server checks, without line of sight); ties broken by net_id.
## Returns its net_id or 0.
static func find_downed_ally(world: RemoteWorld, own_feet: Vector3, own_realm: int) -> int:
	if world == null or own_realm == NetProtocol.Realm.NONE:
		return 0
	var reach: float = CombatCatalog.rules().interact_range_m
	var best: int = 0
	var best_distance: float = INF
	for view: RemotePlayerView in world.get_views():
		if not view.is_drawn() or view.get_realm() != own_realm \
				or view.get_kind() != NetProtocol.EntityKind.PLAYER \
				or (view.get_drawn_action() & 15) != CombatState.Action.DOWNED:
			continue
		var feet: Vector3 = view.get_drawn_position()
		if absf(feet.y - own_feet.y) > 1.5:
			continue
		var distance: float = Vector2(feet.x - own_feet.x, feet.z - own_feet.z).length()
		if distance > reach:
			continue
		if distance < best_distance or (distance == best_distance and view.get_net_id() < best):
			best = view.get_net_id()
			best_distance = distance
	return best


## What is being done now ([enum Interaction]): on the local player, the finisher before the
## revive; otherwise, what they do.
func get_interaction() -> int:
	var shown: _Ongoing = _shown_on_me()
	if shown != null:
		return shown.interaction
	return _mine.interaction if _mine != null else Interaction.NONE


func get_title_text() -> String:
	return _title.text if _title.visible else ""


func get_countdown_text() -> String:
	return _countdown.text if _countdown.visible else ""


## The revive or finish-off line (empty if none).
func get_detail_text() -> String:
	return _detail.text if _detail.visible else ""


## The prompt to revive an ally (empty if none).
func get_prompt_text() -> String:
	return _prompt.text if _prompt.visible else ""


## Progress (0 to 1) of the revive or finish-off bar (-1 if not visible).
func get_progress() -> float:
	return _bar.value / _bar.max_value if _bar.visible else -1.0


func _start(interaction: int, event: NetMessages.EntityEvent) -> void:
	var ongoing := _Ongoing.new()
	ongoing.interaction = interaction
	ongoing.start_tick = event.tick
	ongoing.end_tick = maxi(event.end_tick, event.tick + 1)
	if event.net_id == _own_id:
		# An actor does one thing at a time: the new one replaces whatever it had.
		ongoing.other_id = event.actor
		_forget_actor(event.actor)
		_on_me.append(ongoing)
	else:
		ongoing.other_id = event.net_id
		_mine = ongoing


# Removes what [param actor] was doing to the local player.
func _forget_actor(actor: int) -> void:
	for index: int in range(_on_me.size() - 1, -1, -1):
		if _on_me[index].other_id == actor:
			_on_me.remove_at(index)


# The end or interruption of [param interaction] by [param actor] on the local player: removes only its own.
func _end_on_me(interaction: int, actor: int) -> void:
	for index: int in range(_on_me.size() - 1, -1, -1):
		if _on_me[index].other_id == actor and _on_me[index].interaction == interaction:
			_on_me.remove_at(index)


# The end or interruption of what the local player does ([param interaction] with [param target]).
func _end_mine(interaction: int, target: int) -> void:
	if _mine != null and _mine.interaction == interaction and _mine.other_id == target:
		_mine = null


# The end (revived, finished off or interrupted) arrives by event; if it was lost from sight, it is forgotten
# [constant FORGET_AFTER_TICKS] ticks after its expected end.
func _forget_stale(tick: int) -> void:
	for index: int in range(_on_me.size() - 1, -1, -1):
		if tick >= _on_me[index].end_tick + FORGET_AFTER_TICKS:
			_on_me.remove_at(index)
	if _mine != null and tick >= _mine.end_tick + FORGET_AFTER_TICKS:
		_mine = null


# What is shown on the local player: the finisher that ends first and, if there is none, the revive; or null.
func _shown_on_me() -> _Ongoing:
	var shown: _Ongoing = null
	for ongoing: _Ongoing in _on_me:
		if shown == null:
			shown = ongoing
		elif ongoing.interaction == Interaction.BEING_EXECUTED:
			if shown.interaction != Interaction.BEING_EXECUTED or ongoing.end_tick < shown.end_tick:
				shown = ongoing
	return shown


func _show_bar(text: String, color: Color, tick: int, ongoing: _Ongoing) -> void:
	_detail.visible = true
	_detail.text = text
	_bar.visible = true
	_bar.value = clampf(float(tick - ongoing.start_tick)
			/ float(maxi(ongoing.end_tick - ongoing.start_tick, 1)), 0.0, 1.0) * _bar.max_value
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	_bar.add_theme_stylebox_override(&"fill", fill)


func _name(net_id: int) -> String:
	return String(name_of.call(net_id)) if name_of.is_valid() and net_id != 0 else ""


func _name_or_ally(net_id: int) -> String:
	var found: String = _name(net_id)
	return found if not found.is_empty() else CombatText.TEXT_ALLY


func _build() -> void:
	# Full screen (that is how the HUD places it too): the column is centered relative to the parent, whatever its size
	# (UI-49; before, it assumed a centered parent of width 0 and came out cut off on the left).
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_column = VBoxContainer.new()
	_column.name = "Columna"
	_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.alignment = BoxContainer.ALIGNMENT_CENTER
	_column.add_theme_constant_override(&"separation", 6)
	_column.custom_minimum_size = Vector2(COLUMN_WIDTH, 0.0)
	UILayout.anchor_top_center(_column, COLUMN_WIDTH, TOP_OFFSET)
	add_child(_column)
	_title = _make_label("Titulo", CombatText.TEXT_DOWNED, TITLE_FONT_SIZE, DOWNED_COLOR)
	_countdown = _make_label("Cuenta", "", TEXT_FONT_SIZE, Color.WHITE)
	_detail = _make_label("Detalle", "", TEXT_FONT_SIZE, Color.WHITE)
	_bar = ProgressBar.new()
	_bar.name = "Barra"
	_bar.custom_minimum_size = BAR_SIZE
	_bar.show_percentage = false
	_bar.max_value = 100.0
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var back := StyleBoxFlat.new()
	back.bg_color = BAR_BACK
	_bar.add_theme_stylebox_override(&"background", back)
	_column.add_child(_bar)
	_prompt = _make_label("Invitacion", "", TEXT_FONT_SIZE, REVIVE_COLOR)
	for item: CanvasItem in [_title, _countdown, _detail, _bar, _prompt]:
		item.visible = false
	visible = false


func _make_label(label_name: String, text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.name = label_name
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override(&"font_size", font_size)
	label.add_theme_color_override(&"font_color", color)
	label.add_theme_color_override(&"font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
	label.add_theme_constant_override(&"outline_size", 6)
	_column.add_child(label)
	return label
