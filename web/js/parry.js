/*
 * Trial of the Parry: a one-button duel against a Hollow of the old garrison.
 * It uses the game's real numbers from data/combat/combat_rules.tres: a parry is a press in the
 * 6 ticks (100 ms at 60 Hz) before the hit lands, parrying has a 30-tick (500 ms) cooldown and a
 * parried attacker staggers for 0.6 s. Squire mode widens the window to 200 ms and shows a timing bar.
 * Press during the stagger to riposte. Health and stamina are 1000, as in the game.
 */
(function () {
	'use strict';

	const mount = document.getElementById('parry-trial');
	if (!mount || !window.Eldmark) return;
	const E = window.Eldmark;
	const reduced = E.reducedMotion;

	const RULES = {
		tickMs: 1000 / 60,
		parryWindowTicks: 6,
		parryCooldownTicks: 30,
		parryStaggerS: 0.6,
		healthMax: 1000,
		staminaMax: 1000,
	};
	const MODES = {
		squire: { windowMs: 200, bar: true },
		eldmark: { windowMs: RULES.parryWindowTicks * RULES.tickMs, bar: false },
	};
	const BLOCK_STAMINA = 220;
	/* Direction of the Hollow's blade in canvas radians (0 = right, -PI/2 = up). It faces left. */
	const GUARD = -3.7;      /* forward and down, toward the player */
	const TOP = -1.04;       /* raised behind the head */
	const FEINT_TOP = -1.8;
	const STAGGERED = -2.1;
	const HIT_DAMAGE = [140, 190];
	const RIPOSTE_DAMAGE = 260;

	E.addStrings({
		en: {
			'pt.title': 'Trial of the Parry',
			'pt.sub': 'One button. Time it.',
			'pt.squire': 'Squire',
			'pt.squire.small': '200 ms window',
			'pt.eldmark': 'Eldmark',
			'pt.eldmark.small': '6 ticks · 100 ms',
			'pt.start.title': 'A Hollow guards the ford',
			'pt.start.text': 'Press Space, click or tap the moment before its blade lands. Parry, then strike again while it staggers.',
			'pt.start.btn': 'Face the Hollow',
			'pt.down.title': 'You are downed',
			'pt.down.text': 'Best streak: {streak} parries. Hollows laid to rest: {kills}.',
			'pt.down.btn': 'Rise again',
			'pt.paused.title': 'Paused',
			'pt.paused.text': 'The Hollow waits. It has nowhere else to be.',
			'pt.paused.btn': 'Resume',
			'pt.parry': 'Parry!',
			'pt.riposte': 'Riposte',
			'pt.blocked': 'Blocked',
			'pt.guardbreak': 'Guard broken',
			'pt.hit': 'Hit',
			'pt.feint': 'Feint!',
			'pt.fallen': 'The Hollow falls',
			'pt.v.parry': 'Parried {ms} ms before the hit.',
			'pt.v.early': 'Too early by {ms} ms: that was a block, not a parry.',
			'pt.v.late': 'Too late by {ms} ms.',
			'pt.v.none': 'No guard at all.',
			'pt.v.cooldown': 'Parry still on cooldown (500 ms).',
			'pt.v.riposte': 'Riposte lands while it staggers.',
			'pt.v.feint': 'It feinted. Your parry is on cooldown.',
			'pt.v.fallen': 'Another Hollow rises, faster.',
			'pt.v.guardbreak': 'Out of stamina: your guard breaks.',
			'pt.streak': 'Streak',
			'pt.best': 'Best',
			'pt.kills': 'Laid to rest',
			'pt.hint': 'Space / click / tap · the real game uses the right mouse button',
			'pt.tap': 'Parry',
			'pt.you': 'You',
			'pt.hollow': 'Hollow',
			'pt.aria': 'Duel against a Hollow. Press Space or click to parry.',
		},
		es: {
			'pt.title': 'Prueba de la parada',
			'pt.sub': 'Un botón. Mide el momento.',
			'pt.squire': 'Escudero',
			'pt.squire.small': 'ventana de 200 ms',
			'pt.eldmark': 'Eldmark',
			'pt.eldmark.small': '6 ticks · 100 ms',
			'pt.start.title': 'Un Hueco guarda el vado',
			'pt.start.text': 'Pulsa Espacio, haz clic o toca justo antes de que caiga su hoja. Para el golpe y vuelve a golpear mientras se tambalea.',
			'pt.start.btn': 'Enfrentarse al Hueco',
			'pt.down.title': 'Has caído',
			'pt.down.text': 'Mejor racha: {streak} paradas. Huecos que descansan en paz: {kills}.',
			'pt.down.btn': 'Levantarse',
			'pt.paused.title': 'En pausa',
			'pt.paused.text': 'El Hueco espera. No tiene otro sitio adonde ir.',
			'pt.paused.btn': 'Seguir',
			'pt.parry': '¡Parada!',
			'pt.riposte': 'Contraataque',
			'pt.blocked': 'Bloqueado',
			'pt.guardbreak': 'Guardia rota',
			'pt.hit': 'Golpe',
			'pt.feint': '¡Finta!',
			'pt.fallen': 'El Hueco cae',
			'pt.v.parry': 'Parada {ms} ms antes del golpe.',
			'pt.v.early': '{ms} ms antes de tiempo: eso fue un bloqueo, no una parada.',
			'pt.v.late': '{ms} ms tarde.',
			'pt.v.none': 'Ni siquiera levantaste el escudo.',
			'pt.v.cooldown': 'La parada aún se está recargando (500 ms).',
			'pt.v.riposte': 'El contraataque entra mientras se tambalea.',
			'pt.v.feint': 'Era una finta. Tu parada se está recargando.',
			'pt.v.fallen': 'Se alza otro Hueco, más rápido.',
			'pt.v.guardbreak': 'Sin aguante: se rompe tu guardia.',
			'pt.streak': 'Racha',
			'pt.best': 'Récord',
			'pt.kills': 'En paz',
			'pt.hint': 'Espacio / clic / toque · en el juego es el botón derecho del ratón',
			'pt.tap': 'Parar',
			'pt.you': 'Tú',
			'pt.hollow': 'Hueco',
			'pt.aria': 'Duelo contra un Hueco. Pulsa Espacio o haz clic para parar.',
		},
	});

	/* ---------------------------------------------------------------- DOM */
	mount.innerHTML = `
		<div class="pt">
			<div class="pt-head">
				<div class="pt-title"><span data-i18n="pt.title"></span><small data-i18n="pt.sub"></small></div>
				<div class="pt-modes" role="group">
					<button type="button" data-mode="squire" aria-pressed="true"><span data-i18n="pt.squire"></span><small data-i18n="pt.squire.small"></small></button>
					<button type="button" data-mode="eldmark" aria-pressed="false"><span data-i18n="pt.eldmark"></span><small data-i18n="pt.eldmark.small"></small></button>
				</div>
			</div>
			<div class="pt-stage" tabindex="0" role="application" data-i18n-attr="aria-label:pt.aria">
				<canvas></canvas>
				<div class="pt-overlay">
					<div>
						<h4></h4>
						<p></p>
						<button type="button" class="btn btn-primary pt-go"></button>
					</div>
				</div>
			</div>
			<button type="button" class="btn btn-ghost pt-btn" data-i18n="pt.tap"></button>
			<div class="pt-foot">
				<p class="pt-verdict" aria-live="polite"></p>
				<div class="pt-score">
					<span><span data-i18n="pt.streak"></span> <b class="pt-streak">0</b></span>
					<span><span data-i18n="pt.best"></span> <b class="pt-best">0</b></span>
					<span><span data-i18n="pt.kills"></span> <b class="pt-kills">0</b></span>
				</div>
				<p class="pt-hint" data-i18n="pt.hint"></p>
			</div>
		</div>`;
	const stage = mount.querySelector('.pt-stage');
	const canvas = stage.querySelector('canvas');
	const overlay = stage.querySelector('.pt-overlay');
	const overlayTitle = overlay.querySelector('h4');
	const overlayText = overlay.querySelector('p');
	const overlayBtn = overlay.querySelector('.pt-go');
	const tapBtn = mount.querySelector('.pt-btn');
	const verdictEl = mount.querySelector('.pt-verdict');
	const streakEl = mount.querySelector('.pt-streak');
	const bestEl = mount.querySelector('.pt-best');
	const killsEl = mount.querySelector('.pt-kills');
	const modeBtns = Array.from(mount.querySelectorAll('.pt-modes button'));

	/* ---------------------------------------------------------------- state */
	let ctx = null;
	let W = 0;
	let H = 0;
	let mode = E.store.get('eldmark.parry.mode') === 'eldmark' ? 'eldmark' : 'squire';
	let best = parseInt(E.store.get('eldmark.parry.best') || '0', 10) || 0;
	let overlayState = 'start'; /* start | down | paused | none */
	let running = false;
	let raf = 0;
	let last = 0;

	const game = {
		t: 0,               /* game clock in ms (scaled by slow motion) */
		slow: 0,            /* ms of slow motion left (real time) */
		phase: 'ready',     /* ready | windup | swing | recover | stagger | feint | dying */
		phaseT: 0,
		phaseLen: 0,
		impactAt: 0,        /* real time (performance.now) of the next impact */
		windupStartReal: 0,
		lastPress: -1e9,
		pressedThisAttack: false,
		pressTime: 0,
		health: RULES.healthMax,
		stamina: RULES.staminaMax,
		enemyHealth: 1000,
		enemyMax: 1000,
		level: 1,
		streak: 0,
		kills: 0,
		comboLeft: 0,
		shake: 0,
		flash: 0,
		flashColor: '255,230,170',
		shieldUp: 0,
		lunge: 0,
		stagger: 0,
		popups: [],
		sparks: [],
		motes: [],
		armAngle: GUARD,
	};

	function rand(a, b) { return a + Math.random() * (b - a); }
	function toRoman(n) {
		const table = [[10, 'X'], [9, 'IX'], [5, 'V'], [4, 'IV'], [1, 'I']];
		let out = '';
		for (const [v, r] of table) while (n >= v) { out += r; n -= v; }
		return out;
	}
	function clamp(v, a, b) { return Math.max(a, Math.min(b, v)); }

	function accent() {
		return getComputedStyle(document.documentElement).getPropertyValue('--accent').trim() || '#ff8a3d';
	}
	let accentColor = accent();

	/* ---------------------------------------------------------------- flow */
	function setMode(next) {
		mode = next;
		E.store.set('eldmark.parry.mode', mode);
		modeBtns.forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.mode === mode)));
	}

	function showOverlay(kind) {
		overlayState = kind;
		if (kind === 'none') {
			overlay.classList.add('is-hidden');
			return;
		}
		overlay.classList.remove('is-hidden');
		const vars = { streak: game.bestRun || 0, kills: game.kills };
		overlayTitle.textContent = E.t(`pt.${kind}.title`);
		overlayText.textContent = E.t(`pt.${kind}.text`, vars);
		overlayBtn.textContent = E.t(`pt.${kind}.btn`);
	}

	function newGame() {
		Object.assign(game, {
			t: 0, slow: 0, health: RULES.healthMax, stamina: RULES.staminaMax,
			enemyHealth: 1000, enemyMax: 1000, level: 1, streak: 0, kills: 0, bestRun: 0,
			comboLeft: 0, popups: [], sparks: [], lastPress: -1e9, stagger: 0,
		});
		verdict('', '');
		updateScore();
		enter('ready');
		showOverlay('none');
		E.sound.warm();
		stage.focus({ preventScroll: true });
		start();
	}

	function speedFactor() {
		/* Each Hollow laid to rest makes the next one quicker */
		return Math.max(0.55, 1 - (game.level - 1) * 0.09);
	}

	function enter(phase) {
		game.phase = phase;
		game.phaseT = 0;
		const now = performance.now();
		switch (phase) {
		case 'ready':
			game.phaseLen = rand(500, 1100) * speedFactor();
			break;
		case 'windup': {
			const f = speedFactor();
			/* Combos and the real blow after a feint come fast, inside the parry cooldown */
			const quick = game.comboLeft > 0 || game.afterFeint;
			game.afterFeint = false;
			game.phaseLen = (quick ? rand(240, 360) : rand(520, 1050)) * f;
			game.windupStartReal = now;
			game.pressedThisAttack = false;
			/* Impact = end of windup + the swing itself */
			game.swingLen = 150;
			game.windupEndReal = now + game.phaseLen;
			game.impactAt = game.windupEndReal + game.swingLen;
			break;
		}
		case 'feint':
			game.phaseLen = rand(380, 520) * speedFactor();
			game.pressedThisAttack = false;
			break;
		case 'swing':
			game.phaseLen = game.swingLen;
			break;
		case 'recover':
			game.phaseLen = 420;
			break;
		case 'stagger':
			game.phaseLen = RULES.parryStaggerS * 1000;
			break;
		case 'dying':
			game.phaseLen = 1300;
			break;
		default:
			game.phaseLen = 500;
		}
	}

	function nextAttack() {
		/* From the second Hollow on, some attacks are feints and some come in pairs */
		const feintChance = game.level >= 2 ? 0.18 + 0.04 * game.level : 0;
		if (Math.random() < feintChance) { enter('feint'); return; }
		game.comboLeft = game.level >= 3 && Math.random() < 0.35 ? 1 : 0;
		enter('windup');
	}

	/* The visitor pressed the button */
	function press(timeStamp) {
		if (overlayState !== 'none') return;
		const now = timeStamp || performance.now();
		if (game.phase === 'stagger' && !game.riposted) {
			riposte();
			return;
		}
		if (now - game.lastPress < RULES.parryCooldownTicks * RULES.tickMs) {
			verdict(E.t('pt.v.cooldown'), '');
			return;
		}
		game.lastPress = now;
		game.shieldUp = 1;
		E.sound.play('swing', { volume: 0.25, rate: 1.3 });
		if (game.phase === 'windup' || game.phase === 'swing' || game.phase === 'feint') {
			game.pressedThisAttack = true;
			game.pressTime = now;
		} else if (game.phase === 'recover' && game.lateWindow && now - game.lastImpact < 260) {
			verdict(E.t('pt.v.late', { ms: Math.round(now - game.lastImpact) }), 'is-hit');
		}
	}

	function resolveImpact() {
		const now = performance.now();
		const windowMs = MODES[mode].windowMs;
		const lead = game.impactAt - game.pressTime;
		game.lastImpact = now;
		game.lateWindow = false;
		const contact = contactPoint();
		if (game.pressedThisAttack && lead >= -8 && lead <= windowMs) {
			/* PARRY */
			game.streak += 1;
			game.bestRun = Math.max(game.bestRun || 0, game.streak);
			if (game.streak > best) { best = game.streak; E.store.set('eldmark.parry.best', String(best)); }
			popup(E.t('pt.parry'), contact.x, contact.y - 40, '#f0d595', 1.25);
			sparks(contact.x, contact.y, 46, ['255,240,200', '255,200,110', '255,160,70']);
			game.flash = 0.8;
			game.flashColor = '255,236,190';
			game.slow = reduced ? 0 : 280;
			verdict(E.t('pt.v.parry', { ms: Math.max(0, Math.round(lead)) }), 'is-parry');
			E.sound.play('clash', { volume: 0.7 });
			game.comboLeft = 0;
			game.riposted = false;
			enter('stagger');
		} else if (game.pressedThisAttack && lead > windowMs) {
			/* Too early: the shield was up, so it is a block, paid in stamina */
			game.streak = 0;
			game.stamina -= BLOCK_STAMINA;
			if (game.stamina < 0) {
				game.stamina = 0;
				damage(rand(HIT_DAMAGE[0], HIT_DAMAGE[1]) * 0.8);
				popup(E.t('pt.guardbreak'), contact.x - 40, contact.y - 30, '#ff8b80', 1);
				verdict(E.t('pt.v.guardbreak'), 'is-hit');
			} else {
				popup(E.t('pt.blocked'), contact.x - 30, contact.y - 30, '#cfc6b2', 0.9);
				verdict(E.t('pt.v.early', { ms: Math.round(lead - windowMs) }), '');
			}
			sparks(contact.x, contact.y, 14, ['220,200,170', '255,190,120']);
			game.shake = 0.25;
			E.sound.play('block', { volume: 0.6 });
			afterHit();
		} else {
			/* Clean hit */
			game.streak = 0;
			const dmg = rand(HIT_DAMAGE[0], HIT_DAMAGE[1]);
			damage(dmg);
			popup(`-${Math.round(dmg)}`, contact.x - 60, contact.y - 10, '#ff8b80', 1.1);
			game.flash = 0.6;
			game.flashColor = '200,40,30';
			game.shake = 0.6;
			game.lateWindow = true;
			verdict(E.t('pt.v.none'), 'is-hit');
			E.sound.play('hit', { volume: 0.7 });
			afterHit();
		}
		updateScore();
	}

	function afterHit() {
		if (game.health <= 0) {
			game.health = 0;
			game.phase = 'down';
			setTimeout(() => showOverlay('down'), 700);
			return;
		}
		if (game.comboLeft > 0) {
			game.comboLeft -= 1;
			enter('recover');
			game.phaseLen = 120;
			game.chain = true;
		} else {
			game.chain = false;
			enter('recover');
		}
	}

	function damage(n) {
		game.health = Math.max(0, game.health - n);
	}

	function riposte() {
		game.riposted = true;
		game.lunge = 1;
		const dmg = RIPOSTE_DAMAGE + rand(-20, 40);
		game.enemyHealth = Math.max(0, game.enemyHealth - dmg);
		const c = enemyCenter();
		popup(`${E.t('pt.riposte')} -${Math.round(dmg)}`, c.x, c.y - 90, accentColor, 1);
		sparks(c.x - 20, c.y - 20, 18, ['255,140,90', '255,90,60']);
		verdict(E.t('pt.v.riposte'), 'is-parry');
		E.sound.play('hit', { volume: 0.6, rate: 0.9 });
		E.sound.play('heavy', { volume: 0.35 });
		if (game.enemyHealth <= 0) {
			game.kills += 1;
			popup(E.t('pt.fallen'), W * 0.5, H * 0.3, '#f0d595', 1.4);
			verdict(E.t('pt.v.fallen'), 'is-parry');
			enter('dying');
		}
		updateScore();
	}

	function verdict(text, cls) {
		verdictEl.textContent = text;
		verdictEl.className = 'pt-verdict' + (cls ? ' ' + cls : '');
	}

	function updateScore() {
		streakEl.textContent = game.streak;
		bestEl.textContent = best;
		killsEl.textContent = game.kills;
	}

	function popup(text, x, y, color, scale) {
		game.popups.push({ text, x, y, color, scale: scale || 1, age: 0 });
	}

	function sparks(x, y, n, colors) {
		const count = reduced ? Math.ceil(n / 3) : n;
		for (let i = 0; i < count; i++) {
			const a = rand(-Math.PI, Math.PI);
			const sp = rand(120, 520);
			game.sparks.push({
				x, y, vx: Math.cos(a) * sp, vy: Math.sin(a) * sp - 120,
				life: rand(0.25, 0.7), age: 0, c: colors[i % colors.length],
			});
		}
	}

	/* ---------------------------------------------------------------- simulation */
	function step(dtReal) {
		const scale = game.slow > 0 ? 0.25 : 1;
		game.slow = Math.max(0, game.slow - dtReal);
		const dt = dtReal * scale;
		game.t += dt;
		game.phaseT += dt;
		const k = game.phaseLen ? game.phaseT / game.phaseLen : 1;

		/* Stamina regenerates as in the game, a little after the last spend */
		game.stamina = Math.min(RULES.staminaMax, game.stamina + 0.18 * dtReal);
		game.shieldUp = Math.max(0, game.shieldUp - dtReal / 380);
		game.lunge = Math.max(0, game.lunge - dtReal / 320);
		game.shake = Math.max(0, game.shake - dtReal / 400);
		game.flash = Math.max(0, game.flash - dtReal / 360);

		/* Sword arm angle: guard 0.35 rad forward-down, raised to -2.3 rad at the top of the windup */
		switch (game.phase) {
		case 'ready':
			game.armAngle += (GUARD - game.armAngle) * 0.12;
			if (k >= 1) nextAttack();
			break;
		case 'windup': {
			/* Attacks run on the real clock, the same one the presses are stamped with, so a slow
			   frame can never move the moment of impact */
			const now = performance.now();
			const kr = (now - game.windupStartReal) / (game.windupEndReal - game.windupStartReal);
			const e = 1 - Math.pow(1 - clamp(kr, 0, 1), 2);
			game.armAngle = GUARD + (TOP - GUARD) * e;
			if (now >= game.windupEndReal) { game.phase = 'swing'; game.phaseT = 0; game.phaseLen = game.swingLen; }
			break;
		}
		case 'feint': {
			const half = k < 0.6 ? k / 0.6 : 1 - (k - 0.6) / 0.4;
			game.armAngle = GUARD + (FEINT_TOP - GUARD) * clamp(half, 0, 1);
			if (k >= 1) {
				if (game.pressedThisAttack) {
					popup(E.t('pt.feint'), enemyCenter().x, enemyCenter().y - 110, '#cfc6b2', 1);
					verdict(E.t('pt.v.feint'), '');
				}
				game.afterFeint = true;
				enter('windup');
			}
			break;
		}
		case 'swing': {
			const now = performance.now();
			const e = clamp((now - game.windupEndReal) / game.swingLen, 0, 1);
			game.armAngle = TOP + (GUARD - 0.25 - TOP) * (e * e);
			if (now >= game.impactAt) resolveImpact();
			break;
		}
		case 'recover':
			game.armAngle += (GUARD - game.armAngle) * 0.08;
			if (k >= 1) {
				if (game.chain) { game.chain = false; enter('windup'); } else enter('ready');
			}
			break;
		case 'stagger':
			game.armAngle += (STAGGERED - game.armAngle) * 0.1;
			game.stagger = Math.sin(clamp(k, 0, 1) * Math.PI);
			if (k >= 1) { game.stagger = 0; enter('ready'); }
			break;
		case 'dying':
			if (k >= 1) {
				game.level += 1;
				game.enemyMax = 1000 + (game.level - 1) * 150;
				game.enemyHealth = game.enemyMax;
				enter('ready');
				game.phaseLen = 900;
			}
			break;
		default:
			break;
		}

		for (let i = game.sparks.length - 1; i >= 0; i--) {
			const s = game.sparks[i];
			s.age += dtReal / 1000;
			s.vy += 900 * dtReal / 1000;
			s.vx *= 1 - 2 * dtReal / 1000;
			s.x += s.vx * dtReal / 1000;
			s.y += s.vy * dtReal / 1000;
			if (s.age > s.life) game.sparks.splice(i, 1);
		}
		for (let i = game.popups.length - 1; i >= 0; i--) {
			const p = game.popups[i];
			p.age += dtReal / 1000;
			if (p.age > 1.2) game.popups.splice(i, 1);
		}
		/* Drifting embers in the night air */
		if (game.motes.length < 26 && Math.random() < 0.3) {
			game.motes.push({ x: rand(0, W), y: H + 5, vy: rand(12, 30), vx: rand(-6, 6), life: rand(5, 10), age: 0, r: rand(0.8, 2) });
		}
		for (let i = game.motes.length - 1; i >= 0; i--) {
			const m = game.motes[i];
			m.age += dtReal / 1000;
			m.x += m.vx * dtReal / 1000;
			m.y -= m.vy * dtReal / 1000;
			if (m.age > m.life) game.motes.splice(i, 1);
		}
	}

	/* ---------------------------------------------------------------- drawing */
	function ground() { return H * 0.8; }
	function playerX() { return W * 0.37; }
	function enemyX() { return W * 0.37 + 182 * unit(); }
	function unit() { return H / 360; }
	function enemyCenter() { return { x: enemyX(), y: ground() - 120 * unit() }; }
	function contactPoint() { return { x: playerX() + 44 * unit(), y: ground() - 116 * unit() }; }

	function drawBackground() {
		const u = unit();
		const sky = ctx.createLinearGradient(0, 0, 0, H);
		sky.addColorStop(0, '#15131a');
		sky.addColorStop(0.55, '#1d1712');
		sky.addColorStop(1, '#0c0a09');
		ctx.fillStyle = sky;
		ctx.fillRect(0, 0, W, H);
		/* Moon behind clouds */
		const moon = ctx.createRadialGradient(W * 0.78, H * 0.2, 0, W * 0.78, H * 0.2, 120 * u);
		moon.addColorStop(0, 'rgba(230, 220, 200, 0.35)');
		moon.addColorStop(0.2, 'rgba(230, 220, 200, 0.12)');
		moon.addColorStop(1, 'rgba(230, 220, 200, 0)');
		ctx.fillStyle = moon;
		ctx.fillRect(0, 0, W, H);
		/* Palisade of the Vado Gris fort, far behind */
		ctx.fillStyle = '#141009';
		const stakeW = 14 * u;
		for (let x = -stakeW; x < W + stakeW; x += stakeW) {
			const h = (52 + ((x * 7.3) % 13)) * u;
			const y = ground() - 34 * u - h;
			ctx.beginPath();
			ctx.moveTo(x, ground() - 30 * u);
			ctx.lineTo(x, y + 8 * u);
			ctx.lineTo(x + stakeW / 2, y);
			ctx.lineTo(x + stakeW, y + 8 * u);
			ctx.lineTo(x + stakeW, ground() - 30 * u);
			ctx.fill();
		}
		/* Tower */
		ctx.fillRect(W * 0.86, ground() - 150 * u, 46 * u, 130 * u);
		ctx.beginPath();
		ctx.moveTo(W * 0.86 - 8 * u, ground() - 150 * u);
		ctx.lineTo(W * 0.86 + 23 * u, ground() - 182 * u);
		ctx.lineTo(W * 0.86 + 54 * u, ground() - 150 * u);
		ctx.fill();
		ctx.fillStyle = 'rgba(255, 170, 80, 0.5)';
		ctx.fillRect(W * 0.86 + 19 * u, ground() - 130 * u, 7 * u, 12 * u);
		/* Ground */
		const g = ctx.createLinearGradient(0, ground() - 20 * u, 0, H);
		g.addColorStop(0, '#221b14');
		g.addColorStop(1, '#0d0a08');
		ctx.fillStyle = g;
		ctx.fillRect(0, ground() - 20 * u, W, H);
		ctx.strokeStyle = 'rgba(201, 164, 92, 0.18)';
		ctx.lineWidth = 1;
		ctx.beginPath();
		ctx.moveTo(0, ground());
		ctx.lineTo(W, ground());
		ctx.stroke();
		/* Embers */
		ctx.globalCompositeOperation = 'lighter';
		for (const m of game.motes) {
			const a = Math.sin((m.age / m.life) * Math.PI) * 0.8;
			ctx.fillStyle = `rgba(255, 150, 70, ${a})`;
			ctx.beginPath();
			ctx.arc(m.x, m.y, m.r * u, 0, Math.PI * 2);
			ctx.fill();
		}
		ctx.globalCompositeOperation = 'source-over';
	}

	function drawShadow(x, w) {
		const u = unit();
		const s = ctx.createRadialGradient(x, ground() + 2 * u, 0, x, ground() + 2 * u, w);
		s.addColorStop(0, 'rgba(0, 0, 0, 0.6)');
		s.addColorStop(1, 'rgba(0, 0, 0, 0)');
		ctx.fillStyle = s;
		ctx.fillRect(x - w, ground() - 10 * u, w * 2, 24 * u);
	}

	/* The player: a knight with a round shield, facing right */
	function drawPlayer() {
		const u = unit();
		const x = playerX() + game.lunge * 40 * u;
		const gy = ground();
		drawShadow(x, 60 * u);
		ctx.save();
		ctx.translate(x, gy);
		const body = '#2a241e';
		const trim = accentColor;
		/* legs */
		ctx.fillStyle = '#1b1612';
		ctx.fillRect(-22 * u, -70 * u, 16 * u, 70 * u);
		ctx.fillRect(4 * u, -70 * u, 16 * u, 70 * u);
		/* torso */
		ctx.fillStyle = body;
		ctx.beginPath();
		ctx.moveTo(-34 * u, -150 * u);
		ctx.lineTo(30 * u, -150 * u);
		ctx.lineTo(24 * u, -66 * u);
		ctx.lineTo(-28 * u, -66 * u);
		ctx.closePath();
		ctx.fill();
		ctx.fillStyle = trim;
		ctx.globalAlpha = 0.85;
		ctx.fillRect(-28 * u, -96 * u, 52 * u, 6 * u);
		ctx.globalAlpha = 1;
		/* tabard trim */
		ctx.strokeStyle = 'rgba(255, 255, 255, 0.08)';
		ctx.lineWidth = 1;
		ctx.stroke();
		/* head and helm */
		ctx.fillStyle = '#3a332b';
		ctx.beginPath();
		ctx.arc(-2 * u, -168 * u, 17 * u, 0, Math.PI * 2);
		ctx.fill();
		ctx.fillStyle = '#0c0a09';
		ctx.fillRect(4 * u, -172 * u, 12 * u, 4 * u);
		/* sword, held low behind */
		ctx.save();
		ctx.translate(-14 * u, -104 * u);
		ctx.rotate(3.44 + game.lunge * 1.27);
		ctx.fillStyle = '#6b5a45';
		ctx.fillRect(-3 * u, -4 * u, 6 * u, 18 * u);
		ctx.fillStyle = '#c9c2b4';
		ctx.fillRect(-3 * u, 14 * u, 6 * u, 74 * u);
		ctx.restore();
		/* shield: raised when guarding */
		const raise = Math.max(game.shieldUp, game.phase === 'stagger' ? 0.4 : 0);
		const sx = (34 + raise * 16) * u;
		const sy = (-110 - raise * 22) * u;
		ctx.save();
		ctx.translate(sx, sy);
		const r = 34 * u;
		const sg = ctx.createRadialGradient(-8 * u, -8 * u, 0, 0, 0, r);
		sg.addColorStop(0, '#6a4a2c');
		sg.addColorStop(1, '#3a2716');
		ctx.fillStyle = sg;
		ctx.beginPath();
		ctx.ellipse(0, 0, r * 0.55, r, 0, 0, Math.PI * 2);
		ctx.fill();
		ctx.strokeStyle = trim;
		ctx.lineWidth = 3 * u;
		ctx.stroke();
		ctx.fillStyle = '#c9c2b4';
		ctx.beginPath();
		ctx.ellipse(2 * u, 0, 6 * u, 10 * u, 0, 0, Math.PI * 2);
		ctx.fill();
		if (raise > 0.05) {
			ctx.globalCompositeOperation = 'lighter';
			ctx.strokeStyle = `rgba(255, 220, 150, ${raise * 0.6})`;
			ctx.lineWidth = 6 * u;
			ctx.beginPath();
			ctx.ellipse(0, 0, r * 0.62, r * 1.08, 0, 0, Math.PI * 2);
			ctx.stroke();
			ctx.globalCompositeOperation = 'source-over';
		}
		ctx.restore();
		ctx.restore();
	}

	/* The Hollow: an undead soldier of Eld's old garrison, tall, ragged, eyes like coals */
	function drawHollow() {
		const u = unit();
		const dying = game.phase === 'dying' ? clamp(game.phaseT / game.phaseLen, 0, 1) : 0;
		const lean = game.stagger * 0.22 + dying * 0.9;
		const x = enemyX() + game.stagger * 18 * u;
		const gy = ground();
		drawShadow(x, 70 * u);
		ctx.save();
		ctx.globalAlpha = 1 - dying * 0.85;
		ctx.translate(x, gy);
		ctx.rotate(lean * 0.4);
		const bone = '#bdb6a6';
		/* cloak, tattered */
		ctx.fillStyle = '#1a1714';
		ctx.beginPath();
		ctx.moveTo(-30 * u, -168 * u);
		ctx.lineTo(38 * u, -168 * u);
		const t = game.t / 1000;
		for (let i = 0; i <= 6; i++) {
			const px = 46 * u - i * 15 * u;
			const py = (-8 - (i % 2) * 18 + Math.sin(t * 2 + i) * 4) * u;
			ctx.lineTo(px, py);
		}
		ctx.closePath();
		ctx.fill();
		/* legs */
		ctx.fillStyle = '#2b2722';
		ctx.fillRect(-16 * u, -64 * u, 14 * u, 64 * u);
		ctx.fillRect(8 * u, -64 * u, 14 * u, 64 * u);
		/* armor */
		ctx.fillStyle = '#4a463e';
		ctx.beginPath();
		ctx.moveTo(-28 * u, -170 * u);
		ctx.lineTo(32 * u, -170 * u);
		ctx.lineTo(26 * u, -76 * u);
		ctx.lineTo(-22 * u, -76 * u);
		ctx.closePath();
		ctx.fill();
		ctx.strokeStyle = 'rgba(189, 182, 166, 0.35)';
		ctx.lineWidth = 1.5 * u;
		for (let i = 0; i < 4; i++) {
			ctx.beginPath();
			ctx.moveTo(-20 * u, (-150 + i * 18) * u);
			ctx.lineTo(24 * u, (-150 + i * 18) * u);
			ctx.stroke();
		}
		/* pauldron */
		ctx.fillStyle = bone;
		ctx.beginPath();
		ctx.ellipse(-24 * u, -166 * u, 20 * u, 12 * u, -0.3, 0, Math.PI * 2);
		ctx.fill();
		/* helm with a broken crown */
		ctx.fillStyle = '#5d584f';
		ctx.beginPath();
		ctx.arc(0, -190 * u, 19 * u, 0, Math.PI * 2);
		ctx.fill();
		ctx.fillStyle = bone;
		ctx.beginPath();
		ctx.moveTo(-18 * u, -200 * u);
		ctx.lineTo(-16 * u, -224 * u);
		ctx.lineTo(-8 * u, -208 * u);
		ctx.lineTo(-1 * u, -230 * u);
		ctx.lineTo(4 * u, -210 * u);
		ctx.lineTo(9 * u, -216 * u);
		ctx.lineTo(18 * u, -200 * u);
		ctx.closePath();
		ctx.fill();
		/* eyes */
		const glow = game.phase === 'windup' ? 1 : 0.65;
		ctx.globalCompositeOperation = 'lighter';
		for (const ex of [-12, -2]) {
			const eg = ctx.createRadialGradient(ex * u, -190 * u, 0, ex * u, -190 * u, 12 * u);
			eg.addColorStop(0, `rgba(255, 190, 110, ${glow})`);
			eg.addColorStop(1, 'rgba(255, 120, 40, 0)');
			ctx.fillStyle = eg;
			ctx.fillRect((ex - 12) * u, -202 * u, 24 * u, 24 * u);
		}
		ctx.globalCompositeOperation = 'source-over';
		/* sword arm: pivot at the shoulder, the blade swings toward the player (left) */
		ctx.save();
		ctx.translate(-22 * u, -160 * u);
		ctx.rotate(game.armAngle);
		ctx.fillStyle = '#4a463e';
		ctx.fillRect(0, -6 * u, 40 * u, 12 * u);
		ctx.fillStyle = '#6b5a45';
		ctx.fillRect(38 * u, -14 * u, 6 * u, 28 * u);
		const blade = ctx.createLinearGradient(44 * u, 0, 150 * u, 0);
		blade.addColorStop(0, '#9c968a');
		blade.addColorStop(1, '#dcd6c8');
		ctx.fillStyle = blade;
		ctx.beginPath();
		ctx.moveTo(44 * u, -5 * u);
		ctx.lineTo(146 * u, -3 * u);
		ctx.lineTo(156 * u, 0);
		ctx.lineTo(146 * u, 3 * u);
		ctx.lineTo(44 * u, 5 * u);
		ctx.closePath();
		ctx.fill();
		/* Telegraph: a glint at the tip at the start of each windup */
		if ((game.phase === 'windup' || game.phase === 'feint') && game.phaseT < 260) {
			const a = 1 - game.phaseT / 260;
			ctx.globalCompositeOperation = 'lighter';
			const gl = ctx.createRadialGradient(150 * u, 0, 0, 150 * u, 0, 30 * u);
			gl.addColorStop(0, `rgba(255, 255, 240, ${a})`);
			gl.addColorStop(1, 'rgba(255, 220, 160, 0)');
			ctx.fillStyle = gl;
			ctx.fillRect(120 * u, -30 * u, 60 * u, 60 * u);
			ctx.globalCompositeOperation = 'source-over';
		}
		ctx.restore();
		ctx.restore();
		/* Swing trail */
		if (game.phase === 'swing') {
			ctx.save();
			ctx.translate(x - 22 * u, gy - 160 * u);
			ctx.strokeStyle = 'rgba(255, 230, 200, 0.35)';
			ctx.lineWidth = 10 * u;
			ctx.lineCap = 'round';
			ctx.beginPath();
			ctx.arc(0, 0, 150 * u, game.armAngle, TOP);
			ctx.stroke();
			ctx.restore();
		}
	}

	function bar(x, y, w, h, k, color, label) {
		ctx.fillStyle = 'rgba(0, 0, 0, 0.55)';
		ctx.fillRect(x - 1, y - 1, w + 2, h + 2);
		ctx.fillStyle = color;
		ctx.fillRect(x, y, w * clamp(k, 0, 1), h);
		ctx.strokeStyle = 'rgba(201, 164, 92, 0.4)';
		ctx.lineWidth = 1;
		ctx.strokeRect(x - 0.5, y - 0.5, w + 1, h + 1);
		if (label) {
			ctx.fillStyle = '#ece3cf';
			ctx.font = `600 ${Math.max(9, h * 0.8)}px ${getComputedStyle(document.body).fontFamily}`;
			ctx.textAlign = 'center';
			ctx.textBaseline = 'middle';
			ctx.fillText(label, x + w / 2, y + h / 2 + 0.5);
		}
	}

	function drawHud() {
		const u = unit();
		const display = "'Cinzel', Georgia, serif";
		/* Player bars, like the game HUD */
		const bw = Math.min(220 * u, W * 0.34);
		const bx = 16 * u;
		bar(bx, H - 34 * u, bw, 11 * u, game.health / RULES.healthMax, '#c0322a', `${Math.round(game.health)} / ${RULES.healthMax}`);
		bar(bx, H - 19 * u, bw, 5 * u, game.stamina / RULES.staminaMax, '#d9b44a');
		/* Enemy bar */
		const ew = Math.min(160 * u, W * 0.26);
		const ec = enemyCenter();
		const ey = ground() - 252 * u;
		bar(ec.x - ew / 2, ey, ew, 6 * u, game.enemyHealth / game.enemyMax, '#bdb6a6');
		ctx.fillStyle = '#a99e89';
		ctx.font = `600 ${10 * u}px ${display}`;
		ctx.textAlign = 'left';
		ctx.textBaseline = 'middle';
		ctx.fillText(`${E.t('pt.hollow')} ${toRoman(game.level)}`, ec.x + ew / 2 + 8 * u, ey + 3 * u);

		/* Incoming-attack arc over the player, as in the game */
		if (game.phase === 'windup' || game.phase === 'swing' || game.phase === 'feint') {
			const now = performance.now();
			const total = game.impactAt - game.windupStartReal;
			const left = game.phase === 'feint' ? 1 : clamp((game.impactAt - now) / total, 0, 1);
			const cx = playerX();
			const cy = ground() - 214 * u;
			ctx.strokeStyle = `rgba(220, 60, 50, ${0.35 + 0.65 * (1 - left)})`;
			ctx.lineWidth = 5 * u;
			ctx.lineCap = 'round';
			const span = 1.1 * (0.3 + 0.7 * (1 - left));
			ctx.beginPath();
			ctx.arc(cx, cy + 60 * u, 60 * u, -Math.PI / 2 - span / 2 + 0.25, -Math.PI / 2 + span / 2 + 0.25);
			ctx.stroke();
		}

		/* Squire timing bar: the time to the hit, with the parry window in gold */
		if (MODES[mode].bar && (game.phase === 'windup' || game.phase === 'swing')) {
			const now = performance.now();
			const horizon = 1100;
			const w = Math.min(W * 0.56, 420 * u);
			const x0 = W / 2 - w / 2;
			const y0 = 10 * u;
			const h = 7 * u;
			ctx.fillStyle = 'rgba(0, 0, 0, 0.55)';
			ctx.fillRect(x0, y0, w, h);
			const winW = (MODES[mode].windowMs / horizon) * w;
			ctx.fillStyle = 'rgba(240, 213, 149, 0.85)';
			ctx.fillRect(x0, y0, winW, h);
			const toHit = game.impactAt - now;
			const mx = x0 + clamp(toHit / horizon, 0, 1) * w;
			ctx.fillStyle = '#ff6b4a';
			ctx.fillRect(mx - 2 * u, y0 - 4 * u, 4 * u, h + 8 * u);
			ctx.strokeStyle = 'rgba(201, 164, 92, 0.45)';
			ctx.strokeRect(x0 - 0.5, y0 - 0.5, w + 1, h + 1);
		}
	}

	function drawEffects() {
		const u = unit();
		ctx.globalCompositeOperation = 'lighter';
		for (const s of game.sparks) {
			const a = 1 - s.age / s.life;
			ctx.strokeStyle = `rgba(${s.c}, ${a})`;
			ctx.lineWidth = 2 * u;
			ctx.beginPath();
			ctx.moveTo(s.x, s.y);
			ctx.lineTo(s.x - s.vx * 0.025, s.y - s.vy * 0.025);
			ctx.stroke();
		}
		ctx.globalCompositeOperation = 'source-over';
		for (const p of game.popups) {
			const k = p.age / 1.2;
			const pop = k < 0.12 ? 0.6 + (k / 0.12) * 0.55 : 1.15 - Math.min(0.15, (k - 0.12) * 0.5);
			ctx.save();
			ctx.translate(p.x, p.y - k * 30 * u);
			ctx.scale(pop * p.scale, pop * p.scale);
			ctx.globalAlpha = k > 0.7 ? 1 - (k - 0.7) / 0.3 : 1;
			ctx.font = `800 ${24 * u}px 'Cinzel', Georgia, serif`;
			ctx.textAlign = 'center';
			ctx.textBaseline = 'middle';
			ctx.lineWidth = 4 * u;
			ctx.strokeStyle = 'rgba(0, 0, 0, 0.75)';
			ctx.strokeText(p.text.toUpperCase(), 0, 0);
			ctx.fillStyle = p.color;
			ctx.fillText(p.text.toUpperCase(), 0, 0);
			ctx.restore();
		}
		ctx.globalAlpha = 1;
		if (game.flash > 0) {
			ctx.fillStyle = `rgba(${game.flashColor}, ${game.flash * 0.32})`;
			ctx.fillRect(0, 0, W, H);
		}
		/* Vignette */
		const v = ctx.createRadialGradient(W / 2, H / 2, Math.min(W, H) * 0.35, W / 2, H / 2, Math.max(W, H) * 0.75);
		v.addColorStop(0, 'rgba(0, 0, 0, 0)');
		v.addColorStop(1, 'rgba(0, 0, 0, 0.6)');
		ctx.fillStyle = v;
		ctx.fillRect(0, 0, W, H);
	}

	function draw() {
		ctx.save();
		if (game.shake > 0 && !reduced) ctx.translate(rand(-1, 1) * 10 * game.shake, rand(-1, 1) * 6 * game.shake);
		drawBackground();
		drawHollow();
		drawPlayer();
		drawHud();
		drawEffects();
		ctx.restore();
	}

	function frame(now) {
		if (!running) return;
		const dt = Math.min(50, now - last || 16);
		last = now;
		if (overlayState === 'none' && game.phase !== 'down') step(dt);
		else game.t += dt * 0.3;
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
		const fit = E.fitCanvas(canvas);
		ctx = fit.ctx;
		W = fit.w;
		H = fit.h;
		if (!running) draw();
	}

	/* ---------------------------------------------------------------- input */
	stage.addEventListener('pointerdown', (e) => {
		if (overlayState !== 'none') return;
		if (e.target.closest('.pt-overlay')) return;
		e.preventDefault();
		stage.focus({ preventScroll: true });
		const ts = e.timeStamp;
		press(ts > 0 && ts <= performance.now() + 5 ? ts : performance.now());
	});
	stage.addEventListener('contextmenu', (e) => e.preventDefault());
	stage.addEventListener('keydown', (e) => {
		if (e.code === 'Space' || e.code === 'KeyK' || e.code === 'Enter') {
			if (overlayState !== 'none') {
				if (e.code !== 'Space') return;
				e.preventDefault();
				overlayBtn.click();
				return;
			}
			e.preventDefault();
			if (!e.repeat) press(performance.now());
		} else if (e.code === 'Escape' && overlayState === 'none' && game.phase !== 'down') {
			showOverlay('paused');
		}
	});
	tapBtn.addEventListener('pointerdown', (e) => { e.preventDefault(); press(performance.now()); });
	overlayBtn.addEventListener('click', () => {
		if (overlayState === 'paused') {
			showOverlay('none');
			stage.focus({ preventScroll: true });
		} else {
			newGame();
		}
	});
	modeBtns.forEach((b) => b.addEventListener('click', () => {
		setMode(b.dataset.mode);
		E.sound.play('click', { volume: 0.4 });
	}));

	E.on('lang', () => {
		E.applyI18n(mount);
		if (overlayState !== 'none') showOverlay(overlayState);
	});
	E.on('realm', () => { accentColor = accent(); if (!running) draw(); });

	let visible = false;
	E.whenVisible(stage, () => {
		visible = true;
		if (!document.hidden) start();
	}, () => {
		visible = false;
		if (overlayState === 'none' && game.phase !== 'down') showOverlay('paused');
		stop();
	});
	document.addEventListener('visibilitychange', () => {
		if (document.hidden) {
			if (overlayState === 'none' && game.phase !== 'down') showOverlay('paused');
			stop();
		} else if (visible) start();
	});
	if ('ResizeObserver' in window) new ResizeObserver(resize).observe(stage);
	else window.addEventListener('resize', resize);

	setMode(mode);
	E.applyI18n(mount);
	showOverlay('start');
	updateScore();
	resize();
})();
