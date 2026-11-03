class_name ChargeAura
extends VfxEffect
## Aura de carga del golpe fuerte (ART-09, solo cliente): un efecto continuo que crece con la carga y que
## se concentra en el arma, no en el cuerpo.
## [br][br]
## Cuelga del personaje (a ras de suelo, sin escala). Se enciende con [method play], se alimenta cada
## fotograma con [method set_charge] (0 a 1, la fracción de carga del golpe) y se apaga con [method stop]
## si se cancela o con [method release] si el golpe sale. Al llegar a carga completa lanza una vez el
## aviso [code]pulse[/code] (destello en la hoja y onda plana en el suelo: se nota sin mirar la barra) y deja
## la carga al máximo; [method release] lanza el aviso [code]release[/code], el estallido de la suelta.
## [br][br]
## [b]Qué se ve.[/b] En el arma: una franja de luz a lo largo de la hoja que crece con la carga (el núcleo
## se ensancha y se calienta, corren pulsos hacia la punta), motas y brasas que la hoja absorbe y, con casi
## toda la carga, una distorsión de calor. En el suelo: la runa que se cierra. El cuerpo no lleva nada
## encima (una cáscara de energía tapaba al personaje y no decía qué se cargaba).
## [br][br]
## [b]El arma.[/b] Todo lo que va en la hoja cuelga del nodo [code]Blade[/code], cuyo eje +X es la hoja.
## [method set_weapon] lo cuelga del nodo del arma (el [BoneAttachment3D] de la espada) para que la siga
## sin retraso; sin arma se queda sobre el personaje, en una posición de reposo. Lo que depende de la
## carga lleva el metadato [code]vfx_charge[/code] con el nombre del parámetro de instancia que recibe el
## valor, o [code]vfx_charge_amount[/code] (partículas: su fracción emitida).

const META_CHARGE: StringName = &"vfx_charge"
const META_CHARGE_AMOUNT: StringName = &"vfx_charge_amount"
const CUE_PULSE: StringName = &"pulse"
const CUE_RELEASE: StringName = &"release"
## Carga a partir de la cual se considera completa y suena el pulso.
const FULL_CHARGE: float = 0.995

## Reino que decide el color ([VfxPalette]).
@export var realm: int = 0:
	set = set_realm

var _charge: float = 0.0
var _pulsed: bool = false
var _charged: Array[GeometryInstance3D] = []
var _amounts: Array[GPUParticles3D] = []
var _aura_color: Color = Color.WHITE
var _charge_setup: bool = false
var _blade: Node3D = null


func _ready() -> void:
	super._ready()
	_ensure_charge_setup()
	set_realm(realm)
	_set_blade_visible(false)


func _exit_tree() -> void:
	# El arma cuelga del esqueleto, no de la aura: si la aura se va, se lleva lo suyo.
	if _blade != null and is_instance_valid(_blade) and not is_ancestor_of(_blade):
		_blade.queue_free()


func play() -> void:
	_ensure_charge_setup()
	_pulsed = false
	super.play()
	_set_blade_visible(true)
	set_charge(_charge)


func reset() -> void:
	super.reset()
	_set_blade_visible(false)


## Pone la carga actual, de 0 a 1.
func set_charge(value: float) -> void:
	_ensure_charge_setup()
	_charge = clampf(value, 0.0, 1.0)
	for node: GeometryInstance3D in _charged:
		var param: StringName = StringName(node.get_meta(META_CHARGE))
		node.set_instance_shader_parameter(param, _charge)
	for particles: GPUParticles3D in _amounts:
		particles.amount_ratio = lerpf(0.12, 1.0, _charge)
		particles.speed_scale = lerpf(0.8, 1.35, _charge)
	if is_playing():
		if _charge >= FULL_CHARGE and not _pulsed:
			_pulsed = true
			trigger(CUE_PULSE)
		elif _charge < 0.9:
			_pulsed = false


## Carga actual (la última de [method set_charge]).
func get_charge() -> float:
	return _charge


## El golpe sale: estallido y la aura se apaga.
func release() -> void:
	if not is_playing():
		return
	trigger(CUE_RELEASE)
	stop()


## Cuelga todo lo que va en la hoja de [param weapon] (el nodo del arma: su eje +X es la hoja) para que
## la siga fotograma a fotograma. Con null lo devuelve a la posición de reposo sobre el personaje.
func set_weapon(weapon: Node3D) -> void:
	_ensure_setup()
	_ensure_charge_setup()
	if _blade == null:
		return
	var target: Node = weapon if weapon != null else self
	if _blade.get_parent() != target:
		_blade.reparent(target, false)
	_blade.transform = Transform3D.IDENTITY if weapon != null else _rest_transform()


## Colores por reino (ver [VfxPalette]).
func set_realm(value: int) -> void:
	realm = value
	_aura_color = VfxPalette.aura(value)
	tint = _aura_color


# Sin arma, la hoja queda de lado del personaje, a la altura de la mano, apuntando hacia arriba y adelante.
func _rest_transform() -> Transform3D:
	var basis: Basis = Basis.from_euler(Vector3(0.0, 0.0, deg_to_rad(55.0)))
	return Transform3D(basis, Vector3(0.45, 0.85, -0.2))


func _set_blade_visible(value: bool) -> void:
	if _blade != null and is_instance_valid(_blade):
		_blade.visible = value


func _ensure_charge_setup() -> void:
	if _charge_setup:
		return
	_charge_setup = true
	_blade = get_node_or_null(^"Blade") as Node3D
	if _blade != null:
		_blade.transform = _rest_transform()
	for node: Node in find_children("*", "", true, false):
		if node is GeometryInstance3D and node.has_meta(META_CHARGE):
			_charged.append(node as GeometryInstance3D)
		if node is GPUParticles3D and node.has_meta(META_CHARGE_AMOUNT):
			_amounts.append(node as GPUParticles3D)
