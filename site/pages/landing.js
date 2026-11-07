"use strict";
// Animations run only while their section is on screen.
(() => {
	const io = new IntersectionObserver((es) => es.forEach((e) => e.target.classList.toggle('offscreen', !e.isIntersecting)), { rootMargin: '100px' });
	document.querySelectorAll('.hero, .modes, #agents, #download').forEach((s) => io.observe(s));
})();
// The mode switch's beams, in the hero's language: streamlines that come in as a wide fan
// from far off, gather into a narrow bright stream and run into the pill, light travelling
// along them towards it. Both are drawn with the pill at the right end; the right beam is
// mirrored in CSS.
(() => {
	const beams = [...document.querySelectorAll('.mbeam')];
	if (!beams.length) return;
	const still = matchMedia('(prefers-reduced-motion: reduce)').matches;
	const palettes = { l: ['#F0F2FF', '#B9C1FF', '#8592FF'], r: ['#FFF1EA', '#FFC2A6', '#E8876A'] };
	const N = 12;
	const draw = (beam) => {
		const side = beam.classList.contains('mbeam-l') ? 'l' : 'r';
		const W = beam.clientWidth, H = beam.clientHeight, mid = H / 2;
		if (!W) return;
		const pal = palettes[side], id = 'mb' + side;
		let mv = '';
		if (!beam._lines) beam._lines = [-1, 1].flatMap((s) => Array.from({ length: N }, (_, i) => ({ s, t: i / (N - 1), d: 1.4 + Math.random() * 1.6, del: -Math.random() * 4, len: 8 + Math.random() * 14, o: .4 + Math.random() * .5, j: Math.random() })));
		let h = `<svg class="mstreams" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}"><defs>
			<filter id="${id}s1" x="-5%" y="-20%" width="110%" height="140%"><feGaussianBlur stdDeviation=".7"/></filter>
			<filter id="${id}s2" x="-5%" y="-20%" width="110%" height="140%"><feGaussianBlur stdDeviation="1.4"/></filter>
			<radialGradient id="${id}g" gradientUnits="userSpaceOnUse" cx="${W}" cy="${mid}" r="${W}" gradientTransform="translate(${W} ${mid}) scale(1 ${(H * .9 / W).toFixed(3)}) translate(${-W} ${-mid})"><stop offset="0" stop-color="#fff"/><stop offset=".4" stop-color="#fff" stop-opacity=".85"/><stop offset=".8" stop-color="#fff" stop-opacity=".25"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>
			<mask id="${id}m" maskUnits="userSpaceOnUse" x="0" y="0" width="${W}" height="${H}"><rect width="${W}" height="${H}" fill="url(#${id}g)"/></mask></defs><g mask="url(#${id}m)">`;
		for (const l of beam._lines) {
			const s = l.s, t = l.t;
			const c = mid + s * (1 + t * 7 + l.j * 1.5);               // close to the core by the pill
			const e = mid + s * (8 + t * (mid - 12));                   // fanned out far away
			const u0 = W * (.82 - .5 * Math.pow(t, .9));                // where it starts to gather (outer ones earlier)
			const x = (u) => (W - u).toFixed(1);                        // u: distance from the pill
			const d = `M${x(0)} ${c.toFixed(1)} L${x(W - u0)} ${c.toFixed(1)} C${x((W - u0) + u0 * .45)} ${c.toFixed(1)} ${x((W - u0) + u0 * .55)} ${e.toFixed(1)} ${x(W)} ${e.toFixed(1)}`;
			const col = t < .35 ? pal[0] : t < .7 ? pal[1] : pal[2];
			const f = t > .66 ? ` filter="url(#${id}s2)"` : t > .33 ? ` filter="url(#${id}s1)"` : '';
			h += `<path class="st" d="${d}" stroke="${col}" stroke-opacity="${(.08 + (1 - t) * .22).toFixed(2)}"${f}/>`;
			if (!still) mv += `<path class="tw in" d="${d}" pathLength="100" stroke="${col}" stroke-width="${(1.4 + t).toFixed(1)}" stroke-dasharray="${l.len.toFixed(1)} 100" style="--L:${l.len.toFixed(1)};--d:${l.d.toFixed(2)}s;--del:${l.del.toFixed(2)}s;--o:${(l.o * (1 - t * .55)).toFixed(2)}"/>`;
		}
		for (let k = 0; k < 12; k++) {
			const u = Math.random() * W * .8, y = mid + (Math.random() < .5 ? -1 : 1) * (2 + Math.pow(Math.random(), 1.6) * 14);
			mv += `<circle class="sp" cx="${(W - u).toFixed(1)}" cy="${y.toFixed(1)}" r="${(.4 + Math.random() * .8).toFixed(2)}" fill="${pal[0]}" style="--d:${(1.2 + Math.random() * 2.4).toFixed(2)}s;--del:${(-Math.random() * 3).toFixed(2)}s"/>`;
		}
		beam.innerHTML = h + `</g></svg><svg class="mstreams moving" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">${mv}</svg><i class="mcore"></i>`;
	};
	const ro = new ResizeObserver((es) => es.forEach((e) => draw(e.target)));
	beams.forEach((b) => ro.observe(b));
})();
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
	// Threads, as streamlines: thin curves nested inside each other on both sides of the
	// column. Each runs down beside it, bends and lies along the window's edge; a bright
	// stroke travels along it, so the light itself bends (stroke-dashoffset on the curve).
	const dust = flow.querySelector('.flow-dust');
	const N = 18, lines = [];
	for (const side of [-1, 1]) for (let i = 0; i < N; i++) {
		const t = i / (N - 1);
		lines.push({ side, t, d: 1.6 + Math.random() * 1.6 + t * 1.2, del: -Math.random() * 4, len: 8 + Math.random() * 14, o: .35 + Math.random() * .5, jitter: Math.random() });
	}
	const sparks = Array.from({ length: 22 }, () => ({ side: Math.random() < .5 ? -1 : 1, off: 2 + Math.pow(Math.random(), 1.8) * 26, y: Math.random(), r: .4 + Math.random() * .9, d: 1.2 + Math.random() * 2.4, del: -Math.random() * 3 }));
	const route = () => {
		const W = parseFloat(hero.style.getPropertyValue('--fw')), H = parseFloat(hero.style.getPropertyValue('--fh')), cx = parseFloat(hero.style.getPropertyValue('--cx'));
		if (!W || !H) return;
		const curve = (l) => {
			const s = l.side, t = l.t;
			const x0 = cx + s * (3 + t * 22 + l.jitter * 2);             // beside the column, outer ones further out
			const y0 = H * (.86 - .62 * Math.pow(t, .9));                  // outer ones bend earlier, wider
			const yE = H - .5 - t * 3;                                     // and lie a little above the edge
			const reach = (s < 0 ? cx : W - cx) * (.3 + .72 * Math.pow(t, .75));
			const xE = cx + s * reach;
			return `M${x0.toFixed(1)} -2 L${x0.toFixed(1)} ${y0.toFixed(1)} C${x0.toFixed(1)} ${yE.toFixed(1)} ${(x0 + s * (yE - y0) * .9).toFixed(1)} ${yE.toFixed(1)} ${xE.toFixed(1)} ${yE.toFixed(1)}`;
		};
		const R = Math.max(cx, W - cx) * 1.02;
		let moving = '';
		const color = (t) => t < .35 ? '#FFF1EA' : t < .7 ? '#FFC2A6' : '#B9A8FF';
		let html = `<svg class="streams" width="${W}" height="${H + 6}" viewBox="0 0 ${W} ${H + 6}" overflow="visible"><defs>
			<linearGradient id="fade" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="0" y2="${H}"><stop offset="0" stop-color="#fff" stop-opacity="0"/><stop offset=".45" stop-color="#fff" stop-opacity=".5"/><stop offset="1" stop-color="#fff"/></linearGradient>
			<filter id="soft1" x="-5%" y="-5%" width="110%" height="110%"><feGaussianBlur stdDeviation=".7"/></filter><filter id="soft2" x="-5%" y="-5%" width="110%" height="110%"><feGaussianBlur stdDeviation="1.4"/></filter>
			<mask id="fadeMask" maskUnits="userSpaceOnUse" x="0" y="-10" width="${W}" height="${H + 20}"><rect x="0" y="-10" width="${W}" height="${H + 20}" fill="url(#fade)"/></mask>
			<radialGradient id="side" gradientUnits="userSpaceOnUse" cx="${cx}" cy="${H}" r="${R}" gradientTransform="translate(${cx} ${H}) scale(1 ${(H * 1.6 / R).toFixed(3)}) translate(${-cx} ${-H})"><stop offset="0" stop-color="#fff"/><stop offset=".45" stop-color="#fff" stop-opacity=".85"/><stop offset=".8" stop-color="#fff" stop-opacity=".3"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>
			<mask id="sideMask" maskUnits="userSpaceOnUse" x="-20" y="-10" width="${W + 40}" height="${H + 20}"><rect x="-20" y="-10" width="${W + 40}" height="${H + 20}" fill="url(#side)"/></mask></defs><g mask="url(#fadeMask)"><g mask="url(#sideMask)">`;
		for (const l of lines) {
			const d = curve(l), c = color(l.t);
			// the further out, the softer and fainter
			const f = l.t > .66 ? ' filter="url(#soft2)"' : l.t > .33 ? ' filter="url(#soft1)"' : '';
			html += `<path class="st" d="${d}" stroke="${c}" stroke-opacity="${(.08 + (1 - l.t) * .22).toFixed(2)}"${f}/>`;
			// moving light: no mask or filter on it (those would be redrawn every frame);
			// it fades out on its own as it reaches the end
			moving += `<path class="tw" d="${d}" pathLength="100" stroke="${c}" style="--sw:${(1.2 + l.t * .5).toFixed(1)};--L:${l.len.toFixed(1)};--d:${l.d.toFixed(2)}s;--del:${l.del.toFixed(2)}s;--o:${(l.o * (1 - l.t * .7)).toFixed(2)}" stroke-dasharray="${l.len.toFixed(1)} 100"/>`;
		}
		for (const p of sparks) moving += `<circle class="sp" cx="${(cx + p.side * p.off).toFixed(1)}" cy="${(p.y * H * .95).toFixed(1)}" r="${p.r.toFixed(2)}" style="--d:${p.d.toFixed(2)}s;--del:${p.del.toFixed(2)}s"/>`;
		dust.innerHTML = html + '</g></g></svg>' + `<svg class="streams moving" width="${W}" height="${H + 6}" viewBox="0 0 ${W} ${H + 6}">${moving}</svg>`;
	};
	new ResizeObserver(route).observe(hero);
	route();
})();
