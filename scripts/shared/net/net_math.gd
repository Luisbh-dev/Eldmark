class_name NetMath
extends RefCounted
## Cuantización de los valores que viajan en los registros de entidad (docs/red.md, sección 5.5).
## [br][br]
## La posición ocupa 60 bits: 20 por eje con [code]q = round(v * 100) + 2^19[/code], saturado a
## [code][0, 2^20 - 1][/code] (1 cm de resolución, ±5,24 km). El x va en los bits 0-19, el y en
## 20-39 y el z en 40-59; los bits 60-63 quedan a 0 (el bit 63 nunca se usa porque el int de
## GDScript tiene signo).

## Pasos de cuantización por metro.
const POSITION_SCALE: float = 100.0
## Desplazamiento que hace positivo el valor cuantizado de un eje.
const POSITION_BIAS: int = 1 << 19
## Valor cuantizado máximo de un eje.
const POSITION_MAX: int = (1 << 20) - 1
const _AXIS_BITS: int = 20
const _YAW_STEPS: int = 65536
const _VELOCITY_SCALE: float = 100.0
const _S16_MIN: int = -32768
const _S16_MAX: int = 32767


## Empaqueta [param position] en 60 bits. Los ejes fuera de rango se saturan y un NaN cuenta
## como 0.
static func pack_position(position: Vector3) -> int:
	return _pack_axis(position.x) \
			| (_pack_axis(position.y) << _AXIS_BITS) \
			| (_pack_axis(position.z) << (2 * _AXIS_BITS))


## Inversa de [method pack_position]. Ignora los bits 60-63.
static func unpack_position(packed: int) -> Vector3:
	return Vector3(
		float((packed & POSITION_MAX) - POSITION_BIAS) / POSITION_SCALE,
		float(((packed >> _AXIS_BITS) & POSITION_MAX) - POSITION_BIAS) / POSITION_SCALE,
		float(((packed >> (2 * _AXIS_BITS)) & POSITION_MAX) - POSITION_BIAS) / POSITION_SCALE
	)


## Yaw en radianes -> 0..65535 sobre [0, TAU), igual que [member PlayerInput.look_yaw]. Un valor
## no finito da 0.
static func quantize_yaw16(yaw: float) -> int:
	if not is_finite(yaw):
		return 0
	return roundi(fposmod(yaw, TAU) / TAU * _YAW_STEPS) % _YAW_STEPS


## Inversa de [method quantize_yaw16]: devuelve un yaw en [0, TAU).
static func dequantize_yaw16(quantized: int) -> float:
	return (quantized & (_YAW_STEPS - 1)) / float(_YAW_STEPS) * TAU


## Velocidad en m/s -> cm/s saturado a s16 (±327 m/s). Un NaN da 0.
static func quantize_velocity(value: float) -> int:
	if is_nan(value):
		return 0
	return clampi(roundi(clampf(value * _VELOCITY_SCALE, _S16_MIN, _S16_MAX)), _S16_MIN, _S16_MAX)


## Inversa de [method quantize_velocity], en m/s.
static func dequantize_velocity(quantized: int) -> float:
	return quantized / _VELOCITY_SCALE


static func _pack_axis(value: float) -> int:
	if is_nan(value):
		return POSITION_BIAS
	var scaled: float = clampf(value * POSITION_SCALE, -POSITION_BIAS, POSITION_MAX - POSITION_BIAS)
	return clampi(roundi(scaled) + POSITION_BIAS, 0, POSITION_MAX)
