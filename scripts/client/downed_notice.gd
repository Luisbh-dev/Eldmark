class_name DownedNotice
extends Control
## Avisos de derribado (CMB-28, docs/habilidades.md, sección 6.5), arriba en el centro de la pantalla:
## [br]- Derribado: «Derribado» con la cuenta atrás de la vida de derribado (la del bloque extra, que baja
## 1 cada [code]downed_s / downed_health[/code] s y con el daño enemigo).
## [br]- «Ana te está levantando» con la barra de su INTERACT 1, o «¡Te rematan!» con la de su INTERACT 4.
## [br]- En pie y cerca de un aliado derribado (posiciones dibujadas y acción DOWNED de su registro):
## «Mantén E para levantar a Ana»; y mientras se levanta a alguien, «Levantando a Ana» con su barra.
## [br][br]
## No lee la red: el [HUD] le pasa los eventos de combate ([method handle_event]: INTERACT, DOWNED, DEATH y
## RESPAWN) y, cada fotograma, si el jugador está derribado, su vida, el tick del servidor estimado y a quién
## se puede levantar ([method update_view]). Los nombres los da [member name_of]. Solo cliente.

## Lo que se está haciendo con el jugador local o lo que hace él.
enum Interaction { NONE, BEING_REVIVED, BEING_EXECUTED, REVIVING, EXECUTING }

const TITLE_FONT_SIZE: int = 34
const TEXT_FONT_SIZE: int = 20
const BAR_SIZE: Vector2 = Vector2(320.0, 12.0)
const DOWNED_COLOR: Color = Color(0.95, 0.55, 0.15, 1.0)
const REVIVE_COLOR: Color = Color(0.4, 0.85, 0.45, 1.0)
const EXECUTE_COLOR: Color = Color(0.95, 0.2, 0.15, 1.0)
const BAR_BACK: Color = Color(0.03, 0.03, 0.04, 0.75)
## Desde lo alto de la pantalla (px).
const TOP_OFFSET: float = 150.0

## Nombre de una entidad por su net_id ([code]func(net_id: int) -> String[/code]); vacío si no se sabe.
var name_of: Callable = Callable()

var _own_id: int = 0
var _interaction: int = Interaction.NONE
var _other_id: int = 0
var _start_tick: int = 0
var _end_tick: int = 0
var _column: VBoxContainer = null
var _title: Label = null
var _countdown: Label = null
var _detail: Label = null
var _bar: ProgressBar = null
var _prompt: Label = null


func _init() -> void:
	name = "AvisoDerribado"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()


## Id de red del jugador local.
func set_own_id(net_id: int) -> void:
	_own_id = net_id


## Un ENTITY_EVENT ya temporizado: los INTERACT donde el jugador local es el derribado o quien actúa
## empiezan o acaban levantar y rematar; su DOWNED, DEATH o RESPAWN lo borra todo.
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
				_:
					_interaction = Interaction.NONE
		NetMessages.EntityEvent.Kind.DOWNED, NetMessages.EntityEvent.Kind.DEATH, \
				NetMessages.EntityEvent.Kind.RESPAWN:
			if event.net_id == _own_id:
				_interaction = Interaction.NONE


## Pone el aviso al día: [param downed] si el jugador está derribado, con [param downed_health] de vida de
## derribado; [param tick], el tick del servidor estimado; [param revive_target], el aliado derribado al
## que se puede levantar (0 = ninguno; solo cuenta en pie).
func update_view(downed: bool, downed_health: int, tick: int, revive_target: int = 0) -> void:
	var interaction: int = _interaction
	if interaction != Interaction.NONE and tick >= _end_tick + 30:
		# El final (levantado, rematado o cortado) llega por evento; si se perdió de vista, se olvida.
		_interaction = Interaction.NONE
		interaction = Interaction.NONE
	_title.visible = downed
	_countdown.visible = downed
	_prompt.visible = false
	_detail.visible = false
	_bar.visible = false
	if downed:
		_countdown.text = CombatText.TEXT_DOWNED_COUNTDOWN % seconds_left(downed_health)
		if interaction == Interaction.BEING_REVIVED:
			var who: String = _name(_other_id)
			_show_bar(CombatText.TEXT_BEING_REVIVED_BY % who if not who.is_empty()
					else CombatText.TEXT_BEING_REVIVED, REVIVE_COLOR, tick)
		elif interaction == Interaction.BEING_EXECUTED:
			_show_bar(CombatText.TEXT_BEING_EXECUTED, EXECUTE_COLOR, tick)
	elif interaction == Interaction.REVIVING:
		_show_bar(CombatText.TEXT_REVIVING % _name_or_ally(_other_id), REVIVE_COLOR, tick)
	elif revive_target != 0:
		_prompt.visible = true
		_prompt.text = CombatText.TEXT_REVIVE_PROMPT % [UIKeyGlyph.label_for_action(&"interact"),
				_name_or_ally(revive_target)]
	visible = _title.visible or _prompt.visible or _detail.visible


## Segundos (hacia arriba) que le quedan a un derribado con [param downed_health] de vida de derribado
## al ritmo del desangrado ([member CombatRules.downed_s] para [member CombatRules.downed_health]).
static func seconds_left(downed_health: int) -> int:
	var rules: CombatRules = CombatCatalog.rules()
	var ticks_per_point: float = float(CombatCatalog.tables().downed_ticks) / float(maxi(rules.downed_health, 1))
	return ceili(float(maxi(downed_health, 0)) * ticks_per_point / float(Engine.physics_ticks_per_second))


## El aliado derribado más cercano al que [param own_feet] puede levantar: un remoto de su reino que se
## dibuja con la acción DOWNED, a [member CombatRules.interact_range_m] o menos en horizontal y con
## [code]|Δy| ≤ 1,5[/code] (lo mismo que mira el servidor, sin la línea de visión); empate por net_id.
## Devuelve su net_id o 0.
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


## Lo que se está haciendo ahora ([enum Interaction]).
func get_interaction() -> int:
	return _interaction


func get_title_text() -> String:
	return _title.text if _title.visible else ""


func get_countdown_text() -> String:
	return _countdown.text if _countdown.visible else ""


## La línea de levantar o rematar (vacía si no hay).
func get_detail_text() -> String:
	return _detail.text if _detail.visible else ""


## La invitación a levantar a un aliado (vacía si no hay).
func get_prompt_text() -> String:
	return _prompt.text if _prompt.visible else ""


## Progreso (0 a 1) de la barra de levantar o rematar (-1 si no se ve).
func get_progress() -> float:
	return _bar.value / _bar.max_value if _bar.visible else -1.0


func _start(interaction: int, event: NetMessages.EntityEvent) -> void:
	_interaction = interaction
	_other_id = event.actor if event.net_id == _own_id else event.net_id
	_start_tick = event.tick
	_end_tick = maxi(event.end_tick, event.tick + 1)


func _show_bar(text: String, color: Color, tick: int) -> void:
	_detail.visible = true
	_detail.text = text
	_bar.visible = true
	_bar.value = clampf(float(tick - _start_tick) / float(maxi(_end_tick - _start_tick, 1)), 0.0, 1.0) \
			* _bar.max_value
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	_bar.add_theme_stylebox_override(&"fill", fill)


func _name(net_id: int) -> String:
	return String(name_of.call(net_id)) if name_of.is_valid() and net_id != 0 else ""


func _name_or_ally(net_id: int) -> String:
	var found: String = _name(net_id)
	return found if not found.is_empty() else CombatText.TEXT_ALLY


func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_column = VBoxContainer.new()
	_column.name = "Columna"
	_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.alignment = BoxContainer.ALIGNMENT_CENTER
	_column.add_theme_constant_override(&"separation", 6)
	_column.custom_minimum_size = Vector2(BAR_SIZE.x + 80.0, 0.0)
	_column.position = Vector2(-(BAR_SIZE.x + 80.0) * 0.5, TOP_OFFSET)
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
