// A cloud document's checkpoint (cloud-ops.md S5): its .pen at a seq becomes a version of the
// document, stored like any upload (a blob per workspace, cloud-design §3.5), and the document's
// head moves to it, but only forward: the write carries the seq and loses to a newer one, so a
// retried or late alarm is harmless. Called by the DocRoom's alarm, with the Worker's own app.
import { and, eq, isNull, lt, or } from 'drizzle-orm'

import { blobKey, bucket, type App } from '../blobs'
import { sha256Hex } from '../crypto'
import type { Manifest } from '../files'
import { asset, document, version } from '../schema'

export type Checkpoint = { docId: string; seq: number; pen: string; assets: Manifest['assets'] }

export async function writeCheckpoint(app: Pick<App, 'db' | 'storage'>, c: Checkpoint): Promise<'written' | 'stale' | 'gone'> {
	const db = app.db
	const [doc] = await db.select().from(document).where(eq(document.id, c.docId)).limit(1)
	if (!doc || doc.deletedAt) return 'gone'
	if (doc.headSeq !== null && doc.headSeq >= c.seq) return 'stale'

	const bytes = new TextEncoder().encode(c.pen)
	const hash = await sha256Hex(bytes)
	const key = blobKey(doc.workspaceId, hash)
	const store = bucket(app as App)
	if (!(await store.exists(key))) await store.upload(key, bytes.buffer as ArrayBuffer, 'application/json')
	const now = new Date()
	await db
		.insert(asset)
		.values({ workspaceId: doc.workspaceId, hash, size: bytes.byteLength, type: 'application/json', ready: true, createdAt: now })
		.onConflictDoNothing()

	// The previous head's previews stay until a client renders new ones (cloud-design §4.3).
	let previews: Manifest['previews'] = { frames: [] }
	if (doc.headVersionId) {
		const [prev] = await db.select({ manifest: version.manifest }).from(version).where(eq(version.id, doc.headVersionId))
		if (prev) previews = (JSON.parse(prev.manifest) as Manifest).previews
	}
	const manifest: Manifest = { pen: { hash, size: bytes.byteLength }, assets: c.assets, missing: [], previews }
	const size = bytes.byteLength + c.assets.reduce((n, a) => n + a.size, 0)
	const [ver] = await db
		.insert(version)
		.values({
			docId: c.docId,
			workspaceId: doc.workspaceId,
			status: 'committed',
			kind: 'checkpoint',
			seq: c.seq,
			penHash: hash,
			manifest: JSON.stringify(manifest),
			sizeBytes: size,
			createdBy: doc.createdBy,
			createdAt: now,
			committedAt: now,
		})
		.returning({ id: version.id })
	const moved = await db
		.update(document)
		.set({ headVersionId: ver.id, headSeq: c.seq, sizeBytes: size, updatedAt: now })
		.where(and(eq(document.id, c.docId), or(isNull(document.headSeq), lt(document.headSeq, c.seq))))
		.returning({ id: document.id })
	if (!moved.length) {
		// A newer checkpoint won the race: this version is not anyone's head.
		await db.delete(version).where(eq(version.id, ver.id))
		return 'stale'
	}
	return 'written'
}
