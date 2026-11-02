package agentic_design

import "core:encoding/json"
import "core:math"
import "core:strings"
import "engine"
import nvg "nanovg"
import "vendor:glfw"

// The canvas side of connectors (D54): the connector tool (C) draws one from a shape to
// another (from a side dot for a fixed side, from anywhere on the shape for the side facing
// the other); a selected connector shows its two ends, which drag onto other shapes or
// sides; double-clicking a connector edits its label. Connectors are picked by their line,
// not by the box around it.

Conn_Tool :: struct {
	active:     bool, // dragging out a new connector, or one end of the selected one
	moving_end: int, // 0: a new connector; 1: the source end; 2: the target end of app.sel[0]
	from:       int, // uid of the layer it starts from (a new connector)
	from_side:  engine.Anchor,
	over:       int, // the layer under the pointer that it would attach to
	over_side:  engine.Anchor,
}

ctool: Conn_Tool

SIDE_DOT :: 8 // screen pixels: how near a side dot the pointer picks that side

// The layer a connector end attaches to under the pointer: the deepest layer hit, raised
// out of text, icons and a shape's outline to the box around them; not the top-level frame
// a diagram is drawn on, not connectors or their labels.
connect_target :: proc(page: [2]f32, exclude := 0) -> int {
	uid := hit_test(page)
	for uid != 0 {
		n, _ := engine.doc_find_uid(&app.doc, uid)
		if n == nil do return 0
		if n.flow == .Connector || n.flow == .Label do return 0
		raise := n.kind == .Text || n.kind == .Icon || engine.is_shape_outline(n)
		if p, _ := engine.doc_find_uid(&app.doc, n.parent); raise && p != nil && p.parent != 0 {
			uid = p.uid
			continue
		}
		if n.parent == 0 && n.kind == .Frame do return 0 // the board itself
		if uid == exclude do return 0
		return uid
	}
	return 0
}

// The side whose dot is under the pointer, or center.
side_under_mouse :: proc(uid: int) -> engine.Anchor {
	n, _ := engine.doc_find_uid(&app.doc, uid)
	if n == nil do return .Center
	box := engine.node_page_box(n)
	for s in ([4]engine.Anchor{.Top, .Right, .Bottom, .Left}) {
		p := to_screen(engine.side_point(box, s))
		if abs(app.mouse.x - p.x) <= SIDE_DOT && abs(app.mouse.y - p.y) <= SIDE_DOT do return s
	}
	return .Center
}

// The id path that names a layer from the document: its id, or through the instances it
// is copied into ("card/title").
id_path :: proc(n: ^engine.Node) -> string {
	if !n.ghost do return n.id
	inst, _ := engine.doc_find_uid(&app.doc, n.ghost_inst)
	if inst == nil do return n.ghost_of
	return strings.concatenate({id_path(inst), "/", n.ghost_of}, context.temp_allocator)
}

// The selected connector, if exactly one is selected.
selected_connector :: proc() -> ^engine.Node {
	if len(app.sel) != 1 do return nil
	n, _ := engine.doc_find_uid(&app.doc, app.sel[0])
	if n == nil || n.flow != .Connector do return nil
	return n
}

// Which end of the selected connector is under the pointer: 1 source, 2 target, 0 none.
connector_end_under_mouse :: proc() -> int {
	n := selected_connector()
	if n == nil do return 0
	route, has := engine.connector_routes[n.uid]
	if !has || len(route) < 2 do return 0
	for p, i in ([2][2]f32{route[0], route[len(route) - 1]}) {
		s := to_screen(p)
		if abs(app.mouse.x - s.x) <= 7 && abs(app.mouse.y - s.y) <= 7 do return i + 1
	}
	return 0
}

// Whether a page point is on a connector's line (within a few screen pixels).
point_on_connector :: proc(n: ^engine.Node, p: [2]f32) -> bool {
	route, has := engine.connector_routes[n.uid]
	if !has do return false
	tol := 5 / app.zoom + n.stroke_width / 2
	for i in 1 ..< len(route) {
		if seg_distance(p, route[i - 1], route[i]) <= tol do return true
	}
	return false
}

seg_distance :: proc(p, a, b: [2]f32) -> f32 {
	d := b - a
	l2 := d.x * d.x + d.y * d.y
	t: f32 = 0
	if l2 > 0 do t = clamp(((p.x - a.x) * d.x + (p.y - a.y) * d.y) / l2, 0, 1)
	q := a + d * t
	return math.sqrt((p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y))
}

// Pointer handling for the connector tool and for dragging a connector's ends. True when
// it took the event.
connector_input :: proc(page: [2]f32, over_canvas: bool) -> bool {
	if ctool.active {
		exclude := ctool.from if ctool.moving_end == 0 else 0
		ctool.over = connect_target(page, exclude)
		ctool.over_side = side_under_mouse(ctool.over) if ctool.over != 0 else .Center
		if mouse_down(glfw.MOUSE_BUTTON_LEFT) do return true
		connector_drop()
		return true
	}
	if !over_canvas || !mouse_pressed(glfw.MOUSE_BUTTON_LEFT) || key_down(glfw.KEY_SPACE) do return false
	if app.tool == .Select {
		if e := connector_end_under_mouse(); e != 0 {
			ctool = {active = true, moving_end = e}
			return true
		}
		return false
	}
	if app.tool != .Connector do return false
	target := connect_target(page)
	if target == 0 do return true // a connector starts on a shape; the canvas does nothing
	ctool = {active = true, from = target, from_side = side_under_mouse(target)}
	return true
}

connector_drop :: proc() {
	defer ctool = {}
	if ctool.over == 0 do return
	to, _ := engine.doc_find_uid(&app.doc, ctool.over)
	if to == nil do return
	if ctool.moving_end != 0 {
		n := selected_connector()
		if n == nil do return
		o := make(json.Object, 2, context.temp_allocator)
		end := make(json.Object, 2, context.temp_allocator)
		end["path"] = json.String(id_path(to))
		end["anchor"] = json.String(engine.ANCHOR_NAMES[ctool.over_side])
		o["source" if ctool.moving_end == 1 else "target"] = end
		push_undo()
		if e := update_connector(n, o); e != "" do set_status("%s", e)
		return
	}
	from, _ := engine.doc_find_uid(&app.doc, ctool.from)
	if from == nil do return
	opt := default_connect()
	opt.from, opt.from_side = id_path(from), ctool.from_side
	opt.to, opt.to_side = id_path(to), ctool.over_side
	push_undo()
	uid, _, err := connect_layers(opt)
	if err != "" {
		set_status("%s", err)
		return
	}
	clear(&app.sel)
	append(&app.sel, uid)
	app.tool = .Select
}

// Double-click on a connector: edit its label (adding one).
edit_connector_label :: proc(n: ^engine.Node) {
	label := connector_label(n)
	if label == nil {
		push_undo()
		uid := add_connector_label(n.uid, "Label", n.parent)
		engine.layout_document(&app.doc)
		label, _ = engine.doc_find_uid(&app.doc, uid)
		if label == nil do return
	}
	for cu in engine.children_of(&app.doc, label.uid) {
		if t, _ := engine.doc_find_uid(&app.doc, cu); t != nil && t.kind == .Text {
			start_text_editing(t.uid)
			return
		}
	}
}

// The tool's dots, the line being drawn, and the selected connector's route and ends.
draw_connector_overlay :: proc(vg: ^nvg.Context) {
	dots :: proc(vg: ^nvg.Context, uid: int, hot: engine.Anchor) {
		n, _ := engine.doc_find_uid(&app.doc, uid)
		if n == nil do return
		outline_node(n, 1.5)
		box := engine.node_page_box(n)
		for s in ([4]engine.Anchor{.Top, .Right, .Bottom, .Left}) {
			p := to_screen(engine.side_point(box, s))
			nvg.BeginPath(vg)
			nvg.Circle(vg, p.x, p.y, 5 if s == hot else 3.5)
			nvg.FillColor(vg, ACCENT if s == hot else nvg.Color{1, 1, 1, 1})
			nvg.Fill(vg)
			nvg.StrokeColor(vg, ACCENT)
			nvg.StrokeWidth(vg, 1.5)
			nvg.Stroke(vg)
		}
	}
	if app.tool == .Connector && !ctool.active && in_rect(app.canvas, app.mouse) {
		if t := connect_target(to_page(app.mouse)); t != 0 do dots(vg, t, side_under_mouse(t))
	}
	if ctool.active {
		start: [2]f32
		if ctool.moving_end == 0 {
			dots(vg, ctool.from, ctool.from_side)
			if f, _ := engine.doc_find_uid(&app.doc, ctool.from); f != nil {
				box := engine.node_page_box(f)
				start = engine.side_point(box, ctool.from_side)
			}
		} else if n := selected_connector(); n != nil {
			route := engine.connector_routes[n.uid]
			if len(route) >= 2 do start = route[len(route) - 1] if ctool.moving_end == 1 else route[0]
		}
		if ctool.over != 0 do dots(vg, ctool.over, ctool.over_side)
		a, b := to_screen(start), app.mouse
		nvg.BeginPath(vg)
		nvg.MoveTo(vg, a.x, a.y)
		nvg.LineTo(vg, b.x, b.y)
		nvg.StrokeColor(vg, ACCENT)
		nvg.StrokeWidth(vg, 1.5)
		nvg.Stroke(vg)
	}
	if n := selected_connector(); n != nil && !ctool.active {
		route, has := engine.connector_routes[n.uid]
		if !has || len(route) < 2 do return
		for p in ([2][2]f32{route[0], route[len(route) - 1]}) {
			s := to_screen(p)
			nvg.BeginPath(vg)
			nvg.Circle(vg, s.x, s.y, 4.5)
			nvg.FillColor(vg, {1, 1, 1, 1})
			nvg.Fill(vg)
			nvg.StrokeColor(vg, ACCENT)
			nvg.StrokeWidth(vg, 1.5)
			nvg.Stroke(vg)
		}
	}
}

// A connector's selection outline: its route.
outline_connector :: proc(n: ^engine.Node, width: f32) -> bool {
	route, has := engine.connector_routes[n.uid]
	if !has || len(route) < 2 do return false
	vg := app.vg
	nvg.BeginPath(vg)
	for p, i in route {
		s := to_screen(p)
		if i == 0 do nvg.MoveTo(vg, s.x, s.y)
		else do nvg.LineTo(vg, s.x, s.y)
	}
	nvg.StrokeColor(vg, ACCENT)
	nvg.StrokeWidth(vg, width + 1)
	nvg.Stroke(vg)
	return true
}

MARKER_LABELS := [engine.Marker]string {
	.None       = "None",
	.Arrow      = "Arrow",
	.Open_Arrow = "Open arrow",
	.Circle     = "Circle",
	.Diamond    = "Diamond",
	.Bar        = "Bar",
}

// The inspector's connector section: routing, the markers at both ends, the label.
draw_connector_section :: proc(vg: ^nvg.Context, n: ^engine.Node, x, right: f32, y: ^f32) {
	c, ok := engine.connector_of(n)
	if !ok do return
	w := right - x
	section(vg, x, y, "Connector")
	apply :: proc(n: ^engine.Node, key, value: string) {
		o := make(json.Object, 1, context.temp_allocator)
		o[key] = json.String(value)
		push_undo()
		if e := update_connector(n, o); e != "" do set_status("%s", e)
	}
	routings := [3]string{"Elbow", "Straight", "Curved"}
	bw := (w - 8) / 3
	for name, i in routings {
		if button(vg, {x + f32(i) * (bw + 4), y^, bw, 28}, name, int(c.routing) == i) && int(c.routing) != i {
			apply(n, "routing", engine.ROUTING_NAMES[engine.Routing(i)])
		}
	}
	y^ += 36
	half := (w - 8) / 2
	items := make([]string, len(engine.Marker), context.temp_allocator)
	for m, i in engine.Marker do items[i] = MARKER_LABELS[m]
	sr := Rect{x, y^, half, 28}
	er := Rect{x + half + 8, y^, half, 28}
	if dropdown(vg, sr, strings.concatenate({"Start  ", MARKER_LABELS[c.start]}, context.temp_allocator)) do menu_open("conn.start", sr, items, int(c.start))
	if dropdown(vg, er, strings.concatenate({"End  ", MARKER_LABELS[c.end]}, context.temp_allocator)) do menu_open("conn.end", er, items, int(c.end))
	if pick, picked := menu_take("conn.start"); picked do apply(n, "startMarker", engine.MARKER_NAMES[engine.Marker(pick)])
	if pick, picked := menu_take("conn.end"); picked do apply(n, "endMarker", engine.MARKER_NAMES[engine.Marker(pick)])
	y^ += 36
	if button(vg, {x, y^, w, 28}, "Edit label" if connector_label(n) != nil else "Add label") do edit_connector_label(n)
	y^ += 40
	divider(vg, x, w, y)
}
