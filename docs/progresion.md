# Eldmark · Fase 5: diseño de la progresión

Diseño de lo que se guarda de un personaje y de lo que se juega con ello en el paso 5 de la
[hoja de ruta](vision.md#hoja-de-ruta): objetos (PRG-02), qué se guarda y sus invariantes (PRG-10),
inventario autoritativo (PRG-11), monedas y libro mayor (PRG-12), niveles (PRG-13), razas (PRG-14),
herramientas de GM (PRG-16), configuración de combate persistente (CMB-30), apariencia (ART-19) y la
ventana de inventario y personaje (UI-26).

Se apoya en [red.md](red.md), [combate.md](combate.md), [fuerte.md](fuerte.md) y [social.md](social.md).
Dos documentos se escriben a la vez:

- **`docs/plataforma.md`** (TEC-22 a TEC-28): el servicio en Go con PostgreSQL, cuentas, billetes,
  arrendamiento, guardado, copias. Este documento dice **qué** se guarda y qué tiene que cumplir;
  plataforma.md dice **cómo y dónde**. Lo que necesito de él está en la [sección 13](#13-interfaz-con-plataformamd).
- **`docs/habilidades.md`** (fase 4): equipo (PRG-04), plantillas al aparecer (PRG-07), pociones
  (PRG-08), habilidades y cambio de arma (CMB-19 a CMB-24). Este diseño encaja con ellos por los
  puntos que nombra la [sección 1](#1-qué-es-de-quién); si habilidades.md fija otro nombre, manda el suyo.

## 0. Decisiones

Provisionales, tomadas de noche (revisar), igual que todas las cifras del documento (curva,
recompensas, topes). Las cinco primeras salen de la recomendación del backlog y desde ahora están en
«Decisiones tomadas» de [backlog.md](backlog.md).

| Pregunta | Decisión |
|---|---|
| ¿Qué razas tiene cada reino? | **Un pueblo humano por reino, solo estético**: peinados, barbas, marcas y corte de los trajes. Mismo esqueleto, misma cápsula, ninguna estadística racial (§7). La piel usa la paleta completa en los tres reinos |
| ¿Inventario por ranuras o por peso? | **Ranuras en la bolsa** (30, ampliables) y **peso solo en el equipo puesto**, que ya decide la categoría de carga (PRG-06) |
| ¿Monedas y banco por personaje o por cuenta? | **Por personaje** (§5) |
| ¿Méritos gastables y puntos de reino separados? | **Dos contadores con el mismo evento**: méritos gastables (moneda) y puntos de reino que nunca bajan (ya tomada en fuerte.md §0; se mueve ahora) |
| ¿Quién recibe XP y crédito sin selección de objetivo? | **Contribución**: todo el que hace ≥ 10 % del daño en los últimos 900 ticks (`DamageLedger`, GUE-05), con recompensa personal (§6) |
| ¿Cambia el nivel las estadísticas en la fase 5? | **No.** La hoja base es la misma a cualquier nivel hasta que la zona PvE (fase 6) y la normalización de Eldrun (PRG-31) lo activen. El Vado Gris es la única zona y es RvR |
| Unidad del oro | Un solo entero, «oro», sin plata ni cobre |
| ¿Se equipa en combate? | No: equipar y desequipar solo fuera de combate y sin acción en curso. El cambio entre las dos armas (Q, CMB-24) sí vale en combate |
| Plantillas de la fase 4 (PRG-07) | Se convierten en el **kit de inicio**: la elegida al crear el personaje, puesta; los demás objetos de inicio, en la bolsa (§2.5) |
| Pociones (PRG-08) | Objetos apilables ligados; el campamento repone la pila hasta 5 |
| Enteros de 64 bits en JSON | **Cadenas decimales**. Comprobado: `JSON.parse_string` de Godot 4.7.2 devuelve `float` y lee 2^53 + 1 como 2^53 |

Siguen **pendientes** (fase 6) y el modelo admite cualquier respuesta: reglas de ligado (el campo
existe; los objetos de inicio van ligados), penalización por morir (la durabilidad existe y no baja en
la fase 5), formato de los datos de diseño (en la fase 5, `.tres` a mano) y nivel en Eldrun.
`vision.md` («Por definir: razas») se actualiza al integrar.

## 1. Qué es de quién

| Pieza | La decide | Dónde |
|---|---|---|
| Qué se guarda del personaje, sus invariantes, formatos de objeto, inventario, libro, niveles, apariencia | Este documento | §2–§12 |
| Servicio, migraciones, API HTTP, arrendamiento, billetes, guardado en la BD, copias, RGPD | plataforma.md | TEC-22 a TEC-28, TEC-41, TEC-43 |
| Nombres únicos, roles de GM, auditoría, sanciones | plataforma.md y social.md | SOC-13, SOC-14, SOC-18 |
| `EquipmentState`, recálculo de `StatBlock`, mensaje de hoja derivada, ids visuales de cada ranura | habilidades.md (PRG-04) | En la fase 5 se construye desde el contenedor EQUIPMENT (§4.1) |
| Plantillas `.tres` y su elección al aparecer | habilidades.md (PRG-07) | En la fase 5 solo para personajes efímeros (§2.5) |
| Pociones: acción, cargas por vida, reutilización | habilidades.md (PRG-08) | En la fase 5 consumen objetos (§4.4) |
| Habilidades, reutilizaciones en `PlayerState`, efectos | habilidades.md (CMB-19, CMB-20) | Se guardan las largas (§8) |
| Estadísticas PvP y fortalezas; atributos, maestrías, rareza y afijos | GUE-19; fase 6 (PRG-17 a PRG-20) | Sus tablas; los campos de la fase 6 ya existen (§2, §3) |

**Qué se juega en la fase 5.** El jugador entra con su cuenta (UI-22), crea un personaje (reino,
apariencia de su pueblo, nombre y plantilla de inicio; UI-24) y aparece en el Vado Gris con su kit.
Pelea como en la fase 4 y gana méritos, puntos de reino, XP y algo de oro de los Huecos, el capitán y
las capturas. Sube de nivel (1–40), ordena la bolsa, se equipa armas y armaduras fuera de combate,
bebe pociones que salen de su bolsa y se reponen en el campamento, y al volver lo encuentra todo:
equipo, monedas, nivel, vida, reutilizaciones largas y, si fue hace poco, el sitio donde lo dejó.

## 2. Objetos (PRG-02)

### 2.1 Definición y instancia

Una **definición** es lo que un objeto es (datos de diseño en `data/items/<categoría>/<id>.tres`, en
el repo, con un `id` estable); una **instancia** es un objeto concreto que alguien posee (una fila de
`item_instances`, con un `uid` único en todo el mundo y para siempre).

**`ItemDefinition`** (`scripts/shared/progression/item_definition.gd`, `Resource`):

| Campo | Tipo | Regla |
|---|---|---|
| `id` | `StringName` | `[a-z0-9_]`, 3–32 caracteres, único, nunca se reutiliza ni se renombra (la BD lo guarda) |
| `display_name`, `description` | `String` | Español; el nombre no vacío |
| `category` | `Category` | `WEAPON = 1`, `ARMOR = 2`, `CONSUMABLE = 3`, `MATERIAL = 4`, `QUEST = 5`, `MISC = 6` |
| `equip_slot` | `EquipSlot` | `NONE = 0`, `WEAPON = 1` (vale para las dos ranuras de arma), `HEAD = 2`, `CHEST = 3`, `HANDS = 4`, `LEGS = 5`, `FEET = 6` |
| `ref_id` | `StringName` | WEAPON → `WeaponDefinition.id` de `CombatCatalog`; ARMOR → la armadura de PRG-06; CONSUMABLE → el consumible de PRG-08; resto, vacío |
| `max_stack` | `int` | 1 = no apilable; tope 999. Equipables y objetos con durabilidad: 1 |
| `required_level` | `int` | 1–40 |
| `base_value` | `int` | Oro; ≥ 0. Base de los precios de la fase 6 |
| `bind_rule` | `BindRule` | `NONE = 0`, `ON_EQUIP = 1`, `ON_PICKUP = 2` |
| `destroyable` | `bool` | false: el jugador no puede destruirlo |
| `has_durability` | `bool` | La instancia lleva durabilidad (por mil) |
| `starter` | `bool` | Objeto de inicio (§2.5) |
| `camp_refill` | `int` | Cantidad a la que el campamento repone la pila; 0 = no se repone |
| `icon_path` | `String` | `res://assets/icons/items/…`; solo cliente |
| `visual_paths` | `PackedStringArray` | Escena por cuerpo (índice 0 masculino, 1 femenino; una sola sirve a los dos); solo cliente. Vacío en lo que no se ve |

Coherencia que exige la prueba: WEAPON ⇒ `equip_slot = WEAPON` y `ref_id` en `CombatCatalog`;
ARMOR ⇒ `equip_slot` de HEAD a FEET; CONSUMABLE ⇒ `equip_slot = NONE`; equipable ⇒ `max_stack = 1`.
`ItemDefinition` no tiene ninguna propiedad de tipo `Texture2D`, `PackedScene` ni `Mesh`: el preset
del servidor recorta `assets/` (TEC-12) y el servidor nunca debe intentar cargarlo.

**`ItemInstance`** (`scripts/shared/progression/item_instance.gd`, `RefCounted`):

| Campo | Tipo | Regla |
|---|---|---|
| `uid` | `int` | 1 … 2^63 − 1. Lo da el `IdAllocator` de la zona (§4.5) |
| `def_id` | `StringName` | Existe en `ItemDatabase` |
| `count` | `int` | 1 … `max_stack` |
| `durability` | `int` | 0–1000 (por mil) si `has_durability`; si no, −1 (NULL en la BD y en JSON, `0xFFFF` en el cable) |
| `rarity` | `int` | 0 común, 1 poco común, 2 rara, 3 épica, 4 legendaria. Fase 5: siempre 0 |
| `bound` | `bool` | Ligado al personaje |
| `seed` | `int` | u32 de los afijos (PRG-20); 0 = sin afijos |
| `affixes` | `PackedInt32Array` | Hasta 6 ids u16 de afijo (PRG-20). Fase 5: vacío |

### 2.2 `ItemDatabase`

Igual que `CombatCatalog`: lee `data/items/` (con subcarpetas) una vez, con carga perezosa, tolera los
`.tres.remap` de un proyecto exportado y registra los errores una sola vez.

- **Net id.** 1..n por orden alfabético de `id`; 0 = ninguno. Cambia al añadir objetos, por eso
  solo viaja por el cable y nunca se guarda.
- **Huella.** `wire_hash()`: u32 del SHA-256 de la lista ordenada `(id, net_id, category,
  equip_slot, max_stack, has_durability)`. Entra en `NetProtocol.compute_sim_hash`, igual que
  `CombatCatalog.prediction_hash()`: un cliente con otro catálogo recibe REJECT SIM_HASH. Tope: 65 535
  definiciones (u16).

### 2.3 Formato binario (`ItemInstance.encode()`, versión 1)

Un solo formato para la red y las pruebas; la BD guarda columnas (§3), no este blob.

| Offset | Tipo | Campo | Notas |
|---|---|---|---|
| 0 | u8 | format | 1. Otro valor: `decode` devuelve null |
| 1 | u64 | uid | 1 … 2^63 − 1 (el bit 63 a 0) |
| 9 | u16 | def | net id (≥ 1) |
| 11 | u16 | count | 1 … `max_stack` |
| 13 | u16 | durability | 0–1000; `0xFFFF` = sin durabilidad |
| 15 | u8 | rarity | 0–4 |
| 16 | u8 | flags | bit0 ligado; el resto a 0 |
| 17 | u32 | seed | |
| 21 | u8 | affix_count | 0–6 |
| 22 | n × u16 | affixes | |

Tamaño: 22 + 2·n B (22–34). `decode(bytes, offset)` devuelve null si falta algún byte, el formato no
es 1, el uid es 0 o tiene el bit 63, el net id no existe, la cantidad es 0 o pasa de `max_stack`, la
durabilidad no cuadra con `has_durability`, la rareza pasa de 4, hay bits de flags desconocidos o más
de 6 afijos. Nunca registra errores del motor (red.md §5.7).

### 2.4 Contenido inicial (fase 5)

Un objeto por arma, pieza de armadura y poción de la fase 4, todos `starter = true`, `bind_rule =
ON_PICKUP`, `required_level = 1`, `base_value = 0`:

| Objetos | Categoría | Pila | Notas |
|---|---|---|---|
| `sword_shield_vado` (espada y escudo), `bow_vado` (arco) | WEAPON | 1 | `ref_id` = el arma de `CombatCatalog`; sin durabilidad en la fase 5 |
| Las 15 piezas de PRG-06 (`armor_<carga>_<ranura>`) | ARMOR | 1 | `ref_id` = su armadura |
| `potion_health`, `potion_stamina` | CONSUMABLE | 20 | `camp_refill = 5` |

### 2.5 Kit de inicio y plantillas

Al crear el personaje se elige una plantilla de PRG-07 (`starter_template_id`). En la **primera
entrada** al mundo (`starter_granted = false`), la zona crea el kit en una sola operación con motivo
`STARTER_KIT` y guarda al instante:

1. Cada arma y armadura de la plantilla → su objeto de inicio (`ItemDatabase.starter_for_ref`),
   puesto: las armas en las ranuras 0 y 1 por el orden de la plantilla; cada armadura, en la suya.
2. Cada objeto de inicio que no haya quedado puesto (las armas y armaduras de las demás plantillas)
   → una unidad en la bolsa, desde la ranura 0 por orden de `id`.
3. Cada objeto con `camp_refill > 0` → una pila con esa cantidad en la bolsa.

Así se conserva la libertad de la fase 4 (cambiar de estilo) dentro del inventario. Una plantilla
desconocida usa la primera por orden de `id`, con aviso en el registro. Para un personaje
**persistente** desaparece la elección de plantilla al reaparecer (el servidor ignora esa petición);
los **efímeros** (`--fake-players`, bots y clientes con `DevAuthProvider` sin `--progress-file`) la
conservan tal como la deja PRG-07, con el kit en memoria y sin guardar nada.

## 3. El personaje que se guarda (PRG-10)

### 3.1 Qué se guarda

| Grupo | Campos | Dueño | Cuándo cambia |
|---|---|---|---|
| Identidad | `character_id`, `account_id`, `world_id`, `realm`, `name`, `name_key`, fechas, borrado con gracia, renombrado obligatorio | plataforma.md | Al crear, renombrar, borrar |
| Apariencia | `race_id`, `appearance` (8 B, §7.2) | Este documento | Solo al crear en la fase 5 |
| Progreso | `level`, `xp_total`, `realm_points`, `played_seconds` | Este documento | Al ganar XP o méritos; cada guardado |
| Inventario | Una fila por instancia; `bag_slots` | Este documento | Cada operación |
| Monedas | Saldo por moneda y el libro mayor | Este documento | Cada apunte |
| Combate | `health`, `active_weapon_slot`, `consumable_def_id`, habilidades elegidas, temporizadores largos | Este documento (CMB-30) | Cada guardado |
| Posición | `last_zone_id`, `last_channel`, posición, yaw, `last_in_combat`, `saved_at` | Este documento | Cada guardado |
| Inicio | `starter_template_id`, `starter_granted` | Este documento | Al crear y en la primera entrada |

`played_seconds` lo necesita además SOC-38 (menos de 2 h jugadas: sin `/reino` ni `/comercio`).

### 3.2 Invariantes

Los comprueban la zona al aplicar y el servicio al guardar (§13, S1–S9).

| # | Invariante |
|---|---|
| I1 | Un `uid` identifica una sola instancia en todo el mundo y nunca se reutiliza, ni tras destruirla |
| I2 | Una instancia está en un solo sitio: `(character_id, container, slot)` es único. En la fase 5 no hay objetos sin dueño |
| I3 | `1 ≤ count ≤ max_stack ≤ 999` |
| I4 | **Conservación.** La cantidad total de una definición solo cambia por un evento de objeto con motivo de fuente o de sumidero (§5.3). Mover, dividir, juntar e intercambiar no la cambian |
| I5 | `0 ≤ saldo ≤ tope` de su moneda y `saldo = Σ delta` de sus apuntes |
| I6 | Los apuntes y los eventos de objeto son inmutables; cada uno pertenece a una operación (`op_id`) que se aplica una sola vez |
| I7 | Una operación es atómica: todos sus apuntes y eventos se guardan en la misma transacción o ninguno |
| I8 | `level = curva.level_for(xp_total)`, entre 1 y 40; en el tope no se acumula XP; el nivel nunca baja (salvo `level_set` de GM) |
| I9 | `realm_points` solo sube con los apuntes positivos de méritos de juego y solo baja al revertirlos |
| I10 | En EQUIPMENT cada objeto está en una ranura compatible y la ranura de arma activa tiene un arma |
| I11 | La apariencia es válida para su raza y la raza es del reino del personaje |
| I12 | `save_version` crece de uno en uno; un guardado se aplica si su `base_version` es la actual o si repite el `save_id` ya aplicado (idempotente) |

### 3.3 Esquema propuesto

Nombres que plataforma.md puede adoptar tal cual (las migraciones y el DDL son suyos). Todo id es
`bigint` positivo de 63 bits; `characters` (identidad) es de plataforma.md. Probado en PostgreSQL 16
con una sonda: restricciones, disparador de solo añadir, intercambio de ranuras y secuencia.

| Tabla | Columnas | Claves y restricciones |
|---|---|---|
| `character_progress` | `character_id`, `race_id text`, `appearance bytea` (8 B), `level smallint` (1–40), `xp_total bigint`, `realm_points bigint`, `played_seconds bigint`, `bag_slots smallint` (1–120, 30 por defecto), `starter_template_id text`, `starter_granted bool`, `health int` (NULL = llena), `active_weapon_slot smallint` (0–1), `consumable_def_id text`, `last_zone_id text`, `last_channel smallint`, `pos_x`, `pos_y`, `pos_z`, `yaw real`, `last_in_combat bool`, `saved_at timestamptz`, `save_version bigint`, `last_save_id bigint` | PK `character_id` (1:1 con `characters`); los rangos como CHECK; contadores ≥ 0 |
| `character_wallets` | `character_id`, `currency smallint` (1 oro, 2 méritos), `balance bigint`, `last_seq bigint` | PK (`character_id`, `currency`); CHECK `balance BETWEEN 0 AND 1000000000` |
| `economy_ops` | `op_id`, `character_id`, `kind smallint` (§5.3), `actor_account_id` (NULL salvo GM), `ref_op_id` (la revertida), `zone_id text`, `created_at` | PK `op_id`. Solo añadir |
| `ledger_entries` | `entry_id bigserial`, `character_id`, `currency`, `seq bigint`, `op_id`, `delta bigint`, `balance_after bigint`, `reason smallint`, `ref_kind smallint`, `ref_id bigint`, `created_at` | UNIQUE (`character_id`, `currency`, `seq`) y (`op_id`, `character_id`, `currency`); CHECK `delta <> 0`, `balance_after >= 0`. **Disparador que rechaza UPDATE y DELETE** |
| `item_instances` | `uid`, `character_id`, `container smallint`, `slot smallint`, `def_id text`, `count int` (1–999), `durability smallint` (0–1000; NULL = sin), `rarity smallint` (0–4), `bound bool`, `seed bigint`, `affixes smallint[]` (≤ 6), `created_op bigint` | PK `uid` (CHECK > 0); UNIQUE (`character_id`, `container`, `slot`) **DEFERRABLE INITIALLY DEFERRED** |
| `item_events` | `event_id bigserial`, `op_id`, `character_id`, `uid`, `def_id`, `event smallint` (1 CREATE, 2 DESTROY, 3 COUNT), `count_delta int`, `reason smallint`, `created_at` | FK `op_id`. Solo añadir |
| `op_reversals` | `op_id`, `reversal_op_id` | PK `op_id`; UNIQUE `reversal_op_id`: una operación se revierte una vez |
| `character_ability_slots` | `character_id`, `weapon_id text`, `slot smallint` (0–2), `ability_id text` | PK (`character_id`, `weapon_id`, `slot`) |
| `character_timers` | `character_id`, `key text`, `ends_at timestamptz`, `stacks smallint` | PK (`character_id`, `key`) (§8) |
| `character_attributes` | `character_id`, `attribute smallint`, `spent smallint` | PK (`character_id`, `attribute`). Vacía hasta PRG-17 |
| `character_masteries` | `character_id`, `weapon_family text`, `level smallint`, `xp bigint` | PK (`character_id`, `weapon_family`). Vacía hasta PRG-18 |
| `uid_block_seq` | Secuencia `START 1 INCREMENT 1024` | §4.5 |

`container`: 0 BAG, 1 EQUIPMENT, 2 BANK (PRG-25), 3 reservado. La restricción de ranura es diferida
para que un intercambio quepa en una transacción. Mover e intercambiar no dejan filas en `item_events`
(no cambian cantidades): quedan en el registro de la zona.

### 3.4 `CharacterRecord` en JSON (`record_format` 1)

Es el cuerpo que la zona recibe al cargar y la parte `record` de un guardado. Las claves son las
columnas. **Los enteros que pueden pasar de 2^53** (`character_id`, `uid`, `op_id`, `seed`, `ref_id`,
`actor_account_id`, `last_save_id`) **van como cadena decimal**; el resto, como número.

```json
{"record_format": 1, "character_id": "41", "realm": 1, "name": "Ana", "race_id": "race_vardheim",
 "appearance": "AQEAAgEDAgE=", "level": 7, "xp_total": 12345, "realm_points": 420,
 "played_seconds": 7200, "bag_slots": 30, "starter_template_id": "escudero", "starter_granted": true,
 "health": 640, "active_weapon_slot": 0, "consumable_def_id": "potion_health",
 "location": {"zone_id": "vado_gris", "channel": 0, "position": [12.5, 3.0, -40.25], "yaw": 1.5, "in_combat": false, "saved_at": "2026-10-29T14:00:00Z"},
 "wallets": [{"currency": 1, "balance": 150}, {"currency": 2, "balance": 3200}],
 "items": [{"uid": "1025", "def_id": "sword_shield_vado", "container": 1, "slot": 0, "count": 1,
            "durability": null, "rarity": 0, "bound": true, "seed": "0", "affixes": []}],
 "ability_slots": [{"weapon_id": "sword_shield", "slot": 0, "ability_id": "shield_bash"}],
 "timers": [{"key": "unstuck", "ends_at": "2026-10-29T14:05:00Z", "stacks": 1}],
 "attributes": [], "masteries": [], "save_version": 12, "last_save_id": "5121"}
```

`appearance` va en Base64. `location` es null si no hay posición guardada. Las fechas, en UTC ISO 8601.

## 4. Inventario autoritativo (PRG-11)

### 4.1 Contenedores y ranuras

| Contenedor | Ranuras | Reglas |
|---|---|---|
| 0 BAG | `bag_slots` (30; tope 120) | Cualquier objeto; las pilas se juntan |
| 1 EQUIPMENT | 7: 0 WEAPON_1, 1 WEAPON_2, 2 HEAD, 3 CHEST, 4 HANDS, 5 LEGS, 6 FEET | Un objeto por ranura, compatible con su `equip_slot` |

El equipo puesto **es** el contenedor EQUIPMENT. Tras cada cambio confirmado, la zona reconstruye el
`EquipmentState` de PRG-04 desde él (`EquipmentState.rebuild_from(inventory, db)`) y PRG-04 recalcula
el `StatBlock` y manda su hoja derivada con el tick de entrada en vigor, como en la fase 4. El arma
activa (`CombatState.weapon_id`) es la del objeto de la ranura activa; la segunda ranura puede estar
vacía (CMB-24 no cambia entonces de arma).

### 4.2 Operaciones

Todas son intenciones del cliente que el servidor valida y aplica enteras o no aplica.

| Op | Código | Efecto |
|---|---|---|
| MOVE | 1 | A una ranura vacía: mueve la pila. A una con la misma definición apilable, el mismo `bound` y hueco en la pila: **junta** `min(count, max − destino)`; lo que no cabe se queda. Si no: **intercambia**. Hacia o desde EQUIPMENT es **equipar** o desequipar |
| SPLIT | 2 | Saca `n` (1 ≤ n < count) a una ranura vacía de la bolsa, con `uid` nuevo |
| DESTROY | 3 | Quita `n` (0 = toda la pila); si no queda nada, el `uid` muere |

Al equipar un objeto con `ON_EQUIP` se liga (`bound = true`) y el cambio viaja en el delta.

**Validación, en este orden; el primer fallo da el código:**

| Código | Nombre | Cuándo | Texto (`result_text`) |
|---|---|---|---|
| 0 | OK | Aplicada | — |
| 1 | INVALID | Op desconocida, contenedor o ranura fuera de rango, cantidad imposible (MOVE con `count ≠ 0`, SPLIT fuera de 1..count−1 o a una ranura que no es de la bolsa), origen igual a destino. **Suma un aviso** (red.md §12) | «Petición no válida» |
| 2 | STALE | El origen está vacío o su `uid` no es `expected_uid` | «Ese objeto ya no está ahí» |
| 3 | NOT_NOW | Sin personaje cargado o fuera del mundo; o la op toca EQUIPMENT y el personaje está muerto, en combate, con una acción en curso (`CombatState.action ≠ NONE`), bebiendo o cambiando de arma; o la op cambia cantidades y no queda bloque de ids (§4.5) | «Ahora no puedes hacerlo»; en combate, «No puedes cambiar el equipo en combate» |
| 4 | CANNOT_EQUIP | Ranura de equipo incompatible o `required_level` por encima del nivel | «No puedes equipar eso ahí» o «Necesitas nivel N» |
| 5 | WEAPON_REQUIRED | Dejaría vacía la ranura de arma activa | «Necesitas un arma en la mano» |
| 6 | NO_ROOM | SPLIT a una ranura ocupada; MOVE que junta en una pila llena del todo | «No cabe» |
| 7 | LOCKED | DESTROY de algo equipado o de un objeto con `destroyable = false` | «Ese objeto no se puede destruir» |
| 8 | RATE | Se mira al llegar, antes que todo lo demás: más de 8 peticiones/s (ráfaga 16). Una de cada cinco descartadas suma un aviso, como el chat (social.md §5) | «Más despacio» |

`InventoryOps.apply()` es **compartida y pura**: la usa el servidor para decidir y el cliente para su
intención optimista (§11), así que las dos validan igual. El servidor encola las peticiones al llegar
(en el `poll`) y las aplica al final del tick `s`, junto a las altas (red.md §8.1), en orden de
llegada; lo que cambia la simulación entra en vigor en `s + 1` por el mecanismo de PRG-04.

### 4.3 Transaccional en memoria y en la BD

- `InventoryOps.apply()` calcula el resultado sobre una copia de las ranuras implicadas y solo si todo
  vale lo escribe en el `InventoryState`; con el mismo paso añade al diario la operación (`op_id`, sus
  eventos de objeto y sus apuntes).
- El guardado (§9) manda el estado completo y el diario de operaciones pendientes, y el servicio lo
  aplica en **una** transacción. Una operación nunca se parte entre dos guardados.
- `kill -9`, SIGTERM o SIGINT (no llegan a GDScript, red.md §1.3) pierden 60 s como mucho, y a la vez
  el cambio y su registro: la BD nunca ve uno sin el otro. TEC-25 lo prueba matando el proceso.
- Cada operación aplicada (también los movimientos) deja una línea en el registro de la zona (`op_id`,
  personaje, op, ranuras, uids, resultado); los cambios de cantidad van además a la BD.

### 4.4 Lo que cambia el servidor por su cuenta

| Motivo | Cuándo | Efecto |
|---|---|---|
| `STARTER_KIT` | Primera entrada | §2.5; luego INVENTORY_FULL |
| `CAMP_REFILL` | Al entrar y al reaparecer en el campamento propio | Cada definición con `camp_refill` sube hasta esa cantidad en su pila de ranura más baja, o en una pila nueva en la primera ranura libre; con la bolsa llena no se repone (NOTICE «Bolsa llena») |
| `CONSUME` | Cuando el servidor acepta empezar a beber (PRG-08) | −1 de la pila de esa definición con la ranura de bolsa más baja; si no queda ninguna, PRG-08 lo trata como sin cargas |
| `GM_GRANT`, `GM_REMOVE`, `REVERSAL` | Comandos de §10 | Guardado inmediato |

### 4.5 `uid` y `op_id`: bloques

- La zona pide al servicio bloques de 1024 ids (`nextval('uid_block_seq')` da el primero: 1, 1025,
  2049…; comprobado en PostgreSQL 16). Los ids de un bloque son de esa zona y solo de ella.
- `IdAllocator` reparte los `uid` de los objetos **y** los `op_id` del mismo bloque: así los dos son
  únicos sin otra fuente. Pide el siguiente bloque cuando quedan menos de 256 y guarda dos como mucho.
- Un bloque a medias que se pierde en una caída deja un hueco: no importa, nunca se repite nada.
- Sin bloque disponible, todo lo que cambia cantidades (dividir, juntar, destruir, crear, monedas)
  responde NOT_NOW; mover, intercambiar y equipar no necesitan id y siguen funcionando.
- Los repositorios de memoria y de archivo (§9.4) reparten bloques de un contador propio.

### 4.6 Mensajes de red

Canal fiable 3, tipos `0x50`–`0x5F` (el chat usa `0x40`–`0x47` y los grupos `0x48` en adelante).
Ningún mensaje pasa de 1200 B.

**INVENTORY_REQUEST** (`0x50`, C→S, 18 B)

| Offset | Tipo | Campo | Notas |
|---|---|---|---|
| 0 | u8 | type | `0x50` |
| 1 | u16 | request_id | 1–65535; el cliente lo sube en cada petición y salta el 0 |
| 3 | u8 | op | 1 MOVE, 2 SPLIT, 3 DESTROY |
| 4 | u8 | from_container | 0 o 1 |
| 5 | u8 | from_slot | |
| 6 | u8 | to_container | `0xFF` en DESTROY |
| 7 | u8 | to_slot | `0xFF` en DESTROY |
| 8 | u16 | count | MOVE: 0. SPLIT: n. DESTROY: n (0 = toda la pila) |
| 10 | u64 | expected_uid | El `uid` que el cliente ve en el origen |

**INVENTORY_DELTA** (`0x51`, S→C, 10 B + entradas, ≤ 1120 B). Respuesta a una petición o cambio del
servidor.

| Offset | Tipo | Campo | Notas |
|---|---|---|---|
| 0 | u8 | type | `0x51` |
| 1 | u32 | revision | Revisión del inventario tras aplicar; sin cambio si `result ≠ 0` |
| 5 | u16 | request_id | 0 = cambio que decide el servidor |
| 7 | u8 | result | Código de §4.2 |
| 8 | u8 | reason | Motivo (§5.3) del cambio del servidor; 0 en las respuestas |
| 9 | u8 | entry_count | 0–30 |
| 10 | … | entradas | `u8 container`, `u8 slot`, `u8 present` (0 vacía, 1 con objeto) y, si `present`, `ItemInstance.encode()` |

Con `result ≠ 0` las entradas traen el contenido **real** de las ranuras que tocaba la petición, para
que el cliente revierta sin adivinar.

**INVENTORY_FULL** (`0x52`, S→C, ≤ 1089 B). Al entrar en el mundo (tras el SPAWN propio), tras el kit
de inicio y como respuesta a una sincronización: `u8 type`, `u32 revision`, `u8 bag_slots` (1–120),
`u8 page_index`, `u8 page_count` (1–8), `u8 entry_count` (0–30) y, solo de las ranuras ocupadas,
`u8 container`, `u8 slot` e `ItemInstance.encode()`. El cliente junta las páginas de una misma
revisión y solo entonces sustituye su estado.

**INVENTORY_SYNC_REQUEST** (`0x53`, C→S, 1 B). Pide un INVENTORY_FULL. Uno cada 5 s; más, aviso.

**Revisión.** u32 que empieza en 1 con cada sesión (no se guarda) y sube 1 con cada cambio aplicado.
Un delta aplicado (`result` 0) cuya revisión no es la confirmada + 1 hace que el cliente pida sincronía.

**Validación del `decode`:** tamaño exacto según los contadores, `entry_count ≤ 30`, `present` 0 o 1,
`page_index < page_count ≤ 8`, op entre 1 y 3, contenedores 0–3 (destino `0xFF` en DESTROY; el servidor
rechaza el 2 y el 3 en la fase 5) y cada objeto según §2.3. Devuelve null en cualquier otro caso.

## 5. Monedas y libro mayor (PRG-12)

### 5.1 Monedas

| Código | Moneda | Tope | Fuentes en la fase 5 | Sumideros en la fase 5 |
|---|---|---|---|---|
| 1 | Oro | 1 000 000 000 | PNJ derrotados, capturas, GM | Solo GM. La fase 6 abre comercio, reparación y reinicio de árbol |
| 2 | Méritos | 1 000 000 000 | PvP y objetivos (PRG-09), GM | Solo GM. La intendencia llega en la fase 7 (PRG-33) |

- **Por personaje**, `int64`, nunca negativo (CHECK en la BD y `CurrencyRules` en la zona).
- **Puntos de reino**: no son moneda. Suben en la misma operación que cada apunte positivo de méritos
  de juego y por la misma cantidad (I9).
- Lo ganado en las pruebas de la fase 5 se puede borrar al abrir la economía de la fase 6: una
  migración con motivo `MIGRATION` deja los saldos a 0 con su apunte.

### 5.2 Apunte

- `op_id`: la operación (§4.5). Clave de idempotencia: `(op_id, character_id, currency)` es única.
- `currency`, `delta` (≠ 0), `balance_after` (saldo tras el apunte) y `seq` (1, 2, 3… por saldo).
- `reason`: motivo de §5.3; su signo debe cuadrar con su rango.
- `ref_kind`, `ref_id`: 0 ninguna, 1 personaje (PvP), 2 PNJ (`npc_def_id`), 3 fortaleza, 4 operación.
- En la operación, `actor_account_id`: la cuenta del GM (SOC-14) o null.

**Agregación.** Las ganancias de juego (méritos de cada baja, oro de cada PNJ, cada segundo en el
círculo) cambian el saldo en memoria al momento y se apuntan al guardar: **un apunte por (moneda,
motivo)** y una operación por guardado. Así un jugador en batalla deja unos cinco apuntes por minuto,
no uno por segundo. Los de GM, kit y reversiones van sueltos y con guardado inmediato.

### 5.3 Motivos (`EconomyReason`, u8, fijos: nunca se reutilizan)

Rango 1–63: **fuentes** (`delta > 0`). Rango 64–127: **sumideros** (`delta < 0`). Rango 128–191:
**internos o neutros** (cualquier signo; dividir y juntar suman 0 por definición dentro de su
operación).

| Código | Motivo | Fase | Código | Motivo | Fase |
|---|---|---|---|---|---|
| 1 | STARTER_KIT | 5 | 64 | PLAYER_DESTROY | 5 |
| 2 | CAMP_REFILL | 5 | 65 | CONSUME | 5 |
| 3 | PVP_KILL | 5 | 66 | GM_REMOVE | 5 |
| 4 | PVP_ASSIST | 5 | 67 | VENDOR_BUY | 6 |
| 5 | OBJECTIVE (círculo, puerta, captura, defensa) | 5 | 68 | REPAIR | 6 |
| 6 | NPC_KILL | 5 | 69 | RESPEC | 6 |
| 7 | GM_GRANT | 5 | 70 | TRADE_OUT | 6 |
| 8 | LOOT | 6 | 71 | MAIL_OUT | 6 |
| 9 | QUEST | 6 | 72 | CRAFT_INPUT | 6 |
| 10 | VENDOR_SELL | 6 | 73 | QUARTERMASTER | 7 |
| 11 | TRADE_IN | 6 | 74 | MARKET_FEE | 8 |
| 12 | MAIL_IN | 6 | 128 | SPLIT | 5 |
| 13 | CRAFT_OUTPUT | 6 | 129 | MERGE | 5 |
| | | | 130 | REVERSAL | 5 |
| | | | 131 | MIGRATION | 5 |

Los mismos códigos sirven para los eventos de objeto. Tipos de operación (`economy_ops.kind`): 1
INVENTORY, 2 CONSUME, 3 STARTER_KIT, 4 CAMP_REFILL, 5 REWARD, 6 GM, 7 REVERSAL, 8 MIGRATION.

### 5.4 Reglas

- Una operación que dejaría un saldo negativo o por encima del tope no se aplica entera (también en
  memoria: `CurrencyRules.can_apply`). Una ganancia de juego que pasa el tope se recorta al tope.
- **Concurrencia en la zona.** Un personaje vive en una sola zona (arrendamiento, TEC-25) y sus
  operaciones se aplican en orden dentro del tick: no hay carreras.
- **Concurrencia en la BD.** El servicio aplica cada apunte con un `UPDATE … SET balance = balance +
  delta WHERE … AND balance + delta >= 0`. Comprobado con PostgreSQL 16 y dos transacciones a la vez
  que gastan 60 de un saldo de 100: la segunda espera el bloqueo, vuelve a evaluar la condición, no
  toca ninguna fila y se aborta; el saldo queda en 40 y la suma del libro es 40.
- **Reconstrucción.** `saldo = Σ delta` de sus apuntes; lo comprueba la prueba y, a diario, PRG-30.
- **Idempotencia.** Repetir una operación ya aplicada no hace nada: la restricción única la frena
  aunque dos repeticiones lleguen a la vez.

## 6. Niveles y experiencia (PRG-13)

### 6.1 Curva

`LevelCurve` (`data/progression/level_curve.tres`): `level_cap = 40`, `xp_to_next:
PackedInt32Array` de 39 valores y `attribute_points_per_level = 1`. Los valores se generaron con
`round((500 + 150 · (L − 1)^1,6) / 10) · 10`, pero el dato es la tabla, no la fórmula:

| Nivel | XP al siguiente | XP total para llegar al siguiente |
|---|---|---|
| 1 | 500 | 500 |
| 5 | 1 880 | 5 350 |
| 10 | 5 550 | 25 060 |
| 20 | 17 180 | 140 320 |
| 39 | 51 050 | 783 780 (tope) |

Con unos 3000 XP por hora de batalla en el Vado Gris, el nivel 10 llega en unas 8 h. El ritmo real
y las horas por nivel los fija PRG-22 en la fase 6 con la zona PvE.

### 6.2 Fuentes en la fase 5

| Fuente | XP | Oro | Regla |
|---|---|---|---|
| PvP | `méritos × 10` | — | Los méritos de PRG-09 (reparto por daño y antifarmeo incluidos): sin méritos no hay XP. Sin oro por matar jugadores, para que no se compre oro pactando muertes |
| PNJ | `NpcDefinition.xp_reward` | `NpcDefinition.gold_reward` | Cada contribuyente con ≥ 10 % del daño en 900 ticks recibe la recompensa entera (decisión §0). Valores: Hueco 40 XP y 2 oro; guardia de reino enemigo 60 y 3; Capitán del Vado 400 y 50; Guardianes de la Puerta 0 y 0 |
| Captura | 300 | 20 | A cada jugador del nuevo dueño que esté en el círculo en el tick de la captura |
| GM | `xp_add` | `currency_add` | §10 |

`xp_reward` y `gold_reward` son dos campos nuevos de `NpcDefinition` (MUN-07), con 0 por defecto.
El reparto de XP en grupo es de SOC-23 (fase 6).

### 6.3 Subida

- `ProgressionRules.add_xp(curve, level, xp_total, amount)` (pura, compartida) devuelve el nivel,
  el total, los niveles ganados y lo que se aplicó. Un solo aporte puede subir varios niveles. En el
  tope se aplica 0 y el total se queda en `curve.total_to(40)`.
- **Puntos de atributo** = `(level − 1) · attribute_points_per_level − Σ gastados`. No se guardan:
  se derivan, así PRG-17 puede cambiar el reparto sin migrar. En la fase 5 se ven y no se gastan.
- **Qué cambia al subir:** nada de la simulación ni de la hoja (decisión §0). Se ve en la ventana de
  personaje, en la placa de los aliados y desbloquea objetos por `required_level`.
- **Avisos:** PROGRESS_UPDATE al dueño (§12) y ENTITY_EVENT `16 LEVEL_UP` (`u8 level`, 10 B) al dueño
  y a los del **mismo reino** que lo tienen relevante, para el efecto visual; al enemigo no le llega
  (social.md §1: el nivel del enemigo no cruza). Subir de nivel guarda al instante.
- PROGRESS_UPDATE se agrupa: como mucho uno cada 10 ticks por jugador, con la suma de lo ganado.

## 7. Razas y apariencia (PRG-14, ART-19)

### 7.1 Un pueblo por reino

| Raza (`id`) | Reino | Lo propio (lo amplía ART-20) |
|---|---|---|
| `race_vardheim` | Vardheim | Trenzas y melenas, barbas largas, pintura de guerra azul y tatuajes de nudos |
| `race_solmarch` | Solmarch | Pelo corto o tonsura, barbas cuidadas, marcas de sol doradas |
| `race_askarra` | Askarra | Pelo recogido, barbas cortas, marcas de ceniza y cicatrices de forja |

El nombre del pueblo en la interfaz es provisional («Gente de Vardheim») hasta que lo fije el lore
(MUN-28). **En la simulación no cambia nada:** misma escena de `PlayerCharacter`, misma cápsula de
1,8 m, mismo `sim_hash`, ninguna estadística. No hay control de altura ni de complexión: el aspecto
debe llenar la misma cápsula que se usa para los golpes, o el rival vería un cuerpo más pequeño que
su hitbox. Cambia lo visual: peinados, barbas, marcas y, por PRG-05 y ART-27, el corte y el tinte de
los trajes. La piel usa la paleta completa en los tres reinos.

### 7.2 `CharacterAppearance`: 8 B

Índices sobre `AppearanceCatalog` (`data/characters/appearance_catalog.tres`), que tiene listas
**solo de añadir**: `races`, `bodies`, `heads`, `hairs`, `beards`, `marks` (`AppearancePart`: `id`,
`display_name`, rutas de malla solo cliente y `bodies` compatibles, vacío = todos) y `skin_tones`,
`hair_colors`, `eye_colors` (`AppearanceColor`: `id`, `display_name`, `color` y textura opcional).
`data/characters/appearance_ids.txt` congela el orden («categoría índice id» por línea) y la prueba
exige que el catálogo empiece por esa lista: nada se reordena ni se borra (se retira quitándolo de
las razas). Así los 8 B guardados en la BD siguen valiendo tras cualquier parche.

| Byte | Campo | Valor |
|---|---|---|
| 0 | race | índice en `races` + 1 (0 no vale) |
| 1 | body | índice en `bodies` (0 masculino, 1 femenino: los dos cuerpos de Universal Base Characters) |
| 2 | head | índice en `heads` |
| 3 | hair | 0 sin pelo; si no, índice + 1 |
| 4 | beard | 0 sin barba; si no, índice + 1 |
| 5 | skin | índice en `skin_tones` |
| 6 | hair_color | índice en `hair_colors` (pelo, barba y cejas) |
| 7 | eyes y marks | bits 0–3: índice en `eye_colors`; bits 4–7: 0 sin marcas o índice en `marks` + 1 |

**`RaceDefinition`** (`data/characters/races/<id>.tres`): `id`, `realm` (id de `RealmCatalog`),
`display_name`, listas de índices permitidos por categoría, `allows_no_hair`, `allows_no_beard` y
`stat_modifiers` (debe estar vacía: lo exige la prueba). Las marcas toman el color del reino.

**Validación** (`CharacterAppearance.validate(catalog, realm)`): la raza existe y es del reino; cada
índice está en las listas de la raza; cada pieza es compatible con el cuerpo; un 0 de pelo o barba solo
si la raza lo admite. Valida la plataforma al crear el personaje (con las reglas exportadas, §13) y la
zona al cargarlo: una apariencia inválida en la zona se sustituye por la primera válida de la raza y
se registra, sin echar al jugador.

### 7.3 En el SPAWN

El payload de PLAYER de ENTITY_SPAWN (red.md §5.5) crece **9 B** tras el nombre: `u8 level` (0 si el
receptor es de otro reino) y los 8 B de apariencia. Si en la fase 4 el SPAWN de PLAYER ya lleva un
bloque de equipo (PRG-04), ese bloque va primero y no cambia; los 9 B van detrás. Desde la fase 5 los
ids visuales del equipo son los net id de `ItemDatabase` del objeto de cada ranura (0 = vacía): el
cliente resuelve modelo e icono con un solo catálogo (`visual_paths` por cuerpo). El `decode` solo
comprueba el tamaño; la validez la mira el cliente (inválida → apariencia por defecto de la raza).

### 7.4 En el cliente (kit de Quaternius)

`AppearanceApplier` (solo cliente) monta sobre `HumanoidVisual` (ART-01, un solo `GeneralSkeleton`)
cuerpo, cabeza, pelo y barba como escenas glTF de Universal Base Characters (hoy en el repo:
`Superhero_Male_Head`, `Hair_SimpleParted`, `Hair_Beard`) y tiñe piel, ojos y pelo por material (los
shaders de la versión Source, cuando se compre). El equipo de PRG-05 oculta pelo y barba (capucha,
yelmo) con la lógica que ya tiene `HumanoidVisual`. Cambiar una pieza no recrea el personaje.

## 8. Configuración de combate persistente (CMB-30)

| Qué | Cómo se guarda | Al cargar |
|---|---|---|
| Las dos armas | Son objetos de EQUIPMENT 0 y 1 | Arman `EquipmentState` (PRG-04) |
| Arma activa | `active_weapon_slot`, leída del `PlayerState` al guardar (CMB-24) | Fija `CombatState.weapon_id` en el estado inicial del alta |
| Habilidades elegidas | `ability_slots`: 3 por arma (`WeaponDefinition.id`) | En la fase 5 deben ser el kit fijo del arma (CMB-21, CMB-23); otra cosa se corrige al kit. PRG-19 lo abrirá |
| Consumible de la barra | `consumable_def_id` (si PRG-08 permite elegirlo) | Ranura de consumible de UI-11 |
| Vida | `health` (null = llena) | `min(máx, guardada + health_regen_per_s · segundos desde saved_at)`; con 0 (murió) entra con la vida llena en el campamento |
| Reutilizaciones largas | `timers` con clave `ability:<id>`, `unstuck` o `consumable:<grupo>`, para las de **duración total ≥ 30 s** | `ready_tick = s + ceil((ends_at − ahora) · 60)`; vencidas, se descartan |
| Efectos largos | `timers` con clave `effect:<id>` y `stacks`, para los que su `StatusEffectDefinition` marca `persists = true` (CMB-20) | Se vuelven a aplicar con lo que les quede |

**Nada de lo que se predice por tick se guarda**: ni el resto de `CombatState` (resistencia, acción,
combo, controles, parada), ni la posición exacta entre guardados, ni las reutilizaciones de menos de
30 s. La conversión entre ticks y UTC solo existe en `scripts/server/` (`ProgressClock`, que lee
`Time`), como pide GUE-19; `scripts/shared/` no ve fechas. Para aplicar lo cargado, ProgressService
llama a `CombatDirector.apply_cooldown(entity, key, ready_tick)` y `apply_effect(entity, effect_id,
remaining_ticks, stacks)`, que habilidades.md debe ofrecer (CMB-19, CMB-20).

**Posición.** Se vuelve al sitio guardado solo si es la misma zona y canal, `saved_at` tiene menos de
15 min, no estaba en combate ni muerto, el punto pisa suelo (sondeo de 2 m), no está en un volumen
letal ni en la zona segura de otro reino. Si no, punto de aparición del reino (`SpawnPicker`).

**Traspasos (fase 6).** CMB-30 dice que esto «viaja en el billete», pero el billete tiene 47 B: la
zona de origen hace un guardado crítico antes del HANDOFF y la de destino lo carga. El billete solo
lleva la identidad.

## 9. Ciclo de vida en la zona

### 9.1 Carga y alta

1. HELLO con billete → `TicketAuthProvider` (TEC-24) → WELCOME con el reino del billete.
2. A la vez, `ProgressService.begin_load(peer, character_id, lease_token)` pide el registro.
3. `_process_arrivals` da de alta al peer cuando ha llegado su CLIENT_READY **y** su registro. Si el
   registro no llega en 10 s o falla: NOTICE de expulsión «No se ha podido cargar el personaje».
4. Alta: nombre, reino, apariencia y equipo del registro; vida, temporizadores y posición (§8); kit de
   inicio si toca (§2.5); reposición del campamento si aparece en él.
5. Tras el SPAWN propio: INVENTORY_FULL, un WALLET_UPDATE por moneda y un PROGRESS_UPDATE (estado).

### 9.2 Guardados

| Cuándo | Qué |
|---|---|
| Cada 60 s si hubo cambios | `next_checkpoint_tick = alta + 3600`, y +3600 tras cada uno: se reparten solos por hora de entrada |
| Al instante (crítico) | Kit de inicio, subida de nivel, comandos de GM y reversiones; en la fase 6, comercio y botín raro |
| Al salir | Tras la baja (y tras los 15 s del cuerpo que se queda si salió en combate, GUE-41), con `release_lease = true` |
| Al cerrar el servidor | `--stop-file`, `--quit-after-ticks`, `--idle-quit`: guarda a todos y espera las respuestas 10 s como mucho antes de salir |

- Como mucho **un guardado en vuelo por personaje** y 32 por zona; lo que cambie mientras tanto va en
  el siguiente. Un crítico durante un guardado en vuelo sale nada más llegar su respuesta.
- Un guardado sin respuesta se reintenta con el **mismo** `save_id` (1 s, 2 s, 4 s, hasta 30 s).
- `LEASE_LOST`: NOTICE de expulsión y se descarta el estado en memoria (manda el de la BD).
  `VERSION_CONFLICT` o `INVALID`: igual, más una alerta en el registro (es un error nuestro).

### 9.3 `CharacterSave` en JSON (`save_format` 1)

```json
{"save_format": 1, "character_id": "41", "lease_token": "…", "save_id": "5121", "base_version": 12,
 "reason": 1, "release_lease": false,
 "record": {"…": "CharacterRecord sin character_id, realm, name, race_id ni appearance"},
 "ops": [{"op_id": "5120", "kind": 6, "actor_account_id": "77", "ref_op_id": null,
          "ledger": [{"currency": 1, "delta": 50, "balance_after": 200, "reason": 7,
                      "ref_kind": 0, "ref_id": "0"}],
          "items": [{"uid": "5119", "def_id": "potion_health", "event": 1, "count_delta": 5,
                     "reason": 7}]}]}
```

`reason`: 1 periódico, 2 crítico, 3 salida, 4 cierre del servidor. `ops` va en orden de aplicación;
los apuntes de cada moneda, en orden de `seq`.

### 9.4 Repositorios

| Repositorio | Dónde | Uso |
|---|---|---|
| `MemoryProgressRepository` | `scripts/server/progress/` | Pruebas y efímeros. Responde en el `poll()` siguiente, determinista. Aplica las mismas comprobaciones S1–S9 |
| `FileProgressRepository` | ídem | Desarrollo sin plataforma: `--progress-file=<ruta.json>` con `DevAuthProvider`; el personaje se identifica por `NameRules.normalize_key(nombre)` y su reino queda fijado en la primera entrada (con otro reino, NOTICE de expulsión «Ese personaje es de otro reino»). Escribe a un temporal y renombra |
| `PlatformProgressRepository` | ídem, de TEC-25 | HTTP al servicio con los JSON de §3.4 y §9.3 |

## 10. Herramientas de GM (PRG-16)

Comandos del `CommandRegistry` (TEC-19): por la consola del servidor, por `/gm …` con rol (SOC-14) y,
solo con `--debug-commands`, los cuatro primeros por DEBUG_COMMAND sobre el propio jugador. En la fase 5
el personaje tiene que estar conectado en esa zona; la edición sin conexión es del panel de
moderación (SOC-37, fase 8).

| Comando | Argumentos | Efecto | Rol | Id de red |
|---|---|---|---|---|
| `item_give` | personaje def_id [cantidad] | Crea en la primera ranura libre de la bolsa (GM_GRANT); bolsa llena → error | GM | 40: `u16 def`, `u16 count` (1–999) |
| `currency_add` | personaje oro\|meritos ±cantidad motivo… | Apunte GM_GRANT o GM_REMOVE; el motivo escrito es obligatorio | GM | 41: `u8 currency` (1–2), `s32 amount` (≠ 0) |
| `level_set` | personaje nivel | Nivel y `xp_total = curve.total_to(nivel)` | GM | 42: `u8 level` (1–40) |
| `xp_add` | personaje cantidad | Como una fuente más | GM | 43: `u32 amount` (1–10 000 000) |
| `item_take` | personaje uid [cantidad] | Destruye (GM_REMOVE) | GM | — |
| `mastery_set` | personaje arma nivel | Reservado: «No disponible hasta la fase 6» | GM | — |
| `inv_show` | personaje | Bolsa y equipo con uid, cantidad y ligado | Moderador | — |
| `ledger_show` | personaje [n = 20] | Últimos n apuntes (los de la sesión y los del servicio) | Moderador | — |
| `op_show` | op_id | Apuntes y eventos de una operación | Moderador | — |
| `op_revert` | op_id motivo… | Revierte (abajo) | GM | — |

Los ids 40–43 son fijos en `NetProtocol.DEBUG_*` y su `decode` valida el tamaño y los rangos.

**Reversión.** Crea una operación REVERSAL con `ref_op_id` = la original y guarda al instante:

- Cada apunte → otro con el `delta` contrario. Si dejaría un saldo negativo (ya se lo gastó), no se
  revierte nada y el GM recibe el motivo; puede usar `currency_add`.
- Cada objeto creado → se destruye si sigue existiendo con al menos esa cantidad; si no, no se
  revierte nada y se dice qué falta.
- Cada objeto destruido → se crea de nuevo con **otro** `uid` (I1), la misma definición, cantidad y
  ligado, y el registro anota el `uid` antiguo.
- Méritos revertidos → bajan también los puntos de reino (I9).
- Solo se revierte una vez (`op_reversals`) y una reversión no se revierte. Dividir y juntar no se
  revierten (no cambian valor); una destrucción del jugador sí (le devuelve el objeto).
- Cada comando que cambia algo crea una operación GM con `actor_account_id`, aunque no tenga apuntes
  (así S7 admite que `level_set` baje el nivel), y queda en la auditoría de SOC-14.

## 11. Interfaz: inventario y ventana de personaje (UI-26)

### 11.1 Ventanas

| Ventana | Tecla | Contenido |
|---|---|---|
| Inventario | I | Rejilla de 6 columnas con `bag_slots` casillas (`InventorySlotView`, un `UIIconSlot` con arrastre); al pie, oro y méritos |
| Personaje | C | Figura 3D (SubViewport con `HumanoidVisual`, apariencia y equipo; gira al arrastrar), las 7 ranuras de equipo alrededor, nombre, reino, nivel y barra de XP, puntos de reino, puntos de atributo y la hoja derivada de PRG-01 (vida y resistencia máximas, armadura, categoría de carga, poder por familia) |

Las dos usan `UIWindow` (UI-09), se abren a la vez y liberan el cursor. Se arrastra de una a otra.

### 11.2 Gestos

| Gesto | Petición |
|---|---|
| Arrastrar y soltar | MOVE (mover, juntar, intercambiar, equipar, desequipar) |
| Mayúsculas + arrastrar | SPLIT, con un diálogo de cantidad (por defecto, la mitad) |
| Doble clic o clic derecho en la bolsa | Equipar: a su ranura; un arma, a WEAPON_2 si está vacía y si no a la ranura no activa |
| Doble clic o clic derecho en el equipo | Desequipar a la primera ranura libre de la bolsa |
| Soltar fuera de las ventanas | DESTROY tras `UIConfirmDialog` («¿Destruir Poción de vida ×5?», con cantidad en las pilas) |

**Tooltip** (`UITooltip`): nombre con el color de su rareza, categoría y ranura, nivel requerido (en
rojo si no llega), lo que aporta (arma: daño de sus ataques de `CombatCatalog`; armadura: armadura y
peso de PRG-06; poción: su efecto de PRG-08), «Ligado», valor, y la **comparación** con lo que hay
puesto en esa ranura (diferencias de la hoja derivada en verde o rojo).

### 11.3 Intención optimista y reversión

`ClientInventory` (`scripts/client/inventory/`) guarda el **estado confirmado**, la lista de
**peticiones pendientes** (8 como mucho; con 8, la interfaz espera) y una **vista** que es el
confirmado con las pendientes aplicadas por `InventoryOps.apply()`, la misma función del servidor.

1. **Gesto.** Se valida en local con `InventoryOps` (con el estado «en combate» del bloque extra del
   snapshot). Si falla, aviso con el texto del código y no se envía nada.
2. **Envío.** INVENTORY_REQUEST con el siguiente `request_id`; se añade a pendientes y se recalcula
   la vista: el objeto se mueve al instante. Una pila creada en local (SPLIT) lleva un `uid`
   provisional negativo (−`request_id`) y no se puede tocar hasta que el delta trae el real.
3. **Delta.** Sus entradas se aplican al confirmado, en orden de llegada; si trae `request_id`, esa
   petición sale de pendientes. Se recalcula la vista; una pendiente que ya no valga en local se
   quita (su propia respuesta llegará igual).
4. **Rechazo.** El delta trae el contenido real de las ranuras: aplicado al confirmado, el objeto
   **vuelve a su casilla**, con el aviso del código.
5. **Sin respuesta en 5 s** (no debería pasar en un canal fiable): se vacían las pendientes y se pide
   INVENTORY_SYNC_REQUEST; el FULL reconstruye todo.

Lo que **no** es optimista: el modelo 3D, la barra de acciones (UI-11) y la hoja derivada cambian con
el estado **confirmado** y con la hoja de PRG-04, un RTT después; así un rechazo nunca hace parpadear
el arma en las manos.

## 12. Protocolo

La fase 5 ocupa **una** versión, la siguiente libre al integrar (el chat de la fase 4 ya usa la 5):

| Qué | Formato |
|---|---|
| HELLO | Sin cambios de formato: `character_id` y `ticket` pasan a usarse (TEC-24); `realm` y `name` se ignoran con billete |
| ENTITY_SPAWN de PLAYER | +9 B tras el nombre (y tras el bloque de equipo de PRG-04 si existe): `u8 level`, 8 B de apariencia (§7.3) |
| `0x50`–`0x53` | INVENTORY_REQUEST (C→S, 18 B), INVENTORY_DELTA (S→C, ≤ 1120 B), INVENTORY_FULL (S→C, ≤ 1089 B), INVENTORY_SYNC_REQUEST (C→S, 1 B): §4.6 |
| `0x54` WALLET_UPDATE | S→C, 19 B: `u8 type`, `u8 currency`, `u64 balance`, `s64 delta` (0 en el estado inicial), `u8 reason`. Uno cada 10 ticks por moneda como mucho, con el delta sumado |
| `0x55` PROGRESS_UPDATE | S→C, 25 B: `u8 type`, `u8 level`, `u32 xp_in_level`, `u32 xp_to_next` (0 en el tope), `u32 gained`, `u8 source` (0 estado, 1 PvP, 2 PNJ, 3 captura, 4 GM), `u64 realm_points`, `u16 attribute_points` |
| `0x56`–`0x5F` | Reservados (banco, comercio y correo de la fase 6) |
| ENTITY_EVENT `16 LEVEL_UP` | `u8 level`, 10 B. El 16 deja hueco a los eventos que añada la fase 4 |
| DEBUG_COMMAND 40–43 | §10 |
| `sim_hash` | Añade `ItemDatabase.wire_hash()` y `AppearanceCatalog.wire_hash()` |

Van en `scripts/shared/net/progress_messages.gd` (`ProgressMessages`), aparte de `net_messages.gd`
para no chocar con otros carriles; por el canal 3 y solo al dueño salvo LEVEL_UP. Una petición antes
de estar en el mundo suma un aviso.

## 13. Interfaz con plataforma.md

Lo que este documento **necesita** del servicio. Los nombres de §3.3, §3.4 y §9.3 son propuestas: si
plataforma.md elige otros, se cambian aquí y en las pruebas.

| # | Necesito | Notas |
|---|---|---|
| 1 | Las tablas de §3.3 con sus restricciones, en sus migraciones | `characters` y lo de identidad son suyos |
| 2 | **Cargar** un personaje con arrendamiento → `CharacterRecord` (§3.4) | Con el billete (TEC-24, TEC-25) |
| 3 | **Guardar** un `CharacterSave` (§9.3) → `{version}` o un error: `LEASE_LOST`, `VERSION_CONFLICT`, `INVALID` (con detalle), `UNAVAILABLE` | Idempotente por `save_id` |
| 4 | **Bloque de ids** → `{"first": "…", "count": 1024}` | `uid_block_seq` |
| 5 | **Operación** por `op_id` y **libro** de un personaje (`limit`, `before_entry_id`) | Para `op_show`, `ledger_show` y la reversión |
| 6 | **Crear personaje** con `race_id`, `appearance` (Base64) y `starter_template_id`, validados con `data/generated/progression_rules.json` | Ese archivo lo genera `tools/progression/export_rules.gd` desde los `.tres` (razas y límites de apariencia, plantillas, curva, topes, rangos de motivos, `MAX_STACK`); una prueba falla si está desfasado. El servicio no lee `.tres` |
| 7 | En JSON, los enteros que pueden pasar de 2^53, como cadena | Comprobado en Godot 4.7.2 |
| 8 | Retención: el libro y los eventos de objeto mientras exista el personaje y un año después (PRG-39) | Lo encaja TEC-43 con el RGPD |
| 9 | `actor_account_id` de SOC-14 en las operaciones de GM | |
| 10 | Un arnés de PostgreSQL desechable para las pruebas del servicio | Receta comprobada en §15 |

**Comprobaciones del guardado (S1–S9)**, en una transacción y con la fila del personaje bloqueada:

| # | Comprobación |
|---|---|
| S1 | El arrendamiento es de quien guarda; si no, `LEASE_LOST` |
| S2 | `save_id = last_save_id` → OK con la versión actual (repetición). Si no, `base_version = save_version`, o `VERSION_CONFLICT` |
| S3 | Ningún `op_id` existe ya |
| S4 | Por moneda y en orden: `balance_after = anterior + delta`, entre 0 y el tope, signo según el rango del motivo; el último es el saldo de `record` |
| S5 | Por `uid`: cantidad guardada (0 si no estaba) + Σ `count_delta` = cantidad en `record` (0 si no está). Un CREATE solo de un `uid` que nunca existió (ni destruido); un `uid` de otro personaje → `INVALID` |
| S6 | En cada operación, Σ `count_delta` de los motivos internos (SPLIT, MERGE) por definición = 0 |
| S7 | Ranuras únicas y en rango (bolsa < `bag_slots`, equipo < 7), `count ≤ 999`, nivel 1–40, `xp_total` y `realm_points` no bajan salvo con una operación GM o REVERSAL |
| S8 | Los `timers` caducan en menos de 7 días |
| S9 | Escribe todo: fila de progreso (versión + 1, `last_save_id`), objetos (borra los que faltan y actualiza o inserta el resto), operaciones, apuntes, eventos, temporizadores y habilidades; libera el arrendamiento si se pide |

S4 a S6 duplican en Go lo que `InventoryOps` y `CurrencyRules` ya garantizan en GDScript: es la red de
seguridad contra un error de la zona, no la regla del juego. Para que las dos implementaciones no
diverjan, las pruebas de GDScript escriben en `tests/fixtures/progression/` casos de guardado válidos
e inválidos que las pruebas de Go leen.

## 14. Paquetes y contratos

### 14.1 Paquetes

| Paquete | Contenido | Depende de |
|---|---|---|
| **P1 · objetos** | `ItemDefinition`, `ItemInstance` (encode/decode), `ItemDatabase`, `data/items/` (§2.4), `test_item_database`, `test_item_instance` | `CombatCatalog`; PRG-06 y PRG-08 para validar sus `ref_id` (sin ellos, la prueba salta esas categorías) |
| **P2 · inventario puro** | `InventoryState`, `InventoryOps`, `ItemEvent`, `EconomyReason`, `Currency`, `CurrencyRules`, `StarterKit`; `test_inventory_ops`, `test_inventory_properties`, `test_currency_rules` | P1; PRG-07 para `StarterKit` |
| **P3 · progreso y apariencia** | `LevelCurve` y su `.tres`, `ProgressionRules`, `CharacterAppearance`, `AppearanceCatalog`, `AppearancePart`, `AppearanceColor`, `RaceDefinition`, `data/characters/`, `tools/progression/export_rules.gd`; `test_level_curve`, `test_character_appearance`, `test_progression_rules_export` | — |
| **P4 · protocolo** | `ProgressMessages` (0x50–0x55), cola del SPAWN, LEVEL_UP, ids 40–43, `PROTOCOL_VERSION`, `sim_hash`; red.md actualizado; `test_progress_messages` | P1, P3 |
| **P5 · servidor** | `scripts/server/progress/`: `CharacterRecord`, `CharacterSave`, `EconomyOp`, `LedgerEntry`, `IdAllocator`, `ProgressClock`, `ProgressRepository`, `MemoryProgressRepository`, `FileProgressRepository`, `PlayerProgress`, `ProgressService` y su cableado en `ZoneServer` (carga, alta, peticiones, recompensas, guardados, cierre, comandos de §10), `--progress-file` en `ServerConfig`, campos de `NpcDefinition`; `test_player_progress`, `test_progress_persistence`, `test_progress_service`, `test_gm_progress` | P2, P3, P4; PRG-04, PRG-08, CMB-19, CMB-20 en sus puntos de §8 |
| **P6 · cliente** | `ClientInventory`, `InventoryWindow`, `CharacterWindow`, `InventorySlotView`, `SplitDialog`, `AppearanceApplier`, mensajes en `NetClient`; `test_client_inventory`, `test_inventory_window`, `test_appearance_visual` | P2, P3, P4, UI-09 |
| **P7 · servicio** (plataforma.md) | Tablas de §3.3, S1–S9, bloques, operación y libro; pruebas de Go | §3, §9.3 y §13; TEC-22 |
| **P8 · integración** | `test_progress_loopback` (§15), `PlatformProgressRepository` con TEC-25 | P5, P6; P7 para la parte real |

P1 y P3 van en paralelo; después P2 y P4; después P5 y P6 en paralelo. P7 puede empezar en cuanto
este documento esté fijado. P8 al final.

### 14.2 Contratos

Firmas públicas y estables; lo privado queda a criterio de quien implemente. Los campos de datos son
los de §2.1, §3.4 y §7.2 con tipos estáticos.

```gdscript
# scripts/shared/progression/ (compartido: sin Time, OS ni Input)
class_name ItemDefinition extends Resource          # enums Category, EquipSlot, BindRule de §2.1

class_name ItemInstance extends RefCounted
const FORMAT: int = 1; const MAX_AFFIXES: int = 6; const NO_DURABILITY: int = -1
var uid: int; var def_id: StringName; var count: int; var durability: int; var rarity: int
var bound: bool; var seed: int; var affixes: PackedInt32Array
func encode(db: ItemDatabase = null) -> PackedByteArray                  # null = shared()
static func decode(bytes: PackedByteArray, offset: int, db: ItemDatabase = null) -> ItemInstance
static func encoded_size_at(bytes: PackedByteArray, offset: int) -> int   # −1 si no cabe
func duplicate_instance() -> ItemInstance; func equals(other: ItemInstance) -> bool

class_name ItemDatabase extends RefCounted
const DATA_DIR: String = "res://data/items"
var errors: PackedStringArray
static func shared() -> ItemDatabase; static func build_from_directory(dir: String) -> ItemDatabase
func get_definition(id: StringName) -> ItemDefinition                    # null si no existe
func net_id_of(id: StringName) -> int; func definition_by_net_id(net_id: int) -> ItemDefinition
func starter_for_ref(category: int, ref_id: StringName) -> ItemDefinition
func all_ids() -> Array[StringName]; func wire_hash() -> int

class_name InventoryState extends RefCounted
enum Container { BAG = 0, EQUIPMENT = 1, BANK = 2 }
enum EquipmentSlot { WEAPON_1 = 0, WEAPON_2 = 1, HEAD = 2, CHEST = 3, HANDS = 4, LEGS = 5, FEET = 6 }
const BAG_SLOTS_DEFAULT: int = 30; const BAG_SLOTS_MAX: int = 120; const EQUIPMENT_SLOTS: int = 7
var bag_slots: int; var active_weapon_slot: int
func get_item(container: int, slot: int) -> ItemInstance                 # null si vacía
func set_item(container: int, slot: int, item: ItemInstance) -> void     # null la vacía
func first_free(container: int) -> int; func find_uid(uid: int) -> Vector2i   # −1 / (−1, −1)
func count_of(def_id: StringName) -> int; func all_items() -> Array[ItemInstance]
func duplicate_state() -> InventoryState

class_name InventoryOps extends RefCounted
enum Op { MOVE = 1, SPLIT = 2, DESTROY = 3 }
enum Result { OK = 0, INVALID = 1, STALE = 2, NOT_NOW = 3, CANNOT_EQUIP = 4,
		WEAPON_REQUIRED = 5, NO_ROOM = 6, LOCKED = 7, RATE = 8 }
class Request:
	var op: int; var from_container: int; var from_slot: int; var to_container: int
	var to_slot: int; var count: int; var expected_uid: int
class Context:
	var db: ItemDatabase; var level: int = 1
	var can_touch_equipment: bool = true          # false: muerto, en combate, en una acción…
	var new_id: Callable = Callable()             # () -> int; inválido = sin bloque de ids
class Outcome:
	var result: int; var changed: Array[Vector2i]; var events: Array[ItemEvent]
static func apply(state: InventoryState, request: Request, context: Context) -> Outcome
static func result_text(result: int) -> String                           # español (§4.2)

class_name ItemEvent extends RefCounted
enum Kind { CREATE = 1, DESTROY = 2, COUNT = 3 }
var uid: int; var def_id: StringName; var kind: int; var count_delta: int; var reason: int
class_name EconomyReason extends RefCounted    # constantes de §5.3; is_source, is_sink, is_internal
class_name Currency extends RefCounted         # enum Code { GOLD = 1, MERITS = 2 }; const CAP = 10^9
class_name CurrencyRules extends RefCounted
static func can_apply(balance: int, delta: int) -> bool
static func clamp_gain(balance: int, gain: int) -> int

class_name LevelCurve extends Resource
@export var level_cap: int = 40
@export var xp_to_next: PackedInt32Array
@export var attribute_points_per_level: int = 1
func total_to(level: int) -> int; func level_for(xp_total: int) -> int
class_name ProgressionRules extends RefCounted
const XP_PER_MERIT: int = 10
class XpResult:
	var level: int; var xp_total: int; var levels_gained: int; var applied: int
static func add_xp(curve: LevelCurve, level: int, xp_total: int, amount: int) -> XpResult
static func attribute_points(curve: LevelCurve, level: int, spent: int) -> int

class_name CharacterAppearance extends RefCounted   # campos de §7.2
const ENCODED_SIZE: int = 8
func encode() -> PackedByteArray
static func decode(bytes: PackedByteArray) -> CharacterAppearance       # null si no son 8 B
func validate(catalog: AppearanceCatalog, realm_id: StringName) -> bool
static func random(catalog: AppearanceCatalog, race_index: int,
		rng: RandomNumberGenerator) -> CharacterAppearance
static func default_for(catalog: AppearanceCatalog, race_index: int) -> CharacterAppearance

class_name StarterKit extends RefCounted
## Coloca el kit de §2.5 en un inventario vacío; devuelve los CREATE (motivo STARTER_KIT).
static func grant(state: InventoryState, template_id: StringName, db: ItemDatabase,
		new_id: Callable) -> Array[ItemEvent]

# scripts/server/progress/ (servidor)
class_name ProgressRepository extends RefCounted
enum Result { OK = 0, NOT_FOUND = 1, LEASE_LOST = 2, VERSION_CONFLICT = 3, INVALID = 4,
		UNAVAILABLE = 5 }
signal character_loaded(request_id: int, result: int, record: CharacterRecord)
signal character_saved(request_id: int, result: int, version: int)
signal id_block_granted(request_id: int, result: int, first_id: int, count: int)
func load_character(character_id: int, lease_token: String) -> int       # id de petición
func save_character(save: CharacterSave) -> int; func request_id_block() -> int
func poll() -> void                                                      # una vez por tick

class_name CharacterRecord extends RefCounted     # campos de §3.4
const RECORD_FORMAT: int = 1
static func ephemeral(display_name: String, realm: int, template_id: StringName) -> CharacterRecord
func to_dictionary() -> Dictionary
static func from_dictionary(data: Dictionary) -> CharacterRecord         # null si no cuadra

class_name PlayerProgress extends RefCounted   # estado autoritativo de un personaje en la zona
var record: CharacterRecord; var inventory: InventoryState
func apply_request(request: InventoryOps.Request, context: InventoryOps.Context) -> InventoryOps.Outcome
func grant_item(def_id: StringName, count: int, reason: int, actor: int) -> InventoryOps.Outcome
func consume_one(def_id: StringName) -> bool
func add_currency(currency: int, delta: int, reason: int, ref_kind: int, ref_id: int,
		actor: int) -> bool
func add_merits(amount: int, reason: int, ref_kind: int, ref_id: int) -> void
func add_xp(amount: int, source: int) -> ProgressionRules.XpResult
func is_dirty() -> bool
func build_save(save_id: int, reason: int, release_lease: bool) -> CharacterSave
func acknowledge(save: CharacterSave, version: int) -> void

class_name ProgressService extends RefCounted
signal record_ready(peer_id: int); signal record_failed(peer_id: int, reason: String)
func setup(zone: ZoneServer, repository: ProgressRepository, commands: CommandRegistry) -> void
func begin_load(peer_id: int, character_id: int, lease_token: String) -> void
func is_ready(peer_id: int) -> bool
func on_spawned(entity: NetEntity, peer: ServerPeer, s: int) -> void     # §9.1, pasos 4 y 5
func handle_request(peer: ServerPeer, bytes: PackedByteArray) -> void    # 0x50 y 0x53
func apply_pending(s: int) -> void                                       # final del tick
func on_merits(net_id: int, amount: int, reason: int, ref_kind: int, ref_id: int) -> void
func on_npc_killed(npc_def_id: int, contributors: PackedInt32Array) -> void
func on_capture(fortress_id: StringName, owner_realm: int, in_circle: PackedInt32Array) -> void
func on_departure(net_id: int) -> void
func tick(s: int) -> void; func drain(timeout_ms: int) -> void           # guardados; cierre

# scripts/client/inventory/ (cliente)
class_name ClientInventory extends RefCounted
signal view_changed; signal confirmed_changed; signal request_rejected(result: int, text: String)
const MAX_PENDING: int = 8
func request(op: InventoryOps.Request) -> int                 # Result local; OK = enviada
func on_delta(delta: ProgressMessages.InventoryDelta) -> void
func on_full_page(page: ProgressMessages.InventoryFull) -> void
func get_view() -> InventoryState; func get_confirmed() -> InventoryState
func tick(now_msec: int) -> void                              # plazo de 5 s
class_name AppearanceApplier extends RefCounted
static func apply(visual: HumanoidVisual, appearance: CharacterAppearance,
		catalog: AppearanceCatalog) -> void
```

`test_architecture` se amplía: `scripts/shared/progression/` no nombra `Time`, `OS`, `Input` ni nada
de `scripts/client/` o `scripts/server/`; ningún recurso de `data/items/` ni de `data/characters/`
tiene propiedades `Texture2D`, `PackedScene` o `Mesh`; `ProgressClock` es el único de
`scripts/server/progress/` que lee `Time`.

## 15. Pruebas

Cada una dura menos de 30 s con el ejecutor actual (`run_tests.gd`) o con `go test`.

| Prueba | Qué comprueba |
|---|---|
| `test_item_database` | ids únicos y con formato; todos los `.tres` en texto (empiezan por `[gd_resource`); coherencia de §2.1; `ref_id` que existen; un objeto de inicio por `ref_id` de plantilla; net ids alfabéticos; `wire_hash` estable entre dos cargas |
| `test_item_instance` | Ida y vuelta de 1000 instancias aleatorias con semilla; null en cada caso de §2.3 (truncado, formato 2, uid 0, bit 63, net id desconocido, cantidad 0 o > pila, 7 afijos) |
| `test_inventory_ops` | Tabla de casos: cada op y cada código de §4.2, en su orden; juntar parcial; intercambio; ligado al equipar |
| `test_inventory_properties` | 20 semillas × 5000 operaciones aleatorias (válidas e inválidas): la cantidad por definición no cambia sin fuente ni sumidero, ningún `uid` se repite ni reaparece tras morir, ranuras únicas, la ranura activa siempre con arma. Menos de 10 s |
| `test_currency_rules` | Topes, negativos, dos operaciones del mismo tick sobre un saldo, reconstrucción desde los apuntes |
| `test_level_curve` | 39 valores crecientes; `level_for(total_to(n)) = n`; varias subidas con un solo aporte; tope |
| `test_character_appearance` | Ida y vuelta de 8 B; `validate` rechaza cada índice fuera de rango y la raza de otro reino; 100 aleatorias válidas por raza; `appearance_ids.txt` es prefijo del catálogo; `stat_modifiers` vacío |
| `test_progression_rules_export` | `data/generated/progression_rules.json` coincide con lo que genera la herramienta |
| `test_progress_messages` | Ida y vuelta de 0x50–0x55, SPAWN con apariencia y LEVEL_UP; null con cada malformación; ninguno pasa de 1200 B; DEBUG 40–43 |
| `test_player_progress`, `test_progress_service` | Kit de inicio; reposición; consumo; recompensas por méritos, PNJ y captura; agregación de apuntes; forma del guardado; alta que espera al registro (plazo de 10 s); `LEASE_LOST` expulsa; el cierre guarda a todos |
| `test_progress_persistence` | Crea, guarda, recarga y compara **campo a campo** (incluidos objetos, saldos, temporizadores pasados por UTC y posición); repetir un `save_id` no cambia nada; S1–S9 rechazan cada caso de `tests/fixtures/progression/`; `FileProgressRepository` sobrevive a reabrir el archivo |
| `test_gm_progress` | Da un objeto, lo revierte y encuentra el CREATE y el DESTROY (y sus apuntes de oro) en el repositorio; segunda reversión rechazada |
| `test_client_inventory`, `test_inventory_window` | Optimista, confirmación, rechazo que devuelve el objeto, deltas del servidor intercalados, plazo de 5 s; arrastrar, dividir y destruir simulados generan la petición correcta |
| `test_appearance_visual` | 100 apariencias aleatorias aplicadas a `HumanoidVisual` sin errores del motor |
| `test_progress_loopback` | Dos clientes por `NetHarness` con `MemoryProgressRepository`: equipar un arma desde la bolsa cambia el modelo del otro (net id en la ranura), la barra y la hoja sin correcciones de predicción; un rechazo devuelve el objeto; desconectar y volver conserva equipo, arma activa, vida y una reutilización de 5 min |
| Go: `TestSave*` | S1–S9 con los fixtures; dos guardados a la vez del mismo personaje (uno gana); dos apuntes a la vez sobre un saldo; repetición idempotente; reconstrucción del saldo; intercambio de ranuras con la restricción diferida; bloques de ids |

**PostgreSQL en esta máquina (comprobado).** Docker está instalado pero sin demonio: las pruebas no
dependen de él. `initdb` no corre como root, así que los binarios de `/usr/lib/postgresql/16/bin` se
lanzan como `postgres` con `setpriv --reuid=postgres --regid=postgres --init-groups` sobre una carpeta
`build/<pid>/pg/` suya, y el servidor escucha solo en un socket Unix (`pg_ctl … -o "-k <carpeta> -p
<puerto> -c listen_addresses= -c fsync=off -c synchronous_commit=off -c full_page_writes=off"`).
Medido: `initdb --no-sync` 0,64 s, arranque 0,12 s, esquema 0,15 s, parada 0,1 s: ~1 s por clúster
desechable. En CI (sin root) van sin `setpriv`. Go 1.24 baja los módulos por el proxy (pgx v5.7.1
comprobado). El arnés es de plataforma.md.

## 16. Riesgos

- **Dos validaciones** (GDScript y Go) pueden divergir: las fija la misma colección de casos.
- **Precisión de JSON**: un id de 64 bits como número se corrompe sin avisar; las pruebas de
  `CharacterRecord` usan ids por encima de 2^53.
- **Net ids alfabéticos**: añadir un objeto cambia los de los demás; la huella del `sim_hash` impide
  mezclar clientes y servidores con catálogos distintos, y la BD nunca guarda net ids.
- **Reutilizaciones de menos de 30 s**: reconectar las reinicia. Lo limita el tiempo de reconexión y,
  en combate, el cuerpo que se queda 15 s (GUE-41); se revisa con la telemetría.
- **Encaje con habilidades.md**: `EquipmentState.rebuild_from`, el bloque de equipo del SPAWN, las
  plantillas, las pociones y los `apply_cooldown`/`apply_effect` dependen de cómo quede la fase 4. Si
  sus nombres cambian, se ajusta §1, §4.1, §7.3 y §8 al integrar.
- **Volumen del guardado**: unos 40 objetos y 5 apuntes por minuto y jugador (~6 KB de JSON por
  guardado); con 1000 jugadores, ~100 KB/s hacia el servicio. Se mide en TEC-25.
