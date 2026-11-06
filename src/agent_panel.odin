#+build !js
package agentic_design

import "engine"

import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"
import "core:unicode"
import "core:unicode/utf8"
import nvg "nanovg"

// Agent mode (app-ui.pen "1 · Context popover" … "7 · Thread after sending with the marks"):
// a panel 400 wide at the left under the tab bar. From the top: the session (its title or
// "New session", a list of the file's sessions) and "+"; the thread, whose text can be
// selected and copied; the input, in two rows (the field; context, the agent with its model
// and effort, Send/Stop). The canvas keeps the rest, with the marks bar at its bottom: in
// this mode the pointer draws marks for the agent.

C_PANEL :: nvg.Color{0x1E / 255.0, 0x1E / 255.0, 0x1E / 255.0, 1}
C_LINE :: nvg.Color{0x2E / 255.0, 0x2E / 255.0, 0x2E / 255.0, 1}
C_FIELD :: nvg.Color{0x2A / 255.0, 0x2A / 255.0, 0x2A / 255.0, 1}
C_INPUT :: nvg.Color{0x1A / 255.0, 0x1A / 255.0, 0x1A / 255.0, 1}
C_MENU :: nvg.Color{0x30 / 255.0, 0x30 / 255.0, 0x30 / 255.0, 1}
C_GHOST :: nvg.Color{1, 1, 1, 0.06}
C_TEXT :: nvg.Color{0xE8 / 255.0, 0xE8 / 255.0, 0xE8 / 255.0, 1}
C_DIM :: nvg.Color{0x8F / 255.0, 0x8F / 255.0, 0x8F / 255.0, 1}
C_OK :: nvg.Color{0.24, 0.84, 0.55, 1}
C_GUIDE :: nvg.Color{1, 0.3, 0.45, 1}
C_ERR :: nvg.Color{1, 0.5, 0.45, 1}

AGENT_DOTS := [Agent_Kind]nvg.Color{.Claude = {0.85, 0.47, 0.34, 1}, .Codex = {0.24, 0.84, 0.55, 1}, .Gemini = {0.27, 0.55, 1, 1}}

panel_ui: struct {
	composer:  Rect,
	popover:   Rect,
	marks_bar: Rect,
	pick_open: bool, // the agent picker
	ses_open:  bool, // the sessions list
	ses_query: string,
	resizing:  bool, // the right edge is being dragged
}

// ---------------------------------------------------------------- the mode switch

// Design | Agent, first in the tab bar while a file is shown; returns where the next item goes.
draw_mode_switch :: proc(vg: ^nvg.Context, x: f32) -> f32 {
	if app.tab < 0 do return x
	names := [Editor_Mode]string{.Design = "Design", .Agent = "Agent"}
	icons := [Editor_Mode]string{.Design = "pen-tool", .Agent = "sparkles"}
	widths: [Editor_Mode]f32
	total: f32 = 4
	for m in Editor_Mode {
		widths[m] = text_width(vg, names[m], 12.5) + 43
		total += widths[m] + 2
	}
	r := Rect{x, 7, total - 2, TAB_H - 14}
	fill_rect(vg, r, C_FIELD, 8)
	bx := r.x + 2
	for m in Editor_Mode {
		b := Rect{bx, r.y + 2, widths[m], r.h - 4}
		on := editor_mode == m
		if on do fill_rect(vg, b, {1, 1, 1, 0.12}, 6)
		else if hovered(b) do fill_rect(vg, b, C_GHOST, 6)
		draw_lucide(vg, icons[m], b.x + 18, b.y + b.h / 2, 13, C_TEXT if on else C_DIM, 1.6)
		label(vg, b.x + 31, b.y + b.h / 2, names[m], C_TEXT if on else C_DIM, 12.5)
		if clicked(b) do set_editor_mode(m)
		bx += widths[m] + 2
	}
	return r.x + r.w + 10
}

// ---------------------------------------------------------------- selectable text

// Text in the thread can be selected with the pointer (drag, double click for a word) and
// copied with ⌘C. Each block of text drawn this frame is listed as pieces (a run of one style
// on one line) of its plain text; the selection runs from one block's offset to another's,
// in drawing order.
Chat_Style :: enum u8 {
	Regular,
	Bold,
	Italic,
	Bold_Italic,
	Mono,
}

// The face of a style: Inter's weights and italics when the app has them.
chat_face :: proc(st: Chat_Style) -> string {
	if st == .Mono do return "ui-mono" if ui_mono_loaded else "ui"
	bold := st == .Bold || st == .Bold_Italic
	italic := st == .Italic || st == .Bold_Italic
	if engine.family_find("Inter") != nil do return engine.font_face("Inter", 650 if bold else 400, italic)
	return "ui-bold" if bold && ui_bold_loaded else "ui"
}

Chat_Piece :: struct {
	a, b:  int, // byte range of the block's text
	x, y:  f32, // left and the line's top
	w:     f32,
	style: Chat_Style,
	size:  f32,
}

Chat_Block :: struct {
	text:   string,
	pieces: []Chat_Piece,
	lh:     f32,
}

Chat_Pos :: struct {
	block, at: int,
}

chat: struct {
	blocks:     [dynamic]Chat_Block, // this frame's (temp)
	prev:       [dynamic]Chat_Block, // last frame's, for the pointer
	a, b:       Chat_Pos,
	has:        bool,
	dragging:   bool,
	area:       Rect, // where selecting starts
	last_click: time.Time,
}

@(private = "file")
pos_less :: proc(p, q: Chat_Pos) -> bool {
	return p.block < q.block || (p.block == q.block && p.at < q.at)
}

@(private = "file")
piece_x :: proc(vg: ^nvg.Context, text: string, p: Chat_Piece, at: int) -> f32 {
	nvg.FontFace(vg, chat_face(p.style))
	nvg.FontSize(vg, p.size)
	return p.x + nvg.TextBounds(vg, 0, 0, text[p.a:clamp(at, p.a, p.b)])
}

// Lists a block drawn by the caller (pieces in temp memory) and draws the selection over it.
// Call before drawing its glyphs.
chat_block :: proc(vg: ^nvg.Context, text: string, pieces: []Chat_Piece, lh: f32) {
	index := len(chat.blocks)
	append(&chat.blocks, Chat_Block{text = text, pieces = pieces, lh = lh})
	if !chat.has do return
	lo, hi := chat.a, chat.b
	if pos_less(hi, lo) do lo, hi = hi, lo
	if index < lo.block || index > hi.block do return
	a := lo.at if index == lo.block else 0
	b := hi.at if index == hi.block else len(text)
	nvg.BeginPath(vg)
	for p, i in pieces {
		s, e := max(a, p.a), min(b, p.b)
		last_on_line := i + 1 >= len(pieces) || pieces[i + 1].y != p.y
		past := b > p.b && last_on_line
		if s > e || (s == e && !past) do continue
		x0 := piece_x(vg, text, p, s)
		x1 := piece_x(vg, text, p, e) + (p.size * 0.3 if past else 0)
		nvg.Rect(vg, x0, p.y, x1 - x0, lh)
	}
	nvg.FillColor(vg, {ACCENT.r, ACCENT.g, ACCENT.b, 0.35})
	nvg.Fill(vg)
}

// Draws `text` wrapped at w (font "ui"), with the selection over it; returns its height.
chat_text :: proc(vg: ^nvg.Context, x, y, w: f32, text: string, size: f32, color: nvg.Color, line := f32(1.45)) -> f32 {
	nvg.FontFace(vg, "ui")
	nvg.FontSize(vg, size)
	rows := text_rows(vg, text, w)
	lh := size * line
	pieces := make([]Chat_Piece, len(rows), context.temp_allocator)
	for row, i in rows {
		nvg.FontFace(vg, "ui")
		nvg.FontSize(vg, size)
		pieces[i] = {row[0], row[1], x, y + f32(i) * lh, nvg.TextBounds(vg, 0, 0, text[row[0]:row[1]]), .Regular, size}
	}
	chat_block(vg, text, pieces, lh)
	nvg.FontFace(vg, "ui")
	nvg.FontSize(vg, size)
	nvg.TextAlign(vg, .LEFT, .MIDDLE)
	nvg.FillColor(vg, color)
	for row, i in rows do nvg.Text(vg, x, y + f32(i) * lh + lh / 2, text[row[0]:row[1]])
	return f32(len(rows)) * lh
}

chat_text_height :: proc(vg: ^nvg.Context, w: f32, text: string, size: f32, line := f32(1.45)) -> f32 {
	nvg.FontFace(vg, "ui")
	nvg.FontSize(vg, size)
	return f32(len(text_rows(vg, text, w))) * size * line
}

// The block and offset under p (the nearest block above or below when between them).
@(private = "file")
chat_hit :: proc(vg: ^nvg.Context, p: [2]f32) -> (Chat_Pos, bool) {
	if len(chat.prev) == 0 do return {}, false
	best := -1
	for b, i in chat.prev {
		if len(b.pieces) == 0 do continue
		top, bottom := b.pieces[0].y, b.pieces[len(b.pieces) - 1].y + b.lh
		if p.y >= top && p.y < bottom {
			best = i
			break
		}
		if p.y >= bottom do best = i // the last block above
	}
	if best < 0 do return {0, 0}, true
	b := chat.prev[best]
	if len(b.pieces) == 0 do return {best, 0}, true
	if p.y >= b.pieces[len(b.pieces) - 1].y + b.lh do return {best, len(b.text)}, true
	// the line, then the piece on it, then the glyph boundary
	line_y := b.pieces[0].y
	for pc in b.pieces do if pc.y <= p.y do line_y = pc.y
	first, last := -1, -1
	for pc, i in b.pieces do if pc.y == line_y {
		if first < 0 do first = i
		last = i
	}
	if first < 0 do return {best, 0}, true
	pc := b.pieces[last]
	for i in first ..= last do if p.x < b.pieces[i].x + b.pieces[i].w {
		pc = b.pieces[i]
		break
	}
	if p.x <= pc.x do return {best, pc.a}, true
	nvg.FontFace(vg, chat_face(pc.style))
	nvg.FontSize(vg, pc.size)
	at, best_d := pc.a, abs(p.x - pc.x)
	k := pc.a
	for k < pc.b {
		_, size := utf8.decode_rune_in_string(b.text[k:pc.b])
		k += size
		if d := abs(p.x - (pc.x + nvg.TextBounds(vg, 0, 0, b.text[pc.a:k]))); d < best_d do at, best_d = k, d
	}
	return {best, at}, true
}

// The pointer and ⌘C over the thread (after its blocks are drawn).
@(private = "file")
chat_input :: proc(vg: ^nvg.Context, area: Rect) {
	if hovered(area) && len(chat.prev) > 0 do ui.cursor_hint = .IBeam
	// (a click a row, a link or a button took is theirs: no selection starts there)
	if mouse_pressed(MOUSE_BUTTON_LEFT) && !ui.click_taken {
		if hovered(area) {
			if pos, ok := chat_hit(vg, app.mouse); ok {
				now := time.now()
				double := time.duration_seconds(time.diff(chat.last_click, now)) < 0.35
				chat.last_click = now
				if double && pos.block < len(chat.prev) {
					text := chat.prev[pos.block].text
					a, b := pos.at, pos.at
					for a > 0 {
						r, s := utf8.decode_last_rune_in_string(text[:a])
						if !(unicode.is_letter(r) || unicode.is_digit(r)) do break
						a -= s
					}
					for b < len(text) {
						r, s := utf8.decode_rune_in_string(text[b:])
						if !(unicode.is_letter(r) || unicode.is_digit(r)) do break
						b += s
					}
					chat.a, chat.b, chat.has, chat.dragging = {pos.block, a}, {pos.block, b}, a != b, false
				} else {
					chat.a, chat.b, chat.has, chat.dragging = pos, pos, false, true
				}
				if ui.focus != "" do field_commit()
			}
		} else if !in_rect(panel_ui.popover, app.mouse) {
			chat.has = false
		}
	}
	if chat.dragging {
		if mouse_down(MOUSE_BUTTON_LEFT) {
			if pos, ok := chat_hit(vg, app.mouse); ok {
				chat.b = pos
				chat.has = chat.a != chat.b
			}
		} else do chat.dragging = false
	}
	if hovered(area) && mouse_pressed(MOUSE_BUTTON_RIGHT) && len(chat.prev) > 0 {
		// without a selection: the message under the pointer
		if !chat.has {
			if pos, ok := chat_hit(vg, app.mouse); ok && pos.block < len(chat.prev) {
				chat.a, chat.b, chat.has = {pos.block, 0}, {pos.block, len(chat.prev[pos.block].text)}, true
			}
		}
		if chat.has do menu_open("chat.menu", {app.mouse.x, app.mouse.y, 0, 0}, {"Copy\t⌘C", "Quote in reply", "-", "Select All"})
	}
	if chat.has && ui.focus == "" && mod_cmd() && key_pressed(KEY_C) {
		platform_clipboard_set(chat_selected_text())
		set_status("Copied")
	}
	if chat.has && ui.focus == "" && key_pressed(KEY_ESCAPE) do chat.has = false
}

chat_selected_text :: proc() -> string {
	lo, hi := chat.a, chat.b
	if pos_less(hi, lo) do lo, hi = hi, lo
	b := strings.builder_make(context.temp_allocator)
	for i in lo.block ..= hi.block {
		if i < 0 || i >= len(chat.prev) do continue
		t := chat.prev[i].text
		s := clamp(lo.at if i == lo.block else 0, 0, len(t))
		e := clamp(hi.at if i == hi.block else len(t), s, len(t))
		if i > lo.block do strings.write_string(&b, "\n\n")
		strings.write_string(&b, t[s:e])
	}
	return strings.to_string(b)
}

// Called once a frame after the thread is drawn (here and on the Dashboard's panel).
chat_frame_end :: proc() {
	for b in chat.prev {
		delete(b.text)
		delete(b.pieces)
	}
	clear(&chat.prev)
	for b in chat.blocks {
		pieces := make([]Chat_Piece, len(b.pieces))
		copy(pieces, b.pieces)
		append(&chat.prev, Chat_Block{strings.clone(b.text), pieces, b.lh})
	}
	clear(&chat.blocks)
}

// ---------------------------------------------------------------- the panel

agent_panel_rect :: proc() -> Rect {
	return {0, TAB_H, agent_side_w(), app.screen.y - TAB_H}
}

// The panel's right edge drags its width; the canvas keeps what it shows where it was.
@(private = "file")
panel_resize :: proc(r: Rect) {
	grip := Rect{r.x + r.w - 4, r.y, 8, r.h}
	if hovered(grip) || panel_ui.resizing do ui.cursor_hint = .Resize_H
	if !panel_ui.resizing && hovered(grip) && mouse_pressed(MOUSE_BUTTON_LEFT) {
		panel_ui.resizing = true
		ui.click_taken = true
	}
	if !panel_ui.resizing do return
	if !mouse_down(MOUSE_BUTTON_LEFT) {
		panel_ui.resizing = false
		settings_save()
		return
	}
	old := agent_side_w()
	settings.agent_panel_w = app.mouse.x
	if d := agent_side_w() - old; d != 0 {
		app.cam.x += d / app.zoom // the design stays where it is on screen
		app.canvas = canvas_rect()
	}
}

HEAD_H :: f32(48)

draw_agent_panel :: proc(vg: ^nvg.Context) {
	if !agent_mode() do return
	if chat.blocks == nil do chat.blocks = make([dynamic]Chat_Block)
	r := agent_panel_rect()
	t := agent_current()
	panel_ui.popover = {}
	fill_rect(vg, r, C_PANEL)
	fill_rect(vg, {r.x + r.w - 1, r.y, 1, r.h}, ACCENT if panel_ui.resizing else C_LINE)
	panel_resize(r)

	// the input first: its height sets where the thread ends
	ch := composer_height(vg, t)
	comp := Rect{r.x + 12, r.y + r.h - 12 - ch, r.w - 24, ch}
	panel_ui.composer = comp
	body := Rect{r.x, r.y + HEAD_H, r.w - 1, comp.y - 8 - (r.y + HEAD_H)}
	draw_thread_body(vg, t, body)
	draw_composer(vg, t, comp)
	draw_panel_head(vg, t, {r.x, r.y, r.w - 1, HEAD_H})
	if panel_ui.pick_open do draw_agent_picker(vg, comp)
	if agent_ui.ctx_open do draw_context_popover(vg, t, ctx_button_rect(comp), r.x + 12, r.w - 24)
	if panel_ui.ses_open do draw_sessions_list(vg, t, {r.x + 12, r.y + HEAD_H - 4, r.w - 24, 0})
	chat_input(vg, body)
	chat_frame_end()
	text_menus()

	// ⌘L: the field; ⌘.: stop
	if !ui_modal() && mod_cmd() {
		if key_pressed(KEY_PERIOD) && t.running do agent_stop(t)
	}
}

// The pointer is on the agent's panel or the marks bar (not the canvas).
agent_panel_hit :: proc(p: [2]f32) -> bool {
	if !agent_mode() do return false
	return in_rect(agent_panel_rect(), p) || in_rect({agent_side_w() - 4, TAB_H, 8, app.screen.y}, p) || in_rect(panel_ui.marks_bar, p) || (panel_ui.popover.w > 0 && in_rect(panel_ui.popover, p))
}

@(private = "file")
tokens_text :: proc(n: int) -> string {
	if n >= 1_000_000 do return fmt.tprintf("%.1fM", f64(n) / 1e6)
	if n >= 1000 do return fmt.tprintf("%dk", (n + 500) / 1000)
	return fmt.tprintf("%d", n)
}

@(private = "file")
draw_panel_head :: proc(vg: ^nvg.Context, t: ^Agent_Thread, r: Rect) {
	fill_rect(vg, r, C_PANEL)
	fill_rect(vg, {r.x, r.y + r.h - 1, r.w, 1}, C_LINE)
	title := t.title
	if title == "" do for it in t.items do if it.kind == .User {
		title = it.text
		break
	}
	if title == "" do title = "New session"
	plus := Rect{r.x + r.w - 14 - 28, r.y + 10, 28, 28}
	max_w := plus.x - 10 - (r.x + 14) - 48 - (76 if t.ctx_used > 0 else 0)
	shown := title
	nvg.FontFace(vg, "ui")
	nvg.FontSize(vg, 12.5)
	for text_width(vg, shown, 12.5) > max_w && len(shown) > 4 {
		_, s := utf8.decode_last_rune_in_string(shown)
		shown = shown[:len(shown) - s]
	}
	if shown != title do shown = fmt.tprintf("%s…", strings.trim_right_space(shown))
	sb := Rect{r.x + 8, r.y + 10, text_width(vg, shown, 12.5) + 52, 28}
	if panel_ui.ses_open do fill_rect(vg, sb, {1, 1, 1, 0.1}, 8)
	else if hovered(sb) do fill_rect(vg, sb, C_GHOST, 8)
	draw_lucide(vg, "history", sb.x + 14, sb.y + 14, 14, C_DIM, 1.6)
	label(vg, sb.x + 28, sb.y + 14, shown, C_TEXT if t.title != "" || len(t.items) > 0 else C_TEXT, 12.5)
	draw_lucide(vg, "chevron-down", sb.x + sb.w - 12, sb.y + 14, 12, C_DIM, 1.6)
	if clicked(sb) {
		panel_ui.ses_open = !panel_ui.ses_open
		panel_ui.pick_open, agent_ui.ctx_open = false, false
	}
	if t.ctx_used > 0 && t.ctx_window > 0 {
		// how full the agent's context is; a click offers Compact
		frac := clamp(f32(t.ctx_used) / f32(t.ctx_window), 0, 1)
		pct := fmt.tprintf("%d%%", int(frac * 100 + 0.5))
		cw := text_width(vg, pct, 11.5) + 30
		cr := Rect{plus.x - 6 - cw, r.y + 10, cw, 28}
		if hovered(cr) do fill_rect(vg, cr, C_GHOST, 8)
		cx, cy := cr.x + 12, cr.y + 14
		nvg.BeginPath(vg)
		nvg.Circle(vg, cx, cy, 6)
		nvg.StrokeColor(vg, {1, 1, 1, 0.15})
		nvg.StrokeWidth(vg, 2)
		nvg.Stroke(vg)
		ring := ACCENT if frac < 0.7 else (nvg.Color{1, 0.7, 0.2, 1} if frac < 0.9 else C_ERR)
		nvg.BeginPath(vg)
		nvg.Arc(vg, cx, cy, 6, -math.PI / 2, -math.PI / 2 + 2 * math.PI * max(frac, 0.02), .CW)
		nvg.StrokeColor(vg, ring)
		nvg.Stroke(vg)
		label(vg, cx + 11, cy, pct, C_DIM, 11.5)
		if hovered(cr) do tooltip_request(fmt.tprintf("Context: %s of %s tokens. Click to compact the conversation", tokens_text(t.ctx_used), tokens_text(t.ctx_window)), cr)
		if clicked(cr) do menu_open("context.menu", cr, {fmt.tprintf("Compact the conversation\t%s → summary", tokens_text(t.ctx_used))})
	}
	if pick, ok := menu_take("context.menu"); ok && pick == 0 do agent_compact(t)
	if !t.running && lucide_button(vg, plus, "plus", tip = "New session") {
		agent_session_new(t)
		panel_ui.ses_open = false
		chat.has = false
	}
}

// ---------------------------------------------------------------- the thread

@(private = "file")
item_height :: proc(vg: ^nvg.Context, it: Run_Item, w: f32) -> f32 {
	switch it.kind {
	case .User:
		inner := w - 28
		h: f32 = 24 + chat_text_height(vg, inner, it.text, 13.5)
		if it.ctx != "" || it.marks > 0 do h += 26 + 10
		if it.image != "" do h += 120 + 10
		if it.images != "" do h += 72 + 10
		if it.notes != "" do h += f32(strings.count(it.notes, "\n") + 1) * 24 + (10 if it.image == "" else 0)
		return h
	case .Text: return md_draw(vg, 0, 0, w, it.text, C_TEXT, false)
	case .Error: return chat_text_height(vg, w, it.text, 13.5)
	case .Tool, .Note:
		h: f32 = 28
		if it.open && it.detail != "" do h += detail_height(vg, w, it.detail) + 6
		return h
	}
	return 0
}

DETAIL_SIZE :: f32(11.5)

@(private = "file")
detail_height :: proc(vg: ^nvg.Context, w: f32, text: string) -> f32 {
	nvg.FontFace(vg, chat_face(.Mono))
	nvg.FontSize(vg, DETAIL_SIZE)
	return f32(len(text_rows(vg, text, w - 20))) * DETAIL_SIZE * 1.45 + 16
}

// A tool's calls (inputs and results) or a compaction's summary, under its row.
@(private = "file")
draw_detail :: proc(vg: ^nvg.Context, x, y, w: f32, text: string) -> f32 {
	h := detail_height(vg, w, text)
	fill_rect(vg, {x, y, w, h}, {0x14 / 255.0, 0x14 / 255.0, 0x14 / 255.0, 1}, 8)
	stroke_rect(vg, {x, y, w, h}, C_LINE, 8)
	size := DETAIL_SIZE
	lh := size * 1.45
	nvg.FontFace(vg, chat_face(.Mono))
	nvg.FontSize(vg, size)
	rows := text_rows(vg, text, w - 20)
	pieces := make([]Chat_Piece, len(rows), context.temp_allocator)
	for row, i in rows {
		nvg.FontFace(vg, chat_face(.Mono))
		nvg.FontSize(vg, size)
		pieces[i] = {row[0], row[1], x + 10, y + 8 + f32(i) * lh, nvg.TextBounds(vg, 0, 0, text[row[0]:row[1]]), .Mono, size}
	}
	chat_block(vg, text, pieces, lh)
	nvg.FontFace(vg, chat_face(.Mono))
	nvg.FontSize(vg, size)
	nvg.TextAlign(vg, .LEFT, .MIDDLE)
	for row, i in rows {
		line := text[row[0]:row[1]]
		nvg.FillColor(vg, C_DIM if strings.has_prefix(line, "→") || strings.has_prefix(line, "✕") else C_TEXT)
		nvg.Text(vg, x + 10, y + 8 + f32(i) * lh + lh / 2, line)
	}
	return h
}

@(private = "file")
spinner :: proc(vg: ^nvg.Context, cx, cy, r: f32, color: nvg.Color) {
	a := f32(time.duration_seconds(time.since({}))) * 6
	nvg.BeginPath(vg)
	nvg.Arc(vg, cx, cy, r, a, a + math.PI * 1.4, .CW)
	nvg.StrokeColor(vg, color)
	nvg.StrokeWidth(vg, 1.6)
	nvg.LineCap(vg, .ROUND)
	nvg.Stroke(vg)
}

@(private = "file")
draw_thread_body :: proc(vg: ^nvg.Context, t: ^Agent_Thread, area: Rect) {
	PAD :: f32(14)
	GAP :: f32(10)
	w := area.w - 2 * PAD
	if len(t.items) == 0 {
		cx, cy := area.x + area.w / 2, area.y + area.h / 2 - 40
		label(vg, cx, cy + 28, "New session", C_TEXT, 14, true, .CENTER)
		hint := "Describe the change below. Comment on the canvas with the bar at the bottom: the agent sees your marks."
		nvg.FontFace(vg, "ui")
		nvg.FontSize(vg, 12.5)
		for row, i in text_rows(vg, hint, 280) do label(vg, cx, cy + 54 + f32(i) * 18, hint[row[0]:row[1]], C_DIM, 12.5, false, .CENTER)
		return
	}
	heights := make([]f32, len(t.items), context.temp_allocator)
	content: f32 = PAD
	for it, i in t.items {
		heights[i] = item_height(vg, it, w)
		content += heights[i] + GAP
	}
	status_h: f32 = 34
	content += status_h + PAD
	max_scroll := max(content - area.h, 0)
	t.scroll = clamp(t.scroll + wheel_over(area), 0, max_scroll) // (distance from the newest: the wheel's sign flips)
	nvg.Save(vg)
	nvg.IntersectScissor(vg, area.x, area.y, area.w, area.h)
	defer nvg.Restore(vg)
	// newest at the bottom; scrolled up by t.scroll
	y := area.y + PAD - (max_scroll - t.scroll)
	x := area.x + PAD
	for it, i in t.items {
		h := heights[i]
		switch it.kind {
		case .User:
			card := Rect{x, y, w, h}
			fill_rect(vg, card, C_FIELD, 14)
			cy := y + 12
			ix := x + 14
			if it.ctx != "" || it.marks > 0 {
				cx := ix
				chip :: proc(vg: ^nvg.Context, x, y: f32, icon, text: string) -> f32 {
					cw := text_width(vg, text, 12.5) + 37
					fill_rect(vg, {x, y, cw, 26}, {1, 1, 1, 0.07}, 8)
					draw_lucide(vg, icon, x + 14.5, y + 13, 13, C_TEXT, 1.6)
					label(vg, x + 27, y + 13, text, C_TEXT, 12.5)
					return cw + 6
				}
				for name in strings.split_lines(it.ctx, context.temp_allocator) {
					if name == "" do continue
					folder := strings.has_suffix(name, "/")
					cx += chip(vg, cx, cy, "folder" if folder else "file-text", strings.trim_suffix(name, "/"))
				}
				if it.marks > 0 do cx += chip(vg, cx, cy, "pencil-line", fmt.tprintf("%d mark%s", it.marks, "" if it.marks == 1 else "s"))
				cy += 36
			}
			cy += chat_text(vg, ix, cy, w - 28, it.text, 13.5, C_TEXT)
			if it.images != "" {
				cy += 10
				px := ix
				for p in strings.split_lines(it.images, context.temp_allocator) {
					if p == "" || px + 96 > ix + w - 28 do continue
					tr := Rect{px, cy, 96, 72}
					fill_rect(vg, tr, {0x28 / 255.0, 0x28 / 255.0, 0x28 / 255.0, 1}, 8)
					if img := thumb_of(vg, p); img > 0 {
						iw, ih := nvg.ImageSize(vg, img)
						sc := max(tr.w / f32(iw), tr.h / f32(ih))
						nvg.Save(vg)
						nvg.IntersectScissor(vg, tr.x, tr.y, tr.w, tr.h)
						nvg.BeginPath(vg)
						nvg.RoundedRect(vg, tr.x, tr.y, tr.w, tr.h, 8)
						nvg.FillPaint(vg, nvg.ImagePattern(tr.x + (tr.w - f32(iw) * sc) / 2, tr.y + (tr.h - f32(ih) * sc) / 2, f32(iw) * sc, f32(ih) * sc, 0, img, 1))
						nvg.Fill(vg)
						nvg.Restore(vg)
					}
					stroke_rect(vg, tr, C_LINE, 8)
					if hovered(tr) do tooltip_request(fs_base(p), tr)
					px += 102
				}
				cy += 72
			}
			if it.image != "" {
				cy += 10
				tr := Rect{ix, cy, 190, 120}
				fill_rect(vg, tr, {0x28 / 255.0, 0x28 / 255.0, 0x28 / 255.0, 1}, 8)
				if img := thumb_of(vg, it.image); img > 0 {
					iw, ih := nvg.ImageSize(vg, img)
					sc := min(tr.w / f32(iw), tr.h / f32(ih))
					dw, dh := f32(iw) * sc, f32(ih) * sc
					nvg.BeginPath(vg)
					nvg.RoundedRect(vg, tr.x + (tr.w - dw) / 2, tr.y + (tr.h - dh) / 2, dw, dh, 6)
					nvg.FillPaint(vg, nvg.ImagePattern(tr.x + (tr.w - dw) / 2, tr.y + (tr.h - dh) / 2, dw, dh, 0, img, 1))
					nvg.Fill(vg)
				}
				stroke_rect(vg, tr, C_LINE, 8)
				cy += 120
			}
			if it.notes != "" {
				cy += 10
				for line, k in strings.split_lines(it.notes, context.temp_allocator) {
					nvg.BeginPath(vg)
					nvg.Circle(vg, ix + 8, cy + 9, 8)
					nvg.FillColor(vg, C_GUIDE)
					nvg.Fill(vg)
					label(vg, ix + 8, cy + 9, fmt.tprintf("%d", k + 1), {1, 1, 1, 1}, 10, true, .CENTER)
					label(vg, ix + 24, cy + 9, line, C_DIM, 12.5)
					cy += 24
				}
			}
		case .Text:
			md_draw(vg, x, y, w, it.text, C_TEXT, true)
		case .Error:
			chat_text(vg, x, y, w, it.text, 13.5, C_ERR)
		case .Tool, .Note:
			row := Rect{x - 4, y, w + 8, 28}
			can_open := it.detail != ""
			if can_open && hovered(row) do fill_rect(vg, row, C_GHOST, 6)
			working := t.running && i == len(t.items) - 1
			if it.kind == .Tool {
				if working do spinner(vg, x + 6.5, y + 14, 5.5, ACCENT)
				else if strings.contains(it.detail, "\n✕") do draw_lucide(vg, "x", x + 6.5, y + 14, 13, C_ERR, 2)
				else do draw_lucide(vg, "check", x + 6.5, y + 14, 13, C_OK, 2)
			} else {
				if working do spinner(vg, x + 6.5, y + 14, 5.5, ACCENT)
				else do draw_lucide(vg, "fold-vertical", x + 6.5, y + 14, 13, C_DIM, 1.8)
			}
			text := item_text(it) if it.kind == .Tool else it.text
			if working && it.kind == .Tool do text = fmt.tprintf("%s…", text)
			label(vg, x + 21, y + 14, text, C_DIM, 12.5)
			if can_open {
				draw_lucide(vg, "chevron-down" if it.open else "chevron-right", x + 21 + text_width(vg, text, 12.5) + 12, y + 14, 12, C_DIM, 1.6)
				if clicked(row) do t.items[i].open = !it.open
				if it.open do draw_detail(vg, x, y + 30, w, it.detail)
			}
		}
		y += h + GAP
	}
	// how the run is going, and Undo
	fill_rect(vg, {x, y, w, 1}, C_LINE)
	sy := y + status_h / 2
	status, dot := "", C_DIM
	switch t.state {
	case .Idle:
	case .Working:
		secs := int(time.duration_seconds(time.since(t.started)))
		status = fmt.tprintf("%s is working · %d s · %d tool call%s", AGENT_KIND_NAMES[t.agent], secs, t.tools, "" if t.tools == 1 else "s")
		dot = ACCENT
	case .Done:
		status = fmt.tprintf("Done in %d s · %d tool call%s", int(t.seconds + 0.5), t.tools, "" if t.tools == 1 else "s")
		if t.cost > 0 do status = fmt.tprintf("%s · $%.2f", status, t.cost)
		dot = C_OK
	case .Stopped: status = "Stopped"
	case .Failed:
		status = "Failed"
		dot = C_ERR
	}
	if status != "" {
		nvg.BeginPath(vg)
		nvg.Circle(vg, x + 4, sy, 4)
		nvg.FillColor(vg, dot)
		nvg.Fill(vg)
		label(vg, x + 16, sy, status, C_DIM, 12.5)
	}
	if !t.running && t.state != .Idle && app.file_path in t.touched {
		u := Rect{x + w - 64, sy - 13, 64, 26}
		if button(vg, u, "Undo") do agent_undo_last(t)
	}
}

// ---------------------------------------------------------------- the sessions list

@(private = "file")
draw_sessions_list :: proc(vg: ^nvg.Context, t: ^Agent_Thread, at: Rect) {
	now := time.now()
	day := i64(time.to_unix_seconds(now)) / 86400
	Group :: struct {
		name: string,
		rows: [dynamic]int,
	}
	groups := [3]Group{{"TODAY", make([dynamic]int, context.temp_allocator)}, {"YESTERDAY", make([dynamic]int, context.temp_allocator)}, {"EARLIER", make([dynamic]int, context.temp_allocator)}}
	q := strings.to_lower(strings.trim_space(panel_ui.ses_query), context.temp_allocator)
	for s, i in t.sessions {
		if q != "" && !strings.contains(strings.to_lower(s.title, context.temp_allocator), q) do continue
		d := s.time / 86400
		g := 0 if d >= day else (1 if d == day - 1 else 2)
		append(&groups[g].rows, i)
	}
	h: f32 = 52
	for g in groups do if len(g.rows) > 0 do h += 28 + f32(len(g.rows)) * 56
	if len(t.sessions) == 0 || h == 52 do h += 40
	h = min(h + 8, panel_ui.composer.y - 10 - at.y)
	r := Rect{at.x, at.y, at.w, h}
	panel_ui.popover = r
	popup_shadow(vg, r, 12)
	fill_rect(vg, r, {0x24 / 255.0, 0x24 / 255.0, 0x24 / 255.0, 1}, 12)
	stroke_rect(vg, r, {1, 1, 1, 0.09}, 12)
	field(vg, 0, "sessions.search", "", {r.x + 6, r.y + 6, r.w - 12, 32}, panel_ui.ses_query, placeholder = "Search sessions", icon = .Search)
	if field_is_focused(0, "sessions.search") {
		s := strings.to_string(ui.buf)
		if s != panel_ui.ses_query {
			delete(panel_ui.ses_query)
			panel_ui.ses_query = strings.clone(s)
		}
	}
	nvg.Save(vg)
	nvg.IntersectScissor(vg, r.x, r.y + 44, r.w, r.h - 44)
	y := r.y + 48
	if len(t.sessions) == 0 do label(vg, r.x + 16, y + 16, "No sessions yet", C_DIM, 12.5)
	else if h <= 100 && q != "" do label(vg, r.x + 16, y + 16, "No sessions match", C_DIM, 12.5)
	picked := ""
	for g in groups {
		if len(g.rows) == 0 do continue
		label(vg, r.x + 16, y + 14, g.name, C_DIM, 10.5, true)
		y += 28
		for i in g.rows {
			s := t.sessions[i]
			row := Rect{r.x + 6, y, r.w - 12, 52}
			current := s.sid == t.sid
			hov := hovered(row)
			if hov do fill_rect(vg, row, {1, 1, 1, 0.07}, 8)
			nvg.BeginPath(vg)
			nvg.Circle(vg, row.x + 16, row.y + 18, 4)
			nvg.FillColor(vg, AGENT_DOTS[s.agent])
			nvg.Fill(vg)
			nvg.Save(vg)
			nvg.IntersectScissor(vg, row.x + 30, row.y, row.w - 120, row.h)
			label(vg, row.x + 32, row.y + 18, s.title if s.title != "" else "Untitled session", C_TEXT, 13)
			nvg.Restore(vg)
			label(vg, row.x + 32, row.y + 36, fmt.tprintf("%s · %s", AGENT_KIND_NAMES[s.agent], ago(s.time)), C_DIM, 11.5)
			if current {
				cw := text_width(vg, "Current", 11) + 14
				fill_rect(vg, {row.x + row.w - 10 - cw, row.y + 15, cw, 20}, {ACCENT.r, ACCENT.g, ACCENT.b, 0.15}, 6)
				label(vg, row.x + row.w - 10 - cw / 2, row.y + 25, "Current", ACCENT, 11, true, .CENTER)
			} else if hov {
				rb := Rect{row.x + row.w - 100, row.y + 12, 90, 28}
				fill_rect(vg, rb, {0.95, 0.95, 0.96, 1}, 7)
				draw_lucide(vg, "history", rb.x + 18, rb.y + 14, 12, {0.1, 0.1, 0.1, 1}, 1.8)
				label(vg, rb.x + 31, rb.y + 14, "Resume", {0.1, 0.1, 0.1, 1}, 12.5, true)
			}
			if clicked(row) && !current && !t.running do picked = s.sid
			y += 56
		}
	}
	nvg.Restore(vg)
	if picked != "" {
		agent_session_resume(t, picked)
		panel_ui.ses_open = false
		chat.has = false
	}
	if mouse_pressed(MOUSE_BUTTON_LEFT) && !in_rect(r, app.mouse) && app.mouse.y > TAB_H + HEAD_H do panel_ui.ses_open = false
	if key_pressed(KEY_ESCAPE) && ui.focus == "" do panel_ui.ses_open = false
}

// ---------------------------------------------------------------- the input

PROMPT_SIZE :: f32(14)
PROMPT_LH :: f32(20)

@(private = "file")
prompt_text_w :: proc(comp: Rect) -> f32 {
	return comp.w - 12 - 10
}

// The prompt's lines (byte ranges), with the empty line a final newline opens.
@(private = "file")
prompt_rows :: proc(vg: ^nvg.Context, text: string, w: f32) -> [][2]int {
	nvg.FontFace(vg, "ui")
	nvg.FontSize(vg, PROMPT_SIZE)
	out := make([dynamic][2]int, context.temp_allocator)
	if text != "" do append(&out, ..text_rows(vg, text, w))
	if text == "" || strings.has_suffix(text, "\n") do append(&out, [2]int{len(text), len(text)})
	return out[:]
}

// The line the caret is on: the last one starting at or before it.
@(private = "file")
row_of :: proc(rows: [][2]int, at: int) -> int {
	ri := 0
	for row, i in rows do if row[0] <= at do ri = i
	return ri
}

@(private = "file")
composer_height :: proc(vg: ^nvg.Context, t: ^Agent_Thread) -> f32 {
	w := prompt_text_w({0, 0, agent_side_w() - 24, 0})
	text := strings.to_string(ui.buf) if field_is_focused(0, "agent.prompt") else agent_state.draft
	lines := len(prompt_rows(vg, text, w))
	h := 10 + f32(clamp(lines, 1, 8)) * PROMPT_LH + 10 + 36 + 10
	if len(t.attached) > 0 || annotations_count() > 0 do h += 26 + 10
	if len(chat_images) > 0 do h += 44 + 10
	return h
}

@(private = "file")
ctx_button_rect :: proc(comp: Rect) -> Rect {
	return {comp.x + 12, comp.y + comp.h - 10 - 35, 34, 34}
}

@(private = "file")
draw_composer :: proc(vg: ^nvg.Context, t: ^Agent_Thread, comp: Rect) {
	focused := field_is_focused(0, "agent.prompt")
	fill_rect(vg, comp, C_INPUT, 14)
	stroke_rect(vg, comp, ACCENT if focused else {1, 1, 1, 0.09}, 14)
	y := comp.y + 10
	// the pictures for this request
	if len(chat_images) > 0 {
		draw_chat_images(vg, comp.x + 12, y)
		y += 54
	}
	// chips: context and marks
	if len(t.attached) > 0 || annotations_count() > 0 {
		x := comp.x + 12
		remove := -1
		chip :: proc(vg: ^nvg.Context, x, y: f32, icon, text: string, tip: string) -> (w: f32, close: bool) {
			w = text_width(vg, text, 12.5) + 56
			fill_rect(vg, {x, y, w, 26}, {1, 1, 1, 0.07}, 8)
			draw_lucide(vg, icon, x + 14.5, y + 13, 13, C_TEXT, 1.6)
			label(vg, x + 27, y + 13, text, C_TEXT, 12.5)
			close = lucide_button(vg, {x + w - 23, y + 4, 18, 18}, "x", tip = tip)
			return w + 6, close
		}
		if len(t.attached) > 2 {
			text := fmt.tprintf("%d items", len(t.attached))
			cw := text_width(vg, text, 12.5) + 37
			r := Rect{x, y, cw, 26}
			fill_rect(vg, r, {1, 1, 1, 0.07}, 8)
			draw_lucide(vg, "paperclip", x + 14.5, y + 13, 13, C_TEXT, 1.6)
			label(vg, x + 27, y + 13, text, C_TEXT, 12.5)
			if clicked(r) do agent_ui.ctx_open = true
			x += cw + 6
		} else {
			for c, i in t.attached {
				w, close := chip(vg, x, y, "folder" if c.folder else "file-text", fs_base(c.path), c.path)
				if close do remove = i
				x += w
			}
		}
		if n := annotations_count(); n > 0 {
			_, close := chip(vg, x, y, "pencil-line", fmt.tprintf("%d mark%s", n, "" if n == 1 else "s"), "Clear marks")
			if close do annotations_clear()
		}
		if remove >= 0 do agent_context_remove(t, remove)
		y += 36
	}
	// the prompt, wrapped
	agent := agent_state.choice
	name := AGENT_KIND_NAMES[agent]
	placeholder: string
	switch {
	case !agent_available(agent): placeholder = fmt.tprintf("Install %s, or pick another agent", name)
	case t.running: placeholder = "Queue a follow-up…"
	case annotations_count() > 0: placeholder = fmt.tprintf("Tell %s about your marks…", name)
	case: placeholder = fmt.tprintf("Ask %s to change this design…", name)
	}
	tx := comp.x + 14
	tw := prompt_text_w(comp)
	area := Rect{tx - 2, y - 2, tw + 4, comp.y + comp.h - 10 - 36 - 10 - y + 4}
	prompt_area(vg, area, tx, y, tw, placeholder)

	// the second row: context, the agent, Send/Stop
	row_y := comp.y + comp.h - 10 - 36
	cb := ctx_button_rect(comp)
	fill_rect(vg, cb, {1, 1, 1, 0.12} if agent_ui.ctx_open || hovered(cb) else C_FIELD, 17)
	draw_lucide(vg, "paperclip", cb.x + 17, cb.y + 17, 16, C_DIM, 1.6)
	if hovered(cb) do tooltip_request("Context for the agent", cb)
	if n := len(t.attached); n > 0 {
		nvg.BeginPath(vg)
		nvg.Circle(vg, cb.x + 27, cb.y + 5, 8)
		nvg.FillColor(vg, ACCENT)
		nvg.Fill(vg)
		label(vg, cb.x + 27, cb.y + 5, fmt.tprintf("%d", n), {1, 1, 1, 1}, 10, true, .CENTER)
	}
	if clicked(cb) {
		agent_ui.ctx_open = !agent_ui.ctx_open
		panel_ui.pick_open, panel_ui.ses_open = false, false
	}
	send := Rect{comp.x + comp.w - 10 - 36, row_y, 36, 36}
	model := agent_model_label(agent)
	pw := text_width(vg, name, 13) + 52 + (text_width(vg, model, 12.5) + 6 if model != "" else 0)
	pick := Rect{send.x - 8 - pw, row_y + 1, pw, 34}
	fill_rect(vg, pick, {1, 1, 1, 0.12} if panel_ui.pick_open || hovered(pick) else C_FIELD, 17)
	nvg.BeginPath(vg)
	nvg.Circle(vg, pick.x + 16, pick.y + 17, 6)
	nvg.FillColor(vg, AGENT_DOTS[agent])
	nvg.Fill(vg)
	label(vg, pick.x + 28, pick.y + 17, name, C_TEXT, 13)
	if model != "" do label(vg, pick.x + 28 + text_width(vg, name, 13) + 6, pick.y + 17, model, C_DIM, 12.5)
	draw_lucide(vg, "chevron-down", pick.x + pick.w - 16, pick.y + 17, 12, C_DIM, 1.6)
	if clicked(pick) {
		panel_ui.pick_open = !panel_ui.pick_open
		agent_ui.ctx_open, panel_ui.ses_open = false, false
	}
	running := t.running
	empty := strings.trim_space(agent_state.draft) == "" && !(focused && strings.trim_space(strings.to_string(ui.buf)) != "")
	nvg.BeginPath(vg)
	nvg.Circle(vg, send.x + 18, send.y + 18, 18)
	nvg.FillColor(vg, {0.95, 0.95, 0.96, 1} if running || !empty else {1, 1, 1, 0.25})
	nvg.Fill(vg)
	if running {
		fill_rect(vg, {send.x + 12, send.y + 12, 12, 12}, {0.1, 0.1, 0.1, 1}, 2)
		if hovered(send) do tooltip_request("Stop  ⌘.", send)
	} else do draw_lucide(vg, "arrow-up", send.x + 18, send.y + 18, 16, {0.1, 0.1, 0.1, 1}, 2)
	if clicked(send) {
		if running && empty do agent_stop(t)
		else do prompt_send()
	}
}

// The prompt's and the thread's right-button menus.
@(private = "file")
text_menus :: proc() {
	if pick, ok := menu_take("prompt.menu"); ok {
		if !field_is_focused(0, "agent.prompt") do field_focus(0, "agent.prompt", agent_state.draft)
		text := strings.to_string(ui.buf)
		a, b := min(ui.sel, ui.caret), max(ui.sel, ui.caret)
		if ui.sel < 0 do a, b = ui.caret, ui.caret
		a, b = clamp(a, 0, len(text)), clamp(b, 0, len(text))
		replace :: proc(a, b: int, with: string) {
			text := strings.to_string(ui.buf)
			out := strings.concatenate({text[:a], with, text[b:]}, context.temp_allocator)
			strings.builder_reset(&ui.buf)
			strings.write_string(&ui.buf, out)
			ui.caret, ui.sel = a + len(with), -1
		}
		switch pick {
		case 0:
			if b > a {
				platform_clipboard_set(text[a:b])
				replace(a, b, "")
			}
		case 1: if b > a do platform_clipboard_set(text[a:b])
		case 2: if !chat_paste_image() do replace(a, b, platform_clipboard_get())
		case 4: ui.sel, ui.caret = 0, len(text)
		}
		s := strings.to_string(ui.buf)
		if s != agent_state.draft {
			delete(agent_state.draft)
			agent_state.draft = strings.clone(s)
		}
	}
	if pick, ok := menu_take("chat.menu"); ok {
		switch pick {
		case 0:
			platform_clipboard_set(chat_selected_text())
			set_status("Copied")
		case 1: quote_in_reply(chat_selected_text())
		case 3:
			if len(chat.prev) > 0 {
				chat.a, chat.b, chat.has = {0, 0}, {len(chat.prev) - 1, len(chat.prev[len(chat.prev) - 1].text)}, true
			}
		}
	}
}

// The selected text as a quote at the start of the reply ("> " before each line).
quote_in_reply :: proc(text: string) {
	q := strings.trim_space(text)
	if q == "" do return
	b := strings.builder_make(context.temp_allocator)
	for line in strings.split_lines(q, context.temp_allocator) {
		strings.write_string(&b, "> ")
		strings.write_string(&b, line)
		strings.write_byte(&b, '\n')
	}
	strings.write_byte(&b, '\n')
	cur := strings.to_string(ui.buf) if field_is_focused(0, "agent.prompt") else agent_state.draft
	strings.write_string(&b, cur)
	out := strings.to_string(b)
	delete(agent_state.draft)
	agent_state.draft = strings.clone(out)
	field_focus(0, "agent.prompt", out)
	ui.sel = -1 // the caret at the end
	chat.has = false
}

@(private = "file")
prompt_send :: proc() {
	text := strings.to_string(ui.buf) if field_is_focused(0, "agent.prompt") else agent_state.draft
	text = strings.clone(strings.trim_space(text), context.temp_allocator)
	if text == "" do return
	if field_is_focused(0, "agent.prompt") {
		strings.builder_reset(&ui.buf)
		ui.caret, ui.sel = 0, -1
	}
	agent_send(text)
	agent_draft_clear()
	chat.has = false
}

// A field that wraps: typing with the field's keys (widgets.odin), Return sends, ⇧Return
// adds a line; clicks place the caret.
@(private = "file")
prompt_area :: proc(vg: ^nvg.Context, area: Rect, x, y, w: f32, placeholder: string) {
	focused := field_is_focused(0, "agent.prompt")
	text := strings.to_string(ui.buf) if focused else agent_state.draft
	rows := prompt_rows(vg, text, w)
	visible := clamp(len(rows), 1, 8)
	first := max(0, len(rows) - visible) // the end stays in view
	if focused {
		ri := row_of(rows, ui.caret)
		if ri < first do first = ri
	}
	if hovered(area) do ui.cursor_hint = .IBeam
	offset_at :: proc(vg: ^nvg.Context, text: string, rows: [][2]int, first: int, x, y, w: f32, p: [2]f32) -> int {
		if len(rows) == 0 do return 0
		ri := clamp(first + int((p.y - y) / PROMPT_LH), 0, len(rows) - 1)
		row := rows[ri]
		// the spaces a line ends with belong to it
		if ri + 1 < len(rows) do row[1] = max(row[1], rows[ri + 1][0] - (1 if rows[ri + 1][0] > 0 && text[rows[ri + 1][0] - 1] == '\n' else 0))
		else do row[1] = len(text) - (1 if strings.has_suffix(text, "\n") && row[0] < len(text) else 0)
		nvg.FontFace(vg, "ui")
		nvg.FontSize(vg, PROMPT_SIZE)
		at, best := row[0], abs(p.x - x)
		k := row[0]
		for k < row[1] {
			_, s := utf8.decode_rune_in_string(text[k:row[1]])
			k += s
			if d := abs(p.x - (x + nvg.TextBounds(vg, 0, 0, text[row[0]:k]))); d < best do at, best = k, d
		}
		return at
	}
	if clicked(area) {
		if !focused {
			field_focus(0, "agent.prompt", agent_state.draft)
			focused = true
			text = strings.to_string(ui.buf)
		}
		ui.caret = offset_at(vg, text, rows, first, x, y, w, app.mouse)
		ui.sel = ui.caret
		ui.drag_select = true
	}
	if focused && ui.drag_select && mouse_down(MOUSE_BUTTON_LEFT) do ui.caret = offset_at(vg, text, rows, first, x, y, w, app.mouse)
	if focused {
		ui.focus_rect = {area.x + ui.origin.x, area.y + ui.origin.y, area.w, area.h}
		if !ui.input_claimed {
			ui.input_claimed = true
			if key_pressed(KEY_ENTER) || key_pressed(KEY_KP_ENTER) {
				if mod_shift() {
					a, b := min(ui.sel, ui.caret), max(ui.sel, ui.caret)
					if ui.sel < 0 do a, b = ui.caret, ui.caret
					s := strings.to_string(ui.buf)
					out := strings.concatenate({s[:a], "\n", s[b:]}, context.temp_allocator)
					strings.builder_reset(&ui.buf)
					strings.write_string(&ui.buf, out)
					ui.caret, ui.sel = a + 1, -1
				} else {
					prompt_send()
					return
				}
			} else {
				// ⌘V with a picture on the clipboard attaches it
				if mod_cmd() && key_pressed(KEY_V) && chat_paste_image() do pf.key_pressed[KEY_V] = false
				index := ui.field_count
				ui.field_count += 1
				field_keys(index, false)
			}
		}
		s := strings.to_string(ui.buf)
		if s != agent_state.draft {
			delete(agent_state.draft)
			agent_state.draft = strings.clone(s)
		}
		text = s
		rows = prompt_rows(vg, text, w)
	}
	// the right button: Cut, Copy, Paste, Select All
	if hovered(area) && mouse_pressed(MOUSE_BUTTON_RIGHT) {
		if !focused do field_focus(0, "agent.prompt", agent_state.draft)
		menu_open("prompt.menu", {app.mouse.x, app.mouse.y, 0, 0}, {"Cut\t⌘X", "Copy\t⌘C", "Paste\t⌘V", "-", "Select All\t⌘A"})
	}
	nvg.Save(vg)
	nvg.IntersectScissor(vg, area.x, area.y, area.w, area.h)
	defer nvg.Restore(vg)
	if text == "" {
		label(vg, x, y + PROMPT_LH / 2, placeholder, C_DIM, PROMPT_SIZE)
	} else {
		if focused && ui.sel >= 0 && ui.sel != ui.caret {
			a, b := min(ui.sel, ui.caret), max(ui.sel, ui.caret)
			nvg.FontFace(vg, "ui")
			nvg.FontSize(vg, PROMPT_SIZE)
			nvg.BeginPath(vg)
			for row, i in rows {
				end := rows[i + 1][0] if i + 1 < len(rows) else len(text)
				s, e := max(a, row[0]), min(b, end)
				if s >= e || i < first do continue
				x0 := x + nvg.TextBounds(vg, 0, 0, text[row[0]:s])
				x1 := x + nvg.TextBounds(vg, 0, 0, strings.trim_right(text[row[0]:e], "\n"))
				nvg.Rect(vg, x0, y + f32(i - first) * PROMPT_LH, max(x1 - x0, 3), PROMPT_LH)
			}
			nvg.FillColor(vg, {ACCENT.r, ACCENT.g, ACCENT.b, 0.35})
			nvg.Fill(vg)
		}
		for row, i in rows do if i >= first do label(vg, x, y + f32(i - first) * PROMPT_LH + PROMPT_LH / 2, text[row[0]:row[1]], C_TEXT, PROMPT_SIZE)
	}
	if focused && (ui.sel < 0 || ui.sel == ui.caret) && (int(time.now()._nsec / 500_000_000) % 2 == 0 || ui.drag_select) {
		ri := row_of(rows, ui.caret)
		cx := x
		if len(rows) > 0 {
			nvg.FontFace(vg, "ui")
			nvg.FontSize(vg, PROMPT_SIZE)
			// up to the caret, the spaces before it too (a row's own range leaves them out)
			cx += nvg.TextBounds(vg, 0, 0, text[rows[ri][0]:clamp(ui.caret, rows[ri][0], len(text))])
		}
		fill_rect(vg, {cx, y + f32(ri - first) * PROMPT_LH + 2, 1.5, PROMPT_LH - 4}, C_TEXT)
	}
}

// ---------------------------------------------------------------- the agent picker

@(private = "file")
draw_agent_picker :: proc(vg: ^nvg.Context, comp: Rect) {
	choice := agent_state.choice
	models := agent_models(choice)
	cur := agent_model_of(choice)
	efforts := cur.efforts
	w: f32 = 320
	h: f32 = 12 + 26 + f32(len(Agent_Kind)) * 36 + 26 + f32(len(models)) * 50 + 26 + 40 + 12 + 50 + 8
	h = min(h, comp.y - 10 - TAB_H - 10)
	r := Rect{comp.x + comp.w - w, comp.y - 10 - h, w, h}
	panel_ui.popover = r
	popup_shadow(vg, r, 12)
	fill_rect(vg, r, {0x24 / 255.0, 0x24 / 255.0, 0x24 / 255.0, 1}, 12)
	stroke_rect(vg, r, {1, 1, 1, 0.09}, 12)
	nvg.Save(vg)
	nvg.IntersectScissor(vg, r.x, r.y, r.w, r.h)
	defer nvg.Restore(vg)
	y := r.y + 12
	section :: proc(vg: ^nvg.Context, x: f32, y: ^f32, name: string) {
		label(vg, x + 18, y^ + 13, name, C_DIM, 10.5, true)
		y^ += 26
	}
	check :: proc(vg: ^nvg.Context, row: Rect) {draw_lucide(vg, "check", row.x + row.w - 18, row.y + row.h / 2, 13, C_TEXT, 2)}
	section(vg, r.x, &y, "AGENT")
	for k in Agent_Kind {
		row := Rect{r.x + 8, y, r.w - 16, 32}
		on := k == choice
		if on do fill_rect(vg, row, {1, 1, 1, 0.1}, 8)
		else if hovered(row) do fill_rect(vg, row, C_GHOST, 8)
		nvg.BeginPath(vg)
		nvg.Circle(vg, row.x + 14, row.y + 16, 4.5)
		nvg.FillColor(vg, AGENT_DOTS[k])
		nvg.Fill(vg)
		avail := agent_available(k)
		label(vg, row.x + 28, row.y + 16, AGENT_KIND_NAMES[k], C_TEXT if avail else C_DIM, 13.5)
		if !avail do label(vg, row.x + 28 + text_width(vg, AGENT_KIND_NAMES[k], 13.5) + 8, row.y + 16, "not installed", C_DIM, 11.5)
		if on do check(vg, row)
		if clicked(row) do agent_choose(k)
		y += 36
	}
	section(vg, r.x, &y, "MODEL")
	for m in models {
		row := Rect{r.x + 8, y, r.w - 16, 46}
		on := m.id == cur.id
		if on do fill_rect(vg, row, {1, 1, 1, 0.1}, 8)
		else if hovered(row) do fill_rect(vg, row, C_GHOST, 8)
		label(vg, row.x + 10, row.y + 15, m.name, C_TEXT, 13.5)
		nvg.Save(vg)
		nvg.IntersectScissor(vg, row.x, row.y, row.w - 34, row.h)
		label(vg, row.x + 10, row.y + 33, m.hint, C_DIM, 11.5)
		nvg.Restore(vg)
		if on do check(vg, row)
		if clicked(row) do agent_set_model(choice, m.id)
		y += 50
	}
	section(vg, r.x, &y, "REASONING")
	seg := Rect{r.x + 18, y, r.w - 36, 30}
	if len(efforts) == 0 {
		label(vg, seg.x, seg.y + 15, fmt.tprintf("Set by %s", AGENT_KIND_NAMES[choice]), C_DIM, 12.5)
	} else {
		fill_rect(vg, seg, C_FIELD, 8)
		sw := (seg.w - 4) / f32(len(efforts))
		chosen := agent_effort_of(choice)
		for e, i in efforts {
			b := Rect{seg.x + 2 + f32(i) * sw, seg.y + 2, sw, seg.h - 4}
			on := e == chosen
			if on do fill_rect(vg, b, {1, 1, 1, 0.14}, 6)
			else if hovered(b) do fill_rect(vg, b, C_GHOST, 6)
			label(vg, b.x + b.w / 2, b.y + b.h / 2, effort_title(e), C_TEXT if on else C_DIM, 12, on, .CENTER)
			if clicked(b) do agent_set_effort(choice, "" if on else e) // a second click: the CLI's own
		}
	}
	y += 40
	fill_rect(vg, {r.x + 8, y, r.w - 16, 1}, {1, 1, 1, 0.08})
	y += 8
	row := Rect{r.x + 8, y, r.w - 16, 44}
	if hovered(row) do fill_rect(vg, row, C_GHOST, 8)
	draw_lucide(vg, "plug", row.x + 18, row.y + 22, 14, C_DIM, 1.6)
	label(vg, row.x + 36, row.y + 14, "Connect agents…", C_TEXT, 13.5)
	label(vg, row.x + 36, row.y + 31, "Add a client over MCP", C_DIM, 11.5)
	if clicked(row) {
		panel_ui.pick_open = false
		onboarding_start(1)
	}
	if mouse_pressed(MOUSE_BUTTON_LEFT) && !in_rect(r, app.mouse) && !in_rect(panel_ui.composer, app.mouse) do panel_ui.pick_open = false
	if key_pressed(KEY_ESCAPE) do panel_ui.pick_open = false
}

// ---------------------------------------------------------------- the marks bar

// At the bottom of the canvas in Agent mode, instead of the tools: the marks are always on.
draw_marks_bar :: proc(vg: ^nvg.Context) {
	panel_ui.marks_bar = {}
	if !agent_mode() do return
	c := app.canvas
	tools_w: f32 = 0
	for tool in Mark_Tool do tools_w += text_width(vg, MARK_TOOL_NAMES[tool], 12.5) + 40
	clear_w := text_width(vg, "Clear marks", 12.5) + 40
	w := tools_w + 3 * 22 + 20 + clear_w + 12
	r := Rect{c.x + (c.w - w) / 2, app.screen.y - 10 - 44, w, 44}
	panel_ui.marks_bar = r
	popup_shadow(vg, r, 14)
	fill_rect(vg, r, C_INPUT, 14)
	stroke_rect(vg, r, {1, 1, 1, 0.09}, 14)
	x := r.x + 6
	for tool in Mark_Tool {
		tw := text_width(vg, MARK_TOOL_NAMES[tool], 12.5) + 40
		b := Rect{x, r.y + 6, tw - 4, 32}
		on := annot.tool == tool
		if on do fill_rect(vg, b, {1, 1, 1, 0.12}, 8)
		else if hovered(b) do fill_rect(vg, b, C_GHOST, 8)
		draw_lucide(vg, MARK_TOOL_ICONS[tool], b.x + 16, b.y + 16, 14, C_TEXT if on else C_DIM, 1.6)
		label(vg, b.x + 30, b.y + 16, MARK_TOOL_NAMES[tool], C_TEXT if on else C_DIM, 12.5)
		if clicked(b) do annot.tool = tool
		x += tw
	}
	fill_rect(vg, {x + 2, r.y + 12, 1, 20}, {1, 1, 1, 0.1})
	x += 8
	for col, i in MARK_COLORS {
		cr := Rect{x, r.y + 13, 18, 18}
		nvg.BeginPath(vg)
		nvg.Circle(vg, cr.x + 9, cr.y + 9, 6.5)
		nvg.FillColor(vg, col)
		nvg.Fill(vg)
		if annot.color == i {
			nvg.BeginPath(vg)
			nvg.Circle(vg, cr.x + 9, cr.y + 9, 8.5)
			nvg.StrokeColor(vg, {1, 1, 1, 0.95})
			nvg.StrokeWidth(vg, 1.5)
			nvg.Stroke(vg)
		}
		if clicked(cr) do annot.color = i
		x += 22
	}
	fill_rect(vg, {x + 4, r.y + 12, 1, 20}, {1, 1, 1, 0.1})
	x += 10
	cb := Rect{x, r.y + 6, clear_w - 4, 32}
	if hovered(cb) do fill_rect(vg, cb, C_GHOST, 8)
	draw_lucide(vg, "eraser", cb.x + 16, cb.y + 16, 14, C_DIM, 1.6)
	label(vg, cb.x + 30, cb.y + 16, "Clear marks", C_DIM, 12.5)
	if clicked(cb) do annotations_clear()
	// a reminder at the top of the canvas while there are marks
	if annotations_count() > 0 {
		note := "Marks are for the agent only. They are not saved in the file."
		nw := text_width(vg, note, 12.5) + 46
		nr := Rect{c.x + (c.w - nw) / 2, TAB_H + 16, nw, 28}
		fill_rect(vg, nr, C_GUIDE, 8)
		draw_lucide(vg, "pencil", nr.x + 18, nr.y + 14, 12, {1, 1, 1, 1}, 1.8)
		label(vg, nr.x + 32, nr.y + 14, note, {1, 1, 1, 1}, 12.5, true)
	}
}

// The Dashboard's thread: the same selection, copy and menus.
chat_dashboard_end :: proc(vg: ^nvg.Context, area: Rect) {
	if area.w > 0 do chat_input(vg, area)
	chat_frame_end()
	text_menus()
}

// Leaving Agent mode: the marks stay for when it comes back, the popovers close.
annot_leave_agent_mode :: proc() {
	panel_ui.pick_open, panel_ui.ses_open, agent_ui.ctx_open = false, false, false
	chat.has = false
}
