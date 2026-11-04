class_name PlatformErrors
extends RefCounted
## The texts for the player for platform errors (docs/platform.md §4.1, UI-04): the client translates
## by [code]code[/code] and, if it does not know it, shows the server's [code]message[/code]. With no response or with a TLS
## failure: "No se puede conectar con el servidor de cuentas" (Cannot connect to the accounts server) (§13.2).
## [br][br]
## Error dates (end of a sanction, account deletion, realm being released) arrive in Unix time and are
## shown in local time ([method format_date]). Client only.

const TEXT_NETWORK: String = "No se puede conectar con el servidor de cuentas"
const TEXT_VALIDATION: String = "Datos no válidos"
const TEXT_INTERNAL: String = "Error del servidor"

## Fixed texts by code (§4.1 and the codes added by P1 and P2, §19.2 and §19.3).
const TEXTS: Dictionary = {
	"bad_request": TEXT_VALIDATION,
	"validation": TEXT_VALIDATION,
	"unauthorized": "Tu sesión ha caducado",
	"invalid_credentials": "Correo o contraseña incorrectos",
	"email_unverified": "Verifica tu correo para entrar",
	"terms_required": "Hay textos nuevos que aceptar",
	"not_found": "No encontrado",
	"name_taken": "Ese nombre ya está en uso",
	"realm_closed": "Ese reino abre más adelante",
	"slots_full": "No te quedan huecos",
	"rename_required": "Tienes que cambiar el nombre de este personaje",
	"rename_not_required": "Este personaje no necesita otro nombre",
	"character_busy": "Tu personaje está saliendo del mundo…",
	"client_outdated": "Actualiza el cliente",
	"zone_unavailable": "La zona no está disponible",
	"maintenance": "El servidor está en mantenimiento",
	"unavailable": "El servicio de cuentas no está disponible; inténtalo más tarde",
	"too_large": "La petición es demasiado grande",
	"deletion_expired": "El plazo para cancelar el borrado ha terminado",
	"internal": TEXT_INTERNAL,
	ApiResult.CODE_NETWORK: TEXT_NETWORK,
	ApiResult.CODE_BAD_RESPONSE: TEXT_INTERNAL,
}

## Spanish name of each field of [code]fields[/code] for "Datos no válidos (correo, contraseña)" (Invalid data (email, password)).
const FIELD_NAMES: Dictionary = {
	"email": "correo",
	"new_email": "correo",
	"password": "contraseña",
	"current_password": "contraseña",
	"new_password": "contraseña nueva",
	"age_confirmed": "edad",
	"name": "nombre",
	"confirm_name": "nombre",
	"realm": "reino",
	"race_id": "pueblo",
	"appearance": "apariencia",
	"starter_template_id": "plantilla",
	"token": "enlace",
	"refresh_token": "sesión",
}


## The text for the player of [param result] (empty if it went well).
static func text_for(result: ApiResult) -> String:
	if result == null:
		return TEXT_NETWORK
	if result.ok:
		return ""
	match result.code:
		"account_suspended":
			var until: int = result.int_of("until", 0)
			var reason: String = result.text_of("reason")
			if until > 0:
				return "Cuenta suspendida hasta el %s: %s" % [format_date(until), _reason_or_default(reason)]
			return "Cuenta suspendida: %s" % _reason_or_default(reason)
		"account_banned":
			return "Cuenta expulsada: %s" % _reason_or_default(result.text_of("reason"))
		"account_pending_deletion":
			var deletion_at: int = result.int_of("deletion_at", 0)
			if deletion_at > 0:
				return "Tu cuenta se borrará el %s" % format_date(deletion_at)
			return "Tu cuenta tiene el borrado pedido"
		"name_invalid":
			var reason_code: int = NameRules.reason_from_code(result.text_of("reason"))
			if reason_code > 0:
				return NameRules.reason_text(reason_code)
			return "Ese nombre no vale"
		"realm_locked":
			var realm_id: StringName = StringName(result.text_of("realm"))
			var realm_name: String = RealmCatalog.display_name(realm_id)
			var text: String = "Tu cuenta es de %s" % realm_name if not realm_name.is_empty() \
					else "Tu cuenta es de otro reino"
			var unlock_at: int = result.int_of("unlock_at", 0)
			if unlock_at > 0:
				text += " hasta el %s" % format_date(unlock_at)
			return text
		"rate_limited":
			var wait_s: int = maxi(result.retry_after_s, 1)
			return "Demasiados intentos; espera %d s" % wait_s
		"maintenance":
			if not result.message.is_empty():
				return result.message
			return TEXTS["maintenance"]
		"validation", "bad_request":
			return _validation_text(result)
		ApiResult.CODE_BAD_URL:
			return result.message if not result.message.is_empty() else TEXT_NETWORK
	if TEXTS.has(result.code):
		return TEXTS[result.code]
	if not result.message.is_empty():
		return result.message
	return TEXT_INTERNAL


## A Unix date in this machine's local time: "12/05/2026 18:00".
static func format_date(unix: int) -> String:
	var bias_minutes: int = int(Time.get_time_zone_from_system().get("bias", 0))
	var local: Dictionary = Time.get_datetime_dict_from_unix_time(unix + bias_minutes * 60)
	return "%02d/%02d/%04d %02d:%02d" % [local["day"], local["month"], local["year"], local["hour"],
			local["minute"]]


static func _reason_or_default(reason: String) -> String:
	return reason if not reason.strip_edges().is_empty() else "sin motivo"


static func _validation_text(result: ApiResult) -> String:
	var names: PackedStringArray = PackedStringArray()
	var fields: Dictionary = result.get_fields()
	var keys: Array = fields.keys()
	keys.sort()
	for key: Variant in keys:
		var field: String = str(key)
		if field.begins_with("accept."):
			field = "accept"
		var name_text: String = FIELD_NAMES.get(field, "textos legales" if field == "accept" else field)
		if not names.has(name_text):
			names.append(name_text)
	if names.is_empty():
		return TEXT_VALIDATION
	return "%s (%s)" % [TEXT_VALIDATION, ", ".join(names)]
