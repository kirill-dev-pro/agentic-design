"use strict";
// The pages in the landing's style (/, /cloud, /download): Sign in, or Dashboard once signed in.
(() => {
	fetch("/api/me", { credentials: "same-origin", headers: { accept: "application/json" } })
		.then((r) => (r.ok ? r.json() : null))
		.catch(() => null)
		.then((me) => {
			for (const el of document.querySelectorAll("[data-signed-in]")) el.hidden = !me;
			for (const el of document.querySelectorAll("[data-signed-out]")) el.hidden = !!me;
		});
})();
