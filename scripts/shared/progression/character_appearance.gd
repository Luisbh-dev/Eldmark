class_name CharacterAppearance
extends RefCounted
## La apariencia de un personaje en 8 B (docs/progresion.md §7.2, ART-19): índices sobre
## [AppearanceCatalog]. Viaja en el SPAWN de PLAYER, se guarda en [code]character_progress.appearance[/code]
## y va en base64 por la API.
## [br][br]
## [codeblock]
## byte 0  race        índice en races + 1 (0 no vale)
## byte 1  body        índice en bodies
## byte 2  head        índice en heads
## byte 3  hair        0 sin pelo; si no, índice en hairs + 1
## byte 4  beard       0 sin barba; si no, índice en beards + 1
## byte 5  skin        índice en skin_tones
## byte 6  hair_color  índice en hair_colors (pelo, barba y cejas)
## byte 7  bits 0–3: eyes, índice en eye_colors; bits 4–7: marks, 0 sin marcas o índice en marks + 1
## [/codeblock]
## [method validate] es la regla entera, la misma que aplica la plataforma en Go al crear el personaje
## (con las reglas exportadas por [ProgressionRulesExport] y los mismos casos,
## [code]tests/fixtures/progression/appearance_cases.json[/code]). La zona, al cargarlo, sustituye una
## apariencia que no vale por [method default_for]; el cliente hace lo mismo con la de otro jugador. No
## entra en el [code]sim_hash[/code]: un índice desconocido ya cae a la apariencia por defecto.
## Compartido: sin reloj; el azar de [method random] es el del generador que se le pasa.

## Tamaño codificado.
const ENCODED_SIZE: int = 8
## Valor de [member hair], [member beard] y [member marks] para «sin».
const NONE: int = 0

## Índice del pueblo + 1.
var race: int = 0
var body: int = 0
var head: int = 0
## 0 sin pelo; si no, índice + 1.
var hair: int = 0
## 0 sin barba; si no, índice + 1.
var beard: int = 0
var skin: int = 0
var hair_color: int = 0
## Índice del color de ojos (0–15).
var eyes: int = 0
## 0 sin marcas; si no, índice + 1 (0–15).
var marks: int = 0


## Los 8 B. Cada campo se escribe con sus bits bajos (8, o 4 para [member eyes] y [member marks]): una
## apariencia que pasa [method validate] cabe entera.
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


## Lee 8 B; null si no son exactamente 8. No mira si valen: eso es [method validate].
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


## true si vale para un personaje del reino [param realm] (código de [enum NetProtocol.Realm], el de
## [code]claimed.realm[/code] y de [code]ValidateCreate[/code]) y del pueblo [param race_id] (§7.2):
## [br]- [param race_id] existe, es de ese reino y el byte 0 es su índice + 1 (la raza va en los dos
## sitios y deben coincidir);
## [br]- cada índice está en las listas del pueblo (y existe en el catálogo);
## [br]- cada pieza (cabeza, pelo, barba y marcas) encaja con el cuerpo;
## [br]- un 0 de pelo o barba solo si el pueblo lo admite ([member RaceDefinition.allows_no_hair],
## [member RaceDefinition.allows_no_beard]); sin marcas vale siempre.
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


## Una apariencia válida al azar para el pueblo [param race_index] (índice en
## [member AppearanceCatalog.races]): cada campo, uniforme entre lo que el pueblo permite y encaja con el
## cuerpo elegido (con «sin» entre las opciones cuando se admite). Null si el índice no existe. Para el
## botón «Aleatorio» de la creación (UI-24) y las pruebas.
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


## La apariencia por defecto del pueblo [param race_index]: lo primero que permite de cada lista, con
## pelo y barba si los hay compatibles, y sin marcas. La usa la zona en lugar de una apariencia que no
## vale (§7.2). Null si el índice no existe.
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
	# Con pelo y barba si hay alguno compatible (la primera opción es «sin» cuando se admite).
	appearance.hair = _first_present(options[&"hair"])
	appearance.beard = _first_present(options[&"beard"])
	appearance.marks = NONE
	return appearance


## true si las dos apariencias tienen los mismos 8 B.
func equals(other: CharacterAppearance) -> bool:
	return other != null and encode() == other.encode()


func _to_string() -> String:
	return "CharacterAppearance(%s)" % Marshalls.raw_to_base64(encode())


# --- Utilidades ---------------------------------------------------------------------------------

static func _is_allowed(allowed: PackedInt32Array, index: int, size: int) -> bool:
	return index >= 0 and index < size and allowed.has(index)


static func _part_fits(allowed: PackedInt32Array, parts: Array[AppearancePart], index: int,
		body_index: int) -> bool:
	return (_is_allowed(allowed, index, parts.size()) and parts[index] != null
			and parts[index].fits_body(body_index))


## Los índices de [param allowed] que existen en una lista de [param size] entradas.
static func _existing(allowed: PackedInt32Array, size: int) -> PackedInt32Array:
	var result := PackedInt32Array()
	for index: int in allowed:
		if index >= 0 and index < size:
			result.append(index)
	return result


## Lo que se puede elegir en cada campo con el cuerpo [param body_index], ya en el valor de los 8 B (pelo,
## barba y marcas con +1 y «sin» delante cuando se admite).
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


## [param indices] + 1, con [constant NONE] delante si [param none_allowed].
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


## La primera opción que no es «sin»; [constant NONE] si no hay ninguna.
static func _first_present(choices: PackedInt32Array) -> int:
	for choice: int in choices:
		if choice != NONE:
			return choice
	return NONE
