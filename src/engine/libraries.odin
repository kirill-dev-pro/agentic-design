package engine

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"

// Design libraries, as in pen.dev: the header's `imports` maps an alias to another .pen
// file (by convention a .lib.pen). Its layers and variables are read into this document
// under the alias, the names pen.dev uses: the component "btn" is "ui:btn", the variable
// "brand" is "$ui:brand" and a descendant override key is "ui:label". They are flagged
// `imported`, so refs and overrides resolve as for local components while saving, the
// layer tree, pages and the agent API leave them out. A library is read again whenever
// the document opens, and when its file changes on disk (libraries_refresh).

Library :: struct {
	alias, path: string,
	ok:          bool,
}

// The imports of a document: alias -> path relative to it.
doc_imports :: proc(doc: ^Document) -> json.Object {
	for p in doc.header do if p.key == "imports" {
		v, err := json.parse_string(p.raw, .JSON5, false, context.temp_allocator)
		if err == nil do if obj, ok := v.(json.Object); ok do return obj
	}
	return nil
}

// Reads every imported library into the document (dropping what an earlier read added).
doc_load_imports :: proc(doc: ^Document, doc_path: string) -> []Library {
	libs := make([dynamic]Library, context.temp_allocator)
	for i := len(doc.nodes) - 1; i >= 0; i -= 1 {
		if i < len(doc.nodes) && doc.nodes[i].imported && doc.nodes[i].parent == 0 do doc_delete(doc, doc.nodes[i].uid)
	}
	delete(doc.lib_vars)
	doc.lib_vars = ""
	imports := doc_imports(doc)
	vars := make(json.Object, 16, context.temp_allocator)
	base := path_dir(doc_path)
	// the fonts the document and its libraries list (fonts_add_declared)
	for p in doc.header do if p.key == "fonts" {
		if v, err := json.parse_string(p.raw, .JSON5, false, context.temp_allocator); err == nil do fonts_add_declared(v, base)
	}
	for alias, rel in imports {
		path := string(rel.(json.String) or_else "")
		if !path_is_abs(path) do path = path_join(base, path)
		lib := Library{alias = alias, path = path}
		defer append(&libs, lib)
		data, ok := read_file(path, context.temp_allocator)
		if !ok do continue
		root, perr := json.parse_string(string(data), .JSON5, false, context.temp_allocator)
		if perr != nil do continue
		obj, _ := root.(json.Object)
		fonts_add_declared(obj["fonts"], path_dir(path))
		lib_vars, _ := obj["variables"].(json.Object)
		names := make(map[string]bool, len(lib_vars), context.temp_allocator)
		for name in lib_vars do names[name] = true
		for name, def in lib_vars do vars[fmt.tprintf("%s:%s", alias, name)] = lib_prefix(def, alias, names)
		children, _ := obj["children"].(json.Array)
		for item in children {
			uid, nerr := node_from_json(doc, lib_prefix(item, alias, names), 0)
			if nerr != "" do continue
			mark_imported(doc, uid)
		}
		lib.ok = true
	}
	if len(vars) > 0 {
		b := strings.builder_make(context.temp_allocator)
		write_json_value(&b, vars)
		doc.lib_vars = strings.clone(strings.to_string(b))
	}
	doc_resolve_vars(doc)
	for &n in doc.nodes do node_refresh(doc, &n)
	doc.version += 1
	return libs[:]
}

mark_imported :: proc(doc: ^Document, uid: int) {
	if n, _ := doc_find_uid(doc, uid); n != nil do n.imported = true
	for c in children_of(doc, uid) do mark_imported(doc, c)
}

// A library value renamed under its alias: ids, refs and descendant keys get "alias:",
// references to the library's own variables become "$alias:name".
lib_prefix :: proc(v: json.Value, alias: string, names: map[string]bool) -> json.Value {
	#partial switch x in v {
	case json.Object:
		out := make(json.Object, len(x), context.temp_allocator)
		for k, val in x {
			switch k {
			case "id", "ref":
				if s, ok := val.(json.String); ok {
					out[k] = json.String(fmt.tprintf("%s:%s", alias, s))
					continue
				}
			case "descendants":
				if d, ok := val.(json.Object); ok {
					m := make(json.Object, len(d), context.temp_allocator)
					for path, ov in d {
						parts := strings.split(path, "/", context.temp_allocator)
						for &p in parts do p = fmt.tprintf("%s:%s", alias, p)
						m[strings.join(parts, "/", context.temp_allocator)] = lib_prefix(ov, alias, names)
					}
					out[k] = m
					continue
				}
			}
			out[k] = lib_prefix(val, alias, names)
		}
		return out
	case json.Array:
		out := make(json.Array, len(x), context.temp_allocator)
		for item, i in x do out[i] = lib_prefix(item, alias, names)
		return out
	case json.String:
		if strings.has_prefix(string(x), "$") && string(x)[1:] in names do return json.String(fmt.tprintf("$%s:%s", alias, string(x)[1:]))
	}
	return v
}

// The alias a library file gets: its name without .lib.pen / .pen, made unique.
library_alias :: proc(doc: ^Document, path: string) -> string {
	base := path_base(path)
	base = strings.trim_suffix(strings.trim_suffix(base, ".pen"), ".lib")
	b := strings.builder_make(context.temp_allocator)
	for r in strings.to_lower(base, context.temp_allocator) {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '-' || r == '_' do strings.write_rune(&b, r)
	}
	alias := strings.to_string(b)
	if alias == "" do alias = "lib"
	imports := doc_imports(doc)
	name := alias
	for i := 2; (name in imports); i += 1 do name = fmt.tprintf("%s%d", alias, i)
	return name
}

// The library's theme axes and values join the document's, in the same undo step: its
// variables are themed on them, and a frame can only pin a value the document declares
// (pen.dev reads the axes from the document's own header).
library_merge_axes :: proc(doc: ^Document, path: string) {
	data, read := read_file(path, context.temp_allocator)
	if !read do return
	root, perr := json.parse_string(string(data), .JSON5, false, context.temp_allocator)
	if perr != nil do return
	obj, _ := root.(json.Object)
	themes, ok := obj["themes"].(json.Object)
	if !ok || len(themes) == 0 do return
	_ = doc_theme_axes(doc)
	names := make([dynamic]string, context.temp_allocator)
	for k in themes do append(&names, k)
	slice.sort(names[:])
	changed := false
	for name in names {
		values, _ := themes[name].(json.Array)
		idx := -1
		for a, i in doc.theme_axes do if a.name == name do idx = i
		if idx < 0 {
			append(&doc.theme_axes, Theme_Axis{name = strings.clone(name)})
			idx = len(doc.theme_axes) - 1
		}
		for v in values {
			val := string(v.(json.String) or_else "")
			if val == "" || slice.contains(doc.theme_axes[idx].values[:], val) do continue
			append(&doc.theme_axes[idx].values, strings.clone(val))
			changed = true
		}
	}
	if !changed do return
	doc_theme_axes_write(doc)
	theme_defaults(doc)
	doc_retheme(doc)
}

// Sets (or, with nil, removes) a top-level property of the document.
doc_set_header :: proc(doc: ^Document, key: string, v: json.Value) {
	for i := 0; i < len(doc.header); i += 1 {
		if doc.header[i].key != key do continue
		delete(doc.header[i].key)
		delete(doc.header[i].raw)
		ordered_remove(&doc.header, i)
		break
	}
	if v == nil do return
	b := strings.builder_make(context.temp_allocator)
	write_json_value(&b, v)
	append(&doc.header, Prop{strings.clone(key), strings.clone(strings.to_string(b))})
}

// "ui" from "ui:btn".
library_of :: proc(n: ^Node) -> string {
	if !n.imported do return ""
	if i := strings.index_byte(n.id, ':'); i > 0 do return n.id[:i]
	return ""
}

// Reads the open document's libraries again when one of their files changed on disk
// (saved from another tab or window, or by an agent), within a couple of seconds. Not an
// edit of this document: no undo step, nothing to save. The stamp of each document is
// kept, so a tab that was in the background reloads when it is shown.
lib_stamps: map[string]string // document path -> its libraries' paths and modification times
lib_checked: time.Tick
