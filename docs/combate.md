# Eldmark · Fase 3: diseño del combate de acción

Diseño del paso 3 de la [hoja de ruta](vision.md#hoja-de-ruta): ataques ligeros y fuertes,
bloqueo, esquiva, resistencia, compensación de latencia, muerte y reaparición, en red y con el
servidor como autoridad. Se apoya en la red de la fase 2 ([red.md](red.md), sobre todo §6.7, §10 y
§15) y cubre los elementos de la fase 3 del [backlog](backlog.md).

Primer y único kit de la fase: **espada y escudo**. El resto de armas y las habilidades con
reutilización llegan en la fase 4 (CMB-19 y siguientes) sobre las mismas piezas.

---

## 0. Decisiones

Tomadas de las recomendaciones de [backlog.md](backlog.md#decisiones-pendientes) (provisionales,
tomadas de noche, y movidas a «Decisiones tomadas»):

| Pregunta | Decisión |
|---|---|
| Clases | Sin clases: el rol lo dan las armas equipadas. |
| Armas equipadas | Dos ranuras con cambio rápido (CMB-24, fase 4). En la fase 3 solo hay una: espada y escudo. |
| Números | **Enteros** para vida, resistencia y daño. Nada de floats en lo que se compara o se guarda. |
| Duraciones en los datos | **Segundos** en los `.tres`, convertidos a ticks al cargar con `roundi(s · 60)`. Lo que entra en el `sim_hash` es el catálogo ya convertido. |
| Críticos | **Posicionales, sin azar**: un golpe cuerpo a cuerpo por la espalda (más de 120° respecto a la mirada de la víctima) hace ×1,5. |
| Fuego amigo | No. Los golpes atraviesan a los aliados. |
| Estado defensivo con rebobinado | Protege si el defensor se defendía **en el tick rebobinado o en el actual**. |
| Parada | Ventana de 6 ticks (100 ms) al empezar a bloquear, solo contra cuerpo a cuerpo. |
| Esprint y resistencia | El esprint no gasta resistencia. |
| Impacto propio | Mixto: barrido, estela y sonido del arma al predecir; marcador, chispas y número al confirmar (ENTITY_EVENT). Los números nunca se predicen. |
| Vida del enemigo | En su placa al apuntarle o tras dañarlo en los últimos 5 s; barra de jefe para capitanes. |
| PNJ humanoides | `PlayerCharacter` con entrada sintética (como `BotBrain`). |
| Colisión entre personajes | Ninguna, como en la fase 2. |

---

## 1. Qué se predice y qué decide el servidor

| Dato | Dónde vive | Predicho | Viaja en |
|---|---|---|---|
| Acción actual, su fase y su tick de inicio, combo, carga, búfer | `PlayerState` | Sí | estado propio del snapshot |
| Resistencia y agotamiento | `PlayerState` | Sí | estado propio |
| Desplazamiento de esquiva y avance de los golpes | `PlayerState` (velocidad) | Sí | estado propio |
| Controles (tambaleo, aturdimiento, empuje), rotura de guardia, muerte | `PlayerState`, **impuestos por el servidor** | No: el cliente los adopta al reconciliar | estado propio |
| Coste de resistencia de un golpe bloqueado | `PlayerState`, impuesto por el servidor | No | estado propio |
| Vida | `Combatant` en el servidor | No | bloque extra del snapshot (propia) y `health_q` del registro (ajenos) |
| Golpes, daño, críticos, bajas | `CombatResolver` en el servidor | No | ENTITY_EVENT |

Regla de red.md §6.7: todo lo que solo decide el servidor y cambia la simulación entra en
`PlayerState`, así que la reconciliación lo absorbe sin cambios. La vida no cambia la simulación
(salvo al morir, que es una acción) y por eso no está en `PlayerState`.

---

## 2. Catálogo de combate (CMB-02)

`scripts/shared/combat/`, datos en `data/combat/` (`.tres` en texto).

```gdscript
class_name AttackDefinition extends Resource
@export var id: StringName                 # p. ej. &"sword_light_1"
@export var windup_s: float                # anticipación
@export var active_s: float                # golpe activo (se prueba la forma en cada tick)
@export var recovery_s: float              # recuperación
@export var combo_window_s: float          # al final de la recuperación: enlaza el siguiente
@export var cancel_to_dodge_from_s: float  # desde aquí (dentro de la recuperación) se puede esquivar
@export var stamina_cost: int              # 0–1000
@export var lunge_speed: float             # m/s de avance durante la anticipación y el golpe activo
@export var turn_rate: float               # rad/s de giro permitido durante la acción
@export var move_speed_scale: float        # velocidad de carrera permitida (0 = clavado)
@export var shape: HitShape                # sector: alcance, ángulo, alturas
@export var base_damage: int
@export var damage_type: int               # CombatRules.DamageType
@export var poise_damage: int              # contra la entereza
@export var hyper_armor: bool              # entereza durante el golpe activo
@export var stagger_s: float               # tambaleo que causa (0 = ninguno)
@export var knockback_speed: float         # empuje que causa (m/s, 0 = ninguno)
@export var charge_min_s: float            # solo fuertes: carga mínima y máxima
@export var charge_max_s: float
@export var charge_damage_scale: float     # multiplicador a carga máxima (lineal desde 1)

class_name WeaponDefinition extends Resource
@export var id: StringName
@export var light_combo: Array[AttackDefinition]   # 3 golpes
@export var heavy: AttackDefinition
@export var block_angle_deg: float                 # cono frontal
@export var block_mitigation: float                # 1,0 = para todo el daño físico frontal
@export var block_move_scale: float
@export var block_stamina_per_damage: float        # resistencia por punto de daño absorbido
@export var dodge: DodgeDefinition

class_name DodgeDefinition extends Resource
@export var duration_s: float
@export var invulnerable_from_s: float
@export var invulnerable_to_s: float
@export var distance_m: float                      # recorrido total (perfil de velocidad fijo)
@export var stamina_cost: int
@export var cancel_to_attack_from_s: float

class_name HitShape extends Resource
@export var range_m: float
@export var inner_m: float
@export var angle_deg: float
@export var height_min: float                      # relativas a los pies del atacante
@export var height_max: float
```

**`CombatCatalog`** (RefCounted, estático): carga los `.tres` de `data/combat/`, asigna IDs u16
estables (orden alfabético de `id`; un `id` repetido es un error), convierte las duraciones a ticks
(`roundi(s · 60)`, como mínimo 1 en las fases activas) y expone tablas en ticks:
`attack(id_u16) -> AttackTicks`, `weapon(id_u16)`. `CombatCatalog.prediction_hash()` hace el
SHA-256 de lo que afecta a la predicción (fases, movimiento, costes de resistencia, ventanas,
cancelaciones, esquiva) y entra en `NetProtocol.compute_sim_hash`. Daño, mitigación y críticos no
entran: los decide el servidor.

**`CombatRules`** (`data/combat/combat_rules.tres`): resistencia máxima 1000, regeneración (por tick
y retardo), umbral de salida del agotamiento, regeneración en agotamiento, protección al reaparecer
(3 s), tiempo de reaparición (10 s en PvP), duración de «en combate» (10 s), vida máxima base
(1000), regeneración fuera de combate, umbral y escala del daño por caída, inmunidad tras controles.

Valores iniciales de espada y escudo (en `data/combat/sword_shield.tres`, ajustables en CMB-29):

| Ataque | Anticipación | Activo | Recuperación | Resistencia | Daño |
|---|---|---|---|---|---|
| Ligero 1 / 2 / 3 | 0,20 / 0,18 / 0,25 s | 0,10 s | 0,30 / 0,30 / 0,45 s | 0 | 90 / 90 / 130 |
| Fuerte (carga 0,35–1,2 s) | carga + 0,15 s | 0,12 s | 0,55 s | 150 | 180 → 300 |
| Esquiva | 0,45 s (invulnerable 0,05–0,30 s), 4,5 m | | | 300 | |
| Bloqueo | cono de 120°, para el 100 % frontal, movimiento ×0,5, 1,0 de resistencia por punto | | | | |

---

## 3. Máquina de acciones (CMB-03, CMB-04, CMB-06, CMB-13, CMB-14)

`scripts/shared/combat/action_machine.gd`: función determinista que `PlayerCharacter.simulate()`
llama **antes** del movimiento. Lee la entrada, el estado y el catálogo; escribe el estado de
acción y devuelve cómo se limita el movimiento en este tick (escala de velocidad, giro permitido,
velocidad impuesta).

### 3.1 Estado nuevo en `PlayerState` (entra en `encode()`)

| Campo | Tipo | Qué es |
|---|---|---|
| `action` | u8 | `NONE`, `ATTACK`, `CHARGE`, `BLOCK`, `DODGE`, `STAGGER`, `STUN`, `DEAD` |
| `action_id` | u16 | ataque del catálogo (o 0) |
| `action_tick` | u32 | tick en que empezó la acción |
| `combo_step` | u8 | golpe del combo (0–2) |
| `stamina` | u16 | 0–1000 |
| `stamina_regen_tick` | u32 | primer tick en que vuelve a regenerar |
| `combat_flags` | u8 | bit0 agotado, bit1 PRIMARY pendiente (pulsado sin decidir ligero/fuerte), bit2 golpe enlazado en el búfer |
| `buffered` | u8 | acción guardada en el búfer y ticks que le quedan (4 + 4 bits) |
| `primary_down_tick` | u32 | tick de la pulsación de PRIMARY pendiente |
| `cc_until_tick` | u32 | fin del control actual (tambaleo, aturdimiento) |
| `cc_immune_until_tick` | u32 | fin de la inmunidad tras controles |
| `weapon_id` | u16 | arma equipada |

`PlayerState.ENCODED_SIZE` pasa de 35 a 65 B y `PROTOCOL_VERSION` a 2. Los ticks absolutos
(en vez de contadores) hacen que el estado se pueda restaurar en cualquier tick sin ambigüedad.

### 3.2 Reglas

- **Fases de un ataque** (desde `action_tick`): anticipación, activo y recuperación según el
  catálogo. Durante la anticipación y el golpe activo hay avance (`lunge_speed`) en la dirección
  del personaje y giro limitado a `turn_rate`.
- **Ligero o fuerte.** Al pulsar PRIMARY queda pendiente. Si se suelta antes de 8 ticks, empieza el
  ligero en ese tick. Si se mantiene 8 ticks, empieza la carga (`CHARGE`): soltar entre
  `charge_min` y `charge_max`, o llegar a `charge_max`, lanza el fuerte con el daño escalado.
  Soltar antes de `charge_min` lanza el fuerte con carga mínima.
- **Combo.** Pulsar PRIMARY en la ventana de enlace (final de la recuperación) encadena el
  siguiente ligero en cuanto termina la recuperación; fuera de la ventana el combo vuelve a 0.
- **Búfer.** Una pulsación de ataque o esquiva que llega cuando la acción actual no se puede
  cancelar se guarda hasta 8 ticks y se ejecuta en cuanto se pueda.
- **Cancelaciones.** Un ataque solo se cancela con esquiva desde `cancel_to_dodge_from`. La
  esquiva se cancela con un ataque desde `cancel_to_attack_from`. El bloqueo se cancela al soltar
  BLOCK o con esquiva. Los controles y la muerte no se cancelan.
- **Bloqueo.** BLOCK mantenido sin otra acción: `BLOCK`, movimiento ×`block_move_scale`. Los
  primeros 6 ticks son ventana de parada.
- **Esquiva.** Flanco de DODGE con resistencia ≥ coste y sin agotamiento: dirección según `move`
  relativa a `look_yaw` (hacia atrás sin entrada), perfil de velocidad fijo que recorre
  `distance_m` con `move_and_slide` (respeta muros y bloqueos del puente). Invulnerable entre
  `invulnerable_from` e `invulnerable_to`.
- **Resistencia.** Costes al empezar la acción. Regenera `regen_per_tick` desde
  `stamina_regen_tick` (retardo tras cada gasto). Al llegar a 0 se activa el agotamiento: ni
  esquiva ni bloqueo hasta superar el umbral, y regeneración más lenta.
- **Controles impuestos.** `STAGGER` y `STUN` ignoran las entradas de acción hasta
  `cc_until_tick`; el movimiento queda a 0 salvo el empuje, que el servidor impone como velocidad.
  `DEAD` ignora todas las entradas.
- **Sin aleatoriedad, sin reloj**, enteros donde se compara. El estado completo se restaura con
  `set_state()`.

Constantes del byte `action` del registro de entidad (para animar a los remotos): bits 0–3 la
acción, bits 4–5 la fase (0 anticipación o carga, 1 activo, 2 recuperación), bits 6–7 el paso del
combo.

---

## 4. Golpes en el servidor (CMB-05, CMB-07, CMB-09, TEC-14)

### 4.1 Geometría (`scripts/shared/combat/hit_shapes.gd`)

Matemática pura, sin cuerpos de física:

- **Sector anular con altura** contra cápsula vertical: distancia horizontal del eje de la cápsula
  al atacante en `[inner − radio, range + radio]`, ángulo respecto al yaw del atacante dentro de
  `angle/2` (ampliado por el radio a esa distancia) y solapamiento vertical de
  `[height_min, height_max]` con la cápsula.
- **Barrido**: se prueba en cada tick activo con la posición y el yaw del atacante de ese tick, así
  que un golpe rápido no se salta un objetivo.
- **Línea de visión**: un rayo contra la capa del mundo (1) desde el pecho del atacante (1,4 m) al
  centro de la cápsula de la víctima. Bloqueado = sin golpe.
- Cada objetivo recibe como mucho un impacto por acción (`action_tick` + objetivo), en orden por
  `net_id`.

### 4.2 Rebobinado (`CombatResolver`, `scripts/server/combat_resolver.gd`)

Corre en el paso de acciones del tick ([red.md §8.1](red.md#81-orden-del-tick)), después de
simular a todos:

1. Para cada combatiente con un ataque en fase activa en el tick `s`: `T = s`,
   `view_offset_q = input_queue.get_view_offset_q(s)` (si la entrada se sustituyó, el último valor
   real), y el `view_tick` y el tope de [red.md §10](red.md#10-historial-para-la-compensación-de-latencia).
2. El atacante se toma en su estado del tick `s` (el actual). Cada candidato (entidades hostiles
   según `FactionRules`, vivas, sin protección de reaparición) se toma de `StateHistory.sample(id,
   view_tick)`: posición, yaw y banderas defensivas.
3. Forma y línea de visión (contra el mundo actual). Nunca se mueven cuerpos.
4. **Defensa**: el golpe se bloquea si el defensor bloqueaba (y el atacante estaba en su cono
   frontal) **en el `view_tick` o en el tick actual**; se para si estaba en ventana de parada en
   alguno de los dos; no hace nada si era invulnerable en alguno de los dos.
5. Resultado → `CombatEvents` (daño, controles, eventos).

`StateHistory` amplía sus banderas por tick: bit 3 bloqueando, bit 4 ventana de parada, bit 5
invulnerable, bit 6 muerto.

### 4.3 Daño (`scripts/shared/combat/damage_formula.gd`)

```
daño = base × carga × crítico × (1 − mitigación_bloqueo) × (1 − armadura / (armadura + 1000))
```

Todo con enteros al final (`roundi`), mínimo 1 si no se bloquea por completo. Tipos de daño:
cortante, perforante, contundente, elemental (resistencias por tipo; en la fase 3, todas 0).
Crítico ×1,5 si el atacante está a más de 120° de la mirada de la víctima. Parada: sin daño,
tambaleo de 0,6 s al atacante. Bloqueo: daño × (1 − mitigación) y resistencia del defensor
`−= daño_absorbido × block_stamina_per_damage`; si llega a 0, **rotura de guardia** (aturdimiento
de 1 s).

### 4.4 Antitrampas (TEC-14)

El cliente solo manda botones. El servidor comprueba resistencia, fases y ritmo con su propia
simulación, así que un cliente modificado no puede atacar más rápido ni sin resistencia. Lo que
queda por vigilar es el rebobinado: `view_offset_q` acotado por el RTT medido (red.md §10) y una
**puntuación de sospecha** por peer (golpes con rebobinado en el tope, ratio de acierto por encima
de lo humano) que solo se registra en el log en la fase 3.

---

## 5. Vida, eventos, muerte y reaparición (CMB-10, CMB-15, CMB-41, GUE-03, GUE-05)

- **`Combatant`** (servidor, uno por entidad que puede recibir daño): vida y máxima, fin del estado
  «en combate», fin de la protección de reaparición, tick de muerte, `DamageLedger` (900 ticks).
- **Regeneración de vida** fuera de combate. «En combate» dura 10 s tras dar o recibir daño.
- **Muerte**: vida 0 → el servidor impone `action = DEAD` en el estado, emite DEATH (víctima,
  autor, arma) y KILL (asesino, asistentes con ≥ 10 % del daño en 900 ticks).
- **Reaparición**: a los `respawn_s` (10 s) el servidor teletransporta (contador de teletransporte)
  a un punto de su reino, con vida y resistencia llenas, `action = NONE` y protección de 3 s que se
  pierde al atacar. Las oleadas y la elección de punto son de la fase 4 (GUE-14, UI-14).
- **Caída**: `PlayerCharacter` expone `last_landing_speed` (velocidad vertical al aterrizar). El
  servidor aplica daño por encima de 13 m/s (≈ 4 m de caída): la pasarela de 3 m no hace daño y la
  torre de 12 m sí. Bajo y = −100 se muere (en vez de reaparecer sin más) y la baja se acredita al
  último enemigo que golpeó en los últimos 10 s.
- **`FactionRules`** (`scripts/shared/war/faction_rules.gd`): `can_damage(atacante, víctima,
  zona)`: sin fuego amigo, Huecos hostiles a todos, reinos enemigos solo en zonas RVR (Vado Gris,
  Eldrun). `Zones` gana el modo PvP de cada zona (SAFE o RVR). **Zonas seguras**: nodos del grupo
  `safe_areas` (Marker3D con metadatos `realm` y `radius`, 24 m) en cada campamento del Vado Gris:
  dentro no se recibe daño. El daño creciente de la guarnición contra intrusos llega con los PNJ
  (fase 4).

---

## 6. Protocolo (TEC-13): `PROTOCOL_VERSION = 2`

- **`PlayerState`** de 65 B (ver 3.1). El estado propio del snapshot crece en consecuencia.
- **Bloque extra propio** tras el estado propio cuando `flags` bit 3: `u16 health`, `u16
  max_health`, `u8 combat_flags` (bit0 en combate, bit1 protegido), `u32 respawn_tick` (0 si vivo).
  9 B.
- **Registro de entidad** de 21 B: se añade `u8 health_q` (vida / máxima × 255, redondeado; 0 =
  muerto) al final. Caben ⌊(1200 − 90) / 21⌋ = 52 registros con estado propio y bloque extra.
- **ENTITY_EVENT** (`0x23`, canal 3): `u8 type`, `u32 tick`, `u8 event`, `u8 len` y los datos:
  - `HIT`: `u16 attacker`, `u16 target`, `u16 amount`, `u8 damage_type`, `u8 flags` (bit0 crítico,
    bit1 bloqueado, bit2 parado, bit3 rotura de guardia, bit4 mortal), `u16 attack_id`;
  - `DEATH`: `u16 victim`, `u16 killer` (0 = entorno), `u16 attack_id`;
  - `KILL`: `u16 killer`, `u16 victim`, `u8 n` y `n × u16` asistentes.
  Se envía a quien tiene relevantes al atacante o a la víctima. El cliente aplica los eventos de
  los remotos cuando su `render_tick` alcanza `tick`, y los propios al llegar.
- **DEBUG_COMMAND** ampliado (TEC-19): un registro de comandos del servidor (`CommandRegistry`) en
  el que cada sistema registra los suyos con nombre, argumentos y si exige `--debug-commands`; se
  invocan por red (`command` = id del registro) o por la consola del servidor (stdin). Comandos de
  la fase 3: `teleport`, `heal`, `kill`, `stamina_inf`, `reset_cooldowns`, `set_weapon`,
  `spawn_dummy`, `announce`, `kick`, `shutdown <s>`. Cada uso queda en el log.
- `sim_hash` incluye `CombatCatalog.prediction_hash()`.

---

## 7. PNJ y maniquí (MUN-02, CMB-11)

- Tipo `NPC` en `NetEntity`, con el mismo registro de 21 B. Su cuerpo es un `PlayerCharacter`
  simulado por el servidor con entrada sintética (`NpcBrain`); se graba en `StateHistory` y los
  golpes rebobinados le alcanzan igual.
- **Maniquí de entrenamiento**: NPC fijo con vida que se reinicia a los 5 s sin daño, con modos
  quieto, bloqueando y girando (comando `spawn_dummy`). Uno en `test_world` y uno junto a cada
  campamento del Vado Gris (marcadores del grupo `dummy_points`).
- **Registro de combate** (`--combat-log=<csv>`): `tick, atacante, objetivo, ataque, view_tick,
  rebobinado, resultado, daño`.

---

## 8. Cliente (UI-10, UI-12, UI-13, UI-14, ART-06, ART-08, ART-09)

- **`CombatFeedback`** (cliente): recibe los ENTITY_EVENT ya temporizados y reparte: marcador de
  impacto y número de daño (UI-12), destello y sacudida (ART-09), sonidos (ART-11), registro.
- **HUD** (UI-10): vida (autoritativa, del bloque extra) y resistencia (predicha, del estado
  local) abajo al centro, tramo fantasma, parpadeo al fallar por falta de resistencia, arcos de
  dirección del daño.
- **Placas** (UI-07 y UI-13): nombre, color de reino y, para enemigos apuntados o dañados en los
  últimos 5 s y para aliados, barra de vida desde `health_q`.
- **Muerte** (UI-14): HUD atenuado, quién te derrotó, cuenta atrás hasta `respawn_tick`.
- **Animación** (ART-08): capa de combate sobre la locomoción en `CharacterAnimator`, que lee
  `action`/fase/combo del estado local o del byte `action` de los remotos. Clips de UAL1/UAL2
  (`Sword_Attack`, `Roll`, `Hit_Chest`, `Death01`...) reescalados a la duración de cada fase. El
  ajuste fino de los clips y la composición visual quedan para el usuario (ver el informe).
- **Armas** (ART-06): de momento, mallas provisionales (caja para la espada, cilindro aplanado para
  el escudo) colgadas de los huesos de las manos con `BoneAttachment3D`, hasta que lleguen los
  modelos.

---

## 9. Plan de archivos y paquetes

| Paquete | Contenido | Depende de |
|---|---|---|
| **K1 · datos y simulación** | `AttackDefinition`, `WeaponDefinition`, `DodgeDefinition`, `HitShape`, `CombatCatalog`, `CombatRules`, `data/combat/*.tres`; `PlayerState` ampliado; `ActionMachine` y su llamada desde `simulate()`; `hit_shapes.gd`, `damage_formula.gd`, `FactionRules`, modo PvP en `Zones`; `last_landing_speed`; `sim_hash` con el catálogo | fase 2 |
| **K2 · protocolo** | `PROTOCOL_VERSION = 2`, registro de 21 B, bloque extra, ENTITY_EVENT, `CommandRegistry` y DEBUG_COMMAND ampliado | K1 |
| **K3 · servidor** | `Combatant`, `CombatResolver` con rebobinado, banderas defensivas en `StateHistory`, `DamageLedger`, muerte, reaparición, daño por caída, zonas seguras, NPC y maniquí, `--combat-log`, comandos | K1, K2 |
| **K4 · cliente** | aplicación de eventos por `render_tick`, `CombatFeedback`, HUD de vida y resistencia, marcador y números, placas con nombre y vida, pantalla de muerte, capa de animación de combate, armas provisionales | K1, K2 |
| **K5 · integración** | loopback con NetSim (95 % de acierto con rtt=150 contra un objetivo que se mueve en lateral, rechazo por encima de 24 ticks), `BotBrain` de combate, carga con refriegas de 32/64 bots, demo del sandbox con el combo | K3, K4 |

Pruebas mínimas por paquete: repetición determinista con acciones a medias (K1), ida y vuelta de
todos los mensajes nuevos con sus tamaños (K2), matriz de bloqueo/parada/esquiva con rebobinado y
muerte/reaparición (K3), eventos aplicados en su tick de dibujo (K4) y las de integración (K5).

---

## 10. Riesgos

- **Coste de `simulate()`**: la máquina de acciones añade trabajo por personaje. Se mide en K5
  contra los ~100 µs de la fase 2.
- **Parada con latencia**: 6 ticks de ventana con 150 ms de RTT puede ser una lotería. Se mide en
  CMB-29; si no funciona, pasa a habilidad del escudo.
- **Animación**: los clips gratuitos no cubren impacto en bloqueo ni esquiva lateral (arte.md). Se
  usan sustitutos y se anota.
- **Tamaño del estado**: 65 B de estado propio por snapshot (30 más) a 30 Hz: ~1 KB/s más por
  cliente, asumible.
