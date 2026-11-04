package pencore

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "../engine"

// pencore.wasm: the engine's document model, the cloud protocol's ops (engine/ops.odin) and the
// .pen serializer, for the server's DocRoom and its tests (cloud-ops.md §7). No GPU, files or
// network. JSON and .pen text in and out over linear memory:
//
//   pc_alloc(len) -> ptr, pc_free(ptr)                    memory for the host to write into
//   pc_open(pen, pen_len, sorts, sorts_len) -> handle     a document (sorts: {"id": "key"}; {} = assign)
//   pc_apply(h, batch, batch_len) -> ptr                  {"ok", "reason"?, "skipped": [i], "ops": [as applied]}
//   pc_serialize(h) -> ptr                                the .pen bytes
//   pc_state(h) -> ptr                                    {"nodes": {id: {"parent", "sort", "slot"}}}
//   pc_close(h)
//   pc_result_len() -> int                                the byte length of the last returned ptr
//
// Returned buffers belong to pencore until the next call that returns one.

Entry :: struct {
	doc:   engine.Document,
	state: engine.Cloud_State,
}

docs: map[int]^Entry
next_handle: int
result: []u8

@(private = "file")
ctx :: proc "contextless" () -> runtime.Context {
	return runtime.default_context()
}

main :: proc() {}

@(private = "file")
give :: proc(s: string) -> rawptr {
	delete(result)
	result = make([]u8, len(s) + 1)
	copy(result, s)
	return raw_data(result)
}

@(export)
pc_alloc :: proc "contextless" (n: int) -> rawptr {
	context = ctx()
	return raw_data(make([]u8, max(n, 1)))
}

@(export)
pc_free :: proc "contextless" (p: rawptr) {
	context = ctx()
	free(p)
}

@(export)
pc_result_len :: proc "contextless" () -> int {
	return max(len(result) - 1, 0)
}

@(export)
pc_open :: proc "contextless" (pen: [^]u8, pen_len: int, sorts: [^]u8, sorts_len: int) -> int {
	context = ctx()
	e := new(Entry)
	if !engine.doc_load(&e.doc, strings.clone(string(pen[:pen_len]))) {
		free(e)
		return -1
	}
	if sorts_len > 0 {
		if v, err := json.parse_string(string(sorts[:sorts_len]), .JSON, false, context.temp_allocator); err == nil {
			if o, ok := v.(json.Object); ok do for id, k in o do e.state.sorts[strings.clone(id)] = strings.clone(string(k.(json.String) or_else ""))
		}
	}
	engine.sorts_assign(&e.doc, &e.state)
	next_handle += 1
	docs[next_handle] = e
	free_all(context.temp_allocator)
	return next_handle
}

@(export)
pc_close :: proc "contextless" (h: int) {
	context = ctx()
	if e, ok := docs[h]; ok {
		engine.doc_clear(&e.doc)
		delete_key(&docs, h)
		free(e)
	}
}

// batch: {"ops": [...]} or a bare [...] of ops.
@(export)
pc_apply :: proc "contextless" (h: int, batch: [^]u8, batch_len: int) -> rawptr {
	context = ctx()
	defer free_all(context.temp_allocator)
	e, found := docs[h]
	if !found do return give(`{"ok":false,"reason":"NO_DOCUMENT","skipped":[],"ops":[]}`)
	v, err := json.parse_string(string(batch[:batch_len]), .JSON, false, context.temp_allocator)
	if err != nil do return give(`{"ok":false,"reason":"BAD_OP","skipped":[],"ops":[]}`)
	list: json.Array
	#partial switch x in v {
	case json.Array: list = x
	case json.Object: list = x["ops"].(json.Array) or_else nil
	}
	ops := make([dynamic]engine.Op, context.temp_allocator)
	for o in list {
		op, ok := engine.op_parse(o)
		if !ok do return give(`{"ok":false,"reason":"BAD_OP","skipped":[],"ops":[]}`)
		append(&ops, op)
	}
	// owned copies: applying a delete frees the node's strings the ops would point into
	owned := engine.ops_clone(ops[:], context.temp_allocator)
	res := engine.ops_apply(&e.doc, &e.state, owned)
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"ok":%v`, res.ok)
	if !res.ok {
		strings.write_string(&b, `,"reason":`)
		engine.json_write_string(&b, res.reason)
	}
	strings.write_string(&b, `,"skipped":[`)
	for i, k in res.skipped do fmt.sbprintf(&b, "%s%d", "," if k > 0 else "", i)
	strings.write_string(&b, `],"ops":[`)
	if res.ok {
		for op, k in owned {
			c := op
			if c.raw != "" do if r := engine.canonical_raw(c.raw); r != "" do c.raw = r
			if c.props != nil {
				props := make([]engine.Prop, len(c.props), context.temp_allocator)
				for p, j in c.props do props[j] = engine.Prop{p.key, engine.canonical_raw(p.raw) if p.key != "children" else p.raw}
				c.props = props
			}
			if k > 0 do strings.write_byte(&b, ',')
			engine.op_write(&b, c)
		}
	}
	strings.write_string(&b, "]}")
	return give(strings.to_string(b))
}

@(export)
pc_serialize :: proc "contextless" (h: int) -> rawptr {
	context = ctx()
	defer free_all(context.temp_allocator)
	e, found := docs[h]
	if !found do return give("")
	engine.pages_prune(&e.doc)
	s := engine.doc_serialize(&e.doc)
	defer delete(s)
	return give(s)
}

@(export)
pc_state :: proc "contextless" (h: int) -> rawptr {
	context = ctx()
	defer free_all(context.temp_allocator)
	e, found := docs[h]
	if !found do return give(`{"nodes":{}}`)
	ids := make(map[int]string, len(e.doc.nodes), context.temp_allocator)
	for n in e.doc.nodes do ids[n.uid] = n.id
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"nodes":{`)
	first := true
	for n in e.doc.nodes {
		if n.imported || n.ghost do continue
		if !first do strings.write_byte(&b, ',')
		first = false
		engine.json_write_string(&b, n.id)
		strings.write_string(&b, `:{"parent":`)
		engine.json_write_string(&b, ids[n.parent] or_else "")
		strings.write_string(&b, `,"sort":`)
		engine.json_write_string(&b, e.state.sorts[n.id] or_else "")
		strings.write_string(&b, `,"slot":`)
		engine.json_write_string(&b, n.slot_of)
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "}}")
	return give(strings.to_string(b))
}
