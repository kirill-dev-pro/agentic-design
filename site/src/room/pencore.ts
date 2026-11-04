// pencore.wasm (the engine's model, ops and serializer; cloud-ops.md §7) with the four host
// functions it imports and its JSON ABI. A Worker cannot compile WebAssembly from bytes at run
// time, so the room hands over the module its bundler compiled; Bun and Node may pass bytes.
// After Agentic Design Dev's tests/cloud-ops/pencore.mjs.
import type { Op, Pencore } from './room'

export async function loadPencore(source: WebAssembly.Module | BufferSource): Promise<Pencore> {
	let mem: WebAssembly.Memory
	const dec = new TextDecoder()
	const enc = new TextEncoder()
	const imports = {
		odin_env: {
			cos: Math.cos,
			sin: Math.sin,
			write: (fd: number, ptr: number, len: number) => {
				const s = dec.decode(new Uint8Array(mem.buffer, ptr, len)).replace(/\n$/, '')
				;(fd === 2 ? console.error : console.log)(`[pencore] ${s}`)
			},
			rand_bytes: (ptr: number, len: number) => crypto.getRandomValues(new Uint8Array(mem.buffer, ptr, len)),
		},
	}
	const instance =
		source instanceof WebAssembly.Module
			? await WebAssembly.instantiate(source, imports)
			: (await WebAssembly.instantiate(source, imports)).instance
	// eslint-disable-next-line @typescript-eslint/no-explicit-any
	const x = instance.exports as any
	if (typeof x.pc_open !== 'function')
		throw new Error('[pencore] no engine in this build (pencore.wasm is the empty stand-in of a SKIP_VIEWER=1 build)')
	mem = x.memory
	x._start?.()
	const put = (s: string): [number, number] => {
		const b = enc.encode(s)
		const p = x.pc_alloc(b.length)
		new Uint8Array(mem.buffer, p, b.length).set(b)
		return [p, b.length]
	}
	const take = (p: number) => dec.decode(new Uint8Array(mem.buffer, p, x.pc_result_len()))
	return {
		open(pen, sorts = {}) {
			const [a, al] = put(pen)
			const [b, bl] = put(JSON.stringify(sorts))
			const h = x.pc_open(a, al, b, bl)
			x.pc_free(a)
			x.pc_free(b)
			return h
		},
		apply(h, batch: { ops: Op[] }) {
			const [p, l] = put(JSON.stringify(batch))
			const r = JSON.parse(take(x.pc_apply(h, p, l)))
			x.pc_free(p)
			return r
		},
		serialize: (h) => take(x.pc_serialize(h)),
		state: (h) => JSON.parse(take(x.pc_state(h))),
		close: (h) => x.pc_close(h),
	}
}
