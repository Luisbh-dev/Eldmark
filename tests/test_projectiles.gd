extends TestCase
## Los proyectiles del servidor (docs/habilidades.md, sección 4.4; paquete H3b, CMB-22): ninguna flecha
## atraviesa un muro (40 disparos con ángulos distintos a un blanco tras él), el disparo pegado a una
## esquina da en la esquina aunque la cámara vea el blanco, desde el vano de la puerta cerrada la flecha se
## clava en el origen, el escudo de frente la bloquea (nunca la para), la esquiva la deja pasar, la caja
## del muro de escudos para las flechas que llegan de frente a quien está detrás (desde lejos y con el
## arquero dentro de ella) y no las de un arquero detrás de quien lo sostiene, un segmento que empieza
## dentro de una cápsula da a quemarropa, los topes (8 por tirador, 64 por zona) retiran la más vieja y el
## disparo nuevo existe, el tirador que se va se lleva sus flechas (DESPAWN 5) y una flecha golpea la
## puerta con su parte perforante. Además: el vuelo contra posiciones rebobinadas (y el control sin
## rebobinar, en la misma ejecución), el rebobinado rechazado y la zona segura dan flechas inofensivas, el
## abanico, la carga del tensado, la flecha lastrante, la interrupción, la balística igual a la del SPAWN,
## la caducidad, la flecha del servidor igual a la que predice el cliente ([ProjectileLaunch]), un arquero
## falso en un [ZoneServer] y el SPAWN y el DESPAWN que llegan por red al cliente que ve al tirador.
## [br][br]
## Las cortas montan los luchadores a mano y avanzan el [CombatDirector] tick a tick (como
## test_ability_server); las del servidor avanzan un [ZoneServer] sin red con [code]_physics_process[/code];
## la de red usa ENet en 127.0.0.1 ([NetHarness]).

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ZONE_ID: StringName = &"test_world"
const S: int = 400
const HIT: int = NetMessages.EntityEvent.Kind.HIT
const IMPACT: int = NetProtocol.DespawnReason.IMPACT
const EXPIRED: int = NetProtocol.DespawnReason.EXPIRED
const GATE_SCENE: String = "res://scenes/world/props/fort/fort_gate.tscn"
const TICK_DELTA: float = 1.0 / 60.0
## Centro del cuerpo de un blanco (sobre los pies), al que se apunta.
const CENTER: Vector3 = Vector3(0.0, 0.9, 0.0)
const WAIT_FRAMES: int = 900

var _viewport: SubViewport
var _world: Node3D
var _history: StateHistory
var _safe_areas: SafeAreas
var _director: CombatDirector
var _events: Array[NetMessages.EntityEvent] = []
var _spawns: Array[NetMessages.EntitySpawn] = []
## Bajas: [code]{id, tick, reason}[/code].
var _despawns: Array[Dictionary] = []
# Servidor de las pruebas con ZoneServer (null en las demás) y lo de la prueba de red.
var _server: ZoneServer = null
var _server_viewport: SubViewport = null
var _client_viewport: SubViewport = null
var _client: NetClient = null
# El servidor de la prueba de red tiene transporte: se libera con su viewport, sin stop().
var _server_has_transport: bool = false


func before_each() -> void:
	_viewport = CombatFixture.make_world(tree.root)
	_world = NetHarness.get_world(_viewport)
	_history = StateHistory.new()
	_safe_areas = SafeAreas.new()
	_director = CombatDirector.new(_history, ZONE_ID, _world, _safe_areas, CombatFixture.place,
			func(realm: int) -> Transform3D:
				return Transform3D(Basis.IDENTITY, Vector3(100.0 + float(realm), 0.0, 100.0)))
	_events.clear()
	_spawns.clear()
	_despawns.clear()
	_director.event_emitted.connect(func(event: NetMessages.EntityEvent,
			_involved: PackedInt32Array) -> void: _events.append(event))
	_watch(_director.projectiles)
	await wait_physics_frames(3)


func after_each() -> void:
	_director = null
	if is_instance_valid(_client_viewport):
		_client_viewport.free()
	_client_viewport = null
	_client = null
	if is_instance_valid(_server) and not _server_has_transport:
		_server.stop()
		_server.free()
	_server = null
	_server_has_transport = false
	for viewport: SubViewport in [_viewport, _server_viewport]:
		if is_instance_valid(viewport):
			viewport.get_parent().remove_child(viewport)
			viewport.free()
	_viewport = null
	_server_viewport = null
	_world = null
	await wait_process_frames()


# --- Ayudantes --------------------------------------------------------------------------------

func _watch(system: ProjectileSystem) -> void:
	system.spawned.connect(func(spawn: NetMessages.EntitySpawn, _recipients: PackedInt32Array) -> void:
		_spawns.append(spawn))
	system.despawned.connect(func(projectile_id: int, tick: int, reason: int,
			_recipients: PackedInt32Array) -> void:
		_despawns.append({"id": projectile_id, "tick": tick, "reason": reason}))


func _space() -> PhysicsDirectSpaceState3D:
	return _world.get_world_3d().direct_space_state


func _body(net_id: int, realm: int, position: Vector3, yaw: float, peer: ServerPeer = null) -> Combatant:
	var entity: NetEntity = CombatFixture.make_entity(_world, net_id, realm, position, yaw)
	_history.add_entity(net_id)
	return _director.add(entity, CombatFixture.make_queue(yaw), peer)


func _tick(s: int) -> void:
	_director.process_tick(s, _space())


func _run(from: int, to: int) -> void:
	for tick: int in range(from, to):
		_tick(tick)


## Una caja estática del mundo (capa 1) centrada en [param center] de tamaño [param size].
func _add_box(center: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = PlayerCharacter.WORLD_COLLISION_LAYER
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	_world.add_child(body)
	body.global_position = center
	return body


## Deja en la cola de [param fighter] la entrada simulada en [param s] con la cámara hacia [param point]
## (el rayo canónico pasa por él) y [param view_offset] ticks de vista atrás.
func _aim(fighter: Combatant, s: int, point: Vector3, left: bool = false, view_offset: int = 0) -> void:
	var look: Vector2 = AimRay.look_for(fighter.entity.get_position(), point, left)
	var input := PlayerInput.new()
	input.tick = s
	input.look_yaw = look.x
	input.look_pitch = look.y
	if left:
		input.buttons = PlayerInput.AIM_LEFT
	fighter.queue.reset(s - 1, NetProtocol.neutral_input(s - 1, look.x))
	fighter.queue.push(input.quantized(), view_offset * CombatResolver.VIEW_OFFSET_Q_SCALE, s)
	fighter.queue.take(s)


## Pone a [param shooter] con el arco en el compromiso (el primer tick activo) del ataque
## [param attack_name] en el tick [param s], apuntando a [param point], con [param charge_ticks] de carga si
## es el tensado.
func _shoot(shooter: Combatant, attack_name: StringName, s: int, point: Vector3, charge_ticks: int = 0,
		view_offset: int = 0, left: bool = false) -> void:
	var attack: AttackTicks = CombatCatalog.attack(CombatCatalog.attack_id(attack_name))
	assert_not_null(attack, "el ataque %s existe" % attack_name)
	var combat: CombatState = shooter.get_character().combat
	combat.weapon_id = CombatCatalog.weapon_id(&"bow")
	combat.action = CombatState.Action.HEAVY if attack.heavy else CombatState.Action.LIGHT
	combat.action_id = attack.id
	combat.action_tick = s - attack.windup_ticks
	combat.charge_ticks = charge_ticks
	_aim(shooter, s, point, left, view_offset)


## Lo mismo con la habilidad [param ability_name] (su compromiso es el primer tick activo).
func _cast(shooter: Combatant, ability_name: StringName, s: int, point: Vector3) -> AbilityTicks:
	var ability: AbilityTicks = CombatCatalog.ability(CombatCatalog.ability_id(ability_name))
	assert_not_null(ability, "la habilidad %s existe" % ability_name)
	var combat: CombatState = shooter.get_character().combat
	combat.weapon_id = CombatCatalog.weapon_id(&"bow")
	combat.action = CombatState.Action.ABILITY
	combat.action_id = ability.id
	combat.action_tick = s - ability.cast_ticks
	_aim(shooter, s, point)
	return ability


## El punto al que apunta un bot para que la flecha que sale del pecho de quien tiene los pies en
## [param feet] a [param speed] m/s llegue a [param target] pese a la caída ([method Ballistics.solve_lead]).
func _over_drop(feet: Vector3, target: Vector3, speed: float) -> Vector3:
	var muzzle: Vector3 = AimRay.muzzle(feet)
	var arrow: ProjectileTicks = CombatCatalog.projectile(CombatCatalog.projectile_id(&"arrow"))
	return muzzle + Ballistics.solve_lead(muzzle, target, Vector3.ZERO, speed, arrow.gravity) \
			* muzzle.distance_to(target)


func _center_of(fighter: Combatant) -> Vector3:
	return fighter.entity.get_position() + CENTER


func _hits_on(net_id: int, events: Array[NetMessages.EntityEvent] = _events) -> Array[NetMessages.EntityEvent]:
	var found: Array[NetMessages.EntityEvent] = []
	for event: NetMessages.EntityEvent in events:
		if event.event == HIT and event.net_id == net_id:
			found.append(event)
	return found


func _spawns_of(owner_id: int) -> Array[NetMessages.EntitySpawn]:
	var found: Array[NetMessages.EntitySpawn] = []
	for spawn: NetMessages.EntitySpawn in _spawns:
		if spawn.owner_id == owner_id:
			found.append(spawn)
	return found


func _despawn_of(projectile_id: int) -> Dictionary:
	for despawn: Dictionary in _despawns:
		if despawn["id"] == projectile_id:
			return despawn
	return {}


## Posición de la flecha del SPAWN [param spawn] tras [param ticks] ticks de vuelo.
func _arrow_at(spawn: NetMessages.EntitySpawn, ticks: float) -> Vector3:
	var definition: ProjectileTicks = CombatCatalog.projectile(spawn.projectile_def_id)
	return Ballistics.position(spawn.origin, spawn.velocity, definition.gravity, ticks)


## El segmento en el que acabó la flecha [param spawn]: [code][pos(n), pos(n + 1)][/code] con
## [code]n = despawn_tick − spawn_tick[/code].
func _last_segment(spawn: NetMessages.EntitySpawn) -> Array[Vector3]:
	var despawn: Dictionary = _despawn_of(spawn.net_id)
	var flown: int = int(despawn.get("tick", spawn.spawn_tick)) - spawn.spawn_tick
	return [_arrow_at(spawn, float(flown)), _arrow_at(spawn, float(flown + 1))]


# --- Muros y esquinas -------------------------------------------------------------------------

func test_no_arrow_goes_through_a_wall() -> void:
	# Un muro de 40 x 8 m y 0,5 de grueso a 10 m (cara delantera en z = -9,75) y el blanco a 15 m detrás.
	var wall: StaticBody3D = _add_box(Vector3(0.0, 4.0, -10.0), Vector3(40.0, 8.0, 0.5))
	await wait_physics_frames(2)
	var archer: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var target: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -15.0), PI)
	assert_false(HitShapes.has_line_of_sight(_space(), Vector3.ZERO, target.entity.get_position()),
			"el muro tapa al blanco")
	for shot: int in 40:
		# 8 desfases laterales por 5 alturas alrededor del blanco: ángulos distintos, todos contra el muro.
		@warning_ignore("integer_division")
		var offset := Vector3((float(shot % 8) - 3.5) * 0.8, float(shot / 8) * 0.7 - 0.8, 0.0)
		var s: int = S + shot * 20
		_shoot(archer, &"bow_quick", s, _center_of(target) + offset)
		_run(s, s + 20)
	assert_eq(_spawns.size(), 40, "40 flechas")
	assert_eq(_hits_on(2).size(), 0, "ninguna atraviesa el muro")
	assert_eq(target.health, 1000)
	var at_the_wall: int = 0
	for spawn: NetMessages.EntitySpawn in _spawns:
		var despawn: Dictionary = _despawn_of(spawn.net_id)
		if despawn.get("reason", -1) != IMPACT:
			continue
		var segment: Array[Vector3] = _last_segment(spawn)
		if segment[0].z >= -9.75 - 0.001 and segment[1].z <= -9.75 + 0.001:
			at_the_wall += 1
	assert_eq(at_the_wall, 40, "todas acaban con DESPAWN 4 en el segmento que cruza la cara del muro")
	assert_eq(_director.projectiles.live_count(), 0)
	# Control en la misma ejecución: sin el muro, el mismo disparo al centro del blanco acierta.
	wall.collision_layer = 0
	await wait_physics_frames(2)
	_shoot(archer, &"bow_quick", S + 1000, _center_of(target))
	_run(S + 1000, S + 1030)
	assert_eq(_hits_on(2).size(), 1, "sin muro, la flecha da al blanco")


func test_a_shot_pressed_against_a_corner_hits_the_corner() -> void:
	# Una pared a la izquierda por delante (x de -10 a 0,3; z de -3 a -2): el pecho (x = 0) queda detrás de
	# su esquina y la cámara (hombro derecho, x = 0,6) ve más allá.
	_add_box(Vector3(-4.85, 2.0, -2.5), Vector3(10.3, 4.0, 1.0))
	await wait_physics_frames(2)
	var archer: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var target: Combatant = _body(2, SOLMARCH, Vector3(0.6, 0.0, -15.0), PI)
	var look: Vector2 = AimRay.look_for(Vector3.ZERO, _center_of(target), false)
	var camera: Vector3 = AimRay.canonical(Vector3.ZERO, look.x, look.y, false)[0]
	assert_true(HitShapes.is_ray_clear(_space(), camera, _center_of(target)), "la cámara ve al blanco")
	assert_false(HitShapes.is_ray_clear(_space(), AimRay.muzzle(Vector3.ZERO), _center_of(target)),
			"el pecho no")
	_shoot(archer, &"bow_quick", S, _center_of(target))
	_run(S, S + 40)
	assert_eq(_hits_on(2).size(), 0, "la flecha no sale por el lado de la cámara")
	if not assert_eq(_spawns.size(), 1):
		return
	var despawn: Dictionary = _despawn_of(_spawns[0].net_id)
	assert_eq(despawn.get("reason", -1), IMPACT, "se clava")
	var segment: Array[Vector3] = _last_segment(_spawns[0])
	assert_true(segment[0].z >= -2.0 - 0.001 and segment[1].z <= -2.0 + 0.001,
			"en la cara de la esquina (z = -2): %s" % [segment])
	assert_true(segment[0].x < 0.3, "por el lado del pecho")


func test_from_inside_a_closed_gate_the_arrow_sticks_at_its_origin() -> void:
	var gate: FortGate = (load(GATE_SCENE) as PackedScene).instantiate() as FortGate
	_world.add_child(gate)
	gate.set_state(VARDHEIM, false)
	await wait_physics_frames(2)
	# El dueño con los pies en el vano (el pecho dentro de la caja de vista de 0,5 m) dispara al oeste.
	var owner: Combatant = _body(1, VARDHEIM, Vector3(0.0, 0.0, 0.5), PI * 0.5)
	var enemy: Combatant = _body(2, SOLMARCH, Vector3(-6.0, 0.0, 0.5), -PI * 0.5)
	_shoot(owner, &"bow_quick", S, _center_of(enemy))
	_run(S, S + 20)
	assert_eq(_hits_on(2).size(), 0, "desde el vano cerrado no se dispara hacia fuera")
	if not assert_eq(_spawns.size(), 1):
		return
	assert_eq(_despawn_of(_spawns[0].net_id), {"id": _spawns[0].net_id, "tick": S, "reason": IMPACT},
			"DESPAWN 4 en el tick del disparo: se clava en el origen")
	assert_vec_near(_spawns[0].origin, Vector3(0.0, 1.4, 0.5), 0.011, "sale del pecho, dentro de la caja")
	# Con la puerta rota no hay caja: la flecha sale.
	gate.set_state(VARDHEIM, true)
	await wait_physics_frames(2)
	_shoot(owner, &"bow_quick", S + 100, _center_of(enemy))
	_run(S + 100, S + 120)
	assert_eq(_hits_on(2).size(), 1, "rota, la flecha da al enemigo")


# --- Defensas ---------------------------------------------------------------------------------

func test_a_shield_in_front_blocks_an_arrow_and_never_parries_it() -> void:
	# Bloqueando de cara al arquero, con la ventana de parada abierta cuando llega la flecha.
	var archer: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var front: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -2.0), PI)
	CombatFixture.start_block(front, S - 1, true)
	var stamina: int = front.get_character().combat.stamina
	_shoot(archer, &"bow_quick", S, _center_of(front))
	_run(S, S + 10)
	var hits: Array[NetMessages.EntityEvent] = _hits_on(2)
	if assert_eq(hits.size(), 1, "un HIT"):
		assert_true(hits[0].has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_BLOCKED), "bloqueada")
		assert_false(hits[0].has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_PARRIED), "nunca parada")
		assert_eq(hits[0].amount, 0, "el escudo de la espada mitiga todo")
		assert_eq(hits[0].get_source(), CombatCatalog.attack_id(&"bow_quick"), "con la fuente del disparo")
		assert_true(hits[0].tick <= S + 3, "a 2 m llega enseguida")
	assert_eq(front.health, 1000)
	assert_eq(front.get_character().combat.stamina, stamina - 60, "1 de resistencia por punto (el del arma)")
	assert_eq(archer.get_character().combat.action, CombatState.Action.LIGHT, "el arquero no se tambalea")
	assert_eq(_director.stats[&"arrow_blocked"], 1, "registro: arrow_blocked")
	# De espaldas al arquero, el mismo bloqueo no la para.
	var archer_2: Combatant = _body(3, VARDHEIM, Vector3(20.0, 0.0, 0.0), 0.0)
	var back: Combatant = _body(4, SOLMARCH, Vector3(20.0, 0.0, -6.0), 0.0)
	CombatFixture.start_block(back, S + 50)
	_shoot(archer_2, &"bow_quick", S + 100, _center_of(back))
	_run(S + 100, S + 120)
	var behind: Array[NetMessages.EntityEvent] = _hits_on(4)
	if assert_eq(behind.size(), 1, "por la espalda"):
		assert_false(behind[0].has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_BLOCKED), "no bloquea")
		assert_eq(behind[0].amount, 60, "60 perforante, sin crítico")
		assert_eq(behind[0].damage_type, DamageFormula.DamageType.PIERCE)
	assert_eq(_director.stats[&"arrow_hits"], 1, "registro: arrow_hit")


func test_a_dodge_lets_the_arrow_through_to_whoever_is_behind() -> void:
	var archer: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var dodger: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -6.0), PI)
	# El de detrás, lejos: el rayo de la cámara (0,6 m al lado) no roza al que esquiva y la mira converge en
	# el de detrás; la recta del pecho a él sí cruza al que esquiva.
	var behind: Combatant = _body(3, SOLMARCH, Vector3(0.0, 0.0, -30.0), PI)
	# A 45 m/s la flecha recorre 0,75 m por tick: llega al que esquiva hacia S + 7. Invulnerable de S + 3 a S + 18.
	CombatFixture.start_dodge(dodger, S)
	dodger.get_character().combat.weapon_id = CombatCatalog.weapon_id(&"sword_shield")
	# A 30 m la flecha cae 1,3 m: se apunta por encima, como un bot (Ballistics.solve_lead).
	_shoot(archer, &"bow_quick", S, _over_drop(Vector3.ZERO, _center_of(behind), 45.0))
	_run(S, S + 50)
	assert_eq(_hits_on(2).size(), 0, "la esquiva la deja pasar")
	assert_eq(dodger.health, 1000)
	assert_eq(_director.stats[&"invulnerable"], 1, "una vez: no vuelve a probarlo")
	var hits: Array[NetMessages.EntityEvent] = _hits_on(3)
	if assert_eq(hits.size(), 1, "y sigue volando hasta el de detrás"):
		assert_eq(hits[0].amount, 60)


func test_the_shield_wall_box_stops_arrows_from_the_front_only() -> void:
	var wall: AbilityTicks = CombatCatalog.ability(CombatCatalog.ability_id(&"shield_wall"))
	var rules: CombatRules = CombatCatalog.rules()
	# Quien sostiene el muro (Solmarch) mira a -Z; su aliado está detrás (en +Z).
	var holder: Combatant = _body(10, SOLMARCH, Vector3.ZERO, 0.0)
	var ally: Combatant = _body(11, SOLMARCH, Vector3(0.0, 0.0, 3.0), 0.0)
	holder.get_character().combat.action = CombatState.Action.ABILITY
	holder.get_character().combat.action_id = wall.id
	holder.get_character().combat.action_tick = S - wall.cast_ticks - 30
	var stamina: int = holder.get_character().combat.stamina
	# 1) Desde lejos, de frente: la caja para la flecha dirigida al aliado de detrás.
	var far: Combatant = _body(1, VARDHEIM, Vector3(0.0, 0.0, -20.0), PI)
	_shoot(far, &"bow_quick", S, _center_of(ally))
	_run(S, S + 40)
	assert_eq(_hits_on(11).size(), 0, "el aliado de detrás no recibe la flecha")
	var blocked: Array[NetMessages.EntityEvent] = _hits_on(10)
	if assert_eq(blocked.size(), 1, "la bloquea quien sostiene el muro"):
		assert_true(blocked[0].has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_BLOCKED))
		assert_eq(blocked[0].amount, 0, "sin daño")
	assert_eq(holder.health, 1000)
	assert_eq(holder.get_character().combat.stamina, stamina - roundi(60.0 * rules.ability_block_stamina_per_damage),
			"gasta lo del muro: 0,6 por punto")
	assert_eq(holder.get_character().combat.action, CombatState.Action.ABILITY, "y sigue en el muro")
	assert_eq(_director.stats[&"wall_blocked"], 1, "registro: wall_blocked")
	if assert_eq(_spawns.size(), 1):
		# La cara delantera de la caja (0,7 m delante, 0,15 de medio grueso, más el radio de la flecha).
		var face: float = -wall.wall_forward_m - wall.wall_half_extents.z - 0.05
		var segment: Array[Vector3] = _last_segment(_spawns[0])
		assert_true(segment[0].z <= face + 0.001 and segment[1].z >= face - 0.001,
				"acaba en la cara de la caja, delante de quien lo sostiene: %s" % [segment])
	# 2) Con el arquero dentro de la caja (0,7 m delante, a un lado), disparando hacia el aliado: se para en
	# el origen.
	var inside: Combatant = _body(2, VARDHEIM, Vector3(0.8, 0.0, -0.7), PI)
	_spawns.clear()
	_shoot(inside, &"bow_quick", S + 100, _center_of(ally) + Vector3(0.8, 0.0, 0.0))
	_run(S + 100, S + 110)
	assert_eq(_hits_on(11).size(), 0, "tampoco desde dentro de la caja")
	assert_eq(_hits_on(10).size(), 2, "la bloquea quien sostiene el muro")
	if assert_eq(_spawns.size(), 1):
		assert_eq(_despawn_of(_spawns[0].net_id).get("tick", -1), S + 100, "en el primer segmento")
	# 3) Un arquero detrás de quien lo sostiene (a un lado de su cápsula) dispara libre a un aliado de
	# delante: el muro cubre de frente.
	var front_ally: Combatant = _body(12, SOLMARCH, Vector3(1.0, 0.0, -8.0), PI)
	var sneaky: Combatant = _body(3, VARDHEIM, Vector3(1.0, 0.0, 2.0), 0.0)
	_shoot(sneaky, &"bow_quick", S + 200, _center_of(front_ally))
	_run(S + 200, S + 220)
	assert_eq(_hits_on(12).size(), 1, "la flecha de detrás atraviesa la caja y da al de delante")
	assert_eq(_hits_on(10).size(), 2, "sin otro bloqueo del muro")
	# Control: sin el muro (y quien lo sostenía fuera de la línea), la flecha de lejos llega al aliado.
	holder.get_character().combat.action = CombatState.Action.NONE
	holder.entity.node.global_position = Vector3(6.0, 0.0, 0.0)
	_shoot(far, &"bow_quick", S + 300, _center_of(ally))
	_run(S + 300, S + 340)
	assert_eq(_hits_on(11).size(), 1, "control: sin el muro el aliado recibe la flecha")


func test_a_segment_that_starts_inside_a_capsule_hits_point_blank() -> void:
	# El enemigo se ha metido encima del arquero (los personajes no chocan): su cápsula contiene el pecho.
	var archer: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var hugger: Combatant = _body(2, SOLMARCH, Vector3(0.2, 0.0, 0.2), PI)
	# Aunque apunte hacia otro lado (hacia -Z, lejos).
	_shoot(archer, &"bow_quick", S, Vector3(0.0, 1.4, -30.0))
	_run(S, S + 5)
	var hits: Array[NetMessages.EntityEvent] = _hits_on(2)
	if assert_eq(hits.size(), 1, "a quemarropa"):
		assert_eq(hits[0].tick, S, "en el tick del disparo")
		assert_eq(hits[0].amount, 60)
	if assert_eq(_spawns.size(), 1):
		assert_eq(_despawn_of(_spawns[0].net_id).get("tick", -1), S, "DESPAWN 4 en el primer segmento")


# --- Topes y bajas ----------------------------------------------------------------------------

func test_with_eight_per_shooter_or_sixty_four_per_zone_the_oldest_leaves() -> void:
	var rules: CombatRules = CombatCatalog.rules()
	assert_eq([rules.max_projectiles_per_shooter, rules.max_projectiles_per_zone], [8, 64])
	var sky := Vector3(0.0, 300.0, -100.0)
	# Tope del tirador: 9 disparos seguidos al cielo; el noveno retira el primero en ese mismo tick.
	var archer: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	for shot: int in 9:
		_shoot(archer, &"bow_quick", S + shot, sky)
		_tick(S + shot)
	assert_eq(_spawns.size(), 9, "nueve disparos, ninguno rechazado")
	assert_eq(_director.projectiles.live_count(), 8, "ocho vivos")
	assert_eq(_despawns, [{"id": _spawns[0].net_id, "tick": S + 8, "reason": EXPIRED}],
			"sale la más vieja con DESPAWN 5 en el tick del noveno")
	assert_not_null(_director.projectiles.get_projectile(_spawns[8].net_id), "el disparo nuevo existe")
	# Tope de la zona: siete tiradores más con ocho cada uno (64 vivos) y otro que dispara: sale la más vieja de
	# la zona (la segunda del primer tirador, del tick S + 1).
	var shooters: Array[Combatant] = []
	for index: int in 8:
		shooters.append(_body(20 + index, VARDHEIM, Vector3(float(index) * 3.0 + 5.0, 0.0, 0.0), 0.0))
	for round_index: int in 8:
		var s: int = S + 20 + round_index
		for index: int in 7:
			_shoot(shooters[index], &"bow_quick", s, sky)
		_tick(s)
	assert_eq(_director.projectiles.live_count(), 64, "64 en la zona")
	var oldest: int = _spawns[1].net_id
	assert_not_null(_director.projectiles.get_projectile(oldest))
	_despawns.clear()
	_shoot(shooters[7], &"bow_quick", S + 40, sky)
	_tick(S + 40)
	assert_eq(_director.projectiles.live_count(), 64, "sigue en el tope")
	assert_eq(_despawns, [{"id": oldest, "tick": S + 40, "reason": EXPIRED}],
			"sale la más vieja de la zona con DESPAWN 5")
	assert_not_null(_director.projectiles.get_projectile(_spawns[_spawns.size() - 1].net_id),
			"y el disparo nuevo existe")
	assert_eq(_director.projectiles.stats[&"projectiles_evicted"], 2)
	assert_eq(_director.projectiles.registry.transient_count(), 64, "un id por proyectil vivo")


func test_a_shooter_who_leaves_takes_his_arrows_with_despawn_5() -> void:
	var archer: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var other: Combatant = _body(2, VARDHEIM, Vector3(10.0, 0.0, 0.0), 0.0)
	for shot: int in 3:
		_shoot(archer, &"bow_quick", S + shot, Vector3(0.0, 200.0, -100.0))
		_tick(S + shot)
	_shoot(other, &"bow_quick", S + 3, Vector3(10.0, 200.0, -100.0))
	_tick(S + 3)
	assert_eq(_director.projectiles.live_count(), 4)
	_director.remove(1, S + 4)
	assert_eq(_director.projectiles.live_count(), 1, "solo queda la del otro")
	assert_eq(_despawns.size(), 3, "sus tres flechas salen")
	for index: int in 3:
		assert_eq(_despawns[index], {"id": _spawns[index].net_id, "tick": S + 4, "reason": EXPIRED},
				"con DESPAWN 5 en el tick de la baja")
	assert_false(_director.projectiles.registry.is_transient(_spawns[0].net_id), "su id vuelve a la cuarentena")
	assert_true(_director.projectiles.registry.is_quarantined(_spawns[0].net_id, S + 4))


func test_the_sweep_never_drops_a_capsule_that_the_full_scan_would_touch() -> void:
	# 40 enemigos repartidos en 60 x 60 m con 32 ticks de historia al azar (uno se teletransportó: su caja
	# barrida es ancha y va aparte), y 3000 segmentos al azar con 10 ticks de rebobinado: la criba (cajas
	# barridas y barrido en x) toca exactamente a los mismos que probar la cápsula de todos.
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var homes: Array[Vector3] = []
	for index: int in 40:
		var net_id: int = 10 + index
		var home := Vector3(rng.randf_range(-30.0, 30.0), 0.0, rng.randf_range(-30.0, 30.0))
		homes.append(home)
		var fighter: Combatant = _body(net_id, SOLMARCH, home, 0.0)
		for tick: int in range(S - 32, S):
			var position: Vector3 = home + Vector3(rng.randf_range(-3.0, 3.0), rng.randf_range(0.0, 1.0),
					rng.randf_range(-3.0, 3.0))
			if index == 0 and tick < S - 20:
				position += Vector3(40.0, 0.0, 0.0)
			_history.record(tick, net_id, position, 0.0, EntityRecord.FLAG_GROUNDED)
		fighter.freeze(S)
	var system: ProjectileSystem = _director.projectiles
	system.begin_tick(S, _director.get_sorted())
	var projectile := ProjectileSystem.Projectile.new()
	projectile.realm = VARDHEIM
	projectile.owner_id = 1
	projectile.rewind = 10
	projectile.definition = CombatCatalog.projectile(CombatCatalog.projectile_id(&"arrow"))
	var touched: int = 0
	var mismatches: int = 0
	for trial: int in 3000:
		# Dos de cada tres cerca de alguien (de donde estaba hace 10 ticks); el resto, en cualquier sitio.
		var from := Vector3(rng.randf_range(-35.0, 75.0), rng.randf_range(-0.5, 3.0), rng.randf_range(-35.0, 35.0))
		if trial % 3 != 0:
			var seen: Vector3 = _history.position_at(10 + rng.randi_range(0, homes.size() - 1), S - 10)
			from = seen + Vector3(rng.randf_range(-1.2, 1.2), rng.randf_range(-0.5, 2.5), rng.randf_range(-1.2, 1.2))
		var to: Vector3 = from + Vector3(rng.randf_range(-1.2, 1.2), rng.randf_range(-0.3, 0.3),
				rng.randf_range(-1.2, 1.2))
		var swept: PackedInt32Array = system.touched_ids(projectile, from, to, S)
		var full: PackedInt32Array = system.touched_ids(projectile, from, to, S, true)
		if swept != full:
			mismatches += 1
		touched += full.size()
	assert_eq(mismatches, 0, "la criba no cambia nada")
	assert_true(touched > 200, "y la prueba toca a alguien de verdad (%d)" % touched)


# --- Puerta -----------------------------------------------------------------------------------

func test_an_arrow_hits_the_gate_with_its_piercing_share() -> void:
	FortressFixture.add_fortress(_world, FortressFixture.make_definition())
	var registry := NetEntityRegistry.new()
	var controller := FortressController.new()
	controller.setup(_world, registry, 0)
	_director.set_structure_targets(controller.get_structure_targets())
	_director.structure_hit.connect(controller.on_structure_hit)
	await wait_physics_frames(3)
	var state: FortressState = controller.get_fortress_state(FortressFixture.FORTRESS_ID)
	var gate_id: int = controller.get_net_id(FortressFixture.FORTRESS_ID)
	var target: StructureTarget = controller.get_structure_targets()[0]
	# Un arquero de Vardheim a 8 m de la cara oeste de la puerta (neutral y cerrada), mirando al este.
	var archer: Combatant = _body(11, VARDHEIM, target.box.origin + Vector3(-8.0, -target.box.origin.y, 0.0),
			-PI * 0.5)
	_shoot(archer, &"bow_quick", S, target.box.origin + Vector3(-1.0, 0.0, 0.0))
	_run(S, S + 20)
	var expected: int = roundi(60.0 * CombatCatalog.rules().structure_multiplier(DamageFormula.DamageType.PIERCE))
	assert_eq(expected, 12, "60 perforante × 0,2")
	var gate_hits: Array[NetMessages.EntityEvent] = _hits_on(gate_id)
	if assert_eq(gate_hits.size(), 1, "un HIT a la puerta"):
		assert_eq(gate_hits[0].amount, expected)
		assert_eq(gate_hits[0].attacker, 11)
		assert_eq(gate_hits[0].damage_type, DamageFormula.DamageType.PIERCE)
	assert_eq(state.gate_health, 900 - expected, "la puerta pierde su vida")
	assert_eq(_despawn_of(_spawns[0].net_id).get("reason", -1), IMPACT, "y la flecha se clava")
	# De su dueño, la flecha se clava sin hacerle nada.
	controller.set_owner(FortressFixture.FORTRESS_ID, VARDHEIM, S + 50)
	_shoot(archer, &"bow_quick", S + 100, target.box.origin + Vector3(-1.0, 0.0, 0.0))
	_run(S + 100, S + 120)
	assert_eq(_hits_on(gate_id).size(), 1, "el dueño no daña su puerta")
	assert_eq(_despawn_of(_spawns[1].net_id).get("reason", -1), IMPACT, "su flecha se clava en ella")


# --- Rebobinado e inofensivas -----------------------------------------------------------------

func test_the_arrow_flies_against_rewound_positions() -> void:
	# Dos parejas iguales a 50 m: el blanco corre en lateral a 6 m/s (0,1 m por tick) a 15 m del arquero. El
	# arquero A (con peer) ve 10 ticks atrás; el B no rebobina. Los dos apuntan donde A ve al blanco cuando
	# llega la flecha (~20 ticks): x(S + 20 − 10) = 1 m.
	var peer := ServerPeer.new(7)
	peer.rtt_ticks = 4
	peer.interp_delay_q = 48
	var archer_a: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	var runner_a: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -15.0), PI)
	var archer_b: Combatant = _body(3, VARDHEIM, Vector3(50.0, 0.0, 0.0), 0.0)
	var runner_b: Combatant = _body(4, SOLMARCH, Vector3(50.0, 0.0, -15.0), PI)
	var place: Callable = func(tick: int) -> void:
		var x: float = 0.1 * float(tick - S)
		runner_a.entity.node.global_position = Vector3(x, 0.0, -15.0)
		runner_b.entity.node.global_position = Vector3(50.0 + x, 0.0, -15.0)
	for tick: int in range(S - 30, S):
		place.call(tick)
		for fighter: Combatant in _director.get_sorted():
			CombatFixture.record(_history, fighter, tick)
	place.call(S)
	_shoot(archer_a, &"bow_quick", S, Vector3(1.0, 0.9, -15.0), 0, 10)
	_shoot(archer_b, &"bow_quick", S, Vector3(51.0, 0.9, -15.0))
	for tick: int in range(S, S + 40):
		place.call(tick)
		_tick(tick)
		for fighter: Combatant in _director.get_sorted():
			CombatFixture.record(_history, fighter, tick)
	assert_eq(_spawns.size(), 2)
	var hits: Array[NetMessages.EntityEvent] = _hits_on(2)
	if assert_eq(hits.size(), 1, "con el rebobinado de 10 ticks la flecha da donde el arquero veía al blanco"):
		assert_true(hits[0].tick >= S + 18 and hits[0].tick <= S + 21, "al llegar (%d)" % (hits[0].tick - S))
	assert_eq(_hits_on(4).size(), 0, "control sin rebobinar: contra la posición presente falla")
	assert_eq(peer.suspicion_score, 0, "un rebobinado dentro del tope no es sospechoso")


func test_a_rejected_rewind_or_the_safe_area_make_a_harmless_arrow() -> void:
	var peer := ServerPeer.new(7)
	peer.rtt_ticks = 4
	peer.interp_delay_q = 48
	var cheat: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	var target: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -8.0), PI)
	# 40 ticks de vista atrás, por encima del tope (12): flecha inofensiva.
	_shoot(cheat, &"bow_quick", S, _center_of(target), 0, 40)
	_run(S, S + 60)
	if assert_eq(_spawns.size(), 1):
		assert_true(_spawns[0].is_harmless(), "SPAWN con el bit de inofensiva")
		assert_eq(_despawn_of(_spawns[0].net_id).get("reason", -1), IMPACT, "vuela y choca con el suelo")
	assert_eq(_hits_on(2).size(), 0, "no prueba a nadie")
	assert_eq(peer.suspicion_score, 1, "sospecha + 1")
	assert_eq(peer.rewind_rejects, 1)
	assert_eq(_director.stats[&"rewind_rejected"], 1, "y una línea del registro")
	# Desde la zona segura de su reino, tampoco.
	_safe_areas.add(Vector3(30.0, 0.0, 0.0), 5.0, VARDHEIM)
	var camper: Combatant = _body(3, VARDHEIM, Vector3(30.0, 0.0, 0.0), 0.0)
	var outside: Combatant = _body(4, SOLMARCH, Vector3(30.0, 0.0, -8.0), PI)
	_shoot(camper, &"bow_quick", S + 100, _center_of(outside))
	_run(S + 100, S + 120)
	if assert_eq(_spawns.size(), 2):
		assert_true(_spawns[1].is_harmless(), "desde la zona segura, inofensiva")
	assert_eq(_hits_on(4).size(), 0)
	assert_eq(_director.projectiles.stats[&"projectiles_harmless"], 2)


# --- Abanico, carga, efectos ------------------------------------------------------------------

func test_the_volley_the_drawn_shot_and_the_slowing_shot() -> void:
	# Abanico: tres flechas a -7°, 0° y +7°, 55 de daño cada una; un acierto por disparo.
	var peer := ServerPeer.new(9)
	var archer: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	var target: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -10.0), PI)
	_cast(archer, &"bow_volley", S, _center_of(target))
	_run(S, S + 30)
	if assert_eq(_spawns.size(), 3, "tres flechas"):
		var middle: Vector3 = _spawns[1].velocity
		for index: int in 3:
			assert_eq(_spawns[index].volley_index, index)
			assert_eq(_spawns[index].source, CombatSource.make(CombatSource.Kind.ABILITY,
					CombatCatalog.ability_id(&"bow_volley")), "con la fuente de la habilidad")
			assert_near(_spawns[index].velocity.length(), 45.0, 0.02, "45 m/s")
		var left := Vector2(_spawns[0].velocity.x, _spawns[0].velocity.z)
		var right := Vector2(_spawns[2].velocity.x, _spawns[2].velocity.z)
		var center := Vector2(middle.x, middle.z)
		assert_near(rad_to_deg(absf(center.angle_to(left))), 7.0, 0.05, "a 7° a un lado")
		assert_near(rad_to_deg(absf(center.angle_to(right))), 7.0, 0.05, "y al otro")
	var volley_hits: Array[NetMessages.EntityEvent] = _hits_on(2)
	if assert_eq(volley_hits.size(), 1, "a 10 m solo la del centro da en la cápsula"):
		assert_eq(volley_hits[0].amount, 55)
	assert_eq(peer.swings_landed, 1, "un acierto por disparo")
	# Tensado: carga mínima (21 ticks) 40 m/s y 90; máxima (60) 70 m/s y 180.
	_spawns.clear()
	_shoot(archer, &"bow_drawn", S + 100, _center_of(target), 21)
	_run(S + 100, S + 130)
	_shoot(archer, &"bow_drawn", S + 200, _center_of(target), 60)
	_run(S + 200, S + 230)
	if assert_eq(_spawns.size(), 2):
		assert_near(_spawns[0].velocity.length(), 40.0, 0.02, "carga mínima: 40 m/s")
		assert_near(_spawns[1].velocity.length(), 70.0, 0.02, "carga máxima: 70 m/s")
	var drawn: Array[NetMessages.EntityEvent] = _hits_on(2)
	if assert_eq(drawn.size(), 3):
		assert_eq([drawn[1].amount, drawn[2].amount], [90, 180], "90 → 180")
	# Flecha lastrante: 60 y `slowed` al golpear (ranura de movimiento del blanco); interrumpe a quien bebe.
	var potion: AbilityTicks = CombatCatalog.ability(CombatCatalog.ability_id(&"potion_health"))
	var combat: CombatState = target.get_character().combat
	combat.consumable_charges = CombatState.pack_charges(3, 2)
	combat.action = CombatState.Action.ABILITY
	combat.action_id = potion.id
	combat.action_tick = S + 300
	_cast(archer, &"bow_slowing_shot", S + 300, _center_of(target))
	_run(S + 300, S + 330)
	var slowing: Array[NetMessages.EntityEvent] = _hits_on(2)
	if assert_eq(slowing.size(), 4):
		assert_eq(slowing[3].amount, 60)
		assert_true(slowing[3].has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_INTERRUPTED), "interrumpe beber")
	assert_eq(combat.action, CombatState.Action.NONE, "deja de beber")
	assert_eq(combat.charges_of(0), 3, "sin gastar la carga")
	var slowed_id: int = CombatCatalog.status_id(&"slowed")
	assert_not_null(_director.status.find(target, slowed_id), "ralentizado")
	assert_true(combat.move_effect_ids.has(slowed_id), "con su ranura de movimiento")
	# Salto atrás con disparo: una flecha a 50 m/s en su compromiso, con la fuente de la habilidad.
	_spawns.clear()
	var evasive: AbilityTicks = _cast(archer, &"bow_evasive_shot", S + 400, _center_of(target))
	_run(S + 400, S + 430)
	if assert_eq(_spawns.size(), 1, "el salto atrás dispara"):
		assert_eq(_spawns[0].spawn_tick, S + 400, "en su compromiso")
		assert_eq(_spawns[0].source, CombatSource.make(CombatSource.Kind.ABILITY, evasive.id))
		assert_near(_spawns[0].velocity.length(), 50.0, 0.02, "50 m/s")
	assert_eq(_hits_on(2).size(), 5, "y da")


func test_the_flight_is_the_ballistics_of_the_spawn_and_ends_when_it_expires() -> void:
	var archer: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var arrow: ProjectileTicks = CombatCatalog.projectile(CombatCatalog.projectile_id(&"arrow"))
	assert_eq(arrow.lifetime_ticks, 120, "2 s")
	# Hacia el cielo: nada que tocar en 2 s.
	_shoot(archer, &"bow_quick", S, Vector3(3.0, 400.0, -100.0))
	_tick(S)
	if not assert_eq(_spawns.size(), 1):
		return
	var spawn: NetMessages.EntitySpawn = _spawns[0]
	var projectile: ProjectileSystem.Projectile = _director.projectiles.get_projectile(spawn.net_id)
	assert_eq(spawn.kind, NetProtocol.EntityKind.PROJECTILE)
	assert_eq(spawn.spawn_tick, S)
	assert_eq(spawn.realm, VARDHEIM)
	assert_eq(spawn.owner_id, 1)
	assert_false(spawn.is_yours, "nunca is_yours")
	assert_eq(spawn.projectile_def_id, arrow.id)
	# Lo que vuela el servidor es lo cuantizado del SPAWN, y lo mismo tras codificarlo.
	var decoded: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(spawn.encode())
	assert_eq(decoded.origin, projectile.origin, "origen como viaja")
	assert_eq(decoded.velocity, projectile.velocity, "velocidad como viaja")
	var quantized: Array = Ballistics.quantize(projectile.origin, projectile.velocity)
	assert_eq(quantized, [projectile.origin, projectile.velocity], "ya cuantizado")
	assert_vec_near(projectile.origin, AimRay.muzzle(Vector3.ZERO), 0.01, "sale del pecho")
	assert_eq(projectile.position_after(37.0), Ballistics.position(decoded.origin, decoded.velocity,
			arrow.gravity, 37.0), "la misma Ballistics.position que el cliente")
	_run(S + 1, S + 125)
	assert_eq(_despawns, [{"id": spawn.net_id, "tick": S + arrow.lifetime_ticks - 1, "reason": EXPIRED}],
			"caduca en n + 1 = lifetime_ticks, con DESPAWN 5")
	assert_eq(_director.projectiles.live_count(), 0)
	assert_eq(_director.projectiles.registry.transient_count(), 0)


func test_the_server_arrow_is_the_shared_launch_the_client_predicts() -> void:
	# La flecha predicha del cliente (ProjectileWorld) y la del servidor salen de ProjectileLaunch: con la
	# misma entrada, el mismo estado y el mismo blanco para la convergencia, el SPAWN trae exactamente lo
	# que predice el cliente (fuente, índice del abanico, origen y velocidad cuantizados), también con el
	# hombro izquierdo, la carga del tensado y el abanico (fusión de H3b y H4).
	var archer: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var target: Combatant = _body(2, SOLMARCH, Vector3(1.5, 0.0, -20.0), PI)
	var cases: Array[Dictionary] = [
		{"attack": &"bow_quick", "charge": 0, "left": false},
		{"attack": &"bow_drawn", "charge": 40, "left": true},
		{"ability": &"bow_volley"},
	]
	var tick: int = S
	for case: Dictionary in cases:
		_spawns.clear()
		var aim: Vector3 = _center_of(target) + Vector3(0.0, 0.4, 0.0)
		if case.has("ability"):
			_cast(archer, case["ability"], tick, aim)
		else:
			_shoot(archer, case["attack"], tick, aim, case["charge"], 0, case["left"])
		# Lo que hace el cliente en su paso del compromiso (sin rebobinado: el blanco donde está).
		var launch: ProjectileLaunch = ProjectileLaunch.from_state(archer.get_character().combat, tick)
		var input: PlayerInput = archer.queue.get_applied(tick)
		if not assert_not_null(launch, "el compromiso dispara") or not assert_not_null(input):
			return
		var predicted: Array[PackedVector3Array] = launch.launch(archer.entity.get_position(),
				input.look_yaw, input.look_pitch, input.has(PlayerInput.AIM_LEFT), _space(),
				PackedVector3Array([target.entity.get_position()]))
		_tick(tick)
		var label: String = str(case)
		if assert_eq(_spawns.size(), predicted.size(), "%s: tantas flechas como las predichas" % label):
			for index: int in predicted.size():
				var spawn: NetMessages.EntitySpawn = _spawns[index]
				assert_eq(spawn.source, launch.source, "%s: la misma fuente" % label)
				assert_eq(spawn.volley_index, index, "%s: el mismo índice" % label)
				assert_eq(spawn.origin, predicted[index][0], "%s: el mismo origen" % label)
				assert_eq(spawn.velocity, predicted[index][1], "%s: la misma velocidad" % label)
		_run(tick + 1, tick + 60)
		tick += 100


# --- Servidor ---------------------------------------------------------------------------------

## Un [ZoneServer] sin red en una zona plana, que se avanza a mano.
func _start_server() -> void:
	_server_viewport = NetHarness.make_world_viewport(tree.root, "")
	_server = ZoneServer.new()
	_server.name = "ZoneServer"
	_server.log_enabled = false
	_server_viewport.add_child(_server)
	await wait_physics_frames(3)
	var config := ServerConfig.new()
	config.zone_id = String(ZONE_ID)
	config.no_dummies = true
	assert_eq(_server.start(config, NetHarness.get_world(_server_viewport), null, DevAuthProvider.new()), OK,
			"el servidor arranca")
	_server.set_physics_process(false)


## Un jugador falso de [param realm] en [param position] con el arco, cuyas entradas salen de
## [param script] ([code](tick) -> PlayerInput[/code]).
func _fake_archer(realm: int, position: Vector3, yaw: float, script: Callable) -> int:
	var brain := CombatFixture.ScriptBrain.new(1)
	brain.script_fn = func(tick: int, _position: Vector3, _yaw: float) -> PlayerInput:
		return script.call(tick)
	var net_id: int = _server.add_fake_player(brain, realm)
	_server.teleport(net_id, position)
	var character: PlayerCharacter = _server.get_registry().get_entity(net_id).get_character()
	character.yaw = yaw
	character.combat.weapon_id = CombatCatalog.weapon_id(&"bow")
	CombatDirector.commit_state(character)
	return net_id


func _step(count: int) -> void:
	await tree.physics_frame
	for _i: int in count:
		_server._physics_process(TICK_DELTA)


func test_a_fake_archer_on_the_server_shoots_and_hits() -> void:
	await _start_server()
	var server_events: Array[NetMessages.EntityEvent] = []
	_server.get_combat().event_emitted.connect(func(event: NetMessages.EntityEvent,
			_involved: PackedInt32Array) -> void: server_events.append(event))
	_watch(_server.get_combat().projectiles)
	var target_id: int = _fake_archer(SOLMARCH, Vector3(0.0, 0.05, -12.0), PI, func(tick: int) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = PI
		return input)
	var press: int = _server.get_tick() + 10
	# Un toque de PRIMARY con la cámara hacia el centro del blanco: disparo rápido.
	var look: Vector2 = AimRay.look_for(Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.9, -12.0), false)
	var archer_id: int = _fake_archer(VARDHEIM, Vector3(0.0, 0.05, 0.0), 0.0, func(tick: int) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = look.x
		input.look_pitch = look.y
		if tick >= press and tick < press + 2:
			input.buttons = PlayerInput.PRIMARY
		return input)
	var spawned_alive: Array[bool] = []
	_server.get_combat().projectiles.spawned.connect(func(spawn: NetMessages.EntitySpawn,
			_recipients: PackedInt32Array) -> void:
		spawned_alive.append(_server.get_registry().is_transient(spawn.net_id)
				and _server.get_registry().get_entity(spawn.net_id) == null))
	await _step(70)
	if not assert_eq(_spawns.size(), 1, "un disparo"):
		return
	assert_eq(spawned_alive, [true], "con un id pasajero del registro de la zona, sin entidad")
	assert_eq(_spawns[0].owner_id, archer_id)
	assert_eq(_spawns[0].source, CombatCatalog.attack_id(&"bow_quick"))
	var hits: Array[NetMessages.EntityEvent] = _hits_on(target_id, server_events)
	if assert_eq(hits.size(), 1, "da al blanco"):
		assert_eq(hits[0].amount, 60)
		assert_eq(hits[0].attacker, archer_id)
	assert_eq(_despawn_of(_spawns[0].net_id).get("reason", -1), IMPACT)
	assert_false(_server.get_registry().is_transient(_spawns[0].net_id), "su id vuelve a la cuarentena")
	var report: Dictionary = _server._combat_report()
	assert_eq(int(report.get("projectiles_fired", -1)), 1, "el informe cuenta los disparos")
	assert_eq(int(report.get("arrow_hits", -1)), 1, "y los aciertos")
	# Con flechas en el aire, el falso que se va se las lleva (DESPAWN 5).
	_despawns.clear()
	var sky_press: int = _server.get_tick() + 5
	var sky_archer: int = _fake_archer(VARDHEIM, Vector3(20.0, 0.05, 0.0), 0.0, func(tick: int) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_pitch = 1.2
		if tick >= sky_press and tick < sky_press + 2:
			input.buttons = PlayerInput.PRIMARY
		return input)
	await _step(30)
	assert_eq(_server.get_combat().projectiles.live_count(), 1, "una flecha al cielo")
	assert_true(_server.remove_fake_player(sky_archer))
	await _step(1)
	assert_eq(_despawns.size(), 1, "sale con su tirador")
	if not _despawns.is_empty():
		assert_eq(_despawns[0]["reason"], EXPIRED)
	assert_eq(_server.get_combat().projectiles.live_count(), 0)


# --- Red --------------------------------------------------------------------------------------

func test_the_client_that_sees_the_shooter_receives_the_spawn_and_the_despawn() -> void:
	var port: int = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(tree.root, "")
	var config := ServerConfig.new()
	config.port = port
	config.zone_id = String(ZONE_ID)
	config.max_players = 4
	config.no_dummies = true
	_server = NetHarness.start_server(_server_viewport, config)
	if not assert_not_null(_server, "el servidor escucha"):
		return
	_server_has_transport = true
	await wait_physics_frames(3)
	_client_viewport = NetHarness.make_world_viewport(tree.root, "")
	_client = NetHarness.start_bot(_client_viewport, port, SOLMARCH, 3)
	var spawned: Array[NetMessages.EntitySpawn] = []
	var despawned: Array[Dictionary] = []
	_client.projectile_spawned.connect(func(spawn: NetMessages.EntitySpawn) -> void: spawned.append(spawn))
	_client.projectile_despawned.connect(func(projectile_id: int, tick: int, reason: int) -> void:
		despawned.append({"id": projectile_id, "tick": tick, "reason": reason}))
	var joined: bool = false
	for _i: int in WAIT_FRAMES:
		await tree.physics_frame
		if _client.get_net_id() > 0:
			joined = true
			break
	if not assert_true(joined, "el bot entra en el mundo"):
		return
	# Un arquero falso de otro reino dispara al cielo: el bot lo tiene relevante (la política base lo ve todo).
	var press: Array[int] = [0]
	var brain := CombatFixture.ScriptBrain.new(2)
	brain.script_fn = func(tick: int, _position: Vector3, _yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_pitch = 1.0
		if press[0] > 0 and tick >= press[0] and tick < press[0] + 2:
			input.buttons = PlayerInput.PRIMARY
		return input
	var archer: int = _server.add_fake_player(brain, VARDHEIM)
	var character: PlayerCharacter = _server.get_registry().get_entity(archer).get_character()
	character.combat.weapon_id = CombatCatalog.weapon_id(&"bow")
	CombatDirector.commit_state(character)
	var server_spawns: Array[int] = []
	_server.get_combat().projectiles.spawned.connect(func(spawn: NetMessages.EntitySpawn,
			_recipients: PackedInt32Array) -> void: server_spawns.append(spawn.net_id))
	press[0] = _server.get_tick() + 30
	var done: bool = false
	for _i: int in WAIT_FRAMES:
		await tree.physics_frame
		if not despawned.is_empty():
			done = true
			break
	if not assert_true(done, "llegan el SPAWN y el DESPAWN de la flecha"):
		return
	if assert_eq(spawned.size(), 1, "un SPAWN") and assert_eq(server_spawns.size(), 1):
		assert_eq(spawned[0].net_id, server_spawns[0], "el de la flecha del servidor")
		assert_eq(spawned[0].owner_id, archer, "con su tirador")
		assert_eq(spawned[0].kind, NetProtocol.EntityKind.PROJECTILE)
		assert_eq(despawned[0]["id"], server_spawns[0], "y su DESPAWN")
	assert_eq(despawned[0]["reason"], EXPIRED, "caduca a los 2 s en el aire")
	assert_eq(int(_server._combat_report().get("projectile_messages_sent", -1)), 2, "dos mensajes: alta y baja")
