package agentic_design

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "engine"

// Vector PDF from the MCP (D59): `screenshot` with format "pdf" writes one layer (or the
// shown page's frames) as vector PDF, and `export_pages` writes chosen frames, a document
// page or all of them into one PDF, a PDF page per top-level frame.

// The top-level layers of document page `page` (all pages when -1), in page and layer
// order. Layers listed under no page are on the first one; connectors and labels are not
// pages of their own.
page_frames :: proc(page: int) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	for i in 0 ..< max(len(engine.doc_pages(&app.doc)), 1) {
		if page >= 0 && i != page do continue
		for &n in app.doc.nodes {
			if n.parent != 0 || !n.enabled || n.imported || n.flow == .Connector || n.flow == .Label do continue
			if engine.page_of_top(&app.doc, n.id) == i do append(&out, n.uid)
		}
	}
	return out[:]
}

write_pdf :: proc(b: ^strings.Builder, uids: []int, path: string) -> string {
	if len(uids) == 0 do return "nothing to export"
	data, ok := engine.export_pdf(engine.renderer, &app.doc, uids)
	if !ok do return "could not draw the PDF"
	defer delete(data)
	if err := os.write_entire_file(path, data); err != nil do return fmt.tprintf("cannot write %s: %v", path, err)
	fmt.sbprintf(b, `{{"path":`)
	engine.json_write_string(b, path)
	fmt.sbprintf(b, `,"pages":%d,"bytes":%d}}`, len(uids), len(data))
	return ""
}

// `export_pages` {path, ids?: [top-level frame ids], page?: name or index, format?: "pdf"}
api_export_pages :: proc(b: ^strings.Builder, params: json.Object) -> string {
	path := string(params["path"].(json.String) or_else "")
	if path == "" do return "path is required (the .pdf file to write)"
	if f, has := params["format"].(json.String); has && f != "pdf" do return "format: only pdf (one PDF page per frame); use screenshot for PNG"
	uids: []int
	if _, has := params["ids"]; has {
		uids = uids_param(params, "ids")
		if len(uids) == 0 do return "ids names no layer"
	} else if pv, has := params["page"]; has {
		page := -1
		#partial switch v in pv {
		case json.Float: page = int(v)
		case json.Integer: page = int(v)
		case json.String:
			for p, i in engine.doc_pages(&app.doc) do if p.name == string(v) do page = i
		}
		if page < 0 || page >= len(engine.doc_pages(&app.doc)) do return "page must be a page's name or index"
		uids = page_frames(page)
	} else {
		uids = page_frames(-1)
	}
	return write_pdf(b, uids, path)
}
