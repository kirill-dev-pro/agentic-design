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
	for side in Panel_Side {
		if panel_shown(side) {
			if in_rect(panel_rect(side), p) do return true
		} else if in_rect(corner_button_rect(side), p) do return true
	}
	return in_rect(toolbar_rect(), p)
}

// The pointer is on the canvas itself (not on a panel, the tool bar or the tab bar).
canvas_hit :: proc(p: [2]f32) -> bool {
	return in_rect(app.canvas, p) && !chrome_hit(p)
}

// The part of the canvas the panels leave open: zoom to fit and the view's centre use it.
canvas_visible :: proc() -> Rect {
	c := app.canvas
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
