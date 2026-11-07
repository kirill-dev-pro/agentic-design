#+build linux
package agentic_design

import "core:fmt"
import "core:os"
import "core:strings"

// The open and save panels behind dialogs.odin on Linux: zenity (GNOME and most desktops)
// or kdialog (KDE). Both block until the user answers, as the macOS panels do.

@(private = "file")
Picker :: enum {
	None,
	Zenity,
	Kdialog,
}

@(private = "file")
picker :: proc() -> Picker {
	for name, p in ([Picker]string{.None = "", .Zenity = "zenity", .Kdialog = "kdialog"}) {
		if name == "" do continue
		state, _, _, err := os.process_exec({command = {"/bin/sh", "-c", `command -v "$1" >/dev/null`, "sh", name}}, context.temp_allocator)
		if err == nil && state.exited && state.exit_code == 0 do return p
	}
	return .None
}

// The lines a picker printed, or nil when cancelled.
@(private = "file")
pick :: proc(command: []string) -> []string {
	state, out, _, err := os.process_exec({command = command}, context.temp_allocator)
	if err != nil || !state.exited || state.exit_code != 0 do return nil
	lines := make([dynamic]string, context.temp_allocator)
	for line in strings.split_lines(string(out), context.temp_allocator) {
		if line != "" do append(&lines, line)
	}
	return lines[:]
}

@(private = "file")
no_picker :: proc() {
	set_status("No file dialog: install zenity (or kdialog), or drop files on the window")
}

system_open_panel :: proc(p: Open_Panel) -> []string {
	start := p.start if p.start != "" else (os.get_working_directory(context.temp_allocator) or_else "")
	switch picker() {
	case .Zenity:
		cmd := make([dynamic]string, context.temp_allocator)
		append(&cmd, "zenity", "--file-selection", "--separator=\n")
		if p.multiple do append(&cmd, "--multiple")
		if p.folders do append(&cmd, "--directory")
		if p.message != "" do append(&cmd, fmt.tprintf("--title=%s", p.message))
		if start != "" do append(&cmd, fmt.tprintf("--filename=%s/", start))
		return pick(cmd[:])
	case .Kdialog:
		cmd := make([dynamic]string, context.temp_allocator)
		if p.folders do append(&cmd, "kdialog", "--getexistingdirectory", start)
		else do append(&cmd, "kdialog", "--getopenfilename", start)
		if p.multiple && !p.folders do append(&cmd, "--multiple", "--separate-output")
		if p.message != "" do append(&cmd, "--title", p.message)
		return pick(cmd[:])
	case .None:
		no_picker()
	}
	return nil
}

system_save_panel :: proc(name: string, types: []string, start: string) -> (path: string, ok: bool) {
	file := name
	if len(types) > 0 && !has_extension(name, types) do file = fmt.tprintf("%s.%s", name, types[0])
	full := fmt.tprintf("%s/%s", start, file) if start != "" else file
	lines: []string
	switch picker() {
	case .Zenity:
		cmd := make([dynamic]string, context.temp_allocator)
		append(&cmd, "zenity", "--file-selection", "--save", "--confirm-overwrite", fmt.tprintf("--filename=%s", full))
		for t in types do append(&cmd, fmt.tprintf("--file-filter=*.%s", t))
		lines = pick(cmd[:])
	case .Kdialog:
		lines = pick({"kdialog", "--getsavefilename", full})
	case .None:
		no_picker()
	}
	if len(lines) == 0 do return "", false
	path = lines[0]
	if len(types) > 0 && !has_extension(path, types) do path = fmt.tprintf("%s.%s", path, types[0])
	return path, true
}

@(private = "file")
has_extension :: proc(name: string, types: []string) -> bool {
	for t in types do if strings.has_suffix(strings.to_lower(name, context.temp_allocator), fmt.tprintf(".%s", t)) do return true
	return false
}
