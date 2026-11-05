/*
 * The legend of the Broken Crown, told by scrolling. A canvas shows the Flame of Eld burning over
 * the citadel of Aldcor; as the visitor reads on, the Flame weakens (the last king), bursts and the
 * citadel sinks (the Sundering), and what is left are the Embers scattered over the ruins.
 * The section's scroll progress (0..1) drives everything, so scrolling back rebuilds the Flame.
 */
(function () {
	'use strict';

	const section = document.getElementById('legend');
	const canvas = document.getElementById('flame');
	if (!section || !canvas || !window.Eldmark) return;
	const steps = Array.from(section.querySelectorAll('.legend-step'));
	const numeral = document.getElementById('legend-numeral');
	const NUMERALS = ['I', 'II', 'III', 'IV'];
	const reduced = Eldmark.reducedMotion;

	let ctx = null;
	let W = 0;
	let H = 0;
	let progress = 0;
	let prevProgress = 0;
	let running = false;
	let raf = 0;
	let last = 0;
	let time = 0;
	let flash = 0;
	let shake = 0;
	const flame = [];
	const debris = [];
	const shards = [];

	/* Flame color ramp by particle age: white heart, gold, orange, deep red, smoke */
	const RAMP = [
		[255, 247, 220], [255, 214, 120], [255, 160, 60], [236, 96, 30], [150, 40, 18], [40, 20, 14],
	];
	const sprites = RAMP.map((c) => {
		const s = document.createElement('canvas');
		s.width = s.height = 64;
		const g = s.getContext('2d');
		const grad = g.createRadialGradient(32, 32, 0, 32, 32, 32);
		grad.addColorStop(0, `rgba(${c[0]},${c[1]},${c[2]},1)`);
		grad.addColorStop(0.4, `rgba(${c[0]},${c[1]},${c[2]},0.45)`);
		grad.addColorStop(1, `rgba(${c[0]},${c[1]},${c[2]},0)`);
		g.fillStyle = grad;
		g.fillRect(0, 0, 64, 64);
		return s;
	});

	function clamp(v, a, b) { return Math.max(a, Math.min(b, v)); }
	function smooth(a, b, v) { const t = clamp((v - a) / (b - a), 0, 1); return t * t * (3 - 2 * t); }
	function rand(a, b) { return a + Math.random() * (b - a); }

	/* Phase weights from the scroll progress */
	function phase(p) {
		const king = smooth(0.18, 0.36, p);       /* the Flame weakens */
		const sunder = smooth(0.44, 0.56, p);     /* the burst */
		const embers = smooth(0.58, 0.78, p);     /* what remains */
		return { king, sunder, embers };
	}

	function base() {
		return { x: W * 0.5, y: H * (W < 860 ? 0.52 : 0.6) };
	}

	function emitFlame(dt, ph) {
		const strength = (1 - ph.king * 0.55) * (1 - ph.sunder);
		if (strength <= 0.02) return;
		const b = base();
		const scale = Math.min(W, H) / 700;
		const rate = (reduced ? 70 : 180) * strength;
		let n = rate * dt;
		while (n > 0) {
			if (n < 1 && Math.random() > n) break;
			n -= 1;
			const spread = (30 + ph.king * 14) * scale;
			flame.push({
				x: b.x + rand(-spread, spread),
				y: b.y + rand(-4, 6),
				vx: rand(-14, 14) * scale,
				vy: -rand(240, 420) * scale * (0.55 + 0.45 * strength),
				life: rand(0.6, 1.25) * (0.5 + 0.5 * strength),
				age: 0,
				size: rand(36, 74) * scale * (0.55 + 0.45 * strength),
				seed: rand(0, 6.28),
			});
		}
	}

	function explode() {
		const b = base();
		const scale = Math.min(W, H) / 700;
		const n = reduced ? 120 : 420;
		for (let i = 0; i < n; i++) {
			const a = rand(0, Math.PI * 2);
			const sp = rand(80, 620) * scale;
			debris.push({
				x: b.x, y: b.y - 30 * scale,
				vx: Math.cos(a) * sp, vy: Math.sin(a) * sp - 120 * scale,
				life: rand(1.2, 3.2), age: 0, size: rand(4, 16) * scale,
			});
		}
		flash = 1;
		shake = reduced ? 0 : 1;
		Eldmark.sound.play('heavy', { volume: 0.5, rate: 0.6 });
	}

	function buildShards() {
		shards.length = 0;
		const count = W < 860 ? 16 : 26;
		for (let i = 0; i < count; i++) {
			shards.push({
				x: rand(0.08, 0.92), y: rand(0.15, 0.9),
				r: rand(2, 5.5), phase: rand(0, 6.28), drift: rand(0.3, 1),
				sparkT: rand(0, 2),
			});
		}
	}

	function update(dt) {
		time += dt;
		const ph = phase(progress);
		/* Crossing the Sundering forward makes the Flame burst once */
		if (prevProgress < 0.5 && progress >= 0.5) explode();
		prevProgress = progress;

		emitFlame(dt, ph);
		const sway = Math.sin(time * 1.7) * (8 + ph.king * 26);
		for (let i = flame.length - 1; i >= 0; i--) {
			const p = flame[i];
			p.age += dt;
			const k = p.age / p.life;
			p.vx += (Math.sin(time * 6 + p.seed) * 40 + sway * 2 - (p.x - base().x) * 2.2) * dt;
			p.x += p.vx * dt;
			p.y += p.vy * dt;
			if (k >= 1) flame.splice(i, 1);
		}
		for (let i = debris.length - 1; i >= 0; i--) {
			const p = debris[i];
			p.age += dt;
			p.vx *= 1 - 1.2 * dt;
			p.vy = p.vy * (1 - 1.2 * dt) + 90 * dt;
			p.x += p.vx * dt;
			p.y += p.vy * dt;
			if (p.age > p.life) debris.splice(i, 1);
		}
		flash = Math.max(0, flash - dt * 1.4);
		shake = Math.max(0, shake - dt * 1.8);
	}

	/* The citadel of Aldcor: a dark silhouette that sinks and tilts at the Sundering */
	function drawCitadel(ph) {
		const b = base();
		const s = Math.min(W, H) / 700;
		const sink = ph.sunder * 70 * s + ph.embers * 20 * s;
		const tilt = ph.sunder * 0.05;
		ctx.save();
		ctx.translate(b.x, b.y + 26 * s + sink);
		ctx.rotate(tilt);
		const g = ctx.createLinearGradient(0, -200 * s, 0, 260 * s);
		g.addColorStop(0, '#2a211a');
		g.addColorStop(1, '#0c0a09');
		ctx.fillStyle = g;
		ctx.beginPath();
		const pts = [
			[-330, 1400], [-330, 40], [-300, 40], [-300, 10], [-270, 10], [-270, 40], [-210, 40], [-210, -60],
			[-224, -60], [-190, -130], [-156, -60], [-170, -60], [-170, 0], [-90, 0], [-90, -20], [-60, -20],
			[-60, 0], [-34, 0], [-34, -16], [34, -16], [34, 0], [60, 0], [60, -20], [90, -20], [90, 0],
			[170, 0], [170, -60], [156, -60], [190, -130], [224, -60], [210, -60], [210, 40], [270, 40],
			[270, 10], [300, 10], [300, 40], [330, 40], [330, 1400], [-330, 1400],
		];
		ctx.moveTo(pts[0][0] * s, pts[0][1] * s);
		for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i][0] * s, pts[i][1] * s);
		ctx.fill();
		/* Rim light from the Flame */
		const strength = (1 - ph.king * 0.55) * (1 - ph.sunder);
		ctx.strokeStyle = `rgba(255, 170, 80, ${0.12 + 0.35 * strength})`;
		ctx.lineWidth = 1.2;
		ctx.stroke();
		/* Lit windows */
		ctx.fillStyle = `rgba(255, 180, 90, ${0.15 + 0.5 * strength})`;
		for (const [wx, wy] of [[-190, -40], [190, -40], [-130, 40], [130, 40], [-250, 80], [250, 80], [0, 50]]) {
			ctx.fillRect((wx - 3) * s, wy * s, 6 * s, 12 * s);
		}
		ctx.restore();
		/* Ground fog line */
		const fog = ctx.createLinearGradient(0, H * 0.72, 0, H);
		fog.addColorStop(0, 'rgba(12, 10, 9, 0)');
		fog.addColorStop(1, 'rgba(12, 10, 9, 1)');
		ctx.fillStyle = fog;
		ctx.fillRect(0, H * 0.72, W, H * 0.28);
	}

	function draw() {
		const ph = phase(progress);
		const b = base();
		const s = Math.min(W, H) / 700;
		ctx.setTransform(ctx.getTransform());
		ctx.clearRect(-50, -50, W + 100, H + 100);
		ctx.save();
		if (shake > 0) ctx.translate(rand(-1, 1) * 14 * shake, rand(-1, 1) * 10 * shake);

		/* Sky glow behind the Flame */
		const strength = (1 - ph.king * 0.55) * (1 - ph.sunder);
		const glow = ctx.createRadialGradient(b.x, b.y - 60 * s, 0, b.x, b.y - 60 * s, Math.max(W, H) * 0.7);
		glow.addColorStop(0, `rgba(255, 150, 60, ${0.05 + 0.22 * strength + 0.4 * flash})`);
		glow.addColorStop(0.5, `rgba(120, 40, 16, ${0.04 + 0.08 * strength})`);
		glow.addColorStop(1, 'rgba(12, 10, 9, 0)');
		ctx.fillStyle = glow;
		ctx.fillRect(0, 0, W, H);

		drawCitadel(ph);

		/* Flame: a soft heart of light first, then the tongues */
		ctx.globalCompositeOperation = 'lighter';
		if (strength > 0.02) {
			const heart = 150 * s * (0.6 + 0.4 * strength) * (1 + Math.sin(time * 5) * 0.04);
			ctx.globalAlpha = 0.5 * strength;
			ctx.drawImage(sprites[2], b.x - heart / 2, b.y - heart * 0.62, heart, heart);
		}
		for (const p of flame) {
			const k = p.age / p.life;
			const idx = Math.min(RAMP.length - 1, Math.floor(0.6 + k * (RAMP.length - 0.6) + ph.king * 0.8));
			const size = p.size * (1 - k * 0.7);
			ctx.globalAlpha = (1 - k) * (k < 0.1 ? k * 4.2 : 0.42);
			ctx.drawImage(sprites[idx], p.x - size / 2, p.y - size / 2, size, size);
		}
		/* Burst debris */
		for (const p of debris) {
			const k = p.age / p.life;
			const idx = Math.min(RAMP.length - 2, Math.floor(k * 4));
			ctx.globalAlpha = (1 - k) * 0.9;
			const size = p.size * (1 - k * 0.5);
			ctx.drawImage(sprites[idx], p.x - size / 2, p.y - size / 2, size, size);
		}
		/* The Embers of Eld: shards scattered over the ruins, breathing light */
		if (ph.embers > 0.01) {
			for (const e of shards) {
				const x = e.x * W + Math.sin(time * 0.3 * e.drift + e.phase) * 10;
				const y = e.y * H + Math.cos(time * 0.25 * e.drift + e.phase) * 8;
				const pulse = 0.6 + 0.4 * Math.sin(time * 1.6 + e.phase);
				const size = e.r * 9 * s * (0.8 + pulse * 0.4);
				ctx.globalAlpha = ph.embers * pulse * 0.9;
				ctx.drawImage(sprites[2], x - size / 2, y - size / 2, size, size);
				ctx.globalAlpha = ph.embers;
				ctx.drawImage(sprites[0], x - size / 8, y - size / 8, size / 4, size / 4);
			}
		}
		ctx.globalCompositeOperation = 'source-over';
		ctx.globalAlpha = 1;
		if (flash > 0) {
			ctx.fillStyle = `rgba(255, 230, 180, ${flash * 0.5})`;
			ctx.fillRect(0, 0, W, H);
		}
		ctx.restore();
	}

	function measure() {
		const rect = section.getBoundingClientRect();
		const span = rect.height - window.innerHeight;
		progress = clamp(-rect.top / (span > 0 ? span : 1), 0, 1);
		section.style.setProperty('--crack', smooth(0.42, 0.6, progress).toFixed(3));
		/* Active chapter: the one whose middle is closest to the middle of the screen */
		const mid = window.innerHeight / 2;
		let best = 0;
		let bestD = Infinity;
		steps.forEach((el, i) => {
			const r = el.getBoundingClientRect();
			const d = Math.abs(r.top + r.height / 2 - mid);
			if (d < bestD) { bestD = d; best = i; }
		});
		steps.forEach((el, i) => el.classList.toggle('is-active', i === best));
		if (numeral && numeral.textContent !== NUMERALS[best]) numeral.textContent = NUMERALS[best];
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
	function stop() { running = false; cancelAnimationFrame(raf); }

	function resize() {
		const fit = Eldmark.fitCanvas(canvas);
		ctx = fit.ctx;
		W = fit.w;
		H = fit.h;
		buildShards();
	}

	resize();
	measure();
	prevProgress = progress;
	window.addEventListener('scroll', measure, { passive: true });
	window.addEventListener('resize', () => { resize(); measure(); });
	let visible = false;
	Eldmark.whenVisible(section, () => { visible = true; if (!document.hidden) start(); }, () => { visible = false; stop(); });
	document.addEventListener('visibilitychange', () => {
		if (document.hidden) stop();
		else if (visible) start();
	});
})();
