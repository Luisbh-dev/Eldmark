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
## nombre de 3 a 24 caracteres  -> NAME     (y 48 B como mucho en UTF-8)
## servidor lleno               -> FULL
## demasiadas conexiones por IP -> TOO_MANY_CONNECTIONS (salvo loopback)
## el AuthProvider              -> OK o TICKET
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


## [param sim_hash] es la huella de la simulación del servidor
## ([method NetProtocol.compute_sim_hash]); [param allowed_realms], los reinos de la zona
## (vacío = todos los reales); [param provider], quien da la última palabra.
func _init(config: ServerConfig, sim_hash: int, allowed_realms: PackedInt32Array,
		provider: AuthProvider) -> void:
	_config = config
	_sim_hash = sim_hash
	_allowed_realms = allowed_realms
	_provider = provider


## Devuelve un [enum NetProtocol.Result]: OK si hay que aceptar al cliente o el motivo del
## rechazo. [param player_count] son los jugadores ya conectados y
## [param connections_from_address], las conexiones que ya tiene abiertas esa IP (sin contar
## esta): se rechaza si llega a [member ServerConfig.max_connections_per_ip].
func validate(hello: NetMessages.Hello, remote_address: String, player_count: int,
		connections_from_address: int) -> int:
	if hello == null:
		return NetProtocol.Result.MALFORMED
	if hello.protocol_version != NetProtocol.PROTOCOL_VERSION:
		return NetProtocol.Result.VERSION
	if hello.sim_hash != _sim_hash:
		return NetProtocol.Result.SIM_HASH
	if not _is_realm_allowed(hello.realm):
		return NetProtocol.Result.REALM
	if not is_valid_name(hello.display_name):
		return NetProtocol.Result.NAME
	if player_count >= _config.max_players:
		return NetProtocol.Result.FULL
	if connections_from_address >= _config.max_connections_per_ip \
			and not is_loopback(remote_address):
		return NetProtocol.Result.TOO_MANY_CONNECTIONS
	if _provider == null:
		return NetProtocol.Result.TICKET
	return _provider.authenticate(hello)


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


## true si [param display_name] cumple las reglas de la fase 2: de
## [constant NetProtocol.MIN_NAME_CHARS] a [constant NetProtocol.MAX_NAME_CHARS] caracteres, no
## más de [constant NetProtocol.MAX_NAME_BYTES] bytes en UTF-8, ni solo espacios ni caracteres de
## control. Las reglas completas (letras, reservados, colisiones) llegan con SOC-01.
static func is_valid_name(display_name: String) -> bool:
	var length: int = display_name.length()
	if length < NetProtocol.MIN_NAME_CHARS or length > NetProtocol.MAX_NAME_CHARS:
		return false
	if display_name.to_utf8_buffer().size() > NetProtocol.MAX_NAME_BYTES:
		return false
	if display_name.strip_edges().is_empty():
		return false
	for i: int in length:
		var code: int = display_name.unicode_at(i)
		if code < 0x20 or (code >= 0x7F and code <= 0x9F):
			return false
	return true


func _is_realm_allowed(realm: int) -> bool:
	if not RealmCatalog.is_realm_code(realm):
		return false
	return _allowed_realms.is_empty() or _allowed_realms.has(realm)
