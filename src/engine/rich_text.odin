package engine

import nvg "../nanovg"

import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:mem"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// Rich text (D39, D98): a text node's optional `spans`, runs whose texts join up to its
// `content`, each one overriding the node's text style for its part:
//
//   "content": "Read the docs now",
//   "spans": [{"text": "Read the "}, {"text": "docs", "fill": "#2563eb", "underline": true,
//             "href": "https://example.com/docs"}, {"text": " now", "fontWeight": "700"}]
//
// `content` stays the whole plain text, so pen.dev and older versions show the words in the
// node's own style. When the runs do not join up to the content (the content was changed
// somewhere that does not know about spans), the spans are ignored and lint says so.

Text_Span :: struct {
	a, b:        int, // byte range of the content
	family:      string, // "" = the node's
	weight:      int, // 0 = the node's
	italic:      i8, // -1 = the node's
	size:        f32, // 0 = the node's
	fill:        Color,
	has_fill:    bool,
	underline:   i8, // -1 = the node's
	strike:      i8,
	spacing:     f32,
	has_spacing: bool,
	href:        string,
}

SPAN_KEYS :: "text, fontFamily, fontWeight, fontStyle, fontSize, fill, underline, strikethrough, letterSpacing, href"

spans_free :: proc(n: ^Node) {
	for s in n.spans {
		delete(s.family)
		delete(s.href)
	}
	delete(n.spans)
	n.spans = nil
	n.spans_bad = false
}

// Reads `spans` once `content` is known (node_refresh).
parse_spans :: proc(doc: ^Document, n: ^Node, v: json.Value) {
	arr, is_arr := v.(json.Array)
	if !is_arr || len(arr) == 0 do return
	pos := 0
	for item in arr {
		o, is_obj := item.(json.Object)
		t := string(o["text"].(json.String) or_else "") if is_obj else ""
		if !is_obj || pos + len(t) > len(n.content) || n.content[pos:pos + len(t)] != t {
			spans_free(n)
			n.spans_bad = true
			return
		}
		if len(t) == 0 do continue
		s := Text_Span{a = pos, b = pos + len(t), italic = -1, underline = -1, strike = -1}
		for k, val in o {
			switch k {
			case "fontFamily": s.family = strings.clone(json_str(doc, val))
			case "fontWeight": s.weight = weight_number(doc, val)
			case "fontStyle": s.italic = 1 if strings.contains(strings.to_lower(json_str(doc, val), context.temp_allocator), "italic") else 0
			case "fontSize": if f, ok := num(doc, val); ok do s.size = max(f, 1)
			case "fill": s.fill, s.has_fill = color_of(doc, val)
			case "underline": if on, ok := json_bool(doc, val); ok do s.underline = 1 if on else 0
			case "strikethrough": if on, ok := json_bool(doc, val); ok do s.strike = 1 if on else 0
			case "letterSpacing": s.spacing, s.has_spacing = num(doc, val)
			case "href": s.href = strings.clone(json_str(doc, val))
			}
		}
		append(&n.spans, s)
		pos += len(t)
	}
	if pos != len(n.content) {
		spans_free(n)
		n.spans_bad = true
	}
}

// The node draws its runs: they still cover its content exactly.
is_rich :: proc(n: ^Node) -> bool {
	return len(n.spans) > 0 && n.spans[len(n.spans) - 1].b == len(n.content)
}

// `n` with the style of one span: a copy that shares n's memory, never freed or kept.
span_node :: proc(n: ^Node, s: Text_Span) -> Node {
	c := n^
	if s.family != "" do c.font_family = s.family
	if s.weight > 0 {
		c.weight = s.weight
		c.bold = s.weight >= 600
	}
	if s.italic >= 0 do c.italic = s.italic == 1
	if s.size > 0 do c.font_size = s.size
	if s.has_fill do c.fill, c.has_fill = s.fill, true
	if s.underline >= 0 do c.underline = s.underline == 1
	if s.strike >= 0 do c.strikethrough = s.strike == 1
	if s.has_spacing do c.letter_spacing = s.spacing
	return c
}

// The span holding byte `at` (the last one at the end of the content).
span_at :: proc(n: ^Node, at: int) -> int {
	for s, i in n.spans do if at < s.b do return i
	return len(n.spans) - 1
}

spans_hash :: proc(n: ^Node, key: u64) -> u64 {
	key := key
	for s in n.spans {
		nums := [6]f32{f32(s.a), f32(s.b), f32(s.weight), f32(s.italic), s.size, s.spacing if s.has_spacing else -1e9}
		key = hash.fnv64a(mem.slice_to_bytes(nums[:]), key)
		key = hash.fnv64a(transmute([]u8)s.family, key)
	}
	return key
}

// ---------------------------------------------------------------- layout

Rich_Row :: struct {
	a, b: int, // byte range, without the spaces a wrapped line ends with
	w, h: f32,
	asc:  f32, // the baseline below the row's top
}

Rich_Layout :: struct {
	size: [2]f32,
	rows: []Rich_Row,
}

rich_cache: map[u64]Rich_Layout

rich_cache_clear :: proc() {
	for _, l in rich_cache do delete(l.rows)
	clear(&rich_cache)
}

// Width of content[a:b] drawn span by span (letter spacing after every character, as CSS).
rich_width :: proc(vg: ^nvg.Context, n: ^Node, a, b: int) -> f32 {
	w: f32
	i := a
	for i < b {
		s := n.spans[span_at(n, i)]
		e := min(b, s.b)
		c := span_node(n, s)
		set_font(vg, &c)
		piece := n.content[i:e]
		w += nvg.TextBounds(vg, 0, 0, piece)
		if piece != "" do w += c.letter_spacing
		i = e
	}
	return w
}

@(private = "file")
rich_row :: proc(vg: ^nvg.Context, n: ^Node, rows: ^[dynamic]Rich_Row, a, b: int) {
	r := Rich_Row{a = a, b = b}
	r.w = rich_width(vg, n, a, b)
	top, bottom: f32 = 0, 0 // ascent and descent of the tallest fonts
	i := a
	for {
		si := span_at(n, i if i < len(n.content) else max(i - 1, 0))
		s := n.spans[si]
		c := span_node(n, s)
		set_font(vg, &c)
		asc, desc, _ := nvg.TextMetrics(vg)
		top, bottom = max(top, asc), min(bottom, desc)
		r.h = max(r.h, c.font_size * line_height_of(&c))
		i = s.b
		if i >= b do break
	}
	r.asc = (r.h - (top - bottom)) / 2 + top
	append(rows, r)
}

rich_measure :: proc(vg: ^nvg.Context, n: ^Node, wrap_w: f32, key: u64) -> (m: Text_Metrics) {
	rows := make([dynamic]Rich_Row)
	content := n.content
	wrap := n.growth != .Auto && wrap_w >= 0
	limit := max(wrap_w, 1)
	para := 0
	for {
		nl := strings.index_byte(content[para:], '\n')
		pend := len(content) if nl < 0 else para + nl
		if !wrap {
			rich_row(vg, n, &rows, para, pend)
		} else {
			line_a, words_end := para, para
			line_w: f32
			i := para
			for i < pend {
				we := i
				for we < pend && content[we] != ' ' && content[we] != '\t' do we += 1
				se := we
				for se < pend && (content[se] == ' ' || content[se] == '\t') do se += 1
				ww := rich_width(vg, n, i, we)
				if line_w + ww > limit && words_end > line_a {
					rich_row(vg, n, &rows, line_a, words_end)
					line_a, line_w = i, 0
				}
				if ww > limit {
					// one word wider than the box: break it between characters
					j := i
					for j < we {
						_, sz := utf8.decode_rune_in_string(content[j:we])
						cw := rich_width(vg, n, j, j + sz)
						if line_w + cw > limit && j > line_a {
							rich_row(vg, n, &rows, line_a, j)
							line_a, line_w = j, 0
						}
						line_w += cw
						j += sz
					}
					line_w += rich_width(vg, n, we, se)
				} else {
					line_w += ww + rich_width(vg, n, we, se)
				}
				if we > i do words_end = we
				i = se
			}
			rich_row(vg, n, &rows, line_a, words_end if words_end > line_a else pend)
		}
		if nl < 0 do break
		para = pend + 1
	}
	l := Rich_Layout{rows = rows[:]}
	out := make([][2]int, len(rows))
	for r, i in rows {
		l.size.x = max(l.size.x, r.w)
		l.size.y += r.h
		out[i] = {r.a, r.b}
	}
	if wrap do l.size.x = wrap_w
	l.size.x = max(l.size.x, 2)
	if old, had := rich_cache[key]; had do delete(old.rows)
	rich_cache[key] = l
	return {size = l.size, rows = out}
}

// ---------------------------------------------------------------- drawing

draw_rich :: proc(vg: ^nvg.Context, n: ^Node) {
	wrap := n.w if n.growth != .Auto else -1
	text_metrics(n, wrap)
	l, ok := rich_cache[text_key(n, wrap)]
	if !ok do return
	y := n.y
	if n.growth == .Fixed_Width_Height && n.text_valign != .Start {
		free := n.h - l.size.y
		y += free / 2 if n.text_valign == .Center else free
	}
	for row in l.rows {
		x := n.x
		#partial switch n.text_align {
		case .Center: x += (n.w - row.w) / 2
		case .Right: x += n.w - row.w
		}
		base := y + row.asc
		i := row.a
		for i < row.b {
			s := n.spans[span_at(n, i)]
			e := min(row.b, s.b)
			c := span_node(n, s)
			set_font(vg, &c)
			asc, _, _ := nvg.TextMetrics(vg)
			piece := n.content[i:e]
			w := nvg.TextBounds(vg, 0, 0, piece)
			if piece != "" do w += c.letter_spacing
			nvg.FillColor(vg, to_nvg(c.fill if c.has_fill else Color{0, 0, 0, 255}))
			text_run(vg, &c, x, base - asc, piece)
			if c.underline || c.strikethrough do rich_decoration(vg, &c, x, base, w)
			x += w
			i = e
		}
		y += row.h
	}
}

@(private = "file")
rich_decoration :: proc(vg: ^nvg.Context, c: ^Node, x, base, w: f32) {
	thick := max(c.font_size / 14, 0.5)
	if outline_sink != nil {
		rect :: proc(x, y, w, h: f32) {
			sink_cmd('M', x, y)
			sink_cmd('L', x + w, y)
			sink_cmd('L', x + w, y + h)
			sink_cmd('L', x, y + h)
		}
		if c.underline do rect(x, base + thick, w, thick)
		if c.strikethrough do rect(x, base - c.font_size * 0.3, w, thick)
		return
	}
	nvg.BeginPath(vg)
	if c.underline do nvg.Rect(vg, x, base + thick, w, thick)
	if c.strikethrough do nvg.Rect(vg, x, base - c.font_size * 0.3, w, thick)
	nvg.Fill(vg)
}

// ---------------------------------------------------------------- editing

// The runs of `spans_raw` (the file's JSON) after the content changed from `old` to `new`:
// the changed middle (after the common start, before the common end) goes into the run
// where the change starts, so typing keeps the style of the text before the caret.
// Returns "" when there were no runs to follow.
spans_follow :: proc(spans_raw, old, new: string, allocator := context.allocator) -> string {
	v, err := json.parse_string(spans_raw, .JSON5, false, context.temp_allocator)
	if err != nil do return ""
	arr, is_arr := v.(json.Array)
	if !is_arr || len(arr) == 0 do return ""
	p := 0
	for p < len(old) && p < len(new) && old[p] == new[p] do p += 1
	for p > 0 && p < len(old) && !utf8.rune_start(old[p]) do p -= 1
	s := 0
	for s < len(old) - p && s < len(new) - p && old[len(old) - 1 - s] == new[len(new) - 1 - s] do s += 1
	for s > 0 && !utf8.rune_start(old[len(old) - s]) do s -= 1
	del_end := len(old) - s
	inserted := new[p:len(new) - s]
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '[')
	pos := 0
	placed := false
	wrote := 0
	for item, idx in arr {
		o, is_obj := item.(json.Object)
		if !is_obj do return ""
		t := string(o["text"].(json.String) or_else "")
		a, e := pos, pos + len(t)
		pos = e
		tb := strings.builder_make(context.temp_allocator)
		if a < p do strings.write_string(&tb, old[a:min(e, p)])
		// the run the change starts in (or the run before it, for a change at a run's start)
		if !placed && ((a < p && p <= e) || (p == 0 && a == 0) || idx == len(arr) - 1) {
			strings.write_string(&tb, inserted)
			placed = true
		}
		if e > del_end do strings.write_string(&tb, old[max(a, del_end):e])
		text := strings.to_string(tb)
		if text == "" do continue
		if wrote > 0 do strings.write_byte(&b, ',')
		wrote += 1
		strings.write_string(&b, `{"text":`)
		json_write_string(&b, text)
		for k, val in o {
			if k == "text" do continue
			strings.write_byte(&b, ',')
			json_write_string(&b, k)
			strings.write_byte(&b, ':')
			write_json_value(&b, val)
		}
		strings.write_byte(&b, '}')
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

// The plain text a `spans` array joins up to.
spans_text :: proc(spans: json.Value, allocator := context.temp_allocator) -> (string, bool) {
	arr, is_arr := spans.(json.Array)
	if !is_arr do return "", false
	b := strings.builder_make(allocator)
	for item in arr {
		o, is_obj := item.(json.Object)
		if !is_obj do return "", false
		t, has := o["text"].(json.String)
		if !has do return "", false
		strings.write_string(&b, string(t))
	}
	return strings.to_string(b), true
}

// Sets a text node's content; its spans, when it has them, follow the change.
node_set_content :: proc(doc: ^Document, n: ^Node, text: string) {
	if len(n.spans) > 0 && text != n.content {
		if follow := spans_follow(prop_raw(n, "spans"), n.content, text, context.temp_allocator); follow != "" do node_set_raw(n, "spans", follow)
	}
	node_set_string(doc, n, "content", text)
}

// The content of a rich text node as HTML (or JSX): a <span> per styled run with its own
// style inline, an <a> for a run with href. Plain runs are bare text.
rich_html :: proc(n: ^Node, jsx: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	for s in n.spans {
		text := n.content[s.a:s.b]
		esc := jsx_escape(text) if jsx else html_escape(text)
		decls := make([dynamic][2]string, context.temp_allocator)
		if s.family != "" do append(&decls, [2]string{"font-family", fmt.tprintf("\"%s\", sans-serif", s.family)})
		if s.weight > 0 && s.weight != n.weight do append(&decls, [2]string{"font-weight", fmt.tprintf("%d", s.weight)})
		if s.italic >= 0 && (s.italic == 1) != n.italic do append(&decls, [2]string{"font-style", "italic" if s.italic == 1 else "normal"})
		if s.size > 0 && s.size != n.font_size do append(&decls, [2]string{"font-size", fmt.tprintf("%spx", num_text(s.size))})
		if s.has_fill do append(&decls, [2]string{"color", css_color(s.fill)})
		if s.has_spacing do append(&decls, [2]string{"letter-spacing", fmt.tprintf("%spx", num_text(s.spacing))})
		u := n.underline if s.underline < 0 else s.underline == 1
		k := n.strikethrough if s.strike < 0 else s.strike == 1
		if u != n.underline || k != n.strikethrough || s.href != "" {
			append(&decls, [2]string{"text-decoration", "underline line-through" if u && k else ("underline" if u else ("line-through" if k else "none"))})
		}
		tag := "a" if s.href != "" else "span"
		if len(decls) == 0 && s.href == "" {
			strings.write_string(&b, esc)
			continue
		}
		fmt.sbprintf(&b, "<%s", tag)
		if s.href != "" do fmt.sbprintf(&b, " href=\"%s\"", html_escape(s.href))
		if len(decls) > 0 {
			if jsx {
				strings.write_string(&b, " style={{ ")
				for d, i in decls {
					if i > 0 do strings.write_string(&b, ", ")
					fmt.sbprintf(&b, "%s: %s", jsx_style_key(d[0]), js_string(d[1]))
				}
				strings.write_string(&b, " }}")
			} else {
				strings.write_string(&b, " style=\"")
				for d, i in decls {
					if i > 0 do strings.write_string(&b, "; ")
					fmt.sbprintf(&b, "%s: %s", d[0], html_escape(d[1]))
				}
				strings.write_byte(&b, '"')
			}
		}
		fmt.sbprintf(&b, ">%s</%s>", esc, tag)
	}
	return strings.to_string(b)
}

// font-family → fontFamily
@(private = "file")
jsx_style_key :: proc(prop: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	up := false
	for r in prop {
		if r == '-' {
			up = true
			continue
		}
		strings.write_rune(&b, unicode.to_upper(r) if up else r)
		up = false
	}
	return strings.to_string(b)
}
