package engine

import "core:fmt"
import "core:math"
import "core:strings"
import nvg "../nanovg"

// Drawing a document with NanoVG: transforms, the node tree, boxes, text and paints. The
// caller sets up the frame (transform, scissor) and the view state below.

// ---------------------------------------------------------------- transforms

// An affine transform as NanoVG stores it: x' = a x + c y + e, y' = b x + d y + f.
Xform :: [6]f32

XFORM_IDENTITY :: Xform{1, 0, 0, 1, 0, 0}

// a · b: b applies first.
xform_mul :: proc(a, b: Xform) -> Xform {
	return {
		a[0] * b[0] + a[2] * b[1],
		a[1] * b[0] + a[3] * b[1],
		a[0] * b[2] + a[2] * b[3],
		a[1] * b[2] + a[3] * b[3],
		a[0] * b[4] + a[2] * b[5] + a[4],
		a[1] * b[4] + a[3] * b[5] + a[5],
	}
}

xform_inverse :: proc(m: Xform) -> Xform {
	det := m[0] * m[3] - m[1] * m[2]
	if abs(det) < 1e-12 do return XFORM_IDENTITY
	a, b, c, d := m[3] / det, -m[1] / det, -m[2] / det, m[0] / det
	return {a, b, c, d, -(a * m[4] + c * m[5]), -(b * m[4] + d * m[5])}
}

xform_point :: proc(m: Xform, p: [2]f32) -> [2]f32 {
	return {m[0] * p.x + m[2] * p.y + m[4], m[1] * p.x + m[3] * p.y + m[5]}
}

// Where a node's untransformed page box is drawn: its own rotation and flips and those
// of its ancestors, each around that node's top-left corner (as draw_node_tree applies
// them).
node_transform :: proc(n: ^Node) -> (m: Xform, transformed: bool) {
	chain: [MAX_DEPTH]^Node
	count := 0
	for cur := n; cur != nil && count < MAX_DEPTH; {
		chain[count] = cur
		count += 1
		if cur.parent == 0 do break
		cur, _ = doc_find_uid(current, cur.parent)
	}
	m = XFORM_IDENTITY
	for i := count - 1; i >= 0; i -= 1 {
		a := chain[i]
		if a.rotation == 0 && !a.flip_x && !a.flip_y do continue
		transformed = true
		t := -a.rotation * math.PI / 180
		cs, sn := math.cos(t), math.sin(t)
		sx: f32 = -1 if a.flip_x else 1
		sy: f32 = -1 if a.flip_y else 1
		// T(x, y) · R · S · T(-x, -y)
		local := Xform{cs * sx, sn * sx, -sn * sy, cs * sy, 0, 0}
		local[4] = a.x - (local[0] * a.x + local[2] * a.y)
		local[5] = a.y - (local[1] * a.x + local[3] * a.y)
		m = xform_mul(m, local)
	}
	return
}

// The corners of a node as drawn, in page coordinates (TL, TR, BR, BL).
node_corners :: proc(n: ^Node) -> (c: [4][2]f32, transformed: bool) {
	c = {{n.x, n.y}, {n.x + n.w, n.y}, {n.x + n.w, n.y + n.h}, {n.x, n.y + n.h}}
	m, tr := node_transform(n)
	if !tr do return c, false
	for &p in c do p = xform_point(m, p)
	return c, true
}

// The page-space box around a node as drawn.
node_page_box :: proc(n: ^Node) -> [4]f32 {
	c, tr := node_corners(n)
	if !tr do return {n.x, n.y, n.w, n.h}
	lo, hi := c[0], c[0]
	for p in c[1:] {
		lo = {min(lo.x, p.x), min(lo.y, p.y)}
		hi = {max(hi.x, p.x), max(hi.y, p.y)}
	}
	return {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y}
}

// ---------------------------------------------------------------- rendering

to_nvg :: proc(c: Color, opacity: f32 = 1) -> nvg.Color {
	return {f32(c[0]) / 255, f32(c[1]) / 255, f32(c[2]) / 255, f32(c[3]) / 255 * opacity}
}

// The part of the page the canvas shows (page coordinates); nodes outside it are not
// drawn. Zero while rendering offscreen (screenshots, thumbnails, export).
cull_rect: [4]f32

// True when a node's box, grown by its stroke and shadow, can be seen.
node_visible :: proc(n: ^Node) -> bool {
	if cull_rect[2] <= 0 || n.rotation != 0 || n.flip_x || n.flip_y do return true
	m := n.stroke_width + 2
	if n.shadow.has do m += abs(n.shadow.offset.x) + abs(n.shadow.offset.y) + n.shadow.blur + n.shadow.spread
	for e in n.effects[:n.neffects] {
		if e.kind == .Drop_Shadow do m = max(m, n.stroke_width + 2 + abs(e.offset.x) + abs(e.offset.y) + e.blur + e.spread)
		if e.kind == .Blur do m = max(m, n.stroke_width + 2 + e.blur * 1.5)
	}
	return n.x - m < cull_rect[0] + cull_rect[2] && n.x + n.w + m > cull_rect[0] &&
	       n.y - m < cull_rect[1] + cull_rect[3] && n.y + n.h + m > cull_rect[1]
}

// Draws a node and, for frames and groups, its children.
draw_node_tree :: proc(vg: ^nvg.Context, n: ^Node, alpha: f32, depth: int, force := false) {
	if (!n.enabled && !force) || depth > MAX_DEPTH do return
	// capturing what lies behind a background blur: stop at its layer
	if blur_stopped do return
	if blur_stop != 0 && n.uid == blur_stop {
		blur_stopped = true
		return
	}
	// Off-screen nodes are skipped: besides the work, their glyphs would take atlas space
	// (at high zoom a few large glyphs fill it and the rest of the text disappears).
	// Children may overflow an unclipped container, so only leaves and clipping frames
	// are culled by their own box.
	if !node_visible(n) {
		#partial switch n.kind {
		case .Group, .Ref: // children may lie outside
		case .Frame: if n.clip do return
		case: return
		}
	}
	if lod_scale > 0 && n.w * lod_scale < 0.5 && n.h * lod_scale < 0.5 && n.kind != .Frame && n.kind != .Group && n.kind != .Ref do return
	if blur_active && n.uid != blur_self {
		if r, ok := blur_layer[n.uid]; ok {
			draw_blurred_layer(vg, r, alpha)
			return
		}
	}
	doc := current
	a := alpha * n.opacity
	nvg.Save(vg)
	defer nvg.Restore(vg)
	nvg.GlobalAlpha(vg, a)
	// rotation (counter-clockwise) and flips apply to the node and everything inside it,
	// both around its top-left corner as pen.dev renders them
	saved_cull := cull_rect
	defer cull_rect = saved_cull
	if n.rotation != 0 || n.flip_x || n.flip_y {
		nvg.Translate(vg, n.x, n.y)
		if n.rotation != 0 do nvg.Rotate(vg, -n.rotation * math.PI / 180)
		if n.flip_x || n.flip_y do nvg.Scale(vg, -1 if n.flip_x else 1, -1 if n.flip_y else 1)
		nvg.Translate(vg, -n.x, -n.y)
		// the children land turned or mirrored, so their own boxes cannot be culled
		cull_rect = {}
	}
	// NanoVG's Odin port traps on a closed path whose points all coincide, so boxes
	// without any extent (empty fit_content frames, zero-size shapes) are not outlined.
	flat := n.w < 1e-3 && n.h < 1e-3

	// drop shadows that follow the shape (blur.odin), under the layer
	if blur_active && n.uid != blur_self && shadow_by_silhouette(n) {
		for e, i in n.effects[:n.neffects] {
			if !e.enabled || e.kind != .Drop_Shadow do continue
			if r, ok := blur_shadow[n.uid * 16 + i]; ok do draw_blurred_layer(vg, r, 1)
		}
	}
	switch n.kind {
	case .Frame, .Rectangle:
		if !flat && node_visible(n) do draw_box(vg, n)
		if n.kind == .Frame {
			if n.clip do nvg.IntersectScissor(vg, n.x, n.y, n.w, n.h)
			for cu in children_for_layout(doc, n.uid) {
				if c, _ := doc_find_uid(doc, cu); c != nil do draw_node_tree(vg, c, a, depth + 1)
			}
		}
	case .Group:
		for cu in children_for_layout(doc, n.uid) {
			if c, _ := doc_find_uid(doc, cu); c != nil do draw_node_tree(vg, c, a, depth + 1)
		}
	case .Ellipse:
		if flat do return
		cx, cy := n.x + n.w / 2, n.y + n.h / 2
		draw_drop_shadows(vg, n, min(n.w, n.h) / 2)
		nvg.BeginPath(vg)
		nvg.Ellipse(vg, cx, cy, n.w / 2, n.h / 2)
		fill_backdrop(vg, n)
		fill_paints(vg, n)
		draw_inner_shadows(vg, n, min(n.w, n.h) / 2)
		if n.has_stroke && n.stroke_width > 0 {
			inset: f32
			#partial switch n.stroke_align {
			case .Inner: inset = n.stroke_width / 2
			case .Outer: inset = -n.stroke_width / 2
			}
			nvg.BeginPath(vg)
			nvg.Ellipse(vg, cx, cy, max(n.w / 2 - inset, 0), max(n.h / 2 - inset, 0))
			nvg.StrokeColor(vg, to_nvg(n.stroke))
			nvg.StrokeWidth(vg, n.stroke_width)
			stroke_node(vg, n)
		}
	case .Path, .Icon:
		if n.kind == .Icon && len(n.cmds) == 0 {
			draw_placeholder(vg, n, "icon")
			return
		}
		if len(n.cmds) == 0 || flat do return
		sx := n.w / n.view_box[2]
		sy := n.h / n.view_box[3]
		if n.kind == .Icon && lod_scale > 0 && min(n.w, n.h) * lod_scale < 6 {
			// a few points across: its strokes are a smudge of its colour
			color := to_nvg(n.fill if n.has_fill else Color{0, 0, 0, 255})
			s := min(n.w, n.h) * 0.5
			nvg.BeginPath(vg)
			nvg.Rect(vg, n.x + (n.w - s) / 2, n.y + (n.h - s) / 2, s, s)
			nvg.FillColor(vg, {color.r, color.g, color.b, color.a * 0.6})
			nvg.Fill(vg)
			return
		}
		if n.kind == .Icon {
			// uniform scale, centred, like an SVG with preserveAspectRatio
			s := min(sx, sy)
			nvg.Translate(vg, n.x + (n.w - 24 * s) / 2, n.y + (n.h - 24 * s) / 2)
			nvg.Scale(vg, s, s)
			color := to_nvg(n.fill if n.has_fill else Color{0, 0, 0, 255})
			// lucide draws dots as zero-length segments with round caps ("M12 8h.01");
			// NanoVG drops those, so they are filled as circles instead
			dots := make([dynamic][2]f32, context.temp_allocator)
			nvg.BeginPath(vg)
			for c, i in n.cmds {
				if c.kind == .Move && i + 1 < len(n.cmds) && n.cmds[i + 1].kind == .Line {
					next_is_new := i + 2 >= len(n.cmds) || n.cmds[i + 2].kind == .Move
					d := n.cmds[i + 1].p[2] - c.p[2]
					if next_is_new && d.x * d.x + d.y * d.y < 0.25 {
						append(&dots, c.p[2])
						continue
					}
				}
				if c.kind == .Line && i > 0 && n.cmds[i - 1].kind == .Move && len(dots) > 0 && dots[len(dots) - 1] == n.cmds[i - 1].p[2] do continue
				path_cmd(vg, c, {0, 0}, 1, 1)
			}
			nvg.LineCap(vg, .ROUND)
			nvg.LineJoin(vg, .ROUND)
			nvg.StrokeColor(vg, color)
			nvg.StrokeWidth(vg, 2)
			nvg.Stroke(vg)
			if len(dots) > 0 {
				nvg.BeginPath(vg)
				for d in dots do nvg.Circle(vg, d.x, d.y, 1)
				nvg.FillColor(vg, color)
				nvg.Fill(vg)
			}
			return
		}
		nvg.BeginPath(vg)
		tp :: proc(p: [2]f32, n: ^Node, sx, sy: f32) -> [2]f32 {
			return {n.x + (p.x - n.view_box[0]) * sx, n.y + (p.y - n.view_box[1]) * sy}
		}
		windings := path_windings(n)
		sub := -1
		for c in n.cmds {
			switch c.kind {
			case .Move:
				p := tp(c.p[2], n, sx, sy)
				nvg.MoveTo(vg, p.x, p.y)
				sub += 1
				if sub < len(windings) do nvg.PathWinding(vg, windings[sub])
			case .Line:
				p := tp(c.p[2], n, sx, sy)
				nvg.LineTo(vg, p.x, p.y)
			case .Cubic:
				c1, c2, p := tp(c.p[0], n, sx, sy), tp(c.p[1], n, sx, sy), tp(c.p[2], n, sx, sy)
				nvg.BezierTo(vg, c1.x, c1.y, c2.x, c2.y, p.x, p.y)
			case .Quad:
				c1, p := tp(c.p[0], n, sx, sy), tp(c.p[1], n, sx, sy)
				nvg.QuadTo(vg, c1.x, c1.y, p.x, p.y)
			case .Close:
				nvg.ClosePath(vg)
			}
		}
		nvg.LineCap(vg, LINE_CAPS[n.line_cap])
		nvg.LineJoin(vg, LINE_JOINS[n.line_join])
		if path_stroke_behind(n) {
			// an outer stroke under an opaque fill: twice as wide and painted first, so the
			// fill covers its inner half (CSS paint-order: stroke)
			nvg.StrokeColor(vg, to_nvg(n.stroke))
			nvg.StrokeWidth(vg, n.stroke_width * 2)
			stroke_node(vg, n)
			fill_paints(vg, n)
		} else {
			fill_and_stroke(vg, n)
		}
		if n.flow == .Connector do fill_connector_heads(vg, n, sx, sy)
	case .Text:
		if lod_scale > 0 && n.font_size * lod_scale < 2 do draw_text_bars(vg, n)
		else do draw_text(vg, n)
	case .Ref:
		root := ghost_root_of(doc, n.uid)
		if root == nil {
			draw_placeholder(vg, n, fmt.tprintf("ref %s", n.ref))
			return
		}
		draw_node_tree(vg, root, a, depth + 1, force = true)
	case .Other:
		draw_placeholder(vg, n, n.type_name)
	}
}

// A connector's filled markers (arrow, diamond, circle): the closed subpaths of its
// geometry, filled with its stroke colour. The route itself is open and only stroked.
fill_connector_heads :: proc(vg: ^nvg.Context, n: ^Node, sx, sy: f32) {
	if !n.has_stroke do return
	tp :: proc(p: [2]f32, n: ^Node, sx, sy: f32) -> [2]f32 {
		return {n.x + (p.x - n.view_box[0]) * sx, n.y + (p.y - n.view_box[1]) * sy}
	}
	nvg.BeginPath(vg)
	any := false
	start := -1
	for c, i in n.cmds {
		if c.kind == .Move do start = i
		if c.kind != .Close || start < 0 do continue
		for k in start ..= i {
			cc := n.cmds[k]
			p := tp(cc.p[2], n, sx, sy)
			#partial switch cc.kind {
			case .Move: nvg.MoveTo(vg, p.x, p.y)
			case .Line: nvg.LineTo(vg, p.x, p.y)
			case .Close: nvg.ClosePath(vg)
			}
		}
		any = true
		start = -1
	}
	if !any do return
	nvg.FillColor(vg, to_nvg(n.stroke))
	nvg.Fill(vg)
}

// A path's stroke aligned outside its outline, over a fill that hides the inside: drawn as
// a stroke of twice the width under the fill. pen.dev aligns path strokes inside and
// outside too; with a fill that does not cover (none, translucent, gradient or image) or
// for an inside stroke the app still strokes the outline's centre, as it needs clipping
// to the path for those.
path_stroke_behind :: proc(n: ^Node) -> bool {
	if n.stroke_align != .Outer || !n.has_stroke || n.stroke_width <= 0 do return false
	if n.nfills == 0 do return n.has_fill && n.fill.a == 255
	for i in 0 ..< n.nfills {
		p := &n.fills[i]
		if p.enabled && p.kind == .Color && p.color.a == 255 && p.opacity >= 1 do return true
	}
	return false
}

// The winding NanoVG should give each subpath of a path, so that its stencil fill (front
// faces count up, back faces down, cover where the count is not 0) applies the path's
// fill rule, as SVG and pen.dev do. NanoVG forces every subpath to one winding unless told
// otherwise, which filled the holes of every shape (a ring, an "o" converted to a path).
// nonzero: each subpath keeps the direction it was written in. evenodd: a subpath inside an
// odd number of others is a hole; exact for nested contours, overlapping ones are joined.
path_windings :: proc(n: ^Node) -> []nvg.Winding {
	polys := make([dynamic][dynamic][2]f32, context.temp_allocator)
	for c in n.cmds {
		if c.kind == .Move || len(polys) == 0 {
			p := make([dynamic][2]f32, context.temp_allocator)
			append(&polys, p)
		}
		cur := &polys[len(polys) - 1]
		switch c.kind {
		case .Move, .Line: append(cur, c.p[2])
		case .Quad: append(cur, c.p[0], c.p[1])
		case .Cubic: append(cur, c.p[0], c.p[1], c.p[2])
		case .Close:
		}
	}
	out := make([]nvg.Winding, len(polys), context.temp_allocator)
	areas := make([]f32, len(polys), context.temp_allocator)
	biggest := 0
	for poly, i in polys {
		// the shoelace sum: positive turns clockwise on screen (y down)
		for p, k in poly {
			q := poly[(k + 1) % len(poly)]
			areas[i] += p.x * q.y - q.x * p.y
		}
		if abs(areas[i]) > abs(areas[biggest]) do biggest = i
	}
	// NanoVG draws the antialiasing fringe outside a contour it calls CCW and inside a CW
	// one, so the biggest contour goes CCW; turning every subpath around keeps nonzero's
	// result (each count only changes sign)
	flip: f32 = -1 if len(areas) > 0 && areas[biggest] > 0 else 1
	for poly, i in polys {
		if !n.even_odd {
			// NanoVG's polygon area is the negated shoelace sum; CCW asks for a positive one
			out[i] = .CW if areas[i] * flip > 0 else .CCW
			continue
		}
		depth := 0
		if len(poly) > 0 {
			pt := poly[0]
			for other, j in polys do if j != i && point_in_polygon(pt, other[:]) do depth += 1
		}
		out[i] = .CCW if depth % 2 == 0 else .CW
	}
	return out
}

point_in_polygon :: proc(pt: [2]f32, poly: [][2]f32) -> bool {
	inside := false
	for k in 0 ..< len(poly) {
		a, b := poly[k], poly[(k + 1) % len(poly)]
		if (a.y > pt.y) != (b.y > pt.y) && pt.x < (b.x - a.x) * (pt.y - a.y) / (b.y - a.y) + a.x do inside = !inside
	}
	return inside
}

LINE_CAPS := [Line_Cap]nvg.LineCapType{.Butt = .BUTT, .Round = .ROUND, .Square = .SQUARE}
LINE_JOINS := [Line_Join]nvg.LineCapType{.Miter = .MITER, .Round = .ROUND, .Bevel = .BEVEL}

// Adds one parsed path command, mapping its points from `origin` with a scale.
path_cmd :: proc(vg: ^nvg.Context, c: Path_Cmd, origin: [2]f32, sx, sy: f32) {
	tp :: proc(p, origin: [2]f32, sx, sy: f32) -> [2]f32 {
		return {(p.x - origin.x) * sx, (p.y - origin.y) * sy}
	}
	switch c.kind {
	case .Move:
		p := tp(c.p[2], origin, sx, sy)
		nvg.MoveTo(vg, p.x, p.y)
	case .Line:
		p := tp(c.p[2], origin, sx, sy)
		nvg.LineTo(vg, p.x, p.y)
	case .Cubic:
		c1, c2, p := tp(c.p[0], origin, sx, sy), tp(c.p[1], origin, sx, sy), tp(c.p[2], origin, sx, sy)
		nvg.BezierTo(vg, c1.x, c1.y, c2.x, c2.y, p.x, p.y)
	case .Quad:
		c1, p := tp(c.p[0], origin, sx, sy), tp(c.p[1], origin, sx, sy)
		nvg.QuadTo(vg, c1.x, c1.y, p.x, p.y)
	case .Close:
		nvg.ClosePath(vg)
	}
}

// Fills and strokes a rectangle-like node with its corner radii.
draw_box :: proc(vg: ^nvg.Context, n: ^Node) {
	draw_drop_shadows(vg, n, n.radius[0])
	nvg.BeginPath(vg)
	rounded_rect(vg, n.x, n.y, n.w, n.h, n.radius)
	fill_backdrop(vg, n)
	if n.nfills > 0 {
		fill_paints(vg, n)
	} else if n.has_fill {
		if n.image_url == "" || !image_fill(vg, n) {
			nvg.FillColor(vg, to_nvg(n.fill))
			nvg.Fill(vg)
		}
	}
	draw_inner_shadows(vg, n, n.radius[0])
	if n.has_stroke && n.stroke_per_side && n.stroke_width > 0 {
		// per-side widths, drawn inside the box like CSS borders: the rounded box with
		// the inner box (inset by each side's width) cut out
		t, rt, b, l := n.stroke_sides[0], n.stroke_sides[1], n.stroke_sides[2], n.stroke_sides[3]
		r := n.radius
		inner := [4]f32{max(r[0] - max(t, l), 0), max(r[1] - max(t, rt), 0), max(r[2] - max(b, rt), 0), max(r[3] - max(b, l), 0)}
		nvg.BeginPath(vg)
		if r == {} {
			// square corners: one band per side (a cut-out would leave an antialiasing
			// hairline along the sides without a border)
			if t > 0 do nvg.Rect(vg, n.x, n.y, n.w, t)
			if b > 0 do nvg.Rect(vg, n.x, n.y + n.h - b, n.w, b)
			if l > 0 do nvg.Rect(vg, n.x, n.y + t, l, n.h - t - b)
			if rt > 0 do nvg.Rect(vg, n.x + n.w - rt, n.y + t, rt, n.h - t - b)
		} else {
			rounded_rect(vg, n.x, n.y, n.w, n.h, r)
			if n.w - l - rt > 0 && n.h - t - b > 0 {
				rounded_rect(vg, n.x + l, n.y + t, n.w - l - rt, n.h - t - b, inner)
				nvg.PathWinding(vg, .CW)
			}
		}
		nvg.FillColor(vg, to_nvg(n.stroke))
		nvg.Fill(vg)
	} else if n.has_stroke && n.stroke_width > 0 {
		inset: f32
		switch n.stroke_align {
		case .Center:
		case .Inner: inset = n.stroke_width / 2
		case .Outer: inset = -n.stroke_width / 2
		}
		r := n.radius
		for &v in r do v = max(v - inset, 0)
		nvg.BeginPath(vg)
		rounded_rect(vg, n.x + inset, n.y + inset, n.w - inset * 2, n.h - inset * 2, r)
		nvg.StrokeColor(vg, to_nvg(n.stroke))
		nvg.StrokeWidth(vg, n.stroke_width)
		stroke_node(vg, n)
	}
}

// Screen points per page unit while the live canvas draws, 0 elsewhere (screenshots,
// exports, thumbnails, blur buffers). Above 0, details too small to see are simplified:
// text under 2 points becomes grey bars, icons under 6 points a dot of their colour,
// corners under a third of a point square, leaves under half a point are skipped.
lod_scale: f32
lod_off: bool // AGENTIC_NO_LOD=1 draws every detail (measurements)

rounded_rect :: proc(vg: ^nvg.Context, x, y, w, h: f32, r: [4]f32) {
	if r == {} || lod_scale > 0 && max(max(r[0], r[1]), max(r[2], r[3])) * lod_scale < 0.35 do nvg.Rect(vg, x, y, w, h)
	else do nvg.RoundedRectVarying(vg, x, y, w, h, r[0], r[1], r[2], r[3])
}

fill_and_stroke :: proc(vg: ^nvg.Context, n: ^Node) {
	fill_paints(vg, n)
	if n.has_stroke && n.stroke_width > 0 {
		nvg.StrokeColor(vg, to_nvg(n.stroke))
		nvg.StrokeWidth(vg, n.stroke_width)
		stroke_node(vg, n)
	}
}

// Strokes the current path with the node's dash pattern, if it has one.
stroke_node :: proc(vg: ^nvg.Context, n: ^Node) {
	if n.ndash == 0 {
		nvg.Stroke(vg)
		return
	}
	nvg.StrokeDash(vg, n.dash[:n.ndash])
	nvg.Stroke(vg)
	nvg.StrokeDash(vg, nil)
}

// Text too small to read on screen: a bar per line in its colour.
draw_text_bars :: proc(vg: ^nvg.Context, n: ^Node) {
	rows := len(text_lines(n, n.w))
	if rows == 0 do return
	lh := n.font_size * line_height_of(n)
	color := to_nvg(n.fill if n.has_fill else Color{0, 0, 0, 255})
	nvg.BeginPath(vg)
	for i in 0 ..< rows {
		w := n.w if i < rows - 1 else n.w * (0.6 if rows > 1 else 1)
		nvg.Rect(vg, n.x, n.y + f32(i) * lh + lh * 0.3, w, lh * 0.4)
	}
	nvg.FillColor(vg, {color.r, color.g, color.b, color.a * 0.45})
	nvg.Fill(vg)
}

// Where the glyph box of text with "normal" line height starts below the top of its line
// box when glyphs go on whole device pixels (`k` per unit), as Blink places it: the line box
// is the ascent and descent each rounded to device pixels, the baseline the rounded ascent
// below its top. With the exact ascent the baseline rounded to the other pixel whenever the
// layer sat at a fractional position (flex layouts put text at y = 10.6 and so on), a
// device pixel off Chrome (D44). Text with an explicit line height keeps the exact half
// leading: imported pages and pen.dev place it by that.
blink_baseline_top :: proc(vg: ^nvg.Context, k: f32) -> f32 {
	asc, _, _ := nvg.TextMetrics(vg)
	return math.round(asc * k) / k - asc
}

draw_text :: proc(vg: ^nvg.Context, n: ^Node) {
	if len(n.spans) > 0 {
		draw_rich(vg, n)
		return
	}
	set_font(vg, n)
	nvg.FillColor(vg, to_nvg(n.fill if n.has_fill else Color{0, 0, 0, 255}))
	halign: nvg.AlignHorizontal = .LEFT
	anchor := n.x
	switch n.text_align {
	case .Left, .Justify:
	case .Center:
		halign = .CENTER
		anchor = n.x + n.w / 2
	case .Right:
		halign = .RIGHT
		anchor = n.x + n.w
	}
	nvg.TextAlign(vg, halign, .TOP)
	// lines were broken at document scale by the layout pass; draw them one by one so
	// wrapping and widths do not drift with the zoom level
	rows := text_lines(n, n.w if n.growth != .Auto else -1)
	y := n.y + half_leading(vg, n)
	if k := nvg.TextSnapScale(vg); k > 0 && n.line_height <= 0 && outline_sink == nil do y = n.y + blink_baseline_top(vg, k)
	if n.growth == .Fixed_Width_Height && n.text_valign != .Start {
		free := n.h - f32(len(rows)) * n.font_size * line_height_of(n)
		y += free / 2 if n.text_valign == .Center else free
	}
	justify := n.text_align == .Justify && n.growth != .Auto
	for row, i in rows {
		a, b := clamp(row[0], 0, len(n.content)), clamp(row[1], 0, len(n.content))
		if b > a {
			line := n.content[a:b]
			// the last line of a paragraph keeps its natural spacing
			last := i == len(rows) - 1 || strings.has_suffix(line, "\n") || (b < len(n.content) && n.content[b] == '\n')
			if justify && !last && draw_justified(vg, n, y, line) {
				if n.underline || n.strikethrough do text_decoration(vg, n, anchor, y, halign, line, n.w)
			} else {
				text_run(vg, n, anchor, y, line, halign)
				if n.underline || n.strikethrough do text_decoration(vg, n, anchor, y, halign, line)
			}
		}
		y += n.font_size * line_height_of(n)
	}
}

// One line spread over the box width: the space left over goes between the words.
// Returns false for a line with a single word, which is drawn as it is.
draw_justified :: proc(vg: ^nvg.Context, n: ^Node, y: f32, line: string) -> bool {
	words := strings.fields(strings.trim_space(line), context.temp_allocator)
	if len(words) < 2 do return false
	widths := make([]f32, len(words), context.temp_allocator)
	total: f32
	for w, i in words {
		widths[i] = nvg.TextBounds(vg, 0, 0, w)
		total += widths[i]
	}
	gap := (n.w - total) / f32(len(words) - 1)
	x := n.x
	for w, i in words {
		text_run(vg, n, x, y, w)
		x += widths[i] + gap
	}
	return true
}

// Underline and strikethrough for one drawn line of text.
text_decoration :: proc(vg: ^nvg.Context, n: ^Node, anchor, y: f32, halign: nvg.AlignHorizontal, line: string, width: f32 = -1) {
	w := width if width >= 0 else nvg.TextBounds(vg, 0, 0, line)
	x := anchor
	#partial switch halign {
	case .CENTER: x -= w / 2
	case .RIGHT: x -= w
	}
	thick := max(n.font_size / 14, 0.5)
	lh := n.font_size * line_height_of(n)
	base := y + (lh - n.font_size) / 2 + n.font_size * 0.92 // roughly the baseline
	if outline_sink != nil {
		rect :: proc(x, y, w, h: f32) {
			sink_cmd('M', x, y)
			sink_cmd('L', x + w, y)
			sink_cmd('L', x + w, y + h)
			sink_cmd('L', x, y + h)
		}
		if n.underline do rect(x, base + thick, w, thick)
		if n.strikethrough do rect(x, base - n.font_size * 0.3, w, thick)
		return
	}
	nvg.BeginPath(vg)
	if n.underline do nvg.Rect(vg, x, base + thick, w, thick)
	if n.strikethrough do nvg.Rect(vg, x, base - n.font_size * 0.3, w, thick)
	nvg.Fill(vg)
}

// Node types this app does not render (scripts, browsers, ...).
draw_placeholder :: proc(vg: ^nvg.Context, n: ^Node, label: string) {
	if n.w < 1e-3 && n.h < 1e-3 do return
	if n.has_fill {
		nvg.BeginPath(vg)
		nvg.Rect(vg, n.x, n.y, n.w, n.h)
		nvg.FillColor(vg, to_nvg(n.fill, 0.35))
		nvg.Fill(vg)
	}
	nvg.BeginPath(vg)
	nvg.Rect(vg, n.x + 0.5, n.y + 0.5, n.w - 1, n.h - 1)
	nvg.StrokeColor(vg, {0.5, 0.5, 0.55, 0.6})
	nvg.StrokeWidth(vg, 1)
	nvg.Stroke(vg)
	if n.w >= 40 && n.h >= 14 {
		nvg.FontFace(vg, "sans")
		nvg.FontSize(vg, 10)
		nvg.TextAlign(vg, .CENTER, .MIDDLE)
		nvg.FillColor(vg, {0.4, 0.4, 0.45, 0.9})
		nvg.Save(vg)
		nvg.IntersectScissor(vg, n.x, n.y, n.w, n.h)
		nvg.Text(vg, n.x + n.w / 2, n.y + n.h / 2, label)
		nvg.Restore(vg)
	}
}

