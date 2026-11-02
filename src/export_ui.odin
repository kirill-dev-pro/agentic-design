package agentic_design

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strings"
import NS "core:sys/darwin/Foundation"
import "engine"

// Writes the files into a folder next to the document (or `dir`) and returns it.
export_code_to_dir :: proc(format: engine.Code_Format, dir := "", roots: []int = nil) -> (string, bool) {
	files := engine.generate_code(&app.doc, format, roots)
	target := dir
	if target == "" do target = fmt.tprintf("%s/%s", downloads_dir(), code_folder_name(format))
	if err := os.make_directory_all(target); err != nil && !os.is_dir(target) do return target, false // fails on an existing folder
	for f in files {
		if err := os.write_entire_file(fmt.tprintf("%s/%s", target, f.name), f.content); err != nil do return target, false
	}
	// the fonts and images the code refers to, next to it
	for rel, src in engine.export_assets {
		dst := fmt.tprintf("%s/%s", target, rel)
		_ = os.make_directory_all(os.dir(dst))
		if os.exists(dst) do _ = os.remove(dst)
		if err := os.copy_file(dst, src); err != nil do return target, false
	}
	return target, true
}

code_folder_name :: proc(format: engine.Code_Format) -> string {
	return fmt.tprintf("%s-%s", engine.file_title(app.file_path), "html" if format == .HTML else "react")
}

// The Export menu's code export: the system save panel names the folder the files go into
// (a quiet window writes to its default folder without asking).
export_code_ui :: proc(format: engine.Code_Format) {
	target, ok := ask_save_path(code_folder_name(format), nil)
	if !ok do return
	if dir, wok := export_code_to_dir(format, target); wok {
		remember_export_dir(os.dir(dir))
		export_done(fmt.tprintf("Exported %s", os.base(dir)), dir)
	} else {
		set_status("Export failed: could not write to %s", dir)
	}
}

// Where exports go without asking: ~/Downloads, or for a quiet (test) window a folder in
// $TMPDIR. ~/Downloads is privacy-protected: the first write from a process without access
// waits in open() for the user to answer a system prompt, which froze a fuzzed test window
// (and would show the user a dialog).
downloads_dir :: proc() -> string {
	if pf.quiet {
		dir := fmt.tprintf("%s/agentic-design-downloads", strings.trim_suffix(os.temp_directory(context.temp_allocator) or_else "/tmp", "/"))
		_ = os.make_directory_all(dir)
		return dir
	}
	home, _ := os.user_home_dir(context.temp_allocator)
	return fmt.tprintf("%s/Downloads", home)
}

// ---------------------------------------------------------------- save panels

// The folder a save panel opens in: the last one exported to, else the document's folder.
export_start_dir :: proc() -> string {
	if settings.export_dir != "" && os.is_dir(settings.export_dir) do return settings.export_dir
	if app.file_path != "" do return os.dir(app.file_path)
	return downloads_dir()
}

remember_export_dir :: proc(dir: string) {
	if pf.quiet || dir == "" || dir == settings.export_dir do return
	delete(settings.export_dir)
	settings.export_dir = strings.clone(dir)
	settings_save()
}

// A layer's name as a file name: no path separators, no leading dot.
file_safe_name :: proc(name: string) -> string {
	s, _ := strings.replace_all(strings.trim_space(name), "/", "-", context.temp_allocator)
	s, _ = strings.replace_all(s, ":", "-", context.temp_allocator)
	s = strings.trim_left(s, ".")
	if len(s) > 120 do s = s[:120]
	return s if s != "" else "Untitled"
}

// Autoreleased: valid until the enclosing pool drains.
ns_string :: proc(s: string) -> ^NS.String {
	o := NS.String.alloc()->initWithOdinString(s)
	o->autorelease()
	return o
}

ns_file_url :: proc(path: string) -> ^NS.URL {
	o := NS.URL.alloc()->initFileURLWithPath(ns_string(path))
	o->autorelease()
	return o
}

// The system save panel, opened in export_start_dir with `name` filled in. `types` limits
// the extensions (the first is added when the name has none of them); nil for a folder
// name. Cancel returns false. A quiet window never shows it: it answers its default
// folder, so tests and the fuzzer cannot wait on a modal panel.
ask_save_path :: proc(name: string, types: []string) -> (path: string, ok: bool) {
	if pf.quiet {
		file := name if len(types) == 0 else fmt.tprintf("%s.%s", name, types[0])
		return fmt.tprintf("%s/%s", downloads_dir(), file), true
	}
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()
	panel := NS.SavePanel.savePanel()
	intrinsics.objc_send(nil, panel, "setCanCreateDirectories:", NS.BOOL(true))
	intrinsics.objc_send(nil, panel, "setNameFieldStringValue:", ns_string(name))
	intrinsics.objc_send(nil, panel, "setDirectoryURL:", ns_file_url(export_start_dir()))
	if len(types) > 0 {
		arr := make([]^NS.Object, len(types), context.temp_allocator)
		for t, i in types do arr[i] = ns_string(t)
		list := NS.Array.alloc()->initWithObjects(raw_data(arr), NS.UInteger(len(arr)))
		list->autorelease()
		intrinsics.objc_send(nil, panel, "setAllowedFileTypes:", list)
		intrinsics.objc_send(nil, panel, "setAllowsOtherFileTypes:", NS.BOOL(false))
	}
	if panel->runModal() != .OK do return "", false
	url := panel->URL()
	if url == nil do return "", false
	return strings.clone(intrinsics.objc_send(^NS.String, url, "path")->odinString(), context.temp_allocator), true
}

// The system open panel choosing a folder (several layers exported at once).
ask_folder :: proc() -> (dir: string, ok: bool) {
	if pf.quiet do return downloads_dir(), true
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()
	panel := NS.OpenPanel.openPanel()
	panel->setCanChooseDirectories(true)
	panel->setCanChooseFiles(false)
	panel->setAllowsMultipleSelection(false)
	intrinsics.objc_send(nil, panel, "setCanCreateDirectories:", NS.BOOL(true))
	intrinsics.objc_send(nil, panel, "setPrompt:", NS.AT("Export"))
	intrinsics.objc_send(nil, panel, "setMessage:", NS.AT("Choose a folder: each layer is saved as a file named after it."))
	intrinsics.objc_send(nil, panel, "setDirectoryURL:", ns_file_url(export_start_dir()))
	if panel->runModal() != .OK do return "", false
	urls := panel->URLs()
	if urls->count() == 0 do return "", false
	url := urls->objectAs(0, ^NS.URL)
	return strings.clone(intrinsics.objc_send(^NS.String, url, "path")->odinString(), context.temp_allocator), true
}

// After an export: the toast, with "Show in Finder" for `path`.
export_done :: proc(msg, path: string) {
	set_status("%s", msg)
	delete(app.status_reveal)
	app.status_reveal = strings.clone(path)
}

@(objc_class = "NSWorkspace")
Workspace :: struct {
	using _: NS.Object,
}

// Selects `path` in a Finder window.
reveal_in_finder :: proc(path: string) {
	if pf.quiet || path == "" do return
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()
	ws := intrinsics.objc_send(^Workspace, Workspace, "sharedWorkspace")
	_ = intrinsics.objc_send(NS.BOOL, ws, "selectFile:inFileViewerRootedAtPath:", ns_string(path), NS.AT(""))
}
