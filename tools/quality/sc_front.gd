extends RefCounted
## Banco de capturas de calidad (TEC-50), área interfaz (escenario de online_driver.gd).
##
## Título con cuenta (FrontMain): sin la plataforma de cuentas en marcha (no hace falta: el banco no usa cuentas ni contraseñas), así que se ve el
## título con su aviso de error y, forzando la pantalla con datos de mentira (no hay contraseñas ni cuentas reales),
## el registro, la selección de personaje y los cuatro pasos de la creación.

var d: Variant


func run(drv: Variant) -> void:
	d = drv
	await d.wait(3.0)
	var main: Node = d.main
	await d.shot("interfaz/titulo_01_inicio.png", "pantalla de título con cuenta: inicio (la plataforma de cuentas no está en marcha)", "online_driver --front --title")
	var title: Variant = main.get_title_screen()
	if title != null:
		# Intento de entrar sin escribir nada (el botón debe estar desactivado) y panel de «¿has olvidado la contraseña?».
		title.open_forgot()
		await d.wait(0.6)
		await d.shot("interfaz/titulo_02_olvide_contrasena.png", "título: panel de recuperar contraseña abierto (sin escribir nada)", "TitleScreen.open_forgot()")
		title.close_forgot()
		await d.wait(0.3)
		title.get_register_button().pressed.emit()
		await d.wait(0.8)
		await d.shot("interfaz/titulo_03_registro.png", "pantalla de registro de cuenta (campos vacíos)", "botón «Crear cuenta»")
	# Selección de personaje con datos inventados.
	var select: Variant = main.get_character_select()
	if select != null:
		main._show(select)
		select.set_data({"realm": "vardheim", "slots": 3, "used": 2, "characters": [
			{"character_id": "11", "name": "Bran", "realm": "vardheim", "level": 7, "race": "human", "body": 1, "deleted_at": null},
			{"character_id": "12", "name": "Ysolda", "realm": "vardheim", "level": 3, "race": "human", "body": 2, "deleted_at": null},
		]})
		await d.wait(1.0)
		await d.shot("interfaz/seleccion_personaje_01.png", "selección de personaje con dos personajes de mentira", "CharacterSelect.set_data(...) forzado desde el script")
		select.select_index(1)
		await d.wait(0.6)
		await d.shot("interfaz/seleccion_personaje_02.png", "selección de personaje, segundo personaje elegido", "select_index(1)")
		select.ask_delete()
		await d.wait(0.5)
		await d.shot("interfaz/seleccion_personaje_03_borrar.png", "diálogo de borrar personaje", "CharacterSelect.ask_delete()")
		select.close_delete()
		select.set_data({"realm": "vardheim", "slots": 3, "used": 0, "characters": []})
		await d.wait(0.5)
		await d.shot("interfaz/seleccion_personaje_04_vacia.png", "selección de personaje sin personajes", "set_data vacío")
	# Creación de personaje, paso a paso.
	var create: Variant = main.get_character_create()
	if create != null:
		create.setup(&"")
		main._show(create)
		await d.wait(0.8)
		await d.shot("interfaz/creacion_01_reino.png", "creación de personaje, paso 1: reino", "CharacterCreate.setup")
		create.select_realm(&"vardheim")
		await d.wait(0.4)
		await d.shot("interfaz/creacion_01b_reino_elegido.png", "creación, paso 1 con Vardheim elegido", "select_realm(vardheim)")
		create.next()
		await d.wait(0.8)
		await d.shot("interfaz/creacion_02_apariencia.png", "creación, paso 2: apariencia (valores por defecto)", "next()")
		for field: StringName in create.FIELDS:
			create.cycle(field, 1)
		await d.wait(0.8)
		await d.shot("interfaz/creacion_02b_apariencia_cambiada.png", "creación, paso 2 con todas las opciones avanzadas una posición", "cycle(campo, 1) en cada campo")
		for field: StringName in create.FIELDS:
			create.cycle(field, 2)
		await d.wait(0.8)
		await d.shot("interfaz/creacion_02c_apariencia_cambiada_2.png", "creación, paso 2 con las opciones avanzadas dos posiciones más", "cycle(campo, 2)")
		create.next()
		await d.wait(0.8)
		await d.shot("interfaz/creacion_03_plantilla.png", "creación, paso 3: plantilla de equipo", "next()")
		create.next()
		await d.wait(0.8)
		await d.shot("interfaz/creacion_04_nombre.png", "creación, paso 4: nombre", "next()")
