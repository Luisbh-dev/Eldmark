class_name RemoteWorld
extends Node3D
## World of the remote players (docs/red.md, section 7): creates one [RemotePlayerView] per remote
## entity and keeps it up to date with the server's messages.
## [br][br]
## [NetClient] passes it other entities' ENTITY_SPAWN ([method on_spawn]), the ENTITY_DESPAWN
## ([method on_despawn]) and all the snapshots ([method on_snapshot], including out-of-order ones: they
## only feed the interpolators). Records of a [code]net_id[/code] that is not yet known are ignored, as
## are those earlier than the spawn or later than the scheduled despawn: the reliable and snapshot
## channels are not ordered relative to each other.
## [br][br]
## [b]Drawing.[/b] On every frame ([method _process]) the remotes are drawn at the instant
## [code]render_tick + Engine.get_physics_interpolation_fraction()[/code] of the
## [InterpolationClock], so each frame uses its exact time, without the half-tick bias that applying
## them at the physics tick would have. The instant used is stored
## ([method get_last_drawn_render_tick]) because it is what the player was seeing: [NetClient] sends it
## to the server with every input.
## [br][br]
## If the same [code]net_id[/code] appears again while the previous view is still on screen (it leaves
## interest and comes back in), the old view stays until its despawn tick and the new one appears at its
## own, each with its own records.

const PLAYER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"

## true: each remote gets the animated visual installed ([HumanoidVisual]). By default, only if there is
## a display; on a headless client (bots) the placeholder capsules are enough.
var install_visuals: bool = DisplayServer.get_name() != "headless"

var _clock: InterpolationClock = null
var _player_scene: PackedScene = null
## net_id -> current view (the most recent one for that id).
var _views: Dictionary[int, RemotePlayerView] = {}
## Views that already have their despawn scheduled and have been replaced by another with the same net_id.
var _retiring: Array[RemotePlayerView] = []
var _last_drawn_render_tick: float = 0.0
var _spawn_count: int = 0
var _despawn_count: int = 0
var _ignored_records: int = 0


func _init() -> void:
	name = "RemoteWorld"
	# Before the animator (priority -1): this frame's state is already written when the animator reads it.
	process_priority = -10
	# Each remote is placed in the world with global_position; the node itself does not move.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF


## Clock that says which instant is drawn ([NetClient] advances it on every physics tick).
func setup(clock: InterpolationClock) -> void:
	_clock = clock


## ENTITY_SPAWN of another entity: creates its view with the message's first sample. Ignores the player's
## own SPAWN ([code]is_yours[/code]), repeated ones and those that are not characters (projectiles,
## kind 3, are drawn by something else; structures carry no state).
func on_spawn(msg: NetMessages.EntitySpawn) -> void:
	if msg == null or msg.is_yours or msg.state == null \
			or msg.kind == NetProtocol.EntityKind.PROJECTILE:
		return
	var existing: RemotePlayerView = _views.get(msg.net_id)
	if existing != null:
		if existing.get_spawn_tick() == msg.spawn_tick:
			return
		# A new spawn with the same id: the old view stays until the new spawn's tick.
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
	# The remote's combat animator reads the action byte of its drawn record.
	var visual: HumanoidVisual = body.get_node_or_null(^"Visual/HumanoidVisual") as HumanoidVisual
	if visual != null:
		# With no collision between characters, a remote glued to the camera fades out (ART-53).
		visual.camera_fade = true
		visual.get_animator().set_remote_source(Callable(view, "get_drawn_action"),
				Callable(view, "get_active_weapon_id"))
		# Its appearance (protocol 7): the SPAWN's if it is valid for its realm and, if not, the default of its people.
		if msg.kind == NetProtocol.EntityKind.PLAYER:
			AppearanceApplier.apply_bytes(visual, msg.appearance, msg.realm)
	_views[msg.net_id] = view
	_spawn_count += 1


## ENTITY_DESPAWN: schedules the despawn of that entity's current view. Ignores unknown ids.
func on_despawn(msg: NetMessages.EntityDespawn) -> void:
	if msg == null:
		return
	var view: RemotePlayerView = _views.get(msg.net_id)
	if view == null or view.is_despawn_scheduled():
		return
	view.schedule_despawn(msg.despawn_tick)
	_despawn_count += 1


## LOADOUT of a remote (already at its draw tick): its new pair of weapons (docs/habilidades.md, section
## 5.4). Ignores unknown ids.
func on_loadout(event: NetMessages.EntityEvent) -> void:
	if event == null or event.event != NetMessages.EntityEvent.Kind.LOADOUT:
		return
	var view: RemotePlayerView = _views.get(event.net_id)
	if view != null:
		view.set_weapons(event.weapon_1, event.weapon_2)


## LEVEL_UP of a remote (already at its draw tick; only arrives for those of your realm): its new level,
## for its nameplate. Ignores unknown ids.
func on_level_up(event: NetMessages.EntityEvent) -> void:
	if event == null or event.event != NetMessages.EntityEvent.Kind.LEVEL_UP:
		return
	var view: RemotePlayerView = _views.get(event.net_id)
	if view != null:
		view.set_level(event.level)


## Distributes the records of a SNAPSHOT among the views. Ignores those of ids it does not know and those
## that fall outside the view's [code][spawn_tick, despawn_tick)[/code].
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


## Current view of entity [param net_id], or null.
func get_view(net_id: int) -> RemotePlayerView:
	return _views.get(net_id)


## Current views (does not count those that already have their despawn scheduled and have been replaced).
func get_view_count() -> int:
	return _views.size()


## All the live views, including those being retired.
func get_views() -> Array[RemotePlayerView]:
	var views: Array[RemotePlayerView] = []
	views.assign(_views.values())
	views.append_array(_retiring)
	return views


## [code]render_tick + fraction[/code] used in the last draw.
func get_last_drawn_render_tick() -> float:
	return _last_drawn_render_tick


## Remotes created, despawns scheduled and records ignored since it was created.
func get_stats() -> Dictionary:
	return {
		"spawned": _spawn_count,
		"despawns": _despawn_count,
		"ignored_records": _ignored_records,
		"views": _views.size(),
	}


func _process(delta: float) -> void:
	# Until the first snapshot arrives the clock has not started (draw tick 0): there is nothing to draw nor
	# an instant to remember.
	if _clock == null or _clock.get_render_tick() <= 0.0:
		return
	draw(_clock.get_render_tick() + Engine.get_physics_interpolation_fraction(), delta)


## Draws all the remotes at [param render_time] (ticks with fraction) and removes those that have already
## reached their despawn tick. [method _process] calls it with the clock's instant; the tests, with exact
## instants.
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
