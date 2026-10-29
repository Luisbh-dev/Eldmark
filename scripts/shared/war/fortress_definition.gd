class_name FortressDefinition
extends Resource
## Datos de una fortaleza capturable (docs/fuerte.md, sección 1.1), en
## [code]data/fortresses/<id>.tres[/code]. La escena de la zona apunta a ella con el metadato
## [code]definition[/code] del nodo de la fortaleza ([constant Zones.FORTRESS_GROUP]).
## [br][br]
## Todo se expresa en segundos y se convierte a ticks con los métodos [code]*_ticks()[/code]
## ([method CombatCatalog.seconds_to_ticks]), que son los que usa [FortressState]. El radio del
## círculo de captura no está aquí: sale solo del metadato [code]radius[/code] del marcador
## [code]CaptureCircle[/code] de la escena (5 m en el Vado Gris).
## [br][br]
## Compartido: no depende del cliente ni del servidor.

## Identificador de la fortaleza (el de la clave de [code]fortresses[/code] en
## [method RespawnRules.points_for] y el metadato [code]fortress[/code] de sus puntos de
## reaparición).
@export var id: StringName = &"vado_gris_fort"
## Nombre en español para los avisos de guerra y la interfaz.
@export var display_name: String = "Fuerte del Vado Gris"
## Segundos que tarda la captura con un solo atacante en el círculo.
@export_range(1.0, 600.0, 0.5, "suffix:s") var capture_s: float = 30.0
## Segundos con el círculo vacío antes de que el progreso empiece a decaer (a un tercio de la
## velocidad base).
@export_range(0.0, 120.0, 0.5, "suffix:s") var decay_after_empty_s: float = 5.0
## Altura (m) del cilindro del círculo de captura sobre su marcador.
@export_range(1.0, 20.0, 0.5, "suffix:m") var circle_height_m: float = 4.0
## Vida de la puerta.
@export_range(1, 1000000) var gate_health: int = 9000
## Segundos de consolidación tras una captura: círculo inactivo y puerta dañable hasta que llega
## la guarnición del nuevo dueño.
@export_range(0.0, 3600.0, 0.5, "suffix:s") var consolidation_s: float = 120.0
## Segundos hasta que reaparece el capitán muerto si nadie captura el fuerte.
@export_range(0.0, 3600.0, 0.5, "suffix:s") var captain_respawn_s: float = 300.0
## Segundos hasta que reaparecen los guardias muertos.
@export_range(0.0, 3600.0, 0.5, "suffix:s") var guard_respawn_s: float = 180.0
## Segundos que el fuerte cuenta como «atacado» tras un golpe a la puerta o a un defensor (no se
## puede reaparecer en él).
@export_range(0.0, 600.0, 0.5, "suffix:s") var under_attack_s: float = 30.0
## Segundos sin daño tras los que se repara la puerta.
@export_range(0.0, 3600.0, 0.5, "suffix:s") var gate_repair_after_s: float = 300.0
## Segundos tras los que el fuerte vuelve a neutral (solo en pruebas; 0 = nunca).
@export_range(0.0, 86400.0, 1.0, "suffix:s") var reset_to_neutral_s: float = 1800.0


## Ticks que dura la captura con un solo atacante.
func capture_ticks() -> int:
	return maxi(CombatCatalog.seconds_to_ticks(capture_s), 1)


## Ticks con el círculo vacío antes de que empiece el decaimiento.
func decay_after_empty_ticks() -> int:
	return CombatCatalog.seconds_to_ticks(decay_after_empty_s)


## Ticks de la consolidación.
func consolidation_ticks() -> int:
	return CombatCatalog.seconds_to_ticks(consolidation_s)


## Ticks hasta que reaparece el capitán.
func captain_respawn_ticks() -> int:
	return CombatCatalog.seconds_to_ticks(captain_respawn_s)


## Ticks hasta que reaparecen los guardias.
func guard_respawn_ticks() -> int:
	return CombatCatalog.seconds_to_ticks(guard_respawn_s)


## Ticks que el fuerte cuenta como atacado.
func under_attack_ticks() -> int:
	return CombatCatalog.seconds_to_ticks(under_attack_s)


## Ticks sin daño tras los que se repara la puerta.
func gate_repair_after_ticks() -> int:
	return CombatCatalog.seconds_to_ticks(gate_repair_after_s)


## Ticks tras los que el fuerte vuelve a neutral (0 = nunca).
func reset_to_neutral_ticks() -> int:
	return CombatCatalog.seconds_to_ticks(reset_to_neutral_s)
