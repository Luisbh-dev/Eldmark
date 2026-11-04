class_name CombatVfx
extends Node3D
## Conecta los efectos de golpe (ART-09, escenas de [code]scenes/vfx/[/code]) con el combate. Solo cliente.
## [br][br]
## Un nodo por cliente, en el mundo (los efectos se colocan en coordenadas globales). Tiene un [VfxPool] por efecto,
## creados una vez, y los dispara desde [CombatFeedback] ([method bind]) y desde los visuales ([HumanoidVisual]):
## [br]- [b]Impacto[/b] de todo golpe confirmado ([signal CombatFeedback.hit_impact]), propio o ajeno, en el
## punto de contacto: el pecho de la víctima, adelantado hacia el atacante, con la normal hacia él y la dirección del
## golpe a lo largo del tajo. Carne ([code]hit_flesh[/code]), malla ([code]hit_metal_spark[/code]), tela
## ([code]hit_cloth[/code]), escudo ([code]hit_block_wood[/code], sobre la cara del escudo) y parada
## ([code]parry_flash[/code] más chispas de metal): se distinguen de un vistazo.
## [br]- [b]Golpe predicho[/b] ([signal CombatFeedback.hit_predicted]): la carne al instante, sin esperar al servidor; si
## el servidor lo confirma como golpe normal no se repite.
## [br]- [b]Polvo[/b]: esquiva, aterrizaje y muerte ([method play_dodge_dust], [method play_land_dust],
## [method play_death_dust]), con el color del suelo ([VfxGround]).
## [br]- [b]Habilidades[/b] de espada y escudo ([method play_ability]): el golpe de escudo (impacto de escudo y onda de
## polvo), la carga (rastro de polvo) y el muro (el arco de [code]shield_wall[/code] con el borde del color del reino).
## [br][br]
## Los efectos son solo visuales y no dicen nada a la simulación.

const FLESH_SCENE: PackedScene = preload("res://scenes/vfx/hit_flesh.tscn")
const CLOTH_SCENE: PackedScene = preload("res://scenes/vfx/hit_cloth.tscn")
const METAL_SCENE: PackedScene = preload("res://scenes/vfx/hit_metal_spark.tscn")
const BLOCK_SCENE: PackedScene = preload("res://scenes/vfx/hit_block_wood.tscn")
const PARRY_SCENE: PackedScene = preload("res://scenes/vfx/parry_flash.tscn")
const DUST_SCENE: PackedScene = preload("res://scenes/vfx/dust_kick.tscn")
const WALL_SCENE: PackedScene = preload("res://scenes/vfx/shield_wall.tscn")

## Altura (m) del pecho sobre los pies, donde cae el impacto, y cuánto se adelanta hacia el atacante.
const CHEST_HEIGHT: float = 1.25
const CHEST_FORWARD: float = 0.32
## A qué distancia (m) delante de la víctima queda la cara del escudo en un golpe bloqueado.
const SHIELD_FORWARD: float = 0.62
const SHIELD_HEIGHT: float = 1.1
## Segundos entre el golpe mortal y el polvo del cuerpo al tocar el suelo.
const DEATH_DUST_DELAY: float = 0.42

static var _instance: CombatVfx = null

var _pools: Dictionary[StringName, VfxPool] = {}
var _counts: Dictionary[StringName, int] = {}
var _feedback: CombatFeedback = null


func _init() -> void:
	name = "CombatVfx"
	top_level = true


## El nodo de efectos vivo, o null (el servidor, las pruebas sin él).
static func get_instance() -> CombatVfx:
	return _instance if is_instance_valid(_instance) else null


func _enter_tree() -> void:
	_instance = self


func _exit_tree() -> void:
	if _instance == self:
		_instance = null


func _ready() -> void:
	_make_pool(&"flesh", FLESH_SCENE, 8)
	_make_pool(&"cloth", CLOTH_SCENE, 6)
	_make_pool(&"metal", METAL_SCENE, 6)
	_make_pool(&"block", BLOCK_SCENE, 5)
	_make_pool(&"parry", PARRY_SCENE, 3)
	_make_pool(&"dust", DUST_SCENE, 5)
	_make_pool(&"wall", WALL_SCENE, 3)


## Conecta con el reparto de la sensación de combate. Se puede volver a llamar con otro.
func bind(feedback: CombatFeedback) -> void:
	if is_instance_valid(_feedback):
		_feedback.hit_impact.disconnect(_on_hit_impact)
		_feedback.hit_predicted.disconnect(_on_hit_predicted)
		_feedback.entity_died.disconnect(_on_entity_died)
		_feedback.action_changed.disconnect(_on_local_action)
	_feedback = feedback
	if is_instance_valid(_feedback):
		_feedback.hit_impact.connect(_on_hit_impact)
		_feedback.hit_predicted.connect(_on_hit_predicted)
		_feedback.entity_died.connect(_on_entity_died)
		_feedback.action_changed.connect(_on_local_action)


# --- Disparos -----------------------------------------------------------------------------------

## Punto de contacto de un golpe a la víctima en [param victim_feet] desde el atacante en [param attacker_feet]: el pecho,
## adelantado hacia el atacante.
static func contact_point(victim_feet: Vector3, attacker_feet: Vector3) -> Vector3:
	var toward: Vector3 = _horizontal_toward(victim_feet, attacker_feet)
	return victim_feet + Vector3(0.0, CHEST_HEIGHT, 0.0) + toward * CHEST_FORWARD


## Impacto de un golpe. [param material] es un [enum CombatSoundBank.Armor]; con [param blocked] el golpe da en el
## escudo y con [param parried] es una parada.
func spawn_impact(victim_feet: Vector3, attacker_feet: Vector3, material: int, blocked: bool, parried: bool,
		heavy: bool) -> void:
	var toward: Vector3 = _horizontal_toward(victim_feet, attacker_feet)
	var blow: Vector3 = -toward
	var chest: Vector3 = contact_point(victim_feet, attacker_feet)
	var normal: Vector3 = (toward + Vector3(0.0, 0.25, 0.0)).normalized()
	if parried:
		_spawn(&"parry", chest + toward * 0.1, toward, blow)
		_spawn(&"metal", chest + toward * 0.05, normal, blow)
	elif blocked:
		var shield: Vector3 = victim_feet + Vector3(0.0, SHIELD_HEIGHT, 0.0) + toward * SHIELD_FORWARD
		_spawn(&"block", shield, toward, blow)
	else:
		match material:
			CombatSoundBank.Armor.MAIL, CombatSoundBank.Armor.SHIELD_METAL:
				_spawn(&"metal", chest, normal, blow)
			CombatSoundBank.Armor.LEATHER, CombatSoundBank.Armor.GAMBESON, CombatSoundBank.Armor.HOLLOW:
				_spawn(&"cloth", chest, normal, blow)
			_:
				_spawn(&"flesh", chest, normal, blow)
		if heavy:
			_spawn(&"metal", chest, normal, blow)


## Polvo de una esquiva en [param feet] hacia [param move_direction].
func play_dodge_dust(feet: Vector3, move_direction: Vector3) -> void:
	var kick: DustKick = _dust(feet)
	if kick != null:
		kick.play_dodge(feet, move_direction, 1.0)
		_count(&"dust")


## Polvo de un aterrizaje en [param feet] con [param strength] de 0 a 1.
func play_land_dust(feet: Vector3, strength: float) -> void:
	var kick: DustKick = _dust(feet)
	if kick != null:
		kick.play_landing(feet, strength)
		_count(&"dust")


## Polvo del cuerpo al caer en [param feet], un instante después del golpe mortal.
func play_death_dust(feet: Vector3) -> void:
	if is_inside_tree():
		get_tree().create_timer(DEATH_DUST_DELAY).timeout.connect(func() -> void:
			play_land_dust(feet, 0.9), CONNECT_ONE_SHOT)
	else:
		play_land_dust(feet, 0.9)


## Efecto de la habilidad [param ability] (el nombre de [member AbilityTicks.name]) de quien está en [param feet]
## mirando hacia [param forward], del reino [param realm] (colores del muro).
func play_ability(ability: StringName, feet: Vector3, forward: Vector3, realm: int) -> void:
	var ahead: Vector3 = Vector3(forward.x, 0.0, forward.z)
	ahead = ahead.normalized() if ahead.length_squared() > 0.0001 else Vector3.FORWARD
	match ability:
		&"shield_bash":
			_spawn(&"block", feet + Vector3(0.0, 1.05, 0.0) + ahead * 0.95, -ahead, ahead)
			play_land_dust(feet + ahead * 0.5, 0.75)
		&"shield_rush":
			play_dodge_dust(feet, ahead)
			if is_inside_tree():
				get_tree().create_timer(0.18).timeout.connect(func() -> void:
					play_dodge_dust(feet + ahead * 2.0, ahead), CONNECT_ONE_SHOT)
		&"shield_wall":
			var pool: VfxPool = _pools.get(&"wall") as VfxPool
			if pool != null:
				var colors: Array[Color] = VfxPalette.trail(realm)
				pool.set_tint(colors[1].lerp(Color.WHITE, 0.2))
				pool.spawn(feet + Vector3(0.0, 1.0, 0.0) + ahead * 0.9, ahead, Vector3.ZERO)
				_count(&"wall")


## Veces que ha salido el efecto [param pool_name] ([code]flesh[/code], [code]cloth[/code], [code]metal[/code],
## [code]block[/code], [code]parry[/code], [code]dust[/code], [code]wall[/code]): para las pruebas.
func get_spawn_count(pool_name: StringName) -> int:
	return _counts.get(pool_name, 0)


## Pool de un efecto (para las pruebas).
func get_pool(pool_name: StringName) -> VfxPool:
	return _pools.get(pool_name) as VfxPool


# --- Interno ------------------------------------------------------------------------------------

func _make_pool(pool_name: StringName, scene: PackedScene, size: int) -> void:
	var pool := VfxPool.new()
	pool.name = String(pool_name).capitalize()
	pool.setup(scene, size)
	add_child(pool)
	_pools[pool_name] = pool


func _spawn(pool_name: StringName, position: Vector3, normal: Vector3, direction: Vector3) -> void:
	var pool: VfxPool = _pools.get(pool_name) as VfxPool
	if pool == null:
		return
	pool.spawn(position, normal, direction)
	_count(pool_name)


func _count(pool_name: StringName) -> void:
	_counts[pool_name] = _counts.get(pool_name, 0) + 1


func _dust(feet: Vector3) -> DustKick:
	var pool: VfxPool = _pools.get(&"dust") as VfxPool
	if pool == null:
		return null
	var kick: DustKick = pool.acquire() as DustKick
	if kick != null:
		kick.set_ground_color(VfxGround.color_at(FootstepSurface.terrain_for(self), feet, &"dirt"))
	return kick


static func _horizontal_toward(from: Vector3, to: Vector3) -> Vector3:
	var flat: Vector3 = Vector3(to.x - from.x, 0.0, to.z - from.z)
	return flat.normalized() if flat.length_squared() > 0.0001 else Vector3.BACK


func _on_hit_impact(event: NetMessages.EntityEvent, position: Vector3, _involves_me: bool,
		already_predicted: bool) -> void:
	if already_predicted or not is_instance_valid(_feedback):
		return
	var attacker: Vector3 = _feedback.get_entity_position(event.attacker)
	if attacker == Vector3.INF:
		attacker = position + Vector3.BACK * 2.0
	var attack: AttackTicks = CombatCatalog.attack(event.attack_id)
	var audio: CombatAudio = CombatAudio.get_instance()
	var material: int = audio.material_of(event.net_id) if audio != null else CombatSoundBank.Armor.FLESH
	spawn_impact(position, attacker, material,
			event.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_BLOCKED),
			event.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_PARRIED), attack != null and attack.heavy)


func _on_hit_predicted(net_id: int, position: Vector3, heavy: bool) -> void:
	var attacker: Vector3 = _feedback.get_local_position() if is_instance_valid(_feedback) else Vector3.ZERO
	var audio: CombatAudio = CombatAudio.get_instance()
	var material: int = audio.material_of(net_id) if audio != null else CombatSoundBank.Armor.FLESH
	spawn_impact(position, attacker, material, false, false, heavy)


func _on_entity_died(_net_id: int, position: Vector3) -> void:
	play_death_dust(position)


func _on_local_action(action: int, attack_id: int, _action_tick: int, _previous: int) -> void:
	if not is_instance_valid(_feedback):
		return
	var feet: Vector3 = _feedback.get_local_position()
	if action == CombatState.Action.DODGE:
		play_dodge_dust(feet, _feedback.get_local_heading())
	elif action == CombatState.Action.ABILITY:
		var ability: AbilityTicks = CombatCatalog.ability(attack_id)
		if ability != null:
			play_ability(ability.name, feet, _feedback.get_local_heading(), _feedback.get_local_realm())
