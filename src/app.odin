package agentic_design

import "engine"

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import nvg "nanovg"

// Window regions: tab bar on top, sidebar + tool strip on the left, inspector on the right.
TAB_H :: f32(44)
LEFT_W :: f32(260)
TOOLS_W :: f32(44)
RIGHT_W :: f32(300)

// Dark theme in the spirit of Paper.
ACCENT :: nvg.Color{0.05, 0.60, 1.00, 1}
PANEL_BG :: nvg.Color{0.118, 0.118, 0.118, 1} // #1E1E1E
TAB_BG :: nvg.Color{0.102, 0.102, 0.102, 1} // #1A1A1A
PANEL_LINE :: nvg.Color{0.18, 0.18, 0.18, 1}
FIELD_BG :: nvg.Color{0.165, 0.165, 0.165, 1} // #2A2A2A
HOVER_BG :: nvg.Color{1, 1, 1, 0.06}
ACTIVE_BG :: nvg.Color{1, 1, 1, 0.12}
TEXT_FG :: nvg.Color{0.91, 0.91, 0.91, 1}
TEXT_DIM :: nvg.Color{0.56, 0.56, 0.56, 1}
CANVAS_BG :: nvg.Color{0.157, 0.157, 0.157, 1} // #282828
GUIDE :: nvg.Color{1, 0.3, 0.45, 1}

Tool :: enum {
	Select,
	Hand,
	Frame,
	Rect,
	Ellipse,
	Text,
	Pen,
	Connector,
}

Drag_Kind :: enum {
	None,
	Pan,
	Move,
	Resize,
	Create,
	Marquee,
	Zoom,
	Gradient,
}

Drag :: struct {
	kind:        Drag_Kind,
	start_page:  [2]f32,
	start_mouse: [2]f32,
	last_page:   [2]f32,
	handle:      int,
	orig:        [4]f32,
	target:      int,
	pushed_undo: bool,
}

Rect :: struct {
	x, y, w, h: f32,
}

App :: struct {
	vg:            ^nvg.Context,
	doc:           engine.Document,
	file_path:     string,
	dirty:         bool,
	last_change:   time.Time,
	cam:           [2]f32,
	zoom:          f32,
	tool:          Tool,
	sel:           [dynamic]int, // uids
	hover:         int,
	drag:          Drag,
	editing:       int,
	undo_stack:    [dynamic]engine.Snapshot,
	redo_stack:    [dynamic]engine.Snapshot,
	screen:        [2]f32,
	dpr:           f32,
	mouse:         [2]f32,
	canvas:        Rect,
	draw_order:    [dynamic]int,
	last_click:    time.Time,
	last_click_p:  [2]f32,
	layers_scroll: f32,
	status:        string,
	status_time:   time.Time,
	status_reveal: string, // the toast's "Show in Finder" target (an export), or ""
	canvas_bg:     nvg.Color,
	guides:        [dynamic]Guide, // alignment lines shown while dragging
	move_roots:    [dynamic]int, // nodes being moved and where they started
	move_start:    [dynamic][2]f32,
	perf:          [8]f64, // milliseconds of the last frame's phases (debug)
	needs_layout:  bool, // the tree changed since the last layout pass
	page:          int, // shown page of the active document
	page_hidden:   map[int]bool, // top-level uids on other pages (rebuilt per frame)
	tabs:          [dynamic]Tab,
	tab:           int, // active tab, -1 = dashboard
	files_dir:     string, // where new files go
}

app: App

app_main :: proc(path: string) {
	context.allocator = big_allocator() // memory.odin: big blocks go back to the system when freed
	if !app_start(path) do return
	active_until = platform_time() + 1
	trimmed := false
	for !platform_should_close() && exit_signal == {} {
		free_all(context.temp_allocator)
		engine.font_atlas_trim(app.vg)
		wait := idle_wait()
		if wait > 0.1 && !trimmed {
			// the app is going quiet: hand back what the last burst of work freed
			memory_trim()
			trimmed = true
		} else if wait == 0 do trimmed = false
		if wait == 0 && shot.req == nil && !export_pending && !copy_png_pending {
			// full rate, but never faster than the display: vsync does not hold back a
			// window covered by others, and pointer events can come faster than frames.
			// A capture waiting for its frame is not paced, and an agent request cuts the
			// wait short (server.odin posts pace_wake): in a window started by an agent
			// macOS stretched this sleep to ~130 ms, and every request and screenshot
			// frame paid it (dogfooding D35).
			if rest := frame_started + 1 / pf.refresh - platform_time(); rest > 0.0005 do _ = sync.sema_wait_with_timeout(&pace_wake, time.Duration(rest * 1e9))
		}
		platform_poll(wait)
		app_frame()
	}
	app_stop()
}

// Everything before the first frame: the window, the renderer, fonts, settings, the
// documents to open, the control socket. False when there is no window or renderer.
app_start :: proc(path: string) -> bool {
	engine.lod_off = fs_env("AGENTIC_NO_LOD", context.temp_allocator) != ""
	use_big_allocator_for_temp()
	posix_ignore_sigpipe()

	// AGENTIC_WINDOW=1200x800 sets the window size (tests)
	win := [2]int{1440, 900}
	if v := fs_env("AGENTIC_WINDOW", context.temp_allocator); v != "" {
		if parts := strings.split(v, "x", context.temp_allocator); len(parts) == 2 {
			w, wok := strconv.parse_int(parts[0])
			h, hok := strconv.parse_int(parts[1])
			if wok && hok && w >= 400 && h >= 300 do win = {w, h}
		}
	}
	if !platform_init(win.x, win.y, "Agentic Design") {
		fmt.eprintln("could not create a window")
		return false
	}
	// AGENTIC_WINDOW_POS=40,60 places the window (two test windows side by side)
	if v := fs_env("AGENTIC_WINDOW_POS", context.temp_allocator); v != "" {
		if parts := strings.split(v, ",", context.temp_allocator); len(parts) == 2 {
			x, xok := strconv.parse_int(parts[0])
			y, yok := strconv.parse_int(parts[1])
			if xok && yok do platform_set_window_pos(x, y)
		}
	}
	app.vg = platform_gpu_create()
	if app.vg == nil {
		fmt.eprintln("could not start the renderer")
		return false
	}
	// the engine draws with the window's NanoVG context, on the open document (tabs are
	// swapped into app.doc), and skips the pages the window does not show
	engine.renderer = app.vg
	engine.current = &app.doc
	engine.hidden = &app.page_hidden
	engine.allocator = big_allocator()
	engine.font_atlas_init(app.vg)
	load_fonts(app.vg)
	app.zoom = 1
	app.cam = {-80, -60}
	app.canvas_bg = CANVAS_BG
	app.tab = -1
	app.files_dir = strings.clone(fs_dir(engine.absolute_path(path)))
	// no field takes the keyboard until the user picks one (0 would focus the first
	// field drawn, now the layer search)
	ui.tab_target = -1
	settings_load()
	recents_load()
	// launched to open documents (Finder, `open`): those instead of the scratch file
	launched_with_documents := len(fs_args()) <= 1 && len(pf.open_requests) > 0
	if launched_with_documents do handle_open_requests()
	if !launched_with_documents && path != "" && !open_in_tab(path) do set_status("Could not read %s as a .pen document", path)
	update_title()
	server_start()
	onboarding_maybe_start()
	whats_new_launch() // before the first app_log line: app.log tells a first run from an update
	install_exit_handlers()
	app_log("start: %s (port %d%s)", app.file_path, server_port(), ", opened by an agent" if pf.no_focus else "")

	return true
}

// One frame, once the platform has gathered its input (platform_poll): layout, agents'
// requests, input, autosave, the renders that wait for a frame, and drawing. The desktop's
// loop (app_main) calls it after pacing and idling; a browser host calls it from
// requestAnimationFrame.
app_frame :: proc() {
	frame_started = platform_time()
	frames_drawn += 1
	if platform_had_input() do active_until = platform_time() + ACTIVE_AFTER_INPUT
	fb := frame_size()
	if added := engine.fonts_refresh(); added != "" do set_status("Fonts installed: %s", added)
	if libraries_refresh() do set_status("A library changed on disk; its components were read again")

	// drawing instances re-lays out their components in place, so refresh
	// the boxes before requests read them and again before input
	t0 := time.tick_now()
	if app.needs_layout do engine.layout_invalidate()
	engine.layout_document(&app.doc)
	app.needs_layout = false
	ran := process_requests()
	if ran {
		active_until = platform_time() + ACTIVE_AFTER_INPUT
		agent_activity_touch()
	}
	agent_activity_tick()
	update_tick()
	share_tick()
	if app.needs_layout do engine.layout_invalidate()
	if ran || app.needs_layout {
		engine.layout_document(&app.doc)
		app.needs_layout = false
	}
	pages_sync()
	build_draw_order()
	t1 := time.tick_now()
	handle_drops()
	handle_open_requests()
	handle_input()
	if app.needs_layout {
		engine.layout_invalidate()
		engine.layout_document(&app.doc)
		app.needs_layout = false
	}
	autosave()
	t2 := time.tick_now()

	presence_tick(platform_time())
	if shot_pending() do render_screenshot()
	thumbs_render()
	export_render()
	copy_png_render()

	t3, t4, t5, t6 := frame_draw(fb, true)
	app.perf = {
		time.duration_milliseconds(time.tick_diff(t0, t1)), // layout x2 + requests
		time.duration_milliseconds(time.tick_diff(t1, t2)), // input + layout
		time.duration_milliseconds(time.tick_diff(t2, t3)), // canvas draw
		time.duration_milliseconds(time.tick_diff(t3, t4)), // ui draw
		time.duration_milliseconds(time.tick_diff(t4, t5)), // nvg flush
		time.duration_milliseconds(time.tick_diff(t5, t6)), // swap
		time.duration_milliseconds(time.tick_diff(t0, t6)),
		f64(app.vg.fs.width),
	}
}

// After the last frame: the exit is logged, unsaved documents are written, the window closes.
app_stop :: proc() {
	if exit_signal != {} do app_log("exit: signal %v", exit_signal)
	else do app_log("exit: window closed")
	if app.dirty do save_document(app.file_path)
	for &t in app.tabs do if t.dirty && t.path != "" {
		data := engine.doc_serialize(&t.doc)
		_ = fs_write(t.path, data)
		delete(data)
	}
	platform_shutdown()
}

// The window's size this frame: screen, framebuffer, pixel ratio and the canvas.
frame_size :: proc() -> [2]i32 {
	app.screen = platform_window_size()
	fb := platform_framebuffer_size()
	app.dpr = f32(fb.x) / max(app.screen.x, 1)
	app.mouse = pf.mouse
	// the canvas fills the window under the tab bar; the panels float over it (panels.odin)
	app.canvas = {0, TAB_H, app.screen.x, app.screen.y - TAB_H}
	return fb
}

drawing_frame: bool

// Draws the canvas and the interface and shows them. Returns the times after the canvas,
// the interface, the flush and the swap.
frame_draw :: proc(fb: [2]i32, capture: bool) -> (t3, t4, t5, t6: time.Tick) {
	drawing_frame = true
	defer drawing_frame = false
	if app.tab >= 0 {
		c := app.canvas
		engine.blur_prepare({xf = {app.zoom, 0, 0, app.zoom, c.x - app.cam.x * app.zoom, c.y - app.cam.y * app.zoom}, dpr = app.dpr, clip = {c.x, c.y, c.w, c.h}, fb = {fb.x, fb.y}, bg = app.canvas_bg, order = app.draw_order[:]})
	}
	bg := app.canvas_bg if app.tab >= 0 else PANEL_BG
	engine.gpu_window_begin(fb.x, fb.y, {bg.r, bg.g, bg.b, 1})
	nvg.BeginFrame(app.vg, app.screen.x, app.screen.y, app.dpr)
	if app.tab >= 0 do draw_canvas()
	t3 = time.tick_now()
	draw_ui()
	t4 = time.tick_now()
	nvg.EndFrame(app.vg)
	t5 = time.tick_now()
	if capture && view_shot_pending() do capture_view()
	platform_swap()
	t6 = time.tick_now()
	return
}

// While macOS resizes the window it runs its own event loop inside glfwPollEvents, so the
// main loop stops and the system stretches the last frame to the new size. GLFW reports
// each size step through its callbacks; they draw a frame at that size right away (no
// input or requests: those wait for the main loop, so nothing runs twice).
live_redraw :: proc() {
	// only from inside the event poll: elsewhere (a size set from code) the main loop
	// draws anyway, and the temporary memory it uses must not be freed here
	if !pf.polling || drawing_frame || app.vg == nil do return
	free_all(context.temp_allocator)
	fb := frame_size()
	if fb.x <= 0 || fb.y <= 0 do return
	engine.layout_document(&app.doc)
	build_draw_order()
	frame_draw(fb, false)
}

// The main loop draws frames back to back only while something is going on: for a moment
// after any input or agent request, and while a screenshot, export or thumbnail waits for a
// frame. Otherwise it sleeps until an event arrives (input, a request wakes it through
// platform_wake), and twice a second, on the half seconds the text carets blink on, for
// the timers (autosave, status messages, fonts installed meanwhile). Without this the
// loop spun at hundreds of frames a second whenever macOS stopped syncing it to the
// display (a window behind others), keeping a core busy and the laptop warm.
ACTIVE_AFTER_INPUT :: 0.5 // seconds of full frame rate after the last input

active_until: f64
pace_wake: sync.Sema // posted when a request arrives, so frame pacing does not hold it up
frame_started: f64
frames_drawn: int // since the last `perf` request

idle_wait :: proc() -> f64 {
	now := platform_time()
	if now < active_until || shot.req != nil || len(thumb_queue) > 0 || export_pending || copy_png_pending || app.needs_layout do return 0
	// agents' cursors and flashes (presence.odin): paced, since a covered window gets no vsync
	if busy, fast := presence_animating(now); busy {
		step := 1 / pf.refresh if fast else 1.0 / 20
		return max(frame_started + step - now, 0.001)
	}
	into := time.now()._nsec % 500_000_000 // carets blink on every half second
	return f64(500_000_000 - into) / 1e9 + 0.002
}

load_fonts :: proc(vg: ^nvg.Context) {
	platform_load_fonts(vg)
}

// Opens a document (in a tab); kept for callers that predate tabs.
open_document :: proc(path: string) -> bool {
	return open_in_tab(path)
}

// Creates an empty .pen file next to the current one and opens it.
new_document :: proc() {
	dir := fs_dir(app.file_path) if app.file_path != "" else app.files_dir
	for i in 1 ..< 1000 {
		path := fmt.tprintf("%s/untitled-%d.pen", dir, i)
		if fs_exists(path) do continue
		_ = fs_mkdir_all(dir)
		if fs_write(path, "{\n  \"version\": \"2.21\",\n  \"children\": []\n}\n") == nil {
			open_in_tab(path)
			set_status("Created %s", fs_base(path))
		} else {
			set_status("Could not create %s", path)
		}
		return
	}
}

set_status :: proc(format: string, args: ..any) {
	delete(app.status)
	app.status = fmt.aprintf(format, ..args)
	app.status_time = time.now()
	delete(app.status_reveal)
	app.status_reveal = ""
}

update_title :: proc() {
	title := fmt.ctprintf("%s%s — Agentic Design", fs_base(app.file_path), " •" if app.dirty else "") if app.tab >= 0 else "Agentic Design"
	platform_set_title(title)
}

mark_dirty :: proc() {
	app.needs_layout = true
	if !app.dirty {
		app.dirty = true
		update_title()
	}
	app.last_change = time.now()
}

autosave :: proc() {
	if app.dirty && time.duration_seconds(time.since(app.last_change)) > 1.0 {
		save_document(app.file_path)
	}
}

save_document :: proc(path: string) -> bool {
	if path == "" do return false
	engine.pages_prune(&app.doc)
	data := engine.doc_serialize(&app.doc)
	defer delete(data)
	_ = fs_mkdir_all(fs_dir(path))
	if err := fs_write(path, data); err != nil {
		set_status("Save failed: %v", err)
		return false
	}
	app.dirty = false
	update_title()
	if path == app.file_path {
		recents_touch(path)
		thumb_request(path)
	}
	return true
}

// ---------------------------------------------------------------- undo

push_undo :: proc() {
	if undo_suppressed {
		// inside a batch: its first snapshot is the one undo step
		mark_dirty()
		return
	}
	append(&app.undo_stack, engine.doc_snapshot(&app.doc))
	if len(app.undo_stack) > 200 {
		engine.free_snapshot(app.undo_stack[0])
		ordered_remove(&app.undo_stack, 0)
	}
	for s in app.redo_stack do engine.free_snapshot(s)
	clear(&app.redo_stack)
	mark_dirty()
}

undo :: proc() {
	if len(app.undo_stack) == 0 do return
	app.needs_layout = true
	append(&app.redo_stack, engine.doc_snapshot(&app.doc))
	snap := pop(&app.undo_stack)
	engine.doc_restore(&app.doc, snap)
	engine.free_snapshot(snap)
	prune_selection()
	mark_dirty()
}

redo :: proc() {
	if len(app.redo_stack) == 0 do return
	app.needs_layout = true
	append(&app.undo_stack, engine.doc_snapshot(&app.doc))
	snap := pop(&app.redo_stack)
	engine.doc_restore(&app.doc, snap)
	engine.free_snapshot(snap)
	prune_selection()
	mark_dirty()
}

prune_selection :: proc() {
	for i := 0; i < len(app.sel); {
		if n, _ := engine.doc_find_uid(&app.doc, app.sel[i]); n == nil do ordered_remove(&app.sel, i)
		else do i += 1
	}
	if n, _ := engine.doc_find_uid(&app.doc, app.editing); n == nil do app.editing = 0
}

// ---------------------------------------------------------------- coordinates

to_screen :: proc(p: [2]f32) -> [2]f32 {
	return {app.canvas.x, app.canvas.y} + (p - app.cam) * app.zoom
}

to_page :: proc(p: [2]f32) -> [2]f32 {
	return (p - {app.canvas.x, app.canvas.y}) / app.zoom + app.cam
}

zoom_at :: proc(screen_pt: [2]f32, factor: f32) {
	before := to_page(screen_pt)
	app.zoom = clamp(app.zoom * factor, 0.05, 64)
	after := to_page(screen_pt)
	app.cam += before - after
}

zoom_to_rect :: proc(r: [4]f32) {
	if r[2] <= 0 || r[3] <= 0 do return
	// fit in the part of the canvas the panels leave open, above the tool bar
	pad: f32 = 60
	v := canvas_visible()
	v.h -= TOOLBAR_H + PANEL_MARGIN
	zx := (v.w - pad * 2) / r[2]
	zy := (v.h - pad * 2) / r[3]
	app.zoom = clamp(min(zx, zy), 0.05, 4)
	center := [2]f32{r[0] + r[2] / 2, r[1] + r[3] / 2}
	app.cam = center - ([2]f32{v.x + v.w / 2, v.y + v.h / 2} - [2]f32{app.canvas.x, app.canvas.y}) / app.zoom
}

bounds_of :: proc(uids: []int) -> (r: [4]f32, ok: bool) {
	lo := [2]f32{math.F32_MAX, math.F32_MAX}
	hi := [2]f32{-math.F32_MAX, -math.F32_MAX}
	for uid in uids {
		n, _ := engine.doc_find_uid(&app.doc, uid)
		if n == nil do continue
		b := engine.node_page_box(n)
		lo = {min(lo.x, b[0]), min(lo.y, b[1])}
		hi = {max(hi.x, b[0] + b[2]), max(hi.y, b[1] + b[3])}
		ok = true
	}
	return {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y}, ok
}

all_uids :: proc(top_level_only: bool) -> []int {
	uids := make([dynamic]int, context.temp_allocator)
	for n in app.doc.nodes {
		if top_level_only && n.parent != 0 do continue
		if !on_page(n.uid) do continue
		append(&uids, n.uid)
	}
	return uids[:]
}

// ---------------------------------------------------------------- rendering

// Visible nodes in paint order. Children of instances are not painted
// (the component is), so they are left out.
build_draw_order :: proc() {
	clear(&app.draw_order)
	walk :: proc(parent: int, depth: int) {
		if depth > engine.MAX_DEPTH do return
		for cu in engine.children_of(&app.doc, parent) {
			n, _ := engine.doc_find_uid(&app.doc, cu)
			if n == nil || !n.enabled do continue
			if parent == 0 && app.page_hidden[cu] do continue
			append(&app.draw_order, n.uid)
			if n.kind == .Frame || n.kind == .Group || n.kind == .Ref do walk(n.uid, depth + 1)
		}
	}
	walk(0, 0)
}

draw_canvas :: proc() {
	vg := app.vg
	c := app.canvas
	nvg.Save(vg)
	nvg.Scissor(vg, c.x, c.y, c.w, c.h)

	if ui.show_grid && app.zoom >= 0.35 {
		step: f32 = 20
		for step * app.zoom < 14 do step *= 2
		tl := to_page({c.x, c.y})
		br := to_page({c.x + c.w, c.y + c.h})
		nvg.BeginPath(vg)
		for x := math.floor(tl.x / step) * step; x <= br.x; x += step {
			for y := math.floor(tl.y / step) * step; y <= br.y; y += step {
				p := to_screen({x, y})
				nvg.Rect(vg, p.x - 0.75, p.y - 0.75, 1.5, 1.5)
			}
		}
		nvg.FillColor(vg, {1, 1, 1, 0.12})
		nvg.Fill(vg)
	}

	// document
	nvg.Save(vg)
	nvg.Translate(vg, c.x, c.y)
	nvg.Scale(vg, app.zoom, app.zoom)
	nvg.Translate(vg, -app.cam.x, -app.cam.y)
	tl, br := to_page({c.x, c.y}), to_page({c.x + c.w, c.y + c.h})
	engine.cull_rect = {tl.x, tl.y, br.x - tl.x, br.y - tl.y}
	engine.blur_active = true
	engine.lod_scale = 0 if engine.lod_off else app.zoom
	for cu in engine.children_of(&app.doc, 0) {
		if app.page_hidden[cu] do continue
		if c, _ := engine.doc_find_uid(&app.doc, cu); c != nil do engine.draw_node_tree(vg, c, 1, 0)
	}
	engine.lod_scale = 0
	engine.blur_active = false
	engine.cull_rect = {}
	nvg.Restore(vg)
	draw_presence_effects(vg) // what agents touch flashes; placeholder frames glow

	// titles of top-level frames
	nvg.FontFace(vg, "ui")
	nvg.FontSize(vg, 12)
	nvg.TextAlign(vg, .LEFT, .BOTTOM)
	for &n in app.doc.nodes {
		if n.parent != 0 || !n.enabled || !(n.kind == .Frame || n.kind == .Group) || app.page_hidden[n.uid] do continue
		p := to_screen({n.x, n.y})
		if ui.focus == "name" && ui.focus_uid == n.uid && ui.rename_canvas {
			field(vg, n.uid, "name", "", {p.x - 4, p.y - 30, 200, 24}, n.name, placeholder = engine.node_label(&n))
			nvg.FontFace(vg, "ui")
			nvg.FontSize(vg, 12)
			nvg.TextAlign(vg, .LEFT, .BOTTOM)
			continue
		}
		nvg.FillColor(vg, ACCENT if is_selected(n.uid) else TEXT_DIM)
		nvg.Text(vg, p.x, p.y - 7, engine.node_label(&n))
	}

	draw_pixel_grid(vg)
	// hover + selection overlays
	if app.hover != 0 && !is_selected(app.hover) && app.drag.kind == .None {
		if n, _ := engine.doc_find_uid(&app.doc, app.hover); n != nil do outline_node(n, 1.5)
	}
	for uid in app.sel {
		if n, _ := engine.doc_find_uid(&app.doc, uid); n != nil do outline_node(n, 1)
	}
	if len(app.sel) == 1 && app.editing == 0 {
		if n, _ := engine.doc_find_uid(&app.doc, app.sel[0]); n != nil && resizable(n) && !pen_active() {
			for h in 0 ..< 8 {
				p := handle_pos(n, h)
				nvg.BeginPath(vg)
				nvg.Rect(vg, p.x - 4, p.y - 4, 8, 8)
				nvg.FillColor(vg, {1, 1, 1, 1})
				nvg.Fill(vg)
				nvg.StrokeColor(vg, ACCENT)
				nvg.StrokeWidth(vg, 1)
				nvg.Stroke(vg)
			}
		}
	}
	// smart guides
	for g in app.guides {
		nvg.BeginPath(vg)
		if g.vertical {
			a := to_screen({g.pos, g.lo})
			b := to_screen({g.pos, g.hi})
			nvg.MoveTo(vg, math.round(a.x) + 0.5, a.y)
			nvg.LineTo(vg, math.round(b.x) + 0.5, b.y)
		} else {
			a := to_screen({g.lo, g.pos})
			b := to_screen({g.hi, g.pos})
			nvg.MoveTo(vg, a.x, math.round(a.y) + 0.5)
			nvg.LineTo(vg, b.x, math.round(b.y) + 0.5)
		}
		nvg.StrokeColor(vg, GUIDE)
		nvg.StrokeWidth(vg, 1)
		nvg.Stroke(vg)
	}

	// size badge under a single selection, Paper style: "Fill 1440 × Fit 296"
	if len(app.sel) == 1 && app.drag.kind != .Pan {
		if n, _ := engine.doc_find_uid(&app.doc, app.sel[0]); n != nil {
			text := fmt.tprintf("%s × %s", size_label(n.width, n.w), size_label(n.height, n.h))
			nvg.FontFace(vg, "ui")
			nvg.FontSize(vg, 11)
			tw := nvg.TextBounds(vg, 0, 0, text) + 12
			p := to_screen({n.x + n.w / 2, n.y + n.h})
			nvg.BeginPath(vg)
			nvg.RoundedRect(vg, p.x - tw / 2, p.y + 8, tw, 18, 4)
			nvg.FillColor(vg, ACCENT)
			nvg.Fill(vg)
			nvg.TextAlign(vg, .CENTER, .MIDDLE)
			nvg.FillColor(vg, {1, 1, 1, 1})
			nvg.Text(vg, p.x, p.y + 17, text)
		}
	}
	// text caret
	if app.editing != 0 {
		if n, _ := engine.doc_find_uid(&app.doc, app.editing); n != nil && (int(time.now()._nsec / 500_000_000) % 2 == 0) {
			nvg.Save(vg)
			engine.set_font(vg, n)
			lines := strings.split(n.content, "\n", context.temp_allocator)
			last := lines[len(lines) - 1]
			w := nvg.TextBounds(vg, 0, 0, last)
			nvg.Restore(vg)
			p := to_screen({n.x + w, n.y + f32(len(lines) - 1) * n.font_size * engine.line_height_of(n)})
			nvg.BeginPath(vg)
			nvg.Rect(vg, p.x + 1, p.y, 1.5, n.font_size * engine.line_height_of(n) * app.zoom)
			nvg.FillColor(vg, ACCENT)
			nvg.Fill(vg)
		}
	}
	draw_gradient_handles(vg)
	draw_pen_overlay(vg)
	draw_connector_overlay(vg)
	draw_measurements(vg)
	// marquee, and the region of the zoom tool
	if (app.drag.kind == .Marquee || app.drag.kind == .Zoom) && (abs(app.mouse.x - to_screen(app.drag.start_page).x) >= 0.5 || abs(app.mouse.y - to_screen(app.drag.start_page).y) >= 0.5) {
		a := to_screen(app.drag.start_page)
		b := app.mouse
		col := ACCENT if app.drag.kind == .Marquee else nvg.Color{0.6, 0.6, 0.65, 1}
		nvg.BeginPath(vg)
		nvg.Rect(vg, min(a.x, b.x), min(a.y, b.y), abs(b.x - a.x), abs(b.y - a.y))
		nvg.FillColor(vg, {col.r, col.g, col.b, 0.08})
		nvg.Fill(vg)
		nvg.StrokeColor(vg, col)
		nvg.StrokeWidth(vg, 1)
		nvg.Stroke(vg)
	}
	draw_cursors(vg)
	nvg.Restore(vg)
}

MEASURE :: nvg.Color{0.95, 0.28, 0.13, 1}

// While ⌥ is held: distances from the selection to the layer under the pointer, or to the
// edges of a layer around it (pen.dev and Figma show the same).
draw_measurements :: proc(vg: ^nvg.Context) {
	if !alt_down() || len(app.sel) == 0 || app.drag.kind != .None || !canvas_hit(app.mouse) do return
	a, ok := bounds_of(app.sel[:])
	if !ok do return
	target := hit_test(to_page(app.mouse))
	if target == 0 || is_selected(target) {
		// over the selection itself: measure to its parent
		n, _ := engine.doc_find_uid(&app.doc, app.sel[0])
		if n == nil || n.parent == 0 do return
		target = n.parent
	}
	tn, _ := engine.doc_find_uid(&app.doc, target)
	if tn == nil do return
	b := engine.node_page_box(tn)
	// the other box, outlined
	p0, p1 := to_screen({b[0], b[1]}), to_screen({b[0] + b[2], b[1] + b[3]})
	nvg.BeginPath(vg)
	nvg.Rect(vg, p0.x + 0.5, p0.y + 0.5, p1.x - p0.x, p1.y - p0.y)
	nvg.StrokeColor(vg, MEASURE)
	nvg.StrokeWidth(vg, 1)
	nvg.Stroke(vg)
	// one axis at a time: a gap between the boxes, or the insets of one inside the other
	for axis in 0 ..< 2 {
		o := 1 - axis
		alo, ahi := a[axis], a[axis] + a[axis + 2]
		blo, bhi := b[axis], b[axis] + b[axis + 2]
		// where across the other axis the line runs: the middle of the overlap, or of the selection
		lo, hi := max(a[o], b[o]), min(a[o] + a[o + 2], b[o] + b[o + 2])
		across := (lo + hi) / 2 if lo < hi else a[o] + a[o + 2] / 2
		switch {
		case ahi <= blo: measure_line(vg, axis, ahi, blo, across)
		case bhi <= alo: measure_line(vg, axis, bhi, alo, across)
		case blo <= alo && ahi <= bhi:
			measure_line(vg, axis, blo, alo, across)
			measure_line(vg, axis, ahi, bhi, across)
		case alo <= blo && bhi <= ahi:
			measure_line(vg, axis, alo, blo, across)
			measure_line(vg, axis, bhi, ahi, across)
		}
	}
}

// A distance along `axis` (0: x, 1: y) from `from` to `to`, drawn at `across`, with its label.
measure_line :: proc(vg: ^nvg.Context, axis: int, from, to, across: f32) {
	if to - from < 0.01 do return
	p, q: [2]f32
	p[axis], p[1 - axis] = from, across
	q[axis], q[1 - axis] = to, across
	sp, sq := to_screen(p), to_screen(q)
	nvg.BeginPath(vg)
	nvg.MoveTo(vg, math.round(sp.x) + 0.5, math.round(sp.y) + 0.5)
	nvg.LineTo(vg, math.round(sq.x) + 0.5, math.round(sq.y) + 0.5)
	nvg.StrokeColor(vg, MEASURE)
	nvg.StrokeWidth(vg, 1)
	nvg.Stroke(vg)
	text := engine.num_text(to - from)
	nvg.FontFace(vg, "ui")
	nvg.FontSize(vg, 11)
	tw := nvg.TextBounds(vg, 0, 0, text) + 10
	m := (sp + sq) / 2
	if axis == 1 do m.x += tw / 2 + 4
	else do m.y += 12
	nvg.BeginPath(vg)
	nvg.RoundedRect(vg, m.x - tw / 2, m.y - 9, tw, 18, 4)
	nvg.FillColor(vg, MEASURE)
	nvg.Fill(vg)
	nvg.TextAlign(vg, .CENTER, .MIDDLE)
	nvg.FillColor(vg, {1, 1, 1, 1})
	nvg.Text(vg, m.x, m.y, text)
}

size_label :: proc(spec: engine.Size_Spec, computed: f32) -> string {
	switch spec.mode {
	case .Fit: return fmt.tprintf("Fit %s", engine.num_text(computed))
	case .Fill: return fmt.tprintf("Fill %s", engine.num_text(computed))
	case .Fixed:
	}
	return engine.num_text(computed)
}

// Selection colours as in pen.dev: magenta for a component origin, violet for an
// instance, blue for everything else.
COMPONENT_COLOR :: nvg.Color{0.85, 0.27, 0.93, 1}
INSTANCE_COLOR :: nvg.Color{0.55, 0.42, 1.0, 1}

selection_color :: proc(n: ^engine.Node) -> nvg.Color {
	if n.reusable do return COMPONENT_COLOR
	if n.kind == .Ref do return INSTANCE_COLOR
	return ACCENT
}

outline_node :: proc(n: ^engine.Node, width: f32) {
	if n.flow == .Connector && outline_connector(n, width) do return
	vg := app.vg
	a := to_screen({n.x, n.y})
	if n.w * app.zoom < 0.5 && n.h * app.zoom < 0.5 do return // see draw_node_tree
	nvg.BeginPath(vg)
	if m, tr := engine.node_transform(n); tr {
		// turned or mirrored: outline the box (or ellipse) where it is drawn
		steps := 48 if n.kind == .Ellipse else 4
		for i in 0 ..< steps {
			p: [2]f32
			if n.kind == .Ellipse {
				t := f32(i) / f32(steps) * 2 * math.PI
				p = {n.x + n.w / 2 * (1 + math.cos(t)), n.y + n.h / 2 * (1 + math.sin(t))}
			} else {
				p = [4][2]f32{{n.x, n.y}, {n.x + n.w, n.y}, {n.x + n.w, n.y + n.h}, {n.x, n.y + n.h}}[i]
			}
			s := to_screen(engine.xform_point(m, p))
			if i == 0 do nvg.MoveTo(vg, s.x, s.y)
			else do nvg.LineTo(vg, s.x, s.y)
		}
		nvg.ClosePath(vg)
		nvg.StrokeColor(vg, selection_color(n))
		nvg.StrokeWidth(vg, width)
		nvg.Stroke(vg)
		return
	}
	if n.kind == .Ellipse {
		nvg.Ellipse(vg, a.x + n.w * app.zoom / 2, a.y + n.h * app.zoom / 2, n.w * app.zoom / 2, n.h * app.zoom / 2)
	}
	nvg.Rect(vg, a.x, a.y, n.w * app.zoom, n.h * app.zoom)
	nvg.StrokeColor(vg, selection_color(n))
	nvg.StrokeWidth(vg, width)
	nvg.Stroke(vg)
}

// Resize handles work on the axis-aligned box; turned or mirrored layers are resized
// from the inspector.
resizable :: proc(n: ^engine.Node) -> bool {
	if n.flow == .Connector do return false // its route follows its ends
	_, tr := engine.node_transform(n)
	return !tr
}

is_selected :: proc(uid: int) -> bool {
	for s in app.sel do if s == uid do return true
	return false
}

// Handles: 0 TL, 1 T, 2 TR, 3 R, 4 BR, 5 B, 6 BL, 7 L (screen space)
handle_pos :: proc(n: ^engine.Node, h: int) -> [2]f32 {
	a := to_screen({n.x, n.y})
	b := to_screen({n.x + n.w, n.y + n.h})
	m := (a + b) / 2
	switch h {
	case 0: return a
	case 1: return {m.x, a.y}
	case 2: return {b.x, a.y}
	case 3: return {b.x, m.y}
	case 4: return b
	case 5: return {m.x, b.y}
	case 6: return {a.x, b.y}
	case 7: return {a.x, m.y}
	}
	return a
}
