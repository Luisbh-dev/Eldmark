class_name AccountSession
extends RefCounted
## The account session on the client (docs/platform.md §4.2 and §14.4): the two tokens, when the access one
## expires, the scope ([code]game[/code] or [code]privacy[/code]), the restriction of a sanctioned account and the account
## from the last response. It lives only in memory: none of this is written to disk (§0). It is kept by [FrontMain] between
## scenes and used by [PlatformApi] on every call with a session.
## [br][br]
## Deadlines are in milliseconds of [method Time.get_ticks_msec] (the process clock, which does not jump): the
## platform gives [code]access_expires_in[/code] in seconds and it is converted here on receipt. Client only.

## Lead time with which the access token is refreshed before it expires.
const REFRESH_MARGIN_MSEC: int = 60000
const SCOPE_GAME: String = "game"
const SCOPE_PRIVACY: String = "privacy"

var access_token: String = ""
var refresh_token: String = ""
## When the access token expires ([method Time.get_ticks_msec]).
var access_expires_msec: int = 0
## When the whole session expires (the refresh; 12 h from login, §4.2).
var refresh_expires_msec: int = 0
## [constant SCOPE_GAME] or [constant SCOPE_PRIVACY] (suspended or banned account: only export, delete the account
## and log out).
var scope: String = ""
## [code]{code, until, reason}[/code] of the sanction of a privacy session; empty if there is none.
var restriction: Dictionary = {}
## The account ([code]GET /v1/account[/code] or the login one): [code]account_id[/code] (string),
## [code]email[/code], [code]role[/code], [code]realms[/code], [code]slots[/code], [code]pending[/code]…
var account: Dictionary = {}


## The session from the response of [code]POST /v1/sessions[/code] ([param data]) received at [param now_msec].
static func from_login(data: Dictionary, now_msec: int) -> AccountSession:
	var session := AccountSession.new()
	session.apply_tokens(data, now_msec)
	var restriction_value: Variant = data.get("restriction")
	session.restriction = restriction_value if restriction_value is Dictionary else {}
	var account_value: Variant = data.get("account")
	session.account = account_value if account_value is Dictionary else {}
	return session


## Sets the tokens from a login or a refresh ([param data]: [code]access_token[/code],
## [code]access_expires_in[/code], [code]refresh_token[/code], [code]refresh_expires_in[/code] and [code]scope[/code])
## received at [param now_msec]. A refresh keeps the scope (§4.2).
func apply_tokens(data: Dictionary, now_msec: int) -> void:
	access_token = _text(data, "access_token")
	refresh_token = _text(data, "refresh_token")
	access_expires_msec = now_msec + _seconds(data, "access_expires_in") * 1000
	refresh_expires_msec = now_msec + _seconds(data, "refresh_expires_in") * 1000
	var new_scope: String = _text(data, "scope")
	if not new_scope.is_empty():
		scope = new_scope


## true if there is a logged-in session (with tokens).
func is_active() -> bool:
	return not access_token.is_empty() and not refresh_token.is_empty()


## true if it is the privacy session of a sanctioned account (§4.2).
func is_privacy() -> bool:
	return scope == SCOPE_PRIVACY


## true if the access token expires in less than [constant REFRESH_MARGIN_MSEC] (or has already expired) at
## [param now_msec].
func needs_refresh(now_msec: int) -> bool:
	return is_active() and access_expires_msec - now_msec <= REFRESH_MARGIN_MSEC


## Forgets the session (logout, lost session).
func clear() -> void:
	access_token = ""
	refresh_token = ""
	access_expires_msec = 0
	refresh_expires_msec = 0
	scope = ""
	restriction = {}
	account = {}


## The account's realm in [param world_id] (id from [RealmCatalog], [code]&""[/code] if it has none yet), from
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
