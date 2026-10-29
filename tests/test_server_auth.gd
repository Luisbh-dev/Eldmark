extends TestCase
## Pruebas de la validación del HELLO ([ServerAuth]): cada motivo de REJECT, el orden de las
## comprobaciones, el tope de conexiones por IP con la excepción de loopback y el
## [AuthProvider] (docs/red.md, secciones 3 y 12).

const SIM_HASH: int = 0xA1B2C3D4
const REMOTE_ADDRESS: String = "203.0.113.7"


## Proveedor de prueba: cuenta las llamadas y devuelve lo que se le pida.
class CountingProvider extends AuthProvider:
	var calls: int = 0
	var result: int = NetProtocol.Result.OK


	func authenticate(_hello: NetMessages.Hello) -> int:
		calls += 1
		return result


func _make_config(max_players: int = 4, max_per_ip: int = 2) -> ServerConfig:
	var config := ServerConfig.new()
	config.max_players = max_players
	config.max_connections_per_ip = max_per_ip
	return config


func _make_auth(provider: AuthProvider = null, allowed: PackedInt32Array = PackedInt32Array(),
		config: ServerConfig = null) -> ServerAuth:
	return ServerAuth.new(config if config != null else _make_config(), SIM_HASH, allowed,
			provider if provider != null else DevAuthProvider.new())


func _make_hello() -> NetMessages.Hello:
	var hello := NetMessages.Hello.new()
	hello.sim_hash = SIM_HASH
	hello.realm = NetProtocol.Realm.VARDHEIM
	hello.display_name = "Ana"
	return hello


func test_valid_hello_is_accepted() -> void:
	var auth: ServerAuth = _make_auth()
	assert_eq(auth.validate(_make_hello(), REMOTE_ADDRESS, 0, 0), NetProtocol.Result.OK,
			"un HELLO correcto")
	# Y también si pasa por el cable.
	var decoded: NetMessages.Hello = NetMessages.Hello.decode(_make_hello().encode())
	if assert_not_null(decoded, "el HELLO se decodifica"):
		assert_eq(auth.validate(decoded, REMOTE_ADDRESS, 0, 0), NetProtocol.Result.OK,
				"un HELLO decodificado")


func test_malformed_hello_is_rejected() -> void:
	assert_eq(_make_auth().validate(null, REMOTE_ADDRESS, 0, 0), NetProtocol.Result.MALFORMED,
			"sin HELLO (el decode devolvió null)")


func test_reject_version() -> void:
	var hello: NetMessages.Hello = _make_hello()
	hello.protocol_version = NetProtocol.PROTOCOL_VERSION + 1
	assert_eq(_make_auth().validate(hello, REMOTE_ADDRESS, 0, 0), NetProtocol.Result.VERSION,
			"versión más nueva")
	hello.protocol_version = 0
	assert_eq(_make_auth().validate(hello, REMOTE_ADDRESS, 0, 0), NetProtocol.Result.VERSION,
			"versión 0")


func test_reject_sim_hash() -> void:
	var hello: NetMessages.Hello = _make_hello()
	hello.sim_hash = SIM_HASH ^ 1
	assert_eq(_make_auth().validate(hello, REMOTE_ADDRESS, 0, 0), NetProtocol.Result.SIM_HASH,
			"huella distinta")


func test_reject_realm_none_and_out_of_range() -> void:
	var auth: ServerAuth = _make_auth()
	for realm: int in [NetProtocol.Realm.NONE, 4, 5, 200, 255]:
		var hello: NetMessages.Hello = _make_hello()
		hello.realm = realm
		assert_eq(auth.validate(hello, REMOTE_ADDRESS, 0, 0), NetProtocol.Result.REALM,
				"el reino %d no vale" % realm)


func test_every_real_realm_is_accepted_when_allowed_is_empty() -> void:
	var auth: ServerAuth = _make_auth()
	for realm: int in [NetProtocol.Realm.VARDHEIM, NetProtocol.Realm.SOLMARCH,
			NetProtocol.Realm.ASKARRA]:
		var hello: NetMessages.Hello = _make_hello()
		hello.realm = realm
		assert_eq(auth.validate(hello, REMOTE_ADDRESS, 0, 0), NetProtocol.Result.OK,
				"el reino %d se admite si la zona no restringe" % realm)


func test_reject_realm_not_allowed_in_zone() -> void:
	var allowed := PackedInt32Array([NetProtocol.Realm.VARDHEIM, NetProtocol.Realm.SOLMARCH])
	var auth: ServerAuth = _make_auth(null, allowed)
	var hello: NetMessages.Hello = _make_hello()
	hello.realm = NetProtocol.Realm.ASKARRA
	assert_eq(auth.validate(hello, REMOTE_ADDRESS, 0, 0), NetProtocol.Result.REALM,
			"Askarra no está admitido en la zona")
	hello.realm = NetProtocol.Realm.SOLMARCH
	assert_eq(auth.validate(hello, REMOTE_ADDRESS, 0, 0), NetProtocol.Result.OK,
			"Solmarch sí")
	hello.realm = NetProtocol.Realm.NONE
	assert_eq(auth.validate(hello, REMOTE_ADDRESS, 0, 0), NetProtocol.Result.REALM,
			"NONE se rechaza siempre")


func test_reject_name() -> void:
	var auth: ServerAuth = _make_auth()
	var bad_names: Array[String] = [
		"", "A", "ab", "x".repeat(25), "   ", " \t ", "Ana\nBruno", "Ana" + char(127),
		# 24 caracteres de 3 bytes: 72 B, más que los 48 B del formato.
		"€".repeat(24),
		# Reglas de NameRules (SOC-01): sin espacios ni dígitos ni signos, con mayúscula inicial,
		# 16 letras como máximo y sin reservados.
		"Ana B", "Jugador-0001", "Ana1", "ana", "Anabcdefghijklmnopq", "Admin", "ADMINISTRADOR",
		"Vardheim", "Capitán",
	]
	for display_name: String in bad_names:
		var hello: NetMessages.Hello = _make_hello()
		hello.display_name = display_name
		assert_eq(auth.validate(hello, REMOTE_ADDRESS, 0, 0), NetProtocol.Result.NAME,
				"nombre no válido: '%s'" % display_name.c_escape())


func test_name_length_boundaries() -> void:
	var auth: ServerAuth = _make_auth()
	var good_names: Array[String] = [
		"Ana", "A" + "x".repeat(15), "Ñandú", "Ñ" + "ñ".repeat(15), "Jugadorabcd", "Álvaro",
	]
	for display_name: String in good_names:
		var hello: NetMessages.Hello = _make_hello()
		hello.display_name = display_name
		assert_eq(auth.validate(hello, REMOTE_ADDRESS, 0, 0), NetProtocol.Result.OK,
				"nombre válido: '%s' (%d caracteres, %d B)" % [display_name, display_name.length(),
				display_name.to_utf8_buffer().size()])
	assert_true(ServerAuth.is_valid_name("Ñ" + "ñ".repeat(15)), "16 letras de 2 B: caben")
	assert_false(ServerAuth.is_valid_name("Ñ" + "ñ".repeat(16)), "17 letras no caben")
	assert_false(ServerAuth.is_valid_name("ab"), "dos letras no bastan")
	# El tope del protocolo (24 caracteres) sigue siendo el límite del cable, por encima de NameRules.
	assert_false(ServerAuth.is_valid_name("A" + "x".repeat(24)), "25 caracteres no caben en el HELLO")
	assert_eq(_make_auth().check_name("A" + "x".repeat(24)), NameRules.Reason.TOO_LONG,
			"y se informa como demasiado largo")


func test_check_name_reports_the_reason() -> void:
	var auth: ServerAuth = _make_auth()
	assert_eq(auth.check_name("Ana"), NameRules.Reason.OK, "válido")
	assert_eq(auth.check_name("Ana B"), NameRules.Reason.HAS_SPACE, "espacio")
	assert_eq(auth.check_name("Ana1"), NameRules.Reason.HAS_DIGIT, "dígito")
	assert_eq(auth.check_name("ana"), NameRules.Reason.NOT_CAPITALIZED, "minúscula")
	assert_eq(auth.check_name("Admin"), NameRules.Reason.RESERVED, "reservado")
	assert_eq(auth.check_name("ab"), NameRules.Reason.TOO_SHORT, "corto")


func test_duplicate_name_is_rejected() -> void:
	var auth: ServerAuth = _make_auth()
	var connected := PackedStringArray(["Álvaro", "Bruno"])
	auth.set_connected_names_source(func() -> PackedStringArray: return connected)
	var hello: NetMessages.Hello = _make_hello()
	hello.display_name = "Carla"
	assert_eq(auth.validate(hello, REMOTE_ADDRESS, 2, 0), NetProtocol.Result.OK,
			"un nombre libre entra")
	# Mismo nombre, y con las variantes de mayúsculas y tildes que lo harían ambiguo.
	for display_name: String in ["Álvaro", "Alvaro", "ALVARO", "ÁLVARO", "AlVaRo", "Bruno", "BRUNO"]:
		hello.display_name = display_name
		assert_eq(auth.validate(hello, REMOTE_ADDRESS, 2, 0), NetProtocol.Result.NAME,
				"'%s' ya está conectado" % display_name)
		assert_eq(auth.check_name(display_name), NameRules.Reason.TAKEN,
				"el motivo de '%s' es TAKEN" % display_name)
	hello.display_name = "Alvaro"
	assert_true(auth.is_name_connected("Alvaro"), "is_name_connected")
	assert_false(auth.is_name_connected("Carla"), "Carla no está")
	# Cuando el otro jugador se va, el nombre queda libre (la fuente se consulta en cada HELLO).
	connected.remove_at(0)
	assert_eq(auth.validate(hello, REMOTE_ADDRESS, 1, 0), NetProtocol.Result.OK,
			"libre tras irse el jugador")


func test_duplicate_name_is_checked_after_the_rules_and_before_the_cap() -> void:
	var auth: ServerAuth = _make_auth(null, PackedInt32Array(), _make_config(4, 2))
	auth.set_connected_names_source(func() -> PackedStringArray: return PackedStringArray(["Ana"]))
	var hello: NetMessages.Hello = _make_hello()
	hello.display_name = "Ana"
	# Un nombre repetido se informa antes que el servidor lleno (orden de la sección 3).
	assert_eq(auth.validate(hello, REMOTE_ADDRESS, 4, 0), NetProtocol.Result.NAME,
			"NAME antes que FULL")
	# Sin fuente de nombres no se comprueba nada.
	assert_eq(_make_auth().validate(hello, REMOTE_ADDRESS, 0, 0), NetProtocol.Result.OK,
			"sin fuente de nombres conectados")
	# Una fuente inválida (un Callable vacío) tampoco rompe nada.
	var no_source: ServerAuth = _make_auth()
	no_source.set_connected_names_source(Callable())
	assert_eq(no_source.validate(hello, REMOTE_ADDRESS, 0, 0), NetProtocol.Result.OK,
			"Callable vacío")


func test_reject_full() -> void:
	var auth: ServerAuth = _make_auth(null, PackedInt32Array(), _make_config(4, 2))
	assert_eq(auth.validate(_make_hello(), REMOTE_ADDRESS, 3, 0), NetProtocol.Result.OK,
			"con una plaza libre")
	assert_eq(auth.validate(_make_hello(), REMOTE_ADDRESS, 4, 0), NetProtocol.Result.FULL,
			"con tantos jugadores como plazas")
	assert_eq(auth.validate(_make_hello(), REMOTE_ADDRESS, 9, 0), NetProtocol.Result.FULL,
			"con más jugadores que plazas")
	assert_eq(auth.validate(_make_hello(), "127.0.0.1", 4, 0), NetProtocol.Result.FULL,
			"loopback tampoco se salta el cupo")


func test_reject_too_many_connections_from_address() -> void:
	var auth: ServerAuth = _make_auth(null, PackedInt32Array(), _make_config(64, 4))
	assert_eq(auth.validate(_make_hello(), REMOTE_ADDRESS, 0, 3), NetProtocol.Result.OK,
			"con 3 conexiones abiertas aún cabe la cuarta")
	assert_eq(auth.validate(_make_hello(), REMOTE_ADDRESS, 0, 4),
			NetProtocol.Result.TOO_MANY_CONNECTIONS, "con 4 abiertas ya no")
	assert_eq(auth.validate(_make_hello(), REMOTE_ADDRESS, 0, 50),
			NetProtocol.Result.TOO_MANY_CONNECTIONS, "ni con muchas más")
	assert_eq(auth.validate(_make_hello(), "2001:db8::1", 0, 4),
			NetProtocol.Result.TOO_MANY_CONNECTIONS, "también con IPv6")


func test_loopback_is_exempt_from_the_per_ip_limit() -> void:
	var auth: ServerAuth = _make_auth(null, PackedInt32Array(), _make_config(64, 4))
	for address: String in ["127.0.0.1", "::1", "localhost", "LOCALHOST", "127.0.0.2",
			"::ffff:127.0.0.1"]:
		assert_eq(auth.validate(_make_hello(), address, 0, 100), NetProtocol.Result.OK,
				"%s es loopback: sin tope por IP" % address)
	for address: String in ["10.0.0.1", "192.168.1.5", "128.0.0.1", "1127.0.0.1", ""]:
		assert_eq(auth.validate(_make_hello(), address, 0, 4),
				NetProtocol.Result.TOO_MANY_CONNECTIONS, "'%s' no es loopback" % address)
	assert_true(ServerAuth.is_loopback("127.0.0.1"), "is_loopback(127.0.0.1)")
	assert_true(ServerAuth.is_loopback("::1"), "is_loopback(::1)")
	assert_true(ServerAuth.is_loopback("localhost"), "is_loopback(localhost)")
	assert_false(ServerAuth.is_loopback("8.8.8.8"), "is_loopback(8.8.8.8)")


func test_reject_ticket_from_provider() -> void:
	var provider := CountingProvider.new()
	provider.result = NetProtocol.Result.TICKET
	var auth: ServerAuth = _make_auth(provider)
	assert_eq(auth.validate(_make_hello(), REMOTE_ADDRESS, 0, 0), NetProtocol.Result.TICKET,
			"el proveedor rechaza")
	assert_eq(provider.calls, 1, "se le ha preguntado una vez")

	assert_eq(_make_auth(AuthProvider.new()).validate(_make_hello(), REMOTE_ADDRESS, 0, 0),
			NetProtocol.Result.TICKET, "el proveedor base no deja pasar a nadie")
	assert_eq(ServerAuth.new(_make_config(), SIM_HASH, PackedInt32Array(), null).validate(
			_make_hello(), REMOTE_ADDRESS, 0, 0), NetProtocol.Result.TICKET,
			"sin proveedor tampoco")


func test_dev_auth_provider_accepts_declared_identity() -> void:
	var provider := DevAuthProvider.new()
	assert_eq(provider.authenticate(_make_hello()), NetProtocol.Result.OK,
			"acepta el reino y el nombre que declara el cliente")
	assert_eq(AuthProvider.new().authenticate(_make_hello()), NetProtocol.Result.TICKET,
			"la base no autentica")


func test_provider_is_asked_last_and_only_when_everything_else_passes() -> void:
	var provider := CountingProvider.new()
	var auth: ServerAuth = _make_auth(provider, PackedInt32Array(), _make_config(4, 2))

	var bad_version: NetMessages.Hello = _make_hello()
	bad_version.protocol_version = 99
	auth.validate(bad_version, REMOTE_ADDRESS, 0, 0)
	var bad_hash: NetMessages.Hello = _make_hello()
	bad_hash.sim_hash = 1
	auth.validate(bad_hash, REMOTE_ADDRESS, 0, 0)
	var bad_realm: NetMessages.Hello = _make_hello()
	bad_realm.realm = 0
	auth.validate(bad_realm, REMOTE_ADDRESS, 0, 0)
	var bad_name: NetMessages.Hello = _make_hello()
	bad_name.display_name = "x"
	auth.validate(bad_name, REMOTE_ADDRESS, 0, 0)
	auth.validate(_make_hello(), REMOTE_ADDRESS, 4, 0)
	auth.validate(_make_hello(), REMOTE_ADDRESS, 0, 2)
	assert_eq(provider.calls, 0, "ningún rechazo previo llega al proveedor")

	assert_eq(auth.validate(_make_hello(), REMOTE_ADDRESS, 0, 0), NetProtocol.Result.OK,
			"y con todo en regla sí")
	assert_eq(provider.calls, 1, "el proveedor decide al final")


func test_checks_run_in_the_documented_order() -> void:
	var auth: ServerAuth = _make_auth(null, PackedInt32Array(), _make_config(4, 2))
	var hello: NetMessages.Hello = _make_hello()
	# Todo mal a la vez: se informa del primer fallo, en el orden de la sección 3.
	hello.protocol_version = 99
	hello.sim_hash = 1
	hello.realm = 0
	hello.display_name = "x"
	assert_eq(auth.validate(hello, REMOTE_ADDRESS, 4, 2), NetProtocol.Result.VERSION, "versión")
	hello.protocol_version = NetProtocol.PROTOCOL_VERSION
	assert_eq(auth.validate(hello, REMOTE_ADDRESS, 4, 2), NetProtocol.Result.SIM_HASH, "huella")
	hello.sim_hash = SIM_HASH
	assert_eq(auth.validate(hello, REMOTE_ADDRESS, 4, 2), NetProtocol.Result.REALM, "reino")
	hello.realm = NetProtocol.Realm.SOLMARCH
	assert_eq(auth.validate(hello, REMOTE_ADDRESS, 4, 2), NetProtocol.Result.NAME, "nombre")
	hello.display_name = "Bruno"
	assert_eq(auth.validate(hello, REMOTE_ADDRESS, 4, 2), NetProtocol.Result.FULL, "cupo")
	assert_eq(auth.validate(hello, REMOTE_ADDRESS, 0, 2), NetProtocol.Result.TOO_MANY_CONNECTIONS,
			"conexiones por IP")
	assert_eq(auth.validate(hello, REMOTE_ADDRESS, 0, 1), NetProtocol.Result.OK, "todo en regla")


func test_every_reject_reason_has_a_spanish_text() -> void:
	# Cada motivo que ServerAuth puede devolver tiene su texto para el REJECT.
	for result: int in [NetProtocol.Result.VERSION, NetProtocol.Result.SIM_HASH,
			NetProtocol.Result.REALM, NetProtocol.Result.FULL, NetProtocol.Result.TICKET,
			NetProtocol.Result.MALFORMED, NetProtocol.Result.TOO_MANY_CONNECTIONS,
			NetProtocol.Result.NAME]:
		var text: String = NetProtocol.result_text(result)
		assert_false(text.is_empty(), "texto del motivo %d" % result)
		assert_false(text == NetProtocol.result_text(-1),
				"el motivo %d tiene un texto propio" % result)
