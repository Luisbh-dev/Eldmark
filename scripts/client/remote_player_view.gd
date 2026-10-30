class_name RemotePlayerView
extends Node
## Vista de un jugador remoto (docs/red.md, sección 7): gobierna una instancia de
## [code]player_character.tscn[/code] que nunca llama a [method PlayerCharacter.simulate].
## [br][br]
## El cuerpo no colisiona ([code]collision_layer = 0[/code], [code]collision_mask = 0[/code]), no
## tiene proceso de física y no usa la interpolación de física. En [method apply] (una vez por
## fotograma, desde [method RemoteWorld.draw]) se le escriben [code]global_position[/code],
## [code]yaw[/code], [code]velocity[/code] y [code]grounded[/code] a partir de la muestra
## interpolada ([RemoteInterpolator]). Así la capa de animación ([CharacterAnimator]) anima igual a
## locales y remotos: lee esos mismos campos y las señales [signal PlayerCharacter.jumped] y
## [signal PlayerCharacter.landed], que esta vista emite cuando detecta los flancos entre dos
## fotogramas consecutivos (despegar subiendo, o volver a pisar el suelo).
## [br][br]
## [b]Aparición y desaparición.[/b] El cuerpo se muestra cuando el instante de dibujo alcanza el
## [code]spawn_tick[/code] y se quita cuando alcanza el [code]despawn_tick[/code]
## ([method schedule_despawn]), no cuando llega el mensaje, para que no se esfume antes de lo que se
## ve. Los registros fuera de [code][spawn_tick, despawn_tick)[/code] se ignoran.
## [br][br]
## [b]Vuelta tras extrapolar.[/b] Si el instante de dibujo iba por delante de la última muestra
## (extrapolación) y llegan datos nuevos, el salto entre lo que ya se dibujó y lo que dicen los
## datos se convierte en un desfase que decae con una semivida de [constant OFFSET_HALF_LIFE] s
## (tiempo real) si está entre [constant MIN_BLEND_DISTANCE] y [constant MAX_BLEND_DISTANCE]
## metros; si pasa de ahí, o hay un teletransporte, se salta directamente.
## [br][br]
## [b]Armas[/b] (docs/habilidades.md, sección 5.2; PRG-07): la pareja de armas en orden de ranura sale del
## SPAWN (y la cambia un LOADOUT, [method set_weapons]) y la ranura activa, del bit 3 de [code]flags[/code]
## del registro dibujado: [method get_active_weapon_id] es el arma que se ve en sus manos y con la que se
## anima.

## Señal de que un remoto despegó subiendo: velocidad vertical mínima (m/s) para considerarlo un
## salto y no una caída por un borde.
const JUMP_MIN_VELOCITY: float = 2.0
## Saltos menores que esto (m) al volver los datos se ignoran.
const MIN_BLEND_DISTANCE: float = 0.05
## Saltos mayores que esto (m) al volver los datos se aplican de golpe.
const MAX_BLEND_DISTANCE: float = 1.5
## Semivida (s) del desfase de vuelta tras extrapolar (tiempo real).
const OFFSET_HALF_LIFE: float = 0.1
## Por debajo de esta longitud (m) el desfase se anula.
const MIN_OFFSET: float = 0.001

var _body: PlayerCharacter = null
var _interpolator: RemoteInterpolator = RemoteInterpolator.new()
var _net_id: int = 0
var _kind: int = NetProtocol.EntityKind.PLAYER
var _display_name: String = ""
var _npc_def_id: int = 0
var _realm: int = NetProtocol.Realm.NONE
var _spawn_tick: int = 0
var _despawn_tick: int = -1
var _drawn_position: Vector3 = Vector3.ZERO
# Desfase (mundo) que se suma a la muestra interpolada y decae en cada apply().
var _offset: Vector3 = Vector3.ZERO
var _has_drawn: bool = false
var _drawn_visible: bool = false
var _was_grounded: bool = true
var _last_render_time: float = 0.0
# Posición de la muestra (sin desfase) y contador de teletransporte del último apply().
var _last_sample_position: Vector3 = Vector3.ZERO
var _last_teleport: int = 0
var _extrapolating: bool = false
var _jumped_count: int = 0
var _landed_count: int = 0
# Byte action (acción, fase y paso del combo o contador de reinicio) y vida cuantizada del último registro dibujado.
var _drawn_action: int = 0
var _drawn_health_q: int = EntityRecord.HEALTH_Q_FULL
# Armas en orden de ranura (0 = ninguna) y si el registro dibujado lleva la ranura 2 activa.
var _weapon_1: int = 0
var _weapon_2: int = 0
var _drawn_second_slot: bool = false
# Nivel (protocolo 7): el del SPAWN (0 si el remoto es de otro reino) o el de su último LEVEL_UP.
var _level: int = 0
# Los 8 B de la apariencia del SPAWN (protocolo 7; sin validar).
var _appearance: PackedByteArray = PackedByteArray()


## Toma el control de [param body] (un [PlayerCharacter] recién instanciado) y le pone como primera
## muestra el estado del SPAWN. Si el cuerpo aún no ha entrado en el árbol, la configuración que
## desactiva sus colisiones se aplica cuando esté listo (su [code]_ready()[/code] las activa).
func setup(body: PlayerCharacter, spawn: NetMessages.EntitySpawn) -> void:
	_body = body
	_net_id = spawn.net_id
	_kind = spawn.kind
	_display_name = spawn.display_name
	_npc_def_id = spawn.npc_def_id
	_realm = spawn.realm
	_spawn_tick = spawn.spawn_tick
	_despawn_tick = -1
	_level = spawn.level
	_appearance = spawn.appearance.duplicate()
	if body.is_node_ready():
		_configure_body()
	else:
		body.ready.connect(_configure_body, CONNECT_ONE_SHOT)
	# Oculto hasta que el instante de dibujo alcance el tick de aparición.
	body.visible = false
	body.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	var first: EntityRecord = EntityRecord.from_state(spawn.net_id, spawn.kind, spawn.state,
			spawn.teleport_counter)
	_interpolator.push(spawn.spawn_tick, first)
	_place(first)
	_last_teleport = first.get_teleport_counter()
	_last_sample_position = first.position
	_was_grounded = first.is_grounded()
	_drawn_action = first.action
	_drawn_health_q = first.health_q
	_drawn_second_slot = first.is_second_slot()
	var combat: CombatState = spawn.state.combat
	if combat.is_second_slot():
		set_weapons(combat.alt_weapon_id, combat.weapon_id)
	else:
		set_weapons(combat.weapon_id, combat.alt_weapon_id)


## Guarda la muestra del snapshot [param tick]. Se ignora si cae fuera de
## [code][spawn_tick, despawn_tick)[/code]. Si el remoto estaba extrapolando, el salto entre lo ya
## dibujado y lo que dicen los datos nuevos se reparte en un desfase (ver la descripción de la
## clase).
func push(tick: int, record: EntityRecord) -> void:
	if not accepts_tick(tick):
		return
	var was_extrapolating: bool = _extrapolating and _has_drawn
	_interpolator.push(tick, record)
	if not was_extrapolating:
		return
	var corrected: EntityRecord = _interpolator.sample(_last_render_time)
	if corrected == null:
		return
	if corrected.get_teleport_counter() != _last_teleport:
		_offset = Vector3.ZERO
		return
	var jump: Vector3 = _last_sample_position - corrected.position
	var distance: float = jump.length()
	if distance > MAX_BLEND_DISTANCE:
		_offset = Vector3.ZERO
	elif distance > MIN_BLEND_DISTANCE:
		_offset += jump
	# Lo ya dibujado ya no cambia: la referencia de la próxima comparación son los datos nuevos.
	_last_sample_position = corrected.position
	_extrapolating = _last_render_time > float(_interpolator.get_newest_tick())


## Dibuja al remoto en el instante [param render_time] (ticks con fracción): muestra u oculta el
## cuerpo según [code]spawn_tick[/code] y [code]despawn_tick[/code], escribe su posición, yaw,
## velocidad y suelo, y emite [signal PlayerCharacter.jumped] y [signal PlayerCharacter.landed]
## cuando hay un flanco. [param real_delta] (segundos reales) hace decaer el desfase de vuelta.
func apply(render_time: float, real_delta: float) -> void:
	if not is_instance_valid(_body):
		return
	var should_show: bool = render_time >= float(_spawn_tick) and not is_expired(render_time)
	if should_show != _drawn_visible:
		_drawn_visible = should_show
		_body.visible = should_show
	_last_render_time = render_time
	var record: EntityRecord = _interpolator.sample(render_time)
	if record == null:
		return
	_extrapolating = render_time > float(_interpolator.get_newest_tick())
	_decay_offset(real_delta)
	if record.get_teleport_counter() != _last_teleport:
		_offset = Vector3.ZERO
	_last_teleport = record.get_teleport_counter()
	_last_sample_position = record.position
	_drawn_action = record.action
	_drawn_health_q = record.health_q
	_drawn_second_slot = record.is_second_slot()
	_place(record)
	if _has_drawn and should_show:
		_emit_flanks(record)
	_was_grounded = record.is_grounded()
	_has_drawn = true


## Programa la desaparición: el remoto se quita cuando el instante de dibujo llega a
## [param tick]. Los registros de ese tick en adelante se ignoran.
func schedule_despawn(tick: int) -> void:
	_despawn_tick = tick


## true si el instante de dibujo [param render_time] ya alcanzó el tick de desaparición.
func is_expired(render_time: float) -> bool:
	return _despawn_tick >= 0 and render_time >= float(_despawn_tick)


## Posición global que se dibujó en el último [method apply] (con el desfase de vuelta).
func get_drawn_position() -> Vector3:
	return _drawn_position


## Posición de cada muestra guardada del remoto, sin interpolar (para marcarlas en la depuración).
func get_sample_positions() -> PackedVector3Array:
	return _interpolator.get_sample_positions()


## true si el registro del tick [param tick] pertenece a esta vista: no es anterior al alta ni
## posterior (o igual) a la baja programada.
func accepts_tick(tick: int) -> bool:
	return tick >= _spawn_tick and (_despawn_tick < 0 or tick < _despawn_tick)


## true si ya se programó la desaparición.
func is_despawn_scheduled() -> bool:
	return _despawn_tick >= 0


## Cuerpo gobernado por la vista.
func get_body() -> PlayerCharacter:
	return _body


func get_net_id() -> int:
	return _net_id


func get_kind() -> int:
	return _kind


func get_display_name() -> String:
	return _display_name


## Id de la definición de PNJ del SPAWN (0 en un jugador o un PNJ sin definición): con él se sabe si
## es un jefe ([BossInfo]).
func get_npc_def_id() -> int:
	return _npc_def_id


func get_realm() -> int:
	return _realm


func get_spawn_tick() -> int:
	return _spawn_tick


## Tick de desaparición programado, o -1.
func get_despawn_tick() -> int:
	return _despawn_tick


## true si el cuerpo se está mostrando (ya ha alcanzado su alta y todavía no su baja).
func is_drawn() -> bool:
	return _drawn_visible


## Byte [code]action[/code] del registro dibujado (docs/combate.md, sección 3.4: bits 0-3 la
## acción, 4-5 la fase y 6-7 el paso del combo o el contador de reinicio; [ActionWire]). Lo lee el
## animador de combate del remoto.
func get_drawn_action() -> int:
	return _drawn_action


## Vida cuantizada ([method EntityRecord.quantize_health]) del registro dibujado: 0 muerto, 1-255
## vivo. Lo leen las placas de nombre.
func get_drawn_health_q() -> int:
	return _drawn_health_q


## Nivel del remoto (docs/progresion.md §7.3): el de su SPAWN o su último LEVEL_UP; 0 si es de otro reino (el nivel
## del enemigo no cruza) o la zona no tiene progreso.
func get_level() -> int:
	return _level


## Un LEVEL_UP del remoto (ya en su tick de dibujo): su nivel nuevo.
func set_level(level: int) -> void:
	_level = clampi(level, 0, ProgressMessages.MAX_LEVEL)


## Los 8 B de la apariencia de su SPAWN, tal cual llegaron (los valida [method AppearanceApplier.resolve]).
func get_appearance() -> PackedByteArray:
	return _appearance


## Pareja de armas del remoto en orden de ranura ([param weapon_1] la de la ranura 1; 0 = ninguna): la del
## SPAWN o la de un LOADOUT.
func set_weapons(weapon_1: int, weapon_2: int) -> void:
	_weapon_1 = weapon_1
	_weapon_2 = weapon_2


## Armas en orden de ranura (x la 1, y la 2).
func get_weapons() -> Vector2i:
	return Vector2i(_weapon_1, _weapon_2)


## true si el registro dibujado lleva la ranura 2 activa (bit 3 de [code]flags[/code]).
func is_drawn_second_slot() -> bool:
	return _drawn_second_slot


## Arma que lleva en las manos según lo dibujado: la de la ranura 2 si su bit está puesto (y la tiene), si
## no la de la ranura 1.
func get_active_weapon_id() -> int:
	if _drawn_second_slot and _weapon_2 != 0:
		return _weapon_2
	return _weapon_1


## Desfase de vuelta tras extrapolar que se suma ahora a la muestra (m, en el mundo).
func get_blend_offset() -> Vector3:
	return _offset


## Número de saltos y aterrizajes que ha emitido.
func get_jumped_count() -> int:
	return _jumped_count


func get_landed_count() -> int:
	return _landed_count


## Muestras guardadas por el interpolador.
func get_interpolator() -> RemoteInterpolator:
	return _interpolator


# Sin colisiones ni proceso de física ni interpolación de física: el cuerpo solo se dibuja.
func _configure_body() -> void:
	if not is_instance_valid(_body):
		return
	_body.collision_layer = 0
	_body.collision_mask = 0
	_body.set_physics_process(false)
	_body.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF


# Escribe en el cuerpo lo que las demás capas leen: posición, yaw, velocidad y suelo.
func _place(record: EntityRecord) -> void:
	var position: Vector3 = record.position + _offset
	_drawn_position = position
	if _body.is_inside_tree():
		_body.global_position = position
	else:
		_body.position = position
	_body.yaw = record.yaw
	_body.velocity = record.velocity
	_body.grounded = record.is_grounded()


func _decay_offset(real_delta: float) -> void:
	if _offset == Vector3.ZERO:
		return
	_offset *= pow(0.5, maxf(real_delta, 0.0) / OFFSET_HALF_LIFE)
	if _offset.length() < MIN_OFFSET:
		_offset = Vector3.ZERO


# Despegar subiendo es un salto; volver al suelo es un aterrizaje. Caer por un borde (despegar sin
# subir) no es un salto: la animación lo deduce del cambio de "grounded".
func _emit_flanks(record: EntityRecord) -> void:
	var grounded: bool = record.is_grounded()
	if _was_grounded and not grounded and record.velocity.y > JUMP_MIN_VELOCITY:
		_jumped_count += 1
		_body.jumped.emit()
	elif not _was_grounded and grounded:
		_landed_count += 1
		_body.landed.emit()
