package agentic_design

import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"
import "core:time"
import nvg "nanovg"

// Open documents live in tabs. The active tab's state is held in `app` (doc, path,
// selection, undo stacks, camera); the others keep theirs here until activated.
// app.tab == -1 shows the dashboard.

Tab :: struct {
	doc:           Document,
	path:          string,
	dirty:         bool,
	last_change:   time.Time,
	cam:           [2]f32,
	zoom:          f32,
	sel:           [dynamic]int,
	editing:       int,
	undo_stack:    [dynamic]Snapshot,
	redo_stack:    [dynamic]Snapshot,
	layers_scroll: f32,
	insp_scroll:   f32,
	expanded:      map[int]bool,
	page:          int,
}

// Moves the live state into its tab and leaves `app` with an empty document.
tab_store :: proc() {
	if app.tab < 0 || app.tab >= len(app.tabs) do return
	t := &app.tabs[app.tab]
	t.doc, t.path, t.dirty, t.last_change = app.doc, app.file_path, app.dirty, app.last_change
	t.cam, t.zoom, t.sel, t.editing = app.cam, app.zoom, app.sel, app.editing
	t.undo_stack, t.redo_stack = app.undo_stack, app.redo_stack
	t.layers_scroll, t.insp_scroll, t.expanded = app.layers_scroll, ui.insp_scroll, ui.expanded
	t.page = app.page
	app.page = 0
	app.doc, app.file_path, app.sel = {}, "", {}
	app.undo_stack, app.redo_stack = {}, {}
	ui.expanded = {}
	app.dirty, app.editing, app.hover = false, 0, 0
	app.drag = {}
}

tab_activate :: proc(i: int) {
	if i == app.tab do return
	if app.editing != 0 do finish_text_editing()
	if ui.focus != "" do field_commit()
	tab_store()
	app.tab = i
	if i >= 0 && i < len(app.tabs) {
		t := &app.tabs[i]
		app.doc, app.file_path, app.dirty, app.last_change = t.doc, t.path, t.dirty, t.last_change
		app.cam, app.zoom, app.sel, app.editing = t.cam, t.zoom, t.sel, t.editing
		app.undo_stack, app.redo_stack = t.undo_stack, t.redo_stack
		app.layers_scroll, ui.insp_scroll, ui.expanded = t.layers_scroll, t.insp_scroll, t.expanded
		app.page = t.page
		t^ = {}
		ui.last_sel = -1
	}
	app.tool = .Select
	app.needs_layout = true
	if app.tab >= 0 {
		theme_defaults(&app.doc)
		doc_retheme(&app.doc)
	}
	update_title()
}

tab_title :: proc(i: int) -> string {
	if i == app.tab do return file_title(app.file_path)
	return file_title(app.tabs[i].path)
}

tab_dirty :: proc(i: int) -> bool {
	return app.dirty if i == app.tab else app.tabs[i].dirty
}

absolute_path :: proc(path: string, allocator := context.temp_allocator) -> string {
	if os.is_absolute_path(path) do return strings.clone(path, allocator)
	wd, err := os.get_working_directory(context.temp_allocator)
	if err != nil do return strings.clone(path, allocator)
	return fmt.aprintf("%s/%s", wd, path, allocator = allocator)
}

// Opens a .pen file in a new tab, or switches to it when it is already open.
open_in_tab :: proc(path: string) -> bool {
	abs := absolute_path(path)
	for i in 0 ..< len(app.tabs) {
		p := app.file_path if i == app.tab else app.tabs[i].path
		if p == abs {
			tab_activate(i)
			return true
		}
	}
	data, rerr := os.read_entire_file(abs, context.temp_allocator)
	if rerr != nil do return false
	append(&app.tabs, Tab{zoom = 1, cam = {-80, -60}})
	tab_activate(len(app.tabs) - 1)
	fonts_add_document_dir(abs)
	if !doc_load(&app.doc, string(data)) {
		close_tab(app.tab)
		return false
	}
	doc_load_imports(&app.doc, abs)
	app.file_path = strings.clone(abs)
	recents_touch(abs)
	update_title()
	return true
}

// Saves (if needed) and closes a tab; the dashboard shows when none is left.
close_tab :: proc(i: int) {
	if i < 0 || i >= len(app.tabs) do return
	if i == app.tab {
		if app.dirty do save_document(app.file_path)
		if app.editing != 0 do finish_text_editing()
		ui.focus = ""
		tab_store()
		app.tab = -1
	}
	t := &app.tabs[i]
	doc_clear(&t.doc)
	pages_free(&t.doc.pages)
	delete(t.doc.pages)
	delete(t.doc.nodes)
	delete(t.doc.header)
	delete(t.doc.vars)
	delete(t.path)
	delete(t.sel)
	for s in t.undo_stack do free_snapshot(s)
	delete(t.undo_stack)
	for s in t.redo_stack do free_snapshot(s)
	delete(t.redo_stack)
	delete(t.expanded)
	ordered_remove(&app.tabs, i)
	if app.tab > i do app.tab -= 1
	if app.tab < 0 && len(app.tabs) > 0 do tab_activate(min(i, len(app.tabs) - 1))
	else do update_title()
}

// Renames the open file on disk and in every place that refers to it.
rename_document :: proc(new_title: string) -> bool {
	title := strings.trim_space(new_title)
	if title == "" || strings.contains(title, "/") do return false
	if strings.has_suffix(title, ".pen") do title = title[:len(title) - 4]
	new_path := fmt.aprintf("%s/%s.pen", os.dir(app.file_path), title)
	if new_path == app.file_path {
		delete(new_path)
		return true
	}
	if os.exists(new_path) {
		set_status("%s already exists", os.base(new_path))
		delete(new_path)
		return false
	}
	if app.dirty do save_document(app.file_path)
	if err := os.rename(app.file_path, new_path); err != nil {
		set_status("Rename failed: %v", err)
		delete(new_path)
		return false
	}
	recents_rename(app.file_path, new_path)
	delete(app.file_path)
	app.file_path = new_path
	update_title()
	return true
}

// ---------------------------------------------------------------- recents

Recent :: struct {
	path: string,
	time: i64, // unix seconds of the last open or save
}

recents: [dynamic]Recent

support_dir :: proc() -> string {
	home, _ := os.user_home_dir(context.temp_allocator)
	return fmt.tprintf("%s/Library/Application Support/Agentic Design", home)
}

recents_load :: proc() {
	// test windows show no recent files, so a scripted or fuzzed run cannot open (and
	// autosave) the user's documents from the dashboard
	if pf.quiet do return
	data, err := os.read_entire_file(fmt.tprintf("%s/recents.json", support_dir()), context.temp_allocator)
	if err != nil do return
	root, perr := json.parse_string(string(data), .JSON, false, context.temp_allocator)
	if perr != nil do return
	arr, ok := root.(json.Array)
	if !ok do return
	for item in arr {
		obj, is_obj := item.(json.Object)
		if !is_obj do continue
		path := string(obj["path"].(json.String) or_else "")
		if path == "" do continue
		append(&recents, Recent{strings.clone(path), i64(obj["time"].(json.Float) or_else 0)})
	}
}

recents_save :: proc() {
	dir := support_dir()
	_ = os.make_directory_all(dir)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "[\n")
	for r, i in recents {
		if i > 0 do strings.write_string(&b, ",\n")
		strings.write_string(&b, `  {"path":`)
		json_write_string(&b, r.path)
		fmt.sbprintf(&b, `,"time":%d}}`, r.time)
	}
	strings.write_string(&b, "\n]\n")
	_ = os.write_entire_file(fmt.tprintf("%s/recents.json", dir), strings.to_string(b))
}

recents_touch :: proc(path: string) {
	if pf.quiet do return // test windows leave the user's recent files alone
	for r, i in recents {
		if r.path == path {
			ordered_remove(&recents, i)
			inject_at(&recents, 0, Recent{r.path, time.now()._nsec / 1_000_000_000})
			recents_save()
			return
		}
	}
	inject_at(&recents, 0, Recent{strings.clone(path), time.now()._nsec / 1_000_000_000})
	for len(recents) > 40 {
		delete(recents[len(recents) - 1].path)
		pop(&recents)
	}
	recents_save()
}

recents_remove :: proc(path: string) {
	for r, i in recents do if r.path == path {
		delete(r.path)
		ordered_remove(&recents, i)
		break
	}
	recents_save()
}

recents_rename :: proc(old, new: string) {
	for &r in recents do if r.path == old {
		delete(r.path)
		r.path = strings.clone(new)
	}
	recents_save()
	if img, ok := thumbs[old]; ok {
		if img > 0 do nvg.DeleteImage(app.vg, img)
		delete_key(&thumbs, old)
	}
	thumb_request(new)
}

// ---------------------------------------------------------------- thumbnails

thumbs: map[string]int // file path -> nanovg image (0 = none)
thumb_queue: [dynamic]string

thumb_path :: proc(path: string) -> string {
	h := hash.fnv64a(transmute([]u8)path)
	return fmt.tprintf("%s/thumbs/%016x.png", support_dir(), h)
}

thumb_request :: proc(path: string) {
	for q in thumb_queue do if q == path do return
	append(&thumb_queue, strings.clone(path))
}

// Renders queued thumbnails from the saved files. Called between frames, outside
// nanovg frames, because it draws with the main context.
thumbs_render :: proc() {
	if len(thumb_queue) == 0 do return
	paths := thumb_queue
	thumb_queue = {}
	defer {
		for p in paths do delete(p)
		delete(paths)
	}
	_ = os.make_directory_all(fmt.tprintf("%s/thumbs", support_dir()))
	for path in paths {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil do continue
		tmp: Document
		if !doc_load(&tmp, string(data)) do continue
		saved := app.doc
		saved_page := app.page
		app.doc = tmp
		doc_load_imports(&app.doc, path)
		app.page = 0
		layout_document(&app.doc)
		pages_sync()
		if r, ok := bounds_of(all_uids(true)); ok {
			pad: f32 = 24
			r = {r[0] - pad, r[1] - pad, r[2] + pad * 2, r[3] + pad * 2}
			scale := min(560 / r[2], 360 / r[3], 2)
			if pixels, w, h, rok := render_region(r, scale, nil, {0.157, 0.157, 0.157, 1}); rok {
				if png, pok := png_encode(pixels, w, h); pok do _ = os.write_entire_file(thumb_path(path), png)
			}
		}
		app.doc = saved
		app.page = saved_page
		doc_clear(&tmp)
		pages_free(&tmp.pages)
		delete(tmp.pages)
		delete(tmp.nodes)
		delete(tmp.header)
		delete(tmp.vars)
		if img, has := thumbs[path]; has {
			if img > 0 do nvg.DeleteImage(app.vg, img)
			delete_key(&thumbs, path)
		}
	}
}

thumb_image :: proc(path: string) -> int {
	if img, has := thumbs[path]; has do return img
	file := thumb_path(path)
	img := 0
	if os.exists(file) do img = nvg.CreateImagePath(app.vg, strings.clone_to_cstring(file, context.temp_allocator), {})
	thumbs[strings.clone(path)] = img
	return img
}
