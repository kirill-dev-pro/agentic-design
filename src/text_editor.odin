package agentic_design

import "engine"

import "core:strings"
import "core:time"
import "core:unicode"
import "core:unicode/utf8"
import nvg "nanovg"

// Editing a text layer on the canvas: a caret and a selection placed by clicking and dragging
// (double click: a word, triple: everything), moved with the arrows (Option: by words,
// Command: to the line's ends or the text's), Shift to select; typing, Return for a new line,
// Delete, copy, cut, paste and select all. Esc or Command-Return ends. The edits of one
// session are one undo step. Rich text keeps its runs (engine.node_set_content).

ted: struct {
	caret, anchor: int, // byte offsets; anchor == caret: no selection
	want_x:        f32, // up and down keep this page x; -1 = from the caret
	dragging:      bool,
	changed:       bool, // an undo step was taken for this session
	clicks:        int,
	last_click:    time.Time,
	last_key:      time.Time, // the caret stays on while typing
}

// `at`: a page point to put the caret at (a double click); nil selects the whole text.
start_text_editing :: proc(uid: int, at: Maybe([2]f32) = nil) {
	app.editing = uid
	clear(&app.sel)
	append(&app.sel, uid)
	ted.changed, ted.dragging, ted.want_x = false, false, -1
	n, _ := engine.doc_find_uid(&app.doc, uid)
	if n == nil do return
	if p, ok := at.?; ok {
		ted.caret = engine.text_offset_at(n, p)
		ted.anchor = ted.caret
		// the double click that started editing also picks the word, as in pen.dev and Figma
		ted.anchor, ted.caret = word_around(n.content, ted.caret)
	} else {
		ted.anchor, ted.caret = 0, len(n.content)
	}
	ted.last_key = time.now()
}

finish_text_editing :: proc() {
	n, _ := engine.doc_find_uid(&app.doc, app.editing)
	if n != nil && strings.trim_space(n.content) == "" {
		engine.doc_delete(&app.doc, n.uid)
		prune_selection()
	}
	app.editing = 0
	ted.dragging = false
}

@(private = "file")
word_around :: proc(text: string, at: int) -> (a, b: int) {
	is_word :: proc(r: rune) -> bool {return unicode.is_letter(r) || unicode.is_digit(r) || r == '_'}
	a, b = at, at
	for a > 0 {
		r, size := utf8.decode_last_rune_in_string(text[:a])
		if !is_word(r) do break
		a -= size
	}
	for b < len(text) {
		r, size := utf8.decode_rune_in_string(text[b:])
		if !is_word(r) do break
		b += size
	}
	return
}

@(private = "file")
prev_rune :: proc(text: string, at: int) -> int {
	if at <= 0 do return 0
	_, size := utf8.decode_last_rune_in_string(text[:at])
	return at - size
}

@(private = "file")
next_rune :: proc(text: string, at: int) -> int {
	if at >= len(text) do return len(text)
	_, size := utf8.decode_rune_in_string(text[at:])
	return at + size
}

// The start of the word before `at` (Option-Left), the end of the word after (Option-Right).
@(private = "file")
word_left :: proc(text: string, at: int) -> int {
	i := at
	for i > 0 {
		r, size := utf8.decode_last_rune_in_string(text[:i])
		if unicode.is_letter(r) || unicode.is_digit(r) do break
		i -= size
	}
	for i > 0 {
		r, size := utf8.decode_last_rune_in_string(text[:i])
		if !(unicode.is_letter(r) || unicode.is_digit(r)) do break
		i -= size
	}
	return i
}

@(private = "file")
word_right :: proc(text: string, at: int) -> int {
	i := at
	for i < len(text) {
		r, size := utf8.decode_rune_in_string(text[i:])
		if unicode.is_letter(r) || unicode.is_digit(r) do break
		i += size
	}
	for i < len(text) {
		r, size := utf8.decode_rune_in_string(text[i:])
		if !(unicode.is_letter(r) || unicode.is_digit(r)) do break
		i += size
	}
	return i
}

// Replaces the selection (or inserts at the caret) and leaves the caret after it.
@(private = "file")
ted_replace :: proc(n: ^engine.Node, with: string) {
	a, b := min(ted.anchor, ted.caret), max(ted.anchor, ted.caret)
	a, b = clamp(a, 0, len(n.content)), clamp(b, 0, len(n.content))
	if a == b && with == "" do return
	if !ted.changed {
		push_undo() // the whole session is one step
		ted.changed = true
	}
	out := strings.concatenate({n.content[:a], with, n.content[b:]}, context.temp_allocator)
	engine.node_set_content(&app.doc, n, out)
	ted.caret, ted.anchor = a + len(with), a + len(with)
	ted.want_x = -1
	mark_dirty()
	app.needs_layout = true
}

// Moves the caret; with Shift the selection grows from the anchor.
@(private = "file")
ted_move :: proc(to: int, extend: bool) {
	ted.caret = to
	if !extend do ted.anchor = to
}

handle_text_editing :: proc(page: [2]f32, over_canvas: bool) {
	n, _ := engine.doc_find_uid(&app.doc, app.editing)
	if n == nil {
		app.editing = 0
		return
	}
	text := n.content
	ted.caret, ted.anchor = clamp(ted.caret, 0, len(text)), clamp(ted.anchor, 0, len(text))
	cmd, shift := mod_cmd(), mod_shift()
	alt := key_down(KEY_LEFT_ALT) || key_down(KEY_RIGHT_ALT)
	has_sel := ted.caret != ted.anchor

	// the pointer: click, double click (word), triple (everything), drag, Shift-click
	if over_canvas && mouse_pressed(MOUSE_BUTTON_LEFT) && point_in_node(n, page) && !key_down(KEY_SPACE) {
		now := time.now()
		if time.duration_seconds(time.diff(ted.last_click, now)) < 0.35 do ted.clicks += 1
		else do ted.clicks = 1
		ted.last_click = now
		at := engine.text_offset_at(n, page)
		switch {
		case ted.clicks == 2: ted.anchor, ted.caret = word_around(text, at)
		case ted.clicks >= 3: ted.anchor, ted.caret = 0, len(text)
		case shift: ted.caret = at
		case: ted.caret, ted.anchor = at, at
		}
		ted.dragging = ted.clicks == 1
		ted.want_x = -1
		ted.last_key = now
	}
	if ted.dragging {
		if mouse_down(MOUSE_BUTTON_LEFT) do ted.caret = engine.text_offset_at(n, page)
		else do ted.dragging = false
	}

	if key_pressed(KEY_ESCAPE) || (cmd && key_pressed(KEY_ENTER)) {
		finish_text_editing()
		return
	}
	typed := false
	if cmd {
		switch {
		case key_pressed(KEY_A): ted.anchor, ted.caret = 0, len(text)
		case key_pressed(KEY_C), key_pressed(KEY_X):
			if has_sel {
				a, b := min(ted.anchor, ted.caret), max(ted.anchor, ted.caret)
				platform_clipboard_set(text[a:b])
				if key_pressed(KEY_X) do ted_replace(n, "")
			}
		case key_pressed(KEY_V):
			ted_replace(n, platform_clipboard_get())
			typed = true
		case key_pressed(KEY_Z):
			// back to before this edit (and out of the editor)
			finish_text_editing()
			if shift do redo()
			else do undo()
			return
		case key_hit(KEY_LEFT), key_hit(KEY_RIGHT):
			rows := engine.text_row_boxes(n)
			r := rows[engine.text_row_of(rows, ted.caret)]
			ted_move(r.a if key_hit(KEY_LEFT) else r.b, shift)
		case key_hit(KEY_UP): ted_move(0, shift)
		case key_hit(KEY_DOWN): ted_move(len(text), shift)
		case key_hit(KEY_BACKSPACE):
			// to the start of the line
			if !has_sel {
				rows := engine.text_row_boxes(n)
				ted.anchor = rows[engine.text_row_of(rows, ted.caret)].a
			}
			ted_replace(n, "")
		}
	} else {
		if len(pf.chars) > 0 {
			b := strings.builder_make(context.temp_allocator)
			for ch in pf.chars do strings.write_rune(&b, ch)
			ted_replace(n, strings.to_string(b))
			typed = true
		}
		if key_hit(KEY_ENTER) || key_hit(KEY_KP_ENTER) {
			ted_replace(n, "\n")
			typed = true
		}
		text = n.content
		if key_hit(KEY_BACKSPACE) {
			if ted.caret == ted.anchor do ted.anchor = word_left(text, ted.caret) if alt else prev_rune(text, ted.caret)
			ted_replace(n, "")
			typed = true
		}
		if key_hit(KEY_DELETE) {
			if ted.caret == ted.anchor do ted.anchor = word_right(text, ted.caret) if alt else next_rune(text, ted.caret)
			ted_replace(n, "")
			typed = true
		}
		text = n.content
		if key_hit(KEY_LEFT) {
			if has_sel && !shift do ted_move(min(ted.anchor, ted.caret), false)
			else do ted_move(word_left(text, ted.caret) if alt else prev_rune(text, ted.caret), shift)
			ted.want_x = -1
		}
		if key_hit(KEY_RIGHT) {
			if has_sel && !shift do ted_move(max(ted.anchor, ted.caret), false)
			else do ted_move(word_right(text, ted.caret) if alt else next_rune(text, ted.caret), shift)
			ted.want_x = -1
		}
		if key_hit(KEY_UP) || key_hit(KEY_DOWN) {
			rows := engine.text_row_boxes(n)
			i := engine.text_row_of(rows, ted.caret)
			if ted.want_x < 0 do ted.want_x, _, _ = engine.text_caret_pos(n, ted.caret)
			j := i - 1 if key_hit(KEY_UP) else i + 1
			want := ted.want_x
			if j < 0 do ted_move(0, shift)
			else if j >= len(rows) do ted_move(len(text), shift)
			else do ted_move(engine.text_offset_in_row(n, rows[j], want), shift)
			ted.want_x = want
		}
		if key_hit(KEY_HOME) do ted_move(0, shift)
		if key_hit(KEY_END) do ted_move(len(text), shift)
	}
	any_key := false
	for k in pf.key_repeated do if k do any_key = true
	if typed || any_key do ted.last_key = time.now()
}

// The selection and the caret over the text being edited (screen space, after the canvas).
draw_text_editor :: proc(vg: ^nvg.Context) {
	if app.editing == 0 do return
	n, _ := engine.doc_find_uid(&app.doc, app.editing)
	if n == nil do return
	rows := engine.text_row_boxes(n)
	a, b := min(ted.anchor, ted.caret), max(ted.anchor, ted.caret)
	if a != b {
		nvg.BeginPath(vg)
		for r in rows {
			lo, hi := max(a, r.a), min(b, r.b)
			// a selection running past the row's end covers its newline too
			ends_past := b > r.b && hi == r.b
			if lo > hi || (lo == hi && !ends_past) do continue
			x0 := r.x + engine.text_span_width(n, r.a, lo)
			x1 := r.x + engine.text_span_width(n, r.a, hi) + (n.font_size * 0.3 if ends_past else 0)
			p0, p1 := to_screen({x0, r.y}), to_screen({x1, r.y + r.h})
			nvg.Rect(vg, p0.x, p0.y, p1.x - p0.x, p1.y - p0.y)
		}
		nvg.FillColor(vg, {ACCENT.r, ACCENT.g, ACCENT.b, 0.3})
		nvg.Fill(vg)
	}
	blink_on := int(time.now()._nsec / 500_000_000) % 2 == 0 || time.duration_seconds(time.since(ted.last_key)) < 0.6
	if a == b && blink_on {
		x, y, h := engine.text_caret_pos(n, ted.caret)
		p := to_screen({x, y})
		nvg.BeginPath(vg)
		nvg.Rect(vg, p.x - 0.75, p.y, 1.5, h * app.zoom)
		nvg.FillColor(vg, ACCENT)
		nvg.Fill(vg)
	}
}
