#+build !js
package agentic_design

import "engine"

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

// Tools for agents beyond reading and writing nodes:
//   batch       many edits as one step: all of them apply, or none (and one undo)
//   find_nodes  search by name, type, text, component or variable, without the whole tree
//   get_guide   what this document holds and how its parts are named (pen.dev's read_skill
//               is the model): pages, themes, variables, components, libraries, fonts
//   lint        what a reviewer would flag: hard-coded colours that have a variable, missing
//               fonts, text that does not fit its box, layers cut off by a clipping frame,
//               broken refs, positions and sizes off whole pixels, empty text, frames
//               fitting their content around a child that fills them (collapsed-size)

undo_suppressed: bool // inside a batch: the batch's own snapshot is the undo step

api_batch :: proc(b: ^strings.Builder, params: json.Object) -> string {
	ops, ok := params["operations"].(json.Array)
	if !ok || len(ops) == 0 do return "operations must be a non-empty array"
	push_undo()
	snap := len(app.undo_stack) - 1
	undo_suppressed = true
	defer undo_suppressed = false
	strings.write_string(b, `{"results":[`)
	for op, i in ops {
		o, is_obj := op.(json.Object)
		kind := string(o["op"].(json.String) or_else "") if is_obj else ""
		sub := strings.builder_make(context.temp_allocator)
		err := ""
		switch kind {
		case "create":
			err = api_create_nodes(&sub, o)
		case "update":
			if _, has := o["updates"]; has {
				err = api_update_nodes(&sub, o)
			} else {
				// the update itself: {"op": "update", "id": ..., properties}
				u := make(json.Object, len(o), context.temp_allocator)
				for k, v in o do if k != "op" do u[k] = v
				wrapped := make(json.Object, 1, context.temp_allocator)
				arr := make(json.Array, 1, context.temp_allocator)
				arr[0] = u
				wrapped["updates"] = arr
				err = api_update_nodes(&sub, wrapped)
			}
		case "delete":
			ids, _ := o["ids"].(json.Array)
			if id, has := o["id"].(json.String); has {
				ids = make(json.Array, 1, context.temp_allocator)
				ids[0] = id
			}
			uids := make([dynamic]int, context.temp_allocator)
			for v in ids {
				n, _ := engine.doc_find(&app.doc, string(v.(json.String) or_else ""))
				if n == nil {
					err = fmt.tprintf("node '%v' not found", v)
					break
				}
				append(&uids, n.uid)
			}
			if err == "" {
				engine.doc_delete_layers(&app.doc, uids[:])
				prune_selection()
				strings.write_string(&sub, `{"deleted":true}`)
			}
		case "move":
			err = batch_move(&sub, o)
		case "set_variables":
			err = api_set_variables(&sub, o)
		case "connect":
			err = api_connect(&sub, o)
		case:
			err = "op must be create, update, delete, move, connect or set_variables"
		}
		if err != "" {
			// undo everything this batch did
			engine.doc_restore(&app.doc, app.undo_stack[snap])
			engine.free_snapshot(app.undo_stack[snap])
			ordered_remove(&app.undo_stack, snap)
			prune_selection()
			app.needs_layout = true
			return fmt.tprintf("operation %d (%s) failed, nothing was changed: %s", i, kind, err)
		}
		if i > 0 do strings.write_byte(b, ',')
		strings.write_string(b, strings.to_string(sub) if strings.builder_len(sub) > 0 else "{}")
		engine.layout_document(&app.doc) // later operations see where earlier ones put things
	}
	strings.write_string(b, "]}")
	return ""
}

// {"op": "move", "id", "parent_id"?, "before"?/"after"? (a sibling id), "position"?: "front"|"back"}
batch_move :: proc(b: ^strings.Builder, o: json.Object) -> string {
	n, _ := engine.doc_find(&app.doc, string(o["id"].(json.String) or_else ""))
	if n == nil do return "move needs an existing id"
	uid := n.uid
	moved := false // by parent_id, before or after: then position is not the only move
	if pv, has := o["parent_id"]; has {
		moved = true
		np := 0
		if pid, is_str := pv.(json.String); is_str && pid != "" {
			p, _ := engine.doc_find(&app.doc, string(pid))
			if p == nil || (p.kind != .Frame && p.kind != .Group) || p.uid == uid || engine.is_descendant(&app.doc, p.uid, uid) do return "invalid parent_id"
			np = p.uid
		}
		engine.doc_reparent(&app.doc, uid, np)
	}
	for key, place in ([2]string{"before", "after"}) {
		sid, has := o[key].(json.String)
		if !has do continue
		s, _ := engine.doc_find(&app.doc, string(sid))
		if s == nil do return fmt.tprintf("%s: '%s' not found", key, sid)
		// in paint order: before = under the sibling, after = over it
		layer_move(uid, s.uid, 1 if place == 0 else -1)
		moved = true
	}
	if pos, has := o["position"].(json.String); has {
		note := arrange_hint({uid}, pos != "back", true)
		if note != "" && !moved {
			strings.write_string(b, `{"moved":false,"note":`)
			engine.json_write_string(b, note)
			strings.write_byte(b, '}')
			return ""
		}
		if note == "" {
			if pos == "back" do send_to_back(uid)
			else do engine.doc_bring_to_front(&app.doc, uid)
		}
	}
	strings.write_string(b, `{"moved":true}`)
	return ""
}

// ---------------------------------------------------------------- find_nodes

api_find_nodes :: proc(b: ^strings.Builder, params: json.Object) -> string {
	lower :: proc(s: string) -> string {return strings.to_lower(s, context.temp_allocator)}
	name := lower(string(params["name"].(json.String) or_else ""))
	kind := lower(string(params["type"].(json.String) or_else ""))
	text := lower(string(params["text"].(json.String) or_else ""))
	ref := string(params["ref"].(json.String) or_else (params["component"].(json.String) or_else ""))
	variable := strings.trim_prefix(string(params["variable"].(json.String) or_else ""), "$")
	limit := int(params["limit"].(json.Float) or_else 100)
	within := 0
	if w, has := params["within"].(json.String); has {
		n, _ := engine.doc_find(&app.doc, string(w))
		if n == nil do return "within: node not found"
		within = n.uid
	}
	if name == "" && kind == "" && text == "" && ref == "" && variable == "" && within == 0 do return "pass name, type, text, ref (or component), variable or within"
	token := fmt.tprintf(`"$%s"`, variable)
	strings.write_string(b, `{"nodes":[`)
	total := 0
	for &n in app.doc.nodes {
		if n.imported do continue
		if within != 0 && !engine.is_descendant(&app.doc, n.uid, within) do continue
		if name != "" && !strings.contains(lower(engine.node_label(&n)), name) do continue
		if kind != "" && lower(n.type_name) != kind do continue
		if text != "" && !strings.contains(lower(n.content), text) do continue
		if ref != "" && n.ref != ref do continue
		if variable != "" {
			used := false
			for p in n.props do if strings.contains(p.raw, token) do used = true
			if !used do continue
		}
		total += 1
		if total > limit do continue
		if total > 1 do strings.write_byte(b, ',')
		strings.write_string(b, `{"id":`)
		engine.json_write_string(b, n.id)
		strings.write_string(b, `,"type":`)
		engine.json_write_string(b, n.type_name)
		strings.write_string(b, `,"name":`)
		engine.json_write_string(b, engine.node_label(&n))
		if p, _ := engine.doc_find_uid(&app.doc, n.parent); p != nil {
			strings.write_string(b, `,"parent":`)
			engine.json_write_string(b, p.id)
		}
		if n.kind == .Text {
			strings.write_string(b, `,"content":`)
			engine.json_write_string(b, n.content if len(n.content) <= 80 else fmt.tprintf("%s…", n.content[:80]))
		}
		fmt.sbprintf(b, `,"bounds":[%s,%s,%s,%s]`, engine.num_text(n.x), engine.num_text(n.y), engine.num_text(n.w), engine.num_text(n.h))
		engine.write_visual_bounds(b, &n)
		strings.write_byte(b, '}')
	}
	// Text shown inside instances (the component's text or an override of it) lives in
	// the ghost copies. Report it as the instance plus the path to override it with
	// ("descendants": {"<path>": {"content": ...}}).
	if text != "" && ref == "" && variable == "" {
		engine.ghosts_sync(&app.doc)
		for gi := 0; gi < len(app.doc.ghosts); gi += 1 {
			g := &app.doc.ghosts[gi]
			if g.kind != .Text || !strings.contains(lower(g.content), text) do continue
			if kind != "" && lower(g.type_name) != kind do continue
			if name != "" && !strings.contains(lower(engine.node_label(g)), name) do continue
			// walk out through nested instances to the real one, collecting the path
			path := make([dynamic]string, context.temp_allocator)
			append(&path, g.ghost_of)
			inst, _ := engine.doc_find_uid(&app.doc, g.ghost_inst)
			for inst != nil && inst.ghost {
				append(&path, inst.ghost_of)
				inst, _ = engine.doc_find_uid(&app.doc, inst.ghost_inst)
			}
			if inst == nil || inst.imported do continue
			if within != 0 && inst.uid != within && !engine.is_descendant(&app.doc, inst.uid, within) do continue
			total += 1
			if total > limit do continue
			for i in 0 ..< len(path) / 2 do path[i], path[len(path) - 1 - i] = path[len(path) - 1 - i], path[i]
			if total > 1 do strings.write_byte(b, ',')
			strings.write_string(b, `{"id":`)
			engine.json_write_string(b, inst.id)
			strings.write_string(b, `,"type":"text","in_instance":true,"descendant":`)
			engine.json_write_string(b, strings.join(path[:], "/", context.temp_allocator))
			strings.write_string(b, `,"name":`)
			engine.json_write_string(b, engine.node_label(g))
			strings.write_string(b, `,"instance_name":`)
			engine.json_write_string(b, engine.node_label(inst))
			strings.write_string(b, `,"content":`)
			engine.json_write_string(b, g.content if len(g.content) <= 80 else fmt.tprintf("%s…", g.content[:80]))
			fmt.sbprintf(b, `,"bounds":[%s,%s,%s,%s]}}`, engine.num_text(g.x), engine.num_text(g.y), engine.num_text(g.w), engine.num_text(g.h))
		}
	}
	fmt.sbprintf(b, `],"total":%d}}`, total)
	return ""
}

// ---------------------------------------------------------------- get_guide

api_get_guide :: proc(b: ^strings.Builder) {
	g := strings.builder_make(context.temp_allocator)
	doc := &app.doc
	fmt.sbprintf(&g, "# %s\n\n", os.base(app.file_path))

	strings.write_string(&g, "## Pages\n")
	for p, i in engine.doc_pages(doc) {
		count := 0
		names := make([dynamic]string, context.temp_allocator)
		for &n in doc.nodes do if n.parent == 0 && !n.imported && engine.page_of_top(doc, n.id) == i {
			count += 1
			if len(names) < 8 do append(&names, fmt.tprintf("%s (%s)", engine.node_label(&n), n.id))
		}
		fmt.sbprintf(&g, "- %s: %d top-level layers%s%s\n", p.name, count, ": " if len(names) > 0 else "", strings.join(names[:], ", ", context.temp_allocator))
	}

	axes := engine.doc_theme_axes(doc)
	if len(axes) > 0 {
		strings.write_string(&g, "\n## Themes\n")
		for a in axes do fmt.sbprintf(&g, "- %s: %s (shown: %s)\n", a.name, strings.join(a.values[:], ", ", context.temp_allocator), engine.theme[a.name] if a.name in engine.theme else a.values[0])
		strings.write_string(&g, "Set a theme on a frame with \"theme\": {\"axis\": \"value\"}; its subtree resolves variables for it.\n")
	}

	// variables by kind and by their first word
	if len(doc.var_defs) > 0 {
		Group :: struct {
			kind:  string,
			count: int,
			names: [dynamic]string,
		}
		groups := make(map[string]Group, 16, context.temp_allocator)
		keys := make([dynamic]string, context.temp_allocator)
		// libraries' variables ("alias:name") are summarised after the document's own
		lib_groups := make(map[string]Group, 16, context.temp_allocator)
		lib_keys := make([dynamic]string, context.temp_allocator)
		own := 0
		kinds := [engine.Var_Kind]string{.Color = "color", .Number = "number", .String = "string", .Bool = "boolean"}
		for name in doc.var_defs {
			v, _ := engine.var_get(doc, name)
			if colon := strings.index_byte(name, ':'); colon > 0 {
				rest := name[colon + 1:]
				prefix := rest
				if i := strings.index_any(rest, "-/."); i > 0 do prefix = rest[:i]
				key := fmt.tprintf("%s %s", name[:colon], kinds[v.kind])
				gr, has := lib_groups[key]
				if !has {
					gr = Group{kind = kinds[v.kind], names = make([dynamic]string, context.temp_allocator)}
					append(&lib_keys, key)
				}
				gr.count += 1
				if !slice.contains(gr.names[:], prefix) do append(&gr.names, prefix)
				lib_groups[key] = gr
				continue
			}
			own += 1
			prefix := name
			if i := strings.index_any(name, "-/."); i > 0 do prefix = name[:i]
			key := fmt.tprintf("%s %s", kinds[v.kind], prefix)
			gr, has := groups[key]
			if !has {
				gr = Group{kind = kinds[v.kind], names = make([dynamic]string, context.temp_allocator)}
				append(&keys, key)
			}
			gr.count += 1
			append(&gr.names, name)
			groups[key] = gr
		}
		slice.sort(keys[:])
		if own > 0 {
			fmt.sbprintf(&g, "\n## Variables (%d)\nUse them as \"$name\" in any property.\n", own)
			for k in keys {
				gr := groups[k]
				slice.sort(gr.names[:])
				shown := gr.names[:min(len(gr.names), 12)]
				fmt.sbprintf(&g, "- %s (%d): %s%s\n", k, gr.count, strings.join(shown, ", ", context.temp_allocator), ", …" if len(gr.names) > len(shown) else "")
			}
		}
		if len(lib_keys) > 0 {
			slice.sort(lib_keys[:])
			fmt.sbprintf(&g, "\n## Library variables (%d)\nUse them as \"$alias:name\"; get_variables lists them all. Name prefixes:\n", len(doc.var_defs) - own)
			for k in lib_keys {
				gr := lib_groups[k]
				slice.sort(gr.names[:])
				shown := gr.names[:min(len(gr.names), 16)]
				fmt.sbprintf(&g, "- %s (%d): %s%s\n", k, gr.count, strings.join(shown, ", ", context.temp_allocator), ", …" if len(gr.names) > len(shown) else "")
			}
		}
	}

	comps := make([dynamic]string, context.temp_allocator)
	for &n in doc.nodes do if n.reusable && !n.imported do append(&comps, fmt.tprintf("%s (%s)", engine.node_label(&n), n.id))
	if len(comps) > 0 {
		fmt.sbprintf(&g, "\n## Components (%d)\nInsert as {{\"type\": \"ref\", \"ref\": \"<id>\"}}; override parts with \"descendants\": {{\"<child id>\": {{properties}}}}.\n", len(comps))
		for c in comps[:min(len(comps), 80)] do fmt.sbprintf(&g, "- %s\n", c)
		if len(comps) > 80 do fmt.sbprintf(&g, "- … %d more (find_nodes can search them)\n", len(comps) - 80)
	}

	imports := engine.doc_imports(doc)
	if len(imports) > 0 {
		strings.write_string(&g, "\n## Libraries\nTheir components are refs \"alias:id\", their variables \"$alias:name\", and overrides inside them use keys \"alias:childId\".\n")
		for alias in engine.sorted_keys(imports) {
			rel := imports[alias]
			names := make([dynamic]string, context.temp_allocator)
			for &n in doc.nodes do if n.imported && n.reusable && engine.library_of(&n) == alias do append(&names, fmt.tprintf("%s (%s)", engine.node_label(&n), n.id))
			fmt.sbprintf(&g, "- %s → %v: %s\n", alias, rel, strings.join(names[:min(len(names), 30)], ", ", context.temp_allocator))
		}
	}

	// fonts the document uses, and whether they are here
	engine.fonts_scan()
	used := make(map[string]int, 8, context.temp_allocator)
	for &n in doc.nodes do if n.kind == .Text && !n.imported do used[n.font_family if n.font_family != "" else "(default)"] += 1
	if len(used) > 0 {
		strings.write_string(&g, "\n## Fonts\n")
		for fam in engine.sorted_keys(used) {
			count := used[fam]
			state := "in the document's fonts"
			if fam == "(default)" do state = "Arial"
			else if engine.font_source(fam) != .Document do state = fmt.tprintf("NOT IN THE DOCUMENT: %s", engine.font_state(fam))
			fmt.sbprintf(&g, "- %s: %d text layers, %s\n", fam, count, state)
		}
	}

	strings.write_string(&g, `
## Working with this file
- Read: get_document with "depth" and "ids" for big files, find_nodes to locate layers, get_styles for the CSS of a layer.
- Write: batch for several edits (one undo step; all or nothing), create_nodes / update_nodes for single ones.
- Check: screenshot to look, lint to catch hard-coded colours, missing fonts, text that does not fit and layers cut off.
- Frames default to a horizontal flex layout; give "layout": "none" and a size for a free-form board. x/y are relative to the parent and ignored inside flex layouts.
`)
	strings.write_string(b, `{"markdown":`)
	engine.json_write_string(b, strings.to_string(g))
	strings.write_byte(b, '}')
}

// ---------------------------------------------------------------- lint

api_lint :: proc(b: ^strings.Builder, params: json.Object) -> string {
	scope := uids_param(params, "ids")
	limit := int(params["limit"].(json.Float) or_else 200)
	doc := &app.doc
	in_scope :: proc(doc: ^engine.Document, n: ^engine.Node, scope: []int) -> bool {
		if n.imported do return false
		if len(scope) == 0 do return on_page(n.uid)
		for s in scope do if n.uid == s || engine.is_descendant(doc, n.uid, s) do return true
		return false
	}
	// colour variables, to suggest one for a hard-coded colour
	Named :: struct {
		name:  string,
		color: engine.Color,
	}
	palette := make([dynamic]Named, context.temp_allocator)
	for name, v in doc.vars do if v.kind == .Color do append(&palette, Named{name, v.color})
	closest :: proc(doc: ^engine.Document, palette: []Named, c: engine.Color) -> (string, int) {
		// a variable that keeps its value in every theme wins over one that only has
		// this value in the theme shown now; then the document's own over a library's
		best, dist, best_fixed, best_own := "", 1 << 30, false, false
		for p in palette {
			d := 0
			for k in 0 ..< 4 do d += abs(int(p.color[k]) - int(c[k]))
			fixed := var_constant(doc, p.name)
			own := !strings.contains(p.name, ":")
			better := d < dist
			if d == dist {
				if fixed != best_fixed do better = fixed
				else if own != best_own do better = own
				else do better = p.name < best
			}
			if better do best, dist, best_fixed, best_own = p.name, d, fixed, own
		}
		return best, dist
	}
	// "light" for a variable whose value is `c` only under some themes
	themes_with :: proc(doc: ^engine.Document, name: string, c: engine.Color) -> string {
		parts := make([dynamic]string, context.temp_allocator)
		defs := doc.var_defs[name] // (a copy: see engine.connector_obstacles)
		for e in defs {
			if e.ref != "" || e.var.kind != .Color || e.var.color != c do continue
			if len(e.theme) == 0 do append(&parts, "by default")
			for t in e.theme do append(&parts, fmt.tprintf("in %s %s", t[0], t[1]))
		}
		return strings.join(parts[:], ", ", context.temp_allocator) if len(parts) > 0 else "in the theme shown now"
	}
	count := 0
	lint_skip_rules = nil
	if arr, ok := params["ignore"].(json.Array); ok {
		rules := make([dynamic]string, context.temp_allocator)
		for v in arr do append(&rules, string(v.(json.String) or_else ""))
		lint_skip_rules = rules[:]
	}
	issue :: proc(b: ^strings.Builder, count: ^int, limit: int, n: ^engine.Node, rule, msg: string) {
		if lint_ignored(n, rule) do return
		count^ += 1
		if count^ > limit do return
		if count^ > 1 do strings.write_byte(b, ',')
		strings.write_string(b, `{"id":`)
		engine.json_write_string(b, n.id)
		strings.write_string(b, `,"name":`)
		engine.json_write_string(b, engine.node_label(n))
		strings.write_string(b, `,"rule":`)
		engine.json_write_string(b, rule)
		strings.write_string(b, `,"message":`)
		engine.json_write_string(b, msg)
		strings.write_byte(b, '}')
	}
	strings.write_string(b, `{"issues":[`)
	// a missing font is one issue per family, not one per layer
	Missing :: struct {
		first: ^engine.Node,
		count: int,
	}
	missing := make(map[string]Missing, 4, context.temp_allocator)
	missing_order := make([dynamic]string, context.temp_allocator)
	for &n in doc.nodes {
		if !in_scope(doc, &n, scope) do continue
		// hard-coded colours
		if len(palette) > 0 {
			for key in ([2]string{"fill", "stroke"}) {
				raw := engine.prop_string(&n, key)
				if !strings.has_prefix(raw, "#") do continue
				c, ok := engine.parse_color(raw)
				if !ok do continue
				name, d := closest(doc, palette[:], c)
				if d == 0 && !var_constant(doc, name) do issue(b, &count, limit, &n, "hardcoded-color", fmt.tprintf("%s %s is not a variable; $%s has this value only %s and changes with the theme, so use it only if this colour should follow the theme", key, raw, name, themes_with(doc, name, c)))
				else if d == 0 do issue(b, &count, limit, &n, "hardcoded-color", fmt.tprintf("%s %s is the value of $%s; use the variable", key, raw, name))
				else if d <= 24 do issue(b, &count, limit, &n, "hardcoded-color", fmt.tprintf("%s %s is not a variable; $%s is close", key, raw, name))
				else do issue(b, &count, limit, &n, "hardcoded-color", fmt.tprintf("%s %s is not a variable", key, raw))
			}
		}
		#partial switch n.kind {
		case .Text:
			if strings.trim_space(n.content) == "" do issue(b, &count, limit, &n, "empty-text", "text layer without text")
			if n.font_family != "" && engine.font_source(n.font_family) != .Document {
				m, seen := missing[n.font_family]
				if !seen {
					m.first = &n
					append(&missing_order, n.font_family)
				}
				m.count += 1
				missing[n.font_family] = m
			}
			if n.growth == .Fixed_Width_Height {
				need := f32(len(engine.text_lines(&n, n.w))) * n.font_size * engine.line_height_of(&n)
				if need > n.h + 0.5 do issue(b, &count, limit, &n, "text-overflow", fmt.tprintf("the text needs %s px of height, the box has %s", engine.num_text(need), engine.num_text(n.h)))
			}
		case .Icon:
			if msg := engine.icon_problem(&n); msg != "" do issue(b, &count, limit, &n, "unknown-icon", msg)

		case .Ref:
			if c, _ := engine.doc_find(doc, n.ref); c == nil do issue(b, &count, limit, &n, "broken-ref", fmt.tprintf("component \"%s\" does not exist", n.ref))
		case .Frame:
			// pen.dev's "Collapsed size": a frame fitting its content on an axis where a child
			// fills it; the child gets only what the other children give the frame
			// (layout.odin), which is rarely what was meant
			if n.layout != .None {
				axes := [2]string{"width", "height"}
				specs := [2]engine.Size_Spec{n.width, n.height}
				for i in 0 ..< 2 {
					if specs[i].mode != .Fit || specs[i].has_value do continue
					for cu in engine.children_for_layout(doc, n.uid) {
						c, _ := engine.doc_find_uid(doc, cu)
						if c == nil || !c.enabled || c.abs_pos do continue
						if ([2]engine.Size_Spec{c.width, c.height})[i].mode != .Fill do continue
						issue(b, &count, limit, &n, "collapsed-size", fmt.tprintf("its %s fits its content while \"%s\" fills it, so that child only gets %s px (what the others need); give this frame a %s (a number or fill_container), or the child its own", axes[i], engine.node_label(c), engine.num_text(([2]f32{c.w, c.h})[i]), axes[i]))
						break
					}
				}
			}
		}
		// an image fill whose file is not there or not readable draws nothing, silently (D106)
		if n.image_url != "" {
			if img, _, _ := engine.image_for(n.image_url); img == 0 do issue(b, &count, limit, &n, "missing-image", fmt.tprintf("image %s cannot be read (%s)", n.image_url, engine.image_resolve(n.image_url)))
		}
		// rich text whose runs no longer join up to the content: drawn plain
		if n.kind == .Text && n.spans_bad && !n.ghost do issue(b, &count, limit, &n, "spans-mismatch", "its spans' texts do not join up to its content (changed outside Agentic Design?), so it is drawn without them; set spans again")
		// cut off by a clipping frame around it
		// (a rotated or flipped layer by its drawn corners, in the parent's own space: the
		// transforms above the parent move both alike)
		if p, _ := engine.doc_find_uid(doc, n.parent); p != nil && p.clip && p.kind == .Frame {
			box := own_drawn_box(&n)
			if box[0] < p.x - 0.5 || box[1] < p.y - 0.5 || box[0] + box[2] > p.x + p.w + 0.5 || box[1] + box[3] > p.y + p.h + 0.5 {
				issue(b, &count, limit, &n, "clipped", fmt.tprintf("partly outside \"%s\", which clips its content", engine.node_label(p)))
			}
		}
		// off whole pixels (set values, not the result of a layout)
		frac :: proc(v: f32) -> bool {return abs(v - math.round(v)) >= 0.01}
		off := make([dynamic]string, context.temp_allocator)
		// x and y mean nothing inside a flex layout; connectors, their labels and shape
		// outlines are placed and sized by the app
		computed := n.flow == .Connector || n.flow == .Label || engine.is_shape_outline(&n)
		placed := !engine.in_flow(doc, &n) && !computed
		if placed && engine.prop_index(&n, "x") >= 0 && frac(n.pos.x) do append(&off, fmt.tprintf("x %s", engine.num_text(n.pos.x)))
		if placed && engine.prop_index(&n, "y") >= 0 && frac(n.pos.y) do append(&off, fmt.tprintf("y %s", engine.num_text(n.pos.y)))
		if !computed && n.width.mode == .Fixed && n.width.has_value && frac(n.width.value) && n.kind != .Path do append(&off, fmt.tprintf("width %s", engine.num_text(n.width.value)))
		if !computed && n.height.mode == .Fixed && n.height.has_value && frac(n.height.value) && n.kind != .Path do append(&off, fmt.tprintf("height %s", engine.num_text(n.height.value)))
		if len(off) > 0 do issue(b, &count, limit, &n, "fractional", fmt.tprintf("not on whole pixels: %s", strings.join(off[:], ", ", context.temp_allocator)))
	}
	// text drawn inside instances (a component's or a library's text, or an override) uses
	// fonts too; the issue points at the instance
	engine.ghosts_sync(doc)
	for gi := 0; gi < len(doc.ghosts); gi += 1 {
		gt := &doc.ghosts[gi]
		if gt.kind != .Text || !gt.enabled || gt.font_family == "" || engine.font_source(gt.font_family) == .Document do continue
		inst, _ := engine.doc_find_uid(doc, gt.ghost_inst)
		for inst != nil && inst.ghost do inst, _ = engine.doc_find_uid(doc, inst.ghost_inst)
		if inst == nil || !in_scope(doc, inst, scope) do continue
		m, seen := missing[gt.font_family]
		if !seen {
			m.first = inst
			append(&missing_order, gt.font_family)
		}
		m.count += 1
		missing[gt.font_family] = m
	}
	for fam in missing_order {
		m := missing[fam]
		issue(b, &count, limit, m.first, "missing-font", fmt.tprintf("font \"%s\" (used by %d text layers, those inside instances included) %s", fam, m.count, engine.font_state(fam)))
	}
	// diagrams: connectors through boxes, overlapping connectors and labels, free arrows
	for d in diagram_issues() {
		n, _ := engine.doc_find_uid(doc, d.uid)
		if n != nil && in_scope(doc, n, scope) do issue(b, &count, limit, n, d.rule, d.msg)
	}
	fmt.sbprintf(b, `],"count":%d}}`, count)
	return ""
}

// ---------------------------------------------------------------- rename_references

// Points references at other names in every layer and variable: variables ("$old" →
// "$new"), instance refs (an instance moved to "alias:id" also gets its descendant keys
// prefixed "alias:", as pen.dev names the parts of a library component), or, with
// `library`, every variable and component that the imported library also has.
api_rename_references :: proc(b: ^strings.Builder, params: json.Object) -> string {
	doc := &app.doc
	vars := make(map[string]string, 16, context.temp_allocator)
	refs := make(map[string]string, 16, context.temp_allocator)
	if vm, ok := params["variables"].(json.Object); ok {
		for k, v in vm do vars[strings.trim_prefix(k, "$")] = strings.trim_prefix(string(v.(json.String) or_else ""), "$")
	}
	if rm, ok := params["refs"].(json.Object); ok {
		for k, v in rm do refs[k] = string(v.(json.String) or_else "")
	}
	if alias, ok := params["library"].(json.String); ok {
		if string(alias) not_in engine.doc_imports(doc) do return fmt.tprintf("no imported library \"%s\"", alias)
		prefix := fmt.tprintf("%s:", alias)
		for &n in doc.nodes do if n.imported && strings.has_prefix(n.id, prefix) do refs[n.id[len(prefix):]] = n.id
		for name in doc.var_defs do if strings.has_prefix(name, prefix) do vars[name[len(prefix):]] = name
	}
	if len(vars) == 0 && len(refs) == 0 do return "pass variables, refs or library"
	push_undo()
	R :: struct {
		vars, refs: ^map[string]string,
		changes:    int,
	}
	r := R{&vars, &refs, 0}
	rewrite :: proc(r: ^R, v: json.Value) -> json.Value {
		#partial switch x in v {
		case json.Object:
			out := make(json.Object, len(x), context.temp_allocator)
			old_ref := string(x["ref"].(json.String) or_else "")
			new_ref, renamed := r.refs[old_ref]
			// "c-btn" → "ui:c-btn": the parts are "ui:<child>" too
			key_prefix := new_ref[:len(new_ref) - len(old_ref)] if renamed && strings.has_suffix(new_ref, old_ref) else ""
			for k, val in x {
				switch {
				case k == "ref" && renamed:
					out[k] = json.String(new_ref)
					r.changes += 1
				case k == "descendants" && key_prefix != "":
					d, _ := val.(json.Object)
					m := make(json.Object, len(d), context.temp_allocator)
					for path, ov in d {
						parts := strings.split(path, "/", context.temp_allocator)
						for &p in parts do if !strings.has_prefix(p, key_prefix) do p = fmt.tprintf("%s%s", key_prefix, p)
						m[strings.join(parts, "/", context.temp_allocator)] = rewrite(r, ov)
					}
					out[k] = m
					r.changes += 1
				case:
					out[k] = rewrite(r, val)
				}
			}
			return out
		case json.Array:
			out := make(json.Array, len(x), context.temp_allocator)
			for item, i in x do out[i] = rewrite(r, item)
			return out
		case json.String:
			if strings.has_prefix(string(x), "$") {
				if to, ok := r.vars[string(x)[1:]]; ok {
					r.changes += 1
					return json.String(fmt.tprintf("$%s", to))
				}
			}
		}
		return v
	}
	layers := 0
	for &n in doc.nodes {
		if n.imported do continue
		obj := make(json.Object, len(n.props), context.temp_allocator)
		for p in n.props {
			if v, err := json.parse_string(p.raw, .JSON5, false, context.temp_allocator); err == nil do obj[p.key] = v
		}
		before := r.changes
		out := rewrite(&r, obj).(json.Object)
		if r.changes == before do continue
		layers += 1
		for k, v in out {
			a := strings.builder_make(context.temp_allocator)
			c := strings.builder_make(context.temp_allocator)
			engine.write_json_value(&a, obj[k])
			engine.write_json_value(&c, v)
			if strings.to_string(a) != strings.to_string(c) do engine.node_set(doc, &n, k, v)
		}
	}
	// variables that point at renamed ones
	defs := engine.doc_variables(doc)
	before := r.changes
	new_defs := rewrite(&r, defs).(json.Object)
	if r.changes > before do engine.doc_write_variables(doc, new_defs)
	fmt.sbprintf(b, `{{"layers":%d,"variables":%d}}`, layers, r.changes - before if r.changes > before else 0)
	return ""
}

// Whether a variable has the same value under every theme (no themed entries that
// differ, references followed).
var_constant :: proc(doc: ^engine.Document, name: string, depth := 0) -> bool {
	entries, has := doc.var_defs[name]
	if !has || len(entries) == 0 || depth > 8 do return true
	first: engine.Var
	have := false
	for e in entries {
		v := e.var
		if e.ref != "" {
			ref := strings.trim_prefix(e.ref, "$")
			if !var_constant(doc, ref, depth + 1) do return false
			v, _ = engine.var_get(doc, ref)
		}
		if !have {
			first, have = v, true
			continue
		}
		if v.kind != first.kind || v.color != first.color || v.number != first.number || v.str != first.str || v.b != first.b do return false
	}
	return true
}

// A layer's box after its own rotation and flips (around its top-left corner), not its
// ancestors'.
own_drawn_box :: proc(n: ^engine.Node) -> [4]f32 {
	if n.rotation == 0 && !n.flip_x && !n.flip_y do return {n.x, n.y, n.w, n.h}
	t := -n.rotation * math.PI / 180
	cs, sn := math.cos(t), math.sin(t)
	sx: f32 = -1 if n.flip_x else 1
	sy: f32 = -1 if n.flip_y else 1
	lo, hi := [2]f32{max(f32), max(f32)}, [2]f32{min(f32), min(f32)}
	for c in ([4][2]f32{{0, 0}, {n.w, 0}, {n.w, n.h}, {0, n.h}}) {
		x, y := c.x * sx, c.y * sy
		p := [2]f32{n.x + cs * x - sn * y, n.y + sn * x + cs * y}
		lo = {min(lo.x, p.x), min(lo.y, p.y)}
		hi = {max(hi.x, p.x), max(hi.y, p.y)}
	}
	return {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y}
}

// ---------------------------------------------------------------- scale_nodes

// Scales layers and everything inside them by a factor, as if the subtree were drawn
// smaller or larger, by rewriting its numbers: sizes, positions inside it, font sizes,
// letter spacing, gaps, padding, corner radii, stroke thickness and dashes, effect offsets,
// blur and spread, and the same keys in instance overrides and slot content. The scaled
// layers keep their own place. The result is plain .pen (pen.dev has no scale property),
// one undo step. Variables ($name) are left as they are; instances keep their component's
// inner sizes, so they are reported.
api_scale_nodes :: proc(b: ^strings.Builder, params: json.Object) -> string {
	uids := uids_param(params, "ids")
	if len(uids) == 0 do return "pass ids: the layers to scale"
	factor := f64(params["factor"].(json.Float) or_else 0)
	if factor <= 0 || factor > 100 do return "factor must be a number above 0 (0.64 makes it 64% as big)"
	push_undo()
	Scale_Report :: struct {
		layers:    int,
		variables: [dynamic]string,
		instances: [dynamic]string,
	}
	report := Scale_Report{variables = make([dynamic]string, context.temp_allocator), instances = make([dynamic]string, context.temp_allocator)}
	scale_value :: proc(v: json.Value, f: f64, key: string, report: ^Scale_Report) -> json.Value {
		#partial switch x in v {
		case json.Float:
			return json.Float(x * f)
		case json.Integer:
			return json.Float(f64(x) * f)
		case json.String:
			s := string(x)
			if strings.has_prefix(s, "$") {
				if !slice.contains(report.variables[:], s) do append(&report.variables, s)
				return v
			}
			// fit_content(120) / fill_container(80): the fallback size scales too
			if open := strings.index_byte(s, '('); open > 0 && strings.has_suffix(s, ")") {
				if n, ok := strconv.parse_f64(s[open + 1:len(s) - 1]); ok do return json.String(fmt.aprintf("%s(%s)", s[:open], engine.num_text(f32(n * f)), allocator = context.temp_allocator))
			}
			return v
		case json.Array:
			out := make(json.Array, len(x), context.temp_allocator)
			for item, i in x do out[i] = scale_value(item, f, key, report)
			return out
		case json.Object:
			return scale_props(x, f, false, report)
		}
		return v
	}
	// The keys of one node, override or paint/effect object that hold lengths.
	scale_props :: proc(obj: json.Object, f: f64, keep_place: bool, report: ^Scale_Report) -> json.Object {
		out := make(json.Object, len(obj), context.temp_allocator)
		for k, v in obj {
			switch k {
			case "x", "y":
				out[k] = v if keep_place else scale_value(v, f, k, report)
			case "width", "height", "gap", "padding", "cornerRadius", "fontSize", "letterSpacing", "strokeWidth", "strokeDashPattern", "thickness", "dashPattern", "blur", "spread", "radius", "top", "right", "bottom", "left":
				out[k] = scale_value(v, f, k, report)
			case "offset", "stroke", "effect":
				out[k] = scale_value(v, f, k, report)
			case "metadata":
				// the app's own lengths kept in metadata (the dash pattern), nothing else of it
				if m, ok := v.(json.Object); ok && engine.DASH_KEY in m {
					nm := make(json.Object, len(m), context.temp_allocator)
					for mk, mv in m do nm[mk] = scale_value(mv, f, mk, report) if mk == engine.DASH_KEY else mv
					out[k] = nm
				} else do out[k] = v
			case "descendants":
				// overrides by id, and slot content (their children) inside them
				if d, ok := v.(json.Object); ok {
					nd := make(json.Object, len(d), context.temp_allocator)
					for id, o in d {
						if oo, ok2 := o.(json.Object); ok2 do nd[id] = scale_props(oo, f, false, report)
						else do nd[id] = o
					}
					out[k] = nd
				} else do out[k] = v
			case "children":
				if arr, ok := v.(json.Array); ok {
					na := make(json.Array, len(arr), context.temp_allocator)
					for c, i in arr {
						if co, ok2 := c.(json.Object); ok2 do na[i] = scale_props(co, f, false, report)
						else do na[i] = c
					}
					out[k] = na
				} else do out[k] = v
			case:
				out[k] = v
			}
		}
		return out
	}
	scale_node :: proc(uid: int, f: f64, keep_place: bool, report: ^Scale_Report) {
		n, _ := engine.doc_find_uid(&app.doc, uid)
		if n == nil || n.ghost || n.imported do return
		report.layers += 1
		if n.kind == .Ref && !slice.contains(report.instances[:], n.id) do append(&report.instances, n.id)
		obj := make(json.Object, len(n.props), context.temp_allocator)
		for p in n.props {
			v, err := json.parse_string(p.raw, .JSON5, false, context.temp_allocator)
			if err == nil do obj[p.key] = v
		}
		scaled := scale_props(obj, f, keep_place, report)
		for k, v in scaled {
			if k == "children" do continue
			b := strings.builder_make(context.temp_allocator)
			engine.write_json_value(&b, v)
			engine.node_set_raw(n, k, strings.to_string(b))
		}
		engine.node_refresh(&app.doc, n)
		kids := make([dynamic]int, context.temp_allocator)
		append(&kids, ..engine.children_of(&app.doc, uid))
		for c in kids do scale_node(c, f, false, report)
	}
	for uid in uids do scale_node(uid, factor, true, &report)
	engine.doc_bump(&app.doc)
	mark_dirty()
	fmt.sbprintf(b, `{{"scaled":%d`, report.layers)
	if len(report.variables) > 0 {
		strings.write_string(b, `,"variables_unchanged":[`)
		for v, i in report.variables {
			if i > 0 do strings.write_byte(b, ',')
			engine.json_write_string(b, v)
		}
		strings.write_byte(b, ']')
	}
	if len(report.instances) > 0 {
		strings.write_string(b, `,"instances":[`)
		for v, i in report.instances {
			if i > 0 do strings.write_byte(b, ',')
			engine.json_write_string(b, v)
		}
		strings.write_string(b, `],"note":"instances keep their component's inner sizes: scale the component, or override its parts"`)
	}
	strings.write_byte(b, '}')
	return ""
}
