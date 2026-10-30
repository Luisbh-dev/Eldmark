class_name NetEntity
extends RefCounted
## Entidad replicada por el servidor (docs/red.md, sección 9.1): un jugador (y, desde la fase 4,
## PNJ, proyectiles y estructuras).
## [br][br]
## Guarda lo que hace falta para replicarla: el id de red que asigna [NetEntityRegistry], el
## tipo, el reino, el tick de alta, el peer dueño, el nombre, los flags, su nodo y el contador de
## teletransporte. Sabe escribir su registro del snapshot sin crear objetos
## ([method encode_record]) y su mensaje ENTITY_SPAWN ([method encode_spawn]).
## [br][br]
## También guarda lo que se ve de su vida en los snapshots: la vida cuantizada del registro
## ([member health_q]) y el bloque extra propio ([member health], [member max_health],
## [member status] y [member respawn_tick]). Quien lleva la vida (el [code]Combatant[/code] del
## combate) los actualiza cada tick con [method set_health_view]; mientras nadie lo haga, la
## entidad está sana.
## [br][br]
## [member action] es el byte de acción del registro ([method ActionWire.encode]); lo
## actualiza cada tick el mismo código que lleva la vida.

## La ven todos los jugadores de la zona, sin pasar por la [InterestPolicy] (fortalezas, puertas).
const FLAG_ALWAYS_RELEVANT: int = 1 << 0
## Vida (y vida máxima) que se anuncia mientras nadie la actualiza: la de
## [code]CombatRules.health_max[/code].
const DEFAULT_HEALTH: int = 1000

## Id de red (1..65535) que asigna [NetEntityRegistry].
var net_id: int
## [enum NetProtocol.EntityKind].
var kind: int
## Código de [enum NetProtocol.Realm].
var realm: int
## Tick en el que se dio de alta.
var spawn_tick: int
## Id del peer dueño (0 si no lo controla ningún cliente).
var owner_peer: int = 0
var display_name: String
## Personal del juego (moderador o más, el rol de la reclamación; docs/plataforma.md §5.4): su ENTITY_SPAWN
## lleva el bit [constant NetMessages.SPAWN_FLAG_STAFF] para la etiqueta (SOC-14). Siempre false sin plataforma.
var is_staff: bool = false
## Marcado por un comando de GM que lo mueve, lo cura o lo muestra (docs/progresion.md §6.2; lo ponen
## [code]/gm teleport[/code], [code]/gm visible[/code] y los DEBUG_COMMAND 1, 2 y 4, plataforma.md P7b): mientras
## dura no entra en la lista de capturas ni cobra méritos ni PNJ. La reaparición lo quita (plataforma.md P6).
var gm_forced: bool = false
## Combinación de [constant FLAG_ALWAYS_RELEVANT].
var flags: int = 0
## Nodo de la entidad en el mundo del servidor: un [PlayerCharacter] si es un jugador.
var node: Node3D
## Sube (módulo 4) con cada teletransporte, para que el cliente no interpole el salto.
var teleport_counter: int = 0
## Vida cuantizada que lleva su registro del snapshot ([method EntityRecord.quantize_health]).
var health_q: int = EntityRecord.HEALTH_Q_FULL
## Vida, vida máxima, bits de estado ([constant NetMessages.STATUS_IN_COMBAT] y compañía) y tick
## de reaparición del bloque extra del snapshot propio.
var health: int = DEFAULT_HEALTH
var max_health: int = DEFAULT_HEALTH
var status: int = 0
var respawn_tick: int = 0
## Byte de acción del registro de red ([method ActionWire.encode]); 0 = sin datos.
var action: int = 0
## PNJ: id de su definición en el catálogo de PNJ, que viaja en su ENTITY_SPAWN para que el cliente
## elija modelo, tabardo y barra de jefe (0 = sin definición).
var npc_def_id: int = 0
## STRUCTURE: id de su definición (ASCII, el de [member FortressDefinition.id]) y el estado vivo de la
## fortaleza, que el [code]FortressController[/code] mantiene al día. Su ENTITY_SPAWN lleva el estado
## completo en el momento del alta.
var definition_id: String = ""
var fortress_state: FortressState = null
## PLAYER (protocolo 7, docs/progresion.md §7.3): nivel del personaje (1 a 40; 0 = sin progreso, como un jugador
## falso) y los 8 B de su [CharacterAppearance] (vacío = sin apariencia). Los pone el progreso en el alta y al
## subir de nivel; viajan en su ENTITY_SPAWN (el nivel, solo hacia su reino: ver [method encode_spawn]).
var level: int = 0
var appearance: PackedByteArray = PackedByteArray()


## Posición global de la entidad (los pies, si es un jugador).
func get_position() -> Vector3:
	if not is_instance_valid(node):
		return Vector3.ZERO
	return node.global_position if node.is_inside_tree() else node.position


## El [PlayerCharacter] de la entidad, o null si no es un jugador.
func get_character() -> PlayerCharacter:
	return node as PlayerCharacter if is_instance_valid(node) else null


## Actualiza lo que los snapshots muestran de la vida de la entidad: [param new_health] y
## [param new_max_health] (la vida cuantizada del registro sale de ellas), los bits de
## [param new_status] y el tick de reaparición ([param new_respawn_tick], 0 si está viva).
func set_health_view(new_health: int, new_max_health: int, new_status: int,
		new_respawn_tick: int) -> void:
	health = new_health
	max_health = new_max_health
	status = new_status
	respawn_tick = new_respawn_tick
	health_q = EntityRecord.quantize_health(new_health, new_max_health)


## Escribe el registro de la entidad (21 B, [constant EntityRecord.SIZE]) en [param bytes] a
## partir de [param offset], sin crear objetos si es un jugador. Amplía el búfer si hace falta.
func encode_record(bytes: PackedByteArray, offset: int) -> void:
	var character: PlayerCharacter = get_character()
	if character != null:
		EntityRecord.encode_character(bytes, offset, net_id, character, teleport_counter, action,
				health_q)
		return
	# Entidades sin personaje (PNJ simples): posición y giro del nodo, sin velocidad.
	var record := EntityRecord.new()
	record.net_id = net_id
	record.kind = kind
	record.position = get_position()
	record.yaw = node.rotation.y if is_instance_valid(node) else 0.0
	var teleport_bits: int = teleport_counter & EntityRecord.TELEPORT_MASK
	record.flags = (teleport_bits << EntityRecord.TELEPORT_SHIFT) | EntityRecord.FLAG_GROUNDED
	record.health_q = health_q
	record.action = action
	record.encode_into(bytes, offset)


## Mensaje ENTITY_SPAWN de la entidad con su estado actual, que se da como el estado «tras
## [param tick]». [param for_owner] pone el bit «es tu personaje» (el SPAWN propio), que lleva el
## [PlayerState] entero; el de una entidad ajena solo lleva lo que ya enseña su registro de 21 B
## (posición, velocidad, giro, suelo, acción, las dos armas y la ranura activa): ni su resistencia
## exacta, agotamiento, enfriamiento de la parada, búfer, controles, botones mantenidos,
## reutilizaciones, cargas ni efectos de movimiento (docs/combate.md, secciones 1 y 6, y
## docs/habilidades.md, sección 5.2).
## [br][br]
## Un jugador lleva además su apariencia y su nivel (protocolo 7, docs/progresion.md §7.3); el nivel real solo
## si es el SPAWN propio o [param receiver_realm] (el código de [enum NetProtocol.Realm] de quien lo recibe) es
## el de la entidad, y 0 si no: el nivel del enemigo no cruza (social.md §1). Por eso quien reparte SPAWN los
## codifica por reino receptor.
func encode_spawn(tick: int, for_owner: bool, receiver_realm: int = NetProtocol.Realm.NONE) -> PackedByteArray:
	if kind == NetProtocol.EntityKind.STRUCTURE:
		if fortress_state == null:
			return PackedByteArray()
		return NetMessages.EntitySpawn.for_fortress(net_id, tick, definition_id,
				fortress_state).encode()
	var spawn := NetMessages.EntitySpawn.new()
	spawn.net_id = net_id
	spawn.kind = kind
	spawn.spawn_tick = tick
	spawn.realm = realm
	spawn.is_yours = for_owner
	spawn.teleport_counter = teleport_counter & EntityRecord.TELEPORT_MASK
	spawn.is_staff = is_staff
	spawn.display_name = display_name
	spawn.npc_def_id = npc_def_id
	if kind == NetProtocol.EntityKind.PLAYER:
		spawn.appearance = appearance
		spawn.level = level if for_owner or (receiver_realm == realm and realm != NetProtocol.Realm.NONE) else 0
	var character: PlayerCharacter = get_character()
	if character != null:
		spawn.state = character.get_state()
		if not for_owner:
			_hide_private_state(spawn.state)
	else:
		var state := PlayerState.new()
		state.position = get_position()
		state.yaw = PlayerState.to_f32(node.rotation.y) if is_instance_valid(node) else 0.0
		state.grounded = true
		spawn.state = state
	return spawn.encode()


# Deja en [param state] solo lo público de un personaje ajeno: el combate vuelve a los valores
# iniciales de sus armas (resistencia llena, sin banderas, búfer, controles, parada, reutilizaciones,
# cargas, consumible ni ranuras de movimiento) salvo la acción en curso, que el registro de 21 B ya
# muestra, y las armas: la de la otra ranura y la ranura activa (bit 0 de combat_flags2) se ven
# (docs/habilidades.md, sección 5.2). Se borran los botones del último tick y los contadores de salto.
static func _hide_private_state(state: PlayerState) -> void:
	var own: CombatState = state.combat
	var public := CombatState.initial(CombatCatalog.rules(), own.weapon_id, own.alt_weapon_id)
	public.combat_flags2 = own.combat_flags2 & CombatState.FLAG2_SECOND_SLOT
	public.action = own.action
	if own.action != CombatState.Action.NONE:
		public.action_id = own.action_id
		public.action_tick = own.action_tick
	state.combat = public
	state.prev_buttons = 0
	state.coyote_ticks = 0
	state.jump_buffer_ticks = 0
