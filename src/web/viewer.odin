package viewer

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:sys/wasm/js"
import "core:time"
import "../engine"
import nvg "../nanovg"

// A .pen viewer in a web page: the engine of the app, drawing with the browser's WebGPU
// into a canvas (web/index.html, web/viewer.js; build with tools/build_web.sh).
//
// A page has no files: the engine asks for each file it reads (files_js.odin) and this
// host has the page fetch them from its server, by URL path ("/designs/a.pen", and
// "/designs/images/b.png" for an image the document names "./images/b.png"). When they
// arrive, the document or its libraries are read again; an image is drawn as soon as it
// is there. Input is the page's: it calls the procs exported below.

foreign import page "viewer"

@(default_calling_convention = "contextless")
foreign page {
	// fetches the files (one path per line), hands each to viewer_file (one that is
	// missing as empty) and then calls viewer_files_done
	page_fetch :: proc(paths: string) ---
	// what the page shows: {"title", "pages": [names], "page", "themes": [{"name",
	// "values", "value"}], "zoom", "draw_ms", "missing": [paths], "frames": [{"uid",
	// "name", "box": [x, y, w, h]}] (the page's top-level layers), "sel": {"uid", "id", "name", "type", "x",
	// "y", "w", "h", "component"} or null, "fonts": [{"family", "missing"}]}
	page_info :: proc(json: string) ---
	page_error :: proc(message: string) ---
}

CANVAS_BG :: nvg.Color{0.157, 0.157, 0.157, 1} // #282828, as in the app

V: struct {
	vg:          ^nvg.Context,
	doc:         engine.Document,
	path:        string, // the document's URL path
	loaded:      bool,
	page:        int,
	hidden:      map[int]bool, // top-level layers not on the page shown
	order:       [dynamic]int, // layers in paint order (for the blurs)
	zoom:        f32,
	cam:         [2]f32, // the page point at the canvas's top left
	fit_pending: bool,
	auto_fit:    bool, // the view is the fitted one: fitted again when files arrive (text grows)
	redraw:      bool,
	fetching:    bool,
	missing:     [dynamic]string, // files the server did not have
	size:        [2]f32, // the canvas in CSS pixels
	dpr:         f32,
	draw_ms:     f64, // the last frame's layout and drawing (CPU; the GPU runs after)
	sel:         int, // the selected layer's uid, 0 for none
}

SEL_COLOR :: nvg.Color{0.05, 0.60, 1.00, 1} // the app's ACCENT

main :: proc() {
	V.zoom = 1
	engine.gpu_create_async({canvas = "#canvas"}, proc(vg: ^nvg.Context) {
		if vg == nil {
			page_error("This browser has no WebGPU.")
			return
		}
		V.vg = vg
		engine.renderer = vg
		engine.current = &V.doc
		engine.hidden = &V.hidden
		engine.font_atlas_init(vg)
		// text without a family: Noto Sans, the font pen.dev's renderer falls back on
		for name, i in ([2]string{"sans", "sans-bold"}) {
			if inst, ok := engine.varfont_instance(engine.NOTO_SANS, 0, {{"wght", 700 if i == 1 else 400}}); ok {
				nvg.CreateFontMem(vg, name, inst, true)
			}
		}
		V.redraw = true
	})
}

// The page's frame (requestAnimationFrame): lays out, draws when something changed and
// asks for the files the engine could not read.
@(export)
step :: proc(dt: f64) -> bool {
	free_all(context.temp_allocator)
	if V.vg == nil do return true
	engine.font_atlas_trim(V.vg)
	rect := js.get_bounding_client_rect("canvas")
	size := [2]f32{f32(rect.width), f32(rect.height)}
	dpr := f32(js.device_pixel_ratio())
	if size != V.size || dpr != V.dpr {
		V.size, V.dpr = size, dpr
		V.redraw = true
	}
	// (nothing to do between changes: the page stays as drawn)
	fb := [2]i32{i32(math.round(size.x * dpr)), i32(math.round(size.y * dpr))}
	if V.redraw && fb.x > 0 && fb.y > 0 {
		V.redraw = false
		t0 := time.tick_now()
		if V.loaded {
			engine.layout_document(&V.doc)
			pages_sync()
			if V.fit_pending {
				fit()
				V.fit_pending = false
			}
		}
		draw(fb)
		V.draw_ms = time.duration_milliseconds(time.tick_since(t0))
		report()
	}
	if !V.fetching && len(engine.files_wanted) > 0 {
		paths := strings.join(engine.files_wanted[:], "\n", context.temp_allocator)
		for p in engine.files_wanted do delete(p)
		clear(&engine.files_wanted)
		V.fetching = true
		page_fetch(paths)
	}
	return true
}

// Reads the document (once its file is there).
load :: proc() {
	data, ok := engine.read_file(V.path, context.temp_allocator)
	if !ok do return // asked for: viewer_files_done comes back here
	engine.doc_destroy(&V.doc)
	clear(&V.hidden)
	engine.fonts_add_document_dir(V.path)
	if !engine.doc_load(&V.doc, string(data)) {
		page_error(fmt.tprintf("%s is not a .pen document.", V.path))
		return
	}
	V.doc.path = strings.clone(V.path)
	engine.doc_load_imports(&V.doc, V.path)
	engine.layout_invalidate()
	V.loaded = true
	V.page = 0
	V.sel = 0
	V.fit_pending = true
	V.auto_fit = true
	V.redraw = true
}

// Library layers are on no page; with several pages, the others' layers are hidden.
pages_sync :: proc() {
	clear(&V.hidden)
	pages := engine.doc_pages(&V.doc)
	V.page = clamp(V.page, 0, len(pages) - 1)
	for &n in V.doc.nodes {
		if n.parent != 0 do continue
		if n.imported || len(pages) > 1 && engine.page_of_top(&V.doc, n.id) != V.page do V.hidden[n.uid] = true
	}
	clear(&V.order)
	walk :: proc(parent: int, depth: int) {
		if depth > engine.MAX_DEPTH do return
		for cu in engine.children_of(&V.doc, parent) {
			n, _ := engine.doc_find_uid(&V.doc, cu)
			if n == nil || !n.enabled do continue
			if parent == 0 && V.hidden[cu] do continue
			append(&V.order, n.uid)
			if n.kind == .Frame || n.kind == .Group || n.kind == .Ref do walk(n.uid, depth + 1)
		}
	}
	walk(0, 0)
}

// Zooms to the page's layers, at most 100 %.
fit :: proc() {
	lo := [2]f32{math.F32_MAX, math.F32_MAX}
	hi := [2]f32{-math.F32_MAX, -math.F32_MAX}
	found := false
	for &n in V.doc.nodes {
		if n.parent != 0 || V.hidden[n.uid] || !n.enabled do continue
		b := engine.node_page_box(&n)
		lo = {min(lo.x, b[0]), min(lo.y, b[1])}
		hi = {max(hi.x, b[0] + b[2]), max(hi.y, b[1] + b[3])}
		found = true
	}
	if !found || V.size.x <= 0 || V.size.y <= 0 do return
	pad: f32 = 40
	box := hi - lo
	V.zoom = clamp(min((V.size.x - pad * 2) / max(box.x, 1), (V.size.y - pad * 2) / max(box.y, 1)), 0.02, 1)
	V.cam = (lo + hi) / 2 - V.size / (2 * V.zoom)
	V.redraw = true
}

draw :: proc(fb: [2]i32) {
	vg := V.vg
	engine.gpu_window_begin(fb.x, fb.y, CANVAS_BG)
	nvg.BeginFrame(vg, V.size.x, V.size.y, V.dpr)
	if V.loaded {
		draw_scene(V.cam, V.zoom, V.size, V.dpr, fb, CANVAS_BG, true)
		// the names of the top-level frames, as on the app's canvas
		z := V.zoom
		nvg.FontFace(vg, "sans")
		nvg.FontSize(vg, 12)
		nvg.TextAlign(vg, .LEFT, .BOTTOM)
		nvg.FillColor(vg, {1, 1, 1, 0.45})
		for &n in V.doc.nodes {
			if n.parent != 0 || !n.enabled || V.hidden[n.uid] || !(n.kind == .Frame || n.kind == .Group) do continue
			nvg.FillColor(vg, SEL_COLOR if n.uid == V.sel else nvg.Color{1, 1, 1, 0.45})
			nvg.Text(vg, (n.x - V.cam.x) * z, (n.y - V.cam.y) * z - 7, engine.node_label(&n))
		}
		draw_selection()
	}
	nvg.EndFrame(vg)
	engine.gpu_present()
}

// The page's layers seen from `cam` at `zoom` in a `size` (CSS pixels) area. Call inside
// a NanoVG frame; `visible` culls what is outside the area (off for exports).
draw_scene :: proc(cam: [2]f32, z: f32, size: [2]f32, dpr: f32, fb: [2]i32, bg: nvg.Color, visible: bool) {
	vg := V.vg
	engine.blur_prepare({xf = {z, 0, 0, z, -cam.x * z, -cam.y * z}, dpr = dpr, clip = {0, 0, size.x, size.y}, fb = {fb.x, fb.y}, bg = bg, order = V.order[:]})
	nvg.Save(vg)
	nvg.Scale(vg, z, z)
	nvg.Translate(vg, -cam.x, -cam.y)
	engine.cull_rect = {cam.x, cam.y, size.x / z, size.y / z} if visible else {}
	engine.blur_active = true
	engine.lod_scale = z
	for cu in engine.children_of(&V.doc, 0) {
		if V.hidden[cu] do continue
		if n, _ := engine.doc_find_uid(&V.doc, cu); n != nil do engine.draw_node_tree(vg, n, 1, 0)
	}
	engine.lod_scale = 0
	engine.blur_active = false
	engine.cull_rect = {}
	nvg.Restore(vg)
}

// The selected layer's outline, as drawn (turned layers too), and its size below it.
draw_selection :: proc() {
	if V.sel == 0 do return
	n, _ := engine.doc_find_uid(&V.doc, V.sel)
	if n == nil {
		V.sel = 0
		return
	}
	vg := V.vg
	c, _ := engine.node_corners(n)
	screen :: proc(p: [2]f32) -> [2]f32 {return (p - V.cam) * V.zoom}
	nvg.BeginPath(vg)
	p0 := screen(c[0])
	nvg.MoveTo(vg, p0.x, p0.y)
	for p in c[1:] {
		q := screen(p)
		nvg.LineTo(vg, q.x, q.y)
	}
	nvg.ClosePath(vg)
	nvg.StrokeColor(vg, SEL_COLOR)
	nvg.StrokeWidth(vg, 1.5)
	nvg.Stroke(vg)
	// "W × H" in a pill under the layer
	lo := [2]f32{math.F32_MAX, math.F32_MAX}
	hi := [2]f32{-math.F32_MAX, -math.F32_MAX}
	for p in c {
		q := screen(p)
		lo = {min(lo.x, q.x), min(lo.y, q.y)}
		hi = {max(hi.x, q.x), max(hi.y, q.y)}
	}
	label := fmt.tprintf("%s × %s", num(n.w), num(n.h))
	nvg.FontFace(vg, "sans")
	nvg.FontSize(vg, 11)
	tw := nvg.TextBounds(vg, 0, 0, label, nil)
	w := tw + 12
	x := (lo.x + hi.x) / 2 - w / 2
	y := hi.y + 6
	nvg.BeginPath(vg)
	nvg.RoundedRect(vg, x, y, w, 18, 4)
	nvg.FillColor(vg, SEL_COLOR)
	nvg.Fill(vg)
	nvg.FillColor(vg, {1, 1, 1, 1})
	nvg.TextAlign(vg, .CENTER, .MIDDLE)
	nvg.Text(vg, x + w / 2, y + 9.5, label)
}

// A size as the app's inspector shows it: whole numbers plain, others to two decimals.
num :: proc(v: f32) -> string {
	if abs(v - math.round(v)) < 0.005 do return fmt.tprintf("%d", int(math.round(v)))
	return fmt.tprintf("%.2f", v)
}

// Tells the page what its bar shows.
report :: proc() {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"title":`)
	engine.json_write_string(&b, engine.file_title(V.path))
	strings.write_string(&b, `,"pages":[`)
	if V.loaded do for p, i in engine.doc_pages(&V.doc) {
		if i > 0 do strings.write_byte(&b, ',')
		engine.json_write_string(&b, p.name)
	}
	fmt.sbprintf(&b, `],"page":%d,"themes":[`, V.page)
	if V.loaded do for a, i in engine.doc_theme_axes(&V.doc) {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, `{"name":`)
		engine.json_write_string(&b, a.name)
		strings.write_string(&b, `,"values":[`)
		for v, k in a.values {
			if k > 0 do strings.write_byte(&b, ',')
			engine.json_write_string(&b, v)
		}
		strings.write_string(&b, `],"value":`)
		// an axis the viewer has not set shows its first value
		engine.json_write_string(&b, engine.theme[a.name] if a.name in engine.theme else (a.values[0] if len(a.values) > 0 else ""))
		strings.write_byte(&b, '}')
	}
	fmt.sbprintf(&b, `],"zoom":%.4f,"draw_ms":%.2f,"missing":[`, V.zoom, V.draw_ms)
	for p, i in V.missing {
		if i > 0 do strings.write_byte(&b, ',')
		engine.json_write_string(&b, p)
	}
	strings.write_string(&b, `],"frames":[`)
	k := 0
	if V.loaded do for cu in engine.children_of(&V.doc, 0) {
		if V.hidden[cu] do continue
		n, _ := engine.doc_find_uid(&V.doc, cu)
		if n == nil || !n.enabled do continue
		if k > 0 do strings.write_byte(&b, ',')
		k += 1
		fmt.sbprintf(&b, `{{"uid":%d,"name":`, n.uid)
		engine.json_write_string(&b, engine.node_label(n))
		box := engine.node_page_box(n)
		fmt.sbprintf(&b, `,"box":[%s,%s,%s,%s]}}`, num(box[0]), num(box[1]), num(box[2]), num(box[3]))
	}
	strings.write_string(&b, `],"sel":`)
	n: ^engine.Node
	if V.loaded && V.sel != 0 do n, _ = engine.doc_find_uid(&V.doc, V.sel)
	if n == nil {
		strings.write_string(&b, "null")
	} else {
		fmt.sbprintf(&b, `{{"uid":%d,"id":`, n.uid)
		engine.json_write_string(&b, n.id)
		strings.write_string(&b, `,"name":`)
		engine.json_write_string(&b, engine.node_label(n))
		strings.write_string(&b, `,"type":`)
		engine.json_write_string(&b, engine.KIND_LABELS[n.kind] if n.kind != .Other else n.type_name)
		fmt.sbprintf(&b, `,"x":%s,"y":%s,"w":%s,"h":%s,"component":`, num(n.x), num(n.y), num(n.w), num(n.h))
		comp: ^engine.Node
		if n.kind == .Ref do comp, _ = engine.doc_find(&V.doc, n.ref)
		if comp != nil do engine.json_write_string(&b, engine.node_label(comp))
		else do strings.write_string(&b, "null")
		strings.write_byte(&b, '}')
	}
	// the families text is set in, and whether each is drawn with a stand-in
	strings.write_string(&b, `,"fonts":[`)
	if V.loaded {
		seen := make(map[string]bool, 16, context.temp_allocator)
		for &t in V.doc.nodes {
			if t.kind != .Text || t.font_family == "" || V.hidden[top_of(t.uid)] do continue
			key := strings.to_lower(t.font_family, context.temp_allocator)
			if key in seen do continue
			seen[key] = true
			if len(seen) > 1 do strings.write_byte(&b, ',')
			strings.write_string(&b, `{"family":`)
			engine.json_write_string(&b, t.font_family)
			fmt.sbprintf(&b, `,"missing":%v}}`, engine.font_source(t.font_family) == .Missing)
		}
	}
	strings.write_string(&b, "]}")
	page_info(strings.to_string(b))
}

// The top-level layer a layer is in.
top_of :: proc(uid: int) -> int {
	cur := uid
	for _ in 0 ..< engine.MAX_DEPTH {
		n, _ := engine.doc_find_uid(&V.doc, cur)
		if n == nil || n.parent == 0 do return cur
		cur = n.parent
	}
	return cur
}

// The deepest layer under the page point, children before their container.
hit_test :: proc(p: [2]f32) -> int {
	// the names above top-level frames pick the frame
	for &n in V.doc.nodes {
		if n.parent != 0 || !n.enabled || V.hidden[n.uid] || !(n.kind == .Frame || n.kind == .Group) do continue
		if p.x >= n.x && p.x <= n.x + 160 / V.zoom && p.y >= n.y - 18 / V.zoom && p.y < n.y do return n.uid
	}
	slop := 2 / V.zoom
	#reverse for uid in V.order {
		n, _ := engine.doc_find_uid(&V.doc, uid)
		if n == nil do continue
		q := p
		if m, tr := engine.node_transform(n); tr do q = engine.xform_point(engine.xform_inverse(m), q)
		if q.x < n.x - slop || q.y < n.y - slop || q.x > n.x + n.w + slop || q.y > n.y + n.h + slop do continue
		if n.kind == .Ellipse {
			d := (q - [2]f32{n.x + n.w / 2, n.y + n.h / 2}) / [2]f32{n.w / 2 + slop, n.h / 2 + slop}
			if d.x * d.x + d.y * d.y > 1 do continue
		}
		return uid
	}
	return 0
}

// ---------------------------------------------------------------- called by the page

@(private = "file")
ctx :: proc "contextless" () -> runtime.Context {
	return runtime.default_context()
}

// Memory for the page to write a path or a file's bytes into.
@(export)
viewer_alloc :: proc "contextless" (n: int) -> rawptr {
	context = ctx()
	return raw_data(make([]u8, max(n, 1)))
}

// A file the engine asked for: `data` (from viewer_alloc) is the engine's from now on,
// `path` is freed. An empty file is one the server did not have.
@(export)
viewer_file :: proc "contextless" (path: [^]u8, path_len: int, data: [^]u8, data_len: int) {
	context = ctx()
	p := string(path[:path_len])
	if data_len == 0 do append(&V.missing, strings.clone(p))
	engine.files_add(p, data[:data_len])
	free(path)
}

@(export)
viewer_files_done :: proc "contextless" () {
	context = ctx()
	V.fetching = false
	if !V.loaded {
		load()
	} else {
		// a library, or a font a library or the document lists, may have come
		engine.doc_load_imports(&V.doc, V.path)
		engine.layout_invalidate()
		if V.auto_fit do V.fit_pending = true
	}
	V.redraw = true
}

// Shows the document at `path` (the URL path of a .pen file on the page's server).
@(export)
viewer_open :: proc "contextless" (path: [^]u8, path_len: int) {
	context = ctx()
	delete(V.path)
	V.path = strings.clone(string(path[:path_len]))
	free(path)
	for m in V.missing do delete(m)
	clear(&V.missing)
	V.loaded = false
	load()
	V.redraw = true
}

@(export)
viewer_pan :: proc "contextless" (dx, dy: f32) {
	V.auto_fit = false
	V.cam -= [2]f32{dx, dy} / V.zoom
	V.redraw = true
}

// Zooms by `factor` around the canvas point (x, y), in CSS pixels.
@(export)
viewer_zoom :: proc "contextless" (factor, x, y: f32) {
	V.auto_fit = false
	at := V.cam + [2]f32{x, y} / V.zoom
	V.zoom = clamp(V.zoom * factor, 0.02, 64)
	V.cam = at - [2]f32{x, y} / V.zoom
	V.redraw = true
}

// Shows the page point (x, y) at the canvas's top left, at `zoom`.
@(export)
viewer_view :: proc "contextless" (zoom, x, y: f32) {
	V.zoom = clamp(zoom, 0.02, 64)
	V.cam = {x, y}
	V.fit_pending = false
	V.auto_fit = false
	V.redraw = true
}

@(export)
viewer_fit :: proc "contextless" () {
	V.fit_pending = true
	V.auto_fit = true
	V.redraw = true
}

// Shows the document with `value` on the theme axis `axis` (both are freed).
@(export)
viewer_set_theme :: proc "contextless" (axis: [^]u8, axis_len: int, value: [^]u8, value_len: int) {
	context = ctx()
	a, v := string(axis[:axis_len]), string(value[:value_len])
	if old, ok := engine.theme[a]; ok {
		delete(old)
		engine.theme[a] = strings.clone(v)
	} else {
		engine.theme[strings.clone(a)] = strings.clone(v)
	}
	free(axis)
	free(value)
	if V.loaded do engine.doc_retheme(&V.doc)
	V.redraw = true
}

@(export)
viewer_set_page :: proc "contextless" (i: int) {
	V.page = i
	V.fit_pending = true
	V.auto_fit = true
	V.redraw = true
}

// Selects the layer under the canvas point (x, y), in CSS pixels. mode 0: a click, as in the
// app (the layer next to the selected one, or a top-level frame's child); 1: a double
// click, one level into the selection; 2: the deepest layer (⌘ or Ctrl).
@(export)
viewer_pick :: proc "contextless" (x, y: f32, mode: int) {
	context = ctx()
	V.redraw = true
	if !V.loaded do return
	hit := hit_test(V.cam + [2]f32{x, y} / V.zoom)
	if hit == 0 || mode == 2 {
		V.sel = hit
		return
	}
	chain := make([dynamic]int, context.temp_allocator) // the hit, its parent, ... the top
	for cur := hit; cur != 0 && len(chain) < engine.MAX_DEPTH; {
		append(&chain, cur)
		n, _ := engine.doc_find_uid(&V.doc, cur)
		if n == nil do break
		cur = n.parent
	}
	for uid, i in chain {
		if uid != V.sel do continue
		// a double click goes one level in; a click keeps what is selected
		V.sel = chain[i - 1] if mode == 1 && i > 0 else uid
		return
	}
	if V.sel != 0 {
		if sn, _ := engine.doc_find_uid(&V.doc, V.sel); sn != nil && sn.parent != 0 {
			for uid in chain {
				if n, _ := engine.doc_find_uid(&V.doc, uid); n != nil && n.parent == sn.parent {
					V.sel = uid
					return
				}
			}
		}
	}
	if len(chain) >= 2 {
		if top, _ := engine.doc_find_uid(&V.doc, chain[len(chain) - 1]); top != nil && top.kind == .Frame && mode == 0 {
			V.sel = chain[len(chain) - 2]
			return
		}
	}
	V.sel = chain[len(chain) - 1]
}

// Selects a layer by uid (0: none).
@(export)
viewer_select :: proc "contextless" (uid: int) {
	V.sel = uid
	V.redraw = true
}

// Selects the parent of the selection (Shift Enter in the app).
@(export)
viewer_select_parent :: proc "contextless" () {
	context = ctx()
	if n, _ := engine.doc_find_uid(&V.doc, V.sel); n != nil do V.sel = n.parent
	V.redraw = true
}

// Zooms to a layer (0: the selection; nothing selected: fits the page).
@(export)
viewer_zoom_to :: proc "contextless" (uid: int) {
	context = ctx()
	id := uid if uid != 0 else V.sel
	n, _ := engine.doc_find_uid(&V.doc, id)
	if n == nil || V.size.x <= 0 {
		V.fit_pending = true
		V.auto_fit = true
		V.redraw = true
		return
	}
	b := engine.node_page_box(n)
	pad: f32 = 48
	V.zoom = clamp(min((V.size.x - pad * 2) / max(b[2], 1), (V.size.y - pad * 2) / max(b[3], 1)), 0.02, 8)
	V.cam = [2]f32{b[0] + b[2] / 2, b[1] + b[3] / 2} - V.size / (2 * V.zoom)
	V.auto_fit = false
	V.redraw = true
}

// Draws a layer (uid; 0: every layer of the page) at `scale` into the canvas, sized to
// it, for the page to copy before this task ends; the next frame draws the view again.
// Returns the picture's size, width << 16 | height, or 0 if there is nothing to draw.
@(export)
viewer_export :: proc "contextless" (uid: int, scale: f32) -> i32 {
	context = ctx()
	if !V.loaded || V.vg == nil do return 0
	box: [4]f32
	if uid != 0 {
		n, _ := engine.doc_find_uid(&V.doc, uid)
		if n == nil do return 0
		box = engine.node_page_box(n)
	} else {
		lo := [2]f32{math.F32_MAX, math.F32_MAX}
		hi := [2]f32{-math.F32_MAX, -math.F32_MAX}
		found := false
		for &n in V.doc.nodes {
			if n.parent != 0 || V.hidden[n.uid] || !n.enabled do continue
			b := engine.node_page_box(&n)
			lo = {min(lo.x, b[0]), min(lo.y, b[1])}
			hi = {max(hi.x, b[0] + b[2]), max(hi.y, b[1] + b[3])}
			found = true
		}
		if !found do return 0
		pad: f32 = 40 // the page around its layers, as the app's canvas export
		box = {lo.x - pad, lo.y - pad, hi.x - lo.x + 2 * pad, hi.y - lo.y + 2 * pad}
	}
	// whole pixels, at most the GPU's texture size
	z := scale
	limit := f32(engine.gpu_max_side())
	if box[2] * z > limit do z = limit / box[2]
	if box[3] * z > limit do z = min(z, limit / box[3])
	fb := [2]i32{max(i32(math.ceil(box[2] * z)), 1), max(i32(math.ceil(box[3] * z)), 1)}
	size := [2]f32{f32(fb.x), f32(fb.y)}
	vg := V.vg
	bg := CANVAS_BG if uid == 0 else nvg.Color{1, 1, 1, 1}
	engine.gpu_window_begin(fb.x, fb.y, bg)
	nvg.BeginFrame(vg, size.x, size.y, 1)
	draw_scene({box[0], box[1]}, z, size, 1, fb, bg, false)
	nvg.EndFrame(vg)
	engine.gpu_present()
	V.size = {} // the next step sizes the canvas back and draws the view
	V.redraw = true
	return fb.x << 16 | fb.y
}
