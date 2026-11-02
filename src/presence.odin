package agentic_design

import "engine"

import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:math"
import "core:math/rand"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import nvg "nanovg"

// Others on the canvas. Agents working through the API (the MCP proxy names them from the
// client's `clientInfo`), and whoever a future multiplayer link reports through the
// `presence` request. Each has a cursor with its name that glides to what it works on.
// Layers an agent creates, changes, deletes or captures flash in its colour once the
// cursor gets there, one after another. Frames marked `placeholder` glow while an agent
// works on the file.
//
// Modelled on pen.dev's agent presence, with its timings and sizes (AgentCursorMotion,
// addFlash, renderGeneratingEffects in Pen.app). The differences: an agent's cursor visits
// the layers of one request in turn instead of jumping to the last, a little faster; it
// stays for 15 s, since an agent thinks between calls; deleted layers flash where they were.
//
// Frames are drawn only while something moves (presence_animating feeds idle_wait), at
// 60 fps for travel and flashes and 20 fps while a resting cursor sways. Nothing of this is
// drawn into screenshots or exports.

Peer :: struct {
	key:        string, // "agent:<id>" or "person:<id>"
	name:       string,
	color:      nvg.Color,
	person:     bool,
	file:       string, // the document it is in
	cur:        [2]f32, // page coordinates, as drawn
	target:     [2]f32,
	appear:     f64, // when it last appeared; 0 = never
	active:     f64, // its last activity
	decay:      f32, // how fast it closes in on the target, per second
	wobble:     f32, // 0..1, the sway of a resting cursor
	phase:      f32,
	visits:     [dynamic]Visit, // where it heads next, in order
	busy_until: f64, // when its queued visits end
}

Visit :: struct {
	at:  f64, // when the cursor heads there
	uid: int, // a layer (its box when the visit starts), or 0 for `box`
	box: [4]f32,
}

Flash :: struct {
	file:  string,
	uid:   int, // follows the layer; 0 once it is gone (deleted layers keep their last box)
	box:   [4]f32,
	start: f64,
	color: nvg.Color,
	scan:  bool,
	long:  bool,
	gone:  bool, // a deleted layer: the ring folds in where it was
}

cursors: [dynamic]Peer
flashes: [dynamic]Flash
presence_clock: f64 // the time of the last motion step

// pen.dev's AgentCursorMotion and getAgentFlashTiming, in seconds and screen pixels
CURSOR_FADE_IN :: 0.2
CURSOR_FADE_OUT :: 1.5
AGENT_LINGER :: 15.0 // pen.dev: 5 s, while its own agent is not known to run
PERSON_LINGER :: 30.0
CURSOR_DECAY :: 4 // pen.dev: 2.5; a little quicker, so the cursor is there when the flash starts
PERSON_DECAY :: 14.0 // follows frequent updates of a person's pointer closely
WOBBLE_AMPLITUDE :: 4
WOBBLE_SPEED :: [2]f32{3, 2.3}
WOBBLE_REST :: 0.25
WOBBLE_DECAY :: 3
MAX_STEP :: 0.1
VISIT_STEP :: 0.45 // between the layers of one request
MAX_VISITS :: 6
MAX_FLASHES :: 40
FLASH_ATTACK :: 0.2
FLASH_HOLD :: 0.4
FLASH_HOLD_LONG :: 1.5
FLASH_RELEASE :: 0.3
PRESENCE_BLUE :: nvg.Color{96.0 / 255, 125.0 / 255, 1, 1} // #607dff

// The cursor glyph (24 × 24, tip at 4,5) and its label, as pen.dev draws them.
CURSOR_PATH :: "M4.037 4.688a.495.495 0 0 1 .651-.651l16 6.5a.5.5 0 0 1-.063.947l-6.124 1.58a2 2 0 0 0-1.438 1.435l-1.579 6.126a.5.5 0 0 1-.947.063z"
cursor_cmds: [dynamic]engine.Path_Cmd

Agent_Info :: struct {
	id, client, title: string,
}

// ---------------------------------------------------------------- who

// A display name and colour for an MCP client ("claude-code" → Claude in clay).
agent_look :: proc(client, title: string) -> (string, nvg.Color) {
	c := strings.to_lower(client, context.temp_allocator)
	Known :: struct {
		key, name: string,
		color:     u32,
	}
	known := [?]Known {
		{"claude", "Claude", 0xD97757},
		{"codex", "Codex", 0x10A37F},
		{"openai", "Codex", 0x10A37F},
		{"cursor", "Cursor", 0x7C5CFF},
		{"gemini", "Gemini", 0x4285F4},
		{"copilot", "Copilot", 0x8957E5},
		{"windsurf", "Windsurf", 0x0BA5A8},
		{"opencode", "OpenCode", 0xF97316},
		{"zed", "Zed", 0x0751CF},
	}
	for k in known do if strings.contains(c, k.key) do return k.name, hex_color(k.color)
	name := title if title != "" else client
	if name == "" do name = "Agent"
	return name, palette_color(name)
}

hex_color :: proc(v: u32) -> nvg.Color {
	return {f32(v >> 16 & 0xFF) / 255, f32(v >> 8 & 0xFF) / 255, f32(v & 0xFF) / 255, 1}
}

palette_color :: proc(name: string) -> nvg.Color {
	palette := [?]u32{0x607DFF, 0xE5484D, 0x30A46C, 0xF76B15, 0x8E4EC6, 0x0090FF, 0xD6409F, 0x12A594}
	return hex_color(palette[hash.fnv32a(transmute([]u8)name) % len(palette)])
}

presence_cursor :: proc(key, name: string, color: nvg.Color, person: bool) -> ^Peer {
	for &c in cursors do if c.key == key do return &c
	label := name
	// a second session of the same agent is told apart
	same := 1
	for c in cursors do if cursor_name_is(c.name, name) do same += 1
	if same > 1 do label = fmt.tprintf("%s %d", name, same)
	append(&cursors, Peer{key = strings.clone(key), name = strings.clone(label), color = color, person = person, decay = PERSON_DECAY if person else CURSOR_DECAY, phase = rand.float32() * 2 * math.PI})
	return &cursors[len(cursors) - 1]
}

agent_cursor :: proc(agent: Agent_Info) -> ^Peer {
	name, color := agent_look(agent.client, agent.title)
	key := fmt.tprintf("agent:%s", agent.id)
	// The MCP proxy names its agent by its process id. An agent that starts a proxy per
	// call (a script, a CLI) would get a new cursor each time: a crowd of "Claude 36",
	// "Claude 37". A new proxy takes over the cursor of an earlier one from the same client
	// whose process has ended; proxies running side by side keep cursors of their own.
	has := false
	for &c in cursors do if c.key == key do has = true
	if !has {
		for &c in cursors {
			if c.person || !strings.has_prefix(c.key, "agent:") || !cursor_name_is(c.name, name) do continue
			if !agent_process_gone(c.key[len("agent:"):]) do continue
			delete(c.key)
			c.key = strings.clone(key)
			break
		}
	}
	return presence_cursor(key, name, color, false)
}

// "Claude" or "Claude 2" for the name "Claude".
cursor_name_is :: proc(label, name: string) -> bool {
	if label == name do return true
	if !strings.has_prefix(label, name) || len(label) < len(name) + 2 || label[len(name)] != ' ' do return false
	_, ok := strconv.parse_int(label[len(name) + 1:])
	return ok
}

// A numeric agent id is the MCP proxy's process id: true once that process has ended.
// Other ids (tests, other front ends) never count as ended.
agent_process_gone :: proc(id: string) -> bool {
	pid, ok := strconv.parse_int(id)
	if !ok || pid <= 0 do return false
	if posix.kill(posix.pid_t(pid), posix.Signal(0)) == .OK do return false
	return posix.errno() == .ESRCH
}

cursor_set_file :: proc(c: ^Peer) {
	if c.file == app.file_path do return
	delete(c.file)
	c.file = strings.clone(app.file_path)
}

agent_of :: proc(obj: json.Object) -> (Agent_Info, bool) {
	a, ok := obj["agent"].(json.Object)
	if !ok do return {}, false
	info := Agent_Info {
		id     = string(a["id"].(json.String) or_else "agent"),
		client = string(a["client"].(json.String) or_else ""),
		title  = string(a["title"].(json.String) or_else ""),
	}
	return info, true
}

// ---------------------------------------------------------------- what changed

Node_Sig :: struct {
	hash:   u64,
	parent: int,
	box:    [4]f32,
}

// The document's layers (not instance copies or library layers) as they stand, to tell
// afterwards what a request created, changed or deleted.
doc_signature :: proc(doc: ^engine.Document) -> map[int]Node_Sig {
	sig := make(map[int]Node_Sig, len(doc.nodes), context.temp_allocator)
	for &n in doc.nodes do if !n.ghost && !n.imported do sig[n.uid] = {doc_signature_hash(&n), n.parent, engine.node_page_box(&n)}
	return sig
}

MUTATING :: [?]string{"create_nodes", "update_nodes", "delete_nodes", "batch", "reorder", "undo", "redo", "rename_references"}

presence_wants_signature :: proc(obj: json.Object) -> bool {
	if !settings.agent_cursors do return false
	if _, ok := obj["agent"].(json.Object); !ok do return false
	method := string(obj["method"].(json.String) or_else "")
	for m in MUTATING do if m == method do return true
	return false
}

// After an agent's request: its cursor shows up (or stays), and visits and flashes what the
// request touched.
presence_after_request :: proc(obj: json.Object, before: map[int]Node_Sig, ok: bool) {
	if !settings.agent_cursors do return
	agent, is_agent := agent_of(obj)
	if !is_agent do return
	c := agent_cursor(agent)
	now := platform_time()
	cursor_set_file(c)
	method := string(obj["method"].(json.String) or_else "")
	params, _ := obj["params"].(json.Object)

	touched := make([dynamic]Visit, context.temp_allocator)
	scan := make([dynamic]bool, context.temp_allocator) // flash with a scan line
	if ok && before != nil {
		doc := &app.doc
		created := make(map[int]bool, 8, context.temp_allocator)
		for &n in doc.nodes do if !n.ghost && !n.imported && n.uid not_in before do created[n.uid] = true
		for &n in doc.nodes {
			if n.ghost || n.imported || !node_shown(&n) do continue
			s, existed := before[n.uid]
			fresh := !existed
			if fresh {
				if n.parent in created do continue // its parent's flash covers it
			} else {
				if s.hash == doc_signature_hash(&n) do continue
				inside := false
				for p := n.parent; p != 0; {
					if p in created {inside = true; break}
					pn, _ := engine.doc_find_uid(doc, p)
					if pn == nil do break
					p = pn.parent
				}
				if inside do continue
			}
			append(&touched, Visit{uid = n.uid})
			append(&scan, fresh)
		}
		// deleted layers (not those whose parent went with them)
		for uid, s in before {
			if n, _ := engine.doc_find_uid(doc, uid); n != nil do continue
			if s.parent in before {
				if pn, _ := engine.doc_find_uid(doc, s.parent); pn == nil do continue // went with its parent
			}
			append(&touched, Visit{box = s.box, uid = -1})
			append(&scan, false)
		}
		if method == "reorder" {
			if n, _ := engine.doc_find(doc, string(params["id"].(json.String) or_else "")); n != nil {
				append(&touched, Visit{uid = n.uid})
				append(&scan, false)
			}
		}
	}
	// a capture or a selection: the cursor goes there
	switch method {
	case "screenshot":
		if shot.uid != 0 {
			append(&touched, Visit{uid = shot.uid})
			append(&scan, true)
		}
	case "select":
		if r, has := bounds_of(app.sel[:]); has {
			append(&touched, Visit{box = r})
			append(&scan, false)
		}
	}
	if len(touched) == 0 {
		presence_poke(c, now)
		return
	}
	presence_schedule(c, touched[:], scan[:], now, flash = !(method == "select"))
}

doc_signature_hash :: proc(n: ^engine.Node) -> u64 {
	h := hash.fnv64a(transmute([]u8)n.id)
	parent := n.parent
	h = hash.fnv64a(mem.ptr_to_bytes(&parent), h)
	for p in n.props {
		h = hash.fnv64a(transmute([]u8)p.key, h)
		h = hash.fnv64a(transmute([]u8)p.raw, h)
	}
	return h
}

// On a page that is shown.
node_shown :: proc(n: ^engine.Node) -> bool {
	top := n
	for top.parent != 0 {
		p, _ := engine.doc_find_uid(&app.doc, top.parent)
		if p == nil do break
		top = p
	}
	return !app.page_hidden[top.uid]
}

// Queues the visits after those still pending (but never far behind), and the flashes for
// when the cursor gets there.
presence_schedule :: proc(c: ^Peer, touched: []Visit, scan: []bool, now: f64, flash: bool) {
	t := max(now, c.busy_until)
	if t - now > 1.5 do t = now + 0.2 // a long backlog: catch up
	shown := cursor_shown(c, now)
	n := min(len(touched), MAX_FLASHES)
	visits := min(n, MAX_VISITS)
	for i in 0 ..< n {
		v := touched[i]
		if i < visits {
			v.at = t
			append(&c.visits, v)
		}
		// the cursor gets there first (pen.dev: +300 ms when it travels)
		arrive := t + (0.4 if shown || i > 0 else 0.05) + f64(rand.float32()) * 0.05
		gone := v.uid < 0
		if gone do v.uid = 0
		if i < visits do c.visits[len(c.visits) - 1].uid = v.uid
		if flash do append(&flashes, Flash{file = strings.clone(app.file_path), uid = v.uid, box = v.box, start = arrive, color = c.color, scan = scan[i], gone = gone})
		if i < visits - 1 do t += VISIT_STEP
	}
	c.busy_until = t + VISIT_STEP
	c.active = now
}

// Activity with nothing to point at: a cursor that had faded comes back where it was, or
// near the middle of the view the first time.
presence_poke :: proc(c: ^Peer, now: f64) {
	if cursor_shown(c, now) {
		c.active = now
		return
	}
	t := c.target
	if c.appear == 0 {
		mid := to_page({app.canvas.x + app.canvas.w / 2, app.canvas.y + app.canvas.h / 2})
		spread := [2]f32{app.canvas.w, app.canvas.h} * 0.25 / app.zoom
		t = mid + {(rand.float32() - 0.5) * spread.x, (rand.float32() - 0.5) * spread.y}
	}
	cursor_activate(c, t, now)
}

cursor_linger :: proc(c: ^Peer) -> f64 {
	return PERSON_LINGER if c.person else AGENT_LINGER
}

cursor_shown :: proc(c: ^Peer, now: f64) -> bool {
	return c.appear != 0 && now - c.active <= cursor_linger(c) + CURSOR_FADE_OUT
}

cursor_activate :: proc(c: ^Peer, target: [2]f32, now: f64) {
	if !cursor_shown(c, now) {
		c.cur = target
		c.appear = now
	}
	c.target = target
	c.active = now
}

cursor_opacity :: proc(c: ^Peer, now: f64) -> f32 {
	since := now - c.appear
	idle := now - c.active - cursor_linger(c)
	if since < CURSOR_FADE_IN do return ease_out_cubic(f32(since / CURSOR_FADE_IN))
	if idle > 0 do return 1 - ease_out_cubic(clamp(f32(idle / CURSOR_FADE_OUT), 0, 1))
	return 1
}

ease_out_cubic :: proc(t: f32) -> f32 {
	u := 1 - clamp(t, 0, 1)
	return 1 - u * u * u
}

// Biased toward the middle, so repeated visits to one layer do not stack (pen.dev).
pick_target :: proc(box: [4]f32) -> [2]f32 {
	tri :: proc() -> f32 {return (rand.float32() + rand.float32()) * 0.5}
	return {box[0] + box[2] * tri(), box[1] + box[3] * tri()}
}

// ---------------------------------------------------------------- the `presence` request

// Sets where a participant is: {"id", "name", "color": "#RRGGBB", "x", "y" (page
// coordinates), "kind": "person" | "agent", "leave": true}. For a multiplayer link, or any
// tool that wants a cursor of its own.
api_presence :: proc(b: ^strings.Builder, params: json.Object) -> string {
	id := string(params["id"].(json.String) or_else "")
	if id == "" do return "id is required"
	person := string(params["kind"].(json.String) or_else "person") != "agent"
	key := fmt.tprintf("%s:%s", "person" if person else "agent", id)
	if params["leave"].(json.Boolean) or_else false {
		for c, i in cursors do if c.key == key {
			ordered_remove(&cursors, i)
			break
		}
		fmt.sbprintf(b, `{{"cursors":%d}}`, len(cursors))
		return ""
	}
	name := string(params["name"].(json.String) or_else id)
	color := palette_color(name)
	if hex, ok := params["color"].(json.String); ok {
		if v, pok := strconv.parse_u64_of_base(strings.trim_prefix(string(hex), "#"), 16); pok do color = hex_color(u32(v))
	}
	c := presence_cursor(key, name, color, person)
	c.color = color
	cursor_set_file(c)
	now := platform_time()
	x, xok := params["x"].(json.Float)
	y, yok := params["y"].(json.Float)
	if xok && yok do cursor_activate(c, {f32(x), f32(y)}, now)
	else do presence_poke(c, now)
	fmt.sbprintf(b, `{{"cursors":%d}}`, len(cursors))
	return ""
}

// ---------------------------------------------------------------- motion

// Whether presence needs frames, and whether at full rate (travel, flashes) or slowly (a
// resting cursor swaying).
presence_animating :: proc(now: f64) -> (busy, fast: bool) {
	if !settings.agent_cursors || app.tab < 0 do return false, false
	for &c in cursors {
		if c.file != app.file_path do continue
		if len(c.visits) > 0 do return true, true
		if !cursor_shown(&c, now) do continue
		busy = true
		moving := linalg_len((c.target - c.cur) * app.zoom) > 0.3
		if moving || now - c.appear < CURSOR_FADE_IN || now - c.active > cursor_linger(&c) do fast = true
	}
	for f in flashes do if f.file == app.file_path do return true, true
	return
}

linalg_len :: proc(v: [2]f32) -> f32 {
	return math.sqrt(v.x * v.x + v.y * v.y)
}

// Advances every cursor; starts the visits that are due; drops what has faded.
presence_tick :: proc(now: f64) {
	dt := f32(clamp(now - presence_clock, 0, MAX_STEP))
	presence_clock = now
	for i := len(cursors) - 1; i >= 0; i -= 1 {
		c := &cursors[i]
		for len(c.visits) > 0 && c.visits[0].at <= now {
			v := c.visits[0]
			ordered_remove(&c.visits, 0)
			box := v.box
			if v.uid != 0 {
				n, _ := engine.doc_find_uid(&app.doc, v.uid)
				if n == nil do continue
				box = engine.node_page_box(n)
			}
			cursor_activate(c, pick_target(box), now)
		}
		k := math.exp(-c.decay * dt)
		c.cur = c.target + (c.cur - c.target) * k
		resting: f32 = 1 if now - c.active > WOBBLE_REST else 0
		c.wobble = resting + (c.wobble - resting) * math.exp(-WOBBLE_DECAY * dt)
		if c.person && c.appear != 0 && !cursor_shown(c, now) {
			// people come back through `presence`; their cursor is dropped once faded
			delete(c.key)
			delete(c.name)
			delete(c.file)
			delete(c.visits)
			ordered_remove(&cursors, i)
		}
	}
	for i := len(flashes) - 1; i >= 0; i -= 1 {
		f := &flashes[i]
		hold := FLASH_HOLD_LONG if f.long else FLASH_HOLD
		if now - f.start > FLASH_ATTACK + hold + FLASH_RELEASE {
			delete(f.file)
			ordered_remove(&flashes, i)
		}
	}
}

// ---------------------------------------------------------------- drawing

// Flashes around touched layers, and the glow of placeholder frames: over the document,
// under the selection.
draw_presence_effects :: proc(vg: ^nvg.Context) {
	if !settings.agent_cursors do return
	now := platform_time()
	working := false // an agent is around: placeholders move
	for &c in cursors do if !c.person && c.file == app.file_path && cursor_shown(&c, now) do working = true
	draw_placeholders(vg, now, working)
	for &f in flashes {
		if f.file != app.file_path do continue
		t := f32(now - f.start)
		if t < 0 do continue
		box := f.box
		if f.uid != 0 {
			n, _ := engine.doc_find_uid(&app.doc, f.uid)
			if n == nil do continue
			box = engine.node_page_box(n)
		}
		if box[2] * app.zoom <= 1 && box[3] * app.zoom <= 1 do continue
		hold := f32(FLASH_HOLD_LONG if f.long else FLASH_HOLD)
		alpha, grow: f32 = 1, 0
		if t < FLASH_ATTACK {
			e := 1 - (1 - t / FLASH_ATTACK) * (1 - t / FLASH_ATTACK)
			alpha, grow = e, 1 - e
		} else if t > FLASH_ATTACK + hold {
			r := clamp((t - FLASH_ATTACK - hold) / FLASH_RELEASE, 0, 1)
			r = r * r * (3 - 2 * r)
			alpha, grow = 1 - r, r * 0.1
		}
		// the ring closes in from 30 px out to 5 units around the layer; for a deleted one it
		// folds into the middle of where the layer was
		g := 5 + 30 * grow / app.zoom
		if f.gone {
			total := FLASH_ATTACK + hold + FLASH_RELEASE
			k := ease_out_cubic(clamp(t / total, 0, 1))
			g = -min(box[2], box[3]) * 0.9 * k
			alpha = 1 - k * k
		}
		x, y := box[0] - g / 2, box[1] - g / 2
		w, h := box[2] + g, box[3] + g
		radius: f32 = 0 if min(box[2], box[3]) < 20 else 3 * app.zoom
		a := to_screen({x, y})
		sw, sh := w * app.zoom, h * app.zoom
		col := f.color
		if f.scan && t > 0.04 {
			// a band of colour sweeps down once
			m := clamp((t - 0.04) / 0.3, 0, 1)
			mid := -sh / 2 + (sh + sh) * m
			top := a.y + mid - sh / 2
			nvg.Save(vg)
			nvg.IntersectScissor(vg, a.x, a.y, sw, sh)
			nvg.BeginPath(vg)
			nvg.Rect(vg, a.x, top, sw, sh)
			nvg.FillPaint(vg, nvg.LinearGradient(0, top, 0, top + sh, {col.r, col.g, col.b, 0}, {col.r, col.g, col.b, 0.4 * alpha}))
			nvg.Fill(vg)
			nvg.Restore(vg)
		}
		nvg.BeginPath(vg)
		nvg.RoundedRect(vg, a.x, a.y, sw, sh, radius)
		nvg.StrokeColor(vg, {col.r, col.g, col.b, alpha})
		nvg.StrokeWidth(vg, 2)
		nvg.Stroke(vg)
	}
}

// pen.dev's generating effect: two soft lights circling inside a placeholder frame, and a
// blue outline. They turn only while an agent is around (frames cost power).
draw_placeholders :: proc(vg: ^nvg.Context, now: f64, moving: bool) {
	for &n in app.doc.nodes {
		if n.kind != .Frame || n.ghost || !n.enabled do continue
		i := engine.prop_index(&n, "placeholder")
		if i < 0 || n.props[i].raw != "true" || !node_shown(&n) do continue
		a := to_screen({n.x, n.y})
		w, h := n.w * app.zoom, n.h * app.zoom
		if w < 2 || h < 2 || a.x > app.canvas.x + app.canvas.w || a.y > app.canvas.y + app.canvas.h || a.x + w < app.canvas.x || a.y + h < app.canvas.y do continue
		size := max(w, h)
		r, blur, off := size * 0.4, size * 0.2, size * 0.5
		angle := f32(hash.fnv32a(transmute([]u8)n.id) % 628) / 100
		if moving do angle += f32(now) * 0.5
		cx, cy := a.x + w / 2, a.y + h / 2
		glow := nvg.Color{PRESENCE_BLUE.r, PRESENCE_BLUE.g, PRESENCE_BLUE.b, 0.5}
		nvg.Save(vg)
		nvg.IntersectScissor(vg, a.x, a.y, w, h)
		for s in ([2]f32{1, -1}) {
			px, py := cx + s * math.cos(angle) * off, cy + s * math.sin(angle) * off
			nvg.BeginPath(vg)
			nvg.Rect(vg, px - r - blur, py - r - blur, 2 * (r + blur), 2 * (r + blur))
			nvg.FillPaint(vg, nvg.RadialGradient(px, py, max(r - blur, 0), r + blur, glow, {glow.r, glow.g, glow.b, 0}))
			nvg.Fill(vg)
		}
		nvg.Restore(vg)
		nvg.BeginPath(vg)
		nvg.RoundedRect(vg, a.x, a.y, w, h, 5)
		nvg.StrokeColor(vg, PRESENCE_BLUE)
		nvg.StrokeWidth(vg, 2)
		nvg.Stroke(vg)
	}
}

// The cursors with their names, over everything on the canvas. One outside the view sits
// at its edge, pointing the way.
draw_cursors :: proc(vg: ^nvg.Context) {
	if !settings.agent_cursors do return
	if len(cursor_cmds) == 0 do cursor_cmds, _, _ = engine.parse_svg_path(CURSOR_PATH)
	now := platform_time()
	cv := app.canvas
	for &c in cursors {
		if c.file != app.file_path || !cursor_shown(&c, now) do continue
		alpha := cursor_opacity(&c, now)
		if alpha <= 0.01 do continue
		p := to_screen(c.cur)
		if !c.person {
			amp := WOBBLE_AMPLITUDE * c.wobble
			p += {math.cos(f32(now) * WOBBLE_SPEED.x + c.phase) * amp, math.sin(f32(now) * WOBBLE_SPEED.y + c.phase) * amp}
		}
		inset: f32 = 10
		inside := p.x >= cv.x + inset && p.y >= cv.y + inset && p.x <= cv.x + cv.w - inset && p.y <= cv.y + cv.h - inset
		if !inside {
			draw_cursor_edge(vg, &c, p, alpha)
			continue
		}
		nvg.Save(vg)
		nvg.GlobalAlpha(vg, alpha)
		// shadow, then the arrow in the participant's colour with a white edge
		for pass in 0 ..< 2 {
			nvg.BeginPath(vg)
			off := [2]f32{0, 1} if pass == 0 else {0, 0}
			for cmd in cursor_cmds do engine.path_cmd(vg, cmd, {4 - (p.x + off.x), 5 - (p.y + off.y)}, 1, 1)
			if pass == 0 {
				nvg.StrokeColor(vg, {0, 0, 0, 0.35})
				nvg.StrokeWidth(vg, 3)
				nvg.Stroke(vg)
			} else {
				nvg.FillColor(vg, c.color)
				nvg.Fill(vg)
				nvg.StrokeColor(vg, {1, 1, 1, 1})
				nvg.StrokeWidth(vg, 1.5)
				nvg.Stroke(vg)
			}
		}
		draw_cursor_label(vg, &c, p + {14, 15})
		nvg.Restore(vg)
	}
}

draw_cursor_label :: proc(vg: ^nvg.Context, c: ^Peer, at: [2]f32) {
	nvg.FontFace(vg, "ui")
	nvg.FontSize(vg, 11)
	tw := nvg.TextBounds(vg, 0, 0, c.name)
	box := [4]f32{at.x, at.y, tw + 10, 16}
	nvg.BeginPath(vg)
	nvg.RoundedRect(vg, box[0], box[1] + 1, box[2], box[3], 3)
	nvg.FillColor(vg, {0, 0, 0, 0.25})
	nvg.Fill(vg)
	nvg.BeginPath(vg)
	nvg.RoundedRect(vg, box[0], box[1], box[2], box[3], 3)
	nvg.FillColor(vg, c.color)
	nvg.Fill(vg)
	nvg.TextAlign(vg, .LEFT, .MIDDLE)
	nvg.FillColor(vg, {1, 1, 1, 1})
	nvg.Text(vg, box[0] + 5, box[1] + box[3] / 2 + 0.5, c.name)
}

// A cursor out of view: its name at the canvas edge, with a small arrow toward it.
draw_cursor_edge :: proc(vg: ^nvg.Context, c: ^Peer, p: [2]f32, alpha: f32) {
	cv := app.canvas
	nvg.FontFace(vg, "ui")
	nvg.FontSize(vg, 11)
	w := nvg.TextBounds(vg, 0, 0, c.name) + 10
	h: f32 = 16
	m: f32 = 8
	x := clamp(p.x - w / 2, cv.x + m, cv.x + cv.w - w - m)
	y := clamp(p.y - h / 2, cv.y + m, cv.y + cv.h - h - m)
	nvg.Save(vg)
	nvg.GlobalAlpha(vg, alpha)
	draw_cursor_label(vg, c, {x, y})
	// the arrow, on the side facing the cursor
	mid := [2]f32{x + w / 2, y + h / 2}
	d := p - mid
	l := linalg_len(d)
	if l > 0 {
		d /= l
		tip := mid + d * (max(w, h) / 2 + 7)
		side := [2]f32{-d.y, d.x} * 4
		base := tip - d * 6
		nvg.BeginPath(vg)
		nvg.MoveTo(vg, tip.x, tip.y)
		nvg.LineTo(vg, base.x + side.x, base.y + side.y)
		nvg.LineTo(vg, base.x - side.x, base.y - side.y)
		nvg.ClosePath(vg)
		nvg.FillColor(vg, c.color)
		nvg.Fill(vg)
	}
	nvg.Restore(vg)
}
