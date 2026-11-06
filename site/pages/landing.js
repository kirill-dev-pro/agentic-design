"use strict";
// The landing page: the mode switch, the agents scene, and (as in main.js) the return after
// a sign-in and the download button pointing at the latest release's dmg.
	// Mode switch: the chosen pill lights its card.
	const cards = document.querySelector('.mode-cards');
	const pills = document.querySelectorAll('.pill');
	const pick = mode => {
		cards.dataset.active = mode;
		pills.forEach(p => p.setAttribute('aria-selected', String(p.dataset.mode === mode)));
	};
	pills.forEach(p => p.addEventListener('click', () => pick(p.dataset.mode)));
	document.querySelectorAll('.mode-card').forEach(c => c.addEventListener('mouseenter', () => pick(c.dataset.mode)));
	// Agents on the canvas: two cursors move to layers and edit them, in a loop.
	(() => {
		const art = document.querySelector('.agents-art');
		const stage = art.querySelector('.stage');
		const fit = () => stage.style.transform = `scale(${art.clientWidth / 560})`;
		new ResizeObserver(fit).observe(art); fit();

		const $ = s => stage.querySelector(s);
		const el = t => $(`[data-t="${t}"]`);
		const cur = { claude: $('[data-agent="claude"]'), codex: $('[data-agent="codex"]') };
		const home = { claude: [470, 360], codex: [60, 60] };
		const wait = ms => new Promise(r => setTimeout(r, ms));
		const still = matchMedia('(prefers-reduced-motion: reduce)').matches;

		const place = (a, x, y) => cur[a].style.transform = `translate(${x}px, ${y}px)`;
		// Point the cursor at a spot of a layer: fx, fy are fractions of its box.
		const go = async (a, t, fx = .92, fy = .8) => {
			const n = el(t), r = n.getBoundingClientRect(), sr = stage.getBoundingClientRect(), k = sr.width / 560;
			place(a, (r.left - sr.left + r.width * fx) / k, (r.top - sr.top + r.height * fy) / k);
			await wait(900);
		};
		const mark = (a, t, on = true) => el(t).classList.toggle('by-' + a, on);
		const flash = (a, t) => { const n = el(t); n.classList.remove('flash-' + a); void n.offsetWidth; n.classList.add('flash-' + a); };
		const type = async (node, text) => { for (const ch of text) { node.textContent += ch; await wait(55); } };
		const retitle = async text => {
			const s = el('title').firstElementChild;
			while (s.textContent) { s.textContent = s.textContent.slice(0, -1); await wait(28); }
			await type(s, text);
		};
		const reset = () => {
			el('title').firstElementChild.textContent = 'Welcome back';
			el('email').classList.remove('filled'); el('email').querySelector('.val').textContent = '';
			el('button').classList.remove('styled'); el('google').classList.remove('shown', 'placeholder');
		};

		place('claude', ...home.claude); place('codex', ...home.codex);
		if (still) return;

		const claude = async () => {
			await wait(400);
			await go('claude', 'button', .9, .75); mark('claude', 'button');
			await wait(250); el('button').classList.add('styled'); flash('claude', 'button');
			await wait(900); mark('claude', 'button', false);
			// Create a new layer below the button: it glows as a placeholder first.
			el('google').classList.add('shown', 'placeholder');
			await go('claude', 'google', .9, .75); mark('claude', 'google');
			await wait(1100); el('google').classList.remove('placeholder'); flash('claude', 'google');
			await wait(900); mark('claude', 'google', false);
			place('claude', ...home.claude); await wait(1200);
		};
		const codex = async () => {
			await wait(1100);
			await go('codex', 'title', .95, .7); mark('codex', 'title');
			await retitle('Sign in to Studio'); flash('codex', 'title');
			await wait(600); mark('codex', 'title', false);
			await go('codex', 'email', .85, .75); mark('codex', 'email');
			el('email').classList.add('filled'); await type(el('email').querySelector('.val'), 'ada@studio.dev'); flash('codex', 'email');
			await wait(700); mark('codex', 'email', false);
			place('codex', ...home.codex); await wait(1600);
		};
		(async function loop() {
			for (;;) { await Promise.all([claude(), codex()]); await wait(1200); const card = $('.lcard'); card.classList.add('fade'); await wait(400); reset(); card.classList.remove('fade'); await wait(900); }
		})();
	})();

(function () {
	// Back from Google or GitHub on the home page rather than where the sign-in was meant to
	// lead (app.js noted it just before leaving): when there is a session, go there.
	try {
		var wanted = JSON.parse(sessionStorage.getItem("ad-next") || "null");
		if (wanted) {
			sessionStorage.removeItem("ad-next");
			if (location.pathname === "/" && Date.now() - wanted.t < 10 * 60 * 1000 && typeof wanted.to === "string" && wanted.to.charAt(0) === "/" && wanted.to.charAt(1) !== "/" && wanted.to.charAt(1) !== "\\") {
				fetch("/api/me", { credentials: "same-origin" }).then(function (r) { if (r.ok) location.replace(wanted.to); });
			}
		}
	} catch (e) {}

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
