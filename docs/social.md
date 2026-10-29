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

Las dos que quedaban pendientes se tomaron en la fase 5 ([plataforma.md](plataforma.md) §0,
provisionales, de noche): «ignorar» afecta a **la cuenta**, en silencio, y el servidor filtra también los
canales públicos (sección 10); el registro de chat se guarda **30 días**, susurros incluidos, y **un año** lo
ligado a reportes o sanciones (sección 8), con revisión legal (RGPD) antes de las pruebas públicas.

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

## 8. Registros y retención (decidido en la fase 5: plataforma.md §0 y §11)

| Qué | Qué se guarda | Cuánto |
|---|---|---|
| Chat | Canal, `character_id` del emisor, destinatario o alcance, zona, texto y hora UTC (SOC-15), **incluidos los susurros** | 30 días |
| Fragmentos ligados a un reporte o una sanción | El contexto que se adjunta al reporte (SOC-17) | 1 año |
| Auditoría de comandos de GM | Quién, cuándo, zona, objetivo y argumentos (SOC-14) | 1 año como mínimo |
| Sanciones | Tipo, motivo, autor, caducidad y reportes enlazados | Mientras exista la cuenta |
| Nombres de personajes borrados | Reservados para que nadie los herede | 30 días (SOC-13) |

Los susurros se guardan porque sin ellos no se puede atender un reporte de acoso. Acceso solo a
moderadores con rol, con registro de cada consulta (plataforma.md §9.1: la CLI exige `--actor` y cada
lectura deja su fila en la auditoría). Antes de abrir pruebas públicas hay que pasar la
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
- **Ignorados:** hasta 100. Ignorar afecta a **la cuenta** (decidido en la fase 5, plataforma.md §0),
  en silencio y sin revelar qué otros personajes comparte, porque el acoso con personajes alternativos es
  el caso más frecuente. El servidor descarta del ignorado susurros, invitaciones y correo, y lo quita
  también de los destinatarios de los canales públicos: el cliente no puede ocultarlo, porque no sabe qué
  personajes comparten cuenta (SOC-16, plataforma.md §9.3).
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

## 12. Implementación (fase 4)

Lo que se ha hecho de SOC-03 a SOC-08 en la fase 4, con los formatos de bytes, las decisiones que se
tomaron al implementarlo y lo que queda. Las cifras siguen siendo provisionales (sección 0).

### 12.1 Mensajes de chat (SOC-03)

El protocolo sube a la **versión 5** (`NetProtocol.PROTOCOL_VERSION`). Los tipos van del `0x40` en adelante,
por el canal fiable 3 ([red.md](red.md), sección 2); ningún paquete pasa de 1200 B. Todo en
little-endian y con las cadenas en UTF-8 (sin byte nulo) con su longitud delante, como el resto del
protocolo.

**CHAT_SEND** (`0x40`, C→S): lo que el jugador quiere decir.

| Offset | Tipo | Campo | Notas |
|---|---|---|---|
| 0 | u8 | type | `0x40` |
| 1 | u8 | channel | `ChatChannel.Id`; el 7 (sistema) no lo envía un cliente |
| 2 | u8 | recipient_len | bytes del destinatario (≤ 48; ≤ 24 caracteres); solo en un susurro, y obligatorio en él |
| 3 | u16 | text_len | bytes del texto (≤ 768) |
| 5 | n B | recipient | el nombre tal como lo escribió el jugador |
| 5 + n | m B | text | ≤ 255 caracteres |

**CHAT_MESSAGE** (`0x41`, S→C): un mensaje ya saneado y repartido solo a quien debe verlo.

| Offset | Tipo | Campo | Notas |
|---|---|---|---|
| 0 | u8 | type | `0x41` |
| 1 | u8 | channel | `ChatChannel.Id` |
| 2 | u8 | sender_realm | reino del emisor (0 en el sistema) |
| 3 | u32 | tick | tick del servidor al repartirlo |
| 7 | u8 | sender_len | 0 si y solo si el canal es el del sistema |
| 8 | u8 | recipient_len | solo en un susurro (y obligatorio en él) |
| 9 | u16 | text_len | ≤ 768 |
| 11 | n B | sender | nombre canónico del emisor |
| 11 + n | m B | recipient | nombre canónico del destinatario |
| 11 + n + m | k B | text | ≤ 255 caracteres |

Tamaños máximos: 821 B el CHAT_SEND y 875 B el CHAT_MESSAGE.

Canales (`ChatChannel.Id`, no se reordenan): `0` decir, `1` zona, `2` susurro, `3` grupo, `4` banda, `5`
gremio, `6` reino, `7` sistema, `8` GM. En la fase 4 el servidor reparte decir, zona, susurro, grupo y
sistema; los otros contestan «Ese canal aún no está disponible».

`decode` devuelve `null` (y no registra ningún error del motor) si el tamaño no cuadra con las longitudes,
si el canal no existe, si un cliente manda el del sistema, si un susurro no lleva destinatario o cualquier
otro canal lo lleva, si algún texto no es UTF-8 válido o lleva un byte nulo, si el destinatario pasa de
24 caracteres o el texto de 255 caracteres o 768 B. Un CHAT_MESSAGE además exige emisor en todos los
canales menos el del sistema y destinatario solo en el susurro. Un texto vacío sí se decodifica: es el
servidor quien lo descarta al sanear. `encode` recorta a los límites sin partir ningún carácter.

### 12.2 Enrutado en el servidor de zona (SOC-04)

Todo lo social vive en `scripts/server/social/`; `ZoneServer` solo crea un `SocialService`, le pasa los
mensajes de los tipos `0x40` a `0x4F` (`handle_packet`) y le presta tres funciones (la lista de peers en el
mundo, el envío por el canal fiable y la suma de avisos). El resto es:

| Pieza | Qué hace |
|---|---|
| `SocialService` | Reúne el enrutador del chat y, cuando existan, los grupos; es lo único que conoce `ZoneServer` |
| `ChatRouter` | Sanea, aplica los ritmos y reparte; resultado de cada mensaje en `ChatRouter.Result` |
| `ChatPeerState` | Cubos de fichas, último texto, descartes y contadores de cada peer; cuelga de `ServerPeer.chat` |
| `SocialPeers` | Búsqueda de jugadores en el mundo por nombre (clave de `NameRules`) y por reino |

**Destinatarios.** La lista se construye ya filtrada por reino; nunca se filtra al mostrar.

| Canal | Quién lo recibe |
|---|---|
| Decir | Los del mismo reino a 30 m en 3D del emisor, él incluido |
| Zona | Todos los del mismo reino en el proceso, él incluido |
| Susurro | El destinatario y, como copia, el emisor |
| Grupo | Los miembros de su grupo (que el enrutador vuelve a filtrar por reino) |

**Susurro.** Se busca por la clave de comparación (minúsculas y sin tildes: `peña` encuentra a `Peña`).
Si no hay nadie con ese nombre en el mundo *o* es del otro reino, la respuesta es idéntica: el mensaje del
sistema ««X» no está conectado.», con lo que escribió el jugador y no el nombre canónico del otro lado.
Susurrarse a uno mismo se rechaza («No puedes susurrarte a ti mismo.»).

**Responder (`/r`).** Lo resuelve el cliente: guarda con quién habló la última vez (quien le susurró o a
quien susurró) y manda un susurro a ese nombre. El servidor no guarda «el último interlocutor»: un susurro a
un nombre que ya no está da la respuesta de siempre, y así el protocolo no necesita otro canal.

**Ritmos** (`RateLimiter` por peer, en ticks; no cambian los cubos del transporte, que van antes):

| Cubo | Ritmo | Ráfaga |
|---|---|---|
| Hablar (decir, zona, grupo; banda y gremio cuando existan) | 1/s | 5 |
| Susurro | 1/s | 3 |
| Destinatarios nuevos de susurro | 5/min | 5 |
| Repetición | un texto igual al último aceptado en 600 ticks (10 s) se descarta | |

Un interlocutor reciente (quien te ha susurrado, o a quien has susurrado, en los últimos 5 min) no cuenta
como destinatario nuevo, así que responder a seis desconocidos seguidos no gasta del cubo. Lo descartado,
por ritmo o por repetición:

- avisa al jugador por el canal del sistema, «Hablas demasiado rápido.», como mucho una vez por segundo;
- y uno de cada cinco suma un aviso del peer (`exceso de mensajes de chat`): 250 descartes seguidos en
  10 s llegan a los 50 avisos y expulsan; pulsar Intro de más, no.

**Otros resultados.** Un CHAT_SEND mal formado, con el canal del sistema, o de quien aún no está en el
mundo, suma un aviso. Un texto vacío tras sanear se descarta sin más. Banda, gremio y reino contestan
«Ese canal aún no está disponible.»; GM contesta «Comando desconocido. Escribe /ayuda.» para no revelar que
existe. Un grupo inexistente contesta «No estás en un grupo.».

**Informe.** `write_report` incluye `social.chat` con los mensajes procesados, las copias repartidas y
cuántos acabaron en cada resultado.

**Pruebas.** `test_chat_router` (24, sin red: alcance, filtro por reino, saneado, ritmos, susurros),
`test_chat_loopback` (8, con ENet real: dos bots de un reino y uno del otro; el del otro reino no recibe
ningún CHAT_MESSAGE ni ningún paquete cuyos bytes contengan el texto de los demás, en los cuatro canales y
con el enemigo a 3 m del emisor).

### 12.3 Caja de chat y comandos (SOC-05)

`scripts/client/chat/` (solo cliente); la caja cuelga del `HUD` en red, abajo a la izquierda, por debajo de la
pantalla de muerte. Una vista previa sin servidor para probarla a mano o sacar capturas está en
`scenes/tests/chat_preview.tscn`:

```
godot --path . res://scenes/tests/chat_preview.tscn
xvfb-run -a godot --path . res://scenes/tests/chat_preview.tscn --resolution 1600x900 -- --shots=/ruta/absoluta/build/chat
```

(`--headless` no sirve para las capturas: el renderizador falso no dibuja. Con `xvfb-run`, Mesa llvmpipe sí.)
La captura de demo con mensajes de todos los canales, la línea abierta con un comando a medio escribir y la
pestaña de susurros es [capturas/chat_demo.png](capturas/chat_demo.png).

| Pieza | Qué hace |
|---|---|
| `ChatBox` | Pestañas, registro y línea; abrir, cerrar, enviar, desvanecer |
| `ChatCommandParser` | Decide si la línea es texto o comando y cuál (puro, solo texto) |
| `ChatLog` | Últimas 200 líneas con lo necesario para pintarlas y filtrarlas |
| `ChatStyle` | Color de cada canal y composición de una línea («Ana te susurra: …») |
| `ChatInputHistory` | Historial de lo enviado, 50 líneas, para flecha arriba y abajo |

**Teclas.** Intro (acción `chat_open`, también el Intro del teclado numérico) abre la línea; escribir `/` la
abre ya con la barra (se mira el carácter, no la tecla, así vale en cualquier distribución); Esc la cierra sin
enviar; Intro envía y cierra; flecha arriba y abajo recorren el historial; perder el foco (un clic fuera)
también la cierra. No se abre si otra ventana (ajustes, mapa, pantalla de muerte) tiene el cursor.

**Entrada suspendida.** Mientras la línea está abierta la caja pide el cursor libre a la cámara
(`CameraRig.set_ui_cursor_release`, como las ventanas), con lo que la cámara no gira y los clics no atacan, y
suspende la entrada de juego en `LocalPlayerController.set_input_blocked`: la entrada del dispositivo sale
neutra (sin movimiento ni botones) aunque se teclee W. **Hallazgo:** las ventanas de la interfaz (ajustes F10,
mapa) solo liberaban el cursor, no el movimiento: seguir caminando con W al abrirlas era posible. Para escribir
no vale, así que el bloqueo es un mecanismo nuevo por solicitante (id de instancia), igual que el del cursor;
las ventanas pueden pedirlo cuando se quiera.

**Comandos de la fase 4** (sin distinguir mayúsculas ni tildes; `/ayuda` los lista desde la tabla
`ChatCommandParser.COMMANDS`):

| Comando | Efecto |
|---|---|
| `/d` `/decir` `[texto]` | Decir. Con texto lo envía por ahí sin cambiar el canal activo; sin texto, lo deja activo |
| `/z` `/zona` `[texto]` | Zona (igual) |
| `/g` `/grupo` `[texto]` | Grupo (igual) |
| `/s` `/susurrar` `nombre [texto]` | Susurro. Sin texto deja «susurro a nombre» como canal activo; sin nombre, «Uso: /s nombre [texto]» |
| `/r` `/responder` `[texto]` | Susurro al último interlocutor (copia de un susurro propio o susurro recibido) |
| `/ayuda` `[comando]` | La lista de comandos o el detalle de uno |
| `/invitar` `/salir` `/expulsar` `/lider` | Grupos (se entregan a `ChatBox.party_handler`; ver 12.5) |

Cualquier otro (`/b`, `/gr`, `/reino`, `/gm`, `/amigo`...) contesta «Comando desconocido. Escribe /ayuda.»,
también los de fases futuras: no se avisa de que existen. Los nombres de más de 16 letras no pueden existir
(`NameRules`) y se rechazan en local.

**Qué se ve.** Pestañas Todo, Decir, Zona, Grupo, Susurros y Sistema. Cada canal tiene su color propio (el
sistema, amarillo pálido; los GM, cian) y el nombre del emisor va con el color de su reino. Los NOTICE del
servidor salen en el canal del sistema, igual que los avisos locales (ayuda, errores de un comando).
**El texto de otros jugadores se pinta con `RichTextLabel.add_text`**: nunca se interpreta BBCode, aunque el
servidor lo deje pasar (la prueba pasa `[b]`, `[color]`, `[url]`, `[img]` y `[font_size]` y comprueba que se ve
literal). Cerrada, la caja se desvanece 8 s después del último mensaje (fundido de 2 s) y vuelve con el
siguiente; abierta, no se desvanece.

**Decisiones.** `/r` lo resuelve el cliente (12.2); Intro cierra la línea al enviar (como New World), y para
seguir hablando por un canal está el canal activo; el texto se sanea en el cliente con `ChatText` antes de
enviarlo (el servidor lo vuelve a sanear) y un texto vacío tras sanear no se envía.

**Pendiente del usuario.** Colores de los canales, medidas de la caja (560 x 236, abajo a la izquierda),
tiempos de desvanecimiento y los textos de los avisos son provisionales (ART-12); también si la caja debe
atenuarse con la pantalla de muerte (hoy no) y qué tecla debe abrir el chat en el menú de controles.

### 12.4 Grupos: protocolo y servidor (SOC-06)

Ocho tipos nuevos, del `0x48` al `0x4F`, por el canal fiable 3 (los atiende el `SocialService`, que ya tenía el
rango `0x40`–`0x4F`). `NetProtocol.PARTY_MAX_SIZE` (5) es la constante compartida del tope de miembros; el
resto de reglas están en `PartyRules` (shared).

| Tipo | Mensaje | Sentido | Formato |
|---|---|---|---|
| `0x48` | PARTY_INVITE | C→S | `u8 type, u8 name_len` + nombre (UTF-8, 1 a 48 B y 24 caracteres) |
| `0x49` | PARTY_RESPONSE | C→S | `u8 type, u8 accept (0 o 1), u8 name_len` + nombre de quien invitó |
| `0x4A` | PARTY_LEAVE | C→S | `u8 type` (1 B) |
| `0x4B` | PARTY_KICK | C→S | como PARTY_INVITE |
| `0x4C` | PARTY_LEADER | C→S | como PARTY_INVITE |
| `0x4D` | PARTY_INVITATION | S→C | `u8 type, u8 state (0 nueva, 1 caducada, 2 cancelada), u32 tick, u8 name_len` + nombre canónico; con `state` 0, `tick` es cuándo caduca |
| `0x4E` | PARTY_ROSTER | S→C | `u8 type, u8 count (0 a 5), u8 leader_index` y, por miembro, `u16 net_id, u8 name_len` + nombre (≤ 258 B); `count` 0 = «ya no estás en un grupo» |
| `0x4F` | PARTY_STATUS | S→C | `u8 type, u8 count` y, por miembro, `u16 net_id, u8 health_q, u8 stamina_q, u8 status, f32 x, f32 y, f32 z` (17 B por miembro, ≤ 87 B) |

`health_q` es la vida cuantizada de los snapshots (0 muerto, de 1 a 255 vivo), `stamina_q` la resistencia en 255
pasos y `status` los bits `STATUS_IN_COMBAT`, `STATUS_PROTECTED` y `STATUS_DEAD`. `decode` devuelve `null` si el
tamaño no cuadra, hay más de 5 miembros, un id de red se repite, el líder no está en la lista, un nombre está
vacío o no es UTF-8 válido, un bit de estado es desconocido o una posición no es finita.

**Reglas** (`PartyManager`, en `scripts/server/social/`):

- Un grupo es de 5 como mucho y **solo del mismo reino**. Invitar a un enemigo, o a quien no existe, contesta
  lo mismo que un susurro («no está conectado»), no avisa al invitado y no deja ninguna invitación.
- Cualquier miembro puede invitar; solo el líder expulsa (`/expulsar`) y cede el mando (`/lider`). El primero
  en invitar crea el grupo cuando el invitado acepta, y es su líder.
- Una invitación caduca a los 3600 ticks (60 s); cada jugador puede tener como mucho 5 enviadas a la vez, y
  aceptar una cancela las demás que tuviera el aceptante. Invitar tiene su cubo (1 cada 2 s, ráfaga de 3): lo
  descartado avisa («Invitas demasiado rápido.») y uno de cada cinco suma un aviso del peer.
- Si el líder sale o se desconecta, hereda el mando el siguiente más antiguo; un grupo que se queda en uno se
  disuelve. Aceptar una invitación a un grupo que se llenó entretanto contesta «El grupo está completo.».
- Cada resultado llega al jugador como un mensaje del canal del sistema del chat; la interfaz recibe además
  PARTY_INVITATION y PARTY_ROSTER cuando cambian.
- **Estado a 2 Hz.** Cada 30 ticks (`PartyRules.STATUS_INTERVAL_TICKS`) el servidor manda un PARTY_STATUS a cada
  miembro con la vida, la resistencia, los bits de estado y la posición de todos, estén donde estén: no pasa
  por la política de interés de los snapshots, así que un miembro a 250 m y fuera del radio de interés sigue
  apareciendo (la prueba usa una política de 100 m y un miembro a 210 m).
- Canal de grupo del chat (`/g`): los miembros, esté donde esté cada uno; el enrutador vuelve a filtrar por
  reino a quien le da el `PartyManager`.

**Fuera de alcance de la fase 4** (SOC-22): el grupo no sobrevive a una desconexión ni cruza zonas; el servidor
no guarda nada. Cuando alguien se desconecta, sale del grupo.

**Pruebas.** `test_party_messages` (formatos a mano, corruptos, truncados en cada longitud y fuzz),
`test_party_manager` (sin red: todos los flujos, topes, enemigo, líder heredado, estado a 2 Hz, canal de
grupo) y `test_party_loopback` (con ENet y bots: invitar, aceptar, rechazar, caducar, expulsar, ceder el mando,
salir y desconectarse, la invitación a un enemigo rechazada sin que se entere, y el estado de un miembro fuera
del radio de interés).

### 12.5 Interfaz de grupo (SOC-08)

`scripts/client/party/`; la monta el `HUD` en red a la izquierda de la pantalla, por debajo de la pantalla de
muerte.

| Pieza | Qué hace |
|---|---|
| `PartyState` | Lo que el cliente sabe del grupo: miembros por orden de llegada, líder, estado a 2 Hz e invitaciones (la más antigua a la vista). Lo alimenta `NetClient` y lo expone `NetClient.get_party()` |
| `PartyFrames` y `PartyFrame` | Un marco por miembro: nombre con el color del reino, corona dibujada del líder, vida, resistencia y distancia a partir de 30 m; atenuado si está a más de 100 m, muerto o sin datos todavía |
| `PartyInvitePrompt` | «Ana te invita a su grupo», los segundos que quedan y las teclas reales de aceptar (Y) y rechazar (N) con su glifo; quita lo caducado por tick |
| `PartyHud` | Reúne los dos y traduce `/invitar`, `/salir`, `/expulsar` y `/lider` de la caja de chat en peticiones (`NetClient.send_party_*`) |
| `Nameplates.set_party` | Los miembros del grupo llevan el nombre con el color de grupo (azul del canal) en lugar del de su reino |

Teclas nuevas en `InputBindings`: `party_accept` (Y), `party_decline` (N) y `social_menu` (T); todas
provisionales (pendiente del usuario, igual que las medidas y los colores de los marcos).

La demo del backlog (cuatro bots agrupados con el jugador local) está en `test_party_hud`
(`test_a_party_of_five_shows_the_right_frames`): comprueba nombres, orden, corona única, vida, resistencia,
distancia, atenuado por lejos, por muerte y por falta de datos, y que los marcos siguen a la lista.

### 12.6 Menú social sobre el jugador bajo el punto de mira (SOC-07)

Solo el primer origen de las acciones: la tecla `social_menu` (T) lanza un rayo desde la cámara contra la
cápsula de cada jugador remoto que se está dibujando (como el de las placas de nombre) y toma al más cercano a
lo largo del rayo a **20 m o menos del jugador local** (no de la cámara, que va detrás). Con él se abre una
ventana pequeña (`SocialMenu`, una `UIWindow`: libera el cursor, se maneja con teclado o ratón y Esc la cierra)
con las acciones que aplican:

| Objetivo | Opciones |
|---|---|
| Aliado | Invitar al grupo (si no es ya del grupo y el grupo no está completo) y Susurrar |
| Miembro del grupo, o grupo completo | Solo Susurrar |
| Enemigo | Ninguna: el menú no se abre y el chat avisa («No hay acciones sociales disponibles con ese jugador.») |
| Nadie | No se abre y el chat avisa («Apunta a un jugador (a 20 m o menos) para ver sus acciones.») |

**Invitar** manda PARTY_INVITE; **susurrar** cierra el menú y abre la línea del chat con `/s nombre ` ya escrito.
Cuando existan inspeccionar, añadir amigo, ignorar y reportar, saldrán de `SocialTarget.options_for` (una función
pura) sin mostrar con un enemigo las que no apliquen.

**Pendiente de SOC-07:** el segundo origen, un nombre pulsado en el chat con el cursor libre (los nombres de las
líneas del chat no son todavía pulsables), y las opciones que dependen de fases posteriores.

**Pruebas.** `test_social_menu`: el rayo (20 m desde el jugador y no desde la cámara, PNJ ignorados, el más
cercano gana), las opciones, el menú con un aliado y con un enemigo, y la tecla del HUD.

### 12.7 Decisiones y pendiente de la fase 4

**Decisiones tomadas al implementar** (todas provisionales, revisables con las pruebas reales):

- **Protocolo.** `PROTOCOL_VERSION` sube a 5 con una sola línea de historia («chat y grupos»). Si al fusionar otra
  rama también la sube, la renumera quien fusiona; las pruebas solo exigen `>= 4` y `>= 5` en los sitios que
  dependen de estos mensajes.
- **Un servicio social, no un cambio en cada pieza.** `SocialService` es lo único que ve `ZoneServer` (tipos
  `0x40`–`0x4F`, un paso por tick y la baja de cada jugador); el estado de ritmos de cada peer cuelga de
  `ServerPeer.chat`.
- **`/r` lo resuelve el cliente** y el servidor no guarda «el último interlocutor» (12.2).
- **Mismo texto para el enemigo y para nadie.** Susurrar o invitar a alguien de otro reino responde «no está
  conectado» con lo que escribió el jugador, no gasta del cubo de destinatarios nuevos y no manda nada al otro
  lado.
- **Cualquier miembro puede invitar; solo el líder expulsa y cede el mando.** El tope de 5 pendientes es por
  quien invita y aceptar una invitación cancela las demás del aceptante.
- **Estado de grupo fuera del interés.** Un mensaje propio a 2 Hz a cada miembro con vida, resistencia, estado y
  posición; no pasa por los snapshots. El marco se atenúa a más de 100 m.
- **Intro cierra la línea al enviar**, con canal activo para seguir hablando por un canal.
- **Un grupo no sobrevive a una desconexión** (SOC-22 lo cambiará con los 5 min de gracia).

**Pendiente del usuario** (provisional, a la espera de ART-12 y de probarlo jugando): los colores de cada canal,
las medidas y el desvanecimiento de la caja de chat, el aspecto y la posición de los marcos y del aviso de
invitación, los textos de los avisos y las teclas nuevas (Intro y `/` para el chat, Y y N para responder a una
invitación, T para el menú de jugador). Además, si la caja de chat debe atenuarse con la pantalla de muerte (hoy
no).

**Pendiente de implementar:**

- SOC-07: el menú desde un nombre pulsado en el chat con el cursor libre y las acciones de fases posteriores
  (inspeccionar, amigo, ignorar, reportar).
- SOC-09 y SOC-10: los miembros del grupo en la brújula, el minimapa y el mapa (ya reciben sus posiciones a 2 Hz en
  `PartyState`) y los pings y marcas tácticas.
- SOC-15, SOC-16, SOC-17 y SOC-27: registro persistente, ignorados, reportes y filtro de lenguaje.
- SOC-21 y SOC-22: más canales (reino, comercio, novatos) y grupos entre zonas y con reconexión.
- UI-47: las ventanas de la interfaz tampoco suspenden el movimiento (hallazgo de SOC-05).
