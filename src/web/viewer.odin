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
	// what the page's bar shows: {"title", "pages": [names], "page", "themes": [{"name",
	// "values", "value"}], "zoom", "draw_ms", "missing": [paths]}
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
}

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
	z := V.zoom
	if V.loaded {
		engine.blur_prepare({xf = {z, 0, 0, z, -V.cam.x * z, -V.cam.y * z}, dpr = V.dpr, clip = {0, 0, V.size.x, V.size.y}, fb = {fb.x, fb.y}, bg = CANVAS_BG, order = V.order[:]})
	}
	engine.gpu_window_begin(fb.x, fb.y, CANVAS_BG)
	nvg.BeginFrame(vg, V.size.x, V.size.y, V.dpr)
	if V.loaded {
		nvg.Save(vg)
		nvg.Scale(vg, z, z)
		nvg.Translate(vg, -V.cam.x, -V.cam.y)
		engine.cull_rect = {V.cam.x, V.cam.y, V.size.x / z, V.size.y / z}
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
		// the names of the top-level frames, as on the app's canvas
		nvg.FontFace(vg, "sans")
		nvg.FontSize(vg, 12)
		nvg.TextAlign(vg, .LEFT, .BOTTOM)
		nvg.FillColor(vg, {1, 1, 1, 0.45})
		for &n in V.doc.nodes {
			if n.parent != 0 || !n.enabled || V.hidden[n.uid] || !(n.kind == .Frame || n.kind == .Group) do continue
			nvg.Text(vg, (n.x - V.cam.x) * z, (n.y - V.cam.y) * z - 7, engine.node_label(&n))
		}
	}
	nvg.EndFrame(vg)
	engine.gpu_present()
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
	strings.write_string(&b, "]}")
	page_info(strings.to_string(b))
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
