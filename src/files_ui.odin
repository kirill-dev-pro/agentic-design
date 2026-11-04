package agentic_design

import "core:c"
import "core:fmt"
import "core:strings"
import "engine"

// Copies an image next to the document (images/) and adds a rectangle filled with it.
place_image :: proc(src: string, at: [2]f32) -> bool {
	if app.tab < 0 || !engine.is_image_file(src) do return false
	dir := fmt.tprintf("%s/images", fs_dir(app.file_path))
	_ = fs_mkdir_all(dir)
	name := fs_base(src)
	dst := fmt.tprintf("%s/%s", dir, name)
	if !fs_exists(dst) {
		if err := fs_copy(dst, src); err != nil {
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
	at := to_page(app.mouse) if canvas_hit(app.mouse) else to_page(canvas_center())
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

