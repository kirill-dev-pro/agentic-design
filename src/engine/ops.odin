package engine

import "core:encoding/json"
import "core:strings"

// Cloud documents: applying the operations of the protocol (cloud-ops.md §2–§3) to a
// document, the same way on every client and in the server's room. No file or network
// calls: the app, the web editor and the room's pencore all run this.
//
// The document keeps nodes in an array (siblings in their order); the protocol orders
// siblings by fractional sort keys, kept here per node id.

Op_Kind :: enum u8 {
	Set,
	Unset,
	Create,
	Move,
	Delete,
	Hset,
	Hunset,
	Asset,
}

Op :: struct {
	kind:   Op_Kind,
	node:   string,
	key:    string,
	raw:    string,
	parent: string, // "" = the canvas
	sort:   string,
	slot:   string,
	props:  []Prop, // create
}

// Sibling sort keys by node id (cloud-ops.md §2.5).
Cloud_State :: struct {
	sorts: map[string]string,
}

Apply_Result :: struct {
	ok:      bool,
	reason:  string, // a nack reason when not ok: ID_EXISTS, CYCLE, NO_PARENT, BAD_OP
	skipped: [dynamic]int, // indexes of ops on nodes that are gone (acknowledged, not applied)
}

// Parses one op object of the wire form.
op_parse :: proc(v: json.Value) -> (op: Op, ok: bool) {
	o := v.(json.Object) or_return
	str :: proc(o: json.Object, k: string) -> string {return string(o[k].(json.String) or_else "")}
	switch str(o, "op") {
	case "set": op.kind = .Set
	case "unset": op.kind = .Unset
	case "create": op.kind = .Create
	case "move": op.kind = .Move
	case "delete": op.kind = .Delete
	case "hset": op.kind = .Hset
	case "hunset": op.kind = .Hunset
	case "asset": op.kind = .Asset
	case: return op, false
	}
	op.node, op.key, op.raw = str(o, "node"), str(o, "key"), str(o, "raw")
	op.parent, op.sort, op.slot = str(o, "parent"), str(o, "sort"), str(o, "slot")
	if arr, has := o["props"].(json.Array); has {
		props := make([dynamic]Prop, 0, len(arr), context.temp_allocator)
		for e in arr {
			pair, pok := e.(json.Array)
			if !pok || len(pair) != 2 do return op, false
			append(&props, Prop{string(pair[0].(json.String) or_else ""), string(pair[1].(json.String) or_else "")})
		}
		op.props = props[:]
	}
	return op, true
}

// A raw JSON value in canonical form (sorted object keys, tidy numbers), or "" when it
// does not parse.
canonical_raw :: proc(raw: string, allocator := context.temp_allocator) -> string {
	v, err := json.parse_string(raw, .JSON5, false, context.temp_allocator)
	if err != nil do return ""
	b := strings.builder_make(allocator)
	write_json_value(&b, v)
	return strings.to_string(b)
}

// Applies a batch: all of it or none (a refused batch leaves the document as it was).
ops_apply :: proc(doc: ^Document, state: ^Cloud_State, ops: []Op) -> (res: Apply_Result) {
	res.skipped = make([dynamic]int, context.temp_allocator)
	snap := doc_snapshot(doc)
	saved_sorts := make(map[string]string, len(state.sorts), context.temp_allocator)
	for k, v in state.sorts do saved_sorts[k] = v
	refuse :: proc(doc: ^Document, state: ^Cloud_State, snap: Snapshot, saved: map[string]string, why: string) -> Apply_Result {
		doc_restore(doc, snap)
		clear(&state.sorts)
		for k, v in saved do state.sorts[strings.clone(k)] = strings.clone(v)
		return {ok = false, reason = why}
	}
	for op, i in ops {
		switch op.kind {
		case .Set, .Unset:
			n, _ := doc_find(doc, op.node)
			if n == nil {
				append(&res.skipped, i)
				continue
			}
			if op.key == "id" || op.key == "children" do return refuse(doc, state, snap, saved_sorts, "BAD_OP")
			if !node_put(doc, n, op.key, op.raw if op.kind == .Set else "") do return refuse(doc, state, snap, saved_sorts, "BAD_OP")
		case .Create:
			if existing, _ := doc_find(doc, op.node); existing != nil do return refuse(doc, state, snap, saved_sorts, "ID_EXISTS")
			parent := 0
			if op.parent != "" {
				p, _ := doc_find(doc, op.parent)
				if p == nil do return refuse(doc, state, snap, saved_sorts, "NO_PARENT")
				parent = p.uid
			}
			n: Node
			n.parent = parent
			n.id = strings.clone(op.node)
			if op.slot != "" do n.slot_of = strings.clone(op.slot)
			for p in op.props {
				if p.key == "children" do continue
				raw := canonical_raw(p.raw)
				if raw == "" do return refuse(doc, state, snap, saved_sorts, "BAD_OP")
				node_set_raw(&n, p.key, raw)
			}
			added := doc_add(doc, n)
			state.sorts[strings.clone(op.node)] = strings.clone(op.sort)
			ops_place(doc, state, added.uid)
		case .Move:
			n, _ := doc_find(doc, op.node)
			if n == nil {
				append(&res.skipped, i)
				continue
			}
			parent := 0
			if op.parent != "" {
				p, _ := doc_find(doc, op.parent)
				if p == nil do return refuse(doc, state, snap, saved_sorts, "NO_PARENT")
				if p.uid == n.uid || is_descendant(doc, p.uid, n.uid) do return refuse(doc, state, snap, saved_sorts, "CYCLE")
				parent = p.uid
			}
			uid := n.uid
			n.parent = parent
			delete(n.slot_of)
			n.slot_of = strings.clone(op.slot)
			state.sorts[strings.clone(op.node)] = strings.clone(op.sort)
			ops_place(doc, state, uid)
		case .Delete:
			n, _ := doc_find(doc, op.node)
			if n == nil {
				append(&res.skipped, i)
				continue
			}
			doc_delete(doc, n.uid)
		case .Hset, .Hunset:
			if !header_put(doc, op.key, op.raw if op.kind == .Hset else "") do return refuse(doc, state, snap, saved_sorts, "BAD_OP")
		case .Asset:
		// the asset manifest is not part of the .pen (the host keeps it)
		}
	}
	free_snapshot(snap)
	res.ok = true
	return
}

// Sets a node key ("" raw = unset). "descendants/<path>" and "metadata/<key>" set one
// entry of that object (cloud-ops.md §2.2).
@(private = "file")
node_put :: proc(doc: ^Document, n: ^Node, key, raw: string) -> bool {
	if slash := strings.index_byte(key, '/'); slash > 0 && (key[:slash] == "descendants" || key[:slash] == "metadata") {
		whole, entry := key[:slash], key[slash + 1:]
		obj := make(json.Object, context.temp_allocator)
		if v, ok := prop_value(n, whole); ok {
			if o, is_obj := v.(json.Object); is_obj do obj = o
		}
		if raw == "" {
			delete_key(&obj, entry)
		} else {
			v, err := json.parse_string(raw, .JSON5, false, context.temp_allocator)
			if err != nil do return false
			obj[entry] = v
		}
		if len(obj) == 0 {
			node_unset(doc, n, whole)
			return true
		}
		b := strings.builder_make(context.temp_allocator)
		write_json_value(&b, obj)
		node_set_raw(n, whole, strings.to_string(b))
		node_refresh(doc, n)
		return true
	}
	if raw == "" {
		node_unset(doc, n, key)
		return true
	}
	c := canonical_raw(raw)
	if c == "" do return false
	node_set_raw(n, key, c)
	node_refresh(doc, n)
	return true
}

// Sets a header key ("" raw = unset); "variables/<name>", "themes/<axis>" and
// "imports/<alias>" set one entry of that object, "fonts/<url>" one entry of the fonts list.
@(private = "file")
header_put :: proc(doc: ^Document, key, raw: string) -> bool {
	whole, entry := key, ""
	if slash := strings.index_byte(key, '/'); slash > 0 do whole, entry = key[:slash], key[slash + 1:]
	value: json.Value
	if raw != "" {
		v, err := json.parse_string(raw, .JSON5, false, context.temp_allocator)
		if err != nil do return false
		value = v
	}
	current: json.Value
	for p in doc.header do if p.key == whole {
		current, _ = json.parse_string(p.raw, .JSON5, false, context.temp_allocator)
	}
	result: json.Value = value
	if entry != "" {
		switch whole {
		case "variables", "themes", "imports":
			obj := make(json.Object, context.temp_allocator)
			if o, ok := current.(json.Object); ok do obj = o
			if value == nil do delete_key(&obj, entry)
			else do obj[entry] = value
			result = obj if len(obj) > 0 else nil
		case "fonts":
			list := make(json.Array, 0, 8, context.temp_allocator)
			replaced := false
			if a, ok := current.(json.Array); ok {
				for f in a {
					fo, _ := f.(json.Object)
					if string(fo["url"].(json.String) or_else "") == entry {
						if value != nil do append(&list, value)
						replaced = true
					} else {
						append(&list, f)
					}
				}
			}
			if !replaced && value != nil do append(&list, value)
			result = list if len(list) > 0 else nil
		case:
			return false // pages/<id>: not yet (cloud-ops.md §2.2)
		}
	}
	doc_set_header(doc, whole, result)
	doc_resolve_vars(doc)
	for &n in doc.nodes do node_refresh(doc, &n)
	return true
}

// Moves a node (with its subtree) among its siblings to where its sort key puts it:
// before the first sibling with a greater (sort, id).
ops_place :: proc(doc: ^Document, state: ^Cloud_State, uid: int) {
	n, _ := doc_find_uid(doc, uid)
	if n == nil do return
	parent, slot, id := n.parent, n.slot_of, n.id
	key := state.sorts[id] or_else ""
	block := make([dynamic]Node, context.temp_allocator)
	for i := 0; i < len(doc.nodes); {
		m := doc.nodes[i]
		if m.uid == uid || is_descendant(doc, m.uid, uid) {
			append(&block, m)
			ordered_remove(&doc.nodes, i)
		} else {
			i += 1
		}
	}
	at := len(doc.nodes)
	for m, i in doc.nodes {
		if m.parent != parent || m.slot_of != slot || m.ghost do continue
		k := state.sorts[m.id] or_else ""
		if k > key || (k == key && m.id > id) {
			at = i
			break
		}
	}
	inject_at(&doc.nodes, at, ..block[:])
	doc_bump(doc)
	doc_index(doc)
}
