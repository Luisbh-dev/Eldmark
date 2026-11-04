extends RefCounted
## Banco de capturas de calidad (TEC-50): el cliente de captura como compañero de entrenamiento.
##
## Conduce al personaje del cliente con [code]Input.action_press[/code] contra un enemigo, para que pelee de verdad
## contra los PNJ y los bots mientras los escenarios graban. Modos ([member mode]):
## [br]- [code]fight[/code]: se acerca, ataca con ligeros y de vez en cuando usa una habilidad, esquiva o bloquea.
## [br]- [code]heavy[/code]: se acerca y suelta golpes fuertes cargados (derriban y hacen tambalear).
## [br]- [code]tank[/code]: se queda delante con el escudo arriba, sin atacar (para ver golpes recibidos en bloqueo).
## [br]- [code]idle[/code]: mira al enemigo sin hacer nada, recibe los golpes.
## [br]- [code]kite[/code]: retrocede mirando al enemigo (para que corra detrás).
## [br]- [code]observe[/code]: se aleja hasta unos 5 m y se queda quieto mirando (para ver caer o morir a alguien sin
## tenerlo encima).
## [br]- [code]execute[/code]: se acerca a un derribado y mantiene INTERACT para rematarlo.
## Se llama a [method step] una vez por fotograma. La cámara apunta [member look_offset_deg] grados a la izquierda del
## enemigo: con la cámara por encima del hombro, así el enemigo queda a la derecha del centro y el cuerpo del cliente,
## que está en primer plano a la izquierda, no lo tapa en las tiras.

## Puntos (x, z) delante del campamento de Solmarch, fuera de su zona segura (a unos 30 m de su centro) y a la vista del bot
## de combate (40 m), para quedar con él: [code]online_driver.open_spot[/code] elige el más despejado.
const MEET_CANDIDATES: Array = [Vector2(0.0, 105.0), Vector2(30.0, 100.0), Vector2(-30.0, 100.0), Vector2(55.0, 104.0),
		Vector2(-55.0, 104.0), Vector2(15.0, 92.0), Vector2(-15.0, 92.0), Vector2(75.0, 100.0), Vector2(-75.0, 100.0)]

var mode: String = "fight"
## Con [code]true[/code], el modo [code]fight[/code] no usa habilidades ni esquiva (solo ligeros y bloqueo ocasional).
var plain: bool = false
## Grados que la cámara se desvía hacia la izquierda del enemigo (ver arriba).
var look_offset_deg: float = 24.0
## Distancia (m) a la que se queda en el modo [code]observe[/code].
var observe_distance: float = 5.0
## Separación (m) que mantiene en el cuerpo a cuerpo: se acerca si está más lejos que [member melee_max] y retrocede si está
## más cerca que [member melee_min], para que los cuerpos no se monten uno sobre otro (con la cámara por encima del hombro, un
## enemigo pegado queda detrás del personaje y las tiras no enseñan nada). La espada llega a 2,6 m, así que se golpea bien así.
var melee_min: float = 1.5
var melee_max: float = 2.4

var _d: Variant
var _rng := RandomNumberGenerator.new()
var _next_attack_ms: int = 0
var _next_special_ms: int = 0
var _block_until_ms: int = 0
var _heavy_until_ms: int = 0
var _held_primary: bool = false


func _init(driver: Variant, seed_value: int = 7) -> void:
	_d = driver
	_rng.seed = seed_value
	_next_special_ms = Time.get_ticks_msec() + 2500


func set_mode(new_mode: String) -> void:
	if new_mode != mode:
		_release_all()
	mode = new_mode


## Un fotograma de sparring contra el enemigo en [param enemy_pos]: mira hacia él y hace lo que toque según el modo.
func step(enemy_pos: Vector3) -> void:
	var now: int = Time.get_ticks_msec()
	var p: Vector3 = _d.pos()
	var dist: float = Vector2(enemy_pos.x - p.x, enemy_pos.z - p.z).length()
	# La desviación de la cámara solo vale en el cuerpo a cuerpo (cerca y sin andar hacia el enemigo): al acercarse, retroceder
	# o apartarse, el personaje anda hacia donde mira la cámara y una cámara torcida lo desviaría.
	var offset: float = look_offset_deg if (dist <= 5.0 and mode != "kite" and mode != "observe") else 0.0
	_d.look(_d.yaw_to(p.x, p.z, enemy_pos.x, enemy_pos.z) + offset, 6.0)
	match mode:
		"observe":
			_d.release(&"move_forward")
			_d.release(&"block")
			if dist < observe_distance:
				_d.hold(&"move_back")
			else:
				_d.release(&"move_back")
		"idle":
			_d.release(&"move_forward")
			_d.release(&"move_back")
		"kite":
			_d.release(&"move_forward")
			if dist < 14.0:
				_d.hold(&"move_back")
			else:
				_d.release(&"move_back")
		"tank":
			_keep_spacing(dist, melee_min, melee_max)
			_d.hold(&"block")
		"heavy":
			_keep_spacing(dist, melee_min, melee_max)
			if dist <= 2.8:
				if _held_primary and now >= _heavy_until_ms:
					_d.release(&"primary_attack")
					_held_primary = false
					_next_attack_ms = now + 1400
				elif not _held_primary and now >= _next_attack_ms:
					_d.hold(&"primary_attack")
					_held_primary = true
					_heavy_until_ms = now + 900
		"execute":
			_approach(dist, 1.6)
			_d.hold(&"interact")
		_:
			_fight(now, dist)


func stop() -> void:
	_release_all()


func _release_all() -> void:
	for action: StringName in [&"move_forward", &"move_back", &"sprint", &"block", &"primary_attack", &"interact"]:
		_d.release(action)
	_held_primary = false


func _approach(dist: float, stop_at: float) -> void:
	if dist > stop_at + 0.4:
		_d.hold(&"move_forward")
		if dist > 10.0:
			_d.hold(&"sprint")
		else:
			_d.release(&"sprint")
	else:
		_d.release(&"move_forward")
		_d.release(&"sprint")


# Se acerca si está lejos, retrocede si está demasiado cerca y se queda quieto entre las dos distancias.
func _keep_spacing(dist: float, min_d: float, max_d: float) -> void:
	if dist > max_d:
		_d.release(&"move_back")
		_d.hold(&"move_forward")
		if dist > 10.0:
			_d.hold(&"sprint")
		else:
			_d.release(&"sprint")
	elif dist < min_d:
		_d.release(&"move_forward")
		_d.release(&"sprint")
		_d.hold(&"move_back")
	else:
		_d.release(&"move_forward")
		_d.release(&"move_back")
		_d.release(&"sprint")


func _fight(now: int, dist: float) -> void:
	_keep_spacing(dist, melee_min, melee_max)
	if dist > melee_max:
		return
	if now < _block_until_ms:
		return
	_d.release(&"block")
	if now >= _next_special_ms:
		var pick: int = _rng.randi() % (2 if plain else 5)
		match pick:
			0:
				if plain:
					_block_for(now, 900)
				else:
					_d.tap(&"ability_1", 3)
			1:
				_block_for(now, 900)
			2:
				_d.tap(&"ability_2", 3)
			3:
				_d.tap(&"dodge", 3)
			_:
				_block_for(now, 900)
		_next_special_ms = now + 2200 + _rng.randi() % 1500
	elif now >= _next_attack_ms:
		_d.tap(&"primary_attack", 3)
		_next_attack_ms = now + 420


func _block_for(now: int, ms: int) -> void:
	_d.hold(&"block")
	_block_until_ms = now + ms
