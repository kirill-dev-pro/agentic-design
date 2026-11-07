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
	cloud:       bool, // the Cloud view (dashboard_cloud.odin)
	search:      string,
	scroll:      f32,
	selected:    string, // path of the selected card
	click_path:  string, // for double clicks
	click_time:  time.Time,
	menu_path:   string, // the card the context menu is for
	trash_path:  string, // the file the confirmation is for
	content_h:   f32,
	drawn_frame: int, // the last frame the dashboard was drawn in
	renaming:    string, // the card whose name is being edited
	cloud_path:  string, // the file being copied to the cloud
}

DASH_CARD_MENU := [?]string{"Open", "Reveal in Finder", "Duplicate", "Copy to cloud", "Rename", "-", "Remove from list", "Hide this folder", "-", "Move to Trash…"}

// The Dashboard opens on Recents (Kirill 2026-11-06).
@(init)
dash_init :: proc "contextless" () {
	dash.recents = true
}

DASH_SORT_NAMES := [4]string{"Last modified", "Last opened", "Name", "Created"} // in Dash_Sort's order

@(private = "file")
set_string :: proc(s: ^string, v: string) {
	if s^ == v do return
	delete(s^)
	s^ = strings.clone(v)
}

draw_dashboard :: proc(vg: ^nvg.Context) {
	// coming back to the dashboard (it was not drawn last frame) looks again soon
	files_refresh(shown = dash.drawn_frame != frames_drawn - 1)
	dash.drawn_frame = frames_drawn
	files_poll()
	fill_rect(vg, {0, TAB_H, app.screen.x, app.screen.y - TAB_H}, PANEL_BG)

	// one header (app-ui.pen, "Dashboard · All files"): All files | Recents, search and sort
	// on the left; New file, Connect agents, Settings and the account on the right
	M :: f32(32)
	ty := TAB_H + 18
	seg := Rect{M, ty, 0, 30}
	names := [3]string{"All files", "Recents", "Cloud"}
	widths: [3]f32
	for name, i in names do widths[i] = text_width(vg, name, 12) + 40
	seg.w = widths[0] + widths[1] + widths[2] + 6
	fill_rect(vg, seg, FIELD_BG, 8)
	sx := seg.x + 3
	for name, i in names {
		t := Rect{sx, seg.y + 3, widths[i], seg.h - 6}
		active := dash.cloud if i == 2 else !dash.cloud && dash.recents == (i == 1)
		if active do fill_rect(vg, t, ACTIVE_BG, 6)
		else if hovered(t) do fill_rect(vg, t, HOVER_BG, 6)
		color := TEXT_FG if active else TEXT_DIM
		switch i {
		case 0: draw_icon(vg, .Grid, t.x + 15, t.y + t.h / 2, color, 13)
		case 1: draw_icon(vg, .Clock, t.x + 15, t.y + t.h / 2, color, 13)
		case 2: draw_lucide(vg, "cloud", t.x + 15, t.y + t.h / 2, 13, color, 1.6)
		}
		label(vg, t.x + 28, t.y + t.h / 2, name, color, 12)
		if clicked(t) && !active {
			dash.cloud = i == 2
			if i < 2 do dash.recents = i == 1
			dash.scroll = 0
		}
		sx += widths[i]
	}
	x := seg.x + seg.w + 12
	field(vg, 0, "dash.search", "", {x, ty + 1, 240, 28}, dash.search, placeholder = "Find files", icon = .Search)
	if field_is_focused(0, "dash.search") {
		if strings.to_string(ui.buf) != dash.search do dash.scroll = 0
		set_string(&dash.search, strings.to_string(ui.buf))
	}
	x += 252
	if !dash.recents && !dash.cloud {
		if pick, ok := dropdown_menu(vg, "dash.sort", {x, ty + 1, 150, 28}, DASH_SORT_NAMES[:], int(settings.dash_sort)); ok && Dash_Sort(pick) != settings.dash_sort {
			settings.dash_sort = Dash_Sort(pick)
			settings_save()
			dash.scroll = 0
		}
	}
	rx := app.screen.x - M
	// the account: its initial when signed in to the cloud
	av := Rect{rx - 28, ty + 1, 28, 28}
	if cloud_signed_in() {
		who := cloud_text(&cloud.name)
		if who == "" do who = cloud_text(&cloud.email)
		fill_rect(vg, av, {0.47, 0.36, 0.95, 1}, 14)
		initial := strings.to_upper(who[:1] if len(who) > 0 else "?", context.temp_allocator)
		label(vg, av.x + 14, av.y + 14, initial, TEXT_FG, 12, true, .CENTER)
		if hovered(av) do tooltip_request(who, av)
	} else {
		fill_rect(vg, av, FIELD_BG, 14)
		draw_icon(vg, .User, av.x + 14, av.y + 14, TEXT_DIM, 14)
		if hovered(av) do tooltip_request("Not signed in", av)
	}
	if clicked(av) do settings_open = true
	gear := Rect{av.x - 8 - 28, ty + 1, 28, 28}
	if icon_button(vg, gear, .Gear, tip = "Settings  ⌘,") do settings_open = true
	newf := Rect{gear.x - 12 - 92, ty + 1, 92, 28}
	if button(vg, newf, "New file", primary = true) do new_document()
	conn := Rect{newf.x - 8 - 124, ty + 1, 124, 28}
	if button(vg, conn, "Connect agents") do onboarding_start(1)
	x0 := M
	ty += 4

	if dash.cloud {
		draw_dashboard_cloud(vg, {0, ty + 40, app.screen.x, app.screen.y - ty - 40 - 36}, x0, dash.search)
		return
	}

	// what the list is made of, at the bottom left
	status: string
	switch {
	case files_root() == "": status = "Test window: no files indexed"
	case files.running: status = "Looking for .pen files…"
	case: status = fmt.tprintf("%d files on this Mac", len(files.items))
	}
	label(vg, M, app.screen.y - 18, status, TEXT_DIM, 11)
	if n := len(settings.dash_hidden); n > 0 {
		t := fmt.tprintf("Show %d hidden item%s again", n, "" if n == 1 else "s")
		r := Rect{M + text_width(vg, status, 11) + 12, app.screen.y - 30, text_width(vg, t, 11) + 16, 24}
		if hovered(r) do fill_rect(vg, r, HOVER_BG, 6)
		label(vg, r.x + 8, r.y + 12, t, TEXT_DIM, 11)
		if clicked(r) do files_unhide_all()
	}

	// the list
	items := files_list(dash.recents)
	if needle := strings.to_lower(strings.trim_space(dash.search), context.temp_allocator); needle != "" {
		kept := make([dynamic]File_Item, 0, len(items), context.temp_allocator)
		for it in items do if strings.contains(strings.to_lower(fs_base(it.path), context.temp_allocator), needle) do append(&kept, it)
		items = kept[:]
	}
	area := Rect{0, ty + 40, app.screen.x, app.screen.y - ty - 40 - 36}
	gap: f32 = 24
	ch: f32 = 236
	cols := max(int((app.screen.x - 2 * x0 + gap) / (280 + gap)), 1)
	cw := (app.screen.x - 2 * x0 - gap * f32(cols - 1)) / f32(cols)
	rows_n := (len(items) + cols - 1) / cols
	dash.content_h = f32(rows_n) * (ch + gap) + 24 + agent_input_reserve() // the agent input floats below
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
			menu_open("dash.card", {app.mouse.x, app.mouse.y, 0, 0}, DASH_CARD_MENU[:])
		}
	}
	ui.clip = saved_clip
	nvg.Restore(vg)
	dash.scroll = scrollbar(vg, "dash", area, dash.content_h, dash.scroll)
	if len(items) == 0 {
		msg := "No files yet. Create one with + New file."
		if dash.search != "" do msg = "No file names match."
		else if dash.recents do msg = "The files you open show here. All files lists every .pen on this Mac."
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
		switch DASH_CARD_MENU[pick] {
		case "Open": dash_open(p)
		case "Reveal in Finder": reveal_in_finder(p)
		case "Duplicate": dash_duplicate(p)
		case "Copy to cloud": dash_copy_to_cloud(p)
		case "Rename":
			set_string(&dash.renaming, p)
			field_focus(0, "dash.rename", engine.file_title(p))
		case "Remove from list":
			files_hide(p)
			set_status("“%s” is off the list; the file stays where it is", fs_base(p))
		case "Hide this folder":
			files_hide(fs_dir(p))
			set_status("Files in %s are off the list", short_dir(fs_dir(p)))
		case "Move to Trash…": dash_confirm_trash(p)
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
	renaming := dash.renaming == e.path && field_is_focused(0, "dash.rename")
	if renaming do field(vg, 0, "dash.rename", "", {card.x + 8, card.y + 6, card.w - 16, 28}, engine.file_title(e.path))
	else if dash.renaming == e.path do set_string(&dash.renaming, "")
	nvg.Save(vg)
	nvg.IntersectScissor(vg, card.x + 14, card.y, card.w - 28, 56)
	if !renaming do label(vg, card.x + 14, card.y + 20, engine.file_title(e.path), TEXT_FG, 13)
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
	if working, color := agent_working_on(e.path); working do agent_card_glow(vg, card, color, agent_working_name(e.path))
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

// A copy beside the file: "<name> copy.pen" (numbered when that exists).
dash_duplicate :: proc(path: string) {
	dir, title := fs_dir(path), engine.file_title(path)
	dst := fmt.tprintf("%s/%s copy.pen", dir, title)
	for k := 2; fs_exists(dst); k += 1 do dst = fmt.tprintf("%s/%s copy %d.pen", dir, title, k)
	if err := fs_copy(dst, path); err != nil {
		set_status("Could not duplicate: %v", err)
		return
	}
	files_refresh(true)
	set_string(&dash.selected, dst)
	set_status("Duplicated as %s", fs_base(dst))
}

// Copy to cloud (decision 87, cloud-docs plan: a local file stays local; the cloud gets an
// unlinked copy, private to the signed-in account).
dash_copy_to_cloud :: proc(path: string) {
	if !cloud_signed_in() {
		settings_section = .Account
		settings_scroll = 0
		settings_open = true
		set_status("Sign in to copy files to the cloud")
		return
	}
	if cloud.running {
		set_status("Another upload is running; try again in a moment")
		return
	}
	if !cloud_share_as(path, engine.file_title(path), .Private, false, false) {
		set_status("The upload could not start")
		return
	}
	set_string(&dash.cloud_path, path)
	set_status("Copying “%s” to the cloud…", engine.file_title(path))
}

// Every frame: the end of a Copy to cloud.
dash_cloud_tick :: proc() {
	if dash.cloud_path == "" || cloud.running do return
	if cloud_phase() == .Failed do set_status("Copy to cloud failed: %s", cloud_text(&cloud.error))
	else do set_status("“%s” is in your cloud files (only you can see it)", engine.file_title(dash.cloud_path))
	set_string(&dash.cloud_path, "")
}

// The card name typed in place (Rename): the file is renamed on disk.
dash_field_apply :: proc(key, text: string) -> bool {
	if key != "dash.rename" do return false
	p := dash.renaming
	if p == "" do return true
	title := strings.trim_space(text)
	if strings.has_suffix(title, ".pen") do title = title[:len(title) - 4]
	if title == "" || strings.contains(title, "/") || title == engine.file_title(p) do return true
	for t in app.tabs do if t.path == p || app.file_path == p {
		set_status("“%s” is open: rename it from its tab (double click)", engine.file_title(p))
		return true
	}
	dst := fmt.tprintf("%s/%s.pen", fs_dir(p), title)
	if fs_exists(dst) {
		set_status("%s already exists", fs_base(dst))
		return true
	}
	if err := fs_rename(p, dst); err != nil {
		set_status("Rename failed: %v", err)
		return true
	}
	recents_rename(p, dst)
	files_refresh(true)
	set_string(&dash.selected, dst)
	set_string(&dash.renaming, "")
	return true
}
