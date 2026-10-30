class_name AuthOutcome
extends RefCounted
## El final de una autenticación que quedó pendiente ([constant AuthProvider.PENDING]): lo devuelve
## [method AuthProvider.take_completed] en el paso «poll» del tick (docs/plataforma.md §5.2 y §14.3).

var peer_id: int = 0
## [constant NetProtocol.Result.OK] o el motivo del REJECT.
var result: int = NetProtocol.Result.UNAVAILABLE
## Texto del REJECT; vacío = [method NetProtocol.result_text]. En [constant NetProtocol.Result.BANNED], el
## [code]message[/code] del 403 [code]account_blocked[/code], que compone la plataforma.
var text: String = ""
## Con OK, lo que trajo la reclamación; null en un rechazo.
var claimed: ClaimedCharacter = null


func _init(p_peer_id: int = 0, p_result: int = NetProtocol.Result.UNAVAILABLE, p_text: String = "",
		p_claimed: ClaimedCharacter = null) -> void:
	peer_id = p_peer_id
	result = p_result
	text = p_text
	claimed = p_claimed
