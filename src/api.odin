package agentic_design

import "base:runtime"
import "core:c"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import gl "vendor:OpenGL"
import "vendor:glfw"
import nvg "nanovg"
import stbiw "vendor:stb/image"

// Request: {"method": "...", "params": {...}}
// Response: {"ok": true, "result": ...} or {"ok": false, "error": "..."}
// Nodes are exchanged in the .pen format itself: the same objects and
// properties as in the file, with x/y relative to the parent.

api_dispatch :: proc(req: ^Request) -> (response: string, deferred: bool) {
	root, err := json.parse_string(req.body, .JSON, false, context.temp_allocator)
	if err != nil do return api_error("invalid JSON request"), false
	obj, _ := root.(json.Object)
	method := string(obj["method"].(json.String) or_else "")
	params, _ := obj["params"].(json.Object)

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"ok":true,"result":`)
	e := ""
	switch method {
	case "get_document":
		api_get_document(&b, params, false)
	case "get_selection":
		api_get_document(&b, params, true)
	case "get_variables":
		api_get_variables(&b)
	case "batch":
		e = api_batch(&b, params)
	case "find_nodes":
		e = api_find_nodes(&b, params)
	case "get_guide":
		api_get_guide(&b)
	case "lint":
		e = api_lint(&b, params)
	case "rename_references":
		e = api_rename_references(&b, params)
	case "set_libraries":
		e = api_set_libraries(&b, params)
	case "get_styles":
		e = api_get_styles(&b, params)
	case "create_nodes":
		e = api_create_nodes(&b, params)
	case "update_nodes":
		e = api_update_nodes(&b, params)
	case "delete_nodes":
		uids := uids_param(params, "ids")
		if len(uids) == 0 do return api_error("ids is required (and must name existing nodes)"), false
		push_undo()
		for uid in uids do doc_delete(&app.doc, uid)
		prune_selection()
		strings.write_string(&b, `{"deleted":true}`)
	case "set_variables":
		e = api_set_variables(&b, params)
	case "onboarding":
		// opens the onboarding (tests, or an agent pointing the user at agent setup)
		step := int(params["step"].(json.Float) or_else 0)
		if params["close"].(json.Boolean) or_else false do onboarding.open = false
		else do onboarding_start(step)
		fmt.sbprintf(&b, `{{"open":%v,"step":%d}}`, onboarding.open, onboarding.step)
	case "set_pages":
		e = api_set_pages(&b, params)
	case "perf":
		fmt.sbprintf(&b, `{{"layout":%.2f,"input":%.2f,"canvas":%.2f,"ui":%.2f,"flush":%.2f,"swap":%.2f,"frame":%.2f,"atlas":%v,"nodes":%d,"ghosts":%d,"ghost_rebuilds":%d,"measures":%d,"text_measures":%d}}`, app.perf[0], app.perf[1], app.perf[2], app.perf[3], app.perf[4], app.perf[5], app.perf[6], int(app.perf[7]), len(app.doc.nodes), len(app.doc.ghosts), ghost_rebuilds, measure_calls, text_measures)
		ghost_rebuilds, measure_calls, text_measures = 0, 0, 0
	case "input":
		// Synthetic mouse/keyboard events for driving the interface from tests.
		inject_input(params)
		strings.write_string(&b, `{"ok":true}`)
	case "select":
		uids := uids_param(params, "ids")
		clear(&app.sel)
		append(&app.sel, ..uids)
		if params["zoom"].(json.Boolean) or_else false {
			if r, ok := bounds_of(app.sel[:]); ok do zoom_to_rect(r)
		}
		fmt.sbprintf(&b, `{{"selected":%d}}`, len(app.sel))
	case "export_code":
		format := Code_Format.HTML
		if string(params["format"].(json.String) or_else "html") == "react" do format = .React
		files := generate_code(&app.doc, format)
		dir := ""
		if d, has := params["dir"].(json.String); has && d != "" {
			written, ok := export_code_to_dir(format, string(d))
			if !ok do return api_error("could not write the files"), false
			dir = written
		}
		strings.write_string(&b, `{"dir":`)
		json_write_string(&b, dir)
		strings.write_string(&b, `,"files":{`)
		for file, i in files {
			if i > 0 do strings.write_byte(&b, ',')
			json_write_string(&b, file.name)
			strings.write_byte(&b, ':')
			json_write_string(&b, file.content)
		}
		strings.write_string(&b, "}}")
	case "zoom_to_fit":
		uids := uids_param(params, "ids")
		if len(uids) == 0 do uids = all_uids(true)
		if r, ok := bounds_of(uids); ok do zoom_to_rect(r)
		strings.write_string(&b, `{"ok":true}`)
	case "reorder":
		n, i := doc_find(&app.doc, string(params["id"].(json.String) or_else ""))
		if n == nil do return api_error("node not found"), false
		push_undo()
		if (params["position"].(json.String) or_else "front") == "back" {
			send_to_back(n.uid)
		} else {
			doc_bring_to_front(&app.doc, n.uid)
		}
		strings.write_string(&b, `{"ok":true}`)
	case "undo":
		undo()
		strings.write_string(&b, `{"ok":true}`)
	case "redo":
		redo()
		strings.write_string(&b, `{"ok":true}`)
	case "save":
		path := string(params["path"].(json.String) or_else app.file_path)
		if !save_document(path) do return api_error("save failed"), false
		if path != app.file_path {
			delete(app.file_path)
			app.file_path = strings.clone(path, runtime.default_allocator())
			update_title()
		}
		strings.write_string(&b, `{"path":`)
		json_write_string(&b, app.file_path)
		strings.write_string(&b, "}")
	case "open":
		path := string(params["path"].(json.String) or_else "")
		if !os.exists(path) do return api_error("could not read file"), false
		if !open_in_tab(path) do return api_error("not a .pen document"), false
		strings.write_string(&b, `{"ok":true}`)
	case "screenshot":
		if shot.req != nil do return api_error("another screenshot is in progress"), false
		shot = {
			req   = req,
			scale = f32(params["scale"].(json.Float) or_else 2),
			view  = params["view"].(json.Boolean) or_else false,
			path  = strings.clone(string(params["path"].(json.String) or_else ""), context.temp_allocator),
		}
		if th, has := params["theme"].(json.Object); has {
			for k, v in th {
				if shot.themes == len(shot.theme) do break
				shot.theme[shot.themes] = {strings.clone(k, context.temp_allocator), strings.clone(string(v.(json.String) or_else ""), context.temp_allocator)}
				shot.themes += 1
			}
		}
		if f, has := params["format"].(json.String); has {
			ok: bool
			if shot.format, ok = export_format_from(string(f)); !ok {
				shot = {}
				return api_error("format must be png, jpeg, webp or pdf"), false
			}
			if shot.format != .PNG && shot.path == "" {
				shot = {}
				return api_error("pass a path for jpeg, webp and pdf"), false
			}
		}
		if id, has := params["id"].(json.String); has {
			n, _ := doc_find(&app.doc, string(id))
			if n == nil {
				shot = {}
				return api_error("node not found"), false
			}
			shot.uid = n.uid
		}
		return "", true
	case:
		return api_error(fmt.tprintf("unknown method '%s'", method)), false
	}
	if e != "" do return api_error(e), false
	strings.write_string(&b, "}")
	return strings.clone(strings.to_string(b), runtime.default_allocator()), false
}

api_error :: proc(msg: string) -> string {
	b := strings.builder_make(runtime.default_allocator())
	strings.write_string(&b, `{"ok":false,"error":`)
	json_write_string(&b, msg)
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// Resolves a list of .pen ids to uids, skipping unknown ones.
uids_param :: proc(params: json.Object, key: string) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	arr, _ := params[key].(json.Array)
	for v in arr {
		if id, ok := v.(json.String); ok {
			if n, _ := doc_find(&app.doc, string(id)); n != nil do append(&out, n.uid)
		}
	}
	return out[:]
}

// The node tree for agents. `ids` picks subtrees, `depth` limits how many levels of
// children come back, `variables` adds the variable definitions (on by default for the
// whole document, off for the selection).
api_get_document :: proc(b: ^strings.Builder, params: json.Object, selection_only: bool) {
	strings.write_string(b, `{"file":`)
	json_write_string(b, app.file_path)
	strings.write_string(b, `,"selection":[`)
	for uid, i in app.sel {
		if i > 0 do strings.write_byte(b, ',')
		if n, _ := doc_find_uid(&app.doc, uid); n != nil do json_write_string(b, n.id)
		else do strings.write_string(b, "null")
	}
	strings.write_byte(b, ']')
	if params["variables"].(json.Boolean) or_else !selection_only {
		strings.write_string(b, `,"variables":`)
		write_header_value(b, "variables")
	}
	// imported libraries and the components they offer ("alias:id" for refs)
	if !selection_only {
		strings.write_string(b, `,"libraries":[`)
		first_lib := true
		for alias, rel in doc_imports(&app.doc) {
			if !first_lib do strings.write_byte(b, ',')
			first_lib = false
			strings.write_string(b, `{"alias":`)
			json_write_string(b, alias)
			strings.write_string(b, `,"path":`)
			json_write_string(b, string(rel.(json.String) or_else ""))
			strings.write_string(b, `,"components":[`)
			first_c := true
			for &n in app.doc.nodes do if n.imported && n.reusable && library_of(&n) == alias {
				if !first_c do strings.write_byte(b, ',')
				first_c = false
				strings.write_string(b, `{"id":`)
				json_write_string(b, n.id)
				strings.write_string(b, `,"name":`)
				json_write_string(b, node_label(&n))
				strings.write_byte(b, '}')
			}
			strings.write_string(b, "]}")
		}
		strings.write_byte(b, ']')
	}
	picked := uids_param(params, "ids")
	api_depth_limit = int(params["depth"].(json.Float) or_else -1)
	api_depth = 0
	defer api_depth_limit = -1
	strings.write_string(b, `,"children":[`)
	first := true
	for &n in app.doc.nodes {
		include := n.parent == 0 && !n.imported
		if selection_only do include = is_selected(n.uid) && !(n.parent != 0 && is_selected(n.parent))
		if len(picked) > 0 do include = slice.contains(picked, n.uid)
		if !include do continue
		if !first do strings.write_byte(b, ',')
		first = false
		write_node(b, &app.doc, &n, -1, true)
	}
	strings.write_string(b, "]}")
}

write_header_value :: proc(b: ^strings.Builder, key: string) {
	raw := ""
	for p in app.doc.header do if p.key == key do raw = p.raw
	strings.write_string(b, raw if raw != "" else "{}")
}

// Imports libraries (`add`: .pen paths) and drops them (`remove`: aliases).
api_set_libraries :: proc(b: ^strings.Builder, params: json.Object) -> string {
	added := make([dynamic]string, context.temp_allocator)
	if arr, ok := params["add"].(json.Array); ok {
		for v in arr {
			p := absolute_path(string(v.(json.String) or_else ""))
			if !os.exists(p) do return fmt.tprintf("no such file: %s", p)
			if alias, aok := library_add(p); aok do append(&added, alias)
		}
	}
	if arr, ok := params["remove"].(json.Array); ok {
		for v in arr do library_remove(string(v.(json.String) or_else ""))
	}
	strings.write_string(b, `{"added":[`)
	for a, i in added {
		if i > 0 do strings.write_byte(b, ',')
		json_write_string(b, a)
	}
	strings.write_string(b, "]}")
	return ""
}

// Variables and theme axes, with the theme shown in the window.
api_get_variables :: proc(b: ^strings.Builder) {
	strings.write_string(b, `{"themes":`)
	write_header_value(b, "themes")
	strings.write_string(b, `,"shown":{`)
	first := true
	for k, v in app.theme {
		if !first do strings.write_byte(b, ',')
		first = false
		json_write_string(b, k)
		strings.write_byte(b, ':')
		json_write_string(b, v)
	}
	strings.write_string(b, `},"variables":`)
	write_header_value(b, "variables")
	strings.write_byte(b, '}')
}

// The CSS code export writes for each node, with its bounds: a quick way to implement
// a part of the design without exporting the page.
api_get_styles :: proc(b: ^strings.Builder, params: json.Object) -> string {
	uids := uids_param(params, "ids")
	if len(uids) == 0 do uids = app.sel[:]
	if len(uids) == 0 do return "pass ids (or select nodes in the window)"
	g := Gen{doc = &app.doc, format = .HTML}
	strings.write_string(b, `{"nodes":[`)
	for uid, i in uids {
		n, _ := doc_find_uid(&app.doc, uid)
		if n == nil do continue
		if i > 0 do strings.write_byte(b, ',')
		strings.write_string(b, `{"id":`)
		json_write_string(b, n.id)
		fmt.sbprintf(b, `,"bounds":[%s,%s,%s,%s],"css":{{`, num_text(n.x), num_text(n.y), num_text(n.w), num_text(n.h))
		parent, _ := doc_find_uid(&app.doc, n.parent)
		for d, j in node_decls(&g, n, parent) {
			if j > 0 do strings.write_byte(b, ',')
			json_write_string(b, d.prop)
			strings.write_byte(b, ':')
			json_write_string(b, d.value)
		}
		strings.write_string(b, "}}")
	}
	strings.write_string(b, "]}")
	return ""
}

api_create_nodes :: proc(b: ^strings.Builder, params: json.Object) -> string {
	parent := 0
	if pid, has := params["parent_id"].(json.String); has && pid != "" {
		p, _ := doc_find(&app.doc, string(pid))
		if p == nil || (p.kind != .Frame && p.kind != .Group) do return "parent_id must be a frame or group"
		parent = p.uid
	}
	specs, ok := params["nodes"].(json.Array)
	if !ok || len(specs) == 0 do return "nodes must be a non-empty array of .pen nodes"
	push_undo()
	created := make([dynamic]int, context.temp_allocator)
	for spec in specs {
		uid, err := node_from_json(&app.doc, spec, parent)
		if err != "" do return err
		append(&created, uid)
	}
	strings.write_string(b, `{"created":[`)
	for uid, i in created {
		if i > 0 do strings.write_byte(b, ',')
		n, _ := doc_find_uid(&app.doc, uid)
		json_write_string(b, n.id)
	}
	strings.write_string(b, "]}")
	return ""
}

api_update_nodes :: proc(b: ^strings.Builder, params: json.Object) -> string {
	updates, ok := params["updates"].(json.Array)
	if !ok || len(updates) == 0 do return "updates must be a non-empty array"
	push_undo()
	for u in updates {
		o, is_obj := u.(json.Object)
		if !is_obj do return "each update must be an object"
		id := string(o["id"].(json.String) or_else "")
		n, _ := doc_find(&app.doc, id)
		if n == nil do return fmt.tprintf("node '%s' not found", id)
		if pv, has := o["parent_id"]; has {
			np := 0
			if pid, is_str := pv.(json.String); is_str && pid != "" {
				p, _ := doc_find(&app.doc, string(pid))
				if p == nil || (p.kind != .Frame && p.kind != .Group) || p.uid == n.uid || is_descendant(&app.doc, p.uid, n.uid) do return "invalid parent_id"
				np = p.uid
			}
			uid := n.uid
			doc_reparent(&app.doc, uid, np)
			n, _ = doc_find_uid(&app.doc, uid)
		}
		for k, v in o {
			switch k {
			case "id", "parent_id", "children", "type":
			case:
				if _, is_null := v.(json.Null); is_null do node_unset(&app.doc, n, k)
				else do node_set(&app.doc, n, k, v)
			}
		}
	}
	strings.write_string(b, `{"updated":true}`)
	return ""
}

// ---------------------------------------------------------------- screenshots

Shot :: struct {
	req:    ^Request,
	uid:    int,
	scale:  f32,
	view:   bool, // capture the window as shown, after the regular frame
	format: Export_Format,
	path:   string, // write the image here instead of returning it
	theme:  [8][2]string, // theme values to render with (axis, value), whatever the window shows
	themes: int,
}

shot: Shot

shot_pending :: proc() -> bool {
	return shot.req != nil && !shot.view
}

view_shot_pending :: proc() -> bool {
	return shot.req != nil && shot.view
}

// Reads the finished frame (canvas and panels) back as a PNG.
capture_view :: proc() {
	req := shot.req
	defer shot = {}
	fb := platform_framebuffer_size()
	w, h := fb.x, fb.y
	pixels := make([]u8, int(w * h * 4), context.temp_allocator)
	gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
	gl.ReadPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(pixels))
	finish_request(req, encode_png_response(pixels, w, h))
}

// Renders the target into the back buffer, reads it back and encodes a PNG.
// Runs before the regular frame overwrites the buffer.
render_screenshot :: proc() {
	req := shot.req
	defer shot = {}

	uids: []int
	target: ^Node
	if shot.uid != 0 {
		target, _ = doc_find_uid(&app.doc, shot.uid)
		if target == nil {
			finish_request(req, api_error("node not found"))
			return
		}
		uids = {shot.uid}
	} else {
		uids = all_uids(true)
	}
	r, ok := bounds_of(uids)
	if !ok {
		finish_request(req, api_error("nothing to capture"))
		return
	}
	pad: f32 = 0 if target != nil else 20
	r = {r[0] - pad, r[1] - pad, r[2] + pad * 2, r[3] + pad * 2}
	// another theme just for this image: switch, draw, switch back
	saved_theme := make(map[string]string, 4, context.temp_allocator)
	if shot.themes > 0 {
		for k, v in app.theme do saved_theme[k] = v
		for t in shot.theme[:shot.themes] do app.theme[t[0]] = t[1]
		doc_retheme(&app.doc)
		layout_document(&app.doc)
	}
	defer if shot.themes > 0 {
		clear(&app.theme)
		for k, v in saved_theme do app.theme[k] = v
		doc_retheme(&app.doc)
		layout_document(&app.doc)
	}
	pixels, ow, oh, rok := render_region(r, shot.scale, target, {1, 1, 1, 1})
	if !rok {
		finish_request(req, api_error("node too small to capture"))
		return
	}
	if shot.path != "" {
		data, eok := encode_image(pixels, ow, oh, shot.format, shot.scale)
		if !eok {
			finish_request(req, api_error("encoding failed"))
			return
		}
		path := absolute_path(shot.path)
		if err := os.write_entire_file(path, data); err != nil {
			finish_request(req, api_error(fmt.tprintf("could not write %s", path)))
			return
		}
		b := strings.builder_make(runtime.default_allocator())
		fmt.sbprintf(&b, `{{"ok":true,"result":{{"path":`)
		json_write_string(&b, path)
		fmt.sbprintf(&b, `,"format":"%s","width":%d,"height":%d,"bytes":%d}}}}`, EXPORT_EXTENSIONS[shot.format], ow, oh, len(data))
		finish_request(req, strings.to_string(b))
		return
	}
	finish_request(req, encode_png_response(pixels, ow, oh))
}

// Draws a page rectangle (a node, or every top-level node) into the back buffer at
// `scale` pixels per unit and reads the pixels back (bottom-up rows, RGBA).
render_region :: proc(r: [4]f32, scale: f32, target: ^Node, bg: nvg.Color) -> (pixels: []u8, ow, oh: i32, ok: bool) {
	fb := platform_framebuffer_size()
	rw, rh := f32(fb.x), f32(fb.y)
	s := clamp(scale, 0.05, 4)
	s = min(s, rw / r[2], rh / r[3])
	ow, oh = i32(r[2] * s), i32(r[3] * s)
	if ow < 1 || oh < 1 do return

	vg := app.vg
	blur_prepare({xf = {s, 0, 0, s, -r[0] * s, -r[1] * s}, dpr = 1, clip = {0, 0, f32(ow), f32(oh)}, fb = {i32(rw), i32(rh)}, bg = bg})
	gl.Viewport(0, 0, i32(rw), i32(rh))
	gl.ClearColor(bg.r, bg.g, bg.b, 1)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.STENCIL_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
	nvg.BeginFrame(vg, rw, rh, 1)
	nvg.Scale(vg, s, s)
	nvg.Translate(vg, -r[0], -r[1])
	blur_active = true
	if target != nil {
		draw_node_tree(vg, target, 1, 0)
	} else {
		for i in 0 ..< len(app.doc.nodes) {
			if app.doc.nodes[i].parent == 0 && !app.page_hidden[app.doc.nodes[i].uid] do draw_node_tree(vg, &app.doc.nodes[i], 1, 0)
		}
	}
	blur_active = false
	nvg.EndFrame(vg)

	pixels = make([]u8, int(ow * oh * 4), context.temp_allocator)
	gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
	gl.ReadPixels(0, i32(rh) - oh, ow, oh, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(pixels))
	return pixels, ow, oh, true
}

// Flips GL rows (bottom-up) in place and encodes a PNG (temp allocator).
png_encode :: proc(pixels: []u8, ow, oh: i32) -> (png: []u8, ok: bool) {
	row := int(ow * 4)
	tmp := make([]u8, row, context.temp_allocator)
	for y in 0 ..< int(oh) / 2 {
		a := pixels[y * row:][:row]
		bb := pixels[(int(oh) - 1 - y) * row:][:row]
		copy(tmp, a)
		copy(a, bb)
		copy(bb, tmp)
	}
	for i := 3; i < len(pixels); i += 4 do pixels[i] = 255

	out := make([dynamic]u8, context.temp_allocator)
	write_chunk :: proc "c" (ctx: rawptr, data: rawptr, size: c.int) {
		context = runtime.default_context()
		out := (^[dynamic]u8)(ctx)
		append(out, ..([^]u8)(data)[:size])
	}
	if stbiw.write_png_to_func(write_chunk, &out, c.int(ow), c.int(oh), 4, raw_data(pixels), c.int(row)) == 0 do return
	return out[:], true
}

encode_png_response :: proc(pixels: []u8, ow, oh: i32) -> string {
	png, ok := png_encode(pixels, ow, oh)
	if !ok do return api_error("PNG encoding failed")
	encoded := base64.encode(png, allocator = context.temp_allocator)
	b := strings.builder_make(runtime.default_allocator())
	fmt.sbprintf(&b, `{{"ok":true,"result":{{"width":%d,"height":%d,"png_base64":"%s"}}}}`, ow, oh, encoded)
	return strings.to_string(b)
}

// Applies synthetic input for the current frame: x/y move the pointer (and keep it there
// until "end"), press/release hold a button, keys/mods/chars/wheel act for this frame.
inject_input :: proc(params: json.Object) {
	if x, ok := params["x"].(json.Float); ok {
		pf.synthetic = true
		pf.synthetic_pos = {f32(x), f32(params["y"].(json.Float) or_else 0)}
		pf.mouse = pf.synthetic_pos
		app.mouse = pf.mouse
	}
	if params["end"].(json.Boolean) or_else false do pf.synthetic = false
	button :: proc(name: string) -> int {
		switch name {
		case "left": return int(glfw.MOUSE_BUTTON_LEFT)
		case "middle": return int(glfw.MOUSE_BUTTON_MIDDLE)
		case "right": return int(glfw.MOUSE_BUTTON_RIGHT)
		}
		return -1
	}
	if name, ok := params["press"].(json.String); ok {
		if b := button(string(name)); b >= 0 {
			pf.button_down[b] = true
			pf.button_pressed[b] = true
		}
	}
	if name, ok := params["release"].(json.String); ok {
		if b := button(string(name)); b >= 0 do pf.button_down[b] = false
	}
	if w, ok := params["wheel"].(json.Array); ok && len(w) == 2 {
		pf.wheel = {f32(w[0].(json.Float) or_else 0), f32(w[1].(json.Float) or_else 0)}
	}
	if w, ok := params["scroll"].(json.Array); ok && len(w) == 2 {
		pf.scroll = {f32(w[0].(json.Float) or_else 0), f32(w[1].(json.Float) or_else 0)}
	}
	if m, ok := params["magnify"].(json.Float); ok do pf.magnify = f32(m)
	if params["smart"].(json.Boolean) or_else false do pf.smart = true
	if text, ok := params["chars"].(json.String); ok {
		for r in string(text) do append(&pf.chars, r)
	}
	key_code :: proc(name: string) -> c.int {
		switch name {
		case "enter": return glfw.KEY_ENTER
		case "backspace": return glfw.KEY_BACKSPACE
		case "delete": return glfw.KEY_DELETE
		case "escape": return glfw.KEY_ESCAPE
		case "tab": return glfw.KEY_TAB
		case "space": return glfw.KEY_SPACE
		case "left": return glfw.KEY_LEFT
		case "right": return glfw.KEY_RIGHT
		case "up": return glfw.KEY_UP
		case "down": return glfw.KEY_DOWN
		case "cmd": return glfw.KEY_LEFT_SUPER
		case "shift": return glfw.KEY_LEFT_SHIFT
		case "alt": return glfw.KEY_LEFT_ALT
		case "/": return glfw.KEY_SLASH
		case "'": return glfw.KEY_APOSTROPHE
		case ",": return glfw.KEY_COMMA
		case "=": return glfw.KEY_EQUAL
		case "-": return glfw.KEY_MINUS
		case "]": return glfw.KEY_RIGHT_BRACKET
		case "[": return glfw.KEY_LEFT_BRACKET
		}
		if len(name) == 1 {
			ch := name[0]
			if ch >= 'a' && ch <= 'z' do return glfw.KEY_A + c.int(ch - 'a')
			if ch >= '0' && ch <= '9' do return glfw.KEY_0 + c.int(ch - '0')
		}
		return -1
	}
	if mods, ok := params["mods"].(json.Array); ok {
		for m in mods {
			if k := key_code(string(m.(json.String) or_else "")); k >= 0 {
				pf.key_down[k] = true
				append(&pf.synthetic_keys, k)
			}
		}
	}
	// keys held across frames until "unhold" (for ⌥ measuring, the Z zoom tool)
	if keys, ok := params["hold"].(json.Array); ok {
		for kv in keys do if k := key_code(string(kv.(json.String) or_else "")); k >= 0 do pf.key_down[k] = true
	}
	if keys, ok := params["unhold"].(json.Array); ok {
		for kv in keys do if k := key_code(string(kv.(json.String) or_else "")); k >= 0 do pf.key_down[k] = false
	}
	if keys, ok := params["keys"].(json.Array); ok {
		for kv in keys {
			if k := key_code(string(kv.(json.String) or_else "")); k >= 0 {
				pf.key_down[k] = true
				pf.key_pressed[k] = true
				pf.key_repeated[k] = true
				append(&pf.synthetic_keys, k)
			}
		}
	}
}

// Edits the document's tokens: `themes` replaces the theme axes ({"mode": ["light",
// "dark"]}), `variables` merges .pen variable definitions by name (null removes one),
// `show` picks the theme value the window displays ({"mode": "dark"}).
api_set_variables :: proc(b: ^strings.Builder, params: json.Object) -> string {
	doc := &app.doc
	themes, has_themes := params["themes"].(json.Object)
	vars, has_vars := params["variables"].(json.Object)
	show, has_show := params["show"].(json.Object)
	if !has_themes && !has_vars && !has_show do return "pass themes, variables or show"
	// showing another theme does not change the document
	if has_themes || has_vars do push_undo()
	if has_themes {
		_ = doc_theme_axes(doc)
		theme_axes_free(&doc.theme_axes)
		names := make([dynamic]string, context.temp_allocator)
		for k in themes do append(&names, k)
		slice.sort(names[:])
		for k in names {
			arr, ok := themes[k].(json.Array)
			if !ok do return fmt.tprintf("themes.%s must be an array of values", k)
			axis := Theme_Axis{name = strings.clone(k)}
			for v in arr do append(&axis.values, strings.clone(string(v.(json.String) or_else "")))
			append(&doc.theme_axes, axis)
		}
		doc_theme_axes_write(doc)
		theme_defaults(doc)
	}
	if has_vars {
		cur := doc_variables(doc)
		for k, v in vars {
			if _, is_null := v.(json.Null); is_null do delete_key(&cur, k)
			else do cur[k] = v
		}
		doc_write_variables(doc, cur)
	}
	if has_show {
		for k, v in show {
			val := string(v.(json.String) or_else "")
			if old, had := app.theme[k]; had {
				delete(old)
				app.theme[k] = strings.clone(val)
			} else {
				app.theme[strings.clone(k)] = strings.clone(val)
			}
		}
	}
	doc_retheme(doc)
	if has_themes || has_vars do mark_dirty()
	fmt.sbprintf(b, `{{"variables":%d,"themes":%d}}`, len(doc_variables(doc)), len(doc_theme_axes(doc)))
	return ""
}

// Replaces the document's pages: {"pages": [{"name": "Components", "nodes": [top-level
// ids]}], "show": 1}. Top-level nodes listed under no page stay on the first one.
api_set_pages :: proc(b: ^strings.Builder, params: json.Object) -> string {
	doc := &app.doc
	list, has_list := params["pages"].(json.Array)
	show, has_show := params["show"].(json.Float)
	if !has_list && !has_show do return "pass pages and/or show"
	if has_list {
		if len(list) == 0 do return "pages must not be empty"
		push_undo()
		_ = doc_pages(doc)
		pages_free(&doc.pages)
		for item in list {
			obj, ok := item.(json.Object)
			if !ok do return "each page is {name, nodes}"
			page := Page{name = strings.clone(string(obj["name"].(json.String) or_else "Page"))}
			if ids, has := obj["nodes"].(json.Array); has {
				for id in ids do append(&page.ids, strings.clone(string(id.(json.String) or_else "")))
			}
			append(&doc.pages, page)
		}
		doc_pages_write(doc)
		for &n in doc.nodes do if n.parent == 0 do n.page_seen = true
		mark_dirty()
	}
	page_switch(clamp(int(show) if has_show else app.page, 0, len(doc.pages) - 1))
	fmt.sbprintf(b, `{{"pages":%d,"shown":%d}}`, len(doc.pages), app.page)
	return ""
}
