#+build !js
package agentic_design

import "engine"

import "core:fmt"
import "core:strings"
import "core:time"
import nvg "nanovg"

// The agent input (app-ui.pen "Agent input", agent-context.pen): a rounded field at the
// bottom centre of the canvas and of the dashboard. In it: the context the agent may read
// (paperclip), the marks for it (pencil, annotations.odin), the agent to ask and Send (Stop
// while it works). Above it: chips of what goes with the request, the marks toolbar, and the
// thread with its sessions: the requests, what the agent says, the tools it called and how
// the run ended (agent_run.odin runs it). ⌘L focuses the field.

AGENT_INPUT_W :: f32(620)
AGENT_INPUT_H :: f32(52)
AGENT_PANEL_W :: f32(620)
AGENT_PANEL_MAX_H :: f32(360)

@(private = "file")
input_rect :: proc() -> Rect {
	w := min(AGENT_INPUT_W, app.screen.x - 2 * 24)
	bottom := app.screen.y - 22 if app.tab < 0 else toolbar_rect().y - 10
	return {(app.screen.x - w) / 2, bottom - AGENT_INPUT_H, w, AGENT_INPUT_H}
}

// The parts drawn last frame, for the pointer tests (canvas or chrome).
agent_ui: struct {
	panel:    Rect, // the thread panel
	chips:    Rect,
	toolbar:  Rect, // the marks toolbar
	popover:  Rect, // context or sessions
	ctx_open: bool, // the context popover
	ses_open: bool, // the sessions list
	thumbs:   map[string]int, // marked-view pictures in the thread (NanoVG images)
}

// Room the dashboard keeps free at the bottom of its list.
agent_input_reserve :: proc() -> f32 {
	return AGENT_INPUT_H + 40
}

// The pointer is on the input or what floats above it (not the canvas).
agent_chrome_hit :: proc(p: [2]f32) -> bool {
	if agent_mode() do return agent_panel_hit(p)
	if app.tab >= 0 do return false // Design mode: no agent input
	if in_rect(input_rect(), p) do return true
	for r in ([4]Rect{agent_ui.panel, agent_ui.chips, agent_ui.toolbar, agent_ui.popover}) do if r.w > 0 && in_rect(r, p) do return true
	return false
}

@(private = "file")
wrap_height :: proc(vg: ^nvg.Context, w: f32, text: string, size: f32) -> f32 {
	nvg.FontFace(vg, "ui")
	nvg.FontSize(vg, size)
	nvg.TextLineHeight(vg, 1.35)
	b: [4]f32
	nvg.TextBoxBounds(vg, 0, 0, w, text, &b)
	return b[3] - b[1]
}

@(private = "file")
wrap_text :: proc(vg: ^nvg.Context, x, y, w: f32, text: string, size: f32, color: nvg.Color) {
	nvg.FontFace(vg, "ui")
	nvg.FontSize(vg, size)
	nvg.TextLineHeight(vg, 1.35)
	nvg.TextAlign(vg, .LEFT, .TOP)
	nvg.FillColor(vg, color)
	nvg.TextBox(vg, x, y, w, text)
	nvg.TextLineHeight(vg, 1)
}

tool_verb :: proc(tool: string) -> string {
	switch tool {
	case "create_nodes": return "Created layers"
	case "update_nodes": return "Changed layers"
	case "delete_nodes": return "Deleted layers"
	case "batch": return "Edited the design"
	case "screenshot": return "Took a screenshot"
	case "get_document": return "Read the document"
	case "get_selection": return "Read the selection"
	case "open": return "Opened a file"
	case "save": return "Saved"
	case "lint": return "Checked the design"
	case "connect": return "Connected layers"
	case "set_variables": return "Set variables"
	case "get_guide": return "Read the guide"
	case "reorder": return "Reordered layers"
	case "undo": return "Undid a step"
	}
	return tool
}

item_text :: proc(it: Run_Item) -> string {
	if it.kind != .Tool do return it.text
	verb := tool_verb(it.text)
	return verb if it.count == 1 else fmt.tprintf("%s ×%d", verb, it.count)
}

thumb_of :: proc(vg: ^nvg.Context, path: string) -> int {
	if path == "" do return 0
	if img, ok := agent_ui.thumbs[path]; ok do return img
	img := 0
	if fs_exists(path) do img = nvg.CreateImagePath(vg, strings.clone_to_cstring(path, context.temp_allocator), {})
	agent_ui.thumbs[strings.clone(path)] = img
	return img
}

@(private = "file")
short_date :: proc(unix: i64) -> string {
	return ago(unix)
}

@(private = "file")
draw_thread :: proc(vg: ^nvg.Context, t: ^Agent_Thread, bottom: f32) {
	agent_ui.panel = {}
	if !t.shown || (len(t.items) == 0 && len(t.sessions) == 0) do return
	input := input_rect()
	w := min(AGENT_PANEL_W, input.w)
	inner := w - 32
	THUMB_W, THUMB_H :: f32(120), f32(72)
	heights := make([]f32, len(t.items), context.temp_allocator)
	content: f32 = 0
	for it, i in t.items {
		h: f32
		switch it.kind {
		case .User:
			h = wrap_height(vg, inner - 20, it.text, 13) + 16
			if it.image != "" || it.marks > 0 do h += THUMB_H + 10
		case .Text, .Error: h = wrap_height(vg, inner, it.text, 13) + 8
		case .Tool: h = 22
		}
		heights[i] = h
		content += h + 6
	}
	header_h: f32 = 44
	status_h: f32 = 34 if len(t.items) > 0 else 0
	if len(t.items) == 0 do content = 34
	h := min(header_h + content + status_h + 14, AGENT_PANEL_MAX_H)
	r := Rect{(app.screen.x - w) / 2, bottom - 10 - h, w, h}
	agent_ui.panel = r
	float_surface(vg, r, 14)

	// header: the sessions of this file, this one's title, a new one
	hy := r.y + 8
	sb := Rect{r.x + 10, hy, 0, 28}
	label_text := fmt.tprintf("Sessions  %d", len(t.sessions))
	sb.w = text_width(vg, label_text, 12) + 46
	if agent_ui.ses_open do fill_rect(vg, sb, ACTIVE_BG, 8)
	else if hovered(sb) do fill_rect(vg, sb, HOVER_BG, 8)
	else do fill_rect(vg, sb, {1, 1, 1, 0.05}, 8)
	draw_lucide(vg, "clock", sb.x + 14, sb.y + 14, 13, TEXT_FG, 1.6)
	label(vg, sb.x + 26, sb.y + 14, label_text, TEXT_FG, 12)
	draw_icon(vg, .Chevron_Down, sb.x + sb.w - 11, sb.y + 14, TEXT_DIM, 10)
	if clicked(sb) {
		agent_ui.ses_open = !agent_ui.ses_open
		agent_ui.ctx_open = false
	}
	ns := Rect{r.x + r.w - 10 - 112, hy, 112, 28}
	if !t.running && button(vg, ns, "+ New session") {
		agent_session_new(t)
		agent_ui.ses_open = false
	}
	title := t.title
	if title == "" do for it in t.items do if it.kind == .User {
		title = it.text
		break
	}
	nvg.Save(vg)
	nvg.IntersectScissor(vg, sb.x + sb.w + 10, hy, ns.x - 10 - (sb.x + sb.w + 10), 28)
	label(vg, sb.x + sb.w + 12, hy + 14, title if title != "" else "New session", TEXT_DIM, 12)
	nvg.Restore(vg)

	// the list scrolls; it follows the newest item unless scrolled up
	area := Rect{r.x, r.y + header_h, r.w, r.h - header_h - status_h - 6}
	if len(t.items) == 0 {
		label(vg, r.x + 16, area.y + 16, "A new session: ask something below.", TEXT_DIM, 12)
	}
	max_scroll := max(content - area.h, 0)
	t.scroll = clamp(t.scroll + wheel_over(area), 0, max_scroll) // (distance from the newest)
	nvg.Save(vg)
	nvg.IntersectScissor(vg, area.x, area.y, area.w, area.h)
	y := area.y + area.h - content + t.scroll
	x := r.x + 16
	for it, i in t.items {
		hh := heights[i]
		if y + hh >= area.y && y <= area.y + area.h {
			switch it.kind {
			case .User:
				extra := it.image != "" || it.marks > 0
				tw := wrap_width(vg, it.text, 13) + 20
				if extra do tw = max(tw, THUMB_W + 20)
				bw := min(tw, inner)
				b := Rect{r.x + r.w - 16 - bw, y, bw, hh}
				fill_rect(vg, b, {1, 1, 1, 0.08}, 10)
				ty := y + 8
				if extra {
					tr := Rect{b.x + 10, y + 10, THUMB_W, THUMB_H}
					if img := thumb_of(vg, it.image); img > 0 {
						iw, ih := nvg.ImageSize(vg, img)
						sc := max(tr.w / f32(iw), tr.h / f32(ih))
						nvg.Save(vg)
						nvg.IntersectScissor(vg, tr.x, tr.y, tr.w, tr.h)
						nvg.BeginPath(vg)
						nvg.RoundedRect(vg, tr.x, tr.y, tr.w, tr.h, 6)
						nvg.FillPaint(vg, nvg.ImagePattern(tr.x + (tr.w - f32(iw) * sc) / 2, tr.y + (tr.h - f32(ih) * sc) / 2, f32(iw) * sc, f32(ih) * sc, 0, img, 1))
						nvg.Fill(vg)
						nvg.Restore(vg)
					} else do fill_rect(vg, tr, {1, 1, 1, 0.06}, 6)
					if it.marks > 0 do label(vg, tr.x + tr.w + 10, tr.y + 12, fmt.tprintf("%d mark%s", it.marks, "" if it.marks == 1 else "s"), {1, 0.45, 0.6, 1}, 12)
					ty += THUMB_H + 10
				}
				chat_text(vg, b.x + 10, ty, bw - 20, it.text, 13, TEXT_FG, 1.35)
			case .Text:
				chat_text(vg, x, y + 4, inner, it.text, 13, TEXT_FG, 1.35)
			case .Error:
				chat_text(vg, x, y + 4, inner, it.text, 13, {1, 0.5, 0.45, 1}, 1.35)
			case .Tool:
				draw_lucide(vg, "wrench", x + 7, y + 11, 12, TEXT_DIM, 1.6)
				label(vg, x + 20, y + 11, item_text(it), TEXT_DIM, 12)
			}
		}
		y += hh + 6
	}
	nvg.Restore(vg)

	if status_h > 0 {
		// status line: state, time, tools; Undo; hide
		sy := r.y + r.h - status_h
		fill_rect(vg, {r.x + 12, sy, r.w - 24, 1}, PANEL_LINE)
		cy := sy + status_h / 2
		status: string
		color := TEXT_DIM
		switch t.state {
		case .Idle: status = ""
		case .Working:
			secs := int(time.duration_seconds(time.since(t.started)))
			DOTS := [3]string{".", "..", "..."}
			dots := DOTS[secs % 3]
			status = fmt.tprintf("%s is working%s %d s · %d tool call%s", AGENT_KIND_NAMES[t.agent], dots, secs, t.tools, "" if t.tools == 1 else "s")
			color = TEXT_FG // (the window redraws every half second while idle)
		case .Done:
			status = fmt.tprintf("Done in %d s · %d tool call%s", int(t.seconds + 0.5), t.tools, "" if t.tools == 1 else "s")
			if t.cost > 0 do status = fmt.tprintf("%s · $%.2f", status, t.cost)
		case .Stopped: status = "Stopped"
		case .Failed:
			status = "Failed"
			color = {1, 0.5, 0.45, 1}
		}
		label(vg, r.x + 16, cy, status, color, 12)
		hide := Rect{r.x + r.w - 12 - 26, cy - 13, 26, 26}
		if lucide_button(vg, hide, "chevron-down", tip = "Hide") do t.shown = false
		if !t.running && t.state != .Idle && app.tab >= 0 && app.file_path in t.touched {
			u := Rect{hide.x - 8 - 70, cy - 13, 70, 26}
			if button(vg, u, "Undo") do agent_undo_last(t)
		}
	}

	// the sessions list, over the thread
	if agent_ui.ses_open {
		rows := len(t.sessions)
		lh := min(f32(rows) * 44 + 12, r.h - header_h - 8)
		lr := Rect{r.x + 8, r.y + header_h, r.w - 16, max(lh, 50)}
		agent_ui.popover = lr
		fill_rect(vg, lr, {0.15, 0.15, 0.16, 1}, 10)
		stroke_rect(vg, lr, {1, 1, 1, 0.08}, 10)
		if rows == 0 do label(vg, lr.x + 12, lr.y + 24, "No sessions yet.", TEXT_DIM, 12)
		nvg.Save(vg)
		nvg.IntersectScissor(vg, lr.x, lr.y, lr.w, lr.h)
		ry := lr.y + 6
		for s in t.sessions {
			row := Rect{lr.x + 6, ry, lr.w - 12, 40}
			current := s.sid == t.sid
			hov := hovered(row)
			if hov do fill_rect(vg, row, HOVER_BG, 8)
			dot := [Agent_Kind]nvg.Color{.Claude = {0.85, 0.47, 0.34, 1}, .Codex = {0.6, 0.62, 0.66, 1}, .Gemini = {0.27, 0.55, 1, 1}}
			nvg.BeginPath(vg)
			nvg.Circle(vg, row.x + 12, row.y + 14, 4)
			nvg.FillColor(vg, dot[s.agent])
			nvg.Fill(vg)
			nvg.Save(vg)
			nvg.IntersectScissor(vg, row.x + 24, row.y, row.w - 120, row.h)
			label(vg, row.x + 24, row.y + 13, s.title if s.title != "" else "Untitled session", TEXT_FG, 13)
			nvg.Restore(vg)
			label(vg, row.x + 24, row.y + 30, fmt.tprintf("%s · %s", AGENT_KIND_NAMES[s.agent], short_date(s.time)), TEXT_DIM, 11)
			if current {
				label(vg, row.x + row.w - 12, row.y + 20, "Current", ACCENT, 11, false, .RIGHT)
			} else if hov {
				rb := Rect{row.x + row.w - 84, row.y + 7, 76, 26}
				fill_rect(vg, rb, {0.95, 0.95, 0.96, 1}, 7)
				label(vg, rb.x + rb.w / 2, rb.y + 13, "Resume", {0.1, 0.1, 0.1, 1}, 12, false, .CENTER)
			}
			if clicked(row) && !current && !t.running {
				agent_session_resume(t, s.sid)
				agent_ui.ses_open = false
				nvg.Restore(vg)
				return
			}
			ry += 44
		}
		nvg.Restore(vg)
	}
}

// What goes with the next request, above the input: the attached context and the marks.
@(private = "file")
draw_chips :: proc(vg: ^nvg.Context, t: ^Agent_Thread, input: Rect) -> (top: f32) {
	agent_ui.chips = {}
	top = input.y
	n := annotations_count()
	if len(t.attached) == 0 && n == 0 do return
	h: f32 = 26
	y := input.y - 8 - h
	x := input.x + 16
	remove := -1
	// more than three: one chip that says how many
	if len(t.attached) > 3 {
		folders, files := 0, 0
		for c in t.attached do if c.folder do folders += 1
		else do files += 1
		parts := make([dynamic]string, context.temp_allocator)
		if folders > 0 do append(&parts, fmt.tprintf("%d folder%s", folders, "" if folders == 1 else "s"))
		if files > 0 do append(&parts, fmt.tprintf("%d file%s", files, "" if files == 1 else "s"))
		text := strings.join(parts[:], " · ", context.temp_allocator)
		cw := text_width(vg, text, 12) + 36
		cr := Rect{x, y, cw, h}
		fill_rect(vg, cr, {0.2, 0.2, 0.22, 0.95}, h / 2)
		draw_lucide(vg, "paperclip", cr.x + 14, cr.y + h / 2, 12, TEXT_FG, 1.6)
		label(vg, cr.x + 26, cr.y + h / 2, text, TEXT_FG, 12)
		if clicked(cr) do agent_ui.ctx_open = true
		x += cw + 6
	} else {
		for c, i in t.attached {
			name := fs_base(c.path)
			cw := text_width(vg, name, 12) + 52
			cr := Rect{x, y, cw, h}
			fill_rect(vg, cr, {0.12, 0.22, 0.36, 0.95} if c.folder else {0.2, 0.2, 0.22, 0.95}, h / 2)
			draw_lucide(vg, "folder" if c.folder else "file-text", cr.x + 14, cr.y + h / 2, 12, {0.55, 0.75, 1, 1} if c.folder else TEXT_FG, 1.6)
			label(vg, cr.x + 26, cr.y + h / 2, name, TEXT_FG, 12)
			xr := Rect{cr.x + cw - 22, cr.y + 4, 18, 18}
			if lucide_button(vg, xr, "x", tip = c.path) do remove = i
			x += cw + 6
		}
	}
	if n > 0 {
		text := fmt.tprintf("%d mark%s", n, "" if n == 1 else "s")
		cw := text_width(vg, text, 12) + 52
		cr := Rect{x, y, cw, h}
		fill_rect(vg, cr, {0.36, 0.12, 0.2, 0.95}, h / 2)
		draw_lucide(vg, "pencil", cr.x + 14, cr.y + h / 2, 12, {1, 0.5, 0.65, 1}, 1.6)
		label(vg, cr.x + 26, cr.y + h / 2, text, TEXT_FG, 12)
		xr := Rect{cr.x + cw - 22, cr.y + 4, 18, 18}
		if lucide_button(vg, xr, "x", tip = "Clear marks") do annotations_clear()
		x += cw + 6
	}
	if remove >= 0 do agent_context_remove(t, remove)
	agent_ui.chips = {input.x, y, x - input.x, h}
	return y
}

// The marks toolbar (agent-context.pen frame 5), above the chips.
@(private = "file")
draw_marks_toolbar :: proc(vg: ^nvg.Context, bottom: f32) -> (top: f32) {
	agent_ui.toolbar = {}
	top = bottom
	if !annotations_active() do return
	BW :: f32(30)
	tools_w: f32 = 0
	for tool in Mark_Tool do tools_w += text_width(vg, MARK_TOOL_NAMES[tool], 12) + 40
	clear_w := text_width(vg, "Clear marks", 12) + 40
	w := tools_w + 3 * 22 + 16 + clear_w + 64 + 24
	r := Rect{(app.screen.x - w) / 2, bottom - 8 - 40, w, 40}
	agent_ui.toolbar = r
	float_surface(vg, r, 12)
	x := r.x + 6
	for tool in Mark_Tool {
		tw := text_width(vg, MARK_TOOL_NAMES[tool], 12) + 40
		b := Rect{x, r.y + 5, tw - 4, 30}
		on := annot.tool == tool
		if on do fill_rect(vg, b, ACTIVE_BG, 7)
		else if hovered(b) do fill_rect(vg, b, HOVER_BG, 7)
		draw_lucide(vg, MARK_TOOL_ICONS[tool], b.x + 14, b.y + 15, 13, TEXT_FG if on else TEXT_DIM, 1.6)
		label(vg, b.x + 26, b.y + 15, MARK_TOOL_NAMES[tool], TEXT_FG if on else TEXT_DIM, 12)
		if clicked(b) do annot.tool = tool
		x += tw
	}
	x += 6
	for c, i in MARK_COLORS {
		cr := Rect{x, r.y + 11, 18, 18}
		nvg.BeginPath(vg)
		nvg.Circle(vg, cr.x + 9, cr.y + 9, 7)
		nvg.FillColor(vg, c)
		nvg.Fill(vg)
		if annot.color == i {
			nvg.BeginPath(vg)
			nvg.Circle(vg, cr.x + 9, cr.y + 9, 9)
			nvg.StrokeColor(vg, {1, 1, 1, 0.9})
			nvg.StrokeWidth(vg, 1.5)
			nvg.Stroke(vg)
		}
		if clicked(cr) do annot.color = i
		x += 22
	}
	x += 10
	cb := Rect{x, r.y + 5, clear_w - 4, 30}
	if hovered(cb) do fill_rect(vg, cb, HOVER_BG, 7)
	draw_lucide(vg, "eraser", cb.x + 14, cb.y + 15, 13, TEXT_DIM, 1.6)
	label(vg, cb.x + 26, cb.y + 15, "Clear marks", TEXT_DIM, 12)
	if clicked(cb) do annotations_clear()
	db := Rect{r.x + r.w - 6 - 60, r.y + 5, 60, 30}
	fill_rect(vg, db, {0.95, 0.95, 0.96, 1}, 7)
	label(vg, db.x + 30, db.y + 15, "Done", {0.1, 0.1, 0.1, 1}, 12, true, .CENTER)
	if clicked(db) do annot.active = false
	// a reminder at the top of the canvas
	note := "Marks are for the agent only. They are not saved in the file."
	nw := text_width(vg, note, 12) + 44
	nr := Rect{(app.screen.x - nw) / 2, TAB_H + 14, nw, 28}
	fill_rect(vg, nr, {1, 0.3, 0.5, 0.95}, 8)
	draw_lucide(vg, "pencil", nr.x + 16, nr.y + 14, 12, {1, 1, 1, 1}, 1.6)
	label(vg, nr.x + 30, nr.y + 14, note, {1, 1, 1, 1}, 12)
	return r.y
}

// The context popover (agent-context.pen frame 1), above the paperclip.
// `left` >= 0 places it there with `width` (the agent's panel), else centred on the anchor.
draw_context_popover :: proc(vg: ^nvg.Context, t: ^Agent_Thread, anchor: Rect, left := f32(-1), width := f32(400)) {
	if !agent_ui.ctx_open do return
	w := width
	rows := len(t.attached)
	h := 44 + 2 * 50 + (f32(rows) * 50 + 30 if rows > 0 else 0) + 52
	r := Rect{clamp(anchor.x + anchor.w / 2 - w / 2, 12, app.screen.x - w - 12), anchor.y - 10 - h, w, h}
	if left >= 0 {
		r.x = left
		r.y = panel_ui.composer.y - 10 - h
	}
	agent_ui.popover = r
	if agent_mode() do panel_ui.popover = r
	float_surface(vg, r, 12)
	label(vg, r.x + 16, r.y + 22, "Context", TEXT_FG, 13, true)
	label(vg, r.x + r.w - 16, r.y + 22, fmt.tprintf("for %s", fs_base(t.key)) if t.key != "" else "for the Dashboard", TEXT_DIM, 11, false, .RIGHT)
	y := r.y + 44
	Add :: struct {
		icon, name, hint: string,
		folder:           bool,
	}
	adds := [2]Add{{"folder-plus", "Add folder…", "A code repo or docs. The agent can read and search it.", true}, {"file-plus", "Add files…", ".md, images and other .pen files", false}}
	for a in adds {
		row := Rect{r.x + 8, y, r.w - 16, 46}
		if hovered(row) do fill_rect(vg, row, HOVER_BG, 8)
		draw_lucide(vg, a.icon, row.x + 18, row.y + 23, 15, TEXT_DIM, 1.6)
		label(vg, row.x + 36, row.y + 16, a.name, TEXT_FG, 13)
		label(vg, row.x + 36, row.y + 33, a.hint, TEXT_DIM, 11)
		if clicked(row) {
			for p in ask_context_paths(a.folder) do agent_context_add(t, p, a.folder)
		}
		y += 50
	}
	remove := -1
	if rows > 0 {
		label(vg, r.x + 16, y + 14, fmt.tprintf("ATTACHED · %d", rows), TEXT_DIM, 10, true)
		y += 30
		for c, i in t.attached {
			row := Rect{r.x + 8, y, r.w - 16, 46}
			if hovered(row) do fill_rect(vg, row, HOVER_BG, 8)
			draw_lucide(vg, "folder" if c.folder else "file-text", row.x + 18, row.y + 23, 15, {0.55, 0.75, 1, 1} if c.folder else TEXT_DIM, 1.6)
			nvg.Save(vg)
			nvg.IntersectScissor(vg, row.x + 36, row.y, row.w - 76, row.h)
			label(vg, row.x + 36, row.y + 16, fs_base(c.path), TEXT_FG, 13)
			label(vg, row.x + 36, row.y + 33, short_dir(fs_dir(c.path)), TEXT_DIM, 11)
			nvg.Restore(vg)
			if lucide_button(vg, {row.x + row.w - 34, row.y + 10, 26, 26}, "x", tip = "Remove") do remove = i
			y += 50
		}
	}
	draw_lucide(vg, "clock", r.x + 22, y + 24, 12, TEXT_DIM, 1.6)
	note := fmt.tprintf("Remembered for this file: reopen %s and these are selected again. Nothing is copied into the .pen.", fs_base(t.key)) if t.key != "" else "Used for designs started from the Dashboard."
	wrap_text(vg, r.x + 38, y + 14, r.w - 54, note, 11, TEXT_DIM)
	if remove >= 0 do agent_context_remove(t, remove)
	// a click elsewhere closes it
	if mouse_pressed(MOUSE_BUTTON_LEFT) && !in_rect(r, app.mouse) && !in_rect(anchor, app.mouse) && !(left >= 0 && in_rect(panel_ui.composer, app.mouse)) do agent_ui.ctx_open = false
	if key_pressed(KEY_ESCAPE) do agent_ui.ctx_open = false
}

@(private = "file")
round_button :: proc(vg: ^nvg.Context, r: Rect, icon: string, on: bool, tip: string) -> bool {
	fill_rect(vg, r, ACCENT if on else ({1, 1, 1, 0.1} if hovered(r) else {1, 1, 1, 0.05}), r.h / 2)
	draw_lucide(vg, icon, r.x + r.w / 2, r.y + r.h / 2, 15, {1, 1, 1, 1} if on else TEXT_FG, 1.6)
	if hovered(r) do tooltip_request(tip, r)
	return clicked(r)
}

// ⌘L anywhere: the agent's field (in a file, Agent mode).
agent_focus_keys :: proc() {
	if ui_modal() || !mod_cmd() || !key_pressed(KEY_L) || field_is_focused(0, "agent.prompt") do return
	if app.tab >= 0 do set_editor_mode(.Agent)
	field_focus(0, "agent.prompt", agent_state.draft)
}

// The Dashboard's agent input (a file's is in its Agent mode, agent_panel.odin).
draw_agent_input :: proc(vg: ^nvg.Context) {
	if app.tab >= 0 do return
	if pf.quiet && fs_env("AGENTIC_AGENT_INPUT", context.temp_allocator) == "" do return // test windows: only when asked
	r := input_rect()
	t := agent_current()
	agent_ui.popover = {}
	if t.running do agent_ui.ctx_open = false
	// above the input, from the bottom up: chips, the marks toolbar, the thread
	top := draw_chips(vg, t, r)
	top = draw_marks_toolbar(vg, top)
	draw_thread(vg, t, top)

	// the pill
	popup_shadow(vg, r, r.h / 2)
	fill_rect(vg, r, {0.16, 0.16, 0.17, 1}, r.h / 2)
	focused := field_is_focused(0, "agent.prompt")
	stroke_rect(vg, r, ACCENT if focused else {1, 1, 1, 0.12}, r.h / 2)

	// right side: context, marks, the agent, then Send or Stop
	send := Rect{r.x + r.w - 8 - 36, r.y + 8, 36, 36}
	name := AGENT_KIND_NAMES[agent_state.choice]
	pw := text_width(vg, name, 12) + 44
	pick := Rect{send.x - 8 - pw, r.y + 10, pw, 32}
	pen := Rect{pick.x - 8 - 32, r.y + 10, 32, 32}
	clip := Rect{pen.x - 6 - 32, r.y + 10, 32, 32}
	if app.tab < 0 do clip = Rect{pick.x - 8 - 32, r.y + 10, 32, 32} // no canvas to mark on the dashboard
	if round_button(vg, clip, "paperclip", agent_ui.ctx_open, "Context for the agent") {
		agent_ui.ctx_open = !agent_ui.ctx_open
		agent_ui.ses_open = false
	}
	if n := len(t.attached); n > 0 {
		nvg.BeginPath(vg)
		nvg.Circle(vg, clip.x + clip.w - 4, clip.y + 5, 7)
		nvg.FillColor(vg, ACCENT)
		nvg.Fill(vg)
		label(vg, clip.x + clip.w - 4, clip.y + 5, fmt.tprintf("%d", n), {1, 1, 1, 1}, 9, true, .CENTER)
	}
	if app.tab >= 0 && round_button(vg, pen, "pencil", annot.active, "Mark things for the agent") {
		annot.active = !annot.active
		if annot.active do agent_ui.ctx_open = false
	}
	if hovered(pick) do fill_rect(vg, pick, {1, 1, 1, 0.1}, 16)
	else do fill_rect(vg, pick, {1, 1, 1, 0.05}, 16)
	dots := [Agent_Kind]nvg.Color{.Claude = {0.85, 0.47, 0.34, 1}, .Codex = {0.6, 0.62, 0.66, 1}, .Gemini = {0.27, 0.55, 1, 1}}
	nvg.BeginPath(vg)
	nvg.Circle(vg, pick.x + 14, pick.y + 16, 5)
	nvg.FillColor(vg, dots[agent_state.choice])
	nvg.Fill(vg)
	label(vg, pick.x + 26, pick.y + 16, name, TEXT_FG, 12)
	draw_icon(vg, .Chevron_Down, pick.x + pick.w - 12, pick.y + 16, TEXT_DIM, 10)
	if clicked(pick) {
		items := make([]string, len(Agent_Kind), context.temp_allocator)
		for k in Agent_Kind do items[int(k)] = AGENT_KIND_NAMES[k] if agent_available(k) else fmt.tprintf("%s (not installed)", AGENT_KIND_NAMES[k])
		menu_open("agent.pick", pick, items, int(agent_state.choice))
	}
	if p, ok := menu_take("agent.pick"); ok && p >= 0 && p < len(Agent_Kind) do agent_choose(Agent_Kind(p))

	running := t.running
	nvg.BeginPath(vg)
	nvg.Circle(vg, send.x + 18, send.y + 18, 18)
	empty := strings.trim_space(agent_state.draft) == ""
	nvg.FillColor(vg, {0.95, 0.95, 0.96, 1} if running || !empty else {1, 1, 1, 0.25})
	nvg.Fill(vg)
	if running {
		fill_rect(vg, {send.x + 12, send.y + 12, 12, 12}, {0.1, 0.1, 0.1, 1}, 2)
		if hovered(send) do tooltip_request("Stop  ⌘.", send)
	} else {
		draw_lucide(vg, "arrow-up", send.x + 18, send.y + 18, 16, {0.1, 0.1, 0.1, 1}, 2)
	}
	if clicked(send) {
		if running do agent_stop(t)
		else {
			agent_send(agent_state.draft)
			agent_draft_clear()
		}
	}

	// the field
	placeholder: string
	if app.tab < 0 {
		placeholder = "Ask an agent to make a design…"
	} else if annotations_count() > 0 {
		placeholder = fmt.tprintf("Tell %s about your marks…", name)
	} else if len(app.sel) == 1 {
		n, _ := engine.doc_find_uid(&app.doc, app.sel[0])
		placeholder = fmt.tprintf("Ask %s to change %s…", name, n.name if n != nil && n.name != "" else "the selection")
	} else {
		placeholder = fmt.tprintf("Ask %s to change this design…", name)
	}
	if !agent_available(agent_state.choice) do placeholder = fmt.tprintf("Install %s to ask it here, or connect another agent (Settings → Agents)", name)
	fr := Rect{r.x + 18, r.y + 8, clip.x - 8 - (r.x + 18), r.h - 16}
	if focused && (key_pressed(KEY_ENTER) || key_pressed(KEY_KP_ENTER)) && !mod_shift() {
		text := strings.clone(strings.to_string(ui.buf), context.temp_allocator)
		ui.focus = ""
		agent_send(text)
		agent_draft_clear()
	} else {
		field(vg, 0, "agent.prompt", "", fr, agent_state.draft, placeholder = placeholder, bare = true)
		if field_is_focused(0, "agent.prompt") {
			s := strings.to_string(ui.buf)
			if s != agent_state.draft {
				delete(agent_state.draft)
				agent_state.draft = strings.clone(s)
			}
		}
	}
	draw_context_popover(vg, t, clip)
	chat_dashboard_end(vg, agent_ui.panel)
	// ⌘L focuses the field, ⌘. stops the run
	if !ui_modal() && mod_cmd() {
		if key_pressed(KEY_PERIOD) && running do agent_stop(t)
	}
	// a finished run's panel comes back when the input gets the focus
	if focused && !t.shown && (len(t.items) > 0 || len(t.sessions) > 0) do t.shown = true
}

agent_draft_clear :: proc() {
	delete(agent_state.draft)
	agent_state.draft = ""
}

@(private = "file")
wrap_width :: proc(vg: ^nvg.Context, text: string, size: f32) -> f32 {
	nvg.FontFace(vg, "ui")
	nvg.FontSize(vg, size)
	return nvg.TextBounds(vg, 0, 0, text)
}
