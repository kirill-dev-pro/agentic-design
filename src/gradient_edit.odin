package agentic_design

import "engine"

import "core:encoding/json"
import "core:math"
import nvg "nanovg"

// On-canvas handles for the gradient being edited in the inspector (ui.grad), as pen.dev
// shows them: a linear gradient's two ends, a radial or angular one's centre and its two
// radii. They follow the geometry of paint.odin and the node's own rotation and flips.

Grad_Handle :: enum {
	None,
	Start,
	End,
	Center,
	Radius_X,
	Radius_Y,
}

grad_edit_target :: proc() -> (n: ^engine.Node, p: engine.Paint, ok: bool) {
	if len(app.sel) != 1 || ui.grad.uid != app.sel[0] || app.editing != 0 do return
	n, _ = engine.doc_find_uid(&app.doc, app.sel[0])
	if n == nil do return
	items := fill_items(n)
	if ui.grad.fill >= len(items) do return
	p = paint_of(items[ui.grad.fill])
	ok = p.kind == .Linear || p.kind == .Radial || p.kind == .Angular
	return
}

// Where the handles are, in the node's untransformed page box.
grad_handles :: proc(n: ^engine.Node, p: engine.Paint) -> (h: [Grad_Handle][2]f32) {
	if p.kind == .Linear {
		rad := p.rotation * math.PI / 180
		dir := [2]f32{-math.sin(rad), -math.cos(rad)}
		a := p.center - dir * p.size.y / 2
		b := p.center + dir * p.size.y / 2
		h[.Start] = {n.x + a.x * n.w, n.y + a.y * n.h}
		h[.End] = {n.x + b.x * n.w, n.y + b.y * n.h}
		return
	}
	c := [2]f32{n.x + p.center.x * n.w, n.y + p.center.y * n.h}
	t := -p.rotation * math.PI / 180
	cs, sn := math.cos(t), math.sin(t)
	h[.Center] = c
	h[.Radius_X] = c + [2]f32{cs, sn} * (p.size.x * n.w / 2)
	h[.Radius_Y] = c + [2]f32{-sn, cs} * (p.size.y * n.h / 2)
	return
}

// The handles in screen space, as drawn.
grad_screen_handles :: proc(n: ^engine.Node, p: engine.Paint) -> (h: [Grad_Handle][2]f32) {
	h = grad_handles(n, p)
	m, tr := engine.node_transform(n)
	for &q, k in h do if k != .None do q = to_screen(engine.xform_point(m, q) if tr else q)
	return
}

grad_handle_under_mouse :: proc() -> Grad_Handle {
	n, p, ok := grad_edit_target()
	if !ok do return .None
	h := grad_screen_handles(n, p)
	for k in Grad_Handle {
		if k == .None || h[k] == {} do continue
		d := app.mouse - h[k]
		if d.x * d.x + d.y * d.y <= 49 do return k
	}
	return .None
}

draw_gradient_handles :: proc(vg: ^nvg.Context) {
	n, p, ok := grad_edit_target()
	if !ok do return
	h := grad_screen_handles(n, p)
	line :: proc(vg: ^nvg.Context, a, b: [2]f32) {
		nvg.BeginPath(vg)
		nvg.MoveTo(vg, a.x, a.y)
		nvg.LineTo(vg, b.x, b.y)
		nvg.StrokeColor(vg, {0, 0, 0, 0.5})
		nvg.StrokeWidth(vg, 3)
		nvg.Stroke(vg)
		nvg.StrokeColor(vg, {1, 1, 1, 1})
		nvg.StrokeWidth(vg, 1.5)
		nvg.Stroke(vg)
	}
	dot :: proc(vg: ^nvg.Context, q: [2]f32, fill: nvg.Color) {
		nvg.BeginPath(vg)
		nvg.Circle(vg, q.x, q.y, 6)
		nvg.FillColor(vg, fill)
		nvg.Fill(vg)
		nvg.StrokeColor(vg, {1, 1, 1, 1})
		nvg.StrokeWidth(vg, 2)
		nvg.Stroke(vg)
		nvg.BeginPath(vg)
		nvg.Circle(vg, q.x, q.y, 7.5)
		nvg.StrokeColor(vg, {0, 0, 0, 0.35})
		nvg.StrokeWidth(vg, 1)
		nvg.Stroke(vg)
	}
	if p.kind == .Linear {
		line(vg, h[.Start], h[.End])
		// the stops along the line
		for k in 0 ..< p.nstops do dot(vg, h[.Start] + (h[.End] - h[.Start]) * p.stops[k].pos, engine.to_nvg(p.stops[k].color))
		return
	}
	line(vg, h[.Center], h[.Radius_X])
	line(vg, h[.Center], h[.Radius_Y])
	dot(vg, h[.Center], engine.to_nvg(p.stops[0].color))
	dot(vg, h[.Radius_X], engine.to_nvg(p.stops[p.nstops - 1].color))
	dot(vg, h[.Radius_Y], engine.to_nvg(p.stops[p.nstops - 1].color))
}

// Moves a handle to a page point: a linear end keeps the other end where it is; the
// centre moves the gradient; a radius sets that radius (and, for the first, the turn).
grad_drag :: proc(handle: Grad_Handle, page: [2]f32) {
	n, p, ok := grad_edit_target()
	if !ok do return
	q := page
	if m, tr := engine.node_transform(n); tr do q = engine.xform_point(engine.xform_inverse(m), q)
	w, h := max(n.w, 1e-3), max(n.h, 1e-3)
	norm := [2]f32{(q.x - n.x) / w, (q.y - n.y) / h}
	hs := grad_handles(n, p)
	center, size, rotation := p.center, p.size, p.rotation
	switch handle {
	case .None:
		return
	case .Start, .End:
		a := [2]f32{(hs[.Start].x - n.x) / w, (hs[.Start].y - n.y) / h}
		b := [2]f32{(hs[.End].x - n.x) / w, (hs[.End].y - n.y) / h}
		if handle == .Start do a = norm
		else do b = norm
		d := b - a
		s := math.sqrt(d.x * d.x + d.y * d.y)
		if s < 1e-3 do return
		center = (a + b) / 2
		size.y = s
		rotation = math.atan2(-d.x / s, -d.y / s) * 180 / math.PI
	case .Center:
		center = norm
	case .Radius_X:
		v := q - hs[.Center]
		size.x = 2 * math.sqrt(v.x * v.x + v.y * v.y) / w
		rotation = -math.atan2(v.y, v.x) * 180 / math.PI
	case .Radius_Y:
		v := q - hs[.Center]
		size.y = 2 * math.sqrt(v.x * v.x + v.y * v.y) / h
	}
	// rounded in f64, so the file gets 0.148 rather than 0.14800000190734863
	r3 :: proc(v: f32) -> json.Value {return json.Float(math.round(f64(v) * 1000) / 1000)}
	out := fill_items(n)
	o := fill_object(out[ui.grad.fill])
	c := make(json.Object, context.temp_allocator)
	c["x"], c["y"] = r3(center.x), r3(center.y)
	o["center"] = c
	sz := make(json.Object, context.temp_allocator)
	sz["width"], sz["height"] = r3(size.x), r3(size.y)
	o["size"] = sz
	if rotation < 0 do rotation += 360
	o["rotation"] = json.Float(math.round(f64(rotation) * 100) / 100)
	out[ui.grad.fill] = o
	fill_store(n, out)
	mark_dirty()
}
