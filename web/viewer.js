"use strict";

// The page around the .pen viewer (src/web/viewer.odin): it runs the WebAssembly, hands
// the engine the files it asks for and turns pointer, wheel and keys into pan, zoom and
// selection.
//
// Where files come from:
// - files the user dropped or picked: kept in this page (nothing is uploaded), under
//   /local/<n>/ with their folders, so a document finds its images, fonts and libraries
//   next to it as on disk; a file that is not where the document says is matched by name;
// - ?file=/path: a document on this server;
// - ?url=https://...: a public document elsewhere, fetched by the browser (its server must
//   allow it: CORS); the engine sees it as /~url/https/host/path, so relative paths in it
//   resolve as they would on that server.

(async function () {
	// where this script and its files live (the share pages load it from /view/)
	const HERE = document.currentScript ? document.currentScript.src : location.href;
	const $ = (id) => document.getElementById(id);
	const canvas = $("canvas");
	const body = document.body;
	const SAMPLE = "samples/agentic-design/agentic-design.pen";
	// A share page (/s/<token>, /embed/<token>): the site's Worker puts the link's data in
	// #ad-share (the M1 API contract, §5 and §6).
	const shareEl = document.getElementById("ad-share");
	const share = shareEl ? JSON.parse(shareEl.textContent) : null;
	const embed = body.classList.contains("embed");

	const encoder = new TextEncoder();
	const local = new Map(); // "/local/<n>/a/b.pen" -> bytes of a file the user gave
	let session = 0; // <n> above: a new one for every drop (the engine keeps a file once)
	let ex = null; // the module's exports
	let mem = null;
	let docPath = ""; // the open document's path, as the engine knows it
	let info = null; // the last page_info
	const failed = new Map(); // path -> why it could not be fetched
	const dismissed = new Set();

	// ---------------------------------------------------------------- messages

	function showMessage(title, text, opts = {}) {
		$("message-title").textContent = title;
		$("message-text").textContent = text;
		$("message").classList.toggle("error", !!opts.error);
		const actions = $("message-actions");
		actions.replaceChildren(...(opts.actions || []).map(([label, href, primary]) => {
			const a = document.createElement(typeof href === "function" ? "button" : "a");
			a.className = "btn" + (primary ? " primary" : "");
			a.textContent = label;
			if (typeof href === "function") { a.type = "button"; a.addEventListener("click", href); } else a.href = href;
			return a;
		}));
		$("message").hidden = false;
		$("welcome").hidden = true;
	}
	function hideMessage() { $("message").hidden = true; }

	function showWelcome() {
		if (share) return location.assign("/view/"); // a share page opens nothing else
		hideMessage();
		$("welcome").hidden = false;
		setTimeout(() => $("welcome-files").closest("label").focus?.(), 0);
	}

	const noGpu = () => showMessage("This browser cannot draw the viewer",
		"The viewer runs the Agentic Design engine on WebGPU, which this browser does not offer (or has turned off). It works in Chrome and Edge 113 or later, Safari 26 or later, and Firefox 141 or later on Windows. On a Mac, the app itself opens every .pen file.",
		{ error: true, actions: [["Download the app", "https://github.com/kirill-dev-pro/agentic-design/releases/latest", true], ["Agentic Design", "/"]] });

	// ---------------------------------------------------------------- files

	// Copies bytes into the module's memory (viewer_alloc): [pointer, length].
	function put(bytes) {
		const ptr = ex.viewer_alloc(bytes.length);
		new Uint8Array(mem.memory.buffer, ptr, bytes.length).set(bytes);
		return [ptr, bytes.length];
	}

	const base = (p) => p.slice(p.lastIndexOf("/") + 1).toLowerCase();

	function toVirtual(url) {
		const u = new URL(url);
		return "/~url/" + u.protocol.replace(":", "") + "/" + u.host + decodeURIComponent(u.pathname);
	}
	function fromVirtual(path) {
		const m = /^\/~url\/(https?)\/([^/]+)(\/.*)$/.exec(path);
		return m ? `${m[1]}://${m[2]}${encodeURI(m[3])}` : null;
	}

	async function getFile(path) {
		if (local.has(path)) return local.get(path);
		if (path.startsWith("/local/")) {
			// dropped together but not where the document says: the same name in this drop
			const prefix = `/local/${session}/`;
			const name = base(path);
			for (const [p, bytes] of local) if (p.startsWith(prefix) && base(p) === name) return bytes;
			return null;
		}
		const remote = fromVirtual(path);
		try {
			const response = await fetch(remote || path, remote ? { mode: "cors", credentials: "omit" } : {});
			if (response.ok) return new Uint8Array(await response.arrayBuffer());
			failed.set(path, `${response.status} ${response.statusText}`.trim());
		} catch (e) {
			// a cross-origin fetch the server does not allow fails without a status
			failed.set(path, remote ? "cors" : "network");
		}
		return null;
	}

	async function fetchFiles(paths) {
		const got = await Promise.all(paths.map(getFile));
		if (got[paths.indexOf(docPath)] === null) return docFailed(docPath);
		paths.forEach((path, i) => {
			const [p, pl] = put(encoder.encode(path));
			const [d, dl] = put(got[i] || new Uint8Array(0)); // a missing file: the engine draws without it
			ex.viewer_file(p, pl, d, dl);
		});
		ex.viewer_files_done();
	}

	function docFailed(path) {
		const remote = fromVirtual(path);
		const why = failed.get(path);
		if (remote && why === "cors") {
			showMessage("The file could not be read",
				`${new URL(remote).host} does not let other sites read its files (no CORS header), or it cannot be reached. Download the file and drop it here instead: it stays in your browser.`,
				{ error: true, actions: [["Download it", remote, true], ["Open a file", () => showWelcome()]] });
		} else {
			showMessage("The file could not be read", `${remote || path}: ${why || "not found"}.`,
				{ error: true, actions: [["Open a file", () => showWelcome(), true]] });
		}
	}

	function open(path) {
		hideMessage();
		$("welcome").hidden = true;
		docPath = path;
		failed.clear();
		dismissed.clear();
		const [p, pl] = put(encoder.encode(path));
		ex.viewer_open(p, pl);
	}

	function openUrl(raw) {
		let url;
		try { url = new URL(raw.trim(), location.href); } catch (e) { return showMessage("That is not a URL", raw, { error: true, actions: [["Back", () => showWelcome(), true]] }); }
		// a file page on GitHub: its raw file (served with CORS)
		const gh = /^https:\/\/github\.com\/([^/]+)\/([^/]+)\/blob\/(.+)$/.exec(url.href);
		if (gh) url = new URL(`https://raw.githubusercontent.com/${gh[1]}/${gh[2]}/${gh[3]}`);
		if (url.origin === location.origin) open(decodeURIComponent(url.pathname));
		else open(toVirtual(url.href));
	}

	function openSample() {
		openUrl(new URL(SAMPLE, HERE).href);
		history.replaceState(null, "", "?sample");
	}

	// Files the user dropped or picked: a design over a library (.lib.pen), the shallowest
	// first. With a document open and no other document among them, they are added to it
	// (its fonts folder, a library) and the document is read again.
	async function addLocal(entries) {
		const docs = [];
		const prev = docPath.startsWith(`/local/${session}/`) ? docPath.slice(`/local/${session}/`.length) : null;
		const carried = prev ? [...local].filter(([p]) => p.startsWith(`/local/${session}/`)) : [];
		session += 1;
		const prefix = `/local/${session}/`;
		for (const [p, bytes] of carried) local.set(prefix + p.slice(`/local/${session - 1}/`.length), bytes);
		for (const [path, file] of entries) {
			const p = prefix + path.replace(/^\/+/, "");
			local.set(p, new Uint8Array(await file.arrayBuffer()));
			if (/\.pen$/i.test(p)) docs.push(p);
		}
		const designs = docs.filter((d) => !/\.lib\.pen$/i.test(d));
		if (prev && !designs.length) return open(prefix + prev);
		docs.sort((a, b) => (/\.lib\.pen$/i.test(a) - /\.lib\.pen$/i.test(b)) || (a.split("/").length - b.split("/").length) || a.localeCompare(b));
		if (docs.length) {
			history.replaceState(null, "", location.pathname);
			open(docs[0]);
		} else {
			showMessage("There is no .pen file among these", "Drop a .pen file, or the folder it is in.", { error: true, actions: [["Open a file", () => showWelcome(), true]] });
		}
	}

	// ---------------------------------------------------------------- what the page shows

	function setTheme(axis, value) {
		const [a, al] = put(encoder.encode(axis));
		const [v, vl] = put(encoder.encode(value));
		ex.viewer_set_theme(a, al, v, vl);
	}

	const listButton = (label, current, onClick) => {
		const li = document.createElement("li");
		const b = document.createElement("button");
		b.type = "button";
		b.textContent = label;
		b.title = label;
		b.setAttribute("aria-current", current ? "true" : "false");
		b.addEventListener("click", onClick);
		li.append(b);
		return li;
	};

	// ?page=N from the URL, applied once the document has that many pages
	let pendingPage = Number(new URLSearchParams(location.search).get("page")) || 0;

	// A document from a URL (or the sample) keeps its page and theme in the address, so the
	// link opens the same view; dropped files have no address to share.
	function syncAddress() {
		if (!info || docPath.startsWith("/local/") || !location.search) return;
		const params = new URLSearchParams(location.search);
		if (info.page > 0) params.set("page", String(info.page));
		else params.delete("page");
		const set = (info.themes || []).filter((a) => a.values.length && a.value !== a.values[0]).map((a) => `${a.name}:${a.value}`);
		if (set.length) params.set("theme", set.join(","));
		else params.delete("theme");
		const next = "?" + params.toString().replace(/%3A/g, ":").replace(/%2C/g, ",").replace(/%2F/g, "/").replace(/^\?sample=(&|$)/, "?sample$1");
		if (next !== location.search) history.replaceState(null, "", next);
	}

	let shownShape = "";
	function showInfo(next) {
		info = next;
		if (pendingPage && (info.pages || []).length > pendingPage) {
			const p = pendingPage;
			pendingPage = 0;
			ex.viewer_set_page(p);
		}
		window.viewerInfo = info; // (for the console and tests)
		const loaded = !!(info.frames && (info.frames.length || (info.pages || []).length));
		if (!share) {
			const title = loaded && info.title !== "." ? info.title : "";
			$("title").textContent = title || ".pen viewer";
			document.title = title ? title + " — .pen viewer" : ".pen viewer — Agentic Design";
		}
		$("export").disabled = !loaded;
		$("toggle-side").hidden = !loaded;
		if (loaded && !body.dataset.sideSet) {
			body.dataset.sideSet = "1";
			setSide(innerWidth > 720);
		}

		// pages and frames
		const names = info.pages || [];
		$("pages-section").hidden = names.length < 2;
		const shape = JSON.stringify([names, info.page, (info.frames || []).map((f) => [f.uid, f.name]), info.sel && info.sel.uid]);
		if (shape !== shownShape) {
			shownShape = shape;
			$("pages").replaceChildren(...names.map((name, i) => listButton(name, i === info.page, () => ex.viewer_set_page(i))));
			$("frames").replaceChildren(...(info.frames || []).map((f) => listButton(f.name, info.sel && info.sel.uid === f.uid, () => {
				ex.viewer_select(f.uid);
				ex.viewer_zoom_to(f.uid);
			})));
		}

		// one picker per theme axis ("mode: light | dark"), rebuilt when the axes change
		const themes = $("themes");
		const axes = info.themes || [];
		const tshape = JSON.stringify(axes.map((a) => [a.name, a.values]));
		if (themes.dataset.shape !== tshape) {
			themes.dataset.shape = tshape;
			themes.replaceChildren(...axes.map((a) => {
				const select = document.createElement("select");
				select.title = "Theme: " + a.name;
				select.setAttribute("aria-label", "Theme: " + a.name);
				select.dataset.axis = a.name;
				select.append(...a.values.map((v) => new Option(a.name + ": " + v, v)));
				select.addEventListener("change", () => setTheme(a.name, select.value));
				return select;
			}));
		}
		for (const a of axes) {
			const select = themes.querySelector(`select[data-axis="${CSS.escape(a.name)}"]`);
			if (select) select.value = a.value;
		}
		placeThemes();
		syncAddress();

		$("zoom").textContent = Math.round(info.zoom * 100) + "%";

		// the selected layer
		const sel = info.sel;
		$("info").hidden = !sel;
		if (sel) {
			$("info-name").textContent = sel.name;
			$("info-name").title = sel.name + (sel.id ? ` (id ${sel.id})` : "");
			$("info-type").textContent = sel.component ? `${sel.type} of ${sel.component}` : sel.type;
			$("info-x").textContent = sel.x;
			$("info-y").textContent = sel.y;
			$("info-w").textContent = sel.w;
			$("info-h").textContent = sel.h;
		}
		showNotices();
	}

	function showNotices() {
		if (!info) return;
		const lost = info.missing || [];
		const notes = [];
		const libs = lost.filter((p) => /\.pen$/i.test(p));
		const fontFiles = lost.filter((p) => /\.(ttf|otf|woff2?|ttc)$/i.test(p));
		const images = lost.filter((p) => !libs.includes(p) && !fontFiles.includes(p));
		const isLocal = docPath.startsWith("/local/");
		const shortName = (p) => (fromVirtual(p) || p).replace(/^\/local\/\d+\//, "");
		if (libs.length) {
			notes.push(["libs", `${libs.length === 1 ? "A library this document imports was" : libs.length + " libraries this document imports were"} not found: ${libs.map(shortName).join(", ")}.`,
				isLocal ? "Drop the library files here too (or the whole folder); its components are missing until then." : "Its components are missing."]);
		}
		const families = (info.fonts || []).filter((f) => f.missing).map((f) => f.family);
		if (families.length) {
			notes.push(["fonts", `${families.join(", ")} ${families.length === 1 ? "is" : "are"} drawn with Noto Sans, as in pen.dev.`,
				fontFiles.length && isLocal ? `The document lists font files that are not here (${fontFiles.slice(0, 3).map(shortName).join(", ")}${fontFiles.length > 3 ? ` and ${fontFiles.length - 3} more` : ""}): drop its folder with the fonts folder.`
					: `The document does not include ${families.length === 1 ? "this font's files" : "these fonts' files"}.`]);
		}
		if (images.length) {
			notes.push(["images", `${images.length} ${images.length === 1 ? "image was" : "images were"} not found.`,
				isLocal ? "Drop the document's folder so its images come along." : images.slice(0, 3).map(shortName).join(", ")]);
		}
		const cors = [...failed].filter(([p, why]) => why === "cors" && p !== docPath).map(([p]) => p);
		if (cors.length) notes.push(["cors", `The server does not let this page read ${cors.length} of the document's files (CORS).`, "Download the folder and drop it here instead."]);
		const box = $("notices");
		box.replaceChildren(...notes.filter(([key, text]) => !dismissed.has(key + text)).map(([key, text, more]) => {
			const div = document.createElement("div");
			div.className = "notice";
			const p = document.createElement("p");
			p.textContent = text + " ";
			const small = document.createElement("small");
			small.textContent = more;
			p.append(small);
			const close = document.createElement("button");
			close.type = "button";
			close.setAttribute("aria-label", "Dismiss");
			close.textContent = "×";
			close.addEventListener("click", () => { dismissed.add(key + text); showNotices(); });
			div.append(p, close);
			return div;
		}));
	}

	// The theme pickers sit in the bar, or in the side panel where the bar is too narrow.
	const narrow = matchMedia("(max-width: 720px)");
	function placeThemes() {
		const themes = $("themes");
		const home = narrow.matches ? $("themes-side") : $("export");
		if (narrow.matches) home.append(themes);
		else home.before(themes);
		$("themes-section").hidden = !narrow.matches || !themes.children.length;
	}
	narrow.addEventListener("change", placeThemes);

	function setSide(on) {
		$("side").hidden = !on;
		body.classList.toggle("with-side", on);
		$("toggle-side").setAttribute("aria-expanded", on ? "true" : "false");
	}

	// ---------------------------------------------------------------- export

	function download(blob, name) {
		const a = document.createElement("a");
		a.href = URL.createObjectURL(blob);
		a.download = name;
		document.body.append(a);
		a.click();
		a.remove();
		setTimeout(() => URL.revokeObjectURL(a.href), 10000);
	}

	// The canvas is drawn at the picture's size, copied in the same task (a WebGPU canvas
	// keeps its picture until the task ends) and drawn back at the next frame.
	function exportCanvas(uid, scale) {
		// drawn twice: the first pass puts glyphs of a new size into the atlas (Safari can
		// draw the first pass without them)
		if (!ex.viewer_export(uid, scale)) return null;
		const packed = ex.viewer_export(uid, scale);
		if (!packed) return null;
		const w = packed >>> 16, h = packed & 0xffff;
		const copy = document.createElement("canvas");
		copy.width = w;
		copy.height = h;
		copy.getContext("2d").drawImage(canvas, 0, 0, w, h, 0, 0, w, h);
		return copy;
	}

	function exportPng(uid, scale) {
		const copy = exportCanvas(uid, scale);
		if (!copy) return;
		const stem = (info.title || "design").replace(/\.pen$/i, "");
		const what = uid ? (info.sel && info.sel.uid === uid ? info.sel.name : "layer") : (info.pages && info.pages[info.page]) || "page";
		const name = `${stem} - ${what}${scale !== 1 ? "@" + scale + "x" : ""}.png`.replace(/[\\/:*?"<>|]+/g, "-");
		copy.toBlob((blob) => blob && download(blob, name), "image/png");
	}

	function openExport() {
		const dialog = $("export-dialog");
		const sel = info && info.sel;
		const selRadio = dialog.querySelector('input[value="sel"]');
		selRadio.disabled = !sel;
		$("export-sel-label").textContent = sel ? `The selection: ${sel.name}` : "The selection (none)";
		if (!sel) dialog.querySelector('input[value="page"]').checked = true;
		else selRadio.checked = true;
		dialog.hidden = false;
		$("export-go").focus();
	}
	$("export").addEventListener("click", () => ($("export-dialog").hidden ? openExport() : ($("export-dialog").hidden = true)));
	$("export-cancel").addEventListener("click", () => ($("export-dialog").hidden = true));
	$("export-go").addEventListener("click", () => {
		const d = $("export-dialog");
		const what = d.querySelector('input[name="what"]:checked').value;
		const scale = Number(d.querySelector('input[name="scale"]:checked').value);
		d.hidden = true;
		exportPng(what === "sel" && info.sel ? info.sel.uid : 0, scale);
	});
	$("info-export").addEventListener("click", () => info.sel && exportPng(info.sel.uid, 2));
	$("info-zoom").addEventListener("click", () => ex.viewer_zoom_to(0));
	$("info-parent").addEventListener("click", () => ex.viewer_select_parent());

	// ---------------------------------------------------------------- start

	// ---------------------------------------------------------------- share pages

	const SHARE_ERRORS = {
		NOT_FOUND: ["This link does not exist", "Check that you have the whole link, or ask the person who sent it for a new one."],
		REVOKED: ["This file is no longer shared", "The owner stopped sharing it. Ask them for a new link."],
		EXPIRED: ["This link has expired", "Ask the person who sent it for a new link."],
		EMBED_OFF: ["This file cannot be embedded", "The owner has not allowed it on other sites."],
	};

	// The bar on a share page: the file's name and owner, Download, the app.
	function shareBar() {
		document.title = `${share.name} · Agentic Design`;
		$("title").textContent = share.name;
		$("owner").textContent = "by " + share.owner.name;
		$("owner").hidden = false;
		$("open").closest(".menu-wrap").hidden = true;
		if (share.download) {
			$("share-download").href = share.download;
			$("share-download").hidden = false;
		}
		$("get-app").hidden = false;
		if (embed && share.url) {
			$("embed-open").href = share.url;
			$("embed-open").hidden = false;
		}
	}

	// Without WebGPU: pictures of the frames, rendered when the file was shared.
	function showFrames() {
		const frames = (share.previews && share.previews.frames) || [];
		if (!frames.length) {
			return showMessage("This browser cannot show the design",
				"The live viewer needs WebGPU (Safari 26, Chrome and Edge 113 or later), and this file was shared without pictures of its frames." + (share.download ? " You can download it and open it in the Agentic Design app." : ""),
				{ error: true, actions: [...(share.download ? [["Download the file", share.download, true]] : []), ["Get Agentic Design", "/"]] });
		}
		hideMessage();
		$("frames-title").textContent = share.name;
		$("frames-list").replaceChildren(...frames.map((f) => {
			const fig = document.createElement("figure");
			const a = Object.assign(document.createElement("a"), { href: f.url, target: "_blank", rel: "noopener" });
			const img = Object.assign(document.createElement("img"), { src: f.url, alt: f.name, loading: "lazy", decoding: "async", width: f.width, height: f.height });
			a.append(img);
			const cap = Object.assign(document.createElement("figcaption"), { textContent: f.name });
			fig.append(a, cap);
			return fig;
		}));
		$("frames-view").hidden = false;
	}

	if (share) {
		body.classList.add("share");
		if (share.error) {
			const [title, text] = SHARE_ERRORS[share.error] || SHARE_ERRORS.NOT_FOUND;
			document.title = title + " · Agentic Design";
			$("open").closest(".menu-wrap").hidden = true;
			return showMessage(title, text, { error: true, actions: [["Agentic Design", "/", true]] });
		}
		shareBar();
	}

	if (!navigator.gpu) return share ? showFrames() : noGpu();
	showMessage("Loading the viewer…", "");
	mem = new odin.WasmMemoryInterface();
	let gpuFailed = false;
	const imports = {
		wgpu: new odin.WebGPUInterface(mem).getInterface(),
		viewer: {
			// (called from inside the module's frame: the fetch starts after it)
			page_fetch: (ptr, len) => {
				const paths = mem.loadString(ptr, len).split("\n").filter((p) => p);
				setTimeout(() => fetchFiles(paths), 0);
			},
			page_info: (ptr, len) => showInfo(JSON.parse(mem.loadString(ptr, len))),
			page_error: (ptr, len) => {
				const text = mem.loadString(ptr, len);
				if (/WebGPU/.test(text)) { gpuFailed = true; return share ? showFrames() : noGpu(); }
				showMessage("This file could not be opened", text, { error: true, actions: [["Open another file", () => showWelcome(), true]] });
			},
		},
	};
	try {
		await odin.runWasm(new URL("viewer.wasm", HERE).href, null, imports, mem);
	} catch (e) {
		console.error(e);
		return showMessage("The viewer could not start", String(e && e.message || e), { error: true, actions: [["Reload", () => location.reload(), true]] });
	}
	ex = mem.exports;
	// wait for the GPU (the module asks for it at start)
	await new Promise((r) => setTimeout(r, 0));
	if (gpuFailed) return;

	// for the console and tests
	window.viewer = {
		open: (path) => open(path),
		openUrl: (url) => openUrl(url),
		view: (zoom, x, y) => ex.viewer_view(zoom, x, y),
		fit: () => ex.viewer_fit(),
		pan: (dx, dy) => ex.viewer_pan(dx, dy),
		zoom: (factor, x, y) => ex.viewer_zoom(factor, x, y),
		memory: () => mem.memory.buffer.byteLength, // the module's heap, in bytes
		page: (i) => ex.viewer_set_page(i),
		theme: (axis, value) => setTheme(axis, value),
		pick: (x, y, mode = 0) => ex.viewer_pick(x, y, mode),
		select: (uid) => ex.viewer_select(uid),
		zoomTo: (uid) => ex.viewer_zoom_to(uid),
		exportPng: (uid, scale) => exportPng(uid, scale),
		exportCanvas: (uid, scale) => exportCanvas(uid, scale), // (tests: the picture without the download)
	};

	const params = new URLSearchParams(location.search);
	// ?theme=mode:dark,platform:ios picks theme values before the document shows
	for (const pair of (params.get("theme") || "").split(",")) {
		const i = pair.indexOf(":");
		if (i > 0) setTheme(pair.slice(0, i), pair.slice(i + 1));
	}
	if (share) {
		// root-relative on this site today; absolute once files come from the content host
		if (share.doc.url.startsWith("/")) open(share.doc.url);
		else openUrl(share.doc.url);
	} else if (params.get("file")) open(new URL(params.get("file"), location.href).pathname);
	else if (params.get("url")) openUrl(params.get("url"));
	else if (params.has("sample")) openSample();
	else showWelcome();

	// ---------------------------------------------------------------- pointer and keys

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

	// Safari's trackpad pinch
	let gestureScale = 1;
	canvas.addEventListener("gesturestart", (e) => { e.preventDefault(); gestureScale = 1; });
	canvas.addEventListener("gesturechange", (e) => {
		e.preventDefault();
		const [x, y] = at(e);
		ex.viewer_zoom(e.scale / gestureScale, x, y);
		gestureScale = e.scale;
	});

	const pointers = new Map(); // id -> [x, y]
	let pinch = 0; // the distance between two fingers
	let press = null; // where a press began, until it moves: a click selects

	function spread() {
		const [a, b] = [...pointers.values()];
		return [Math.hypot(a[0] - b[0], a[1] - b[1]), (a[0] + b[0]) / 2, (a[1] + b[1]) / 2];
	}

	canvas.addEventListener("pointerdown", (e) => {
		canvas.setPointerCapture(e.pointerId);
		pointers.set(e.pointerId, at(e));
		press = pointers.size === 1 && e.button === 0 ? { at: at(e), deep: e.metaKey || e.ctrlKey } : null;
		if (pointers.size === 2) pinch = spread()[0];
		$("export-dialog").hidden = true;
	});
	canvas.addEventListener("pointermove", (e) => {
		if (!pointers.has(e.pointerId)) return;
		const [x, y] = at(e);
		if (press && Math.hypot(x - press.at[0], y - press.at[1]) < 4) return;
		press = null;
		canvas.classList.add("dragging");
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
	let lastTap = null; // a touch tap, for double taps: { at, time }
	const release = (e) => {
		if (press && e.type === "pointerup") {
			const [x, y] = press.at;
			if (e.pointerType === "touch" && lastTap && e.timeStamp - lastTap.time < 350 && Math.hypot(x - lastTap.at[0], y - lastTap.at[1]) < 30) {
				// a double tap zooms to the layer under the finger, or fits the page
				ex.viewer_pick(x, y, 0);
				if (info && info.sel) ex.viewer_zoom_to(0);
				else ex.viewer_fit();
				lastTap = null;
			} else {
				ex.viewer_pick(x, y, press.deep ? 2 : 0);
				lastTap = e.pointerType === "touch" ? { at: [x, y], time: e.timeStamp } : null;
			}
		}
		press = null;
		pointers.delete(e.pointerId);
		pinch = pointers.size === 2 ? spread()[0] : 0;
		if (!pointers.size) canvas.classList.remove("dragging");
	};
	canvas.addEventListener("pointerup", release);
	canvas.addEventListener("pointercancel", release);
	canvas.addEventListener("dblclick", (e) => {
		const [x, y] = at(e);
		ex.viewer_pick(x, y, 1);
	});

	window.addEventListener("keydown", (e) => {
		if (e.target instanceof HTMLInputElement || e.target instanceof HTMLSelectElement || !ex) return;
		const cx = canvas.clientWidth / 2, cy = canvas.clientHeight / 2;
		if (e.key === "Escape") {
			if (!$("export-dialog").hidden) $("export-dialog").hidden = true;
			else if (!$("open-menu").hidden) closeMenu();
			else ex.viewer_select(0);
		} else if (e.metaKey || e.ctrlKey || e.altKey) return;
		else if (e.key === "0" || (e.key === "1" && e.shiftKey) || e.key === "!") ex.viewer_fit();
		else if ((e.key === "2" && e.shiftKey) || e.key === "@" || e.key === "f") ex.viewer_zoom_to(0);
		else if (e.key === "Enter" && e.shiftKey) ex.viewer_select_parent();
		else if (e.key === "+" || e.key === "=") ex.viewer_zoom(1.25, cx, cy);
		else if (e.key === "-" || e.key === "_") ex.viewer_zoom(0.8, cx, cy);
		else return;
		e.preventDefault();
	});

	$("zoom").addEventListener("click", () => ex.viewer_fit());
	$("zoom-in").addEventListener("click", () => ex.viewer_zoom(1.25, canvas.clientWidth / 2, canvas.clientHeight / 2));
	$("zoom-out").addEventListener("click", () => ex.viewer_zoom(0.8, canvas.clientWidth / 2, canvas.clientHeight / 2));
	$("toggle-side").addEventListener("click", () => setSide($("side").hidden));

	// ---------------------------------------------------------------- opening

	function closeMenu() {
		$("open-menu").hidden = true;
		$("open").setAttribute("aria-expanded", "false");
	}
	$("open").addEventListener("click", (e) => {
		e.stopPropagation();
		const menu = $("open-menu");
		menu.hidden = !menu.hidden;
		$("open").setAttribute("aria-expanded", menu.hidden ? "false" : "true");
	});
	document.addEventListener("click", (e) => { if (!e.target.closest(".menu-wrap")) closeMenu(); });
	$("open-menu").addEventListener("keydown", (e) => {
		if ((e.key === "Enter" || e.key === " ") && e.target.tagName === "LABEL") { e.preventDefault(); e.target.click(); }
	});
	for (const el of document.querySelectorAll('[data-action="sample"]')) el.addEventListener("click", () => { closeMenu(); openSample(); });
	document.querySelector('[data-action="url"]').addEventListener("click", () => {
		closeMenu();
		showWelcome();
		$("url-input").focus();
	});
	$("url-form").addEventListener("submit", (e) => {
		e.preventDefault();
		const url = $("url-input").value;
		history.replaceState(null, "", "?url=" + encodeURIComponent(url));
		openUrl(url);
	});

	function picked(input) {
		const files = [...input.files].map((f) => [f.webkitRelativePath || f.name, f]);
		input.value = "";
		closeMenu();
		if (files.length) addLocal(files);
	}
	for (const id of ["open-dir", "open-files", "welcome-dir", "welcome-files"]) $(id).addEventListener("change", (e) => picked(e.target));

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

	let dragDepth = 0;
	window.addEventListener("dragenter", (e) => { e.preventDefault(); dragDepth += 1; $("drop").hidden = false; });
	window.addEventListener("dragover", (e) => e.preventDefault());
	window.addEventListener("dragleave", () => { dragDepth = Math.max(0, dragDepth - 1); if (!dragDepth) $("drop").hidden = true; });
	window.addEventListener("drop", async (e) => {
		e.preventDefault();
		dragDepth = 0;
		$("drop").hidden = true;
		const out = [];
		const items = [...e.dataTransfer.items].map((item) => item.webkitGetAsEntry && item.webkitGetAsEntry()).filter(Boolean);
		if (items.length) for (const entry of items) await walk(entry, "", out);
		else for (const f of e.dataTransfer.files) out.push([f.name, f]);
		if (out.length) addLocal(out);
	});

	// ---------------------------------------------------------------- installed app

	// .pen files opened with the installed viewer (Chrome's file handlers)
	if ("launchQueue" in window) {
		window.launchQueue.setConsumer(async (params) => {
			if (!params.files || !params.files.length) return;
			const files = await Promise.all(params.files.map(async (h) => [h.name, await h.getFile()]));
			addLocal(files);
		});
	}
	// offline and instant reopening (sw.js)
	if ("serviceWorker" in navigator && window.isSecureContext) {
		navigator.serviceWorker.register(new URL("sw.js", HERE).href, { scope: new URL("./", HERE).href }).catch(() => {});
	}
})();
