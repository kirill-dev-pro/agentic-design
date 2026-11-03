"use strict";
// Replaced by the site's service worker (/sw.js, scope /). A browser that registered this
// one (scope /view/) removes it, so /sw.js controls the viewer too.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => {
	event.waitUntil(self.registration.unregister().then(() => self.clients.matchAll()).then((all) => all.forEach((c) => c.navigate(c.url))));
});
