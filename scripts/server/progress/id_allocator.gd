class_name IdAllocator
extends RefCounted
## Los ids de la zona (docs/progresion.md §4.5): los [code]uid[/code] de los objetos y los [code]op_id[/code] de
## las operaciones salen del mismo generador. Con plataforma, de los bloques de 1024 que da
## [code]POST /internal/v1/id-blocks[/code] ([method ZonePlatform.request_id_block], plataforma.md §6), únicos en
## todos los mundos; sin plataforma, [method local] cuenta desde 1 en memoria (nada se guarda).
## [br][br]
## [b]Tres tramos[/b], de abajo arriba en lo que queda:
## [codeblock]
## los últimos build_reserve (2 × max_players)   solo next_for_build: cerrar lo agregado al construir un guardado
## los SERVER_RESERVE de encima                  next_for_server: kit, pila nueva de CAMP_REFILL, cierre antes de una
##                                               operación suelta, GM y reversión
## el resto                                      next_for_client: SPLIT y DESTROY del cliente
## [/codeblock]
## Así ningún cliente deja a otro sin beber ni a la zona sin guardar: con la plataforma caída nada sale salvo el
## guardado en vuelo, nadie nuevo entra y cada personaje construye como mucho dos cuerpos, que la reserva cubre.
## Guarda dos bloques como mucho (pide otro cuando quedan menos de [constant REFILL_BELOW] por encima de la reserva
## de los guardados) y los gasta en orden. Un bloque a medias que se pierde en una caída deja un hueco: nunca se
## repite nada. Solo servidor: sin reloj.

## Avisa cuando, tras tomar un id, [method needs_block] es true: quien lo escucha pide el siguiente bloque.
signal running_low

## Ids de cada bloque de la plataforma.
const BLOCK_SIZE: int = 1024
## Se pide otro bloque cuando quedan menos que esto por encima de [member build_reserve].
const REFILL_BELOW: int = 512
## Ids del tramo del servidor, por encima de [member build_reserve].
const SERVER_RESERVE: int = 256
## Mayor id (2^53 − 1: un número JSON lo lleva exacto, §3.4).
const MAX_ID: int = (1 << 53) - 1

## El tramo de los guardados: 2 × [code]max_players[/code] (128 con 64 plazas); lo pone
## [method ProgressService.setup].
var build_reserve: int = 128

## Bloques que quedan: [code][siguiente, último][/code] (los dos incluidos), en el orden en que llegaron.
var _blocks: Array[PackedInt64Array] = []
## Sin plataforma: cuenta desde 1 sin tope ni tramos.
var _local: bool = false
var _local_next: int = 1
var _taken: int = 0


## El generador sin plataforma: desde 1, en memoria, sin bloques ni tramos (todos los personajes son efímeros).
static func local() -> IdAllocator:
	var ids := IdAllocator.new()
	ids._local = true
	return ids


## true si es el de [method local].
func is_local() -> bool:
	return _local


## Añade el bloque [code][first, first + count)[/code] que ha dado la plataforma. Un bloque que no vale (vacío,
## fuera de 1 … 2^53 − 1 o que se solapa con uno que queda) se ignora con aviso: es un error de la plataforma.
func add_block(first: int, count: int) -> void:
	if _local:
		return
	if first < 1 or count < 1 or count > MAX_ID or first > MAX_ID - count + 1:
		push_warning("[Eldmark] Ids: bloque que no vale (%d, %d)" % [first, count])
		return
	var last: int = first + count - 1
	for block: PackedInt64Array in _blocks:
		if first <= block[1] and last >= block[0]:
			push_warning("[Eldmark] Ids: el bloque (%d, %d) se solapa con uno que queda" % [first, count])
			return
	_blocks.append(PackedInt64Array([first, last]))


## true si hay que pedir otro bloque: quedan menos de [member build_reserve] + [constant REFILL_BELOW].
func needs_block() -> bool:
	return not _local and available() < build_reserve + REFILL_BELOW


## Ids que quedan en los bloques (sin plataforma, los que quedan hasta 2^53 − 1).
func available() -> int:
	if _local:
		return MAX_ID - _local_next + 1
	var total: int = 0
	for block: PackedInt64Array in _blocks:
		total += block[1] - block[0] + 1
	return total


## Un id para una petición del cliente (SPLIT, DESTROY); 0 si quedan [member build_reserve] +
## [constant SERVER_RESERVE] o menos.
func next_for_client() -> int:
	return _take(build_reserve + SERVER_RESERVE)


## Un id para el resto del servidor (kit, CAMP_REFILL, cierre antes de una operación suelta, GM, reversión); 0 si
## quedan [member build_reserve] o menos.
func next_for_server() -> int:
	return _take(build_reserve)


## Un id para cerrar lo agregado al construir un guardado ([method PlayerProgress.build_section]); 0 si no queda
## ninguno.
func next_for_build() -> int:
	return _take(0)


## Ids que se han dado desde que existe (métricas y pruebas).
func taken_count() -> int:
	return _taken


# El siguiente id si quedan más de [param keep]; 0 si no.
func _take(keep: int) -> int:
	if _local:
		if _local_next > MAX_ID:
			return 0
		_local_next += 1
		_taken += 1
		return _local_next - 1
	if available() <= keep or _blocks.is_empty():
		return 0
	var block: PackedInt64Array = _blocks[0]
	var id: int = block[0]
	if block[0] == block[1]:
		_blocks.remove_at(0)
	else:
		block[0] += 1
		_blocks[0] = block
	_taken += 1
	if needs_block():
		running_low.emit()
	return id
