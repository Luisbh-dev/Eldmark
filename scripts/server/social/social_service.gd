class_name SocialService
extends RefCounted
## A zone server's social service (docs/social.md, section 12): it brings together the [ChatRouter] and the
## [PartyManager], and is the only thing of chat and parties that the [ZoneServer] knows, which passes it each message of
## types [constant FIRST_TYPE] to [constant LAST_TYPE], notifies it of who leaves ([method on_peer_left]) and gives it one
## step per tick ([method step]). That way the social part lives in [code]scripts/server/social/[/code] and the zone
## server is touched as little as possible.
## [br][br]
## The chat's party channel delivers to the members given by the [PartyManager] and the parties' system messages go out
## through the [ChatRouter].
## [br][br]
## [b]Chat state per character[/b] (docs/platform.md §9.2, P7b). With a platform, the [ChatPeerState] of whoever leaves
## is kept by its [code]character_id[/code] for [constant ChatRouter.KNOWN_RECIPIENT_TICKS] ticks (5 min) and, if it
## re-enters this instance, [method on_peer_joined] gives it back: leaving and coming back does not refill the bursts. On
## entering, its account, those it ignores and its mute are also set, from the claim. Without a platform, per connection,
## as in phase 4.
## [br][br]
## It touches neither the network nor the clock. It receives from the [ZoneServer] three [Callable]s
## ([code]peers_source() -> Array[ServerPeer][/code], [code]send_sink(peer_id: int, bytes: PackedByteArray)[/code] over
## the reliable channel and [code]strike_sink(peer: ServerPeer, reason: String)[/code]) and the tick on each call.

## First and last message type this service handles (the social range of protocol 5: chat from 0x40 and parties from
## 0x48).
const FIRST_TYPE: int = 0x40
const LAST_TYPE: int = 0x4F
## Every how many ticks the retained states that have already expired are forgotten.
const RETAINED_PURGE_TICKS: int = 600


# The chat state of a character that has left, and when.
class _Kept:
	extends RefCounted

	var state: ChatPeerState = null
	var left_tick: int = 0


var _chat: ChatRouter
var _party: PartyManager
# character_id -> the state of whoever left less than KNOWN_RECIPIENT_TICKS ago.
var _retained: Dictionary[int, _Kept] = {}
var _reattached: int = 0


func _init(peers_source: Callable, send_sink: Callable, strike_sink: Callable) -> void:
	_chat = ChatRouter.new(peers_source, send_sink, strike_sink)
	_party = PartyManager.new(peers_source, send_sink, strike_sink, Callable(_chat, "send_system"))
	_chat.party_members = Callable(_party, "members_of")


## true if [param msg_type] is a message type of this service.
static func handles_type(msg_type: int) -> bool:
	return msg_type >= FIRST_TYPE and msg_type <= LAST_TYPE


## The chat router.
func get_chat() -> ChatRouter:
	return _chat


## The parties.
func get_party() -> PartyManager:
	return _party


## Handles the message [param bytes] of type [param msg_type] that arrived from [param peer] at tick [param now_tick].
## Returns false if the type is not this service's, or is one that only the server sends (and nothing was done): the
## caller decides what to do (the zone server adds a strike for an unexpected type).
func handle_packet(peer: ServerPeer, msg_type: int, bytes: PackedByteArray, now_tick: int) -> bool:
	if msg_type == NetProtocol.MSG_CHAT_SEND:
		_chat.handle_send(peer, bytes, now_tick)
		return true
	return _party.handle_packet(peer, msg_type, bytes, now_tick)


## [param peer] enters the world at tick [param now_tick]. With a platform (its claim), it recovers its character's chat
## state if it left less than [constant ChatRouter.KNOWN_RECIPIENT_TICKS] ticks ago and takes from the claim its account,
## the accounts it ignores and its mute.
func on_peer_joined(peer: ServerPeer, now_tick: int) -> void:
	var claimed: ClaimedCharacter = peer.claimed
	if claimed == null:
		return
	var kept: _Kept = _retained.get(claimed.character_id)
	if kept != null:
		_retained.erase(claimed.character_id)
		if now_tick - kept.left_tick < ChatRouter.KNOWN_RECIPIENT_TICKS:
			peer.chat = kept.state
			_reattached += 1
	var state: ChatPeerState = peer.chat
	state.name_key = ""
	state.account_id = claimed.account_id
	state.ignored_accounts.clear()
	for account_id: int in claimed.ignored_accounts:
		state.ignored_accounts[account_id] = true
	state.muted_until_unix = claimed.muted_until_unix
	state.mute_changed_msec = -1


## [param peer] has left the zone (it is no longer in the world): it leaves its party and its invitations are cancelled.
## With a platform, if it ever was in the world, its chat state is kept by its character.
func on_peer_left(peer: ServerPeer, now_tick: int) -> void:
	_party.on_peer_left(peer, now_tick)
	if peer.claimed != null and peer.entity != null:
		var kept := _Kept.new()
		kept.state = peer.chat
		kept.left_tick = now_tick
		_retained[peer.claimed.character_id] = kept


## One server tick: invitations expire and, at 2 Hz, the parties' state goes out. Every [constant RETAINED_PURGE_TICKS]
## ticks the retained chat states that have already expired are forgotten.
func step(now_tick: int) -> void:
	_party.step(now_tick)
	if now_tick % RETAINED_PURGE_TICKS == 0 and not _retained.is_empty():
		for character_id: int in _retained.keys():
			if now_tick - _retained[character_id].left_tick >= ChatRouter.KNOWN_RECIPIENT_TICKS:
				_retained.erase(character_id)


## Retained chat states of characters that have left.
func get_retained_count() -> int:
	return _retained.size()


## Statistics for the report.
func get_stats() -> Dictionary:
	return {"chat": _chat.get_stats(), "party": _party.get_stats(), "retained": _retained.size(),
			"reattached": _reattached}
