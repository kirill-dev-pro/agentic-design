// Personal workspaces (docs/cloud-design.md §3.2, decision 4). Every user owns exactly one
// until teams arrive in M3; it is created with the account, and a session starts in it.
import { and, eq } from 'drizzle-orm'

import { entitlementsOf, type Entitlements } from './plans'
import { member, organization, workspacePlan } from './schema'

// The database handle the backend gives auth hooks and handlers. Typed loosely here so
// that this module needs no generics from the backend declaration.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Db = any

export type Workspace = {
	id: string
	name: string
	plan: string
	entitlements: Entitlements
}

/** Create the personal workspace of a new user (idempotent). */
export async function ensurePersonalWorkspace(db: Db, userId: string): Promise<string> {
	const existing = await personalWorkspaceId(db, userId)
	if (existing) return existing
	const now = new Date()
	const [org] = await db
		.insert(organization)
		.values({ name: 'Personal', slug: `personal-${userId}`, createdAt: now })
		.onConflictDoNothing()
		.returning({ id: organization.id })
	const id: string =
		org?.id ??
		(await db.select({ id: organization.id }).from(organization).where(eq(organization.slug, `personal-${userId}`)))[0].id
	await db.insert(member).values({ organizationId: id, userId, role: 'owner', createdAt: now }).onConflictDoNothing()
	await db.insert(workspacePlan).values({ workspaceId: id, plan: 'free', updatedAt: now }).onConflictDoNothing()
	return id
}

export async function personalWorkspaceId(db: Db, userId: string): Promise<string | null> {
	const rows = await db
		.select({ id: organization.id })
		.from(member)
		.innerJoin(organization, eq(member.organizationId, organization.id))
		.where(and(eq(member.userId, userId), eq(member.role, 'owner'), eq(organization.slug, `personal-${userId}`)))
		.limit(1)
	return rows[0]?.id ?? null
}

/** The workspace a signed-in request works in: the session's, if the user belongs to it. */
export async function currentWorkspace(db: Db, userId: string, activeId: string | null): Promise<Workspace> {
	let id = activeId
	if (id) {
		const rows = await db
			.select({ id: member.organizationId })
			.from(member)
			.where(and(eq(member.userId, userId), eq(member.organizationId, id)))
			.limit(1)
		if (!rows[0]) id = null
	}
	id ??= await ensurePersonalWorkspace(db, userId)
	const rows = await db
		.select({ name: organization.name, plan: workspacePlan.plan, entitlements: workspacePlan.entitlements })
		.from(organization)
		.leftJoin(workspacePlan, eq(workspacePlan.workspaceId, organization.id))
		.where(eq(organization.id, id))
		.limit(1)
	const row = rows[0] ?? { name: 'Personal', plan: 'free', entitlements: '{}' }
	const plan = row.plan ?? 'free'
	return { id: id!, name: row.name, plan, entitlements: entitlementsOf(plan, row.entitlements) }
}
