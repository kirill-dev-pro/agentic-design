package agentic_design

import "base:intrinsics"
import "core:strings"
import NS "core:sys/darwin/Foundation"

// The macOS open and save panels behind dialogs.odin, and Reveal in Finder.

// Autoreleased: valid until the enclosing pool drains. The bytes are copied: Foundation's
// initWithOdinString does not copy them, and what keeps the string (a request's headers, read
// later on CFNetwork's own thread) then reads memory the temporary allocator has reused.
ns_string :: proc(s: string) -> ^NS.String {
	o := intrinsics.objc_send(^NS.String, NS.String.alloc(), "initWithBytes:length:encoding:", raw_data(s), NS.UInteger(len(s)), NS.StringEncoding.UTF8)
	o->autorelease()
	return o
}

ns_file_url :: proc(path: string) -> ^NS.URL {
	o := NS.URL.alloc()->initFileURLWithPath(ns_string(path))
	o->autorelease()
	return o
}

// The chosen paths (temporary memory), none when cancelled.
system_open_panel :: proc(p: Open_Panel) -> []string {
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()
	panel := NS.OpenPanel.openPanel()
	panel->setAllowsMultipleSelection(NS.BOOL(p.multiple))
	panel->setCanChooseDirectories(NS.BOOL(p.folders))
	panel->setCanChooseFiles(NS.BOOL(!p.folders))
	if p.folders do intrinsics.objc_send(nil, panel, "setCanCreateDirectories:", NS.BOOL(true))
	if p.prompt != "" do intrinsics.objc_send(nil, panel, "setPrompt:", ns_string(p.prompt))
	if p.message != "" do intrinsics.objc_send(nil, panel, "setMessage:", ns_string(p.message))
	if p.start != "" do intrinsics.objc_send(nil, panel, "setDirectoryURL:", ns_file_url(p.start))
	if panel->runModal() != .OK do return nil
	urls := panel->URLs()
	out := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< int(urls->count()) {
		url := urls->objectAs(NS.UInteger(i), ^NS.URL)
		append(&out, strings.clone(intrinsics.objc_send(^NS.String, url, "path")->odinString(), context.temp_allocator))
	}
	return out[:]
}

// The save panel in `start` with `name` filled in; `types` limits the extensions.
system_save_panel :: proc(name: string, types: []string, start: string) -> (path: string, ok: bool) {
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()
	panel := NS.SavePanel.savePanel()
	intrinsics.objc_send(nil, panel, "setCanCreateDirectories:", NS.BOOL(true))
	intrinsics.objc_send(nil, panel, "setNameFieldStringValue:", ns_string(name))
	if start != "" do intrinsics.objc_send(nil, panel, "setDirectoryURL:", ns_file_url(start))
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
