// The site's one Worker object (createWorker): shared by the Worker entry (src/server.ts) and the
// Durable Objects, which import it inside their methods (src/room/doc-room.ts) to reach the same
// app (db, storage) the Worker uses. A second createWorker would re-register the isolate's worker.
import { createWorker } from 'workerstack/workers'

import { backend } from './workerstack'

export const worker = createWorker(backend)
