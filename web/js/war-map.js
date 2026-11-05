/*
 * Eldmark website: the war table.
 *
 * Mounts into <div id="war-map"> and builds a stylized SVG map of Eldrun (the three realms, their walls
 * and gates, six forts, three castles and Aldcor) plus a live simulation of the war that follows the
 * rules of docs/world.md ("Ember Lines"):
 *   - a stronghold can only be attacked from a road that touches the attacker's gate or one of its strongholds;
 *   - Aldcor can only be attacked by a realm holding 2 of the 3 castles;
 *   - braziers burn in a realm's color on roads linking two of its strongholds that are chained to its gate;
 *   - a stronghold cut off from every gate of its realm is isolated: dimmed, and easier to capture;
 *   - taking Aldcor rekindles the Flame; meanwhile the other two realms attack with a bonus.
 * Depends on core.js (window.Eldmark): i18n, realm, sound, whenVisible, reducedMotion.
 * Public surface: window.EldmarkWarMap = { play, pause, reset, setSpeed, advance(seconds) }.
 */
(function () {
	'use strict';

	const root = document.getElementById('war-map');
	const E = window.Eldmark;
	if (!root || !E) return;

	const SVGNS = 'http://www.w3.org/2000/svg';
	const REALM_IDS = ['vardheim', 'solmarch', 'askarra'];
	const REALMS = E.REALMS;
	const reduced = E.reducedMotion;

	/* ---------- Strings ---------- */
	E.addStrings({
		en: {
			'wm.aria.map': 'War table of Eldrun: forts, castles and roads between the three realms',
			'wm.play': 'Play', 'wm.pause': 'Pause', 'wm.reset': 'Reset', 'wm.speed': 'Speed',
			'wm.embers': 'Embers', 'wm.perSec': '+{n}/s',
			'wm.yourBanner': 'Your banner',
			'wm.hollow': 'The Hollow', 'wm.hollowThe': 'the Hollow',
			'wm.hint': 'Hover, focus or tap a stronghold to read it. Esc clears the selection.',
			'wm.type.gate': 'Wall gate', 'wm.type.fort': 'Fort', 'wm.type.castle': 'Castle', 'wm.type.aldcor': 'Citadel',
			'wm.front.nw': 'Northwest front · Vardheim–Solmarch',
			'wm.front.ne': 'Northeast front · Vardheim–Askarra',
			'wm.front.s': 'South front · Solmarch–Askarra',
			'wm.front.c': 'Center of Eldrun',
			'wm.playable': 'Playable now',
			'wm.heldBy': 'Held by', 'wm.status': 'Chain', 'wm.output': 'Embers',
			'wm.st.gate': 'Always linked: the root of the {realm} chain. It cannot be captured.',
			'wm.st.neutral': 'Neutral, guarded by the Hollow garrison. Weaker than a realm garrison.',
			'wm.st.linked': 'Linked: an unbroken road chain reaches a {realm} gate.',
			'wm.st.isolated': 'Isolated: no road chain to any {realm} gate. Its defenders weaken and it is easier to take.',
			'wm.castlesHeld': 'Castles held',
			'wm.flameBurns': 'The Flame burns for {realm}.',
			'wm.sealed': 'Sealed until a realm holds 2 of the 3 castles.',
			'wm.fx.gate': 'Spawn point and root of the realm\'s Ember Lines. Safe on the realm side.',
			'wm.fx.vado': 'Shortens the route to Velmont. The first playable zone of the game: a compressed border test.',
			'wm.fx.atalaya': 'Reveals nearby enemies on the map.',
			'wm.fx.cantera': 'Supplies materials for siege weapons.',
			'wm.fx.ilse': 'Forward respawn point.',
			'wm.fx.kerth': 'Generates extra Embers.',
			'wm.fx.hadrin': 'Bottleneck between Solmarch and Askarra.',
			'wm.fx.velmont': 'River castle with a fortified bridge. It controls the fords.',
			'wm.fx.grauholt': 'Mountain castle above a gorge. It dominates the eastern pass.',
			'wm.fx.sarnath': 'Fortress above a crack of embers. The one that produces the most resources.',
			'wm.fx.aldcor': 'The ruined citadel at the center. Only a realm holding 2 of the 3 castles can attack it. Whoever takes it rekindles the Flame; the other two realms then attack with a bonus.',
			'wm.chronicle': 'War chronicle',
			'wm.chronicle.empty': 'The war has not begun.',
			'wm.ev.take': '{realm} takes {node} from {from}',
			'wm.ev.fail': '{realm} fails to take {node}',
			'wm.ev.isolated': '{Node} is isolated',
			'wm.ev.flame': '{realm} rekindles the Flame at Aldcor',
			'wm.ev.flameOut': 'The Flame at Aldcor dies down',
			'wm.banner': 'The Flame is rekindled',
			'wm.banner.sub': '{realm} holds Aldcor',
			'wm.legend': 'Legend',
			'wm.lg.gate': 'Wall gate', 'wm.lg.fort': 'Fort', 'wm.lg.castle': 'Castle', 'wm.lg.aldcor': 'Aldcor',
			'wm.lg.lit': 'Lit road: linked chain', 'wm.lg.cold': 'Cold road', 'wm.lg.isolated': 'Isolated',
			'wm.g.vado': 'the Gray Ford', 'wm.g.lobo': 'Wolf Gate', 'wm.g.aurea': 'Golden Gate',
			'wm.g.penitentes': 'Gate of the Penitents', 'wm.g.ceniza': 'Ash Gate', 'wm.g.canon': 'Canyon Gate',
			'wm.g.aldcor': 'the Broken Throne',
		},
		es: {
			'wm.aria.map': 'Mesa de guerra de Eldrun: fuertes, castillos y caminos entre los tres reinos',
			'wm.play': 'Reproducir', 'wm.pause': 'Pausar', 'wm.reset': 'Reiniciar', 'wm.speed': 'Velocidad',
			'wm.embers': 'Brasas', 'wm.perSec': '+{n}/s',
			'wm.yourBanner': 'Tu estandarte',
			'wm.hollow': 'Los Huecos', 'wm.hollowThe': 'los Huecos',
			'wm.hint': 'Pasa el ratón, enfoca o toca una plaza para leerla. Esc quita la selección.',
			'wm.type.gate': 'Puerta de la muralla', 'wm.type.fort': 'Fuerte', 'wm.type.castle': 'Castillo', 'wm.type.aldcor': 'Ciudadela',
			'wm.front.nw': 'Frente noroeste · Vardheim–Solmarch',
			'wm.front.ne': 'Frente noreste · Vardheim–Askarra',
			'wm.front.s': 'Frente sur · Solmarch–Askarra',
			'wm.front.c': 'Centro de Eldrun',
			'wm.playable': 'Jugable ya',
			'wm.heldBy': 'En manos de', 'wm.status': 'Cadena', 'wm.output': 'Brasas',
			'wm.st.gate': 'Siempre enlazada: es la raíz de la cadena de {realm}. No se puede capturar.',
			'wm.st.neutral': 'Neutral, custodiada por la guarnición de los Huecos. Más débil que la de un reino.',
			'wm.st.linked': 'Enlazada: una cadena de caminos sin romper llega a una puerta de {realm}.',
			'wm.st.isolated': 'Aislada: sin cadena de caminos hasta ninguna puerta de {realm}. Sus defensores flaquean y es más fácil de tomar.',
			'wm.castlesHeld': 'Castillos',
			'wm.flameBurns': 'La Llama arde para {realm}.',
			'wm.sealed': 'Sellada hasta que un reino domine 2 de los 3 castillos.',
			'wm.fx.gate': 'Punto de aparición y raíz de las Líneas de Brasas del reino. Zona segura por el lado del reino.',
			'wm.fx.vado': 'Acorta la ruta hacia Velmont. Es la primera zona jugable del juego: una frontera de prueba comprimida.',
			'wm.fx.atalaya': 'Revela en el mapa a los enemigos cercanos.',
			'wm.fx.cantera': 'Suministra materiales para armas de asedio.',
			'wm.fx.ilse': 'Punto de reaparición avanzado.',
			'wm.fx.kerth': 'Genera Brasas adicionales.',
			'wm.fx.hadrin': 'Cuello de botella entre Solmarch y Askarra.',
			'wm.fx.velmont': 'Castillo fluvial con un puente fortificado. Controla los vados.',
			'wm.fx.grauholt': 'Castillo de montaña sobre una garganta. Domina el paso oriental.',
			'wm.fx.sarnath': 'Fortaleza sobre una grieta de brasas. La que más recursos produce.',
			'wm.fx.aldcor': 'La ciudadela en ruinas del centro. Solo puede atacarla un reino que domine 2 de los 3 castillos. Quien la toma reaviva la Llama; los otros dos reinos atacan entonces con una bonificación.',
			'wm.chronicle': 'Crónica de guerra',
			'wm.chronicle.empty': 'La guerra aún no ha empezado.',
			'wm.ev.take': '{realm} toma {node} a {from}',
			'wm.ev.fail': '{realm} no logra tomar {node}',
			'wm.ev.isolated': '{Node} queda {iso}',
			'wm.ev.flame': '{realm} reaviva la Llama en Aldcor',
			'wm.ev.flameOut': 'La Llama de Aldcor se apaga',
			'wm.banner': 'La Llama arde de nuevo',
			'wm.banner.sub': '{realm} domina Aldcor',
			'wm.legend': 'Leyenda',
			'wm.lg.gate': 'Puerta de la muralla', 'wm.lg.fort': 'Fuerte', 'wm.lg.castle': 'Castillo', 'wm.lg.aldcor': 'Aldcor',
			'wm.lg.lit': 'Camino encendido: cadena enlazada', 'wm.lg.cold': 'Camino frío', 'wm.lg.isolated': 'Aislada',
		},
	});
	const t = (k, v) => E.t(k, v);

	/* ---------- Map data (viewBox 1000 x 800) ---------- */
	/* lab: [dx, dy, anchor] of the label relative to the node. art/gender: Spanish article and gender for the chronicle. */
	const NODES = [
		{ id: 'lobo', type: 'gate', realm: 'vardheim', front: 'nw', x: 385, y: 197, name: 'Puerta del Lobo', gloss: 'wm.g.lobo', lab: [0, -24, 'middle'] },
		{ id: 'hrafn', type: 'gate', realm: 'vardheim', front: 'ne', x: 615, y: 197, name: 'Puerta de Hrafn', lab: [0, -24, 'middle'] },
		{ id: 'aurea', type: 'gate', realm: 'solmarch', front: 'nw', x: 195, y: 435, name: 'Puerta Áurea', gloss: 'wm.g.aurea', lab: [-24, 4, 'end'] },
		{ id: 'penitentes', type: 'gate', realm: 'solmarch', front: 's', x: 303, y: 626, name: 'Puerta de los Penitentes', gloss: 'wm.g.penitentes', lab: [-20, 18, 'end'] },
		{ id: 'ceniza', type: 'gate', realm: 'askarra', front: 's', x: 697, y: 626, name: 'Puerta de Ceniza', gloss: 'wm.g.ceniza', lab: [20, 18, 'start'] },
		{ id: 'canon', type: 'gate', realm: 'askarra', front: 'ne', x: 805, y: 435, name: 'Puerta del Cañón', gloss: 'wm.g.canon', lab: [24, 4, 'start'] },

		{ id: 'vado', type: 'fort', front: 'nw', x: 360, y: 292, name: 'Vado Gris', gloss: 'wm.g.vado', art: 'el ', g: 'm', fx: 'vado', playable: true, lab: [-22, 4, 'end'] },
		{ id: 'atalaya', type: 'fort', front: 'nw', x: 275, y: 450, name: 'Atalaya de Brenn', art: 'la ', g: 'f', fx: 'atalaya', lab: [0, 34, 'middle'] },
		{ id: 'cantera', type: 'fort', front: 'ne', x: 640, y: 292, name: 'Cantera de Odd', art: 'la ', g: 'f', fx: 'cantera', lab: [22, 4, 'start'] },
		{ id: 'kerth', type: 'fort', front: 'ne', x: 725, y: 450, name: 'Mina de Kerth', art: 'la ', g: 'f', fx: 'kerth', boost: 2, lab: [0, 34, 'middle'] },
		{ id: 'ilse', type: 'fort', front: 's', x: 385, y: 618, name: 'Santuario de Ilse', art: 'el ', g: 'm', fx: 'ilse', lab: [-4, -26, 'end'] },
		{ id: 'hadrin', type: 'fort', front: 's', x: 615, y: 618, name: 'Puente de Hadrin', art: 'el ', g: 'm', fx: 'hadrin', lab: [4, -26, 'start'] },

		{ id: 'velmont', type: 'castle', front: 'nw', x: 336, y: 395, name: 'Velmont', art: '', g: 'm', fx: 'velmont', lab: [26, -20, 'start'], labN: [-28, -22, 'end'] },
		{ id: 'grauholt', type: 'castle', front: 'ne', x: 664, y: 395, name: 'Grauholt', art: '', g: 'm', fx: 'grauholt', lab: [-26, -20, 'end'], labN: [28, -22, 'start'] },
		{ id: 'sarnath', type: 'castle', front: 's', x: 500, y: 572, name: 'Sarnath', art: '', g: 'f', fx: 'sarnath', boost: 4, lab: [0, 40, 'middle'] },

		{ id: 'aldcor', type: 'aldcor', front: 'c', x: 500, y: 415, name: 'Aldcor', gloss: 'wm.g.aldcor', art: '', g: 'm', fx: 'aldcor', lab: [0, -64, 'middle'] },
	];
	const byId = {};
	NODES.forEach((n) => { byId[n.id] = n; });

	/* Roads: gate-fort, fort-fort (cross road, curved), fort-castle, castle-Aldcor. No castle-castle roads. */
	const EDGES = [
		['lobo', 'vado'], ['hrafn', 'cantera'], ['aurea', 'atalaya'], ['canon', 'kerth'], ['penitentes', 'ilse'], ['ceniza', 'hadrin'],
		['vado', 'atalaya', [282, 366]], ['cantera', 'kerth', [718, 366]], ['ilse', 'hadrin', [500, 676]],
		['vado', 'velmont'], ['atalaya', 'velmont'], ['cantera', 'grauholt'], ['kerth', 'grauholt'], ['ilse', 'sarnath'], ['hadrin', 'sarnath'],
		['velmont', 'aldcor'], ['grauholt', 'aldcor'], ['sarnath', 'aldcor'],
	].map(([a, b, c]) => ({ a, b, c }));

	const adj = {};
	NODES.forEach((n) => { adj[n.id] = []; });
	EDGES.forEach((e) => { adj[e.a].push(e.b); adj[e.b].push(e.a); });

	const WALLS = {
		vardheim: 'M212 252 Q500 120 788 252',
		solmarch: 'M200 270 Q130 560 470 748',
		askarra: 'M800 270 Q870 560 530 748',
	};
	const TERRITORY = {
		vardheim: 'M-10 -10 H1010 V215 L794 261 L788 252 Q500 120 212 252 L206 261 L-10 215 Z',
		solmarch: 'M-10 215 L206 261 L200 270 Q130 560 470 748 L500 775 L500 810 L-10 810 Z',
		askarra: 'M1010 215 L794 261 L800 270 Q870 560 530 748 L500 775 L500 810 L1010 810 Z',
	};
	const RIDGES = [
		[[210, 258], [130, 238], [60, 224], [-12, 210]],
		[[790, 258], [870, 238], [940, 224], [1012, 210]],
		[[470, 748], [500, 775], [500, 822]],
		[[530, 748], [500, 775]],
	];
	const REALM_LABEL = { vardheim: [500, 48], solmarch: [112, 500], askarra: [888, 500] };

	/* ---------- Helpers ---------- */
	function mulberry(seed) {
		let a = seed >>> 0;
		return function () {
			a = (a + 0x6D2B79F5) >>> 0;
			let x = Math.imul(a ^ (a >>> 15), 1 | a);
			x = (x + Math.imul(x ^ (x >>> 7), 61 | x)) ^ x;
			return ((x ^ (x >>> 14)) >>> 0) / 4294967296;
		};
	}
	function el(tag, attrs, parent, text) {
		const n = document.createElementNS(SVGNS, tag);
		if (attrs) for (const k in attrs) n.setAttribute(k, attrs[k]);
		if (text !== undefined) n.textContent = text;
		if (parent) parent.appendChild(n);
		return n;
	}
	function h(tag, cls, parent, html) {
		const n = document.createElement(tag);
		if (cls) n.className = cls;
		if (html !== undefined) n.innerHTML = html;
		if (parent) parent.appendChild(n);
		return n;
	}
	function esc(s) { return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])); }
	function useIcon(href, parent, cls, x, y, w, hh) {
		const u = el('use', { href: '#' + href, x, y, width: w, height: hh }, parent);
		if (cls) u.setAttribute('class', cls);
		return u;
	}
	function quadPoint(p0, c, p1, t) {
		const u = 1 - t;
		return [u * u * p0[0] + 2 * u * t * c[0] + t * t * p1[0], u * u * p0[1] + 2 * u * t * c[1] + t * t * p1[1]];
	}
	function quadTangent(p0, c, p1, t) {
		return [2 * (1 - t) * (c[0] - p0[0]) + 2 * t * (p1[0] - c[0]), 2 * (1 - t) * (c[1] - p0[1]) + 2 * t * (p1[1] - c[1])];
	}

	/* ---------- Static markup ---------- */
	const SYMBOLS = `
	<symbol id="wm-i-gate" viewBox="-14 -14 28 28"><path style="fill:var(--c);stroke:#0c0a09;stroke-width:1.1;stroke-linejoin:round" fill-rule="evenodd" d="M-12 11V-7h3v-3h2v3h2v-3h2v3h2v-3h2v3h2v-3h2v3h3V11ZM-4 11V3a4 4 0 0 1 8 0V11Z"/><path style="fill:var(--cd)" d="M-12 3h8v2h-8zM4 3h8v2H4z"/></symbol>
	<symbol id="wm-i-fort" viewBox="-14 -14 28 28"><path style="fill:var(--c);stroke:#0c0a09;stroke-width:1.1;stroke-linejoin:round" d="M-11 11V-4l2.5-6 2.5 6 3-6 3 6 3-6 3 6 2.5-6 2.5 6V11Z"/><path style="fill:none;stroke:var(--cd);stroke-width:1.6" d="M-6 -3V11M0 -3V11M6 -3V11M-11 4H11"/></symbol>
	<symbol id="wm-i-castle" viewBox="-14 -14 28 28"><path style="fill:var(--c);stroke:#0c0a09;stroke-width:1.1;stroke-linejoin:round" fill-rule="evenodd" d="M-13 11V-8h3v-2h2v2h3V-12h2v-2h2v2h2v-2h2v2h2V-8h3v-2h2v2h3V11ZM-3 11V5a3 3 0 0 1 6 0V11Z"/><path style="fill:var(--cd)" d="M-13 1h8v2h-8zM5 1h8v2H5z"/></symbol>
	<symbol id="wm-i-aldcor" viewBox="0 0 128 128"><g transform="translate(-3 2)"><polygon style="fill:var(--c);stroke:#0c0a09;stroke-width:3;stroke-linejoin:round" points="22,104 22,50 42,74 64,34 65,36 60,56 69,72 59,88 66,104"/></g><g transform="translate(3 -2)"><polygon style="fill:var(--cd);stroke:#0c0a09;stroke-width:3;stroke-linejoin:round" points="65,36 86,74 106,50 106,104 66,104 59,88 69,72 60,56"/></g></symbol>
	<symbol id="wm-e-hollow" viewBox="0 0 128 128"><g transform="translate(-3 2)"><polygon fill="#BDB6A6" points="22,104 22,50 42,74 64,34 65,36 60,56 69,72 59,88 66,104"/></g><g transform="translate(3 -2)"><polygon fill="#AAA495" points="65,36 86,74 106,50 106,104 66,104 59,88 69,72 60,56"/></g></symbol>
	<symbol id="wm-e-vardheim" viewBox="0 0 128 128"><polygon points="28,50 30,8 58,38" fill="#4E7C90"/><polygon points="100,50 98,8 70,38" fill="#4E7C90"/><polygon points="33,40 32,20 49,37" fill="#7EC8E8"/><polygon points="95,40 96,20 79,37" fill="#7EC8E8"/><polygon points="22,66 36,38 64,70" fill="#7EC8E8"/><polygon points="36,38 92,38 64,70" fill="#95D2EC"/><polygon points="22,66 64,70 44,100" fill="#4E7C90"/><polygon points="44,100 84,100 64,70" fill="#7EC8E8"/><polygon points="44,100 84,100 64,118" fill="#4E7C90"/><polygon points="106,66 92,38 64,70" fill="#7EC8E8"/><polygon points="106,66 64,70 84,100" fill="#4E7C90"/><polygon points="40,56 58,60 44,67" fill="#10242E"/><polygon points="88,56 70,60 84,67" fill="#10242E"/><polygon points="57,102 71,102 64,111" fill="#10242E"/></symbol>
	<symbol id="wm-e-solmarch" viewBox="0 0 128 128"><g transform="translate(-3.5 0)"><polygon points="48.9885,120.024 59.9537,94.7348 52.1368,92.6403" fill="#E9C341"/><polygon points="30.766,97.234 45.1284,88.594 39.406,82.8716" fill="#A3882E"/><polygon points="7.9763,79.0115 35.3597,75.8632 33.2652,68.0463" fill="#E9C341"/><polygon points="18.6015,51.8355 33.2652,59.9537 35.3597,52.1368" fill="#A3882E"/><polygon points="22.9878,22.9878 39.406,45.1284 45.1284,39.406" fill="#E9C341"/><polygon points="51.8355,18.6015 52.1368,35.3597 59.9537,33.2652" fill="#A3882E"/><path d="M64 38 A26 26 0 0 0 64 90 Z" fill="#E9C341"/></g><g transform="translate(3.5 0)"><polygon points="79.0115,7.9763 68.0463,33.2652 75.8632,35.3597" fill="#E9C341"/><polygon points="97.234,30.766 82.8716,39.406 88.594,45.1284" fill="#A3882E"/><polygon points="120.024,48.9885 92.6403,52.1368 94.7348,59.9537" fill="#E9C341"/><polygon points="109.399,76.1645 94.7348,68.0463 92.6403,75.8632" fill="#A3882E"/><polygon points="105.012,105.012 88.594,82.8716 82.8716,88.594" fill="#E9C341"/><polygon points="76.1645,109.399 75.8632,92.6403 68.0463,94.7348" fill="#A3882E"/><path d="M64 38 A26 26 0 0 1 64 90 Z" fill="#E9C341"/></g></symbol>
	<symbol id="wm-e-askarra" viewBox="0 0 128 128"><polygon points="34,34 112,34 112,52 34,52" fill="#C3242F"/><polygon points="34,36 8,44 34,52" fill="#D25B63"/><polygon points="46,52 100,52 90,78 56,78" fill="#79161D"/><polygon points="38,78 108,78 118,96 28,96" fill="#C3242F"/><polyline points="12,112 30,104 44,114 62,102 78,116 94,104 116,112" fill="none" stroke="#CD7F32" stroke-width="5"/><polygon points="28,118 36,104 44,118" fill="#CD7F32"/><polygon points="70,120 80,104 90,120" fill="#CD7F32"/></symbol>`;

	const DEFS = `
	<radialGradient id="wm-g-ground" cx="50%" cy="52%" r="62%"><stop offset="0" stop-color="#2c2019"/><stop offset=".55" stop-color="#1b1511"/><stop offset="1" stop-color="#0e0b09"/></radialGradient>
	<radialGradient id="wm-g-core" cx="50%" cy="50%" r="50%"><stop offset="0" stop-color="#ff8a3d" stop-opacity=".32"/><stop offset=".6" stop-color="#b8401a" stop-opacity=".1"/><stop offset="1" stop-color="#b8401a" stop-opacity="0"/></radialGradient>
	<linearGradient id="wm-g-vardheim" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#6aa5c4" stop-opacity=".34"/><stop offset="1" stop-color="#3f6a80" stop-opacity=".16"/></linearGradient>
	<linearGradient id="wm-g-solmarch" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#c9a640" stop-opacity=".16"/><stop offset="1" stop-color="#ecc94f" stop-opacity=".3"/></linearGradient>
	<linearGradient id="wm-g-askarra" x1="1" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#9e1c25" stop-opacity=".18"/><stop offset="1" stop-color="#e8574e" stop-opacity=".3"/></linearGradient>
	<pattern id="wm-p-vardheim" width="26" height="26" patternUnits="userSpaceOnUse"><circle cx="5" cy="6" r="1.1" fill="#d6efff" opacity=".35"/><circle cx="18" cy="15" r=".8" fill="#d6efff" opacity=".3"/><circle cx="10" cy="22" r=".9" fill="#d6efff" opacity=".25"/></pattern>
	<pattern id="wm-p-solmarch" width="16" height="16" patternUnits="userSpaceOnUse" patternTransform="rotate(35)"><path d="M0 8H16" stroke="#f1d57a" stroke-width=".7" opacity=".16"/></pattern>
	<pattern id="wm-p-askarra" width="22" height="22" patternUnits="userSpaceOnUse"><path d="M3 3l3 3M6 3l-3 3M14 14l3 3M17 14l-3 3" stroke="#e8745c" stroke-width=".8" opacity=".22"/></pattern>
	<filter id="wm-glow" x="-40%" y="-40%" width="180%" height="180%"><feGaussianBlur stdDeviation="3.2" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
	<filter id="wm-blur" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="5"/></filter>
	<filter id="wm-grain" x="0" y="0" width="100%" height="100%"><feTurbulence type="fractalNoise" baseFrequency=".85" numOctaves="2" seed="7"/><feColorMatrix values="0 0 0 0 .8  0 0 0 0 .66  0 0 0 0 .42  1.1 0 0 0 -.38"/></filter>
	<clipPath id="wm-clip-vardheim"><path d="${TERRITORY.vardheim}"/></clipPath>`;

	/* ---------- Build ---------- */
	root.classList.add('wm');
	root.innerHTML = '';
	const bar = h('div', 'wm-bar', root);
	const controls = h('div', 'wm-controls', bar);
	const btnPlay = h('button', 'wm-btn wm-btn-play', controls);
	btnPlay.type = 'button';
	const speedGroup = h('div', 'wm-speed', controls);
	speedGroup.setAttribute('role', 'group');
	const speedLabel = h('span', 'wm-speed-label', speedGroup);
	const btnSpeed = [1, 3].map((n) => {
		const b = h('button', 'wm-btn wm-btn-speed', speedGroup, n + '×');
		b.type = 'button';
		b.dataset.speed = n;
		return b;
	});
	const btnReset = h('button', 'wm-btn wm-btn-reset', controls);
	btnReset.type = 'button';
	const counters = h('div', 'wm-counters', bar);
	const counterEls = {};
	REALM_IDS.forEach((r) => {
		const c = h('div', 'wm-counter wm-r-' + r, counters,
			'<svg class="wm-emblem" viewBox="0 0 128 128" aria-hidden="true"><use href="#wm-e-' + r + '"/></svg>' +
			'<span class="wm-counter-text"><span class="wm-counter-name"></span><span class="wm-counter-val">0</span></span>' +
			'<span class="wm-counter-rate"></span><span class="wm-counter-flag"></span>');
		counterEls[r] = {
			root: c, name: c.querySelector('.wm-counter-name'), val: c.querySelector('.wm-counter-val'),
			rate: c.querySelector('.wm-counter-rate'), flag: c.querySelector('.wm-counter-flag'),
		};
	});

	const body = h('div', 'wm-body', root);
	const stage = h('div', 'wm-stage', body);
	const svg = el('svg', { class: 'wm-svg', viewBox: '0 0 1000 800', role: 'group', preserveAspectRatio: 'xMidYMid meet' }, stage);
	svg.innerHTML = '<defs>' + SYMBOLS + DEFS + '</defs>';
	const banner = h('div', 'wm-banner', stage, '<span class="wm-banner-title"></span><span class="wm-banner-sub"></span>');
	banner.setAttribute('aria-hidden', 'true');

	const side = h('div', 'wm-side', body);
	const card = h('section', 'wm-card', side);
	card.setAttribute('aria-live', 'off');
	const chronicleBox = h('section', 'wm-chronicle', side, '<h3 class="wm-h"></h3><ol class="wm-log"></ol>');
	const logList = chronicleBox.querySelector('.wm-log');
	const legend = h('section', 'wm-legend', side);

	/* --- Layers --- */
	const gGround = el('g', null, svg);
	el('rect', { x: -10, y: -10, width: 1020, height: 820, fill: 'url(#wm-g-ground)' }, gGround);
	el('rect', { x: -10, y: -10, width: 1020, height: 820, filter: 'url(#wm-grain)', opacity: '.16' }, gGround);
	el('circle', { cx: 500, cy: 415, r: 250, fill: 'url(#wm-g-core)' }, gGround);

	const rng = mulberry(20260);
	/* Three broken rings of ruins around Aldcor */
	[[46, '2 7'], [74, '14 9 3 9'], [104, '26 14 4 14']].forEach(([r, dash]) => {
		el('circle', { cx: 500, cy: 415, r, class: 'wm-ruin-ring', 'stroke-dasharray': dash }, gGround);
	});

	/* Ember cracks: seeded random walks out of Aldcor, plus the crack under the Puente de Hadrin */
	const gCracks = el('g', { class: 'wm-cracks' }, gGround);
	const crackPaths = [];
	function crack(x, y, ang, steps, len, spread, fork) {
		let d = 'M' + x.toFixed(1) + ' ' + y.toFixed(1);
		for (let i = 0; i < steps; i++) {
			ang += (rng() - 0.5) * spread;
			x += Math.cos(ang) * len * (0.6 + rng() * 0.8);
			y += Math.sin(ang) * len * (0.6 + rng() * 0.8);
			d += 'L' + x.toFixed(1) + ' ' + y.toFixed(1);
			if (fork && i > 1 && rng() < 0.28) crack(x, y, ang + (rng() < 0.5 ? 1 : -1) * (0.6 + rng() * 0.6), 3 + Math.floor(rng() * 3), len * 0.8, spread * 1.2, false);
		}
		crackPaths.push(d);
	}
	for (let i = 0; i < 11; i++) crack(500 + Math.cos(i * 0.57) * 30, 415 + Math.sin(i * 0.57) * 26, i * 0.57 + rng() * 0.3, 5 + Math.floor(rng() * 5), 24, 1.1, true);
	crack(404, 668, 0.05, 9, 22, 0.9, true);
	crack(640, 676, Math.PI - 0.1, 5, 20, 0.9, true);
	crack(300, 170, 1.1, 4, 20, 0.9, false);
	const crackGlow = el('path', { d: crackPaths.join(''), class: 'wm-crack-glow', filter: 'url(#wm-blur)' }, gCracks);
	el('path', { d: crackPaths.join(''), class: 'wm-crack-core' }, gCracks);
	crackGlow.setAttribute('fill', 'none');

	/* The shallow river of the northwest front */
	const gRiver = el('g', { class: 'wm-river' }, gGround);
	el('path', { d: 'M215 262C255 305 296 340 300 372C305 412 330 470 308 566', class: 'wm-river-bed' }, gRiver);
	el('path', { d: 'M215 262C255 305 296 340 300 372C305 412 330 470 308 566', class: 'wm-river-line' }, gRiver);

	/* Territories */
	const gTerr = el('g', null, svg);
	const terrEls = {};
	REALM_IDS.forEach((r) => {
		const g = el('g', { class: 'wm-territory wm-r-' + r }, gTerr);
		el('path', { d: TERRITORY[r], fill: 'url(#wm-g-' + r + ')' }, g);
		el('path', { d: TERRITORY[r], fill: 'url(#wm-p-' + r + ')' }, g);
		el('path', { d: WALLS[r], class: 'wm-wall-aura' }, g);
		terrEls[r] = el('path', { d: TERRITORY[r], class: 'wm-territory-mine' }, g);
	});

	/* Ridges */
	const gRidge = el('g', { class: 'wm-ridges' }, svg);
	const peaks = [];
	RIDGES.forEach((pts) => {
		let band = 'M' + pts.map((p) => p.join(' ')).join('L');
		el('path', { d: band, class: 'wm-ridge-band' }, gRidge);
		for (let i = 0; i < pts.length - 1; i++) {
			const [x0, y0] = pts[i], [x1, y1] = pts[i + 1];
			const n = Math.max(2, Math.round(Math.hypot(x1 - x0, y1 - y0) / 11));
			for (let j = 0; j < n; j++) {
				const k = j / n;
				peaks.push({ x: x0 + (x1 - x0) * k + (rng() - 0.5) * 8, y: y0 + (y1 - y0) * k + (rng() - 0.5) * 9, s: 0.75 + rng() * 0.75 });
			}
		}
	});
	peaks.sort((a, b) => a.y - b.y);
	peaks.forEach((p) => {
		const w = 20 * p.s, ht = 24 * p.s, x = p.x.toFixed(1), y = p.y.toFixed(1);
		const peak = (p.x + w * 0.05).toFixed(1) + ' ' + (p.y - ht).toFixed(1);
		el('polygon', { class: 'wm-peak-l', points: (p.x - w / 2).toFixed(1) + ' ' + y + ' ' + peak + ' ' + (p.x + w * 0.1).toFixed(1) + ' ' + y }, gRidge);
		el('polygon', { class: 'wm-peak-r', points: peak + ' ' + (p.x + w / 2).toFixed(1) + ' ' + y + ' ' + (p.x + w * 0.1).toFixed(1) + ' ' + y }, gRidge);
		void x;
	});

	/* Walls */
	const gWalls = el('g', { class: 'wm-walls' }, svg);
	REALM_IDS.forEach((r) => {
		const g = el('g', { class: 'wm-wall wm-r-' + r }, gWalls);
		el('path', { d: WALLS[r], class: 'wm-wall-bed' }, g);
		el('path', { d: WALLS[r], class: 'wm-wall-body' }, g);
		el('path', { d: WALLS[r], class: 'wm-wall-edge' }, g);
	});

	/* Roads and braziers */
	const gRoads = el('g', { class: 'wm-roads' }, svg);
	EDGES.forEach((e, i) => {
		const A = byId[e.a], B = byId[e.b];
		const p0 = [A.x, A.y], p1 = [B.x, B.y];
		let c = e.c;
		if (!c) {
			const dx = p1[0] - p0[0], dy = p1[1] - p0[1], len = Math.hypot(dx, dy), off = (rng() - 0.5) * 16;
			c = [(p0[0] + p1[0]) / 2 - dy / len * off, (p0[1] + p1[1]) / 2 + dx / len * off];
		}
		e.c = c;
		const d = 'M' + p0.join(' ') + 'Q' + c.join(' ') + ' ' + p1.join(' ');
		const g = el('g', { class: 'wm-road' }, gRoads);
		el('path', { d, class: 'wm-road-bed' }, g);
		el('path', { d, class: 'wm-road-line' }, g);
		el('path', { d, class: 'wm-road-lit' }, g);
		el('path', { d, class: 'wm-road-hot' }, g);
		const len = Math.hypot(p1[0] - p0[0], p1[1] - p0[1]);
		const n = Math.max(3, Math.round(len / 36));
		for (let k = 0; k < n; k++) {
			const tt = 0.2 + 0.6 * (n === 1 ? 0.5 : k / (n - 1));
			const pt = quadPoint(p0, c, p1, tt), tg = quadTangent(p0, c, p1, tt), tl = Math.hypot(tg[0], tg[1]) || 1;
			const side = k % 2 ? 1 : -1;
			const bx = pt[0] - tg[1] / tl * 7 * side, by = pt[1] + tg[0] / tl * 7 * side;
			const b = el('g', { class: 'wm-brazier', transform: 'translate(' + bx.toFixed(1) + ' ' + by.toFixed(1) + ')' }, g);
			el('circle', { r: 8, class: 'wm-brazier-halo' }, b);
			el('circle', { r: 2.6, class: 'wm-brazier-core' }, b).style.animationDelay = (-rng() * 2).toFixed(2) + 's';
		}
		e.el = g;
	});

	/* Realm labels */
	const realmLabels = {};
	REALM_IDS.forEach((r) => {
		const [x, y] = REALM_LABEL[r];
		const g = el('g', { class: 'wm-realm wm-r-' + r }, svg);
		useIcon('wm-e-' + r, g, 'wm-realm-emblem', x - 30, y - 30, 60, 60);
		const mine = el('text', { x, y: y + 48, 'text-anchor': 'middle', class: 'wm-realm-mine' }, g);
		const name = el('text', { x, y: y + 76, 'text-anchor': 'middle', class: 'wm-realm-name' }, g, REALMS[r].name);
		const wall = el('text', { x, y: y + 97, 'text-anchor': 'middle', class: 'wm-realm-wall' }, g);
		const gloss = el('text', { x, y: y + 114, 'text-anchor': 'middle', class: 'wm-realm-wall wm-realm-gloss' }, g);
		realmLabels[r] = { g, name, wall, gloss, mine };
	});

	/* Nodes */
	const gNodes = el('g', { class: 'wm-nodes' }, svg);
	const nodeEls = {};
	NODES.forEach((n) => {
		const big = n.type === 'aldcor';
		const g = el('g', { class: 'wm-node wm-t-' + n.type, transform: 'translate(' + n.x + ' ' + n.y + ')', tabindex: '0', role: 'button', 'data-id': n.id }, gNodes);
		el('circle', { r: big ? 44 : 34, class: 'wm-hit' }, g);
		el('circle', { r: big ? 44 : 26, class: 'wm-halo' }, g);
		el('circle', { r: big ? 38 : 24, class: 'wm-sel' }, g);
		const ring = el('circle', { r: big ? 38 : 23, class: 'wm-ring-track' }, g);
		const prog = el('circle', { r: big ? 38 : 23, class: 'wm-ring', pathLength: '100', transform: 'rotate(-90)' }, g);
		void ring;
		const ico = el('g', { class: 'wm-ico' }, g);
		if (big) useIcon('wm-i-aldcor', ico, '', -30, -32, 60, 60);
		else useIcon('wm-i-' + n.type, ico, '', -14, -14, 28, 28);
		const lab = el('text', { class: 'wm-label wm-l-' + (n.type === 'gate' || n.type === 'fort' ? 'minor' : n.type), x: n.lab[0], y: n.lab[1], 'text-anchor': n.lab[2] }, g);
		nodeEls[n.id] = { g, prog, lab, ico };
	});

	/* ---------- State and simulation ---------- */
	const state = {};
	let playing = false, started = false, speed = 1, visible = false, selected = null, hovered = null;
	let analysis = null, lastHorn = -1e9, muted = false, bannerTimer = 0;
	const FLAME_TIME = 42;

	function reset() {
		state.owner = {};
		NODES.forEach((n) => { state.owner[n.id] = n.type === 'gate' ? n.realm : 'hollow'; });
		state.embers = { vardheim: 0, solmarch: 0, askarra: 0 };
		state.flame = null;
		state.flameT = 0;
		state.simTime = 0;
		state.log = [];
		state.ai = {};
		REALM_IDS.forEach((r, i) => { state.ai[r] = { target: null, t: 0, dur: 1, cool: 0.4 + i * 0.9 }; });
		analysis = analyze();
		banner.classList.remove('is-on');
		render();
		renderLog();
	}

	/* Chains: BFS from each realm's gates over nodes it owns. */
	function analyze() {
		const connected = {};
		REALM_IDS.forEach((r) => {
			const set = new Set();
			const queue = NODES.filter((n) => n.type === 'gate' && n.realm === r).map((n) => n.id);
			queue.forEach((id) => set.add(id));
			while (queue.length) {
				const id = queue.shift();
				adj[id].forEach((nb) => {
					if (!set.has(nb) && state.owner[nb] === r) { set.add(nb); queue.push(nb); }
				});
			}
			connected[r] = set;
		});
		const isolated = new Set();
		NODES.forEach((n) => {
			const o = state.owner[n.id];
			if (n.type !== 'gate' && o !== 'hollow' && !connected[o].has(n.id)) isolated.add(n.id);
		});
		const lit = EDGES.map((e) => {
			const oa = state.owner[e.a];
			if (oa === 'hollow' || oa !== state.owner[e.b]) return null;
			return connected[oa].has(e.a) && connected[oa].has(e.b) ? oa : null;
		});
		const castles = { vardheim: 0, solmarch: 0, askarra: 0 };
		NODES.forEach((n) => { if (n.type === 'castle' && castles[state.owner[n.id]] !== undefined) castles[state.owner[n.id]]++; });
		const rate = { vardheim: 0, solmarch: 0, askarra: 0 };
		NODES.forEach((n) => {
			const o = state.owner[n.id];
			if (n.type === 'gate' || o === 'hollow' || isolated.has(n.id)) return;
			rate[o] += n.type === 'aldcor' ? (state.flame === o ? 5 : 1) : (n.boost || (n.type === 'castle' ? 3 : 1));
		});
		return { connected, isolated, lit, castles, rate };
	}

	function canTarget(r, n) {
		if (n.type === 'gate' || state.owner[n.id] === r) return false;
		if (n.type === 'aldcor' && analysis.castles[r] < 2) return false;
		return adj[n.id].some((nb) => state.owner[nb] === r);
	}

	function captureChance(r, n) {
		const o = state.owner[n.id];
		let p = o === 'hollow'
			? { fort: 0.74, castle: 0.58, aldcor: 0.5 }[n.type]
			: { fort: 0.45, castle: 0.34, aldcor: 0.3 }[n.type];
		if (o !== 'hollow' && analysis.isolated.has(n.id)) p += 0.3;
		if (state.flame && state.flame !== r) p += 0.2;
		return Math.max(0.08, Math.min(0.92, p));
	}

	function pickTarget(r) {
		const taken = new Set(REALM_IDS.map((x) => state.ai[x].target).filter(Boolean));
		const cands = NODES.filter((n) => canTarget(r, n) && !taken.has(n.id));
		if (!cands.length) return null;
		const weights = cands.map((n) => {
			const o = state.owner[n.id];
			let w = o === 'hollow' ? 3 : 1.6;
			if (o !== 'hollow' && analysis.isolated.has(n.id)) w += 3;
			if (n.type === 'castle') w += 1.5;
			if (n.type === 'aldcor') w += 5;
			return w;
		});
		let roll = Math.random() * weights.reduce((a, b) => a + b, 0);
		for (let i = 0; i < cands.length; i++) { roll -= weights[i]; if (roll <= 0) return cands[i]; }
		return cands[cands.length - 1];
	}

	function startAttack(r) {
		const ai = state.ai[r], n = pickTarget(r);
		if (!n) { ai.cool = 1; return; }
		const base = { fort: 5, castle: 7.5, aldcor: 9 }[n.type];
		ai.target = n.id;
		ai.t = 0;
		ai.dur = base * (0.8 + Math.random() * 0.4);
		const ne = nodeEls[n.id];
		ne.g.classList.add('wm-attacked');
		ne.g.style.setProperty('--rc', REALMS[r].accent);
		ne.prog.style.strokeDasharray = '0 100';
	}

	function endAttack(r) {
		const ai = state.ai[r], ne = nodeEls[ai.target];
		if (ne) { ne.g.classList.remove('wm-attacked'); ne.prog.style.strokeDasharray = '0 100'; }
		ai.target = null;
		ai.cool = 0.7 + Math.random() * 1.5;
	}

	function resolveAttack(r) {
		const ai = state.ai[r], n = byId[ai.target];
		if (!canTarget(r, n)) { endAttack(r); return; }
		const from = state.owner[n.id];
		const won = Math.random() < captureChance(r, n);
		endAttack(r);
		if (!won) { pushLog({ k: 'fail', realm: r, node: n.id }); return; }
		const wasIsolated = analysis.isolated;
		state.owner[n.id] = r;
		pushLog({ k: 'take', realm: r, node: n.id, from });
		if (n.type === 'aldcor') {
			state.flame = r;
			state.flameT = FLAME_TIME;
			pushLog({ k: 'flame', realm: r });
			if (!muted) showBanner(r);
		}
		analysis = analyze();
		analysis.isolated.forEach((id) => { if (!wasIsolated.has(id)) pushLog({ k: 'isolated', node: id, realm: state.owner[id] }); });
		render();
		/* Horns for the visitor's realm */
		const mine = E.realm;
		if (mine && r === mine) horn('horn-' + mine);
		else if (mine && from === mine) horn('horn-lost-' + mine);
	}

	function horn(name) {
		const now = performance.now();
		if (muted || now - lastHorn < 4000) return;
		lastHorn = now;
		E.sound.play(name);
	}

	function showBanner(r) {
		banner.style.setProperty('--c', REALMS[r].accent);
		banner.style.setProperty('--cd', REALMS[r].deep);
		banner.dataset.realm = r;
		banner.querySelector('.wm-banner-title').textContent = t('wm.banner');
		banner.querySelector('.wm-banner-sub').textContent = t('wm.banner.sub', { realm: REALMS[r].name });
		banner.classList.add('is-on');
		clearTimeout(bannerTimer);
		bannerTimer = setTimeout(() => banner.classList.remove('is-on'), 4600);
	}

	function step(dt) {
		state.simTime += dt;
		REALM_IDS.forEach((r) => {
			const ai = state.ai[r];
			state.embers[r] += analysis.rate[r] * dt;
			if (!ai.target) {
				ai.cool -= dt;
				if (ai.cool <= 0) startAttack(r);
			} else {
				ai.t += dt;
				const p = Math.min(100, ai.t / ai.dur * 100);
				nodeEls[ai.target].prog.style.strokeDasharray = p.toFixed(1) + ' 100';
				if (ai.t >= ai.dur) resolveAttack(r);
			}
		});
		if (state.flame) {
			state.flameT -= dt;
			if (state.flameT <= 0) {
				state.owner.aldcor = 'hollow';
				state.flame = null;
				pushLog({ k: 'flameOut' });
				analysis = analyze();
				render();
			}
		}
		renderCounters();
	}

	/* ---------- Event log ---------- */
	function pushLog(ev) {
		state.log.unshift(ev);
		state.log.length = Math.min(state.log.length, 6);
		renderLog(true);
	}

	function nodeRef(id, cap) {
		const n = byId[id];
		if (E.lang !== 'es') return n.name;
		const s = (n.art || '') + n.name;
		return cap ? s.charAt(0).toUpperCase() + s.slice(1) : s;
	}
	function realmHtml(r) {
		return '<b class="wm-rn wm-r-' + r + '">' + esc(REALMS[r].name) + '</b>';
	}
	function ownerHtml(o) { return o === 'hollow' ? '<b class="wm-rn wm-r-hollow">' + esc(t('wm.hollowThe')) + '</b>' : realmHtml(o); }

	function renderLog(fresh) {
		logList.innerHTML = '';
		if (!state.log.length) {
			h('li', 'wm-log-empty', logList, esc(t('wm.chronicle.empty')));
			return;
		}
		state.log.forEach((ev, i) => {
			const li = h('li', 'wm-log-item', logList);
			li.style.setProperty('--age', Math.max(0.28, 1 - i * 0.13));
			const rr = ev.realm || 'hollow';
			li.classList.add('wm-r-' + rr);
			if (fresh && i === 0 && !reduced) li.classList.add('is-new');
			const vars = { realm: ev.realm ? realmHtml(ev.realm) : '', from: ev.from ? ownerHtml(ev.from) : '' };
			if (ev.node) {
				vars.node = '<em>' + esc(nodeRef(ev.node)) + '</em>';
				vars.Node = '<em>' + esc(nodeRef(ev.node, true)) + '</em>';
				vars.iso = byId[ev.node].g === 'f' ? 'aislada' : 'aislado';
			}
			li.innerHTML = '<i class="wm-dot"></i><span>' + t('wm.ev.' + ev.k, vars) + '</span>';
		});
	}

	/* ---------- Rendering ---------- */
	function nodeTitle(n) { return n.name; }
	function glossOf(n) { return E.lang === 'en' && n.gloss ? t(n.gloss) : ''; }
	function ownerName(o) { return o === 'hollow' ? t('wm.hollow') : REALMS[o].name; }

	function render() {
		const mine = E.realm;
		NODES.forEach((n) => {
			const o = state.owner[n.id], ne = nodeEls[n.id], iso = analysis.isolated.has(n.id);
			const cls = ['wm-node', 'wm-t-' + n.type, 'wm-own-' + o];
			if (iso) cls.push('wm-isolated');
			if (n.id === 'aldcor' && state.flame) cls.push('wm-flame');
			if (n.id === selected) cls.push('is-selected');
			if (nodeEls[n.id].g.classList.contains('wm-attacked')) cls.push('wm-attacked');
			if (n.type === 'gate' && n.realm === mine) cls.push('wm-mine');
			ne.g.setAttribute('class', cls.join(' '));
			const label = [nodeTitle(n), t('wm.type.' + n.type), ownerName(o)];
			if (iso) label.push(t('wm.lg.isolated'));
			if (n.playable) label.push(t('wm.playable'));
			if (n.type === 'gate' && n.realm === mine) label.push(t('wm.yourBanner'));
			ne.g.setAttribute('aria-label', label.join(', '));
		});
		EDGES.forEach((e, i) => {
			const r = analysis.lit[i];
			e.el.setAttribute('class', 'wm-road' + (r ? ' is-lit wm-r-' + r : '') + (selected && (e.a === selected || e.b === selected) ? ' is-hot' : ''));
		});
		REALM_IDS.forEach((r) => {
			terrEls[r].classList.toggle('is-on', mine === r);
			realmLabels[r].g.classList.toggle('is-mine', mine === r);
			counterEls[r].root.classList.toggle('is-mine', mine === r);
			counterEls[r].root.classList.toggle('has-flame', state.flame === r);
		});
		renderCounters(true);
		renderCard();
	}

	function renderCounters(force) {
		REALM_IDS.forEach((r) => {
			const c = counterEls[r], v = Math.floor(state.embers[r]);
			if (force || c.val.dataset.v !== String(v)) { c.val.dataset.v = v; c.val.textContent = v.toLocaleString(E.lang === 'es' ? 'es-ES' : 'en-US'); }
			if (force) c.rate.textContent = t('wm.perSec', { n: analysis.rate[r] });
		});
	}

	function renderCard() {
		const n = selected && byId[selected];
		if (!n) {
			card.innerHTML = '<p class="wm-hint">' + esc(t('wm.hint')) + '</p>';
			return;
		}
		const o = state.owner[n.id], iso = analysis.isolated.has(n.id), mine = E.realm;
		const gloss = glossOf(n);
		let status;
		if (n.type === 'gate') status = t('wm.st.gate', { realm: REALMS[n.realm].name });
		else if (o === 'hollow') status = t('wm.st.neutral');
		else if (iso) status = t('wm.st.isolated', { realm: REALMS[o].name });
		else status = t('wm.st.linked', { realm: REALMS[o].name });
		const fx = n.type === 'gate' ? t('wm.fx.gate') : t('wm.fx.' + n.fx);
		const badges = ['<span class="wm-badge">' + esc(t('wm.type.' + n.type)) + '</span>', '<span class="wm-badge">' + esc(t('wm.front.' + n.front)) + '</span>'];
		if (n.playable) badges.push('<span class="wm-badge wm-badge-hot">' + esc(t('wm.playable')) + '</span>');
		if (n.type === 'gate' && n.realm === mine) badges.push('<span class="wm-badge wm-badge-mine">' + esc(t('wm.yourBanner')) + '</span>');
		let extra = '';
		if (n.type === 'aldcor') {
			extra = '<dt>' + esc(t('wm.castlesHeld')) + '</dt><dd>' + REALM_IDS.map((r) => '<span class="wm-pair">' + realmHtml(r) + ' ' + analysis.castles[r] + '</span>').join(' · ') + '</dd>';
			extra += '<dt>' + esc(t('wm.status')) + '</dt><dd>' + esc(state.flame ? t('wm.flameBurns', { realm: REALMS[state.flame].name }) : (REALM_IDS.some((r) => analysis.castles[r] >= 2) ? status : t('wm.sealed'))) + '</dd>';
		} else {
			extra = '<dt>' + esc(t('wm.status')) + '</dt><dd class="' + (iso ? 'wm-warn' : '') + '">' + esc(status) + '</dd>';
		}
		const out = n.type === 'gate' ? '' : '<dt>' + esc(t('wm.output')) + '</dt><dd>×' + (n.type === 'aldcor' ? 5 : (n.boost || (n.type === 'castle' ? 3 : 1))) + '</dd>';
		card.innerHTML =
			'<div class="wm-card-head wm-own-' + o + (iso ? ' wm-isolated' : '') + '">' +
			'<svg class="wm-card-ico" viewBox="' + (n.type === 'aldcor' ? '0 0 128 128' : '0 0 28 28') + '" aria-hidden="true"><use href="#wm-i-' + n.type + '"/></svg>' +
			'<div><h3 class="wm-card-name">' + esc(n.name) + '</h3>' + (gloss ? '<p class="wm-card-gloss">' + esc(gloss) + '</p>' : '') + '</div></div>' +
			'<div class="wm-badges">' + badges.join('') + '</div>' +
			'<p class="wm-card-fx">' + esc(fx) + '</p>' +
			'<dl class="wm-rows"><dt>' + esc(t('wm.heldBy')) + '</dt><dd>' + ownerHtml(o) + '</dd>' + extra + out + '</dl>';
	}

	function renderStatic() {
		btnPlay.innerHTML = (playing
			? '<svg viewBox="0 0 12 12" aria-hidden="true"><path d="M2 1h3v10H2zM7 1h3v10H7z"/></svg>'
			: '<svg viewBox="0 0 12 12" aria-hidden="true"><path d="M2 1l9 5-9 5z"/></svg>') + '<span>' + esc(t(playing ? 'wm.pause' : 'wm.play')) + '</span>';
		btnPlay.setAttribute('aria-pressed', playing ? 'true' : 'false');
		btnReset.innerHTML = '<svg viewBox="0 0 12 12" aria-hidden="true"><path d="M6 1.5a4.5 4.5 0 1 0 4.2 2.9" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M5 .5l2.5 1.2L5.3 3.8z"/></svg><span>' + esc(t('wm.reset')) + '</span>';
		speedLabel.textContent = t('wm.speed');
		btnSpeed.forEach((b) => b.setAttribute('aria-pressed', Number(b.dataset.speed) === speed ? 'true' : 'false'));
		svg.setAttribute('aria-label', t('wm.aria.map'));
		REALM_IDS.forEach((r) => {
			counterEls[r].name.textContent = REALMS[r].name;
			counterEls[r].root.title = t('wm.embers') + ' · ' + REALMS[r].name;
			counterEls[r].flag.textContent = '';
			realmLabels[r].mine.textContent = E.realm === r ? t('wm.yourBanner') : '';
		});
		/* Wall names: the Spanish original is the main label, the English gloss follows in English mode. */
		const walls = { vardheim: ['Muro de Escarcha', 'Frost Wall'], solmarch: ['Muralla del Alba', 'Dawn Wall'], askarra: ['Cinturón de Bronce', 'Bronze Belt'] };
		REALM_IDS.forEach((r) => { realmLabels[r].wall.textContent = walls[r][0]; realmLabels[r].gloss.textContent = E.lang === 'en' ? walls[r][1] : ''; });
		chronicleBox.querySelector('.wm-h').textContent = t('wm.chronicle');
		legend.innerHTML = '<h3 class="wm-h">' + esc(t('wm.legend')) + '</h3><ul class="wm-lg">' +
			[['gate', 'wm-i-gate', '0 0 28 28'], ['fort', 'wm-i-fort', '0 0 28 28'], ['castle', 'wm-i-castle', '0 0 28 28'], ['aldcor', 'wm-i-aldcor', '0 0 128 128']].map(([k, id, vb]) =>
				'<li><svg viewBox="' + vb + '" class="wm-lg-ico" aria-hidden="true"><use href="#' + id + '"/></svg>' + esc(t('wm.lg.' + k)) + '</li>').join('') +
			'<li><svg viewBox="0 0 30 12" class="wm-lg-road wm-lg-lit" aria-hidden="true"><path d="M0 6H30" class="wm-road-line"/><path d="M0 6H30" class="wm-road-lit"/><circle cx="8" cy="3" r="2.6"/><circle cx="22" cy="9" r="2.6"/></svg>' + esc(t('wm.lg.lit')) + '</li>' +
			'<li><svg viewBox="0 0 30 12" class="wm-lg-road" aria-hidden="true"><path d="M0 6H30" class="wm-road-line"/><circle cx="8" cy="3" r="2.6" class="wm-cold"/><circle cx="22" cy="9" r="2.6" class="wm-cold"/></svg>' + esc(t('wm.lg.cold')) + '</li>' +
			'<li class="wm-isolated"><svg viewBox="0 0 28 28" class="wm-lg-ico wm-own-vardheim" aria-hidden="true"><use href="#wm-i-fort"/></svg>' + esc(t('wm.lg.isolated')) + '</li></ul>';
		NODES.forEach((n) => {
			const tx = nodeTitle(n);
			nodeEls[n.id].lab.textContent = tx;
		});
	}

	function fullRender() {
		renderStatic();
		render();
		renderLog();
	}

	/* ---------- Selection ---------- */
	function select(id) {
		if (selected === id) return;
		selected = id;
		render();
	}
	function clearSelection() {
		if (selected === null) return;
		selected = null;
		render();
	}

	NODES.forEach((n) => {
		const g = nodeEls[n.id].g;
		g.addEventListener('pointerenter', () => select(n.id));
		g.addEventListener('focus', () => select(n.id));
		g.addEventListener('click', (ev) => { ev.stopPropagation(); select(n.id); E.sound.play('click', { volume: 0.35 }); });
		g.addEventListener('keydown', (ev) => {
			if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); select(n.id); E.sound.play('click', { volume: 0.35 }); }
		});
	});
	svg.addEventListener('click', clearSelection);
	root.addEventListener('keydown', (ev) => {
		if (ev.key === 'Escape') { clearSelection(); if (document.activeElement && root.contains(document.activeElement) && document.activeElement.classList.contains('wm-node')) document.activeElement.blur(); }
	});

	/* ---------- Loop and controls ---------- */
	let raf = 0, last = 0;
	function active() { return playing && visible && !document.hidden; }
	function frame(ts) {
		raf = 0;
		if (!active()) return;
		const dt = Math.min(0.1, (ts - last) / 1000);
		last = ts;
		step(dt * speed);
		raf = requestAnimationFrame(frame);
	}
	function updateLoop() {
		root.classList.toggle('is-running', active());
		if (active()) {
			if (!raf) { last = performance.now(); raf = requestAnimationFrame(frame); }
		} else if (raf) { cancelAnimationFrame(raf); raf = 0; }
	}
	function setPlaying(v) { playing = v; renderStatic(); updateLoop(); }

	btnPlay.addEventListener('click', () => { started = true; setPlaying(!playing); });
	btnReset.addEventListener('click', () => { reset(); renderStatic(); });
	btnSpeed.forEach((b) => b.addEventListener('click', () => { speed = Number(b.dataset.speed); renderStatic(); }));
	document.addEventListener('visibilitychange', updateLoop);
	E.whenVisible(stage, () => {
		visible = true;
		if (!started) { started = true; playing = true; renderStatic(); }
		updateLoop();
	}, () => { visible = false; updateLoop(); }, { threshold: 0.12 });

	E.on('lang', fullRender);
	E.on('realm', () => { render(); renderStatic(); });

	/* Narrow containers: crop the viewBox to Eldrun and enlarge nodes through CSS classes. */
	function fit() {
		const w = stage.clientWidth;
		svg.setAttribute('viewBox', w && w < 720 ? '86 24 828 776' : '0 0 1000 800');
		root.classList.toggle('wm-compact', !!w && w < 720);
		root.classList.toggle('wm-narrow', !!w && w < 560);
		/* Pull the side realm names inside the cropped view. */
		const shift = w && w < 720 ? 60 : 0;
		realmLabels.solmarch.g.setAttribute('transform', 'translate(' + shift + ' 0)');
		realmLabels.askarra.g.setAttribute('transform', 'translate(' + (-shift) + ' 0)');
		NODES.forEach((n) => {
			if (!n.labN) return;
			const l = (w && w < 560 ? n.labN : n.lab), lab = nodeEls[n.id].lab;
			lab.setAttribute('x', l[0]); lab.setAttribute('y', l[1]); lab.setAttribute('text-anchor', l[2]);
		});
	}
	if ('ResizeObserver' in window) new ResizeObserver(fit).observe(stage);
	else window.addEventListener('resize', fit);
	fit();

	window.EldmarkWarMap = {
		play() { started = true; setPlaying(true); },
		pause() { started = true; setPlaying(false); },
		reset() { reset(); },
		setSpeed(n) { speed = n === 3 ? 3 : 1; renderStatic(); },
		/* Runs the simulation forward without drawing every frame (used by tests). */
		advance(seconds) {
			muted = true;
			for (let s = 0; s < seconds; s += 0.1) step(0.1);
			muted = false;
			render();
		},
	};

	reset();
	renderStatic();
})();
