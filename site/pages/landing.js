"use strict";
// The hero's flow of light: it pours out of Download, widens into the whole width of the app
// window and becomes the screenshot. Threads of light run down the stream's curves.
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
	// the screenshot fills in from its top edge, as if poured
	win.classList.add('pour');
	setTimeout(() => win.classList.add('poured'), 350);
	// Threads: each follows its own curve, down the column and then out along the flare to
	// a point of the window's edge (offset-path, turned along the path).
	const dust = flow.querySelector('.flow-dust');
	const colors = ['#FFF1EA', '#FFD3BF', '#FFB48F', '#FFFFFF', '#E8876A', '#B9C1FF'];
	const threads = [];
	for (let i = 0; i < 56; i++) {
		const t = document.createElement('i');
		t.className = 'thread';
		const d = 1.5 + Math.random() * 1.9;
		t.style.cssText = `--d:${d.toFixed(2)}s;--del:${(-Math.random() * d).toFixed(2)}s;--len:${Math.round(40 + Math.random() * 110)}px;--w:${(1.2 + Math.random() * 1.4).toFixed(1)}px;--o:${(.65 + Math.random() * .35).toFixed(2)};--c:${colors[i % colors.length]}`;
		// where it leaves the column, how far off the axis it runs, where it lands (0..1)
		threads.push({ el: t, k: .25 + Math.random() * .5, j: (Math.random() - .5) * 6, to: Math.random() });
		dust.appendChild(t);
	}
	const route = () => {
		const W = parseFloat(hero.style.getPropertyValue('--fw')), H = parseFloat(hero.style.getPropertyValue('--fh')), cx = parseFloat(hero.style.getPropertyValue('--cx'));
		if (!W || !H) return;
		for (const t of threads) {
			// landing points crowd near the column and thin out towards the window's ends
			const u = t.to * 2 - 1, tx = cx + (u < 0 ? cx : W - cx) * Math.sign(u) * Math.pow(Math.abs(u), 1.6) * 1.02;
			const x0 = cx + t.j, y0 = H * t.k;
			t.el.style.offsetPath = `path("M${x0} -4 L${x0} ${y0} C${x0} ${H * .96} ${x0 + (tx - x0) * .2} ${H} ${tx} ${H + 2}")`;
		}
	};
	new ResizeObserver(route).observe(hero);
	route();
})();
