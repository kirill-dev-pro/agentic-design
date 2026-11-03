#+build !js
package agentic_design

import "engine"

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import nvg "nanovg"

// "What's new": a sheet with the release notes of the versions since the one the user last
// ran. It opens once, on the first launch after an update (also when the updater relaunches
// the app), with every skipped version merged. Never on a fresh install, in test windows
// (AGENTIC_QUIET) or in windows an agent opened (AGENTIC_NO_FOCUS); a window an agent
// opened does not count as seen either, so the user gets it the next time they open the
// app. The version last shown is `lastSeenVersion` in settings.json. The app menu
// ("What's New in Agentic Design…") and Settings → Updates open it again.
//
// The notes are docs/releases/v<version>.md, compiled into the binary and parsed once:
//
//   <!-- released: 2026-11-03 -->
//   One paragraph for the GitHub release (not shown here).
//
//   ## New | ## Improved | ## Fixed
//   - Headline.
//     Optional detail, indented by two spaces.
//
// Tests: with AGENTIC_WHATS_NEW_TEST=1 and HOME set to a sandbox (never the user's home), a
// quiet window decides as a normal launch would, from the sandbox's settings.json and
// app.log, and records what it showed there. The socket's `whats_new` method reports,
// opens and closes the sheet.

RELEASE_NOTES := #load_directory("../docs/releases")
RELEASES_URL :: "https://github.com/kirill-dev-pro/agentic-design/releases"
WHATS_NEW_ICON := #load("../assets/icon/icon-112.png")

Release_Kind :: enum {
	New,
	Improved,
	Fixed,
}

RELEASE_KIND_LABELS := [Release_Kind]string {
	.New      = "New",
	.Improved = "Improved",
	.Fixed    = "Fixed",
}

RELEASE_KIND_COLORS := [Release_Kind]nvg.Color {
	.New      = {0.36, 0.80, 0.52, 1},
	.Improved = {0.29, 0.62, 1.00, 1},
	.Fixed    = {0.96, 0.66, 0.30, 1},
}

Release_Entry :: struct {
	headline, detail: string,
}

Release :: struct {
	version, date: string, // "0.1.4", "2026-11-03"
	entries:       [Release_Kind][dynamic]Release_Entry,
}

whats_new: struct {
	open:     bool,
	pending:  bool, // open once the onboarding (or another sheet) is closed
	manual:   bool, // opened from the menu or Settings: "Version Y", not "Updated from X"
	from, to: string, // versions: the notes of (from, to] are shown
	date:     string,
	entries:  [Release_Kind][dynamic]Release_Entry,
	scroll:   f32,
	rect:     Rect, // the sheet as last drawn (tests click its buttons)
	icon:     int, // NanoVG image, 0 until first drawn
	releases: [dynamic]Release, // parsed notes, newest first
}

// ---------------------------------------------------------------- the notes

// Parses the compiled-in notes once, newest version first.
release_notes :: proc() -> []Release {
	if len(whats_new.releases) > 0 do return whats_new.releases[:]
	for f in RELEASE_NOTES {
		name := f.name
		if !strings.has_prefix(name, "v") || !strings.has_suffix(name, ".md") do continue
		append(&whats_new.releases, release_parse(name[1:len(name) - 3], string(f.data)))
	}
	slice.sort_by(whats_new.releases[:], proc(a, b: Release) -> bool {return version_newer(a.version, b.version)})
	return whats_new.releases[:]
}

release_parse :: proc(version, text: string) -> Release {
	r := Release {
		version = version,
	}
	kind := -1
	entry: ^Release_Entry
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_right_space(line)
		switch {
		case strings.has_prefix(l, "<!-- released:"):
			r.date = strings.trim_space(strings.trim_suffix(strings.trim_prefix(l, "<!-- released:"), "-->"))
		case strings.has_prefix(l, "## "):
			kind = -1
			entry = nil
			name := strings.trim_space(l[3:])
			for k in Release_Kind do if strings.equal_fold(name, RELEASE_KIND_LABELS[k]) do kind = int(k)
		case kind >= 0 && strings.has_prefix(l, "- "):
			list := &r.entries[Release_Kind(kind)]
			append(list, Release_Entry{headline = md_plain(l[2:])})
			entry = &list[len(list) - 1]
		case entry != nil && strings.has_prefix(l, "  ") && strings.trim_space(l) != "":
			d := md_plain(strings.trim_space(l))
			entry.detail = d if entry.detail == "" else strings.concatenate({entry.detail, " ", d})
		case l == "":
			entry = nil
		}
	}
	return r
}

// Markdown inline marks dropped: `code`, **bold**.
@(private = "file")
md_plain :: proc(s: string) -> string {
	out, _ := strings.remove_all(s, "`")
	out, _ = strings.remove_all(out, "**")
	return out
}

// "2026-11-03" -> "November 3, 2026"
@(private = "file")
date_long :: proc(iso: string) -> string {
	MONTHS := [12]string{"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"}
	p := strings.split(iso, "-", context.temp_allocator)
	if len(p) != 3 do return iso
	m, d := version_part_int(p[1]), version_part_int(p[2])
	if m < 1 || m > 12 do return iso
	return fmt.tprintf("%s %d, %s", MONTHS[m - 1], d, p[0])
}

@(private = "file")
version_part_int :: proc(s: string) -> int {
	n := 0
	for c in s {
		if c < '0' || c > '9' do break
		n = n * 10 + int(c - '0')
	}
	return n
}

// ---------------------------------------------------------------- when it opens

// At launch, after settings_load: decides whether to show the notes and records this
// version as seen.
whats_new_launch :: proc() {
	if (pf.quiet || pf.no_focus) && !whats_new_testing() do return
	last := settings.last_seen_version
	if last == "" {
		// Versions before 0.1.4 did not write it. A first launch ever (no settings, no log)
		// shows nothing; otherwise the updater's log line says where the user came from, or
		// it was the release before this one.
		if !settings_found && !os.exists(fmt.tprintf("%s/app.log", support_dir())) {
			whats_new_mark_seen()
			return
		}
		last = previous_version_from_log()
		if last == "" do last = release_before(VERSION)
	}
	if last != "" && version_newer(VERSION, last) do whats_new_queue(last)
	if last != VERSION do whats_new_mark_seen()
}

whats_new_mark_seen :: proc() {
	delete(settings.last_seen_version)
	settings.last_seen_version = strings.clone(VERSION)
	settings_save(in_test_window = whats_new_testing())
}

// AGENTIC_WHATS_NEW_TEST=1 in a window whose HOME is not the user's home directory.
whats_new_testing :: proc() -> bool {
	return os.get_env("AGENTIC_WHATS_NEW_TEST", context.temp_allocator) != "" && home_sandboxed()
}

// HOME is set to a folder that is not the user's home directory (a test's sandbox).
home_sandboxed :: proc() -> bool {
	pw := posix.getpwuid(posix.getuid())
	home, _ := fs_home(context.temp_allocator)
	return pw != nil && home != "" && home != string(pw.pw_dir)
}

// A test window may write settings.json: AGENTIC_SETTINGS_TEST=1 with a sandboxed HOME.
settings_test_writes :: proc() -> bool {
	return os.get_env("AGENTIC_SETTINGS_TEST", context.temp_allocator) != "" && home_sandboxed()
}

// The update that brought this version: the last "update: A -> VERSION" in app.log.
@(private = "file")
previous_version_from_log :: proc() -> string {
	data, err := os.read_entire_file(fmt.tprintf("%s/app.log", support_dir()), context.temp_allocator)
	if err != nil do return ""
	found := ""
	text := string(data)
	suffix := fmt.tprintf(" -> %s, relaunching", VERSION)
	for line in strings.split_lines_iterator(&text) {
		i := strings.index(line, "update: ")
		if i < 0 || !strings.has_suffix(line, suffix) do continue
		found = line[i + len("update: "):len(line) - len(suffix)]
	}
	return strings.clone(found, context.temp_allocator)
}

// The newest released version older than v, or "".
@(private = "file")
release_before :: proc(v: string) -> string {
	for r in release_notes() do if version_newer(v, r.version) do return r.version
	return ""
}

// Shows the notes of the versions after `from` up to this one, as soon as no other sheet
// is open. Nothing opens when they have no entries (a build without notes).
whats_new_queue :: proc(from: string) {
	whats_new_collect(from)
	if whats_new_count() == 0 do return
	whats_new.manual = false
	whats_new.pending = true
}

// From the menu or Settings: this version's notes, at once.
whats_new_show :: proc() {
	whats_new_collect(release_before(VERSION))
	whats_new.manual = true
	settings_open, shortcuts_open = false, false
	whats_new.pending = false
	whats_new.open = true
	whats_new.scroll = 0
	platform_wake()
}

whats_new_close :: proc() {
	whats_new.open = false
	whats_new.pending = false
}

@(private = "file")
whats_new_collect :: proc(from: string) {
	for &list in whats_new.entries do clear(&list)
	delete(whats_new.from)
	whats_new.from = strings.clone(from)
	whats_new.to = VERSION
	whats_new.date = ""
	// newest first, so each section reads from the latest change back
	for r in release_notes() {
		if version_newer(r.version, VERSION) do continue
		if from != "" && !version_newer(r.version, from) do continue
		if r.version == VERSION || whats_new.date == "" do whats_new.date = r.date
		for k in Release_Kind do append(&whats_new.entries[k], ..r.entries[k][:])
	}
}

whats_new_count :: proc() -> int {
	n := 0
	for list in whats_new.entries do n += len(list)
	return n
}

// ---------------------------------------------------------------- the sheet

draw_whats_new :: proc(vg: ^nvg.Context) {
	if whats_new.pending && !onboarding.open && !settings_open && !shortcuts_open && !vtable.open {
		whats_new.pending = false
		whats_new.open = true
		whats_new.scroll = 0
	}
	if !whats_new.open do return
	saved_pass := ui.overlay_pass
	ui.overlay_pass = true
	defer ui.overlay_pass = saved_pass

	fill_rect(vg, {0, 0, app.screen.x, app.screen.y}, {0, 0, 0, 0.55})
	w := min(app.screen.x - 64, 520)
	h := min(app.screen.y - 64, 640)
	pad: f32 = 28
	text_w := w - pad * 2

	// the list's height decides the sheet's, up to the limit
	content_h := whats_new_list(vg, 0, 0, text_w, false)
	HEADER_H :: f32(108)
	FOOTER_H :: f32(72)
	LIST_TOP :: f32(22) // above the first section; the last entry's spacing is below it
	list_h := LIST_TOP + content_h + 4
	h = min(h, HEADER_H + list_h + FOOTER_H)
	sheet := Rect{(app.screen.x - w) / 2, (app.screen.y - h) / 2, w, h}
	whats_new.rect = sheet
	popup_shadow(vg, sheet, 16)
	fill_rect(vg, sheet, {0.125, 0.125, 0.135, 1}, 16)
	stroke_rect(vg, sheet, {1, 1, 1, 0.08}, 16)
	saved_clip := ui.clip
	ui.clip = sheet
	defer ui.clip = saved_clip

	// header: the icon, the title, where from and when
	if whats_new.icon == 0 do whats_new.icon = nvg.CreateImageMem(vg, WHATS_NEW_ICON, {})
	ICON :: f32(56)
	ix, iy := sheet.x + pad - 4, sheet.y + 26
	if whats_new.icon > 0 {
		nvg.BeginPath(vg)
		nvg.Rect(vg, ix, iy, ICON, ICON)
		nvg.FillPaint(vg, nvg.ImagePattern(ix, iy, ICON, ICON, 0, whats_new.icon, 1))
		nvg.Fill(vg)
	}
	tx := ix + ICON + 12
	ob_text(vg, tx, iy + 18, "What's new in Agentic Design", 18, TEXT_FG, 600)
	sub: string
	if whats_new.manual || whats_new.from == "" do sub = fmt.tprintf("Version %s", whats_new.to)
	else do sub = fmt.tprintf("Updated from %s to %s", whats_new.from, whats_new.to)
	if whats_new.date != "" do sub = fmt.tprintf("%s · %s", sub, date_long(whats_new.date))
	ob_text(vg, tx, iy + 42, sub, 13, {0.6, 0.61, 0.64, 1}, 400)
	close := Rect{sheet.x + sheet.w - 46, sheet.y + 16, 30, 30}
	if hovered(close) do fill_rect(vg, close, HOVER_BG, 8)
	draw_lucide(vg, "x", close.x + 15, close.y + 15, 16, TEXT_DIM)
	if clicked(close) || (key_pressed(KEY_ESCAPE) && ui.focus == "") {
		whats_new_close()
		return
	}
	if mouse_pressed(MOUSE_BUTTON_LEFT) && !in_rect(sheet, app.mouse) {
		whats_new_close()
		return
	}

	// the list scrolls between the header and the footer
	body := Rect{sheet.x, sheet.y + HEADER_H, sheet.w, sheet.h - HEADER_H - FOOTER_H}
	fill_rect(vg, {sheet.x, body.y - 1, sheet.w, 1}, {1, 1, 1, 0.07})
	max_scroll := max(list_h - body.h, 0)
	whats_new.scroll = clamp(whats_new.scroll - wheel_over(body), 0, max_scroll)
	nvg.Save(vg)
	nvg.IntersectScissor(vg, body.x, body.y, body.w, body.h)
	whats_new_list(vg, sheet.x + pad, body.y + LIST_TOP - whats_new.scroll, text_w, true)
	nvg.Restore(vg)
	whats_new.scroll = scrollbar(vg, "whats_new", {body.x, body.y, body.w - 4, body.h}, list_h, whats_new.scroll)

	// footer: the whole changelog, and Got it
	fy := sheet.y + sheet.h - FOOTER_H
	fill_rect(vg, {sheet.x, fy, sheet.w, 1}, {1, 1, 1, 0.07})
	link_label := "All changes"
	lw := ob_width(vg, link_label, 13, 500)
	link := Rect{sheet.x + pad - 8, fy + 18, lw + 34, 36}
	link_hot := hovered(link)
	if link_hot do fill_rect(vg, link, HOVER_BG, 8)
	link_fg := TEXT_FG if link_hot else nvg.Color{0.72, 0.73, 0.76, 1}
	ob_text(vg, link.x + 8, link.y + link.h / 2, link_label, 13, link_fg, 500)
	draw_lucide(vg, "arrow-up-right", link.x + 8 + lw + 10, link.y + link.h / 2, 14, link_fg)
	if clicked(link) {
		// one version: its release; several: the list of releases
		url := RELEASES_URL
		if whats_new.manual || release_before(VERSION) == whats_new.from do url = fmt.tprintf("%s/tag/v%s", RELEASES_URL, VERSION)
		open_url(url)
	}
	ok := Rect{sheet.x + sheet.w - pad - 108, fy + 18, 108, 36}
	if ob_button(vg, ok, "Got it", .Primary) || ((key_pressed(KEY_ENTER) || key_pressed(KEY_KP_ENTER)) && ui.focus == "") {
		whats_new_close()
	}
}

// Draws (or only measures) the sections from y; returns their height.
@(private = "file")
whats_new_list :: proc(vg: ^nvg.Context, x, y, w: f32, draw: bool) -> f32 {
	y0, yy := y, y
	first := true
	for k in Release_Kind {
		list := whats_new.entries[k]
		if len(list) == 0 do continue
		if !first do yy += 14
		first = false
		// ● LABEL (n)
		if draw {
			c := RELEASE_KIND_COLORS[k]
			nvg.BeginPath(vg)
			nvg.Circle(vg, x + 4, yy + 9, 4)
			nvg.FillColor(vg, c)
			nvg.Fill(vg)
			lab := strings.to_upper(RELEASE_KIND_LABELS[k], context.temp_allocator)
			nvg.FontFace(vg, ob_face(600))
			nvg.FontSize(vg, 11)
			nvg.TextLetterSpacing(vg, 0.9)
			nvg.TextAlign(vg, .LEFT, .MIDDLE)
			nvg.FillColor(vg, c)
			lab_w := nvg.TextBounds(vg, 0, 0, lab)
			nvg.Text(vg, x + 16, yy + 9, lab)
			nvg.TextLetterSpacing(vg, 0)
			n := fmt.tprintf("%d", len(list))
			cw := ob_width(vg, n, 11, 600) + 12
			chip_r := Rect{x + 16 + lab_w + 8, yy + 1, max(cw, 20), 16}
			fill_rect(vg, chip_r, {c.r, c.g, c.b, 0.16}, 8)
			ob_text(vg, chip_r.x + chip_r.w / 2, chip_r.y + 8, n, 11, c, 600, .CENTER)
		}
		yy += 30
		for e in list {
			hh := para_height(vg, e.headline, w - 16, 14, 500)
			if draw do para(vg, x + 16, yy, w - 16, e.headline, 14, TEXT_FG, 500)
			yy += hh
			if e.detail != "" {
				yy += 3
				dh := para_height(vg, e.detail, w - 16, 13, 400)
				if draw do para(vg, x + 16, yy, w - 16, e.detail, 13, {0.6, 0.61, 0.64, 1}, 400)
				yy += dh
			}
			yy += 14
		}
	}
	return yy - y0
}

@(private = "file")
para_setup :: proc(vg: ^nvg.Context, size: f32, weight: int) {
	nvg.FontFace(vg, ob_face(weight))
	nvg.FontSize(vg, size)
	nvg.TextLineHeight(vg, 1.15) // of the font's own line height, about 1.2 em
	nvg.TextAlign(vg, .LEFT, .TOP)
}

@(private = "file")
para :: proc(vg: ^nvg.Context, x, y, w: f32, text: string, size: f32, color: nvg.Color, weight: int) {
	para_setup(vg, size, weight)
	nvg.FillColor(vg, color)
	nvg.TextBox(vg, x, y, w, text)
	nvg.TextLineHeight(vg, 1)
}

@(private = "file")
para_height :: proc(vg: ^nvg.Context, text: string, w, size: f32, weight: int) -> f32 {
	para_setup(vg, size, weight)
	b: [4]f32
	nvg.TextBoxBounds(vg, 0, 0, w, text, &b)
	nvg.TextLineHeight(vg, 1)
	return b[3] - b[1]
}

// ---------------------------------------------------------------- socket (tests)

// {"open": true} shows this version's notes, {"menu": true} through the app menu's item,
// {"close": true} closes the sheet; the answer says whether it is open and what it shows.
api_whats_new :: proc(b: ^strings.Builder, open, close, menu: bool) -> string {
	if close do whats_new_close()
	else if open do whats_new_show()
	else if menu && !app_menu_click_whats_new() do return "the application menu has no What's New item"
	fmt.sbprintf(b, `{{"open":%v,"pending":%v,"manual":%v,"from":`, whats_new.open, whats_new.pending, whats_new.manual)
	engine.json_write_string(b, whats_new.from)
	fmt.sbprintf(b, `,"to":"%s","date":"%s","lastSeen":`, whats_new.to, whats_new.date)
	engine.json_write_string(b, settings.last_seen_version)
	strings.write_string(b, `,"sections":{`)
	for k, i in Release_Kind {
		fmt.sbprintf(b, `%s"%s":%d`, "," if i > 0 else "", strings.to_lower(RELEASE_KIND_LABELS[k], context.temp_allocator), len(whats_new.entries[k]))
	}
	r := whats_new.rect
	fmt.sbprintf(b, `}},"sheet":[%.0f,%.0f,%.0f,%.0f]}}`, r.x, r.y, r.w, r.h)
	return ""
}
