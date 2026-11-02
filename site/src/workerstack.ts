// The site's backend: a Worker that serves the static pages and the viewer from its
// assets and answers under /api. The API is empty except for a version probe; sharing,
// accounts and the web editor's endpoints will go here.
import { workerstack } from 'workerstack'
import { libsql } from 'workerstack/libsql'

import * as schema from './schema'

export const backend = workerstack({
	schema,
	database: { adapter: libsql() },
	api: (o) => ({
		version: o.public
			.route({ method: 'GET', path: '/api/version' })
			.handler(() => ({ name: 'agentic-design-site', api: 0 })),
	}),
})
