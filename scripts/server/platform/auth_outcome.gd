class_name AuthOutcome
extends RefCounted
## The outcome of an authentication that was left pending ([constant AuthProvider.PENDING]): returned by
## [method AuthProvider.take_completed] in the tick's "poll" step (docs/platform.md §5.2 and §14.3).

var peer_id: int = 0
## [constant NetProtocol.Result.OK] or the REJECT reason.
var result: int = NetProtocol.Result.UNAVAILABLE
## REJECT text; empty = [method NetProtocol.result_text]. In [constant NetProtocol.Result.BANNED], the
## [code]message[/code] of the 403 [code]account_blocked[/code], which the platform composes.
var text: String = ""
## With OK, what the claim brought; null on a rejection.
var claimed: ClaimedCharacter = null


func _init(p_peer_id: int = 0, p_result: int = NetProtocol.Result.UNAVAILABLE, p_text: String = "",
		p_claimed: ClaimedCharacter = null) -> void:
	peer_id = p_peer_id
	result = p_result
	text = p_text
	claimed = p_claimed
