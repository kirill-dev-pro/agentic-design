package engine

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

// Reading and writing .pen files (pencil.design). A .pen file is a JSON
// document: {"version": "...", "themes": {...}, "variables": {...},
// "children": [node, ...]} where each node has a "type", an "id" and its
// properties, and frames and groups nest their "children". Positions are
// relative to the parent. This app keeps every property it reads and writes
// them back unchanged, so the file survives a round trip even where the app
// only understands part of it.

PEN_VERSION :: "2.21"

doc_load :: proc(doc: ^Document, data: string) -> bool {
	root, err := json.parse_string(data, .JSON5, false, context.temp_allocator)
	if err != nil do return false
	obj, ok := root.(json.Object)
	if !ok do return false
	if _, has := obj["children"]; !has do return false
	doc_clear(doc)
	doc.next_uid = 0
	b := strings.builder_make(context.temp_allocator)
	for k, v in obj {
		if k == "children" do continue
		strings.builder_reset(&b)
		write_json_value(&b, v)
		append(&doc.header, Prop{strings.clone(k), strings.clone(strings.to_string(b))})
	}
	slice.sort_by(doc.header[:], proc(a, b: Prop) -> bool {
		return header_rank(a.key) < header_rank(b.key) || (header_rank(a.key) == header_rank(b.key) && a.key < b.key)
	})
	theme_defaults(doc)
	doc_resolve_vars(doc)
	if arr, is_arr := obj["children"].(json.Array); is_arr {
		for item in arr do node_from_json(doc, item, 0)
	}
	return true
}

// Where `key` goes among props kept in canonical order: by rank, then alphabetically.
canonical_index :: proc(props: []Prop, key: string, rank: proc(key: string) -> int) -> int {
	r := rank(key)
	for p, i in props {
		pr := rank(p.key)
		if pr > r || (pr == r && p.key > key) do return i
	}
	return len(props)
}

// Adds a header entry at its canonical place (the loader's order).
header_insert :: proc(doc: ^Document, key, raw: string) {
	inject_at(&doc.header, canonical_index(doc.header[:], key, header_rank), Prop{strings.clone(key), strings.clone(raw)})
}

header_rank :: proc(key: string) -> int {
	switch key {
	case "version": return 0
	case "themes": return 1
	case "variables": return 2
	}
	return 3
}

// Adds a node (and its children) from a .pen object. Returns the new uid.
node_from_json :: proc(doc: ^Document, v: json.Value, parent: int) -> (uid: int, err: string) {
	obj, ok := v.(json.Object)
	if !ok do return 0, "each node must be an object"
	if _, has := obj["type"]; !has do return 0, "node is missing 'type'"
	n: Node
	n.parent = parent
	b := strings.builder_make(context.temp_allocator)
	// .pen 2.21 keeps an instance's slot content in `descendants[slot].children`; it
	// becomes real child nodes of the instance (Node.slot_of) and is written back there
	Slot_Content :: struct {
		slot:     string,
		children: json.Array,
	}
	slotted := make([dynamic]Slot_Content, context.temp_allocator)
	for k, val in obj {
		if k == "children" do continue
		val := val
		if k == "descendants" {
			if desc, is_obj := val.(json.Object); is_obj {
				for path, entry in desc {
					e, e_obj := entry.(json.Object)
					if !e_obj do continue
					if kids, has := e["children"].(json.Array); has {
						if _, replaces := e["type"]; !replaces {
							append(&slotted, Slot_Content{path, kids})
							delete_key(&e, "children")
							desc[path] = e
						}
					}
				}
				for path, entry in desc do if e, e_obj := entry.(json.Object); e_obj && len(e) == 0 do delete_key(&desc, path)
				if len(desc) == 0 do continue
				val = desc
			}
		}
		strings.builder_reset(&b)
		write_json_value(&b, val)
		append(&n.props, Prop{strings.clone(k), strings.clone(strings.to_string(b))})
	}
	slice.sort_by(n.props[:], proc(a, b: Prop) -> bool {
		return prop_rank(a.key) < prop_rank(b.key) || (prop_rank(a.key) == prop_rank(b.key) && a.key < b.key)
	})
	_, n.children_key = obj["children"]
	if id, is_str := obj["id"].(json.String); is_str && !strings.contains(string(id), "/") {
		if existing, _ := doc_find(doc, string(id)); existing == nil do n.id = strings.clone(string(id))
	}
	added := doc_add(doc, n)
	uid = added.uid
	if children, has := obj["children"].(json.Array); has {
		for c in children {
			if _, cerr := node_from_json(doc, c, uid); cerr != "" do return uid, cerr
		}
	}
	for s in slotted {
		for c in s.children {
			cuid, cerr := node_from_json(doc, c, uid)
			if cerr != "" do return uid, cerr
			if cn, _ := doc_find_uid(doc, cuid); cn != nil do cn.slot_of = strings.clone(s.slot)
		}
	}
	return uid, ""
}

prop_rank :: proc(key: string) -> int {
	switch key {
	case "type": return 0
	case "id": return 1
	case "name": return 2
	}
	return 3
}

// Parses the "variables" header into doc.var_defs (every themed value of each
// variable) and fills doc.vars with the values for the theme shown now (theme);
// variables may point at other variables.
doc_resolve_vars :: proc(doc: ^Document) {
	vars_clear(doc)
	var_defs_free(doc)
	raw := ""
	for p in doc.header do if p.key == "variables" do raw = p.raw
	var_defs_add(doc, raw)
	var_defs_add(doc, doc.lib_vars)
	// the values for the theme shown now, for the palette and the Theme tab
	clear(&doc.resolve_theme)
	for k, v in theme do doc.resolve_theme[k] = v
	for name in doc.var_defs {
		if v, ok := var_get(doc, name); ok {
			if v.kind == .String do v.str = strings.clone(v.str)
			doc.vars[strings.clone(name)] = v
		}
	}
}

// Parses variable definitions (a JSON object) into doc.var_defs.
var_defs_add :: proc(doc: ^Document, raw: string) {
	if raw != "" {
		root, err := json.parse_string(raw, .JSON5, false, context.temp_allocator)
		if err == nil {
			if defs, ok := root.(json.Object); ok {
				for name, def in defs {
					d, is_obj := def.(json.Object)
					if !is_obj do continue
					kind := string(d["type"].(json.String) or_else "")
					entries := make([dynamic]Var_Entry)
					add :: proc(entries: ^[dynamic]Var_Entry, kind: string, val: json.Value, theme: json.Object) {
						e: Var_Entry
						if theme != nil {
							for k, v in theme do append(&e.theme, [2]string{strings.clone(k), strings.clone(string(v.(json.String) or_else ""))})
						}
						if s, is_str := val.(json.String); is_str && strings.has_prefix(string(s), "$") {
							e.ref = strings.clone(string(s)[1:])
							append(entries, e)
							return
						}
						switch kind {
						case "color":
							c, cok := parse_color(string(val.(json.String) or_else ""))
							if !cok do return
							e.var = {kind = .Color, color = c}
						case "number":
							#partial switch x in val {
							case json.Float: e.var = {kind = .Number, number = f32(x)}
							case json.Integer: e.var = {kind = .Number, number = f32(x)}
							case json.String:
								f, fok := strconv.parse_f32(string(x))
								if !fok do return
								e.var = {kind = .Number, number = f}
							case: return
							}
						case "string":
							e.var = {kind = .String, str = strings.clone(string(val.(json.String) or_else ""))}
						case "boolean":
							e.var = {kind = .Bool, b = val.(json.Boolean) or_else false}
						case:
							return
						}
						append(entries, e)
					}
					if arr, is_arr := d["value"].(json.Array); is_arr {
						for item in arr {
							if obj, is_entry := item.(json.Object); is_entry {
								th, _ := obj["theme"].(json.Object)
								add(&entries, kind, obj["value"], th)
							} else {
								add(&entries, kind, item, nil)
							}
						}
					} else {
						add(&entries, kind, d["value"], nil)
					}
					if len(entries) == 0 {
						delete(entries)
						continue
					}
					doc.var_defs[strings.clone(name)] = entries
				}
			}
		}
	}
}

// ---------------------------------------------------------------- writing

doc_serialize :: proc(doc: ^Document) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\n")
	has_version := false
	for p in doc.header do if p.key == "version" do has_version = true
	if !has_version do fmt.sbprintf(&b, "  \"version\": \"%s\",\n", PEN_VERSION)
	for p in doc.header {
		strings.write_string(&b, "  ")
		json_write_string(&b, p.key)
		strings.write_string(&b, ": ")
		strings.write_string(&b, p.raw)
		strings.write_string(&b, ",\n")
	}
	strings.write_string(&b, "  \"children\": [")
	write_children(&b, doc, 0, 2, false)
	strings.write_string(&b, "]\n}\n")
	return strings.to_string(b)
}

write_indent :: proc(b: ^strings.Builder, indent: int) {
	if indent < 0 do return
	strings.write_byte(b, '\n')
	for _ in 0 ..< indent do strings.write_string(b, "  ")
}

// An instance's `descendants` with its slot content added as `children` of the slot
// entries (compact JSON).
descendants_with_slots :: proc(doc: ^Document, n: ^Node, raw: string, api: bool) -> string {
	v, err := json.parse_string(raw, .JSON5, false, context.temp_allocator)
	desc, ok := v.(json.Object)
	if err != nil || !ok do desc = make(json.Object, context.temp_allocator)
	for cu in children_of(doc, n.uid) {
		c, _ := doc_find_uid(doc, cu)
		if c == nil || c.slot_of == "" do continue
		cb := strings.builder_make(context.temp_allocator)
		write_node(&cb, doc, c, -1, api)
		cv, cerr := json.parse_string(strings.to_string(cb), .JSON5, false, context.temp_allocator)
		if cerr != nil do continue
		entry, has := desc[c.slot_of].(json.Object)
		if !has do entry = make(json.Object, context.temp_allocator)
		kids, _ := entry["children"].(json.Array)
		append(&kids, cv)
		entry["children"] = kids
		desc[c.slot_of] = entry
	}
	b := strings.builder_make(context.temp_allocator)
	write_json_value(&b, desc)
	return strings.to_string(b)
}

// Writes the children of `parent` (0 = canvas) as a JSON array body (slot content of
// instances excluded: it is written into their `descendants`).
write_children :: proc(b: ^strings.Builder, doc: ^Document, parent: int, indent: int, api: bool) {
	count := 0
	// a library node's own children are imported too: write them when the parent is
	// written (get_document of a library component); never at the document's top level
	parent_imported := false
	if parent != 0 do if p, _ := doc_find_uid(doc, parent); p != nil do parent_imported = p.imported
	for &n in doc.nodes {
		if n.parent != parent || n.slot_of != "" || (n.imported && !parent_imported) do continue
		if count > 0 do strings.write_byte(b, ',')
		write_indent(b, indent)
		write_node(b, doc, &n, indent, api)
		count += 1
	}
	if count > 0 do write_indent(b, indent - 1)
}

// Writes one node as a .pen object. `indent` < 0 writes compact JSON.
// `api` adds the computed absolute box as "bounds".
// For agents: how many levels of children get_document writes (-1: all). Deeper
// containers report "childCount" instead.
api_depth_limit := -1
api_depth := 0

write_node :: proc(b: ^strings.Builder, doc: ^Document, n: ^Node, indent: int, api: bool) {
	strings.write_byte(b, '{')
	inner := indent + 1 if indent >= 0 else -1
	first := true
	// slot content (2.21) goes into `descendants`, the rest into `children`
	slotted, plain := 0, 0
	for cu in children_of(doc, n.uid) {
		if c, _ := doc_find_uid(doc, cu); c != nil {
			if c.slot_of != "" do slotted += 1
			else do plain += 1
		}
	}
	for p in n.props {
		if !first do strings.write_byte(b, ',')
		first = false
		write_indent(b, inner)
		json_write_string(b, p.key)
		strings.write_string(b, ": " if indent >= 0 else ":")
		if p.key == "descendants" && slotted > 0 do strings.write_string(b, descendants_with_slots(doc, n, p.raw, api))
		else do strings.write_string(b, p.raw)
	}
	if slotted > 0 && prop_index(n, "descendants") < 0 {
		if !first do strings.write_byte(b, ',')
		first = false
		write_indent(b, inner)
		strings.write_string(b, `"descendants": ` if indent >= 0 else `"descendants":`)
		strings.write_string(b, descendants_with_slots(doc, n, "{}", api))
	}
	if api {
		strings.write_byte(b, ',')
		write_indent(b, inner)
		fmt.sbprintf(b, `"bounds":[%s,%s,%s,%s]`, num_text(n.x), num_text(n.y), num_text(n.w), num_text(n.h))
		write_visual_bounds(b, n)
		if route, has := connector_routes[n.uid]; has && n.flow == .Connector {
			// where it runs, page coordinates, from shape to shape
			strings.write_string(b, `,"route":[`)
			for p, i in route {
				if i > 0 do strings.write_byte(b, ',')
				fmt.sbprintf(b, "[%s,%s]", num_text(p.x), num_text(p.y))
			}
			strings.write_byte(b, ']')
		}
	}
	if api && api_depth_limit >= 0 && api_depth >= api_depth_limit && plain > 0 {
		fmt.sbprintf(b, `,"childCount":%d`, plain)
	} else if plain > 0 || n.children_key {
		strings.write_byte(b, ',')
		write_indent(b, inner)
		strings.write_string(b, `"children": [` if indent >= 0 else `"children":[`)
		api_depth += 1
		write_children(b, doc, n.uid, inner + 1 if inner >= 0 else -1, api)
		api_depth -= 1
		strings.write_byte(b, ']')
	}
	write_indent(b, indent)
	strings.write_byte(b, '}')
}

// Compact JSON with sorted object keys and tidy numbers.
write_json_value :: proc(b: ^strings.Builder, v: json.Value) {
	#partial switch x in v {
	case json.Null:
		strings.write_string(b, "null")
	case json.Integer:
		fmt.sbprintf(b, "%d", x)
	case json.Float:
		if x == f64(i64(x)) && abs(x) < 1e15 do fmt.sbprintf(b, "%d", i64(x))
		else do fmt.sbprintf(b, "%v", x)
	case json.Boolean:
		strings.write_string(b, "true" if x else "false")
	case json.String:
		json_write_string(b, string(x))
	case json.Array:
		strings.write_byte(b, '[')
		for item, i in x {
			if i > 0 do strings.write_byte(b, ',')
			write_json_value(b, item)
		}
		strings.write_byte(b, ']')
	case json.Object:
		keys := make([]string, len(x), context.temp_allocator)
		i := 0
		for k in x {
			keys[i] = k
			i += 1
		}
		slice.sort(keys)
		strings.write_byte(b, '{')
		for k, j in keys {
			if j > 0 do strings.write_byte(b, ',')
			json_write_string(b, k)
			strings.write_byte(b, ':')
			write_json_value(b, x[k])
		}
		strings.write_byte(b, '}')
	case:
		strings.write_string(b, "null")
	}
}

json_write_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for r in s {
		switch r {
		case '"': strings.write_string(b, `\"`)
		case '\\': strings.write_string(b, `\\`)
		case '\n': strings.write_string(b, `\n`)
		case '\r': strings.write_string(b, `\r`)
		case '\t': strings.write_string(b, `\t`)
		case 0 ..< 0x20: fmt.sbprintf(b, `\u%04x`, int(r))
		case: strings.write_rune(b, r)
		}
	}
	strings.write_byte(b, '"')
}

// Empties doc.var_defs, names included (they were kept before: each change of the
// variables left a copy of every name behind).
var_defs_free :: proc(doc: ^Document) {
	for name, &entries in doc.var_defs {
		for &e in entries {
			for t in e.theme {
				delete(t[0])
				delete(t[1])
			}
			delete(e.theme)
			if e.var.kind == .String do delete(e.var.str)
			delete(e.ref)
		}
		delete(entries)
		delete(name)
	}
	clear(&doc.var_defs)
}


// ,"visual_bounds":[x, y, w, h]: the box around a layer as drawn, when it or an ancestor is
// rotated or flipped ("bounds" stays the layout box its x, y and size refer to).
write_visual_bounds :: proc(b: ^strings.Builder, n: ^Node) {
	if _, tr := node_transform(n); !tr do return
	v := node_page_box(n)
	fmt.sbprintf(b, `,"visual_bounds":[%s,%s,%s,%s]`, num_text(v[0]), num_text(v[1]), num_text(v[2]), num_text(v[3]))
}
