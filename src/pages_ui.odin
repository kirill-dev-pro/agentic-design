package agentic_design

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import NS "core:sys/darwin/Foundation"
import "vendor:glfw"
import nvg "nanovg"
import "engine"

// Rebuilds the set of top-level nodes hidden by the current page; once per frame.
pages_sync :: proc() {
	clear(&app.page_hidden)
	// library layers are on no page
	for &n in app.doc.nodes do if n.parent == 0 && n.imported do app.page_hidden[n.uid] = true
	pages := engine.doc_pages(&app.doc)
	if app.page >= len(pages) do app.page = len(pages) - 1
	if app.page < 0 do app.page = 0
	if len(pages) == 1 {
		for &n in app.doc.nodes do if n.parent == 0 do n.page_seen = true
		return
	}
	// new top-level nodes drawn while another page is shown belong to it
	added := false
	for &n in app.doc.nodes {
		if n.parent != 0 || n.imported do continue
		idx := engine.page_of_top(&app.doc, n.id)
		if idx == 0 && app.page != 0 {
			listed := false
			for pid in pages[0].ids do if pid == n.id do listed = true
			if !listed && !n.page_seen {
				append(&app.doc.pages[app.page].ids, strings.clone(n.id))
				added = true
				idx = app.page
			}
		}
		n.page_seen = true
		if idx != app.page do app.page_hidden[n.uid] = true
	}
	if added do engine.doc_pages_write(&app.doc)
}

// True when the node (or its top-level ancestor) is on the current page.
on_page :: proc(uid: int) -> bool {
	top := uid
	for {
		n, _ := engine.doc_find_uid(&app.doc, top)
		if n == nil do return true
		if n.parent == 0 do break
		top = n.parent
	}
	_, hidden := app.page_hidden[top]
	return !hidden
}

page_switch :: proc(i: int) {
	if ui.focus != "" do field_commit()
	if app.editing != 0 do finish_text_editing()
	app.page = i
	clear(&app.sel)
	pages_sync()
	app.needs_layout = true
}

page_add :: proc() {
	pages := engine.doc_pages(&app.doc)
	push_undo()
	append(&app.doc.pages, engine.Page{name = fmt.aprintf("Page %d", len(pages) + 1)})
	engine.doc_pages_write(&app.doc)
	page_switch(len(app.doc.pages) - 1)
	mark_dirty()
}

page_rename :: proc(i: int, name: string) {
	pages := engine.doc_pages(&app.doc)
	if i < 0 || i >= len(pages) || strings.trim_space(name) == "" do return
	push_undo()
	delete(app.doc.pages[i].name)
	app.doc.pages[i].name = strings.clone(strings.trim_space(name))
	engine.doc_pages_write(&app.doc)
	mark_dirty()
}

// Deletes a page with every layer on it.
page_delete :: proc(i: int) {
	pages := engine.doc_pages(&app.doc)
	if i < 0 || i >= len(pages) || len(pages) == 1 do return
	push_undo()
	doomed := make([dynamic]int, context.temp_allocator)
	for &n in app.doc.nodes {
		if n.parent == 0 && engine.page_of_top(&app.doc, n.id) == i do append(&doomed, n.uid)
	}
	for uid in doomed do engine.doc_delete(&app.doc, uid)
	p := app.doc.pages[i]
	delete(p.name)
	for id in p.ids do delete(id)
	delete(p.ids)
	ordered_remove(&app.doc.pages, i)
	engine.doc_pages_write(&app.doc)
	page_switch(clamp(i, 0, len(app.doc.pages) - 1))
	mark_dirty()
}
