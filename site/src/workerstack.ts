// The site's backend (docs/cloud-design.md §3): accounts through Better Auth, with Google
// and GitHub from Bunderhost's managed sign-in (added by Workerstack when the platform
// configures it), personal workspaces with a plan, and the API under /api. The Worker
// entry (server.ts) also hands it the share pages.
import { bearer, organization } from 'better-auth/plugins'
import { and, count, eq, isNull, sql, sum } from 'drizzle-orm'
import { workerstack } from 'workerstack'
import { libsql } from 'workerstack/libsql'

import * as v from 'valibot'
import { WorkerstackError } from 'workerstack'

import { access } from './access'
import type { App } from './blobs'
import { deleteOwnAccount, runAccountDeletions } from './account'
import { exchangeCode } from './app-auth'
import { cleanup } from './cleanup'
import { DocRoom } from './room/doc-room'
import { fileRoutes } from './files'
import * as schema from './schema'
import { countView, manifestOf, resolveToken, shareJson, tokenOfShareUrl } from './share'
import { currentWorkspace, ensurePersonalWorkspace } from './workspaces'

export const backend = workerstack({
	schema,
	access,
	database: { adapter: libsql() },
	auth: ({ db, env }) => ({
		baseURL: env.APP_URL,
		trustedOrigins: env.APP_URL ? [env.APP_URL] : [],
		emailAndPassword: { enabled: true, minPasswordLength: 10 },
		// Accounts are linked only explicitly, never by a matching email (cloud-design §3.1).
		account: { accountLinking: { enabled: false } },
		session: { expiresIn: 60 * 60 * 24 * 30, updateAge: 60 * 60 * 24 },
		// On in production only (Better Auth's default), with its stricter sign-in rules.
		rateLimit: { window: 60, max: 10 },
		// bearer: the Mac app sends its device session as Authorization: Bearer (src/app-auth.ts).
		plugins: [organization({ allowUserToCreateOrganization: false }), bearer({ requireSignature: false })],
		advanced: { database: { generateId: () => false } },
		databaseHooks: {
			user: {
				create: {
					after: async (user: { id: string }) => {
						await ensurePersonalWorkspace(db, user.id)
					},
				},
			},
			session: {
				create: {
					before: async (session: { userId: string; activeOrganizationId?: string | null }) => {
						// The user's after-hook may not have run yet: create the workspace here too.
						const id = await ensurePersonalWorkspace(db, session.userId)
						return { data: { ...session, activeOrganizationId: session.activeOrganizationId ?? id } }
					},
				},
			},
		},
	}),
	rateLimit: { windowMs: 60_000, max: 120 },
	// One DocRoom per cloud document, reached through env.DOC_ROOM (src/room/route.ts).
	durableObjects: { DOC_ROOM: DocRoom },
	jobs: (j) =>
		j.define({
			cleanup: j.cron({
				schedule: '30 3 * * *',
				handler: async (_invocation, ctx) => {
					await cleanup(ctx as unknown as App)
				},
			}),
			accountDeletions: j.cron({
				schedule: '15 * * * *',
				handler: async (_invocation, ctx) => {
					await runAccountDeletions(ctx as unknown as App)
				},
			}),
		}),
	api: (o) => ({
		...fileRoutes(o),

		share: o.public
			.route({ method: 'GET', path: '/api/share/{token}' })
			.input(v.object({ token: v.string() }))
			.handler(async ({ input, context }) => {
				const app = context as unknown as App
				const r = await resolveToken(app, input.token)
				if (typeof r === 'string') throw new WorkerstackError('NOT_FOUND', r === 'NOT_FOUND' ? 'No such link' : 'This link no longer works', { reason: r })
				const m = await manifestOf(app, r.doc.id, r.doc.headVersionId!)
				if (!m) throw new WorkerstackError('NOT_FOUND', 'No such link', { reason: 'NOT_FOUND' })
				await countView(app, r.link!.id)
				context.resHeaders?.set('cache-control', 'private, no-store')
				context.resHeaders?.set('x-robots-tag', 'noindex')
				return shareJson(app, r, input.token, m, context.request)
			}),

		oembed: o.public
			.route({ method: 'GET', path: '/api/oembed' })
			.input(v.object({ url: v.string(), maxwidth: v.optional(v.string()), maxheight: v.optional(v.string()) }))
			.handler(async ({ input, context }) => {
				const app = context as unknown as App
				const token = tokenOfShareUrl(app, input.url, context.request)
				const r = token ? await resolveToken(app, token) : 'NOT_FOUND'
				if (typeof r === 'string' || !r.link!.allowEmbed) throw new WorkerstackError('NOT_FOUND', 'Not embeddable')
				const width = Math.min(Number(input.maxwidth) || 800, 1600)
				const height = Math.min(Number(input.maxheight) || 450, 1200)
				const site = new URL(input.url).origin
				return {
					version: '1.0',
					type: 'rich',
					provider_name: 'Agentic Design',
					provider_url: site,
					title: r.doc.name,
					author_name: r.owner,
					width,
					height,
					html: `<iframe src="${site}/embed/${token}" width="${width}" height="${height}" style="border:0" allowfullscreen loading="lazy"></iframe>`,
				}
			}),

		appToken: o.public
			.route({ method: 'POST', path: '/api/app-auth/token' })
			.input(v.object({ code: v.string(), verifier: v.string() }))
			.handler(async ({ input, context }) => {
				const out = await exchangeCode(context as never, input.code, input.verifier)
				if (!out) throw new WorkerstackError('BAD_REQUEST', 'The code is not valid', { reason: 'INVALID_CODE' })
				context.resHeaders?.set('cache-control', 'no-store')
				return out
			}),

		deleteAccount: o.protected
			.route({ method: 'POST', path: '/api/account/delete' })
			.input(v.object({ password: v.optional(v.string()) }))
			.handler(async ({ input, context }) => {
				const r = await deleteOwnAccount(context as never, context.request, input.password)
				if (r !== 'ok') throw new WorkerstackError('FORBIDDEN', r === 'PASSWORD' ? 'The password is not right' : 'Sign in again to delete the account', { reason: r })
				context.resHeaders?.append('set-cookie', 'better-auth.session_token=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax')
				context.resHeaders?.append('set-cookie', '__Secure-better-auth.session_token=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax')
				return { ok: true }
			}),

		viewMetric: o.public
			.route({ method: 'POST', path: '/api/metrics/view', successStatus: 204 })
			.input(
				v.object({
					webgpu: v.boolean(),
					platform: v.picklist(['ios', 'android', 'mac', 'windows', 'linux', 'other']),
					standalone: v.optional(v.boolean(), false),
				}),
			)
			.handler(async ({ input, context }) => {
				const day = new Date().toISOString().slice(0, 10)
				await context.db
					.insert(schema.viewMetric)
					.values({ day, webgpu: input.webgpu, platform: input.platform, standalone: input.standalone, count: 1 })
					.onConflictDoUpdate({
						target: [schema.viewMetric.day, schema.viewMetric.webgpu, schema.viewMetric.platform, schema.viewMetric.standalone],
						set: { count: sql`${schema.viewMetric.count} + 1` },
					})
			}),

		version: o.public
			.route({ method: 'GET', path: '/api/version' })
			.handler(() => ({ name: 'agentic-design-site', api: 1 })),

		me: o.protected
			.route({ method: 'GET', path: '/api/me' })
			.handler(async ({ context }) => {
				const { db, user, session } = context
				const ws = await currentWorkspace(db, user.id, session.activeOrganizationId)
				const [files] = await db
					.select({ n: count() })
					.from(schema.document)
					.where(and(eq(schema.document.workspaceId, ws.id), isNull(schema.document.deletedAt)))
				const [bytes] = await db
					.select({ n: sum(schema.asset.size) })
					.from(schema.asset)
					.where(eq(schema.asset.workspaceId, ws.id))
				return {
					user: {
						id: user.id,
						name: user.name,
						email: user.email,
						emailVerified: Boolean(user.emailVerified),
						image: (user as { image?: string | null }).image ?? null,
					},
					workspace: {
						id: ws.id,
						name: ws.name,
						plan: ws.plan,
						entitlements: ws.entitlements,
						usage: { storageBytes: Number(bytes?.n ?? 0), sharedFiles: Number(files?.n ?? 0) },
					},
				}
			}),
	}),
})
