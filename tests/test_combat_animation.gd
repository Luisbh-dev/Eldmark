extends TestCase
## Pruebas de la capa de animación de combate (ART-08) y de las armas provisionales (ART-06).
## [br]- El recurso de clips ([CombatClipSet]) resuelve todos sus clips de UAL1/UAL2.
## [br]- [CombatClipPlanner] elige el clip correcto para cada acción y la velocidad de reproducción
## que encaja cada fase en su duración de los datos de combate.
## [br]- El fotograma de contacto de cada ataque cae en su ventana activa (con un tick de margen).
## [br]- La reconciliación (repetir ticks) no reinicia los clips; un remoto se anima con el byte
## action; el [CombatPoseModifier] pone la pose solo en los huesos que toca.

const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const CLIPS_PATH: String = "res://data/animation/sword_shield_clips.tres"
const START_TICK: int = 1000
const PRIMARY: int = PlayerInput.PRIMARY
const BLOCK: int = PlayerInput.BLOCK
const DODGE: int = PlayerInput.DODGE

var _clips: CombatClipSet
var _weapon: WeaponTicks
var _tick_rate: float = 60.0
var _nodes: Array[Node] = []
var _server_viewport: SubViewport = null
var _server_world: Node3D = null


func before_each() -> void:
	_clips = load(CLIPS_PATH) as CombatClipSet
	_weapon = CombatCatalog.weapon(CombatCatalog.default_weapon_id())
	_tick_rate = float(Engine.physics_ticks_per_second)


func after_each() -> void:
	for node: Node in _nodes:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()
	_nodes.clear()
	_server_viewport = null
	_server_world = null
	await wait_process_frames()


## Máquina de acciones sin física: un [CombatState] y un reloj, para guionizar botones tick a tick.
class Driver:
	var c: CombatState
	var tick: int = START_TICK
	var move: Vector2 = Vector2.ZERO

	func _init() -> void:
		c = CombatState.initial(CombatCatalog.rules(), CombatCatalog.default_weapon_id())

	func step(buttons: int = 0) -> void:
		tick += 1
		var input := PlayerInput.new()
		input.tick = tick
		input.buttons = buttons
		input.move = move
		ActionMachine.step(c, input, true)


func _attack(attack_name: StringName) -> AttackTicks:
	return CombatCatalog.attack(CombatCatalog.attack_id(attack_name))


# --- El recurso de clips ----------------------------------------------------------------------

func test_clip_set_covers_every_attack_and_action() -> void:
	if not assert_not_null(_clips, "el recurso carga"):
		return
	for key: StringName in [&"sword_light_1", &"sword_light_2", &"sword_light_3", &"sword_heavy",
			&"charge", &"block", &"dodge", &"stagger", &"stun", &"dead"]:
		assert_not_null(_clips.find(key), "hay entrada para %s" % key)
	assert_null(_clips.find(&"no_existe"))
	for name_of_attack: StringName in [&"sword_light_1", &"sword_light_2", &"sword_light_3",
			&"sword_heavy"]:
		var entry: CombatActionAnim = _clips.find(name_of_attack)
		assert_true(entry.is_attack(), "%s tiene los tres tramos" % name_of_attack)
		assert_true(entry.upper_body, "y se anima en la parte superior")


func test_every_segment_points_into_an_existing_clip() -> void:
	var checked: int = 0
	for entry: CombatActionAnim in _clips.entries:
		for segment: CombatClipSegment in [entry.windup, entry.active, entry.recovery]:
			if segment == null:
				continue
			var animation: Animation = _clips.get_animation(segment.animation)
			if not assert_not_null(animation, "%s: el clip %s existe" % [entry.key, segment.animation]):
				continue
			checked += 1
			assert_true(segment.from_s >= 0.0 and segment.to_s <= animation.length + 0.0001,
					"%s: [%.3f, %.3f] cabe en %s (%.3f s)" % [entry.key, segment.from_s,
					segment.to_s, segment.animation, animation.length])
			assert_true(segment.to_s > segment.from_s, "%s: el tramo avanza" % entry.key)
	assert_true(checked >= 18, "se han comprobado %d tramos" % checked)
	assert_null(_clips.get_animation(&"ual9/Nada"), "una biblioteca desconocida no resuelve")
	assert_null(_clips.get_animation(&"ual1/NoExiste"))
	assert_null(_clips.get_animation(&"sin_barra"))


# --- Elección de clip -------------------------------------------------------------------------

func test_planner_picks_the_right_clip_for_each_action() -> void:
	var expected: Array[Array] = [
		# acción, fase, paso del combo, clip, parte superior
		[CombatState.Action.LIGHT, ActionMachine.PHASE_WINDUP, 0, &"ual2/Sword_Regular_A", true],
		[CombatState.Action.LIGHT, ActionMachine.PHASE_ACTIVE, 0, &"ual2/Sword_Regular_A", true],
		[CombatState.Action.LIGHT, ActionMachine.PHASE_RECOVERY, 0, &"ual2/Sword_Regular_A_Rec", true],
		[CombatState.Action.LIGHT, ActionMachine.PHASE_WINDUP, 1, &"ual2/Sword_Regular_B", true],
		[CombatState.Action.LIGHT, ActionMachine.PHASE_RECOVERY, 1, &"ual2/Sword_Regular_B_Rec", true],
		[CombatState.Action.LIGHT, ActionMachine.PHASE_WINDUP, 2, &"ual2/Sword_Regular_C", true],
		[CombatState.Action.LIGHT, ActionMachine.PHASE_RECOVERY, 2, &"ual2/Sword_Regular_C", true],
		[CombatState.Action.HEAVY, ActionMachine.PHASE_WINDUP, 0, &"ual2/Sword_Heavy_Combo", true],
		[CombatState.Action.HEAVY, ActionMachine.PHASE_ACTIVE, 0, &"ual2/Sword_Heavy_Combo", true],
		[CombatState.Action.CHARGE, ActionMachine.PHASE_WINDUP, 0, &"ual2/Sword_Heavy_Combo", true],
		[CombatState.Action.BLOCK, ActionMachine.PHASE_NONE, 0, &"ual2/Idle_Shield_Loop", true],
		[CombatState.Action.DODGE, ActionMachine.PHASE_NONE, 0, &"ual1/Roll", false],
		[CombatState.Action.STAGGER, ActionMachine.PHASE_NONE, 0, &"ual1/Hit_Chest", true],
		[CombatState.Action.STUN, ActionMachine.PHASE_NONE, 0, &"ual2/Idle_Shield_Break", true],
		[CombatState.Action.DEAD, ActionMachine.PHASE_NONE, 0, &"ual1/Death01", false],
	]
	for row: Array in expected:
		var plan: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, int(row[0]),
				int(row[1]), int(row[2]), 0.0)
		var label: String = "acción %d fase %d paso %d" % [int(row[0]), int(row[1]), int(row[2])]
		if not assert_not_null(plan, "%s tiene animación" % label):
			continue
		assert_eq(plan.animation, row[3], "%s: clip" % label)
		assert_eq(plan.upper_body, bool(row[4]), "%s: parte superior" % label)
	assert_null(CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.NONE, 3, 0, 0.0),
			"sin acción no hay animación de combate")
	assert_null(CombatClipPlanner.plan(null, _weapon, CombatState.Action.LIGHT, 0, 0, 0.0))


func test_planner_keys_follow_the_catalog_names() -> void:
	assert_eq(CombatClipPlanner.key_for(_weapon, CombatState.Action.LIGHT, 0), &"sword_light_1")
	assert_eq(CombatClipPlanner.key_for(_weapon, CombatState.Action.LIGHT, 2), &"sword_light_3")
	assert_eq(CombatClipPlanner.key_for(_weapon, CombatState.Action.LIGHT, 9), &"sword_light_3",
			"un paso fuera de rango se recorta")
	assert_eq(CombatClipPlanner.key_for(_weapon, CombatState.Action.HEAVY, 0), &"sword_heavy")
	assert_eq(CombatClipPlanner.key_for(_weapon, CombatState.Action.NONE, 0), &"")
	assert_eq(CombatClipPlanner.key_for(_weapon, CombatState.Action.DODGE, 0), &"dodge")


# --- Velocidad de reproducción ----------------------------------------------------------------

func test_each_attack_phase_is_stretched_to_its_duration() -> void:
	for name_of_attack: StringName in [&"sword_light_1", &"sword_light_2", &"sword_light_3",
			&"sword_heavy"]:
		var attack: AttackTicks = _attack(name_of_attack)
		var entry: CombatActionAnim = _clips.find(name_of_attack)
		var action: int = CombatState.Action.HEAVY if attack.heavy else CombatState.Action.LIGHT
		var combo: int = _weapon.light_index(attack.id) if not attack.heavy else 0
		var lengths: Array[int] = [attack.windup_ticks, attack.active_ticks, attack.recovery_ticks]
		for phase: int in 3:
			var segment: CombatClipSegment = entry.segment_for_phase(phase)
			var seconds: float = float(lengths[phase]) / _tick_rate
			var start: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, action,
					phase, combo, 0.0)
			assert_near(start.time_s, segment.from_s, 0.0001, "%s fase %d: empieza al principio del tramo" % [name_of_attack, phase])
			assert_near(start.speed * seconds, segment.length_s(), 0.0001,
					"%s fase %d: la velocidad (%.3f) recorre el tramo en la duración de la fase" % [name_of_attack, phase, start.speed])
			assert_near(start.duration_s, seconds, 0.0001)
			var middle: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, action,
					phase, combo, float(lengths[phase]) * 0.5)
			assert_near(middle.time_s, (segment.from_s + segment.to_s) * 0.5, 0.0001,
					"%s fase %d: a media fase, a medio tramo" % [name_of_attack, phase])
			var finish: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, action,
					phase, combo, float(lengths[phase]))
			assert_near(finish.time_s, segment.to_s, 0.0001, "%s fase %d: acaba al final del tramo" % [name_of_attack, phase])
			var beyond: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, action,
					phase, combo, float(lengths[phase]) * 3.0)
			assert_near(beyond.time_s, segment.to_s, 0.0001, "%s fase %d: no se pasa del final" % [name_of_attack, phase])


func test_dodge_and_controls_fit_their_durations() -> void:
	var dodge_ticks: int = _weapon.dodge.duration_ticks
	var dodge: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon,
			CombatState.Action.DODGE, ActionMachine.PHASE_NONE, 0, 0.0)
	var roll: CombatClipSegment = _clips.find(&"dodge").windup
	assert_near(dodge.duration_s, float(dodge_ticks) / _tick_rate, 0.0001, "la esquiva dura lo que dicen los datos")
	assert_near(dodge.speed * dodge.duration_s, roll.length_s(), 0.0001)
	var end: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.DODGE,
			ActionMachine.PHASE_NONE, 0, float(dodge_ticks))
	assert_near(end.time_s, roll.to_s, 0.0001)
	# Un tambaleo de 18 ticks: el clip se estira a esos 0,3 s.
	var stagger: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon,
			CombatState.Action.STAGGER, ActionMachine.PHASE_NONE, 0, 0.0, 18)
	assert_near(stagger.duration_s, 18.0 / _tick_rate, 0.0001)
	var stagger_clip: CombatClipSegment = _clips.find(&"stagger").windup
	assert_near(stagger.speed * stagger.duration_s, stagger_clip.length_s(), 0.0001)
	# Sin duración conocida (un remoto) usa la del recurso.
	var remote: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon,
			CombatState.Action.STAGGER, ActionMachine.PHASE_NONE, 0, 0.0)
	assert_near(remote.duration_s, _clips.find(&"stagger").duration_s, 0.0001)


func test_charge_and_death_hold_their_last_pose() -> void:
	for pair: Array in [[CombatState.Action.CHARGE, &"charge"], [CombatState.Action.DEAD, &"dead"]]:
		var entry: CombatActionAnim = _clips.find(pair[1])
		assert_true(entry.hold_end, "%s se queda en la última pose" % pair[1])
		var late: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, int(pair[0]),
				ActionMachine.PHASE_NONE, 0, 100000.0)
		assert_near(late.time_s, entry.windup.to_s, 0.0001, "%s: mucho después sigue en el final" % pair[1])
		assert_true(late.hold)


## ART-48: el bloqueo es la guardia del escudo en bucle (no una pose congelada): el escudo queda delante del
## pecho, el clip no se queda parado y se puede andar bloqueando (solo la parte superior).
func test_block_loops_the_shield_guard_instead_of_freezing() -> void:
	var entry: CombatActionAnim = _clips.find(&"block")
	assert_true(entry.loop, "el bloqueo se repite")
	assert_false(entry.hold_end, "y no se queda en la última pose")
	assert_true(entry.upper_body, "solo la parte superior: se anda bloqueando")
	assert_eq(entry.windup.animation, &"ual2/Idle_Shield_Loop")
	var length: float = _clips.get_animation(entry.windup.animation).length
	assert_near(entry.windup.length_s(), length, 0.0001, "el bucle completo del clip")
	var times: Array[float] = []
	for ticks: float in [0.0, 40.0, 80.0, 120.0]:
		var plan: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.BLOCK,
				ActionMachine.PHASE_NONE, 0, ticks)
		assert_false(plan.hold)
		assert_near(plan.speed, 1.0, 0.0001, "a su velocidad original")
		times.append(plan.time_s)
	assert_true(times[1] > times[0] and times[2] > times[1] and times[3] > times[2], "el instante avanza")
	var wrapped: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.BLOCK,
			ActionMachine.PHASE_NONE, 0, entry.duration_s * _tick_rate + 30.0)
	assert_near(wrapped.time_s, entry.windup.from_s + 30.0 / _tick_rate, 0.0001, "y vuelve al principio")
	# El muro de escudos mantiene la misma guardia en bucle.
	var wall: CombatActionAnim = _clips.find(&"shield_wall")
	assert_true(wall.loop and not wall.hold_end, "el muro de escudos tampoco congela el clip")
	assert_eq(wall.windup.animation, &"ual2/Idle_Shield_Loop")


## ART-49: la esquiva reproduce el Roll recortado a unas 2x como máximo (el único clip que hay; el tope del
## listón de calidad para la esquiva), no a 3x.
func test_the_dodge_clip_plays_at_most_twice_as_fast() -> void:
	for clips: CombatClipSet in [_clips, load(BOW_CLIPS_PATH) as CombatClipSet]:
		var plan: CombatClipPlanner.Plan = CombatClipPlanner.plan(clips, _weapon, CombatState.Action.DODGE,
				ActionMachine.PHASE_NONE, 0, 0.0)
		assert_true(plan.speed <= 2.0001 and plan.speed >= 0.7, "esquiva a %.2fx" % plan.speed)


# --- Contacto dentro de la ventana activa -----------------------------------------------------

func test_contact_frame_falls_inside_the_active_window() -> void:
	for name_of_attack: StringName in [&"sword_light_1", &"sword_light_2", &"sword_light_3",
			&"sword_heavy"]:
		var attack: AttackTicks = _attack(name_of_attack)
		var entry: CombatActionAnim = _clips.find(name_of_attack)
		var contact: float = CombatClipPlanner.contact_tick(entry, attack)
		assert_true(contact >= float(attack.active_from()) - 1.0
				and contact <= float(attack.active_to()) + 1.0,
				"%s: el contacto (tick %.1f) cae en la ventana activa [%d, %d) ±1" % [
				name_of_attack, contact, attack.active_from(), attack.active_to()])
		assert_true(entry.contact_s >= entry.active.from_s and entry.contact_s <= entry.active.to_s,
				"%s: el contacto está dentro del tramo activo del clip" % name_of_attack)
	assert_eq(CombatClipPlanner.contact_tick(_clips.find(&"block"), _attack(&"sword_light_1")), -1.0,
			"lo que no es un ataque no tiene contacto")


func test_layer_reaches_the_contact_frame_within_the_active_window_for_each_light() -> void:
	for name_of_attack: StringName in [&"sword_light_1", &"sword_light_2", &"sword_light_3"]:
		var attack: AttackTicks = _attack(name_of_attack)
		var entry: CombatActionAnim = _clips.find(name_of_attack)
		var driver := Driver.new()
		driver.c.combo_step = _weapon.light_index(attack.id)
		driver.step()
		driver.step(PRIMARY)
		var action_tick: int = driver.c.action_tick
		assert_eq(driver.c.action_id, attack.id, "%s empieza" % name_of_attack)
		var layer := CombatAnimationLayer.new(_clips)
		var contact_k: int = -1
		for k: int in attack.total_ticks:
			var tick: int = action_tick + k
			if k > 0:
				driver.step(PRIMARY if k < 3 else 0)
			layer.update_local(driver.c, tick, 0.0, 1.0 / _tick_rate)
			var slot: CombatAnimationLayer.Slot = layer.get_current()
			if contact_k < 0 and slot != null and slot.animation_name == entry.active.animation \
					and layer.get_plan().phase >= ActionMachine.PHASE_ACTIVE \
					and slot.time_s >= entry.contact_s - 0.0001:
				contact_k = k
		assert_true(contact_k >= attack.active_from() - 1 and contact_k <= attack.active_to() + 1,
				"%s: el fotograma de contacto sale en el tick %d de la acción (ventana activa [%d, %d) ±1)" % [
				name_of_attack, contact_k, attack.active_from(), attack.active_to()])


func test_layer_reaches_the_contact_frame_within_the_active_window_for_the_heavy() -> void:
	var attack: AttackTicks = _attack(&"sword_heavy")
	var entry: CombatActionAnim = _clips.find(&"sword_heavy")
	var driver := Driver.new()
	driver.step()
	var layer := CombatAnimationLayer.new(_clips)
	# Mantener PRIMARY: ligero -> carga -> suelta -> fuerte.
	var released: bool = false
	var heavy_tick: int = -1
	var contact_k: int = -1
	for i: int in 160:
		var holding: bool = i < 8 + attack.charge_min_ticks + 4
		driver.step(PRIMARY if holding else 0)
		layer.update_local(driver.c, driver.tick, 0.0, 1.0 / _tick_rate)
		if driver.c.action == CombatState.Action.HEAVY and heavy_tick < 0:
			heavy_tick = driver.c.action_tick
		if heavy_tick >= 0:
			released = true
			var k: int = driver.tick - heavy_tick
			var slot: CombatAnimationLayer.Slot = layer.get_current()
			if contact_k < 0 and slot != null and slot.key == &"sword_heavy" \
					and layer.get_plan().phase >= ActionMachine.PHASE_ACTIVE \
					and slot.time_s >= entry.contact_s - 0.0001:
				contact_k = k
	assert_true(released, "se llegó a lanzar el fuerte")
	assert_true(contact_k >= attack.active_from() - 1 and contact_k <= attack.active_to() + 1,
			"el fuerte: contacto en el tick %d de la acción (ventana [%d, %d) ±1)" % [
			contact_k, attack.active_from(), attack.active_to()])


func test_layer_shows_charge_then_the_heavy_with_a_crossfade() -> void:
	var driver := Driver.new()
	driver.step()
	var layer := CombatAnimationLayer.new(_clips)
	var keys_seen: Array[StringName] = []
	for i: int in 70:
		driver.step(PRIMARY if i < 35 else 0)
		layer.update_local(driver.c, driver.tick, 0.0, 1.0 / _tick_rate)
		var current: CombatAnimationLayer.Slot = layer.get_current()
		if current != null and (keys_seen.is_empty() or keys_seen[keys_seen.size() - 1] != current.key):
			keys_seen.append(current.key)
	assert_eq(keys_seen, [&"sword_light_1", &"charge", &"sword_heavy"] as Array[StringName],
			"ligero que se convierte en carga y se suelta como fuerte")


# --- La reconciliación no reinicia los clips --------------------------------------------------

func test_replaying_ticks_does_not_restart_the_clip() -> void:
	var driver := Driver.new()
	driver.step()
	var layer := CombatAnimationLayer.new(_clips)
	var snapshots: Array[CombatState] = []
	var inputs: Array[int] = []
	for i: int in 24:
		var buttons: int = PRIMARY if i < 3 else 0
		driver.step(buttons)
		inputs.append(buttons)
		snapshots.append(driver.c.duplicate_state())
		layer.update_local(driver.c, driver.tick, 0.0, 1.0 / _tick_rate)
	var slot_before: CombatAnimationLayer.Slot = layer.get_current()
	var time_before: float = slot_before.time_s
	var weight_before: float = slot_before.weight
	assert_true(weight_before > 0.9, "el clip ya está a pleno peso")
	# La reconciliación vuelve al estado del tick 12 y repite los mismos ticks.
	driver.c.copy_from(snapshots[11])
	driver.tick = START_TICK + 1 + 12
	for i: int in range(12, 24):
		driver.step(inputs[i])
	layer.update_local(driver.c, driver.tick, 0.0, 1.0 / _tick_rate)
	var slot_after: CombatAnimationLayer.Slot = layer.get_current()
	assert_true(slot_after == slot_before, "es el mismo clip: no se reinicia")
	assert_near(slot_after.time_s, time_before, 0.0001, "en el mismo instante")
	assert_true(slot_after.weight >= weight_before, "y el peso no se reinicia")
	assert_null(layer.get_previous(), "sin fundido de vuelta")


func test_a_server_imposed_control_changes_the_key_and_crossfades() -> void:
	var driver := Driver.new()
	driver.step()
	driver.step(PRIMARY)
	var layer := CombatAnimationLayer.new(_clips)
	for i: int in 10:
		driver.step()
		layer.update_local(driver.c, driver.tick, 0.0, 1.0 / _tick_rate)
	var attack_slot: CombatAnimationLayer.Slot = layer.get_current()
	assert_eq(attack_slot.key, &"sword_light_1")
	ActionMachine.impose_stagger(driver.c, driver.tick, driver.tick + 20, Vector2.ZERO)
	driver.step()
	layer.update_local(driver.c, driver.tick, 0.0, 1.0 / _tick_rate)
	assert_eq(layer.get_current().key, &"stagger", "el tambaleo impuesto cambia el clip")
	assert_true(layer.get_previous() == attack_slot, "y el ataque se desvanece")
	assert_true(layer.get_previous().target == 0.0)
	for i: int in 20:
		driver.step()
		layer.update_local(driver.c, driver.tick, 0.0, 1.0 / _tick_rate)
	assert_null(layer.get_previous(), "acabado el fundido, solo queda el clip nuevo")


func test_layer_fades_out_when_the_action_ends() -> void:
	var driver := Driver.new()
	driver.step()
	driver.step(PRIMARY)
	var layer := CombatAnimationLayer.new(_clips)
	var attack: AttackTicks = _attack(&"sword_light_1")
	for i: int in attack.total_ticks + 20:
		driver.step()
		layer.update_local(driver.c, driver.tick, 0.0, 1.0 / _tick_rate)
	assert_eq(driver.c.action, CombatState.Action.NONE, "el ataque ha acabado")
	assert_eq(layer.get_current(), null, "y la capa se ha vaciado tras el fundido de salida")
	assert_true(layer.get_slots().is_empty())
	assert_false(layer.is_active())


# --- Remotos ----------------------------------------------------------------------------------

func _byte(action: int, phase: int, combo: int = 0) -> int:
	return (action & 15) | (phase << 4) | (combo << 6)


func test_remote_action_byte_selects_the_clip_and_restarts_each_phase() -> void:
	var layer := CombatAnimationLayer.new(_clips)
	var dt: float = 1.0 / _tick_rate
	layer.update_remote(_byte(CombatState.Action.NONE, ActionMachine.PHASE_NONE), dt)
	assert_null(layer.get_current(), "sin acción, nada")
	# Ligero 2 en anticipación.
	layer.update_remote(_byte(CombatState.Action.LIGHT, ActionMachine.PHASE_WINDUP, 1), dt)
	var slot: CombatAnimationLayer.Slot = layer.get_current()
	assert_eq(slot.key, &"sword_light_2")
	assert_eq(slot.animation_name, &"ual2/Sword_Regular_B")
	var entry: CombatActionAnim = _clips.find(&"sword_light_2")
	assert_near(slot.time_s, entry.windup.from_s, 0.0001, "empieza el tramo desde su principio")
	for _i: int in 5:
		layer.update_remote(_byte(CombatState.Action.LIGHT, ActionMachine.PHASE_WINDUP, 1), dt)
	assert_true(layer.get_current().time_s > entry.windup.from_s, "y avanza con el tiempo real")
	# Pasa a golpe activo: el tramo activo empieza de cero, aunque lleve tiempo en la fase anterior.
	layer.update_remote(_byte(CombatState.Action.LIGHT, ActionMachine.PHASE_ACTIVE, 1), dt)
	assert_eq(layer.get_current().animation_name, &"ual2/Sword_Regular_B")
	assert_near(layer.get_current().time_s, entry.active.from_s, 0.0001)
	layer.update_remote(_byte(CombatState.Action.LIGHT, ActionMachine.PHASE_RECOVERY, 1), dt)
	assert_eq(layer.get_current().animation_name, &"ual2/Sword_Regular_B_Rec", "recuperación")
	# El siguiente del combo (paso 2) es otra acción aunque la fase vuelva a la anticipación.
	layer.update_remote(_byte(CombatState.Action.LIGHT, ActionMachine.PHASE_WINDUP, 2), dt)
	assert_eq(layer.get_current().key, &"sword_light_3")
	assert_true(layer.get_previous() != null, "con fundido desde el anterior")


func test_remote_dead_and_dodge_play_and_hold() -> void:
	var layer := CombatAnimationLayer.new(_clips)
	var dt: float = 1.0 / _tick_rate
	layer.update_remote(_byte(CombatState.Action.DODGE, ActionMachine.PHASE_NONE), dt)
	assert_eq(layer.get_current().animation_name, &"ual1/Roll")
	assert_false(layer.get_current().upper_body, "la esquiva es de cuerpo entero")
	for _i: int in 200:
		layer.update_remote(_byte(CombatState.Action.DEAD, ActionMachine.PHASE_NONE), dt)
	var dead: CombatAnimationLayer.Slot = layer.get_current()
	assert_eq(dead.animation_name, &"ual1/Death01")
	assert_near(dead.time_s, _clips.find(&"dead").windup.to_s, 0.0001, "tumbado, en la última pose")
	assert_near(dead.weight, 1.0, 0.0001, "a pleno peso")


func test_remote_ignores_garbage_actions() -> void:
	var layer := CombatAnimationLayer.new(_clips)
	layer.update_remote(0x0F, 0.016)
	assert_null(layer.get_current(), "una acción fuera del enum no se anima")
	assert_eq(ActionMachine.action_byte(CombatState.initial(CombatCatalog.rules(), 1), 0), 0x30,
			"y el byte de «sin acción» es 0x30")
	layer.update_remote(0x30, 0.016)
	assert_null(layer.get_current())


## Un luchador del servidor en un mundo propio: es quien publica el byte de acción que ven los
## demás clientes (el camino real, no la máquina de acciones suelta).
func _make_server_fighter(net_id: int) -> Combatant:
	if _server_world == null:
		_server_viewport = CombatFixture.make_world(tree.root)
		_nodes.append(_server_viewport)
		_server_world = NetHarness.get_world(_server_viewport)
	return CombatFixture.make_fighter(_server_world, net_id, NetProtocol.Realm.VARDHEIM, Vector3.ZERO,
			0.0, CombatTiming.from_rules(CombatCatalog.rules()))


## Recorre los ticks [code]START_TICK + 1[/code] a [code]START_TICK + last_rel[/code] del luchador:
## en cada uno simula la máquina de acciones con los botones de [param buttons_at] (tick relativo
## -> botones), llama a [param impose] (con el tick relativo, para imponer controles como hace el
## servidor tras resolver los golpes) y publica. Un remoto recibe el byte [code]action[/code] de un
## snapshot cada 2 ticks y avanza un tick de tiempo real por tick. Devuelve cuántas veces vuelve
## atrás el instante del clip del remoto (un reinicio) y cuántas el de la capa local.
func _count_restarts(fighter: Combatant, last_rel: int, buttons_at: Callable,
		impose: Callable) -> Vector2i:
	var clips: CombatClipSet = _clips
	var remote := CombatAnimationLayer.new(clips)
	var local := CombatAnimationLayer.new(clips)
	var combat: CombatState = fighter.get_character().combat
	var dt: float = 1.0 / _tick_rate
	var snapshot_byte: int = ActionMachine.action_byte(combat, START_TICK)
	var previous_remote: float = -1.0
	var previous_local: float = -1.0
	var remote_restarts: int = 0
	var local_restarts: int = 0
	for rel: int in range(1, last_rel + 1):
		var input := PlayerInput.new()
		input.tick = START_TICK + rel
		input.move = Vector2(0.0, 1.0)
		input.buttons = int(buttons_at.call(rel))
		ActionMachine.step(combat, input, true)
		impose.call(rel, combat)
		fighter.publish(input.tick)
		if rel % 2 == 0:
			snapshot_byte = fighter.entity.action
		remote.update_remote(snapshot_byte, dt)
		local.update_local(combat, input.tick, 0.0, dt)
		var remote_time: float = remote.get_current().time_s if remote.get_current() != null else -1.0
		var local_time: float = local.get_current().time_s if local.get_current() != null else -1.0
		if previous_remote >= 0.0 and remote_time >= 0.0 and remote_time + 0.0001 < previous_remote:
			remote_restarts += 1
		if previous_local >= 0.0 and local_time >= 0.0 and local_time + 0.0001 < previous_local:
			local_restarts += 1
		previous_remote = remote_time
		previous_local = local_time
	return Vector2i(remote_restarts, local_restarts)


func test_a_remote_replays_a_second_dodge_chained_by_the_buffer() -> void:
	# T2: la segunda esquiva sale del búfer en el tick en que acaba la primera, sin ningún tick en
	# NONE: el byte de acción sería el mismo y el remoto se quedaría congelado en la última pose.
	var fighter: Combatant = _make_server_fighter(1)
	var restarts: Vector2i = _count_restarts(fighter, 70,
			func(rel: int) -> int: return DODGE if rel == 1 or rel == 22 else 0,
			func(_rel: int, _combat: CombatState) -> void: pass)
	assert_eq(restarts.y, 1, "la capa local reinicia el clip al empezar la segunda esquiva")
	assert_eq(restarts.x, 1, "y el remoto también, aunque no vea ningún tick sin esquiva")


func test_a_remote_replays_a_second_control_whatever_the_gap_between_them() -> void:
	# Dos tambaleos (o aturdimientos) seguidos comparten byte: el remoto debe reiniciar el clip en
	# el segundo sea cual sea la separación entre ambos.
	var first_tick: int = 10
	for gap: int in range(2, 12):
		var fighter: Combatant = _make_server_fighter(10 + gap)
		var restarts: Vector2i = _count_restarts(fighter, first_tick + gap + 10,
				func(_rel: int) -> int: return 0,
				func(rel: int, combat: CombatState) -> void:
					if rel == first_tick or rel == first_tick + gap:
						ActionMachine.impose_stagger(combat, START_TICK + rel, START_TICK + rel + 40,
								Vector2.ZERO))
		assert_eq(restarts.x, 1, "separados %d ticks: el remoto reinicia el tambaleo" % gap)
		assert_eq(restarts.y, 1, "(y el local también)")
	var stun_fighter: Combatant = _make_server_fighter(99)
	var stun_restarts: Vector2i = _count_restarts(stun_fighter, 40,
			func(_rel: int) -> int: return 0,
			func(rel: int, combat: CombatState) -> void:
				if rel == 10 or rel == 17:
					ActionMachine.impose_stun(combat, START_TICK + rel, START_TICK + rel + 40))
	assert_eq(stun_restarts.x, 1, "dos aturdimientos seguidos también")


func test_a_remote_does_not_restart_a_dodge_or_a_control_that_just_goes_on() -> void:
	var fighter: Combatant = _make_server_fighter(3)
	var restarts: Vector2i = _count_restarts(fighter, 40,
			func(rel: int) -> int: return DODGE if rel == 1 else 0,
			func(_rel: int, _combat: CombatState) -> void: pass)
	assert_eq(restarts, Vector2i(0, 0), "una sola esquiva no se reinicia a mitad")
	var staggered: Combatant = _make_server_fighter(4)
	restarts = _count_restarts(staggered, 40,
			func(_rel: int) -> int: return 0,
			func(rel: int, combat: CombatState) -> void:
				if rel == 5:
					ActionMachine.impose_stagger(combat, START_TICK + rel, START_TICK + rel + 30,
							Vector2.ZERO))
	assert_eq(restarts, Vector2i(0, 0), "ni un solo tambaleo")


# --- Pose en el esqueleto ---------------------------------------------------------------------

## Humanoide animado de verdad (cápsula sustituida) colgado de un personaje.
func _make_visual() -> HumanoidVisual:
	var world := Node3D.new()
	tree.root.add_child(world)
	_nodes.append(world)
	var character: PlayerCharacter = (load(CHARACTER_SCENE_PATH) as PackedScene).instantiate() \
			as PlayerCharacter
	world.add_child(character)
	var visual: HumanoidVisual = HumanoidVisual.install(character)
	return visual


func test_weapon_placeholders_hang_from_the_hands() -> void:
	var visual: HumanoidVisual = _make_visual()
	if not assert_not_null(visual):
		return
	var skeleton: Skeleton3D = visual.get_skeleton()
	var sword: BoneAttachment3D = skeleton.get_node_or_null(NodePath(WeaponProps.SWORD_ATTACHMENT)) \
			as BoneAttachment3D
	var shield: BoneAttachment3D = skeleton.get_node_or_null(NodePath(WeaponProps.SHIELD_ATTACHMENT)) \
			as BoneAttachment3D
	if not assert_not_null(sword, "hay espada") or not assert_not_null(shield, "y escudo"):
		return
	assert_eq(sword.bone_name, "RightHand", "la espada en la mano derecha")
	assert_eq(shield.bone_name, "LeftHand", "y el escudo en la izquierda")
	# La espada ya es el modelo propio (SwordModel), no la caja: dos mallas de LOD y no es provisional.
	var blade: MeshInstance3D = sword.find_child(String(SwordModel.LOD0_NAME), true, false) as MeshInstance3D
	if assert_not_null(blade, "la espada es el modelo con su malla de detalle completo"):
		assert_true(blade.mesh is ArrayMesh and not (blade.mesh is BoxMesh), "una malla modelada, no una caja")
	assert_not_null(sword.find_child(String(SwordModel.LOD1_NAME), true, false), "y la de detalle sencillo")
	assert_null(sword.find_child("Hoja", true, false), "sin la caja de reserva")
	var disc: MeshInstance3D = shield.find_child("Disco", true, false) as MeshInstance3D
	assert_true(disc.mesh is CylinderMesh, "y un cilindro aplanado para el escudo")
	var cylinder: CylinderMesh = disc.mesh as CylinderMesh
	assert_true(cylinder.height < cylinder.top_radius * 0.5, "aplanado")
	assert_false(bool(sword.get_child(0).get_meta(&"placeholder", true)), "la espada ya no es provisional")
	assert_true(bool(shield.get_child(0).get_meta(&"placeholder", false)), "el escudo sí")
	var again: Array[BoneAttachment3D] = WeaponProps.install(skeleton)
	assert_null(again[0], "instalarlas otra vez no duplica nada")
	var count: int = 0
	for child: Node in skeleton.get_children():
		if child is BoneAttachment3D:
			count += 1
	assert_eq(count, 2)


func test_weapons_follow_the_hand_bone() -> void:
	var visual: HumanoidVisual = _make_visual()
	var skeleton: Skeleton3D = visual.get_skeleton()
	var sword: BoneAttachment3D = skeleton.get_node(NodePath(WeaponProps.SWORD_ATTACHMENT)) \
			as BoneAttachment3D
	await wait_process_frames(3)
	var hand: int = skeleton.find_bone("RightHand")
	var hand_global: Transform3D = skeleton.global_transform * skeleton.get_bone_global_pose(hand)
	assert_vec_near(sword.global_position, hand_global.origin, 0.05,
			"la espada está en la mano (no en el origen)")
	assert_true(sword.global_position.distance_to(visual.global_position) > 0.2)


func test_pose_modifier_blends_upper_body_clips_into_the_upper_bones_only() -> void:
	var visual: HumanoidVisual = _make_visual()
	if not assert_not_null(visual):
		return
	var animator: CharacterAnimator = visual.get_animator()
	var modifier: CombatPoseModifier = animator.get_combat_modifier()
	var layer: CombatAnimationLayer = animator.get_combat_layer()
	var skeleton: Skeleton3D = visual.get_skeleton()
	assert_not_null(modifier, "el humanoide trae su modificador de combate")
	assert_not_null(layer)
	await wait_process_frames(2)
	var chest: int = skeleton.find_bone("Chest")
	var left_leg: int = skeleton.find_bone("LeftUpperLeg")
	var before_chest: Quaternion = skeleton.get_bone_pose_rotation(chest)
	var before_leg: Quaternion = skeleton.get_bone_pose_rotation(left_leg)
	# Bloqueo (parte superior) a pleno peso.
	var plan: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.BLOCK,
			ActionMachine.PHASE_NONE, 0, 1000.0)
	layer.apply_plan(plan, 1.0)
	var slot: CombatAnimationLayer.Slot = layer.get_current()
	assert_near(slot.weight, 1.0, 0.0001)
	modifier._process_modification()
	var clip: Animation = slot.animation
	var expected: Quaternion = Quaternion.IDENTITY
	var found: bool = false
	for track: int in clip.get_track_count():
		if String(clip.track_get_path(track)).ends_with(":Chest") \
				and clip.track_get_type(track) == Animation.TYPE_ROTATION_3D:
			expected = clip.rotation_track_interpolate(track, slot.time_s)
			found = true
	assert_true(found, "el clip anima el pecho")
	var after_chest: Quaternion = skeleton.get_bone_pose_rotation(chest)
	assert_true(after_chest.angle_to(expected) < 0.001, "el pecho queda con la pose del clip")
	assert_true(after_chest.angle_to(before_chest) > 0.001, "y cambia respecto a la locomoción")
	var after_leg: Quaternion = skeleton.get_bone_pose_rotation(left_leg)
	assert_true(after_leg.angle_to(before_leg) < 0.0001, "las piernas siguen con la locomoción")
	assert_true(modifier.get_applied_count() >= 1)
	assert_true(modifier.get_upper_body_bones().size() > 20, "la máscara de la parte superior (%d huesos)" % modifier.get_upper_body_bones().size())
	assert_false(modifier.get_upper_body_bones().has(left_leg))


func test_pose_modifier_full_body_clip_moves_legs_and_hips_and_zero_weight_does_nothing() -> void:
	var visual: HumanoidVisual = _make_visual()
	var animator: CharacterAnimator = visual.get_animator()
	var modifier: CombatPoseModifier = animator.get_combat_modifier()
	var layer: CombatAnimationLayer = animator.get_combat_layer()
	var skeleton: Skeleton3D = visual.get_skeleton()
	await wait_process_frames(2)
	var hips: int = skeleton.find_bone("Hips")
	var left_leg: int = skeleton.find_bone("LeftUpperLeg")
	var rest_leg: Quaternion = skeleton.get_bone_pose_rotation(left_leg)
	var rest_hips: Vector3 = skeleton.get_bone_pose_position(hips)
	# Sin plan no se toca nada.
	modifier._process_modification()
	assert_true(skeleton.get_bone_pose_rotation(left_leg).angle_to(rest_leg) < 0.0001, "sin clip, sin cambios")
	# Muerte (cuerpo entero), al final del clip: las caderas bajan al suelo.
	var plan: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.DEAD,
			ActionMachine.PHASE_NONE, 0, 100000.0)
	layer.apply_plan(plan, 1.0)
	modifier._process_modification()
	assert_true(skeleton.get_bone_pose_rotation(left_leg).angle_to(rest_leg) > 0.01, "la pierna sigue el clip")
	assert_true(skeleton.get_bone_pose_position(hips).y < rest_hips.y - 0.3,
			"las caderas bajan (%.2f -> %.2f)" % [rest_hips.y, skeleton.get_bone_pose_position(hips).y])


func test_animator_follows_the_local_combat_state_and_a_remote_byte() -> void:
	var visual: HumanoidVisual = _make_visual()
	var animator: CharacterAnimator = visual.get_animator()
	var character: PlayerCharacter = animator.get_character()
	await wait_physics_frames(2)
	# Local: se le pone un estado de ataque y el animador lo recoge.
	var driver := Driver.new()
	driver.step()
	driver.step(PRIMARY)
	character.combat.copy_from(driver.c)
	character.last_input_tick = driver.tick
	await wait_process_frames(2)
	var local: Dictionary = animator.get_debug_state()["combat"]
	assert_true(bool(local["active"]), "el animador anima el ataque")
	assert_eq(local["key"], &"sword_light_1")
	assert_true(bool(local["upper_body"]))
	# Remoto: la acción sale del byte que devuelve el origen.
	var holder: Array[int] = [_byte(CombatState.Action.BLOCK, ActionMachine.PHASE_NONE)]
	character.combat.copy_from(CombatState.initial(CombatCatalog.rules(), CombatCatalog.default_weapon_id()))
	animator.set_remote_source(func() -> int: return holder[0])
	await wait_process_frames(3)
	var remote: Dictionary = animator.get_debug_state()["combat"]
	assert_eq(remote.get("key"), &"block", "el remoto bloquea según su byte")
	holder[0] = 0x30
	await wait_physics_frames(45)
	var idle: Dictionary = animator.get_debug_state()["combat"]
	assert_false(bool(idle.get("active", true)), "sin acción, la capa se vacía")


func test_remote_world_wires_the_animator_to_the_drawn_action() -> void:
	var clock := RemoteWorldClock.new()
	var world := RemoteWorld.new()
	world.install_visuals = true
	world.setup(clock)
	tree.root.add_child(world)
	_nodes.append(world)
	var spawn := NetMessages.EntitySpawn.new()
	spawn.net_id = 9
	spawn.kind = NetProtocol.EntityKind.PLAYER
	spawn.spawn_tick = 1
	spawn.realm = NetProtocol.Realm.SOLMARCH
	spawn.display_name = "Ana"
	var state := PlayerState.new()
	state.grounded = true
	spawn.state = state
	world.on_spawn(spawn)
	var view: RemotePlayerView = world.get_view(9)
	var visual: HumanoidVisual = view.get_body().get_node_or_null(^"Visual/HumanoidVisual") as HumanoidVisual
	if not assert_not_null(visual, "el remoto lleva el humanoide"):
		return
	for tick: int in [2, 4]:
		var record := EntityRecord.new()
		record.net_id = 9
		record.flags = EntityRecord.FLAG_GROUNDED
		record.action = _byte(CombatState.Action.DODGE, ActionMachine.PHASE_NONE)
		var snapshot := NetMessages.Snapshot.new()
		snapshot.server_tick = tick
		snapshot.records = [record] as Array[EntityRecord]
		world.on_snapshot(snapshot)
	clock.render = 3.0
	world.draw(3.0, 0.016)
	await wait_process_frames(3)
	var combat: Dictionary = visual.get_animator().get_debug_state()["combat"]
	assert_eq(combat.get("key"), &"dodge", "el animador del remoto lee el byte action de su registro")


## Reloj de dibujo fijado desde la prueba.
class RemoteWorldClock extends InterpolationClock:
	var render: float = 0.0

	func get_render_tick() -> float:
		return render


# --- Fase 4: habilidades, arco, derribado (provisional, docs/habilidades.md, sección 6.6) ----------

const BOW_CLIPS_PATH: String = "res://data/animation/bow_clips.tres"


func test_each_weapon_has_its_clip_set_with_the_phase_4_entries() -> void:
	var bow_clips: CombatClipSet = load(BOW_CLIPS_PATH) as CombatClipSet
	if not assert_not_null(bow_clips, "el arco tiene su juego de clips"):
		return
	var sword_id: int = CombatCatalog.weapon_id(&"sword_shield")
	var bow_id: int = CombatCatalog.weapon_id(&"bow")
	assert_eq(CombatAnimationLayer.clips_for(bow_id, _clips), bow_clips, "el de su arma")
	assert_eq(CombatAnimationLayer.clips_for(sword_id, null).resource_path, CLIPS_PATH)
	var npc: int = CombatCatalog.weapon_id(&"npc_guard")
	var npc_clips: CombatClipSet = CombatAnimationLayer.clips_for(npc, _clips)
	assert_true(npc_clips != _clips and npc_clips.resource_path.ends_with("npc_guard_clips.tres"),
			"un PNJ usa su propio juego (ART-47)")
	assert_eq(CombatAnimationLayer.clips_for(0, _clips), _clips, "un arma desconocida usa el de por defecto")
	var common: Array[StringName] = [&"drink", &"swap", &"downed", &"downed_crawl", &"revive", &"execute",
			&"get_up", &"dodge", &"stagger", &"stun", &"dead"]
	for key: StringName in common + ([&"shield_bash", &"shield_rush", &"shield_wall", &"block", &"charge"]
			as Array[StringName]):
		assert_not_null(_clips.find(key), "espada y escudo: %s" % key)
	for key: StringName in common + ([&"bow_quick", &"bow_drawn", &"bow_volley", &"bow_slowing_shot",
			&"bow_evasive_shot", &"charge"] as Array[StringName]):
		assert_not_null(bow_clips.find(key), "arco: %s" % key)
	assert_null(bow_clips.find(&"block"), "el arco no bloquea")
	assert_true(_clips.find(&"downed_crawl").loop, "arrastrarse se repite")
	assert_true(_clips.find(&"downed").hold_end, "derribado quieto, en la última pose")
	# Todos los tramos del arco existen y caben en su clip (los de la espada ya los mira otra prueba).
	for entry: CombatActionAnim in bow_clips.entries:
		for segment: CombatClipSegment in [entry.windup, entry.active, entry.recovery]:
			if segment == null:
				continue
			var animation: Animation = bow_clips.get_animation(segment.animation)
			if not assert_not_null(animation, "%s: el clip %s existe" % [entry.key, segment.animation]):
				continue
			assert_true(segment.from_s >= 0.0 and segment.to_s <= animation.length + 0.0001
					and segment.to_s > segment.from_s, "%s: el tramo cabe en %s" % [entry.key, segment.animation])
	for name_of_attack: StringName in [&"bow_quick", &"bow_drawn"]:
		var attack: AttackTicks = _attack(name_of_attack)
		var contact: float = CombatClipPlanner.contact_tick(bow_clips.find(name_of_attack), attack)
		assert_true(contact >= float(attack.active_from()) - 1.0 and contact <= float(attack.active_to()) + 1.0,
				"%s: el disparo cae en su tick activo (%.1f)" % [name_of_attack, contact])


func test_the_planner_animates_abilities_potions_swap_and_downed() -> void:
	var bash: AbilityTicks = CombatCatalog.ability(CombatCatalog.ability_id(&"shield_bash"))
	var potion: int = CombatCatalog.consumable_ids()[1]
	assert_eq(CombatClipPlanner.key_for(_weapon, CombatState.Action.ABILITY, 0, bash.id), &"shield_bash",
			"una habilidad, por su nombre")
	assert_eq(CombatClipPlanner.key_for(_weapon, CombatState.Action.ABILITY, 0, potion), &"drink",
			"una poción, beber")
	assert_eq(CombatClipPlanner.key_for(_weapon, CombatState.Action.SWAP, 0), &"swap")
	assert_eq(CombatClipPlanner.key_for(_weapon, CombatState.Action.DOWNED, 0), &"downed")
	assert_eq(CombatClipPlanner.key_for(_weapon, CombatState.Action.DOWNED, 0, 0, true), &"downed_crawl",
			"derribado y moviéndose, se arrastra")
	assert_eq(CombatClipPlanner.key_for(_weapon, CombatState.Action.REVIVE, 0), &"revive")
	assert_eq(CombatClipPlanner.key_for(_weapon, CombatState.Action.EXECUTE, 0), &"execute")
	assert_eq(CombatClipPlanner.ability_of_slot(_weapon, 0), bash.id, "la ranura 1 del byte de un remoto")
	assert_eq(CombatClipPlanner.ability_of_slot(_weapon, 3), CombatCatalog.consumable_ids()[0],
			"la 3 es beber")
	# Cada fase de la habilidad se estira a la suya: lanzamiento, activo y recuperación.
	var entry: CombatActionAnim = _clips.find(&"shield_bash")
	var lengths: Array[int] = [bash.cast_ticks, bash.active_ticks, bash.recovery_ticks]
	for phase: int in 3:
		var plan: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.ABILITY,
				phase, 0, 0.0, 0, bash.id)
		assert_eq(plan.animation, entry.segment_for_phase(phase).animation)
		assert_near(plan.duration_s, float(lengths[phase]) / _tick_rate, 0.0001,
				"fase %d del golpe de escudo, en su duración" % phase)
	var swap: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.SWAP,
			ActionMachine.PHASE_NONE, 0, 0.0)
	assert_near(swap.duration_s, float(CombatCatalog.tables().swap_ticks) / _tick_rate, 0.0001,
			"el cambio de arma dura sus 0,4 s")
	var revive: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.REVIVE,
			ActionMachine.PHASE_NONE, 0, 0.0)
	assert_eq(revive.animation, &"ual1/Fixing_Kneeling")
	assert_near(revive.duration_s, float(CombatCatalog.tables().revive_ticks) / _tick_rate, 0.0001)
	# Arrastrarse se repite: pasada su duración vuelve al principio.
	var crawl: CombatActionAnim = _clips.find(&"downed_crawl")
	var crawl_ticks: float = crawl.duration_s * _tick_rate
	var later: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.DOWNED,
			ActionMachine.PHASE_NONE, 0, crawl_ticks * 1.25, 0, 0, true)
	assert_near(later.time_s, lerpf(crawl.windup.from_s, crawl.windup.to_s, 0.25), 0.0001)


func test_the_layer_uses_the_weapons_clips_the_remote_ability_and_gets_up_after_being_revived() -> void:
	var layer := CombatAnimationLayer.new(_clips)
	var dt: float = 1.0 / _tick_rate
	var bow: int = CombatCatalog.weapon_id(&"bow")
	# Local con el arco: el disparo rápido sale de su juego.
	var state := CombatState.initial(CombatCatalog.rules(), bow)
	state.action = CombatState.Action.LIGHT
	state.action_id = CombatCatalog.attack_id(&"bow_quick")
	state.action_tick = START_TICK
	layer.update_local(state, START_TICK + 1, 0.0, dt)
	assert_eq(layer.get_current().key, &"bow_quick")
	assert_eq(layer.get_current().animation_name, &"ual1/Pistol_Aim_Neutral")
	# Un remoto con la espada y escudo en la ranura 2 de su byte: la embestida.
	var remote := CombatAnimationLayer.new(_clips)
	remote.update_remote(_byte(CombatState.Action.ABILITY, ActionMachine.PHASE_ACTIVE, 1), dt,
			CombatCatalog.weapon_id(&"sword_shield"))
	assert_eq(remote.get_current().key, &"shield_rush", "la habilidad de la ranura del byte")
	assert_false(remote.get_current().upper_body, "de cuerpo entero")
	remote.update_remote(_byte(CombatState.Action.ABILITY, ActionMachine.PHASE_WINDUP, 3), dt)
	assert_eq(remote.get_current().key, &"drink", "la ranura 3 es beber")
	# Derribado, levantado y de pie: se levanta una vez.
	for _i: int in 10:
		remote.update_remote(_byte(CombatState.Action.DOWNED, ActionMachine.PHASE_NONE), dt, 0, true)
	assert_eq(remote.get_current().key, &"downed_crawl")
	remote.update_remote(_byte(CombatState.Action.NONE, ActionMachine.PHASE_NONE), dt)
	assert_eq(remote.get_current().key, &"get_up", "lo han levantado: se levanta")
	for _i: int in roundi(_clips.find(&"get_up").duration_s * _tick_rate) + 2:
		remote.update_remote(_byte(CombatState.Action.NONE, ActionMachine.PHASE_NONE), dt)
	assert_eq(remote.get_plan(), null, "y luego, nada")
	remote.update_remote(0x0E, dt)
	assert_null(remote.get_plan(), "la acción 14 (libre) no se anima")


func test_the_props_follow_the_weapon_in_the_hands() -> void:
	var visual: HumanoidVisual = _make_visual()
	if not assert_not_null(visual):
		return
	var skeleton: Skeleton3D = visual.get_skeleton()
	var animator: CharacterAnimator = visual.get_animator()
	var character: PlayerCharacter = animator.get_character()
	var sword: BoneAttachment3D = skeleton.get_node(NodePath(WeaponProps.SWORD_ATTACHMENT)) as BoneAttachment3D
	var left: BoneAttachment3D = skeleton.get_node(NodePath(WeaponProps.SHIELD_ATTACHMENT)) as BoneAttachment3D
	await wait_process_frames(2)
	assert_eq(animator.get_shown_weapon(), character.combat.weapon_id)
	assert_true(sword.visible, "con la espada y escudo, la espada")
	assert_null(left.get_node_or_null(NodePath(WeaponProps.BOW_MESH)), "el arco aún no existe")
	# Cambia al arco (el estado predicho): se ve el arco y no la espada ni el escudo.
	character.combat.weapon_id = CombatCatalog.weapon_id(&"bow")
	await wait_process_frames(2)
	assert_eq(animator.get_shown_weapon(), CombatCatalog.weapon_id(&"bow"))
	assert_false(sword.visible, "sin espada")
	var bow_node: Node3D = left.get_node_or_null(NodePath(WeaponProps.BOW_MESH)) as Node3D
	if not assert_not_null(bow_node, "el arco provisional en la mano izquierda"):
		return
	assert_true(bow_node.visible)
	assert_false((left.get_node(NodePath(WeaponProps.SHIELD_MESH)) as Node3D).visible, "sin escudo")
	assert_true(bool(bow_node.get_meta(&"placeholder", false)), "marcado como provisional")
	# Un remoto: el arma sale de su vista (pareja y bit de ranura).
	var holder: Array[int] = [CombatCatalog.weapon_id(&"sword_shield")]
	animator.set_remote_source(func() -> int: return 0x30, func() -> int: return holder[0])
	await wait_process_frames(2)
	assert_true(sword.visible, "el remoto lleva la espada")
	assert_false(bow_node.visible)
