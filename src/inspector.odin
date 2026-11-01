package agentic_design

import "engine"

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import "vendor:glfw"
import nvg "nanovg"

// Inspector sections modelled on pen.dev's properties panel: alignment, position with
// rotation and flips, dimensions with Fill/Hug, appearance with per-corner radius, fill
// and effect lists, typography details, context and per-layer export. The field keys
// they use (fill.N, effect.N.blur, radius.tl, ...) are applied in inspector_field_apply.

// An icon button drawing a lucide icon.
lucide_button :: proc(vg: ^nvg.Context, r: Rect, icon: string, active := false, tip := "") -> bool {
	hover := hovered(r)
	if active do fill_rect(vg, r, ACTIVE_BG, 6)
	else if hover do fill_rect(vg, r, HOVER_BG, 6)
	draw_lucide(vg, icon, r.x + r.w / 2, r.y + r.h / 2, 15, TEXT_FG if active || hover else TEXT_DIM, 1.6)
	if hover && tip != "" do tooltip_request(tip, r)
	return clicked(r)
}

// A row of segmented lucide buttons; returns the clicked index or -1.
segmented :: proc(vg: ^nvg.Context, r: Rect, icons: []string, current: int, tips: []string = nil) -> int {
	fill_rect(vg, r, FIELD_BG, 6)
	seg := (r.w - 4) / f32(len(icons))
	picked := -1
	for icon, i in icons {
		b := Rect{r.x + 2 + f32(i) * seg, r.y + 2, seg, r.h - 4}
		tip := tips[i] if i < len(tips) else ""
		if lucide_button(vg, b, icon, i == current, tip) && i != current do picked = i
	}
	return picked
}

// ---------------------------------------------------------------- alignment

draw_alignment_row :: proc(vg: ^nvg.Context, x, w: f32, y: ^f32) {
	section(vg, x, y, "Alignment")
	Op :: struct {
		op:   Align_Op,
		icon: string,
		tip:  string,
	}
	ops := [?]Op {
		{.Left, "align-start-vertical", "Align left  ⌥A"},
		{.Center_H, "align-center-vertical", "Align centre  ⌥H"},
		{.Right, "align-end-vertical", "Align right  ⌥D"},
		{.Top, "align-start-horizontal", "Align top  ⌥W"},
		{.Center_V, "align-center-horizontal", "Align middle  ⌥V"},
		{.Bottom, "align-end-horizontal", "Align bottom  ⌥S"},
	}
	bw := (w - 12) / 6
	for o, i in ops {
		gap: f32 = 12 if i >= 3 else 0
		r := Rect{x + f32(i) * bw + gap, y^, bw - 2, 28}
		if i == 0 || i == 3 do fill_rect(vg, {r.x, r.y, bw * 3 - 2, 28}, FIELD_BG, 6)
		if lucide_button(vg, r, o.icon, false, o.tip) do align_selection(o.op)
	}
	y^ += 36
	divider(vg, x, w, y)
}

// ---------------------------------------------------------------- position

draw_position_rows :: proc(vg: ^nvg.Context, n: ^engine.Node, x, w: f32, y: ^f32) {
	half := (w - 8) / 2
	section(vg, x, y, "Position")
	ox, oy := engine.parent_origin(&app.doc, n.parent)
	field(vg, n.uid, "x", "X", {x, y^, half, 28}, engine.num_text(n.x - ox), numeric = true)
	field(vg, n.uid, "y", "Y", {x + half + 8, y^, half, 28}, engine.num_text(n.y - oy), numeric = true)
	y^ += 36
	field(vg, n.uid, "rotation", "°", {x, y^, half, 28}, engine.num_text(n.rotation), numeric = true)
	icons := [3]string{"rotate-ccw-square", "move-horizontal", "move-vertical"}
	tips := [3]string{"Rotate 90°", "Flip horizontal  ⇧H", "Flip vertical  ⇧V"}
	bw := (half) / 3
	for icon, i in icons {
		r := Rect{x + half + 8 + f32(i) * bw, y^, bw - 2, 28}
		active := (i == 1 && n.flip_x) || (i == 2 && n.flip_y)
		if lucide_button(vg, r, icon, active, tips[i]) {
			push_undo()
			switch i {
			case 0: transform_in_place(n, n.rotation + 90, n.flip_x, n.flip_y)
			case 1: transform_in_place(n, n.rotation, !n.flip_x, n.flip_y)
			case 2: transform_in_place(n, n.rotation, n.flip_x, !n.flip_y)
			}
		}
	}
	y^ += 36
	if p, _ := engine.doc_find_uid(&app.doc, n.parent); p != nil && p.layout != .None {
		if checkbox(vg, {x, y^, w, 22}, "Absolute position", n.abs_pos) {
			push_undo()
			if n.abs_pos do engine.node_unset(&app.doc, n, "layoutPosition")
			else do engine.node_set_string(&app.doc, n, "layoutPosition", "absolute")
		}
		y^ += 28
	}
	divider(vg, x, w, y)
}

toggle_flag :: proc(n: ^engine.Node, key: string, on: bool) {
	if on do engine.node_unset(&app.doc, n, key)
	else do engine.node_set_bool(&app.doc, n, key, true)
}

// ---------------------------------------------------------------- dimensions

draw_dimension_rows :: proc(vg: ^nvg.Context, n: ^engine.Node, x, w: f32, y: ^f32) {
	half := (w - 8) / 2
	label(vg, x, y^ + 6, "Dimensions", TEXT_DIM, 11)
	y^ += 16
	field(vg, n.uid, "width", "W", {x, y^, half, 28}, engine.num_text(n.w), numeric = true)
	field(vg, n.uid, "height", "H", {x + half + 8, y^, half, 28}, engine.num_text(n.h), numeric = true)
	y^ += 34
	p, _ := engine.doc_find_uid(&app.doc, n.parent)
	in_flex := p != nil && p.layout != .None && !n.abs_pos
	if in_flex {
		if checkbox(vg, {x, y^, half, 22}, "Fill width", n.width.mode == .Fill) do set_size_mode(n, "width", .Fill)
		if checkbox(vg, {x + half + 8, y^, half, 22}, "Fill height", n.height.mode == .Fill) do set_size_mode(n, "height", .Fill)
		y^ += 26
	}
	if n.kind == .Text {
		label(vg, x, y^ + 8, "Resizing", TEXT_DIM, 11)
		y^ += 18
		modes := [3]string{"arrow-left-right", "text-wrap", "scan"}
		tips := [3]string{"Auto width", "Auto height", "Fixed size"}
		cur := int(n.growth)
		if pick := segmented(vg, {x, y^, w, 28}, modes[:], cur, tips[:]); pick >= 0 {
			push_undo()
			switch pick {
			case 0:
				engine.node_set_string(&app.doc, n, "textGrowth", "auto")
				engine.node_unset(&app.doc, n, "width")
				engine.node_unset(&app.doc, n, "height")
			case 1:
				engine.node_set_string(&app.doc, n, "textGrowth", "fixed-width")
				if n.width.mode != .Fill do engine.node_set_number(&app.doc, n, "width", n.w)
				engine.node_unset(&app.doc, n, "height")
			case 2:
				engine.node_set_string(&app.doc, n, "textGrowth", "fixed-width-height")
				if n.width.mode != .Fill do engine.node_set_number(&app.doc, n, "width", n.w)
				engine.node_set_number(&app.doc, n, "height", n.h)
			}
		}
		y^ += 36
	} else if n.kind == .Frame || n.kind == .Group || n.kind == .Ref {
		if checkbox(vg, {x, y^, half, 22}, "Hug width", n.width.mode == .Fit) do set_size_mode(n, "width", .Fit)
		if checkbox(vg, {x + half + 8, y^, half, 22}, "Hug height", n.height.mode == .Fit) do set_size_mode(n, "height", .Fit)
		y^ += 30
	}
}

// Toggles a size mode: on sets fill_container / fit_content, off fixes the current size.
set_size_mode :: proc(n: ^engine.Node, key: string, mode: engine.Size_Mode) {
	push_undo()
	cur := n.width.mode if key == "width" else n.height.mode
	size := n.w if key == "width" else n.h
	if cur == mode {
		engine.node_set_number(&app.doc, n, key, math.round(size * 100) / 100)
	} else {
		engine.node_set_string(&app.doc, n, key, "fill_container" if mode == .Fill else "fit_content")
		if n.kind == .Text && mode == .Fill && n.growth == .Auto do engine.node_set_string(&app.doc, n, "textGrowth", "fixed-width")
	}
}

// ---------------------------------------------------------------- appearance

draw_appearance :: proc(vg: ^nvg.Context, n: ^engine.Node, x, w: f32, y: ^f32) {
	half := (w - 8) / 2
	section(vg, x, y, "Appearance")
	if icon_button(vg, {x + w - 24, y^ - 32, 24, 24}, .Eye if n.enabled else .Eye_Off, false, "Show / hide") {
		push_undo()
		if n.enabled do engine.node_set_bool(&app.doc, n, "enabled", false)
		else do engine.node_unset(&app.doc, n, "enabled")
	}
	field(vg, n.uid, "opacity", "", {x, y^, half, 28}, fmt.tprintf("%d%%", int(n.opacity * 100 + 0.5)), icon = .Opacity, numeric = true)
	rounded := n.kind == .Rectangle || n.kind == .Frame || n.kind == .Ref
	if rounded {
		r := n.radius
		uniform := r[0] == r[1] && r[1] == r[2] && r[2] == r[3]
		if !ui.radius_corners {
			field(vg, n.uid, "cornerRadius", "R", {x + half + 8, y^, half - 30, 28}, engine.num_text(r[0]) if uniform else "Mixed", numeric = true)
		}
		if lucide_button(vg, {x + w - 26, y^ + 1, 26, 26}, "square-round-corner", ui.radius_corners, "Corners") do ui.radius_corners = !ui.radius_corners
		y^ += 36
		if ui.radius_corners {
			q := (w - 24) / 4
			keys := [4]string{"radius.tl", "radius.tr", "radius.br", "radius.bl"}
			labels := [4]string{"↖", "↗", "↘", "↙"}
			for k, i in keys do field(vg, n.uid, k, labels[i], {x + f32(i) * (q + 8), y^, q, 28}, engine.num_text(r[i]), numeric = true)
			y^ += 36
		}
	} else {
		y^ += 36
	}
	if n.kind == .Frame {
		if checkbox(vg, {x, y^, w, 22}, "Clip content", n.clip) {
			push_undo()
			engine.node_set_bool(&app.doc, n, "clip", !n.clip)
		}
		y^ += 28
	}
	divider(vg, x, w, y)
}

// ---------------------------------------------------------------- fills

fill_items :: proc(n: ^engine.Node) -> json.Array {
	v, ok := engine.prop_value(n, "fill")
	if !ok do return nil
	if arr, is_arr := v.(json.Array); is_arr do return arr
	out := make(json.Array, 0, 1, context.temp_allocator)
	append(&out, v)
	return out
}

// Writes the fill list back: a lone solid colour stays a plain string, as pen.dev writes
// it, and a lone paint object stays an object unless the file had a list.
fill_store :: proc(n: ^engine.Node, items: json.Array) {
	if len(items) == 0 {
		engine.node_unset(&app.doc, n, "fill")
		return
	}
	if len(items) == 1 {
		if s, is_str := items[0].(json.String); is_str {
			engine.node_set_string(&app.doc, n, "fill", string(s))
			return
		}
		cur, _ := engine.prop_value(n, "fill")
		if _, was_list := cur.(json.Array); !was_list {
			engine.node_set(&app.doc, n, "fill", items[0])
			return
		}
	}
	engine.node_set(&app.doc, n, "fill", items)
}

fill_object :: proc(item: json.Value) -> json.Object {
	if obj, ok := item.(json.Object); ok do return obj
	o := make(json.Object, context.temp_allocator)
	o["type"] = json.String("color")
	o["color"] = item
	return o
}

paint_of :: proc(item: json.Value) -> engine.Paint {
	tmp: engine.Node
	engine.parse_fills(&app.doc, &tmp, item)
	if tmp.nfills == 0 do return engine.Paint{kind = .Color, enabled = true, opacity = 1}
	return tmp.fills[0]
}

draw_fills_section :: proc(vg: ^nvg.Context, n: ^engine.Node, x, w: f32, y: ^f32) {
	section(vg, x, y, "Fill")
	items := fill_items(n)
	if icon_button(vg, {x + w - 24, y^ - 32, 24, 24}, .Plus, false, "Add fill") {
		push_undo()
		out := make(json.Array, 0, len(items) + 1, context.temp_allocator)
		append(&out, ..items[:])
		append(&out, json.String("#D9D9D9" if n.kind != .Text else "#1E1E1E"))
		fill_store(n, out)
		return
	}
	for item, i in items {
		p := paint_of(item)
		row := Rect{x, y^, w - 80, 28}
		if p.kind == .Color {
			color_row(vg, n, fmt.tprintf("fill.%d", i), row.x, row.w, row.y, p.color)
		} else {
			fill_rect(vg, row, FIELD_BG, 6)
			sw := Rect{row.x + 6, row.y + 6, 16, 16}
			fake := engine.Node{x = sw.x, y = sw.y, w = sw.w, h = sw.h}
			nvg.BeginPath(vg)
			nvg.RoundedRect(vg, sw.x, sw.y, sw.w, sw.h, 4)
			if p.kind == .Image {
				nvg.FillColor(vg, {0.5, 0.5, 0.5, 1})
				nvg.Fill(vg)
			} else {
				nvg.FillPaint(vg, engine.gradient_paint(vg, &fake, &p))
				nvg.Fill(vg)
			}
			kinds := [engine.Paint_Kind]string{.Color = "Solid", .Linear = "Linear", .Radial = "Radial", .Angular = "Angular", .Image = "Image"}
			label(vg, row.x + 30, row.y + 14, kinds[p.kind], TEXT_FG)
		}
		// kind menu, visibility, remove
		kr := Rect{x + w - 78, y^ + 2, 24, 24}
		if lucide_button(vg, kr, "chevrons-up-down", false, "Fill type") {
			menu_open(fmt.tprintf("fillkind:%d", i), {x, y^, w, 28}, {"Solid", "Linear gradient", "Radial gradient", "Angular gradient"}, int(p.kind) if p.kind != .Image else -1)
		}
		if pick, ok := menu_take(fmt.tprintf("fillkind:%d", i)); ok {
			fill_set_kind(n, i, pick)
			if pick > 0 do ui.grad = {uid = n.uid, fill = i}
		}
		if lucide_button(vg, {x + w - 26, y^ + 2, 24, 24}, "minus", false, "Remove") {
			push_undo()
			out := fill_items(n)
			ordered_remove(&out, i)
			fill_store(n, out)
			return
		}
		if lucide_button(vg, {x + w - 52, y^ + 2, 24, 24}, "eye" if p.enabled else "eye-off", false, "Show / hide") {
			push_undo()
			out := fill_items(n)
			o := fill_object(out[i])
			if p.enabled do o["enabled"] = json.Boolean(false)
			else do delete_key(&o, "enabled")
			out[i] = o
			if len(o) == 2 && p.enabled == false {
				if c, has := o["color"]; has && string(o["type"].(json.String) or_else "") == "color" do out[i] = c
			}
			fill_store(n, out)
		}
		if p.kind != .Color && p.kind != .Image && clicked(row) do ui.grad = {uid = n.uid, fill = i}
		y^ += 32
		if p.kind == .Linear || p.kind == .Radial || p.kind == .Angular {
			half := (w - 8) / 2
			draw_gradient_stops(vg, n, i, &p, x, w, y)
			field(vg, n.uid, fmt.tprintf("fill.%d.rotation", i), "°", {x, y^, half, 28}, engine.num_text(p.rotation), numeric = true)
			if p.kind != .Linear {
				field(vg, n.uid, fmt.tprintf("fill.%d.size", i), "Size", {x + half + 8, y^, half, 28}, fmt.tprintf("%d%%", int(p.size.x * 100 + 0.5)), numeric = true)
			}
			y^ += 32
		}
	}
	divider(vg, x, w, y)
}

// ---------------------------------------------------------------- gradient stops

// The stops of fill i, editable: the fill list, the fill object and its colors.
grad_colors :: proc(n: ^engine.Node, i: int) -> (out: json.Array, o: json.Object, colors: json.Array, ok: bool) {
	out = fill_items(n)
	if i >= len(out) do return
	o = fill_object(out[i])
	colors, ok = o["colors"].(json.Array)
	return
}

grad_store :: proc(n: ^engine.Node, i: int, out: json.Array, o: json.Object, colors: json.Array) {
	o := o
	o["colors"] = colors
	out[i] = o
	fill_store(n, out)
}

stop_pos :: proc(c: json.Value) -> f32 {
	co, _ := c.(json.Object)
	return f32(co["position"].(json.Float) or_else 0)
}

stop_set_pos :: proc(c: json.Value, pos: f32) {
	if co, ok := c.(json.Object); ok {
		co := co
		co["position"] = json.Float(math.round(f64(clamp(pos, 0, 1)) * 1000) / 1000)
	}
}

// A bar showing the gradient with a marker per stop (drag to move one, click the bar to
// add one), then a row per stop: position, colour, remove.
draw_gradient_stops :: proc(vg: ^nvg.Context, n: ^engine.Node, i: int, p: ^engine.Paint, x, w: f32, y: ^f32) {
	editing := ui.grad.uid == n.uid && ui.grad.fill == i
	bar := Rect{x + 6, y^ + 4, w - 12, 16}
	lp := p^
	lp.kind = .Linear
	nvg.BeginPath(vg)
	nvg.RoundedRect(vg, bar.x, bar.y, bar.w, bar.h, 4)
	nvg.FillPaint(vg, nvg.ImagePattern(bar.x, bar.y, bar.w, 1, 0, engine.gradient_image(vg, &lp), 1))
	nvg.Fill(vg)
	stroke_rect(vg, bar, {1, 1, 1, 0.12}, 4)
	// markers under the bar
	marker_hit := -1
	for k in 0 ..< p.nstops {
		mx := bar.x + p.stops[k].pos * bar.w
		m := Rect{mx - 6, bar.y + bar.h + 2, 12, 12}
		nvg.BeginPath(vg)
		nvg.RoundedRect(vg, m.x, m.y, m.w, m.h, 3)
		nvg.FillColor(vg, engine.to_nvg(p.stops[k].color))
		nvg.Fill(vg)
		nvg.StrokeColor(vg, ACCENT if editing && ui.grad.stop == k else nvg.Color{1, 1, 1, 0.8})
		nvg.StrokeWidth(vg, 2 if editing && ui.grad.stop == k else 1)
		nvg.Stroke(vg)
		if hovered({m.x - 2, m.y - 2, m.w + 4, m.h + 4}) do marker_hit = k
	}
	if marker_hit >= 0 && clicked({x, bar.y, w, 34}) {
		ui.grad = {uid = n.uid, fill = i, stop = marker_hit, dragging = true}
		push_undo()
	} else if clicked(bar) {
		// a new stop where the bar was clicked, in the colour the gradient has there
		pos := clamp((app.mouse.x - bar.x) / bar.w, 0, 1)
		if out, o, colors, ok := grad_colors(n, i); ok && len(colors) < engine.MAX_STOPS {
			push_undo()
			c := make(json.Object, context.temp_allocator)
			c["color"] = json.String(engine.color_hex(engine.gradient_at(p, pos)))
			c["position"] = json.Float(math.round(f64(pos) * 1000) / 1000)
			k := len(colors)
			for cv, j in colors do if stop_pos(cv) > pos {k = j; break}
			inject_at(&colors, k, c)
			grad_store(n, i, out, o, colors)
			ui.grad = {uid = n.uid, fill = i, stop = k, dragging = true}
		}
	}
	// a dragged marker stays between its neighbours, so the stops keep their order
	if editing && ui.grad.dragging {
		if !mouse_down(glfw.MOUSE_BUTTON_LEFT) {
			ui.grad.dragging = false
		} else if out, o, colors, ok := grad_colors(n, i); ok && ui.grad.stop < len(colors) {
			k := ui.grad.stop
			lo: f32 = stop_pos(colors[k - 1]) if k > 0 else 0
			hi: f32 = stop_pos(colors[k + 1]) if k + 1 < len(colors) else 1
			pos := clamp((app.mouse.x - bar.x) / bar.w, lo, hi)
			if abs(pos - stop_pos(colors[k])) > 1e-4 {
				stop_set_pos(colors[k], pos)
				grad_store(n, i, out, o, colors)
			}
		}
	}
	y^ += 40
	// one row per stop
	for k in 0 ..< p.nstops {
		field(vg, n.uid, fmt.tprintf("fill.%d.stoppos.%d", i, k), "", {x, y^, 56, 28}, fmt.tprintf("%d%%", int(math.round(p.stops[k].pos * 100))), numeric = true)
		color_row(vg, n, fmt.tprintf("fill.%d.stop.%d", i, k), x + 64, w - 64 - 30, y^, p.stops[k].color)
		if p.nstops > 2 && lucide_button(vg, {x + w - 26, y^ + 2, 24, 24}, "minus", false, "Remove stop") {
			if out, o, colors, ok := grad_colors(n, i); ok && k < len(colors) {
				push_undo()
				ordered_remove(&colors, k)
				grad_store(n, i, out, o, colors)
				ui.grad.stop = max(0, min(ui.grad.stop, len(colors) - 1))
				return
			}
		}
		y^ += 32
	}
}

fill_set_kind :: proc(n: ^engine.Node, i: int, kind: int) {
	out := fill_items(n)
	if i >= len(out) do return
	push_undo()
	p := paint_of(out[i])
	base := engine.color_hex(p.color)
	if kind == 0 {
		out[i] = json.String(base)
	} else {
		o := make(json.Object, context.temp_allocator)
		o["type"] = json.String("gradient")
		types := [4]string{"linear", "linear", "radial", "angular"}
		o["gradientType"] = json.String(types[clamp(kind, 0, 3)])
		colors := make(json.Array, 0, 2, context.temp_allocator)
		if p.nstops >= 2 {
			for s in p.stops[:p.nstops] {
				c := make(json.Object, context.temp_allocator)
				c["color"] = json.String(engine.color_hex(s.color))
				c["position"] = engine.json_num(s.pos)
				append(&colors, c)
			}
		} else {
			c0 := make(json.Object, context.temp_allocator)
			c0["color"] = json.String(base)
			c0["position"] = json.Float(0)
			end := p.color
			end[3] = 0
			c1 := make(json.Object, context.temp_allocator)
			c1["color"] = json.String(engine.color_hex(end))
			c1["position"] = json.Float(1)
			append(&colors, c0)
			append(&colors, c1)
		}
		o["colors"] = colors
		if kind == 1 do o["rotation"] = json.Float(180)
		out[i] = o
	}
	fill_store(n, out)
}

// ---------------------------------------------------------------- effects

effect_items :: proc(n: ^engine.Node) -> json.Array {
	v, ok := engine.prop_value(n, "effect")
	if !ok do return nil
	if arr, is_arr := v.(json.Array); is_arr do return arr
	out := make(json.Array, 0, 1, context.temp_allocator)
	append(&out, v)
	return out
}

effect_store :: proc(n: ^engine.Node, items: json.Array) {
	if len(items) == 0 do engine.node_unset(&app.doc, n, "effect")
	else if len(items) == 1 do engine.node_set(&app.doc, n, "effect", items[0])
	else do engine.node_set(&app.doc, n, "effect", items)
}

EFFECT_NAMES := [engine.Effect_Kind]string {
	.Drop_Shadow     = "Drop shadow",
	.Inner_Shadow    = "Inner shadow",
	.Blur            = "Layer blur",
	.Background_Blur = "Background blur",
}

new_effect :: proc(kind: engine.Effect_Kind) -> json.Object {
	o := make(json.Object, context.temp_allocator)
	switch kind {
	case .Drop_Shadow, .Inner_Shadow:
		o["type"] = json.String("shadow")
		o["shadowType"] = json.String("inner" if kind == .Inner_Shadow else "outer")
		off := make(json.Object, context.temp_allocator)
		off["x"] = json.Float(0)
		off["y"] = json.Float(4)
		o["offset"] = off
		o["blur"] = json.Float(12)
		o["color"] = json.String("#00000040")
	case .Blur:
		o["type"] = json.String("blur")
		o["radius"] = json.Float(4)
	case .Background_Blur:
		o["type"] = json.String("background_blur")
		o["radius"] = json.Float(12)
	}
	return o
}

draw_effects_section :: proc(vg: ^nvg.Context, n: ^engine.Node, x, w: f32, y: ^f32) {
	section(vg, x, y, "Effects")
	plus := Rect{x + w - 24, y^ - 32, 24, 24}
	if icon_button(vg, plus, .Plus, false, "Add effect") {
		menu_open("effect.add", {x + w - 160, y^ - 8, 160, 28}, {"Drop shadow", "Inner shadow", "Layer blur", "Background blur"})
	}
	if pick, ok := menu_take("effect.add"); ok {
		push_undo()
		out := make(json.Array, 0, 4, context.temp_allocator)
		append(&out, ..effect_items(n)[:])
		append(&out, new_effect(engine.Effect_Kind(pick)))
		effect_store(n, out)
		return
	}
	items := effect_items(n)
	q := (w - 24) / 4
	half := (w - 8) / 2
	for item, i in items {
		tmp: engine.Node
		engine.parse_effects(&app.doc, &tmp, item)
		if tmp.neffects == 0 do continue
		e := tmp.effects[0]
		names := []string{"Drop shadow", "Inner shadow", "Layer blur", "Background blur"}
		if pick, ok := dropdown_menu(vg, fmt.tprintf("effect.kind.%d", i), {x, y^, w - 56, 28}, names, int(e.kind)); ok && pick != int(e.kind) {
			push_undo()
			out := effect_items(n)
			out[i] = new_effect(engine.Effect_Kind(pick))
			effect_store(n, out)
		}
		if lucide_button(vg, {x + w - 52, y^ + 2, 24, 24}, "eye" if e.enabled else "eye-off", false, "Show / hide") {
			push_undo()
			out := effect_items(n)
			o, _ := out[i].(json.Object)
			if e.enabled do o["enabled"] = json.Boolean(false)
			else do delete_key(&o, "enabled")
			out[i] = o
			effect_store(n, out)
		}
		if lucide_button(vg, {x + w - 26, y^ + 2, 24, 24}, "minus", false, "Remove") {
			push_undo()
			out := effect_items(n)
			ordered_remove(&out, i)
			effect_store(n, out)
			return
		}
		y^ += 34
		switch e.kind {
		case .Drop_Shadow, .Inner_Shadow:
			field(vg, n.uid, fmt.tprintf("effect.%d.x", i), "X", {x, y^, q, 28}, engine.num_text(e.offset.x), numeric = true)
			field(vg, n.uid, fmt.tprintf("effect.%d.y", i), "Y", {x + q + 8, y^, q, 28}, engine.num_text(e.offset.y), numeric = true)
			field(vg, n.uid, fmt.tprintf("effect.%d.blur", i), "B", {x + 2 * (q + 8), y^, q, 28}, engine.num_text(e.blur), numeric = true)
			field(vg, n.uid, fmt.tprintf("effect.%d.spread", i), "S", {x + 3 * (q + 8), y^, q, 28}, engine.num_text(e.spread), numeric = true)
			y^ += 34
			color_row(vg, n, fmt.tprintf("effect.%d.color", i), x, w, y^, e.color)
			y^ += 36
		case .Blur, .Background_Blur:
			field(vg, n.uid, fmt.tprintf("effect.%d.radius", i), "R", {x, y^, half, 28}, engine.num_text(e.blur), numeric = true)
			label(vg, x + half + 12, y^ + 14, "Kept; not drawn yet", TEXT_DIM, 11)
			y^ += 36
		}
	}
	divider(vg, x, w, y)
}

// ---------------------------------------------------------------- typography details

draw_typography_details :: proc(vg: ^nvg.Context, n: ^engine.Node, x, w: f32, y: ^f32) {
	half := (w - 8) / 2
	lh := "Auto" if n.line_height == 0 else engine.num_text(n.line_height)
	label(vg, x, y^ + 6, "Line height", TEXT_DIM, 11)
	label(vg, x + half + 8, y^ + 6, "Letter spacing", TEXT_DIM, 11)
	y^ += 16
	field(vg, n.uid, "lineHeight", "", {x, y^, half, 28}, lh, icon = .Font_Size, numeric = true)
	field(vg, n.uid, "letterSpacing", "", {x + half + 8, y^, half, 28}, engine.num_text(n.letter_spacing), icon = .Gap, numeric = true)
	y^ += 36
	h_icons := [4]string{"text-align-start", "text-align-center", "text-align-end", "text-align-justify"}
	h_names := [4]string{"left", "center", "right", "justify"}
	cur := int(n.text_align)
	if raw := engine.prop_string(n, "textAlign"); raw == "justify" do cur = 3
	if pick := segmented(vg, {x, y^, half + 30, 28}, h_icons[:], cur); pick >= 0 {
		push_undo()
		if pick == 0 do engine.node_unset(&app.doc, n, "textAlign")
		else do engine.node_set_string(&app.doc, n, "textAlign", h_names[pick])
	}
	v_icons := [3]string{"align-vertical-justify-start", "align-vertical-justify-center", "align-vertical-justify-end"}
	v_names := [3]string{"top", "middle", "bottom"}
	if pick := segmented(vg, {x + half + 38, y^, w - half - 38, 28}, v_icons[:], int(n.text_valign)); pick >= 0 {
		push_undo()
		if pick == 0 do engine.node_unset(&app.doc, n, "textAlignVertical")
		else do engine.node_set_string(&app.doc, n, "textAlignVertical", v_names[pick])
	}
	y^ += 36
	if checkbox(vg, {x, y^, half, 22}, "Underline", n.underline) do toggle_flag_undo(n, "underline", n.underline)
	if checkbox(vg, {x + half + 8, y^, half, 22}, "Strikethrough", n.strikethrough) do toggle_flag_undo(n, "strikethrough", n.strikethrough)
	y^ += 28
}

toggle_flag_undo :: proc(n: ^engine.Node, key: string, on: bool) {
	push_undo()
	toggle_flag(n, key, on)
}

// ---------------------------------------------------------------- context, export

draw_context_section :: proc(vg: ^nvg.Context, n: ^engine.Node, x, w: f32, y: ^f32) {
	section(vg, x, y, "Context")
	field(vg, n.uid, "context", "", {x, y^, w, 28}, engine.prop_string(n, "context"), placeholder = "Notes for agents: purpose, behaviour, data")
	y^ += 36
	divider(vg, x, w, y)
}

EXPORT_SCALES := [?]string{"1x", "2x", "3x", "4x", "0.5x"}
EXPORT_SCALE_VALUES := [?]f32{1, 2, 3, 4, 0.5}

draw_export_section :: proc(vg: ^nvg.Context, n: ^engine.Node, x, w: f32, y: ^f32) {
	half := (w - 8) / 2
	section(vg, x, y, "Export")
	if pick, ok := dropdown_menu(vg, "export.scale", {x, y^, half, 28}, EXPORT_SCALES[:], ui.export_scale); ok do ui.export_scale = pick
	formats := [4]string{"PNG", "JPEG", "WEBP", "PDF"}
	if pick, ok := dropdown_menu(vg, "export.format", {x + half + 8, y^, half, 28}, formats[:], ui.export_format); ok do ui.export_format = pick
	y^ += 34
	if button(vg, {x, y^, w, 28}, "Export layer") do export_layer(n, EXPORT_SCALE_VALUES[ui.export_scale], engine.Export_Format(ui.export_format))
	y^ += 36
	divider(vg, x, w, y)
}

// Writes the node at the given scale and format into ~/Downloads.
export_layer :: proc(n: ^engine.Node, scale: f32, format: engine.Export_Format) {
	name := engine.css_name(engine.node_label(n))
	suffix := "" if scale == 1 else fmt.tprintf("@%vx", scale)
	path := fmt.tprintf("%s/%s%s.%s", downloads_dir(), name, suffix, engine.EXPORT_EXTENSIONS[format])
	export_request(scale, path, format)
}

// ---------------------------------------------------------------- field keys

// Applies inspector-specific field keys; false when the key is not one of them.
inspector_field_apply :: proc(n: ^engine.Node, key, text: string) -> bool {
	t := strings.trim_space(text)
	if strings.has_prefix(key, "radius.") {
		f, ok := strconv.parse_f32(t)
		if !ok do return true
		r := n.radius
		switch key {
		case "radius.tl": r[0] = f
		case "radius.tr": r[1] = f
		case "radius.br": r[2] = f
		case "radius.bl": r[3] = f
		}
		arr := make(json.Array, 0, 4, context.temp_allocator)
		for v in r do append(&arr, engine.json_num(v))
		engine.node_set(&app.doc, n, "cornerRadius", arr)
		return true
	}
	if key == "rotation" {
		if f, ok := strconv.parse_f32(strings.trim_suffix(t, "°")); ok do transform_in_place(n, f, n.flip_x, n.flip_y)
		return true
	}
	if key == "lineHeight" {
		if t == "" || strings.equal_fold(t, "auto") || t == "0" do engine.node_unset(&app.doc, n, "lineHeight")
		else if f, ok := strconv.parse_f32(strings.trim_suffix(t, "%")); ok {
			if strings.has_suffix(t, "%") do f /= 100
			else if f > 4 do f /= n.font_size // a pixel value
			engine.node_set_number(&app.doc, n, "lineHeight", math.round(f * 1000) / 1000)
		}
		return true
	}
	if strings.has_prefix(key, "fill.") {
		parts := strings.split(key, ".", context.temp_allocator)
		i, _ := strconv.parse_int(parts[1])
		out := fill_items(n)
		if i >= len(out) do return true
		o := fill_object(out[i])
		f, fok := strconv.parse_f32(strings.trim_suffix(t, "%"))
		switch {
		case len(parts) == 3 && parts[2] == "rotation" && fok:
			o["rotation"] = engine.json_num(f)
		case len(parts) == 4 && parts[2] == "stoppos" && fok:
			// a typed position: the stops are re-sorted
			k, _ := strconv.parse_int(parts[3])
			colors, cok := o["colors"].(json.Array)
			if !cok || k >= len(colors) do return true
			stop_set_pos(colors[k], f / 100)
			slice.sort_by(colors[:], proc(a, b: json.Value) -> bool {return stop_pos(a) < stop_pos(b)})
			o["colors"] = colors
		case len(parts) == 3 && parts[2] == "size" && fok:
			s := make(json.Object, context.temp_allocator)
			s["width"] = engine.json_num(f / 100)
			s["height"] = engine.json_num(f / 100)
			o["size"] = s
		case:
			return true
		}
		out[i] = o
		fill_store(n, out)
		return true
	}
	if strings.has_prefix(key, "effect.") {
		parts := strings.split(key, ".", context.temp_allocator)
		if len(parts) != 3 do return true
		i, _ := strconv.parse_int(parts[1])
		out := effect_items(n)
		if i >= len(out) do return true
		o, _ := out[i].(json.Object)
		f, fok := strconv.parse_f32(t)
		if !fok && parts[2] != "color" do return true
		switch parts[2] {
		case "x", "y":
			off, _ := o["offset"].(json.Object)
			if off == nil do off = make(json.Object, context.temp_allocator)
			off[parts[2]] = engine.json_num(f)
			o["offset"] = off
		case "blur", "spread", "radius":
			o[parts[2]] = engine.json_num(f)
		case "color":
			hex := t if strings.has_prefix(t, "#") || strings.has_prefix(t, "$") else fmt.tprintf("#%s", t)
			o["color"] = json.String(hex)
		}
		out[i] = o
		effect_store(n, out)
		return true
	}
	return false
}

// A colour picked for one of the inspector's list keys.
inspector_color_set :: proc(n: ^engine.Node, key, value: string) -> bool {
	parts := strings.split(key, ".", context.temp_allocator)
	if parts[0] == "fill" && len(parts) >= 2 {
		i, _ := strconv.parse_int(parts[1])
		out := fill_items(n)
		if i >= len(out) do return true
		if len(parts) == 2 {
			o, is_obj := out[i].(json.Object)
			if is_obj && string(o["type"].(json.String) or_else "") == "color" {
				o["color"] = json.String(value)
				out[i] = o
			} else {
				out[i] = json.String(value)
			}
		} else if len(parts) == 4 && parts[2] == "stop" {
			k, _ := strconv.parse_int(parts[3])
			o := fill_object(out[i])
			colors, _ := o["colors"].(json.Array)
			if k < len(colors) {
				c, _ := colors[k].(json.Object)
				c["color"] = json.String(value)
				colors[k] = c
				o["colors"] = colors
				out[i] = o
			}
		}
		fill_store(n, out)
		return true
	}
	if parts[0] == "effect" && len(parts) == 3 && parts[2] == "color" {
		inspector_field_apply(n, key, value)
		return true
	}
	return false
}

// The label of a colour bound to a list key ("$var" when a variable is used).
inspector_color_label :: proc(n: ^engine.Node, key: string) -> (string, bool) {
	parts := strings.split(key, ".", context.temp_allocator)
	item: json.Value
	switch parts[0] {
	case "fill":
		if len(parts) < 2 do return "", false
		i, _ := strconv.parse_int(parts[1])
		items := fill_items(n)
		if i >= len(items) do return "", false
		item = items[i]
		if len(parts) == 4 {
			k, _ := strconv.parse_int(parts[3])
			colors, _ := fill_object(item)["colors"].(json.Array)
			if k >= len(colors) do return "", false
			item = (colors[k].(json.Object) or_else nil)["color"]
		} else if o, is_obj := item.(json.Object); is_obj {
			item = o["color"]
		}
	case "effect":
		if len(parts) != 3 do return "", false
		i, _ := strconv.parse_int(parts[1])
		items := effect_items(n)
		if i >= len(items) do return "", false
		item = (items[i].(json.Object) or_else nil)["color"]
	case:
		return "", false
	}
	if s, is_str := item.(json.String); is_str && strings.has_prefix(string(s), "$") do return string(s), true
	return "", true
}
