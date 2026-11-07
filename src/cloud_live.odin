package agentic_design

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import "engine"
import nvg "nanovg"

// A cloud document open live (cloud-design §2, §3.4): the tab's document is the room's, kept in
// step through its WebSocket. The same code runs in the Mac app and in the browser editor;
// each has its transport (live_darwin.odin, live_js.odin) and hands what arrives to live_event.
//
// - Own edits: every 100 ms, if the document changed, the difference from what was last sent
//   (engine.ops_diff) becomes a batch (engine.sync_local) and goes to the room. Layout's own
//   props are never sent.
// - Others' edits: applied as they come (engine.sync_remote); a pending value of ours wins on
//   screen until the room has ordered it.
// - Undo: each person undoes their own steps. A step keeps the ops that revert it, worked out
//   when it was sent; undo applies them as a new edit, which then goes out like any other.
//   Others' changes made since stay.
// - Presence: the pointer (page coordinates), the selection and the page, at most 10 a
//   second, while something moved; others' pointers are drawn as people's cursors
//   (presence.odin).
// - Viewers and commenters get the document and the cursors; their edits are refused by the
//   room, so the canvas does not let them edit (live_read_only).
// - The connection drops: it reconnects with backoff and resends what the room has not
//   acknowledged (the room drops a batch it has already seen).

LIVE_WIRE :: 1
LIVE_FLUSH :: 0.1 // seconds between batches while editing
LIVE_PRESENCE :: 0.1

Live_Phase :: enum {
	Off,
	Connecting,
	Live,
	Offline, // lost the connection; retrying
	Closed, // the room said no (removed, deleted); not retrying
}

Live_Person :: struct {
	user:  string,
	name:  string,
	color: nvg.Color,
	role:  string,
}

Live_Event :: enum {
	Open,
	Message,
	Close,
	Http, // the answer to live_http: `code` is the status (0: no answer), `req` its number
}

live: struct {
	phase:        Live_Phase,
	doc_id:       string,
	path:         string, // the tab's document
	name:         string, // the document's title
	role:         string, // ours: viewer, commenter, editor, owner
	me:           Live_Person,
	opened:       bool, // the room's document is in the tab (the first welcome)
	client:       engine.Sync_Client,
	state:        engine.Cloud_State, // the shown document's sort keys
	sent:         engine.Snapshot, // the shown document as last sent (or received)
	has_sent:     bool,
	flushed_at:   f64,
	seen_change:  i64, // app.last_change when last diffed
	steps:        int, // the tab's undo depth at the last flush
	undo:         [dynamic][]engine.Op, // ops reverting each of our steps
	redo:         [dynamic][]engine.Op,
	presence_at:  f64,
	sent_cursor:  [2]f32,
	sent_sel:     u64,
	retry_at:     f64,
	retries:      int,
	error:        string,
	people:       [dynamic]Live_Person, // others in the room now
	comments_rev: int, // bumps when the room says the comments changed
	inbox:        [dynamic]Live_Message, // from the transport, any thread
	lock:         sync.Mutex,
}

Live_Message :: struct {
	event: Live_Event,
	text:  string, // a message; the reason for a close; an answer's body
	code:  int,
	req:   int,
}

// Called by the transport, from any thread: queued for the next frame.
live_event :: proc(event: Live_Event, text: string, code := 0, req := 0) {
	sync.mutex_lock(&live.lock)
	append(&live.inbox, Live_Message{event, strings.clone(text, live_allocator()), code, req})
	sync.mutex_unlock(&live.lock)
	platform_wake()
}

live_active :: proc() -> bool {
	return live.phase != .Off
}

// The tab shows a live document whose room does not take our edits.
live_read_only :: proc() -> bool {
	return live.phase != .Off && app.file_path == live.path && live.role != "editor" && live.role != "owner"
}

live_is_current :: proc() -> bool {
	return live.phase != .Off && app.tab >= 0 && app.file_path == live.path
}

// Opens a cloud document live in the tab showing `path` (the copy it was started from).
live_open :: proc(doc_id, path, name: string) {
	live_close()
	live.doc_id = strings.clone(doc_id)
	live.path = strings.clone(path)
	live.name = strings.clone(name)
	live.phase = .Connecting
	live.retries = 0
	live_connect()
}

live_close :: proc() {
	if live.phase == .Off do return
	live_transport_close()
	presence_people_clear()
	live_reset_doc_state()
	delete(live.doc_id)
	delete(live.path)
	delete(live.name)
	live.doc_id, live.path, live.name = "", "", ""
	live.phase = .Off
	live.role = ""
	clear(&live.people)
}

@(private = "file")
live_reset_doc_state :: proc() {
	if live.has_sent do engine.free_snapshot(live.sent)
	live.has_sent = false
	live.opened = false
	for ops in live.undo do delete(ops)
	for ops in live.redo do delete(ops)
	clear(&live.undo)
	clear(&live.redo)
}

@(private = "file")
live_connect :: proc() {
	url, bearer := live_room_url(live.doc_id)
	if url == "" {
		live_fail("Sign in to the cloud to open this file" when ODIN_OS == .Darwin || ODIN_OS == .JS else "Cloud files open in the browser on this system for now")
		return
	}
	if !live_transport_open(url, bearer) {
		live_fail("The connection to the cloud could not start")
		return
	}
	live.phase = .Connecting
}

@(private = "file")
live_fail :: proc(reason: string) {
	delete(live.error)
	live.error = strings.clone(reason)
	live.phase = .Closed
	set_status("%s", reason)
}

@(private = "file")
live_send :: proc(text: string) {
	if live.phase == .Live do live_transport_send(text)
}

// The document the live session edits, wherever its tab is (the open tab's is app.doc).
@(private = "file")
live_doc :: proc() -> ^engine.Document {
	if app.tab >= 0 && app.file_path == live.path do return &app.doc
	for &t in app.tabs do if t.path == live.path do return &t.doc
	return nil
}

// Each frame: what arrived, then our edits and presence.
live_tick :: proc() {
	if live.phase == .Off do return
	doc := live_doc()
	if doc == nil {
		// the tab was closed (or, starting, is not open yet: what arrived waits)
		if live.opened do live_close()
		return
	}
	sync.mutex_lock(&live.lock)
	inbox := live.inbox
	live.inbox = {}
	sync.mutex_unlock(&live.lock)
	defer {
		for m in inbox do delete(m.text, live_allocator())
		delete(inbox)
	}
	live.client.shown = doc
	now := platform_time()
	// viewers and commenters: the canvas selects and pans, nothing else (the room refuses edits;
	// what still changes goes back at the next flush)
	if live_read_only() {
		#partial switch app.drag.kind {
		case .Move, .Resize, .Create, .Gradient: app.drag.kind = .None
		}
		if app.tool != .Select && app.tool != .Hand do app.tool = .Select
		if app.editing != 0 do app.editing = 0
	}
	// ours first, so that what arrives is not taken for our edit
	if live.opened && (len(inbox) > 0 || now - live.flushed_at >= LIVE_FLUSH) do live_flush(doc, .Edit)
	changed := false
	for m in inbox {
		switch m.event {
		case .Open:
			live.retries = 0
			hello := fmt.tprintf(`{{"t":"hello","v":%d,"since":%d,"full":%v}}`, LIVE_WIRE, live.client.seq, !live.opened)
			live.phase = .Live
			live_transport_send(hello)
		case .Message:
			if live_message(doc, m.text) do changed = true
		case .Close:
			live_closed(m.code, m.text)
		case .Http:
			comments_http_done(m.req, m.code, m.text)
		}
	}
	if changed {
		app.needs_layout = true
		live_resnapshot(doc)
		if app.file_path == live.path do prune_selection()
	}
	if (live.phase == .Offline) && now >= live.retry_at do live_connect()
	if live.phase == .Live && live.opened && app.file_path == live.path do live_presence(now)
	live_report()
}

// What the host shows outside the canvas (the web page's bar): the phase, our role and who
// else is here, when it changed.
@(private = "file")
live_report :: proc() {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"phase":"%v","role":%s,"error":%s,"people":[`, live.phase, json_quote(live.role), json_quote(live.error))
	for p, i in live.people {
		if i > 0 do strings.write_byte(&b, ',')
		fmt.sbprintf(&b, `{{"id":%s,"name":%s,"role":%s,"color":"#%02X%02X%02X"}}`, json_quote(p.user), json_quote(p.name), json_quote(p.role), u8(p.color.r * 255), u8(p.color.g * 255), u8(p.color.b * 255))
	}
	strings.write_string(&b, "]}")
	s := strings.to_string(b)
	@(static) last: string
	if s == last do return
	delete(last)
	last = strings.clone(s)
	live_host_state(s)
}

@(private = "file")
live_resnapshot :: proc(doc: ^engine.Document) {
	if live.has_sent do engine.free_snapshot(live.sent)
	live.sent = engine.doc_snapshot(doc)
	live.has_sent = true
	live.seen_change = app.last_change._nsec
}

@(private = "file")
live_closed :: proc(code: int, reason: string) {
	switch reason {
	case "REVOKED":
		live_fail("You no longer have access to this file")
		return
	case "GONE":
		live_fail("This file was deleted")
		return
	case "UPGRADE":
		live_fail("This file needs a newer version of the app")
		return
	case "SIGNED_OUT":
		live_fail("Sign in to the cloud again to open this file")
		return
	}
	if code == 4403 && reason == "ROLE_CHANGED" {
		set_status("Your access to this file changed")
		live.retry_at = platform_time()
	} else {
		live.retries += 1
		live.retry_at = platform_time() + min(30, f64(int(1) << uint(min(live.retries, 5))))
	}
	live.phase = .Offline
	presence_people_clear()
	clear(&live.people)
}

Flush_Kind :: enum {
	Edit,
	Undo,
	Redo,
}

// The difference between the shown document and what was last sent goes out as a batch.
@(private = "file")
live_flush :: proc(doc: ^engine.Document, kind: Flush_Kind) {
	live.flushed_at = platform_time()
	if !live.has_sent do return
	if kind == .Edit && app.last_change._nsec == live.seen_change do return
	live.seen_change = app.last_change._nsec
	if live.role != "editor" && live.role != "owner" {
		// nothing of ours may change the room's document: what was changed here goes back
		live_revert(doc)
		return
	}
	before := make([]engine.Node, len(live.sent.nodes), context.temp_allocator)
	for r, i in live.sent.nodes do before[i] = r.node
	ops := engine.ops_diff(before, doc.nodes[:], live.sent.header.props, doc.header[:], &live.state)
	if len(ops) == 0 do return
	// what reverts it, for our undo (worked out on a copy of the keys: the revert's moves get
	// their own)
	keys := engine.Cloud_State{}
	keys.sorts = make(map[string]string, len(live.state.sorts), context.temp_allocator)
	for k, v in live.state.sorts do keys.sorts[k] = v
	back := engine.ops_diff(doc.nodes[:], before, doc.header[:], live.sent.header.props, &keys)
	switch kind {
	case .Edit:
		if depth := undo_depth(); depth != live.steps || len(live.undo) == 0 {
			live.steps = depth
			append(&live.undo, engine.ops_clone(back[:]))
		} else {
			// the same step (a drag across frames): its revert runs this one's first
			last := live.undo[len(live.undo) - 1]
			joined := make([dynamic]engine.Op, 0, len(back) + len(last), context.temp_allocator)
			append(&joined, ..back[:])
			append(&joined, ..last)
			live.undo[len(live.undo) - 1] = engine.ops_clone(joined[:])
			delete(last)
		}
		for r in live.redo do delete(r)
		clear(&live.redo)
	case .Undo:
		append(&live.redo, engine.ops_clone(back[:]))
	case .Redo:
		append(&live.undo, engine.ops_clone(back[:]))
	}
	id := engine.sync_local(&live.client, ops[:])
	live_send_batch(id, ops[:])
	live_resnapshot(doc)
}

@(private = "file")
live_send_batch :: proc(id: string, ops: []engine.Op) {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"t":"batch","batch":%s,"base":%d,"ops":[`, json_quote(id), live.client.seq)
	for op, i in ops {
		if i > 0 do strings.write_byte(&b, ',')
		engine.op_write(&b, op)
	}
	strings.write_string(&b, "]}")
	live_send(strings.to_string(b))
}

// After a reconnect: what the room has not acknowledged, again (it drops what it has seen).
@(private = "file")
live_resend :: proc() {
	for p in live.client.pending do live_send_batch(p.id, p.ops)
}

// A change made where the room takes none (a viewer): the shown document goes back.
@(private = "file")
live_revert :: proc(doc: ^engine.Document) {
	engine.doc_restore(doc, live.sent)
	app.needs_layout = true
	if !live_read_only_said {
		live_read_only_said = true
		set_status("You can %s this file, not edit it", "comment on" if live.role == "commenter" else "view")
	}
}
@(private = "file")
live_read_only_said: bool

// Undo and redo of a live document: our own steps only.
live_undo :: proc(redo := false) {
	doc := live_doc()
	if doc == nil || !live.has_sent do return
	live_flush(doc, .Edit)
	stack := &live.redo if redo else &live.undo
	if len(stack) == 0 do return
	ops := pop(stack)
	defer delete(ops)
	_ = engine.ops_apply(doc, &live.state, ops)
	app.needs_layout = true
	mark_dirty()
	live_flush(doc, .Redo if redo else .Undo)
	live.steps = undo_depth()
	prune_selection()
}

@(private = "file")
undo_depth :: proc() -> int {
	return undo_pushes
}

// ---------------------------------------------------------------- what the room says

@(private = "file")
live_message :: proc(doc: ^engine.Document, text: string) -> (changed: bool) {
	v, err := json.parse_string(text, allocator = context.temp_allocator)
	if err != nil do return
	o, ok := v.(json.Object)
	if !ok do return
	str :: proc(o: json.Object, k: string) -> string {return string(o[k].(json.String) or_else "")}
	num :: proc(o: json.Object, k: string) -> int {return int(o[k].(json.Float) or_else 0)}
	switch str(o, "t") {
	case "welcome":
		live.role = strings.clone(str(o, "role"))
		if you, has := o["you"].(json.Object); has do live.me = person_of(you)
		if snap, has := o["snapshot"].(json.Object); has {
			// the whole document: from it, with whatever we have not had acknowledged lost
			sorts := make(map[string]string, 64, context.temp_allocator)
			if so, sok := snap["sorts"].(json.Object); sok do for k, val in so do sorts[k] = string(val.(json.String) or_else "")
			live_reset_doc_state()
			live.client = {}
			live.state = {}
			if !engine.sync_init(&live.client, str(snap, "pen"), num(snap, "seq"), doc, &live.state, live_session_id(), sorts) {
				live_fail("The cloud document could not be read")
				return
			}
			live.opened = true
			live.steps = undo_depth()
			changed = true
			if app.file_path == live.path do app.needs_layout = true
		} else if ops, has := o["ops"].(json.Array); has {
			for entry in ops {
				e := entry.(json.Object) or_continue
				if live_remote(e) do changed = true
			}
			live_resend()
		}
		clear(&live.people)
		if pres, has := o["presence"].(json.Array); has do for p in pres do if po, pok := p.(json.Object); pok do live_presence_in(po)
	case "ops":
		if live_remote(o) do changed = true
	case "ack":
		engine.sync_ack(&live.client, str(o, "batch"), num(o, "seq"))
	case "nack":
		engine.sync_nack(&live.client, str(o, "batch"))
		changed = true
		switch str(o, "reason") {
		case "FORBIDDEN": set_status("You can view this file, not edit it")
		case "QUOTA": set_status("This file has reached its size limit; the change was undone")
		case "AGENTS_OFF": set_status("Agents may not edit this file")
		case: set_status("The cloud refused a change (%s); it was undone", str(o, "reason"))
		}
	case "presence":
		live_presence_in(o)
	case "join":
		if a, has := o["author"].(json.Object); has do live_person_add(person_of(a))
	case "leave":
		if a, has := o["author"].(json.Object); has {
			id := str(a, "userId")
			presence_person_leave(id)
			for p, i in live.people do if p.user == id {
				ordered_remove(&live.people, i)
				break
			}
		}
	case "comments":
		live.comments_rev += 1
		comments_room_changed()
	}
	return
}

@(private = "file")
live_remote :: proc(o: json.Object) -> bool {
	arr, ok := o["ops"].(json.Array)
	if !ok do return false
	ops := make([dynamic]engine.Op, 0, len(arr), context.temp_allocator)
	for e in arr do if op, pok := engine.op_parse(e); pok do append(&ops, op)
	seq := int(o["seq"].(json.Float) or_else 0)
	if seq <= live.client.seq do return false
	engine.sync_remote(&live.client, seq, ops[:])
	// what someone else did is not ours to undo: our steps keep their reverts, which touch
	// only what we changed
	return true
}

@(private = "file")
person_of :: proc(a: json.Object) -> Live_Person {
	p := Live_Person {
		user = strings.clone(string(a["userId"].(json.String) or_else "")),
		name = strings.clone(string(a["name"].(json.String) or_else "Someone")),
		role = strings.clone(string(a["role"].(json.String) or_else "")),
	}
	p.color = palette_color(p.name)
	if hex, ok := a["color"].(json.String); ok {
		if v, pok := strconv.parse_u64_of_base(strings.trim_prefix(string(hex), "#"), 16); pok do p.color = hex_color(u32(v))
	}
	return p
}

@(private = "file")
live_person_add :: proc(p: Live_Person) {
	for q in live.people do if q.user == p.user do return // a second tab or device of the same person
	if p.user == live.me.user do return
	append(&live.people, p)
}

@(private = "file")
live_presence_in :: proc(o: json.Object) {
	a, ok := o["author"].(json.Object)
	if !ok do return
	who := person_of(a)
	if who.user == live.me.user do return
	live_person_add(who)
	cur, has := o["cursor"].(json.Object)
	if !has do return
	x, xok := cur["x"].(json.Float)
	y, yok := cur["y"].(json.Float)
	if !xok || !yok do return
	presence_person_at(who.user, who.name, who.color, live.path, {f32(x), f32(y)})
}

// Our pointer and selection, when they changed.
@(private = "file")
live_presence :: proc(now: f64) {
	if now - live.presence_at < LIVE_PRESENCE do return
	over := in_rect(app.canvas, app.mouse)
	cursor := to_page(app.mouse)
	h: u64 = 1469598103934665603
	for uid in app.sel do h = (h ~ u64(uid)) * 1099511628211
	if (!over || cursor == live.sent_cursor) && h == live.sent_sel do return
	live.presence_at = now
	live.sent_sel = h
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"t":"presence"`)
	if over {
		live.sent_cursor = cursor
		fmt.sbprintf(&b, `,"cursor":{{"x":%.1f,"y":%.1f}}`, cursor.x, cursor.y)
	}
	strings.write_string(&b, `,"selection":[`)
	first := true
	for uid in app.sel {
		n, _ := engine.doc_find_uid(&app.doc, uid)
		if n == nil do continue
		if !first do strings.write_byte(&b, ',')
		first = false
		strings.write_string(&b, json_quote(n.id))
	}
	fmt.sbprintf(&b, `],"page":%d}}`, app.page)
	live_send(strings.to_string(b))
}

@(private = "file")
live_session_id :: proc() -> string {
	@(static) id: string
	if id == "" do id = fmt.aprintf("%x", u64(platform_time() * 1e6) ~ u64(uintptr(&live)))
	return id
}
