# Eldmark: diseño social

Qué se pueden decir y hacer los jugadores entre sí: qué cruza la frontera entre reinos y qué no,
canales y alcances del chat, grupos y bandas, comandos, límites de ritmo, registros y sanciones. Es el
documento de SOC-02: lo implementan SOC-03 a SOC-40 del [backlog](backlog.md) y de él salen las
constantes de [red.md](red.md) (canal fiable 3) y los textos de las normas (`docs/normas.md`, SOC-18).
Para el mundo y los reinos, [mundo.md](mundo.md); para la visión, [vision.md](vision.md).

Todo lo que dice este documento sobre cifras (alcances, ritmos, retenciones, tiempos de sanción) es
**provisional**: se fijó de noche para desbloquear las fases 3 y 4 y se afina con las pruebas reales.
Las reglas de nombres ya están implementadas (SOC-01, `NameRules`) y aquí solo se recuerdan.

## 0. Decisiones

Tomadas de noche, con la recomendación del backlog (provisionales; revisar). Las cuatro salían de las
«Decisiones pendientes» de [backlog.md](backlog.md) y desde ahora están en «Decisiones tomadas».

| Pregunta | Decisión |
|---|---|
| ¿Qué se ve de los jugadores enemigos y qué pueden comunicarse los reinos? | Del enemigo solo se ve el color y el emblema de su bando; su nombre aparece solo al apuntarle con la retícula y siempre en el registro de combate y en la pantalla de muerte. Ni chat, ni susurros, ni grupos entre reinos, y lo filtra el servidor (sección 1) |
| ¿Los gestos se ven entre reinos? | Solo la animación: provocar al enemigo forma parte del PvP y, sin texto, no sirve de canal de comunicación (sección 6) |
| ¿Tamaño máximo del grupo? | 5, coherente con las mazmorras de 3–5 jugadores de mundo.md y con marcos legibles en combate; las batallas grandes se cubren con bandas (sección 3) |
| ¿Chat de voz integrado? | Sin voz hasta después del lanzamiento: es caro y difícil de moderar y Discord ya lo cubre; los pings y marcas (SOC-10) resuelven la táctica dentro del juego (sección 7) |

Quedan **pendientes** (fase 5 en adelante; aquí van como propuesta y los detalles, en las secciones
8 y 9): si «ignorar» afecta a un personaje o a la cuenta (propuesta: a la cuenta, en silencio) y la
retención del registro de chat (propuesta: 30 días, un año para lo ligado a reportes), que además
necesita revisión legal (RGPD) antes de las pruebas públicas.

## 1. Qué cruza entre reinos

Los reinos están en guerra y no hay diplomacia: lo que cruza la frontera es la **imagen** del
enemigo (cómo se ve, cómo se mueve, qué le hace al mundo), nunca su **voz**. El servidor lo impone;
el cliente no puede pedir algo que el servidor no envía.

| Qué | ¿Cruza entre reinos? | Cómo |
|---|---|---|
| Aspecto, posición y animaciones | Sí | Es el juego: se ve al enemigo, sus tabardos y su emblema |
| Color y emblema de bando | Sí | Siempre visibles (también en la placa) |
| Nombre del personaje | Solo al apuntar | La placa del enemigo muestra el nombre mientras la retícula lo señala (unos segundos de gracia al apartarla) y siempre figura en el registro de combate y en la pantalla de muerte («Te ha derrotado X») |
| Gremio, nivel y equipo del enemigo | No | Solo se ven los de un aliado. Inspeccionar a un enemigo (SOC-29) no devuelve equipo, atributos, gremio ni nivel; solo lo que ya se ve y, desde la fase 8, su rango de guerra |
| Vida del enemigo | Sí, en su placa | Al apuntarle o tras dañarlo (decisión de combate.md) |
| Chat (decir, zona y los demás canales) | No | El servidor **nunca** envía a un cliente un texto de otro reino |
| Susurros | No | Susurrar a un enemigo responde «no está conectado», sin revelar que existe |
| Grupos, bandas, gremios, amigos, correo, comercio | No | Solo del mismo reino |
| Gestos | Solo la animación | Sección 6 |
| Pings y marcas tácticas | No | Solo al grupo y la banda propios (SOC-10) |
| Mensajes del sistema | Los que afectan a los dos | «X ha capturado el fuerte» lo ven todos los implicados; el texto lo compone el servidor |
| Nombres | Sí | Un nombre es único en todo el mundo, de cualquier reino (SOC-13, clave de comparación de `NameRules`): identifica a un solo personaje, así que se puede reportar y recordar |

Detalles que se deducen:

- **Zona compartida.** En Eldrun, el Vado Gris y las fronteras hay jugadores de varios reinos en el
  mismo proceso. El canal «zona» y el «decir» solo reparten dentro del reino del emisor; el
  `ChatRouter` filtra por reino al construir la lista de destinatarios, no al mostrar.
- **Los Huecos** (neutrales) no hablan: no tienen chat; sus avisos de PNJ son mensajes del sistema.
- **Ignorar y reportar** funcionan con enemigos (se puede reportar a quien insulta con un gesto o
  con un nombre ofensivo); ignorar a un enemigo no tiene efecto práctico porque no puede escribirte.

## 2. Canales y alcances

Mensaje de chat: hasta **255 caracteres** y 768 B (SOC-03, canal fiable 3, tipos `0x40` en adelante),
con emisor y destinatario por nombre. El texto se sanea en el servidor antes de repartirlo (sección 5).
Sin comando delante, el texto va al **canal activo**, que por defecto es «decir» y cambia al escribir
un comando de canal sin texto (`/g` deja el grupo como activo).

| Canal | Comando | Alcance | Fase |
|---|---|---|---|
| Decir | `/d` · `/decir` | Mismo reino, a 30 m del emisor | 4 (SOC-04) |
| Zona | `/z` · `/zona` | Todo el reino presente en esa zona y esa copia (canal) | 4 |
| Susurro | `/s nombre texto` · `/susurrar` | Un personaje del mismo reino; en la fase 4 dentro del proceso, desde la 6 en cualquier zona (SOC-20) | 4 · 6 |
| Responder | `/r texto` · `/responder` | Al último con quien se habló | 4 |
| Grupo | `/g` · `/grupo` | Los miembros del grupo, estén donde estén | 4 (SOC-06) |
| Banda | `/b` · `/banda` | Los miembros de la banda | 7 (SOC-30) |
| Gremio | `/gr` · `/gremio` | Los miembros del gremio | 6 (SOC-25) |
| Oficiales | `/o` · `/oficiales` | Los oficiales del gremio | 6 |
| Reino | `/reino` | Todo el reino conectado, a ritmo lento | 6 (SOC-21) |
| Comercio | `/comercio` | Todo el reino conectado, a ritmo lento | 6 |
| Novatos | `/novatos` | Todo el reino conectado que se haya unido al canal | 6 |
| Sistema | (solo S→C) | El destinatario; avisos del servidor (`NOTICE`) y del juego | 4 |
| GM | `/gm …` | Roles de moderación (SOC-14); etiqueta visible | 5 |

- **Zona y copias.** Una capital o una zona PvE con varias copias («canales», mundo.md) tiene un canal
  de zona por copia. Eldrun no se divide: allí «zona» es el reino entero dentro de Eldrun.
- **Eldrun y el ruido.** En Eldrun con cientos de jugadores, «zona» sigue siendo por reino; los
  eventos de guerra no pasan por el chat de jugadores sino por el canal de guerra del reino (SOC-32).
- **Nombre del canal de ayuda.** SOC-05 usa `/ayuda` para listar los comandos; el canal de preguntas de
  los jugadores nuevos, que SOC-21 llama «ayuda», se llama **«novatos»** para no chocar.
- **Colores.** Cada canal tiene su color propio y el sistema y los GM, uno inconfundible; los textos de
  otros jugadores se muestran sin interpretar BBCode (SOC-05).

## 3. Grupos y bandas

| Concepto | Valor | Notas |
|---|---|---|
| Tamaño máximo del grupo | **5** (`PARTY_MAX_SIZE`) | Una constante compartida; mazmorras de 3–5 |
| Quién puede agrupar | Solo el mismo reino | La invitación a un enemigo se rechaza en el servidor (SOC-06) |
| Invitación | Caduca a los **60 s**; como mucho 5 pendientes por emisor | Aceptar y rechazar por teclado |
| Líder | El primero; hereda el siguiente más antiguo al salir | Puede expulsar y cambiar de líder |
| Estado compartido | Vida, resistencia y posición de cada miembro a 2 Hz, aunque esté fuera del radio de interés (SOC-06, SOC-09) | |
| Reparto de XP y crédito | Miembros a menos de **100 m** (SOC-23); el botín es personal (PRG-21) | |
| Reconexión | **5 min** de gracia manteniendo el puesto (SOC-22) | |
| Banda de guerra | Hasta **4 grupos (20 jugadores)** en la primera versión; el tope final lo fija TEC-34 con la capacidad medida de Eldrun | Líder y ayudantes, `/banda`, marcos compactos, pings a toda la banda (SOC-30) |
| Bandas abiertas | Cualquiera del reino se une con un clic o al acercarse a la fortaleza que atacan (SOC-31) | Fase 7 |

El grupo es de 5 y no de 6 u 8 porque los marcos de grupo tienen que seguir siendo legibles con la
mirada puesta en un combate de acción sin selección de objetivo; para más gente existe la banda.

## 4. Comandos en español

Los comandos empiezan por `/` y se reconocen sin distinguir mayúsculas ni tildes
(`/Susurrar`, `/susurrar` y `/SUSURRAR` valen igual; la clave de comparación es la de `NameRules`).
Un nombre de jugador como argumento tampoco distingue mayúsculas ni tildes y no lleva comillas (los
nombres no tienen espacios). Un comando desconocido contesta «Comando desconocido. Escribe /ayuda.»
y un jugador sin rol que escribe `/gm` recibe lo mismo: no se revela que existe.

| Grupo | Comandos |
|---|---|
| Canales | `/d` `/z` `/s` `/r` `/g` `/b` `/gr` `/o` `/reino` `/comercio` `/novatos` (y sus nombres largos de la sección 2) |
| Grupo | `/invitar nombre` · `/salir` · `/expulsar nombre` · `/lider nombre` |
| Gremio | `/ginvitar nombre` · `/gsalir` · `/gexpulsar nombre` · `/gascender nombre` |
| Social | `/amigo nombre` · `/ignorar nombre` · `/designorar nombre` · `/ausente [texto]` · `/ocupado` |
| Gestos | `/saludar` · `/reverencia` · `/burla` · `/animar` · `/sentarse` · `/señalar` (SOC-11) |
| Ayuda y quejas | `/ayuda [comando]` · `/reportar nombre` · `/peticion texto` (SOC-17, SOC-36) |
| Moderación | `/gm …` (solo con rol; SOC-14) |

Todo comando que cambia un estado (invitar, salir, reportar) pasa por el servidor, que valida y
contesta con un mensaje del sistema; el cliente nunca da por hecho el resultado. Los que dependen de
un jugador concreto sin escribir su nombre (invitar, susurrar, inspeccionar, ignorar, reportar) salen
también del **menú social** sobre el jugador bajo el punto de mira, a 20 m como mucho (SOC-07).

## 5. Límites de ritmo y saneado

Se aplican en el servidor, por peer, con el `RateLimiter` de cubo de fichas que ya existe
([red.md](red.md), sección 12). Cuando algo se descarta, el jugador recibe un aviso del sistema
(«Hablas demasiado rápido») y, para que pulsar Intro de más no expulse a nadie, solo **uno de cada
cinco** mensajes descartados cuenta como aviso del peer para la expulsión (50 avisos en 600 ticks:
red.md sección 12), de modo que la inundación sostenida sí expulsa.

| Acción | Ritmo | Ráfaga | Notas |
|---|---|---|---|
| Decir, zona, grupo, banda, gremio | 1 mensaje/s | 5 | Un mensaje idéntico al anterior en los últimos 10 s se descarta |
| Susurro | 1 mensaje/s | 3 | Y como mucho 5 destinatarios nuevos por minuto (SOC-38) |
| Reino | 1 mensaje cada 10 s | 1 | SOC-21 |
| Comercio | 1 mensaje cada 15 s | 1 | |
| Novatos | 1 mensaje cada 5 s | 2 | |
| Invitaciones (grupo, gremio, amigo) | 1 cada 2 s | 3 | Y como mucho 5 pendientes |
| Gestos | 1 cada 2 s | 2 | Moverse, atacar o recibir daño lo cancela |
| Pings | 1 cada 2 s | 3 | A 300 m como mucho; duran 6 s (SOC-10) |
| Inspeccionar | 1 cada 2 s | 3 | A 20 m, solo aliados (SOC-29) |
| Reportes | 1 por objetivo cada 10 min | 10 por hora | SOC-17 |
| Peticiones a un GM | 1 abierta a la vez | | SOC-36 |

Antes de repartir un mensaje, el servidor lo **sanea**: quita los caracteres de control, la
secuencia BBCode (`[…]`), los espacios repetidos y los de los extremos, y rechaza el texto vacío o que
pase de 255 caracteres. En los canales públicos bloquea además los enlaces (SOC-27). El cliente tiene un
filtro de lenguaje opcional, activo por defecto, con listas editables en español e inglés. Un personaje
con menos de 2 h jugadas no puede usar `/reino`, `/comercio` ni adjuntos de correo (SOC-38).

## 6. Gestos

Un gesto es una animación con o sin texto («Ana saluda»). Se replica a todos los que ven al
personaje, también al enemigo: la burla es parte del PvP. **El texto del gesto solo lo recibe el
propio reino y a 30 m**; el enemigo ve la animación sin palabras y no puede usarla para comunicarse.
Moverse, atacar, recibir daño o morir cancela el gesto. Los gestos nunca dan ventaja mecánica.

## 7. Voz y pings

No hay chat de voz integrado: es caro, se modera mal y Discord ya cubre esa necesidad (SOC-40 deja
una integración opcional de presencia). La coordinación táctica dentro del juego la cubren los
**pings** (atacar, defender, peligro, reunirse) y hasta 4 marcas persistentes del líder, que ve el
grupo o la banda en el mundo, la brújula y el minimapa (SOC-10), con límite de ritmo y sin que los
vea el enemigo.

## 8. Registros y retención (propuesta; decisión pendiente para la fase 5)

| Qué | Qué se guarda | Cuánto |
|---|---|---|
| Chat | Canal, `character_id` del emisor, destinatario o alcance, zona, texto y hora UTC (SOC-15), **incluidos los susurros** | 30 días |
| Fragmentos ligados a un reporte o una sanción | El contexto que se adjunta al reporte (SOC-17) | 1 año |
| Auditoría de comandos de GM | Quién, cuándo, zona, objetivo y argumentos (SOC-14) | 1 año como mínimo |
| Sanciones | Tipo, motivo, autor, caducidad y reportes enlazados | Mientras exista la cuenta |
| Nombres de personajes borrados | Reservados para que nadie los herede | 30 días (SOC-13) |

Los susurros se guardan porque sin ellos no se puede atender un reporte de acoso. Acceso solo a
moderadores con rol, con registro de cada consulta. Antes de abrir pruebas públicas hay que pasar la
retención y el consentimiento por una revisión legal (RGPD); esas cifras pueden cambiar entonces.

## 9. Sanciones y normas

Las normas completas y la pantalla que se acepta al crear la cuenta son de SOC-18
(`docs/normas.md`). La escala es **progresiva** y siempre lleva motivo, autor, caducidad y los
reportes enlazados:

| Paso | Sanción | Efecto |
|---|---|---|
| 1 | Aviso | Mensaje del sistema y anotación en la cuenta; sin efecto mecánico |
| 2 | Silencio | Sin acceso a ningún canal de chat salvo los de sistema; 1 h, 24 h o 7 días |
| 3 | Suspensión temporal | La cuenta no puede entrar; 1, 3, 7 o 30 días, con el motivo y la fecha de fin en el rechazo |
| 4 | Expulsión permanente | Cuenta cerrada; sin devolución |
| Aparte | Renombrado forzado | Nombre ofensivo o suplantación: se obliga a elegir otro al entrar |

| Falta | Primera vez | Reincidencia |
|---|---|---|
| Lenguaje ofensivo, spam | Aviso o silencio de 1 h | Silencio de 24 h o 7 días |
| Acoso, amenazas, discriminación | Silencio de 7 días o suspensión de 3 días | Suspensión de 30 días o expulsión |
| Nombre ofensivo o suplantación | Renombrado forzado | Suspensión de 7 días |
| Trampas, bots, explotar errores | Suspensión de 7 a 30 días | Expulsión |
| Compraventa de cuentas, objetos u oro por dinero real | Suspensión de 30 días | Expulsión |

Una sanción grave puede saltarse pasos; la reincidencia cuenta dentro de 90 días. Toda sanción tiene
una vía de apelación (una petición, atendida por un moderador distinto en 7 días). Un silencio
automático provisional tras varios reportes de jugadores distintos queda pendiente de revisión
humana (SOC-38).

## 10. Ignorados, amigos y gremios

- **Amigos:** hasta 100, del mismo reino, por solicitud aceptada (SOC-24).
- **Ignorados:** hasta 100. Propuesta pendiente de decisión: ignorar afecta a **la cuenta**, en
  silencio y sin revelar qué otros personajes comparte, porque el acoso con personajes alternativos es
  el caso más frecuente. El servidor descarta del ignorado susurros, invitaciones y correo; el cliente
  oculta sus mensajes en los canales públicos (SOC-16).
- **Gremios:** del mismo reino, con 5 rangos y permisos por bits; el nombre del gremio de un aliado
  aparece en su placa, el del enemigo no (SOC-25, sección 1).

## 11. Dónde se implementa

| Fase | Pieza |
|---|---|
| 4 | Protocolo de chat (SOC-03), `ChatRouter` en el servidor de zona con decir, zona, susurro y sistema (SOC-04), ventana de chat y comandos (SOC-05), grupos (SOC-06 a SOC-09), menú social (SOC-07), pings (SOC-10) |
| 5 | Nombres únicos (SOC-13), roles de GM y auditoría (SOC-14), registro persistente (SOC-15), ignorados, reportes y sanciones (SOC-16 a SOC-18) |
| 6 | Gestos (SOC-11), susurros entre zonas y canales de reino, comercio y novatos (SOC-20, SOC-21), grupos entre zonas (SOC-22), amigos, gremios, filtro, correo e inspección (SOC-24 a SOC-29) |
| 7 | Bandas de guerra (SOC-30), buscar grupo (SOC-31), canal de guerra (SOC-32), heráldica y fortalezas de gremio (SOC-33 a SOC-35) |
| 8 | Peticiones a GM, panel de moderación, antispam y escalado (SOC-36 a SOC-39) |

Quien implemente una pieza debe respetar el filtro por reino de la sección 1 en el servidor, aunque el
cliente «ya no muestre» lo que no debe: la prueba de aceptación de SOC-04 es que un cliente de otro
reino no recibe ningún paquete con el texto, no que no lo pinte.
