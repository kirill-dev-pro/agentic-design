"use strict";
// The hero's flow of light: placed between Download and the app window, with motes rising
// from the window's whole width into the stream.
(() => {
	const hero = document.querySelector('.hero-in');
	const flow = hero && hero.querySelector('.flow');
	const btn = hero && hero.querySelector('.btn-glow');
	const win = hero && hero.querySelector('.window');
	if (!flow || !btn || !win) return;
	const NS = 'http://www.w3.org/2000/svg';
	const svgs = [...flow.querySelectorAll('svg.fx')];
	// The flare: a column that widens near the bottom with concave sides into the whole
	// width of the window's edge (a trumpet). k is where the widening starts, s how far
	// the sides reach out sideways at the bottom (W = all the way).
	const flare = (W, H, cx, k, half, s) => {
		const y0 = H * k, l = cx - half, r = cx + half;
		return `M${l} 0 L${l} ${y0} C${l} ${H * .93} ${cx - (cx * .18)} ${H} ${cx - cx * s} ${H} L${cx + (W - cx) * s} ${H} C${cx + (W - cx) * .18} ${H} ${r} ${H * .93} ${r} ${y0} L${r} 0 Z`;
	};
	const paint = (svg, W, H, cx, layers) => {
		svg.setAttribute('width', W); svg.setAttribute('height', H);
		svg.setAttribute('viewBox', `0 0 ${W} ${H}`);
		svg.innerHTML = layers.map(([d, fill]) => `<path d="${d}" fill="${fill}"/>`).join('');
	};
	const layout = () => {
		const h = hero.getBoundingClientRect(), b = btn.getBoundingClientRect(), w = win.getBoundingClientRect();
		const W = w.width, H = Math.max(0, w.top - b.bottom), cx = b.left + b.width / 2 - w.left;
		const set = (k, v) => hero.style.setProperty(k, v + 'px');
		set('--fl', w.left - h.left); set('--ft', b.bottom - h.top);
		set('--fw', W); set('--fh', H); set('--cx', cx);
		const g = (id, stops) => `<radialGradient id="${id}" gradientUnits="userSpaceOnUse" cx="${cx}" cy="${H}" r="${Math.max(cx, W - cx)}" gradientTransform="translate(${cx} ${H}) scale(1 ${Math.max(.3, H / Math.max(cx, W - cx) * 1.6)}) translate(${-cx} ${-H})">${stops}</radialGradient>`;
		const defs = (s) => `<defs>${s}</defs>`;
		paint(svgs[0], W, H, cx, [[flare(W, H, cx, .1, 34, 1), 'url(#gh)']]);
		svgs[0].innerHTML = defs(g('gh', '<stop offset="0" stop-color="#FFC2A6"/><stop offset=".3" stop-color="#E8876A" stop-opacity=".75"/><stop offset=".75" stop-color="#C8643F" stop-opacity=".3"/><stop offset="1" stop-color="#C8643F" stop-opacity=".05"/>')) + svgs[0].innerHTML;
		paint(svgs[1], W, H, cx, [[flare(W, H, cx, .35, 18, 1), 'url(#gt)']]);
		svgs[1].innerHTML = defs(g('gt', '<stop offset=".1" stop-color="#8592FF" stop-opacity="0"/><stop offset=".4" stop-color="#8592FF" stop-opacity=".7"/><stop offset=".8" stop-color="#5B6CF0" stop-opacity=".25"/><stop offset="1" stop-color="#5B6CF0" stop-opacity="0"/>')) + svgs[1].innerHTML;
		paint(svgs[2], W, H, cx, [[flare(W, H, cx, .42, 7, 1), 'url(#gf)']]);
		svgs[2].innerHTML = defs(g('gf', '<stop offset="0" stop-color="#FFFFFF"/><stop offset=".3" stop-color="#FFD3BF" stop-opacity=".95"/><stop offset=".7" stop-color="#E8876A" stop-opacity=".5"/><stop offset="1" stop-color="#E8876A" stop-opacity=".12"/>')) + svgs[2].innerHTML;
		paint(svgs[3], W, H, cx, [[flare(W, H, cx, .6, 1.6, .9), 'url(#gs)']]);
		svgs[3].innerHTML = defs(g('gs', '<stop offset="0" stop-color="#FFFFFF"/><stop offset=".35" stop-color="#FFF1EA" stop-opacity=".9"/><stop offset=".75" stop-color="#FFB48F" stop-opacity=".35"/><stop offset="1" stop-color="#FFB48F" stop-opacity="0"/>')) + svgs[3].innerHTML;
	};
	new ResizeObserver(layout).observe(hero);
	addEventListener('resize', layout);
	layout();
	if (matchMedia('(prefers-reduced-motion: reduce)').matches) return;
	const dust = flow.querySelector('.flow-dust');
	const colors = ['#FFD3BF', '#FFB48F', '#FFF1EA', '#E8876A'];
	const cxFrac = () => parseFloat(hero.style.getPropertyValue('--cx')) / parseFloat(hero.style.getPropertyValue('--fw')) || .5;
	for (let i = 0; i < 28; i++) {
		const m = document.createElement('i');
		m.className = 'mote';
		const d = 2.6 + Math.random() * 2.6;
		m.style.cssText = `--r:${(Math.max(0, Math.min(1, (b0 => b0 + (Math.random() - .5) * .5 * Math.random())(cxFrac())))).toFixed(3)};--d:${d.toFixed(2)}s;--del:${(-Math.random() * d).toFixed(2)}s;--s:${(1.5 + Math.random() * 2).toFixed(1)}px;--o:${(.45 + Math.random() * .55).toFixed(2)};--c:${colors[i % colors.length]}`;
		m.appendChild(document.createElement('b'));
		dust.appendChild(m);
	}
})();
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
