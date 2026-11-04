package agentic_design

import "engine"

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import nvg "nanovg"

// A small immediate-mode widget library drawn with NanoVG, in the dark style of the
// rest of the window. Widgets are plain procedures called every frame; the little state
// they need (focus, open menu, drags) lives in `ui`. Overlays (menus, the color picker,
// dialogs, tooltips) are drawn last by widgets_end_frame.
//
//   button, icon_button, checkbox, dropdown / dropdown_menu, slider, field (text and
//   numbers), menus, color_picker, dialog, tooltip, scrollbar, section, divider, chip.

UI :: struct {
	// text fields
	focus:         string, // key of the focused field ("" = none)
	focus_owned:   string, // storage behind `focus` when it was cloned
	focus_uid:     int, // node the field belongs to; 0 = app setting
	focus_rect:    Rect,
	buf:           strings.Builder, // text being edited
	caret:         int, // byte offset in buf
	sel:           int, // selection anchor (byte offset) or -1
	drag_select:   bool,
	input_claimed: bool, // the focused field already consumed this frame's typing
	field_count:   int, // fields drawn this frame, for Tab order
	tab_target:    int, // index of the field to focus next frame, -1 = none
	scrub:         string, // key of the number field being scrubbed by dragging
	scrub_uid:     int,
	scrub_x:       f32,
	scrub_value:   f32,
	scrub_moved:   bool,
	cursor_hint:   Cursor, // cursor a widget asked for this frame
	// overlays
	menu:          Menu,
	picker:        Picker,
	dialog:        Dialog,
	tooltip:       string,
	tooltip_rect:  Rect,
	hover_tip:     string,
	hover_since:   time.Time,
	// generic
	overlay_pass:  bool, // drawing menus/pickers/dialogs: their widgets may take input
	status_rect:   Rect, // the toast with a "Show in Finder" button, while shown
	clip:          Rect, // clicks only count inside this area while it is set
	slider:        string, // key of the slider being dragged
	scrollbar:     string, // key of the scrollbar being dragged
	scrollbar_off: f32,
	icons:         map[Icon][dynamic]engine.Path_Cmd,
	// application panels
	expanded:       map[int]bool, // layer tree rows that show their children
	theme_tab:      bool, // sidebar shows variables instead of layers
	side_tab:       int, // sidebar: 0 design (pages, layers), 1 components, 2 theme
	layer_drag:     struct {
		uid:    int, // layer pressed in the tree (0 = none)
		start:  [2]f32,
		active: bool,
	},
	comp_search:    string,
	layer_search:   string,
	export_format:  int,
	// the gradient being edited: its node, fill index, selected stop, a stop being dragged
	grad:           struct {
		uid, fill, stop: int,
		dragging:        bool,
	},
	pages_shut:     bool,
	files:          [dynamic]string, // .pen files next to the open one
	files_time:     time.Time,
	files_dir:      string,
	last_sel:       int, // first selected uid last frame, to auto-expand its ancestors
	show_grid:      bool,
	rename_canvas:  bool, // the "name" field is shown on the canvas title
	rename_tree:    bool, // ... or in the layer tree
	tree_click:     time.Time, // for double clicks in the tree
	tree_click_uid: int,
	insp_scroll:    f32,
	insp_h:         f32, // content height of the inspector last frame
	side_h:         f32,
	pad_all:        bool, // padding shown as four sides
	radius_corners: bool, // corner radius shown as four corners
	export_scale:   int, // index into EXPORT_SCALES
	// floating panels (panels.odin): the offset of the panel being drawn, and each panel's
	// full height last frame (its header and content), which its height follows
	origin:         [2]f32,
	side_full_h:    f32,
	insp_full_h:    f32,
}

ui: UI

// Call before drawing any widget in a frame.
widgets_begin_frame :: proc() {
	ui.input_claimed = false
	ui.field_count = 0
	ui.cursor_hint = .Default
	if ui.tooltip != "" {
		delete(ui.tooltip)
		ui.tooltip = ""
	}
}

// Draws the overlays; call after everything else.
widgets_end_frame :: proc(vg: ^nvg.Context) {
	if ui.tab_target >= ui.field_count do ui.tab_target = 0 if ui.field_count > 0 else -1
	if ui.tab_target < -1 do ui.tab_target = ui.field_count - 1
	ui.overlay_pass = true
	ui.clip = {}
	draw_picker(vg)
	draw_menu(vg)
	draw_dialog(vg)
	ui.overlay_pass = false
	draw_tooltip(vg)
	if !mouse_down(MOUSE_BUTTON_LEFT) {
		ui.scrub = ""
		ui.drag_select = false
		ui.scrollbar = ""
	}
}

// True while an overlay owns the pointer and keyboard.
ui_modal :: proc() -> bool {
	return ui.menu.open || ui.picker.open || ui.dialog.open || onboarding.open || vtable.open || settings_open || shortcuts_open || whats_new.open || share_open
}

// ---------------------------------------------------------------- primitives

label :: proc(vg: ^nvg.Context, x, y: f32, text: string, color := TEXT_FG, size: f32 = 12, bold := false, align := nvg.AlignHorizontal.LEFT) {
	nvg.FontFace(vg, "ui")
	nvg.FontSize(vg, size)
	nvg.TextAlign(vg, align, .MIDDLE)
	nvg.FillColor(vg, color)
	nvg.Text(vg, x, y, text)
}

text_width :: proc(vg: ^nvg.Context, text: string, size: f32 = 12) -> f32 {
	nvg.FontFace(vg, "ui")
	nvg.FontSize(vg, size)
	return nvg.TextBounds(vg, 0, 0, text)
}

fill_rect :: proc(vg: ^nvg.Context, r: Rect, color: nvg.Color, radius: f32 = 0) {
	nvg.BeginPath(vg)
	if radius > 0 do nvg.RoundedRect(vg, r.x, r.y, r.w, r.h, radius)
	else do nvg.Rect(vg, r.x, r.y, r.w, r.h)
	nvg.FillColor(vg, color)
	nvg.Fill(vg)
}

stroke_rect :: proc(vg: ^nvg.Context, r: Rect, color: nvg.Color, radius: f32 = 0, width: f32 = 1) {
	nvg.BeginPath(vg)
	nvg.RoundedRect(vg, r.x + 0.5, r.y + 0.5, r.w - 1, r.h - 1, radius)
	nvg.StrokeColor(vg, color)
	nvg.StrokeWidth(vg, width)
	nvg.Stroke(vg)
}

// A soft drop shadow under a popup.
popup_shadow :: proc(vg: ^nvg.Context, r: Rect, radius: f32) {
	nvg.BeginPath(vg)
	nvg.Rect(vg, r.x - 20, r.y - 16, r.w + 40, r.h + 44)
	nvg.RoundedRect(vg, r.x, r.y, r.w, r.h, radius)
	nvg.PathWinding(vg, .CW)
	nvg.FillPaint(vg, nvg.BoxGradient(r.x, r.y + 4, r.w, r.h, radius, 18, nvg.Color{0, 0, 0, 0.45}, nvg.Color{0, 0, 0, 0}))
	nvg.Fill(vg)
}

// Pointer tests ignore everything under an open overlay, except while the overlay
// itself is being drawn (overlay_pass).
hovered :: proc(r: Rect) -> bool {
	if ui_modal() && !ui.overlay_pass do return false
	if ui.clip.w > 0 && !in_rect(ui.clip, app.mouse) do return false
	return in_rect(r, app.mouse)
}

// Scroll distance (content pixels, positive = down) for a scrollable area under the
// pointer. Like `hovered`, only the topmost layer gets it: while a menu, picker or
// dialog is open, the panels below do not scroll.
wheel_over :: proc(r: Rect) -> f32 {
	if !hovered(r) do return 0
	return pf.wheel.y * 30 + pf.scroll.y
}

clicked :: proc(r: Rect) -> bool {
	if ui_modal() && !ui.overlay_pass do return false
	if ui.clip.w > 0 && !in_rect(ui.clip, app.mouse) do return false
	return mouse_pressed(MOUSE_BUTTON_LEFT) && in_rect(r, app.mouse)
}

// Column i of n equal columns inside r.
cols :: proc(r: Rect, n: int, gap: f32, i: int) -> Rect {
	w := (r.w - gap * f32(n - 1)) / f32(n)
	return {r.x + f32(i) * (w + gap), r.y, w, r.h}
}

// ---------------------------------------------------------------- icons

Icon :: enum {
	Select,
	Hand,
	Frame,
	Rect,
	Ellipse,
	Text,
	Path,
	Group,
	Component,
	Other,
	Plus,
	Chevron_Right,
	Chevron_Down,
	File,
	Grid,
	Check,
	Pencil,
	Row,
	Column,
	Arrow_Down,
	Arrow_Right,
	X,
	Eye,
	Eye_Off,
	Minus,
	Gap,
	Pad_V,
	Pad_H,
	Expand,
	Opacity,
	Blend,
	Stroke_Width,
	Font_Size,
	Align_Left,
	Align_Center,
	Align_Right,
	Align_Top,
	Align_Middle,
	Align_Bottom,
	Distribute_H,
	Distribute_V,
	Image,
	More,
	Search,
	Pen,
	Connector,
	Panel_Left,
	Panel_Right,
}

// 24×24 outlines; only M/L/C/Q/Z commands so the SVG parser handles them.
ICON_PATHS := [Icon]string {
	.Select        = "M5 3 L19 12 L12.5 13.5 L16 20.5 L13.5 21.5 L10 14.5 L5 19 Z",
	.Hand          = "M8 13 V5.5 C8 4.7 8.7 4 9.5 4 C10.3 4 11 4.7 11 5.5 V12 M11 12 V4 C11 3.2 11.7 2.5 12.5 2.5 C13.3 2.5 14 3.2 14 4 V12 M14 12 V5.5 C14 4.7 14.7 4 15.5 4 C16.3 4 17 4.7 17 5.5 V14.5 M17 9.5 C17 8.7 17.7 8 18.5 8 C19.3 8 20 8.7 20 9.5 V15 C20 18.9 16.9 22 13 22 H11.5 C9.3 22 7.3 20.9 6 19 L3.5 15.2 C3 14.4 3.3 13.4 4 13 C4.7 12.6 5.6 12.8 6.1 13.5 L8 16 V13",
	.Frame         = "M22 6 H2 M22 18 H2 M6 2 V22 M18 2 V22",
	.Rect          = "M4 6 C4 4.9 4.9 4 6 4 H18 C19.1 4 20 4.9 20 6 V18 C20 19.1 19.1 20 18 20 H6 C4.9 20 4 19.1 4 18 Z",
	.Ellipse       = "M12 4 C16.4 4 20 7.6 20 12 C20 16.4 16.4 20 12 20 C7.6 20 4 16.4 4 12 C4 7.6 7.6 4 12 4 Z",
	.Text          = "M5 5 H19 M12 5 V19 M9 19 H15",
	.Path          = "M4 20 C4 11 11 4 20 4 M4 20 L8 16 M20 4 L16 8",
	.Group         = "M4 4 H8 M16 4 H20 M4 20 H8 M16 20 H20 M4 4 V8 M4 16 V20 M20 4 V8 M20 16 V20",
	.Component     = "M12 3 L16 7 L12 11 L8 7 Z M12 13 L16 17 L12 21 L8 17 Z M3 12 L7 8 L11 12 L7 16 Z M21 12 L17 8 L13 12 L17 16 Z",
	.Other         = "M12 4 C16.4 4 20 7.6 20 12 C20 16.4 16.4 20 12 20 C7.6 20 4 16.4 4 12 C4 7.6 7.6 4 12 4 Z M12 16 V16.5 M9.5 9.5 C9.5 8 10.6 7 12 7 C13.4 7 14.5 8 14.5 9.5 C14.5 11.5 12 11.5 12 13.5",
	.Plus          = "M12 5 V19 M5 12 H19",
	.Chevron_Right = "M9 6 L15 12 L9 18",
	.Chevron_Down  = "M6 9 L12 15 L18 9",
	.File          = "M14 2 H6 C5 2 4 3 4 4 V20 C4 21 5 22 6 22 H18 C19 22 20 21 20 20 V8 Z M14 2 V8 H20",
	.Grid          = "M3 3 H10 V10 H3 Z M14 3 H21 V10 H14 Z M14 14 H21 V21 H14 Z M3 14 H10 V21 H3 Z",
	.Check         = "M20 6 L9 17 L4 12",
	.Pencil        = "M17 3 L21 7 L8 20 L3 21 L4 16 Z M14 6 L18 10",
	.Row           = "M5 5 V19 M12 5 V19 M19 5 V19",
	.Column        = "M5 5 H19 M5 12 H19 M5 19 H19",
	.Arrow_Down    = "M12 4 V20 M6 14 L12 20 L18 14",
	.Arrow_Right   = "M4 12 H20 M14 6 L20 12 L14 18",
	.X             = "M6 6 L18 18 M18 6 L6 18",
	.Eye           = "M2 12 C5 6 19 6 22 12 C19 18 5 18 2 12 Z M12 9 C13.7 9 15 10.3 15 12 C15 13.7 13.7 15 12 15 C10.3 15 9 13.7 9 12 C9 10.3 10.3 9 12 9 Z",
	.Eye_Off       = "M2 12 C5 6 19 6 22 12 C19 18 5 18 2 12 Z M4 4 L20 20",
	.Minus         = "M5 12 H19",
	.Gap           = "M4 4 V20 M20 4 V20 M9 12 H15 M9 12 L11 10 M9 12 L11 14 M15 12 L13 10 M15 12 L13 14",
	.Pad_V         = "M3 4 H21 M3 20 H21 M8 9 H16 V15 H8 Z",
	.Pad_H         = "M4 3 V21 M20 3 V21 M9 8 H15 V16 H9 Z",
	.Expand        = "M3 9 V3 H9 M15 3 H21 V9 M21 15 V21 H15 M9 21 H3 V15",
	.Opacity       = "M12 3 C12 3 5 10 5 15 C5 19 8 21 12 21 C16 21 19 19 19 15 C19 10 12 3 12 3 Z M12 21 V3",
	.Blend         = "M9 3 C12.3 3 15 5.7 15 9 C15 12.3 12.3 15 9 15 C5.7 15 3 12.3 3 9 C3 5.7 5.7 3 9 3 Z M15 9 C18.3 9 21 11.7 21 15 C21 18.3 18.3 21 15 21 C11.7 21 9 18.3 9 15",
	.Stroke_Width  = "M4 6 H20 M4 11 H20 M4 17 H20",
	.Font_Size     = "M4 20 L10 5 L16 20 M6.5 14 H13.5 M17 20 L19.5 13 L22 20 M18 18 H21",
	.Align_Left    = "M4 6 H20 M4 12 H13 M4 18 H17",
	.Align_Center  = "M4 6 H20 M7.5 12 H16.5 M5.5 18 H18.5",
	.Align_Right   = "M4 6 H20 M11 12 H20 M7 18 H20",
	.Align_Top     = "M4 4 H20 M8 8 V20 M14 8 V15",
	.Align_Middle  = "M4 12 H20 M8 6 V18 M14 8 V16",
	.Align_Bottom  = "M4 20 H20 M8 4 V16 M14 9 V16",
	.Distribute_H  = "M4 4 V20 M20 4 V20 M9 8 H15 V16 H9 Z",
	.Distribute_V  = "M4 4 H20 M4 20 H20 M8 9 H16 V15 H8 Z",
	.Image         = "M5 3 H19 C20.1 3 21 3.9 21 5 V19 C21 20.1 20.1 21 19 21 H5 C3.9 21 3 20.1 3 19 V5 C3 3.9 3.9 3 5 3 Z M3 16 L8 11 L13 16 L16 13 L21 18 M15 8 C15 8.6 15.4 9 16 9 C16.6 9 17 8.6 17 8 C17 7.4 16.6 7 16 7 C15.4 7 15 7.4 15 8 Z",
	.More          = "M5 12 C5 11.4 5.4 11 6 11 C6.6 11 7 11.4 7 12 C7 12.6 6.6 13 6 13 C5.4 13 5 12.6 5 12 Z M11 12 C11 11.4 11.4 11 12 11 C12.6 11 13 11.4 13 12 C13 12.6 12.6 13 12 13 C11.4 13 11 12.6 11 12 Z M17 12 C17 11.4 17.4 11 18 11 C18.6 11 19 11.4 19 12 C19 12.6 18.6 13 18 13 C17.4 13 17 12.6 17 12 Z",
	.Search        = "M11 4 C14.9 4 18 7.1 18 11 C18 14.9 14.9 18 11 18 C7.1 18 4 14.9 4 11 C4 7.1 7.1 4 11 4 Z M16 16 L20.5 20.5",
	.Connector     = "M5 4 C6.1 4 7 4.9 7 6 C7 7.1 6.1 8 5 8 C3.9 8 3 7.1 3 6 C3 4.9 3.9 4 5 4 Z M7 6 H13 V18 H19 M16 15 L19 18 L16 21",
	.Panel_Left    = "M5 3 H19 C20.1 3 21 3.9 21 5 V19 C21 20.1 20.1 21 19 21 H5 C3.9 21 3 20.1 3 19 V5 C3 3.9 3.9 3 5 3 Z M9 3 V21",
	.Panel_Right   = "M5 3 H19 C20.1 3 21 3.9 21 5 V19 C21 20.1 20.1 21 19 21 H5 C3.9 21 3 20.1 3 19 V5 C3 3.9 3.9 3 5 3 Z M15 3 V21",
	.Pen           = "M12 19 L19 12 L22 15 L15 22 Z M18 13 L16.5 5.5 L2 2 L5.5 16.5 L13 18 Z M2 2 L9.6 9.6 M11 13 C12.1 13 13 12.1 13 11 C13 9.9 12.1 9 11 9 C9.9 9 9 9.9 9 11 C9 12.1 9.9 13 11 13 Z",
}

draw_icon :: proc(vg: ^nvg.Context, icon: Icon, cx, cy: f32, color: nvg.Color, size: f32 = 16) {
	cmds, cached := ui.icons[icon]
	if !cached {
		cmds, _, _ = engine.parse_svg_path(ICON_PATHS[icon])
		ui.icons[icon] = cmds
	}
	nvg.Save(vg)
	nvg.Translate(vg, cx - size / 2, cy - size / 2)
	nvg.Scale(vg, size / 24, size / 24)
	nvg.BeginPath(vg)
	for c in cmds {
		switch c.kind {
		case .Move: nvg.MoveTo(vg, c.p[2].x, c.p[2].y)
		case .Line: nvg.LineTo(vg, c.p[2].x, c.p[2].y)
		case .Cubic: nvg.BezierTo(vg, c.p[0].x, c.p[0].y, c.p[1].x, c.p[1].y, c.p[2].x, c.p[2].y)
		case .Quad: nvg.QuadTo(vg, c.p[0].x, c.p[0].y, c.p[1].x, c.p[1].y)
		case .Close: nvg.ClosePath(vg)
		}
	}
	if icon == .Select || icon == .More {
		nvg.FillColor(vg, color)
		nvg.Fill(vg)
	} else {
		nvg.StrokeColor(vg, color)
		nvg.StrokeWidth(vg, 2)
		nvg.LineCap(vg, .ROUND)
		nvg.LineJoin(vg, .ROUND)
		nvg.Stroke(vg)
	}
	nvg.Restore(vg)
}

// ---------------------------------------------------------------- buttons

// A text button; `active` renders it pressed.
button :: proc(vg: ^nvg.Context, r: Rect, text: string, active := false, size: f32 = 12, primary := false) -> bool {
	hover := hovered(r)
	bg := ACTIVE_BG if active else (nvg.Color{1, 1, 1, 0.1} if hover else FIELD_BG)
	if primary do bg = nvg.Color{ACCENT.r, ACCENT.g, ACCENT.b, 0.85 if hover else 1}
	fill_rect(vg, r, bg, 6)
	label(vg, r.x + r.w / 2, r.y + r.h / 2, text, TEXT_FG, size, false, .CENTER)
	return clicked(r)
}

icon_button :: proc(vg: ^nvg.Context, r: Rect, icon: Icon, active := false, tip := "") -> bool {
	hover := hovered(r)
	if active do fill_rect(vg, r, ACTIVE_BG, 7)
	else if hover do fill_rect(vg, r, HOVER_BG, 7)
	draw_icon(vg, icon, r.x + r.w / 2, r.y + r.h / 2, TEXT_FG if active || hover else TEXT_DIM)
	if hover && tip != "" do tooltip_request(tip, r)
	return clicked(r)
}

checkbox :: proc(vg: ^nvg.Context, r: Rect, text: string, on: bool) -> bool {
	box := Rect{r.x, r.y + 3, 16, 16}
	fill_rect(vg, box, ACCENT if on else FIELD_BG, 4)
	if !on do stroke_rect(vg, box, {1, 1, 1, 0.2}, 4)
	if on do draw_icon(vg, .Check, box.x + 8, box.y + 8, {1, 1, 1, 1}, 11)
	label(vg, r.x + 24, r.y + 11, text, TEXT_FG)
	return clicked(r)
}

// A button that looks like a dropdown; use dropdown_menu for the whole thing.
dropdown :: proc(vg: ^nvg.Context, r: Rect, text: string) -> bool {
	hover := hovered(r)
	fill_rect(vg, r, nvg.Color{1, 1, 1, 0.1} if hover else FIELD_BG, 6)
	nvg.Save(vg)
	nvg.IntersectScissor(vg, r.x, r.y, r.w - 22, r.h)
	label(vg, r.x + 10, r.y + r.h / 2, text, TEXT_FG)
	nvg.Restore(vg)
	draw_icon(vg, .Chevron_Down, r.x + r.w - 12, r.y + r.h / 2, TEXT_DIM, 11)
	return clicked(r)
}

// A dropdown bound to a menu of `items`; returns the newly picked index.
dropdown_menu :: proc(vg: ^nvg.Context, key: string, r: Rect, items: []string, current: int) -> (int, bool) {
	if dropdown(vg, r, items[current] if current >= 0 && current < len(items) else "") do menu_open(key, r, items, current)
	return menu_take(key)
}

// Horizontal slider; returns the dragged value while the pointer is held.
slider :: proc(vg: ^nvg.Context, key: string, r: Rect, value, lo, hi: f32) -> (v: f32, changed: bool) {
	v = value
	track := Rect{r.x, r.y + r.h / 2 - 2, r.w, 4}
	fill_rect(vg, track, {1, 1, 1, 0.15}, 2)
	t := clamp((value - lo) / max(hi - lo, 0.001), 0, 1)
	fill_rect(vg, {track.x, track.y, track.w * t, track.h}, TEXT_DIM, 2)
	kx := track.x + track.w * t
	nvg.BeginPath(vg)
	nvg.Circle(vg, kx, r.y + r.h / 2, 7)
	nvg.FillColor(vg, TEXT_FG)
	nvg.Fill(vg)
	if ui.slider == "" && clicked({r.x - 8, r.y - 4, r.w + 16, r.h + 8}) {
		ui.slider = key
		push_undo()
	}
	if ui.slider == key {
		if mouse_down(MOUSE_BUTTON_LEFT) {
			v = lo + clamp((app.mouse.x - track.x) / track.w, 0, 1) * (hi - lo)
			changed = v != value
		} else {
			ui.slider = ""
		}
	}
	return
}

chip :: proc(vg: ^nvg.Context, x, y: f32, text: string, variable: bool) {
	shown := text[1:] if variable && len(text) > 1 else text
	tw := text_width(vg, shown, 12) + 12
	if variable do fill_rect(vg, {x, y, tw, 18}, {1, 1, 1, 0.1}, 4)
	label(vg, x + 6, y + 9, shown, TEXT_FG, 12)
}

divider :: proc(vg: ^nvg.Context, x, w: f32, y: ^f32) {
	y^ += 4
	fill_rect(vg, {x, y^, w, 1}, PANEL_LINE)
	y^ += 12
}

section :: proc(vg: ^nvg.Context, x: f32, y: ^f32, title: string, trailing := "") {
	label(vg, x, y^ + 8, title, TEXT_FG, 13)
	if trailing != "" do label(vg, x + RIGHT_W - 32, y^ + 8, trailing, TEXT_DIM, 11, false, .RIGHT)
	y^ += 30
}

// Section header with a "+" (add) or "−" (remove) at the right; returns true on click.
section_toggle :: proc(vg: ^nvg.Context, x: f32, y: ^f32, title: string, present: bool) -> bool {
	label(vg, x, y^ + 8, title, TEXT_FG if present else TEXT_DIM, 13)
	r := Rect{x + RIGHT_W - 32 - 24, y^ - 4, 24, 24}
	hit := icon_button(vg, r, .Minus if present else .Plus, tip = "Remove" if present else "Add")
	y^ += 30
	return hit
}

// A thin scrollbar on the right edge of `area`; returns the (possibly dragged) offset.
scrollbar :: proc(vg: ^nvg.Context, key: string, area: Rect, content_h, scroll: f32) -> f32 {
	if content_h <= area.h do return 0
	s := clamp(scroll, 0, content_h - area.h)
	track := Rect{area.x + area.w - 8, area.y + 2, 4, area.h - 4}
	th := max(track.h * area.h / content_h, 24)
	ty := track.y + (track.h - th) * (s / (content_h - area.h))
	thumb := Rect{track.x, ty, 4, th}
	hot := hovered({thumb.x - 6, thumb.y, 16, thumb.h}) || ui.scrollbar == key
	fill_rect(vg, thumb, {1, 1, 1, 0.35 if hot else 0.18}, 2)
	if ui.scrollbar == "" && clicked({thumb.x - 6, thumb.y, 16, thumb.h}) {
		ui.scrollbar = key
		ui.scrollbar_off = app.mouse.y - ty
	}
	if ui.scrollbar == key && mouse_down(MOUSE_BUTTON_LEFT) {
		frac := clamp((app.mouse.y - ui.scrollbar_off - track.y) / max(track.h - th, 1), 0, 1)
		s = frac * (content_h - area.h)
	}
	return s
}

// ---------------------------------------------------------------- text fields

// Gives a field the focus with its whole text selected.
field_focus :: proc(uid: int, key, value: string) {
	if ui.focus != "" do field_commit()
	// keys are often built with tprintf: keep our own copy
	delete(ui.focus_owned)
	ui.focus_owned = strings.clone(key)
	ui.focus = ui.focus_owned
	ui.focus_uid = uid
	strings.builder_reset(&ui.buf)
	strings.write_string(&ui.buf, value)
	ui.caret = len(value)
	ui.sel = 0
	ui.drag_select = false
}

field_is_focused :: proc(uid: int, key: string) -> bool {
	return ui.focus == key && ui.focus_uid == uid
}

// A text field bound to a node property (uid > 0) or an app setting (uid = 0);
// commits on Enter, Tab or click-away. `plain` draws it without a box. Numeric
// fields can be scrubbed by dragging their icon/prefix and stepped with ↑/↓.
field :: proc(vg: ^nvg.Context, uid: int, key, prefix: string, r: Rect, value: string, plain := false, placeholder := "", icon := Icon.Select, numeric := false) {
	index := ui.field_count
	ui.field_count += 1
	focused := field_is_focused(uid, key)
	hover := hovered(r)
	if !focused && ui.tab_target == index {
		ui.tab_target = -1
		field_focus(uid, key, value)
		focused = true
	}
	if !plain || focused || hover {
		fill_rect(vg, r, nvg.Color{1, 1, 1, 0.1} if focused || hover else FIELD_BG, 6)
	}
	if focused do stroke_rect(vg, r, ACCENT, 6)

	// prefix / icon zone (also the scrub handle for numbers)
	tx := r.x + 10
	grip := Rect{r.x, r.y, 0, r.h}
	if icon != .Select {
		draw_icon(vg, icon, tx + 6, r.y + r.h / 2, TEXT_DIM, 13)
		tx += 22
		grip.w = 28
	} else if prefix != "" {
		label(vg, tx, r.y + r.h / 2, prefix, TEXT_DIM)
		tx += 18 if len(prefix) <= 2 else 32
		grip.w = tx - r.x
	}
	if numeric && grip.w > 0 {
		if hovered(grip) || ui.scrub == key do ui.cursor_hint = .Resize_H
		if ui.scrub == "" && clicked(grip) {
			if f, ok := strconv.parse_f32(strings.trim_space(value)); ok {
				ui.scrub = strings.clone(key)
				ui.scrub_uid = uid
				ui.scrub_x = app.mouse.x
				ui.scrub_value = f
				ui.scrub_moved = false
			}
		}
		if ui.scrub == key && ui.scrub_uid == uid && mouse_down(MOUSE_BUTTON_LEFT) {
			step: f32 = 10 if mod_shift() else (0.1 if key_down(KEY_LEFT_ALT) else 1)
			d := math.round((app.mouse.x - ui.scrub_x) / 2) * step
			if d != 0 || ui.scrub_moved {
				if !ui.scrub_moved do push_undo()
				ui.scrub_moved = true
				if !focused do field_focus(uid, key, value)
				strings.builder_reset(&ui.buf)
				strings.write_string(&ui.buf, engine.num_text(ui.scrub_value + d))
				ui.caret, ui.sel = strings.builder_len(ui.buf), 0
				field_apply()
			}
			focused = true
		}
	}

	// text, selection and caret
	shown := strings.to_string(ui.buf) if focused else value
	if focused {
		ui.caret = clamp(ui.caret, 0, len(shown))
		if ui.sel > len(shown) do ui.sel = len(shown)
	}
	inner_w := r.w - (tx - r.x) - 8
	offset: f32
	caret_x: f32
	if focused {
		nvg.FontFace(vg, "ui")
		nvg.FontSize(vg, 12)
		caret_x = nvg.TextBounds(vg, 0, 0, shown[:clamp(ui.caret, 0, len(shown))])
		if caret_x > inner_w do offset = caret_x - inner_w
	}
	nvg.Save(vg)
	nvg.IntersectScissor(vg, tx - 2, r.y, inner_w + 4, r.h)
	if focused && ui.sel >= 0 && ui.sel != ui.caret {
		a, b := min(ui.sel, ui.caret), max(ui.sel, ui.caret)
		ax := nvg.TextBounds(vg, 0, 0, shown[:clamp(a, 0, len(shown))])
		bx := nvg.TextBounds(vg, 0, 0, shown[:clamp(b, 0, len(shown))])
		fill_rect(vg, {tx + ax - offset, r.y + 6, bx - ax, r.h - 12}, {ACCENT.r, ACCENT.g, ACCENT.b, 0.35}, 2)
	}
	if shown == "" && !focused do label(vg, tx, r.y + r.h / 2, placeholder, TEXT_DIM)
	else do label(vg, tx - offset, r.y + r.h / 2, shown)
	if focused && (ui.sel < 0 || ui.sel == ui.caret) && (int(time.now()._nsec / 500_000_000) % 2 == 0 || ui.drag_select) {
		fill_rect(vg, {tx + caret_x - offset, r.y + 7, 1.5, r.h - 14}, TEXT_FG)
	}
	nvg.Restore(vg)

	// mouse: focus with everything selected; inside a focused field place or drag the caret
	text_zone := Rect{tx - 2, r.y, r.w - (tx - r.x) + 2, r.h}
	if !focused {
		if clicked(r) && !(numeric && in_rect(grip, app.mouse)) {
			field_focus(uid, key, value)
			ui.focus_rect = {r.x + ui.origin.x, r.y + ui.origin.y, r.w, r.h}
		}
		return
	}
	ui.focus_rect = {r.x + ui.origin.x, r.y + ui.origin.y, r.w, r.h} // on screen: handle_input tests it
	if hovered(text_zone) do ui.cursor_hint = .IBeam
	if clicked(text_zone) {
		double := time.duration_seconds(time.since(app.last_click)) < 0.35 && abs(app.mouse.x - app.last_click_p.x) < 4
		app.last_click, app.last_click_p = time.now(), app.mouse
		if double {
			ui.sel, ui.caret = 0, len(shown)
		} else {
			ui.caret = caret_from_x(vg, shown, app.mouse.x - tx + offset)
			ui.sel = ui.caret
			ui.drag_select = true
		}
	}
	if ui.drag_select && mouse_down(MOUSE_BUTTON_LEFT) {
		ui.caret = caret_from_x(vg, shown, app.mouse.x - tx + offset)
	}

	if ui.input_claimed do return
	ui.input_claimed = true
	field_keys(index, numeric)
}

// Byte offset of the glyph boundary nearest to a local x.
caret_from_x :: proc(vg: ^nvg.Context, text: string, x: f32) -> int {
	if len(text) == 0 do return 0
	nvg.FontFace(vg, "ui")
	nvg.FontSize(vg, 12)
	positions := make([]nvg.Glyph_Position, len(text), context.temp_allocator)
	n := nvg.TextGlyphPositions(vg, 0, 0, text, &positions)
	best, best_d := len(text), abs(x - nvg.TextBounds(vg, 0, 0, text))
	for p in positions[:n] {
		if d := abs(x - p.minx); d < best_d do best, best_d = p.str, d
	}
	return best
}

// Keyboard handling for the focused field.
field_keys :: proc(index: int, numeric: bool) {
	b := &ui.buf
	text := strings.to_string(b^)
	ui.caret = clamp(ui.caret, 0, len(text))
	if ui.sel > len(text) do ui.sel = len(text)
	cmd := mod_cmd()
	shift := mod_shift()
	has_sel := ui.sel >= 0 && ui.sel != ui.caret
	replace_selection :: proc(with: string) {
		text := strings.to_string(ui.buf)
		a, b := min(ui.sel, ui.caret), max(ui.sel, ui.caret)
		if ui.sel < 0 do a, b = ui.caret, ui.caret
		out := strings.builder_make(context.temp_allocator)
		strings.write_string(&out, text[:clamp(a, 0, len(text))])
		strings.write_string(&out, with)
		strings.write_string(&out, text[clamp(b, 0, len(text)):])
		strings.builder_reset(&ui.buf)
		strings.write_string(&ui.buf, strings.to_string(out))
		ui.caret = a + len(with)
		ui.sel = -1
	}
	prev_rune :: proc(text: string, at: int) -> int {
		if at <= 0 do return 0
		_, size := utf8.decode_last_rune_in_string(text[:at])
		return at - size
	}
	next_rune :: proc(text: string, at: int) -> int {
		if at >= len(text) do return len(text)
		_, size := utf8.decode_rune_in_string(text[at:])
		return at + size
	}

	if cmd {
		switch {
		case key_pressed(KEY_A):
			ui.sel, ui.caret = 0, len(text)
		case key_pressed(KEY_C), key_pressed(KEY_X):
			if has_sel {
				a, bb := min(ui.sel, ui.caret), max(ui.sel, ui.caret)
				platform_clipboard_set(text[a:bb])
				if key_pressed(KEY_X) do replace_selection("")
			}
		case key_pressed(KEY_V):
			paste := platform_clipboard_get()
			replace_selection(strings.trim_space(paste) if numeric else paste)
		case key_hit(KEY_LEFT):
			if !shift do ui.sel = -1
			else if ui.sel < 0 do ui.sel = ui.caret
			ui.caret = 0
		case key_hit(KEY_RIGHT):
			if !shift do ui.sel = -1
			else if ui.sel < 0 do ui.sel = ui.caret
			ui.caret = len(text)
		}
		return
	}
	for ch in pf.chars {
		enc, n := utf8.encode_rune(ch)
		replace_selection(string(enc[:n]))
		text = strings.to_string(b^)
	}
	if key_hit(KEY_BACKSPACE) {
		if has_sel do replace_selection("")
		else if ui.caret > 0 {
			ui.sel = prev_rune(text, ui.caret)
			replace_selection("")
		}
	}
	if key_hit(KEY_DELETE) {
		if has_sel do replace_selection("")
		else if ui.caret < len(text) {
			ui.sel = next_rune(text, ui.caret)
			replace_selection("")
		}
	}
	if key_hit(KEY_LEFT) {
		if shift {
			if ui.sel < 0 do ui.sel = ui.caret
			ui.caret = prev_rune(text, ui.caret)
		} else if has_sel {
			ui.caret = min(ui.sel, ui.caret)
			ui.sel = -1
		} else {
			ui.caret = prev_rune(text, ui.caret)
			ui.sel = -1
		}
	}
	if key_hit(KEY_RIGHT) {
		if shift {
			if ui.sel < 0 do ui.sel = ui.caret
			ui.caret = next_rune(text, ui.caret)
		} else if has_sel {
			ui.caret = max(ui.sel, ui.caret)
			ui.sel = -1
		} else {
			ui.caret = next_rune(text, ui.caret)
			ui.sel = -1
		}
	}
	if key_hit(KEY_HOME) {
		if !shift do ui.sel = -1
		else if ui.sel < 0 do ui.sel = ui.caret
		ui.caret = 0
	}
	if key_hit(KEY_END) {
		if !shift do ui.sel = -1
		else if ui.sel < 0 do ui.sel = ui.caret
		ui.caret = len(text)
	}
	if numeric && (key_hit(KEY_UP) || key_hit(KEY_DOWN)) {
		if f, ok := strconv.parse_f32(strings.trim_space(text)); ok {
			step: f32 = 10 if shift else 1
			if key_hit(KEY_DOWN) do step = -step
			strings.builder_reset(b)
			strings.write_string(b, engine.num_text(f + step))
			ui.caret, ui.sel = strings.builder_len(b^), 0
			push_undo()
			field_apply()
		}
	}
	switch {
	case key_pressed(KEY_ENTER), key_pressed(KEY_KP_ENTER):
		field_commit()
	case key_pressed(KEY_TAB):
		field_commit()
		ui.tab_target = index - 1 if shift else index + 1
	case key_pressed(KEY_ESCAPE):
		ui.focus = ""
	}
}

// ---------------------------------------------------------------- menus

// Items: "-" is a separator, "Label\tShortcut" shows a right-aligned hint.
Menu :: struct {
	open:        bool,
	key:         string,
	anchor:      Rect,
	items:       [dynamic]string,
	checked:     int,
	hover:       int,
	scroll:      f32,
	searchable:  bool, // a filter box at the top; typing narrows the list
	font_preview: bool, // draw each item in the font family it names
	filter:      strings.Builder,
	visible:     [dynamic]int, // indices of items passing the filter
	just_opened: bool,
	result_key:  string,
	result:      int,
	has_result:  bool,
}

MENU_ROW :: f32(26)
MENU_SEP :: f32(9)
MENU_SEARCH :: f32(36)

menu_open :: proc(key: string, anchor: Rect, items: []string, checked := -1, searchable := false, font_preview := false) {
	menu_close()
	ui.menu.open = true
	ui.menu.key = strings.clone(key)
	ui.menu.anchor = anchor
	ui.menu.anchor.x += ui.origin.x
	ui.menu.anchor.y += ui.origin.y
	for it in items do append(&ui.menu.items, strings.clone(it))
	ui.menu.checked = checked
	ui.menu.hover = checked
	ui.menu.scroll = 0
	ui.menu.searchable = searchable
	ui.menu.font_preview = font_preview
	strings.builder_reset(&ui.menu.filter)
	ui.menu.just_opened = true
	menu_filter()
}

// Recomputes which items pass the search text.
menu_filter :: proc() {
	m := &ui.menu
	clear(&m.visible)
	needle := strings.to_lower(strings.to_string(m.filter), context.temp_allocator)
	// items starting with the text first, then the ones merely containing it
	for it, i in m.items {
		if needle == "" || strings.has_prefix(strings.to_lower(it, context.temp_allocator), needle) do append(&m.visible, i)
	}
	if needle != "" do for it, i in m.items {
		low := strings.to_lower(it, context.temp_allocator)
		if !strings.has_prefix(low, needle) && strings.contains(low, needle) do append(&m.visible, i)
	}
	if m.hover >= 0 {
		found := false
		for v in m.visible do if v == m.hover do found = true
		if !found do m.hover = m.visible[0] if len(m.visible) > 0 else -1
	}
}

menu_close :: proc() {
	for it in ui.menu.items do delete(it)
	clear(&ui.menu.items)
	delete(ui.menu.key)
	ui.menu.key = ""
	ui.menu.open = false
}

// The item picked from the menu with this key, once.
menu_take :: proc(key: string) -> (int, bool) {
	if ui.menu.has_result && ui.menu.result_key == key {
		ui.menu.has_result = false
		return ui.menu.result, true
	}
	return -1, false
}

menu_item_h :: proc(item: string) -> f32 {
	return MENU_SEP if item == "-" else MENU_ROW
}

menu_rect :: proc(vg: ^nvg.Context) -> (r: Rect, content_h: f32) {
	w: f32 = ui.menu.anchor.w
	for it in ui.menu.items {
		lbl, hint := menu_split(it)
		tw := text_width(vg, lbl, 12) + 40
		if hint != "" do tw += text_width(vg, hint, 11) + 16
		w = max(w, tw)
	}
	for vi in ui.menu.visible do content_h += menu_item_h(ui.menu.items[vi])
	content_h += 8
	if ui.menu.searchable do content_h += MENU_SEARCH
	h := content_h
	avail_down := app.screen.y - 8 - (ui.menu.anchor.y + ui.menu.anchor.h + 4)
	y := ui.menu.anchor.y + ui.menu.anchor.h + 4
	if h > avail_down {
		avail_up := ui.menu.anchor.y - 12
		if avail_up > avail_down {
			h = min(h, avail_up)
			y = ui.menu.anchor.y - h - 4
		} else {
			h = avail_down
		}
	}
	x := clamp(ui.menu.anchor.x, 8, max(app.screen.x - w - 8, 8))
	return {x, y, w, h}, content_h
}

menu_split :: proc(item: string) -> (label, hint: string) {
	if i := strings.index_byte(item, '\t'); i >= 0 do return item[:i], item[i + 1:]
	return item, ""
}

draw_menu :: proc(vg: ^nvg.Context) {
	if !ui.menu.open do return
	m := &ui.menu
	r, content_h := menu_rect(vg)
	m.scroll = clamp(m.scroll - wheel_over(r), 0, max(content_h - r.h, 0))
	if m.searchable && m.just_opened do ui.focus = "" // typing goes to the search box
	popup_shadow(vg, r, 8)
	fill_rect(vg, r, {0.19, 0.19, 0.19, 1}, 8)
	stroke_rect(vg, r, {1, 1, 1, 0.1}, 8)

	// search box
	list := r
	if m.searchable {
		box := Rect{r.x + 8, r.y + 6, r.w - 16, 26}
		fill_rect(vg, box, {1, 1, 1, 0.08}, 6)
		typed := false
		for ch in pf.chars {
			strings.write_rune(&m.filter, ch)
			typed = true
		}
		if key_hit(KEY_BACKSPACE) && strings.builder_len(m.filter) > 0 {
			_, size := utf8.decode_last_rune_in_string(strings.to_string(m.filter))
			for _ in 0 ..< size do strings.pop_byte(&m.filter)
			typed = true
		}
		if typed {
			menu_filter()
			m.scroll = 0
		}
		text := strings.to_string(m.filter)
		if text == "" do label(vg, box.x + 10, box.y + 13, "Search", TEXT_DIM)
		else do label(vg, box.x + 10, box.y + 13, text, TEXT_FG)
		if int(time.now()._nsec / 500_000_000) % 2 == 0 {
			fill_rect(vg, {box.x + 10 + text_width(vg, text) + 1, box.y + 6, 1.5, 14}, TEXT_FG)
		}
		list = {r.x, r.y + MENU_SEARCH, r.w, r.h - MENU_SEARCH}
	}

	// keyboard
	enabled :: proc(i: int) -> bool {return ui.menu.items[i] != "-"}
	if (key_hit(KEY_DOWN) || key_hit(KEY_UP)) && len(m.visible) > 0 {
		dir := 1 if key_hit(KEY_DOWN) else -1
		pos := -1
		for v, k in m.visible do if v == m.hover do pos = k
		for _ in 0 ..< len(m.visible) {
			pos = (pos + dir + len(m.visible)) % len(m.visible)
			if enabled(m.visible[pos]) do break
		}
		m.hover = m.visible[pos]
	}
	picked := -1
	if key_pressed(KEY_ENTER) && m.hover >= 0 && enabled(m.hover) do picked = m.hover

	nvg.Save(vg)
	nvg.IntersectScissor(vg, list.x, list.y, list.w, list.h)
	y := list.y + 4 - m.scroll
	for vi in m.visible {
		it := m.items[vi]
		h := menu_item_h(it)
		row := Rect{r.x + 4, y, r.w - 8, h}
		if y + h < list.y || y > list.y + list.h {
			y += h
			continue
		}
		if it == "-" {
			fill_rect(vg, {row.x + 6, y + h / 2, row.w - 12, 1}, PANEL_LINE)
			y += h
			continue
		}
		if in_rect(row, app.mouse) && in_rect(list, app.mouse) && (pf.mouse != pf.mouse_prev || m.hover < 0) do m.hover = vi
		if m.hover == vi {
			fill_rect(vg, row, ACTIVE_BG, 5)
			if mouse_pressed(MOUSE_BUTTON_LEFT) && in_rect(row, app.mouse) do picked = vi
		}
		lbl, hint := menu_split(it)
		if m.checked == vi do draw_icon(vg, .Check, row.x + 12, row.y + h / 2, TEXT_FG, 12)
		if m.font_preview {
			nvg.FontFace(vg, engine.font_face(lbl, 400, false))
			nvg.FontSize(vg, 13)
			nvg.TextAlign(vg, .LEFT, .MIDDLE)
			nvg.FillColor(vg, TEXT_FG)
			nvg.Text(vg, row.x + 26, row.y + h / 2, lbl)
		} else {
			label(vg, row.x + 26, row.y + h / 2, lbl, TEXT_FG)
		}
		if hint != "" do label(vg, row.x + row.w - 10, row.y + h / 2, hint, TEXT_DIM, 11, false, .RIGHT)
		y += h
	}
	nvg.Restore(vg)
	m.scroll = scrollbar(vg, "menu", list, content_h - (MENU_SEARCH if m.searchable else 0), m.scroll)

	if picked >= 0 {
		delete(m.result_key)
		m.result_key = strings.clone(m.key)
		m.result = picked
		m.has_result = true
		menu_close()
		return
	}
	if (mouse_pressed(MOUSE_BUTTON_LEFT) && !m.just_opened && !in_rect(r, app.mouse)) || key_pressed(KEY_ESCAPE) {
		menu_close()
	}
	m.just_opened = false
}

// ---------------------------------------------------------------- color picker

Picker :: struct {
	open:        bool,
	key:         string,
	anchor:      Rect,
	h, s, v, a:  f32,
	drag:        enum {None, SV, Hue, Alpha},
	just_opened: bool,
	changed:     bool, // a new color is waiting in `color`
	color:       engine.Color,
	ref:         string, // "$name" when a document color was picked
	result_key:  string,
	current:     string, // variable the property uses now ("" = a literal color)
	filter:      strings.Builder, // typed search over the document colors
	scroll:      f32,
	reveal:      bool, // scroll the current variable into view on the next draw
}

// `ref` names the variable the property is bound to ("$name"), if any.
picker_open :: proc(key: string, anchor: Rect, c: engine.Color, ref := "") {
	picker_close()
	p := &ui.picker
	p.open = true
	p.key = strings.clone(key)
	p.anchor = anchor
	p.anchor.x += ui.origin.x
	p.anchor.y += ui.origin.y
	p.h, p.s, p.v = rgb_to_hsv(c)
	p.a = f32(c[3]) / 255
	p.color = c
	p.just_opened = true
	p.current = strings.clone(strings.trim_prefix(ref, "$"))
	strings.builder_reset(&p.filter)
	p.scroll = 0
	p.reveal = true
}

picker_close :: proc() {
	delete(ui.picker.key)
	ui.picker.key = ""
	delete(ui.picker.current)
	ui.picker.current = ""
	ui.picker.open = false
	ui.picker.drag = .None
	if ui.focus == "picker.hex" do ui.focus = ""
}

picker_is_open :: proc(key: string) -> bool {
	return ui.picker.open && ui.picker.key == key
}

// The color chosen since the last call (continuous while dragging). `ref` is set
// when a document color variable was picked instead of a literal.
picker_take :: proc(key: string) -> (c: engine.Color, ref: string, changed: bool) {
	p := &ui.picker
	if p.changed && p.result_key == key {
		p.changed = false
		ref = p.ref
		p.ref = ""
		return p.color, ref, true
	}
	return
}

picker_set :: proc() {
	p := &ui.picker
	p.color = hsv_to_rgb(p.h, p.s, p.v, p.a)
	p.changed = true
	delete(p.result_key)
	p.result_key = strings.clone(p.key)
}

PICKER_W :: f32(248)
PICKER_ROW :: f32(28)
PICKER_LIST_MAX :: f32(280)

draw_picker :: proc(vg: ^nvg.Context) {
	p := &ui.picker
	if !p.open do return
	// document colors as a list (name + value), narrowed by typing; a plain palette
	// when the document has no color variables
	all_names := color_variable_names()
	if ui.focus == "" {
		typed := false
		for ch in pf.chars {
			strings.write_rune(&p.filter, ch)
			typed = true
		}
		if key_hit(KEY_BACKSPACE) && strings.builder_len(p.filter) > 0 {
			_, size := utf8.decode_last_rune_in_string(strings.to_string(p.filter))
			for _ in 0 ..< size do strings.pop_byte(&p.filter)
			typed = true
		}
		if typed do p.scroll = 0
	}
	needle := strings.to_lower(strings.to_string(p.filter), context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	for n in all_names do if needle == "" || strings.contains(n, needle) do append(&names, n)
	has_vars := len(all_names) > 0
	list_h: f32
	if has_vars do list_h = min(max(f32(len(names)), 1) * PICKER_ROW, PICKER_LIST_MAX)
	else do list_h = f32((len(SWATCHES) + 7) / 8) * 28
	h: f32 = 16 + 150 + 12 + 14 + 10 + 14 + 14 + 32 + 10 + 24 + (34 if has_vars else 0) + list_h + 8
	x := clamp(p.anchor.x, 8, app.screen.x - PICKER_W - 8)
	y := p.anchor.y + p.anchor.h + 6
	// placed for the tallest list, so it does not jump while the search narrows it
	tallest := h - list_h + (min(f32(len(all_names)) * PICKER_ROW, PICKER_LIST_MAX) if has_vars else list_h)
	if y + tallest > app.screen.y - 8 do y = max(p.anchor.y - tallest - 6, 8)
	r := Rect{x, y, PICKER_W, h}
	popup_shadow(vg, r, 10)
	fill_rect(vg, r, {0.19, 0.19, 0.19, 1}, 10)
	stroke_rect(vg, r, {1, 1, 1, 0.1}, 10)
	saved_clip := ui.clip
	ui.clip = r
	defer ui.clip = saved_clip

	// saturation / value square
	sv := Rect{r.x + 12, r.y + 12, r.w - 24, 150}
	hue_col := hsv_to_rgb(p.h, 1, 1, 1)
	nvg.BeginPath(vg)
	nvg.RoundedRect(vg, sv.x, sv.y, sv.w, sv.h, 6)
	nvg.FillPaint(vg, nvg.LinearGradient(sv.x, sv.y, sv.x + sv.w, sv.y, {1, 1, 1, 1}, engine.to_nvg(hue_col)))
	nvg.Fill(vg)
	nvg.BeginPath(vg)
	nvg.RoundedRect(vg, sv.x, sv.y, sv.w, sv.h, 6)
	nvg.FillPaint(vg, nvg.LinearGradient(sv.x, sv.y, sv.x, sv.y + sv.h, {0, 0, 0, 0}, {0, 0, 0, 1}))
	nvg.Fill(vg)
	kx, ky := sv.x + p.s * sv.w, sv.y + (1 - p.v) * sv.h
	nvg.BeginPath(vg)
	nvg.Circle(vg, kx, ky, 6)
	nvg.StrokeColor(vg, {1, 1, 1, 1})
	nvg.StrokeWidth(vg, 2)
	nvg.Stroke(vg)
	nvg.BeginPath(vg)
	nvg.Circle(vg, kx, ky, 7)
	nvg.StrokeColor(vg, {0, 0, 0, 0.5})
	nvg.StrokeWidth(vg, 1)
	nvg.Stroke(vg)

	// hue bar
	hue := Rect{r.x + 12, sv.y + sv.h + 12, r.w - 24, 14}
	for i in 0 ..< 6 {
		seg := Rect{hue.x + hue.w * f32(i) / 6, hue.y, hue.w / 6 + 1, hue.h}
		c0 := hsv_to_rgb(f32(i) / 6, 1, 1, 1)
		c1 := hsv_to_rgb(f32(i + 1) / 6, 1, 1, 1)
		nvg.BeginPath(vg)
		nvg.Rect(vg, seg.x, seg.y, seg.w, seg.h)
		nvg.FillPaint(vg, nvg.LinearGradient(seg.x, seg.y, seg.x + seg.w, seg.y, engine.to_nvg(c0), engine.to_nvg(c1)))
		nvg.Fill(vg)
	}
	picker_knob(vg, hue.x + p.h * hue.w, hue.y + hue.h / 2)

	// alpha bar
	al := Rect{r.x + 12, hue.y + hue.h + 10, r.w - 24, 14}
	for i in 0 ..< int(al.w / 7) {
		for j in 0 ..< 2 {
			if (i + j) % 2 == 0 do fill_rect(vg, {al.x + f32(i) * 7, al.y + f32(j) * 7, 7, 7}, {0.6, 0.6, 0.6, 1})
			else do fill_rect(vg, {al.x + f32(i) * 7, al.y + f32(j) * 7, 7, 7}, {0.35, 0.35, 0.35, 1})
		}
	}
	opaque := hsv_to_rgb(p.h, p.s, p.v, 1)
	nvg.BeginPath(vg)
	nvg.Rect(vg, al.x, al.y, al.w, al.h)
	nvg.FillPaint(vg, nvg.LinearGradient(al.x, al.y, al.x + al.w, al.y, {0, 0, 0, 0}, engine.to_nvg(opaque)))
	nvg.Fill(vg)
	picker_knob(vg, al.x + p.a * al.w, al.y + al.h / 2)

	// dragging the three controls
	if mouse_pressed(MOUSE_BUTTON_LEFT) {
		switch {
		case in_rect(sv, app.mouse): p.drag = .SV
		case in_rect({hue.x, hue.y - 4, hue.w, hue.h + 8}, app.mouse): p.drag = .Hue
		case in_rect({al.x, al.y - 4, al.w, al.h + 8}, app.mouse): p.drag = .Alpha
		}
	}
	if p.drag != .None && mouse_down(MOUSE_BUTTON_LEFT) {
		switch p.drag {
		case .None:
		case .SV:
			p.s = clamp((app.mouse.x - sv.x) / sv.w, 0, 1)
			p.v = 1 - clamp((app.mouse.y - sv.y) / sv.h, 0, 1)
		case .Hue: p.h = clamp((app.mouse.x - hue.x) / hue.w, 0, 0.9999)
		case .Alpha: p.a = clamp((app.mouse.x - al.x) / al.w, 0, 1)
		}
		picker_set()
	} else {
		p.drag = .None
	}

	// hex and alpha fields
	fy := al.y + al.h + 14
	cur := hsv_to_rgb(p.h, p.s, p.v, p.a)
	fill_rect(vg, {r.x + 12, fy + 3, 22, 22}, engine.to_nvg(cur), 5)
	stroke_rect(vg, {r.x + 12, fy + 3, 22, 22}, {1, 1, 1, 0.15}, 5)
	field(vg, 0, "picker.hex", "", {r.x + 42, fy, 100, 28}, fmt.tprintf("%02X%02X%02X", cur[0], cur[1], cur[2]))
	field(vg, 0, "picker.alpha", "", {r.x + 150, fy, 70, 28}, fmt.tprintf("%d%%", int(p.a * 100 + 0.5)), numeric = true)

	// document colors
	gy := fy + 40
	label(vg, r.x + 12, gy, "Document colors" if has_vars else "Palette", TEXT_DIM, 11)
	if has_vars {
		label(vg, r.x + r.w - 12, gy, fmt.tprintf("%d", len(names)), TEXT_DIM, 11, false, .RIGHT)
		gy += 12
		box := Rect{r.x + 12, gy, r.w - 24, 26}
		fill_rect(vg, box, {1, 1, 1, 0.08}, 6)
		text := strings.to_string(p.filter)
		if text == "" do label(vg, box.x + 10, box.y + 13, "Search colors", TEXT_DIM)
		else do label(vg, box.x + 10, box.y + 13, text, TEXT_FG)
		if ui.focus == "" && int(time.now()._nsec / 500_000_000) % 2 == 0 {
			fill_rect(vg, {box.x + 10 + text_width(vg, text) + 1, box.y + 6, 1.5, 14}, TEXT_FG)
		}
		if clicked(box) && ui.focus != "" do field_commit() // typing goes back to the search
		gy += 34
		list := Rect{r.x + 4, gy, r.w - 8, list_h}
		content_h := f32(len(names)) * PICKER_ROW
		if p.reveal {
			for n, i in names do if n == p.current do p.scroll = f32(i) * PICKER_ROW - list_h / 2 + PICKER_ROW / 2
			p.reveal = false
		}
		p.scroll -= wheel_over(list)
		p.scroll = clamp(p.scroll, 0, max(content_h - list_h, 0))
		nvg.Save(vg)
		nvg.IntersectScissor(vg, list.x, list.y, list.w, list.h)
		if len(names) == 0 do label(vg, list.x + 8, list.y + 14, "No colors match", TEXT_DIM)
		for name, i in names {
			row := Rect{list.x, list.y + f32(i) * PICKER_ROW - p.scroll, list.w - 8, PICKER_ROW}
			if row.y + row.h < list.y || row.y > list.y + list.h do continue
			c := app.doc.vars[name].color
			if name == p.current do fill_rect(vg, row, ACTIVE_BG, 6)
			else if in_rect(row, app.mouse) && in_rect(list, app.mouse) do fill_rect(vg, row, HOVER_BG, 6)
			sw := Rect{row.x + 8, row.y + 5, 18, 18}
			fill_rect(vg, sw, engine.to_nvg(c), 4)
			stroke_rect(vg, sw, {1, 1, 1, 0.15}, 4)
			hex := engine.color_hex(c)[1:]
			hw := text_width(vg, hex, 11)
			nvg.Save(vg)
			nvg.IntersectScissor(vg, row.x, row.y, row.w - hw - 18, row.h)
			label(vg, sw.x + sw.w + 8, row.y + row.h / 2, name, TEXT_FG, 12)
			nvg.Restore(vg)
			label(vg, row.x + row.w - 8, row.y + row.h / 2, hex, TEXT_DIM, 11, false, .RIGHT)
			if in_rect(row, app.mouse) && in_rect(list, app.mouse) && mouse_pressed(MOUSE_BUTTON_LEFT) {
				p.h, p.s, p.v = rgb_to_hsv(c)
				p.a = f32(c[3]) / 255
				picker_set()
				delete(p.ref)
				p.ref = fmt.aprintf("$%s", name)
				delete(p.current)
				p.current = strings.clone(name)
			}
		}
		nvg.Restore(vg)
		p.scroll = scrollbar(vg, "picker.colors", list, content_h, p.scroll)
	} else {
		gy += 14
		for hex, i in SWATCHES {
			sw := Rect{r.x + 12 + f32(i % 8) * 28, gy + f32(i / 8) * 28, 22, 22}
			c, _ := engine.parse_color(hex)
			fill_rect(vg, sw, engine.to_nvg(c), 5)
			stroke_rect(vg, sw, {1, 1, 1, 0.15}, 5)
			if in_rect(sw, app.mouse) {
				stroke_rect(vg, {sw.x - 2, sw.y - 2, sw.w + 4, sw.h + 4}, TEXT_FG, 7, 1.5)
				if mouse_pressed(MOUSE_BUTTON_LEFT) {
					p.h, p.s, p.v = rgb_to_hsv(c)
					p.a = f32(c[3]) / 255
					picker_set()
				}
			}
		}
	}

	if (mouse_pressed(MOUSE_BUTTON_LEFT) && !p.just_opened && !in_rect(r, app.mouse)) || key_pressed(KEY_ESCAPE) {
		if ui.focus == "picker.hex" || ui.focus == "picker.alpha" do field_commit()
		picker_close()
	}
	p.just_opened = false
}

picker_knob :: proc(vg: ^nvg.Context, x, y: f32) {
	nvg.BeginPath(vg)
	nvg.Circle(vg, x, y, 7)
	nvg.FillColor(vg, {1, 1, 1, 1})
	nvg.Fill(vg)
	nvg.StrokeColor(vg, {0, 0, 0, 0.4})
	nvg.StrokeWidth(vg, 1)
	nvg.Stroke(vg)
}

// Typed hex / alpha in the picker.
picker_apply_text :: proc(key, text: string) {
	p := &ui.picker
	t := strings.trim_space(text)
	if key == "picker.hex" {
		hex := t if strings.has_prefix(t, "#") else fmt.tprintf("#%s", t)
		if c, ok := engine.parse_color(hex); ok {
			p.h, p.s, p.v = rgb_to_hsv(c)
			if len(hex) > 7 do p.a = f32(c[3]) / 255
			picker_set()
		}
	} else if f, ok := strconv.parse_f32(strings.trim_suffix(t, "%")); ok {
		p.a = clamp(f / 100, 0, 1)
		picker_set()
	}
}

rgb_to_hsv :: proc(c: engine.Color) -> (h, s, v: f32) {
	r, g, b := f32(c[0]) / 255, f32(c[1]) / 255, f32(c[2]) / 255
	mx, mn := max(r, g, b), min(r, g, b)
	v = mx
	d := mx - mn
	s = 0 if mx == 0 else d / mx
	if d == 0 do return 0, s, v
	switch mx {
	case r: h = math.mod((g - b) / d, 6)
	case g: h = (b - r) / d + 2
	case: h = (r - g) / d + 4
	}
	h /= 6
	if h < 0 do h += 1
	return
}

hsv_to_rgb :: proc(h, s, v, a: f32) -> engine.Color {
	i := int(h * 6)
	f := h * 6 - f32(i)
	p, q, t := v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
	r, g, b: f32
	switch i % 6 {
	case 0: r, g, b = v, t, p
	case 1: r, g, b = q, v, p
	case 2: r, g, b = p, v, t
	case 3: r, g, b = p, q, v
	case 4: r, g, b = t, p, v
	case: r, g, b = v, p, q
	}
	return {u8(r * 255 + 0.5), u8(g * 255 + 0.5), u8(b * 255 + 0.5), u8(a * 255 + 0.5)}
}

// ---------------------------------------------------------------- tooltips

tooltip_request :: proc(text: string, at: Rect) {
	if ui.hover_tip != text {
		delete(ui.hover_tip)
		ui.hover_tip = strings.clone(text)
		ui.hover_since = time.now()
		return
	}
	if time.duration_seconds(time.since(ui.hover_since)) > 0.6 {
		delete(ui.tooltip)
		ui.tooltip = strings.clone(text)
		ui.tooltip_rect = {at.x + ui.origin.x, at.y + ui.origin.y, at.w, at.h}
	}
}

draw_tooltip :: proc(vg: ^nvg.Context) {
	if ui.tooltip == "" {
		if ui.hover_tip != "" && pf.mouse != pf.mouse_prev {
			// nothing asked for a tip this frame: the pointer left the widget
		}
		return
	}
	w := text_width(vg, ui.tooltip, 11) + 16
	r := Rect{ui.tooltip_rect.x + ui.tooltip_rect.w / 2 - w / 2, ui.tooltip_rect.y + ui.tooltip_rect.h + 6, w, 22}
	r.x = clamp(r.x, 4, app.screen.x - w - 4)
	if r.y + r.h > app.screen.y - 4 do r.y = ui.tooltip_rect.y - 28
	fill_rect(vg, r, {0.1, 0.1, 0.1, 0.96}, 5)
	stroke_rect(vg, r, {1, 1, 1, 0.12}, 5)
	label(vg, r.x + 8, r.y + 11, ui.tooltip, TEXT_FG, 11)
}

// ---------------------------------------------------------------- dialogs

Dialog :: struct {
	open:       bool,
	key:        string,
	title:      string,
	message:    string,
	buttons:    [dynamic]string, // first = cancel (Esc), last = primary (Enter)
	result_key: string,
	result:     int,
	has_result: bool,
}

dialog_open :: proc(key, title, message: string, buttons: []string) {
	dialog_close()
	d := &ui.dialog
	d.open = true
	d.key = strings.clone(key)
	d.title = strings.clone(title)
	d.message = strings.clone(message)
	for b in buttons do append(&d.buttons, strings.clone(b))
}

dialog_close :: proc() {
	d := &ui.dialog
	delete(d.key)
	delete(d.title)
	delete(d.message)
	for b in d.buttons do delete(b)
	clear(&d.buttons)
	d.key, d.title, d.message = "", "", ""
	d.open = false
}

// The button pressed in the dialog with this key, once.
dialog_take :: proc(key: string) -> (int, bool) {
	d := &ui.dialog
	if d.has_result && d.result_key == key {
		d.has_result = false
		return d.result, true
	}
	return -1, false
}

draw_dialog :: proc(vg: ^nvg.Context) {
	d := &ui.dialog
	if !d.open do return
	fill_rect(vg, {0, 0, app.screen.x, app.screen.y}, {0, 0, 0, 0.45})
	w: f32 = 380
	// as tall as the message needs (at least the old 150)
	nvg.FontFace(vg, "ui")
	nvg.FontSize(vg, 12)
	nvg.TextAlign(vg, .LEFT, .TOP)
	tb: [4]f32
	nvg.TextBoxBounds(vg, 0, 0, w - 48, d.message, &tb)
	h: f32 = max(150, 52 + (tb[3] - tb[1]) + 16 + 46)
	r := Rect{(app.screen.x - w) / 2, (app.screen.y - h) / 2 - 40, w, h}
	popup_shadow(vg, r, 12)
	fill_rect(vg, r, {0.16, 0.16, 0.16, 1}, 12)
	stroke_rect(vg, r, {1, 1, 1, 0.1}, 12)
	label(vg, r.x + 24, r.y + 32, d.title, TEXT_FG, 15)
	nvg.FontFace(vg, "ui")
	nvg.FontSize(vg, 12)
	nvg.FillColor(vg, TEXT_DIM)
	nvg.TextAlign(vg, .LEFT, .TOP)
	nvg.TextBox(vg, r.x + 24, r.y + 52, w - 48, d.message)
	saved := ui.clip
	ui.clip = r
	picked := -1
	bx := r.x + r.w - 24
	for i := len(d.buttons) - 1; i >= 0; i -= 1 {
		bw := text_width(vg, d.buttons[i], 12) + 32
		br := Rect{bx - bw, r.y + h - 46, bw, 30}
		primary := i == len(d.buttons) - 1
		hover := in_rect(br, app.mouse)
		fill_rect(vg, br, nvg.Color{ACCENT.r, ACCENT.g, ACCENT.b, 0.85 if hover else 1} if primary else (nvg.Color{1, 1, 1, 0.1} if hover else FIELD_BG), 6)
		label(vg, br.x + br.w / 2, br.y + 15, d.buttons[i], TEXT_FG, 12, false, .CENTER)
		if mouse_pressed(MOUSE_BUTTON_LEFT) && hover do picked = i
		bx -= bw + 8
	}
	ui.clip = saved
	if key_pressed(KEY_ENTER) do picked = len(d.buttons) - 1
	if key_pressed(KEY_ESCAPE) do picked = 0
	if picked >= 0 {
		delete(d.result_key)
		d.result_key = strings.clone(d.key)
		d.result = picked
		d.has_result = true
		dialog_close()
	}
}
