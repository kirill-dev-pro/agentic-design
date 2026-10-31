package agentic_design

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"

// Themes. The header declares axes and their values (`"themes": {"mode": ["light",
// "dark"]}`); variables carry one value per theme (`value: [{value, theme: {mode:
// "dark"}}, ...]`); a node's `theme` property switches the theme for its subtree.
// `app.theme` is the mode shown globally; each node resolves its variables against
// the theme in effect at its place in the tree.

Theme_Axis :: struct {
	name:   string,
	values: [dynamic]string,
}

Var_Entry :: struct {
	theme: [dynamic][2]string, // axis/value constraints of this entry (empty = default)
	var:   Var,
	ref:   string, // "$other": resolved through that variable under the same theme
}

// The axes declared in the header (cached per document version).
doc_theme_axes :: proc(doc: ^Document) -> []Theme_Axis {
	if doc.axes_version == doc.version && doc.axes_valid do return doc.theme_axes[:]
	theme_axes_free(&doc.theme_axes)
	doc.axes_version = doc.version
	doc.axes_valid = true
	for p in doc.header do if p.key == "themes" {
		v, err := json.parse_string(p.raw, .JSON5, false, context.temp_allocator)
		if err != nil do break
		obj, ok := v.(json.Object)
		if !ok do break
		names := make([dynamic]string, context.temp_allocator)
		for k in obj do append(&names, k)
		slice.sort(names[:])
		for k in names {
			axis := Theme_Axis{name = strings.clone(k)}
			if arr, is_arr := obj[k].(json.Array); is_arr {
				for item in arr do append(&axis.values, strings.clone(string(item.(json.String) or_else "")))
			}
			append(&doc.theme_axes, axis)
		}
	}
	return doc.theme_axes[:]
}

theme_axes_free :: proc(axes: ^[dynamic]Theme_Axis) {
	for &a in axes {
		delete(a.name)
		for v in a.values do delete(v)
		delete(a.values)
	}
	clear(axes)
}

doc_theme_axes_write :: proc(doc: ^Document) {
	for i := 0; i < len(doc.header); {
		if doc.header[i].key == "themes" {
			delete(doc.header[i].key)
			delete(doc.header[i].raw)
			ordered_remove(&doc.header, i)
		} else {
			i += 1
		}
	}
	if len(doc.theme_axes) > 0 {
		obj := make(json.Object, context.temp_allocator)
		for a in doc.theme_axes {
			arr := make(json.Array, 0, len(a.values), context.temp_allocator)
			for v in a.values do append(&arr, json.String(v))
			obj[a.name] = arr
		}
		b := strings.builder_make(context.temp_allocator)
		write_json_value(&b, obj)
		append(&doc.header, Prop{strings.clone("themes"), strings.clone(strings.to_string(b))})
	}
	doc.version += 1
	doc.axes_version = doc.version
}

// Makes sure every axis has a chosen value in app.theme (the first one by default).
theme_defaults :: proc(doc: ^Document) {
	for a in doc_theme_axes(doc) {
		if _, has := app.theme[a.name]; !has && len(a.values) > 0 do app.theme[strings.clone(a.name)] = strings.clone(a.values[0])
	}
}

// Picks the variable entry that fits `doc.resolve_theme` best: entries whose
// constraints contradict the theme are skipped, the most specific match wins.
var_get :: proc(doc: ^Document, name: string, depth := 0) -> (Var, bool) {
	entries, has := doc.var_defs[name]
	if !has || len(entries) == 0 || depth > 8 do return {}, false
	best := -1
	best_score := -1
	for e, i in entries {
		score := 0
		fits := true
		for c in e.theme {
			if cur, set := doc.resolve_theme[c[0]]; set {
				if cur == c[1] do score += 1
				else {
					fits = false
					break
				}
			}
		}
		if fits && score > best_score do best, best_score = i, score
	}
	if best < 0 do return {}, false
	if entries[best].ref != "" do return var_get(doc, entries[best].ref, depth + 1)
	return entries[best].var, true
}

// Serialises the theme in effect for a node, for cache keys and ghost comparisons.
theme_key :: proc(theme: map[string]string) -> string {
	if len(theme) == 0 do return ""
	names := make([dynamic]string, context.temp_allocator)
	for k in theme do append(&names, k)
	slice.sort(names[:])
	b := strings.builder_make(context.temp_allocator)
	for k in names do fmt.sbprintf(&b, "%s=%s;", k, theme[k])
	return strings.clone(strings.to_string(b))
}

// The theme a node sees: the global choice, then every ancestor's `theme` from the
// root down, then its own.
theme_in_effect :: proc(doc: ^Document, n: ^Node, out: ^map[string]string) {
	clear(out)
	for k, v in app.theme do out[k] = v
	chain := make([dynamic]^Node, context.temp_allocator)
	cur := n
	for cur != nil {
		append(&chain, cur)
		if cur.parent == 0 do break
		p, _ := doc_find_uid(doc, cur.parent)
		cur = p
	}
	#reverse for a in chain {
		for t in a.theme_set do out[t[0]] = t[1]
	}
}

// Re-resolves variables and every node for the current app.theme.
doc_retheme :: proc(doc: ^Document) {
	doc_resolve_vars(doc)
	for &n in doc.nodes do node_refresh(doc, &n)
	app.needs_layout = true
}

// Adds a value to an axis (creating the axis), giving every variable with themed
// values a copy for it, and switches to it.
theme_add_value :: proc(doc: ^Document, axis, value: string) {
	axes := doc_theme_axes(doc)
	found := false
	for &a in doc.theme_axes do if a.name == axis {
		for v in a.values do if v == value do return
		append(&a.values, strings.clone(value))
		found = true
	}
	if !found {
		a := Theme_Axis{name = strings.clone(axis)}
		append(&a.values, strings.clone(value))
		append(&doc.theme_axes, a)
	}
	_ = axes
	doc_theme_axes_write(doc)
	delete(app.theme[axis])
	app.theme[strings.clone(axis)] = strings.clone(value)
	doc_retheme(doc)
}

// Renames a theme value in the header, in every variable entry and in every node's
// `theme` property.
theme_rename_value :: proc(doc: ^Document, axis, old, new: string) {
	if new == "" || old == new do return
	for &a in doc.theme_axes do if a.name == axis {
		for &v in a.values do if v == old {
			delete(v)
			v = strings.clone(new)
		}
	}
	doc_theme_axes_write(doc)
	vars := doc_variables(doc)
	for name, def in vars {
		d, is_obj := def.(json.Object)
		if !is_obj do continue
		arr, is_arr := d["value"].(json.Array)
		if !is_arr do continue
		for &item in arr {
			entry, eok := item.(json.Object)
			if !eok do continue
			if th, tok := entry["theme"].(json.Object); tok {
				if string(th[axis].(json.String) or_else "") == old do th[axis] = json.String(new)
				entry["theme"] = th
			}
			item = entry
		}
		d["value"] = arr
		vars[name] = d
	}
	doc_write_variables(doc, vars)
	for &n in doc.nodes {
		if v, ok := prop_value(&n, "theme"); ok {
			if th, tok := v.(json.Object); tok && string(th[axis].(json.String) or_else "") == old {
				th[axis] = json.String(new)
				node_set(doc, &n, "theme", th)
			}
		}
	}
	if cur, has := app.theme[axis]; has && cur == old {
		delete(app.theme[axis])
		app.theme[axis] = strings.clone(new)
	}
	doc_retheme(doc)
}

// Sets a node's theme override for one axis ("" = inherit).
node_set_theme :: proc(doc: ^Document, n: ^Node, axis, value: string) {
	th: json.Object
	if v, ok := prop_value(n, "theme"); ok {
		if obj, is_obj := v.(json.Object); is_obj do th = obj
	}
	if th == nil do th = make(json.Object, context.temp_allocator)
	if value == "" do delete_key(&th, axis)
	else do th[axis] = json.String(value)
	if len(th) == 0 do node_unset(doc, n, "theme")
	else do node_set(doc, n, "theme", th)
	// descendants inherit it
	for &c in doc.nodes do if is_descendant(doc, c.uid, n.uid) do node_refresh(doc, &c)
}

// Value of a variable for the theme shown now; edits go to the matching themed
// entry (added if missing) so other themes keep theirs.
doc_set_variable_themed :: proc(doc: ^Document, name, kind, value: string) {
	vars := doc_variables(doc)
	def, has := vars[name].(json.Object)
	if !has do def = make(json.Object, context.temp_allocator)
	def["type"] = json.String(kind)
	lit := variable_literal(kind, value)
	axes := doc_theme_axes(doc)
	is_default := true
	for a in axes {
		if cur, set := app.theme[a.name]; set && len(a.values) > 0 && cur != a.values[0] do is_default = false
	}
	arr, is_arr := def["value"].(json.Array)
	if !is_arr {
		if is_default {
			def["value"] = lit
			vars[name] = def
			doc_write_variables(doc, vars)
			return
		}
		arr = make(json.Array, 0, 2, context.temp_allocator)
		if old, had := def["value"]; had {
			first := make(json.Object, context.temp_allocator)
			first["value"] = old
			append(&arr, first)
		}
	}
	// the entry whose theme equals the current choice on every axis
	target := -1
	for item, i in arr {
		entry, eok := item.(json.Object)
		if !eok do continue
		th, tok := entry["theme"].(json.Object)
		if is_default {
			if !tok || len(th) == 0 {
				target = i
				break
			}
			continue
		}
		if !tok do continue
		match := true
		for a in axes {
			cur := app.theme[a.name]
			if string(th[a.name].(json.String) or_else a.values[0]) != cur do match = false
		}
		if match {
			target = i
			break
		}
	}
	if target >= 0 {
		entry := arr[target].(json.Object)
		entry["value"] = lit
		arr[target] = entry
	} else {
		entry := make(json.Object, context.temp_allocator)
		entry["value"] = lit
		if !is_default {
			th := make(json.Object, context.temp_allocator)
			for a in axes do th[a.name] = json.String(app.theme[a.name])
			entry["theme"] = th
		}
		append(&arr, entry)
	}
	def["value"] = arr
	vars[name] = def
	doc_write_variables(doc, vars)
}
