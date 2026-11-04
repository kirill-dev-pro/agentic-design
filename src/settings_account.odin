#+build !js
package agentic_design

import "core:fmt"
import "core:strings"
import nvg "nanovg"

// Settings, Account: the cloud account this Mac is signed in to (cloud.odin), or a way to
// sign in. Signing in happens in the browser; the app never asks for a password.
draw_settings_account :: proc(vg: ^nvg.Context, x, w: f32, y: ^f32) {
	if !cloud_signed_in() {
		box := settings_group(vg, x, w, y, "", 1, 190)
		cx := box.x + box.w / 2
		nvg.BeginPath(vg)
		nvg.Circle(vg, cx, box.y + 46, 22)
		nvg.FillColor(vg, {1, 1, 1, 0.07})
		nvg.Fill(vg)
		draw_lucide(vg, "cloud", cx, box.y + 46, 20, TEXT_FG, 1.6)
		label(vg, cx, box.y + 88, "Your Agentic Design account", TEXT_FG, 14, true, .CENTER)
		label(vg, cx, box.y + 112, "Share files by link and keep them in the cloud.", TEXT_DIM, 12, false, .CENTER)
		label(vg, cx, box.y + 130, "Signing in happens in your browser; the app never asks for a password.", TEXT_DIM, 12, false, .CENTER)
		if cloud_phase() == .Signing_In {
			label(vg, cx - 10, box.y + 162, "Waiting for the browser…", TEXT_DIM, 12, false, .RIGHT)
			if button(vg, {cx, box.y + 148, 80, 28}, "Cancel") do cloud_cancel()
		} else if button(vg, {cx - 80, box.y + 148, 160, 28}, "Sign in with browser", primary = true) {
			cloud_sign_in()
		}
		if e := cloud_text(&cloud.error); e != "" do label(vg, x, y^ + 4, e, {1, 0.45, 0.4, 1}, 11)
		return
	}
	name := cloud_text(&cloud.name)
	email := cloud_text(&cloud.email)
	who := name if name != "" else email
	box := settings_group(vg, x, w, y, "", 1, 72)
	nvg.BeginPath(vg)
	nvg.Circle(vg, box.x + 36, box.y + 36, 22)
	nvg.FillColor(vg, {0.47, 0.36, 0.95, 1})
	nvg.Fill(vg)
	label(vg, box.x + 36, box.y + 36, strings.to_upper(who[:1] if len(who) > 0 else "?", context.temp_allocator), TEXT_FG, 16, true, .CENTER)
	label(vg, box.x + 70, box.y + 27, who, TEXT_FG, 14, true)
	if name != "" do label(vg, box.x + 70, box.y + 46, email, TEXT_DIM, 12)
	if button(vg, {box.x + box.w - 14 - 150, box.y + 22, 150, 28}, "Open the website ↗") do open_url(cloud_url())

	box = settings_group(vg, x, w, y, "This Mac", 1)
	cy := settings_row_text(vg, box, 0, "Signed in", "Share uses this Mac's own session; you can also sign it out on the web")
	sr := Rect{box.x + box.w - 14 - 84, cy - 14, 84, 28}
	if hovered(sr) do fill_rect(vg, sr, HOVER_BG, 6)
	label(vg, sr.x + sr.w / 2, cy, "Sign out", {1, 0.45, 0.4, 1}, 12, false, .CENTER)
	if clicked(sr) do cloud_sign_out()
	_ = fmt.tprintf
}
