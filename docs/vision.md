# Eldmark: visión del juego

## Concepto

MMORPG 3D de fantasía medieval centrado en la guerra entre tres reinos. Cada
jugador pertenece a un reino. Dentro de su reino progresa con contenido PvE; en
la zona de guerra central lucha contra los otros dos reinos por el control de
fuertes y castillos.

## Los tres reinos

Mundo elegido: **La Corona Rota**. Los tres pueblos fueron un solo reino, Eld,
gobernado desde la ciudadela de Aldcor, donde ardía la Llama de Eld. Al morir el
último rey sin heredero, los tres linajes se disputaron el trono; la Llama
estalló y la tierra se agrietó (la Quiebra). Las Brasas de Eld, esquirlas de la
Llama, siguen ardiendo en las ruinas y dan poder a quien las controla.

| Reino | Inspiración y paisaje | Arquitectura | Colores y emblema | Capital |
|---|---|---|---|---|
| **Vardheim** (norte) | Clanes nórdicos y anglosajones; fiordos, pinares, tundra y glaciares | Casas largas de madera oscura, empalizadas, torres de piedra tosca | Gris acero y azul hielo; lobo blanco | Isenholm |
| **Solmarch** (suroeste) | Teocracia gótica; valles fértiles, viñedos, ríos lentos | Caliza clara, catedrales, torres cónicas de pizarra azul | Blanco y oro; sol radiante partido | Valcorin |
| **Askarra** (sureste) | Señores forjadores y mercaderes; cañones rojos, mesetas y campos volcánicos | Arenisca roja y terracota, cúpulas bajas, ciudades talladas en la roca | Carmesí y bronce; yunque sobre una grieta en llamas | Kassar |

La zona de guerra es **Eldrun**: el cadáver del antiguo reino, con la ciudadela
en ruinas de Aldcor en el centro. Los detalles de zonas, fortalezas y la primera
zona de frontera están en [mundo.md](mundo.md).

Cada reino tiene:

- Una ciudad capital, más ciudades y aldeas
- Varias zonas PvE con niveles progresivos
- Una muralla que rodea todo el reino, con puertas que dan a la zona de guerra

## Zona de guerra central

Mapa compartido por los tres reinos, en el centro del mundo. Cada reino se
conecta con ella a través de las puertas de su muralla.

- **Fuertes**: objetivos pequeños y rápidos de capturar.
- **Castillos**: objetivos grandes, con murallas, puertas y varias líneas de defensa.
- Puertas y muros destructibles, y armas de asedio.
- Defensores PNJ (guardias y un señor de la fortaleza) a los que hay que derrotar para capturarla.
- El reino que captura una fortaleza la conserva hasta que otro se la quite.
- Controlar fortalezas da recompensas a todo el reino (por definir).

## Decisiones técnicas que salen de esta visión

- **Mundo por zonas, no continuo.** Cada zona es un mapa independiente con su
  propio proceso de servidor. Pasar de una a otra (por ejemplo, cruzar la puerta
  de la muralla) implica una carga breve. Es más simple, escala mejor y evita
  los problemas de precisión numérica de los mapas gigantes.
- **Servidor autoritativo** para todo lo que importa en PvP: movimiento, daño y
  estado de las fortalezas. El cliente nunca decide resultados.
- **La zona de guerra es el mapa más exigente**, con muchos jugadores a la vez.
  Cada cliente recibe solo lo que tiene cerca, y el rendimiento se mide desde
  el principio.
- **Combate de acción** (ver sección siguiente): exige predicción en el cliente
  y compensación de latencia en el servidor desde el primer día.

## Combate

Combate de acción en tercera persona, estilo New World:

- Cámara por encima del hombro con punto de mira. El ratón mueve la cámara
  siempre; una tecla libera el cursor para usar la interfaz.
- Golpes ligeros y fuertes, bloqueo y esquiva, gestionados con resistencia (stamina).
- Sin selección de objetivo: los ataques aciertan si el arco del arma o el
  proyectil toca al enemigo.
- Habilidades con tiempo de reutilización, ligadas al arma equipada.

Cómo se hace en red sin que el servidor deje de mandar:

- **Predicción en el cliente**: tu personaje se mueve y ataca al instante en
  tu pantalla; el servidor confirma y corrige si hace falta.
- **Interpolación**: los demás jugadores se muestran ligeramente en el pasado
  para que se muevan suaves.
- **Compensación de latencia**: el servidor guarda un historial corto de dónde
  estaba cada jugador y comprueba los golpes "rebobinando" al momento en que
  el atacante los vio.
- **Validación en el servidor**: resistencia, tiempos de reutilización,
  alcance y línea de visión. El cliente solo envía intenciones.
- **Límite de jugadores por batalla**: el combate de acción es más caro de
  calcular. Hay que medir pronto cuántos jugadores aguanta la zona de guerra
  y diseñar los asedios en función de eso.

## Primer objetivo jugable

Antes de construir los reinos completos: un mapa de frontera pequeño con un
fuerte capturable y dos reinos enfrentándose. Es el corazón del juego; si eso
es divertido, el resto se construye alrededor.

## Hoja de ruta

1. Personaje y cámara: movimiento con WASD y cámara de acción por encima del hombro
2. Red: servidor dedicado, varios jugadores, predicción e interpolación, elección de reino
3. Combate de acción: ataques, bloqueo, esquiva, resistencia, compensación de latencia, muerte y reaparición
4. Primer fuerte capturable en un mapa de frontera pequeño
5. Cuentas, personajes y guardado en base de datos
6. Primer reino: ciudad capital, una zona PvE, muralla y puerta
7. Zona de guerra completa: varios fuertes y castillos, armas de asedio y recompensas
8. Los tres reinos completos y escalado a varios servidores

## Por definir

- Razas jugables de cada reino
- Clases
- Tamaño de los mapas
- Recompensas por dominar la zona de guerra
