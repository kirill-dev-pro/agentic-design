package agentic_design

import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import "vendor:glfw"

in_rect :: proc(r: Rect, p: [2]f32) -> bool {
	return p.x >= r.x && p.y >= r.y && p.x < r.x + r.w && p.y < r.y + r.h
}

handle_input :: proc() {
	m := app.mouse
	over_canvas := in_rect(app.canvas, m) && app.tab >= 0
	page := to_page(m)

	// A click anywhere outside a focused field commits it first.
	if mouse_pressed(glfw.MOUSE_BUTTON_LEFT) && ui.focus != "" && !in_rect(ui.focus_rect, m) do field_commit()
	if ui_modal() do return // an open menu, picker or dialog owns the pointer and keys
	if app.tab < 0 {
		if mod_cmd() && key_pressed(glfw.KEY_N) do new_document()
		update_cursor(false)
		return
	}

	// trackpad and wheel: pinch zooms, two-finger scroll pans (or zooms with cmd/ctrl)
	if over_canvas {
		if pf.magnify != 0 do zoom_at(m, clamp(1 + pf.magnify, 0.5, 2))
		if pf.scroll != {0, 0} {
			if mod_cmd() do zoom_at(m, math.pow(1.01, pf.scroll.y))
			else do app.cam -= pf.scroll / app.zoom
		}
		if pf.wheel != {0, 0} {
			if mod_cmd() do zoom_at(m, math.pow(1.1, pf.wheel.y))
			else do app.cam -= pf.wheel * 30 / app.zoom
		}
		if pf.smart do smart_zoom(m)
	}

	if app.editing != 0 do handle_text_editing()
	else if ui.focus == "" do handle_shortcuts()

	app.hover = 0
	if over_canvas && app.drag.kind == .None {
		app.hover = click_target(hit_test(page), mod_cmd())
		if frame_body(app.hover, page) do app.hover = 0
	}

	context_menu_apply()
	if over_canvas && mouse_pressed(glfw.MOUSE_BUTTON_RIGHT) && app.drag.kind == .None {
		if hit := click_target(hit_test(page), mod_cmd()); hit != 0 && !is_selected(hit) && !frame_body(hit, page) {
			clear(&app.sel)
			append(&app.sel, hit)
		}
		context_menu_open(m)
		return
	}

	// the pen tool and path editing take the pointer first
	if app.tool == .Pen && !pen.drawing && over_canvas && mouse_pressed(glfw.MOUSE_BUTTON_LEFT) && !key_down(glfw.KEY_SPACE) do pen_start_drawing()
	if pen_active() && (over_canvas || pen.drag != .None) && !key_down(glfw.KEY_SPACE) && !mouse_pressed(glfw.MOUSE_BUTTON_MIDDLE) {
		if pen_input(page) {
			update_cursor(over_canvas)
			return
		}
	}

	// mouse down
	if over_canvas && (mouse_pressed(glfw.MOUSE_BUTTON_LEFT) || mouse_pressed(glfw.MOUSE_BUTTON_MIDDLE)) {
		if app.editing != 0 {
			n, _ := doc_find_uid(&app.doc, app.editing)
			if n == nil || !point_in_node(n, page) do finish_text_editing()
		}
		app.drag = Drag {
			start_page  = page,
			start_mouse = m,
			last_page   = page,
		}
		if mouse_pressed(glfw.MOUSE_BUTTON_MIDDLE) || key_down(glfw.KEY_SPACE) || app.tool == .Hand {
			app.drag.kind = .Pan
		} else if zoom_tool_held() {
			app.drag.kind = .Zoom
		} else if app.editing == 0 {
			mouse_down_tool(page)
		}
	}

	// dragging
	if app.drag.kind != .None {
		if mouse_down(glfw.MOUSE_BUTTON_LEFT) || mouse_down(glfw.MOUSE_BUTTON_MIDDLE) {
			drag_update(page)
		} else {
			drag_end(page)
			app.drag = {}
		}
	}

	update_cursor(over_canvas)
}

// Two-finger double tap: zoom in on what is under the pointer, or back out to fit all.
smart_zoom :: proc(m: [2]f32) {
	if app.zoom < 0.95 {
		if hit := hit_test(to_page(m)); hit != 0 {
			if n, _ := doc_find_uid(&app.doc, hit); n != nil {
				top := n
				for top.parent != 0 {
					p, _ := doc_find_uid(&app.doc, top.parent)
					if p == nil do break
					top = p
				}
				zoom_to_rect({top.x, top.y, top.w, top.h})
				return
			}
		}
		app.zoom = 1
		return
	}
	if r, ok := bounds_of(all_uids(true)); ok do zoom_to_rect(r)
}

update_cursor :: proc(over_canvas: bool) {
	cursor := Cursor.Default
	if over_canvas {
		switch {
		case app.drag.kind == .Pan || key_down(glfw.KEY_SPACE) || app.tool == .Hand: cursor = .Hand
		case app.drag.kind == .Zoom || zoom_tool_held(): cursor = .Crosshair
		case app.tool == .Text || app.editing != 0: cursor = .IBeam
		case app.tool != .Select: cursor = .Crosshair
		case handle_under_mouse() >= 0 || grad_handle_under_mouse() != .None: cursor = .Hand
		}
	} else if ui.cursor_hint != .Default {
		cursor = ui.cursor_hint
	} else if ui.scrub != "" {
		cursor = .Resize_H
	}
	platform_set_cursor(cursor)
}

alt_down :: proc() -> bool {
	return key_down(glfw.KEY_LEFT_ALT) || key_down(glfw.KEY_RIGHT_ALT)
}

// Holding Z turns the pointer into a zoom tool (pen.dev): click zooms in, ⌥-click out,
// dragging zooms to the region.
zoom_tool_held :: proc() -> bool {
	return key_down(glfw.KEY_Z) && !mod_cmd() && app.editing == 0 && ui.focus == ""
}

handle_under_mouse :: proc() -> int {
	if len(app.sel) != 1 || app.editing != 0 do return -1
	n, _ := doc_find_uid(&app.doc, app.sel[0])
	if n == nil || !resizable(n) do return -1
	for h in 0 ..< 8 {
		p := handle_pos(n, h)
		if abs(app.mouse.x - p.x) <= 6 && abs(app.mouse.y - p.y) <= 6 do return h
	}
	return -1
}

// What a click on `hit` (the deepest layer under the pointer) selects, as in pen.dev and
// Figma: a selected layer under the pointer stays selected (so a selected container drags
// by its content); next to a selected layer, the layer at that level; otherwise the child
// of a top-level frame, or the top-level layer itself. `deep` (⌘) takes the deepest.
click_target :: proc(hit: int, deep: bool) -> int {
	if hit == 0 || deep do return hit
	chain := make([dynamic]int, context.temp_allocator)
	for cur := hit; cur != 0 && len(chain) < MAX_DEPTH; {
		append(&chain, cur)
		n, _ := doc_find_uid(&app.doc, cur)
		if n == nil do break
		cur = n.parent
	}
	for uid in chain do if is_selected(uid) do return uid
	for s in app.sel {
		sn, _ := doc_find_uid(&app.doc, s)
		if sn == nil || sn.parent == 0 do continue
		for uid in chain {
			if n, _ := doc_find_uid(&app.doc, uid); n != nil && n.parent == sn.parent do return uid
		}
	}
	if len(chain) >= 2 {
		if top, _ := doc_find_uid(&app.doc, chain[len(chain) - 1]); top != nil && top.kind == .Frame do return chain[len(chain) - 2]
	}
	return chain[len(chain) - 1]
}

// The empty body of a top-level frame that has layers in it: pressing there starts a
// marquee over its layers instead of picking the frame up (its title moves it).
frame_body :: proc(uid: int, page: [2]f32) -> bool {
	n, _ := doc_find_uid(&app.doc, uid)
	if n == nil || n.parent != 0 || n.kind != .Frame || is_selected(uid) || page.y < n.y do return false
	return len(children_of(&app.doc, uid)) > 0
}

// The child of `ancestor` on the way down to `uid`, or 0.
child_toward :: proc(uid, ancestor: int) -> int {
	for cur := uid; cur != 0; {
		n, _ := doc_find_uid(&app.doc, cur)
		if n == nil do return 0
		if n.parent == ancestor do return cur
		cur = n.parent
	}
	return 0
}

// Top-most node under the point. Children win over their container.
hit_test :: proc(page: [2]f32) -> int {
	// frame titles
	for &n in app.doc.nodes {
		if n.parent != 0 || !n.enabled || !(n.kind == .Frame || n.kind == .Group) || app.page_hidden[n.uid] do continue
		a := to_screen({n.x, n.y})
		if app.mouse.x >= a.x && app.mouse.x <= a.x + 160 && app.mouse.y >= a.y - 18 && app.mouse.y < a.y do return n.uid
	}
	#reverse for uid in app.draw_order {
		n, _ := doc_find_uid(&app.doc, uid)
		if n != nil && point_in_node(n, page) do return uid
	}
	return 0
}

point_in_node :: proc(n: ^Node, p_in: [2]f32) -> bool {
	slop := 3 / app.zoom
	p := p_in
	// a turned or mirrored node: test the point in the node's own frame
	if m, tr := node_transform(n); tr do p = xform_point(xform_inverse(m), p)
	if p.x < n.x - slop || p.y < n.y - slop || p.x > n.x + n.w + slop || p.y > n.y + n.h + slop do return false
	if n.kind == .Ellipse {
		c := [2]f32{n.x + n.w / 2, n.y + n.h / 2}
		d := (p - c) / [2]f32{n.w / 2 + slop, n.h / 2 + slop}
		return d.x * d.x + d.y * d.y <= 1
	}
	return true
}

// Top-most frame under the point that could take a dropped node.
frame_at :: proc(page: [2]f32, exclude: int) -> int {
	#reverse for uid in app.draw_order {
		n, _ := doc_find_uid(&app.doc, uid)
		if n == nil || n.kind != .Frame || uid == exclude || (exclude != 0 && is_descendant(&app.doc, uid, exclude)) do continue
		if page.x >= n.x && page.y >= n.y && page.x <= n.x + n.w && page.y <= n.y + n.h do return uid
	}
	return 0
}

// A new node with the properties the editor tools author.
new_node :: proc(kind: Node_Kind, parent: int) -> Node {
	n: Node
	n.parent = parent
	node_set_raw(&n, "type", fmt.tprintf(`"%s"`, KIND_NAMES[kind]))
	#partial switch kind {
	case .Frame:
		node_set_raw(&n, "layout", `"none"`)
		node_set_raw(&n, "clip", "true")
		node_set_raw(&n, "fill", `"#FFFFFF"`)
	case .Rectangle, .Ellipse:
		node_set_raw(&n, "fill", `"#D9D9D9"`)
	case .Text:
		node_set_raw(&n, "fill", `"#1E1E1E"`)
		node_set_raw(&n, "fontSize", "16")
		node_set_raw(&n, "textGrowth", `"auto"`)
	}
	return n
}

mouse_down_tool :: proc(page: [2]f32) {
	switch app.tool {
	case .Hand:
	case .Select:
		if gh := grad_handle_under_mouse(); gh != .None {
			push_undo()
			app.drag.kind = .Gradient
			app.drag.handle = int(gh)
			return
		}
		if h := handle_under_mouse(); h >= 0 {
			n, _ := doc_find_uid(&app.doc, app.sel[0])
			app.drag.kind = .Resize
			app.drag.handle = h
			app.drag.target = n.uid
			app.drag.orig = {n.x, n.y, n.w, n.h}
			return
		}
		deepest := hit_test(page)
		hit := click_target(deepest, mod_cmd())
		now := time.now()
		double := time.duration_seconds(time.diff(app.last_click, now)) < 0.35 && abs(app.mouse.x - app.last_click_p.x) < 4 && abs(app.mouse.y - app.last_click_p.y) < 4
		app.last_click, app.last_click_p = now, app.mouse
		if double && deepest != 0 {
			// double click: text is edited, a title renames its frame, an instance opens its
			// component, anything else selects the layer one level further in
			if n, _ := doc_find_uid(&app.doc, deepest); n != nil && n.kind == .Text {
				start_text_editing(deepest)
				return
			}
			if n, _ := doc_find_uid(&app.doc, hit); n != nil {
				if page.y < n.y {
					start_rename(hit, true)
					return
				}
				if n.kind == .Path {
					pen_start_editing(hit)
					return
				}
				if inner := child_toward(deepest, hit); inner != 0 {
					clear(&app.sel)
					append(&app.sel, inner)
					app.drag.kind = .Move
					return
				}
				if n.kind == .Ref {
					go_to_component(n)
					return
				}
			}
		}
		if hit == 0 || frame_body(hit, page) {
			if !mod_shift() do clear(&app.sel)
			app.drag.kind = .Marquee
			app.drag.target = hit // the frame whose layers the marquee picks (0: the page)
			return
		}
		if mod_shift() {
			if is_selected(hit) {
				for uid, i in app.sel do if uid == hit {ordered_remove(&app.sel, i); break}
			} else {
				append(&app.sel, hit)
			}
		} else if !is_selected(hit) {
			clear(&app.sel)
			append(&app.sel, hit)
		}
		app.drag.kind = .Move
	case .Pen: // pen_input handles it
	case .Frame, .Rect, .Ellipse:
		kind := Node_Kind.Frame if app.tool == .Frame else (.Rectangle if app.tool == .Rect else .Ellipse)
		push_undo()
		parent := 0 if kind == .Frame else frame_at(page, 0)
		n := new_node(kind, parent)
		added := doc_add(&app.doc, n)
		set_box(added, page.x, page.y, 1, 1)
		clear(&app.sel)
		append(&app.sel, added.uid)
		app.drag.kind = .Create
		app.drag.target = added.uid
	case .Text:
		push_undo()
		n := new_node(.Text, frame_at(page, 0))
		node_set_raw(&n, "content", `""`)
		added := doc_add(&app.doc, n)
		ox, oy := parent_origin(&app.doc, added.parent)
		node_set_number(&app.doc, added, "x", page.x - ox)
		node_set_number(&app.doc, added, "y", page.y - 8 - oy)
		clear(&app.sel)
		append(&app.sel, added.uid)
		app.tool = .Select
		start_text_editing(added.uid)
	}
}

// Authors an absolute page box as parent-relative position and fixed size.
set_box :: proc(n: ^Node, x, y, w, h: f32) {
	ox, oy := parent_origin(&app.doc, n.parent)
	node_set_number(&app.doc, n, "x", x - ox)
	node_set_number(&app.doc, n, "y", y - oy)
	if n.kind == .Text {
		if n.growth == .Auto do node_set_string(&app.doc, n, "textGrowth", "fixed-width")
	}
	node_set_number(&app.doc, n, "width", max(w, 1))
	if n.kind != .Text || n.growth == .Fixed_Width_Height do node_set_number(&app.doc, n, "height", max(h, 1))
}

drag_update :: proc(page: [2]f32) {
	d := &app.drag
	switch d.kind {
	case .None, .Marquee, .Zoom:
	case .Gradient:
		grad_drag(Grad_Handle(d.handle), page)
	case .Pan:
		app.cam -= mouse_delta() / app.zoom
	case .Move:
		if page == d.last_page do break
		if !d.pushed_undo {
			if abs(app.mouse.x - d.start_mouse.x) + abs(app.mouse.y - d.start_mouse.y) < 3 do break
			push_undo()
			d.pushed_undo = true
			clear(&app.move_roots)
			clear(&app.move_start)
			for uid in selection_roots() {
				n, _ := doc_find_uid(&app.doc, uid)
				if n == nil do continue
				if in_flow(&app.doc, n) {
					set_status("%s is positioned by its parent's layout", node_label(n))
					continue
				}
				append(&app.move_roots, uid)
				append(&app.move_start, [2]f32{n.x, n.y})
			}
		}
		// absolute: start + pointer travel, then snapped to neighbours
		delta := page - d.start_page
		lo, hi := [2]f32{1e9, 1e9}, [2]f32{-1e9, -1e9}
		for uid, i in app.move_roots {
			n, _ := doc_find_uid(&app.doc, uid)
			if n == nil do continue
			p := app.move_start[i] + delta
			lo = {min(lo.x, p.x), min(lo.y, p.y)}
			hi = {max(hi.x, p.x + n.w), max(hi.y, p.y + n.h)}
		}
		if len(app.move_roots) > 0 {
			delta += snap_box({lo.x, lo.y, hi.x - lo.x, hi.y - lo.y}, app.move_roots[:], {true, true, true}, {true, true, true})
		}
		for uid, i in app.move_roots {
			n, _ := doc_find_uid(&app.doc, uid)
			if n == nil do continue
			target := app.move_start[i] + delta
			target = {snap_px(target.x), snap_px(target.y)}
			doc_move(&app.doc, uid, target.x - n.x, target.y - n.y)
		}
		mark_dirty()
	case .Resize:
		n, _ := doc_find_uid(&app.doc, d.target)
		if n == nil do break
		if !d.pushed_undo {
			push_undo()
			d.pushed_undo = true
		}
		x0, y0 := d.orig[0], d.orig[1]
		x1, y1 := x0 + d.orig[2], y0 + d.orig[3]
		delta := page - d.start_page
		switch d.handle {
		case 0: x0 += delta.x; y0 += delta.y
		case 1: y0 += delta.y
		case 2: x1 += delta.x; y0 += delta.y
		case 3: x1 += delta.x
		case 4: x1 += delta.x; y1 += delta.y
		case 5: y1 += delta.y
		case 6: x0 += delta.x; y1 += delta.y
		case 7: x0 += delta.x
		}
		if mod_shift() && d.orig[3] > 0 {
			ratio := d.orig[2] / d.orig[3]
			if abs(x1 - x0) / ratio > abs(y1 - y0) do y1 = y0 + math.sign(y1 - y0) * abs(x1 - x0) / ratio
			else do x1 = x0 + math.sign(x1 - x0) * abs(y1 - y0) * ratio
		} else {
			// snap the edges being dragged
			left := d.handle == 0 || d.handle == 6 || d.handle == 7
			right := d.handle == 2 || d.handle == 3 || d.handle == 4
			top := d.handle == 0 || d.handle == 1 || d.handle == 2
			bottom := d.handle == 4 || d.handle == 5 || d.handle == 6
			sn := snap_box({min(x0, x1), min(y0, y1), abs(x1 - x0), abs(y1 - y0)}, {n.uid}, {left, false, right}, {top, false, bottom})
			if left do x0 += sn.x
			if right do x1 += sn.x
			if top do y0 += sn.y
			if bottom do y1 += sn.y
		}
		if n.kind == .Text && (d.handle == 1 || d.handle == 5 || d.handle == 0 || d.handle == 2 || d.handle == 4 || d.handle == 6) && n.growth != .Fixed_Width_Height {
			node_set_string(&app.doc, n, "textGrowth", "fixed-width-height")
		}
		x0, y0, x1, y1 = snap_px(x0), snap_px(y0), snap_px(x1), snap_px(y1)
		set_box(n, min(x0, x1), min(y0, y1), abs(x1 - x0), abs(y1 - y0))
		mark_dirty()
	case .Create:
		n, _ := doc_find_uid(&app.doc, d.target)
		if n == nil do break
		a, b := d.start_page, page
		if mod_shift() {
			side := max(abs(b.x - a.x), abs(b.y - a.y))
			b = a + [2]f32{math.sign(b.x - a.x), math.sign(b.y - a.y)} * side
		} else {
			box := Rect{min(a.x, b.x), min(a.y, b.y), abs(b.x - a.x), abs(b.y - a.y)}
			sn := snap_box(box, {n.uid}, {b.x < a.x, false, b.x >= a.x}, {b.y < a.y, false, b.y >= a.y})
			b += sn
		}
		a, b = {snap_px(a.x), snap_px(a.y)}, {snap_px(b.x), snap_px(b.y)}
		set_box(n, min(a.x, b.x), min(a.y, b.y), abs(b.x - a.x), abs(b.y - a.y))
	}
	d.last_page = page
}

drag_end :: proc(page: [2]f32) {
	d := &app.drag
	clear(&app.guides)
	#partial switch d.kind {
	case .Create:
		if n, _ := doc_find_uid(&app.doc, d.target); n != nil && n.w < 3 && n.h < 3 {
			size: f32 = 400 if n.kind == .Frame else 100
			set_box(n, n.x, n.y, size, size * (0.75 if n.kind == .Frame else 1))
		}
		app.tool = .Select
	case .Move:
		if !d.pushed_undo do break
		// drop into / out of frames
		for uid in app.sel {
			n, _ := doc_find_uid(&app.doc, uid)
			if n == nil || n.kind == .Frame do continue
			if is_selected(n.parent) || in_flow(&app.doc, n) do continue
			target := frame_at({n.x + n.w / 2, n.y + n.h / 2}, uid)
			if target != n.parent do doc_reparent(&app.doc, uid, target)
		}
	case .Marquee:
		a, b := d.start_page, page
		r := [4]f32{min(a.x, b.x), min(a.y, b.y), abs(b.x - a.x), abs(b.y - a.y)}
		if r[2] < 2 && r[3] < 2 do break
		if !mod_shift() do clear(&app.sel)
		marquee_select(r, d.target, mod_cmd())
	case .Zoom:
		a, b := d.start_page, page
		if abs(app.mouse.x - d.start_mouse.x) + abs(app.mouse.y - d.start_mouse.y) < 4 {
			zoom_at(app.mouse, 0.5 if alt_down() else 2)
		} else {
			zoom_to_rect({min(a.x, b.x), min(a.y, b.y), abs(b.x - a.x), abs(b.y - a.y)})
		}
	}
}

// Selects by marquee. On the page: top-level layers fully inside it. Started in a frame:
// that frame's layers it touches. With ⌘: the innermost layers it touches.
marquee_select :: proc(r: [4]f32, scope: int, deep: bool) {
	touches :: proc(nb, r: [4]f32) -> bool {
		return nb[0] < r[0] + r[2] && nb[0] + nb[2] > r[0] && nb[1] < r[1] + r[3] && nb[1] + nb[3] > r[1]
	}
	for uid in app.draw_order {
		n, _ := doc_find_uid(&app.doc, uid)
		if n == nil || is_selected(uid) do continue
		nb := node_page_box(n)
		switch {
		case deep:
			if scope != 0 && !is_descendant(&app.doc, uid, scope) do continue
			if len(children_of(&app.doc, uid)) > 0 && n.kind != .Ref do continue
			if touches(nb, r) do append(&app.sel, uid)
		case scope != 0:
			if n.parent == scope && touches(nb, r) do append(&app.sel, uid)
		case:
			if n.parent == 0 && nb[0] >= r[0] && nb[1] >= r[1] && nb[0] + nb[2] <= r[0] + r[2] && nb[1] + nb[3] <= r[1] + r[3] do append(&app.sel, uid)
		}
	}
}

handle_shortcuts :: proc() {
	if pen_keys() do return
	cmd, shift := mod_cmd(), mod_shift()
	alt := key_down(glfw.KEY_LEFT_ALT) || key_down(glfw.KEY_RIGHT_ALT)
	if cmd {
		switch {
		case key_pressed(glfw.KEY_K) && alt: toggle_component_selection()
		case key_pressed(glfw.KEY_X) && alt:
			if len(app.sel) == 1 do detach_instance(app.sel[0])
		case key_pressed(glfw.KEY_X):
			if len(app.sel) > 0 {
				copy_selection()
				push_undo()
				for uid in app.sel do doc_delete(&app.doc, uid)
				clear(&app.sel)
			}
		case key_pressed(glfw.KEY_Z) && shift: redo()
		case key_pressed(glfw.KEY_Z): undo()
		case key_pressed(glfw.KEY_S):
			if save_document(app.file_path) do set_status("Saved")
		case key_pressed(glfw.KEY_D): duplicate_selection()
		case key_pressed(glfw.KEY_C) && shift:
			if len(app.sel) > 0 do copy_png_pending = true
		case key_pressed(glfw.KEY_C) && alt:
			if len(app.sel) > 0 {
				html := html_snippet(selection_roots())
				clipboard_set(transmute([]u8)html, "public.html", html)
				set_status("Copied as HTML")
			}
		case key_pressed(glfw.KEY_C): copy_selection()
		case key_pressed(glfw.KEY_V): paste_clipboard()
		case key_pressed(glfw.KEY_G) && shift: ungroup_selection()
		case key_pressed(glfw.KEY_G) && key_down(glfw.KEY_LEFT_ALT): wrap_selection(.Frame)
		case key_pressed(glfw.KEY_G): wrap_selection(.Group)
		case key_pressed(glfw.KEY_R) && len(app.sel) == 1: start_rename(app.sel[0], false)
		case key_pressed(glfw.KEY_LEFT_BRACKET):
			// one step back, as in pen.dev ([ alone sends to the back)
			push_undo()
			for uid in app.sel do move_in_siblings(uid, -1)
		case key_pressed(glfw.KEY_W): close_tab(app.tab)
		case key_pressed(glfw.KEY_COMMA): settings_open = true
		case key_pressed(glfw.KEY_APOSTROPHE):
			settings.pixel_grid = !settings.pixel_grid
			settings_save()
			set_status("Pixel grid %s", "on" if settings.pixel_grid else "off")
		case key_pressed(glfw.KEY_F):
			ui.side_tab = 0
			field_focus(0, "layers.search", ui.layer_search)
		case key_pressed(glfw.KEY_N): new_document()
		case key_pressed(glfw.KEY_E) && shift: export_request()
		case key_pressed(glfw.KEY_A):
			clear(&app.sel)
			append(&app.sel, ..all_uids(true))
		case key_pressed(glfw.KEY_0), key_pressed(glfw.KEY_1):
			// 100% around the middle of the view (⌘0 as in pen.dev)
			zoom_at({app.canvas.x + app.canvas.w / 2, app.canvas.y + app.canvas.h / 2}, 1 / app.zoom)
		case key_hit(glfw.KEY_EQUAL):
			zoom_at({app.canvas.x + app.canvas.w / 2, app.canvas.y + app.canvas.h / 2}, 1.25)
		case key_hit(glfw.KEY_MINUS):
			zoom_at({app.canvas.x + app.canvas.w / 2, app.canvas.y + app.canvas.h / 2}, 0.8)
		case key_pressed(glfw.KEY_RIGHT_BRACKET):
			push_undo()
			for i := len(app.sel) - 1; i >= 0; i -= 1 do move_in_siblings(app.sel[i], 1)
		}
		return
	}
	// pen.dev's arrange and view shortcuts
	if alt && !shift && len(app.sel) > 0 {
		switch {
		case key_pressed(glfw.KEY_A): align_selection(.Left); return
		case key_pressed(glfw.KEY_D): align_selection(.Right); return
		case key_pressed(glfw.KEY_W): align_selection(.Top); return
		case key_pressed(glfw.KEY_S): align_selection(.Bottom); return
		case key_pressed(glfw.KEY_H): align_selection(.Center_H); return
		case key_pressed(glfw.KEY_V): align_selection(.Center_V); return
		}
	}
	if alt && shift && key_pressed(glfw.KEY_A) {
		remove_flex_selection()
		return
	}
	if shift && key_pressed(glfw.KEY_SLASH) {
		shortcuts_open = true
		return
	}
	if shift {
		switch {
		case key_pressed(glfw.KEY_1):
			if r, ok := bounds_of(all_uids(true)); ok do zoom_to_rect(r)
			return
		case key_pressed(glfw.KEY_2):
			if r, ok := bounds_of(app.sel[:]); ok do zoom_to_rect(r)
			return
		case key_pressed(glfw.KEY_H): flip_selection(true); return
		case key_pressed(glfw.KEY_V): flip_selection(false); return
		case key_pressed(glfw.KEY_ENTER):
			// select the parent
			if len(app.sel) == 1 {
				if n, _ := doc_find_uid(&app.doc, app.sel[0]); n != nil && n.parent != 0 {
					clear(&app.sel)
					append(&app.sel, n.parent)
				}
			}
			return
		}
	}
	if key_pressed(glfw.KEY_LEFT_BRACKET) && len(app.sel) > 0 {
		push_undo()
		for uid in app.sel do send_to_back(uid)
		return
	}
	if key_pressed(glfw.KEY_RIGHT_BRACKET) && len(app.sel) > 0 {
		push_undo()
		for uid in app.sel do doc_bring_to_front(&app.doc, uid)
		return
	}
	switch {
	case key_pressed(glfw.KEY_V): app.tool = .Select
	case key_pressed(glfw.KEY_H): app.tool = .Hand
	case key_pressed(glfw.KEY_B), key_pressed(glfw.KEY_F): app.tool = .Frame
	case key_pressed(glfw.KEY_R): app.tool = .Rect
	case key_pressed(glfw.KEY_E), key_pressed(glfw.KEY_O): app.tool = .Ellipse
	case key_pressed(glfw.KEY_T): app.tool = .Text
	case key_pressed(glfw.KEY_P): app.tool = .Pen
	case key_pressed(glfw.KEY_A) && shift: wrap_selection(.Auto_Layout)
	case key_pressed(glfw.KEY_ESCAPE):
		app.tool = .Select
		clear(&app.sel)
	case key_pressed(glfw.KEY_ENTER):
		if len(app.sel) == 1 {
			n, _ := doc_find_uid(&app.doc, app.sel[0])
			if n != nil && n.kind == .Text do start_text_editing(n.uid)
			else if n != nil && n.kind == .Path do pen_start_editing(n.uid)
			else if n != nil {
				// select the children of a container
				kids := children_of(&app.doc, n.uid)
				if len(kids) > 0 {
					clear(&app.sel)
					append(&app.sel, ..kids)
				}
			}
		}
	case key_pressed(glfw.KEY_BACKSPACE), key_pressed(glfw.KEY_DELETE):
		if len(app.sel) > 0 {
			push_undo()
			for uid in app.sel do doc_delete(&app.doc, uid)
			clear(&app.sel)
		}
	}
	nudge := [2]f32{}
	step := settings.nudge_big if shift else settings.nudge
	if key_hit(glfw.KEY_LEFT) do nudge.x -= step
	if key_hit(glfw.KEY_RIGHT) do nudge.x += step
	if key_hit(glfw.KEY_UP) do nudge.y -= step
	if key_hit(glfw.KEY_DOWN) do nudge.y += step
	if nudge != {0, 0} && len(app.sel) > 0 {
		push_undo()
		// inside a flex layout the arrows reorder (as in pen.dev) instead of nudging
		if n, _ := doc_find_uid(&app.doc, app.sel[0]); n != nil && in_flow(&app.doc, n) {
			p, _ := doc_find_uid(&app.doc, n.parent)
			along := nudge.x if p != nil && p.layout == .Horizontal else nudge.y
			if along != 0 do move_in_siblings(n.uid, 1 if along > 0 else -1)
			return
		}
		for uid in app.sel do doc_move(&app.doc, uid, nudge.x, nudge.y)
	}
}

duplicate_selection :: proc() {
	if len(app.sel) == 0 do return
	push_undo()
	new_sel := make([dynamic]int, context.temp_allocator)
	for uid in app.sel {
		if nuid := duplicate_tree(uid, -1, 16); nuid != 0 do append(&new_sel, nuid)
	}
	clear(&app.sel)
	append(&app.sel, ..new_sel[:])
}

// Copies a node and its subtree with fresh ids; parent -1 keeps the original parent.
duplicate_tree :: proc(uid: int, parent: int, offset: f32) -> int {
	src, _ := doc_find_uid(&app.doc, uid)
	if src == nil do return 0
	c := node_clone(src^)
	delete(c.id)
	c.id = ""
	if parent >= 0 do c.parent = parent
	added := doc_add(&app.doc, c)
	nuid := added.uid
	if offset != 0 {
		node_set_number(&app.doc, added, "x", added.pos.x + offset)
		node_set_number(&app.doc, added, "y", added.pos.y + offset)
	}
	children := make([dynamic]int, context.temp_allocator)
	for n in app.doc.nodes do if n.parent == uid do append(&children, n.uid)
	for ch in children do duplicate_tree(ch, nuid, 0)
	return nuid
}

// ---------------------------------------------------------------- text editing

start_text_editing :: proc(uid: int) {
	app.editing = uid
	clear(&app.sel)
	append(&app.sel, uid)
}

finish_text_editing :: proc() {
	n, _ := doc_find_uid(&app.doc, app.editing)
	if n != nil && strings.trim_space(n.content) == "" {
		doc_delete(&app.doc, n.uid)
		prune_selection()
	}
	app.editing = 0
}

handle_text_editing :: proc() {
	n, _ := doc_find_uid(&app.doc, app.editing)
	if n == nil {
		app.editing = 0
		return
	}
	if key_pressed(glfw.KEY_ESCAPE) || (mod_cmd() && key_pressed(glfw.KEY_ENTER)) {
		finish_text_editing()
		return
	}
	changed := false
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, n.content)
	for r in pf.chars {
		strings.write_rune(&b, r)
		changed = true
	}
	if key_hit(glfw.KEY_ENTER) || key_hit(glfw.KEY_KP_ENTER) {
		strings.write_byte(&b, '\n')
		changed = true
	}
	if key_hit(glfw.KEY_BACKSPACE) && strings.builder_len(b) > 0 {
		str := strings.to_string(b)
		_, size := utf8.decode_last_rune_in_string(str)
		strings.builder_init(&b, context.temp_allocator)
		strings.write_string(&b, str[:len(str) - size])
		changed = true
	}
	if changed {
		node_set_string(&app.doc, n, "content", strings.to_string(b))
		mark_dirty()
	}
}


// ---------------------------------------------------------------- smart guides

Guide :: struct {
	vertical: bool,
	pos:      f32, // x for vertical lines, y for horizontal
	lo, hi:   f32, // extent along the other axis
}

// Edges/centres of the siblings of `moving` (and of their parent) that a box can snap to.
// Returns the correction to apply and records the guide lines to draw.
// `xs`/`ys` say which of the box's left/centre/right (top/centre/bottom) may snap.
snap_box :: proc(box: Rect, moving: []int, xs, ys: [3]bool) -> (delta: [2]f32) {
	clear(&app.guides)
	if !settings.smart_guides || key_down(glfw.KEY_LEFT_CONTROL) || key_down(glfw.KEY_RIGHT_CONTROL) do return
	parent := 0
	if len(moving) > 0 {
		if n, _ := doc_find_uid(&app.doc, moving[0]); n != nil do parent = n.parent
	}
	Cand :: struct {
		x, y, w, h: f32,
	}
	cands := make([dynamic]Cand, context.temp_allocator)
	for &n in app.doc.nodes {
		if n.parent != parent || !n.enabled do continue
		if parent == 0 && app.page_hidden[n.uid] do continue
		skip := false
		for m in moving do if m == n.uid || is_descendant(&app.doc, n.uid, m) do skip = true
		if skip do continue
		append(&cands, Cand{n.x, n.y, n.w, n.h})
	}
	if p, _ := doc_find_uid(&app.doc, parent); p != nil do append(&cands, Cand{p.x, p.y, p.w, p.h})
	if len(cands) == 0 do return

	tol := 6 / app.zoom
	best_x, best_y := tol, tol
	gx, gy: Guide
	has_x, has_y: bool
	mine_x := [3]f32{box.x, box.x + box.w / 2, box.x + box.w}
	mine_y := [3]f32{box.y, box.y + box.h / 2, box.y + box.h}
	for c in cands {
		cx := [3]f32{c.x, c.x + c.w / 2, c.x + c.w}
		cy := [3]f32{c.y, c.y + c.h / 2, c.y + c.h}
		for i in 0 ..< 3 {
			if !xs[i] do continue
			for j in 0 ..< 3 {
				d := cx[j] - mine_x[i]
				if abs(d) < abs(best_x) || (abs(d) < tol && !has_x) {
					best_x, has_x = d, true
					gx = {true, cx[j], min(box.y, c.y), max(box.y + box.h, c.y + c.h)}
				}
			}
		}
		for i in 0 ..< 3 {
			if !ys[i] do continue
			for j in 0 ..< 3 {
				d := cy[j] - mine_y[i]
				if abs(d) < abs(best_y) || (abs(d) < tol && !has_y) {
					best_y, has_y = d, true
					gy = {false, cy[j], min(box.x, c.x), max(box.x + box.w, c.x + c.w)}
				}
			}
		}
	}
	if has_x && abs(best_x) < tol {
		delta.x = best_x
		gx.lo -= 8 / app.zoom
		gx.hi += 8 / app.zoom
		append(&app.guides, gx)
	}
	if has_y && abs(best_y) < tol {
		delta.y = best_y
		gy.lo -= 8 / app.zoom
		gy.hi += 8 / app.zoom
		append(&app.guides, gy)
	}
	return
}


// Selects the component an instance refers to and brings it into view.
go_to_component :: proc(inst: ^Node) {
	comp := instance_component(&app.doc, inst)
	if comp == nil {
		set_status("Component \"%s\" not found", inst.ref)
		return
	}
	clear(&app.sel)
	append(&app.sel, comp.uid)
	if !on_page(comp.uid) {
		// the component lives on another page
		if top := top_ancestor(comp.uid); top != 0 {
			if n, _ := doc_find_uid(&app.doc, top); n != nil do page_switch(page_of_top(&app.doc, n.id))
			append(&app.sel, comp.uid)
		}
	}
	zoom_to_rect({comp.x - 40, comp.y - 40, comp.w + 80, comp.h + 80})
	set_status("Component %s", node_label(comp))
}

top_ancestor :: proc(uid: int) -> int {
	cur := uid
	for {
		n, _ := doc_find_uid(&app.doc, cur)
		if n == nil do return 0
		if n.parent == 0 do return cur
		cur = n.parent
	}
}

// Turns an instance into an editable copy of its component with the overrides applied.
detach_instance :: proc(inst_uid: int) {
	inst, _ := doc_find_uid(&app.doc, inst_uid)
	if inst == nil do return
	comp := instance_component(&app.doc, inst)
	if comp == nil do return
	push_undo()
	copy_uid := duplicate_tree(comp.uid, inst.parent, 0)
	c, _ := doc_find_uid(&app.doc, copy_uid)
	if c == nil do return
	node_unset(&app.doc, c, "reusable")
	node_set_number(&app.doc, c, "x", inst.pos.x)
	node_set_number(&app.doc, c, "y", inst.pos.y)
	if inst.name != "" do node_set_string(&app.doc, c, "name", inst.name)
	// overrides become plain properties of the copied descendants (matched by original id)
	for o in inst.overrides {
		if o.replaces do continue
		orig, _ := doc_find(&app.doc, o.id)
		if orig == nil do continue
		// the copy of `orig` is the clone created in the same order: find it by subtree walk
		target := find_clone(copy_uid, comp.uid, orig.uid)
		if target == nil do continue
		if o.has_content do node_set_string(&app.doc, target, "content", o.content)
		if o.has_name do node_set_string(&app.doc, target, "name", o.name)
		if o.set_fill && o.fill_on do node_set_fill(&app.doc, target, o.fill)
		if o.set_stroke && o.stroke_on do node_set_stroke(&app.doc, target, o.stroke)
		if o.set_enabled do node_set_bool(&app.doc, target, "enabled", o.enabled)
		if o.set_opacity do node_set_number(&app.doc, target, "opacity", o.opacity)
		if o.set_font_size do node_set_number(&app.doc, target, "fontSize", o.font_size)
		if o.set_weight do node_set_string(&app.doc, target, "fontWeight", fmt.tprintf("%d", o.weight))
	}
	// slot content moves into the copy's slot frame
	slot := copy_uid
	if sf := find_clone_slot(copy_uid); sf != 0 do slot = sf
	kids := make([dynamic]int, context.temp_allocator)
	for cu in children_of(&app.doc, inst_uid) do append(&kids, cu)
	for cu in kids do doc_reparent(&app.doc, cu, slot)
	doc_delete(&app.doc, inst_uid)
	clear(&app.sel)
	append(&app.sel, copy_uid)
	mark_dirty()
}

// The node in the copied subtree that corresponds to `orig_uid` in the original one
// (both subtrees have the same shape, so walk them in parallel).
find_clone :: proc(copy_root, orig_root, orig_uid: int) -> ^Node {
	if orig_root == orig_uid {
		n, _ := doc_find_uid(&app.doc, copy_root)
		return n
	}
	ck := children_of(&app.doc, copy_root)
	ok := children_of(&app.doc, orig_root)
	for i in 0 ..< min(len(ck), len(ok)) {
		if found := find_clone(ck[i], ok[i], orig_uid); found != nil do return found
	}
	return nil
}

find_clone_slot :: proc(root: int) -> int {
	for cu in children_of(&app.doc, root) {
		if c, _ := doc_find_uid(&app.doc, cu); c != nil {
			if c.kind == .Frame && c.is_slot do return cu
			if found := find_clone_slot(cu); found != 0 do return found
		}
	}
	return 0
}
