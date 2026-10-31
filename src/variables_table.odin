package agentic_design

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import "vendor:glfw"
import nvg "nanovg"

// The variables table, like pen.dev's variables panel: one row per variable, one column
// per value of a theme axis (light | dark), every cell editable. A cell takes a literal
// (#hex, a number, text) or an alias ("$other"). Rows are filtered by a search field;
// "+ Add variable" adds one of each type.

Variables_Table :: struct {
	open:   bool,
	axis:   int,
	search: string,
	scroll: f32,
}

vtable: Variables_Table

variables_table_open :: proc() {
	vtable.open = true
	vtable.scroll = 0
}

// The raw value of a variable for one value of an axis (other axes at their defaults):
// the entry that names exactly that value, or the default entry.
var_cell :: proc(name, axis, value: string, is_default: bool) -> (raw: json.Value, resolved: Var, ok: bool) {
	vars := doc_variables(&app.doc)
	def, has := vars[name].(json.Object)
	if !has do return
	v := def["value"]
	if arr, is_arr := v.(json.Array); is_arr {
		fallback: json.Value
		for item in arr {
			e, eok := item.(json.Object)
			if !eok do continue
			th, tok := e["theme"].(json.Object)
			if !tok || len(th) == 0 {
				fallback = e["value"]
				continue
			}
			if len(th) == 1 && string(th[axis].(json.String) or_else "") == value do raw = e["value"]
		}
		if raw == nil do raw = fallback
	} else {
		raw = v
	}
	// what it resolves to under that theme
	saved := make(map[string]string, context.temp_allocator)
	for k, s in app.doc.resolve_theme do saved[k] = s
	clear(&app.doc.resolve_theme)
	for a in doc_theme_axes(&app.doc) do if len(a.values) > 0 do app.doc.resolve_theme[a.name] = a.values[0]
	if axis != "" do app.doc.resolve_theme[axis] = value
	resolved, ok = var_get(&app.doc, name)
	clear(&app.doc.resolve_theme)
	for k, s in saved do app.doc.resolve_theme[k] = s
	return
}

// Sets a variable's value for one value of an axis (the default value writes the
// untagged entry); other themed values stay as they are.
var_set_for :: proc(name, kind, text, axis, value: string, is_default: bool) {
	vars := doc_variables(&app.doc)
	def, has := vars[name].(json.Object)
	if !has do return
	lit := variable_literal(kind, text)
	if strings.has_prefix(text, "$") do lit = json.String(text)
	arr, is_arr := def["value"].(json.Array)
	if !is_arr {
		if is_default || axis == "" {
			def["value"] = lit
			vars[name] = def
			doc_write_variables(&app.doc, vars)
			return
		}
		arr = make(json.Array, 0, 2, context.temp_allocator)
		first := make(json.Object, context.temp_allocator)
		first["value"] = def["value"]
		append(&arr, first)
	}
	target := -1
	for item, i in arr {
		e, eok := item.(json.Object)
		if !eok do continue
		th, tok := e["theme"].(json.Object)
		if is_default {
			if !tok || len(th) == 0 do target = i
		} else if tok && len(th) == 1 && string(th[axis].(json.String) or_else "") == value {
			target = i
		}
	}
	if target >= 0 {
		e := arr[target].(json.Object)
		e["value"] = lit
		arr[target] = e
	} else {
		e := make(json.Object, context.temp_allocator)
		e["value"] = lit
		if !is_default {
			th := make(json.Object, context.temp_allocator)
			th[axis] = json.String(value)
			e["theme"] = th
		}
		append(&arr, e)
	}
	def["value"] = arr
	vars[name] = def
	doc_write_variables(&app.doc, vars)
}

draw_variables_table :: proc(vg: ^nvg.Context) {
	if !vtable.open do return
	saved_pass := ui.overlay_pass
	ui.overlay_pass = true
	defer ui.overlay_pass = saved_pass

	fill_rect(vg, {0, 0, app.screen.x, app.screen.y}, {0, 0, 0, 0.55})
	w := min(app.screen.x - 96, 1080)
	h := min(app.screen.y - 96, 760)
	sheet := Rect{(app.screen.x - w) / 2, (app.screen.y - h) / 2, w, h}
	popup_shadow(vg, sheet, 14)
	fill_rect(vg, sheet, {0.13, 0.13, 0.14, 1}, 14)
	stroke_rect(vg, sheet, {1, 1, 1, 0.08}, 14)
	saved_clip := ui.clip
	ui.clip = sheet
	defer ui.clip = saved_clip

	ob_text(vg, sheet.x + 24, sheet.y + 30, "Variables", 18, TEXT_FG, 600)
	close := Rect{sheet.x + sheet.w - 44, sheet.y + 14, 30, 30}
	if lucide_button(vg, close, "x") || (key_pressed(glfw.KEY_ESCAPE) && ui.focus == "") {
		vtable.open = false
		return
	}

	// axis tabs, search, add
	axes := doc_theme_axes(&app.doc)
	if vtable.axis >= len(axes) do vtable.axis = 0
	tx := sheet.x + 24
	ty := sheet.y + 58
	for a, i in axes {
		tw := text_width(vg, a.name, 12) + 24
		r := Rect{tx, ty, tw, 28}
		if i == vtable.axis do fill_rect(vg, r, ACTIVE_BG, 6)
		label(vg, r.x + 12, r.y + 14, a.name, TEXT_FG if i == vtable.axis else TEXT_DIM, 12)
		if clicked(r) do vtable.axis = i
		tx += tw + 4
	}
	if lucide_button(vg, {tx + 2, ty + 2, 24, 24}, "plus", false, "Add a theme axis") {
		push_undo()
		theme_add_value(&app.doc, fmt.tprintf("axis%d", len(axes) + 1), "default")
		mark_dirty()
	}
	sr := Rect{sheet.x + sheet.w - 24 - 220 - 8 - 140, ty, 220, 28}
	field(vg, 0, "vt.search", "", sr, vtable.search, placeholder = "Search variables")
	if field_is_focused(0, "vt.search") {
		delete(vtable.search)
		vtable.search = strings.clone(strings.to_string(ui.buf))
	}
	add := Rect{sheet.x + sheet.w - 24 - 140, ty, 140, 28}
	if button(vg, add, "+ Add variable") do menu_open("vt.add", add, {"Color", "Number", "String", "Boolean"})
	if pick, ok := menu_take("vt.add"); ok {
		push_undo()
		kinds := [4]string{"color", "number", "string", "boolean"}
		defaults := [4]string{"#4C8DFF", "8", "value", "true"}
		base := [4]string{"color.new", "number.new", "string.new", "boolean.new"}
		name := base[pick]
		for i := 2; i < 100; i += 1 {
			if _, taken := doc_variables(&app.doc)[name]; !taken do break
			name = fmt.tprintf("%s%d", base[pick], i)
		}
		doc_set_variable(&app.doc, name, kinds[pick], defaults[pick])
		mark_dirty()
	}

	// columns
	axis_name := ""
	values: []string = {""}
	if len(axes) > 0 {
		axis_name = axes[vtable.axis].name
		values = axes[vtable.axis].values[:]
	}
	table := Rect{sheet.x + 24, ty + 44, sheet.w - 48, sheet.h - (ty + 44 - sheet.y) - 20}
	name_w := min(table.w * 0.34, 320)
	col_w := (table.w - name_w - 32) / f32(max(len(values), 1))
	label(vg, table.x + 30, table.y + 12, "Name", TEXT_DIM, 11)
	for v, i in values {
		cx := table.x + name_w + f32(i) * col_w
		label(vg, cx + 8, table.y + 12, v if v != "" else "Value", TEXT_DIM, 11)
		if axis_name != "" && i > 0 {
			hr := Rect{cx, table.y, col_w, 24}
			if hovered(hr) && mouse_pressed(glfw.MOUSE_BUTTON_RIGHT) do field_focus(0, fmt.tprintf("theme.value:%s", axis_name), v)
		}
	}
	if axis_name != "" {
		if lucide_button(vg, {table.x + table.w - 26, table.y, 24, 24}, "plus", false, fmt.tprintf("Add a %s value", axis_name)) {
			push_undo()
			theme_add_value(&app.doc, axis_name, fmt.tprintf("%s%d", "value", len(values) + 1))
			mark_dirty()
		}
	}
	fill_rect(vg, {table.x, table.y + 26, table.w, 1}, PANEL_LINE)

	body := Rect{table.x, table.y + 30, table.w, table.h - 30}
	vars := doc_variables(&app.doc)
	names := make([dynamic]string, 0, len(vars), context.temp_allocator)
	needle := strings.to_lower(strings.trim_space(vtable.search), context.temp_allocator)
	for name in vars do if needle == "" || strings.contains(strings.to_lower(name, context.temp_allocator), needle) do append(&names, name)
	slice.sort(names[:])
	row_h: f32 = 34
	content := f32(len(names)) * row_h
	vtable.scroll = clamp(vtable.scroll - wheel_over(body), 0, max(content - body.h, 0))
	nvg.Save(vg)
	nvg.IntersectScissor(vg, body.x, body.y, body.w, body.h)
	saved_clip2 := ui.clip
	ui.clip = body
	remove := ""
	for name, i in names {
		r := Rect{body.x, body.y + f32(i) * row_h - vtable.scroll, body.w, row_h}
		if r.y + r.h < body.y || r.y > body.y + body.h do continue
		if hovered(r) do fill_rect(vg, r, HOVER_BG, 6)
		def, _ := vars[name].(json.Object)
		kind := string(def["type"].(json.String) or_else "string")
		icon := "palette" if kind == "color" else ("hash" if kind == "number" else ("toggle-left" if kind == "boolean" else "type"))
		draw_lucide(vg, icon, r.x + 14, r.y + row_h / 2, 14, TEXT_DIM, 1.6)
		field(vg, 0, fmt.tprintf("var.name:%s", name), "", {r.x + 28, r.y + 4, name_w - 36, 26}, name, true)
		for v, k in values {
			cell := Rect{r.x + name_w + f32(k) * col_w, r.y + 4, col_w - 8, 26}
			raw, resolved, ok := var_cell(name, axis_name, v, k == 0)
			shown := ""
			#partial switch x in raw {
			case json.String: shown = string(x)
			case json.Float: shown = num_text(f32(x))
			case json.Integer: shown = fmt.tprintf("%d", x)
			case json.Boolean: shown = "true" if x else "false"
			}
			tx2 := cell.x + 6
			if ok && resolved.kind == .Color {
				sw := Rect{cell.x + 6, cell.y + 6, 14, 14}
				fill_rect(vg, sw, to_nvg(resolved.color), 3)
				stroke_rect(vg, sw, {1, 1, 1, 0.15}, 3)
				tx2 = cell.x + 24
			}
			key := fmt.tprintf("vt.cell:%s:%s:%s:%d:%s", kind, axis_name, v, k, name)
			field(vg, 0, key, "", {tx2, cell.y, cell.x + cell.w - tx2, cell.h}, shown, true)
		}
		if hovered(r) && lucide_button(vg, {r.x + r.w - 26, r.y + 5, 24, 24}, "minus", false, "Delete variable") do remove = name
	}
	ui.clip = saved_clip2
	nvg.Restore(vg)
	if len(names) == 0 do label(vg, body.x + 12, body.y + 20, "No variables" if needle == "" else "Nothing matches", TEXT_DIM)
	if content > body.h do vtable.scroll = scrollbar(vg, "vtable", body, content, vtable.scroll)
	if remove != "" {
		push_undo()
		doc_remove_variable(&app.doc, remove)
		mark_dirty()
	}
}

// Applies an edited table cell ("vt.cell:<kind>:<axis>:<value>:<column>:<name>").
variables_table_apply :: proc(key, text: string) -> bool {
	if !strings.has_prefix(key, "vt.cell:") do return false
	parts := strings.split_n(key[len("vt.cell:"):], ":", 5, context.temp_allocator)
	if len(parts) != 5 do return true
	kind, axis, value, column, name := parts[0], parts[1], parts[2], parts[3], parts[4]
	t := strings.trim_space(text)
	if kind == "color" && !strings.has_prefix(t, "#") && !strings.has_prefix(t, "$") do t = fmt.tprintf("#%s", t)
	push_undo()
	var_set_for(name, kind, t, axis, value, column == "0")
	doc_retheme(&app.doc)
	mark_dirty()
	return true
}
