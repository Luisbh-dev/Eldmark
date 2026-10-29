extends TestCase
## El control del comando /atascado ([UnstuckTracker], docs/fuerte.md sección 5; MUN-41): canalización de
## 10 s, rechazo en combate y muerto, interrupción, reutilización de 5 min y que volver a entrar no la
## salta (la clave es el nombre).


func test_the_real_times_are_ten_seconds_and_five_minutes() -> void:
	assert_eq(UnstuckTracker.CHANNEL_TICKS, 600)
	assert_eq(UnstuckTracker.COOLDOWN_TICKS, 18000)
	var tracker := UnstuckTracker.new()
	assert_eq(tracker.channel_ticks, 600)
	assert_eq(tracker.cooldown_ticks, 18000)


func test_a_request_out_of_combat_channels_and_completes_after_ten_seconds() -> void:
	var tracker := UnstuckTracker.new()
	assert_eq(tracker.request("ana", 100, true, false), UnstuckTracker.RequestResult.STARTED)
	assert_true(tracker.is_channeling("ana"))
	assert_eq(tracker.channel_remaining("ana", 100), 600)
	assert_eq(tracker.update("ana", 101, true, false), UnstuckTracker.UpdateResult.CHANNELING)
	assert_eq(tracker.update("ana", 699, true, false), UnstuckTracker.UpdateResult.CHANNELING)
	assert_eq(tracker.update("ana", 700, true, false), UnstuckTracker.UpdateResult.COMPLETED)
	assert_false(tracker.is_channeling("ana"))
	assert_eq(tracker.completed_count, 1)
	assert_eq(tracker.cooldown_remaining("ana", 700), 18000)
	assert_eq(tracker.cooldown_remaining("ana", 18700), 0)


func test_combat_and_death_refuse_the_request() -> void:
	var tracker := UnstuckTracker.new()
	assert_eq(tracker.request("ana", 10, true, true), UnstuckTracker.RequestResult.IN_COMBAT)
	assert_eq(tracker.request("ana", 10, false, false), UnstuckTracker.RequestResult.DEAD)
	assert_false(tracker.is_channeling("ana"))
	assert_eq(tracker.request("ana", 10, true, false), UnstuckTracker.RequestResult.STARTED)
	assert_eq(tracker.request("ana", 11, true, false), UnstuckTracker.RequestResult.ALREADY_CHANNELING)


func test_damage_or_death_interrupts_and_the_cooldown_is_not_spent() -> void:
	var tracker := UnstuckTracker.new()
	tracker.request("ana", 0, true, false)
	assert_eq(tracker.update("ana", 100, true, true), UnstuckTracker.UpdateResult.INTERRUPTED,
			"entrar en combate (recibir daño) la interrumpe")
	assert_eq(tracker.interrupted_count, 1)
	assert_eq(tracker.cooldown_remaining("ana", 100), 0)
	assert_eq(tracker.request("ana", 101, true, false), UnstuckTracker.RequestResult.STARTED, "puede volver a intentarlo")
	assert_eq(tracker.update("ana", 200, false, false), UnstuckTracker.UpdateResult.INTERRUPTED, "morir también")
	assert_eq(tracker.completed_count, 0)


func test_the_cooldown_blocks_a_second_use_and_survives_leaving_and_coming_back() -> void:
	var tracker := UnstuckTracker.new()
	tracker.request("ana", 0, true, false)
	tracker.update("ana", 600, true, false)
	assert_eq(tracker.request("ana", 1000, true, false), UnstuckTracker.RequestResult.COOLDOWN)
	tracker.cancel("ana")
	assert_eq(tracker.request("ana", 2000, true, false), UnstuckTracker.RequestResult.COOLDOWN,
			"salir y volver a entrar no la salta")
	assert_eq(tracker.request("bob", 2000, true, false), UnstuckTracker.RequestResult.STARTED, "otro jugador, sí")
	assert_eq(tracker.request("ana", 18600, true, false), UnstuckTracker.RequestResult.STARTED, "a los 5 min")


func test_cancel_stops_a_channel_without_counting_it() -> void:
	var tracker := UnstuckTracker.new()
	tracker.request("ana", 0, true, false)
	tracker.cancel("ana")
	assert_false(tracker.is_channeling("ana"))
	assert_eq(tracker.interrupted_count, 0)
	assert_eq(tracker.get_channeling(), PackedStringArray())
	assert_eq(tracker.update("ana", 10, true, false), UnstuckTracker.UpdateResult.CHANNELING, "sin canal no pasa nada")


func test_shorter_times_can_be_set_for_tests_and_expired_cooldowns_are_purged() -> void:
	var tracker := UnstuckTracker.new()
	tracker.channel_ticks = 10
	tracker.cooldown_ticks = 20
	tracker.request("ana", 0, true, false)
	assert_eq(tracker.update("ana", 10, true, false), UnstuckTracker.UpdateResult.COMPLETED)
	tracker.request("bob", 100, true, false)
	assert_eq(tracker.update("bob", 110, true, false), UnstuckTracker.UpdateResult.COMPLETED)
	assert_eq(tracker.cooldown_remaining("ana", 110), 0, "la de ana ya venció")
	assert_eq(tracker.get_channeling(), PackedStringArray())
