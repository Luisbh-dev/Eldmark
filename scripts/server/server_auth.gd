class_name ServerAuth
extends RefCounted
## Validación del HELLO de un cliente (docs/red.md, sección 3).
## [br][br]
## Decide si se envía WELCOME o REJECT. El magic y el formato ya los comprueba
## [method NetMessages.Hello.decode] (un HELLO mal formado ni llega aquí). Las comprobaciones,
## en este orden y devolviendo el primer fallo:
## [codeblock]
## versión del protocolo        -> VERSION
## sim_hash                     -> SIM_HASH
## reino válido y admitido      -> REALM    (NONE siempre se rechaza)
## nombre (NameRules)           -> NAME     (y no repetido entre los conectados)
## servidor lleno               -> FULL     (los falsos de relleno no ocupan plaza: GUE-43)
## demasiadas conexiones por IP -> TOO_MANY_CONNECTIONS (salvo loopback)
## el AuthProvider              -> OK o TICKET
## el reino elegido              -> IMBALANCE (solo con --max-realm-diff, tras el proveedor: el reino lo puede
##                                 decidir él; ver RealmBalance)
## [/codeblock]

## Direcciones de loopback exentas del tope por IP (para los bots y los clientes locales).
## Además se considera loopback cualquier dirección que empiece por [code]127.[/code].
const LOOPBACK_ADDRESSES: Array[String] = ["127.0.0.1", "::1", "localhost"]
## Cuerpo de [code]127.0.0.0/8[/code] y su forma IPv4 mapeada en IPv6.
const _LOOPBACK_PREFIXES: Array[String] = ["127.", "::ffff:127."]

var _config: ServerConfig
var _sim_hash: int
var _allowed_realms: PackedInt32Array
var _provider: AuthProvider
var _connected_names: Callable = Callable()
var _realm_counts: Callable = Callable()


## [param sim_hash] es la huella de la simulación del servidor
## ([method NetProtocol.compute_sim_hash]); [param allowed_realms], los reinos de la zona
## (vacío = todos los reales); [param provider], quien da la última palabra.
func _init(config: ServerConfig, sim_hash: int, allowed_realms: PackedInt32Array,
		provider: AuthProvider) -> void:
	_config = config
	_sim_hash = sim_hash
	_allowed_realms = allowed_realms
	_provider = provider


## Fuente de los nombres de los jugadores ya conectados en la zona: un [Callable] sin argumentos
## que devuelve un [PackedStringArray]. Se consulta en cada HELLO; con un nombre que ya está ahí
## (se compara con [method NameRules.normalize_key]: da igual mayúsculas y tildes) se rechaza con
## NAME, para que los susurros por nombre no sean ambiguos. Sin fuente no se comprueba.
func set_connected_names_source(source: Callable) -> void:
	_connected_names = source


## Fuente de las personas conectadas en cada reino (GUE-42): un [Callable] sin argumentos que devuelve un
## [PackedInt32Array] de tres posiciones (Vardheim, Solmarch, Askarra; ver [RealmBalance]). Se consulta en
## cada HELLO aceptado cuando [member ServerConfig.max_realm_diff] es mayor que 0; sin fuente no se rechaza
## nunca por desequilibrio.
func set_realm_counts_source(source: Callable) -> void:
	_realm_counts = source


## Devuelve un [enum NetProtocol.Result]: OK si hay que aceptar al cliente o el motivo del
## rechazo. [param player_count] son los jugadores ya conectados y
## [param connections_from_address], las conexiones que ya tiene abiertas esa IP (sin contar
## esta): se rechaza si llega a [member ServerConfig.max_connections_per_ip].
## [br][br]
## [param filler_seats] son los falsos de relleno de [code]--max-realm-diff[/code] que hay entre esos jugadores y que
## aún pueden ceder su plaza (GUE-43): no ocupan plazas de personas, así que el servidor solo está lleno (FULL) si los
## demás (personas y falsos que no son de relleno) llegan a [member ServerConfig.max_players]. Si con un OK el servidor
## sigue lleno, quien llama le aparta a la persona la plaza de un falso de relleno, que se va cuando ella entra en el
## mundo ([method FillerKeeper.reserve_seat]).
func validate(hello: NetMessages.Hello, remote_address: String, player_count: int,
		connections_from_address: int, filler_seats: int = 0) -> int:
	if hello == null:
		return NetProtocol.Result.MALFORMED
	if hello.protocol_version != NetProtocol.PROTOCOL_VERSION:
		return NetProtocol.Result.VERSION
	if hello.sim_hash != _sim_hash:
		return NetProtocol.Result.SIM_HASH
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
	var result: int = _provider.authenticate(hello)
	if result == NetProtocol.Result.OK and _would_unbalance(hello.realm):
		return NetProtocol.Result.IMBALANCE
	return result


## true si [param remote_address] es loopback (127.0.0.1, ::1, localhost o cualquier 127.x), que
## no cuenta para el tope de conexiones por IP.
static func is_loopback(remote_address: String) -> bool:
	var address: String = remote_address.strip_edges().to_lower()
	if LOOPBACK_ADDRESSES.has(address):
		return true
	for prefix: String in _LOOPBACK_PREFIXES:
		if address.begins_with(prefix):
			return true
	return false


## Clave con la que el tope por IP cuenta las conexiones de [param remote_address]: una IPv4 tal
## cual, una IPv6 mapeada ([code]::ffff:a.b.c.d[/code]) como su IPv4 y el resto de IPv6 por su
## prefijo /64 (sus cuatro primeros grupos, ya expandidos y sin ceros a la izquierda), porque quien
## tiene IPv6 suele tener un /64 entero y cada dirección suya sería otra IP. La zona de ámbito
## ([code]%eth0[/code]) no cuenta. Lo que no se entiende se devuelve tal cual.
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


## true si [param display_name] cabe en el HELLO (como mucho [constant NetProtocol.MAX_NAME_CHARS]
## caracteres y [constant NetProtocol.MAX_NAME_BYTES] bytes en UTF-8) y cumple las reglas de
## [NameRules]. No mira los nombres de los conectados: para eso está [method check_name].
static func is_valid_name(display_name: String) -> bool:
	return _fits_protocol(display_name) and NameRules.is_valid(display_name)


## Motivo ([enum NameRules.Reason]) por el que [param display_name] no se admite, o
## [constant NameRules.Reason.OK] si vale: cabe en el HELLO, cumple las reglas de [NameRules] y
## no lo lleva ya un jugador conectado ([constant NameRules.Reason.TAKEN]).
func check_name(display_name: String) -> int:
	if not _fits_protocol(display_name):
		return NameRules.Reason.TOO_LONG
	var reason: int = NameRules.validate(display_name)
	if reason != NameRules.Reason.OK:
		return reason
	if is_name_connected(display_name):
		return NameRules.Reason.TAKEN
	return NameRules.Reason.OK


## true si la fuente de [method set_connected_names_source] da algún nombre con la misma clave
## ([method NameRules.normalize_key]) que [param display_name].
func is_name_connected(display_name: String) -> bool:
	if not _connected_names.is_valid():
		return false
	var key: String = NameRules.normalize_key(display_name)
	var names: PackedStringArray = _connected_names.call()
	for existing: String in names:
		if NameRules.normalize_key(existing) == key:
			return true
	return false


# Los topes del cable: 24 caracteres y 48 bytes en UTF-8 como mucho (el mínimo lo pone NameRules).
static func _fits_protocol(display_name: String) -> bool:
	if display_name.length() > NetProtocol.MAX_NAME_CHARS:
		return false
	return display_name.to_utf8_buffer().size() <= NetProtocol.MAX_NAME_BYTES


# true si entrar en [param realm] dejaría más de --max-realm-diff personas de ventaja sobre el reino con
# menos de los que admite la zona. Los jugadores falsos no cuentan: el recuento es de personas.
func _would_unbalance(realm: int) -> bool:
	if _config.max_realm_diff <= 0 or not _realm_counts.is_valid():
		return false
	return RealmBalance.exceeds(_realm_counts.call(), _allowed_realms, realm, _config.max_realm_diff)


func _is_realm_allowed(realm: int) -> bool:
	if not RealmCatalog.is_realm_code(realm):
		return false
	return _allowed_realms.is_empty() or _allowed_realms.has(realm)
