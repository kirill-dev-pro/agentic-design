// /api/docs/<docId>/room: the WebSocket of a cloud document's DocRoom (cloud-design §3.4).
// The Worker checks the session (cookie, or the Mac app's bearer token) and the person's role
// in the document, sets x-doc-* headers itself (whatever the client sent is dropped), starts the
// room from the document's latest upload the first time, and hands the upgrade over.
import { eq } from 'drizzle-orm'

import { blobKey, bucket, type App } from '../blobs'
import type { Manifest } from '../files'
import { docAccess } from '../invites'
import { document, version } from '../schema'

export const ROOM_PATH = /^\/api\/docs\/([^/]+)\/room$/

type Namespace = {
	idFromName(name: string): unknown
	get(id: unknown): { fetch(input: Request | string, init?: RequestInit): Promise<Response> }
}

export async function handleRoom(app: App & { auth: any }, request: Request, ns: Namespace | undefined, docId: string) {
	if (!ns) return new Response('Rooms are not available here', { status: 503 })
	if (request.headers.get('upgrade')?.toLowerCase() !== 'websocket') return new Response('Expected a WebSocket', { status: 426 })
	const session = await app.auth.api.getSession({ headers: request.headers }).catch(() => null)
	if (!session?.user) return new Response('Unauthorized', { status: 401 })

	// The workspace's people own it; invited people have their role (src/invites.ts). Anyone else
	// gets the same answer as for a document that does not exist.
	const access = await docAccess(app.db, session.user.id, docId)
	if (!access?.doc.headVersionId) return new Response('Not found', { status: 404 })
	const row = { doc: access.doc }
	const role = access.role

	const stub = ns.get(ns.idFromName(docId))
	const info = (await (await stub.fetch('https://room/info')).json()) as { initialized: boolean }
	if (!info.initialized) {
		// The first time: the latest upload becomes the room's document (an M1 shared file becomes a
		// cloud document, decision 14).
		const [ver] = await app.db.select({ manifest: version.manifest }).from(version).where(eq(version.id, row.doc.headVersionId!))
		const m = JSON.parse(ver!.manifest) as Manifest
		const res = await bucket(app).get(blobKey(row.doc.workspaceId, m.pen.hash))
		if (!res.ok) return new Response('The document could not be read', { status: 502 })
		const pen = await res.text()
		const init = await stub.fetch('https://room/init', { method: 'POST', body: JSON.stringify({ pen, docId, assets: m.assets }) })
		if (!init.ok) return new Response('The room could not start', { status: 502 })
		if (row.doc.kind !== 'cloud') await app.db.update(document).set({ kind: 'cloud' }).where(eq(document.id, docId))
	}

	const headers = new Headers(request.headers)
	const sent: string[] = []
	headers.forEach((_v, k) => { if (k.startsWith("x-doc-")) sent.push(k) })
	for (const k of sent) headers.delete(k)
	headers.set('x-doc-user', session.user.id)
	headers.set('x-doc-name', encodeURIComponent(session.user.name ?? 'Someone'))
	headers.set('x-doc-role', role)
	return stub.fetch(new Request(request, { headers }))
}
