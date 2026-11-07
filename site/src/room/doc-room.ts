// One DocRoom per cloud document (cloud-design §3.4, cloud-ops.md): every editor and viewer of
// the document holds a WebSocket to the same instance, which orders their edits (src/room/room.ts
// over pencore), keeps the op log and a snapshot in its own SQLite, and relays presence.
//
// Hibernation only (acceptWebSocket): the object may sleep between messages; what a socket needs
// after a wake-up is in its attachment, and the document is rebuilt from the snapshot plus the
// op log after it. The Worker (src/server.ts) has checked the session and the role and passes
// them in x-doc-* headers it sets itself; the room never reads a role from a message.
//
// `DurableObject` comes from `workerstack/durable` (Cloudflare's in the Worker, a stand-in when
// `workerstack blueprint` loads this file in Bun); Cloudflare-only code stays inside methods.
import { DurableObject, type HibernatableWebSocket } from 'workerstack/durable'

import { loadPencore } from './pencore'
import { canEdit, Room, type Batch, type Op, type Principal } from './room'

const WIRE = 1
const MAX_MESSAGE = 1024 * 1024
const SNAPSHOT_AFTER_MS = 5_000
/** A checkpoint (a version in storage) after this long without edits, or when the last editor leaves. */
const CHECKPOINT_IDLE_MS = 30_000
const RETRY_MAX_MS = 3600_000
const LOG_DAYS = 7
const PRESENCE_PER_SECOND = 20

type Who = Principal & { color: string }
type Attachment = { who: Who; joined: boolean; presence?: Record<string, unknown> | null }

const COLORS = ['#C96442', '#2E7D32', '#1565C0', '#6A1B9A', '#AD1457', '#00838F', '#EF6C00', '#4E342E']
const colorOf = (id: string) => COLORS[[...id].reduce((h, c) => (h * 31 + c.charCodeAt(0)) >>> 0, 7) % COLORS.length]!

export class DocRoom extends DurableObject {
	private room: Room | null = null
	private loading: Promise<Room | null> | null = null
	private readonly rates = new WeakMap<object, { at: number; n: number }>()

	constructor(...args: ConstructorParameters<typeof DurableObject>) {
		super(...args)
		const sql = this.ctx.storage.sql
		sql.exec(`CREATE TABLE IF NOT EXISTS snapshot (
			id INTEGER PRIMARY KEY CHECK (id = 1), seq INTEGER NOT NULL, pen TEXT NOT NULL,
			sorts TEXT NOT NULL, tombstones TEXT NOT NULL, docId TEXT NOT NULL, at INTEGER NOT NULL)`)
		sql.exec('CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)')
		sql.exec('CREATE TABLE IF NOT EXISTS room_assets (path TEXT PRIMARY KEY, hash TEXT NOT NULL, size INTEGER NOT NULL, type TEXT NOT NULL)')
		sql.exec(`CREATE TABLE IF NOT EXISTS ops (
			seq INTEGER PRIMARY KEY, batch TEXT NOT NULL UNIQUE, author TEXT NOT NULL,
			agent TEXT, at INTEGER NOT NULL, ops TEXT NOT NULL)`)
	}

	// ------------------------------------------------------------ state

	private snapshotRow() {
		return this.ctx.storage.sql
			.exec<{ seq: number; pen: string; sorts: string; tombstones: string; docId: string }>(
				'SELECT seq, pen, sorts, tombstones, docId FROM snapshot WHERE id = 1',
			)
			.toArray()[0]
	}

	/** The document in memory: the snapshot, then the logged batches after it. */
	private async load(): Promise<Room | null> {
		if (this.room) return this.room
		this.loading ??= (async () => {
			const snap = this.snapshotRow()
			if (!snap) return null
			const pc = await loadPencore(await pencoreModule())
			const sql = this.ctx.storage.sql
			const room = Room.restore(
				pc,
				{ pen: snap.pen, sorts: JSON.parse(snap.sorts), tombstones: JSON.parse(snap.tombstones), seq: snap.seq },
				{
					lookupBatch: (id) => sql.exec<{ seq: number }>('SELECT seq FROM ops WHERE batch = ?', id).toArray()[0]?.seq,
				},
			)
			for (const row of sql.exec<{ seq: number; batch: string; ops: string }>(
				'SELECT seq, batch, ops FROM ops WHERE seq > ? ORDER BY seq',
				snap.seq,
			))
				room.replay(row.seq, row.batch, JSON.parse(row.ops))
			this.room = room
			return room
		})()
		try {
			return await this.loading
		} finally {
			this.loading = null
		}
	}

	private writeSnapshot(room: Room, docId?: string) {
		const s = room.snapshot()
		const sql = this.ctx.storage.sql
		const id = docId ?? this.snapshotRow()?.docId ?? ''
		sql.exec(
			`INSERT INTO snapshot (id, seq, pen, sorts, tombstones, docId, at) VALUES (1, ?, ?, ?, ?, ?, ?)
			 ON CONFLICT(id) DO UPDATE SET seq = excluded.seq, pen = excluded.pen, sorts = excluded.sorts,
			 tombstones = excluded.tombstones, at = excluded.at`,
			s.seq,
			s.pen,
			JSON.stringify(s.sorts),
			JSON.stringify(s.tombstones),
			id,
			Date.now(),
		)
		// The log keeps 7 days for resent batches and resuming clients; older rows the snapshot covers.
		sql.exec('DELETE FROM ops WHERE seq <= ? AND at < ?', s.seq, Date.now() - LOG_DAYS * 86_400_000)
	}

	private meta(k: string): string | undefined {
		return this.ctx.storage.sql.exec<{ v: string }>('SELECT v FROM meta WHERE k = ?', k).toArray()[0]?.v
	}

	private setMeta(k: string, v: string | number) {
		this.ctx.storage.sql.exec('INSERT INTO meta (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v', k, String(v))
	}

	private joinedCount(except?: HibernatableWebSocket) {
		return (this.ctx.getWebSockets() as HibernatableWebSocket[]).filter(
			(s) => s !== except && (s.deserializeAttachment() as Attachment | null)?.joined,
		).length
	}

	// ------------------------------------------------------------ requests from the Worker

	async fetch(request: Request): Promise<Response> {
		const url = new URL(request.url)
		if (url.pathname === '/info') {
			const snap = this.snapshotRow()
			return Response.json({ initialized: Boolean(snap), seq: snap ? (this.room?.seq ?? snap.seq) : 0 })
		}
		if (url.pathname === '/kick' && request.method === 'POST') {
			// The Worker after a role change or a removal: close that person's sockets; they reconnect
			// with their new role, or not at all.
			const { userId, reason } = (await request.json()) as { userId: string; reason: string }
			let closed = 0
			for (const s of this.ctx.getWebSockets(userId) as HibernatableWebSocket[]) {
				s.close(4403, reason === 'ROLE_CHANGED' ? 'ROLE_CHANGED' : 'REVOKED')
				closed++
			}
			return Response.json({ closed })
		}
		if (url.pathname === '/notify' && request.method === 'POST') {
			// The Worker after a comment changed (src/comments.ts): everyone in the room hears it and
			// fetches the comments again. Nothing of the comment itself travels here.
			const msg = (await request.json()) as { t: 'comments'; thread: string; by: string }
			const text = JSON.stringify({ t: 'comments', thread: msg.thread, by: msg.by })
			let sent = 0
			for (const s of this.ctx.getWebSockets() as HibernatableWebSocket[])
				if ((s.deserializeAttachment() as Attachment | null)?.joined)
					try {
						s.send(text)
						sent++
					} catch {
						// closing
					}
			return Response.json({ sent })
		}
		if (url.pathname === '/init' && request.method === 'POST') {
			if (this.snapshotRow()) return Response.json({ ok: true, already: true })
			const { pen, docId, assets = [] } = (await request.json()) as {
				pen: string
				docId: string
				assets?: { path: string; hash: string; size: number; type: string }[]
			}
			for (const a of assets)
				this.ctx.storage.sql.exec('INSERT OR REPLACE INTO room_assets (path, hash, size, type) VALUES (?, ?, ?, ?)', a.path, a.hash, a.size, a.type)
			const pc = await loadPencore(await pencoreModule())
			const room = new Room(pc, pen, {})
			this.writeSnapshot(room, docId)
			this.room = null
			room.close()
			return Response.json({ ok: true })
		}
		if (request.headers.get('upgrade')?.toLowerCase() !== 'websocket') return new Response('Expected a WebSocket', { status: 426 })
		const userId = request.headers.get('x-doc-user')
		const role = request.headers.get('x-doc-role') as Principal['role'] | null
		if (!userId || !role) return new Response('Unauthorized', { status: 401 })
		if (!this.snapshotRow()) return new Response('Not initialized', { status: 409 })
		const name = decodeURIComponent(request.headers.get('x-doc-name') ?? 'Someone')
		const pair = new WebSocketPair()
		const [client, server] = [pair[0], pair[1] as unknown as HibernatableWebSocket]
		this.ctx.acceptWebSocket(server, [userId])
		server.serializeAttachment({ who: { userId, name, role, color: colorOf(userId) }, joined: false } satisfies Attachment)
		return new Response(null, { status: 101, webSocket: client } as ResponseInit)
	}

	// ------------------------------------------------------------ the protocol

	async webSocketMessage(socket: HibernatableWebSocket, message: string | ArrayBuffer) {
		const size = typeof message === 'string' ? message.length : message.byteLength
		if (size > MAX_MESSAGE) return socket.close(4413, 'TOO_LARGE')
		const att = socket.deserializeAttachment() as Attachment | null
		if (!att) return socket.close(4401, 'UNAUTHORIZED')
		let msg: { t?: string } & Record<string, unknown>
		try {
			msg = JSON.parse(typeof message === 'string' ? message : new TextDecoder().decode(message))
		} catch {
			return send(socket, { t: 'error', reason: 'BAD_MESSAGE' })
		}
		let room: Room | null
		try {
			room = await this.load()
		} catch (error) {
			console.error('[DocRoom] cannot load the document', String(error))
			return socket.close(1011, 'ENGINE_UNAVAILABLE')
		}
		if (!room) return socket.close(4410, 'GONE')

		if (msg.t === 'hello') {
			if (typeof msg.v === 'number' && msg.v > WIRE) return socket.close(4400, 'UPGRADE')
			const since = Number(msg.since ?? 0)
			const sql = this.ctx.storage.sql
			const oldest = sql.exec<{ seq: number | null }>('SELECT min(seq) AS seq FROM ops').toArray()[0]?.seq ?? null
			const welcome: Record<string, unknown> = { t: 'welcome', v: WIRE, seq: room.seq, role: att.who.role, you: att.who }
			// full: a client with no copy of the document (it opens it from the room)
			if (msg.full === true) {
				const s = room.snapshot()
				welcome.snapshot = { seq: s.seq, pen: s.pen, sorts: s.sorts }
			} else if (since >= room.seq) welcome.ops = []
			else if (oldest !== null && since >= oldest - 1)
				welcome.ops = sql
					.exec<{ seq: number; batch: string; author: string; agent: string | null; ops: string }>(
						'SELECT seq, batch, author, agent, ops FROM ops WHERE seq > ? ORDER BY seq',
						since,
					)
					.toArray()
					.map((r) => ({ seq: r.seq, batch: r.batch, author: r.author, agent: r.agent ? JSON.parse(r.agent) : null, ops: JSON.parse(r.ops) }))
			else {
				// The log does not reach back: the whole document. (A checkpoint URL replaces this in S1b.)
				const s = room.snapshot()
				welcome.snapshot = { seq: s.seq, pen: s.pen, sorts: s.sorts }
			}
			welcome.presence = this.others(socket)
				.map((p) => p.deserializeAttachment() as Attachment)
				.filter((a) => a?.joined)
				.map((a) => ({ author: a.who, ...(a.presence ?? {}) }))
			socket.serializeAttachment({ ...att, joined: true } satisfies Attachment)
			send(socket, welcome)
			this.broadcast(socket, { t: 'join', author: att.who })
			return
		}
		if (!att.joined) return send(socket, { t: 'error', reason: 'HELLO_FIRST' })

		if (msg.t === 'batch') {
			const b = msg as unknown as Batch
			if (typeof b.batch !== 'string' || !Array.isArray(b.ops)) return send(socket, { t: 'nack', batch: b.batch, reason: 'BAD_OP' })
			const { reply, broadcast } = room.submit(att.who, b)
			if (broadcast) {
				this.ctx.storage.sql.exec(
					'INSERT INTO ops (seq, batch, author, agent, at, ops) VALUES (?, ?, ?, ?, ?, ?)',
					broadcast.seq,
					broadcast.batch,
					broadcast.author,
					broadcast.agent ? JSON.stringify(broadcast.agent) : null,
					Date.now(),
					JSON.stringify(broadcast.ops),
				)
				for (const op of broadcast.ops)
					if (op.op === 'asset')
						this.ctx.storage.sql.exec(
							`INSERT INTO room_assets (path, hash, size, type) VALUES (?, ?, 0, ?)
							 ON CONFLICT(path) DO UPDATE SET hash = excluded.hash, type = excluded.type`,
							op.path,
							op.hash,
							op.type,
						)
				this.setMeta('lastBatchAt', Date.now())
				if ((await this.ctx.storage.getAlarm()) === null) await this.ctx.storage.setAlarm(Date.now() + SNAPSHOT_AFTER_MS)
			}
			// The ops row is written before either message leaves (the output gate holds them until it is durable).
			send(socket, reply)
			if (broadcast) this.broadcast(socket, broadcast)
			return
		}

		if (msg.t === 'presence' || msg.t === 'preview') {
			if (!this.allow(socket)) return
			const out = { ...msg, author: att.who }
			if (msg.t === 'presence') {
				const { t: _t, ...rest } = msg
				socket.serializeAttachment({ ...att, presence: rest } satisfies Attachment)
				if (!canEdit(att.who.role)) delete (out as Record<string, unknown>).selection
			}
			this.broadcast(socket, out)
			return
		}
		send(socket, { t: 'error', reason: 'UNKNOWN_TYPE' })
	}

	async webSocketClose(socket: HibernatableWebSocket, code: number, reason: string) {
		const att = socket.deserializeAttachment() as Attachment | null
		if (att?.joined) this.broadcast(socket, { t: 'leave', author: att.who })
		// The last one out: checkpoint soon rather than after the idle wait.
		if (att?.joined && this.joinedCount(socket) === 0) await this.ctx.storage.setAlarm(Date.now() + 1000)
		try {
			socket.close(code, reason)
		} catch {
			// already closed
		}
	}

	/** The snapshot in the room's SQLite, then, when the document has rested, a checkpoint in storage. */
	async alarm() {
		const room = await this.load()
		if (!room) return
		this.writeSnapshot(room)
		const done = Number(this.meta('checkpointSeq') ?? 0)
		if (room.seq <= done) return
		const idleSince = Number(this.meta('lastBatchAt') ?? 0)
		const due = idleSince + CHECKPOINT_IDLE_MS
		if (this.joinedCount() > 0 && Date.now() < due) {
			await this.ctx.storage.setAlarm(due)
			return
		}
		const docId = this.snapshotRow()!.docId
		const assets = this.ctx.storage.sql
			.exec<{ path: string; hash: string; size: number; type: string }>('SELECT path, hash, size, type FROM room_assets ORDER BY path')
			.toArray()
		const seq = room.seq
		const pen = room.pen()
		try {
			const { worker } = await import('../worker')
			const { writeCheckpoint } = await import('./checkpoint')
			const result = await worker.withContext(this.ctx as never, async () => {
				const app = (await worker.app(this.env as never)) as never
				return writeCheckpoint(app, { docId, seq, pen, assets: assets as never })
			})
			if (result === 'gone') {
				for (const s of this.ctx.getWebSockets()) s.close(4410, 'GONE')
				return
			}
			this.setMeta('checkpointSeq', seq)
			this.setMeta('checkpointAttempts', 0)
		} catch (error) {
			// Turso or storage away: keep the snapshot here and try again later; the seq makes a retry safe.
			const n = Number(this.meta('checkpointAttempts') ?? 0) + 1
			this.setMeta('checkpointAttempts', n)
			console.error('[DocRoom] checkpoint failed', String(error))
			await this.ctx.storage.setAlarm(Date.now() + Math.min(60_000 * 2 ** (n - 1), RETRY_MAX_MS))
		}
	}

	// ------------------------------------------------------------ helpers

	private others(socket: HibernatableWebSocket) {
		return (this.ctx.getWebSockets() as HibernatableWebSocket[]).filter((s) => s !== socket)
	}

	private broadcast(from: HibernatableWebSocket, msg: unknown) {
		const text = JSON.stringify(msg)
		for (const peer of this.others(from))
			if ((peer.deserializeAttachment() as Attachment | null)?.joined)
				try {
					peer.send(text)
				} catch {
					// a socket closing as we send
				}
	}

	/** Presence and previews: at most 20 a second per socket; more are dropped silently. */
	private allow(socket: object): boolean {
		const now = Date.now()
		const r = this.rates.get(socket)
		if (!r || now - r.at >= 1000) {
			this.rates.set(socket, { at: now, n: 1 })
			return true
		}
		r.n += 1
		return r.n <= PRESENCE_PER_SECOND
	}
}

function send(socket: HibernatableWebSocket, msg: unknown) {
	socket.send(JSON.stringify(msg))
}

/** The compiled pencore module: the bundler turns the import into a WebAssembly.Module in the Worker. */
async function pencoreModule(): Promise<WebAssembly.Module> {
	const mod = (await import('./pencore.wasm?module')) as { default: WebAssembly.Module }
	return mod.default
}

declare const WebSocketPair: { new (): Record<0 | 1, WebSocket> }
export type { Op }
