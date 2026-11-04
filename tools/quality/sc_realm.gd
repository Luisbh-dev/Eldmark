extends RefCounted
## Quality capture bench (TEC-50), interfaz area (scenario of online_driver.gd).
##
## Realm selection (client without --realm): screen with player counters, equipment template and validation.

var d: Variant


func run(drv: Variant) -> void:
	d = drv
	await d.wait(3.0)
	var rs: Variant = d.main.get_realm_select()
	if rs == null:
		d.note("no apareció RealmSelect")
		return
	await d.shot("interfaz/eleccion_de_reino_01.png", "elección de reino al arrancar sin --realm (con contadores de jugadores del servidor)", "online_driver sin --realm")
	rs.select_realm(NetProtocol.Realm.SOLMARCH)
	await d.wait(0.5)
	await d.shot("interfaz/eleccion_de_reino_02_solmarch.png", "elección de reino con Solmarch seleccionado", "select_realm(SOLMARCH)")
	rs.select_realm(NetProtocol.Realm.ASKARRA)
	await d.wait(0.5)
	await d.shot("interfaz/eleccion_de_reino_03_askarra.png", "intento de elegir Askarra (cerrado)", "select_realm(ASKARRA)")
	rs.select_realm(NetProtocol.Realm.VARDHEIM)
	rs.get_name_edit().text = "x"
	rs.get_name_edit().text_changed.emit("x")
	await d.wait(0.5)
	await d.shot("interfaz/eleccion_de_reino_04_nombre_invalido.png", "elección de reino con un nombre no válido («x»)", "texto en la caja de nombre")
	rs.get_name_edit().text = "Capturador"
	rs.get_name_edit().text_changed.emit("Capturador")
	rs.get_address_edit().text = "no es una direccion"
	rs.get_address_edit().text_changed.emit("no es una direccion")
	await d.wait(0.5)
	await d.shot("interfaz/eleccion_de_reino_05_direccion_invalida.png", "elección de reino con una dirección de servidor mal escrita", "texto en la caja de dirección")
