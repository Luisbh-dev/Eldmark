class_name VfxPalette
extends RefCounted
## Colores de los efectos por reino (ART-09, solo cliente). Salen de la dirección de arte
## (docs/arte.md): Vardheim, acero y azul hielo; Solmarch, blanco y oro; Askarra, carmesí y bronce;
## Eldrun (los Huecos), desaturado con brasas. El número de reino es el de [enum NetProtocol.Realm]
## (1 a 3); 4 es Eldrun y 0 un acero neutro.

## Reino de los Huecos (no tiene valor en [enum NetProtocol.Realm]: no es un bando jugable).
const REALM_ELDRUN: int = 4
## Reino neutro: acero.
const REALM_NEUTRAL: int = 0


## Colores de la estela del arma: [núcleo caliente del filo, cuerpo de la cinta].
static func trail(realm: int) -> Array[Color]:
	match realm:
		NetProtocol.Realm.VARDHEIM:
			return [Color(0.88, 0.97, 1.0), Color(0.12, 0.42, 0.95)]
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


## Color del polvo del suelo de cada reino (piedra gris fría, caliza, arenisca roja, ceniza).
static func dust(realm: int) -> Color:
	match realm:
		NetProtocol.Realm.VARDHEIM:
			return Color(0.74, 0.78, 0.82)
		NetProtocol.Realm.SOLMARCH:
			return Color(0.88, 0.83, 0.7)
		NetProtocol.Realm.ASKARRA:
			return Color(0.8, 0.5, 0.34)
		REALM_ELDRUN:
			return Color(0.5, 0.46, 0.45)
	return Color(0.78, 0.74, 0.66)
