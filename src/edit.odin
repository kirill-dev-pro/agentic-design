package agentic_design

import "engine"

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"

// Editing commands shared by shortcuts, the context menu and the inspector.

// Selected nodes without those whose ancestor is also selected, in paint order.
selection_roots :: proc() -> []int {
	roots := make([dynamic]int, context.temp_allocator)
	for uid in app.draw_order {
		if !is_selected(uid) do continue
		nested := false
		for other in app.sel do if other != uid && engine.is_descendant(&app.doc, uid, other) do nested = true
		if !nested do append(&roots, uid)
	}
	return roots[:]
}

// Wraps the selection in a group, a plain frame, or a flex frame.
Wrap :: enum {
	Group,
	Frame,
	Auto_Layout,
}

wrap_selection :: proc(kind: Wrap) {
	roots := selection_roots()
	if len(roots) == 0 do return
	r, ok := bounds_of(roots)
	if !ok do return
	push_undo()
	first, _ := engine.doc_find_uid(&app.doc, roots[0])
	parent := first.parent
	for uid in roots {
		if n, _ := engine.doc_find_uid(&app.doc, uid); n != nil && n.parent != parent do parent = 0
	}

	n: engine.Node
	n.parent = parent
	ox, oy := engine.parent_origin(&app.doc, parent)
	switch kind {
	case .Group:
		engine.node_set_raw(&n, "type", `"group"`)
		engine.node_set_raw(&n, "x", engine.num_text(r[0] - ox))
		engine.node_set_raw(&n, "y", engine.num_text(r[1] - oy))
	case .Frame:
		engine.node_set_raw(&n, "type", `"frame"`)
		engine.node_set_raw(&n, "layout", `"none"`)
		engine.node_set_raw(&n, "x", engine.num_text(r[0] - ox))
		engine.node_set_raw(&n, "y", engine.num_text(r[1] - oy))
		engine.node_set_raw(&n, "width", engine.num_text(r[2]))
		engine.node_set_raw(&n, "height", engine.num_text(r[3]))
	case .Auto_Layout:
		engine.node_set_raw(&n, "type", `"frame"`)
		horizontal := r[2] >= r[3]
		engine.node_set_raw(&n, "layout", `"horizontal"` if horizontal else `"vertical"`)
		engine.node_set_raw(&n, "x", engine.num_text(r[0] - ox))
		engine.node_set_raw(&n, "y", engine.num_text(r[1] - oy))
		// gap: average space between neighbours along the main axis
		if len(roots) > 1 {
			sorted := slice.clone(roots, context.temp_allocator)
			distribute_horizontal = horizontal
			slice.sort_by(sorted, proc(a, b: int) -> bool {
				na, _ := engine.doc_find_uid(&app.doc, a)
				nb, _ := engine.doc_find_uid(&app.doc, b)
				return na.x < nb.x if distribute_horizontal else na.y < nb.y
			})
			total: f32
			for i in 1 ..< len(sorted) {
				a, _ := engine.doc_find_uid(&app.doc, sorted[i - 1])
				b, _ := engine.doc_find_uid(&app.doc, sorted[i])
				total += (b.x - (a.x + a.w)) if horizontal else (b.y - (a.y + a.h))
			}
			engine.node_set_raw(&n, "gap", engine.num_text(max(total / f32(len(sorted) - 1), 0)))
			roots = sorted
		}
	}
	added := engine.doc_add(&app.doc, n)
	new_uid := added.uid
	engine.layout_document(&app.doc) // the container needs its page position before members move in
	for uid in roots {
		engine.doc_reparent(&app.doc, uid, new_uid)
		engine.doc_bring_to_front(&app.doc, uid)
	}
	clear(&app.sel)
	append(&app.sel, new_uid)
	mark_dirty()
}

// Replaces selected groups/frames by their children.
ungroup_selection :: proc() {
	roots := selection_roots()
	freed := make([dynamic]int, context.temp_allocator)
	changed := false
	for uid in roots {
		n, _ := engine.doc_find_uid(&app.doc, uid)
		if n == nil || !(n.kind == .Group || n.kind == .Frame) do continue
		if !changed {
			push_undo()
			changed = true
		}
		parent := n.parent
		children := make([dynamic]int, context.temp_allocator)
		for c in app.doc.nodes do if c.parent == uid do append(&children, c.uid)
		for c in children {
			engine.doc_reparent(&app.doc, c, parent)
			append(&freed, c)
		}
		// members keep the group's place in the stacking order
		_, gi := engine.doc_find_uid(&app.doc, uid)
		for c in children {
			_, gi = engine.doc_find_uid(&app.doc, uid)
			move_subtree(c, gi)
		}
		engine.doc_delete(&app.doc, uid)
	}
	if changed {
		clear(&app.sel)
		append(&app.sel, ..freed[:])
		mark_dirty()
	}
}

// Moves a node and its subtree so the node sits at `index` in the flat node list.
move_subtree :: proc(uid: int, index: int) {
	engine.doc_bump(&app.doc)
	moved := make([dynamic]engine.Node, context.temp_allocator)
	for i := 0; i < len(app.doc.nodes); {
		n := app.doc.nodes[i]
		if n.uid == uid || engine.is_descendant(&app.doc, n.uid, uid) {
			append(&moved, n)
			ordered_remove(&app.doc.nodes, i)
		} else {
			i += 1
		}
	}
	at := clamp(index, 0, len(app.doc.nodes))
	inject_at(&app.doc.nodes, at, ..moved[:])
}

// Arrange commands. Each orders a layer among the siblings inside its parent, as in Figma and
// pen.dev; a layer can look stuck under another one that is in a different parent (the hero
// "+" of an imported page sits alone in a wrapper frame under its neighbouring card).
Arrange :: enum {
	Front,
	Forward,
	Backward,
	Back,
}

// Whether the layer can still go towards the front (or back) inside its parent.
can_arrange :: proc(uid: int, front: bool) -> bool {
	n, _ := engine.doc_find_uid(&app.doc, uid)
	if n == nil do return false
	siblings := engine.children_of(&app.doc, n.parent)
	for s, i in siblings do if s == uid do return i < len(siblings) - 1 if front else i > 0
	return false
}

// What to tell the user when no layer of `uids` can go further towards the front (back)
// inside its parent, "" when one can. `agent`: the wording for an MCP reply.
arrange_hint :: proc(uids: []int, front: bool, agent := false) -> string {
	if len(uids) == 0 do return ""
	for uid in uids do if can_arrange(uid, front) do return ""
	n, _ := engine.doc_find_uid(&app.doc, uids[0])
	if n == nil do return ""
	where_ := "in front" if front else "at the back"
	p, _ := engine.doc_find_uid(&app.doc, n.parent)
	if p == nil do return fmt.tprintf("Already %s on the page", where_)
	if agent do return fmt.tprintf("Already %s inside '%s' (id %s): reorder that parent to move it further", where_, engine.node_label(p), p.id)
	return fmt.tprintf("Already %s inside '%s' — Shift+Enter selects it", where_, engine.node_label(p))
}

// An arrange command on the selection, one undo step; when no selected layer can move
// further inside its parent, the status line says so and nothing changes.
arrange_selection :: proc(op: Arrange) {
	if len(app.sel) == 0 do return
	if hint := arrange_hint(app.sel[:], op == .Front || op == .Forward); hint != "" {
		set_status("%s", hint)
		return
	}
	push_undo()
	switch op {
	case .Front: for uid in app.sel do engine.doc_bring_to_front(&app.doc, uid)
	case .Forward: for i := len(app.sel) - 1; i >= 0; i -= 1 do move_in_siblings(app.sel[i], 1)
	case .Backward: for uid in app.sel do move_in_siblings(uid, -1)
	case .Back: for uid in app.sel do send_to_back(uid)
	}
}

send_to_back :: proc(uid: int) {
	engine.doc_bump(&app.doc)
	moved := make([dynamic]engine.Node, context.temp_allocator)
	for i := 0; i < len(app.doc.nodes); {
		n := app.doc.nodes[i]
		if n.uid == uid || engine.is_descendant(&app.doc, n.uid, uid) {
			append(&moved, n)
			ordered_remove(&app.doc.nodes, i)
		} else {
			i += 1
		}
	}
	inject_at(&app.doc.nodes, 0, ..moved[:])
}

// ---------------------------------------------------------------- align

Align_Op :: enum {
	Left,
	Center_H,
	Right,
	Top,
	Center_V,
	Bottom,
	Distribute_H,
	Distribute_V,
}

align_selection :: proc(op: Align_Op) {
	roots := selection_roots()
	if len(roots) < 2 do return
	r, ok := bounds_of(roots)
	if !ok do return
	push_undo()
	switch op {
	case .Left, .Center_H, .Right, .Top, .Center_V, .Bottom:
		for uid in roots {
			n, _ := engine.doc_find_uid(&app.doc, uid)
			if n == nil || engine.in_flow(&app.doc, n) do continue
			dx, dy: f32
			#partial switch op {
			case .Left: dx = r[0] - n.x
			case .Center_H: dx = r[0] + r[2] / 2 - (n.x + n.w / 2)
			case .Right: dx = r[0] + r[2] - (n.x + n.w)
			case .Top: dy = r[1] - n.y
			case .Center_V: dy = r[1] + r[3] / 2 - (n.y + n.h / 2)
			case .Bottom: dy = r[1] + r[3] - (n.y + n.h)
			}
			engine.doc_move(&app.doc, uid, dx, dy)
		}
	case .Distribute_H, .Distribute_V:
		horizontal := op == .Distribute_H
		distribute_horizontal = horizontal
		sorted := slice.clone(roots, context.temp_allocator)
		slice.sort_by(sorted, proc(a, b: int) -> bool {
			na, _ := engine.doc_find_uid(&app.doc, a)
			nb, _ := engine.doc_find_uid(&app.doc, b)
			return na.x < nb.x if distribute_horizontal else na.y < nb.y
		})
		total: f32
		for uid in sorted {
			n, _ := engine.doc_find_uid(&app.doc, uid)
			total += n.w if horizontal else n.h
		}
		gap := ((r[2] if horizontal else r[3]) - total) / f32(len(sorted) - 1)
		pos := r[0] if horizontal else r[1]
		for uid in sorted {
			n, _ := engine.doc_find_uid(&app.doc, uid)
			if horizontal {
				engine.doc_move(&app.doc, uid, pos - n.x, 0)
				pos += n.w + gap
			} else {
				engine.doc_move(&app.doc, uid, 0, pos - n.y)
				pos += n.h + gap
			}
		}
	}
	mark_dirty()
}

distribute_horizontal: bool

// ---------------------------------------------------------------- clipboard

clipboard: string // JSON array of .pen nodes

copy_selection :: proc() {
	roots := selection_roots()
	if len(roots) == 0 do return
	b := strings.builder_make()
	strings.write_byte(&b, '[')
	for uid, i in roots {
		n, _ := engine.doc_find_uid(&app.doc, uid)
		if n == nil do continue
		if i > 0 do strings.write_byte(&b, ',')
		engine.write_node(&b, &app.doc, n, -1, false)
	}
	strings.write_byte(&b, ']')
	delete(clipboard)
	clipboard = strings.to_string(b)
	platform_clipboard_set(clipboard)
	set_status("Copied %d %s", len(roots), "layer" if len(roots) == 1 else "layers")
}

// Pastes nodes from the system clipboard when it holds .pen JSON, else from the
// internal one, into the selected frame (or beside the selection).
paste_clipboard :: proc() {
	text := clipboard
	st := strings.trim_space(platform_clipboard_get())
	if strings.has_prefix(st, "[") || strings.has_prefix(st, "{") do text = st
	if text == "" do return
	root, err := json.parse_string(text, .JSON5, false, context.temp_allocator)
	if err != nil do return
	items: []json.Value
	if arr, is_arr := root.(json.Array); is_arr do items = arr[:]
	else do items = {root}

	parent := 0
	if len(app.sel) == 1 {
		if n, _ := engine.doc_find_uid(&app.doc, app.sel[0]); n != nil {
			parent = n.uid if n.kind == .Frame else n.parent
			// a copy of the selected frame goes beside it, not inside
			for v in items {
				if obj, is_obj := v.(json.Object); is_obj && string(obj["id"].(json.String) or_else "") == n.id do parent = n.parent
			}
		}
	}
	push_undo()
	before := len(app.doc.nodes)
	pasted := make([dynamic]int, context.temp_allocator)
	for v in items {
		uid, perr := engine.node_from_json(&app.doc, v, parent)
		if perr != "" do continue
		append(&pasted, uid)
	}
	// fresh ids for anything that collided, and a small offset
	for i in before ..< len(app.doc.nodes) {
		n := &app.doc.nodes[i]
		if n.parent == parent {
			for p in pasted do if p == n.uid {
				engine.node_set_number(&app.doc, n, "x", n.pos.x + 16)
				engine.node_set_number(&app.doc, n, "y", n.pos.y + 16)
			}
		}
	}
	clear(&app.sel)
	append(&app.sel, ..pasted[:])
	mark_dirty()
	set_status("Pasted %d %s", len(pasted), "layer" if len(pasted) == 1 else "layers")
}

// ---------------------------------------------------------------- context menu

CONTEXT_ITEMS := [?]string{"Rename", "Duplicate", "Copy", "Paste", "Group", "Frame selection", "Add auto layout", "Ungroup", "Create component", "Create instance", "Outline text", "Bring to front", "Send to back", "Export PNG", "Delete"}

context_menu_open :: proc(at: [2]f32) {
	menu_open("context", {at.x, at.y, 0, 0}, CONTEXT_ITEMS[:])
}

context_menu_apply :: proc() {
	pick, ok := menu_take("context")
	if !ok do return
	switch CONTEXT_ITEMS[pick] {
	case "Rename":
		if len(app.sel) == 1 do start_rename(app.sel[0], false)
	case "Duplicate": duplicate_selection()
	case "Copy": copy_selection()
	case "Paste": paste_clipboard()
	case "Group": wrap_selection(.Group)
	case "Frame selection": wrap_selection(.Frame)
	case "Add auto layout": wrap_selection(.Auto_Layout)
	case "Ungroup": ungroup_selection()
	case "Create component":
		push_undo()
		for uid in app.sel {
			if n, _ := engine.doc_find_uid(&app.doc, uid); n != nil && (n.kind == .Frame || n.kind == .Group) do engine.node_set_bool(&app.doc, n, "reusable", true)
		}
	case "Create instance": create_instances()
	case "Outline text": outline_selected_text()
	case "Bring to front": arrange_selection(.Front)
	case "Send to back": arrange_selection(.Back)
	case "Export PNG": export_request()
	case "Delete":
		push_undo()
		engine.doc_delete_layers(&app.doc, app.sel[:])
		clear(&app.sel)
	}
}

// Puts the name of a node into an editable field: in the layer tree, or on the canvas title.
start_rename :: proc(uid: int, on_canvas: bool) {
	n, _ := engine.doc_find_uid(&app.doc, uid)
	if n == nil do return
	field_focus(uid, "name", n.name)
	ui.rename_canvas = on_canvas
	ui.rename_tree = !on_canvas
	ui.focus_rect = {}
}

// Adds a `ref` instance next to each selected component (making it one if needed).
create_instances :: proc() {
	roots := selection_roots()
	if len(roots) == 0 do return
	push_undo()
	made := make([dynamic]int, context.temp_allocator)
	for uid in roots {
		n, _ := engine.doc_find_uid(&app.doc, uid)
		if n == nil || !(n.kind == .Frame || n.kind == .Group) do continue
		if !n.reusable do engine.node_set_bool(&app.doc, n, "reusable", true)
		inst: engine.Node
		inst.parent = n.parent
		engine.node_set_raw(&inst, "type", `"ref"`)
		b := strings.builder_make(context.temp_allocator)
		engine.json_write_string(&b, n.id)
		engine.node_set_raw(&inst, "ref", strings.to_string(b))
		engine.node_set_raw(&inst, "x", engine.num_text(n.pos.x + n.w + 40))
		engine.node_set_raw(&inst, "y", engine.num_text(n.pos.y))
		added := engine.doc_add(&app.doc, inst)
		append(&made, added.uid)
	}
	clear(&app.sel)
	append(&app.sel, ..made[:])
	mark_dirty()
}

// Moves a node one place forward (+1) or backward (-1) among its siblings.
move_in_siblings :: proc(uid, delta: int) -> bool {
	n, _ := engine.doc_find_uid(&app.doc, uid)
	if n == nil do return false
	siblings := engine.children_of(&app.doc, n.parent)
	k := -1
	for s, i in siblings do if s == uid do k = i
	t := k + delta
	if k < 0 || t < 0 || t >= len(siblings) do return false
	target := siblings[t]
	engine.doc_bump(&app.doc)
	moved := make([dynamic]engine.Node, context.temp_allocator)
	for i := 0; i < len(app.doc.nodes); {
		m := app.doc.nodes[i]
		if m.uid == uid || engine.is_descendant(&app.doc, m.uid, uid) {
			append(&moved, m)
			ordered_remove(&app.doc.nodes, i)
		} else {
			i += 1
		}
	}
	at := 0
	for m, i in app.doc.nodes do if m.uid == target do at = i + (1 if delta > 0 else 0)
	inject_at(&app.doc.nodes, at, ..moved[:])
	engine.doc_index(&app.doc)
	return true
}

// Flips the selection horizontally or vertically.
flip_selection :: proc(horizontal: bool) {
	if len(app.sel) == 0 do return
	push_undo()
	for uid in app.sel {
		n, _ := engine.doc_find_uid(&app.doc, uid)
		if n == nil do continue
		transform_in_place(n, n.rotation, n.flip_x != horizontal, n.flip_y != !horizontal)
	}
}

// Sets a layer's rotation and flips so that it stays where it is on screen. The file
// turns and mirrors a layer around its top-left corner (pen.dev renders it so), so the
// corner moves to keep the centre in place. A layer placed by a flex layout only changes
// its transform.
transform_in_place :: proc(n: ^engine.Node, rotation: f32, flip_x, flip_y: bool) {
	// where the centre lands relative to the corner
	center_of :: proc(w, h, rotation: f32, flip_x, flip_y: bool) -> [2]f32 {
		v := [2]f32{w / 2 * (-1 if flip_x else 1), h / 2 * (-1 if flip_y else 1)}
		a := -rotation * math.PI / 180
		return {v.x * math.cos(a) - v.y * math.sin(a), v.x * math.sin(a) + v.y * math.cos(a)}
	}
	rotation := math.mod(rotation, 360)
	if rotation < 0 do rotation += 360
	placed := true
	if p, _ := engine.doc_find_uid(&app.doc, n.parent); p != nil && p.layout != .None && !n.abs_pos do placed = false
	d := center_of(n.w, n.h, n.rotation, n.flip_x, n.flip_y) - center_of(n.w, n.h, rotation, flip_x, flip_y)
	pos := n.pos + d
	set_flag :: proc(n: ^engine.Node, key: string, on: bool) {
		if on do engine.node_set_bool(&app.doc, n, key, true)
		else do engine.node_unset(&app.doc, n, key)
	}
	if rotation != n.rotation {
		if rotation == 0 do engine.node_unset(&app.doc, n, "rotation")
		else do engine.node_set_number(&app.doc, n, "rotation", math.round(rotation * 100) / 100)
	}
	if flip_x != n.flip_x do set_flag(n, "flipX", flip_x)
	if flip_y != n.flip_y do set_flag(n, "flipY", flip_y)
	if placed && (abs(d.x) > 1e-3 || abs(d.y) > 1e-3) {
		engine.node_set_number(&app.doc, n, "x", math.round(pos.x * 100) / 100)
		engine.node_set_number(&app.doc, n, "y", math.round(pos.y * 100) / 100)
	}
}

// Turns the selection into components, or components back into plain layers.
toggle_component_selection :: proc() {
	if len(app.sel) == 0 do return
	push_undo()
	for uid in app.sel {
		n, _ := engine.doc_find_uid(&app.doc, uid)
		if n == nil || n.kind == .Ref do continue
		if n.reusable do engine.node_unset(&app.doc, n, "reusable")
		else do engine.node_set_bool(&app.doc, n, "reusable", true)
	}
}

// Removes flex layout from the selected frames, keeping where the children are.
remove_flex_selection :: proc() {
	push_undo()
	for uid in app.sel {
		n, _ := engine.doc_find_uid(&app.doc, uid)
		if n == nil || n.kind != .Frame || n.layout == .None do continue
		for cu in engine.children_of(&app.doc, n.uid) {
			c, _ := engine.doc_find_uid(&app.doc, cu)
			if c == nil do continue
			engine.node_set_number(&app.doc, c, "x", math.round(c.x - n.x))
			engine.node_set_number(&app.doc, c, "y", math.round(c.y - n.y))
		}
		engine.node_set_number(&app.doc, n, "width", n.w)
		engine.node_set_number(&app.doc, n, "height", n.h)
		engine.node_set_string(&app.doc, n, "layout", "none")
	}
}
