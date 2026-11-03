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
}

settings := Settings {
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
}

// Test windows keep the user's settings as they are (whats_new.odin's test, in a sandboxed
// home, is the exception).
settings_save :: proc(in_test_window := false) {
	if pf.quiet && !in_test_window do return
	_ = fs_mkdir_all(support_dir())
	s := settings
	text := fmt.tprintf(
		"{{\n  \"onboarded\": %v,\n  \"nudge\": %s,\n  \"nudgeBig\": %s,\n  \"pixelGrid\": %v,\n  \"snapToPixels\": %v,\n  \"smartGuides\": %v,\n  \"agentCursors\": %v,\n  \"autoUpdate\": %v,\n  \"exportFolder\": %s,\n  \"lastSeenVersion\": %s\n}}\n",
		s.onboarded, engine.num_text(s.nudge), engine.num_text(s.nudge_big), s.pixel_grid, s.snap_pixels, s.smart_guides, s.agent_cursors, s.auto_update, json_quote(s.export_dir), json_quote(s.last_seen_version),
	)
	_ = fs_write(settings_path(), text)
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

// A centred modal sheet with a title and a close button; false once it is closed.
sheet_begin :: proc(vg: ^nvg.Context, title: string, w, h: f32) -> (sheet: Rect, open: bool) {
	fill_rect(vg, {0, 0, app.screen.x, app.screen.y}, {0, 0, 0, 0.55})
	w, h := min(app.screen.x - 96, w), min(app.screen.y - 96, h)
	sheet = Rect{(app.screen.x - w) / 2, (app.screen.y - h) / 2, w, h}
	popup_shadow(vg, sheet, 14)
	fill_rect(vg, sheet, {0.13, 0.13, 0.14, 1}, 14)
	stroke_rect(vg, sheet, {1, 1, 1, 0.08}, 14)
	ob_text(vg, sheet.x + 24, sheet.y + 30, title, 18, TEXT_FG, 600)
	close := Rect{sheet.x + sheet.w - 44, sheet.y + 14, 30, 30}
	if lucide_button(vg, close, "x") || (key_pressed(KEY_ESCAPE) && ui.focus == "") do return sheet, false
	if mouse_pressed(MOUSE_BUTTON_LEFT) && !in_rect(sheet, app.mouse) do return sheet, false
	return sheet, true
}

draw_settings_sheet :: proc(vg: ^nvg.Context) {
	if !settings_open do return
	saved_pass := ui.overlay_pass
	ui.overlay_pass = true
	defer ui.overlay_pass = saved_pass
	sheet, open := sheet_begin(vg, "Settings", 460, 540)
	if !open {
		if ui.focus != "" do field_commit()
		settings_open = false
		return
	}
	saved_clip := ui.clip
	ui.clip = sheet
	defer ui.clip = saved_clip

	x, w := sheet.x + 24, sheet.w - 48
	y := sheet.y + 64
	label(vg, x, y + 14, "Nudge", TEXT_FG, 13)
	label(vg, x + 150, y + 14, "Arrow", TEXT_DIM, 12)
	field(vg, 0, "settings.nudge", "", {x + 200, y, 60, 28}, engine.num_text(settings.nudge), numeric = true)
	label(vg, x + 280, y + 14, "⇧ Arrow", TEXT_DIM, 12)
	field(vg, 0, "settings.nudge_big", "", {x + 340, y, 60, 28}, engine.num_text(settings.nudge_big), numeric = true)
	y += 48
	Toggle :: struct {
		name, hint: string,
		value:      ^bool,
	}
	toggles := [4]Toggle {
		{"Pixel grid", "A grid of whole units at 800% and closer  ⌘'", &settings.pixel_grid},
		{"Snap to pixels", "Dragging and resizing land on whole units", &settings.snap_pixels},
		{"Smart guides", "Align to edges and centres of neighbours (hold ⌃ to skip)", &settings.smart_guides},
		{"Agent cursors", "Show where agents work: their cursors, and flashes on what they change", &settings.agent_cursors},
	}
	for t in toggles {
		if checkbox(vg, {x, y, w, 22}, t.name, t.value^) {
			t.value^ = !t.value^
			settings_save()
		}
		label(vg, x + 28, y + 34, t.hint, TEXT_DIM, 11)
		y += 58
	}
	// updates (update.odin)
	label(vg, x, y + 10, "Updates", TEXT_FG, 13)
	label(vg, x + 150, y + 10, fmt.tprintf("Version %s", VERSION), TEXT_DIM, 12)
	if button(vg, {x + w - 100, y - 4, 100, 28}, "What's new") {
		whats_new_show()
		return
	}
	y += 28
	if checkbox(vg, {x, y, w, 22}, "Check for updates automatically", settings.auto_update) {
		settings.auto_update = !settings.auto_update
		settings_save()
	}
	y += 34
	status_x := x
	#partial switch update_phase() {
	case .Ready:
		if button(vg, {x, y, 200, 28}, fmt.tprintf("Restart to update to %s", update.version)) do update_request_install()
		status_x = x + 212
	case .Checking, .Downloading, .Installing, .Waiting_For_Agents:
	case:
		if update_allowed() && bundle_path() != "" {
			if button(vg, {x, y, 120, 28}, "Check now") do update_check()
			status_x = x + 132
		}
	}
	label(vg, status_x, y + 14, update_status_text(), TEXT_DIM, 11)
	if button(vg, {x, sheet.y + sheet.h - 52, 180, 28}, "Show onboarding again") {
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
