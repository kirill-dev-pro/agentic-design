"use strict";
// Where the editor's documents live in the browser (the DocStore of the web editor plan).
// Two kinds, one interface:
//   opfs  the browser's private storage (origin private file system): docs/<id>/ holds the
//         document's files and a meta.json. A document the user opens or creates is copied
//         there, so a reload finds it again.
//   fs    a folder the user picked (File System Access, Chrome and Edge): the document is
//         edited in place, and the folder's handle is kept (IndexedDB) to open it again.
// The editor module writes through page_fs_write; write() queues those per document and
// writes them a file at a time. Nothing leaves the browser. A document is open in one tab at
// a time (a Web Lock), so two tabs do not write over each other.

window.DocStore = (() => {
	const ASSETS = /\.(pen|png|jpe?g|webp|gif|svg|ttf|otf|woff2?)$/i; // what a folder's scan reads
	const MAX_FILES = 3000, MAX_BYTES = 400 * 1024 * 1024, MAX_DEPTH = 8;
	const supported = { opfs: !!(navigator.storage && navigator.storage.getDirectory), fs: typeof window.showDirectoryPicker === "function" };
	const enc = new TextEncoder(), dec = new TextDecoder();

	let onState = () => {};
	const queues = new Map(); // document id → the promise of its last write
	let pending = 0, failure = null;
	const setPending = (d) => { pending += d; onState({ pending, failure }); };

	// ---------------------------------------------------------------- directories

	async function opfsDocs() {
		const root = await navigator.storage.getDirectory();
		return root.getDirectoryHandle("docs", { create: true });
	}
	async function opfsDir(id, create) {
		return (await opfsDocs()).getDirectoryHandle(id, { create });
	}

	// The directory handle of the folder that holds `rel`, made as needed.
	async function parentOf(root, rel, create) {
		const parts = rel.split("/").filter(Boolean);
		const name = parts.pop();
		let dir = root;
		for (const p of parts) dir = await dir.getDirectoryHandle(p, { create });
		return [dir, name];
	}

	async function writeFile(root, rel, bytes) {
		const [dir, name] = await parentOf(root, rel, true);
		const fh = await dir.getFileHandle(name, { create: true });
		const w = await fh.createWritable();
		await w.write(bytes);
		await w.close();
	}

	async function readFile(root, rel) {
		const [dir, name] = await parentOf(root, rel, false);
		return new Uint8Array(await (await (await dir.getFileHandle(name)).getFile()).arrayBuffer());
	}

	async function removeFile(root, rel) {
		const [dir, name] = await parentOf(root, rel, false);
		await dir.removeEntry(name, { recursive: true });
	}

	// Every file under `root` as [relative path, bytes]; `only` limits it to the kinds a
	// document uses (a picked folder may hold anything).
	async function readAll(root, only) {
		const out = [];
		let bytes = 0;
		const walk = async (dir, prefix, depth) => {
			for await (const [name, h] of dir.entries()) {
				if (h.kind === "directory") {
					if (depth < MAX_DEPTH && !name.startsWith(".") && name !== "node_modules") await walk(h, prefix + name + "/", depth + 1);
					continue;
				}
				if (prefix === "" && name === "meta.json" && !only) continue;
				if (only && !ASSETS.test(name)) continue;
				const f = await h.getFile();
				bytes += f.size;
				if (out.length >= MAX_FILES || bytes > MAX_BYTES) throw new Error("This folder is too large to open here. Open a folder with just the design in it.");
				out.push([prefix + name, new Uint8Array(await f.arrayBuffer())]);
			}
		};
		await walk(root, "", 0);
		return out;
	}

	// ---------------------------------------------------------------- the list

	let idb;
	function db() {
		idb ??= new Promise((ok, no) => {
			const r = indexedDB.open("agentic-design-editor", 1);
			r.onupgradeneeded = () => r.result.createObjectStore("folders", { keyPath: "id" });
			r.onsuccess = () => ok(r.result);
			r.onerror = () => no(r.error);
		});
		return idb;
	}
	async function folders(op, value) {
		const d = await db();
		return new Promise((ok, no) => {
			const t = d.transaction("folders", op === "list" ? "readonly" : "readwrite").objectStore("folders");
			const r = op === "list" ? t.getAll() : op === "put" ? t.put(value) : t.delete(value);
			r.onsuccess = () => ok(r.result);
			r.onerror = () => no(r.error);
		});
	}

	async function putMeta(doc) {
		doc.updated = Date.now();
		if (doc.kind === "opfs") await writeFile(await opfsDir(doc.id, true), "meta.json", enc.encode(JSON.stringify({ name: doc.name, penRel: doc.penRel, updated: doc.updated, cloud: null })));
		else await folders("put", { id: doc.id, name: doc.name, penRel: doc.penRel, updated: doc.updated, handle: doc.handle });
	}

	// The documents kept here, newest first: [{ id, kind, name, penRel, updated }]
	async function list() {
		const out = [];
		if (supported.opfs) {
			try {
				for await (const [id, h] of (await opfsDocs()).entries()) {
					if (h.kind !== "directory") continue;
					try {
						const meta = JSON.parse(dec.decode(await readFile(h, "meta.json")));
						out.push({ id, kind: "opfs", name: meta.name, penRel: meta.penRel, updated: meta.updated || 0 });
					} catch (e) { /* no meta.json: not a document of ours */ }
				}
			} catch (e) { console.warn("DocStore: listing the private storage failed", e); }
		}
		try {
			for (const f of await folders("list")) out.push({ id: f.id, kind: "fs", name: f.name, penRel: f.penRel, updated: f.updated || 0 });
		} catch (e) { /* no IndexedDB */ }
		return out.sort((a, b) => b.updated - a.updated);
	}

	const newId = () => (crypto.randomUUID ? crypto.randomUUID().replace(/-/g, "").slice(0, 12) : String(Date.now()) + Math.floor(Math.random() * 1e6));

	// The .pen a document opens on: the shallowest, then by name.
	const mainPen = (rels) => rels.filter((r) => /\.pen$/i.test(r)).sort((a, b) => a.split("/").length - b.split("/").length || a.localeCompare(b))[0];

	// ---------------------------------------------------------------- opening and creating

	// Keeps `files` ([[rel, bytes]]) as a new document in the private storage.
	async function create(name, files) {
		const doc = { id: newId(), kind: "opfs", name, penRel: mainPen(files.map((f) => f[0])) };
		if (!supported.opfs) return doc; // no storage: the document lives for this tab (Download keeps it)
		const dir = await opfsDir(doc.id, true);
		for (const [rel, bytes] of files) await writeFile(dir, rel, bytes);
		await putMeta(doc);
		if (navigator.storage.persist) navigator.storage.persist().catch(() => {});
		return doc;
	}

	// The user picks a folder; its design files are read and the folder is kept for editing in place.
	async function openFolder() {
		const handle = await window.showDirectoryPicker({ id: "agentic-design-editor", mode: "readwrite" });
		const files = await readAll(handle, true);
		const penRel = mainPen(files.map((f) => f[0]));
		if (!penRel) throw new Error("There is no .pen file in that folder.");
		const doc = { id: newId(), kind: "fs", name: handle.name, penRel, handle };
		await putMeta(doc);
		return { doc, files };
	}

	// A kept document's files. A folder asks again for permission (only a click may).
	async function load(entry) {
		if (entry.kind === "opfs") {
			const dir = await opfsDir(entry.id, false);
			return { doc: { ...entry }, files: await readAll(dir, false) };
		}
		const rec = (await folders("list")).find((f) => f.id === entry.id);
		if (!rec) throw new Error("That folder is not kept any more.");
		const opts = { mode: "readwrite" };
		if ((await rec.handle.queryPermission(opts)) !== "granted" && (await rec.handle.requestPermission(opts)) !== "granted") throw new Error("The editor needs permission to use that folder.");
		const files = await readAll(rec.handle, true);
		return { doc: { ...entry, handle: rec.handle, penRel: mainPen(files.map((f) => f[0])) || entry.penRel }, files };
	}

	async function forget(entry) {
		if (entry.kind === "opfs") await (await opfsDocs()).removeEntry(entry.id, { recursive: true }).catch(() => {});
		else await folders("delete", entry.id);
	}

	// Whether this tab may use the document: false while another tab has it open. The lock is
	// held until the tab closes.
	function lock(id) {
		return new Promise((ok) => {
			if (!navigator.locks) return ok(true);
			navigator.locks.request("agentic-design-doc-" + id, { ifAvailable: true }, (l) => {
				if (!l) return void ok(false);
				ok(true);
				return new Promise(() => {});
			});
		});
	}

	// ---------------------------------------------------------------- writing

	async function root(doc) {
		return doc.kind === "opfs" ? opfsDir(doc.id, true) : doc.handle;
	}

	// Queues a change to the document's files (one at a time, in order).
	function enqueue(doc, job) {
		if (doc.kind === "none" || (doc.kind === "opfs" && !supported.opfs)) return; // kept nowhere
		setPending(1);
		const run = (queues.get(doc.id) || Promise.resolve()).then(async () => {
			try {
				await job(await root(doc));
				failure = null;
			} catch (e) {
				console.error("DocStore:", e);
				failure = e && e.message ? e.message : String(e);
			} finally {
				setPending(-1);
			}
		});
		queues.set(doc.id, run);
		return run;
	}

	const write = (doc, rel, bytes) => enqueue(doc, async (r) => { await writeFile(r, rel, bytes); await putMeta(doc); });
	const remove = (doc, rel) => enqueue(doc, (r) => removeFile(r, rel).catch(() => {}));
	const rename = (doc, from, to) => enqueue(doc, async (r) => {
		await writeFile(r, to, await readFile(r, from));
		await removeFile(r, from);
		if (doc.penRel === from) { doc.penRel = to; doc.name = to.slice(to.lastIndexOf("/") + 1).replace(/\.pen$/i, ""); }
		await putMeta(doc);
	});

	return {
		supported, list, create, openFolder, load, forget, lock, write, remove, rename,
		onState: (f) => { onState = f; },
		pending: () => pending,
	};
})();
