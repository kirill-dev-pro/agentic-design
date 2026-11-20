// The server rules of a cloud document (cloud-ops.md, "Server rules"), as a plain class: no
// Durable Object, no socket, no storage. The DocRoom (S1) wraps it with WebSockets, the op
// log in SQLite and checkpoints; the harness in the tests drives it directly.
//
// The engine's ops_apply (pencore.wasm) applies a batch whole or not at all, skips ops on
// missing nodes and refuses ID_EXISTS, CYCLE, NO_PARENT and BAD_OP. What the engine cannot
// know is the room's: the order (seq), duplicate batch ids, roles, agents switched off, limits,
// missing assets, and tombstones, which turn a create or move into a deleted parent into one
// into its nearest live ancestor.

export type Raw = string
export type Op =
	| { op: 'set'; node: string; key: string; raw: Raw }
	| { op: 'unset'; node: string; key: string }
	| { op: 'create'; node: string; parent: string; sort: string; slot?: string; props: [string, Raw][] }
	| { op: 'move'; node: string; parent: string; sort: string; slot?: string }
	| { op: 'delete'; node: string }
	| { op: 'hset'; key: string; raw: Raw }
	| { op: 'hunset'; key: string }
	| { op: 'asset'; path: string; hash: string; type: string }

export type Agent = { client: string; session: string; name?: string; color?: string }
export type Batch = { batch: string; base: number; ops: Op[]; agent?: Agent | null }
export type Principal = { userId: string; name: string; role: 'viewer' | 'commenter' | 'editor' | 'owner' }

/** Whether a role may change the document (viewers and commenters may not). */
export const canEdit = (role: Principal['role']) => role === 'editor' || role === 'owner'

export type Ack = { t: 'ack'; batch: string; seq: number; skipped?: number[]; rewritten?: { op: number; parent: string }[] }
export type Nack = { t: 'nack'; batch: string; reason: string; detail?: Record<string, unknown> }
export type Broadcast = { t: 'ops'; seq: number; batch: string; author: string; agent: Agent | null; ops: Op[] }

/** The engine as pencore.mjs wraps it. */
export type Pencore = {
	open(pen: string, sorts?: Record<string, string>): number
	apply(h: number, batch: { ops: Op[] }): { ok: boolean; reason?: string; skipped?: number[]; deleted?: string[]; ops?: Op[] }
	serialize(h: number): string
	state(h: number): { nodes: Record<string, { parent: string; sort: string; slot: string }> }
	/** The ops that turn document h into `pen` (h does not change). */
	diff(h: number, pen: string): { ok: boolean; reason?: string; ops: Op[] }
	close(h: number): void
}

export type RoomOptions = {
	/** Agent edits switched off for this document (cloud-design §6.5). */
	agentsOff?: boolean
	maxOpsPerBatch?: number
	maxLiveNodes?: number
	/** A batch id the room acknowledged before its in-memory map (the op log), with its seq. */
	lookupBatch?: (batch: string) => number | undefined
	/** Whether a blob is uploaded and ready in the workspace (cloud-design §3.5). */
	hasAsset?: (hash: string) => boolean
	/** How long tombstones are kept, ms (cloud-ops S2: 30 days). */
	tombstoneMs?: number
	now?: () => number
}

type Tombstone = { parent: string; at: number }

export class Room {
	seq = 0
	private readonly h: number
	private readonly batches = new Map<string, number>()
	private readonly tombstones = new Map<string, Tombstone>()
	private liveNodes: number
	private readonly opts: Required<Omit<RoomOptions, 'hasAsset' | 'lookupBatch'>> & Pick<RoomOptions, 'hasAsset' | 'lookupBatch'>

	constructor(
		private readonly pc: Pencore,
		pen: string,
		sorts: Record<string, string> = {},
		opts: RoomOptions = {},
	) {
		this.h = pc.open(pen, sorts)
		this.liveNodes = Object.keys(pc.state(this.h).nodes).length
		this.opts = {
			agentsOff: false,
			maxOpsPerBatch: 10_000,
			maxLiveNodes: 200_000,
			tombstoneMs: 30 * 24 * 3600 * 1000,
			now: Date.now,
			...opts,
		}
	}

	/** One client message of type batch: the reply for the sender, and what everyone else gets. */
	submit(who: Principal, b: Batch): { reply: Ack | Nack; broadcast?: Broadcast } {
		const nack = (reason: string, detail?: Record<string, unknown>) => ({
			reply: { t: 'nack', batch: b.batch, reason, ...(detail ? { detail } : {}) } as Nack,
		})
		const seen = this.batches.get(b.batch) ?? this.opts.lookupBatch?.(b.batch)
		if (seen !== undefined) return { reply: { t: 'ack', batch: b.batch, seq: seen } }
		if (!canEdit(who.role)) return nack('FORBIDDEN')
		if (b.agent && this.opts.agentsOff) return nack('AGENTS_OFF')
		if (!Array.isArray(b.ops) || b.ops.length === 0) return nack('BAD_OP')
		if (b.ops.length > this.opts.maxOpsPerBatch) return nack('TOO_LARGE', { max: this.opts.maxOpsPerBatch })
		for (const [i, op] of b.ops.entries())
			if (op.op === 'asset' && this.opts.hasAsset && !this.opts.hasAsset(op.hash)) return nack('ASSET_MISSING', { op: i })

		const structural = b.ops.some((o) => o.op === 'create' || o.op === 'move' || o.op === 'delete')
		const before = structural ? this.pc.state(this.h).nodes : null
		const ops = b.ops.slice()
		const rewritten: { op: number; parent: string }[] = []
		if (before) {
			const created = new Set<string>()
			for (const [i, op] of ops.entries()) {
				if (op.op === 'create') created.add(op.node)
				if ((op.op === 'create' || op.op === 'move') && op.parent !== '' && !(op.parent in before) && !created.has(op.parent)) {
					const live = this.liveAncestor(op.parent, before)
					if (live !== null) {
						ops[i] = { ...op, parent: live }
						rewritten.push({ op: i, parent: live })
					}
				}
			}
			const creates = ops.filter((o) => o.op === 'create').length
			if (this.liveNodes + creates > this.opts.maxLiveNodes) return nack('QUOTA', { maxLiveNodes: this.opts.maxLiveNodes })
		}

		const r = this.pc.apply(this.h, { ops })
		if (!r.ok) return nack(r.reason ?? 'BAD_OP')

		this.seq += 1
		this.batches.set(b.batch, this.seq)
		if (before) this.updateTombstones(before, r.deleted ?? [], ops)
		const ack: Ack = { t: 'ack', batch: b.batch, seq: this.seq }
		if (r.skipped?.length) ack.skipped = r.skipped
		if (rewritten.length) ack.rewritten = rewritten
		return {
			reply: ack,
			broadcast: { t: 'ops', seq: this.seq, batch: b.batch, author: who.userId, agent: b.agent ?? null, ops: r.ops ?? ops },
		}
	}

	/**
	 * A new upload of the document (the owner shared the local file again): the ops that turn the
	 * room's document into `pen`, submitted by `who` as ordinary batches, so that everyone in the
	 * room gets the upload as an edit and the log and checkpoints carry it. Batches hold at most
	 * `maxBytes` of ops each (the op log's rows and the socket's messages have limits); each is
	 * applied whole, in order. A retry is safe: the diff starts from what the room has, and an
	 * upload already in it is no ops at all.
	 */
	upload(who: Principal, pen: string, id: string, maxBytes = 512 * 1024): { ok: true; broadcasts: Broadcast[] } | { ok: false; reason: string; broadcasts: Broadcast[] } {
		const d = this.pc.diff(this.h, pen)
		if (!d.ok) return { ok: false, reason: d.reason ?? 'BAD_PEN', broadcasts: [] }
		const chunks: Op[][] = []
		let cur: Op[] = []
		let bytes = 0
		for (const op of d.ops) {
			const n = JSON.stringify(op).length + 1
			if (cur.length && (bytes + n > maxBytes || cur.length >= this.opts.maxOpsPerBatch)) {
				chunks.push(cur)
				cur = []
				bytes = 0
			}
			cur.push(op)
			bytes += n
		}
		if (cur.length) chunks.push(cur)
		const broadcasts: Broadcast[] = []
		for (const ops of chunks) {
			const { reply, broadcast } = this.submit(who, { batch: `${id}:${this.seq}`, base: this.seq, ops, agent: null })
			if (reply.t === 'nack') return { ok: false, reason: reply.reason, broadcasts }
			if (broadcast) broadcasts.push(broadcast)
		}
		return { ok: true, broadcasts }
	}

	/** What the room needs to start again after an eviction: its text, sort keys, tombstones and seq. */
	snapshot(): { pen: string; sorts: Record<string, string>; tombstones: [string, Tombstone][]; seq: number } {
		const nodes = this.pc.state(this.h).nodes
		const sorts: Record<string, string> = {}
		for (const [id, n] of Object.entries(nodes)) sorts[id] = n.sort
		return { pen: this.pc.serialize(this.h), sorts, tombstones: [...this.tombstones], seq: this.seq }
	}

	/** A room from a snapshot. */
	static restore(
		pc: Pencore,
		snap: { pen: string; sorts: Record<string, string>; tombstones?: [string, Tombstone][]; seq: number },
		opts: RoomOptions = {},
	): Room {
		const room = new Room(pc, snap.pen, snap.sorts, opts)
		room.seq = snap.seq
		for (const [id, t] of snap.tombstones ?? []) room.tombstones.set(id, t)
		return room
	}

	/** Apply a batch the room already acknowledged (from its op log), without the checks: its ops are as applied. */
	replay(seq: number, batch: string, ops: Op[]) {
		const structural = ops.some((o) => o.op === 'create' || o.op === 'move' || o.op === 'delete')
		const before = structural ? this.pc.state(this.h).nodes : null
		const r = this.pc.apply(this.h, { ops })
		if (!r.ok) throw new Error(`[room] replay of ${batch} (seq ${seq}) failed: ${r.reason}`)
		this.seq = seq
		this.batches.set(batch, seq)
		if (before) this.updateTombstones(before, r.deleted ?? [], ops)
	}

	pen(): string {
		return this.pc.serialize(this.h)
	}

	close() {
		this.pc.close(this.h)
	}

	/** The nearest live ancestor of a tombstoned node ("" for the canvas), or null if it was never known. */
	private liveAncestor(id: string, live: Record<string, unknown>): string | null {
		let cur = id
		for (let depth = 0; depth < 10_000; depth++) {
			const t = this.tombstones.get(cur)
			if (!t) return null
			if (t.parent === '' || t.parent in live) return t.parent
			cur = t.parent
		}
		return ''
	}

	/** From the engine's `deleted` (each deleted node and its subtree) and the parents before the batch. */
	private updateTombstones(before: Record<string, { parent: string }>, deleted: string[], ops: Op[]) {
		const now = this.opts.now()
		for (const id of deleted) this.tombstones.set(id, { parent: before[id]?.parent ?? '', at: now })
		let created = 0
		for (const op of ops)
			if (op.op === 'create') {
				this.tombstones.delete(op.node)
				created++
			}
		for (const [id, t] of this.tombstones) if (now - t.at > this.opts.tombstoneMs) this.tombstones.delete(id)
		this.liveNodes += created - deleted.length
	}
}
