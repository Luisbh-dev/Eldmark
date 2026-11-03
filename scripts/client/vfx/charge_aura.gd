class_name ChargeAura
extends VfxEffect
## Aura de carga del golpe fuerte (ART-09, solo cliente): un efecto continuo que crece con la carga.
## [br][br]
## Cuelga del personaje (a ras de suelo, sin escala). Se enciende con [method play], se alimenta cada
## fotograma con [method set_charge] (0 a 1, la fracción de carga del golpe) y se apaga con [method stop]
## si se cancela o con [method release] si el golpe sale. Al llegar a carga completa lanza una vez el
## aviso [code]pulse[/code] (anillo y destello: se nota sin mirar la barra) y deja la aura al máximo;
## [method release] lanza el aviso [code]release[/code], el estallido de la suelta.
## [br][br]
## Está hecha de una cáscara de energía alrededor del cuerpo con vetas que suben, motas que convergen
## hacia el pecho, lenguas que suben por los costados y una runa en el suelo que se cierra. Todo lo que
## depende de la carga lleva el metadato [code]vfx_charge[/code] con el nombre del parámetro de instancia
## que recibe el valor, o [code]vfx_charge_amount[/code] (partículas: su fracción emitida).

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


func _ready() -> void:
	super._ready()
	_ensure_charge_setup()
	set_realm(realm)


func play() -> void:
	_ensure_charge_setup()
	_pulsed = false
	super.play()
	set_charge(_charge)


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


## Colores por reino (ver [VfxPalette]).
func set_realm(value: int) -> void:
	realm = value
	_aura_color = VfxPalette.aura(value)
	tint = _aura_color


func _ensure_charge_setup() -> void:
	if _charge_setup:
		return
	_charge_setup = true
	for node: Node in find_children("*", "", true, false):
		if node is GeometryInstance3D and node.has_meta(META_CHARGE):
			_charged.append(node as GeometryInstance3D)
		if node is GPUParticles3D and node.has_meta(META_CHARGE_AMOUNT):
			_amounts.append(node as GPUParticles3D)
