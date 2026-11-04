class_name RealmBalance
extends RefCounted
## Realm balance of a zone (GUE-42; docs/fortress.md, section 7): pure rules over per-realm counts, with no nodes or
## network. Used by [ServerAuth] (the REJECT 9 IMBALANCE), [ZoneServer] (the WELCOME's count) and [ServerMain] (the
## filler fake players).
## [br][br]
## [b]Counts.[/b] A three-position [PackedInt32Array], in the WELCOME's order: Vardheim, Solmarch and Askarra (the index
## is the realm code minus one). [b]People[/b] are the accepted clients (loading the zone or already inside): fake
## players and bodies left after a combat departure do not count. The [b]fillers[/b] are the auto-realm fake players
## that the server has placed to even out the sides ([method totals] adds people and fillers).
## [br][br]
## [b]Competing realms.[/b] Those the zone admits ([method NetZones.allowed_realms]); if the zone restricts none, all
## three.
## [br][br]
## [b]Rejection.[/b] With [code]--max-realm-diff=N[/code] (N > 0), joining realm [i]r[/i] is rejected if
## [code]people[r] + 1 − min(people[s])[/code] is greater than N, with [i]s[/i] each of the other competing realms
## ([method exceeds]). With N = 0, or if the zone admits only one realm, it is never rejected.
## [br][br]
## [b]Filling[/b] (only with N > 0; see [ServerMain]). The server creates auto-realm fakes distributed in turns, in the
## realm with the lowest total ([method realm_for_new_filler]); afterwards:
## [br]- A person joins realm [i]r[/i]: if the total of [i]r[/i] becomes greater than the lowest of the others and
## [i]r[/i] has any filler fake, one is withdrawn (the oldest) ([method should_retire_on_join]). At most one is
## withdrawn per person.
## [br]- A person leaves [i]r[/i]: if the total of [i]r[/i] falls below the highest of the others and the
## [code]--fake-players[/code] quota has not run out, a filler fake joins [i]r[/i] ([method should_add_on_leave]).
## [br]- The HELLO of a person of [i]r[/i] arrives with the server full only because of fillers (GUE-43): fillers do not
## take people's seats, so the person enters and a fake gives up their seat, which they leave when the person enters the
## world (if they leave before, nobody has moved). It is yielded by the realm with the highest total counting whoever is
## entering; in a tie, that of [i]r[/i] and, failing that, the one with the highest code ([method realm_to_yield_seat]).
## It counts as the fake that this person withdraws: no other is withdrawn for them (it is still one per person).
## [br]A fake is never withdrawn for any other reason, and fillers do not count for the rejection: a person is not left
## out because the opposing side is full of fakes, nor because the server is.
## [br][br]
## Server only.

## Number of positions of a count (Vardheim, Solmarch, Askarra).
const REALM_COUNT: int = 3


## A zeroed count.
static func empty_counts() -> PackedInt32Array:
	var counts := PackedInt32Array()
	counts.resize(REALM_COUNT)
	return counts


## Codes of the realms that compete in a zone that admits [param allowed] (empty = all three).
static func competing_realms(allowed: PackedInt32Array) -> PackedInt32Array:
	var realms := PackedInt32Array()
	for code: int in range(1, REALM_COUNT + 1):
		if allowed.is_empty() or allowed.has(code):
			realms.append(code)
	return realms


## true if letting a person into [param realm] would leave more than [param max_diff] people of advantage over the realm
## with the fewest of the other competing ones. [param persons] counts the people already there (without the one
## entering). False with [param max_diff] ≤ 0, with a realm that does not compete or without another realm to compare
## with.
static func exceeds(persons: PackedInt32Array, allowed: PackedInt32Array, realm: int,
		max_diff: int) -> bool:
	if max_diff <= 0:
		return false
	var competing: PackedInt32Array = competing_realms(allowed)
	if not competing.has(realm):
		return false
	var lowest: int = _lowest_of_others(persons, competing, realm)
	if lowest < 0:
		return false
	return _count_of(persons, realm) + 1 - lowest > max_diff


## Total (people plus fillers) of each realm.
static func totals(persons: PackedInt32Array, fillers: PackedInt32Array) -> PackedInt32Array:
	var result: PackedInt32Array = empty_counts()
	for i: int in REALM_COUNT:
		result[i] = (persons[i] if i < persons.size() else 0) + (fillers[i] if i < fillers.size() else 0)
	return result


## The realm the next filler fake must join: the one with the lowest total among those that compete (in a tie, the
## lowest code). 0 if none competes.
static func realm_for_new_filler(persons: PackedInt32Array, fillers: PackedInt32Array,
		allowed: PackedInt32Array) -> int:
	var all_totals: PackedInt32Array = totals(persons, fillers)
	var best: int = 0
	var best_total: int = 0x7FFFFFFF
	for code: int in competing_realms(allowed):
		var total: int = all_totals[code - 1]
		if total < best_total:
			best_total = total
			best = code
	return best


## true if, after a person joins [param realm] ([param persons] already counts them), a filler fake of that realm must be
## withdrawn: its total exceeds the lowest of the other competing ones and it still has a fake.
static func should_retire_on_join(persons: PackedInt32Array, fillers: PackedInt32Array,
		allowed: PackedInt32Array, realm: int) -> bool:
	var competing: PackedInt32Array = competing_realms(allowed)
	if not competing.has(realm) or _count_of(fillers, realm) <= 0:
		return false
	var all_totals: PackedInt32Array = totals(persons, fillers)
	var lowest: int = _lowest_of_others(all_totals, competing, realm)
	return lowest >= 0 and all_totals[realm - 1] > lowest


## true if, after a person leaves [param realm] ([param persons] no longer counts them), a filler fake must be added to
## that realm: its total falls below the highest of the other competing ones and the quota has not run out
## ([param fillers_alive] filler alive in total versus [param budget]).
static func should_add_on_leave(persons: PackedInt32Array, fillers: PackedInt32Array,
		allowed: PackedInt32Array, realm: int, fillers_alive: int, budget: int) -> bool:
	if fillers_alive >= budget:
		return false
	var competing: PackedInt32Array = competing_realms(allowed)
	if not competing.has(realm):
		return false
	var all_totals: PackedInt32Array = totals(persons, fillers)
	var highest: int = -1
	for code: int in competing:
		if code != realm:
			highest = maxi(highest, all_totals[code - 1])
	return highest >= 0 and all_totals[realm - 1] < highest


## The realm of the filler fake that yields its seat to a person of [param realm] arriving with the server full
## (GUE-43): among the realms with any fake in [param fillers], the one with the highest total (people plus fillers)
## counting the person entering; in a tie, their own and, failing that, the one with the highest code (the last that
## would have been filled). It is the one that leaves the sides most evenly matched. [param persons] does not count
## whoever enters. 0 if there is no filler.
static func realm_to_yield_seat(persons: PackedInt32Array, fillers: PackedInt32Array, realm: int) -> int:
	var all_totals: PackedInt32Array = totals(persons, fillers)
	if realm >= 1 and realm <= REALM_COUNT:
		all_totals[realm - 1] += 1
	var best: int = 0
	var best_total: int = -1
	for code: int in range(REALM_COUNT, 0, -1):
		if _count_of(fillers, code) <= 0:
			continue
		var total: int = all_totals[code - 1]
		if total > best_total or (total == best_total and code == realm):
			best_total = total
			best = code
	return best


static func _count_of(counts: PackedInt32Array, realm: int) -> int:
	var index: int = realm - 1
	return counts[index] if index >= 0 and index < counts.size() else 0


# The lowest count among the competing realms other than [param realm]; -1 if there is none.
static func _lowest_of_others(counts: PackedInt32Array, competing: PackedInt32Array,
		realm: int) -> int:
	var lowest: int = -1
	for code: int in competing:
		if code == realm:
			continue
		var count: int = _count_of(counts, code)
		if lowest < 0 or count < lowest:
			lowest = count
	return lowest
