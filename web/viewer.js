"use strict";

// The page around the .pen viewer (src/web/viewer.odin): it runs the WebAssembly, fetches
// the files the engine asks for (by URL path on this server, or from files the user
// dropped or opened), and turns pointer, wheel and keys into pan and zoom.

(async function () {
	const canvas = document.getElementById("canvas");
	const message = document.getElementById("message");
	const title = document.getElementById("title");
	const pages = document.getElementById("pages");
	const zoom = document.getElementById("zoom");
	const missing = document.getElementById("missing");

	const mem = new odin.WasmMemoryInterface();
	const encoder = new TextEncoder();
	const local = new Map(); // "/local/..." -> bytes of a file the user dropped or opened
	let ex = null;

	function showMessage(text, error) {
		message.textContent = text;
		message.classList.toggle("error", !!error);
		message.hidden = !text;
	}

	// Copies bytes into the module's memory (viewer_alloc): [pointer, length].
	function put(bytes) {
		const ptr = ex.viewer_alloc(bytes.length);
		new Uint8Array(mem.memory.buffer, ptr, bytes.length).set(bytes);
		return [ptr, bytes.length];
	}

	async function fetchFiles(paths) {
		const got = await Promise.all(paths.map(async (path) => {
			if (local.has(path)) return local.get(path);
			try {
				const response = await fetch(path);
				if (response.ok) return new Uint8Array(await response.arrayBuffer());
			} catch (e) {}
			return new Uint8Array(0); // the engine draws without it
		}));
		paths.forEach((path, i) => {
			const [p, pl] = put(encoder.encode(path));
			const [d, dl] = put(got[i]);
			ex.viewer_file(p, pl, d, dl);
		});
		ex.viewer_files_done();
	}

	function open(path) {
		showMessage("");
		const [p, pl] = put(encoder.encode(path));
		ex.viewer_open(p, pl);
	}

	function showInfo(info) {
		window.viewerInfo = info; // (for the console and tests)
		title.textContent = info.title || "Agentic Design viewer";
		document.title = info.title ? info.title + " — Agentic Design viewer" : "Agentic Design viewer";
		const names = info.pages || [];
		pages.hidden = names.length < 2;
		if (pages.options.length !== names.length || [...pages.options].some((o, i) => o.text !== names[i])) {
			pages.replaceChildren(...names.map((name, i) => new Option(name, i)));
		}
		pages.value = String(info.page);
		zoom.textContent = Math.round(info.zoom * 100) + "%";
		const lost = info.missing || [];
		missing.style.display = lost.length ? "" : "none";
		missing.textContent = lost.length + (lost.length === 1 ? " file missing" : " files missing");
		missing.title = lost.join("\n");
	}

	const imports = {
		wgpu: new odin.WebGPUInterface(mem).getInterface(),
		viewer: {
			// (called from inside the module's frame: the fetch starts after it)
			page_fetch: (ptr, len) => {
				const paths = mem.loadString(ptr, len).split("\n").filter((p) => p);
				setTimeout(() => fetchFiles(paths), 0);
			},
			page_info: (ptr, len) => showInfo(JSON.parse(mem.loadString(ptr, len))),
			page_error: (ptr, len) => showMessage(mem.loadString(ptr, len), true),
		},
	};

	if (!navigator.gpu) {
		showMessage("This browser has no WebGPU (Chrome, Edge and Safari 26 have it).", true);
		return;
	}
	await odin.runWasm("viewer.wasm", null, imports, mem);
	ex = mem.exports;
	// for the console and tests
	window.viewer = {
		open: (path) => open(path),
		view: (zoom, x, y) => ex.viewer_view(zoom, x, y),
		fit: () => ex.viewer_fit(),
		pan: (dx, dy) => ex.viewer_pan(dx, dy),
		zoom: (factor, x, y) => ex.viewer_zoom(factor, x, y),
		memory: () => mem.memory.buffer.byteLength, // the module's heap, in bytes
		page: (i) => ex.viewer_set_page(i),
	};

	const file = new URLSearchParams(location.search).get("file");
	if (file) open(new URL(file, location.href).pathname);

	// ---------------------------------------------------------------- pan and zoom

	function at(e) {
		const r = canvas.getBoundingClientRect();
		return [e.clientX - r.left, e.clientY - r.top];
	}

	canvas.addEventListener("wheel", (e) => {
		e.preventDefault();
		let dx = e.deltaX, dy = e.deltaY;
		if (e.deltaMode === 1) { dx *= 16; dy *= 16; }
		else if (e.deltaMode === 2) { dx *= canvas.clientWidth; dy *= canvas.clientHeight; }
		const [x, y] = at(e);
		// a trackpad pinch comes as a wheel with ctrlKey; a mouse wheel's notch (100) zooms
		// by a quarter at most
		if (e.ctrlKey || e.metaKey) ex.viewer_zoom(Math.exp(-Math.max(-22, Math.min(22, dy)) * 0.01), x, y);
		else ex.viewer_pan(-dx, -dy);
	}, { passive: false });

	const pointers = new Map(); // id -> [x, y]
	let pinch = 0; // the distance between two fingers

	function spread() {
		const [a, b] = [...pointers.values()];
		return [Math.hypot(a[0] - b[0], a[1] - b[1]), (a[0] + b[0]) / 2, (a[1] + b[1]) / 2];
	}

	canvas.addEventListener("pointerdown", (e) => {
		canvas.setPointerCapture(e.pointerId);
		pointers.set(e.pointerId, at(e));
		if (pointers.size === 2) pinch = spread()[0];
		canvas.classList.add("dragging");
	});
	canvas.addEventListener("pointermove", (e) => {
		if (!pointers.has(e.pointerId)) return;
		const [x, y] = at(e);
		if (pointers.size === 2) {
			const [, mx0, my0] = spread();
			pointers.set(e.pointerId, [x, y]);
			const [d, mx, my] = spread();
			ex.viewer_pan(mx - mx0, my - my0);
			if (pinch > 0 && d > 0) ex.viewer_zoom(d / pinch, mx, my);
			pinch = d;
			return;
		}
		const [px, py] = pointers.get(e.pointerId);
		pointers.set(e.pointerId, [x, y]);
		ex.viewer_pan(x - px, y - py);
	});
	const release = (e) => {
		pointers.delete(e.pointerId);
		pinch = pointers.size === 2 ? spread()[0] : 0;
		if (!pointers.size) canvas.classList.remove("dragging");
	};
	canvas.addEventListener("pointerup", release);
	canvas.addEventListener("pointercancel", release);

	window.addEventListener("keydown", (e) => {
		if (e.target instanceof HTMLSelectElement) return;
		const cx = canvas.clientWidth / 2, cy = canvas.clientHeight / 2;
		if (e.key === "0" || e.key === "1" && e.shiftKey || e.key === "!") ex.viewer_fit();
		else if (e.key === "+" || e.key === "=") ex.viewer_zoom(1.25, cx, cy);
		else if (e.key === "-") ex.viewer_zoom(0.8, cx, cy);
		else return;
		e.preventDefault();
	});

	zoom.addEventListener("click", () => ex.viewer_fit());
	pages.addEventListener("change", () => ex.viewer_set_page(Number(pages.value)));

	// ---------------------------------------------------------------- local files

	// Files the user dropped or picked go under /local/, keeping their folders, so a
	// document finds its images, fonts and libraries next to it as on disk.
	async function addLocal(entries) {
		let docs = [];
		for (const [path, file] of entries) {
			const p = "/local/" + path.replace(/^\/+/, "");
			local.set(p, new Uint8Array(await file.arrayBuffer()));
			if (p.endsWith(".pen")) docs.push(p);
		}
		// a design over a library (.lib.pen), the shallowest first
		docs.sort((a, b) => (a.endsWith(".lib.pen") - b.endsWith(".lib.pen")) || (a.split("/").length - b.split("/").length) || a.localeCompare(b));
		if (docs.length) open(docs[0]);
		else showMessage("There is no .pen file among these.", true);
	}

	function picked(input) {
		const files = [...input.files].map((f) => [f.webkitRelativePath || f.name, f]);
		input.value = "";
		if (files.length) addLocal(files);
	}
	document.getElementById("open-dir").addEventListener("change", (e) => picked(e.target));
	document.getElementById("open-files").addEventListener("change", (e) => picked(e.target));

	async function walk(entry, prefix, out) {
		if (entry.isFile) {
			out.push([prefix + entry.name, await new Promise((ok, fail) => entry.file(ok, fail))]);
		} else if (entry.isDirectory) {
			const reader = entry.createReader();
			for (;;) {
				const batch = await new Promise((ok, fail) => reader.readEntries(ok, fail));
				if (!batch.length) break;
				for (const child of batch) await walk(child, prefix + entry.name + "/", out);
			}
		}
	}

	window.addEventListener("dragover", (e) => {
		e.preventDefault();
		document.body.classList.add("drop");
	});
	window.addEventListener("dragleave", () => document.body.classList.remove("drop"));
	window.addEventListener("drop", async (e) => {
		e.preventDefault();
		document.body.classList.remove("drop");
		const out = [];
		for (const item of [...e.dataTransfer.items]) {
			const entry = item.webkitGetAsEntry && item.webkitGetAsEntry();
			if (entry) await walk(entry, "", out);
		}
		if (out.length) addLocal(out);
	});
})();
