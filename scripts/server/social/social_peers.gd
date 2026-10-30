class_name SocialPeers
extends RefCounted
## Búsquedas de jugadores que comparten el chat y los grupos (docs/social.md, secciones 1 y 12): quién
## está en el mundo y quién se llama así. Funciones estáticas sobre la lista de peers que da el
## [ZoneServer]; no guardan estado.


## De [param peers], los que están dentro del mundo con su personaje ya creado.
static func in_world(peers: Array[ServerPeer]) -> Array[ServerPeer]:
	var result: Array[ServerPeer] = []
	for peer: ServerPeer in peers:
		if peer.state == ServerPeer.State.IN_WORLD and peer.entity != null:
			result.append(peer)
	return result


## Clave de comparación del nombre de [param peer] ([method NameRules.normalize_key]), calculada una vez.
static func name_key_of(peer: ServerPeer) -> String:
	if peer.chat.name_key.is_empty():
		peer.chat.name_key = NameRules.normalize_key(peer.display_name)
	return peer.chat.name_key


## El jugador de [param peers] que se llama [param name] (sin distinguir mayúsculas ni tildes) y es del
## reino [param realm]; null si no hay ninguno. Un jugador de otro reino no se encuentra: para quien
## busca es como si no estuviera conectado y no se revela que existe (docs/social.md, sección 1).
static func find_by_name(peers: Array[ServerPeer], name: String, realm: int) -> ServerPeer:
	var key: String = NameRules.normalize_key(name)
	if key.is_empty():
		return null
	for peer: ServerPeer in peers:
		if peer.realm == realm and name_key_of(peer) == key:
			return peer
	return null


## El jugador de [param peers] que se llama [param name], sea del reino que sea (sin distinguir mayúsculas ni
## tildes); null si no está. Solo para lo que funciona también con enemigos (ignorar, reportar, la moderación,
## docs/social.md sección 1); el chat y los grupos usan [method find_by_name].
static func find_any_by_name(peers: Array[ServerPeer], name: String) -> ServerPeer:
	var key: String = NameRules.normalize_key(name)
	if key.is_empty():
		return null
	for peer: ServerPeer in peers:
		if name_key_of(peer) == key:
			return peer
	return null


## true si [param receiver] ignora la cuenta de [param sender] (docs/plataforma.md §9.3): no le llega lo que
## [param sender] escribe, susurra o le invita. Sin plataforma nadie tiene cuenta y nadie ignora a nadie.
static func ignores(receiver: ServerPeer, sender: ServerPeer) -> bool:
	return receiver != sender and receiver.chat.ignores_account(sender.chat.account_id)
