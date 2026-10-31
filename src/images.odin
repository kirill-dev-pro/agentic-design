package agentic_design

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import NS "core:sys/darwin/Foundation"
import "vendor:glfw"
import nvg "nanovg"

// Image fills: files referenced relative to the .pen document, loaded into NanoVG on demand.

images: map[string]int // absolute path -> nanovg image (0 = failed)

image_resolve :: proc(url: string) -> string {
	if os.is_absolute_path(url) do return url
	u := url
	if strings.has_prefix(u, "./") do u = u[2:]
	return fmt.tprintf("%s/%s", os.dir(app.file_path), u)
}

image_for :: proc(url: string) -> (img: int, w, h: int) {
	path := image_resolve(url)
	if cached, has := images[path]; has {
		img = cached
	} else {
		img = nvg.CreateImagePath(app.vg, strings.clone_to_cstring(path, context.temp_allocator), {})
		if img < 0 do img = 0
		images[strings.clone(path)] = img
	}
	if img > 0 do w, h = nvg.ImageSize(app.vg, img)
	return
}

// Draws an image into the current path with cover/contain/stretch fitting.
image_fill :: proc(vg: ^nvg.Context, n: ^Node) -> bool {
	img, iw, ih := image_for(n.image_url)
	if img == 0 || iw == 0 || ih == 0 do return false
	w, h := f32(iw), f32(ih)
	dw, dh := n.w, n.h
	switch n.image_mode {
	case .Cover:
		s := max(n.w / w, n.h / h)
		dw, dh = w * s, h * s
	case .Contain:
		s := min(n.w / w, n.h / h)
		dw, dh = w * s, h * s
	case .Stretch:
	}
	dx, dy := n.x + (n.w - dw) / 2, n.y + (n.h - dh) / 2
	nvg.FillPaint(vg, nvg.ImagePattern(dx, dy, dw, dh, 0, img, 1))
	nvg.Fill(vg)
	return true
}

IMAGE_EXTS := [?]string{".png", ".jpg", ".jpeg", ".gif", ".bmp", ".psd", ".tga"}

is_image_file :: proc(path: string) -> bool {
	lower := strings.to_lower(path, context.temp_allocator)
	for e in IMAGE_EXTS do if strings.has_suffix(lower, e) do return true
	return false
}

// Copies an image next to the document (images/) and adds a rectangle filled with it.
place_image :: proc(src: string, at: [2]f32) -> bool {
	if app.tab < 0 || !is_image_file(src) do return false
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
	_, iw, ih := image_for(url)
	if iw == 0 || ih == 0 {
		set_status("Could not read %s", name)
		return false
	}
	w, h := f32(iw), f32(ih)
	if s := min(600 / w, 600 / h, 1); s < 1 do w, h = w * s, h * s

	push_undo()
	parent := frame_at(at, 0)
	n := new_node(.Rectangle, parent)
	node_set_raw(&n, "name", fmt.tprintf(`"%s"`, file_title(name)))
	node_set_raw(&n, "fill", fmt.tprintf(`{{"type":"image","url":"%s","mode":"cover"}}`, url))
	added := doc_add(&app.doc, n)
	set_box(added, at.x - w / 2, at.y - h / 2, w, h)
	clear(&app.sel)
	append(&app.sel, added.uid)
	app.tool = .Select
	mark_dirty()
	return true
}

// Files dropped on the window land where the pointer is.
drop_callback :: proc "c" (window: glfw.WindowHandle, count: c.int, paths: [^]cstring) {
	context = runtime.default_context()
	for i in 0 ..< int(count) do append(&pf.dropped, strings.clone(string(paths[i])))
}

handle_drops :: proc() {
	if len(pf.dropped) == 0 do return
	defer {
		for p in pf.dropped do delete(p)
		clear(&pf.dropped)
	}
	at := to_page(app.mouse) if in_rect(app.canvas, app.mouse) else to_page({app.canvas.x + app.canvas.w / 2, app.canvas.y + app.canvas.h / 2})
	fonts_dropped := make([dynamic]string, context.temp_allocator)
	for p in pf.dropped do if is_font_file(p) && app.tab >= 0 do append(&fonts_dropped, p)
	if len(fonts_dropped) > 0 do import_font_files(fonts_dropped[:])
	for p in pf.dropped {
		if is_font_file(p) do continue
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

// Puts data of one type (a UTI such as "public.png" or "public.html") on the system
// clipboard; `text` adds a plain-text version beside it.
clipboard_set :: proc(data: []u8, uti: string, text := "") {
	pb := intrinsics.objc_send(^NS.Pasteboard, NS.Pasteboard, "generalPasteboard")
	if pb == nil do return
	_ = intrinsics.objc_send(NS.Integer, pb, "clearContents")
	d := NS.Data.alloc()->initWithBytes(data)
	t := NS.String.alloc()->initWithOdinString(uti)
	_ = intrinsics.objc_send(NS.BOOL, pb, "setData:forType:", d, t)
	if text != "" {
		s := NS.String.alloc()->initWithOdinString(text)
		_ = intrinsics.objc_send(NS.BOOL, pb, "setString:forType:", s, NS.AT("public.utf8-plain-text"))
	}
}

