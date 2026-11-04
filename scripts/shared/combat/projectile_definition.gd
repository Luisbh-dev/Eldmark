class_name ProjectileDefinition
extends Resource
## The ballistics of a projectile (docs/habilidades.md, section 2.1). It goes in full into the
## prediction fingerprint: the client draws its predicted arrow and other players' arrows with the same
## [method Ballistics.position] that the server flies. The launch speed is set by whoever fires
## (the attack or the ability).

## Unique identifier (the catalog assigns it a u16 ID in alphabetical order).
@export var id: StringName
## Gravity (m/s², downward).
@export var gravity: float = 6.0
## Radius (m) added to that of the target's capsule.
@export var radius_m: float = 0.05
## Lifetime (s) before expiring.
@export var lifetime_s: float = 2.0
