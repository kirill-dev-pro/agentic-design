#+build !js
package agentic_design


import "core:fmt"
import "core:os"
import "core:time"

// A short record of the window's life in Application Support/app.log: when it started,
// when and why it ended (closed by the user, a signal, a crash), so an exit nobody saw
// can be explained afterwards. Test windows do not write it.
// The exit signals and the crash handler are the system's (sys_unix.odin, sys_windows.odin).

app_log :: proc(format: string, args: ..any) {
	if pf.quiet do return
	_ = os.make_directory_all(support_dir())
	f, err := os.open(fmt.tprintf("%s/app.log", support_dir()), {.Write, .Append, .Create})
	if err != nil do return
	defer os.close(f)
	now := time.now()
	y, mon, d := time.date(now)
	h, mi, s := time.clock(now)
	line := fmt.tprintf("%04d-%02d-%02d %02d:%02d:%02dZ pid %d  %s\n", y, int(mon), d, h, mi, s, os.get_pid(), fmt.tprintf(format, ..args))
	_, _ = os.write(f, transmute([]u8)line)
}
