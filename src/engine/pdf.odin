package engine

import "core:c"
import "core:fmt"
import "core:math"
import "core:strings"
import "../fontstash"
import nvg "../nanovg"
import stbi "vendor:stb/image"
import stbtt "vendor:stb/truetype"

// Vector PDF (D59). The layers are drawn by the same code as on the canvas, into a NanoVG
// context whose recorder (nanovg.odin) takes every fill, stroke and text run instead of
// drawing it: paths become PDF paths in their fill rule, strokes keep width, caps, joins and
// dashes, text is real text in the fonts the document uses (embedded whole, TrueType or
// CFF, with a ToUnicode map, so it selects, searches and copies), image fills are the
// image itself. What PDF has no operator for is drawn as an image at 2 px per unit, only
// where it is: gradients (as the canvas samples them) and shadows. Layer and background
// blurs are drawn without their blur. One page per layer, its size in points = units.

PDF_RASTER_SCALE :: 2

Pdf_Font :: struct {
	fs_index: int,
	name:     string,
	cff:      bool,
	widths:   map[u16]f32, // glyph -> advance in 1/1000 em
	uni:      map[u16]rune,
	obj:      int,
}

Pdf_Image :: struct {
	w, h:   int,
	rgba:   []u8,
	smooth: bool,
	obj:    int,
}

Pdf_Page :: struct {
	w, h:    f32,
	content: strings.Builder,
	fonts:   map[int]bool,
	images:  map[int]bool,
	alphas:  map[int]bool,
}

Pdf :: struct {
	rec:        nvg.Recorder,
	pages:      [dynamic]Pdf_Page,
	fonts:      [dynamic]Pdf_Font,
	font_of:    map[int]int, // fontstash index -> fonts
	images:     [dynamic]Pdf_Image,
	image_of:   map[int]int, // nanovg image -> images (files drawn as themselves)
	alpha_vals: [dynamic]f32,
}

// Where images come from, by NanoVG image: their file, or the pixels made for a gradient.
Image_Source :: struct {
	path:   string,
	pixels: []u8,
	w, h:   int,
}

image_sources: map[int]Image_Source

pdf_n :: proc(b: ^strings.Builder, v: f32) {
	s := fmt.tprintf("%.3f", v)
	s = strings.trim_right(s, "0")
	s = strings.trim_right(s, ".")
	if s == "-0" || s == "" do s = "0"
	strings.write_string(b, s)
	strings.write_byte(b, ' ')
}

pdf_page :: proc(p: ^Pdf) -> ^Pdf_Page {
	return &p.pages[len(p.pages) - 1]
}

pdf_alpha :: proc(p: ^Pdf, a: f32) -> int {
	for v, i in p.alpha_vals do if abs(v - a) < 0.002 do return i
	append(&p.alpha_vals, a)
	return len(p.alpha_vals) - 1
}

pdf_set_alpha :: proc(p: ^Pdf, b: ^strings.Builder, a: f32) {
	if a >= 0.999 do return
	i := pdf_alpha(p, a)
	pdf_page(p).alphas[i] = true
	fmt.sbprintf(b, "/GA%d gs\n", i)
}

pdf_clip_scissor :: proc(b: ^strings.Builder, s: ^nvg.ScissorT) {
	if s.extent[0] < 0 do return
	ex, ey := s.extent[0], s.extent[1]
	corners := [4][2]f32{{-ex, -ey}, {ex, -ey}, {ex, ey}, {-ex, ey}}
	for p, i in corners {
		x := s.xform[0] * p.x + s.xform[2] * p.y + s.xform[4]
		y := s.xform[1] * p.x + s.xform[3] * p.y + s.xform[5]
		pdf_n(b, x)
		pdf_n(b, y)
		strings.write_string(b, "m\n" if i == 0 else "l\n")
	}
	strings.write_string(b, "h W n\n")
}

Pdf_Seg :: struct {
	kind: nvg.Commands,
	p:    [3][2]f32,
}

// Writes NanoVG path commands as PDF path operators. With `windings`, each subpath is
// turned the way NanoVG would fill it (solid ones one way, holes the other), so PDF's
// nonzero rule fills what the canvas fills. Returns the path's bounds.
pdf_path :: proc(b: ^strings.Builder, cmds: []f32, windings: bool) -> (lo, hi: [2]f32) {
	lo, hi = {max(f32), max(f32)}, {-max(f32), -max(f32)}
	subs := make([dynamic][dynamic]Pdf_Seg, context.temp_allocator)
	wind := make([dynamic]nvg.Winding, context.temp_allocator)
	closed := make([dynamic]bool, context.temp_allocator)
	grow :: proc(lo, hi: ^[2]f32, p: [2]f32) {
		lo^ = {min(lo.x, p.x), min(lo.y, p.y)}
		hi^ = {max(hi.x, p.x), max(hi.y, p.y)}
	}
	i := 0
	for i < len(cmds) {
		k := nvg.Commands(int(cmds[i]))
		switch k {
		case .MOVE_TO:
			append(&subs, make([dynamic]Pdf_Seg, context.temp_allocator))
			append(&wind, nvg.Winding.CCW)
			append(&closed, false)
			p := [2]f32{cmds[i + 1], cmds[i + 2]}
			append(&subs[len(subs) - 1], Pdf_Seg{.MOVE_TO, {p, p, p}})
			grow(&lo, &hi, p)
			i += 3
		case .LINE_TO:
			p := [2]f32{cmds[i + 1], cmds[i + 2]}
			if len(subs) > 0 do append(&subs[len(subs) - 1], Pdf_Seg{.LINE_TO, {p, p, p}})
			grow(&lo, &hi, p)
			i += 3
		case .BEZIER_TO:
			c1, c2, p := [2]f32{cmds[i + 1], cmds[i + 2]}, [2]f32{cmds[i + 3], cmds[i + 4]}, [2]f32{cmds[i + 5], cmds[i + 6]}
			if len(subs) > 0 do append(&subs[len(subs) - 1], Pdf_Seg{.BEZIER_TO, {c1, c2, p}})
			grow(&lo, &hi, c1)
			grow(&lo, &hi, c2)
			grow(&lo, &hi, p)
			i += 7
		case .CLOSE:
			if len(closed) > 0 do closed[len(closed) - 1] = true
			i += 1
		case .WINDING:
			if len(wind) > 0 do wind[len(wind) - 1] = nvg.Winding(int(cmds[i + 1]))
			i += 2
		case:
			i += 1
		}
	}
	for sub, si in subs {
		if len(sub) == 0 do continue
		reverse := false
		if windings && len(sub) > 2 {
			// NanoVG's polyArea over the points (control points stand in for curves)
			pts := make([dynamic][2]f32, context.temp_allocator)
			for s in sub {
				if s.kind == .BEZIER_TO do append(&pts, s.p[0], s.p[1])
				append(&pts, s.p[2])
			}
			area: f32
			for j in 2 ..< len(pts) {
				a, bb, cc := pts[0], pts[j - 1], pts[j]
				area += ((cc.x - a.x) * (bb.y - a.y) - (bb.x - a.x) * (cc.y - a.y)) * 0.5
			}
			reverse = (wind[si] == .CCW && area < 0) || (wind[si] == .CW && area > 0)
		}
		if !reverse {
			for s in sub {
				switch s.kind {
				case .MOVE_TO: pdf_n(b, s.p[2].x); pdf_n(b, s.p[2].y); strings.write_string(b, "m\n")
				case .LINE_TO: pdf_n(b, s.p[2].x); pdf_n(b, s.p[2].y); strings.write_string(b, "l\n")
				case .BEZIER_TO:
					for q in s.p {pdf_n(b, q.x); pdf_n(b, q.y)}
					strings.write_string(b, "c\n")
				case .CLOSE, .WINDING:
				}
			}
		} else {
			// the same segments backwards: from the last point to the first
			last := sub[len(sub) - 1].p[2]
			pdf_n(b, last.x); pdf_n(b, last.y); strings.write_string(b, "m\n")
			for j := len(sub) - 1; j >= 1; j -= 1 {
				s := sub[j]
				prev := sub[j - 1].p[2]
				if s.kind == .BEZIER_TO {
					pdf_n(b, s.p[1].x); pdf_n(b, s.p[1].y)
					pdf_n(b, s.p[0].x); pdf_n(b, s.p[0].y)
					pdf_n(b, prev.x); pdf_n(b, prev.y)
					strings.write_string(b, "c\n")
				} else {
					pdf_n(b, prev.x); pdf_n(b, prev.y); strings.write_string(b, "l\n")
				}
			}
		}
		if closed[si] do strings.write_string(b, "h\n")
	}
	return
}

// Colours are sRGB, as the canvas draws them: in the page's ICC-based sRGB space /CS0
// (DeviceRGB would be shown through a generic profile, #16A34A as #4CA154).
pdf_color :: proc(b: ^strings.Builder, c: nvg.Color, stroke: bool) {
	strings.write_string(b, "/CS0 CS " if stroke else "/CS0 cs ")
	pdf_n(b, c.r)
	pdf_n(b, c.g)
	pdf_n(b, c.b)
	strings.write_string(b, "SC\n" if stroke else "sc\n")
}

SRGB_PROFILE :: "/System/Library/ColorSync/Profiles/sRGB Profile.icc"

paint_is_solid :: proc(p: ^nvg.Paint) -> bool {
	return p.image == 0 && p.innerColor == p.outerColor
}

pdf_fill :: proc(r: ^nvg.Recorder, paint: ^nvg.Paint, scissor: ^nvg.ScissorT, cmds: []f32) {
	p := cast(^Pdf)r.user
	b := &pdf_page(p).content
	strings.write_string(b, "q\n")
	pdf_clip_scissor(b, scissor)
	if paint_is_solid(paint) {
		if paint.innerColor.a <= 0 {
			strings.write_string(b, "n Q\n")
			return
		}
		pdf_set_alpha(p, b, paint.innerColor.a)
		pdf_color(b, paint.innerColor, false)
		pdf_path(b, cmds, true)
		strings.write_string(b, "f\nQ\n")
		return
	}
	lo, hi := pdf_path(b, cmds, true)
	strings.write_string(b, "W n\n")
	if src, has := image_sources[paint.image]; has && paint.image != 0 && src.path != "" {
		// an image fill: the image itself, placed as the paint places it
		idx := pdf_file_image(p, paint.image, src)
		if idx >= 0 {
			pdf_set_alpha(p, b, paint.innerColor.a)
			m := paint.xform
			ex, ey := paint.extent[0], paint.extent[1]
			// unit square (row 0 at the top) -> extent rect -> paint transform
			a, bb, cc, d := m[0] * ex, m[1] * ex, -m[2] * ey, -m[3] * ey
			e, f := m[2] * ey + m[4], m[3] * ey + m[5]
			for v in ([6]f32{a, bb, cc, d, e, f}) do pdf_n(b, v)
			fmt.sbprintf(b, "cm /Im%d Do\n", idx)
			pdf_page(p).images[idx] = true
		}
		strings.write_string(b, "Q\n")
		return
	}
	// a gradient or a shadow: sampled as the canvas does, over the path's bounds
	pdf_raster_paint(p, b, paint, lo, hi, scissor)
	strings.write_string(b, "Q\n")
}

pdf_stroke :: proc(r: ^nvg.Recorder, paint: ^nvg.Paint, scissor: ^nvg.ScissorT, cmds: []f32, width: f32, cap, join: nvg.LineCapType, miter: f32, dash: []f32) {
	p := cast(^Pdf)r.user
	b := &pdf_page(p).content
	if paint.innerColor.a <= 0 || width <= 0 do return
	strings.write_string(b, "q\n")
	pdf_clip_scissor(b, scissor)
	pdf_set_alpha(p, b, paint.innerColor.a)
	pdf_color(b, paint.innerColor, true)
	pdf_n(b, width)
	strings.write_string(b, "w\n")
	pdf_cap := 1 if cap == .ROUND else (2 if cap == .SQUARE else 0)
	pdf_join := 1 if join == .ROUND else (2 if join == .BEVEL else 0)
	fmt.sbprintf(b, "%d J %d j ", pdf_cap, pdf_join)
	pdf_n(b, max(miter, 1))
	strings.write_string(b, "M\n")
	if len(dash) > 0 {
		strings.write_byte(b, '[')
		for d in dash do pdf_n(b, d)
		strings.write_string(b, "] 0 d\n")
	}
	pdf_path(b, cmds, false)
	strings.write_string(b, "S\nQ\n")
}

// The font and glyph that draw a code point, as fontstash picks them (fallbacks included).
pdf_glyph_font :: proc(fs: ^fontstash.FontContext, base: int, cp: rune) -> (font: int, gid: i32) {
	f := &fs.fonts[base]
	if g := stbtt.FindGlyphIndex(&f.info, cp); g != 0 do return base, g
	for k in 0 ..< f.nfallbacks {
		fb := &fs.fonts[f.fallbacks[k]]
		if g := stbtt.FindGlyphIndex(&fb.info, cp); g != 0 do return f.fallbacks[k], g
	}
	return base, 0
}

pdf_font :: proc(p: ^Pdf, fs: ^fontstash.FontContext, index: int) -> int {
	if i, has := p.font_of[index]; has do return i
	f := &fs.fonts[index]
	data := f.loadedData
	cff := len(data) > 4 && string(data[:4]) == "OTTO"
	// a single font (not a collection) with glyf outlines, or a CFF one of modest size
	embeddable := f.info.fontstart == 0 && len(data) > 12 && (sfnt_has_table(data, "glyf") || (cff && len(data) < 4 << 20))
	if !embeddable {
		p.font_of[index] = -1
		return -1
	}
	name := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&name, "%c%c%c%c%c%c+", 'A' + len(p.fonts) / 26 % 26, 'A' + len(p.fonts) % 26, 'P', 'D', 'F', 'A')
	base := f.name
	if i := strings.last_index_byte(base, '/'); i >= 0 do base = base[i + 1:]
	if i := strings.last_index_byte(base, '.'); i > 0 do base = base[:i]
	for ch in base do if (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '-' do strings.write_rune(&name, ch)
	if strings.builder_len(name) == 7 do strings.write_string(&name, "Font")
	append(&p.fonts, Pdf_Font{fs_index = index, name = strings.clone(strings.to_string(name)), cff = cff})
	p.font_of[index] = len(p.fonts) - 1
	return len(p.fonts) - 1
}

pdf_text :: proc(r: ^nvg.Recorder, run: ^nvg.Text_Run) {
	p := cast(^Pdf)r.user
	if len(run.glyphs) == 0 || run.color.a <= 0 do return
	fs := &renderer.fs
	b := &pdf_page(p).content
	xf := run.xform
	strings.write_string(b, "q\n")
	pdf_clip_scissor(b, &run.scissor)
	pdf_set_alpha(p, b, run.color.a)
	pdf_color(b, run.color, false)
	strings.write_string(b, "BT\n")
	if run.spacing != 0 {
		// letter spacing as the text's own character spacing: viewers keep the word whole
		pdf_n(b, run.spacing)
		strings.write_string(b, "Tc\n")
	}
	cur_font := -1
	open := false // inside a TJ array
	prev_x, prev_adv: f32
	prev_y := f32(-1e9)
	for g in run.glyphs {
		if g.codepoint == ' ' || g.codepoint == '\n' || g.codepoint == '\t' {
			// spaces as glyphs too when the font has one (copied text keeps its words)
		}
		fi, gid := pdf_glyph_font(fs, run.font, g.codepoint)
		pf := pdf_font(p, fs, fi)
		if gid == 0 do continue
		if pf < 0 {
			// a font PDF cannot embed (a collection, bitmap glyphs): its outline, filled
			if open {strings.write_string(b, "] TJ\n"); open = false}
			strings.write_string(b, "ET\n")
			pdf_glyph_outline(b, fs, fi, gid, run, g)
			strings.write_string(b, "BT\n")
			cur_font = -1
			continue
		}
		font := &p.fonts[pf]
		f := &fs.fonts[fi]
		em := stbtt.ScaleForMappingEmToPixels(&f.info, 1)
		adv, lsb: i32
		stbtt.GetGlyphHMetrics(&f.info, gid, &adv, &lsb)
		w := f32(adv) * em * 1000
		font.widths[u16(gid)] = w
		if u16(gid) not_in font.uni do font.uni[u16(gid)] = g.codepoint
		straight := xf[1] == 0 && xf[2] == 0
		if pf != cur_font || !straight || abs(g.y - prev_y) > 0.01 || !open {
			if open {strings.write_string(b, "] TJ\n"); open = false}
			if pf != cur_font {
				fmt.sbprintf(b, "/F%d ", pf)
				pdf_n(b, run.size)
				strings.write_string(b, "Tf\n")
				cur_font = pf
				pdf_page(p).fonts[pf] = true
			}
			ex := xf[0] * g.x + xf[2] * g.y + xf[4]
			ey := xf[1] * g.x + xf[3] * g.y + xf[5]
			// the baseline on a whole unit, as the canvas puts it on a whole pixel at 1x
			if straight && xf[0] == 1 && xf[3] == 1 do ey = math.round(ey)
			for v in ([6]f32{xf[0], xf[1], -xf[2], -xf[3], ex, ey}) do pdf_n(b, v)
			strings.write_string(b, "Tm [")
			open = true
		} else {
			// how far this glyph is from where the previous one's advance left the pen
			adj := (prev_adv * run.size / 1000 + run.spacing - (g.x - prev_x)) * 1000 / run.size
			if abs(adj) > 0.01 do pdf_n(b, adj)
		}
		fmt.sbprintf(b, "<%04X>", gid)
		prev_x, prev_y, prev_adv = g.x, g.y, w
	}
	if open do strings.write_string(b, "] TJ\n")
	strings.write_string(b, "ET\nQ\n")
}

pdf_file_image :: proc(p: ^Pdf, img: int, src: Image_Source) -> int {
	if i, has := p.image_of[img]; has do return i
	data, ok := read_file(src.path, context.temp_allocator)
	idx := -1
	if ok {
		w, h, ch: c.int
		px := stbi.load_from_memory(raw_data(data), c.int(len(data)), &w, &h, &ch, 4)
		if px != nil {
			rgba := make([]u8, int(w * h * 4))
			copy(rgba, px[:w * h * 4])
			stbi.image_free(px)
			append(&p.images, Pdf_Image{w = int(w), h = int(h), rgba = rgba, smooth = true})
			idx = len(p.images) - 1
		}
	}
	p.image_of[img] = idx
	return idx
}

// A paint PDF cannot draw (a gradient, a feathered shadow) as an image over [lo, hi]: each
// pixel takes the colour the canvas's shader gives it.
pdf_raster_paint :: proc(p: ^Pdf, b: ^strings.Builder, paint: ^nvg.Paint, lo_in, hi_in: [2]f32, scissor: ^nvg.ScissorT) {
	lo, hi := lo_in, hi_in
	if scissor.extent[0] >= 0 && scissor.xform[1] == 0 && scissor.xform[2] == 0 {
		cx, cy := scissor.xform[4], scissor.xform[5]
		ex, ey := scissor.extent[0] * abs(scissor.xform[0]), scissor.extent[1] * abs(scissor.xform[3])
		lo = {max(lo.x, cx - ex), max(lo.y, cy - ey)}
		hi = {min(hi.x, cx + ex), min(hi.y, cy + ey)}
	}
	if hi.x <= lo.x || hi.y <= lo.y do return
	s := f32(PDF_RASTER_SCALE)
	w := clamp(int(math.ceil((hi.x - lo.x) * s)), 1, 2048)
	h := clamp(int(math.ceil((hi.y - lo.y) * s)), 1, 2048)
	sx, sy := (hi.x - lo.x) / f32(w), (hi.y - lo.y) / f32(h)
	inv: nvg.Matrix
	nvg.TransformInverse(&inv, paint.xform)
	src, has_src := image_sources[paint.image]
	rgba := make([]u8, w * h * 4)
	for y in 0 ..< h {
		for x in 0 ..< w {
			px, py := lo.x + (f32(x) + 0.5) * sx, lo.y + (f32(y) + 0.5) * sy
			u := inv[0] * px + inv[2] * py + inv[4]
			v := inv[1] * px + inv[3] * py + inv[5]
			col: [4]f32
			if paint.image != 0 && has_src && len(src.pixels) > 0 {
				// the gradient's image, clamped at its edges (as the texture is sampled)
				tx := clamp(int(u / paint.extent[0] * f32(src.w)), 0, src.w - 1)
				ty := clamp(int(v / paint.extent[1] * f32(src.h)), 0, src.h - 1)
				o := (ty * src.w + tx) * 4
				a := f32(src.pixels[o + 3]) / 255 * paint.innerColor.a
				col = {f32(src.pixels[o]) / 255, f32(src.pixels[o + 1]) / 255, f32(src.pixels[o + 2]) / 255, a}
			} else {
				// NanoVG's gradient shader: a rounded box distance through the feather
				ex, ey := paint.extent[0] - paint.radius, paint.extent[1] - paint.radius
				dx, dy := abs(u) - ex, abs(v) - ey
				sd := min(max(dx, dy), 0) + math.sqrt(max(dx, 0) * max(dx, 0) + max(dy, 0) * max(dy, 0)) - paint.radius
				t := clamp((sd + paint.feather * 0.5) / max(paint.feather, 0.0001), 0, 1)
				ic, oc := paint.innerColor, paint.outerColor
				pa := ic.a + (oc.a - ic.a) * t
				if pa > 0 {
					col.r = (ic.r * ic.a + (oc.r * oc.a - ic.r * ic.a) * t) / pa
					col.g = (ic.g * ic.a + (oc.g * oc.a - ic.g * ic.a) * t) / pa
					col.b = (ic.b * ic.a + (oc.b * oc.a - ic.b * ic.a) * t) / pa
				}
				col.a = pa
			}
			o := (y * w + x) * 4
			for k in 0 ..< 4 do rgba[o + k] = u8(clamp(col[k], 0, 1) * 255 + 0.5)
		}
	}
	append(&p.images, Pdf_Image{w = w, h = h, rgba = rgba, smooth = true})
	idx := len(p.images) - 1
	pdf_page(p).images[idx] = true
	ww, hh := hi.x - lo.x, hi.y - lo.y
	for v in ([6]f32{ww, 0, 0, -hh, lo.x, lo.y + hh}) do pdf_n(b, v)
	fmt.sbprintf(b, "cm /Im%d Do\n", idx)
}

// Draws each layer onto a page of its own and returns the PDF file.
export_pdf :: proc(vg: ^nvg.Context, doc: ^Document, uids: []int) -> (file: []u8, ok: bool) {
	p := new(Pdf, context.temp_allocator)
	p.rec = {fill = pdf_fill, stroke = pdf_stroke, text = pdf_text, user = p}
	p.font_of = make(map[int]int, 8, context.temp_allocator)
	p.image_of = make(map[int]int, 8, context.temp_allocator)
	defer for &f in p.fonts {
		delete(f.widths)
		delete(f.uni)
		delete(f.name)
	}
	defer for &im in p.images do delete(im.rgba)
	defer for &pg in p.pages {
		strings.builder_destroy(&pg.content)
		delete(pg.fonts)
		delete(pg.images)
		delete(pg.alphas)
	}
	layout_document(doc)
	saved_cull, saved_blur, saved_lod := cull_rect, blur_active, lod_scale
	defer cull_rect, blur_active, lod_scale = saved_cull, saved_blur, saved_lod
	blur_active, lod_scale = false, 0
	for uid in uids {
		n, _ := doc_find_uid(doc, uid)
		if n == nil do continue
		box := node_page_box(n)
		append(&p.pages, Pdf_Page{w = box[2], h = box[3], content = strings.builder_make()})
		cull_rect = box
		nvg.Save(vg)
		nvg.ResetTransform(vg)
		nvg.ResetScissor(vg)
		nvg.Translate(vg, -box.x, -box.y)
		vg.recorder = &p.rec
		draw_node_tree(vg, n, 1, 0, force = true)
		vg.recorder = nil
		nvg.Restore(vg)
	}
	if len(p.pages) == 0 do return nil, false
	return pdf_write(p), true
}

// Serialises pages, fonts, images and alpha states into a PDF file.
pdf_write :: proc(p: ^Pdf) -> []u8 {
	out := strings.builder_make()
	offsets := make([dynamic]int, context.temp_allocator)
	append(&offsets, 0)
	strings.write_string(&out, "%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
	next := 1
	reserve :: proc(next: ^int) -> int {
		n := next^
		next^ += 1
		return n
	}
	begin :: proc(out: ^strings.Builder, offsets: ^[dynamic]int, n: int) {
		for len(offsets) <= n do append(offsets, 0)
		offsets[n] = strings.builder_len(out^)
		fmt.sbprintf(out, "%d 0 obj\n", n)
	}
	stream :: proc(out: ^strings.Builder, dict: string, data: []u8) {
		z := pdf_deflate(data)
		if z != nil {
			fmt.sbprintf(out, "<<%s /Filter /FlateDecode /Length %d>>\nstream\n", dict, len(z))
			strings.write_bytes(out, z)
		} else {
			fmt.sbprintf(out, "<<%s /Length %d>>\nstream\n", dict, len(data))
			strings.write_bytes(out, data)
		}
		strings.write_string(out, "\nendstream\nendobj\n")
	}
	catalog, pages_obj := reserve(&next), reserve(&next)
	fs := &renderer.fs
	// the sRGB colour space every page and image uses
	cs_ref := "/DeviceRGB"
	if icc, ok := read_file(SRGB_PROFILE, context.temp_allocator); ok {
		icc_obj := reserve(&next)
		begin(&out, &offsets, icc_obj)
		stream(&out, " /N 3 /Alternate /DeviceRGB", icc)
		cs_ref = fmt.tprintf("[/ICCBased %d 0 R]", icc_obj)
	}
	// fonts
	for &font in p.fonts {
		f := &fs.fonts[font.fs_index]
		em := stbtt.ScaleForMappingEmToPixels(&f.info, 1)
		file_obj, desc_obj, cid_obj, uni_obj := reserve(&next), reserve(&next), reserve(&next), reserve(&next)
		font.obj = reserve(&next)
		begin(&out, &offsets, file_obj)
		if font.cff {
			stream(&out, " /Subtype /OpenType", f.loadedData)
		} else {
			sub, sok := pdf_subset_ttf(f.loadedData, font.widths)
			if !sok do sub = f.loadedData
			stream(&out, fmt.tprintf(" /Length1 %d", len(sub)), sub)
			if sok do delete(sub)
		}
		x0, y0, x1, y1: c.int
		stbtt.GetFontBoundingBox(&f.info, &x0, &y0, &x1, &y1)
		begin(&out, &offsets, desc_obj)
		fmt.sbprintf(&out, "<</Type /FontDescriptor /FontName /%s /Flags 4 /FontBBox [%d %d %d %d] /ItalicAngle 0 /Ascent %d /Descent %d /CapHeight %d /StemV 80 /%s %d 0 R>>\nendobj\n",
			font.name, int(f32(x0) * em * 1000), int(f32(y0) * em * 1000), int(f32(x1) * em * 1000), int(f32(y1) * em * 1000),
			int(f.ascender * 1000), int(f.descender * 1000), int(f.ascender * 700), "FontFile3" if font.cff else "FontFile2", file_obj)
		begin(&out, &offsets, cid_obj)
		wb := strings.builder_make(context.temp_allocator)
		for gid, w in font.widths do fmt.sbprintf(&wb, "%d [%d] ", gid, int(w + 0.5))
		fmt.sbprintf(&out, "<</Type /Font /Subtype /%s /BaseFont /%s /CIDSystemInfo <</Registry (Adobe) /Ordering (Identity) /Supplement 0>> /FontDescriptor %d 0 R /W [%s]%s>>\nendobj\n",
			"CIDFontType0" if font.cff else "CIDFontType2", font.name, desc_obj, strings.to_string(wb), "" if font.cff else " /CIDToGIDMap /Identity")
		cm := strings.builder_make(context.temp_allocator)
		strings.write_string(&cm, "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CIDSystemInfo <</Registry (Adobe) /Ordering (UCS) /Supplement 0>> def\n/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n")
		count := 0
		for _, _ in font.uni do count += 1
		done := 0
		for gid, cp in font.uni {
			if done % 100 == 0 do fmt.sbprintf(&cm, "%d beginbfchar\n", min(100, count - done))
			r := u32(cp)
			if r >= 0x10000 {
				v := r - 0x10000
				fmt.sbprintf(&cm, "<%04X> <%04X%04X>\n", gid, 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF))
			} else {
				fmt.sbprintf(&cm, "<%04X> <%04X>\n", gid, r)
			}
			done += 1
			if done % 100 == 0 || done == count do strings.write_string(&cm, "endbfchar\n")
		}
		strings.write_string(&cm, "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n")
		begin(&out, &offsets, uni_obj)
		stream(&out, "", transmute([]u8)strings.to_string(cm))
		begin(&out, &offsets, font.obj)
		fmt.sbprintf(&out, "<</Type /Font /Subtype /Type0 /BaseFont /%s /Encoding /Identity-H /DescendantFonts [%d 0 R] /ToUnicode %d 0 R>>\nendobj\n", font.name, cid_obj, uni_obj)
	}
	// images, with their alpha as a soft mask
	for &im in p.images {
		n := im.w * im.h
		rgb := make([]u8, n * 3, context.temp_allocator)
		alpha := make([]u8, n, context.temp_allocator)
		opaque := true
		for i in 0 ..< n {
			rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2] = im.rgba[i * 4], im.rgba[i * 4 + 1], im.rgba[i * 4 + 2]
			alpha[i] = im.rgba[i * 4 + 3]
			if alpha[i] != 255 do opaque = false
		}
		mask := 0
		if !opaque {
			mask = reserve(&next)
			begin(&out, &offsets, mask)
			stream(&out, fmt.tprintf(" /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceGray /BitsPerComponent 8%s", im.w, im.h, " /Interpolate true" if im.smooth else ""), alpha)
		}
		im.obj = reserve(&next)
		begin(&out, &offsets, im.obj)
		stream(&out, fmt.tprintf(" /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace %s /BitsPerComponent 8%s%s", im.w, im.h, cs_ref, " /Interpolate true" if im.smooth else "", fmt.tprintf(" /SMask %d 0 R", mask) if mask != 0 else ""), rgb)
	}
	// pages
	page_objs := make([dynamic]int, context.temp_allocator)
	for &pg in p.pages {
		content := strings.builder_make(context.temp_allocator)
		// y down, as the canvas: the page flipped once
		fmt.sbprintf(&content, "1 0 0 -1 0 ")
		pdf_n(&content, pg.h)
		strings.write_string(&content, "cm\n")
		strings.write_string(&content, strings.to_string(pg.content))
		cobj := reserve(&next)
		begin(&out, &offsets, cobj)
		stream(&out, "", transmute([]u8)strings.to_string(content))
		res := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&res, "<</ColorSpace <</CS0 %s>> ", cs_ref)
		if len(pg.fonts) > 0 {
			strings.write_string(&res, "/Font <<")
			for fi in pg.fonts do fmt.sbprintf(&res, "/F%d %d 0 R ", fi, p.fonts[fi].obj)
			strings.write_string(&res, ">> ")
		}
		if len(pg.images) > 0 {
			strings.write_string(&res, "/XObject <<")
			for ii in pg.images do fmt.sbprintf(&res, "/Im%d %d 0 R ", ii, p.images[ii].obj)
			strings.write_string(&res, ">> ")
		}
		if len(pg.alphas) > 0 {
			strings.write_string(&res, "/ExtGState <<")
			for ai in pg.alphas do fmt.sbprintf(&res, "/GA%d <</ca %.3f /CA %.3f>> ", ai, p.alpha_vals[ai], p.alpha_vals[ai])
			strings.write_string(&res, ">> ")
		}
		strings.write_string(&res, ">>")
		pobj := reserve(&next)
		begin(&out, &offsets, pobj)
		mb := strings.builder_make(context.temp_allocator)
		pdf_n(&mb, pg.w)
		pdf_n(&mb, pg.h)
		fmt.sbprintf(&out, "<</Type /Page /Parent %d 0 R /MediaBox [0 0 %s] /Contents %d 0 R /Resources %s>>\nendobj\n", pages_obj, strings.trim_space(strings.to_string(mb)), cobj, strings.to_string(res))
		append(&page_objs, pobj)
	}
	begin(&out, &offsets, pages_obj)
	kids := strings.builder_make(context.temp_allocator)
	for po in page_objs do fmt.sbprintf(&kids, "%d 0 R ", po)
	fmt.sbprintf(&out, "<</Type /Pages /Kids [%s] /Count %d>>\nendobj\n", strings.to_string(kids), len(page_objs))
	begin(&out, &offsets, catalog)
	fmt.sbprintf(&out, "<</Type /Catalog /Pages %d 0 R>>\nendobj\n", pages_obj)
	xref := strings.builder_len(out)
	fmt.sbprintf(&out, "xref\n0 %d\n0000000000 65535 f \n", next)
	for i in 1 ..< next do fmt.sbprintf(&out, "%010d 00000 n \n", offsets[i] if i < len(offsets) else 0)
	fmt.sbprintf(&out, "trailer\n<</Size %d /Root %d 0 R>>\nstartxref\n%d\n%%%%EOF\n", next, catalog, xref)
	return out.buf[:]
}

// ---------------------------------------------------------------- TrueType subsets

be16 :: proc(d: []u8, o: int) -> int {return int(d[o]) << 8 | int(d[o + 1])}
be32 :: proc(d: []u8, o: int) -> int {return int(d[o]) << 24 | int(d[o + 1]) << 16 | int(d[o + 2]) << 8 | int(d[o + 3])}
put_be16 :: proc(b: ^[dynamic]u8, v: int) {append(b, u8(v >> 8), u8(v))}
put_be32 :: proc(b: ^[dynamic]u8, v: int) {append(b, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))}

// A TrueType font with only the glyphs `used` draws (and the parts of composite ones);
// every other glyph is empty, so glyph ids stay the same. Hinting and the cmap go (a PDF's
// CIDFontType2 maps glyph ids itself). ok = false when the font has no glyf outlines.
pdf_subset_ttf :: proc(data: []u8, used: map[u16]f32) -> (out: []u8, ok: bool) {
	if len(data) < 12 do return
	ntables := be16(data, 4)
	Table :: struct {tag: string, off, len: int}
	tables := make(map[string]Table, 32, context.temp_allocator)
	for i in 0 ..< ntables {
		r := 12 + i * 16
		if r + 16 > len(data) do return
		t := Table{string(data[r:r + 4]), be32(data, r + 8), be32(data, r + 12)}
		if t.off + t.len > len(data) do return
		tables[t.tag] = t
	}
	for need in ([?]string{"head", "hhea", "maxp", "hmtx", "loca", "glyf"}) do if need not_in tables do return
	head, maxp, loca, glyf := tables["head"], tables["maxp"], tables["loca"], tables["glyf"]
	long_loca := be16(data, head.off + 50) == 1
	nglyphs := be16(data, maxp.off + 4)
	glyph_range :: proc(data: []u8, loca: Table, long_loca: bool, g: int) -> (int, int) {
		if long_loca do return be32(data, loca.off + g * 4), be32(data, loca.off + g * 4 + 4)
		return be16(data, loca.off + g * 2) * 2, be16(data, loca.off + g * 2 + 2) * 2
	}
	keep := make([]bool, nglyphs, context.temp_allocator)
	stack := make([dynamic]int, context.temp_allocator)
	append(&stack, 0) // .notdef
	for g in used do if int(g) < nglyphs do append(&stack, int(g))
	for len(stack) > 0 {
		g := pop(&stack)
		if keep[g] do continue
		keep[g] = true
		s, e := glyph_range(data, loca, long_loca, g)
		if e - s < 10 || glyf.off + e > len(data) do continue
		p := glyf.off + s
		if i16(be16(data, p)) >= 0 do continue // simple glyph
		// composite: walk its components
		q := p + 10
		for q + 4 <= glyf.off + e {
			flags := be16(data, q)
			append(&stack, be16(data, q + 2))
			q += 4 + (4 if flags & 0x1 != 0 else 2)
			if flags & 0x8 != 0 do q += 2
			else if flags & 0x40 != 0 do q += 4
			else if flags & 0x80 != 0 do q += 8
			if flags & 0x20 == 0 do break
		}
	}
	new_glyf := make([dynamic]u8, context.temp_allocator)
	new_loca := make([dynamic]u8, context.temp_allocator)
	for g in 0 ..< nglyphs {
		put_be32(&new_loca, len(new_glyf))
		if !keep[g] do continue
		s, e := glyph_range(data, loca, long_loca, g)
		if e > s && glyf.off + e <= len(data) {
			append(&new_glyf, ..data[glyf.off + s:glyf.off + e])
			for len(new_glyf) % 4 != 0 do append(&new_glyf, 0)
		}
	}
	put_be32(&new_loca, len(new_glyf))
	new_head := make([dynamic]u8, context.temp_allocator)
	append(&new_head, ..data[head.off:head.off + head.len])
	new_head[8], new_head[9], new_head[10], new_head[11] = 0, 0, 0, 0 // checkSumAdjustment
	new_head[50], new_head[51] = 0, 1 // long loca
	post := make([dynamic]u8, context.temp_allocator)
	if pt, has := tables["post"]; has && pt.len >= 32 {
		append(&post, ..data[pt.off:pt.off + 32])
		post[0], post[1], post[2], post[3] = 0, 3, 0, 0 // version 3: no glyph names
	}
	Out :: struct {tag: string, data: []u8}
	outs := make([dynamic]Out, context.temp_allocator)
	for tag in ([?]string{"OS/2", "hhea", "hmtx", "maxp", "name"}) {
		if t, has := tables[tag]; has do append(&outs, Out{tag, data[t.off:t.off + t.len]})
	}
	append(&outs, Out{"glyf", new_glyf[:]}, Out{"head", new_head[:]}, Out{"loca", new_loca[:]})
	if len(post) > 0 do append(&outs, Out{"post", post[:]})
	// sorted by tag, as the directory must be
	for i in 1 ..< len(outs) {
		for j := i; j > 0 && outs[j].tag < outs[j - 1].tag; j -= 1 do outs[j], outs[j - 1] = outs[j - 1], outs[j]
	}
	buf := make([dynamic]u8)
	n := len(outs)
	es := 0
	for (1 << uint(es + 1)) <= n do es += 1
	put_be32(&buf, 0x00010000)
	put_be16(&buf, n)
	put_be16(&buf, (1 << uint(es)) * 16)
	put_be16(&buf, es)
	put_be16(&buf, n * 16 - (1 << uint(es)) * 16)
	off := 12 + n * 16
	for t in outs {
		sum: u32
		for k := 0; k < len(t.data); k += 4 {
			w: u32
			for m in 0 ..< 4 do w = w << 8 | (u32(t.data[k + m]) if k + m < len(t.data) else 0)
			sum += w
		}
		append(&buf, ..transmute([]u8)t.tag)
		put_be32(&buf, int(sum))
		put_be32(&buf, off)
		put_be32(&buf, len(t.data))
		off += (len(t.data) + 3) &~ 3
	}
	for t in outs {
		append(&buf, ..t.data)
		for len(buf) % 4 != 0 do append(&buf, 0)
	}
	return buf[:], true
}

sfnt_has_table :: proc(data: []u8, tag: string) -> bool {
	if len(data) < 12 do return false
	for i in 0 ..< be16(data, 4) {
		r := 12 + i * 16
		if r + 16 <= len(data) && string(data[r:r + 4]) == tag do return true
	}
	return false
}

// One glyph as a filled path (fonts that cannot be embedded), in the run's colour (set).
pdf_glyph_outline :: proc(b: ^strings.Builder, fs: ^fontstash.FontContext, fi: int, gid: i32, run: ^nvg.Text_Run, g: nvg.Text_Glyph) {
	f := &fs.fonts[fi]
	o := glyph_outline(fi, f, gid)
	if len(o.verts) == 0 do return
	s := stbtt.ScaleForMappingEmToPixels(&f.info, run.size)
	xf := run.xform
	tp :: proc(xf: nvg.Matrix, x, y: f32) -> [2]f32 {
		return {xf[0] * x + xf[2] * y + xf[4], xf[1] * x + xf[3] * y + xf[5]}
	}
	cur: [2]f32
	for v in o.verts {
		p := tp(xf, g.x + f32(v.x) * s, g.y - f32(v.y) * s)
		switch v.type {
		case u8(stbtt.vmove.vmove):
			if cur != {} do strings.write_string(b, "h\n")
			pdf_n(b, p.x); pdf_n(b, p.y); strings.write_string(b, "m\n")
		case u8(stbtt.vmove.vline):
			pdf_n(b, p.x); pdf_n(b, p.y); strings.write_string(b, "l\n")
		case u8(stbtt.vmove.vcurve):
			// a quadratic as the cubic it equals
			q := tp(xf, g.x + f32(v.cx) * s, g.y - f32(v.cy) * s)
			c1 := cur + (q - cur) * (2.0 / 3.0)
			c2 := p + (q - p) * (2.0 / 3.0)
			pdf_n(b, c1.x); pdf_n(b, c1.y); pdf_n(b, c2.x); pdf_n(b, c2.y); pdf_n(b, p.x); pdf_n(b, p.y)
			strings.write_string(b, "c\n")
		case u8(stbtt.vmove.vcubic):
			c1 := tp(xf, g.x + f32(v.cx) * s, g.y - f32(v.cy) * s)
			c2 := tp(xf, g.x + f32(v.cx1) * s, g.y - f32(v.cy1) * s)
			pdf_n(b, c1.x); pdf_n(b, c1.y); pdf_n(b, c2.x); pdf_n(b, c2.y); pdf_n(b, p.x); pdf_n(b, p.y)
			strings.write_string(b, "c\n")
		}
		cur = p
	}
	strings.write_string(b, "h f\n")
}
