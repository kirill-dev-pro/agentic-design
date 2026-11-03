"use strict";
// Light or dark (the system's until the button is used), and the download button: the
// latest release's dmg, straight from GitHub (the link opens the release page without it).
(function () {
	var root = document.documentElement;
	var button = document.querySelector(".theme");
	var media = matchMedia("(prefers-color-scheme: dark)");
	function dark() { return root.dataset.theme ? root.dataset.theme === "dark" : media.matches; }
	function label() { button.setAttribute("aria-label", dark() ? "Switch to light theme" : "Switch to dark theme"); }
	button.addEventListener("click", function () {
		var next = dark() ? "light" : "dark";
		// back to following the system when the choice matches it
		if ((next === "dark") === media.matches) { delete root.dataset.theme; try { localStorage.removeItem("theme"); } catch (e) {} }
		else { root.dataset.theme = next; try { localStorage.setItem("theme", next); } catch (e) {} }
		label();
	});
	media.addEventListener("change", label);
	label();

	if (document.querySelector("[data-download]")) fetch("https://api.github.com/repos/kirill-dev-pro/agentic-design/releases/latest", { headers: { Accept: "application/vnd.github+json" } })
		.then(function (r) { return r.ok ? r.json() : null; })
		.then(function (release) {
			if (!release) return;
			var dmg = (release.assets || []).filter(function (a) { return /\.dmg$/.test(a.name); })[0];
			if (!dmg) return;
			var version = release.tag_name.replace(/^v/, "");
			var size = (dmg.size / 1048576).toFixed(1) + " MB";
			document.querySelectorAll("[data-download]").forEach(function (a) {
				a.href = dmg.browser_download_url;
				a.title = dmg.name + ", " + size;
			});
			document.querySelectorAll("[data-version]").forEach(function (s) {
				s.textContent = "Version " + version + " · " + size + " · Apple Silicon";
			});
		})
		.catch(function () {});
})();
