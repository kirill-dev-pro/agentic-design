"use strict";
// The editor's page (web/edit/index.html): runs the app's interface, compiled to WebAssembly
// (src/editor_web.odin, src/platform_js.odin), on the page's canvas. This script is the
// platform: it hands the module the document's files (kept in the browser by store.js), turns the page's pointer, wheel, key
// and text events into the calls the module exports (editor_*), and keeps what the module
// writes (page_fs_write) so that "Download .pen" can give it to the user. Nothing leaves the
// browser.
(() => {
	const HERE = document.currentScript ? document.currentScript.src : location.href;
	const $ = (id) => document.getElementById(id);
	const canvas = $("canvas");
	const NEW_DOCUMENT = '{\n  "version": "2.21",\n  "children": []\n}\n';
	const CURSORS = ["default", "text", "crosshair", "pointer", "move", "ew-resize"]; // src/platform.odin's Cursor

	let mem, ex, started = false, failed = false, docCount = 0;
	const written = new Map(); // path → the bytes the module wrote last
	let saving = null; // the paths written while Download .pen asked for a save

	// ---------------------------------------------------------------- messages

	function showMessage(title, text, { error = false, actions = [] } = {}) {
		$("welcome").hidden = true;
		$("loading").hidden = true;
		$("message-title").textContent = title;
		$("message-text").textContent = text;
		$("message").querySelector(".card").classList.toggle("error", error);
		const row = $("message-actions");
		row.textContent = "";
		for (const [label, action, primary] of actions) {
			const el = document.createElement(typeof action === "string" ? "a" : "button");
			el.className = "btn" + (primary ? " primary" : "");
			el.textContent = label;
			if (typeof action === "string") el.href = action;
			else { el.type = "button"; el.onclick = action; }
			row.append(el);
		}
		$("message").hidden = false;
	}

	const noGpu = () => showMessage("This browser cannot run the editor",
		"The editor runs the Agentic Design interface on WebGPU, which this browser does not offer (or has turned off). It works in Chrome and Edge 113 or later, Safari 26 or later, and Firefox 141 or later on Windows. On a Mac, the app itself has everything.",
		{ error: true, actions: [["Download the app", "https://github.com/kirill-dev-pro/agentic-design/releases/latest", true], ["Look at a file instead", "/view/"]] });

	// ---------------------------------------------------------------- files

	// Copies bytes into the module's memory (editor_alloc): [pointer, length].
	function put(bytes) {
		const ptr = ex.editor_alloc(bytes.length);
		new Uint8Array(mem.memory.buffer, ptr, bytes.length).set(bytes);
		return [ptr, bytes.length];
	}
	const putString = (s) => put(new TextEncoder().encode(s));

	function addFile(path, bytes) {
		const [pp, pl] = putString(path), [dp, dl] = put(bytes);
		ex.editor_file(pp, pl, dp, dl);
	}

	// The documents open in this page: where their files are kept (DocStore) and the virtual
	// folder the engine reads them from.
	const sessions = []; // { doc, dir }
	const sessionOf = (path) => {
		for (const s of sessions) if (path.startsWith(s.dir)) return [s, path.slice(s.dir.length)];
		return [null, ""];
	};
	const SAVED = { opfs: "Saved in this browser", fs: "Saved to the folder", none: "" };

	// Hands a document's files ([[relative path, bytes]]) to the engine and starts the editor
	// on it (or opens a tab, once it runs).
	function startDoc(doc, files) {
		if (failed) return;
		$("message").hidden = true;
		$("welcome").hidden = true;
		const dir = `/doc/${++docCount}/`;
		sessions.push({ doc, dir });
		for (const [rel, bytes] of files) addFile(dir + rel, bytes);
		const [pp, pl] = putString(dir + doc.penRel);
		ex.editor_open(pp, pl);
		if (!started) $("loading").hidden = false;
		showSaved();
	}

	function showSaved(state = {}) {
		const last = sessions[sessions.length - 1];
		const el = $("saved");
		const text = state.failure ? "Not saved: " + state.failure : state.pending ? "Saving…" : last ? SAVED[last.doc.kind] : "";
		el.textContent = text;
		el.hidden = !text;
		el.classList.toggle("error", !!state.failure);
	}
	DocStore.onState(showSaved);

	// Opens files the user gave ([[relative path, File | bytes]], a .pen among them) as a new
	// document, kept in the browser unless `keep` is false.
	async function openFiles(files, { keep = true } = {}) {
		if (failed) return;
		const entries = [];
		for (const [rel, f] of files) entries.push([rel.replace(/^\/+/, ""), f instanceof Uint8Array ? f : new Uint8Array(await f.arrayBuffer())]);
		const pens = entries.map((e) => e[0]).filter((r) => /\.pen$/i.test(r));
		if (!pens.length) return showMessage("That is not a .pen file", "The editor opens .pen files, with the images and fonts they use next to them.", { error: true, actions: [["Choose another", showWelcome, true]] });
		try {
			const name = (pens.sort((a, b) => a.split("/").length - b.split("/").length || a.localeCompare(b))[0]).split("/").pop().replace(/\.pen$/i, "");
			const doc = keep ? await DocStore.create(name, entries) : { id: "tmp" + Date.now(), kind: "none", name, penRel: pens[0] };
			if (keep) await DocStore.lock(doc.id);
			startDoc(doc, entries);
		} catch (e) {
			showMessage("That could not be opened", String((e && e.message) || e), { error: true, actions: [["Choose another", showWelcome, true]] });
		}
	}

	// A document kept from before (the list on the start card).
	async function openKept(entry) {
		try {
			if (!(await DocStore.lock(entry.id))) {
				return showMessage("It is open in another tab", `“${entry.name}” is being edited in another tab of this browser. Use that one, or close it and open the document here.`, { actions: [["Back", showWelcome, true]] });
			}
			const { doc, files } = await DocStore.load(entry);
			startDoc(doc, files);
		} catch (e) {
			showMessage("That could not be opened", String((e && e.message) || e), { error: true, actions: [["Back", showWelcome, true]] });
		}
	}

	async function openFolder() {
		try {
			const { doc, files } = await DocStore.openFolder();
			await DocStore.lock(doc.id);
			startDoc(doc, files);
		} catch (e) {
			if (e && e.name === "AbortError") return;
			showMessage("That folder could not be opened", String((e && e.message) || e), { error: true, actions: [["Back", showWelcome, true]] });
		}
	}

	// The kept documents, on the start card.
	async function showRecent() {
		const box = $("recent"), items = (await DocStore.list()).slice(0, 8);
		box.hidden = items.length === 0;
		const ul = box.querySelector("ul");
		ul.textContent = "";
		for (const it of items) {
			const li = document.createElement("li");
			const open = Object.assign(document.createElement("button"), { type: "button", className: "recent-open", title: it.kind === "fs" ? "A folder on this computer" : "Kept in this browser" });
			open.append(Object.assign(document.createElement("span"), { className: "recent-name", textContent: it.name }));
			open.append(Object.assign(document.createElement("span"), { className: "recent-when", textContent: (it.kind === "fs" ? "folder · " : "") + new Date(it.updated).toLocaleString([], { dateStyle: "medium", timeStyle: "short" }) }));
			open.onclick = () => openKept(it);
			const del = Object.assign(document.createElement("button"), { type: "button", className: "recent-del", textContent: "×", title: it.kind === "fs" ? "Forget this folder" : "Delete from this browser" });
			del.setAttribute("aria-label", del.title);
			del.onclick = async () => { await DocStore.forget(it); showRecent(); };
			li.append(open, del);
			ul.append(li);
		}
	}

	const showWelcome = () => { $("message").hidden = true; $("welcome").hidden = started; if (!started) showRecent(); };
	const openNew = () => openFiles([[`untitled-${docCount + 1}.pen`, new TextEncoder().encode(NEW_DOCUMENT)]]);

	// The files of an input element: a folder keeps its structure.
	const fromInput = (list) => [...list].map((f) => [f.webkitRelativePath ? f.webkitRelativePath.split("/").slice(1).join("/") : f.name, f]);

	// A drop: files, and folders (walked through their entries).
	async function fromDrop(dt) {
		const entries = [...dt.items].map((i) => i.webkitGetAsEntry && i.webkitGetAsEntry()).filter(Boolean);
		if (!entries.length) return fromInput(dt.files);
		const out = [];
		const walk = async (entry, prefix) => {
			if (entry.isFile) {
				const file = await new Promise((ok, no) => entry.file(ok, no));
				out.push([prefix + entry.name, file]);
				return;
			}
			const reader = entry.createReader();
			for (let batch; (batch = await new Promise((ok, no) => reader.readEntries(ok, no))).length;) {
				for (const e of batch) await walk(e, prefix + entry.name + "/");
			}
		};
		// a dropped folder: its own name is not part of the paths
		for (const e of entries) {
			if (e.isDirectory) {
				const reader = e.createReader();
				for (let batch; (batch = await new Promise((ok, no) => reader.readEntries(ok, no))).length;) for (const c of batch) await walk(c, "");
			} else await walk(e, "");
		}
		return out;
	}

	// ---------------------------------------------------------------- cloud documents (/d/<id>)

	// A cloud document opens from its latest version (the .pen, then its images and fonts as the
	// engine asks for them), and goes live through its room: the room's document replaces the
	// version's at once, edits and pointers travel through the WebSocket (src/cloud_live.odin).
	const cloudId = decodeURIComponent((location.pathname.match(/^\/d\/([^/]+)\/?$/) || [])[1] || "");
	let cloud = null; // { id, file, dir, base, ws }
	const ROLE = { owner: "Owner", editor: "Can edit", commenter: "Can comment", viewer: "Can view" };

	async function openCloud(id) {
		$("welcome").hidden = true;
		$("loading").hidden = false;
		document.body.classList.add("cloud");
		let r;
		try { r = await fetch(`/api/docs/${encodeURIComponent(id)}`, { credentials: "same-origin", headers: { accept: "application/json" } }); }
		catch (e) { return showMessage("No connection", "The file could not be fetched. Check the connection and reload.", { error: true, actions: [["Reload", () => location.reload(), true]] }); }
		if (r.status === 401) return location.replace("/signin?next=" + encodeURIComponent(location.pathname));
		if (!r.ok) return showMessage("This file is not here", "It was deleted, or it is not shared with this account.", { error: true, actions: [["Dashboard", "/dashboard", true]] });
		const f = await r.json();
		if (!f.docUrl) return showMessage("This file is still uploading", "Try again in a moment.", { actions: [["Reload", () => location.reload(), true]] });
		const base = f.docUrl.slice(0, f.docUrl.indexOf("/", `/api/docs/${id}/v/`.length) + 1); // /api/docs/<id>/v/<ver>/
		const rel = f.docUrl.slice(base.length);
		const relDir = rel.includes("/") ? rel.slice(0, rel.lastIndexOf("/") + 1) : "";
		const dir = `/cloud/${id}/`;
		const safe = f.name.replace(/[\/\\:*?"<>|]+/g, " ").trim() || "Untitled";
		const penPath = dir + relDir + safe + ".pen";
		cloud = { id, file: f, dir, base, penPath, relPen: rel };
		const pen = await fetch(f.docUrl, { credentials: "same-origin" });
		if (!pen.ok) return showMessage("The file could not be read", `HTTP ${pen.status}`, { error: true, actions: [["Reload", () => location.reload(), true]] });
		addFile(penPath, new Uint8Array(await pen.arrayBuffer()));
		const [pp, pl] = putString(penPath);
		ex.editor_open(pp, pl);
		const [ip, il] = putString(id), [qp, ql] = putString(penPath), [np, nl] = putString(f.name);
		ex.editor_live_open(ip, il, qp, ql, np, nl);
		$("role").textContent = ROLE[f.role] || "";
		$("role").hidden = !f.role;
		document.title = `${f.name} — Agentic Design`;
		$("open-app").href = `agentic-design://open?doc=${encodeURIComponent(id)}`;
	}

	// The engine asks for a file of the cloud document it does not have: from the version.
	const fetching = new Set();
	async function want(paths) {
		if (!cloud) return;
		for (const p of paths.split("\n")) {
			if (!p.startsWith(cloud.dir) || fetching.has(p)) continue;
			fetching.add(p);
			const rel = p.slice(cloud.dir.length);
			try {
				const r = await fetch(cloud.base + rel.split("/").map(encodeURIComponent).join("/"), { credentials: "same-origin" });
				if (r.ok) addFile(p, new Uint8Array(await r.arrayBuffer()));
			} catch (e) {}
		}
	}

	// The room's WebSocket, for the engine (page_live_*): events go back as editor_live_event.
	function liveOpen(path) {
		liveClose();
		const url = (location.protocol === "https:" ? "wss://" : "ws://") + location.host + path;
		const ws = new WebSocket(url);
		cloud.ws = ws;
		const event = (kind, text, code) => {
			if (cloud.ws !== ws) return;
			if (text) { const [p, l] = putString(text); ex.editor_live_event(kind, p, l, code); }
			else ex.editor_live_event(kind, 0, 0, code);
		};
		ws.onopen = () => event(0, "", 0);
		ws.onmessage = (e) => event(1, typeof e.data === "string" ? e.data : "", 0);
		ws.onclose = (e) => event(2, e.reason || "", e.code);
	}
	function liveClose() {
		if (cloud && cloud.ws) { const ws = cloud.ws; cloud.ws = null; try { ws.close(1000); } catch (e) {} }
	}

	// Who is here, and whether the room holds us.
	function liveState(json) {
		let st;
		try { st = JSON.parse(json); } catch (e) { return; }
		const box = $("people");
		box.textContent = "";
		for (const p of st.people.slice(0, 6)) {
			const a = Object.assign(document.createElement("span"), { className: "avatar", textContent: (p.name || "?").trim().charAt(0).toUpperCase(), title: `${p.name} · ${ROLE[p.role] || ""}` });
			a.style.background = p.color;
			box.append(a);
		}
		if (st.people.length > 6) box.append(Object.assign(document.createElement("span"), { className: "avatar more", textContent: `+${st.people.length - 6}` }));
		const saved = $("saved");
		const text = { Connecting: "Connecting…", Live: st.people.length ? "Live" : "Live · only you", Offline: "Offline · reconnecting", Closed: st.error || "Disconnected" }[st.phase] || "";
		saved.textContent = text;
		saved.hidden = !text;
		saved.classList.toggle("error", st.phase === "Closed");
		if (st.role) { $("role").textContent = ROLE[st.role] || st.role; $("role").hidden = false; }
		// the owner manages who has access (the dashboard's People)
		$("people-link").style.display = st.role === "owner" ? "" : "none";
		$("people-link").href = `/dashboard?people=${encodeURIComponent(cloud.id)}`;
	}

	// ---------------------------------------------------------------- download

	function download() {
		if (!started || failed) return;
		saving = [];
		const ok = ex.editor_save();
		const paths = saving;
		saving = null;
		const path = paths.filter((p) => /\.pen$/i.test(p)).pop() || null; // (saving also writes a thumbnail)
		const bytes = ok && path ? written.get(path) : null;
		if (!bytes) return;
		const name = path.slice(path.lastIndexOf("/") + 1);
		const url = URL.createObjectURL(new Blob([bytes], { type: "application/json" }));
		const a = Object.assign(document.createElement("a"), { href: url, download: name });
		document.body.append(a);
		a.click();
		a.remove();
		setTimeout(() => URL.revokeObjectURL(url), 10000);
	}

	// ---------------------------------------------------------------- input

	let resizeTimer = 0;
	function resize() {
		const r = canvas.getBoundingClientRect();
		if (ex) ex.editor_resize(r.width, r.height, window.devicePixelRatio || 1);
	}

	function pos(e) {
		const r = canvas.getBoundingClientRect();
		return [e.clientX - r.left, e.clientY - r.top];
	}
	const BUTTON = [0, 2, 1]; // DOM left, middle, right → GLFW left (0), right (1), middle (2)

	function wireInput() {
		canvas.addEventListener("contextmenu", (e) => e.preventDefault());
		canvas.addEventListener("pointerdown", (e) => {
			canvas.focus();
			canvas.setPointerCapture(e.pointerId);
			const [x, y] = pos(e);
			ex.editor_button(BUTTON[e.button] ?? e.button, true, x, y);
			e.preventDefault();
		});
		canvas.addEventListener("pointerup", (e) => {
			const [x, y] = pos(e);
			ex.editor_button(BUTTON[e.button] ?? e.button, false, x, y);
			e.preventDefault();
		});
		canvas.addEventListener("pointercancel", (e) => {
			const [x, y] = pos(e);
			for (let b = 0; b < 3; b++) ex.editor_button(b, false, x, y);
		});
		canvas.addEventListener("pointermove", (e) => {
			const [x, y] = pos(e);
			ex.editor_move(x, y);
		});
		canvas.addEventListener("wheel", (e) => {
			e.preventDefault();
			const k = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? 400 : 1; // lines and pages to points
			if (e.ctrlKey) { // a trackpad's pinch (and ctrl + wheel)
				ex.editor_magnify(-e.deltaY * k * 0.01);
			} else if (e.deltaMode === 0 && Math.abs(e.deltaY) < 60 || e.deltaX !== 0) {
				ex.editor_scroll(-e.deltaX * k, -e.deltaY * k); // two fingers on a trackpad: points
			} else {
				ex.editor_wheel(-e.deltaX / 100, -e.deltaY / (e.deltaMode === 0 ? 100 : 3)); // a mouse wheel's notches
			}
		}, { passive: false });

		// keys: the physical key as GLFW numbers it; text comes separately, as on the desktop
		const KEEP = /^(r|l|t|w|n|q|k|j|o|d|e|p|f)$/i; // browser shortcuts a page should not take (with ctrl or cmd)
		const handleKey = (e, action) => {
			const code = GLFW_KEYS[e.code];
			if (code === undefined) return;
			if (e.target !== canvas && e.target !== document.body) return;
			ex.editor_key(code, action);
			const browser = (e.ctrlKey || e.metaKey) && KEEP.test(e.key) && !["d", "p", "f", "e", "o", "k", "j"].includes(e.key.toLowerCase()) || /^F\d+$/.test(e.code);
			if (!browser) e.preventDefault();
			if (action !== 0 && e.key.length > 0 && [...e.key].length === 1 && !e.ctrlKey && !e.metaKey) ex.editor_char(e.key.codePointAt(0));
		};
		window.addEventListener("keydown", (e) => handleKey(e, e.repeat ? 2 : 1));
		window.addEventListener("keyup", (e) => handleKey(e, 0));
		window.addEventListener("blur", () => { // keys that went up while the window was elsewhere
			for (const code of Object.values(GLFW_KEYS)) ex.editor_key(code, 0);
		});

		new ResizeObserver(() => { cancelAnimationFrame(resizeTimer); resizeTimer = requestAnimationFrame(resize); }).observe(canvas);
		matchMedia(`(resolution: ${window.devicePixelRatio}dppx)`).addEventListener("change", resize, { once: true });
		resize();
	}

	// drag and drop
	let dragDepth = 0;
	window.addEventListener("dragenter", (e) => { if (e.dataTransfer?.types.includes("Files")) { dragDepth++; $("drop").hidden = false; } });
	window.addEventListener("dragleave", () => { if (--dragDepth <= 0) { dragDepth = 0; $("drop").hidden = true; } });
	window.addEventListener("dragover", (e) => { if (e.dataTransfer?.types.includes("Files")) e.preventDefault(); });
	window.addEventListener("drop", async (e) => {
		dragDepth = 0;
		$("drop").hidden = true;
		if (!e.dataTransfer?.files.length) return;
		e.preventDefault();
		openFiles(await fromDrop(e.dataTransfer));
	});
	for (const id of ["open-files", "welcome-files"]) {
		$(id).addEventListener("change", (e) => { const f = fromInput(e.target.files); e.target.value = ""; if (f.length) openFiles(f); });
	}
	if (DocStore.supported.fs) {
		for (const id of ["open-folder", "welcome-folder"]) { $(id).hidden = false; $(id).addEventListener("click", openFolder); }
	}
	$("new").addEventListener("click", openNew);
	$("welcome-new").addEventListener("click", openNew);
	$("download").addEventListener("click", download);
	// leaving with changes still being written, or a document that is kept nowhere
	window.addEventListener("beforeunload", (e) => {
		if (DocStore.pending() > 0 || (started && sessions.some((s) => s.doc.kind === "none") && written.size)) { e.preventDefault(); e.returnValue = ""; }
	});

	// ---------------------------------------------------------------- start

	async function main() {
		if (!navigator.gpu) return noGpu();
		if (!cloudId) {
			$("welcome").hidden = false;
			showRecent();
		}
		mem = new odin.WasmMemoryInterface();
		const imports = {
			wgpu: new odin.WebGPUInterface(mem).getInterface(),
			editor: {
				page_set_cursor: (c) => { canvas.style.cursor = CURSORS[c] || "default"; },
				page_set_title: (ptr, len) => {
					const t = mem.loadString(ptr, len);
					$("title").textContent = t.replace(/\s+[—–-]\s+Agentic Design$/, "") || "Editor";
					document.title = `${t} (beta)`;
				},
				page_clipboard_write: (ptr, len) => { navigator.clipboard?.writeText(mem.loadString(ptr, len)).catch(() => {}); },
				page_fs_write: (pp, pl, dp, dl) => {
					const path = mem.loadString(pp, pl);
					const bytes = new Uint8Array(mem.memory.buffer.slice(dp, dp + dl));
					written.set(path, bytes);
					if (saving) saving.push(path);
					const [s, rel] = sessionOf(path);
					if (s) DocStore.write(s.doc, rel, bytes);
				},
				page_fs_remove: (ptr, len) => {
					const path = mem.loadString(ptr, len);
					written.delete(path);
					const [s, rel] = sessionOf(path);
					if (s) DocStore.remove(s.doc, rel);
				},
				page_fs_rename: (fp, fl, tp, tl) => {
					const from = mem.loadString(fp, fl), to = mem.loadString(tp, tl);
					if (written.has(from)) { written.set(to, written.get(from)); written.delete(from); }
					const [s, a] = sessionOf(from), [t, b] = sessionOf(to);
					if (s && s === t) DocStore.rename(s.doc, a, b);
				},
				page_error: (ptr, len) => {
					failed = true;
					const text = mem.loadString(ptr, len);
					if (/WebGPU/.test(text)) return noGpu();
					showMessage("The editor could not open this", text, { error: true, actions: [["Start over", () => location.reload(), true]] });
				},
				page_ready: () => {
					started = true;
					$("loading").hidden = true;
					$("welcome").hidden = true;
					$("download").disabled = false;
					canvas.focus();
				},
				page_want: (ptr, len) => want(mem.loadString(ptr, len)),
				page_live_open: (ptr, len) => liveOpen(mem.loadString(ptr, len)),
				page_live_send: (ptr, len) => { if (cloud && cloud.ws && cloud.ws.readyState === 1) cloud.ws.send(mem.loadString(ptr, len)); },
				page_live_close: () => liveClose(),
				page_live_state: (ptr, len) => liveState(mem.loadString(ptr, len)),
				page_live_http: (req, mp, ml, pp, pl, bp, bl) => {
					const method = mem.loadString(mp, ml), path = mem.loadString(pp, pl), body = mem.loadString(bp, bl);
					const done = (status, text) => {
						if (text) { const [p, l] = putString(text); ex.editor_live_http(req, status, p, l); }
						else ex.editor_live_http(req, status, 0, 0);
					};
					fetch(path, { method, credentials: "same-origin", headers: body ? { "content-type": "application/json", accept: "application/json" } : { accept: "application/json" }, body: body || undefined })
						.then(async (r) => done(r.status, await r.text()))
						.catch(() => done(0, ""));
				},
			},
		};
		try {
			await odin.runWasm(new URL("editor.wasm", HERE).href, null, imports, mem);
		} catch (e) {
			console.error(e);
			return showMessage("The editor could not start", String((e && e.message) || e), { error: true, actions: [["Reload", () => location.reload(), true]] });
		}
		ex = mem.exports;
		wireInput();
		// for the console and tests
		window.editor = { open: openFiles, openKept, openNew, download, files: written, sessions, store: DocStore, exports: ex, memory: () => mem.memory.buffer.byteLength, started: () => started };
		if (cloudId) return openCloud(cloudId);
		const file = new URLSearchParams(location.search).get("file");
		if (file) { // ?file=<url>: a .pen the page can fetch (same origin or CORS), to try the editor on
			try {
				const r = await fetch(file);
				if (!r.ok) throw new Error(`HTTP ${r.status}`);
				openFiles([[decodeURIComponent(new URL(file, location.href).pathname.split("/").pop()) || "design.pen", new Uint8Array(await r.arrayBuffer())]], { keep: false });
			} catch (e) {
				showMessage("That file could not be fetched", String(e.message || e), { error: true, actions: [["Choose a file", showWelcome, true]] });
			}
		}
	}
	main();
})();
