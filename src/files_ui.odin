package agentic_design

import "base:intrinsics"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import NS "core:sys/darwin/Foundation"
import "engine"

// Copies an image next to the document (images/) and adds a rectangle filled with it.
place_image :: proc(src: string, at: [2]f32) -> bool {
	if app.tab < 0 || !engine.is_image_file(src) do return false
	dir := fmt.tprintf("%s/images", os.dir(app.file_path))
	_ = os.make_directory_all(dir)
	name := os.base(src)
	dst := fmt.tprintf("%s/%s", dir, name)
	if !os.exists(dst) {
		if err := os.copy_file(dst, src); err != nil {
			set_status("Could not copy %s: %v", name, err)
			return false
		}
	}
	url := fmt.tprintf("./images/%s", name)
	_, iw, ih := engine.image_for(url)
	if iw == 0 || ih == 0 {
		set_status("Could not read %s", name)
		return false
	}
	w, h := f32(iw), f32(ih)
	if s := min(600 / w, 600 / h, 1); s < 1 do w, h = w * s, h * s

	push_undo()
	parent := frame_at(at, 0)
	n := new_node(.Rectangle, parent)
	engine.node_set_raw(&n, "name", fmt.tprintf(`"%s"`, engine.file_title(name)))
	engine.node_set_raw(&n, "fill", fmt.tprintf(`{{"type":"image","url":"%s","mode":"cover"}}`, url))
	added := engine.doc_add(&app.doc, n)
	set_box(added, at.x - w / 2, at.y - h / 2, w, h)
	clear(&app.sel)
	append(&app.sel, added.uid)
	app.tool = .Select
	mark_dirty()
	return true
}

handle_drops :: proc() {
	if len(pf.dropped) == 0 do return
	defer {
		for p in pf.dropped do delete(p)
		clear(&pf.dropped)
	}
	at := to_page(app.mouse) if in_rect(app.canvas, app.mouse) else to_page({app.canvas.x + app.canvas.w / 2, app.canvas.y + app.canvas.h / 2})
	fonts_dropped := make([dynamic]string, context.temp_allocator)
	for p in pf.dropped do if engine.is_font_file(p) && app.tab >= 0 do append(&fonts_dropped, p)
	if len(fonts_dropped) > 0 do import_font_files(fonts_dropped[:])
	for p in pf.dropped {
		if engine.is_font_file(p) do continue
		if strings.has_suffix(p, ".pen") {
			open_in_tab(p)
		} else if place_image(p, at) {
			at += {24, 24}
		}
	}
}

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
