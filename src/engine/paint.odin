package engine

import "core:hash"
import "core:math"
import nvg "../nanovg"

// Fills and effects of a node. NanoVG paints two-colour gradients only, so gradients are
// drawn from small generated textures (any number of stops, linear, radial and angular)
// mapped onto the node with an image pattern. The geometry follows pen.dev (checked by
// rendering the same file there): linear 0° runs from the bottom (position 0) to the top
// (position 1) and rotation turns it counter-clockwise; radial fills an ellipse of
// size × box; angular starts at the top and goes clockwise.

gradient_images: map[u64]int

// The texture for a gradient (cached by kind and stops).
gradient_image :: proc(vg: ^nvg.Context, p: ^Paint) -> int {
	key_data: [MAX_STOPS * 8 + 1]u8
	key_data[0] = u8(p.kind)
	for i in 0 ..< p.nstops {
		s := p.stops[i]
		key_data[1 + i * 8 + 0] = s.color[0]
		key_data[1 + i * 8 + 1] = s.color[1]
		key_data[1 + i * 8 + 2] = s.color[2]
		key_data[1 + i * 8 + 3] = s.color[3]
		pos := u32(s.pos * 65535)
		key_data[1 + i * 8 + 4] = u8(pos)
		key_data[1 + i * 8 + 5] = u8(pos >> 8)
	}
	key := hash.fnv64a(key_data[:1 + p.nstops * 8])
	if img, ok := gradient_images[key]; ok do return img
	if len(gradient_images) > 128 {
		for _, img in gradient_images do nvg.DeleteImage(vg, img)
		clear(&gradient_images)
	}
	w, h := 256, 1
	if p.kind != .Linear do w, h = 256, 256
	pixels := make([]u8, w * h * 4, context.temp_allocator)
	for y in 0 ..< h {
		for x in 0 ..< w {
			t: f32
			switch p.kind {
			case .Linear, .Color, .Image:
				t = (f32(x) + 0.5) / f32(w)
			case .Radial:
				dx, dy := (f32(x) + 0.5) / f32(w) * 2 - 1, (f32(y) + 0.5) / f32(h) * 2 - 1
				t = math.sqrt(dx * dx + dy * dy)
			case .Angular:
				dx, dy := (f32(x) + 0.5) / f32(w) * 2 - 1, (f32(y) + 0.5) / f32(h) * 2 - 1
				// 0 at the top, increasing clockwise
				t = (math.atan2(dx, -dy) / (2 * math.PI))
				if t < 0 do t += 1
			}
			c := gradient_at(p, t)
			i := (y * w + x) * 4
			pixels[i + 0], pixels[i + 1], pixels[i + 2], pixels[i + 3] = c[0], c[1], c[2], c[3]
		}
	}
	img := nvg.CreateImageRGBA(vg, w, h, {}, pixels)
	gradient_images[key] = img
	return img
}

// Colour of a gradient at t (0..1), interpolated between its stops.
gradient_at :: proc(p: ^Paint, t: f32) -> Color {
	if p.nstops == 1 do return p.stops[0].color
	t := clamp(t, 0, 1)
	if t <= p.stops[0].pos do return p.stops[0].color
	for i in 1 ..< p.nstops {
		a, b := p.stops[i - 1], p.stops[i]
		if t <= b.pos {
			f := (t - a.pos) / max(b.pos - a.pos, 1e-6)
			out: Color
			for k in 0 ..< 4 do out[k] = u8(f32(a.color[k]) + (f32(b.color[k]) - f32(a.color[k])) * f + 0.5)
			return out
		}
	}
	return p.stops[p.nstops - 1].color
}

// Fills the current path with every enabled fill of the node, in order.
fill_paints :: proc(vg: ^nvg.Context, n: ^Node) {
	if n.nfills == 0 {
		if n.has_fill {
			nvg.FillColor(vg, to_nvg(n.fill))
			nvg.Fill(vg)
		}
		return
	}
	for i in 0 ..< n.nfills {
		p := &n.fills[i]
		if !p.enabled do continue
		switch p.kind {
		case .Color:
			nvg.FillColor(vg, to_nvg(p.color, p.opacity))
			nvg.Fill(vg)
		case .Image:
			if n.image_url != "" do image_fill(vg, n)
		case .Linear, .Radial, .Angular:
			nvg.FillPaint(vg, gradient_paint(vg, n, p))
			nvg.Fill(vg)
		}
	}
}

gradient_paint :: proc(vg: ^nvg.Context, n: ^Node, p: ^Paint) -> nvg.Paint {
	img := gradient_image(vg, p)
	cx, cy := n.x + p.center.x * n.w, n.y + p.center.y * n.h
	rad := p.rotation * math.PI / 180
	paint: nvg.Paint
	if p.kind == .Linear {
		// the gradient line in box-normalized space (0° = up, counter-clockwise), then
		// mapped onto the box
		dir := [2]f32{-math.sin(rad), -math.cos(rad)}
		a := p.center - dir * p.size.y / 2
		b := p.center + dir * p.size.y / 2
		start := [2]f32{n.x + a.x * n.w, n.y + a.y * n.h}
		end := [2]f32{n.x + b.x * n.w, n.y + b.y * n.h}
		d := end - start
		length := math.sqrt(d.x * d.x + d.y * d.y)
		paint = nvg.ImagePattern(start.x, start.y, max(length, 0.01), 1, math.atan2(d.y, d.x), img, 1)
	} else {
		rx, ry := p.size.x * n.w / 2, p.size.y * n.h / 2
		// the pattern rotates around its origin: rotate the ellipse's corner around the centre
		ox, oy := -rx, -ry
		c, s := math.cos(-rad), math.sin(-rad)
		paint = nvg.ImagePattern(cx + ox * c - oy * s, cy + ox * s + oy * c, max(rx * 2, 0.01), max(ry * 2, 0.01), -rad, img, 1)
	}
	paint.innerColor.a *= p.opacity
	paint.outerColor.a *= p.opacity
	return paint
}

// Drop shadows, drawn before the fills.
draw_drop_shadows :: proc(vg: ^nvg.Context, n: ^Node, radius: f32) {
	if n.neffects == 0 {
		if s := n.shadow; s.has && !s.inner do drop_shadow(vg, n, s.offset, s.blur, s.spread, s.color, radius)
		return
	}
	for i in 0 ..< n.neffects {
		e := n.effects[i]
		if e.enabled && e.kind == .Drop_Shadow do drop_shadow(vg, n, e.offset, e.blur, e.spread, e.color, radius)
	}
}

// Shadows follow CSS (pen.dev renders and exports them so): the blur fades the shadow
// over twice its value, centred on the edge of the offset, spread box. NanoVG's box
// gradient fades over `feather`, centred the same way.
drop_shadow :: proc(vg: ^nvg.Context, n: ^Node, offset: [2]f32, blur, spread: f32, color: Color, radius: f32) {
	x, y := n.x + offset.x - spread, n.y + offset.y - spread
	w, h := n.w + spread * 2, n.h + spread * 2
	feather := max(blur * 2, 0.5)
	paint := nvg.BoxGradient(x, y, w, h, clamp(radius + spread, 0, min(w, h) / 2), feather, to_nvg(color), nvg.Color{0, 0, 0, 0})
	nvg.BeginPath(vg)
	nvg.Rect(vg, x - feather, y - feather, w + feather * 2, h + feather * 2)
	nvg.FillPaint(vg, paint)
	nvg.Fill(vg)
}

// Inner shadows: the current path filled with a box gradient that is clear inside the
// shifted, shrunk box and the shadow colour towards the edges.
draw_inner_shadows :: proc(vg: ^nvg.Context, n: ^Node, radius: f32) {
	for i in 0 ..< n.neffects {
		e := n.effects[i]
		if !e.enabled || e.kind != .Inner_Shadow do continue
		feather := max(e.blur * 2, 0.5)
		x, y := n.x + e.offset.x + e.spread, n.y + e.offset.y + e.spread
		w, h := n.w - e.spread * 2, n.h - e.spread * 2
		paint := nvg.BoxGradient(x, y, w, h, clamp(radius - e.spread, 0, max(min(w, h), 0) / 2), feather, nvg.Color{0, 0, 0, 0}, to_nvg(e.color))
		nvg.FillPaint(vg, paint)
		nvg.Fill(vg)
	}
}
