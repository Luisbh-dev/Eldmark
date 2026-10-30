extends TestCase
## [ZoneDtls] (docs/plataforma.md §10.2, P9c): el certificado y la clave DTLS de la zona. Lee el CN del DER (el
## [X509Certificate] de Godot no lo da), comprueba que la clave es la del certificado y no deja pasar un PEM roto sin
## un motivo claro (ni con errores del motor). Además, el registro con el certificado y su nombre, la salida con código
## 1 de un servidor con un certificado que no vale y la comparación de [code]tools/load_test.gd --dtls-compare[/code].
## [br][br]
## Los PEM de [code]tests/fixtures/dtls/[/code] se hicieron con OpenSSL 3.0 (válidos 100 años): [code]zone_*[/code],
## RSA 2048 con CN y subjectAltName [code]zona-pruebas.eldmark.test[/code]; [code]other_*[/code], EC P-256 con el CN
## delante de la organización; [code]no_cn_cert.pem[/code], la clave de [code]zone_key.pem[/code] sin CN.

const DIR: String = "res://tests/fixtures/dtls/"
const ZONE_CERT: String = DIR + "zone_cert.pem"
const ZONE_KEY: String = DIR + "zone_key.pem"
const OTHER_CERT: String = DIR + "other_cert.pem"
const OTHER_KEY: String = DIR + "other_key.pem"
const NO_CN_CERT: String = DIR + "no_cn_cert.pem"
const ZONE_NAME: String = "zona-pruebas.eldmark.test"
const LoadTestScript = preload("res://tools/load_test.gd")
const MAX_WAIT_SECONDS: float = 25.0

var _pids: Array[int] = []


func after_each() -> void:
	for pid: int in _pids:
		if OS.is_process_running(pid):
			OS.kill(pid)
	_pids.clear()


func _text(path: String) -> String:
	return FileAccess.get_file_as_string(path)


# --- Certificado y clave ------------------------------------------------------------------------

func test_the_name_is_the_cn_of_the_certificate_and_the_key_is_its_own() -> void:
	var dtls: ZoneDtls = ZoneDtls.load_files(ZONE_CERT, ZONE_KEY)
	assert_eq(dtls.error, "", "el certificado de las pruebas vale")
	assert_true(dtls.is_valid())
	assert_eq(dtls.common_name, ZONE_NAME, "el CN del sujeto")
	assert_eq(dtls.certificate_pem, _text(ZONE_CERT), "el PEM tal cual, para el registro")
	assert_not_null(dtls.server_options, "las opciones del servidor para NetTransport.host")


func test_an_ec_certificate_with_the_cn_first_also_gives_its_name() -> void:
	var dtls: ZoneDtls = ZoneDtls.from_pem(_text(OTHER_CERT), _text(OTHER_KEY))
	assert_eq(dtls.error, "", "EC P-256 vale")
	assert_eq(dtls.common_name, "otra-zona.eldmark.test", "el CN aunque vaya antes que la organización")


func test_a_key_that_is_not_the_certificates_does_not_load() -> void:
	for pair: Array in [[ZONE_CERT, OTHER_KEY], [OTHER_CERT, ZONE_KEY]]:
		var dtls: ZoneDtls = ZoneDtls.load_files(pair[0], pair[1])
		assert_false(dtls.is_valid(), "%s con %s no vale" % [pair[0].get_file(), pair[1].get_file()])
		assert_eq(dtls.error, "La clave DTLS no es la del certificado")
		assert_null(dtls.server_options)


func test_a_certificate_without_cn_does_not_load() -> void:
	var dtls: ZoneDtls = ZoneDtls.load_files(NO_CN_CERT, ZONE_KEY)
	assert_false(dtls.is_valid())
	assert_true(dtls.error.contains("no tiene CN"), dtls.error)


func test_missing_or_broken_files_give_a_reason_without_engine_errors() -> void:
	var cases: Array[Array] = [
		[ZoneDtls.load_files(ZONE_CERT, ""), "a la vez"],
		[ZoneDtls.load_files("", ZONE_KEY), "a la vez"],
		[ZoneDtls.load_files(DIR + "no_existe.pem", ZONE_KEY), "No existe el certificado"],
		[ZoneDtls.load_files(ZONE_CERT, DIR + "no_existe.pem"), "No existe la clave"],
		[ZoneDtls.from_pem("hola", _text(ZONE_KEY)), "no es un PEM válido"],
		[ZoneDtls.from_pem("-----BEGIN CERTIFICATE-----\n¿no?es*base64\n-----END CERTIFICATE-----\n", _text(ZONE_KEY)),
				"no es un PEM válido"],
		[ZoneDtls.from_pem("-----BEGIN CERTIFICATE-----\nAAECAwQF\n-----END CERTIFICATE-----\n", _text(ZONE_KEY)),
				"No se entiende"],
		[ZoneDtls.from_pem(_text(ZONE_CERT), "hola"), "clave privada"],
		[ZoneDtls.from_pem(_text(ZONE_CERT), _text(ZONE_CERT)), "clave privada"],
	]
	for entry: Array in cases:
		var dtls: ZoneDtls = entry[0]
		assert_false(dtls.is_valid(), "no vale: %s" % entry[1])
		assert_true(dtls.error.contains(String(entry[1])), "«%s» dice «%s»" % [dtls.error, entry[1]])


func test_a_truncated_or_altered_der_never_breaks_the_reader() -> void:
	var der: PackedByteArray = ZoneDtls.pem_blocks(_text(ZONE_CERT), "CERTIFICATE")[0]
	var full: Dictionary = ZoneDtls.certificate_fields(der)
	assert_eq(full["common_name"], ZONE_NAME)
	assert_eq((full["public_key"] as PackedByteArray)[0], 0x30, "la subjectPublicKeyInfo es una SEQUENCE")
	# Cortado por cualquier sitio: nunca da otro nombre ni falla con un error.
	for length: int in range(0, der.size(), 7):
		var fields: Dictionary = ZoneDtls.certificate_fields(der.slice(0, length))
		assert_true(fields.is_empty(), "cortado a %d B no se entiende" % length)
	# Con una longitud que se sale del certificado.
	var altered: PackedByteArray = der.duplicate()
	altered[1] = 0x84
	assert_true(ZoneDtls.certificate_fields(altered).is_empty(), "longitud imposible")
	assert_true(ZoneDtls.certificate_fields(PackedByteArray()).is_empty(), "vacío")


func test_pem_blocks_skips_bad_base64_and_reads_every_block() -> void:
	var two: String = _text(ZONE_CERT) + "\n" + _text(OTHER_CERT)
	assert_eq(ZoneDtls.pem_blocks(two, "CERTIFICATE").size(), 2, "una cadena de dos certificados")
	var chain: ZoneDtls = ZoneDtls.from_pem(two, _text(ZONE_KEY))
	assert_eq(chain.common_name, ZONE_NAME, "el nombre y la clave son los del primero de la cadena")
	assert_eq(ZoneDtls.pem_blocks("-----BEGIN CERTIFICATE-----\nAB=C\n-----END CERTIFICATE-----", "CERTIFICATE").size(),
			0, "relleno en medio")
	assert_eq(ZoneDtls.pem_blocks("-----BEGIN CERTIFICATE-----\nABC\n-----END CERTIFICATE-----", "CERTIFICATE").size(),
			0, "longitud que no es múltiplo de 4")


# --- Registro ----------------------------------------------------------------------------------

func test_the_registration_sends_the_certificate_and_its_name() -> void:
	var config := ServerConfig.from_args(PackedStringArray(["--zone=test_world", "--dtls-cert=%s" % ZONE_CERT,
			"--dtls-key=%s" % ZONE_KEY]))
	assert_eq(config.dtls_cert_path, ZONE_CERT, "--dtls-cert")
	assert_eq(config.dtls_key_path, ZONE_KEY, "--dtls-key")
	assert_null(config.dtls, "los argumentos no cargan nada: lo hace ServerMain")
	var plain: Dictionary = ZonePlatform.registration_body(config)
	assert_null(plain["dtls_cert_pem"], "sin DTLS cargado, null")
	assert_null(plain["dtls_name"])
	config.dtls = ZoneDtls.load_files(config.dtls_cert_path, config.dtls_key_path)
	var body: Dictionary = ZonePlatform.registration_body(config)
	assert_eq(body["dtls_cert_pem"], _text(ZONE_CERT), "el PEM del certificado")
	assert_eq(body["dtls_name"], ZONE_NAME, "su CN")
	# Ida y vuelta por JSON, como lo manda PlatformClient.
	var json := JSON.new()
	assert_eq(json.parse(JSON.stringify(body)), OK)
	assert_eq((json.data as Dictionary)["dtls_name"], ZONE_NAME)


# --- ServerMain ---------------------------------------------------------------------------------

func test_a_server_with_a_certificate_that_does_not_work_exits_with_one() -> void:
	var cases: Array[Array] = [
		[["--dtls-cert=%s" % ProjectSettings.globalize_path(ZONE_CERT)], "a la vez"],
		[["--dtls-cert=%s" % ProjectSettings.globalize_path(ZONE_CERT),
				"--dtls-key=%s" % ProjectSettings.globalize_path(OTHER_KEY)], "no es la del certificado"],
	]
	var pids: Array[int] = []
	var logs: Array[String] = []
	for i: int in cases.size():
		var log_path: String = NetHarness.build_path("test_zone_dtls_bad_%d.log" % i)
		DirAccess.remove_absolute(log_path)
		var args := PackedStringArray(["--server", "--zone=test_world", "--port=%d" % NetHarness.free_udp_port(),
				"--quit-after-ticks=600"])
		args.append_array(PackedStringArray(cases[i][0]))
		var pid: int = OS.create_process(OS.get_executable_path(), PackedStringArray(["--headless", "--path",
				ProjectSettings.globalize_path("res://"), "--log-file", log_path, "--"]) + args)
		_pids.append(pid)
		pids.append(pid)
		logs.append(log_path)
	for i: int in cases.size():
		if not assert_true(await _wait_for_exit(pids[i]), "el servidor %d sale solo" % i):
			continue
		assert_eq(OS.get_process_exit_code(pids[i]), 1, "código 1 (%s)" % cases[i][1])
		var text: String = FileAccess.get_file_as_string(logs[i])
		assert_true(text.contains(String(cases[i][1])), "el registro dice por qué (%s)" % cases[i][1])
		assert_false(text.contains("escuchando en el puerto"), "no abre el puerto")


func _wait_for_exit(pid: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(MAX_WAIT_SECONDS * 1000.0)
	while OS.is_process_running(pid):
		if Time.get_ticks_msec() > deadline:
			return false
		await tree.create_timer(0.1).timeout
	return true


# --- tools/load_test.gd --dtls-compare -----------------------------------------------------------

func _summary(dtls: bool, tick_p99: int, net_p50: int) -> Dictionary:
	var sections: Dictionary = {}
	for section: String in ["tick", "net", "flush"]:
		sections[section] = {"p50": net_p50 if section == "net" else 1000, "p95": 0,
				"p99": tick_p99 if section == "tick" else 2000, "max": 0}
	return {"ok": true, "tag": "cluster_0f_64b%s" % ("_dtls" if dtls else ""), "run": {"dtls": dtls},
			"sections_us": sections, "server_kb_in_per_s": 400.0, "server_kb_out_per_s": 2300.0,
			"client_kb_down_per_s_avg": 36.0, "players_peak": 64}


func test_the_dtls_comparison_averages_each_side_and_applies_the_ten_percent() -> void:
	var summaries: Array[Dictionary] = [_summary(false, 10000, 900), _summary(true, 10500, 1100),
			_summary(false, 12000, 1100), _summary(true, 12700, 1300)]
	var comparison: Dictionary = LoadTestScript.dtls_comparison(summaries)
	assert_eq(comparison["plain_runs"], 2)
	assert_eq(comparison["dtls_runs"], 2)
	var tick: Dictionary = (comparison["figures"] as Dictionary)["tick_p99_us"]
	assert_near(float(tick["plain"]), 11000.0, 0.01, "media sin DTLS")
	assert_near(float(tick["dtls"]), 11600.0, 0.01, "media con DTLS")
	assert_near(float(comparison["tick_p99_rise"]), 600.0 / 11000.0, 1e-6, "sube un 5,5 %")
	assert_true(bool(comparison["criterion_met"]), "por debajo del 10 %")
	assert_near(float(((comparison["figures"] as Dictionary)["net_p50_us"] as Dictionary)["rise"]), 0.2, 1e-6,
			"la sección net sube un 20 %")
	assert_eq((comparison["passes"] as Array).size(), 4, "las cuatro pasadas, para ver el ruido")
	summaries.append(_summary(true, 20000, 1500))
	assert_false(bool(LoadTestScript.dtls_comparison(summaries)["criterion_met"]), "una pasada mucho peor lo rompe")
	var only_plain: Array[Dictionary] = [_summary(false, 10000, 900)]
	var missing: Dictionary = LoadTestScript.dtls_comparison(only_plain)
	assert_false(bool(missing["criterion_met"]), "sin pasadas con DTLS no hay criterio")
	assert_true(missing.has("error"))


func test_the_load_test_passes_the_certificate_to_the_server_and_the_swarms() -> void:
	var run: Dictionary = {"dtls_cert": "/c.pem", "dtls_key": "/k.pem", "dtls_name": ZONE_NAME}
	assert_eq(LoadTestScript.dtls_server_args(run), PackedStringArray(["--dtls-cert=/c.pem", "--dtls-key=/k.pem"]))
	assert_eq(LoadTestScript.dtls_swarm_args(run), PackedStringArray(["--dtls-cert=/c.pem",
			"--dtls-name=%s" % ZONE_NAME]))
	assert_true(FileAccess.file_exists(LoadTestScript.DTLS_TEST_CERT), "el certificado por defecto existe")
	assert_true(FileAccess.file_exists(LoadTestScript.DTLS_TEST_KEY), "la clave por defecto existe")
	var dtls: ZoneDtls = ZoneDtls.load_files(LoadTestScript.DTLS_TEST_CERT, LoadTestScript.DTLS_TEST_KEY)
	assert_eq(dtls.common_name, LoadTestScript.DTLS_TEST_NAME, "el nombre por defecto es el CN del certificado")
