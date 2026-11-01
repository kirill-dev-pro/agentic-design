package agentic_design

import "engine"

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"
import "vendor:glfw"
import nvg "nanovg"

// The Components tab of the sidebar, as in pen.dev's left panel: every component of the
// document with a preview, filtered by a search field. Click inserts an instance in the
// middle of the view, dragging drops it where the pointer is released (into the frame
// under it), double click goes to the component.

comp_drag: struct {
	uid:    int, // component being dragged from the panel, 0 = none
	moved:  bool,
	start:  [2]f32,
}

draw_components_panel :: proc(vg: ^nvg.Context, y: ^f32) {
	x: f32 = 16
	w := LEFT_W - 32
	field(vg, 0, "comp.search", "", {x, y^, w, 28}, ui.comp_search, placeholder = "Search components", icon = .Component)
	if field_is_focused(0, "comp.search") {
		delete(ui.comp_search)
		ui.comp_search = strings.clone(strings.to_string(ui.buf))
	}
	y^ += 38
	needle := strings.to_lower(strings.trim_space(ui.comp_search), context.temp_allocator)
	count := 0
	for &n in app.doc.nodes {
		if !n.reusable do continue
		name := engine.node_label(&n)
		if needle != "" && !strings.contains(strings.to_lower(name, context.temp_allocator), needle) do continue
		count += 1
		row := Rect{x - 6, y^, w + 12, 52}
		hover := hovered(row)
		if hover do fill_rect(vg, row, HOVER_BG, 8)
		// preview: the component scaled into a box
		pv := Rect{x, y^ + 6, 64, 40}
		fill_rect(vg, pv, {1, 1, 1, 0.04}, 6)
		if n.w > 0 && n.h > 0 {
			s := min((pv.w - 6) / n.w, (pv.h - 6) / n.h, 1)
			nvg.Save(vg)
			nvg.IntersectScissor(vg, pv.x, pv.y, pv.w, pv.h)
			nvg.Translate(vg, pv.x + (pv.w - n.w * s) / 2, pv.y + (pv.h - n.h * s) / 2)
			nvg.Scale(vg, s, s)
			nvg.Translate(vg, -n.x, -n.y)
			saved := engine.cull_rect
			engine.cull_rect = {}
			engine.draw_node_tree(vg, &n, 1, 0)
			engine.cull_rect = saved
			nvg.Restore(vg)
		}
		label(vg, pv.x + pv.w + 10, y^ + 19, name, TEXT_FG, 12)
		page := fmt.tprintf("Library · %s", engine.library_of(&n)) if n.imported else engine.doc_pages(&app.doc)[page_of_component(&n)].name
		label(vg, pv.x + pv.w + 10, y^ + 36, page, TEXT_DIM, 11)
		if hover && mouse_pressed(glfw.MOUSE_BUTTON_LEFT) {
			double := ui.tree_click_uid == n.uid && time.duration_seconds(time.since(ui.tree_click)) < 0.35
			ui.tree_click, ui.tree_click_uid = time.now(), n.uid
			if double {
				comp_drag.uid = 0
				if n.imported do set_status("%s comes from the library \"%s\"; edit it in that file", name, engine.library_of(&n))
				else do focus_node(n.uid)
			} else {
				comp_drag = {uid = n.uid, start = app.mouse}
			}
		}
		y^ += 56
	}
	if count == 0 {
		label(vg, x, y^ + 10, "No components" if needle == "" else "Nothing matches", TEXT_DIM)
		y^ += 28
		if needle == "" {
			label(vg, x, y^ + 6, "Select a layer and press ⌘⌥K", TEXT_DIM, 11)
			y^ += 22
		}
	}
	draw_libraries(vg, x, w, y)
}

// Imported libraries: alias and file, remove, and "+" to import a .pen file.
draw_libraries :: proc(vg: ^nvg.Context, x, w: f32, y: ^f32) {
	y^ += 12
	fill_rect(vg, {x, y^, w, 1}, PANEL_LINE)
	y^ += 10
	label(vg, x, y^ + 12, "Libraries", TEXT_FG, 13)
	if lucide_button(vg, {x + w - 26, y^, 24, 24}, "plus", false, "Import a library (.lib.pen or any .pen file)") do import_library_dialog()
	y^ += 32
	imports := engine.doc_imports(&app.doc)
	if len(imports) == 0 {
		label(vg, x, y^ + 8, "No imported libraries", TEXT_DIM, 12)
		y^ += 24
		return
	}
	for alias, rel in imports {
		label(vg, x, y^ + 10, alias, TEXT_FG, 12)
		label(vg, x, y^ + 27, string(rel.(json.String) or_else ""), TEXT_DIM, 11)
		if lucide_button(vg, {x + w - 26, y^ + 6, 24, 24}, "minus", false, "Remove library") {
			library_remove(alias)
			return
		}
		y^ += 40
	}
}

// Page of a component (its top-level ancestor's page).
page_of_component :: proc(n: ^engine.Node) -> int {
	top := n
	for top.parent != 0 {
		p, _ := engine.doc_find_uid(&app.doc, top.parent)
		if p == nil do break
		top = p
	}
	return engine.page_of_top(&app.doc, top.id)
}

// Selects a node, switching to its page and zooming to it.
focus_node :: proc(uid: int) {
	n, _ := engine.doc_find_uid(&app.doc, uid)
	if n == nil do return
	if pg := page_of_component(n); pg != app.page do page_switch(pg)
	clear(&app.sel)
	append(&app.sel, uid)
	zoom_to_rect({n.x - 40, n.y - 40, n.w + 80, n.h + 80})
}

// Finishes a drag from the components panel: a click inserts in the middle of the view,
// a drop on the canvas inserts at the pointer.
components_drag_update :: proc() {
	if comp_drag.uid == 0 do return
	d := app.mouse - comp_drag.start
	if d.x * d.x + d.y * d.y > 16 do comp_drag.moved = true
	if mouse_down(glfw.MOUSE_BUTTON_LEFT) do return
	uid, moved := comp_drag.uid, comp_drag.moved
	comp_drag = {}
	comp, _ := engine.doc_find_uid(&app.doc, uid)
	if comp == nil do return
	if moved && !in_rect(app.canvas, app.mouse) do return
	at := to_page(app.mouse) if moved else to_page({app.canvas.x + app.canvas.w / 2, app.canvas.y + app.canvas.h / 2})
	insert_instance(comp, at - {comp.w / 2, comp.h / 2}, at if moved else {})
}

// Adds an instance of `comp` at page position `at` (top-left), inside the frame under
// `drop` when there is one.
insert_instance :: proc(comp: ^engine.Node, at: [2]f32, drop: [2]f32) {
	push_undo()
	parent := 0
	if drop != {} {
		if hit := hit_test(drop); hit != 0 {
			for p := hit; p != 0; {
				pn, _ := engine.doc_find_uid(&app.doc, p)
				if pn == nil do break
				if pn.kind == .Frame && !pn.reusable && pn.uid != comp.uid && !engine.is_descendant(&app.doc, pn.uid, comp.uid) {
					parent = pn.uid
					break
				}
				p = pn.parent
			}
		}
	}
	inst: engine.Node
	inst.parent = parent
	engine.node_set_raw(&inst, "type", `"ref"`)
	b := strings.builder_make(context.temp_allocator)
	engine.json_write_string(&b, comp.id)
	engine.node_set_raw(&inst, "ref", strings.to_string(b))
	ox, oy := engine.parent_origin(&app.doc, parent)
	engine.node_set_raw(&inst, "x", engine.num_text(at.x - ox))
	engine.node_set_raw(&inst, "y", engine.num_text(at.y - oy))
	added := engine.doc_add(&app.doc, inst)
	clear(&app.sel)
	append(&app.sel, added.uid)
	mark_dirty()
	set_status("Added %s", engine.node_label(comp))
}

draw_component_drag_ghost :: proc(vg: ^nvg.Context) {
	if comp_drag.uid == 0 || !comp_drag.moved do return
	comp, _ := engine.doc_find_uid(&app.doc, comp_drag.uid)
	if comp == nil do return
	r := Rect{app.mouse.x + 12, app.mouse.y + 12, 0, 26}
	name := engine.node_label(comp)
	r.w = text_width(vg, name, 12) + 20
	fill_rect(vg, r, {0.55, 0.42, 1.0, 0.95}, 6)
	label(vg, r.x + 10, r.y + 13, fmt.tprintf("%s", name), {1, 1, 1, 1}, 12)
}
