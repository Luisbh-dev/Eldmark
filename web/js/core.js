/*
 * Eldmark website core. Loaded first, before every other script.
 *
 * Shared contract for every module (see web/README.md):
 *   Eldmark.lang                 'en' | 'es'
 *   Eldmark.realm                null | 'vardheim' | 'solmarch' | 'askarra'
 *   Eldmark.on(evt, fn)          evt: 'lang' (fn(lang)) | 'realm' (fn(realm)) | 'sound' (fn(enabled))
 *   Eldmark.setLang(l) / Eldmark.setRealm(r)
 *   Eldmark.addStrings({en:{}, es:{}}) and Eldmark.t(key, vars)
 *   Eldmark.applyI18n(root)      fills [data-i18n], [data-i18n-html], [data-i18n-attr="attr:key;attr2:key2"]
 *   Eldmark.sound.play(name, opts) / Eldmark.sound.enabled / Eldmark.sound.toggle()
 *   Eldmark.REALMS               palette and names per realm
 *   Eldmark.reducedMotion        boolean
 *   Eldmark.whenVisible(el, onEnter, onLeave)   IntersectionObserver helper
 *   Eldmark.fitCanvas(canvas)    sizes a canvas to its CSS box with devicePixelRatio, returns {w, h, dpr, ctx}
 *
 * Plain classic scripts (no modules) so the site also works when index.html is opened from disk.
 */
(function () {
	'use strict';

	const store = {
		get(key) { try { return window.localStorage.getItem(key); } catch (e) { return null; } },
		set(key, value) { try { window.localStorage.setItem(key, value); } catch (e) { /* storage blocked */ } },
	};

	const REALMS = {
		vardheim: {
			id: 'vardheim', name: 'Vardheim',
			accent: '#8fd3f0', deep: '#4e7c90', dark: '#10242e', glow: 'rgba(126, 200, 232, 0.45)',
			particle: 'snow',
		},
		solmarch: {
			id: 'solmarch', name: 'Solmarch',
			accent: '#ecc94f', deep: '#a3882e', dark: '#2a210b', glow: 'rgba(233, 195, 65, 0.45)',
			particle: 'motes',
		},
		askarra: {
			id: 'askarra', name: 'Askarra',
			accent: '#e8574e', deep: '#9e1c25', dark: '#2a0b0d', glow: 'rgba(205, 127, 50, 0.5)',
			bronze: '#cd7f32',
			particle: 'ash',
		},
	};
	/* Neutral strongholds, held by the Hollow (the undead of old Eld). */
	const HOLLOW = { id: 'hollow', name: 'Hollow', accent: '#bdb6a6', deep: '#716d64' };

	const listeners = { lang: [], realm: [], sound: [] };
	const strings = { en: {}, es: {} };

	function emit(evt, value) {
		for (const fn of listeners[evt]) {
			try { fn(value); } catch (err) { console.error(err); }
		}
	}

	function t(key, vars) {
		let s = strings[Eldmark.lang][key];
		if (s === undefined) s = strings.en[key];
		if (s === undefined) return key;
		if (vars) s = s.replace(/\{(\w+)\}/g, (m, k) => (vars[k] !== undefined ? vars[k] : m));
		return s;
	}

	function applyI18n(root) {
		const scope = root || document;
		scope.querySelectorAll('[data-i18n]').forEach((el) => { el.textContent = t(el.dataset.i18n); });
		scope.querySelectorAll('[data-i18n-html]').forEach((el) => { el.innerHTML = t(el.dataset.i18nHtml); });
		scope.querySelectorAll('[data-i18n-attr]').forEach((el) => {
			for (const pair of el.dataset.i18nAttr.split(';')) {
				const [attr, key] = pair.split(':').map((x) => x.trim());
				if (attr && key) el.setAttribute(attr, t(key));
			}
		});
	}

	/* ---------- Sound: off by default, the visitor turns it on from the nav ---------- */
	const SFX_BASE = 'assets/sfx/';
	const SFX = {
		clash: ['clash_metal_01', 'clash_metal_02', 'clash_metal_03', 'clash_metal_04'],
		swing: ['sword_swing_light_01', 'sword_swing_light_02', 'sword_swing_light_03'],
		heavy: ['sword_swing_heavy_01', 'sword_swing_heavy_02'],
		hit: ['hit_flesh_01', 'hit_flesh_02', 'hit_flesh_03'],
		block: ['hit_shield_wood_01', 'hit_shield_wood_02', 'hit_shield_wood_03'],
		click: ['ui_click_01'],
		confirm: ['ui_confirm_01'],
		'horn-vardheim': ['horn_fort_won_vardheim_01'],
		'horn-solmarch': ['horn_fort_won_solmarch_01'],
		'horn-askarra': ['horn_fort_won_askarra_01'],
		'horn-lost-vardheim': ['horn_fort_lost_vardheim_01'],
		'horn-lost-solmarch': ['horn_fort_lost_solmarch_01'],
		'horn-lost-askarra': ['horn_fort_lost_askarra_01'],
	};
	const audioCache = {};
	let lastPlay = {};

	const sound = {
		enabled: store.get('eldmark.sound') === 'on',
		/* Plays one of the variants of a named sound. opts: {volume: 0..1, rate: number} */
		play(name, opts) {
			if (!sound.enabled) return;
			const list = SFX[name];
			if (!list) return;
			const now = performance.now();
			if (lastPlay[name] && now - lastPlay[name] < 40) return; /* avoid stacking */
			lastPlay[name] = now;
			const file = list[Math.floor(Math.random() * list.length)];
			let base = audioCache[file];
			if (!base) {
				base = new Audio(SFX_BASE + file + '.ogg');
				base.preload = 'auto';
				audioCache[file] = base;
			}
			const a = base.cloneNode();
			a.volume = Math.max(0, Math.min(1, (opts && opts.volume) != null ? opts.volume : 0.6));
			if (opts && opts.rate) { a.playbackRate = opts.rate; a.preservesPitch = false; }
			a.play().catch(() => { /* autoplay refused: ignore */ });
		},
		toggle(force) {
			sound.enabled = force === undefined ? !sound.enabled : !!force;
			store.set('eldmark.sound', sound.enabled ? 'on' : 'off');
			if (sound.enabled) sound.warm();
			emit('sound', sound.enabled);
		},
		/* Preloads the short combat sounds so the first parry is not late. */
		warm() {
			['clash', 'swing', 'hit', 'block', 'click'].forEach((n) => SFX[n].forEach((file) => {
				if (!audioCache[file]) {
					const a = new Audio(SFX_BASE + file + '.ogg');
					a.preload = 'auto';
					audioCache[file] = a;
				}
			}));
		},
	};

	const reducedMotion = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

	function whenVisible(el, onEnter, onLeave, options) {
		if (!el) return null;
		if (!('IntersectionObserver' in window)) { onEnter && onEnter(); return null; }
		const io = new IntersectionObserver((entries) => {
			for (const e of entries) {
				if (e.isIntersecting) onEnter && onEnter(e);
				else onLeave && onLeave(e);
			}
		}, options || { threshold: 0.01 });
		io.observe(el);
		return io;
	}

	function fitCanvas(canvas) {
		const dpr = Math.min(window.devicePixelRatio || 1, 2);
		const rect = canvas.getBoundingClientRect();
		const w = Math.max(1, Math.round(rect.width));
		const h = Math.max(1, Math.round(rect.height));
		if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) {
			canvas.width = Math.round(w * dpr);
			canvas.height = Math.round(h * dpr);
		}
		const ctx = canvas.getContext('2d');
		ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
		return { w, h, dpr, ctx };
	}

	function initialLang() {
		const saved = store.get('eldmark.lang');
		if (saved === 'en' || saved === 'es') return saved;
		const nav = (navigator.language || 'en').toLowerCase();
		return nav.startsWith('es') ? 'es' : 'en';
	}

	function initialRealm() {
		const saved = store.get('eldmark.realm');
		return REALMS[saved] ? saved : null;
	}

	const Eldmark = {
		lang: initialLang(),
		realm: initialRealm(),
		REALMS,
		HOLLOW,
		reducedMotion,
		sound,
		store,
		on(evt, fn) { if (listeners[evt]) listeners[evt].push(fn); },
		addStrings(dict) {
			for (const lang of ['en', 'es']) {
				if (dict[lang]) Object.assign(strings[lang], dict[lang]);
			}
		},
		t,
		applyI18n,
		setLang(lang) {
			if (lang !== 'en' && lang !== 'es') return;
			Eldmark.lang = lang;
			document.documentElement.lang = lang;
			store.set('eldmark.lang', lang);
			applyI18n(document);
			emit('lang', lang);
		},
		setRealm(realm) {
			if (realm !== null && !REALMS[realm]) return;
			Eldmark.realm = realm;
			store.set('eldmark.realm', realm || '');
			const root = document.documentElement;
			if (realm) {
				const r = REALMS[realm];
				root.dataset.realm = realm;
				root.style.setProperty('--accent', r.accent);
				root.style.setProperty('--accent-deep', r.deep);
				root.style.setProperty('--accent-glow', r.glow);
			} else {
				delete root.dataset.realm;
				root.style.removeProperty('--accent');
				root.style.removeProperty('--accent-deep');
				root.style.removeProperty('--accent-glow');
			}
			emit('realm', realm);
		},
		whenVisible,
		fitCanvas,
	};

	window.Eldmark = Eldmark;
	document.documentElement.lang = Eldmark.lang;
	document.documentElement.classList.add('js');
	if (Eldmark.realm) Eldmark.setRealm(Eldmark.realm);
})();
