// Builds the site's static files into site/dist/client (the Worker's assets directory): the
// pages from site/pages and, when it has been built, the browser viewer (build/web,
// tools/build_web.sh) under /view with the sample design. Every asset but the pages, the
// crawler files and the icons gets a content hash in its name; _headers marks those
// immutable. Plain files: any static host can serve the folder.
//   node site/build.mjs      (or bun; from anywhere)
// VIEWER=path/to/web overrides where the viewer build is read from.
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const src = path.join(here, "pages");
const out = path.join(here, "dist", "client");
const viewer = process.env.VIEWER || path.join(here, "..", "build", "web");

fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(out, { recursive: true });

const hash = (data) => crypto.createHash("sha256").update(data).digest("hex").slice(0, 10);
const hashed = (name, data) => {
	const ext = path.extname(name);
	return name.slice(0, -ext.length) + "." + hash(data) + ext;
};
const write = (rel, data) => {
	const file = path.join(out, rel);
	fs.mkdirSync(path.dirname(file), { recursive: true });
	fs.writeFileSync(file, data);
};
// replaces every `from` (a path as written in the file) with `to`
const rewrite = (text, map) => {
	for (const [from, to] of map) text = text.split(from).join(to);
	return text;
};

// ---------------------------------------------------------------- the page

const map = new Map();
// files kept at their names: crawlers, the og image and favicons are fetched by URL
const plain = new Set(["index.html", "404.html", "robots.txt", "sitemap.xml", "favicon.ico", "img/og.png", "img/apple-touch-icon.png", "favicon.svg", "img/icon-192.png", "img/icon-512.png", "site.webmanifest"]);
const walk = (dir) => fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
	const p = path.join(dir, e.name);
	return e.isDirectory() ? walk(p) : [path.relative(src, p).split(path.sep).join("/")];
});
const files = walk(src);

// fonts and images first (CSS names them), then CSS and JS, then the HTML
const order = (f) => (/\.(css)$/.test(f) ? 1 : /\.(js)$/.test(f) ? 2 : /\.html$/.test(f) ? 3 : 0);
for (const rel of files.sort((a, b) => order(a) - order(b))) {
	let data = fs.readFileSync(path.join(src, rel));
	if (/\.(css|js|html|webmanifest)$/.test(rel)) data = Buffer.from(rewrite(data.toString(), map));
	// the stylesheet goes inline (about 3 KB compressed): no request blocks the first paint
	if (/\.html$/.test(rel)) {
		data = Buffer.from(data.toString().replace(/<link rel="stylesheet" href="\/(styles\.[0-9a-f]{10}\.css)">/, (_, css) =>
			"<style>" + fs.readFileSync(path.join(out, css), "utf8").replace(/\/\*[\s\S]*?\*\//g, "").replace(/\n\s*/g, "\n") + "</style>"));
	}
	if (plain.has(rel) || /\.txt$/.test(rel)) {
		write(rel, data);
	} else {
		const name = hashed(rel, data);
		map.set("/" + rel, "/" + name);
		write(name, data);
	}
}

// ---------------------------------------------------------------- the viewer

if (fs.existsSync(path.join(viewer, "viewer.wasm"))) {
	const vmap = new Map();
	const shell = []; // the viewer's hashed files, cached by sw.js
	for (const name of ["viewer.wasm", "odin.js", "wgpu.js", "viewer.css"]) {
		if (!fs.existsSync(path.join(viewer, name))) continue;
		const data = fs.readFileSync(path.join(viewer, name));
		const h = hashed(name, data);
		vmap.set(`"${name}"`, `"${h}"`);
		write("view/" + h, data);
		shell.push(h);
	}
	// viewer.js names the wasm; it is hashed after that
	let js = rewrite(fs.readFileSync(path.join(viewer, "viewer.js"), "utf8"), vmap);
	const jsName = hashed("viewer.js", js);
	vmap.set(`"viewer.js"`, `"${jsName}"`);
	write("view/" + jsName, js);
	shell.push(jsName);
	let html = rewrite(fs.readFileSync(path.join(viewer, "index.html"), "utf8"), vmap);
	html = rewrite(html, map); // the site's shared assets (fonts, icons) by their hashed names
	write("view/index.html", html);
	for (const extra of fs.readdirSync(viewer)) {
		// samples and other files the page links to by name
		if (/^(index\.html|viewer\.(wasm|js|css)|odin\.js|wgpu\.js|sw\.js)$/.test(extra)) continue;
		const p = path.join(viewer, extra);
		if (fs.statSync(p).isDirectory()) fs.cpSync(p, path.join(out, "view", extra), { recursive: true });
		else write("view/" + extra, fs.readFileSync(p));
	}
	// the service worker: a new build is a new cache, holding the hashed files
	if (fs.existsSync(path.join(viewer, "sw.js"))) {
		const sw = fs.readFileSync(path.join(viewer, "sw.js"), "utf8")
			.replace('"__BUILD__"', JSON.stringify(hash(shell.join(","))))
			.replace("__ASSETS__", JSON.stringify(shell));
		write("view/sw.js", sw);
	}
	// the sample design (the landing page, with its fonts) for "Try the sample"
	const sample = path.join(here, "..", "designs", "sample");
	if (fs.existsSync(sample)) fs.cpSync(sample, path.join(out, "view", "samples", "agentic-design"), { recursive: true });
	console.log("viewer: included from", viewer);
} else {
	console.log("viewer: not built (", viewer, "), /view is left out");
}

// ---------------------------------------------------------------- headers

const all = (dir) => fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
	const p = path.join(dir, e.name);
	return e.isDirectory() ? all(p) : [p];
});
// Cloudflare's static assets read _headers: names with a content hash never change; the rest
// revalidate.
write("_headers", [
	"/*",
	"  X-Content-Type-Options: nosniff",
	"  Referrer-Policy: strict-origin-when-cross-origin",
	...[...new Set(all(out).map((f) => path.relative(out, f).split(path.sep).join("/")).filter((f) => /\.[0-9a-f]{10}\.[a-z0-9]+$/.test(f)))]
		.flatMap((f) => ["/" + f, "  Cache-Control: public, max-age=31536000, immutable"]),
	"/img/*",
	"  Cache-Control: public, max-age=86400",
	"/favicon.*",
	"  Cache-Control: public, max-age=86400",
	"/view/samples/*",
	"  Cache-Control: public, max-age=3600",
	"",
].join("\n"));

const written = all(out);
console.log(`dist/client: ${written.length} files, ${(written.reduce((n, f) => n + fs.statSync(f).size, 0) / 1024).toFixed(0)} KB`);
