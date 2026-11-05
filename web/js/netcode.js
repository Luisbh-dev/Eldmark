/*
 * Eldmark netcode lab. Mounts into #netcode-lab and shows, with the real numbers of the game,
 * how an authoritative server with client-side prediction, interpolation and lag compensation works.
 *
 * Model (one shared clock, a fixed 60 Hz tick loop driven by an accumulator):
 *   - Client: samples input every tick, predicts its own movement (optional), sends the last two inputs
 *     every 2 ticks. Keeps an input history to replay after a reconciliation.
 *   - Server: applies the inputs when they arrive (repeating the last input over lost ones), keeps a
 *     40-tick history of the enemy, sends a snapshot every 2 ticks (30 Hz).
 *   - Wire: packets carry timestamps; one-way delay = RTT / 2; unreliable packets are dropped with the
 *     packet loss probability. Strike intents and verdicts are treated as reliable.
 *   - Strike: the intent carries the render time the player saw; the server rewinds the enemy to that
 *     time and rejects the strike when the rewind exceeds 24 ticks (400 ms).
 * Everything is drawn on one canvas; the controls, readout and captions are plain DOM.
 */
(function () {
	'use strict';

	const E = window.Eldmark;
	const mount = document.getElementById('netcode-lab');
	if (!E || !mount) return;

	/* ---------- Strings ---------- */
	E.addStrings({
		en: {
			'nc.client': 'Your screen',
			'nc.clientSub': 'client',
			'nc.server': 'The server',
			'nc.serverSub': 'truth',
			'nc.wireUp': 'inputs',
			'nc.wireDown': 'snapshots',
			'nc.timeline': 'ticks 60 Hz · snapshots 30 Hz',
			'nc.interpZone': 'interpolation delay',
			'nc.you': 'you',
			'nc.enemy': 'enemy',
			'nc.youServer': 'you (server copy)',
			'nc.enemyServer': 'enemy now',
			'nc.ghost': 'rewound {ms} ms',
			'nc.reconciled': 'reconciled',
			'nc.inputDelay': 'input delay: {ms} ms',
			'nc.inputDelayPredicted': 'input delay: 0 ms (predicted)',
			'nc.latency': 'Latency (RTT)',
			'nc.loss': 'Packet loss',
			'nc.prediction': 'Prediction',
			'nc.interpolation': 'Interpolation',
			'nc.lagComp': 'Lag compensation',
			'nc.strike': 'Strike',
			'nc.autopilot': 'Autopilot',
			'nc.on': 'on',
			'nc.off': 'off',
			'nc.hint': 'Click the arena (or Tab to it), then move with WASD or the arrow keys and strike with Space. On a touch screen, drag to steer and tap to strike. Without input, the autopilot plays for you.',
			'nc.stageLabel': 'Netcode arena. Keyboard controls: WASD or arrows to move, Space to strike.',
			'nc.r.rtt': 'Round trip',
			'nc.r.oneWay': 'One way',
			'nc.r.interp': 'Interpolation delay',
			'nc.r.rewind': 'Last rewind',
			'nc.r.inputDelay': 'Input delay',
			'nc.r.ticks': 'Ticks per second',
			'nc.r.snaps': 'Snapshots per second',
			'nc.r.none': 'none yet',
			'nc.r.off': 'off',
			'nc.r.predicted': '0 ms (predicted)',
			'nc.ms': '{ms} ms',
			'nc.msTicks': '{ms} ms ({ticks} ticks)',
			'nc.verdict.none': 'Strike an enemy to see what the server decides.',
			'nc.verdict.sent': 'Strike sent, waiting for the server…',
			'nc.verdict.hit': 'Hit confirmed — rewound {ms} ms',
			'nc.verdict.miss': 'Miss — nothing in reach {ms} ms ago',
			'nc.verdict.rejected': 'Rejected — {ms} ms is beyond the 400 ms rewind cap (24 ticks)',
			'nc.cap.pred.on': 'Your knight moves the instant you press a key. The server replays the same inputs {ms} ms later; if a snapshot disagrees (a lost packet, say), the client jumps back to the server state and re-simulates your pending inputs: the “reconciled” flash.',
			'nc.cap.pred.off': 'Your knight only moves when a snapshot comes back, so every key press feels {ms} ms late. This is what a game without prediction feels like.',
			'nc.cap.interp.on': 'Other players are drawn {ms} ms in the past, between two snapshots (the faint dots). Movement stays smooth; the price is a slightly older picture, and packet loss makes the delay grow (4 to 12 ticks).',
			'nc.cap.interp.off': 'The enemy jumps to each snapshot as it arrives: 30 updates per second, and a lost packet freezes it and then makes it jump.',
			'nc.cap.lag': 'When you strike, the server rewinds the enemy’s hitbox to what your screen showed, about {ms} ms ago (round trip plus interpolation delay). It never rewinds more than 400 ms (24 ticks), so a laggy attacker cannot hit what left long ago.',
			'nc.aria': 'Netcode simulation. Round trip {rtt} ms, packet loss {loss} %, prediction {pred}, interpolation {interp}. Last strike: {last}',
		},
		es: {
			'nc.client': 'Tu pantalla',
			'nc.clientSub': 'cliente',
			'nc.server': 'El servidor',
			'nc.serverSub': 'la verdad',
			'nc.wireUp': 'entradas',
			'nc.wireDown': 'instantáneas',
			'nc.timeline': 'ticks 60 Hz · instantáneas 30 Hz',
			'nc.interpZone': 'retardo de interpolación',
			'nc.you': 'tú',
			'nc.enemy': 'enemigo',
			'nc.youServer': 'tú (copia del servidor)',
			'nc.enemyServer': 'enemigo ahora',
			'nc.ghost': 'rebobinado {ms} ms',
			'nc.reconciled': 'reconciliado',
			'nc.inputDelay': 'retardo de entrada: {ms} ms',
			'nc.inputDelayPredicted': 'retardo de entrada: 0 ms (predicho)',
			'nc.latency': 'Latencia (RTT)',
			'nc.loss': 'Pérdida de paquetes',
			'nc.prediction': 'Predicción',
			'nc.interpolation': 'Interpolación',
			'nc.lagComp': 'Compensación de latencia',
			'nc.strike': 'Golpear',
			'nc.autopilot': 'Piloto automático',
			'nc.on': 'activada',
			'nc.off': 'desactivada',
			'nc.hint': 'Haz clic en la arena (o llega con Tab) y muévete con WASD o las flechas; golpea con la barra espaciadora. En pantalla táctil, arrastra para moverte y toca para golpear. Si no tocas nada, juega el piloto automático.',
			'nc.stageLabel': 'Arena de netcode. Controles de teclado: WASD o flechas para moverse, espacio para golpear.',
			'nc.r.rtt': 'Ida y vuelta',
			'nc.r.oneWay': 'Solo ida',
			'nc.r.interp': 'Retardo de interpolación',
			'nc.r.rewind': 'Último rebobinado',
			'nc.r.inputDelay': 'Retardo de entrada',
			'nc.r.ticks': 'Ticks por segundo',
			'nc.r.snaps': 'Instantáneas por segundo',
			'nc.r.none': 'aún ninguno',
			'nc.r.off': 'desactivado',
			'nc.r.predicted': '0 ms (predicho)',
			'nc.ms': '{ms} ms',
			'nc.msTicks': '{ms} ms ({ticks} ticks)',
			'nc.verdict.none': 'Golpea a un enemigo para ver qué decide el servidor.',
			'nc.verdict.sent': 'Golpe enviado, esperando al servidor…',
			'nc.verdict.hit': 'Impacto confirmado — rebobinado {ms} ms',
			'nc.verdict.miss': 'Fallo — no había nadie al alcance hace {ms} ms',
			'nc.verdict.rejected': 'Rechazado — {ms} ms supera el límite de rebobinado de 400 ms (24 ticks)',
			'nc.cap.pred.on': 'Tu caballero se mueve en cuanto pulsas una tecla. El servidor repite las mismas entradas {ms} ms después; si una instantánea no coincide (un paquete perdido, por ejemplo), el cliente vuelve al estado del servidor y vuelve a simular tus entradas pendientes: el destello «reconciliado».',
			'nc.cap.pred.off': 'Tu caballero solo se mueve cuando vuelve una instantánea, así que cada pulsación llega {ms} ms tarde. Así se siente un juego sin predicción.',
			'nc.cap.interp.on': 'Los demás jugadores se dibujan {ms} ms en el pasado, entre dos instantáneas (los puntos tenues). El movimiento sigue siendo fluido; el precio es una imagen algo más vieja, y la pérdida de paquetes alarga el retardo (de 4 a 12 ticks).',
			'nc.cap.interp.off': 'El enemigo salta a cada instantánea en cuanto llega: 30 actualizaciones por segundo, y un paquete perdido lo congela y luego lo hace saltar.',
			'nc.cap.lag': 'Cuando golpeas, el servidor rebobina la hitbox del enemigo a lo que mostraba tu pantalla, hace unos {ms} ms (ida y vuelta más retardo de interpolación). Nunca rebobina más de 400 ms (24 ticks), así que un atacante con mucho lag no puede golpear lo que se fue hace tiempo.',
			'nc.aria': 'Simulación de netcode. Ida y vuelta {rtt} ms, pérdida de paquetes {loss} %, predicción {pred}, interpolación {interp}. Último golpe: {last}',
		},
	});
	const t = (k, v) => E.t(k, v);

	/* ---------- Constants ---------- */
	const TICK_MS = 1000 / 60;
	const SNAP_EVERY = 2;
	const WORLD_W = 160;
	const WORLD_H = 100;
	const ASPECT = WORLD_W / WORLD_H;
	const REACH = 17;
	const PLAYER_R = 6.5;
	const SPEED = 38 / 60; // world units per tick
	const REWIND_CAP_MS = 24 * TICK_MS; // 400 ms
	const HIST_TICKS = 40;
	const TIMELINE_MS = 520;
	const TAU = Math.PI * 2;

	/* ---------- DOM ---------- */
	function el(tag, cls, attrs) {
		const n = document.createElement(tag);
		if (cls) n.className = cls;
		if (attrs) for (const k in attrs) n.setAttribute(k, attrs[k]);
		return n;
	}
	function i18nText(tag, cls, key) {
		const n = el(tag, cls);
		n.dataset.i18n = key;
		return n;
	}

	mount.textContent = '';
	const lab = el('div', 'nc-lab');
	const stage = el('div', 'nc-stage', { tabindex: '0', role: 'group' });
	stage.setAttribute('data-i18n-attr', 'aria-label:nc.stageLabel');
	const canvas = el('canvas', 'nc-canvas', { role: 'img' });
	stage.appendChild(canvas);
	const hint = i18nText('p', 'nc-hint', 'nc.hint');

	const controls = el('div', 'nc-controls');
	function slider(id, key, min, max, step, value, unit) {
		const wrap = el('div', 'nc-field');
		const label = el('label', 'nc-field-label', { for: id });
		label.dataset.i18n = key;
		const out = el('output', 'nc-field-value', { for: id });
		const input = el('input', 'nc-range', { type: 'range', id: id, min: min, max: max, step: step, value: value });
		const head = el('div', 'nc-field-head');
		head.append(label, out);
		wrap.append(head, input);
		controls.appendChild(wrap);
		return { input, out, unit };
	}
	function toggle(id, key, checked) {
		const label = el('label', 'nc-switch', { for: id });
		const input = el('input', 'nc-switch-input', { type: 'checkbox', id: id });
		input.checked = checked;
		const ui = el('span', 'nc-switch-ui', { 'aria-hidden': 'true' });
		const name = i18nText('span', 'nc-switch-name', key);
		const state = el('span', 'nc-switch-state');
		label.append(input, ui, name, state);
		controls.appendChild(label);
		return { input, state };
	}
	const latencyCtl = slider('nc-latency', 'nc.latency', 0, 400, 10, 120, 'ms');
	const lossCtl = slider('nc-loss', 'nc.loss', 0, 20, 1, 0, '%');
	const predCtl = toggle('nc-pred', 'nc.prediction', true);
	const interpCtl = toggle('nc-interp', 'nc.interpolation', true);
	const autoCtl = toggle('nc-auto', 'nc.autopilot', true);
	const strikeBtn = el('button', 'nc-strike', { type: 'button' });
	strikeBtn.append(i18nText('span', 'nc-strike-label', 'nc.strike'), Object.assign(el('kbd', 'nc-kbd'), { textContent: 'Space' }));
	controls.appendChild(strikeBtn);

	const verdictLine = el('p', 'nc-verdict', { 'aria-live': 'polite', role: 'status' });
	const readout = el('dl', 'nc-readout');
	const readoutEls = {};
	for (const [id, key] of [['rtt', 'nc.r.rtt'], ['oneWay', 'nc.r.oneWay'], ['interp', 'nc.r.interp'], ['rewind', 'nc.r.rewind'], ['inputDelay', 'nc.r.inputDelay'], ['ticks', 'nc.r.ticks'], ['snaps', 'nc.r.snaps']]) {
		const box = el('div', 'nc-readout-item');
		const dt = i18nText('dt', 'nc-readout-label', key);
		const dd = el('dd', 'nc-readout-value');
		box.append(dt, dd);
		readout.appendChild(box);
		readoutEls[id] = dd;
	}

	const captions = el('div', 'nc-captions');
	const capEls = {};
	for (const [id, key] of [['pred', 'nc.prediction'], ['interp', 'nc.interpolation'], ['lag', 'nc.lagComp']]) {
		const box = el('article', 'nc-cap');
		box.append(i18nText('h3', 'nc-cap-title', key), el('p', 'nc-cap-text'));
		captions.appendChild(box);
		capEls[id] = box;
	}

	lab.append(stage, hint, controls, verdictLine, readout, captions);
	mount.appendChild(lab);

	/* ---------- Settings and simulation state ---------- */
	const cfg = { rtt: 120, loss: 0, pred: true, interp: true, auto: true };
	const keys = new Set();
	const pointer = { down: false, dragged: false, x: 0, y: 0, sx: 0, sy: 0, st: 0, tx: null, ty: null };

	let simTick = 0;
	let simNow = 0;
	let acc = 0;
	let cpos, spos, ap;
	let face = { x: 1, y: 0 };
	let inputHist = [];
	let serverLastTick = -1;
	let serverLastDir = { x: 0, y: 0 };
	let packets = [];
	let snaps = [];
	let enemyHist = [];
	let delayTotal = 0;
	let inputDelay = 0;
	let lastManual = -1e9;
	let lastStrike = -1e9;
	let apActive = false;
	let swing = null;
	let reconFlash = -1e9;
	let burst = null;
	let serverEvent = null;
	let clientEvent = null;
	let lastRewind = null;
	let lastVerdictText = '';
	let lastVerdictKind = '';
	let activeCap = 'pred';
	let authPos = null;

	const enemyTimeScale = E.reducedMotion ? 0.4 : 1;
	function enemyAtTick(n) {
		const s = (n / 60) * enemyTimeScale;
		return { x: WORLD_W / 2 + 58 * Math.sin(0.31 * s + 0.5), y: WORLD_H / 2 + 33 * Math.sin(0.47 * s) };
	}

	const oneWay = () => cfg.rtt / 2;
	function interpTicks() {
		const jitterTicks = 1 + cfg.loss * 0.25;
		return Math.max(4, Math.min(12, Math.round(4 + 2 * jitterTicks)));
	}
	const interpMs = () => interpTicks() * TICK_MS;

	function applyMove(pos, dx, dy) {
		pos.x = Math.max(PLAYER_R, Math.min(WORLD_W - PLAYER_R, pos.x + dx * SPEED));
		pos.y = Math.max(PLAYER_R, Math.min(WORLD_H - PLAYER_R, pos.y + dy * SPEED));
	}
	const dist = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);

	/* Samples a time-sorted list of {time, x, y} at time T (clamped to its ends). */
	function sample(list, T) {
		if (!list.length) return null;
		if (T <= list[0].time) return { x: list[0].x, y: list[0].y, time: list[0].time, a: list[0], b: list[0] };
		const last = list[list.length - 1];
		if (T >= last.time) return { x: last.x, y: last.y, time: last.time, a: last, b: last };
		for (let i = 0; i < list.length - 1; i++) {
			const a = list[i], b = list[i + 1];
			if (T >= a.time && T < b.time) {
				const k = (T - a.time) / (b.time - a.time);
				return { x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k, time: T, a: a, b: b };
			}
		}
		return { x: last.x, y: last.y, time: last.time, a: last, b: last };
	}

	/* What the client shows for the enemy at wall time tNow (ms). */
	function enemyView(tNow) {
		if (!snaps.length) return null;
		const newest = snaps[snaps.length - 1];
		if (!cfg.interp) return { x: newest.x, y: newest.y, time: newest.time, a: newest, b: newest, snapped: true };
		return sample(snaps, tNow - delayTotal);
	}

	/* ---------- Wire ---------- */
	function send(kind, up, data, reliable) {
		const ow = oneWay();
		const p = { kind: kind, up: up, t0: simNow, t1: simNow + ow, data: data, dropped: false, dropAt: 0.3 + Math.random() * 0.4 };
		if (!reliable && Math.random() * 100 < cfg.loss) p.dropped = true;
		packets.push(p);
	}

	function deliver() {
		const rest = [];
		for (const p of packets) {
			if (p.t1 <= simNow) {
				if (!p.dropped) handle(p);
			} else {
				rest.push(p);
			}
		}
		packets = rest;
	}

	function handle(p) {
		if (p.kind === 'in') serverReceiveInputs(p.data);
		else if (p.kind === 'snap') clientReceiveSnapshot(p.data);
		else if (p.kind === 'strike') serverReceiveStrike(p.data);
		else if (p.kind === 'verdict') clientReceiveVerdict(p.data);
	}

	/* ---------- Server ---------- */
	function serverReceiveInputs(list) {
		for (const inp of list) {
			if (inp.tick <= serverLastTick) continue;
			// A gap means the input packet in between was lost: the server repeats the last input.
			for (let k = serverLastTick + 1; k < inp.tick && serverLastTick >= 0; k++) applyMove(spos, serverLastDir.x, serverLastDir.y);
			applyMove(spos, inp.x, inp.y);
			serverLastDir = { x: inp.x, y: inp.y };
			serverLastTick = inp.tick;
		}
	}

	function serverTick() {
		const e = enemyAtTick(simTick);
		enemyHist.push({ time: simNow, x: e.x, y: e.y });
		if (enemyHist.length > HIST_TICKS) enemyHist.shift();
		if (simTick % SNAP_EVERY === 0) {
			send('snap', false, { time: simNow, x: e.x, y: e.y, px: spos.x, py: spos.y, ack: serverLastTick }, false);
		}
	}

	function serverReceiveStrike(d) {
		const ms = simNow - d.displayTime;
		let kind, ghost;
		if (ms > REWIND_CAP_MS) {
			kind = 'rejected';
			ghost = enemyAtTick(d.displayTime / TICK_MS);
		} else {
			const s = sample(enemyHist, d.displayTime);
			ghost = { x: s.x, y: s.y };
			kind = dist(ghost, { x: d.px, y: d.py }) <= REACH + 2 ? 'hit' : 'miss';
		}
		lastRewind = ms;
		serverEvent = { until: simNow + 2200, start: simNow, ghost: ghost, ms: Math.round(ms), kind: kind, player: { x: d.px, y: d.py } };
		send('verdict', false, { kind: kind, ms: Math.round(ms) }, true);
	}

	/* ---------- Client ---------- */
	function clientReceiveSnapshot(s) {
		if (snaps.length && s.time <= snaps[snaps.length - 1].time && snaps.some((q) => q.time === s.time)) return;
		snaps.push({ time: s.time, x: s.x, y: s.y });
		snaps.sort((a, b) => a.time - b.time);
		while (snaps.length > 40) snaps.shift();
		const server = { x: s.px, y: s.py };
		authPos = { x: s.px, y: s.py };
		if (cfg.pred) {
			const p = { x: server.x, y: server.y };
			for (const inp of inputHist) if (inp.tick > s.ack) applyMove(p, inp.x, inp.y);
			if (dist(p, cpos) > 0.6) reconFlash = simNow;
			cpos = p;
		} else {
			cpos = { x: server.x, y: server.y };
		}
		const mine = inputHist.find((i) => i.tick === s.ack);
		if (mine) inputDelay += (simNow - mine.t - inputDelay) * 0.25;
		inputHist = inputHist.filter((i) => i.tick >= s.ack);
	}

	function clientReceiveVerdict(v) {
		const key = 'nc.verdict.' + v.kind;
		lastVerdictKind = v.kind;
		lastVerdictText = key;
		lastVerdictMs = v.ms;
		clientEvent = { until: simNow + 2200, start: simNow, kind: v.kind, ms: v.ms };
		const view = enemyView(simNow);
		if (v.kind === 'hit' && view && !E.reducedMotion) burst = { start: simNow, x: view.x, y: view.y };
		verdictDirty = true;
	}
	let lastVerdictMs = 0;
	let verdictDirty = true;

	function clientInput() {
		let dx = 0, dy = 0;
		if (keys.has('left')) dx -= 1;
		if (keys.has('right')) dx += 1;
		if (keys.has('up')) dy -= 1;
		if (keys.has('down')) dy += 1;
		const manualKeys = dx !== 0 || dy !== 0;
		if (manualKeys) {
			const len = Math.hypot(dx, dy);
			dx /= len; dy /= len;
		} else if (pointer.down && pointer.dragged && pointer.tx !== null) {
			const vx = pointer.tx - cpos.x, vy = pointer.ty - cpos.y;
			const len = Math.hypot(vx, vy);
			if (len > 2.5) { dx = vx / len; dy = vy / len; }
			lastManual = simNow;
		}
		if (manualKeys) lastManual = simNow;

		const autoOn = cfg.auto && simNow - lastManual > 3500;
		if (autoOn) {
			if (!apActive) ap = { x: cpos.x, y: cpos.y };
			const target = enemyAtTick(simTick + 15);
			const ang = simNow * 0.0015;
			target.x += Math.cos(ang) * 13;
			target.y += Math.sin(ang) * 13;
			const vx = target.x - ap.x, vy = target.y - ap.y;
			const len = Math.hypot(vx, vy);
			const mag = Math.min(1, len / 8);
			if (len > 0.01) { dx = (vx / len) * mag; dy = (vy / len) * mag; }
			applyMove(ap, dx, dy);
			if (dist(ap, enemyAtTick(simTick)) < 15 && simNow - lastStrike > 3200) strike();
		}
		apActive = autoOn;
		if (dx !== 0 || dy !== 0) face = { x: dx, y: dy };
		return { x: dx, y: dy };
	}

	function clientTick() {
		const d = clientInput();
		const inp = { tick: simTick, t: simNow, x: d.x, y: d.y };
		inputHist.push(inp);
		if (inputHist.length > 90) inputHist.shift();
		if (cfg.pred) applyMove(cpos, d.x, d.y);
		if (simTick % SNAP_EVERY === 1) {
			const n = inputHist.length;
			send('in', true, inputHist.slice(Math.max(0, n - 2)).map((i) => ({ tick: i.tick, x: i.x, y: i.y })), false);
		}
	}

	function strike() {
		if (simNow - lastStrike < 350) return;
		lastStrike = simNow;
		const view = enemyView(simNow);
		const ang = view ? Math.atan2(view.y - cpos.y, view.x - cpos.x) : Math.atan2(face.y, face.x);
		swing = { start: simNow, ang: ang };
		if (!view) return;
		lastVerdictKind = 'sent';
		lastVerdictText = 'nc.verdict.sent';
		verdictDirty = true;
		send('strike', true, { displayTime: view.time, px: cpos.x, py: cpos.y }, true);
	}

	function step() {
		simNow = simTick * TICK_MS;
		deliver();
		clientTick();
		serverTick();
		const target = cfg.interp ? oneWay() + interpMs() : oneWay();
		delayTotal += (target - delayTotal) * 0.08;
		simTick++;
	}

	function init() {
		cpos = { x: 40, y: 60 };
		spos = { x: 40, y: 60 };
		ap = { x: 40, y: 60 };
		delayTotal = oneWay() + interpMs();
		for (let i = 0; i < 150; i++) step();
		for (let i = 0; i < 20; i++) packets = packets.filter((p) => p.t1 > simNow);
		serverEvent = null; clientEvent = null; swing = null; reconFlash = -1e9; lastRewind = null;
		lastVerdictText = ''; lastVerdictKind = ''; burst = null; lastStrike = -1e9;
	}

	/* ---------- Colors ---------- */
	let C = {};
	const colorCtx = document.createElement('canvas').getContext('2d');
	const rgbaCache = {};
	function rgba(color, a) {
		let rgb = rgbaCache[color];
		if (!rgb) {
			colorCtx.fillStyle = '#000';
			colorCtx.fillStyle = color;
			const s = colorCtx.fillStyle;
			if (s[0] === '#') rgb = [parseInt(s.slice(1, 3), 16), parseInt(s.slice(3, 5), 16), parseInt(s.slice(5, 7), 16)];
			else { const m = s.match(/[\d.]+/g) || [0, 0, 0]; rgb = [+m[0], +m[1], +m[2]]; }
			rgbaCache[color] = rgb;
		}
		return 'rgba(' + rgb[0] + ',' + rgb[1] + ',' + rgb[2] + ',' + a + ')';
	}
	function readColors() {
		const cs = getComputedStyle(document.documentElement);
		const v = (name, fb) => (cs.getPropertyValue(name).trim() || fb);
		const realm = E.realm;
		C = {
			accent: v('--accent', '#ff8a3d'),
			gold: v('--gold', '#c9a45c'),
			goldBright: v('--gold-bright', '#f0d595'),
			ember: v('--ember', '#ff8a3d'),
			emberHot: v('--ember-hot', '#ffc070'),
			text: v('--text', '#ece3cf'),
			dim: v('--text-dim', '#a99e89'),
			faint: v('--text-faint', '#6f665a'),
			bad: '#d9583f',
			enemy: realm ? (realm === 'askarra' ? '#8fd3f0' : '#e8574e') : '#bdb6a6',
			display: v('--font-display', 'Georgia, serif'),
			label: v('--font-label', 'Georgia, serif'),
			mono: v('--font-mono', 'monospace'),
		};
	}

	/* ---------- Layout ---------- */
	let L = null;
	let view = null;
	function layout() {
		const W = Math.floor(stage.clientWidth);
		if (W < 10) return;
		const stacked = W < 700;
		const pad = 12, labelH = 30, tlH = 56, gapBelow = 14;
		let H, cl, sv, wire, tl;
		if (!stacked) {
			const gap = Math.max(92, Math.round(W * 0.085));
			const aw = (W - 2 * pad - gap) / 2;
			const ah = aw / ASPECT;
			cl = { x: pad, y: labelH, w: aw, h: ah };
			sv = { x: pad + aw + gap, y: labelH, w: aw, h: ah };
			wire = { x0: cl.x + aw, x1: sv.x, yUp: labelH + ah * 0.4, yDown: labelH + ah * 0.62, label: true };
			tl = { x: pad, y: labelH + ah + gapBelow, w: W - 2 * pad, h: tlH };
			H = tl.y + tlH;
		} else {
			const aw = W - 2 * pad;
			const ah = aw / ASPECT;
			const wireH = 56;
			cl = { x: pad, y: labelH, w: aw, h: ah };
			const wireTop = labelH + ah + 4;
			sv = { x: pad, y: wireTop + wireH + labelH, w: aw, h: ah };
			wire = { x0: pad + 10, x1: W - pad - 10, yUp: wireTop + wireH * 0.3, yDown: wireTop + wireH * 0.72, label: true };
			tl = { x: pad, y: sv.y + ah + gapBelow, w: aw, h: tlH };
			H = tl.y + tlH;
		}
		canvas.style.height = Math.round(H) + 'px';
		L = { W: W, H: H, stacked: stacked, cl: cl, sv: sv, wire: wire, tl: tl, labelH: labelH, scale: cl.w / WORLD_W };
	}

	/* ---------- Drawing ---------- */
	let g, fit;
	const wx = (r, x) => r.x + x * (r.w / WORLD_W);
	const wy = (r, y) => r.y + y * (r.h / WORLD_H);

	function drawArena(r, title, sub) {
		const grad = g.createLinearGradient(0, r.y, 0, r.y + r.h);
		grad.addColorStop(0, '#15110d');
		grad.addColorStop(1, '#0d0b09');
		g.fillStyle = grad;
		g.fillRect(r.x, r.y, r.w, r.h);
		g.strokeStyle = rgba(C.gold, 0.07);
		g.lineWidth = 1;
		g.beginPath();
		for (let x = 10; x < WORLD_W; x += 10) { const px = Math.round(wx(r, x)) + 0.5; g.moveTo(px, r.y); g.lineTo(px, r.y + r.h); }
		for (let y = 10; y < WORLD_H; y += 10) { const py = Math.round(wy(r, y)) + 0.5; g.moveTo(r.x, py); g.lineTo(r.x + r.w, py); }
		g.stroke();
		const vg = g.createRadialGradient(r.x + r.w / 2, r.y + r.h / 2, r.h * 0.2, r.x + r.w / 2, r.y + r.h / 2, r.w * 0.65);
		vg.addColorStop(0, 'rgba(0,0,0,0)');
		vg.addColorStop(1, 'rgba(0,0,0,0.5)');
		g.fillStyle = vg;
		g.fillRect(r.x, r.y, r.w, r.h);
		g.strokeStyle = rgba(C.gold, 0.55);
		g.lineWidth = 1;
		g.strokeRect(r.x + 0.5, r.y + 0.5, r.w - 1, r.h - 1);
		// Corner ticks
		g.strokeStyle = C.gold;
		g.beginPath();
		for (const [cx, cy, sx, sy] of [[r.x, r.y, 1, 1], [r.x + r.w, r.y, -1, 1], [r.x, r.y + r.h, 1, -1], [r.x + r.w, r.y + r.h, -1, -1]]) {
			g.moveTo(cx + sx * 10, cy + 0.5 * sy); g.lineTo(cx + 0.5 * sx, cy + 0.5 * sy); g.lineTo(cx + 0.5 * sx, cy + sy * 10);
		}
		g.stroke();
		// Title
		g.textBaseline = 'alphabetic';
		g.textAlign = 'left';
		g.font = '600 12px ' + C.display;
		if ('letterSpacing' in g) g.letterSpacing = '2.5px';
		g.fillStyle = C.goldBright;
		const up = title.toUpperCase();
		g.fillText(up, r.x, r.y - 11);
		const tw = g.measureText(up).width;
		if ('letterSpacing' in g) g.letterSpacing = '0px';
		g.font = '12px ' + C.label;
		g.fillStyle = C.dim;
		g.fillText('· ' + sub, r.x + tw + 10, r.y - 11);
	}

	function knight(r, x, y, color, alpha, dashed) {
		const px = wx(r, x), py = wy(r, y), rad = PLAYER_R * (r.w / WORLD_W);
		g.save();
		g.globalAlpha = alpha;
		g.fillStyle = rgba(color, 0.2);
		g.beginPath(); g.arc(px, py, rad * 2.1, 0, TAU); g.fill();
		g.fillStyle = rgba(color, 0.9);
		g.strokeStyle = '#0c0a09';
		g.lineWidth = 1.5;
		g.beginPath(); g.arc(px, py, rad, 0, TAU); g.fill(); g.stroke();
		// Helm slit pointing at the facing direction
		const a = Math.atan2(face.y, face.x);
		g.strokeStyle = '#0c0a09';
		g.lineWidth = 2;
		g.beginPath(); g.moveTo(px + Math.cos(a) * rad * 0.1, py + Math.sin(a) * rad * 0.1); g.lineTo(px + Math.cos(a) * rad * 0.95, py + Math.sin(a) * rad * 0.95); g.stroke();
		g.restore();
	}

	function foe(r, x, y, color, alpha, dashed) {
		const px = wx(r, x), py = wy(r, y), rad = PLAYER_R * 1.15 * (r.w / WORLD_W);
		g.save();
		g.globalAlpha = alpha;
		if (!dashed) { g.fillStyle = rgba(color, 0.18); g.beginPath(); g.arc(px, py, rad * 2.1, 0, TAU); g.fill(); }
		g.beginPath();
		g.moveTo(px, py - rad); g.lineTo(px + rad, py); g.lineTo(px, py + rad); g.lineTo(px - rad, py); g.closePath();
		if (dashed) {
			g.setLineDash([4, 3]);
			g.strokeStyle = C.goldBright;
			g.lineWidth = 1.5;
			g.stroke();
			g.setLineDash([]);
		} else {
			g.fillStyle = rgba(color, 0.92);
			g.fill();
			g.strokeStyle = '#0c0a09';
			g.lineWidth = 1.5;
			g.stroke();
		}
		g.restore();
	}

	function tag(text, x, y, color, align) {
		g.font = '11px ' + C.label;
		g.textAlign = align || 'center';
		g.textBaseline = 'alphabetic';
		g.fillStyle = 'rgba(8,6,5,0.65)';
		const w = g.measureText(text).width;
		const bx = align === 'left' ? x : align === 'right' ? x - w : x - w / 2;
		g.fillRect(bx - 3, y - 10, w + 6, 14);
		g.fillStyle = color;
		g.fillText(text, x, y);
	}

	function drawClientArena(now) {
		const r = L.cl;
		drawArena(r, t('nc.client'), t('nc.clientSub'));
		g.save();
		g.beginPath(); g.rect(r.x, r.y, r.w, r.h); g.clip();
		view = enemyView(now);
		// Snapshot buffer: faint dots
		if (view) {
			const cutoff = (cfg.interp ? view.time : snaps[snaps.length - 1].time) - 260;
			for (const s of snaps) {
				if (s.time < cutoff) continue;
				g.fillStyle = rgba(C.enemy, 0.28);
				g.beginPath(); g.arc(wx(r, s.x), wy(r, s.y), 2.2, 0, TAU); g.fill();
			}
			if (cfg.interp && view.a !== view.b) {
				g.strokeStyle = rgba(C.enemy, 0.3);
				g.lineWidth = 1;
				g.beginPath(); g.moveTo(wx(r, view.a.x), wy(r, view.a.y)); g.lineTo(wx(r, view.b.x), wy(r, view.b.y)); g.stroke();
			}
		}
		// Latest authoritative position of the player (what a snapshot last said)
		if (cfg.pred && authPos) {
			g.strokeStyle = rgba(C.accent, 0.4);
			g.setLineDash([2, 3]);
			g.beginPath(); g.arc(wx(r, authPos.x), wy(r, authPos.y), PLAYER_R * (r.w / WORLD_W) * 1.25, 0, TAU); g.stroke();
			g.setLineDash([]);
		}
		if (view) foe(r, view.x, view.y, C.enemy, 1, false);
		if (view && cfg.interp) {
			g.strokeStyle = rgba(C.goldBright, 0.8);
			g.lineWidth = 1;
			g.beginPath(); g.arc(wx(r, view.x), wy(r, view.y), PLAYER_R * 1.15 * (r.w / WORLD_W) * 1.55, 0, TAU); g.stroke();
		}
		// Swing arc
		if (swing && now - swing.start < 260) {
			const k = (now - swing.start) / 260;
			const sc = r.w / WORLD_W;
			g.strokeStyle = rgba(C.goldBright, 1 - k);
			g.lineWidth = 3;
			g.beginPath();
			g.arc(wx(r, cpos.x), wy(r, cpos.y), REACH * sc * (0.6 + 0.4 * k), swing.ang - 0.9, swing.ang + 0.9);
			g.stroke();
		}
		knight(r, cpos.x, cpos.y, C.accent, 1);
		const sc = r.w / WORLD_W;
		tag(t('nc.you'), wx(r, cpos.x), wy(r, cpos.y) - PLAYER_R * sc - 7, C.text);
		if (view) tag(t('nc.enemy'), wx(r, view.x), wy(r, view.y) - PLAYER_R * sc * 1.15 - 7, C.dim);
		// Reconciliation flash
		const rf = now - reconFlash;
		if (rf < 900) {
			if (!E.reducedMotion && rf < 450) {
				g.strokeStyle = rgba(C.goldBright, 1 - rf / 450);
				g.lineWidth = 2;
				g.beginPath(); g.arc(wx(r, cpos.x), wy(r, cpos.y), PLAYER_R * sc * (1.4 + rf / 150), 0, TAU); g.stroke();
			}
			tag(t('nc.reconciled'), wx(r, cpos.x), wy(r, cpos.y) + PLAYER_R * sc + 16, C.goldBright);
		}
		// Hit burst
		if (burst && now - burst.start < 450) {
			const k = (now - burst.start) / 450;
			g.strokeStyle = rgba(C.goldBright, 1 - k);
			g.lineWidth = 2;
			g.beginPath(); g.arc(wx(r, burst.x), wy(r, burst.y), 8 + k * 30, 0, TAU); g.stroke();
		}
		// Verdict as it arrives on the client
		if (clientEvent && now < clientEvent.until) {
			const col = clientEvent.kind === 'hit' ? C.goldBright : clientEvent.kind === 'rejected' ? C.bad : C.dim;
			tag(t('nc.verdict.' + clientEvent.kind, { ms: clientEvent.ms }), r.x + r.w / 2, r.y + r.h - 10, col);
		}
		// Input delay label
		g.textAlign = 'left';
		const delay = cfg.pred ? t('nc.inputDelayPredicted') : t('nc.inputDelay', { ms: Math.round(inputDelay) });
		tag(delay, r.x + 8, r.y + 16, cfg.pred ? C.dim : C.bad, 'left');
		g.restore();
	}

	function drawServerArena(now) {
		const r = L.sv;
		drawArena(r, t('nc.server'), t('nc.serverSub'));
		g.save();
		g.beginPath(); g.rect(r.x, r.y, r.w, r.h); g.clip();
		const sc = r.w / WORLD_W;
		const cur = enemyHist[enemyHist.length - 1];
		const ev = serverEvent && now < serverEvent.until ? serverEvent : null;
		if (ev) {
			const fade = Math.min(1, (ev.until - now) / 600);
			const col = ev.kind === 'hit' ? C.goldBright : ev.kind === 'rejected' ? C.bad : C.dim;
			g.globalAlpha = fade;
			// Intent position and reach, ghost hitbox and link to the current enemy
			g.strokeStyle = rgba(C.accent, 0.35);
			g.setLineDash([2, 3]);
			g.beginPath(); g.arc(wx(r, ev.player.x), wy(r, ev.player.y), REACH * sc, 0, TAU); g.stroke();
			g.setLineDash([]);
			if (cur) {
				g.strokeStyle = rgba(col, 0.6);
				g.setLineDash([1, 4]);
				g.beginPath(); g.moveTo(wx(r, ev.ghost.x), wy(r, ev.ghost.y)); g.lineTo(wx(r, cur.x), wy(r, cur.y)); g.stroke();
				g.setLineDash([]);
			}
			foe(r, ev.ghost.x, ev.ghost.y, C.enemy, 1, true);
			if (ev.kind === 'rejected') {
				const gx = wx(r, ev.ghost.x), gy = wy(r, ev.ghost.y);
				g.strokeStyle = C.bad; g.lineWidth = 2;
				g.beginPath(); g.moveTo(gx - 6, gy - 6); g.lineTo(gx + 6, gy + 6); g.moveTo(gx + 6, gy - 6); g.lineTo(gx - 6, gy + 6); g.stroke();
			}
			tag(t('nc.ghost', { ms: ev.ms }), wx(r, ev.ghost.x), wy(r, ev.ghost.y) + PLAYER_R * sc * 1.15 + 14, col);
			tag(t('nc.verdict.' + ev.kind, { ms: ev.ms }), r.x + r.w / 2, r.y + r.h - 10, col);
			g.globalAlpha = 1;
		}
		if (cur) {
			foe(r, cur.x, cur.y, C.enemy, 1, false);
			tag(t('nc.enemyServer'), wx(r, cur.x), wy(r, cur.y) - PLAYER_R * sc * 1.15 - 7, C.dim);
		}
		knight(r, spos.x, spos.y, C.accent, 0.95);
		tag(t('nc.youServer'), wx(r, spos.x), wy(r, spos.y) - PLAYER_R * sc - 7, C.text);
		g.restore();
	}

	function drawWire(now) {
		const w = L.wire;
		g.lineWidth = 1;
		g.strokeStyle = rgba(C.gold, 0.28);
		g.setLineDash([3, 5]);
		g.beginPath();
		g.moveTo(w.x0, w.yUp); g.lineTo(w.x1, w.yUp);
		g.moveTo(w.x0, w.yDown); g.lineTo(w.x1, w.yDown);
		g.stroke();
		g.setLineDash([]);
		// Arrowheads
		g.fillStyle = rgba(C.gold, 0.6);
		g.beginPath(); g.moveTo(w.x1, w.yUp); g.lineTo(w.x1 - 6, w.yUp - 3.5); g.lineTo(w.x1 - 6, w.yUp + 3.5); g.fill();
		g.beginPath(); g.moveTo(w.x0, w.yDown); g.lineTo(w.x0 + 6, w.yDown - 3.5); g.lineTo(w.x0 + 6, w.yDown + 3.5); g.fill();
		g.font = '10px ' + C.label;
		g.textBaseline = 'alphabetic';
		g.fillStyle = C.dim;
		g.textAlign = L.stacked ? 'left' : 'center';
		const cx = (w.x0 + w.x1) / 2;
		const lx = L.stacked ? w.x0 + 4 : cx;
		g.fillText(t('nc.wireUp'), lx, w.yUp - 6);
		g.textAlign = L.stacked ? 'right' : 'center';
		g.fillText(t('nc.wireDown'), L.stacked ? w.x1 - 4 : cx, w.yDown + 15);
		g.textAlign = 'left';
		for (const p of packets) {
			const span = p.t1 - p.t0;
			const k = span <= 0 ? 1 : (now - p.t0) / span;
			if (k < 0 || k > 1) continue;
			const x = p.up ? w.x0 + (w.x1 - w.x0) * k : w.x1 - (w.x1 - w.x0) * k;
			const y = p.up ? w.yUp : w.yDown;
			if (p.dropped) {
				if (k > p.dropAt) {
					const a = Math.max(0, 1 - (k - p.dropAt) * 6);
					if (a <= 0) continue;
					const dx = p.up ? w.x0 + (w.x1 - w.x0) * p.dropAt : w.x1 - (w.x1 - w.x0) * p.dropAt;
					g.strokeStyle = rgba(C.bad, a); g.lineWidth = 1.5;
					g.beginPath(); g.moveTo(dx - 3, y - 3); g.lineTo(dx + 3, y + 3); g.moveTo(dx + 3, y - 3); g.lineTo(dx - 3, y + 3); g.stroke();
					continue;
				}
			}
			let color = C.emberHot, rad = 2.4;
			if (p.kind === 'snap') { color = C.accent; rad = 3.2; }
			else if (p.kind === 'strike') { color = C.goldBright; rad = 4.6; }
			else if (p.kind === 'verdict') { color = p.data.kind === 'hit' ? C.goldBright : p.data.kind === 'rejected' ? C.bad : C.dim; rad = 4.6; }
			g.fillStyle = rgba(color, 0.22);
			g.beginPath(); g.arc(x, y, rad * 2.6, 0, TAU); g.fill();
			g.fillStyle = color;
			g.beginPath(); g.arc(x, y, rad, 0, TAU); g.fill();
			if (p.kind === 'strike' || p.kind === 'verdict') {
				g.strokeStyle = rgba(color, 0.7); g.lineWidth = 1;
				g.beginPath(); g.arc(x, y, rad + 3, 0, TAU); g.stroke();
			}
		}
	}

	function drawTimeline(now) {
		const r = L.tl;
		const midY = r.y + r.h - 16;
		g.fillStyle = 'rgba(8,6,5,0.5)';
		g.fillRect(r.x, r.y, r.w, r.h);
		g.strokeStyle = rgba(C.gold, 0.3);
		g.strokeRect(r.x + 0.5, r.y + 0.5, r.w - 1, r.h - 1);
		g.save();
		g.beginPath(); g.rect(r.x, r.y, r.w, r.h); g.clip();
		const xOf = (tm) => r.x + r.w - 14 - ((now - tm) / TIMELINE_MS) * (r.w - 28);
		// Interpolation delay zone, behind "now"
		if (cfg.interp) {
			const x1 = xOf(now), x0 = xOf(now - interpMs());
			g.fillStyle = rgba(C.accent, 0.12);
			g.fillRect(x0, r.y + 18, x1 - x0, r.h - 20);
			g.strokeStyle = rgba(C.accent, 0.55);
			g.beginPath(); g.moveTo(x0 + 0.5, r.y + 18); g.lineTo(x0 + 0.5, r.y + r.h - 3); g.stroke();
			g.font = '10px ' + C.label;
			g.textAlign = 'right';
			g.fillStyle = rgba(C.accent, 0.9);
			g.fillText(t('nc.interpZone'), x1 - 4, r.y + 13);
		}
		const first = Math.floor((now - TIMELINE_MS) / TICK_MS);
		const lastT = Math.floor(now / TICK_MS);
		for (let n = Math.max(0, first); n <= lastT; n++) {
			const x = Math.round(xOf(n * TICK_MS)) + 0.5;
			const snapMark = n % SNAP_EVERY === 0;
			g.strokeStyle = snapMark ? C.accent : rgba(C.gold, 0.45);
			g.lineWidth = snapMark ? 2 : 1;
			g.beginPath(); g.moveTo(x, midY); g.lineTo(x, midY - (snapMark ? 14 : 6)); g.stroke();
		}
		g.strokeStyle = rgba(C.gold, 0.5); g.lineWidth = 1;
		g.beginPath(); g.moveTo(r.x, midY + 0.5); g.lineTo(r.x + r.w, midY + 0.5); g.stroke();
		const nx = xOf(now);
		g.fillStyle = C.goldBright;
		g.beginPath(); g.moveTo(nx, midY + 2); g.lineTo(nx - 4, midY + 8); g.lineTo(nx + 4, midY + 8); g.fill();
		g.restore();
		g.font = '11px ' + C.label;
		g.textAlign = 'left';
		g.fillStyle = C.dim;
		g.fillText(t('nc.timeline'), r.x + 8, r.y + 13);
	}

	function draw(frac) {
		if (!L) return;
		fit = E.fitCanvas(canvas);
		g = fit.ctx;
		g.clearRect(0, 0, fit.w, fit.h);
		const now = simNow + frac;
		drawClientArena(now);
		drawServerArena(now);
		drawWire(now);
		drawTimeline(now);
	}

	/* ---------- DOM text ---------- */
	function stateWord(on) { return t(on ? 'nc.on' : 'nc.off'); }

	function updateControls() {
		latencyCtl.out.textContent = cfg.rtt + ' ms';
		lossCtl.out.textContent = cfg.loss + ' %';
		predCtl.state.textContent = stateWord(cfg.pred);
		interpCtl.state.textContent = stateWord(cfg.interp);
		autoCtl.state.textContent = stateWord(cfg.auto);
	}

	function verdictString() {
		if (!lastVerdictText) return t('nc.verdict.none');
		return t(lastVerdictText, { ms: lastVerdictMs });
	}

	function updateText() {
		updateControls();
		const ms = Math.round(interpMs());
		readoutEls.rtt.textContent = t('nc.ms', { ms: cfg.rtt });
		readoutEls.oneWay.textContent = t('nc.ms', { ms: Math.round(oneWay()) });
		readoutEls.interp.textContent = cfg.interp ? t('nc.msTicks', { ms: ms, ticks: interpTicks() }) : t('nc.r.off');
		readoutEls.rewind.textContent = lastRewind === null ? t('nc.r.none') : t('nc.ms', { ms: Math.round(lastRewind) });
		readoutEls.inputDelay.textContent = cfg.pred ? t('nc.r.predicted') : t('nc.ms', { ms: Math.round(inputDelay) });
		readoutEls.ticks.textContent = '60';
		readoutEls.snaps.textContent = '30';
		capEls.pred.querySelector('.nc-cap-text').textContent = cfg.pred
			? t('nc.cap.pred.on', { ms: Math.round(oneWay()) })
			: t('nc.cap.pred.off', { ms: Math.round(cfg.rtt + 17) });
		capEls.interp.querySelector('.nc-cap-text').textContent = cfg.interp
			? t('nc.cap.interp.on', { ms: ms })
			: t('nc.cap.interp.off');
		capEls.lag.querySelector('.nc-cap-text').textContent = t('nc.cap.lag', { ms: Math.round(cfg.rtt + (cfg.interp ? interpMs() : 17)) });
		for (const id in capEls) capEls[id].classList.toggle('is-active', id === activeCap);
		verdictLine.textContent = verdictString();
		verdictLine.dataset.kind = lastVerdictKind || 'none';
		canvas.setAttribute('aria-label', t('nc.aria', {
			rtt: cfg.rtt,
			loss: cfg.loss,
			pred: stateWord(cfg.pred),
			interp: stateWord(cfg.interp),
			last: verdictString(),
		}));
	}

	function setActiveCap(id) {
		activeCap = id;
		updateText();
	}

	/* ---------- Events ---------- */
	latencyCtl.input.addEventListener('input', () => { cfg.rtt = +latencyCtl.input.value; setActiveCap('lag'); });
	lossCtl.input.addEventListener('input', () => { cfg.loss = +lossCtl.input.value; setActiveCap('interp'); });
	predCtl.input.addEventListener('change', () => { cfg.pred = predCtl.input.checked; setActiveCap('pred'); });
	interpCtl.input.addEventListener('change', () => { cfg.interp = interpCtl.input.checked; setActiveCap('interp'); });
	autoCtl.input.addEventListener('change', () => { cfg.auto = autoCtl.input.checked; updateControls(); });
	strikeBtn.addEventListener('click', () => { strike(); setActiveCap('lag'); });

	const KEYMAP = {
		KeyW: 'up', ArrowUp: 'up', KeyS: 'down', ArrowDown: 'down',
		KeyA: 'left', ArrowLeft: 'left', KeyD: 'right', ArrowRight: 'right',
	};
	stage.addEventListener('keydown', (e) => {
		if (e.ctrlKey || e.metaKey || e.altKey) return;
		const dir = KEYMAP[e.code];
		if (dir) {
			keys.add(dir);
			e.preventDefault();
		} else if (e.code === 'Space') {
			e.preventDefault();
			if (!e.repeat) { strike(); setActiveCap('lag'); }
		}
	});
	stage.addEventListener('keyup', (e) => {
		const dir = KEYMAP[e.code];
		if (dir) keys.delete(dir);
	});
	stage.addEventListener('blur', () => keys.clear());

	function toWorld(e) {
		const rect = canvas.getBoundingClientRect();
		const px = e.clientX - rect.left, py = e.clientY - rect.top;
		const r = L.cl;
		return { inside: px >= r.x && px <= r.x + r.w && py >= r.y && py <= r.y + r.h, x: (px - r.x) / (r.w / WORLD_W), y: (py - r.y) / (r.h / WORLD_H) };
	}
	canvas.addEventListener('pointerdown', (e) => {
		stage.focus({ preventScroll: true });
		if (!L) return;
		const w = toWorld(e);
		if (!w.inside) return;
		pointer.down = true; pointer.dragged = false;
		pointer.sx = e.clientX; pointer.sy = e.clientY; pointer.st = performance.now();
		pointer.tx = w.x; pointer.ty = w.y;
		try { canvas.setPointerCapture(e.pointerId); } catch (err) { /* ignore */ }
	});
	canvas.addEventListener('pointermove', (e) => {
		if (!pointer.down || !L) return;
		if (Math.hypot(e.clientX - pointer.sx, e.clientY - pointer.sy) > 8) pointer.dragged = true;
		const w = toWorld(e);
		pointer.tx = w.x; pointer.ty = w.y;
	});
	function endPointer(e) {
		if (!pointer.down) return;
		const wasTap = !pointer.dragged && performance.now() - pointer.st < 450;
		pointer.down = false; pointer.tx = null; pointer.ty = null;
		if (wasTap && e.type === 'pointerup') { strike(); setActiveCap('lag'); }
	}
	canvas.addEventListener('pointerup', endPointer);
	canvas.addEventListener('pointercancel', endPointer);

	E.on('realm', () => { readColors(); });
	E.on('lang', () => { E.applyI18n(mount); verdictDirty = true; updateText(); });

	/* ---------- Loop ---------- */
	let visible = false;
	let raf = 0;
	let lastFrame = 0;
	let textTimer = 0;

	function frame(ts) {
		raf = 0;
		if (!visible || document.hidden) return;
		const dt = Math.min(100, ts - lastFrame);
		lastFrame = ts;
		acc += dt;
		while (acc >= TICK_MS) { step(); acc -= TICK_MS; }
		draw(acc);
		textTimer += dt;
		if (textTimer > 150 || verdictDirty) {
			textTimer = 0;
			verdictDirty = false;
			updateText();
		}
		raf = requestAnimationFrame(frame);
	}
	function ensureLoop() {
		if (!raf && visible && !document.hidden) {
			lastFrame = performance.now();
			raf = requestAnimationFrame(frame);
		}
	}

	readColors();
	E.applyI18n(mount);
	init();
	layout();
	updateText();
	draw(0);

	let lastW = stage.clientWidth;
	function onResize() {
		const w = stage.clientWidth;
		if (Math.abs(w - lastW) < 1 && L) return;
		lastW = w;
		layout();
		draw(acc);
	}
	if ('ResizeObserver' in window) new ResizeObserver(onResize).observe(stage);
	else window.addEventListener('resize', onResize);

	E.whenVisible(stage, () => { visible = true; ensureLoop(); }, () => { visible = false; });
	document.addEventListener('visibilitychange', ensureLoop);
	// Fonts may arrive after the first frame: redraw once they do.
	if (document.fonts && document.fonts.ready) document.fonts.ready.then(() => { if (L) draw(acc); });
})();
