#+build !js
package agentic_design

import "engine"

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"
import nvg "nanovg"

// The agent's answers as Markdown: headings, paragraphs, lists, quotes, code blocks, rules;
// **bold**, *italic*, `code` and [links](…). Links may point at the design:
//
//   [the sign-in button](node:aB3x9)     selects the layer and brings it into view
//   [here](canvas:120,340,400,300)       shows that area of the page (x, y[, w, h])
//   ![The new header](node:aB3x9)        alone on a line: a picture of the layer, live
//
// Each paragraph is a selectable block (agent_panel.odin's chat_block).

MD_SIZE :: f32(13.5)
MD_LINE :: f32(1.5)
MD_GAP :: f32(8)

@(private = "file")
Md_Run :: struct {
	a, b:  int, // in the paragraph's plain text
	style: Chat_Style,
	link:  string, // "" or the target
}

// Inline Markdown to plain text and styled runs.
@(private = "file")
md_inline :: proc(src: string) -> (plain: string, runs: []Md_Run) {
	b := strings.builder_make(context.temp_allocator)
	out := make([dynamic]Md_Run, context.temp_allocator)
	bold, italic := false, false
	style :: proc(bold, italic: bool) -> Chat_Style {
		switch {
		case bold && italic: return .Bold_Italic
		case bold: return .Bold
		case italic: return .Italic
		}
		return .Regular
	}
	start := 0
	cur := Chat_Style.Regular
	flush :: proc(out: ^[dynamic]Md_Run, b: ^strings.Builder, start: ^int, st: Chat_Style, link: string = "") {
		end := strings.builder_len(b^)
		if end > start^ do append(out, Md_Run{start^, end, st, link})
		start^ = end
	}
	i := 0
	for i < len(src) {
		c := src[i]
		switch {
		case c == '\\' && i + 1 < len(src) && strings.contains_rune("\\`*_[]()#>-!", rune(src[i + 1])):
			strings.write_byte(&b, src[i + 1])
			i += 2
		case c == '`':
			e := strings.index_byte(src[i + 1:], '`')
			if e < 0 {
				strings.write_byte(&b, c)
				i += 1
				continue
			}
			flush(&out, &b, &start, cur)
			strings.write_string(&b, src[i + 1:i + 1 + e])
			flush(&out, &b, &start, .Mono)
			i += e + 2
		case (c == '*' || c == '_') && i + 1 < len(src) && src[i + 1] == c:
			flush(&out, &b, &start, cur)
			bold = !bold
			cur = style(bold, italic)
			i += 2
		case (c == '*' || c == '_') && (italic || (i + 1 < len(src) && src[i + 1] != ' ')) && !(c == '_' && i > 0 && is_word_byte(src[i - 1]) && i + 1 < len(src) && is_word_byte(src[i + 1])):
			flush(&out, &b, &start, cur)
			italic = !italic
			cur = style(bold, italic)
			i += 1
		case c == '[' || (c == '!' && i + 1 < len(src) && src[i + 1] == '['):
			// [text](target)
			o := i + (2 if c == '!' else 1)
			close := strings.index_byte(src[o:], ']')
			if close < 0 || o + close + 1 >= len(src) || src[o + close + 1] != '(' {
				strings.write_byte(&b, c)
				i += 1
				continue
			}
			pe := strings.index_byte(src[o + close + 2:], ')')
			if pe < 0 {
				strings.write_byte(&b, c)
				i += 1
				continue
			}
			label := src[o:o + close]
			target := strings.trim_space(src[o + close + 2:o + close + 2 + pe])
			flush(&out, &b, &start, cur)
			strings.write_string(&b, label if label != "" else target)
			flush(&out, &b, &start, cur, target)
			i = o + close + 2 + pe + 1
		case:
			strings.write_byte(&b, c)
			i += 1
		}
	}
	flush(&out, &b, &start, cur)
	return strings.to_string(b), out[:]
}

@(private = "file")
is_word_byte :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c >= 0x80
}

// ---------------------------------------------------------------- blocks

@(private = "file")
Md_Kind :: enum {
	Para,
	Heading,
	Bullet,
	Number,
	Quote,
	Code,
	Rule,
	Picture,
}

@(private = "file")
Md_Block :: struct {
	kind:   Md_Kind,
	text:   string, // the source (inline Markdown), or the code
	level:  int, // heading level, list indent
	number: string, // "3." for numbered items
	target: string, // a picture's node
}

@(private = "file")
md_blocks :: proc(src: string) -> []Md_Block {
	out := make([dynamic]Md_Block, context.temp_allocator)
	lines := strings.split_lines(src, context.temp_allocator)
	para := strings.builder_make(context.temp_allocator)
	end_para :: proc(out: ^[dynamic]Md_Block, para: ^strings.Builder) {
		if strings.builder_len(para^) > 0 {
			append(out, Md_Block{kind = .Para, text = strings.clone(strings.to_string(para^), context.temp_allocator)})
			strings.builder_reset(para)
		}
	}
	i := 0
	for i < len(lines) {
		raw := lines[i]
		line := strings.trim_right_space(raw)
		t := strings.trim_left_space(line)
		indent := (len(line) - len(t)) / 2
		switch {
		case strings.has_prefix(t, "```"):
			end_para(&out, &para)
			code := strings.builder_make(context.temp_allocator)
			i += 1
			for i < len(lines) && !strings.has_prefix(strings.trim_space(lines[i]), "```") {
				if strings.builder_len(code) > 0 do strings.write_byte(&code, '\n')
				strings.write_string(&code, strings.trim_right_space(lines[i]))
				i += 1
			}
			append(&out, Md_Block{kind = .Code, text = strings.to_string(code)})
		case t == "":
			end_para(&out, &para)
		case strings.has_prefix(t, "#"):
			end_para(&out, &para)
			lvl := 0
			for lvl < len(t) && t[lvl] == '#' do lvl += 1
			append(&out, Md_Block{kind = .Heading, text = strings.trim_space(t[lvl:]), level = lvl})
		case t == "---" || t == "***" || t == "___":
			end_para(&out, &para)
			append(&out, Md_Block{kind = .Rule})
		case strings.has_prefix(t, "- ") || strings.has_prefix(t, "* ") || strings.has_prefix(t, "+ "):
			end_para(&out, &para)
			append(&out, Md_Block{kind = .Bullet, text = t[2:], level = indent})
		case strings.has_prefix(t, "> ") || t == ">":
			end_para(&out, &para)
			append(&out, Md_Block{kind = .Quote, text = strings.trim_prefix(strings.trim_prefix(t, ">"), " ")})
		case strings.has_prefix(t, "![") && strings.contains(t, "](node:") && strings.has_suffix(t, ")"):
			end_para(&out, &para)
			cap_end := strings.index(t, "](")
			append(&out, Md_Block{kind = .Picture, text = t[2:cap_end], target = t[cap_end + 2 + 5:len(t) - 1]})
		case:
			// "1. item"
			dot := strings.index_byte(t, '.')
			if dot > 0 && dot <= 3 && dot + 1 < len(t) && t[dot + 1] == ' ' {
				if _, ok := strconv.parse_int(t[:dot]); ok {
					end_para(&out, &para)
					append(&out, Md_Block{kind = .Number, text = t[dot + 2:], number = t[:dot + 1], level = indent})
					break
				}
			}
			// a line of a paragraph: line breaks are kept (agents write them on purpose)
			if strings.builder_len(para) > 0 do strings.write_byte(&para, '\n')
			strings.write_string(&para, t)
		}
		i += 1
	}
	end_para(&out, &para)
	return out[:]
}

// ---------------------------------------------------------------- flow

@(private = "file")
Md_Ctx :: struct {
	vg:      ^nvg.Context,
	draw:    bool,
	color:   nvg.Color,
	size:    f32,
	links:   [dynamic]Md_Link,
}

@(private = "file")
Md_Link :: struct {
	r:      Rect,
	target: string,
}

// One paragraph of inline Markdown wrapped at w; returns its height.
@(private = "file")
md_flow :: proc(m: ^Md_Ctx, x, y, w: f32, src: string, base := Chat_Style.Regular, size: f32 = MD_SIZE, color := nvg.Color{}) -> f32 {
	vg := m.vg
	plain, runs := md_inline(src)
	if base != .Regular {
		for &r in runs do if r.style == .Regular do r.style = base
		if len(runs) == 0 && plain != "" {
			one := make([]Md_Run, 1, context.temp_allocator)
			one[0] = {0, len(plain), base, ""}
			runs = one
		}
	}
	col := color if color.a > 0 else m.color
	lh := size * MD_LINE
	pieces := make([dynamic]Chat_Piece, context.temp_allocator)
	links := make([dynamic]string, context.temp_allocator) // per piece, "" for none
	run_at :: proc(runs: []Md_Run, at: int) -> int {
		for r, i in runs do if at >= r.a && at < r.b do return i
		return -1
	}
	width :: proc(vg: ^nvg.Context, text: string, st: Chat_Style, size: f32) -> f32 {
		nvg.FontFace(vg, chat_face(st))
		nvg.FontSize(vg, size if st != .Mono else size * 0.92)
		return nvg.TextBounds(vg, 0, 0, text)
	}
	cx, line := f32(0), 0
	i := 0
	for i < len(plain) {
		if plain[i] == '\n' {
			cx, line = 0, line + 1
			i += 1
			continue
		}
		// a word: up to the next space or line break, with the spaces after it
		we := i
		for we < len(plain) && plain[we] != ' ' && plain[we] != '\n' do we += 1
		se := we
		for se < len(plain) && plain[se] == ' ' do se += 1
		// its parts by style
		ww: f32
		k := i
		for k < we {
			ri := run_at(runs, k)
			e := we if ri < 0 else min(we, runs[ri].b)
			ww += width(vg, plain[k:e], .Regular if ri < 0 else runs[ri].style, size)
			k = e
		}
		if cx > 0 && cx + ww > w {
			cx, line = 0, line + 1
		}
		k = i
		for k < se {
			ri := run_at(runs, k)
			e := se if ri < 0 else min(se, runs[ri].b)
			st := Chat_Style.Regular if ri < 0 else runs[ri].style
			target := "" if ri < 0 else runs[ri].link
			pw := width(vg, plain[k:e], st, size)
			py := y + f32(line) * lh
			n := len(pieces)
			if n > 0 && pieces[n - 1].y == py && pieces[n - 1].style == st && pieces[n - 1].b == k && links[n - 1] == target {
				pieces[n - 1].b = e
				pieces[n - 1].w += pw
			} else {
				append(&pieces, Chat_Piece{k, e, x + cx, py, pw, st, size})
				append(&links, target)
			}
			cx += pw
			k = e
		}
		i = se
	}
	h := f32(line + 1) * lh
	if !m.draw do return h
	chat_block(vg, plain, pieces[:], lh)
	for p, i in pieces {
		text := strings.trim_right(plain[p.a:p.b], " ")
		if text == "" do continue
		link := links[i]
		c := col
		if p.style == .Mono {
			tw := width(vg, text, .Mono, size)
			fill_rect(vg, {p.x - 2, p.y + lh * 0.12, tw + 4, lh * 0.76}, {1, 1, 1, 0.08}, 4)
		}
		if link != "" {
			c = ACCENT
			tw := width(vg, text, p.style, size)
			r := Rect{p.x, p.y, tw, lh}
			append(&m.links, Md_Link{r, link})
			if hovered(r) {
				fill_rect(vg, {p.x, p.y + lh * 0.82, tw, 1}, ACCENT)
				ui.cursor_hint = .Hand
				tooltip_request(md_link_hint(link), r)
			}
		}
		chat_styled_text(vg, p.x, p.y + lh / 2, text, p.style, size if p.style != .Mono else size * 0.92, c)
	}
	return h
}

// Text in a style. Without Inter the interface font has one weight and no italic: bold is
// drawn twice half a pixel apart, italic slanted.
chat_styled_text :: proc(vg: ^nvg.Context, x, y: f32, text: string, st: Chat_Style, size: f32, color: nvg.Color) {
	face := chat_face(st)
	nvg.FontFace(vg, face)
	nvg.FontSize(vg, size)
	nvg.TextAlign(vg, .LEFT, .MIDDLE)
	nvg.FillColor(vg, color)
	real := chat_has_inter()
	bold := (st == .Bold || st == .Bold_Italic) && !real && face == "ui"
	italic := (st == .Italic || st == .Bold_Italic) && !real
	if italic {
		nvg.Save(vg)
		nvg.Translate(vg, x, y)
		nvg.SkewX(vg, -0.2)
		nvg.Text(vg, 0, 0, text)
		if bold do nvg.Text(vg, 0.45, 0, text)
		nvg.Restore(vg)
		return
	}
	nvg.Text(vg, x, y, text)
	if bold do nvg.Text(vg, x + 0.45, y, text)
}

@(private = "file")
md_link_hint :: proc(target: string) -> string {
	switch {
	case strings.has_prefix(target, "node:"):
		if n, _ := engine.doc_find(&app.doc, target[5:]); n != nil do return fmt.tprintf("Show “%s” on the canvas", engine.node_label(n))
		return "That layer is not in this file"
	case strings.has_prefix(target, "canvas:"): return "Show this place on the canvas"
	}
	return target
}

// Follows a link: a layer or a place on the canvas, or a web page.
md_open :: proc(target: string) {
	switch {
	case strings.has_prefix(target, "node:"):
		n, _ := engine.doc_find(&app.doc, strings.trim_space(target[5:]))
		if n == nil {
			set_status("That layer is not in this file any more")
			return
		}
		uid := n.uid
		show_page_of({uid})
		clear(&app.sel)
		append(&app.sel, uid)
		if r, ok := bounds_of({uid}); ok {
			pad := max(r[2], r[3]) * 0.15 + 40
			zoom_to_rect({r[0] - pad, r[1] - pad, r[2] + 2 * pad, r[3] + 2 * pad})
		}
	case strings.has_prefix(target, "canvas:"):
		parts := strings.split(target[7:], ",", context.temp_allocator)
		v: [4]f32
		for p, i in parts do if i < 4 do v[i], _ = strconv.parse_f32(strings.trim_space(p))
		if len(parts) < 4 do v[2], v[3] = 400, 300
		if len(parts) < 4 do v[0], v[1] = v[0] - 200, v[1] - 150
		zoom_to_rect(v)
	case strings.has_prefix(target, "http://"), strings.has_prefix(target, "https://"), strings.has_prefix(target, "mailto:"):
		open_url(target)
	}
}

// The agent's answer drawn at (x, y) in width w; with draw false, only measured. Returns
// its height.
md_draw :: proc(vg: ^nvg.Context, x, y, w: f32, src: string, color: nvg.Color, draw: bool) -> f32 {
	m := Md_Ctx{vg = vg, draw = draw, color = color, size = MD_SIZE, links = make([dynamic]Md_Link, context.temp_allocator)}
	cy := y
	blocks := md_blocks(src)
	for b, bi in blocks {
		if bi > 0 do cy += MD_GAP
		switch b.kind {
		case .Para:
			cy += md_flow(&m, x, cy, w, b.text)
		case .Heading:
			size := f32(16) if b.level <= 1 else (15 if b.level == 2 else 14)
			if bi > 0 do cy += 4
			cy += md_flow(&m, x, cy, w, b.text, .Bold, size)
		case .Bullet, .Number:
			ind := f32(b.level) * 16
			lh := MD_SIZE * MD_LINE
			if draw {
				if b.kind == .Bullet {
					nvg.BeginPath(vg)
					nvg.Circle(vg, x + ind + 5, cy + lh / 2, 2.2)
					nvg.FillColor(vg, C_DIM)
					nvg.Fill(vg)
				} else do label(vg, x + ind, cy + lh / 2, b.number, C_DIM, MD_SIZE)
			}
			cy += md_flow(&m, x + ind + 18, cy, w - ind - 18, b.text)
			// list items sit close together
			if bi + 1 < len(blocks) && (blocks[bi + 1].kind == .Bullet || blocks[bi + 1].kind == .Number) do cy -= MD_GAP - 3
		case .Quote:
			h := md_flow(&m, x + 12, cy, w - 12, b.text, .Italic, MD_SIZE, C_DIM)
			if draw do fill_rect(vg, {x, cy + 2, 2, h - 4}, {1, 1, 1, 0.18}, 1)
			cy += h
			if bi + 1 < len(blocks) && blocks[bi + 1].kind == .Quote do cy -= MD_GAP
		case .Code:
			size := f32(12.5)
			lh := size * 1.45
			nvg.FontFace(vg, chat_face(.Mono))
			nvg.FontSize(vg, size)
			rows := text_rows(vg, b.text, w - 20)
			h := f32(len(rows)) * lh + 16
			if draw {
				fill_rect(vg, {x, cy, w, h}, {0x14 / 255.0, 0x14 / 255.0, 0x14 / 255.0, 1}, 8)
				stroke_rect(vg, {x, cy, w, h}, C_LINE, 8)
				pieces := make([]Chat_Piece, len(rows), context.temp_allocator)
				for row, i in rows {
					nvg.FontFace(vg, chat_face(.Mono))
					nvg.FontSize(vg, size)
					pieces[i] = {row[0], row[1], x + 10, cy + 8 + f32(i) * lh, nvg.TextBounds(vg, 0, 0, b.text[row[0]:row[1]]), .Mono, size}
				}
				chat_block(vg, b.text, pieces, lh)
				nvg.FontFace(vg, chat_face(.Mono))
				nvg.FontSize(vg, size)
				nvg.TextAlign(vg, .LEFT, .MIDDLE)
				nvg.FillColor(vg, C_TEXT)
				for row, i in rows do nvg.Text(vg, x + 10, cy + 8 + f32(i) * lh + lh / 2, b.text[row[0]:row[1]])
			}
			cy += h
		case .Rule:
			if draw do fill_rect(vg, {x, cy + 6, w, 1}, C_LINE)
			cy += 12
		case .Picture:
			pw := min(w, 340)
			r := Rect{x, cy, pw, 150 + (24 if b.text != "" else 0)}
			if draw {
				fill_rect(vg, r, {0x28 / 255.0, 0x28 / 255.0, 0x28 / 255.0, 1}, 10)
				box := Rect{r.x + 8, r.y + 8, r.w - 16, 134}
				if img, iw, ih, ok := chat_preview(b.target); ok && img > 0 {
					sc := min(box.w / f32(iw), box.h / f32(ih))
					dw, dh := f32(iw) * sc, f32(ih) * sc
					nvg.BeginPath(vg)
					nvg.RoundedRect(vg, box.x + (box.w - dw) / 2, box.y + (box.h - dh) / 2, dw, dh, 4)
					nvg.FillPaint(vg, nvg.ImagePattern(box.x + (box.w - dw) / 2, box.y + (box.h - dh) / 2, dw, dh, 0, img, 1))
					nvg.Fill(vg)
				} else if !ok {
					label(vg, box.x + box.w / 2, box.y + box.h / 2, "That layer is not in this file", C_DIM, 12, false, .CENTER)
				}
				if b.text != "" do label(vg, r.x + 10, r.y + r.h - 14, b.text, C_DIM, 12)
				stroke_rect(vg, r, {1, 1, 1, 0.08} if !hovered(r) else {ACCENT.r, ACCENT.g, ACCENT.b, 0.6}, 10)
				append(&m.links, Md_Link{r, fmt.tprintf("node:%s", b.target)})
				if hovered(r) {
					ui.cursor_hint = .Hand
					tooltip_request(md_link_hint(fmt.tprintf("node:%s", b.target)), r)
				}
			}
			cy += r.h
		}
	}
	if draw {
		// a click (not a drag: selecting text starts there too) follows the link
		for l in m.links do if clicked(l.r) do md_open(l.target)
	}
	return cy - y
}

// ---------------------------------------------------------------- layer pictures

@(private = "file")
Chat_Preview :: struct {
	img:     int,
	w, h:    int,
	version: int,
	at:      time.Time,
}

@(private = "file")
previews: map[string]Chat_Preview

@(private = "file")
preview_wanted: [dynamic]string

// The picture of a layer for the thread: made before the next frame (chat_previews_render),
// again after the document changes (at most every 2 s). ok is false when the layer is not
// in the file.
chat_preview :: proc(id: string) -> (img, w, h: int, ok: bool) {
	n, _ := engine.doc_find(&app.doc, id)
	if n == nil do return 0, 0, 0, false
	p, has := previews[id]
	stale := !has || (p.version != app.doc.version && time.since(p.at) > 2 * time.Second)
	if stale {
		known := false
		for q in preview_wanted do if q == id do known = true
		if !known do append(&preview_wanted, strings.clone(id))
	}
	return p.img, p.w, p.h, true
}

// Before the frame: one wanted picture (render_region draws outside the window's frame).
chat_previews_render :: proc() {
	if len(preview_wanted) == 0 do return
	id := pop(&preview_wanted)
	defer delete(id)
	n, _ := engine.doc_find(&app.doc, id)
	if n == nil do return
	box := engine.node_page_box(n)
	if box[2] <= 0 || box[3] <= 0 do return
	scale := min(648 / box[2], 268 / box[3], 2)
	bg := app.canvas_bg
	pixels, w, h, ok := render_region(box, scale, n, {bg.r, bg.g, bg.b, 1})
	if !ok do return
	old, had := previews[id]
	img := nvg.CreateImageRGBA(app.vg, int(w), int(h), {}, pixels)
	if had && old.img > 0 do nvg.DeleteImage(app.vg, old.img)
	key := id if had else strings.clone(id)
	previews[key] = {img, int(w), int(h), app.doc.version, time.now()}
	platform_wake()
}
