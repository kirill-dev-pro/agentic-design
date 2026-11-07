#+build windows
package agentic_design

import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import win "core:sys/windows"

// The few system calls the shared code needs, on Windows (sys_unix.odin has the same
// procedures for macOS and Linux).

// ---------------------------------------------------------------- exit (applog.odin)

Exit_Signal :: enum i32 {
	None,
	Ctrl_C,
	Ctrl_Break,
	Close, // the console window closed, the user logged off, the system shuts down
}

exit_signal: Exit_Signal

// Ctrl-C, Ctrl-Break and closing the console end the main loop the normal way, so the
// document is saved first; a crash is written down before Windows ends the process.
install_exit_handlers :: proc() {
	win.SetConsoleCtrlHandler(proc "system" (ctrl: win.DWORD) -> win.BOOL {
		switch ctrl {
		case win.CTRL_C_EVENT: exit_signal = .Ctrl_C
		case win.CTRL_BREAK_EVENT: exit_signal = .Ctrl_Break
		case: exit_signal = .Close
		}
		return true
	}, true)
	win.SetUnhandledExceptionFilter(proc "system" (info: ^win.EXCEPTION_POINTERS) -> win.LONG {
		context = app_context()
		code: win.DWORD
		if info != nil && info.ExceptionRecord != nil do code = info.ExceptionRecord.ExceptionCode
		app_log("crash: exception 0x%08x (%s)", code, app.file_path)
		return win.EXCEPTION_CONTINUE_SEARCH
	})
}

// Windows has no SIGPIPE: a write to a closed socket is an error.
posix_ignore_sigpipe :: proc() {}

// ---------------------------------------------------------------- processes

// Not inherited by processes this one starts (server.odin).
close_on_exec :: proc(sock: net.TCP_Socket) {
	win.SetHandleInformation(win.HANDLE(uintptr(sock)), win.HANDLE_FLAG_INHERIT, 0)
}

// A numeric agent id is the MCP proxy's process id: true once that process has ended.
agent_process_gone :: proc(id: string) -> bool {
	pid, ok := strconv.parse_int(id)
	if !ok || pid <= 0 do return false
	h := win.OpenProcess(win.SYNCHRONIZE | win.PROCESS_QUERY_LIMITED_INFORMATION, false, win.DWORD(pid))
	if h == nil do return win.GetLastError() == win.ERROR_INVALID_PARAMETER // no such process
	defer win.CloseHandle(h)
	return win.WaitForSingleObject(h, 0) == win.WAIT_OBJECT_0
}

// Stops a child process. A console process could be sent Ctrl-C only from its console;
// the agents' CLIs are ended instead (they keep no state worth a clean exit).
process_interrupt :: proc(pid: int) {
	p, err := os.process_open(pid)
	if err != nil do return
	_ = os.process_kill(p)
}

// ---------------------------------------------------------------- memory (memory.odin)

pages_alloc :: proc(size: int) -> rawptr {
	return win.VirtualAlloc(nil, win.SIZE_T(size), win.MEM_COMMIT | win.MEM_RESERVE, win.PAGE_READWRITE)
}

pages_free :: proc(p: rawptr, size: int) {
	win.VirtualFree(p, 0, win.MEM_RELEASE)
}

// The Windows heap gives large blocks back on its own.
heap_trim :: proc() -> uint {
	return 0
}

// ---------------------------------------------------------------- files

// The absolute path, lower-cased (Windows paths ignore case) with / separators, in temporary
// memory; "" when it does not exist.
resolved_path :: proc(path: string) -> string {
	if !os.exists(path) do return ""
	abs, err := os.get_absolute_path(path, context.temp_allocator)
	if err != nil do return ""
	s, _ := strings.replace_all(strings.to_lower(abs, context.temp_allocator), "\\", "/", context.temp_allocator)
	return s
}

// Test sandboxes (HOME pointed elsewhere) are a macOS and Linux affair.
home_sandboxed :: proc() -> bool {
	return false
}
