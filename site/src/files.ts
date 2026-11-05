// Shared files and their links (M1: docs/cloud-design.md §1 conversions, §3.5, §4; the API
// contract in the shared folder). A shared file is an uploaded .pen with its assets; each
// upload is a version, and links show the latest committed one.
import { and, desc, eq, inArray, isNotNull, isNull, sum, count } from 'drizzle-orm'
import * as v from 'valibot'
import { WorkerstackError } from 'workerstack'

import { blobKey, bucket, secretOf, sniffOk, TYPES, uploadTarget, appUrl, type App } from './blobs'
import { randomToken, seal, sha256Hex, unseal } from './crypto'
import { asset, document, shareLink, user, version } from './schema'
import { docPath } from './share'
import { docAccess, sharedWith } from './invites'
import { currentWorkspace, type Workspace } from './workspaces'

const VERSION_TTL_MS = 60 * 60 * 1000

// ---------------------------------------------------------------- input

const hash = v.pipe(v.string(), v.regex(/^[0-9a-f]{64}$/, 'a SHA-256 in lower-case hex'))
const size = v.pipe(v.number(), v.integer(), v.minValue(1))
const relPath = v.pipe(
	v.string(),
	v.maxLength(1024),
	v.check((p) => !/^[a-z][a-z0-9+.-]*:/i.test(p) && !p.startsWith('/') && !p.includes('\\') && !p.includes('\0'), 'a relative path'),
)
const blob = v.object({ hash, size })
const preview = v.object({
	id: v.pipe(v.string(), v.minLength(1), v.maxLength(200)),
	name: v.pipe(v.string(), v.maxLength(200)),
	width: v.pipe(v.number(), v.minValue(1)),
	height: v.pipe(v.number(), v.minValue(1)),
	scale: v.optional(v.number(), 1),
	hash,
	size,
})

export const uploadInput = v.object({
	name: v.pipe(v.string(), v.trim(), v.minLength(1), v.maxLength(200)),
	pen: blob,
	assets: v.optional(
		v.pipe(v.array(v.object({ path: relPath, hash, size, type: v.picklist(TYPES) })), v.maxLength(2000)),
		[],
	),
	missing: v.optional(v.pipe(v.array(relPath), v.maxLength(2000)), []),
	previews: v.optional(
		v.object({ og: v.optional(blob), frames: v.optional(v.pipe(v.array(preview), v.maxLength(200)), []) }),
		{ frames: [] },
	),
})
export type UploadInput = v.InferOutput<typeof uploadInput>
export type Manifest = Pick<UploadInput, 'assets' | 'missing' | 'previews'> & { pen: { hash: string; size: number } }

const linkFields = {
	visibility: v.optional(v.picklist(['link', 'public'])),
	allowDownload: v.optional(v.boolean()),
	allowEmbed: v.optional(v.boolean()),
	expiresAt: v.optional(v.nullable(v.pipe(v.string(), v.isoTimestamp()))),
}

// ---------------------------------------------------------------- helpers

const fail = (code: 'BAD_REQUEST' | 'FORBIDDEN' | 'NOT_FOUND' | 'CONFLICT' | 'PAYLOAD_TOO_LARGE', reason: string, message: string, extra?: object) => {
	throw new WorkerstackError(code, message, { reason, ...extra })
}

async function usageOf(app: App, ws: string) {
	const [bytes] = await app.db.select({ n: sum(asset.size) }).from(asset).where(and(eq(asset.workspaceId, ws), eq(asset.ready, true)))
	const [files] = await app.db
		.select({ n: count() })
		.from(document)
		.where(and(eq(document.workspaceId, ws), isNull(document.deletedAt), isNotNull(document.headVersionId)))
	return { storageBytes: Number(bytes?.n ?? 0), sharedFiles: Number(files?.n ?? 0) }
}

/** Every blob of a manifest once, with the type it is stored as. */
export function blobsOf(m: Manifest): { hash: string; size: number; type: string }[] {
	const out = new Map<string, { hash: string; size: number; type: string }>()
	const add = (hash: string, size: number, type: string) => {
		const seen = out.get(hash)
		if (seen && seen.size !== size) fail('BAD_REQUEST', 'BAD_SIZE', `Two sizes given for one hash ${hash}`)
		if (!seen) out.set(hash, { hash, size, type })
	}
	add(m.pen.hash, m.pen.size, 'application/json')
	for (const a of m.assets) add(a.hash, a.size, a.type)
	if (m.previews.og) add(m.previews.og.hash, m.previews.og.size, 'image/png')
	for (const f of m.previews.frames ?? []) add(f.hash, f.size, 'image/png')
	return [...out.values()]
}

async function ownDoc(app: App, ws: Workspace, docId: string) {
	const [doc] = await app.db
		.select()
		.from(document)
		.where(and(eq(document.id, docId), eq(document.workspaceId, ws.id), isNull(document.deletedAt)))
		.limit(1)
	if (!doc) fail('NOT_FOUND', 'NOT_FOUND', 'No such file')
	return doc
}

export async function linkJson(app: App, row: typeof shareLink.$inferSelect, request?: Request) {
	const token = await unseal(secretOf(app), 'share-link-v1', row.tokenSealed)
	return {
		id: row.id,
		url: token ? `${appUrl(app, request)}/s/${token}` : null,
		visibility: row.visibility,
		allowDownload: row.allowDownload,
		allowEmbed: row.allowEmbed,
		expiresAt: row.expiresAt ? row.expiresAt.toISOString() : null,
		createdAt: row.createdAt.toISOString(),
		viewCount: row.viewCount,
	}
}

async function fileJson(app: App, doc: typeof document.$inferSelect, request?: Request) {
	const links = await app.db
		.select()
		.from(shareLink)
		.where(and(eq(shareLink.docId, doc.id), isNull(shareLink.revokedAt)))
		.orderBy(desc(shareLink.createdAt))
	let thumbUrl: string | null = null
	let docUrl: string | null = null
	if (doc.headVersionId) {
		const [ver] = await app.db.select({ manifest: version.manifest }).from(version).where(eq(version.id, doc.headVersionId))
		const m = ver ? (JSON.parse(ver.manifest) as Manifest) : null
		const base = `/api/docs/${doc.id}/v/${doc.headVersionId}`
		if (m?.previews.og) thumbUrl = `${base}/_ad/og.png`
		if (m) docUrl = `${base}/${docPath(m)}`
	}
	return {
		id: doc.id,
		name: doc.name,
		createdAt: doc.createdAt.toISOString(),
		updatedAt: doc.updatedAt.toISOString(),
		sizeBytes: doc.sizeBytes,
		versionId: doc.headVersionId,
		thumbUrl,
		docUrl,
		links: await Promise.all(links.map((l: typeof shareLink.$inferSelect) => linkJson(app, l, request))),
	}
}

// ---------------------------------------------------------------- upload

/** The shape of a .pen (docs/pen-format.md): an object whose `children` is a list of nodes,
 * each an object with a string `type`, nested children likewise. The engine's own parser
 * replaces this check in M2. */
export function isPen(doc: unknown): boolean {
	if (!doc || typeof doc !== 'object' || Array.isArray(doc)) return false
	const d = doc as Record<string, unknown>
	if (d.version !== undefined && typeof d.version !== 'string') return false
	const nodesOk = (list: unknown, depth: number): boolean =>
		Array.isArray(list) &&
		depth < 200 &&
		list.every(
			(n) =>
				n !== null &&
				typeof n === 'object' &&
				!Array.isArray(n) &&
				typeof (n as Record<string, unknown>).type === 'string' &&
				((n as Record<string, unknown>).children === undefined || nodesOk((n as Record<string, unknown>).children, depth + 1)),
		)
	return nodesOk(d.children, 0)
}

async function startUpload(app: App, request: Request, ws: Workspace, userId: string, input: UploadInput, existingId?: string) {
	const ent = ws.entitlements
	if (input.pen.size > ent.maxPenBytes) fail('PAYLOAD_TOO_LARGE', 'TOO_LARGE', 'The .pen file is larger than the plan allows')
	const paths = new Set<string>()
	for (const a of input.assets) {
		if (a.size > ent.maxAssetBytes) fail('PAYLOAD_TOO_LARGE', 'TOO_LARGE', `${a.path} is larger than the plan allows`)
		if (paths.has(a.path)) fail('BAD_REQUEST', 'DUPLICATE_PATH', `${a.path} is listed twice`)
		paths.add(a.path)
	}
	for (const p of [input.previews.og, ...(input.previews.frames ?? [])])
		if (p && p.size > ent.maxAssetBytes) fail('PAYLOAD_TOO_LARGE', 'TOO_LARGE', 'A preview is larger than the plan allows')
	const manifest: Manifest = { pen: input.pen, assets: input.assets, missing: input.missing, previews: input.previews }
	const blobs = blobsOf(manifest)
	const usage = await usageOf(app, ws.id)
	if (!existingId && usage.sharedFiles >= ent.sharedFiles) fail('FORBIDDEN', 'QUOTA_EXCEEDED', 'The plan allows no more shared files')

	const hashes = blobs.map((b) => b.hash)
	const have = new Set<string>(
		(
			await app.db
				.select({ hash: asset.hash })
				.from(asset)
				.where(and(eq(asset.workspaceId, ws.id), eq(asset.ready, true), inArray(asset.hash, hashes)))
		).map((r: { hash: string }) => r.hash),
	)
	const missing = blobs.filter((b) => !have.has(b.hash))
	const adding = missing.reduce((n, b) => n + b.size, 0)
	if (usage.storageBytes + adding > ent.storageBytes) fail('FORBIDDEN', 'QUOTA_EXCEEDED', 'The plan has no room for these files')

	const now = new Date()
	if (missing.length)
		await app.db
			.insert(asset)
			.values(missing.map((b) => ({ workspaceId: ws.id, hash: b.hash, size: b.size, type: b.type, ready: false, createdAt: now })))
			.onConflictDoNothing()
	let docId = existingId
	if (!docId) {
		const [doc] = await app.db
			.insert(document)
			.values({ workspaceId: ws.id, kind: 'shared', name: input.name, createdBy: userId, createdAt: now, updatedAt: now })
			.returning({ id: document.id })
		docId = doc.id as string
	}
	const total = blobs.filter((b) => b.hash === input.pen.hash || input.assets.some((a) => a.hash === b.hash)).reduce((n, b) => n + b.size, 0)
	const [ver] = await app.db
		.insert(version)
		.values({
			docId,
			workspaceId: ws.id,
			status: 'pending',
			penHash: input.pen.hash,
			manifest: JSON.stringify(manifest),
			sizeBytes: total,
			createdBy: userId,
			createdAt: now,
		})
		.returning({ id: version.id })
	const uploads = await Promise.all(missing.map((b) => uploadTarget(app, request, ws.id, b.hash, b.type, b.size)))
	return { docId, versionId: ver.id as string, uploads }
}

async function commit(app: App, request: Request, ws: Workspace, docId: string, versionId: string, name?: string) {
	const doc = await ownDoc(app, ws, docId)
	const [ver] = await app.db
		.select()
		.from(version)
		.where(and(eq(version.id, versionId), eq(version.docId, docId)))
		.limit(1)
	if (!ver) fail('NOT_FOUND', 'NOT_FOUND', 'No such version')
	if (ver.status === 'committed') return fileJson(app, doc, request)
	if (Date.now() - ver.createdAt.getTime() > VERSION_TTL_MS) fail('CONFLICT', 'EXPIRED', 'The upload took too long; start again')
	const m = JSON.parse(ver.manifest) as Manifest
	const blobs = blobsOf(m)
	const rows = await app.db
		.select()
		.from(asset)
		.where(and(eq(asset.workspaceId, ws.id), inArray(asset.hash, blobs.map((b) => b.hash))))
	const ready = new Set<string>(rows.filter((r: { ready: boolean }) => r.ready).map((r: { hash: string }) => r.hash))
	const store = bucket(app)
	const incomplete: string[] = []
	for (const b of blobs) {
		// A blob seen before must still be there (a HEAD): storage lost it, or a cleanup raced.
		if (ready.has(b.hash) && (await store.exists(blobKey(ws.id, b.hash)))) continue
		const res = await store.get(blobKey(ws.id, b.hash))
		if (!res.ok) {
			incomplete.push(b.hash)
			// so that the next upload asks for it again
			if (ready.has(b.hash))
				await app.db.update(asset).set({ ready: false }).where(and(eq(asset.workspaceId, ws.id), eq(asset.hash, b.hash)))
			continue
		}
		const bytes = new Uint8Array(await res.arrayBuffer())
		const bad =
			bytes.byteLength !== b.size ? 'size' : (await sha256Hex(bytes)) !== b.hash ? 'hash' : !sniffOk(b.type, bytes.subarray(0, 512)) ? 'type' : ''
		if (bad) {
			await store.delete(blobKey(ws.id, b.hash))
			if (bad === 'type') fail('BAD_REQUEST', 'BAD_TYPE', `A file is not the ${b.type} it was declared as`, { hash: b.hash })
			fail('BAD_REQUEST', 'HASH_MISMATCH', `A file differs from its declared ${bad}`, { hash: b.hash })
		}
		if (b.type === 'application/json') {
			let ok = false
			try {
				ok = isPen(JSON.parse(new TextDecoder().decode(bytes)))
			} catch {}
			if (!ok) {
				await store.delete(blobKey(ws.id, b.hash))
				fail('BAD_REQUEST', 'INVALID_PEN', 'A .pen file (the document or a library) is not a valid .pen')
			}
		}
		await app.db.update(asset).set({ ready: true }).where(and(eq(asset.workspaceId, ws.id), eq(asset.hash, b.hash)))
	}
	if (incomplete.length) fail('BAD_REQUEST', 'UPLOAD_INCOMPLETE', 'Some files were not uploaded', { missing: incomplete })
	const usage = await usageOf(app, ws.id)
	if (usage.storageBytes > ws.entitlements.storageBytes) fail('FORBIDDEN', 'QUOTA_EXCEEDED', 'The plan has no room for these files')
	const now = new Date()
	await app.db.update(version).set({ status: 'committed', committedAt: now }).where(eq(version.id, versionId))
	const [updated] = await app.db
		.update(document)
		.set({ headVersionId: versionId, sizeBytes: ver.sizeBytes, updatedAt: now, ...(name ? { name } : {}) })
		.where(eq(document.id, docId))
		.returning()
	return fileJson(app, updated, request)
}

// ---------------------------------------------------------------- routes

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function fileRoutes(o: any) {
	const ctxWs = async (context: any): Promise<[App, Workspace, string]> => {
		const ws = await currentWorkspace(context.db, context.user.id, context.session.activeOrganizationId)
		return [context as App, ws, context.user.id]
	}
	return {
		listFiles: o.protected.route({ method: 'GET', path: '/api/docs' }).handler(async ({ context }: any) => {
			const [app, ws] = await ctxWs(context)
			const docs = await app.db
				.select()
				.from(document)
				.where(and(eq(document.workspaceId, ws.id), isNull(document.deletedAt), isNotNull(document.headVersionId)))
				.orderBy(desc(document.updatedAt))
			const files = await Promise.all(docs.map((d: typeof document.$inferSelect) => fileJson(app, d, context.request)))
			// Files other people shared with this account (src/invites.ts): no links, which are the owner's.
			const shared = await Promise.all(
				(await sharedWith(app.db, context.user.id))
					.filter((s) => s.doc.headVersionId)
					.map(async (s) => ({ ...(await fileJson(app, s.doc, context.request)), links: [], shared: { role: s.role, owner: s.owner } })),
			)
			return { files, shared }
		}),

		createFile: o.protected
			.route({ method: 'POST', path: '/api/docs', successStatus: 201 })
			.input(uploadInput)
			.handler(async ({ input, context }: any) => {
				const [app, ws, userId] = await ctxWs(context)
				return startUpload(app, context.request, ws, userId, input)
			}),

		getFile: o.protected
			.route({ method: 'GET', path: '/api/docs/{docId}' })
			.input(v.object({ docId: v.string() }))
			.handler(async ({ input, context }: any) => {
				const app = context as App
				const access = await docAccess(app.db, context.user.id, input.docId)
				if (!access) fail('NOT_FOUND', 'NOT_FOUND', 'No such file')
				const doc = access!.doc
				const mine = access!.role === 'owner'
				const versions = await app.db
					.select({ id: version.id, createdAt: version.committedAt, sizeBytes: version.sizeBytes })
					.from(version)
					.where(and(eq(version.docId, doc.id), eq(version.status, 'committed')))
					.orderBy(desc(version.committedAt))
				const json = await fileJson(app, doc, context.request)
				return {
					...json,
					role: access!.role,
					links: mine ? json.links : [],
					versions: versions.map((x: { id: string; createdAt: Date; sizeBytes: number }) => ({
						id: x.id,
						createdAt: x.createdAt.toISOString(),
						sizeBytes: x.sizeBytes,
					})),
				}
			}),

		newVersion: o.protected
			.route({ method: 'POST', path: '/api/docs/{docId}/versions', successStatus: 201 })
			.input(v.object({ docId: v.string(), ...uploadInput.entries }))
			.handler(async ({ input, context }: any) => {
				const [app, ws, userId] = await ctxWs(context)
				await ownDoc(app, ws, input.docId)
				const { docId, ...rest } = input
				return startUpload(app, context.request, ws, userId, rest, docId)
			}),

		commitVersion: o.protected
			.route({ method: 'POST', path: '/api/docs/{docId}/versions/{versionId}/commit' })
			.input(v.object({ docId: v.string(), versionId: v.string() }))
			.handler(async ({ input, context }: any) => {
				const [app, ws] = await ctxWs(context)
				return commit(app, context.request, ws, input.docId, input.versionId)
			}),

		renameFile: o.protected
			.route({ method: 'PATCH', path: '/api/docs/{docId}' })
			.input(v.object({ docId: v.string(), name: v.pipe(v.string(), v.trim(), v.minLength(1), v.maxLength(200)) }))
			.handler(async ({ input, context }: any) => {
				const [app, ws] = await ctxWs(context)
				await ownDoc(app, ws, input.docId)
				const [doc] = await app.db
					.update(document)
					.set({ name: input.name, updatedAt: new Date() })
					.where(eq(document.id, input.docId))
					.returning()
				return fileJson(app, doc, context.request)
			}),

		deleteFile: o.protected
			.route({ method: 'DELETE', path: '/api/docs/{docId}' })
			.input(v.object({ docId: v.string() }))
			.handler(async ({ input, context }: any) => {
				const [app, ws] = await ctxWs(context)
				await ownDoc(app, ws, input.docId)
				const now = new Date()
				await app.db.update(document).set({ deletedAt: now }).where(eq(document.id, input.docId))
				await app.db.update(shareLink).set({ revokedAt: now }).where(and(eq(shareLink.docId, input.docId), isNull(shareLink.revokedAt)))
				return { ok: true }
			}),

		createLink: o.protected
			.route({ method: 'POST', path: '/api/docs/{docId}/links', successStatus: 201 })
			.input(v.object({ docId: v.string(), ...linkFields }))
			.handler(async ({ input, context }: any) => {
				const [app, ws, userId] = await ctxWs(context)
				await ownDoc(app, ws, input.docId)
				if (input.visibility === 'public') await requireVerified(app, userId)
				const token = randomToken()
				const [row] = await app.db
					.insert(shareLink)
					.values({
						docId: input.docId,
						workspaceId: ws.id,
						tokenHash: await sha256Hex(token),
						tokenSealed: await seal(secretOf(app), 'share-link-v1', token),
						visibility: input.visibility ?? 'link',
						allowDownload: input.allowDownload ?? false,
						allowEmbed: input.allowEmbed ?? false,
						expiresAt: input.expiresAt ? new Date(input.expiresAt) : null,
						createdBy: userId,
						createdAt: new Date(),
					})
					.returning()
				return linkJson(app, row, context.request)
			}),

		updateLink: o.protected
			.route({ method: 'PATCH', path: '/api/links/{linkId}' })
			.input(v.object({ linkId: v.string(), ...linkFields }))
			.handler(async ({ input, context }: any) => {
				const [app, ws, userId] = await ctxWs(context)
				const row = await ownLink(app, ws, input.linkId)
				if (input.visibility === 'public' && row.visibility !== 'public') await requireVerified(app, userId)
				const set: Record<string, unknown> = {}
				for (const k of ['visibility', 'allowDownload', 'allowEmbed'] as const) if (input[k] !== undefined) set[k] = input[k]
				if (input.expiresAt !== undefined) set.expiresAt = input.expiresAt ? new Date(input.expiresAt) : null
				const [updated] = Object.keys(set).length
					? await app.db.update(shareLink).set(set).where(eq(shareLink.id, row.id)).returning()
					: [row]
				return linkJson(app, updated, context.request)
			}),

		revokeLink: o.protected
			.route({ method: 'DELETE', path: '/api/links/{linkId}' })
			.input(v.object({ linkId: v.string() }))
			.handler(async ({ input, context }: any) => {
				const [app, ws] = await ctxWs(context)
				const row = await ownLink(app, ws, input.linkId)
				await app.db.update(shareLink).set({ revokedAt: new Date() }).where(eq(shareLink.id, row.id))
				return { ok: true }
			}),
	}
}

async function ownLink(app: App, ws: Workspace, linkId: string) {
	const [row] = await app.db
		.select()
		.from(shareLink)
		.where(and(eq(shareLink.id, linkId), eq(shareLink.workspaceId, ws.id), isNull(shareLink.revokedAt)))
		.limit(1)
	if (!row) fail('NOT_FOUND', 'NOT_FOUND', 'No such link')
	return row
}

async function requireVerified(app: App, userId: string) {
	const [u] = await app.db.select({ v: user.emailVerified }).from(user).where(eq(user.id, userId))
	if (!u?.v) fail('FORBIDDEN', 'EMAIL_NOT_VERIFIED', 'Verify your email before making a link public')
}
