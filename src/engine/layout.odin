package engine

import "core:hash"
import "core:math"
import "core:mem"
import "core:strings"
import nvg "../nanovg"

// Layout pass: computes the absolute box of every node from the authored
// positions, sizes and flex layout of the .pen tree. Two passes per subtree:
// `measure` finds intrinsic sizes bottom-up (text metrics, fit_content), then
// `arrange` hands out final boxes top-down (fill_container, alignment).

LINE_HEIGHT :: 1.2
MAX_DEPTH :: 32

// Layout depends on the document (its version moves with every change to a layer, the
// header or the tree) and on the fonts at hand. Nothing else changes boxes, so a frame
// with neither lays nothing out again: the main loop asks up to three times a frame.
layout_epoch: int // bumped when fonts change, or when code asks for a layout outright

layout_invalidate :: proc() {
	layout_epoch += 1
}

layout_document :: proc(doc: ^Document) {
	if doc.layout_version == doc.version && doc.layout_epoch == layout_epoch && doc.layout_done do return
	defer {
		doc.layout_version, doc.layout_epoch, doc.layout_done = doc.version, layout_epoch, true
	}
	ghosts_sync(doc)
	for uid in children_of(doc, 0) {
		n, _ := doc_find_uid(doc, uid)
		if n == nil do continue
		w, h := measure(doc, n, {-1, -1}, 0)
		arrange(doc, n, n.pos.x, n.pos.y, w, h, 0)
	}
}

// Intrinsic size of a node. `avail` is the space the parent offers on each
// axis, or -1 when the parent does not know yet (it fits its content).
measure_calls: int

measure :: proc(doc: ^Document, n: ^Node, avail: [2]f32, depth: int) -> (f32, f32) {
	measure_calls += 1
	if depth > MAX_DEPTH do return 0, 0
	own := [2]f32{-1, -1}
	specs := [2]Size_Spec{n.width, n.height}
	for i in 0 ..< 2 {
		switch specs[i].mode {
		case .Fixed:
			own[i] = specs[i].value
		case .Fill:
			if avail[i] >= 0 do own[i] = avail[i]
			else if specs[i].has_value do own[i] = specs[i].value
		case .Fit:
		}
	}
	content: [2]f32
	switch n.kind {
	case .Text:
		content = measure_text(n, own.x)
	case .Path:
		content = {n.view_box[2], n.view_box[3]}
	case .Icon:
		content = {24, 24}
	case .Ref:
		if root := ghost_root_of(doc, n.uid); root != nil {
			w, h := measure(doc, root, avail, depth + 1)
			content = {w, h}
		}
	case .Frame, .Group:
		content = measure_children(doc, n, own, depth)
	case .Rectangle, .Ellipse, .Other:
		content = {100, 100}
	}
	for i in 0 ..< 2 {
		if own[i] >= 0 do continue
		own[i] = content[i]
		// fit_content(n) / fill_container(n): the fallback applies when there is nothing to fit
		if content[i] <= 0 && specs[i].has_value do own[i] = specs[i].value
	}
	n.mw, n.mh = own.x, own.y
	return own.x, own.y
}

measure_children :: proc(doc: ^Document, n: ^Node, own: [2]f32, depth: int) -> [2]f32 {
	pad := n.padding
	inner := own
	if inner.x >= 0 do inner.x -= pad[1] + pad[3]
	if inner.y >= 0 do inner.y -= pad[0] + pad[2]

	if n.layout == .None {
		ext: [2]f32
		for cu in children_for_layout(doc, n.uid) {
			c, _ := doc_find_uid(doc, cu)
			if c == nil do continue
			cw, ch := measure(doc, c, inner, depth + 1)
			if !c.enabled do continue
			ext = {max(ext.x, c.pos.x + cw), max(ext.y, c.pos.y + ch)}
		}
		return ext
	}

	main := 0 if n.layout == .Horizontal else 1
	cross := 1 - main
	// As pen.dev sizes a container that fits its content: fill_container children add
	// nothing to it on that axis and then get what it has. Across the flow they take the
	// width (or height) the other children give it; along the flow they share what is
	// left, which is nothing. Its "Collapsed size" warning names the case where nothing is
	// left at all (lint: collapsed-size).
	// Measured in passes: children with their own size first; then, once the size
	// across the flow is known, those that fill it; then those that fill along the flow,
	// with their share of what is left, so that text inside them wraps (and grows) at the
	// width it will really get.
	kids := children_for_layout(doc, n.uid)
	sizes := make([][2]f32, len(kids), context.temp_allocator)
	counted := make([]bool, len(kids), context.temp_allocator) // adds to the size along the flow
	later: [dynamic]int // fill across the flow, which is not known yet
	later.allocator = context.temp_allocator
	fills: [dynamic]int // fill along the flow, which is known
	fills.allocator = context.temp_allocator
	used: f32
	count := 0
	for cu, i in kids {
		c, _ := doc_find_uid(doc, cu)
		if c == nil do continue
		flowing := c.enabled && !c.abs_pos
		spec := [2]Size_Spec{c.width, c.height}
		if flowing && spec[main].mode == .Fill && inner[main] >= 0 {
			append(&fills, i)
			count += 1
			continue
		}
		if flowing && spec[cross].mode == .Fill && inner[cross] < 0 {
			append(&later, i)
			continue
		}
		avail := inner
		if flowing && spec[main].mode == .Fill do avail[main] = 0 // in a container fitting its content
		cw, ch := measure(doc, c, avail, depth + 1)
		sizes[i] = {cw, ch}
		if flowing do sizes[i], _ = rotated_extent(cw, ch, c.rotation)
		if !flowing || spec[main].mode == .Fill do continue
		counted[i] = true
		used += sizes[i][main]
		count += 1
	}
	across := inner[cross]
	if across < 0 {
		// children filling along the flow have a size across it of their own: measure them
		// once with what is left so far (again below, once everything else is known)
		if len(fills) > 0 {
			share := max((inner[main] - used - n.gap * f32(max(count - 1, 0))) / f32(len(fills)), 0)
			for i in fills {
				c, _ := doc_find_uid(doc, kids[i])
				if ([2]Size_Spec{c.width, c.height})[cross].mode == .Fill do continue
				avail := inner
				avail[main] = share
				cw, ch := measure(doc, c, avail, depth + 1)
				sizes[i], _ = rotated_extent(cw, ch, c.rotation)
			}
		}
		across = 0
		for cu, i in kids {
			c, _ := doc_find_uid(doc, cu)
			if c == nil || !c.enabled || c.abs_pos do continue
			if ([2]Size_Spec{c.width, c.height})[cross].mode == .Fill do continue
			across = max(across, sizes[i][cross])
		}
	}
	for i in later {
		c, _ := doc_find_uid(doc, kids[i])
		avail := inner
		avail[cross] = across
		if ([2]Size_Spec{c.width, c.height})[main].mode == .Fill do avail[main] = 0
		cw, ch := measure(doc, c, avail, depth + 1)
		sizes[i], _ = rotated_extent(cw, ch, c.rotation)
		if ([2]Size_Spec{c.width, c.height})[main].mode == .Fill do continue
		counted[i] = true
		used += sizes[i][main]
		count += 1
	}
	if len(fills) > 0 {
		share := max((inner[main] - used - n.gap * f32(max(count - 1, 0))) / f32(len(fills)), 0)
		for i in fills {
			c, _ := doc_find_uid(doc, kids[i])
			avail := inner
			avail[main] = share
			if avail[cross] < 0 do avail[cross] = across
			cw, ch := measure(doc, c, avail, depth + 1)
			sizes[i], _ = rotated_extent(cw, ch, c.rotation)
			counted[i] = true
		}
	}
	sum: f32
	for ok, i in counted do if ok do sum += sizes[i][main]
	if count > 1 do sum += n.gap * f32(count - 1)
	out: [2]f32
	out[main] = sum
	out[cross] = across
	out.x += pad[1] + pad[3]
	out.y += pad[0] + pad[2]
	return out
}

// Assigns the final box and lays out the children inside it.
arrange :: proc(doc: ^Document, n: ^Node, x, y, w, h: f32, depth: int) {
	if depth > MAX_DEPTH {
		n.x, n.y, n.w, n.h = x, y, w, h
		return
	}
	// fill_container nodes were measured against a guess; remeasure the
	// subtree now that the final size is known
	w, h := w, h
	if n.kind != .Text && (w != n.mw || h != n.mh) {
		measure(doc, n, {w, h}, depth)
		// a height that fits the content follows the new measurement: a different
		// width changes how the text inside wraps
		if n.height.mode == .Fit do h = n.mh
	}
	n.x, n.y, n.w, n.h = x, y, w, h
	if n.kind == .Text && n.growth == .Fixed_Width && w != n.mw {
		size := measure_text(n, w)
		n.h = size.y
	}
	if n.kind == .Ref {
		if root := ghost_root_of(doc, n.uid); root != nil do arrange(doc, root, x, y, w, h, depth + 1)
		else do for cu in children_for_layout(doc, n.uid) {
			if c, _ := doc_find_uid(doc, cu); c != nil do arrange_absolute(doc, c, x, y, {w, h}, depth)
		}
		return
	}
	if n.kind != .Frame && n.kind != .Group do return

	pad := n.padding
	ix, iy := x + pad[3], y + pad[0]
	inner := [2]f32{w - pad[1] - pad[3], h - pad[0] - pad[2]}

	if n.layout == .None {
		for cu in children_for_layout(doc, n.uid) {
			if c, _ := doc_find_uid(doc, cu); c != nil do arrange_absolute(doc, c, x, y, inner, depth)
		}
		return
	}

	main := 0 if n.layout == .Horizontal else 1
	cross := 1 - main
	fixed_sum: f32
	fills, count := 0, 0
	for cu in children_for_layout(doc, n.uid) {
		c, _ := doc_find_uid(doc, cu)
		if c == nil || !c.enabled || c.abs_pos do continue
		specs := [2]Size_Spec{c.width, c.height}
		if specs[main].mode == .Fill do fills += 1
		else {
			ext, _ := rotated_extent(c.mw, c.mh, c.rotation)
			fixed_sum += ext[main]
		}
		count += 1
	}
	gap := n.gap
	remaining := inner[main] - fixed_sum - gap * f32(max(count - 1, 0))
	fill_size: f32 = max(remaining / f32(fills), 0) if fills > 0 else 0
	offset: f32
	if fills == 0 && remaining > 0 {
		switch n.justify {
		case .Start:
		case .Center: offset = remaining / 2
		case .End: offset = remaining
		case .Space_Between: if count > 1 do gap += remaining / f32(count - 1)
		case .Space_Around:
			offset = remaining / f32(2 * count)
			gap += remaining / f32(count)
		}
	}
	cursor := offset
	for cu in children_for_layout(doc, n.uid) {
		c, _ := doc_find_uid(doc, cu)
		if c == nil do continue
		if !c.enabled || c.abs_pos {
			arrange_absolute(doc, c, x, y, inner, depth)
			continue
		}
		specs := [2]Size_Spec{c.width, c.height}
		size := [2]f32{c.mw, c.mh}
		if specs[main].mode == .Fill do size[main] = fill_size
		if specs[cross].mode == .Fill do size[cross] = inner[cross]
		// the room it takes is its rotated box (a fill gets its share as its own size, as
		// in pen.dev, and then takes the room of that rotated)
		ext, off := rotated_extent(size.x, size.y, c.rotation)
		pos: [2]f32
		pos[main] = cursor
		free := inner[cross] - ext[cross]
		switch n.align {
		case .Start:
		case .Center: pos[cross] = free / 2
		case .End: pos[cross] = free
		}
		arrange(doc, c, ix + pos.x + off.x, iy + pos.y + off.y, size.x, size.y, depth + 1)
		took, _ := rotated_extent(c.w, c.h, c.rotation)
		cursor += took[main] + gap
	}
}

arrange_absolute :: proc(doc: ^Document, c: ^Node, px, py: f32, inner: [2]f32, depth: int) {
	cw := inner.x if c.width.mode == .Fill else c.mw
	ch := inner.y if c.height.mode == .Fill else c.mh
	arrange(doc, c, px + c.pos.x, py + c.pos.y, cw, ch, depth + 1)
}

// A rotated layer in a flex frame takes the room of its rotated box, as in pen.dev: the
// frame's flow, gaps, alignment and fit_content size use the box around the rotated
// layer, and the layer's own top-left (the corner it turns around) sits inside that box
// where the rotation puts it. `rotated_extent` gives the size of the box around a w × h
// layer turned by `deg` counter-clockwise, and the offset of its top-left corner from
// the box's top-left. A layer that is not rotated gets its own size and no offset.
rotated_extent :: proc(w, h, deg: f32) -> (size, offset: [2]f32) {
	if deg == 0 do return {w, h}, {}
	t := -deg * math.PI / 180 // as drawn: nvg.Rotate(-rotation) with y down
	cs, sn := math.cos(t), math.sin(t)
	a := [2]f32{w * cs, w * sn} // the top edge
	b := [2]f32{-h * sn, h * cs} // the left edge
	lo := [2]f32{min(0, a.x, b.x, a.x + b.x), min(0, a.y, b.y, a.y + b.y)}
	hi := [2]f32{max(0, a.x, b.x, a.x + b.x), max(0, a.y, b.y, a.y + b.y)}
	return hi - lo, -lo
}

// ---------------------------------------------------------------- instances

// Instances are expanded by ghosts_sync (doc.odin) into ghost copies of their
// component with the overrides applied; layout and drawing treat those like nodes.
// Kept for callers that need to know whether an instance resolves.
instance_component :: proc(doc: ^Document, inst: ^Node) -> ^Node {
	comp, _ := doc_find(doc, inst.ref)
	if comp == nil || comp.uid == inst.uid || is_descendant(doc, inst.uid, comp.uid) || is_descendant(doc, comp.uid, inst.uid) do return nil
	return comp
}

// ---------------------------------------------------------------- text

// Line height as a multiple of the font size. Without `lineHeight` the font's own
// ascender to descender applies, without its line gap, as in pen.dev; Inter gives 1.21.
line_height_of :: proc(n: ^Node) -> f32 {
	if n.line_height > 0 do return n.line_height
	face := font_face(n.font_family, n.weight, n.italic)
	if r, ok := line_ratio_cache[face]; ok do return r
	r := f32(LINE_HEIGHT)
	if renderer != nil {
		vg := renderer
		nvg.Save(vg)
		nvg.ResetTransform(vg)
		nvg.FontFace(vg, face)
		nvg.FontSize(vg, 100)
		// the font's ascender to descender, without its line gap, as pen.dev sets a line
		// (measured: Scto Grotesk A, 1000 units tall plus a 244 gap, takes 1.0; Inter 1.21,
		// Roboto 1.17, Merriweather 1.26)
		asc, desc, _ := nvg.TextMetrics(vg)
		nvg.Restore(vg)
		if asc - desc > 0 do r = (asc - desc) / 100
	}
	line_ratio_cache[strings.clone(face)] = r
	return r
}

line_ratio_cache: map[string]f32

// Where a line's glyphs start inside its line box: CSS-style half leading, so the
// glyphs sit centred in a line height bigger or smaller than the font's own.
half_leading :: proc(vg: ^nvg.Context, n: ^Node) -> f32 {
	asc, desc, _ := nvg.TextMetrics(vg)
	return (n.font_size * line_height_of(n) - (asc - desc)) / 2
}

set_font :: proc(vg: ^nvg.Context, n: ^Node) {
	nvg.FontFace(vg, font_face(n.font_family, n.weight, n.italic))
	nvg.FontSize(vg, n.font_size)
	nvg.TextAlign(vg, .LEFT, .TOP)
	nvg.TextLineHeight(vg, line_height_of(n))
	nvg.TextLetterSpacing(vg, n.letter_spacing)
}

// Text metrics are measured once at document scale and cached: the size, and the line
// breaks as byte ranges of the content. Drawing reuses the same breaks at any zoom, so
// wrapping never depends on the screen pixel grid.
Text_Metrics :: struct {
	size: [2]f32,
	rows: [][2]int,
}

text_cache: map[u64]Text_Metrics

text_key :: proc(n: ^Node, wrap_w: f32) -> u64 {
	face := font_face(n.font_family, n.weight, n.italic)
	key := hash.fnv64a(transmute([]u8)n.content)
	key = hash.fnv64a(transmute([]u8)face, key)
	nums := [4]f32{n.font_size, line_height_of(n), wrap_w if n.growth != .Auto else -1, n.letter_spacing}
	// (mem.slice_to_bytes: transmuting a []f32 to []u8 would keep the element count and
	// hash only the first number)
	return hash.fnv64a(mem.slice_to_bytes(nums[:]), key)
}

text_metrics :: proc(n: ^Node, wrap_w: f32) -> Text_Metrics {
	key := text_key(n, wrap_w)
	if m, hit := text_cache[key]; hit do return m
	m := measure_text_now(n, wrap_w)
	if len(text_cache) > 20000 {
		for _, old in text_cache do delete(old.rows)
		clear(&text_cache)
	}
	text_cache[key] = m
	return m
}

// Natural size of a text node; wraps at `wrap_w` when the text has a fixed width.
measure_text :: proc(n: ^Node, wrap_w: f32) -> [2]f32 {
	return text_metrics(n, wrap_w).size
}

// The lines of a text node as byte ranges of its content.
text_lines :: proc(n: ^Node, wrap_w: f32) -> [][2]int {
	return text_metrics(n, wrap_w).rows
}

text_measures: int

measure_text_now :: proc(n: ^Node, wrap_w: f32) -> (m: Text_Metrics) {
	text_measures += 1
	vg := renderer
	nvg.Save(vg)
	defer nvg.Restore(vg)
	nvg.ResetTransform(vg) // measure at document scale, whatever is being drawn
	set_font(vg, n)
	lh := n.font_size * line_height_of(n)
	rows := make([dynamic][2]int)
	content := n.content
	if n.growth == .Auto || wrap_w < 0 {
		w: f32
		pos := 0
		for {
			nl := strings.index_byte(content[pos:], '\n')
			end := len(content) if nl < 0 else pos + nl
			line := content[pos:end]
			// letter spacing follows every character, the last one too (CSS, pen.dev);
			// NanoVG only counts it between characters
			lw := nvg.TextBounds(vg, 0, 0, line)
			if line != "" do lw += n.letter_spacing
			w = max(w, lw)
			append(&rows, [2]int{pos, end})
			if nl < 0 do break
			pos = end + 1
		}
		m.size = {max(w, 2), f32(len(rows)) * lh}
		m.rows = rows[:]
		return
	}
	buf: [8]nvg.Text_Row
	buf_slice := buf[:]
	input := content
	for nrows, last in nvg.TextBreakLines(vg, &input, max(wrap_w, 1), &buf_slice) {
		base := len(content) - len(last)
		for row in buf[:nrows] do append(&rows, [2]int{base + row.start, base + row.end})
	}
	if len(rows) == 0 do append(&rows, [2]int{0, 0})
	m.size = {wrap_w, f32(len(rows)) * lh}
	m.rows = rows[:]
	return
}
