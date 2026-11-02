// Blobs: every file of a shared document (the .pen, its images, fonts and libraries, its
// previews) is stored once per workspace under assets/<workspaceId>/<sha256>
// (docs/cloud-design.md §3.5). Uploads go straight to object storage with a presigned PUT
// when the bucket has S3 keys, else through the Worker with a signed ticket. Either way the
// client sends no cookie.
import { sha256Hex, signTicket, verifyTicket } from './crypto'

// The started app (backend.start(), worker.app(env), a test fixture's app): only what this
// module uses.
export type App = {
	// eslint-disable-next-line @typescript-eslint/no-explicit-any
	db: any
	storage: {
		bucket(name: string):
			| {
					upload(key: string, data: Blob | ArrayBuffer, contentType: string): Promise<void>
					get(key: string): Promise<Response>
					delete(key: string): Promise<void>
					exists(key: string): Promise<boolean>
					stat?(key: string): Promise<{ size: number; contentType: string } | null>
					presignPut?(key: string, opts: { contentType?: string; expiresIn: number }): Promise<string>
			  }
			| undefined
	}
	env: Record<string, unknown>
}

export const UPLOAD_SECONDS = 15 * 60

export const TYPES = [
	'image/png',
	'image/jpeg',
	'image/webp',
	'image/gif',
	'image/svg+xml',
	'font/ttf',
	'font/otf',
	'font/woff',
	'font/woff2',
	'application/json',
] as const
export type BlobType = (typeof TYPES)[number]

export function bucket(app: App) {
	const b = app.storage.bucket('default')
	if (!b) throw new Error('[site] storage bucket "default" is not configured')
	return b
}

export const blobKey = (workspaceId: string, hash: string) => `assets/${workspaceId}/${hash}`

export function secretOf(app: App): string {
	const s = (app.env.BETTER_AUTH_SECRET ?? app.env.AUTH_SECRET) as string | undefined
	if (!s) throw new Error('[site] AUTH_SECRET is not set')
	return s
}

export function appUrl(app: App, request?: Request): string {
	const url = (app.env.APP_URL as string | undefined) ?? (request ? new URL(request.url).origin : '')
	return url.replace(/\/$/, '')
}

type Ticket = { ws: string; hash: string; type: string; size: number; exp: number }

/** Where the client PUTs one blob, and the headers it must send. */
export async function uploadTarget(app: App, request: Request, ws: string, hash: string, type: string, size: number) {
	const b = bucket(app)
	const headers = { 'content-type': type }
	if (b.presignPut) {
		const url = await b.presignPut(blobKey(ws, hash), { contentType: type, expiresIn: UPLOAD_SECONDS })
		return { hash, url, method: 'PUT' as const, headers }
	}
	const ticket = await signTicket(secretOf(app), 'upload-v1', {
		ws,
		hash,
		type,
		size,
		exp: Date.now() + UPLOAD_SECONDS * 1000,
	} satisfies Ticket)
	return { hash, url: `${appUrl(app, request)}/api/blobs/${ticket}`, method: 'PUT' as const, headers }
}

/** PUT /api/blobs/<ticket>: an upload through the Worker (buckets without S3 keys). */
export async function handleBlobPut(app: App, request: Request): Promise<Response> {
	if (request.method !== 'PUT') return text(405, 'Method not allowed')
	const ticketText = new URL(request.url).pathname.slice('/api/blobs/'.length)
	const t = await verifyTicket<Ticket>(secretOf(app), 'upload-v1', ticketText)
	if (!t || t.exp < Date.now()) return text(403, 'Upload ticket invalid or expired')
	const declared = Number(request.headers.get('content-length') ?? '0')
	if (declared > t.size) return text(413, 'Larger than declared')
	const body = await request.arrayBuffer()
	if (body.byteLength !== t.size) return text(400, 'Size differs from the declared size')
	if ((await sha256Hex(body)) !== t.hash) return text(400, 'Hash differs from the declared hash')
	await bucket(app).upload(blobKey(t.ws, t.hash), body, t.type)
	return new Response(null, { status: 204, headers: cors(app) })
}

export function cors(app: App): Record<string, string> {
	const origin = app.env.APP_URL as string | undefined
	return origin ? { 'access-control-allow-origin': origin, vary: 'origin' } : {}
}

function text(status: number, message: string) {
	return new Response(message, { status, headers: { 'content-type': 'text/plain; charset=utf-8' } })
}

/** Whether the first bytes fit the declared type: a PNG named .jpg is fine, HTML is not. */
export function sniffOk(type: string, head: Uint8Array): boolean {
	const at = (i: number, ...bytes: number[]) => bytes.every((b, k) => head[i + k] === b)
	const ascii = (i: number, s: string) => at(i, ...[...s].map((c) => c.charCodeAt(0)))
	switch (type) {
		case 'image/png':
			return at(0, 0x89, 0x50, 0x4e, 0x47)
		case 'image/jpeg':
			return at(0, 0xff, 0xd8, 0xff)
		case 'image/gif':
			return ascii(0, 'GIF8')
		case 'image/webp':
			return ascii(0, 'RIFF') && ascii(8, 'WEBP')
		case 'font/ttf':
			return at(0, 0x00, 0x01, 0x00, 0x00) || ascii(0, 'true')
		case 'font/otf':
			return ascii(0, 'OTTO')
		case 'font/woff':
			return ascii(0, 'wOFF')
		case 'font/woff2':
			return ascii(0, 'wOF2')
		case 'image/svg+xml': {
			const s = new TextDecoder().decode(head).trimStart().toLowerCase()
			return (s.startsWith('<?xml') || s.startsWith('<svg') || s.startsWith('<!--')) && !s.includes('<html')
		}
		case 'application/json': {
			const s = new TextDecoder().decode(head).trimStart()
			return s.startsWith('{') || s.startsWith('[')
		}
		default:
			return false
	}
}
