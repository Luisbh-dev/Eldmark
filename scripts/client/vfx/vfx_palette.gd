class_name VfxPalette
extends RefCounted
## Colores de los efectos (ART-09, solo cliente). Los de la estela y el aura salen del reino y de la
## dirección de arte (docs/arte.md): Vardheim, acero y azul hielo; Solmarch, blanco y oro; Askarra, carmesí
## y bronce; Eldrun (los Huecos), desaturado con brasas. El número de reino es el de
## [enum NetProtocol.Realm] (1 a 3); 4 es Eldrun y 0 un acero neutro. El polvo, en cambio, no es del reino
## sino del suelo que se pisa ([method ground], [VfxGround]).

## Reino de los Huecos (no tiene valor en [enum NetProtocol.Realm]: no es un bando jugable).
const REALM_ELDRUN: int = 4
## Reino neutro: acero.
const REALM_NEUTRAL: int = 0


## Colores de la estela del arma: [núcleo caliente del filo, cuerpo de la cinta].
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


## Color del aura de carga del golpe fuerte.
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


## Materiales de suelo que distingue el polvo.
const GROUND_KINDS: Array[StringName] = [&"dirt", &"stone", &"sand", &"grass", &"snow", &"ash", &"mud"]


## Color del polvo que levanta un suelo de ese material ([constant GROUND_KINDS]); un material desconocido
## da el de tierra seca.
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
