"use strict";
// The editor's page (web/edit/index.html): runs the app's interface, compiled to WebAssembly
// (src/editor_web.odin, src/platform_js.odin), on the page's canvas. This script is the
// platform: it hands the module the document's files, turns the page's pointer, wheel, key
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

	// Opens a document with the files it uses: `files` is [[relative path, File | bytes]], a
	// .pen among them. Gives all to the engine under /doc/ and starts (or opens a tab on) the
	// shallowest .pen.
	async function openFiles(files) {
		const pens = files.filter(([p]) => /\.pen$/i.test(p)).sort((a, b) => a[0].split("/").length - b[0].split("/").length || a[0].localeCompare(b[0]));
		if (!pens.length) return showMessage("That is not a .pen file", "The editor opens .pen files, with the images and fonts they use next to them.", { error: true, actions: [["Choose another", () => { $("message").hidden = true; showWelcome(); }, true]] });
		if (failed) return;
		$("message").hidden = true;
		$("welcome").hidden = true;
		const dir = `/doc/${++docCount}/`;
		for (const [rel, f] of files) {
			const bytes = f instanceof Uint8Array ? f : new Uint8Array(await f.arrayBuffer());
			addFile(dir + rel.replace(/^\/+/, ""), bytes);
		}
		const [pp, pl] = putString(dir + pens[0][0].replace(/^\/+/, ""));
		ex.editor_open(pp, pl);
		if (!started) $("loading").hidden = false;
	}

	const showWelcome = () => { $("message").hidden = true; $("welcome").hidden = started; };
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
	$("new").addEventListener("click", openNew);
	$("welcome-new").addEventListener("click", openNew);
	$("download").addEventListener("click", download);
	window.addEventListener("beforeunload", (e) => { if (started && written.size) { e.preventDefault(); e.returnValue = ""; } });

	// ---------------------------------------------------------------- start

	async function main() {
		if (!navigator.gpu) return noGpu();
		$("welcome").hidden = false;
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
					written.set(path, new Uint8Array(mem.memory.buffer.slice(dp, dp + dl)));
					if (saving) saving.push(path);
				},
				page_fs_remove: (ptr, len) => { written.delete(mem.loadString(ptr, len)); },
				page_fs_rename: (fp, fl, tp, tl) => {
					const from = mem.loadString(fp, fl), to = mem.loadString(tp, tl);
					if (written.has(from)) { written.set(to, written.get(from)); written.delete(from); }
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
		window.editor = { open: openFiles, openNew, download, files: written, exports: ex, memory: () => mem.memory.buffer.byteLength, started: () => started };
		const file = new URLSearchParams(location.search).get("file");
		if (file) { // ?file=<url>: a .pen the page can fetch (same origin or CORS), to try the editor on
			try {
				const r = await fetch(file);
				if (!r.ok) throw new Error(`HTTP ${r.status}`);
				openFiles([[decodeURIComponent(new URL(file, location.href).pathname.split("/").pop()) || "design.pen", new Uint8Array(await r.arrayBuffer())]]);
			} catch (e) {
				showMessage("That file could not be fetched", String(e.message || e), { error: true, actions: [["Choose a file", showWelcome, true]] });
			}
		}
	}
	main();
})();
