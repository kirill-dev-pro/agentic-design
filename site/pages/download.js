"use strict";
// The download page: one tab per system, the visitor's chosen first (or the one the address
// names: /download#linux), and each button pointed at its file in the newest release that has
// one, straight from GitHub. Without the API (offline, rate-limited) the buttons open the
// releases page.
(() => {
	const REPO = "kirill-dev-pro/agentic-design";
	// each system's file, by name (tools/release/build.sh and desktop.sh name them)
	const FILES = {
		mac: { re: /-arm64\.dmg$/, label: "Download .dmg" },
		"mac-zip": { re: /-arm64\.zip$/, label: ".zip" },
		windows: { re: /-windows-x86_64\.zip$/, label: "Download .zip" },
		linux: { re: /-linux-x86_64\.tar\.gz$/, label: "Download .tar.gz" },
	};
	const NAMES = { mac: "macOS", windows: "Windows", linux: "Linux" };
	const tabs = [...document.querySelectorAll(".dl-tab")];
	const panels = [...document.querySelectorAll(".dl-panel")];

	const detect = () => {
		const p = ((navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || navigator.userAgent || "").toLowerCase();
		if (/win/.test(p)) return "windows";
		if (/linux|x11|cros/.test(p) && !/android/.test(navigator.userAgent.toLowerCase())) return "linux";
		if (/mac/.test(p)) return "mac";
		return null;
	};

	const select = (os, focus) => {
		for (const t of tabs) {
			const on = t.dataset.os === os;
			t.setAttribute("aria-selected", on);
			t.tabIndex = on ? 0 : -1;
			if (on && focus) t.focus();
		}
		for (const p of panels) p.hidden = p.dataset.os !== os;
	};

	const yours = detect();
	if (yours) document.querySelector(`.dl-tab[data-os="${yours}"] [data-yours]`).hidden = false;
	const fromHash = location.hash.slice(1);
	select(NAMES[fromHash] ? fromHash : yours || "mac");

	for (const t of tabs) {
		t.addEventListener("click", () => {
			select(t.dataset.os);
			history.replaceState(null, "", "#" + t.dataset.os);
		});
		// arrows move between tabs (the WAI-ARIA tabs pattern)
		t.addEventListener("keydown", (e) => {
			const i = tabs.indexOf(t);
			const to = e.key === "ArrowRight" ? i + 1 : e.key === "ArrowLeft" ? i - 1 : e.key === "Home" ? 0 : e.key === "End" ? tabs.length - 1 : null;
			if (to === null) return;
			e.preventDefault();
			const next = tabs[(to + tabs.length) % tabs.length];
			select(next.dataset.os, true);
			history.replaceState(null, "", "#" + next.dataset.os);
		});
	}

	const mb = (n) => (n / 1048576).toFixed(1) + " MB";
	const day = (s) => new Date(s).toLocaleDateString("en", { year: "numeric", month: "short", day: "numeric" });

	fetch(`https://api.github.com/repos/${REPO}/releases?per_page=20`, { headers: { Accept: "application/vnd.github+json" } })
		.then((r) => (r.ok ? r.json() : null))
		.then((releases) => {
			if (!Array.isArray(releases)) return;
			const stable = releases.filter((r) => !r.draft && !r.prerelease);
			const latest = stable[0];
			for (const [key, file] of Object.entries(FILES)) {
				// the newest release that has this system's file
				let asset = null, release = null;
				for (const r of stable) {
					asset = (r.assets || []).find((a) => file.re.test(a.name));
					if (asset) { release = r; break; }
				}
				const link = document.querySelector(`[data-get="${key}"]`);
				if (!link) continue;
				const panel = link.closest(".dl-panel");
				if (!asset) {
					if (key === "mac-zip") { link.hidden = true; continue; }
					const soon = panel.querySelector("[data-soon]");
					soon.querySelector("span").textContent = `The first ${NAMES[key]} build comes with the next release${latest ? ` (the latest, ${latest.tag_name}, is for macOS)` : ""}.`;
					soon.hidden = false;
					link.querySelector("[data-label]").textContent = "See all releases";
					link.href = `https://github.com/${REPO}/releases`;
					panel.querySelector("[data-meta]").hidden = true;
					continue;
				}
				link.href = asset.browser_download_url;
				link.title = `${asset.name}, ${mb(asset.size)}`;
				const meta = panel.querySelector(`[data-meta="${key}"]`);
				if (meta) {
					const version = release.tag_name.replace(/^v/, "");
					meta.textContent = `Version ${version} · ${mb(asset.size)} · ${day(release.published_at)}` + (release !== latest ? ` · the newest build for ${NAMES[key]}` : "");
				}
			}
		})
		.catch(() => {});
})();
