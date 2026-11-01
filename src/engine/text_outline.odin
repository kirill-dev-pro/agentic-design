package engine

import "core:math"
import "core:strings"
import "core:fmt"
import "../fontstash"
import nvg "../nanovg"
import stbtt "vendor:stb/truetype"

// Large text drawn as glyph outlines. Glyphs come from a bitmap atlas and are rasterised at
// most MAX_GLYPH_PIXELS tall (nanovg.odin), so past that size on screen the bitmaps are
// stretched and blur. Above OUTLINE_PIXELS the glyphs' own curves are filled instead (as
// pen.dev draws text at any zoom). Positions follow fontstash: the same advances, GPOS
// kerning and letter spacing, so the switch does not move anything.

OUTLINE_PIXELS :: 200

Glyph_Outline :: struct {
	verts: []stbtt.vertex,
	signs: []bool, // per contour: winding of the solid parts (holes have the other)
}

outline_cache: map[u64]Glyph_Outline

// While set, text is not drawn: its glyph outlines (and underlines) are written as SVG path
// data, relative to (ox, oy), by the same code that draws them (text_to_geometry).
Outline_Sink :: struct {
	b:        ^strings.Builder,
	ox, oy:   f32,
	open:     bool, // a contour is open: close it before the next one
	embolden: bool, // a missing bold was drawn by thickening (a stroke of font size / 24)
}

outline_sink: ^Outline_Sink

sink_num :: proc(b: ^strings.Builder, v: f32) {
	s := fmt.tprintf("%.4f", v)
	s = strings.trim_right(s, "0")
	s = strings.trim_right(s, ".")
	if s == "-0" || s == "" do s = "0"
	strings.write_string(b, s)
}

sink_cmd :: proc(k: u8, pts: ..f32) {
	sk := outline_sink
	if k == 'M' && sk.open do strings.write_string(sk.b, "Z")
	strings.write_byte(sk.b, k)
	for v, i in pts {
		if i > 0 do strings.write_byte(sk.b, ' ')
		sink_num(sk.b, v - (sk.ox if i % 2 == 0 else sk.oy))
	}
	if k == 'M' do sk.open = true
}

// The rows of `n` as an SVG path in its own box (0, 0 at its top-left), drawn exactly as the
// canvas draws the text: glyph outlines with kerning, letter spacing and fallback fonts,
// the same line breaks, alignment and underlines. For "outline text": the path fills the
// same pixels as the text.
text_to_geometry :: proc(vg: ^nvg.Context, n: ^Node) -> (geometry: string, embolden: bool) {
	b := strings.builder_make(context.temp_allocator)
	sink := Outline_Sink{b = &b, ox = n.x, oy = n.y}
	nvg.Save(vg)
	nvg.ResetTransform(vg)
	outline_sink = &sink
	draw_text(vg, n)
	outline_sink = nil
	nvg.Restore(vg)
	if sink.open do strings.write_string(&b, "Z")
	return strings.to_string(b), sink.embolden
}

// True when the current transform makes a `size` font larger than the atlas draws sharply.
text_needs_outlines :: proc(vg: ^nvg.Context, size: f32) -> bool {
	m: nvg.Matrix
	nvg.CurrentTransform(vg, &m)
	s := math.sqrt(abs(m[0] * m[3] - m[1] * m[2]))
	return size * s * vg.devicePxRatio > OUTLINE_PIXELS // the frame's own pixel ratio: 1 offscreen
}

glyph_outline :: proc(font_index: int, font: ^fontstash.Font, glyph: i32) -> Glyph_Outline {
	key := u64(font_index) << 32 | u64(u32(glyph))
	if o, ok := outline_cache[key]; ok do return o
	o: Glyph_Outline
	raw: [^]stbtt.vertex
	n := stbtt.GetGlyphShape(&font.info, glyph, &raw)
	if n > 0 {
		o.verts = make([]stbtt.vertex, n)
		copy(o.verts, raw[:n])
		stbtt.FreeShape(&font.info, raw)
		// the contour with the largest area is solid; contours wound the other way are holes
		areas := make([dynamic]f32, context.temp_allocator)
		a: f32
		start: [2]f32
		prev: [2]f32
		for v, i in o.verts {
			p := [2]f32{f32(v.x), f32(v.y)}
			if v.type == u8(stbtt.vmove.vmove) {
				if i > 0 do append(&areas, a + (prev.x * start.y - start.x * prev.y))
				a, start = 0, p
			} else {
				a += prev.x * p.y - p.x * prev.y
			}
			prev = p
		}
		append(&areas, a + (prev.x * start.y - start.x * prev.y))
		biggest := 0
		for ar, i in areas do if abs(ar) > abs(areas[biggest]) do biggest = i
		o.signs = make([]bool, len(areas))
		for ar, i in areas do o.signs[i] = (ar > 0) == (areas[biggest] > 0)
	}
	outline_cache[key] = o
	return o
}

// Fills `text` with its glyph outlines, the first glyph's origin at x and the line's top
// at y (as nvg.Text with TOP alignment), in the current font settings of `n`. `embolden`
// thickens the glyphs as Skia (FreeType) does for a bold that the family lacks: the outline
// grows by font size / 24 in all, half on each side, and the advances stay the same.
draw_text_outlines :: proc(vg: ^nvg.Context, n: ^Node, x, y: f32, text: string, embolden := false) {
	fs := &renderer.fs
	face := font_face(n.font_family, n.weight, n.italic)
	fi := fontstash.GetFontByName(fs, face)
	if fi < 0 do return
	font := &fs.fonts[fi]
	scale := stbtt.ScaleForMappingEmToPixels(&font.info, n.font_size)
	baseline := y + font.ascender * n.font_size
	spacing := n.letter_spacing
	pen := x
	prev: i32 = -1
	sk := outline_sink
	if sk == nil do nvg.BeginPath(vg)
	for r in text {
		if r == '\n' do continue
		use, ufont := fi, font
		g := stbtt.FindGlyphIndex(&font.info, r)
		if g == 0 {
			// the font's fallbacks, as fontstash picks them
			for k in 0 ..< font.nfallbacks {
				fb := &fs.fonts[font.fallbacks[k]]
				if fg := stbtt.FindGlyphIndex(&fb.info, r); fg != 0 {
					g, use, ufont = fg, font.fallbacks[k], fb
					break
				}
			}
		}
		s := scale if use == fi else stbtt.ScaleForMappingEmToPixels(&ufont.info, n.font_size)
		if prev >= 0 && use == fi do pen += f32(fontstash.__getGlyphKernAdvance(font, prev, g)) * scale
		o := glyph_outline(use, ufont, g)
		contour := -1
		for v in o.verts {
			p := [2]f32{pen + f32(v.x) * s, baseline - f32(v.y) * s}
			if sk != nil {
				switch v.type {
				case u8(stbtt.vmove.vmove): sink_cmd('M', p.x, p.y)
				case u8(stbtt.vmove.vline): sink_cmd('L', p.x, p.y)
				case u8(stbtt.vmove.vcurve):
					// as nvg.QuadTo draws it: a cubic with control points 2/3 of the way
					q := [2]f32{pen + f32(v.cx) * s, baseline - f32(v.cy) * s}
					sink_cmd('Q', q.x, q.y, p.x, p.y)
				case u8(stbtt.vmove.vcubic):
					sink_cmd('C', pen + f32(v.cx) * s, baseline - f32(v.cy) * s, pen + f32(v.cx1) * s, baseline - f32(v.cy1) * s, p.x, p.y)
				}
				continue
			}
			switch v.type {
			case u8(stbtt.vmove.vmove):
				nvg.MoveTo(vg, p.x, p.y)
				contour += 1
				nvg.PathWinding(vg, .CCW if o.signs[contour] else .CW)
			case u8(stbtt.vmove.vline):
				nvg.LineTo(vg, p.x, p.y)
			case u8(stbtt.vmove.vcurve):
				nvg.QuadTo(vg, pen + f32(v.cx) * s, baseline - f32(v.cy) * s, p.x, p.y)
			case u8(stbtt.vmove.vcubic):
				nvg.BezierTo(vg, pen + f32(v.cx) * s, baseline - f32(v.cy) * s, pen + f32(v.cx1) * s, baseline - f32(v.cy1) * s, p.x, p.y)
			}
		}
		adv, lsb: i32
		stbtt.GetGlyphHMetrics(&ufont.info, g, &adv, &lsb)
		pen += f32(adv) * s + spacing
		prev = g if use == fi else -1
	}
	if sk != nil {
		if embolden do sk.embolden = true
		return
	}
	nvg.Fill(vg)
	if embolden {
		st := nvg.__getState(vg)
		saved := st^
		st.stroke = st.fill
		st.strokeWidth = n.font_size / 24
		st.lineJoin = .MITER
		st.miterLimit = 4
		nvg.Stroke(vg)
		st.stroke, st.strokeWidth, st.lineJoin, st.miterLimit = saved.stroke, saved.strokeWidth, saved.lineJoin, saved.miterLimit
	}
}

// One run of text at (x, y): bitmap glyphs normally, outlines when large on screen or when
// a missing bold is drawn by thickening a lighter face. `halign` places it as nvg.Text would.
text_run :: proc(vg: ^nvg.Context, n: ^Node, x, y: f32, text: string, halign: nvg.AlignHorizontal = .LEFT) {
	embolden := font_pick(n.font_family, n.weight, n.italic).embolden
	if outline_sink == nil && !embolden && !text_needs_outlines(vg, n.font_size) {
		nvg.Text(vg, x, y, text)
		return
	}
	left := x
	if halign != .LEFT {
		w := nvg.TextBounds(vg, 0, 0, text)
		left -= w / 2 if halign == .CENTER else w
	}
	draw_text_outlines(vg, n, left, y, text, embolden)
}
