class_name CharacterAppearance
extends RefCounted
## A character's appearance in 8 B (docs/progression.md §7.2, ART-19): indices over
## [AppearanceCatalog]. It travels in the PLAYER SPAWN, is stored in
## [code]character_progress.appearance[/code] and goes as base64 through the API.
## [br][br]
## [codeblock]
## byte 0  race        index in races + 1 (0 is not valid)
## byte 1  body        index in bodies
## byte 2  head        index in heads
## byte 3  hair        0 no hair; otherwise index in hairs + 1
## byte 4  beard       0 no beard; otherwise index in beards + 1
## byte 5  skin        index in skin_tones
## byte 6  hair_color  index in hair_colors (hair, beard and eyebrows)
## byte 7  bits 0–3: eyes, index in eye_colors; bits 4–7: marks, 0 no marks or index in marks + 1
## [/codeblock]
## [method validate] is the whole rule, the same one the Go platform applies when creating the
## character (with the rules exported by [ProgressionRulesExport] and the same cases,
## [code]tests/fixtures/progression/appearance_cases.json[/code]). When loading it, the zone
## replaces an invalid appearance with [method default_for]; the client does the same with another
## player's. It does not enter the [code]sim_hash[/code]: an unknown index already falls back to
## the default appearance. Shared: no clock; the randomness of [method random] is that of the
## generator passed to it.

## Encoded size.
const ENCODED_SIZE: int = 8
## Value of [member hair], [member beard] and [member marks] for "none".
const NONE: int = 0

## Index of the people + 1.
var race: int = 0
var body: int = 0
var head: int = 0
## 0 no hair; otherwise index + 1.
var hair: int = 0
## 0 no beard; otherwise index + 1.
var beard: int = 0
var skin: int = 0
var hair_color: int = 0
## Index of the eye color (0–15).
var eyes: int = 0
## 0 no marks; otherwise index + 1 (0–15).
var marks: int = 0


## The 8 B. Each field is written with its low bits (8, or 4 for [member eyes] and
## [member marks]): an appearance that passes [method validate] fits entirely.
func encode() -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(ENCODED_SIZE)
	bytes[0] = race & 0xFF
	bytes[1] = body & 0xFF
	bytes[2] = head & 0xFF
	bytes[3] = hair & 0xFF
	bytes[4] = beard & 0xFF
	bytes[5] = skin & 0xFF
	bytes[6] = hair_color & 0xFF
	bytes[7] = (eyes & 0x0F) | ((marks & 0x0F) << 4)
	return bytes


## Reads 8 B; null if they are not exactly 8. It does not check whether they are valid: that is
## [method validate].
static func decode(bytes: PackedByteArray) -> CharacterAppearance:
	if bytes.size() != ENCODED_SIZE:
		return null
	var appearance := CharacterAppearance.new()
	appearance.race = bytes[0]
	appearance.body = bytes[1]
	appearance.head = bytes[2]
	appearance.hair = bytes[3]
	appearance.beard = bytes[4]
	appearance.skin = bytes[5]
	appearance.hair_color = bytes[6]
	appearance.eyes = bytes[7] & 0x0F
	appearance.marks = bytes[7] >> 4
	return appearance


## true if valid for a character of realm [param realm] ([enum NetProtocol.Realm] code, the one in
## [code]claimed.realm[/code] and in [code]ValidateCreate[/code]) and of people [param race_id]
## (§7.2):
## [br]- [param race_id] exists, belongs to that realm and byte 0 is its index + 1 (the race goes
## in both places and they must match);
## [br]- each index is in the people's lists (and exists in the catalog);
## [br]- each part (head, hair, beard and marks) fits the body;
## [br]- a 0 for hair or beard only if the people allows it ([member RaceDefinition.allows_no_hair],
## [member RaceDefinition.allows_no_beard]); no marks is always valid.
func validate(catalog: AppearanceCatalog, realm: int, race_id: StringName) -> bool:
	if catalog == null:
		return false
	var realm_id: StringName = RealmCatalog.id_of_code(realm)
	if not RealmCatalog.is_realm(realm_id):
		return false
	var race_index: int = race - 1
	if race_index < 0 or race_index >= catalog.races.size():
		return false
	var definition: RaceDefinition = catalog.races[race_index]
	if definition == null or definition.id != race_id or definition.realm != realm_id:
		return false
	if not _is_allowed(definition.bodies, body, catalog.bodies.size()):
		return false
	if not _part_fits(definition.heads, catalog.heads, head, body):
		return false
	if hair == NONE:
		if not definition.allows_no_hair:
			return false
	elif not _part_fits(definition.hairs, catalog.hairs, hair - 1, body):
		return false
	if beard == NONE:
		if not definition.allows_no_beard:
			return false
	elif not _part_fits(definition.beards, catalog.beards, beard - 1, body):
		return false
	if marks != NONE and not _part_fits(definition.marks, catalog.marks, marks - 1, body):
		return false
	return (_is_allowed(definition.skin_tones, skin, catalog.skin_tones.size())
			and _is_allowed(definition.hair_colors, hair_color, catalog.hair_colors.size())
			and _is_allowed(definition.eye_colors, eyes, catalog.eye_colors.size()))


## A random valid appearance for people [param race_index] (index in
## [member AppearanceCatalog.races]): each field uniform among what the people allows and fits the
## chosen body (with "none" among the options when allowed). Null if the index does not exist. For
## the "Aleatorio" (Random) button in creation (UI-24) and tests.
static func random(catalog: AppearanceCatalog, race_index: int,
		rng: RandomNumberGenerator) -> CharacterAppearance:
	if catalog == null or race_index < 0 or race_index >= catalog.races.size():
		return null
	var definition: RaceDefinition = catalog.races[race_index]
	if definition == null:
		return null
	var options: Dictionary = _options(catalog, definition, _pick(rng, _existing(definition.bodies,
			catalog.bodies.size())))
	var appearance := CharacterAppearance.new()
	appearance.race = race_index + 1
	appearance.body = options[&"body"]
	for field: StringName in [&"head", &"hair", &"beard", &"marks", &"skin", &"hair_color", &"eyes"]:
		appearance.set(field, _pick(rng, options[field]))
	return appearance


## The default appearance of people [param race_index]: the first allowed item of each list, with
## hair and beard if compatible ones exist, and no marks. The zone uses it in place of an invalid
## appearance (§7.2). Null if the index does not exist.
static func default_for(catalog: AppearanceCatalog, race_index: int) -> CharacterAppearance:
	if catalog == null or race_index < 0 or race_index >= catalog.races.size():
		return null
	var definition: RaceDefinition = catalog.races[race_index]
	if definition == null:
		return null
	var bodies: PackedInt32Array = _existing(definition.bodies, catalog.bodies.size())
	var options: Dictionary = _options(catalog, definition, bodies[0] if not bodies.is_empty() else 0)
	var appearance := CharacterAppearance.new()
	appearance.race = race_index + 1
	appearance.body = options[&"body"]
	for field: StringName in [&"head", &"skin", &"hair_color", &"eyes"]:
		appearance.set(field, _first(options[field]))
	# With hair and beard if any is compatible (the first option is "none" when allowed).
	appearance.hair = _first_present(options[&"hair"])
	appearance.beard = _first_present(options[&"beard"])
	appearance.marks = NONE
	return appearance


## true if both appearances have the same 8 B.
func equals(other: CharacterAppearance) -> bool:
	return other != null and encode() == other.encode()


func _to_string() -> String:
	return "CharacterAppearance(%s)" % Marshalls.raw_to_base64(encode())


# --- Utilities ----------------------------------------------------------------------------------

static func _is_allowed(allowed: PackedInt32Array, index: int, size: int) -> bool:
	return index >= 0 and index < size and allowed.has(index)


static func _part_fits(allowed: PackedInt32Array, parts: Array[AppearancePart], index: int,
		body_index: int) -> bool:
	return (_is_allowed(allowed, index, parts.size()) and parts[index] != null
			and parts[index].fits_body(body_index))


## The indices of [param allowed] that exist in a list of [param size] entries.
static func _existing(allowed: PackedInt32Array, size: int) -> PackedInt32Array:
	var result := PackedInt32Array()
	for index: int in allowed:
		if index >= 0 and index < size:
			result.append(index)
	return result


## What can be chosen in each field with body [param body_index], already as the 8 B value (hair,
## beard and marks with +1 and "none" first when allowed).
static func _options(catalog: AppearanceCatalog, definition: RaceDefinition, body_index: int) -> Dictionary:
	var options: Dictionary = {&"body": body_index}
	options[&"head"] = AppearanceCatalog.fitting_indices(definition.heads, catalog.heads, body_index)
	options[&"hair"] = _with_none(AppearanceCatalog.fitting_indices(definition.hairs, catalog.hairs,
			body_index), definition.allows_no_hair)
	options[&"beard"] = _with_none(AppearanceCatalog.fitting_indices(definition.beards, catalog.beards,
			body_index), definition.allows_no_beard)
	options[&"marks"] = _with_none(AppearanceCatalog.fitting_indices(definition.marks, catalog.marks,
			body_index), true)
	options[&"skin"] = _existing(definition.skin_tones, catalog.skin_tones.size())
	options[&"hair_color"] = _existing(definition.hair_colors, catalog.hair_colors.size())
	options[&"eyes"] = _existing(definition.eye_colors, catalog.eye_colors.size())
	return options


## [param indices] + 1, with [constant NONE] first if [param none_allowed].
static func _with_none(indices: PackedInt32Array, none_allowed: bool) -> PackedInt32Array:
	var result := PackedInt32Array()
	if none_allowed:
		result.append(NONE)
	for index: int in indices:
		result.append(index + 1)
	return result


static func _pick(rng: RandomNumberGenerator, choices: PackedInt32Array) -> int:
	if choices.is_empty():
		return 0
	return choices[rng.randi_range(0, choices.size() - 1)]


static func _first(choices: PackedInt32Array) -> int:
	return choices[0] if not choices.is_empty() else 0


## The first option that is not "none"; [constant NONE] if there is none.
static func _first_present(choices: PackedInt32Array) -> int:
	for choice: int in choices:
		if choice != NONE:
			return choice
	return NONE
