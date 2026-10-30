class_name ProjectileSystem
extends RefCounted
## Proyectiles del servidor (docs/habilidades.md, sección 4.4; CMB-22): las flechas del arco, con la
## balística de datos ([ProjectileTicks]), el rebobinado de los golpes fijado para todo el vuelo y la
## caja del muro de escudos.
## [br][br]
## [b]Disparo[/b] ([method fire], paso 3 del tick, por net_id): cada proyectil del ataque o la habilidad que
## compromete en [code]s[/code] sale del pecho ([method AimRay.muzzle]) hacia el punto apuntado
## ([method AimRay.aim_point]) por el rayo canónico de la cámara ([method AimRay.canonical] con el yaw, el
## pitch y el hombro de la entrada simulada en [code]s[/code], [method InputQueue.get_applied]), con la
## convergencia a la profundidad del hostil más cercano a la mira en [code]s − rewind[/code]. El abanico
## gira la dirección en yaw. El origen y la velocidad se cuantizan como viajan en el ENTITY_SPAWN
## ([method Ballistics.quantize]) y el servidor vuela con eso. Qué sale, su velocidad, el abanico y la
## cuantización son los de [ProjectileLaunch], compartido con la flecha predicha del cliente. El rebobinado
## ([method CombatResolver.compute_rewind]) se fija una vez por disparo, en ticks enteros; si se rechaza,
## la flecha es [b]inofensiva[/b] (vuela y choca con el mundo, no prueba a nadie), con sospecha + 1 y
## registro; también lo es la de quien dispara desde la zona segura de su reino. El proyectil guarda una
## copia del autor (reino, si es jugador, fuente, rebobinado, carga y más daño): el daño no vuelve a mirar
## el estado del tirador. [b]Un disparo nunca se rechaza[/b]: con [member CombatRules.max_projectiles_per_shooter]
## vivos del tirador sale la más vieja suya y con [member CombatRules.max_projectiles_per_zone] en la zona,
## la más vieja de la zona (empate por id), con DESPAWN 5 en ese tick.
## [br][br]
## [b]Vuelo[/b] ([method resolve], paso 4, sin tocar estado de combate): en el tick [code]k[/code], con
## [code]n = k − spawn_tick[/code], el segmento [code][pos(n), pos(n + 1)][/code] de
## [method Ballistics.position] (en el tick del disparo, el primero) contra el mundo y las puertas
## ([constant HitShapes.LINE_OF_SIGHT_MASK]; el primer segmento con [code]hit_from_inside[/code]: desde el
## vano de la puerta cerrada se clava en el origen), las cajas de los muros de escudos de los hostiles al
## tirador en [code]k[/code] (solo a las flechas que llegan de frente) y las cápsulas (radio 0,4 + el del
## proyectil) de los candidatos en [code]k − rewind[/code] ([method StateHistory.position_at]), cribados
## con su caja barrida ([method StateHistory.swept_box] más la posición congelada), calculada una vez por
## tick. Gana la fracción menor. Un personaje invulnerable en [code][k − defense_rewind, k][/code] no la
## para (no vuelve a probarlo); uno bloqueando de cara a la flecha (el cono del arma o el ancho del muro,
## en la muestra de [code]k[/code] o en la de [code]k − defense_rewind[/code] si aún cuenta) la bloquea;
## nunca hay parada. La caja del muro bloquea por quien lo sostiene (sin daño). El mundo la clava; una
## puerta que el tirador puede dañar recibe el golpe. Sin impacto, caduca en
## [code]n + 1 ≥ lifetime_ticks[/code] o por debajo de [constant VOID_LIMIT_Y] (DESPAWN 5).
## [br][br]
## No toca la red ni el reloj: avisa de las altas y bajas con [signal spawned] y [signal despawned] (el
## [ZoneServer] las manda a quien tiene relevante al tirador y a él) y devuelve los golpes para que los
## aplique el [CombatDirector], que es quien sabe de daño, controles y muertes.
## [br][br]
## [b]Coste[/b] (docs/habilidades.md, sección 8): los candidatos del tick viven en arrays empaquetados
## (sin objetos por tick) y cada flecha guarda el extremo de su segmento, que es el origen del siguiente
## (la misma [method Ballistics.position] con el mismo [code]n[/code]): un tick de vuelo es un rayo contra el
## mundo, una criba por cajas y, casi nunca, una prueba exacta.

## Alta de un proyectil: el ENTITY_SPAWN de kind 3 y los net_id implicados (el tirador): su dueño y quien
## lo tenga relevante lo reciben.
signal spawned(spawn: NetMessages.EntitySpawn, recipients: PackedInt32Array)
## Baja de un proyectil en el tick [param tick] con el motivo [param reason] (4 impacto, 5 caducado o
## retirado) y los net_id implicados (el tirador). El [ZoneServer] la manda a quien recibió su alta.
signal despawned(projectile_id: int, tick: int, reason: int, recipients: PackedInt32Array)

## Por debajo de esta altura el proyectil caduca (cae fuera del mundo).
const VOID_LIMIT_Y: float = -100.0

const _IMPACT: int = NetProtocol.DespawnReason.IMPACT
const _EXPIRED: int = NetProtocol.DespawnReason.EXPIRED
# Clases de lo que toca un segmento, en orden de preferencia con la misma fracción.
const _TOUCH_WORLD: int = 0
const _TOUCH_WALL: int = 1
const _TOUCH_CHARACTER: int = 2
# Barrido en x de los candidatos: el borde izquierdo de cada caja en centímetros (desplazado para que sea
# positivo) por encima de _SWEEP_INDEX_BITS bits con su índice, ordenado; las cajas más anchas que
# _SWEEP_WIDE_M (un teletransporte en los últimos ticks) van aparte y se prueban siempre.
const _SWEEP_INDEX_BITS: int = 12
const _SWEEP_INDEX_MASK: int = (1 << _SWEEP_INDEX_BITS) - 1
const _SWEEP_OFFSET_CM: int = 1 << 30
const _SWEEP_WIDE_M: float = 12.0

## Registro del que salen los ids de los proyectiles ([method NetEntityRegistry.allocate_transient_id]).
## El [ZoneServer] pone el de la zona; sin él (pruebas), uno propio.
var registry: NetEntityRegistry = NetEntityRegistry.new()
## Efectos de estado de la zona, para copiar el más daño del tirador al disparar (null = sin efectos).
var status: StatusSystem = null
## Contadores de la ejecución (para el informe).
var stats: Dictionary[StringName, int] = {
	&"projectiles_fired": 0, &"projectiles_harmless": 0, &"projectile_world_hits": 0,
	&"projectile_gate_hits": 0, &"projectile_wall_blocks": 0, &"projectile_character_hits": 0,
	&"projectile_invulnerable": 0, &"projectiles_expired": 0, &"projectiles_evicted": 0,
	&"projectiles_forgotten": 0, &"projectile_rewind_rejected": 0, &"projectile_segments": 0,
	&"projectile_capsule_tests": 0, &"projectile_peak": 0,
}

var _history: StateHistory
var _resolver: CombatResolver
# Proyectiles vivos, en orden de alta.
var _live: Array[Projectile] = []
# Golpes rechazados por rebobinado en los disparos de este tick (para el registro del director).
var _rejected: Array[CombatResolver.Hit] = []
# Rayo contra el mundo, reutilizado en cada segmento.
var _query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.new()
# Los combatientes del tick (begin_tick) y, calculados una vez por tick y solo si hacen falta, sus
# candidatos (vivos) en arrays paralelos: el combatiente, su id, su reino, si está abierto (ni protegido ni
# en la zona segura de su reino) y su caja barrida ensanchada con la cápsula; y los muros de escudos.
var _combatants: Array[Combatant] = []
var _prepared_tick: int = -1
var _candidate_count: int = 0
var _candidates: Array[Combatant] = []
var _candidate_ids: PackedInt32Array = PackedInt32Array()
var _candidate_realms: PackedInt32Array = PackedInt32Array()
var _candidate_open: PackedByteArray = PackedByteArray()
var _candidate_low: PackedVector3Array = PackedVector3Array()
var _candidate_high: PackedVector3Array = PackedVector3Array()
# Los candidatos estrechos ordenados por el borde izquierdo de su caja (ver _SWEEP_INDEX_BITS), la anchura
# en x de la más ancha de ellos y los anchos.
var _sweep: PackedInt64Array = PackedInt64Array()
var _sweep_width: float = 0.0
var _wide: PackedInt32Array = PackedInt32Array()
var _walls: Array[_Wall] = []


## Lo que comparten los proyectiles de un mismo disparo (un abanico): si alguno ya ha dado en algo, para
## contar un acierto por disparo.
class Shot:
	extends RefCounted
	var landed: bool = false


## Un proyectil vivo, con la copia del autor que guardó al salir.
class Projectile:
	extends RefCounted
	## Id de red (del espacio de [NetEntityRegistry], sin entidad).
	var id: int = 0
	## El tirador (para los contadores y el registro de daño) y su net_id, reino y si es jugador, copiados
	## al salir.
	var owner: Combatant = null
	var owner_id: int = 0
	var realm: int = 0
	var is_player: bool = false
	## Fuente del ataque o la habilidad ([CombatSource]) y el golpe con su daño, controles y efecto al
	## objetivo (el ataque o el golpe sintetizado de la habilidad).
	var source: int = 0
	var attack: AttackTicks = null
	var definition: ProjectileTicks = null
	var volley_index: int = 0
	## Inofensiva: vuela y choca con el mundo, no prueba a nadie.
	var harmless: bool = false
	## Ticks que ve atrás y los que se miran atrás para las defensas (fijados al salir).
	var rewind: int = 0
	var defense_rewind: int = 0
	## Carga con la que salió y el más daño del tirador en el disparo.
	var charge_ticks: int = 0
	var damage_scale: float = 1.0
	var spawn_tick: int = 0
	## Origen y velocidad cuantizados: los del ENTITY_SPAWN.
	var origin: Vector3 = Vector3.ZERO
	var velocity: Vector3 = Vector3.ZERO
	var shot: Shot = null
	## Personajes que no vuelve a probar (eran invulnerables cuando los tocó).
	var ignored: PackedInt32Array = PackedInt32Array()
	## Ticks de vuelo en los que acaba el último segmento probado y su posición: el origen del siguiente.
	var reached_ticks: int = 0
	var reached: Vector3 = Vector3.ZERO


	## Posición tras [param ticks] ticks de vuelo (entero o fraccionario).
	func position_after(ticks: float) -> Vector3:
		return Ballistics.position(origin, velocity, definition.gravity, ticks)


	## Velocidad (m/s) tras [param ticks] ticks de vuelo.
	func velocity_after(ticks: float) -> Vector3:
		return velocity - Vector3(0.0, definition.gravity * ticks / Ballistics.TICK_RATE, 0.0)


# La caja de un muro de escudos en este tick.
class _Wall:
	var holder: Combatant
	var realm: int = 0
	var box: Transform3D = Transform3D.IDENTITY
	var half_extents: Vector3 = Vector3.ZERO
	var forward: Vector3 = Vector3.FORWARD


# Lo que toca un segmento.
class _Touch:
	var fraction: float = 0.0
	var kind: int = 0
	## Índice del candidato tocado (en los arrays del tick).
	var candidate: int = -1
	var wall: _Wall = null
	var structure: StructureTarget = null


## [param history] es el historial del servidor y [param resolver] el resolutor de la zona (rebobinado,
## hostilidad, invulnerabilidad, zonas seguras y puertas).
func _init(history: StateHistory, resolver: CombatResolver) -> void:
	_history = history
	_resolver = resolver
	_query.collision_mask = HitShapes.LINE_OF_SIGHT_MASK


## Empieza un tick con los combatientes de la zona [param combatants] (por net_id): sus candidatos y muros
## se calculan la primera vez que hacen falta en el tick.
func begin_tick(_s: int, combatants: Array[Combatant]) -> void:
	_combatants = combatants
	_prepared_tick = -1


## Proyectiles vivos.
func live_count() -> int:
	return _live.size()


## true si algún disparo de este tick tiene un golpe que entregar en [method resolve] (el rechazo de su
## rebobinado, para el registro) aunque no quede ningún proyectil vivo.
func has_pending() -> bool:
	return not _rejected.is_empty()


## Los proyectiles vivos, en orden de alta (no hay que modificarlos).
func get_live() -> Array[Projectile]:
	return _live


## El proyectil vivo [param projectile_id], o null.
func get_projectile(projectile_id: int) -> Projectile:
	for projectile: Projectile in _live:
		if projectile.id == projectile_id:
			return projectile
	return null


# --- Disparo ----------------------------------------------------------------------------------

## Dispara los proyectiles del ataque o la habilidad de la fuente [param source] ([CombatSource]) que
## [param shooter] compromete en el tick [param s] (ya congelado), contra el mundo [param space]. No hace
## nada si la fuente no lleva proyectil.
func fire(shooter: Combatant, source: int, s: int, space: PhysicsDirectSpaceState3D) -> void:
	var frame: Combatant.Frozen = shooter.frozen
	# Qué sale, con qué velocidad y en qué abanico: lo mismo que la flecha predicha del cliente
	# (ProjectileLaunch, compartido).
	var attack: AttackTicks = null
	var launch: ProjectileLaunch = null
	var charge_ticks: int = 0
	match CombatSource.kind_of(source):
		CombatSource.Kind.ATTACK:
			attack = CombatCatalog.attack(CombatSource.id_of(source))
			if attack != null and attack.heavy:
				charge_ticks = frame.charge_ticks
			launch = ProjectileLaunch.for_attack(attack, charge_ticks)
		CombatSource.Kind.ABILITY:
			var ability: AbilityTicks = CombatCatalog.ability(CombatSource.id_of(source))
			if ability != null:
				attack = ability.hit
				launch = ProjectileLaunch.for_ability(ability)
	if attack == null or launch == null:
		return
	var definition: ProjectileTicks = CombatCatalog.projectile(launch.projectile_id)
	if definition == null:
		return
	var rules: CombatRules = CombatCatalog.rules()
	# Rebobinado, fijado para todo el vuelo en ticks enteros.
	var harmless: bool = false
	var rewind: int = 0
	var defense_rewind: int = 0
	var fixed: Vector2 = CombatResolver.compute_rewind(shooter, s)
	if is_nan(fixed.x):
		harmless = true
		_reject(shooter, attack, s)
	else:
		rewind = roundi(fixed.x)
		defense_rewind = maxi(roundi(fixed.y), rewind)
	if not shooter.ignores_safe_area \
			and _resolver.get_safe_areas().contains_own(shooter.get_realm(), frame.position):
		harmless = true
	# Puntería con la entrada simulada en s (sin ella, la del cuerpo: yaw del personaje, pitch 0).
	var input: PlayerInput = shooter.queue.get_applied(s) if shooter.queue != null else null
	var look_yaw: float = input.look_yaw if input != null else frame.yaw
	var look_pitch: float = input.look_pitch if input != null else 0.0
	var left: bool = input != null and input.has(PlayerInput.AIM_LEFT)
	var ray: Array = AimRay.canonical(frame.position, look_yaw, look_pitch, left)
	var camera: Vector3 = ray[0]
	var forward: Vector3 = ray[1]
	var feet := PackedVector3Array()
	if not harmless:
		_prepare(s)
		feet = _aim_candidates(shooter, camera, forward, s - rewind, s)
	var point: Vector3 = AimRay.aim_point(space, camera, forward, feet)
	var shots: Array[PackedVector3Array] = launch.launch_toward(AimRay.muzzle(frame.position), point,
			forward)
	var shot := Shot.new()
	var scale: float = status.damage_scale(shooter) if status != null else 1.0
	for index: int in shots.size():
		_make_room(shooter.get_id(), s, rules)
		var projectile_id: int = registry.allocate_transient_id(s)
		if projectile_id == 0:
			push_warning("[Eldmark] Sin ids libres para un proyectil")
			continue
		var projectile := Projectile.new()
		projectile.id = projectile_id
		projectile.owner = shooter
		projectile.owner_id = shooter.get_id()
		projectile.realm = shooter.get_realm()
		projectile.is_player = shooter.entity.kind == NetProtocol.EntityKind.PLAYER
		projectile.source = source
		projectile.attack = attack
		projectile.definition = definition
		projectile.volley_index = index
		projectile.harmless = harmless
		projectile.rewind = rewind
		projectile.defense_rewind = defense_rewind
		projectile.charge_ticks = charge_ticks
		projectile.damage_scale = scale
		projectile.spawn_tick = s
		projectile.origin = shots[index][0]
		projectile.velocity = shots[index][1]
		projectile.reached_ticks = 0
		projectile.reached = projectile.origin
		projectile.shot = shot
		_live.append(projectile)
		stats[&"projectiles_fired"] += 1
		if harmless:
			stats[&"projectiles_harmless"] += 1
		stats[&"projectile_peak"] = maxi(stats[&"projectile_peak"], _live.size())
		spawned.emit(NetMessages.EntitySpawn.for_projectile(projectile_id, s, projectile.realm,
				projectile.owner_id, definition.id, source, index, harmless, projectile.origin,
				projectile.velocity), PackedInt32Array([projectile.owner_id]))


# Un disparo con el rebobinado rechazado: sospecha + 1 y una línea del registro (el director la recibe en
# resolve como REWIND_REJECTED).
func _reject(shooter: Combatant, attack: AttackTicks, s: int) -> void:
	_resolver.note_rewind_rejected(shooter)
	stats[&"projectile_rewind_rejected"] += 1
	var hit := CombatResolver.Hit.new()
	hit.attacker = shooter
	hit.attack = attack
	hit.outcome = CombatResolver.Outcome.REWIND_REJECTED
	if shooter.queue != null:
		var params: Vector2i = shooter.queue.get_rewind_params(s)
		hit.rewind = float(params.x) / float(CombatResolver.VIEW_OFFSET_Q_SCALE)
		hit.view_tick = float(s) - hit.rewind
	_rejected.append(hit)


# Los pies, en el tick [param view_tick], de los hostiles de [param shooter] cuya caja barrida (como esfera)
# toca el cono de convergencia de la mira o su rayo: los que pueden decidir el punto apuntado, por net_id.
func _aim_candidates(shooter: Combatant, camera: Vector3, forward: Vector3, view_tick: int,
		s: int) -> PackedVector3Array:
	var rules: CombatRules = CombatCatalog.rules()
	var angle: float = deg_to_rad(rules.aim_converge_deg)
	var cone_cos: float = cos(angle)
	var cone_sin: float = sin(angle)
	var reach: float = rules.aim_range_m
	var realm: int = shooter.get_realm()
	var owner_id: int = shooter.get_id()
	var lows: PackedVector3Array = _candidate_low
	var highs: PackedVector3Array = _candidate_high
	var feet := PackedVector3Array()
	for index: int in _candidate_count:
		if _candidate_open[index] == 0 or _candidate_ids[index] == owner_id:
			continue
		var low: Vector3 = lows[index]
		var high: Vector3 = highs[index]
		var radius: float = (high - low).length() * 0.5
		var to_center: Vector3 = (low + high) * 0.5 - camera
		var depth: float = to_center.dot(forward)
		if depth <= -radius or depth - radius >= reach:
			continue
		# Distancia de la esfera al cono de la mira (por delante): perpendicular · cos − profundidad · sen.
		var perpendicular: float = sqrt(maxf(to_center.length_squared() - depth * depth, 0.0))
		if perpendicular > radius and perpendicular * cone_cos - depth * cone_sin > radius:
			continue
		if not _resolver.is_hostile(realm, _candidate_realms[index]):
			continue
		var position: Vector3 = _position_of(_candidates[index], view_tick, s)
		if position.is_finite():
			feet.append(position)
	return feet


# Con el tope del tirador o el de la zona lleno, retira el proyectil más viejo (del tirador o de la zona;
# empate por id) con DESPAWN 5: el disparo nuevo nunca se rechaza.
func _make_room(owner_id: int, s: int, rules: CombatRules) -> void:
	var own_count: int = 0
	var own_oldest: Projectile = null
	for projectile: Projectile in _live:
		if projectile.owner_id == owner_id:
			own_count += 1
			if own_oldest == null or _is_older(projectile, own_oldest):
				own_oldest = projectile
	if own_oldest != null and own_count >= rules.max_projectiles_per_shooter:
		_evict(own_oldest, s)
	if _live.size() >= rules.max_projectiles_per_zone and not _live.is_empty():
		var oldest: Projectile = _live[0]
		for projectile: Projectile in _live:
			if _is_older(projectile, oldest):
				oldest = projectile
		_evict(oldest, s)


static func _is_older(a: Projectile, b: Projectile) -> bool:
	return a.spawn_tick < b.spawn_tick or (a.spawn_tick == b.spawn_tick and a.id < b.id)


func _evict(projectile: Projectile, s: int) -> void:
	stats[&"projectiles_evicted"] += 1
	_live.erase(projectile)
	_end(projectile, s, _EXPIRED)


# --- Vuelo ------------------------------------------------------------------------------------

## El vuelo del tick [param s] de todos los proyectiles vivos (también los que acaban de salir) contra
## [param combatants] (por net_id, ya congelados en [param s]) y el mundo [param space]. Devuelve los
## golpes por net_id del tirador y por id de proyectil (antes, los disparos de este tick con el rebobinado
## rechazado) para que los aplique el [CombatDirector]; las bajas (DESPAWN 4 y 5) ya han salido por
## [signal despawned].
func resolve(s: int, combatants: Array[Combatant],
		space: PhysicsDirectSpaceState3D) -> Array[CombatResolver.Hit]:
	var rejected: Array[CombatResolver.Hit] = _rejected
	_rejected = []
	if _live.is_empty():
		return rejected
	_combatants = combatants
	_prepare(s)
	var flying: Array[Projectile] = _live.duplicate()
	flying.sort_custom(func(a: Projectile, b: Projectile) -> bool:
		return a.owner_id < b.owner_id or (a.owner_id == b.owner_id and a.id < b.id))
	var hits: Array[CombatResolver.Hit] = []
	var ended: Array[Projectile] = []
	var reasons: PackedInt32Array = PackedInt32Array()
	for projectile: Projectile in flying:
		var reason: int = _fly(projectile, s, space, hits)
		if reason >= 0:
			ended.append(projectile)
			reasons.append(reason)
	for index: int in ended.size():
		_live.erase(ended[index])
		_end(ended[index], s, reasons[index])
	return merge_by_attacker(rejected, hits)


## Mezcla dos listas de golpes ordenadas por net_id del atacante sin deshacer su orden: con el mismo
## atacante, primero los de [param first]. Es como el director junta los golpes cuerpo a cuerpo y los de
## los proyectiles (docs/habilidades.md, sección 4.1, paso 5).
static func merge_by_attacker(first: Array[CombatResolver.Hit],
		second: Array[CombatResolver.Hit]) -> Array[CombatResolver.Hit]:
	if first.is_empty():
		return second
	if second.is_empty():
		return first
	var merged: Array[CombatResolver.Hit] = []
	var i: int = 0
	var j: int = 0
	while i < first.size() or j < second.size():
		if j >= second.size() or (i < first.size()
				and first[i].attacker.get_id() <= second[j].attacker.get_id()):
			merged.append(first[i])
			i += 1
		else:
			merged.append(second[j])
			j += 1
	return merged


# Vuela un tick [param projectile]: prueba su segmento y deja en [param hits] lo que toca. Devuelve el
# motivo de su baja (4 impacto, 5 caducado) o -1 si sigue en el aire.
func _fly(projectile: Projectile, s: int, space: PhysicsDirectSpaceState3D,
		hits: Array[CombatResolver.Hit]) -> int:
	var flown: int = s - projectile.spawn_tick
	# El extremo del segmento anterior es el origen de este: la misma función con el mismo n.
	var from: Vector3 = projectile.reached if projectile.reached_ticks == flown \
			else projectile.position_after(float(flown))
	var to: Vector3 = projectile.position_after(float(flown + 1))
	projectile.reached_ticks = flown + 1
	projectile.reached = to
	stats[&"projectile_segments"] += 1
	var touches: Array[_Touch] = []
	var world: _Touch = _touch_world(space, from, to, flown == 0)
	if world != null:
		touches.append(world)
	if not projectile.harmless:
		if not _walls.is_empty():
			_touch_walls(projectile, from, to, touches)
		_touch_characters(projectile, from, to, s, touches)
	if touches.size() > 1:
		touches.sort_custom(func(a: _Touch, b: _Touch) -> bool:
			if a.fraction != b.fraction:
				return a.fraction < b.fraction
			if a.kind != b.kind:
				return a.kind < b.kind
			return a.candidate < b.candidate)
	for touch: _Touch in touches:
		if touch.kind == _TOUCH_WORLD:
			stats[&"projectile_world_hits"] += 1
			if touch.structure != null and not projectile.harmless \
					and touch.structure.can_be_hit_by(projectile.realm):
				stats[&"projectile_gate_hits"] += 1
				hits.append(_structure_hit(projectile, touch.structure, s))
			return _IMPACT
		if touch.kind == _TOUCH_WALL:
			stats[&"projectile_wall_blocks"] += 1
			var blocked: CombatResolver.Hit = _hit_on(projectile, touch.wall.holder, s, flown, touch)
			blocked.outcome = CombatResolver.Outcome.BLOCKED
			blocked.wide_block = true
			blocked.wall = true
			hits.append(blocked)
			return _IMPACT
		var victim: Combatant = _candidates[touch.candidate]
		var hit: CombatResolver.Hit = _hit_on(projectile, victim, s, flown, touch)
		if _resolver.was_invulnerable(victim, float(s - projectile.defense_rewind), s):
			# Sigue volando (lo siguiente del mismo segmento aún puede pararla) y no vuelve a probarlo.
			stats[&"projectile_invulnerable"] += 1
			projectile.ignored.append(victim.get_id())
			hit.outcome = CombatResolver.Outcome.INVULNERABLE
			hits.append(hit)
			continue
		stats[&"projectile_character_hits"] += 1
		hit.outcome = _defense(projectile, victim, hit, s)
		hits.append(hit)
		return _IMPACT
	if flown + 1 >= projectile.definition.lifetime_ticks or to.y < VOID_LIMIT_Y:
		stats[&"projectiles_expired"] += 1
		return _EXPIRED
	return -1


# El mundo y las puertas en el segmento [param from]-[param to]: el primer choque (con
# [param from_inside], también uno que empieza dentro de un cuerpo, en su origen), o null.
func _touch_world(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3,
		from_inside: bool) -> _Touch:
	if space == null:
		return null
	var length: float = from.distance_to(to)
	if length <= 0.0:
		return null
	_query.from = from
	_query.to = to
	_query.hit_from_inside = from_inside
	var result: Dictionary = space.intersect_ray(_query)
	if result.is_empty():
		return null
	var touch := _Touch.new()
	touch.kind = _TOUCH_WORLD
	touch.fraction = clampf(from.distance_to(result["position"] as Vector3) / length, 0.0, 1.0)
	var rid: RID = result.get("rid", RID())
	for target: StructureTarget in _resolver.structure_targets:
		if target.exclude.has(rid):
			touch.structure = target
			break
	return touch


# Las cajas de los muros de escudos de los hostiles al tirador que la flecha cruza de frente (contra el
# mirar de quien lo sostiene): las que llegan por detrás no las paran (el muro cubre de frente).
func _touch_walls(projectile: Projectile, from: Vector3, to: Vector3, touches: Array[_Touch]) -> void:
	var travel: Vector3 = to - from
	var radius: float = projectile.definition.radius_m
	for wall: _Wall in _walls:
		if wall.holder.get_id() == projectile.owner_id or travel.dot(wall.forward) >= 0.0 \
				or not _resolver.is_hostile(projectile.realm, wall.realm):
			continue
		var fraction: float = HitShapes.segment_box_fraction(from, to, wall.box,
				wall.half_extents + Vector3(radius, radius, radius))
		if fraction < 0.0:
			continue
		var touch := _Touch.new()
		touch.kind = _TOUCH_WALL
		touch.fraction = fraction
		touch.wall = wall
		touches.append(touch)


# Las cápsulas de los candidatos en [code]s − rewind[/code] que toca el segmento, cribadas con sus cajas
# barridas: solo se miran las cajas cuyo borde izquierdo cae en la ventana en x que puede solapar el
# segmento (búsqueda binaria en el barrido del tick) y las anchas.
func _touch_characters(projectile: Projectile, from: Vector3, to: Vector3, s: int,
		touches: Array[_Touch]) -> void:
	if _candidate_count == 0:
		return
	var radius: float = projectile.definition.radius_m
	var margin := Vector3(radius, radius, radius)
	var low: Vector3 = from.min(to) - margin
	var high: Vector3 = from.max(to) + margin
	var sweep: PackedInt64Array = _sweep
	var first: int = sweep.bsearch(_sweep_key(low.x - _sweep_width) << _SWEEP_INDEX_BITS, true)
	var last_key: int = _sweep_key(high.x) + 1
	for position: int in range(first, sweep.size()):
		var entry: int = sweep[position]
		if (entry >> _SWEEP_INDEX_BITS) > last_key:
			break
		_touch_candidate(projectile, entry & _SWEEP_INDEX_MASK, from, to, low, high, s, touches, true)
	for index: int in _wide:
		_touch_candidate(projectile, index, from, to, low, high, s, touches, true)


## Para las pruebas: los net_id de los candidatos del tick [param s] cuya cápsula toca el segmento
## [param from]-[param to] de [param projectile], con la criba del vuelo (cajas barridas y barrido en x) o,
## con [param full_scan], probando la cápsula de todos sin criba. Los dos deben coincidir siempre.
func touched_ids(projectile: Projectile, from: Vector3, to: Vector3, s: int,
		full_scan: bool = false) -> PackedInt32Array:
	_prepare(s)
	var touches: Array[_Touch] = []
	if full_scan:
		for index: int in _candidate_count:
			_touch_candidate(projectile, index, from, to, Vector3.ZERO, Vector3.ZERO, s, touches, false)
	else:
		_touch_characters(projectile, from, to, s, touches)
	var ids := PackedInt32Array()
	for touch: _Touch in touches:
		ids.append(_candidate_ids[touch.candidate])
	ids.sort()
	return ids


# Borde (m) en centímetros enteros del barrido, siempre positivo y redondeado hacia abajo.
static func _sweep_key(x: float) -> int:
	return floori(x * 100.0) + _SWEEP_OFFSET_CM


# El candidato [param index] contra el segmento [param from]-[param to] (de caja [param low]-[param high],
# ya ensanchada con el radio del proyectil; con [param check_box], primero contra su caja barrida).
func _touch_candidate(projectile: Projectile, index: int, from: Vector3, to: Vector3, low: Vector3,
		high: Vector3, s: int, touches: Array[_Touch], check_box: bool) -> void:
	if check_box:
		var box_low: Vector3 = _candidate_low[index]
		var box_high: Vector3 = _candidate_high[index]
		if low.x > box_high.x or high.x < box_low.x or low.z > box_high.z or high.z < box_low.z \
				or low.y > box_high.y or high.y < box_low.y:
			return
	var radius: float = projectile.definition.radius_m
	var view_tick: int = s - projectile.rewind
	var candidate_id: int = _candidate_ids[index]
	if _candidate_open[index] == 0 or candidate_id == projectile.owner_id \
			or projectile.ignored.has(candidate_id) \
			or not _resolver.is_hostile(projectile.realm, _candidate_realms[index]):
		return
	var combatant: Combatant = _candidates[index]
	var feet: Vector3 = _position_of(combatant, view_tick, s)
	if not feet.is_finite() or _was_dead(combatant, view_tick, s):
		return
	stats[&"projectile_capsule_tests"] += 1
	var fraction: float = HitShapes.segment_capsule_fraction(from, to, feet - Vector3(0.0, radius, 0.0),
			HitShapes.CAPSULE_RADIUS + radius, HitShapes.CAPSULE_HEIGHT + 2.0 * radius)
	if fraction < 0.0:
		return
	var touch := _Touch.new()
	touch.kind = _TOUCH_CHARACTER
	touch.fraction = fraction
	touch.candidate = index
	touches.append(touch)


# Pies de [param combatant] en el tick [param tick] (el congelado en [param s] o después; si no, el
# historial), o [constant Vector3.INF] si no se conocen.
func _position_of(combatant: Combatant, tick: int, s: int) -> Vector3:
	if tick >= s:
		return combatant.frozen.position
	return _history.position_at(combatant.get_id(), tick)


# true si [param combatant] tenía el bit «muerto» en el tick [param tick].
func _was_dead(combatant: Combatant, tick: int, s: int) -> bool:
	var flags: int = combatant.frozen.defense if tick >= s else _history.get_flags(combatant.get_id(), tick)
	return flags >= 0 and (flags & ActionMachine.DEFENSE_DEAD) != 0


# Defensa de [param victim] ante la flecha: bloqueo de cara a ella (el cono del arma o, con el muro, el
# ancho de las reglas) en la muestra de s o en la de s − defense_rewind si aún cuenta; nunca parada.
func _defense(projectile: Projectile, victim: Combatant, hit: CombatResolver.Hit, s: int) -> int:
	var frame: Combatant.Frozen = victim.frozen
	var weapon: WeaponTicks = CombatCatalog.weapon(frame.weapon_id)
	var attack: AttackTicks = projectile.attack
	if weapon == null or attack.unblockable or not DamageFormula.is_physical(attack.damage_type):
		return CombatResolver.Outcome.IMPACT
	var rules: CombatRules = CombatCatalog.rules()
	var cone: float = weapon.block_angle_deg
	var wide_cone: float = rules.ability_block_angle_deg
	# De dónde viene la flecha: un punto detrás de la víctima, contra su velocidad.
	var back := Vector3(-hit.direction.x, 0.0, -hit.direction.z)
	if CombatResolver.blocks_sample(frame, frame.defense, cone, wide_cone, frame.position + back):
		hit.wide_block = (frame.defense & ActionMachine.DEFENSE_WIDE_BLOCK) != 0
		return CombatResolver.Outcome.BLOCKED
	var old_tick: int = s - projectile.defense_rewind
	if old_tick < s and not CombatResolver.dropped_guard_after(frame, float(old_tick)):
		var old: StateHistory.Sample = _history.sample(victim.get_id(), float(old_tick))
		if old != null and CombatResolver.blocks_sample(old, old.flags, cone, wide_cone, old.position + back):
			hit.wide_block = (old.flags & ActionMachine.DEFENSE_WIDE_BLOCK) != 0
			return CombatResolver.Outcome.BLOCKED
	return CombatResolver.Outcome.IMPACT


# Un golpe de [param projectile] sobre [param victim] en el tick [param s] (el resultado lo pone quien
# llama).
func _hit_on(projectile: Projectile, victim: Combatant, s: int, flown: int,
		touch: _Touch) -> CombatResolver.Hit:
	var hit: CombatResolver.Hit = _base_hit(projectile, s)
	hit.victim = victim
	hit.direction = projectile.velocity_after(float(flown) + touch.fraction)
	return hit


func _structure_hit(projectile: Projectile, target: StructureTarget, s: int) -> CombatResolver.Hit:
	var hit: CombatResolver.Hit = _base_hit(projectile, s)
	hit.structure = target
	hit.outcome = CombatResolver.Outcome.STRUCTURE
	hit.view_tick = float(s)
	hit.rewind = 0.0
	return hit


func _base_hit(projectile: Projectile, s: int) -> CombatResolver.Hit:
	var hit := CombatResolver.Hit.new()
	hit.attacker = projectile.owner
	hit.attack = projectile.attack
	hit.projectile_id = projectile.id
	hit.projectile = projectile
	hit.view_tick = float(s - projectile.rewind)
	hit.rewind = float(projectile.rewind)
	return hit


# --- Candidatos y muros del tick --------------------------------------------------------------

# Calcula una vez por tick los candidatos (vivos, con su caja barrida ensanchada con la cápsula) y los muros
# de escudos de [member _combatants] (solo de quien está sin protección y fuera de la zona segura de su
# reino), en los arrays del tick (sin crear objetos salvo los muros).
func _prepare(s: int) -> void:
	if _prepared_tick == s:
		return
	_prepared_tick = s
	_walls = []
	var safe_areas: SafeAreas = _resolver.get_safe_areas()
	var check_safe: bool = safe_areas.size() > 0
	var reach := Vector3(HitShapes.CAPSULE_RADIUS, 0.0, HitShapes.CAPSULE_RADIUS)
	var top := Vector3(HitShapes.CAPSULE_RADIUS, HitShapes.CAPSULE_HEIGHT, HitShapes.CAPSULE_RADIUS)
	var total: int = _combatants.size()
	if _candidate_ids.size() < total:
		_candidates.resize(total)
		_candidate_ids.resize(total)
		_candidate_realms.resize(total)
		_candidate_open.resize(total)
		_candidate_low.resize(total)
		_candidate_high.resize(total)
	var count: int = 0
	for combatant: Combatant in _combatants:
		if combatant.is_dead():
			continue
		var frame: Combatant.Frozen = combatant.frozen
		var net_id: int = combatant.get_id()
		var realm: int = combatant.get_realm()
		var open: bool = not combatant.is_protected(s) \
				and not (check_safe and safe_areas.contains_own(realm, frame.position))
		var low: Vector3 = frame.position
		var high: Vector3 = frame.position
		var box: AABB = _history.swept_box(net_id)
		if box.size.x >= 0.0:
			low = low.min(box.position)
			high = high.max(box.end)
		_candidates[count] = combatant
		_candidate_ids[count] = net_id
		_candidate_realms[count] = realm
		_candidate_open[count] = 1 if open else 0
		_candidate_low[count] = low - reach
		_candidate_high[count] = high + top
		count += 1
		# Solo el muro de quien está «abierto»: el de quien tiene protección o está en la zona segura de su
		# reino no para flechas (pasan como por su cápsula), así no gasta resistencia, ni se le rompe la
		# guardia, ni queda en combate dentro de su campamento (docs/combate.md §5).
		if open and frame.wall_half_extents != Vector3.ZERO:
			var wall := _Wall.new()
			wall.holder = combatant
			wall.realm = realm
			wall.box = frame.wall
			wall.half_extents = frame.wall_half_extents
			wall.forward = frame.wall.basis * Vector3.FORWARD
			_walls.append(wall)
	_candidate_count = count
	# Sin referencias colgadas a quien ya no está.
	for index: int in range(count, _candidates.size()):
		_candidates[index] = null
	# El barrido en x: los estrechos ordenados por su borde izquierdo; los anchos, aparte.
	_sweep.resize(count)
	_wide.clear()
	_sweep_width = 0.0
	var narrow: int = 0
	for index: int in count:
		var width: float = _candidate_high[index].x - _candidate_low[index].x
		if not (width <= _SWEEP_WIDE_M) or index > _SWEEP_INDEX_MASK:
			_wide.append(index)
			continue
		_sweep_width = maxf(_sweep_width, width)
		_sweep[narrow] = (_sweep_key(_candidate_low[index].x) << _SWEEP_INDEX_BITS) | index
		narrow += 1
	_sweep.resize(narrow)
	_sweep.sort()
	# El redondeo del borde a centímetros (hacia abajo) nunca deja fuera una caja: la ventana se abre un
	# centímetro más.
	_sweep_width += 0.01


# --- Bajas ------------------------------------------------------------------------------------

## Retira en el tick [param s], con DESPAWN 5, todos los proyectiles vivos de [param owner_id] (el tirador se
## da de baja: salida, [code]--fake-churn[/code], un PNJ retirado).
func forget_owner(owner_id: int, s: int) -> void:
	var leaving: Array[Projectile] = []
	for projectile: Projectile in _live:
		if projectile.owner_id == owner_id:
			leaving.append(projectile)
	for projectile: Projectile in leaving:
		stats[&"projectiles_forgotten"] += 1
		_live.erase(projectile)
		_end(projectile, s, _EXPIRED)
	# Ni los candidatos del tick ni los muros guardan ya a quien se va.
	_prepared_tick = -1


## Quita todos los proyectiles sin avisar (cierre del servidor).
func clear() -> void:
	for projectile: Projectile in _live:
		registry.release_transient_id(projectile.id, projectile.spawn_tick)
	_live.clear()
	_rejected.clear()
	_combatants = []
	_candidates.clear()
	_candidate_ids.clear()
	_candidate_realms.clear()
	_candidate_open.clear()
	_candidate_low.clear()
	_candidate_high.clear()
	_candidate_count = 0
	_sweep.clear()
	_wide.clear()
	_walls = []
	_prepared_tick = -1


# Baja de [param projectile] (ya fuera de la lista): DESPAWN y su id a la cuarentena.
func _end(projectile: Projectile, s: int, reason: int) -> void:
	registry.release_transient_id(projectile.id, s)
	despawned.emit(projectile.id, s, reason, PackedInt32Array([projectile.owner_id]))
