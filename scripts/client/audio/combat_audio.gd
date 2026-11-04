class_name CombatAudio
extends Node
## Audio del combate y de los pasos (ART-11, solo cliente). Un solo nodo por cliente que reparte las peticiones de
## sonido por el [AudioDirector] con los bancos de [CombatSoundBank]: cada sonido sale de una variante distinta
## con tono y volumen aleatorios, en 3D y con prioridad alta para lo propio.
## [br][br]
## [b]De dónde vienen las peticiones[/b]:
## [br]- [CombatFeedback] ([method bind]): el impacto de TODO golpe confirmado ([signal CombatFeedback.hit_impact],
## propio o ajeno, en su tick de dibujo), el golpe predicho en local ([signal CombatFeedback.hit_predicted]), la
## acción del personaje local ([signal CombatFeedback.action_changed]) y su muerte.
## [br]- Los visuales ([HumanoidVisual]): los pasos, el salto y el aterrizaje de cualquier personaje
## ([signal CharacterAnimator.stepped]...) y las acciones de los remotos (barridos y esquivas).
## [br][br]
## [b]Sincronía del barrido.[/b] El sonido tiene el pico a [constant SWING_PEAK_LIGHT] ([constant SWING_PEAK_HEAVY])
## segundos de su inicio, y el golpe activo empieza al acabar la anticipación; se pide al empezar la acción con el
## retraso que hace caer el pico en medio de la ventana activa ([method swing_delay], regla de
## [code]niveles.json[/code]).
## [br][br]
## Lo que suena se cuenta por grupo ([method get_play_count]) aunque no haya [AudioDirector] (las pruebas).

## Segundos desde el inicio del sonido hasta su pico, en los barridos ligeros y en los fuertes (niveles.json).
const SWING_PEAK_LIGHT: float = 0.089
const SWING_PEAK_HEAVY: float = 0.197
## Prioridad (m) de lo que hace o recibe el jugador local frente a lo ajeno al repartir las voces.
const LOCAL_PRIORITY_BONUS: float = 60.0
## Un golpe predicho y el confirmado que lo sigue son el mismo si llegan con menos de esto (s) de diferencia.
const PREDICTION_MATCH_SECONDS: float = 1.2
## Segundos entre el golpe mortal y el ruido del cuerpo al caer.
const DEATH_FALL_DELAY: float = 0.4
## Metros a los que un paso deja de oírse (los pasos de los demás se atenúan por distancia).
const STEP_HEARING_DISTANCE: float = 28.0
## Volumen (dB) extra de cada paso al correr y al esprintar frente a andar.
const STEP_LOUDNESS_DB_RANGE: float = 6.0

static var _instance: CombatAudio = null

var _feedback: CombatFeedback = null
var _counts: Dictionary = {}
var _last_step_msec: Dictionary = {}
var _pending: int = 0


static func get_instance() -> CombatAudio:
	return _instance if is_instance_valid(_instance) else null


func _enter_tree() -> void:
	_instance = self


func _exit_tree() -> void:
	if OS.has_environment("ELDMARK_FEEL_LOG"):
		print("[audio] sonidos pedidos por grupo: %s" % str(_counts))
	if _instance == self:
		_instance = null


func _init() -> void:
	name = "CombatAudio"


## Conecta el nodo con el reparto de la sensación de combate: de ahí salen los impactos, las acciones propias y la
## muerte. Se puede volver a llamar con otro reparto.
func bind(feedback: CombatFeedback) -> void:
	if is_instance_valid(_feedback):
		_feedback.hit_impact.disconnect(_on_hit_impact)
		_feedback.hit_predicted.disconnect(_on_hit_predicted)
		_feedback.action_changed.disconnect(_on_local_action)
		_feedback.sound_requested.disconnect(_on_sound_requested)
	_feedback = feedback
	if is_instance_valid(_feedback):
		_feedback.hit_impact.connect(_on_hit_impact)
		_feedback.hit_predicted.connect(_on_hit_predicted)
		_feedback.action_changed.connect(_on_local_action)
		_feedback.sound_requested.connect(_on_sound_requested)


# --- Peticiones --------------------------------------------------------------------------------

## Retraso (s) con el que hay que arrancar el sonido de un barrido para que su pico caiga en medio de la ventana
## activa: anticipación + mitad de la activa - pico, nunca negativo.
static func swing_delay(windup_s: float, active_s: float, heavy: bool) -> float:
	var peak: float = SWING_PEAK_HEAVY if heavy else SWING_PEAK_LIGHT
	return maxf(windup_s + active_s * 0.5 - peak, 0.0)


## Barrido del arma en [param position]. Si [param windup_s] y [param active_s] son positivos se retrasa para la
## sincronía de [method swing_delay]; [param local] da prioridad.
func play_swing(position: Vector3, heavy: bool, windup_s: float = 0.0, active_s: float = 0.0,
		local: bool = false) -> void:
	var delay: float = swing_delay(windup_s, active_s, heavy) if windup_s > 0.0 else 0.0
	var group: StringName = &"sword_swing_heavy" if heavy else &"sword_swing_light"
	if delay > 0.01 and is_inside_tree():
		_pending += 1
		get_tree().create_timer(delay).timeout.connect(func() -> void:
			_pending -= 1
			_play(group, position, 0.0, 1.0, local), CONNECT_ONE_SHOT)
	else:
		_play(group, position, 0.0, 1.0, local)


## Impacto de un golpe en [param position] (pecho de la víctima).
## [param material] es un [enum CombatSoundBank.Armor]; [param heavy] lo hace más grave y fuerte.
func play_impact(position: Vector3, material: int, heavy: bool, blocked: bool, parried: bool,
		local: bool) -> void:
	var group: StringName = CombatSoundBank.impact_group(material, blocked, parried)
	_play(group, position, 2.0 if heavy else 0.0, 0.92 if heavy else 1.0, local)
	if material == CombatSoundBank.Armor.HOLLOW and not blocked and not parried:
		_play(&"hollow_hurt", position, 0.0, 1.0, local)


## Paso de un personaje en [param position] sobre [param surface]. [param speed_fraction] (0 = andando, 1 = esprint)
## le da algo más de fuerza; los pasos de los demás se atenúan con la distancia y tienen menos prioridad.
func play_step(position: Vector3, surface: StringName, speed_fraction: float, local: bool) -> void:
	var group: StringName = CombatSoundBank.step_group(surface)
	var extra: float = lerpf(-STEP_LOUDNESS_DB_RANGE * 0.5, STEP_LOUDNESS_DB_RANGE * 0.5,
			clampf(speed_fraction, 0.0, 1.0))
	_play(group, position, extra - (0.0 if local else 3.0), CombatSoundBank.step_pitch(surface), local,
			STEP_HEARING_DISTANCE)


## Despegue del salto: un paso con empuje.
func play_jump(position: Vector3, surface: StringName, local: bool) -> void:
	_play(CombatSoundBank.step_group(surface), position, 1.0, 1.1, local, STEP_HEARING_DISTANCE)


## Aterrizaje con [param strength] de 0 a 1 (la velocidad del impacto): dos pasos juntos, más fuertes cuanto mayor.
func play_land(position: Vector3, surface: StringName, strength: float, local: bool) -> void:
	var group: StringName = CombatSoundBank.step_group(surface)
	var pitch: float = lerpf(0.95, 0.78, clampf(strength, 0.0, 1.0))
	_play(group, position, lerpf(-1.0, 5.0, strength), pitch * CombatSoundBank.step_pitch(surface), local,
			STEP_HEARING_DISTANCE)


## Esquiva: la voltereta (con tela y pisada) del que se mueve.
func play_dodge(position: Vector3, local: bool) -> void:
	_play(&"dodge_roll", position, 0.0, 1.0, local)


## Muerte: la caída del cuerpo, un instante después del golpe.
func play_death(position: Vector3, local: bool) -> void:
	if is_inside_tree():
		_pending += 1
		get_tree().create_timer(DEATH_FALL_DELAY).timeout.connect(func() -> void:
			_pending -= 1
			_play(&"body_fall", position, 0.0, 1.0, local), CONNECT_ONE_SHOT)
	else:
		_play(&"body_fall", position, 0.0, 1.0, local)


# --- Lectura (las pruebas) ----------------------------------------------------------------------

## Veces que se ha pedido el grupo [param group] desde que existe.
func get_play_count(group: StringName) -> int:
	return int(_counts.get(group, 0))


## Peticiones totales.
func get_total_play_count() -> int:
	var total: int = 0
	for group: Variant in _counts:
		total += int(_counts[group])
	return total


## Barridos con retraso que esperan su momento.
func get_pending_count() -> int:
	return _pending


## Olvida los contadores (las pruebas).
func reset_counts() -> void:
	_counts.clear()


## Material con el que suena el golpe a la víctima [param net_id]: estable por víctima (su armadura) y de los Huecos
## si lo es. Sin reparto, carne.
func material_of(net_id: int) -> int:
	if is_instance_valid(_feedback) and _feedback.is_hollow(net_id):
		return CombatSoundBank.Armor.HOLLOW
	var order: Array[int] = [CombatSoundBank.Armor.FLESH, CombatSoundBank.Armor.LEATHER,
			CombatSoundBank.Armor.GAMBESON, CombatSoundBank.Armor.MAIL]
	return order[absi(net_id) % order.size()]


# --- Interno ----------------------------------------------------------------------------------

func _play(group: StringName, position: Vector3, volume_offset_db: float, pitch: float, local: bool,
		max_distance: float = 0.0) -> void:
	_counts[group] = int(_counts.get(group, 0)) + 1
	var director: AudioDirector = AudioDirector.get_instance()
	if director == null:
		return
	if max_distance > 0.0 and not local \
			and director.get_listener_position().distance_to(position) > max_distance:
		return
	var stream: AudioStream = CombatSoundBank.stream_of(group)
	if stream == null:
		return
	director.play_3d(AudioDirector.Category.VOICES if group == &"hollow_hurt" else AudioDirector.Category.SFX,
			stream, position, CombatSoundBank.volume_db_of(group) + volume_offset_db, pitch,
			LOCAL_PRIORITY_BONUS if local else 0.0)


func _on_hit_impact(event: NetMessages.EntityEvent, position: Vector3, involves_me: bool,
		already_predicted: bool) -> void:
	if already_predicted:
		return
	var blocked: bool = event.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_BLOCKED)
	var parried: bool = event.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_PARRIED)
	var attack: AttackTicks = CombatCatalog.attack(event.attack_id)
	var heavy: bool = attack != null and attack.heavy
	play_impact(position + Vector3(0.0, 1.2, 0.0), material_of(event.net_id), heavy, blocked, parried,
			involves_me)


func _on_hit_predicted(position: Vector3, heavy: bool) -> void:
	play_impact(position + Vector3(0.0, 1.2, 0.0), CombatSoundBank.Armor.FLESH, heavy, false, false, true)


func _on_local_action(action: int, attack_id: int, _action_tick: int, _previous: int) -> void:
	if not is_instance_valid(_feedback):
		return
	var position: Vector3 = _feedback.get_local_position()
	if action == CombatState.Action.LIGHT or action == CombatState.Action.HEAVY:
		var attack: AttackTicks = CombatCatalog.attack(attack_id)
		var tick_s: float = 1.0 / float(Engine.physics_ticks_per_second)
		if attack != null:
			play_swing(position + Vector3(0.0, 1.2, 0.0), action == CombatState.Action.HEAVY,
					float(attack.windup_ticks) * tick_s, float(attack.active_ticks) * tick_s, true)
		else:
			play_swing(position + Vector3(0.0, 1.2, 0.0), action == CombatState.Action.HEAVY, 0.0, 0.0, true)
	elif action == CombatState.Action.DODGE:
		play_dodge(position + Vector3(0.0, 0.5, 0.0), true)


func _on_sound_requested(sound: StringName, position: Vector3) -> void:
	# Barridos, esquivas y golpes ya los reparten sus propias señales; aquí, solo la muerte propia o ajena.
	if sound == CombatFeedback.SOUND_DEATH:
		play_death(position, false)
