class_name RemoteWorld
extends Node3D
## Mundo de los jugadores remotos (docs/red.md, sección 7): crea una [RemotePlayerView] por entidad
## remota y la mantiene al día con los mensajes del servidor.
## [br][br]
## [NetClient] le pasa los ENTITY_SPAWN ajenos ([method on_spawn]), los ENTITY_DESPAWN
## ([method on_despawn]) y todos los snapshots ([method on_snapshot], también los desordenados: solo
## alimentan a los interpoladores). Los registros de un [code]net_id[/code] que todavía no se
## conoce se ignoran, igual que los anteriores al alta o posteriores a la baja programada: los
## canales fiable y de snapshots no están ordenados entre sí.
## [br][br]
## [b]Dibujo.[/b] En cada fotograma ([method _process]) los remotos se dibujan en el instante
## [code]render_tick + Engine.get_physics_interpolation_fraction()[/code] del
## [InterpolationClock], así que cada fotograma usa su tiempo exacto, sin el sesgo de medio tick
## que tendría aplicarlos en el tick de física. El instante usado se guarda
## ([method get_last_drawn_render_tick]) porque es lo que el jugador estaba viendo: [NetClient] lo
## manda al servidor con cada entrada.
## [br][br]
## Si un mismo [code]net_id[/code] vuelve a aparecer mientras la vista anterior sigue en pantalla
## (sale de interés y vuelve a entrar), la vista vieja se queda hasta su tick de baja y la nueva
## aparece en el suyo, cada una con sus propios registros.

const PLAYER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"

## true: a cada remoto se le instala el visual animado ([HumanoidVisual]). Por defecto, solo si hay
## pantalla; en un cliente headless (bots) bastan las cápsulas provisionales.
var install_visuals: bool = DisplayServer.get_name() != "headless"

var _clock: InterpolationClock = null
var _player_scene: PackedScene = null
## net_id -> vista vigente (la más reciente de ese id).
var _views: Dictionary[int, RemotePlayerView] = {}
## Vistas que ya tienen programada la baja y han sido sustituidas por otra del mismo net_id.
var _retiring: Array[RemotePlayerView] = []
var _last_drawn_render_tick: float = 0.0
var _spawn_count: int = 0
var _despawn_count: int = 0
var _ignored_records: int = 0


func _init() -> void:
	name = "RemoteWorld"
	# Antes que el animador (prioridad -1): el estado de este fotograma ya está escrito cuando
	# el animador lo lee.
	process_priority = -10
	# Cada remoto se coloca en el mundo con global_position; el propio nodo no se mueve.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF


## Reloj que dice qué instante se dibuja ([NetClient] lo avanza en cada tick de física).
func setup(clock: InterpolationClock) -> void:
	_clock = clock


## ENTITY_SPAWN de otra entidad: crea su vista con la primera muestra del mensaje. Ignora el SPAWN
## propio ([code]is_yours[/code]), los repetidos y los que no son personajes (los proyectiles, kind 3,
## los dibuja otro; las estructuras no traen estado).
func on_spawn(msg: NetMessages.EntitySpawn) -> void:
	if msg == null or msg.is_yours or msg.state == null \
			or msg.kind == NetProtocol.EntityKind.PROJECTILE:
		return
	var existing: RemotePlayerView = _views.get(msg.net_id)
	if existing != null:
		if existing.get_spawn_tick() == msg.spawn_tick:
			return
		# Un alta nueva con el mismo id: la vista vieja se queda hasta el tick del alta nueva.
		if not existing.is_despawn_scheduled():
			existing.schedule_despawn(msg.spawn_tick)
		_retiring.append(existing)
	var body: PlayerCharacter = _instantiate_body()
	if body == null:
		return
	body.name = "Remote%d" % msg.net_id
	add_child(body)
	if install_visuals:
		if HumanoidVisual.install_replacing_placeholder(body) == null:
			push_warning("[Eldmark] Sin visual del humanoide para el remoto %d" % msg.net_id)
	var view := RemotePlayerView.new()
	view.name = "View%d" % msg.net_id
	add_child(view)
	view.setup(body, msg)
	# El animador de combate del remoto lee el byte action de su registro dibujado.
	var visual: HumanoidVisual = body.get_node_or_null(^"Visual/HumanoidVisual") as HumanoidVisual
	if visual != null:
		visual.get_animator().set_remote_source(Callable(view, "get_drawn_action"))
	_views[msg.net_id] = view
	_spawn_count += 1


## ENTITY_DESPAWN: programa la baja de la vista vigente de esa entidad. Ignora ids desconocidos.
func on_despawn(msg: NetMessages.EntityDespawn) -> void:
	if msg == null:
		return
	var view: RemotePlayerView = _views.get(msg.net_id)
	if view == null or view.is_despawn_scheduled():
		return
	view.schedule_despawn(msg.despawn_tick)
	_despawn_count += 1


## Reparte los registros de un SNAPSHOT entre las vistas. Ignora los de ids que no conoce y los
## que caen fuera de [code][spawn_tick, despawn_tick)[/code] de la vista.
func on_snapshot(snapshot: NetMessages.Snapshot) -> void:
	if snapshot == null:
		return
	var tick: int = snapshot.server_tick
	for record: EntityRecord in snapshot.records:
		var delivered: bool = false
		var view: RemotePlayerView = _views.get(record.net_id)
		if view != null and view.accepts_tick(tick):
			view.push(tick, record)
			delivered = true
		for retiring: RemotePlayerView in _retiring:
			if retiring.get_net_id() == record.net_id and retiring.accepts_tick(tick):
				retiring.push(tick, record)
				delivered = true
		if not delivered:
			_ignored_records += 1


## Vista vigente de la entidad [param net_id], o null.
func get_view(net_id: int) -> RemotePlayerView:
	return _views.get(net_id)


## Vistas vigentes (no cuenta las que ya tienen la baja programada y han sido sustituidas).
func get_view_count() -> int:
	return _views.size()


## Todas las vistas vivas, también las que se están retirando.
func get_views() -> Array[RemotePlayerView]:
	var views: Array[RemotePlayerView] = []
	views.assign(_views.values())
	views.append_array(_retiring)
	return views


## [code]render_tick + fracción[/code] usado en el último dibujo.
func get_last_drawn_render_tick() -> float:
	return _last_drawn_render_tick


## Remotos que se han creado, bajas programadas y registros ignorados desde que existe.
func get_stats() -> Dictionary:
	return {
		"spawned": _spawn_count,
		"despawns": _despawn_count,
		"ignored_records": _ignored_records,
		"views": _views.size(),
	}


func _process(delta: float) -> void:
	# Hasta que llega el primer snapshot el reloj no ha arrancado (tick de dibujo 0): no hay nada
	# que dibujar ni un instante que recordar.
	if _clock == null or _clock.get_render_tick() <= 0.0:
		return
	draw(_clock.get_render_tick() + Engine.get_physics_interpolation_fraction(), delta)


## Dibuja a todos los remotos en [param render_time] (ticks con fracción) y quita los que ya han
## alcanzado su tick de baja. [method _process] lo llama con el instante del reloj; las pruebas,
## con instantes exactos.
func draw(render_time: float, real_delta: float) -> void:
	_last_drawn_render_tick = render_time
	for view: RemotePlayerView in _views.values():
		view.apply(render_time, real_delta)
	for view: RemotePlayerView in _retiring:
		view.apply(render_time, real_delta)
	_remove_expired(render_time)


func _remove_expired(render_time: float) -> void:
	for net_id: int in _views.keys():
		var view: RemotePlayerView = _views[net_id]
		if view.is_expired(render_time):
			_views.erase(net_id)
			_free_view(view)
	var still: Array[RemotePlayerView] = []
	for view: RemotePlayerView in _retiring:
		if view.is_expired(render_time):
			_free_view(view)
		else:
			still.append(view)
	_retiring = still


func _free_view(view: RemotePlayerView) -> void:
	var body: PlayerCharacter = view.get_body()
	if is_instance_valid(body):
		body.get_parent().remove_child(body)
		body.queue_free()
	if view.get_parent() != null:
		view.get_parent().remove_child(view)
	view.queue_free()


func _instantiate_body() -> PlayerCharacter:
	if _player_scene == null:
		_player_scene = load(PLAYER_SCENE_PATH) as PackedScene
	if _player_scene == null:
		push_error("[Eldmark] No se pudo cargar la escena %s" % PLAYER_SCENE_PATH)
		return null
	return _player_scene.instantiate() as PlayerCharacter
