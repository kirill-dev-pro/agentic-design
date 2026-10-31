package agentic_design

import "core:math"
import "core:strconv"

// Minimal SVG path parser: M L H V C S Q T A Z (absolute and relative).
// Arcs become cubic Béziers, at most a quarter turn each.

Path_Cmd_Kind :: enum {
	Move,
	Line,
	Cubic,
	Quad,
	Close,
}

Path_Cmd :: struct {
	kind: Path_Cmd_Kind,
	p:    [3][2]f32, // control points then end point
}

parse_svg_path :: proc(d: string) -> (cmds: [dynamic]Path_Cmd, box: [4]f32, ok: bool) {
	i := 0
	skip :: proc(d: string, i: ^int) {
		for i^ < len(d) && (d[i^] == ' ' || d[i^] == ',' || d[i^] == '\n' || d[i^] == '\t' || d[i^] == '\r') do i^ += 1
	}
	number :: proc(d: string, i: ^int) -> (f32, bool) {
		skip(d, i)
		start := i^
		if i^ < len(d) && (d[i^] == '-' || d[i^] == '+') do i^ += 1
		seen_dot, seen_digit := false, false
		for i^ < len(d) {
			c := d[i^]
			if c >= '0' && c <= '9' {
				seen_digit = true
			} else if c == '.' && !seen_dot {
				seen_dot = true
			} else if (c == 'e' || c == 'E') && seen_digit {
				i^ += 1
				if i^ < len(d) && (d[i^] == '-' || d[i^] == '+') do i^ += 1
				continue
			} else {
				break
			}
			i^ += 1
		}
		if !seen_digit do return 0, false
		v, vok := strconv.parse_f32(d[start:i^])
		return v, vok
	}
	// Arc flags are single digits and may be written without separators ("a1 1 0 011 1").
	flag :: proc(d: string, i: ^int) -> (bool, bool) {
		skip(d, i)
		if i^ >= len(d) || (d[i^] != '0' && d[i^] != '1') do return false, false
		i^ += 1
		return d[i^ - 1] == '1', true
	}
	has_number :: proc(d: string, i: int) -> bool {
		j := i
		skip(d, &j)
		if j >= len(d) do return false
		c := d[j]
		return (c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.'
	}

	cur, start, last_ctrl: [2]f32
	cmd: u8 = 0
	prev: u8 = 0
	for {
		skip(d, &i)
		if i >= len(d) do break
		c := d[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') {
			cmd = c
			i += 1
		} else if cmd == 0 {
			return
		}
		rel := cmd >= 'a'
		base := cur if rel else [2]f32{0, 0}
		pt :: proc(d: string, i: ^int, base: [2]f32) -> (p: [2]f32, ok: bool) {
			x := number(d, i) or_return
			y := number(d, i) or_return
			return {x + base.x, y + base.y}, true
		}
		switch cmd {
		case 'M', 'm':
			p := pt(d, &i, base) or_return
			append(&cmds, Path_Cmd{kind = .Move, p = {p, p, p}})
			cur, start = p, p
			cmd = 'l' if rel else 'L' // subsequent pairs are lines
		case 'L', 'l':
			p := pt(d, &i, base) or_return
			append(&cmds, Path_Cmd{kind = .Line, p = {p, p, p}})
			cur = p
		case 'H', 'h':
			x := number(d, &i) or_return
			p := [2]f32{x + (cur.x if rel else 0), cur.y}
			append(&cmds, Path_Cmd{kind = .Line, p = {p, p, p}})
			cur = p
		case 'V', 'v':
			y := number(d, &i) or_return
			p := [2]f32{cur.x, y + (cur.y if rel else 0)}
			append(&cmds, Path_Cmd{kind = .Line, p = {p, p, p}})
			cur = p
		case 'C', 'c':
			c1 := pt(d, &i, base) or_return
			c2 := pt(d, &i, base) or_return
			p := pt(d, &i, base) or_return
			append(&cmds, Path_Cmd{kind = .Cubic, p = {c1, c2, p}})
			last_ctrl, cur = c2, p
		case 'S', 's':
			c1 := cur
			if prev == 'C' || prev == 'c' || prev == 'S' || prev == 's' do c1 = 2 * cur - last_ctrl
			c2 := pt(d, &i, base) or_return
			p := pt(d, &i, base) or_return
			append(&cmds, Path_Cmd{kind = .Cubic, p = {c1, c2, p}})
			last_ctrl, cur = c2, p
		case 'Q', 'q':
			c1 := pt(d, &i, base) or_return
			p := pt(d, &i, base) or_return
			append(&cmds, Path_Cmd{kind = .Quad, p = {c1, p, p}})
			last_ctrl, cur = c1, p
		case 'T', 't':
			c1 := cur
			if prev == 'Q' || prev == 'q' || prev == 'T' || prev == 't' do c1 = 2 * cur - last_ctrl
			p := pt(d, &i, base) or_return
			append(&cmds, Path_Cmd{kind = .Quad, p = {c1, p, p}})
			last_ctrl, cur = c1, p
		case 'A', 'a':
			rx := number(d, &i) or_return
			ry := number(d, &i) or_return
			rot := number(d, &i) or_return
			large := flag(d, &i) or_return
			sweep := flag(d, &i) or_return
			p := pt(d, &i, base) or_return
			arc_to_cubics(&cmds, cur, p, rx, ry, rot, large, sweep)
			cur = p
		case 'Z', 'z':
			append(&cmds, Path_Cmd{kind = .Close})
			cur = start
		case:
			return
		}
		prev = cmd
		// Implicit repetition: another number means the same command again.
		if (cmd == 'Z' || cmd == 'z') || !has_number(d, i) do continue
	}
	if len(cmds) == 0 do return

	lo := [2]f32{math.F32_MAX, math.F32_MAX}
	hi := [2]f32{-math.F32_MAX, -math.F32_MAX}
	// Tight bounds: sample curves instead of using their control points.
	add :: proc(lo, hi: ^[2]f32, p: [2]f32) {
		lo^ = {min(lo.x, p.x), min(lo.y, p.y)}
		hi^ = {max(hi.x, p.x), max(hi.y, p.y)}
	}
	pen, sub := [2]f32{}, [2]f32{}
	for c in cmds {
		switch c.kind {
		case .Move:
			pen, sub = c.p[2], c.p[2]
			add(&lo, &hi, pen)
		case .Line:
			pen = c.p[2]
			add(&lo, &hi, pen)
		case .Cubic:
			for k in 1 ..= 16 {
				t := f32(k) / 16
				u := 1 - t
				add(&lo, &hi, u*u*u*pen + 3*u*u*t*c.p[0] + 3*u*t*t*c.p[1] + t*t*t*c.p[2])
			}
			pen = c.p[2]
		case .Quad:
			for k in 1 ..= 16 {
				t := f32(k) / 16
				u := 1 - t
				add(&lo, &hi, u*u*pen + 2*u*t*c.p[0] + t*t*c.p[1])
			}
			pen = c.p[1]
		case .Close:
			pen = sub
		}
	}
	box = {lo.x, lo.y, max(hi.x - lo.x, 1), max(hi.y - lo.y, 1)}
	return cmds, box, true
}

// Appends an SVG elliptical arc from `p0` to `p1` as cubic Béziers (SVG 1.1 F.6.5/F.6.6).
arc_to_cubics :: proc(cmds: ^[dynamic]Path_Cmd, p0, p1: [2]f32, rx_in, ry_in, rot_deg: f32, large, sweep: bool) {
	if p0 == p1 do return
	rx, ry := abs(rx_in), abs(ry_in)
	if rx == 0 || ry == 0 {
		append(cmds, Path_Cmd{kind = .Line, p = {p1, p1, p1}})
		return
	}
	phi := rot_deg * math.PI / 180
	cs, sn := math.cos(phi), math.sin(phi)
	// the end points in the ellipse's own frame, centred between them
	dx, dy := (p0.x - p1.x) / 2, (p0.y - p1.y) / 2
	x1 := cs * dx + sn * dy
	y1 := -sn * dx + cs * dy
	// radii too small to reach: scale them up
	lam := (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
	if lam > 1 {
		s := math.sqrt(lam)
		rx, ry = rx * s, ry * s
	}
	num := rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
	den := rx * rx * y1 * y1 + ry * ry * x1 * x1
	coef := math.sqrt(max(num / den, 0)) if den != 0 else 0
	if large == sweep do coef = -coef
	cxp := coef * rx * y1 / ry
	cyp := -coef * ry * x1 / rx
	c := [2]f32{cs * cxp - sn * cyp + (p0.x + p1.x) / 2, sn * cxp + cs * cyp + (p0.y + p1.y) / 2}
	angle :: proc(u, v: [2]f32) -> f32 {
		a := math.atan2(v.y, v.x) - math.atan2(u.y, u.x)
		return a
	}
	u := [2]f32{(x1 - cxp) / rx, (y1 - cyp) / ry}
	v := [2]f32{(-x1 - cxp) / rx, (-y1 - cyp) / ry}
	theta := math.atan2(u.y, u.x)
	delta := angle(u, v)
	for delta < 0 do delta += 2 * math.PI
	for delta >= 2 * math.PI do delta -= 2 * math.PI
	if !sweep && delta > 0 do delta -= 2 * math.PI
	// split into pieces of at most 90°, each approximated by one cubic
	n := int(math.ceil(abs(delta) / (math.PI / 2) - 0.001))
	n = max(n, 1)
	step := delta / f32(n)
	k := 4.0 / 3.0 * math.tan(step / 4)
	point :: proc(c: [2]f32, rx, ry, cs, sn, t: f32) -> [2]f32 {
		x, y := rx * math.cos(t), ry * math.sin(t)
		return {c.x + cs * x - sn * y, c.y + sn * x + cs * y}
	}
	deriv :: proc(rx, ry, cs, sn, t: f32) -> [2]f32 {
		x, y := -rx * math.sin(t), ry * math.cos(t)
		return {cs * x - sn * y, sn * x + cs * y}
	}
	t := theta
	for s in 0 ..< n {
		t2 := t + step
		a := point(c, rx, ry, cs, sn, t)
		b := point(c, rx, ry, cs, sn, t2)
		if s == n - 1 do b = p1
		c1 := a + k * deriv(rx, ry, cs, sn, t)
		c2 := b - k * deriv(rx, ry, cs, sn, t2)
		append(cmds, Path_Cmd{kind = .Cubic, p = {c1, c2, b}})
		t = t2
	}
}
