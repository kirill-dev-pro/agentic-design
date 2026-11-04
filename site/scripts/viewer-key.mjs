// Prints the key of the compiled viewer, editor and server engine (viewer.wasm, odin.js,
// editor.wasm, pencore.wasm): a hash of what goes into them, src/, tools/build_web.sh and
// tools/build_pencore.sh, and the Odin release ($ODIN_VERSION). CI uploads each
// build under its key (.github/workflows/ci.yml) and the site build fetches it
// (scripts/viewer.sh), so the same inputs give the same file. Run from the repository root.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const odin = process.env.ODIN_VERSION;
if (!odin) throw new Error("viewer-key: set ODIN_VERSION");

// The files git tracks, where there is a checkout with git (a working copy has ignored files,
// such as src/wgpu/lib); otherwise every file, as in a fresh checkout.
let files;
try {
	files = execFileSync("git", ["ls-files", "-z", "--", "src", "tools/build_web.sh", "tools/build_pencore.sh"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] })
		.split("\0").filter(Boolean);
} catch {
	files = [];
	const walk = (dir) => {
		for (const e of readdirSync(dir, { withFileTypes: true })) {
			const p = join(dir, e.name);
			if (e.isDirectory()) walk(p);
			else if (e.isFile()) files.push(p.split("\\").join("/"));
		}
	};
	walk("src");
	files.push("tools/build_web.sh", "tools/build_pencore.sh");
}
if (!files.length) throw new Error("viewer-key: no sources");
files.sort();

const all = createHash("sha256").update(`odin ${odin}\n`);
for (const f of files) all.update(`${createHash("sha256").update(readFileSync(f)).digest("hex")}  ${f}\n`);
console.log(all.digest("hex").slice(0, 24));
