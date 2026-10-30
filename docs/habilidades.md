# Eldmark · Fase 4: diseño de habilidades, efectos, armas y proyectiles

Diseño corto de la ampliación del combate que anuncia [fuerte.md 10](fuerte.md#10-ampliación-del-combate-otro-diseño-corto):
habilidades con reutilización (CMB-19), efectos de estado (CMB-20), espada y escudo (CMB-21), proyectiles
con rebobinado (CMB-22), arco (CMB-23), cambio de arma (CMB-24), derribado (CMB-28), equipo mínimo
(PRG-04), plantillas (PRG-07), consumibles (PRG-08), barra de acciones (UI-11) e iconos de estados
(UI-45). Continúa [combate.md](combate.md) (sus §1, §3, §4 y §6 se dan por leídos), [red.md](red.md) (§6,
§8, §10, §14) y el orden del tick de [fuerte.md 1.7](fuerte.md#17-orden-del-tick-completa-combatemd-42).

Versión 2: la 1 tras la revisión de tres revisores (§10). Lo marcado «comprobado» sale de sondas en
Godot 4.7.2 headless (no se suben).

Convivencia: F4 (PNJ) y el chat y los grupos (SOC-03 a SOC-08, protocolo 5) se fusionan **antes** que
cualquier paquete H (§7.1). F4 añade armas `data/combat/npc_*.tres`, `AttackDefinition.unblockable`
(solo servidor) y el comando 12: **ningún id del catálogo es fijo**, todo se pide por nombre
(`CombatCatalog.ability_id(&"shield_bash")`). Los PNJ del fuerte (`HfsmBrain` y `NpcWorld` de F4;
`NpcBrain` sigue siendo el maniquí) usan habilidades y efectos como un jugador (su arma puede llevar
`abilities`); rematar derribados se lo enseña H3c (§4.5).

---

## 0. Decisiones

Las cuatro primeras eran pendientes del backlog que bloqueaban; se toman con su recomendación
(**provisional, tomada de noche**) y pasan a «Decisiones tomadas» de [backlog.md](backlog.md).

| Pregunta | Decisión |
|---|---|
| Recurso de las habilidades | Solo reutilización en las armas físicas; maná solo en los bastones (fase 6). La resistencia sigue siendo el recurso defensivo. *Provisional, tomada de noche.* |
| Origen y dirección de los proyectiles | Rayo de cámara canónico desde `look_yaw`, `look_pitch` y un bit de hombro; la flecha sale del pecho hacia el punto apuntado, que converge a la profundidad del enemigo más cercano a la mira (§4.4). *Provisional, tomada de noche.* |
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
| Interrupción | Solo un HIT de golpe o de flecha con resultado IMPACT, daño > 0 y autor hostil (ni pulsos ni entorno) corta beber y los lanzamientos marcados (fase 0, `[0, cast)`), levantar y rematar. Los controles cortan cualquier acción, como hoy. |
| Fuego amigo | Sigue sin haber: flechas y áreas atraviesan a los aliados. |
| Teclas nuevas | Q cambiar de arma, R poción de vida, T poción de resistencia. Se reasignan con UI-17. |
| Desvíos del backlog | CMB-21: el muro protege a los de detrás solo de flechas. CMB-23: sin dispersión; la carga da daño y velocidad (trayectoria más tensa). CMB-24: el arma activa va en el bit 3 de `flags` del registro, no en el byte de acción. PRG-04: solo las dos armas, sin hoja derivada (§9). Anotados en backlog.md. |

---

## 1. Qué se predice y qué decide el servidor

| Dato | Dónde vive | Predicho | Viaja en |
|---|---|---|---|
| Habilidad en curso: acción ABILITY, id, tick, dirección del avance | `CombatState` | Sí | estado propio; byte de acción de los remotos (§5.5) |
| Reutilizaciones (6 ticks absolutos), la de los consumibles y las cargas | `CombatState` | Sí; el servidor impone todo al aparecer y, en el campamento, solo las cargas (§3.5) | estado propio |
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
@export var id: StringName; @export var selectable: bool = true   # false: solo pruebas y PNJ
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
  `consumable_cooldown_s` 20, `aim_pivot_height` 1,6, `aim_shoulder_offset` 0,6,
  `aim_camera_v_offset` 0,1, `aim_range_m` 150, `aim_converge_deg` 12, `muzzle_height` 1,4. S:
  `downed_health` 400, `downed_s` 20, `revived_health` 300, `interact_range_m` 2,0,
  `interact_keep_range_m` 2,5, `ability_block_angle_deg` 180, `ability_block_stamina_per_damage` 0,6,
  `max_projectiles_per_shooter` 8, `max_projectiles_per_zone` 64 (§4.4, §8), `default_template`
  (escudero). `aim_shoulder_offset` y `aim_camera_v_offset` son el `h_offset` y el `v_offset` de
  `camera_rig.tscn` (lo comprueba `test_aim_ray`).

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
  `lifetime_ticks ≥ 1`; `projectile_count` 1–5; una plantilla `selectable` no lleva armas `npc_*`.
- **`prediction_hash`** (`_HASH_FORMAT` pasa a 2): entra **todo campo marcado P en §2.1, sin
  excepciones** (reglas, ataques, armas y habilidades con el avance horneado; id, tipo y
  `move_speed_scale` de cada efecto; los proyectiles), también `downed_move_scale`, `downed_turn_rate`,
  `revive_s`, `execute_s` y `blocks`. No entran los S (`downed_health`, `downed_s`, `revived_health`,
  `interact_*`, `wall_*`, `ability_block_*`, daños, formas, controles, pulsos) ni las plantillas.

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

**Resistencia** (la columna de 12.1): ninguna acción nueva cuesta resistencia; la esquiva del arco es la
de la espada. El muro gasta 0,6 por punto bloqueado y no regenera: un atacante solo (156,3 DPS) le quita
563 en 6 s y **no lo rompe**; dos, 1000 en 5,3 s. Es a propósito (contrajuego: golpe de escudo
imbloqueable, flanco y superioridad numérica); H5 mide la rotura 1 contra 1 y 2 contra 1 y, si dos
tampoco la rompen, sube el coste a 0,8–1,0. El agotamiento impide el muro (como BLOCK) y el tensado
(como la carga, `_try_charge`); no impide el disparo rápido, las demás habilidades ni las pociones.

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
  PRIMARY, 2 DODGE, 3 enlace, 4–6 ABILITY_1–3, 7 SWAP, 8–9 CONSUMABLE_1–2. Las lecturas de `buffered &
  3` no se sustituyen sin más: `_run_buffer` despacha por tipo (1 y 3 → ligero, 2 → esquiva, 4–6 →
  `_try_ability`, 7 → `_try_swap`, 8–9 → `_try_consumable`); en `_finish_expired`, `linked` = tipo ∈
  {PRIMARY, enlace}; y la caducidad de cualquier tipo distinto de PRIMARY con el ligero ya acabado
  también pone `combo_step = 0`.
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
   DOWNED y DEAD solo se borran búfer y pulsación. Orden fijo: **4a** fines por entrada (canalización y
   REVIVE/EXECUTE, abajo); **4b** el búfer (vale en `p+1 … p+8` para la pulsación del tick `p`, por tipo,
   §3.1); **4c** los flancos nuevos por prioridad, **DODGE > ABILITY_1 > ABILITY_2 > ABILITY_3 >
   CONSUMABLE_1 > CONSUMABLE_2 > PRIMARY > SWAP > BLOCK**. Un flanco que no se puede ejecutar ahora va
   al búfer (una ranura, la última gana); se descarta si no tiene sentido (ranura vacía, sin cargas, sin
   arma alternativa, `can_block` falso, avance con ROOT). Una canalización con `channel_hold` que sale
   del búfer exige su botón abajo; si no, se descarta. Ejemplo: soltar 3 y pulsar PRIMARY en el mismo
   tick acaba el muro en 4a y el ligero sale en 4c, en ese tick.
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
   - **Canalización en curso** (4a; ABILITY con `channel` y `t ≥ action_tick + cast`): con
     `channel_hold`, una entrada real sin el botón de su ranura la acaba; con `channel_breaks_on_move`,
     una entrada real con `|move| ≥ 0,1` también.
   - **INTERACT** (4a) no empieza nada aquí (levantar y rematar los empieza el servidor, §4.5); en REVIVE
     o EXECUTE, una entrada real sin INTERACT los acaba (a NONE).
5. **Compromiso** (tras las entradas): si `action == ABILITY` y `t == action_tick + cast_ticks`:
   consumible → su carga − 1 y `consumable_ready_tick = t + consumable_cooldown_ticks`; habilidad sin
   canalización → `ability_ready[slot] = t + cooldown_ticks`; en los dos, resistencia +
   `stamina_restore` (sin pasar del máximo). Con `cast = 0` se compromete en el tick en que empieza. Una
   canalización fija `ability_ready[slot] = t_fin + cooldown_ticks` en el tick en que acaba, por la causa
   que sea (también si la corta el servidor, §3.5), **si ha llegado comprometida**: la que acaba en
   `t ≤ action_tick + cast` (soltar o DODGE en el tick del compromiso, que 4a y 4c miran antes) se
   cancela sin reutilización. Un toque de 3 más corto que el lanzamiento da 12 ticks de lanzamiento, NONE
   y ninguna reutilización; soltar en `action_tick + cast + 1`, un tick de muro y 18 s. Con el bit7 no se
   fija nada ni se gastan cargas.
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
- `impose_interrupt(c, t)`: NONE (corta beber, un lanzamiento marcado, REVIVE o EXECUTE) **conservando
  el `action_tick` de lo que corta**, como `_to_none` (§4.2, muestra antigua); antes del compromiso no
  hay reutilización ni gasto.
- `impose_move_effect(c, effect_id, until_tick)`: mismo id → `until = max`; si no, ranura libre; si no,
  sustituye a la que acaba antes.
- `clear_move_effects(c)`, `reset_cooldowns(c)`.
- `set_charges(c, charges)`: **solo** `consumable_charges`. La usan la recarga del campamento y el
  comando 16: no tocan arma, reutilizaciones, ranuras ni la acción en curso.
- `set_loadout(c, weapon_1, weapon_2, charges)` y `reset_for_respawn(c, t, weapon_1, weapon_2,
  charges)`: armas en orden de ranura (activa la 1), reutilizaciones a 0, cargas, ranuras vacías; se
  conservan los bits de botones pulsados. **Solo al aparecer** (personaje recién creado o DEAD); sobre un
  vivo fuerzan antes NONE. El comando 5 `set_weapon` pasa a ser `set_loadout` con el arma en la ranura 1.

### 3.6 Consultas

`phase(c, t)`: en ABILITY, 0 lanzamiento, 1 activo o canalización, 2 recuperación; en SWAP, DOWNED,
REVIVE y EXECUTE, 3. `active_hit(c, t) -> AttackTicks` (el ataque en golpe activo o el golpe
sintetizado de la habilidad en su activo; null si no hay). `is_commit_tick(c, t)` (primer tick activo de
LIGHT, HEAVY o ABILITY). `ability_status(c, slot, t)` (READY, COOLDOWN, BLOCKED, EMPTY, NO_CHARGES; para
la barra). `defense_flags`: la canalización que bloquea da `DEFENSE_BLOCKING | DEFENSE_WIDE_BLOCK` (bit 7
de `StateHistory`, libre hasta hoy); DOWNED no da ninguna defensa. El byte del historial es **`(flags del
registro & 0b111) | defense_flags`**: el bit 3 del registro (ranura 2, §5.2) no entra nunca, porque en
`StateHistory` el bit 3 es `DEFENSE_BLOCKING`. `_record_history` enmascara y lo dicen los comentarios de
`StateHistory` y de `ActionMachine`.

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
| 6 | **Efectos de estado**: pulsos y caducidades; primero se reúnen los pulsos de todos y después se aplican, por `net_id` del afectado e id de efecto, saltándose a quien ya esté derribado o muerto en este tick | 4 |
| 7 | **Derribado**: desangrado, INTERACT nuevos, progreso y final de levantar y rematar | 4 |
| 8 | Entorno, reapariciones (con plantilla) y recarga de consumibles en el campamento (cada 60 ticks, `set_charges`) | 4 |
| 9 | Publicar: vida, estado, byte de acción y ranura activa | 4 |
| 10 | `FortressController.step(s)` | 4b |
| 11 | Altas, historial, snapshots, OBJECT_STATE, eventos y SPAWN/DESPAWN de proyectiles | 5 |

Un derribado o un muerto en el paso 5 no recibe más golpes de ese tick (`_apply_hit` descarta con
`is_dead() or downed_tick == s`, §4.5): todos se resolvieron contra el mismo estado, como las muertes
de hoy. Al dar de baja a una entidad (`CombatDirector.remove`: salida, `--fake-churn`, un PNJ retirado),
sus flechas vivas salen con DESPAWN 5 en ese tick y sus efectos sobre otros se quitan (STATUS 2); la
baja de un derribado es antes una muerte (§4.5).

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
  `ability_block_stamina_per_damage`; para los proyectiles, además, la caja (§4.4).
- **Muestra antigua del bloqueo** (cambia combate.md §4.3; H3a): **no cuenta si la acción congelada no es
  BLOCK y su `action_tick > view_tick`, sea NONE o no** (hoy `_dropped_guard_after` da por buena
  cualquier NONE). `_to_none` e `impose_interrupt` conservan el `action_tick` de lo que acaba: soltar el
  escudo sin más sigue contando; bajarlo para beber o levantar y volver a NONE, no.
- **Puertas**: los golpes de habilidad prueban las puertas igual que los ataques.
- **Interrupción**: un HIT de golpe o de flecha con resultado IMPACT, daño > 0 y autor hostil (ni pulsos
  de efectos ni entorno) a quien está en la fase 0 (`[0, cast)`) de un consumible o de una habilidad con
  `interrupt_on_damage`, o en REVIVE o EXECUTE → `impose_interrupt` (si el golpe no impone ya un
  control). Tras el compromiso ya no se interrumpe: la carga y la curación ya están puestas. HIT con el
  bit 5.
- **Protección de reaparición**: se pierde también en ABILITY que no sea consumible
  (`CombatDirector._started_attack`, como LIGHT, HEAVY y CHARGE); beber, SWAP, REVIVE y EXECUTE no la
  quitan.

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
  HIT con la fuente del efecto y el atacante `source_id` (puede derribar y matar; no interrumpe). HOT:
  cura sin pasar del máximo → HEAL. Los PNJ inmortales siguen sin bajar de 1. `step` reúne los pulsos
  antes de aplicarlos (§4.1, paso 6): un derribo a mitad no borra la lista que se recorre.
- **Caducidad**: en `s ≥ until` se quita (STATUS 2); la ranura de movimiento ya la vacía la simulación
  en el mismo tick.
- **Modificadores**: `DamageFormula.compute(..., damage_scale = 1 + Σ DAMAGE_UP del atacante,
  mitigation_penalty = Σ MITIGATION_DOWN de la víctima)`; la mitigación del bloqueo baja en esa
  fracción (mínimo 0).
- **Limpieza**: al morir, al quedar derribado y al reaparecer se borran todos, sin STATUS sueltos
  (DEATH, DOWNED y RESPAWN los borran en el cliente). No se aplican efectos a un derribado.

### 4.4 Proyectiles (`ProjectileSystem`, `scripts/server/projectile_system.gd`)

**Disparo** (paso 3), por cada proyectil del ataque o la habilidad que compromete en `s`:

1. **Rebobinado**: el de combate.md §4.3 paso 2, fijado ahora para todo el vuelo y **redondeado a ticks
   enteros** (`rewind` y `defense_rewind`; se factoriza de `CombatResolver._swing_rewind`). Rechazado →
   flecha **inofensiva** (vuela y choca con el mundo, no prueba personajes), sospecha + 1 y registro.
   También es inofensiva si el tirador está en la zona segura de su reino. Falsos y PNJ: sin rebobinado.
2. **Puntería** con la entrada de `s` (`InputQueue.get_applied(s)`): `AimRay.canonical(pies, look_yaw,
   look_pitch, AIM_LEFT)` da el rayo de la cámara canónica: base `B = Basis(UP, yaw) · Basis(RIGHT,
   pitch)`, dirección `D = B · FORWARD` y origen `C = pies + (0, aim_pivot_height, 0) +
   B · (±aim_shoulder_offset, aim_camera_v_offset, 0)` (lo que hay detrás del personaje no cuenta).
   **Punto apuntado** (`AimRay.aim_point`) `P = C + D · t`, con `t_m` la distancia al primer choque con
   el mundo (`LINE_OF_SIGHT_MASK`) o `aim_range_m` y los hostiles en `s − rewind`: si el rayo toca una
   cápsula antes de `t_m`, `t` es ese choque; si no, el hostil cuyo centro `H` (pies + 0,9 m) queda a
   menos de `aim_converge_deg` de `D` con `(H − C) · D` en `(0, t_m)`, el de menor ángulo (empate por
   `net_id`), da `t = (H − C) · D`; sin ninguno, `t = t_m`. Así la flecha cruza la mira a la
   profundidad del blanco aunque se adelante al aire (sin convergencia se desviaba `|O − C| · (1 − d/t)`,
   0,51 m a 30 m con el fondo a 150 m). Salida en el pecho, `O = pies + (0, muzzle_height, 0)`;
   `dir = (P − O).normalized()`, girada en yaw por los desfases del abanico; `v0 = dir · velocidad ·
   lerp(1, charge_speed_scale, f)`, con la `f` de la carga del daño (combate.md §4.4; 0 sin carga).
   Bots y PNJ: `AimRay.look_for(pies, punto, izquierdo)` da el `(yaw, pitch)` cuyo rayo pasa por un punto
   (3 iteraciones de punto fijo); apuntan a `O + dir · |blanco − O|` con la `dir` de `solve_lead`.
3. **Redondeo**: `O` y `v0` se cuantizan como viajan en el SPAWN (1 cm, 1 cm/s; `Ballistics.quantize`) y
   el servidor vuela con eso, para que la trayectoria del cliente sea la misma.
4. **Copia del autor**: el proyectil guarda `owner_id`, reino, si es jugador, `source`, `rewind`,
   `defense_rewind`, la `f` de la carga y `damage_scale` (DAMAGE_UP en `s`), y no vuelve a buscar el
   `Combatant` del tirador (`Hit` gana `projectile_id` y esta copia; `should_down` recibe el reino y si es
   jugador). Si el tirador se da de baja, DESPAWN 5 (§4.1).
5. **Alta**: id del espacio de `NetEntityRegistry` (`allocate_transient_id`, misma cuarentena de 600
   ticks) sin entrar en su lista de entidades; SPAWN a quien tiene relevante al tirador y a él. **Un
   disparo nunca se rechaza** (compromiso y reutilización ya están predichos): con 8 vivos del tirador
   sale su más vieja, y con 64 en la zona, la más vieja de la zona (empate por id), con DESPAWN 5 en ese
   tick: suelen ser las tiradas al cielo, que viven los 2 s.

Comprobado: `h_offset` y `v_offset` desplazan el origen sin girar el rayo (con `v_offset`, a 4·10⁻⁷ m
del canónico); zoom y brazo (a lo largo del rayo) no cambian la línea; el hombro y el tirón lateral, sí.

**Vuelo**: los dos lados llaman a la misma `Ballistics.position(p0, v0, g, n) = p0 + v0 · n/60 + (0, −½
· g · (n/60)², 0)`, con `n` entero (servidor) o fraccionario (dibujo). En el tick `k`, con `n = k −
spawn_tick`, se prueba el segmento `[pos(n), pos(n + 1)]` (en el tick del disparo, el primero). Un
segmento que **empieza dentro** de una caja o una cápsula da fracción 0.

- **Mundo**: `intersect_ray` contra `LINE_OF_SIGHT_MASK` (mundo y puerta; no los bloqueos invisibles);
  el primer segmento, con `hit_from_inside = true`. Segmentos contiguos: no hay túnel. Si el cuerpo es de
  un `StructureTarget` que el tirador puede dañar (`get_body_rids`), es un golpe a la puerta (perforante
  ×0,2).
- **Muros**: las cajas de los muros de escudos de entidades hostiles al tirador, en `k` (presente, como
  el mundo y la puerta; quien lo sostiene va a ×0,3), con `HitShapes.segment_box_fraction`.
- **Personajes**: candidatos de combate.md §4.3 paso 4 (hostiles, vivos o derribados, sin protección ni
  zona segura) en `k − rewind`, leídos con `StateHistory.position_at(id, tick) -> Vector3` (sin crear
  objetos; con `rewind = 0`, la congelada). Criba: una **caja barrida** por candidato (la unión de 4
  bloques de 8 ticks que `StateHistory` mantiene al grabar, que cubre al menos `[k − 24, k − 1]`, más la
  posición congelada), calculada una vez por tick si hay flechas vivas o disparos; solo si solapa la del
  segmento, segmento contra cápsula de radio 0,4 + `radius_m` (`HitShapes.segment_capsule_fraction`).
  `aim_point` criba con las mismas cajas, por ángulo.
- Gana la fracción menor. Personaje: invulnerable en `[k − defense_rewind, k]` → sigue volando y no
  vuelve a probarlo; bloqueo (normal o del muro) con el cono frente a `−velocidad` → BLOCKED; nunca
  parada; si no, IMPACTO (a quemarropa si empieza dentro) con daño de la fuente (con su carga),
  controles y `target_status`. **Muro** → BLOCKED de quien lo sostiene, como su bloqueo: sin daño
  (`block_mitigation` 1), gasta `ability_block_stamina_per_damage × daño` y sin resistencia rompe la
  guardia (aturde y corta la canalización con su reutilización). Mundo → se clava.
- Sin impacto y `n + 1 ≥ lifetime_ticks`, o `y < −100` → DESPAWN 5 (caduca).
- **Esquinas**: la flecha sale del pecho, y el segmento hacia `P` choca con la esquina que el pecho no
  ve: no sale por el lado de la cámara. El pecho **sí** puede estar dentro de un cuerpo de vista: el
  dueño cruza su puerta cerrada (fuerte.md §3.1) y, con los pies en el vano, el pecho queda en la caja
  de 0,5 m. Por eso el primer segmento usa `hit_from_inside` y la flecha se clava en el origen
  (comprobado: sin él, el rayo que empieza dentro ignora la caja). En el cuerpo a cuerpo,
  `HitShapes.is_ray_clear` pasa a `hit_from_inside = true` (H3a): desde el vano ni se golpea ni se es
  golpeado. Un arquero enemigo dentro de la caja del muro choca con ella; detrás de quien lo sostiene
  (los personajes no chocan entre sí) dispara libre: el muro cubre de frente.
- El cliente solo controla yaw, pitch y `AIM_LEFT`, como en el cuerpo a cuerpo; `P` solo elige la
  dirección y nunca hace que la flecha atraviese nada. La puntería asistida por programa es de CMB-39.

### 4.5 Derribado, levantar y rematar (`DownedSystem`, `scripts/server/downed_system.gd`)

- **Cuándo**: la vida de un **jugador** (también los falsos) llega a 0 por un golpe, flecha o pulso cuyo
  autor es un jugador hostil en una zona RVR. Si no, muerte directa (PNJ, entorno, maniquí).
- **Caer**: `impose_downed`, `health = 0`, `downed_health = 400`, `downed_tick = s`, `downed_by`,
  `downed_source`, efectos borrados; DOWNED (toda la zona) y HIT con el bit 6.
- **Predicados** (`Combatant`): `is_alive()` = vida > 0, sin cambios; `is_downed()` = `downed_tick ≥ 0`;
  `is_dead()` = vida 0 y no derribado. Un derribado no es ni vivo ni muerto, y cada uso de hoy queda así:

| Dónde | Con un derribado |
|---|---|
| `CombatResolver._is_candidate`, `NpcWorld` (F4), `_rebuild_target_cache` (todos con `is_dead()`) | candidato, sin tocar el código |
| `CombatDirector._apply_hit` | descarta con `is_dead() or downed_tick == s` |
| `_apply_impact` → `take_damage` (devuelve 0 con vida 0) | `take_downed_damage`: sin bloqueo ni controles |
| `_process_environment` (volúmenes letales) | muere; asesino `downed_by` |
| `ZoneServer._gate_blockers` (`is_alive()`) | cuenta: la puerta no se repara con un derribado en el vano |
| `request_respawn`, `heal` (comando y consola), `regenerate` | lo rechazan (`request_respawn`: NOT_DEAD) |
| presencia en el círculo, `UnstuckTracker` (`is_alive()`) | sin cambios: no cuenta ni pide /atascado |
| `status_bits` | bit 3 de derribado (§5.2), sin DEAD |
| `_should_linger`, `_process_lingering`, `_remove_player` | ver «Salida» |

- **Desangrarse**: −1 cada 3 ticks (400 en 1200 ticks = 20 s). El daño enemigo (sin bloqueo posible) le
  quita de ahí; los controles no entran. A 0: muerte. DEATH y KILL con asesino = quien dio el último
  daño, o `downed_by` con fuente «desangrado» (§5.4) si fue el tiempo.
- **INTERACT** (paso 7): flanco en una entrada real (botones de `s` frente a los de `s − 1`, que guarda el
  `Combatant`) de alguien vivo, no derribado, en NONE o BLOCK y en el suelo; el derribado más cercano a ≤
  `interact_range_m` (horizontal, `|Δy| ≤ 1,5`; empate por `net_id`) **con línea de visión**
  (`HitShapes.is_ray_clear` del pecho, pies + 1,4, a pies + 0,5 del derribado; la puerta cerrada la
  corta):
  - **aliado** sin nadie levantándolo → `impose_interact(REVIVE)`; INTERACT 1 con `end_tick = s +
    revive_ticks`;
  - **enemigo** (sin zonas seguras de por medio) → `impose_interact(EXECUTE)`; INTERACT 4.
- **Seguir**: cada tick se corta (`impose_interrupt` si aún está en la acción; INTERACT 2 o 5) si quien
  actúa ha dejado la acción (soltó, esquivó o le impusieron otra), el objetivo ya no está derribado,
  pasa de `interact_keep_range_m` o se pierde la línea de visión, o uno de los dos recibe un impacto
  que interrumpe (§4.2). Lo predicho termina solo la acción: el servidor lo nota porque sale de REVIVE
  antes de tiempo.
- **Acabar** (se mira antes que seguir: en ese tick la simulación ya ha vuelto a NONE), en `s == inicio +
  duración`: levantar → `impose_revived`, vida 300, INTERACT 3; rematar → muerte con fuente «remate».
- **PNJ** (H3c, en el código de F4): no quedan derribados. En `NpcWorld` y `HfsmBrain`, un derribado
  hostil a ≤ 6 m es el objetivo preferido (antes que el más cercano en pie) y se ataca con PRIMARY;
  pide ficha de `AttackTokens` como cualquier objetivo. H3c lo anota en fuerte.md §4.2.
- **Fuerte**: un derribado no cuenta en el círculo (fuerte.md 1.2).
- **Salida**: toda baja de un derribado (CLIENT_LEAVE, caída de ENet, `--fake-churn` o el fin del plazo
  de un cuerpo que se quedó por GUE-41) es antes una **muerte en ese tick**: DEATH y KILL con asesino =
  quien dio el último daño, o `downed_by`, y fuente «desangrado»; después, DESPAWN. No hace falta
  mantener el cuerpo ni renovar «en combate», y al volver aparece en el campamento como cualquiera.
- **Comando 15** `down`: `downed_by = 0` (al desangrarse, DEATH sin KILL); rechazado fuera de las zonas
  RVR y en la zona segura propia.

### 4.6 Equipo, plantillas y consumibles

- `Combatant.template_id` es la vigente; la pendiente vive en `ServerPeer.pending_template_id` (−1 =
  ninguna; vale en LOADING e IN_WORLD): LOADOUT_SELECT (§5.1) la anota, y se copia al `Combatant` al
  darlo de alta (`_process_arrivals`) y en cada reaparición. Sin elegir, `default_template`; los falsos,
  `--fake-loadout`. Al aparecer, `set_loadout` o `reset_for_respawn` con sus armas y cargas, y LOADOUT
  al dueño y a quien lo tenga relevante.
- **Recarga** (cada 60 ticks): vivo, fuera de combate, en la zona segura de su reino y con menos cargas
  que su plantilla → `set_charges` con las cargas llenas y LOADOUT al dueño. Arma, reutilizaciones,
  ranuras y acción en curso no cambian.
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

## 5. Protocolo: `PROTOCOL_VERSION = 6`

«6: habilidades, efectos, cambio de arma, proyectiles, derribado y plantillas (docs/habilidades.md)». La
5 es del chat y los grupos (SOC-03, `0x40`–`0x4F`), que se fusionan antes; F4 no la cambia. Si cambia el
orden de fusión, la siguiente libre. `0x07` y los eventos 7–11 no chocan con SOC.

### 5.1 Entradas y mensajes C→S

- INPUT_BATCH sin cambios de formato; `VALID_BUTTONS` = bits 0–12 (§3.2).
- **LOADOUT_SELECT** (`0x07`, C→S, canal 3, 2 B): `u8 type`, `u8 template_id`. Vale desde el WELCOME,
  también antes de CLIENT_READY (LOADING e IN_WORLD; §4.6). `_on_packet_received` gana su caso, con el
  limitador de fiables. 0 = la de por defecto, sin aviso; un id que no existe o no es `selectable`
  cuenta un aviso.
- **DEBUG_COMMAND**, ids nuevos (fijos): 13 `cooldowns_off` (`u8` 0 o 1: bit7 de `combat_flags2`), 14
  `apply_status` (`u8 status_id`, `u16` ticks, 0 = los del dato), 15 `down` (se derriba a sí mismo, como
  si lo hubiera derribado un enemigo, pero con `downed_by = 0`; §4.5), 16 `refill` (repone las cargas
  con `set_charges`). Sin datos en 15 y 16.

### 5.2 Estado, snapshot y registro

- `PlayerState` de 111 B (§3.1) en el estado propio, en el SPAWN propio y en el ajeno.
- **SPAWN ajeno**: además de lo que ya es público, `alt_weapon_id` y el bit0 de `combat_flags2` (las
  armas se ven); reutilizaciones, cargas, consumible, ranuras de movimiento y bits de botones, a sus
  valores iniciales.
- **Registro** (21 B, sin cambios de tamaño): bit 3 de `flags` = ranura 2 activa. El remoto sabe qué
  arma lleva con la pareja (SPAWN o LOADOUT) y este bit. El byte de acción no tiene bits libres. El
  historial no toma este bit (§3.6).
- **Bloque extra propio** (9 B): bit 3 de `status` = derribado; derribado, `health` es la vida de
  derribado y `max_health` 400. El `health_q` de un derribado sale de esa vida (nunca 0: 0 es muerto).
- Cabecera de 134 B, 50 registros (§3.1).

### 5.3 PROJECTILE (kind 3)

**ENTITY_SPAWN**: cabecera de siempre (`net_id` = proyectil, `realm` = el del tirador, **bit0 de `flags`
(`is_yours`) siempre 0**: «tuya» es `owner` = tu `net_id`) y 22 B; total **32 B**. `NetClient._on_spawn`
mira `kind` antes que `is_yours`; `RemoteWorld` y `SwarmBot` ignoran el kind 3.

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
del impacto, que el servidor encontró en el segmento `[pos(n), pos(n + 1)]`, `n = despawn_tick −
spawn_tick` (§6.2).

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
| 9 LOADOUT | `u8 template_id`, `u16 weapon_1`, `u16 weapon_2`, `u8 charges` | 6 | 15 B | el jugador | dueño; y quien lo tenga relevante si cambian las armas, con `charges` = 0 |
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

- **Predicha**: `ClientPrediction` emite `stepped(tick, input, state)` tras **cada** `step()` (un tick
  de física puede dar 0, 1, 2 o más pasos; nunca en las repeticiones) y `ProjectileWorld` mira ahí
  `ActionMachine.is_commit_tick(state.combat, tick)`. Se crea con esa entrada, `AimRay` contra el mundo
  local y las cápsulas de los remotos **tal como se dibujan** (también la convergencia) y la misma
  cuantización. Se dibuja en el tiempo predicho; se para en el mundo con su propio rayo (primer segmento
  con `hit_from_inside`) y se oculta al tocar la cápsula dibujada de un enemigo (sin número).
- **Sustitución**: el SPAWN con `owner` propio se empareja con la predicha de la misma fuente y
  `volley_index` cuyo tick difiera ≤ `input_buffer_ticks`; se adoptan `p0`, `v0` y `spawn_tick` del
  servidor con un desfase visual que decae en 6 ticks. Sin pareja: se dibuja la del servidor. Una predicha
  sin SPAWN en `rtt + 30` ticks se retira (rechazo).
- **Remotas**: aparecen cuando `render_tick ≥ spawn_tick` y se dibujan en `pos(render_tick + fracción −
  spawn_tick)`. Con DESPAWN 4 se retiran cuando `render_tick + fracción ≥ despawn_tick + f`, con `f` la
  fracción de su propio rayo (mundo y cápsulas dibujadas) en el último segmento, o 1 si no toca nada: así
  llegan al muro o al blanco, como la propia. Con DESPAWN 5, en `despawn_tick`.

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
- **Arco**: tensando, la cámara cierra el campo de visión al 75 % del configurado (72° por defecto,
  `client_settings` lo cambia; no toca el brazo, así que el rayo canónico no cambia) y la retícula se
  cierra. `get_effective_shoulder()` (hombro tras el cambio automático) pone `AIM_LEFT`.

### 6.6 Animación provisional (pendiente del ojo del usuario)

`CombatClipPlanner` gana claves por nombre de habilidad y `swap`, `drink`, `downed`, `revive`,
`execute`, con un juego de clips por arma (`data/animation/<arma>_clips.tres`; nuevo `bow_clips.tres`).
Provisionales, con clips que hay (nombres comprobados en los `.glb`): `ual2/Shield_OneShot` (golpe de
escudo), `ual2/Shield_Dash` (embestida), `ual2/Idle_Shield_Loop` (muro), `ual2/Consume` (beber),
`ual1/Fixing_Kneeling` (levantar), `ual2/Melee_Hook` (rematar), `ual2/LayToIdle` (levantarse),
`ual2/NinjaJump_Start` (salto atrás), `ual1/Spell_Simple_Shoot` y `ual1/Pistol_Aim_Neutral` (arco),
`ual1/Death01` parado en su último fotograma (derribado quieto) y `ual1/Crouch_Fwd_Loop` (arrastrarse);
`swap` es un fundido de 0,4 s. `WeaponProps` gana un arco provisional (cilindro curvado) y cambia los
accesorios con el bit de ranura, también en los remotos (PRG-07 se ve, no solo en los datos).
**Pendiente del usuario**: tensar, mantener y soltar el arco y el ajuste de las poses y la sensación del
zoom (ART-41), arrastrarse, sacar y guardar el arma, modelos del arco y la flecha, VFX e iconos (ART-12).
El remoto anima con el byte de acción, el bit de ranura y la pareja de armas.

---

## 7. Paquetes y contratos

### 7.1 Paquetes

Todo H empieza con **F4 y SOC-03 a SOC-08 fusionados**: H1a toca `attack_definition.gd`, `attack_ticks.gd`,
`combat_catalog.gd` y sus pruebas, que F4 y SOC-03 ya cambian, y H2 y H4, los mismos archivos de red,
`zone_server.gd`, `input_bindings.gd` y `hud.gd` que SOC.

| Paquete | Contenido | Depende de |
|---|---|---|
| **H1a · estado y datos** | `CombatState` v5 (campos, constantes, `copy_from`, sin conducta nueva), `PlayerState` 111 B, botones de `PlayerInput`, recursos y `*Ticks` de §2.1, `CombatRules` nuevas, `CombatCatalog` (ids, validación, huella), `CombatSource`, `Ballistics` (`position`, `quantize`), todos los `.tres` de §2.3, backlog.md (§0) | F4, SOC |
| **H1b · máquina** | `ActionMachine` (§3, partida en `ability_rules.gd`), `ActionWire` (§5.5: ranura, consumible, contador de SWAP), `PlayerCharacter.simulate` con `speed_factor` y `rooted`, `AimRay` (`canonical`, `aim_point`, `look_for`), `Ballistics.solve_lead`, `HitShapes` (fracciones), `DamageFormula` (modificadores) | H1a |
| **H2 · protocolo v6** | `PROTOCOL_VERSION`, `VALID_BUTTONS`, LOADOUT_SELECT, ids 13–16, SPAWN y DESPAWN de proyectiles, eventos 7–11, bits de HIT, bit 3 de `flags` y de `status` en los mensajes, red.md (filas nuevas de §5.2 con «v6», versiones de §5.3, §5.4, §5.5 y §14) | H1a |
| **H3a · habilidades y efectos** | orden del tick (§4.1, con los pasos de H3b y H3c vacíos), golpe sintetizado en `Combatant.freeze` y el resolutor, `StatusSystem`, interrupciones, muro cuerpo a cuerpo, protección, muestra antigua (§4.2), `is_ray_clear` desde dentro, byte del historial (§3.6), `_hide_private_state`, publicación del bit 3, `InputQueue.get_applied`, comandos 13–14, registro de combate | H1b, H2 |
| **H3b · proyectiles** | `ProjectileSystem`, `allocate_transient_id`, `StateHistory.position_at` y cajas barridas, caja del muro, topes, bajas del tirador | H3a |
| **H3c · derribado y plantillas** | `DownedSystem`, predicados (§4.5), salida, `HfsmBrain`/`NpcWorld`, plantillas, `ServerPeer.pending_template_id`, LOADOUT_SELECT en `ZoneServer`, recarga, comandos 5, 15 y 16 | H3b |
| **H4 · cliente** | `ProjectileWorld`, `ClientPrediction.stepped`, `ActionBar`, `StatusTracker`/`StatusIcons`, avisos de derribado, selector de plantilla, zoom y retícula del arco, teclas Q/R/T y bit `AIM_LEFT`, explicaciones nuevas de `NetClient`, textos (`CombatText`), clips y `WeaponProps` provisionales | H1b, H2 |
| **H5 · integración** | `BotBrain` de combate con habilidades (mantiene el botón de una canalización), cambio de arma, pociones y arco (`solve_lead` + `look_for`); modos tramposos `reuse`, `potion`, `interact` (`bot_cheat_brain.gd`, `bot_cheater.gd`, `client_config.gd`); pruebas de extremo a extremo y carga de §7.3; hoja de equilibrio medida (§2.4 → combate.md §12); límite de jugadores en red.md §14 | H3c, H4 |

H2 y H1b en paralelo tras H1a; H3a → H3b → H3c en serie (todos tocan `zone_server.gd` y
`combat_director.gd`) y H4 a la vez; H5 al final. Con dos agentes: uno H1a → H1b → H3a → H3b → H3c, otro
H2 → H4 → H5.

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
static func reset_cooldowns(c: CombatState) -> void; static func set_charges(c: CombatState, charges: int) -> void
static func set_loadout(c: CombatState, weapon_1: int, weapon_2: int, charges: int) -> void  # al aparecer
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
		capsule_feet: PackedVector3Array) -> Vector3   # hostiles; con la convergencia de §4.4
static func muzzle(feet: Vector3) -> Vector3
static func look_for(feet: Vector3, point: Vector3, left_shoulder: bool) -> Vector2   # (yaw, pitch)

# scripts/shared/combat/ballistics.gd · class_name Ballistics extends RefCounted
static func position(p0: Vector3, v0: Vector3, gravity: float, ticks: float) -> Vector3
static func quantize(p0: Vector3, v0: Vector3) -> Array    # [p0, v0] como viajan
static func solve_lead(origin: Vector3, target: Vector3, target_velocity: Vector3, speed: float,
		gravity: float) -> Vector3                       # dirección (bots y PNJ)

# scripts/shared/combat/hit_shapes.gd (amplía); devuelven 0..1, o -1 si no toca
static func segment_capsule_fraction(a: Vector3, b: Vector3, capsule_feet: Vector3, radius: float,
		height: float) -> float
static func segment_box_fraction(a: Vector3, b: Vector3, box: Transform3D, half_extents: Vector3) -> float
# (0 si a está dentro); is_ray_clear pasa a hit_from_inside = true
# damage_formula.gd: compute(..., damage_scale: float = 1.0, mitigation_penalty: float = 0.0)

# scripts/server/combatant.gd (amplía); Frozen gana hit: AttackTicks, commit: bool, wall: Transform3D
var effects: Array[StatusSystem.ActiveEffect]
var downed_health: int; var downed_tick: int = -1; var downed_by: int; var downed_source: int
var interact_target: int; var interact_action: int; var interact_start: int; var last_buttons: int
var template_id: int              # la pendiente, en ServerPeer.pending_template_id (−1 = ninguna)
func is_downed() -> bool; func take_downed_damage(amount: int, tick: int) -> int   # is_dead(): §4.5

# scripts/server/projectile_system.gd · class_name ProjectileSystem extends RefCounted
signal spawned(spawn: NetMessages.EntitySpawn, recipients: PackedInt32Array)
signal despawned(projectile_id: int, tick: int, reason: int, recipients: PackedInt32Array)
func fire(shooter: Combatant, source: int, s: int, space: PhysicsDirectSpaceState3D) -> void
func resolve(s: int, combatants: Array[Combatant],
		space: PhysicsDirectSpaceState3D) -> Array[CombatResolver.Hit]   # Hit gana projectile_id
func live_count() -> int; func forget_owner(owner_id: int, s: int) -> void   # DESPAWN 5 de las suyas

# scripts/server/status_system.gd · class_name StatusSystem extends RefCounted
func apply(target: Combatant, status_id: int, source_id: int, s: int) -> void
func step(s: int, list: Array[Combatant]) -> void; func clear(target: Combatant) -> void

# scripts/server/downed_system.gd · class_name DownedSystem extends RefCounted
func should_down(victim: Combatant, author_realm: int, author_is_player: bool) -> bool
func down(victim: Combatant, author_id: int, source: int, s: int) -> void
func step(s: int, list: Array[Combatant], space: PhysicsDirectSpaceState3D) -> void

# input_queue.gd: get_applied(tick) -> PlayerInput (real o sustituida)
# state_history.gd: position_at(id, tick) -> Vector3 (Vector3.INF si no está); swept_box(id) -> AABB
# client_prediction.gd: signal stepped(tick: int, input: PlayerInput, state: PlayerState)
# net_entity_registry.gd: allocate_transient_id(tick) -> int; release_transient_id(id, tick)
# camera_rig.gd: get_effective_shoulder() -> int; set_aim_zoom(f: float)
# net_client.gd: signal projectile_spawned(spawn); signal projectile_despawned(id, tick, reason)
```

### 7.3 Pruebas (cada una < 30 s)

Ninguna lleva cotas de microsegundos (la máquina es compartida): el coste se mide con herramientas (§8).

**H1a y H1b** (sin red, mundos en `SubViewport` como `test_prediction`):

- `test_combat_state_v5`: ida y vuelta con cada campo en su offset; 76 y 111 B; `buffered` nuevo.
- `test_ability_machine`: empieza con el flanco; reutilización fijada en el compromiso (con `cast = 0`,
  en el mismo tick); vuelve a valer en `t == ability_ready`, no antes; tambaleo en el lanzamiento → sin
  reutilización; **el tambaleo corta una canalización** y fija su reutilización en ese tick; soltar,
  moverse (si lo dice el dato) y el tope acaban la canalización; los ejemplos de §3.3 (soltar y pulsar
  en el mismo tick; toque más corto que el lanzamiento; soltar en el compromiso y uno después; muro del
  búfer con el botón arriba); prioridades con flancos simultáneos; búfer de una habilidad pulsada en la
  recuperación de un ligero, y una que caduca deja `combo_step = 0`; una sustituida no empieza nada.
- `test_ability_reconciliation`: **la reutilización sobrevive a una reconciliación**: cliente y servidor
  con las mismas entradas, una diferencia de posición impuesta tras el compromiso; tras repetir,
  `ability_ready` es el mismo y el estado coincide byte a byte.
- `test_weapon_swap`: intercambio de armas y de las dos mitades; **no se cambia a mitad de un golpe**
  (SWAP en anticipación o activo: el arma no cambia hasta la recuperación; caduca si no llega);
  **predicho y reconciliado** con una entrada sustituida alrededor del flanco: estados iguales;
  `set_charges` no toca nada más.
- `test_move_effects`: **la ralentización da la misma velocidad en cliente y servidor** (el servidor la
  impone en `s`; tras reconciliar, estados iguales cada tick y velocidad = `run_speed · 0,6`); ROOT
  impide esquivar y avanzar; caducidad en el tick exacto; tercera ranura sustituye a la que acaba antes.
- `test_consumables_machine` (cargas, reutilización compartida, compromiso al acabar de beber, +400
  exactos, sin cargas no empieza) y `test_bow_machine` (toque = disparo rápido, 8 ticks = tensado, cargas
  mínima y máxima en sus ticks, BLOCK no hace nada, agotado no tensa).
- `test_aim_ray`: el rayo canónico coincide con `CameraRig.get_aim_ray()` (sin colisión, cualquier zoom
  y FOV, los dos hombros) a menos de 1 mm, y `aim_shoulder_offset`/`aim_camera_v_offset` con la escena;
  **tiro adelantado con el fondo a 150 m**: blanco a 30 m y mira 3 m por delante, la recta de la flecha
  cruza la de la mira a menos de 2 cm a la profundidad del blanco; `look_for` pasa a < 1 mm del punto;
  `Ballistics` y la cuantización.
- `test_combat_catalog` (amplía): ids pedidos por nombre; cada error de §2.2; la huella cambia con un
  tiempo de habilidad, `downed_move_scale`, `revive_s` y `blocks`, y no con un daño; el camino rápido de
  `simulate()` no llama a `CombatCatalog.weapon()` ni recorre ranuras (contador; el microbanco, a
  `tools/combat_balance.gd`).
- `test_action_wire` (amplía, H1b): ABILITY por ranura y fase, consumible (3), contador de SWAP.

**H2**: `test_net_messages` (amplía): ida y vuelta y tamaños de los eventos 7–11, del SPAWN de 32 B (con
`is_yours` 0) y de LOADOUT_SELECT; truncados y `op` fuera de rango → `null`; `VALID_BUTTONS`; `CombatSource`;
bit 3 de `flags`; *fuzz*. `test_snapshot_builder`: 50 registros y nunca más de 1200 B.

**H3a, H3b y H3c** (servidor en un proceso, `combat_fixture.gd`; las largas avanzan a mano con
`CombatDirector.process_tick`, como `test_combat_director`, o `ZoneServer._physics_process`, como
`tools/combat_balance.gd`, sin esperar fotogramas):

- `test_ability_server` (H3a): golpe de escudo aturde de frente y no por detrás, atraviesa un escudo en
  alto; la embestida recorre 6 m (±0,3) y empuja; el muro bloquea un golpe a 85° del frente y no a 95°;
  **el servidor rechaza una habilidad en reutilización** (bot que la pulsa un tick de cada dos:
  compromisos separados exactamente `cooldown_ticks + cast_ticks`); una habilidad quita la protección y
  beber no; muestra antigua: REVIVE soltado y poción interrumpida dentro del rebobinado no bloquean;
  ranura 2 activa sin bloquear → `flags & DEFENSE_BLOCKING == 0` en el historial; desde dentro del vano
  cerrado no se golpea hacia fuera ni se recibe.
- `test_status_effects` (H3a): **un sangrado hace exactamente N pulsos** (6, en `anchor + 60k`);
  acumulación, renovación y el más fuerte; un pulso no interrumpe; un pulso que derriba a mitad de la
  lista; limpieza al morir, al quedar derribado y al irse el autor; STATUS con su `until_tick`.
- `test_projectiles` (H3b): **ninguna flecha atraviesa muros** (40 disparos con ángulos distintos a un
  blanco tras un muro: 0 impactos, todas con DESPAWN 4 en el muro); **disparo pegado a una esquina**
  (cámara al lado abierto, blanco que solo ve la cámara: la flecha da en la esquina); dueño en el vano
  cerrado: se clava en el origen; bloqueo frontal; esquiva que deja pasar; el muro para flechas a un
  aliado detrás, desde lejos y con el arquero dentro de su caja, y no si está detrás de quien lo sostiene;
  segmento que empieza en una cápsula; topes: con 8 del tirador o 64 en la zona un disparo nuevo existe y
  sale la más vieja; el tirador se va con flechas en el aire (DESPAWN 5); golpe a la puerta.
- `test_downed` (H3c): **los tres desenlaces**: levantado (180 ticks, vida 300, NONE), rematado (60
  ticks, DEATH con fuente de remate y KILL) y desangrado (1200 ticks, asesino = quien derribó); levantar
  cortado por daño; no se remata a través de la puerta cerrada; la puerta no se repara con un derribado
  en el vano; **un derribado que sale produce DEATH y KILL** y al volver aparece en el campamento; muerte
  directa contra un PNJ; un PNJ no ignora a un derribado y lo remata con daño; comando 15 sin KILL.
- `test_consumables_server` (H3c): curación de 6 pulsos; **un golpe que interrumpe** no gasta carga ni
  reutilización; recarga en el campamento **con la ranura 2 activa y una canalización en curso**: arma,
  `ability_ready` y acción no cambian; LOADOUT ajeno con `charges` 0.

**H4**: `test_action_bar` (iconos del arma tras un cambio; **un rechazo revierte el contador**: una
reconciliación que quita la habilidad deja la casilla lista), `test_status_icons` (placa y fila propia; se
va al caducar), `test_projectile_world` (la predicha se sustituye por la del servidor; dos pasos en un tick
de física con el compromiso en el primero; SPAWN propio con el jugador ya en el mundo; la remota aparece en
su `render_tick` y se retira en `despawn_tick + f`), `test_hud_combat` (amplía: avisos de derribado).

**H5** (ENet en loopback, `net_harness.gd`):

- `test_projectile_loopback`: **flecha a 30 m con rtt=150** (jitter 30) contra un objetivo que corre en
  lateral, apuntada con `solve_lead` y `look_for`: al menos 18 de 20 tensados confirmados; control en la
  misma ejecución, como `test_combat_loopback`: contra la posición presente (sin rebobinar) habrían
  acertado menos de 10.
- `test_abilities_reconciliation`: **3 bots con NetSim** (`rtt=120, jitter=20, loss=5`, 900 + 180 ticks)
  con las dos plantillas usando habilidades, cambio de arma, pociones, flechas, ralentizaciones y
  derribos: todas las correcciones explicadas (sustitución, teletransporte o combate), ningún reinicio
  duro tras el arranque y convergencia exacta al quedarse quietos (la aceptación de la fase 2).
- `test_loadout_net`: dos clientes eligen plantillas distintas (uno antes de CLIENT_READY) y cada uno ve
  las armas del otro (PRG-07); sin pérdida, **0 correcciones en ±rtt ticks alrededor de cada SWAP**
  (PRG-04); un sangrado del comando 14 sale con su duración en la placa y el HUD y se va al caducar (UI-45).
- `test_bot_cheat` (amplía): `reuse`, `potion` e `interact` sin efecto de más ni sospecha.
  `test_combat_balance` (amplía): DPS del arco igual al calculado; maniquí a 10, 30 y 50 m; rotura del
  muro 1 y 2 contra 1 (§2.4).
- **Carga** (`load_test.gd --brawl`, manual como TEC-15): Vado Gris, 64 jugadores (`--fake-loadout=
  marksman:50`), los PNJ del fuerte y el tope de zona lleno: p99 del tick ≤ 16,7 ms y la sección de
  proyectiles ≤ 1 ms; si no, se baja el límite de red.md §14.

---

## 8. Riesgos

- **CPU de los proyectiles** (revisado con sondas, máquina compartida). Una muestra del historial cuesta
  2,4–3,4 µs (objeto y diccionario); con la criba por distancia del resolutor, una flecha cuesta 16 µs
  por tick con los candidatos dispersos y 105–115 µs en una refriega de 20 × 20 m, donde todos pasan la
  criba: 20 flechas, 2,1 ms, y el margen del p99 (15,9 ms con 64, más el fuerte y los PNJ de F4) ya está
  gastado. Con rebobinado entero, `position_at` y cajas barridas por bloques (§4.4): 50–90 µs fijos por
  tick y 9–13 µs por flecha, densa o dispersa (0,4 pruebas exactas por flecha); `intersect_ray` de un
  tick, 0,6 µs. De ahí la reserva de **1 ms con 64 jugadores** y el tope de **64 flechas por zona**
  (0,7–0,9 ms). H5 lo mide en carga (§7.3); si el p99 del tick pasa de 16,7 ms, se baja el límite de
  jugadores de red.md §14. Una rejilla sobre las cajas podría subir el tope. Terrain3D real, sin medir.
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
- **F4 y SOC**: ningún paquete H empieza hasta fusionarlos (§7.1).

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

---

## 10. Revisión

Tres revisores (predicción y red, servidor y trampas, implementabilidad): 42 hallazgos sobre la versión
1, los repetidos en una fila. Comprobados en el código y los documentos, todos se sostienen; tres se
resuelven de otra forma («en parte»). Los dos cambios fijos (versión 6; topes de proyectiles con su
comportamiento y prueba de carga) van en PRE3 y SER2–SER3.

| Id | Gravedad | Qué era | Qué se hizo |
|---|---|---|---|
| PRE1 · SER7 · IMP3 | bloqueante | La recarga y `refill` usaban `set_loadout`: cambiaban el arma activa, ponían a 0 las reutilizaciones y dejaban una ABILITY con el arma equivocada | `set_charges` solo toca las cargas; `set_loadout` y `reset_for_respawn`, solo al aparecer y, sobre un vivo, con NONE antes (§3.5, §4.6); prueba en `test_consumables_server` |
| SER1 · SER9 · IMP2 | bloqueante | Un derribado que salía se libraba de morir y de dar la baja; `is_alive` e `is_dead` dejaban de ser complementarios y el código los usa como si lo fueran | Toda baja de un derribado es antes una muerte con DEATH y KILL; tabla de predicados por sitio de uso (§4.5); pruebas en `test_downed` |
| IMP1 | bloqueante | El rayo canónico no contaba el `v_offset` de 0,1 de la cámara; FOV absoluto; sin inversa para bots | `aim_camera_v_offset` comprobado con la escena; zoom al 75 % del FOV configurado; `AimRay.look_for` (§2.1, §4.4, §6.5) |
| PRE2 | importante | El bit 3 del registro (ranura 2) es `DEFENSE_BLOCKING` en el historial | El historial toma `flags & 0b111` y lo dicen los comentarios (§3.6, §5.2); prueba en H3a |
| PRE3 · IMP5 | importante | La versión 5 ya es del chat y los grupos; H2 y H4 chocan con SOC | `PROTOCOL_VERSION = 6` (§5); todo H tras F4 y SOC (§7.1); H2 marca «v6» en red.md |
| PRE4 | importante | Sin orden entre fines de canalización, búfer y flancos, ni regla para soltar en el tick del compromiso | 4a fines, 4b búfer, 4c flancos; la canalización que no pasa del compromiso no gasta; la del búfer exige el botón; ejemplos en §3.3 y `test_ability_machine`; los bots mantienen el botón (H5) |
| PRE5 · IMP6 · IMP9 | importante | H1 ∥ H2 no era posible, H1 sin F4, §5.5 sin paquete, tramposos en el paquete de servidor, H1 y H3 demasiado grandes | Paquetes H1a, H1b, H2, H3a, H3b, H3c, H4 y H5 con sus dependencias (§7.1); §5.5 y `test_action_wire` en H1b; tramposos y `test_bot_cheat` en H5 |
| PRE6 | importante | La flecha va del pecho a `P`; con el tiro adelantado `P` cae en el fondo y la flecha se desvía hasta 0,59 m | Convergencia a la profundidad del hostil más cercano a la mira (`aim_converge_deg` 12); `look_for` para bots; prueba con el fondo a 150 m (§4.4, §7.3) |
| SER2 | importante | El coste de las flechas no cabía en una refriega densa; 256 por zona no caben en el tick; `AimRay` sin presupuestar | Rebobinado entero, `position_at` y cajas barridas por bloques (medido: 9–13 µs por flecha); reserva de 1 ms; **en parte**: tope de 64 por zona, no 96, con lo medido; carga en H5 con criterio de p99 (§4.4, §8) |
| SER3 | importante | Con la zona llena el disparo no se creaba: negación de disparo y flecha fantasma | Un disparo nunca se rechaza: sale la más vieja del tirador o de la zona, con DESPAWN 5 (§4.4); prueba en `test_projectiles` |
| SER4 | importante | El dueño en el vano de su puerta dispara y golpea desde dentro del cuerpo de vista | Primer segmento y `is_ray_clear` con `hit_from_inside`; frase de las esquinas corregida (§4.4); pruebas en H3a y H3b |
| SER5 | importante | Segmentos que empiezan dentro del muro o de una cápsula; efectos del BLOCKED del muro; instante del muro | Fracción 0; BLOCKED como un bloqueo (sin daño, 0,6 por punto, rotura de guardia); el muro se prueba en `k` (§4.4) |
| SER6 | importante | Las habilidades no quitaban la protección de reaparición | La quita toda ABILITY que no sea consumible (§4.2); prueba en `test_ability_server` |
| SER8 | importante | Levantar y rematar sin línea de visión, también a través de la puerta | `is_ray_clear` al empezar y en cada tick (§4.5); prueba en `test_downed` |
| PRE13 · SER10 · IMP11 | importante | Flechas y efectos huérfanos cuando el autor se va | El proyectil guarda una copia del autor; al darlo de baja, DESPAWN 5 de sus flechas y STATUS 2 de sus efectos (§4.1, §4.4) |
| SER12 · IMP8 | importante | `NpcBrain` no es el cerebro del fuerte y F4 no prioriza derribados | `HfsmBrain` y `NpcWorld`; la prioridad la pone H3c y se anota en fuerte.md §4.2 (§4.5) |
| IMP4 | importante | El SPAWN de proyectil usaba `is_yours` y `NetClient` lo descartaba como personaje propio | `is_yours` = 0 en kind 3; «tuya» por `owner`; despacho por `kind` (§5.3) |
| IMP7 | importante | Pruebas de más de 30 s y un rebobinado apagado que no existe | 900 + 180 ticks; H3 avanza a mano y 40 disparos; **en parte**: control contrafactual en la misma ejecución, como `test_combat_loopback`, sin interruptor nuevo (§7.3) |
| IMP10 | importante | Desvíos de CMB-21, CMB-23, CMB-24 y PRG-04 sin anotar; PRG-04 y UI-45 sin prueba que los demuestre | Fila en §0 y nota en backlog.md; 0 correcciones alrededor de SWAP y sangrado del comando 14 en `test_loadout_net` |
| PRE7 | menor | La remota se retiraba en `despawn_tick`, hasta 1,2 m antes del impacto; «f64» frente a `Vector3` | Retirada en `despawn_tick + f` con el rayo local; la misma `Ballistics.position` con `n` entero o fraccionario (§4.4, §6.2) |
| PRE8 | menor | Mirar el compromiso una vez por tick de física pierde pasos de predicción | `ClientPrediction.stepped` tras cada `step()`; prueba con dos pasos (§6.2) |
| PRE9 | menor | `pending_template_id` en un `Combatant` que no existe antes de CLIENT_READY; `0x07` sin despacho | En `ServerPeer`, copiada al dar de alta; caso `0x07` con el limitador (§4.6, §5.1) |
| PRE10 | menor | Cambiar `buffered & 3` por `buffered_type()` sin más rompía `linked` y `_run_buffer` | Despacho por tipo; `linked` = PRIMARY o enlace; la caducidad pone el combo a 0 (§3.1) |
| PRE11 | menor | La huella dejaba fuera campos P (derribado, interacción, `blocks`) | Entra todo campo P; prueba en `test_combat_catalog` (§2.2) |
| PRE12 | menor | La muestra antigua del bloqueo contaba tras volver a NONE desde REVIVE, una poción o una interrupción | No cuenta si la acción no es BLOCK y empezó después de `view_tick`; cambia combate.md §4.3 (§4.2); pruebas en H3a |
| SER11 | menor | Sin definir qué impacto interrumpe ni qué es «bebiendo»; un derribo a mitad de los pulsos | Definidos (§0, §4.2); `StatusSystem.step` reúne los pulsos antes de aplicarlos (§4.1, §4.3) |
| SER13 | menor | Cualquier plantilla elegible, id 0 sin definir, comando 15 con `downed_by` propio | `selectable` y validación sin `npc_*`; 0 = por defecto; comando 15 con `downed_by = 0`, solo en RVR (§2.1, §4.5, §5.1) |
| IMP12 | menor | LOADOUT revelaba las cargas a los enemigos | `charges` = 0 para quien no es el dueño (§5.4) |
| IMP13 | menor | Sin columna de resistencia; un atacante no rompe el muro; agotado no se tensa | **En parte**: párrafo de resistencia (§2.4); el muro que uno solo no rompe es a propósito y H5 lo mide; el agotamiento impide tensar y el muro, escrito |
| IMP14 | menor | Faltaban `downed`, `swap` y un arco provisional | `Death01`, `Crouch_Fwd_Loop`, fundido de 0,4 s y arco en `WeaponProps`; pendientes del usuario marcados (§6.6) |
| IMP15 | menor | Cota de 2 µs en una prueba | Contador de llamadas determinista; el microbanco, informativo en `tools/combat_balance.gd` (§7.3) |

---

## 11. Implementación

Lo que hizo cada paquete, sus desvíos de este documento (que se escribió antes de fusionar F4, F6a,
F6b y el protocolo 5 del chat y los grupos) y lo medido.

### 11.1 H1a · estado y datos

**Hecho.**

- `CombatState` v5 (`scripts/shared/combat/combat_state.gd`): acciones 9–13 (ABILITY, SWAP, DOWNED,
  REVIVE, EXECUTE), `ENCODED_SIZE` 76, los campos de §3.1 en sus offsets (`alt_weapon_id`,
  `combat_flags2`, `ability_ready` como `PackedInt64Array` de 6, `consumable_ready_tick`,
  `consumable_charges`, `move_effect_ids` y `move_effect_until`), `initial(rules, weapon, alt_weapon,
  charges)`, `copy_from` elemento a elemento (los `Packed*Array` se pasan por referencia: comprobado
  en 4.7.2), `buffered_type()`/`buffered_ticks()` con el formato nuevo, `charges_of()`,
  `is_second_slot()` y las constantes `FLAG2_*` y `BUFFER_*` (4–9). `PlayerState` pasa a 111 B.
- `PlayerInput`: `SWAP_WEAPON` (bit 9), `AIM_LEFT` (10), `CONSUMABLE_1` (11) y `CONSUMABLE_2` (12).
- Recursos nuevos `AbilityDefinition`, `StatusEffectDefinition`, `ProjectileDefinition` y
  `EquipmentTemplate`, con sus `AbilityTicks`, `StatusTicks` y `ProjectileTicks`; `AttackDefinition`
  gana `projectile`, `projectile_speed_mps`, `charge_speed_scale`, `stun_s` y `on_hit_status` (y la
  forma puede ser nula con proyectil); `WeaponDefinition`, `abilities` y `can_block` (el combo ligero
  admite de 1 a 3 golpes); `CombatRules`, todos los campos de §2.1.
- `CombatCatalog`: seis espacios de ids por orden alfabético, todos pedidos por nombre
  (`ability_id`, `status_id`, `projectile_id`, `template_id`); `ability()`, `status()`,
  `projectile()`, `template()`, `template_count()`, `consumable_ids()`; dueño de cada habilidad
  (arma y ranura o consumible), golpe sintetizado con la fuente de la habilidad como id, avances
  horneados como la esquiva, la validación de §2.2 y la huella con `_HASH_FORMAT` 2.
- `CombatSource` (`make`, `kind_of`, `id_of`, `EXECUTE`, `BLEED_OUT`) y `Ballistics` (`position` con
  `n` entero o fraccionario, `quantize` a 1 cm y 1 cm/s con `NetMath`, como el SPAWN).
- Datos de §2.3 en `data/combat/`: `shield_bash`, `shield_rush`, `shield_wall` (en las ranuras de
  `sword_shield.tres`) y sus dos formas; `bow`, `bow_quick`, `bow_drawn`, `bow_volley`,
  `bow_slowing_shot`, `bow_evasive_shot`; `arrow`; `potion_health` y `potion_stamina` (los
  `consumables` de las reglas); `slowed`, `potion_regen`, `bleed`, `rooted`; `squire` (la
  `default_template`) y `marksman`.
- backlog.md: las cuatro decisiones de §0 y los desvíos de CMB-21, CMB-23, CMB-24 y PRG-04 ya estaban
  anotados al cerrar este diseño; H1a añade las notas «Hecho (H1a)» de lo que deja hecho.

**Pruebas.** `test_combat_state_v5` (nueva, 12: offsets de cada campo nuevo dentro de `PlayerState`,
76 y 111 B, ida y vuelta, u32 de los ticks, el `buffered` nuevo y la esquiva guardada con él,
`initial`, cargas, ranura activa, copia de los arrays, `equals` y la reconciliación notan cada campo,
`reset_for_respawn`); `test_combat_catalog` (de 25 a 35: los seis espacios de ids por nombre, los
kits de espada y escudo y de arco, pociones, efectos, plantillas y reglas en ticks, el golpe
sintetizado, cada error de §2.2, los ids de efectos y plantillas en u8, la huella con 47 cambios
predichos —tiempos de habilidad, `downed_move_scale`, `revive_s`, `blocks`, puntería, efectos,
flecha…— y 27 de solo servidor —daños, formas, controles, pulsos, derribado, muros, topes y
plantillas— y el camino rápido de `simulate()` sin buscar arma ni habilidades, con los contadores
`weapon_lookups` y `ability_lookups` de `CombatTables`); `test_ballistics` y `test_combat_source`
(nuevas, 6 y 3); `test_player_input`, `test_combat_state`, `test_player_state`, `test_net_entity`,
`test_net_messages` y `test_snapshot_builder` adaptadas a 111 B y al `buffered` nuevo.

**Desvíos y decisiones.**

- **`consumables`: 0 o exactamente 2.** Las reglas sin pociones (`CombatRules.new()`, las de las
  pruebas que montan catálogos a mano) son válidas; con alguna, han de ser dos. El catálogo real
  lleva las dos (lo prueba `test_combat_catalog`). Igual `default_template`: puede ser nula
  (`default_template_id()` = 0) fuera de `data/combat/`.
- **Huecos y habilidades sueltas.** Un `null` en `WeaponDefinition.abilities` es una ranura vacía (un
  arma puede llevar solo la 3). Una habilidad que no lleva ningún arma ni es consumible es válida
  (ranura −1, arma 0) y no se puede usar.
- **Validaciones de más**: el activo dura al menos un tick (el del compromiso, también en una
  canalización); un consumible lleva `interrupt_on_damage` (§2.1: «siempre true»); velocidad de un
  proyectil ≤ 327,67 m/s (viaja en s16 de cm/s), también a carga máxima; ids de ataques y habilidades
  en 14 bits (la fuente); una plantilla lleva una o dos armas y dos cargas de 0 a 15.
- **Valores que §2.3 no fija**: `dash_curve` nula = plana (la embestida); el salto atrás frena de 1 a
  0,4 en su ventana; el tensado cancela a esquiva desde su recuperación (tick 4) y, como el rápido,
  mueve ×0,5 y gira 8 mientras dispara; las tres habilidades de arco, ×0,5 y giro 8; las pociones,
  giro 6; `rooted` renueva; las formas nuevas van de 0,2 a 2,0 m de alto, como la de la espada.
- **`buffered` y la máquina.** Cambiar el formato obliga a tocar `ActionMachine`: `_run_buffer`
  despacha por tipo (1 y 3 ligero, 2 esquiva; los tipos 4–9 los descarta hasta H1b, y nadie los
  guarda), `linked` es PRIMARY o enlace (§3.1) y la caducidad de cualquier tipo con el ligero ya
  acabado pone `combo_step = 0`. Lo único que cambia de conducta es un caso de esquina: una esquiva
  guardada en el aire que sustituyó a la pulsación que enlazaba y caduca reinicia el combo (antes lo
  dejaba a medias). `test_action_machine` sigue entera (73).
- **`reset_for_respawn(c, tick)`** conserva su firma hasta H1b: ahora guarda las dos armas, la ranura
  activa, las cargas y los botones mantenidos de `combat_flags2`, y pone a 0 reutilizaciones y
  ranuras de movimiento.
- **Protocolo.** `PROTOCOL_VERSION` sigue en 5 y `VALID_BUTTONS` en los bits 0–8 hasta H2: el formato
  del estado ya es el de 111 B en los dos lados y la huella nueva cambia el `sim_hash`, así que un
  cliente anterior no entra. `test_snapshot_builder` y `test_net_messages` ya comprueban los 50
  registros de §3.1 (cabecera de 134 B, 1186 B llenos); la prueba de propiedades del constructor
  da a su observador C 30 relevantes en vez de 40 para que, con las 15 que entran, sigan cabiendo
  todas en 50 plazas (antes eran 52).
- **Ayudas de más**: `CombatState.pack_buffer`/`pack_charges`, `CombatCatalog.template_weapons`/
  `template_charges`/`default_template_id`, las duraciones de las reglas en ticks en `CombatTables`
  (`swap_ticks`, `revive_ticks`, `execute_ticks`, `consumable_cooldown_ticks`, `downed_ticks`),
  `CombatSource.name_of` (para el registro de combate de H3a) y consultas de `AbilityTicks` y
  `StatusTicks` (`is_dashing`, `dash_speed_at`, `is_movement`, `has_pulses`, `is_harmful`).

**Medido** (máquina compartida, 4 núcleos con otros trabajos; orientativo): `PlayerState.encode`
2,3–3,2 µs, `PlayerState.decode` 18–22 µs, `CombatState.duplicate_state` 6–7 µs, `copy_from`
1,8–2,6 µs, `CombatState.new` 4,2–4,7 µs (los tres arrays suman ~1,4 µs por estado, medido aparte
contra un objeto igual sin ellos) y el camino rápido de `ActionMachine.step` 3,3 µs. El decode
sigue creando un `CombatState` inicial que tira (el valor por defecto de `PlayerState.combat`); no
se toca aquí.

**Para los paquetes siguientes.** H1b: la conducta de §3 (máquina, `ActionWire`, `simulate` con
`speed_factor` y `rooted`, `AimRay`, `Ballistics.solve_lead`, fracciones de `HitShapes`, modificadores
de `DamageFormula`) y la firma nueva de `reset_for_respawn`/`set_loadout`; el camino rápido debe seguir
sin tocar los contadores de `CombatTables`. H2: `PROTOCOL_VERSION` 6, `VALID_BUTTONS` hasta el bit
12 y red.md. H3a: `_hide_private_state` con los campos nuevos (hoy el SPAWN ajeno los lleva a su
valor inicial porque nadie los rellena todavía).

### 11.2 H1b · máquina

**Hecho.**

- `ActionMachine` (§3.3 a §3.6) partida en dos: la entrada y lo de la fase 3 siguen en
  `action_machine.gd`; habilidades, consumibles, canalizaciones, cambio de arma, levantar y rematar,
  derribado y efectos de movimiento, en `ability_rules.gd` (`AbilityRules`, que solo llama la
  máquina). El orden fijo de §3.3: 0 camino rápido (además sin ABILITY, SWAP ni CONSUMABLE pulsados
  ni en `combat_flags2`, y con las dos ranuras de movimiento libres; sigue sin buscar arma ni
  habilidades), 1 fin de acciones (ABILITY, canalización al tope con su reutilización, SWAP, REVIVE,
  EXECUTE; DOWNED y DEAD no acaban), 2 caducidad de las ranuras, 3 resistencia (no en la canalización
  que bloquea), 4a fines por entrada, 4b el búfer despachado por tipo, 4c los flancos por prioridad,
  5 compromiso y 6 movimiento (tabla de §3.4 y `Output.speed_factor`/`rooted`).
- Lo que impone el servidor (§3.5): `impose_downed`, `impose_revived`, `impose_interact`,
  `impose_interrupt`, `impose_move_effect`, `clear_move_effects`, `reset_cooldowns`, `set_charges`,
  `set_loadout` y `reset_for_respawn(c, tick, weapon_1, weapon_2, charges)`; `impose_stagger` e
  `impose_stun` no hacen nada sobre DOWNED ni DEAD, y todas las que cambian la acción fijan la
  reutilización de la canalización comprometida que cortan.
- Consultas (§3.6): `phase` con las fases de ABILITY, `active_hit`, `is_commit_tick`,
  `ability_status` (con `AbilityStatus` y las casillas `STATUS_SLOT_CONSUMABLE_1`/`_2`),
  `defense_flags` con `DEFENSE_WIDE_BLOCK` (bit 7) en la canalización que bloquea, `is_blocking` y
  `action_byte` con la ranura (3 = consumible) en los bits 6-7. Los comentarios de `ActionMachine`
  dicen que el byte del historial es `(flags & 0b111) | defense_flags` (el enmascarado es de H3a).
- `ActionWire.has_counter` cuenta SWAP (§5.5).
- `PlayerCharacter.simulate`: la velocidad objetivo no impuesta se multiplica por `speed_factor`
  (también el esprint y el avance de los ataques) y enraizado no salta ni conserva el impulso en el
  aire.
- `AimRay` (`canonical`, `aim_point` con la convergencia de §4.4, `muzzle`, `look_for`),
  `Ballistics.solve_lead`, `HitShapes.segment_capsule_fraction` y `segment_box_fraction` (0 si el
  segmento empieza dentro, -1 si no toca) y `DamageFormula.compute(..., damage_scale,
  mitigation_penalty)`.
- `CombatDirector`: la reaparición usa la firma nueva; hasta las plantillas (H3c) reaparece con las
  armas que llevaba, en su orden de ranura (activa la 1), y sus cargas.
- Notas de la fase 4 en combate.md §3.3 (la máquina ampliada y partida) y §3.4 (la firma nueva de
  `reset_for_respawn`); notas «Hecho (H1b)» en backlog.md.

**Pruebas.** Nuevas: `test_ability_machine` (24: flanco, compromiso y reutilización también con
`cast = 0`, vuelve a valer en `ability_ready` y no antes, tambaleo en el lanzamiento sin
reutilización, el tambaleo, el aturdimiento y la muerte cortan una canalización y fijan su
reutilización, soltar, moverse con el dato, el tope y las sustitutas, los ejemplos de §3.3, el muro
del búfer con el botón arriba, prioridades con flancos simultáneos, búfer en la recuperación de un
ligero y la caducidad que reinicia el combo, sustitutas que no inventan nada, cancelación a esquiva,
suelo y acciones que lo permiten, ranura vacía, agotamiento y muro, comando 13, consultas,
regeneración en el muro, el avance de la embestida y del salto atrás, derribado, levantar y
rematar), `test_ability_reconciliation` (2: la reutilización sobrevive a una reconciliación por un
empujón del servidor tras el compromiso, con el estado igual byte a byte, y un rechazo la devuelve a
0), `test_weapon_swap` (7, con el cambio predicho y reconciliado con una entrada sustituida alrededor
del flanco), `test_move_effects` (6, con la ralentización igual en cliente y servidor a
`run_speed · 0,6` y su caducidad en el tick exacto), `test_consumables_machine` (6),
`test_bow_machine` (5) y `test_aim_ray` (5: el rayo canónico es el de `CameraRig.get_aim_ray()` a
menos de 1 mm con cinco combinaciones de yaw, pitch, hombro, brazo y FOV; las reglas son las de
`camera_rig.tscn` y `player_character.tscn`; tiro adelantado con el fondo a 150 m: 0 mm frente a
0,5 m sin convergencia; `look_for` a menos de 1 mm). Ampliadas: `test_action_wire` (+2: ranura y
fase de ABILITY, consumible, contador de SWAP), `test_hit_shapes` (+2: fracciones, coherentes con
`segment_hits_capsule` en 200 segmentos), `test_damage_formula` (+1) y `test_ballistics` (+1:
`solve_lead` a menos de 2 cm de un blanco que se mueve). Adaptadas a `reset_for_respawn` con
equipo: `test_action_machine` y `test_combat_state_v5`. Ayudantes: `tests/machine_driver.gd`
(`MachineDriver`, la máquina sin física con dos armas y cargas) y `tests/prediction_pair.gd`
(`PredictionPair`, cliente con la `ClientPrediction` de verdad y servidor con la regla de
sustitución en dos mundos, con lo que imponga el servidor en un gancho).

**Desvíos y decisiones.**

- **Flancos simultáneos.** Se procesan en el orden de prioridad: el primero que puede, empieza, y los
  que no pueden van al búfer; como hoy con DODGE + PRIMARY, uno de menos prioridad del mismo tick
  sustituye en la ranura a otro de más (la última pulsación gana). DODGE + ABILITY_1 desde NONE
  esquiva y deja la habilidad en el búfer.
- **Sustitutas.** No se ignoran flancos con `SUBSTITUTED`: como en combate.md §3.2, la sustituta
  repite los botones y no los crea. Lo que sí mira el bit es 4a (una sustituta ni suelta una
  canalización, levantar o rematar ni la rompe por moverse).
- **Compromiso de una canalización.** «Comprometida» es `t > action_tick + cast` cuando la acaba la
  propia máquina dentro del tick (4a, 4c, tope: soltar o esquivar en el tick del compromiso la
  cancela) y `t ≥ action_tick + cast` cuando la corta el servidor (impone tras simular el tick, y el
  compromiso de ese tick ya ha ocurrido).
- **ROOT.** La esquiva enraizada se descarta (no va al búfer y no avisa de resistencia), como una
  habilidad con avance; un avance o una esquiva ya en curso siguen (la velocidad impuesta no se
  escala, §3.4).
- **Canalización del búfer.** Con `channel_hold`, se descarta en cuanto el búfer la ve con el botón
  suelto, no solo al ir a empezar (el resultado es el mismo y no ocupa la ranura).
- **El muro agotado** se descarta con el aviso de resistencia (bit 1), como la carga.
- **Poción de resistencia.** Además de los +400, saca del agotamiento en el compromiso si supera el
  umbral (si no, esperaba al retardo de la regeneración).
- **Resistencia en el muro.** No regenera en la misma ventana en que bloquea (desde el fin del
  lanzamiento); como la regeneración va antes de las entradas, el tick en que se suelta aún no
  regenera.
- **Giro.** El primer tick de una habilidad salta a `look_yaw` también si el avance empieza en él
  (el salto atrás: mira a la cámara y salta hacia atrás); en la ventana del avance no gira, y el
  `lunge_speed` vale en el lanzamiento y el activo, no en la canalización.
- **PRIMARY desde ABILITY** desde `min(recuperación, cancel_to_attack_from)` (la misma regla que
  ABILITY_n); SWAP desde ABILITY, solo en la recuperación. Un SWAP que sale (del búfer o del flanco)
  cambia el arma con la que se miran el resto de entradas de ese tick.
- **`set_loadout`** sobre un muerto solo cambia el equipo; sobre un vivo fuerza NONE y borra búfer,
  pulsación y combo; conserva el bit 7 (comando 13). `reset_for_respawn` no lo conserva, como la
  resistencia infinita. `impose_revived` e `impose_interact` también borran búfer, pulsación y
  combo; `impose_interact` con otra acción no hace nada.
- **`ability_status`**: casillas 0-2 (habilidades del arma activa) y 3-4 (consumibles); orden EMPTY,
  NO_CHARGES, COOLDOWN, BLOCKED, READY; no mira el suelo (no está en `CombatState`).
- **`active_hit`** devuelve el golpe sintetizado también en la canalización (sin forma, no prueba a
  nadie).
- **`AimRay.look_for`** es una solución cerrada en vez de 3 iteraciones de punto fijo: en la base de
  la cámara el punto está en `(±s, v, −t)` desde el pivote, el pitch sale de la altura y el yaw del
  ángulo en planta. Es exacta sin depender del número de pasos (las 3 iteraciones también bastaban:
  0,03 mm a 2 m, comprobado aparte); si el punto está a menos de `√(s² + v²)` del pivote, apunta
  desde el pivote. `aim_point` con `space` nulo = sin
  mundo; el centro de un hostil es pies + 0,9 (`HitShapes.LINE_OF_SIGHT_TO_HEIGHT`).
- **`Ballistics.solve_lead`**: 16 pasos de punto fijo sobre el tiempo de vuelo (determinista).
- **`DamageFormula`**: `mitigation_penalty` resta (`max(block_mitigation − p, 0)`); un `damage_scale`
  negativo cuenta como 0. Sin efectos (1 y 0) el resultado no cambia.
- `HitShapes.is_ray_clear` con `hit_from_inside` se queda para H3a, como dice §7.1.
- Con H1b las habilidades 1–3 ya se usan con sus teclas (ABILITY_1–3 ya iban en `VALID_BUTTONS`):
  el servidor las simula (movimiento, reutilización, bloqueo del muro como un bloqueo de la fase 3)
  sin golpes, efectos ni proyectiles hasta H3. Cambio de arma y pociones esperan a `VALID_BUTTONS`
  de H2 y a sus teclas (H4).

**Medido** (orientativo: máquina compartida, 4 núcleos con otros trabajos; `ActionMachine.step`,
20 000 ticks): camino rápido 3,8 µs; un ligero 14 µs; el golpe de escudo 17 µs; el muro mantenido
23 µs; quieto y ralentizado 17 µs (sale del camino rápido, como manda la regla 0).

**Para los paquetes siguientes.** H2: `VALID_BUTTONS` hasta el bit 12 y `PROTOCOL_VERSION` 6.
H3a: `active_hit` en `Combatant.freeze` y el resolutor, `impose_move_effect` desde `StatusSystem`,
`impose_interrupt` (§4.2), el byte del historial enmascarado, los modificadores de `DamageFormula`,
`is_ray_clear` desde dentro y la protección que pierde una ABILITY. H3b: `ProjectileSystem` con
`is_commit_tick`, `AimRay` y las fracciones. H3c: `DownedSystem` con `impose_downed`,
`impose_revived`, `impose_interact` e `impose_interrupt`; plantillas con `set_loadout` y
`reset_for_respawn` (sustituyen a las armas que llevaba en `CombatDirector`) y la recarga con
`set_charges`. H4: `ClientPrediction.stepped` con `is_commit_tick` y la barra con `ability_status`.
H5: bots con `solve_lead` y `look_for`.

### 11.3 H2 · protocolo 6

**Hecho.**

- `NetProtocol`: `PROTOCOL_VERSION` 6 (con su línea en la historia de versiones), `VALID_BUTTONS` = bits
  0–12 (`SWAP_WEAPON`, `AIM_LEFT`, `CONSUMABLE_1` y `CONSUMABLE_2` viajan; los bits 13–14 y la marca de
  sustituida, no), `MSG_LOADOUT_SELECT` (`0x07`, canal fiable), los comandos 13 `cooldowns_off`, 14
  `apply_status`, 15 `down` y 16 `refill` en `DEBUG_COMMAND_IDS` y `DespawnReason.IMPACT` (4) y `EXPIRED`
  (5).
- `NetMessages`:
  - `LoadoutSelect` (2 B).
  - `DebugCommand`: valida los datos de 13 a 16 en el `decode` (13, `u8` 0 o 1; 14, `u8 status_id` de 1
    a 255 y `u16` ticks; 15 y 16, sin datos), con `cooldowns_off()`, `apply_status()`,
    `get_status_id()` y `get_status_ticks()`.
  - `EntitySpawn` de kind 3 (§5.3): 32 B, `for_projectile()`, `is_harmless()` y los campos `owner_id`,
    `projectile_def_id`, `source`, `volley_index`, `projectile_flags`, `origin` (`p0`) y `velocity`
    (`v0`), cuantizados como `Ballistics.quantize` (lo comprueba la prueba).
  - `EntityEvent`: STATUS (7), HEAL (8), LOADOUT (9), DOWNED (10) e INTERACT (11) con sus tamaños
    exactos, `StatusOp`, `InteractOp`, sus constructores y `get_source()`; los bits 5
    (`HIT_FLAG_INTERRUPTED`) y 6 (`HIT_FLAG_DOWNED`) de un HIT.
  - `STATUS_DOWNED` (bit 3 del `status` del bloque extra y del PARTY_STATUS), `Snapshot.is_downed()` y
    `PartyStatus.MemberStatus.is_downed()`.
- `EntityRecord`: `FLAG_SECOND_SLOT` (bit 3 de `flags`), `is_second_slot()`, `HISTORY_FLAGS_MASK`
  (`0b111`); `encode_character` y `from_state` ponen el bit desde `CombatState.is_second_slot()`.
- Cliente: `NetClient._on_spawn` mira el `kind` antes que `is_yours` y entrega los proyectiles por las
  señales nuevas `projectile_spawned` y `projectile_despawned` (el DESPAWN de un id que llegó como
  proyectil va a la suya); `is_own_event` reconoce los eventos 7–11 (temporización de §5.4); `RemoteWorld`
  y `SwarmBot` ignoran el kind 3.
- Documentación: red.md (catálogo de §5.2 con las filas «v6» y la leyenda, versión en §5.3, botones,
  comandos y LOADOUT_SELECT en §5.4, cabecera de 134 B, 50 registros, bit 3 del `status` y de los
  `flags`, SPAWN ajeno, PROJECTILE, motivos de DESPAWN, eventos 7–11, bits de HIT y fuentes en §5.5,
  garantía de §9.3, botones de §12, presupuesto de §14 y contratos de §17.3 y §17.5); nota del protocolo
  6 en combate.md §6; el bit de derribado del PARTY_STATUS en social.md §12.4; notas «Hecho (H2)» en
  backlog.md.

**Pruebas.** Nueva `test_net_messages_v6` (17: constantes y canales; los botones nuevos llegan en un
INPUT_BATCH y los bits 13–15 no; LOADOUT_SELECT; comandos 13 a 16; SPAWN de proyectil con cada offset, el
`is_yours` a 0 aunque se ponga, la balística igual a `Ballistics.quantize`, saturación y malformados;
DESPAWN 4 y 5; STATUS, HEAL, LOADOUT, DOWNED e INTERACT con sus offsets, `op` fuera de rango y STATUS
aplicado sin acumulaciones; longitudes incoherentes; bits 5 y 6 de HIT y las seis clases de fuente en
HIT, DEATH, KILL, HEAL y DOWNED; bit 3 del registro desde el estado y desde el personaje; bit 3 del status
del snapshot; el SPAWN de jugador con los 111 B exactos; malformados y *fuzz* de 8000 búferes).
`test_net_messages` gana los mensajes nuevos en sus ejemplos (malformados, decodificador único por tipo y
*fuzz*). `test_snapshot_builder` (+1): el bit 3 del registro de quien lleva la ranura 2 y el derribado en
el bloque extra, sin pasar de 1200 B (los 50 registros ya los comprobaba desde H1a). `test_net_client`
(+1): proyectiles por su señal, propia y ajena, sin vistas de remotos ni tocar el personaje local; DESPAWN
4 y 5 por la suya; STATUS y LOADOUT propios al llegar y DOWNED ajeno en su tick de dibujo; un id de flecha
que vuelve como entidad crea su vista. Adaptadas: `test_net_messages` (versión 6, `VALID_BUTTONS`
0x1FFF, 16 comandos, el evento 12 es el desconocido, PROJECTILE ya tiene formato), `test_net_messages_v3`
(el proyectil tiene formato; el 13 ya se valida), `test_party_messages` (el bit 3 es derribado; el
desconocido pasa a ser el 4), `test_command_registry` (16 ids), `test_input_queue` (texto) y
`test_combat_server` y `test_hfsm_brain` (los cuatro comandos nuevos aún sin manejador).

**Desvíos y decisiones.**

- **Comandos 13 a 16.** H2 deja sus ids, la tabla y la validación del `decode`; los manejadores son de
  H3a (13 y 14) y H3c (15 y 16), como dice §7.1. Mientras, el servidor los acepta sin aviso ni efecto
  (la regla de red.md §5.4 para un id fijo sin manejador) y `missing_network_commands()` los lista:
  `test_combat_server` y `test_hfsm_brain` esperan esos cuatro y H3a y H3c los irán quitando. El 14 exige
  `status_id` ≥ 1: 0 no es ningún efecto.
- **LOADOUT_SELECT en el servidor** es de H3c (con `ServerPeer.pending_template_id`); hasta entonces un
  `0x07` cuenta «tipo de mensaje inesperado». Nadie lo envía todavía (el selector es de H4).
- **Flags de la cabecera de un proyectil, a 0 enteros**, no solo el bit `is_yours`: un proyectil no se
  teletransporta. El `decode` rechaza cualquier flag de la cabecera y los bits de `proj_flags` que no
  existen.
- **El bit 3 del registro ya se publica.** El registro se escribe del personaje al construir el snapshot
  (`EntityRecord.encode_character`), no en un paso aparte, así que §7.1 («publicación del bit 3», H3a)
  queda hecho aquí. El historial no lo recibe: `ZoneServer._record_history` (y `combat_fixture`)
  componen sus bits 0–2 a mano y no leen el registro, así que el bit de la ranura 2 nunca se confunde con
  `DEFENSE_BLOCKING`; `HISTORY_FLAGS_MASK` queda para que H3a lo escriba explícito. En la práctica sale a
  0 hasta las plantillas de dos armas (H3c).
- **PARTY_STATUS acepta el bit 3.** Es el mismo byte de estado que el bloque extra (`NetEntity.status`):
  sin añadirlo, el `encode` lo habría tirado y el `decode` habría rechazado el mensaje de un grupo con un
  derribado en cuanto H3c lo publique. El bit 4 sigue siendo desconocido.
- **La fuente sigue en `EntityEvent.attack_id`.** Renombrar el campo tocaba todo el cliente; HEAL y DOWNED
  guardan ahí su `source` y `get_source()` la devuelve en los seis eventos que la llevan (0 en los
  demás). STATUS e INTERACT comparten el campo `op` (con `StatusOp` e `InteractOp`). Un STATUS quitado
  puede llevar 0 acumulaciones; uno aplicado, no. El `encode` satura las acumulaciones a 255 y la vida
  curada a u16; los ids de LOADOUT y HEAL no se validan al decodificar (no hay catálogo en el mensaje).
- **Cliente.** Las señales `projectile_spawned` y `projectile_despawned` (contratos de §7.2) ya salen de
  `NetClient`, para que el SPAWN de kind 3 de H3b nunca llegue a `RemoteWorld`, al directorio de nombres
  ni al alta propia; `ProjectileWorld` (H4) solo tiene que conectarse. Un id que vuelve como entidad deja
  de contar como proyectil (comparten espacio de ids). `is_own_event` decide ya la temporización de los
  eventos 7–11 (§5.4); lo que explican en la predicción (`_note_imposed_state`) es de H4.
- **Pruebas en un archivo propio**, `test_net_messages_v6.gd`, como hizo el protocolo 3 con
  `test_net_messages_v3.gd` (`test_net_messages.gd` ya pasa de 2200 líneas); el filtro
  `test_net_messages` ejecuta los tres.

**Medido.** Los tamaños son los del documento (SPAWN de proyectil 32 B, STATUS 18, HEAL 15, LOADOUT 15,
DOWNED 13, INTERACT 16, LOADOUT_SELECT 2, cabecera de 134 B y 50 registros en 1186 B). Las 93 pruebas de
mensajes (los tres archivos) tardan ~1,3 s sin el arranque del motor; sus tres *fuzz* (10 000, 8000 y 8000
búferes) ~0,1 s cada uno.

**Para los paquetes siguientes.** H3a: manejadores de 13 y 14 (y quitarlos de la lista esperada en
`test_combat_server` y `test_hfsm_brain`), `_hide_private_state` con `alt_weapon_id` y el bit 0 de
`combat_flags2`, `EntityRecord.HISTORY_FLAGS_MASK` en `_record_history`, STATUS y HEAL con
`EntityEvent.status`/`heal`, `HIT_FLAG_INTERRUPTED` y las fuentes de `CombatSource` en HIT, DEATH y KILL.
H3b: `EntitySpawn.for_projectile` y `DespawnReason.IMPACT`/`EXPIRED` (`NetClient` ya los reparte). H3c:
LOADOUT_SELECT en `ZoneServer` (limitador de fiables, LOADING e IN_WORLD), LOADOUT, DOWNED, INTERACT,
`HIT_FLAG_DOWNED`, `STATUS_DOWNED` en `Combatant.status_bits` y los comandos 15 y 16. H4:
`ProjectileWorld` conectado a las señales de `NetClient`, las explicaciones de `_note_imposed_state`, el
selector que manda LOADOUT_SELECT y las teclas que ponen los bits 9 a 12.

### 11.4 H3a · habilidades y efectos en el servidor

**Hecho.**

- **Orden del tick** (§4.1) dentro de `CombatDirector.process_tick`, con los pasos numerados en el código
  y en la cabecera de `ZoneServer`: 2 congelar, 3 efectos propios del compromiso, 4 resolver, 5 aplicar,
  6 efectos de estado, 7 derribado (vacío hasta H3c), 8 entorno y reapariciones (la recarga del
  campamento, vacía hasta H3c), 9 publicar. Los disparos del paso 3 y el vuelo del paso 4 son de H3b.
  Nota en fuerte.md §1.7.
- **Golpe sintetizado.** `Combatant.Frozen` gana `hit` (`ActionMachine.active_hit`: el ataque activo o el
  golpe sintetizado de la habilidad), `commit` (`is_commit_tick`), `wall` y `wall_half_extents` (la caja
  del muro de escudos mientras bloquea; un `Transform3D` no puede ser nulo, así que la caja vale si los
  semiejes no son cero). `attack_active` es `hit != null` y `hyper_armor` sale del golpe (la entereza de la
  embestida en su activo). `CombatResolver.resolve` prueba `frozen.hit` en vez de buscar el ataque por
  `action_id`: rebobinado fijado en el primer tick activo, candidatos, forma, línea de visión, defensas
  y puertas, igual que un ataque; su `id` es la fuente de la habilidad, así que HIT, DEATH y KILL ya la
  llevan sin código propio, y el registro de combate escribe su nombre.
- **Controles del golpe.** `_apply_hit_controls` aturde si el golpe lleva `stun_ticks` (el golpe de escudo)
  y, si no, tambalea y empuja (radial desde el atacante, como hoy), con la entereza y la cadena de
  controles de siempre. `unblockable` ya saltaba parada y bloqueo.
- **`StatusSystem`** (`scripts/server/status_system.gd`, §4.3): `ActiveEffect` (`status_id`,
  `source_id`, `anchor_tick`, `until_tick`, `stacks`) en `Combatant.effects`, hasta 8 por entidad y
  ordenados por id; `apply` (REFRESH, STACK, STRONGEST; SLOW y ROOT escriben su ranura de movimiento con
  `impose_move_effect` y pasan el estado por `encode/decode`), `step` (pulsos exactos reunidos antes de
  aplicarlos; los de daño los aplica el director como un HIT con la fuente del efecto y los de curación
  curan sin pasar del máximo con HEAL; después, las caducidades con STATUS 2), `clear` (al morir y al
  reaparecer, sin eventos, vaciando sus ranuras de movimiento), `forget_author` (al darse de baja una
  entidad, STATUS 2 de lo que puso a otros, con `CombatDirector.remove(net_id, tick)`), `heal`, `find` y
  los modificadores `damage_scale` (1 + Σ DAMAGE_UP del atacante) y `mitigation_penalty` (Σ
  MITIGATION_DOWN de la víctima) que `_apply_impact` y los pulsos pasan a `DamageFormula.compute`. Cada
  `Combatant` guarda en `effects_due` el primer tick en que le pasa algo (un pulso o una caducidad) y el
  sistema el menor de todos: un tick sin sucesos no recorre a nadie, y uno con sucesos salta a quien no
  tiene nada. Cada efecto guarda su `StatusTicks` (no se busca en el catálogo).
- **Efectos propios y al objetivo.** Paso 3: quien está en el compromiso de una habilidad se pone su
  `self_status` (la curación de la poción de vida, con él como autor) y su `self_heal` (HEAL con la fuente
  de la habilidad). Paso 5: el `target_status` de una habilidad y el `on_hit_status` de un ataque se
  aplican en un IMPACT (no en un bloqueo ni una parada) a quien sigue vivo.
- **Interrupciones** (§4.2): un IMPACT con daño > 0 de un atacante hostil (el resolutor solo da golpes de
  hostiles; los pulsos y el entorno no pasan por aquí) a quien está en el lanzamiento de un consumible o
  de una habilidad con `interrupt_on_damage`, o en REVIVE o EXECUTE, impone `impose_interrupt` y marca el
  bit 5 del HIT, si el golpe no ha impuesto ya un control. `CombatDirector.is_interruptible` es pública
  (H3b la usa con las flechas y H3c con levantar y rematar).
- **Muro de escudos cuerpo a cuerpo.** El resolutor elige el cono por muestra: con
  `DEFENSE_WIDE_BLOCK`, `ability_block_angle_deg` (180°); si no, el del arma. `Hit.wide_block` dice al
  director que cobre `ability_block_stamina_per_damage` (0,6) en vez del coste del arma; la mitigación es
  la del arma (1 en la espada y escudo). Sin resistencia, la rotura de guardia aturde y corta la
  canalización con su reutilización (`_leave_imposed` de H1b).
- **Protección de reaparición**: la quita también una ABILITY que no sea un consumible
  (`_started_attack`); beber, SWAP, REVIVE y EXECUTE no.
- **Muestra antigua** (§4.2): `_dropped_guard_after` descarta la muestra de `view_tick` si la acción
  congelada no es BLOCK y su `action_tick > view_tick`, sea NONE o no. Nota en combate.md §4.3.
- **`HitShapes.is_ray_clear`** con `hit_from_inside = true`: desde el vano de la puerta cerrada ni se
  golpea hacia fuera ni se es golpeado.
- **Byte del historial** (§3.6): `ZoneServer._record_history`, `Combatant.freeze` y
  `CombatFixture.record` componen `(flags del registro & EntityRecord.HISTORY_FLAGS_MASK) |
  defense_flags`; lo dicen los comentarios de `StateHistory`, `ActionMachine` y `ZoneServer`.
- **`NetEntity._hide_private_state`**: el SPAWN ajeno lleva `alt_weapon_id` y el bit 0 de
  `combat_flags2`; reutilizaciones, cargas, consumible, ranuras de movimiento y el resto de
  `combat_flags2`, a sus valores iniciales.
- **Publicación del bit 3**: ya la hizo H2 al escribir el registro desde el personaje; H3a la comprueba en
  un servidor (registro con el bit, historial sin él).
- **`InputQueue.get_applied(tick)`**: la entrada que se simuló en ese tick (real, o la sustituta aunque
  la real llegara después, tarde); null si aún no se ha consumido o ya salió del anillo.
- **Comandos 13 y 14** en `ZoneServer`, por la red y por la consola: `cooldowns_off <jugador> [on|off]`
  (`CombatDirector.set_cooldowns_off`, bit 7 de `combat_flags2`) y `apply_status <jugador> <efecto>
  [ticks]` (`CombatDirector.apply_status`: sin autor, en el tick que va a simular el servidor, con la
  duración pedida o la del dato). `missing_network_commands()` ya solo da `down` y `refill`.
- **Registro de combate**: `CombatDirector._log_line` escribe la columna «ataque» con el nombre de la
  fuente (`CombatSource.name_of`); resultado nuevo `pulse` (un pulso de daño). `arrow_hit`,
  `arrow_blocked` y `wall_blocked` son de H3b; `downed`, `executed`, `bled_out` y `revived`, de H3c.
- **Informe**: contadores nuevos del director (`interrupts`, `pulse_hits`, `heals`) y del `StatusSystem`
  (`status_applied`, `status_removed`, `pulses`, `healed`).

**Pruebas.** Nuevas: `test_ability_server` (9: el golpe de escudo aturde 48 ticks de frente aunque el
objetivo tenga el escudo en alto, no da al de detrás y da una vez por acción; la embestida recorre 6 m en
su ventana de avance y empuja con 6 m/s radiales y su tambaleo; el muro bloquea a 85° y no a 95°, cobra 0,6
por punto y un bloqueo normal no para lo de 85°; la rotura del muro aturde y fija su reutilización; un bot
que pulsa el golpe de escudo un tick de cada dos compromete exactamente cada `cooldown + cast` = 738 ticks
y da un golpe por compromiso, y con el comando 13 vuelve a salir enseguida; una habilidad quita la
protección y beber o cambiar de arma no; un golpe interrumpe beber antes del compromiso (bit 5, sin gastar
carga ni reutilización, conservando el `action_tick`), no después, corta levantar y no se marca si ya
impone un control; la muestra antigua no cuenta tras un REVIVE soltado ni tras una poción interrumpida y sí
al soltar el escudo sin más; la ranura 2 activa sale en el registro y no en el historial, y el SPAWN ajeno
enseña las dos armas; desde el vano de una puerta cerrada no se golpea ni se recibe, y rota sí) y
`test_status_effects` (10: un sangrado hace exactamente 6 pulsos en `anchor + 60k` con STATUS 1 y 2 y su
`until_tick`, el último pulso antes que la caducidad; acumulación, renovación y el más fuerte con la
ranura de movimiento; la curación no pasa del máximo; un pulso no interrumpe; un pulso que mata a mitad de
la lista no cambia lo que se recorre; limpieza al morir y al reaparecer sin STATUS; STATUS 2 al irse el
autor; las ranuras de movimiento y el noveno efecto; más daño y menos mitigación; el pulso en el registro
de combate). Ampliadas: `test_combat_server` (+1: comandos 13 y 14 por la red y la consola, y el
sangrado sin autor que pulsa en `anchor + 60`; la lista de comandos sin manejador), `test_hfsm_brain`
(la lista de comandos sin manejador), `test_input_queue` (+1: `get_applied`), `test_net_entity` (+1: el
SPAWN ajeno con las dos armas y sin el estado de las habilidades) y `test_hit_shapes` (+1: un rayo que
empieza dentro de un cuerpo no está libre).

**Desvíos y decisiones.**

- **Un efecto por id y entidad.** Renovarlo no crea otro: `source_id` pasa a ser el último que lo renueva
  (REFRESH y STACK) y STRONGEST no cambia de autor. Un mismo efecto siempre es igual de fuerte (sus datos
  no cambian), así que STRONGEST se queda con el fin más tardío. El fin nunca retrocede (`max`, también en
  REFRESH y STACK): solo podría con la duración del comando 14, y así la ranura de movimiento (que también
  se queda con el máximo) acaba en el mismo tick que el efecto.
- **STATUS 2** sale al caducar, al irse el autor y cuando el noveno efecto sustituye al que acaba antes,
  con 0 acumulaciones y `until_tick` = el tick en que se quita. HEAL solo sale si cura algo (un pulso con
  la vida llena no manda nada); `healer` es 0 si se cura a sí mismo.
- **Destinatarios de STATUS y HEAL** (§5.4): `ZoneServer._on_combat_event` los manda a los dueños del
  afectado y del autor y a quien tenga relevante **al afectado** (no al autor, como los demás eventos).
- **Pulsos de daño**: `DamageFormula` con el más daño del autor (sin bloqueo, crítico ni armadura); el
  atacante del HIT es el autor (0 si no tiene: el comando 14), que entra «en combate» y en el registro de
  daño de la víctima si es otro. Un pulso de un efecto sin autor que mata da DEATH sin KILL.
- **Al morir** se quitan los efectos y sus ranuras de movimiento (`ActionMachine.remove_move_effect`,
  nueva) antes del `commit_state`: la acción DEAD no se mueve, pero el estado queda limpio para la
  reaparición. Un efecto no se aplica a un muerto. Lo del derribado (no aplicar a un derribado, saltarlo
  en los pulsos, `clear` al caer y el descarte de golpes con `downed_tick == s`) lo pone H3c.
- **Interrupción**: se decide con el estado vivo al aplicar (tras los golpes anteriores del mismo tick) y
  con el daño del HIT (el completo en un maniquí inmortal). Un golpe mortal no interrumpe (mata).
- **Golpes de las habilidades como «ataques» del peer**: una habilidad que golpea (con forma o proyectil)
  cuenta en `ServerPeer.swings` el tick en que empieza, porque sus aciertos ya contaban en
  `swings_landed`.
- **`Combatant.restore_health(amount)`** (nueva) cura sin pasar del máximo; la usan HEAL y `self_heal`.
- **`is_ray_clear` desde dentro** vale para todo quien lo usa: la línea de visión de los golpes y de los
  PNJ (`NpcWorld`) y la de las placas del cliente. Un rayo que empieza dentro de un cuerpo del mundo o de
  una estructura choca en su origen; los pechos de los personajes nunca quedan dentro del mundo (la
  cápsula los separa) salvo en el vano de la puerta del propio fuerte, que es justo el caso que se quería.
- **`CombatDirector.remove(net_id, tick)`** pide el tick para los STATUS 2 (lo da `_remove_player`).
- **Ayudas de más**: `CombatDirector.set_cooldowns_off`, `apply_status`, `is_interruptible` y `_log_line`;
  `StatusSystem.find`, `heal`, `forget_author` y `stats`; `ActiveEffect.status` y `next_event_after`;
  `Combatant.effects_due`. El paso 3 solo recorre a quien está en su compromiso (se reúnen al congelar).

**Medido** (orientativo, máquina compartida con otros trabajos). La embestida recorre **6,000 m** en su
ventana de avance y **7,75 m** hasta pararse: al acabar el avance va a 15 m/s y frena a 60 m/s²
(`ground_deceleration`) durante la recuperación, 1,75 m más. §2.3 habla de «6 m en el activo» y así queda;
si se quieren 6 m en total, la curva puede caer al final (decisión de equilibrio para H5, combate.md §12).
`CombatDirector.process_tick` con 64 combatientes quietos (sonda sin subir, 600 ticks): 0,49–0,59 ms antes
y después de H3a (el ruido de la máquina es mayor que la diferencia); con tres efectos cada uno (192:
sangrado, curación y ralentización con los pulsos sincronizados, el peor caso) +10–20 µs de media, y
`StatusSystem.step` solo 42–45 µs de media, 0 en los ticks sin sucesos. Antes de guardar `effects_due`
el mismo `step` costaba 306 µs por tick (recorría los 192 efectos y los buscaba en el catálogo). Las
pruebas nuevas tardan ~9 s por archivo con el arranque del motor; la de la reutilización avanza 1720
ticks del servidor en ~0,6 s.

**Para los paquetes siguientes.** H3b: `ProjectileSystem.fire` en el paso 3 (`_process_commits`, también
con el compromiso de un LIGHT o HEAVY con proyectil) con `InputQueue.get_applied(s)`, el vuelo en el paso
4, la caja del muro de `Combatant.frozen.wall`/`wall_half_extents`, `Hit.projectile_id`, el
`target_status` de la flecha lastrante con `status.apply`, la interrupción con
`CombatDirector.is_interruptible`, los resultados `arrow_hit`, `arrow_blocked` y `wall_blocked` del
registro y el DESPAWN 5 de las flechas en `CombatDirector.remove` (junto a `forget_author`). H3c:
`DownedSystem` en el paso 7, el descarte con `downed_tick == s` en `_apply_hit`, `StatusSystem` sin
derribados (`_takes_pulses`, `apply`) y `status.clear` al caer, el corte de levantar y rematar con un
impacto que interrumpe, la recarga del paso 8 y los comandos 15 y 16.

### 11.5 H3b · proyectiles

**Hecho.**

- **`ProjectileSystem`** (`scripts/server/projectile_system.gd`) con el contrato de §7.2 (`spawned`,
  `despawned`, `fire`, `resolve`, `live_count`, `forget_owner`) y, además, `begin_tick`, `has_pending`,
  `get_live`, `get_projectile`, `clear`, `merge_by_attacker` y `stats`.
  - **Disparo** (paso 3): `CombatDirector._process_commits` dispara en el compromiso de un LIGHT o HEAVY
    con proyectil (el arco) y de una habilidad con proyectil. El rebobinado sale de
    `CombatResolver.compute_rewind` (factorizado de `_swing_rewind`), redondeado a ticks enteros y fijado
    para todo el vuelo; rechazado o desde la zona segura propia, la flecha es inofensiva (bit 0 de
    `proj_flags`), y el rechazo suma sospecha y llega al registro de combate como `rewind_rejected`. La
    puntería es la de §4.4 con la entrada de `InputQueue.get_applied(s)`: rayo canónico, punto apuntado
    con convergencia sobre los hostiles en `s − rewind` (cribados por su caja barrida contra el cono de la
    mira) y salida del pecho; el abanico gira en yaw; `v0` lleva la carga del tensado (`charge_speed_scale`);
    origen y velocidad se cuantizan con `Ballistics.quantize` y el servidor vuela con eso. Cada proyectil
    guarda la copia del autor (tirador, reino, si es jugador, fuente, golpe, rebobinado, carga y
    `damage_scale` del disparo).
  - **Vuelo** (paso 4): el segmento `[pos(n), pos(n + 1)]` contra el mundo y las puertas (el primero con
    `hit_from_inside`), las cajas de los muros de los hostiles y las cápsulas rebobinadas (radio 0,4 + el
    de la flecha) de los candidatos; gana la fracción menor. Invulnerable: sigue volando sin volver a
    probarlo (golpe INVULNERABLE para el registro); bloqueo de cara a la flecha con el cono del arma o el
    del muro, en la muestra de `k` o en la de `k − defense_rewind` si aún cuenta; nunca parada. Mundo: se
    clava; una puerta que el tirador puede dañar recibe el golpe (perforante ×0,2). Caducidad en
    `n + 1 ≥ lifetime_ticks` o bajo y = −100.
  - **Topes**: con 8 vivos del tirador sale su más vieja y con 64 en la zona la más vieja de la zona (empate
    por id), con DESPAWN 5 en ese tick; el disparo nuevo siempre existe.
  - **Bajas**: `CombatDirector.remove` llama a `forget_owner` (DESPAWN 5 de las flechas del que se va).
- **`CombatResolver`**: `compute_rewind` y `note_rewind_rejected`; públicos `is_hostile`,
  `was_invulnerable`, `blocks_sample`, `dropped_guard_after`, `get_safe_areas` y `get_history`. `Hit` gana
  `projectile_id`, `projectile` (la copia del autor), `wall` (bloqueado por la caja del muro) y `direction`
  (la velocidad de la flecha al tocar).
- **`CombatDirector`**: `projectiles`; el paso 4 junta los golpes cuerpo a cuerpo y los de los
  proyectiles por net_id del atacante (primero sus golpes, después sus proyectiles por id); `_apply_hit`
  aplica los de las flechas con la carga y el más daño copiados, la caja del muro con mitigación 1 y el
  gasto del muro (su rotura de guardia corta la canalización con su reutilización), el empuje en la
  dirección de la flecha, la interrupción y el `target_status` de siempre (la flecha lastrante pone
  `slowed`), un acierto por disparo en el peer y los resultados `arrow_hit`, `arrow_blocked` y
  `wall_blocked` del registro (con sus contadores). Sección de métricas `combat_projectiles` (disparos y
  vuelo) y contadores `projectile_us` y `projectile_busy_ticks`.
- **`StateHistory`**: `position_at(id, tick)` (sin crear objetos; `Vector3.INF` si no está) y
  `swept_box(id)`: cada pista guarda al grabar las cajas de 4 bloques de 8 ticks y su unión, al día (cubre
  los 25 ticks anteriores al siguiente como mínimo).
- **`NetEntityRegistry`**: `allocate_transient_id`, `release_transient_id`, `is_transient` y
  `transient_count`, del mismo espacio y con la misma cuarentena de 600 ticks; `allocate` no toma un id
  pasajero en uso.
- **`ZoneServer`**: los ids de los proyectiles salen del registro de la zona; el ENTITY_SPAWN de kind 3 va
  al dueño del tirador y a quien lo tiene relevante; el ENTITY_DESPAWN, exactamente a quien recibió el
  SPAWN; el informe cuenta disparos, impactos, bajas, criba, pico de vivas y los mensajes enviados.
- Notas en combate.md §4.3, red.md §5.5 (destinatarios del SPAWN y el DESPAWN) y §17.4 (contratos de
  `NetEntityRegistry` y `StateHistory`) y fuerte.md §1.7; notas «Hecho (H3b)» en
  backlog.md (CMB-19, CMB-21, CMB-22 y CMB-23).

**Pruebas.** Nueva `test_projectiles` (17): ninguna flecha atraviesa un muro (40 disparos con ángulos
distintos, todos con DESPAWN 4 en el segmento que cruza su cara, y el control sin muro, que acierta); el
disparo pegado a una esquina da en la esquina (la cámara ve al blanco y el pecho no); desde el vano de la
puerta cerrada se clava en el origen (DESPAWN 4 en el tick del disparo) y rota sale; el escudo de frente la
bloquea sin pararla aunque la ventana de parada esté abierta, y por la espalda no; la esquiva la deja pasar
hasta el de detrás; la caja del muro para la flecha de lejos dirigida al aliado de detrás (sin daño, 0,6
por punto) y la del arquero que está dentro de la caja, no la de un arquero detrás de quien lo sostiene, y
sin muro el aliado recibe la flecha; un segmento que empieza dentro de una cápsula da a quemarropa en el
tick del disparo; los topes (el noveno del tirador saca su primera y el primero con 64 en la zona saca la
más vieja de la zona, los dos con DESPAWN 5, y el disparo nuevo existe); el que se va se lleva sus flechas;
la flecha a la puerta (12 = 60 × 0,2) y la del dueño, que se clava; el vuelo contra posiciones rebobinadas
(con 10 ticks de vista atrás acierta donde el arquero veía al blanco, y el control sin rebobinar, en la misma
ejecución, falla); el rebobinado rechazado y la zona segura dan flechas inofensivas (sospecha + 1); el
abanico (3 flechas a ±7°, un acierto por disparo), el tensado (40 y 70 m/s, 90 y 180), la flecha lastrante
(60, `slowed` con su ranura e interrupción de beber) y el salto atrás; la balística del SPAWN es la que vuela
el servidor y caduca en `n + 1 = 120` con DESPAWN 5; la criba (cajas barridas y barrido en x) toca
exactamente a los mismos que probar las cápsulas de todos (3000 segmentos al azar, con un teletransportado);
un arquero falso en un `ZoneServer` dispara con un id pasajero del registro, acierta y, al irse, se lleva su
flecha; y, con ENet en 127.0.0.1, el cliente que ve al tirador recibe el SPAWN y el DESPAWN. Ampliadas:
`test_state_history` (+3: `position_at`, la caja barrida cubre los 25 ticks y olvida lo de hace más de 4
bloques, el hueco) y `test_net_entity_registry` (+1: ids pasajeros). Los 53 archivos de prueba de las áreas tocadas (combate,
servidor de zona, fuerte, PNJ, asedio, red, snapshots, chat y grupos, procesos), uno a uno: 722 pruebas en
verde.

**Desvíos y decisiones.**

- **`begin_tick(s, combatants)`** se añade al contrato: `fire` necesita los combatientes del tick para la
  convergencia de la mira. Los candidatos y muros se calculan una vez por tick y solo si hay un disparo o
  flechas vivas.
- **DESPAWN al final del paso 4**, no en el 5: `resolve` da de baja las flechas que acaban (y su id va a la
  cuarentena) y devuelve sus golpes. En el canal fiable el DESPAWN llega antes que el HIT del mismo tick;
  los dos llevan su tick, así que el cliente no nota la diferencia.
- **El muro cubre de frente**: su caja solo para las flechas cuya velocidad va contra el mirar de quien lo
  sostiene. Así un arquero enemigo detrás de quien lo sostiene «dispara libre» también hacia los de
  delante (la flecha cruza la caja por detrás) y uno dentro de la caja que dispara hacia él se para en el
  origen. La caja se ensancha con el radio de la flecha.
- **Sin crítico por la espalda** para las flechas: §4.4 no lo pide y la hoja de §2.4 se calculó sin él.
  Decisión de equilibrio para H5.
- **El cono de bloqueo frente a −velocidad** es el de siempre con un «atacante» detrás de la víctima en la
  dirección horizontal de la que viene la flecha; una flecha vertical cuenta como de frente.
- **Inofensivas**: solo chocan con el mundo; tampoco con muros ni puertas (una puerta la clava sin daño).
- **Rebobinado**: `roundi` del de los golpes; el de las defensas, `max(roundi(defensa), rebobinado)`.
- **Sin entrada aplicada** en `s` (una cola sin consumir, en las pruebas): yaw del cuerpo, pitch 0 y hombro
  derecho.
- **Cápsula ensanchada de verdad**: radio 0,4 + r y también la altura (pies − r, altura + 2r), la suma de la
  cápsula y la esfera de la flecha.
- **Un acierto por disparo** en `ServerPeer.swings_landed` (las flechas de un abanico comparten un `Shot`).
- **Destinatarios**: `ZoneServer` apunta qué peers recibieron cada SPAWN y manda el DESPAWN a esos (aunque
  ya no tengan relevante al tirador); quien empieza a ver al tirador después no recibe las flechas que ya
  están en el aire (viven 2 s como mucho).
- **`get_body_rids`**: `StructureTarget.exclude` ya guarda los cuerpos de la puerta (`FortGate.get_body_rids`),
  así que la flecha reconoce la puerta por el cuerpo que toca su rayo.
- **Coste**: la criba es la de §4.4 más un **barrido en x** (una rejilla de una dimensión, la que §8 dejaba
  abierta): los candidatos estrechos se ordenan por el borde izquierdo de su caja (enteros en centímetros
  con el índice, `PackedInt64Array.sort` y `bsearch`) y cada segmento solo mira los que caen en su ventana;
  las cajas de más de 12 m de ancho (un teletransporte reciente) van aparte y se miran siempre. La unión de
  los 4 bloques se mantiene al grabar (cada pista la rehace al empezar un bloque), así que `swept_box` no
  recorre nada. `test_projectiles` comprueba que la criba no cambia el resultado. La convergencia criba con
  una prueba esfera-cono en vez del ángulo (equivalente y sin `acos`).
- **`touched_ids`** (para las pruebas): los candidatos que toca un segmento, con la criba o probando todas
  las cápsulas.

**Medido** (sonda sin subir, máquina compartida con otros trabajos; orientativo). Refriega de 64 en 20 × 20
m que se mueven, 30 disparos por segundo (~51 flechas vivas, todas sobre la refriega): la sección de
proyectiles cuesta **650–690 µs por tick**: preparar los 64 candidatos 130–170 µs, **9–10 µs por flecha y
tick** y 70–115 µs por disparo (convergencia y punto apuntado); 0,023 pruebas exactas por segmento. Con el
tope de 64 vivas, ~0,8 ms: dentro de la reserva de 1 ms. La primera versión (objetos por tick, un recorrido
de todos los candidatos por flecha y la unión calculada al pedirla) costaba 3,3 ms. `StateHistory.record`
pasa de 0,70–0,73 a 0,95–0,98 µs por entidad (+16 µs por tick con 64). `test_projectiles` tarda ~13 s con el
arranque del motor (la de red, ~3 s).

**Para los paquetes siguientes.** H3c: `should_down` con `Hit.projectile.realm` e `is_player` (la copia del
autor); el descarte `downed_tick == s` de `_apply_hit` vale también para las flechas, y la flecha de un
tirador que ya ha muerto o está derribado sigue pudiendo derribar o matar (la copia del autor basta). H4: `ProjectileWorld` con las señales
de `NetClient`; la flecha remota se retira en `despawn_tick + f`, con el segmento de §6.2 (es el que probó el
servidor), y la inofensiva se dibuja igual. H5: `test_projectile_loopback` (los bots apuntan con
`solve_lead` y `look_for`, como `_over_drop` de `test_projectiles`) y la carga con la sección
`combat_projectiles` del registro de métricas.

### 11.6 H3c · derribado y plantillas

**Hecho.**

- **`DownedSystem`** (`scripts/server/downed_system.gd`) con el contrato de §7.2 (`should_down`, `down`, `step`)
  y, además, las señales `event_emitted` (DOWNED e INTERACT) y `killed` (la muerte de un derribado, que
  aplica el director), `is_enabled`, `killer_of`, `release`, `forget`, `downed_count`, `interacting_count`,
  `clear`, `bleed_loss` y `stats` (`downs`, `revives`, `executions`, `bled_out`, `interact_started`,
  `interact_cut`).
  - **Cuándo** (`should_down`): un jugador (entidad PLAYER, también los falsos; nunca un maniquí) sin vida por
    el golpe, la flecha o el pulso de un jugador de un reino hostil en una zona RVR. El director lo mira en
    `_apply_impact` (con la copia del autor de la flecha: su reino y si es jugador) y en `_apply_pulse` (el
    autor del efecto, si sigue en la zona). Si no, muerte directa.
  - **Caer** (`down`): `Combatant.mark_downed` (vida 0, 400 de derribado, autor y fuente),
    `StatusSystem.clear` (sin STATUS), `impose_downed`, `commit_state` y DOWNED a toda la zona. El HIT que
    derriba lleva el bit 6 y no el 4 (mortal).
  - **Paso 7**: desangrado, INTERACT nuevos y el progreso y el final de levantar y rematar (§4.5), por net_id,
    con todo lo de §4.5: flanco de INTERACT en una entrada real, vivo en NONE o BLOCK y en el suelo, el más
    cercano a 2 m con `|Δy| ≤ 1,5` y línea de visión del pecho a pies + 0,5 (la puerta cerrada la corta), un
    aliado sin nadie que lo levante (REVIVE, INTERACT 1) o un enemigo sin zonas seguras de por medio (EXECUTE,
    INTERACT 4); acabar se mira antes que seguir (levantado con 300 e `impose_revived`, INTERACT 3; rematado,
    muerte con la fuente «remate»); se corta (INTERACT 2 o 5, `impose_interrupt` si sigue en la acción) si
    quien actúa deja la acción, el objetivo deja de estar derribado o recibe daño en el tick, pasa de 2,5 m o
    se pierde la línea de visión.
- **Predicados** (`Combatant`): `is_alive` sin cambios, `is_downed` (`downed_tick ≥ 0`) e `is_dead` (vida 0 y
  no derribado); `status_bits` con el bit 3 (y el de «en combate»), nunca el de muerto; `publish` con la vida
  de derribado sobre 400 (`health_q` nunca 0). Cada uso de la tabla de §4.5: el resolutor, los proyectiles,
  `NpcWorld` y `_rebuild_target_cache` lo tienen por candidato sin tocar el código; `_apply_hit` descarta con
  `is_dead() or downed_tick == s`; un golpe a un derribado pasa por `_apply_downed_impact` (vida de
  derribado, sin bloqueo ni controles); los volúmenes letales y y < −100 lo matan con el asesino de
  `killer_of`; `_gate_blockers` lo cuenta (`not is_dead()`); `request_respawn` (NOT_DEAD), `heal` (comando
  y consola) y `regenerate` lo rechazan; el círculo y /atascado no lo cuentan (`is_alive`); `StatusSystem` no
  le aplica efectos ni pulsos.
- **Salida**: `ZoneServer._remove_player` mata antes a un derribado (`CombatDirector.kill_downed`: DEATH y KILL
  con el asesino de `killer_of` y la fuente «desangrado»), así que vale para CLIENT_LEAVE, la caída de ENet,
  `remove_fake_player`/`--fake-churn`, el fin del cuerpo de GUE-41 y `remove_npc`. Un derribado no deja cuerpo
  (`_should_linger` pide `is_alive`), y `_process_departures` lo saca de `_world_peers` antes, para que lo
  que sale de su baja no le llegue a él.
- **PNJ** (`HfsmBrain`): un derribado hostil a ≤ 6 m (`DOWNED_PRIORITY_RADIUS`) es el objetivo preferido en
  `_choose_target` y también al notarlo en reposo o patrulla (`_scan`); se le ataca con el ligero (ni escudo
  ni carga) y con su ficha de `AttackTokens`. Nota en fuerte.md §4.2.
- **Plantillas** (§4.6): `ServerPeer.pending_template_id` (−1 = ninguna); LOADOUT_SELECT en
  `ZoneServer._on_packet_received` (`_handle_loadout_select`, en LOADING e IN_WORLD, tras el limitador de
  fiables; 0 = la de por defecto; aviso con un id que no existe, que no se puede elegir o un mensaje mal
  formado). La pendiente se copia al `Combatant` al darlo de alta (`_process_arrivals`, antes del SPAWN, con
  `CombatDirector.equip_template`: `set_loadout` con sus armas y sus cargas) y en cada reaparición
  (`_respawn`: `reset_for_respawn` con las de la plantilla), y vuelve a −1. Los falsos:
  `add_fake_player(brain, realm, template_id = 0)` y `--fake-loadout=<plantilla>[:<porcentaje>]`
  (`ServerConfig.fake_template_for`, en `ServerMain`). LOADOUT con `announce_loadout`: al dueño con sus cargas
  y, si cambian las armas, la pública con 0 cargas.
- **Recarga** (paso 8, `_process_recharge`, `RECHARGE_INTERVAL_TICKS` = 60): vivo, fuera de combate, en la
  zona segura de su reino y con menos cargas que su plantilla en alguna poción → `set_charges` con las llenas
  y LOADOUT al dueño.
- **Comandos**: 5 `set_weapon` es `set_loadout` con el arma en la ranura 1 y la de la ranura 2 que llevaba
  (`CombatDirector.set_weapon(combatant, weapon_id, tick)`), con su LOADOUT; 15 `down` (`CombatDirector.down`)
  y 16 `refill` (`CombatDirector.refill`), por la red y por la consola (`down <jugador>`, `refill <jugador>`).
  `missing_network_commands()` ya está vacía.
- **Registro de combate**: `downed` (tras la línea del golpe o del pulso que derriba, o la del comando 15),
  `executed`, `bled_out` y `revived`. Informe: los contadores del `DownedSystem`, `downed_now` y los del
  director `downed_hits`, `recharges` y `loadouts`.
- `tools/combat_balance.gd`: la «muerte» de sus medidas (TTK ideal, duelos y equipos) es la caída, DOWNED o
  DEATH, lo que llegue antes; un derribado que luego muere solo cae una vez.
- `NetZones.is_rvr(zone_id)` (nueva): el servidor solo habla con `Zones` a través de `NetZones`
  (test_architecture).
- Notas en combate.md §5, fuerte.md §1.7 y §4.2 y red.md §5.4 y §17; notas «Hecho (H3c)» en backlog.md.

**Pruebas.** Nuevas: `test_downed` (15: el golpe mortal entre reinos derriba con el bit 6 y DOWNED, publica la
vida de derribado sobre 400 con el bit 3 y se arrastra a ×0,15; levantado en 180 ticks con 300 de vida y NONE,
INTERACT 1 con su `end_tick` y 3; rematado en 60 con la fuente del remate, DEATH y KILL; desangrado en 1200
exactos (200 a los 600) con el asesino que derribó; levantar cortado por un golpe a quien levanta (bit 5) y por
un golpe al derribado; no se remata a través de la puerta cerrada y rota sí; la puerta no se repara con un
derribado en el vano; el falso que se va derribado muere antes con DEATH y KILL; con ENet, el jugador que sale
derribado muere aunque esté en combate (sin cuerpo) y al volver aparece en el punto de su reino, y el cuerpo
de GUE-41 derribado muere al acabar su plazo; el golpe mortal de un PNJ mata sin derribar; un Hueco prefiere al
derribado (su primer golpe es para él, no para el de pie más cerca) y lo remata con daño antes de 1200 ticks;
el comando 15 sin autor (y rechazado en la zona segura propia, fuera de RVR o ya derribado) se desangra sin KILL,
y por la consola; dos golpes en el mismo tick: el segundo se descarta y los de después quitan vida de derribado
sin controles), `test_consumables_server` (5: la poción de vida cura 6 pulsos de 50 en `compromiso + 30k`, gasta
una carga y fija la reutilización compartida; un golpe que interrumpe no gasta carga ni reutilización y se puede
volver a beber; la recarga del campamento con la ranura 2 activa, el golpe de escudo en reutilización y el muro
levantado: arma, ranura, `ability_ready` y acción no cambian, LOADOUT solo al dueño, y fuera del campamento o en
combate no recarga; el comando 16; con ENet, el LOADOUT del comando 5 llega al dueño con sus cargas y al otro con
0, y el del 16 solo al dueño) y `test_loadout_server` (5: el escudero por defecto y el tirador con sus armas,
cargas y las dos LOADOUT; LOADOUT_SELECT mientras carga decide la plantilla del alta, con avisos para un id que
no existe, uno que no se puede elegir y un mensaje mal formado, y en el mundo la de la siguiente reaparición;
reaparecer con la misma plantilla solo avisa al dueño; el comando 5 pone el arma en la ranura 1 y conserva la 2,
y no vale con un derribado; `--fake-loadout` con su reparto y sus valores no válidos). Adaptadas a que el golpe
mortal entre reinos derriba: `test_combat_director` (las tres pruebas de la muerte usan un atacante PNJ),
`test_status_effects` (el pulso a mitad de la lista ahora derriba, con la limpieza al quedar derribado, y la
versión que mata usa un autor PNJ: 11) y `test_fortress_net` (el cuerpo de GUE-41 se derriba y se remata);
`test_combat_server` y `test_hfsm_brain` ya no esperan comandos sin manejador.

**Desvíos y decisiones.**

- **El asesino sin golpe** (`killer_of`): el último enemigo que le hizo daño ya derribado y, si no, quien lo
  derribó; 0 si ya no está en la zona (DEATH sin KILL). Vale para el desangrado, la salida, los volúmenes
  letales, y < −100 y la caída. El desangrado es exacto en enteros: `⌊e · 400 / 1200⌋` acumulado.
- **Golpes a un derribado**: daño de la fórmula con la carga, el crítico y el más daño (sin bloqueo aunque una
  muestra antigua diga BLOCKED o PARRIED, sin controles, efectos ni interrupciones); el HIT lleva el bit 4 si le
  mata, y el registro escribe `hit` o `arrow_hit`. La caída le quita vida de derribado; el entorno nunca derriba.
- **El flanco de INTERACT** sale de `InputQueue.get_applied(s)` (sin `SUBSTITUTED`) frente a
  `Combatant.last_buttons` del tick anterior; si no está al día (no había derribados), de `get_applied(s − 1)`.
  Solo se mira si hay algún derribado en la zona: sin ninguno, el paso 7 no recorre a nadie. Se añade
  `Combatant.last_buttons_tick`.
- **Varios pueden rematar** al mismo derribado (gana quien acaba antes); levantar, solo uno. Se elige el más
  cercano de los que valen y después se mira la línea de visión por orden.
- **Al acabar** solo hace falta que el objetivo siga derribado y quien actúa vivo: un golpe en el último tick ya
  no lo corta (en ese tick la simulación ya ha vuelto a NONE). El `end_tick` de INTERACT es el previsto en 1 y 4 y
  el del tick en 2, 3 y 5. Levantado no da protección ni quita «en combate».
- **Comando 15**: también se rechaza a quien no está vivo, a un maniquí y a quien no es un jugador; el DOWNED va
  sin autor ni fuente y sin HIT. **Comando 16**: necesita estar vivo y llevar plantilla. **Comando 5**: con un
  derribado se rechaza (REFUSED; `set_loadout` lo pondría en NONE) y la misma arma que la de la ranura 2 la deja
  vacía. Los PNJ se equipan con él al crearse, sin LOADOUT (su SPAWN ya lleva el arma).
- **LOADOUT por `event_emitted`**: el director lo emite dos veces cuando cambian las armas; con `involved` =
  `[jugador]` es la del dueño (`ZoneServer` solo se la manda a él) y con `involved` vacío, la pública (cargas 0,
  a quien tenga relevante al jugador, sin el dueño). Al aparecer sale tras el SPAWN; al reaparecer, tras el
  RESPAWN, con la pública solo si cambian las armas.
- **`template_id` 0** (PNJ, luchadores montados a mano en las pruebas): sin plantilla, reaparece con lo que
  llevaba (lo de H1b) y no recarga. Un jugador siempre lleva una: la pendiente o la de por defecto.
- **La recarga** cae en los ticks múltiplos de 60, sin escalonar (es barata: solo mira a quien tiene plantilla
  y le faltan cargas) y repone la plantilla entera.
- **El golpe mortal entre reinos ya no mata**: las pruebas que daban por hecha la muerte (las de
  `test_combat_director`, `test_status_effects` y `test_fortress_net`) usan un autor PNJ o rematan. Los falsos
  de combate (`BotBrain`) siguen atacando a un derribado y lo rematan con daño; levantar y rematar con INTERACT
  es de H5. Un falso derribado deja de buscar enemigos (`_find_enemy_position` pide `is_alive`).
- **Sin cambios** en `BattleLog` y `ScoreKeeper`: un derribo no es una baja; la baja es la muerte que le sigue
  (DEATH y KILL).

**Medido** (orientativo, sonda sin subir con 64 combatientes en una refriega y otros trabajos en la máquina):
el paso 7 sin derribados cuesta 1,6 µs por tick (no recorre a nadie); con 8 derribados y la mitad de la zona
pulsando E cada 2 ticks, 55–63 µs (sobre todo leer la entrada aplicada de los 64). `process_tick` con 64,
1,1–1,6 ms con o sin derribados (el ruido de la máquina es mayor que la diferencia). `test_downed` tarda ~16 s
con el arranque del motor (la prueba del desangrado avanza 1200 ticks en ~0,7 s), `test_consumables_server`
~12 s y `test_loadout_server` ~10 s.

**Para los paquetes siguientes.** H4: `_note_imposed_state` con DOWNED, INTERACT (levantado y cortes) y
LOADOUT propios; los avisos de derribado con la vida del bloque extra (bit 3, sobre 400); el selector manda
LOADOUT_SELECT (`0x07`) también antes de CLIENT_READY; el LOADOUT ajeno llega con 0 cargas. H5: bots que
levantan y rematan (mantienen E), el modo tramposo `interact`, `test_loadout_net` y la hoja de equilibrio con
los derribos (`tools/combat_balance.gd` ya mide hasta la caída).

### 11.7 H4 · cliente

**Hecho.**

- **Predicción y flechas.** `ClientPrediction` emite `stepped(tick, input, state)` tras cada `step()` (nunca
  en las repeticiones ni en el avance neutro del arranque). `ProjectileWorld` (`scripts/client/projectile_world.gd`)
  lo escucha: en el compromiso de un disparo crea las flechas predichas con la entrada de ese tick, el rayo
  canónico contra el mundo local y las cápsulas de los remotos hostiles tal como se dibujan, y la misma
  cuantización; las dibuja en el tiempo predicho, las para en el mundo con su propio rayo (el primer
  segmento con `hit_from_inside`) y las oculta al tocar la cápsula dibujada de un enemigo. El SPAWN propio
  se empareja por fuente, índice del abanico y tick (a menos de `input_buffer_ticks`) y se adopta con un
  desfase que decae en 6 ticks; sin pareja se dibuja la del servidor; sin SPAWN en `rtt + 30` ticks la
  predicha se retira. Las remotas salen en su `spawn_tick`, se dibujan en `pos(render_tick + fracción −
  spawn_tick)` y se retiran en `despawn_tick + f` (DESPAWN 4, con su propio rayo contra el mundo y las
  cápsulas dibujadas) o en `despawn_tick` (DESPAWN 5). `NetClient` la crea, la mete en la zona junto al
  `RemoteWorld` y le pasa los pasos, los SPAWN y los DESPAWN antes de emitir sus señales.
- **`ProjectileLaunch`** (`scripts/shared/combat/projectile_launch.gd`, compartido): qué dispara un
  compromiso (`from_state`: ataque con proyectil o habilidad con proyectil, su fuente, su velocidad con
  `lerp(1, charge_speed_scale, f)` y el abanico) y con qué balística (`launch`: rayo canónico, `aim_point`,
  boca en el pecho, giro en yaw `(i − (n − 1)/2) · spread` de la flecha `i` y `Ballistics.quantize`).
- **Barra de acciones** (`ActionBar`, UI-11): ligero/fuerte (o disparo/tensado), bloqueo (oculto con
  `can_block` falso), esquiva, habilidades 1–3 del arma activa, R y T con sus cargas y Q con el arma de la
  otra ranura, en casillas `UIIconSlot` con su glifo de tecla. Lee el estado predicho cada fotograma:
  reutilización `ability_ready[i] − tick predicho` con barrido y segundos, destello al acabar sola, sin
  destello si la quita una reconciliación (rechazo) o un cambio de arma; `ability_status` apaga (BLOCKED) y
  tacha (NO_CHARGES); la esquiva y el bloqueo se apagan agotado y la esquiva parpadea con el bit 1; una
  pulsación a destiempo (en las entradas de `LocalPlayerController.input_generated`) parpadea la casilla.
  Iconos provisionales `PlaceholderIcon` (una `Texture2D` que se dibuja sola: cuadro del color del arma y
  la inicial) con los colores de `CombatIcons`.
- **Estados** (UI-45): `StatusTracker` por entidad en `NetClient` (`get_status_tracker`), alimentado con los
  STATUS ya temporizados y vaciado por STATUS 2, DEATH, DOWNED, RESPAWN y el ENTITY_DESPAWN; `StatusIcons`
  (fila propia sobre la vida, contra el tick del servidor estimado: icono, segundos, acumulaciones, borde
  rojo o verde y tooltip) y las placas (hasta 4, primero los perjudiciales, contra el tick de dibujo; la
  barra de derribado en naranja con su icono).
- **Derribado**: `DownedNotice` («Derribado» con la cuenta atrás de la vida de derribado, «Ana te está
  levantando» o «¡Te rematan!» con la barra del INTERACT, «Mantén E para levantar a …» cerca de un aliado
  derribado y «Levantando a …»); `NetClient.is_downed()` (bit 3 del `status`); el registro de bajas enseña
  también los DOWNED.
- **Plantillas**: `TemplateSelector` en la pantalla de muerte (manda el LOADOUT_SELECT con
  `NetClient.send_loadout_select`) y en la elección de reino; `ClientConfig.loadout` (`--loadout=<plantilla>`)
  sale en un LOADOUT_SELECT nada más llegar el WELCOME, antes de CLIENT_READY.
- **Arco**: tensando, `CameraRig.set_aim_zoom` cierra el campo de visión al 75 % del configurado
  (`get_fov` sigue siendo el de los ajustes) y `Crosshair.set_tension` cierra la retícula con la carga.
- **Teclas**: Q `swap_weapon`, R `consumable_1`, T `consumable_2` (en `InputBindings` y
  `LocalPlayerController.BUTTON_ACTIONS`) y el bit `AIM_LEFT` en cada entrada del dispositivo con
  `CameraRig.get_effective_shoulder()` (el hombro tras el cambio automático por una pared).
- **Explicaciones de `NetClient`** (§5.4): STATUS de movimiento sobre uno mismo, DOWNED propio, INTERACT
  donde uno es el derribado o el actor y LOADOUT propio dan por explicada la corrección (el HIT propio con
  el bit 5 ya lo estaba: todo golpe recibido lo está).
- **Textos** (`CombatText`): `source_label` para las fuentes de §5.4 (ataques, habilidades, pulsos, remate y
  desangrado), la pantalla de muerte con «Te ha rematado…» y «Te has desangrado…», y los nombres de
  habilidades, efectos, armas y plantillas, por nombre del recurso.
- **Animación provisional** (§6.6): `CombatClipPlanner` gana las claves de cada habilidad, `drink`, `swap`,
  `downed`, `downed_crawl`, `revive`, `execute` y `get_up`; las habilidades con tres tramos se estiran a
  su lanzamiento, activo y recuperación; `CombatActionAnim.loop` (arrastrarse). Cada arma usa su juego
  (`CombatAnimationLayer.clips_for`: `data/animation/<arma>_clips.tres`; nuevo `bow_clips.tres`, y las
  entradas nuevas en `sword_shield_clips.tres`), el remoto con la pareja de armas de su vista y el bit 3 de
  su registro (`RemotePlayerView.get_active_weapon_id`, que toman del SPAWN y de un LOADOUT). `WeaponProps`
  gana el arco provisional (dos palas y empuñadura en arco, con cuerda) y `show_weapon`, que el
  `HumanoidVisual` llama cuando el animador avisa de otra arma (`weapon_shown`), también en los remotos.

**Pruebas.** Nuevas: `test_projectile_world` (5: la predicha se sustituye sin salto y adopta id, tick y
balística del servidor; dos pasos en un tick de física con el compromiso en el primero, con la
`ClientPrediction` de verdad; SPAWN propio con el jugador ya en el mundo por `NetClient`, con y sin
pareja; la remota sale en su `render_tick` y se retira en `despawn_tick + f` en un muro (f = 0,25) y en
`despawn_tick` al caducar; la propia se clava en el muro, se oculta en la cápsula de un enemigo y sin
SPAWN se retira en `rtt + 30`), `test_action_bar` (4: iconos y reutilizaciones tras dos cambios de arma;
**un rechazo revierte el contador** con `PredictionPair` y la pulsación perdida, sin destello; el destello
de la que acaba sola; cargas, tachado, parpadeos y agotamiento), `test_status_icons` (4: tracker, uno por
entidad y fuera con el DESPAWN, fila propia con duración y acumulaciones que se va al caducar, placa con
cuatro iconos perjudiciales primero, caducidad y derribado) y `test_ability_input` (2: Q, R, T y G sin
teclas repetidas; los bits nuevos y `AIM_LEFT` desde el hombro efectivo, también con la entrada
suspendida). Ampliadas: `test_hud_combat` (+5: avisos de derribado con levantar, corte y remate; la
invitación a levantar a un aliado y «Levantando a…»; el selector de la pantalla de muerte; zoom y
retícula del arco; registro de bajas y frases de remate y desangrado), `test_net_client` (+2:
LOADOUT_SELECT antes de CLIENT_READY y desde la pantalla de muerte; las explicaciones nuevas),
`test_combat_animation` (+4: juegos de clips por arma, claves y fases de habilidades, capa con el arma
y el levantarse, accesorios por arma), `test_remote_world` (+1: pareja de armas y bit de ranura),
`test_client_config` (+1, `--loadout`) y `test_realm_select` (+1). Adaptadas: `test_social_menu` (la tecla
del menú de jugador es G) y `test_combat_animation` (el arma 1 ya no es la espada: se pide por nombre).

**Desvíos y decisiones.**

- **T era el menú de jugador** (SOC-07, provisional). §0 da T a la poción de resistencia: el menú pasa a
  **G** (libre, y no la quieren el inventario I, el personaje C, el diario L ni las habilidades K de la
  hoja de ruta). Anotado en social.md y en SOC-07. Hasta UI-17 no hay reasignación ni perfil guardado, así
  que nadie tiene una T vieja.
- **`ProjectileLaunch` es nuevo y compartido.** §7.2 deja el disparo dentro de `ProjectileSystem.fire`; para
  que la flecha predicha y la del servidor salgan iguales, qué se dispara, con qué velocidad y en qué
  dirección (el giro del abanico incluido, que el documento no fijaba) vive en un solo sitio. H3b, hecho a
  la vez en otra rama, debe usarlo (o igualarlo) al fusionar: la prueba de `test_projectile_world` compara
  con él. Hecho en la fusión (§11.8): `ProjectileSystem.fire` dispara con él.
- **Tiempo de las flechas propias**: `tick predicho − 1 + fracción`, el instante en que se dibuja el
  personaje local (con interpolación de física, entre el tick anterior y el último), para que la flecha
  salga del pecho que se ve.
- **Lo que se para en el mundo** solo es la propia: una remota no se para por su cuenta (el servidor decide
  y avisa con el DESPAWN 4). Una flecha propia ya clavada desaparece cuando llega su DESPAWN; dejarla
  clavada un rato es de los VFX pendientes (ART-12).
- **El zoom** llega entero al alcanzar la carga mínima (antes se cierra a la par que la carga) y la
  retícula se cierra con la `f` de la carga (de la mínima a la máxima).
- **Plantilla en la elección de reino**: la de por defecto no se pide (sin LOADOUT_SELECT), para no mandar
  un mensaje que el servidor de antes de H3c cuenta como inesperado; elegir otra, y cualquier elección en la
  pantalla de muerte, sí.
- **Derribado sin eventos de servidor todavía**: los avisos leen el bit 3 del `status` y los INTERACT de
  H3c; mientras no los mande nadie, las pruebas usan eventos sintéticos, como las de cliente de antes.
- **Animación**: sin clip para la flecha ni para tensar (ART-41); el tensado usa `Pistol_Aim_Neutral` y el
  disparo, `Spell_Simple_Shoot`; `swap` es un `Sword_Idle` de 0,4 s con fundidos de 0,2 s; derribado
  quieto es el último fotograma de `Death01` y se arrastra con `Crouch_Fwd_Loop` en bucle; levantarse
  (`LayToIdle`) se ve una vez al pasar de DOWNED a NONE. El arco cuelga del mismo `BoneAttachment3D` que el
  escudo (la mano izquierda) y se crea la primera vez que hace falta.
- **Curación sin número**: el HEAL (poción) aún no saca un número verde; la fila de efectos ya enseña la
  regeneración. Queda para cuando haya VFX.
- **Ayudas de más**: `CameraRig.get_effective_fov()`/`get_aim_zoom()`, `Crosshair.get_ring_radius()`,
  `ActionBar.is_ranged(weapon)`, `CombatText.template_summary`, `NetClient.get_projectile_world()`,
  `KillFeed.show_downed`, `RemoteWorld.on_loadout` y `HUD.bind_controller` (el sandbox conecta su
  controlador para los parpadeos).

**Medido** (orientativo: máquina compartida, 4 núcleos con otros trabajos; `probes/bench_h4.gd`, no se sube):
dibujar 40 flechas remotas, 86–118 µs por fotograma (2,2–2,9 µs por flecha); el alta de una flecha predicha
(rayo canónico y `aim_point` contra un mundo plano), 25–27 µs; `ActionBar.refresh` con una reutilización
en marcha, 31–34 µs por fotograma; `StatusIcons.show_tracker` con dos efectos, 28–33 µs al principio y 4,6
µs tras no tocar lo que no cambia (con 32 placas cuenta: se tocan solo los iconos que cambian).

**Para los paquetes siguientes.** H3a: los STATUS y HEAL que ya pintan la fila propia y las placas
(`StatusTracker` los toma de `NetClient` sin más), el bit 5 de HIT. H3b: `ProjectileSystem.fire` con
`ProjectileLaunch.from_state` y `launch` (la misma fuente, velocidad, abanico y cuantización que la flecha
predicha; si se cambia algo, en los dos lados), el SPAWN con esa fuente y `volley_index` (la pareja se busca
por ellos) y los DESPAWN 4 y 5 (`ProjectileWorld` ya los atiende). H3c: el bit 3 del `status` con la vida de
derribado en el bloque extra, DOWNED e INTERACT (los avisos ya los leen), LOADOUT_SELECT en `ZoneServer`
(el cliente lo manda nada más llegar el WELCOME si eligió plantilla) y LOADOUT a quien tenga relevante al
jugador (la vista del remoto toma de él su pareja de armas). H5: los bots ponen `AIM_LEFT` ellos mismos (su
cámara es la canónica) y eligen plantilla con `--loadout`; `test_loadout_net` puede mirar las armas del otro
con `RemotePlayerView.get_weapons`/`get_active_weapon_id` y el sangrado del comando 14 con
`NetClient.get_status_tracker` y la fila del HUD; `test_projectile_loopback`, con las estadísticas de
`ProjectileWorld` (`substituted`, `rejected`).

### 11.8 Fusión de H3 (servidor) y H4 (cliente)

H3a–H3c (servidor, rama `wip/habilidades`) y H4 (cliente, rama `wip/habilidades-h4`) salieron a la vez de
H2. Se fusionan con `git merge --no-ff wip/habilidades-h4`.

**Qué chocó.** Solo la documentación; el código se fusionó solo, porque H3 tocó servidor y compartido y H4,
cliente, datos de animación y un archivo compartido nuevo (`ProjectileLaunch`).

- **`docs/backlog.md`**: las dos ramas añadían su nota «Hecho» al final de las mismas líneas. Son UI-45,
  CMB-19 a CMB-24, CMB-28, PRG-04, PRG-07 y PRG-08. Cada línea guarda las dos notas, primero las de H3 y luego
  la de H4, por orden de paquete. En las notas de H4, los «Falta…» que pedían el servidor (H3a, H3b o H3c)
  se ponen al día, porque ya está hecho. Las casillas son las de cada rama: CMB-20, CMB-28 y PRG-08 (H3) y
  UI-11 (H4).
- **`docs/habilidades.md`**: las dos ramas empezaban su §11 en 11.4. Las de H3 se quedan en 11.4–11.6 y la
  de H4 pasa a ser §11.7. Sus referencias se cambian a la vez: SOC-07 del backlog, el enlace de social.md
  §12.5 y el comentario de `InputBindings`.

**Integración de código: el servidor dispara con `ProjectileLaunch`.** H4 pedía en su «Desvíos y decisiones»
que la flecha del servidor y la predicha salieran del mismo sitio. H3b calculaba lo mismo por su cuenta, con
tres diferencias de borde:

- el servidor normalizaba dividiendo por `length()`;
- con una puntería degenerada, el servidor salía por el rayo de la cámara por debajo de 1 cm y
  `ProjectileLaunch` hacia −Z solo en el cero;
- el servidor solo leía la carga de un fuerte.

Ahora `ProjectileSystem.fire` saca qué sale, la velocidad (con la carga) y el abanico de
`ProjectileLaunch.for_attack`/`for_ability`, y el origen y la velocidad cuantizados de cada flecha de
`launch_toward(boca, punto, rayo de la cámara)`. El punto apuntado sigue siendo el del servidor: `aim_point`
con sus candidatos rebobinados y cribados.

En `ProjectileLaunch`:

- `MIN_AIM_DISTANCE` = 0,01 m;
- `launch_toward` gana `fallback`, la dirección del rayo de la cámara, que `launch` pasa;
- `for_attack` no cuenta la carga de un ligero.

Del servidor salen `_charge_progress` y `_MIN_AIM_DISTANCE`. Ninguna prueba de H3b ni de H4 cambia de
resultado. La única diferencia que queda entre las dos flechas es la de diseño (§6.2): los hostiles de la
convergencia, rebobinados en el servidor y tal como se dibujan en el cliente.

**Prueba nueva**: `test_projectiles::test_the_server_arrow_is_the_shared_launch_the_client_predicts`. Hace
un disparo rápido, un tensado con 40 ticks de carga desde el hombro izquierdo y el abanico, cada uno con
convergencia sobre un blanco a 20 m. El SPAWN trae, bit a bit, la fuente, el índice del abanico, el origen y
la velocidad que calcula el cliente con `ProjectileLaunch.from_state(...).launch(...)` a partir de la misma
entrada aplicada.

**Lo que ya encajaba** (comprobado leyendo los dos lados, sin cambios):

- **Derribado.** Los avisos de derribado leen `NetClient.get_health()`, el bloque extra, que con un
  derribado lleva la vida de derribado sobre 400 (`Combatant.publish`). Las placas usan el `health_q` de esa
  misma vida.
- **INTERACT.** Las operaciones 1 a 5 y su `end_tick` son las mismas en `DownedSystem` y `DownedNotice`. El
  remate acaba con la DEATH, que borra el aviso.
- **LOADOUT.** El LOADOUT ajeno llega con 0 cargas y `RemoteWorld.on_loadout` solo toma las armas.
- **LOADOUT_SELECT.** El de antes de CLIENT_READY lo admite `ZoneServer` en LOADING. La plantilla por
  defecto es la misma en los dos lados (`CombatCatalog.default_template_id`). El desvío de H4 de no pedirla
  al elegir reino ya no hace falta, pero tampoco molesta.
- **Flechas.** El SPAWN lleva la fuente y `volley_index`, con los que `ProjectileWorld` empareja la flecha.
  Los DESPAWN 4 y 5 los manda `ProjectileSystem`.
- **STATUS.** Los STATUS y HEAL de `StatusSystem` llegan a `StatusTracker` sin más.

**Arreglado al probar.** `test_combat_wire` fallaba ya en H3c (3 de 8; comprobado en `8d9a752`, antes de
fusionar) y H3c no lo había pasado. Había dos causas:

- **El LOADOUT de la entrada.** Cada cliente recibe el suyo, y el público de los que entran después. Las
  esperas de «algún evento» se cumplían antes del HIT, y el que no ve a nadie recibía un evento: su propio
  LOADOUT.
- **El derribado.** «test_world» es RVR, así que el golpe mortal entre reinos derriba.

Ahora las pruebas esperan el HIT por su clase y el ciego no recibe nada de los otros dos. La prueba del
KILL comprueba que el ligero derriba (bit 6 y no bit 4, DOWNED a los tres), que Ana remata manteniendo E y
que la DEATH y el KILL llevan la fuente del remate, a Ana como asesina y a Cleo como asistente.

**Pruebas.** Se pasaron 143 archivos, uno a uno, con 2020 pruebas. Son todos los de las áreas que tocan
las dos ramas: combate, predicción, mensajes, `ZoneServer`, HUD, flechas, derribado, habilidades, efectos,
plantillas, consumibles, chat y grupos, fuerte, asedio, PNJ y bots, más los de bucle local y procesos. Todo
pasa en verde. Lo único que falló fue `test_combat_wire`, arreglado arriba. Los únicos archivos que no se
pasaron son los 11 que nadie toca aquí: terreno, mapa y zona del Vado Gris, recursos, navmesh y rutas,
exportación, audio, nombres y reinos.

**Para H5**, sin cambios respecto de §11.6 y §11.7, ahora que cliente y servidor están juntos:

- `test_projectile_loopback`: con el SPAWN emparejado, `ProjectileWorld.stats` `substituted` y `rejected`;
- `test_loadout_net`;
- la prueba en red del sangrado del comando 14 en las placas y en el HUD;
- bots que levantan y rematan (mantienen E) y el modo tramposo `interact`;
- `AIM_LEFT` y `--loadout` en los bots;
- las pruebas contra el maniquí y la hoja de equilibrio.
