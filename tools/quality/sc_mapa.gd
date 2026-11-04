extends RefCounted
## Banco de capturas de calidad (TEC-50), área mapa (escenario de online_driver.gd).
##
## Mapa M, minimapa y brújula del cliente en red, en varios sitios del Vado Gris.

var d: Variant

# [nombre, x, z, yaw, descripción]
const SPOTS: Array = [
	["campamento", 0.0, -138.0, 180.0, "campamento de Vardheim"],
	["puente_norte", 0.0, -62.0, 180.0, "sobre el puente norte"],
	["vado", -62.0, 0.0, 90.0, "en mitad del vado"],
	["ruinas_de_eld", -105.0, -6.0, 90.0, "aldea en ruinas de Eld"],
	["fuerte_patio", -12.0, -9.0, 90.0, "patio del fuerte"],
	["borde_este", 128.0, -62.0, -90.0, "borde este, donde el río sale"],
]


func run(drv: Variant) -> void:
	d = drv
	if not await d.enter_world():
		return
	await d.wait(1.5)
	var war: Variant = d.hud.get_war_hud()
	var minimap: Control = war.get_minimap()
	var compass: Control = war.get_compass()
	d.note("minimapa en %s, brújula en %s" % [minimap.get_global_rect(), compass.get_global_rect()])
	var n: int = 0
	for s: Array in SPOTS:
		n += 1
		await d.ensure_alive()
		await d.tp(float(s[1]), float(s[2]), float(s[3]), 3.0, NAN, 1.2)
		d.heal()
		await d.shot("mapa/minimapa_%02d_%s_pantalla.png" % [n, s[0]], "pantalla completa con minimapa y brújula, %s" % s[4], "tp de depuración")
		var r: Rect2 = minimap.get_global_rect().grow(8.0)
		await d.crop("mapa/minimapa_%02d_%s_recorte.png" % [n, s[0]], Rect2i(r), "recorte del minimapa x3, %s" % s[4], "recorte del rectángulo del minimapa", 3.0)
		var cr: Rect2 = compass.get_global_rect().grow(6.0)
		await d.crop("mapa/brujula_%02d_%s_recorte.png" % [n, s[0]], Rect2i(cr), "recorte de la brújula x2, %s" % s[4], "recorte del rectángulo de la brújula", 2.0)
	# Niveles de zoom del minimapa.
	await d.ensure_alive()
	await d.tp(-20.0, 30.0, 90.0, 3.0, NAN, 1.2)
	for level: int in 3:
		minimap.set_zoom_level(level)
		await d.wait(0.6)
		d.heal()
		var r2: Rect2 = minimap.get_global_rect().grow(8.0)
		await d.crop("mapa/minimapa_zoom_%d_recorte.png" % level, Rect2i(r2), "minimapa con zoom %d (%.0f m visibles)" % [level, minimap.get_visible_meters()], "set_zoom_level(%d)" % level, 3.0)
		await d.shot("mapa/minimapa_zoom_%d_pantalla.png" % level, "pantalla completa, minimapa zoom %d" % level, "set_zoom_level")
	minimap.set_zoom_level(1)
	# Brújula con distintos rumbos.
	await d.tp(0.0, -134.0, 0.0, 3.0, NAN, 1.0)
	for yaw: int in [0, 90, 180, -90, 45]:
		d.look(float(yaw), 3.0)
		await d.wait(0.6)
		var cr2: Rect2 = compass.get_global_rect().grow(6.0)
		await d.crop("mapa/brujula_rumbo_%d_recorte.png" % yaw, Rect2i(cr2), "brújula con rumbo %d grados" % yaw, "d.look(%d)" % yaw, 2.0)
	# Mapa M en varios puntos.
	var map: Variant = d.hud.get_world_map()
	var spots: Array = [["campamento", 0.0, -138.0], ["vado", -62.0, 0.0], ["fuerte", -12.0, -9.0], ["borde_este", 128.0, -62.0]]
	var k: int = 0
	for s: Array in spots:
		k += 1
		await d.ensure_alive()
		await d.tp(float(s[1]), float(s[2]), 180.0, 3.0, NAN, 1.0)
		d.heal()
		await d.key(KEY_M)
		await d.wait(0.9)
		await d.shot("mapa/mapa_m_%02d_%s.png" % [k, s[0]], "mapa M abierto con el jugador en (%.0f, %.0f)" % [s[1], s[2]], "tecla M")
		if map.is_open():
			await d.key(KEY_M)
		await d.wait(0.4)
	# El mapa con el fuerte en manos de cada reino.
	d.cmd(NetProtocol.DEBUG_FORT_OWNER, PackedByteArray([NetProtocol.Realm.SOLMARCH]))
	await d.wait(1.5)
	await d.key(KEY_M)
	await d.wait(0.9)
	await d.shot("mapa/mapa_m_05_fuerte_de_solmarch.png", "mapa M con el fuerte en manos de Solmarch (comando de depuración 9)", "DEBUG_FORT_OWNER=2")
	await d.key(KEY_M)
	d.cmd(NetProtocol.DEBUG_FORT_OWNER, PackedByteArray([NetProtocol.Realm.VARDHEIM]))
	await d.wait(1.0)
	await d.key(KEY_M)
	await d.wait(0.9)
	await d.shot("mapa/mapa_m_06_fuerte_de_vardheim.png", "mapa M con el fuerte de Vardheim", "DEBUG_FORT_OWNER=1")
	await d.key(KEY_M)
	# Teclas de zoom con el mapa abierto.
	await d.key(KEY_M)
	await d.wait(0.6)
	await d.key(KEY_EQUAL)
	await d.wait(0.5)
	await d.shot("mapa/mapa_m_07_tecla_mas.png", "mapa M tras pulsar + (zoom del minimapa)", "teclas M y =")
	await d.key(KEY_M)
