#+build !js
package agentic_design

import "engine"

import "core:encoding/json"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:strings"

// agentic-design              open the editor with the default document
// agentic-design <file.pen>   open the editor with a document
// agentic-design mcp          run the MCP server over stdio (starts the editor if needed)
// agentic-design --version    print the version
// agentic-design cloud-vectors <vectors.json>   run the cloud protocol's test vectors
// agentic-design font-instance <font> <tag=value>... <out.ttf>
//                             write a static instance of a variable font (to check the
//                             instancer against fontTools)
main :: proc() {
	if len(os.args) > 1 && (os.args[1] == "--version" || os.args[1] == "version") {
		fmt.println(VERSION)
		return
	}
	if len(os.args) > 1 && os.args[1] == "mcp" {
		mcp_main()
		return
	}
	if len(os.args) > 5 && os.args[1] == "cloud-sim" {
		n, _ := strconv.parse_int(os.args[3])
		steps, _ := strconv.parse_int(os.args[4])
		seed, _ := strconv.parse_int(os.args[5])
		cloud_sim_main(os.args[2], n, steps, seed)
		return
	}
	if len(os.args) > 3 && os.args[1] == "cloud-diff" {
		cloud_diff_main(os.args[2], os.args[3], len(os.args) > 4 && os.args[4] == "-v")
		return
	}
	if len(os.args) > 2 && os.args[1] == "cloud-vectors" {
		cloud_vectors_main(os.args[2])
		return
	}
	if len(os.args) > 3 && os.args[1] == "font-instance" {
		font_instance_main(os.args[2], os.args[3:len(os.args) - 1], os.args[len(os.args) - 1])
		return
	}
	// the installed app opens on the Dashboard; a build from the repository (tests, agents'
	// test windows) opens its scratch file as before
	path := os.args[1] if len(os.args) > 1 else ("" if bundle_path() != "" else default_document_path())
	app_main(path)
}

// <repo>/designs/untitled.pen next to the build directory, or for the installed app a
// scratch file in Application Support (made on first launch; no folder the system asks
// permission for).
default_document_path :: proc() -> string {
	if bundle_path() != "" {
		path := fmt.aprintf("%s/untitled.pen", support_dir())
		if !os.exists(path) {
			_ = os.make_directory_all(support_dir())
			_ = os.write_entire_file(path, "{\n  \"version\": \"2.21\",\n  \"children\": []\n}\n")
		}
		return path
	}
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil do return "untitled.pen"
	return fmt.aprintf("%s/designs/untitled.pen", os.dir(os.dir(exe)))
}

font_instance_main :: proc(in_path: string, settings: []string, out_path: string) {
	data, err := os.read_entire_file(in_path, context.allocator)
	if err != nil {
		fmt.eprintln("cannot read", in_path)
		os.exit(1)
	}
	axes := make([dynamic]engine.Var_Axis)
	for s in settings {
		i := strings.index_byte(s, '=')
		if i < 0 do continue
		v, _ := strconv.parse_f32(s[i + 1:])
		append(&axes, engine.Var_Axis{s[:i], v})
	}
	out, ok := engine.varfont_instance(data, 0, axes[:])
	if !ok {
		fmt.eprintln("not a TrueType variable font")
		os.exit(1)
	}
	_ = os.write_entire_file(out_path, out)
}

// agentic-design cloud-vectors <vectors.json>: runs the protocol's test vectors (cloud-ops.md §8)
// through engine.ops_apply and the .pen serializer; prints one line per vector, exits 1 on a failure.
cloud_vectors_main :: proc(path: string) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintln("cannot read", path)
		os.exit(1)
	}
	root, perr := json.parse(data, .JSON, false, context.allocator)
	if perr != nil {
		fmt.eprintln("not JSON:", path)
		os.exit(1)
	}
	failed, room_only := 0, 0
	vectors, _ := root.(json.Object)["vectors"].(json.Array)
	for vv in vectors {
		v, _ := vv.(json.Object)
		name := string(v["name"].(json.String) or_else "?")
		if v["room"].(json.Boolean) or_else false {
			fmt.println("skip", name, "(room only: tombstones)")
			room_only += 1
			continue
		}
		doc: engine.Document
		engine.doc_load(&doc, string(v["start"].(json.String) or_else ""))
		state: engine.Cloud_State
		if s, ok := v["start_sorts"].(json.Object); ok do for id, k in s do state.sorts[strings.clone(id)] = strings.clone(string(k.(json.String) or_else ""))
		batches := make(map[string]json.Array)
		if c, ok := v["clients"].(json.Object); ok {
			for _, list in c do for b in list.(json.Array) or_else nil {
				bo, _ := b.(json.Object)
				batches[string(bo["batch"].(json.String) or_else "")] = bo["ops"].(json.Array) or_else nil
			}
		}
		expect, _ := v["expect"].(json.Object)
		problems := make([dynamic]string)
		seq := 0
		for bid in v["server_order"].(json.Array) or_else nil {
			id := string(bid.(json.String) or_else "")
			ops := make([dynamic]engine.Op)
			batch := batches[id] // (a copy: see engine.connector_obstacles)
			for o in batch {
				op, ok := engine.op_parse(o)
				if !ok do append(&problems, fmt.aprintf("%s: an op does not parse", id))
				append(&ops, op)
			}
			res := engine.ops_apply(&doc, &state, ops[:])
			want_nack := string(expect["nacks"].(json.Object)[id].(json.String) or_else "") if expect["nacks"] != nil else ""
			if res.ok {
				seq += 1
				if want_nack != "" do append(&problems, fmt.aprintf("%s: acked, expected nack %s", id, want_nack))
				if a, has := expect["acks"].(json.Object)[id]; has && int(a.(json.Float) or_else 0) != seq do append(&problems, fmt.aprintf("%s: seq %d, expected %v", id, seq, a))
				want_skip := 0
				if sk, has := expect["skipped"].(json.Object)[id]; has do want_skip = len(sk.(json.Array) or_else nil)
				if len(res.skipped) != want_skip do append(&problems, fmt.aprintf("%s: %d ops skipped, expected %d", id, len(res.skipped), want_skip))
			} else if want_nack != res.reason {
				append(&problems, fmt.aprintf("%s: nack %s, expected %s", id, res.reason, want_nack if want_nack != "" else "an ack"))
			}
		}
		engine.pages_prune(&doc)
		got := engine.doc_serialize(&doc)
		want := string(expect["pen"].(json.String) or_else "")
		if got != want do append(&problems, "the .pen differs from the expected bytes")
		if len(problems) == 0 {
			fmt.println("ok  ", name)
		} else {
			failed += 1
			fmt.println("FAIL", name)
			for p in problems do fmt.println("     ", p)
			if got != want {
				_ = os.write_entire_file(fmt.tprintf("/tmp/cloud-vector-%d.got.pen", failed), transmute([]u8)got)
				_ = os.write_entire_file(fmt.tprintf("/tmp/cloud-vector-%d.want.pen", failed), transmute([]u8)want)
			}
		}
	}
	fmt.printfln("%d of %d vectors pass (%d room-only skipped)", len(vectors) - room_only - failed, len(vectors) - room_only, room_only)
	if failed > 0 do os.exit(1)
}

// agentic-design cloud-diff <before.pen> <after.pen> [-v]: the ops that turn one state into the
// other (engine.ops_diff), applied to the first (engine.ops_apply); passes when the result saves
// to the same bytes as the second. -v prints the ops.
cloud_diff_main :: proc(before_path, after_path: string, verbose: bool) {
	load :: proc(path: string, doc: ^engine.Document) {
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil || !engine.doc_load(doc, string(data)) {
			fmt.eprintln("cannot load", path)
			os.exit(2)
		}
	}
	before, after: engine.Document
	load(before_path, &before)
	load(after_path, &after)
	state: engine.Cloud_State
	engine.sorts_assign(&before, &state)
	ops := engine.ops_diff(before.nodes[:], after.nodes[:], before.header[:], after.header[:], &state, include_derived = true)
	if verbose {
		for op in ops {
			b := strings.builder_make(context.temp_allocator)
			engine.op_write(&b, op)
			fmt.println(strings.to_string(b))
		}
	}
	// the receiver: the wire form parsed again, applied to its own copy of `before`
	wire := make([dynamic]engine.Op)
	for op in ops {
		b := strings.builder_make(context.temp_allocator)
		engine.op_write(&b, op)
		v, _ := json.parse_string(strings.to_string(b), .JSON, false, context.allocator)
		parsed, ok := engine.op_parse(v)
		if !ok {
			fmt.println("FAIL an op does not parse back:", strings.to_string(b))
			os.exit(1)
		}
		append(&wire, parsed)
	}
	recv: engine.Document
	load(before_path, &recv)
	rstate: engine.Cloud_State
	engine.sorts_assign(&recv, &rstate)
	res := engine.ops_apply(&recv, &rstate, wire[:])
	if !res.ok {
		fmt.println("FAIL the batch was refused:", res.reason)
		os.exit(1)
	}
	engine.pages_prune(&recv)
	engine.pages_prune(&after)
	got, want := engine.doc_serialize(&recv), engine.doc_serialize(&after)
	if got != want {
		_ = os.write_entire_file("/tmp/cloud-diff.got.pen", transmute([]u8)got)
		_ = os.write_entire_file("/tmp/cloud-diff.want.pen", transmute([]u8)want)
		fmt.printfln("FAIL %d ops; the result differs (/tmp/cloud-diff.got.pen vs want.pen)", len(ops))
		os.exit(1)
	}
	fmt.printfln("ok   %d ops, %d skipped; the result saves byte-identical", len(ops), len(res.skipped))
}

// agentic-design cloud-sim <start.pen> <clients> <steps> <seed>: a room and several clients in
// one process (engine.Sync_Client and ops_apply), each making random edits that reach the room
// and come back in random interleavings. Passes when, with everything delivered, every client
// shows exactly the room's document.
cloud_sim_main :: proc(start_path: string, nclients, steps, seed: int) {
	data, err := os.read_entire_file(start_path, context.allocator)
	if err != nil {
		fmt.eprintln("cannot read", start_path)
		os.exit(2)
	}
	r := rand.create(u64(seed))
	context.random_generator = rand.default_random_generator(&r)
	Msg :: struct {
		kind:  enum {Ops, Ack, Nack},
		batch: string,
		seq:   int,
		ops:   []engine.Op,
	}
	room: engine.Document
	room_state: engine.Cloud_State
	engine.doc_load(&room, string(data))
	engine.sorts_assign(&room, &room_state)
	seq := 0
	clients := make([]engine.Sync_Client, nclients)
	shown := make([]engine.Document, nclients)
	shown_state := make([]engine.Cloud_State, nclients)
	for i in 0 ..< nclients do engine.sync_init(&clients[i], string(data), 0, &shown[i], &shown_state[i], fmt.aprintf("c%d", i))
	Inbound :: struct {
		from:  int,
		batch: string,
		ops:   []engine.Op,
	}
	room_in := make([dynamic]Inbound)
	outbox := make([][dynamic]Msg, nclients)
	acks, nacks, edits := 0, 0, 0

	rid :: proc() -> string {
		a := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
		b := make([]u8, 10)
		for &c in b do c = a[rand.int_max(len(a))]
		return string(b)
	}
	// a random step on what client i sees
	edit :: proc(doc: ^engine.Document, state: ^engine.Cloud_State) -> []engine.Op {
		live := make([dynamic]^engine.Node, context.temp_allocator)
		frames := make([dynamic]^engine.Node, context.temp_allocator)
		for &n in doc.nodes do if !n.imported && !n.ghost {
			append(&live, &n)
			if n.kind == .Frame do append(&frames, &n)
		}
		if len(live) == 0 do return nil
		n := live[rand.int_max(len(live))]
		ops := make([dynamic]engine.Op)
		switch rand.int_max(7) {
		case 0, 1:
			append(&ops, engine.Op{kind = .Set, node = n.id, key = "fill", raw = fmt.aprintf("\"#%06X\"", rand.int_max(0xFFFFFF))})
		case 2:
			append(&ops, engine.Op{kind = .Set, node = n.id, key = "opacity", raw = fmt.aprintf("%v", f32(rand.int_max(10)) / 10)})
		case 3:
			if len(frames) == 0 do return nil
			p := frames[rand.int_max(len(frames))]
			last := ""
			for &m in doc.nodes do if m.parent == p.uid && m.slot_of == "" {
				if k := state.sorts[m.id] or_else ""; k > last do last = k
			}
			id := rid()
			props := make([]engine.Prop, 4)
			props[0] = {"type", "\"rectangle\""}
			props[1] = {"id", fmt.aprintf("\"%s\"", id)}
			props[2] = {"width", "10"}
			props[3] = {"height", "10"}
			append(&ops, engine.Op{kind = .Create, node = id, parent = p.id, sort = strings.clone(engine.sort_between(last, "")), props = props})
		case 4:
			if n.parent == 0 do return nil // keep the top level
			append(&ops, engine.Op{kind = .Delete, node = n.id})
		case 5:
			if len(frames) == 0 || n.parent == 0 do return nil
			p := frames[rand.int_max(len(frames))]
			if p.uid == n.uid || engine.is_descendant(doc, p.uid, n.uid) do return nil
			append(&ops, engine.Op{kind = .Move, node = n.id, parent = p.id, sort = strings.clone(engine.sort_between("", state.sorts[n.id] or_else "a0"))})
		case 6:
			append(&ops, engine.Op{kind = .Hset, key = fmt.aprintf("variables/v%d", rand.int_max(5)), raw = fmt.aprintf("{{\"type\":\"number\",\"value\":%d}}", rand.int_max(100))})
		}
		return ops[:]
	}
	deliver_room :: proc(room: ^engine.Document, room_state: ^engine.Cloud_State, seq: ^int, in_: Inbound, outbox: [][dynamic]Msg, acks, nacks: ^int) {
		res := engine.ops_apply(room, room_state, in_.ops)
		if !res.ok {
			append(&outbox[in_.from], Msg{kind = .Nack, batch = in_.batch})
			nacks^ += 1
			return
		}
		seq^ += 1
		acks^ += 1
		for i in 0 ..< len(outbox) {
			if i == in_.from do append(&outbox[i], Msg{kind = .Ack, batch = in_.batch, seq = seq^})
			else do append(&outbox[i], Msg{kind = .Ops, seq = seq^, ops = in_.ops})
		}
	}
	deliver_client :: proc(c: ^engine.Sync_Client, m: Msg) {
		switch m.kind {
		case .Ops: engine.sync_remote(c, m.seq, m.ops)
		case .Ack: engine.sync_ack(c, m.batch, m.seq)
		case .Nack: engine.sync_nack(c, m.batch)
		}
	}
	for _ in 0 ..< steps {
		switch rand.int_max(3) {
		case 0:
			i := rand.int_max(nclients)
			ops := engine.ops_clone(edit(&shown[i], &shown_state[i]))
			if len(ops) == 0 do continue
			res := engine.ops_apply(&shown[i], &shown_state[i], ops)
			if !res.ok do continue
			edits += 1
			if os.get_env("AGENTIC_SIM_TRACE", context.temp_allocator) != "" {
				for op in ops {
					b := strings.builder_make(context.temp_allocator)
					engine.op_write(&b, op)
					fmt.printfln("c%d edit %d: %s", i, edits, strings.to_string(b))
				}
			}
			id := engine.sync_local(&clients[i], ops)
			append(&room_in, Inbound{i, id, ops})
		case 1:
			if len(room_in) == 0 do continue
			// the room takes batches in arrival order per client, but clients interleave
			k := rand.int_max(len(room_in))
			for j in 0 ..< k do if room_in[j].from == room_in[k].from {k = j; break}
			in_ := room_in[k]
			ordered_remove(&room_in, k)
			deliver_room(&room, &room_state, &seq, in_, outbox, &acks, &nacks)
		case 2:
			i := rand.int_max(nclients)
			if len(outbox[i]) == 0 do continue
			m := outbox[i][0]
			ordered_remove(&outbox[i], 0)
			deliver_client(&clients[i], m)
		}
		free_all(context.temp_allocator)
	}
	for len(room_in) > 0 {
		in_ := room_in[0]
		ordered_remove(&room_in, 0)
		deliver_room(&room, &room_state, &seq, in_, outbox, &acks, &nacks)
	}
	for i in 0 ..< nclients do for len(outbox[i]) > 0 {
		m := outbox[i][0]
		ordered_remove(&outbox[i], 0)
		deliver_client(&clients[i], m)
	}
	engine.pages_prune(&room)
	want := engine.doc_serialize(&room)
	bad := 0
	for i in 0 ..< nclients {
		engine.pages_prune(&shown[i])
		got := engine.doc_serialize(&shown[i])
		if got != want {
			bad += 1
			_ = os.write_entire_file(fmt.tprintf("/tmp/cloud-sim-client%d.pen", i), transmute([]u8)got)
		}
		if len(clients[i].pending) != 0 do bad += 1
	}
	if bad > 0 {
		_ = os.write_entire_file("/tmp/cloud-sim-room.pen", transmute([]u8)want)
		fmt.printfln("FAIL seed %d: %d of %d clients differ from the room (%d edits, %d acks, %d nacks)", seed, bad, nclients, edits, acks, nacks)
		os.exit(1)
	}
	fmt.printfln("ok   seed %d: %d clients converge (%d edits, %d acks, %d nacks, seq %d)", seed, nclients, edits, acks, nacks, seq)
}
