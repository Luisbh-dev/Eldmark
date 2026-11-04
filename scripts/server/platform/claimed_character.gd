class_name ClaimedCharacter
extends RefCounted
## What the 200 of the ticket claim brings (docs/plataforma.md §5.3 and §6): the account, the character, the
## lease and its saved sections. The zone uses the realm and name from here, never those of the HELLO.
## [br][br]
## [method from_claim] reads the body strictly, like Go: string ids ([method String.to_int], up to 2^63 − 1) and
## integers with [code]int()[/code] (accepts [code]4.0[/code]). The [code]progress[/code] section arrives as-is at
## [code]ProgressRecord.from_dictionary[/code] (docs/progresion.md §3.4), which does the same with its own.

## Account roles, lowest to highest (§9.1).
const ROLES: Array[StringName] = [&"player", &"moderator", &"gm", &"admin"]
## The six totals of the pvp section (§8).
const PVP_KEYS: Array[String] = ["kills", "deaths", "assists", "captures", "gate_damage", "defend_s"]
## Cap on a [code]lease_id[/code] (a UUID takes 36).
const MAX_LEASE_ID_LENGTH: int = 64

var character_id: int = 0
var account_id: int = 0
var world_id: int = 0
## Code of [enum NetProtocol.Realm].
var realm: int = 0
var display_name: String = ""
## One of [constant ROLES].
var role: StringName = &"player"
var lease_id: String = ""
## End of the account's mute (0 without a mute; 253402300799 for an open-ended one).
var muted_until_unix: int = 0
var ignored_accounts: PackedInt64Array = PackedInt64Array()
## The progress section as it arrives; read by [code]ProgressRecord.from_dictionary[/code] (progresion.md §14.2).
var progress: Dictionary = {}
## [code]{kills, deaths, assists, captures, gate_damage, defend_s}[/code], already with [code]int()[/code].
var pvp: Dictionary = {}
## The response's [code]instance_status[/code].
var instance_status: String = ""
## Moderation warnings the account has not seen ([code]account.warnings[/code], plataforma.md §19.5):
## [code]{sanction_id: int, text: String, at_unix: int}[/code]. The zone sends them in a NOTICE on entry (P7b).
var warnings: Array[Dictionary] = []


## What [param body] brings, or null if something is missing or something does not have the shape of §6.
static func from_claim(body: Dictionary) -> ClaimedCharacter:
	var account: Dictionary = PlatformJson.dict_in(body, "account")
	var character: Dictionary = PlatformJson.dict_in(body, "character")
	if account.is_empty() or character.is_empty():
		return null
	var claimed := ClaimedCharacter.new()
	claimed.lease_id = PlatformJson.text_in(body, "lease_id")
	if claimed.lease_id.is_empty() or claimed.lease_id.length() > MAX_LEASE_ID_LENGTH:
		return null
	claimed.instance_status = PlatformJson.text_in(body, "instance_status")
	claimed.account_id = PlatformJson.id_of(account.get("account_id"))
	claimed.character_id = PlatformJson.id_of(character.get("character_id"))
	if claimed.account_id < 1 or claimed.character_id < 1:
		return null
	claimed.role = StringName(PlatformJson.text_in(account, "role"))
	if not ROLES.has(claimed.role):
		return null
	claimed.muted_until_unix = PlatformJson.int_in(account, "muted_until_unix", 0, PlatformJson.MAX_SAFE_INT, -1)
	if claimed.muted_until_unix < 0:
		return null
	var ignored: Variant = account.get("ignored_account_ids")
	if ignored != null:
		if not ignored is Array:
			return null
		for value: Variant in ignored:
			var id: int = PlatformJson.id_of(value)
			if id < 1:
				return null
			claimed.ignored_accounts.append(id)
	var warnings: Variant = account.get("warnings")
	if warnings != null:
		if not warnings is Array:
			return null
		for value: Variant in warnings:
			var warning: Dictionary = value if value is Dictionary else {}
			var sanction_id: int = PlatformJson.id_of(warning.get("sanction_id"))
			var at_unix: int = PlatformJson.int_in(warning, "at_unix", 0, PlatformJson.MAX_SAFE_INT, -1)
			var text: String = PlatformJson.text_in(warning, "text")
			if sanction_id < 1 or at_unix < 0 or text.is_empty():
				return null
			claimed.warnings.append({"sanction_id": sanction_id, "text": text, "at_unix": at_unix})
	claimed.world_id = PlatformJson.int_in(character, "world_id", 1, 0xFFFF, 0)
	claimed.realm = PlatformJson.int_in(character, "realm", 1, 3, 0)
	claimed.display_name = PlatformJson.text_in(character, "name")
	if claimed.world_id < 1 or claimed.realm < 1 or claimed.display_name.is_empty() \
			or claimed.display_name.length() > NetProtocol.MAX_NAME_CHARS \
			or claimed.display_name.to_utf8_buffer().size() > NetProtocol.MAX_NAME_BYTES:
		return null
	if not body.has("progress"):
		return null
	var progress_value: Variant = body["progress"]
	if progress_value != null and not progress_value is Dictionary:
		return null
	claimed.progress = progress_value if progress_value is Dictionary else {}
	var pvp_value: Dictionary = PlatformJson.dict_in(body, "pvp")
	for key: String in PVP_KEYS:
		if not PlatformJson.is_int(pvp_value.get(key), 0, PlatformJson.MAX_SAFE_INT):
			return null
		claimed.pvp[key] = int(pvp_value[key])
	return claimed


## true if it is game staff (moderator or higher): its SPAWN carries the nameplate tag bit (SOC-14).
func is_staff() -> bool:
	return ROLES.find(role) >= 1
