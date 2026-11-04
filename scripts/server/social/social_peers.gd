class_name SocialPeers
extends RefCounted
## Lookups of players shared by chat and parties (docs/social.md, sections 1 and 12): who is in the world and who has a
## given name. Static functions over the peer list given by the [ZoneServer]; they keep no state.


## From [param peers], those that are inside the world with their character already created.
static func in_world(peers: Array[ServerPeer]) -> Array[ServerPeer]:
	var result: Array[ServerPeer] = []
	for peer: ServerPeer in peers:
		if peer.state == ServerPeer.State.IN_WORLD and peer.entity != null:
			result.append(peer)
	return result


## Comparison key of the name of [param peer] ([method NameRules.normalize_key]), computed once.
static func name_key_of(peer: ServerPeer) -> String:
	if peer.chat.name_key.is_empty():
		peer.chat.name_key = NameRules.normalize_key(peer.display_name)
	return peer.chat.name_key


## The player in [param peers] named [param name] (ignoring case and accents) and of realm [param realm]; null if there
## is none. A player of another realm is not found: for the searcher it is as if they were not connected and it is not
## revealed that they exist (docs/social.md, section 1).
static func find_by_name(peers: Array[ServerPeer], name: String, realm: int) -> ServerPeer:
	var key: String = NameRules.normalize_key(name)
	if key.is_empty():
		return null
	for peer: ServerPeer in peers:
		if peer.realm == realm and name_key_of(peer) == key:
			return peer
	return null


## The player in [param peers] named [param name], of whatever realm (ignoring case and accents); null if not there.
## Only for what also works with enemies (ignore, report, moderation, docs/social.md section 1); chat and parties use
## [method find_by_name].
static func find_any_by_name(peers: Array[ServerPeer], name: String) -> ServerPeer:
	var key: String = NameRules.normalize_key(name)
	if key.is_empty():
		return null
	for peer: ServerPeer in peers:
		if name_key_of(peer) == key:
			return peer
	return null


## true if [param receiver] ignores the account of [param sender] (docs/platform.md §9.3): what [param sender] writes,
## whispers or invites them to does not reach them. Without a platform nobody has an account and nobody ignores anyone.
static func ignores(receiver: ServerPeer, sender: ServerPeer) -> bool:
	return receiver != sender and receiver.chat.ignores_account(sender.chat.account_id)
