"use strict";
// Animations run only while their section is on screen.
(() => {
	const io = new IntersectionObserver((es) => es.forEach((e) => e.target.classList.toggle('offscreen', !e.isIntersecting)), { rootMargin: '100px' });
	document.querySelectorAll('.hero, .modes, #agents, #download').forEach((s) => io.observe(s));
})();
// Moving light is drawn on canvases by one loop at 30 frames a second, only while its canvas
// is on screen and the tab is visible: CSS animations of strokes over large areas repaint on
// every display frame (120 a second on ProMotion screens), which costs Firefox a lot.
const Flow = (() => {
	const items = new Set();
	let raf = 0, last = 0;
	const live = () => !document.hidden && [...items].some((it) => it.on);
	const tick = (now) => {
		raf = 0;
		if (!live()) return;
		if (now - last >= 32) {
			last = now;
			for (const it of items) if (it.on) it.frame(now / 1000);
		}
		raf = requestAnimationFrame(tick);
	};
	const kick = () => { if (!raf && live()) raf = requestAnimationFrame(tick); };
	document.addEventListener('visibilitychange', kick);
	const still = matchMedia('(prefers-reduced-motion: reduce)').matches;
	return {
		still,
		// a canvas of W x H css px; draw(ctx, t) paints one frame
		// one per host, kept across re-layouts (the host's innerHTML is rebuilt around it)
		canvas(host, cls) {
			if (host._flow) { host.appendChild(host._flow.c); return host._flow; }
			const c = document.createElement('canvas');
			c.className = cls;
			const it = { on: false, c, ctx: c.getContext('2d'), draw: null, frame(t) { const { ctx } = this; ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.clearRect(0, 0, c.width, c.height); ctx.setTransform(this.k, 0, 0, this.k, 0, 0); this.draw && this.draw(ctx, t); } };
			it.size = (W, H) => { it.k = Math.min(2, devicePixelRatio || 1); c.width = Math.ceil(W * it.k); c.height = Math.ceil(H * it.k); c.style.width = W + 'px'; c.style.height = H + 'px'; };
			host.appendChild(c);
			host._flow = it;
			if (!still) {
				items.add(it);
				new IntersectionObserver(([e]) => { it.on = e.isIntersecting; kick(); }).observe(c);
			}
			return it;
		},
	};
})();
// One travelling stroke along a curve: phase p in 0..1; from/to are where the dash starts in
// hundredths of the curve; a(p) its opacity.
const strokeAlong = (ctx, l, p) => {
	const a = l.alpha(p);
	if (a <= .01) return;
	const L = l.len / 100 * l.total, at = (l.from + (l.to - l.from) * p) / 100 * l.total;
	ctx.globalAlpha = a;
	ctx.strokeStyle = l.color;
	ctx.lineWidth = l.w;
	ctx.setLineDash([L, l.total * 2 + L]);
	ctx.lineDashOffset = -at;
	ctx.stroke(l.path);
};
const phase = (t, d, del) => (((t - del) / d) % 1 + 1) % 1;
const twinkle = (p) => .1 + .8 * (.5 - .5 * Math.cos(p * Math.PI * 2));
// the length of a curve, measured on a path in a hidden svg (some browsers only measure attached paths)
const lengthOf = (() => {
	let svg;
	return (d) => {
		if (!svg) { svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg'); svg.setAttribute('width', 0); svg.setAttribute('height', 0); svg.style.position = 'absolute'; document.body.appendChild(svg); }
		const e = document.createElementNS('http://www.w3.org/2000/svg', 'path');
		e.setAttribute('d', d); svg.appendChild(e);
		const n = e.getTotalLength(); e.remove();
		return n;
	};
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
	const glow = { l: '#8592FF', r: '#E8876A' };
	const N = 12;
	const draw = (beam) => {
		const side = beam.classList.contains('mbeam-l') ? 'l' : 'r';
		const W = beam.clientWidth, H = beam.clientHeight, mid = H / 2;
		if (!W) return;
		const pal = palettes[side], id = 'mb' + side;
		const mv = [];
		if (!beam._lines) beam._lines = [-1, 1].flatMap((s) => Array.from({ length: N }, (_, i) => ({ s, t: i / (N - 1), d: 1.4 + Math.random() * 1.6, del: -Math.random() * 4, len: 8 + Math.random() * 14, o: .4 + Math.random() * .5, j: Math.random() })));
		// the image reaches PAD past the pill end, under the toggle, so the glow fades out there
		// rather than stopping at the edge of the box
		const PAD = 90;
		let h = `<svg xmlns="http://www.w3.org/2000/svg" width="${W + PAD}" height="${H}" viewBox="0 0 ${W + PAD} ${H}"><defs>
			<filter id="${id}b" filterUnits="userSpaceOnUse" x="0" y="0" width="${W + PAD}" height="${H}"><feGaussianBlur stdDeviation="14"/></filter>
			<radialGradient id="${id}c" gradientUnits="userSpaceOnUse" cx="${W}" cy="${mid}" r="${W}" gradientTransform="translate(${W} ${mid}) scale(1 ${(35 / W).toFixed(4)}) translate(${-W} ${-mid})"><stop offset="0" stop-color="${glow[side]}" stop-opacity=".6"/><stop offset="1" stop-color="${glow[side]}" stop-opacity="0"/></radialGradient>
			<filter id="${id}s1" x="-5%" y="-20%" width="110%" height="140%"><feGaussianBlur stdDeviation=".7"/></filter>
			<filter id="${id}s2" x="-5%" y="-20%" width="110%" height="140%"><feGaussianBlur stdDeviation="1.4"/></filter>
			<radialGradient id="${id}g" gradientUnits="userSpaceOnUse" cx="${W}" cy="${mid}" r="${W}" gradientTransform="translate(${W} ${mid}) scale(1 ${(H * .9 / W).toFixed(3)}) translate(${-W} ${-mid})"><stop offset="0" stop-color="#fff"/><stop offset=".4" stop-color="#fff" stop-opacity=".85"/><stop offset=".8" stop-color="#fff" stop-opacity=".25"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>
			<mask id="${id}m" maskUnits="userSpaceOnUse" x="0" y="0" width="${W}" height="${H}"><rect width="${W}" height="${H}" fill="url(#${id}g)"/></mask></defs>
			<rect x="0" y="${mid - 35}" width="${W + 30}" height="70" fill="url(#${id}c)" filter="url(#${id}b)"/><g mask="url(#${id}m)">`;
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
			mv.push({ d, color: col, w: 1.4 + t, len: l.len, dur: l.d, del: l.del, o: l.o * (1 - t * .55) });
		}
		const sparks = Array.from({ length: 12 }, () => ({ x: W - Math.random() * W * .8, y: mid + (Math.random() < .5 ? -1 : 1) * (2 + Math.pow(Math.random(), 1.6) * 14), r: .4 + Math.random() * .8, dur: 1.2 + Math.random() * 2.4, del: -Math.random() * 3 }));
		// the still part (glow and streamlines, blurred and masked) as one image, rasterised once
		beam.innerHTML = `<img class="mbake" alt="" width="${W + PAD}" height="${H}" src="data:image/svg+xml;charset=utf-8,${encodeURIComponent(h + '</g></svg>')}"><i class="mcore"></i>`;
		const cv = Flow.canvas(beam, 'mstreams moving');
		cv.size(W, H);
		const lines = mv.map((m) => ({ ...m, path: new Path2D(m.d), total: lengthOf(m.d), from: 100, to: -m.len,
			alpha: (p) => m.o * (p < .35 ? p / .35 : p < .9 ? 1 : (1 - p) / .1) }));
		cv.draw = (ctx, t) => {
			ctx.lineCap = 'round';
			for (const l of lines) strokeAlong(ctx, l, phase(t, l.dur, l.del));
			ctx.setLineDash([]);
			ctx.fillStyle = pal[0];
			for (const p of sparks) { ctx.globalAlpha = twinkle(phase(t, p.dur, p.del)); ctx.beginPath(); ctx.arc(p.x, p.y, p.r, 0, 7); ctx.fill(); }
		};
		cv.frame(0);
	};
	const ro = new ResizeObserver((es) => es.forEach((e) => draw(e.target)));
	beams.forEach((b) => ro.observe(b));
})();
// The hero's flow of light: it pours out of Download, widens into the whole width of the app
// window and becomes the screenshot. Threads of light run down the stream's curves.
// Everything that stands still (the glows, the flare, the streamlines, all blurred and masked)
// is baked into one SVG image, which the browser rasterises once; only the light moving along
// the streamlines is drawn per frame, on a canvas above it with no filter or mask under its
// own layer.
(() => {
	const hero = document.querySelector('.hero-in');
	const flow = hero && hero.querySelector('.flow');
	const btn = hero && hero.querySelector('.btn-glow');
	const win = hero && hero.querySelector('.window');
	if (!flow || !btn || !win) return;
	const bake = flow.querySelector('.flow-bake');
	const dust = flow.querySelector('.flow-dust');
	const PAD = 120;
	// The flare: a column that widens near the bottom with concave sides into the whole
	// width of the window's edge (a trumpet). k is where the widening starts, s how far
	// the sides reach out sideways at the bottom (1 = all the way).
	const flare = (W, H, cx, k, half, s) => {
		const y0 = H * k, l = cx - half, r = cx + half;
		return `M${l} 0 L${l} ${y0} C${l} ${H * .93} ${cx - (cx * .18)} ${H} ${cx - cx * s} ${H} L${cx + (W - cx) * s} ${H} C${cx + (W - cx) * .18} ${H} ${r} ${H * .93} ${r} ${y0} L${r} 0 Z`;
	};
	// Threads, as streamlines: thin curves nested inside each other on both sides of the
	// column. Each runs down beside it, bends and lies along the window's edge; a bright
	// stroke travels along it, so the light itself bends.
	const N = 18, lines = [];
	for (const side of [-1, 1]) for (let i = 0; i < N; i++) {
		const t = i / (N - 1);
		lines.push({ side, t, d: 1.6 + Math.random() * 1.6 + t * 1.2, del: -Math.random() * 4, len: 8 + Math.random() * 14, o: .35 + Math.random() * .5, jitter: Math.random() });
	}
	const sparks = Array.from({ length: 22 }, () => ({ side: Math.random() < .5 ? -1 : 1, off: 2 + Math.pow(Math.random(), 1.8) * 26, y: Math.random(), r: .4 + Math.random() * .9, d: 1.2 + Math.random() * 2.4, del: -Math.random() * 3 }));
	const color = (t) => t < .35 ? '#FFF1EA' : t < .7 ? '#FFC2A6' : '#B9A8FF';
	const curve = (l, W, H, cx) => {
		const s = l.side, t = l.t;
		const x0 = cx + s * (3 + t * 22 + l.jitter * 2);             // beside the column, outer ones further out
		const y0 = H * (.86 - .62 * Math.pow(t, .9));                  // outer ones bend earlier, wider
		const yE = H - .5 - t * 3;                                     // and lie a little above the edge
		const reach = (s < 0 ? cx : W - cx) * (.3 + .72 * Math.pow(t, .75));
		const xE = cx + s * reach;
		return `M${x0.toFixed(1)} -2 L${x0.toFixed(1)} ${y0.toFixed(1)} C${x0.toFixed(1)} ${yE.toFixed(1)} ${(x0 + s * (yE - y0) * .9).toFixed(1)} ${yE.toFixed(1)} ${xE.toFixed(1)} ${yE.toFixed(1)}`;
	};
	let cv = null, lastKey = '';
	const layout = () => {
		const h = hero.getBoundingClientRect(), b = btn.getBoundingClientRect(), w = win.getBoundingClientRect();
		const W = Math.round(w.width), H = Math.round(Math.max(0, w.top - b.bottom)), cx = Math.round(b.left + b.width / 2 - w.left);
		const set = (k, v) => hero.style.setProperty(k, v + 'px');
		set('--fl', w.left - h.left); set('--ft', b.bottom - h.top);
		set('--fw', W); set('--fh', H); set('--cx', cx);
		const key = `${W} ${H} ${cx}`;
		if (!W || !H || key === lastKey) return;
		lastKey = key;
		const Rg = Math.max(cx, W - cx);
		const g = (id, stops) => `<radialGradient id="${id}" gradientUnits="userSpaceOnUse" cx="${cx}" cy="${H}" r="${Rg}" gradientTransform="translate(${cx} ${H}) scale(1 ${Math.max(.3, H / Rg * 1.6)}) translate(${-cx} ${-H})">${stops}</radialGradient>`;
		const blur = (id, sd) => `<filter id="${id}" filterUnits="userSpaceOnUse" x="${-PAD}" y="${-PAD}" width="${W + PAD * 2}" height="${H + PAD * 2}"><feGaussianBlur stdDeviation="${sd}"/></filter>`;
		const R = Rg * 1.02;
		let st = '';
		for (const l of lines) {
			const f = l.t > .66 ? ' filter="url(#s2)"' : l.t > .33 ? ' filter="url(#s1)"' : '';
			st += `<path d="${curve(l, W, H, cx)}" fill="none" stroke-width="1" stroke-linecap="round" stroke="${color(l.t)}" stroke-opacity="${(.08 + (1 - l.t) * .22).toFixed(2)}"${f}/>`;
		}
		const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${W + PAD * 2}" height="${H + PAD * 2}" viewBox="${-PAD} ${-PAD} ${W + PAD * 2} ${H + PAD * 2}"><defs>
			${blur('b30', 30)}${blur('b16', 16)}${blur('b7', 7)}${blur('b5', 5)}${blur('b06', .6)}${blur('s1', .7)}${blur('s2', 1.4)}
			${g('gh', '<stop offset="0" stop-color="#FFC2A6"/><stop offset=".3" stop-color="#E8876A" stop-opacity=".75"/><stop offset=".75" stop-color="#C8643F" stop-opacity=".3"/><stop offset="1" stop-color="#C8643F" stop-opacity=".05"/>')}
			${g('gt', '<stop offset=".1" stop-color="#8592FF" stop-opacity="0"/><stop offset=".4" stop-color="#8592FF" stop-opacity=".7"/><stop offset=".8" stop-color="#5B6CF0" stop-opacity=".25"/><stop offset="1" stop-color="#5B6CF0" stop-opacity="0"/>')}
			${g('gf', '<stop offset="0" stop-color="#FFFFFF"/><stop offset=".3" stop-color="#FFD3BF" stop-opacity=".95"/><stop offset=".7" stop-color="#E8876A" stop-opacity=".5"/><stop offset="1" stop-color="#E8876A" stop-opacity=".12"/>')}
			${g('gs', '<stop offset="0" stop-color="#FFFFFF"/><stop offset=".35" stop-color="#FFF1EA" stop-opacity=".9"/><stop offset=".75" stop-color="#FFB48F" stop-opacity=".35"/><stop offset="1" stop-color="#FFB48F" stop-opacity="0"/>')}
			<radialGradient id="gspot"><stop offset="0" stop-color="#E8876A" stop-opacity=".6"/><stop offset="1" stop-color="#E8876A" stop-opacity="0"/></radialGradient>
			<radialGradient id="gbase"><stop offset="0" stop-color="#FFFFFF"/><stop offset=".3" stop-color="#FFD3BF" stop-opacity=".8"/><stop offset=".65" stop-color="#E8876A" stop-opacity=".4"/><stop offset="1" stop-color="#E8876A" stop-opacity="0"/></radialGradient>
			<linearGradient id="fade" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="0" y2="${H}"><stop offset="0" stop-color="#fff" stop-opacity="0"/><stop offset=".45" stop-color="#fff" stop-opacity=".5"/><stop offset="1" stop-color="#fff"/></linearGradient>
			<mask id="fadeMask" maskUnits="userSpaceOnUse" x="0" y="-10" width="${W}" height="${H + 20}"><rect x="0" y="-10" width="${W}" height="${H + 20}" fill="url(#fade)"/></mask>
			<radialGradient id="side" gradientUnits="userSpaceOnUse" cx="${cx}" cy="${H}" r="${R}" gradientTransform="translate(${cx} ${H}) scale(1 ${(H * 1.6 / R).toFixed(3)}) translate(${-cx} ${-H})"><stop offset="0" stop-color="#fff"/><stop offset=".45" stop-color="#fff" stop-opacity=".85"/><stop offset=".8" stop-color="#fff" stop-opacity=".3"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>
			<mask id="sideMask" maskUnits="userSpaceOnUse" x="-20" y="-10" width="${W + 40}" height="${H + 20}"><rect x="-20" y="-10" width="${W + 40}" height="${H + 20}" fill="url(#side)"/></mask>
			<clipPath id="box"><rect x="0" y="0" width="${W}" height="${H + 6}"/></clipPath></defs>
			<ellipse cx="${cx}" cy="-15" rx="170" ry="55" fill="url(#gspot)" filter="url(#b16)"/>
			<path d="${flare(W, H, cx, .1, 34, 1)}" fill="url(#gh)" opacity=".95" filter="url(#b30)"/>
			<path d="${flare(W, H, cx, .35, 18, 1)}" fill="url(#gt)" opacity=".6" filter="url(#b16)"/>
			<path d="${flare(W, H, cx, .42, 7, 1)}" fill="url(#gf)" filter="url(#b5)"/>
			<path d="${flare(W, H, cx, .6, 1.6, .9)}" fill="url(#gs)" filter="url(#b06)"/>
			<ellipse cx="${cx}" cy="${H}" rx="${W * .45}" ry="18" fill="url(#gbase)" filter="url(#b7)"/>
			<g clip-path="url(#box)"><g mask="url(#fadeMask)"><g mask="url(#sideMask)">${st}</g></g></g></svg>`;
		bake.style.left = bake.style.top = -PAD + 'px';
		bake.width = W + PAD * 2; bake.height = H + PAD * 2;
		bake.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
		if (cv) route(W, H, cx);
	};
	const route = (W, H, cx) => {
		cv = Flow.canvas(dust, 'streams moving');
		cv.size(W, H + 6);
		// light runs down from the button, shows up a little way down and fades out at the end
		const ls = lines.map((l) => {
			const d = curve(l, W, H, cx);
			return { d, color: color(l.t), w: 1.2 + l.t * .5, len: l.len, dur: l.d, del: l.del, o: l.o * (1 - l.t * .7),
				path: new Path2D(d), total: lengthOf(d), from: -l.len, to: 100 };
		});
		ls.forEach((l) => { l.alpha = (p) => l.o * (p < .22 ? 0 : p < .42 ? (p - .22) / .2 : p < .72 ? 1 : (1 - p) / .28); });
		const sp = sparks.map((p) => ({ ...p, x: cx + p.side * p.off, cy: p.y * H * .95 }));
		cv.draw = (ctx, t) => {
			ctx.lineCap = 'round';
			for (const l of ls) strokeAlong(ctx, l, phase(t, l.dur, l.del));
			ctx.setLineDash([]);
			ctx.fillStyle = '#FFF1EA';
			for (const p of sp) { ctx.globalAlpha = twinkle(phase(t, p.d, p.del)); ctx.beginPath(); ctx.arc(p.x, p.cy, p.r, 0, 7); ctx.fill(); }
		};
		cv.frame(0);
	};
	new ResizeObserver(layout).observe(hero);
	addEventListener('resize', layout);
	layout();
	if (Flow.still) return;
	// the screenshot fills in from its top edge, as if poured
	win.classList.add('pour');
	setTimeout(() => win.classList.add('poured'), 350);
	const W = parseFloat(hero.style.getPropertyValue('--fw')), H = parseFloat(hero.style.getPropertyValue('--fh')), cx = parseFloat(hero.style.getPropertyValue('--cx'));
	if (W && H) route(W, H, cx);
	else cv = true;   // laid out later: layout() routes then
})();

// The mode switch, the agents scene, and (as in main.js) the return after a sign-in and the
// download button pointing at the latest release's dmg.
(() => {
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
