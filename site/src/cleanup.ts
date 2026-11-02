// Nightly cleanup (docs/cloud-design.md §3.5, §7): uploads never committed, shared files
// deleted more than 30 days ago, and blobs no remaining version uses. A blob is deleted only
// when no version of its workspace names it and it is older than a day, so a blob uploaded
// for a version still being committed is never taken away.
import { and, eq, inArray, isNotNull, isNull, lt, or } from 'drizzle-orm'

import { blobKey, bucket, type App } from './blobs'
import type { Manifest } from './files'
import { blobsOf } from './files'
import { asset, document, shareLink, version } from './schema'

const HOUR = 60 * 60 * 1000
const DAY = 24 * HOUR

export async function cleanup(app: Pick<App, 'db' | 'storage'>, now = Date.now()) {
	const db = app.db
	const stale = await db
		.delete(version)
		.where(and(eq(version.status, 'pending'), lt(version.createdAt, new Date(now - 2 * HOUR))))
		.returning({ id: version.id })
	// documents whose first upload was never committed, and deleted ones after 30 days
	const gone: string[] = (
		await db
			.select({ id: document.id })
			.from(document)
			.where(
				or(
					and(eq(document.kind, 'shared'), isNull(document.headVersionId), lt(document.createdAt, new Date(now - 2 * HOUR))),
					and(isNotNull(document.deletedAt), lt(document.deletedAt, new Date(now - 30 * DAY))),
				),
			)
	).map((r: { id: string }) => r.id)
	if (gone.length) {
		await db.delete(shareLink).where(inArray(shareLink.docId, gone))
		await db.delete(version).where(inArray(version.docId, gone))
		await db.delete(document).where(inArray(document.id, gone))
	}

	// blobs: per workspace, what its remaining versions name
	const used = new Map<string, Set<string>>()
	for (const v of await db.select({ ws: version.workspaceId, manifest: version.manifest }).from(version)) {
		let set = used.get(v.ws)
		if (!set) used.set(v.ws, (set = new Set()))
		for (const b of blobsOf(JSON.parse(v.manifest) as Manifest)) set.add(b.hash)
	}
	const old = await db
		.select({ ws: asset.workspaceId, hash: asset.hash })
		.from(asset)
		.where(lt(asset.createdAt, new Date(now - DAY)))
	const store = bucket(app as App)
	let blobs = 0
	for (const a of old as { ws: string; hash: string }[]) {
		if (used.get(a.ws)?.has(a.hash)) continue
		await store.delete(blobKey(a.ws, a.hash)).catch(() => {})
		await db.delete(asset).where(and(eq(asset.workspaceId, a.ws), eq(asset.hash, a.hash)))
		blobs++
	}
	return { versions: stale.length, docs: gone.length, blobs }
}
