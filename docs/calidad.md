# Eldmark: plan de calidad visual

Este documento es el plan para que el corte vertical del Vado Gris pase de prototipo a algo decente. Parte de la primera partida con ventana (1 de noviembre de 2026, servidor, 8 bots y cliente), de cuatro auditorías con capturas reales a 1920 × 1080 (animación, mapa e interfaz, mundo y combate) y de una investigación de assets a 1 de noviembre. Las capturas están en `build/calidad/` y su índice en `build/calidad/indice.md`. Los elementos del backlog que salen de aquí están en [backlog.md](backlog.md) con el prefijo de su área.

Antes de escribirlo he revisado yo mismo las capturas que respaldan los hallazgos graves y he comprobado en el repo las causas que deciden el plan. Lo que no se sostiene o hay que matizar:

- **Las cápsulas rojas de las cámaras de revisión no son del juego.** Las pone `tools/render/render_screenshot_points.gd` como referencia de escala (`--no-capsules` las quita). No hay nada que arreglar.
- **UAL2 Standard ya trae más de lo que suponían las auditorías.** El GLB del repo contiene `Idle_Shield_Loop`, `Idle_Shield_Break`, `Sword_Block`, `Sword_Dash`, `Shield_Dash`, `Shield_OneShot`, `Hit_Knockback`, `Melee_Hook`, `LayToIdle`, `Zombie_Idle_Loop`, `Zombie_Walk_Fwd_Loop` y `Zombie_Scratch`. Lo que aporta de verdad UAL2 Source es andar en 8 direcciones, el arco, el esprint con escudo, el zombi en 8 direcciones y golpes como Groundpound y Uppercut.
- **La regla de reproducir cada clip entre 0,7x y 1,5x no puede cumplirse en la esquiva.** El único clip es `Roll` (1,35 s) y la esquiva dura 27 ticks (0,45 s). Hasta tener clips de esquiva propios, la prueba admite hasta 2x solo en la esquiva.
- **Las rocas flotantes son probables, no seguras.** En `mundo/jugador_vardheim/28_ruinas_final_de_calzada.png` hay una roca sin contacto visible con la ladera, pero a esa distancia no es concluyente. Lo que sí está comprobado es que el generador no hunde las instancias según la pendiente.
- **La pose de caída de un PNJ remoto (`rem_hueco_ataque_b.png`) está sin confirmar**: la tira no deja ver si es el Hueco seguido. Se repite con el banco de capturas (TEC-50).
- **Las capturas no sirven para juzgar el audio, la parada de golpe ni la fluidez.** Esos hallazgos se han comprobado en el código: `assets/audio/` está vacío y nadie escucha `sound_requested` ni `swing_active_changed`.
- **La espada de ART-06 no puede salir del Fantasy Props MegaKit con seguridad**: la página no nombra espadas. La primera prueba es la espada de RPG Weapons Free.
- **La luz que propone la auditoría de mundo choca con mundo.md**, que pinta el Vado Gris como frontera de Eldrun bajo un cielo cubierto. Queda como decisión del usuario (sección 6).
- **Las herramientas que hicieron las capturas no están versionadas**: viven en `build/calidad/scripts/`, que Git ignora. Sin ellas no se puede demostrar ninguna mejora, así que guardarlas en `tools/` es lo primero (TEC-50).

---

## 1. Veredicto

**Animación.** Es la parte más floja y la que más se nota. El reposo y la locomoción usan clips sin arma, así que la espada y el escudo, que son una caja y un disco pegados a las manos, apuntan a cualquier lado y nunca hay guardia. Los ataques solo mueven el torso: las piernas siguen el ciclo de andar que provoca la estocada y cada tajo acaba en un saltito sobre un pie, con el escudo saliendo por detrás del hombro (`animacion/lado/com_combo_completo.png`, fotogramas 2 y 8 a 10). Al reescalar cada tramo a los ticks de combate, las velocidades van de 0,35x a 3,3x: la anticipación del fuerte parece congelada y las recuperaciones son espasmos. El bloqueo es una parada con la espada congelada en un fotograma, con el escudo colgando (`camara_juego/com_bloqueo__mantener.png`). La esquiva es una voltereta hacia delante aunque se esquive hacia atrás. Los Huecos y el Capitán no tienen ni un clip de ataque: su golpe imparable es un hombre que camina (`lado/npc_hollow_ataque_ligero.png`). La mitad se arregla con clips que ya están en el repo y código del animador; el strafe, la esquiva lateral, el arco y la segunda muerte exigen comprar UAL1 Pro y UAL2 Source.

**Sensación de combate.** La simulación funciona, pero en pantalla no existe el golpe. No hay un solo sonido, ni chispa, ni estela, ni parada de golpe, y dos de cada tres ligeros no mueven a la víctima. La única señal es un recorte rojo plano de 0,12 s y un número, y una viñeta roja que tiñe media pantalla con cualquier rasguño (`combate/pelea_b_05.png`, con 910 de 1000 de vida). Huecos, Capitán, aliados y enemigos son el mismo muñeco. Casi todo es falta de contenido y de conexiones: las señales ya existen en `CombatFeedback` y nadie las escucha.

**Mapa y minimapa.** El mapa M no es un mapa: es un volcado de la pintura del terreno con manchas de camuflaje en escalera, un río azul de cartel, árboles como lunares y una banda gris en el oeste (`mapa/imagen_horneada_vado_gris.png`). No se parece al Vado Gris brumoso del juego. La ventana pisa rótulos, deja sin nombre el vado, las ruinas, los puentes y la capilla, no tiene zoom y deja el HUD debajo. El minimapa estira el borde de la imagen en franjas en cuanto el jugador se acerca a un límite, y el campamento de aparición siempre lo está (`mapa/minimapa_06_borde_este_recorte.png`).

**Interfaz.** Se lee como una herramienta interna en modo oscuro. No hay tipografía propia (todo es la fuente del motor), los iconos son letras sobre cuadros de color y todas las ventanas son rectángulos casi negros sin marco. El HUD no tiene jerarquía: compiten 14 atajos de teclado, rótulos de lugares encimados bajo la mira, una brújula y un panel descentrados unos 300 px (`interfaz/hud_en_pelea_02.png`), y jefe, avisos y números que se pisan. Hay fallos de una línea que solo se ven con ventana: el aviso de derribado sale cortado por la izquierda (`interfaz/derribado_aviso.png`), un tooltip tapa el inventario al abrirlo y la figura de creación sale en la pose de salto. Casi todo es capa visual sin hacer, no sistemas que rehacer.

**Escenario.** El Vado Gris está bien medido para jugar (rutas simétricas, distancias y colisiones correctas), pero a la vista es un blockout. La luz es plana porque dos rellenos sin sombra igualan al sol. El terreno parece fieltro: texturas de acuarela solo de color, sin normales, con teselas de 8 a 17 m y la roca estirada en las laderas. El fuerte, que es el objetivo, es una caja baja que se confunde con la muralla enemiga que tiene detrás (`mundo/camaras_revision/vista_desde_puerta_vardheim.png`). El agua es una lámina lechosa, el cielo tiene vetas en el cénit y un disco solar borroso, y quedan a la vista tiendas prisma, estandartes lisos y cadalsos como bloques sueltos. Del Stylized Nature ya descargado se usan 16 de 68 modelos. Una parte grande se arregla con parámetros; el relieve, el fuerte y las murallas hay que rehacerlos como composición.

---

## 2. El listón

"Decente" aquí significa un indie pequeño con assets estilizados que no avergüenza en ninguna captura: nada que delate un placeholder, todo legible en combate y una identidad reconocible. No es un listón AAA. Cada criterio se comprueba repitiendo las capturas del banco de TEC-50 a 1920 × 1080; los marcados con ⓒ solo se cumplen tras las compras de la sección 5.

### Animación

1. En todos los fotogramas de `loc_*` (lado, frente y cámara del juego) el escudo va delante del torso y la hoja nunca apunta hacia atrás ni por encima de la cabeza. Los dedos de las dos manos están cerrados.
2. En `com_ligero_*`, `com_combo_completo` y `com_fuerte__golpe`, sin entrada de movimiento, los pies quedan plantados durante la anticipación y el golpe, la cadera gira hacia el golpe y el escudo no sale de delante del pecho.
3. Ningún tramo de ataque, bloqueo o habilidad se reproduce fuera de 0,7x a 1,5x de su velocidad original. Lo comprueba una prueba que cruza `data/animation` con los ticks de `data/combat`; la esquiva admite hasta 2x hasta tener clips propios, y la anticipación de los PNJ admite desde 0,3x (la alargan a propósito; se cambiará en la oleada 2 por un tramo a 1x más una pose mantenida).
4. Todo ataque de toda `WeaponDefinition` de `data/combat` tiene entrada en su `CombatClipSet` (prueba automática), y las tiras `npc_*` muestran un clip en cada fotograma de la acción.
5. Bloqueo: visto desde el atacante, el escudo tapa pecho y cabeza; la pose respira (no hay 12 fotogramas idénticos), se puede andar bloqueando y cada golpe bloqueado da una reacción visible de 0,15 s o más.
6. En las cuatro esquivas el cuerpo viaja hacia donde rueda o salta. ⓒ Con clips direccionales, el modelo no gira más de 15° respecto al punto de mira.
7. Todo golpe con daño se ve en el cuerpo de la víctima, aunque no imponga control. El tambaleo es de cuerpo entero con un paso atrás, el derribado se distingue del muerto y la muerte en carrera no frena en seco.
8. ⓒ Strafe y retroceso con clips propios en 8 direcciones al andar y al trotar; sobre la cuadrícula de 1 m ningún pie apoyado patina más de unos 5 cm por pisada.
9. ⓒ Arco vertical, cuerda tensada hasta la mejilla y suelta en el tick del disparo.
10. A 20 m, sin placas, un Hueco y el Capitán se distinguen de un jugador por silueta, color y forma de moverse.

### Sensación de combate

Se comprueba con las capturas y con un vídeo de un minuto con sonido grabado con el modo Movie Maker del motor (`--write-movie`), contra dos Huecos y un jugador.

1. Cada golpe propio que conecta da, dentro de su ventana activa, sonido de impacto según el material, chispa o polvo en el punto de contacto, parada de golpe de 50 a 80 ms en la animación y reacción visible en la víctima, también en los ligeros.
2. Todo golpe, barrido, bloqueo y esquiva suena, también el de los demás, en posición 3D.
3. Un golpe bloqueado da chispa, sonido de escudo, empuje y un pulso en la resistencia. Una parada se distingue de un bloqueo sin leer texto.
4. Un golpe de 90 no tiñe más del 10 % de la pantalla, y cada color significa una sola cosa (el rojo, la vida propia y el daño recibido; el peligro de un PNJ, otro color).
5. En una refriega ningún cuerpo tapa más del 30 % de la pantalla más de un instante.
6. No queda en pantalla ni una caja ni un disco plano: espada, escudo y arco son modelos, con sombra.
7. Todo ataque de PNJ se lee en el cuerpo al menos 0,4 s antes del golpe, sin mirar el suelo.

### Mapa y minimapa

1. En el mapa M, un jugador nuevo señala en cinco segundos el fuerte, los dos puentes, el vado, las ruinas, los campamentos y los pasos. Todos tienen nombre, ningún rótulo pisa otro, no hay escalones de píxel y las montañas enmarcan el valle, en la gama desaturada del juego.
2. El mapa M tiene zoom con la rueda y desplazamiento al arrastrar, y con él abierto el HUD no se transparenta.
3. El minimapa no enseña ninguna franja estirada en las seis posiciones de `sc_mapa` ni en sus tres niveles de zoom; los iconos que se tocan se fusionan y el cono de la cámara no tapa el terreno.

### Interfaz

1. Ningún texto usa la fuente del motor: dos familias OFL en todo, también en placas, vida, marcos de grupo y estados (prueba que falla si reaparece `ThemeDB.fallback_font` en `scripts/client`).
2. Ninguna casilla lleva una letra: cada acción tiene un icono dibujado, distinguible a 52 px y en escala de grises.
3. En una pelea con 12 combatientes, brújula, panel del fuerte, barra de jefe y avisos están centrados en x = 960 ± 1, nada se solapa, ningún rótulo de lugar queda a menos de 150 px de la mira y la línea de ayuda está oculta.
4. Todo texto sobre el mundo tiene un contraste de 4,5:1 o más contra su placa, no solo por contorno.
5. Aliado o enemigo se distingue a 20 m sin apuntar.
6. Ningún tooltip aparece sin pasar el ratón y ninguna ventana corta columnas.
7. El título tiene logotipo y fondo en el motor, la selección enseña la figura en reposo sobre un escenario y la carga dice el nombre de la zona con una imagen.

### Escenario

1. Luz con dirección: en la torre del fuerte y en una torre de muralla, la cara iluminada tiene tres veces o más la luminancia de la cara en sombra, y árboles, empalizada y torres proyectan sombra en el 80 % o más de las 66 vistas a altura de jugador.
2. A 3 m de la cámara el terreno enseña grano, piedras o briznas, y ninguna ladera de más de 35° tiene la textura estirada.
3. Desde los dos campamentos y los dos puentes, la torre del fuerte se recorta contra el cielo, no contra la muralla enemiga, y es la construcción más alta que se ve.
4. En ninguna de las 66 vistas hay hueco bajo una roca o un tronco.
5. En el vado se ve el lecho de grava y la corriente, el cauce hondo es más oscuro y el río nunca acaba en un hueco visible.
6. Mirando a cualquier borde hay al menos dos planos de relieve lejano y nunca se ve dónde acaba el terreno.
7. No quedan tiendas `PrismMesh`, banderas de Kenney ni telas de ruido; los estandartes llevan el emblema de `assets/emblems`.
8. Los bosquetes se leen como bosque (20 árboles o más, con sotobosque) y la corteza entra en la paleta de mundo.md.
9. El cielo no tiene vetas en el cénit y el sol es coherente con la luz.
10. Todo cabe en el presupuesto actual: menos de 2000 llamadas de dibujo y 2 M de primitivas en las vistas de `render_screenshot_points.gd`.

---

## 3. Lo que más cuesta poco

Arreglos de una sesión o menos, sin compras, ordenados por efecto. Juntos cambian la primera impresión de casi todas las capturas.

| Arreglo | Qué cambia en pantalla | Esfuerzo | Elemento |
|---|---|---|---|
| Clips de ataque para Huecos, Capitán, guardias y guardianes con clips del repo (`Zombie_Scratch`, `Sword_Attack`, `Sword_Regular_C`, `Sword_Heavy_Combo`), y una prueba de cobertura | Los PNJ dejan de atacar andando; el golpe imparable del Capitán se ve venir | S | ART-47 |
| Bloqueo con `Idle_Shield_Loop` en bucle en vez de `Sword_Block` congelado | El escudo tapa el pecho; el verbo defensivo principal por fin se lee | S | ART-48 |
| Quitar los dos rellenos de luz, subir el sol a 2–2,5, bajar el ambiente a 0,35–0,5 y alargar las sombras | El valle gana volumen y dirección en todas las vistas | S | ART-54 |
| Viñeta de daño proporcional y solo en el borde; destello de la víctima blanco y breve | Se deja de ver el mundo en rojo a cada rasguño | S | UI-50 |
| Centrar brújula y panel del fuerte (`grow_horizontal` en dos líneas), anclar el aviso de derribado y no enseñar tooltips por foco con ratón | El HUD deja de estar roto en tres sitios visibles | S | UI-49 |
| `grounded = true` en la figura de selección, creación y personaje | La figura sale en reposo y no en la pose de salto | S | UI-49 |
| Ocultar la línea de ayuda de 14 atajos | La parte baja de la pantalla respira y el HUD puede bajar | S | UI-49 |
| Filtrar los marcadores del mundo: solo el objetivo actual, nombre al acercar la mira | Desaparece la sopa de rótulos bajo la mira | S | UI-54 |
| Limitar las UV del minimapa con fundido a niebla y activar mipmaps | Desaparecen las franjas estiradas y el moteado | S | UI-52 |
| Orientar el modelo hacia la dirección de la esquiva durante `DODGE` | La voltereta va hacia donde se mueve el cuerpo | S | ART-49 |
| Proyección de Terrain3D en pendientes y `uv_scale` de 0,25–0,35 | La roca de las montañas deja de estirarse en vetas | S | ART-55 |
| Hundir rocas y troncos según la pendiente y quitar árboles por encima de 45° | Ni rocas ni árboles clavados como alfileres | S | ART-58 |
| Material propio para la corteza y meter las variantes ya descargadas del Stylized Nature | Adiós a los troncos color salmón; más variedad sin gastar | S | ART-59 |
| Atenuar los remotos a menos de 1,2 m de la cámara | Ningún torso llena media pantalla | S | ART-53 |
| Sombras en espada y escudo (`cast_shadow`) y cambio de arma a mitad del gesto | El arma existe en la sombra y no aparece por arte de magia | S | ART-06 |
| Fuentes Cinzel y Noto Sans (descarga gratuita, OFL) | Todas las pantallas dejan de parecer de sistema | S | UI-02 |

---

## 4. Oleadas de trabajo

El orden pone primero lo que permite demostrar la mejora, después lo barato y luego lo que el usuario citó (animación y mapa), antes que el escenario, que es lo más largo. La oleada 6 puede empezar en cuanto lleguen las compras, siempre después de la 2, porque monta los clips nuevos sobre la capa de brazos y el árbol que deja la 2. Las sesiones son de agente, como en el backlog.

### Oleada 0: banco de capturas (1 sesión)

**Objetivo.** Poder regenerar con una orden las capturas que demuestran cada criterio del listón.

**Tareas.** TEC-50: pasar `build/calidad/scripts/` (`anim_strips.gd`, `online_driver.gd`, los `sc_*.gd` y `compose_strips.py`) a `tools/quality/`, con una orden por área. Repetir las tiras de remotos con un solo bot aislado y guardar en `meta.json` el clip de la capa remota. Añadir las tiras que faltan: golpe recibido en bloqueo, guardias y guardianes. Añadir la grabación de vídeo con sonido (`--write-movie`).

**Capturas que lo demuestran.** El índice regenerado y una tira remota en la que el remoto seguido no queda tapado.

**Estado.** Hecho: `tools/quality/` con `python tools/quality/run.py <área>` (animacion, mapa, interfaz, mundo, combate, video y todo), documentado en el README. Las tiras de remotos salen de un bot completo solo en el servidor (sin PNJ), de los PNJ del fuerte, de los guardias de reino y de los Guardianes de la Puerta; cada una lleva en su `meta.json` el clip que reproduce la capa de animación del remoto, una vista lateral propia y la marca de los fotogramas tapados. Hay tira de golpe recibido en bloqueo y el vídeo con `--write-movie`. El índice resume por tira cuántos fotogramas de acción tienen clip (por ejemplo, `0/9` en un ataque de PNJ que ataca andando).

**Depende del usuario.** Nada.

### Oleada 1: lo barato (4 a 6 sesiones)

**Objetivo.** Quitar los fallos que gritan prototipo en todas las capturas, sin comprar nada.

**Tareas.** UI-49 (arreglos rápidos de la interfaz), UI-50 (señales de daño y colores), ART-47 (clips de los PNJ), ART-48 (bloqueo con escudo), ART-49 (esquiva orientada), ART-53 (cuerpos junto a la cámara), ART-58 (rocas y árboles asentados), la primera mitad de ART-54 (luz sin rellenos, sombras), las UV y los mipmaps del minimapa de UI-52, el filtro de marcadores de UI-54 y las sombras de las armas de ART-06.

**Capturas que lo demuestran.** `interfaz/hud_en_pelea_*` (brújula y panel en x = 960), `interfaz/derribado_aviso.png` entero, `interfaz/inventario_i.png` y `personaje_c.png` sin tooltip, `interfaz/creacion_02_apariencia.png` en reposo, `combate/pelea_b_05.png` sin rojo a pantalla completa, `animacion/lado/npc_*_ataque_*` con clip, `camara_juego/com_bloqueo__mantener.png` con el escudo delante, `lado/com_esquiva_*`, `mapa/minimapa_*` sin franjas y las 10 cámaras de revisión con sombras.

**Estado.** Integrada (3 de noviembre de 2026) la parte barata de UI-49 (puntos 1 a 5), UI-50, ART-47 (clips, sin árbol de zombi), ART-48 (bloqueo con `Idle_Shield_Loop`), ART-49 (esquiva orientada), ART-53, ART-58, ART-54 (solo la luz), ART-55 (UV y proyección), ART-59 (corteza y modelos), UI-52 (UV y niebla), UI-54 (filtro de marcadores) y ART-06 (sombras y cambio de arma a mitad del gesto). La suite completa pasa (2768 pruebas) y el juego completo de capturas se regeneró con `python tools/quality/run.py todo` en `build/calidad_o1/`, con los mismos encuadres que la auditoría. Las parejas antes y después están en `build/comparaciones/`. Comprobado en las capturas: brújula y panel centrados en x = 960, aviso de derribado entero, sin tooltip al abrir el inventario, figura de creación en reposo, golpe de 70 u 90 sin teñir la pantalla, minimapa sin franjas, sombras en las 10 cámaras de revisión (como mucho 1,93 M de primitivas y 1151 llamadas de dibujo, dentro del presupuesto), todos los ataques de PNJ con clip en cada fotograma de acción y el bloqueo con el escudo delante del pecho. Sigue abierto: el aviso de derribado se pisa con la barra de jefe (UI-08 y UI-18), las columnas cortadas del marcador y la elección de reino (UI-49, 6 y 7), el árbol de locomoción de zombi y el perfil visual de los PNJ (ART-52), la segunda mitad de ART-54, ART-55 y ART-59, y toda la oleada 2. Dos observaciones del banco: la tira `rem_bot_*` se colgó una vez al cerrar el cliente (se repitió y salió bien) y `rem_guardian_andar` necesitó una segunda pasada de la fase del Guardián.

**Depende del usuario.** Aprobar la descarga de las fuentes (gratis) si se quieren ya en esta oleada.

### Oleada 2: animación de combate con los clips del repo (6 a 8 sesiones)

**Objetivo.** Que el personaje parezca armado y que cada golpe tenga apoyo y peso, sin esperar a las compras.

**Tareas.** ART-45 (postura armada: reposo de combate con `Idle_Shield_Loop`, capa de brazos durante la locomoción y agarre de dedos), ART-46 (ataques de cuerpo entero con pies plantados, máscara del brazo del escudo y velocidad de piernas sin la estocada), el recorte de tramos de ART-07 (0,7x a 1,5x, prueba automática, carga en bucle), ART-50 (reacción visible a todo golpe), ART-51 (muerte con inercia y derribado distinguible) y ART-52 (perfil visual por tipo de PNJ: Hueco sin escudo, con hueso gris y ojos emisivos; Capitán más grande).

**Capturas que lo demuestran.** Todas las tiras `animacion/*/loc_*` y `com_*` contra los criterios 1 a 5, 7 y 10 de animación; `lado/com_recibir_golpe.png`, `lado/com_muerte_corriendo.png`, `lado/com_derribado.png`; `combate/pelea_b_20.png` con Huecos distinguibles.

**Depende del usuario.** Si algún tramo no cabe en 0,7x a 1,5x con ningún clip, decidir si se tocan los ticks de combate (decisión 7). Cambiar `lunge_speed` afecta al equilibrio de CMB-29.

### Oleada 3: mapa, minimapa y HUD legibles (8 a 10 sesiones)

**Objetivo.** El mapa que pidió el usuario y un HUD con jerarquía.

**Tareas.** UI-51 (horneado del mapa por capas en el estilo elegido, ±256 m para que entren las montañas, 2048 px), UI-52 (minimapa con máscara, niebla en los bordes, iconos fusionados y cono suave), UI-53 (ventana del mapa con topónimos, colocación de rótulos, zoom, arrastre y HUD oculto), UI-54 (brújula con rumbo, marcadores con jerarquía y línea de objetivo), UI-55 (composición del HUD inferior), UI-56 (placas sin solapes y marca de bando), ART-12 (iconos de game-icons.net con fondo y bisel), UI-02 (fuentes y las cinco llamadas a `ThemeDB.fallback_font`), y los ajustes de UI-18 (barra de jefe solo si peleas con él), UI-08 (avisos en cola sobre una banda) y UI-41 (registro de bajas con banda y formato de icono).

**Capturas que lo demuestran.** `mapa/mapa_m_*` y `mapa/imagen_horneada_vado_gris.png` contra los criterios de mapa; `mapa/minimapa_*` en las seis posiciones y tres zooms; `interfaz/hud_en_pelea_*` y `hud_reposo_campamento.png` contra los criterios 1 a 5 de interfaz; `interfaz/recorte_*`.

**Estado del carril de HUD e interfaz (4 de noviembre de 2026).** Hecho: UI-02 (Cinzel y Noto Sans, variables, en `assets/fonts` con sus OFL y anotadas en LICENCIAS.md; IM Fell English SC disponible con `UIFonts.map_label()`; `UIFonts` sustituye a las cinco llamadas a la fuente del motor y una prueba falla si reaparece), ART-12 (los iconos propios de `assets/ui/icons` en la barra de acciones, las pociones, los estados, el cambio de arma y los objetos de arma y poción del inventario; el icono ocupa casi toda la casilla), UI-55 (bloque inferior compacto: casillas a 24 px del borde sobre una banda, vida con marco y trazos cada 10 % y resistencia fina siempre visible pegadas encima, efectos sobre ellas, clic izquierdo y derecho como un ratón dentro de la casilla), UI-56 (placas apiladas sin solaparse, marca de bando de círculo o rombo a menos de 30 m, barra mayor de cerca), UI-18 (barra de jefe solo peleando con él), UI-08 (avisos de guerra en cola, de uno en uno, sobre una banda con emblema y la fuente de títulos; banda, barra de jefe y aviso de derribado a 166, 234 y 300 px, centrados en x = 960), UI-41 (registro de bajas con banda y el icono del arma entre los nombres) y la telegrafía de los PNJ en ámbar (UI-50). Las parejas antes y después están en `build/comparaciones/`. Queda para otros carriles o para después: los marcos 9-slice y el cursor propio de UI-02, el NotificationCenter general de UI-08, los rótulos de lugar de la brújula y el mapa (UI-53 y UI-54) y los números de daño, que siguen naciendo juntos.

**Depende del usuario.** Elegir el estilo del mapa (decisión 3) y aprobar las descargas de fuentes e iconos (gratis; game-icons exige acreditar a cada autor).

**Estado (carril mapa, 4 de noviembre de 2026).** Hechas UI-51 (mapa de pergamino activado y horneado reproducible), UI-52, UI-53 y UI-54 en lo que dice el backlog; faltan de esta oleada UI-55, UI-56, ART-12, UI-02, UI-18, UI-08 y UI-41 (otros carriles). Capturas antes y después con `python tools/quality/run.py mapa`; `sc_mapa` suma el zoom, el arrastre y la línea de objetivo (`mapa_m_08` a `mapa_m_10`, `hud_objetivo_lejos`). Para volver a hornear el mapa tras cambiar el escenario: `godot --headless --path . -s res://tools/map/bake_parchment_map.gd` y `godot --headless --path . --import`.

### Oleada 4: sensación de golpe (5 a 7 sesiones)

**Objetivo.** Que pegar y recibir se oiga y se sienta.

**Tareas.** ART-11 (nodo de audio de combate conectado a `sound_requested`, bancos por material con variaciones y ganchos para los golpes y acciones de los demás, pasos), ART-09 (chispa o polvo en el punto de contacto, estela con `swing_active_changed` y con la fase activa de los remotos, parada de golpe de 50 a 80 ms solo en la animación, golpe bloqueado y parada distinguibles, tensión de la carga, efectos de las tres habilidades de espada y escudo y de la muerte) y los números y el marcador de UI-12.

**Capturas que lo demuestran.** El vídeo con sonido de TEC-50 contra los criterios 1 a 3 y 7 de sensación de combate; `combate/pelea_b_*` y `combate/bloqueo_recibiendo_*` con chispas y estela; `camara_juego/com_habilidad_3_shield_wall.png` con su efecto.

**Estado.** Hecho (4 de noviembre de 2026): ART-11 (`CombatAudio` con bancos por material y variaciones, pasos por superficie desde los pies, barridos sincronizados y también los de los remotos), ART-09 (impacto en el punto de contacto de todo golpe, bloqueo y parada distintos, estela del fuerte rehecha, parada de golpe de 50/80 ms solo en la animación y predicha en local, aura de carga, efectos de las tres habilidades de espada y escudo, polvo de muerte) y UI-12 (números y marcador legibles). La decisión 6 se aplicó como cosmético provisional (el número, el marcador y el DPS siguen esperando al servidor). También las correcciones de la espada propia (hoja base, pomo de lobo, guarda de Askarra). Queda por elegir de oído entre las alternativas de la hoja de escucha (`build/o4_hoja_escucha/`) y juzgar jugando las cifras de la parada de golpe. Las pruebas están en `tests/test_combat_sound_bank.gd` y `tests/test_combat_feel.gd`; el vídeo con sonido sale de `python tools/quality/run.py video --mp4`.

**Depende del usuario.** Aprobar las descargas de Kenney RPG Audio, Impact Sounds y Particle Pack, Still North, 80 CC0 RPG SFX y Binbun Hit FX y Battle FX Free (todo gratis). Decidir si la parada de golpe y el sonido de impacto se predicen en local (decisión 6).

### Oleada 5: el escenario del Vado Gris (12 a 15 sesiones)

**Objetivo.** Que el Vado Gris deje de ser un blockout.

**Tareas.** El cielo y la niebla de ART-54, ART-55 (terreno con normales y altura), ART-56 (relieve con silueta, anillo de montañas lejanas y salida del río cerrada), ART-57 (el fuerte domina: torreón de 20 a 24 m, torres de esquina, colina más alta, empalizada irregular y patio con objetos), ART-59 (vegetación densa, hierba con base del color del terreno), ART-60 (agua del Eldrun), ART-61 (murallas adaptadas al terreno, puerta monumental y cadalsos con ménsulas), ART-14 (viento, LOD, tiendas y calcomanías), ART-15 (estandartes de tela con emblema), ART-62 (identidad de cada mitad) y ART-63 (ruinas y capilla). Al acabar, hornear otra vez el mapa (UI-51) y repetir `verify_vado_gris_routes.gd` y la malla de navegación tras ART-56 y ART-57.

**Capturas que lo demuestran.** Las 10 cámaras de `mundo/camaras_revision/` y las 66 vistas de `mundo/jugador_*` contra los criterios de escenario, con las cifras de `metricas.txt` dentro del presupuesto.

**Depende del usuario.** Decidir la hora y el clima (decisión 4) y si las dos mitades pueden diferenciarse a la vista (decisión 5). Aprobar la descarga de 6 a 8 texturas CC0 y de Sky3D. Compras opcionales: Medieval Village MegaKit Source (torreón, tiendas, piezas de muralla) y Stylized Nature MegaKit Pro (más árboles y rocas).

### Oleada 6: contenido comprado (6 a 8 sesiones)

**Objetivo.** Cerrar lo que con los clips gratuitos no tiene arreglo digno.

**Tareas.** ART-04 (BlendSpace2D con andar de UAL2 Source y trote de UAL1 Pro en 8 direcciones, giros de 90° y entrada y salida del esprint), la esquiva lateral de UAL1 Pro en ART-49, ART-41 (arco con los clips BOW de UAL2 Source y el arco de RPG Weapons Pro), ART-06 (espada y escudos con modelo), los golpes direccionales y la segunda muerte de UAL1 Pro en ART-50 y ART-51, y ART-16 (modelo definitivo de los Huecos: Bestiary si trae esqueleto, si no el plan B).

**Capturas que lo demuestran.** `animacion/*/loc_lateral_*`, `loc_atras`, `com_esquiva_*` y `arc_*` contra los criterios 6, 8 y 9 de animación; `combate/pelea_*` sin cajas ni discos.

**Depende del usuario.** Comprar UAL1 Pro y UAL2 Source; RPG Weapons Pro tras probar la Free; decidir sobre el Bestiary (licencia QAL) y sobre la esquiva hacia atrás (decisión 9).

### Oleada 7: pantallas de flujo y tema (unas 5 sesiones)

**Objetivo.** Que lo primero que se ve no sea un formulario sobre negro.

**Tareas.** ART-21 (logotipo y fondo de título en el motor), UI-22, UI-23 y UI-24 (selección y creación con escenario y tarjetas de reino, ART-20), UI-06 (carga con nombre de zona, imagen y consejo, y menú de juego) y los marcos del tema de UI-02 y ART-12.

**Capturas que lo demuestran.** `interfaz/titulo_*`, `seleccion_personaje_*`, `creacion_*`, `carga_*` y `galeria_ui_*` contra los criterios 6 y 7 de interfaz.

**Depende del usuario.** Decidir los marcos (decisión 10) y aprobar la descarga de Cinzel Decorative para el logotipo.

---

## 5. Compras y descargas recomendadas

Las compras las hace el usuario; las descargas gratuitas necesitan su aprobación y las baja una persona a `../Eldmark-raw/<pack>/` (itch.io no da enlaces directos). Todo se anota en `assets/LICENCIAS.md`. Precios en dólares a 1 de noviembre de 2026, sin comprobar el IVA.

| # | Qué | Precio | Licencia | Qué desbloquea | Elemento |
|---|---|---|---|---|---|
| 1 | Universal Animation Library (UAL1) Pro | 9,99 | CC0 | Trote en 8 direcciones, esquiva izquierda y derecha, golpes en hombros y estómago, segunda muerte, arrastrarse en 4 direcciones, giros de 90° y entrada y salida del esprint. Mismo esqueleto, sin retargeting. El strafe en Pro ya está confirmado por la imagen oficial de la página. | ART-04, ART-49, ART-50, ART-51 |
| 2 | UAL2 Source (no existe Pro) | 14,99 | CC0 | El único andar en 8 direcciones de la familia, los clips de arco (apuntar arriba, al centro y abajo, encordar, disparar), esprint con escudo y zombi en 8 direcciones para los Huecos. | ART-04, ART-41, ART-16 |
| 3 | Cinzel, Noto Sans e IM Fell English SC (google/fonts) | Gratis | OFL | Títulos, cuerpo y rótulos del mapa con ñ y tildes; `UIThemeBuilder` ya las espera. | UI-02, UI-51 |
| 4 | Kenney RPG Audio e Impact Sounds | Gratis | CC0 | Los primeros pasos, barridos e impactos mientras `assets/audio` está vacío. | ART-11 |
| 5 | Still North Weapon Impacts y Weapon Textures, y 80 CC0 RPG SFX | Gratis | CC0 | Choques de arma, desenvainar, arco y voces de criatura para los Huecos. | ART-11 |
| 6 | game-icons.net | Gratis | CC BY 3.0 (hay que acreditar a cada autor) | El primer juego de iconos de acciones, pociones, estados y armas. | ART-12 |
| 7 | Kenney Particle Pack y Binbun Hit FX y Battle FX (Free) | Gratis (las versiones Full, 3,49 cada una, solo si convencen) | CC0 | Chispas, polvo, estelas, impactos y efectos de escudo. | ART-09 |
| 8 | 6 a 8 texturas de Poly Haven o ambientCG (hierba, tierra, grava, roca, barro de orilla, nieve) | Gratis | CC0 | Terreno con normales y altura, procesado y desaturado como pide arte.md. | ART-55 |
| 9 | Sky3D 2.1.0 | Gratis | MIT; las estrellas obligan a acreditar a ESO | Cielo con nubes con forma y sol coherente, solo en el cliente. | ART-54 |
| 10 | RPG Weapons Free, y después Pro | Gratis; Pro 3,99 | CC0 | Espada con punto de agarre (Free); escudos, arco y flechas (Pro). | ART-06, ART-41 |
| 11 | Medieval Village MegaKit Source | 14,99 | CC0 | Colisiones, .blend y proyecto de Godot para modelar el torreón, las tiendas y piezas de muralla con las texturas del kit. | ART-14, ART-57, ART-61, ART-22 |
| 12 | Modular Character Outfits Source | 20,00 | CC0 | Caballero, noble y mago de la misma familia: guardias de reino, Capitán y aspecto por reino. | ART-27, ART-16, ART-03 |
| 13 | Stylized Nature MegaKit Pro | 9,99 | CC0 | Unos 40 árboles, 35 plantas y 27 rocas. Opcional: antes hay que usar los 52 modelos de la Standard ya descargada. | ART-59 |
| 14 | Bestiary Standard (para probar) | Gratis | QAL v1.0, no CC0 | Comprobar si trae un esqueleto para los Huecos. | ART-16 |
| 15 | KayKit Character Animations 1.1 | Gratis | CC0 | Respaldo para una esquiva hacia atrás o el impacto en bloqueo, con riesgo de estilo. | ART-49, ART-48 |
| 16 | Medieval Animation Pack 2.0 (Hadukis), probar antes | 19,99 | Uso en proyectos propios; crédito CC BY 4.0 de 100STYLE | Lo único encontrado con bloqueo andando, esquiva hacia atrás y strafe con arco. Pack muy reciente, sin valoraciones y con otro esqueleto. | ART-48, ART-49 |
| 17 | Terrain3D 1.1.0 (probar en una rama) | Gratis | MIT | Malla de océano con shader de agua, desplazamiento por altura y colorizador por pendiente. Tiene cambios de API respecto a 1.0. | ART-55, ART-60 |

Imprescindible: 1 y 2 (24,98 USD). Con 10, 11 y 12 la compra recomendada sube a 63,96 USD; con el Nature Pro, a 73,95 USD.

Descartados por licencia o procedencia: packs de la Unity Asset Store (prohíben que los archivos sean extraíbles y el uso con IA en tu equipo), MoCap Online (prohíbe toda IA, sin confirmar en la página oficial), la música de AssetSmithy (generada con IA), las texturas del cielo de GDQuest (no comerciales) y Mixamo salvo como último recurso.

---

## 6. Decisiones para el usuario

1. **Compras.** Recomiendo comprar ya UAL1 Pro y UAL2 Source (24,98 USD): sin ellas no hay strafe, esquiva lateral ni arco dignos, y son del mismo esqueleto. RPG Weapons Pro, después de probar la Free; Village Source y Outfits Source, cuando llegue la oleada 5 o la ropa de los guardias.
2. **Descargas gratuitas.** Aprobar la lista de la sección 5 (puestos 3 a 10, 14 y 15). Solo game-icons.net y las estrellas de Sky3D obligan a acreditar.
3. **Estilo del mapa M.** Pergamino oscuro (papel con grano, montañas a tinta, río con lavado gris azulado, calzadas con doble trazo, sellos de árbol) o mapa táctico oscuro (planos de color, curvas de nivel, iconos limpios). Recomiendo el pergamino oscuro para la ventana del mapa, por tono, y las mismas capas con más contraste para el minimapa, donde la legibilidad manda.
4. **Hora y clima del Vado Gris.** Mantener el cielo cubierto con una luz direccional real; tormenta que se abre (nubes rotas, sol bajo del oeste a 25–30° que se cuela entre ellas); o la tormenta oscura de Eldrun. Recomiendo la tormenta que se abre: conserva el gris de la frontera de Eldrun que pide mundo.md, pero da sombras y volumen, que con el cielo cerrado no existen. El sol sigue en el eje oeste, así que la simetría no se toca. Afecta a la decisión pendiente del ciclo de día y noche, que recomendaba luz fija de tormenta.
5. **Asimetría visual entre las dos mitades.** docs/zonas/vado_gris.md solo admite cambiar modelos y materiales. Propongo permitir también terreno, vegetación, cielo y arquitectura distintos mientras la capa de juego (alturas jugables, colisiones, marcadores) siga en espejo. Recomiendo que sí: hoy los dos campamentos son la misma foto con otra bandera.
6. **Parada de golpe y sonido de impacto predichos.** La tabla «Impacto propio» de combate.md solo predice el barrido, la estela y el sonido del arma. Con 100 ms de RTT el golpe confirmado llega ya en la recuperación, fuera de la ventana activa. Recomiendo predecir en local, como cosmético, la parada de golpe y el sonido de impacto con una comprobación contra las posiciones dibujadas; el número y el marcador siguen esperando al servidor.
7. **Ticks de combate frente a clips.** Si algún ataque no casa con ningún tramo de clip entre 0,7x y 1,5x, ¿se tocan sus ticks (sobre todo la anticipación y la recuperación del fuerte), con una nueva pasada de CMB-29? Recomiendo recortar clips primero y tocar ticks solo donde no haya otra salida, empezando por el fuerte.
8. **Alcance del golpe frente a la hoja.** La espada conecta a 3,0 m entre ejes y la hoja dibujada llega a unos 1,6 m. Opciones: espada de 1,1 m más una estela que dibuje hasta 2,2 m; bajar el alcance a 2,2 m; o más avance hacia el objetivo en la anticipación. Recomiendo la primera y no tocar el alcance, que con latencia perdona.
9. **Esquiva hacia atrás.** Ningún pack de la familia trae esquiva hacia atrás. Opciones: voltereta orientada hacia donde se viaja (el cuerpo gira); un paso o salto corto hacia atrás estilo New World con un clip propio o de KayKit; o el `dodge_back` de Hadukis tras probarlo. Recomiendo el paso corto hacia atrás, porque es la esquiva más usada en combate y no obliga a dar la espalda al enemigo.
10. **Marcos de la interfaz.** Conservar el estilo oscuro minimalista y darle un rasgo propio con marcos 9-slice de hierro hechos desde SVG en `tools/ui`, o probar el Fantasy RPG UI Kit de kibbitz (0,24 USD, etiquetado «AI Assisted» en los gráficos). Recomiendo los marcos propios: sin coste, sin dudas de procedencia y aplicables a todas las ventanas a la vez desde `UIThemeBuilder`.
11. **Huecos.** Sigue abierta la decisión del backlog. Recomiendo el perfil rápido de ART-52 ya y bajar la Standard del Bestiary solo para ver si trae un esqueleto, sabiendo que es QAL y que habría que sacarlo si el repo se hace público.
