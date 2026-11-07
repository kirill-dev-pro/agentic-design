#+build linux
package agentic_design

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "engine"
import "vendor:glfw"

// The Linux side of what macOS does in *_darwin.odin: the desktop's commands (xdg-open,
// gio, secret-tool, gdbus), the locale from the environment and the window's X11 or
// Wayland surface for WebGPU. A missing command is a status line, never a crash.

// Runs a command and waits; its output in temporary memory.
@(private = "file")
run_command :: proc(command: []string, input := "") -> (out: string, ok: bool) {
	desc := os.Process_Desc{command = command}
	rd, wr: ^os.File
	if input != "" {
		perr: os.Error
		rd, wr, perr = os.pipe()
		if perr != nil do return "", false
		_, _ = os.write(wr, transmute([]u8)input)
		os.close(wr)
		desc.stdin = rd
	}
	state, stdout, _, err := os.process_exec(desc, context.temp_allocator)
	if rd != nil do os.close(rd)
	if err != nil do return "", false
	return string(stdout), state.exited && state.exit_code == 0
}

// Starts a command and leaves it running (a browser, a file manager).
@(private = "file")
spawn :: proc(command: ..string) -> bool {
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "/bin/sh", "-c", `"$@" >/dev/null 2>&1 &`, "sh")
	append(&args, ..command)
	_, ok := run_command(args[:])
	return ok
}

@(private = "file")
have :: proc(name: string) -> bool {
	_, ok := run_command({"/bin/sh", "-c", `command -v "$1" >/dev/null`, "sh", name})
	return ok
}

// Opens a web address in the default browser. Test windows open nothing.
open_url :: proc(url: string) {
	if pf.quiet {
		set_status("Test window: not opening %s", url)
		return
	}
	if !spawn("xdg-open", url) do set_status("Could not open %s (xdg-open is missing)", url)
}

// Shows `path` selected in the file manager (FileManager1 over D-Bus), or its folder.
reveal_in_finder :: proc(path: string) {
	if pf.quiet || path == "" do return
	uri := fmt.tprintf("['file://%s']", path)
	if _, ok := run_command({"gdbus", "call", "--session", "--dest", "org.freedesktop.FileManager1", "--object-path", "/org/freedesktop/FileManager1", "--method", "org.freedesktop.FileManager1.ShowItems", uri, ""}); ok do return
	spawn("xdg-open", os.dir(path))
}

// Moves a file to the desktop's trash (gio, as the file manager does), so it can be put
// back. Returns the error, if any.
move_to_trash :: proc(path: string) -> (trashed: string, err_text: string) {
	if _, ok := run_command({"gio", "trash", path}); ok do return "", ""
	if _, ok := run_command({"kioclient", "move", path, "trash:/"}); ok do return "", ""
	return "", "no trash command (gio or kioclient) worked"
}

// The first preferred language ("ru-RU", "en"), from the locale variables.
preferred_language :: proc() -> string {
	for name in ([]string{"LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG"}) {
		v := os.get_env(name, context.temp_allocator)
		if v == "" || v == "C" || v == "POSIX" do continue
		if i := strings.index_byte(v, ':'); i >= 0 do v = v[:i] // LANGUAGE is a list
		if i := strings.index_any(v, ".@"); i >= 0 do v = v[:i] // ru_RU.UTF-8
		s, _ := strings.replace_all(v, "_", "-", context.temp_allocator)
		return s
	}
	return ""
}

// ---------------------------------------------------------------- secrets

// The cloud's token in the desktop's keyring (libsecret's secret-tool, GNOME Keyring or
// KWallet behind it). Without one, a file only the user can read in the support folder,
// as command-line tools keep their tokens.

@(private = "file")
secrets_file :: proc() -> string {
	return fmt.tprintf("%s/secrets.json", support_dir())
}

@(private = "file")
secrets_read :: proc() -> json.Object {
	data, err := os.read_entire_file(secrets_file(), context.temp_allocator)
	if err != nil do return nil
	v, jerr := json.parse(data, allocator = context.temp_allocator)
	if jerr != nil do return nil
	return v.(json.Object) or_else nil
}

@(private = "file")
secrets_write :: proc(o: json.Object) -> bool {
	_ = os.make_directory_all(support_dir())
	text, err := json.marshal(o, allocator = context.temp_allocator)
	if err != nil do return false
	f, ferr := os.open(secrets_file(), {.Write, .Create, .Trunc}, os.Permissions{.Read_User, .Write_User})
	if ferr != nil do return false
	defer os.close(f)
	_, werr := os.write(f, text)
	return werr == nil
}

keychain_get :: proc(service, account: string, allocator := context.allocator) -> string {
	if have("secret-tool") {
		out, ok := run_command({"secret-tool", "lookup", "service", service, "account", account})
		return strings.clone(strings.trim_right(out, "\n"), allocator) if ok else ""
	}
	o := secrets_read()
	s, _ := o[fmt.tprintf("%s\x1f%s", service, account)].(json.String)
	return strings.clone(s, allocator)
}

keychain_set :: proc(service, account, label, secret: string) -> bool {
	if have("secret-tool") {
		_, ok := run_command({"secret-tool", "store", "--label", label, "service", service, "account", account}, secret)
		return ok
	}
	o := secrets_read()
	if o == nil do o = make(json.Object, 4, context.temp_allocator)
	o[fmt.tprintf("%s\x1f%s", service, account)] = json.String(secret)
	return secrets_write(o)
}

keychain_delete :: proc(service, account: string) {
	if have("secret-tool") {
		run_command({"secret-tool", "clear", "service", service, "account", account})
		return
	}
	o := secrets_read()
	if o == nil do return
	delete_key(&o, fmt.tprintf("%s\x1f%s", service, account))
	secrets_write(o)
}

// This computer's name, for the cloud's device list.
device_name :: proc() -> string {
	data, err := os.read_entire_file("/etc/hostname", context.temp_allocator)
	name := strings.trim_space(string(data)) if err == nil else ""
	return name[:min(len(name), 80)] if name != "" else "Linux"
}

// ---------------------------------------------------------------- window

// The window's surface for WebGPU: Wayland when GLFW runs on it, X11 otherwise.
platform_native_surface :: proc(window: glfw.WindowHandle) -> engine.Gpu_Surface {
	if glfw.GetPlatform != nil && glfw.GetPlatform() == glfw.PLATFORM_WAYLAND {
		return {wayland_display = glfw.GetWaylandDisplay(), wayland_surface = glfw.GetWaylandWindow(window)}
	}
	return {x11_display = glfw.GetX11Display(), x11_window = u64(glfw.GetX11Window(window))}
}
