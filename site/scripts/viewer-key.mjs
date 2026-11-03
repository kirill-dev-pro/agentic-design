// Prints the key of the compiled viewer (viewer.wasm and odin.js): a hash of what goes into
// it, src/ and tools/build_web.sh, and the Odin release ($ODIN_VERSION). CI uploads each
// build under its key (.github/workflows/ci.yml) and the site build fetches it
// (scripts/viewer.sh), so the same inputs give the same file. Run from the repository root.
import { createHash } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const odin = process.env.ODIN_VERSION;
if (!odin) throw new Error("viewer-key: set ODIN_VERSION");

const files = [];
const walk = (dir) => {
	for (const e of readdirSync(dir, { withFileTypes: true })) {
		const p = join(dir, e.name);
		if (e.isDirectory()) walk(p);
		else if (e.isFile()) files.push(p);
	}
};
walk("src");
files.push("tools/build_web.sh");
files.sort();

const all = createHash("sha256").update(`odin ${odin}\n`);
for (const f of files) all.update(`${createHash("sha256").update(readFileSync(f)).digest("hex")}  ${f.split("\\").join("/")}\n`);
console.log(all.digest("hex").slice(0, 24));
