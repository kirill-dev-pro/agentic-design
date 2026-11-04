#+build !js
package agentic_design

import "engine"

import "core:fmt"
import "core:strings"
import "core:time"
import nvg "nanovg"

// The agent input (app-ui.pen, component "Agent input"): a rounded field at the bottom
// centre of the canvas and of the dashboard, the agent to ask at its right and Send (Stop
// while it works). Above it, the thread: the user's requests, what the agent says, the
// tools it called and how the run ended (agent_run.odin runs it). ⌘L focuses the field.

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

panel_rect_cache: Rect // the thread panel as last drawn (input and chrome tests)

// Room the dashboard keeps free at the bottom of its list.
agent_input_reserve :: proc() -> f32 {
	return AGENT_INPUT_H + 40
}

// The pointer is on the input or its thread panel (not the canvas).
agent_chrome_hit :: proc(p: [2]f32) -> bool {
	if in_rect(input_rect(), p) do return true
	t := agent_current()
	return t.shown && len(t.items) > 0 && in_rect(panel_rect_cache, p)
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

@(private = "file")
item_text :: proc(it: Run_Item) -> string {
	if it.kind != .Tool do return it.text
	verb := tool_verb(it.text)
	return verb if it.count == 1 else fmt.tprintf("%s ×%d", verb, it.count)
}

@(private = "file")
draw_thread :: proc(vg: ^nvg.Context, t: ^Agent_Thread, input: Rect) {
	panel_rect_cache = {}
	if !t.shown || len(t.items) == 0 do return
	w := min(AGENT_PANEL_W, input.w)
	inner := w - 32
	// heights of the items, newest last
	heights := make([]f32, len(t.items), context.temp_allocator)
	content: f32 = 0
	for it, i in t.items {
		h: f32
		switch it.kind {
		case .User: h = wrap_height(vg, inner - 20, it.text, 13) + 16
		case .Text, .Error: h = wrap_height(vg, inner, it.text, 13) + 8
		case .Tool: h = 22
		}
		heights[i] = h
		content += h + 6
	}
	status_h: f32 = 34
	h := min(content + status_h + 20, AGENT_PANEL_MAX_H)
	r := Rect{(app.screen.x - w) / 2, input.y - 10 - h, w, h}
	panel_rect_cache = r
	float_surface(vg, r, 14)

	// the list scrolls; it follows the newest item unless scrolled up
	area := Rect{r.x, r.y + 10, r.w, r.h - status_h - 14}
	max_scroll := max(content - area.h, 0)
	t.scroll = clamp(t.scroll - wheel_over(area), 0, max_scroll)
	nvg.Save(vg)
	nvg.IntersectScissor(vg, area.x, area.y, area.w, area.h)
	y := area.y + area.h - content + t.scroll
	x := r.x + 16
	for it, i in t.items {
		hh := heights[i]
		if y + hh >= area.y && y <= area.y + area.h {
			switch it.kind {
			case .User:
				bw := min(wrap_width(vg, it.text, 13) + 20, inner)
				b := Rect{r.x + r.w - 16 - bw, y, bw, hh}
				fill_rect(vg, b, {1, 1, 1, 0.08}, 10)
				wrap_text(vg, b.x + 10, y + 8, bw - 20, it.text, 13, TEXT_FG)
			case .Text:
				wrap_text(vg, x, y + 4, inner, it.text, 13, TEXT_FG)
			case .Error:
				wrap_text(vg, x, y + 4, inner, it.text, 13, {1, 0.5, 0.45, 1})
			case .Tool:
				draw_lucide(vg, "wrench", x + 7, y + 11, 12, TEXT_DIM, 1.6)
				label(vg, x + 20, y + 11, item_text(it), TEXT_DIM, 12)
			}
		}
		y += hh + 6
	}
	nvg.Restore(vg)

	// status line: state, time, tools; Stop or Undo; hide
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

@(private = "file")
wrap_width :: proc(vg: ^nvg.Context, text: string, size: f32) -> f32 {
	nvg.FontFace(vg, "ui")
	nvg.FontSize(vg, size)
	return nvg.TextBounds(vg, 0, 0, text)
}

draw_agent_input :: proc(vg: ^nvg.Context) {
	if pf.quiet && fs_env("AGENTIC_AGENT_INPUT", context.temp_allocator) == "" do return // test windows: only when asked
	r := input_rect()
	t := agent_current()
	draw_thread(vg, t, r)

	// the pill
	popup_shadow(vg, r, r.h / 2)
	fill_rect(vg, r, {0.16, 0.16, 0.17, 1}, r.h / 2)
	focused := field_is_focused(0, "agent.prompt")
	stroke_rect(vg, r, ACCENT if focused else {1, 1, 1, 0.12}, r.h / 2)
	draw_lucide(vg, "sparkles", r.x + 26, r.y + r.h / 2, 16, {0.85, 0.47, 0.34, 1}, 1.6)

	// right side: the agent, then Send or Stop
	send := Rect{r.x + r.w - 8 - 36, r.y + 8, 36, 36}
	name := AGENT_KIND_NAMES[agent_state.choice]
	pw := text_width(vg, name, 12) + 44
	pick := Rect{send.x - 8 - pw, r.y + 10, pw, 32}
	if hovered(pick) do fill_rect(vg, pick, {1, 1, 1, 0.1}, 16)
	else do fill_rect(vg, pick, {1, 1, 1, 0.05}, 16)
	nvg.BeginPath(vg)
	nvg.Circle(vg, pick.x + 14, pick.y + 16, 5)
	nvg.FillColor(vg, {0.85, 0.47, 0.34, 1} if agent_state.choice == .Claude else {0.6, 0.62, 0.66, 1})
	nvg.Fill(vg)
	label(vg, pick.x + 26, pick.y + 16, name, TEXT_FG, 12)
	draw_icon(vg, .Chevron_Down, pick.x + pick.w - 12, pick.y + 16, TEXT_DIM, 10)
	if clicked(pick) {
		items := make([]string, len(Agent_Kind), context.temp_allocator)
		for k in Agent_Kind do items[int(k)] = AGENT_KIND_NAMES[k] if agent_available(k) else fmt.tprintf("%s (not installed)", AGENT_KIND_NAMES[k])
		menu_open("agent.pick", pick, items, int(agent_state.choice))
	}
	if p, ok := menu_take("agent.pick"); ok && p >= 0 && p < len(Agent_Kind) do agent_state.choice = Agent_Kind(p)

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
	} else if len(app.sel) == 1 {
		n, _ := engine.doc_find_uid(&app.doc, app.sel[0])
		placeholder = fmt.tprintf("Ask %s to change %s…", name, n.name if n != nil && n.name != "" else "the selection")
	} else {
		placeholder = fmt.tprintf("Ask %s to change this design…", name)
	}
	if !agent_available(agent_state.choice) do placeholder = fmt.tprintf("Install %s to ask it here, or connect another agent (Settings → Agents)", name)
	fr := Rect{r.x + 46, r.y + 8, pick.x - 8 - (r.x + 46), r.h - 16}
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
	// ⌘L focuses the field, ⌘. stops the run
	if !ui_modal() && mod_cmd() {
		if key_pressed(KEY_L) && !focused do field_focus(0, "agent.prompt", agent_state.draft)
		if key_pressed(KEY_PERIOD) && running do agent_stop(t)
	}
	// a finished run's panel comes back when the input gets the focus
	if focused && !t.shown && len(t.items) > 0 do t.shown = true
}

agent_draft_clear :: proc() {
	delete(agent_state.draft)
	agent_state.draft = ""
}
