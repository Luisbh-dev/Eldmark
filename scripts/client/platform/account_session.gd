class_name AccountSession
extends RefCounted
## La sesión de la cuenta en el cliente (docs/plataforma.md §4.2 y §14.4): los dos tokens, cuándo caduca el de
## acceso, el ámbito ([code]game[/code] o [code]privacy[/code]), la restricción de una cuenta sancionada y la cuenta
## de la última respuesta. Vive solo en memoria: nada de esto se escribe en disco (§0). La guarda [FrontMain] entre
## escenas y la usa [PlatformApi] en cada llamada con sesión.
## [br][br]
## Los plazos van en milisegundos de [method Time.get_ticks_msec] (el reloj del proceso, que no salta): la
## plataforma da [code]access_expires_in[/code] en segundos y aquí se convierte al recibirlo. Solo cliente.

## Antelación con la que se refresca el token de acceso antes de que caduque.
const REFRESH_MARGIN_MSEC: int = 60000
const SCOPE_GAME: String = "game"
const SCOPE_PRIVACY: String = "privacy"

var access_token: String = ""
var refresh_token: String = ""
## Cuándo caduca el token de acceso ([method Time.get_ticks_msec]).
var access_expires_msec: int = 0
## Cuándo caduca la sesión entera (el refresco; 12 h desde el inicio, §4.2).
var refresh_expires_msec: int = 0
## [constant SCOPE_GAME] o [constant SCOPE_PRIVACY] (cuenta suspendida o expulsada: solo exportar, borrar la cuenta
## y cerrar sesión).
var scope: String = ""
## [code]{code, until, reason}[/code] de la sanción de una sesión de privacidad; vacío si no hay.
var restriction: Dictionary = {}
## La cuenta ([code]GET /v1/account[/code] o la del inicio de sesión): [code]account_id[/code] (cadena),
## [code]email[/code], [code]role[/code], [code]realms[/code], [code]slots[/code], [code]pending[/code]…
var account: Dictionary = {}


## La sesión de la respuesta de [code]POST /v1/sessions[/code] ([param data]) recibida en [param now_msec].
static func from_login(data: Dictionary, now_msec: int) -> AccountSession:
	var session := AccountSession.new()
	session.apply_tokens(data, now_msec)
	var restriction_value: Variant = data.get("restriction")
	session.restriction = restriction_value if restriction_value is Dictionary else {}
	var account_value: Variant = data.get("account")
	session.account = account_value if account_value is Dictionary else {}
	return session


## Pone los tokens de un inicio de sesión o de un refresco ([param data]: [code]access_token[/code],
## [code]access_expires_in[/code], [code]refresh_token[/code], [code]refresh_expires_in[/code] y [code]scope[/code])
## recibidos en [param now_msec]. El refresco conserva el ámbito (§4.2).
func apply_tokens(data: Dictionary, now_msec: int) -> void:
	access_token = _text(data, "access_token")
	refresh_token = _text(data, "refresh_token")
	access_expires_msec = now_msec + _seconds(data, "access_expires_in") * 1000
	refresh_expires_msec = now_msec + _seconds(data, "refresh_expires_in") * 1000
	var new_scope: String = _text(data, "scope")
	if not new_scope.is_empty():
		scope = new_scope


## true si hay una sesión iniciada (con tokens).
func is_active() -> bool:
	return not access_token.is_empty() and not refresh_token.is_empty()


## true si es la sesión de privacidad de una cuenta sancionada (§4.2).
func is_privacy() -> bool:
	return scope == SCOPE_PRIVACY


## true si el token de acceso caduca en menos de [constant REFRESH_MARGIN_MSEC] (o ya caducó) en
## [param now_msec].
func needs_refresh(now_msec: int) -> bool:
	return is_active() and access_expires_msec - now_msec <= REFRESH_MARGIN_MSEC


## Olvida la sesión (cerrar sesión, sesión perdida).
func clear() -> void:
	access_token = ""
	refresh_token = ""
	access_expires_msec = 0
	refresh_expires_msec = 0
	scope = ""
	restriction = {}
	account = {}


## El reino de la cuenta en [param world_id] (id de [RealmCatalog], [code]&""[/code] si aún no tiene), de
## [member account].
func realm_in(world_id: int) -> StringName:
	var realms: Variant = account.get("realms")
	if realms is Dictionary:
		var value: Variant = (realms as Dictionary).get(str(world_id))
		if value is String:
			return StringName(value)
	return &""


static func _text(data: Dictionary, key: String) -> String:
	var value: Variant = data.get(key)
	return value if value is String else ""


static func _seconds(data: Dictionary, key: String) -> int:
	var value: Variant = data.get(key)
	if (value is float or value is int) and float(value) > 0.0:
		return int(value)
	return 0
