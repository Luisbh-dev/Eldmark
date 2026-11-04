class_name ChatRouter
extends RefCounted
## Chat routing on the zone server (SOC-04, docs/social.md, sections 1, 2, 5 and 12).
## [br][br]
## It receives each already-authenticated CHAT_SEND ([method handle_send]), applies the per-connection rates, sanitizes
## it ([ChatText]) and delivers it with a CHAT_MESSAGE only to whoever should see it. [b]It never sends a client a text
## from another realm[/b]: the recipient list is filtered by realm when built (the client cannot ask for what the server
## does not send), and the acceptance test looks at the received bytes, not at what is drawn.
## [br][br]
## [b]Channels[/b] of phase 4:
## [br]- [b]Say[/b]: those of the same realm within [constant SAY_RANGE] m of the sender (including the sender).
## [br]- [b]Zone[/b]: everyone of the same realm present in the process (the zone and its copy are the process).
## [br]- [b]Whisper[/b]: a character of the same realm in this process, by name (ignoring case and accents). If they are
## not there, or belong to the other realm, the response is the same, "no está conectado" (not connected), and it is not
## revealed that they exist. The recipient and the sender themselves (their copy) receive it.
## [br]- [b]Party[/b]: the members of their party, wherever they come from; given by [member party_members].
## [br]- Band, guild, realm and GM have an id but are not yet delivered: "Ese canal aún no está disponible" (that channel
## is not available yet) (on GM, "Comando desconocido" (unknown command), so as not to reveal that it exists).
## [br][br]
## [b]Reply (/r).[/b] Resolved by the client: it remembers whom it last talked to and sends a whisper to that name. The
## server does not store "the last conversation partner" because it is not needed (a whisper to a name that is no longer
## connected gets the usual response) and so the protocol does not need one more channel.
## [br][br]
## [b]Rates[/b] (per connection, [RateLimiter] in ticks, docs/social.md section 5). Each CHAT_SEND first spends a token
## from its bucket, [b]before sanitizing[/b] or answering anything: sanitizing is not free and a text that ends up empty,
## or a channel with no service, also cost. Say, zone, party and the channels with no service share 1 message per second
## with a burst of 5; whisper, 1 per second with a burst of 3 and at most 5 new recipients per minute (whoever has talked
## to you in the last [constant KNOWN_RECIPIENT_TICKS] ticks does not count as new, and neither do you for them). A text
## equal to the last one accepted within [constant REPEAT_WINDOW_TICKS] ticks is discarded if it goes to the same place:
## public channels share the check and in a whisper the recipient counts ("ok" to two people goes through). What is
## discarded warns the player through the system channel ("Hablas demasiado rápido." (you talk too fast) or "Ya has
## enviado ese mensaje." (you already sent that message), at most one warning per second); the first
## [constant ChatPeerState.FLOOD_FREE_DISCARDS] discards in each 10 s add nothing and, from there, each one adds a
## strike to the peer (50 in 600 ticks kick): pressing Enter too many times kicks nobody, sustained flooding does.
## [br][br]
## [b]Moderation[/b] (docs/platform.md §9.2 to §9.5, P7b). Since protocol 7 the GM channel carries the commands the
## server handles ([code]/gm …[/code], [code]/ignorar[/code], [code]/designorar[/code], [code]/reportar[/code]): with
## [member command_sink] set, the sanitized text goes there (after spending its token and without the repetition check).
## Whoever is muted ([member ChatPeerState.muted_until_unix]) does not talk on any channel and receives "Estás
## silenciado N min más." (you are muted for N more min). A receiver who ignores the sender's account does not receive
## their message on any channel (in a whisper the sender receives their copy anyway: they do not know they are ignored).
## With [member keep_received], each receiver records what it receives in its ring (the evidence for a report) and, with
## [member log_sink], each delivered message from a character goes to the platform's chat batch.
## [br][br]
## It touches neither the network nor the clock: it receives from whoever assembles it ([SocialService]) three
## [Callable]s ([code]peers_source() -> Array[ServerPeer][/code], [code]send_sink(peer_id: int, bytes:
## PackedByteArray)[/code] and [code]strike_sink(peer: ServerPeer, reason: String)[/code]) and the tick on each call; the
## Unix time (mutes and chat batch), from [member clock_unix].

## Result of [method handle_send] and [method route], for tests and reports.
enum Result {
	## Delivered to whoever it was meant for.
	DELIVERED,
	## The message did not decode, or the peer is not in the world yet, or it is a channel a client does not use: adds a
	## strike.
	MALFORMED,
	## Discarded by rate.
	RATE_LIMITED,
	## Discarded for being equal to the previous one.
	REPEATED,
	## Empty text after sanitizing: discarded (it already spent its token) without telling anyone.
	EMPTY,
	## Channel with no service in phase 4.
	UNAVAILABLE,
	## Whisper to someone who is not there (or to an enemy), to oneself, or party chat without a party: the sender is
	## answered.
	NO_TARGET,
	## A GM channel command delivered to [member command_sink].
	COMMAND,
	## The sender is muted: nothing goes out and they are told how much time they have left.
	MUTED,
}

## Distance (m) that "say" reaches.
const SAY_RANGE: float = 30.0
## Ticks in which a text identical to the previous one (to the same place) is discarded (10 s).
const REPEAT_WINDOW_TICKS: int = 600
## Minimum ticks between two discarded-message warnings to the same player (1 s). Party invitations ([PartyManager]) use
## the same interval for "Invitas demasiado rápido." (you invite too fast).
const WARNING_INTERVAL_TICKS: int = 60
## Ticks for which a whisper conversation partner stops counting as "new" (5 min).
const KNOWN_RECIPIENT_TICKS: int = 18000
## Reason with which strikes for flooding the chat are added.
const STRIKE_REASON_FLOOD: String = "exceso de mensajes de chat"
const STRIKE_REASON_MALFORMED: String = "mensaje de chat mal formado"
const STRIKE_REASON_NOT_IN_WORLD: String = "chat antes de entrar en el mundo"

const TEXT_TOO_FAST: String = "Hablas demasiado rápido."
const TEXT_REPEATED: String = "Ya has enviado ese mensaje."
const TEXT_UNAVAILABLE: String = "Ese canal aún no está disponible."
const TEXT_UNKNOWN_COMMAND: String = "Comando desconocido. Escribe /ayuda."
const TEXT_NOT_CONNECTED: String = "«%s» no está conectado."
const TEXT_SELF_WHISPER: String = "No puedes susurrarte a ti mismo."
const TEXT_NO_PARTY: String = "No estás en un grupo."
const TEXT_MUTED: String = "Estás silenciado %d min más."
const TEXT_MUTED_NO_END: String = "Estás silenciado sin fecha de fin."

## Who provides a peer's party members: [code](peer: ServerPeer) -> Array[ServerPeer][/code]. Without it (or empty)
## nobody has a party and the party channel answers "No estás en un grupo." (you are not in a party).
var party_members: Callable = Callable()
## Who handles the GM channel commands: [code](peer: ServerPeer, line: String, now_tick: int) -> void[/code]
## ([ModerationService]). Without it, the GM channel answers "Comando desconocido. Escribe /ayuda." (unknown command,
## type /ayuda) as in phase 4.
var command_sink: Callable = Callable()
## With a platform: receives the chat batch entry of each delivered message from a character,
## [code](entry: Dictionary) -> void[/code] with [code]{channel, sender_character_id, target_character_id, text,
## sent_at_unix}[/code] (docs/platform.md §9.2; the [code]key[/code] is set by [ZonePlatform]).
var log_sink: Callable = Callable()
## Unix time, [code]() -> int[/code] (with a platform, [method ZonePlatform.now_unix]).
var clock_unix: Callable = Callable()
## Whether each receiver records what it receives in its ring ([method ChatPeerState.remember_received]).
var keep_received: bool = false

var _peers_source: Callable
var _send_sink: Callable
var _strike_sink: Callable
var _routed: int = 0
var _delivered_copies: int = 0
var _ignored_copies: int = 0
var _logged: int = 0
var _results: Dictionary[int, int] = {}


func _init(peers_source: Callable, send_sink: Callable, strike_sink: Callable) -> void:
	_peers_source = peers_source
	_send_sink = send_sink
	_strike_sink = strike_sink


## Handles a CHAT_SEND from [param peer] arriving at tick [param now_tick]: decodes and routes it. A malformed message,
## or one from someone not yet in the world, adds a strike. Returns the [enum Result].
func handle_send(peer: ServerPeer, bytes: PackedByteArray, now_tick: int) -> int:
	if peer.state != ServerPeer.State.IN_WORLD or peer.entity == null:
		_strike_sink.call(peer, STRIKE_REASON_NOT_IN_WORLD)
		return _count(Result.MALFORMED)
	var message: NetMessages.ChatSend = NetMessages.ChatSend.decode(bytes)
	if message == null:
		_strike_sink.call(peer, STRIKE_REASON_MALFORMED)
		return _count(Result.MALFORMED)
	return route(peer, message, now_tick)


## Routes an already decoded message from [param peer] (in the world). See the class documentation.
func route(peer: ServerPeer, message: NetMessages.ChatSend, now_tick: int) -> int:
	var state: ChatPeerState = peer.chat
	# Rate before anything else: neither sanitizing nor system replies are free.
	var limiter: RateLimiter = state.limiter_whisper \
			if message.channel == ChatChannel.Id.WHISPER else state.limiter_public
	if not limiter.try_consume(now_tick):
		state.discarded_rate += 1
		_note_discard(peer, now_tick, TEXT_TOO_FAST)
		return _count(Result.RATE_LIMITED)
	if message.channel == ChatChannel.Id.GM and command_sink.is_valid():
		# A command for the server (docs/platform.md §9): neither repetition nor mute, since it is not chat.
		var line: String = ChatText.sanitize(message.text)
		if line.is_empty():
			state.discarded_empty += 1
			return _count(Result.EMPTY)
		command_sink.call(peer, line, now_tick)
		return _count(Result.COMMAND)
	if not ChatChannel.is_implemented(message.channel):
		state.rejected_channel += 1
		var text: String = TEXT_UNKNOWN_COMMAND if message.channel == ChatChannel.Id.GM \
				else TEXT_UNAVAILABLE
		send_system(peer, text, now_tick)
		return _count(Result.UNAVAILABLE)
	# Muted (docs/platform.md §9.5): it does not talk on any channel.
	var now_unix: int = _now_unix()
	if state.mute_remaining_s(now_unix) > 0:
		state.discarded_muted += 1
		send_system(peer, muted_text(state, now_unix), now_tick)
		return _count(Result.MUTED)
	var text_clean: String = ChatText.sanitize(message.text)
	if text_clean.is_empty():
		state.discarded_empty += 1
		return _count(Result.EMPTY)

	# Repetition: the same text to the same place (public channels share a key).
	var repeat_key: String = _repeat_key(message)
	if text_clean == state.last_text and repeat_key == state.last_text_key \
			and now_tick - state.last_text_tick < REPEAT_WINDOW_TICKS:
		state.discarded_repeat += 1
		_note_discard(peer, now_tick, TEXT_REPEATED)
		return _count(Result.REPEATED)

	var result: int = Result.DELIVERED
	match message.channel:
		ChatChannel.Id.SAY:
			_deliver(peer, _say_recipients(peer), message.channel, null, text_clean, now_tick)
		ChatChannel.Id.ZONE:
			_deliver(peer, _zone_recipients(peer), message.channel, null, text_clean, now_tick)
		ChatChannel.Id.PARTY:
			result = _route_party(peer, text_clean, now_tick)
		ChatChannel.Id.WHISPER:
			result = _route_whisper(peer, message.recipient, text_clean, now_tick)
	if result == Result.DELIVERED:
		state.accepted += 1
		state.last_text = text_clean
		state.last_text_key = repeat_key
		state.last_text_tick = now_tick
	return _count(result)


## Sends [param peer] a system channel message (what would previously have been a chat NOTICE).
func send_system(peer: ServerPeer, text: String, now_tick: int) -> void:
	var message := NetMessages.ChatMessage.new()
	message.channel = ChatChannel.Id.SYSTEM
	message.tick = now_tick
	message.text = text
	_send_sink.call(peer.peer_id, message.encode())


## The mute notice of [param state] at Unix time [param now_unix]: the minutes left, rounded up, or "sin fecha de fin"
## (no end date).
static func muted_text(state: ChatPeerState, now_unix: int) -> String:
	if state.muted_until_unix >= ChatPeerState.MUTE_NO_END_UNIX:
		return TEXT_MUTED_NO_END
	return TEXT_MUTED % ceili(float(state.mute_remaining_s(now_unix)) / 60.0)


## Statistics for the report: messages processed, copies delivered, copies that did not go out because the receiver
## ignores the sender, chat batch entries and how many ended in each [enum Result].
func get_stats() -> Dictionary:
	var by_result: Dictionary = {}
	for result: int in _results:
		by_result[Result.keys()[result].to_lower()] = _results[result]
	return {"routed": _routed, "delivered_copies": _delivered_copies, "ignored_copies": _ignored_copies,
			"logged": _logged, "results": by_result}


# --- Recipients ----------------------------------------------------------------------------

# Those of the same realm within SAY_RANGE m of the sender (including the sender).
func _say_recipients(sender: ServerPeer) -> Array[ServerPeer]:
	var origin: Vector3 = sender.entity.get_position()
	var result: Array[ServerPeer] = []
	for other: ServerPeer in _world_peers():
		if other.realm == sender.realm and other.entity.get_position().distance_to(origin) <= SAY_RANGE:
			result.append(other)
	return result


# Everyone of the same realm present in the process (including the sender).
func _zone_recipients(sender: ServerPeer) -> Array[ServerPeer]:
	var result: Array[ServerPeer] = []
	for other: ServerPeer in _world_peers():
		if other.realm == sender.realm:
			result.append(other)
	return result


func _route_party(sender: ServerPeer, text: String, now_tick: int) -> int:
	var members: Array[ServerPeer] = []
	if party_members.is_valid():
		var found: Variant = party_members.call(sender)
		for member: ServerPeer in found:
			# A party belongs to a single realm; the check is the last defense of the realm filter.
			if member.realm == sender.realm and member.state == ServerPeer.State.IN_WORLD:
				members.append(member)
	if members.is_empty():
		send_system(sender, TEXT_NO_PARTY, now_tick)
		return Result.NO_TARGET
	_deliver(sender, members, ChatChannel.Id.PARTY, null, text, now_tick)
	return Result.DELIVERED


func _route_whisper(sender: ServerPeer, recipient_name: String, text: String, now_tick: int) -> int:
	var state: ChatPeerState = sender.chat
	var target: ServerPeer = SocialPeers.find_by_name(_world_peers(), recipient_name, sender.realm)
	if target == null:
		# Same for whoever does not exist and for an enemy: nothing reveals which of the two it is. What the player typed is
		# repeated, not the other's canonical name.
		state.whisper_misses += 1
		var shown: String = ChatText.clean(recipient_name).substr(0, NetProtocol.MAX_NAME_CHARS)
		send_system(sender, TEXT_NOT_CONNECTED % shown, now_tick)
		return Result.NO_TARGET
	if target == sender:
		send_system(sender, TEXT_SELF_WHISPER, now_tick)
		return Result.NO_TARGET
	# New recipients: a recent conversation partner does not spend from the bucket.
	var key: String = SocialPeers.name_key_of(target)
	if not state.knows_recipient(key, now_tick, KNOWN_RECIPIENT_TICKS):
		if not state.limiter_new_recipients.try_consume(now_tick):
			state.discarded_rate += 1
			_note_discard(sender, now_tick, TEXT_TOO_FAST)
			return Result.RATE_LIMITED
	# Both sides are pruned before recording: the dictionary of someone who only receives whispers also stays limited to
	# the conversation partners of the last KNOWN_RECIPIENT_TICKS ticks.
	state.forget_old_recipients(now_tick, KNOWN_RECIPIENT_TICKS)
	state.remember_recipient(key, now_tick)
	target.chat.forget_old_recipients(now_tick, KNOWN_RECIPIENT_TICKS)
	target.chat.remember_recipient(SocialPeers.name_key_of(sender), now_tick)
	# If the recipient ignores the sender, only the sender's copy goes out: they do not know they are ignored (§9.3).
	var copies: Array[ServerPeer] = [target, sender]
	_deliver(sender, copies, ChatChannel.Id.WHISPER, target, text, now_tick)
	return Result.DELIVERED


# --- Sending ----------------------------------------------------------------------------------

# CHAT_MESSAGE from [param sender] with already sanitized [param text], to each of [param recipients] who does not
# ignore their account ([param target]: the recipient of a whisper, null in other channels). With
# [member keep_received], each receiver records it in its ring and, with [member log_sink], the message goes to the chat
# batch.
func _deliver(sender: ServerPeer, recipients: Array[ServerPeer], channel: int, target: ServerPeer,
		text: String, now_tick: int) -> void:
	var message := NetMessages.ChatMessage.new()
	message.channel = channel
	message.sender_realm = sender.realm
	message.tick = now_tick
	message.sender = sender.display_name
	message.recipient = target.display_name if target != null else ""
	message.text = text
	var bytes: PackedByteArray = message.encode()
	var now_unix: int = _now_unix() if keep_received or log_sink.is_valid() else 0
	var line: ChatPeerState.Received = null
	var copies: int = 0
	for peer: ServerPeer in recipients:
		if SocialPeers.ignores(peer, sender):
			_ignored_copies += 1
			continue
		_send_sink.call(peer.peer_id, bytes)
		copies += 1
		if keep_received and peer != sender:
			if line == null:
				line = ChatPeerState.Received.new()
				line.sender_key = SocialPeers.name_key_of(sender)
				line.sender_name = sender.display_name
				line.channel = channel
				line.text = text
				line.sent_at_unix = now_unix
				line.tick = now_tick
			peer.chat.remember_received(line)
	sender.chat.delivered += copies
	_delivered_copies += copies
	if log_sink.is_valid() and sender.claimed != null:
		var target_id: Variant = null
		if target != null and target.claimed != null:
			target_id = str(target.claimed.character_id)
		_logged += 1
		log_sink.call({"channel": channel, "sender_character_id": str(sender.claimed.character_id),
				"target_character_id": target_id, "text": text, "sent_at_unix": now_unix})


# A discarded message: [param warning] to the player (at most one warning per second) and, after the window's free
# discards, a strike on the peer.
func _note_discard(peer: ServerPeer, now_tick: int, warning: String) -> void:
	var state: ChatPeerState = peer.chat
	state.discards += 1
	if state.last_warning_tick < 0 or now_tick - state.last_warning_tick >= WARNING_INTERVAL_TICKS:
		state.last_warning_tick = now_tick
		send_system(peer, warning, now_tick)
	if state.chat_flood.note(now_tick):
		_strike_sink.call(peer, STRIKE_REASON_FLOOD)


# Where a message goes, for repetition: public channels share a key; a whisper, the recipient's as it is looked up
# ([method SocialPeers.find_by_name]).
static func _repeat_key(message: NetMessages.ChatSend) -> String:
	if message.channel != ChatChannel.Id.WHISPER:
		return ""
	return "w:" + NameRules.normalize_key(message.recipient)


func _now_unix() -> int:
	if clock_unix.is_valid():
		return int(clock_unix.call())
	return int(Time.get_unix_time_from_system())


func _world_peers() -> Array[ServerPeer]:
	var peers: Array[ServerPeer] = _peers_source.call()
	return SocialPeers.in_world(peers)


func _count(result: int) -> int:
	_routed += 1
	_results[result] = _results.get(result, 0) + 1
	return result
