package agentic_design

import "engine"

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import nvg "nanovg"

// App preferences, kept in settings.json next to the recent files, and the two sheets
// that show them: Settings (⌘,) and the keyboard shortcuts (?), as in pen.dev.

Settings :: struct {
	onboarded:    bool,
	nudge:        f32, // arrow keys
	nudge_big:    f32, // ⇧ + arrow keys
	pixel_grid:   bool, // a 1-unit grid at high zoom (⌘')
	snap_pixels:  bool, // whole numbers for positions and sizes set by dragging
	smart_guides: bool,
	agent_cursors: bool, // agents' cursors, flashes and placeholder glow (presence.odin)
	auto_update:  bool, // check for updates at launch and daily (update.odin)
	export_dir:   string, // the folder of the last export (export_ui.odin)
	last_seen_version: string, // the version whose "What's new" was shown (whats_new.odin)
	dash_sort:    Dash_Sort, // the dashboard's order of all files (dashboard.odin)
	dash_hidden:  [dynamic]string, // files and folders kept off the dashboard (files_index.odin)
	hide_layers:    bool, // the editor's floating panels (panels.odin)
	ui_scale:       f32, // the interface size, 0.9 to 1.3 (Settings, General)
	hide_inspector: bool,
}

Dash_Sort :: enum i32 {
	Modified,
	Opened,
	Name,
	Created,
}

DASH_SORT_KEYS := [Dash_Sort]string {
	.Modified = "modified",
	.Opened   = "opened",
	.Name     = "name",
	.Created  = "created",
}

settings := Settings {
	ui_scale     = 1,
	nudge        = 1,
	nudge_big    = 10,
	pixel_grid   = true,
	snap_pixels  = true,
	smart_guides = true,
	agent_cursors = true,
	auto_update  = true,
}

settings_open, shortcuts_open: bool
settings_found: bool // settings.json existed at launch (not a first run)

settings_path :: proc() -> string {
	return fmt.tprintf("%s/settings.json", support_dir())
}

settings_load :: proc() {
	data, err := fs_read(settings_path(), context.temp_allocator)
	if err != nil do return
	v, perr := json.parse_string(string(data), .JSON, false, context.temp_allocator)
	if perr != nil do return
	obj, _ := v.(json.Object)
	settings_found = true
	settings.onboarded = obj["onboarded"].(json.Boolean) or_else false
	if f, ok := obj["nudge"].(json.Float); ok do settings.nudge = f32(f)
	if f, ok := obj["nudgeBig"].(json.Float); ok do settings.nudge_big = f32(f)
	if b, ok := obj["pixelGrid"].(json.Boolean); ok do settings.pixel_grid = bool(b)
	if b, ok := obj["snapToPixels"].(json.Boolean); ok do settings.snap_pixels = bool(b)
	if b, ok := obj["smartGuides"].(json.Boolean); ok do settings.smart_guides = bool(b)
	if b, ok := obj["agentCursors"].(json.Boolean); ok do settings.agent_cursors = bool(b)
	if b, ok := obj["autoUpdate"].(json.Boolean); ok do settings.auto_update = bool(b)
	if s, ok := obj["exportFolder"].(json.String); ok do settings.export_dir = strings.clone(string(s))
	if s, ok := obj["lastSeenVersion"].(json.String); ok do settings.last_seen_version = strings.clone(string(s))
	if s, ok := obj["dashboardSort"].(json.String); ok {
		for k in Dash_Sort do if DASH_SORT_KEYS[k] == string(s) do settings.dash_sort = k
	}
	if b, ok := obj["hideLayers"].(json.Boolean); ok do settings.hide_layers = bool(b)
	if f, ok := obj["interfaceScale"].(json.Float); ok do settings.ui_scale = clamp(f32(f), UI_SCALES[0], UI_SCALES[len(UI_SCALES) - 1])
	if b, ok := obj["hideInspector"].(json.Boolean); ok do settings.hide_inspector = bool(b)
	if arr, ok := obj["dashboardHidden"].(json.Array); ok {
		for v in arr do if s, sok := v.(json.String); sok do append(&settings.dash_hidden, strings.clone(string(s)))
	}
}

// Test windows keep the user's settings as they are (whats_new.odin's test, in a sandboxed
// home, is the exception).
settings_save :: proc(in_test_window := false) {
	if pf.quiet && !in_test_window && !settings_test_writes() do return
	_ = fs_mkdir_all(support_dir())
	s := settings
	text := fmt.tprintf(
		"{{\n  \"onboarded\": %v,\n  \"nudge\": %s,\n  \"nudgeBig\": %s,\n  \"pixelGrid\": %v,\n  \"snapToPixels\": %v,\n  \"smartGuides\": %v,\n  \"agentCursors\": %v,\n  \"autoUpdate\": %v,\n  \"exportFolder\": %s,\n  \"lastSeenVersion\": %s,\n  \"dashboardSort\": \"%s\",\n  \"dashboardHidden\": %s,\n  \"hideLayers\": %v,\n  \"hideInspector\": %v,\n  \"interfaceScale\": %s\n}}\n",
		s.onboarded, engine.num_text(s.nudge), engine.num_text(s.nudge_big), s.pixel_grid, s.snap_pixels, s.smart_guides, s.agent_cursors, s.auto_update, json_quote(s.export_dir), json_quote(s.last_seen_version), DASH_SORT_KEYS[s.dash_sort], json_string_array(s.dash_hidden[:]), s.hide_layers, s.hide_inspector, engine.num_text(ui_scale()),
	)
	_ = fs_write(settings_path(), text)
}

json_string_array :: proc(items: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for it, i in items {
		if i > 0 do strings.write_string(&b, ", ")
		engine.json_write_string(&b, it)
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

json_quote :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	engine.json_write_string(&b, s)
	return strings.to_string(b)
}

settings_onboarded :: proc() -> bool {
	return settings.onboarded
}

settings_set_onboarded :: proc() {
	settings.onboarded = true
	settings_save()
}

// Whole page units, when snapping to pixels is on.
snap_px :: proc(v: f32) -> f32 {
	return math.round(v) if settings.snap_pixels else v
}

// A field of the Settings sheet committed.
settings_field_apply :: proc(key, text: string) -> bool {
	if !strings.has_prefix(key, "settings.") do return false
	f, ok := strconv.parse_f32(strings.trim_space(text))
	if !ok || f <= 0 do return true
	switch key {
	case "settings.nudge": settings.nudge = f
	case "settings.nudge_big": settings.nudge_big = f
	}
	settings_save()
	return true
}

// ---------------------------------------------------------------- sheets

// The frame each sheet was last drawn in (by title, a literal): a sheet not drawn last frame
// was opened in this one, often by a click outside where it appears (a Settings or Share
// button), and that click must not close it again.
sheet_frames: map[string]int

sheet_just_opened :: proc(key: string) -> bool {
	last, seen := sheet_frames[key]
	sheet_frames[key] = frames_drawn
	return !seen || last != frames_drawn - 1
}

// A centred modal sheet with a title and a close button; false once it is closed.
sheet_begin :: proc(vg: ^nvg.Context, title: string, w, h: f32) -> (sheet: Rect, open: bool) {
	just_opened := sheet_just_opened(title)
	fill_rect(vg, {0, 0, app.screen.x, app.screen.y}, {0, 0, 0, 0.55})
	w, h := min(app.screen.x - 96, w), min(app.screen.y - 96, h)
	sheet = Rect{(app.screen.x - w) / 2, (app.screen.y - h) / 2, w, h}
	popup_shadow(vg, sheet, 14)
	fill_rect(vg, sheet, {0.13, 0.13, 0.14, 1}, 14)
	stroke_rect(vg, sheet, {1, 1, 1, 0.08}, 14)
	ob_text(vg, sheet.x + 24, sheet.y + 30, title, 18, TEXT_FG, 600)
	close := Rect{sheet.x + sheet.w - 44, sheet.y + 14, 30, 30}
	if lucide_button(vg, close, "x") || (key_pressed(KEY_ESCAPE) && ui.focus == "") do return sheet, false
	if mouse_pressed(MOUSE_BUTTON_LEFT) && !in_rect(sheet, app.mouse) && !just_opened do return sheet, false
	return sheet, true
}

// Settings (app-ui.pen, "Settings · …"): sections on the left, the chosen one on the right.
Settings_Section :: enum {
	Account,
	General,
	Canvas,
	Agents,
	Updates,
}

SETTINGS_SECTION_NAMES := [Settings_Section]string {
	.Account = "Account",
	.General = "General",
	.Canvas  = "Canvas",
	.Agents  = "Agents",
	.Updates = "Updates",
}

SETTINGS_SECTION_ICONS := [Settings_Section]string {
	.Account = "circle-user",
	.General = "sliders-horizontal",
	.Canvas  = "frame",
	.Agents  = "sparkles",
	.Updates = "refresh-cw",
}

settings_section := Settings_Section.General

// A switch at the right of a settings row; true when clicked.
settings_switch :: proc(vg: ^nvg.Context, x, cy: f32, on: bool) -> bool {
	r := Rect{x - 34, cy - 10, 34, 20}
	fill_rect(vg, r, ACCENT if on else {1, 1, 1, 0.16}, 10)
	k := r.x + 12 if !on else r.x + r.w - 12
	nvg.BeginPath(vg)
	nvg.Circle(vg, k + (0 if on else -2), cy, 8)
	nvg.FillColor(vg, {1, 1, 1, 1})
	nvg.Fill(vg)
	return clicked(r)
}

// A group of rows in a rounded box: a small title above, `rows` rows of `row_h`.
settings_group :: proc(vg: ^nvg.Context, x, w: f32, y: ^f32, title: string, rows: int, row_h: f32 = 54) -> Rect {
	if title != "" {
		label(vg, x, y^ + 8, strings.to_upper(title, context.temp_allocator), TEXT_DIM, 10, true)
		y^ += 22
	}
	box := Rect{x, y^, w, f32(rows) * row_h}
	fill_rect(vg, box, {1, 1, 1, 0.03}, 10)
	stroke_rect(vg, box, {1, 1, 1, 0.08}, 10)
	for i in 1 ..< rows do fill_rect(vg, {x, y^ + f32(i) * row_h, w, 1}, {1, 1, 1, 0.07})
	y^ += box.h + 20
	return box
}

// A row's name and hint, at the left of row i of box.
settings_row_text :: proc(vg: ^nvg.Context, box: Rect, i: int, name, hint: string, row_h: f32 = 54) -> (cy: f32) {
	top := box.y + f32(i) * row_h
	cy = top + row_h / 2
	if hint == "" {
		label(vg, box.x + 14, cy, name, TEXT_FG, 13)
		return
	}
	label(vg, box.x + 14, cy - 8, name, TEXT_FG, 13)
	label(vg, box.x + 14, cy + 10, hint, TEXT_DIM, 11)
	return
}

draw_settings_sheet :: proc(vg: ^nvg.Context) {
	if !settings_open do return
	just_opened := sheet_just_opened("Settings")
	saved_pass := ui.overlay_pass
	ui.overlay_pass = true
	defer ui.overlay_pass = saved_pass
	fill_rect(vg, {0, 0, app.screen.x, app.screen.y}, {0, 0, 0, 0.55})
	w, h := min(app.screen.x - 64, f32(760)), min(app.screen.y - 64, f32(580))
	sheet := Rect{(app.screen.x - w) / 2, (app.screen.y - h) / 2, w, h}
	popup_shadow(vg, sheet, 14)
	fill_rect(vg, sheet, {0.13, 0.13, 0.14, 1}, 14)
	nav := Rect{sheet.x, sheet.y, 200, sheet.h}
	nvg.Save(vg)
	nvg.IntersectScissor(vg, nav.x, nav.y, nav.w, nav.h)
	fill_rect(vg, sheet, {0.105, 0.105, 0.115, 1}, 14)
	nvg.Restore(vg)
	fill_rect(vg, {nav.x + nav.w, nav.y, 1, nav.h}, {1, 1, 1, 0.08})
	stroke_rect(vg, sheet, {1, 1, 1, 0.08}, 14)
	closing := false
	close := Rect{sheet.x + sheet.w - 44, sheet.y + 14, 30, 30}
	if lucide_button(vg, close, "x") || (key_pressed(KEY_ESCAPE) && ui.focus == "") do closing = true
	if mouse_pressed(MOUSE_BUTTON_LEFT) && !in_rect(sheet, app.mouse) && !just_opened do closing = true
	if closing {
		if ui.focus != "" do field_commit()
		settings_open = false
		return
	}
	saved_clip := ui.clip
	ui.clip = sheet
	defer ui.clip = saved_clip

	// sections
	label(vg, nav.x + 18, nav.y + 30, "Settings", TEXT_FG, 15, true)
	ny := nav.y + 52
	for sec in Settings_Section {
		r := Rect{nav.x + 10, ny, nav.w - 20, 30}
		active := sec == settings_section
		if active do fill_rect(vg, r, ACTIVE_BG, 7)
		else if hovered(r) do fill_rect(vg, r, HOVER_BG, 7)
		draw_lucide(vg, SETTINGS_SECTION_ICONS[sec], r.x + 17, r.y + 15, 14, TEXT_FG if active else TEXT_DIM, 1.6)
		label(vg, r.x + 34, r.y + 15, SETTINGS_SECTION_NAMES[sec], TEXT_FG if active else TEXT_DIM, 13)
		if clicked(r) && !active {
			if ui.focus != "" do field_commit()
			settings_section = sec
		}
		ny += 32
	}
	label(vg, nav.x + 18, nav.y + nav.h - 20, fmt.tprintf("Agentic Design %s", VERSION), TEXT_DIM, 11)

	x := nav.x + nav.w + 24
	cw := sheet.x + sheet.w - 24 - x
	ob_text(vg, x, sheet.y + 30, SETTINGS_SECTION_NAMES[settings_section], 18, TEXT_FG, 600)
	y := sheet.y + 60
	switch settings_section {
	case .Account: draw_settings_account(vg, x, cw, &y)
	case .General: draw_settings_general(vg, x, cw, &y)
	case .Canvas: draw_settings_canvas(vg, x, cw, &y)
	case .Agents: draw_settings_agents(vg, x, cw, &y)
	case .Updates: draw_settings_updates(vg, x, cw, &y)
	}
}

draw_settings_general :: proc(vg: ^nvg.Context, x, w: f32, y: ^f32) {
	box := settings_group(vg, x, w, y, "Interface", 1, 92)
	label(vg, box.x + 14, box.y + 24, "Interface size", TEXT_FG, 13)
	label(vg, box.x + 14, box.y + 42, "Panels, menus and text; the canvas keeps its zoom.", TEXT_DIM, 11)
	label(vg, box.x + 14, box.y + 70, "⌘⌥+ and ⌘⌥− change it anywhere; ⌘⌥0 goes back to 100%.", TEXT_DIM, 11)
	cell: f32 = 64
	cx := box.x + box.w - 14 - cell * f32(len(UI_SCALES))
	for s, i in UI_SCALES {
		r := Rect{cx + f32(i) * cell, box.y + 12, cell - 4, 46}
		on := abs(s - ui_scale()) < 0.01
		if on do fill_rect(vg, r, ACTIVE_BG, 8)
		else if hovered(r) do fill_rect(vg, r, HOVER_BG, 8)
		label(vg, r.x + r.w / 2, r.y + 16, "Aa", TEXT_FG if on else TEXT_DIM, 11 * s + 1, true, .CENTER)
		label(vg, r.x + r.w / 2, r.y + 34, fmt.tprintf("%d%%", int(s * 100 + 0.5)), TEXT_FG if on else TEXT_DIM, 10, false, .CENTER)
		if clicked(r) do ui_scale_set(s)
	}

	box = settings_group(vg, x, w, y, "Window", 1)
	cy := settings_row_text(vg, box, 0, "Layers and inspector", "Floating panels over the canvas; ⌘\\ hides and shows both")
	shown := panel_shown(.Left) || panel_shown(.Right)
	if settings_switch(vg, box.x + box.w - 14, cy, shown) do panels_toggle_all()
}

draw_settings_canvas :: proc(vg: ^nvg.Context, x, w: f32, y: ^f32) {
	box := settings_group(vg, x, w, y, "Moving", 1)
	cy := settings_row_text(vg, box, 0, "Nudge", "Arrow keys move by this much; ⇧ for the larger step")
	fx := box.x + box.w - 14 - 60
	field(vg, 0, "settings.nudge_big", "", {fx, cy - 14, 60, 28}, engine.num_text(settings.nudge_big), numeric = true)
	label(vg, fx - 8, cy, "⇧", TEXT_DIM, 12, false, .RIGHT)
	field(vg, 0, "settings.nudge", "", {fx - 30 - 60, cy - 14, 60, 28}, engine.num_text(settings.nudge), numeric = true)

	Toggle :: struct {
		name, hint: string,
		value:      ^bool,
	}
	toggles := [3]Toggle {
		{"Pixel grid", "A grid of whole units at 800% and closer  ⌘'", &settings.pixel_grid},
		{"Snap to pixels", "Dragging and resizing land on whole units", &settings.snap_pixels},
		{"Smart guides", "Align to edges and centres of neighbours (hold ⌃ to skip)", &settings.smart_guides},
	}
	box = settings_group(vg, x, w, y, "Guides", len(toggles))
	for t, i in toggles {
		cy = settings_row_text(vg, box, i, t.name, t.hint)
		if settings_switch(vg, box.x + box.w - 14, cy, t.value^) {
			t.value^ = !t.value^
			settings_save()
		}
	}
}

draw_settings_agents :: proc(vg: ^nvg.Context, x, w: f32, y: ^f32) {
	box := settings_group(vg, x, w, y, "", 3)
	cy := settings_row_text(vg, box, 2, "Agent history", "The requests and answers kept for each file on this Mac")
	if button(vg, {box.x + box.w - 14 - 120, cy - 14, 120, 28}, "Clear history") {
		agent_history_clear()
		set_status("Agent history cleared")
	}
	cy = settings_row_text(vg, box, 0, "Connect agents", "Claude Code, Codex and other MCP clients edit the open file")
	if button(vg, {box.x + box.w - 14 - 120, cy - 14, 120, 28}, "Set up…") {
		settings_open = false
		onboarding_start(1)
	}
	cy = settings_row_text(vg, box, 1, "Agent cursors", "Show where agents work: their cursors, and flashes on what they change")
	if settings_switch(vg, box.x + box.w - 14, cy, settings.agent_cursors) {
		settings.agent_cursors = !settings.agent_cursors
		settings_save()
	}
}

draw_settings_updates :: proc(vg: ^nvg.Context, x, w: f32, y: ^f32) {
	box := settings_group(vg, x, w, y, "", 3)
	cy := settings_row_text(vg, box, 0, fmt.tprintf("Version %s", VERSION), "")
	if button(vg, {box.x + box.w - 14 - 110, cy - 14, 110, 28}, "What's new") {
		whats_new_show()
		return
	}
	cy = settings_row_text(vg, box, 1, "Update automatically", update_status_text())
	if settings_switch(vg, box.x + box.w - 14, cy, settings.auto_update) {
		settings.auto_update = !settings.auto_update
		settings_save()
	}
	cy = settings_row_text(vg, box, 2, "Check for an update", "")
	bx := box.x + box.w - 14
	#partial switch update_phase() {
	case .Ready:
		if button(vg, {bx - 210, cy - 14, 210, 28}, fmt.tprintf("Restart to update to %s", update.version), primary = true) do update_request_install()
	case .Checking, .Downloading, .Installing, .Waiting_For_Agents:
	case:
		if update_allowed() && bundle_path() != "" {
			if button(vg, {bx - 110, cy - 14, 110, 28}, "Check now") do update_check()
		}
	}
	if button(vg, {x, y^, 180, 28}, "Show onboarding again") {
		settings_open = false
		onboarding_start(0)
	}
}

Shortcut :: struct {
	keys, what: string,
}

SHORTCUT_GROUPS := [?]struct {
	name:  string,
	items: []Shortcut,
} {
	{"Tools", {{"V", "Move"}, {"H", "Hand"}, {"F  B", "Frame"}, {"R", "Rectangle"}, {"O  E", "Ellipse"}, {"T", "Text"}, {"Z  (hold)", "Zoom: click, ⌥-click, drag"}, {"Space  (hold)", "Pan"}}},
	{"Select", {{"Click", "Layer at the current level"}, {"⌘ Click", "Deepest layer"}, {"Double click", "One level in, edit text"}, {"⇧ Click", "Add to selection"}, {"Enter  ⇧ Enter", "Children  /  parent"}, {"⌘ A", "Select all"}, {"⌘ F", "Find layers"}, {"⌥  (hold)", "Measure distances"}}},
	{"Edit", {{"⌘ C  ⌘ X  ⌘ V", "Copy, cut, paste"}, {"⌘ D", "Duplicate"}, {"⌫", "Delete"}, {"⌘ G  ⌥⌘ G", "Group, frame"}, {"⇧ A", "Flex layout"}, {"⇧⌘ G", "Ungroup"}, {"⌘ R", "Rename"}, {"⌘ Z  ⇧⌘ Z", "Undo, redo"}, {"Arrows", "Nudge (⇧ more), reorder in flex"}}},
	{"Arrange", {{"⌥ A  ⌥ D", "Align left, right"}, {"⌥ W  ⌥ S", "Align top, bottom"}, {"⌥ H  ⌥ V", "Centre, middle"}, {"⌘ [  ⌘ ]", "Back, forward one step"}, {"[  ]", "To the back, front"}, {"⇧ H  ⇧ V", "Flip"}, {"⇧⌥ A", "Remove flex layout"}}},
	{"Components", {{"⌥⌘ K", "Create component"}, {"⌥⌘ X", "Detach instance"}}},
	{"View", {{"⌘ 0", "100%"}, {"⇧ 1  ⇧ 2", "Fit all, selection"}, {"⌘ +  ⌘ -", "Zoom in, out"}, {"⌘ '", "Pixel grid"}, {"?", "This sheet"}, {"⌘ ,", "Settings"}}},
	{"File", {{"⌘ N", "New file"}, {"⌘ S", "Save"}, {"⌘ W", "Close tab"}, {"⇧⌘ E", "Export"}}},
}

draw_shortcuts_sheet :: proc(vg: ^nvg.Context) {
	if !shortcuts_open do return
	saved_pass := ui.overlay_pass
	ui.overlay_pass = true
	defer ui.overlay_pass = saved_pass
	sheet, open := sheet_begin(vg, "Keyboard shortcuts", 1000, 640)
	if !open {
		shortcuts_open = false
		return
	}
	cols := 3
	col_w := (sheet.w - 48) / f32(cols)
	ys := [3]f32{sheet.y + 64, sheet.y + 64, sheet.y + 64}
	for g in SHORTCUT_GROUPS {
		// the shortest column takes the next group
		c := 0
		for i in 1 ..< cols do if ys[i] < ys[c] do c = i
		x := sheet.x + 24 + f32(c) * col_w
		label(vg, x, ys[c] + 10, g.name, TEXT_FG, 13)
		ys[c] += 26
		for it in g.items {
			label(vg, x, ys[c] + 10, it.keys, ACCENT, 12)
			label(vg, x + 120, ys[c] + 10, it.what, TEXT_DIM, 12)
			ys[c] += 22
		}
		ys[c] += 16
	}
}

// ---------------------------------------------------------------- pixel grid

// Lines on whole page units once a unit is 8 screen pixels or more.
draw_pixel_grid :: proc(vg: ^nvg.Context) {
	if !settings.pixel_grid || app.zoom < 8 do return
	a := to_page({app.canvas.x, app.canvas.y})
	b := to_page({app.canvas.x + app.canvas.w, app.canvas.y + app.canvas.h})
	nvg.BeginPath(vg)
	for x := math.floor(a.x); x <= b.x; x += 1 {
		s := to_screen({x, 0})
		nvg.MoveTo(vg, math.round(s.x) + 0.5, app.canvas.y)
		nvg.LineTo(vg, math.round(s.x) + 0.5, app.canvas.y + app.canvas.h)
	}
	for y := math.floor(a.y); y <= b.y; y += 1 {
		s := to_screen({0, y})
		nvg.MoveTo(vg, app.canvas.x, math.round(s.y) + 0.5)
		nvg.LineTo(vg, app.canvas.x + app.canvas.w, math.round(s.y) + 0.5)
	}
	nvg.StrokeColor(vg, {0.5, 0.5, 0.5, 0.18})
	nvg.StrokeWidth(vg, 1)
	nvg.Stroke(vg)
}

// One line on the state of updates, for the Settings sheet.
update_status_text :: proc() -> string {
	if !update_allowed() do return "Off in test windows"
	if bundle_path() == "" do return "Updates apply to the installed app"
	switch update_phase() {
	case .Idle: return "Not checked yet" if settings.auto_update else "Automatic checks are off"
	case .Checking: return "Checking…"
	case .Downloading: return "Downloading…"
	case .Up_To_Date: return "Up to date"
	case .Ready: return "Downloaded and verified"
	case .Waiting_For_Agents: return "Installing when the agents pause…"
	case .Installing: return "Installing…"
	case .Failed: return update.error
	}
	return ""
}
