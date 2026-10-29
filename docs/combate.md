# Eldmark · Fase 3: diseño del combate de acción

Diseño del paso 3 de la [hoja de ruta](vision.md#hoja-de-ruta): ataques ligeros y fuertes,
bloqueo, esquiva, resistencia, compensación de latencia, muerte y reaparición, en red y con el
servidor como autoridad. Se apoya en la red de la fase 2 ([red.md](red.md), sobre todo §6.7, §8,
§10 y §15).

Primer y único kit de la fase: **espada y escudo**. Las demás armas y las habilidades con
reutilización llegan en la fase 4 (CMB-19 y siguientes) sobre las mismas piezas.

Revisado con dos lentes (netcode y diseño) antes de implementarlo; la versión 2 incorpora sus
arreglos (entradas sustituidas, estado completo, orden del tick, rebobinado del tick actual,
precedencias, contratos entre paquetes).

---

## 0. Decisiones

Tomadas de las recomendaciones de [backlog.md](backlog.md#decisiones-pendientes) (provisionales,
tomadas de noche; están en «Decisiones tomadas» del backlog):

| Pregunta | Decisión |
|---|---|
| Clases | Sin clases: el rol lo dan las armas equipadas. |
| Armas equipadas | Dos ranuras con cambio rápido (CMB-24, fase 4). En la fase 3 solo hay espada y escudo. |
| Números | **Enteros** para vida, resistencia y daño. |
| Duraciones en los datos | **Segundos** en los `.tres`, convertidos a ticks al cargar con `roundi(s · 60)`. Al `sim_hash` entra el catálogo ya convertido. |
| Críticos | **Posicionales, sin azar**: cuerpo a cuerpo por la espalda (más de 120° respecto al yaw del cuerpo de la víctima) hace ×1,5. |
| Fuego amigo | No. Los golpes atraviesan a los aliados. |
| Estado defensivo con rebobinado | Protege si el defensor se defendía en el tick rebobinado o en el actual, con las precisiones de §4.3. |
| Parada | Ventana de 6 ticks (100 ms) al pulsar bloquear, solo contra cuerpo a cuerpo y con enfriamiento. |
| Esprint y resistencia | El esprint no gasta resistencia. |
| Impacto propio | Mixto: barrido, estela y sonido del arma al predecir; marcador, chispas y número al confirmar (ENTITY_EVENT). Los números nunca se predicen. |
| Vida del enemigo | En su placa al apuntarle o tras dañarlo en los últimos 5 s; barra de jefe para capitanes (fase 4). |
| PNJ humanoides | `PlayerCharacter` con entrada sintética (como `BotBrain`). |
| Colisión entre personajes | Ninguna, como en la fase 2. |
| Reaparición | 10 s fijos en la fase 3, con botón; oleadas cada 10 s en el Vado Gris con GUE-14 (fase 4). |
| Entereza acumulada | No en la fase 3: solo `hyper_armor` por ataque y una cadena de controles con inmunidad. |

---

## 1. Qué se predice y qué decide el servidor

| Dato | Dónde vive | Predicho | Viaja en |
|---|---|---|---|
| Acción, fase, tick de inicio, combo, pulsación, carga, búfer, dirección de esquiva | `CombatState` dentro de `PlayerState` | Sí | estado propio del snapshot |
| Resistencia y agotamiento | `CombatState` | Sí | estado propio |
| Controles (tambaleo, aturdimiento, empuje), rotura de guardia, muerte | `CombatState`, **impuestos por el servidor** | No: el cliente los adopta al reconciliar | estado propio |
| Gasto de resistencia de un golpe bloqueado | `CombatState`, impuesto por el servidor | No | estado propio |
| Vida, «en combate», protección, cadena de controles | `Combatant` en el servidor | No | bloque extra del snapshot (propia) y `health_q` del registro (ajenos) |
| Golpes, daño, críticos, bajas | `CombatResolver` en el servidor | No | ENTITY_EVENT |

Regla de red.md §6.7: todo lo que decide el servidor y cambia la simulación entra en
`PlayerState`, así que la reconciliación lo absorbe. La vida no cambia la simulación (salvo al
morir, que es una acción) y por eso no está en `PlayerState`.

---

## 2. Catálogo de combate (CMB-02)

`scripts/shared/combat/`, datos en `data/combat/` (`.tres` en texto). Todos los tiempos son
**segundos desde el inicio de la acción** salvo que se diga otra cosa; al convertir, cada ventana
es un intervalo de ticks `[desde, hasta)` contado desde `action_tick`.

```gdscript
class_name HitShape extends Resource
@export var range_m: float = 2.6
@export var inner_m: float = 0.0
@export var angle_deg: float = 100.0
@export var height_min: float = 0.2          # relativas a los pies del atacante
@export var height_max: float = 2.0

class_name AttackDefinition extends Resource
@export var id: StringName
@export var heavy: bool = false
@export var windup_s: float                  # anticipación (en el fuerte: tras soltar)
@export var active_s: float                  # golpe activo: se prueba la forma en cada tick
@export var recovery_s: float
@export var combo_window_s: float            # últimos s de la recuperación: enlaza el siguiente ligero
@export var cancel_to_dodge_from_s: float    # desde el inicio de la acción
@export var stamina_cost: int                # 0–1000
@export var lunge_speed: float               # m/s hacia delante en anticipación y golpe activo
@export var turn_rate: float                 # rad/s de giro hacia la cámara en anticipación y activo
@export var move_speed_scale: float          # fracción de run_speed permitida
@export var shape: HitShape
@export var base_damage: int
@export var damage_type: int                 # DamageFormula.DamageType
@export var hyper_armor: bool                # en el golpe activo, inmune a tambaleo y empuje
@export var stagger_s: float                 # tambaleo que causa (0 = ninguno)
@export var knockback_speed: float           # empuje que causa (m/s, 0 = ninguno)
@export var charge_min_s: float              # solo fuertes, contados desde la pulsación
@export var charge_max_s: float
@export var charge_damage_scale: float       # multiplicador a carga máxima (lineal desde ×1 en charge_min)
@export var charge_move_scale: float
@export var charge_turn_rate: float

class_name DodgeDefinition extends Resource
@export var duration_s: float
@export var invulnerable_from_s: float
@export var invulnerable_to_s: float
@export var distance_m: float
@export var speed_curve: Curve               # forma del perfil; se normaliza a distance_m
@export var stamina_cost: int
@export var cancel_to_attack_from_s: float

class_name WeaponDefinition extends Resource
@export var id: StringName
@export var light_combo: Array[AttackDefinition]   # 3 golpes
@export var heavy_attack: AttackDefinition
@export var block_angle_deg: float                 # cono frontal total
@export var block_mitigation: float                # 1,0 = para todo el daño físico frontal
@export var block_move_scale: float
@export var block_turn_rate: float
@export var block_stamina_per_damage: float
@export var dodge: DodgeDefinition

class_name CombatRules extends Resource            # data/combat/combat_rules.tres
# Predichas (entran en prediction_hash):
@export var stamina_max: int = 1000
@export var stamina_regen_per_tick: int = 3          # 180/s
@export var stamina_regen_delay_s: float = 0.6
@export var exhausted_regen_per_tick: int = 1        # 60/s
@export var exhausted_exit_threshold: int = 300
@export var hold_to_heavy_ticks: int = 8
@export var input_buffer_ticks: int = 8
@export var parry_window_ticks: int = 6
@export var parry_cooldown_ticks: int = 30
# Solo del servidor (no entran):
@export var health_max: int = 1000
@export var health_regen_per_s: int = 20             # fuera de combate
@export var in_combat_s: float = 10.0
@export var respawn_s: float = 10.0
@export var respawn_protection_s: float = 3.0
@export var cc_chain_window_s: float = 3.0
@export var cc_immunity_s: float = 2.0
@export var fall_damage_threshold: float = 15.0      # m/s
@export var fall_damage_per_mps: int = 70
@export var parry_stagger_s: float = 0.6
@export var guard_break_stun_s: float = 1.0
@export var backstab_angle_deg: float = 120.0
@export var crit_multiplier: float = 1.5
```

**`CombatCatalog`** (RefCounted, estático, carga perezosa): lee `data/combat/`, asigna IDs u16
por tipo (ataques y armas tienen espacios separados, **1..n por orden alfabético de `id`, 0 =
ninguno**; un `id` repetido es un error), convierte a ticks y hornea la curva de la esquiva en una
tabla de velocidades por tick (`PlayerState.to_f32`) que suma `distance_m`. Expone
`attack(id) -> AttackTicks`, `weapon(id) -> WeaponTicks`, `rules() -> CombatRules` y
`prediction_hash() -> int`: SHA-256 de todo lo predicho (ventanas, movimiento, costes, curva
horneada, cancelaciones, bloqueo, campos predichos de `CombatRules`). Entra en
`NetProtocol.compute_sim_hash`. Daño, mitigación, críticos, controles, vida y reaparición no
entran.

Valores iniciales de espada y escudo (`data/combat/sword_shield.tres`, se ajustan en CMB-29):

| Ataque | Anticip. | Activo | Recup. | Ventana combo | A esquiva desde | Resist. | Daño | Avance | Movim. | Control |
|---|---|---|---|---|---|---|---|---|---|---|
| Ligero 1 | 0,20 | 0,10 | 0,30 | 0,15 | 0,40 | 0 | 90 | 1,5 m/s | ×0,3 | — |
| Ligero 2 | 0,18 | 0,10 | 0,30 | 0,15 | 0,38 | 0 | 90 | 1,5 | ×0,3 | — |
| Ligero 3 | 0,25 | 0,10 | 0,45 | — | 0,50 | 0 | 130 | 2,0 | ×0,2 | tambaleo 0,3 s |
| Fuerte (carga 0,35–1,2 s desde la pulsación, ×1–×1,7) | 0,40 tras soltar | 0,12 | 0,55 | — | 0,70 | 150 | 180 | 2,5 | ×0,2 (carga ×0,4) | tambaleo 0,5 s, empuje 4 m/s, `hyper_armor` |

Forma de todos: alcance 2,6 m, 100°, alturas 0,2–2,0 m; giro 6 rad/s (carga 4). Esquiva: 0,45 s,
invulnerable [0,05, 0,30), 4,5 m, curva de salida rápida, 300 de resistencia, a ataque desde 0,30
s. Bloqueo: cono de 120°, para el 100 % del daño físico frontal, movimiento ×0,5, giro 8 rad/s,
1,0 de resistencia por punto absorbido.

Los ligeros (12 ticks de anticipación) no se pueden reaccionar en red con 150 ms; la parada y la
esquiva reactivas se diseñan contra los fuertes, cuya anticipación tras soltar (0,40 s) se ve.

---

## 3. Máquina de acciones (CMB-03, CMB-04, CMB-06, CMB-13, CMB-14)

### 3.1 `CombatState` (en `PlayerState`, entra en `encode()`)

`PlayerState` gana `var combat: CombatState`; `PlayerCharacter` también, y `get_state()`/
`set_state()` lo copian. `PlayerState.ENCODED_SIZE` pasa de 35 a **69 B**:

| Offset | Tipo | Campo | Qué es |
|---|---|---|---|
| 35 | u8 | `action` | `Action`: 0 NONE, 1 LIGHT, 2 HEAVY, 3 CHARGE, 4 BLOCK, 5 DODGE, 6 STAGGER, 7 STUN, 8 DEAD |
| 36 | u16 | `action_id` | ataque del catálogo (0 si no es un ataque) |
| 38 | u32 | `action_tick` | tick en que empezó la acción |
| 42 | u8 | `combo_step` | 0–2: siguiente ligero del combo |
| 43 | u8 | `primary_held` | ticks reales que PRIMARY lleva pulsado desde su flanco (0 = sin pulsación viva; satura en 255) |
| 44 | u8 | `charge_ticks` | ticks de carga al lanzar el fuerte (lo lee el servidor para el daño) |
| 45 | u8 | `buffered` | bits 0–1 tipo (0 nada, 1 PRIMARY, 2 DODGE), bits 2–5 ticks que le quedan |
| 46 | u16 | `stamina` | 0–`stamina_max` |
| 48 | u32 | `stamina_regen_tick` | primer tick en que vuelve a regenerar |
| 52 | u8 | `combat_flags` | bit0 agotado, bit1 último intento sin resistencia (para la interfaz), bit2 resistencia infinita (comando), bits 3–5 botones DODGE/BLOCK/PRIMARY pulsados en el tick anterior, bit6 ligero de la pulsación viva (§11) |
| 53 | u16 | `action_dir` | yaw cuantizado (como `look_yaw`) de la esquiva |
| 55 | u32 | `cc_until_tick` | fin del control actual (exclusivo) |
| 59 | s16 × 2 | `knockback` | empuje horizontal (x, z) en cm/s |
| 63 | u32 | `parry_ready_tick` | primer tick en que puede abrirse otra ventana de parada |
| 67 | u16 | `weapon_id` | arma equipada |

`PROTOCOL_VERSION` pasa a 2 (y a 3 con la revisión de la fase 3, que cambia la simulación predicha:
bit 6 de `combat_flags`, carga cancelada tras el silencio del cliente, combo reiniciado al caducar
el enlace y movimiento aéreo de los controles). Los ticks absolutos hacen que el estado se restaure
sin ambigüedad.

**Fase 4.** La versión 5 de `CombatState` (76 B, `PlayerState` de 111 B) añade al final la otra arma,
las reutilizaciones, los consumibles y los efectos de movimiento, y `buffered` pasa a bits 0–3 tipo
y 4–7 ticks: [habilidades.md 3.1](habilidades.md#31-combatstate-v5).

### 3.2 Entradas sustituidas (cierra la nota de red.md §8.2)

`PlayerInput.SUBSTITUTED = 1 << 15`, fuera de `VALID_BUTTONS` (el cliente no puede ponerlo: el
servidor aplica la máscara al decodificar). Lo ponen `InputQueue.take()` y
`ClientPrediction._input_or_substitute()` en la entrada sustituta, que sigue repitiendo todos los
botones. Con ese bit, la máquina de acciones:

- no suma a `primary_held`, no convierte un ligero en carga ni lanza el fuerte al llegar a la
  carga máxima (la carga se congela hasta la siguiente entrada real; una sustituida solo
  *retrasa* la conversión, no la pierde: el bit `FLAG_LIGHT_OF_PRESS` recuerda de qué pulsación
  es el ligero, §11). La carga congelada dura como mucho `input_buffer_ticks` tras la carga
  máxima: pasado ese margen con el cliente aún callado, **se cancela** (a NONE, sin lanzar ni
  gastar resistencia), de modo que un cliente que deja de enviar con la conexión viva no puede
  guardar un fuerte al máximo para soltarlo al instante con la primera entrada real;
- no abre ventanas de parada;
- calcula los flancos sin el bit (`prev_buttons` nunca lo guarda).

Así ninguna pérdida inventa un fuerte ni una parada. Quien deja de enviar entradas con BLOCK
pulsado sigue bloqueando mientras no se le expulse: con la conexión viva no hay límite de
inactividad (el timeout de ENet solo salta si el par deja de responder a nivel de ENet, no si
deja de mandar `INPUT_BATCH`). No da ventaja sobre un jugador honrado, que también puede
bloquear sin límite (gasta resistencia al recibir), y se acepta.

### 3.3 Reglas por tick

`ActionMachine.step()` corre al principio de `simulate()`, antes del movimiento, con
`t = input.tick`. Orden fijo:

1. **Fin de acciones.** Si la acción tiene duración y `t ≥ fin`, vuelve a NONE (o encadena el
   ligero enlazado, o el contenido del búfer). STAGGER/STUN terminan en `cc_until_tick`.
2. **Resistencia.** Si `t ≥ stamina_regen_tick` y la acción no es BLOCK, CHARGE ni DODGE, regenera
   (`exhausted_regen` si está agotado). El agotamiento se activa al llegar a 0 y se quita al
   superar `exhausted_exit_threshold`. Todo gasto (también el que impone el servidor) pone
   `stamina_regen_tick = t + retardo`.
3. **Entradas** (flancos sin el bit SUBSTITUTED; prioridad DODGE > PRIMARY > BLOCK):
   - **DODGE** (flanco): si la acción actual lo permite (NONE, BLOCK, LIGHT/HEAVY desde
     `cancel_to_dodge_from`, CHARGE), en el suelo, con `stamina ≥ coste` y sin agotamiento: DODGE
     con `action_dir` = dirección de `move` relativa a `look_yaw` (hacia atrás sin entrada). Si no
     se puede por la acción, va al búfer; si es por resistencia, se pone el bit1.
   - **PRIMARY** (flanco): `primary_held = 1`. Si se puede atacar (NONE, BLOCK, DODGE desde
     `cancel_to_attack_from`) y está en el suelo: empieza el ligero `combo_step` con
     `action_tick = t`. Si hay un ligero en curso y `t` está en su ventana de combo (o hasta
     `input_buffer_ticks` antes): se enlaza el siguiente, que empieza al acabar la recuperación.
     En cualquier otro caso, al búfer.
   - **PRIMARY mantenido** (real): `primary_held += 1`. Si llega a `hold_to_heavy_ticks` y la
     acción es un ligero en anticipación empezado por esta pulsación (o enlazado por ella): si hay
     resistencia ≥ coste del fuerte y no está agotado, pasa a CHARGE con el mismo `action_tick`
     (aún no ha golpeado: 12 ticks de anticipación > 8); si no, sigue el ligero y se pone el bit1.
   - **PRIMARY soltado**: `primary_held = 0`. En CHARGE: si la carga (ticks desde `action_tick`)
     es menor que `charge_min`, se lanza al llegar a `charge_min`; si no, se lanza ya.
     **Lanzar** = HEAVY con `action_tick = t`, `charge_ticks` = carga, gasto de resistencia.
   - **CHARGE** que llega a `charge_max` con entrada real: se lanza.
   - **BLOCK** (a nivel): desde NONE (o al acabar una acción con BLOCK pulsado) entra en BLOCK,
     sin agotamiento. Si además es un **flanco real** y `t ≥ parry_ready_tick`, abre una ventana
     de parada `[t, t + parry_window)` y pone `parry_ready_tick = t + parry_cooldown`. Soltar BLOCK
     sale de BLOCK.
   - **Búfer**: guarda la última pulsación de PRIMARY o DODGE no ejecutada durante
     `input_buffer_ticks`; se ejecuta en el primer tick en que se pueda, con prioridad sobre las
     entradas nuevas de ese tick. `primary_held` sigue contando mientras tanto.
   - Tras el ligero 3, `combo_step` vuelve a 0. Si se acaba una recuperación sin enlace, también.
     Y también si el enlace no llegó a ejecutarse: un ligero que acaba en el aire con una pulsación
     de enlace pendiente la deja como pulsación guardada normal, y al caducar (sin ligero en curso)
     el combo vuelve a empezar; si se aterriza dentro de los `input_buffer_ticks`, el enlace se
     ejecuta como siempre.
4. **Movimiento permitido** (lo usa `simulate()`):

| Acción | Velocidad horizontal objetivo | Giro | Salto | Esprint |
|---|---|---|---|---|
| NONE | la de siempre | el de siempre | sí | sí |
| LIGHT/HEAVY anticipación y activo | `forward · lunge + wish · run_speed · move_scale` | hacia `look_yaw` a `turn_rate` aunque esté quieto; en el primer tick, el yaw salta a `look_yaw` | no | no |
| LIGHT/HEAVY recuperación | `wish · run_speed · move_scale` | ninguno | no | no |
| CHARGE | `wish · run_speed · charge_move_scale` | hacia `look_yaw` a `charge_turn_rate`; en el primer tick de la acción (ligero que se convierte), salta | no | no |
| BLOCK | `wish · run_speed · block_move_scale` | hacia `look_yaw` a `block_turn_rate` | sí (sale de BLOCK) | no |
| DODGE | **impuesta**: `dir(action_dir) · curva[t − action_tick]`, sin aceleración | ninguno (el cuerpo conserva su yaw) | no | no |
| STAGGER | **impuesta**: `knockback · (fin − t) / (fin − inicio)` si hay empuje; si no, frena | ninguno | no | no |
| STUN | frena | ninguno | no | no |
| DEAD | frena; la gravedad sigue | ninguno | no | no |

La gravedad y `move_and_slide` se aplican siempre, así que la esquiva y el empuje respetan muros
y bloqueos del puente. Las acciones con movimiento escalado a 0 (STUN, DEAD y STAGGER sin empuje)
frenan también en el aire: la regla de `simulate()` que conserva el impulso aéreo mientras se
empuja hacia delante no se aplica con ellas, así que el stick no dirige a un cadáver, un aturdido
ni un tambaleado en pleno salto. Ni ataques, ni esquiva, ni bloqueo en el aire: un PRIMARY o DODGE en el
aire va al búfer.

### 3.4 Lo que impone el servidor

API de `ActionMachine` (estática, sobre `CombatState`), siempre seguida de redondeo por
`PlayerState.decode(encode())`. Todas borran el búfer, `primary_held` y `combo_step`:

- `impose_stagger(c, t, until, knockback: Vector2)`, `impose_stun(c, t, until)`: STAGGER o STUN
  con `action_tick = t`, `cc_until_tick = until`.
- `impose_death(c, t)`: DEAD.
- `reset_for_respawn(c, t, rules)`: todo a los valores iniciales (resistencia llena) salvo el
  arma.
- `drain_stamina(c, amount, t)`: resta, pone el retardo y, si llega a 0, el agotamiento.

Consultas (las usan el servidor y el animador): `phase(c, t)` (0 anticipación o carga, 1 activo,
2 recuperación, 3 sin fases), `is_attack_active(c, t)`, `is_blocking(c, t)`,
`is_parry_window(c, t)`, `is_invulnerable(c, t)`, `defense_flags(c, t) -> int` (bits de
`StateHistory`) y `action_byte(c, t) -> int`: bits 0–3 la acción, 4–5 la fase, 6–7 el paso del
combo del ligero en curso. El byte que viaja en el registro lo arma `ActionWire`
(`scripts/shared/net/action_wire.gd`, uno por entidad en el `Combatant`): es el de `action_byte`
y, en la esquiva, el tambaleo y el aturdimiento (que no tienen combo), los bits 6–7 llevan un
contador de reinicio que sube en 1 (módulo 4) con cada acción nueva. Sin él, dos esquivas
encadenadas por el búfer (la segunda sale en el tick en que acaba la primera, sin ningún tick en
NONE) o dos controles seguidos dan el mismo byte y el remoto no reinicia el clip.

---

## 4. Golpes en el servidor (CMB-05, CMB-07, CMB-09, TEC-14)

### 4.1 Geometría (`scripts/shared/combat/hit_shapes.gd`)

Matemática pura, sin cuerpos de física:

- **Sector anular con altura** contra cápsula vertical (radio 0,4, altura 1,8 desde los pies):
  distancia horizontal al eje en `[inner − r, range + r]`, ángulo respecto al yaw del atacante
  dentro de `angle/2 + asin(r / d)`, y solapamiento de `[height_min, height_max]` con
  `[0, 1,8]` sobre los pies de cada uno.
- **Segmento contra cápsula** (proyectiles, fase 4) y **caja orientada** (estructuras, fase 4).
- **Línea de visión**: rayo contra la capa del mundo (1) desde el pecho del atacante (1,4 m) al
  centro de la cápsula de la víctima (0,9 m).

### 4.2 Orden del tick del servidor

Sustituye el comentario «Fase 3: acciones validadas contra StateHistory» de red.md §8.1:

1. Simular a **todas** las entidades con cuerpo (jugadores, falsos y PNJ) por `net_id`.
2. **Congelar**: guardar, para cada entidad, su estado tras `s` (posición, yaw, `defense_flags`,
   acción). Es la «muestra del tick actual».
3. **Resolver** todos los ataques activos en `s` contra lo congelado y `StateHistory` (§4.3), sin
   tocar ningún estado: todos los golpes de un tick son simultáneos.
4. **Aplicar** los resultados por `net_id` del atacante y luego del objetivo: daño, gasto de
   resistencia del bloqueo, controles, muertes; después, volúmenes letales, caída, muertes por
   y < −100 y reapariciones vencidas o pedidas.
5. Altas, `_record_history(s)` (ya con lo impuesto), snapshots y eventos.

Así un intercambio de golpes del mismo tick resuelve los dos, y el snapshot de `s` ya lleva lo
impuesto: el cliente reconcilia desde `s`.

### 4.3 Rebobinado (`CombatResolver`, `scripts/server/combat_resolver.gd`)

Para cada atacante en golpe activo en `s`:

1. **Parámetros.** `InputQueue.get_rewind_params(s) -> Vector2i(view_offset_q, lead)`: los de la
   entrada real de `s` o, si se sustituyó, los de la última real. Los jugadores falsos y los PNJ
   usan `view_tick = s`. **Se leen una sola vez por golpe**, en su primer tick activo: el
   rebobinado (`rewind = s₀ − view_tick₀`) queda fijado en el `Combatant` junto a `track_swing`, y
   en los demás ticks activos `view_tick = s − rewind` (avanza con el tick). Antes cada tick activo
   leía su propio `view_offset_q` y un cliente modificado barría la ventana (0, 5, 10... 24) o se
   quitaba las defensas retroactivas con un 0 en los ticks que le convenían.
2. **Tope.** `allowed` de red.md §10, con una `lead` que el cliente no escoge a su antojo: la de la
   entrada del golpe, pero como mucho la **habitual** del cliente más 3
   (`InputQueue.get_typical_lead(s)`, la mediana de las antelaciones de primera copia de las
   entradas reales de los últimos 60 ticks; 3 es la dispersión de un honrado con jitter) y nunca más
   de 8 (`_MAX_LEAD_CREDIT`: lo que mantiene un cliente honrado con `TickSync`, margen objetivo ≤ 4
   más la holgura de su ventana). Un honrado no pierde nada (su vista es `rtt + antelación de la
   entrada + interpolación`, así que con la antelación de esa entrada nunca queda por encima del
   tope), pero un cliente que adelanta solo las entradas de su golpe 14 ticks ya no sube el tope de
   12 a 24 con RTT de LAN. Si `view_offset_q / 16 > allowed + 1`, el golpe **no se prueba**: suma a
   la puntuación de sospecha y va al `--combat-log`. Si no, `view_tick = clamp(s − view_offset_q /
   16, s − allowed, s)`. **Mínimo para la defensa:** las defensas retroactivas (invulnerable,
   parada, bloqueo; paso 6) miran al menos `max(0, rtt_floor + 4 − 2)` ticks atrás
   (`ServerPeer.rtt_floor_ticks` es el RTT de ENet, que el cliente no controla, y 4 el retardo de
   interpolación mínimo), aunque el golpe pida menos: un honrado nunca ve el mundo con menos
   retraso, y pedir 0 ya no libra de ellas. La geometría (paso 3) sigue en el `view_tick` pedido.
   *Límites conocidos:* un tramposo todavía escoge el rebobinado, una vez por golpe, entre ese
   mínimo y el tope; y con todas sus entradas adelantadas (hasta el máximo de 8) y `interp_delay_q`
   al máximo llega al tope global de 24 (un honrado con el mismo RTT, a unos 10-16): el servidor no
   puede comprobar la interpolación declarada, así que el tope de 24 ticks (400 ms) es la cota
   del daño posible.
3. **Muestras.** El atacante, siempre en su estado congelado de `s`. Cada candidato: si
   `view_tick ≤ s − 1`, `StateHistory.sample(id, view_tick)`; si está entre `s − 1` y `s`,
   interpolación entre la pista de `s − 1` y lo congelado de `s`; si es `s`, lo congelado. Una
   muestra nula (apareció después) descarta al candidato.
4. **Candidatos**: hostiles según `FactionRules`, vivos ahora (`Combatant.health > 0`) y sin el
   bit «muerto» en `view_tick`, sin protección de reaparición en `s`, y sin zona segura de por
   medio en `s` (§5: ni la víctima dentro de la zona segura de su propio reino, ni el atacante
   dentro de la de su propio reino). Un objetivo ya golpeado (o bloqueado o parado) por esta
   acción no se vuelve a probar.
5. **Forma** con la muestra de la víctima y **línea de visión** contra el mundo actual.
6. **Defensa**, por este orden de precedencia:
   - **Invulnerable** en algún tick de `[floor(defensa), s]` (`defensa` = el `view_tick` o, si es
     posterior, el mínimo para la defensa del paso 2): sin efecto y **no** consume el golpe (puede
     entrar en un tick activo posterior).
   - **Parada**: ventana de parada en la muestra de `view_tick` o en la de `s`, con el atacante
     dentro del cono frontal del defensor en esa muestra (yaw del cuerpo), solo cuerpo a cuerpo:
     sin daño, tambaleo de `parry_stagger_s` al atacante. Consume el golpe.
   - **Bloqueo**: bloqueando en la muestra de `view_tick` o en la de `s`, con el cono: mitigación y
     gasto de resistencia. Consume el golpe.
   - La muestra de `view_tick` solo cuenta para parada y bloqueo si el defensor **no** ha bajado el
     escudo después: su acción en `s` es distinta de BLOCK y NONE y tiene `action_tick > view_tick`
     (LIGHT, HEAVY, CHARGE y DODGE propios, pero también STAGGER, STUN o DEAD impuestos). Quien
     suelta el escudo para atacar, o a quien se lo quitan con un control, deja de estar protegido;
     quien lo suelta sin más (NONE conserva el `action_tick` del bloqueo) conserva lo que el
     atacante veía. Sin esto, un aturdido que bloqueaba hace 20 ticks «bloqueaba» el ligero de un
     segundo atacante con rebobinado: con 0 de resistencia eso es una rotura de guardia que le
     alargaba el aturdimiento.
   - Si nada aplica: **impacto**.

`StateHistory` añade a sus banderas por tick: bit 3 bloqueando, bit 4 ventana de parada, bit 5
invulnerable, bit 6 muerto (`ActionMachine.defense_flags`).

### 4.4 Daño (`scripts/shared/combat/damage_formula.gd`)

```
bruto   = base × carga × crítico
mitig.  = bruto × block_mitigation          (solo si se bloquea)
final   = roundi((bruto − mitig.) × 1000 / (1000 + armadura)),  mínimo 1 si queda algo
```

- `carga = lerp(1, charge_damage_scale, (charge_ticks − charge_min) / (charge_max − charge_min))`
  en los fuertes; 1 en los ligeros.
- Crítico ×1,5 si el atacante está a más de 120° del yaw del cuerpo de la víctima (de su
  muestra).
- Tipos de daño cortante, perforante, contundente, elemental, con resistencias por tipo (0 en la
  fase 3). Armadura 0 en la fase 3.
- **Bloqueo**: el defensor gasta `roundi(mitig. × block_stamina_per_damage)`. Si no le alcanza, se
  absorbe solo la parte proporcional, el resto pasa como daño y hay **rotura de guardia**
  (aturdimiento de `guard_break_stun_s`).
- **Controles del golpe**: tambaleo y empuje del ataque, salvo si la víctima está en golpe activo
  de un ataque con `hyper_armor` (la parada y la rotura de guardia sí entran siempre). Cadena:
  `Combatant.cc_chain` cuenta los controles en `cc_chain_window_s`; el tercero no entra y abre
  `cc_immunity_s` de inmunidad. CHARGE se puede interrumpir.

### 4.5 Antitrampas (TEC-14)

El cliente solo manda botones; el servidor comprueba fases, resistencia y ritmo con su propia
simulación, así que un cliente modificado no ataca más rápido ni sin resistencia. Las entradas
sustituidas no inventan nada (§3.2): ni un fuerte cargado que se guarda en silencio, ni una parada.
Se vigila el rebobinado (§4.3, paso 2: fijado por golpe, con antelación estable y un mínimo para la
defensa) con una **puntuación de sospecha** por peer (golpes fuera de tope,
ratio de acierto anómalo) que en la fase 3 solo se registra. Modos nuevos del bot tramposo:
`rewind` (view_offset_q de 40 ticks), `reach` (ataca desde 5 m) y `rate` (PRIMARY cada tick):
ninguno debe hacer daño de más.

---

## 5. Vida, eventos, muerte y reaparición (CMB-10, CMB-15, CMB-41, GUE-03, GUE-05)

- **`Combatant`** (servidor, uno por entidad que recibe daño): vida y máxima, `in_combat_until`,
  `protected_until`, `death_tick`, `respawn_tick`, `cc_chain`, `DamageLedger` (900 ticks),
  `last_enemy_hit` (para acreditar caídas), y si es inmortal (maniquí).
- **Regeneración de vida** fuera de combate. «En combate» dura 10 s tras dar o recibir daño.
- **Muerte**: vida 0 → `impose_death`, `death_tick`, `respawn_tick = s + respawn_s`, una sola
  DEATH (víctima, autor, ataque) y un KILL (asesino, ataque, asistentes con ≥ 10 % del daño en 900
  ticks; no cuentan aliados ni autolesiones).
- **Reaparición**: desde `respawn_tick` el cliente puede pedirla con **RESPAWN_REQUEST**
  (`point_index`); a los 30 s sin pedirla, automática en el primer punto. Puntos: nodos del grupo
  `respawn_points` (o, si la zona no tiene, `spawn_points`) con metadato `realm`, en el orden de la
  escena, que el cliente conoce porque carga la misma zona; en la fase 4 el índice pasa a ser el de la
  lista **estática** de todos los puntos y se añade la condición (el fuerte propio, sin atacar:
  [fuerte.md 5](fuerte.md#5-avisos-reaparición-salida-y-atascado)). Al reaparecer: teletransporte (contador), `reset_for_respawn`, vida llena,
  `protected_until = s + 3 s` (se pierde al empezar un ataque), evento RESPAWN.
- **Caída**: `PlayerCharacter.last_landing_speed = −velocity.y` medido **antes** de
  `move_and_slide()` en el tick en que `grounded` pasa a true (0 en los demás). Daño
  `(v − 15) × 70` por encima de 15 m/s: saltar desde la pasarela de 3 m (14,0 m/s) no hace daño; la
  torre de 12 m (23 m/s) quita 560. Se acredita al último enemigo que golpeó en 10 s.
- **Volúmenes letales**: `Area3D` del grupo `lethal_volumes` (máscara de la capa 2) que el
  servidor comprueba cada tick; matan.
- **Bajo y = −100**: muerte y el cuerpo se lleva a su punto de aparición (contador) con velocidad
  0 mientras está DEAD; `_check_motion` no actúa sobre entidades DEAD; una sola DEATH por
  `death_tick`.
- **`FactionRules`** (`scripts/shared/war/faction_rules.gd`):
  `static func can_damage(attacker_realm: int, victim_realm: int, zone_id: StringName) -> bool`:
  sin fuego amigo, Huecos (código 0 con bando neutral) hostiles a todos, reinos enemigos solo en
  zonas RVR. `Zones.get_pvp_mode(zone_id) -> PvpMode` (SAFE o RVR; Vado Gris y test_world RVR).
  **Zonas seguras**: `Marker3D` del grupo `safe_areas` con metadatos `realm` y `radius` (24 m) en
  cada campamento del Vado Gris. **Solo protege a su reino**: un jugador de ese reino dentro no
  recibe daño ni lo hace (no se puede atacar a salvo desde dentro); un intruso enemigo dentro sí
  es dañable, por los Guardianes de la Puerta de la fase 4 (PNJ con `ignores_safe_area`).

---

## 6. Protocolo (TEC-13): `PROTOCOL_VERSION = 2`

- **`PlayerState`** de 69 B (§3.1).
- **ENTITY_SPAWN ajeno**: su `PlayerState` va con el `CombatState` neutro del arma (resistencia llena,
  sin banderas, búfer, controles ni parada), salvo la acción en curso (`action`, y `action_id` y
  `action_tick` si no es NONE) y el arma, y con `prev_buttons` y los contadores de salto a 0: lo demás es
  estado privado del enemigo (§1: la resistencia viaja en el «estado propio») y no debe volcarse a quien
  entra en la zona. El SPAWN propio lo lleva entero. El formato (69 B) no cambia.
- **Bloque extra propio**, en **todo** snapshot con estado propio (bit 3 de `flags` ⇔ bit 0;
  `decode` rechaza bit 3 sin bit 0), tras el estado propio: `u16 health`, `u16 max_health`, `u8
  status` (bit0 en combate, bit1 protegido, bit2 muerto), `u32 respawn_tick` (0 si vivo). 9 B.
- **Registro de entidad de 21 B**: `u8 health_q` al final, `0` si muerto y si no
  `clampi((health · 255 + max − 1) / max, 1, 255)`. `EntityRecord.encode_character(bytes, offset,
  net_id, character, teleport_counter, action, health_q)`. Cabecera con estado propio y bloque:
  13 + 69 + 9 + 1 = 92 B; con una sección (2 B), ⌊(1200 − 94) / 21⌋ = **52 registros**.
- **ENTITY_EVENT** (`0x23`, canal 3), formato reservado en red.md §5.6: `u8 type`, `u16 net_id`
  (la entidad a la que se ata: víctima o entidad que reaparece), `u32 tick`, `u8 event`, `u8 len`,
  datos:
  - `1 HIT`: `u16 attacker`, `u16 amount`, `u8 damage_type`, `u8 flags` (bit0 crítico, bit1
    bloqueado, bit2 parado, bit3 rotura de guardia, bit4 mortal), `u16 attack_id`. 17 B.
  - `2 DEATH`: `u16 killer` (0 = entorno), `u16 attack_id`. 13 B.
  - `3 KILL`: `u16 killer`, `u16 attack_id`, `u8 n`, `n × u16` asistentes. 14 + 2n B.
  - `4 RESPAWN`: `u8 point`. 10 B.
  - **Destinatarios**: los dueños del atacante y de la víctima (y de asesino y asistentes en
    KILL) y quien tenga relevante a cualquiera de ellos.
  - **Temporización**: un evento es **propio** si el jugador local es atacante, víctima, asesino
    o asistente; su marcador, número y HUD se aplican al llegar. La reacción visual de un remoto
    (destello, sacudida, animación) se aplica cuando su `render_tick` alcanza `tick`. Eso vale
    también cuando el remoto es la víctima (o el muerto) de un evento propio: `CombatFeedback`
    aplica al llegar lo que es del jugador local y guarda el destello, la placa de vida
    (`entity_damaged`) y el sonido de muerte o de baja del remoto en su propia cola hasta ese
    `render_tick`.
- **RESPAWN_REQUEST** (`0x05`, C→S, canal 3): `u8 type`, `u8 point_index`. Fuera de plazo o con un
  índice inválido cuenta un aviso.
- **DEBUG_COMMAND** (TEC-19) con ids fijos en `NetProtocol`: 1 `teleport` (sin cambios), 2 `heal`,
  3 `kill`, 4 `stamina_inf` (bit2 de `combat_flags`: la máquina no gasta), 5 `set_weapon`, 6
  `spawn_dummy`. Solo con `--debug-commands`. `announce`, `kick` y `shutdown <s>` son **solo de
  consola** (stdin del servidor) hasta los roles de GM (TEC-23). `CommandRegistry` (servidor)
  comprueba al registrar que cada comando de red tiene su id en la tabla; cada uso queda en el log.
- `sim_hash` incluye `CombatCatalog.prediction_hash()`.
- **Ancho de banda**: bajada = (94 + n · 21 + 40) B × 30/s (10 visibles: ~10,3 KB/s; tope desde 52
  visibles: ~37 KB/s) más los ENTITY_EVENT (~27 B por destinatario y golpe). Hay que actualizar
  red.md §5.5, §5.6, §9.3, §14 y `test_snapshot_builder`.

---

## 7. PNJ y maniquí (MUN-02, CMB-11)

- Tipo `NPC` en `NetEntity` con el registro de 21 B. Su cuerpo es un `PlayerCharacter` simulado
  por el servidor en el mismo bucle que los jugadores (por `net_id`) con entradas de un `NpcBrain`
  que entran en su `InputQueue` como las de los jugadores falsos; se graba en `StateHistory`.
- **Maniquí de entrenamiento**: NPC fijo, **inmortal** (la vida no baja de 1, no emite DEATH ni
  KILL) que se cura del todo a los 5 s sin daño, con modos quieto, bloqueando y girando (comando
  `spawn_dummy`). Uno en `test_world` y uno junto a cada campamento del Vado Gris (marcadores del
  grupo `dummy_points`).
- **PNJ de guerra (F4, MUN-07, MUN-08)**: las armas de los PNJ son `data/combat/npc_*.tres` (Hueco, guardia del reino,
  Capitán, Guardián) y se piden por nombre. Entran en el catálogo, así que, por el orden alfabético, los `npc_*` van antes que
  los `sword_*` y los números cambian (`sword_shield` 1 a 5, `sword_heavy` 1 a 9...) y también el `sim_hash`; las pruebas buscan
  por `id`. `AttackDefinition.unblockable` (solo servidor, no entra en el hash de predicción, `AttackTicks.unblockable`) hace que
  el `CombatResolver` dé IMPACT aunque el defensor pare o bloquee; la esquiva invulnerable sigue valiendo. `Combatant.ignores_safe_area`
  deja atacar en la zona segura de su propio reino al Guardián de la Puerta. El cerebro (`HfsmBrain`) y el aviso TELEGRAPH están
  en `docs/fuerte.md` 8.3.
- **Registro de combate** (`--combat-log=<csv>`): `tick, atacante, objetivo, ataque, view_tick,
  rebobinado, resultado, daño`.
- **Medidor de DPS** en el panel F3: suma los `amount` de los HIT propios en una ventana de 30 s.

---

## 8. Cliente (UI-07, UI-10, UI-12, UI-13, UI-14, ART-06, ART-08, ART-09)

- **Detección de acciones sin señales**: `CombatFeedback` y `CharacterAnimator` comparan, tras
  cada tick de física, `(action, action_id, action_tick)` del estado mostrado con el último que
  vieron, y lanzan o cortan barrido, estela y clip desde ahí. Ninguna señal de combate dentro de
  `simulate()`: las repeticiones no duplican ni pierden efectos. Una corrección que solo mueve el
  inicio de la misma acción hasta `input_buffer_ticks` ticks (el servidor sustituyó la entrada del
  flanco y esquivó un tick después) no es una acción nueva para `CombatFeedback`: no repite el
  aviso ni el sonido. Dos esquivas encadenadas (27 ticks de diferencia) sí son dos.
- **`CombatFeedback`**: recibe los ENTITY_EVENT ya temporizados y reparte marcador de impacto y
  número de daño (UI-12), destello y sacudida (ART-09), ganchos de sonido (ART-11) y el medidor de
  DPS.
- **HUD** (UI-10): vida (del bloque extra) y resistencia (del estado local) abajo al centro, tramo
  fantasma, parpadeo con el bit1, arcos de dirección del daño.
- **Placas** (UI-07, UI-13): nombre y color de reino; barra de vida desde `health_q` para enemigos
  bajo la retícula o dañados en los últimos 5 s, y para aliados siempre.
- **Muerte** (UI-14): HUD atenuado, quién te derrotó y con qué, cuenta atrás hasta `respawn_tick`,
  botón Reaparecer y lista de puntos de su reino.
- **Animación** (ART-08): capa de combate sobre la locomoción, leyendo `action_byte` del estado
  local o del registro de los remotos; clips de UAL1/UAL2 (`Sword_Attack`, `Roll`, `Hit_Chest`,
  `Death01`...) reescalados a cada fase. El ajuste fino queda para el usuario.
- **Armas** (ART-06): mallas provisionales (caja para la espada, cilindro aplanado para el escudo)
  en `BoneAttachment3D` de las manos hasta que lleguen los modelos.

---

## 9. Paquetes y contratos

### 9.1 Paquetes

| Paquete | Contenido | Depende de |
|---|---|---|
| **K1a · simulación** | `CombatState`, `HitShape`, `AttackDefinition`, `DodgeDefinition`, `WeaponDefinition`, `CombatRules`, `CombatCatalog`, `data/combat/*.tres`; `PlayerState`/`PlayerCharacter` con `combat`, `ActionMachine` (§3) y su llamada en `simulate()`; `last_landing_speed`; bit SUBSTITUTED en `PlayerInput`, `InputQueue.take()` y `ClientPrediction`; `sim_hash` con el catálogo | fase 2 |
| **K1b · reglas puras** | `hit_shapes.gd`, `damage_formula.gd`, `FactionRules`, `Zones.get_pvp_mode` | fase 2 |
| **K2 · protocolo** | `PROTOCOL_VERSION = 2`, registro de 21 B, bloque extra, ENTITY_EVENT, RESPAWN_REQUEST, ids de comandos, red.md actualizado | fase 2 (usa `PlayerState.encode()` sea cual sea su tamaño) |
| **K3 · servidor** | `Combatant`, orden del tick (§4.2), `CombatResolver` (§4.3), `InputQueue.get_rewind_params`, banderas en `StateHistory`, muerte, reaparición y RESPAWN_REQUEST, caída, volúmenes letales, zonas seguras, NPC y maniquí, `CommandRegistry` y consola, `--combat-log`, puntuación de sospecha | K1a, K1b, K2 |
| **K4 · cliente** | eventos por `render_tick`, `CombatFeedback`, HUD de vida y resistencia, marcador y números, placas con vida, pantalla de muerte con reaparición, capa de animación, armas provisionales, DPS en F3 | K1a, K2 |
| **K5 · integración** | loopback con NetSim rtt=150 (≥ 95 % de acierto contra un objetivo que se mueve en lateral; 0 impactos con `view_offset_q` de 30 ticks contra un objetivo quieto), bot tramposo `rewind`/`reach`/`rate`, `BotBrain` de combate, reconciliación con rtt=120 y 5 % de pérdida, carga con refriegas de 32, 64 y 128 bots, límite de jugadores anotado en red.md, demo del sandbox con el combo | K3, K4 |

K1a, K1b y K2 van en paralelo; después K3 y K4 en paralelo; al final K5.

Fuera de K1–K5, en otro carril de la misma fase: ART-10 (infraestructura de audio, sin sonidos
hasta que lleguen los packs), UI-02, UI-09, UI-16, SOC-02, TEC-12. Quedan para el usuario: ART-04
(compra de UAL1 Pro), ART-06 y ART-07 definitivos (modelos y recorte de clips), ART-09 y ART-11
con assets reales. `AbilityDefinition` pasa a CMB-19 (fase 4).

### 9.2 Contratos

```gdscript
# scripts/shared/combat/combat_state.gd
class_name CombatState extends RefCounted
enum Action { NONE, LIGHT, HEAVY, CHARGE, BLOCK, DODGE, STAGGER, STUN, DEAD }
const ENCODED_SIZE: int = 34
var action: int; var action_id: int; var action_tick: int; var combo_step: int
var primary_held: int; var charge_ticks: int; var buffered: int; var stamina: int
var stamina_regen_tick: int; var combat_flags: int; var action_dir: int; var cc_until_tick: int
var knockback: Vector2; var parry_ready_tick: int; var weapon_id: int
func encode_into(bytes: PackedByteArray, offset: int) -> void
static func decode_from(bytes: PackedByteArray, offset: int) -> CombatState
func duplicate_state() -> CombatState
static func initial(rules: CombatRules, weapon_id: int) -> CombatState

# scripts/shared/combat/action_machine.gd
class_name ActionMachine extends RefCounted
class Output:
	var move_scale: float = 1.0; var lunge_speed: float = 0.0
	var turn_rate: float = -1.0           # -1 = giro normal de simulate()
	var snap_yaw: bool = false            # el yaw salta a look_yaw este tick
	var forced_velocity: bool = false; var velocity: Vector3 = Vector3.ZERO
	var allow_jump: bool = true; var allow_sprint: bool = true
static func step(c: CombatState, input: PlayerInput, grounded: bool) -> ActionMachine.Output
static func phase(c: CombatState, tick: int) -> int
static func is_attack_active(c: CombatState, tick: int) -> bool
static func is_blocking(c: CombatState, tick: int) -> bool
static func is_parry_window(c: CombatState, tick: int) -> bool
static func is_invulnerable(c: CombatState, tick: int) -> bool
static func defense_flags(c: CombatState, tick: int) -> int
static func action_byte(c: CombatState, tick: int) -> int
static func impose_stagger(c: CombatState, tick: int, until_tick: int, knockback: Vector2) -> void
static func impose_stun(c: CombatState, tick: int, until_tick: int) -> void
static func impose_death(c: CombatState, tick: int) -> void
static func reset_for_respawn(c: CombatState, tick: int) -> void
static func drain_stamina(c: CombatState, amount: int, tick: int) -> void

# scripts/shared/combat/hit_shapes.gd
class_name HitShapes extends RefCounted
static func sector_hits_capsule(origin: Vector3, yaw: float, shape: HitShape,
		capsule_feet: Vector3, radius: float, height: float) -> bool
static func segment_hits_capsule(a: Vector3, b: Vector3, capsule_feet: Vector3, radius: float,
		height: float) -> bool
static func has_line_of_sight(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> bool
static func is_in_front(defender_pos: Vector3, defender_yaw: float, attacker_pos: Vector3,
		cone_deg: float) -> bool

# scripts/shared/combat/damage_formula.gd
class_name DamageFormula extends RefCounted
enum DamageType { SLASH, PIERCE, BLUNT, ELEMENTAL }
class Result:
	var damage: int; var absorbed: int; var stamina_cost: int; var critical: bool
	var guard_break: bool
static func compute(attack: AttackTicks, charge_ticks: int, critical: bool, blocked: bool,
		block_mitigation: float, block_stamina_per_damage: float, defender_stamina: int,
		armor: int) -> DamageFormula.Result
static func is_backstab(attacker_pos: Vector3, victim_pos: Vector3, victim_yaw: float) -> bool

# scripts/shared/war/faction_rules.gd
class_name FactionRules extends RefCounted
static func can_damage(attacker_realm: int, victim_realm: int, zone_id: StringName) -> bool
```

---

## 10. Riesgos

- **Coste de `simulate()`**: la máquina de acciones añade trabajo por personaje. Medido en K5: 69–72 µs
  por personaje, frente a los 42–50 µs de la fase 2 (red.md 14); es el cuello de las refriegas.
- **Parada con latencia**: 6 ticks de ventana con 150 ms de RTT puede ser una lotería. Se mide en
  CMB-29 (12.7: la primera pasada solo la calcula; se decide con personas); si no funciona, pasa a
  habilidad del escudo.
- **Ligeros imposibles de reaccionar en red** (12 ticks): es intencionado; la defensa reactiva es
  contra los fuertes.
- **Animación**: los clips gratuitos no cubren impacto en bloqueo ni esquiva lateral (arte.md). Se
  usan sustitutos y se anota.
- **Ancho de banda**: +34 B de estado, +9 B de bloque y +1 B por registro por snapshot (~2,7 KB/s
  más al tope) y 52 registros por snapshot en vez de 57.

---

## 11. Cambios durante la implementación

Huecos del documento que se cerraron al implementar (K1a, K1b, K2):

- **`combat_flags`**: además de los bits 0–2, bit 3 DODGE, bit 4 BLOCK y bit 5 PRIMARY guardan
  si el botón estaba pulsado en el tick anterior; así los flancos no dependen de `prev_buttons` y
  un control impuesto con el botón mantenido no crea un ataque fantasma. El bit 1 dura un tick. El
  bit 6 (`FLAG_LIGHT_OF_PRESS`) marca que el ligero en curso es de la pulsación viva (siguiente
  punto).
- **Búfer**: tipo 3 = enlace de combo (la pulsación en la ventana de enlace espera al fin de la
  recuperación; 4 bits no bastaban para 9 + 8 ticks). Una sola ranura; la pulsación del tick `p`
  vale en `p+1 … p+8`; la esquiva guardada usa `move`/`look_yaw` del tick en que se ejecuta; una
  esquiva rechazada por resistencia se descarta.
- **Conversión a carga**: «ligero empezado por esta pulsación» lo dice el bit 6 de `combat_flags`
  (`FLAG_LIGHT_OF_PRESS`): lo pone `_try_start_light` cuando el ligero empieza con la pulsación viva
  abajo (flanco de ese tick, o búfer o enlace que ella dejó) y lo borra soltar PRIMARY, empezar otra
  acción o un control. Antes se deducía de `action_tick ≥ t − primary_held + 1`, que solo vale sin
  entradas sustituidas: `primary_held` no cuenta las sustituidas, y con un hueco el servidor nunca
  convertía el ligero (el cliente sí había predicho la carga). Ahora una entrada sustituida entre
  `p+1` y `p+7` retrasa la carga un tick por cada una (sigue contando ticks reales y exige
  anticipación), no la anula. Mantener PRIMARY desde la ventana de enlace convierte el siguiente
  ligero en carga. El tamaño codificado no cambia.
- **Movimiento en acciones**: velocidad objetivo literal `wish · run_speed · move_scale (+ avance)`
  sin los multiplicadores de retroceso, lateral ni esprint (campo extra `scaled_movement` en
  `Output`). BLOCK se deja al dejar de pulsar o en el aire. La ventana de parada exige además que
  el BLOCK sea el que la abrió.
- **`action_byte`**: NONE, BLOCK y DODGE llevan fase 3 («sin fases»), así que NONE vale `0x30`;
  quien lea la acción usa `byte & 15`.
- **IDs**: orden alfabético; `sword_heavy` = 1, `sword_light_1..3` = 2..4. Se piden por nombre
  (`CombatCatalog.attack_id()`, `WeaponTicks.light_ids/heavy_id`).
- **`reset_for_respawn(c, tick)`** sin `rules` (las saca del catálogo).
- **`DamageFormula.compute`** recibe los campos sueltos (`base_damage, charge_ticks,
  charge_min_ticks, charge_max_ticks, charge_damage_scale, critical, blocked, block_mitigation,
  block_stamina_per_damage, defender_stamina, armor, crit_multiplier`). El bloqueo no distingue el
  daño elemental: `is_physical()` deja que el servidor decida.
- **`HitShapes.has_line_of_sight(space, pies_atacante, pies_víctima)`** suma las alturas (1,4 y
  0,9 m); `is_ray_clear` para puntos ya calculados.
- **`FactionRules`**: un código de reino desconocido ni daña ni recibe daño; los Huecos son
  hostiles a los reinos en cualquier zona, no entre sí.
- **Bloque extra**: va siempre que va el estado propio (bit 0 ⇔ bit 3). Hasta que exista
  `Combatant`, `NetEntity.set_health_view()` anuncia 1000/1000.
- **Coste medido** de `simulate()` (microbanco, un mundo): sin acción +4–5 µs respecto a la fase 2
  (16,9 µs quieto, 37,9 µs corriendo); bloqueando 48 µs; combate mixto 44 µs.

Cerrado durante K3 (servidor) y K4 (cliente):

- **Clases del servidor**: `CombatDirector` (el paso de combate del tick: congelar, resolver,
  aplicar, entorno, reapariciones, publicar), `CombatResolver` (solo calcula: devuelve impactos),
  `CombatTiming` (plazos en ticks), `Combatant`, `DamageLedger`, `SafeAreas`, `CommandRegistry`,
  `ServerConsole` y `NpcBrain` (extiende `BotBrain`).
- **RESPAWN_REQUEST**: el índice va sobre `NetZones.get_respawn_points(zona, reino)`, la misma lista
  en servidor y cliente (`RespawnPointList` la usa tal cual). Un índice que ya no vale usa el
  primer punto, sin aviso. Una petición hasta 12 ticks antes de `respawn_tick` queda pendiente;
  antes de eso, o estando vivo, es aviso. La automática llega a los 30 s **desde la muerte**.
  *(Cambiado en F3, fase 4: el índice va sobre `NetZones.get_all_respawn_points(zona)`, la lista estática
  de todos los puntos; el servidor valida con `RespawnRules.points_for` y, si no vale, usa el primer
  campamento válido del reino; ver [fuerte.md 8.3](fuerte.md#83-lo-que-han-dejado-f0-f1-y-f2-añadidos-al-contrato-y-decisiones).
  `CombatDirector.get_respawn_points(reino)` ya no existe: son `get_all_respawn_points()` y
  `get_valid_respawn_points(reino, tick)`.)*
- **Blancos estáticos (F3)**: `CombatResolver.structure_targets` (las puertas de los fuertes,
  `StructureTarget`) se prueba para cada ataque activo antes del rebobinado, con `Outcome.STRUCTURE`; el
  director aplica el daño con los multiplicadores de `CombatRules` y avisa con `structure_hit`. El KILL
  va a toda la zona. Con alguna fortaleza en la zona, `CombatTiming.respawn_wave_ticks = 600`: la
  reaparición sale en oleadas de 10 s.
- **Cadena de controles**: cuenta todos los controles (también el tambaleo de la parada y la
  rotura de guardia). `hyper_armor` solo anula el tambaleo y el empuje de los impactos.
- **«En combate»**: también lo ponen un bloqueo, una parada y la caída. La protección de
  reaparición se pierde también al empezar una carga.
- **Maniquí**: PNJ neutral «Maniquí», modos quieto, bloqueando y girando, tope de 16; `ServerMain`
  pone uno en cada `dummy_points` (`--no-dummies` lo evita). Su HIT lleva el daño completo
  calculado aunque la vida se quede en 1, para que el medidor de DPS cuente entero.
- **Caída y muertes del entorno**: HIT con atacante 0 y tipo contundente; DEATH con `attack_id` 0 y
  autor el último enemigo en 10 s; KILL solo si hay autor.
- **Zonas seguras del Vado Gris**: en (0, 6,25, ±138), radio 24; maniquíes en (0, ±108). Añadidos a
  mano al `.tscn` y al generador (que no se ha ejecutado aquí).
- **Comandos**: los de red actúan sobre quien los envía; datos mal formados = aviso, imposible =
  rechazado sin aviso; todo queda auditado. Consola por stdin **solo con `--console`**; en Linux,
  con la entrada abierta, el proceso no termina tras cerrar hasta recibir una línea o Ctrl+D.
- **`--combat-log`**: cabecera `tick,atacante,objetivo,ataque,view_tick,rebobinado,resultado,daño`
  y resultados `hit`, `blocked`, `guard_break`, `parried`, `invulnerable`, `rewind_rejected`.
- **Cliente**: los eventos son propios según los ids; los ajenos esperan en `CombatEventQueue`
  (tope 512) hasta su `render_tick`. Un snapshot atrasado con «muerto» posterior a un RESPAWN no
  reabre la pantalla de muerte. La cuenta atrás usa un tick del servidor estimado (conservador). El
  bit de «sin resistencia» se lee en `_physics_process` y parpadea 0,6 s. La animación es una
  función pura de `(action, action_id, action_tick, tick)`; los remotos cuentan el tiempo de cada
  fase desde que la ven entrar. La vida, la resistencia y el DPS están en el panel F3 del HUD.
- **Coste medido** del paso de combate con refriegas de jugadores falsos (test_world): 32 →
  combate p50 0,44 ms / p99 2,8 ms; 64 → 0,64 / 6,1; 128 → 1,3 / 4,3 (domina `simulate()`).

Cerrado durante K5 (integración):

- **Rebobinado fijado por golpe y antelación acotada** (revisión de la fase 3, R1): el rebobinado se
  lee una vez, en el primer tick activo; la antelación que abona el tope es la de la entrada del golpe,
  acotada por la habitual del cliente más 3 y por 8 (con la de cada entrada a secas, un cliente que
  adelantara las entradas de su golpe subía el tope a 24 con RTT de LAN). Para un honrado no cambia
  nada: su vista es `rtt + antelación de esa entrada + interpolación`, de modo que la antelación de su
  entrada es justo la que el tope necesita (con el mínimo de la ventana, en cambio, un honrado con
  jitter se quedaba por encima del tope y el golpe, ya sin segunda oportunidad en los ticks activos
  siguientes, se rechazaba: lo mostró `test_combat_reconciliation`, de 47 golpes a 0). Las pruebas de K5
  con rtt=150 y jitter=30 (`test_combat_loopback`) siguen confirmando todos sus golpes sin sospecha. El
  mínimo para la defensa y sus límites están en §4.3, paso 2.
- **Tope del rebobinado con jitter**: el mínimo del RTT de la ventana (red.md 10) se queda por debajo
  del viaje de un tick cualquiera, y con `rtt=150,jitter=30` el tope rechazaba un 20 % de los ticks
  activos de un bot honrado (y le sumaba sospecha). El tope usa `max(mínimo, máximo)` de la ventana
  (`ServerPeer.rtt_peak_ticks`), con la misma cota independiente del cliente. Con 150 ms de RTT y 30
  de jitter el servidor confirma el 100 % de los golpes que el atacante veía dentro del arco (20 de 20;
  8 de ellos habrían fallado sin rebobinar) con un rebobinado medio de 21,7 ticks; con 200 ms el tope
  de 24 ticks ya no cubre a un jugador honrado (11 de 20): decisión de diseño pendiente (subir
  `MAX_REWIND_TICKS` o recortar el margen de `TickSync`).
- **Modos del bot tramposo**: `rewind` (pelea con el cerebro de combate y 40 ticks de vista en todas sus
  entradas: ningún daño, una sospecha por golpe), `reach` (`BotCheatBrain`: ataca desde 5 m con entradas
  legítimas: ningún impacto, ninguna sospecha) y `rate` (machaca PRIMARY un tick de cada dos: 14 aciertos
  en 600 ticks, el tope del combo es 17). La puntuación de sospecha de la fase 3 solo sube con el
  rebobinado; alcance y ritmo los resuelve la propia simulación del servidor sin que haya nada que
  puntuar.
- **Cerebro de combate del cliente**: `--bot-brain=combat` (`ClientBotBrains`, `BotEnemySight`): el
  enemigo más cercano que dibuja su `RemoteWorld` y que el servidor dejaría dañar; no ve a los
  maniquíes (los modos tramposos sí) ni conoce las zonas seguras. Los bots ligeros de `--bots=N`
  ([SwarmBot]) pelean igual sin simular: enemigos por los ENTITY_SPAWN, posiciones por una fracción
  rotatoria de los registros de cada snapshot (1 de cada 6), `view_offset_q` real (su tick menos el
  de dibujo) y RESPAWN_REQUEST al morir. Con `--fake-brain=combat` pelean los jugadores falsos del
  servidor (K3).
- **Correcciones explicadas por el combate** (cierra un hueco de §3.4 para las pruebas): lo que el
  servidor impone (tambaleo, aturdimiento, empuje, resistencia gastada por un bloqueo, muerte,
  reaparición) obliga al cliente que lo sufre a corregir su predicción, y eso no es un fallo.
  `NetClient` anota los eventos propios que imponen estado (HIT con él de víctima o con su golpe
  parado, DEATH, RESPAWN) y da por explicada la corrección cuyo snapshot cae en el tick del evento o
  en los 12 siguientes (`COMBAT_EXPLAIN_TICKS`); el evento va por el canal fiable y puede llegar
  después del snapshot, así que una diferencia espera 90 ticks (`DIFF_SETTLE_TICKS`) a su evento
  antes de contar como fallo (mientras tanto `get_stats()` la cuenta según lo que sabe). Estadística
  nueva: `combat_diffs`. Medido en una refriega de 6 bots de combate con rtt=120, jitter=20 y 5 % de
  pérdida (`test_combat_reconciliation`): 40 golpes, 4 muertes, 2-4 correcciones por bot, todas
  explicadas (sustitución o combate), ningún reinicio duro ni resincronización y convergencia exacta
  al quedarse quietos.
- **Carga de combate** (TEC-15; cifras y límite en red.md 14): `load_test.gd --brawl` mide refriegas de 32, 64
  y 128 combatientes (falsos con `--fake-brain=combat` en un corro, `--fake-center`, y 10 bots reales con
  `--bot-brain=combat`). El servidor cuenta aparte las secciones `combat_resolve` (golpes con
  rebobinado: 76–97 µs por comprobación de forma y línea de visión) y `combat_events` (armar y mandar los
  ENTITY_EVENT: 67–97 µs por evento), y el informe lleva `hit_tests`, `resolve_us`, `resolve_busy_ticks` y
  `event_bytes_sent` (0,5–1,6 KB/s de eventos en todo el servidor). **Primer límite de jugadores por
  batalla con combate: 64** (p99 del tick 15,9 ms, sin sustituciones ni rebobinados rechazados); con
  128 el servidor ya no sostiene el tiempo real y rechaza el rebobinado a los honrados. El coste de
  combate es lineal (unos 0,14 golpes por segundo y combatiente) y no es el cuello: lo es
  `simulate()`.
- **Demo del sandbox (CMB-06)**: `--demo --quit-after-demo` en un cliente sin ventana termina solo con
  código 0 y sin errores en test_world (803 ticks) y en el Vado Gris (2049 ticks). `ClientMain` anota las
  acciones de combate en las que entra el personaje durante la demo y las escribe al final
  («Demo, acciones de combate: LIGHT x4, CHARGE x1, HEAVY x1, BLOCK x1, DODGE x1»: los tres ligeros del combo
  más la pulsación que se convierte en la carga), de modo que `test_combat_demo` comprueba con un proceso
  real que la máquina de acciones recorre lo que dice el guion, no solo que el guion lo pida. En el Vado Gris
  sale una sola advertencia, «instance_reset_physics_interpolation() is deprecated», al añadir la zona al
  árbol (`client_main.gd`, `add_child`): la lanza código nativo (probablemente Terrain3D), ningún script del
  proyecto llama a esa función, y no afecta a la demo.

---

## 12. Primera pasada de equilibrio (CMB-29)

Primera pasada con **espada y escudo**, el único kit de la fase 3. Se repite cuando lleguen las habilidades
(CMB-21) y el arco (CMB-23); las dos partes que dependen de contenido que aún no existe, la puerta del
fuerte (GUE-10) y el capitán (MUN-11), quedan pendientes (12.7). Las cifras salen de
`tools/combat_balance.gd`, no de una cuenta a mano: monta un `ZoneServer` sin red sobre `test_world`
(llano, sin terreno ni zonas seguras: el daño no depende de ellos), lo avanza tick a tick sin esperar
al motor y lee los datos de `data/combat/`. **No usa reloj ni red, así que es determinista:** dos
ejecuciones dan el mismo JSON byte a byte, en cualquier máquina. Se lanza con

```
godot --headless --path . -s res://tools/combat_balance.gd -- --duels=60 --seconds=30 --out=build/combat_balance.json
```

(unos 20 s; `tests/test_combat_balance.gd` lo lanza en pequeño y comprueba que el DPS medido es el que dicen
los `.tres`).

### 12.1 Hoja de acciones (lo que dicen los datos)

Vida 1000 y resistencia 1000 para todos; 1 tick = 1/60 s. Estos datos están en `data/combat/`
(`sword_light_*.tres`, `sword_heavy.tres`, `sword_dodge.tres`, `sword_shield.tres`, `combat_rules.tres`).

| Acción | Duración | Daño | Resistencia | DPS contra el maniquí (medido) |
|---|---|---|---|---|
| Ligero 1 | 36 ticks (0,60 s), golpe al tick 12 | 90 | 0 | 150,0 si se repite sin enlazar |
| Ligero 2 | 35 ticks (0,58 s), golpe al tick 11 | 90 | 0 | |
| Ligero 3 | 48 ticks (0,80 s), golpe al tick 15 | 130, tambaleo de 0,3 s | 0 | |
| **Combo de 3 ligeros** | 119 ticks (1,98 s) | 310 | 0 | **156,3** |
| Fuerte, carga mínima | 85 ticks (1,42 s): 21 de carga, 24 de anticipación, 7 activos, 33 de recuperación | 180, tambaleo de 0,5 s, empuje de 4 m/s | 150 | 127,1 |
| Fuerte, carga máxima | 136 ticks (2,27 s): 72 de carga | 306 (×1,7) | 150 | 135,0 |
| Esquiva | 27 ticks (0,45 s), 4,5 m; invulnerable de 0,05 s a 0,30 s | | 300 | |
| Bloqueo | 120 grados, mitigación del 100 % | | 1 por punto de daño bloqueado | |
| Parada | ventana de 6 ticks al pulsar BLOCK, reutilización de 30 ticks | | 0 | |

- **El DPS medido es igual al calculado con los datos** (156,3, 150,0, 127,1 y 135,0, con 45, 50, 21 y 13
  golpes en 30 s, ciclos completos): la máquina de acciones, la ventana de enlace y la carga hacen
  exactamente lo que dicen los `.tres`; no hay pérdidas de ticks al enlazar. Lo que lo demuestra no
  es la división (daño de ciclos enteros entre sus segundos da siempre el DPS calculado, y el búfer de
  8 ticks absorbe un tick de retraso por enlace sin cambiar el recuento de golpes) sino el **tick de
  cada golpe**: la herramienta lo exporta (`hit_ticks` frente a `expected_hit_ticks`) y
  `test_combat_server` y `test_combat_balance` exigen que coincidan, con un control que alarga un
  tick el ligero 1 y comprueba que se detecta.
- **TTK ideal calculado:** 1000 de vida entre 156,3 de DPS son 6,4 s de combo continuo, o 7,4 s con
  fuertes cargados al máximo. Medido con un atacante perfecto (combo encadenado, del primer golpe a la
  muerte): **5,95 s y 10 golpes contra alguien quieto** (el primer golpe va 12 ticks después de empezar).

### 12.2 Coste de resistencia por acción

- **Atacar es gratis; defender cuesta.** Los tres ligeros cuestan 0, el fuerte 150 (6 seguidos desde la
  barra llena) y la esquiva 300 (**3 seguidas**, y quedan 100). El bloqueo cuesta 1 por punto de daño que
  detiene: la barra entera aguanta 1000 de daño, es decir, algo más de 3 combos completos (310 cada uno).
- **Regeneración:** 3 por tick (180/s) a partir de 0,6 s sin gastar; quien llega a 0 queda agotado y
  regenera 1 por tick (60/s) hasta superar 300. Una barra con algo de resistencia tarda como mucho 5,6 s en
  llenarse; una agotada, unos 9,5 s (0,6 s de espera, 5 s hasta 300 y 3,9 s más).
- **Bloquear sin parar no es dominante ni inútil.** Un atacante perfecto rompe la guardia de quien bloquea
  sin parar a los **5,95 s** (rotura: aturdimiento de 1 s) y lo mata a los **14,47 s**, con 23 golpes (13
  bloqueados): 2,4 veces lo que tarda contra uno quieto. Bloquear compra unos 8,5 s, a costa de no atacar.
- **El ligero repetido casi iguala al combo** (150,0 contra 156,3 de DPS, un 4 % menos): como los ligeros no
  cuestan resistencia, no hay nada que premie enlazar los tres salvo el tambaleo del tercero y su
  avance. Ver la propuesta P1.

### 12.3 TTK entre iguales con bots

60 duelos de dos bots de combate (`BotBrain` en modo `COMBAT`: ataca cada 26 a 34 ticks, de ellos un 14 %
bloquea, un 10 % esquiva y un 12 % carga un fuerte; **no reacciona al ataque del rival**), de reinos
enemigos, con las mismas armas, a 4 m de distancia, hasta que uno muere:

| | Primer golpe a la muerte |
|---|---|
| Mínimo / p10 | 5,8 s / 7,3 s |
| **Mediana** / media | **10,7 s** / 11,4 s |
| p90 / máximo | 16,4 s / 20,7 s |

- Por duelo: 15,0 golpes que hacen daño (1717 de daño entre los dos), 2,8 bloqueados, 0,1 paradas, 0,0
  roturas de guardia y 1,4 esquivados. Ningún empate por tiempo; ganó el primero 27 veces y el segundo
  33 (sin ventaja de lado). El ganador hace una mediana de 92,6 de DPS: el 59 % del combo ideal, porque un
  bot que ataca a intervalos al azar no enlaza el combo cuando toca.
- **Lectura:** el ideal contra alguien quieto (5,95 s) es el suelo; los bots, que no leen al rival, mueren
  en la mitad baja de lo que se pretende entre iguales (12.5). Con jugadores que bloqueen, esquiven y
  paren a tiempo el TTK sube; con armaduras y estadísticas (PRG-01, PRG-06) también. Por eso esta cifra
  es una **cota baja**.

### 12.4 Equipos de 2 contra 2 y de 5 contra 5

20 combates de cada tamaño con bots de combate (Vardheim contra Solmarch, en fila, a 4 m), hasta que un
bando se queda sin nadie en pie, con reapariciones de 10 s de por medio y un tope de 60 s:

| | Primera baja (mediana, p10 / p90) | Un bando sin nadie en pie (mediana, p10 / p90) | Bajas por combate |
|---|---|---|---|
| 2 contra 2 | 5,0 s (3,8 / 7,0) | 8,4 s (6,1 / 13,8) | 2,5 |
| 5 contra 5 | 3,0 s (2,4 / 5,3) | 8,6 s (5,6 / 11,1) | 6,8 |

Ninguno de los 40 combates llegó al tope. Con 5 contra 5 sale una baja cada 3 s y el combate entero dura lo
que un duelo: sin curación, sin armadura ni habilidades defensivas, una pelea pequeña se decide de
inmediato. **No es una cifra para el fuerte** (docenas de combatientes, curaciones y puertas): se repite al
llegar CMB-21 y GUE-15.

### 12.5 Decisiones de esta pasada

| Decisión | Motivo |
|---|---|
| **TTK objetivo entre iguales** con espada y escudo y sin armadura: mediana de 10 a 15 s por duelo, p10 no por debajo de 6 s y p90 no por encima de 25 s. | El ideal contra uno quieto es 6 s (suelo); los bots dan mediana 10,7 s, p10 7,3 s, p90 16,4 s: dentro del margen y cerca del suelo, que es lo que se espera de una cota baja. |
| **No se cambia ningún `.tres`** (vida 1000, daños 90/90/130/180, costes 150/300, bloqueo 1:1, regeneración 180/s, parada de 6 ticks). | Todo el DPS medido coincide con el calculado, el TTK cae en el margen y las cifras que más pesan (armadura, habilidades, jugadores que reaccionan) aún no existen. Retocar a ciegas contra bots que no reaccionan sería ajustar al ruido. |
| **El TTK se defiende con la vida y el daño base, no con el coste de resistencia.** Cuando entren armaduras (PRG-06) se mantiene el TTK objetivo escalando la mitigación, no el daño ni la vida. | Los ligeros no cuestan resistencia: no hay palanca de resistencia sobre el ataque. |
| **La parada de 6 ticks se queda en el kit.** | No se ha podido medir con latencia (12.7). |

### 12.6 Propuestas sin aplicar

- **P1. Premiar el combo: `sword_light_3.base_damage` de 130 a 150.** Medido cambiando el dato solo en una
  ejecución de la herramienta (y revirtiéndolo): el combo pasa de 310 a 330 de daño (**166,4 de DPS, un 11
  % más que el ligero repetido** en lugar de un 4 %), el TTK ideal contra uno quieto no cambia (5,95 s y
  10 golpes), contra uno que bloquea baja de 14,5 s a 13,1 s (21 golpes) y la mediana de los duelos de
  bots de 10,7 s a 10,5 s (p10 7,0, p90 16,4). Es una mejora barata del valor de enlazar y no toca el TTK
  objetivo, pero se deja para cuando se vea si los jugadores enlazan por gusto: lo medido son bots.
- **P2. Fuerte.** Su DPS (127–135) queda un 14–19 % por debajo del combo y cuesta 150 de resistencia y
  hasta 1,2 s de carga a la vista. Lo compensan la `hyper_armor` (no se tambalea ni se le empuja
  mientras golpea), el empuje de 4 m/s, el tambaleo de 0,5 s y que un fuerte bloqueado cuesta al defensor
  180–306 de resistencia de una vez (3,3 máximos rompen la guardia). Sin cambios mientras no haya datos de jugadores.
- **P3. Cota baja del TTK de 5 contra 5.** Si con curaciones y armaduras la primera baja de un 5 contra 5
  sigue por debajo de los 5 s, subir la vida base o bajar el daño base antes que tocar las duraciones.

### 12.7 Pendiente de esta pasada (CMB-29 sigue abierto)

- **Vida de la puerta y tiempos del fuerte:** dependen de GUE-10 (puerta destructible), GUE-15 (bots de
  asedio) y GUE-08 (captura). Referencia para dimensionarlos: cada atacante de espada hace hasta 156
  de DPS antes del multiplicador de estructuras; vida de la puerta = atacantes simultáneos × 156 ×
  segundos que debe aguantar × (1 − fracción del tiempo que no golpean).
- **Capitán del Vado (MUN-11)**: TTK del jefe contra grupos de 5; no hay jefe todavía.
- **Parada con latencia** (riesgo de §10): los bots paran por casualidad (0,1 por duelo), así que no
  prueban nada. Cuenta, no medida: con 150 ms de RTT el defensor ve empezar un ataque
  entre 142 y 275 ms más tarde (75 ms de medio RTT más 4 a 12 ticks de interpolación) y su pulsación
  tarda otros 75 ms en llegar, es decir, 13 a 21 ticks después del inicio. Un ligero golpea a los 12
  ticks: solo se para por anticipación. Un fuerte golpea a los 45 ticks como mínimo (21 de carga y 24 de
  anticipación), con lo que sobran de 24 a 32 ticks para reaccionar. La ventana de 6 ticks (100 ms) le
  pide a un humano acertar el momento con unos ±50 ms. Se decide con personas en la prueba cerrada (si
  no funciona, la parada pasa a habilidad del escudo).
- **Personas:** todas las cifras son de bots que no reaccionan. Falta una sesión de 2 contra 2 y 5 contra 5
  con jugadores en el Vado Gris para fijar el TTK real.
