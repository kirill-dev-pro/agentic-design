#+build !js
package agentic_design

import "engine"

import "core:crypto"
import "core:encoding/hex"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import nvg "nanovg"

// Marks for the agent (decision 88, agent-context.pen frames 5-7): a comment pinned to a
// point, a pen stroke, an arrow, an area and a numbered tag on a layer. They live on top of
// the canvas, in page coordinates, never in the .pen. The next request takes them: a list
// that names the layers each mark is on, and a picture of the view with the marks drawn;
// then they leave the canvas.

Mark_Tool :: enum {
	Comment,
	Pen,
	Arrow,
	Area,
	Tag,
}

MARK_TOOL_NAMES := [Mark_Tool]string {
	.Comment = "Comment",
	.Pen     = "Pen",
	.Arrow   = "Arrow",
	.Area    = "Area",
	.Tag     = "Tag",
}

MARK_TOOL_ICONS := [Mark_Tool]string {
	.Comment = "message-circle",
	.Pen     = "pencil",
	.Arrow   = "move-up-right",
	.Area    = "square-dashed",
	.Tag     = "hash",
}

MARK_COLORS := [3]nvg.Color{{1, 0.3, 0.5, 1}, {0.05, 0.6, 1, 1}, {0.2, 0.8, 0.45, 1}}

Mark :: struct {
	tool:  Mark_Tool,
	pts:   [dynamic][2]f32, // page coordinates: a point, a stroke, two ends, two corners
	text:  string, // a comment
	uid:   int, // a tag's layer
	num:   int, // a tag's number
	color: nvg.Color,
}

annot: struct {
	active:  bool, // the marks toolbar is open; the canvas draws marks instead of selecting
	tool:    Mark_Tool,
	color:   int,
	marks:   [dynamic]Mark,
	drawing: int, // the mark being drawn with the pointer, -1 none
	editing: int, // the comment whose text is being typed, -1 none
}

@(init)
annot_init :: proc "contextless" () {
	annot.drawing, annot.editing = -1, -1
}

annotations_active :: proc() -> bool {
	return annot.active && app.tab >= 0
}

annotations_count :: proc() -> int {
	return len(annot.marks)
}

annotations_clear :: proc() {
	for &m in annot.marks {
		delete(m.pts)
		delete(m.text)
	}
	clear(&annot.marks)
	annot.drawing, annot.editing = -1, -1
	if ui.focus == "mark.comment" do ui.focus = ""
}

@(private = "file")
next_tag :: proc() -> int {
	n := 0
	for m in annot.marks do if m.tool == .Tag do n = max(n, m.num)
	return n + 1
}

// The canvas's pointer while the marks toolbar is open (handle_input). True when it took it.
annotate_input :: proc(over_canvas: bool, page: [2]f32) -> bool {
	if !annotations_active() do return false
	if key_pressed(KEY_ESCAPE) && ui.focus == "" {
		annot.active = false
		return true
	}
	color := MARK_COLORS[annot.color]
	if annot.drawing >= 0 {
		m := &annot.marks[annot.drawing]
		if mouse_down(MOUSE_BUTTON_LEFT) {
			switch m.tool {
			case .Pen:
				last := m.pts[len(m.pts) - 1]
				if linalg_len((page - last) * app.zoom) > 2 do append(&m.pts, page)
			case .Arrow, .Area:
				m.pts[1] = page
			case .Comment, .Tag:
			}
		} else {
			// a stroke or a box too small to mean anything goes
			small := false
			switch m.tool {
			case .Pen: small = len(m.pts) < 3
			case .Arrow, .Area: small = linalg_len((m.pts[1] - m.pts[0]) * app.zoom) < 6
			case .Comment, .Tag:
			}
			if small {
				delete(m.pts)
				ordered_remove(&annot.marks, annot.drawing)
			}
			annot.drawing = -1
		}
		return true
	}
	if !over_canvas || !mouse_pressed(MOUSE_BUTTON_LEFT) do return over_canvas
	if ui.focus == "mark.comment" do field_commit()
	switch annot.tool {
	case .Comment:
		m := Mark{tool = .Comment, color = color}
		append(&m.pts, page)
		append(&annot.marks, m)
		annot.editing = len(annot.marks) - 1
		field_focus(0, "mark.comment", "")
	case .Pen:
		m := Mark{tool = .Pen, color = color}
		append(&m.pts, page)
		append(&annot.marks, m)
		annot.drawing = len(annot.marks) - 1
	case .Arrow, .Area:
		m := Mark{tool = annot.tool, color = color}
		append(&m.pts, page, page)
		append(&annot.marks, m)
		annot.drawing = len(annot.marks) - 1
	case .Tag:
		uid := click_target(hit_test(page), true)
		if uid == 0 do uid = hit_test(page) // a top-level frame's own body
		if uid == 0 do return true
		for m in annot.marks do if m.tool == .Tag && m.uid == uid do return true // one tag a layer
		m := Mark{tool = .Tag, color = color, uid = uid, num = next_tag()}
		append(&m.pts, page)
		append(&annot.marks, m)
	}
	return true
}

@(private = "file")
linalg_len :: proc(v: [2]f32) -> f32 {
	return math.sqrt(v.x * v.x + v.y * v.y)
}

// Draws the marks with `to` mapping page to drawing coordinates and `s` the drawing units of
// one screen point (1 on the canvas, the render's scale for the agent's picture).
@(private = "file")
draw_marks :: proc(vg: ^nvg.Context, to: proc(p: [2]f32) -> [2]f32, s: f32) {
	for m, mi in annot.marks {
		c := m.color
		switch m.tool {
		case .Pen:
			if len(m.pts) < 2 do continue
			nvg.BeginPath(vg)
			p0 := to(m.pts[0])
			nvg.MoveTo(vg, p0.x, p0.y)
			for p in m.pts[1:] {
				q := to(p)
				nvg.LineTo(vg, q.x, q.y)
			}
			nvg.StrokeColor(vg, c)
			nvg.StrokeWidth(vg, 3 * s)
			nvg.LineCap(vg, .ROUND)
			nvg.LineJoin(vg, .ROUND)
			nvg.Stroke(vg)
		case .Arrow:
			a, b := to(m.pts[0]), to(m.pts[1])
			d := b - a
			l := linalg_len(d)
			if l < 1 do continue
			u := d / l
			nvg.BeginPath(vg)
			nvg.MoveTo(vg, a.x, a.y)
			nvg.LineTo(vg, b.x, b.y)
			nvg.StrokeColor(vg, c)
			nvg.StrokeWidth(vg, 3 * s)
			nvg.LineCap(vg, .ROUND)
			nvg.Stroke(vg)
			h := 12 * s
			nrm := [2]f32{-u.y, u.x}
			nvg.BeginPath(vg)
			nvg.MoveTo(vg, b.x, b.y)
			l1 := b - u * h + nrm * h * 0.55
			l2 := b - u * h - nrm * h * 0.55
			nvg.LineTo(vg, l1.x, l1.y)
			nvg.LineTo(vg, l2.x, l2.y)
			nvg.ClosePath(vg)
			nvg.FillColor(vg, c)
			nvg.Fill(vg)
		case .Area:
			a, b := to(m.pts[0]), to(m.pts[1])
			x, y := min(a.x, b.x), min(a.y, b.y)
			w, h := abs(b.x - a.x), abs(b.y - a.y)
			nvg.BeginPath(vg)
			nvg.RoundedRect(vg, x, y, w, h, 4 * s)
			nvg.FillColor(vg, {c.r, c.g, c.b, 0.12})
			nvg.Fill(vg)
			nvg.StrokeColor(vg, c)
			nvg.StrokeWidth(vg, 2 * s)
			nvg.Stroke(vg)
		case .Comment:
			if mi == annot.editing && s == 1 do continue // drawn with its caret by draw_annotations
			draw_comment(vg, to(m.pts[0]), c, m.text, s, -1)
		case .Tag:
			n, _ := engine.doc_find_uid(&app.doc, m.uid)
			if n == nil do continue
			box := engine.node_page_box(n)
			a := to({box[0], box[1]})
			b := to({box[0] + box[2], box[1] + box[3]})
			nvg.BeginPath(vg)
			nvg.Rect(vg, a.x, a.y, b.x - a.x, b.y - a.y)
			nvg.StrokeColor(vg, {c.r, c.g, c.b, 0.8})
			nvg.StrokeWidth(vg, 1.5 * s)
			nvg.Stroke(vg)
			nvg.BeginPath(vg)
			nvg.Circle(vg, a.x - 2 * s, a.y - 2 * s, 10 * s)
			nvg.FillColor(vg, c)
			nvg.Fill(vg)
			nvg.FontFace(vg, "ui")
			nvg.FontSize(vg, 12 * s)
			nvg.TextAlign(vg, .CENTER, .MIDDLE)
			nvg.FillColor(vg, {1, 1, 1, 1})
			nvg.Text(vg, a.x - 2 * s, a.y - 2 * s, fmt.tprintf("%d", m.num))
		}
	}
}

// On the canvas (draw_canvas), with the comment being typed.
draw_annotations :: proc(vg: ^nvg.Context) {
	if app.tab < 0 || len(annot.marks) == 0 do return
	draw_marks(vg, to_screen, 1)
	if annot.editing >= 0 && annot.editing < len(annot.marks) {
		m := &annot.marks[annot.editing]
		focused := field_is_focused(0, "mark.comment")
		if focused {
			// the keys go to the field's editing (widgets.odin); the card shows the text
			index := ui.field_count
			ui.field_count += 1
			if !ui.input_claimed {
				ui.input_claimed = true
				field_keys(index, false)
			}
			s := strings.to_string(ui.buf)
			if s != m.text {
				delete(m.text)
				m.text = strings.clone(s)
			}
			card := draw_comment(vg, to_screen(m.pts[0]), m.color, m.text, 1, clamp(ui.caret, 0, len(m.text)))
			ui.focus_rect = {card.x + ui.origin.x, card.y + ui.origin.y, card.w, card.h} // a click outside ends typing
		} else {
			// done typing: an empty comment goes
			if m.text == "" {
				delete(m.pts)
				ordered_remove(&annot.marks, annot.editing)
			}
			annot.editing = -1
		}
	}
}

// A comment mark as in app-ui.pen ("5 · Annotate mode"): a pin whose tip is the point, and
// beside it a card 210 wide (who, then the text wrapped to the card). `caret` >= 0: being
// typed, with the caret there and a placeholder while empty. `s` scales it (pictures).
COMMENT_W :: 210
draw_comment :: proc(vg: ^nvg.Context, p: [2]f32, color: nvg.Color, text: string, s: f32, caret: int) -> (card: Rect) {
	// the pin: 28 × 28, its tip at the point
	o := p - {14 * s, 28 * s}
	nvg.BeginPath(vg)
	nvg.MoveTo(vg, o.x + 14 * s, o.y + 28 * s)
	nvg.LineTo(vg, o.x + 5 * s, o.y + 18 * s)
	nvg.Arc(vg, o.x + 14 * s, o.y + 12 * s, 10.8 * s, math.to_radians(f32(146)), math.to_radians(f32(34)), .CW)
	nvg.ClosePath(vg)
	nvg.FillColor(vg, color)
	nvg.Fill(vg)
	nvg.StrokeColor(vg, {1, 1, 1, 1})
	nvg.StrokeWidth(vg, 2 * s)
	nvg.Stroke(vg)
	nvg.BeginPath(vg)
	nvg.Circle(vg, o.x + 14 * s, o.y + 12 * s, 5 * s)
	nvg.FillColor(vg, {1, 1, 1, 1})
	nvg.Fill(vg)
	if text == "" && caret < 0 do return

	// the card
	pad_x, pad_y := 12 * s, 8 * s
	inner := (COMMENT_W - 24) * s
	nvg.FontFace(vg, "ui")
	nvg.FontSize(vg, 12.5 * s)
	nvg.TextLineHeight(vg, 1.35)
	nvg.TextLetterSpacing(vg, 0)
	shown := text if text != "" else "What should the agent know here?"
	rows := text_rows(vg, shown, inner)
	lh := 12.5 * 1.35 * s
	h := pad_y * 2 + 16 * s + 2 * s + f32(len(rows)) * lh
	r := Rect{o.x + 34 * s, o.y - 4 * s, COMMENT_W * s, h}
	card = r
	shadow := nvg.BoxGradient(r.x, r.y + 6 * s, r.w, r.h, 10 * s, 20 * s, {0, 0, 0, 0.45}, {0, 0, 0, 0})
	nvg.BeginPath(vg)
	nvg.Rect(vg, r.x - 30 * s, r.y - 24 * s, r.w + 60 * s, r.h + 60 * s)
	nvg.FillPaint(vg, shadow)
	nvg.Fill(vg)
	nvg.BeginPath(vg)
	nvg.RoundedRect(vg, r.x, r.y, r.w, r.h, 10 * s)
	nvg.FillColor(vg, {0x30 / 255.0, 0x30 / 255.0, 0x30 / 255.0, 1})
	nvg.Fill(vg)
	nvg.BeginPath(vg)
	nvg.RoundedRect(vg, r.x + 0.75 * s, r.y + 0.75 * s, r.w - 1.5 * s, r.h - 1.5 * s, 9.25 * s)
	nvg.StrokeColor(vg, color)
	nvg.StrokeWidth(vg, 1.5 * s)
	nvg.Stroke(vg)
	// who
	ax, ay := r.x + pad_x + 8 * s, r.y + pad_y + 8 * s
	nvg.BeginPath(vg)
	nvg.Circle(vg, ax, ay, 8 * s)
	nvg.FillColor(vg, {0x7C / 255.0, 0x5C / 255.0, 1, 1})
	nvg.Fill(vg)
	nvg.FontSize(vg, 9 * s)
	nvg.TextAlign(vg, .CENTER, .MIDDLE)
	nvg.FillColor(vg, {1, 1, 1, 1})
	nvg.Text(vg, ax, ay + 0.5 * s, comment_initial())
	nvg.FontSize(vg, 11 * s)
	nvg.TextAlign(vg, .LEFT, .MIDDLE)
	nvg.FillColor(vg, {0x8F / 255.0, 0x8F / 255.0, 0x8F / 255.0, 1})
	nvg.Text(vg, ax + 14 * s, ay, "Comment")
	// the text, wrapped
	nvg.FontSize(vg, 12.5 * s)
	nvg.TextAlign(vg, .LEFT, .TOP)
	ty := r.y + pad_y + 18 * s
	nvg.FillColor(vg, {0xE8 / 255.0, 0xE8 / 255.0, 0xE8 / 255.0, 1} if text != "" else {0x8F / 255.0, 0x8F / 255.0, 0x8F / 255.0, 1})
	for row, i in rows {
		nvg.Text(vg, r.x + pad_x, ty + f32(i) * lh + (lh - 12.5 * s) / 2, shown[row[0]:row[1]])
	}
	if caret >= 0 && (int(time.now()._nsec / 500_000_000) % 2 == 0) {
		at := caret if text != "" else 0
		ri := 0
		for row, i in rows do if row[0] <= at do ri = i
		cx := r.x + pad_x
		if text != "" do cx += nvg.TextBounds(vg, 0, 0, shown[rows[ri][0]:clamp(at, rows[ri][0], rows[ri][1])])
		nvg.BeginPath(vg)
		nvg.Rect(vg, cx, ty + f32(ri) * lh + 1 * s, 1.5 * s, lh - 2 * s)
		nvg.FillColor(vg, {1, 1, 1, 1})
		nvg.Fill(vg)
	}
	return
}

// The letter in the comment's avatar: the cloud account's name, else this Mac's user.
@(private = "file")
comment_initial :: proc() -> string {
	name := cloud_text(&cloud.name)
	if name == "" do name = os.get_env("USER", context.temp_allocator)
	if name == "" do return "?"
	_, size := utf8.decode_rune_in_string(name)
	return strings.to_upper(name[:size], context.temp_allocator)
}

// ---------------------------------------------------------------- what the agent gets

@(private = "file")
layer_name :: proc(n: ^engine.Node) -> string {
	name := n.name if n.name != "" else fmt.tprintf("%v", n.kind)
	return fmt.tprintf("\"%s\" (id %s)", name, n.id)
}

// The layer under a point: the deepest one drawn there.
@(private = "file")
layer_at :: proc(p: [2]f32) -> ^engine.Node {
	uid := click_target(hit_test(p), true)
	if uid == 0 do return nil
	n, _ := engine.doc_find_uid(&app.doc, uid)
	return n
}

// Layers inside a box (the smallest few), or the one that holds it.
@(private = "file")
layers_in :: proc(b: [4]f32) -> string {
	inside := make([dynamic]^engine.Node, context.temp_allocator)
	holder: ^engine.Node
	for &n in app.doc.nodes {
		if !n.enabled || app.page_hidden[top_of(&n)] do continue
		r := engine.node_page_box(&n)
		if r[2] <= 0 || r[3] <= 0 do continue
		if r[0] >= b[0] && r[1] >= b[1] && r[0] + r[2] <= b[0] + b[2] && r[1] + r[3] <= b[1] + b[3] {
			append(&inside, &n)
		} else if r[0] <= b[0] && r[1] <= b[1] && r[0] + r[2] >= b[0] + b[2] && r[1] + r[3] >= b[1] + b[3] {
			if holder == nil || r[2] * r[3] < engine.node_page_box(holder)[2] * engine.node_page_box(holder)[3] do holder = &n
		}
	}
	if len(inside) == 0 {
		if holder != nil do return fmt.tprintf("inside %s", layer_name(holder))
		return "on empty canvas"
	}
	// the outermost ones first: a layer whose parent is also inside is left out
	in_set := make(map[int]bool, len(inside), context.temp_allocator)
	for n in inside do in_set[n.uid] = true
	names := make([dynamic]string, context.temp_allocator)
	for n in inside {
		if in_set[n.parent] do continue
		append(&names, layer_name(n))
		if len(names) == 8 do break
	}
	return fmt.tprintf("around %s", strings.join(names[:], ", ", context.temp_allocator))
}

@(private = "file")
on_layer :: proc(n: ^engine.Node) -> string {
	if n == nil do return ""
	return fmt.tprintf(" on %s", layer_name(n))
}

@(private = "file")
top_of :: proc(n: ^engine.Node) -> int {
	cur := n
	for cur.parent != 0 {
		p, _ := engine.doc_find_uid(&app.doc, cur.parent)
		if p == nil do break
		cur = p
	}
	return cur.uid
}

@(private = "file")
bounds_of_pts :: proc(pts: [][2]f32) -> [4]f32 {
	lo, hi := pts[0], pts[0]
	for p in pts {
		lo = {min(lo.x, p.x), min(lo.y, p.y)}
		hi = {max(hi.x, p.x), max(hi.y, p.y)}
	}
	return {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y}
}

@(private = "file")
num :: proc(v: f32) -> string {
	return engine.num_text(math.round(v))
}

@(private = "file")
page_identity :: proc(p: [2]f32) -> [2]f32 {
	return p
}

@(private = "file")
overlay_marks :: proc(vg: ^nvg.Context, s: f32) {
	draw_marks(vg, page_identity, 1 / s)
}

// Takes the marks for a request: a description, the path of a picture of the view with the
// marks drawn, and how many there were; the canvas is left without them.
annotations_take :: proc(dir: string) -> (text: string, image: string, count: int) {
	if len(annot.marks) == 0 || app.tab < 0 do return "", "", 0
	if ui.focus == "mark.comment" do field_commit()
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "The user drew marks on the canvas to show what they mean (page coordinates; the marks are not part of the design):")
	for m, i in annot.marks {
		fmt.sbprintf(&b, "\n%d. ", i + 1)
		switch m.tool {
		case .Comment:
			n := layer_at(m.pts[0])
			fmt.sbprintf(&b, "Comment at (%s, %s)%s: \"%s\"", num(m.pts[0].x), num(m.pts[0].y), on_layer(n), m.text)
		case .Pen:
			r := bounds_of_pts(m.pts[:])
			closed := linalg_len(m.pts[0] - m.pts[len(m.pts) - 1]) < max(r[2], r[3]) * 0.25
			fmt.sbprintf(&b, "Pen stroke %s the area (%s, %s, %s × %s), %s", "circling" if closed else "drawn over", num(r[0]), num(r[1]), num(r[2]), num(r[3]), layers_in(r))
		case .Arrow:
			a, z := layer_at(m.pts[0]), layer_at(m.pts[1])
			fmt.sbprintf(&b, "Arrow from (%s, %s)%s to (%s, %s)%s", num(m.pts[0].x), num(m.pts[0].y), on_layer(a), num(m.pts[1].x), num(m.pts[1].y), on_layer(z))
		case .Area:
			r := bounds_of_pts(m.pts[:])
			fmt.sbprintf(&b, "Area (%s, %s, %s × %s), %s", num(r[0]), num(r[1]), num(r[2]), num(r[3]), layers_in(r))
		case .Tag:
			n, _ := engine.doc_find_uid(&app.doc, m.uid)
			if n != nil do fmt.sbprintf(&b, "Tag %d on %s (the user may say \"%d\")", m.num, layer_name(n), m.num)
		}
	}
	count = len(annot.marks)

	// the picture: the part of the canvas in view, with the marks
	v := canvas_visible()
	a, z := to_page({v.x, v.y}), to_page({v.x + v.w, v.y + v.h})
	region := [4]f32{a.x, a.y, z.x - a.x, z.y - a.y}
	scale := clamp(1.5 * app.zoom, 0.05, 4)
	render_overlay = overlay_marks
	defer render_overlay = nil
	if pixels, w, h, ok := render_region(region, scale, nil, app.canvas_bg); ok {
		if png, pok := engine.png_encode(pixels, w, h); pok {
			tmp := os.get_env("TMPDIR", context.temp_allocator)
			if tmp == "" do tmp = "/tmp"
			mdir := fmt.tprintf("%s/agentic-design-marks", strings.trim_right(tmp, "/"))
			_ = fs_mkdir_all(mdir)
			raw: [6]u8
			crypto.rand_bytes(raw[:])
			path := fmt.tprintf("%s/marks-%s.png", mdir, hex.encode(raw[:], context.temp_allocator))
			if fs_write(path, png) == nil {
				image = path
				fmt.sbprintf(&b, "\nA picture of the view with these marks: %s (it shows the area (%s, %s, %s × %s)).", path, num(region[0]), num(region[1]), num(region[2]), num(region[3]))
			}
		}
	}
	text = strings.to_string(b)
	annotations_clear()
	annot.active = false
	return
}
