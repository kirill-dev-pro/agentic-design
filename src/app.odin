package agentic_design

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import gl "vendor:OpenGL"
import "vendor:glfw"
import "fontstash"
import nvg "nanovg"
import nvgl "nanovg/gl"

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
	doc:           Document,
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
	undo_stack:    [dynamic][]Node,
	redo_stack:    [dynamic][]Node,
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
	canvas_bg:     nvg.Color,
	guides:        [dynamic]Guide, // alignment lines shown while dragging
	move_roots:    [dynamic]int, // nodes being moved and where they started
	move_start:    [dynamic][2]f32,
	perf:          [8]f64, // milliseconds of the last frame's phases (debug)
	needs_layout:  bool, // the tree changed since the last layout pass
	theme:         map[string]string, // chosen value per theme axis
	page:          int, // shown page of the active document
	page_hidden:   map[int]bool, // top-level uids on other pages (rebuilt per frame)
	tabs:          [dynamic]Tab,
	tab:           int, // active tab, -1 = dashboard
	files_dir:     string, // where new files go
}

app: App

app_main :: proc(path: string) {
	posix_ignore_sigpipe()

	if !platform_init(1440, 900, "Agentic Design") {
		fmt.eprintln("could not create a window")
		return
	}
	gl.load_up_to(3, 2, glfw.gl_set_proc_address)

	app.vg = nvgl.Create({.ANTI_ALIAS, .STENCIL_STROKES})
	font_atlas_init(app.vg)
	load_fonts(app.vg)
	app.zoom = 1
	app.cam = {-80, -60}
	app.canvas_bg = CANVAS_BG
	app.tab = -1
	app.files_dir = strings.clone(os.dir(absolute_path(path)))
	settings_load()
	recents_load()
	if path != "" && !open_in_tab(path) do set_status("Could not read %s as a .pen document", path)
	update_title()
	server_start()
	onboarding_maybe_start()

	for !platform_should_close() {
		free_all(context.temp_allocator)
		font_atlas_trim(app.vg)
		platform_poll()
		app.screen = platform_window_size()
		fb := platform_framebuffer_size()
		app.dpr = f32(fb.x) / max(app.screen.x, 1)
		app.mouse = pf.mouse
		app.canvas = {LEFT_W + TOOLS_W, TAB_H, app.screen.x - LEFT_W - TOOLS_W - RIGHT_W, app.screen.y - TAB_H}

		// drawing instances re-lays out their components in place, so refresh
		// the boxes before requests read them and again before input
		t0 := time.tick_now()
		layout_document(&app.doc)
		app.needs_layout = false
		if process_requests() || app.needs_layout {
			layout_document(&app.doc)
			app.needs_layout = false
		}
		pages_sync()
		build_draw_order()
		t1 := time.tick_now()
		handle_drops()
		handle_input()
		if app.needs_layout {
			layout_document(&app.doc)
			app.needs_layout = false
		}
		autosave()
		t2 := time.tick_now()

		if shot_pending() do render_screenshot()
		thumbs_render()
		export_render()

		if app.tab >= 0 {
			c := app.canvas
			blur_prepare({xf = {app.zoom, 0, 0, app.zoom, c.x - app.cam.x * app.zoom, c.y - app.cam.y * app.zoom}, dpr = app.dpr, clip = {c.x, c.y, c.w, c.h}, fb = {fb.x, fb.y}, bg = app.canvas_bg})
		}
		gl.Viewport(0, 0, fb.x, fb.y)
		bg := app.canvas_bg if app.tab >= 0 else PANEL_BG
		gl.ClearColor(bg.r, bg.g, bg.b, 1)
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.STENCIL_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		nvg.BeginFrame(app.vg, app.screen.x, app.screen.y, app.dpr)
		if app.tab >= 0 do draw_canvas()
		t3 := time.tick_now()
		draw_ui()
		t4 := time.tick_now()
		nvg.EndFrame(app.vg)
		t5 := time.tick_now()
		if view_shot_pending() do capture_view()
		platform_swap()
		t6 := time.tick_now()
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
	if app.dirty do save_document(app.file_path)
	for &t in app.tabs do if t.dirty && t.path != "" {
		data := doc_serialize(&t.doc)
		_ = os.write_entire_file(t.path, data)
		delete(data)
	}
	platform_shutdown()
}

// Works around two bugs in Odin's fontstash/nanovg ports. When the glyph atlas fills up,
// fontstash doubles it and asks nanovg for a new texture, but nanovg uploads the old,
// smaller pixel buffer into it (a crash inside glTexImage2D). And nothing ever resets the
// atlas, so glyphs rasterised at every zoom level accumulate until the texture is huge.
font_atlas_init :: proc(vg: ^nvg.Context) {
	vg.fs.callbackResize = proc(data: rawptr, w, h: int) {
		ctx := (^nvg.Context)(data)
		old := ctx.fontImages[ctx.fontImageIdx]
		// no pixels: fontstash marks the used area dirty and re-uploads it on the next flush
		ctx.fontImages[ctx.fontImageIdx] = ctx.params.renderCreateTexture(ctx.params.userPtr, .Alpha, w, h, {}, nil)
		if old != 0 do ctx.params.renderDeleteTexture(ctx.params.userPtr, old)
	}
}

FONT_ATLAS_MAX :: 2048

// Between frames: once the atlas has outgrown its budget, start over with an empty one.
font_atlas_trim :: proc(vg: ^nvg.Context) {
	if vg.fs.width <= FONT_ATLAS_MAX && vg.fs.height <= FONT_ATLAS_MAX do return
	fontstash.ResetAtlas(&vg.fs, FONT_ATLAS_MAX, FONT_ATLAS_MAX)
	fontstash.__atlasReset(&vg.fs, FONT_ATLAS_MAX, FONT_ATLAS_MAX)
	vg.fs.callbackResize(vg, FONT_ATLAS_MAX, FONT_ATLAS_MAX)
}

load_fonts :: proc(vg: ^nvg.Context) {
	nvg.CreateFont(vg, "sans", "/System/Library/Fonts/Supplemental/Arial.ttf")
	nvg.CreateFont(vg, "sans-bold", "/System/Library/Fonts/Supplemental/Arial Bold.ttf")
	// The interface uses the system font; fall back to Arial when it cannot be read.
	if nvg.CreateFont(vg, "ui", "/System/Library/Fonts/SFNS.ttf") < 0 {
		nvg.CreateFont(vg, "ui", "/System/Library/Fonts/Supplemental/Arial.ttf")
	}
}

// Opens a document (in a tab); kept for callers that predate tabs.
open_document :: proc(path: string) -> bool {
	return open_in_tab(path)
}

// Creates an empty .pen file next to the current one and opens it.
new_document :: proc() {
	dir := os.dir(app.file_path) if app.file_path != "" else app.files_dir
	for i in 1 ..< 1000 {
		path := fmt.tprintf("%s/untitled-%d.pen", dir, i)
		if os.exists(path) do continue
		_ = os.make_directory_all(dir)
		if os.write_entire_file(path, "{\n  \"version\": \"2.21\",\n  \"children\": []\n}\n") == nil {
			open_in_tab(path)
			set_status("Created %s", os.base(path))
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
}

update_title :: proc() {
	title := fmt.ctprintf("%s%s — Agentic Design", os.base(app.file_path), " •" if app.dirty else "") if app.tab >= 0 else "Agentic Design"
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
	pages_prune(&app.doc)
	data := doc_serialize(&app.doc)
	defer delete(data)
	_ = os.make_directory_all(os.dir(path))
	if err := os.write_entire_file(path, data); err != nil {
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
	append(&app.undo_stack, doc_snapshot(&app.doc))
	if len(app.undo_stack) > 200 {
		free_snapshot(app.undo_stack[0])
		ordered_remove(&app.undo_stack, 0)
	}
	for s in app.redo_stack do free_snapshot(s)
	clear(&app.redo_stack)
	mark_dirty()
}

free_snapshot :: proc(snap: []Node) {
	for &n in snap do node_free(&n)
	delete(snap)
}

undo :: proc() {
	if len(app.undo_stack) == 0 do return
	app.needs_layout = true
	append(&app.redo_stack, doc_snapshot(&app.doc))
	snap := pop(&app.undo_stack)
	doc_restore(&app.doc, snap)
	free_snapshot(snap)
	prune_selection()
	mark_dirty()
}

redo :: proc() {
	if len(app.redo_stack) == 0 do return
	app.needs_layout = true
	append(&app.undo_stack, doc_snapshot(&app.doc))
	snap := pop(&app.redo_stack)
	doc_restore(&app.doc, snap)
	free_snapshot(snap)
	prune_selection()
	mark_dirty()
}

prune_selection :: proc() {
	for i := 0; i < len(app.sel); {
		if n, _ := doc_find_uid(&app.doc, app.sel[i]); n == nil do ordered_remove(&app.sel, i)
		else do i += 1
	}
	if n, _ := doc_find_uid(&app.doc, app.editing); n == nil do app.editing = 0
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
	pad: f32 = 60
	zx := (app.canvas.w - pad * 2) / r[2]
	zy := (app.canvas.h - pad * 2) / r[3]
	app.zoom = clamp(min(zx, zy), 0.05, 4)
	center := [2]f32{r[0] + r[2] / 2, r[1] + r[3] / 2}
	app.cam = center - [2]f32{app.canvas.w, app.canvas.h} / (2 * app.zoom)
}

bounds_of :: proc(uids: []int) -> (r: [4]f32, ok: bool) {
	lo := [2]f32{math.F32_MAX, math.F32_MAX}
	hi := [2]f32{-math.F32_MAX, -math.F32_MAX}
	for uid in uids {
		n, _ := doc_find_uid(&app.doc, uid)
		if n == nil do continue
		b := node_page_box(n)
		lo = {min(lo.x, b[0]), min(lo.y, b[1])}
		hi = {max(hi.x, b[0] + b[2]), max(hi.y, b[1] + b[3])}
		ok = true
	}
	return {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y}, ok
}

// ---------------------------------------------------------------- transforms

// An affine transform as NanoVG stores it: x' = a x + c y + e, y' = b x + d y + f.
Xform :: [6]f32

XFORM_IDENTITY :: Xform{1, 0, 0, 1, 0, 0}

// a · b: b applies first.
xform_mul :: proc(a, b: Xform) -> Xform {
	return {
		a[0] * b[0] + a[2] * b[1],
		a[1] * b[0] + a[3] * b[1],
		a[0] * b[2] + a[2] * b[3],
		a[1] * b[2] + a[3] * b[3],
		a[0] * b[4] + a[2] * b[5] + a[4],
		a[1] * b[4] + a[3] * b[5] + a[5],
	}
}

xform_inverse :: proc(m: Xform) -> Xform {
	det := m[0] * m[3] - m[1] * m[2]
	if abs(det) < 1e-12 do return XFORM_IDENTITY
	a, b, c, d := m[3] / det, -m[1] / det, -m[2] / det, m[0] / det
	return {a, b, c, d, -(a * m[4] + c * m[5]), -(b * m[4] + d * m[5])}
}

xform_point :: proc(m: Xform, p: [2]f32) -> [2]f32 {
	return {m[0] * p.x + m[2] * p.y + m[4], m[1] * p.x + m[3] * p.y + m[5]}
}

// Where a node's untransformed page box is drawn: its own rotation and flips and those
// of its ancestors, each around that node's top-left corner (as draw_node_tree applies
// them).
node_transform :: proc(n: ^Node) -> (m: Xform, transformed: bool) {
	chain: [MAX_DEPTH]^Node
	count := 0
	for cur := n; cur != nil && count < MAX_DEPTH; {
		chain[count] = cur
		count += 1
		if cur.parent == 0 do break
		cur, _ = doc_find_uid(&app.doc, cur.parent)
	}
	m = XFORM_IDENTITY
	for i := count - 1; i >= 0; i -= 1 {
		a := chain[i]
		if a.rotation == 0 && !a.flip_x && !a.flip_y do continue
		transformed = true
		t := -a.rotation * math.PI / 180
		cs, sn := math.cos(t), math.sin(t)
		sx: f32 = -1 if a.flip_x else 1
		sy: f32 = -1 if a.flip_y else 1
		// T(x, y) · R · S · T(-x, -y)
		local := Xform{cs * sx, sn * sx, -sn * sy, cs * sy, 0, 0}
		local[4] = a.x - (local[0] * a.x + local[2] * a.y)
		local[5] = a.y - (local[1] * a.x + local[3] * a.y)
		m = xform_mul(m, local)
	}
	return
}

// The corners of a node as drawn, in page coordinates (TL, TR, BR, BL).
node_corners :: proc(n: ^Node) -> (c: [4][2]f32, transformed: bool) {
	c = {{n.x, n.y}, {n.x + n.w, n.y}, {n.x + n.w, n.y + n.h}, {n.x, n.y + n.h}}
	m, tr := node_transform(n)
	if !tr do return c, false
	for &p in c do p = xform_point(m, p)
	return c, true
}

// The page-space box around a node as drawn.
node_page_box :: proc(n: ^Node) -> [4]f32 {
	c, tr := node_corners(n)
	if !tr do return {n.x, n.y, n.w, n.h}
	lo, hi := c[0], c[0]
	for p in c[1:] {
		lo = {min(lo.x, p.x), min(lo.y, p.y)}
		hi = {max(hi.x, p.x), max(hi.y, p.y)}
	}
	return {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y}
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
		if depth > MAX_DEPTH do return
		for cu in children_of(&app.doc, parent) {
			n, _ := doc_find_uid(&app.doc, cu)
			if n == nil || !n.enabled do continue
			if parent == 0 && app.page_hidden[cu] do continue
			append(&app.draw_order, n.uid)
			if n.kind == .Frame || n.kind == .Group || n.kind == .Ref do walk(n.uid, depth + 1)
		}
	}
	walk(0, 0)
}

to_nvg :: proc(c: Color, opacity: f32 = 1) -> nvg.Color {
	return {f32(c[0]) / 255, f32(c[1]) / 255, f32(c[2]) / 255, f32(c[3]) / 255 * opacity}
}

// The part of the page the canvas shows (page coordinates); nodes outside it are not
// drawn. Zero while rendering offscreen (screenshots, thumbnails, export).
cull_rect: [4]f32

// True when a node's box, grown by its stroke and shadow, can be seen.
node_visible :: proc(n: ^Node) -> bool {
	if cull_rect[2] <= 0 || n.rotation != 0 || n.flip_x || n.flip_y do return true
	m := n.stroke_width + 2
	if n.shadow.has do m += abs(n.shadow.offset.x) + abs(n.shadow.offset.y) + n.shadow.blur + n.shadow.spread
	for e in n.effects[:n.neffects] {
		if e.kind == .Drop_Shadow do m = max(m, n.stroke_width + 2 + abs(e.offset.x) + abs(e.offset.y) + e.blur + e.spread)
		if e.kind == .Blur do m = max(m, n.stroke_width + 2 + e.blur * 1.5)
	}
	return n.x - m < cull_rect[0] + cull_rect[2] && n.x + n.w + m > cull_rect[0] &&
	       n.y - m < cull_rect[1] + cull_rect[3] && n.y + n.h + m > cull_rect[1]
}

// Draws a node and, for frames and groups, its children.
draw_node_tree :: proc(vg: ^nvg.Context, n: ^Node, alpha: f32, depth: int, force := false) {
	if (!n.enabled && !force) || depth > MAX_DEPTH do return
	// capturing what lies behind a background blur: stop at its layer
	if blur_stopped do return
	if blur_stop != 0 && n.uid == blur_stop {
		blur_stopped = true
		return
	}
	// Off-screen nodes are skipped: besides the work, their glyphs would take atlas space
	// (at high zoom a few large glyphs fill it and the rest of the text disappears).
	// Children may overflow an unclipped container, so only leaves and clipping frames
	// are culled by their own box.
	if !node_visible(n) {
		#partial switch n.kind {
		case .Group, .Ref: // children may lie outside
		case .Frame: if n.clip do return
		case: return
		}
	}
	if blur_active && n.uid != blur_self {
		if r, ok := blur_layer[n.uid]; ok {
			draw_blurred_layer(vg, r, alpha)
			return
		}
	}
	doc := &app.doc
	a := alpha * n.opacity
	nvg.Save(vg)
	defer nvg.Restore(vg)
	nvg.GlobalAlpha(vg, a)
	// rotation (counter-clockwise) and flips apply to the node and everything inside it,
	// both around its top-left corner as pen.dev renders them
	saved_cull := cull_rect
	defer cull_rect = saved_cull
	if n.rotation != 0 || n.flip_x || n.flip_y {
		nvg.Translate(vg, n.x, n.y)
		if n.rotation != 0 do nvg.Rotate(vg, -n.rotation * math.PI / 180)
		if n.flip_x || n.flip_y do nvg.Scale(vg, -1 if n.flip_x else 1, -1 if n.flip_y else 1)
		nvg.Translate(vg, -n.x, -n.y)
		// the children land turned or mirrored, so their own boxes cannot be culled
		cull_rect = {}
	}
	// NanoVG's Odin port traps on a closed path whose points all coincide, so boxes
	// without any extent (empty fit_content frames, zero-size shapes) are not outlined.
	flat := n.w < 1e-3 && n.h < 1e-3

	switch n.kind {
	case .Frame, .Rectangle:
		if !flat && node_visible(n) do draw_box(vg, n)
		if n.kind == .Frame {
			if n.clip do nvg.IntersectScissor(vg, n.x, n.y, n.w, n.h)
			for cu in children_for_layout(doc, n.uid) {
				if c, _ := doc_find_uid(doc, cu); c != nil do draw_node_tree(vg, c, a, depth + 1)
			}
		}
	case .Group:
		for cu in children_for_layout(doc, n.uid) {
			if c, _ := doc_find_uid(doc, cu); c != nil do draw_node_tree(vg, c, a, depth + 1)
		}
	case .Ellipse:
		if flat do return
		cx, cy := n.x + n.w / 2, n.y + n.h / 2
		draw_drop_shadows(vg, n, min(n.w, n.h) / 2)
		nvg.BeginPath(vg)
		nvg.Ellipse(vg, cx, cy, n.w / 2, n.h / 2)
		fill_backdrop(vg, n)
		fill_paints(vg, n)
		draw_inner_shadows(vg, n, min(n.w, n.h) / 2)
		if n.has_stroke && n.stroke_width > 0 {
			inset: f32
			#partial switch n.stroke_align {
			case .Inner: inset = n.stroke_width / 2
			case .Outer: inset = -n.stroke_width / 2
			}
			nvg.BeginPath(vg)
			nvg.Ellipse(vg, cx, cy, max(n.w / 2 - inset, 0), max(n.h / 2 - inset, 0))
			nvg.StrokeColor(vg, to_nvg(n.stroke))
			nvg.StrokeWidth(vg, n.stroke_width)
			nvg.Stroke(vg)
		}
	case .Path, .Icon:
		if n.kind == .Icon && len(n.cmds) == 0 {
			draw_placeholder(vg, n, "icon")
			return
		}
		if len(n.cmds) == 0 || flat do return
		sx := n.w / n.view_box[2]
		sy := n.h / n.view_box[3]
		if n.kind == .Icon {
			// uniform scale, centred, like an SVG with preserveAspectRatio
			s := min(sx, sy)
			nvg.Translate(vg, n.x + (n.w - 24 * s) / 2, n.y + (n.h - 24 * s) / 2)
			nvg.Scale(vg, s, s)
			color := to_nvg(n.fill if n.has_fill else Color{0, 0, 0, 255})
			// lucide draws dots as zero-length segments with round caps ("M12 8h.01");
			// NanoVG drops those, so they are filled as circles instead
			dots := make([dynamic][2]f32, context.temp_allocator)
			nvg.BeginPath(vg)
			for c, i in n.cmds {
				if c.kind == .Move && i + 1 < len(n.cmds) && n.cmds[i + 1].kind == .Line {
					next_is_new := i + 2 >= len(n.cmds) || n.cmds[i + 2].kind == .Move
					d := n.cmds[i + 1].p[2] - c.p[2]
					if next_is_new && d.x * d.x + d.y * d.y < 0.25 {
						append(&dots, c.p[2])
						continue
					}
				}
				if c.kind == .Line && i > 0 && n.cmds[i - 1].kind == .Move && len(dots) > 0 && dots[len(dots) - 1] == n.cmds[i - 1].p[2] do continue
				path_cmd(vg, c, {0, 0}, 1, 1)
			}
			nvg.LineCap(vg, .ROUND)
			nvg.LineJoin(vg, .ROUND)
			nvg.StrokeColor(vg, color)
			nvg.StrokeWidth(vg, 2)
			nvg.Stroke(vg)
			if len(dots) > 0 {
				nvg.BeginPath(vg)
				for d in dots do nvg.Circle(vg, d.x, d.y, 1)
				nvg.FillColor(vg, color)
				nvg.Fill(vg)
			}
			return
		}
		nvg.BeginPath(vg)
		tp :: proc(p: [2]f32, n: ^Node, sx, sy: f32) -> [2]f32 {
			return {n.x + (p.x - n.view_box[0]) * sx, n.y + (p.y - n.view_box[1]) * sy}
		}
		for c in n.cmds {
			switch c.kind {
			case .Move:
				p := tp(c.p[2], n, sx, sy)
				nvg.MoveTo(vg, p.x, p.y)
			case .Line:
				p := tp(c.p[2], n, sx, sy)
				nvg.LineTo(vg, p.x, p.y)
			case .Cubic:
				c1, c2, p := tp(c.p[0], n, sx, sy), tp(c.p[1], n, sx, sy), tp(c.p[2], n, sx, sy)
				nvg.BezierTo(vg, c1.x, c1.y, c2.x, c2.y, p.x, p.y)
			case .Quad:
				c1, p := tp(c.p[0], n, sx, sy), tp(c.p[1], n, sx, sy)
				nvg.QuadTo(vg, c1.x, c1.y, p.x, p.y)
			case .Close:
				nvg.ClosePath(vg)
			}
		}
		nvg.LineCap(vg, LINE_CAPS[n.line_cap])
		nvg.LineJoin(vg, LINE_JOINS[n.line_join])
		fill_and_stroke(vg, n)
	case .Text:
		draw_text(vg, n)
	case .Ref:
		root := ghost_root_of(doc, n.uid)
		if root == nil {
			draw_placeholder(vg, n, fmt.tprintf("ref %s", n.ref))
			return
		}
		draw_node_tree(vg, root, a, depth + 1, force = true)
	case .Other:
		draw_placeholder(vg, n, n.type_name)
	}
}

LINE_CAPS := [Line_Cap]nvg.LineCapType{.Butt = .BUTT, .Round = .ROUND, .Square = .SQUARE}
LINE_JOINS := [Line_Join]nvg.LineCapType{.Miter = .MITER, .Round = .ROUND, .Bevel = .BEVEL}

// Adds one parsed path command, mapping its points from `origin` with a scale.
path_cmd :: proc(vg: ^nvg.Context, c: Path_Cmd, origin: [2]f32, sx, sy: f32) {
	tp :: proc(p, origin: [2]f32, sx, sy: f32) -> [2]f32 {
		return {(p.x - origin.x) * sx, (p.y - origin.y) * sy}
	}
	switch c.kind {
	case .Move:
		p := tp(c.p[2], origin, sx, sy)
		nvg.MoveTo(vg, p.x, p.y)
	case .Line:
		p := tp(c.p[2], origin, sx, sy)
		nvg.LineTo(vg, p.x, p.y)
	case .Cubic:
		c1, c2, p := tp(c.p[0], origin, sx, sy), tp(c.p[1], origin, sx, sy), tp(c.p[2], origin, sx, sy)
		nvg.BezierTo(vg, c1.x, c1.y, c2.x, c2.y, p.x, p.y)
	case .Quad:
		c1, p := tp(c.p[0], origin, sx, sy), tp(c.p[1], origin, sx, sy)
		nvg.QuadTo(vg, c1.x, c1.y, p.x, p.y)
	case .Close:
		nvg.ClosePath(vg)
	}
}

// Fills and strokes a rectangle-like node with its corner radii.
draw_box :: proc(vg: ^nvg.Context, n: ^Node) {
	draw_drop_shadows(vg, n, n.radius[0])
	nvg.BeginPath(vg)
	rounded_rect(vg, n.x, n.y, n.w, n.h, n.radius)
	fill_backdrop(vg, n)
	if n.nfills > 0 {
		fill_paints(vg, n)
	} else if n.has_fill {
		if n.image_url == "" || !image_fill(vg, n) {
			nvg.FillColor(vg, to_nvg(n.fill))
			nvg.Fill(vg)
		}
	}
	draw_inner_shadows(vg, n, n.radius[0])
	if n.has_stroke && n.stroke_per_side && n.stroke_width > 0 {
		// per-side widths, drawn inside the box like CSS borders: the rounded box with
		// the inner box (inset by each side's width) cut out
		t, rt, b, l := n.stroke_sides[0], n.stroke_sides[1], n.stroke_sides[2], n.stroke_sides[3]
		r := n.radius
		inner := [4]f32{max(r[0] - max(t, l), 0), max(r[1] - max(t, rt), 0), max(r[2] - max(b, rt), 0), max(r[3] - max(b, l), 0)}
		nvg.BeginPath(vg)
		if r == {} {
			// square corners: one band per side (a cut-out would leave an antialiasing
			// hairline along the sides without a border)
			if t > 0 do nvg.Rect(vg, n.x, n.y, n.w, t)
			if b > 0 do nvg.Rect(vg, n.x, n.y + n.h - b, n.w, b)
			if l > 0 do nvg.Rect(vg, n.x, n.y + t, l, n.h - t - b)
			if rt > 0 do nvg.Rect(vg, n.x + n.w - rt, n.y + t, rt, n.h - t - b)
		} else {
			rounded_rect(vg, n.x, n.y, n.w, n.h, r)
			if n.w - l - rt > 0 && n.h - t - b > 0 {
				rounded_rect(vg, n.x + l, n.y + t, n.w - l - rt, n.h - t - b, inner)
				nvg.PathWinding(vg, .CW)
			}
		}
		nvg.FillColor(vg, to_nvg(n.stroke))
		nvg.Fill(vg)
	} else if n.has_stroke && n.stroke_width > 0 {
		inset: f32
		switch n.stroke_align {
		case .Center:
		case .Inner: inset = n.stroke_width / 2
		case .Outer: inset = -n.stroke_width / 2
		}
		r := n.radius
		for &v in r do v = max(v - inset, 0)
		nvg.BeginPath(vg)
		rounded_rect(vg, n.x + inset, n.y + inset, n.w - inset * 2, n.h - inset * 2, r)
		nvg.StrokeColor(vg, to_nvg(n.stroke))
		nvg.StrokeWidth(vg, n.stroke_width)
		nvg.Stroke(vg)
	}
}

rounded_rect :: proc(vg: ^nvg.Context, x, y, w, h: f32, r: [4]f32) {
	if r == {} do nvg.Rect(vg, x, y, w, h)
	else do nvg.RoundedRectVarying(vg, x, y, w, h, r[0], r[1], r[2], r[3])
}

fill_and_stroke :: proc(vg: ^nvg.Context, n: ^Node) {
	fill_paints(vg, n)
	if n.has_stroke && n.stroke_width > 0 {
		nvg.StrokeColor(vg, to_nvg(n.stroke))
		nvg.StrokeWidth(vg, n.stroke_width)
		nvg.Stroke(vg)
	}
}

draw_text :: proc(vg: ^nvg.Context, n: ^Node) {
	set_font(vg, n)
	nvg.FillColor(vg, to_nvg(n.fill if n.has_fill else Color{0, 0, 0, 255}))
	halign: nvg.AlignHorizontal = .LEFT
	anchor := n.x
	switch n.text_align {
	case .Left, .Justify:
	case .Center:
		halign = .CENTER
		anchor = n.x + n.w / 2
	case .Right:
		halign = .RIGHT
		anchor = n.x + n.w
	}
	nvg.TextAlign(vg, halign, .TOP)
	// lines were broken at document scale by the layout pass; draw them one by one so
	// wrapping and widths do not drift with the zoom level
	rows := text_lines(n, n.w if n.growth != .Auto else -1)
	y := n.y + half_leading(vg, n)
	if n.growth == .Fixed_Width_Height && n.text_valign != .Start {
		free := n.h - f32(len(rows)) * n.font_size * line_height_of(n)
		y += free / 2 if n.text_valign == .Center else free
	}
	justify := n.text_align == .Justify && n.growth != .Auto
	for row, i in rows {
		a, b := clamp(row[0], 0, len(n.content)), clamp(row[1], 0, len(n.content))
		if b > a {
			line := n.content[a:b]
			// the last line of a paragraph keeps its natural spacing
			last := i == len(rows) - 1 || strings.has_suffix(line, "\n") || (b < len(n.content) && n.content[b] == '\n')
			if justify && !last && draw_justified(vg, n, y, line) {
				if n.underline || n.strikethrough do text_decoration(vg, n, anchor, y, halign, line, n.w)
			} else {
				nvg.Text(vg, anchor, y, line)
				if n.underline || n.strikethrough do text_decoration(vg, n, anchor, y, halign, line)
			}
		}
		y += n.font_size * line_height_of(n)
	}
}

// One line spread over the box width: the space left over goes between the words.
// Returns false for a line with a single word, which is drawn as it is.
draw_justified :: proc(vg: ^nvg.Context, n: ^Node, y: f32, line: string) -> bool {
	words := strings.fields(strings.trim_space(line), context.temp_allocator)
	if len(words) < 2 do return false
	widths := make([]f32, len(words), context.temp_allocator)
	total: f32
	for w, i in words {
		widths[i] = nvg.TextBounds(vg, 0, 0, w)
		total += widths[i]
	}
	gap := (n.w - total) / f32(len(words) - 1)
	x := n.x
	for w, i in words {
		nvg.Text(vg, x, y, w)
		x += widths[i] + gap
	}
	return true
}

// Underline and strikethrough for one drawn line of text.
text_decoration :: proc(vg: ^nvg.Context, n: ^Node, anchor, y: f32, halign: nvg.AlignHorizontal, line: string, width: f32 = -1) {
	w := width if width >= 0 else nvg.TextBounds(vg, 0, 0, line)
	x := anchor
	#partial switch halign {
	case .CENTER: x -= w / 2
	case .RIGHT: x -= w
	}
	thick := max(n.font_size / 14, 0.5)
	lh := n.font_size * line_height_of(n)
	base := y + (lh - n.font_size) / 2 + n.font_size * 0.92 // roughly the baseline
	nvg.BeginPath(vg)
	if n.underline do nvg.Rect(vg, x, base + thick, w, thick)
	if n.strikethrough do nvg.Rect(vg, x, base - n.font_size * 0.3, w, thick)
	nvg.Fill(vg)
}

// Node types this app does not render (scripts, browsers, ...).
draw_placeholder :: proc(vg: ^nvg.Context, n: ^Node, label: string) {
	if n.w < 1e-3 && n.h < 1e-3 do return
	if n.has_fill {
		nvg.BeginPath(vg)
		nvg.Rect(vg, n.x, n.y, n.w, n.h)
		nvg.FillColor(vg, to_nvg(n.fill, 0.35))
		nvg.Fill(vg)
	}
	nvg.BeginPath(vg)
	nvg.Rect(vg, n.x + 0.5, n.y + 0.5, n.w - 1, n.h - 1)
	nvg.StrokeColor(vg, {0.5, 0.5, 0.55, 0.6})
	nvg.StrokeWidth(vg, 1)
	nvg.Stroke(vg)
	if n.w >= 40 && n.h >= 14 {
		nvg.FontFace(vg, "sans")
		nvg.FontSize(vg, 10)
		nvg.TextAlign(vg, .CENTER, .MIDDLE)
		nvg.FillColor(vg, {0.4, 0.4, 0.45, 0.9})
		nvg.Save(vg)
		nvg.IntersectScissor(vg, n.x, n.y, n.w, n.h)
		nvg.Text(vg, n.x + n.w / 2, n.y + n.h / 2, label)
		nvg.Restore(vg)
	}
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
	cull_rect = {tl.x, tl.y, br.x - tl.x, br.y - tl.y}
	blur_active = true
	for cu in children_of(&app.doc, 0) {
		if app.page_hidden[cu] do continue
		if c, _ := doc_find_uid(&app.doc, cu); c != nil do draw_node_tree(vg, c, 1, 0)
	}
	blur_active = false
	cull_rect = {}
	nvg.Restore(vg)

	// titles of top-level frames
	nvg.FontFace(vg, "ui")
	nvg.FontSize(vg, 12)
	nvg.TextAlign(vg, .LEFT, .BOTTOM)
	for &n in app.doc.nodes {
		if n.parent != 0 || !n.enabled || !(n.kind == .Frame || n.kind == .Group) || app.page_hidden[n.uid] do continue
		p := to_screen({n.x, n.y})
		if ui.focus == "name" && ui.focus_uid == n.uid && ui.rename_canvas {
			field(vg, n.uid, "name", "", {p.x - 4, p.y - 30, 200, 24}, n.name, placeholder = node_label(&n))
			nvg.FontFace(vg, "ui")
			nvg.FontSize(vg, 12)
			nvg.TextAlign(vg, .LEFT, .BOTTOM)
			continue
		}
		nvg.FillColor(vg, ACCENT if is_selected(n.uid) else TEXT_DIM)
		nvg.Text(vg, p.x, p.y - 7, node_label(&n))
	}

	draw_pixel_grid(vg)
	// hover + selection overlays
	if app.hover != 0 && !is_selected(app.hover) && app.drag.kind == .None {
		if n, _ := doc_find_uid(&app.doc, app.hover); n != nil do outline_node(n, 1.5)
	}
	for uid in app.sel {
		if n, _ := doc_find_uid(&app.doc, uid); n != nil do outline_node(n, 1)
	}
	if len(app.sel) == 1 && app.editing == 0 {
		if n, _ := doc_find_uid(&app.doc, app.sel[0]); n != nil && resizable(n) {
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
		if n, _ := doc_find_uid(&app.doc, app.sel[0]); n != nil {
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
		if n, _ := doc_find_uid(&app.doc, app.editing); n != nil && (int(time.now()._nsec / 500_000_000) % 2 == 0) {
			nvg.Save(vg)
			set_font(vg, n)
			lines := strings.split(n.content, "\n", context.temp_allocator)
			last := lines[len(lines) - 1]
			w := nvg.TextBounds(vg, 0, 0, last)
			nvg.Restore(vg)
			p := to_screen({n.x + w, n.y + f32(len(lines) - 1) * n.font_size * line_height_of(n)})
			nvg.BeginPath(vg)
			nvg.Rect(vg, p.x + 1, p.y, 1.5, n.font_size * line_height_of(n) * app.zoom)
			nvg.FillColor(vg, ACCENT)
			nvg.Fill(vg)
		}
	}
	draw_gradient_handles(vg)
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
	nvg.Restore(vg)
}

MEASURE :: nvg.Color{0.95, 0.28, 0.13, 1}

// While ⌥ is held: distances from the selection to the layer under the pointer, or to the
// edges of a layer around it (pen.dev and Figma show the same).
draw_measurements :: proc(vg: ^nvg.Context) {
	if !alt_down() || len(app.sel) == 0 || app.drag.kind != .None || !in_rect(app.canvas, app.mouse) do return
	a, ok := bounds_of(app.sel[:])
	if !ok do return
	target := hit_test(to_page(app.mouse))
	if target == 0 || is_selected(target) {
		// over the selection itself: measure to its parent
		n, _ := doc_find_uid(&app.doc, app.sel[0])
		if n == nil || n.parent == 0 do return
		target = n.parent
	}
	tn, _ := doc_find_uid(&app.doc, target)
	if tn == nil do return
	b := node_page_box(tn)
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
	text := num_text(to - from)
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

size_label :: proc(spec: Size_Spec, computed: f32) -> string {
	switch spec.mode {
	case .Fit: return fmt.tprintf("Fit %s", num_text(computed))
	case .Fill: return fmt.tprintf("Fill %s", num_text(computed))
	case .Fixed:
	}
	return num_text(computed)
}

// Selection colours as in pen.dev: magenta for a component origin, violet for an
// instance, blue for everything else.
COMPONENT_COLOR :: nvg.Color{0.85, 0.27, 0.93, 1}
INSTANCE_COLOR :: nvg.Color{0.55, 0.42, 1.0, 1}

selection_color :: proc(n: ^Node) -> nvg.Color {
	if n.reusable do return COMPONENT_COLOR
	if n.kind == .Ref do return INSTANCE_COLOR
	return ACCENT
}

outline_node :: proc(n: ^Node, width: f32) {
	vg := app.vg
	a := to_screen({n.x, n.y})
	if n.w * app.zoom < 0.5 && n.h * app.zoom < 0.5 do return // see draw_node_tree
	nvg.BeginPath(vg)
	if m, tr := node_transform(n); tr {
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
			s := to_screen(xform_point(m, p))
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
resizable :: proc(n: ^Node) -> bool {
	_, tr := node_transform(n)
	return !tr
}

is_selected :: proc(uid: int) -> bool {
	for s in app.sel do if s == uid do return true
	return false
}

// Handles: 0 TL, 1 T, 2 TR, 3 R, 4 BR, 5 B, 6 BL, 7 L (screen space)
handle_pos :: proc(n: ^Node, h: int) -> [2]f32 {
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
