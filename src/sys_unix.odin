#+build darwin, linux
package agentic_design

import "core:net"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

// The few system calls the shared code needs, on macOS and Linux (sys_windows.odin has the
// same procedures). Everything else goes through core:os, which is the same everywhere.

// ---------------------------------------------------------------- signals (applog.odin)

// SIGTERM, SIGINT and SIGHUP end the main loop the normal way, so the document is saved
// first; a crash signal is written down before the default handler runs.
Exit_Signal :: posix.Signal

exit_signal: Exit_Signal // set by a quit signal; 0 until then

install_exit_handlers :: proc() {
	quit :: proc "c" (sig: posix.Signal) {
		exit_signal = sig
	}
	crash :: proc "c" (sig: posix.Signal) {
		context = app_context()
		app_log("crash: %v (%s)", sig, app.file_path)
		posix.signal(sig, transmute(proc "c" (posix.Signal))posix.SIG_DFL)
		posix.raise(sig)
	}
	for sig in ([?]posix.Signal{.SIGTERM, .SIGINT, .SIGHUP}) do posix.signal(sig, quit)
	for sig in ([?]posix.Signal{.SIGSEGV, .SIGBUS, .SIGILL, .SIGFPE, .SIGABRT}) do posix.signal(sig, crash)
}

// A client that hangs up mid-reply must not end the process.
posix_ignore_sigpipe :: proc() {
	posix.signal(.SIGPIPE, transmute(proc "c" (posix.Signal))posix.SIG_IGN)
}

// ---------------------------------------------------------------- processes

// Not inherited by processes this one starts (server.odin).
close_on_exec :: proc(sock: net.TCP_Socket) {
	fd := posix.FD(sock)
	flags := posix.fcntl(fd, .GETFD)
	if flags >= 0 do posix.fcntl(fd, .SETFD, flags | posix.FD_CLOEXEC)
}

// A numeric agent id is the MCP proxy's process id: true once that process has ended.
// Other ids (tests, other front ends) never count as ended.
agent_process_gone :: proc(id: string) -> bool {
	pid, ok := strconv.parse_int(id)
	if !ok || pid <= 0 do return false
	if posix.kill(posix.pid_t(pid), posix.Signal(0)) == .OK do return false
	return posix.errno() == .ESRCH
}

// Asks a child process to stop (Ctrl-C), as a terminal would.
process_interrupt :: proc(pid: int) {
	posix.kill(posix.pid_t(pid), .SIGINT)
}

// ---------------------------------------------------------------- memory (memory.odin)

// Whole pages from the system, zeroed; nil when there are none.
pages_alloc :: proc(size: int) -> rawptr {
	p := posix.mmap(nil, uint(size), {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
	return nil if p == posix.MAP_FAILED else p
}

pages_free :: proc(p: rawptr, size: int) {
	posix.munmap(p, uint(size))
}

when ODIN_OS == .Darwin {
	foreign import libc "system:System.framework"
	@(default_calling_convention = "c")
	foreign libc {
		malloc_zone_pressure_relief :: proc(zone: rawptr, goal: uint) -> uint ---
	}
	// macOS's malloc keeps freed large blocks for reuse; this gives them back.
	heap_trim :: proc() -> uint {
		return malloc_zone_pressure_relief(nil, 0)
	}
} else {
	foreign import libc "system:c"
	@(default_calling_convention = "c")
	foreign libc {
		malloc_trim :: proc(pad: uint) -> i32 ---
	}
	// glibc's malloc_trim returns the free memory at the top of the heap and unused pages
	// inside it; it says whether it did, not how much.
	heap_trim :: proc() -> uint {
		return uint(malloc_trim(0))
	}
}

// ---------------------------------------------------------------- files

// The path with symlinks resolved (/tmp and /private/tmp), in temporary memory; "" when it
// does not exist.
resolved_path :: proc(path: string) -> string {
	r := posix.realpath(strings.clone_to_cstring(path, context.temp_allocator))
	if r == nil do return ""
	defer posix.free(r)
	return strings.clone(string(r), context.temp_allocator)
}

// HOME is set to a folder that is not the user's home directory (a test's sandbox).
home_sandboxed :: proc() -> bool {
	pw := posix.getpwuid(posix.getuid())
	home, _ := fs_home(context.temp_allocator)
	return pw != nil && home != "" && home != string(pw.pw_dir)
}
