// Giving named people access to one document (cloud-design §3.2; contract §10). A document is
// private to its workspace by default. Its owner invites someone by email as a viewer or an
// editor; the invitation is a link (no mail yet: the inviter passes it on). Whoever opens the
// link signed in with that same email becomes a member of the document: it shows in their files
// and its room lets them in with that role. Changing a role or removing someone takes effect at
// once, also in an open room.
import { and, desc, eq, gt, isNull } from 'drizzle-orm'
import * as v from 'valibot'
import { WorkerstackError } from 'workerstack'
import { registeredWorker } from 'workerstack/workers'

import { appUrl, secretOf, type App } from './blobs'
import { randomToken, seal, sha256Hex, unseal } from './crypto'
import { docInvite, docMember, document, member, user } from './schema'

export type Role = 'owner' | 'editor' | 'commenter' | 'viewer'
export type MemberRole = Exclude<Role, 'owner'>
type Doc = typeof document.$inferSelect

const INVITE_DAYS = 14
const MAX_PEOPLE = 50

/** A person's role on a document: through its workspace (owner) or as an invited member; null for none. */
export async function docAccess(db: App['db'], userId: string, docId: string): Promise<{ doc: Doc; role: Role } | null> {
	const [own] = await db
		.select({ doc: document })
		.from(document)
		.innerJoin(member, and(eq(member.organizationId, document.workspaceId), eq(member.userId, userId)))
		.where(and(eq(document.id, docId), isNull(document.deletedAt)))
		.limit(1)
	if (own) return { doc: own.doc, role: 'owner' }
	const [shared] = await db
		.select({ doc: document, role: docMember.role })
		.from(docMember)
		.innerJoin(document, eq(document.id, docMember.docId))
		.where(and(eq(docMember.docId, docId), eq(docMember.userId, userId), isNull(document.deletedAt)))
		.limit(1)
	return shared ? { doc: shared.doc, role: shared.role } : null
}

/** Documents shared with a person (not in their own workspace), newest first. */
export async function sharedWith(db: App['db'], userId: string) {
	return (await db
		.select({ doc: document, role: docMember.role, owner: user.name })
		.from(docMember)
		.innerJoin(document, eq(document.id, docMember.docId))
		.innerJoin(user, eq(user.id, document.createdBy))
		.where(and(eq(docMember.userId, userId), isNull(document.deletedAt)))
		.orderBy(desc(document.updatedAt))) as { doc: Doc; role: MemberRole; owner: string }[]
}

const fail = (code: 'BAD_REQUEST' | 'FORBIDDEN' | 'NOT_FOUND' | 'CONFLICT', reason: string, message: string): never => {
	throw new WorkerstackError(code, message, { reason })
}

async function ownerOnly(app: App, userId: string, docId: string) {
	const a = await docAccess(app.db, userId, docId)
	if (!a) fail('NOT_FOUND', 'NOT_FOUND', 'No such file')
	if (a!.role !== 'owner') fail('FORBIDDEN', 'NOT_OWNER', 'Only the owner can change who has access')
	return a!.doc
}

const normEmail = (e: string) => e.trim().toLowerCase()
const email = v.pipe(v.string(), v.trim(), v.maxLength(254), v.email())
const role = v.picklist(['viewer', 'commenter', 'editor'])

type RoomNs = { idFromName(n: string): unknown; get(id: unknown): { fetch(i: string, init?: RequestInit): Promise<Response> } }

/** A request to a document's room (kick, notify); a room that is not running has nobody to tell. */
export async function tellRoom(docId: string, path: '/kick' | '/notify', body: unknown) {
	// The room's namespace is a Worker binding, not an env string: from the isolate's registered env.
	const ns = (registeredWorker()?.env as { DOC_ROOM?: RoomNs } | undefined)?.DOC_ROOM
	if (!ns) return
	try {
		await ns.get(ns.idFromName(docId)).fetch(`https://room${path}`, { method: 'POST', body: JSON.stringify(body) })
	} catch {
		// nobody to tell
	}
}

/** Close a person's sockets in an open room after their role changed or was removed. */
const kick = (docId: string, userId: string, reason: 'ROLE_CHANGED' | 'REVOKED') => tellRoom(docId, '/kick', { userId, reason })

async function inviteJson(app: App, row: typeof docInvite.$inferSelect, request?: Request) {
	const token = await unseal(secretOf(app), 'doc-invite-v1', row.tokenSealed)
	return {
		id: row.id,
		email: row.email,
		role: row.role,
		url: token ? `${appUrl(app, request)}/i/${token}` : null,
		createdAt: row.createdAt.toISOString(),
		expiresAt: row.expiresAt.toISOString(),
	}
}

async function peopleJson(app: App, doc: Doc, request?: Request) {
	const [owner] = await app.db.select({ id: user.id, name: user.name, email: user.email }).from(user).where(eq(user.id, doc.createdBy))
	const members = await app.db
		.select({ userId: docMember.userId, role: docMember.role, addedAt: docMember.createdAt, name: user.name, email: user.email })
		.from(docMember)
		.innerJoin(user, eq(user.id, docMember.userId))
		.where(eq(docMember.docId, doc.id))
		.orderBy(docMember.createdAt)
	const invites = await app.db
		.select()
		.from(docInvite)
		.where(and(eq(docInvite.docId, doc.id), isNull(docInvite.acceptedAt), isNull(docInvite.revokedAt), gt(docInvite.expiresAt, new Date())))
		.orderBy(docInvite.createdAt)
	return {
		owner: owner ? { userId: owner.id, name: owner.name, email: owner.email } : null,
		members: members.map((m: { userId: string; name: string; email: string; role: string; addedAt: Date }) => ({ userId: m.userId, name: m.name, email: m.email, role: m.role, addedAt: m.addedAt.toISOString() })),
		invites: await Promise.all(invites.map((i: typeof docInvite.$inferSelect) => inviteJson(app, i, request))),
	}
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function inviteRoutes(o: any) {
	return {
		listPeople: o.protected
			.route({ method: 'GET', path: '/api/docs/{docId}/people' })
			.input(v.object({ docId: v.string() }))
			.handler(async ({ input, context }: any) => {
				const app = context as App
				const doc = await ownerOnly(app, context.user.id, input.docId)
				return peopleJson(app, doc, context.request)
			}),

		invite: o.protected
			.route({ method: 'POST', path: '/api/docs/{docId}/invites', successStatus: 201 })
			.input(v.object({ docId: v.string(), email, role: v.optional(role, 'viewer') }))
			.handler(async ({ input, context }: any) => {
				const app = context as App
				const doc = await ownerOnly(app, context.user.id, input.docId)
				const address = normEmail(input.email)
				if (address === normEmail(context.user.email)) fail('BAD_REQUEST', 'SELF', 'You already own this file')
				const people = await peopleJson(app, doc)
				if (people.members.some((m: { email: string }) => normEmail(m.email) === address))
					fail('CONFLICT', 'ALREADY_MEMBER', 'This person already has access; change their role instead')
				const open = people.invites.find((i: { email: string }) => i.email === address)
				if (open) {
					// Inviting again changes the role of the open invitation and keeps its link.
					const [row] = await app.db.update(docInvite).set({ role: input.role }).where(eq(docInvite.id, open.id)).returning()
					return inviteJson(app, row, context.request)
				}
				if (people.members.length + people.invites.length >= MAX_PEOPLE) fail('FORBIDDEN', 'TOO_MANY', `A file can be shared with at most ${MAX_PEOPLE} people`)
				const token = randomToken()
				const now = new Date()
				const [row] = await app.db
					.insert(docInvite)
					.values({
						docId: doc.id,
						email: address,
						role: input.role,
						tokenHash: await sha256Hex(token),
						tokenSealed: await seal(secretOf(app), 'doc-invite-v1', token),
						invitedBy: context.user.id,
						createdAt: now,
						expiresAt: new Date(now.getTime() + INVITE_DAYS * 86_400_000),
					})
					.returning()
				return inviteJson(app, row, context.request)
			}),

		changeInvite: o.protected
			.route({ method: 'PATCH', path: '/api/docs/{docId}/invites/{inviteId}' })
			.input(v.object({ docId: v.string(), inviteId: v.string(), role }))
			.handler(async ({ input, context }: any) => {
				const app = context as App
				await ownerOnly(app, context.user.id, input.docId)
				const [row] = await app.db
					.update(docInvite)
					.set({ role: input.role })
					.where(and(eq(docInvite.id, input.inviteId), eq(docInvite.docId, input.docId), isNull(docInvite.acceptedAt), isNull(docInvite.revokedAt)))
					.returning()
				if (!row) fail('NOT_FOUND', 'NOT_FOUND', 'No such invitation')
				return inviteJson(app, row, context.request)
			}),

		revokeInvite: o.protected
			.route({ method: 'DELETE', path: '/api/docs/{docId}/invites/{inviteId}' })
			.input(v.object({ docId: v.string(), inviteId: v.string() }))
			.handler(async ({ input, context }: any) => {
				const app = context as App
				await ownerOnly(app, context.user.id, input.docId)
				await app.db
					.update(docInvite)
					.set({ revokedAt: new Date() })
					.where(and(eq(docInvite.id, input.inviteId), eq(docInvite.docId, input.docId), isNull(docInvite.acceptedAt)))
				return { ok: true }
			}),

		changeMember: o.protected
			.route({ method: 'PATCH', path: '/api/docs/{docId}/people/{userId}' })
			.input(v.object({ docId: v.string(), userId: v.string(), role }))
			.handler(async ({ input, context }: any) => {
				const app = context as App
				await ownerOnly(app, context.user.id, input.docId)
				const [row] = await app.db
					.update(docMember)
					.set({ role: input.role })
					.where(and(eq(docMember.docId, input.docId), eq(docMember.userId, input.userId)))
					.returning()
				if (!row) fail('NOT_FOUND', 'NOT_FOUND', 'This person has no access')
				await kick(input.docId, input.userId, 'ROLE_CHANGED')
				return { userId: row.userId, role: row.role }
			}),

		removeMember: o.protected
			.route({ method: 'DELETE', path: '/api/docs/{docId}/people/{userId}' })
			.input(v.object({ docId: v.string(), userId: v.string() }))
			.handler(async ({ input, context }: any) => {
				const app = context as App
				// The owner removes anyone; a member may remove themselves (leave the file).
				if (input.userId !== context.user.id) await ownerOnly(app, context.user.id, input.docId)
				await app.db.delete(docMember).where(and(eq(docMember.docId, input.docId), eq(docMember.userId, input.userId)))
				await kick(input.docId, input.userId, 'REVOKED')
				return { ok: true }
			}),
	}
}

// ---------------------------------------------------------------- the invitation link: /i/<token>

type Lookup = { invite: typeof docInvite.$inferSelect; doc: Doc; inviter: string } | 'NOT_FOUND' | 'GONE'

async function lookup(app: App, token: string): Promise<Lookup> {
	if (!/^[0-9A-Za-z]{22}$/.test(token)) return 'NOT_FOUND'
	const [row] = await app.db
		.select({ invite: docInvite, doc: document, inviter: user.name })
		.from(docInvite)
		.innerJoin(document, eq(document.id, docInvite.docId))
		.innerJoin(user, eq(user.id, docInvite.invitedBy))
		.where(eq(docInvite.tokenHash, await sha256Hex(token)))
		.limit(1)
	if (!row) return 'NOT_FOUND'
	if (row.invite.revokedAt || row.invite.acceptedAt || row.doc.deletedAt || row.invite.expiresAt.getTime() <= Date.now()) return 'GONE'
	return row
}

/** Accept: the signed-in account must have the invited email. Returns the document id. */
export async function acceptInvite(app: App, token: string, signedIn: { id: string; email: string }) {
	const r = await lookup(app, token)
	if (typeof r === 'string') return r
	if (normEmail(signedIn.email) !== r.invite.email) return 'WRONG_ACCOUNT' as const
	const own = await docAccess(app.db, signedIn.id, r.doc.id)
	if (!own) {
		await app.db
			.insert(docMember)
			.values({ docId: r.doc.id, userId: signedIn.id, role: r.invite.role, invitedBy: r.invite.invitedBy, createdAt: new Date() })
			.onConflictDoUpdate({ target: [docMember.docId, docMember.userId], set: { role: r.invite.role } })
	}
	await app.db.update(docInvite).set({ acceptedAt: new Date(), acceptedBy: signedIn.id }).where(eq(docInvite.id, r.invite.id))
	return { docId: r.doc.id }
}

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!)

function page(status: number, body: string) {
	return new Response(
		`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>An invitation · Agentic Design</title><meta name="robots" content="noindex"><style>body{font:16px/1.5 system-ui,sans-serif;max-width:30rem;margin:15vh auto;padding:0 1.5rem;color:#1a1a1b}@media(prefers-color-scheme:dark){body{background:#1a1a1b;color:#eee}}button{font:inherit;padding:.6rem 1.2rem;border-radius:.5rem;border:0;background:#c96442;color:#fff;cursor:pointer}a{color:inherit}</style></head><body>${body}</body></html>`,
		{
			status,
			headers: {
				'content-type': 'text/html; charset=utf-8',
				'cache-control': 'no-store',
				'content-security-policy': "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'",
				'referrer-policy': 'same-origin',
				'x-content-type-options': 'nosniff',
			},
		},
	)
}

/** GET /i/<token>: who invites to what; POST: accept, then on to /files. */
export async function handleInvitePage(app: App & { auth: any }, request: Request): Promise<Response> {
	const url = new URL(request.url)
	const token = url.pathname.split('/')[2] ?? ''
	const r = await lookup(app, token)
	if (r === 'NOT_FOUND') return page(404, '<h1>This invitation does not exist</h1><p>Ask the person who shared the file for a new link.</p>')
	if (r === 'GONE') return page(410, '<h1>This invitation no longer works</h1><p>It was used, withdrawn or has expired. Ask for a new one.</p>')
	const session = await app.auth.api.getSession({ headers: request.headers }).catch(() => null)
	if (!session?.user) {
		return new Response(null, { status: 302, headers: { location: `/signin?next=${encodeURIComponent(url.pathname)}`, 'cache-control': 'no-store' } })
	}
	const what = `<b>${esc(r.doc.name)}</b> from ${esc(r.inviter)}, as ${r.invite.role === 'editor' ? 'an editor' : r.invite.role === 'commenter' ? 'a commenter' : 'a viewer'}`
	if (normEmail(session.user.email) !== r.invite.email)
		return page(
			403,
			`<h1>This invitation is for another account</h1><p>It was sent to a different email address than the one you are signed in with (${esc(session.user.email)}). Sign out and sign in with the invited address.</p><p><a href="/account">Your account</a></p>`,
		)
	if (request.method === 'GET')
		return page(200, `<h1>You are invited</h1><p>${what}.</p><form method="post"><button type="submit">Open the file</button></form>`)
	if (request.method !== 'POST') return page(405, '<h1>Not allowed</h1>')
	const origin = request.headers.get('origin')
	if (origin && origin !== 'null' ? origin !== url.origin : request.headers.get('sec-fetch-site') !== 'same-origin')
		return page(403, '<h1>Not allowed</h1>')
	const done = await acceptInvite(app, token, session.user)
	if (typeof done === 'string') return page(410, '<h1>This invitation no longer works</h1>')
	return new Response(null, { status: 303, headers: { location: `/d/${encodeURIComponent(done.docId)}`, 'cache-control': 'no-store' } })
}
