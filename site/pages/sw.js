"use strict";
// The site's service worker (scope /), registered by the viewer and the share pages.
// - The viewer's files (/view/<name>.<hash>.<ext>) never change: cache first, so the
//   viewer starts at once and offline.
// - Share pages (/s/<token>) and the files of a shared version (/c/<token>/<version>/…):
//   network first, so a revoked or expired link stops at once whenever there is a
//   network; the cached copy is used only offline ("the last version you opened").
// - Files shared to the installed app (Android's share sheet, the manifest's
//   share_target) are kept for the viewer, which opens them (/view/?shared).
// - Everything else (the landing page, /dashboard, /api) is not touched.
// site/build.mjs fills in BUILD and ASSETS (the viewer's hashed files).
const BUILD = "__BUILD__";
const ASSETS = __ASSETS__;
const SHELL = "shell-" + BUILD;
const SHARED = "shared-v1"; // share pages and versions, kept across builds
const INBOX = "inbox"; // files shared to the app, until the viewer takes them

self.addEventListener("install", (event) => {
	event.waitUntil(caches.open(SHELL).then((c) => c.addAll(["/view/", ...ASSETS.map((a) => "/view/" + a)])).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
	event.waitUntil(
		caches.keys()
			.then((keys) => Promise.all(keys.filter((k) => (k.startsWith("shell-") && k !== SHELL) || k.startsWith("view-")).map((k) => caches.delete(k))))
			.then(() => self.clients.claim()),
	);
});

const hashed = /^\/view\/[^/]+\.[0-9a-f]{10}\.[a-z0-9]+$/;

async function networkFirst(req, cacheName, offline) {
	try {
		const res = await fetch(req);
		if (res.ok) (await caches.open(cacheName)).put(req, res.clone());
		return res;
	} catch (e) {
		const hit = await caches.match(req);
		return hit || offline();
	}
}

const offlinePage = () => new Response(
	'<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Offline</title>' +
	'<body style="font:15px/1.5 -apple-system,system-ui,sans-serif;background:#1e1e1e;color:#e8e8e8;display:grid;place-items:center;min-height:90vh;margin:0;padding:24px;text-align:center">' +
	"<div><h1 style=\"font-size:20px\">You are offline</h1><p>This link has not been opened on this device before. Open it again when you are online.</p></div>",
	{ status: 503, headers: { "content-type": "text/html; charset=utf-8" } },
);

self.addEventListener("fetch", (event) => {
	const req = event.request;
	const url = new URL(req.url);
	if (url.origin !== location.origin) return;
	if (req.method === "POST" && url.pathname === "/view/share-target") {
		event.respondWith((async () => {
			const form = await req.formData();
			const inbox = await caches.open(INBOX);
			for (const k of await inbox.keys()) await inbox.delete(k);
			let i = 0;
			for (const file of form.getAll("files")) {
				if (!(file instanceof File)) continue;
				await inbox.put(`/inbox/${i++}/${encodeURIComponent(file.name)}`, new Response(file));
			}
			return Response.redirect("/view/?shared", 303);
		})());
		return;
	}
	if (req.method !== "GET") return;
	if (hashed.test(url.pathname)) {
		event.respondWith(caches.match(req).then((hit) => hit || fetch(req).then((res) => {
			if (res.ok) caches.open(SHELL).then((c) => c.put(req, res.clone()));
			return res;
		})));
	} else if (req.mode === "navigate" && /^\/view\/?$/.test(url.pathname)) {
		event.respondWith(networkFirst(new Request("/view/"), SHELL, () => caches.match("/view/")).then((r) => r || offlinePage()));
	} else if (req.mode === "navigate" && url.pathname.startsWith("/s/")) {
		event.respondWith(networkFirst(req, SHARED, offlinePage));
	} else if (url.pathname.startsWith("/c/")) {
		event.respondWith(networkFirst(req, SHARED, () => new Response("offline", { status: 503 })));
	}
});
