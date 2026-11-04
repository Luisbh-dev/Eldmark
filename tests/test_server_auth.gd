extends TestCase
## Tests for HELLO validation ([ServerAuth]): each REJECT reason, the order of the
## checks, the per-IP connection cap with the loopback exception and the
## [AuthProvider] (docs/networking.md, sections 3 and 12).

const SIM_HASH: int = 0xA1B2C3D4
const REMOTE_ADDRESS: String = "203.0.113.7"
const PEER_ID: int = 7


## Test provider: counts the calls and returns whatever it is asked to.
class CountingProvider extends AuthProvider:
	var calls: int = 0
	var result: int = NetProtocol.Result.OK


	var tickets: bool = false
	var last_peer_id: int = 0


	func authenticate(peer_id: int, _hello: NetMessages.Hello) -> int:
		calls += 1
		last_peer_id = peer_id
		return result


	func uses_tickets() -> bool:
		return tickets


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
	assert_eq(auth.validate(PEER_ID, _make_hello(), REMOTE_ADDRESS, 0, 0), NetProtocol.Result.OK,
			"a correct HELLO")
	# And also if it goes over the wire.
	var decoded: NetMessages.Hello = NetMessages.Hello.decode(_make_hello().encode())
	if assert_not_null(decoded, "the HELLO is decoded"):
		assert_eq(auth.validate(PEER_ID, decoded, REMOTE_ADDRESS, 0, 0), NetProtocol.Result.OK,
				"a decoded HELLO")


func test_malformed_hello_is_rejected() -> void:
	assert_eq(_make_auth().validate(PEER_ID, null, REMOTE_ADDRESS, 0, 0), NetProtocol.Result.MALFORMED,
			"no HELLO (decode returned null)")


func test_reject_version() -> void:
	var hello: NetMessages.Hello = _make_hello()
	hello.protocol_version = NetProtocol.PROTOCOL_VERSION + 1
	assert_eq(_make_auth().validate(PEER_ID, hello, REMOTE_ADDRESS, 0, 0), NetProtocol.Result.VERSION,
			"newer version")
	hello.protocol_version = 0
	assert_eq(_make_auth().validate(PEER_ID, hello, REMOTE_ADDRESS, 0, 0), NetProtocol.Result.VERSION,
			"version 0")


func test_reject_sim_hash() -> void:
	var hello: NetMessages.Hello = _make_hello()
	hello.sim_hash = SIM_HASH ^ 1
	assert_eq(_make_auth().validate(PEER_ID, hello, REMOTE_ADDRESS, 0, 0), NetProtocol.Result.SIM_HASH,
			"different fingerprint")


func test_reject_realm_none_and_out_of_range() -> void:
	var auth: ServerAuth = _make_auth()
	for realm: int in [NetProtocol.Realm.NONE, 4, 5, 200, 255]:
		var hello: NetMessages.Hello = _make_hello()
		hello.realm = realm
		assert_eq(auth.validate(PEER_ID, hello, REMOTE_ADDRESS, 0, 0), NetProtocol.Result.REALM,
				"realm %d is not valid" % realm)


func test_every_real_realm_is_accepted_when_allowed_is_empty() -> void:
	var auth: ServerAuth = _make_auth()
	for realm: int in [NetProtocol.Realm.VARDHEIM, NetProtocol.Realm.SOLMARCH,
			NetProtocol.Realm.ASKARRA]:
		var hello: NetMessages.Hello = _make_hello()
		hello.realm = realm
		assert_eq(auth.validate(PEER_ID, hello, REMOTE_ADDRESS, 0, 0), NetProtocol.Result.OK,
				"realm %d is admitted if the zone does not restrict" % realm)


func test_reject_realm_not_allowed_in_zone() -> void:
	var allowed := PackedInt32Array([NetProtocol.Realm.VARDHEIM, NetProtocol.Realm.SOLMARCH])
	var auth: ServerAuth = _make_auth(null, allowed)
	var hello: NetMessages.Hello = _make_hello()
	hello.realm = NetProtocol.Realm.ASKARRA
	assert_eq(auth.validate(PEER_ID, hello, REMOTE_ADDRESS, 0, 0), NetProtocol.Result.REALM,
			"Askarra is not admitted in the zone")
	hello.realm = NetProtocol.Realm.SOLMARCH
	assert_eq(auth.validate(PEER_ID, hello, REMOTE_ADDRESS, 0, 0), NetProtocol.Result.OK,
			"Solmarch is")
	hello.realm = NetProtocol.Realm.NONE
	assert_eq(auth.validate(PEER_ID, hello, REMOTE_ADDRESS, 0, 0), NetProtocol.Result.REALM,
			"NONE is always rejected")


func test_reject_name() -> void:
	var auth: ServerAuth = _make_auth()
	var bad_names: Array[String] = [
		"", "A", "ab", "x".repeat(25), "   ", " \t ", "Ana\nBruno", "Ana" + char(127),
		# 24 characters of 3 bytes: 72 B, more than the format's 48 B.
		"€".repeat(24),
		# NameRules rules (SOC-01): no spaces, digits or symbols, with an initial capital,
		# 16 letters at most and no reserved names.
		"Ana B", "Jugador-0001", "Ana1", "ana", "Anabcdefghijklmnopq", "Admin", "ADMINISTRADOR",
		"Vardheim", "Capitán",
	]
	for display_name: String in bad_names:
		var hello: NetMessages.Hello = _make_hello()
		hello.display_name = display_name
		assert_eq(auth.validate(PEER_ID, hello, REMOTE_ADDRESS, 0, 0), NetProtocol.Result.NAME,
				"invalid name: '%s'" % display_name.c_escape())


func test_name_length_boundaries() -> void:
	var auth: ServerAuth = _make_auth()
	var good_names: Array[String] = [
		"Ana", "A" + "x".repeat(15), "Ñandú", "Ñ" + "ñ".repeat(15), "Jugadorabcd", "Álvaro",
	]
	for display_name: String in good_names:
		var hello: NetMessages.Hello = _make_hello()
		hello.display_name = display_name
		assert_eq(auth.validate(PEER_ID, hello, REMOTE_ADDRESS, 0, 0), NetProtocol.Result.OK,
				"valid name: '%s' (%d characters, %d B)" % [display_name, display_name.length(),
				display_name.to_utf8_buffer().size()])
	assert_true(ServerAuth.is_valid_name("Ñ" + "ñ".repeat(15)), "16 letters of 2 B: they fit")
	assert_false(ServerAuth.is_valid_name("Ñ" + "ñ".repeat(16)), "17 letters do not fit")
	assert_false(ServerAuth.is_valid_name("ab"), "two letters are not enough")
	# The protocol cap (24 characters) remains the wire limit, above NameRules.
	assert_false(ServerAuth.is_valid_name("A" + "x".repeat(24)), "25 characters do not fit in the HELLO")
	assert_eq(_make_auth().check_name("A" + "x".repeat(24)), NameRules.Reason.TOO_LONG,
			"and it is reported as too long")


func test_check_name_reports_the_reason() -> void:
	var auth: ServerAuth = _make_auth()
	assert_eq(auth.check_name("Ana"), NameRules.Reason.OK, "valid")
	assert_eq(auth.check_name("Ana B"), NameRules.Reason.HAS_SPACE, "space")
	assert_eq(auth.check_name("Ana1"), NameRules.Reason.HAS_DIGIT, "digit")
	assert_eq(auth.check_name("ana"), NameRules.Reason.NOT_CAPITALIZED, "lowercase")
	assert_eq(auth.check_name("Admin"), NameRules.Reason.RESERVED, "reserved")
	assert_eq(auth.check_name("ab"), NameRules.Reason.TOO_SHORT, "short")


func test_duplicate_name_is_rejected() -> void:
	var auth: ServerAuth = _make_auth()
	var connected := PackedStringArray(["Álvaro", "Bruno"])
	auth.set_connected_names_source(func() -> PackedStringArray: return connected)
	var hello: NetMessages.Hello = _make_hello()
	hello.display_name = "Carla"
	assert_eq(auth.validate(PEER_ID, hello, REMOTE_ADDRESS, 2, 0), NetProtocol.Result.OK,
			"a free name gets in")
	# Same name, and with the uppercase and accent variants that would make it ambiguous.
	for display_name: String in ["Álvaro", "Alvaro", "ALVARO", "ÁLVARO", "AlVaRo", "Bruno", "BRUNO"]:
		hello.display_name = display_name
		assert_eq(auth.validate(PEER_ID, hello, REMOTE_ADDRESS, 2, 0), NetProtocol.Result.NAME,
				"'%s' is already connected" % display_name)
		assert_eq(auth.check_name(display_name), NameRules.Reason.TAKEN,
				"the reason for '%s' is TAKEN" % display_name)
	hello.display_name = "Alvaro"
	assert_true(auth.is_name_connected("Alvaro"), "is_name_connected")
	assert_false(auth.is_name_connected("Carla"), "Carla is not there")
	# When the other player leaves, the name becomes free (the source is queried on every HELLO).
	connected.remove_at(0)
	assert_eq(auth.validate(PEER_ID, hello, REMOTE_ADDRESS, 1, 0), NetProtocol.Result.OK,
			"free after the player leaves")


func test_duplicate_name_is_checked_after_the_rules_and_before_the_cap() -> void:
	var auth: ServerAuth = _make_auth(null, PackedInt32Array(), _make_config(4, 2))
	auth.set_connected_names_source(func() -> PackedStringArray: return PackedStringArray(["Ana"]))
	var hello: NetMessages.Hello = _make_hello()
	hello.display_name = "Ana"
	# A repeated name is reported before a full server (order of section 3).
	assert_eq(auth.validate(PEER_ID, hello, REMOTE_ADDRESS, 4, 0), NetProtocol.Result.NAME,
			"NAME before FULL")
	# Without a name source nothing is checked.
	assert_eq(_make_auth().validate(PEER_ID, hello, REMOTE_ADDRESS, 0, 0), NetProtocol.Result.OK,
			"without a source of connected names")
	# An invalid source (an empty Callable) does not break anything either.
	var no_source: ServerAuth = _make_auth()
	no_source.set_connected_names_source(Callable())
	assert_eq(no_source.validate(PEER_ID, hello, REMOTE_ADDRESS, 0, 0), NetProtocol.Result.OK,
			"empty Callable")


func test_reject_full() -> void:
	var auth: ServerAuth = _make_auth(null, PackedInt32Array(), _make_config(4, 2))
	assert_eq(auth.validate(PEER_ID, _make_hello(), REMOTE_ADDRESS, 3, 0), NetProtocol.Result.OK,
			"with one free slot")
	assert_eq(auth.validate(PEER_ID, _make_hello(), REMOTE_ADDRESS, 4, 0), NetProtocol.Result.FULL,
			"with as many players as slots")
	assert_eq(auth.validate(PEER_ID, _make_hello(), REMOTE_ADDRESS, 9, 0), NetProtocol.Result.FULL,
			"with more players than slots")
	assert_eq(auth.validate(PEER_ID, _make_hello(), "127.0.0.1", 4, 0), NetProtocol.Result.FULL,
			"loopback does not skip the cap either")


func test_filler_fakes_do_not_make_the_server_full() -> void:
	# GUE-43: the --max-realm-diff filler fake players do not take human slots.
	var auth: ServerAuth = _make_auth(null, PackedInt32Array(), _make_config(4, 2))
	assert_eq(auth.validate(PEER_ID, _make_hello(), REMOTE_ADDRESS, 4, 0, 4), NetProtocol.Result.OK,
			"full only of filler: it gets in (and the caller removes one)")
	assert_eq(auth.validate(PEER_ID, _make_hello(), REMOTE_ADDRESS, 4, 0, 1), NetProtocol.Result.OK,
			"three real slots and one filler: it gets in")
	assert_eq(auth.validate(PEER_ID, _make_hello(), REMOTE_ADDRESS, 5, 0, 1), NetProtocol.Result.FULL,
			"with four non-filler there is no slot even if a filler fake player remains")
	assert_eq(auth.validate(PEER_ID, _make_hello(), REMOTE_ADDRESS, 4, 0, 0), NetProtocol.Result.FULL,
			"without filler, the usual cap (non-filler fake players do count)")
	assert_eq(auth.validate(PEER_ID, _make_hello(), REMOTE_ADDRESS, 2, 0, 9), NetProtocol.Result.OK,
			"a filler count greater than the player count gives no extra slots")
	var hello: NetMessages.Hello = _make_hello()
	hello.display_name = "x"
	assert_eq(auth.validate(PEER_ID, hello, REMOTE_ADDRESS, 4, 0, 4), NetProtocol.Result.NAME,
			"the filler does not skip the other checks")
	assert_eq(auth.validate(PEER_ID, _make_hello(), REMOTE_ADDRESS, 4, 2, 4), NetProtocol.Result.TOO_MANY_CONNECTIONS,
			"nor the per-IP cap")


func test_reject_too_many_connections_from_address() -> void:
	var auth: ServerAuth = _make_auth(null, PackedInt32Array(), _make_config(64, 4))
	assert_eq(auth.validate(PEER_ID, _make_hello(), REMOTE_ADDRESS, 0, 3), NetProtocol.Result.OK,
			"with 3 open connections a fourth still fits")
	assert_eq(auth.validate(PEER_ID, _make_hello(), REMOTE_ADDRESS, 0, 4),
			NetProtocol.Result.TOO_MANY_CONNECTIONS, "with 4 open it no longer does")
	assert_eq(auth.validate(PEER_ID, _make_hello(), REMOTE_ADDRESS, 0, 50),
			NetProtocol.Result.TOO_MANY_CONNECTIONS, "nor with many more")
	assert_eq(auth.validate(PEER_ID, _make_hello(), "2001:db8::1", 0, 4),
			NetProtocol.Result.TOO_MANY_CONNECTIONS, "also with IPv6")


func test_loopback_is_exempt_from_the_per_ip_limit() -> void:
	var auth: ServerAuth = _make_auth(null, PackedInt32Array(), _make_config(64, 4))
	for address: String in ["127.0.0.1", "::1", "localhost", "LOCALHOST", "127.0.0.2",
			"::ffff:127.0.0.1"]:
		assert_eq(auth.validate(PEER_ID, _make_hello(), address, 0, 100), NetProtocol.Result.OK,
				"%s is loopback: no per-IP cap" % address)
	for address: String in ["10.0.0.1", "192.168.1.5", "128.0.0.1", "1127.0.0.1", ""]:
		assert_eq(auth.validate(PEER_ID, _make_hello(), address, 0, 4),
				NetProtocol.Result.TOO_MANY_CONNECTIONS, "'%s' is not loopback" % address)
	assert_true(ServerAuth.is_loopback("127.0.0.1"), "is_loopback(127.0.0.1)")
	assert_true(ServerAuth.is_loopback("::1"), "is_loopback(::1)")
	assert_true(ServerAuth.is_loopback("localhost"), "is_loopback(localhost)")
	assert_false(ServerAuth.is_loopback("8.8.8.8"), "is_loopback(8.8.8.8)")


## The per-IP cap counts IPv6 addresses by /64 prefix: each address in a /64 is another IP
## for the attacker, who usually has a whole /64 (finding S2).
func test_address_group_counts_ipv6_by_slash_64() -> void:
	assert_eq(ServerAuth.address_group("203.0.113.7"), "203.0.113.7", "IPv4 as is")
	assert_eq(ServerAuth.address_group("::ffff:203.0.113.7"), "203.0.113.7",
			"IPv4 mapped into IPv6 = its IPv4")
	var a: String = ServerAuth.address_group("2001:db8:1:2:aaaa:bbbb:cccc:dddd")
	assert_eq(a, ServerAuth.address_group("2001:0DB8:0001:0002::1"), "same /64, different form")
	assert_eq(a, ServerAuth.address_group("2001:db8:1:2::"), "and with the tail compressed")
	assert_eq(a, ServerAuth.address_group("2001:db8:1:2:ffff:ffff:ffff:ffff"), "and another address")
	assert_true(a != ServerAuth.address_group("2001:db8:1:3::1"), "another /64")
	assert_true(a != ServerAuth.address_group("2001:db8:2:2::1"), "another /64 (third group)")
	assert_eq(ServerAuth.address_group("2001:db8::5"), ServerAuth.address_group("2001:db8:0:0::9"),
			"the :: compression in the middle is expanded")
	assert_eq(ServerAuth.address_group("fe80::1%eth0"), ServerAuth.address_group("fe80::2"),
			"the scope zone does not count")
	assert_eq(ServerAuth.address_group(""), "", "without an address, empty")
	assert_eq(ServerAuth.address_group("no-es-una-ip"), "no-es-una-ip", "what is not understood, as is")
	assert_eq(ServerAuth.address_group("1:2:3:4:5:6:7:8:9"), "1:2:3:4:5:6:7:8:9", "too many groups")
	assert_eq(ServerAuth.address_group("1::2::3"), "1::2::3", "two compressions")


func test_reject_ticket_from_provider() -> void:
	var provider := CountingProvider.new()
	provider.result = NetProtocol.Result.TICKET
	var auth: ServerAuth = _make_auth(provider)
	assert_eq(auth.validate(PEER_ID, _make_hello(), REMOTE_ADDRESS, 0, 0), NetProtocol.Result.TICKET,
			"the provider rejects")
	assert_eq(provider.calls, 1, "it has been asked once")

	assert_eq(_make_auth(AuthProvider.new()).validate(PEER_ID, _make_hello(), REMOTE_ADDRESS, 0, 0),
			NetProtocol.Result.TICKET, "the base provider lets nobody through")
	assert_eq(ServerAuth.new(_make_config(), SIM_HASH, PackedInt32Array(), null).validate(PEER_ID,
			_make_hello(), REMOTE_ADDRESS, 0, 0), NetProtocol.Result.TICKET,
			"without a provider neither")


func test_dev_auth_provider_accepts_declared_identity() -> void:
	var provider := DevAuthProvider.new()
	assert_eq(provider.authenticate(PEER_ID, _make_hello()), NetProtocol.Result.OK,
			"accepts the realm and name the client declares")
	assert_false(provider.uses_tickets(), "without tickets")
	assert_false(provider.on_platform_event(PlatformEvent.new()), "does not handle platform events")
	assert_true(provider.take_completed().is_empty(), "never leaves anything pending")
	assert_eq(AuthProvider.new().authenticate(PEER_ID, _make_hello()), NetProtocol.Result.TICKET,
			"the base does not authenticate")


func test_provider_is_asked_last_and_only_when_everything_else_passes() -> void:
	var provider := CountingProvider.new()
	var auth: ServerAuth = _make_auth(provider, PackedInt32Array(), _make_config(4, 2))

	var bad_version: NetMessages.Hello = _make_hello()
	bad_version.protocol_version = 99
	auth.validate(PEER_ID, bad_version, REMOTE_ADDRESS, 0, 0)
	var bad_hash: NetMessages.Hello = _make_hello()
	bad_hash.sim_hash = 1
	auth.validate(PEER_ID, bad_hash, REMOTE_ADDRESS, 0, 0)
	var bad_realm: NetMessages.Hello = _make_hello()
	bad_realm.realm = 0
	auth.validate(PEER_ID, bad_realm, REMOTE_ADDRESS, 0, 0)
	var bad_name: NetMessages.Hello = _make_hello()
	bad_name.display_name = "x"
	auth.validate(PEER_ID, bad_name, REMOTE_ADDRESS, 0, 0)
	auth.validate(PEER_ID, _make_hello(), REMOTE_ADDRESS, 4, 0)
	auth.validate(PEER_ID, _make_hello(), REMOTE_ADDRESS, 0, 2)
	assert_eq(provider.calls, 0, "no earlier rejection reaches the provider")

	assert_eq(auth.validate(PEER_ID, _make_hello(), REMOTE_ADDRESS, 0, 0), NetProtocol.Result.OK,
			"and with everything in order it does")
	assert_eq(provider.calls, 1, "the provider decides last")


func test_checks_run_in_the_documented_order() -> void:
	var auth: ServerAuth = _make_auth(null, PackedInt32Array(), _make_config(4, 2))
	var hello: NetMessages.Hello = _make_hello()
	# Everything wrong at once: the first failure is reported, in the order of section 3.
	hello.protocol_version = 99
	hello.sim_hash = 1
	hello.realm = 0
	hello.display_name = "x"
	assert_eq(auth.validate(PEER_ID, hello, REMOTE_ADDRESS, 4, 2), NetProtocol.Result.VERSION, "version")
	hello.protocol_version = NetProtocol.PROTOCOL_VERSION
	assert_eq(auth.validate(PEER_ID, hello, REMOTE_ADDRESS, 4, 2), NetProtocol.Result.SIM_HASH, "fingerprint")
	hello.sim_hash = SIM_HASH
	assert_eq(auth.validate(PEER_ID, hello, REMOTE_ADDRESS, 4, 2), NetProtocol.Result.REALM, "realm")
	hello.realm = NetProtocol.Realm.SOLMARCH
	assert_eq(auth.validate(PEER_ID, hello, REMOTE_ADDRESS, 4, 2), NetProtocol.Result.NAME, "name")
	hello.display_name = "Bruno"
	assert_eq(auth.validate(PEER_ID, hello, REMOTE_ADDRESS, 4, 2), NetProtocol.Result.FULL, "cap")
	assert_eq(auth.validate(PEER_ID, hello, REMOTE_ADDRESS, 0, 2), NetProtocol.Result.TOO_MANY_CONNECTIONS,
			"connections per IP")
	assert_eq(auth.validate(PEER_ID, hello, REMOTE_ADDRESS, 0, 1), NetProtocol.Result.OK, "everything in order")


func test_every_reject_reason_has_a_spanish_text() -> void:
	# Every reason ServerAuth can return has its text for the REJECT.
	for result: int in [NetProtocol.Result.VERSION, NetProtocol.Result.SIM_HASH,
			NetProtocol.Result.REALM, NetProtocol.Result.FULL, NetProtocol.Result.TICKET,
			NetProtocol.Result.MALFORMED, NetProtocol.Result.TOO_MANY_CONNECTIONS,
			NetProtocol.Result.NAME]:
		var text: String = NetProtocol.result_text(result)
		assert_false(text.is_empty(), "text of reason %d" % result)
		assert_false(text == NetProtocol.result_text(-1),
				"reason %d has its own text" % result)


# --- Realm balance (GUE-42) -------------------------------------------------------------------

func _unbalanced_auth(max_diff: int, counts: PackedInt32Array, provider: AuthProvider = null) -> ServerAuth:
	var config: ServerConfig = _make_config(16, 2)
	config.max_realm_diff = max_diff
	var auth: ServerAuth = _make_auth(provider, PackedInt32Array([NetProtocol.Realm.VARDHEIM,
			NetProtocol.Realm.SOLMARCH]), config)
	auth.set_realm_counts_source(func() -> PackedInt32Array: return counts)
	return auth


func test_reject_imbalance_when_the_realm_would_lead_by_more_than_the_limit() -> void:
	var auth: ServerAuth = _unbalanced_auth(2, PackedInt32Array([3, 1, 0]))
	var hello: NetMessages.Hello = _make_hello()
	assert_eq(auth.validate(PEER_ID, hello, REMOTE_ADDRESS, 4, 0), NetProtocol.Result.IMBALANCE,
			"Vardheim would go to 4 against 1: a lead of 3, more than 2")
	hello.realm = NetProtocol.Realm.SOLMARCH
	assert_eq(auth.validate(PEER_ID, hello, REMOTE_ADDRESS, 4, 0), NetProtocol.Result.OK, "Solmarch, the short one, gets in")
	var edge: ServerAuth = _unbalanced_auth(2, PackedInt32Array([2, 1, 0]))
	hello.realm = NetProtocol.Realm.VARDHEIM
	assert_eq(edge.validate(PEER_ID, hello, REMOTE_ADDRESS, 3, 0), NetProtocol.Result.OK, "3 against 1: exactly a lead of 2, fine")


func test_the_imbalance_check_is_off_without_a_limit_or_a_source() -> void:
	var hello: NetMessages.Hello = _make_hello()
	assert_eq(_unbalanced_auth(0, PackedInt32Array([9, 0, 0])).validate(PEER_ID, hello, REMOTE_ADDRESS, 9, 0),
			NetProtocol.Result.OK, "with 0 there is no limit")
	var config: ServerConfig = _make_config()
	config.max_realm_diff = 1
	var no_source: ServerAuth = _make_auth(null, PackedInt32Array(), config)
	assert_eq(no_source.validate(PEER_ID, hello, REMOTE_ADDRESS, 0, 0), NetProtocol.Result.OK, "without a count it is not rejected")


func test_imbalance_comes_after_the_other_checks_and_the_provider() -> void:
	var counts := PackedInt32Array([5, 0, 0])
	var hello: NetMessages.Hello = _make_hello()
	hello.display_name = "ab"
	assert_eq(_unbalanced_auth(1, counts).validate(PEER_ID, hello, REMOTE_ADDRESS, 5, 0), NetProtocol.Result.NAME,
			"a misspelled name is reported first")
	hello = _make_hello()
	assert_eq(_unbalanced_auth(1, counts).validate(PEER_ID, hello, REMOTE_ADDRESS, 4, 0), NetProtocol.Result.IMBALANCE)
	var provider := CountingProvider.new()
	provider.result = NetProtocol.Result.TICKET
	assert_eq(_unbalanced_auth(1, counts, provider).validate(PEER_ID, hello, REMOTE_ADDRESS, 4, 0), NetProtocol.Result.TICKET,
			"a bad ticket is reported before the imbalance")
	provider = CountingProvider.new()
	assert_eq(_unbalanced_auth(1, counts, provider).validate(PEER_ID, hello, REMOTE_ADDRESS, 4, 0), NetProtocol.Result.IMBALANCE)
	assert_eq(provider.calls, 1, "the provider is still queried")
	assert_eq(_unbalanced_auth(1, counts).validate(PEER_ID, hello, REMOTE_ADDRESS, 16, 0), NetProtocol.Result.FULL,
			"and a full server, also first")


## With tickets (docs/platform.md §5.4) the HELLO's realm and name are not checked: neither REALM, nor NAME (even if
## the name is that of someone connected), nor IMBALANCE; the provider receives the peer and may leave it pending.
func test_with_tickets_the_realm_and_name_of_the_hello_are_ignored() -> void:
	var provider := CountingProvider.new()
	provider.tickets = true
	provider.result = AuthProvider.PENDING
	var config: ServerConfig = _make_config(4, 2)
	config.max_realm_diff = 1
	var auth: ServerAuth = _make_auth(provider, PackedInt32Array([NetProtocol.Realm.VARDHEIM]), config)
	auth.set_connected_names_source(func() -> PackedStringArray: return PackedStringArray(["Bruna"]))
	auth.set_realm_counts_source(func() -> PackedInt32Array: return PackedInt32Array([0, 5, 0]))
	var hello: NetMessages.Hello = _make_hello()
	hello.realm = NetProtocol.Realm.ASKARRA
	hello.display_name = "Bruna"
	assert_eq(auth.validate(PEER_ID, hello, REMOTE_ADDRESS, 0, 0), AuthProvider.PENDING,
			"neither REALM nor NAME: the provider decides")
	assert_eq(provider.last_peer_id, PEER_ID, "the provider receives the peer")
	hello.display_name = "x"
	hello.realm = NetProtocol.Realm.NONE
	assert_eq(auth.validate(PEER_ID, hello, REMOTE_ADDRESS, 0, 0), AuthProvider.PENDING,
			"not even an invalid name or realm")
	provider.result = NetProtocol.Result.OK
	assert_eq(auth.validate(PEER_ID, _make_hello(), REMOTE_ADDRESS, 0, 0), NetProtocol.Result.OK,
			"no IMBALANCE even if the declared realm unbalances")
	assert_eq(auth.validate(PEER_ID, _make_hello(), REMOTE_ADDRESS, 4, 0), NetProtocol.Result.FULL,
			"the cap is checked")
	assert_true(auth.is_realm_allowed(NetProtocol.Realm.VARDHEIM) and not auth.is_realm_allowed(
			NetProtocol.Realm.ASKARRA), "the zone checks the claim's realm with is_realm_allowed")
