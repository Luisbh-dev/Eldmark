class_name CurrencyRules
extends RefCounted
## The balance rules (docs/progression.md §5.4, I5): [code]0 ≤ balance ≤ Currency.CAP[/code] and
## [code]balance = Σ delta[/code] of its entries. An operation that would leave a negative balance
## or one above the cap is not applied at all ([method can_apply]); an in-game gain that exceeds
## the cap is clamped ([method clamp_gain]). The same as the CHECK on [code]character_wallets[/code]
## and the platform's [code]UPDATE … WHERE balance + delta >= 0[/code]. Pure and shared: no clock,
## no randomness.
## [br][br]
## The arithmetic does not add before comparing: with [code]delta[/code] near 2^63,
## [code]balance + delta[/code] would wrap around.


## true if [param balance] is a valid balance and [param delta] leaves it between 0 and
## [constant Currency.CAP] (0 leaves it unchanged: valid).
static func can_apply(balance: int, delta: int) -> bool:
	if balance < 0 or balance > Currency.CAP:
		return false
	return delta >= -balance and delta <= Currency.CAP - balance


## What gets applied of an in-game gain [param gain] on [param balance]: what fits up to the cap
## (never negative). With [param gain] ≤ 0 or an out-of-range balance, 0.
static func clamp_gain(balance: int, gain: int) -> int:
	if gain <= 0 or balance < 0 or balance >= Currency.CAP:
		return 0
	return mini(gain, Currency.CAP - balance)


## The balance left by the entries [param deltas] applied in order from [param start] (0: the
## reconstruction from the ledger, §5.4), or −1 if any is 0 or leaves the balance out of range at
## any step.
static func replay(deltas: PackedInt64Array, start: int = 0) -> int:
	if start < 0 or start > Currency.CAP:
		return -1
	var balance: int = start
	for delta: int in deltas:
		if delta == 0 or not can_apply(balance, delta):
			return -1
		balance += delta
	return balance
