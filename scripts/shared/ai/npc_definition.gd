class_name NpcDefinition
extends Resource
## Definición de un tipo de PNJ (docs/fuerte.md, sección 4.2; MUN-07): los datos que el servidor necesita para
## crearlo y para que su cerebro ([code]HfsmBrain[/code]) sepa cómo comportarse. Está en
## [code]data/npcs/<id>.tres[/code] (el [member id] es el nombre del archivo sin extensión) y la lista el
## [NpcCatalog], que da a cada una un número 1..n por orden alfabético: es el [code]npc_def_id[/code] del
## ENTITY_SPAWN que usa el cliente para elegir modelo, tabardo y barra de jefe.
## [br][br]
## Compartido porque los nodos de la zona (el [code]NpcSpawner[/code]) lo nombran. Las duraciones están en
## segundos y las distancias en metros; el cerebro las convierte a ticks.

## Identificador (el nombre del archivo en [code]data/npcs/[/code] sin extensión).
@export var id: StringName = &""
## Nombre que ven los jugadores.
@export var display_name: String = ""
## Vida máxima.
@export_range(1, 65535) var max_health: int = 1000
## Arma del catálogo de combate ([code]data/combat/npc_*.tres[/code]): sus ataques ligeros y fuertes, su
## bloqueo y su esquiva.
@export var weapon_id: StringName = &"npc_hollow"
## true: no muere (la vida no baja de 1). Solo los maniquíes.
@export var immortal: bool = false
## true: es un jefe (el cliente le pone barra de jefe).
@export var is_boss: bool = false
## true: ataca a los enemigos dentro de la zona segura de su propio reino y puede atacar desde ella (los
## Guardianes de la Puerta, docs/combate.md 5). Solo ataca a los enemigos que están dentro de esa zona.
@export var ignores_safe_area: bool = false

@export_group("Movimiento")
## Fracción de la velocidad de carrera (5 m/s) al patrullar y al volver.
@export_range(0.1, 1.0) var patrol_speed_scale: float = 0.45
## Fracción de la velocidad de carrera al perseguir.
@export_range(0.1, 1.0) var chase_speed_scale: float = 0.85
## true: esprinta (7,5 m/s) si el objetivo está lejos.
@export var can_sprint: bool = false

@export_group("Percepción")
## Radio de visión (m).
@export var perception_radius: float = 16.0
## Cono de visión (grados, total). 360 = ve a su alrededor.
@export_range(10.0, 360.0) var perception_cone_deg: float = 140.0
## Radio (m) en el que nota a alguien aunque esté a su espalda o sin línea de visión limpia (el oído).
@export var awareness_radius: float = 4.0
## A más de esta distancia (m) del objetivo, lo da por perdido.
@export var lose_radius: float = 28.0
## Radio (m) de la alerta de grupo: al entrar en combate avisa a los del mismo grupo a esta distancia.
@export var alert_radius: float = 25.0
## Tiempo (s) que tarda en reaccionar tras notar a alguien (mínimo y máximo; el azar sale de su semilla).
@export var reaction_s: Vector2 = Vector2(0.3, 0.7)

@export_group("Correa")
## Distancia máxima (m) a la que se aleja de su puesto persiguiendo. Más allá vuelve, regenerado e inmune.
@export var leash_radius: float = 32.0

@export_group("Combate")
## Probabilidad (0 a 1) de que un ataque sea el fuerte (cargado).
@export_range(0.0, 1.0) var heavy_chance: float = 0.2
## Probabilidad (0 a 1) de que, entre dos ataques, levante el escudo.
@export_range(0.0, 1.0) var block_chance: float = 0.12
## Duración (s) del bloqueo (mínimo y máximo).
@export var block_s: Vector2 = Vector2(0.6, 1.1)
## Pausa (s) entre un ataque y el siguiente (mínimo y máximo).
@export var attack_gap_s: Vector2 = Vector2(0.5, 1.2)
## Cada cuántos ataques lanza el ataque fuerte especial (el golpe imbloqueable del Capitán); 0 = nunca.
@export_range(0, 20) var special_every: int = 0
## Distancia (m) a la que rodea al objetivo cuando no tiene ficha de ataque (3 a 4 m).
@export var circle_distance: float = 3.5

@export_group("Jefe")
## true: al entrar en combate grita y alerta a los PNJ de su grupo.
@export var shouts: bool = false
## Definición de los refuerzos que llama al bajar de [member reinforcement_health_fraction] (vacío = ninguno).
@export var reinforcement_id: StringName = &""
## Cuántos refuerzos llama.
@export_range(0, 8) var reinforcement_count: int = 0
## Fracción de vida (0 a 1) por debajo de la cual llama a los refuerzos, una sola vez.
@export_range(0.0, 1.0) var reinforcement_health_fraction: float = 0.5

@export_group("Guarnición")
## Definición que lo sustituye en el mismo puesto cuando el fuerte tiene dueño (los Huecos dan paso a los
## guardias del reino, el Capitán del Vado al capitán del reino). Vacío = nadie.
@export var garrison_id: StringName = &""
