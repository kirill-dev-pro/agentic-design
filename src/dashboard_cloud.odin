#+build !js
package agentic_design

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import nvg "nanovg"

// The Dashboard's Cloud view: the account's cloud files and those shared with it (the site's
// /api/docs, the same list as its dashboard), with their previews. A double click opens one
// live (cloud_open.odin); the right button also opens it in the browser. The list comes on a
// thread of its own, again when the view comes back after half a minute.

Cloud_File :: struct {
	id, name, owner, role, updated, thumb: string, // thumb: the preview in the cache, "" none
}

@(private = "file")
dc: struct {
	lock:     sync.Mutex,
	files:    [dynamic]Cloud_File,
	incoming: [dynamic]Cloud_File, // the worker's answer, taken by the next frame
	ready:    bool,
	running:  bool,
	loaded:   bool,
	at:       f64, // when it last asked
	error:    string,
	images:   map[string]int, // preview file -> image
	selected: string,
	click:    string,
	click_at: time.Time,
	menu:     string,
}

DASH_CLOUD_MENU := [?]string{"Open", "Open in browser", "-", "People…"}

@(private = "file")
cloud_files_free :: proc(list: ^[dynamic]Cloud_File) {
	for f in list {
		delete(f.id)
		delete(f.name)
		delete(f.owner)
		delete(f.role)
		delete(f.updated)
		delete(f.thumb)
	}
	clear(list)
}

@(private = "file")
dash_cloud_fetch :: proc() {
	if dc.running do return
	dc.running = true
	dc.at = platform_time()
	thread.create_and_start(proc() {
		out := make([dynamic]Cloud_File)
		err := ""
		defer {
			sync.mutex_lock(&dc.lock)
			cloud_files_free(&dc.incoming)
			delete(dc.incoming)
			dc.incoming = out
			delete(dc.error)
			dc.error = err
			dc.ready = true
			dc.running = false
			sync.mutex_unlock(&dc.lock)
			platform_wake()
			free_all(context.temp_allocator)
		}
		base := cloud_url()
		r := cloud_http("GET", fmt.tprintf("%s/api/docs", base), bearer = cloud.token)
		if r.status != 200 {
			err = strings.clone("Sign in again (Settings → Account) to see your cloud files" if r.status == 401 else (r.err if r.err != "" else "The cloud did not answer"))
			return
		}
		o := r.json.(json.Object) or_else nil
		thumbs := fmt.tprintf("%s/cloud/previews", support_dir())
		_ = os.make_directory_all(thumbs)
		add :: proc(out: ^[dynamic]Cloud_File, f: json.Object, owner, role, base, thumbs: string) {
			str :: proc(o: json.Object, k: string) -> string {return string(o[k].(json.String) or_else "")}
			id := str(f, "id")
			if id == "" do return
			thumb := ""
			if url := str(f, "thumbUrl"); url != "" {
				// one file per version: a new version has a new preview
				p := fmt.tprintf("%s/%s-%s.png", thumbs, id, str(f, "versionId"))
				if !os.exists(p) {
					got := cloud_http("GET", fmt.tprintf("%s%s", base, url), bearer = cloud.token)
					if got.status == 200 do _ = os.write_entire_file(p, transmute([]u8)got.body)
				}
				if os.exists(p) do thumb = p
			}
			append(out, Cloud_File{strings.clone(id), strings.clone(str(f, "name")), strings.clone(owner), strings.clone(role), strings.clone(str(f, "updatedAt")), strings.clone(thumb)})
		}
		for v in o["files"].(json.Array) or_else nil do if f, ok := v.(json.Object); ok do add(&out, f, "", "owner", base, thumbs)
		for v in o["shared"].(json.Array) or_else nil {
			f := v.(json.Object) or_continue
			sh := f["shared"].(json.Object) or_else nil
			owner, role := "someone", "viewer"
			if sh != nil {
				role = string(sh["role"].(json.String) or_else "viewer")
				if ow, ok := sh["owner"].(json.String); ok do owner = string(ow)
				else if oo, ok2 := sh["owner"].(json.Object); ok2 do owner = string(oo["name"].(json.String) or_else (oo["email"].(json.String) or_else "someone"))
			}
			add(&out, f, owner, role, base, thumbs)
		}
	}, app_context(), self_cleanup = true)
}

// The Cloud view's list, in `area` (draw_dashboard draws the header).
draw_dashboard_cloud :: proc(vg: ^nvg.Context, area: Rect, x0: f32, search: string) {
	if !cloud_signed_in() {
		label(vg, x0, area.y + 28, "Sign in to see your cloud files here: the files you put in the cloud, and those shared with you.", TEXT_DIM, 13)
		if button(vg, {x0, area.y + 48, 150, 30}, "Sign in with browser", primary = true) do cloud_sign_in()
		return
	}
	sync.mutex_lock(&dc.lock)
	if dc.ready {
		dc.ready = false
		cloud_files_free(&dc.files)
		delete(dc.files)
		dc.files = dc.incoming
		dc.incoming = {}
		dc.loaded = true
	}
	err := strings.clone(dc.error, context.temp_allocator)
	sync.mutex_unlock(&dc.lock)
	if !dc.running && (!dc.loaded || platform_time() - dc.at > 30) do dash_cloud_fetch()

	list := make([dynamic]^Cloud_File, 0, len(dc.files), context.temp_allocator)
	needle := strings.to_lower(strings.trim_space(search), context.temp_allocator)
	for &f in dc.files do if needle == "" || strings.contains(strings.to_lower(f.name, context.temp_allocator), needle) do append(&list, &f)

	gap: f32 = 24
	ch: f32 = 236
	cols := max(int((app.screen.x - 2 * x0 + gap) / (280 + gap)), 1)
	cw := (app.screen.x - 2 * x0 - gap * f32(cols - 1)) / f32(cols)
	@(static) scroll: f32
	content := f32((len(list) + cols - 1) / cols) * (ch + gap) + 24
	scroll = clamp(scroll - wheel_over(area), 0, max(content - area.h, 0))
	nvg.Save(vg)
	nvg.Scissor(vg, area.x, area.y, area.w, area.h)
	saved := ui.clip
	ui.clip = area
	now := time.now()
	for f, i in list {
		col, row := i % cols, i / cols
		card := Rect{x0 + f32(col) * (cw + gap), area.y + 8 - scroll + f32(row) * (ch + gap), cw, ch}
		if card.y > area.y + area.h || card.y + card.h < area.y do continue
		cloud_card(vg, card, f)
		if clicked(card) {
			double := dc.click == f.id && time.duration_seconds(time.diff(dc.click_at, now)) < 0.45
			delete(dc.selected)
			dc.selected = strings.clone(f.id)
			delete(dc.click)
			dc.click = strings.clone(f.id)
			dc.click_at = now
			if double do cloud_open_doc(f.id)
		}
		if hovered(card) && mouse_pressed(MOUSE_BUTTON_RIGHT) {
			delete(dc.menu)
			dc.menu = strings.clone(f.id)
			menu_open("dash.cloud", {app.mouse.x, app.mouse.y, 0, 0}, DASH_CLOUD_MENU[:] if f.role == "owner" else DASH_CLOUD_MENU[:2])
		}
	}
	ui.clip = saved
	nvg.Restore(vg)
	switch {
	case !dc.loaded && err == "": label(vg, x0, area.y + 28, "Loading your cloud files…", TEXT_DIM, 13)
	case err != "" && len(dc.files) == 0: label(vg, x0, area.y + 28, err, TEXT_DIM, 13)
	case len(dc.files) == 0: label(vg, x0, area.y + 28, "No cloud files yet. Copy a file to the cloud from its card's menu (right button), or share it from the website.", TEXT_DIM, 13)
	case len(list) == 0: label(vg, x0, area.y + 28, "No file names match.", TEXT_DIM, 13)
	}
	if !ui_modal() && ui.focus == "" && dc.selected != "" && (key_pressed(KEY_ENTER) || key_pressed(KEY_KP_ENTER)) do cloud_open_doc(dc.selected)
	if pick, ok := menu_take("dash.cloud"); ok && dc.menu != "" {
		switch DASH_CLOUD_MENU[pick] {
		case "Open": cloud_open_doc(dc.menu)
		case "Open in browser": open_url(fmt.tprintf("%s/d/%s", cloud_url(), dc.menu))
		case "People…": open_url(fmt.tprintf("%s/dashboard?people=%s", cloud_url(), dc.menu))
		}
	}
}

@(private = "file")
cloud_card :: proc(vg: ^nvg.Context, card: Rect, f: ^Cloud_File) {
	hover := hovered(card)
	fill_rect(vg, card, {0.145, 0.145, 0.145, 1}, 10)
	if dc.selected == f.id do stroke_rect(vg, card, ACCENT, 10, 2)
	else do stroke_rect(vg, card, {1, 1, 1, 0.12 if hover else 0.06}, 10)
	nvg.Save(vg)
	nvg.IntersectScissor(vg, card.x + 14, card.y, card.w - 28, 56)
	label(vg, card.x + 14, card.y + 20, f.name, TEXT_FG, 13)
	who: string
	switch f.role {
	case "owner": who = "Yours"
	case "editor": who = "Can edit"
	case "commenter": who = "Can comment"
	case: who = "Can view"
	}
	if f.role != "owner" do who = fmt.tprintf("%s · %s", f.owner, who)
	label(vg, card.x + 14, card.y + 40, fmt.tprintf("%s · edited %s", who, ago_iso_text(f.updated)), TEXT_DIM, 11)
	nvg.Restore(vg)
	thumb := Rect{card.x + 10, card.y + 56, card.w - 20, card.h - 66}
	fill_rect(vg, thumb, {0.2, 0.2, 0.2, 1}, 6)
	img := 0
	if f.thumb != "" {
		if have, ok := dc.images[f.thumb]; ok do img = have
		else {
			img = nvg.CreateImagePath(app.vg, strings.clone_to_cstring(f.thumb, context.temp_allocator), {})
			dc.images[strings.clone(f.thumb)] = img
		}
	}
	if img > 0 {
		iw, ih := nvg.ImageSize(vg, img)
		if iw > 0 && ih > 0 {
			s := max(thumb.w / f32(iw), thumb.h / f32(ih)) // the card's preview fills the box
			dw, dh := f32(iw) * s, f32(ih) * s
			nvg.Save(vg)
			nvg.IntersectScissor(vg, thumb.x, thumb.y, thumb.w, thumb.h)
			nvg.BeginPath(vg)
			nvg.RoundedRect(vg, thumb.x, thumb.y, thumb.w, thumb.h, 6)
			nvg.FillPaint(vg, nvg.ImagePattern(thumb.x + (thumb.w - dw) / 2, thumb.y, dw, dh, 0, img, 1))
			nvg.Fill(vg)
			nvg.Restore(vg)
		}
	} else {
		draw_lucide(vg, "cloud", thumb.x + thumb.w / 2, thumb.y + thumb.h / 2, 28, TEXT_DIM, 1.6)
	}
	// open live: the badge
	badge := Rect{thumb.x + 8, thumb.y + 8, text_width(vg, "Cloud", 11) + 30, 20}
	fill_rect(vg, badge, {0, 0, 0, 0.55}, 10)
	draw_lucide(vg, "cloud", badge.x + 12, badge.y + 10, 11, TEXT_FG, 1.8)
	label(vg, badge.x + 22, badge.y + 10, "Cloud", TEXT_FG, 11)
}

// "3 d ago" for an ISO time.
@(private = "file")
ago_iso_text :: proc(iso: string) -> string {
	t, n := time.iso8601_to_time_utc(iso)
	if n == 0 do return "—"
	return ago(time.to_unix_seconds(t))
}
