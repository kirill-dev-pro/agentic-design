package engine

import nvg "../nanovg"

import "core:unicode/utf8"

// Where the rows of a text node sit on the page, as draw_text and draw_rich place them: the
// caret, the selection and the clicks of the text editor on the canvas.
Text_Row_Box :: struct {
	a, b:       int, // byte range of the content
	x, y, w, h: f32, // the row's ink box on the page (its line box vertically)
}

text_row_boxes :: proc(n: ^Node) -> []Text_Row_Box {
	out := make([dynamic]Text_Row_Box, context.temp_allocator)
	wrap := n.w if n.growth != .Auto else -1
	vg := renderer
	nvg.Save(vg)
	defer nvg.Restore(vg)
	nvg.ResetTransform(vg)
	align_x :: proc(n: ^Node, w: f32) -> f32 {
		#partial switch n.text_align {
		case .Center: return n.x + (n.w - w) / 2
		case .Right: return n.x + n.w - w
		}
		return n.x
	}
	if is_rich(n) {
		text_metrics(n, wrap)
		if l, ok := rich_cache[text_key(n, wrap)]; ok {
			y := n.y
			if n.growth == .Fixed_Width_Height && n.text_valign != .Start {
				free := n.h - l.size.y
				y += free / 2 if n.text_valign == .Center else free
			}
			for r in l.rows {
				append(&out, Text_Row_Box{r.a, r.b, align_x(n, r.w), y, r.w, r.h})
				y += r.h
			}
		}
	} else {
		lh := n.font_size * line_height_of(n)
		rows := text_lines(n, wrap)
		y := n.y
		if n.growth == .Fixed_Width_Height && n.text_valign != .Start {
			free := n.h - f32(len(rows)) * lh
			y += free / 2 if n.text_valign == .Center else free
		}
		for row in rows {
			a, b := clamp(row[0], 0, len(n.content)), clamp(row[1], 0, len(n.content))
			if b < a do b = a
			w := text_span_width(n, a, b)
			append(&out, Text_Row_Box{a, b, align_x(n, w), y, w, lh})
			y += lh
		}
	}
	if len(out) == 0 {
		lh := n.font_size * line_height_of(n)
		append(&out, Text_Row_Box{0, 0, align_x(n, 0), n.y, 0, lh})
	}
	return out[:]
}

// Width of content[a:b], inside one row, as drawn: where the caret after b is, from a.
text_span_width :: proc(n: ^Node, a, b: int) -> f32 {
	if b <= a do return 0
	vg := renderer
	nvg.Save(vg)
	defer nvg.Restore(vg)
	nvg.ResetTransform(vg)
	if is_rich(n) do return rich_width(vg, n, a, b)
	set_font(vg, n)
	return nvg.TextBounds(vg, 0, 0, n.content[a:b]) + n.letter_spacing
}

// The row a byte offset is drawn on (at a wrap, the row it starts).
text_row_of :: proc(rows: []Text_Row_Box, at: int) -> int {
	for i := len(rows) - 1; i >= 0; i -= 1 do if rows[i].a <= at do return i
	return 0
}

// The page position of the caret before byte `at`: x, the row's top and height.
text_caret_pos :: proc(n: ^Node, at: int) -> (x, y, h: f32) {
	rows := text_row_boxes(n)
	r := rows[text_row_of(rows, at)]
	return r.x + text_span_width(n, r.a, clamp(at, r.a, r.b)), r.y, r.h
}

// The caret offset nearest to a page point.
text_offset_at :: proc(n: ^Node, p: [2]f32) -> int {
	rows := text_row_boxes(n)
	i := len(rows) - 1
	for r, k in rows do if p.y < r.y + r.h {
		i = k
		break
	}
	return text_offset_in_row(n, rows[i], p.x)
}

text_offset_in_row :: proc(n: ^Node, r: Text_Row_Box, x: f32) -> int {
	best, best_d := r.a, abs(x - r.x)
	k := r.a
	for k < r.b {
		_, size := utf8.decode_rune_in_string(n.content[k:r.b])
		k += size
		if d := abs(x - (r.x + text_span_width(n, r.a, k))); d < best_d do best, best_d = k, d
	}
	return best
}
