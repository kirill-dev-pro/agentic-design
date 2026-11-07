// Comments on a cloud document, in threads (decision 18, cloud-design §4.1). Who may do what:
//
//   read            everyone with access (viewer, commenter, editor, owner)
//   start a thread  commenter, editor, owner
//   reply           commenter, editor, owner
//   change the text the comment's author only
//   delete          the comment's author, or an editor or the owner (a thread's first comment
//                   takes its replies with it)
//   resolve, reopen the thread's author, an editor or the owner
//
// The comments live in the database, not in the .pen: they survive any edit and never reach a
// downloaded file. After a change the room tells its people to fetch them again (src/room).
import { and, asc, eq, isNull, or } from 'drizzle-orm'
import * as v from 'valibot'
import { WorkerstackError } from 'workerstack'

import type { App } from './blobs'
import { docAccess, tellRoom, type Role } from './invites'
import { comment, user } from './schema'

const MAX_BODY = 5000
const MAX_THREADS = 2000
const MAX_REPLIES = 500

export const canComment = (r: Role) => r !== 'viewer'
const canModerate = (r: Role) => r === 'editor' || r === 'owner'

const fail = (code: 'BAD_REQUEST' | 'FORBIDDEN' | 'NOT_FOUND', reason: string, message: string): never => {
	throw new WorkerstackError(code, message, { reason })
}

async function access(app: App, userId: string, docId: string) {
	const a = await docAccess(app.db, userId, docId)
	if (!a) fail('NOT_FOUND', 'NOT_FOUND', 'No such file')
	return a!
}

const body = v.pipe(v.string(), v.trim(), v.minLength(1), v.maxLength(MAX_BODY))
const anchor = v.object({
	x: v.pipe(v.number(), v.finite()),
	y: v.pipe(v.number(), v.finite()),
	node: v.optional(v.pipe(v.string(), v.maxLength(200))),
	page: v.optional(v.pipe(v.number(), v.integer(), v.minValue(0))),
})

type Row = typeof comment.$inferSelect

/** The document's threads, oldest first, each with its replies and what this person may do. */
async function threadsJson(app: App, docId: string, me: string, role: Role) {
	const rows = (await app.db
		.select({ c: comment, name: user.name, image: user.image })
		.from(comment)
		.innerJoin(user, eq(user.id, comment.authorId))
		.where(eq(comment.docId, docId))
		.orderBy(asc(comment.createdAt))) as { c: Row; name: string; image: string | null }[]
	const one = (r: { c: Row; name: string; image: string | null }) => ({
		id: r.c.id,
		author: { id: r.c.authorId, name: r.name, image: r.image },
		body: r.c.body,
		createdAt: r.c.createdAt.toISOString(),
		editedAt: r.c.editedAt?.toISOString() ?? null,
		canEdit: r.c.authorId === me,
		canDelete: r.c.authorId === me || canModerate(role),
	})
	const threads = rows
		.filter((r) => r.c.threadId === null)
		.map((r) => ({
			...one(r),
			anchor: r.c.anchor ? JSON.parse(r.c.anchor) : null,
			resolvedAt: r.c.resolvedAt?.toISOString() ?? null,
			canResolve: r.c.authorId === me || canModerate(role),
			replies: [] as ReturnType<typeof one>[],
		}))
	const byId = new Map(threads.map((t) => [t.id, t]))
	for (const r of rows) if (r.c.threadId) byId.get(r.c.threadId)?.replies.push(one(r))
	return { role, canComment: canComment(role), threads }
}

const changed = (docId: string, thread: string, by: string) => tellRoom(docId, '/notify', { t: 'comments', thread, by })

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function commentRoutes(o: any) {
	return {
		listComments: o.protected
			.route({ method: 'GET', path: '/api/docs/{docId}/comments' })
			.input(v.object({ docId: v.string() }))
			.handler(async ({ input, context }: any) => {
				const app = context as App
				const a = await access(app, context.user.id, input.docId)
				context.resHeaders?.set('cache-control', 'private, no-store')
				return threadsJson(app, input.docId, context.user.id, a.role)
			}),

		addComment: o.protected
			.route({ method: 'POST', path: '/api/docs/{docId}/comments', successStatus: 201 })
			.input(v.object({ docId: v.string(), body, anchor: v.optional(anchor), threadId: v.optional(v.string()) }))
			.handler(async ({ input, context }: any) => {
				const app = context as App
				const a = await access(app, context.user.id, input.docId)
				if (!canComment(a.role)) fail('FORBIDDEN', 'VIEW_ONLY', 'You can view this file, not comment on it')
				if (input.threadId) {
					const [root] = await app.db
						.select({ id: comment.id })
						.from(comment)
						.where(and(eq(comment.id, input.threadId), eq(comment.docId, input.docId), isNull(comment.threadId)))
					if (!root) fail('NOT_FOUND', 'NO_THREAD', 'This thread was deleted')
					const replies = await app.db.select({ id: comment.id }).from(comment).where(eq(comment.threadId, input.threadId))
					if (replies.length >= MAX_REPLIES) fail('FORBIDDEN', 'TOO_MANY', `A thread holds at most ${MAX_REPLIES} replies`)
				} else {
					if (!input.anchor) fail('BAD_REQUEST', 'NO_ANCHOR', 'A new comment needs its place: anchor {x, y}')
					const roots = await app.db
						.select({ id: comment.id })
						.from(comment)
						.where(and(eq(comment.docId, input.docId), isNull(comment.threadId)))
					if (roots.length >= MAX_THREADS) fail('FORBIDDEN', 'TOO_MANY', `A file holds at most ${MAX_THREADS} threads`)
				}
				const [row] = await app.db
					.insert(comment)
					.values({
						docId: input.docId,
						threadId: input.threadId ?? null,
						authorId: context.user.id,
						body: input.body,
						anchor: input.threadId ? null : JSON.stringify(input.anchor),
						createdAt: new Date(),
					})
					.returning()
				await changed(input.docId, input.threadId ?? row.id, context.user.id)
				return { id: row.id, threadId: row.threadId }
			}),

		changeComment: o.protected
			.route({ method: 'PATCH', path: '/api/docs/{docId}/comments/{commentId}' })
			.input(v.object({ docId: v.string(), commentId: v.string(), body: v.optional(body), resolved: v.optional(v.boolean()) }))
			.handler(async ({ input, context }: any) => {
				const app = context as App
				const a = await access(app, context.user.id, input.docId)
				const [row] = await app.db.select().from(comment).where(and(eq(comment.id, input.commentId), eq(comment.docId, input.docId)))
				if (!row) fail('NOT_FOUND', 'NOT_FOUND', 'No such comment')
				const set: Partial<Row> = {}
				if (input.body !== undefined) {
					if (row!.authorId !== context.user.id) fail('FORBIDDEN', 'NOT_AUTHOR', 'Only its author can change a comment')
					if (!canComment(a.role)) fail('FORBIDDEN', 'VIEW_ONLY', 'You can view this file, not comment on it')
					set.body = input.body
					set.editedAt = new Date()
				}
				if (input.resolved !== undefined) {
					if (row!.threadId) fail('BAD_REQUEST', 'NOT_THREAD', 'Resolve the thread, not a reply')
					if (row!.authorId !== context.user.id && !canModerate(a.role)) fail('FORBIDDEN', 'NOT_ALLOWED', 'The thread’s author or an editor resolves it')
					set.resolvedAt = input.resolved ? new Date() : null
					set.resolvedBy = input.resolved ? context.user.id : null
				}
				if (Object.keys(set).length === 0) fail('BAD_REQUEST', 'NOTHING', 'Pass body or resolved')
				await app.db.update(comment).set(set).where(eq(comment.id, row!.id))
				await changed(input.docId, row!.threadId ?? row!.id, context.user.id)
				return { ok: true }
			}),

		deleteComment: o.protected
			.route({ method: 'DELETE', path: '/api/docs/{docId}/comments/{commentId}' })
			.input(v.object({ docId: v.string(), commentId: v.string() }))
			.handler(async ({ input, context }: any) => {
				const app = context as App
				const a = await access(app, context.user.id, input.docId)
				const [row] = await app.db.select().from(comment).where(and(eq(comment.id, input.commentId), eq(comment.docId, input.docId)))
				if (!row) return { ok: true }
				if (row.authorId !== context.user.id && !canModerate(a.role))
					fail('FORBIDDEN', 'NOT_ALLOWED', 'Only its author or an editor can delete a comment')
				// a thread's first comment takes its replies with it
				await app.db.delete(comment).where(row.threadId ? eq(comment.id, row.id) : or(eq(comment.id, row.id), eq(comment.threadId, row.id)))
				await changed(input.docId, row.threadId ?? row.id, context.user.id)
				return { ok: true }
			}),
	}
}
