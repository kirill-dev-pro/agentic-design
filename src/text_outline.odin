package agentic_design

import "core:math"
import "fontstash"
import nvg "nanovg"
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
// at y (as nvg.Text with TOP alignment), in the current font settings of `n`.
draw_text_outlines :: proc(vg: ^nvg.Context, n: ^Node, x, y: f32, text: string) {
	fs := &app.vg.fs
	face := font_face(n.font_family, n.weight, n.italic, n.font_size)
	fi := fontstash.GetFontByName(fs, face)
	if fi < 0 do return
	font := &fs.fonts[fi]
	scale := stbtt.ScaleForMappingEmToPixels(&font.info, n.font_size)
	baseline := y + font.ascender * n.font_size
	spacing := n.letter_spacing + system_tracking(n)
	pen := x
	prev: i32 = -1
	nvg.BeginPath(vg)
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
	nvg.Fill(vg)
}

// One run of text at (x, y): bitmap glyphs normally, outlines when large on screen.
// `halign` places it as nvg.Text would.
text_run :: proc(vg: ^nvg.Context, n: ^Node, x, y: f32, text: string, halign: nvg.AlignHorizontal = .LEFT) {
	if !text_needs_outlines(vg, n.font_size) {
		nvg.Text(vg, x, y, text)
		return
	}
	left := x
	if halign != .LEFT {
		w := nvg.TextBounds(vg, 0, 0, text)
		left -= w / 2 if halign == .CENTER else w
	}
	draw_text_outlines(vg, n, left, y, text)
}
