#+build !js
package agentic_design

import "engine"

import "core:fmt"
import "core:strings"
import "core:time"

// Agents work on documents the window does not show (decision 85). A request that names
// another document ("file") is run on it in place: the document of another tab, or one read
// from disk and kept here for a while, is swapped into `app` for that request alone, saved
// if it changed, and swapped back. The user's view, selection and undo stay as they were;
// nothing is drawn while another document is in `app` (requests run between frames).

Background_Doc :: struct {
	tab:       Tab,
	last_used: time.Time,
}

background_docs: [dynamic]^Background_Doc
BACKGROUND_KEEP :: 3 * time.Minute

// Exchanges the shown document's live state with a tab's.
tab_swap :: proc(t: ^Tab) {
	app.doc, t.doc = t.doc, app.doc
	app.file_path, t.path = t.path, app.file_path
	app.dirty, t.dirty = t.dirty, app.dirty
	app.last_change, t.last_change = t.last_change, app.last_change
	app.cam, t.cam = t.cam, app.cam
	app.zoom, t.zoom = t.zoom, app.zoom
	app.sel, t.sel = t.sel, app.sel
	app.editing, t.editing = t.editing, app.editing
	app.undo_stack, t.undo_stack = t.undo_stack, app.undo_stack
	app.redo_stack, t.redo_stack = t.redo_stack, app.redo_stack
	app.page, t.page = t.page, app.page
}

// The tab holding `path` when the window does not show it: another tab, or a background
// document (read from disk now if needed). "" or an error.
background_find :: proc(path: string) -> (t: ^Tab, err: string) {
	abs := engine.absolute_path(path)
	for i in 0 ..< len(app.tabs) {
		if i != app.tab && same_file(app.tabs[i].path, abs) do return &app.tabs[i], ""
	}
	for bd in background_docs {
		if same_file(bd.tab.path, abs) {
			bd.last_used = time.now()
			return &bd.tab, ""
		}
	}
	data, rerr := fs_read(abs, context.temp_allocator)
	if rerr != nil do return nil, fmt.tprintf("no readable file at %s; call open with \"create\": true to start a new document there", abs)
	bd := new(Background_Doc)
	bd.tab = Tab{zoom = 1, cam = {-80, -60}}
	bd.last_used = time.now()
	engine.fonts_add_document_dir(abs)
	if !engine.doc_load(&bd.tab.doc, string(data)) {
		free(bd)
		return nil, fmt.tprintf("%s is not a readable .pen document", abs)
	}
	bd.tab.doc.path = strings.clone(abs)
	bd.tab.path = strings.clone(abs)
	// imports and themes resolve against the document while it is in `app`
	tab_swap(&bd.tab)
	engine.doc_load_imports(&app.doc, abs)
	engine.theme_defaults(&app.doc)
	engine.doc_retheme(&app.doc)
	tab_swap(&bd.tab)
	append(&background_docs, bd)
	return &bd.tab, ""
}

// Puts the document of `t` in `app` for one request.
background_enter :: proc(t: ^Tab) {
	if app.editing != 0 do finish_text_editing()
	tab_swap(t)
	engine.layout_invalidate()
	engine.layout_document(&app.doc)
	pages_sync()
	build_draw_order()
}

// Saves what the request changed and puts the shown document back.
background_leave :: proc(t: ^Tab) {
	if app.dirty do save_document(app.file_path)
	tab_swap(t)
	engine.layout_invalidate()
	engine.layout_document(&app.doc)
	app.needs_layout = true
	pages_sync()
	build_draw_order()
	update_title()
}

// A background document the user opens becomes a tab, with its undo history.
background_take :: proc(path: string) -> (Tab, bool) {
	for bd, i in background_docs {
		if same_file(bd.tab.path, path) {
			t := bd.tab
			ordered_remove(&background_docs, i)
			free(bd)
			return t, true
		}
	}
	return {}, false
}

// Forgets background documents no agent used for a while (they were saved after each change).
background_tick :: proc() {
	for i := len(background_docs) - 1; i >= 0; i -= 1 {
		bd := background_docs[i]
		if time.since(bd.last_used) < BACKGROUND_KEEP do continue
		t := &bd.tab
		engine.doc_destroy(&t.doc)
		delete(t.path)
		delete(t.sel)
		for s in t.undo_stack do engine.free_snapshot(s)
		delete(t.undo_stack)
		for s in t.redo_stack do engine.free_snapshot(s)
		delete(t.redo_stack)
		ordered_remove(&background_docs, i)
		free(bd)
	}
}
