# Eldmark · Fase 4: diseño de habilidades, efectos, armas y proyectiles

Diseño corto de la ampliación del combate que anuncia [fuerte.md 10](fuerte.md#10-ampliación-del-combate-otro-diseño-corto):
habilidades con reutilización (CMB-19), efectos de estado (CMB-20), espada y escudo (CMB-21), proyectiles
con rebobinado (CMB-22), arco (CMB-23), cambio de arma (CMB-24), derribado (CMB-28), equipo mínimo
(PRG-04), plantillas (PRG-07), consumibles (PRG-08), barra de acciones (UI-11) e iconos de estados
(UI-45). Continúa [combate.md](combate.md) (sus §1, §3, §4 y §6 se dan por leídos), [red.md](red.md) (§6,
§8, §10, §14) y el orden del tick de [fuerte.md 1.7](fuerte.md#17-orden-del-tick-completa-combatemd-42).

Versión 1, escrita de noche. Lo marcado «comprobado» sale de sondas en Godot 4.7.2 headless (no se suben).

Convivencia con F4 (PNJ, en curso a la vez), que añade armas `data/combat/npc_*.tres` y
`AttackDefinition.unblockable` (solo servidor): **ningún id del catálogo es fijo**, todo se pide por
nombre (`CombatCatalog.ability_id(&"shield_bash")`), y los PNJ usan habilidades y efectos como un
jugador (`NpcBrain` pulsa `ABILITY_n`; su arma puede llevar `abilities`).

---

## 0. Decisiones

Las cuatro primeras eran pendientes del backlog que bloqueaban; se toman con su recomendación
(**provisional, tomada de noche**) y pasan a «Decisiones tomadas» de [backlog.md](backlog.md).

| Pregunta | Decisión |
|---|---|
| Recurso de las habilidades | Solo reutilización en las armas físicas; maná solo en los bastones (fase 6). La resistencia sigue siendo el recurso defensivo. *Provisional, tomada de noche.* |
| Origen y dirección de los proyectiles | Rayo de cámara canónico desde `look_yaw`, `look_pitch` y un bit de hombro; la flecha sale del pecho hacia el punto apuntado. *Provisional, tomada de noche.* |
| Derribado | Solo en PvP: si el golpe mortal es de un jugador de otro reino, se queda derribado 20 s. Contra PNJ, el entorno o en PvE, muerte directa. *Provisional, tomada de noche.* |
| HUD y recurso secundario | Disposición de acción: vida, resistencia y barra abajo al centro; la resistencia se oculta llena; el hueco del recurso secundario queda reservado para los bastones. *Provisional, tomada de noche.* |
| Cuándo empieza la reutilización | En el **compromiso**: el primer tick activo de la habilidad. Las canalizaciones la fijan al acabar. Un control o una esquiva antes del compromiso no la gastan. |
| Pociones | Dos fijas (vida en R, resistencia en T), reutilización compartida de 20 s y cargas por vida de la plantilla. Se gastan al acabar de beber: un golpe que interrumpe no gasta la poción. |
| Arco | El ligero es el disparo rápido y la carga del fuerte es el tensado: la máquina de la fase 3 sin cambios de forma. Sin bloqueo. Sin dispersión aleatoria: la precisión es la balística. |
| Proyectiles en red | Sin registros en el snapshot: ENTITY_SPAWN y ENTITY_DESPAWN fiables con la balística (§5.3); el cliente calcula el vuelo. 40 flechas en el aire costarían 840 B por snapshot. |
| Flecha propia | Se ve al instante (predicha); marcador y número al confirmar, como el cuerpo a cuerpo. |
| Cambio de arma | Q, 0,4 s; el arma cambia en el primer tick; conserva las reutilizaciones (ticks absolutos). Arma activa en `CombatState` y en el bit 3 de `flags` del registro. |
| Plantillas | Escudero (espada y escudo) y tirador (arco y espada y escudo). Se eligen antes de entrar o en la pantalla de muerte; valen en la siguiente aparición. |
| Equipo | Solo las dos armas. Armaduras, `StatBlock` y hoja derivada quedan para PRG-01 y PRG-06 (§9). |
| Efectos que mueven | Dos ranuras en `CombatState` (ralentizar, enraizar); el resto vive en el servidor. |
| Golpe de escudo | Imbloqueable (`AttackDefinition.unblockable`, de F4) y aturde 0,8 s. Se esquiva. |
| Muro de escudos | Bloqueo de 180° y una caja que para los proyectiles enemigos: protege de flechas a los de detrás, no de golpes. |
| Interrupción | Solo un impacto con daño (no bloqueado) corta beber, levantar, rematar y los lanzamientos marcados. Los controles cortan cualquier acción, como hoy. |
| Fuego amigo | Sigue sin haber: flechas y áreas atraviesan a los aliados. |
| Teclas nuevas | Q cambiar de arma, R poción de vida, T poción de resistencia. Se reasignan con UI-17. |

---

## 1. Qué se predice y qué decide el servidor

| Dato | Dónde vive | Predicho | Viaja en |
|---|---|---|---|
| Habilidad en curso: acción ABILITY, id, tick, dirección del avance | `CombatState` | Sí | estado propio; byte de acción de los remotos (§5.5) |
| Reutilizaciones (6 ticks absolutos), la de los consumibles y las cargas | `CombatState` | Sí; el servidor solo las impone al aparecer o recargar | estado propio |
| Arma activa y la de la otra ranura | `CombatState` | El cambio, sí; la pareja la impone el servidor (plantilla) | estado propio; SPAWN público; bit 3 de `flags` del registro; LOADOUT |
| Ralentizar y enraizar (2 ranuras) | `CombatState`, **impuestos por el servidor** | No: se adoptan al reconciliar; su efecto en la velocidad sí se predice | estado propio; STATUS |
| Sangrado, curación en el tiempo, más daño, menos mitigación | `Combatant` (`StatusSystem`) | No | STATUS, HIT (pulso), HEAL |
| Golpes de habilidad, áreas y embestida | `CombatResolver` | No | HIT |
| Proyectiles | `ProjectileSystem` | Solo la flecha propia, como imagen | SPAWN y DESPAWN de kind 3 |
| Derribado, levantar y rematar | `CombatState` (acciones **impuestas**) y `Combatant` | Ni el inicio ni el desenlace; sí el movimiento y el fin de levantar o rematar al soltar o por tiempo | estado propio; DOWNED; INTERACT |
| Vida de derribado | `Combatant` | No | bloque extra (bit 3 de `status`), `health_q` |
| Curación de la poción | `StatusSystem` | No | STATUS, HEAL |
| Resistencia de la poción | `CombatState` | Sí | estado propio |

Regla de red.md §6.7: lo que decide el servidor y cambia la simulación entra en `PlayerState`, aunque
no se prediga (efectos de movimiento, derribado).

---

## 2. Datos

### 2.1 Recursos (`scripts/shared/combat/`, datos en `data/combat/`)

Segundos en los `.tres`, ticks al cargar con `roundi(s · 60)`. «P» = predicho (entra en
`prediction_hash`); «S» = solo servidor. Todo en la carpeta `data/combat/` (el catálogo no entra en
subcarpetas y distingue por tipo).

```gdscript
class_name AbilityDefinition extends Resource
@export var id: StringName
# P · fases: lanzamiento [0, cast), activo [cast, cast+active), recuperación hasta el total.
@export var cast_s: float = 0.0; @export var active_s: float = 0.1   # en una canalización, su tope
@export var recovery_s: float = 0.3         # 0 en las canalizaciones
@export var cooldown_s: float = 10.0        # 0 en los consumibles (usan la compartida)
@export var channel: bool = false           # el activo es una canalización
@export var channel_hold: bool = true       # soltar el botón de su ranura la acaba
@export var channel_breaks_on_move: bool = false
@export var cancel_to_dodge_from_s: float = -1.0; @export var cancel_to_attack_from_s: float = -1.0
		# -1 = desde la recuperación
@export var move_speed_scale: float = 0.3; @export var turn_rate: float = 6.0; @export var lunge_speed: float = 0.0
@export var dash_distance_m: float = 0.0    # avance impuesto (0 = ninguno), horneado como la esquiva
@export var dash_from_s: float = 0.0; @export var dash_to_s: float = 0.0; @export var dash_curve: Curve
@export var dash_direction: int = 0         # 0 hacia look_yaw, 1 hacia atrás, 2 según move (como DODGE)
@export var usable_in_air: bool = false
@export var stamina_restore: int = 0        # al comprometer (poción de resistencia)
@export var blocks: bool = false            # la canalización bloquea (muro de escudos)
@export var projectile: ProjectileDefinition    # sale en el compromiso
@export var projectile_count: int = 1; @export var projectile_spread_deg: float = 0.0   # entre flechas
@export var projectile_speed_mps: float = 45.0
# S · golpe en cada tick activo (sin forma, no hay golpe) y efectos:
@export var shape: HitShape; @export var base_damage: int = 0; @export var damage_type: int = 0
@export var stagger_s: float = 0.0; @export var stun_s: float = 0.0; @export var knockback_speed: float = 0.0
@export var hyper_armor: bool = false; @export var unblockable: bool = false
@export var target_status: StatusEffectDefinition   # a quien golpea (también con su flecha)
@export var self_status: StatusEffectDefinition; @export var self_heal: int = 0   # al comprometer
@export var interrupt_on_damage: bool = false        # siempre true en los consumibles
@export var wall_half_extents: Vector3 = Vector3.ZERO   # caja que para proyectiles (canalización)
@export var wall_forward_m: float = 0.7

class_name StatusEffectDefinition extends Resource
enum Kind { DAMAGE_OVER_TIME, HEAL_OVER_TIME, SLOW, ROOT, DAMAGE_UP, MITIGATION_DOWN }
enum Stacking { REFRESH, STACK, STRONGEST }
@export var id: StringName; @export var kind: int; @export var duration_s: float
@export var stacking: int = Stacking.REFRESH; @export var max_stacks: int = 1
@export var move_speed_scale: float = 1.0   # P: SLOW (0 < x ≤ 1, o > 1 si acelera); ROOT = 0
@export var pulse_every_s: float = 1.0      # S: la duración, múltiplo exacto en ticks
@export var pulse_amount: int = 0           # S: por acumulación
@export var damage_type: int = 0            # S
@export var magnitude: float = 0.0          # S: DAMAGE_UP +fracción; MITIGATION_DOWN −fracción

class_name ProjectileDefinition extends Resource     # P entera: balística de la flecha predicha
@export var id: StringName; @export var gravity: float = 6.0   # m/s² hacia abajo
@export var radius_m: float = 0.05; @export var lifetime_s: float = 2.0

class_name EquipmentTemplate extends Resource        # ni P ni S: la impone el servidor
@export var id: StringName
@export var weapons: Array[WeaponDefinition]        # 1 o 2, en orden de ranura
@export var consumable_charges: PackedInt32Array = PackedInt32Array([3, 2])   # 0–15 cada una
```

Cambios en los recursos existentes:

- `AttackDefinition`: `projectile` y `projectile_speed_mps` (P; con proyectil la forma puede ser nula y
  el ataque dispara en su primer tick activo), `charge_speed_scale` (P, velocidad a carga máxima, lineal
  desde ×1), `stun_s` y `on_hit_status` (S). `unblockable` lo añade F4.
- `WeaponDefinition`: `abilities: Array[AbilityDefinition]` (0–3, la posición es la ranura) y
  `can_block: bool = true` (P). `light_combo` admite de 1 a 3 golpes.
- `CombatRules`. P: `swap_s` 0,4, `swap_move_scale` 0,8, `downed_move_scale` 0,15, `downed_turn_rate` 3,
  `revive_s` 3, `execute_s` 1, `consumables: Array[AbilityDefinition]` (exactamente 2),
  `consumable_cooldown_s` 20, `aim_pivot_height` 1,6, `aim_shoulder_offset` 0,6, `aim_range_m` 150,
  `muzzle_height` 1,4. S: `downed_health` 400, `downed_s` 20, `revived_health` 300,
  `interact_range_m` 2,0, `interact_keep_range_m` 2,5, `ability_block_angle_deg` 180,
  `ability_block_stamina_per_damage` 0,6, `max_projectiles_per_shooter` 8, `max_projectiles_per_zone`
  256, `default_template` (escudero).

### 2.2 Catálogo

- **Ids**: espacios separados para ataques, armas, habilidades, efectos, proyectiles y plantillas;
  1..n por orden alfabético de `id`, 0 = ninguno. Efectos y plantillas caben en u8 (≤ 255; más es un
  error). Nadie escribe un id a mano: `ability_id(name)`, `status_id(name)`, `projectile_id(name)`,
  `template_id(name)`. Los de F4 (`npc_*`) solo desplazan números.
- **`AbilityTicks`** guarda además `slot` (0–2) y `weapon_id`, o `consumable_index` (0–1) si es un
  consumible, y `hit: AttackTicks`: un ataque **sintetizado** con las ventanas de la habilidad
  (anticipación = `cast`) y sus campos S, que no está en la tabla de ataques. Así el resolutor prueba
  igual un ataque que el golpe de una habilidad (§4.2). Su `id` es la fuente de la habilidad (§5.4).
- **Avance**: `dash_curve` se hornea como la esquiva: velocidad f32 por tick entre `dash_from` y
  `dash_to` que suma `dash_distance_m`.
- **Validación** (errores en `CombatTables.errors`): una habilidad en un solo arma o en los consumibles;
  `cooldown_ticks ≥ total_ticks + 1` (dos usos de la misma ranura nunca se encadenan sin NONE: lo
  necesita el byte de acción); canalización sin recuperación; consumible con `cooldown_s` 0 y
  `consumable_cooldown_ticks > total` de cada consumible; duración de un efecto con pulsos múltiplo de
  `pulse_ticks`; ROOT con escala 0, SLOW con escala > 0; ventana del avance dentro de la habilidad;
  `lifetime_ticks ≥ 1`; `projectile_count` 1–5.
- **`prediction_hash`** (`_HASH_FORMAT` pasa a 2) añade: los campos P de reglas, ataques, armas y
  habilidades (con el avance horneado), id, tipo y `move_speed_scale` de cada efecto, y los proyectiles.
  No entran: daños, formas, controles, pulsos, derribado, interacción, muros ni plantillas.

### 2.3 Valores de partida

Espada y escudo (`sword_shield.tres` gana `abilities`). Ticks entre paréntesis.

| Habilidad | Ranura | Lanz. | Activo | Recup. | Reutil. | Efecto |
|---|---|---|---|---|---|---|
| Golpe de escudo `shield_bash` | 1 | 0,3 (18) | 0,1 (6) | 0,4 (24) | 12 s | sector 2,2 m, 90°, 0,2–2,0 m; 60 contundente; **aturde 0,8 s (48)**; imbloqueable; avance 1 m/s, movimiento ×0,2, giro 6 |
| Embestida `shield_rush` | 2 | 0,15 (9) | 0,4 (24) | 0,35 (21) | 16 s | avance de 6 m en el activo (curva plana); sector 1,8 m, 140°; 50 contundente; tambaleo 0,4 s y empuje 6 m/s; entereza en el activo |
| Muro de escudos `shield_wall` | 3 | 0,2 (12) | hasta 6 s (360), canalizada | 0 | 18 s al acabar | bloqueo de 180° (resistencia 0,6 por punto); caja 2,6 × 2,0 × 0,3 m a 0,7 m delante que para flechas enemigas; movimiento ×0,3, giro 4; se suelta con 3; esquiva desde el fin del lanzamiento |

Arco (`bow.tres`, `bow_quick.tres`, `bow_drawn.tres`; esquiva = `sword_dodge.tres`; `can_block = false`).

| Acción | Tiempos | Proyectil | Daño | Otros |
|---|---|---|---|---|
| Disparo rápido (ligero, combo de 1) | anticipación 0,25 (15), activo 1/60 (1), recup. 0,35 (21): 37 ticks | 45 m/s | 60 perforante | movimiento ×0,5, giro 8, a esquiva desde 0,27 (16) |
| Tensado (fuerte) | carga 0,35–1,0 s (21–60) desde la pulsación; tras soltar 0,05 (3) + 1 + 0,3 (18) | 40 → 70 m/s (`charge_speed_scale` 1,75) | 90 → 180 (×2,0) | carga: movimiento ×0,5, giro 8; sin resistencia |
| Abanico `bow_volley` (1) | 0,3 (18) + 1 + 0,4 (24); reutil. 10 s | 3 flechas a ±7°, 45 m/s | 55 cada una | |
| Flecha lastrante `bow_slowing_shot` (2) | 0,35 (21) + 1 + 0,3 (18); reutil. 12 s | 55 m/s | 60 | `slowed` al golpear |
| Salto atrás con disparo `bow_evasive_shot` (3) | lanzamiento 0,3 (18) con avance de 4 m hacia atrás en [0, 0,3); dispara al comprometer; recup. 0,25 (15); reutil. 14 s | 50 m/s | 60 | |

`arrow.tres`: gravedad 6 m/s², radio 0,05 m, 2 s de vida (90 m a 45 m/s; 140 m a 70).

Consumibles (`CombatRules.consumables`), reutilización compartida de 20 s (1200):

| Poción | Beber | Movimiento | Al comprometer |
|---|---|---|---|
| Vida `potion_health` (R) | 0,6 (36) + 1 + 0,2 (12) | ×0,4, sin esprint ni salto | `potion_regen`: 300 de vida en 3 s |
| Resistencia `potion_stamina` (T) | 0,4 (24) + 1 + 0,2 (12) | ×0,4 | +400 de resistencia (predicho) |

Efectos: `slowed` (SLOW ×0,6, 3 s, el más fuerte gana), `potion_regen` (curación 50 cada 0,5 s durante 3
s: 6 pulsos; renovar), `bleed` (15 por acumulación cada 1 s durante 6 s: 6 pulsos; hasta 3; cortante;
para armas de PNJ y pruebas), `rooted` (ROOT 1,5 s; pruebas). Plantillas: `squire` = [`sword_shield`],
cargas [3, 2]; `marksman` = [`bow`, `sword_shield`], cargas [2, 3].

### 2.4 Entrada para la hoja de equilibrio (combate.md §12)

Calculada con los datos de arriba, sin medir. H5 (§7) la mide con `tools/combat_balance.gd` y la
pasa a combate.md §12 como «12.8 Kits de la fase 4».

| Acción | Ciclo | Daño | DPS calculado |
|---|---|---|---|
| Combo de espada (referencia, 12.1) | 119 ticks | 310 | 156,3 |
| Disparo rápido repetido | 37 ticks | 60 | 97,3 |
| Tensado mínimo | 21 + 22 = 43 ticks | 90 | 125,6 |
| Tensado máximo | 60 + 22 = 82 ticks | 180 | 131,7 |
| Habilidades de espada y escudo, a reutilización | | 60 / 12 s + 50 / 16 s | +8,1 y 0,8 s de aturdimiento cada 12 s |
| Habilidades de arco, a reutilización | | 165 / 10 s + 60 / 12 s + 60 / 14 s | +25,8 si el abanico acierta entero |
| Poción de vida | 20 s | +300 | +15 de vida por segundo sostenido; 900 por vida (escudero) |

Vuelo del tensado máximo: 0,14 s a 10 m, 0,43 s a 30 m, 0,71 s a 50 m (caída de 1,5 m). Del rápido: 1,11
s y 3,7 m de caída a 50 m. El TTK objetivo de 12.5 (mediana 10–15 s) se vuelve a medir en 2 contra 2 con
bots y las dos plantillas.

---

## 3. Estado y máquina de acciones

### 3.1 `CombatState` v5

`CombatState.ENCODED_SIZE` pasa de 34 a **76 B** y `PlayerState.ENCODED_SIZE` de 69 a **111 B**. Los
offsets 35–68 no cambian; se añade al final (offsets dentro de `PlayerState`):

| Offset | Tipo | Campo | Qué es |
|---|---|---|---|
| 69 | u16 | `alt_weapon_id` | arma de la otra ranura (0 = ninguna) |
| 71 | u8 | `combat_flags2` | bit0 ranura 2 activa, bits 1–6 ABILITY_1/2/3, SWAP, CONSUMABLE_1/2 pulsados en el tick anterior, bit7 sin reutilizaciones (comando) |
| 72 | u32 × 3 | `ability_ready[0..2]` | primer tick en que vuelve a valer cada habilidad del arma activa |
| 84 | u32 × 3 | `ability_ready[3..5]` | ídem, arma de la otra ranura |
| 96 | u32 | `consumable_ready_tick` | reutilización compartida de los consumibles |
| 100 | u8 | `consumable_charges` | bits 0–3 poción 1, bits 4–7 poción 2 |
| 101 | u8 + u32 | `move_effect_ids[0]`, `move_effect_until[0]` | efecto de movimiento (0 = libre) y su fin (exclusivo) |
| 106 | u8 + u32 | `move_effect_ids[1]`, `move_effect_until[1]` | ídem |

Cambios en campos existentes:

- `action`: 9 ABILITY (habilidad o consumible), 10 SWAP, 11 DOWNED, 12 REVIVE, 13 EXECUTE (14 y 15
  libres). `action_id` es un ataque en LIGHT/HEAVY/CHARGE y una habilidad en ABILITY.
- `buffered` cambia de forma: **bits 0–3 tipo, bits 4–7 ticks que le quedan**. Tipos: 0 nada, 1
  PRIMARY, 2 DODGE, 3 enlace, 4–6 ABILITY_1–3, 7 SWAP, 8–9 CONSUMABLE_1–2. Toda lectura de `buffered &
  3` pasa a `buffered_type()`.
- `action_dir` guarda también la dirección del avance de una habilidad.

Reutilizaciones y efectos son ticks absolutos, como `cc_until_tick`: restaurar un estado no tiene
ambigüedad y el tiempo corre aunque el arma esté guardada. **Dos ranuras** bastan: en la fase 4 solo hay
`slowed` y `rooted` (de prueba); una tercera sustituye a la que acaba antes.

**Coste en bytes.** El estado propio va en cada snapshot del dueño: +42 B por snapshot. Cabecera con
estado y bloque extra: 13 + 111 + 9 + 1 = **134 B**; con una sección, ⌊(1200 − 136) / 21⌋ = **50
registros** (antes 52). Con 64 jugadores, 63 ajenos en 50 plazas: cada uno sale al menos uno de cada
⌈63/50⌉ = 2 snapshots, igual que con 52; con los ~10 PNJ del fuerte, 73 ajenos, también 2 (pasa a 3 con
más de 100 ajenos). Por debajo del tope, +42 B × 30/s = **+1,26 KB/s** por cliente; en el tope el
paquete ya iba lleno (36,8 KB/s): lo que se pierde son 2 registros por snapshot.

### 3.2 Botones y entradas sustituidas

`PlayerInput`: bit 9 `SWAP_WEAPON` (Q), bit 10 `AIM_LEFT` (hombro izquierdo: lo pone el cliente con el
hombro efectivo de la cámara; es un nivel, no una pulsación), bit 11 `CONSUMABLE_1` (R), bit 12
`CONSUMABLE_2` (T). Bits 13–14 reservados; 15 sigue siendo `SUBSTITUTED`. `VALID_BUTTONS = (1 << 13) −
1`. Con `SUBSTITUTED`, como en combate.md §3.2, la máquina no ve flancos (la sustituta repite los
botones), no corta una canalización por moverse y no suelta lo que se mantiene. Ninguna pérdida inventa
una habilidad, un cambio de arma ni una poción.

### 3.3 Reglas por tick

`ActionMachine.step()` con `t = input.tick`, orden fijo (amplía combate.md §3.3):

0. **Camino rápido**, como hoy, si además no hay ABILITY, SWAP ni CONSUMABLE pulsados (`AIM_LEFT` no
   cuenta) ni sus bits en `combat_flags2`, ni ninguna ranura de movimiento ocupada.
1. **Fin de acciones**, como hoy y además: ABILITY a NONE en `t ≥ action_tick + total` (canalización:
   en `t ≥ action_tick + cast + active`, con su reutilización, regla 5); SWAP en `t ≥ action_tick +
   swap_ticks`; REVIVE y EXECUTE en `t ≥ action_tick + revive_ticks` / `execute_ticks`. DOWNED y DEAD no
   terminan solos.
2. **Efectos de movimiento**: se vacía la ranura con `move_effect_until ≤ t`.
3. **Resistencia**, como hoy; tampoco regenera en una canalización que bloquea.
4. **Entradas** (flancos con los bits de `combat_flags` y `combat_flags2`, sin `SUBSTITUTED`). En
   DOWNED y DEAD solo se borran búfer y pulsación. Primero el búfer; después, **DODGE > ABILITY_1 >
   ABILITY_2 > ABILITY_3 > CONSUMABLE_1 > CONSUMABLE_2 > PRIMARY > SWAP > BLOCK**. Un flanco que no se
   puede ejecutar ahora va al búfer (una ranura, la última gana); se descarta si no tiene sentido
   (ranura vacía, sin cargas, sin arma alternativa, `can_block` falso, avance con ROOT).
   - **DODGE**: como hoy y además desde ABILITY a partir de su `cancel_to_dodge_from` y desde REVIVE y
     EXECUTE (los corta). No con ROOT. Desde una canalización, la acaba (regla 5).
   - **ABILITY_n**: hay habilidad en la ranura; `t ≥ ability_ready[n]` (o bit7); acción que lo permite:
     NONE, BLOCK, CHARGE (cancela la carga sin gastar), DODGE desde `cancel_to_attack_from`, LIGHT y
     HEAVY en su recuperación, ABILITY en su recuperación o desde su `cancel_to_attack_from`; en el
     suelo salvo `usable_in_air`. Empieza: `action = ABILITY`, `action_id`, `action_tick = t`,
     `action_dir` según `dash_direction` (con `move` y `look_yaw` de este tick), `combo_step = 0`,
     `charge_ticks = 0`, sin enlace ni `FLAG_LIGHT_OF_PRESS`. En reutilización: al búfer (vale si se
     acaba en los 8 ticks siguientes).
   - **CONSUMABLE_n**: igual, con `t ≥ consumable_ready_tick` y cargas > 0.
   - **PRIMARY**: como hoy; también desde ABILITY en recuperación. Con el arco, el ligero es el disparo
     rápido y mantener lo convierte en tensado (combate.md §3.3, sin cambios).
   - **SWAP**: `alt_weapon_id ≠ 0`; desde NONE, BLOCK, la recuperación de LIGHT, HEAVY o ABILITY y DODGE
     desde `cancel_to_attack_from`; también en el aire. Empieza: `action = SWAP`, `action_tick = t`,
     intercambia `weapon_id ↔ alt_weapon_id` y `ability_ready[0..2] ↔ [3..5]`, invierte el bit0 de
     `combat_flags2`, `combo_step = 0`. Nunca a mitad de anticipación, golpe activo, carga, lanzamiento
     o canalización: va al búfer.
   - **BLOCK**: como hoy, solo si `can_block`.
   - **Canalización en curso** (ABILITY con `channel` y `t ≥ action_tick + cast`): con `channel_hold`,
     una entrada real sin el botón de su ranura la acaba; con `channel_breaks_on_move`, una entrada real
     con `|move| ≥ 0,1` también.
   - **INTERACT** no empieza nada aquí (levantar y rematar los empieza el servidor, §4.5); en REVIVE o
     EXECUTE, una entrada real sin INTERACT los acaba (a NONE).
   - **Búfer**: la pulsación del tick `p` vale en `p+1 … p+8` y se ejecuta con prioridad sobre las nuevas.
5. **Compromiso** (tras las entradas): si `action == ABILITY` y `t == action_tick + cast_ticks`:
   consumible → su carga − 1 y `consumable_ready_tick = t + consumable_cooldown_ticks`; habilidad sin
   canalización → `ability_ready[slot] = t + cooldown_ticks`; en los dos, resistencia +
   `stamina_restore` (sin pasar del máximo). Con `cast = 0` se compromete en el tick en que empieza. Una
   canalización fija `ability_ready[slot] = t_fin + cooldown_ticks` en el tick en que acaba, por la causa
   que sea (también si la corta el servidor, §3.5). Con el bit7 no se fija nada ni se gastan cargas.
6. **Salida de movimiento** (§3.4).

### 3.4 Movimiento permitido

Amplía la tabla de combate.md §3.3:

| Acción | Velocidad horizontal objetivo | Giro | Salto | Esprint |
|---|---|---|---|---|
| ABILITY lanzamiento y activo | `wish · run · move_scale + forward · lunge` | hacia `look_yaw` a `turn_rate`; en el primer tick salta a `look_yaw` | no | no |
| ABILITY en su ventana de avance | **impuesta**: `dir(action_dir) · dash[t − action_tick − dash_from]` | ninguno | no | no |
| ABILITY recuperación | `wish · run · move_scale` | ninguno | no | no |
| ABILITY canalización | `wish · run · move_scale` | hacia `look_yaw` a `turn_rate` | no | no |
| SWAP | `wish · run · swap_move_scale` | el normal | no | no |
| DOWNED | `wish · run · downed_move_scale` | hacia `look_yaw` a `downed_turn_rate` | no | no |
| REVIVE, EXECUTE | frena | ninguno | no | no |

**Efectos.** `Output.speed_factor` = (menor escala < 1 de las ranuras, o 1) × (mayor escala > 1, o 1)
multiplica la velocidad objetivo **no impuesta** en todas las acciones, NONE y el esprint incluidos; la
esquiva, el avance y el empuje no. ROOT (escala 0) pone además `rooted`: sin salto, y en el aire frena
como `move_scale` 0. El arco tensando usa la fila CHARGE de siempre.

### 3.5 Lo que impone el servidor

Todas seguidas de `CombatDirector.commit_state` (redondeo por `encode/decode`). Las de combate.md §3.4
cambian así: `impose_stagger` e `impose_stun` no hacen nada sobre DOWNED ni DEAD; todas las que cambian la
acción, si cortan una canalización comprometida, fijan su reutilización en ese tick.

- `impose_downed(c, t)`: DOWNED, borra búfer, pulsación, combo y ranuras de movimiento.
- `impose_revived(c, t)`: NONE con `action_tick = t`.
- `impose_interact(c, t, action)`: REVIVE o EXECUTE con `action_tick = t`.
- `impose_interrupt(c, t)`: NONE (corta beber, un lanzamiento marcado, REVIVE o EXECUTE); antes del
  compromiso no hay reutilización ni gasto.
- `impose_move_effect(c, effect_id, until_tick)`: mismo id → `until = max`; si no, ranura libre; si no,
  sustituye a la que acaba antes.
- `clear_move_effects(c)`, `reset_cooldowns(c)`.
- `set_loadout(c, weapon_1, weapon_2, charges)` y `reset_for_respawn(c, t, weapon_1, weapon_2,
  charges)`: armas en orden de ranura (activa la 1), reutilizaciones a 0, cargas, ranuras vacías; se
  conservan los bits de botones pulsados.

### 3.6 Consultas

`phase(c, t)`: en ABILITY, 0 lanzamiento, 1 activo o canalización, 2 recuperación; en SWAP, DOWNED,
REVIVE y EXECUTE, 3. `active_hit(c, t) -> AttackTicks` (el ataque en golpe activo o el golpe
sintetizado de la habilidad en su activo; null si no hay). `is_commit_tick(c, t)` (primer tick activo de
LIGHT, HEAVY o ABILITY). `ability_status(c, slot, t)` (READY, COOLDOWN, BLOCKED, EMPTY, NO_CHARGES; para
la barra). `defense_flags`: la canalización que bloquea da `DEFENSE_BLOCKING | DEFENSE_WIDE_BLOCK` (bit 7
de `StateHistory`, libre hasta hoy); DOWNED no da ninguna defensa.

---

## 4. Servidor

### 4.1 Orden del tick (completa fuerte.md §1.7)

| Paso | Qué | En fuerte.md |
|---|---|---|
| 0 | Cerebros de PNJ (F4) | 0 |
| 1 | Simular a todos por `net_id` | 1 |
| 2 | Congelar: posición, giro, defensa, acción, `active_hit`, compromiso y muro de cada uno | 2 |
| 3 | **Disparos y efectos propios** de quien está en su compromiso, por `net_id`: proyectiles nuevos (§4.4), `self_status` y `self_heal` (HEAL) | — |
| 4 | **Resolver** sin tocar estado: golpes de ataques y habilidades contra lo congelado y el historial, puertas, y el vuelo de todos los proyectiles vivos (también los del paso 3) | 3 |
| 5 | **Aplicar** por `net_id` del atacante (primero sus golpes, después sus proyectiles por id) y del objetivo: daño, bloqueo, controles, `target_status`, interrupciones, derribos y muertes; DESPAWN de las flechas que impactan | 4 |
| 6 | **Efectos de estado**: pulsos y caducidades, por `net_id` del afectado y después por id de efecto | 4 |
| 7 | **Derribado**: desangrado, INTERACT nuevos, progreso y final de levantar y rematar | 4 |
| 8 | Entorno, reapariciones (con plantilla) y recarga de consumibles en el campamento (cada 60 ticks) | 4 |
| 9 | Publicar: vida, estado, byte de acción y ranura activa | 4 |
| 10 | `FortressController.step(s)` | 4b |
| 11 | Altas, historial, snapshots, OBJECT_STATE, eventos y SPAWN/DESPAWN de proyectiles | 5 |

Un derribado o un muerto en el paso 5 no recibe más golpes de ese tick: todos se resolvieron contra el
mismo estado, como las muertes de hoy.

### 4.2 Habilidades

- **Golpe con forma propia** (golpe de escudo): el golpe sintetizado pasa por el mismo camino que un
  ataque: rebobinado fijado en el primer tick activo, candidatos, forma, línea de visión y defensas de
  combate.md §4.3. `unblockable` salta parada y bloqueo. Aplicar: `stun_ticks` → `impose_stun`; si no,
  tambaleo y empuje como hoy; `hyper_armor` y la cadena de controles, igual.
- **Embestida**: el avance lo simula `simulate()` (predicho, choca con muros); el golpe se prueba en
  cada tick activo, cada objetivo una vez por acción, con empuje radial.
- **Área**: frontal = sector; centrada = `angle_deg ≥ 360` (sin cono, ya lo trata `HitShapes`).
- **Efecto propio**: en el paso 3, una vez (el compromiso cae en un solo tick).
- **Muro de escudos**: melé con `DEFENSE_WIDE_BLOCK` → cono de `ability_block_angle_deg` y gasto de
  `ability_block_stamina_per_damage`; para los proyectiles, además, la caja (§4.4). La muestra antigua
  cuenta con la regla de combate.md §4.3.
- **Puertas**: los golpes de habilidad prueban las puertas igual que los ataques.
- **Interrupción**: un IMPACTO con daño > 0 a quien está en el lanzamiento de una habilidad con
  `interrupt_on_damage`, bebiendo, en REVIVE o en EXECUTE → `impose_interrupt` (si el golpe no impone
  ya un control). HIT con el bit 5.

### 4.3 Efectos de estado (`StatusSystem`, `scripts/server/status_system.gd`)

- Cada `Combatant` lleva hasta 8 `ActiveEffect`: `status_id`, `source_id`, `anchor_tick`, `until_tick`,
  `stacks`. Uno nuevo cuando ya hay 8 sustituye al que acaba antes.
- **Aplicar** en `s`: `REFRESH` → `until = s + D` (el ancla no cambia); `STACK` → `stacks = min(stacks +
  1, max)` y `until = s + D`; `STRONGEST` → solo si es más fuerte (menor escala en SLOW/ROOT, más
  `pulse_amount` o `magnitude`), y si es igual, `until = max`. Nuevo: `anchor = s`, `stacks = 1`.
  SLOW y ROOT escriben además su ranura (`impose_move_effect`). Evento STATUS 1.
- **Pulsos exactos**: en `anchor + k · P` para `k = 1, 2, …` mientras `anchor + k · P ≤ until`. Sin
  renovar, N = D / P (6 en `bleed`). El último pulso y la caducidad caen en el mismo tick: primero el
  pulso. DOT: `pulse_amount × stacks` de su tipo, sin bloqueo ni crítico, con los modificadores →
  HIT con la fuente del efecto y el atacante `source_id` (puede derribar y matar). HOT: cura sin pasar
  del máximo → HEAL. Los PNJ inmortales siguen sin bajar de 1.
- **Caducidad**: en `s ≥ until` se quita (STATUS 2); la ranura de movimiento ya la vacía la simulación
  en el mismo tick.
- **Modificadores**: `DamageFormula.compute(..., damage_scale = 1 + Σ DAMAGE_UP del atacante,
  mitigation_penalty = Σ MITIGATION_DOWN de la víctima)`; la mitigación del bloqueo baja en esa
  fracción (mínimo 0).
- **Limpieza**: al morir, al quedar derribado y al reaparecer se borran todos, sin STATUS sueltos
  (DEATH, DOWNED y RESPAWN los borran en el cliente). No se aplican efectos a un derribado.

### 4.4 Proyectiles (`ProjectileSystem`, `scripts/server/projectile_system.gd`)

**Disparo** (paso 3), por cada proyectil del ataque o la habilidad que compromete en `s`:

1. **Rebobinado**: el de combate.md §4.3 paso 2, fijado ahora y para todo el vuelo (`rewind` y
   `defense_rewind`; se factoriza de `CombatResolver._swing_rewind`). Rechazado → flecha **inofensiva**
   (vuela y choca con el mundo, no prueba personajes), sospecha + 1 y registro. También es inofensiva
   si el tirador está en la zona segura de su reino. Falsos y PNJ: sin rebobinado.
2. **Puntería** con la entrada de `s` (`InputQueue.get_applied(s)`): `AimRay.canonical(pies, look_yaw,
   look_pitch, AIM_LEFT)` da el rayo de la cámara canónica: base `B = Basis(UP, yaw) · Basis(RIGHT,
   pitch)`, dirección `B · FORWARD` y origen `pies + (0, aim_pivot_height, 0) + B · (±aim_shoulder_offset,
   0, 0)` (el punto del rayo a la altura del pivote: lo que hay detrás del personaje no cuenta). Punto
   apuntado `P`: el más cercano entre el mundo (`LINE_OF_SIGHT_MASK`) y las cápsulas hostiles muestreadas
   en `s − rewind`, hasta `aim_range_m`. La salida es el pecho, `O = pies + (0, muzzle_height, 0)`;
   `dir = (P − O).normalized()`, girada en yaw por los desfases del abanico; `v0 = dir · velocidad ·
   lerp(1, charge_speed_scale, f)`, con la `f` de la carga del daño (combate.md §4.4; 0 sin carga).
3. **Redondeo**: `O` y `v0` se cuantizan como viajan en el SPAWN (1 cm, 1 cm/s) y el servidor vuela con
   eso, para que la trayectoria del cliente sea la misma.
4. **Alta**: id del espacio de `NetEntityRegistry` (`allocate_transient_id`, misma cuarentena de 600
   ticks) sin entrar en su lista de entidades; SPAWN a quien tiene relevante al tirador y a él. Tope de 8
   vivos por tirador (sale el más viejo, DESPAWN 5) y 256 por zona (no se crea; registro).

Comprobado: `Camera3D.h_offset` desplaza el origen del rayo del centro sin girarlo; zoom y colisión del
brazo (a lo largo del rayo) no cambian la línea, solo el hombro y el tirón lateral contra una pared.

**Vuelo**, con `Ballistics.position(p0, v0, g, n) = p0 + v0 · n/60 + (0, −½ · g · (n/60)², 0)` en f64. En
el tick `k`, con `n = k − spawn_tick`, se prueba el segmento `[pos(n), pos(n + 1)]` (en el propio tick
del disparo, el primero):

- **Mundo**: `intersect_ray` contra `LINE_OF_SIGHT_MASK` (mundo y puerta; no los bloqueos invisibles).
  Segmentos contiguos: no hay túnel. Si el cuerpo golpeado es de un `StructureTarget` que el tirador
  puede dañar (`get_body_rids`), es un golpe a la puerta (perforante ×0,2).
- **Muros**: las cajas de los muros de escudos de entidades hostiles al tirador, en su estado congelado
  (`HitShapes.segment_box_fraction`).
- **Personajes**: candidatos de combate.md §4.3 paso 4 (hostiles, vivos o derribados, sin protección ni
  zona segura), muestreados en `k − rewind`; segmento contra cápsula de radio 0,4 + `radius_m`
  (`HitShapes.segment_capsule_fraction`).
- Gana la fracción menor. Personaje: invulnerable en `[floor(k − defense_rewind), k]` → sigue volando y
  no vuelve a probarlo; bloqueo (normal o del muro) con el cono frente a `−velocidad` → BLOCKED; nunca parada;
  si no, IMPACTO con daño de la fuente (con su carga), controles y `target_status`. Muro → BLOCKED al
  que canaliza. Mundo → se clava.
- Sin impacto y `n + 1 ≥ lifetime_ticks`, o `y < −100` → DESPAWN 5 (caduca).
- **Esquinas**: la flecha sale del pecho, dentro de la cápsula del tirador, que nunca solapa un muro.
  Si la cámara ve más allá de una esquina que el pecho no ve, el segmento hacia `P` choca con la esquina:
  no sale por el lado de la cámara. Comprobado: un rayo que empieza dentro de una caja la ignora
  (`hit_from_inside` falso), así que el origen del rayo de puntería dentro de una pared no la detecta.

### 4.5 Derribado, levantar y rematar (`DownedSystem`, `scripts/server/downed_system.gd`)

- **Cuándo**: la vida de un **jugador** (también los falsos) llega a 0 por un golpe, flecha o pulso cuyo
  autor es un jugador hostil en una zona RVR. Si no, muerte directa (PNJ, entorno, maniquí).
- **Caer**: `impose_downed`, `health = 0`, `downed_health = 400`, `downed_tick = s`, `downed_by`,
  `downed_source`, efectos borrados; DOWNED (toda la zona) y HIT con el bit 6. `Combatant.is_dead()` pasa
  a ser «vida 0 y no derribado»: el derribado sigue siendo candidato.
- **Desangrarse**: −1 cada 3 ticks (400 en 1200 ticks = 20 s). El daño enemigo (sin bloqueo posible) le
  quita de ahí; los controles no entran. A 0: muerte. DEATH y KILL con asesino = quien dio el último
  daño, o `downed_by` con fuente «desangrado» (§5.4) si fue el tiempo.
- **INTERACT** (paso 7): flanco en una entrada real (botones de `s` frente a los de `s − 1`, que guarda el
  `Combatant`) de alguien vivo, no derribado, en NONE o BLOCK y en el suelo; el derribado más cercano a ≤
  `interact_range_m` (horizontal, `|Δy| ≤ 1,5`; empate por `net_id`):
  - **aliado** sin nadie levantándolo → `impose_interact(REVIVE)`; INTERACT 1 con `end_tick = s +
    revive_ticks`;
  - **enemigo** (sin zonas seguras de por medio) → `impose_interact(EXECUTE)`; INTERACT 4.
- **Seguir**: cada tick se corta (`impose_interrupt` si aún está en la acción; INTERACT 2 o 5) si quien
  actúa ha dejado la acción (soltó, esquivó o le impusieron otra), el objetivo ya no está derribado o
  pasa de `interact_keep_range_m`, o uno de los dos recibe un impacto con daño. Lo predicho termina solo
  la acción: el servidor lo nota porque sale de REVIVE antes de tiempo.
- **Acabar** (se mira antes que seguir: en ese tick la simulación ya ha vuelto a NONE), en `s == inicio +
  duración`: levantar → `impose_revived`, vida 300, INTERACT 3; rematar → muerte con fuente «remate».
- **PNJ**: no quedan derribados; un derribado es para ellos un objetivo más (F4 le da prioridad a menos de
  6 m): lo rematan con daño.
- **Fuerte y salida**: un derribado no cuenta en el círculo (fuerte.md 1.2); si sale en combate, el cuerpo
  se queda (GUE-41) y se desangra.

### 4.6 Equipo, plantillas y consumibles

- `Combatant.template_id` (la vigente) y `pending_template_id`: LOADOUT_SELECT (§5.1) anota la pendiente,
  que vale en la siguiente aparición (la primera si llega antes que CLIENT_READY, que va detrás por el
  mismo canal fiable). Sin elegir, `default_template`. Al aparecer, `set_loadout` o `reset_for_respawn`
  con sus armas y cargas, y LOADOUT al dueño y a quien lo tenga relevante.
- **Recarga** (cada 60 ticks): vivo, fuera de combate, en la zona segura de su reino y con menos cargas
  que su plantilla → `set_loadout` con las cargas llenas y LOADOUT al dueño.
- **Pociones**: son habilidades (§2.3); la curación (HOT) la pone el paso 3; la resistencia, la simulación.

### 4.7 Validación y antitrampas

- Decide la simulación del servidor: una habilidad en reutilización, un consumible sin cargas o un cambio
  a mitad de golpe no ocurren. `--bot-cheat=reuse` (machaca una habilidad en reutilización), `potion` y
  `interact` (INTERACT cada tick lejos de nadie): ningún efecto de más ni sospecha.
- Proyectiles: rebobinado fijado por disparo con el tope y el mínimo de defensa de siempre; la dirección
  sale de yaw y pitch, nunca de un punto que mande el cliente.
- `--combat-log`: resultados nuevos `arrow_hit`, `arrow_blocked`, `wall_blocked`, `pulse`, `downed`,
  `executed`, `bled_out`, `revived`; la columna `ataque` lleva el nombre de la fuente.

---

## 5. Protocolo: `PROTOCOL_VERSION = 5`

«5: habilidades, efectos, cambio de arma, proyectiles, derribado y plantillas (docs/habilidades.md)».
Si F4 sube antes la versión, esta pasa a la siguiente libre.

### 5.1 Entradas y mensajes C→S

- INPUT_BATCH sin cambios de formato; `VALID_BUTTONS` = bits 0–12 (§3.2).
- **LOADOUT_SELECT** (`0x07`, C→S, canal 3, 2 B): `u8 type`, `u8 template_id`. Vale desde el WELCOME,
  también antes de CLIENT_READY. Un id que no existe cuenta un aviso; pasa por el limitador de fiables.
- **DEBUG_COMMAND**, ids nuevos (fijos): 13 `cooldowns_off` (`u8` 0 o 1: bit7 de `combat_flags2`), 14
  `apply_status` (`u8 status_id`, `u16` ticks, 0 = los del dato), 15 `down` (se derriba a sí mismo, como
  si lo hubiera derribado un enemigo), 16 `refill` (repone las cargas). Sin datos en 15 y 16.

### 5.2 Estado, snapshot y registro

- `PlayerState` de 111 B (§3.1) en el estado propio, en el SPAWN propio y en el ajeno.
- **SPAWN ajeno**: además de lo que ya es público, `alt_weapon_id` y el bit0 de `combat_flags2` (las
  armas se ven); reutilizaciones, cargas, consumible, ranuras de movimiento y bits de botones, a sus
  valores iniciales.
- **Registro** (21 B, sin cambios de tamaño): bit 3 de `flags` = ranura 2 activa. El remoto sabe qué
  arma lleva con la pareja (SPAWN o LOADOUT) y este bit. El byte de acción no tiene bits libres.
- **Bloque extra propio** (9 B): bit 3 de `status` = derribado; derribado, `health` es la vida de
  derribado y `max_health` 400. El `health_q` de un derribado sale de esa vida (nunca 0: 0 es muerto).
- Cabecera de 134 B, 50 registros (§3.1).

### 5.3 PROJECTILE (kind 3)

**ENTITY_SPAWN**: cabecera de siempre (`net_id` = proyectil, `realm` = el del tirador, bit0 de `flags` =
el tirador eres tú) y 22 B; total **32 B**:

| Offset | Tipo | Campo | Notas |
|---|---|---|---|
| 10 | u16 | owner | `net_id` del tirador |
| 12 | u16 | projectile_def_id | `ProjectileDefinition` |
| 14 | u16 | source | fuente del ataque o la habilidad (§5.4) |
| 16 | u8 | volley_index | 0..n−1 dentro del disparo |
| 17 | u8 | proj_flags | bit0 inofensiva; resto, 0 |
| 18 | u64 | position | `p0`, 20 bits por eje como el registro |
| 26 | s16 × 3 | velocity | `v0` en cm/s |

`spawn_tick` es el tick del disparo. `decode` devuelve `null` si el tamaño no es 32.

**ENTITY_DESPAWN** (8 B, sin cambios): motivos nuevos 4 IMPACTO y 5 CADUCADO; `despawn_tick` es el tick
del impacto. El cliente busca el punto exacto con su propio rayo en el último segmento.

El snapshot **no** lleva registros de proyectiles (`Snapshot.decode` sigue rechazando otros `kind`).

### 5.4 ENTITY_EVENT y fuentes

**Fuente** (`CombatSource`, compartido): los `u16 attack_id` de HIT, DEATH, KILL y TELEGRAPH pasan a ser
una fuente: bits 14–15 la clase y bits 0–13 el id. 0 = ninguna (entorno); `0x0000 | id` ataque;
`0x4000 | id` habilidad; `0x8000 | id` efecto (pulso); `0xC000 | 1` remate, `0xC000 | 2` desangrado. Los
ataques de hoy conservan su número.

HIT gana el bit 5 de `flags` (interrumpido) y el bit 6 (derriba). Eventos nuevos:

| `event` | Datos | `len` | Total | `net_id` | Destinatarios |
|---|---|---|---|---|---|
| 7 STATUS | `u16 source_entity` (0 = sin autor), `u8 op` (1 aplicado o renovado, 2 quitado), `u8 status_id`, `u8 stacks`, `u32 until_tick` | 9 | 18 B | el afectado | dueño, autor y quien tenga relevante al afectado |
| 8 HEAL | `u16 healer` (0 = sí mismo), `u16 amount`, `u16 source` | 6 | 15 B | el curado | ídem |
| 9 LOADOUT | `u8 template_id`, `u16 weapon_1`, `u16 weapon_2`, `u8 charges` | 6 | 15 B | el jugador | dueño; y quien lo tenga relevante si cambian las armas |
| 10 DOWNED | `u16 attacker`, `u16 source` | 4 | 13 B | el derribado | toda la zona (registro de bajas) |
| 11 INTERACT | `u16 actor`, `u8 op` (1 levantar, 2 levantar cortado, 3 levantado, 4 rematar, 5 rematar cortado), `u32 end_tick` | 7 | 16 B | el derribado | actor, derribado y quien lo tenga relevante |

Validación: tamaños exactos; `op` fuera de rango o STATUS 1 con `stacks` 0 → `null`. «Habilidad lanzada»
y «cambio de arma» no llevan evento: van en el flujo (byte de acción y bit 3 de `flags`), que anima al
remoto como los ataques. Pulso de daño = HIT con fuente de efecto; de curación = HEAL; rematado y
desangrado = DEATH con su fuente; poción = STATUS y HEAL.

**Temporización** (combate.md §6): propios al llegar; los de un remoto, en su `render_tick`.
`NetClient._note_imposed_state` da por explicadas también: STATUS de movimiento sobre uno mismo, DOWNED e
INTERACT donde uno es el derribado o el actor, LOADOUT propio y HIT propio con el bit 5.

### 5.5 Byte de acción (`ActionWire`)

| Acción | Bits 4–5 | Bits 6–7 |
|---|---|---|
| ABILITY | 0 lanzamiento, 1 activo o canalización, 2 recuperación | ranura 0–2; 3 = consumible (beber) |
| SWAP | 3 | contador de reinicio (un SWAP del búfer sale en el tick en que acaba otro) |
| DOWNED, REVIVE, EXECUTE | 3 | 0 |
| CHARGE con el arco | 0 | 0 (el remoto sabe que es tensado por el arma) |

Dos usos seguidos de la misma ranura o dos consumibles seguidos no pueden darse sin NONE (validación de
§2.2), así que ABILITY no necesita contador. `ActionWire.has_counter` añade SWAP.

### 5.6 Ancho de banda

Bajada por cliente = (136 + n · 21 + 40) B × 30/s: 10 visibles ~11,6 KB/s (antes 10,3), 30 visibles
~24,2 KB/s (22,9), tope desde 50 visibles 36,8 KB/s. Proyectiles: 40 B (SPAWN + DESPAWN) más ~10 de ENet
por flecha y destinatario: 20 flechas por segundo a la vista, ~1 KB/s. Salida del servidor con 64: de
~2,4 a ~2,5 MB/s. H2 actualiza red.md §5.2, §5.4, §5.5 y §14.

---

## 6. Cliente

### 6.1 Predicción y rechazos

Todo lo de §3 vive en el estado predicho: la reconciliación lo corrige sin código propio. **Un rechazo**
(el servidor no empezó la habilidad: en su línea de tiempo el jugador estaba aturdido) quita la acción y
devuelve `ability_ready` a su valor al repetir, y la barra, que lee el estado predicho cada fotograma,
revierte el contador sola. `CombatFeedback` sigue detectando acciones por `(action, action_id,
action_tick)`; ninguna señal sale de `simulate()`.

### 6.2 Flechas (`ProjectileWorld`, `scripts/client/projectile_world.gd`)

- **Predicha**: cuando el personaje local pasa por un compromiso con proyectil (tras el tick de física,
  no en las repeticiones), se crea con la entrada de ese tick (`ClientPrediction.get_input(t)`),
  `AimRay` contra el mundo local y las cápsulas de los remotos **tal como se dibujan**, y la misma
  cuantización. Se dibuja en el tiempo predicho; se para en el mundo con su propio rayo y se oculta al
  tocar la cápsula dibujada de un enemigo (impacto predicho: sin número).
- **Sustitución**: el SPAWN con `owner` propio se empareja con la predicha de la misma fuente y
  `volley_index` cuyo tick difiera ≤ `input_buffer_ticks`; se adoptan `p0`, `v0` y `spawn_tick` del
  servidor con un desfase visual que decae en 6 ticks. Sin pareja: se dibuja la del servidor. Una predicha
  sin SPAWN en `rtt + 30` ticks se retira (rechazo).
- **Remotas**: aparecen cuando `render_tick ≥ spawn_tick` y se dibujan en `pos(render_tick + fracción −
  spawn_tick)`; el DESPAWN las retira en su `despawn_tick`.

### 6.3 Barra de acciones (UI-11, `ActionBar`)

Abajo al centro, sobre la vida y la resistencia: ligero/fuerte (o disparo/tensado), bloqueo (oculto con
`can_block` falso), esquiva, habilidades 1–3 del arma activa, R y T con sus cargas, y Q con el icono del
arma de la otra ranura. Casillas `UIIconSlot` (UI-09): reutilización = `ability_ready[i] −
tick predicho`, con barrido y segundos; destello al quedar lista; `ability_status` las apaga (BLOCKED) o
las tacha (NO_CHARGES); la esquiva parpadea sin resistencia (bit1, como hoy). Al cambiar de arma cambian
los iconos. Una pulsación en reutilización parpadea la casilla en el cliente (no viaja). Iconos
provisionales: cuadros con la inicial y el color del arma hasta ART-12.

### 6.4 Estados (UI-45, `StatusTracker` y `StatusIcons`)

`StatusTracker` (uno por entidad) guarda `status_id`, `stacks` y `until_tick` de los STATUS; los quita
con STATUS 2, DEATH, DOWNED, RESPAWN o DESPAWN. Fila propia sobre la vida: icono, segundos que quedan
(contra el tick del servidor estimado), acumulaciones, borde rojo si es perjudicial y verde si no,
tooltip. Placas: hasta 4 iconos (primero los perjudiciales), con la vida de derribado y un icono de
derribado.

### 6.5 Derribado, plantillas y arco

- **Derribado**: aviso «Derribado» con la cuenta atrás de la vida de derribado (bloque extra), «Te están
  levantando» con la barra de INTERACT 1, «¡Te rematan!» con INTERACT 4. Quien está cerca de un aliado
  derribado (posiciones dibujadas y acción DOWNED) ve «Mantén E para levantar a …».
- **Plantillas**: selector (armas y cargas de cada `EquipmentTemplate`) en la pantalla de muerte y en la
  selección de reino; manda LOADOUT_SELECT al elegir.
- **Arco**: tensando, la cámara cierra el campo de visión (75° → 55°; no toca el brazo, así que el rayo
  canónico no cambia) y la retícula se cierra. `get_effective_shoulder()` (hombro tras el cambio
  automático) pone `AIM_LEFT`.

### 6.6 Animación provisional (pendiente del ojo del usuario)

`CombatClipPlanner` gana claves por nombre de habilidad y `swap`, `drink`, `downed`, `revive`,
`execute`, con un juego de clips por arma (`data/animation/<arma>_clips.tres`; nuevo `bow_clips.tres`).
Provisionales, con clips que hay (nombres comprobados en los `.glb`): `ual2/Shield_OneShot` (golpe de
escudo), `ual2/Shield_Dash` (embestida), `ual2/Idle_Shield_Loop` (muro), `ual2/Consume` (beber),
`ual1/Fixing_Kneeling` (levantar), `ual2/Melee_Hook` (rematar), `ual2/LayToIdle` (levantarse),
`ual2/NinjaJump_Start` (salto atrás), `ual1/Spell_Simple_Shoot` y `ual1/Pistol_Aim_Neutral` (arco).
**Para el usuario**: tensar, mantener y soltar el arco (ART-41), arrastrarse, sacar y guardar el arma,
modelos del arco y la flecha, VFX e iconos (ART-12). El remoto anima con el byte de acción, el bit de
ranura y la pareja de armas.

---

## 7. Paquetes y contratos

### 7.1 Paquetes

| Paquete | Contenido | Depende de |
|---|---|---|
| **H1 · simulación** | `CombatState` v5, `PlayerState` 111 B, botones de `PlayerInput`, `AbilityDefinition`/`Ticks`, `StatusEffectDefinition`/`StatusTicks`, `ProjectileDefinition`/`Ticks`, `EquipmentTemplate`, `CombatRules` nuevas, `CombatCatalog` ampliado y su huella, `ActionMachine` (§3), `PlayerCharacter.simulate` con `speed_factor` y `rooted`, `AimRay`, `Ballistics`, `CombatSource`, `HitShapes` (fracciones), `DamageFormula` (modificadores), todos los `.tres` de §2.3 | fase 3 |
| **H2 · protocolo v5** | `PROTOCOL_VERSION`, `VALID_BUTTONS`, LOADOUT_SELECT, ids 13–16, SPAWN y DESPAWN de proyectiles, eventos 7–11, bits de HIT, bit 3 de `flags`, bit 3 de `status`, `_hide_private_state`, red.md actualizado | fase 3 (usa `PlayerState.ENCODED_SIZE` sea cual sea) |
| **H3 · servidor** | orden del tick (§4.1), golpe sintetizado en `Combatant.freeze` y el resolutor, `ProjectileSystem`, `StatusSystem`, `DownedSystem`, plantillas y recarga, interrupciones, muro, `InputQueue.get_applied`, `allocate_transient_id`, comandos 13–16, modos tramposos `reuse`, `potion`, `interact`, registro de combate | H1, H2 y **F4 fusionado** (los dos tocan `zone_server.gd`, `combat_director.gd` y `combat_resolver.gd`) |
| **H4 · cliente** | `ProjectileWorld`, `ActionBar`, `StatusTracker`/`StatusIcons`, avisos de derribado, selector de plantilla, zoom y retícula del arco, teclas Q/R/T y bit `AIM_LEFT`, explicaciones nuevas de `NetClient`, textos (`CombatText`), clips provisionales | H1, H2 |
| **H5 · integración** | `BotBrain` de combate con habilidades, cambio de arma, pociones y arco (apunta con `Ballistics.solve_lead`), pruebas de extremo a extremo de §7.3, hoja de equilibrio medida (§2.4 → combate.md §12), `load_test --brawl` con arqueros (`--fake-loadout=marksman:50`), límite de jugadores revisado en red.md §14 | H3, H4 |

H1 y H2 en paralelo; luego H3 y H4 en paralelo; H5 al final. Con dos agentes: uno H1 → H3, otro H2 →
H4, y H5 el que acabe antes.

### 7.2 Contratos

```gdscript
# scripts/shared/combat/combat_state.gd (amplía)
enum Action { NONE, LIGHT, HEAVY, CHARGE, BLOCK, DODGE, STAGGER, STUN, DEAD,
		ABILITY, SWAP, DOWNED, REVIVE, EXECUTE }
const ENCODED_SIZE: int = 76; const ABILITY_SLOTS: int = 3; const MOVE_EFFECT_SLOTS: int = 2
const FLAG2_SECOND_SLOT: int = 1 << 0          # bits 1-6: botones pulsados el tick anterior
const FLAG2_NO_COOLDOWNS: int = 1 << 7
const BUFFER_ABILITY_1: int = 4                 # 5, 6; BUFFER_SWAP = 7; BUFFER_CONSUMABLE_1 = 8, _2 = 9
var alt_weapon_id: int; var combat_flags2: int
var ability_ready: PackedInt64Array             # 6; copy_from copia el contenido
var consumable_ready_tick: int; var consumable_charges: int
var move_effect_ids: PackedInt32Array           # 2 (0 = libre)
var move_effect_until: PackedInt64Array         # 2
static func initial(rules: CombatRules, weapon_id: int, alt_weapon_id: int = 0,
		charges: int = 0) -> CombatState
func buffered_type() -> int; func buffered_ticks() -> int
func charges_of(index: int) -> int; func is_second_slot() -> bool

# scripts/shared/combat/action_machine.gd (amplía)
class Output:     # + var speed_factor: float = 1.0; var rooted: bool = false
enum AbilityStatus { READY, COOLDOWN, BLOCKED, EMPTY, NO_CHARGES }
const DEFENSE_WIDE_BLOCK: int = 1 << 7
static func active_hit(c: CombatState, tick: int) -> AttackTicks
static func is_commit_tick(c: CombatState, tick: int) -> bool
static func ability_status(c: CombatState, slot: int, tick: int) -> int
static func impose_downed(c: CombatState, tick: int) -> void
static func impose_revived(c: CombatState, tick: int) -> void
static func impose_interact(c: CombatState, tick: int, action: int) -> void   # REVIVE o EXECUTE
static func impose_interrupt(c: CombatState, tick: int) -> void
static func impose_move_effect(c: CombatState, effect_id: int, until_tick: int) -> void
static func clear_move_effects(c: CombatState) -> void
static func reset_cooldowns(c: CombatState) -> void
static func set_loadout(c: CombatState, weapon_1: int, weapon_2: int, charges: int) -> void
static func reset_for_respawn(c: CombatState, tick: int, weapon_1: int, weapon_2: int,
		charges: int) -> void

# scripts/shared/combat/combat_catalog.gd (amplía): ability(id) -> AbilityTicks, status(id) ->
# StatusTicks, projectile(id) -> ProjectileTicks, template(id) -> EquipmentTemplate, sus *_id(name)
# -> int, template_count() -> int y consumable_ids() -> PackedInt32Array (2, en orden de botón).

# scripts/shared/combat/combat_source.gd
class_name CombatSource extends RefCounted
enum Kind { ATTACK, ABILITY, STATUS, SPECIAL }
const EXECUTE: int = 0xC001; const BLEED_OUT: int = 0xC002
static func make(kind: int, id: int) -> int
static func kind_of(source: int) -> int; static func id_of(source: int) -> int

# scripts/shared/combat/aim_ray.gd · class_name AimRay extends RefCounted
static func canonical(feet: Vector3, look_yaw: float, look_pitch: float,
		left_shoulder: bool) -> Array        # [origin: Vector3, direction: Vector3]
static func aim_point(space: PhysicsDirectSpaceState3D, origin: Vector3, direction: Vector3,
		capsule_feet: PackedVector3Array) -> Vector3
static func muzzle(feet: Vector3) -> Vector3

# scripts/shared/combat/ballistics.gd · class_name Ballistics extends RefCounted
static func position(p0: Vector3, v0: Vector3, gravity: float, ticks: float) -> Vector3
static func quantize(p0: Vector3, v0: Vector3) -> Array    # [p0, v0] como viajan
static func solve_lead(origin: Vector3, target: Vector3, target_velocity: Vector3, speed: float,
		gravity: float) -> Vector3                       # dirección (bots y PNJ)

# scripts/shared/combat/hit_shapes.gd (amplía); devuelven 0..1, o -1 si no toca
static func segment_capsule_fraction(a: Vector3, b: Vector3, capsule_feet: Vector3, radius: float,
		height: float) -> float
static func segment_box_fraction(a: Vector3, b: Vector3, box: Transform3D, half_extents: Vector3) -> float
# damage_formula.gd: compute(..., damage_scale: float = 1.0, mitigation_penalty: float = 0.0)

# scripts/server/combatant.gd (amplía); Frozen gana hit: AttackTicks, commit: bool, wall: Transform3D
var effects: Array[StatusSystem.ActiveEffect]
var downed_health: int; var downed_tick: int = -1; var downed_by: int; var downed_source: int
var interact_target: int; var interact_action: int; var interact_start: int; var last_buttons: int
var template_id: int; var pending_template_id: int = -1
func is_downed() -> bool          # is_dead() = vida 0 y no derribado

# scripts/server/projectile_system.gd · class_name ProjectileSystem extends RefCounted
signal spawned(spawn: NetMessages.EntitySpawn, recipients: PackedInt32Array)
signal despawned(projectile_id: int, tick: int, reason: int, recipients: PackedInt32Array)
func fire(shooter: Combatant, source: int, s: int, space: PhysicsDirectSpaceState3D) -> void
func resolve(s: int, combatants: Array[Combatant],
		space: PhysicsDirectSpaceState3D) -> Array[CombatResolver.Hit]   # Hit gana projectile_id
func live_count() -> int

# scripts/server/status_system.gd · class_name StatusSystem extends RefCounted
func apply(target: Combatant, status_id: int, source_id: int, s: int) -> void
func step(s: int, list: Array[Combatant]) -> void; func clear(target: Combatant) -> void

# scripts/server/downed_system.gd · class_name DownedSystem extends RefCounted
func should_down(victim: Combatant, author: Combatant) -> bool
func down(victim: Combatant, author_id: int, source: int, s: int) -> void
func step(s: int, list: Array[Combatant], space: PhysicsDirectSpaceState3D) -> void

# input_queue.gd: get_applied(tick) -> PlayerInput (real o sustituida)
# net_entity_registry.gd: allocate_transient_id(tick) -> int; release_transient_id(id, tick)
# camera_rig.gd: get_effective_shoulder() -> int; set_aim_zoom(f: float)
# net_client.gd: signal projectile_spawned(spawn); signal projectile_despawned(id, tick, reason)
```

### 7.3 Pruebas (cada una < 30 s)

**H1** (sin red, mundos en `SubViewport` como `test_prediction`):

- `test_combat_state_v5`: ida y vuelta con cada campo en su offset; 76 y 111 B; `buffered` nuevo.
- `test_ability_machine`: empieza con el flanco; reutilización fijada en el compromiso (con `cast = 0`,
  en el mismo tick); vuelve a valer en `t == ability_ready`, no antes; tambaleo en el lanzamiento → sin
  reutilización; **el tambaleo corta una canalización** y fija su reutilización en ese tick; soltar,
  moverse (si lo dice el dato) y el tope acaban la canalización; prioridades con flancos simultáneos;
  búfer de una habilidad pulsada en la recuperación de un ligero; una sustituida no empieza nada.
- `test_ability_reconciliation`: **la reutilización sobrevive a una reconciliación**: cliente y servidor
  con las mismas entradas, una diferencia de posición impuesta tras el compromiso; tras repetir,
  `ability_ready` es el mismo y el estado coincide byte a byte.
- `test_weapon_swap`: intercambio de armas y de las dos mitades; **no se cambia a mitad de un golpe**
  (SWAP en anticipación o activo: el arma no cambia hasta la recuperación; caduca si no llega);
  **predicho y reconciliado** con una entrada sustituida alrededor del flanco: estados iguales.
- `test_move_effects`: **la ralentización da la misma velocidad en cliente y servidor** (el servidor la
  impone en `s`; tras reconciliar, estados iguales cada tick y velocidad = `run_speed · 0,6`); ROOT
  impide esquivar y avanzar; caducidad en el tick exacto; tercera ranura sustituye a la que acaba antes.
- `test_consumables_machine` (cargas, reutilización compartida, compromiso al acabar de beber, +400
  exactos, sin cargas no empieza) y `test_bow_machine` (toque = disparo rápido, 8 ticks = tensado, cargas
  mínima y máxima en sus ticks, BLOCK no hace nada).
- `test_aim_ray`: el rayo canónico coincide con `CameraRig.get_aim_ray()` (sin colisión, cualquier zoom,
  los dos hombros) a menos de 1 mm; `Ballistics` y la cuantización.
- `test_combat_catalog` (amplía): ids pedidos por nombre; cada error de §2.2; la huella cambia con un
  tiempo de habilidad y no con su daño. Microbanco de `simulate()`: el camino rápido no sube más de 2 µs.

**H2**: `test_net_messages` (amplía): ida y vuelta y tamaños de los eventos 7–11, del SPAWN de 32 B y de
LOADOUT_SELECT; truncados y `op` fuera de rango → `null`; `VALID_BUTTONS`; `CombatSource`; bit 3 de
`flags`; *fuzz*. `test_snapshot_builder`: 50 registros y nunca más de 1200 B.

**H3** (servidor en un proceso, `combat_fixture.gd`):

- `test_ability_server`: golpe de escudo aturde de frente y no por detrás, atraviesa un escudo en alto;
  la embestida recorre 6 m (±0,3) y empuja; el muro bloquea un golpe a 85° del frente y no a 95°, y para
  flechas a un aliado detrás; **el servidor rechaza una habilidad en reutilización** (bot que la pulsa un
  tick de cada dos: compromisos separados exactamente `cooldown_ticks + cast_ticks`, ni uno antes).
- `test_status_effects`: **un sangrado hace exactamente N pulsos** (6, en `anchor + 60k`); acumulación,
  renovación y el más fuerte; limpieza al morir y al quedar derribado; STATUS con su `until_tick`.
- `test_projectiles`: **ninguna flecha atraviesa muros** (200 disparos a un blanco tras un muro: 0
  impactos, todas con DESPAWN 4 en el muro); **disparo pegado a una esquina** (cámara al lado abierto,
  blanco que solo ve la cámara: la flecha da en la esquina); bloqueo frontal; esquiva que deja pasar;
  topes por tirador y por zona; golpe a la puerta.
- `test_downed`: **los tres desenlaces**: levantado (180 ticks, vida 300, NONE), rematado (60 ticks,
  DEATH con fuente de remate y KILL) y desangrado (1200 ticks, asesino = quien derribó); levantar cortado
  por daño; muerte directa contra un PNJ; un PNJ remata con daño.
- `test_consumables_server`: curación de 6 pulsos; **un golpe que interrumpe** no gasta carga ni
  reutilización; recarga en el campamento; `--bot-cheat=potion` no cura de más.
- `test_bot_cheat` (amplía): `reuse` e `interact` sin efecto de más ni sospecha.

**H4**: `test_action_bar` (iconos del arma tras un cambio; **un rechazo revierte el contador**: una
reconciliación que quita la habilidad deja la casilla lista), `test_status_icons` (en la placa y en la
fila propia; se va al caducar), `test_projectile_world` (la predicha se sustituye por la del servidor; la
remota, en su `render_tick`), `test_hud_combat` (amplía: avisos de derribado).

**H5** (ENet en loopback, `net_harness.gd`):

- `test_projectile_loopback`: **flecha a 30 m con rtt=150** (jitter 30) contra un objetivo que corre en
  lateral: al menos 18 de 20 tensados confirmados; control con el rebobinado apagado: menos de 10.
- `test_abilities_reconciliation`: **3 bots con NetSim** (`rtt=120, jitter=20, loss=5`, 1800 ticks) con
  las dos plantillas usando habilidades, cambio de arma, pociones, flechas, ralentizaciones y derribos:
  todas las correcciones explicadas (sustitución, teletransporte o combate), ningún reinicio duro tras el
  arranque y convergencia exacta al quedarse quietos (la aceptación de la fase 2).
- `test_loadout_net`: dos clientes eligen plantillas distintas y cada uno ve las armas del otro (PRG-07).
- `test_combat_balance` (amplía): DPS del arco medido igual al calculado; maniquí a 10, 30 y 50 m.

---

## 8. Riesgos

- **CPU de los proyectiles.** Sonda (Godot 4.7.2 headless, Jolt, 400 cajas, máquina compartida con otros
  dos procesos): `intersect_ray` de 1,17 m (un tick a 70 m/s) **0,6 µs** (1,0 creando la consulta en cada
  rayo), de 150 m 1,6 µs; segmento contra cápsula en GDScript 0,8 µs; cribado de un par
  proyectil-candidato 0,09 µs (**225 µs por tick con 40 flechas y 64 candidatos**). Con el sobrecoste
  real del bucle (objetos, muestras del historial) se estiman **30–50 µs por flecha y tick**: 20 flechas
  en el aire (un tercio de arqueros entre 64) son 0,6–1 ms, frente a los 0,77 ms del paso de combate y
  los 9,4 / 15,9 ms (p50 / p99) del tick con 64 combatientes (combate.md §11): el p99 puede pasar de 16,7
  ms. H5 lo mide con `--fake-loadout=marksman:50`; si pasa de 1 ms, rejilla de candidatos por tick
  (celdas de 16 m) antes que bajar el límite de jugadores. El rayo contra el Terrain3D real no se ha medido.
- **Tamaño del estado.** +42 B: 50 registros en vez de 52. Si sigue creciendo (PRG-06), las
  reutilizaciones del arma guardada pueden pasar a u16 relativas al tick del cambio.
- **`simulate()`** ya es el cuello (69–72 µs por personaje) y la máquina crece mucho: conviene partirla
  (`ActionMachine` sigue siendo la entrada; habilidades y consumibles en `ability_rules.gd`).
- **Flechas que se ven tarde**: la víctima ve la flecha en el pasado y su HIT llega con ella aún en vuelo;
  con el tope de 24 ticks se acepta, como el cuerpo a cuerpo.
- **Mira frente al rayo canónico**: el seguimiento suavizado (`follow_sharpness` 25) deja el pivote hasta
  v/25 m atrás (0,2 m corriendo). Si se nota, la retícula del arco va al punto canónico proyectado.
- **Animaciones**: faltan las del arco, arrastrarse y sacar el arma (§6.6); sin ART-41 el arco se ve mal.
- **Derribado con latencia**: levantar y rematar los empieza el servidor: quien pulsa E ve una corrección
  de 1 RTT, explicada por INTERACT.
- **F4 en paralelo**: H3 no empieza hasta fusionar F4.

---

## 9. Fuera de alcance

- **PRG-01** (`StatBlock`): no hace falta; vida, resistencia y esquiva siguen saliendo de `CombatRules` y
  del arma. **PRG-06** (armaduras y carga): armadura 0. **PRG-04**: solo las dos armas; las ranuras de
  armadura, los ids visuales por ranura y la hoja derivada por mensaje fiable llegan con PRG-06.
- Maná y bastones (fase 6), elegir habilidades o talentos (PRG-19), persistencia de armas,
  reutilizaciones y efectos (CMB-30), escala de Eldrun para proyectiles (CMB-36), antitrampas
  estadístico de puntería (CMB-39), INTERACT con objetos del mundo (MUN-16: los derribados tendrán
  prioridad).
- Modelos, clips, VFX, sonidos e iconos definitivos: del usuario (ART-12, ART-41).
