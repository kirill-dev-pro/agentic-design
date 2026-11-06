package agentic_design

import nvg "nanovg"

// The editor's chrome floats over the canvas (app-ui.pen, "Editor · panels open" and
// "Editor · panels hidden"): the layers panel at the top left, the inspector at the top
// right, the tools in a bar at the bottom. Each panel hides with the button in its header;
// a hidden panel leaves a small button in its corner of the canvas, which shows where the
// panel opens while the pointer is on it. ⌘\ hides or shows both.
//
// The panels' contents are drawn as before, in panel coordinates: panel_begin moves the
// drawing and the pointer by the panel's offset (ui.origin), and the widgets that keep a
// rect for later (menus, the color picker, tooltips, the focused field) add it back.

PANEL_MARGIN :: f32(10)
PANEL_RADIUS :: f32(12)
CORNER_BUTTON :: f32(36)
TOOLBAR_H :: f32(44)
TOOLBAR_BUTTON :: f32(32)

// Design or Agent (app-ui.pen "1 · Context popover" … "7 · Thread"): in Agent the floating
// panels and the tools give way to the agent's panel at the left (agent_panel.odin) and the
// marks bar at the bottom of the canvas.
Editor_Mode :: enum {
	Design,
	Agent,
}

editor_mode: Editor_Mode

// The Agent panel's width: 400 by default, dragged between 320 and half the window.
agent_side_w :: proc() -> f32 {
	w := settings.agent_panel_w if settings.agent_panel_w > 0 else 400
	return clamp(w, 320, max(320, min(760, app.screen.x * 0.5)))
}

agent_mode :: proc() -> bool {
	return editor_mode == .Agent && app.tab >= 0
}

// Where the canvas is: under the tab bar, right of the agent's panel in Agent mode.
canvas_rect :: proc() -> Rect {
	left := agent_side_w() if agent_mode() else 0
	return {left, TAB_H, app.screen.x - left, app.screen.y - TAB_H}
}

// Switches mode keeping the view's centre where it is.
set_editor_mode :: proc(m: Editor_Mode) {
	if editor_mode == m do return
	if ui.focus != "" do field_commit()
	centre := to_page(canvas_center())
	editor_mode = m
	app.canvas = canvas_rect()
	app.cam = centre - (canvas_center() - [2]f32{app.canvas.x, app.canvas.y}) / app.zoom
	if m == .Design do annot_leave_agent_mode()
}

Panel_Side :: enum {
	Left,
	Right,
}

panel_shown :: proc(side: Panel_Side) -> bool {
	return !settings.hide_layers if side == .Left else !settings.hide_inspector
}

panel_toggle :: proc(side: Panel_Side) {
	if side == .Left do settings.hide_layers = !settings.hide_layers
	else do settings.hide_inspector = !settings.hide_inspector
	settings_save()
}

// ⌘\: both hide when any is shown, else both show.
panels_toggle_all :: proc() {
	hide := panel_shown(.Left) || panel_shown(.Right)
	settings.hide_layers, settings.hide_inspector = hide, hide
	settings_save()
}

// The panel's rect on screen. Its height follows its content (last frame's), up to the
// space above the tool bar.
panel_rect :: proc(side: Panel_Side) -> Rect {
	top := TAB_H + PANEL_MARGIN
	avail := app.screen.y - top - PANEL_MARGIN
	content := ui.side_full_h if side == .Left else ui.insp_full_h
	h := clamp(content, 120, avail) if content > 0 else avail
	if side == .Left do return {PANEL_MARGIN, top, LEFT_W, h}
	return {app.screen.x - PANEL_MARGIN - RIGHT_W, top, RIGHT_W, h}
}

corner_button_rect :: proc(side: Panel_Side) -> Rect {
	top := TAB_H + PANEL_MARGIN
	if side == .Left do return {PANEL_MARGIN, top, CORNER_BUTTON, CORNER_BUTTON}
	return {app.screen.x - PANEL_MARGIN - CORNER_BUTTON, top, CORNER_BUTTON, CORNER_BUTTON}
}

TOOLBAR_TOOLS :: 9 // the drawing tools and Place image
toolbar_rect :: proc() -> Rect {
	w := f32(TOOLBAR_TOOLS + 1) * (TOOLBAR_BUTTON + 4) + 4 + 9
	return {(app.screen.x - w) / 2, app.screen.y - PANEL_MARGIN - 6 - TOOLBAR_H, w, TOOLBAR_H}
}

// True when p is on the editor's floating chrome rather than the canvas.
chrome_hit :: proc(p: [2]f32) -> bool {
	if app.tab < 0 do return false
	if agent_mode() do return agent_chrome_hit(p)
	for side in Panel_Side {
		if panel_shown(side) {
			if in_rect(panel_rect(side), p) do return true
		} else if in_rect(corner_button_rect(side), p) do return true
	}
	return in_rect(toolbar_rect(), p) || agent_chrome_hit(p)
}

// The pointer is on the canvas itself (not on a panel, the tool bar or the tab bar).
canvas_hit :: proc(p: [2]f32) -> bool {
	return in_rect(app.canvas, p) && !chrome_hit(p)
}

// The part of the canvas the panels leave open: zoom to fit and the view's centre use it.
canvas_visible :: proc() -> Rect {
	c := app.canvas
	if agent_mode() do return c
	l := c.x
	r := c.x + c.w
	if app.tab >= 0 && panel_shown(.Left) do l = PANEL_MARGIN + LEFT_W
	if app.tab >= 0 && panel_shown(.Right) do r = app.screen.x - PANEL_MARGIN - RIGHT_W
	if r - l < 200 do l, r = c.x, c.x + c.w
	return {l, c.y, r - l, c.h}
}

canvas_center :: proc() -> [2]f32 {
	v := canvas_visible()
	return {v.x + v.w / 2, v.y + v.h / 2}
}

// A floating surface: shadow, rounded fill and a hairline edge.
float_surface :: proc(vg: ^nvg.Context, r: Rect, radius: f32 = PANEL_RADIUS) {
	popup_shadow(vg, r, radius)
	fill_rect(vg, r, PANEL_BG, radius)
	stroke_rect(vg, r, PANEL_LINE, radius)
}

// Draws the panel's surface and moves drawing and the pointer so that the panel's content
// can be drawn at `at` (the place it had when the panels were docked).
panel_begin :: proc(vg: ^nvg.Context, r: Rect, at: [2]f32) {
	float_surface(vg, r)
	off := [2]f32{r.x, r.y} - at
	nvg.Save(vg)
	nvg.Translate(vg, off.x, off.y)
	ui.origin = off
	app.mouse -= off
}

panel_end :: proc(vg: ^nvg.Context) {
	app.mouse += ui.origin
	ui.origin = {}
	nvg.Restore(vg)
}

// The button in a panel's header that hides it (drawn in panel coordinates).
panel_hide_button :: proc(vg: ^nvg.Context, r: Rect, side: Panel_Side) {
	tip := "Hide layers  ⌘\\" if side == .Left else "Hide inspector  ⌘\\"
	if icon_button(vg, r, .Panel_Left if side == .Left else .Panel_Right, tip = tip) do panel_toggle(side)
}

// The corner buttons of hidden panels, with an outline of where the panel opens while the
// pointer is on one.
draw_corner_buttons :: proc(vg: ^nvg.Context) {
	for side in Panel_Side {
		if panel_shown(side) do continue
		b := corner_button_rect(side)
		if hovered(b) {
			p := panel_rect(side)
			fill_rect(vg, p, {ACCENT.r, ACCENT.g, ACCENT.b, 0.08}, PANEL_RADIUS)
			stroke_rect(vg, p, {ACCENT.r, ACCENT.g, ACCENT.b, 0.55}, PANEL_RADIUS)
		}
		float_surface(vg, b, 9)
		tip := "Show layers  ⌘\\" if side == .Left else "Show inspector  ⌘\\"
		if icon_button(vg, {b.x + 4, b.y + 4, b.w - 8, b.h - 8}, .Panel_Left if side == .Left else .Panel_Right, tip = tip) do panel_toggle(side)
	}
}

// ---------------------------------------------------------------- interface size

UI_SCALES := [4]f32{0.9, 1, 1.15, 1.3}

ui_scale :: proc() -> f32 {
	s := settings.ui_scale
	return s if s >= UI_SCALES[0] && s <= UI_SCALES[len(UI_SCALES) - 1] else 1
}

// The page point at the view's centre while the interface size changes: the next frame
// (with the new window units) puts it back there, at the same real zoom.
ui_rescale_center: Maybe([2]f32)

ui_scale_set :: proc(s: f32) {
	if s == ui_scale() do return
	if app.tab >= 0 {
		ui_rescale_center = to_page(canvas_center())
		app.zoom *= ui_scale() / s // the canvas keeps its zoom in real pixels
	}
	settings.ui_scale = s
	settings_save()
	set_status("Interface size %d%%", int(s * 100 + 0.5))
}

// ⌘⌥+ and ⌘⌥- step through the sizes; ⌘⌥0 goes back to 100%.
ui_scale_step :: proc(dir: int) {
	if dir == 0 {
		ui_scale_set(1)
		return
	}
	i := 1
	for s, k in UI_SCALES do if abs(s - ui_scale()) < 0.01 do i = k
	ui_scale_set(UI_SCALES[clamp(i + dir, 0, len(UI_SCALES) - 1)])
}

// The canvas's zoom in real pixels: what the zoom menu shows and sets (app.zoom is in the
// window's units, which the interface size makes larger).
view_zoom :: proc() -> f32 {
	return app.zoom * ui_scale()
}

// The interface-size shortcuts, on the dashboard and in the editor; true when one acted.
ui_scale_keys :: proc() -> bool {
	if !mod_cmd() || !(key_down(KEY_LEFT_ALT) || key_down(KEY_RIGHT_ALT)) do return false
	switch {
	case key_hit(KEY_EQUAL): ui_scale_step(1)
	case key_hit(KEY_MINUS): ui_scale_step(-1)
	case key_pressed(KEY_0): ui_scale_step(0)
	case: return false
	}
	return true
}
