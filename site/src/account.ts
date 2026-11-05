// A user's own data (docs/cloud-design.md §7): export everything as a zip, and delete the
// account with its files, links and stored blobs.
//
// Deletion happens through Better Auth's delete-user (password, or a session younger than a
// day), whose beforeDelete runs purgeAccount. Operators delete an account they cannot sign in
// as (a lost test account, a takedown) by adding its user id to account_deletion; the
// cleanup job then runs the same purge and removes the user.
import { and, eq, inArray, isNull } from 'drizzle-orm'

import { blobKey, bucket, type App } from './blobs'
import type { Manifest } from './files'
import {
	accountDeletion,
	appAuthCode,
	asset,
	docInvite,
	docMember,
	document,
	member,
	organization,
	session,
	shareLink,
	user,
	version,
	workspacePlan,
} from './schema'
import { docPath, normalize, depthOf } from './share'
import { zip, type Entry } from './zip'

/** The workspaces only this user belongs to: their data goes with the account. Shared
 *  workspaces (teams, from M3) stay with their other members. */
async function ownWorkspaces(app: Pick<App, 'db'>, userId: string): Promise<string[]> {
	const mine: string[] = (
		await app.db.select({ id: member.organizationId }).from(member).where(eq(member.userId, userId))
	).map((r: { id: string }) => r.id)
	const out: string[] = []
	for (const ws of mine) {
		const others = await app.db
			.select({ id: member.id })
			.from(member)
			.where(eq(member.organizationId, ws))
		if (others.length <= 1) out.push(ws)
	}
	return out
}

/** Everything of the user's own workspaces: blobs in storage, then the rows. */
export async function purgeAccount(app: Pick<App, 'db' | 'storage'>, userId: string) {
	const db = app.db
	const store = bucket(app as App)
	const workspaces = await ownWorkspaces(app, userId)
	let blobs = 0
	if (workspaces.length) {
		const hashes = await db.select({ ws: asset.workspaceId, hash: asset.hash }).from(asset).where(inArray(asset.workspaceId, workspaces))
		for (const a of hashes as { ws: string; hash: string }[]) {
			await store.delete(blobKey(a.ws, a.hash)).catch(() => {})
			blobs++
		}
		const docs: string[] = (
			await db.select({ id: document.id }).from(document).where(inArray(document.workspaceId, workspaces))
		).map((r: { id: string }) => r.id)
		if (docs.length) {
			await db.delete(docMember).where(inArray(docMember.docId, docs))
			await db.delete(docInvite).where(inArray(docInvite.docId, docs))
			await db.delete(shareLink).where(inArray(shareLink.docId, docs))
			await db.delete(version).where(inArray(version.docId, docs))
			await db.delete(document).where(inArray(document.id, docs))
		}
		await db.delete(asset).where(inArray(asset.workspaceId, workspaces))
		await db.delete(workspacePlan).where(inArray(workspacePlan.workspaceId, workspaces))
		await db.delete(member).where(inArray(member.organizationId, workspaces))
		await db.delete(organization).where(inArray(organization.id, workspaces))
	}
	// Their access to other people's documents, and invitations they sent.
	await db.delete(docMember).where(eq(docMember.userId, userId))
	await db.delete(docInvite).where(eq(docInvite.invitedBy, userId))
	// Rows elsewhere that name the user (a team's documents they created stay with the team).
	await db.delete(shareLink).where(eq(shareLink.createdBy, userId))
	await db.delete(appAuthCode).where(eq(appAuthCode.userId, userId))
	return { workspaces: workspaces.length, blobs }
}

/** Operator deletions waiting in account_deletion: purge, then remove the user itself. */
export async function runAccountDeletions(app: Pick<App, 'db' | 'storage'>) {
	const rows = await app.db.select().from(accountDeletion).where(isNull(accountDeletion.doneAt))
	let done = 0
	for (const r of rows as { userId: string }[]) {
		await purgeAccount(app, r.userId)
		await app.db.delete(session).where(eq(session.userId, r.userId))
		await app.db.delete(user).where(eq(user.id, r.userId))
		await app.db.update(accountDeletion).set({ doneAt: new Date() }).where(eq(accountDeletion.userId, r.userId))
		done++
	}
	return done
}

const enc = new TextEncoder()

/** GET /api/account/export: the account as JSON and every committed version of every file. */
export async function exportAccount(app: Pick<App, 'db' | 'storage'>, userId: string): Promise<ReadableStream<Uint8Array>> {
	const db = app.db
	const [u] = await db.select().from(user).where(eq(user.id, userId))
	const workspaces = (
		await db
			.select({ id: organization.id, name: organization.name, role: member.role, createdAt: organization.createdAt })
			.from(member)
			.innerJoin(organization, eq(organization.id, member.organizationId))
			.where(eq(member.userId, userId))
	) as { id: string; name: string; role: string; createdAt: Date }[]
	const wsIds = workspaces.map((w) => w.id)
	const docs = wsIds.length
		? await db.select().from(document).where(and(inArray(document.workspaceId, wsIds), isNull(document.deletedAt)))
		: []
	const sessions = await db
		.select({ createdAt: session.createdAt, expiresAt: session.expiresAt, userAgent: session.userAgent, ipAddress: session.ipAddress })
		.from(session)
		.where(eq(session.userId, userId))
	const entries: (Entry & { ws?: string })[] = []
	const files: object[] = []
	for (const d of docs as (typeof document.$inferSelect)[]) {
		const folder = `files/${d.name.replace(/[\\/:*?"<>|\u0000-\u001f]/g, '_').slice(0, 80)} (${d.id})`
		const versions = (await db
			.select()
			.from(version)
			.where(and(eq(version.docId, d.id), eq(version.status, 'committed')))) as (typeof version.$inferSelect)[]
		const links = await db
			.select({
				id: shareLink.id,
				visibility: shareLink.visibility,
				allowDownload: shareLink.allowDownload,
				allowEmbed: shareLink.allowEmbed,
				expiresAt: shareLink.expiresAt,
				revokedAt: shareLink.revokedAt,
				viewCount: shareLink.viewCount,
				createdAt: shareLink.createdAt,
			})
			.from(shareLink)
			.where(eq(shareLink.docId, d.id))
		files.push({ id: d.id, name: d.name, createdAt: d.createdAt, updatedAt: d.updatedAt, head: d.headVersionId, versions: versions.map((x) => ({ id: x.id, committedAt: x.committedAt, sizeBytes: x.sizeBytes })), links })
		for (const ver of versions) {
			const m = JSON.parse(ver.manifest) as Manifest
			const root = `${folder}/${ver.id}`
			const dir = '_/'.repeat(depthOf(m))
			entries.push({ path: `${root}/${docPath(m).replace(/^(_\/)+/, '')}`, hash: m.pen.hash, ws: d.workspaceId })
			for (const a of m.assets) entries.push({ path: `${root}/${normalize(dir + a.path).replace(/^(_\/)+/, '')}`, hash: a.hash, ws: d.workspaceId })
		}
	}
	const account = {
		exportedAt: new Date().toISOString(),
		user: u ? { id: u.id, name: u.name, email: u.email, emailVerified: u.emailVerified, image: u.image, createdAt: u.createdAt } : null,
		workspaces,
		sessions,
		files,
	}
	entries.unshift({ path: 'account.json', hash: '', data: enc.encode(JSON.stringify(account, null, 2)) })
	const store = bucket(app as App)
	const wsOf = new Map(entries.map((e) => [e.hash, e.ws]))
	return zip(entries, async (hash) => {
		const res = await store.get(blobKey(wsOf.get(hash)!, hash))
		return new Uint8Array(await res.arrayBuffer())
	})
}

/** GET /api/account/export with the session or the app's bearer token. */
export async function handleExport(app: App & { auth: any }, request: Request): Promise<Response> {
	if (request.method !== 'GET') return new Response('Method not allowed', { status: 405 })
	const s = await app.auth.api.getSession({ headers: request.headers }).catch(() => null)
	if (!s?.user) return new Response('Sign in', { status: 401 })
	const day = new Date().toISOString().slice(0, 10)
	return new Response(await exportAccount(app, s.user.id), {
		headers: {
			'content-type': 'application/zip',
			'content-disposition': `attachment; filename="agentic-design-export-${day}.zip"`,
			'cache-control': 'private, no-store',
			'x-content-type-options': 'nosniff',
		},
	})
}

/** POST /api/account/delete: the password, or for accounts without one (Google, GitHub) a
 *  session younger than a day. Then the purge, the user, and every session. */
export async function deleteOwnAccount(
	app: App & { auth: any },
	request: Request,
	password?: string,
): Promise<'ok' | 'PASSWORD' | 'SESSION_NOT_FRESH'> {
	const s = await app.auth.api.getSession({ headers: request.headers })
	if (!s?.user) return 'SESSION_NOT_FRESH'
	const ctx = await app.auth.$context
	const credential = await ctx.internalAdapter.findCredentialAccount(s.user.id)
	if (credential?.password) {
		if (!password || !(await ctx.password.verify({ hash: credential.password, password }))) return 'PASSWORD'
	} else if (Date.now() - new Date(s.session.createdAt).getTime() > 24 * 3600 * 1000) {
		return 'SESSION_NOT_FRESH'
	}
	await purgeAccount(app, s.user.id)
	await ctx.internalAdapter.deleteUserSessions(s.user.id)
	await ctx.internalAdapter.deleteUser(s.user.id)
	return 'ok'
}
