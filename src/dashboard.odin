package agentic_design

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import nvg "nanovg"

// The dashboard (no active tab): recent files with thumbnails, like Paper's home.

dash_files: bool // show the files of app.files_dir instead of recents

draw_dashboard :: proc(vg: ^nvg.Context) {
	fill_rect(vg, {0, TAB_H, app.screen.x, app.screen.y - TAB_H}, PANEL_BG)
	// sidebar
	fill_rect(vg, {LEFT_W - 1, TAB_H, 1, app.screen.y - TAB_H}, PANEL_LINE)
	rows := [?]string{"Recents", "Files"}
	for name, i in rows {
		r := Rect{12, TAB_H + 16 + f32(i) * 34, LEFT_W - 24, 30}
		active := dash_files == (i == 1)
		if active do fill_rect(vg, r, ACTIVE_BG, 6)
		else if in_rect(r, app.mouse) do fill_rect(vg, r, HOVER_BG, 6)
		draw_icon(vg, .Grid if i == 0 else .File, r.x + 16, r.y + 15, TEXT_FG if active else TEXT_DIM, 14)
		label(vg, r.x + 32, r.y + 15, name, TEXT_FG if active else TEXT_DIM, 13)
		if clicked(r) do dash_files = i == 1
	}
	label(vg, 24, app.screen.y - 24, app.files_dir, TEXT_DIM, 11)

	// header
	x0 := LEFT_W + 48
	label(vg, x0, TAB_H + 48, "Files" if dash_files else "Recents", TEXT_FG, 24)
	if button(vg, {app.screen.x - 48 - 96, TAB_H + 34, 96, 28}, "+ New file") do new_document()
	if button(vg, {app.screen.x - 48 - 96 - 8 - 132, TAB_H + 34, 132, 28}, "Connect agents") do onboarding_start(1)
	if button(vg, {app.screen.x - 48 - 96 - 8 - 132 - 8 - 96, TAB_H + 34, 96, 28}, "Settings") do settings_open = true

	// cards
	entries := dashboard_entries()
	cw, ch, gap: f32 = 300, 236, 24
	cols := max(int((app.screen.x - x0 - 48 + gap) / (cw + gap)), 1)
	y0 := TAB_H + 88
	for e, i in entries {
		col, row := i % cols, i / cols
		card := Rect{x0 + f32(col) * (cw + gap), y0 + f32(row) * (ch + gap), cw, ch}
		hover := in_rect(card, app.mouse)
		fill_rect(vg, card, {0.145, 0.145, 0.145, 1}, 10)
		stroke_rect(vg, card, {1, 1, 1, 0.12 if hover else 0.06}, 10)
		label(vg, card.x + 14, card.y + 20, e.title, TEXT_FG, 13)
		label(vg, card.x + 14, card.y + 40, e.subtitle, TEXT_DIM, 11)
		thumb := Rect{card.x + 10, card.y + 56, card.w - 20, card.h - 66}
		fill_rect(vg, thumb, {0.2, 0.2, 0.2, 1}, 6)
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
			label(vg, thumb.x + thumb.w / 2, thumb.y + thumb.h / 2, "No preview yet", TEXT_DIM, 12, false, .CENTER)
		}
		if clicked(card) {
			if !open_in_tab(e.path) {
				set_status("Could not open %s", e.title)
				if !dash_files do recents_remove(e.path)
			}
		}
	}
	if len(entries) == 0 {
		label(vg, x0, y0 + 20, "No files yet. Create one with + New file.", TEXT_DIM, 13)
	}
}

Dash_Entry :: struct {
	path, title, subtitle: string,
}

dashboard_entries :: proc() -> []Dash_Entry {
	out := make([dynamic]Dash_Entry, context.temp_allocator)
	if dash_files {
		infos, err := os.read_all_directory_by_path(app.files_dir, context.temp_allocator)
		if err == nil {
			slice.sort_by(infos, proc(a, b: os.File_Info) -> bool {return a.modification_time._nsec > b.modification_time._nsec})
			for info in infos {
				if info.type == .Directory || !strings.has_suffix(info.name, ".pen") do continue
				path := fmt.tprintf("%s/%s", app.files_dir, info.name)
				append(&out, Dash_Entry{path, file_title(info.name), fmt.tprintf("Edited %s", ago(info.modification_time._nsec / 1_000_000_000))})
			}
		}
		return out[:]
	}
	for r in recents {
		if !os.exists(r.path) do continue
		append(&out, Dash_Entry{r.path, file_title(r.path), fmt.tprintf("Opened %s", ago(r.time))})
	}
	return out[:]
}

ago :: proc(unix: i64) -> string {
	d := time.now()._nsec / 1_000_000_000 - unix
	switch {
	case d < 60: return "just now"
	case d < 3600: return fmt.tprintf("%d min ago", d / 60)
	case d < 86400: return fmt.tprintf("%d h ago", d / 3600)
	case d < 86400 * 2: return "1 day ago"
	}
	return fmt.tprintf("%d days ago", d / 86400)
}
