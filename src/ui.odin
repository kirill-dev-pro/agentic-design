package agentic_design

import "engine"

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "vendor:glfw"
import nvg "nanovg"

// Immediate-mode interface drawn with NanoVG: tab bar, sidebar (pages + layers),
// tool strip and inspector. Styled after Paper's dark theme.

SWATCHES := [?]string{"#FFFFFF", "#D9D9D9", "#1E1E1E", "#F24822", "#FFA629", "#FFCD29", "#14AE5C", "#0D99FF", "#9747FF", "#FF24BD"}

ROW_H :: f32(30)

draw_ui :: proc() {
	vg := app.vg
	widgets_begin_frame()
	if app.tab < 0 {
		draw_dashboard(vg)
	} else {
		draw_sidebar(vg)
		draw_tools(vg)
		draw_inspector(vg)
	}
	draw_tab_bar(vg)
	draw_component_drag_ghost(vg)
	components_drag_update()
	draw_variables_table(vg)
	draw_settings_sheet(vg)
	draw_shortcuts_sheet(vg)
	draw_onboarding(vg)
	draw_status(vg)
	widgets_end_frame(vg)
}

// ---------------------------------------------------------------- primitives

// ---------------------------------------------------------------- icons

kind_icon :: proc(n: ^engine.Node) -> Icon {
	switch n.kind {
	case .Frame:
		switch n.layout {
		case .Horizontal: return .Row
		case .Vertical: return .Column
		case .None: return .Frame
		}
		return .Frame
	case .Group: return .Group
	case .Rectangle: return .Rect
	case .Ellipse: return .Ellipse
	case .Path, .Icon: return .Path
	case .Text: return .Text
	case .Ref: return .Component
	case .Other: return .Other
	}
	return .Other
}

// ---------------------------------------------------------------- tab bar

draw_tab_bar :: proc(vg: ^nvg.Context) {
	fill_rect(vg, {0, 0, app.screen.x, TAB_H}, TAB_BG)
	fill_rect(vg, {0, TAB_H - 1, app.screen.x, 1}, PANEL_LINE)

	x: f32 = 12
	// dashboard
	dw := text_width(vg, "Dashboard", 13) + 44
	home := Rect{x, 7, dw, TAB_H - 14}
	active := app.tab < 0
	if active do fill_rect(vg, home, ACTIVE_BG, 7)
	else if in_rect(home, app.mouse) do fill_rect(vg, home, HOVER_BG, 7)
	draw_icon(vg, .Grid, home.x + 18, TAB_H / 2, TEXT_FG if active else TEXT_DIM, 15)
	label(vg, home.x + 34, TAB_H / 2, "Dashboard", TEXT_FG if active else TEXT_DIM, 13)
	if clicked(home) do tab_activate(-1)
	x += dw + 8
	fill_rect(vg, {x, 14, 1, TAB_H - 28}, PANEL_LINE)
	x += 9

	// one tab per open file
	close_me := -1
	for i in 0 ..< len(app.tabs) {
		name := tab_title(i)
		if tab_dirty(i) do name = fmt.tprintf("%s •", name)
		tw := text_width(vg, name, 13) + 64
		tab := Rect{x, 7, tw, TAB_H - 14}
		active = i == app.tab
		hover := in_rect(tab, app.mouse)
		if active do fill_rect(vg, tab, ACTIVE_BG, 7)
		else if hover do fill_rect(vg, tab, HOVER_BG, 7)
		draw_icon(vg, .File, tab.x + 18, TAB_H / 2, TEXT_FG if active else TEXT_DIM, 15)
		label(vg, tab.x + 34, TAB_H / 2, name, TEXT_FG if active else TEXT_DIM, 13)
		cross := Rect{tab.x + tab.w - 26, tab.y + 4, 22, 22}
		if active || hover {
			if icon_button(vg, cross, .X) do close_me = i
		}
		if clicked(tab) && !in_rect(cross, app.mouse) do tab_activate(i)
		x += tw + 6
	}
	if close_me >= 0 do close_tab(close_me)
	if icon_button(vg, {x + 2, 8, 28, 28}, .Plus) do new_document()
}

draw_sidebar :: proc(vg: ^nvg.Context) {
	panel := Rect{0, TAB_H, LEFT_W, app.screen.y - TAB_H}
	fill_rect(vg, panel, PANEL_BG)
	fill_rect(vg, {LEFT_W - 1, TAB_H, 1, panel.h}, PANEL_LINE)

	// file header; double click renames the file
	y := TAB_H + 22
	draw_icon(vg, .File, 24, y, TEXT_FG, 15)
	if ui.focus == "filename" && ui.focus_uid == 0 {
		field(vg, 0, "filename", "", {36, y - 12, LEFT_W - 52, 24}, engine.file_title(app.file_path))
	} else {
		label(vg, 40, y, engine.file_title(app.file_path), TEXT_FG, 13)
		hdr := Rect{16, y - 14, LEFT_W - 32, 28}
		if clicked(hdr) {
			double := ui.tree_click_uid == -2 && time.duration_seconds(time.since(ui.tree_click)) < 0.35
			ui.tree_click, ui.tree_click_uid = time.now(), -2
			if double do field_focus(0, "filename", engine.file_title(app.file_path))
		}
	}

	// Design | Components | Theme
	seg := Rect{16, TAB_H + 44, LEFT_W - 32, 28}
	fill_rect(vg, seg, FIELD_BG, 7)
	tab_names := [3]string{"Design", "Components", "Theme"}
	tw := (seg.w - 4) / 3
	for name, i in tab_names {
		t := Rect{seg.x + 2 + f32(i) * tw, seg.y + 2, tw, seg.h - 4}
		if ui.side_tab == i do fill_rect(vg, t, ACTIVE_BG, 6)
		label(vg, t.x + t.w / 2, t.y + t.h / 2, name, TEXT_FG if ui.side_tab == i else TEXT_DIM, 12, false, .CENTER)
		if clicked(t) do ui.side_tab = i
	}
	ui.theme_tab = ui.side_tab == 2

	top := TAB_H + 88
	app.layers_scroll = max(app.layers_scroll - wheel_over({0, top, LEFT_W, panel.h - (top - TAB_H)}), 0)
	nvg.Save(vg)
	nvg.Scissor(vg, 0, top, LEFT_W, app.screen.y - top)
	y = top + 8 - app.layers_scroll
	if ui.side_tab == 2 do draw_variables(vg, &y)
	else if ui.side_tab == 1 do draw_components_panel(vg, &y)
	else {
		draw_pages(vg, &y)
		fill_rect(vg, {16, y, LEFT_W - 32, 1}, PANEL_LINE)
		y += 8
		draw_layers(vg, &y)
	}
	nvg.Restore(vg)
	ui.side_h = y + app.layers_scroll - top + 16
	side := Rect{0, top, LEFT_W, app.screen.y - top}
	if ui.side_h > side.h do app.layers_scroll = scrollbar(vg, "sidebar", side, ui.side_h, app.layers_scroll)
	else do app.layers_scroll = 0
}

// Pages of the document: switch, add, rename (double click) and delete (right click).
draw_pages :: proc(vg: ^nvg.Context, y: ^f32) {
	hdr := Rect{8, y^, LEFT_W - 16, ROW_H}
	draw_icon(vg, .Chevron_Right if ui.pages_shut else .Chevron_Down, hdr.x + 12, hdr.y + ROW_H / 2, TEXT_DIM, 12)
	label(vg, hdr.x + 24, hdr.y + ROW_H / 2, "Pages", TEXT_FG, 13)
	add := Rect{LEFT_W - 40, hdr.y + 1, 28, 28}
	if icon_button(vg, add, .Plus, tip = "New page") do page_add()
	else if clicked(hdr) do ui.pages_shut = !ui.pages_shut
	y^ += ROW_H
	if ui.pages_shut do return
	pages := engine.doc_pages(&app.doc)
	for page, i in pages {
		r := Rect{8, y^, LEFT_W - 16, ROW_H}
		current := i == app.page
		key := fmt.tprintf("page.name:%d", i)
		renaming := ui.focus == key && ui.focus_uid == 0
		if hovered(r) && !renaming do fill_rect(vg, r, HOVER_BG, 6)
		draw_icon(vg, .File, r.x + 32, r.y + ROW_H / 2, TEXT_DIM, 14)
		if renaming {
			field(vg, 0, key, "", {r.x + 44, r.y + 3, r.w - 76, 24}, page.name)
		} else {
			label(vg, r.x + 48, r.y + ROW_H / 2, page.name, TEXT_FG, 12)
		}
		if current do draw_icon(vg, .Check, r.x + r.w - 16, r.y + ROW_H / 2, TEXT_FG, 13)
		if !renaming && clicked(r) {
			double := ui.tree_click_uid == -10 - i && time.duration_seconds(time.since(ui.tree_click)) < 0.35
			ui.tree_click, ui.tree_click_uid = time.now(), -10 - i
			if double do field_focus(0, key, page.name)
			else if !current do page_switch(i)
		}
		if mouse_pressed(glfw.MOUSE_BUTTON_RIGHT) && hovered(r) {
			page_menu_index = i
			menu_open("page", {app.mouse.x, app.mouse.y, 0, 0}, {"Rename", "Duplicate", "-", "Delete…"})
		}
		y^ += ROW_H
	}
	y^ += 6
	page_menu_apply()
}

page_menu_index: int

page_menu_apply :: proc() {
	if pick, ok := menu_take("page"); ok {
		i := page_menu_index
		pages := engine.doc_pages(&app.doc)
		if i < 0 || i >= len(pages) do return
		switch pick {
		case 0: field_focus(0, fmt.tprintf("page.name:%d", i), pages[i].name)
		case 1:
			// duplicate: copy every top-level layer of the page onto a new one
			push_undo()
			append(&app.doc.pages, engine.Page{name = fmt.aprintf("%s copy", pages[i].name)})
			engine.doc_pages_write(&app.doc)
			ni := len(app.doc.pages) - 1
			tops := make([dynamic]int, context.temp_allocator)
			for &n in app.doc.nodes do if n.parent == 0 && engine.page_of_top(&app.doc, n.id) == i do append(&tops, n.uid)
			for uid in tops {
				if nuid := duplicate_tree(uid, -1, 0); nuid != 0 {
					if c, _ := engine.doc_find_uid(&app.doc, nuid); c != nil {
						c.page_seen = true
						append(&app.doc.pages[ni].ids, strings.clone(c.id))
					}
				}
			}
			engine.doc_pages_write(&app.doc)
			page_switch(ni)
			mark_dirty()
		case 3:
			if len(pages) == 1 do set_status("A document needs at least one page")
			else do dialog_open("delete-page", "Delete page?", fmt.tprintf("\"%s\" and every layer on it will be deleted.", pages[i].name), {"Cancel", "Delete"})
		}
	}
	if pick, ok := dialog_take("delete-page"); ok && pick == 1 do page_delete(page_menu_index)
}

draw_layers :: proc(vg: ^nvg.Context, y: ^f32) {
	// a new selection reveals itself in the tree
	first := app.sel[0] if len(app.sel) > 0 else 0
	if first != ui.last_sel {
		ui.last_sel = first
		ui.insp_scroll = 0
		if n, _ := engine.doc_find_uid(&app.doc, first); n != nil {
			for p := n.parent; p != 0; {
				ui.expanded[p] = true
				pn, _ := engine.doc_find_uid(&app.doc, p)
				if pn == nil do break
				p = pn.parent
			}
		}
	}

	Row :: struct {
		uid:       int,
		r:         Rect,
		depth:     int,
		container: bool,
	}
	rows := make([dynamic]Row, context.temp_allocator)
	row :: proc(vg: ^nvg.Context, n: ^engine.Node, depth: int, y: ^f32, rows: ^[dynamic]Row) {
		if depth > engine.MAX_DEPTH do return
		r := Rect{8, y^, LEFT_W - 16, ROW_H}
		append(rows, Row{n.uid, r, depth, n.kind == .Frame || n.kind == .Group})
		sel := is_selected(n.uid)
		if sel do fill_rect(vg, r, ACTIVE_BG, 6)
		else if in_rect(r, app.mouse) do fill_rect(vg, r, HOVER_BG, 6)
		x := r.x + 12 + f32(depth) * 16
		has_children := false
		for c in app.doc.nodes do if c.parent == n.uid {has_children = true; break}
		open := ui.expanded[n.uid]
		chev := Rect{x - 10, r.y, 20, ROW_H}
		if has_children do draw_icon(vg, .Chevron_Down if open else .Chevron_Right, x, r.y + ROW_H / 2, TEXT_DIM, 12)
		if n.kind == .Text do label(vg, x + 20, r.y + ROW_H / 2, "Aa", TEXT_DIM, 12, false, .CENTER)
		else do draw_icon(vg, kind_icon(n), x + 20, r.y + ROW_H / 2, TEXT_DIM, 14)
		renaming := ui.focus == "name" && ui.focus_uid == n.uid && ui.rename_tree
		eye := Rect{r.x + r.w - 28, r.y + 3, 24, 24}
		if renaming {
			field(vg, n.uid, "name", "", {x + 30, r.y + 3, r.w - (x + 30 - r.x) - 4, 24}, n.name, placeholder = engine.node_label(n))
		} else {
			nvg.Save(vg)
			nvg.IntersectScissor(vg, r.x, r.y, r.w - 32, r.h)
			label(vg, x + 36, r.y + ROW_H / 2, engine.node_label(n), TEXT_DIM if !n.enabled else TEXT_FG, 12)
			nvg.Restore(vg)
		}
		if (in_rect(r, app.mouse) || !n.enabled) && !renaming {
			if icon_button(vg, eye, .Eye if n.enabled else .Eye_Off) {
				push_undo()
				if n.enabled do engine.node_set_bool(&app.doc, n, "enabled", false)
				else do engine.node_unset(&app.doc, n, "enabled")
			}
		}
		if r.y + r.h > TAB_H + 88 && !renaming && !in_rect(eye, app.mouse) && clicked(r) {
			if has_children && in_rect(chev, app.mouse) {
				ui.expanded[n.uid] = !open
			} else {
				if app.editing != 0 do finish_text_editing()
				double := ui.tree_click_uid == n.uid && time.duration_seconds(time.since(ui.tree_click)) < 0.35
				ui.tree_click, ui.tree_click_uid = time.now(), n.uid
				if double {
					start_rename(n.uid, false)
				} else if mod_shift() {
					if !sel do append(&app.sel, n.uid)
				} else {
					if !sel {
						clear(&app.sel)
						append(&app.sel, n.uid)
					}
					ui.layer_drag = {uid = n.uid, start = app.mouse}
				}
			}
		}
		if mouse_pressed(glfw.MOUSE_BUTTON_RIGHT) && in_rect(r, app.mouse) && r.y + r.h > TAB_H + 88 {
			if !sel {
				clear(&app.sel)
				append(&app.sel, n.uid)
			}
			context_menu_open(app.mouse)
		}
		y^ += ROW_H
		if !open do return
		uid := n.uid
		for i := len(app.doc.nodes) - 1; i >= 0; i -= 1 {
			if app.doc.nodes[i].parent == uid do row(vg, &app.doc.nodes[i], depth + 1, y, rows)
		}
	}
	// find layers (⌘F): a flat list of matches on this page instead of the tree
	field(vg, 0, "layers.search", "", {16, y^, LEFT_W - 32, 28}, ui.layer_search, placeholder = "Find layers  ⌘F", icon = .Search)
	if field_is_focused(0, "layers.search") {
		delete(ui.layer_search)
		ui.layer_search = strings.clone(strings.to_string(ui.buf))
	}
	y^ += 36
	if needle := strings.to_lower(strings.trim_space(ui.layer_search), context.temp_allocator); needle != "" {
		draw_layer_matches(vg, needle, y)
		return
	}
	for i := len(app.doc.nodes) - 1; i >= 0; i -= 1 {
		if app.doc.nodes[i].parent == 0 && !app.page_hidden[app.doc.nodes[i].uid] do row(vg, &app.doc.nodes[i], 0, y, &rows)
	}
	layers_drag(vg, rows[:])
	if len(app.doc.nodes) == 0 {
		label(vg, 24, y^ + ROW_H / 2, "Empty page — press F to draw a frame", TEXT_DIM)
		y^ += ROW_H
	}
}

// Layers on the current page whose name, text or type contains `needle`, with the frame
// they are in. Click selects, double click also zooms to the layer.
draw_layer_matches :: proc(vg: ^nvg.Context, needle: string, y: ^f32) {
	count := 0
	for &n in app.doc.nodes {
		if !on_page(n.uid) do continue
		hay := strings.to_lower(fmt.tprintf("%s\x00%s\x00%s", engine.node_label(&n), n.content, n.type_name), context.temp_allocator)
		if !strings.contains(hay, needle) do continue
		count += 1
		r := Rect{8, y^, LEFT_W - 16, ROW_H}
		sel := is_selected(n.uid)
		if sel do fill_rect(vg, r, ACTIVE_BG, 6)
		else if in_rect(r, app.mouse) do fill_rect(vg, r, HOVER_BG, 6)
		if n.kind == .Text do label(vg, r.x + 20, r.y + ROW_H / 2, "Aa", TEXT_DIM, 12, false, .CENTER)
		else do draw_icon(vg, kind_icon(&n), r.x + 20, r.y + ROW_H / 2, TEXT_DIM, 14)
		nvg.Save(vg)
		nvg.IntersectScissor(vg, r.x, r.y, r.w - 8, r.h)
		name := engine.node_label(&n)
		label(vg, r.x + 36, r.y + ROW_H / 2, name, TEXT_FG, 12)
		if p, _ := engine.doc_find_uid(&app.doc, n.parent); p != nil {
			label(vg, r.x + 44 + text_width(vg, name, 12), r.y + ROW_H / 2, engine.node_label(p), TEXT_DIM, 11)
		}
		nvg.Restore(vg)
		if r.y + r.h > TAB_H + 88 && clicked(r) {
			double := ui.tree_click_uid == n.uid && time.duration_seconds(time.since(ui.tree_click)) < 0.35
			ui.tree_click, ui.tree_click_uid = time.now(), n.uid
			if mod_shift() {
				if !sel do append(&app.sel, n.uid)
			} else {
				clear(&app.sel)
				append(&app.sel, n.uid)
			}
			if double do if b, ok := bounds_of({n.uid}); ok do zoom_to_rect(b)
		}
		y^ += ROW_H
		if count >= 200 do break
	}
	if count == 0 {
		label(vg, 24, y^ + ROW_H / 2, "No layers match", TEXT_DIM, 12)
		y^ += ROW_H
	}
}

draw_variables :: proc(vg: ^nvg.Context, y: ^f32) {
	if button(vg, {16, y^, LEFT_W - 32, 28}, "Open variables table") do variables_table_open()
	y^ += 36
	draw_theme_axes(vg, y)
	label(vg, 20, y^ + ROW_H / 2, "Variables", TEXT_FG, 13)
	if icon_button(vg, {LEFT_W - 40, y^ + 1, 28, 28}, .Plus, tip = "Add variable") {
		menu_open("newvar", {LEFT_W - 40, y^ + 1, 28, 28}, {"Color", "Number", "String"})
	}
	if pick, ok := menu_take("newvar"); ok {
		push_undo()
		kinds := [?]string{"color", "number", "string"}
		defaults := [?]string{"#4C8DFF", "8", "value"}
		base := [?]string{"color.new", "number.new", "string.new"}
		name := base[pick]
		for i := 2; i < 100; i += 1 {
			if _, taken := app.doc.vars[name]; !taken do break
			name = fmt.tprintf("%s%d", base[pick], i)
		}
		engine.doc_set_variable_themed(&app.doc, name, kinds[pick], defaults[pick])
		mark_dirty()
	}
	y^ += ROW_H
	if len(app.doc.vars) == 0 {
		label(vg, 20, y^ + ROW_H / 2, "No variables yet — add one with +", TEXT_DIM)
		y^ += ROW_H
		return
	}
	names := make([dynamic]string, 0, len(app.doc.vars), context.temp_allocator)
	for name in app.doc.vars do append(&names, name)
	slice.sort(names[:])
	remove := ""
	for name in names {
		v := app.doc.vars[name]
		r := Rect{8, y^, LEFT_W - 16, ROW_H}
		hover := in_rect(r, app.mouse)
		if hover do fill_rect(vg, r, HOVER_BG, 6)
		value: string
		kind := "string"
		switch v.kind {
		case .Color:
			fill_rect(vg, {r.x + 10, r.y + 8, 14, 14}, engine.to_nvg(v.color), 3)
			stroke_rect(vg, {r.x + 10, r.y + 8, 14, 14}, {1, 1, 1, 0.12}, 3)
			value = engine.color_hex(v.color)[1:]
			kind = "color"
		case .Number:
			value = engine.num_text(v.number)
			kind = "number"
			draw_icon(vg, .Font_Size, r.x + 17, r.y + 15, TEXT_DIM, 12)
		case .String:
			value = v.str
		case .Bool:
			value = "true" if v.b else "false"
			kind = "boolean"
		}
		name_key := fmt.tprintf("var.name:%s", name)
		value_key := fmt.tprintf("var.value:%s:%s", kind, name)
		name_r := Rect{r.x + 30, r.y + 3, r.w * 0.55 - 30, 24}
		value_r := Rect{r.x + r.w * 0.55 + 2, r.y + 3, r.w * 0.45 - 30, 24}
		field(vg, 0, name_key, "", name_r, name, true)
		field(vg, 0, value_key, "", value_r, value, true)
		if hover && icon_button(vg, {r.x + r.w - 26, r.y + 3, 24, 24}, .Minus) do remove = name
		y^ += ROW_H
	}
	if remove != "" {
		push_undo()
		engine.doc_remove_variable(&app.doc, remove)
		mark_dirty()
	}
	y^ += 6
}

// Theme axes: a dropdown per axis with the shown value, "+" adds a value or an axis.
draw_theme_axes :: proc(vg: ^nvg.Context, y: ^f32) {
	axes := engine.doc_theme_axes(&app.doc)
	label(vg, 20, y^ + ROW_H / 2, "Theme", TEXT_FG, 13)
	if icon_button(vg, {LEFT_W - 40, y^ + 1, 28, 28}, .Plus, tip = "Add theme value") {
		items := make([dynamic]string, context.temp_allocator)
		for a in axes do append(&items, fmt.tprintf("New value for %s", a.name))
		if len(axes) == 0 do append(&items, "New axis \"mode\"")
		menu_open("newtheme", {LEFT_W - 40, y^ + 1, 28, 28}, items[:])
	}
	if pick, ok := menu_take("newtheme"); ok {
		push_undo()
		if len(axes) == 0 {
			engine.theme_add_value(&app.doc, "mode", "light")
			engine.theme_add_value(&app.doc, "mode", "dark")
		} else if pick < len(axes) {
			a := axes[pick]
			name := fmt.tprintf("%s%d", a.name, len(a.values) + 1)
			engine.theme_add_value(&app.doc, a.name, name)
			field_focus(0, fmt.tprintf("theme.value:%s", a.name), name)
		}
		mark_dirty()
	}
	y^ += ROW_H
	if len(axes) == 0 {
		label(vg, 20, y^ + ROW_H / 2, "No themes — add light and dark with +", TEXT_DIM)
		y^ += ROW_H + 6
		return
	}
	for a in axes {
		r := Rect{8, y^, LEFT_W - 16, ROW_H}
		label(vg, r.x + 12, r.y + ROW_H / 2, a.name, TEXT_DIM, 12)
		key := fmt.tprintf("theme.value:%s", a.name)
		dd := Rect{r.x + r.w * 0.4, r.y + 2, r.w * 0.6 - 4, 26}
		if ui.focus == key && ui.focus_uid == 0 {
			field(vg, 0, key, "", dd, engine.theme[a.name])
		} else {
			cur := -1
			for v, i in a.values do if v == engine.theme[a.name] do cur = i
			if pick, ok := dropdown_menu(vg, fmt.tprintf("theme:%s", a.name), dd, a.values[:], cur); ok {
				delete(engine.theme[a.name])
				engine.theme[strings.clone(a.name)] = strings.clone(a.values[pick])
				engine.doc_retheme(&app.doc)
			}
			if mouse_pressed(glfw.MOUSE_BUTTON_RIGHT) && hovered(dd) {
				page_menu_index = -1
				theme_menu_axis = a.name
				menu_open("theme-axis", {app.mouse.x, app.mouse.y, 0, 0}, {"Rename value"})
			}
		}
		y^ += ROW_H
	}
	if pick, ok := menu_take("theme-axis"); ok && pick == 0 {
		field_focus(0, fmt.tprintf("theme.value:%s", theme_menu_axis), engine.theme[theme_menu_axis])
	}
	y^ += 6
	fill_rect(vg, {16, y^, LEFT_W - 32, 1}, PANEL_LINE)
	y^ += 10
}

theme_menu_axis: string

// ---------------------------------------------------------------- tool strip

draw_tools :: proc(vg: ^nvg.Context) {
	fill_rect(vg, {LEFT_W, TAB_H, TOOLS_W, app.screen.y - TAB_H}, PANEL_BG)
	fill_rect(vg, {LEFT_W + TOOLS_W - 1, TAB_H, 1, app.screen.y - TAB_H}, PANEL_LINE)
	Tool_Button :: struct {
		tool: Tool,
		icon: Icon,
		tip:  string,
	}
	tools := [?]Tool_Button{{.Select, .Select, "Move  V"}, {.Hand, .Hand, "Hand  H"}, {.Frame, .Frame, "Frame  F"}, {.Rect, .Rect, "Rectangle  R"}, {.Ellipse, .Ellipse, "Ellipse  E"}, {.Text, .Text, "Text  T"}, {.Pen, .Pen, "Pen  P"}}
	y := TAB_H + 8
	for t in tools {
		if icon_button(vg, {LEFT_W + 6, y, 32, 32}, t.icon, app.tool == t.tool, t.tip) {
			if pen_active() do pen_finish()
			app.tool = t.tool
			if app.editing != 0 do finish_text_editing()
		}
		y += 38
	}
	if icon_button(vg, {LEFT_W + 6, y, 32, 32}, .Image, tip = "Place image") do place_image_dialog()
	y += 38
	fill_rect(vg, {LEFT_W + 12, y + 2, TOOLS_W - 24, 1}, PANEL_LINE)
	y += 10
	if icon_button(vg, {LEFT_W + 6, y, 32, 32}, .Grid, ui.show_grid, "Dot grid") do ui.show_grid = !ui.show_grid
}

// ---------------------------------------------------------------- inspector

draw_inspector :: proc(vg: ^nvg.Context) {
	px := app.screen.x - RIGHT_W
	panel := Rect{px, TAB_H, RIGHT_W, app.screen.y - TAB_H}
	fill_rect(vg, panel, PANEL_BG)
	fill_rect(vg, {px, TAB_H, 1, panel.h}, PANEL_LINE)
	x := px + 16
	right := px + RIGHT_W - 16
	y := TAB_H + 12

	// zoom · export
	zoom_text := fmt.tprintf("%d%%", int(app.zoom * 100 + 0.5))
	zoom := Rect{x, y + 2, 84, 24}
	if in_rect(zoom, app.mouse) do fill_rect(vg, zoom, HOVER_BG, 6)
	label(vg, zoom.x + 8, zoom.y + 12, zoom_text, TEXT_FG, 12)
	draw_icon(vg, .Chevron_Down, zoom.x + zoom.w - 10, zoom.y + 12, TEXT_DIM, 11)
	if clicked(zoom) do menu_open("zoom", zoom, {"Zoom to fit", "Zoom to selection", "50%", "100%", "200%", "400%"})
	if pick, ok := menu_take("zoom"); ok {
		c := [2]f32{app.canvas.x + app.canvas.w / 2, app.canvas.y + app.canvas.h / 2}
		switch pick {
		case 0:
			if r, rok := bounds_of(all_uids(true)); rok do zoom_to_rect(r)
		case 1:
			if r, rok := bounds_of(app.sel[:]); rok do zoom_to_rect(r)
		case 2: zoom_at(c, 0.5 / app.zoom)
		case 3: zoom_at(c, 1 / app.zoom)
		case 4: zoom_at(c, 2 / app.zoom)
		case 5: zoom_at(c, 4 / app.zoom)
		}
	}
	export := Rect{right - 76, y + 2, 76, 24}
	if button(vg, export, "Export ▾") do menu_open("export", export, {"PNG\tShift Cmd E", "HTML + CSS", "React + Tailwind"})
	if pick, ok := menu_take("export"); ok {
		switch pick {
		case 0: export_request()
		case 1, 2:
			if dir, wok := export_code_to_dir(.HTML if pick == 1 else .React); wok do set_status("Exported to %s", dir)
			else do set_status("Export failed")
		}
	}
	y += 46

	// the rest scrolls
	area := Rect{px, y, RIGHT_W, app.screen.y - y}
	ui.insp_scroll = clamp(ui.insp_scroll - wheel_over(area), 0, max(ui.insp_h - area.h + 16, 0))
	nvg.Save(vg)
	nvg.Scissor(vg, area.x, area.y, area.w, area.h)
	ui.clip = area
	top := y
	y -= ui.insp_scroll
	draw_inspector_content(vg, x, right, &y)
	ui.insp_h = y + ui.insp_scroll - top
	ui.clip = {}
	nvg.Restore(vg)
	if ui.insp_h + 16 > area.h do ui.insp_scroll = scrollbar(vg, "inspector", area, ui.insp_h + 16, ui.insp_scroll)
}

draw_inspector_content :: proc(vg: ^nvg.Context, x, right: f32, y: ^f32) {
	if len(app.sel) == 0 {
		draw_page_section(vg, x, right, y)
		return
	}
	if len(app.sel) > 1 {
		section(vg, x, y, fmt.tprintf("%d layers", len(app.sel)))
		ops := [?]Align_Op{.Left, .Center_H, .Right, .Top, .Center_V, .Bottom, .Distribute_H, .Distribute_V}
		icons := [?]Icon{.Align_Left, .Align_Center, .Align_Right, .Align_Top, .Align_Middle, .Align_Bottom, .Distribute_H, .Distribute_V}
		w := right - x
		bw := (w - 7 * 4) / 8
		for op, i in ops {
			if icon_button(vg, {x + f32(i) * (bw + 4), y^, bw, 28}, icons[i]) do align_selection(op)
		}
		y^ += 40
		half := (w - 8) / 2
		if button(vg, {x, y^, half, 28}, "Group") do wrap_selection(.Group)
		if button(vg, {x + half + 8, y^, half, 28}, "Auto layout") do wrap_selection(.Auto_Layout)
		y^ += 36
		divider(vg, x, w, y)
		draw_selection_colors(vg, x, w, y)
		if button(vg, {x, y^, half, 28}, "Duplicate") do duplicate_selection()
		if button(vg, {x + half + 8, y^, half, 28}, "Delete") {
			push_undo()
			for uid in app.sel do engine.doc_delete(&app.doc, uid)
			clear(&app.sel)
		}
		y^ += 36
		return
	}

	n, _ := engine.doc_find_uid(&app.doc, app.sel[0])
	if n == nil do return
	if ui.focus != "" && ui.focus_uid != n.uid do field_commit()
	draw_node_properties(vg, n, x, right, y)
}

draw_page_section :: proc(vg: ^nvg.Context, x, right: f32, y: ^f32) {
	w := right - x
	section(vg, x, y, "Page")
	// background color of the canvas
	hex := engine.color_hex(from_nvg(app.canvas_bg))[1:]
	r := Rect{x, y^, w - 56, 28}
	fill_rect(vg, {r.x + 8, r.y + 7, 14, 14}, app.canvas_bg, 3)
	field(vg, 0, "canvas", "", {r.x + 26, r.y, r.w - 26, r.h}, hex, true)
	label(vg, r.x + r.w - 10, r.y + 14, "100%", TEXT_DIM, 12, false, .RIGHT)
	if icon_button(vg, {right - 50, y^, 24, 28}, .Grid, ui.show_grid) do ui.show_grid = !ui.show_grid
	if icon_button(vg, {right - 24, y^, 24, 28}, .Pencil) {
		if len(app.doc.nodes) > 0 {
			clear(&app.sel)
			append(&app.sel, app.doc.nodes[len(app.doc.nodes) - 1].uid)
		}
	}
	y^ += 44

	section(vg, x, y, "MCP")
	dot := nvg.Color{0.2, 0.8, 0.45, 1} if server_listening else nvg.Color{0.9, 0.35, 0.3, 1}
	nvg.BeginPath(vg)
	nvg.Circle(vg, x + 5, y^ + 8, 4)
	nvg.FillColor(vg, dot)
	nvg.Fill(vg)
	label(vg, x + 16, y^ + 8, fmt.tprintf("Listening on 127.0.0.1:%d", server_port()) if server_listening else "Server is off", TEXT_DIM)
	y^ += 26
	if button(vg, {x, y^, w, 30}, "Connect agents") do onboarding_start(1)
	y^ += 38
	half := (w - 8) / 2
	if button(vg, {x, y^, half, 30}, "Settings  ⌘,") do settings_open = true
	if button(vg, {x + half + 8, y^, half, 30}, "Shortcuts  ?") do shortcuts_open = true
	y^ += 46

	section(vg, x, y, "Document", fmt.tprintf("%d layers · %d variables", len(app.doc.nodes), len(app.doc.vars)))
	lines := [?]string {
		"V  H  F  R  E  T   tools",
		"Space + drag / Scroll   pan",
		"Cmd + scroll   zoom",
		"Shift 1 / Cmd 0   fit / 100%",
		"Hold Z / Option   zoom / measure",
		"Cmd D   duplicate",
		"Cmd Z / Shift Cmd Z   undo / redo",
		"Double click text   edit",
		"Shift + drag   keep proportions",
	}
	for l in lines {
		label(vg, x, y^ + 8, l, TEXT_DIM)
		y^ += 20
	}
}

draw_node_properties :: proc(vg: ^nvg.Context, n: ^engine.Node, x, right: f32, y: ^f32) {
	w := right - x
	half := (w - 8) / 2
	title := n.type_name if n.kind == .Other else engine.KIND_LABELS[n.kind]
	section(vg, x, y, title, n.id)
	field(vg, n.uid, "name", "", {x, y^, w, 28}, n.name, placeholder = engine.node_label(n))
	y^ += 40
	if n.kind == .Ref {
		draw_instance_section(vg, n, x, w, y)
	}

	if n.kind != .Ref {
		if n.reusable {
			label(vg, x, y^ + 14, "Component origin", {0.85, 0.45, 0.95, 1})
			if button(vg, {x + w - 120, y^, 120, 28}, "Make plain layer") {
				push_undo()
				engine.node_unset(&app.doc, n, "reusable")
			}
		} else if button(vg, {x, y^, w, 28}, "Create component  ⌘⌥K") {
			push_undo()
			engine.node_set_bool(&app.doc, n, "reusable", true)
		}
		y^ += 36
	}
	divider(vg, x, w, y)

	draw_alignment_row(vg, x, w, y)
	draw_position_rows(vg, n, x, w, y)
	if n.kind == .Frame do draw_flex_section(vg, n, x, w, y)
	draw_dimension_rows(vg, n, x, w, y)
	divider(vg, x, w, y)
	draw_appearance(vg, n, x, w, y)

	if n.kind == .Frame || n.kind == .Group {
		axes := engine.doc_theme_axes(&app.doc)
		if len(axes) > 0 {
			section(vg, x, y, "Theme")
			for a in axes {
				items := make([dynamic]string, context.temp_allocator)
				append(&items, "Inherit")
				for v in a.values do append(&items, v)
				cur := 0
				for t in n.theme_set do if t[0] == a.name {
					for v, i in a.values do if v == t[1] do cur = i + 1
				}
				label(vg, x, y^ + 14, a.name, TEXT_DIM, 11)
				if pick, ok := dropdown_menu(vg, fmt.tprintf("node-theme:%s", a.name), {x + half + 8, y^, half, 28}, items[:], cur); ok {
					push_undo()
					engine.node_set_theme(&app.doc, n, a.name, "" if pick == 0 else a.values[pick - 1])
					mark_dirty()
				}
				y^ += 36
			}
			divider(vg, x, w, y)
		}
	}

	draw_fills_section(vg, n, x, w, y)

	// stroke
	if n.kind != .Text {
		if section_toggle(vg, x, y, "Stroke", n.has_stroke) {
			push_undo()
			if n.has_stroke do engine.node_unset(&app.doc, n, "stroke")
			else {
				engine.node_set_stroke(&app.doc, n, {0, 0, 0, 255})
				// inside the box, like the strokes pen.dev writes: the node's bounds stay
				// its bounds
				if n.kind != .Path && n.kind != .Text && engine.prop_index(n, "strokeAlignment") < 0 do engine.node_set_string(&app.doc, n, "strokeAlignment", "inner")
			}
		}
		if n.has_stroke {
			field(vg, n.uid, "strokeWidth", "", {x, y^, half, 28}, engine.num_text(n.stroke_width), icon = .Stroke_Width, numeric = true)
			aligns := [engine.Stroke_Align]string {
				.Inner  = "Inside",
				.Center = "Center",
				.Outer  = "Outside",
			}
			if dropdown(vg, {x + half + 8, y^, half, 28}, aligns[n.stroke_align]) {
				push_undo()
				next := engine.Stroke_Align((int(n.stroke_align) + 1) % len(engine.Stroke_Align))
				if obj, ok := engine.old_stroke_object(n); ok {
					names := [engine.Stroke_Align]string{.Inner = "inside", .Center = "center", .Outer = "outside"}
					obj["align"] = json.String(names[next])
					engine.node_set(&app.doc, n, "stroke", obj)
				} else {
					names := [engine.Stroke_Align]string{.Inner = "inner", .Center = "center", .Outer = "outer"}
					engine.node_set_string(&app.doc, n, "strokeAlignment", names[next])
				}
			}
			y^ += 36
			color_row(vg, n, "stroke", x, w, y^, n.stroke)
			y^ += 36
		}
		divider(vg, x, w, y)
	}

	draw_effects_section(vg, n, x, w, y)

	if n.kind == .Text {
		section(vg, x, y, "Typography")
		engine.fonts_scan()
		fam_items := make([dynamic]string, context.temp_allocator)
		append(&fam_items, "Default (Arial)")
		append(&fam_items, ..engine.family_names[:])
		cur := 0
		for name, i in engine.family_names do if strings.equal_fold(name, n.font_family) do cur = i + 1
		shown := n.font_family if n.font_family != "" else "Default (Arial)"
		if n.font_family != "" && cur == 0 do shown = fmt.tprintf("%s (missing)", n.font_family)
		if dropdown(vg, {x, y^, w - 32, 28}, shown) do menu_open("font", {x, y^, w - 32, 28}, fam_items[:], cur, searchable = true, font_preview = true)
		if lucide_button(vg, {x + w - 28, y^ + 2, 24, 24}, "file-plus", false, "Add a font file to the document: copied into fonts/ next to it and listed in its fonts, as pen.dev does (or drop a font file)") do import_font_dialog()
		if pick, ok := menu_take("font"); ok {
			push_undo()
			if pick == 0 do engine.node_unset(&app.doc, n, "fontFamily")
			else do engine.node_set_string(&app.doc, n, "fontFamily", engine.family_names[pick - 1])
		}
		y^ += 36
		field(vg, n.uid, "fontSize", "", {x, y^, half, 28}, engine.num_text(n.font_size), icon = .Font_Size, numeric = true)
		if pick, ok := dropdown_menu(vg, "weight", {x + half + 8, y^, half, 28}, engine.WEIGHT_NAMES[:], clamp((n.weight + 50) / 100 - 1, 0, 8)); ok {
			push_undo()
			if pick == 3 do engine.node_unset(&app.doc, n, "fontWeight")
			else do engine.node_set_string(&app.doc, n, "fontWeight", fmt.tprintf("%d", (pick + 1) * 100))
		}
		y^ += 36
		draw_typography_details(vg, n, x, w, y)
		divider(vg, x, w, y)
	}

	draw_context_section(vg, n, x, w, y)
	draw_export_section(vg, n, x, w, y)
	draw_selection_colors(vg, x, w, y)

	y^ += 8
	if button(vg, {x, y^, half, 28}, "Duplicate") do duplicate_selection()
	if button(vg, {x + half + 8, y^, half, 28}, "Delete") {
		push_undo()
		engine.doc_delete(&app.doc, n.uid)
		prune_selection()
	}
	y^ += 36
}

// Instance: which component, jump to it, detach, and the overrides as parameters.
draw_instance_section :: proc(vg: ^nvg.Context, n: ^engine.Node, x, w: f32, y: ^f32) {
	half := (w - 8) / 2
	comp := engine.instance_component(&app.doc, n)
	section(vg, x, y, "Component")
	if comp == nil {
		label(vg, x, y^ + 8, fmt.tprintf("\"%s\" was not found", n.ref), TEXT_DIM)
		y^ += 30
		divider(vg, x, w, y)
		return
	}
	r := Rect{x, y^, w, 28}
	fill_rect(vg, r, FIELD_BG, 6)
	draw_icon(vg, .Component, r.x + 14, r.y + 14, TEXT_DIM, 13)
	nvg.Save(vg)
	nvg.IntersectScissor(vg, r.x, r.y, r.w - 8, r.h)
	label(vg, r.x + 28, r.y + 14, engine.node_label(comp), TEXT_FG)
	nvg.Restore(vg)
	y^ += 36
	if button(vg, {x, y^, half, 28}, "Go to component") do go_to_component(n)
	if button(vg, {x + half + 8, y^, half, 28}, "Detach") do detach_instance(n.uid)
	y^ += 36

	// parameters: texts and visibility of the component's parts
	section(vg, x, y, "Parameters")
	count := 0
	walk :: proc(vg: ^nvg.Context, inst: ^engine.Node, uid: int, depth: int, x, w: f32, y: ^f32, count: ^int) {
		if depth > engine.MAX_DEPTH do return
		for cu in engine.children_of(&app.doc, uid) {
			c, _ := engine.doc_find_uid(&app.doc, cu)
			if c == nil || c.ghost do continue
			ov: engine.Override
			for o in inst.overrides do if o.id == c.id do ov = o
			name := c.name if c.name != "" else c.id
			if c.kind == .Text {
				label(vg, x, y^ + 8, name if c.name != "" else c.id, TEXT_DIM, 11)
				y^ += 18
				shown := ov.content if ov.has_content else c.content
				field(vg, inst.uid, fmt.tprintf("ov.content:%s", c.id), "", {x, y^, w, 28}, shown, placeholder = c.content)
				y^ += 34
				count^ += 1
			} else if depth == 0 || c.kind == .Ref {
				on := ov.enabled if ov.set_enabled else c.enabled
				if checkbox(vg, {x, y^, w, 22}, name, on) {
					push_undo()
					if on do engine.override_set(&app.doc, inst, c.id, "enabled", json.Boolean(false))
					else do engine.override_set(&app.doc, inst, c.id, "enabled", nil)
					mark_dirty()
				}
				y^ += 26
				count^ += 1
			}
			if c.kind == .Frame || c.kind == .Group do walk(vg, inst, cu, depth + 1, x, w, y, count)
			if c.kind == .Ref {
				// parts of a nested instance can be overridden too (path "a/b" matches by its last id)
				if nested := engine.instance_component(&app.doc, c); nested != nil do walk(vg, inst, nested.uid, depth + 1, x, w, y, count)
			}
		}
	}
	walk(vg, n, comp.uid, 0, x, w, y, &count)
	if count == 0 {
		label(vg, x, y^ + 8, "This component has no texts or parts to override", TEXT_DIM)
		y^ += 30
	}
	y^ += 6
	divider(vg, x, w, y)
}

// Flex: alignment grid, direction, gap, padding, absolute/clip.
draw_flex_section :: proc(vg: ^nvg.Context, n: ^engine.Node, x, w: f32, y: ^f32) {
	section(vg, x, y, "Layout")
	grid := Rect{x, y^, 120, 96}
	fill_rect(vg, grid, FIELD_BG, 8)
	flex := n.layout != .None
	for row in 0 ..< 3 {
		for col in 0 ..< 3 {
			cx := grid.x + grid.w / 6 + f32(col) * grid.w / 3
			cy := grid.y + grid.h / 6 + f32(row) * grid.h / 3
			// main axis runs along the layout direction; cross axis across it
			main, cross := col, row
			if n.layout == .Vertical do main, cross = row, col
			active := flex && int(n.justify) == main && int(n.align) == cross
			cell := Rect{cx - 18, cy - 14, 36, 28}
			hover := flex && in_rect(cell, app.mouse)
			if active {
				draw_icon(vg, .Column if n.layout == .Vertical else .Row, cx, cy, TEXT_FG, 14)
			} else {
				nvg.BeginPath(vg)
				nvg.Circle(vg, cx, cy, 2.5 if hover else 1.5)
				nvg.FillColor(vg, TEXT_FG if hover else nvg.Color{1, 1, 1, 0.25})
				nvg.Fill(vg)
			}
			if flex && clicked(cell) && !active {
				push_undo()
				justify := [?]string{"start", "center", "end"}
				align := [?]string{"start", "center", "end"}
				if main == 0 do engine.node_unset(&app.doc, n, "justifyContent")
				else do engine.node_set_string(&app.doc, n, "justifyContent", justify[main])
				if cross == 0 do engine.node_unset(&app.doc, n, "alignItems")
				else do engine.node_set_string(&app.doc, n, "alignItems", align[cross])
			}
		}
	}
	cx := x + 132
	cw := w - 132
	// direction: none · column · row
	seg := Rect{cx, y^, cw, 28}
	fill_rect(vg, seg, FIELD_BG, 6)
	Dir_Button :: struct {
		dir:  engine.Layout_Dir,
		icon: Icon,
	}
	dirs := [?]Dir_Button{{.None, .X}, {.Vertical, .Arrow_Down}, {.Horizontal, .Arrow_Right}}
	third := (seg.w - 4) / 3
	for d, i in dirs {
		r := Rect{seg.x + 2 + f32(i) * third, seg.y + 2, third, seg.h - 4}
		if icon_button(vg, r, d.icon, n.layout == d.dir) && n.layout != d.dir {
			push_undo()
			engine.node_set_string(&app.doc, n, "layout", KIND_LAYOUT_NAMES[d.dir])
		}
	}
	field(vg, n.uid, "gap", "", {cx, y^ + 34, cw, 28}, engine.num_text(n.gap), icon = .Gap, numeric = true)
	justify := n.justify
	if dropdown(vg, {cx, y^ + 68, cw, 28}, "Space between" if justify == .Space_Between else ("Space around" if justify == .Space_Around else "Packed")) {
		push_undo()
		switch justify {
		case .Start, .Center, .End: engine.node_set_string(&app.doc, n, "justifyContent", "space_between")
		case .Space_Between: engine.node_set_string(&app.doc, n, "justifyContent", "space_around")
		case .Space_Around: engine.node_unset(&app.doc, n, "justifyContent")
		}
	}
	y^ += 104

	// padding: vertical / horizontal, or all four sides
	half := (w - 8) / 2
	if ui.pad_all {
		q := (w - 24) / 4
		names := [?]string{"padding.t", "padding.r", "padding.b", "padding.l"}
		labels := [?]string{"T", "R", "B", "L"}
		for key, i in names do field(vg, n.uid, key, labels[i], {x + f32(i) * (q + 8), y^, q, 28}, engine.num_text(n.padding[i]), numeric = true)
	} else {
		field(vg, n.uid, "padding.v", "", {x, y^, half - 16, 28}, engine.num_text(n.padding[0]), icon = .Pad_V, numeric = true)
		field(vg, n.uid, "padding.h", "", {x + half + 8 - 16, y^, half - 16, 28}, engine.num_text(n.padding[1]), icon = .Pad_H, numeric = true)
	}
	if icon_button(vg, {x + w - 24, y^ + 2, 24, 24}, .Expand, ui.pad_all) do ui.pad_all = !ui.pad_all
	y^ += 36

	divider(vg, x, w, y)
}

// Every color used by the selection, most frequent first.
draw_selection_colors :: proc(vg: ^nvg.Context, x, w: f32, y: ^f32) {
	Entry :: struct {
		label: string,
		color: engine.Color,
		count: int,
	}
	entries := make([dynamic]Entry, context.temp_allocator)
	add :: proc(entries: ^[dynamic]Entry, label: string, c: engine.Color) {
		for &e in entries do if e.label == label {e.count += 1; return}
		append(entries, Entry{label, c, 1})
	}
	visit :: proc(entries: ^[dynamic]Entry, uid: int, depth: int) {
		if depth > engine.MAX_DEPTH do return
		n, _ := engine.doc_find_uid(&app.doc, uid)
		if n == nil do return
		if n.has_fill do add(entries, color_label(n, "fill", n.fill), n.fill)
		if n.has_stroke do add(entries, color_label(n, "stroke", n.stroke), n.stroke)
		for c in app.doc.nodes do if c.parent == uid do visit(entries, c.uid, depth + 1)
	}
	for uid in app.sel do visit(&entries, uid, 0)
	if len(entries) == 0 do return
	slice.sort_by(entries[:], proc(a, b: Entry) -> bool {return a.count > b.count})
	section(vg, x, y, "Selection colors")
	for e in entries {
		r := Rect{x, y^, w, 28}
		fill_rect(vg, {r.x + 8, r.y + 7, 14, 14}, engine.to_nvg(e.color), 3)
		stroke_rect(vg, {r.x + 8, r.y + 7, 14, 14}, {1, 1, 1, 0.12}, 3)
		chip(vg, r.x + 28, r.y + 5, e.label, strings.has_prefix(e.label, "$"))
		label(vg, r.x + r.w - 10, r.y + 14, fmt.tprintf("%d", e.count), TEXT_DIM, 11, false, .RIGHT)
		y^ += 30
	}
	y^ += 6
	divider(vg, x, w, y)
}

// "$name" for variable references, "RRGGBB" otherwise.
color_label :: proc(n: ^engine.Node, key: string, c: engine.Color) -> string {
	if s := engine.prop_string(n, key); strings.has_prefix(s, "$") do return s
	if key == "stroke" {
		if obj, ok := engine.old_stroke_object(n); ok {
			if s, is_str := obj["fill"].(json.String); is_str && strings.has_prefix(string(s), "$") do return string(s)
		}
	}
	return engine.color_hex(c)[1:]
}

// Swatch + value for a color property; variables show as a chip, hex as a field.
// Swatch + value + chevron, like a dropdown: the swatch and the chevron open the
// color picker (with the document's colors); the hex text can be typed into.
color_row :: proc(vg: ^nvg.Context, n: ^engine.Node, key: string, x, w, y: f32, c: engine.Color) {
	r := Rect{x, y, w, 28}
	fill_rect(vg, r, FIELD_BG, 6)
	sw := Rect{r.x + 6, r.y + 6, 16, 16}
	fill_rect(vg, sw, engine.to_nvg(c), 4)
	stroke_rect(vg, sw, {1, 1, 1, 0.15}, 4)
	chev := Rect{r.x + r.w - 26, r.y, 26, r.h}
	picker_key := fmt.tprintf("picker:%s:%d", key, n.uid)
	open := picker_is_open(picker_key)
	if hovered(chev) || hovered(sw) || open do stroke_rect(vg, r, TEXT_DIM, 6)
	draw_icon(vg, .Chevron_Down, chev.x + 13, chev.y + 14, TEXT_FG if open else TEXT_DIM, 11)
	if clicked(sw) || clicked(chev) {
		push_undo()
		bound := color_label(n, key, c)
		if key == "shadow.color" {
			bound = ""
			if obj, _, _, ok := engine.shadow_object(n); ok do bound = string(obj["color"].(json.String) or_else "")
		}
		picker_open(picker_key, {r.x, r.y, r.w, r.h}, c, bound if strings.has_prefix(bound, "$") else "")
	}
	if picked, ref, changed := picker_take(picker_key); changed {
		value := ref if ref != "" else engine.color_hex(picked)
		switch key {
		case "fill": engine.node_set_string(&app.doc, n, "fill", value)
		case "stroke":
			if obj, old := engine.old_stroke_object(n); old {
				obj["fill"] = json.String(value)
				engine.node_set(&app.doc, n, "stroke", obj)
			} else {
				engine.node_set_string(&app.doc, n, "stroke", value)
			}
		case "shadow.color": engine.shadow_set(&app.doc, n, "color", 0, value)
		case: inspector_color_set(n, key, value)
		}
		mark_dirty()
	}
	shown := color_label(n, key, c)
	if l, ok := inspector_color_label(n, key); ok do shown = l if l != "" else engine.color_hex(c)[1:]
	if key == "shadow.color" {
		shown = engine.color_hex(c)[1:]
		if obj, _, _, ok := engine.shadow_object(n); ok {
			if v, is_str := obj["color"].(json.String); is_str && strings.has_prefix(string(v), "$") do shown = string(v)
		}
	}
	pct := fmt.tprintf("%d%%", int(f32(c[3]) / 255 * 100 + 0.5))
	pct_w := text_width(vg, pct, 11)
	if strings.has_prefix(shown, "$") {
		// the chip gets the room; the percentage shows when it fits
		chip_w := text_width(vg, shown[1:], 11) + 16
		if r.x + 28 + chip_w < chev.x - 8 - pct_w do label(vg, chev.x - 4, r.y + 14, pct, TEXT_DIM, 11, false, .RIGHT)
		nvg.Save(vg)
		nvg.IntersectScissor(vg, r.x, r.y, chev.x - r.x - 2, r.h)
		chip(vg, r.x + 28, r.y + 5, shown, true)
		nvg.Restore(vg)
	} else {
		label(vg, chev.x - 4, r.y + 14, pct, TEXT_DIM, 11, false, .RIGHT)
		field(vg, n.uid, key, "", {r.x + 26, r.y + 2, r.w - 26 - 26 - 34, r.h - 4}, shown, true)
	}
}

color_variable_names :: proc() -> []string {
	names := make([dynamic]string, context.temp_allocator)
	for name, v in app.doc.vars do if v.kind == .Color do append(&names, name)
	slice.sort(names[:])
	return names[:]
}

// ---------------------------------------------------------------- widgets

KIND_LAYOUT_NAMES := [engine.Layout_Dir]string {
	.None       = "none",
	.Horizontal = "horizontal",
	.Vertical   = "vertical",
}

size_text :: proc(spec: engine.Size_Spec, computed: f32) -> string {
	switch spec.mode {
	case .Fixed:
	case .Fit: return "fit_content"
	case .Fill: return "fill_container"
	}
	return engine.num_text(computed)
}

from_nvg :: proc(c: nvg.Color) -> engine.Color {
	return {u8(c.r * 255 + 0.5), u8(c.g * 255 + 0.5), u8(c.b * 255 + 0.5), u8(c.a * 255 + 0.5)}
}

// ---------------------------------------------------------------- status

draw_status :: proc(vg: ^nvg.Context) {
	if app.status == "" || time.duration_seconds(time.since(app.status_time)) >= 3 do return
	w := text_width(vg, app.status) + 28
	r := Rect{app.canvas.x + (app.canvas.w - w) / 2, app.screen.y - 44, w, 28}
	fill_rect(vg, r, {0.1, 0.1, 0.1, 0.95}, 8)
	stroke_rect(vg, r, PANEL_LINE, 8)
	label(vg, r.x + r.w / 2, r.y + r.h / 2, app.status, TEXT_FG, 12, false, .CENTER)
}

// ---------------------------------------------------------------- text fields

field_commit :: proc() {
	field_apply()
	ui.focus = ""
	ui.rename_canvas, ui.rename_tree = false, false
}

// Applies the focused field's text to whatever it is bound to (focus stays).
field_apply :: proc() {
	text := strings.to_string(ui.buf)
	if ui.focus_uid == 0 {
		if variables_table_apply(ui.focus, text) do return
		if settings_field_apply(ui.focus, text) do return
		if ui.focus == "vt.search" || ui.focus == "comp.search" || ui.focus == "layers.search" do return
		if ui.focus == "picker.hex" || ui.focus == "picker.alpha" {
			picker_apply_text(ui.focus, text)
			return
		}
		if strings.has_prefix(ui.focus, "page.name:") {
			if i, ok := strconv.parse_int(ui.focus[len("page.name:"):]); ok do page_rename(i, text)
			return
		}
		if strings.has_prefix(ui.focus, "var.name:") {
			push_undo()
			engine.doc_rename_variable(&app.doc, ui.focus[len("var.name:"):], strings.trim_space(text))
			mark_dirty()
			return
		}
		if strings.has_prefix(ui.focus, "var.value:") {
			rest := ui.focus[len("var.value:"):]
			colon := strings.index_byte(rest, ':')
			if colon < 0 do return
			kind, name := rest[:colon], rest[colon + 1:]
			value := strings.trim_space(text)
			if kind == "color" && !strings.has_prefix(value, "#") do value = fmt.tprintf("#%s", value)
			push_undo()
			engine.doc_set_variable_themed(&app.doc, name, kind, value)
			mark_dirty()
			return
		}
		if strings.has_prefix(ui.focus, "theme.value:") {
			axis := ui.focus[len("theme.value:"):]
			push_undo()
			engine.theme_rename_value(&app.doc, axis, engine.theme[axis], strings.trim_space(text))
			mark_dirty()
			return
		}
		if ui.focus == "filename" {
			if !rename_document(text) do set_status("Could not rename to %s", text)
			return
		}
		if ui.focus == "canvas" {
			hex := text if strings.has_prefix(text, "#") else fmt.tprintf("#%s", text)
			if c, ok := engine.parse_color(hex); ok do app.canvas_bg = engine.to_nvg(c)
			else do set_status("Not a color: %s", text)
		}
		return
	}
	n, _ := engine.doc_find_uid(&app.doc, ui.focus_uid)
	if n == nil do return
	push_undo()
	if strings.has_prefix(ui.focus, "ov.content:") {
		id := ui.focus[len("ov.content:"):]
		orig, _ := engine.doc_find(&app.doc, id)
		if orig != nil && text == orig.content do engine.override_set(&app.doc, n, id, "content", nil)
		else do engine.override_set(&app.doc, n, id, "content", json.String(text))
		return
	}
	if strings.has_prefix(ui.focus, "padding.") {
		f, ok := strconv.parse_f32(strings.trim_space(text))
		if !ok {
			set_status("invalid number")
			return
		}
		pad := n.padding
		switch ui.focus {
		case "padding.v": pad[0], pad[2] = f, f
		case "padding.h": pad[1], pad[3] = f, f
		case "padding.t": pad[0] = f
		case "padding.r": pad[1] = f
		case "padding.b": pad[2] = f
		case "padding.l": pad[3] = f
		}
		engine.node_set_padding(&app.doc, n, pad)
		return
	}
	if strings.has_prefix(ui.focus, "shadow.") {
		key := ui.focus[len("shadow."):]
		t := strings.trim_space(text)
		if key == "color" {
			hex := t if strings.has_prefix(t, "#") else fmt.tprintf("#%s", t)
			if _, ok := engine.parse_color(hex); ok do engine.shadow_set(&app.doc, n, "color", 0, hex)
			else do set_status("Not a color: %s", t)
		} else if f, ok := strconv.parse_f32(t); ok {
			engine.shadow_set(&app.doc, n, key, f)
		} else {
			set_status("invalid number")
		}
		return
	}
	if inspector_field_apply(n, ui.focus, text) do return
	// color fields accept bare hex
	if (ui.focus == "fill" || ui.focus == "stroke") && len(text) >= 6 && !strings.has_prefix(text, "#") && !strings.has_prefix(text, "$") {
		text = fmt.tprintf("#%s", text)
	}
	if err := engine.node_set_text(&app.doc, n, ui.focus, text); err != "" do set_status("%s", err)
}

// ---------------------------------------------------------------- menus

// ---------------------------------------------------------------- export

export_pending: bool

export_scale: f32 = 2
export_path: string
export_format: engine.Export_Format
copy_png_pending: bool

// Exports the selection (or everything) on the next frame: at `scale`, as `format`, into
// `path` (default ~/Downloads/<file> - <layer>.<ext>).
export_request :: proc(scale: f32 = 2, path := "", format := engine.Export_Format.PNG) {
	export_pending = true
	export_scale = scale
	export_format = format
	delete(export_path)
	export_path = strings.clone(path)
}

// ⇧⌘C: the selection as a PNG (2×) on the clipboard. Runs between frames.
copy_png_render :: proc() {
	if !copy_png_pending do return
	copy_png_pending = false
	r, ok := bounds_of(app.sel[:])
	if !ok do return
	target: ^engine.Node
	if len(app.sel) == 1 do target, _ = engine.doc_find_uid(&app.doc, app.sel[0])
	pixels, w, h, rok := render_region(r, 2, target, {1, 1, 1, 1})
	if !rok do return
	png, pok := engine.png_encode(pixels, w, h)
	if !pok do return
	clipboard_set(png, "public.png")
	set_status("Copied as PNG (%d × %d)", w, h)
}

// Writes the selection (or everything) as a PNG into ~/Downloads. Runs between frames.
export_render :: proc() {
	if !export_pending do return
	export_pending = false
	uids := app.sel[:] if len(app.sel) > 0 else all_uids(true)
	r, ok := bounds_of(uids)
	if !ok {
		set_status("Nothing to export")
		return
	}
	target: ^engine.Node
	if len(uids) == 1 do target, _ = engine.doc_find_uid(&app.doc, uids[0])
	pad: f32 = 0 if target != nil else 20
	r = {r[0] - pad, r[1] - pad, r[2] + pad * 2, r[3] + pad * 2}
	pixels, w, h, rok := render_region(r, export_scale, target, {1, 1, 1, 1})
	if !rok {
		set_status("Export failed")
		return
	}
	png, pok := engine.encode_image(pixels, w, h, export_format, export_scale)
	if !pok {
		set_status("Export failed")
		return
	}
	name := engine.file_title(app.file_path)
	if target != nil do name = fmt.tprintf("%s - %s", name, engine.node_label(target))
	path := fmt.tprintf("%s/%s.%s", downloads_dir(), name, engine.EXPORT_EXTENSIONS[export_format])
	if export_path != "" do path = export_path
	if err := os.write_entire_file(path, png); err != nil {
		set_status("Export failed: %v", err)
		return
	}
	set_status("Exported %s", os.base(path))
}

// Dragging a layer in the tree: above or below a row moves it next to that layer, the
// middle of a frame or group row moves it inside. Applied on release.
layers_drag :: proc(vg: ^nvg.Context, rows: []$T) {
	d := &ui.layer_drag
	if d.uid == 0 do return
	if !d.active {
		m := app.mouse - d.start
		if m.x * m.x + m.y * m.y > 25 do d.active = true
	}
	target, place := 0, 0 // place: -1 above, 0 inside, 1 below
	if d.active {
		for r in rows {
			if app.mouse.y < r.r.y || app.mouse.y >= r.r.y + r.r.h do continue
			f := (app.mouse.y - r.r.y) / r.r.h
			place = -1 if f < 0.3 else (1 if f > 0.7 else 0)
			if place == 0 && !r.container do place = -1 if f < 0.5 else 1
			if r.uid == d.uid || engine.is_descendant(&app.doc, r.uid, d.uid) {
				target = 0
				break
			}
			target = r.uid
			x := r.r.x + 24 + f32(r.depth) * 16
			if place == 0 do stroke_rect(vg, r.r, ACCENT, 6, 1.5)
			else {
				ly := r.r.y if place < 0 else r.r.y + r.r.h
				fill_rect(vg, {x, ly - 1, r.r.x + r.r.w - x, 2}, ACCENT)
			}
			break
		}
	}
	if mouse_down(glfw.MOUSE_BUTTON_LEFT) do return
	uid := d.uid
	active := d.active
	d^ = {}
	if !active || target == 0 do return
	layer_move(uid, target, place)
}

// Moves a layer next to (place -1 above, 1 below in the tree) or into (0) a target.
layer_move :: proc(uid, target, place: int) {
	n, _ := engine.doc_find_uid(&app.doc, uid)
	t, _ := engine.doc_find_uid(&app.doc, target)
	if n == nil || t == nil || n.ghost || t.ghost do return
	push_undo()
	parent := t.uid if place == 0 else t.parent
	if parent != n.parent do engine.doc_reparent(&app.doc, uid, parent)
	if place == 0 do return // reparenting puts it on top, the first row inside
	// the tree lists siblings top-most first: above a row = after it in z-order
	engine.doc_bump(&app.doc)
	moved := make([dynamic]engine.Node, context.temp_allocator)
	for i := 0; i < len(app.doc.nodes); {
		m := app.doc.nodes[i]
		if m.uid == uid || engine.is_descendant(&app.doc, m.uid, uid) {
			append(&moved, m)
			ordered_remove(&app.doc.nodes, i)
		} else {
			i += 1
		}
	}
	at := len(app.doc.nodes)
	for m, i in app.doc.nodes do if m.uid == target do at = i + (1 if place < 0 else 0)
	inject_at(&app.doc.nodes, at, ..moved[:])
	engine.doc_index(&app.doc)
	mark_dirty()
}
