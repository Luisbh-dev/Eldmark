class_name NetMath
extends RefCounted
## Quantization of the values that travel in entity records (docs/networking.md, section 5.5).
## [br][br]
## The position takes 60 bits: 20 per axis with [code]q = round(v * 100) + 2^19[/code], saturated to
## [code][0, 2^20 - 1][/code] (1 cm resolution, ±5.24 km). x goes in bits 0-19, y in
## 20-39 and z in 40-59; bits 60-63 stay at 0 (bit 63 is never used because GDScript's
## int is signed).

## Quantization steps per meter.
const POSITION_SCALE: float = 100.0
## Offset that makes the quantized value of an axis positive.
const POSITION_BIAS: int = 1 << 19
## Maximum quantized value of an axis.
const POSITION_MAX: int = (1 << 20) - 1
const _AXIS_BITS: int = 20
const _YAW_STEPS: int = 65536
const _VELOCITY_SCALE: float = 100.0
const _S16_MIN: int = -32768
const _S16_MAX: int = 32767


## Packs [param position] into 60 bits. Out-of-range axes are saturated and a NaN counts
## as 0.
static func pack_position(position: Vector3) -> int:
	return _pack_axis(position.x) \
			| (_pack_axis(position.y) << _AXIS_BITS) \
			| (_pack_axis(position.z) << (2 * _AXIS_BITS))


## Inverse of [method pack_position]. Ignores bits 60-63.
static func unpack_position(packed: int) -> Vector3:
	return Vector3(
		float((packed & POSITION_MAX) - POSITION_BIAS) / POSITION_SCALE,
		float(((packed >> _AXIS_BITS) & POSITION_MAX) - POSITION_BIAS) / POSITION_SCALE,
		float(((packed >> (2 * _AXIS_BITS)) & POSITION_MAX) - POSITION_BIAS) / POSITION_SCALE
	)


## Yaw in radians -> 0..65535 over [0, TAU), same as [member PlayerInput.look_yaw]. A non-finite
## value gives 0.
static func quantize_yaw16(yaw: float) -> int:
	if not is_finite(yaw):
		return 0
	return roundi(fposmod(yaw, TAU) / TAU * _YAW_STEPS) % _YAW_STEPS


## Inverse of [method quantize_yaw16]: returns a yaw in [0, TAU).
static func dequantize_yaw16(quantized: int) -> float:
	return (quantized & (_YAW_STEPS - 1)) / float(_YAW_STEPS) * TAU


## Speed in m/s -> cm/s saturated to s16 (±327 m/s). A NaN gives 0.
static func quantize_velocity(value: float) -> int:
	if is_nan(value):
		return 0
	return clampi(roundi(clampf(value * _VELOCITY_SCALE, _S16_MIN, _S16_MAX)), _S16_MIN, _S16_MAX)


## Inverse of [method quantize_velocity], in m/s.
static func dequantize_velocity(quantized: int) -> float:
	return quantized / _VELOCITY_SCALE


static func _pack_axis(value: float) -> int:
	if is_nan(value):
		return POSITION_BIAS
	var scaled: float = clampf(value * POSITION_SCALE, -POSITION_BIAS, POSITION_MAX - POSITION_BIAS)
	return clampi(roundi(scaled) + POSITION_BIAS, 0, POSITION_MAX)
