class_name DevAuthProvider
extends AuthProvider
## Proveedor de la fase 2: acepta el reino y el nombre que declara el cliente, sin cuentas ni
## billetes (docs/red.md, sección 12). Desde la fase 5 el reino saldrá del personaje guardado o
## del billete, y este proveedor solo servirá para desarrollo.


func authenticate(_hello: NetMessages.Hello) -> int:
	return NetProtocol.Result.OK
