class_name CurrencyRules
extends RefCounted
## Las reglas de los saldos (docs/progresion.md §5.4, I5): [code]0 ≤ saldo ≤ Currency.CAP[/code] y
## [code]saldo = Σ delta[/code] de sus apuntes. Una operación que dejaría un saldo negativo o por encima del
## tope no se aplica entera ([method can_apply]); una ganancia de juego que pasa del tope se recorta
## ([method clamp_gain]). Las mismas que el CHECK de [code]character_wallets[/code] y el
## [code]UPDATE … WHERE balance + delta >= 0[/code] de la plataforma. Puras y compartidas: sin reloj ni azar.
## [br][br]
## Las cuentas no suman antes de comparar: con [code]delta[/code] cerca de 2^63, [code]balance + delta[/code]
## daría la vuelta.


## true si [param balance] es un saldo válido y [param delta] lo deja entre 0 y [constant Currency.CAP]
## (0 lo deja igual: vale).
static func can_apply(balance: int, delta: int) -> bool:
	if balance < 0 or balance > Currency.CAP:
		return false
	return delta >= -balance and delta <= Currency.CAP - balance


## Lo que se aplica de una ganancia de juego [param gain] sobre [param balance]: lo que cabe hasta el tope
## (nunca negativo). Con [param gain] ≤ 0 o un saldo fuera de rango, 0.
static func clamp_gain(balance: int, gain: int) -> int:
	if gain <= 0 or balance < 0 or balance >= Currency.CAP:
		return 0
	return mini(gain, Currency.CAP - balance)


## El saldo que dejan los apuntes [param deltas] aplicados en orden desde [param start] (0: la
## reconstrucción desde el libro, §5.4), o −1 si alguno es 0 o deja el saldo fuera de rango en algún paso.
static func replay(deltas: PackedInt64Array, start: int = 0) -> int:
	if start < 0 or start > Currency.CAP:
		return -1
	var balance: int = start
	for delta: int in deltas:
		if delta == 0 or not can_apply(balance, delta):
			return -1
		balance += delta
	return balance
