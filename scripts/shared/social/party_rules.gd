class_name PartyRules
extends RefCounted
## Reglas de los grupos (SOC-06, docs/social.md, secciones 3 y 12.4), compartidas por el servidor (que las
## aplica) y el cliente (que las usa para pintar los marcos y no pedir lo que el servidor rechazaría).
## [br][br]
## Un grupo es de [constant NetProtocol.PARTY_MAX_SIZE] jugadores como mucho, del mismo reino; el primero es
## el líder y, si se va, el siguiente más antiguo hereda el mando. Una invitación caduca a los
## [constant INVITE_TTL_TICKS] ticks (60 s) y cada jugador puede tener como mucho
## [constant MAX_PENDING_PER_INVITER] enviadas a la vez. Compartido: no depende del cliente ni del servidor.

## Ticks que vale una invitación (60 s a 60 ticks por segundo).
const INVITE_TTL_TICKS: int = 3600
## Invitaciones pendientes como mucho por quien invita.
const MAX_PENDING_PER_INVITER: int = 5
## Ticks entre dos envíos del estado compacto de los miembros (2 Hz).
const STATUS_INTERVAL_TICKS: int = 30
## Distancia (m) a partir de la cual el marco de un miembro se ve atenuado (provisional: la del reparto de
## experiencia de docs/social.md, sección 3).
const FAR_DISTANCE: float = 100.0
## Pasos de la resistencia cuantizada ([code]stamina_q[/code] de PARTY_STATUS).
const STAMINA_Q_MAX: int = 255


## Resistencia [param stamina] de [param stamina_max] en 0 a [constant STAMINA_Q_MAX] (redondeada; 0 si el
## máximo no es positivo).
static func quantize_stamina(stamina: int, stamina_max: int) -> int:
	if stamina_max <= 0:
		return 0
	return clampi(roundi(float(stamina) * float(STAMINA_Q_MAX) / float(stamina_max)), 0, STAMINA_Q_MAX)


## Fracción (0 a 1) de una resistencia cuantizada.
static func stamina_fraction(stamina_q: int) -> float:
	return clampf(float(stamina_q) / float(STAMINA_Q_MAX), 0.0, 1.0)


## Fracción (0 a 1) de una vida cuantizada del registro ([method EntityRecord.quantize_health]).
static func health_fraction(health_q: int) -> float:
	return clampf(float(health_q) / 255.0, 0.0, 1.0)
