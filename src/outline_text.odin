package agentic_design

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "engine"

// Outline text: a text layer becomes a path with its glyph outlines, so that it can carry a
// stroke in a form pen.dev keeps (pen.dev drops `stroke` on text). The path has the text's
// box, position and paint; its geometry is what the canvas draws for the text, written by
// the drawing code itself (engine.text_to_geometry), so the two fill the same pixels.

// Properties of a text layer that a path has too; the rest (content, font, text layout) go.
OUTLINE_KEEP := []string {
	"type", "id", "name", "context", "reusable", "theme", "enabled", "opacity", "flipX", "flipY",
	"layoutPosition", "metadata", "rotation", "x", "y", "fill", "stroke", "strokeWidth",
	"strokeLinecap", "strokeLinejoin", "strokeAlignment", "effect", "strokeDashPattern",
}

// Replaces text layer `uid` with a path; false (and nothing changed) when it is not a text
// layer of the document, or a copy inside an instance.
outline_text_node :: proc(uid: int) -> bool {
	doc := &app.doc
	n, _ := engine.doc_find_uid(doc, uid)
	if n == nil || n.ghost || n.kind != .Text do return false
	geometry, embolden := engine.text_to_geometry(engine.renderer, n)
	w, h := n.w, n.h
	had_fill := engine.prop_index(n, "fill") >= 0
	had_stroke := engine.prop_index(n, "stroke") >= 0
	fill_raw := n.props[engine.prop_index(n, "fill")].raw if had_fill else `"#000000"` // text without a fill draws black
	stroke_w := n.font_size / 24
	kept := make([dynamic]engine.Prop, 0, len(n.props))
	for p in n.props {
		keep := false
		for k in OUTLINE_KEEP do if p.key == k {keep = true; break}
		if keep {
			append(&kept, p)
		} else {
			delete(p.key)
			delete(p.raw)
		}
	}
	delete(n.props)
	n.props = kept
	// the laid-out box in full, so that the path takes exactly the room the text took
	num :: proc(v: f32) -> string {return fmt.tprintf("%v", v)}
	engine.node_set_raw(n, "type", `"path"`)
	if !had_fill do engine.node_set_raw(n, "fill", fill_raw)
	engine.node_set_raw(n, "width", num(w))
	engine.node_set_raw(n, "height", num(h))
	engine.node_set_raw(n, "viewBox", fmt.tprintf("[0,0,%s,%s]", num(w), num(h)))
	b := strings.builder_make(context.temp_allocator)
	engine.json_write_string(&b, geometry)
	engine.node_set_raw(n, "geometry", strings.to_string(b))
	if embolden && !had_stroke {
		// a bold the family lacks is drawn by thickening a lighter face: keep that look
		engine.node_set_raw(n, "stroke", fill_raw)
		engine.node_set_raw(n, "strokeWidth", num(stroke_w))
		engine.node_set_raw(n, "strokeLinejoin", `"miter"`)
	}
	engine.node_refresh(doc, n)
	return true
}

// `outline_text` {ids}: each text layer among ids becomes a path, in one undo step.
api_outline_text :: proc(b: ^strings.Builder, params: json.Object) -> string {
	uids := uids_param(params, "ids")
	if len(uids) == 0 do return "ids is required (text layers of the document)"
	texts := make([dynamic]int, context.temp_allocator)
	for uid in uids {
		n, _ := engine.doc_find_uid(&app.doc, uid)
		if n == nil do continue
		if n.ghost do return fmt.tprintf("'%s' is inside an instance: outline it in the component, or detach the instance", n.id)
		if n.kind == .Text do append(&texts, uid)
	}
	if len(texts) == 0 do return "none of ids is a text layer"
	push_undo()
	strings.write_string(b, `{"outlined":[`)
	for uid, i in texts {
		outline_text_node(uid)
		n, _ := engine.doc_find_uid(&app.doc, uid)
		if i > 0 do strings.write_byte(b, ',')
		engine.json_write_string(b, n.id)
	}
	strings.write_string(b, "]}")
	return ""
}

// The context menu's command: the selected text layers.
outline_selected_text :: proc() {
	texts := make([dynamic]int, context.temp_allocator)
	for uid in app.sel {
		if n, _ := engine.doc_find_uid(&app.doc, uid); n != nil && !n.ghost && n.kind == .Text do append(&texts, uid)
	}
	if len(texts) == 0 do return
	push_undo()
	for uid in texts do outline_text_node(uid)
	set_status("Outlined %d text layer%s", len(texts), "" if len(texts) == 1 else "s")
}
