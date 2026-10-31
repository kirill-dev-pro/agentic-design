package agentic_design

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// Pages inside a document. The .pen format has no pages, so they are kept in the
// header as `"pages": [{"name": ..., "nodes": [top-level ids]}]`; other tools keep
// or ignore the key. Top-level nodes listed under no page belong to the first one.

Page :: struct {
	name: string,
	ids:  [dynamic]string,
}

pages_free :: proc(pages: ^[dynamic]Page) {
	for &p in pages {
		delete(p.name)
		for id in p.ids do delete(id)
		delete(p.ids)
	}
	clear(pages)
}

// The document's pages (at least one), parsed from the header when it changed.
doc_pages :: proc(doc: ^Document) -> []Page {
	if doc.pages_version == doc.version && len(doc.pages) > 0 do return doc.pages[:]
	pages_free(&doc.pages)
	doc.pages_version = doc.version
	for p in doc.header do if p.key == "pages" {
		v, err := json.parse_string(p.raw, .JSON5, false, context.temp_allocator)
		if err != nil do break
		arr, ok := v.(json.Array)
		if !ok do break
		for item in arr {
			obj, is_obj := item.(json.Object)
			if !is_obj do continue
			page := Page{name = strings.clone(string(obj["name"].(json.String) or_else "Page"))}
			if ids, has := obj["nodes"].(json.Array); has {
				for id in ids do append(&page.ids, strings.clone(string(id.(json.String) or_else "")))
			}
			append(&doc.pages, page)
		}
	}
	if len(doc.pages) == 0 do append(&doc.pages, Page{name = strings.clone("Page 1")})
	return doc.pages[:]
}

// Writes the pages back into the header (dropping the key for a lone default page).
doc_pages_write :: proc(doc: ^Document) {
	pages := doc.pages[:]
	for i := 0; i < len(doc.header); {
		if doc.header[i].key == "pages" {
			delete(doc.header[i].key)
			delete(doc.header[i].raw)
			ordered_remove(&doc.header, i)
		} else {
			i += 1
		}
	}
	plain := len(pages) == 1 && pages[0].name == "Page 1" && len(pages[0].ids) == 0
	if !plain {
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '[')
		for p, i in pages {
			if i > 0 do strings.write_byte(&b, ',')
			strings.write_string(&b, `{"name":`)
			json_write_string(&b, p.name)
			strings.write_string(&b, `,"nodes":[`)
			for id, j in p.ids {
				if j > 0 do strings.write_byte(&b, ',')
				json_write_string(&b, id)
			}
			strings.write_string(&b, "]}")
		}
		strings.write_byte(&b, ']')
		append(&doc.header, Prop{strings.clone("pages"), strings.clone(strings.to_string(b))})
	}
	doc.version += 1
	doc.pages_version = doc.version // the cache is still valid
}

// Page index of a top-level node (unlisted nodes are on page 0).
page_of_top :: proc(doc: ^Document, id: string) -> int {
	for p, i in doc_pages(doc) {
		for pid in p.ids do if pid == id do return i
	}
	return 0
}

// Rebuilds the set of top-level nodes hidden by the current page; once per frame.
pages_sync :: proc() {
	clear(&app.page_hidden)
	// library layers are on no page
	for &n in app.doc.nodes do if n.parent == 0 && n.imported do app.page_hidden[n.uid] = true
	pages := doc_pages(&app.doc)
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
		idx := page_of_top(&app.doc, n.id)
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
	if added do doc_pages_write(&app.doc)
}

// True when the node (or its top-level ancestor) is on the current page.
on_page :: proc(uid: int) -> bool {
	top := uid
	for {
		n, _ := doc_find_uid(&app.doc, top)
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
	pages := doc_pages(&app.doc)
	push_undo()
	append(&app.doc.pages, Page{name = fmt.aprintf("Page %d", len(pages) + 1)})
	doc_pages_write(&app.doc)
	page_switch(len(app.doc.pages) - 1)
	mark_dirty()
}

page_rename :: proc(i: int, name: string) {
	pages := doc_pages(&app.doc)
	if i < 0 || i >= len(pages) || strings.trim_space(name) == "" do return
	push_undo()
	delete(app.doc.pages[i].name)
	app.doc.pages[i].name = strings.clone(strings.trim_space(name))
	doc_pages_write(&app.doc)
	mark_dirty()
}

// Deletes a page with every layer on it.
page_delete :: proc(i: int) {
	pages := doc_pages(&app.doc)
	if i < 0 || i >= len(pages) || len(pages) == 1 do return
	push_undo()
	doomed := make([dynamic]int, context.temp_allocator)
	for &n in app.doc.nodes {
		if n.parent == 0 && page_of_top(&app.doc, n.id) == i do append(&doomed, n.uid)
	}
	for uid in doomed do doc_delete(&app.doc, uid)
	p := app.doc.pages[i]
	delete(p.name)
	for id in p.ids do delete(id)
	delete(p.ids)
	ordered_remove(&app.doc.pages, i)
	doc_pages_write(&app.doc)
	page_switch(clamp(i, 0, len(app.doc.pages) - 1))
	mark_dirty()
}

// Removes ids of deleted nodes from the page lists (before saving).
pages_prune :: proc(doc: ^Document) {
	pages := doc_pages(doc)
	changed := false
	for &p in pages {
		for j := 0; j < len(p.ids); {
			if n, _ := doc_find(doc, p.ids[j]); n == nil || n.parent != 0 {
				delete(p.ids[j])
				ordered_remove(&p.ids, j)
				changed = true
			} else {
				j += 1
			}
		}
	}
	if changed do doc_pages_write(doc)
}
