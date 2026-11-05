#+build !js
package agentic_design

import "engine"

import "core:c"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import nvg "nanovg"

// Request: {"method": "...", "params": {...}}
// Response: {"ok": true, "result": ...} or {"ok": false, "error": "..."}
// Nodes are exchanged in the .pen format itself: the same objects and
// properties as in the file, with x/y relative to the parent.

// An agent's request also moves its cursor and flashes what it touched (presence.odin):
// the layers are compared before and after the requests that change them.
api_dispatch :: proc(req: ^Request) -> (response: string, deferred: bool) {
	root, err := json.parse_string(req.body, .JSON, false, context.temp_allocator)
	if err != nil do return api_error("invalid JSON request"), false
	obj, _ := root.(json.Object)
	// a request for a document the window does not show runs on it in place (decision 85)
	method := string(obj["method"].(json.String) or_else "")
	// a request of an agent run started in the window (decision 86): refused once the run
	// was stopped; its changes to a document are one undo step
	run, run_ok := agent_run_of(obj)
	if !run_ok do return api_error("This agent run was stopped in Agentic Design; nothing was changed."), false
	if f, has := obj["file"].(json.String); has && f != "" && !document_free(method) && !(app.tab >= 0 && same_file(string(f), app.file_path)) {
		params, _ := obj["params"].(json.Object)
		if method == "screenshot" && (params["view"].(json.Boolean) or_else false) {
			return api_error(fmt.tprintf("A view screenshot shows the window, and the window shows %s. Take a screenshot of the document or of a layer instead (no \"view\").", app.file_path if app.tab >= 0 else "the dashboard")), false
		}
		t, e := background_find(string(f))
		if e != "" do return api_error(e), false
		background_enter(t)
		saved := agent_request_begin(run, app.file_path)
		response, deferred = api_dispatch_request(req, obj)
		if deferred && shot.req == req do render_screenshot() // drawn now, while it is in `app`
		agent_request_end(run, app.file_path, method, strings.has_prefix(response, `{"ok":true`), saved)
		background_leave(t)
		return
	}
	before: map[int]Node_Sig
	if presence_wants_signature(obj) do before = doc_signature(&app.doc)
	saved := agent_request_begin(run, app.file_path)
	response, deferred = api_dispatch_request(req, obj)
	agent_request_end(run, app.file_path, method, strings.has_prefix(response, `{"ok":true`), saved)
	presence_after_request(obj, before, deferred || strings.has_prefix(response, `{"ok":true`))
	return
}

api_dispatch_request :: proc(req: ^Request, obj: json.Object) -> (response: string, deferred: bool) {
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
	case "update":
		e = api_update(&b, params)
	case "scale_nodes":
		e = api_scale_nodes(&b, params)
	case "add_fonts":
		e = api_add_fonts(&b, params)
	case "outline_text":
		e = api_outline_text(&b, params)
	case "connect":
		e = api_connect(&b, params)
	case "export_pages":
		e = api_export_pages(&b, params)
	case "export_icons":
		e = api_export_icons(&b, params)
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
		engine.doc_delete_layers(&app.doc, uids[:])
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
	case "dashboard":
		// the dashboard's files (tests): files_index.odin api_dashboard
		e = api_dashboard(&b, params)
	case "cloud":
		// sign-in and sharing (tests): cloud.odin api_cloud
		e = api_cloud(&b, params)
	case "agent":
		// the agent input's thread, context, sessions and marks (tests): agent_run.odin
		e = api_agent(&b, params)
	case "whats_new":
		// the "What's new" sheet (tests): {"open": true}, {"menu": true} or {"close": true}, or its state
		e = api_whats_new(&b, params["open"].(json.Boolean) or_else false, params["close"].(json.Boolean) or_else false, params["menu"].(json.Boolean) or_else false)
	case "set_pages":
		e = api_set_pages(&b, params)
	case "presence":
		e = api_presence(&b, params)
	case "memory":
		if params["trim"].(json.Boolean) or_else false do memory_trim()
		api_memory(&b)
	case "perf":
		fmt.sbprintf(&b, `{{"layout":%.2f,"input":%.2f,"canvas":%.2f,"ui":%.2f,"flush":%.2f,"swap":%.2f,"frame":%.2f,"atlas":%v,"nodes":%d,"ghosts":%d,"ghost_rebuilds":%d,"measures":%d,"text_measures":%d,"frames":%d}}`, app.perf[0], app.perf[1], app.perf[2], app.perf[3], app.perf[4], app.perf[5], app.perf[6], int(app.perf[7]), len(app.doc.nodes), len(app.doc.ghosts), engine.ghost_rebuilds, engine.measure_calls, engine.text_measures, frames_drawn)
		engine.ghost_rebuilds, engine.measure_calls, engine.text_measures, frames_drawn = 0, 0, 0, 0
	case "input":
		// Synthetic mouse/keyboard events for driving the interface from tests.
		inject_input(params)
		strings.write_string(&b, `{"ok":true}`)
	case "select":
		uids := uids_param(params, "ids")
		show_page_of(uids)
		clear(&app.sel)
		append(&app.sel, ..uids)
		if params["zoom"].(json.Boolean) or_else false {
			if r, ok := bounds_of(app.sel[:]); ok do zoom_to_rect(r)
		}
		fmt.sbprintf(&b, `{{"selected":%d}}`, len(app.sel))
	case "export_code":
		format := engine.Code_Format.HTML
		if string(params["format"].(json.String) or_else "html") == "react" do format = .React
		roots := uids_param(params, "ids")
		engine.export_all_fonts = params["copy_all_fonts"].(json.Boolean) or_else false
		defer engine.export_all_fonts = false
		files := engine.generate_code(&app.doc, format, roots)
		dir := ""
		if d, has := params["dir"].(json.String); has && d != "" {
			written, ok := export_code_to_dir(format, string(d), roots)
			if !ok do return api_error(fmt.tprintf("could not write the files to %s (a file of that name, or no permission)", engine.absolute_path(string(d)))), false
			dir = written
		}
		strings.write_string(&b, `{"dir":`)
		engine.json_write_string(&b, dir)
		// fonts and images the code refers to (copied there with dir)
		strings.write_string(&b, `,"assets":{`)
		first_asset := true
		for rel, src in engine.export_assets {
			if !first_asset do strings.write_byte(&b, ',')
			first_asset = false
			engine.json_write_string(&b, rel)
			strings.write_byte(&b, ':')
			engine.json_write_string(&b, src)
		}
		strings.write_string(&b, `}`)
		if len(engine.export_warnings) > 0 {
			strings.write_string(&b, `,"warnings":[`)
			for rel, i in engine.export_warnings {
				if i > 0 do strings.write_byte(&b, ',')
				engine.json_write_string(&b, fmt.tprintf("%s is referenced by @font-face but not copied: the font does not name an open license (OFL, Apache), so it is probably licensed per user. Put the file there yourself if the license allows web use, or pass copy_all_fonts: true.", rel))
			}
			strings.write_byte(&b, ']')
		}
		strings.write_string(&b, `,"files":{`)
		for file, i in files {
			if i > 0 do strings.write_byte(&b, ',')
			engine.json_write_string(&b, file.name)
			strings.write_byte(&b, ':')
			engine.json_write_string(&b, file.content)
		}
		strings.write_string(&b, "}}")
	case "zoom_to_fit":
		uids := uids_param(params, "ids")
		show_page_of(uids)
		if len(uids) == 0 do uids = all_uids(true)
		if r, ok := bounds_of(uids); ok do zoom_to_rect(r)
		strings.write_string(&b, `{"ok":true}`)
	case "reorder":
		n, i := engine.doc_find(&app.doc, string(params["id"].(json.String) or_else ""))
		if n == nil do return api_error("node not found"), false
		back := (params["position"].(json.String) or_else "front") == "back"
		if note := arrange_hint({n.uid}, !back, true); note != "" {
			// nothing to move inside its parent: say so, and leave the document as it is
			strings.write_string(&b, `{"ok":true,"moved":false,"note":`)
			engine.json_write_string(&b, note)
			strings.write_byte(&b, '}')
			break
		}
		push_undo()
		if back {
			send_to_back(n.uid)
		} else {
			engine.doc_bring_to_front(&app.doc, n.uid)
		}
		strings.write_string(&b, `{"ok":true,"moved":true}`)
	case "share", "unshare":
		// put the document in the cloud (agent_share.odin); answered when it is done
		agent, _ := obj["agent"].(json.Object)
		return api_share(req, params, agent, method == "unshare")
	case "invite", "people", "remove_access":
		agent, _ := obj["agent"].(json.Object)
		return api_people(req, params, agent, method)
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
			app.file_path = strings.clone(path, big_allocator())
			delete(app.doc.path)
			app.doc.path = strings.clone(path)
			update_title()
		}
		strings.write_string(&b, `{"path":`)
		engine.json_write_string(&b, app.file_path)
		strings.write_string(&b, "}")
	case "window":
		// what the window shows: the document (the envelope's "file") and the open tabs
		strings.write_string(&b, `{"tabs":[`)
		for t, i in app.tabs {
			if i > 0 do strings.write_byte(&b, ',')
			engine.json_write_string(&b, app.file_path if i == app.tab else t.path)
		}
		strings.write_string(&b, "]}")
	case "open":
		path := string(params["path"].(json.String) or_else "")
		if path == "" do return api_error("pass path"), false
		abs := engine.absolute_path(path)
		created := false
		if !os.exists(abs) {
			if !(params["create"].(json.Boolean) or_else false) {
				return api_error(fmt.tprintf("no file at %s; pass \"create\": true to start a new document there", abs)), false
			}
			if !strings.has_suffix(abs, ".pen") do return api_error(fmt.tprintf("%s: a new document needs a .pen name", abs)), false
			_ = os.make_directory_all(os.dir(abs))
			if werr := os.write_entire_file(abs, "{\n  \"version\": \"2.21\",\n  \"children\": []\n}\n"); werr != nil {
				return api_error(fmt.tprintf("could not create %s: %v", abs, werr)), false
			}
			created = true
		} else if os.is_dir(abs) {
			return api_error(fmt.tprintf("%s is a folder, not a .pen file", abs)), false
		}
		if !open_in_tab(abs) do return api_error(fmt.tprintf("could not open %s: not a readable .pen document", abs)), false
		strings.write_string(&b, `{"ok":true,"path":`)
		engine.json_write_string(&b, app.file_path)
		fmt.sbprintf(&b, `,"created":%v}}`, created)
	case "screenshot":
		if shot.req != nil do return api_error("another screenshot is in progress"), false
		shot = {
			req   = req,
			scale = f32(params["scale"].(json.Float) or_else 2),
			view  = params["view"].(json.Boolean) or_else false,
			path  = strings.clone(string(params["path"].(json.String) or_else ""), context.temp_allocator),
			transparent = string(params["background"].(json.String) or_else "") == "transparent",
			width = f32(params["width"].(json.Float) or_else 0),
			height = f32(params["height"].(json.Float) or_else 0),
		}
		if (shot.width > 0 || shot.height > 0) && shot.view {
			shot = {}
			return api_error("width and height size a layer or page image, not the window"), false
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
			if shot.format, ok = engine.export_format_from(string(f)); !ok {
				shot = {}
				return api_error("format must be png, jpeg, webp or pdf"), false
			}
			if shot.format != .PNG && shot.path == "" {
				shot = {}
				return api_error("pass a path for jpeg, webp and pdf"), false
			}
		}
		if id, has := params["id"].(json.String); has {
			n, _ := engine.doc_find(&app.doc, string(id))
			if n == nil {
				shot = {}
				return api_error("node not found"), false
			}
			shot.uid = n.uid
		}
		if shot.format == .PDF && !shot.view {
			// vector, drawn now: the layer, or the frames of the page shown
			uids := []int{shot.uid} if shot.uid != 0 else page_frames(app.page)
			path := shot.path
			shot = {}
			if e = write_pdf(&b, uids, path); e != "" do return api_error(e), false
			strings.write_string(&b, "}")
			return strings.clone(strings.to_string(b), big_allocator()), false
		}
		return "", true
	case:
		return api_error(fmt.tprintf("unknown method '%s'", method)), false
	}
	if e != "" do return api_error(e), false
	// every answer says which document it read or changed (after the method: open and save
	// may have changed it)
	if app.file_path != "" {
		strings.write_string(&b, `,"file":`)
		engine.json_write_string(&b, app.file_path)
	}
	strings.write_string(&b, "}")
	return strings.clone(strings.to_string(b), big_allocator()), false
}

// Methods that do not depend on the document shown.
document_free :: proc(method: string) -> bool {
	switch method {
	case "open", "window", "update", "onboarding", "whats_new", "cloud", "dashboard", "perf", "memory", "input", "presence", "agent":
		return true
	}
	return false
}

// The same file, also through symlinks (/tmp and /private/tmp).
same_file :: proc(a, b: string) -> bool {
	if a == b do return true
	ra := posix.realpath(strings.clone_to_cstring(a, context.temp_allocator))
	rb := posix.realpath(strings.clone_to_cstring(b, context.temp_allocator))
	defer if ra != nil do posix.free(ra)
	defer if rb != nil do posix.free(rb)
	return ra != nil && rb != nil && string(ra) == string(rb)
}

api_error :: proc(msg: string) -> string {
	b := strings.builder_make(big_allocator())
	strings.write_string(&b, `{"ok":false,"error":`)
	engine.json_write_string(&b, msg)
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// The node tree for agents. `ids` picks subtrees, `depth` limits how many levels of
// children come back, `variables` adds the variable definitions (on by default for the
// whole document, off for the selection).
api_get_document :: proc(b: ^strings.Builder, params: json.Object, selection_only: bool) {
	strings.write_string(b, `{"file":`)
	engine.json_write_string(b, app.file_path)
	strings.write_string(b, `,"selection":[`)
	for uid, i in app.sel {
		if i > 0 do strings.write_byte(b, ',')
		if n, _ := engine.doc_find_uid(&app.doc, uid); n != nil do engine.json_write_string(b, n.id)
		else do strings.write_string(b, "null")
	}
	strings.write_byte(b, ']')
	if selection_only {
		// where the page is in the window (screen = origin + page × zoom), for tests and
		// agents that drive the pointer
		o := to_screen({0, 0})
		fmt.sbprintf(b, `,"view":{{"zoom":%s,"origin":[%s,%s]}}`, engine.num_text(app.zoom), engine.num_text(o.x), engine.num_text(o.y))
	}
	if selection_only && status_showing() {
		// the toast the window shows now (a hint after a command), for agents driving it
		strings.write_string(b, `,"status":`)
		engine.json_write_string(b, app.status)
	}
	if params["variables"].(json.Boolean) or_else !selection_only {
		strings.write_string(b, `,"variables":`)
		write_header_value(b, "variables")
	}
	// imported libraries and the components they offer ("alias:id" for refs); only with
	// the whole document, or when asked: a read of a few ids should stay small
	if !selection_only && (params["libraries"].(json.Boolean) or_else ("ids" not_in params)) {
		strings.write_string(b, `,"libraries":[`)
		first_lib := true
		for alias, rel in engine.doc_imports(&app.doc) {
			if !first_lib do strings.write_byte(b, ',')
			first_lib = false
			strings.write_string(b, `{"alias":`)
			engine.json_write_string(b, alias)
			strings.write_string(b, `,"path":`)
			engine.json_write_string(b, string(rel.(json.String) or_else ""))
			strings.write_string(b, `,"components":[`)
			first_c := true
			for &n in app.doc.nodes do if n.imported && n.reusable && engine.library_of(&n) == alias {
				if !first_c do strings.write_byte(b, ',')
				first_c = false
				strings.write_string(b, `{"id":`)
				engine.json_write_string(b, n.id)
				strings.write_string(b, `,"name":`)
				engine.json_write_string(b, engine.node_label(&n))
				strings.write_byte(b, '}')
			}
			strings.write_string(b, "]}")
		}
		strings.write_byte(b, ']')
	}
	picked := uids_param(params, "ids")
	engine.api_depth_limit = int(params["depth"].(json.Float) or_else -1)
	engine.api_depth = 0
	defer engine.api_depth_limit = -1
	strings.write_string(b, `,"children":[`)
	first := true
	for &n in app.doc.nodes {
		include := n.parent == 0 && !n.imported
		if selection_only do include = is_selected(n.uid) && !(n.parent != 0 && is_selected(n.parent))
		if len(picked) > 0 do include = slice.contains(picked, n.uid)
		if !include do continue
		if !first do strings.write_byte(b, ',')
		first = false
		engine.write_node(b, &app.doc, &n, -1, true)
	}
	strings.write_string(b, "]}")
}

// Imports libraries (`add`: .pen paths) and drops them (`remove`: aliases).
api_set_libraries :: proc(b: ^strings.Builder, params: json.Object) -> string {
	added := make([dynamic]string, context.temp_allocator)
	if arr, ok := params["add"].(json.Array); ok {
		for v in arr {
			p := engine.absolute_path(string(v.(json.String) or_else ""))
			if !os.exists(p) do return fmt.tprintf("no such file: %s", p)
			if alias, aok := library_add(p); aok do append(&added, alias)
		}
	}
	removed := make([dynamic]string, context.temp_allocator)
	if arr, ok := params["remove"].(json.Array); ok {
		for v in arr {
			alias := string(v.(json.String) or_else "")
			if alias not_in engine.doc_imports(&app.doc) do return fmt.tprintf("no library \"%s\" is imported", alias)
			library_remove(alias)
			append(&removed, alias)
		}
	}
	// read the libraries again now (they are also re-read within seconds of a change)
	reloaded := params["reload"].(json.Boolean) or_else false
	if reloaded do engine.doc_load_imports(&app.doc, app.file_path)
	list :: proc(b: ^strings.Builder, key: string, items: []string) {
		fmt.sbprintf(b, `"%s":[`, key)
		for a, i in items {
			if i > 0 do strings.write_byte(b, ',')
			engine.json_write_string(b, a)
		}
		strings.write_byte(b, ']')
	}
	strings.write_byte(b, '{')
	list(b, "added", added[:])
	strings.write_byte(b, ',')
	list(b, "removed", removed[:])
	fmt.sbprintf(b, `,"reloaded":%v}}`, reloaded)
	return ""
}

// Variables and theme axes, with the theme shown in the window.
api_get_variables :: proc(b: ^strings.Builder) {
	strings.write_string(b, `{"themes":`)
	write_header_value(b, "themes")
	strings.write_string(b, `,"shown":{`)
	first := true
	for k, v in engine.theme {
		if !first do strings.write_byte(b, ',')
		first = false
		engine.json_write_string(b, k)
		strings.write_byte(b, ':')
		engine.json_write_string(b, v)
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
	g := engine.Gen{doc = &app.doc, format = .HTML}
	strings.write_string(b, `{"nodes":[`)
	for uid, i in uids {
		n, _ := engine.doc_find_uid(&app.doc, uid)
		if n == nil do continue
		if i > 0 do strings.write_byte(b, ',')
		strings.write_string(b, `{"id":`)
		engine.json_write_string(b, n.id)
		fmt.sbprintf(b, `,"bounds":[%s,%s,%s,%s],"css":{{`, engine.num_text(n.x), engine.num_text(n.y), engine.num_text(n.w), engine.num_text(n.h))
		parent, _ := engine.doc_find_uid(&app.doc, n.parent)
		for d, j in engine.node_decls(&g, n, parent) {
			if j > 0 do strings.write_byte(b, ',')
			engine.json_write_string(b, d.prop)
			strings.write_byte(b, ':')
			engine.json_write_string(b, d.value)
		}
		strings.write_string(b, "}}")
	}
	strings.write_string(b, "]}")
	return ""
}

api_create_nodes :: proc(b: ^strings.Builder, params: json.Object) -> string {
	parent := 0
	// an instance as the parent: the nodes become slot content (`slot`: the id of the
	// component's slot frame; default: the frame marked as its slot)
	slot := ""
	if pid, has := params["parent_id"].(json.String); has && pid != "" {
		p, _ := engine.doc_find(&app.doc, string(pid))
		if p != nil && p.kind == .Ref && !p.imported {
			engine.ghosts_sync(&app.doc)
			slot = string(params["slot"].(json.String) or_else "")
			if slot == "" {
				sg, has_slot := app.doc.ghost_slot[p.uid]
				root := engine.ghost_root_of(&app.doc, p.uid)
				if !has_slot || root == nil do return fmt.tprintf("instance '%s' has no component to put content in", p.id)
				if root.uid != sg {
					if gs, _ := engine.doc_find_uid(&app.doc, sg); gs != nil do slot = gs.ghost_of
				}
				// a component without a slot frame takes content in its root (2.8 style)
			}
		} else if p == nil || (p.kind != .Frame && p.kind != .Group) {
			return "parent_id must be a frame, a group or an instance (whose slot gets the nodes)"
		}
		parent = p.uid
	}
	specs, ok := params["nodes"].(json.Array)
	if !ok || len(specs) == 0 do return "nodes must be a non-empty array of .pen nodes"
	push_undo()
	created := make([dynamic]int, context.temp_allocator)
	for spec_in in specs {
		spec, serr := expand_shape_spec(rotation_origin_spec(spec_in))
		if serr != "" do return serr
		uid, err := engine.node_from_json(&app.doc, spec, parent)
		if err != "" do return err
		if slot != "" do if cn, _ := engine.doc_find_uid(&app.doc, uid); cn != nil do cn.slot_of = strings.clone(slot)
		append(&created, uid)
	}
	warnings := make([dynamic]string, context.temp_allocator)
	for uid in created do api_check_nodes(uid, true, &warnings)
	strings.write_string(b, `{"created":[`)
	for uid, i in created {
		if i > 0 do strings.write_byte(b, ',')
		n, _ := engine.doc_find_uid(&app.doc, uid)
		engine.json_write_string(b, n.id)
	}
	strings.write_byte(b, ']')
	write_node_bounds(b, created[:])
	write_warnings(b, warnings[:])
	strings.write_byte(b, '}')
	return ""
}

// ,"nodes":[{"id", "bounds": [x, y, w, h]}, ...] for layers just created or changed, after
// layout (D58): an agent placing things next needs no get_document round trip. A turned
// layer also has "visual_bounds", a connector its "route".
write_node_bounds :: proc(b: ^strings.Builder, uids: []int) {
	engine.layout_document(&app.doc)
	strings.write_string(b, `,"nodes":[`)
	first := true
	for uid in uids {
		n, _ := engine.doc_find_uid(&app.doc, uid)
		if n == nil do continue
		if !first do strings.write_byte(b, ',')
		first = false
		strings.write_string(b, `{"id":`)
		engine.json_write_string(b, n.id)
		fmt.sbprintf(b, `,"bounds":[%s,%s,%s,%s]`, engine.num_text(n.x), engine.num_text(n.y), engine.num_text(n.w), engine.num_text(n.h))
		engine.write_visual_bounds(b, n)
		if route, has := engine.connector_routes[n.uid]; has && n.flow == .Connector {
			strings.write_string(b, `,"route":[`)
			for p, i in route {
				if i > 0 do strings.write_byte(b, ',')
				fmt.sbprintf(b, "[%s,%s]", engine.num_text(p.x), engine.num_text(p.y))
			}
			strings.write_byte(b, ']')
		}
		strings.write_byte(b, '}')
	}
	strings.write_byte(b, ']')
}

// What an agent should hear about the nodes it just wrote: icon names the library does
// not have, and values the app had to read leniently (3-value padding is rewritten to
// the four values it means). `deep` checks the whole subtree.
api_check_nodes :: proc(uid: int, deep: bool, warnings: ^[dynamic]string) {
	n, _ := engine.doc_find_uid(&app.doc, uid)
	if n == nil || n.ghost do return
	if msg := engine.icon_problem(n); msg != "" do append(warnings, fmt.tprintf("%s: %s", n.id, msg))
	// rich text: the content is the spans' texts joined
	if n.kind == .Text && n.spans_bad {
		v, _ := engine.prop_value(n, "spans")
		if text, ok := engine.spans_text(v); ok {
			if engine.prop_index(n, "content") >= 0 && n.content != "" do append(warnings, fmt.tprintf("%s: content was not the spans' texts joined; it was set to them", n.id))
			engine.node_set_string(&app.doc, n, "content", text)
		} else do append(warnings, fmt.tprintf("%s: spans must be an array of runs {\"text\", ...style}; the text is drawn plain", n.id))
	}
	if i := engine.prop_index(n, "padding"); i >= 0 {
		if v, err := json.parse_string(n.props[i].raw, .JSON5, false, context.temp_allocator); err == nil {
			if arr, ok := v.(json.Array); ok && len(arr) == 3 {
				b := strings.builder_make(context.temp_allocator)
				strings.write_byte(&b, '[')
				for k in ([4]int{0, 1, 2, 1}) {
					if b.buf[len(b.buf) - 1] != '[' do strings.write_byte(&b, ',')
					engine.write_json_value(&b, arr[k])
				}
				strings.write_byte(&b, ']')
				engine.node_set_raw(n, "padding", strings.to_string(b))
				append(warnings, fmt.tprintf("%s: padding takes 1, 2 or 4 values; [top, sides, bottom] was written as %s", n.id, strings.to_string(b)))
			}
		}
	}
	if i := engine.prop_index(n, "fill"); i >= 0 && strings.contains(n.props[i].raw, `"image"`) {
		if raw, changed := adopt_image_fills(n.props[i].raw, n.id, warnings); changed {
			engine.node_set_raw(n, "fill", raw)
			engine.node_refresh(&app.doc, n)
		}
	}
	if deep do for cu in engine.children_of(&app.doc, uid) do api_check_nodes(cu, true, warnings)
}

// Image paints whose url is a file outside the document's images/ folder: the file is
// copied there and the url becomes "./images/<name>", as a dropped image is, so the
// document stays self-contained (and pen.dev finds it). A missing file is a warning.
adopt_image_fills :: proc(raw, id: string, warnings: ^[dynamic]string) -> (string, bool) {
	v, err := json.parse_string(raw, .JSON5, false, context.temp_allocator)
	if err != nil do return raw, false
	items := make([dynamic]json.Value, context.temp_allocator)
	single := true
	if arr, ok := v.(json.Array); ok {
		append(&items, ..arr[:])
		single = false
	} else do append(&items, v)
	changed := false
	for &item in items {
		obj, ok := item.(json.Object)
		if !ok || string(obj["type"].(json.String) or_else "") != "image" do continue
		url := string(obj["url"].(json.String) or_else "")
		if url == "" || strings.contains(url, "://") && !strings.has_prefix(url, "file://") || strings.has_prefix(url, "data:") do continue
		src := strings.trim_prefix(url, "file://")
		if strings.has_prefix(src, "~/") {
			home, _ := os.user_home_dir(context.temp_allocator)
			src = fmt.tprintf("%s/%s", home, src[2:])
		}
		path := src if os.is_absolute_path(src) else engine.image_resolve(src)
		if !os.exists(path) {
			append(warnings, fmt.tprintf("%s: image %s not found (give an absolute path; it is copied into images/)", id, path))
			continue
		}
		images := fmt.tprintf("%s/images", os.dir(app.file_path))
		// a file already inside the document's folder stays where it is, written relative to
		// the document so the folder can move (D107)
		abs := engine.absolute_path(path)
		folder := os.dir(app.file_path)
		if strings.has_prefix(abs, folder) && len(abs) > len(folder) && abs[len(folder)] == '/' {
			rel := fmt.tprintf("./%s", abs[len(folder) + 1:])
			if url != rel {
				obj["url"] = json.String(rel)
				changed = true
			}
			continue
		}
		_ = os.make_directory_all(images)
		name := os.base(path)
		dst := fmt.tprintf("%s/%s", images, name)
		// another file of the same name already there: number the copy
		for k := 2; os.exists(dst) && !files_equal(dst, path); k += 1 {
			ext := os.ext(name)
			dst = fmt.tprintf("%s/%s-%d%s", images, strings.trim_suffix(name, ext), k, ext)
		}
		if !os.exists(dst) {
			if cerr := os.copy_file(dst, path); cerr != nil {
				append(warnings, fmt.tprintf("%s: could not copy %s into images/: %v", id, path, cerr))
				continue
			}
		}
		obj["url"] = json.String(fmt.tprintf("./images/%s", os.base(dst)))
		changed = true
	}
	if !changed do return raw, false
	b := strings.builder_make(context.temp_allocator)
	if single do engine.write_json_value(&b, items[0])
	else do engine.write_json_value(&b, json.Array(items))
	return strings.to_string(b), true
}

files_equal :: proc(a, b: string) -> bool {
	da, ea := os.read_entire_file(a, context.temp_allocator)
	db, eb := os.read_entire_file(b, context.temp_allocator)
	return ea == nil && eb == nil && string(da) == string(db)
}

write_warnings :: proc(b: ^strings.Builder, warnings: []string) {
	if len(warnings) == 0 do return
	strings.write_string(b, `,"warnings":[`)
	for w, i in warnings {
		if i > 0 do strings.write_byte(b, ',')
		engine.json_write_string(b, w)
	}
	strings.write_byte(b, ']')
}

// rotationOrigin (D71): "center", "top-left" or [fx, fy] (fractions of the box). The file
// keeps pen.dev's rotation about the top-left corner; x and y are moved so that the layer
// turns about this point instead.
rotation_pivot :: proc(v: json.Value) -> (f: [2]f32, ok: bool) {
	#partial switch t in v {
	case json.String:
		switch string(t) {
		case "center", "centre": return {0.5, 0.5}, true
		case "top-left": return {0, 0}, true
		}
	case json.Array:
		if len(t) == 2 {
			a, aok := t[0].(json.Float)
			b, bok := t[1].(json.Float)
			if aok && bok do return {f32(a), f32(b)}, true
		}
	}
	return {}, false
}

// Where a box point (from the unrotated top-left) lands, relative to the top-left corner.
rotated_offset :: proc(v: [2]f32, rotation: f32, flip_x, flip_y: bool) -> [2]f32 {
	p := [2]f32{v.x * (-1 if flip_x else 1), v.y * (-1 if flip_y else 1)}
	a := -rotation * math.PI / 180
	return {p.x * math.cos(a) - p.y * math.sin(a), p.x * math.sin(a) + p.y * math.cos(a)}
}

// A node spec with rotationOrigin: x and y set so the layer, placed at x and y unturned,
// turns about that point. Children are handled the same way.
rotation_origin_spec :: proc(spec: json.Value) -> json.Value {
	o, is_obj := spec.(json.Object)
	if !is_obj do return spec
	if kids, has := o["children"].(json.Array); has {
		for &k in kids do k = rotation_origin_spec(k)
	}
	pv, has := o["rotationOrigin"]
	if !has do return spec
	delete_key(&o, "rotationOrigin")
	f, ok := rotation_pivot(pv)
	rot := f32(o["rotation"].(json.Float) or_else 0)
	w, wok := o["width"].(json.Float)
	h, hok := o["height"].(json.Float)
	if !ok || rot == 0 || !wok || !hok do return o
	fx, fy := o["flipX"].(json.Boolean) or_else false, o["flipY"].(json.Boolean) or_else false
	v := [2]f32{f.x * f32(w), f.y * f32(h)}
	d := v - rotated_offset(v, rot, bool(fx), bool(fy))
	o["x"] = engine.json_num(f32(o["x"].(json.Float) or_else 0) + d.x)
	o["y"] = engine.json_num(f32(o["y"].(json.Float) or_else 0) + d.y)
	return o
}

api_update_nodes :: proc(b: ^strings.Builder, params: json.Object) -> string {
	updates, ok := params["updates"].(json.Array)
	if !ok || len(updates) == 0 do return "updates must be a non-empty array"
	push_undo()
	warnings := make([dynamic]string, context.temp_allocator)
	changed := make([dynamic]int, context.temp_allocator)
	for u in updates {
		o, is_obj := u.(json.Object)
		if !is_obj do return "each update must be an object"
		id := string(o["id"].(json.String) or_else "")
		n, _ := engine.doc_find(&app.doc, id)
		if n == nil do return fmt.tprintf("node '%s' not found", id)
		if pv, has := o["parent_id"]; has {
			np := 0
			if pid, is_str := pv.(json.String); is_str && pid != "" {
				p, _ := engine.doc_find(&app.doc, string(pid))
				if p == nil || (p.kind != .Frame && p.kind != .Group) || p.uid == n.uid || engine.is_descendant(&app.doc, p.uid, n.uid) do return "invalid parent_id"
				np = p.uid
			}
			uid := n.uid
			engine.doc_reparent(&app.doc, uid, np)
			n, _ = engine.doc_find_uid(&app.doc, uid)
		}
		if n.flow == .Connector {
			has_conn := false
			for k in o do if is_connector_key(k) do has_conn = true
			if has_conn do if e := update_connector(n, o); e != "" do return e
		}
		// a new rotation about a pivot: the pivot stays where it is on the page
		pivot_pos: Maybe([2]f32)
		pivot_v: [2]f32
		if pv, has := o["rotationOrigin"]; has {
			if f, ok := rotation_pivot(pv); ok {
				pivot_v = {f.x * n.w, f.y * n.h}
				pivot_pos = n.pos + rotated_offset(pivot_v, n.rotation, n.flip_x, n.flip_y)
			} else do return "rotationOrigin: \"center\", \"top-left\" or [fx, fy] (fractions of the box)"
		}
		for k, v in o {
			if n.flow == .Connector && is_connector_key(k) do continue
			switch k {
			case "id", "parent_id", "children", "type", "rotationOrigin":
			case "content":
				// without new spans, the node's spans follow the new text
				if text, is_str := v.(json.String); is_str && !("spans" in o) && len(n.spans) > 0 do engine.node_set_content(&app.doc, n, string(text))
				else do engine.node_set(&app.doc, n, k, v)
			case:
				if _, is_null := v.(json.Null); is_null do engine.node_unset(&app.doc, n, k)
				else do engine.node_set(&app.doc, n, k, v)
			}
		}
		if pp, ok := pivot_pos.?; ok && !("x" in o) && !("y" in o) {
			nn, _ := engine.doc_find_uid(&app.doc, n.uid)
			if nn != nil {
				pos := pp - rotated_offset(pivot_v, nn.rotation, nn.flip_x, nn.flip_y)
				engine.node_set_number(&app.doc, nn, "x", math.round(pos.x * 100) / 100)
				engine.node_set_number(&app.doc, nn, "y", math.round(pos.y * 100) / 100)
			}
		}
		if "icon" in o || "iconFontName" in o || "padding" in o || "fill" in o || "spans" in o do api_check_nodes(n.uid, false, &warnings)
		append(&changed, n.uid)
	}
	strings.write_string(b, `{"updated":true`)
	write_node_bounds(b, changed[:])
	write_warnings(b, warnings[:])
	strings.write_byte(b, '}')
	return ""
}

// ---------------------------------------------------------------- screenshots

Shot :: struct {
	req:    ^Request,
	uid:    int,
	scale:  f32,
	view:   bool, // capture the window as shown, after the regular frame
	format: engine.Export_Format,
	path:   string, // write the image here instead of returning it
	theme:  [8][2]string, // theme values to render with (axis, value), whatever the window shows
	themes: int,
	transparent: bool, // no background: an RGBA PNG (D63)
	width, height: f32, // exact pixel size wanted (D66); 0 = from the scale
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
	finish_request(req, encode_png_response(engine.gpu_read(nil, 0, 0, int(fb.x), int(fb.y)), fb.x, fb.y))
}

// Renders the target offscreen (render_region), reads it back and encodes a PNG.
// Runs between frames.
render_screenshot :: proc() {
	req := shot.req
	defer shot = {}

	uids: []int
	target: ^engine.Node
	if shot.uid != 0 {
		target, _ = engine.doc_find_uid(&app.doc, shot.uid)
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
		for k, v in engine.theme do saved_theme[k] = v
		for t in shot.theme[:shot.themes] do engine.theme[t[0]] = t[1]
		engine.doc_retheme(&app.doc)
		engine.layout_document(&app.doc)
	}
	defer if shot.themes > 0 {
		clear(&engine.theme)
		for k, v in saved_theme do engine.theme[k] = v
		engine.doc_retheme(&app.doc)
		engine.layout_document(&app.doc)
	}
	// an exact pixel size: the scale that gives it (the other side follows the layer's shape)
	if shot.width > 0 do shot.scale = shot.width / r[2]
	else if shot.height > 0 do shot.scale = shot.height / r[3]
	bg := shot_backdrop(target)
	if shot.transparent do bg = {0, 0, 0, 0}
	pixels, ow, oh, rok := render_region(r, shot.scale, target, bg)
	if !rok {
		finish_request(req, api_error("node too small to capture"))
		return
	}
	if shot.path != "" {
		data, eok := engine.encode_image(pixels, ow, oh, shot.format, shot.scale, shot.transparent)
		if !eok {
			finish_request(req, api_error("encoding failed"))
			return
		}
		path := engine.absolute_path(shot.path)
		if err := os.write_entire_file(path, data); err != nil {
			finish_request(req, api_error(fmt.tprintf("could not write %s", path)))
			return
		}
		b := strings.builder_make(big_allocator())
		fmt.sbprintf(&b, `{{"ok":true,"result":{{"path":`)
		engine.json_write_string(&b, path)
		fmt.sbprintf(&b, `,"format":"%s","width":%d,"height":%d,"bytes":%d`, engine.EXPORT_EXTENSIONS[shot.format], ow, oh, len(data))
		write_scale_note(&b, shot.scale)
		strings.write_string(&b, "}}")
		finish_request(req, strings.to_string(b))
		return
	}
	finish_request(req, encode_png_response(pixels, ow, oh, shot.scale, shot.transparent))
}

// Shows the page that holds the first of these layers, so selecting or zooming to a layer
// on another page does not draw it over the current one.
show_page_of :: proc(uids: []int) {
	if len(uids) == 0 do return
	top := top_ancestor(uids[0])
	n, _ := engine.doc_find_uid(&app.doc, top)
	if n == nil || n.imported || !app.page_hidden[top] do return
	page_switch(engine.page_of_top(&app.doc, n.id))
}

// The scale used, and why when it is less than asked.
write_scale_note :: proc(b: ^strings.Builder, asked: f32) {
	fmt.sbprintf(b, `,"scale":%s`, engine.num_text(render_scale))
	if asked > 0 && render_scale < asked - 0.001 {
		strings.write_string(b, `,"note":`)
		engine.json_write_string(b, fmt.tprintf("scale %s was reduced to %s: an image is at most 16 pixels per unit, the GPU's largest texture on a side and 100 Mpx", engine.num_text(asked), engine.num_text(render_scale)))
	}
}

// Encodes RGBA rows (top row first) as a PNG response (temp allocator).
encode_png_response :: proc(pixels: []u8, ow, oh: i32, asked: f32 = 0, alpha := false) -> string {
	png, ok := engine.png_encode(pixels, ow, oh, alpha)
	if !ok do return api_error("PNG encoding failed")
	encoded := base64.encode(png, allocator = context.temp_allocator)
	b := strings.builder_make(big_allocator())
	fmt.sbprintf(&b, `{{"ok":true,"result":{{"width":%d,"height":%d`, ow, oh)
	if asked > 0 do write_scale_note(&b, asked)
	fmt.sbprintf(&b, `,"png_base64":"%s"}}}}`, encoded)
	return strings.to_string(b)
}

// Applies synthetic input for the current frame: x/y move the pointer (and keep it there
// until "end"), press/release hold a button, keys/mods/chars/wheel act for this frame.
inject_input :: proc(params: json.Object) {
	if x, ok := params["x"].(json.Float); ok {
		pf.synthetic = true
		pf.synthetic_pos = {f32(x), f32(params["y"].(json.Float) or_else 0)}
		pf.mouse = pf.synthetic_pos
		app.mouse = pf.mouse / ui_scale()
	}
	if params["end"].(json.Boolean) or_else false do pf.synthetic = false
	button :: proc(name: string) -> int {
		switch name {
		case "left": return int(MOUSE_BUTTON_LEFT)
		case "middle": return int(MOUSE_BUTTON_MIDDLE)
		case "right": return int(MOUSE_BUTTON_RIGHT)
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
		case "enter": return KEY_ENTER
		case "backspace": return KEY_BACKSPACE
		case "delete": return KEY_DELETE
		case "escape": return KEY_ESCAPE
		case "tab": return KEY_TAB
		case "space": return KEY_SPACE
		case "left": return KEY_LEFT
		case "right": return KEY_RIGHT
		case "up": return KEY_UP
		case "down": return KEY_DOWN
		case "cmd": return KEY_LEFT_SUPER
		case "shift": return KEY_LEFT_SHIFT
		case "alt": return KEY_LEFT_ALT
		case "/": return KEY_SLASH
		case "'": return KEY_APOSTROPHE
		case "\\": return KEY_BACKSLASH
		case ",": return KEY_COMMA
		case "=": return KEY_EQUAL
		case "-": return KEY_MINUS
		case "]": return KEY_RIGHT_BRACKET
		case "[": return KEY_LEFT_BRACKET
		}
		if len(name) == 1 {
			ch := name[0]
			if ch >= 'a' && ch <= 'z' do return KEY_A + c.int(ch - 'a')
			if ch >= '0' && ch <= '9' do return KEY_0 + c.int(ch - '0')
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
		_ = engine.doc_theme_axes(doc)
		engine.theme_axes_free(&doc.theme_axes)
		names := make([dynamic]string, context.temp_allocator)
		for k in themes do append(&names, k)
		slice.sort(names[:])
		for k in names {
			arr, ok := themes[k].(json.Array)
			if !ok do return fmt.tprintf("themes.%s must be an array of values", k)
			axis := engine.Theme_Axis{name = strings.clone(k)}
			for v in arr do append(&axis.values, strings.clone(string(v.(json.String) or_else "")))
			append(&doc.theme_axes, axis)
		}
		engine.doc_theme_axes_write(doc)
		engine.theme_defaults(doc)
	}
	if has_vars {
		cur := engine.doc_variables(doc)
		for k, v in vars {
			if _, is_null := v.(json.Null); is_null do delete_key(&cur, k)
			else do cur[k] = v
		}
		engine.doc_write_variables(doc, cur)
	}
	if has_show {
		for k, v in show {
			val := string(v.(json.String) or_else "")
			if old, had := engine.theme[k]; had {
				delete(old)
				engine.theme[k] = strings.clone(val)
			} else {
				engine.theme[strings.clone(k)] = strings.clone(val)
			}
		}
	}
	engine.doc_retheme(doc)
	if has_themes || has_vars do mark_dirty()
	fmt.sbprintf(b, `{{"variables":%d,"themes":%d}}`, len(engine.doc_variables(doc)), len(engine.doc_theme_axes(doc)))
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
		_ = engine.doc_pages(doc)
		engine.pages_free(&doc.pages)
		for item in list {
			obj, ok := item.(json.Object)
			if !ok do return "each page is {name, nodes}"
			page := engine.Page{name = strings.clone(string(obj["name"].(json.String) or_else "Page"))}
			if ids, has := obj["nodes"].(json.Array); has {
				for id in ids do append(&page.ids, strings.clone(string(id.(json.String) or_else "")))
			}
			append(&doc.pages, page)
		}
		engine.doc_pages_write(doc)
		for &n in doc.nodes do if n.parent == 0 do n.page_seen = true
		mark_dirty()
	}
	page_switch(clamp(int(show) if has_show else app.page, 0, len(doc.pages) - 1))
	fmt.sbprintf(b, `{{"pages":%d,"shown":%d}}`, len(doc.pages), app.page)
	return ""
}
