package agentic_design

import "engine"
import "core:strings"
import nvg "nanovg"

// Drawing helpers the onboarding introduced and the inspector, the variables table and
// settings use too: Inter (or the interface font) text, wrapped paragraphs, Lucide icons
// and the sheet's buttons.

// Inter when it is installed (the onboarding's type), else the interface font.
ob_face :: proc(weight: int) -> string {
	if engine.family_find("Inter") != nil do return engine.font_face("Inter", weight, false)
	return "ui-bold" if weight >= 600 && ui_bold_loaded else "ui"
}

ui_bold_loaded: bool
ui_mono_loaded: bool // SF Mono, for code in the agent's answers

ob_text :: proc(vg: ^nvg.Context, x, y: f32, text: string, size: f32, color: nvg.Color, weight := 400, align := nvg.AlignHorizontal.LEFT) {
	nvg.FontFace(vg, ob_face(weight))
	nvg.FontSize(vg, size)
	nvg.TextLetterSpacing(vg, -size * 0.02 if size >= 24 else 0)
	nvg.TextAlign(vg, align, .MIDDLE)
	nvg.FillColor(vg, color)
	nvg.Text(vg, x, y, text)
	nvg.TextLetterSpacing(vg, 0)
}

// A paragraph wrapped to `w`, top-aligned at y.
ob_para :: proc(vg: ^nvg.Context, x, y, w: f32, text: string, size: f32, color: nvg.Color, align := nvg.AlignHorizontal.LEFT) {
	nvg.FontFace(vg, ob_face(400))
	nvg.FontSize(vg, size)
	nvg.TextLineHeight(vg, 1.45)
	nvg.TextAlign(vg, align, .TOP)
	nvg.FillColor(vg, color)
	nvg.TextBox(vg, x, y, w, text)
	nvg.TextLineHeight(vg, 1)
}

lucide_cache: map[string][dynamic]engine.Path_Cmd

// A lucide icon centred at (cx, cy).
draw_lucide :: proc(vg: ^nvg.Context, name: string, cx, cy, size: f32, color: nvg.Color, stroke: f32 = 2) {
	cmds, ok := lucide_cache[name]
	if !ok {
		d, found := engine.icon_path("lucide", name)
		if !found do return
		parsed, _, pok := engine.parse_svg_path(d)
		if !pok do return
		lucide_cache[strings.clone(name)] = parsed
		cmds = parsed
	}
	s := size / 24
	nvg.Save(vg)
	nvg.Translate(vg, cx - size / 2, cy - size / 2)
	nvg.Scale(vg, s, s)
	nvg.BeginPath(vg)
	for c in cmds do engine.path_cmd(vg, c, {0, 0}, 1, 1)
	nvg.LineCap(vg, .ROUND)
	nvg.LineJoin(vg, .ROUND)
	nvg.StrokeColor(vg, color)
	nvg.StrokeWidth(vg, stroke)
	nvg.Stroke(vg)
	nvg.Restore(vg)
}

Ob_Button :: enum {
	Primary, // light, like pen.dev's Continue
	Secondary, // outlined
	Success, // "Connected"
	Quiet, // small grey
}

ob_button :: proc(vg: ^nvg.Context, r: Rect, text: string, style: Ob_Button, icon := "", size: f32 = 14) -> bool {
	hover := hovered(r)
	fg := TEXT_FG
	switch style {
	case .Primary:
		fill_rect(vg, r, nvg.Color{0.93, 0.94, 0.96, 1} if !hover else nvg.Color{1, 1, 1, 1}, 8)
		fg = {0.08, 0.08, 0.09, 1}
	case .Secondary:
		fill_rect(vg, r, nvg.Color{1, 1, 1, 0.06 if hover else 0}, 8)
		stroke_rect(vg, r, {1, 1, 1, 0.16}, 8)
	case .Success:
		fill_rect(vg, r, {0.13, 0.25, 0.19, 1}, 8)
		fg = {0.55, 0.88, 0.66, 1}
	case .Quiet:
		fill_rect(vg, r, nvg.Color{1, 1, 1, 0.16 if hover else 0.1}, 6)
	}
	tw := ob_width(vg, text, size, 500)
	iw: f32 = 18 if icon != "" else 0
	x := r.x + (r.w - tw - iw) / 2
	ob_text(vg, x, r.y + r.h / 2, text, size, fg, 500)
	if icon != "" do draw_lucide(vg, icon, x + tw + 12, r.y + r.h / 2, 14, fg)
	return clicked(r)
}

ob_width :: proc(vg: ^nvg.Context, text: string, size: f32, weight: int) -> f32 {
	nvg.FontFace(vg, ob_face(weight))
	nvg.FontSize(vg, size)
	nvg.TextLetterSpacing(vg, -size * 0.02 if size >= 24 else 0)
	w := nvg.TextBounds(vg, 0, 0, text)
	nvg.TextLetterSpacing(vg, 0)
	return w
}
