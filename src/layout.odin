package agentic_design

import "core:hash"
import "core:mem"
import "core:strings"
import nvg "nanovg"

// Layout pass: computes the absolute box of every node from the authored
// positions, sizes and flex layout of the .pen tree. Two passes per subtree:
// `measure` finds intrinsic sizes bottom-up (text metrics, fit_content), then
// `arrange` hands out final boxes top-down (fill_container, alignment).

LINE_HEIGHT :: 1.2
MAX_DEPTH :: 32

layout_document :: proc(doc: ^Document) {
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
	if n.kind == .Frame || n.kind == .Group {
		// a container that fits its content but holds fill_container children
		// stretches to the space it is offered on that axis (across its own flow)
		for cu in children_for_layout(doc, n.uid) {
			c, _ := doc_find_uid(doc, cu)
			if c == nil || !c.enabled || c.abs_pos do continue
			if own.x < 0 && avail.x >= 0 && n.layout != .Horizontal && c.width.mode == .Fill do own.x = avail.x
			if own.y < 0 && avail.y >= 0 && n.layout != .Vertical && c.height.mode == .Fill do own.y = avail.y
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
	// Two passes: children with their own size along the flow first, then the
	// fill_container ones with their share of what is left, so that text inside them
	// wraps (and grows) at the width they will really get.
	kids := children_for_layout(doc, n.uid)
	sizes := make([][2]f32, len(kids), context.temp_allocator)
	fills: [dynamic]int
	fills.allocator = context.temp_allocator
	used: f32
	count := 0
	for cu, i in kids {
		c, _ := doc_find_uid(doc, cu)
		if c == nil do continue
		flowing := c.enabled && !c.abs_pos
		if flowing && ([2]Size_Spec{c.width, c.height})[main].mode == .Fill && inner[main] >= 0 {
			append(&fills, i)
			count += 1
			continue
		}
		cw, ch := measure(doc, c, inner, depth + 1)
		sizes[i] = {cw, ch}
		if !flowing do continue
		used += sizes[i][main]
		count += 1
	}
	if len(fills) > 0 {
		share := max((inner[main] - used - n.gap * f32(max(count - 1, 0))) / f32(len(fills)), 0)
		for i in fills {
			c, _ := doc_find_uid(doc, kids[i])
			avail := inner
			avail[main] = share
			cw, ch := measure(doc, c, avail, depth + 1)
			sizes[i] = {cw, ch}
		}
	}
	sum, biggest: f32
	for cu, i in kids {
		c, _ := doc_find_uid(doc, cu)
		if c == nil || !c.enabled || c.abs_pos do continue
		sum += sizes[i][main]
		biggest = max(biggest, sizes[i][cross])
	}
	if count > 1 do sum += n.gap * f32(count - 1)
	out: [2]f32
	out[main] = sum
	out[cross] = biggest
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
		else do fixed_sum += ([2]f32{c.mw, c.mh})[main]
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
		pos: [2]f32
		pos[main] = cursor
		free := inner[cross] - size[cross]
		switch n.align {
		case .Start:
		case .Center: pos[cross] = free / 2
		case .End: pos[cross] = free
		}
		arrange(doc, c, ix + pos.x, iy + pos.y, size.x, size.y, depth + 1)
		cursor += ([2]f32{c.w, c.h})[main] + gap
	}
}

arrange_absolute :: proc(doc: ^Document, c: ^Node, px, py: f32, inner: [2]f32, depth: int) {
	cw := inner.x if c.width.mode == .Fill else c.mw
	ch := inner.y if c.height.mode == .Fill else c.mh
	arrange(doc, c, px + c.pos.x, py + c.pos.y, cw, ch, depth + 1)
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
// line spacing applies ((ascender - descender + line gap) / em, like CSS "normal" and
// pen.dev); Inter gives 1.21.
line_height_of :: proc(n: ^Node) -> f32 {
	if n.line_height > 0 do return n.line_height
	face := font_face(n.font_family, n.weight, n.italic, n.font_size)
	if r, ok := line_ratio_cache[face]; ok do return r
	r := f32(LINE_HEIGHT)
	if app.vg != nil {
		vg := app.vg
		nvg.Save(vg)
		nvg.ResetTransform(vg)
		nvg.FontFace(vg, face)
		nvg.FontSize(vg, 100)
		_, _, lh := nvg.TextMetrics(vg)
		nvg.Restore(vg)
		if lh > 0 do r = lh / 100
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
	nvg.FontFace(vg, font_face(n.font_family, n.weight, n.italic, n.font_size))
	nvg.FontSize(vg, n.font_size)
	nvg.TextAlign(vg, .LEFT, .TOP)
	nvg.TextLineHeight(vg, line_height_of(n))
	nvg.TextLetterSpacing(vg, n.letter_spacing + system_tracking(n))
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
	face := font_face(n.font_family, n.weight, n.italic, n.font_size)
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
	vg := app.vg
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
