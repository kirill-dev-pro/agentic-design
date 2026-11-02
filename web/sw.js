"use strict";
// The viewer's service worker (scope /view/): the page and its files work offline and
// open at once on the next visit. Names with a content hash never change, so they are
// served from the cache; the page itself is fetched first and taken from the cache only
// when the network is not there. Files the user opens are not touched: dropped ones never
// reach the network, URLs on other servers are not intercepted. site/build.mjs fills in
// BUILD and ASSETS.
const BUILD = "__BUILD__";
const ASSETS = __ASSETS__;
const CACHE = "view-" + BUILD;

self.addEventListener("install", (event) => {
	event.waitUntil(caches.open(CACHE).then((c) => c.addAll(["./", ...ASSETS])).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
	event.waitUntil(
		caches.keys()
			.then((keys) => Promise.all(keys.filter((k) => k.startsWith("view-") && k !== CACHE).map((k) => caches.delete(k))))
			.then(() => self.clients.claim()),
	);
});

const hashed = /\.[0-9a-f]{10}\.[a-z0-9]+$/;

self.addEventListener("fetch", (event) => {
	const req = event.request;
	if (req.method !== "GET") return;
	const url = new URL(req.url);
	if (url.origin !== location.origin) return;
	if (hashed.test(url.pathname)) {
		event.respondWith(caches.match(req).then((hit) => hit || fetch(req).then((res) => {
			if (res.ok) caches.open(CACHE).then((c) => c.put(req, res.clone()));
			return res;
		})));
	} else if (req.mode === "navigate" && url.pathname.startsWith("/view")) {
		event.respondWith(fetch(req).then((res) => {
			if (res.ok) caches.open(CACHE).then((c) => c.put("./", res.clone()));
			return res;
		}).catch(() => caches.match("./")));
	}
});
