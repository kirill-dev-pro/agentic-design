// Builds the site into site/dist: the page from site/src and, when it has been built, the
// browser viewer (build/web, tools/build_web.sh) under /view. Assets get content hashes in
// their names (served as immutable), text and WebAssembly get .br and .gz copies next to
// them (the server picks one by Accept-Encoding).
//   node site/build.mjs      (or bun; from anywhere)
// VIEWER=path/to/web overrides where the viewer build is read from.
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import zlib from "node:zlib";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const src = path.join(here, "src");
const out = path.join(here, "dist");
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
const plain = new Set(["index.html", "404.html", "robots.txt", "sitemap.xml", "favicon.ico", "img/og.png", "img/apple-touch-icon.png", "img/icon.svg", "img/icon-512.png", "site.webmanifest"]);
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
	for (const name of ["viewer.wasm", "odin.js", "wgpu.js", "viewer.css"]) {
		if (!fs.existsSync(path.join(viewer, name))) continue;
		const data = fs.readFileSync(path.join(viewer, name));
		const h = hashed(name, data);
		vmap.set(`"${name}"`, `"${h}"`);
		write("view/" + h, data);
	}
	// viewer.js names the wasm; it is hashed after that
	let js = rewrite(fs.readFileSync(path.join(viewer, "viewer.js"), "utf8"), vmap);
	const jsName = hashed("viewer.js", js);
	vmap.set(`"viewer.js"`, `"${jsName}"`);
	write("view/" + jsName, js);
	let html = rewrite(fs.readFileSync(path.join(viewer, "index.html"), "utf8"), vmap);
	html = rewrite(html, map); // the site's shared assets (fonts, icons) by their hashed names
	write("view/index.html", html);
	for (const extra of fs.readdirSync(viewer)) {
		// samples and other files the page links to by name
		if (/^(index\.html|viewer\.(wasm|js|css)|odin\.js|wgpu\.js)$/.test(extra)) continue;
		const p = path.join(viewer, extra);
		if (fs.statSync(p).isDirectory()) fs.cpSync(p, path.join(out, "view", extra), { recursive: true });
		else write("view/" + extra, fs.readFileSync(p));
	}
	console.log("viewer: included from", viewer);
} else {
	console.log("viewer: not built (", viewer, "), /view is left out");
}

// ---------------------------------------------------------------- compression

let raw = 0, br = 0;
const all = (dir) => fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
	const p = path.join(dir, e.name);
	return e.isDirectory() ? all(p) : [p];
});
for (const file of all(out)) {
	if (!/\.(html|css|js|mjs|json|svg|wasm|txt|xml|webmanifest|pen|ico)$/.test(file)) continue;
	const data = fs.readFileSync(file);
	if (data.length < 1024) continue;
	const b = zlib.brotliCompressSync(data, { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 11, [zlib.constants.BROTLI_PARAM_SIZE_HINT]: data.length } });
	const g = zlib.gzipSync(data, { level: 9 });
	fs.writeFileSync(file + ".br", b);
	fs.writeFileSync(file + ".gz", g);
	raw += data.length;
	br += b.length;
}
console.log(`dist: ${all(out).length} files; compressible ${(raw / 1024).toFixed(0)} KB → ${(br / 1024).toFixed(0)} KB brotli`);
