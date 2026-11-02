package agentic_design

import "base:intrinsics"
import "core:fmt"
import "core:strings"
import NS "core:sys/darwin/Foundation"

// The save panel, the folder panel and Reveal in Finder behind exports (export_ui.odin).

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
