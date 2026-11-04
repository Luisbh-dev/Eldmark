extends TestCase
## Realm balance (GUE-42 and GUE-43; docs/fuerte.md, section 7): the pure rules of [RealmBalance] (rejection
## by difference in humans, when a filler fake player is removed or added and which one gives up its slot with the
## server full) and [FillerKeeper], which applies them to the automatic-realm fake players. With a real network they are
## tested by [code]test_zone_server_net[/code] (REJECT 9, the WELCOME count and the slot the filler gives up) and
## [code]test_server_main[/code] (the fake players that are removed, with the server full of fillers).

const V: int = NetProtocol.Realm.VARDHEIM
const S: int = NetProtocol.Realm.SOLMARCH
const A: int = NetProtocol.Realm.ASKARRA
## The Vado Gris zone only admits Vardheim and Solmarch.
const BORDER: PackedInt32Array = [NetProtocol.Realm.VARDHEIM, NetProtocol.Realm.SOLMARCH]


func _counts(vardheim: int, solmarch: int, askarra: int = 0) -> PackedInt32Array:
	return PackedInt32Array([vardheim, solmarch, askarra])


# --- Competing realms and rejection --------------------------------------------------------------

func test_the_realms_that_compete_are_the_ones_the_zone_admits() -> void:
	assert_eq(RealmBalance.competing_realms(BORDER), BORDER, "Vado Gris: Vardheim and Solmarch")
	assert_eq(RealmBalance.competing_realms(PackedInt32Array()), PackedInt32Array([V, S, A]),
			"a zone with no restriction: all three")


func test_without_a_limit_nobody_is_rejected() -> void:
	assert_false(RealmBalance.exceeds(_counts(40, 0), BORDER, V, 0), "0 = no limit")
	assert_false(RealmBalance.exceeds(_counts(40, 0), BORDER, V, -3), "and a negative one does not limit either")


func test_entering_the_short_side_is_never_rejected() -> void:
	for limit: int in [1, 2, 5]:
		assert_false(RealmBalance.exceeds(_counts(0, 0), BORDER, V, limit), "the first in the zone gets in (N=%d)" % limit)
		assert_false(RealmBalance.exceeds(_counts(7, 3), BORDER, S, limit), "the short realm always gets in (N=%d)" % limit)
		assert_false(RealmBalance.exceeds(_counts(3, 3), BORDER, S, limit), "with a tie, it gets in (N=%d)" % limit)


func test_entering_the_long_side_is_rejected_when_it_leaves_more_than_n_ahead() -> void:
	# N = 1: 1 against 0 is fine; 2 against 0 is not.
	assert_false(RealmBalance.exceeds(_counts(0, 0), BORDER, V, 1), "1 against 0 is fine")
	assert_true(RealmBalance.exceeds(_counts(1, 0), BORDER, V, 1), "2 against 0 leaves a lead of 2")
	assert_false(RealmBalance.exceeds(_counts(1, 1), BORDER, V, 1), "2 against 1 is fine")
	# N = 3: with a lead of 3 it is fine and with 4 it is not.
	assert_false(RealmBalance.exceeds(_counts(2, 0), BORDER, V, 3), "3 against 0 is fine")
	assert_true(RealmBalance.exceeds(_counts(3, 0), BORDER, V, 3), "4 against 0 is not fine")
	assert_false(RealmBalance.exceeds(_counts(7, 4), BORDER, V, 4), "8 against 4 is fine")
	assert_true(RealmBalance.exceeds(_counts(8, 4), BORDER, V, 4), "9 against 4 is not fine")
	# It is symmetric for the other realm.
	assert_true(RealmBalance.exceeds(_counts(0, 3), BORDER, S, 3), "Solmarch is rejected too")


func test_the_comparison_is_with_the_realm_with_fewest_people_among_those_the_zone_admits() -> void:
	# In a three-realm zone, an empty Askarra counts as the realm with the fewest.
	assert_true(RealmBalance.exceeds(_counts(1, 1, 0), PackedInt32Array(), V, 1),
			"2 against 1 and 0: the difference with Askarra is 2")
	assert_false(RealmBalance.exceeds(_counts(1, 1, 1), PackedInt32Array(), V, 1), "2 against 1 and 1: fine")
	# In Vado Gris Askarra does not exist: its 0 does not count.
	assert_false(RealmBalance.exceeds(_counts(1, 1, 0), BORDER, V, 1), "Askarra is not admitted")


func test_a_zone_with_a_single_realm_has_nobody_to_compare_with() -> void:
	assert_false(RealmBalance.exceeds(_counts(9, 0), PackedInt32Array([V]), V, 1))
	assert_false(RealmBalance.exceeds(_counts(0, 0), BORDER, 0, 1), "a realm that does not exist is not rejected here")
	assert_false(RealmBalance.exceeds(_counts(0, 0), BORDER, A, 1), "nor one the zone does not admit")


# --- Filler ----------------------------------------------------------------------------------------

func test_totals_add_people_and_fillers() -> void:
	assert_eq(RealmBalance.totals(_counts(2, 1, 0), _counts(3, 4, 0)), _counts(5, 5, 0))
	assert_eq(RealmBalance.totals(PackedInt32Array([1]), PackedInt32Array()), _counts(1, 0, 0), "short counts are filled")


func test_a_new_filler_goes_to_the_realm_with_the_lowest_total() -> void:
	assert_eq(RealmBalance.realm_for_new_filler(_counts(0, 0), _counts(0, 0), BORDER), V, "on a tie, the one with the lowest code")
	assert_eq(RealmBalance.realm_for_new_filler(_counts(0, 0), _counts(1, 0), BORDER), S)
	assert_eq(RealmBalance.realm_for_new_filler(_counts(0, 3), _counts(2, 0), BORDER), V,
			"humans count: 2 against 3")
	assert_eq(RealmBalance.realm_for_new_filler(_counts(5, 0), _counts(0, 0), BORDER), S)
	assert_eq(RealmBalance.realm_for_new_filler(_counts(0, 0), _counts(1, 1), PackedInt32Array()), A,
			"with three realms Askarra is filled too")


func test_a_person_entering_the_long_side_retires_one_filler_of_it() -> void:
	# 4 fake players per side; a human joins Vardheim: 5 against 4, one Vardheim fake player leaves.
	assert_true(RealmBalance.should_retire_on_join(_counts(1, 0), _counts(4, 4), BORDER, V))
	# With 3 against 4 fake players, a human in Solmarch leaves 4 against 5: one Solmarch fake player is surplus.
	assert_true(RealmBalance.should_retire_on_join(_counts(1, 1), _counts(3, 4), BORDER, S))
	# A human joining the short side takes a slot: nobody is removed.
	assert_false(RealmBalance.should_retire_on_join(_counts(1, 0), _counts(2, 5), BORDER, V),
			"3 against 5: Vardheim is the short one")
	assert_false(RealmBalance.should_retire_on_join(_counts(1, 0), _counts(4, 5), BORDER, V),
			"5 against 5: a tie, the human is not surplus")
	# With no fake players in its realm there is no one to remove.
	assert_false(RealmBalance.should_retire_on_join(_counts(6, 0), _counts(0, 4), BORDER, V))
	assert_false(RealmBalance.should_retire_on_join(_counts(1, 0), _counts(4, 4), BORDER, A),
			"a realm the zone does not admit")


func test_a_person_leaving_asks_for_a_filler_if_the_budget_allows() -> void:
	# Vardheim 3 against Solmarch 4 after a human leaves, and 5 of 6 allowed fake players remain.
	assert_true(RealmBalance.should_add_on_leave(_counts(1, 0), _counts(2, 4), BORDER, V, 6, 7))
	assert_false(RealmBalance.should_add_on_leave(_counts(1, 0), _counts(2, 4), BORDER, V, 7, 7),
			"the filler quota is exhausted")
	assert_false(RealmBalance.should_add_on_leave(_counts(1, 4), _counts(2, 0), BORDER, S, 2, 7),
			"Solmarch 4 against Vardheim 3: it is not the short one")
	assert_false(RealmBalance.should_add_on_leave(_counts(0, 0), _counts(3, 3), BORDER, V, 6, 7),
			"3 against 3: nothing to fill")


# --- FillerKeeper ------------------------------------------------------------------------------------

## A keeper with mock fake players: [member created] stores (realm) of those it creates and
## [member removed] those it removes; the humans are set by the test.
class Rig:
	extends RefCounted

	var persons: PackedInt32Array = PackedInt32Array([0, 0, 0])
	var created: Array[int] = []
	var removed: Array[int] = []
	var next_id: int = 100
	var keeper: FillerKeeper = null


	# With methods and not lambdas: a lambda holds a strong reference to the Rig and the Rig → keeper → lambda cycle
	# was never freed (leaked-object warnings on exit).
	func _init(budget: int, allowed: PackedInt32Array) -> void:
		keeper = FillerKeeper.new(allowed, budget, _get_persons)
		keeper.creator = _create
		keeper.remover = _remove


	func _get_persons() -> PackedInt32Array:
		return persons


	func _create(realm: int) -> int:
		next_id += 1
		created.append(realm)
		return next_id


	func _remove(net_id: int) -> void:
		removed.append(net_id)


	## Creates the whole quota as ServerMain does on startup.
	func fill(count: int) -> void:
		for _i: int in count:
			var realm: int = keeper.next_realm()
			next_id += 1
			keeper.track(next_id, realm)


	func person_joins(realm: int, peer_id: int = 0) -> bool:
		persons[realm - 1] += 1
		return keeper.on_person_joined(realm, peer_id)


	## The HELLO of [param peer_id] arrives with the server full: the filler sets aside a slot for it (GUE-43). The human
	## does not count yet: they enter the world with [method person_joins], and then the fake player who gives up the slot leaves.
	func hello_when_full(peer_id: int, realm: int) -> bool:
		return keeper.reserve_seat(peer_id, realm)


	## [param peer_id] leaves without having entered the world (drops or never finishes loading).
	func leaves_while_loading(peer_id: int) -> bool:
		return keeper.release_seat(peer_id)


	func person_leaves(realm: int) -> bool:
		persons[realm - 1] -= 1
		return keeper.on_person_left(realm)


func test_the_initial_fillers_alternate_between_the_realms() -> void:
	var rig := Rig.new(8, BORDER)
	rig.fill(8)
	assert_eq(rig.keeper.filler_counts(), _counts(4, 4, 0), "4 against 4")
	assert_eq(rig.keeper.filler_count(), 8)
	var three := Rig.new(6, PackedInt32Array())
	three.fill(6)
	assert_eq(three.keeper.filler_counts(), _counts(2, 2, 2), "in a three-realm zone, 2 per realm")


func test_people_replace_fillers_one_for_one_while_the_sides_stay_even() -> void:
	var rig := Rig.new(8, BORDER)
	rig.fill(8)
	assert_true(rig.person_joins(V), "a human joins Vardheim: one of its fake players leaves")
	assert_eq(rig.keeper.filler_counts(), _counts(3, 4, 0))
	assert_true(rig.person_joins(S), "another joins Solmarch: 4 against 5, one from Solmarch leaves")
	assert_eq(rig.keeper.filler_counts(), _counts(3, 3, 0))
	assert_eq(RealmBalance.totals(rig.persons, rig.keeper.filler_counts()), _counts(4, 4, 0), "the totals stay even")
	assert_eq(rig.removed.size(), 2, "two fake players were removed")
	# It removes them by seniority within their realm: the first Vardheim fake player is 101 and Solmarch's is 102.
	assert_eq(rig.removed, [101, 102] as Array[int], "the oldest of each realm")


func test_the_filler_that_leaves_is_the_oldest_calm_one_of_its_realm() -> void:
	# Review of the abilities integration: the oldest could be knocked down, and its removal was a death with a KILL
	# for whoever knocked it down; or getting up or finishing someone off. The oldest calm one leaves (calm_check) and, if none
	# is calm, the oldest (its removal is no longer a death: ZoneServer.retire_filler).
	var rig := Rig.new(8, BORDER)
	rig.fill(8)
	var busy: Dictionary[int, bool] = {101: true, 103: true}
	rig.keeper.calm_check = func(net_id: int) -> bool: return not busy.has(net_id)
	assert_true(rig.person_joins(V), "a human joins Vardheim")
	assert_eq(rig.removed, [105] as Array[int], "101 and 103 are not calm: 105 leaves")
	assert_true(rig.keeper.is_filler(101) and rig.keeper.is_filler(103), "and they stay")
	# The lambda holds the same dictionary: it is changed from the inside.
	busy.clear()
	for net_id: int in [102, 104, 106, 108]:
		busy[net_id] = true
	assert_true(rig.person_joins(S), "another one in Solmarch")
	assert_eq(rig.removed, [105, 102] as Array[int], "none of Solmarch's is calm: the oldest")
	rig.keeper.calm_check = Callable()
	assert_true(rig.person_joins(V), "without calm_check, all of them are")
	assert_eq(rig.removed, [105, 102, 101] as Array[int])


func test_a_person_entering_the_short_side_does_not_retire_anyone() -> void:
	var rig := Rig.new(8, BORDER)
	# Two Vardheim fake players and six Solmarch ones: Vardheim is the short side.
	rig.keeper.track(1, V)
	rig.keeper.track(2, V)
	for id: int in range(3, 9):
		rig.keeper.track(id, S)
	assert_false(rig.person_joins(V), "the human takes a Vardheim slot (3 against 6)")
	assert_eq(rig.keeper.filler_counts(), _counts(2, 6, 0), "nobody is removed")
	assert_true(rig.removed.is_empty())


func test_when_the_fillers_of_a_realm_run_out_people_keep_coming_without_retiring_the_other_side() -> void:
	var rig := Rig.new(4, BORDER)
	rig.fill(4)
	assert_true(rig.person_joins(V))
	assert_true(rig.person_joins(V))
	assert_eq(rig.keeper.filler_counts(), _counts(0, 2, 0))
	assert_false(rig.person_joins(V), "no Vardheim fake players are left: nobody is removed")
	assert_eq(rig.keeper.filler_counts(), _counts(0, 2, 0), "Solmarch's stay: they are the filler of their short side")
	assert_eq(rig.persons, _counts(3, 0, 0))


func test_a_person_leaving_brings_a_filler_back_up_to_the_budget() -> void:
	var rig := Rig.new(8, BORDER)
	rig.fill(8)
	rig.person_joins(V)
	rig.person_joins(V)
	assert_eq(rig.keeper.filler_counts(), _counts(2, 4, 0))
	assert_true(rig.person_leaves(V), "one leaves: Vardheim 3 against 4, a fake player joins")
	assert_eq(rig.created, [V] as Array[int], "in the realm that has fallen short")
	assert_eq(rig.keeper.filler_counts(), _counts(3, 4, 0))
	assert_true(rig.person_leaves(V))
	assert_eq(rig.keeper.filler_counts(), _counts(4, 4, 0))
	assert_eq(rig.keeper.filler_count(), 8, "with no humans the whole quota returns")
	assert_eq(rig.persons, _counts(0, 0, 0))


func test_a_filler_is_only_added_to_the_realm_that_has_fallen_behind() -> void:
	var rig := Rig.new(4, BORDER)
	rig.fill(4)
	rig.person_joins(V)
	rig.person_joins(S)
	assert_eq(rig.keeper.filler_counts(), _counts(1, 1, 0), "each human has replaced a fake player")
	# The Vardheim one leaves: Vardheim 1 against Solmarch 2, a fake player joins Vardheim.
	assert_true(rig.person_leaves(V))
	assert_eq(rig.keeper.filler_counts(), _counts(2, 1, 0))
	# The Solmarch one leaves: Vardheim 2 against Solmarch 1, a fake player joins Solmarch.
	assert_true(rig.person_leaves(S))
	assert_eq(rig.keeper.filler_counts(), _counts(2, 2, 0))
	assert_eq(rig.created, [V, S] as Array[int], "each refiller, in its own realm")


func test_a_leaving_person_of_the_long_side_needs_no_filler() -> void:
	var rig := Rig.new(4, BORDER)
	rig.keeper.track(1, V)
	rig.keeper.track(2, V)
	# Vardheim: 3 humans and 2 fake players (5); Solmarch: 1 human and 1 fake player (2). One leaves Vardheim: 4 against 2.
	rig.keeper.track(3, S)
	rig.persons = _counts(4, 1, 0)
	assert_false(rig.person_leaves(V), "Vardheim is still the long side")
	assert_true(rig.created.is_empty())


func test_the_keeper_tracks_and_forgets_fillers() -> void:
	var rig := Rig.new(4, BORDER)
	rig.keeper.track(7, V)
	rig.keeper.track(7, S)
	rig.keeper.track(0, V)
	assert_eq(rig.keeper.filler_count(), 1, "a repeated id or 0 is not recorded")
	assert_true(rig.keeper.is_filler(7))
	assert_eq(rig.keeper.filler_counts(), _counts(1, 0, 0), "the realm is that of the first join")
	rig.keeper.forget(7)
	assert_false(rig.keeper.is_filler(7))
	assert_eq(rig.keeper.filler_count(), 0)


# --- Slots the filler gives up (GUE-43) ---------------------------------------------------------------------

func test_with_the_server_full_the_filler_that_yields_is_one_of_the_joiners_realm_when_the_sides_are_even() -> void:
	assert_eq(RealmBalance.realm_to_yield_seat(_counts(0, 0), _counts(4, 4), V), V, "4 against 4: one from Vardheim gives up")
	assert_eq(RealmBalance.realm_to_yield_seat(_counts(0, 0), _counts(4, 4), S), S, "and for Solmarch, one from Solmarch")
	assert_eq(RealmBalance.realm_to_yield_seat(_counts(2, 1), _counts(1, 2), S), S,
			"3 against 3 with humans: the one from their realm")
	assert_eq(RealmBalance.realm_to_yield_seat(_counts(0, 0), _counts(2, 2, 2), A), A, "with three realms, too")


func test_with_the_server_full_a_realm_without_fillers_takes_the_seat_of_the_side_with_the_highest_total() -> void:
	# Vardheim is already all humans: the fake player who gives up is from Solmarch (the only one with filler).
	assert_eq(RealmBalance.realm_to_yield_seat(_counts(2, 0), _counts(0, 2), V), S)
	# With three realms, among those with filler, the one with the highest total; on a tie, the one with the highest code.
	assert_eq(RealmBalance.realm_to_yield_seat(_counts(2, 0, 0), _counts(0, 1, 2), V), A, "Askarra 2 against Solmarch 1")
	assert_eq(RealmBalance.realm_to_yield_seat(_counts(2, 0, 0), _counts(0, 2, 1), V), S, "Solmarch 2 against Askarra 1")
	assert_eq(RealmBalance.realm_to_yield_seat(_counts(2, 0, 0), _counts(0, 2, 2), V), A, "tie: the one with the highest code")


func test_with_the_server_full_the_seat_comes_from_the_side_that_would_otherwise_lead() -> void:
	# Vardheim 1 against Solmarch 3 (all filler): a Vardheim human joins (2 against 3). If one from
	# Vardheim gave up it would be 1 against 3; one from Solmarch gives up and it ends up 2 against 2.
	assert_eq(RealmBalance.realm_to_yield_seat(_counts(0, 0), _counts(1, 3), V), S)
	# With its realm tied with the highest (counting it), its own gives up.
	assert_eq(RealmBalance.realm_to_yield_seat(_counts(0, 0), _counts(2, 3), V), V, "3 against 3: its own")
	assert_eq(RealmBalance.realm_to_yield_seat(_counts(0, 0), _counts(0, 0), V), 0, "without filler nobody gives up")


func test_a_person_arriving_at_a_full_server_takes_the_seat_of_the_oldest_filler_of_their_realm() -> void:
	var rig := Rig.new(4, BORDER)
	rig.fill(4)
	assert_true(rig.hello_when_full(11, V), "with the server full of filler, a fake player sets aside its slot for her")
	assert_true(rig.removed.is_empty(), "but it does not leave until she enters the world")
	assert_true(rig.keeper.has_reserved_seat(11), "the slot is held in that human's name")
	assert_eq(rig.keeper.reserved_count(), 1)
	assert_true(rig.person_joins(V, 11), "on entering the world the fake player who gives it up leaves")
	assert_eq(rig.removed, [101] as Array[int], "the oldest of Vardheim")
	assert_false(rig.keeper.has_reserved_seat(11), "and the slot is no longer pending")
	assert_eq(RealmBalance.totals(rig.persons, rig.keeper.filler_counts()), _counts(2, 2, 0), "2 against 2")
	assert_eq(rig.removed.size(), 1, "only one per human")


func test_after_a_yielded_seat_the_usual_rules_keep_working() -> void:
	var rig := Rig.new(4, BORDER)
	rig.fill(4)
	rig.hello_when_full(11, V)
	rig.person_joins(V, 11)
	# Another Vardheim human without the server being full (someone raised the quota): the usual rule.
	assert_true(rig.person_joins(V), "Vardheim 3 against 2: its last fake player is removed")
	assert_eq(rig.keeper.filler_counts(), _counts(0, 2, 0))
	# The one who entered in the ceded slot leaves: Vardheim 1 against 2, a fake player returns to Vardheim.
	assert_true(rig.person_leaves(V))
	assert_eq(rig.created, [V] as Array[int])
	assert_eq(rig.keeper.filler_counts(), _counts(1, 2, 0))


func test_two_people_of_the_same_realm_arriving_together_at_a_full_server_both_get_a_seat() -> void:
	var rig := Rig.new(4, BORDER)
	rig.fill(4)
	# Both HELLOs arrive before either enters the world.
	assert_true(rig.hello_when_full(11, V))
	assert_true(rig.hello_when_full(12, V))
	assert_eq(rig.keeper.reserved_count(), 2, "two slots set aside")
	assert_true(rig.removed.is_empty())
	assert_true(rig.person_joins(V, 11))
	assert_true(rig.person_joins(V, 12), "Vardheim 2 (1 fake player and the second human) against 2: its own")
	assert_eq(rig.removed, [101, 103] as Array[int], "both Vardheim fake players")
	assert_eq(rig.keeper.filler_counts(), _counts(0, 2, 0))
	assert_eq(RealmBalance.totals(rig.persons, rig.keeper.filler_counts()), _counts(2, 2, 0))
	# The third no longer finds Vardheim filler: one from Solmarch gives up (what the quota says is decided by the server).
	assert_true(rig.hello_when_full(13, V))
	assert_true(rig.person_joins(V, 13))
	assert_eq(rig.removed.back(), 102, "the oldest of Solmarch")


func test_the_fillers_only_reserve_as_many_seats_as_there_are_fillers() -> void:
	var rig := Rig.new(2, BORDER)
	rig.fill(2)
	assert_true(rig.hello_when_full(11, V))
	assert_true(rig.hello_when_full(12, S))
	assert_false(rig.hello_when_full(13, V), "both fake players have already set aside their slot")
	assert_false(rig.hello_when_full(11, V), "nor are two set aside for the same human")
	assert_eq(rig.keeper.reserved_count(), 2)
	assert_true(rig.leaves_while_loading(12))
	assert_true(rig.hello_when_full(13, V), "the one who leaves without entering frees up theirs")


func test_a_person_who_leaves_before_entering_the_world_frees_the_seat_without_moving_any_filler() -> void:
	var rig := Rig.new(4, BORDER)
	rig.fill(4)
	rig.hello_when_full(11, V)
	assert_eq(rig.keeper.filler_count(), 4, "the fake player stays in the world while she loads")
	assert_true(rig.leaves_while_loading(11), "she leaves without entering: the slot is freed")
	assert_true(rig.removed.is_empty(), "nobody has been removed")
	assert_true(rig.created.is_empty(), "nor does anyone need to be refilled")
	assert_eq(rig.keeper.filler_counts(), _counts(2, 2, 0), "the whole quota, the same fake players")
	assert_false(rig.keeper.has_reserved_seat(11))
	assert_false(rig.leaves_while_loading(11), "only once")
	assert_false(rig.leaves_while_loading(77), "whoever had no slot set aside frees nothing")


func test_a_hello_and_a_disconnect_in_a_loop_never_touch_the_fillers() -> void:
	# F6b review (GUE-43): with removal on HELLO arrival, every HELLO followed by a disconnect before entering
	# removed the oldest fake player (DESPAWN to everyone; in some states, one from the opposing side) and created a new one at its
	# camp (SPAWN to everyone), without limit. Now the slot is only set aside: the filler does not move.
	# Vardheim 2 humans against Solmarch 1 human and 1 fake player: a third Vardheim human arrives with the server full.
	var rig := Rig.new(2, BORDER)
	rig.persons = _counts(2, 1, 0)
	rig.keeper.track(50, S)
	for peer_id: int in range(11, 16):
		assert_true(rig.hello_when_full(peer_id, V), "HELLO %d: slot set aside" % peer_id)
		assert_true(rig.leaves_while_loading(peer_id), "and leaves without entering")
	assert_true(rig.removed.is_empty(), "no fake player is removed (%s)" % [rig.removed])
	assert_true(rig.created.is_empty(), "nor is any created (%s)" % [rig.created])
	assert_true(rig.keeper.is_filler(50), "Solmarch's is still where it was")


func test_a_seat_abandoned_while_another_person_loads_leaves_the_sides_even() -> void:
	# F6b review (GUE-43): with removal on HELLO arrival, Ana (Vardheim) and Sam (Solmarch) took the slot of a
	# fake player of their realm; Sam left while loading and his fake player returned to the realm with the lower total without counting Ana, who was still loading
	# (Vardheim, by tie): when Ana entered it was 3 against 1. Now the fake player is removed when she enters: 2 against 2.
	var rig := Rig.new(4, BORDER)
	rig.fill(4)
	assert_true(rig.hello_when_full(11, V), "Ana")
	assert_true(rig.hello_when_full(12, S), "Sam")
	assert_true(rig.leaves_while_loading(12), "Sam leaves while loading")
	assert_true(rig.person_joins(V, 11), "Ana enters: a fake player leaves")
	assert_eq(RealmBalance.totals(rig.persons, rig.keeper.filler_counts()), _counts(2, 2, 0), "2 against 2")
	assert_eq(rig.keeper.filler_counts(), _counts(1, 2, 0))
	assert_true(rig.created.is_empty())


func test_without_fillers_nothing_yields_a_seat() -> void:
	var rig := Rig.new(2, BORDER)
	assert_false(rig.hello_when_full(11, V), "there is no filler")
	assert_false(rig.keeper.has_reserved_seat(11))
	assert_true(rig.removed.is_empty())
