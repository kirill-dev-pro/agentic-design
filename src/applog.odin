#+build !js
package agentic_design


import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:time"

// A short record of the window's life in Application Support/app.log: when it started,
// when and why it ended (closed by the user, a signal, a crash), so an exit nobody saw
// can be explained afterwards. Test windows do not write it.
//
// SIGTERM, SIGINT and SIGHUP end the main loop the normal way, so the document is saved
// first; a crash signal is written down before the default handler runs.

exit_signal: posix.Signal // set by a quit signal; 0 until then

app_log :: proc(format: string, args: ..any) {
	if pf.quiet do return
	_ = os.make_directory_all(support_dir())
	f, err := os.open(fmt.tprintf("%s/app.log", support_dir()), {.Write, .Append, .Create})
	if err != nil do return
	defer os.close(f)
	now := time.now()
	y, mon, d := time.date(now)
	h, mi, s := time.clock(now)
	line := fmt.tprintf("%04d-%02d-%02d %02d:%02d:%02dZ pid %d  %s\n", y, int(mon), d, h, mi, s, posix.getpid(), fmt.tprintf(format, ..args))
	_, _ = os.write(f, transmute([]u8)line)
}

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
