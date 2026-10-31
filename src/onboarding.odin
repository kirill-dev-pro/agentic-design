package agentic_design

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "vendor:glfw"
import nvg "nanovg"

// The onboarding: a modal sheet with four steps (welcome, agents, features, start). It
// opens on the first launch of a window someone works in (not for test windows or
// windows an agent starts), and again from "Connect agents" on the dashboard and in the
// inspector. Finishing or closing it is remembered in settings.json.

Onboarding :: struct {
	open: bool,
	step: int,
}

onboarding: Onboarding

ONBOARDING_STEPS :: 4

onboarding_start :: proc(step := 0) {
	onboarding.open = true
	onboarding.step = clamp(step, 0, ONBOARDING_STEPS - 1)
	agents_detect()
}

onboarding_finish :: proc() {
	onboarding.open = false
	settings_set_onboarded()
}

// First launch: show it unless this is a test window or one an agent opened.
onboarding_maybe_start :: proc() {
	if pf.quiet || pf.no_focus || settings_onboarded() do return
	onboarding_start(0)
}

// ---------------------------------------------------------------- settings

settings_path :: proc() -> string {
	return fmt.tprintf("%s/settings.json", support_dir())
}

settings_onboarded :: proc() -> bool {
	data, err := os.read_entire_file(settings_path(), context.temp_allocator)
	if err != nil do return false
	v, perr := json.parse_string(string(data), .JSON, false, context.temp_allocator)
	if perr != nil do return false
	obj, _ := v.(json.Object)
	return obj["onboarded"].(json.Boolean) or_else false
}

settings_set_onboarded :: proc() {
	_ = os.make_directory_all(support_dir())
	_ = os.write_entire_file(settings_path(), "{\n  \"onboarded\": true\n}\n")
}

// ---------------------------------------------------------------- drawing helpers

// Inter when it is installed (the onboarding's type), else the interface font.
ob_face :: proc(weight: int) -> string {
	if family_find("Inter") != nil do return font_face("Inter", weight, false)
	return "ui-bold" if weight >= 600 && ui_bold_loaded else "ui"
}

ui_bold_loaded: bool

ob_text :: proc(vg: ^nvg.Context, x, y: f32, text: string, size: f32, color: nvg.Color, weight := 400, align := nvg.AlignHorizontal.LEFT) {
	nvg.FontFace(vg, ob_face(weight))
	nvg.FontSize(vg, size)
	nvg.TextLetterSpacing(vg, -size * 0.02 if size >= 24 else 0)
	nvg.TextAlign(vg, align, .MIDDLE)
	nvg.FillColor(vg, color)
	nvg.Text(vg, x, y, text)
	nvg.TextLetterSpacing(vg, 0)
}

// A paragraph wrapped to `w`, top-aligned at y.
ob_para :: proc(vg: ^nvg.Context, x, y, w: f32, text: string, size: f32, color: nvg.Color, align := nvg.AlignHorizontal.LEFT) {
	nvg.FontFace(vg, ob_face(400))
	nvg.FontSize(vg, size)
	nvg.TextLineHeight(vg, 1.45)
	nvg.TextAlign(vg, align, .TOP)
	nvg.FillColor(vg, color)
	nvg.TextBox(vg, x, y, w, text)
	nvg.TextLineHeight(vg, 1)
}

lucide_cache: map[string][dynamic]Path_Cmd

// A lucide icon centred at (cx, cy).
draw_lucide :: proc(vg: ^nvg.Context, name: string, cx, cy, size: f32, color: nvg.Color, stroke: f32 = 2) {
	cmds, ok := lucide_cache[name]
	if !ok {
		d, found := icon_path("lucide", name)
		if !found do return
		parsed, _, pok := parse_svg_path(d)
		if !pok do return
		lucide_cache[strings.clone(name)] = parsed
		cmds = parsed
	}
	s := size / 24
	nvg.Save(vg)
	nvg.Translate(vg, cx - size / 2, cy - size / 2)
	nvg.Scale(vg, s, s)
	nvg.BeginPath(vg)
	for c in cmds do path_cmd(vg, c, {0, 0}, 1, 1)
	nvg.LineCap(vg, .ROUND)
	nvg.LineJoin(vg, .ROUND)
	nvg.StrokeColor(vg, color)
	nvg.StrokeWidth(vg, stroke)
	nvg.Stroke(vg)
	nvg.Restore(vg)
}

Ob_Button :: enum {
	Primary, // light, like pen.dev's Continue
	Secondary, // outlined
	Success, // "Connected"
	Quiet, // small grey
}

ob_button :: proc(vg: ^nvg.Context, r: Rect, text: string, style: Ob_Button, icon := "", size: f32 = 14) -> bool {
	hover := hovered(r)
	fg := TEXT_FG
	switch style {
	case .Primary:
		fill_rect(vg, r, nvg.Color{0.93, 0.94, 0.96, 1} if !hover else nvg.Color{1, 1, 1, 1}, 8)
		fg = {0.08, 0.08, 0.09, 1}
	case .Secondary:
		fill_rect(vg, r, nvg.Color{1, 1, 1, 0.06 if hover else 0}, 8)
		stroke_rect(vg, r, {1, 1, 1, 0.16}, 8)
	case .Success:
		fill_rect(vg, r, {0.13, 0.25, 0.19, 1}, 8)
		fg = {0.55, 0.88, 0.66, 1}
	case .Quiet:
		fill_rect(vg, r, nvg.Color{1, 1, 1, 0.16 if hover else 0.1}, 6)
	}
	tw := ob_width(vg, text, size, 500)
	iw: f32 = 18 if icon != "" else 0
	x := r.x + (r.w - tw - iw) / 2
	ob_text(vg, x, r.y + r.h / 2, text, size, fg, 500)
	if icon != "" do draw_lucide(vg, icon, x + tw + 12, r.y + r.h / 2, 14, fg)
	return clicked(r)
}

ob_width :: proc(vg: ^nvg.Context, text: string, size: f32, weight: int) -> f32 {
	nvg.FontFace(vg, ob_face(weight))
	nvg.FontSize(vg, size)
	nvg.TextLetterSpacing(vg, -size * 0.02 if size >= 24 else 0)
	w := nvg.TextBounds(vg, 0, 0, text)
	nvg.TextLetterSpacing(vg, 0)
	return w
}

// ---------------------------------------------------------------- the sheet

draw_onboarding :: proc(vg: ^nvg.Context) {
	if !onboarding.open do return
	saved_pass := ui.overlay_pass
	ui.overlay_pass = true
	defer ui.overlay_pass = saved_pass

	fill_rect(vg, {0, 0, app.screen.x, app.screen.y}, {0, 0, 0, 0.6})
	w := min(app.screen.x - 64, 1180)
	h := min(app.screen.y - 64, 780)
	sheet := Rect{(app.screen.x - w) / 2, (app.screen.y - h) / 2, w, h}
	popup_shadow(vg, sheet, 16)
	fill_rect(vg, sheet, {0.125, 0.125, 0.135, 1}, 16)
	stroke_rect(vg, sheet, {1, 1, 1, 0.08}, 16)
	saved_clip := ui.clip
	ui.clip = sheet
	defer ui.clip = saved_clip

	// brand, progress dots, close
	ob_text(vg, sheet.x + 28, sheet.y + 32, "Agentic Design", 15, TEXT_FG, 600)
	dots_w := f32(ONBOARDING_STEPS - 1) * 18 + 32
	dx := sheet.x + (sheet.w - dots_w) / 2
	for i in 0 ..< ONBOARDING_STEPS {
		if i == onboarding.step {
			fill_rect(vg, {dx, sheet.y + 29, 32, 6}, {1, 1, 1, 0.92}, 3)
			dx += 32 + 10
		} else {
			d := Rect{dx, sheet.y + 29, 6, 6}
			fill_rect(vg, d, {1, 1, 1, 0.3}, 3)
			if clicked({d.x - 5, d.y - 8, 16, 22}) do onboarding.step = i
			dx += 18
		}
	}
	close := Rect{sheet.x + sheet.w - 48, sheet.y + 16, 32, 32}
	if hovered(close) do fill_rect(vg, close, HOVER_BG, 8)
	draw_lucide(vg, "x", close.x + 16, close.y + 16, 18, TEXT_DIM)
	if clicked(close) || key_pressed(glfw.KEY_ESCAPE) {
		onboarding_finish()
		return
	}

	body := Rect{sheet.x + 48, sheet.y + 76, sheet.w - 96, sheet.h - 76 - 96}
	switch onboarding.step {
	case 0: ob_step_welcome(vg, body)
	case 1: ob_step_agents(vg, body)
	case 2: ob_step_features(vg, body)
	case 3: ob_step_start(vg, body)
	}
	if !onboarding.open do return

	// Back / Continue
	by := sheet.y + sheet.h - 72
	last := onboarding.step == ONBOARDING_STEPS - 1
	cont := Rect{sheet.x + sheet.w / 2 + 6, by, 176, 48}
	back := Rect{sheet.x + sheet.w / 2 - 6 - 150, by, 150, 48}
	if onboarding.step > 0 {
		if ob_button(vg, back, "Back", .Secondary) do onboarding.step -= 1
	} else {
		cont.x = sheet.x + (sheet.w - cont.w) / 2
	}
	if ob_button(vg, cont, "Start designing" if last else "Continue", .Primary, "" if last else "arrow-right") || key_pressed(glfw.KEY_ENTER) {
		if last do onboarding_finish()
		else do onboarding.step += 1
	}
}

ob_heading :: proc(vg: ^nvg.Context, body: Rect, title, subtitle: string) -> f32 {
	cx := body.x + body.w / 2
	ob_text(vg, cx, body.y + 50, title, 44, TEXT_FG, 600, .CENTER)
	ob_text(vg, cx, body.y + 106, subtitle, 17, {0.68, 0.69, 0.72, 1}, 400, .CENTER)
	return body.y + 150
}

ob_step_welcome :: proc(vg: ^nvg.Context, body: Rect) {
	y := ob_heading(vg, body, "Design with your agents.", "A native canvas your coding agents can see, draw on and export, while you watch and edit.")
	Tile :: struct {
		icon, title, text: string,
	}
	tiles := [?]Tile {
		{"mouse-pointer-2", "One live canvas", "Agents edit the file you have open. Every change appears as it happens, and you can take over at any moment."},
		{"braces", "Open .pen files", "Documents are pen.dev's .pen format. Files open as they are and nothing is lost when they are saved."},
		{"plug-zap", "MCP built in", "The app is its own MCP server. Connect it once and every new agent session can read, draw and screenshot."},
	}
	gap: f32 = 24
	tw := (body.w - gap * 2) / 3
	th := min(body.y + body.h - y - 24, 300)
	for t, i in tiles {
		r := Rect{body.x + f32(i) * (tw + gap), y + 24, tw, th}
		fill_rect(vg, r, {1, 1, 1, 0.035}, 14)
		stroke_rect(vg, r, {1, 1, 1, 0.07}, 14)
		art := Rect{r.x + 1, r.y + 1, r.w - 2, r.h * 0.48}
		nvg.BeginPath(vg)
		nvg.RoundedRectVarying(vg, art.x, art.y, art.w, art.h, 13, 13, 0, 0)
		nvg.FillPaint(vg, nvg.LinearGradient(art.x, art.y, art.x + art.w, art.y + art.h, ob_gradient(i, 0), ob_gradient(i, 1)))
		nvg.Fill(vg)
		nvg.BeginPath(vg)
		nvg.Circle(vg, art.x + art.w / 2, art.y + art.h / 2, 34)
		nvg.FillColor(vg, {0, 0, 0, 0.25})
		nvg.Fill(vg)
		draw_lucide(vg, t.icon, art.x + art.w / 2, art.y + art.h / 2, 30, {1, 1, 1, 0.95})
		ob_text(vg, r.x + 22, art.y + art.h + 32, t.title, 18, TEXT_FG, 600)
		ob_para(vg, r.x + 22, art.y + art.h + 52, r.w - 44, t.text, 14, {0.62, 0.63, 0.66, 1})
	}
}

ob_gradient :: proc(i, end: int) -> nvg.Color {
	colors := [3][2]nvg.Color {
		{{0.40, 0.33, 0.95, 1}, {0.85, 0.36, 0.55, 1}},
		{{0.10, 0.55, 0.62, 1}, {0.33, 0.30, 0.85, 1}},
		{{0.93, 0.48, 0.25, 1}, {0.80, 0.25, 0.50, 1}},
	}
	return colors[i % 3][end]
}

ob_step_agents :: proc(vg: ^nvg.Context, body: Rect) {
	any_connected := false
	for c in agent_clients do if c.connected do any_connected = true
	subtitle := "We found your agents. You're ready to design." if any_connected else "Connect the built-in MCP server once; every new agent session can use the canvas."
	y := ob_heading(vg, body, "Set up your agents", subtitle)

	// the two main harnesses, large
	main_w: f32 = 330
	gap: f32 = 40
	x0 := body.x + (body.w - main_w * 2 - gap) / 2
	for i in 0 ..< 2 {
		c := &agent_clients[i]
		r := Rect{x0 + f32(i) * (main_w + gap), y + 16, main_w, 236}
		art_c := [2]f32{r.x + r.w / 2, r.y + 52}
		nvg.BeginPath(vg)
		nvg.Circle(vg, art_c.x, art_c.y, 40)
		nvg.FillPaint(vg, nvg.RadialGradient(art_c.x - 10, art_c.y - 14, 4, 52, {1, 1, 1, 0.22}, {1, 1, 1, 0.03}))
		nvg.Fill(vg)
		draw_lucide(vg, c.icon, art_c.x, art_c.y, 36, {0.92, 0.93, 0.95, 1}, 1.6)
		ob_text(vg, r.x + r.w / 2, r.y + 124, c.name, 24, TEXT_FG, 600, .CENTER)
		ob_text(vg, r.x + r.w / 2, r.y + 156, c.blurb, 14, {0.68, 0.69, 0.72, 1}, 400, .CENTER)
		ob_agent_button(vg, c, {r.x + 8, r.y + 184, r.w - 16, 48}, 15)
	}

	// everything else, small
	y += 16 + 236 + 24
	cx := body.x + body.w / 2
	lw := ob_width(vg, "Or connect another client", 13, 400)
	fill_rect(vg, {body.x + 40, y, body.w / 2 - 40 - lw / 2 - 16, 1}, {1, 1, 1, 0.08})
	fill_rect(vg, {cx + lw / 2 + 16, y, body.w / 2 - 40 - lw / 2 - 16, 1}, {1, 1, 1, 0.08})
	ob_text(vg, cx, y, "Or connect another client", 13, {0.6, 0.61, 0.64, 1}, 400, .CENTER)
	y += 28
	rest := len(agent_clients) - 2
	tw: f32 = min(150, (body.w - 40) / f32(rest))
	tx := body.x + (body.w - tw * f32(rest)) / 2
	for i in 2 ..< len(agent_clients) {
		c := &agent_clients[i]
		r := Rect{tx + f32(i - 2) * tw, y, tw, 120}
		alpha: f32 = 1 if c.installed || c.connected else 0.4
		draw_lucide(vg, c.icon, r.x + r.w / 2, r.y + 24, 28, {0.9, 0.91, 0.93, alpha}, 1.6)
		ob_text(vg, r.x + r.w / 2, r.y + 58, c.name, 14, {0.92, 0.93, 0.95, alpha}, 500, .CENTER)
		ob_agent_button(vg, c, {r.x + r.w / 2 - 50, r.y + 76, 100, 30}, 12, small = true)
	}

	// what happened, and the manual way
	msg := ""
	for c in agent_clients do if c.message != "" do msg = c.message
	if msg != "" do ob_text(vg, cx, body.y + body.h - 6, msg, 13, {0.55, 0.88, 0.66, 1}, 400, .CENTER)
	else {
		link := "Copy the command for Claude Code"
		lw2 := ob_width(vg, link, 13, 400)
		lr := Rect{cx - lw2 / 2 - 4, body.y + body.h - 18, lw2 + 8, 24}
		ob_text(vg, cx, body.y + body.h - 6, link, 13, TEXT_FG if hovered(lr) else {0.6, 0.61, 0.64, 1}, 400, .CENTER)
		if clicked(lr) {
			cmd := fmt.tprintf("claude mcp add --scope user %s -- '%s' mcp", MCP_NAME, mcp_executable())
			glfw.SetClipboardString(pf.window, strings.clone_to_cstring(cmd, context.temp_allocator))
			set_status("Command copied to the clipboard")
		}
	}
}

ob_agent_button :: proc(vg: ^nvg.Context, c: ^Agent_Client, r: Rect, size: f32, small := false) {
	if c.connected && !c.outdated {
		ob_button(vg, r, "Connected" if small else "Connected", .Success, "check", size)
		return
	}
	if !c.installed && !c.connected {
		fill_rect(vg, r, {1, 1, 1, 0.04}, 8)
		ob_text(vg, r.x + r.w / 2, r.y + r.h / 2, "Not found", size, {0.5, 0.51, 0.54, 1}, 500, .CENTER)
		return
	}
	text := "Update" if c.outdated else ("Connect" if small else fmt.tprintf("Connect %s", c.name))
	if ob_button(vg, r, text, .Quiet if small else .Primary, "", size) do agent_connect(c)
}

ob_step_features :: proc(vg: ^nvg.Context, body: Rect) {
	y := ob_heading(vg, body, "Feel right at home.", "The design features you expect, in a native app.")
	Item :: struct {
		icon, title, text: string,
	}
	Column :: struct {
		title: string,
		items: [5]Item,
	}
	columns := [3]Column {
		{"Draw and style", {
			{"shapes", "Frames, shapes, text, images", "Draw on an endless canvas with pages."},
			{"palette", "Fills, strokes and shadows", "Per-side borders, radii and opacity."},
			{"sparkles", "2,000 Lucide icons", "Built in, recoloured with one fill."},
			{"ruler", "Smart guides", "Edges and centres snap as you drag."},
			{"hand", "Trackpad first", "Pinch to zoom, two fingers to pan."},
		}},
		{"Build with structure", {
			{"layout-grid", "Flex layout", "Fill, hug, gap, padding and alignment."},
			{"component", "Components", "Instances override any property."},
			{"square-dashed", "Slots", "Drop content into an instance."},
			{"sun-moon", "Variables and themes", "Light, dark and any other axis."},
			{"layers", "Layers and pages", "Group, rename, reorder and hide."},
		}},
		{"Built for agents", {
			{"plug-zap", "MCP server", "Agents read, draw and screenshot."},
			{"braces", "Open .pen format", "Round-trip safe with pen.dev."},
			{"file-code", "Export code", "HTML + CSS and React + Tailwind."},
			{"download", "Export images", "PNG of any frame at any scale."},
			{"gauge", "Native speed", "OpenGL rendering, a few ms a frame."},
		}},
	}
	gap: f32 = 32
	cw := (body.w - gap * 2) / 3
	for col, i in columns {
		x := body.x + f32(i) * (cw + gap)
		ob_text(vg, x, y + 22, col.title, 17, TEXT_FG, 600)
		iy := y + 60
		for it in col.items {
			draw_lucide(vg, it.icon, x + 10, iy + 2, 18, {0.85, 0.86, 0.9, 1}, 1.7)
			ob_text(vg, x + 32, iy + 2, it.title, 15, TEXT_FG, 500)
			ob_text(vg, x + 32, iy + 24, it.text, 13, {0.6, 0.61, 0.64, 1})
			iy += 62
		}
	}
}

ob_step_start :: proc(vg: ^nvg.Context, body: Rect) {
	y := ob_heading(vg, body, "Start designing", "Open a file, start from scratch, or explore the sample design system.")
	Card :: struct {
		icon, title, text: string,
	}
	cards := [3]Card {
		{"file-plus", "New file", "An empty .pen file next to the open one."},
		{"layout-template", "Sample design system", "Sample Search: tokens, components, screens."},
		{"folder-open", "Open a file", "Any .pen file, from pen.dev or elsewhere."},
	}
	gap: f32 = 24
	cw := (body.w - gap * 2) / 3
	for c, i in cards {
		r := Rect{body.x + f32(i) * (cw + gap), y + 24, cw, 190}
		hover := hovered(r)
		fill_rect(vg, r, {1, 1, 1, 0.06 if hover else 0.035}, 14)
		stroke_rect(vg, r, {1, 1, 1, 0.14 if hover else 0.07}, 14)
		draw_lucide(vg, c.icon, r.x + r.w / 2, r.y + 62, 34, {0.92, 0.93, 0.95, 1}, 1.6)
		ob_text(vg, r.x + r.w / 2, r.y + 120, c.title, 17, TEXT_FG, 600, .CENTER)
		ob_text(vg, r.x + r.w / 2, r.y + 148, c.text, 13, {0.6, 0.61, 0.64, 1}, 400, .CENTER)
		if clicked(r) {
			switch i {
			case 0:
				onboarding_finish()
				new_document()
			case 1:
				path := fmt.tprintf("%s/sample-screens.pen", app.files_dir)
				if !os.exists(path) do path = fmt.tprintf("%s/../designs/sample-screens.pen", os.dir(mcp_executable()))
				onboarding_finish()
				if !open_in_tab(path) do set_status("The sample is not next to this build")
			case 2:
				onboarding_finish()
				open_file_dialog()
			}
			return
		}
	}

	// recent files
	if len(recents) == 0 do return
	ry := y + 24 + 190 + 36
	ob_text(vg, body.x, ry, "Recent", 13, {0.6, 0.61, 0.64, 1}, 500)
	ry += 18
	for r, i in recents {
		if i >= 3 do break
		row := Rect{body.x, ry + f32(i) * 36, body.w, 32}
		if hovered(row) do fill_rect(vg, row, HOVER_BG, 8)
		draw_lucide(vg, "file", row.x + 18, row.y + 16, 15, TEXT_DIM, 1.6)
		ob_text(vg, row.x + 38, row.y + 16, file_title(r.path), 14, TEXT_FG, 500)
		ob_text(vg, row.x + row.w - 12, row.y + 16, r.path, 12, TEXT_DIM, 400, .RIGHT)
		if clicked(row) {
			onboarding_finish()
			open_in_tab(r.path)
			return
		}
	}
}
