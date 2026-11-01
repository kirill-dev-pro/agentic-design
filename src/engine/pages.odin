package engine

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
