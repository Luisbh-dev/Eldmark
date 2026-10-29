class_name Ballistics
extends RefCounted
## Balística de los proyectiles (docs/habilidades.md, sección 4.4). Servidor y cliente llaman a la
## misma [method position], con [code]n[/code] entero (el servidor, en cada tick) o fraccionario (el
## dibujo), a partir del origen y la velocidad tal y como viajan en el ENTITY_SPAWN
## ([method quantize]): así las dos trayectorias son la misma.

## Ticks por segundo de la simulación.
const TICK_RATE: float = 60.0


## Posición de un proyectil lanzado desde [param p0] con velocidad [param v0] (m/s) y gravedad
## [param gravity] (m/s², hacia abajo) tras [param ticks] ticks:
## [code]p0 + v0 · n/60 + (0, −½ · g · (n/60)², 0)[/code]. Cada eje se calcula en coma flotante de
## 64 bits y se redondea una sola vez al construir el [Vector3].
static func position(p0: Vector3, v0: Vector3, gravity: float, ticks: float) -> Vector3:
	var t: float = ticks / TICK_RATE
	var x: float = p0.x + v0.x * t
	var y: float = p0.y + v0.y * t - 0.5 * gravity * t * t
	var z: float = p0.z + v0.z * t
	return Vector3(x, y, z)


## [param p0] y [param v0] redondeados como viajan en el ENTITY_SPAWN de un proyectil: la posición a
## 1 cm (20 bits por eje, como el registro de entidad) y la velocidad a 1 cm/s (s16 por eje). El
## servidor vuela con esto, no con lo que calculó. Devuelve [code][p0, v0][/code].
static func quantize(p0: Vector3, v0: Vector3) -> Array:
	var position_q: Vector3 = NetMath.unpack_position(NetMath.pack_position(p0))
	var velocity_q := Vector3(
		NetMath.dequantize_velocity(NetMath.quantize_velocity(v0.x)),
		NetMath.dequantize_velocity(NetMath.quantize_velocity(v0.y)),
		NetMath.dequantize_velocity(NetMath.quantize_velocity(v0.z)),
	)
	return [position_q, velocity_q]
