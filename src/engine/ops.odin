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
			if op.key == "id" do return refuse(doc, state, snap, saved_sorts, "BAD_OP")
			if op.key == "children" {
				// the marker of an empty "children": [] the node writes (cloud-ops.md §1)
				n.children_key = op.kind == .Set
				continue
			}
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
				if p.key == "children" {
					n.children_key = true
					continue
				}
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

// ---------------------------------------------------------------- sort keys (cloud-ops.md §2.5)

SORT_DIGITS := "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz" // bytewise ordered

@(private = "file")
digit_index :: proc(c: u8) -> int {
	switch c {
	case '0' ..= '9': return int(c - '0')
	case 'A' ..= 'Z': return 10 + int(c - 'A')
	case 'a' ..= 'z': return 36 + int(c - 'a')
	}
	return 0
}

// A key strictly between a and b ("" for a = before everything, "" for b = after
// everything), as fractional indexing does.
sort_between :: proc(a, b: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	mid :: proc(sb: ^strings.Builder, a, b: string) {
		if b != "" {
			n := 0
			for n < len(b) && (a[n] if n < len(a) else '0') == b[n] do n += 1
			if n > 0 {
				strings.write_string(sb, b[:n])
				mid(sb, a[n:] if n < len(a) else "", b[n:])
				return
			}
		}
		da := digit_index(a[0]) if a != "" else 0
		db := digit_index(b[0]) if b != "" else 62
		if db - da > 1 {
			strings.write_byte(sb, SORT_DIGITS[(da + db) / 2])
		} else if b != "" && len(b) > 1 {
			strings.write_byte(sb, b[0])
		} else {
			strings.write_byte(sb, SORT_DIGITS[da])
			mid(sb, a[1:] if a != "" else "", "")
		}
	}
	mid(&sb, a, b)
	return strings.to_string(sb)
}

// Gives every node without a key one, in its current sibling order (an upload: evenly
// spaced keys of one width per parent, "a0", "a1", …).
sorts_assign :: proc(doc: ^Document, state: ^Cloud_State) {
	count := make(map[int]int, 64, context.temp_allocator)
	for n in doc.nodes do if !n.imported do count[n.parent] += 1
	next := make(map[int]int, 64, context.temp_allocator)
	for n in doc.nodes {
		if n.imported || n.id in state.sorts do continue
		i := next[n.parent]
		next[n.parent] = i + 1
		width := 1
		for c := count[n.parent]; c > 62; c /= 62 do width += 1
		b := strings.builder_make()
		strings.write_byte(&b, 'a')
		digits := make([]u8, width, context.temp_allocator)
		v := i
		for k := width - 1; k >= 0; k -= 1 {
			digits[k] = SORT_DIGITS[v % 62]
			v /= 62
		}
		strings.write_bytes(&b, digits)
		state.sorts[strings.clone(n.id)] = strings.to_string(b)
	}
}

// ---------------------------------------------------------------- diff (cloud-ops.md §3.1)

// Props written by layout, not by people (cloud-ops.md §2.3): never sent.
derived_key :: proc(n: ^Node, key: string) -> bool {
	#partial switch n.flow {
	case .Shape:
		return key == "padding" || key == "cornerRadius"
	case .Connector:
		switch key {
		case "x", "y", "width", "height", "geometry", "viewBox": return true
		}
	case .Label:
		return key == "x" || key == "y"
	}
	if is_shape_outline(n) {
		switch key {
		case "x", "y", "width", "height", "geometry", "viewBox": return true
		}
	}
	return false
}

// The ops that turn `before` into `after` (two states of one document: ids are what
// matches nodes). New sort keys go into `state`. With include_derived, layout-written
// props are diffed too (tests that check apply(diff) = after); the app leaves them out.
ops_diff :: proc(before, after: []Node, before_header, after_header: []Prop, state: ^Cloud_State, include_derived := false) -> [dynamic]Op {
	ops := make([dynamic]Op, context.temp_allocator)
	id_of :: proc(nodes: []Node, uid: int, ids: map[int]string) -> string {return ids[uid] or_else ""}
	bid := make(map[int]string, len(before), context.temp_allocator)
	aid := make(map[int]string, len(after), context.temp_allocator)
	bnode := make(map[string]^Node, len(before), context.temp_allocator)
	for &n in before do if !n.imported {bid[n.uid] = n.id; bnode[n.id] = &n}
	for &n in after do if !n.imported do aid[n.uid] = n.id
	anode := make(map[string]^Node, len(after), context.temp_allocator)
	for &n in after do if !n.imported do anode[n.id] = &n

	// sibling order in `after`: keep the keys of the longest run already in order, give the
	// others (and new nodes) keys between their neighbours
	Sib :: struct {
		id:  string,
		key: string,
	}
	groups := make(map[string][dynamic]Sib, 64, context.temp_allocator)
	for &n in after {
		if n.imported do continue
		g := strings.concatenate({aid[n.parent] or_else "", "|", n.slot_of}, context.temp_allocator)
		list := groups[g] or_else make([dynamic]Sib, context.temp_allocator)
		append(&list, Sib{n.id, ""})
		groups[g] = list
	}
	new_sort := make(map[string]string, 16, context.temp_allocator)
	for _, list in groups {
		// a node keeps its key when it stays under the same parent and in order
		keep := make([]bool, len(list), context.temp_allocator)
		keys := make([]string, len(list), context.temp_allocator)
		for s, i in list {
			b := bnode[s.id]
			a := anode[s.id]
			if b != nil && (bid[b.parent] or_else "") == (aid[a.parent] or_else "") && b.slot_of == a.slot_of {
				keys[i] = state.sorts[s.id] or_else ""
			}
		}
		// longest increasing subsequence of the kept keys
		best := make([]int, len(list), context.temp_allocator)
		prev := make([]int, len(list), context.temp_allocator)
		top := -1
		for i in 0 ..< len(list) {
			prev[i] = -1
			if keys[i] == "" do continue
			best[i] = 1
			for j in 0 ..< i do if keys[j] != "" && keys[j] < keys[i] && best[j] + 1 > best[i] {
				best[i] = best[j] + 1
				prev[i] = j
			}
			if top < 0 || best[i] > best[top] do top = i
		}
		for i := top; i >= 0; i = prev[i] do keep[i] = true
		for s, i in list {
			if keep[i] do continue
			lo := ""
			for j := i - 1; j >= 0; j -= 1 do if keep[j] || list[j].id in new_sort {
				lo = new_sort[list[j].id] or_else keys[j]
				break
			}
			hi := ""
			for j in i + 1 ..< len(list) do if keep[j] {
				hi = keys[j]
				break
			}
			new_sort[s.id] = strings.clone(sort_between(lo, hi))
		}
	}

	// creates (parents first), moves, then sets
	depth :: proc(nodes: map[string]^Node, ids: map[int]string, n: ^Node) -> int {
		d := 0
		for p := n.parent; p != 0 && d < MAX_DEPTH; d += 1 {
			pn := nodes[ids[p] or_else ""] or_else nil
			if pn == nil do break
			p = pn.parent
		}
		return d
	}
	created := make([dynamic]^Node, context.temp_allocator)
	for &n in after do if !n.imported && n.id not_in bnode do append(&created, &n)
	deepest := 0
	for n in created do deepest = max(deepest, depth(anode, aid, n))
	for d in 0 ..= deepest {
		for n in created {
			if depth(anode, aid, n) != d do continue
			props := make([dynamic]Prop, context.temp_allocator)
			for p in n.props do append(&props, p)
			if n.children_key do append(&props, Prop{"children", "[]"})
			append(&ops, Op{kind = .Create, node = n.id, parent = aid[n.parent] or_else "", sort = new_sort[n.id], slot = n.slot_of, props = props[:]})
			state.sorts[strings.clone(n.id)] = strings.clone(new_sort[n.id])
		}
	}
	for &n in after {
		if n.imported do continue
		b := bnode[n.id] or_else nil
		if b == nil do continue
		if k, moved := new_sort[n.id]; moved {
			append(&ops, Op{kind = .Move, node = n.id, parent = aid[n.parent] or_else "", sort = k, slot = n.slot_of})
			state.sorts[strings.clone(n.id)] = strings.clone(k)
		}
		diff_props(&ops, b, &n, include_derived)
		if n.children_key != b.children_key {
			append(&ops, Op{kind = .Set if n.children_key else .Unset, node = n.id, key = "children", raw = "[]"})
		}
	}
	// deletes: only the top-most of each removed subtree
	for &n in before {
		if n.imported || n.id in anode do continue
		parent_gone := false
		for p := n.parent; p != 0; {
			pid := bid[p] or_else ""
			if pid == "" do break
			if pid not_in anode {
				parent_gone = true
				break
			}
			p = bnode[pid].parent
		}
		if !parent_gone do append(&ops, Op{kind = .Delete, node = n.id})
	}
	diff_header(&ops, before_header, after_header)
	return ops
}

@(private = "file")
merged_node_key :: proc(key: string) -> bool {
	return key == "descendants" || key == "metadata"
}

@(private = "file")
diff_props :: proc(ops: ^[dynamic]Op, b, a: ^Node, include_derived: bool) {
	for p in a.props {
		if p.key == "id" || (!include_derived && derived_key(a, p.key)) do continue
		old := prop_raw(b, p.key)
		if old == p.raw do continue
		if merged_node_key(p.key) && old != "" {
			diff_object(ops, a.id, p.key, old, p.raw, false)
			continue
		}
		append(ops, Op{kind = .Set, node = a.id, key = p.key, raw = p.raw})
	}
	for p in b.props {
		if prop_index(a, p.key) >= 0 || (!include_derived && derived_key(b, p.key)) do continue
		append(ops, Op{kind = .Unset, node = a.id, key = p.key})
	}
}

// Per-entry ops for an object-valued key (node metadata/descendants, header maps).
@(private = "file")
diff_object :: proc(ops: ^[dynamic]Op, node, key, old_raw, new_raw: string, header: bool) {
	ov, _ := json.parse_string(old_raw, .JSON5, false, context.temp_allocator)
	nv, _ := json.parse_string(new_raw, .JSON5, false, context.temp_allocator)
	oo, _ := ov.(json.Object)
	no, _ := nv.(json.Object)
	raw_of :: proc(v: json.Value) -> string {
		b := strings.builder_make(context.temp_allocator)
		write_json_value(&b, v)
		return strings.to_string(b)
	}
	for k, v in no {
		r := raw_of(v)
		if ov2, has := oo[k]; has && raw_of(ov2) == r do continue
		path := strings.concatenate({key, "/", k}, context.temp_allocator)
		append(ops, Op{kind = .Hset if header else .Set, node = node, key = path, raw = r})
	}
	for k in oo do if k not_in no {
		path := strings.concatenate({key, "/", k}, context.temp_allocator)
		append(ops, Op{kind = .Hunset if header else .Unset, node = node, key = path})
	}
}

@(private = "file")
diff_header :: proc(ops: ^[dynamic]Op, before, after: []Prop) {
	raw_in :: proc(props: []Prop, key: string) -> string {
		for p in props do if p.key == key do return p.raw
		return ""
	}
	for p in after {
		old := raw_in(before, p.key)
		if old == p.raw do continue
		switch p.key {
		case "variables", "themes", "imports":
			if old != "" {
				diff_object(ops, "", p.key, old, p.raw, true)
				continue
			}
		case "fonts":
			ov, _ := json.parse_string(old, .JSON5, false, context.temp_allocator)
			nv, _ := json.parse_string(p.raw, .JSON5, false, context.temp_allocator)
			oa, _ := ov.(json.Array)
			na, _ := nv.(json.Array)
			url :: proc(v: json.Value) -> string {o, _ := v.(json.Object); return string(o["url"].(json.String) or_else "")}
			raw_of :: proc(v: json.Value) -> string {b := strings.builder_make(context.temp_allocator); write_json_value(&b, v); return strings.to_string(b)}
			for f in na {
				same := false
				for g in oa do if url(g) == url(f) && raw_of(g) == raw_of(f) do same = true
				if !same do append(ops, Op{kind = .Hset, key = strings.concatenate({"fonts/", url(f)}, context.temp_allocator), raw = raw_of(f)})
			}
			for g in oa {
				kept := false
				for f in na do if url(f) == url(g) do kept = true
				if !kept do append(ops, Op{kind = .Hunset, key = strings.concatenate({"fonts/", url(g)}, context.temp_allocator)})
			}
			continue
		}
		append(ops, Op{kind = .Hset, key = p.key, raw = p.raw})
	}
	for p in before do if raw_in(after, p.key) == "" do append(ops, Op{kind = .Hunset, key = p.key})
}

// The wire form of an op (cloud-ops.md §2).
op_write :: proc(b: ^strings.Builder, op: Op) {
	names := [Op_Kind]string{.Set = "set", .Unset = "unset", .Create = "create", .Move = "move", .Delete = "delete", .Hset = "hset", .Hunset = "hunset", .Asset = "asset"}
	strings.write_string(b, `{"op":"`)
	strings.write_string(b, names[op.kind])
	strings.write_byte(b, '"')
	field :: proc(b: ^strings.Builder, k, v: string) {
		strings.write_string(b, `,"`)
		strings.write_string(b, k)
		strings.write_string(b, `":`)
		json_write_string(b, v)
	}
	switch op.kind {
	case .Set, .Unset:
		field(b, "node", op.node); field(b, "key", op.key)
		if op.kind == .Set do field(b, "raw", op.raw)
	case .Hset, .Hunset:
		field(b, "key", op.key)
		if op.kind == .Hset do field(b, "raw", op.raw)
	case .Create, .Move:
		field(b, "node", op.node); field(b, "parent", op.parent); field(b, "sort", op.sort); field(b, "slot", op.slot)
		if op.kind == .Create {
			strings.write_string(b, `,"props":[`)
			for p, i in op.props {
				if i > 0 do strings.write_byte(b, ',')
				strings.write_byte(b, '[')
				json_write_string(b, p.key)
				strings.write_byte(b, ',')
				json_write_string(b, p.raw)
				strings.write_byte(b, ']')
			}
			strings.write_byte(b, ']')
		}
	case .Delete:
		field(b, "node", op.node)
	case .Asset:
		field(b, "path", op.key)
	}
	strings.write_byte(b, '}')
}
