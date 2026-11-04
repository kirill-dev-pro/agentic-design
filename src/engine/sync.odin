package engine

import "core:fmt"
import "core:strings"

// The client side of a cloud document (cloud-ops.md §3.2): the server's state at the last
// seq, the batches sent but not yet acknowledged, and the document the user sees (the
// server's state with those batches on top). No network or file calls: the host passes in
// what arrives (remote ops, acks, nacks) and sends what sync_local returns.

Pending_Batch :: struct {
	id:  string,
	ops: []Op,
}

Sync_Client :: struct {
	server:       Document, // the server's state at `seq` (never laid out or drawn)
	server_state: Cloud_State,
	seq:          int,
	shown:        ^Document, // what the user sees and edits (the app's document)
	shown_state:  ^Cloud_State,
	pending:      [dynamic]Pending_Batch,
	marks:        map[string]int, // "node\x00key" touched by pending batches -> how many
	session:      string,
	counter:      int,
}

// Starts from a document both sides have (the server's state at `seq`).
sync_init :: proc(c: ^Sync_Client, pen: string, seq: int, shown: ^Document, shown_state: ^Cloud_State, session: string) -> bool {
	if !doc_load(&c.server, pen) do return false
	if !doc_load(shown, pen) do return false
	sorts_assign(&c.server, &c.server_state)
	for k, v in c.server_state.sorts do shown_state.sorts[strings.clone(k)] = strings.clone(v)
	c.seq = seq
	c.shown, c.shown_state = shown, shown_state
	c.session = strings.clone(session)
	return true
}

@(private = "file")
mark_key :: proc(op: Op) -> string {
	#partial switch op.kind {
	case .Set, .Unset: return fmt.aprintf("%s\x00%s", op.node, op.key)
	case .Create, .Move, .Delete: return fmt.aprintf("%s\x00#struct", op.node)
	case .Hset, .Hunset: return fmt.aprintf("\x00h\x00%s", op.key)
	}
	return ""
}

// A local step, already applied to `shown`: becomes a pending batch. Returns its id.
sync_local :: proc(c: ^Sync_Client, ops: []Op) -> string {
	c.counter += 1
	id := fmt.aprintf("%s:%d", c.session, c.counter)
	kept := ops_clone(ops)
	append(&c.pending, Pending_Batch{id, kept})
	for op in ops do if k := mark_key(op); k != "" do c.marks[k] += 1
	return id
}

@(private = "file")
unmark :: proc(c: ^Sync_Client, b: Pending_Batch) {
	for op in b.ops {
		k := mark_key(op)
		if k == "" do continue
		if n := c.marks[k] - 1; n > 0 do c.marks[k] = n
		else do delete_key(&c.marks, k)
	}
}

// Someone else's batch, in the server's order.
sync_remote :: proc(c: ^Sync_Client, seq: int, ops: []Op) {
	on_server := ops_apply(&c.server, &c.server_state, ops)
	c.seq = seq
	// on the shown document, a pending local value wins over the remote one (it comes later
	// in the server's order); everything else applies at once
	shown := make([dynamic]Op, 0, len(ops), context.temp_allocator)
	from := make([dynamic]int, 0, len(ops), context.temp_allocator) // index in ops of each shown op
	for op, i in ops {
		if k := mark_key(op); k != "" && k in c.marks && op.kind != .Delete do continue
		append(&shown, op)
		append(&from, i)
	}
	res := ops_apply(c.shown, c.shown_state, shown[:])
	if !res.ok {
		sync_rebuild(c)
		return
	}
	// an op that found its node on the server but not on screen: a pending local change
	// removed it here first (a delete of the frame someone moved it out of). The server's
	// order decides: rebuild from it.
	server_skipped := make(map[int]bool, len(on_server.skipped), context.temp_allocator)
	for i in on_server.skipped do server_skipped[i] = true
	for j in res.skipped do if !server_skipped[from[j]] {
		sync_rebuild(c)
		return
	}
}

// The server took our oldest pending batch at `seq`.
sync_ack :: proc(c: ^Sync_Client, batch: string, seq: int) {
	if len(c.pending) == 0 || c.pending[0].id != batch do return
	b := c.pending[0]
	ordered_remove(&c.pending, 0)
	unmark(c, b)
	res := ops_apply(&c.server, &c.server_state, b.ops)
	c.seq = seq
	// a value someone else set while ours was pending is now behind ours on the server too,
	// and the shown document already has ours: nothing to redraw. Unless some of our ops
	// found nothing on the server (their node went first): then the screen still shows them.
	if !res.ok || len(res.skipped) > 0 do sync_rebuild(c)
}

// The server refused our oldest pending batch: the user's change is undone.
sync_nack :: proc(c: ^Sync_Client, batch: string) {
	if len(c.pending) == 0 || c.pending[0].id != batch do return
	unmark(c, c.pending[0])
	ordered_remove(&c.pending, 0)
	sync_rebuild(c)
}

// shown = server + the pending batches, from scratch (after a refusal).
sync_rebuild :: proc(c: ^Sync_Client) {
	snap := doc_snapshot(&c.server)
	doc_restore(c.shown, snap)
	free_snapshot(snap)
	clear(&c.shown_state.sorts)
	for k, v in c.server_state.sorts do c.shown_state.sorts[strings.clone(k)] = strings.clone(v)
	for b in c.pending do _ = ops_apply(c.shown, c.shown_state, b.ops)
}
