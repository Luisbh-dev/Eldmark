extends TestCase
## Pruebas del registro de entidades de red ([NetEntityRegistry]): ids de 1 a 65535, cuarentena
## de 600 ticks y orden por net_id (docs/red.md, sección 9.1).

const PLAYER: int = NetProtocol.EntityKind.PLAYER


func test_allocate_assigns_ascending_ids_from_one() -> void:
	var registry := NetEntityRegistry.new()
	for expected: int in range(1, 6):
		var entity: NetEntity = registry.allocate(PLAYER, 10)
		if not assert_not_null(entity, "alta %d" % expected):
			return
		assert_eq(entity.net_id, expected, "net_id")
		assert_eq(entity.kind, PLAYER, "kind")
		assert_eq(entity.spawn_tick, 10, "spawn_tick")
		assert_eq(registry.get_entity(expected), entity, "get_entity devuelve la misma")
	assert_eq(registry.size(), 5, "size")


func test_kind_is_kept() -> void:
	var registry := NetEntityRegistry.new()
	var npc: NetEntity = registry.allocate(NetProtocol.EntityKind.NPC, 1)
	assert_eq(npc.kind, NetProtocol.EntityKind.NPC, "tipo NPC")


func test_get_entity_of_unknown_id_is_null() -> void:
	var registry := NetEntityRegistry.new()
	registry.allocate(PLAYER, 1)
	assert_null(registry.get_entity(0), "el 0 significa ninguno")
	assert_null(registry.get_entity(2), "id sin asignar")
	assert_null(registry.get_entity(70000), "id fuera de rango")


func test_release_removes_the_entity() -> void:
	var registry := NetEntityRegistry.new()
	var first: NetEntity = registry.allocate(PLAYER, 1)
	registry.allocate(PLAYER, 1)
	registry.release(first.net_id, 5)
	assert_null(registry.get_entity(first.net_id), "ya no está")
	assert_eq(registry.size(), 1, "size baja")
	registry.release(first.net_id, 6)
	registry.release(999, 6)
	assert_eq(registry.size(), 1, "liberar dos veces o un id desconocido no hace nada")


func test_released_id_is_not_reused_while_ids_remain() -> void:
	var registry := NetEntityRegistry.new()
	var first: NetEntity = registry.allocate(PLAYER, 1)
	registry.release(first.net_id, 2)
	var next: NetEntity = registry.allocate(PLAYER, 3)
	assert_true(next.net_id != first.net_id, "el id liberado no vuelve enseguida")
	assert_true(registry.is_quarantined(first.net_id, 3), "está en cuarentena")


func test_sorted_order_follows_net_id() -> void:
	var registry := NetEntityRegistry.new()
	for _i: int in 10:
		registry.allocate(PLAYER, 1)
	registry.release(3, 2)
	registry.release(7, 2)
	var sorted: Array[NetEntity] = registry.get_sorted()
	assert_eq(sorted.size(), 8, "diez altas menos dos bajas")
	var previous: int = 0
	for entity: NetEntity in sorted:
		assert_true(entity.net_id > previous, "ascendente: %d tras %d" % [entity.net_id, previous])
		previous = entity.net_id
	assert_eq(sorted[2].net_id, 4, "el hueco del 3 se salta")


func test_sorted_cache_is_invalidated_by_allocations_and_releases() -> void:
	var registry := NetEntityRegistry.new()
	assert_eq(registry.get_sorted().size(), 0, "vacío")
	var a: NetEntity = registry.allocate(PLAYER, 1)
	assert_eq(registry.get_sorted().size(), 1, "tras un alta")
	var b: NetEntity = registry.allocate(PLAYER, 1)
	assert_eq(registry.get_sorted().size(), 2, "tras otra")
	assert_eq(registry.get_sorted()[1], b, "la segunda al final")
	registry.release(a.net_id, 2)
	assert_eq(registry.get_sorted().size(), 1, "tras una baja")
	assert_eq(registry.get_sorted()[0], b, "queda la otra")
	# Sin cambios, la caché sigue siendo válida y estable.
	assert_eq(registry.get_sorted(), registry.get_sorted(), "dos lecturas seguidas iguales")


func test_all_ids_are_distinct_and_the_range_ends_at_65535() -> void:
	var registry := NetEntityRegistry.new()
	var seen: PackedByteArray = PackedByteArray()
	seen.resize(65536)
	for _i: int in 65535:
		var entity: NetEntity = registry.allocate(PLAYER, 0)
		if entity == null:
			fail("se agotaron los ids antes de los 65535")
			return
		if entity.net_id < 1 or entity.net_id > 65535 or seen[entity.net_id] != 0:
			fail("id repetido o fuera de rango: %d" % entity.net_id)
			return
		seen[entity.net_id] = 1
	assert_eq(registry.size(), 65535, "65535 entidades")
	assert_null(registry.allocate(PLAYER, 0), "sin ids libres devuelve null")
	assert_eq(registry.get_sorted().size(), 65535, "y todas están ordenadas")
	assert_eq(registry.get_sorted()[0].net_id, 1, "la primera")
	assert_eq(registry.get_sorted()[65534].net_id, 65535, "la última")


func test_quarantine_blocks_reuse_for_600_ticks() -> void:
	var registry := NetEntityRegistry.new()
	for _i: int in 65535:
		registry.allocate(PLAYER, 0)
	registry.release(1234, 100)
	assert_null(registry.allocate(PLAYER, 100), "en el mismo tick, en cuarentena")
	assert_null(registry.allocate(PLAYER, 699), "599 ticks después sigue en cuarentena")
	assert_true(registry.is_quarantined(1234, 699), "is_quarantined(699)")
	assert_false(registry.is_quarantined(1234, 700), "is_quarantined(700)")
	var reused: NetEntity = registry.allocate(PLAYER, 700)
	if assert_not_null(reused, "a los 600 ticks ya se puede reutilizar"):
		assert_eq(reused.net_id, 1234, "y es justo ese id")
		assert_eq(reused.spawn_tick, 700, "con su nuevo tick de alta")
	assert_null(registry.allocate(PLAYER, 700), "y ya no queda ninguno")


func test_quarantine_expires_in_release_order() -> void:
	var registry := NetEntityRegistry.new()
	for _i: int in 65535:
		registry.allocate(PLAYER, 0)
	registry.release(10, 100)
	registry.release(20, 300)
	registry.release(30, 500)
	assert_null(registry.allocate(PLAYER, 699), "ninguno ha cumplido")
	assert_eq(registry.allocate(PLAYER, 700).net_id, 10, "primero el 10")
	assert_null(registry.allocate(PLAYER, 899), "el 20 aún no")
	assert_eq(registry.allocate(PLAYER, 900).net_id, 20, "luego el 20")
	assert_eq(registry.allocate(PLAYER, 1100).net_id, 30, "y el 30")


func test_ids_wrap_around_to_free_slots() -> void:
	var registry := NetEntityRegistry.new()
	for _i: int in 65535:
		registry.allocate(PLAYER, 0)
	registry.release(5, 0)
	registry.release(60000, 0)
	var first: NetEntity = registry.allocate(PLAYER, 1000)
	var second: NetEntity = registry.allocate(PLAYER, 1000)
	# El cursor sigue por 65535 y da la vuelta: primero llega al 5 y luego al 60000.
	assert_eq(first.net_id, 5, "tras dar la vuelta aparece el id bajo libre")
	assert_eq(second.net_id, 60000, "y después el otro")
