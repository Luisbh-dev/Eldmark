class_name BotBrain
extends RefCounted
## Cerebro de un bot: genera entradas de jugador deterministas para las pruebas y la carga.
##
## Lo usan los bots del cliente (fase 2) y los jugadores falsos del servidor. Es una función de
## (semilla, secuencia de llamadas): no lee el reloj ni aleatoriedad global, solo su propio
## [RandomNumberGenerator]. Con la misma semilla y las mismas posiciones, produce siempre las mismas
## entradas.
## [br][br]
## Patrones ([enum Pattern]):
## [br]- [constant WANDER]: pasea. Cada 60-180 ticks cambia de dirección o se para un momento,
## a veces esprinta y salta de vez en cuando.
## [br]- [constant CIRCLE]: da vueltas alrededor de [code]home[/code] a media distancia del radio.
## [br]- [constant IDLE]: no hace nada (entradas neutras).
## [br]- [constant JUMPY]: como [constant WANDER], pero salta casi siempre que puede.
## [br]- [constant COMBAT]: busca al enemigo más cercano (lo da [method set_enemy_finder]), se
## acerca, ataca (ligeros en combo y, a veces, un fuerte cargado), y de vez en cuando bloquea o esquiva.
## Sin enemigo a la vista pasea como [constant WANDER] (sin saltar). Todo sale de su generador con
## semilla, así que con la misma semilla y las mismas posiciones hace siempre lo mismo.
## [br]- [constant SIEGE] (GUE-15, docs/fuerte.md sección 7): asedia o defiende un fuerte. Necesita un
## [SiegeView] y unas [ApproachRoutes] ([method set_siege]). Ver abajo.
## [br][br]
## Si el bot se aleja de [code]home[/code] más que el radio, vuelve hacia él hasta quedar dentro
## de [constant RETURN_RELEASE_FRACTION] del radio.
## [br][br]
## [b]Asedio ([constant SIEGE]).[/b] En cada tick elige, por este orden:
## [br]1. Si un enemigo (el que da [method set_enemy_finder], como en [constant COMBAT]) está a menos de
## [constant SIEGE_FIGHT_RANGE] y se puede alcanzar (no está tras una puerta que cierra el paso a su reino),
## pelea con él igual que [constant COMBAT]. Mientras el círculo no está activo, antes que a nadie busca a los PNJ
## que guardan el fuerte (los Huecos, el Capitán y la guarnición del dueño; [method set_defender_finder], F6b): el
## capitán tiene que caer para abrir el círculo. Si persiguiendo a alguien que está a más de
## [constant COMBAT_ENGAGE_DISTANCE] no se le acerca en [constant SIEGE_STUCK_TICKS] ticks (un muro, la pasarela),
## deja de perseguir durante [constant SIEGE_CHASE_GIVE_UP_TICKS] ticks y sigue con su plan. Cuenta cada persecución por
## separado: llegar a la distancia de pelea, o cambiar de blanco, empieza otra.
## [br]2. [b]Marcha[/b]: sigue la ruta de su reino, [constant ApproachRoutes.BRIDGE] o
## [constant ApproachRoutes.FORD] (la elige con su generador al empezar y tras cada reaparición), hasta la
## explanada delante de la puerta, esprintando por los tramos largos si no hay enemigos cerca.
## [br]3. [b]Asalto[/b]: llegado a la explanada, si la puerta cierra el paso a su reino
## ([method SiegeView.is_gate_closed_for]) se acerca a ella y la golpea (ligeros en combo y algún fuerte). Solo desde
## fuera: si ya está dentro del fuerte (la puerta se ha reparado con él dentro, o el fuerte ha cambiado de dueño con él en
## la pasarela) sigue con la pasarela y el círculo, que no necesitan la puerta.
## [br]4. [b]Círculo[/b]: con la puerta abierta para su reino (rota, o suya) entra en el círculo de captura y
## se queda dentro cerca del centro: los atacantes lo toman y el dueño lo defiende (salvo los que tienen el papel de la
## pasarela, GUE-45: ver abajo).
## [br]Si no avanza durante [constant SIEGE_STUCK_TICKS] mientras camina, primero prueba un salto y, si sigue
## igual, un desvío lateral. Un salto de posición de más de [constant SIEGE_TELEPORT_DISTANCE] metros en un
## tick (reaparición) reinicia la ruta.
## [br][b]Golpes avisados[/b] (F6b): antes que todo lo anterior, si está en la zona de un golpe avisado con
## TELEGRAPH (el imbloqueable del Capitán del Vado y los fuertes de los demás PNJ; los da
## [method set_threat_finder]), sale de ella en línea recta desde quien golpea, con una esquiva al empezar y
## esprintando, sin bloquear ([constant SiegeTask.EVADE]). Bloquear no frena el imbloqueable y salir es lo más simple
## que funciona con todos; no usa el generador, así que sigue siendo determinista.
## [br][b]Reunión[/b] (GUE-44): un atacante que empieza o reaparece en su campamento no sale solo. Espera a los suyos
## en el punto de reunión (la salida del campamento, el primer punto de sus rutas: [method get_siege_rally_point];
## [constant SiegeTask.RALLY]) y sale cuando hay [constant SIEGE_RALLY_GROUP_SIZE] de su reino a menos de
## [constant SIEGE_RALLY_RADIUS] (él incluido; los cuenta quien da [method set_ally_counter]), cuando ya hay
## [constant SIEGE_RALLY_JOIN_COUNT] de los suyos peleando en el fuerte (va a ayudarlos: un asalto en marcha no se deja
## sin refuerzos, y sin atacantes el capitán se cura) o, como mucho, en la siguiente salida del reloj común (cada
## [constant SIEGE_RALLY_PERIOD_TICKS] ticks de partida, [method next_rally_departure]). Todo el grupo va por la misma
## ruta, que sale del tick de salida ([method rally_route_index]) y no del generador de cada uno, así que los que salen
## juntos llegan juntos. Sin contador de aliados, o con el grupo a 1 o menos ([method set_rally]), no espera nunca. El
## dueño no espera: defiende en cuanto puede.
## [br][b]Formación[/b] (GUE-44): los personajes no chocan entre sí y los bots que siguen los mismos puntos acaban uno
## encima de otro, donde un golpe que barre les da a todos. En grupo (con contador de aliados y la reunión puesta) cada
## bot lleva su hueco ([method get_siege_slot]), que suma a donde va: de lado en la marcha, a lo largo de la puerta al
## golpearla, en el círculo y en el punto de reunión.
## [br][b]Pasarela[/b] (GUE-45): una parte de los bots ([constant SIEGE_WALKWAY_SHARE], por su semilla:
## [method is_walkway_seed]) tiene el papel de la pasarela, si las rutas la conocen ([method ApproachRoutes.has_walkway]).
## Si su reino es el dueño, en lugar de quedarse en el círculo entra en el fuerte, sube por una rampa (una ruta de puntos
## precalculada de los datos, comprobada con la malla de navegación de los PNJ) y guarda su puesto encima de la puerta
## ([constant SiegeTask.WALKWAY]). Si es atacante, solo la mitad de ellos ([constant SIEGE_WALKWAY_SWEEP_SHARE],
## [method is_walkway_sweeper]): al entrar en el fuerte recorre la pasarela una vez hasta ese puesto (la limpia) y luego
## salta al patio y va al círculo. Desde la pasarela no se alcanza con el arma a nadie del suelo (el
## sector llega de 0,2 a 2 m sobre los pies y la pasarela está a 3,35 m, tras la empalizada): dentro del recinto, quien
## está más de [constant SIEGE_LEVEL_TOLERANCE] m más arriba o más abajo no es un blanco cuerpo a cuerpo ni un golpe
## avisado que haya que evitar, así que en la pasarela se pelea con quien sube, sin salirse del eje en las esquinas y sin
## esquivar de lado (con el arco del kit sí se tira a otro nivel, si hay tiro: ver abajo).
## [br][br]
## [b]Kit de la fase 4 (H5; docs/habilidades.md, sección 7.1).[/b] Si quien lleva el bot le da su estado de
## combate ([method set_combat_source]: el predicho en un cliente, el del servidor en un jugador falso), los
## patrones [constant COMBAT] y [constant SIEGE] pelean con todo el equipo: las habilidades del arma activa
## según para qué sirven por sus datos ([enum KitRole]: golpe corto, embestida para acercarse, muro que se
## mantiene pulsado mientras dura la canalización, salto atrás, disparo), el cambio de arma (al arco de lejos, a
## la espada de cerca), las pociones (vida por debajo de [constant KIT_HEALTH_POTION_BELOW] con
## [method set_health_source], resistencia por debajo de [constant KIT_STAMINA_POTION_BELOW]) y el arco: guarda
## la distancia, alterna disparos rápidos y tensados y apunta con el tiro adelantado ([method lead_look]:
## [method Ballistics.solve_lead] y [method AimRay.look_for]), con el bit [constant PlayerInput.AIM_LEFT] de su
## hombro (el izquierdo si la semilla es impar). Remata a un enemigo derribado (el buscador devuelve un
## [BotTarget]) y levanta a un aliado derribado ([method set_ally_finder]) manteniendo INTERACT. Solo pulsa lo
## que su estado deja usar ([method ActionMachine.ability_status]): el servidor decide igual, pero un bot
## honrado no machaca botones (eso es del tramposo, [BotCheatBrain]). Sin estado (o con [member use_kit] en
## false) pelea como en la fase 3, con la misma secuencia de entradas que antes.
## [br]En [constant SIEGE] (integración con F6b) el kit pelea en el paso 1 del plan con el blanco que toque, el PNJ
## defensor o el enemigo (a él apunta el arco, con la velocidad que dé su buscador), pero no levanta a nadie: sigue su
## plan. [b]El arco en el asedio[/b] (revisión de la integración): tira a quien está a menos de
## [constant SIEGE_BOW_FIGHT_RANGE] y [b]a tiro[/b], sin la regla de dejar una persecución (no persigue: guarda la distancia) y
## sin el filtro de nivel, que es del cuerpo a cuerpo (desde la pasarela tira al patio y al revés). A tiro quiere decir
## que la flecha llega: con lo que sabe del fuerte, la puerta entera corta el tiro entre un lado y otro de la empalizada
## a todos los reinos, también al dueño (su cuerpo de vista para las flechas en los dos sentidos), y con la puerta rota
## solo se tira de dentro afuera, o al revés, por el vano ([constant SIEGE_BOW_GAP_HALF_WIDTH]); y, si quien lo lleva se
## la da, con la línea de tiro de verdad ([method set_line_of_sight]: el servidor y [code]--bot[/code], los rayos de su
## cámara y de su boca al centro del blanco en su mundo, [method bow_sight_clear]). Sin tiro no pelea con el arco: sigue
## su plan (o, de cerca, saca la espada). Con la espada en la mano y el arco a la espalda, saca el arco para quien está
## lejos y a tiro, o más cerca si la espada no le llega (en la pasarela, por ejemplo). Ir a rematar a un derribado es
## acercarse, así que lleva la regla de las persecuciones, como la espada. Para golpear la puerta saca la espada si la
## lleva (las flechas le hacen poco). En la pasarela, como no esquiva de lado, el arquero no se mueve en ella y nadie
## usa las habilidades que avanzan en línea recta (la embestida, que además empuja, y el salto atrás): sacaban a los dos
## de ella. Peleando en ella mira al blanco (para que el arma le llegue aunque esté de través), pero lo que mueve
## (acercarse y la esquiva hacia atrás) va por el eje de la pasarela, también sin el kit.

## [constant SIEGE] va al final para no mover los valores de los demás patrones.
enum Pattern { WANDER, CIRCLE, IDLE, JUMPY, COMBAT, SIEGE }

## Qué hace un bot de [constant SIEGE] en este tick ([method get_siege_task]). [constant EVADE] (F6b, al final
## para no mover los demás): sale de la zona de un golpe avisado. [constant RALLY] (GUE-44, después): espera a los suyos
## en el punto de reunión de su campamento. [constant WALKWAY] (GUE-45, la última): sube a la pasarela, va por ella o
## guarda su puesto.
enum SiegeTask { NONE, FIGHT, MARCH, ASSAULT, HOLD, EVADE, RALLY, WALKWAY }

## Para qué usa el kit una habilidad, según sus datos ([method kit_role]): golpe corto con forma
## ([constant CLOSE]), avance hacia delante para acercarse ([constant GAP_CLOSER]), canalización que bloquea
## ([constant GUARD], el muro), avance hacia atrás ([constant ESCAPE]) o disparo ([constant SHOT]).
enum KitRole { NONE, CLOSE, GAP_CLOSER, GUARD, ESCAPE, SHOT }

## Duración mínima de un tramo de paseo (ticks).
const SEGMENT_MIN_TICKS: int = 60
## Duración máxima de un tramo de paseo (ticks).
const SEGMENT_MAX_TICKS: int = 180
## Probabilidad de que un tramo de paseo sea una parada.
const PAUSE_CHANCE: float = 0.2
## Probabilidad de que un tramo en marcha sea de esprint.
const SPRINT_CHANCE: float = 0.3
## Probabilidad de que un tramo en marcha lleve el movimiento ligeramente lateral.
const STRAFE_CHANCE: float = 0.25
## Separación entre saltos de un paseante (ticks, mínimo y máximo).
const WANDER_JUMP_GAP_TICKS: Vector2i = Vector2i(120, 420)
## Separación entre saltos de un [constant JUMPY] (ticks, mínimo y máximo).
const JUMPY_JUMP_GAP_TICKS: Vector2i = Vector2i(20, 60)
## Ticks que se mantiene pulsado el botón de salto (mínimo y máximo).
const JUMP_HOLD_TICKS: Vector2i = Vector2i(2, 5)
## Fracción del radio a la que el bot que volvía a casa se da por llegado.
const RETURN_RELEASE_FRACTION: float = 0.6
## Fracción del radio a la que gira un [constant CIRCLE].
const CIRCLE_RADIUS_FRACTION: float = 0.5
## Radio mínimo de la circunferencia de un [constant CIRCLE] (m).
const CIRCLE_MIN_RADIUS: float = 2.0
## [constant COMBAT]: distancia (m) a la que ve a un enemigo, a la que se detiene para golpear (el
## sector del arma llega a 2,6 m) y a partir de la cual esprinta para alcanzarlo.
const COMBAT_SIGHT_RANGE: float = 40.0
const COMBAT_ATTACK_DISTANCE: float = 1.8
const COMBAT_SPRINT_DISTANCE: float = 8.0
## [constant COMBAT]: a esta distancia empieza a pelear (ataca, bloquea o esquiva).
const COMBAT_ENGAGE_DISTANCE: float = 3.0
## [constant COMBAT]: ticks que se mantiene pulsado un toque de ataque.
const COMBAT_TAP_TICKS: int = 2
## [constant COMBAT]: ticks entre dos ataques (enlazan el combo: la ventana de enlace es el final de
## la recuperación) y entre una defensa y la siguiente decisión.
const COMBAT_ATTACK_GAP_TICKS: Vector2i = Vector2i(26, 34)
## [constant COMBAT]: probabilidades de cada decisión (el resto es un ligero) y duraciones de
## bloqueo y de carga del fuerte (ticks).
const COMBAT_BLOCK_CHANCE: float = 0.14
const COMBAT_DODGE_CHANCE: float = 0.10
const COMBAT_HEAVY_CHANCE: float = 0.12
const COMBAT_BLOCK_TICKS: Vector2i = Vector2i(30, 80)
const COMBAT_HEAVY_HOLD_TICKS: Vector2i = Vector2i(24, 50)
## [constant COMBAT]: ticks que se recuerda la posición del enemigo antes de volver a buscarlo.
const COMBAT_RETARGET_TICKS: int = 4
## [constant SIEGE]: distancia (m) a la que un enemigo le hace dejar su plan para pelear (cuerpo a cuerpo; con el arco
## del kit, [constant SIEGE_BOW_FIGHT_RANGE]).
const SIEGE_FIGHT_RANGE: float = 12.0
## [constant SIEGE]: radio (m) en el que se da por alcanzado un punto de la ruta.
const SIEGE_WAYPOINT_RADIUS: float = 2.5
## [constant SIEGE]: distancia (m) a la puerta a la que se detiene para golpearla (el sector del arma
## llega a 2,6 m de él y la cara de la puerta está a 0,25 m de su centro).
const SIEGE_GATE_ATTACK_DISTANCE: float = 2.3
## [constant SIEGE]: dentro del círculo se coloca a esta fracción del radio del centro.
const SIEGE_CIRCLE_HOLD_FRACTION: float = 0.5
## [constant SIEGE]: para entrar en el fuerte se alinea con el eje de la puerta (a esta distancia lateral como
## mucho, en metros), delante de ella a [constant SIEGE_GATE_FRONT_DISTANCE], y la cruza hasta un punto a
## [constant SIEGE_GATE_EXIT_DISTANCE] dentro. Sin esto, al llegar al último punto de la ruta, que está de
## lado, el bot tiraba derecho al círculo y se estrellaba contra la empalizada.
const SIEGE_GATE_AXIS_TOLERANCE: float = 1.0
## [constant SIEGE]: medio ancho (m) del vano por el que cabe el bot (el vano mide 4 m; menos su radio). Pegado a la
## pared de la puerta pero más a un lado que esto, primero vuelve delante de la puerta.
const SIEGE_GATE_OPENING_HALF_WIDTH: float = 1.6
const SIEGE_GATE_FRONT_DISTANCE: float = 4.5
const SIEGE_GATE_EXIT_DISTANCE: float = 2.5
## [constant SIEGE]: radio (m) que usa si el [SiegeView] no sabe el del círculo.
const SIEGE_DEFAULT_CIRCLE_RADIUS: float = 5.0
## [constant SIEGE]: esprinta si falta más de esta distancia (m) y no hay enemigos a menos de la otra.
const SIEGE_SPRINT_DISTANCE: float = 9.0
const SIEGE_SPRINT_ENEMY_CLEARANCE: float = 25.0
## [constant SIEGE]: un salto de posición de más de esta distancia (m) en un tick es una reaparición.
const SIEGE_TELEPORT_DISTANCE: float = 5.0
## [constant SIEGE]: si está a más de esta distancia (m) del punto que persigue, busca el más cercano.
const SIEGE_LOST_DISTANCE: float = 70.0
## [constant SIEGE]: a menos de estos metros del círculo, y al otro lado de la puerta, ya está dentro del
## fuerte y no necesita la ruta (si el [SiegeView] no sabe el tamaño del recinto; si lo sabe, cuenta el recinto con
## [constant SIEGE_ENCLOSURE_MARGIN] de holgura: pegado a la empalizada por fuera no está dentro).
const SIEGE_INSIDE_RADIUS: float = 30.0
const SIEGE_ENCLOSURE_MARGIN: float = 0.5
## [constant SIEGE]: fuera del recinto pero a su lado o detrás (una persecución le sacó de la ruta), rodea la
## empalizada por sus esquinas, a esta distancia (m) de las paredes, hasta la pared de la puerta; da una esquina por
## alcanzada a [constant SIEGE_WAYPOINT_RADIUS].
const SIEGE_CORNER_MARGIN: float = 6.0
## [constant SIEGE]: ticks sin avanzar [constant SIEGE_STUCK_MIN_PROGRESS] metros tras los que se
## considera atascado; ticks que dura un salto o un desvío para desatascarse; cada cuántos ticks se pulsa
## el salto; y ángulo (rad) del desvío.
const SIEGE_STUCK_TICKS: int = 180
const SIEGE_STUCK_MIN_PROGRESS: float = 1.0
const SIEGE_JUMP_WINDOW_TICKS: int = 40
const SIEGE_JUMP_PULSE_TICKS: int = 20
const SIEGE_DETOUR_TICKS: int = 60
const SIEGE_DETOUR_ANGLE: float = 1.2
## [constant SIEGE]: margen (m) que añade al alcance de un golpe avisado y al borde de su semiplano para darse por
## dentro de su zona (el radio de la cápsula, 0,4 m, y algo más para no quedarse en el filo).
const SIEGE_THREAT_MARGIN: float = 1.0
## [constant SIEGE]: mientras sigue en la zona de un golpe avisado, cada cuántos ticks pulsa la esquiva (la primera,
## nada más verlo: 4,5 m en 0,45 s, que lo sacan del alcance del golpe del Capitán antes del impacto).
const SIEGE_EVADE_DODGE_TICKS: int = 15
## [constant SIEGE]: si persiguiendo a alguien que está a más de [constant COMBAT_ENGAGE_DISTANCE] no se acerca
## [constant SIEGE_STUCK_MIN_PROGRESS] metros en [constant SIEGE_STUCK_TICKS] ticks (está tras un muro, en la pasarela
## o huye más rápido), deja de perseguir a nadie que no esté a esa distancia durante estos ticks y sigue con su plan. Mide
## persecuciones seguidas del mismo blanco: al llegar a la distancia de pelea, o al cambiar de blanco, empieza otra.
const SIEGE_CHASE_GIVE_UP_TICKS: int = 600
## [constant SIEGE], reunión (GUE-44): cuántos de su reino (él incluido) tiene que haber en el punto de reunión para salir
## sin esperar al reloj.
const SIEGE_RALLY_GROUP_SIZE: int = 8
## [constant SIEGE], reunión: cada cuántos ticks de partida sale el reloj común (lo más que espera un atacante), y a qué
## tick dentro de cada vuelta: 5 s después de una oleada de reaparición ([code]CombatTiming.WAVE_TICKS[/code], múltiplos
## de 600), para que los que reaparecen en ella lleguen a tiempo.
const SIEGE_RALLY_PERIOD_TICKS: int = 1800
const SIEGE_RALLY_OFFSET_TICKS: int = 300
## [constant SIEGE], reunión: radio (m) del punto de reunión en el que se cuenta a los suyos (los cuatro puntos de
## reaparición del campamento quedan dentro); espera en su hueco ([constant SIEGE_SLOT_RALLY_SPREAD]).
const SIEGE_RALLY_RADIUS: float = 15.0
## [constant SIEGE], reunión: si ya hay al menos [constant SIEGE_RALLY_JOIN_COUNT] de los suyos a menos de
## [constant SIEGE_RALLY_FORT_RADIUS] metros del círculo (peleando en el fuerte o en su explanada), no espera: va a
## ayudarlos.
const SIEGE_RALLY_JOIN_COUNT: int = 3
const SIEGE_RALLY_FORT_RADIUS: float = 25.0
## [constant SIEGE], formación (GUE-44): los personajes no chocan entre sí, así que los bots que siguen los mismos puntos
## acaban uno encima de otro, y un golpe que barre (el sector del arma) da a todo el montón a la vez. Un bot que va en
## grupo ([method set_ally_counter]) lleva su hueco ([method get_siege_slot], sale de su semilla) y lo suma a donde va:
## de lado en la marcha, a lo largo de la puerta al golpearla, dentro del círculo y en el punto de reunión. Metros de
## cada uno, y distancia a la que da su sitio por alcanzado.
const SIEGE_SLOT_MARCH_SPREAD: float = 1.0
const SIEGE_SLOT_GATE_SPREAD: float = 1.6
const SIEGE_SLOT_CIRCLE_SPREAD: float = 2.0
const SIEGE_SLOT_RALLY_SPREAD: float = 4.0
const SIEGE_SLOT_REACHED: float = 0.5
## Los dos pasos de la sucesión R2 (las inversas del número plástico y de su cuadrado): los huecos de semillas seguidas
## quedan repartidos por el disco ([method slot_for_seed]).
const SLOT_STEP_ANGLE: float = 0.7548776662466927
const SLOT_STEP_RADIUS: float = 0.5698402909980532
## [constant SIEGE], pasarela (GUE-45): qué parte de los bots tiene el papel de la pasarela ([method is_walkway_seed]):
## los del dueño que la guardan y, de ellos, los que la recorren cuando atacan. Con la misma parte para los atacantes
## (unos cinco de veinte que dejan la pelea del patio y suben de uno en uno contra los unos cinco del dueño) la recaptura
## de siege_battle.gd pasaba de una mediana de 2,6 a 5,3 min; con la mitad, 2,7 (docs/fuerte.md 8.3, F6b, paquete D).
const SIEGE_WALKWAY_SHARE: float = 0.25
const SIEGE_WALKWAY_SWEEP_SHARE: float = 0.125
## Paso de la sucesión de Weyl con la que se reparte el papel por semillas (la inversa del número áureo): cualquier
## serie de semillas seguidas, o de una cada N, da casi la misma proporción (con veinte, uno arriba o abajo).
const WALKWAY_SEED_STEP: float = 0.6180339887498949
## [constant SIEGE], pasarela: hasta cuántos metros a cada lado del puesto (encima de la puerta, a lo largo de la
## pasarela) se coloca cada uno según su hueco ([method get_siege_slot]).
const SIEGE_WALKWAY_POST_SPREAD: float = 4.0
## [constant SIEGE], pasarela: distancia (m) a la que da por alcanzado un punto de las rampas, una esquina de la pasarela
## o su puesto. Menos que la holgura del eje (la pasarela mide 2 m y la cápsula 0,8): al cortar una esquina no se cae.
const SIEGE_WALKWAY_REACHED: float = 0.5
## [constant SIEGE], pasarela: está en ella si sus pies están a menos de [constant SIEGE_WALKWAY_LEVEL_MARGIN] m por
## debajo de su suelo (o más arriba) y a menos de [constant SIEGE_WALKWAY_BAND] m de su eje en horizontal.
const SIEGE_WALKWAY_LEVEL_MARGIN: float = 0.8
const SIEGE_WALKWAY_BAND: float = 1.5
## [constant SIEGE], pasarela: subiendo hacia la cima de una rampa, si se aparta de su eje más que esto (m), vuelve
## primero al punto del patio que hay delante de su pie.
const SIEGE_RAMP_AXIS_TOLERANCE: float = 1.0
## [constant SIEGE]: dentro del recinto (el patio es llano), quien está más de estos metros más arriba o más abajo
## (en la pasarela, o en el patio visto desde ella) no se alcanza: el sector del arma va de 0,2 a 2 m sobre los pies del
## que golpea y la cápsula mide 1,8.
const SIEGE_LEVEL_TOLERANCE: float = 1.6
## Peso de la altura en la distancia con la que los buscadores de enemigos de los bots eligen el más cercano
## ([method target_distance_squared]): con 4, la pasarela (3,35 m por encima) queda a más de 13 m, más lejos que el
## alcance de pelea ([constant SIEGE_FIGHT_RANGE]), y cualquier enemigo a tiro en su mismo nivel va antes.
const SIEGE_LEVEL_WEIGHT: float = 4.0
## Kit: con el arco en la mano y el enemigo a menos de esta distancia (m) cambia a la espada si la lleva, y con la
## espada y el enemigo a más de la otra, al arco.
const KIT_SWAP_TO_MELEE_DISTANCE: float = 5.0
const KIT_SWAP_TO_RANGED_DISTANCE: float = 11.0
## Kit: distancias (m) entre las que se queda el arquero (se aleja por debajo y se acerca por encima).
const KIT_BOW_KEEP_MIN: float = 9.0
const KIT_BOW_KEEP_MAX: float = 26.0
## Kit: probabilidad de que un disparo sea tensado y ticks que mantiene PRIMARY (desde la pulsación; la carga
## del tensado va de 21 a 60).
const KIT_BOW_DRAWN_CHANCE: float = 0.45
const KIT_BOW_DRAW_TICKS: Vector2i = Vector2i(24, 60)
## Kit: probabilidad de usar una habilidad de disparo lista y distancia (m) por debajo de la cual el arquero
## salta atrás.
const KIT_SHOT_ABILITY_CHANCE: float = 0.3
const KIT_ESCAPE_DISTANCE: float = 5.0
## Kit: probabilidad de esquivar en una decisión del arquero con el enemigo cerca.
const KIT_BOW_DODGE_CHANCE: float = 0.08
## Kit: golpe corto (el de escudo) a esta distancia (m) como mucho y con esta probabilidad por decisión.
const KIT_CLOSE_DISTANCE: float = 2.2
const KIT_CLOSE_CHANCE: float = 0.22
## Kit: embestida para acercarse entre estas distancias (m) y con esta probabilidad por decisión.
const KIT_GAP_CLOSER_RANGE: Vector2 = Vector2(3.5, 7.0)
const KIT_GAP_CLOSER_CHANCE: float = 0.3
## Kit: probabilidad de levantar el muro en una decisión y ticks que mantiene su botón (la canalización acaba al
## soltarlo o en su tope).
const KIT_GUARD_CHANCE: float = 0.08
const KIT_GUARD_HOLD_TICKS: Vector2i = Vector2i(60, 200)
## Kit: bebe la poción de vida por debajo de esta fracción de vida y la de resistencia por debajo de esta
## fracción de resistencia.
const KIT_HEALTH_POTION_BELOW: float = 0.5
const KIT_STAMINA_POTION_BELOW: float = 0.3
## Kit: se acerca hasta esta distancia (m) de un derribado para levantarlo o rematarlo (el servidor llega a 2 m)
## y mantiene INTERACT lo que dura la acción más este margen (ticks).
const KIT_INTERACT_REACH: float = 1.3
const KIT_INTERACT_MARGIN_TICKS: int = 8
## Kit: busca aliados derribados hasta esta distancia (m) y solo va a levantarlos si no hay un enemigo más
## cerca que la otra.
const KIT_REVIVE_SEARCH: float = 15.0
const KIT_REVIVE_ENEMY_CLEARANCE: float = 6.0
## Kit: ticks entre dos decisiones de más tras acabar una acción, y lo que dura cada tramo lateral del arquero.
const KIT_DECISION_GAP_TICKS: Vector2i = Vector2i(4, 12)
const KIT_STRAFE_TICKS: Vector2i = Vector2i(40, 100)
## Kit en [constant SIEGE]: distancia (m) hasta la que tira con el arco (o lo saca) a quien tiene a tiro. Con
## [constant SIEGE_FIGHT_RANGE] (12 m, la del cuerpo a cuerpo) el cambio al arco, que pide más de
## [constant KIT_SWAP_TO_RANGED_DISTANCE], casi nunca llegaba y el arquero guardaba solo de 9 a 12 m: es esa distancia
## más 9 m de margen, dentro de la que guarda el arquero ([constant KIT_BOW_KEEP_MAX]). Más lejos sigue su plan.
const SIEGE_BOW_FIGHT_RANGE: float = 20.0
## Kit en [constant SIEGE]: medio ancho (m) del vano de la puerta rota por el que pasa una flecha de fuera adentro o al
## revés (el vano mide 4 m; un poco menos, por el grosor de la jamba).
const SIEGE_BOW_GAP_HALF_WIDTH: float = 1.8

# Cómo se desatasca un bot de asedio.
enum _Unstick { NONE, JUMP, DETOUR }
# Cómo pelea un bot de asedio con un blanco: no pelea, se acerca (el cuerpo a cuerpo, o ir a rematar) o le tira con el
# arco.
enum _Engage { SKIP, CLOSE, SHOOT }
# Pitch máximo (rad) de la puntería del arco (por debajo de la vertical).
const _MAX_AIM_PITCH: float = 1.4


## Un golpe avisado (TELEGRAPH, docs/fuerte.md sección 5) que un bot de [constant SIEGE] evita: un sector de
## alcance [member radius] con el vértice en [member origin] (los pies de quien golpea) y orientado según
## [member yaw] (la convención de [PlayerInput]: el yaw 0 mira hacia -Z). El aviso no dice el ángulo del sector, así
## que se toma el semiplano de delante: cubre de sobra los 120° del golpe del Capitán.
class Threat:
	extends RefCounted

	var origin: Vector3 = Vector3.ZERO
	var yaw: float = 0.0
	var radius: float = 0.0


	func _init(new_origin: Vector3 = Vector3.ZERO, new_yaw: float = 0.0, new_radius: float = 0.0) -> void:
		origin = new_origin
		yaw = new_yaw
		radius = new_radius


	## true si [param position] está en la zona de peligro con [param margin] metros de más: a menos del alcance
	## más el margen (en horizontal) y no más de [param margin] por detrás de quien golpea.
	func covers(position: Vector3, margin: float) -> bool:
		var offset := Vector3(position.x - origin.x, 0.0, position.z - origin.z)
		if offset.length() > radius + margin:
			return false
		var forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
		return offset.dot(forward) >= -margin

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _pattern: Pattern = Pattern.WANDER
var _home: Vector3 = Vector3.ZERO
var _radius: float = 30.0
var _idle_from: int = -1
var _started: bool = false
var _returning: bool = false
var _circle_sign: float = 1.0
# Tramo actual de paseo.
var _next_change_tick: int = 0
var _heading: float = 0.0
var _move: Vector2 = Vector2.ZERO
var _sprint: bool = false
# Salto: tick en el que empieza el siguiente y tick en el que se suelta el botón.
var _next_jump_tick: int = 0
var _jump_release_tick: int = -1
# COMBAT: quién busca al enemigo, el último visto, y qué botón se mantiene hasta cuándo.
var _enemy_finder: Callable = Callable()
var _enemy_position: Variant = null
var _enemy_checked_tick: int = -1000
var _hold_buttons: int = 0
var _hold_until: int = -1
var _hold_move: Vector2 = Vector2.ZERO
var _next_decision_tick: int = 0
# SIEGE: el fuerte, las rutas y el reino del bot; la ruta que sigue y por qué punto va.
var _siege: SiegeView = null
var _siege_routes: ApproachRoutes = null
var _siege_realm: int = 0
var _siege_route_id: StringName = &""
var _siege_route_chosen: bool = false
var _siege_route_points: PackedVector2Array = PackedVector2Array()
var _siege_route_index: int = 0
var _siege_task: SiegeTask = SiegeTask.NONE
# SIEGE: la última posición (para detectar una reaparición) y el estado del desatasco.
var _siege_last_position: Vector3 = Vector3.ZERO
var _siege_has_position: bool = false
var _siege_stuck_ref_position: Vector3 = Vector3.ZERO
var _siege_stuck_ref_tick: int = -1
var _siege_stuck_count: int = 0
var _siege_unstick: _Unstick = _Unstick.NONE
var _siege_unstick_start: int = 0
var _siege_unstick_until: int = -1
var _detour_sign: float = 1.0
# SIEGE: el botón mantenido apunta a la puerta (y no a un enemigo).
var _hold_aims_gate: bool = false
# SIEGE: quién da los golpes avisados que hay que evitar, y desde qué tick está saliendo de uno (-1 = no lo está).
var _siege_threat_finder: Callable = Callable()
var _siege_evade_since: int = -1
# SIEGE: quién da el PNJ defensor más cercano, el último visto (con su velocidad y su derribo si el buscador da un
# BotTarget, para el kit) y cuándo se miró.
var _siege_defender_finder: Callable = Callable()
var _siege_defender_position: Variant = null
var _siege_defender_velocity: Vector3 = Vector3.ZERO
var _siege_defender_downed: bool = false
var _siege_defender_checked_tick: int = -1000
# SIEGE: la persecución en curso (distancia y tick de referencia; -1 = ninguna), hasta cuándo no persigue, y a quién
# perseguía en la última comprobación (si era el PNJ defensor y dónde estaba): otro blanco es otra persecución.
var _siege_chase_ref_distance: float = 0.0
var _siege_chase_ref_tick: int = -1
var _siege_chase_blocked_until: int = -1
var _siege_chase_defender: bool = false
var _siege_chase_target: Vector3 = Vector3.ZERO
# SIEGE, reunión (GUE-44): quién cuenta a los suyos, el tamaño del grupo y la vuelta del reloj; si toca mirar si espera
# (al empezar y tras reaparecer) y, mientras espera, hasta qué tick como mucho (-1 = no espera).
var _siege_ally_counter: Callable = Callable()
var _siege_rally_size: int = SIEGE_RALLY_GROUP_SIZE
var _siege_rally_period: int = SIEGE_RALLY_PERIOD_TICKS
var _siege_rally_pending: bool = true
var _siege_rally_until: int = -1
# SIEGE, reunión: tick de la última salida del punto de reunión (-1 = nunca ha salido de una).
var _siege_rally_left_tick: int = -1
# SIEGE, formación: el hueco del bot (un punto del disco unidad, de su semilla).
var _siege_slot: Vector2 = Vector2.ZERO
# SIEGE, pasarela (GUE-45): la semilla (para repartir el papel), si tiene el papel, si ya la ha recorrido como atacante en
# esta vida, la rampa por la que sube (-1 = ninguna) y el punto de ella al que va (-1 = aún no lo ha elegido), y si está
# en la pasarela en este tick.
var _siege_seed: int = 0
var _siege_walkway_role: bool = false
var _siege_walkway_sweeper: bool = false
var _siege_walkway_swept: bool = false
var _siege_climb_ramp: int = -1
var _siege_climb_index: int = -1
var _siege_on_walkway_now: bool = false

## Kit (H5): false lo apaga aunque haya estado de combate (el bot pelea como en la fase 3). Lo usan las medidas
## de referencia de [code]tools/combat_balance.gd[/code].
var use_kit: bool = true
## Kit, para las pruebas de carga ([code]--fake-archers[/code]): con el arco en la mano no cambia nunca a la espada
## (guarda la distancia y dispara), y con la espada vuelve al arco en cuanto puede.
var kit_ranged_only: bool = false
## Kit, para las pruebas de carga: radianes que sube la puntería del arco por encima del tiro bueno. Con un valor
## alto, las flechas van al cielo y viven sus 2 s (llenan el tope de la zona; docs/habilidades.md, sección 4.4).
var kit_aim_raise: float = 0.0
# Kit: de dónde saca su estado de combate, su vida y los aliados derribados.
var _combat_source: Callable = Callable()
var _health_source: Callable = Callable()
var _ally_finder: Callable = Callable()
# Kit: velocidad y derribo del enemigo que sigue (del BotTarget; cero y false con una posición sola).
var _enemy_velocity: Vector3 = Vector3.ZERO
var _enemy_downed: bool = false
# Kit: el blanco de la pelea en curso es el PNJ defensor de SIEGE (y no el enemigo de set_enemy_finder): a él
# apunta el arco y su derribo decide el remate.
var _fight_defender: bool = false
# Kit: el aliado derribado más cercano (Vector3 o null) y cuándo se buscó.
var _ally_position: Variant = null
var _ally_checked_tick: int = -1000
# Kit: qué mantiene (&"" un toque o nada; &"execute", &"revive", &"guard", &"draw").
var _hold_kind: StringName = &""
# Kit: velocidad (m/s) y gravedad del disparo que apunta (0 = nada que apuntar).
var _aim_speed: float = 0.0
var _aim_gravity: float = 0.0
# Kit: hombro de la puntería (el izquierdo con semilla impar) y tramo lateral del arquero.
var _aim_left: bool = false
var _kit_strafe_sign: float = 1.0
var _kit_strafe_until: int = -1
# Kit: cuántas veces ha hecho cada cosa (get_kit_counts).
var _kit_counts: Dictionary[StringName, int] = {}
# Kit en SIEGE: la pelea en curso es de tirar con el arco (_Engage.SHOOT): con la espada en la mano la cambia por el
# arco y no se acerca, y con el arco no saca la espada.
var _kit_shoot_plan: bool = false
# Kit en SIEGE: quién dice si hay línea de tiro (set_line_of_sight) y la última respuesta para el PNJ defensor y para el
# enemigo, con el tick de la búsqueda del blanco a la que corresponde (-1 = ninguna).
var _line_of_sight: Callable = Callable()
var _sight_defender_tick: int = -1
var _sight_defender: bool = false
var _sight_enemy_tick: int = -1
var _sight_enemy: bool = false


## [param rng_seed] fija la secuencia. [param home] y [param radius] delimitan la zona por la
## que se mueve el bot (en el plano horizontal).
func _init(rng_seed: int, pattern: Pattern = Pattern.WANDER, home: Vector3 = Vector3.ZERO,
		radius: float = 30.0) -> void:
	_rng.seed = rng_seed
	_pattern = pattern
	_home = home
	_radius = maxf(radius, 1.0)
	_circle_sign = 1.0 if _rng.randi() % 2 == 0 else -1.0
	_siege_slot = slot_for_seed(rng_seed)
	_siege_seed = rng_seed
	_siege_walkway_role = is_walkway_seed(rng_seed)
	_siege_walkway_sweeper = is_walkway_seed(rng_seed, SIEGE_WALKWAY_SWEEP_SHARE)
	# Sin sacar números del generador: la secuencia de los patrones de antes no cambia.
	_aim_left = posmod(rng_seed, 2) == 1


## Entrada sin cuantizar para [param tick] (la cuantiza quien llama). [param position] y
## [param yaw] son los actuales del personaje. Cambia de dirección cada 60-180 ticks, salta y
## esprinta a veces y vuelve hacia home si sale del radio.
func next_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	if _pattern == Pattern.IDLE or (_idle_from >= 0 and tick >= _idle_from):
		input.look_yaw = yaw
		return input
	if _pattern == Pattern.COMBAT:
		var fighting: PlayerInput = _combat_input(tick, position, yaw)
		if fighting != null:
			return fighting
	elif _pattern == Pattern.SIEGE and _siege != null:
		return _siege_input(tick, position, yaw)
	if not _started:
		_started = true
		_next_change_tick = tick
		_schedule_jump(tick)

	var to_home: Vector3 = _home - position
	to_home.y = 0.0
	var distance: float = to_home.length()
	if distance > _radius:
		_returning = true
	elif distance < _radius * RETURN_RELEASE_FRACTION:
		_returning = false

	if _returning:
		input.look_yaw = _yaw_toward(to_home, yaw)
		input.move = Vector2(0.0, 1.0)
		# Un tramo nuevo al llegar, para no retomar un rumbo que lo vuelva a sacar del radio.
		_next_change_tick = tick
	elif _pattern == Pattern.CIRCLE:
		input.look_yaw = _circle_yaw(position, yaw)
		input.move = Vector2(0.0, 1.0)
	else:
		if tick >= _next_change_tick:
			_start_segment(tick)
		input.look_yaw = _heading
		input.move = _move
		if _sprint:
			input.buttons |= PlayerInput.SPRINT

	if _pattern == Pattern.WANDER or _pattern == Pattern.JUMPY:
		_update_jump(tick)
		if tick < _jump_release_tick:
			input.buttons |= PlayerInput.JUMP
	return input


## Función con la que los patrones [constant COMBAT] y [constant SIEGE] buscan enemigos:
## [code](position: Vector3) -> Variant[/code] devuelve la posición (un [Vector3]) del enemigo más
## cercano a [param position], o null si no hay ninguno. Sin ella, [constant COMBAT] pasea y
## [constant SIEGE] solo marcha, asalta y defiende.
func set_enemy_finder(finder: Callable) -> void:
	_enemy_finder = finder
	_enemy_checked_tick = -1000


## true si el patrón [constant COMBAT] o [constant SIEGE] ya tiene quién le busque enemigos.
func has_enemy_finder() -> bool:
	return _enemy_finder.is_valid()


## Patrón del bot.
func get_pattern() -> Pattern:
	return _pattern


## Desde [param tick] (incluido) solo devuelve entradas neutras: sin movimiento ni botones y
## mirando al yaw actual. Sirve para las pruebas de convergencia de la reconciliación.
func set_idle_from(tick: int) -> void:
	_idle_from = tick


## Da al patrón [constant SIEGE] el fuerte que asedia o defiende ([param view], que quien lo lleva mantiene
## al día y puede compartirse entre bots), las rutas de la zona ([param routes], null = va derecho a la
## puerta) y el reino del bot ([param realm], código de red). Reinicia la ruta.
func set_siege(view: SiegeView, routes: ApproachRoutes, realm: int) -> void:
	_siege = view
	_siege_routes = routes
	_siege_realm = realm
	_reset_route()


## Función con la que el patrón [constant SIEGE] se entera de los golpes avisados (TELEGRAPH) que hay que evitar:
## [code](position: Vector3) -> Array[/code] devuelve los [BotBrain.Threat] activos de quienes le pueden dañar
## (puede devolver también los lejanos: el cerebro mira si está dentro de cada uno). Sin ella no evita nada.
func set_threat_finder(finder: Callable) -> void:
	_siege_threat_finder = finder


## Función con la que el patrón [constant SIEGE] busca primero a los PNJ que defienden el fuerte (los Huecos, el
## Capitán y la guarnición del dueño): [code](position: Vector3) -> Variant[/code] devuelve la posición del PNJ enemigo
## vivo más cercano (un [Vector3] o, como el de [method set_enemy_finder], un [BotTarget] con su velocidad, para el
## tiro adelantado del kit), o null. Mientras el círculo no está activo (el capitán vive), si hay uno a tiro pelea con él antes
## que con el enemigo de [method set_enemy_finder] (un jugador que le pegue no le aparta de él), y como el buscador da
## siempre el más cercano, sigue con el mismo hasta que muere o se aleja. Con el círculo activo, o sin ella, pelea con
## el más cercano de todos.
func set_defender_finder(finder: Callable) -> void:
	_siege_defender_finder = finder
	_siege_defender_checked_tick = -1000


## true si el patrón [constant SIEGE] ya tiene quién le busque los PNJ defensores.
func has_defender_finder() -> bool:
	return _siege_defender_finder.is_valid()


## Función con la que el patrón [constant SIEGE] cuenta a los suyos en el punto de reunión (GUE-44):
## [code](center: Vector3, radius: float) -> int[/code] devuelve cuántos jugadores vivos de su reino, sin contarle a
## él, están a menos de [param radius] metros (en horizontal) de [param center]. Sin ella no espera a nadie y sale solo,
## como antes de GUE-44.
func set_ally_counter(counter: Callable) -> void:
	_siege_ally_counter = counter


## true si el patrón [constant SIEGE] ya tiene quién le cuente a los suyos.
func has_ally_counter() -> bool:
	return _siege_ally_counter.is_valid()


## Cambia la reunión del patrón [constant SIEGE] (GUE-44): sale cuando hay [param group_size] de su reino en el punto
## de reunión (él incluido) o en la siguiente salida del reloj, que da una vuelta cada [param period_ticks] ticks. Con
## [param group_size] 1 o menos no espera nunca (como antes de GUE-44). Lo usan las herramientas para comparar; por
## defecto, [constant SIEGE_RALLY_GROUP_SIZE] y [constant SIEGE_RALLY_PERIOD_TICKS]. Vale para la próxima espera; si
## estaba esperando y el grupo pasa a 1 o menos, deja de esperar.
func set_rally(group_size: int, period_ticks: int = SIEGE_RALLY_PERIOD_TICKS) -> void:
	_siege_rally_size = group_size
	_siege_rally_period = maxi(period_ticks, 1)
	if group_size <= 1:
		_siege_rally_until = -1


## Tamaño del grupo con el que sale de la reunión (1 o menos: no espera).
func get_rally_group_size() -> int:
	return _siege_rally_size


## true si el bot de [constant SIEGE] está esperando a los suyos en el punto de reunión.
func is_rallying() -> bool:
	return _siege_rally_until >= 0


## Tick de la salida del reloj a la que, como mucho, sale el bot que espera (-1 si no espera).
func get_rally_deadline() -> int:
	return _siege_rally_until


## El hueco de un bot con la semilla [param rng_seed] en la formación del patrón [constant SIEGE] (GUE-44): un punto del
## disco de radio 1 (x de lado, y hacia delante) sacado de la sucesión R2, que reparte bien semillas seguidas (los bots
## de un mismo grupo: con veinte seguidas, el par más cercano queda de media a 0,19 y nunca a menos de 0,1 en las bases
## de 0 a 6000; en una de cada diez bases, a menos de 0,18). No usa el generador.
static func slot_for_seed(rng_seed: int) -> Vector2:
	var angle: float = TAU * fposmod(float(rng_seed) * SLOT_STEP_ANGLE, 1.0)
	var reach: float = sqrt(fposmod(float(rng_seed) * SLOT_STEP_RADIUS, 1.0))
	return Vector2(cos(angle), sin(angle)) * reach


## El hueco de este bot en la formación ([method slot_for_seed]).
func get_siege_slot() -> Vector2:
	return _siege_slot


## Tick en el que salió por última vez del punto de reunión con los suyos, también si no tuvo que esperar porque ya
## eran bastantes (-1 si nunca ha salido de una reunión).
func get_last_rally_departure() -> int:
	return _siege_rally_left_tick


## true si un bot con la semilla [param rng_seed] tiene el papel de la pasarela del patrón [constant SIEGE] (GUE-45): la
## fracción [param share] de las semillas, repartidas con la sucesión de Weyl del número áureo, así que con 20 semillas
## seguidas (o una de cada dos, las de un reino) son de 4 a 6 con [constant SIEGE_WALKWAY_SHARE] (5 en más de la mitad de
## las bases) y de 1 a 4 con [constant SIEGE_WALKWAY_SWEEP_SHARE] (casi siempre 2 o 3). No usa el generador.
static func is_walkway_seed(rng_seed: int, share: float = SIEGE_WALKWAY_SHARE) -> bool:
	return fposmod(float(rng_seed) * WALKWAY_SEED_STEP, 1.0) < share


## Da o quita el papel de la pasarela al bot: [param guard], guardarla cuando su reino es el dueño, y [param sweeper],
## recorrerla cuando ataca (por defecto, lo mismo). Sin llamarlo, los tiene si [method is_walkway_seed] con su semilla y
## [constant SIEGE_WALKWAY_SHARE] o [constant SIEGE_WALKWAY_SWEEP_SHARE]. Vale desde el tick siguiente.
func set_walkway_role(guard: bool, sweeper: bool = guard) -> void:
	_siege_walkway_role = guard
	_siege_walkway_sweeper = sweeper
	_siege_climb_ramp = -1


## Reparte otra vez el papel de la pasarela con la fracción [param share] para los del dueño (0 = nadie sube, como antes
## de GUE-45) y la misma proporción de antes para los atacantes (la mitad: [constant SIEGE_WALKWAY_SWEEP_SHARE] de
## [constant SIEGE_WALKWAY_SHARE]), con [method is_walkway_seed] y su semilla. Lo usan las herramientas para comparar.
func set_walkway_share(share: float) -> void:
	set_walkway_role(is_walkway_seed(_siege_seed, share),
			is_walkway_seed(_siege_seed, share * SIEGE_WALKWAY_SWEEP_SHARE / SIEGE_WALKWAY_SHARE))


## true si el bot guarda la pasarela cuando su reino es el dueño (GUE-45).
func has_walkway_role() -> bool:
	return _siege_walkway_role


## true si el bot recorre la pasarela cuando ataca (GUE-45).
func is_walkway_sweeper() -> bool:
	return _siege_walkway_sweeper


## true si el bot atacante ya ha recorrido la pasarela en esta vida (vuelve a hacerlo tras reaparecer).
func is_walkway_swept() -> bool:
	return _siege_walkway_swept


## El puesto de este bot en la pasarela (GUE-45): el punto de su eje encima de la puerta más su hueco a lo largo de ella,
## a la altura de su suelo; null si no tiene fuerte o las rutas no conocen la pasarela.
func get_walkway_post() -> Variant:
	if _siege == null or _siege_routes == null or not _siege_routes.has_walkway() or not _siege_has_places():
		return null
	var point: Vector2 = _siege_routes.walkway_point(_siege_walkway_post_offset())
	return Vector3(point.x, _siege_routes.walkway_height, point.y)


## true si [param position] está en la pasarela del fuerte que asedia (con sus rutas): a su altura, con
## [constant SIEGE_WALKWAY_LEVEL_MARGIN] de holgura, y a menos de [constant SIEGE_WALKWAY_BAND] m de su eje.
func is_on_walkway(position: Vector3) -> bool:
	if _siege_routes == null or not _siege_routes.has_walkway():
		return false
	if position.y < _siege_routes.walkway_height - SIEGE_WALKWAY_LEVEL_MARGIN:
		return false
	return _siege_routes.walkway_distance(Vector2(position.x, position.z)) <= SIEGE_WALKWAY_BAND


## Distancia al cuadrado con la que los buscadores de enemigos de los bots ([method set_enemy_finder] y
## [method set_defender_finder]: el servidor, [code]SwarmBot[/code] y [code]--bot[/code]) eligen el más cercano: la
## horizontal más la vertical multiplicada por [constant SIEGE_LEVEL_WEIGHT]. Así el que está a su altura va antes que
## el de la pasarela o el del patio visto desde ella, a los que no alcanza (GUE-45).
static func target_distance_squared(from: Vector3, to: Vector3) -> float:
	var dx: float = to.x - from.x
	var dz: float = to.z - from.z
	var dy: float = (to.y - from.y) * SIEGE_LEVEL_WEIGHT
	return dx * dx + dz * dz + dy * dy


## El punto de reunión del patrón [constant SIEGE] (GUE-44): la salida del campamento de su reino, donde empiezan sus
## rutas (el primer punto de la primera, por orden de id; en el Vado Gris todas empiezan en el mismo), a ras de suelo.
## null si no tiene fuerte o sus rutas no tienen puntos para su reino.
func get_siege_rally_point() -> Variant:
	if _siege_routes == null:
		return null
	var realm_id: StringName = RealmCatalog.id_of_code(_siege_realm)
	for route: StringName in _siege_routes.get_route_ids():
		var points: PackedVector2Array = _siege_routes.get_points(route, realm_id)
		if not points.is_empty():
			return Vector3(points[0].x, 0.0, points[0].y)
	return null


## Primer tick posterior a [param tick] en el que sale el reloj común de la reunión, que da una vuelta cada
## [param period_ticks] ticks y sale [constant SIEGE_RALLY_OFFSET_TICKS] ticks después del principio de cada una. Es
## el mismo para todos los bots (el tick de la partida es común), así que los que esperan salen juntos.
static func next_rally_departure(tick: int, period_ticks: int = SIEGE_RALLY_PERIOD_TICKS) -> int:
	var period: int = maxi(period_ticks, 1)
	return tick + period - posmod(tick - SIEGE_RALLY_OFFSET_TICKS, period)


## Índice (entre [param route_count] rutas, en el orden de [method ApproachRoutes.get_route_ids]) de la ruta del grupo
## que sale de la reunión en [param tick]: van alternando, una por cada vuelta del reloj. Lo calcula igual cada bot del
## grupo, sin hablar con los demás. Las salidas del reloj caen a mitad de vuelta, así que unos ticks de diferencia
## entre los clientes no cambian la ruta.
static func rally_route_index(tick: int, route_count: int, period_ticks: int = SIEGE_RALLY_PERIOD_TICKS) -> int:
	if route_count <= 0:
		return -1
	@warning_ignore("integer_division")
	return posmod(maxi(tick, 0) / maxi(period_ticks, 1), route_count)


## true si el patrón [constant SIEGE] ya tiene quién le avise de los golpes.
func has_threat_finder() -> bool:
	return _siege_threat_finder.is_valid()


## true si el patrón [constant SIEGE] ya sabe qué fuerte asedia.
func has_siege() -> bool:
	return _siege != null


## El [SiegeView] del patrón [constant SIEGE] (null si no se le ha dado).
func get_siege_view() -> SiegeView:
	return _siege


## Ruta que sigue un bot de [constant SIEGE] ([constant ApproachRoutes.BRIDGE] o
## [constant ApproachRoutes.FORD]); vacía mientras no ha elegido ninguna o si no hay rutas.
func get_siege_route() -> StringName:
	return _siege_route_id


## Índice del punto de la ruta que persigue un bot de [constant SIEGE] (el tamaño de la ruta si ya la ha
## recorrido entera).
func get_siege_route_index() -> int:
	return _siege_route_index


## Lo que hizo un bot de [constant SIEGE] en el último tick.
func get_siege_task() -> SiegeTask:
	return _siege_task


## Kit (H5): de dónde saca el bot su estado de combate, [code]() -> CombatState[/code] (null = no lo sabe): el
## de después del último tick simulado, con el que decide la entrada del siguiente (el predicho en un cliente, el
## del servidor en un jugador falso). Lo lee sin cambiarlo. Con él, [constant COMBAT] y [constant SIEGE] usan el
## kit (ver la documentación de la clase).
func set_combat_source(source: Callable) -> void:
	_combat_source = source


## true si el bot ya sabe de dónde sacar su estado de combate ([method set_combat_source]).
func has_combat_source() -> bool:
	return _combat_source.is_valid()


## Kit: de dónde saca su vida, [code]() -> float[/code] (fracción de 0 a 1). Sin ella, el bot no bebe la poción
## de vida.
func set_health_source(source: Callable) -> void:
	_health_source = source


## Kit: cómo encuentra aliados derribados, [code](position: Vector3) -> Variant[/code]: los pies (un
## [Vector3]) del más cercano a [param position], o null. Sin él, el bot no levanta a nadie.
func set_ally_finder(finder: Callable) -> void:
	_ally_finder = finder
	_ally_checked_tick = -1000


## Kit en [constant SIEGE]: cómo sabe si tiene tiro con el arco,
## [code](from: Vector3, to: Vector3, left_shoulder: bool) -> bool[/code]: true si nada del mundo ni de las estructuras
## (la empalizada, la puerta cerrada) corta el tiro de un tirador con los pies en [code]from[/code] y la mira en el hombro
## izquierdo o el derecho al centro de un blanco con los pies en [code]to[/code] ([method bow_sight_clear] con el espacio
## de su mundo: el del servidor para los falsos, el del cliente para [code]--bot[/code]). Se pregunta como mucho una vez
## por búsqueda del blanco ([constant COMBAT_RETARGET_TICKS]). Sin ella decide solo con lo que sabe del fuerte (la
## puerta, el recinto y la pasarela).
func set_line_of_sight(query: Callable) -> void:
	_line_of_sight = query
	_sight_defender_tick = -1
	_sight_enemy_tick = -1


## true si el bot ya sabe preguntar por la línea de tiro ([method set_line_of_sight]).
func has_line_of_sight() -> bool:
	return _line_of_sight.is_valid()


## La línea de tiro de [method set_line_of_sight] en [param space], la de un disparo del servidor (docs/habilidades.md,
## sección 4.4) a un blanco quieto: el rayo de la cámara del hombro [param left_shoulder] que pasa por el centro
## ([constant AimRay.TARGET_CENTER_HEIGHT]) del blanco con los pies en [param to_feet] ([method AimRay.look_for]), que es
## el que elige el punto apuntado (si choca antes con una jamba, la flecha va a la jamba), y la línea de la boca
## ([method AimRay.muzzle]) del tirador con los pies en [param from_feet] a ese centro, contra el mundo y las estructuras
## ([constant HitShapes.LINE_OF_SIGHT_MASK]; la puerta cerrada las corta en los dos sentidos, también la del dueño).
## Rectas: la caída de la flecha no cuenta. Sin espacio, true.
static func bow_sight_clear(space: PhysicsDirectSpaceState3D, from_feet: Vector3, to_feet: Vector3,
		left_shoulder: bool) -> bool:
	if space == null:
		return true
	var center: Vector3 = to_feet + Vector3(0.0, AimRay.TARGET_CENTER_HEIGHT, 0.0)
	var look: Vector2 = AimRay.look_for(from_feet, center, left_shoulder)
	var camera: Vector3 = AimRay.canonical(from_feet, look.x, look.y, left_shoulder)[0]
	# Como AimRay.aim_point: sin hit_from_inside (la cámara puede quedar dentro de una pared sin que cuente).
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(camera, center,
			HitShapes.LINE_OF_SIGHT_MASK)
	if not space.intersect_ray(query).is_empty():
		return false
	return HitShapes.is_ray_clear(space, AimRay.muzzle(from_feet), center)


## Kit: cuántas veces ha hecho cada cosa desde que se creó: [code]ability_0[/code]..[code]ability_2[/code]
## (habilidades por ranura), [code]potion_0[/code] y [code]potion_1[/code], [code]swap[/code],
## [code]quick[/code] y [code]drawn[/code] (disparos del arco), [code]guard[/code] (muros levantados),
## [code]execute[/code] y [code]revive[/code] (INTERACT mantenido) y [code]dodge[/code]. Es una copia.
func get_kit_counts() -> Dictionary[StringName, int]:
	return _kit_counts.duplicate()


## Para qué usa el kit [param ability] ([enum KitRole]), por sus datos: una canalización que bloquea es
## [constant KitRole.GUARD]; un avance hacia atrás, [constant KitRole.ESCAPE] (aunque dispare); un disparo,
## [constant KitRole.SHOT]; un avance hacia delante, [constant KitRole.GAP_CLOSER]; un golpe con forma,
## [constant KitRole.CLOSE].
static func kit_role(ability: AbilityTicks) -> KitRole:
	if ability == null:
		return KitRole.NONE
	if ability.channel and ability.blocks:
		return KitRole.GUARD
	if ability.dash_distance_m > 0.0 and ability.dash_direction == 1:
		return KitRole.ESCAPE
	if ability.projectile_id != 0:
		return KitRole.SHOT
	if ability.dash_distance_m > 0.0:
		return KitRole.GAP_CLOSER
	if ability.hit != null and ability.hit.shape != null:
		return KitRole.CLOSE
	return KitRole.NONE


## true si el arma [param weapon_id] dispara con el ligero (el arco).
static func is_ranged_weapon(weapon_id: int) -> bool:
	var weapon: WeaponTicks = CombatCatalog.weapon(weapon_id)
	if weapon == null or weapon.light_ids.is_empty():
		return false
	var light: AttackTicks = CombatCatalog.attack(weapon.light_ids[0])
	return light != null and light.projectile_id != 0


## Vista [code](yaw, pitch)[/code] de un tirador con los pies en [param feet] y el hombro
## [param left_shoulder] para que una flecha de [param speed] m/s y [param gravity] m/s² dé en el centro de un
## blanco con los pies en [param target_feet] que va a [param target_velocity] m/s (docs/habilidades.md, sección
## 4.4): la dirección de [method Ballistics.solve_lead] desde la boca [code]O[/code], el punto
## [code]O + dir · |blanco − O|[/code] y el rayo canónico que pasa por él ([method AimRay.look_for]). El yaw queda
## en [0, TAU).
static func lead_look(feet: Vector3, target_feet: Vector3, target_velocity: Vector3, speed: float,
		gravity: float, left_shoulder: bool) -> Vector2:
	var center: Vector3 = target_feet + Vector3(0.0, AimRay.TARGET_CENTER_HEIGHT, 0.0)
	var muzzle: Vector3 = AimRay.muzzle(feet)
	var direction: Vector3 = Ballistics.solve_lead(muzzle, center, target_velocity, speed, gravity)
	var point: Vector3 = muzzle + direction * muzzle.distance_to(center)
	var look: Vector2 = AimRay.look_for(feet, point, left_shoulder)
	return Vector2(fposmod(look.x, TAU), look.y)


# Entrada del patrón COMBAT, o null si no hay enemigo a la vista (entonces pasea).
func _combat_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	_refresh_enemy(tick, position)
	var kit: CombatState = _kit_state()
	if kit != null:
		var reviving: PlayerInput = _revive_input(tick, position, yaw, kit)
		if reviving != null:
			return reviving
	if not _enemy_position is Vector3:
		_hold_until = -1
		return null
	var to_enemy: Vector3 = (_enemy_position as Vector3) - position
	to_enemy.y = 0.0
	var distance: float = to_enemy.length()
	if distance > COMBAT_SIGHT_RANGE:
		_hold_until = -1
		return null
	return _fight_input(tick, position, to_enemy, distance, yaw)


# Vuelve a buscar al enemigo más cercano cada COMBAT_RETARGET_TICKS ticks. El buscador puede devolver la
# posición (un Vector3) o un BotTarget (con la velocidad y el derribo, que usa el kit).
func _refresh_enemy(tick: int, position: Vector3) -> void:
	if tick - _enemy_checked_tick >= COMBAT_RETARGET_TICKS:
		_enemy_checked_tick = tick
		var found: Variant = _enemy_finder.call(position) if _enemy_finder.is_valid() else null
		_enemy_velocity = Vector3.ZERO
		_enemy_downed = false
		if found is BotTarget:
			var target: BotTarget = found as BotTarget
			_enemy_position = target.position
			_enemy_velocity = target.velocity
			_enemy_downed = target.downed
		else:
			_enemy_position = found


# SIEGE: vuelve a buscar al PNJ defensor más cercano cada COMBAT_RETARGET_TICKS ticks (como _refresh_enemy: una
# posición o un BotTarget).
func _refresh_defender(tick: int, position: Vector3) -> void:
	if tick - _siege_defender_checked_tick >= COMBAT_RETARGET_TICKS:
		_siege_defender_checked_tick = tick
		var found: Variant = _siege_defender_finder.call(position)
		_siege_defender_velocity = Vector3.ZERO
		_siege_defender_downed = false
		if found is BotTarget:
			var target: BotTarget = found as BotTarget
			_siege_defender_position = target.position
			_siege_defender_velocity = target.velocity
			_siege_defender_downed = target.downed
		else:
			_siege_defender_position = found


# Pelea con un enemigo que está a [param distance] metros en la dirección [param to_enemy]: mantiene el
# botón que tocaba, decide qué hacer a distancia de combate o se acerca. Con estado de combate, con el kit
# ([param defender]: el blanco es el PNJ defensor de SIEGE y no el enemigo de set_enemy_finder).
func _fight_input(tick: int, position: Vector3, to_enemy: Vector3, distance: float,
		yaw: float, defender: bool = false) -> PlayerInput:
	var kit: CombatState = _kit_state()
	if kit != null:
		_fight_defender = defender
		return _kit_fight_input(tick, position, to_enemy, distance, yaw, kit)
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = _yaw_toward(to_enemy, yaw)
	if tick < _hold_until:
		# Un botón mantenido (toque, bloqueo, carga del fuerte o esquiva).
		input.buttons = _hold_buttons
		input.move = _hold_move
		return input
	if distance <= COMBAT_ENGAGE_DISTANCE and tick >= _next_decision_tick:
		_decide_combat_action(tick)
		if tick < _hold_until:
			input.buttons = _hold_buttons
			input.move = _hold_move
			return input
	# Acercarse hasta la distancia de golpe.
	if distance > COMBAT_ATTACK_DISTANCE:
		input.move = Vector2(0.0, 1.0)
		if distance > COMBAT_SPRINT_DISTANCE:
			input.buttons |= PlayerInput.SPRINT
	return input


# Elige qué hacer a distancia de combate: bloquear, esquivar, cargar un fuerte o dar un ligero.
func _decide_combat_action(tick: int) -> void:
	var roll: float = _rng.randf()
	_hold_move = Vector2.ZERO
	if roll < COMBAT_BLOCK_CHANCE:
		_hold_buttons = PlayerInput.BLOCK
		_hold_until = tick + _rng.randi_range(COMBAT_BLOCK_TICKS.x, COMBAT_BLOCK_TICKS.y)
		_next_decision_tick = _hold_until + 1
	elif roll < COMBAT_BLOCK_CHANCE + COMBAT_DODGE_CHANCE:
		# Esquiva hacia un lado o hacia atrás.
		_hold_buttons = PlayerInput.DODGE
		_hold_until = tick + 1
		_hold_move = Vector2(1.0 if _rng.randi() % 2 == 0 else -1.0, 0.0) if _rng.randf() < 0.7 \
				else Vector2(0.0, -1.0)
		if _siege_on_walkway_now:
			# En la pasarela (sin barandilla por dentro) una esquiva de lado le tira al patio: hacia atrás, por el eje
			# (pelea con quien tiene delante en él). El generador se usa igual.
			_hold_move = Vector2(0.0, -1.0)
		_next_decision_tick = tick + _rng.randi_range(COMBAT_ATTACK_GAP_TICKS.x,
				COMBAT_ATTACK_GAP_TICKS.y)
	elif roll < COMBAT_BLOCK_CHANCE + COMBAT_DODGE_CHANCE + COMBAT_HEAVY_CHANCE:
		_start_heavy_attack(tick)
	else:
		_start_light_attack(tick)


# Un fuerte cargado: mantiene PRIMARY unos ticks y espera antes de la siguiente decisión.
func _start_heavy_attack(tick: int) -> void:
	_hold_buttons = PlayerInput.PRIMARY
	_hold_until = tick + _rng.randi_range(COMBAT_HEAVY_HOLD_TICKS.x, COMBAT_HEAVY_HOLD_TICKS.y)
	_next_decision_tick = _hold_until + _rng.randi_range(COMBAT_ATTACK_GAP_TICKS.x,
			COMBAT_ATTACK_GAP_TICKS.y)


# Un ligero: un toque corto de PRIMARY (los toques seguidos enlazan el combo).
func _start_light_attack(tick: int) -> void:
	_hold_buttons = PlayerInput.PRIMARY
	_hold_until = tick + COMBAT_TAP_TICKS
	_next_decision_tick = tick + _rng.randi_range(COMBAT_ATTACK_GAP_TICKS.x,
			COMBAT_ATTACK_GAP_TICKS.y)


# --- Kit (H5) -----------------------------------------------------------------------------------

# Estado de combate con el que decide el kit, o null si no hay (o el kit está apagado).
func _kit_state() -> CombatState:
	if not use_kit or not _combat_source.is_valid():
		return null
	return _combat_source.call() as CombatState


# El blanco de la pelea en curso (_fight_defender: el PNJ defensor de SIEGE; si no, el enemigo): su posición vista
# (un Vector3 o null), su velocidad, si está derribado y el tick en que se miró.
func _target_position() -> Variant:
	return _siege_defender_position if _fight_defender else _enemy_position


func _target_velocity() -> Vector3:
	return _siege_defender_velocity if _fight_defender else _enemy_velocity


func _target_downed() -> bool:
	return _siege_defender_downed if _fight_defender else _enemy_downed


func _target_seen_tick() -> int:
	return _siege_defender_checked_tick if _fight_defender else _enemy_checked_tick


# Pelea con el kit: mantiene lo que mantenía (apuntando, con el arco), decide cuando toca y, entre medias, se
# acerca, guarda la distancia o va a rematar.
func _kit_fight_input(tick: int, position: Vector3, to_enemy: Vector3, distance: float, yaw: float,
		state: CombatState) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = _yaw_toward(to_enemy, yaw)
	if state.action == CombatState.Action.DOWNED or state.action == CombatState.Action.DEAD:
		_hold_until = -1
		_hold_kind = &""
		return input
	var ranged: bool = is_ranged_weapon(state.weapon_id)
	# Un remate se deja si el objetivo ya no está derribado.
	if _hold_kind == &"execute" and not _target_downed():
		_hold_until = -1
	if tick >= _hold_until:
		_hold_kind = &""
		if tick >= _next_decision_tick:
			_decide_kit_action(tick, state, ranged, distance)
	if tick < _hold_until:
		input.buttons = _hold_buttons
		input.move = _hold_move
	elif _target_downed():
		if distance > KIT_INTERACT_REACH:
			input.move = Vector2(0.0, 1.0)
			if distance > COMBAT_SPRINT_DISTANCE:
				input.buttons |= PlayerInput.SPRINT
	elif ranged:
		_keep_bow_distance(input, tick, distance)
	elif _kit_shoot_plan:
		# SIEGE: va a tirarle con el arco (lo está sacando): no se acerca con la espada.
		pass
	elif distance > COMBAT_ATTACK_DISTANCE:
		input.move = Vector2(0.0, 1.0)
		if distance > COMBAT_SPRINT_DISTANCE:
			input.buttons |= PlayerInput.SPRINT
	if ranged:
		_aim(input, position, tick, state)
	return input


# Decide qué hace el kit: rematar, beber, cambiar de arma o, según el arma, una habilidad, un disparo o lo de la
# fase 3. Lo que decide queda en _hold_* y _next_decision_tick.
func _decide_kit_action(tick: int, state: CombatState, ranged: bool, distance: float) -> void:
	_hold_move = Vector2.ZERO
	_hold_buttons = 0
	_aim_speed = 0.0
	var data: CombatTables = CombatCatalog.tables()
	if _target_downed():
		if distance <= KIT_INTERACT_REACH and _can_interact(state):
			_hold(tick, PlayerInput.INTERACT, data.execute_ticks + KIT_INTERACT_MARGIN_TICKS, &"execute")
			_count(&"execute")
		return
	if _health_fraction() < KIT_HEALTH_POTION_BELOW \
			and _slot_ready(state, ActionMachine.STATUS_SLOT_CONSUMABLE_1, tick):
		_tap_consumable(tick, 0)
		return
	if float(state.stamina) < KIT_STAMINA_POTION_BELOW * float(data.rules.stamina_max) \
			and _slot_ready(state, ActionMachine.STATUS_SLOT_CONSUMABLE_2, tick):
		_tap_consumable(tick, 1)
		return
	if state.alt_weapon_id != 0 and state.action == CombatState.Action.NONE:
		var alt_ranged: bool = is_ranged_weapon(state.alt_weapon_id)
		# En SIEGE, si la pelea es de tirar (_kit_shoot_plan), el arco se queda en la mano y la espada se cambia por él
		# aunque el blanco esté cerca (la espada no le llega: otro nivel, o la empalizada en medio).
		if (ranged and not alt_ranged and distance < KIT_SWAP_TO_MELEE_DISTANCE and not kit_ranged_only
					and not _kit_shoot_plan) \
				or (not ranged and alt_ranged
					and (distance > KIT_SWAP_TO_RANGED_DISTANCE or kit_ranged_only or _kit_shoot_plan)):
			_tap(tick, PlayerInput.SWAP_WEAPON, data.swap_ticks + _gap())
			_count(&"swap")
			return
	if ranged:
		_decide_bow_action(tick, state, distance)
	else:
		_decide_melee_action(tick, state, distance)


# Cuerpo a cuerpo: embestida para acercarse, golpe corto de cerca, el muro o, si no, lo de la fase 3.
func _decide_melee_action(tick: int, state: CombatState, distance: float) -> void:
	var slots: Dictionary[int, int] = _ready_roles(state, tick)
	if slots.has(KitRole.GAP_CLOSER) and distance >= KIT_GAP_CLOSER_RANGE.x \
			and distance <= KIT_GAP_CLOSER_RANGE.y and _rng.randf() < KIT_GAP_CLOSER_CHANCE:
		_use_ability(tick, state, slots[KitRole.GAP_CLOSER])
		return
	if distance > COMBAT_ENGAGE_DISTANCE:
		return
	var roll: float = _rng.randf()
	if slots.has(KitRole.CLOSE) and distance <= KIT_CLOSE_DISTANCE and roll < KIT_CLOSE_CHANCE:
		_use_ability(tick, state, slots[KitRole.CLOSE])
	elif slots.has(KitRole.GUARD) and roll >= KIT_CLOSE_CHANCE \
			and roll < KIT_CLOSE_CHANCE + KIT_GUARD_CHANCE:
		_use_ability(tick, state, slots[KitRole.GUARD])
	else:
		_decide_combat_action(tick)
		if (_hold_buttons & PlayerInput.DODGE) != 0:
			_count(&"dodge")


# Arco: salto atrás si el enemigo se acerca, alguna esquiva, una habilidad de disparo o un disparo (rápido o
# tensado).
func _decide_bow_action(tick: int, state: CombatState, distance: float) -> void:
	var data: CombatTables = CombatCatalog.tables()
	var weapon: WeaponTicks = data.weapon(state.weapon_id)
	var slots: Dictionary[int, int] = _ready_roles(state, tick)
	if slots.has(KitRole.ESCAPE) and distance < KIT_ESCAPE_DISTANCE:
		_use_ability(tick, state, slots[KitRole.ESCAPE])
		return
	# En la pasarela de SIEGE el arquero no esquiva: no se mueve en ella (tirando, lo que mueve no va por el eje; el
	# generador se usa igual).
	if distance < KIT_ESCAPE_DISTANCE and _rng.randf() < KIT_BOW_DODGE_CHANCE and not _siege_on_walkway_now:
		_hold_move = Vector2(0.0, -1.0)
		_tap(tick, PlayerInput.DODGE, (weapon.dodge.duration_ticks if weapon.dodge != null else 30) + _gap())
		_count(&"dodge")
		return
	var shots: Array[int] = _ready_shot_slots(state, tick)
	if not shots.is_empty() and _rng.randf() < KIT_SHOT_ABILITY_CHANCE:
		_use_ability(tick, state, shots[_rng.randi() % shots.size()])
		return
	var light: AttackTicks = data.attack(weapon.light_ids[0])
	var heavy: AttackTicks = data.attack(weapon.heavy_id)
	if heavy != null and not state.is_exhausted() and _rng.randf() < KIT_BOW_DRAWN_CHANCE:
		var held: int = _rng.randi_range(KIT_BOW_DRAW_TICKS.x, KIT_BOW_DRAW_TICKS.y)
		_hold(tick, PlayerInput.PRIMARY, held, &"draw")
		var launched: int = maxi(held, heavy.charge_min_ticks)
		_next_decision_tick = tick + launched + heavy.total_ticks + _gap()
		var launch: ProjectileLaunch = ProjectileLaunch.for_attack(heavy, mini(launched, heavy.charge_max_ticks))
		_set_aim(launch.speed if launch != null else heavy.projectile_speed_mps, heavy.projectile_id)
		_count(&"drawn")
		return
	_tap(tick, PlayerInput.PRIMARY, light.total_ticks + _gap())
	_set_aim(light.projectile_speed_mps, light.projectile_id)
	_count(&"quick")


# Usa la habilidad de la ranura [param slot] del arma activa: el muro se mantiene; el resto, un toque.
func _use_ability(tick: int, state: CombatState, slot: int) -> void:
	var data: CombatTables = CombatCatalog.tables()
	var ability: AbilityTicks = data.ability(data.weapon(state.weapon_id).ability_id(slot))
	var button: int = [PlayerInput.ABILITY_1, PlayerInput.ABILITY_2, PlayerInput.ABILITY_3][slot]
	if kit_role(ability) == KitRole.GUARD:
		var held: int = mini(_rng.randi_range(KIT_GUARD_HOLD_TICKS.x, KIT_GUARD_HOLD_TICKS.y),
				ability.active_to())
		_hold(tick, button, held, &"guard")
		_count(&"guard")
	else:
		_tap(tick, button, ability.total_ticks + _gap())
	if ability.projectile_id != 0:
		_set_aim(ability.projectile_speed_mps, ability.projectile_id)
	_count(StringName("ability_%d" % slot))


# Las habilidades listas del arma activa por su papel (la primera ranura de cada papel). En la pasarela de SIEGE (sin
# barandilla por dentro), sin las que avanzan en línea recta (la embestida, que además empuja, y el salto atrás): como
# la esquiva de lado, sacaban de ella a los dos al patio.
func _ready_roles(state: CombatState, tick: int) -> Dictionary[int, int]:
	var roles: Dictionary[int, int] = {}
	var weapon: WeaponTicks = CombatCatalog.weapon(state.weapon_id)
	if weapon == null:
		return roles
	for slot: int in CombatState.ABILITY_SLOTS:
		if not _slot_ready(state, slot, tick):
			continue
		var role: int = kit_role(CombatCatalog.ability(weapon.ability_id(slot)))
		if _siege_on_walkway_now and (role == KitRole.GAP_CLOSER or role == KitRole.ESCAPE):
			continue
		if role != KitRole.NONE and not roles.has(role):
			roles[role] = slot
	return roles


# Ranuras listas con una habilidad de disparo (sin el salto atrás, que es para huir).
func _ready_shot_slots(state: CombatState, tick: int) -> Array[int]:
	var found: Array[int] = []
	var weapon: WeaponTicks = CombatCatalog.weapon(state.weapon_id)
	if weapon == null:
		return found
	for slot: int in CombatState.ABILITY_SLOTS:
		if _slot_ready(state, slot, tick) \
				and kit_role(CombatCatalog.ability(weapon.ability_id(slot))) == KitRole.SHOT:
			found.append(slot)
	return found


func _slot_ready(state: CombatState, slot: int, tick: int) -> bool:
	return ActionMachine.ability_status(state, slot, tick) == ActionMachine.AbilityStatus.READY


func _tap_consumable(tick: int, index: int) -> void:
	var ability: AbilityTicks = CombatCatalog.ability(CombatCatalog.consumable_ids()[index])
	_tap(tick, PlayerInput.CONSUMABLE_1 if index == 0 else PlayerInput.CONSUMABLE_2,
			(ability.total_ticks if ability != null else 60) + _gap())
	_count(StringName("potion_%d" % index))


# Un toque de [param button] y la siguiente decisión dentro de [param busy_ticks].
func _tap(tick: int, button: int, busy_ticks: int) -> void:
	_hold_buttons = button
	_hold_until = tick + COMBAT_TAP_TICKS
	_hold_kind = &""
	_next_decision_tick = tick + maxi(busy_ticks, COMBAT_TAP_TICKS)


# [param button] mantenido [param ticks] ticks ([param kind]: qué es) y la siguiente decisión al soltarlo.
func _hold(tick: int, button: int, ticks: int, kind: StringName) -> void:
	_hold_buttons = button
	_hold_until = tick + ticks
	_hold_kind = kind
	_next_decision_tick = _hold_until + 1


func _gap() -> int:
	return _rng.randi_range(KIT_DECISION_GAP_TICKS.x, KIT_DECISION_GAP_TICKS.y)


func _count(key: StringName) -> void:
	_kit_counts[key] = int(_kit_counts.get(key, 0)) + 1


# Velocidad y gravedad del disparo que se apunta.
func _set_aim(speed: float, projectile_id: int) -> void:
	_aim_speed = speed
	var projectile: ProjectileTicks = CombatCatalog.projectile(projectile_id)
	_aim_gravity = projectile.gravity if projectile != null else 0.0


# Apunta [param input] al enemigo con el tiro adelantado del disparo que toca (el rápido si no hay otro), con
# su posición extrapolada desde que se buscó.
func _aim(input: PlayerInput, position: Vector3, tick: int, state: CombatState) -> void:
	var seen: Variant = _target_position()
	if not seen is Vector3:
		return
	if _aim_speed <= 0.0:
		var weapon: WeaponTicks = CombatCatalog.weapon(state.weapon_id)
		var light: AttackTicks = CombatCatalog.attack(weapon.light_ids[0])
		_set_aim(light.projectile_speed_mps, light.projectile_id)
	var velocity: Vector3 = _target_velocity()
	var target: Vector3 = (seen as Vector3) + velocity * (float(tick - _target_seen_tick()) / Ballistics.TICK_RATE)
	var look: Vector2 = lead_look(position, target, velocity, _aim_speed, _aim_gravity, _aim_left)
	input.look_yaw = look.x
	input.look_pitch = minf(look.y + kit_aim_raise, _MAX_AIM_PITCH)
	if _aim_left:
		input.buttons |= PlayerInput.AIM_LEFT


# El arquero se queda entre KIT_BOW_KEEP_MIN y KIT_BOW_KEEP_MAX del enemigo, moviéndose de lado entre medias. En la
# pasarela de SIEGE (sin barandilla por dentro) se queda quieto y dispara: tirando, lo que mueve no va por el eje, y
# cualquier paso le podría tirar al patio.
func _keep_bow_distance(input: PlayerInput, tick: int, distance: float) -> void:
	if _siege_on_walkway_now:
		return
	if distance < KIT_BOW_KEEP_MIN:
		input.move = Vector2(0.0, -1.0)
	elif distance > KIT_BOW_KEEP_MAX:
		input.move = Vector2(0.0, 1.0)
		if distance > KIT_BOW_KEEP_MAX + COMBAT_SPRINT_DISTANCE:
			input.buttons |= PlayerInput.SPRINT
	else:
		if tick >= _kit_strafe_until:
			_kit_strafe_until = tick + _rng.randi_range(KIT_STRAFE_TICKS.x, KIT_STRAFE_TICKS.y)
			_kit_strafe_sign = 1.0 if _rng.randi() % 2 == 0 else -1.0
		input.move = Vector2(_kit_strafe_sign, 0.0)


func _can_interact(state: CombatState) -> bool:
	return state.action == CombatState.Action.NONE or state.action == CombatState.Action.BLOCK


func _health_fraction() -> float:
	return float(_health_source.call()) if _health_source.is_valid() else 1.0


# Levantar a un aliado derribado (patrón COMBAT con kit): sigue manteniendo INTERACT si ya lo hacía; si hay un
# aliado derribado cerca y ningún enemigo en pie encima, va hacia él y mantiene INTERACT. null si no toca.
func _revive_input(tick: int, position: Vector3, yaw: float, state: CombatState) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = yaw
	if _hold_kind == &"revive":
		if tick < _hold_until:
			input.buttons = _hold_buttons
			return input
		_hold_kind = &""
	if not _ally_finder.is_valid() or state.action == CombatState.Action.DOWNED \
			or state.action == CombatState.Action.DEAD:
		return null
	if tick - _ally_checked_tick >= COMBAT_RETARGET_TICKS:
		_ally_checked_tick = tick
		_ally_position = _ally_finder.call(position)
	if not _ally_position is Vector3:
		return null
	var to_ally: Vector3 = (_ally_position as Vector3) - position
	to_ally.y = 0.0
	var distance: float = to_ally.length()
	if distance > KIT_REVIVE_SEARCH or tick < _hold_until:
		return null
	if _enemy_position is Vector3 and not _enemy_downed \
			and position.distance_to(_enemy_position as Vector3) < KIT_REVIVE_ENEMY_CLEARANCE:
		return null
	input.look_yaw = _yaw_toward(to_ally, yaw)
	if distance <= KIT_INTERACT_REACH:
		if _can_interact(state):
			_hold(tick, PlayerInput.INTERACT,
					CombatCatalog.tables().revive_ticks + KIT_INTERACT_MARGIN_TICKS, &"revive")
			_count(&"revive")
			input.buttons = PlayerInput.INTERACT
		return input
	input.move = Vector2(0.0, 1.0)
	if distance > COMBAT_SPRINT_DISTANCE:
		input.buttons |= PlayerInput.SPRINT
	return input


# --- Asedio -------------------------------------------------------------------------------------

# Entrada del patrón SIEGE (siempre hay una).
func _siege_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	_note_siege_position(position)
	_siege_on_walkway_now = is_on_walkway(position)
	# 0. Fuera de la zona de un golpe avisado, sin bloquear ni acabar lo que tuviera entre manos.
	var threat: Threat = _siege_threat_covering(position)
	if threat != null:
		if _siege_task != SiegeTask.EVADE:
			_siege_evade_since = tick
		_siege_task = SiegeTask.EVADE
		_hold_until = -1
		_hold_aims_gate = false
		_reset_stuck(tick, position)
		return _siege_evade_input(tick, position, yaw, threat)
	# Un ataque a la puerta ya empezado (un toque o un fuerte cargado) se acaba.
	if _hold_aims_gate and tick < _hold_until:
		_siege_task = SiegeTask.ASSAULT
		return _gate_hold_input(tick, position, yaw)
	_hold_aims_gate = false

	# 1. Un PNJ defensor a tiro que se pueda alcanzar (lo que guarda el fuerte mientras el círculo no está activo) y,
	# si no hay, un enemigo cualquiera.
	if _siege_defender_finder.is_valid() and not _siege.is_circle_active():
		_refresh_defender(tick, position)
		var fighting_defender: PlayerInput = _siege_fight_if_in_range(tick, position, yaw,
				_siege_defender_position, true)
		if fighting_defender != null:
			return fighting_defender
	if _enemy_finder.is_valid():
		_refresh_enemy(tick, position)
		var fighting: PlayerInput = _siege_fight_if_in_range(tick, position, yaw, _enemy_position, false)
		if fighting != null:
			return fighting
	_hold_until = -1

	# 2. Al empezar o tras reaparecer en su campamento, un atacante espera a los suyos (GUE-44).
	if _siege_rally_pending:
		_siege_rally_pending = false
		_siege_start_rally(tick, position)
	if _siege_rally_until >= 0:
		var waiting: PlayerInput = _siege_rally_input(tick, position, yaw)
		if waiting != null:
			return waiting

	# 3. El plan: marchar, asaltar la puerta o quedarse en el círculo.
	_ensure_route(position)
	var inside: bool = _siege_on_walkway_now or _siege_inside_fort(position)
	if inside:
		_siege_route_index = _siege_route_points.size()
	if _siege_route_index < _siege_route_points.size():
		_siege_task = SiegeTask.MARCH
		return _march_input(tick, position, yaw)
	var corner: Variant = _siege_around_enclosure(position)
	if corner is Vector3:
		_siege_task = SiegeTask.MARCH
		var to_corner: Vector3 = (corner as Vector3) - position
		to_corner.y = 0.0
		return _walk_input(tick, position, yaw, to_corner, to_corner.length())
	# La puerta cerrada solo se asalta desde fuera. Un atacante que ya está dentro (la puerta se ha reparado con él en el
	# patio, o el fuerte ha cambiado de dueño con él en la pasarela) sigue con la pasarela y el círculo: la captura no
	# necesita la puerta, y el hueco de la formación delante de ella le dejaba golpeando el aire de espaldas a ella.
	if not inside and _siege.is_gate_closed_for(_siege_realm) and _siege_has_places():
		_siege_task = SiegeTask.ASSAULT
		return _assault_input(tick, position, yaw)
	# 4. Con el papel de la pasarela (GUE-45): el dueño la guarda y el atacante la recorre una vez.
	var walkway: PlayerInput = _siege_walkway_input(tick, position, yaw)
	if walkway != null:
		return walkway
	_siege_task = SiegeTask.HOLD
	return _hold_circle_input(tick, position, yaw)


# Pelea con quien está en [param target] (una posición, o null; [param defender], si es el PNJ defensor) si toca
# (_siege_engagement); null si no. Si persiguiéndolo no se le acerca en SIEGE_STUCK_TICKS, deja de perseguir un rato
# (SIEGE_CHASE_GIVE_UP_TICKS); tirándole con el arco no persigue.
func _siege_fight_if_in_range(tick: int, position: Vector3, yaw: float, target: Variant,
		defender: bool) -> PlayerInput:
	if not target is Vector3:
		return null
	var target_feet: Vector3 = target
	var to_enemy: Vector3 = target_feet - position
	to_enemy.y = 0.0
	var distance: float = to_enemy.length()
	var engage: _Engage = _siege_engagement(position, target_feet, distance, defender)
	_kit_shoot_plan = engage == _Engage.SHOOT
	if engage == _Engage.SKIP:
		return null
	if engage == _Engage.SHOOT or distance <= COMBAT_ENGAGE_DISTANCE:
		# Ha llegado (o tira desde donde está): si el otro se vuelve a alejar (una esquiva, un paso atrás) es otra
		# persecución, que se mide desde entonces y no desde la distancia a la que empezó la de antes.
		_siege_chase_ref_tick = -1
	elif not _siege_keeps_chasing(tick, distance, target_feet, defender):
		return null
	_siege_task = SiegeTask.FIGHT
	_reset_stuck(tick, position)
	var heading: Vector3 = Vector3.ZERO
	if _siege_on_walkway_now and engage == _Engage.CLOSE:
		if distance > COMBAT_ENGAGE_DISTANCE:
			# En la pasarela, si hay una esquina entre los dos, primero la esquina: en línea recta se caería al patio.
			var enemy_point := Vector2(target_feet.x, target_feet.z)
			var corner: Variant = _siege_walkway_corner(Vector2(position.x, position.z),
					_siege_routes.walkway_offset(enemy_point))
			if corner is Vector2:
				var to_corner := Vector3((corner as Vector2).x - position.x, 0.0, (corner as Vector2).y - position.z)
				return _walk_input(tick, position, yaw, to_corner, to_corner.length())
		heading = _siege_walkway_heading(position, target_feet, yaw)
	var input: PlayerInput = _fight_input(tick, position, to_enemy, distance, yaw, defender)
	if heading != Vector3.ZERO:
		# En la pasarela mira al blanco (el arma le llega aunque esté de través, pegado a él), pero lo que se mueve
		# (acercarse, la esquiva hacia atrás) va por su eje y no hacia el patio: con el kit, en las peleas largas, una
		# esquiva «hacia atrás» con el otro casi al lado le tiraba al patio. Antes de la revisión de la integración miraba
		# por el eje y el de al lado era intocable para él.
		input.move = _siege_move_along(input.move, heading, input.look_yaw)
	return input


# Cómo pelea con el blanco que tiene los pies en [param target] a [param distance] metros en horizontal
# ([param defender]: el PNJ defensor). Sin el kit, o para ir a rematar a un derribado (hay que llegar andando), se acerca
# si está a menos de SIEGE_FIGHT_RANGE y lo puede alcanzar (_can_reach). Con el arco, le tira si está a menos de
# SIEGE_BOW_FIGHT_RANGE y a tiro (_siege_has_shot): con el arco en la mano, salvo que esté tan cerca que el kit saque la
# espada; con la espada en la mano y el arco a la espalda, si está más lejos que el cambio al arco o si la espada no le
# llega. Con el arco en la mano y sin tiro no pelea (le tiraría a la empalizada o a la puerta).
func _siege_engagement(position: Vector3, target: Vector3, distance: float, defender: bool) -> _Engage:
	var close: bool = distance <= SIEGE_FIGHT_RANGE and _can_reach(position, target)
	var kit: CombatState = _kit_state()
	var downed: bool = _siege_defender_downed if defender else _enemy_downed
	if kit == null or downed:
		return _Engage.CLOSE if close else _Engage.SKIP
	var bow_in_hand: bool = is_ranged_weapon(kit.weapon_id)
	var alt_ranged: bool = kit.alt_weapon_id != 0 and is_ranged_weapon(kit.alt_weapon_id)
	if not bow_in_hand and not alt_ranged:
		return _Engage.CLOSE if close else _Engage.SKIP
	# Con el arco en la mano, de cerca el kit saca la espada si la lleva (KIT_SWAP_TO_MELEE_DISTANCE).
	var to_sword: bool = bow_in_hand and kit.alt_weapon_id != 0 and not alt_ranged and not kit_ranged_only \
			and distance < KIT_SWAP_TO_MELEE_DISTANCE
	var shot: bool = distance <= SIEGE_BOW_FIGHT_RANGE and _siege_has_shot(position, target, defender)
	if not shot:
		if bow_in_hand and not to_sword:
			return _Engage.SKIP
		return _Engage.CLOSE if close else _Engage.SKIP
	if not close:
		return _Engage.SHOOT
	if bow_in_hand:
		return _Engage.CLOSE if to_sword else _Engage.SHOOT
	return _Engage.SHOOT if distance > KIT_SWAP_TO_RANGED_DISTANCE or kit_ranged_only else _Engage.CLOSE


# Una persecución (alguien a [param distance] metros, en [param target], más lejos que la distancia de pelea; con
# [param defender], el PNJ defensor): false si hay que dejarla, porque lleva SIEGE_STUCK_TICKS sin acercarse o porque la
# dejó hace poco. Solo mide persecuciones seguidas del mismo blanco: si el blanco cambia (del defensor al enemigo o al
# revés, o su posición salta más de SIEGE_TELEPORT_DISTANCE desde la comprobación anterior: es otro) empieza de cero.
func _siege_keeps_chasing(tick: int, distance: float, target: Vector3, defender: bool) -> bool:
	if tick < _siege_chase_blocked_until:
		return false
	var same_target: bool = defender == _siege_chase_defender \
			and target.distance_to(_siege_chase_target) <= SIEGE_TELEPORT_DISTANCE
	_siege_chase_defender = defender
	_siege_chase_target = target
	if not same_target or _siege_chase_ref_tick < 0 \
			or tick - _siege_chase_ref_tick > SIEGE_STUCK_TICKS + COMBAT_RETARGET_TICKS:
		# Empieza (otra persecución, o la misma tras un rato sin perseguir).
		_siege_chase_ref_tick = tick
		_siege_chase_ref_distance = distance
		return true
	if tick - _siege_chase_ref_tick < SIEGE_STUCK_TICKS:
		return true
	if _siege_chase_ref_distance - distance < SIEGE_STUCK_MIN_PROGRESS:
		_siege_chase_blocked_until = tick + SIEGE_CHASE_GIVE_UP_TICKS
		_siege_chase_ref_tick = -1
		return false
	_siege_chase_ref_tick = tick
	_siege_chase_ref_distance = distance
	return true


# Anota la posición y, si ha dado un salto (reaparición), reinicia la ruta y lo que recordaba.
func _note_siege_position(position: Vector3) -> void:
	if _siege_has_position and position.distance_to(_siege_last_position) > SIEGE_TELEPORT_DISTANCE:
		_reset_route()
		_hold_until = -1
		_hold_aims_gate = false
		_enemy_position = null
		_enemy_checked_tick = -1000
		_siege_defender_position = null
		_siege_defender_velocity = Vector3.ZERO
		_siege_defender_downed = false
		_siege_defender_checked_tick = -1000
		_enemy_velocity = Vector3.ZERO
		_enemy_downed = false
		_hold_kind = &""
		_kit_shoot_plan = false
		_sight_defender_tick = -1
		_sight_enemy_tick = -1
		_siege_chase_ref_tick = -1
		_siege_chase_blocked_until = -1
		_siege_rally_until = -1
		_siege_rally_pending = true
	_siege_has_position = true
	_siege_last_position = position


# El golpe avisado más cercano en cuya zona está [param position] (con [constant SIEGE_THREAT_MARGIN]), o null.
func _siege_threat_covering(position: Vector3) -> Threat:
	if not _siege_threat_finder.is_valid():
		return null
	var found: Variant = _siege_threat_finder.call(position)
	if not found is Array:
		return null
	var best: Threat = null
	var best_distance: float = INF
	for item: Variant in found:
		var candidate: Threat = item as Threat
		if candidate == null or not candidate.covers(position, SIEGE_THREAT_MARGIN):
			continue
		if not _siege_same_level(position, candidate.origin):
			# Un golpe desde el patio no llega a la pasarela, ni al revés (GUE-45).
			continue
		var distance: float = Vector2(position.x - candidate.origin.x, position.z - candidate.origin.z).length()
		if distance < best_distance:
			best_distance = distance
			best = candidate
	return best


# Salir de la zona de [param threat]: en línea recta desde quien golpea (hacia atrás de su golpe si está justo
# encima), con una esquiva al empezar (y otra cada SIEGE_EVADE_DODGE_TICKS si sigue dentro) y esprintando entre
# medias.
func _siege_evade_input(tick: int, position: Vector3, yaw: float, threat: Threat) -> PlayerInput:
	var away := Vector3(position.x - threat.origin.x, 0.0, position.z - threat.origin.z)
	if away.length_squared() < 0.01:
		away = Vector3(sin(threat.yaw), 0.0, cos(threat.yaw))
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = _yaw_toward(away, yaw)
	input.move = Vector2(0.0, 1.0)
	input.buttons |= PlayerInput.SPRINT
	if (tick - _siege_evade_since) % SIEGE_EVADE_DODGE_TICKS == 0:
		input.buttons |= PlayerInput.DODGE
	return input


func _reset_route() -> void:
	_siege_route_id = &""
	_siege_route_chosen = false
	_siege_route_points = PackedVector2Array()
	_siege_route_index = 0
	_siege_stuck_count = 0
	_siege_unstick = _Unstick.NONE
	_siege_unstick_until = -1
	_siege_stuck_ref_tick = -1
	_siege_walkway_swept = false
	_siege_climb_ramp = -1
	_siege_climb_index = -1


# Elige la ruta (con el generador del bot) si aún no tiene ninguna, y por qué punto empieza.
func _ensure_route(position: Vector3) -> void:
	if _siege_route_chosen:
		return
	_siege_route_chosen = true
	var candidates: Array[StringName] = _siege_route_candidates()
	if candidates.is_empty():
		return
	_siege_set_route(candidates[_rng.randi() % candidates.size()], position)


# Las rutas que hay para su reino, en el orden de ApproachRoutes.get_route_ids (vacío sin rutas).
func _siege_route_candidates() -> Array[StringName]:
	var candidates: Array[StringName] = []
	if _siege_routes == null:
		return candidates
	var realm_id: StringName = RealmCatalog.id_of_code(_siege_realm)
	for route: StringName in _siege_routes.get_route_ids():
		if _siege_routes.has_route(route, realm_id):
			candidates.append(route)
	return candidates


# Sigue la ruta [param route] de su reino desde el punto más cercano a [param position].
func _siege_set_route(route: StringName, position: Vector3) -> void:
	var realm_id: StringName = RealmCatalog.id_of_code(_siege_realm)
	_siege_route_id = route
	_siege_route_points = _siege_routes.get_points(route, realm_id)
	_siege_route_index = maxi(_siege_routes.get_nearest_index(route, realm_id, Vector2(position.x, position.z)), 0)


# --- Reunión (GUE-44) ---------------------------------------------------------------------------

# true si espera a los suyos al empezar o al reaparecer: tiene quién se los cuente y un grupo de más de uno.
func _siege_rally_enabled() -> bool:
	return _siege_rally_size > 1 and _siege_ally_counter.is_valid()


# true si va en grupo y, por tanto, cada uno en su hueco (la formación va con la reunión).
func _siege_in_formation() -> bool:
	return _siege_rally_enabled()


# Al empezar o al reaparecer: si es atacante y está en su campamento (a menos de SIEGE_RALLY_RADIUS del punto de
# reunión), espera a los suyos como mucho hasta la siguiente salida del reloj.
func _siege_start_rally(tick: int, position: Vector3) -> void:
	if not _siege_rally_enabled() or _siege.owner == _siege_realm:
		return
	var point: Variant = get_siege_rally_point()
	if not point is Vector3:
		return
	var rally: Vector3 = point
	if Vector2(position.x - rally.x, position.z - rally.z).length() > SIEGE_RALLY_RADIUS:
		return
	_siege_rally_until = next_rally_departure(tick, _siege_rally_period)


# Espera en el punto de reunión: va a su hueco en él y allí se queda quieto mirando al fuerte.
# null si deja de esperar (ya son bastantes, sale el reloj, o ahora es el dueño y le toca defender); entonces toma la
# ruta del grupo y sigue con su plan.
func _siege_rally_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	var point: Variant = get_siege_rally_point()
	if _siege.owner == _siege_realm or not point is Vector3 or not _siege_rally_enabled():
		_siege_rally_until = -1
		return null
	var rally: Vector3 = point
	var counted: Variant = _siege_ally_counter.call(rally, SIEGE_RALLY_RADIUS)
	var gathered: int = 1 + (maxi(int(counted), 0) if counted is int else 0)
	var fighting: int = 0
	if _siege_has_places():
		var at_fort: Variant = _siege_ally_counter.call(_siege.circle_center, SIEGE_RALLY_FORT_RADIUS)
		fighting = maxi(int(at_fort), 0) if at_fort is int else 0
	if gathered >= _siege_rally_size or fighting >= SIEGE_RALLY_JOIN_COUNT or tick >= _siege_rally_until:
		_siege_rally_until = -1
		_siege_rally_left_tick = tick
		_siege_take_group_route(tick, position)
		return null
	_siege_task = SiegeTask.RALLY
	var spot: Vector3 = rally + Vector3(_siege_slot.x, 0.0, _siege_slot.y) * SIEGE_SLOT_RALLY_SPREAD
	var to_spot := Vector3(spot.x - position.x, 0.0, spot.z - position.z)
	var distance: float = to_spot.length()
	if distance > SIEGE_SLOT_REACHED:
		return _walk_input(tick, position, yaw, to_spot, distance)
	_reset_stuck(tick, position)
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = yaw
	if _siege_has_places():
		var to_gate: Vector3 = _siege.gate_position - position
		to_gate.y = 0.0
		input.look_yaw = _yaw_toward(to_gate, yaw)
	return input


# Al salir de la reunión, la ruta del grupo (la de la vuelta del reloj en la que sale, rally_route_index), sin el
# generador: todos los que salen en el mismo tick van por la misma.
func _siege_take_group_route(tick: int, position: Vector3) -> void:
	_siege_route_chosen = true
	var candidates: Array[StringName] = _siege_route_candidates()
	if candidates.is_empty():
		return
	_siege_set_route(candidates[rally_route_index(tick, candidates.size(), _siege_rally_period)], position)


# Marcha: hacia el punto de la ruta que toca, esprintando si queda lejos y no hay enemigos cerca.
func _march_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	var target: Vector2 = _siege_route_points[_siege_route_index]
	var to_target := Vector3(target.x - position.x, 0.0, target.y - position.z)
	var distance: float = to_target.length()
	if distance > SIEGE_LOST_DISTANCE:
		# Se ha ido muy lejos de la ruta (una pelea, una caída): retoma por el punto más cercano.
		_siege_route_index = maxi(_siege_routes.get_nearest_index(_siege_route_id,
				RealmCatalog.id_of_code(_siege_realm), Vector2(position.x, position.z)), 0)
		target = _siege_route_points[_siege_route_index]
		to_target = Vector3(target.x - position.x, 0.0, target.y - position.z)
		distance = to_target.length()
	if _siege_in_formation():
		# De lado respecto del tramo que lleva a este punto (o de la dirección hacia él, en el primero).
		var along := Vector2(to_target.x, to_target.z)
		if _siege_route_index > 0:
			along = target - _siege_route_points[_siege_route_index - 1]
		if along.length_squared() > 0.0001:
			var side: Vector2 = Vector2(-along.y, along.x).normalized() * _siege_slot.x * SIEGE_SLOT_MARCH_SPREAD
			to_target += Vector3(side.x, 0.0, side.y)
			distance = to_target.length()
	if distance <= SIEGE_WAYPOINT_RADIUS:
		_siege_route_index += 1
	return _walk_input(tick, position, yaw, to_target, distance)


# Asalto: se acerca a la puerta y la golpea. En formación, desde su sitio a lo largo de la puerta y mirando de frente.
func _assault_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	var to_gate: Vector3 = _siege.gate_position - position
	to_gate.y = 0.0
	var distance: float = to_gate.length()
	var facing: Vector3 = to_gate
	var inward: Vector3 = _siege_inward()
	if _siege_in_formation() and inward != Vector3.ZERO:
		var across := Vector3(-inward.z, 0.0, inward.x)
		var spot: Vector3 = _siege.gate_position - inward * SIEGE_GATE_ATTACK_DISTANCE \
				+ across * (_siege_slot.x * SIEGE_SLOT_GATE_SPREAD)
		var to_spot := Vector3(spot.x - position.x, 0.0, spot.z - position.z)
		if to_spot.length() > SIEGE_SLOT_REACHED and distance > SIEGE_GATE_ATTACK_DISTANCE * 0.5:
			return _walk_input(tick, position, yaw, to_spot, to_spot.length())
		facing = inward
	elif distance > SIEGE_GATE_ATTACK_DISTANCE:
		return _walk_input(tick, position, yaw, to_gate, distance)
	_reset_stuck(tick, position)
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = _yaw_toward(facing, yaw)
	if tick >= _next_decision_tick:
		_hold_aims_gate = true
		if _kit_swaps_to_sword_for_gate(tick):
			# Con el kit, la puerta se golpea con la espada si la lleva: a flechazos le quitaba unas 2,6 veces menos.
			input.buttons = _hold_buttons
			return input
		if _rng.randf() < COMBAT_HEAVY_CHANCE:
			_start_heavy_attack(tick)
		else:
			_start_light_attack(tick)
		input.buttons = _hold_buttons
	return input


# Kit, asalto a la puerta: con el arco en la mano y la espada a la espalda (y sin ser un arquero puro, kit_ranged_only),
# pulsa el cambio de arma en cuanto puede (sin acción en curso; mientras tanto no golpea). true si no toca golpear: ha
# pulsado el cambio (queda en _hold_* y _next_decision_tick, como un toque) o lo espera.
func _kit_swaps_to_sword_for_gate(tick: int) -> bool:
	var kit: CombatState = _kit_state()
	if kit == null or kit_ranged_only or kit.alt_weapon_id == 0:
		return false
	if not is_ranged_weapon(kit.weapon_id) or is_ranged_weapon(kit.alt_weapon_id):
		return false
	_hold_buttons = 0
	if kit.action != CombatState.Action.NONE:
		return true
	_hold_move = Vector2.ZERO
	_tap(tick, PlayerInput.SWAP_WEAPON, CombatCatalog.tables().swap_ticks + _gap())
	_count(&"swap")
	return true


# Un ataque a la puerta que sigue: PRIMARY pulsado mirando a la puerta (en formación, de frente, como al empezarlo).
func _gate_hold_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	var to_gate: Vector3 = _siege.gate_position - position
	to_gate.y = 0.0
	var inward: Vector3 = _siege_inward()
	if _siege_in_formation() and inward != Vector3.ZERO:
		to_gate = inward
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = _yaw_toward(to_gate, yaw)
	input.buttons = _hold_buttons
	return input


# Círculo: hacia su centro y, dentro, quieto mirando a la puerta (por donde llegan los enemigos).
func _hold_circle_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	if not _siege_has_places():
		_reset_stuck(tick, position)
		var idle := PlayerInput.new()
		idle.tick = tick
		idle.look_yaw = yaw
		return idle
	var waypoint: Variant = _gate_waypoint(position)
	if waypoint is Vector3:
		var to_waypoint: Vector3 = (waypoint as Vector3) - position
		to_waypoint.y = 0.0
		return _walk_input(tick, position, yaw, to_waypoint, to_waypoint.length())
	var to_center: Vector3 = _siege.circle_center - position
	to_center.y = 0.0
	var distance: float = to_center.length()
	var circle_radius: float = _siege.circle_radius if _siege.circle_radius > 0.0 \
			else SIEGE_DEFAULT_CIRCLE_RADIUS
	var inward: Vector3 = _siege_inward()
	if _siege_in_formation() and inward != Vector3.ZERO:
		# Su sitio en el círculo: el centro más su hueco (de lado y en profundidad).
		var across := Vector3(-inward.z, 0.0, inward.x)
		var spread: float = minf(SIEGE_SLOT_CIRCLE_SPREAD, circle_radius * SIEGE_CIRCLE_HOLD_FRACTION)
		var spot: Vector3 = _siege.circle_center + (across * _siege_slot.x + inward * _siege_slot.y) * spread
		var to_spot := Vector3(spot.x - position.x, 0.0, spot.z - position.z)
		if to_spot.length() > SIEGE_SLOT_REACHED:
			return _walk_input(tick, position, yaw, to_spot, to_spot.length())
	elif distance > circle_radius * SIEGE_CIRCLE_HOLD_FRACTION:
		return _walk_input(tick, position, yaw, to_center, distance)
	_reset_stuck(tick, position)
	var input := PlayerInput.new()
	input.tick = tick
	var to_gate: Vector3 = _siege.gate_position - position
	to_gate.y = 0.0
	input.look_yaw = _yaw_toward(to_gate, yaw)
	return input


# Para entrar en el fuerte desde fuera: el punto al que ir antes del círculo (delante de la puerta, alineado
# con su eje, y luego un poco dentro), o null si ya ha cruzado la puerta o no sabe dónde está.
func _gate_waypoint(position: Vector3) -> Variant:
	var inward: Vector3 = _siege_inward()
	if inward == Vector3.ZERO:
		return null
	var from_gate: Vector3 = position - _siege.gate_position
	from_gate.y = 0.0
	var along: float = from_gate.dot(inward)
	if along >= 0.5:
		return null
	var lateral: float = (from_gate - inward * along).length()
	if lateral > SIEGE_GATE_AXIS_TOLERANCE and (along < -2.0 or lateral > SIEGE_GATE_OPENING_HALF_WIDTH):
		return _siege.gate_position - inward * SIEGE_GATE_FRONT_DISTANCE
	return _siege.gate_position + inward * SIEGE_GATE_EXIT_DISTANCE


# Caminar hacia [param to_target] (a [param distance] metros): esprinta si queda lejos y no hay enemigos
# cerca, y se desatasca con un salto y, después, con un desvío.
func _walk_input(tick: int, position: Vector3, yaw: float, to_target: Vector3,
		distance: float) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = _yaw_toward(to_target, yaw)
	input.move = Vector2(0.0, 1.0)
	if distance > SIEGE_SPRINT_DISTANCE and _enemies_clear(position):
		input.buttons |= PlayerInput.SPRINT
	_apply_unstick(tick, position, input)
	return input


# true si el último enemigo que se vio está lejos (o no hay).
func _enemies_clear(position: Vector3) -> bool:
	if not _enemy_position is Vector3:
		return true
	return position.distance_to(_enemy_position as Vector3) > SIEGE_SPRINT_ENEMY_CLEARANCE


# Si lleva SIEGE_STUCK_TICKS caminando sin avanzar, prueba un salto y, si sigue igual, un desvío lateral
# (y vuelta a empezar); modifica [param input] mientras dura el intento.
func _apply_unstick(tick: int, position: Vector3, input: PlayerInput) -> void:
	if tick < _siege_unstick_until:
		match _siege_unstick:
			_Unstick.JUMP:
				if (tick - _siege_unstick_start) % SIEGE_JUMP_PULSE_TICKS < JUMP_HOLD_TICKS.x:
					input.buttons |= PlayerInput.JUMP
			_Unstick.DETOUR:
				input.look_yaw = fposmod(input.look_yaw + _detour_sign * SIEGE_DETOUR_ANGLE, TAU)
		return
	if _siege_stuck_ref_tick < 0 or _siege_unstick != _Unstick.NONE:
		# Un intento que acaba cuenta desde cero.
		_siege_unstick = _Unstick.NONE
		_siege_stuck_ref_position = position
		_siege_stuck_ref_tick = tick
		return
	if tick - _siege_stuck_ref_tick < SIEGE_STUCK_TICKS:
		return
	var moved: float = Vector2(position.x - _siege_stuck_ref_position.x,
			position.z - _siege_stuck_ref_position.z).length()
	_siege_stuck_ref_position = position
	_siege_stuck_ref_tick = tick
	if moved >= SIEGE_STUCK_MIN_PROGRESS:
		_siege_stuck_count = 0
		return
	_siege_stuck_count += 1
	_siege_unstick_start = tick
	if _siege_stuck_count % 2 == 1:
		_siege_unstick = _Unstick.JUMP
		_siege_unstick_until = tick + SIEGE_JUMP_WINDOW_TICKS
		if (tick - _siege_unstick_start) % SIEGE_JUMP_PULSE_TICKS < JUMP_HOLD_TICKS.x:
			input.buttons |= PlayerInput.JUMP
	else:
		_siege_unstick = _Unstick.DETOUR
		_siege_unstick_until = tick + SIEGE_DETOUR_TICKS
		_detour_sign = 1.0 if _rng.randi() % 2 == 0 else -1.0
		input.look_yaw = fposmod(input.look_yaw + _detour_sign * SIEGE_DETOUR_ANGLE, TAU)


# Lo que no es caminar (pelear, golpear la puerta, esperar en el círculo) no es estar atascado.
func _reset_stuck(tick: int, position: Vector3) -> void:
	_siege_stuck_count = 0
	_siege_unstick = _Unstick.NONE
	_siege_unstick_until = -1
	_siege_stuck_ref_position = position
	_siege_stuck_ref_tick = tick


# true si hay posiciones de la puerta y del círculo (sin ellas el bot solo sigue su ruta).
func _siege_has_places() -> bool:
	return _siege.circle_radius > 0.0 or _siege.circle_center != Vector3.ZERO \
			or _siege.gate_position != Vector3.ZERO


# Fuera del recinto, al lado de una pared que no es la de la puerta o detrás del fuerte: la esquina a la que ir para
# rodearlo hacia la pared de la puerta (del lado en el que está), o null si está dentro, delante de la pared de la puerta
# o no se sabe el tamaño del recinto. Sin esto iba derecho al círculo y se quedaba pegado a la empalizada.
func _siege_around_enclosure(position: Vector3) -> Variant:
	if _siege.is_inside_enclosure(position, SIEGE_ENCLOSURE_MARGIN) != 0:
		return null
	var inward: Vector3 = _siege_inward()
	var across := Vector3(-inward.z, 0.0, inward.x)
	var offset: Vector3 = position - _siege.gate_position
	offset.y = 0.0
	var along: float = offset.dot(inward)
	var lateral: float = offset.dot(across)
	var half_width: float = _siege.enclosure_size.y * 0.5
	var beside: bool = absf(lateral) >= half_width - SIEGE_ENCLOSURE_MARGIN
	var behind: bool = along >= _siege.enclosure_size.x - SIEGE_ENCLOSURE_MARGIN
	if along < 0.0 or (not beside and not behind):
		# Delante de la pared de la puerta, o en su vano: de eso se ocupan la ruta y la puerta.
		return null
	var side: float = 1.0 if lateral >= 0.0 else -1.0
	var corner_lateral: float = side * (half_width + SIEGE_CORNER_MARGIN)
	var corner_along: float = -SIEGE_CORNER_MARGIN
	if along > _siege.enclosure_size.x and absf(lateral) < half_width + SIEGE_CORNER_MARGIN - SIEGE_WAYPOINT_RADIUS:
		# Detrás de la pared del fondo: primero la esquina de atrás de su lado.
		corner_along = _siege.enclosure_size.x + SIEGE_CORNER_MARGIN
	var target: Vector3 = _siege.gate_position + inward * corner_along + across * corner_lateral
	target.y = position.y
	return target


# true si [param position] está dentro del fuerte: dentro del recinto si el [SiegeView] sabe su tamaño y, si no, al
# otro lado de la puerta, mirando desde fuera, y cerca del círculo.
func _siege_inside_fort(position: Vector3) -> bool:
	if not _siege_has_places():
		return false
	var inward: Vector3 = _siege_inward()
	if inward == Vector3.ZERO:
		return false
	var enclosure: int = _siege.is_inside_enclosure(position, SIEGE_ENCLOSURE_MARGIN)
	if enclosure >= 0:
		return enclosure == 1
	var from_gate: Vector3 = position - _siege.gate_position
	from_gate.y = 0.0
	var from_circle: Vector3 = position - _siege.circle_center
	from_circle.y = 0.0
	return from_gate.dot(inward) > 0.0 and from_circle.length() <= SIEGE_INSIDE_RADIUS


# Dirección horizontal de la puerta hacia el círculo (hacia dentro del fuerte); cero si no se sabe.
func _siege_inward() -> Vector3:
	var inward: Vector3 = _siege.circle_center - _siege.gate_position
	inward.y = 0.0
	return inward.normalized() if inward.length_squared() > 0.0001 else Vector3.ZERO


# true si el bot puede llegar andando hasta [param target] (para golpearle cuerpo a cuerpo o rematarle): está a su nivel
# (GUE-45) y no al otro lado de una puerta que le cierra el paso. El tiro con el arco lo decide _siege_has_shot.
func _can_reach(position: Vector3, target: Vector3) -> bool:
	if not _siege_same_level(position, target):
		return false
	if not _siege.is_gate_closed_for(_siege_realm) or not _siege_has_places():
		return true
	var inward: Vector3 = _siege_inward()
	if inward == Vector3.ZERO:
		return true
	var mine: Vector3 = position - _siege.gate_position
	var theirs: Vector3 = target - _siege.gate_position
	mine.y = 0.0
	theirs.y = 0.0
	return (mine.dot(inward) > 0.0) == (theirs.dot(inward) > 0.0)


# true si el bot tiene tiro con el arco al blanco con los pies en [param target] ([param defender]: el PNJ defensor):
# lo deja lo que sabe del fuerte (_siege_open_shot) y la línea de tiro de set_line_of_sight, si la tiene. La línea se
# pregunta una vez por búsqueda del blanco (su tick, que cambia cada COMBAT_RETARGET_TICKS).
func _siege_has_shot(position: Vector3, target: Vector3, defender: bool) -> bool:
	if not _siege_open_shot(position, target):
		return false
	if not _line_of_sight.is_valid():
		return true
	if defender:
		if _sight_defender_tick != _siege_defender_checked_tick:
			_sight_defender_tick = _siege_defender_checked_tick
			_sight_defender = bool(_line_of_sight.call(position, target, _aim_left))
		return _sight_defender
	if _sight_enemy_tick != _enemy_checked_tick:
		_sight_enemy_tick = _enemy_checked_tick
		_sight_enemy = bool(_line_of_sight.call(position, target, _aim_left))
	return _sight_enemy


# Lo que sabe del fuerte sobre un tiro de [param position] a [param target]: la empalizada y la puerta entera cortan el
# tiro entre dentro y fuera del recinto a todos los reinos (también al dueño: el cuerpo de vista de su puerta para las
# flechas en los dos sentidos), y con la puerta rota solo se tira de un lado a otro por el vano. Desde la pasarela, o a
# alguien que está en ella, decide la línea de tiro (el parapeto). Sin el tamaño del recinto, la puerta entera corta el
# tiro entre los dos lados de su plano. Sin posiciones del fuerte, true.
func _siege_open_shot(position: Vector3, target: Vector3) -> bool:
	if not _siege_has_places():
		return true
	if _siege_on_walkway_now or is_on_walkway(target):
		return true
	var mine: int = _siege.is_inside_enclosure(position)
	var theirs: int = _siege.is_inside_enclosure(target)
	if mine < 0 or theirs < 0:
		if _siege.is_gate_broken():
			return true
		var inward: Vector3 = _siege_inward()
		var from_gate: Vector3 = position - _siege.gate_position
		var to_gate: Vector3 = target - _siege.gate_position
		from_gate.y = 0.0
		to_gate.y = 0.0
		return inward == Vector3.ZERO or (from_gate.dot(inward) > 0.0) == (to_gate.dot(inward) > 0.0)
	if mine == theirs:
		return true
	if not _siege.is_gate_broken():
		return false
	return _siege_through_gap(position if mine == 1 else target, target if mine == 1 else position)


# true si la línea (en planta) de [param inside] (dentro del recinto) a [param outside] (fuera) sale por el vano de la
# puerta: cruza la pared de la puerta, y a menos de SIEGE_BOW_GAP_HALF_WIDTH de su centro. El recinto es convexo, así
# que si cruza esa pared dentro de su ancho no cruza ninguna otra.
func _siege_through_gap(inside: Vector3, outside: Vector3) -> bool:
	var inward: Vector3 = _siege_inward()
	if inward == Vector3.ZERO:
		return false
	var across := Vector3(-inward.z, 0.0, inward.x)
	var a: Vector3 = inside - _siege.gate_position
	var b: Vector3 = outside - _siege.gate_position
	var a_along: float = a.x * inward.x + a.z * inward.z
	var b_along: float = b.x * inward.x + b.z * inward.z
	if a_along <= 0.0 or b_along >= 0.0:
		return false
	var t: float = a_along / (a_along - b_along)
	var a_side: float = a.x * across.x + a.z * across.z
	var b_side: float = b.x * across.x + b.z * across.z
	return absf(a_side + (b_side - a_side) * t) <= SIEGE_BOW_GAP_HALF_WIDTH


# [param move] (en el marco de un personaje que mirase hacia [param heading]: y adelante, x a su derecha) pasado al
# marco de [param look_yaw], el que mira de verdad: el mismo desplazamiento en el mundo. La simulación mueve (y esquiva)
# relativo al yaw de la cámara (PlayerCharacter.simulate y ActionMachine._dodge_yaw).
static func _siege_move_along(move: Vector2, heading: Vector3, look_yaw: float) -> Vector2:
	if move == Vector2.ZERO:
		return move
	var side := Vector3(-heading.z, 0.0, heading.x)
	var world: Vector3 = heading * move.y + side * move.x
	var forward := Vector3(-sin(look_yaw), 0.0, -cos(look_yaw))
	var right := Vector3(cos(look_yaw), 0.0, -sin(look_yaw))
	return Vector2(world.dot(right), world.dot(forward))


# --- Pasarela (GUE-45) --------------------------------------------------------------------------

# true si [param a] y [param b] están a un nivel desde el que se alcanzan: a menos de SIEGE_LEVEL_TOLERANCE en vertical,
# o los dos fuera del recinto (las laderas de fuera no son niveles: ahí no cambia nada). Sin recinto conocido, siempre.
func _siege_same_level(a: Vector3, b: Vector3) -> bool:
	if absf(a.y - b.y) <= SIEGE_LEVEL_TOLERANCE or not _siege_has_places():
		return true
	return _siege.is_inside_enclosure(a) != 1 and _siege.is_inside_enclosure(b) != 1


# true si el bot tiene que ir a la pasarela: las rutas la conocen, y o es el dueño y la guarda, o es atacante y la
# recorre, aún no lo ha hecho en esta vida y ya está dentro del fuerte (o en ella).
func _siege_walkway_wanted(position: Vector3) -> bool:
	if _siege_routes == null or not _siege_routes.has_walkway() or not _siege_has_places():
		return false
	if _siege.should_defend(_siege_realm):
		return _siege_walkway_role
	if not _siege_walkway_sweeper or _siege_walkway_swept:
		return false
	return _siege_on_walkway_now or _siege_inside_fort(position)


# Metros a lo largo del eje de la pasarela de su puesto: encima de la puerta, más su hueco de lado.
func _siege_walkway_post_offset() -> float:
	var post: float = _siege_routes.walkway_offset(_siege_routes.walkway_post())
	return clampf(post + _siege_slot.x * SIEGE_WALKWAY_POST_SPREAD, 0.0, _siege_routes.walkway_length())


# La pasarela: entra en el fuerte si está fuera, sube por la rampa que le toca, va por el eje hasta su puesto y allí lo
# guarda mirando afuera (el dueño) o da la pasarela por recorrida y sigue con su plan (el atacante, que salta al patio
# camino del círculo). null si no tiene que ir.
func _siege_walkway_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	if not _siege_walkway_wanted(position):
		_siege_climb_ramp = -1
		return null
	var here := Vector2(position.x, position.z)
	var post_offset: float = _siege_walkway_post_offset()
	if _siege_on_walkway_now and _siege_climb_ramp >= 0:
		# Lo alto de la rampa ya cuenta como pasarela, pero hasta la cima (en el eje) sigue subiendo: si girase antes,
		# se saldría de la rampa por un lado.
		var ramp: PackedVector2Array = _siege_routes.walkway_ramps[_siege_climb_ramp]
		var top: Vector2 = ramp[ramp.size() - 1]
		if _siege_climb_index >= ramp.size() - 1 and here.distance_to(top) > SIEGE_WALKWAY_REACHED:
			_siege_task = SiegeTask.WALKWAY
			var to_top := Vector3(top.x - position.x, 0.0, top.y - position.z)
			return _walk_input(tick, position, yaw, to_top, to_top.length())
		_siege_climb_ramp = -1
	if _siege_on_walkway_now:
		var axis: Vector2 = _siege_routes.walkway_point(_siege_routes.walkway_offset(here))
		if here.distance_to(axis) > SIEGE_WALKWAY_REACHED:
			# Apartado del eje (una pelea, una esquiva): primero vuelve a él, lejos del borde de dentro.
			_siege_task = SiegeTask.WALKWAY
			var to_axis := Vector3(axis.x - position.x, 0.0, axis.y - position.z)
			return _walk_input(tick, position, yaw, to_axis, to_axis.length())
		var post: Vector2 = _siege_routes.walkway_point(post_offset)
		if here.distance_to(post) <= SIEGE_WALKWAY_REACHED:
			if not _siege.should_defend(_siege_realm):
				_siege_walkway_swept = true
				return null
			_siege_task = SiegeTask.WALKWAY
			_reset_stuck(tick, position)
			var holding := PlayerInput.new()
			holding.tick = tick
			holding.look_yaw = _yaw_toward(-_siege_inward(), yaw)
			return holding
		_siege_task = SiegeTask.WALKWAY
		var next: Vector2 = _siege_walkway_next(here, post_offset)
		var to_next := Vector3(next.x - position.x, 0.0, next.y - position.z)
		return _walk_input(tick, position, yaw, to_next, to_next.length())
	_siege_task = SiegeTask.WALKWAY
	var waypoint: Variant = _gate_waypoint(position)
	if waypoint is Vector3:
		var to_waypoint: Vector3 = (waypoint as Vector3) - position
		to_waypoint.y = 0.0
		return _walk_input(tick, position, yaw, to_waypoint, to_waypoint.length())
	var target: Vector2 = _siege_climb_target(here, post_offset)
	var to_target := Vector3(target.x - position.x, 0.0, target.y - position.z)
	return _walk_input(tick, position, yaw, to_target, to_target.length())


# El punto de la rampa al que va: la rampa cuya cima queda más cerca de su puesto a lo largo de la pasarela (a igualdad,
# la primera), empezando por el punto del patio más cercano; los alcanza a SIEGE_WALKWAY_REACHED. Si iba a la cima y se
# ha apartado del eje de la rampa (lo han empujado o se ha caído), vuelve primero al punto de delante de su pie.
func _siege_climb_target(here: Vector2, post_offset: float) -> Vector2:
	var ramps: Array[PackedVector2Array] = _siege_routes.walkway_ramps
	if _siege_climb_ramp < 0 or _siege_climb_ramp >= ramps.size():
		_siege_climb_ramp = 0
		var best_gap: float = INF
		for index: int in ramps.size():
			if ramps[index].is_empty():
				continue
			var top: Vector2 = ramps[index][ramps[index].size() - 1]
			var gap: float = absf(_siege_routes.walkway_offset(top) - post_offset)
			if gap < best_gap - 0.001:
				best_gap = gap
				_siege_climb_ramp = index
		_siege_climb_index = -1
	var points: PackedVector2Array = ramps[_siege_climb_ramp]
	var last: int = points.size() - 1
	if _siege_climb_index < 0:
		_siege_climb_index = 0
		var best: float = INF
		for index: int in maxi(last, 1):
			var distance: float = here.distance_to(points[index])
			if distance < best:
				best = distance
				_siege_climb_index = index
	if last > 0 and _siege_climb_index >= last and not _siege_on_ramp_axis(here, points[last - 1], points[last]):
		_siege_climb_index = last - 1
	if _siege_climb_index < last and here.distance_to(points[_siege_climb_index]) <= SIEGE_WALKWAY_REACHED:
		_siege_climb_index += 1
	return points[mini(_siege_climb_index, last)]


# La dirección (horizontal y unitaria) del eje de la pasarela en [param position] hacia [param target]: hacia donde crece
# su distancia a lo largo del eje si el blanco está más allá, o hacia atrás si está más acá; con los dos a la par (a
# menos de 0,25 m a lo largo del eje), hacia el lado al que mira con [param yaw]. Cero si no hay eje.
func _siege_walkway_heading(position: Vector3, target: Vector3, yaw: float) -> Vector3:
	var mine: float = _siege_routes.walkway_offset(Vector2(position.x, position.z))
	var theirs: float = _siege_routes.walkway_offset(Vector2(target.x, target.z))
	var length: float = _siege_routes.walkway_length()
	var from: Vector2 = _siege_routes.walkway_point(clampf(mine - 0.25, 0.0, length))
	var to: Vector2 = _siege_routes.walkway_point(clampf(mine + 0.25, 0.0, length))
	var tangent := Vector3(to.x - from.x, 0.0, to.y - from.y)
	if tangent.length_squared() < 0.0001:
		return Vector3.ZERO
	tangent = tangent.normalized()
	var side: float = signf(theirs - mine) if absf(theirs - mine) >= 0.25 \
			else signf(Vector3(-sin(yaw), 0.0, -cos(yaw)).dot(tangent))
	return tangent * (side if side != 0.0 else 1.0)


# true si [param here] está en el eje de la rampa que va de [param foot] a [param top] (con SIEGE_RAMP_AXIS_TOLERANCE de
# lado y un poco de holgura en sus extremos).
func _siege_on_ramp_axis(here: Vector2, foot: Vector2, top: Vector2) -> bool:
	var along: Vector2 = top - foot
	var length: float = along.length()
	if length < 0.001:
		return here.distance_to(top) <= SIEGE_RAMP_AXIS_TOLERANCE
	var direction: Vector2 = along / length
	var offset: Vector2 = here - foot
	var t: float = offset.dot(direction)
	return t >= -SIEGE_RAMP_AXIS_TOLERANCE and t <= length + SIEGE_RAMP_AXIS_TOLERANCE \
			and absf(offset.cross(direction)) <= SIEGE_RAMP_AXIS_TOLERANCE


# Hacia dónde ir por la pasarela desde [param here] para llegar al punto de su eje que está a [param target_offset]
# metros: la primera esquina que hay en medio o, si no hay ninguna, ese punto.
func _siege_walkway_next(here: Vector2, target_offset: float) -> Vector2:
	var corner: Variant = _siege_walkway_corner(here, target_offset)
	return corner as Vector2 if corner is Vector2 else _siege_routes.walkway_point(target_offset)


# La primera esquina (un punto del eje de la pasarela) entre [param here] y el punto del eje a [param target_offset]
# metros, o null si no hay ninguna (las que están a menos de SIEGE_WALKWAY_REACHED se dan por pasadas).
func _siege_walkway_corner(here: Vector2, target_offset: float) -> Variant:
	var mine: float = _siege_routes.walkway_offset(here)
	var offsets: PackedFloat32Array = _siege_routes.walkway_vertex_offsets()
	var path: PackedVector2Array = _siege_routes.walkway_path
	if target_offset > mine:
		for index: int in offsets.size():
			if offsets[index] > mine + SIEGE_WALKWAY_REACHED and offsets[index] < target_offset:
				return path[index]
	else:
		for index: int in range(offsets.size() - 1, -1, -1):
			if offsets[index] < mine - SIEGE_WALKWAY_REACHED and offsets[index] > target_offset:
				return path[index]
	return null


# --- Paseo --------------------------------------------------------------------------------------

# Elige el rumbo, la marcha y el esprint del siguiente tramo de paseo.
func _start_segment(tick: int) -> void:
	_next_change_tick = tick + _rng.randi_range(SEGMENT_MIN_TICKS, SEGMENT_MAX_TICKS)
	_heading = _rng.randf() * TAU
	_sprint = false
	if _rng.randf() < PAUSE_CHANCE:
		_move = Vector2.ZERO
		return
	_move = Vector2(0.0, 1.0)
	if _rng.randf() < STRAFE_CHANCE:
		_move = Vector2(_rng.randf_range(-0.7, 0.7), 1.0).limit_length(1.0)
	else:
		_sprint = _rng.randf() < SPRINT_CHANCE


# Pulsa el botón de salto cuando toca y programa el siguiente salto.
func _update_jump(tick: int) -> void:
	if tick < _next_jump_tick:
		return
	_jump_release_tick = tick + _rng.randi_range(JUMP_HOLD_TICKS.x, JUMP_HOLD_TICKS.y)
	_schedule_jump(_jump_release_tick)


func _schedule_jump(from_tick: int) -> void:
	var gap: Vector2i = JUMPY_JUMP_GAP_TICKS if _pattern == Pattern.JUMPY else WANDER_JUMP_GAP_TICKS
	_next_jump_tick = from_tick + _rng.randi_range(gap.x, gap.y)


# Yaw que mira hacia [param direction] (plano horizontal), con la convención de PlayerInput: el
# yaw 0 mira hacia -Z. Con una dirección nula conserva [param fallback].
func _yaw_toward(direction: Vector3, fallback: float) -> float:
	if direction.x * direction.x + direction.z * direction.z < 0.0001:
		return fallback
	return fposmod(atan2(-direction.x, -direction.z), TAU)


# Rumbo de una circunferencia alrededor de home: la tangente más una corrección radial que
# devuelve al bot a su circunferencia si se desvía.
func _circle_yaw(position: Vector3, fallback: float) -> float:
	var circle_radius: float = maxf(_radius * CIRCLE_RADIUS_FRACTION, CIRCLE_MIN_RADIUS)
	var offset: Vector3 = position - _home
	offset.y = 0.0
	var distance: float = offset.length()
	if distance < 0.01:
		return fallback
	var radial: Vector3 = offset / distance
	var tangent := Vector3(-radial.z, 0.0, radial.x) * _circle_sign
	var correction: float = clampf((circle_radius - distance) / circle_radius * 2.0, -1.0, 1.0)
	return _yaw_toward(tangent + radial * correction, fallback)
