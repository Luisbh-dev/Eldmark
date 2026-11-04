extends TestCase
## Tests for the network entity registry ([NetEntityRegistry]): ids from 1 to 65535, 600-tick
## quarantine and ordering by net_id (docs/networking.md, section 9.1); and the transient ids of projectiles
## (docs/abilities.md, section 4.4), from the same space and with the same quarantine.

const PLAYER: int = NetProtocol.EntityKind.PLAYER


func test_allocate_assigns_ascending_ids_from_one() -> void:
	var registry := NetEntityRegistry.new()
	for expected: int in range(1, 6):
		var entity: NetEntity = registry.allocate(PLAYER, 10)
		if not assert_not_null(entity, "spawn %d" % expected):
			return
		assert_eq(entity.net_id, expected, "net_id")
		assert_eq(entity.kind, PLAYER, "kind")
		assert_eq(entity.spawn_tick, 10, "spawn_tick")
		assert_eq(registry.get_entity(expected), entity, "get_entity returns the same one")
	assert_eq(registry.size(), 5, "size")


func test_kind_is_kept() -> void:
	var registry := NetEntityRegistry.new()
	var npc: NetEntity = registry.allocate(NetProtocol.EntityKind.NPC, 1)
	assert_eq(npc.kind, NetProtocol.EntityKind.NPC, "NPC type")


func test_get_entity_of_unknown_id_is_null() -> void:
	var registry := NetEntityRegistry.new()
	registry.allocate(PLAYER, 1)
	assert_null(registry.get_entity(0), "0 means none")
	assert_null(registry.get_entity(2), "unassigned id")
	assert_null(registry.get_entity(70000), "id out of range")


func test_release_removes_the_entity() -> void:
	var registry := NetEntityRegistry.new()
	var first: NetEntity = registry.allocate(PLAYER, 1)
	registry.allocate(PLAYER, 1)
	registry.release(first.net_id, 5)
	assert_null(registry.get_entity(first.net_id), "it is no longer there")
	assert_eq(registry.size(), 1, "size drops")
	registry.release(first.net_id, 6)
	registry.release(999, 6)
	assert_eq(registry.size(), 1, "releasing twice or an unknown id does nothing")


func test_released_id_is_not_reused_while_ids_remain() -> void:
	var registry := NetEntityRegistry.new()
	var first: NetEntity = registry.allocate(PLAYER, 1)
	registry.release(first.net_id, 2)
	var next: NetEntity = registry.allocate(PLAYER, 3)
	assert_true(next.net_id != first.net_id, "the released id does not come back right away")
	assert_true(registry.is_quarantined(first.net_id, 3), "it is in quarantine")


func test_sorted_order_follows_net_id() -> void:
	var registry := NetEntityRegistry.new()
	for _i: int in 10:
		registry.allocate(PLAYER, 1)
	registry.release(3, 2)
	registry.release(7, 2)
	var sorted: Array[NetEntity] = registry.get_sorted()
	assert_eq(sorted.size(), 8, "ten spawns minus two removals")
	var previous: int = 0
	for entity: NetEntity in sorted:
		assert_true(entity.net_id > previous, "ascending: %d after %d" % [entity.net_id, previous])
		previous = entity.net_id
	assert_eq(sorted[2].net_id, 4, "the gap at 3 is skipped")


func test_sorted_cache_is_invalidated_by_allocations_and_releases() -> void:
	var registry := NetEntityRegistry.new()
	assert_eq(registry.get_sorted().size(), 0, "empty")
	var a: NetEntity = registry.allocate(PLAYER, 1)
	assert_eq(registry.get_sorted().size(), 1, "after one spawn")
	var b: NetEntity = registry.allocate(PLAYER, 1)
	assert_eq(registry.get_sorted().size(), 2, "after another")
	assert_eq(registry.get_sorted()[1], b, "the second at the end")
	registry.release(a.net_id, 2)
	assert_eq(registry.get_sorted().size(), 1, "after a removal")
	assert_eq(registry.get_sorted()[0], b, "the other one remains")
	# Without changes, the cache remains valid and stable.
	assert_eq(registry.get_sorted(), registry.get_sorted(), "two consecutive equal reads")


func test_all_ids_are_distinct_and_the_range_ends_at_65535() -> void:
	var registry := NetEntityRegistry.new()
	var seen: PackedByteArray = PackedByteArray()
	seen.resize(65536)
	for _i: int in 65535:
		var entity: NetEntity = registry.allocate(PLAYER, 0)
		if entity == null:
			fail("the ids ran out before 65535")
			return
		if entity.net_id < 1 or entity.net_id > 65535 or seen[entity.net_id] != 0:
			fail("repeated or out-of-range id: %d" % entity.net_id)
			return
		seen[entity.net_id] = 1
	assert_eq(registry.size(), 65535, "65535 entities")
	assert_null(registry.allocate(PLAYER, 0), "with no free ids it returns null")
	assert_eq(registry.get_sorted().size(), 65535, "and they are all sorted")
	assert_eq(registry.get_sorted()[0].net_id, 1, "the first")
	assert_eq(registry.get_sorted()[65534].net_id, 65535, "the last")


func test_quarantine_blocks_reuse_for_600_ticks() -> void:
	var registry := NetEntityRegistry.new()
	for _i: int in 65535:
		registry.allocate(PLAYER, 0)
	registry.release(1234, 100)
	assert_null(registry.allocate(PLAYER, 100), "in the same tick, in quarantine")
	assert_null(registry.allocate(PLAYER, 699), "599 ticks later it is still in quarantine")
	assert_true(registry.is_quarantined(1234, 699), "is_quarantined(699)")
	assert_false(registry.is_quarantined(1234, 700), "is_quarantined(700)")
	var reused: NetEntity = registry.allocate(PLAYER, 700)
	if assert_not_null(reused, "after 600 ticks it can already be reused"):
		assert_eq(reused.net_id, 1234, "and it is exactly that id")
		assert_eq(reused.spawn_tick, 700, "with its new spawn tick")
	assert_null(registry.allocate(PLAYER, 700), "and none is left")


func test_quarantine_expires_in_release_order() -> void:
	var registry := NetEntityRegistry.new()
	for _i: int in 65535:
		registry.allocate(PLAYER, 0)
	registry.release(10, 100)
	registry.release(20, 300)
	registry.release(30, 500)
	assert_null(registry.allocate(PLAYER, 699), "none has served its time")
	assert_eq(registry.allocate(PLAYER, 700).net_id, 10, "the 10 first")
	assert_null(registry.allocate(PLAYER, 899), "the 20 not yet")
	assert_eq(registry.allocate(PLAYER, 900).net_id, 20, "then the 20")
	assert_eq(registry.allocate(PLAYER, 1100).net_id, 30, "y el 30")


func test_ids_wrap_around_to_free_slots() -> void:
	var registry := NetEntityRegistry.new()
	for _i: int in 65535:
		registry.allocate(PLAYER, 0)
	registry.release(5, 0)
	registry.release(60000, 0)
	var first: NetEntity = registry.allocate(PLAYER, 1000)
	var second: NetEntity = registry.allocate(PLAYER, 1000)
	# The cursor continues past 65535 and wraps around: it reaches 5 first and then 60000.
	assert_eq(first.net_id, 5, "after wrapping around the low free id appears")
	assert_eq(second.net_id, 60000, "and then the other")


func test_transient_ids_share_the_space_and_the_quarantine_without_entities() -> void:
	var registry := NetEntityRegistry.new()
	var player: NetEntity = registry.allocate(PLAYER, 0)
	var arrow: int = registry.allocate_transient_id(0)
	assert_eq([player.net_id, arrow], [1, 2], "from the same space, in a circle")
	assert_true(registry.is_transient(arrow))
	assert_eq(registry.transient_count(), 1)
	assert_null(registry.get_entity(arrow), "without an entity")
	assert_eq(registry.size(), 1, "nor in the entity list")
	assert_eq(registry.get_sorted().size(), 1, "nor in the simulation order")
	var next: NetEntity = registry.allocate(PLAYER, 0)
	assert_eq(next.net_id, 3, "an entity does not take a transient id in use")
	registry.release_transient_id(arrow, 100)
	assert_false(registry.is_transient(arrow))
	assert_true(registry.is_quarantined(arrow, 699), "the same 600-tick quarantine")
	registry.release_transient_id(arrow, 100)
	registry.release_transient_id(77, 100)
	assert_eq(registry.transient_count(), 0, "releasing one that is not there does nothing")
	# With the whole space occupied, the released id only comes back after the quarantine (and an entity can take it).
	while registry.allocate_transient_id(100) != 0:
		pass
	assert_eq(registry.allocate_transient_id(699), 0, "in quarantine")
	assert_null(registry.allocate(PLAYER, 699))
	var reused: NetEntity = registry.allocate(PLAYER, 700)
	if assert_not_null(reused, "after 600 ticks"):
		assert_eq(reused.net_id, arrow, "an entity can take the id of an arrow that has already expired")
	registry.release(reused.net_id, 800)
	assert_eq(registry.allocate_transient_id(1399), 0)
	assert_eq(registry.allocate_transient_id(1400), arrow, "and an arrow, that of an entity")
