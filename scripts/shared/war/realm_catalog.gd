class_name RealmCatalog
extends RefCounted
## Catálogo compartido de reinos y bandos (docs/mundo.md, «Colores de bando»).
## [br][br]
## Fuente única de los tres reinos jugables y del bando neutral de los Huecos. Por cada uno: id
## ([StringName]), código de red, nombre en español, color de bando y ruta del emblema. También
## guarda los reinos admitidos en cada zona. [Zones], [NetZones], [NetProtocol], [ServerAuth] y
## los estandartes leen de aquí, así que añadir o cambiar un bando se hace solo en este archivo.
## [br][br]
## Los códigos de red son los de [enum NetProtocol.Realm] (1 Vardheim, 2 Solmarch, 3 Askarra).
## El código [constant NEUTRAL_CODE] (0) es el bando neutral de los Huecos: es el mismo valor que
## [constant NetProtocol.Realm.NONE], que en el HELLO significa «sin reino» y se rechaza, pero un
## jugador nunca es neutral, así que no hay ambigüedad.
## [br][br]
## No depende de nada de [code]scripts/client/[/code] ni de [code]scripts/server/[/code].

## Ids de los bandos.
const VARDHEIM: StringName = &"vardheim"
const SOLMARCH: StringName = &"solmarch"
const ASKARRA: StringName = &"askarra"
## Bando neutral: los Huecos, soldados no muertos de la vieja guarnición de Eld.
const HUECOS: StringName = &"huecos"

## Colores de bando (mundo.md): azul hielo, oro, carmesí y gris hueso.
const VARDHEIM_COLOR: Color = Color("#7EC8E8")
const SOLMARCH_COLOR: Color = Color("#E9C341")
const ASKARRA_COLOR: Color = Color("#C3242F")
const HUECOS_COLOR: Color = Color("#BDB6A6")

## Código de red del bando neutral.
const NEUTRAL_CODE: int = 0
## Ruta del emblema de un bando, con [code]%s[/code] en lugar del id. Los SVG los aporta el arte
## (UI-02); hasta entonces el archivo puede no existir, así que quien lo cargue debe comprobarlo.
const EMBLEM_PATH_FORMAT: String = "res://assets/emblems/%s.svg"

## Los tres reinos jugables, en orden de código de red.
const REALM_IDS: Array[StringName] = [VARDHEIM, SOLMARCH, ASKARRA]
## Todos los bandos: los tres reinos y el neutral.
const FACTION_IDS: Array[StringName] = [VARDHEIM, SOLMARCH, ASKARRA, HUECOS]

## Id -> {code, name, color}.
const _FACTIONS: Dictionary = {
	VARDHEIM: {"code": NetProtocol.Realm.VARDHEIM, "name": "Vardheim", "color": VARDHEIM_COLOR},
	SOLMARCH: {"code": NetProtocol.Realm.SOLMARCH, "name": "Solmarch", "color": SOLMARCH_COLOR},
	ASKARRA: {"code": NetProtocol.Realm.ASKARRA, "name": "Askarra", "color": ASKARRA_COLOR},
	HUECOS: {"code": NEUTRAL_CODE, "name": "Huecos", "color": HUECOS_COLOR},
}

## Zona -> reinos admitidos (ids). Una zona que no figura aquí no tiene restricción registrada.
## El Vado Gris es la frontera entre Vardheim y Solmarch (mundo.md): Askarra no entra.
const _ZONE_REALMS: Dictionary = {
	&"vado_gris": [VARDHEIM, SOLMARCH],
	&"test_world": [VARDHEIM, SOLMARCH, ASKARRA],
}


## true si [param id] es un reino jugable (no el bando neutral).
static func is_realm(id: StringName) -> bool:
	return REALM_IDS.has(id)


## true si [param id] es un bando del catálogo: un reino o los Huecos.
static func has_faction(id: StringName) -> bool:
	return _FACTIONS.has(id)


## true si [param code] es el código de red de un reino jugable (1 a 3).
static func is_realm_code(code: int) -> bool:
	return is_realm(id_of_code(code))


## Códigos de red de los reinos jugables, en orden.
static func realm_codes() -> Array[int]:
	var codes: Array[int] = []
	for id: StringName in REALM_IDS:
		codes.append(code_of(id))
	return codes


## Código de red de [param id], o -1 si el bando no existe.
static func code_of(id: StringName) -> int:
	var entry: Dictionary = _FACTIONS.get(id, {})
	return entry.get("code", -1)


## Id del bando con código de red [param code] (0 = los Huecos), o una cadena vacía si no hay
## ninguno.
static func id_of_code(code: int) -> StringName:
	for id: StringName in FACTION_IDS:
		if code_of(id) == code:
			return id
	return &""


## Nombre en español de [param id] («Vardheim», «Huecos»...), o una cadena vacía si no existe.
static func display_name(id: StringName) -> String:
	var entry: Dictionary = _FACTIONS.get(id, {})
	return entry.get("name", "")


## Color de bando de [param id]; blanco si el bando no existe.
static func color_of(id: StringName) -> Color:
	var entry: Dictionary = _FACTIONS.get(id, {})
	return entry.get("color", Color.WHITE)


## Ruta prevista del emblema de [param id] (ver [constant EMBLEM_PATH_FORMAT]), o una cadena
## vacía si el bando no existe. El archivo puede no existir todavía.
static func emblem_path(id: StringName) -> String:
	if not has_faction(id):
		return ""
	return EMBLEM_PATH_FORMAT % String(id)


## Reinos admitidos en [param zone_id] como ids. Vacío si la zona no tiene restricción
## registrada (zona desconocida): quien pregunta decide qué hacer entonces.
static func allowed_realm_ids(zone_id: StringName) -> Array[StringName]:
	var result: Array[StringName] = []
	result.assign(_ZONE_REALMS.get(zone_id, []))
	return result


## Zonas con reinos admitidos registrados, ordenadas.
static func zones_with_realms() -> Array[StringName]:
	var ids: Array[StringName] = []
	ids.assign(_ZONE_REALMS.keys())
	ids.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	return ids
