package agentic_design

import "engine"

import "core:fmt"
import "core:math"
import "core:strings"
import nvg "nanovg"

// The pen tool (P) and path editing, as in pen.dev and Figma.
// Drawing: a click places a corner point, a drag pulls out the handles of a smooth one,
// a click on the first point closes the path; Enter or Esc finishes it.
// Editing (double click or Enter on a path): drag points and handles (a smooth point's
// other handle follows, unless ⌥ is held), click a segment to add a point, ⌫ removes the
// selected point; Enter, Esc or a click away finishes.
// Points are kept in page coordinates of the path's untransformed box. Written back, the
// path gets a new box around its outline and geometry relative to it, so it stays put.

Pen_Anchor :: struct {
	p, hin, hout: [2]f32, // a handle equal to p is no handle
}

Pen_Sub :: struct {
	anchors: [dynamic]Pen_Anchor,
	closed:  bool,
}

Pen_Drag :: enum {
	None,
	Anchor,
	In,
	Out,
	New,
}

pen: struct {
	uid:         int, // the path being edited or drawn (0 before the first point is placed)
	drawing:     bool, // the pen tool is placing points
	subs:        [dynamic]Pen_Sub,
	sub, anchor: int, // the selected point, -1 none
	drag:        Pen_Drag,
	last:        [2]f32,
}

pen_active :: proc() -> bool {
	return pen.drawing || pen.uid != 0
}

pen_reset :: proc() {
	for &s in pen.subs do delete(s.anchors)
	clear(&pen.subs)
	pen.uid, pen.drawing, pen.sub, pen.anchor, pen.drag = 0, false, 0, -1, .None
}

pen_start_drawing :: proc() {
	if pen_active() do pen_finish()
	pen_reset()
	pen.drawing = true
	append(&pen.subs, Pen_Sub{})
	clear(&app.sel)
}

pen_start_editing :: proc(uid: int) {
	n, _ := engine.doc_find_uid(&app.doc, uid)
	if n == nil || n.kind != .Path || len(n.cmds) == 0 do return
	pen_reset()
	pen.uid = uid
	sx, sy := n.w / n.view_box[2], n.h / n.view_box[3]
	tp :: proc(q: [2]f32, n: ^engine.Node, sx, sy: f32) -> [2]f32 {return {n.x + (q.x - n.view_box[0]) * sx, n.y + (q.y - n.view_box[1]) * sy}}
	cur: ^Pen_Sub
	last: [2]f32
	for c in n.cmds {
		switch c.kind {
		case .Move:
			append(&pen.subs, Pen_Sub{})
			cur = &pen.subs[len(pen.subs) - 1]
			p := tp(c.p[2], n, sx, sy)
			append(&cur.anchors, Pen_Anchor{p, p, p})
			last = c.p[2]
		case .Line:
			if cur == nil do continue
			p := tp(c.p[2], n, sx, sy)
			append(&cur.anchors, Pen_Anchor{p, p, p})
			last = c.p[2]
		case .Cubic:
			if cur == nil || len(cur.anchors) == 0 do continue
			cur.anchors[len(cur.anchors) - 1].hout = tp(c.p[0], n, sx, sy)
			p := tp(c.p[2], n, sx, sy)
			append(&cur.anchors, Pen_Anchor{p, tp(c.p[1], n, sx, sy), p})
			last = c.p[2]
		case .Quad:
			if cur == nil || len(cur.anchors) == 0 do continue
			// as a cubic: the control point two thirds of the way from each end
			c1 := last + (c.p[0] - last) * 2 / 3
			c2 := c.p[1] + (c.p[0] - c.p[1]) * 2 / 3
			cur.anchors[len(cur.anchors) - 1].hout = tp(c1, n, sx, sy)
			p := tp(c.p[1], n, sx, sy)
			append(&cur.anchors, Pen_Anchor{p, tp(c2, n, sx, sy), p})
			last = c.p[1]
		case .Close:
			if cur == nil do continue
			cur.closed = true
			// a last point on top of the first one is the same point
			if k := len(cur.anchors); k > 1 {
				a, b := cur.anchors[0], cur.anchors[k - 1]
				if abs(a.p.x - b.p.x) < 0.01 && abs(a.p.y - b.p.y) < 0.01 {
					cur.anchors[0].hin = b.hin
					pop(&cur.anchors)
				}
			}
		}
	}
	clear(&app.sel)
	append(&app.sel, uid)
}

// The path as SVG data, its points shifted by -origin.
pen_svg :: proc(origin: [2]f32) -> string {
	b := strings.builder_make(context.temp_allocator)
	pt :: proc(b: ^strings.Builder, p, o: [2]f32) {fmt.sbprintf(b, " %s %s", engine.num_text(p.x - o.x), engine.num_text(p.y - o.y))}
	seg :: proc(b: ^strings.Builder, a, c: Pen_Anchor, o: [2]f32) {
		if a.hout == a.p && c.hin == c.p {
			strings.write_string(b, " L")
			pt(b, c.p, o)
		} else {
			strings.write_string(b, " C")
			pt(b, a.hout, o)
			pt(b, c.hin, o)
			pt(b, c.p, o)
		}
	}
	for s in pen.subs {
		if len(s.anchors) == 0 do continue
		strings.write_string(&b, " M")
		pt(&b, s.anchors[0].p, origin)
		for i in 1 ..< len(s.anchors) do seg(&b, s.anchors[i - 1], s.anchors[i], origin)
		if s.closed && len(s.anchors) > 1 {
			seg(&b, s.anchors[len(s.anchors) - 1], s.anchors[0], origin)
			strings.write_string(&b, " Z")
		}
	}
	return strings.trim_space(strings.to_string(b))
}

// Writes the points into the path node (creating it on the first point drawn).
pen_apply :: proc() {
	count := 0
	for s in pen.subs do count += len(s.anchors)
	if count == 0 do return
	_, box, ok := engine.parse_svg_path(pen_svg({0, 0}))
	if !ok do return
	n: ^engine.Node
	if pen.uid != 0 do n, _ = engine.doc_find_uid(&app.doc, pen.uid)
	if n == nil {
		first := pen.subs[0].anchors[0].p
		nn := new_node(.Path, frame_at(first, 0))
		engine.node_set_raw(&nn, "stroke", `"#000000"`)
		engine.node_set_raw(&nn, "strokeWidth", "1")
		n = engine.doc_add(&app.doc, nn)
		pen.uid = n.uid
	}
	ox, oy := engine.parent_origin(&app.doc, n.parent)
	engine.node_unset(&app.doc, n, "viewBox")
	engine.node_set_string(&app.doc, n, "geometry", pen_svg({box[0], box[1]}))
	engine.node_set_number(&app.doc, n, "x", box[0] - ox)
	engine.node_set_number(&app.doc, n, "y", box[1] - oy)
	engine.node_set_number(&app.doc, n, "width", box[2])
	engine.node_set_number(&app.doc, n, "height", box[3])
	mark_dirty()
}

pen_finish :: proc() {
	if pen.drawing && pen.uid != 0 {
		count := 0
		for s in pen.subs do count += len(s.anchors)
		// a single click is no path
		if count < 2 {
			engine.doc_delete(&app.doc, pen.uid)
			prune_selection()
		}
	}
	uid := pen.uid
	pen_reset()
	if app.tool == .Pen do app.tool = .Select
	if n, _ := engine.doc_find_uid(&app.doc, uid); n != nil {
		clear(&app.sel)
		append(&app.sel, uid)
	}
}

// Page point → the path's own (untransformed) page box, and back for drawing.
pen_to_local :: proc(p: [2]f32) -> [2]f32 {
	if n, _ := engine.doc_find_uid(&app.doc, pen.uid); n != nil {
		if m, tr := engine.node_transform(n); tr do return engine.xform_point(engine.xform_inverse(m), p)
	}
	return p
}

pen_to_screen :: proc(p: [2]f32) -> [2]f32 {
	if n, _ := engine.doc_find_uid(&app.doc, pen.uid); n != nil {
		if m, tr := engine.node_transform(n); tr do return to_screen(engine.xform_point(m, p))
	}
	return to_screen(p)
}

bezier_at :: proc(a, c1, c2, b: [2]f32, t: f32) -> [2]f32 {
	u := 1 - t
	return u * u * u * a + 3 * u * u * t * c1 + 3 * u * t * t * c2 + t * t * t * b
}

// Pointer handling while drawing or editing; true when the pen used the event.
pen_input :: proc(page: [2]f32) -> bool {
	if !pen_active() do return false
	near :: proc(q: [2]f32) -> bool {
		s := pen_to_screen(q)
		d := app.mouse - s
		return d.x * d.x + d.y * d.y <= 49
	}
	local := pen_to_local(page)
	if mouse_pressed(MOUSE_BUTTON_LEFT) {
		// the selected point's handles first, then any point
		if pen.anchor >= 0 && pen.sub < len(pen.subs) && pen.anchor < len(pen.subs[pen.sub].anchors) {
			a := pen.subs[pen.sub].anchors[pen.anchor]
			if a.hout != a.p && near(a.hout) {pen.drag = .Out; push_undo(); return true}
			if a.hin != a.p && near(a.hin) {pen.drag = .In; push_undo(); return true}
		}
		for s, si in pen.subs {
			for a, ai in s.anchors {
				if !near(a.p) do continue
				if pen.drawing && si == len(pen.subs) - 1 && ai == 0 && len(s.anchors) >= 2 && !s.closed {
					// back on the first point: close the path
					push_undo()
					pen.subs[si].closed = true
					pen_apply()
					pen_finish()
					return true
				}
				pen.sub, pen.anchor, pen.drag = si, ai, .Anchor
				pen.last = local
				push_undo()
				return true
			}
		}
		if pen.drawing {
			push_undo()
			s := &pen.subs[len(pen.subs) - 1]
			append(&s.anchors, Pen_Anchor{local, local, local})
			pen.sub, pen.anchor, pen.drag = len(pen.subs) - 1, len(s.anchors) - 1, .New
			pen_apply()
			return true
		}
		// editing: a click on a segment adds a point there
		for &s, si in pen.subs {
			k := len(s.anchors)
			segs := k if s.closed else k - 1
			for i in 0 ..< segs {
				a, b := s.anchors[i], s.anchors[(i + 1) % k]
				for step in 1 ..< 32 {
					t := f32(step) / 32
					if !near(bezier_at(a.p, a.hout, b.hin, b.p, t)) do continue
					push_undo()
					// de Casteljau split at t
					p01 := a.p + (a.hout - a.p) * t
					p12 := a.hout + (b.hin - a.hout) * t
					p23 := b.hin + (b.p - b.hin) * t
					p012 := p01 + (p12 - p01) * t
					p123 := p12 + (p23 - p12) * t
					mid := p012 + (p123 - p012) * t
					straight := a.hout == a.p && b.hin == b.p
					if !straight {
						s.anchors[i].hout = p01
						s.anchors[(i + 1) % k].hin = p23
					}
					na := Pen_Anchor{mid, mid if straight else p012, mid if straight else p123}
					inject_at(&s.anchors, i + 1, na)
					pen.sub, pen.anchor, pen.drag = si, i + 1, .Anchor
					pen.last = local
					pen_apply()
					return true
				}
			}
		}
		// elsewhere: done editing
		pen_finish()
		return false
	}
	if pen.drag != .None {
		if !mouse_down(MOUSE_BUTTON_LEFT) {
			pen.drag = .None
			return true
		}
		if pen.sub >= len(pen.subs) || pen.anchor >= len(pen.subs[pen.sub].anchors) do return true
		a := &pen.subs[pen.sub].anchors[pen.anchor]
		mirror :: proc(a: ^Pen_Anchor, moved, other: ^[2]f32) {
			if alt_down() || other^ == a.p do return
			// the other handle keeps its length and points the opposite way
			d := moved^ - a.p
			l := math.sqrt(d.x * d.x + d.y * d.y)
			o := other^ - a.p
			ol := math.sqrt(o.x * o.x + o.y * o.y)
			if l > 1e-4 do other^ = a.p - d / l * ol
		}
		switch pen.drag {
		case .None:
		case .Anchor:
			d := local - pen.last
			a.p += d
			a.hin += d
			a.hout += d
			pen.last = local
		case .New:
			// pulling out the handles of the point just placed, symmetric
			a.hout = local
			a.hin = a.p - (local - a.p)
		case .Out:
			a.hout = local
			mirror(a, &a.hout, &a.hin)
		case .In:
			a.hin = local
			mirror(a, &a.hin, &a.hout)
		}
		pen_apply()
		return true
	}
	return pen.drawing && canvas_hit(app.mouse)
}

// Keys while drawing or editing; true when handled.
pen_keys :: proc() -> bool {
	if !pen_active() do return false
	if mod_cmd() {
		// undo, save and the rest act on the finished path
		pen_finish()
		return false
	}
	if key_pressed(KEY_ENTER) || key_pressed(KEY_ESCAPE) {
		pen_finish()
		return true
	}
	if (key_pressed(KEY_BACKSPACE) || key_pressed(KEY_DELETE)) && pen.anchor >= 0 && pen.sub < len(pen.subs) {
		s := &pen.subs[pen.sub]
		if pen.anchor < len(s.anchors) {
			push_undo()
			ordered_remove(&s.anchors, pen.anchor)
			if len(s.anchors) < 2 && !pen.drawing {
				delete(s.anchors)
				ordered_remove(&pen.subs, pen.sub)
			}
			pen.anchor = -1
			if len(pen.subs) == 0 {
				engine.doc_delete(&app.doc, pen.uid)
				prune_selection()
				pen_reset()
				return true
			}
			pen_apply()
		}
		return true
	}
	return true // other keys wait until the path is finished
}

PEN_COLOR :: nvg.Color{0.30, 0.55, 1, 1}

draw_pen_overlay :: proc(vg: ^nvg.Context) {
	if !pen_active() do return
	if !pen.drawing {
		if n, _ := engine.doc_find_uid(&app.doc, pen.uid); n == nil {
			pen_reset()
			return
		}
	}
	// the outline, the next segment while drawing, the handles of the selected point
	nvg.BeginPath(vg)
	for s in pen.subs {
		if len(s.anchors) == 0 do continue
		p0 := pen_to_screen(s.anchors[0].p)
		nvg.MoveTo(vg, p0.x, p0.y)
		k := len(s.anchors)
		segs := k if s.closed else k - 1
		for i in 0 ..< segs {
			a, b := s.anchors[i], s.anchors[(i + 1) % k]
			c1, c2, e := pen_to_screen(a.hout), pen_to_screen(b.hin), pen_to_screen(b.p)
			nvg.BezierTo(vg, c1.x, c1.y, c2.x, c2.y, e.x, e.y)
		}
	}
	nvg.StrokeColor(vg, PEN_COLOR)
	nvg.StrokeWidth(vg, 1.5)
	nvg.Stroke(vg)
	if pen.drawing && pen.drag == .None && len(pen.subs) > 0 && canvas_hit(app.mouse) {
		s := pen.subs[len(pen.subs) - 1]
		if k := len(s.anchors); k > 0 && !s.closed {
			a := s.anchors[k - 1]
			p, c := pen_to_screen(a.p), pen_to_screen(a.hout)
			nvg.BeginPath(vg)
			nvg.MoveTo(vg, p.x, p.y)
			nvg.BezierTo(vg, c.x, c.y, app.mouse.x, app.mouse.y, app.mouse.x, app.mouse.y)
			nvg.StrokeColor(vg, {PEN_COLOR.r, PEN_COLOR.g, PEN_COLOR.b, 0.6})
			nvg.StrokeWidth(vg, 1)
			nvg.Stroke(vg)
		}
	}
	for s, si in pen.subs {
		for a, ai in s.anchors {
			selected := si == pen.sub && ai == pen.anchor
			p := pen_to_screen(a.p)
			if selected || pen.drawing {
				for h in ([2][2]f32{a.hin, a.hout}) {
					if h == a.p do continue
					q := pen_to_screen(h)
					nvg.BeginPath(vg)
					nvg.MoveTo(vg, p.x, p.y)
					nvg.LineTo(vg, q.x, q.y)
					nvg.StrokeColor(vg, PEN_COLOR)
					nvg.StrokeWidth(vg, 1)
					nvg.Stroke(vg)
					nvg.BeginPath(vg)
					nvg.Circle(vg, q.x, q.y, 3.5)
					nvg.FillColor(vg, {1, 1, 1, 1})
					nvg.Fill(vg)
					nvg.StrokeColor(vg, PEN_COLOR)
					nvg.Stroke(vg)
				}
			}
			nvg.BeginPath(vg)
			nvg.Rect(vg, p.x - 4, p.y - 4, 8, 8)
			nvg.FillColor(vg, PEN_COLOR if selected else nvg.Color{1, 1, 1, 1})
			nvg.Fill(vg)
			nvg.StrokeColor(vg, PEN_COLOR)
			nvg.StrokeWidth(vg, 1.5)
			nvg.Stroke(vg)
		}
	}
}
