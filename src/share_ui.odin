#+build !js
package agentic_design

import "core:fmt"
import "core:strings"
import nvg "nanovg"

import "engine"

// The Share sheet (cloud.odin): sign in through the browser, then share the open file by a
// link, upload changes behind the same link, set what the link allows, turn it off.

share_open: bool
share_opened_at: int // the frame it opened in: the click that opened it is not a click outside

share_sheet_open :: proc() {
	if app.tab < 0 do return
	cloud_load()
	share_open = true
	share_opened_at = frames_drawn
}

// Every frame: a finished share puts its link on the clipboard.
share_tick :: proc() {
	if !cloud.copied do return
	cloud.copied = false
	if app.tab < 0 do return
	if s, ok := cloud_share_of(app.file_path); ok && s.url != "" {
		platform_clipboard_set(s.url)
		if len(s.missing) > 0 do set_status("Link copied. %d file%s the document refers to %s missing.", len(s.missing), "" if len(s.missing) == 1 else "s", "is" if len(s.missing) == 1 else "are")
		else do set_status("Link copied: %s", s.url)
	}
}

draw_share_sheet :: proc(vg: ^nvg.Context) {
	if !share_open do return
	if app.tab < 0 {
		share_open = false
		return
	}
	saved_pass := ui.overlay_pass
	ui.overlay_pass = true
	defer ui.overlay_pass = saved_pass
	signed_in := cloud_signed_in()
	share, shared := cloud_share_of(app.file_path)
	h: f32 = 236 if !signed_in else (322 if shared else 300)
	if shared && len(share.missing) > 0 do h += 40
	sheet, open := sheet_begin(vg, "Share", 480, h)
	if !open && share_opened_at != frames_drawn {
		share_open = false
		return
	}
	saved_clip := ui.clip
	ui.clip = sheet
	defer ui.clip = saved_clip

	x, w := sheet.x + 24, sheet.w - 48
	y := sheet.y + 60
	phase := cloud_phase()
	busy := cloud.running || phase == .Working || phase == .Signing_In
	dim := nvg.Color{0.62, 0.63, 0.66, 1}

	if !signed_in {
		ob_para(vg, x, y, w, "Share this file with a link that opens in any browser, on a phone too. Sign in with your Agentic Design account first: the browser opens to approve this Mac.", 13, dim)
		y += 84
		if phase == .Signing_In {
			label(vg, x, y + 14, "Waiting for the browser…", TEXT_FG, 13)
			if button(vg, {x + w - 196, y, 92, 28}, "Open again") do open_url(cloud_text(&cloud.signin_url))
			if button(vg, {x + w - 96, y, 96, 28}, "Cancel") do cloud_cancel()
		} else {
			if button(vg, {x, y, 200, 32}, "Sign in with browser", primary = true) && !busy do cloud_sign_in()
		}
		y += 48
	} else {
		// the account
		email := cloud_text(&cloud.email)
		label(vg, x, y + 10, fmt.tprintf("Signed in as %s", email) if email != "" else "Signed in", dim, 12)
		so := Rect{x + w - 72, y - 2, 72, 24}
		if hovered(so) do fill_rect(vg, so, HOVER_BG, 6)
		label(vg, so.x + so.w / 2, so.y + 12, "Sign out", TEXT_FG, 12, false, .CENTER)
		if clicked(so) && !busy do cloud_sign_out()
		y += 34
		fill_rect(vg, {sheet.x, y, sheet.w, 1}, PANEL_LINE)
		y += 18
		name := engine.file_title(app.file_path)
		if !shared {
			ob_text(vg, x, y + 8, name, 15, TEXT_FG, 600)
			y += 26
			ob_para(vg, x, y, w, "Upload this file and get a link. The images, fonts and libraries it uses go with it. Anyone with the link can view it; only you can change it.", 13, dim)
			y += 70
			if button(vg, {x, y, 140, 32}, "Create link", primary = true) && !busy do share_start()
			y += 48
		} else {
			ob_text(vg, x, y + 8, name, 15, TEXT_FG, 600)
			y += 24
			// the link, and Copy
			box := Rect{x, y, w - 92, 30}
			fill_rect(vg, box, FIELD_BG, 6)
			nvg.Save(vg)
			nvg.IntersectScissor(vg, box.x + 8, box.y, box.w - 16, box.h)
			label(vg, box.x + 10, box.y + 15, share.url, TEXT_FG, 12)
			nvg.Restore(vg)
			if button(vg, {x + w - 84, y, 84, 30}, "Copy link", primary = true) {
				platform_clipboard_set(share.url)
				set_status("Link copied")
			}
			y += 42
			if checkbox(vg, {x, y, 220, 22}, "Allow download", share.allow_download) && !busy do cloud_share_settings(app.file_path, !share.allow_download, share.allow_embed)
			if checkbox(vg, {x + 230, y, 200, 22}, "Allow embedding", share.allow_embed) && !busy do cloud_share_settings(app.file_path, share.allow_download, !share.allow_embed)
			y += 36
			label(vg, x, y + 8, "The link shows the last version you uploaded.", dim, 12)
			y += 26
			if button(vg, {x, y, 148, 30}, "Upload changes", primary = true) && !busy do share_start()
			if button(vg, {x + 156, y, 112, 30}, "Open in browser") do open_url(share.url)
			off := Rect{x + w - 100, y, 100, 30}
			if hovered(off) do fill_rect(vg, off, {0.9, 0.3, 0.3, 0.12}, 6)
			label(vg, off.x + off.w / 2, off.y + 15, "Turn off link", {0.95, 0.45, 0.42, 1}, 12, false, .CENTER)
			if clicked(off) && !busy do cloud_share_revoke(app.file_path)
			y += 44
			if len(share.missing) > 0 {
				list := strings.join(share.missing[:min(len(share.missing), 3)], ", ", context.temp_allocator)
				more := fmt.tprintf(" and %d more", len(share.missing) - 3) if len(share.missing) > 3 else ""
				ob_para(vg, x, y, w, fmt.tprintf("Not found, so not shared: %s%s", list, more), 12, {0.96, 0.66, 0.30, 1})
				y += 40
			}
		}
	}
	// progress or the last error
	line, color := cloud_text(&cloud.progress), dim
	if phase == .Signing_In do line = "" // said above, with Cancel
	if line == "" && phase == .Failed do line, color = cloud_text(&cloud.error), nvg.Color{0.95, 0.45, 0.42, 1}
	if line != "" do ob_para(vg, x, sheet.y + sheet.h - 40, w, line, 12, color)
}

@(private = "file")
share_start :: proc() {
	if app.dirty do save_document(app.file_path)
	cloud_share(app.file_path, engine.file_title(app.file_path))
}
