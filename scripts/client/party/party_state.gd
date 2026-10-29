class_name PartyState
extends RefCounted
## Lo que el cliente sabe de su grupo (SOC-06 y SOC-08, docs/social.md, secciones 3 y 12.4): quiénes son los
## miembros y quién manda (PARTY_ROSTER), cómo están (PARTY_STATUS, a 2 Hz y aunque estén lejos) y las
## invitaciones que tiene delante (PARTY_INVITATION). Es solo datos: lo alimenta [NetClient] con los
## mensajes del servidor y lo pintan [PartyFrames], [PartyInvitePrompt] y [Nameplates].
## [br][br]
## [b]Orden y estado.[/b] Los miembros van en el orden de la lista del servidor (por antigüedad). Un miembro
## nuevo no tiene estado hasta el siguiente PARTY_STATUS (como mucho medio segundo): [member Member.has_status]
## lo dice y los marcos lo enseñan atenuado y sin datos. Un PARTY_STATUS de alguien que no está en la lista (un
## mensaje atrasado) se ignora.
## [br][br]
## [b]Invitaciones.[/b] Hay una por quien invitó (una nueva del mismo jugador sustituye a la anterior); se
## quitan cuando el servidor dice que han caducado o se han cancelado y también por su cuenta al pasar el tick
## de caducidad ([method prune_expired]), por si el aviso se pierde o la interfaz va por delante. La que se
## enseña es la más antigua que siga vigente.

## Cambió la lista de miembros o quién manda (también al entrar o salir de un grupo).
signal roster_changed
## Llegó un PARTY_STATUS: cambió la vida, la resistencia o la posición de algún miembro.
signal status_changed
## Cambió el conjunto de invitaciones pendientes.
signal invitation_changed


## Un miembro del grupo.
class Member:
	extends RefCounted

	var net_id: int = 0
	var display_name: String = ""
	## Vida cuantizada del registro (0 muerto, de 1 a 255 vivo).
	var health_q: int = 255
	var stamina_q: int = PartyRules.STAMINA_Q_MAX
	## Bits de [constant NetMessages.STATUS_IN_COMBAT] y compañía.
	var status: int = 0
	var position: Vector3 = Vector3.ZERO
	## false hasta que llega el primer PARTY_STATUS con este miembro.
	var has_status: bool = false

	func is_dead() -> bool:
		return has_status and (status & NetMessages.STATUS_DEAD) != 0

	func is_in_combat() -> bool:
		return has_status and (status & NetMessages.STATUS_IN_COMBAT) != 0

	func get_health_fraction() -> float:
		return PartyRules.health_fraction(health_q)

	func get_stamina_fraction() -> float:
		return PartyRules.stamina_fraction(stamina_q)


## Una invitación al grupo de otro jugador.
class Invitation:
	extends RefCounted

	## Nombre canónico de quien invita.
	var inviter: String = ""
	## Tick del servidor en el que caduca.
	var expire_tick: int = 0


var _members: Array[Member] = []
var _leader_id: int = 0
var _invitations: Array[Invitation] = []


# --- Consultas --------------------------------------------------------------------------------

## true si el jugador está en un grupo.
func is_in_party() -> bool:
	return not _members.is_empty()


## Los miembros, en el orden de la lista del servidor (el líder no tiene por qué ser el primero).
func get_members() -> Array[Member]:
	return _members.duplicate()


func get_member_count() -> int:
	return _members.size()


## El miembro con ese id de red, o null.
func get_member(net_id: int) -> Member:
	for member: Member in _members:
		if member.net_id == net_id:
			return member
	return null


func has_member(net_id: int) -> bool:
	return get_member(net_id) != null


## Id de red del líder (0 si no hay grupo).
func get_leader_id() -> int:
	return _leader_id


func is_leader(net_id: int) -> bool:
	return net_id != 0 and net_id == _leader_id


## Las invitaciones pendientes, de la más antigua a la más nueva.
func get_invitations() -> Array[Invitation]:
	return _invitations.duplicate()


## La invitación que se enseña ahora (la más antigua vigente), o null.
func get_current_invitation() -> Invitation:
	return _invitations[0] if not _invitations.is_empty() else null


# --- Mensajes del servidor --------------------------------------------------------------------

## Aplica una lista de miembros: sustituye a la anterior conservando el estado de quien sigue. Una lista vacía
## es «ya no estás en un grupo».
func apply_roster(roster: NetMessages.PartyRoster) -> void:
	var previous: Dictionary[int, Member] = {}
	for member: Member in _members:
		previous[member.net_id] = member
	var fresh: Array[Member] = []
	for entry: NetMessages.PartyRoster.Member in roster.members:
		var member: Member = previous.get(entry.net_id)
		if member == null:
			member = Member.new()
			member.net_id = entry.net_id
		member.display_name = entry.display_name
		fresh.append(member)
	_members = fresh
	_leader_id = roster.get_leader_id()
	roster_changed.emit()


## Aplica el estado compacto de los miembros.
func apply_status(status: NetMessages.PartyStatus) -> void:
	var changed: bool = false
	for entry: NetMessages.PartyStatus.MemberStatus in status.members:
		var member: Member = get_member(entry.net_id)
		if member == null:
			continue
		member.health_q = entry.health_q
		member.stamina_q = entry.stamina_q
		member.status = entry.status
		member.position = entry.position
		member.has_status = true
		changed = true
	if changed:
		status_changed.emit()


## Aplica una invitación nueva, o que ha caducado o se ha cancelado.
func apply_invitation(message: NetMessages.PartyInvitation) -> void:
	var key: String = NameRules.normalize_key(message.inviter)
	var index: int = _index_of(key)
	if message.state == NetMessages.PartyInvitation.State.OFFERED:
		var invitation := Invitation.new()
		invitation.inviter = message.inviter
		invitation.expire_tick = message.tick
		if index >= 0:
			_invitations.remove_at(index)
		_invitations.append(invitation)
		invitation_changed.emit()
	elif index >= 0:
		_invitations.remove_at(index)
		invitation_changed.emit()


## Quita la invitación de [param inviter] (el jugador ya ha respondido). Devuelve true si estaba.
func remove_invitation(inviter: String) -> bool:
	var index: int = _index_of(NameRules.normalize_key(inviter))
	if index < 0:
		return false
	_invitations.remove_at(index)
	invitation_changed.emit()
	return true


## Quita las invitaciones cuyo tick de caducidad ya pasó ([param server_tick] es el tick estimado del
## servidor). Devuelve cuántas quitó.
func prune_expired(server_tick: int) -> int:
	var removed: int = 0
	for invitation: Invitation in _invitations.duplicate():
		if invitation.expire_tick <= server_tick:
			_invitations.erase(invitation)
			removed += 1
	if removed > 0:
		invitation_changed.emit()
	return removed


## Olvida todo (sesión nueva o terminada).
func clear() -> void:
	var had_party: bool = not _members.is_empty()
	var had_invitations: bool = not _invitations.is_empty()
	_members.clear()
	_leader_id = 0
	_invitations.clear()
	if had_party:
		roster_changed.emit()
	if had_invitations:
		invitation_changed.emit()


func _index_of(key: String) -> int:
	for i: int in _invitations.size():
		if NameRules.normalize_key(_invitations[i].inviter) == key:
			return i
	return -1
