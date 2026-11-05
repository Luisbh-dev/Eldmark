/*
 * Page wiring: navigation, language and sound, the crown in the hero, the realm banners,
 * scroll reveals, counters, the before/after slider, the gallery lightbox, the roadmap braziers,
 * the terminal and one old secret. Loaded last; the section modules are already built.
 */
(function () {
	'use strict';
	const E = window.Eldmark;
	if (!E) return;
	const $ = (sel, root) => (root || document).querySelector(sel);
	const $$ = (sel, root) => Array.from((root || document).querySelectorAll(sel));
	const reduced = E.reducedMotion;

	/* ---------------------------------------------------------------- toast */
	const toastEl = $('#toast');
	let toastTimer = 0;
	function toast(text, ms) {
		if (!toastEl) return;
		toastEl.textContent = text;
		toastEl.classList.add('is-on');
		clearTimeout(toastTimer);
		toastTimer = setTimeout(() => toastEl.classList.remove('is-on'), ms || 3200);
	}

	/* ---------------------------------------------------------------- language */
	function syncLangButtons() {
		$$('.lang-switch button').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.lang === E.lang)));
		document.title = document.hidden ? E.t('doc.away') : E.t('doc.title');
	}
	$$('.lang-switch button').forEach((b) => b.addEventListener('click', () => {
		E.setLang(b.dataset.lang);
		E.sound.play('click', { volume: 0.4 });
	}));
	E.on('lang', syncLangButtons);
	document.addEventListener('visibilitychange', () => {
		document.title = document.hidden ? E.t('doc.away') : E.t('doc.title');
	});

	/* ---------------------------------------------------------------- sound */
	const soundBtn = $('#sound-toggle');
	function syncSound() { soundBtn.setAttribute('aria-pressed', String(E.sound.enabled)); }
	soundBtn.addEventListener('click', () => {
		E.sound.toggle();
		syncSound();
		if (E.sound.enabled) {
			E.sound.play('confirm', { volume: 0.5 });
			toast(E.t('toast.sound.on'));
		}
	});
	syncSound();

	/* ---------------------------------------------------------------- nav */
	const nav = $('#nav');
	const burger = $('#nav-burger');
	const onScroll = () => nav.classList.toggle('is-scrolled', window.scrollY > 40);
	window.addEventListener('scroll', onScroll, { passive: true });
	onScroll();
	burger.addEventListener('click', () => {
		const open = !nav.classList.contains('is-open');
		nav.classList.toggle('is-open', open);
		burger.setAttribute('aria-expanded', String(open));
	});
	$$('.nav-links a').forEach((a) => a.addEventListener('click', () => {
		nav.classList.remove('is-open');
		burger.setAttribute('aria-expanded', 'false');
	}));
	document.addEventListener('click', (e) => {
		if (nav.classList.contains('is-open') && !nav.contains(e.target)) {
			nav.classList.remove('is-open');
			burger.setAttribute('aria-expanded', 'false');
		}
	});
	/* Highlight the section being read */
	const links = new Map($$('.nav-links a').map((a) => [a.getAttribute('href').slice(1), a]));
	if ('IntersectionObserver' in window) {
		const spy = new IntersectionObserver((entries) => {
			for (const e of entries) {
				if (!e.isIntersecting) continue;
				links.forEach((a, id) => a.classList.toggle('is-current', id === e.target.id));
			}
		}, { rootMargin: '-45% 0px -50% 0px' });
		links.forEach((a, id) => { const s = document.getElementById(id); if (s) spy.observe(s); });
	}

	/* ---------------------------------------------------------------- reveals */
	const revealEls = $$('.reveal');
	if ('IntersectionObserver' in window && !reduced) {
		const io = new IntersectionObserver((entries) => {
			for (const e of entries) {
				if (e.isIntersecting) { e.target.classList.add('is-in'); io.unobserve(e.target); }
			}
		}, { rootMargin: '0px 0px -8% 0px', threshold: 0.05 });
		revealEls.forEach((el, i) => {
			el.style.transitionDelay = `${(i % 4) * 70}ms`;
			io.observe(el);
		});
	} else {
		revealEls.forEach((el) => el.classList.add('is-in'));
	}

	/* ---------------------------------------------------------------- hero */
	const hero = $('.hero');
	const crown = $('#crown');
	const video = $('#hero-video');
	hero.addEventListener('pointermove', (e) => {
		const r = hero.getBoundingClientRect();
		hero.style.setProperty('--mx', `${((e.clientX - r.left) / r.width) * 100}%`);
		hero.style.setProperty('--my', `${((e.clientY - r.top) / r.height) * 100}%`);
	});
	if (reduced && video) { video.removeAttribute('autoplay'); video.pause(); }
	if (video) {
		E.whenVisible(hero, () => { if (!reduced) video.play().catch(() => {}); }, () => video.pause());
	}

	function crownCenter() {
		const r = crown.getBoundingClientRect();
		return { x: r.left + r.width / 2, y: r.top + r.height * 0.55 };
	}
	function breakCrown(silent) {
		crown.classList.remove('is-whole', 'is-broken', 'is-idle');
		crown.classList.add('is-cracking');
		setTimeout(() => {
			crown.classList.add('is-broken');
			const c = crownCenter();
			if (E.embers) E.embers.burst(c.x, c.y, { count: 90, speed: 320 });
			if (!silent) E.sound.play('clash', { volume: 0.45, rate: 0.8 });
		}, reduced ? 0 : 650);
		setTimeout(() => crown.classList.add('is-idle'), reduced ? 0 : 2100);
	}
	setTimeout(() => breakCrown(true), reduced ? 0 : 1100);
	crown.addEventListener('click', () => {
		/* Mend the crown for a heartbeat, then let it break again */
		crown.classList.remove('is-cracking', 'is-broken', 'is-idle');
		crown.classList.add('is-whole');
		E.sound.play('confirm', { volume: 0.35 });
		setTimeout(() => breakCrown(false), 700);
	});

	/* ---------------------------------------------------------------- realms */
	const banners = $('.banners');
	const bannerBtns = $$('.banner');
	const panels = $$('.realm-panel');
	const hint = $('#realm-hint');
	const actions = $('#realm-actions');
	const swornName = $('#realm-sworn-name');
	const navPledge = $('#nav-pledge');

	function showRealm(realm) {
		bannerBtns.forEach((b) => b.setAttribute('aria-selected', String(b.dataset.realm === realm)));
		banners.classList.toggle('has-choice', !!realm);
		panels.forEach((p) => { p.hidden = p.dataset.realm !== realm; });
		hint.hidden = !!realm;
		actions.hidden = !realm;
		if (realm) {
			swornName.textContent = E.REALMS[realm].name;
			navPledge.hidden = false;
			$('use', navPledge).setAttribute('href', `#em-${realm}`);
		} else {
			navPledge.hidden = true;
		}
	}

	function pledge(realm, fromClick) {
		if (realm === E.realm && fromClick) {
			showRealm(realm);
			return;
		}
		E.setRealm(realm);
		showRealm(realm);
		if (!fromClick) return;
		const btn = bannerBtns.find((b) => b.dataset.realm === realm);
		btn.classList.remove('is-raising');
		void btn.offsetWidth;
		btn.classList.add('is-raising');
		const r = btn.getBoundingClientRect();
		if (E.embers) {
			const colors = realm === 'vardheim'
				? ['rgba(210,240,255,1)', 'rgba(143,211,240,1)']
				: realm === 'solmarch' ? E.embers.gold : ['rgba(232,87,78,1)', 'rgba(205,127,50,1)', 'rgba(255,150,70,1)'];
			/* The hero canvas only covers the hero; the burst is a small celebration if it is in view */
			E.embers.burst(r.left + r.width / 2, r.top + r.height * 0.4, { count: 50, colors });
		}
		E.sound.play(`horn-${realm}`, { volume: 0.55 });
		toast(E.t(`toast.pledge.${realm}`));
	}

	bannerBtns.forEach((b) => b.addEventListener('click', () => pledge(b.dataset.realm, true)));
	/* Arrow keys move between banners, as in a tab list */
	banners.addEventListener('keydown', (e) => {
		if (e.key !== 'ArrowRight' && e.key !== 'ArrowLeft') return;
		const i = bannerBtns.indexOf(document.activeElement);
		if (i < 0) return;
		e.preventDefault();
		const next = bannerBtns[(i + (e.key === 'ArrowRight' ? 1 : bannerBtns.length - 1)) % bannerBtns.length];
		next.focus();
	});
	$('#realm-release').addEventListener('click', () => {
		const was = E.realm;
		E.setRealm(null);
		showRealm(null);
		if (was) E.sound.play(`horn-lost-${was}`, { volume: 0.4 });
		toast(E.t('toast.release'));
	});
	showRealm(E.realm);

	/* ---------------------------------------------------------------- counters */
	function formatNumber(n) {
		return n.toLocaleString(E.lang === 'es' ? 'es-ES' : 'en-US');
	}
	$$('.stats b[data-count]').forEach((el) => {
		const target = parseInt(el.dataset.count, 10);
		const suffix = el.dataset.suffix || '';
		let done = false;
		const render = (v) => { el.textContent = formatNumber(v) + suffix; };
		E.whenVisible(el, () => {
			if (done) return;
			done = true;
			if (reduced) { render(target); return; }
			const t0 = performance.now();
			const dur = 1400;
			const tick = (now) => {
				const k = Math.min(1, (now - t0) / dur);
				const eased = 1 - Math.pow(1 - k, 3);
				render(Math.round(target * eased));
				if (k < 1) requestAnimationFrame(tick);
			};
			requestAnimationFrame(tick);
		});
		E.on('lang', () => { if (done) render(target); });
	});

	/* ---------------------------------------------------------------- before / after */
	const compare = $('#compare');
	if (compare) {
		const range = $('.compare-range', compare);
		const afterImg = $('.compare-after', compare);
		const beforeImg = $('.compare-before', compare);
		const setPos = (v) => compare.style.setProperty('--pos', `${v}%`);
		range.addEventListener('input', () => setPos(range.value));
		$$('.compare-tabs button').forEach((b) => b.addEventListener('click', () => {
			$$('.compare-tabs button').forEach((x) => x.classList.toggle('is-active', x === b));
			const pair = b.dataset.pair;
			afterImg.src = `assets/img/${pair}.webp`;
			beforeImg.src = `assets/img/antes_${pair}.webp`;
			E.sound.play('click', { volume: 0.35 });
		}));
		/* A small sweep the first time it scrolls into view, so it reads as a slider */
		let swept = false;
		E.whenVisible(compare, () => {
			if (swept || reduced) return;
			swept = true;
			const t0 = performance.now();
			const sweep = (now) => {
				const k = Math.min(1, (now - t0) / 1600);
				const v = 50 + Math.sin(k * Math.PI * 2) * 22 * (1 - k);
				setPos(v);
				range.value = v;
				if (k < 1) requestAnimationFrame(sweep);
			};
			setTimeout(() => requestAnimationFrame(sweep), 500);
		}, null, { threshold: 0.6 });
	}

	/* ---------------------------------------------------------------- lightbox */
	const lightbox = $('#lightbox');
	const shots = $$('.shot');
	let shotIndex = 0;
	let lastFocus = null;
	function openShot(i) {
		shotIndex = (i + shots.length) % shots.length;
		const s = shots[shotIndex];
		const img = $('img', lightbox);
		img.src = s.dataset.full;
		img.alt = $('img', s).alt;
		$('figcaption', lightbox).textContent = $('span', s).textContent;
		if (lightbox.hidden) {
			lastFocus = document.activeElement;
			lightbox.hidden = false;
			document.body.style.overflow = 'hidden';
			$('.lightbox-close', lightbox).focus();
		}
	}
	function closeShot() {
		lightbox.hidden = true;
		document.body.style.overflow = '';
		if (lastFocus) lastFocus.focus();
	}
	shots.forEach((s, i) => s.addEventListener('click', () => openShot(i)));
	$('.lightbox-close', lightbox).addEventListener('click', closeShot);
	$('.lightbox-prev', lightbox).addEventListener('click', () => openShot(shotIndex - 1));
	$('.lightbox-next', lightbox).addEventListener('click', () => openShot(shotIndex + 1));
	lightbox.addEventListener('click', (e) => { if (e.target === lightbox) closeShot(); });
	document.addEventListener('keydown', (e) => {
		if (lightbox.hidden) return;
		if (e.key === 'Escape') closeShot();
		else if (e.key === 'ArrowLeft') openShot(shotIndex - 1);
		else if (e.key === 'ArrowRight') openShot(shotIndex + 1);
		else if (e.key === 'Tab') {
			/* Keep focus inside the lightbox */
			const f = $$('button', lightbox);
			const i = f.indexOf(document.activeElement);
			e.preventDefault();
			f[(i + (e.shiftKey ? f.length - 1 : 1)) % f.length].focus();
		}
	});

	/* ---------------------------------------------------------------- roadmap */
	const road = $('.road-wrap');
	if (road) {
		const stepsEl = $$('.road-step', road);
		const spine = $('#road-spine');
		const doneCount = stepsEl.filter((s) => s.classList.contains('is-done')).length;
		const updateRoad = () => {
			const r = road.getBoundingClientRect();
			const vh = window.innerHeight;
			/* Fill follows the reader, but never beyond the last finished step */
			const lastDone = stepsEl[doneCount - 1];
			const lr = lastDone.getBoundingClientRect();
			const maxFill = (lr.top + lr.height / 2 - r.top) / r.height;
			const read = (vh * 0.62 - r.top) / r.height;
			const fill = Math.max(0, Math.min(maxFill, read));
			spine.style.setProperty('--road', `${(fill * 100).toFixed(2)}%`);
			stepsEl.forEach((s, i) => {
				const sr = s.getBoundingClientRect();
				const at = (sr.top + sr.height / 2 - r.top) / r.height;
				const lit = i < doneCount && fill >= at - 0.01;
				if (lit && !s.classList.contains('is-lit')) {
					s.classList.add('is-lit');
					E.sound.play('block', { volume: 0.12, rate: 1.6 });
				} else if (!lit) s.classList.remove('is-lit');
			});
		};
		if (reduced) {
			stepsEl.forEach((s, i) => s.classList.toggle('is-lit', i < doneCount));
			spine.style.setProperty('--road', '60%');
		} else {
			window.addEventListener('scroll', updateRoad, { passive: true });
			window.addEventListener('resize', updateRoad);
			updateRoad();
		}
	}

	/* ---------------------------------------------------------------- terminal */
	const termBody = $('#terminal-body');
	if (termBody) {
		const code = $('code', termBody);
		const original = code.innerHTML;
		const lines = original.split('\n');
		const plain = lines.filter((l) => !l.startsWith('<span class="c">')).map((l) => l.replace(/&amp;/g, '&')).join('\n');
		$('#terminal-copy').addEventListener('click', () => {
			const done = () => { toast(E.t('toast.copied')); E.sound.play('confirm', { volume: 0.4 }); };
			if (navigator.clipboard && window.isSecureContext) navigator.clipboard.writeText(plain).then(done, () => {});
			else {
				const ta = document.createElement('textarea');
				ta.value = plain;
				document.body.appendChild(ta);
				ta.select();
				try { document.execCommand('copy'); done(); } catch (err) { /* ignore */ }
				ta.remove();
			}
		});
		/* Type the commands out the first time the terminal is seen */
		if (!reduced) {
			code.innerHTML = '<span class="cursor"></span>';
			let typed = false;
			E.whenVisible(termBody, () => {
				if (typed) return;
				typed = true;
				let li = 0;
				let ci = 0;
				let html = '';
				const step = () => {
					if (li >= lines.length) {
						code.innerHTML = original + '\n<span class="p">$</span> <span class="cursor"></span>';
						return;
					}
					const line = lines[li];
					if (line.startsWith('<span class="c">')) {
						html += line + '\n';
						li++;
						code.innerHTML = html + '<span class="cursor"></span>';
						setTimeout(step, 160);
						return;
					}
					if (ci === 0) html += '<span class="p">$</span> ';
					const txt = line.replace(/&amp;/g, '&');
					ci++;
					const shown = txt.slice(0, ci).replace(/&/g, '&amp;');
					code.innerHTML = html + shown + '<span class="cursor"></span>';
					if (ci >= txt.length) {
						html += shown + '\n';
						li++;
						ci = 0;
						setTimeout(step, 260);
					} else setTimeout(step, 18 + Math.random() * 28);
				};
				setTimeout(step, 300);
			}, null, { threshold: 0.4 });
		}
	}

	/* ---------------------------------------------------------------- the old secret */
	const KONAMI = ['ArrowUp', 'ArrowUp', 'ArrowDown', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'ArrowLeft', 'ArrowRight', 'b', 'a'];
	let kpos = 0;
	let rekindled = false;
	document.addEventListener('keydown', (e) => {
		if (e.target.closest && e.target.closest('input, textarea, .pt-stage, .nc-stage')) return;
		const key = e.key.length === 1 ? e.key.toLowerCase() : e.key;
		kpos = key === KONAMI[kpos] ? kpos + 1 : (key === KONAMI[0] ? 1 : 0);
		if (kpos === KONAMI.length) { kpos = 0; rekindle(); }
	});
	function rekindle() {
		if (rekindled) return;
		rekindled = true;
		const root = document.documentElement;
		root.classList.add('is-rekindled');
		const flare = $('#flare');
		flare.classList.remove('is-on');
		void flare.offsetWidth;
		flare.classList.add('is-on');
		crown.classList.remove('is-cracking', 'is-broken', 'is-idle');
		crown.classList.add('is-whole');
		if (E.embers) {
			E.embers.rekindle(8);
			const c = crownCenter();
			E.embers.burst(c.x, c.y, { count: 160, speed: 420, colors: E.embers.gold });
		}
		E.sound.play('confirm', { volume: 0.6 });
		['vardheim', 'solmarch', 'askarra'].forEach((r, i) => setTimeout(() => E.sound.play(`horn-${r}`, { volume: 0.35 }), 300 + i * 500));
		toast(E.t('toast.rekindled'), 5000);
		setTimeout(() => {
			root.classList.remove('is-rekindled');
			rekindled = false;
			breakCrown(false);
		}, 8000);
	}

	/* ---------------------------------------------------------------- first paint in the right language */
	E.setLang(E.lang);
})();
