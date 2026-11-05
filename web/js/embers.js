/*
 * Hero particles. Embers rise from the Flame of Eld by default; once the visitor pledges to a realm
 * the air changes with it: snow for Vardheim, golden motes for Solmarch, ash and sparks for Askarra.
 * Exposes Eldmark.embers.burst(x, y, opts) for the crown and the banners (page coordinates).
 */
(function () {
	'use strict';

	const canvas = document.getElementById('embers');
	if (!canvas || !window.Eldmark) return;
	const hero = canvas.closest('.hero');
	const reduced = Eldmark.reducedMotion;

	let ctx = null;
	let W = 0;
	let H = 0;
	let running = false;
	let raf = 0;
	let last = 0;
	let time = 0;
	let mode = modeFor(Eldmark.realm);
	let boost = 0; /* seconds of extra emission (rekindling) */
	const parts = [];
	const pointer = { x: -9999, y: -9999 };

	/* Pre-rendered glow sprites, one per color, drawn scaled: far cheaper than gradients per particle */
	const sprites = {};
	function sprite(color) {
		if (sprites[color]) return sprites[color];
		const s = document.createElement('canvas');
		s.width = s.height = 64;
		const g = s.getContext('2d');
		const grad = g.createRadialGradient(32, 32, 0, 32, 32, 32);
		grad.addColorStop(0, 'rgba(255,255,255,1)');
		grad.addColorStop(0.18, color);
		grad.addColorStop(0.45, color.replace(/[\d.]+\)$/, '0.35)'));
		grad.addColorStop(1, color.replace(/[\d.]+\)$/, '0)'));
		g.fillStyle = grad;
		g.fillRect(0, 0, 64, 64);
		sprites[color] = s;
		return s;
	}

	const EMBER_COLORS = ['rgba(255,170,80,1)', 'rgba(255,128,48,1)', 'rgba(255,200,110,1)', 'rgba(240,90,30,1)'];
	const GOLD_COLORS = ['rgba(255,226,140,1)', 'rgba(236,201,79,1)', 'rgba(255,246,200,1)'];
	const SNOW_COLOR = 'rgba(225,242,255,1)';
	const ASH_COLOR = '#8c8276';

	function modeFor(realm) {
		if (realm === 'vardheim') return 'snow';
		if (realm === 'solmarch') return 'motes';
		if (realm === 'askarra') return 'ash';
		return 'embers';
	}

	function rand(a, b) { return a + Math.random() * (b - a); }
	function pick(list) { return list[Math.floor(Math.random() * list.length)]; }

	function capacity() {
		const base = W < 700 ? 70 : 150;
		return Math.round((reduced ? 0.35 : 1) * base);
	}

	function spawn(initial, kindOverride) {
		const kind = kindOverride || kindForMode();
		const p = { kind, age: 0, phase: rand(0, Math.PI * 2), spin: rand(-2, 2), rot: rand(0, Math.PI) };
		switch (kind) {
		case 'snow':
			p.x = rand(-40, W + 40);
			p.y = initial ? rand(-20, H) : rand(-40, -10);
			p.vx = rand(-12, 6);
			p.vy = rand(18, 48);
			p.size = rand(1, 3.4);
			p.life = 40;
			p.color = SNOW_COLOR;
			p.alpha = rand(0.45, 0.95);
			break;
		case 'mote':
			p.x = rand(0, W);
			p.y = initial ? rand(0, H) : H + rand(0, 30);
			p.vx = rand(-6, 6);
			p.vy = -rand(6, 20);
			p.size = rand(1.4, 3.6);
			p.life = rand(7, 14);
			p.color = pick(GOLD_COLORS);
			p.alpha = rand(0.4, 0.9);
			break;
		case 'ash':
			p.x = rand(-40, W + 40);
			p.y = initial ? rand(-20, H) : rand(-40, -10);
			p.vx = rand(4, 22);
			p.vy = rand(14, 34);
			p.size = rand(1.6, 4.2);
			p.life = 40;
			p.color = ASH_COLOR;
			p.alpha = rand(0.35, 0.75);
			break;
		default: /* ember */
			p.x = rand(0, W);
			p.y = initial ? rand(H * 0.2, H) : H + rand(0, 20);
			p.vx = rand(-10, 10);
			p.vy = -rand(24, 70);
			p.size = rand(0.8, 2.6);
			p.life = rand(4, 9);
			p.color = pick(EMBER_COLORS);
			p.alpha = 1;
		}
		parts.push(p);
		return p;
	}

	function kindForMode() {
		if (boost > 0) return Math.random() < 0.7 ? 'mote' : 'ember';
		switch (mode) {
		case 'snow': return 'snow';
		case 'motes': return Math.random() < 0.85 ? 'mote' : 'ember';
		case 'ash': return Math.random() < 0.55 ? 'ash' : 'ember';
		default: return 'ember';
		}
	}

	/* A burst of sparks at page coordinates (pageX/pageY are converted to canvas space). */
	function burst(pageX, pageY, opts) {
		if (!ctx) resize();
		const o = opts || {};
		const rect = canvas.getBoundingClientRect();
		const x = pageX - rect.left;
		const y = pageY - rect.top;
		const count = Math.round((o.count || 60) * (reduced ? 0.3 : 1));
		const colors = o.colors || EMBER_COLORS;
		for (let i = 0; i < count; i++) {
			const a = rand(0, Math.PI * 2);
			const speed = rand(40, o.speed || 260);
			parts.push({
				kind: 'spark', x, y,
				vx: Math.cos(a) * speed, vy: Math.sin(a) * speed - 40,
				size: rand(1, 2.8), life: rand(0.7, 1.8), age: 0,
				color: pick(colors), alpha: 1, phase: rand(0, 6), spin: 0, rot: 0,
			});
		}
		if (!running) start();
	}

	function update(dt) {
		time += dt;
		if (boost > 0) boost -= dt;
		const cap = capacity() * (boost > 0 ? 2.2 : 1);
		let ambient = 0;
		for (const p of parts) if (p.kind !== 'spark') ambient++;
		/* Keep a steady population, spawning gradually */
		let need = Math.min(cap - ambient, Math.ceil(cap * dt * 0.6) + 1);
		while (need-- > 0) spawn(false);

		for (let i = parts.length - 1; i >= 0; i--) {
			const p = parts[i];
			p.age += dt;
			const wobble = Math.sin(time * 1.3 + p.phase);
			if (p.kind === 'ember') {
				p.vx += wobble * 14 * dt;
				p.vy -= 4 * dt;
			} else if (p.kind === 'snow') {
				p.vx += Math.sin(time * 0.6 + p.phase) * 8 * dt;
			} else if (p.kind === 'mote') {
				p.vx += wobble * 4 * dt;
			} else if (p.kind === 'ash') {
				p.vx += Math.sin(time * 0.9 + p.phase) * 10 * dt;
				p.rot += p.spin * dt;
			} else if (p.kind === 'spark') {
				p.vx *= 1 - 1.6 * dt;
				p.vy = p.vy * (1 - 1.6 * dt) + 60 * dt;
			}
			/* The cursor pushes the air around it */
			const dx = p.x - pointer.x;
			const dy = p.y - pointer.y;
			const d2 = dx * dx + dy * dy;
			if (d2 < 16000 && d2 > 1) {
				const f = (1 - d2 / 16000) * 380 * dt / Math.sqrt(d2);
				p.vx += dx * f;
				p.vy += dy * f;
			}
			p.x += p.vx * dt;
			p.y += p.vy * dt;
			const out = p.y < -60 || p.y > H + 60 || p.x < -80 || p.x > W + 80;
			if (p.age > p.life || out) parts.splice(i, 1);
		}
	}

	function draw() {
		ctx.clearRect(0, 0, W, H);
		/* Light first (additive), then the ash and snow on top */
		ctx.globalCompositeOperation = 'lighter';
		for (const p of parts) {
			if (p.kind === 'snow' || p.kind === 'ash') continue;
			const lifeK = p.kind === 'mote'
				? Math.sin(Math.min(1, p.age / p.life) * Math.PI)
				: 1 - Math.pow(Math.min(1, p.age / p.life), 2);
			const flick = p.kind === 'ember' ? 0.65 + 0.35 * Math.sin(time * 9 + p.phase * 3) : 0.8 + 0.2 * Math.sin(time * 3 + p.phase);
			const a = p.alpha * lifeK * flick;
			if (a <= 0.01) continue;
			const s = p.size * (p.kind === 'spark' ? 7 : 8);
			ctx.globalAlpha = a;
			ctx.drawImage(sprite(p.color), p.x - s / 2, p.y - s / 2, s, s);
		}
		ctx.globalCompositeOperation = 'source-over';
		for (const p of parts) {
			if (p.kind === 'snow') {
				ctx.globalAlpha = p.alpha;
				ctx.drawImage(sprite(p.color), p.x - p.size * 2.5, p.y - p.size * 2.5, p.size * 5, p.size * 5);
			} else if (p.kind === 'ash') {
				ctx.globalAlpha = p.alpha;
				ctx.fillStyle = p.color;
				ctx.save();
				ctx.translate(p.x, p.y);
				ctx.rotate(p.rot);
				ctx.fillRect(-p.size, -p.size * 0.45, p.size * 2, p.size * 0.9);
				ctx.restore();
			}
		}
		ctx.globalAlpha = 1;
	}

	function frame(now) {
		if (!running) return;
		const dt = Math.min(0.05, (now - last) / 1000 || 0.016);
		last = now;
		update(dt);
		draw();
		raf = requestAnimationFrame(frame);
	}

	function start() {
		if (running) return;
		running = true;
		last = performance.now();
		raf = requestAnimationFrame(frame);
	}
	function stop() {
		running = false;
		cancelAnimationFrame(raf);
	}

	function resize() {
		const fit = Eldmark.fitCanvas(canvas);
		ctx = fit.ctx;
		W = fit.w;
		H = fit.h;
	}

	function setMode(next) {
		if (next === mode) return;
		mode = next;
		/* Let the old particles fade naturally but thin them out so the change reads at once */
		for (let i = parts.length - 1; i >= 0; i--) {
			if (parts[i].kind !== 'spark' && Math.random() < 0.6) parts.splice(i, 1);
		}
		for (let i = 0; i < capacity() * 0.5; i++) spawn(true);
	}

	resize();
	for (let i = 0; i < capacity() * 0.7; i++) spawn(true);
	window.addEventListener('resize', resize);
	if ('ResizeObserver' in window) new ResizeObserver(resize).observe(canvas);

	hero.addEventListener('pointermove', (e) => {
		const rect = canvas.getBoundingClientRect();
		pointer.x = e.clientX - rect.left;
		pointer.y = e.clientY - rect.top;
	});
	hero.addEventListener('pointerleave', () => { pointer.x = pointer.y = -9999; });

	let visible = true;
	Eldmark.whenVisible(hero, () => { visible = true; if (!document.hidden) start(); }, () => { visible = false; stop(); });
	document.addEventListener('visibilitychange', () => {
		if (document.hidden) stop();
		else if (visible) start();
	});
	Eldmark.on('realm', (realm) => setMode(modeFor(realm)));

	Eldmark.embers = {
		burst,
		setMode,
		rekindle(seconds) { boost = seconds || 6; start(); },
		gold: GOLD_COLORS,
		colors: EMBER_COLORS,
	};
	start();
})();
