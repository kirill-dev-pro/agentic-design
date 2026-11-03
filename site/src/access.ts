// No table is served by Workerstack's generated CRUD routes: the site's routes (src/files.ts,
// src/share.ts, /api/me) are the only way in, and Better Auth owns its own tables.
// workerstack 0.2.5 and older expose any table with a userId column (member included) unless
// it is named here, so every table is listed, and a test fails when a new one is not.
import { defineAccess } from 'workerstack/access'

import * as schema from './schema'

const closed = { crud: false } as const

export const access = defineAccess(schema, {
	user: closed,
	session: closed,
	account: closed,
	verification: closed,
	organization: closed,
	member: closed,
	invitation: closed,
	workspacePlan: closed,
	document: closed,
	version: closed,
	asset: closed,
	shareLink: closed,
	viewMetric: closed,
})
