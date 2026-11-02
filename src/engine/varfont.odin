package engine

import "base:runtime"
import "core:math"
import "core:slice"

// A static instance of a TrueType variable font: glyph outlines, component offsets and
// advance widths moved by the font's `gvar` deltas at the requested axis values (other
// axes at their defaults), written out as a plain font that stb_truetype draws. This is
// what fontTools' instancer does for `glyf` fonts; CFF2 (PostScript) variable fonts are
// not handled and keep their default instance.

@(private = "file")
u16be :: proc(b: []u8, at: int) -> int {
	if at < 0 || at + 2 > len(b) do return 0
	return int(b[at]) << 8 | int(b[at + 1])
}

@(private = "file")
i16be :: proc(b: []u8, at: int) -> int {
	v := u16be(b, at)
	return v - 0x10000 if v >= 0x8000 else v
}

@(private = "file")
u32be :: proc(b: []u8, at: int) -> int {
	if at < 0 || at + 4 > len(b) do return 0
	return int(b[at]) << 24 | int(b[at + 1]) << 16 | int(b[at + 2]) << 8 | int(b[at + 3])
}

@(private = "file")
f2dot14 :: proc(b: []u8, at: int) -> f32 {
	return f32(i16be(b, at)) / 16384
}

@(private = "file")
fixed :: proc(b: []u8, at: int) -> f32 {
	return f32(i32(u32(u32be(b, at)))) / 65536 // (signed 16.16)
}

@(private = "file")
put16 :: proc(out: ^[dynamic]u8, v: int) {
	append(out, u8(v >> 8), u8(v))
}

@(private = "file")
put32 :: proc(out: ^[dynamic]u8, v: int) {
	append(out, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))
}

// The tables of the font at `offset` (0, or a font inside a collection).
sfnt_tables :: proc(file: []u8, offset: int) -> (tables: map[string][]u8, ok: bool) {
	tables = make(map[string][]u8, 32, context.temp_allocator)
	num := u16be(file, offset + 4)
	if num == 0 || offset + 12 + num * 16 > len(file) do return
	for i in 0 ..< num {
		rec := offset + 12 + i * 16
		tag := string(file[rec:rec + 4])
		off, length := u32be(file, rec + 8), u32be(file, rec + 12)
		if off + length > len(file) do return
		tables[tag] = file[off:off + length]
	}
	return tables, true
}

// The weight axis of a variable font: its range and default, or ok = false.
varfont_weight_axis :: proc(fvar: []u8) -> (lo, def, hi: f32, ok: bool) {
	count, at, size := u16be(fvar, 8), u16be(fvar, 4), u16be(fvar, 10)
	for a in 0 ..< count {
		rec := at + a * size
		if rec + 20 > len(fvar) do break
		if string(fvar[rec:rec + 4]) == "wght" do return fixed(fvar, rec + 4), fixed(fvar, rec + 8), fixed(fvar, rec + 12), true
	}
	return
}

Var_Axis :: struct {
	tag:   string,
	value: f32,
}

// Private table of an instance: the axis count, then each axis' normalised coordinate
// (F2Dot14), so that fontstash can apply GPOS kerning deltas (gpos.odin).
VAR_COORDS_TAG :: "ADvc"

varfont_instance :: proc(file: []u8, offset: int, settings: []Var_Axis) -> (out: []u8, ok: bool) {
	context.allocator = context.temp_allocator
	tables := sfnt_tables(file, offset) or_return
	fvar, gvar, glyf, loca := tables["fvar"], tables["gvar"], tables["glyf"], tables["loca"]
	head, hhea, hmtx, maxp := tables["head"], tables["hhea"], tables["hmtx"], tables["maxp"]
	if len(fvar) < 16 || len(gvar) < 20 || len(glyf) == 0 || len(head) < 54 || len(hhea) < 36 || len(maxp) < 6 do return
	num_glyphs := u16be(maxp, 4)
	long_loca := i16be(head, 50) == 1

	// the axes, normalised to -1..1 around their defaults, then through avar
	axis_count, axes_at, axis_size := u16be(fvar, 8), u16be(fvar, 4), u16be(fvar, 10)
	coords := make([]f32, axis_count)
	for a in 0 ..< axis_count {
		rec := axes_at + a * axis_size
		tag := string(fvar[rec:rec + 4])
		lo, def, hi := fixed(fvar, rec + 4), fixed(fvar, rec + 8), fixed(fvar, rec + 12)
		v := def
		for s in settings do if s.tag == tag do v = clamp(s.value, lo, hi)
		if v < def && def > lo do coords[a] = (v - def) / (def - lo)
		if v > def && hi > def do coords[a] = (v - def) / (hi - def)
	}
	if avar := tables["avar"]; len(avar) >= 8 {
		at := 8
		for a in 0 ..< min(u16be(avar, 6), axis_count) {
			n := u16be(avar, at)
			at += 2
			v := coords[a]
			for k in 1 ..< n {
				f0, t0 := f2dot14(avar, at + (k - 1) * 4), f2dot14(avar, at + (k - 1) * 4 + 2)
				f1, t1 := f2dot14(avar, at + k * 4), f2dot14(avar, at + k * 4 + 2)
				if v >= f0 && v <= f1 {
					coords[a] = t0 + (v - f0) * (t1 - t0) / (f1 - f0) if f1 > f0 else t0
					break
				}
			}
			at += n * 4
		}
	}

	// gvar
	gaxes := u16be(gvar, 4)
	shared_count, shared_at := u16be(gvar, 6), u32be(gvar, 8)
	gcount, gflags, data_at := u16be(gvar, 12), u16be(gvar, 14), u32be(gvar, 16)
	if gaxes != axis_count do return
	var_offset :: proc(gvar: []u8, flags, g: int) -> int {
		return u32be(gvar, 20 + g * 4) if flags & 1 != 0 else u16be(gvar, 20 + g * 2) * 2
	}
	shared := make([]f32, shared_count * gaxes)
	for i in 0 ..< len(shared) do shared[i] = f2dot14(gvar, shared_at + i * 2)

	scalar_of :: proc(coords, peak, start, end: []f32) -> f32 {
		s: f32 = 1
		for i in 0 ..< len(coords) {
			p := peak[i]
			if p == 0 do continue
			v := coords[i]
			if v == p do continue
			if start != nil {
				lo, hi := start[i], end[i]
				if v < lo || v > hi do return 0
				s *= (v - lo) / (p - lo) if v < p else (hi - v) / (hi - p)
			} else {
				if v == 0 || v < min(0, p) || v > max(0, p) do return 0
				s *= v / p
			}
		}
		return s
	}
	read_points :: proc(d: []u8, at: int) -> (pts: []int, next: int) {
		p := at
		if p >= len(d) do return nil, p
		count := int(d[p])
		p += 1
		if count & 0x80 != 0 {
			count = (count & 0x7F) << 8 | int(d[p])
			p += 1
		}
		if count == 0 do return nil, p
		pts = make([]int, count)
		i, last := 0, 0
		for i < count && p < len(d) {
			ctrl := d[p]
			p += 1
			run := int(ctrl & 0x7F) + 1
			for _ in 0 ..< run {
				if i >= count do break
				if ctrl & 0x80 != 0 {
					last += u16be(d, p)
					p += 2
				} else {
					last += int(d[p])
					p += 1
				}
				pts[i] = last
				i += 1
			}
		}
		return pts, p
	}
	read_deltas :: proc(d: []u8, at, n: int) -> (out: []f32, next: int) {
		out = make([]f32, n)
		p, i := at, 0
		for i < n && p < len(d) {
			ctrl := d[p]
			p += 1
			run := int(ctrl & 0x3F) + 1
			for _ in 0 ..< run {
				if i >= n do break
				if ctrl & 0x80 != 0 {
					// zeros
				} else if ctrl & 0x40 != 0 {
					out[i] = f32(i16be(d, p))
					p += 2
				} else {
					out[i] = f32(i8(d[p]))
					p += 1
				}
				i += 1
			}
		}
		return out, p
	}
	// IUP: deltas for the points a tuple leaves out, inferred contour by contour from the
	// nearest listed points around them
	iup :: proc(orig: [][2]f32, del: [][2]f32, has: []bool, ends: []int) {
		start := 0
		for end in ends {
			listed := make([dynamic]int, context.temp_allocator)
			for i in start ..= end do if has[i] do append(&listed, i)
			if len(listed) == 1 {
				for i in start ..= end do if !has[i] do del[i] = del[listed[0]]
			} else if len(listed) > 1 {
				for k in 0 ..< len(listed) {
					t1, t2 := listed[k], listed[(k + 1) % len(listed)]
					i := t1 + 1
					if i > end do i = start
					for i != t2 {
						for ax in 0 ..< 2 {
							c1, c2 := orig[t1][ax], orig[t2][ax]
							d1, d2 := del[t1][ax], del[t2][ax]
							c := orig[i][ax]
							if c1 == c2 {
								del[i][ax] = d1 if d1 == d2 else 0
							} else {
								lo_c, hi_c, lo_d, hi_d := c1, c2, d1, d2
								if c1 > c2 do lo_c, hi_c, lo_d, hi_d = c2, c1, d2, d1
								if c <= lo_c do del[i][ax] = lo_d
								else if c >= hi_c do del[i][ax] = hi_d
								else do del[i][ax] = lo_d + (c - lo_c) * (hi_d - lo_d) / (hi_c - lo_c)
							}
						}
						i += 1
						if i > end do i = start
					}
				}
			}
			start = end + 1
		}
	}

	num_h := max(u16be(hhea, 34), 1)
	advance_of :: proc(hmtx: []u8, num_h, g: int) -> int {return u16be(hmtx, 4 * min(g, num_h - 1))}
	lsb_of :: proc(hmtx: []u8, num_h, g: int) -> int {
		return i16be(hmtx, 4 * g + 2) if g < num_h else i16be(hmtx, 4 * num_h + 2 * (g - num_h))
	}
	glyph_range :: proc(loca: []u8, long: bool, g: int) -> (int, int) {
		if long do return u32be(loca, g * 4), u32be(loca, g * 4 + 4)
		return u16be(loca, g * 2) * 2, u16be(loca, g * 2 + 2) * 2
	}

	Component :: struct {
		flags, glyph:      int,
		dx, dy:            f32,
		transform:         []u8,
	}
	Glyph :: struct {
		contours:  int, // -1: composite
		ends:      []int,
		on_curve:  []bool,
		pts:       [][2]f32,
		comps:     []Component,
		advance:   int,
		lsb:       int,
		bbox:      [4]int, // xMin yMin xMax yMax
		empty:     bool,
	}
	glyphs := make([]Glyph, num_glyphs)

	for g in 0 ..< num_glyphs {
		gl := &glyphs[g]
		a, b := glyph_range(loca, long_loca, g)
		data := glyf[min(a, len(glyf)):min(b, len(glyf))]
		adv, lsb := advance_of(hmtx, num_h, g), lsb_of(hmtx, num_h, g)
		x_min := i16be(data, 2)
		n := 0
		if len(data) < 10 {
			gl.empty = true
		} else if nc := i16be(data, 0); nc >= 0 {
			gl.contours = nc
			gl.ends = make([]int, nc)
			for c in 0 ..< nc do gl.ends[c] = u16be(data, 10 + c * 2)
			n = gl.ends[nc - 1] + 1 if nc > 0 else 0
			p := 10 + nc * 2
			p += 2 + u16be(data, p)
			flags := make([]u8, n)
			for i := 0; i < n && p < len(data); {
				f := data[p]
				p += 1
				flags[i] = f
				i += 1
				if f & 8 != 0 && p < len(data) {
					rep := int(data[p])
					p += 1
					for _ in 0 ..< rep do if i < n {flags[i] = f; i += 1}
				}
			}
			gl.pts = make([][2]f32, n + 4)
			gl.on_curve = make([]bool, n)
			v := 0
			for i in 0 ..< n {
				f := flags[i]
				if f & 2 != 0 {
					d := int(data[p]) if p < len(data) else 0
					p += 1
					v += d if f & 16 != 0 else -d
				} else if f & 16 == 0 {
					v += i16be(data, p)
					p += 2
				}
				gl.pts[i].x = f32(v)
				gl.on_curve[i] = f & 1 != 0
			}
			v = 0
			for i in 0 ..< n {
				f := flags[i]
				if f & 4 != 0 {
					d := int(data[p]) if p < len(data) else 0
					p += 1
					v += d if f & 32 != 0 else -d
				} else if f & 32 == 0 {
					v += i16be(data, p)
					p += 2
				}
				gl.pts[i].y = f32(v)
			}
		} else {
			gl.contours = -1
			comps := make([dynamic]Component)
			p := 10
			for p + 4 <= len(data) {
				f, gi := u16be(data, p), u16be(data, p + 2)
				p += 4
				c := Component{flags = f, glyph = gi}
				if f & 1 != 0 {
					c.dx, c.dy = f32(i16be(data, p)), f32(i16be(data, p + 2))
					p += 4
				} else if p + 1 < len(data) {
					c.dx, c.dy = f32(i8(data[p])), f32(i8(data[p + 1]))
					p += 2
				}
				if f & 2 == 0 do c.dx, c.dy = 0, 0 // point matching: offsets do not apply
				tl := 2 if f & 8 != 0 else (4 if f & 0x40 != 0 else (8 if f & 0x80 != 0 else 0))
				c.transform = data[p:min(p + tl, len(data))]
				p += tl
				append(&comps, c)
				if f & 0x20 == 0 do break
			}
			gl.comps = comps[:]
			n = len(comps)
			gl.pts = make([][2]f32, n + 4)
			for c, i in comps do gl.pts[i] = {c.dx, c.dy}
		}
		if gl.empty do gl.pts = make([][2]f32, 4)
		// phantom points: the origin and the advance
		gl.pts[n] = {f32(x_min - lsb), 0}
		gl.pts[n + 1] = {f32(x_min - lsb + adv), 0}

		// the variation deltas
		if g < gcount {
			va, vb := data_at + var_offset(gvar, gflags, g), data_at + var_offset(gvar, gflags, g + 1)
			if vb > va && vb <= len(gvar) {
				vd := gvar[va:vb]
				count_word := u16be(vd, 0)
				count := count_word & 0x0FFF
				ser := u16be(vd, 2)
				shared_pts: []int
				if count_word & 0x8000 != 0 do shared_pts, ser = read_points(vd, ser)
				hdr := 4
				total := len(gl.pts)
				orig := slice.clone(gl.pts)
				sum := make([][2]f32, total)
				for _ in 0 ..< count {
					size, index := u16be(vd, hdr), u16be(vd, hdr + 2)
					hdr += 4
					peak := make([]f32, gaxes)
					if index & 0x8000 != 0 {
						for k in 0 ..< gaxes do peak[k] = f2dot14(vd, hdr + k * 2)
						hdr += gaxes * 2
					} else {
						si := index & 0x0FFF
						if (si + 1) * gaxes <= len(shared) do copy(peak, shared[si * gaxes:(si + 1) * gaxes])
					}
					start, end: []f32
					if index & 0x4000 != 0 {
						start, end = make([]f32, gaxes), make([]f32, gaxes)
						for k in 0 ..< gaxes do start[k] = f2dot14(vd, hdr + k * 2)
						for k in 0 ..< gaxes do end[k] = f2dot14(vd, hdr + gaxes * 2 + k * 2)
						hdr += gaxes * 4
					}
					td := vd[min(ser, len(vd)):min(ser + size, len(vd))]
					ser += size
					s := scalar_of(coords, peak, start, end)
					if s == 0 do continue
					pts := shared_pts
					p := 0
					if index & 0x2000 != 0 do pts, p = read_points(td, 0)
					all := pts == nil
					m := total if all else len(pts)
					dx, p2 := read_deltas(td, p, m)
					dy, _ := read_deltas(td, p2, m)
					if all {
						for i in 0 ..< total do sum[i] += {dx[i], dy[i]} * s
						continue
					}
					del := make([][2]f32, total)
					has := make([]bool, total)
					for pt, i in pts do if pt < total {
						del[pt] = {dx[i], dy[i]}
						has[pt] = true
					}
					if gl.contours > 0 do iup(orig[:total - 4], del[:total - 4], has[:total - 4], gl.ends)
					for i in 0 ..< total do sum[i] += del[i] * s
				}
				for i in 0 ..< total do gl.pts[i] = orig[i] + sum[i]
			}
		}
		gl.advance = max(int(math.round(gl.pts[n + 1].x - gl.pts[n].x)), 0)
		gl.lsb = int(math.round(gl.pts[n].x))
		for &q in gl.pts do q = {math.round(q.x), math.round(q.y)}
	}

	// bounding boxes: simple glyphs from their points, composites from their parts
	done := make([]bool, num_glyphs)
	for g in 0 ..< num_glyphs {
		gl := &glyphs[g]
		if gl.empty || gl.contours < 0 do continue
		n := len(gl.pts) - 4
		if n == 0 do continue
		bb := [4]int{max(int), max(int), min(int), min(int)}
		for q in gl.pts[:n] {
			bb = {min(bb[0], int(q.x)), min(bb[1], int(q.y)), max(bb[2], int(q.x)), max(bb[3], int(q.y))}
		}
		gl.bbox = bb
		done[g] = true
	}
	for _ in 0 ..< 4 { // nested composites settle in a few passes
		for g in 0 ..< num_glyphs {
			gl := &glyphs[g]
			if gl.contours >= 0 || done[g] do continue
			bb := [4]int{max(int), max(int), min(int), min(int)}
			ready := true
			for c, i in gl.comps {
				if c.glyph >= num_glyphs || !done[c.glyph] {
					if c.glyph < num_glyphs && glyphs[c.glyph].empty do continue
					ready = false
					break
				}
				cb := glyphs[c.glyph].bbox
				d := gl.pts[i]
				// the part's corners through its 2×2 transform, if any
				m := [4]f32{1, 0, 0, 1}
				t := c.transform
				switch len(t) {
				case 2: m = {f2dot14(t, 0), 0, 0, f2dot14(t, 0)}
				case 4: m = {f2dot14(t, 0), 0, 0, f2dot14(t, 2)}
				case 8: m = {f2dot14(t, 0), f2dot14(t, 2), f2dot14(t, 4), f2dot14(t, 6)}
				}
				for corner in ([4][2]f32{{f32(cb[0]), f32(cb[1])}, {f32(cb[2]), f32(cb[1])}, {f32(cb[0]), f32(cb[3])}, {f32(cb[2]), f32(cb[3])}}) {
					x := int(math.round(corner.x * m[0] + corner.y * m[2] + d.x))
					y := int(math.round(corner.x * m[1] + corner.y * m[3] + d.y))
					bb = {min(bb[0], x), min(bb[1], y), max(bb[2], x), max(bb[3], y)}
				}
			}
			if !ready do continue
			if bb[0] > bb[2] do bb = {}
			gl.bbox = bb
			done[g] = true
		}
	}

	// glyf, loca and hmtx
	new_glyf := make([dynamic]u8, 0, len(glyf))
	new_loca := make([dynamic]u8, 0, (num_glyphs + 1) * 4)
	new_hmtx := make([dynamic]u8, 0, num_glyphs * 4)
	adv_max := 0
	for g in 0 ..< num_glyphs {
		gl := &glyphs[g]
		put32(&new_loca, len(new_glyf))
		n := len(gl.pts) - 4
		lsb := gl.bbox[0] - gl.lsb
		if !gl.empty && (gl.contours != 0 || len(gl.comps) > 0) {
			put16(&new_glyf, gl.contours if gl.contours >= 0 else 0xFFFF)
			for v in gl.bbox do put16(&new_glyf, v & 0xFFFF)
			if gl.contours >= 0 {
				for e in gl.ends do put16(&new_glyf, e)
				put16(&new_glyf, 0) // no instructions
				for on in gl.on_curve do append(&new_glyf, 1 if on else 0)
				prev: f32
				for q in gl.pts[:n] {put16(&new_glyf, int(q.x - prev) & 0xFFFF); prev = q.x}
				prev = 0
				for q in gl.pts[:n] {put16(&new_glyf, int(q.y - prev) & 0xFFFF); prev = q.y}
			} else {
				for c, i in gl.comps {
					f := (c.flags | 1 | 2) &~ 0x100 // word offsets as x/y values, no instructions
					if i < len(gl.comps) - 1 do f |= 0x20
					else do f &~= 0x20
					put16(&new_glyf, f)
					put16(&new_glyf, c.glyph)
					put16(&new_glyf, int(gl.pts[i].x) & 0xFFFF)
					put16(&new_glyf, int(gl.pts[i].y) & 0xFFFF)
					append(&new_glyf, ..c.transform)
				}
			}
			for len(new_glyf) % 4 != 0 do append(&new_glyf, 0)
		} else {
			lsb = 0
		}
		put16(&new_hmtx, gl.advance)
		put16(&new_hmtx, lsb & 0xFFFF)
		adv_max = max(adv_max, gl.advance)
	}
	put32(&new_loca, len(new_glyf))

	new_head := slice.clone(head)
	new_head[8], new_head[9], new_head[10], new_head[11] = 0, 0, 0, 0 // checksumAdjustment
	new_head[50], new_head[51] = 0, 1 // long loca
	new_hhea := slice.clone(hhea)
	new_hhea[10], new_hhea[11] = u8(adv_max >> 8), u8(adv_max)
	new_hhea[34], new_hhea[35] = u8(num_glyphs >> 8), u8(num_glyphs)

	// the font: every table but the variation ones, with the rebuilt ones swapped in
	drop := [?]string{"fvar", "gvar", "avar", "HVAR", "VVAR", "MVAR", "STAT", "cvar", "DSIG", "hdmx", "LTSH", "VDMX", "fpgm", "prep", "cvt "}
	Entry :: struct {
		tag:  string,
		data: []u8,
	}
	entries := make([dynamic]Entry)
	outer: for tag, data in tables {
		for d in drop do if tag == d do continue outer
		switch tag {
		case "glyf": append(&entries, Entry{tag, new_glyf[:]})
		case "loca": append(&entries, Entry{tag, new_loca[:]})
		case "hmtx": append(&entries, Entry{tag, new_hmtx[:]})
		case "head": append(&entries, Entry{tag, new_head})
		case "hhea": append(&entries, Entry{tag, new_hhea})
		case "OS/2":
			os2 := slice.clone(data)
			for s in settings do if s.tag == "wght" && len(os2) > 6 {
				w := int(math.round(s.value))
				os2[4], os2[5] = u8(w >> 8), u8(w)
			}
			append(&entries, Entry{tag, os2})
		case: append(&entries, Entry{tag, data})
		}
	}
	// the instance's normalised axis coordinates, for the kerning deltas GPOS keeps in
	// GDEF's variation store (fontstash gpos.odin reads them): a private table
	coords_table := make([dynamic]u8)
	put16(&coords_table, axis_count)
	for c in coords do put16(&coords_table, int(math.round(c * 16384)) & 0xFFFF)
	append(&entries, Entry{VAR_COORDS_TAG, coords_table[:]})
	slice.sort_by(entries[:], proc(a, b: Entry) -> bool {return a.tag < b.tag})
	font := make([dynamic]u8, 0, len(new_glyf) * 2)
	nt := len(entries)
	put32(&font, 0x00010000)
	put16(&font, nt)
	sr := 1
	for sr * 2 <= nt do sr *= 2
	put16(&font, sr * 16)
	put16(&font, int(math.log2(f32(sr))))
	put16(&font, nt * 16 - sr * 16)
	at := 12 + nt * 16
	for e in entries {
		append(&font, ..transmute([]u8)e.tag)
		sum: u32 // (wraps around, as the checksum does)
		for i := 0; i < len(e.data); i += 4 {
			w: u32
			for k in 0 ..< 4 do w = w << 8 | (u32(e.data[i + k]) if i + k < len(e.data) else 0)
			sum += w
		}
		put32(&font, int(sum))
		put32(&font, at)
		put32(&font, len(e.data))
		at += (len(e.data) + 3) &~ 3
	}
	for e in entries {
		append(&font, ..e.data)
		for len(font) % 4 != 0 do append(&font, 0)
	}
	// the caller keeps it (fontstash frees it with the font)
	return slice.clone(font[:], runtime.default_allocator()), true
}
