class_name PartyState
extends RefCounted
## What the client knows about its party (SOC-06 and SOC-08, docs/social.md, sections 3 and 12.4): who the
## members are and who leads (PARTY_ROSTER), how they are doing (PARTY_STATUS, at 2 Hz and even if they are far away) and the
## invitations in front of it (PARTY_INVITATION). It is data only: it is fed by [NetClient] with the
## server's messages and drawn by [PartyFrames], [PartyInvitePrompt] and [Nameplates].
## [br][br]
## [b]Order and status.[/b] Members go in the order of the server's list (by seniority). A new
## member has no status until the next PARTY_STATUS (half a second at most): [member Member.has_status]
## says so and the frames show them dimmed and without data. A PARTY_STATUS from someone not in the list (a
## late message) is ignored.
## [br][br]
## [b]Invitations.[/b] There is one per inviter (a new one from the same player replaces the previous one); they are
## removed when the server says they have expired or been canceled and also on their own when the expiry
## tick passes ([method prune_expired]), in case the notice is lost or the UI is ahead. The one
## shown is the oldest that is still valid.

## The member list or who leads changed (also on joining or leaving a party).
signal roster_changed
## A PARTY_STATUS arrived: the health, stamina or position of some member changed.
signal status_changed
## The set of pending invitations changed.
signal invitation_changed


## A party member.
class Member:
	extends RefCounted

	var net_id: int = 0
	var display_name: String = ""
	## Quantized health from the record (0 dead, 1 to 255 alive).
	var health_q: int = 255
	var stamina_q: int = PartyRules.STAMINA_Q_MAX
	## Bits of [constant NetMessages.STATUS_IN_COMBAT] and company.
	var status: int = 0
	var position: Vector3 = Vector3.ZERO
	## false until the first PARTY_STATUS with this member arrives.
	var has_status: bool = false

	func is_dead() -> bool:
		return has_status and (status & NetMessages.STATUS_DEAD) != 0

	func is_in_combat() -> bool:
		return has_status and (status & NetMessages.STATUS_IN_COMBAT) != 0

	func get_health_fraction() -> float:
		return PartyRules.health_fraction(health_q)

	func get_stamina_fraction() -> float:
		return PartyRules.stamina_fraction(stamina_q)


## An invitation to another player's party.
class Invitation:
	extends RefCounted

	## Canonical name of the inviter.
	var inviter: String = ""
	## Server tick at which it expires.
	var expire_tick: int = 0


var _members: Array[Member] = []
var _leader_id: int = 0
var _invitations: Array[Invitation] = []


# --- Queries ----------------------------------------------------------------------------------

## true if the player is in a party.
func is_in_party() -> bool:
	return not _members.is_empty()


## The members, in the order of the server's list (the leader need not be the first).
func get_members() -> Array[Member]:
	return _members.duplicate()


func get_member_count() -> int:
	return _members.size()


## The member with that network id, or null.
func get_member(net_id: int) -> Member:
	for member: Member in _members:
		if member.net_id == net_id:
			return member
	return null


func has_member(net_id: int) -> bool:
	return get_member(net_id) != null


## Network id of the leader (0 if there is no party).
func get_leader_id() -> int:
	return _leader_id


func is_leader(net_id: int) -> bool:
	return net_id != 0 and net_id == _leader_id


## The pending invitations, from oldest to newest.
func get_invitations() -> Array[Invitation]:
	return _invitations.duplicate()


## The invitation shown now (the oldest valid one), or null.
func get_current_invitation() -> Invitation:
	return _invitations[0] if not _invitations.is_empty() else null


# --- Server messages --------------------------------------------------------------------------

## Applies a member list: replaces the previous one while keeping the status of whoever remains. An empty list
## means "you are no longer in a party".
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


## Applies the members' compact status.
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


## Applies a new invitation, or one that has expired or been canceled.
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


## Removes the invitation from [param inviter] (the player has already responded). Returns true if it was there.
func remove_invitation(inviter: String) -> bool:
	var index: int = _index_of(NameRules.normalize_key(inviter))
	if index < 0:
		return false
	_invitations.remove_at(index)
	invitation_changed.emit()
	return true


## Removes the invitations whose expiry tick has passed ([param server_tick] is the estimated server
## tick). Returns how many it removed.
func prune_expired(server_tick: int) -> int:
	var removed: int = 0
	for invitation: Invitation in _invitations.duplicate():
		if invitation.expire_tick <= server_tick:
			_invitations.erase(invitation)
			removed += 1
	if removed > 0:
		invitation_changed.emit()
	return removed


## Forgets everything (new or ended session).
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
