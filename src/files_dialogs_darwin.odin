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
	at := to_page({app.canvas.x + app.canvas.w / 2, app.canvas.y + app.canvas.h / 2})
	for i in 0 ..< int(urls->count()) {
		url := urls->objectAs(NS.UInteger(i), ^NS.URL)
		path := intrinsics.objc_send(^NS.String, url, "path")->odinString()
		if place_image(path, at) do at += {24, 24}
	}
}
