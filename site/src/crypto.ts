// Tokens and keys: share-link tokens (128 random bits), their SHA-256 for lookups, a sealed
// copy so the owner can copy a link again, and signed upload tickets for uploads that go
// through the Worker. Every key is derived from the app's auth secret with HKDF.

const enc = new TextEncoder()
const dec = new TextDecoder()

const BASE62 = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'

/** 22 base62 characters from 16 random bytes. */
export function randomToken(): string {
	const bytes = crypto.getRandomValues(new Uint8Array(16))
	let n = 0n
	for (const b of bytes) n = (n << 8n) | BigInt(b)
	let out = ''
	for (let i = 0; i < 22; i++) {
		out = BASE62[Number(n % 62n)] + out
		n /= 62n
	}
	return out
}

export function hex(bytes: ArrayBuffer | Uint8Array): string {
	return [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, '0')).join('')
}

export async function sha256Hex(data: ArrayBuffer | Uint8Array | string): Promise<string> {
	const bytes = typeof data === 'string' ? enc.encode(data) : data
	return hex(await crypto.subtle.digest('SHA-256', bytes as BufferSource))
}

function b64url(bytes: Uint8Array): string {
	let s = ''
	for (const b of bytes) s += String.fromCharCode(b)
	return btoa(s).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '')
}

function unb64url(text: string): Uint8Array {
	const s = atob(text.replaceAll('-', '+').replaceAll('_', '/'))
	return Uint8Array.from(s, (c) => c.charCodeAt(0))
}

const keys = new Map<string, Promise<CryptoKey>>()

function derive(secret: string, purpose: string, usage: 'seal' | 'sign'): Promise<CryptoKey> {
	const id = `${purpose}\0${usage}\0${secret}`
	let key = keys.get(id)
	if (!key) {
		key = crypto.subtle
			.importKey('raw', enc.encode(secret), 'HKDF', false, ['deriveKey'])
			.then((base) =>
				crypto.subtle.deriveKey(
					{ name: 'HKDF', hash: 'SHA-256', salt: enc.encode('agentic-design'), info: enc.encode(purpose) },
					base,
					usage === 'seal' ? { name: 'AES-GCM', length: 256 } : { name: 'HMAC', hash: 'SHA-256', length: 256 },
					false,
					usage === 'seal' ? ['encrypt', 'decrypt'] : ['sign', 'verify'],
				),
			)
		keys.set(id, key)
	}
	return key
}

export async function seal(secret: string, purpose: string, text: string): Promise<string> {
	const key = await derive(secret, purpose, 'seal')
	const iv = crypto.getRandomValues(new Uint8Array(12))
	const data = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, key, enc.encode(text)))
	return `${b64url(iv)}.${b64url(data)}`
}

export async function unseal(secret: string, purpose: string, sealed: string): Promise<string | null> {
	try {
		const [iv, data] = sealed.split('.')
		const key = await derive(secret, purpose, 'seal')
		return dec.decode(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: unb64url(iv!) as BufferSource }, key, unb64url(data!) as BufferSource))
	} catch {
		return null
	}
}

/** A signed, expiring ticket carrying a small JSON payload. */
export async function signTicket(secret: string, purpose: string, payload: object): Promise<string> {
	const body = b64url(enc.encode(JSON.stringify(payload)))
	const key = await derive(secret, purpose, 'sign')
	const mac = new Uint8Array(await crypto.subtle.sign('HMAC', key, enc.encode(body)))
	return `${body}.${b64url(mac)}`
}

export async function verifyTicket<T>(secret: string, purpose: string, ticket: string): Promise<T | null> {
	const [body, mac] = ticket.split('.')
	if (!body || !mac) return null
	const key = await derive(secret, purpose, 'sign')
	let ok = false
	try {
		ok = await crypto.subtle.verify('HMAC', key, unb64url(mac) as BufferSource, enc.encode(body))
	} catch {
		return null
	}
	if (!ok) return null
	try {
		return JSON.parse(dec.decode(unb64url(body))) as T
	} catch {
		return null
	}
}
