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
MARGIN :: 12 // how far a route keeps from the boxes it goes around
BEND :: 24 // what a bend costs the router, in units of length

Route :: struct {
	pts:    [dynamic][2]f32, // the line as drawn (a curve sampled)
	ctrl:   [4][2]f32, // a curve: start, control 1, control 2, end
	curved: bool,
}

// Where a connector leaves and arrives: the sides and the points on them.
Route_Ends :: struct {
	s0, s1: Anchor,
	p0, p1: [2]f32,
}

connector_ends :: proc(c: Connector, a, b: [4]f32, flat_a, flat_b: bool) -> (e: Route_Ends) {
	e.s0 = c.from if c.from != .Center else facing_side(a, b)
	e.s1 = c.to if c.to != .Center else facing_side(b, a)
	e.p0, e.p1 = side_point(a, e.s0), side_point(b, e.s1)
	d0, d1 := ANCHOR_DIRS[e.s0], ANCHOR_DIRS[e.s1]
	if c.from == .Center && c.to == .Center && d0 == -d1 && len(c.waypoints) == 0 {
		// facing sides that overlap across the flow: a straight line where they overlap,
		// as long as the end can slide along a flat side (a diamond or an ellipse is only
		// touched at its side's middle)
		cx := 1 if d0.y == 0 else 0
		lo, hi := max(a[cx], b[cx]), min(a[cx] + a[cx + 2], b[cx] + b[cx + 2])
		if flat_a && flat_b && hi - lo >= 4 {
			e.p0[cx], e.p1[cx] = (lo + hi) / 2, (lo + hi) / 2
		} else if flat_a && e.p1[cx] >= a[cx] + 2 && e.p1[cx] <= a[cx] + a[cx + 2] - 2 {
			e.p0[cx] = e.p1[cx]
		} else if flat_b && e.p0[cx] >= b[cx] + 2 && e.p0[cx] <= b[cx] + b[cx + 2] - 2 {
			e.p1[cx] = e.p0[cx]
		}
	}
	return
}

// The route between two boxes (page coordinates), before markers trim it. Orthogonal
// routes go around `obstacles` (page boxes) when the plain route would cross one.
connector_route :: proc(c: Connector, a, b: [4]f32, e: Route_Ends, obstacles: [][4]f32) -> (r: Route) {
	r.pts = make([dynamic][2]f32, context.temp_allocator)
	p0, p1 := e.p0, e.p1
	d0, d1 := ANCHOR_DIRS[e.s0], ANCHOR_DIRS[e.s1]
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
		r.ctrl = {p0, p0 + d0 * k, p1 + d1 * k, p1}
		r.curved = true
		for i in 0 ..= 24 do append(&r.pts, bezier_at(r.ctrl, f32(i) / 24))
	case .Orthogonal:
		orthogonal_route(&r.pts, a, b, p0, p1, d0, d1)
		if len(obstacles) > 0 && route_hits(r.pts[:], obstacles) {
			if around, ok := avoid_route(p0, d0, p1, d1, obstacles); ok {
				clear(&r.pts)
				append(&r.pts, ..around[:])
			}
		}
	}
	return
}

bezier_at :: proc(c: [4][2]f32, t: f32) -> [2]f32 {
	u := 1 - t
	return c[0] * (u * u * u) + c[1] * (3 * u * u * t) + c[2] * (3 * u * t * t) + c[3] * (t * t * t)
}

route_hits :: proc(pts: [][2]f32, obstacles: [][4]f32) -> bool {
	for o in obstacles do for i in 1 ..< len(pts) do if seg_crosses_box(pts[i - 1], pts[i], o, 1) do return true
	return false
}

// Whether a segment runs through a box (inset by `inset`: touching an edge is not crossing).
seg_crosses_box :: proc(a, b: [2]f32, box: [4]f32, inset: f32) -> bool {
	lo := [2]f32{box.x + inset, box.y + inset}
	hi := [2]f32{box.x + box[2] - inset, box.y + box[3] - inset}
	if hi.x <= lo.x || hi.y <= lo.y do return false
	t0, t1: f32 = 0, 1
	d := b - a
	ps := [4]f32{-d.x, d.x, -d.y, d.y}
	qs := [4]f32{a.x - lo.x, hi.x - a.x, a.y - lo.y, hi.y - a.y}
	for i in 0 ..< 4 {
		if ps[i] == 0 {
			if qs[i] < 0 do return false
			continue
		}
		t := qs[i] / ps[i]
		if ps[i] < 0 do t0 = max(t0, t)
		else do t1 = min(t1, t)
		if t0 > t1 do return false
	}
	return t1 - t0 > 0.001
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
		if opposite && ahead > 0.5 {
			// facing each other: out, across at the middle, in (closer than two stubs too:
			// a shorter stub rather than a loop)
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
		if toward0 > 0.5 && toward1 > 0.5 {
			append(pts, corner)
		} else {
			mid := [2]f32{q0.x, q1.y} if !h0 else [2]f32{q1.x, q0.y}
			append(pts, q0, mid, q1)
		}
	}
	append(pts, p1)
	simplify_polyline(pts)
}

// An orthogonal route around boxes: the cheapest path (length, plus BEND per bend) on the
// grid of lines MARGIN outside the boxes' edges, the stubs and the lines between them.
avoid_route :: proc(p0, d0, p1, d1: [2]f32, obstacles: [][4]f32) -> (out: [dynamic][2]f32, ok: bool) {
	q0, q1 := p0 + d0 * STUB, p1 + d1 * STUB
	xs := make([dynamic]f32, context.temp_allocator)
	ys := make([dynamic]f32, context.temp_allocator)
	append(&xs, q0.x, q1.x)
	append(&ys, q0.y, q1.y)
	for o in obstacles {
		append(&xs, o.x - MARGIN, o.x + o[2] + MARGIN)
		append(&ys, o.y - MARGIN, o.y + o[3] + MARGIN)
	}
	uniq :: proc(v: ^[dynamic]f32) {
		for i in 1 ..< len(v) {
			for j := i; j > 0 && v[j] < v[j - 1]; j -= 1 do v[j], v[j - 1] = v[j - 1], v[j]
		}
		out := make([dynamic]f32, context.temp_allocator)
		for x, i in v do if i == 0 || x - out[len(out) - 1] > 0.5 do append(&out, x)
		// and the lines halfway between, for gaps narrower than two margins
		n := len(out)
		for i in 1 ..< n do append(&out, (out[i - 1] + out[i]) / 2)
		for i in 1 ..< len(out) {
			for j := i; j > 0 && out[j] < out[j - 1]; j -= 1 do out[j], out[j - 1] = out[j - 1], out[j]
		}
		v^ = out
	}
	uniq(&xs)
	uniq(&ys)
	nx, ny := len(xs), len(ys)
	if nx * ny > 40000 do return
	index :: proc(v: []f32, x: f32) -> int {
		best, bd := 0, max(f32)
		for c, i in v do if abs(c - x) < bd do best, bd = i, abs(c - x)
		return best
	}
	blocked :: proc(p: [2]f32, obstacles: [][4]f32) -> bool {
		m := f32(MARGIN) - 0.5
		for o in obstacles do if p.x > o.x - m && p.x < o.x + o[2] + m && p.y > o.y - m && p.y < o.y + o[3] + m do return true
		return false
	}
	DIRS := [4][2]int{{1, 0}, {0, 1}, {-1, 0}, {0, -1}}
	dir_index :: proc(d: [2]f32) -> int {
		if d.x > 0 do return 0
		if d.y > 0 do return 1
		if d.x < 0 do return 2
		return 3
	}
	sx, sy := index(xs[:], q0.x), index(ys[:], q0.y)
	gx, gy := index(xs[:], q1.x), index(ys[:], q1.y)
	start_dir := dir_index(d0)
	goal_dir := dir_index(-d1)
	states := nx * ny * 4
	cost := make([]f32, states, context.temp_allocator)
	from := make([]i32, states, context.temp_allocator)
	for &c in cost do c = max(f32)
	State :: struct {f: f32, s: i32}
	heap := make([dynamic]State, context.temp_allocator)
	heap_push :: proc(h: ^[dynamic]State, st: State) {
		append(h, st)
		i := len(h) - 1
		for i > 0 {
			p := (i - 1) / 2
			if h[p].f <= h[i].f do break
			h[p], h[i] = h[i], h[p]
			i = p
		}
	}
	heap_pop :: proc(h: ^[dynamic]State) -> State {
		top := h[0]
		last := pop(h)
		if len(h) > 0 {
			h[0] = last
			i := 0
			for {
				l, r := 2 * i + 1, 2 * i + 2
				m := i
				if l < len(h) && h[l].f < h[m].f do m = l
				if r < len(h) && h[r].f < h[m].f do m = r
				if m == i do break
				h[m], h[i] = h[i], h[m]
				i = m
			}
		}
		return top
	}
	sid := i32((sy * nx + sx) * 4 + start_dir)
	cost[sid] = 0
	from[sid] = -1
	heur :: proc(xs, ys: []f32, x, y, gx, gy: int) -> f32 {return abs(xs[x] - xs[gx]) + abs(ys[y] - ys[gy])}
	heap_push(&heap, {heur(xs[:], ys[:], sx, sy, gx, gy), sid})
	found: i32 = -1
	for len(heap) > 0 {
		st := heap_pop(&heap)
		s := int(st.s)
		dir := s % 4
		cell := s / 4
		x, y := cell % nx, cell / nx
		g := cost[s]
		if st.f - heur(xs[:], ys[:], x, y, gx, gy) > g + 0.01 do continue // stale
		if x == gx && y == gy {
			found = st.s
			break
		}
		for nd in 0 ..< 4 {
			if (nd + 2) % 4 == dir do continue // no turning back
			step := DIRS[nd]
			x2, y2 := x + step.x, y + step.y
			if x2 < 0 || y2 < 0 || x2 >= nx || y2 >= ny do continue
			a, b := [2]f32{xs[x], ys[y]}, [2]f32{xs[x2], ys[y2]}
			is_goal := x2 == gx && y2 == gy
			if !is_goal && blocked(b, obstacles) do continue
			if blocked((a + b) / 2, obstacles) do continue
			c := g + abs(b.x - a.x) + abs(b.y - a.y) + (BEND if nd != dir else 0)
			if is_goal && nd != goal_dir do c += BEND
			s2 := i32((y2 * nx + x2) * 4 + nd)
			if c < cost[s2] {
				cost[s2] = c
				from[s2] = st.s
				heap_push(&heap, {c + heur(xs[:], ys[:], x2, y2, gx, gy), s2})
			}
		}
	}
	if found < 0 do return
	rev := make([dynamic][2]f32, context.temp_allocator)
	for s := found; s >= 0; s = from[s] {
		cell := int(s) / 4
		append(&rev, [2]f32{xs[cell % nx], ys[cell / nx]})
	}
	out = make([dynamic][2]f32, context.temp_allocator)
	append(&out, p0)
	for i := len(rev) - 1; i >= 0; i -= 1 do append(&out, rev[i])
	append(&out, p1)
	simplify_polyline(&out)
	return out, true
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
// outlines, as SVG path data relative to the page box it spans, and the route as it runs
// from shape to shape (a curve sampled).
connector_geometry :: proc(c: Connector, a, b: [4]f32, sw: f32, e: Route_Ends, obstacles: [][4]f32) -> (d: string, box: [4]f32, route: [][2]f32) {
	r := connector_route(c, a, b, e, obstacles)
	if len(r.pts) < 2 do return
	full := make([dynamic][2]f32, len(r.pts), context.temp_allocator)
	copy(full[:], r.pts[:])
	route = full[:]
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
	dir_of :: proc(from, to: [2]f32) -> [2]f32 {
		d := to - from
		l := math.sqrt(d.x * d.x + d.y * d.y)
		return d / l if l > 0 else [2]f32{1, 0}
	}
	// the drawn line: the polyline, or the curve's control points
	pts := r.pts
	if r.curved {
		pts = make([dynamic][2]f32, 4, context.temp_allocator)
		for p, i in r.ctrl do pts[i] = p
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
	for p in route do grow(&lo, &hi, p)
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
	if r.curved {
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

// ---------------------------------------------------------------- obstacles

// A box a connector goes around (and lint reports it crossing): a drawn layer (a filled
// or stroked frame or rectangle, an ellipse, a shape, an instance, a filled path) that is
// not a background, and not inside another such box. A background is a box with another
// box inside it that is not its own (a lane, a page's panel): routes cross those by design.
Obstacle :: struct {
	uid: int,
	box: [4]f32,
}

obstacles_by_top: map[int][dynamic]Obstacle
obstacles_version := -1

is_drawn_box :: proc(n: ^Node) -> bool {
	if !n.enabled || n.ghost || n.flow == .Connector || n.flow == .Label || is_shape_outline(n) do return false
	#partial switch n.kind {
	case .Rectangle, .Ellipse, .Ref: return true
	case .Path: return n.has_fill
	case .Frame: return n.flow == .Shape || n.has_fill || n.has_stroke
	}
	return false
}

top_level_of :: proc(doc: ^Document, n: ^Node) -> int {
	cur := n
	for cur != nil && cur.ghost do cur, _ = doc_find_uid(doc, cur.ghost_inst)
	for depth := 0; cur != nil && cur.parent != 0 && depth < MAX_DEPTH; depth += 1 do cur, _ = doc_find_uid(doc, cur.parent)
	return cur.uid if cur != nil else 0
}

// The obstacles of every top-level layer, worked out once per document change.
connector_obstacle_map :: proc(doc: ^Document) -> map[int][dynamic]Obstacle {
	if obstacles_version == doc.version do return obstacles_by_top
	for _, &list in obstacles_by_top do delete(list)
	clear(&obstacles_by_top)
	obstacles_version = doc.version
	cands := make(map[int][dynamic]Obstacle, 16, context.temp_allocator)
	for &n in doc.nodes {
		if n.parent == 0 || !is_drawn_box(&n) do continue
		t := top_level_of(doc, &n)
		list := cands[t] or_else make([dynamic]Obstacle, context.temp_allocator)
		append(&list, Obstacle{n.uid, node_page_box(&n)})
		cands[t] = list
	}
	inside :: proc(a, b: [4]f32) -> bool { // a inside b, and smaller
		return a.x >= b.x - 0.5 && a.y >= b.y - 0.5 && a.x + a[2] <= b.x + b[2] + 0.5 && a.y + a[3] <= b.y + b[3] + 0.5 && a[2] * a[3] < b[2] * b[3]
	}
	for t, list in cands {
		kept := make([dynamic]Obstacle)
		for o in list {
			background := false
			for other in list {
				if other.uid == o.uid || is_descendant(doc, other.uid, o.uid) || is_descendant(doc, o.uid, other.uid) do continue
				if inside(other.box, o.box) {
					background = true
					break
				}
			}
			if background do continue
			// inside another box that counts: that one stands for it
			nested := false
			for other in list {
				if other.uid != o.uid && is_descendant(doc, o.uid, other.uid) {
					bg := false
					for x in list {
						if x.uid == other.uid || is_descendant(doc, x.uid, other.uid) || is_descendant(doc, other.uid, x.uid) do continue
						if inside(x.box, other.box) {bg = true; break}
					}
					if !bg {nested = true; break}
				}
			}
			if !nested do append(&kept, o)
		}
		obstacles_by_top[t] = kept
	}
	return obstacles_by_top
}

// The boxes a connector between `a` and `b` goes around: those on its page, but not its
// ends, the boxes around them or inside them.
connector_obstacles :: proc(doc: ^Document, conn, a, b: ^Node) -> []Obstacle {
	m := connector_obstacle_map(doc)
	out := make([dynamic]Obstacle, context.temp_allocator)
	ra, rb := a, b
	for ra != nil && ra.ghost do ra, _ = doc_find_uid(doc, ra.ghost_inst)
	for rb != nil && rb.ghost do rb, _ = doc_find_uid(doc, rb.ghost_inst)
	if ra == nil || rb == nil do return nil
	for o in m[top_level_of(doc, conn)] {
		if o.uid == ra.uid || o.uid == rb.uid do continue
		if is_descendant(doc, ra.uid, o.uid) || is_descendant(doc, rb.uid, o.uid) || is_descendant(doc, o.uid, ra.uid) || is_descendant(doc, o.uid, rb.uid) do continue
		append(&out, o)
	}
	return out[:]
}

// ---------------------------------------------------------------- the routing pass

// The routes worked out by the last routing pass, by connector uid (page coordinates).
connector_routes: map[int][dynamic][2]f32

// After layout: routes every connector between its two shapes and writes the result into
// its geometry, position and size (when it changed), then places labels on their routes.
// A connector whose end is missing keeps its last route (lint reports it). Connectors that
// leave one flat side of a box, each from the side facing the other end, spread along it.
route_connectors :: proc(doc: ^Document) {
	for _, &pts in connector_routes do delete(pts)
	clear(&connector_routes)
	Job :: struct {
		n:        ^Node,
		c:        Connector,
		a, b:     ^Node,
		ba, bb:   [4]f32,
		e:        Route_Ends,
		fa, fb:   bool,
	}
	jobs := make([dynamic]Job, context.temp_allocator)
	any_label := false
	for &n in doc.nodes {
		if n.flow == .Label do any_label = true
		if n.flow != .Connector do continue
		c, ok := connector_of(&n)
		if !ok do continue
		a, b := resolve_path(doc, c.source), resolve_path(doc, c.target)
		if a == nil || b == nil || a == &n || b == &n do continue
		j := Job{n = &n, c = c, a = a, b = b, ba = node_page_box(a), bb = node_page_box(b), fa = flat_sided(a), fb = flat_sided(b)}
		j.e = connector_ends(c, j.ba, j.bb, j.fa, j.fb)
		append(&jobs, j)
	}
	// ports: connectors leaving (or reaching) the same flat side of a box spread along it,
	// in the order of their other ends, so they do not share a line
	Port :: struct {job, end: int, along: f32}
	ports := make(map[[2]int][dynamic]Port, 8, context.temp_allocator)
	for j, ji in jobs {
		if j.c.routing != .Orthogonal || len(j.c.waypoints) > 0 do continue
		for end in 0 ..< 2 {
			auto := j.c.from == .Center if end == 0 else j.c.to == .Center
			flat := j.fa if end == 0 else j.fb
			if !auto || !flat do continue
			node := j.a if end == 0 else j.b
			side := j.e.s0 if end == 0 else j.e.s1
			other := j.bb if end == 0 else j.ba
			cx := 1 if ANCHOR_DIRS[side].y == 0 else 0
			key := [2]int{node.uid, int(side)}
			list := ports[key] or_else make([dynamic]Port, context.temp_allocator)
			append(&list, Port{ji, end, other[cx] + other[cx + 2] / 2})
			ports[key] = list
		}
	}
	for key, list in ports {
		if len(list) < 2 do continue
		for i in 1 ..< len(list) {
			for k := i; k > 0 && list[k].along < list[k - 1].along; k -= 1 do list[k], list[k - 1] = list[k - 1], list[k]
		}
		j0 := &jobs[list[0].job]
		box := j0.ba if list[0].end == 0 else j0.bb
		side := Anchor(key[1])
		cx := 1 if ANCHOR_DIRS[side].y == 0 else 0
		length := box[cx + 2]
		gap := min(length * 0.8 / f32(len(list)), 24)
		mid := box[cx] + length / 2
		for p, i in list {
			pos := mid + (f32(i) - f32(len(list) - 1) / 2) * gap
			j := &jobs[p.job]
			if p.end == 0 do j.e.p0[cx] = pos
			else do j.e.p1[cx] = pos
		}
	}
	for &j in jobs {
		obs := connector_obstacles(doc, j.n, j.a, j.b)
		boxes := make([dynamic][4]f32, 0, len(obs), context.temp_allocator)
		// only those near the two ends matter
		lo := [2]f32{min(j.ba.x, j.bb.x) - 200, min(j.ba.y, j.bb.y) - 200}
		hi := [2]f32{max(j.ba.x + j.ba[2], j.bb.x + j.bb[2]) + 200, max(j.ba.y + j.ba[3], j.bb.y + j.bb[3]) + 200}
		for o in obs do if o.box.x < hi.x && o.box.x + o.box[2] > lo.x && o.box.y < hi.y && o.box.y + o.box[3] > lo.y do append(&boxes, o.box)
		d, box, route := connector_geometry(j.c, j.ba, j.bb, j.n.stroke_width, j.e, boxes[:])
		if d == "" do continue
		kept := make([dynamic][2]f32, len(route))
		copy(kept[:], route)
		connector_routes[j.n.uid] = kept
		ox, oy: f32
		if p, _ := doc_find_uid(doc, j.n.parent); p != nil do ox, oy = p.x, p.y
		set_connector_box(doc, j.n, d, box, {ox, oy})
	}
	if !any_label do return
	place_labels(doc)
}

// Each label centred on its connector at `at` along it, or, when that spot is on another
// connector's line or on a box, at the nearest free spot along its own line.
place_labels :: proc(doc: ^Document) {
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
		obs: []Obstacle
		if c, ok := connector_of(target); ok {
			a, b := resolve_path(doc, c.source), resolve_path(doc, c.target)
			if a != nil && b != nil do obs = connector_obstacles(doc, target, a, b)
		}
		free :: proc(box: [4]f32, own: int, obs: []Obstacle) -> bool {
			for uid, other in connector_routes {
				if uid == own do continue
				for i in 1 ..< len(other) do if seg_crosses_box(other[i - 1], other[i], box, 0) do return false
			}
			for ob in obs {
				if box.x < ob.box.x + ob.box[2] && ob.box.x < box.x + box[2] && box.y < ob.box.y + ob.box[3] && ob.box.y < box.y + box[3] do return false
			}
			return true
		}
		mid := point_along(route[:], at)
		for delta in ([?]f32{0, -0.12, 0.12, -0.24, 0.24, -0.36, 0.36}) {
			t := at + delta
			if t < 0.05 || t > 0.95 do continue
			p := point_along(route[:], t)
			if free({p.x - n.w / 2, p.y - n.h / 2, n.w, n.h}, target.uid, obs) {
				mid = p
				break
			}
		}
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
