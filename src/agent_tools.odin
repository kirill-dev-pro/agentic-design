package agentic_design

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"

// Tools for agents beyond reading and writing nodes:
//   batch       many edits as one step: all of them apply, or none (and one undo)
//   find_nodes  search by name, type, text, component or variable, without the whole tree
//   get_guide   what this document holds and how its parts are named (pen.dev's read_skill
//               is the model): pages, themes, variables, components, libraries, fonts
//   lint        what a reviewer would flag: hard-coded colours that have a variable, missing
//               fonts, text that does not fit its box, layers cut off by a clipping frame,
//               broken refs, positions and sizes off whole pixels, empty text

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
				n, _ := doc_find(&app.doc, string(v.(json.String) or_else ""))
				if n == nil {
					err = fmt.tprintf("node '%v' not found", v)
					break
				}
				append(&uids, n.uid)
			}
			if err == "" {
				for uid in uids do doc_delete(&app.doc, uid)
				prune_selection()
				strings.write_string(&sub, `{"deleted":true}`)
			}
		case "move":
			err = batch_move(&sub, o)
		case "set_variables":
			err = api_set_variables(&sub, o)
		case:
			err = "op must be create, update, delete, move or set_variables"
		}
		if err != "" {
			// undo everything this batch did
			doc_restore(&app.doc, app.undo_stack[snap])
			free_snapshot(app.undo_stack[snap])
			ordered_remove(&app.undo_stack, snap)
			prune_selection()
			app.needs_layout = true
			return fmt.tprintf("operation %d (%s) failed, nothing was changed: %s", i, kind, err)
		}
		if i > 0 do strings.write_byte(b, ',')
		strings.write_string(b, strings.to_string(sub) if strings.builder_len(sub) > 0 else "{}")
		layout_document(&app.doc) // later operations see where earlier ones put things
	}
	strings.write_string(b, "]}")
	return ""
}

// {"op": "move", "id", "parent_id"?, "before"?/"after"? (a sibling id), "position"?: "front"|"back"}
batch_move :: proc(b: ^strings.Builder, o: json.Object) -> string {
	n, _ := doc_find(&app.doc, string(o["id"].(json.String) or_else ""))
	if n == nil do return "move needs an existing id"
	uid := n.uid
	if pv, has := o["parent_id"]; has {
		np := 0
		if pid, is_str := pv.(json.String); is_str && pid != "" {
			p, _ := doc_find(&app.doc, string(pid))
			if p == nil || (p.kind != .Frame && p.kind != .Group) || p.uid == uid || is_descendant(&app.doc, p.uid, uid) do return "invalid parent_id"
			np = p.uid
		}
		doc_reparent(&app.doc, uid, np)
	}
	for key, place in ([2]string{"before", "after"}) {
		sid, has := o[key].(json.String)
		if !has do continue
		s, _ := doc_find(&app.doc, string(sid))
		if s == nil do return fmt.tprintf("%s: '%s' not found", key, sid)
		// in paint order: before = under the sibling, after = over it
		layer_move(uid, s.uid, 1 if place == 0 else -1)
	}
	if pos, has := o["position"].(json.String); has {
		if pos == "back" do send_to_back(uid)
		else do doc_bring_to_front(&app.doc, uid)
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
	ref := string(params["ref"].(json.String) or_else "")
	variable := strings.trim_prefix(string(params["variable"].(json.String) or_else ""), "$")
	limit := int(params["limit"].(json.Float) or_else 100)
	within := 0
	if w, has := params["within"].(json.String); has {
		n, _ := doc_find(&app.doc, string(w))
		if n == nil do return "within: node not found"
		within = n.uid
	}
	if name == "" && kind == "" && text == "" && ref == "" && variable == "" && within == 0 do return "pass name, type, text, ref, variable or within"
	token := fmt.tprintf(`"$%s"`, variable)
	strings.write_string(b, `{"nodes":[`)
	total := 0
	for &n in app.doc.nodes {
		if n.imported do continue
		if within != 0 && !is_descendant(&app.doc, n.uid, within) do continue
		if name != "" && !strings.contains(lower(node_label(&n)), name) do continue
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
		json_write_string(b, n.id)
		strings.write_string(b, `,"type":`)
		json_write_string(b, n.type_name)
		strings.write_string(b, `,"name":`)
		json_write_string(b, node_label(&n))
		if p, _ := doc_find_uid(&app.doc, n.parent); p != nil {
			strings.write_string(b, `,"parent":`)
			json_write_string(b, p.id)
		}
		if n.kind == .Text {
			strings.write_string(b, `,"content":`)
			json_write_string(b, n.content if len(n.content) <= 80 else fmt.tprintf("%s…", n.content[:80]))
		}
		fmt.sbprintf(b, `,"bounds":[%s,%s,%s,%s]}}`, num_text(n.x), num_text(n.y), num_text(n.w), num_text(n.h))
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
	for p, i in doc_pages(doc) {
		count := 0
		names := make([dynamic]string, context.temp_allocator)
		for &n in doc.nodes do if n.parent == 0 && !n.imported && page_of_top(doc, n.id) == i {
			count += 1
			if len(names) < 8 do append(&names, fmt.tprintf("%s (%s)", node_label(&n), n.id))
		}
		fmt.sbprintf(&g, "- %s: %d top-level layers%s%s\n", p.name, count, ": " if len(names) > 0 else "", strings.join(names[:], ", ", context.temp_allocator))
	}

	axes := doc_theme_axes(doc)
	if len(axes) > 0 {
		strings.write_string(&g, "\n## Themes\n")
		for a in axes do fmt.sbprintf(&g, "- %s: %s (shown: %s)\n", a.name, strings.join(a.values[:], ", ", context.temp_allocator), app.theme[a.name] if a.name in app.theme else a.values[0])
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
		for name in doc.var_defs {
			v, _ := var_get(doc, name)
			kinds := [Var_Kind]string{.Color = "color", .Number = "number", .String = "string", .Bool = "boolean"}
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
		fmt.sbprintf(&g, "\n## Variables (%d)\nUse them as \"$name\" in any property.\n", len(doc.var_defs))
		for k in keys {
			gr := groups[k]
			slice.sort(gr.names[:])
			shown := gr.names[:min(len(gr.names), 12)]
			fmt.sbprintf(&g, "- %s (%d): %s%s\n", k, gr.count, strings.join(shown, ", ", context.temp_allocator), ", …" if len(gr.names) > len(shown) else "")
		}
	}

	comps := make([dynamic]string, context.temp_allocator)
	for &n in doc.nodes do if n.reusable && !n.imported do append(&comps, fmt.tprintf("%s (%s)", node_label(&n), n.id))
	if len(comps) > 0 {
		fmt.sbprintf(&g, "\n## Components (%d)\nInsert as {{\"type\": \"ref\", \"ref\": \"<id>\"}}; override parts with \"descendants\": {{\"<child id>\": {{properties}}}}.\n", len(comps))
		for c in comps[:min(len(comps), 80)] do fmt.sbprintf(&g, "- %s\n", c)
		if len(comps) > 80 do fmt.sbprintf(&g, "- … %d more (find_nodes can search them)\n", len(comps) - 80)
	}

	imports := doc_imports(doc)
	if len(imports) > 0 {
		strings.write_string(&g, "\n## Libraries\nTheir components are refs \"alias:id\", their variables \"$alias:name\", and overrides inside them use keys \"alias:childId\".\n")
		for alias, rel in imports {
			names := make([dynamic]string, context.temp_allocator)
			for &n in doc.nodes do if n.imported && n.reusable && library_of(&n) == alias do append(&names, fmt.tprintf("%s (%s)", node_label(&n), n.id))
			fmt.sbprintf(&g, "- %s → %v: %s\n", alias, rel, strings.join(names[:min(len(names), 30)], ", ", context.temp_allocator))
		}
	}

	// fonts the document uses, and whether they are here
	fonts_scan()
	used := make(map[string]int, 8, context.temp_allocator)
	for &n in doc.nodes do if n.kind == .Text && !n.imported do used[n.font_family if n.font_family != "" else "(default)"] += 1
	if len(used) > 0 {
		strings.write_string(&g, "\n## Fonts\n")
		for fam, count in used {
			state := "installed"
			if fam == "(default)" do state = "Arial"
			else if family_find(fam) == nil do state = "MISSING: drawn with the system font (SF Pro), as pen.dev does; install it or put it in a fonts folder next to the file"
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
	json_write_string(b, strings.to_string(g))
	strings.write_byte(b, '}')
}

// ---------------------------------------------------------------- lint

api_lint :: proc(b: ^strings.Builder, params: json.Object) -> string {
	scope := uids_param(params, "ids")
	limit := int(params["limit"].(json.Float) or_else 200)
	doc := &app.doc
	in_scope :: proc(doc: ^Document, n: ^Node, scope: []int) -> bool {
		if n.imported do return false
		if len(scope) == 0 do return on_page(n.uid)
		for s in scope do if n.uid == s || is_descendant(doc, n.uid, s) do return true
		return false
	}
	// colour variables, to suggest one for a hard-coded colour
	Named :: struct {
		name:  string,
		color: Color,
	}
	palette := make([dynamic]Named, context.temp_allocator)
	for name, v in doc.vars do if v.kind == .Color do append(&palette, Named{name, v.color})
	closest :: proc(palette: []Named, c: Color) -> (string, int) {
		best, dist := "", 1 << 30
		for p in palette {
			d := 0
			for k in 0 ..< 4 do d += abs(int(p.color[k]) - int(c[k]))
			if d < dist || (d == dist && p.name < best) do best, dist = p.name, d
		}
		return best, dist
	}
	count := 0
	issue :: proc(b: ^strings.Builder, count: ^int, limit: int, n: ^Node, rule, msg: string) {
		count^ += 1
		if count^ > limit do return
		if count^ > 1 do strings.write_byte(b, ',')
		strings.write_string(b, `{"id":`)
		json_write_string(b, n.id)
		strings.write_string(b, `,"name":`)
		json_write_string(b, node_label(n))
		strings.write_string(b, `,"rule":`)
		json_write_string(b, rule)
		strings.write_string(b, `,"message":`)
		json_write_string(b, msg)
		strings.write_byte(b, '}')
	}
	strings.write_string(b, `{"issues":[`)
	// a missing font is one issue per family, not one per layer
	Missing :: struct {
		first: ^Node,
		count: int,
	}
	missing := make(map[string]Missing, 4, context.temp_allocator)
	missing_order := make([dynamic]string, context.temp_allocator)
	for &n in doc.nodes {
		if !in_scope(doc, &n, scope) do continue
		// hard-coded colours
		if len(palette) > 0 {
			for key in ([2]string{"fill", "stroke"}) {
				raw := prop_string(&n, key)
				if !strings.has_prefix(raw, "#") do continue
				c, ok := parse_color(raw)
				if !ok do continue
				name, d := closest(palette[:], c)
				if d == 0 do issue(b, &count, limit, &n, "hardcoded-color", fmt.tprintf("%s %s is the value of $%s; use the variable", key, raw, name))
				else if d <= 24 do issue(b, &count, limit, &n, "hardcoded-color", fmt.tprintf("%s %s is not a variable; $%s is close", key, raw, name))
				else do issue(b, &count, limit, &n, "hardcoded-color", fmt.tprintf("%s %s is not a variable", key, raw))
			}
		}
		#partial switch n.kind {
		case .Text:
			if strings.trim_space(n.content) == "" do issue(b, &count, limit, &n, "empty-text", "text layer without text")
			if n.font_family != "" && family_find(n.font_family) == nil {
				m, seen := missing[n.font_family]
				if !seen {
					m.first = &n
					append(&missing_order, n.font_family)
				}
				m.count += 1
				missing[n.font_family] = m
			}
			if n.growth == .Fixed_Width_Height {
				need := f32(len(text_lines(&n, n.w))) * n.font_size * line_height_of(&n)
				if need > n.h + 0.5 do issue(b, &count, limit, &n, "text-overflow", fmt.tprintf("the text needs %s px of height, the box has %s", num_text(need), num_text(n.h)))
			}
		case .Ref:
			if c, _ := doc_find(doc, n.ref); c == nil do issue(b, &count, limit, &n, "broken-ref", fmt.tprintf("component \"%s\" does not exist", n.ref))
		}
		// cut off by a clipping frame around it
		if p, _ := doc_find_uid(doc, n.parent); p != nil && p.clip && p.kind == .Frame {
			if n.x < p.x - 0.5 || n.y < p.y - 0.5 || n.x + n.w > p.x + p.w + 0.5 || n.y + n.h > p.y + p.h + 0.5 {
				issue(b, &count, limit, &n, "clipped", fmt.tprintf("partly outside \"%s\", which clips its content", node_label(p)))
			}
		}
		// off whole pixels (set values, not the result of a layout)
		frac :: proc(v: f32) -> bool {return abs(v - math.round(v)) >= 0.01}
		off := make([dynamic]string, context.temp_allocator)
		// x and y mean nothing inside a flex layout
		placed := !in_flow(doc, &n)
		if placed && prop_index(&n, "x") >= 0 && frac(n.pos.x) do append(&off, fmt.tprintf("x %s", num_text(n.pos.x)))
		if placed && prop_index(&n, "y") >= 0 && frac(n.pos.y) do append(&off, fmt.tprintf("y %s", num_text(n.pos.y)))
		if n.width.mode == .Fixed && n.width.has_value && frac(n.width.value) && n.kind != .Path do append(&off, fmt.tprintf("width %s", num_text(n.width.value)))
		if n.height.mode == .Fixed && n.height.has_value && frac(n.height.value) && n.kind != .Path do append(&off, fmt.tprintf("height %s", num_text(n.height.value)))
		if len(off) > 0 do issue(b, &count, limit, &n, "fractional", fmt.tprintf("not on whole pixels: %s", strings.join(off[:], ", ", context.temp_allocator)))
	}
	for fam in missing_order {
		m := missing[fam]
		issue(b, &count, limit, m.first, "missing-font", fmt.tprintf("font \"%s\" is not installed (used by %d text layers, drawn with the system font SF Pro, as in pen.dev); install it or put it in a fonts folder next to the file", fam, m.count))
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
		if string(alias) not_in doc_imports(doc) do return fmt.tprintf("no imported library \"%s\"", alias)
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
			write_json_value(&a, obj[k])
			write_json_value(&c, v)
			if strings.to_string(a) != strings.to_string(c) do node_set(doc, &n, k, v)
		}
	}
	// variables that point at renamed ones
	defs := doc_variables(doc)
	before := r.changes
	new_defs := rewrite(&r, defs).(json.Object)
	if r.changes > before do doc_write_variables(doc, new_defs)
	fmt.sbprintf(b, `{{"layers":%d,"variables":%d}}`, layers, r.changes - before if r.changes > before else 0)
	return ""
}

