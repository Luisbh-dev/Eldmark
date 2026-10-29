class_name ClientServices
extends Node
## Servicios que todo cliente necesita y que no pertenecen a ninguna escena de juego: el
## [AudioDirector] (ART-10) y, a medida que lleguen, los ajustes (UI-16).
## [br][br]
## Es un nodo hijo de las escenas raíz del cliente ([code]client_main.tscn[/code] y
## [code]online_main.tscn[/code]), no un autoload ni algo que nombren sus scripts: el servidor
## dedicado carga los autoloads del proyecto y los scripts que [code]boot.gd[/code] nombra, y no debe cargar nada
## de esto. [method install] es la alternativa para montarlo a mano (pruebas, herramientas).

const NODE_NAME: String = "ClientServices"

var _audio: AudioDirector = null


## Cuelga los servicios de [param parent] (una sola vez: si ya están, devuelve los que había).
static func install(parent: Node) -> ClientServices:
	var existing: ClientServices = parent.get_node_or_null(NODE_NAME) as ClientServices
	if existing != null:
		return existing
	var services: ClientServices = ClientServices.new()
	services.name = NODE_NAME
	parent.add_child(services)
	return services


func _ready() -> void:
	_audio = AudioDirector.new()
	add_child(_audio)


## El director de audio de este cliente.
func get_audio() -> AudioDirector:
	return _audio
