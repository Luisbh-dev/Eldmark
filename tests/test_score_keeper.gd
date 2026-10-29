extends TestCase
## El marcador de la batalla ([ScoreKeeper], docs/fuerte.md sección 6; UI-41): contadores por jugador,
## méritos provisionales (bajas x 10 + asistencias x 5 + segundos en el círculo) y las filas del
## SCOREBOARD.


func test_counters_and_merits() -> void:
	var scores := ScoreKeeper.new()
	scores.add_kill(2)
	scores.add_kill(2)
	scores.add_assist(2)
	scores.add_death(2)
	scores.add_gate_damage(2, 120)
	scores.add_gate_damage(2, 0)
	scores.add_gate_damage(2, -5)
	scores.add_circle_ticks(2, 180)
	scores.add_circle_ticks(2, 59)
	var entry: ScoreKeeper.Entry = scores.get_entry(2)
	assert_eq(entry.kills, 2)
	assert_eq(entry.assists, 1)
	assert_eq(entry.deaths, 1)
	assert_eq(entry.gate_damage, 120, "el daño no positivo no cuenta")
	assert_eq(entry.circle_seconds(), 3, "239 ticks son 3 segundos enteros")
	assert_eq(entry.merits(), 2 * 10 + 1 * 5 + 3, "bajas x 10 + asistencias x 5 + segundos en el círculo")
	assert_null(scores.get_entry(9), "quien no ha hecho nada no tiene ficha")
	assert_eq(scores.size(), 1)


func test_rows_follow_the_order_given_and_zero_the_unknown() -> void:
	var scores := ScoreKeeper.new()
	scores.add_kill(7)
	scores.add_death(3)
	var rows: Array[NetMessages.ScoreRow] = scores.build_rows([3, 5, 7] as Array[int])
	assert_eq(rows.size(), 3)
	assert_eq(rows[0].net_id, 3)
	assert_eq(rows[0].deaths, 1)
	assert_eq(rows[1].net_id, 5)
	assert_eq(rows[1].kills + rows[1].deaths + rows[1].merits, 0, "sin ficha: todo a cero")
	assert_eq(rows[2].kills, 1)
	assert_eq(rows[2].merits, 10)


func test_forget_and_clear() -> void:
	var scores := ScoreKeeper.new()
	scores.add_kill(1)
	scores.add_kill(2)
	scores.forget(1)
	assert_null(scores.get_entry(1), "al irse un jugador su id puede ser de otro")
	assert_not_null(scores.get_entry(2))
	scores.clear()
	assert_eq(scores.size(), 0)


func test_the_rows_fit_a_scoreboard_message_and_split_in_pages() -> void:
	var scores := ScoreKeeper.new()
	var ids: Array[int] = []
	for id: int in range(1, 71):
		ids.append(id)
		scores.add_kill(id)
	var pages: Array[NetMessages.Scoreboard] = NetMessages.Scoreboard.split(scores.build_rows(ids))
	assert_eq(pages.size(), 2)
	assert_eq(pages[0].rows.size(), 66)
	assert_eq(pages[1].rows.size(), 4)
	var decoded: NetMessages.Scoreboard = NetMessages.Scoreboard.decode(pages[0].encode())
	if assert_not_null(decoded):
		assert_eq(decoded.rows[65].net_id, 66)
		assert_eq(decoded.rows[0].merits, 10)
