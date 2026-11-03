#+build !js
package agentic_design

import "engine"

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import nvg "nanovg"

// The dashboard (no active tab), like Paper's home: All files (every .pen on this Mac,
// files_index.odin, sorted as the user chose) and Recents (the files opened in the app,
// last opened first). A click selects a card, a double click or Enter opens it; the
// right-click menu and the Delete key act on it. Previews are drawn in the background, one
// at a time, for the cards in view (thumb_ensure).

dash: struct {
	recents:     bool, // the Recents view instead of All files
	search:      string,
	scroll:      f32,
	selected:    string, // path of the selected card
	click_path:  string, // for double clicks
	click_time:  time.Time,
	menu_path:   string, // the card the context menu is for
	trash_path:  string, // the file the confirmation is for
	content_h:   f32,
}

DASH_SORT_NAMES := [4]string{"Last modified", "Last opened", "Name", "Created"} // in Dash_Sort's order

@(private = "file")
set_string :: proc(s: ^string, v: string) {
	if s^ == v do return
	delete(s^)
	s^ = strings.clone(v)
}

draw_dashboard :: proc(vg: ^nvg.Context) {
	files_refresh()
	files_poll()
	fill_rect(vg, {0, TAB_H, app.screen.x, app.screen.y - TAB_H}, PANEL_BG)

	// sidebar
	fill_rect(vg, {LEFT_W - 1, TAB_H, 1, app.screen.y - TAB_H}, PANEL_LINE)
	rows := [?]string{"All files", "Recents"}
	for name, i in rows {
		r := Rect{12, TAB_H + 16 + f32(i) * 34, LEFT_W - 24, 30}
		active := dash.recents == (i == 1)
		if active do fill_rect(vg, r, ACTIVE_BG, 6)
		else if hovered(r) do fill_rect(vg, r, HOVER_BG, 6)
		draw_icon(vg, .Grid if i == 0 else .File, r.x + 16, r.y + 15, TEXT_FG if active else TEXT_DIM, 14)
		label(vg, r.x + 32, r.y + 15, name, TEXT_FG if active else TEXT_DIM, 13)
		if clicked(r) && dash.recents != (i == 1) {
			dash.recents = i == 1
			dash.scroll = 0
		}
	}
	// what the list is made of
	status: string
	switch {
	case files_root() == "": status = "Test window: no files indexed"
	case files.running: status = "Looking for .pen files…"
	case: status = fmt.tprintf("%d files on this Mac", len(files.items))
	}
	label(vg, 24, app.screen.y - 24, status, TEXT_DIM, 11)
	if n := len(settings.dash_hidden); n > 0 {
		r := Rect{16, app.screen.y - 62, LEFT_W - 32, 26}
		if hovered(r) do fill_rect(vg, r, HOVER_BG, 6)
		label(vg, r.x + 8, r.y + 13, fmt.tprintf("Show %d hidden item%s again", n, "" if n == 1 else "s"), TEXT_DIM, 11)
		if clicked(r) do files_unhide_all()
	}

	// header
	x0 := LEFT_W + 48
	label(vg, x0, TAB_H + 48, "Recents" if dash.recents else "All files", TEXT_FG, 24)
	if button(vg, {app.screen.x - 48 - 96, TAB_H + 34, 96, 28}, "+ New file") do new_document()
	if button(vg, {app.screen.x - 48 - 96 - 8 - 132, TAB_H + 34, 132, 28}, "Connect agents") do onboarding_start(1)
	if button(vg, {app.screen.x - 48 - 96 - 8 - 132 - 8 - 96, TAB_H + 34, 96, 28}, "Settings") do settings_open = true
	ty := TAB_H + 80
	field(vg, 0, "dash.search", "", {x0, ty, 260, 28}, dash.search, placeholder = "Find files", icon = .Search)
	if field_is_focused(0, "dash.search") {
		if strings.to_string(ui.buf) != dash.search do dash.scroll = 0
		set_string(&dash.search, strings.to_string(ui.buf))
	}
	if !dash.recents {
		label(vg, x0 + 280, ty + 14, "Sort", TEXT_DIM, 12)
		if pick, ok := dropdown_menu(vg, "dash.sort", {x0 + 314, ty, 160, 28}, DASH_SORT_NAMES[:], int(settings.dash_sort)); ok && Dash_Sort(pick) != settings.dash_sort {
			settings.dash_sort = Dash_Sort(pick)
			settings_save()
			dash.scroll = 0
		}
	}

	// the list
	items := files_list(dash.recents)
	if needle := strings.to_lower(strings.trim_space(dash.search), context.temp_allocator); needle != "" {
		kept := make([dynamic]File_Item, 0, len(items), context.temp_allocator)
		for it in items do if strings.contains(strings.to_lower(fs_base(it.path), context.temp_allocator), needle) do append(&kept, it)
		items = kept[:]
	}
	area := Rect{LEFT_W, ty + 44, app.screen.x - LEFT_W, app.screen.y - ty - 44}
	cw, ch, gap: f32 = 300, 236, 24
	cols := max(int((app.screen.x - x0 - 48 + gap) / (cw + gap)), 1)
	rows_n := (len(items) + cols - 1) / cols
	dash.content_h = f32(rows_n) * (ch + gap) + 24
	dash.scroll = clamp(dash.scroll - wheel_over(area), 0, max(dash.content_h - area.h, 0))
	nvg.Save(vg)
	nvg.Scissor(vg, area.x, area.y, area.w, area.h)
	saved_clip := ui.clip
	ui.clip = area
	y0 := area.y + 8 - dash.scroll
	now := time.now()
	for e, i in items {
		col, row := i % cols, i / cols
		card := Rect{x0 + f32(col) * (cw + gap), y0 + f32(row) * (ch + gap), cw, ch}
		if card.y > area.y + area.h || card.y + card.h < area.y do continue
		draw_card(vg, card, e)
		if clicked(card) {
			double := dash.click_path == e.path && time.duration_seconds(time.diff(dash.click_time, now)) < 0.45
			set_string(&dash.selected, e.path)
			set_string(&dash.click_path, e.path)
			dash.click_time = now
			if double do dash_open(e.path)
		}
		if hovered(card) && mouse_pressed(MOUSE_BUTTON_RIGHT) {
			set_string(&dash.selected, e.path)
			set_string(&dash.menu_path, e.path)
			menu_open("dash.card", {app.mouse.x, app.mouse.y, 0, 0}, {"Open", "Show in Finder", "-", "Remove from list", "Hide this folder", "-", "Move to Trash…"})
		}
	}
	ui.clip = saved_clip
	nvg.Restore(vg)
	dash.scroll = scrollbar(vg, "dash", area, dash.content_h, dash.scroll)
	if len(items) == 0 {
		msg := "No files yet. Create one with + New file."
		if dash.search != "" do msg = "No file names match."
		else if files.running do msg = "Looking for .pen files…"
		label(vg, x0, area.y + 28, msg, TEXT_DIM, 13)
	}

	// the selected card, from the keyboard
	if !ui_modal() && ui.focus == "" && dash.selected != "" {
		if key_pressed(KEY_ENTER) || key_pressed(KEY_KP_ENTER) do dash_open(dash.selected)
		else if key_pressed(KEY_DELETE) || key_pressed(KEY_BACKSPACE) do dash_confirm_trash(dash.selected)
		else if key_pressed(KEY_ESCAPE) do set_string(&dash.selected, "")
	}
	if pick, ok := menu_take("dash.card"); ok && dash.menu_path != "" {
		p := dash.menu_path
		switch pick {
		case 0: dash_open(p)
		case 1: reveal_in_finder(p)
		case 3:
			files_hide(p)
			set_status("“%s” is off the list; the file stays where it is", fs_base(p))
		case 4:
			files_hide(fs_dir(p))
			set_status("Files in %s are off the list", short_dir(fs_dir(p)))
		case 6: dash_confirm_trash(p)
		}
	}
	if pick, ok := dialog_take("dash.trash"); ok && pick == 1 && dash.trash_path != "" {
		_, msg := files_trash(dash.trash_path)
		set_status("%s", msg)
		if dash.selected == dash.trash_path do set_string(&dash.selected, "")
	}
}

@(private = "file")
draw_card :: proc(vg: ^nvg.Context, card: Rect, e: File_Item) {
	hover := hovered(card)
	selected := dash.selected == e.path
	fill_rect(vg, card, {0.145, 0.145, 0.145, 1}, 10)
	if selected do stroke_rect(vg, card, ACCENT, 10, 2)
	else do stroke_rect(vg, card, {1, 1, 1, 0.12 if hover else 0.06}, 10)
	nvg.Save(vg)
	nvg.IntersectScissor(vg, card.x + 14, card.y, card.w - 28, 56)
	label(vg, card.x + 14, card.y + 20, engine.file_title(e.path), TEXT_FG, 13)
	when_text: string
	switch {
	case dash.recents || settings.dash_sort == .Opened && e.opened > 0: when_text = fmt.tprintf("Opened %s", ago(e.opened))
	case settings.dash_sort == .Created: when_text = fmt.tprintf("Created %s", ago(e.created))
	case: when_text = fmt.tprintf("Edited %s", ago(e.modified))
	}
	label(vg, card.x + 14, card.y + 40, fmt.tprintf("%s · %s", when_text, short_dir(fs_dir(e.path))), TEXT_DIM, 11)
	nvg.Restore(vg)
	thumb := Rect{card.x + 10, card.y + 56, card.w - 20, card.h - 66}
	fill_rect(vg, thumb, {0.2, 0.2, 0.2, 1}, 6)
	thumb_ensure(e.path, e.modified)
	if img := thumb_image(e.path); img > 0 {
		iw, ih := nvg.ImageSize(vg, img)
		if iw > 0 && ih > 0 {
			s := min(thumb.w / f32(iw), thumb.h / f32(ih))
			dw, dh := f32(iw) * s, f32(ih) * s
			dx, dy := thumb.x + (thumb.w - dw) / 2, thumb.y + (thumb.h - dh) / 2
			nvg.BeginPath(vg)
			nvg.RoundedRect(vg, dx, dy, dw, dh, 4)
			nvg.FillPaint(vg, nvg.ImagePattern(dx, dy, dw, dh, 0, img, 1))
			nvg.Fill(vg)
		}
	} else {
		label(vg, thumb.x + thumb.w / 2, thumb.y + thumb.h / 2, "Drawing a preview…" if thumb_pending(e.path) else ("Empty file" if e.path in thumb_empty else "No preview"), TEXT_DIM, 12, false, .CENTER)
	}
}

// "~/OpenBot/Shared" for a folder under the home folder.
short_dir :: proc(dir: string) -> string {
	home, _ := fs_home(context.temp_allocator)
	if home != "" && strings.has_prefix(dir, home) do return fmt.tprintf("~%s", dir[len(home):])
	return dir
}

dash_open :: proc(path: string) {
	if !open_in_tab(path) {
		set_status("Could not open %s", fs_base(path))
		recents_remove(path)
	}
}

dash_confirm_trash :: proc(path: string) {
	for t, i in app.tabs {
		p := app.file_path if i == app.tab else t.path
		if same_file(p, path) {
			set_status("“%s” is open in a tab. Close the tab first.", fs_base(path))
			return
		}
	}
	set_string(&dash.trash_path, path)
	dialog_open("dash.trash", "Move to Trash?", fmt.tprintf("“%s”\n%s\n\nYou can put it back from the Trash in Finder.", fs_base(path), short_dir(fs_dir(path))), {"Cancel", "Move to Trash"})
}

ago :: proc(unix: i64) -> string {
	d := time.now()._nsec / 1_000_000_000 - unix
	switch {
	case unix <= 0: return "never"
	case d < 60: return "just now"
	case d < 3600: return fmt.tprintf("%d min ago", d / 60)
	case d < 86400: return fmt.tprintf("%d h ago", d / 3600)
	case d < 86400 * 2: return "1 day ago"
	case d < 86400 * 60: return fmt.tprintf("%d days ago", d / 86400)
	}
	y, m, day := time.date(time.unix(unix, 0))
	return fmt.tprintf("%d %s %d", day, MONTH_SHORT[int(m) - 1], y)
}

MONTH_SHORT := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}

_ :: os
