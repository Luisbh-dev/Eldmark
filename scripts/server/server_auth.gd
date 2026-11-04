class_name ServerAuth
extends RefCounted
## Validation of a client's HELLO (docs/red.md, section 3).
## [br][br]
## Decides whether a WELCOME or a REJECT is sent. The magic and the format are already checked by
## [method NetMessages.Hello.decode] (a malformed HELLO never gets here). The checks, in this order, returning the
## first failure:
## [codeblock]
## protocol version             -> VERSION
## sim_hash                     -> SIM_HASH
## valid and admitted realm     -> REALM    (NONE is always rejected)
## name (NameRules)             -> NAME     (and not repeated among the connected)
## server full                  -> FULL     (filler fakes do not take seats: GUE-43)
## too many connections per IP  -> TOO_MANY_CONNECTIONS (except loopback)
## the AuthProvider             -> OK, PENDING or its reason (TICKET, UNAVAILABLE…)
## the chosen realm             -> IMBALANCE (only with --max-realm-diff, after the provider: it can decide the
##                                 realm; see RealmBalance)
## [/codeblock]
## With a ticket provider ([method AuthProvider.uses_tickets], docs/plataforma.md §5.4) the HELLO's realm and name are
## not looked at: those of the claim rule, which the zone applies on arrival (REALM) and which the platform makes unique
## when creating the character. So there is no REJECT NAME and the HELLO stops revealing whether a name is in the zone
## (docs/social.md, 12.7). There is no IMBALANCE either: the realm is no longer chosen when connecting.

## Loopback addresses exempt from the per-IP cap (for bots and local clients). In addition, any address that starts with
## [code]127.[/code] is considered loopback.
const LOOPBACK_ADDRESSES: Array[String] = ["127.0.0.1", "::1", "localhost"]
## Body of [code]127.0.0.0/8[/code] and its IPv4-mapped IPv6 form.
const _LOOPBACK_PREFIXES: Array[String] = ["127.", "::ffff:127."]

var _config: ServerConfig
var _sim_hash: int
var _allowed_realms: PackedInt32Array
var _provider: AuthProvider
var _connected_names: Callable = Callable()
var _realm_counts: Callable = Callable()


## [param sim_hash] is the server's simulation fingerprint ([method NetProtocol.compute_sim_hash]);
## [param allowed_realms], the zone's realms (empty = all the real ones); [param provider], whoever has the last word.
func _init(config: ServerConfig, sim_hash: int, allowed_realms: PackedInt32Array,
		provider: AuthProvider) -> void:
	_config = config
	_sim_hash = sim_hash
	_allowed_realms = allowed_realms
	_provider = provider


## Source of the names of players already connected in the zone: a [Callable] without arguments that returns a
## [PackedStringArray]. It is queried on every HELLO; a name that is already there (compared with
## [method NameRules.normalize_key]: case and accents do not matter) is rejected with NAME, so that whispers by name are
## not ambiguous. Without a source it is not checked.
## [br][br]
## [b]Known limitation of phase 4[/b] (docs/social.md, 12.7): since the client chooses its name, that REJECT tells
## whether a name, of any realm, is currently in the zone, and with the whisper's "not connected" it can be deduced that
## it is an enemy. It is not covered here because the same client also chooses its realm ([DevAuthProvider]) and can
## enter the enemy's and whisper to them without more ado; from phase 5 the name and realm come from the ticket's
## character and this REJECT for someone else's name ceases to exist.
func set_connected_names_source(source: Callable) -> void:
	_connected_names = source


## Source of the people connected in each realm (GUE-42): a [Callable] without arguments that returns a three-position
## [PackedInt32Array] (Vardheim, Solmarch, Askarra; see [RealmBalance]). It is queried on every accepted HELLO when
## [member ServerConfig.max_realm_diff] is greater than 0; without a source it never rejects for imbalance.
func set_realm_counts_source(source: Callable) -> void:
	_realm_counts = source


## Returns an [enum NetProtocol.Result]: OK if the client must be accepted, [constant AuthProvider.PENDING] if the
## provider has not decided yet (the peer moves to VERIFYING) or the reason for rejection. [param peer_id] is the HELLO's
## peer, for the provider. [param player_count] is the players already connected (also those verifying) and
## [param connections_from_address], the connections that IP already has open (not counting this one): it is rejected if
## it reaches [member ServerConfig.max_connections_per_ip].
## [br][br]
## [param filler_seats] are the [code]--max-realm-diff[/code] filler fakes among those players that can still give up
## their seat (GUE-43): they take no people's seats, so the server is only full (FULL) if the others (people and fakes
## that are not fillers) reach [member ServerConfig.max_players]. If with an OK the server is still full, the caller
## reserves for the person the seat of a filler fake, which leaves when the person enters the world
## ([method FillerKeeper.reserve_seat]).
func validate(peer_id: int, hello: NetMessages.Hello, remote_address: String, player_count: int,
		connections_from_address: int, filler_seats: int = 0) -> int:
	if hello == null:
		return NetProtocol.Result.MALFORMED
	if hello.protocol_version != NetProtocol.PROTOCOL_VERSION:
		return NetProtocol.Result.VERSION
	if hello.sim_hash != _sim_hash:
		return NetProtocol.Result.SIM_HASH
	var tickets: bool = uses_tickets()
	if not tickets:
		if not _is_realm_allowed(hello.realm):
			return NetProtocol.Result.REALM
		if check_name(hello.display_name) != NameRules.Reason.OK:
			return NetProtocol.Result.NAME
	if player_count - clampi(filler_seats, 0, player_count) >= _config.max_players:
		return NetProtocol.Result.FULL
	if connections_from_address >= _config.max_connections_per_ip \
			and not is_loopback(remote_address):
		return NetProtocol.Result.TOO_MANY_CONNECTIONS
	if _provider == null:
		return NetProtocol.Result.TICKET
	var result: int = _provider.authenticate(peer_id, hello)
	if result == NetProtocol.Result.OK and not tickets and _would_unbalance(hello.realm):
		return NetProtocol.Result.IMBALANCE
	return result


## true if the provider uses tickets (the realm and name come from the claim).
func uses_tickets() -> bool:
	return _provider != null and _provider.uses_tickets()


## true if [param realm] is a real realm admitted in the zone (used by the zone when applying the claim).
func is_realm_allowed(realm: int) -> bool:
	return _is_realm_allowed(realm)


## true if [param remote_address] is loopback (127.0.0.1, ::1, localhost or any 127.x), which does not count towards the
## per-IP connection cap.
static func is_loopback(remote_address: String) -> bool:
	var address: String = remote_address.strip_edges().to_lower()
	if LOOPBACK_ADDRESSES.has(address):
		return true
	for prefix: String in _LOOPBACK_PREFIXES:
		if address.begins_with(prefix):
			return true
	return false


## Key with which the per-IP cap counts connections from [param remote_address]: an IPv4 as is, a mapped IPv6
## ([code]::ffff:a.b.c.d[/code]) as its IPv4 and other IPv6 by its /64 prefix (its first four groups, already expanded
## and without leading zeros), because whoever has IPv6 usually has a whole /64 and each of their addresses would count
## as another IP. The scope zone ([code]%eth0[/code]) does not count. What is not understood is returned as is.
static func address_group(remote_address: String) -> String:
	var text: String = remote_address.strip_edges().to_lower()
	var scope: int = text.find("%")
	if scope >= 0:
		text = text.substr(0, scope)
	if not text.contains(":"):
		return text
	if text.begins_with("::ffff:") and text.substr(7).contains("."):
		return text.substr(7)
	var halves: PackedStringArray = text.split("::")
	if halves.size() > 2:
		return remote_address
	var head: PackedStringArray = halves[0].split(":", false)
	var tail: PackedStringArray = PackedStringArray()
	var groups: PackedStringArray = head
	if halves.size() == 2:
		tail = halves[1].split(":", false)
		var missing: int = 8 - head.size() - tail.size()
		if missing < 1:
			return remote_address
		groups = head.duplicate()
		for _i: int in missing:
			groups.append("0")
		groups.append_array(tail)
	if groups.size() != 8:
		return remote_address
	var prefix := PackedStringArray()
	for i: int in 4:
		if not groups[i].is_valid_hex_number():
			return remote_address
		prefix.append("%x" % groups[i].hex_to_int())
	return ":".join(prefix)


## true if [param display_name] fits in the HELLO (at most [constant NetProtocol.MAX_NAME_CHARS] characters and
## [constant NetProtocol.MAX_NAME_BYTES] bytes in UTF-8) and meets the [NameRules] rules. It does not look at the names
## of those connected: [method check_name] is for that.
static func is_valid_name(display_name: String) -> bool:
	return _fits_protocol(display_name) and NameRules.is_valid(display_name)


## Reason ([enum NameRules.Reason]) why [param display_name] is not admitted, or [constant NameRules.Reason.OK] if it is
## valid: it fits in the HELLO, meets the [NameRules] rules and is not already used by a connected player
## ([constant NameRules.Reason.TAKEN]).
func check_name(display_name: String) -> int:
	if not _fits_protocol(display_name):
		return NameRules.Reason.TOO_LONG
	var reason: int = NameRules.validate(display_name)
	if reason != NameRules.Reason.OK:
		return reason
	if is_name_connected(display_name):
		return NameRules.Reason.TAKEN
	return NameRules.Reason.OK


## true if the source of [method set_connected_names_source] gives any name with the same key
## ([method NameRules.normalize_key]) as [param display_name].
func is_name_connected(display_name: String) -> bool:
	if not _connected_names.is_valid():
		return false
	var key: String = NameRules.normalize_key(display_name)
	var names: PackedStringArray = _connected_names.call()
	for existing: String in names:
		if NameRules.normalize_key(existing) == key:
			return true
	return false


# The wire caps: 24 characters and 48 bytes in UTF-8 at most (the minimum is set by NameRules).
static func _fits_protocol(display_name: String) -> bool:
	if display_name.length() > NetProtocol.MAX_NAME_CHARS:
		return false
	return display_name.to_utf8_buffer().size() <= NetProtocol.MAX_NAME_BYTES


# true if entering [param realm] would leave more than --max-realm-diff people of advantage over the realm with the
# fewest among those the zone admits. Fake players do not count: the count is of people.
func _would_unbalance(realm: int) -> bool:
	if _config.max_realm_diff <= 0 or not _realm_counts.is_valid():
		return false
	return RealmBalance.exceeds(_realm_counts.call(), _allowed_realms, realm, _config.max_realm_diff)


func _is_realm_allowed(realm: int) -> bool:
	if not RealmCatalog.is_realm_code(realm):
		return false
	return _allowed_realms.is_empty() or _allowed_realms.has(realm)
