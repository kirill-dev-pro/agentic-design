package engine

import "core:encoding/json"
import "core:math"
import "core:strings"

// Connectors (D54, D55). pen.dev 1.2.21 drops the schema's own `connection` nodes and every
// property it does not know when it loads a file; only `metadata` survives. So a connector
// is a plain stroked `path` that pen.dev draws as last saved, its geometry the route, and the
// live part sits in its metadata:
//
//   {"type": "connector", "source": {"path": "box-a", "anchor": "center"},
//    "target": {"path": "frame/box-b", "anchor": "left"}, "routing": "orthogonal",
//    "waypoints": [[x, y], ...], "startMarker": "none", "endMarker": "arrow"}
//
// `path` and `anchor` are the schema's ConnectionEndpoint (an id path, slash-separated
// through instances; center, top, right, bottom or left). After each layout the routing pass
// works out the route between the two shapes' boxes as drawn and writes it back into the
// path's geometry, position and size, so a connector follows its shapes and the saved file
// shows the current picture. Markers are drawn into the geometry as outlines too (pen.dev
// shows them as such); the app fills the closed ones. A label is a frame with a text inside
// and `metadata {"type": "connection-label", "connection": <id>, "at": 0..1}`, kept centred
// on the route at that fraction of its length.

Flow_Role :: enum u8 {
	None,
	Connector,
	Label,
	Shape,
}

Anchor :: enum u8 {
	Center,
	Top,
	Right,
	Bottom,
	Left,
}

Marker :: enum u8 {
	None,
	Arrow,
	Open_Arrow,
	Circle,
	Diamond,
	Bar,
}

Routing :: enum u8 {
	Orthogonal,
	Straight,
	Curved,
}

ANCHOR_NAMES := [Anchor]string {
	.Center = "center",
	.Top    = "top",
	.Right  = "right",
	.Bottom = "bottom",
	.Left   = "left",
}

MARKER_NAMES := [Marker]string {
	.None       = "none",
	.Arrow      = "arrow",
	.Open_Arrow = "open_arrow",
	.Circle     = "circle",
	.Diamond    = "diamond",
	.Bar        = "bar",
}

ROUTING_NAMES := [Routing]string {
	.Orthogonal = "orthogonal",
	.Straight   = "straight",
	.Curved     = "curved",
}

Connector :: struct {
	source, target: string, // id paths
	from, to:       Anchor,
	routing:        Routing,
	start, end:     Marker,
	waypoints:      [][2]f32, // page coordinates
}

// The role metadata gives a layer: connector, connector label or shape with text.
flow_role :: proc(v: json.Value) -> Flow_Role {
	o, ok := v.(json.Object)
	if !ok do return .None
	switch string(o["type"].(json.String) or_else "") {
	case "connector": return .Connector
	case "connection-label": return .Label
	case "shape": return .Shape
	}
	return .None
}

anchor_from :: proc(s: string) -> (Anchor, bool) {
	for name, a in ANCHOR_NAMES do if name == s do return a, true
	return .Center, false
}

marker_from :: proc(s: string) -> (Marker, bool) {
	for name, m in MARKER_NAMES do if name == s do return m, true
	return .None, false
}

routing_from :: proc(s: string) -> (Routing, bool) {
	for name, r in ROUTING_NAMES do if name == s do return r, true
	return .Orthogonal, false
}

// The connector a layer's metadata describes (strings live in the temp allocator).
connector_of :: proc(n: ^Node) -> (c: Connector, ok: bool) {
	v, has := prop_value(n, "metadata")
	if !has do return
	o, is_obj := v.(json.Object)
	if !is_obj || string(o["type"].(json.String) or_else "") != "connector" do return
	end :: proc(v: json.Value) -> (path: string, a: Anchor) {
		o, _ := v.(json.Object)
		path = string(o["path"].(json.String) or_else "")
		a, _ = anchor_from(string(o["anchor"].(json.String) or_else "center"))
		return
	}
	c.source, c.from = end(o["source"])
	c.target, c.to = end(o["target"])
	c.routing, _ = routing_from(string(o["routing"].(json.String) or_else ""))
	c.start, _ = marker_from(string(o["startMarker"].(json.String) or_else ""))
	c.end, _ = marker_from(string(o["endMarker"].(json.String) or_else ""))
	if arr, is_arr := o["waypoints"].(json.Array); is_arr {
		wps := make([dynamic][2]f32, context.temp_allocator)
		for w in arr {
			p, is_p := w.(json.Array)
			if !is_p || len(p) != 2 do continue
			append(&wps, [2]f32{json_f32(p[0]), json_f32(p[1])})
		}
		c.waypoints = wps[:]
	}
	return c, c.source != "" && c.target != ""
}

json_f32 :: proc(v: json.Value) -> f32 {
	#partial switch x in v {
	case json.Float: return f32(x)
	case json.Integer: return f32(x)
	}
	return 0
}

// The layer an endpoint's id path names: "id", or "instance/child/..." for a layer inside
// an instance (its copy there). nil when it does not exist.
resolve_path :: proc(doc: ^Document, path: string) -> ^Node {
	parts := strings.split(path, "/", context.temp_allocator)
	if len(parts) == 0 || parts[0] == "" do return nil
	cur, _ := doc_find(doc, parts[0])
	for part in parts[1:] {
		if cur == nil do return nil
		if cur.kind == .Ref {
			inst := cur.uid
			cur = nil
			for &g in doc.ghosts {
				if g.ghost_inst == inst && g.ghost_of == part {
					cur = &g
					break
				}
			}
		} else {
			cur, _ = doc_find(doc, part)
		}
	}
	return cur
}

ANCHOR_DIRS := [Anchor][2]f32 {
	.Center = {0, 0},
	.Top    = {0, -1},
	.Right  = {1, 0},
	.Bottom = {0, 1},
	.Left   = {-1, 0},
}

// The side a "center" end leaves from: the one facing the other box.
facing_side :: proc(a, b: [4]f32) -> Anchor {
	ca := [2]f32{a.x + a[2] / 2, a.y + a[3] / 2}
	cb := [2]f32{b.x + b[2] / 2, b.y + b[3] / 2}
	d := cb - ca
	// compare the gaps between the boxes, so wide boxes side by side still join sideways
	gx := max(b.x - (a.x + a[2]), a.x - (b.x + b[2]))
	gy := max(b.y - (a.y + a[3]), a.y - (b.y + b[3]))
	horizontal := gx > gy if (gx > 0 || gy > 0) else abs(d.x) >= abs(d.y)
	if horizontal do return .Right if d.x >= 0 else .Left
	return .Bottom if d.y >= 0 else .Top
}

side_point :: proc(b: [4]f32, s: Anchor) -> [2]f32 {
	switch s {
	case .Top: return {b.x + b[2] / 2, b.y}
	case .Right: return {b.x + b[2], b.y + b[3] / 2}
	case .Bottom: return {b.x + b[2] / 2, b.y + b[3]}
	case .Left: return {b.x, b.y + b[3] / 2}
	case .Center:
	}
	return {b.x + b[2] / 2, b.y + b[3] / 2}
}

STUB :: 16 // how far an orthogonal route runs straight out of a side

Route :: struct {
	pts:    [dynamic][2]f32, // polyline, or for a curve: start, control 1, control 2, end
	curved: bool,
}

// The route between two boxes (page coordinates), before markers trim it.
connector_route :: proc(c: Connector, a, b: [4]f32, flat_a, flat_b: bool) -> (r: Route) {
	r.pts = make([dynamic][2]f32, context.temp_allocator)
	s0 := c.from if c.from != .Center else facing_side(a, b)
	s1 := c.to if c.to != .Center else facing_side(b, a)
	p0, p1 := side_point(a, s0), side_point(b, s1)
	d0, d1 := ANCHOR_DIRS[s0], ANCHOR_DIRS[s1]
	if c.from == .Center && c.to == .Center && d0 == -d1 && len(c.waypoints) == 0 {
		// facing sides that overlap across the flow: a straight line where they overlap,
		// as long as the end can slide along a flat side (a diamond or an ellipse is only
		// touched at its side's middle)
		cx := 1 if d0.y == 0 else 0
		lo, hi := max(a[cx], b[cx]), min(a[cx] + a[cx + 2], b[cx] + b[cx + 2])
		if flat_a && flat_b && hi - lo >= 4 {
			p0[cx], p1[cx] = (lo + hi) / 2, (lo + hi) / 2
		} else if flat_a && p1[cx] >= a[cx] + 2 && p1[cx] <= a[cx] + a[cx + 2] - 2 {
			p0[cx] = p1[cx]
		} else if flat_b && p0[cx] >= b[cx] + 2 && p0[cx] <= b[cx] + b[cx + 2] - 2 {
			p1[cx] = p0[cx]
		}
	}
	if len(c.waypoints) > 0 {
		append(&r.pts, p0)
		append(&r.pts, ..c.waypoints)
		append(&r.pts, p1)
		return
	}
	switch c.routing {
	case .Straight:
		append(&r.pts, p0, p1)
	case .Curved:
		k := max(math.sqrt((p1.x - p0.x) * (p1.x - p0.x) + (p1.y - p0.y) * (p1.y - p0.y)) / 3, 24)
		append(&r.pts, p0, p0 + d0 * k, p1 + d1 * k, p1)
		r.curved = true
	case .Orthogonal:
		orthogonal_route(&r.pts, a, b, p0, p1, d0, d1)
	}
	return
}

orthogonal_route :: proc(pts: ^[dynamic][2]f32, a, b: [4]f32, p0, p1, d0, d1: [2]f32) {
	q0, q1 := p0 + d0 * STUB, p1 + d1 * STUB
	h0, h1 := d0.y == 0, d1.y == 0 // leaves along x
	append(pts, p0)
	if h0 == h1 {
		ax := 0 if h0 else 1 // the axis both ends run along
		cx := 1 - ax
		opposite := d0[ax] == -d1[ax]
		ahead := (p1[ax] - p0[ax]) * d0[ax] // how far the target is in front of the start
		if opposite && ahead >= 2 * STUB {
			// facing each other: out, across at the middle, in
			m := (p0[ax] + p1[ax]) / 2
			k0, k1: [2]f32
			k0[ax], k0[cx] = m, p0[cx]
			k1[ax], k1[cx] = m, p1[cx]
			append(pts, k0, k1)
		} else if !opposite {
			// both sides face the same way: out past the farther one, across, back in
			far := max(q0[ax] * d0[ax], q1[ax] * d0[ax]) * d0[ax]
			k0, k1: [2]f32
			k0[ax], k0[cx] = far, p0[cx]
			k1[ax], k1[cx] = far, p1[cx]
			append(pts, k0, k1)
		} else {
			// the target is behind: out, around between the boxes (or past both), in
			lo0, hi0 := a[cx], a[cx] + a[cx + 2]
			lo1, hi1 := b[cx], b[cx] + b[cx + 2]
			m: f32
			if hi0 + STUB <= lo1 do m = (hi0 + lo1) / 2
			else if hi1 + STUB <= lo0 do m = (hi1 + lo0) / 2
			else do m = max(hi0, hi1) + STUB
			k0, k1: [2]f32
			k0[ax], k0[cx] = q0[ax], m
			k1[ax], k1[cx] = q1[ax], m
			append(pts, q0, k0, k1, q1)
		}
	} else {
		// one runs along x, the other along y: one bend where they meet, if both ends
		// run towards it; otherwise out of both and a bend between
		corner := [2]f32{p1.x, p0.y} if h0 else [2]f32{p0.x, p1.y}
		toward0 := (corner - p0).x * d0.x + (corner - p0).y * d0.y
		toward1 := (corner - p1).x * d1.x + (corner - p1).y * d1.y
		if toward0 >= STUB && toward1 >= STUB {
			append(pts, corner)
		} else {
			mid := [2]f32{q0.x, q1.y} if !h0 else [2]f32{q1.x, q0.y}
			append(pts, q0, mid, q1)
		}
	}
	append(pts, p1)
	simplify_polyline(pts)
}

// Drops repeated points and points on a straight run.
simplify_polyline :: proc(pts: ^[dynamic][2]f32) {
	i := 1
	for i < len(pts) {
		if abs(pts[i].x - pts[i - 1].x) < 0.01 && abs(pts[i].y - pts[i - 1].y) < 0.01 {
			ordered_remove(pts, i)
			continue
		}
		i += 1
	}
	i = 1
	for i + 1 < len(pts) {
		a, b, c := pts[i - 1], pts[i], pts[i + 1]
		cross := (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
		if abs(cross) < 0.01 {
			ordered_remove(pts, i)
			continue
		}
		i += 1
	}
}

// Marker size for a stroke width: the length of an arrowhead and its half width.
marker_size :: proc(sw: f32) -> (length, half: f32) {
	length = 3 * max(sw, 1) + 5
	return length, length * 0.5
}

// The geometry of a connector: the route (trimmed under filled markers) and the marker
// outlines, as SVG path data relative to `origin`, and the page box it spans.
connector_geometry :: proc(c: Connector, a, b: [4]f32, sw: f32, flat_a := true, flat_b := true) -> (d: string, box: [4]f32, route: [][2]f32) {
	r := connector_route(c, a, b, flat_a, flat_b)
	if len(r.pts) < 2 do return
	length, half := marker_size(sw)
	marks := make([dynamic][dynamic][2]f32, context.temp_allocator) // outlines
	closed := make([dynamic]bool, context.temp_allocator)
	head :: proc(m: Marker, tip, dir: [2]f32, length, half: f32, marks: ^[dynamic][dynamic][2]f32, closed: ^[dynamic]bool) -> (base: [2]f32) {
		perp := [2]f32{-dir.y, dir.x}
		base = tip
		poly := make([dynamic][2]f32, context.temp_allocator)
		is_closed := true
		switch m {
		case .None: return
		case .Arrow:
			base = tip - dir * length
			append(&poly, base + perp * half, tip, base - perp * half)
		case .Open_Arrow:
			back := tip - dir * length
			append(&poly, back + perp * half, tip, back - perp * half)
			is_closed = false
		case .Diamond:
			base = tip - dir * length * 1.6
			mid := tip - dir * length * 0.8
			append(&poly, tip, mid + perp * half, base, mid - perp * half)
		case .Circle:
			rad := half
			ctr := tip - dir * rad
			base = tip - dir * rad * 2
			for k in 0 ..< 16 {
				t := f32(k) / 16 * 2 * math.PI
				append(&poly, ctr + [2]f32{math.cos(t), math.sin(t)} * rad)
			}
		case .Bar:
			append(&poly, tip + perp * half, tip - perp * half)
			is_closed = false
		}
		append(marks, poly)
		append(closed, is_closed)
		return
	}
	pts := r.pts
	dir_of :: proc(from, to: [2]f32) -> [2]f32 {
		d := to - from
		l := math.sqrt(d.x * d.x + d.y * d.y)
		return d / l if l > 0 else [2]f32{1, 0}
	}
	last := len(pts) - 1
	if c.end != .None do pts[last] = head(c.end, pts[last], dir_of(pts[last - 1], pts[last]), length, half, &marks, &closed)
	if c.start != .None do pts[0] = head(c.start, pts[0], dir_of(pts[1], pts[0]), length, half, &marks, &closed)

	lo, hi := pts[0], pts[0]
	grow :: proc(lo, hi: ^[2]f32, p: [2]f32) {
		lo^ = {min(lo.x, p.x), min(lo.y, p.y)}
		hi^ = {max(hi.x, p.x), max(hi.y, p.y)}
	}
	for p in pts do grow(&lo, &hi, p)
	for m in marks do for p in m do grow(&lo, &hi, p)
	pad := max(sw, 1)
	lo -= pad
	hi += pad
	box = {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y}
	sb := strings.builder_make(context.temp_allocator)
	pt :: proc(b: ^strings.Builder, cmd: string, p, lo: [2]f32) {
		strings.write_string(b, cmd)
		strings.write_string(b, num_text(p.x - lo.x))
		strings.write_byte(b, ' ')
		strings.write_string(b, num_text(p.y - lo.y))
	}
	pt(&sb, "M", pts[0], lo)
	if r.curved && len(pts) == 4 {
		pt(&sb, "C", pts[1], lo)
		pt(&sb, " ", pts[2], lo)
		pt(&sb, " ", pts[3], lo)
	} else {
		for p in pts[1:] do pt(&sb, "L", p, lo)
	}
	for m, i in marks {
		if len(m) == 0 do continue
		pt(&sb, "M", m[0], lo)
		for p in m[1:] do pt(&sb, "L", p, lo)
		if closed[i] do strings.write_string(&sb, "Z")
	}
	d = strings.to_string(sb)
	route = pts[:]
	if c.end != .None || c.start != .None {
		// the route as it reaches the shapes, for labels and lint
		full := connector_route(c, a, b, flat_a, flat_b)
		route = full.pts[:]
	}
	return
}

// Whether a connector end may slide along the sides of this layer's box: boxes yes; an
// ellipse, a diamond, a path or a turned layer only at its sides' middles.
flat_sided :: proc(n: ^Node) -> bool {
	if n.rotation != 0 do return false
	#partial switch n.kind {
	case .Ellipse, .Path, .Other: return false
	case .Frame:
		if n.flow == .Shape {
			k, _ := shape_of(n)
			return k == .Capsule
		}
	}
	return true
}

// The point at fraction `at` (0..1) along a polyline.
point_along :: proc(pts: [][2]f32, at: f32) -> [2]f32 {
	if len(pts) == 0 do return {}
	total: f32
	for i in 1 ..< len(pts) do total += seg_len(pts[i - 1], pts[i])
	want := clamp(at, 0, 1) * total
	for i in 1 ..< len(pts) {
		l := seg_len(pts[i - 1], pts[i])
		if want <= l && l > 0 do return pts[i - 1] + (pts[i] - pts[i - 1]) * (want / l)
		want -= l
	}
	return pts[len(pts) - 1]
}

seg_len :: proc(a, b: [2]f32) -> f32 {
	return math.sqrt((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y))
}

// The routes worked out by the last routing pass, by connector uid (page coordinates).
connector_routes: map[int][dynamic][2]f32

// After layout: routes every connector between its two shapes and writes the result into
// its geometry, position and size (when it changed), then centres labels on their routes.
// A connector whose end is missing keeps its last route (lint reports it).
route_connectors :: proc(doc: ^Document) {
	for _, &pts in connector_routes do delete(pts)
	clear(&connector_routes)
	any_label := false
	for &n in doc.nodes {
		if n.flow == .Label do any_label = true
		if n.flow != .Connector do continue
		c, ok := connector_of(&n)
		if !ok do continue
		a, b := resolve_path(doc, c.source), resolve_path(doc, c.target)
		if a == nil || b == nil || a == &n || b == &n do continue
		d, box, route := connector_geometry(c, node_page_box(a), node_page_box(b), n.stroke_width, flat_sided(a), flat_sided(b))
		if d == "" do continue
		kept := make([dynamic][2]f32, len(route))
		copy(kept[:], route)
		connector_routes[n.uid] = kept
		ox, oy: f32
		if p, _ := doc_find_uid(doc, n.parent); p != nil do ox, oy = p.x, p.y
		set_connector_box(doc, &n, d, box, {ox, oy})
	}
	if !any_label do return
	for &n in doc.nodes {
		if n.flow != .Label do continue
		v, _ := prop_value(&n, "metadata")
		o, _ := v.(json.Object)
		target, _ := doc_find(doc, string(o["connection"].(json.String) or_else ""))
		if target == nil do continue
		route, has := connector_routes[target.uid]
		if !has do continue
		at: f32 = 0.5
		if f, is_f := o["at"].(json.Float); is_f do at = f32(f)
		if i, is_i := o["at"].(json.Integer); is_i do at = f32(i)
		mid := point_along(route[:], at)
		ox, oy: f32
		if p, _ := doc_find_uid(doc, n.parent); p != nil do ox, oy = p.x, p.y
		x, y := round2(mid.x - n.w / 2), round2(mid.y - n.h / 2)
		if abs(x - n.x) >= 0.01 || abs(y - n.y) >= 0.01 {
			node_set_raw(&n, "x", num_text(x - ox))
			node_set_raw(&n, "y", num_text(y - oy))
			node_refresh(doc, &n)
			arrange(doc, &n, x, y, n.w, n.h, 1)
		}
	}
}

// Writes a connector's route into its layer, only what changed (each write is a document
// change that the next save keeps).
set_connector_box :: proc(doc: ^Document, n: ^Node, d: string, box: [4]f32, origin: [2]f32) {
	x, y := num_text(box.x - origin.x), num_text(box.y - origin.y)
	w, h := num_text(box[2]), num_text(box[3])
	vb := strings.concatenate({"[0,0,", w, ",", h, "]"}, context.temp_allocator)
	gb := strings.builder_make(context.temp_allocator)
	json_write_string(&gb, d)
	geometry := strings.to_string(gb)
	changed := false
	set :: proc(n: ^Node, key, raw: string, changed: ^bool) {
		if prop_raw(n, key) == raw do return
		node_set_raw(n, key, raw)
		changed^ = true
	}
	set(n, "x", x, &changed)
	set(n, "y", y, &changed)
	set(n, "width", w, &changed)
	set(n, "height", h, &changed)
	set(n, "viewBox", vb, &changed)
	set(n, "geometry", geometry, &changed)
	if changed do node_refresh(doc, n)
	n.x, n.y, n.w, n.h = box.x, box.y, box[2], box[3]
}

// Deletes layers as the user (or an agent) deletes them: with the connectors attached to
// them and the labels of every connector that goes. One pass over the connectors, so a
// batch deleting thousands of layers costs no more than before (D43).
doc_delete_layers :: proc(doc: ^Document, uids: []int) {
	doomed := make(map[int]bool, len(uids), context.temp_allocator)
	for uid in uids do doomed[uid] = true
	all := make([dynamic]int, context.temp_allocator)
	append(&all, ..uids)
	gone_ids := make(map[string]bool, 8, context.temp_allocator)
	in_doomed :: proc(doc: ^Document, n: ^Node, doomed: map[int]bool) -> bool {
		cur := n
		for depth := 0; cur != nil && depth < MAX_DEPTH; depth += 1 {
			if cur.uid in doomed do return true
			if cur.ghost {
				cur, _ = doc_find_uid(doc, cur.ghost_inst)
				continue
			}
			if cur.parent == 0 do return false
			cur, _ = doc_find_uid(doc, cur.parent)
		}
		return false
	}
	has_labels := false
	for &n in doc.nodes {
		if n.flow == .Label do has_labels = true
		if n.flow != .Connector do continue
		goes := in_doomed(doc, &n, doomed)
		if !goes {
			if c, ok := connector_of(&n); ok {
				for path in ([2]string{c.source, c.target}) {
					if e := resolve_path(doc, path); e != nil && in_doomed(doc, e, doomed) {
						goes = true
						break
					}
				}
			}
			if goes do append(&all, n.uid)
		}
		if goes do gone_ids[n.id] = true
	}
	if has_labels && len(gone_ids) > 0 {
		for &n in doc.nodes {
			if n.flow != .Label do continue
			v, _ := prop_value(&n, "metadata")
			o, _ := v.(json.Object)
			if string(o["connection"].(json.String) or_else "") in gone_ids do append(&all, n.uid)
		}
	}
	for uid in all do if n, _ := doc_find_uid(doc, uid); n != nil do doc_delete(doc, uid)
}

// SVG path data of a connector's filled markers (its closed subpaths), in its geometry's
// coordinates; "" for any other layer.
connector_heads_d :: proc(n: ^Node) -> string {
	if n.flow != .Connector || !n.has_stroke do return ""
	sb := strings.builder_make(context.temp_allocator)
	start := -1
	for c, i in n.cmds {
		if c.kind == .Move do start = i
		if c.kind != .Close || start < 0 do continue
		for k in start ..= i {
			cc := n.cmds[k]
			#partial switch cc.kind {
			case .Move, .Line:
				strings.write_string(&sb, "M" if cc.kind == .Move else "L")
				strings.write_string(&sb, num_text(cc.p[2].x))
				strings.write_byte(&sb, ' ')
				strings.write_string(&sb, num_text(cc.p[2].y))
			case .Close:
				strings.write_byte(&sb, 'Z')
			}
		}
		start = -1
	}
	return strings.to_string(sb)
}

// ---------------------------------------------------------------- shapes with text (D57)

// A frame with `metadata {"type": "shape", "shape": "diamond" | "ellipse" | "capsule",
// "inset"?: 8}` holds its text inside the shape: the layout gives it the padding that puts
// its content in the shape's inscribed box (a diamond's middle half, an ellipse's 71 %, a
// capsule's middle between its round ends), and a frame that fits its content grows to
// hold it. The outline is a child with `metadata {"type": "shape-outline"}` (a path for a
// diamond, an ellipse for an ellipse; a capsule is the frame's own fill and corner radius),
// kept the frame's size. The padding, the outline and the corner radius are written into
// the file as plain .pen, so pen.dev shows the same picture as last saved.

Shape_Kind :: enum u8 {
	Diamond,
	Ellipse,
	Capsule,
}

SHAPE_NAMES := [Shape_Kind]string {
	.Diamond = "diamond",
	.Ellipse = "ellipse",
	.Capsule = "capsule",
}

shape_from :: proc(s: string) -> (Shape_Kind, bool) {
	for name, k in SHAPE_NAMES do if name == s do return k, true
	return .Diamond, false
}

shape_of :: proc(n: ^Node) -> (kind: Shape_Kind, inset: f32) {
	inset = 8
	v, _ := prop_value(n, "metadata")
	o, _ := v.(json.Object)
	kind, _ = shape_from(string(o["shape"].(json.String) or_else ""))
	if i, has := o["inset"]; has do inset = json_f32(i)
	return
}

// The share of the width and height the inscribed box takes.
shape_fraction :: proc(k: Shape_Kind) -> [2]f32 {
	switch k {
	case .Diamond: return {0.5, 0.5}
	case .Ellipse: return {0.7071, 0.7071}
	case .Capsule: return {1, 1}
	}
	return {1, 1}
}

// Measures a shape frame: sets its padding for the size it gets and returns that size.
measure_shape :: proc(doc: ^Document, n: ^Node, own: [2]f32, depth: int) -> [2]f32 {
	kind, inset := shape_of(n)
	f := shape_fraction(kind)
	inner := [2]f32{-1, -1}
	for i in 0 ..< 2 do if own[i] >= 0 do inner[i] = max(own[i] * f[i] - 2 * inset, 0)
	if kind == .Capsule && own.x >= 0 && own.y >= 0 do inner.x = max(own.x - own.y - 2 * inset, 0)
	n.padding = {}
	cs := measure_children(doc, n, inner, depth)
	size: [2]f32
	for i in 0 ..< 2 do size[i] = own[i] if own[i] >= 0 else (cs[i] + 2 * inset) / f[i]
	if kind == .Capsule && own.x < 0 do size.x = cs.x + 2 * inset + size.y
	pad := [2]f32{(size.x - size.x * f.x) / 2 + inset, (size.y - size.y * f.y) / 2 + inset}
	if kind == .Capsule do pad.x = size.y / 2 + inset
	n.padding = {pad.y, pad.x, pad.y, pad.x}
	return size
}

// After layout: each shape's padding (and a capsule's radius) and its outline, written
// into the file when they changed.
fit_shapes :: proc(doc: ^Document) {
	for &n in doc.nodes {
		if n.flow != .Shape || n.ghost do continue
		kind, _ := shape_of(&n)
		p := n.padding
		raw := strings.concatenate({"[", num_text(p[0]), ",", num_text(p[1]), ",", num_text(p[2]), ",", num_text(p[3]), "]"}, context.temp_allocator)
		pad := n.padding
		if prop_raw(&n, "padding") != raw {
			node_set_raw(&n, "padding", raw)
			node_refresh(doc, &n)
		}
		n.padding = pad
		if kind == .Capsule {
			r := num_text(n.h / 2)
			if prop_raw(&n, "cornerRadius") != r {
				node_set_raw(&n, "cornerRadius", r)
				node_refresh(doc, &n)
				n.padding = pad
			}
			continue
		}
		for cu in children_of(doc, n.uid) {
			c, _ := doc_find_uid(doc, cu)
			if c == nil || !is_shape_outline(c) do continue
			w, h := num_text(n.w), num_text(n.h)
			changed := false
			set :: proc(n: ^Node, key, raw: string, changed: ^bool) {
				if prop_raw(n, key) == raw do return
				node_set_raw(n, key, raw)
				changed^ = true
			}
			set(c, "x", "0", &changed)
			set(c, "y", "0", &changed)
			set(c, "width", w, &changed)
			set(c, "height", h, &changed)
			if c.kind == .Path {
				d := strings.concatenate({"M", num_text(n.w / 2), " 0L", w, " ", num_text(n.h / 2), "L", num_text(n.w / 2), " ", h, "L0 ", num_text(n.h / 2), "Z"}, context.temp_allocator)
				gb := strings.builder_make(context.temp_allocator)
				json_write_string(&gb, d)
				set(c, "geometry", strings.to_string(gb), &changed)
				set(c, "viewBox", strings.concatenate({"[0,0,", w, ",", h, "]"}, context.temp_allocator), &changed)
			}
			if changed do node_refresh(doc, c)
			c.x, c.y, c.w, c.h = n.x, n.y, n.w, n.h
			break
		}
	}
}

is_shape_outline :: proc(n: ^Node) -> bool {
	i := prop_index(n, "metadata")
	return i >= 0 && strings.contains(n.props[i].raw, `"shape-outline"`)
}
