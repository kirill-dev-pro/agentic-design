package agentic_design

import "core:encoding/json"
import "core:math"
import "core:slice"
import "core:strings"
import "engine"
import nvg "nanovg"

// What the interface itself needs from the agents' side of the app (api.odin,
// agent_tools.odin): rendering a region to pixels (tab thumbnails, export, Copy as PNG),
// resolving ids, the header's raw values and the lint switches. Shared with a browser
// host, which has no control socket.

// Resolves a list of .pen ids to uids, skipping unknown ones.
uids_param :: proc(params: json.Object, key: string) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	arr, _ := params[key].(json.Array)
	for v in arr {
		if id, ok := v.(json.String); ok {
			if n, _ := engine.doc_find(&app.doc, string(id)); n != nil do append(&out, n.uid)
		}
	}
	return out[:]
}

write_header_value :: proc(b: ^strings.Builder, key: string) {
	raw := ""
	for p in app.doc.header do if p.key == key do raw = p.raw
	strings.write_string(b, raw if raw != "" else "{}")
}

// What a layer is seen on: the fill of its nearest ancestor with an opaque one (resolved
// in the theme the screenshot uses), else white. A section without a fill of its own
// inside a dark page came out as light text on white.
shot_backdrop :: proc(target: ^engine.Node) -> nvg.Color {
	if target == nil do return {1, 1, 1, 1}
	p, _ := engine.doc_find_uid(&app.doc, target.parent)
	for depth := 0; p != nil && depth < engine.MAX_DEPTH; depth += 1 {
		if p.has_fill && p.enabled && p.fill[3] == 255 && (p.nfills <= 1 || p.fills[0].kind == .Color) {
			return {f32(p.fill[0]) / 255, f32(p.fill[1]) / 255, f32(p.fill[2]) / 255, 1}
		}
		p, _ = engine.doc_find_uid(&app.doc, p.parent)
	}
	return {1, 1, 1, 1}
}

// Draws a page rectangle (a node, or every top-level node) into the back buffer at
// `scale` pixels per unit and reads the pixels back (RGBA rows, top row first).
render_scale: f32 // the scale the last render_region used, after its limits

render_region :: proc(r: [4]f32, scale: f32, target: ^engine.Node, bg: nvg.Color) -> (pixels: []u8, ow, oh: i32, ok: bool) {
	// drawn into a buffer of its own, so it may be larger than the window (up to what the
	// GPU allows) and leaves the window's frame alone
	max_side := i32(clamp(engine.gpu_max_side(), 1024, 16384))
	// up to 16 pixels per unit, the GPU's largest texture a side and 100 Mpx in all;
	// render_scale tells callers what was used
	s := clamp(scale, 0.05, 16)
	s = min(s, f32(max_side) / r[2], f32(max_side) / r[3])
	if r[2] * s * r[3] * s > 100e6 do s *= math.sqrt(100e6 / (r[2] * s * r[3] * s)) // at most 100 Mpx
	render_scale = s
	ow, oh = i32(math.round(r[2] * s)), i32(math.round(r[3] * s)) // 191.9996 px tall is 192, as pen.dev exports it
	if ow < 1 || oh < 1 do return

	// Drawn in tiles through one buffer of a fixed size. The driver keeps the storage of a
	// deleted texture for reuse; a buffer the size of each image left 60-70 MB of video
	// memory behind after a big screenshot, a fixed one keeps at most its 20 MB. Each tile
	// draws only the layers that reach it.
	TILE :: 2048
	vg := app.vg
	pixels = make([]u8, int(ow) * int(oh) * 4, context.temp_allocator)
	tile := engine.target_make(TILE, TILE)
	defer engine.gpu_finish() // (last: the driver takes the deleted buffer back now, not at the next frame)
	defer engine.target_free(&tile)
	saved_cull := engine.cull_rect
	defer engine.cull_rect = saved_cull
	for y0 := i32(0); y0 < oh; y0 += TILE {
		for x0 := i32(0); x0 < ow; x0 += TILE {
			tw, th := min(TILE, ow - x0), min(TILE, oh - y0)
			xf := nvg.Matrix{s, 0, 0, s, -r[0] * s - f32(x0), -r[1] * s - f32(y0)}
			engine.blur_prepare({xf = xf, dpr = 1, clip = {0, 0, f32(tw), f32(th)}, fb = {TILE, TILE}, bg = bg, order = app.draw_order[:]})
			engine.target_begin(&tile, {bg.r, bg.g, bg.b, 1})
			nvg.BeginFrame(vg, TILE, TILE, 1)
			nvg.Transform(vg, xf[0], xf[1], xf[2], xf[3], xf[4], xf[5])
			engine.cull_rect = {r[0] + f32(x0) / s, r[1] + f32(y0) / s, f32(tw) / s, f32(th) / s}
			engine.blur_active = true
			if target != nil {
				engine.draw_node_tree(vg, target, 1, 0)
			} else {
				for i in 0 ..< len(app.doc.nodes) {
					if app.doc.nodes[i].parent == 0 && !app.page_hidden[app.doc.nodes[i].uid] do engine.draw_node_tree(vg, &app.doc.nodes[i], 1, 0)
				}
			}
			engine.blur_active = false
			nvg.EndFrame(vg)
			got := engine.gpu_read(&tile, 0, 0, int(tw), int(th))
			for k in 0 ..< int(th) {
				copy(pixels[((int(y0) + k) * int(ow) + int(x0)) * 4:][:int(tw) * 4], got[k * int(tw) * 4:][:int(tw) * 4])
			}
		}
	}
	return pixels, ow, oh, true
}

lint_skip_rules: []string // rules a lint call was told to ignore

// Whether a rule is switched off for a layer: by the call's `ignore`, or by
// `"metadata": {"lintIgnore": true | ["rule", ...]}` on the layer or an ancestor
// (artwork, a PDF preview, a brand colour). metadata is a .pen field, kept by pen.dev.
lint_ignored :: proc(n: ^engine.Node, rule: string) -> bool {
	if slice.contains(lint_skip_rules, rule) do return true
	cur := n
	for depth := 0; cur != nil && depth < engine.MAX_DEPTH; depth += 1 {
		if i := engine.prop_index(cur, "metadata"); i >= 0 && strings.contains(cur.props[i].raw, "lintIgnore") {
			if v, err := json.parse_string(cur.props[i].raw, .JSON5, false, context.temp_allocator); err == nil {
				if obj, ok := v.(json.Object); ok {
					#partial switch x in obj["lintIgnore"] {
					case json.Boolean:
						if x do return true
					case json.String:
						if string(x) == rule do return true
					case json.Array:
						for r in x do if string(r.(json.String) or_else "") == rule do return true
					}
				}
			}
		}
		cur, _ = engine.doc_find_uid(&app.doc, cur.parent)
	}
	return false
}
