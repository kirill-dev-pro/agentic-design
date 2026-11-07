package agentic_design

import "engine"

import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:strings"
import "core:thread"
import "core:time"
import nvg "nanovg"

// Open documents live in tabs. The active tab's state is held in `app` (doc, path,
// selection, undo stacks, camera); the others keep theirs here until activated.
// app.tab == -1 shows the dashboard.

Tab :: struct {
	doc:           engine.Document,
	path:          string,
	dirty:         bool,
	last_change:   time.Time,
	cam:           [2]f32,
	zoom:          f32,
	sel:           [dynamic]int,
	editing:       int,
	undo_stack:    [dynamic]engine.Snapshot,
	redo_stack:    [dynamic]engine.Snapshot,
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
		engine.theme_defaults(&app.doc)
		engine.doc_retheme(&app.doc)
	}
	update_title()
}

tab_title :: proc(i: int) -> string {
	if i == app.tab do return engine.file_title(app.file_path)
	return engine.file_title(app.tabs[i].path)
}

tab_dirty :: proc(i: int) -> bool {
	return app.dirty if i == app.tab else app.tabs[i].dirty
}

// Opens a .pen file in a new tab, or switches to it when it is already open.
open_in_tab :: proc(path: string) -> bool {
	abs := engine.absolute_path(path)
	for i in 0 ..< len(app.tabs) {
		p := app.file_path if i == app.tab else app.tabs[i].path
		if p == abs {
			tab_activate(i)
			return true
		}
	}
	when ODIN_OS != .JS {
		// a document an agent was working on in the background: with its undo history
		if t, ok := background_take(abs); ok {
			append(&app.tabs, t)
			tab_activate(len(app.tabs) - 1)
			recents_touch(abs)
			update_title()
			return true
		}
	}
	data, rerr := fs_read(abs, context.temp_allocator)
	if rerr != nil do return false
	append(&app.tabs, Tab{zoom = 1, cam = {-80, -60}})
	tab_activate(len(app.tabs) - 1)
	engine.fonts_add_document_dir(abs)
	if !engine.doc_load(&app.doc, string(data)) {
		close_tab(app.tab)
		return false
	}
	app.doc.path = strings.clone(abs)
	engine.doc_load_imports(&app.doc, abs)
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
	engine.doc_destroy(&t.doc)
	delete(t.path)
	delete(t.sel)
	for s in t.undo_stack do engine.free_snapshot(s)
	delete(t.undo_stack)
	for s in t.redo_stack do engine.free_snapshot(s)
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
	new_path := fmt.aprintf("%s/%s.pen", fs_dir(app.file_path), title)
	if new_path == app.file_path {
		delete(new_path)
		return true
	}
	if fs_exists(new_path) {
		set_status("%s already exists", fs_base(new_path))
		delete(new_path)
		return false
	}
	if app.dirty do save_document(app.file_path)
	if err := fs_rename(app.file_path, new_path); err != nil {
		set_status("Rename failed: %v", err)
		delete(new_path)
		return false
	}
	recents_rename(app.file_path, new_path)
	delete(app.file_path)
	app.file_path = new_path
	delete(app.doc.path)
	app.doc.path = strings.clone(new_path)
	update_title()
	return true
}

// ---------------------------------------------------------------- recents

Recent :: struct {
	path: string,
	time: i64, // unix seconds of the last open or save
}

recents: [dynamic]Recent

// Where the app keeps its settings, recents, logs and samples: Application Support on a
// Mac, %APPDATA% on Windows, ~/.local/share on Linux.
support_dir :: proc() -> string {
	home, _ := fs_home(context.temp_allocator)
	when ODIN_OS == .Windows do return fmt.tprintf("%s/AppData/Roaming/Agentic Design", home)
	else when ODIN_OS == .Linux do return fmt.tprintf("%s/.local/share/agentic-design", home)
	else do return fmt.tprintf("%s/Library/Application Support/Agentic Design", home)
}

// Downloads that can be thrown away (updates, the cloud's files); allocated.
update_cache_dir :: proc() -> string {
	home, _ := fs_home(context.temp_allocator)
	when ODIN_OS == .Windows do return fmt.aprintf("%s/AppData/Local/Agentic Design/Cache/updates", home)
	else when ODIN_OS == .Linux do return fmt.aprintf("%s/.cache/agentic-design/updates", home)
	else do return fmt.aprintf("%s/Library/Caches/%s/updates", home, BUNDLE_ID)
}

recents_load :: proc() {
	// test windows show no recent files, so a scripted or fuzzed run cannot open (and
	// autosave) the user's documents from the dashboard
	if pf.quiet do return
	data, err := fs_read(fmt.tprintf("%s/recents.json", support_dir()), context.temp_allocator)
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
	_ = fs_mkdir_all(dir)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "[\n")
	for r, i in recents {
		if i > 0 do strings.write_string(&b, ",\n")
		strings.write_string(&b, `  {"path":`)
		engine.json_write_string(&b, r.path)
		fmt.sbprintf(&b, `,"time":%d}}`, r.time)
	}
	strings.write_string(&b, "\n]\n")
	_ = fs_write(fmt.tprintf("%s/recents.json", dir), strings.to_string(b))
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
	return fmt.tprintf("%s/thumbs/v2-%016x.png", support_dir(), h) // v2: cropped to stay readable
}

thumb_request :: proc(path: string) {
	for q in thumb_queue do if q == path do return
	append(&thumb_queue, strings.clone(path))
}

THUMB_GAP :: 250 * time.Millisecond
thumb_last: time.Time
thumb_waking: bool // a wake-up for the next preview is on its way

// A frame after THUMB_GAP (the window sleeps without input).
thumb_wake_later :: proc() {
	if thumb_waking do return
	thumb_waking = true
	thread.create_and_start(proc() {
			time.sleep(THUMB_GAP)
			thumb_waking = false
			platform_wake()
		}, self_cleanup = true)
}

thumb_empty: map[string]bool // nothing on the first page to draw
thumb_tried: map[string]i64 // path -> the file's modification time a preview was asked for

// A preview for a file shown on the dashboard: drawn when there is none or the file
// changed after it was drawn, once per version of the file.
thumb_ensure :: proc(path: string, modified: i64) {
	if t, ok := thumb_tried[path]; ok && t == modified do return
	if st, err := fs_stat(thumb_path(path), context.temp_allocator); err == nil && st.modification_time._nsec / 1_000_000_000 >= modified {
		thumb_tried[strings.clone(path)] = modified
		return
	}
	if path not_in thumb_tried do thumb_tried[strings.clone(path)] = modified
	else do thumb_tried[path] = modified
	thumb_request(path)
}

thumb_pending :: proc(path: string) -> bool {
	for q in thumb_queue do if q == path do return true
	return false
}

// Renders queued thumbnails from the saved files. Called between frames, outside
// nanovg frames, because it draws with the main context.
thumbs_render :: proc() {
	if len(thumb_queue) == 0 do return
	// The open document's preview after a save is drawn at once. Others (the dashboard's) one
	// at a time, THUMB_GAP apart, so a dashboard full of new files never holds the window up
	// or keeps the cores busy (decision 82).
	first := thumb_queue[0]
	if !(first == app.file_path && app.tab >= 0) && time.since(thumb_last) < THUMB_GAP {
		thumb_wake_later()
		return
	}
	paths := [1]string{first}
	ordered_remove(&thumb_queue, 0)
	defer delete(paths[0])
	defer thumb_last = time.now()
	if len(thumb_queue) > 0 do thumb_wake_later()
	_ = fs_mkdir_all(fmt.tprintf("%s/thumbs", support_dir()))
	for path in paths {
		if path == app.file_path && app.tab >= 0 && !app.dirty {
			// the open document was just saved: it is what the file holds, already parsed,
			// with its libraries and laid out. Reading the file and its libraries back cost
			// 30-100 ms on the main thread after every autosave.
			// Drawn as a fresh copy would be: page 0, without the libraries' layers.
			page0 := make(map[int]bool, 16, context.temp_allocator)
			multi := len(engine.doc_pages(&app.doc)) > 1
			for &n in app.doc.nodes do if n.parent == 0 && (n.imported || (multi && engine.page_of_top(&app.doc, n.id) != 0)) do page0[n.uid] = true
			shown := app.page_hidden
			app.page_hidden = page0
			thumb_write(path)
			app.page_hidden = shown
		} else {
			data, err := fs_read(path, context.temp_allocator)
			if err != nil do continue
			tmp: engine.Document
			if !engine.doc_load(&tmp, string(data)) do continue
			saved := app.doc
			saved_page := app.page
			app.doc = tmp
			app.doc.path = strings.clone(path) // (images and fonts next to that file, not the open one)
			engine.doc_load_imports(&app.doc, path)
			app.page = 0
			engine.layout_document(&app.doc)
			pages_sync()
			thumb_write(path)
			// the copy grew while it was shown (imports, layout, pages): free that one, not
			// the stale struct it was copied from
			tmp = app.doc
			app.doc = saved
			app.page = saved_page
			engine.doc_destroy(&tmp)
		}
		if img, has := thumbs[path]; has {
			if img > 0 do nvg.DeleteImage(app.vg, img)
			delete_key(&thumbs, path)
		}
	}
}

// Draws the shown page of app.doc, all of it, small, into the thumbnail file of `path`.
thumb_write :: proc(path: string) {
	r, ok := bounds_of(all_uids(true))
	if !ok {
		if path not_in thumb_empty do thumb_empty[strings.clone(path)] = true
		return
	}
	pad: f32 = 24
	r = {r[0] - pad, r[1] - pad, r[2] + pad * 2, r[3] + pad * 2}
	// all of the page when it is about the card's shape; a page much taller or wider shows
	// its top left, at least half the size that fills the card, rather than all of it tiny
	W, H :: f32(560), f32(360)
	fit := min(W / r[2], H / r[3], 2)
	scale := max(fit, min(max(W / r[2], H / r[3]), 2) * 0.5)
	if scale > fit {
		r[2] = min(r[2], W / scale)
		r[3] = min(r[3], H / scale)
	}
	if pixels, w, h, rok := render_region(r, scale, nil, {0.157, 0.157, 0.157, 1}); rok {
		if png, pok := engine.png_encode(pixels, w, h); pok do _ = fs_write(thumb_path(path), png)
	}
}

thumb_image :: proc(path: string) -> int {
	if img, has := thumbs[path]; has do return img
	file := thumb_path(path)
	img := 0
	if fs_exists(file) do img = nvg.CreateImagePath(app.vg, strings.clone_to_cstring(file, context.temp_allocator), {})
	thumbs[strings.clone(path)] = img
	return img
}
