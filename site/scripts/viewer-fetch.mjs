// Fetches the compiled viewer that CI built for a key (scripts/viewer-key.mjs) from the
// web-viewer-builds prerelease, checks it against its .sha256 and writes the .tar.gz.
//   node scripts/viewer-fetch.mjs <key> <out.tar.gz> [wait seconds]
// When CI has not uploaded it yet (the push that triggered this build is still being built
// there), it asks again every 20 s for up to the wait. Exits 0 with the file, 2 when there is
// none, 1 on any other failure. Every request has a time limit.
import { createHash } from "node:crypto";
import { writeFileSync } from "node:fs";

const [key, out, waitArg = "0"] = process.argv.slice(2);
if (!key || !out) throw new Error("usage: viewer-fetch.mjs <key> <out.tar.gz> [wait seconds]");
const BASE = "https://github.com/kirill-dev-pro/agentic-design/releases/download/web-viewer-builds";
const name = `viewer-${key}.tar.gz`;
const until = Date.now() + Number(waitArg) * 1000;

async function get(url, ms) {
	const res = await fetch(url, { signal: AbortSignal.timeout(ms), redirect: "follow" });
	if (res.status === 404) return null;
	if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
	return Buffer.from(await res.arrayBuffer());
}

async function attempt() {
	// The .sha256 is uploaded after the archive, so once it is there the archive is too.
	const sum = await get(`${BASE}/${name}.sha256`, 30_000);
	if (!sum) return null;
	const want = sum.toString().trim().split(/\s+/)[0];
	const bytes = await get(`${BASE}/${name}`, 180_000);
	if (!bytes) throw new Error(`${name}: listed but missing`);
	const got = createHash("sha256").update(bytes).digest("hex");
	if (got !== want) throw new Error(`${name}: sha256 ${got}, expected ${want}`);
	return bytes;
}

let waited = false;
for (;;) {
	let bytes = null;
	try {
		bytes = await attempt();
	} catch (e) {
		if (Date.now() >= until) { console.error(`viewer: ${e.message}`); process.exit(1); }
		console.error(`viewer: ${e.message}; trying again`);
	}
	if (bytes) {
		writeFileSync(out, bytes);
		console.log(`viewer: fetched ${name} (${bytes.length} bytes, sha256 checked)`);
		process.exit(0);
	}
	if (Date.now() >= until) process.exit(2);
	if (!waited) console.log(`viewer: waiting for CI to upload ${name}`);
	waited = true;
	await new Promise((r) => setTimeout(r, 20_000));
}
