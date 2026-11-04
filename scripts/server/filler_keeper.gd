class_name FillerKeeper
extends RefCounted
## The filler fake players of a zone with [code]--max-realm-diff[/code] (GUE-42; docs/fortress.md,
## section 7): the automatic-realm fakes that fill in the short side and withdraw when
## real people join. It keeps track of which ones they are and applies the [RealmBalance] rules; it does not know how to create or remove
## players, that is done by [member creator] and [member remover] ([ServerMain] wires them to [ZoneServer]).
## [br][br]
## [b]The exact rule[/b] (with [param budget] = [code]--fake-players[/code]):
## [br]1. On startup, [ServerMain] creates the whole quota, placing each fake in the realm with the lowest total
## (people plus filler); on a tie, the one with the lowest code. Without people it is the usual round-robin split.
## [br]2. A person joins realm [i]r[/i]: if the total of [i]r[/i] (with them) becomes greater than the
## smallest of the zone's other realms and [i]r[/i] has filler fakes, the oldest one of [i]r[/i] is withdrawn:
## one for each person who joins the long side. If [i]r[/i] was the short side (or tied), the person
## takes a slot and nobody is withdrawn.
## [br]3. A person leaves [i]r[/i]: if the total of [i]r[/i] falls below the largest of the others and the
## live filler does not reach the quota, a new fake joins [i]r[/i].
## [br]4. The HELLO of a person of [i]r[/i] arrives with the server full only because of filler (GUE-43; decided by
## [ZoneServer], which only counts as occupied slots the people and the fakes that are not filler): a fake
## [b]sets aside[/b] its slot for them ([method reserve_seat]), but does not leave yet: it leaves when that person enters the world
## ([method on_person_joined]), and then it is the oldest one of the realm that [method RealmBalance.realm_to_yield_seat] gives
## with what exists at that moment. It counts as the one rule 2 withdraws (one per person). If the person leaves without having entered
## (drops the connection or never finishes loading), the reserved slot is released ([method release_seat]) and the filler has not
## moved: no additions or removals for anyone. While someone is loading into a reserved slot, the server has one player
## too many (them and the fake that cedes the slot; [method reserved_count] says how many there are), and only filler that has not reserved
## its slot can cede it to another HELLO.
## [br]5. Nothing else removes or adds fakes. Filler does not count toward rejecting anyone ([RealmBalance.exceeds]), nor
## toward filling the server.
## [br]6. [b]Whom to withdraw[/b] (review of the abilities integration): the oldest one of the realm that is
## [b]calm[/b] ([member calm_check]: neither knocked down nor lifting or finishing off anyone; dead and waiting to respawn
## also counts). If none is, the oldest. The removal of the filler being withdrawn is never a death: [member remover]
## removes it without DEATH or KILL even if it is knocked down ([method ZoneServer.retire_filler]). A person joining does not
## add a death to one side and a removal to the other, nor cut off a lift or an execution if there is someone to withdraw without doing so.
## [br][br]
## [ZoneServer] calls [method on_person_joined], [method on_person_left], [method reserve_seat] and
## [method release_seat] ([method ZoneServer.set_filler_keeper]) and notifies it of each fake that is removed
## ([method forget]).
## [br][br]
## Server only.

## [code](realm: int) -> int[/code]: creates a fake player in the realm and returns its network id (or -1).
var creator: Callable = Callable()
## [code](net_id: int) -> void[/code]: removes the fake player (without a death even if knocked down: rule 6).
var remover: Callable = Callable()
## [code](net_id: int) -> bool[/code]: true if withdrawing the fake now cuts nothing off (rule 6: neither knocked down nor lifting or
## finishing off). Without it, all of them are.
var calm_check: Callable = Callable()

var _allowed: PackedInt32Array = PackedInt32Array()
var _budget: int = 0
# () -> PackedInt32Array: the people in each realm right now.
var _persons_source: Callable = Callable()
# Live filler, oldest to newest, and the realm of each.
var _ids: Array[int] = []
var _realm_of: Dictionary[int, int] = {}
# People (peer_id) for whom the filler has set aside a slot and who are not in the world yet, with their realm.
var _seated: Dictionary[int, int] = {}


## [param allowed] are the zone's realms (empty = all three), [param budget] the filler quota and
## [param persons_source] an argument-less [Callable] with the count of people per realm.
func _init(allowed: PackedInt32Array, budget: int, persons_source: Callable) -> void:
	_allowed = allowed
	_budget = maxi(budget, 0)
	_persons_source = persons_source


## The realm the next filler fake has to join (0 if none competes).
func next_realm() -> int:
	return RealmBalance.realm_for_new_filler(_persons(), filler_counts(), _allowed)


## Records that fake [param net_id] of realm [param realm] is filler.
func track(net_id: int, realm: int) -> void:
	if net_id <= 0 or _realm_of.has(net_id):
		return
	_ids.append(net_id)
	_realm_of[net_id] = realm


## Stops counting [param net_id] as filler (it was removed for another reason).
func forget(net_id: int) -> void:
	_ids.erase(net_id)
	_realm_of.erase(net_id)


## true if [param net_id] is filler.
func is_filler(net_id: int) -> bool:
	return _realm_of.has(net_id)


## Live filler fakes.
func filler_count() -> int:
	return _ids.size()


## Filler fakes of each realm (Vardheim, Solmarch, Askarra).
func filler_counts() -> PackedInt32Array:
	var counts: PackedInt32Array = RealmBalance.empty_counts()
	for realm: int in _realm_of.values():
		if realm >= 1 and realm <= RealmBalance.REALM_COUNT:
			counts[realm - 1] += 1
	return counts


## A person has joined [param realm] (the people count already includes them): withdraws a filler fake if due.
## Returns true if it withdrew one. If the filler had set aside a slot when their HELLO arrived ([method reserve_seat]
## with the same [param peer_id]), the fake that cedes it is withdrawn now: the oldest one of the realm that gives
## [method RealmBalance.realm_to_yield_seat] (counting them), even if it is not of their realm. Otherwise, rule 2.
func on_person_joined(realm: int, peer_id: int = 0) -> bool:
	if _seated.erase(peer_id):
		# Without counting them (realm_to_yield_seat adds them), and on a copy: the source may hand out its own array.
		var persons: PackedInt32Array = _persons().duplicate()
		if realm >= 1 and realm <= persons.size():
			persons[realm - 1] = maxi(persons[realm - 1] - 1, 0)
		var from_realm: int = RealmBalance.realm_to_yield_seat(persons, filler_counts(), realm)
		return from_realm > 0 and _retire_oldest_of(from_realm)
	if not RealmBalance.should_retire_on_join(_persons(), filler_counts(), _allowed, realm):
		return false
	return _retire_oldest_of(realm)


## The HELLO of person [param peer_id] of [param realm] arrives with the server full: the filler sets aside a slot for them
## (GUE-43). It does not withdraw anyone yet: the fake that cedes it leaves when they enter the world
## ([method on_person_joined]); if they leave before, [method release_seat]. Returns false if no unreserved filler remains
## or if they already had one.
func reserve_seat(peer_id: int, realm: int) -> bool:
	if peer_id <= 0 or _seated.has(peer_id) or _seated.size() >= _ids.size():
		return false
	_seated[peer_id] = realm
	return true


## true if the filler has set aside a slot for [param peer_id] and they have not entered the world yet.
func has_reserved_seat(peer_id: int) -> bool:
	return _seated.has(peer_id)


## Person [param peer_id] has left without entering the world: releases the slot the filler had set aside for them
## ([method reserve_seat]). No fake had left, so none comes back. Returns true if they had one.
func release_seat(peer_id: int) -> bool:
	return _seated.erase(peer_id)


## Slots the filler has set aside for people who are still loading the zone ([method reserve_seat]).
func reserved_count() -> int:
	return _seated.size()


## A person has left [param realm] (the count no longer includes them): adds a filler fake in that realm
## if due. Returns true if it created one.
func on_person_left(realm: int) -> bool:
	if not RealmBalance.should_add_on_leave(_persons(), filler_counts(), _allowed, realm,
			_ids.size(), _budget):
		return false
	if not creator.is_valid():
		return false
	var net_id: int = int(creator.call(realm))
	if net_id <= 0:
		return false
	track(net_id, realm)
	return true


# Withdraws the oldest filler fake of [param realm] that is calm (calm_check) or, if none is, the
# oldest (rule 6). false if that realm has none.
func _retire_oldest_of(realm: int) -> bool:
	var chosen: int = -1
	for net_id: int in _ids:
		if _realm_of[net_id] != realm:
			continue
		if not calm_check.is_valid() or bool(calm_check.call(net_id)):
			chosen = net_id
			break
		if chosen < 0:
			chosen = net_id
	if chosen < 0:
		return false
	forget(chosen)
	if remover.is_valid():
		remover.call(chosen)
	return true


func _persons() -> PackedInt32Array:
	if _persons_source.is_valid():
		return _persons_source.call()
	return RealmBalance.empty_counts()
