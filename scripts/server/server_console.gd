class_name ServerConsole
extends RefCounted
## The server's standard input console (docs/combat.md, section 6; TEC-19): reads lines from [code]stdin[/code] in a
## separate thread, so that waiting for the keyboard never blocks the tick, and leaves them in a protected queue. The
## server collects them once per tick with [method take_lines] and runs them on the main thread
## ([method CommandRegistry.execute_console]).
## [br][br]
## The thread ends by itself when the input closes (EOF); while it waits for a line it cannot be interrupted.
## [b]Known limitation[/b]: on Linux, libc's [code]exit()[/code] keeps waiting for the [code]stdin[/code] lock held by
## the read, so with the input open the process does not end after the server closes until one more line arrives or the
## input is closed (Ctrl+D); on Windows this does not happen. With the input already closed ([code]/dev/null[/code],
## systemd, a container without [code]-i[/code]) the thread ends immediately and there is no wait. It is only started with
## [code]--console[/code]: a standard input shared with a terminal must not be read by a process nobody has asked to read
## it.
## [br][br]
## [b]Lines and reads[/b]: [method OS.read_string_from_stdin] gives one line per call on Linux, but on Windows it returns
## whatever has arrived at the input (several lines together if the writer, or a pipe, sends them at once), with line
## endings already normalized and the last one removed. That is why the thread does not treat each read as a command:
## [method push_text] splits it into lines. An empty read (a blank line or the end of input) ends the thread, on both
## systems.
## [br][br]
## Tests do not need stdin: [method push_line] puts in a line as if someone had typed it and [method push_text] a text
## with several, as a read would give it.

## Maximum pending lines (the rest are discarded: nobody types that fast).
const MAX_PENDING_LINES: int = 64

var _thread: Thread = null
var _mutex: Mutex = Mutex.new()
var _lines: PackedStringArray = PackedStringArray()
var _running: bool = false
var _reached_eof: bool = false


## Starts the reader thread. Returns false if it was already running or there is no usable standard input
## ([constant OS.STD_HANDLE_INVALID]).
func start() -> bool:
	if _thread != null:
		return false
	if OS.get_stdin_type() == OS.STD_HANDLE_INVALID:
		return false
	_running = true
	_thread = Thread.new()
	return _thread.start(_read_loop) == OK


## true while the reader thread is still waiting for lines.
func is_running() -> bool:
	return _thread != null and _running and not has_reached_eof()


## true if the reader thread is alive, even if it was asked to stop with [method stop]: it is still inside the blocked
## read until a line arrives or the input closes.
func is_reading() -> bool:
	return _thread != null and not has_reached_eof()


## true if standard input was closed (the thread has already ended).
func has_reached_eof() -> bool:
	_mutex.lock()
	var reached: bool = _reached_eof
	_mutex.unlock()
	return reached


## Asks the reader not to deliver more lines. It cannot interrupt a read in progress.
func stop() -> void:
	_running = false


## Puts a line in the queue as if it had been typed in the console (discards empty ones and those exceeding
## [constant MAX_PENDING_LINES]).
func push_line(line: String) -> void:
	var text: String = line.strip_edges()
	if text.is_empty():
		return
	_mutex.lock()
	if _lines.size() < MAX_PENDING_LINES:
		_lines.append(text)
	_mutex.unlock()


## Puts in the queue each line of [param text] (separated by LF or CRLF) with [method push_line].
func push_text(text: String) -> void:
	for line: String in text.replace("\r\n", "\n").split("\n"):
		push_line(line)


## The pending lines, from oldest to most recent, and empties the queue.
func take_lines() -> PackedStringArray:
	_mutex.lock()
	var taken: PackedStringArray = _lines
	_lines = PackedStringArray()
	_mutex.unlock()
	return taken


# Reader thread: one read per loop (it may bring several lines) until the input closes.
func _read_loop() -> void:
	while _running:
		var text: String = OS.read_string_from_stdin()
		if text.is_empty():
			break
		push_text(text)
	_mutex.lock()
	_reached_eof = true
	_mutex.unlock()
