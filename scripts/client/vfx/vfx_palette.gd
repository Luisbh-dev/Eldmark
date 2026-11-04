class_name VfxPalette
extends RefCounted
## Effect colors (ART-09, client only). Those of the trail and the aura come from the realm and the art
## direction (docs/arte.md): Vardheim, steel and ice blue; Solmarch, white and gold; Askarra, crimson and
## bronze; Eldrun (the Hollow), desaturated with embers. The realm number is that of
## [enum NetProtocol.Realm] (1 to 3); 4 is Eldrun and 0 a neutral steel. The dust, in contrast, belongs not
## to the realm but to the ground being stepped on ([method ground], [VfxGround]).

## Realm of the Hollow (it has no value in [enum NetProtocol.Realm]: it is not a playable side).
const REALM_ELDRUN: int = 4
## Neutral realm: steel.
const REALM_NEUTRAL: int = 0


## Weapon trail colors: [hot core of the edge, body of the ribbon].
static func trail(realm: int) -> Array[Color]:
	match realm:
		NetProtocol.Realm.VARDHEIM:
			return [Color(0.9, 0.98, 1.0), Color(0.5, 0.78, 1.0)]
		NetProtocol.Realm.SOLMARCH:
			return [Color(1.0, 0.98, 0.84), Color(0.95, 0.6, 0.08)]
		NetProtocol.Realm.ASKARRA:
			return [Color(1.0, 0.7, 0.32), Color(0.78, 0.04, 0.08)]
		REALM_ELDRUN:
			return [Color(1.0, 0.52, 0.16), Color(0.3, 0.24, 0.24)]
	return [Color(1.0, 1.0, 1.0), Color(0.42, 0.52, 0.7)]


## Color of the heavy attack's charge aura.
static func aura(realm: int) -> Color:
	match realm:
		NetProtocol.Realm.VARDHEIM:
			return Color(0.42, 0.72, 1.0)
		NetProtocol.Realm.SOLMARCH:
			return Color(1.0, 0.82, 0.38)
		NetProtocol.Realm.ASKARRA:
			return Color(1.0, 0.3, 0.2)
		REALM_ELDRUN:
			return Color(1.0, 0.5, 0.18)
	return Color(0.8, 0.88, 1.0)


## Ground materials that the dust distinguishes.
const GROUND_KINDS: Array[StringName] = [&"dirt", &"stone", &"sand", &"grass", &"snow", &"ash", &"mud"]


## Color of the dust a ground of that material kicks up ([constant GROUND_KINDS]); an unknown material
## gives that of dry earth.
static func ground(kind: StringName) -> Color:
	match kind:
		&"stone":
			return Color(0.66, 0.67, 0.69)
		&"sand":
			return Color(0.84, 0.72, 0.5)
		&"grass":
			return Color(0.52, 0.55, 0.4)
		&"snow":
			return Color(0.93, 0.95, 0.98)
		&"ash":
			return Color(0.42, 0.4, 0.4)
		&"mud":
			return Color(0.4, 0.33, 0.26)
	return Color(0.6, 0.54, 0.45)
