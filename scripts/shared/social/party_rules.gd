class_name PartyRules
extends RefCounted
## Party rules (SOC-06, docs/social.md, sections 3 and 12.4), shared by the server (which applies
## them) and the client (which uses them to draw the frames and not request what the server would
## reject).
## [br][br]
## A party has at most [constant NetProtocol.PARTY_MAX_SIZE] players, all of the same realm; the
## first is the leader and, if they leave, the next oldest inherits command. An invitation expires
## after [constant INVITE_TTL_TICKS] ticks (60 s) and each player can have at most
## [constant MAX_PENDING_PER_INVITER] sent at a time. Shared: depends on neither the client nor
## the server.

## Ticks an invitation is valid for (60 s at 60 ticks per second).
const INVITE_TTL_TICKS: int = 3600
## Maximum pending invitations per inviter.
const MAX_PENDING_PER_INVITER: int = 5
## Ticks between two sends of the members' compact status (2 Hz).
const STATUS_INTERVAL_TICKS: int = 30
## Distance (m) beyond which a member's frame is shown dimmed (provisional: that of the experience
## sharing in docs/social.md, section 3).
const FAR_DISTANCE: float = 100.0
## Steps of the quantized stamina ([code]stamina_q[/code] of PARTY_STATUS).
const STAMINA_Q_MAX: int = 255


## Stamina [param stamina] out of [param stamina_max] in 0 to [constant STAMINA_Q_MAX] (rounded; 0
## if the maximum is not positive).
static func quantize_stamina(stamina: int, stamina_max: int) -> int:
	if stamina_max <= 0:
		return 0
	return clampi(roundi(float(stamina) * float(STAMINA_Q_MAX) / float(stamina_max)), 0, STAMINA_Q_MAX)


## Fraction (0 to 1) of a quantized stamina.
static func stamina_fraction(stamina_q: int) -> float:
	return clampf(float(stamina_q) / float(STAMINA_Q_MAX), 0.0, 1.0)


## Fraction (0 to 1) of a quantized health from the record ([method EntityRecord.quantize_health]).
static func health_fraction(health_q: int) -> float:
	return clampf(float(health_q) / 255.0, 0.0, 1.0)
