class_name ServerConsole
extends RefCounted
## Consola de la entrada estándar del servidor (docs/combate.md, sección 6; TEC-19): lee líneas de
## [code]stdin[/code] en un hilo aparte, para que esperar al teclado no bloquee nunca el tick, y las
## deja en una cola protegida. El servidor las recoge una vez por tick con [method take_lines] y las
## ejecuta en el hilo principal ([method CommandRegistry.execute_console]).
## [br][br]
## El hilo termina solo cuando la entrada se cierra (EOF); mientras espera una línea no se puede
## interrumpir, así que al cerrar el proceso queda donde está (Godot lo avisa con un aviso, no con un
## error). Solo se arranca con [code]--console[/code]: una entrada estándar compartida con una
## terminal no debe leerla un proceso que nadie ha pedido que la lea.
## [br][br]
## Las pruebas no necesitan stdin: [method push_line] mete una línea como si la hubiera escrito alguien.

## Líneas pendientes como mucho (el resto se descarta: nadie escribe tan deprisa).
const MAX_PENDING_LINES: int = 64

var _thread: Thread = null
var _mutex: Mutex = Mutex.new()
var _lines: PackedStringArray = PackedStringArray()
var _running: bool = false
var _reached_eof: bool = false


## Arranca el hilo lector. Devuelve false si ya estaba en marcha o no hay entrada estándar
## utilizable ([constant OS.STD_HANDLE_INVALID]).
func start() -> bool:
	if _thread != null:
		return false
	if OS.get_stdin_type() == OS.STD_HANDLE_INVALID:
		return false
	_running = true
	_thread = Thread.new()
	return _thread.start(_read_loop) == OK


## true mientras el hilo lector sigue esperando líneas.
func is_running() -> bool:
	return _thread != null and _running and not _reached_eof


## true si la entrada estándar se cerró (el hilo ya terminó).
func has_reached_eof() -> bool:
	_mutex.lock()
	var reached: bool = _reached_eof
	_mutex.unlock()
	return reached


## Pide al lector que no entregue más líneas. No puede interrumpir una lectura en curso.
func stop() -> void:
	_running = false


## Mete una línea en la cola como si se hubiera escrito en la consola (descarta las vacías y las
## que sobran de [constant MAX_PENDING_LINES]).
func push_line(line: String) -> void:
	var text: String = line.strip_edges()
	if text.is_empty():
		return
	_mutex.lock()
	if _lines.size() < MAX_PENDING_LINES:
		_lines.append(text)
	_mutex.unlock()


## Las líneas pendientes, de más antigua a más reciente, y vacía la cola.
func take_lines() -> PackedStringArray:
	_mutex.lock()
	var taken: PackedStringArray = _lines
	_lines = PackedStringArray()
	_mutex.unlock()
	return taken


# Hilo lector: una línea por llamada hasta que la entrada se cierre.
func _read_loop() -> void:
	while _running:
		var line: String = OS.read_string_from_stdin()
		if line.is_empty():
			break
		push_line(line)
	_mutex.lock()
	_reached_eof = true
	_mutex.unlock()
