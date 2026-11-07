package agentic_design

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"
import "engine"
import nvg "nanovg"

// Comments of a live cloud document (site/src/comments.ts, decision 18), in the Mac app and
// the browser editor alike. They are the server's, not the .pen's: fetched over the API, and
// fetched again when the room says they changed.
//
// - A thread is pinned to a point of the page. Its pin shows who started it; a click opens
//   its card: the comments, oldest first, and a reply field.
// - Comment (the button beside the tool bar, or ⇧C) places a new thread with a click.
// - What each person may do comes with the list (canEdit, canDelete, canResolve): a viewer
//   reads; a commenter writes, replies, changes and deletes their own; an editor or the owner
//   also deletes anyone's and resolves.
// - Resolved threads leave the canvas.

COMMENT_CARD_W :: 300

Comment_Item :: struct {
	id:         string,
	author_id:  string,
	author:     string,
	body:       string,
	created:    string,
	edited:     bool,
	can_edit:   bool,
	can_delete: bool,
}

Comment_Thread :: struct {
	using first: Comment_Item,
	at:          [2]f32, // page coordinates
	node:        string,
	resolved:    bool,
	can_resolve: bool,
	replies:     [dynamic]Comment_Item,
}

@(private = "file")
Pin_Hit :: struct {
	thread: string,
	r:      Rect,
}

comments: struct {
	doc_id:      string, // the list is of this document
	threads:     [dynamic]Comment_Thread,
	can_comment: bool,
	loading:     bool,
	again:       bool, // changed while loading: fetch once more
	placing:     bool, // the next click on the canvas starts a thread
	open:        string, // the thread whose card is open
	draft_at:    [2]f32,
	drafting:    bool, // a new thread's card at draft_at
	editing:     string, // the comment whose text is being changed
	busy:        int, // requests that change something, unanswered
	req:         int,
	list_req:    int,
	pins:        [dynamic]Pin_Hit, // where last frame drew them (window coordinates)
	card:        Rect, // the open card, window coordinates
	button:      Rect, // the Comment button
	error:       string,
}

// The document shown is live and its comments are ours to show.
comments_on :: proc() -> bool {
	return live_is_current() && live.opened
}

// The room said they changed (cloud_live.odin).
comments_room_changed :: proc() {
	comments_fetch()
}

@(private = "file")
comments_fetch :: proc() {
	if live.doc_id == "" do return
	if comments.doc_id != live.doc_id {
		comments_clear()
		comments.doc_id = strings.clone(live.doc_id)
	}
	if comments.loading {
		comments.again = true
		return
	}
	comments.loading = true
	comments.req += 1
	comments.list_req = comments.req
	live_http(comments.req, "GET", fmt.tprintf("/api/docs/%s/comments", live.doc_id), "")
}

@(private = "file")
comments_clear :: proc() {
	for &t in comments.threads {
		item_free(&t.first)
		delete(t.node)
		for &r in t.replies do item_free(&r)
		delete(t.replies)
	}
	clear(&comments.threads)
	delete(comments.doc_id)
	comments.doc_id = ""
	delete(comments.open)
	comments.open = ""
	comments.drafting, comments.placing = false, false
}

@(private = "file")
item_free :: proc(c: ^Comment_Item) {
	delete(c.id)
	delete(c.author_id)
	delete(c.author)
	delete(c.body)
	delete(c.created)
}

// An answer from the API (live_http).
comments_http_done :: proc(req, status: int, body: string) {
	if req == comments.list_req {
		comments.loading = false
		if status == 200 do comments_parse(body)
		if comments.again {
			comments.again = false
			comments_fetch()
		}
		return
	}
	comments.busy = max(0, comments.busy - 1)
	if status < 200 || status >= 300 {
		msg := "The comment could not be saved"
		if v, err := json.parse_string(body, allocator = context.temp_allocator); err == nil {
			if o, ok := v.(json.Object); ok do if m, has := o["error"].(json.String); has do msg = string(m)
		}
		set_status("%s", msg)
	}
	comments_fetch()
}

@(private = "file")
comments_parse :: proc(body: string) {
	v, err := json.parse_string(body, allocator = context.temp_allocator)
	if err != nil do return
	o := v.(json.Object) or_else nil
	if o == nil do return
	open := strings.clone(comments.open, context.temp_allocator)
	doc := strings.clone(comments.doc_id, context.temp_allocator)
	drafting, at, placing := comments.drafting, comments.draft_at, comments.placing
	comments_clear()
	comments.doc_id = strings.clone(doc)
	comments.drafting, comments.draft_at, comments.placing = drafting, at, placing
	comments.can_comment = o["canComment"].(json.Boolean) or_else false
	item :: proc(o: json.Object) -> Comment_Item {
		str :: proc(o: json.Object, k: string) -> string {return strings.clone(string(o[k].(json.String) or_else ""))}
		a := o["author"].(json.Object) or_else nil
		return {
			id = str(o, "id"),
			author_id = str(a, "id") if a != nil else "",
			author = str(a, "name") if a != nil else strings.clone("Someone"),
			body = str(o, "body"),
			created = str(o, "createdAt"),
			edited = (o["editedAt"].(json.String) or_else "") != "",
			can_edit = o["canEdit"].(json.Boolean) or_else false,
			can_delete = o["canDelete"].(json.Boolean) or_else false,
		}
	}
	for tv in o["threads"].(json.Array) or_else nil {
		to := tv.(json.Object) or_continue
		t := Comment_Thread{first = item(to)}
		if an, ok := to["anchor"].(json.Object); ok {
			t.at = {f32(an["x"].(json.Float) or_else 0), f32(an["y"].(json.Float) or_else 0)}
			t.node = strings.clone(string(an["node"].(json.String) or_else ""))
		}
		t.resolved = (to["resolvedAt"].(json.String) or_else "") != ""
		t.can_resolve = to["canResolve"].(json.Boolean) or_else false
		for rv in to["replies"].(json.Array) or_else nil do if ro, ok := rv.(json.Object); ok do append(&t.replies, item(ro))
		append(&comments.threads, t)
	}
	// the card stays open on its thread, if it is still there
	for t in comments.threads do if t.id == open && !t.resolved do comments.open = strings.clone(open)
}

@(private = "file")
comments_send :: proc(method, path, body: string) {
	comments.req += 1
	comments.busy += 1
	live_http(comments.req, method, path, body)
}

@(private = "file")
thread_of :: proc(id: string) -> ^Comment_Thread {
	for &t in comments.threads do if t.id == id do return &t
	return nil
}

// ---------------------------------------------------------------- input (handle_input)

// The pointer and keys while comments are on: true when they took the click.
comments_input :: proc(over_canvas: bool, page: [2]f32) -> bool {
	if !comments_on() do return false
	if comments.doc_id != live.doc_id && !comments.loading do comments_fetch()
	if key_pressed(KEY_ESCAPE) && ui.focus == "" && (comments.placing || comments.drafting || comments.open != "") {
		comments.placing, comments.drafting = false, false
		delete(comments.open)
		comments.open = ""
		return true
	}
	if ui.focus == "" && mod_shift() && !mod_cmd() && key_pressed(KEY_C) && comments.can_comment do comments.placing = !comments.placing
	if comments.placing {
		ui.cursor_hint = .Crosshair
		if over_canvas && mouse_pressed(MOUSE_BUTTON_LEFT) {
			comments.placing = false
			comments.drafting = true
			comments.draft_at = page
			delete(comments.open)
			comments.open = ""
			field_focus(0, "cmt.new", "")
			return true
		}
		return over_canvas
	}
	// a click on the canvas closes the card
	if over_canvas && mouse_pressed(MOUSE_BUTTON_LEFT) && (comments.open != "" || comments.drafting) {
		comments.drafting = false
		delete(comments.open)
		comments.open = ""
	}
	return false
}

// Pins, the card and the Comment button sit on the canvas: the canvas leaves them alone.
comments_hit :: proc(p: [2]f32) -> bool {
	if !comments_on() do return false
	if in_rect(comments.button, p) || in_rect(comments.card, p) do return true
	for h in comments.pins do if in_rect(h.r, p) do return true
	return false
}

// Commits of the comment fields: nothing happens on a click away (the text stays typed);
// Enter sends (draw_comments).
comments_field_apply :: proc(key: string) -> bool {
	return strings.has_prefix(key, "cmt.")
}

// ---------------------------------------------------------------- drawing (on the canvas)

draw_comments :: proc(vg: ^nvg.Context) {
	clear(&comments.pins)
	comments.card, comments.button = {}, {}
	if !comments_on() do return
	o := ui.origin
	for &t in comments.threads {
		if t.resolved do continue
		p := to_screen(t.at)
		r := pin(vg, p, t.author, t.id == comments.open)
		append(&comments.pins, Pin_Hit{t.id, {r.x + o.x, r.y + o.y, r.w, r.h}})
		if clicked(r) {
			comments.drafting = false
			delete(comments.open)
			comments.open = strings.clone(t.id) if comments.open != t.id else ""
		}
	}
	if comments.drafting {
		p := to_screen(comments.draft_at)
		pin(vg, p, live.me.name if live.me.name != "" else "You", true)
		draft_card(vg, p)
	} else if t := thread_of(comments.open); t != nil {
		thread_card(vg, to_screen(t.at), t)
	}
	comment_button(vg)
}

// A pin: a round bubble whose bottom-left corner is the point, with the author's initial.
@(private = "file")
pin :: proc(vg: ^nvg.Context, p: [2]f32, who: string, on: bool) -> Rect {
	s: f32 = 26
	r := Rect{p.x, p.y - s, s, s}
	nvg.BeginPath(vg)
	nvg.MoveTo(vg, p.x, p.y)
	nvg.LineTo(vg, p.x, p.y - s / 2)
	nvg.ArcTo(vg, p.x, p.y - s, p.x + s / 2, p.y - s, s / 2)
	nvg.ArcTo(vg, p.x + s, p.y - s, p.x + s, p.y - s / 2, s / 2)
	nvg.ArcTo(vg, p.x + s, p.y, p.x + s / 2, p.y, s / 2)
	nvg.ClosePath(vg)
	nvg.FillColor(vg, palette_color(who))
	nvg.Fill(vg)
	nvg.StrokeColor(vg, ACCENT if on else nvg.Color{1, 1, 1, 1})
	nvg.StrokeWidth(vg, 2.5 if on else 2)
	nvg.Stroke(vg)
	label(vg, p.x + s / 2, p.y - s / 2 + 0.5, initial(who), {1, 1, 1, 1}, 11, true, .CENTER)
	if hovered(r) do ui.cursor_hint = .Hand
	return r
}

@(private = "file")
initial :: proc(name: string) -> string {
	n := strings.trim_space(name)
	if n == "" do return "?"
	for _, i in n {
		if i > 0 do return strings.to_upper(n[:i], context.temp_allocator)
	}
	return strings.to_upper(n, context.temp_allocator)
}

// Where a card goes: right of the pin, kept on the canvas.
@(private = "file")
card_rect :: proc(p: [2]f32, h: f32) -> Rect {
	c := app.canvas
	x := p.x + 36
	if x + COMMENT_CARD_W > c.x + c.w - 8 do x = p.x - 10 - COMMENT_CARD_W
	y := clamp(p.y - 30, c.y + 8, max(c.y + 8, c.y + c.h - h - 8))
	return {x, y, COMMENT_CARD_W, h}
}

@(private = "file")
card_begin :: proc(vg: ^nvg.Context, r: Rect) {
	popup_shadow(vg, r, 12)
	fill_rect(vg, r, PANEL_BG, 12)
	stroke_rect(vg, r, PANEL_LINE, 12)
	comments.card = {r.x + ui.origin.x, r.y + ui.origin.y, r.w, r.h}
	ui.focus_rect = comments.card if strings.has_prefix(ui.focus, "cmt.") else ui.focus_rect
}

COMMENT_LH :: 17

@(private = "file")
body_rows :: proc(vg: ^nvg.Context, text: string, w: f32) -> [][2]int {
	nvg.FontFace(vg, "ui")
	nvg.FontSize(vg, 12.5)
	return text_rows(vg, text, w)
}

@(private = "file")
item_height :: proc(vg: ^nvg.Context, c: ^Comment_Item, w: f32) -> f32 {
	if c.id == comments.editing do return 24 + 34
	return 24 + f32(len(body_rows(vg, c.body, w))) * COMMENT_LH + 6
}

// One comment: who, when, its menu, then the text (or its field while it is being changed).
@(private = "file")
draw_item :: proc(vg: ^nvg.Context, c: ^Comment_Item, x, y, w: f32, thread: ^Comment_Thread) -> f32 {
	nvg.BeginPath(vg)
	nvg.Circle(vg, x + 9, y + 10, 9)
	nvg.FillColor(vg, palette_color(c.author))
	nvg.Fill(vg)
	label(vg, x + 9, y + 10.5, initial(c.author), {1, 1, 1, 1}, 9, true, .CENTER)
	label(vg, x + 24, y + 10, c.author, TEXT_FG, 12, true)
	nw := text_width(vg, c.author, 12)
	label(vg, x + 30 + nw, y + 10, fmt.tprintf("%s%s", ago_iso(c.created), " · edited" if c.edited else ""), TEXT_DIM, 11)
	if c.can_edit || c.can_delete {
		more := Rect{x + w - 22, y, 22, 20}
		if hovered(more) do fill_rect(vg, more, HOVER_BG, 5)
		draw_lucide(vg, "ellipsis", more.x + 11, more.y + 10, 14, TEXT_DIM, 1.8)
		key := fmt.tprintf("cmt.menu:%s", c.id)
		if clicked(more) {
			items := make([dynamic]string, context.temp_allocator)
			if c.can_edit do append(&items, "Edit")
			if c.can_delete do append(&items, "Delete thread" if thread != nil && c.id == thread.id && len(thread.replies) > 0 else "Delete")
			menu_open(key, {more.x, more.y + more.h, more.w, 0}, items[:])
		}
		if i, ok := menu_take(key); ok && i >= 0 {
			choice := "Edit" if c.can_edit && i == 0 else "Delete"
			if choice == "Edit" {
				delete(comments.editing)
				comments.editing = strings.clone(c.id)
				field_focus(0, fmt.tprintf("cmt.edit:%s", c.id), c.body)
				ui.sel = -1
			} else {
				comments_send("DELETE", fmt.tprintf("/api/docs/%s/comments/%s", live.doc_id, c.id), "")
				if thread != nil && c.id == thread.id {
					delete(comments.open)
					comments.open = ""
				}
			}
		}
	}
	y := y + 24
	if c.id == comments.editing {
		key := fmt.tprintf("cmt.edit:%s", c.id)
		fr := Rect{x, y, w, 28}
		if field_is_focused(0, key) && (key_pressed(KEY_ENTER) || key_pressed(KEY_KP_ENTER)) {
			text := strings.trim_space(strings.to_string(ui.buf))
			ui.focus = ""
			if text != "" && text != c.body do comments_send("PATCH", fmt.tprintf("/api/docs/%s/comments/%s", live.doc_id, c.id), fmt.tprintf(`{{"body":%s}}`, json_quote(text)))
			delete(comments.editing)
			comments.editing = ""
		} else if !field_is_focused(0, key) {
			delete(comments.editing)
			comments.editing = ""
		} else {
			field(vg, 0, key, "", fr, c.body, placeholder = "Change the comment, Enter to save")
		}
		return y + 34
	}
	rows := body_rows(vg, c.body, w)
	nvg.TextAlign(vg, .LEFT, .TOP)
	nvg.FillColor(vg, TEXT_FG)
	for row, i in rows do nvg.Text(vg, x, y + f32(i) * COMMENT_LH + 1, c.body[row[0]:row[1]])
	return y + f32(len(rows)) * COMMENT_LH + 6
}

@(private = "file")
thread_card :: proc(vg: ^nvg.Context, p: [2]f32, t: ^Comment_Thread) {
	pad: f32 = 14
	w := f32(COMMENT_CARD_W) - pad * 2
	h := 40 + item_height(vg, &t.first, w)
	for &r in t.replies do h += 8 + item_height(vg, &r, w)
	if comments.can_comment do h += 46
	h += 4
	r := card_rect(p, h)
	card_begin(vg, r)
	// head: Resolve, close
	label(vg, r.x + pad, r.y + 20, "Comment", TEXT_DIM, 11)
	close := Rect{r.x + r.w - 34, r.y + 8, 24, 24}
	if hovered(close) do fill_rect(vg, close, HOVER_BG, 6)
	draw_lucide(vg, "x", close.x + 12, close.y + 12, 14, TEXT_DIM, 1.8)
	if clicked(close) {
		delete(comments.open)
		comments.open = ""
		return
	}
	if t.can_resolve {
		res := Rect{close.x - 28, close.y, 24, 24}
		if hovered(res) {
			fill_rect(vg, res, HOVER_BG, 6)
			tooltip_request("Resolve", res)
		}
		draw_lucide(vg, "circle-check", res.x + 12, res.y + 12, 15, TEXT_DIM, 1.8)
		if clicked(res) {
			comments_send("PATCH", fmt.tprintf("/api/docs/%s/comments/%s", live.doc_id, t.id), `{"resolved":true}`)
			delete(comments.open)
			comments.open = ""
			return
		}
	}
	fill_rect(vg, {r.x, r.y + 36, r.w, 1}, PANEL_LINE)
	y := r.y + 46
	y = draw_item(vg, &t.first, r.x + pad, y, w, t)
	for &c in t.replies {
		y += 8
		y = draw_item(vg, &c, r.x + pad, y, w, t)
	}
	if comments.can_comment {
		key := fmt.tprintf("cmt.reply:%s", t.id)
		fr := Rect{r.x + pad, y + 6, w, 30}
		if field_is_focused(0, key) && (key_pressed(KEY_ENTER) || key_pressed(KEY_KP_ENTER)) {
			text := strings.trim_space(strings.to_string(ui.buf))
			strings.builder_reset(&ui.buf)
			ui.caret, ui.sel = 0, -1
			if text != "" do comments_send("POST", fmt.tprintf("/api/docs/%s/comments", live.doc_id), fmt.tprintf(`{{"body":%s,"threadId":%s}}`, json_quote(text), json_quote(t.id)))
		}
		field(vg, 0, key, "", fr, "", placeholder = "Reply")
	}
}

@(private = "file")
draft_card :: proc(vg: ^nvg.Context, p: [2]f32) {
	r := card_rect(p, 92)
	card_begin(vg, r)
	label(vg, r.x + 14, r.y + 20, "New comment", TEXT_DIM, 11)
	fr := Rect{r.x + 14, r.y + 38, r.w - 28, 30}
	if field_is_focused(0, "cmt.new") && (key_pressed(KEY_ENTER) || key_pressed(KEY_KP_ENTER)) {
		text := strings.trim_space(strings.to_string(ui.buf))
		ui.focus = ""
		comments.drafting = false
		if text != "" {
			node := ""
			if uid := hit_test(comments.draft_at); uid != 0 {
				if n, _ := engine.doc_find_uid(&app.doc, uid); n != nil do node = n.id
			}
			anchor := fmt.tprintf(`{{"x":%.1f,"y":%.1f%s,"page":%d}}`, comments.draft_at.x, comments.draft_at.y, fmt.tprintf(`,"node":%s`, json_quote(node)) if node != "" else "", app.page)
			comments_send("POST", fmt.tprintf("/api/docs/%s/comments", live.doc_id), fmt.tprintf(`{{"body":%s,"anchor":%s}}`, json_quote(text), anchor))
		}
		return
	}
	if !field_is_focused(0, "cmt.new") && ui.focus != "" {
		comments.drafting = false
		return
	}
	field(vg, 0, "cmt.new", "", fr, "", placeholder = "Add a comment, Enter to post")
	label(vg, r.x + 14, r.y + 80, "Esc to cancel", TEXT_DIM, 10)
}

// The Comment button, left of the tool bar (it places a thread with the next click).
@(private = "file")
comment_button :: proc(vg: ^nvg.Context) {
	if !comments.can_comment do return
	bar := toolbar_rect()
	r := Rect{bar.x - 8 - bar.h, bar.y, bar.h, bar.h}
	float_surface(vg, r, 12)
	b := Rect{r.x + 6, r.y + 6, r.w - 12, r.h - 12}
	if comments.placing do fill_rect(vg, b, ACCENT, 8)
	else if hovered(b) do fill_rect(vg, b, HOVER_BG, 8)
	draw_lucide(vg, "message-circle", b.x + b.w / 2, b.y + b.h / 2, 16, {1, 1, 1, 1} if comments.placing else TEXT_FG, 1.8)
	if hovered(b) do tooltip_request("Comment  ⇧C", b)
	if clicked(b) do comments.placing = !comments.placing
	comments.button = {r.x + ui.origin.x, r.y + ui.origin.y, r.w, r.h}
}

// "3 min ago" for an ISO time of the server.
@(private = "file")
ago_iso :: proc(iso: string) -> string {
	t, consumed := time.iso8601_to_time_utc(iso)
	if consumed == 0 do return ""
	s := time.duration_seconds(time.since(t))
	switch {
	case s < 60: return "now"
	case s < 3600: return fmt.tprintf("%d min", int(s / 60))
	case s < 86400: return fmt.tprintf("%d h", int(s / 3600))
	case s < 86400 * 30: return fmt.tprintf("%d d", int(s / 86400))
	}
	y, m, d := time.date(t)
	return fmt.tprintf("%d %v %d", d, m, y)
}
