// A streaming ZIP writer (stored entries, no compression: the .pen and its images and
// fonts go out as they are; brotli on the wire does the rest). One file is read at a time,
// so memory holds one file, not the archive.

const CRC_TABLE = (() => {
	const t = new Uint32Array(256)
	for (let n = 0; n < 256; n++) {
		let c = n
		for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
		t[n] = c >>> 0
	}
	return t
})()

export function crc32(bytes: Uint8Array): number {
	let c = 0xffffffff
	for (let i = 0; i < bytes.length; i++) c = CRC_TABLE[(c ^ bytes[i]!) & 0xff]! ^ (c >>> 8)
	return (c ^ 0xffffffff) >>> 0
}

/** A file of the archive: a blob by its hash, or bytes given here. */
export type Entry = { path: string; hash: string; data?: Uint8Array }

export function zip(entries: Entry[], read: (hash: string) => Promise<Uint8Array>): ReadableStream<Uint8Array> {
	const enc = new TextEncoder()
	const seen = new Set<string>()
	const files = entries.filter((e) => !seen.has(e.path) && seen.add(e.path))
	const central: Uint8Array[] = []
	let offset = 0
	let i = 0
	let done = false
	return new ReadableStream<Uint8Array>({
		async pull(controller) {
			if (done) return
			if (i < files.length) {
				const f = files[i++]!
				const data = f.data ?? (await read(f.hash))
				const name = enc.encode(f.path)
				const crc = crc32(data)
				const local = new DataView(new ArrayBuffer(30))
				local.setUint32(0, 0x04034b50, true)
				local.setUint16(4, 20, true) // version needed
				local.setUint16(6, 0x0800, true) // UTF-8 names
				local.setUint16(8, 0, true) // stored
				local.setUint32(10, 0x00210000, true) // 1980-01-01 00:00
				local.setUint32(14, crc, true)
				local.setUint32(18, data.length, true)
				local.setUint32(22, data.length, true)
				local.setUint16(26, name.length, true)
				local.setUint16(28, 0, true)
				const entry = new DataView(new ArrayBuffer(46))
				entry.setUint32(0, 0x02014b50, true)
				entry.setUint16(4, 20, true)
				entry.setUint16(6, 20, true)
				entry.setUint16(8, 0x0800, true)
				entry.setUint16(10, 0, true)
				entry.setUint32(12, 0x00210000, true)
				entry.setUint32(16, crc, true)
				entry.setUint32(20, data.length, true)
				entry.setUint32(24, data.length, true)
				entry.setUint16(28, name.length, true)
				entry.setUint32(42, offset, true)
				const c = new Uint8Array(46 + name.length)
				c.set(new Uint8Array(entry.buffer), 0)
				c.set(name, 46)
				central.push(c)
				offset += 30 + name.length + data.length
				controller.enqueue(new Uint8Array(local.buffer))
				controller.enqueue(name)
				controller.enqueue(data)
				return
			}
			const size = central.reduce((n, c) => n + c.length, 0)
			for (const c of central) controller.enqueue(c)
			const end = new DataView(new ArrayBuffer(22))
			end.setUint32(0, 0x06054b50, true)
			end.setUint16(8, central.length, true)
			end.setUint16(10, central.length, true)
			end.setUint32(12, size, true)
			end.setUint32(16, offset, true)
			controller.enqueue(new Uint8Array(end.buffer))
			done = true
			controller.close()
		},
	})
}
