package agentic_design

import "base:intrinsics"
import "core:strings"
import NS "core:sys/darwin/Foundation"

// The open panels behind Open, Import font, Import library and Place image
// (files_ui.odin uses them).

// "Place image": the system open panel, then the image goes to the canvas centre.
// Opens .pen files chosen in the system panel, each in a tab.
open_file_dialog :: proc() {
	if pf.quiet {
		set_status("File dialogs are disabled in quiet (test) mode")
		return
	}
	panel := NS.OpenPanel.openPanel()
	panel->setAllowsMultipleSelection(true)
	panel->setCanChooseDirectories(false)
	if panel->runModal() != .OK do return
	urls := panel->URLs()
	for i in 0 ..< int(urls->count()) {
		url := urls->objectAs(NS.UInteger(i), ^NS.URL)
		path := intrinsics.objc_send(^NS.String, url, "path")->odinString()
		if !open_in_tab(path) do set_status("%s is not a .pen document", path)
	}
}

// "Import font": font files chosen in the system panel go into the document's fonts folder.
import_font_dialog :: proc() {
	if pf.quiet {
		set_status("File dialogs are disabled in quiet (test) mode; drop a font file instead")
		return
	}
	panel := NS.OpenPanel.openPanel()
	panel->setAllowsMultipleSelection(true)
	panel->setCanChooseDirectories(false)
	if panel->runModal() != .OK do return
	urls := panel->URLs()
	paths := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< int(urls->count()) {
		url := urls->objectAs(NS.UInteger(i), ^NS.URL)
		append(&paths, intrinsics.objc_send(^NS.String, url, "path")->odinString())
	}
	import_font_files(paths[:])
}

// "Import library": .pen files chosen in the system panel become imported libraries.
import_library_dialog :: proc() {
	if pf.quiet {
		set_status("File dialogs are disabled in quiet (test) mode; use the set_libraries tool")
		return
	}
	panel := NS.OpenPanel.openPanel()
	panel->setAllowsMultipleSelection(true)
	panel->setCanChooseDirectories(false)
	if panel->runModal() != .OK do return
	urls := panel->URLs()
	for i in 0 ..< int(urls->count()) {
		url := urls->objectAs(NS.UInteger(i), ^NS.URL)
		path := intrinsics.objc_send(^NS.String, url, "path")->odinString()
		if alias, ok := library_add(path); ok do set_status("Imported %s as \"%s\"", path, alias)
	}
}

place_image_dialog :: proc() {
	if pf.quiet {
		set_status("File dialogs are disabled in quiet (test) mode; drop a file instead")
		return
	}
	panel := NS.OpenPanel.openPanel()
	panel->setAllowsMultipleSelection(true)
	panel->setCanChooseDirectories(false)
	if panel->runModal() != .OK do return
	urls := panel->URLs()
	at := to_page(canvas_center())
	for i in 0 ..< int(urls->count()) {
		url := urls->objectAs(NS.UInteger(i), ^NS.URL)
		path := intrinsics.objc_send(^NS.String, url, "path")->odinString()
		if place_image(path, at) do at += {24, 24}
	}
}

// Context for the agent (agent_input.odin): folders or files chosen in the system panel.
ask_context_paths :: proc(folders: bool) -> []string {
	if pf.quiet do return nil
	panel := NS.OpenPanel.openPanel()
	panel->setAllowsMultipleSelection(true)
	panel->setCanChooseDirectories(folders)
	panel->setCanChooseFiles(!folders)
	intrinsics.objc_send(nil, panel, "setPrompt:", NS.AT("Attach"))
	intrinsics.objc_send(nil, panel, "setMessage:", NS.AT("The agent may read and search what you attach, for this design."))
	if panel->runModal() != .OK do return nil
	urls := panel->URLs()
	out := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< int(urls->count()) {
		url := urls->objectAs(NS.UInteger(i), ^NS.URL)
		append(&out, strings.clone(intrinsics.objc_send(^NS.String, url, "path")->odinString(), context.temp_allocator))
	}
	return out[:]
}
