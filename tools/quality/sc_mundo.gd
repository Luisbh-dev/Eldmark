extends RefCounted
## Quality capture bench (TEC-50), mundo area (scenario of online_driver.gd).
##
## Walkthrough of Vado Gris at player height with the real game camera (no HUD).
## The positions are written for Vardheim (north); with Solmarch they are mirrored (z -> -z, yaw -> 180 - yaw),
## so each realm sees its camp and its wall and both see the same valley from their side.

# [name, x, z, yaw_degrees, pitch_degrees, description]
const VIEWS: Array = [
	["campamento_spawn", 0.0, -138.0, 180.0, 0.0, "campamento del reino, en el punto de aparición, mirando hacia el fuerte"],
	["campamento_tiendas", -12.0, -134.0, 90.0, 5.0, "campamento: tiendas, cajas y hoguera"],
	["campamento_hacia_muralla", 3.0, -141.0, 0.0, 12.0, "campamento mirando a su muralla y la puerta (11 m)"],
	["puerta_de_muralla", 0.0, -148.0, 0.0, 20.0, "la puerta de la muralla y sus dos torres desde el pie"],
	["muralla_lateral", 50.0, -146.0, 90.0, 8.0, "la muralla vista a lo largo desde su base"],
	["camino_hacia_el_puente", 0.0, -105.0, 180.0, -2.0, "calzada del campamento hacia el puente"],
	["pinar_norte", -60.0, -120.0, 20.0, 5.0, "bosquete de pinos del norte"],
	["calzada_arboles", -20.0, -100.0, 160.0, 0.0, "calzada, árboles y rocas camino del río"],
	["puente_entrada", 0.0, -76.0, 180.0, 0.0, "entrada al puente de piedra"],
	["puente_centro", 0.0, -62.0, 180.0, 6.0, "sobre el puente, mirando al fuerte"],
	["puente_desde_la_orilla", 22.0, -86.0, 150.0, 0.0, "el puente y el río desde la orilla"],
	["rio_aguas_arriba", 60.0, -88.0, 100.0, 2.0, "río visto desde la orilla norte"],
	["ladera_del_fuerte", 0.0, -44.0, 180.0, 6.0, "ladera de la colina del fuerte al salir del puente"],
	["fuerte_esquina_exterior", -32.0, -32.0, -1.0, 8.0, "empalizada del fuerte por fuera, desde una esquina"],
	["fuerte_puerta_lejos", -38.0, 0.0, -90.0, 6.0, "puerta del fuerte por fuera, a unos 18 m"],
	["fuerte_puerta_cerca", -27.0, 0.0, -90.0, 12.0, "puerta del fuerte por fuera, a unos 7 m"],
	["fuerte_patio", -12.0, -9.0, -1.0, 6.0, "interior del fuerte: patio, mirando a la torre"],
	["fuerte_torre", 9.0, 10.0, -1.0, 22.0, "la torre central desde el patio"],
	["fuerte_circulo_de_captura", -8.5, 7.0, -90.0, 6.0, "círculo de captura (entre la puerta y la torre)"],
	["fuerte_patio_hacia_la_puerta", 13.0, -9.0, -1.0, 4.0, "patio mirando hacia la puerta desde el este"],
	["fuerte_pasarela", -19.0, -8.0, 90.0, 4.0, "pasarela sobre la puerta (si existe colisión ahí)"],
	["fuerte_rampa_norte", 8.0, -12.0, 90.0, 8.0, "rampa hacia la pasarela"],
	["vado_orilla_este", -44.0, -4.0, 90.0, 2.0, "orilla este del vado"],
	["vado_centro", -62.0, 0.0, 90.0, 3.0, "en mitad del vado, mirando a la orilla oeste"],
	["vado_desde_el_oeste", -80.0, 0.0, -90.0, 3.0, "vado y fuerte desde la orilla oeste"],
	["ruinas_calle", -100.0, 0.0, 90.0, 0.0, "la vieja calzada entre las casas en ruinas"],
	["ruinas_casa", -105.0, -12.0, 20.0, 4.0, "casas en ruinas de la aldea de Eld"],
	["ruinas_final_de_calzada", -130.0, 0.0, 90.0, 4.0, "final de la vieja calle: pilares de la puerta caída"],
	["borde_oeste_montanas", -138.0, -30.0, 90.0, 14.0, "montañas del borde oeste"],
	["borde_este_rio_sale", 128.0, -62.0, -90.0, 8.0, "el río sale por el este entre dos lomas"],
	["capilla", 28.0, -2.0, -90.0, 6.0, "capilla en ruinas de la península"],
	["franja_central_arboles_muertos", 40.0, -22.0, 90.0, 2.0, "árboles muertos y rocas en la franja central"],
	["campamento_vista_a_montanas", 0.0, -128.0, 0.0, 28.0, "montañas del borde norte sobre la muralla, mirando hacia arriba"],
]

var _d: Variant


func run(d: Variant) -> void:
	_d = d
	if not await d.enter_world():
		return
	var realm: int = d.client.get_config().realm
	var mirror: bool = realm == NetProtocol.Realm.SOLMARCH
	var realm_name: String = "solmarch" if mirror else "vardheim"
	d.note("recorrido del mundo como %s" % realm_name)
	d.set_hud_visible(false)
	d.heal()
	var n: int = 0
	for v: Array in VIEWS:
		var x: float = float(v[1])
		var z: float = float(v[2])
		var yaw: float = float(v[3])
		var pitch: float = float(v[4])
		# The orientation -1 means "look at the center of the fort (0, 0)".
		if yaw == -1.0:
			yaw = d.yaw_to(x, z, 0.0, 0.0)
		if mirror:
			z = -z
			yaw = 180.0 - yaw
		d.heal()
		await d.tp(x, z, yaw, pitch, NAN, 1.6)
		n += 1
		var rel: String = "mundo/jugador_%s/%02d_%s.png" % [realm_name, n, v[0]]
		var p: Vector3 = d.pos()
		await d.shot(rel, "%s (%s). Jugador en (%.0f, %.1f, %.0f), mirando %.0f grados" % [v[5], realm_name, p.x, p.y, p.z, yaw],
				"online_driver + sc_mundo: teletransporte de depuración y cámara real, sin HUD")
	d.set_hud_visible(true)
