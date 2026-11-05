class_name ChargeAura
extends VfxEffect
## Heavy strike charge aura (ART-09, client only): a continuous effect that grows with the charge and is
## concentrated on the weapon, not the body.
## [br][br]
## It hangs from the character (at ground level, unscaled). It is switched on with [method play], fed every
## frame with [method set_charge] (0 to 1, the strike's charge fraction) and switched off with [method stop]
## if canceled or with [method release] if the strike lands. On reaching full charge it fires the
## [code]pulse[/code] cue once (a flash on the blade and a flat wave on the ground: noticeable without looking at the bar) and leaves
## the charge at maximum; [method release] fires the [code]release[/code] cue, the burst of the release.
## [br][br]
## [b]What is seen.[/b] On the weapon: a strip of light along the blade that grows with the charge (the core
## widens and heats up, pulses run toward the tip), motes and embers that the blade absorbs and, with almost
## full charge, a heat distortion. On the ground: the rune that closes. The body carries nothing
## on top (an energy shell hid the character and did not say what was being charged).
## [br][br]
## [b]The weapon.[/b] Everything that goes on the blade hangs from the [code]Blade[/code] node, whose +X axis is the blade.
## [method set_weapon] hangs it from the weapon node (the sword's [BoneAttachment3D]) so it follows it
## without lag; with no weapon it stays on the character, in a rest position. Whatever depends on the
## charge carries the [code]vfx_charge[/code] metadata with the name of the instance parameter that receives the
## value, or [code]vfx_charge_amount[/code] (particles: their emitted fraction).

const META_CHARGE: StringName = &"vfx_charge"
const META_CHARGE_AMOUNT: StringName = &"vfx_charge_amount"
const CUE_PULSE: StringName = &"pulse"
const CUE_RELEASE: StringName = &"release"
## Charge from which it is considered full and the pulse sounds.
const FULL_CHARGE: float = 0.995
## Blade the glow is mounted on (m, from the hilt to the tip of the provisional sword): what the
## [code]Blade[/code] node occupies at scale 1. A sword of another length scales the mount point (see [HumanoidVisual]).
const BLADE_BASE: float = 0.12
const BLADE_TIP: float = 1.12
const BLADE_LENGTH: float = BLADE_TIP - BLADE_BASE

## Realm that decides the color ([VfxPalette]).
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
	# The weapon hangs from the skeleton, not the aura: if the aura goes, it takes its own with it.
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


## Sets the current charge, from 0 to 1.
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


## Current charge (the last one from [method set_charge]).
func get_charge() -> float:
	return _charge


## The strike lands: burst and the aura switches off.
func release() -> void:
	if not is_playing():
		return
	trigger(CUE_RELEASE)
	stop()


## Hangs everything that goes on the blade from [param weapon] (the weapon node: its +X axis is the blade) so that
## it follows it frame by frame. With null it returns it to the rest position on the character.
func set_weapon(weapon: Node3D) -> void:
	_ensure_setup()
	_ensure_charge_setup()
	if _blade == null:
		return
	var target: Node = weapon if weapon != null else self
	if _blade.get_parent() != target:
		_blade.reparent(target, false)
	_blade.transform = Transform3D.IDENTITY if weapon != null else _rest_transform()


## Colors per realm (see [VfxPalette]).
func set_realm(value: int) -> void:
	realm = value
	_aura_color = VfxPalette.aura(value)
	tint = _aura_color


# With no weapon, the blade sits at the character's side, at hand height, pointing up and forward.
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
