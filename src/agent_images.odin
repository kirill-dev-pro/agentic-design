#+build !js
package agentic_design

import "core:crypto"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import nvg "nanovg"

// Pictures for one request (Kirill 2026-11-06): pasted with ⌘V (a screenshot, an image from
// a page) or dropped on the agent's panel. They show as thumbnails in the input, go with the
// next request only, and stay in the thread with it. A pasted picture is written as a PNG in
// $TMPDIR/agentic-design-images; a dropped file is read where it is.

MAX_CHAT_IMAGES :: 8

chat_images: [dynamic]string

IMAGE_EXTS := [?]string{".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".tif", ".tiff", ".bmp"}

is_image_path :: proc(p: string) -> bool {
	low := strings.to_lower(p, context.temp_allocator)
	for e in IMAGE_EXTS do if strings.has_suffix(low, e) do return true
	return false
}

chat_image_add :: proc(path: string) {
	if len(chat_images) >= MAX_CHAT_IMAGES {
		set_status("At most %d pictures for one request", MAX_CHAT_IMAGES)
		return
	}
	for p in chat_images do if p == path do return
	append(&chat_images, strings.clone(path))
}

chat_image_remove :: proc(i: int) {
	if i < 0 || i >= len(chat_images) do return
	delete(chat_images[i])
	ordered_remove(&chat_images, i)
}

// ⌘V in the agent's field: a picture on the clipboard becomes an attachment. False when
// the clipboard has none (the text is pasted as usual).
chat_paste_image :: proc() -> bool {
	if p := clipboard_file_path(); p != "" && is_image_path(p) && os.exists(p) {
		chat_image_add(p)
		return true
	}
	png := clipboard_image_png(context.temp_allocator)
	if len(png) == 0 do return false
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" do tmp = "/tmp"
	dir := fmt.tprintf("%s/agentic-design-images", strings.trim_right(tmp, "/"))
	_ = fs_mkdir_all(dir)
	raw: [6]u8
	crypto.rand_bytes(raw[:])
	path := fmt.tprintf("%s/pasted-%s.png", dir, hex.encode(raw[:], context.temp_allocator))
	if fs_write(path, png) != nil {
		set_status("Could not keep the pasted picture")
		return true
	}
	chat_image_add(path)
	return true
}

// The pictures for the request being sent; the input is empty of them afterwards.
chat_images_take :: proc() -> []string {
	out := make([]string, len(chat_images), context.temp_allocator)
	for p, i in chat_images {
		out[i] = strings.clone(p, context.temp_allocator)
		delete(p)
	}
	clear(&chat_images)
	return out
}

// Files dropped on the agent's panel or input: pictures for the next request, other files
// and folders as context. True when it took them.
agent_take_drop :: proc(paths: []string) -> bool {
	over := (agent_mode() && in_rect(agent_panel_rect(), app.mouse)) || (app.tab < 0 && agent_chrome_hit(app.mouse))
	if !over do return false
	t := agent_current()
	for p in paths {
		if is_image_path(p) do chat_image_add(p)
		else do agent_context_add(t, p, os.is_dir(p))
	}
	return true
}

// The thumbnails in the input, from x; returns the width they take.
draw_chat_images :: proc(vg: ^nvg.Context, x, y: f32) -> f32 {
	cx := x
	remove := -1
	for p, i in chat_images {
		r := Rect{cx, y, 44, 44}
		fill_rect(vg, r, {1, 1, 1, 0.07}, 8)
		if img := thumb_of(vg, p); img > 0 {
			iw, ih := nvg.ImageSize(vg, img)
			sc := max(r.w / f32(iw), r.h / f32(ih))
			nvg.Save(vg)
			nvg.IntersectScissor(vg, r.x, r.y, r.w, r.h)
			nvg.BeginPath(vg)
			nvg.RoundedRect(vg, r.x, r.y, r.w, r.h, 8)
			nvg.FillPaint(vg, nvg.ImagePattern(r.x + (r.w - f32(iw) * sc) / 2, r.y + (r.h - f32(ih) * sc) / 2, f32(iw) * sc, f32(ih) * sc, 0, img, 1))
			nvg.Fill(vg)
			nvg.Restore(vg)
		}
		stroke_rect(vg, r, {1, 1, 1, 0.1}, 8)
		if hovered(r) {
			tooltip_request(fs_base(p), r)
			xr := Rect{r.x + r.w - 18, r.y + 2, 16, 16}
			fill_rect(vg, xr, {0, 0, 0, 0.7}, 8)
			if lucide_button(vg, xr, "x") do remove = i
		}
		cx += 50
	}
	if remove >= 0 do chat_image_remove(remove)
	return cx - x
}
