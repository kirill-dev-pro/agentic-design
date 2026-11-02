// The site's tables (docs/cloud-design.md §3.7). Better Auth's own tables come first: user,
// session, account, verification, and the organization plugin's organization, member and
// invitation. A workspace is an organization; every user gets a personal one at sign-up.
// Then the cloud's: the plan of a workspace, documents (in M1 shared files), their
// versions, content-addressed assets, and share links. Workerstack's own tables (jobs,
// idempotency, files) come from workerstack/schema.
import { generateTypeId, typeid } from 'workerstack'
import { index, integer, primaryKey, sqliteTable, text, uniqueIndex } from 'drizzle-orm/sqlite-core'

export * from 'workerstack/schema'

const timestamp = (name: string) => integer(name, { mode: 'timestamp' })

// ---------------------------------------------------------------- Better Auth

export const user = sqliteTable('user', {
	id: typeid('user').primaryKey().$defaultFn(() => generateTypeId('user')),
	name: text('name').notNull(),
	email: text('email').notNull().unique(),
	emailVerified: integer('emailVerified', { mode: 'boolean' }).notNull().default(false),
	image: text('image'),
	createdAt: timestamp('createdAt').notNull(),
	updatedAt: timestamp('updatedAt').notNull(),
})

export const session = sqliteTable(
	'session',
	{
		id: typeid('session').primaryKey().$defaultFn(() => generateTypeId('session')),
		expiresAt: timestamp('expiresAt').notNull(),
		token: text('token').notNull().unique(),
		createdAt: timestamp('createdAt').notNull(),
		updatedAt: timestamp('updatedAt').notNull(),
		ipAddress: text('ipAddress'),
		userAgent: text('userAgent'),
		userId: typeid('user').notNull().references(() => user.id, { onDelete: 'cascade' }),
		activeOrganizationId: text('activeOrganizationId'),
		activeTeamId: text('activeTeamId'),
	},
	(t) => [index('session_user_idx').on(t.userId)],
)

export const account = sqliteTable(
	'account',
	{
		id: typeid('account').primaryKey().$defaultFn(() => generateTypeId('account')),
		accountId: text('accountId').notNull(),
		providerId: text('providerId').notNull(),
		userId: typeid('user').notNull().references(() => user.id, { onDelete: 'cascade' }),
		accessToken: text('accessToken'),
		refreshToken: text('refreshToken'),
		idToken: text('idToken'),
		accessTokenExpiresAt: timestamp('accessTokenExpiresAt'),
		refreshTokenExpiresAt: timestamp('refreshTokenExpiresAt'),
		scope: text('scope'),
		password: text('password'),
		createdAt: timestamp('createdAt').notNull(),
		updatedAt: timestamp('updatedAt').notNull(),
	},
	(t) => [index('account_user_idx').on(t.userId)],
)

export const verification = sqliteTable('verification', {
	id: typeid('verification').primaryKey().$defaultFn(() => generateTypeId('verification')),
	identifier: text('identifier').notNull(),
	value: text('value').notNull(),
	expiresAt: timestamp('expiresAt').notNull(),
	createdAt: timestamp('createdAt'),
	updatedAt: timestamp('updatedAt'),
})

export const organization = sqliteTable('organization', {
	id: typeid('ws').primaryKey().$defaultFn(() => generateTypeId('ws')),
	name: text('name').notNull(),
	slug: text('slug').notNull().unique(),
	logo: text('logo'),
	createdAt: timestamp('createdAt').notNull(),
	metadata: text('metadata'),
})

export const member = sqliteTable(
	'member',
	{
		id: typeid('member').primaryKey().$defaultFn(() => generateTypeId('member')),
		organizationId: typeid('ws').notNull().references(() => organization.id, { onDelete: 'cascade' }),
		userId: typeid('user').notNull().references(() => user.id, { onDelete: 'cascade' }),
		role: text('role').notNull().default('member'),
		createdAt: timestamp('createdAt').notNull(),
	},
	(t) => [index('member_user_idx').on(t.userId), index('member_org_idx').on(t.organizationId)],
)

export const invitation = sqliteTable('invitation', {
	id: typeid('invite').primaryKey().$defaultFn(() => generateTypeId('invite')),
	organizationId: typeid('ws').notNull().references(() => organization.id, { onDelete: 'cascade' }),
	email: text('email').notNull(),
	role: text('role'),
	teamId: text('teamId'),
	status: text('status').notNull().default('pending'),
	expiresAt: timestamp('expiresAt').notNull(),
	createdAt: timestamp('createdAt').notNull(),
	inviterId: typeid('user').notNull().references(() => user.id, { onDelete: 'cascade' }),
})

// ---------------------------------------------------------------- the cloud

/** A workspace's plan and what it entitles to. Code checks entitlements, never the plan. */
export const workspacePlan = sqliteTable('workspace_plan', {
	workspaceId: typeid('ws').primaryKey().references(() => organization.id, { onDelete: 'cascade' }),
	plan: text('plan').notNull().default('free'),
	/** JSON: Entitlements (src/plans.ts); keys not set fall back to the plan's defaults. */
	entitlements: text('entitlements').notNull().default('{}'),
	updatedAt: timestamp('updatedAt').notNull(),
})

/** A document: in M1 a shared file (an uploaded .pen, one version per upload). */
export const document = sqliteTable(
	'document',
	{
		id: typeid('doc').primaryKey().$defaultFn(() => generateTypeId('doc')),
		workspaceId: typeid('ws').notNull().references(() => organization.id, { onDelete: 'cascade' }),
		kind: text('kind', { enum: ['shared', 'cloud'] }).notNull().default('shared'),
		name: text('name').notNull(),
		headVersionId: text('headVersionId'),
		sizeBytes: integer('sizeBytes').notNull().default(0),
		createdBy: typeid('user').notNull().references(() => user.id),
		createdAt: timestamp('createdAt').notNull(),
		updatedAt: timestamp('updatedAt').notNull(),
		deletedAt: timestamp('deletedAt'),
	},
	(t) => [index('document_ws_idx').on(t.workspaceId, t.deletedAt, t.updatedAt)],
)

/** One upload of a document. The manifest maps the document's relative paths to assets. */
export const version = sqliteTable(
	'version',
	{
		id: typeid('ver').primaryKey().$defaultFn(() => generateTypeId('ver')),
		docId: typeid('doc').notNull().references(() => document.id, { onDelete: 'cascade' }),
		workspaceId: typeid('ws').notNull(),
		status: text('status', { enum: ['pending', 'committed'] }).notNull().default('pending'),
		penHash: text('penHash').notNull(),
		/** JSON: { assets: [{path, hash, size, type}], missing: [path], previews: {og?, frames} } */
		manifest: text('manifest').notNull(),
		sizeBytes: integer('sizeBytes').notNull(),
		createdBy: typeid('user').notNull().references(() => user.id),
		createdAt: timestamp('createdAt').notNull(),
		committedAt: timestamp('committedAt'),
	},
	(t) => [index('version_doc_idx').on(t.docId, t.status)],
)

/** A blob, stored once per workspace under assets/<workspaceId>/<hash>. */
export const asset = sqliteTable(
	'asset',
	{
		workspaceId: typeid('ws').notNull().references(() => organization.id, { onDelete: 'cascade' }),
		hash: text('hash').notNull(),
		size: integer('size').notNull(),
		type: text('type').notNull(),
		/** pending until a commit has seen the object in storage */
		ready: integer('ready', { mode: 'boolean' }).notNull().default(false),
		createdAt: timestamp('createdAt').notNull(),
	},
	(t) => [primaryKey({ columns: [t.workspaceId, t.hash] })],
)

export const shareLink = sqliteTable(
	'share_link',
	{
		id: typeid('link').primaryKey().$defaultFn(() => generateTypeId('link')),
		docId: typeid('doc').notNull().references(() => document.id, { onDelete: 'cascade' }),
		workspaceId: typeid('ws').notNull(),
		/** SHA-256 of the token, hex: the only thing a lookup uses. */
		tokenHash: text('tokenHash').notNull(),
		/** The token sealed with a key derived from AUTH_SECRET, so its owner can copy it again. */
		tokenSealed: text('tokenSealed').notNull(),
		role: text('role', { enum: ['view'] }).notNull().default('view'),
		visibility: text('visibility', { enum: ['link', 'public'] }).notNull().default('link'),
		allowDownload: integer('allowDownload', { mode: 'boolean' }).notNull().default(false),
		allowEmbed: integer('allowEmbed', { mode: 'boolean' }).notNull().default(false),
		expiresAt: timestamp('expiresAt'),
		revokedAt: timestamp('revokedAt'),
		viewCount: integer('viewCount').notNull().default(0),
		createdBy: typeid('user').notNull().references(() => user.id),
		createdAt: timestamp('createdAt').notNull(),
	},
	(t) => [uniqueIndex('share_link_token_idx').on(t.tokenHash), index('share_link_doc_idx').on(t.docId)],
)
