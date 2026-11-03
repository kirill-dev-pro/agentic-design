"use strict";
// Sharing the document open in the viewer (the M1 API contract, §3 and §4): the .pen and
// every file the engine read for it (images, fonts, libraries), hashed with SHA-256, with
// previews rendered here (the cover frame as a 1200 × 630 card, each top-level frame of
// every page as a picture for browsers without WebGPU). The server is told the hashes and
// asks only for the blobs it does not have; they are PUT where it says, the version is
// committed, and the file gets a link (a new version keeps its links).
//
// viewer.js passes a context: { docPath, read: Map(path → bytes | null), title, info(),
// page(i), select(uid), exportCanvas(uid, scale), frame() (a promise for the next frame) }.

window.PenUpload = (() => {
	const TYPES = {
		png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", webp: "image/webp", gif: "image/gif", svg: "image/svg+xml",
		ttf: "font/ttf", otf: "font/otf", woff: "font/woff", woff2: "font/woff2", pen: "application/json",
	};
	const FRAME_SIDE = 4096; // the longer side of a frame picture, at most
	const MAX_FRAMES = 200;

	class UploadError extends Error {
		constructor(status, body) {
			super((body && (body.error || body.message)) || `Request failed (${status})`);
			this.status = status;
			this.code = (body && body.code) || "";
			this.reason = (body && body.details && body.details.reason) || "";
		}
	}

	async function api(method, path, body) {
		const res = await fetch(path, {
			method, credentials: "same-origin",
			headers: body !== undefined ? { "content-type": "application/json" } : {},
			body: body !== undefined ? JSON.stringify(body) : undefined,
		});
		const text = await res.text();
		let data = null;
		try { data = text ? JSON.parse(text) : null; } catch (e) { data = { message: text }; }
		if (!res.ok) throw new UploadError(res.status, data);
		return data;
	}

	const hex = (buf) => Array.from(new Uint8Array(buf), (b) => b.toString(16).padStart(2, "0")).join("");
	const sha256 = async (bytes) => hex(await crypto.subtle.digest("SHA-256", bytes));

	// `to` as the document refers to it, from the document's folder: ./a/b.png, ../x.png
	function relative(fromDir, to) {
		const a = fromDir.split("/").filter(Boolean), b = to.split("/").filter(Boolean);
		let i = 0;
		while (i < a.length && i < b.length && a[i] === b[i]) i++;
		const up = a.length - i;
		return (up ? "../".repeat(up) : "./") + b.slice(i).join("/");
	}

	// The .pen and what the engine read for it.
	function collect(ctx) {
		const dir = ctx.docPath.slice(0, ctx.docPath.lastIndexOf("/") + 1);
		const pen = ctx.read.get(ctx.docPath);
		const assets = [], missing = [];
		for (const [path, bytes] of ctx.read) {
			if (path === ctx.docPath) continue;
			const rel = relative(dir, path);
			const ext = path.slice(path.lastIndexOf(".") + 1).toLowerCase();
			if (!bytes || !bytes.length || !TYPES[ext]) missing.push(rel); // not there, or a kind the server does not keep
			else assets.push({ path: rel, bytes, type: TYPES[ext] });
		}
		return { pen, assets, missing };
	}

	const toBlob = (canvas) => new Promise((ok) => canvas.toBlob(ok, "image/png"));

	// Waits until the viewer reports `test(info)` (the engine reports after drawing a frame).
	async function until(ctx, test) {
		for (let i = 0; i < 120; i++) {
			if (test(ctx.info())) return true;
			await ctx.frame();
		}
		return false;
	}

	// The cover card and the frame pictures. Leaves the viewer on the page it was on.
	async function previews(ctx, progress) {
		const start = ctx.info();
		const pages = Math.max(1, (start.pages || []).length);
		const frames = [];
		let og = null;
		for (let p = 0; p < pages && frames.length < MAX_FRAMES; p++) {
			ctx.page(p);
			await until(ctx, (i) => i.page === p);
			for (const f of ctx.info().frames || []) {
				if (frames.length >= MAX_FRAMES) break;
				ctx.select(f.uid);
				if (!(await until(ctx, (i) => i.sel && i.sel.uid === f.uid))) continue;
				const sel = ctx.info().sel;
				const w = Number(sel.w), h = Number(sel.h);
				if (!(w > 0 && h > 0)) continue;
				progress(`Drawing ${sel.name}…`);
				const scale = Math.min(2, FRAME_SIDE / Math.max(w, h));
				const pic = ctx.exportCanvas(f.uid, scale);
				if (!pic) continue;
				if (!og) og = await card(ctx, f.uid, w, h);
				frames.push({ id: sel.id || String(f.uid), name: sel.name, width: Math.round(w), height: Math.round(h), scale: Number(scale.toFixed(4)), blob: await toBlob(pic) });
				await ctx.frame();
			}
		}
		ctx.select(0);
		ctx.page(start.page || 0);
		return { og, frames };
	}

	// 1200 × 630, the frame scaled to cover it, its top kept (a page's hero is at the top).
	async function card(ctx, uid, w, h) {
		const s = Math.max(1200 / w, 630 / h);
		const pic = ctx.exportCanvas(uid, s);
		if (!pic) return null;
		const c = document.createElement("canvas");
		c.width = 1200;
		c.height = 630;
		const g = c.getContext("2d");
		g.fillStyle = "#ffffff";
		g.fillRect(0, 0, 1200, 630);
		g.drawImage(pic, Math.round((1200 - pic.width) / 2), 0);
		return toBlob(c);
	}

	// PUTs blobs, four at a time.
	async function putAll(uploads, bytesOf, progress) {
		let done = 0;
		const queue = uploads.slice();
		const worker = async () => {
			for (let u; (u = queue.shift());) {
				const res = await fetch(u.url, { method: u.method || "PUT", headers: u.headers || {}, body: bytesOf.get(u.hash), credentials: "omit" });
				if (!res.ok) throw new UploadError(res.status, { error: `Uploading a file failed (${res.status})` });
				progress(`Uploading ${++done} of ${uploads.length}…`);
			}
		};
		await Promise.all([worker(), worker(), worker(), worker()]);
	}

	// Shares the open document: a new file, or a new version of `docId`. Returns { file, link }.
	async function upload(ctx, { name, docId, progress = () => {} }) {
		progress("Reading the files…");
		const { pen, assets, missing } = collect(ctx);
		if (!pen) throw new UploadError(0, { error: "The document is not loaded." });
		const bytesOf = new Map();
		const add = async (bytes) => { const h = await sha256(bytes); bytesOf.set(h, bytes); return h; };

		const shot = await previews(ctx, progress);
		progress("Preparing the upload…");
		const body = {
			name,
			pen: { hash: await add(pen), size: pen.length },
			assets: await Promise.all(assets.map(async (a) => ({ path: a.path, hash: await add(a.bytes), size: a.bytes.length, type: a.type }))),
			missing,
			previews: { frames: [] },
		};
		if (shot.og) {
			const b = new Uint8Array(await shot.og.arrayBuffer());
			body.previews.og = { hash: await add(b), size: b.length };
		}
		for (const f of shot.frames) {
			const b = new Uint8Array(await f.blob.arrayBuffer());
			body.previews.frames.push({ id: f.id, name: f.name, width: f.width, height: f.height, scale: f.scale, hash: await add(b), size: b.length });
		}
		const start = await api("POST", docId ? `/api/docs/${encodeURIComponent(docId)}/versions` : "/api/docs", body);
		await putAll(start.uploads || [], bytesOf, progress);
		progress("Finishing…");
		const file = await api("POST", `/api/docs/${start.docId}/versions/${start.versionId}/commit`);
		const link = (file.links && file.links[0]) || (await api("POST", `/api/docs/${start.docId}/links`, {}));
		return { file, link, missing };
	}

	return { upload, collect, relative, sha256, api, UploadError };
})();
