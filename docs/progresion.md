# Eldmark · Fase 5: diseño de la progresión

Diseño de lo que se guarda de un personaje y de lo que se juega con ello en el paso 5 de la
[hoja de ruta](vision.md#hoja-de-ruta): objetos (PRG-02), qué se guarda y sus invariantes (PRG-10),
inventario autoritativo (PRG-11), monedas y libro mayor (PRG-12), niveles (PRG-13), razas (PRG-14),
herramientas de GM (PRG-16), configuración de combate persistente (CMB-30), apariencia (ART-19) y la
ventana de inventario y personaje (UI-26).

Versión 2: la 1 tras la revisión de tres revisores (§18). Lo marcado «comprobado» sale de sondas en
esta máquina (Godot 4.7.2 headless, PostgreSQL 16, Go 1.24) que no se suben.

Se apoya en [red.md](red.md), [combate.md](combate.md), [fuerte.md](fuerte.md), [social.md](social.md)
y `docs/habilidades.md` (fase 4, ya fusionado en `fase4-fuerte`). Con **`docs/plataforma.md`**
(TEC-22 a TEC-28), escrito a la vez, el reparto es este:

- **plataforma.md**: servicio, cuentas, billete, reclamación, arrendamiento, `CharacterSaver` (cuándo y
  cómo se guarda), posición, vida, tiempo jugado, purgas y RGPD.
- **Este documento**: qué va en la sección `progress` del guardado, sus invariantes, su almacén en Go
  (`platform/internal/progress/`, migraciones 0010 en adelante, paquete P7) y lo que se juega con ello.
  Lo que pide a plataforma.md está en la [sección 13](#13-interfaz-con-plataformamd).
- **habilidades.md**: armas en `CombatState`, evento LOADOUT, `set_loadout`, `set_charges`, plantillas y
  pociones. Este documento añade `ActionMachine.set_weapons` (§4.1) y cambia la recarga del campamento
  para quien tiene inventario (§4.4).

## 0. Decisiones

Provisionales, **tomadas de noche** (revisar), igual que todas las cifras del documento (curva,
recompensas, topes). Las de la recomendación del backlog y las que deja la revisión están en
«Decisiones tomadas» de [backlog.md](backlog.md) con esa marca.

| Pregunta | Decisión |
|---|---|
| ¿Qué razas tiene cada reino? | **Un pueblo humano por reino, solo estético**: peinados, barbas, marcas y corte de los trajes. Mismo esqueleto, misma cápsula, ninguna estadística racial (§7). La piel usa la paleta completa en los tres reinos |
| ¿Inventario por ranuras o por peso? | **Ranuras en la bolsa** (30, ampliables) y **peso solo en el equipo puesto**, cuando lleguen las armaduras (PRG-06) |
| ¿Monedas y banco por personaje o por cuenta? | **Por personaje** (§5) |
| ¿Méritos gastables y puntos de reino separados? | **Dos contadores con el mismo evento**: méritos gastables (moneda) y puntos de reino que nunca bajan (fuerte.md §0) |
| ¿Quién recibe XP y crédito sin selección de objetivo? | **Contribución**: todo el que hace ≥ 10 % del daño en los últimos 900 ticks (`DamageLedger`, GUE-05), con recompensa personal (§6) |
| ¿Cambia el nivel las estadísticas en la fase 5? | **No.** La hoja base es la misma a cualquier nivel hasta que la zona PvE (PRG-22) y la normalización de Eldrun (PRG-31) lo activen. El Vado Gris es la única zona y es RvR |
| ¿Qué equipo hay en la fase 5? | **Las dos armas y las pociones.** Armaduras, `StatBlock` y hoja derivada esperan a PRG-01 y PRG-06, como en habilidades.md §9. Las ranuras de equipo 2–6 existen y quedan reservadas. *Provisional, tomada de noche* |
| Unidad del oro | Un solo entero, «oro», sin plata ni cobre |
| ¿Se equipa en combate? | No: equipar y desequipar solo fuera de combate y sin acción en curso. El cambio entre las dos armas (Q, CMB-24) sí vale en combate |
| Plantillas de la fase 4 (PRG-07) | Se convierten en el **kit de inicio** (§2.5). La plantilla se elige en la **primera entrada** con LOADOUT_SELECT (habilidades.md §5.1), no al crear el personaje: la creación de plataforma.md no cambia |
| Pociones (PRG-08) | Objetos apilables y ligados. Las cargas de `CombatState` son las pociones de la bolsa (tope 15). El campamento repone el **total** a 3 de vida y 2 de resistencia, las cargas del escudero (§4.4) |
| ¿De quién es CMB-30? ¿Corre el tiempo sin conexión? | **De este documento** (§8). **Sí**: las reutilizaciones largas se guardan con su fin en UTC. En la fase 5 solo `/atascado` llega a 30 s. *Provisional, tomada de noche* |
| Carga, guardado e idempotencia | **Los de plataforma.md**: el progreso es la sección `progress` de `CharacterSaver`, llega en la reclamación antes del WELCOME y cada guardado se aplica una vez por `(lease_id, seq)` (§9) |
| Posición y vida | Las guarda y restaura plataforma.md §7.1. En el Vado Gris, zona de guerra, se vuelve al campamento del reino |
| Enteros en JSON | **Números**, con todo id por debajo de 2^53. Comprobado en Godot 4.7.2: `JSON.stringify` escribe un int64 exacto y `JSON.parse_string` devuelve `float` (lee 2^53 + 1 como 2^53). Todos los ids salen de secuencias y bloques que empiezan en 1 |
| Sin plataforma | **Nada se guarda.** Todo personaje es efímero, con inventario en memoria. No hay modo de archivo local. *Provisional, tomada de noche* |

Siguen **pendientes** (fase 6) y el modelo admite cualquier respuesta: reglas de ligado (el campo
existe; los objetos de inicio van ligados), penalización por morir (la durabilidad existe y no baja en
la fase 5), formato de los datos de diseño (en la fase 5, `.tres` a mano) y nivel en Eldrun.
`vision.md` («Por definir: razas») se actualiza al integrar.

## 1. Qué es de quién

| Pieza | La decide | Dónde |
|---|---|---|
| Contenido de la sección `progress`, invariantes, objetos, inventario, libro, niveles, apariencia, CMB-30 | Este documento | §2–§12 |
| Almacén en Go del progreso: migraciones 0010+, comprobaciones, retención del libro, rutas de operación y libro | Este documento (P7) | §3.3, §3.5, §13 |
| Servicio, billete, reclamación, arrendamiento, `CharacterSaver`, cadencia, críticos, posición, vida, tiempo jugado, purgas, exportación | plataforma.md | Sus §5–§7 y §11 |
| Identidad, nombre, raza y apariencia guardadas (`characters`) | plataforma.md, con las reglas exportadas de aquí | §7, §13 |
| Roles, auditoría, sanciones | plataforma.md y social.md | SOC-13, SOC-14, SOC-18 |
| Armas en `CombatState`, LOADOUT, `set_loadout`, `set_charges`, plantillas, pociones, recarga | habilidades.md (H1a–H3c) | Para quien tiene inventario, §4.1 y §4.4 |
| Armaduras, `StatBlock`, hoja derivada, ids visuales por ranura | PRG-01, PRG-05, PRG-06 y el resto de PRG-04: después de la fase 5, sin diseño | §4.1, §7.3 |
| Méritos: reparto y antifarmeo | PRG-09 | Aquí solo se filtran y se apuntan (§6.2) |
| Estadísticas PvP; atributos, maestrías, habilidades elegidas, rareza y afijos | plataforma.md (GUE-19); fase 6 (PRG-17 a PRG-20) | Los campos de objeto ya existen (§2); sus tablas llegan con sus entradas |

**Qué se juega en la fase 5.** El jugador entra con su cuenta (UI-22) y crea un personaje (reino,
apariencia de su pueblo y nombre; UI-24). En su primera entrada elige plantilla y aparece en el Vado
Gris con su kit. Pelea como en la fase 4 y gana méritos, puntos de reino, XP y algo de oro de los
Huecos, el capitán y las capturas. Sube de nivel (1–40), ordena la bolsa, cambia de arma fuera de
combate y bebe las pociones de su bolsa, que repone en el campamento. Al volver encuentra sus armas, sus
monedas, su nivel, su vida y la reutilización de `/atascado`. En el Vado Gris reaparece en el
campamento de su reino.

## 2. Objetos (PRG-02)

### 2.1 Definición y instancia

Una **definición** es lo que un objeto es (datos de diseño en `data/items/<categoría>/<id>.tres`, en
el repo, con un `id` estable). Una **instancia** es un objeto concreto que alguien posee (una fila de
`item_instances`, con un `uid` único en todo el mundo y para siempre).

**`ItemDefinition`** (`scripts/shared/progression/item_definition.gd`, `Resource`):

| Campo | Tipo | Regla |
|---|---|---|
| `id` | `StringName` | `[a-z0-9_]`, 3–32 caracteres, único, nunca se reutiliza ni se renombra (la BD lo guarda) |
| `display_name`, `description` | `String` | Español; el nombre no vacío |
| `category` | `Category` | `WEAPON = 1`, `ARMOR = 2`, `CONSUMABLE = 3`, `MATERIAL = 4`, `QUEST = 5`, `MISC = 6` |
| `equip_slot` | `EquipSlot` | `NONE = 0`, `WEAPON = 1` (vale para las dos ranuras de arma), `HEAD = 2`, `CHEST = 3`, `HANDS = 4`, `LEGS = 5`, `FEET = 6` |
| `ref_id` | `StringName` | WEAPON → `WeaponDefinition.id` de `CombatCatalog`; ARMOR → la armadura de PRG-06 (sin contenido en la fase 5); CONSUMABLE → el id del consumible en `CombatCatalog` (`potion_health`, `potion_stamina`); resto, vacío |
| `max_stack` | `int` | 1 = no apilable; tope 999. Equipables y objetos con durabilidad: 1 |
| `required_level` | `int` | 1–40 |
| `base_value` | `int` | Oro; ≥ 0. Base de los precios de la fase 6 |
| `bind_rule` | `BindRule` | `NONE = 0`, `ON_EQUIP = 1`, `ON_PICKUP = 2` |
| `destroyable` | `bool` | false: el jugador no puede destruirlo |
| `has_durability` | `bool` | La instancia lleva durabilidad (por mil) |
| `starter` | `bool` | Objeto de inicio (§2.5) |
| `camp_refill` | `int` | Total al que el campamento repone esa definición; 0 = no se repone (§4.4) |
| `icon_path` | `String` | `res://assets/icons/items/…`; solo cliente. Vacío: el casillero pinta el nombre corto con el color de la categoría |
| `visual_paths` | `PackedStringArray` | Escena por cuerpo para las armaduras (PRG-05); solo cliente. Vacío en la fase 5: las armas se ven por su id de `CombatCatalog` (habilidades.md) |

Coherencia que exige la prueba: WEAPON ⇒ `equip_slot = WEAPON` y `ref_id` en `CombatCatalog`;
ARMOR ⇒ `equip_slot` de HEAD a FEET; CONSUMABLE ⇒ `equip_slot = NONE` y `ref_id` en los consumibles de
`CombatCatalog`; equipable ⇒ `max_stack = 1`. `data/items/` no tiene armaduras en la fase 5: la regla de
ARMOR se prueba con `tests/fixtures/items/`. `ItemDefinition` no tiene ninguna propiedad de tipo
`Texture2D`, `PackedScene` ni `Mesh`: el preset del servidor recorta `assets/` (TEC-12) y el servidor
nunca debe intentar cargarlo.

**A otro cliente nunca viaja el net id de un objeto.** Lo que se ve de otro jugador sale de su
`CombatState` (las armas, públicas desde habilidades.md §5.2). Las armaduras visibles de PRG-05 y PRG-06
llevarán un id visual propio (`ItemDefinition.visual_id`, de un catálogo visual de solo añadir), que no
deja deducir nivel, rareza ni estadísticas.

**`ItemInstance`** (`scripts/shared/progression/item_instance.gd`, `RefCounted`):

| Campo | Tipo | Regla |
|---|---|---|
| `uid` | `int` | 1 … 2^53 − 1. Lo da el `IdAllocator` de la zona (§4.5) |
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
  solo viaja por el cable hacia el dueño y nunca se guarda.
- **Huella.** `wire_hash()`: u32 del SHA-256 de la lista ordenada `(id, net_id, category,
  equip_slot, max_stack, has_durability)`. Entra en `NetProtocol.compute_sim_hash` (§12): un cliente
  con otro catálogo recibe REJECT SIM_HASH. Tope: 65 535 definiciones (u16).
- **Búsquedas.** `for_ref(category, ref_id)`: el objeto de ese arma o consumible (en la fase 5 hay uno
  por `ref_id`). `consumable_definition(index)`: el objeto del consumible `index` de
  `CombatCatalog.consumable_ids()` (0 vida, R; 1 resistencia, T).

### 2.3 Formato binario (`ItemInstance.encode()`, versión 1)

Un solo formato para la red y las pruebas; la BD guarda columnas (§3), no este blob.

| Offset | Tipo | Campo | Notas |
|---|---|---|---|
| 0 | u8 | format | 1. Otro valor: `decode` devuelve null |
| 1 | u64 | uid | 1 … 2^53 − 1 |
| 9 | u16 | def | net id (≥ 1) |
| 11 | u16 | count | 1 … `max_stack` |
| 13 | u16 | durability | 0–1000; `0xFFFF` = sin durabilidad |
| 15 | u8 | rarity | 0–4 |
| 16 | u8 | flags | bit0 ligado; el resto a 0 |
| 17 | u32 | seed | |
| 21 | u8 | affix_count | 0–6 |
| 22 | n × u16 | affixes | |

Tamaño: 22 + 2·n B (22–34). `decode(bytes, offset)` devuelve null si falta algún byte, el formato no
es 1, el uid es 0 o llega a 2^53, el net id no existe, la cantidad es 0 o pasa de `max_stack`, la
durabilidad no cuadra con `has_durability`, la rareza pasa de 4, hay bits de flags desconocidos o más
de 6 afijos. Nunca registra errores del motor (red.md §5.7).

### 2.4 Contenido inicial (fase 5)

Un objeto por arma y por poción de la fase 4. Todos llevan `starter = true`, `bind_rule = ON_PICKUP`,
`required_level = 1` y `base_value = 0`:

| Objetos | Categoría | Pila | Notas |
|---|---|---|---|
| `sword_shield_vado` (espada y escudo), `bow_vado` (arco) | WEAPON | 1 | `ref_id` = el arma de `CombatCatalog`; sin durabilidad; `destroyable = false` (en la fase 5 no hay otra forma de conseguirlas) |
| `potion_health`, `potion_stamina` | CONSUMABLE | 15 | `ref_id` = el consumible; `camp_refill` 3 y 2 |

### 2.5 Kit de inicio y plantillas

En la **primera entrada** al mundo (`starter_granted = false`), al dar de alta al personaje, la zona
crea el kit en una sola operación STARTER_KIT y marca el guardado como crítico. La plantilla es
`ServerPeer.pending_template_id` (la que mandó LOADOUT_SELECT antes de CLIENT_READY; habilidades.md
§4.6) o, si no hay, `default_template`:

1. Cada arma de la plantilla → su objeto (`ItemDatabase.for_ref`), puesto en las ranuras de equipo 0 y
   1 por el orden de la plantilla.
2. Cada objeto de inicio sin `camp_refill` que no haya quedado puesto (las armas de las demás
   plantillas) → una unidad en la bolsa, desde la ranura 0 por orden de `id`.
3. Cada objeto con `camp_refill > 0` → una pila con esa cantidad en la bolsa.

Así se conserva la libertad de la fase 4 (cambiar de estilo) dentro del inventario. Se guardan
`starter_template_id` (solo informativo) y `starter_granted = true`. Una plantilla desconocida usa la
primera por orden de `id`, con aviso en el registro.

Después de la primera entrada, para quien tiene inventario el servidor **ignora** LOADOUT_SELECT (sin
aviso) y la reaparición toma las armas de su equipo, no de la plantilla. El cliente oculta entonces el
selector de la pantalla de muerte. Los **jugadores falsos** (`--fake-players`) no tienen inventario:
siguen con su plantilla y la recarga de habilidades.md.

## 3. El personaje que se guarda (PRG-10)

### 3.1 Qué se guarda (un dueño por campo)

| Grupo | Campos | Dónde | Dueño |
|---|---|---|---|
| Identidad | `character_id`, `account_id`, `world_id`, `realm`, `name`, `name_key`, fechas, borrado con gracia, renombrado obligatorio | `characters` | plataforma.md |
| Raza y apariencia | `race_id`, `appearance` (8 B exactos, §7.2) | `characters` | plataforma.md las guarda al crear; las reglas son de aquí (§7, §13) |
| Posición, giro, vida, tiempo jugado | `state.zone_id`, `state.position`, `state.yaw`, `state.health`, `state.played_s` | `characters.state` | plataforma.md §7.1 (`played_s` también para SOC-38) |
| Nivel | `level` | `character_progress`; copia en `characters.level` para la lista (UI-23), que escribe P7 | Este documento |
| Progreso | `xp_total`, `realm_points`, `bag_slots`, `starter_template_id`, `starter_granted` | `character_progress` | Este documento |
| Inventario | Una fila por instancia | `item_instances` | Este documento |
| Monedas | Saldo por moneda y el libro mayor | `character_wallets`, `ledger_entries` | Este documento |
| Combate (CMB-30) | `active_weapon_slot` y temporizadores largos | `character_progress`, `character_timers` | Este documento (§8) |
| PvP | Totales | `character_pvp_stats` | plataforma.md (GUE-19) |

No se guardan las habilidades elegidas (en la fase 5 son el kit fijo del arma, habilidades.md §2.3) ni
las cargas de pociones (son las pociones de la bolsa, §4.4).

### 3.2 Invariantes

Los comprueban la zona al aplicar y el servicio al guardar (§13.3, S1–S8).

| # | Invariante |
|---|---|
| I1 | Un `uid` identifica una sola instancia en todo el mundo y nunca se reutiliza, ni tras destruirla (la fila retirada se queda) |
| I2 | Una instancia viva está en un solo sitio: `(character_id, container, slot)` es único. En la fase 5 no hay objetos sin dueño |
| I3 | `1 ≤ count ≤ max_stack ≤ 999` |
| I4 | **Conservación.** La cantidad total de una definición solo cambia con un evento de objeto (fuente, sumidero, reversión o migración, §5.3). Mover, dividir, juntar, intercambiar y equipar no la cambian y no dejan eventos |
| I5 | `0 ≤ saldo ≤ tope` de su moneda y `saldo = Σ delta` de sus apuntes |
| I6 | Los apuntes y los eventos de objeto son inmutables; cada uno pertenece a una operación, y `(op_id, character_id)` se aplica una sola vez |
| I7 | Una operación es atómica y nunca se parte entre dos guardados |
| I8 | `level = curva.level_for(xp_total)`, entre 1 y 40; en el tope no se acumula XP; `xp_total` solo baja con una operación GM o REVERSAL |
| I9 | `realm_points` sube con cada apunte de méritos de motivo 3–5 (juego) y por la misma cantidad; solo baja al revertir esos apuntes |
| I10 | En EQUIPMENT solo hay armas, en las ranuras 0 y 1, y la ranura activa tiene un arma |
| I11 | La apariencia es válida para su raza y la raza es del reino del personaje |
| I12 | `starter_granted` nunca vuelve a false; `bound` nunca pasa de true a false; `bag_slots` no cambia en la fase 5 |
| I13 | Un guardado se aplica una vez: idempotencia por `(lease_id, seq)` de plataforma.md §7.3 |

### 3.3 Esquema (migración `0010_progress`)

Todas las tablas llevan `world_id`. Las de **estado** cuelgan de `characters` con `on delete cascade`.
Las de **solo añadir** no tienen clave ajena hacia `characters`: `character_id` queda como seudónimo y
se borran por retención (§3.5), como el `audit_log` de plataforma.md. Comprobado en PostgreSQL 16 con
una sonda en `build/`: restricciones, disparador, operación de dos personajes, uid retirado que no se
reutiliza, intercambio de ranuras con la restricción diferida, purga del personaje con libro dentro de
la transacción de la lápida de la cuenta y retención a un año.

| Tabla | Columnas | Claves y restricciones |
|---|---|---|
| `character_progress` | `character_id`, `world_id`, `level smallint` (1–40), `xp_total bigint`, `realm_points bigint`, `bag_slots smallint` (1–120, 30), `starter_template_id text`, `starter_granted bool` (false), `active_weapon_slot smallint` (0–1), `updated_at` | PK `character_id`, FK a `characters` en cascada; contadores ≥ 0 |
| `character_wallets` | `character_id`, `world_id`, `currency smallint` (1 oro, 2 méritos), `balance bigint`, `last_seq bigint` | PK (`character_id`, `currency`), FK en cascada; CHECK `balance BETWEEN 0 AND 1000000000` |
| `item_instances` | `uid`, `world_id`, `character_id`, `container smallint` (0–3), `slot smallint` (0–119), `def_id text`, `count int` (1–999), `durability smallint` (0–1000; NULL = sin), `rarity smallint` (0–4), `bound bool`, `seed bigint` (0 … 2^32 − 1), `affixes integer[]` (≤ 6, cada uno 0–65535), `created_op bigint` (NULL = nació al dividir), `retired_at timestamptz` | PK `uid` (CHECK > 0), FK en cascada; CHECK `(retired_at IS NULL) = (container IS NOT NULL AND slot IS NOT NULL)`; UNIQUE (`character_id`, `container`, `slot`) **DEFERRABLE INITIALLY DEFERRED**; índice por `character_id` de las vivas |
| `character_timers` | `character_id`, `world_id`, `key text` (`^[a-z0-9_:]{1,48}$`), `ends_at timestamptz` | PK (`character_id`, `key`), FK en cascada (§8) |
| `economy_ops` | `op_id`, `world_id`, `kind smallint` (§5.3), `actor_account_id` (NULL salvo GM), `ref_op_id` (la revertida), `zone_id text`, `note text` (≤ 200), `detail jsonb`, `created_at` | PK `op_id` (CHECK > 0); CHECK: `kind` GM o REVERSAL ⇒ `note` no vacía. **Solo añadir** |
| `op_participants` | `op_id`, `character_id`, `world_id` | PK (`op_id`, `character_id`); FK `op_id`; índice por `character_id`. **Solo añadir** |
| `ledger_entries` | `entry_id` (identidad), `world_id`, `character_id`, `currency`, `seq bigint`, `op_id`, `delta bigint`, `balance_after bigint`, `reason smallint`, `ref_kind smallint`, `ref_id bigint`, `created_at` | UNIQUE (`character_id`, `currency`, `seq`); FK (`op_id`, `character_id`) a `op_participants`; CHECK `delta <> 0`, `balance_after` 0 … tope; índice (`character_id`, `entry_id` desc). **Solo añadir** |
| `item_events` | `event_id` (identidad), `world_id`, `op_id`, `character_id`, `def_id`, `uid bigint` (NULL = agregado), `reason smallint`, `count_delta int`, `created_at` | FK (`op_id`, `character_id`) a `op_participants`; CHECK `count_delta <> 0`; índice (`character_id`, `op_id`). **Solo añadir** |
| `op_reversals` | `op_id`, `reversal_op_id`, `world_id` | PK `op_id`; UNIQUE `reversal_op_id`; las dos, FK a `economy_ops`: una operación se revierte una vez. **Solo añadir** |
| `progress_tombstones` | `character_id`, `world_id`, `purged_at` | PK `character_id` (§3.5) |

`container`: 0 BAG, 1 EQUIPMENT, 2 BANK (PRG-25), 3 reservado; en la fase 5 solo 0 y 1. La restricción
de ranura es diferida para que un intercambio quepa en una transacción. Un `uid` que muere (destruido
o juntado con otro) no se borra: su fila queda **retirada** (`retired_at`, sin contenedor ni ranura) y la
clave primaria impide reutilizarlo. Las operaciones son de varios personajes desde ya
(`op_participants`): el comercio de la fase 6 guarda una sola operación con los dos.

El disparador de las cinco tablas de solo añadir (`economy_ops`, `op_participants`, `ledger_entries`,
`item_events`, `op_reversals`), tal como se probó:

```sql
create function eldmark_append_only() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' and current_setting('eldmark.retention_purge', true) = 'on' then
    return old;
  end if;
  raise exception '% es de solo añadir', tg_table_name using errcode = 'P0001';
end $$;
create trigger append_only before update or delete on ledger_entries
  for each row execute function eldmark_append_only();   -- y lo mismo en las otras cuatro
```

`0010_progress.down.sql` quita disparadores, función y tablas en orden inverso. Las tablas de
atributos (PRG-17), maestrías (PRG-18) y habilidades elegidas (PRG-19) llegan con sus entradas, en
migraciones propias de la franja 0010–0029.

### 3.4 `ProgressRecord` en JSON (`progress_format` 1)

Es la sección `progress` de la reclamación (`CharacterRecord.progress`, plataforma.md §6) y la parte
fija de cada guardado (§9.3). `{}` es un personaje nuevo: lo da el `jsonProgressStore` provisional de
plataforma.md tras crear; el almacén de P7 devuelve el registro con los valores por defecto. Todo número
que no sea una cantidad pequeña (`uid`, `op_id`, `actor_account_id`, `ref_op_id`, `ref_id`, `seed`,
`ends_at_unix`) tiene que ser un entero exacto entre 0 y 2^53 − 1 (`v == floor(v)`; los ids, desde 1);
si no, la zona rechaza el registro.

```json
{"progress_format": 1, "level": 7, "xp_total": 12345, "realm_points": 420, "bag_slots": 30,
 "starter_template_id": "squire", "starter_granted": true, "active_weapon_slot": 0,
 "wallets": [{"currency": 1, "balance": 150}, {"currency": 2, "balance": 3200}],
 "items": [{"uid": 1025, "def_id": "sword_shield_vado", "container": 1, "slot": 0, "count": 1,
            "durability": null, "rarity": 0, "bound": true, "seed": 0, "affixes": []},
           {"uid": 1027, "def_id": "potion_health", "container": 0, "slot": 1, "count": 3,
            "durability": null, "rarity": 0, "bound": true, "seed": 0, "affixes": []}],
 "timers": [{"key": "unstuck", "ends_at_unix": 1793282700}]}
```

`items` son las instancias vivas. Los temporizadores van en segundos Unix. `from_dictionary` ignora
`zone_id` y `ops` (el `jsonProgressStore` guarda el cuerpo del guardado entero) y devuelve null ante
cualquier otra clave desconocida, un tipo que no cuadra o un valor fuera de rango. Nivel y `xp_total`
deben cumplir I8; la apariencia y la raza vienen aparte, en `CharacterRecord`.

### 3.5 Retención y purga

| Qué | Cuánto | Cómo |
|---|---|---|
| Estado: progreso, saldos, objetos (vivos y retirados), temporizadores | Mientras exista la fila de `characters` | `on delete cascade` |
| Operaciones, participantes, libro, eventos de objeto, reversiones | Mientras exista el personaje y **1 año** después de su purga (PRG-39) | Lápida y trabajo de retención |

- **Purga.** La purga de plataforma.md (personaje al vencer `restore_until`, cuenta en §11.2) llama a
  `ProgressStore.Purge` dentro de su transacción y antes de borrar la fila de `characters`. `Purge`
  inserta la lápida (`progress_tombstones`). El borrado en cascada solo toca las tablas de estado: el
  libro se queda y la transacción de la cuenta no se aborta (comprobado: personaje borrado, correo a
  NULL, 2 apuntes y 1 evento intactos).
- **Retención.** El trabajo horario de plataforma.md §2.5 llama a `ProgressStore.PurgeRetention` con
  una transacción suya. Dentro, `set local eldmark.retention_purge = 'on'` y borra, de las lápidas con
  más de 365 días, sus apuntes, eventos y participaciones; después, las reversiones y operaciones que se
  han quedado sin participantes, y las lápidas ya vacías. Como mucho 10 000 apuntes por llamada: el
  trabajo la repite, una transacción cada vez, mientras devuelva más de 0.
- **Sin la marca**, UPDATE y DELETE fallan siempre (también tras una transacción que la puso: `set
  local` solo vale dentro de ella, comprobado). Corregir datos es añadir apuntes de MIGRATION; una
  migración que tuviera que borrar pone la misma marca y se revisa a mano.
- **Seudónimos.** Tras la purga, `character_id` y los `ref_id` de víctimas apuntan a filas que ya no
  existen y la cuenta es una lápida: no se reescriben (sería un UPDATE en una tabla de solo añadir).
- **Exportación.** `ProgressStore.Export` da el progreso y las operaciones, apuntes y eventos propios
  para el archivo de plataforma.md §11.2.

## 4. Inventario autoritativo (PRG-11)

### 4.1 Contenedores y ranuras

| Contenedor | Ranuras | Reglas |
|---|---|---|
| 0 BAG | `bag_slots` (30; tope 120) | Cualquier objeto; las pilas se juntan |
| 1 EQUIPMENT | 7: 0 WEAPON_1, 1 WEAPON_2; 2 HEAD, 3 CHEST, 4 HANDS, 5 LEGS, 6 FEET reservadas | Un arma por ranura; en la fase 5 las ranuras 2–6 dan CANNOT_EQUIP |

El equipo puesto **es** el contenedor EQUIPMENT. Tras cada cambio confirmado de las ranuras 0 o 1, la
zona impone las armas en el `CombatState`:

```gdscript
# scripts/shared/combat/action_machine.gd (amplía habilidades.md §7.2; lo añade P2)
## Pone las armas de las dos ranuras sin reiniciar nada más. Solo con action NONE: si no, no hace nada
## y registra el error (el inventario nunca la llama entonces: NOT_NOW de §4.2).
static func set_weapons(c: CombatState, weapon_1: int, weapon_2: int, second_active: bool,
		ready_1: PackedInt64Array, ready_2: PackedInt64Array) -> void
```

- Pone `weapon_id` y `alt_weapon_id` según `second_active`, `ability_ready[0..2]` con las del arma
  activa y `[3..5]` con las de la otra, y el bit0 de `combat_flags2` = `second_active`.
- No toca `consumable_ready_tick`, las cargas, las ranuras de movimiento ni los botones.
- Los `ready_*` son ticks absolutos de cada arma (3 valores; vacío = 0). `PlayerProgress` guarda en
  memoria los de un arma que se quita (`stash_ready`) y los devuelve al volver a ponerla: desequipar y
  equipar no reinicia reutilizaciones. Al aparecer y al reaparecer van vacíos, como en `set_loadout`.
- Le siguen `CombatDirector.commit_state` y LOADOUT (habilidades.md §5.4, `template_id` 0 = el equipo
  del inventario) al dueño y, si cambian las armas, a quien lo tenga relevante (con `charges` 0).
- Se aplica al final del tick `s`, con las altas; la simulación lo usa desde `s + 1`. La corrección del
  dueño la explica el LOADOUT propio (`NetClient._note_imposed_state`, habilidades.md §5.4).

Con la ranura 0 vacía y la 1 activa, `weapon_id` es la de la 1 y `alt_weapon_id` 0 (no hay SWAP).

### 4.2 Operaciones

Todas son intenciones del cliente que el servidor valida y aplica enteras o no aplica.

| Op | Código | Efecto |
|---|---|---|
| MOVE | 1 | A una ranura vacía: mueve la pila. A una pila de la misma definición apilable, con el mismo `bound` y hueco: **junta** `min(count, max − destino)` y lo que no cabe se queda. En cualquier otro caso (otra definición, otro `bound` o pila de destino llena): **intercambia**. Hacia o desde EQUIPMENT es **equipar** o desequipar |
| SPLIT | 2 | Saca `n` (1 ≤ n < count) a una ranura vacía de la bolsa, con `uid` nuevo |
| DESTROY | 3 | Quita `n` (0 = toda la pila); si no queda nada, el `uid` muere |

Al equipar un objeto con `ON_EQUIP` se liga (`bound = true`) y el cambio viaja en el delta.

**Validación, en este orden; el primer fallo da el código:**

| Código | Nombre | Cuándo | Texto (`result_text`) |
|---|---|---|---|
| 0 | OK | Aplicada | — |
| 1 | INVALID | Op desconocida, contenedor o ranura fuera de rango (contenedores 2 y 3 en la fase 5), cantidad imposible (MOVE con `count ≠ 0`, SPLIT fuera de 1..count−1 o a una ranura que no es de la bolsa), origen igual a destino. **Suma un aviso** (red.md §12) | «Petición no válida» |
| 2 | STALE | El origen está vacío o su `uid` no es `expected_uid` | «Ese objeto ya no está ahí» |
| 3 | NOT_NOW | Sin personaje o fuera del mundo. La op toca EQUIPMENT y el personaje está muerto, derribado, en combate (`Combatant.is_in_combat`) o con una acción (`CombatState.action ≠ NONE`: beber, cambiar de arma, levantar y rematar incluidos). DESTROY de un consumible mientras bebe uno (si no, el compromiso restaría una carga de 0). SPLIT o DESTROY sin ids para clientes (§4.5) | «Ahora no puedes hacerlo»; en combate, «No puedes cambiar el equipo en combate» |
| 4 | CANNOT_EQUIP | Ranura de equipo incompatible, ranura 2–6 en la fase 5 o `required_level` por encima del nivel | «No puedes equipar eso ahí» o «Necesitas nivel N» |
| 5 | WEAPON_REQUIRED | Dejaría vacía la ranura de arma activa | «Necesitas un arma en la mano» |
| 6 | NO_ROOM | SPLIT a una ranura ocupada | «No cabe» |
| 7 | LOCKED | DESTROY de algo equipado o de un objeto con `destroyable = false` | «Ese objeto no se puede destruir» |
| 8 | RATE | Se mira al llegar, antes que todo lo demás: más de 8 peticiones/s (ráfaga 16), o más de 2 SPLIT y DESTROY por segundo (ráfaga 10; gastan ids). Pasadas las diez primeras descartadas de cada 10 s, cada una suma un aviso, como el chat (social.md §5) | «Más despacio» |

`InventoryOps.apply()` es **compartida y pura**: la usa el servidor para decidir y el cliente para su
intención optimista (§11), así que las dos validan igual. El servidor encola las peticiones al llegar
(en el `poll`) y las aplica al final del tick `s`, tras las altas (red.md §8.1), en orden de llegada.

### 4.3 Transaccional en memoria y en la BD

- `InventoryOps.apply()` calcula el resultado sobre una copia de las ranuras implicadas y solo si todo
  vale lo escribe en el `InventoryState`.
- **Mover, dividir, juntar, intercambiar y equipar no crean eventos ni gastan `op_id`**: su resultado
  va en la foto del guardado. SPLIT gasta un `uid`. Solo DESTROY (sumidero) da un evento, en una
  operación PLAYER.
- El diario de `PlayerProgress` guarda las operaciones con eventos o apuntes que aún no ha confirmado
  un guardado. Cada guardado manda la foto completa y ese diario, y el servicio lo aplica en **una**
  transacción (I7).
- `kill -9`, SIGTERM o SIGINT (no llegan a GDScript, red.md §1.3) pierden lo posterior al último
  guardado aceptado (60 s como mucho, plataforma.md §7.4), y a la vez el cambio y su registro: la BD
  nunca ve uno sin el otro. TEC-25 lo prueba matando el proceso (§15, P8).
- Cada petición aplicada deja una línea en el registro de la zona (personaje, op, ranuras, uids,
  resultado).

### 4.4 Lo que cambia el servidor por su cuenta

| Motivo | Cuándo | Efecto |
|---|---|---|
| `STARTER_KIT` | Primera entrada | §2.5; operación suelta, guardado crítico; luego INVENTORY_FULL |
| `CAMP_REFILL` | Paso 8 del tick (habilidades.md §4.1), cada 60 ticks, si está vivo, fuera de combate y en la zona segura de su reino | Por cada definición con `camp_refill`: `falta = camp_refill − count_of(def)` (bolsa y equipo). Si falta > 0, se suma a la pila de esa definición con la ranura más baja hasta `max_stack` y el resto va a una pila nueva en la primera ranura libre. Bolsa llena: no se repone y llega un NOTICE «Bolsa llena», una vez por entrada en la zona segura. Agregado (§5.2). **Sustituye** la recarga de habilidades.md §4.6 para quien tiene inventario |
| `CONSUME` | Tras el paso 1 (simular), si bajó la carga de un consumible: es el compromiso de beber (habilidades.md §3.3, regla 5) | −1 por carga gastada, de la pila de esa definición con la ranura de bolsa más baja. Beber interrumpido no baja la carga y no gasta nada. Agregado |
| `GM_GRANT`, `GM_REMOVE`, `REVERSAL` | Comandos de §10 | Operación suelta, guardado crítico |

Dividir la pila no da más pociones: la reposición mira el **total** de la definición.

**Cargas.** Para quien tiene inventario, la carga de cada consumible es `min(15, count_of(def))`, con
`def = ItemDatabase.consumable_definition(i)`. Se impone con `ActionMachine.set_charges` (solo toca las
cargas, habilidades.md §3.5) y LOADOUT al dueño en dos momentos:

- tras cada cambio confirmado de la cantidad de un consumible (CONSUME, CAMP_REFILL, DESTROY, GM,
  reversión);
- en el alta y en la reaparición, como el argumento `charges` de `set_loadout` y `reset_for_respawn`.

Con más de 15 en la bolsa, tras beber la carga vuelve a 15 con un LOADOUT. El comando 16 `refill`
(habilidades.md §5.1) es para ellos un CAMP_REFILL forzado, sin mirar zona ni combate. Los jugadores
falsos siguen con la plantilla y la recarga de habilidades.md.

### 4.5 `uid` y `op_id`: bloques

- Con plataforma, un solo generador: `POST /internal/v1/item-uid-blocks {world_id, count: 1024}` →
  `{first, count}` (plataforma.md §6, tabla `item_uid_blocks` por mundo). Del mismo bloque salen los
  `uid` y los `op_id`.
- `IdAllocator` guarda dos bloques como mucho y pide otro cuando quedan menos de 512.
- **Reserva del servidor**: los últimos 256 ids solo los usa el servidor (kit, pila nueva de
  CAMP_REFILL, cierre de la agregación, GM, reversión). Un SPLIT o DESTROY del cliente con 256 o menos
  da NOT_NOW: ningún cliente deja a otro sin beber ni a la zona sin guardar.
- Las operaciones agregadas toman su `op_id` al construir el guardado: beber y reponer nunca esperan a
  un id (salvo la pila nueva, que sale de la reserva).
- **Primer bloque**: la zona lo pide tras registrarse y antes de abrir el puerto, como las fortalezas
  (plataforma.md §8).
- Un bloque a medias que se pierde en una caída deja un hueco: no importa, nunca se repite nada.
- Sin plataforma, `IdAllocator.local()` cuenta desde 1 en memoria (nada se guarda).

### 4.6 Mensajes de red

Canal fiable 3, tipos `0x50`–`0x5F` (el chat usa `0x40`–`0x47` y los grupos `0x48` en adelante).
Ningún mensaje pasa de 1200 B. INVENTORY_DELTA, INVENTORY_FULL, WALLET_UPDATE y PROGRESS_UPDATE solo
van al dueño. `NetClient` los decodifica y emite señales; `SwarmBot` los decodifica y los descarta.
Ninguno de los dos los cuenta como malformados salvo que el `decode` falle (§14.1, P4).

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
- **Puntos de reino**: no son moneda. Suben con cada apunte de méritos de motivo 3–5, en la misma
  operación y por la misma cantidad (I9). Los méritos de GM no los mueven.
- Lo ganado en las pruebas de la fase 5 se puede borrar al abrir la economía de la fase 6: una
  migración con motivo `MIGRATION` deja los saldos a 0 con su apunte.

### 5.2 Apunte

- `op_id`: la operación (§4.5). `(op_id, character_id)` se aplica una vez (I6).
- `currency`, `delta` (≠ 0), `balance_after` (saldo tras el apunte), `reason` (§5.3; su signo debe
  cuadrar con su rango) y `ref_kind`, `ref_id`: 0 ninguna; 1 personaje (víctima PvP: su
  `character_id`); 2 PNJ y 3 fortaleza (la huella u32 de su id de texto, los 4 primeros bytes del
  SHA-256 como el `zone_key` de plataforma.md §5.1: los ids de `NpcCatalog` cambian al añadir PNJ);
  4 operación (la revertida). Ejemplo: `hollow` da 3021413298; `vado_gris`, 0x19efc013, el del vector
  de plataforma.md.
- `seq` (1, 2, 3… por saldo) **lo pone el servicio**: `last_seq + 1` en el orden del diario. La zona no
  lo manda.
- En la operación: `actor_account_id` (la cuenta del GM o null), `note` y `detail` (§10).

**Agregación.** Las ganancias y gastos de juego (méritos, oro de PNJ y capturas, CAMP_REFILL, CONSUME)
cambian el saldo o la bolsa en memoria al momento y se apuntan al construir el guardado. Van en una
operación GAMEPLAY con un apunte por (moneda, motivo, `ref_kind`, `ref_id`) y un evento sin `uid` por
(definición, motivo). Un jugador en batalla deja unos cinco apuntes por minuto, no uno por segundo.

**Orden del diario.** Antes de crear una operación suelta (DESTROY del jugador, kit, GM, reversión),
`PlayerProgress` cierra lo agregado como una GAMEPLAY. Así el diario va siempre en orden de aplicación
y cada `balance_after` sale del saldo ya apuntado. Ejemplo: 100 de oro en la BD, +2 de un PNJ y un
`currency_add +50` → GAMEPLAY (+2, 102) y después GM (+50, 152).

### 5.3 Motivos (`EconomyReason`, u8, fijos: nunca se reutilizan)

Rango 1–63: **fuentes** (`delta > 0`). Rango 64–127: **sumideros** (`delta < 0`). Rango 128–191:
**internos** (cualquier signo).

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
| 12 | MAIL_IN | 6 | 128 | REVERSAL | 5 |
| 13 | CRAFT_OUTPUT | 6 | 129 | MIGRATION | 5 |

Los mismos códigos sirven para los eventos de objeto. Tipos de operación (`economy_ops.kind`,
`EconomyOp.Kind`): 1 PLAYER, 2 GAMEPLAY, 3 STARTER_KIT, 4 GM, 5 REVERSAL, 6 MIGRATION; 7 TRADE y 8 MAIL
(fase 6); 9–15 reservados.

### 5.4 Reglas

- Una operación que dejaría un saldo negativo o por encima del tope no se aplica entera (también en
  memoria: `CurrencyRules.can_apply`). Una ganancia de juego que pasa el tope se recorta al tope.
- **Concurrencia en la zona.** Un personaje vive en una sola zona (arrendamiento, TEC-25) y sus
  operaciones se aplican en orden dentro del tick: no hay carreras.
- **Concurrencia en la BD.** El guardado bloquea el arrendamiento (`for update`, plataforma.md §7.3),
  así que dos guardados del mismo personaje van en serie. Además, cada saldo se escribe con `UPDATE …
  SET balance = balance + delta WHERE … AND balance + delta >= 0`. Comprobado con PostgreSQL 16 y dos
  transacciones a la vez que gastan 60 de un saldo de 100: la segunda espera el bloqueo, vuelve a
  evaluar la condición, no toca ninguna fila y se aborta; el saldo queda en 40 y la suma del libro es 40.
- **Reconstrucción.** `saldo = Σ delta` de sus apuntes; lo comprueba la prueba y, a diario, PRG-30.
- **Idempotencia.** Un reintento repite `(lease_id, seq)` y plataforma.md lo descarta antes de llegar al
  progreso. Una operación repetida en un guardado nuevo choca con la clave de `op_participants`.

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
| Bajas y asistencias PvP | `méritos × 10` | — | Los méritos de PRG-09 (reparto por daño y antifarmeo incluidos). **Solo si la víctima es un personaje persistente de otro reino**; las de PNJ, jugadores falsos y personajes efímeros no dan méritos ni XP de PvP. Sin oro, para que no se compre oro pactando muertes |
| Objetivos | `méritos × 10` | — | Los méritos de objetivo de PRG-09 (círculo, puerta, defensa), sin víctima |
| PNJ | `NpcDefinition.xp_reward` | `NpcDefinition.gold_reward` | Cada contribuyente con ≥ 10 % del daño en 900 ticks recibe la recompensa entera (§0). Sin méritos. Valores: `hollow` 40 XP y 2 de oro; `realm_guard` 60 y 3; `ford_captain` y `realm_captain` 400 y 50; `gate_guardian` 0 y 0 |
| Captura | 300 | 20 | A cada jugador del nuevo dueño que esté en el círculo en el tick de la captura. **Una vez por personaje y fortaleza cada 30 min**: temporizador `capture:<fortress_id>` (§8). Guardado crítico |
| GM | `xp_add` | `currency_add` | §10 |

- `xp_reward` y `gold_reward` son dos campos nuevos de `NpcDefinition`
  (`scripts/shared/ai/npc_definition.gd`, MUN-07), con 0 por defecto, y se rellenan en `data/npcs/`.
- **Con `--platform` y `--fake-players` la zona no da ninguna recompensa persistente** y lo dice en el
  registro al arrancar: los falsos podrían ayudar a capturar o a sostener un círculo.
- La captura sin defensores no se penaliza todavía: en el Vado Gris lo normal es quitársela a los
  Huecos. Las capturas pactadas y el granjeo son de GUE-35 (fase 7).
- El reparto de XP en grupo es de SOC-23 (fase 6).

### 6.3 Subida

- `ProgressionRules.add_xp(curve, level, xp_total, amount)` (pura, compartida) devuelve el nivel,
  el total, los niveles ganados y lo que se aplicó. Un solo aporte puede subir varios niveles. En el
  tope se aplica 0 y el total se queda en `curve.total_to(40)`.
- **Puntos de atributo** = `(level − 1) · attribute_points_per_level − Σ gastados`. No se guardan:
  se derivan, así PRG-17 puede cambiar el reparto sin migrar. En la fase 5 se ven y no se gastan.
- **Qué cambia al subir:** nada de la simulación ni de la hoja (§0). Se ve en la ventana de personaje y
  en la placa de los aliados, y desbloquea objetos por `required_level`.
- **Avisos:** PROGRESS_UPDATE al dueño (§12) y ENTITY_EVENT `16 LEVEL_UP` (`u8 level`, 10 B) al dueño
  y a los del **mismo reino** que lo tienen relevante, para el efecto visual; al enemigo no le llega
  (social.md §1). Subir de nivel marca el guardado como crítico.
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
1,8 m, ninguna estadística; la apariencia no entra en el `sim_hash`. No hay control de altura ni de
complexión: el aspecto debe llenar la misma cápsula que se usa para los golpes, o el rival vería un
cuerpo más pequeño que su hitbox. Cambia lo visual: peinados, barbas, marcas y, con PRG-05 y ART-27, el
corte y el tinte de los trajes. Askarra tiene su raza en los datos aunque su reino aún no se pueda
elegir (plataforma.md §0). Hasta ART-20, las tres razas comparten las piezas que hay en el repo
(§7.4) y solo cambian los colores permitidos.

### 7.2 `CharacterAppearance`: 8 B

Índices sobre `AppearanceCatalog` (`data/characters/appearance_catalog.tres`), que tiene listas
**solo de añadir**: `races`, `bodies`, `heads`, `hairs`, `beards`, `marks` (`AppearancePart`: `id`,
`display_name`, `scene_path: String` solo cliente y `bodies` compatibles, vacío = todos) y
`skin_tones`, `hair_colors`, `eye_colors` (`AppearanceColor`: `id`, `display_name`, `color` y
`texture_path: String`, opcional y solo cliente). El catálogo de la fase 5 **solo lista piezas que
existen** en el repo. `data/characters/appearance_ids.txt` congela el orden («categoría índice id» por
línea), solo crece, y la prueba exige que el catálogo empiece por esa lista: nada se reordena ni se
borra (se retira quitándolo de las razas). Así los 8 B guardados en la BD siguen valiendo tras
cualquier parche.

| Byte | Campo | Valor |
|---|---|---|
| 0 | race | índice en `races` + 1 (0 no vale) |
| 1 | body | índice en `bodies` (en la fase 5 solo hay el 0; el femenino llega con ART-20, §16) |
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
zona al cargarlo: una apariencia inválida en la zona se sustituye por `default_for(raza)` y se registra,
sin echar al jugador.

### 7.3 En el SPAWN

El payload de PLAYER de ENTITY_SPAWN (red.md §5.5) crece **9 B** tras el nombre: `u8 level` y los 8 B de
apariencia. `level` es 0 si el receptor no es del reino del jugador (social.md §1: el nivel del enemigo
no cruza). Por eso el SPAWN se codifica **por reino receptor**:

- `NetEntity.encode_spawn(tick, for_owner, receiver_realm)`; `level` real solo si `for_owner` o
  `receiver_realm == realm`.
- `ZoneServer._announce_arrival` guarda como mucho tres variantes (una por reino) del SPAWN del recién
  llegado y manda a cada `other_peer` la de su reino; los SPAWN de los demás hacia el recién llegado
  usan el reino de este. `_refresh_interest` usa el reino del observador.
- Hoy `_announce_arrival` codifica una sola vez y manda los mismos bytes a todos: P4 cambia los tres
  sitios que llaman a `encode_spawn` y `test_progress_messages` y `test_progress_loopback` lo prueban.

No hay bloque de equipo: las armas ya van en el `PlayerState` público (`weapon_id`, `alt_weapon_id`,
habilidades.md §5.2) y cambian con LOADOUT. El `decode` solo comprueba el tamaño; la validez la mira el
cliente (inválida → `default_for` de la raza). El bit 3 de `flags` (personal del juego) es de
plataforma.md §5.4 y va en la misma versión.

### 7.4 En el cliente (kit de Quaternius)

`AppearanceApplier` (solo cliente) monta sobre `HumanoidVisual` (ART-01, un solo `GeneralSkeleton`)
cuerpo, cabeza, pelo y barba como escenas glTF de Universal Base Characters y tiñe piel, ojos y pelo por
material. Hoy en el repo hay `Superhero_Male_Head`, `Hair_SimpleParted` y `Hair_Beard` (versión
Standard); el resto es del usuario (§16). `HumanoidVisual` solo monta piezas en `_ready()`
(`_attach_part` es privado), así que gana dos funciones públicas para que cambiar una pieza no recree
el personaje:

```gdscript
# scripts/client/humanoid_visual.gd (amplía; P6)
func set_part(slot: StringName, scene: PackedScene) -> void   # &"body", &"head", &"hair", &"beard", &"marks"
func clear_part(slot: StringName) -> void
```

El equipo de PRG-05 ocultará pelo y barba (capucha, yelmo) con la lógica que ya tiene `HumanoidVisual`.

## 8. Configuración de combate persistente (CMB-30)

Es de este documento: plataforma.md solo guarda la sección `progress` (§13.1).

| Qué | Cómo se guarda | Al cargar |
|---|---|---|
| Las dos armas | Son objetos de EQUIPMENT 0 y 1 | `set_loadout` con sus armas de `CombatCatalog` (habilidades.md §3.5), en el sitio donde H3c pone las de la plantilla |
| Arma activa | `active_weapon_slot` = bit0 de `combat_flags2` al construir el guardado (CMB-24): 0 WEAPON_1, 1 WEAPON_2 | En el alta, tras `set_loadout`, `set_weapons(…, second_active = true, [], [])` si vale 1. Al reaparecer, como `reset_for_respawn`: WEAPON_1 activa |
| Habilidades elegidas | No se guardan: en la fase 5 son el kit fijo del arma (habilidades.md §2.3). Llegan con PRG-19 | — |
| Consumibles | Las pociones de la bolsa (§4.4) | Cargas = `min(15, en la bolsa)` |
| Vida | `state.health`, de plataforma.md §7.1 | La guardada; muerto, en el campamento con la vida llena |
| Reutilizaciones de 30 s o más | `timers`: clave y `ends_at_unix` | `ready_tick = s + max(0, ends_at_unix − now_unix) · 60`; las vencidas se descartan |
| Efectos largos | No hay en la fase 5: el más largo, `bleed`, dura 6 s | Cuando CMB-20 tenga uno con `persists`, con clave `effect:<id>` |
| Posición | plataforma.md §7.1 | En el Vado Gris, el campamento del reino |

**Temporizadores de la fase 5:**

| Clave | Qué | Quién la lee y la escribe |
|---|---|---|
| `unstuck` | Reutilización de `/atascado` (5 min, fuerte.md §5) | `UnstuckTracker.get_ready_at(player)` y `set_ready_at(player, tick)`, nuevos; con plataforma, `player` es `"character:<id>"` en lugar del nombre normalizado |
| `capture:<fortress_id>` | Recompensa de captura (30 min, §6.2) | `ProgressService` |
| `ability:<id>`, `consumable` | Reservadas | Ninguna habilidad ni consumible llega a 30 s (las reutilizaciones van de 10 a 20 s). `test_player_progress` falla si aparece una: habría que imponer su `ability_ready` al aparecer, solo con la misma arma |

El tiempo **corre sin conexión** (decisión §0). Al construir el guardado: `ends_at_unix = now_unix +
ceil((ready_tick − s) / 60)`, con `now_unix = ZonePlatform.now_unix()` (el reloj corregido de
plataforma.md §6). `scripts/shared/` no ve fechas y `scripts/server/progress/` no lee `Time`.

**Nada de lo que se predice por tick se guarda**: ni el resto de `CombatState` (resistencia, acción,
combo, controles, parada), ni la posición exacta entre guardados, ni las reutilizaciones de menos de
30 s (reconectar las reinicia; §17).

**Traspasos (fase 6).** CMB-30 dice que esto «viaja en el billete», pero el billete tiene 52 B
(plataforma.md §5.1) y solo lleva la identidad. La zona de origen hace un guardado final con
`release`. Desde la foto, el personaje queda **congelado**: inventario y monedas responden NOT_NOW y no
recibe recompensas. El HANDOFF sale solo tras el OK del guardado; si falla, el traspaso se cancela y se
descongela. La zona de destino lo carga en su reclamación.

## 9. Ciclo de vida en la zona

### 9.1 Carga y alta

1. HELLO con billete → `TicketAuthProvider` → `VERIFYING` → reclamación (plataforma.md §5.2).
2. **Reclamación con 200**: `AuthOutcome.record: CharacterRecord` trae `progress`. Antes del WELCOME,
   en el paso «poll», `ZoneServer` llama a `progress.prepare(peer_id, outcome.record)`:
   - decodifica `ProgressRecord.from_dictionary(record.progress, ItemDatabase.shared())`;
   - valida `record.appearance` con `record.race_id` y el reino (inválida → `default_for`, aviso);
   - crea el `PlayerProgress` del peer.

   Si `from_dictionary` devuelve null: REJECT `UNAVAILABLE` con el texto «No se ha podido cargar el
   personaje», alerta en el registro y `ZonePlatform.release(character_id, lease_id)`. Así nadie
   recibe WELCOME sin haber pasado el un solo uso, las sanciones y la carga.
3. WELCOME y `LOADING` (plataforma.md). LOADOUT_SELECT vale ya en `LOADING` (habilidades.md §5.1).
4. CLIENT_READY → `_process_arrivals`. Antes del SPAWN, `progress.on_arrival(entity, peer, s)`:
   - kit de inicio si toca (§2.5);
   - `NetEntity.level` y `NetEntity.appearance`;
   - devuelve el `Loadout` (armas, ranura activa y cargas) que usa el alta en lugar de la plantilla.
5. Tras el SPAWN propio, `progress.after_spawn(entity, peer, s)`: INVENTORY_FULL, un WALLET_UPDATE por
   moneda y un PROGRESS_UPDATE (estado). Después `CharacterSaver.track(net_id, record, s)` llama a la
   `restore` de la sección (§9.2), que ata el `PlayerProgress` al `net_id` e impone los temporizadores.

Sin plataforma, el paso 2 no existe: `on_arrival` crea un personaje efímero (§9.4).

### 9.2 La sección `progress` de `CharacterSaver`

`ProgressService.setup` la registra con `CharacterSaver.register_section(&"progress", build, restore,
acknowledge)`:

| Llamada | Qué hace |
|---|---|
| `build(net_id, seq) -> Dictionary` | `PlayerProgress.build_section(seq)`: cierra lo agregado (una GAMEPLAY), toma `active_weapon_slot` y los temporizadores (§8) y devuelve la foto y el diario sin confirmar, marcados con `seq` (§9.3) |
| `restore(net_id, record)` | Ata el `PlayerProgress` preparado a su `net_id` e impone `unstuck` (`set_ready_at`); no vuelve a decodificar |
| `acknowledge(net_id, seq)` | Guardado aplicado o `duplicate`: quita del diario las operaciones marcadas con `seq` o antes |

- **Cuándo**: lo decide plataforma.md §7.2 (cada 60 s con cambios, críticos al instante, al salir con
  `release`, cierre ordenado). Los críticos de aquí, con `CharacterSaver.mark_critical(net_id,
  reason)`: `&"starter_kit"`, `&"level_up"`, `&"capture"` y `&"gm"` (todo comando de §10 que cambia
  algo, `op_revert` incluido).
- **Un `seq`, un cuerpo**: `build` se llama una vez por `seq` y los reintentos mandan el mismo cuerpo.
  Lo que cambie mientras hay uno en vuelo va en el siguiente.
- **Salida**: `CharacterSaver.finish` llama a `build` por última vez; después, en el mismo paso,
  `progress.on_departure(net_id)` libera el estado. Al cerrar el servidor, `CharacterSaver` toma las
  fotos finales antes de `_clear_players()` (hoy `stop()` vacía los jugadores en ese mismo paso).

| Respuesta | La zona |
|---|---|
| 200 `applied` o `duplicate` | `acknowledge` |
| 409 `lease_lost` | Expulsa y descarta el estado (plataforma.md §7.3); manda la BD |
| 400 `invalid_progress` (§13.3) | Es un error nuestro: alerta con la comprobación y el detalle, NOTICE de expulsión «Error al guardar el personaje. Avisa a un GM.», `release` sin guardar y se descarta el estado. Manda la BD, que no tiene nada a medias |
| 409 `schema_mismatch` (también un `progress_format` que no es el suyo) | Como plataforma.md §7.1: error en el registro y conserva el guardado en memoria |
| 409 `instance_replaced` | Cierre ordenado sin guardar (plataforma.md §5.3) |
| 5xx o sin respuesta | Reintenta el mismo cuerpo (plataforma.md §6) |

### 9.3 La sección `progress` de un guardado

Es el `ProgressRecord` de §3.4 más `zone_id` y el diario (`ops`), en orden de aplicación:

```json
{"progress_format": 1, "zone_id": "vado_gris", "level": 7, "xp_total": 12345, "…": "resto de §3.4",
 "ops": [{"op_id": 5120, "kind": 2, "actor_account_id": null, "ref_op_id": null, "note": null, "detail": {},
          "ledger": [{"currency": 1, "delta": 2, "balance_after": 102, "reason": 6, "ref_kind": 2, "ref_id": 3021413298},
                     {"currency": 2, "delta": 30, "balance_after": 3230, "reason": 3, "ref_kind": 1, "ref_id": 88}],
          "items": [{"uid": null, "def_id": "potion_health", "count_delta": -1, "reason": 65}]},
         {"op_id": 5121, "kind": 4, "actor_account_id": 77, "ref_op_id": null, "note": "devolución del fallo 12",
          "detail": {"command": "currency_add", "source": "gm", "args": ["Ana", "oro", "50"]},
          "ledger": [{"currency": 1, "delta": 50, "balance_after": 152, "reason": 7, "ref_kind": 0, "ref_id": 0}],
          "items": []}]}
```

- `items` de la foto: todas las instancias vivas. `items` de una operación: sus eventos (I4). Un evento
  lleva `uid` cuando es de una instancia concreta (kit, GM, DESTROY del jugador) y `null` cuando es
  agregado (CAMP_REFILL, CONSUME).
- Los apuntes de cada moneda, en orden. No llevan `seq` (§5.2).
- No hay `save_id`, `base_version` ni versión propia: la idempotencia es `(lease_id, seq)` del cuerpo de
  plataforma.md §7.3, que envuelve esta sección.

### 9.4 Sin plataforma: personajes efímeros

- Sin `--platform`, todo jugador con peer es efímero: `on_arrival` crea `ProgressRecord.new_character()`
  y el kit con la plantilla de LOADOUT_SELECT, con `IdAllocator.local()`. Nada se guarda y al salir se
  pierde.
- Inventario, monedas, niveles, pociones y comandos funcionan igual, para probar en local (`--local`) y
  con bots (`--bot`, `--bots=N`).
- El diario se queda en memoria (las últimas 256 operaciones por personaje) para `op_show`,
  `ledger_show` y `op_revert`.
- Con plataforma, todos los jugadores con peer son persistentes (`AuthProvider.uses_tickets()`); los
  jugadores falsos no tienen inventario nunca.
- Para probar la persistencia en local hace falta la plataforma: `deploy/dev.sh` o su
  `docker-compose.yml` (plataforma.md §12).

## 10. Herramientas de GM (PRG-16)

Comandos del `CommandRegistry` (TEC-19): por la consola del servidor, por `/gm …` con rol (SOC-14,
plataforma.md §9.1: cada comando declara su `min_role`) y por DEBUG_COMMAND con las reglas de abajo. En
la fase 5 el personaje tiene que estar conectado en esa zona; la edición sin conexión es del panel de
moderación (SOC-37, fase 8).

| Comando | Argumentos | Efecto | Rol | Id de red |
|---|---|---|---|---|
| `item_give` | personaje def_id [cantidad] | Crea en la primera ranura libre de la bolsa (GM_GRANT); bolsa llena → error | gm | 40: `u16 def`, `u16 count` (1–999) |
| `currency_add` | personaje oro\|meritos ±cantidad motivo… | Apunte GM_GRANT o GM_REMOVE; el motivo escrito es la `note`, obligatoria | gm | 41: `u8 currency` (1–2), `s32 amount` (≠ 0); `note` = «debug» |
| `level_set` | personaje nivel | Nivel y `xp_total = curve.total_to(nivel)` | gm | 42: `u8 level` (1–40) |
| `xp_add` | personaje cantidad | Como una fuente más | gm | 43: `u32 amount` (1–10 000 000) |
| `item_take` | personaje uid [cantidad] | Destruye (GM_REMOVE) | gm | — |
| `mastery_set` | personaje arma nivel | Reservado: «No disponible hasta la fase 6» | gm | — |
| `inv_show` | personaje | Bolsa y equipo con uid, cantidad y ligado | gm | — |
| `ledger_show` | personaje [n = 20] | Últimos n apuntes: el diario sin confirmar y, con plataforma, `GET /internal/v1/characters/{id}/ledger` | gm | — |
| `op_show` | op_id | Apuntes y eventos de una operación (`GET /internal/v1/ops/{op_id}`) | gm | — |
| `op_revert` | op_id motivo… | Revierte (abajo) | gm | — |

Los ids 40–43 son fijos en `NetProtocol.DEBUG_*` y su `decode` valida el tamaño y los rangos.

**DEBUG_COMMAND** (todos los ids, no solo 40–43; siempre sobre el propio jugador):

| Servidor | Regla |
|---|---|
| Sin `--debug-commands` | Aviso, como hoy (red.md §12) |
| `--debug-commands`, sin plataforma | Como hoy: personajes efímeros, nada se guarda |
| `--debug-commands` y `--platform` | Además, rol `gm` o más de la reclamación (`CharacterRecord.role`); los ids 40–43, que crean valor sobre uno mismo, exigen `admin`. Sin rol: aviso y nada |
| `--debug-commands`, `--platform` y `ELDMARK_ENV` = `staging` o `production` | `ServerMain` no arranca, con un mensaje en español |

**Rastro de cada comando que cambia algo.** Crea una operación GM (aunque no tenga apuntes ni eventos)
con:

- `actor_account_id` (null solo desde la consola);
- `note`: el motivo escrito; «debug» por DEBUG_COMMAND; obligatoria y no vacía;
- `detail`: `command`, `args`, `source` (`gm`, `console` o `debug`) y, si toca nivel o XP,
  `level_before`, `level_after`, `xp_before`, `xp_after` y `xp_delta`.

Su fila de `audit_log` la escribe el propio guardado (§13.3, S8) con `event_key = "op:<op_id>"`, y la
entrada del lote de auditoría de la zona usa la misma clave: llegue antes o después, no se duplica ni se
pierde. Los comandos de consulta van al lote de auditoría como cualquier otro (plataforma.md §9.1).

**Sobre un personaje de la cuenta del propio GM**, cualquier comando que cambie algo exige `admin`; si
no, «No puedes usarlo sobre tus personajes». El servicio lo vuelve a comprobar (S2).

**Reversión** (`op_revert op_id motivo…`):

- Solo de una operación ya guardada (con plataforma, la lee de `GET /internal/v1/ops/{op_id}`; sin
  plataforma, del diario de la sesión) de un personaje conectado en esta zona. Ni una REVERSAL, ni una
  MIGRATION, ni una ya revertida (`op_reversals`). Una aún sin guardar: «Esa operación aún no está
  guardada; inténtalo en unos segundos».
- Cierra lo agregado (§5.2) y crea una REVERSAL con `ref_op_id` y el motivo como `note`. Es crítica.
  Todo o nada.
- **Apuntes**: otro con el `delta` contrario, motivo REVERSAL, `ref_kind` 4 y `ref_id` = la original.
  Si un saldo quedaría negativo (ya se lo gastó), no se revierte nada y el GM recibe lo que falta.
- **Eventos con `count_delta > 0`**: se quita esa cantidad de la definición. Primero del `uid` del
  evento si sigue vivo, después de las pilas de la bolsa por orden de ranura y, si es equipable, de una
  ranura de equipo que no sea la activa. Dividir o juntar no la esquiva. Si en todo el personaje no
  queda tanta, no se revierte nada y se dice cuánta falta.
- **Eventos con `count_delta < 0`**: se crea esa cantidad con **otros** `uid` (I1), en pilas hasta
  `max_stack`. Si el evento tiene `uid`, se copian los campos de su fila retirada (la devuelve la ruta);
  si no, ligado. Bolsa llena: no se revierte nada.
- **Méritos** revertidos de motivo 3–5: bajan los puntos de reino lo mismo (I9).
- **XP**: el `detail.xp_delta` de la original se resta de `xp_total` (sin bajar de 0) y se recalcula el
  nivel.

## 11. Interfaz: inventario y ventana de personaje (UI-26)

### 11.1 Ventanas

| Ventana | Tecla | Contenido |
|---|---|---|
| Inventario | I | Rejilla de 6 columnas con `bag_slots` casillas (`InventorySlotView`, un `UIIconSlot` con arrastre); al pie, oro y méritos |
| Personaje | C | Figura 3D (SubViewport con `HumanoidVisual`, su apariencia y sus armas; gira al arrastrar), las dos ranuras de arma (las otras cinco, en gris con «Próximamente»), nombre, reino, nivel y barra de XP, puntos de reino, puntos de atributo y la hoja de `CombatRules` (vida y resistencia máximas). En la fase 5 la hoja no cambia con el equipo |

Las dos usan `UIWindow` (UI-09), se abren a la vez y liberan el cursor. Se arrastra de una a otra.

### 11.2 Gestos

| Gesto | Petición |
|---|---|
| Arrastrar y soltar | MOVE (mover, juntar, intercambiar, equipar, desequipar) |
| Mayúsculas + arrastrar | SPLIT, con un diálogo de cantidad (por defecto, la mitad) |
| Doble clic o clic derecho en la bolsa | Equipar: un arma, a WEAPON_2 si está vacía y si no a la ranura no activa |
| Doble clic o clic derecho en el equipo | Desequipar a la primera ranura libre de la bolsa |
| Soltar fuera de las ventanas | DESTROY tras `UIConfirmDialog` («¿Destruir Poción de vida ×3?», con cantidad en las pilas) |

**Tooltip** (`UITooltip`): nombre con el color de su rareza, categoría y ranura, nivel requerido (en
rojo si no llega), lo que aporta (arma: daño de sus ataques y habilidades de `CombatCatalog`; poción: su
efecto), «Ligado», valor y, en un arma, la **comparación** de daño con la de esa ranura (en verde o
rojo).

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

Lo que **no** es optimista: el arma en las manos, la barra de acciones (UI-11) y las cargas cambian
con el estado **confirmado** (LOADOUT y el estado propio), un RTT después; así un rechazo nunca hace
parpadear el arma.

## 12. Protocolo

| Qué | Formato |
|---|---|
| Versión | **Una sola para la fase 5, compartida con plataforma.md**: la siguiente libre tras la 6 de habilidades.md (la 7 si nadie la toma antes). La sube el primero de los dos P4 que se fusione, con la línea «7: la fase 5 (docs/plataforma.md y docs/progresion.md): …»; el segundo la completa sin subirla. red.md §5.2, §5.3 y §5.5 anotan en la misma versión los REJECT 10–12, el billete de 52 B, el bit 3 del SPAWN y estos 9 B |
| HELLO | Sin cambios (plataforma.md §5.4) |
| ENTITY_SPAWN de PLAYER | +9 B tras el nombre: `u8 level` (0 si el receptor no es de su reino) y 8 B de apariencia (§7.3) |
| `0x50`–`0x53` | INVENTORY_REQUEST (C→S, 18 B), INVENTORY_DELTA (S→C, ≤ 1120 B), INVENTORY_FULL (S→C, ≤ 1089 B), INVENTORY_SYNC_REQUEST (C→S, 1 B): §4.6 |
| `0x54` WALLET_UPDATE | S→C, 19 B: `u8 type`, `u8 currency`, `u64 balance`, `s64 delta` (0 en el estado inicial), `u8 reason`. Uno cada 10 ticks por moneda como mucho, con el delta sumado |
| `0x55` PROGRESS_UPDATE | S→C, 25 B: `u8 type`, `u8 level`, `u32 xp_in_level`, `u32 xp_to_next` (0 en el tope), `u32 gained`, `u8 source` (0 estado, 1 PvP, 2 PNJ, 3 captura, 4 GM), `u64 realm_points`, `u16 attribute_points` |
| `0x56`–`0x5F` | Reservados (banco, comercio y correo de la fase 6) |
| ENTITY_EVENT `16 LEVEL_UP` | `u8 level`, 10 B. El 16 deja hueco a los eventos de la fase 4 (habilidades.md usa del 7 al 11) |
| ENTITY_EVENT `9 LOADOUT` | De habilidades.md, sin cambios: `template_id` 0 = el equipo del inventario |
| DEBUG_COMMAND 40–43 | §10 |
| `sim_hash` | Añade `ItemDatabase.wire_hash()`, porque los net id de objeto viajan. red.md §3 pasa a decir «la simulación y los catálogos cuyos ids viajan (`CombatCatalog`, `ItemDatabase`)» y el texto del REJECT, «Los datos del juego no coinciden con los del servidor: actualiza el cliente». La apariencia **no** entra: un índice desconocido ya cae a la apariencia por defecto |

Van en `scripts/shared/net/progress_messages.gd` (`ProgressMessages`), aparte de `net_messages.gd`
para no chocar con otros carriles; por el canal 3 y solo al dueño salvo LEVEL_UP. Una petición antes
de estar en el mundo suma un aviso.

## 13. Interfaz con plataforma.md

### 13.1 Lo que este documento pide a plataforma.md

Anotado aquí; lo cambia el documento de plataforma.

| # | Pide | En plataforma.md |
|---|---|---|
| 1 | CMB-30 es de progresion.md: se quitan `state.combat` y la frase «de `docs/habilidades.md`». Lo que guarda va en `progress` | Introducción, §7.1, §16 |
| 2 | Las tablas de solo añadir del progreso, **sin** clave ajena a `characters`; la cascada, solo en las de estado (§3.3) | §3, la frase de las tablas de progreso |
| 3 | La purga (personaje y cuenta) llama a `ProgressStore.Purge` antes de borrar la fila; el trabajo horario, a `PurgeRetention`; la exportación incluye `ProgressStore.Export`. Fila nueva en §11.1: «Libro, eventos y operaciones de un personaje purgado: 1 año» | §2.5, §4.4, §7.5, §11.1, §11.2 |
| 4 | `characters.level` lo escribe `ProgressStore.Apply` (copia de `progress.level`) y se quita `state.level`: un solo dueño del nivel | §7.1, §7.3 paso 4 |
| 5 | Apariencia de **8 B exactos** (`check (length(appearance) = 8)`); mientras no exista el catálogo, la de `default_for(raza)`. Razas `race_vardheim`, `race_solmarch` y `race_askarra` también en el modo provisional | §3 (0002), §4.4 paso 5 |
| 6 | Un solo archivo de reglas: `platform/internal/gamedata/progression_rules.json` (razas, límites de apariencia, objetos, curva, topes, motivos, contenedores), escrito por `tools/platform/export_gamedata.gd` con `ProgressionRulesExport.build()` y comprobado por `test_platform_gamedata.gd`. Sustituye a `appearance_limits.json`. Dentro de `platform/` porque `go:embed` no admite `..` | §4.4 paso 5, P2 |
| 7 | La creación **no** necesita `starter_template_id`: la plantilla se elige en la primera entrada (§2.5). `ProgressStore.Create` no cambia de firma | §4.4 |
| 8 | Gancho antes del WELCOME: `progress.prepare(peer_id, outcome.record)`; si devuelve false, REJECT `UNAVAILABLE` con «No se ha podido cargar el personaje» y `release` (§9.1). `CharacterRecord` gana `race_id: StringName` | §5.2, §14.3 |
| 9 | `register_section(section, build, restore, acknowledge)` con `build(net_id, seq) -> Dictionary`, `restore(net_id, record)` y `acknowledge(net_id, seq)`; `build` una vez por `seq` y los reintentos con el mismo cuerpo | §7.2, §7.5, §14.3 |
| 10 | Los críticos de §9.2 (añade el kit de inicio) y la tabla de respuestas de §9.2: un 400 de un guardado expulsa y libera sin guardar | §7.2, §7.3 |
| 11 | `ProgressStore.Apply` devuelve `*progress.InvalidError` (→ 400 `invalid_progress` con `fields.check`) o `progress.ErrFormat` (→ 409 `schema_mismatch`) | §6, §7.3 |
| 12 | P7 (almacén en Go, migraciones 0010+, rutas `GET /internal/v1/ops/{op_id}` y `GET /internal/v1/characters/{id}/ledger`) es de este documento; `jsonProgressStore` vale hasta que llegue. El enrutador interno llama a `progress.RegisterInternalRoutes` | §6, §7.5, §14.1 |
| 13 | Bloques de `item_uid_blocks` con `count` 1024, el primero antes de abrir el puerto; de ellos salen también los `op_id` | §6, §8 |
| 14 | Una sola versión del protocolo para la fase 5 (§12) | §5.4 |
| 15 | DEBUG_COMMAND con plataforma exige rol `gm` (40–43, `admin`) y `ServerMain` no arranca con `--platform`, `--debug-commands` y `ELDMARK_ENV` de staging o producción (§10) | §5.5, §9.1 |
| 16 | La auditoría de un comando de progreso usa `key = "op:<op_id>"` (§10) | §9.1 |
| 17 | Con `--platform` y `--fake-players`, la zona no da recompensas persistentes (§6.2) | §5.5 |
| 18 | JSON: ids como números por debajo de 2^53, como su §4.1. El único que puede pasar es el `ticket_id` aleatorio de 63 bits: solo va de la zona a la plataforma (Godot lo escribe exacto, comprobado); si alguna respuesta lo devolviera, como cadena | §4.1, §6 |
| 19 | `take_events()` reparte a `progress.on_platform_event(event)` los resultados de bloques, operaciones y libro (`kind` que empiezan por `progress_`) | §14.3 |

### 13.2 El almacén en Go (P7, este documento)

```go
// platform/internal/progress. Implementa persistence.ProgressStore (plataforma.md §7.5) y lo amplía.
package progress

type Rules struct{ /* de gamedata: progression_rules.json */ }
func LoadRules(raw []byte) (*Rules, error)

type Store struct{ /* reglas y reloj inyectable */ }
func New(rules *Rules, now func() time.Time) *Store
func (s *Store) Create(ctx context.Context, tx pgx.Tx, worldID int16, characterID int64) error
func (s *Store) Load(ctx context.Context, tx pgx.Tx, characterID int64) (json.RawMessage, error)
func (s *Store) Apply(ctx context.Context, tx pgx.Tx, worldID int16, characterID int64,
	progress json.RawMessage, key persistence.SaveKey) error             // S1–S8; key solo para el registro
func (s *Store) Purge(ctx context.Context, tx pgx.Tx, worldID int16, characterID int64) error  // lápida
func (s *Store) PurgeRetention(ctx context.Context, tx pgx.Tx) (deleted int64, err error)     // §3.5
func (s *Store) Export(ctx context.Context, tx pgx.Tx, characterID int64) (json.RawMessage, error)
func (s *Store) Op(ctx context.Context, q Querier, worldID int16, opID int64) (json.RawMessage, error)
func (s *Store) Ledger(ctx context.Context, q Querier, characterID int64, limit int,
	beforeEntryID int64) (json.RawMessage, error)                        // limit 1–100; más recientes primero
func RegisterInternalRoutes(mux *http.ServeMux, s *Store, pool *pgxpool.Pool)

type Querier interface { // lo cumplen pgx.Tx y *pgxpool.Pool
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}
type InvalidError struct{ Check, Detail string } // 400 invalid_progress
var ErrFormat = errors.New("progress_format")     // 409 schema_mismatch
var ErrNotFound = errors.New("not_found")         // 404
```

- Archivos: `store.go`, `checks.go` (S1–S7), `write.go` (S8), `retention.go`, `routes.go` y sus
  pruebas; migraciones `internal/migrate/migrations/0010_progress.up.sql` y `.down.sql`. Las reglas,
  con `//go:embed progression_rules.json` en `internal/gamedata`.
- `Load` arma el JSON de §3.4 desde las tablas; un personaje recién creado da el registro con los
  valores por defecto.
- **Rutas** (con el token de zona de plataforma.md §6):
  - `GET /internal/v1/ops/{op_id}?world_id=` → `{op: {op_id, kind, actor_account_id, ref_op_id,
    zone_id, note, detail, created_at_unix, participants, reversed_by, ledger: [{character_id,
    currency, seq, delta, balance_after, reason, ref_kind, ref_id}], items: [{character_id, uid,
    def_id, count_delta, reason}], instances: [{uid, def_id, count, durability, rarity, bound, seed,
    affixes, retired}]}}`, o 404.
  - `GET /internal/v1/characters/{id}/ledger?limit=20&before_entry_id=` → `{entries: [{entry_id,
    op_id, currency, seq, delta, balance_after, reason, ref_kind, ref_id, created_at_unix}]}`.
- Los casos de `tests/fixtures/progression/` se leen con `os.ReadFile("../../../tests/fixtures/…")`
  (no con `go:embed`, que no admite `..`).

### 13.3 Comprobaciones del guardado (S1–S8)

Dentro del paso 4 de plataforma.md §7.3: el arrendamiento ya está bloqueado y el `seq` es nuevo.
Cualquier fallo de S1–S7 devuelve `InvalidError` con su número y el guardado entero se deshace.

| # | Comprobación |
|---|---|
| S1 | `progress_format` = 1 (si no, `ErrFormat`). Claves conocidas. Todo id es entero de 1 a 2^53 − 1 |
| S2 | **Operaciones.** `(op_id, character_id)` no está en `op_participants`. `op_id` < `item_uid_blocks.next_uid` de su mundo. `kind` 1–6 en la fase 5. GM y REVERSAL, con `note` no vacía. GM: `actor_account_id` con rol `gm` o `admin` en `accounts`, o `detail.source = "console"` sin actor; sobre un personaje de la cuenta del actor, solo `admin`. STARTER_KIT solo si `starter_granted` era false en la BD. REVERSAL: `ref_op_id` existe, es de este personaje, no es REVERSAL ni MIGRATION y no está en `op_reversals`. Una operación que ya existe con otro participante (comercio, fase 6) debe tener el mismo `kind` |
| S3 | **Libro.** Por moneda y en orden: `balance_after = anterior + delta`, entre 0 y el tope, con el signo del rango de su motivo; el último es el saldo de la foto; una moneda sin apuntes no cambia de saldo |
| S4 | **Objetos (I4).** Por definición: Σ `count` vivas en la BD + Σ `count_delta` de los eventos = Σ `count` de la foto. Un evento con `uid` y `count_delta > 0` es de un uid que no estaba en la BD; con `count_delta < 0`, de un uid vivo de este personaje en la BD |
| S5 | **Foto.** Uids sin repetir; contenedor 0–1; ranuras únicas, bolsa < `bag_slots`, equipo 0–1; definición en las reglas; `count` 1 … `max_stack`; durabilidad según `has_durability`; rareza 0 y sin afijos en la fase 5; en el equipo, un WEAPON por ranura y la activa con arma (I10); el `bound` de un uid que ya estaba no pasa a false. Un uid nuevo que ya exista en `item_instances` (vivo o retirado, de cualquier personaje) choca con la clave primaria al insertarlo (I1) y se devuelve como S5 |
| S6 | **Progreso.** `level = level_for(xp_total)` con la curva de las reglas; `xp_total` no baja sin una GM o REVERSAL en el guardado; `realm_points` nuevo = antiguo + Σ apuntes de méritos de motivo 3–5 + Σ apuntes de méritos de las REVERSAL de operaciones con méritos de motivo 3–5; `bag_slots` no cambia; `starter_granted` no vuelve a false; `active_weapon_slot` 0–1 |
| S7 | **Temporizadores.** Claves `^[a-z0-9_:]{1,48}$`, 16 como mucho, `ends_at_unix` entre ahora y ahora + 7 días |
| S8 | **Escribe.** `character_progress` y `characters.level`; saldos con su `last_seq`; objetos: inserta los nuevos, actualiza los que cambian y retira los que faltan (`retired_at`, sin contenedor ni ranura); operaciones (`on conflict do nothing`), participantes, apuntes con su `seq`, eventos y `op_reversals`; una fila de `audit_log` por operación GM (`event_key = "op:<op_id>"`, `on conflict do nothing`); temporizadores (sustituye el conjunto) |

S3 a S6 repiten en Go lo que `InventoryOps`, `CurrencyRules` y `PlayerProgress` ya garantizan en
GDScript: son la red de seguridad contra un error de la zona, no la regla del juego. Para que las dos
implementaciones no diverjan, `tools/progression/write_fixtures.gd` genera con `PlayerProgress` los
casos de `tests/fixtures/progression/` (secuencias de guardados con su resultado esperado, válidos e
inválidos, uno por comprobación). Los casos se suben al repo; `test_progression_fixtures.gd` los
regenera en memoria y falla si difieren, y las pruebas de Go los leen.

## 14. Paquetes y contratos

### 14.1 Paquetes

Todo empieza con habilidades.md fusionado (H1a a H3c para P2 y P5b, H4 para P6). Los paquetes de
servidor esperan además a los de plataforma.md que se nombran.

| Paquete | Contenido | Depende de |
|---|---|---|
| **P1 · objetos** | `ItemDefinition`, `ItemInstance` (encode/decode, `to_dictionary`/`from_dictionary`), `ItemDatabase`, `data/items/` (§2.4), `tests/fixtures/items/`; `test_item_database`, `test_item_instance` | `CombatCatalog` |
| **P2 · inventario puro** | `InventoryState`, `InventoryOps`, `ItemEvent`, `EconomyReason`, `Currency`, `CurrencyRules`, `StarterKit`, `ActionMachine.set_weapons`; `test_inventory_ops`, `test_inventory_properties`, `test_currency_rules`, `test_action_machine_weapons` | P1; H1b |
| **P3 · progreso y apariencia** | `LevelCurve` y su `.tres`, `ProgressionRules`, `CharacterAppearance`, `AppearanceCatalog`, `AppearancePart`, `AppearanceColor`, `RaceDefinition`, `data/characters/`, `ProgressionRulesExport`; `test_level_curve`, `test_character_appearance`, `test_progression_rules_export` | — |
| **P4 · protocolo** | `ProgressMessages` (0x50–0x55), LEVEL_UP, ids 40–43, `NetEntity.level`, `appearance` y `encode_spawn(…, receiver_realm)` con sus tres llamadas en `ZoneServer`, versión (§12), `sim_hash`; recepción en `NetClient` (señales) y en `SwarmBot` (descarte); red.md; `test_progress_messages` | P1, P3; H2 |
| **P5a · registro y sección** | `scripts/server/progress/`: `ProgressRecord`, `LedgerEntry`, `EconomyOp`, `IdAllocator`, `PlayerProgress` (inventario, monedas, agregación, diario, `build_section`, `acknowledge`), `ProgressService.setup`, `start`, `prepare` y `on_platform_event`; la sección en `CharacterSaver`; el gancho antes del WELCOME; `tools/progression/write_fixtures.gd` y los casos; `test_progress_record`, `test_player_progress`, `test_progress_section`, `test_progression_fixtures` | P2, P3; plataforma.md P4 y P5 |
| **P5b · inventario en la zona** | Alta (`on_arrival`, `after_spawn`, `loadout_for`, donde H3c pone la plantilla), `handle_packet` en `_on_packet_received` (0x50–0x53, con RATE), `apply_pending` tras `_process_arrivals`, `set_weapons` y LOADOUT, CONSUME (`after_simulate`, tras el paso 1), CAMP_REFILL (`camp_step`, en el paso 8 en lugar de la recarga), cargas, `UnstuckTracker.get_ready_at`/`set_ready_at` y su clave, `on_departure` tras `CharacterSaver.finish`, efímeros, `NetEntity.level`; `test_progress_service`. `test_bot_swarm` y `test_net_processes` siguen con 0 malformados | P5a, P4; H3c |
| **P5c · recompensas** | `on_merits` (PRG-09), `on_npc_killed` (`xp_reward` y `gold_reward` en `NpcDefinition` y `data/npcs/`), `on_capture` (GUE-12) con su temporizador, XP, LEVEL_UP, PROGRESS_UPDATE, críticos, regla de `--fake-players`; `test_progress_rewards` | P5b; PRG-09, MUN-07, GUE-12 |
| **P5d · GM** | Comandos de §10 con `min_role`, ids 40–43, reglas de DEBUG_COMMAND en `_handle_debug_command`, guardia de `ELDMARK_ENV` en `ServerMain`, reversión, `op_show` y `ledger_show` por las rutas; `test_gm_progress` | P5b; plataforma.md P7 (roles); TEC-19 |
| **P6 · cliente** | `ClientInventory`, `InventoryWindow`, `CharacterWindow`, `InventorySlotView`, `SplitDialog`, `AppearanceApplier`, `HumanoidVisual.set_part`/`clear_part`, selector de plantilla oculto tras la primera entrada; `test_client_inventory`, `test_inventory_window`, `test_appearance_visual` | P2, P3, P4, UI-09; H4 |
| **P7 · almacén en Go** | `platform/internal/progress/` (§13.2), `0010_progress` con su `.down.sql`, S1–S8, retención, exportación, rutas; pruebas de Go de §15 | plataforma.md P0 (`testdb`, `migrate`) y P3 (contratos); P3 de aquí (reglas exportadas); los casos de P5a |
| **P8 · integración** | `test_progress_loopback`, `test_progress_platform_loopback`, `--bot-scenario=progress` del bot, `platform/e2e/progress_test.go` (§15) | P5a–P5d, P6, P7; plataforma.md P8 y P10 |

P1 y P3 van en paralelo; después P2 y P4; después P5a y P6 en paralelo; después P5b; después P5c y P5d
en serie (los dos tocan `zone_server.gd`). P7 empieza en cuanto estén plataforma.md P0 y P3, P3 de aquí
y los casos de P5a. P8 al final.

### 14.2 Contratos en GDScript

Firmas públicas y estables; lo privado queda a criterio de quien implemente. Los campos de datos son
los de §2.1, §3.4 y §7.2 con tipos estáticos.

```gdscript
# scripts/shared/progression/ (compartido: sin Time, OS ni Input)
class_name ItemDefinition extends Resource          # enums Category, EquipSlot, BindRule de §2.1

class_name ItemInstance extends RefCounted
const FORMAT: int = 1; const MAX_AFFIXES: int = 6; const NO_DURABILITY: int = -1
const MAX_UID: int = (1 << 53) - 1
var uid: int; var def_id: StringName; var count: int; var durability: int; var rarity: int
var bound: bool; var seed: int; var affixes: PackedInt32Array
func encode(db: ItemDatabase = null) -> PackedByteArray                  # null = shared()
static func decode(bytes: PackedByteArray, offset: int, db: ItemDatabase = null) -> ItemInstance
static func encoded_size_at(bytes: PackedByteArray, offset: int) -> int   # −1 si no cabe
func to_dictionary(container: int, slot: int) -> Dictionary              # una entrada de §3.4
static func from_dictionary(data: Dictionary, db: ItemDatabase) -> ItemInstance  # null si no cuadra
func duplicate_instance() -> ItemInstance; func equals(other: ItemInstance) -> bool

class_name ItemDatabase extends RefCounted
const DATA_DIR: String = "res://data/items"
var errors: PackedStringArray
static func shared() -> ItemDatabase; static func build_from_directory(dir: String) -> ItemDatabase
func get_definition(id: StringName) -> ItemDefinition                    # null si no existe
func net_id_of(id: StringName) -> int; func definition_by_net_id(net_id: int) -> ItemDefinition
func for_ref(category: int, ref_id: StringName) -> ItemDefinition
func consumable_definition(index: int) -> ItemDefinition                 # CombatCatalog.consumable_ids()
func all_ids() -> Array[StringName]; func wire_hash() -> int

class_name InventoryState extends RefCounted
enum Container { BAG = 0, EQUIPMENT = 1, BANK = 2 }
enum EquipmentSlot { WEAPON_1 = 0, WEAPON_2 = 1, HEAD = 2, CHEST = 3, HANDS = 4, LEGS = 5, FEET = 6 }
const BAG_SLOTS_DEFAULT: int = 30; const BAG_SLOTS_MAX: int = 120; const EQUIPMENT_SLOTS: int = 7
const OPEN_EQUIPMENT_SLOTS: int = 2                                      # fase 5: solo las armas
var bag_slots: int; var active_weapon_slot: int
func get_item(container: int, slot: int) -> ItemInstance                 # null si vacía
func set_item(container: int, slot: int, item: ItemInstance) -> void     # null la vacía
func first_free(container: int) -> int; func find_uid(uid: int) -> Vector2i   # −1 / (−1, −1)
func count_of(def_id: StringName) -> int                                 # bolsa y equipo
func all_items() -> Array[ItemInstance]; func duplicate_state() -> InventoryState

class_name InventoryOps extends RefCounted
enum Op { MOVE = 1, SPLIT = 2, DESTROY = 3 }
enum Result { OK = 0, INVALID = 1, STALE = 2, NOT_NOW = 3, CANNOT_EQUIP = 4,
		WEAPON_REQUIRED = 5, NO_ROOM = 6, LOCKED = 7, RATE = 8 }
class Request:
	var op: int; var from_container: int; var from_slot: int; var to_container: int
	var to_slot: int; var count: int; var expected_uid: int
class Context:
	var db: ItemDatabase; var level: int = 1
	var can_touch_equipment: bool = true          # false: muerto, derribado, en combate o con acción
	var drinking: bool = false                    # ABILITY de consumible en curso
	var new_uid: Callable = Callable()            # () -> int; 0 = sin ids para clientes
class Outcome:
	var result: int; var changed: Array[Vector2i]; var events: Array[ItemEvent]
	var weapons_changed: bool                     # tocó EQUIPMENT 0 o 1
static func apply(state: InventoryState, request: Request, context: Context) -> Outcome
static func result_text(result: int) -> String                           # español (§4.2)

class_name ItemEvent extends RefCounted
var uid: int                                      # 0 = agregado (null en JSON)
var def_id: StringName; var count_delta: int; var reason: int
class_name EconomyReason extends RefCounted    # constantes de §5.3; is_source, is_sink, is_internal
class_name Currency extends RefCounted         # enum Code { GOLD = 1, MERITS = 2 }; const CAP = 10^9
class_name CurrencyRules extends RefCounted
static func can_apply(balance: int, delta: int) -> bool
static func clamp_gain(balance: int, gain: int) -> int

class_name StarterKit extends RefCounted
## Coloca el kit de §2.5 en un inventario vacío; devuelve los eventos (motivo STARTER_KIT, con uid).
static func grant(state: InventoryState, template_id: StringName, db: ItemDatabase,
		new_uid: Callable) -> Array[ItemEvent]

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

class_name ProgressionRulesExport extends RefCounted
static func build() -> Dictionary     # §13.1 #6; claves ordenadas: el JSON sale igual en cada llamada

# scripts/shared/combat/action_machine.gd (amplía): set_weapons de §4.1

# scripts/server/net_entity.gd (amplía)
var level: int = 0; var appearance: PackedByteArray
func encode_spawn(tick: int, for_owner: bool, receiver_realm: int = 0) -> PackedByteArray

# scripts/server/unstuck_tracker.gd (amplía)
func get_ready_at(player: String) -> int; func set_ready_at(player: String, tick: int) -> void

# scripts/server/progress/ (servidor; sin Time: la hora UTC es ZonePlatform.now_unix())
class_name ProgressRecord extends RefCounted     # la sección progress de §3.4
const FORMAT: int = 1
var level: int = 1; var xp_total: int; var realm_points: int; var bag_slots: int = 30
var starter_template_id: StringName; var starter_granted: bool; var active_weapon_slot: int
var inventory: InventoryState; var wallets: PackedInt64Array      # índice = moneda; [0] sin usar
var timers: Dictionary[String, int]                               # clave → ends_at_unix
static func new_character() -> ProgressRecord                     # lo que es {}
static func from_dictionary(data: Dictionary, db: ItemDatabase) -> ProgressRecord   # null si no cuadra
func to_dictionary() -> Dictionary                                # sin zone_id ni ops

class_name LedgerEntry extends RefCounted
var currency: int; var delta: int; var balance_after: int; var reason: int; var ref_kind: int
var ref_id: int
class_name EconomyOp extends RefCounted
enum Kind { PLAYER = 1, GAMEPLAY = 2, STARTER_KIT = 3, GM = 4, REVERSAL = 5, MIGRATION = 6 }
var op_id: int; var kind: int; var actor_account_id: int; var ref_op_id: int; var note: String
var detail: Dictionary; var ledger: Array[LedgerEntry]; var items: Array[ItemEvent]
var save_seq: int                                                 # 0 = aún en ningún guardado
func to_dictionary() -> Dictionary; static func from_dictionary(data: Dictionary) -> EconomyOp

class_name IdAllocator extends RefCounted
const BLOCK_SIZE: int = 1024; const REFILL_BELOW: int = 512; const SERVER_RESERVE: int = 256
static func local() -> IdAllocator                                # sin plataforma: desde 1, sin bloques
func add_block(first: int, count: int) -> void
func needs_block() -> bool; func available() -> int
func next_for_client() -> int                                     # 0 si quedan ≤ SERVER_RESERVE
func next_for_server() -> int                                     # 0 si no queda ninguno

class_name PlayerProgress extends RefCounted   # estado autoritativo de un personaje en la zona
var record: ProgressRecord; var persistent: bool
var character_id: int; var account_id: int                        # 0 si es efímero
func _init(record: ProgressRecord, persistent: bool, ids: IdAllocator, db: ItemDatabase) -> void
func apply_request(request: InventoryOps.Request, context: InventoryOps.Context) -> InventoryOps.Outcome
func begin_op(kind: int, actor_account_id: int, note: String, detail: Dictionary) -> EconomyOp  # cierra lo agregado; null sin id
func add_items(op: EconomyOp, def_id: StringName, count: int, reason: int) -> bool              # false: no cabe y nada cambia
func remove_items(op: EconomyOp, def_id: StringName, count: int, reason: int,
		prefer_uid: int = 0) -> bool
func change_currency(op: EconomyOp, currency: int, delta: int, reason: int, ref_kind: int,
		ref_id: int) -> bool
func gain_currency(currency: int, amount: int, reason: int, ref_kind: int, ref_id: int) -> int  # agregada; lo aplicado tras el tope
func gain_items(def_id: StringName, count: int, reason: int) -> bool                            # agregada (CAMP_REFILL)
func lose_items(def_id: StringName, count: int, reason: int) -> bool                             # agregada (CONSUME)
func add_xp(amount: int, source: int) -> ProgressionRules.XpResult
func charges() -> int                                             # byte de consumable_charges (§4.4)
func weapons() -> PackedInt32Array                                # ids de CombatCatalog; 0 = vacía
func stash_ready(weapon_id: int, ready: PackedInt64Array) -> void
func stashed_ready(weapon_id: int) -> PackedInt64Array
func build_section(seq: int) -> Dictionary                        # §9.3
func acknowledge(seq: int) -> void
func journal() -> Array[EconomyOp]                                # sin plataforma: las últimas 256

class_name ProgressService extends RefCounted
class Loadout:
	var weapon_1: int; var weapon_2: int; var second_active: bool; var charges: int
func setup(zone: ZoneServer, platform: ZonePlatform, saver: CharacterSaver,
		commands: CommandRegistry) -> void                             # platform y saver null sin plataforma
func start(s: int) -> void; func is_ready_to_open() -> bool         # primer bloque de ids
func prepare(peer_id: int, record: CharacterRecord) -> bool         # §9.1 paso 2
func on_arrival(entity: NetEntity, peer: ServerPeer, s: int) -> Loadout
func after_spawn(entity: NetEntity, peer: ServerPeer, s: int) -> void
func loadout_for(net_id: int) -> Loadout                            # también al reaparecer
func has_inventory(net_id: int) -> bool; func level_of(net_id: int) -> int
func handle_packet(peer: ServerPeer, bytes: PackedByteArray) -> void   # 0x50 y 0x53
func after_simulate(s: int) -> void                                 # CONSUME
func camp_step(entity: NetEntity, s: int) -> void                   # CAMP_REFILL
func apply_pending(s: int) -> void                                  # peticiones, tras las altas
func on_merits(net_id: int, amount: int, reason: int, victim_net_id: int, s: int) -> void
func on_npc_killed(npc: NpcDefinition, contributors: PackedInt32Array, s: int) -> void
func on_capture(fortress_id: StringName, owner_realm: int, in_circle: PackedInt32Array, s: int) -> void
func on_platform_event(event: PlatformEvent) -> bool                # true si era suyo
func on_departure(net_id: int) -> void                              # tras CharacterSaver.finish
func flush(s: int) -> void                                          # WALLET_UPDATE y PROGRESS_UPDATE

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
# humanoid_visual.gd: set_part y clear_part de §7.4
```

`test_architecture` se amplía:

- `scripts/shared/progression/` no nombra `Time`, `OS`, `Input` ni nada de `scripts/client/` o
  `scripts/server/`;
- ningún recurso de `data/items/` ni de `data/characters/` tiene propiedades `Texture2D`, `PackedScene`
  o `Mesh`;
- `scripts/server/progress/` no lee `Time`;
- ningún `class_name` se repite en `scripts/` ni en `tests/` (Godot registra en silencio solo uno de
  los dos).

## 15. Pruebas

Cada una dura menos de 30 s con el ejecutor actual (`run_tests.gd`) o con `go test` (caché caliente).

| Paquete | Prueba | Qué comprueba |
|---|---|---|
| P1 | `test_item_database` | ids únicos y con formato; todos los `.tres` en texto (empiezan por `[gd_resource`); coherencia de §2.1 (ARMOR con `tests/fixtures/items/`); `ref_id` que existen; un objeto por arma y consumible de las plantillas; net ids alfabéticos; `wire_hash` estable entre dos cargas |
| P1 | `test_item_instance` | Ida y vuelta de 1000 instancias aleatorias con semilla, en binario y en diccionario; null en cada caso de §2.3 (truncado, formato 2, uid 0, uid 2^53, net id desconocido, cantidad 0 o > pila, 7 afijos) |
| P2 | `test_inventory_ops` | Tabla de casos: cada op y cada código de §4.2, en su orden; juntar parcial; pila de destino llena → intercambio; ligado al equipar; ranuras 2–6 → CANNOT_EQUIP; DESTROY de un consumible bebiendo → NOT_NOW; solo DESTROY da eventos |
| P2 | `test_inventory_properties` | 20 semillas × 1000 operaciones aleatorias (válidas e inválidas), con invariantes incrementales (cantidad por definición y uids vivos y muertos, que actualizan los eventos de cada `Outcome`) y la comprobación completa cada 100 operaciones y al final: la cantidad no cambia sin evento, ningún uid se repite ni vuelve, ranuras únicas, la activa con arma; tras CAMP_REFILL, `count_of(def) ≤ max(camp_refill, antes)`, con un caso de tabla de la pila dividida. Menos de 5 s medidos. La versión larga (20 × 5000) solo con `--filter=inventory_properties_long` |
| P2 | `test_currency_rules` | Topes, negativos, dos operaciones del mismo tick sobre un saldo, reconstrucción desde los apuntes |
| P2 | `test_action_machine_weapons` | `set_weapons` conserva cargas, `consumable_ready_tick` y ranuras de movimiento; reparte `ability_ready` por arma; con acción, no hace nada |
| P3 | `test_level_curve` | 39 valores crecientes; `level_for(total_to(n)) = n`; varias subidas con un solo aporte; tope |
| P3 | `test_character_appearance` | Ida y vuelta de 8 B; `validate` rechaza cada índice fuera de rango y la raza de otro reino; 100 aleatorias válidas por raza; `appearance_ids.txt` es prefijo del catálogo; el catálogo solo nombra escenas que existen; `stat_modifiers` vacío |
| P3 | `test_progression_rules_export` | `build()` da lo mismo dos veces y contiene las tres razas, los objetos, la curva, los topes y los rangos de motivos (el archivo lo compara `test_platform_gamedata.gd`) |
| P4 | `test_progress_messages` | Ida y vuelta de 0x50–0x55, SPAWN con nivel y apariencia y LEVEL_UP; null con cada malformación; ninguno pasa de 1200 B; DEBUG 40–43; `encode_spawn` con un receptor de otro reino da `level` 0 |
| P5a | `test_progress_record` | Ida y vuelta de `ProgressRecord` por `JSON.stringify` y `parse_string`, campo a campo; `{}` es un personaje nuevo; ignora `zone_id` y `ops`; null con una clave desconocida, un id no entero o ≥ 2^53 |
| P5a | `test_player_progress` | Kit de inicio (por plantilla y por defecto); agregación (un apunte por moneda, motivo y referencia); el cierre antes de una operación suelta (ganancia, `currency_add`, guardado: S3 cuadra); `build_section` y `acknowledge`; reserva de ids; ninguna habilidad ni consumible de `CombatCatalog` dura 30 s o más |
| P5a | `test_progress_section` | Con `FakeZonePlatform` (plataforma.md P4): sección registrada; reintento con el mismo cuerpo; `duplicate` confirma; `lease_lost` descarta; 400 expulsa y libera; `schema_mismatch` conserva; `prepare` con un `progress` roto → REJECT `UNAVAILABLE` y liberación |
| P5a | `test_progression_fixtures` | Los casos de `tests/fixtures/progression/` coinciden con los que genera `write_fixtures.gd` |
| P5b | `test_progress_service` | Alta con el `Loadout` del inventario y la ranura activa; equipar y desequipar sin reiniciar reutilizaciones; CONSUME al comprometer y no al interrumpir; CAMP_REFILL por total y con la cadencia de habilidades.md; cargas `min(15, bolsa)`; peticiones antes del mundo → aviso; un cliente que manda 10 000 SPLIT y juntar: ningún evento, ids acotados por RATE y otro jugador sigue bebiendo y guardando; `/atascado` restaurado por su clave |
| P5c | `test_progress_rewards` | Méritos de una víctima persistente de otro reino → apunte y XP; matar a un falso o a un PNJ no da méritos; PNJ con dos contribuyentes → los dos cobran; dos capturas en 30 min pagan una; `--fake-players` con plataforma → nada; subida de nivel → LEVEL_UP solo al mismo reino y crítico |
| P5d | `test_gm_progress` | Da un objeto, lo divide en 3 y 2, junta las 2 con otra pila y lo revierte: el total baja 5 y se encuentran el GM_GRANT, la REVERSAL y sus apuntes; segunda reversión rechazada; con plataforma falsa y rol `player`, el id 41 no cambia el saldo y suma un aviso; un `gm` sobre su propio personaje, rechazado; `level_set` deja `detail` con antes y después |
| P6 | `test_client_inventory`, `test_inventory_window` | Optimista, confirmación, rechazo que devuelve el objeto, deltas del servidor intercalados, plazo de 5 s; arrastrar, dividir y destruir simulados generan la petición correcta |
| P6 | `test_appearance_visual` | Todas las combinaciones de piezas que existen (cuerpo, cabeza, pelo y barba, con y sin) con un color aleatorio cada una, y 100 aleatorias, aplicadas a `HumanoidVisual` sin errores del motor; `set_part` no recrea el nodo |
| P7 | Go: `TestApply*` | Cada caso de los fixtures con su resultado; S1–S8 uno a uno; `characters.level` copiado; auditoría con `op:<op_id>` sin duplicar |
| P7 | Go: `TestWalletConcurrency` | Dos transacciones a la vez sobre un saldo (§5.4); reconstrucción del saldo |
| P7 | Go: `TestTwoCharacterOp` | Una operación con dos participantes en una transacción; el mismo participante dos veces falla |
| P7 | Go: `TestPurgeKeepsLedger`, `TestRetention` | Purga de un personaje con apuntes dentro de la purga de la cuenta: la cuenta queda como lápida y el libro sigue; con el reloj a +366 días, `PurgeRetention` lo borra y deja las operaciones de otros |
| P7 | Go: `TestRoutes` | `GET` de operación (con las filas retiradas) y de libro con paginación; 404 |
| P8 | `test_progress_loopback` | Dos clientes por `NetHarness`, sin plataforma: equipar el arco desde la bolsa cambia el arma del otro por LOADOUT, la barra y 0 correcciones sin explicar; un rechazo devuelve el objeto; un cliente de otro reino recibe `level` 0 y uno del mismo, el real; beber gasta una poción de la bolsa |
| P8 | `test_progress_platform_loopback` | Con `FakeZonePlatform` y billetes de prueba: primera entrada con LOADOUT_SELECT `marksman` → kit; beber, reponer, `/atascado`; salir y volver conserva uids, equipo, arma activa, saldos y la reutilización de 5 min (menos lo transcurrido); vuelve al campamento |
| P8 | Go: `platform/e2e/progress_test.go` | `TestProgressEndToEnd`: plataforma en el proceso, PostgreSQL efímero, `test_world` con `--platform --debug-commands`, cuenta `admin` y `--bot --bot-scenario=progress --report=<ruta>` (equipa el arco, da 50 de oro y una poción por DEBUG_COMMAND y sale); `Load` de la BD frente al informe del bot, campo a campo. `TestProgressCrash`: lo mismo con `kill -9` a la zona tras el delta del oro; por SQL, Σ `delta` = saldo, por definición Σ `count_delta` = Σ `count` vivas, y el bot vuelve a entrar con lo mismo |

**PostgreSQL en esta máquina (comprobado).** Docker está instalado pero sin demonio: las pruebas no
dependen de él. El arnés es `internal/testdb` de plataforma.md §2.6: `initdb` no corre como root, así
que cada orden va con `runuser -u postgres --` sobre una carpeta suya, y el servidor escucha solo en un
socket Unix con `fsync`, `synchronous_commit` y `full_page_writes` apagados. Medido con la sonda de este
documento (clúster, esquema de §3.3 y los casos de §3.3 y §3.5): 0,9 s en total. Go 1.24 baja los
módulos por el proxy.

## 16. Pendiente del usuario

| Qué | Para qué | Mientras tanto |
|---|---|---|
| Cuerpo femenino y más cabezas, peinados, barbas y marcas (ART-20): comprar la Source de Universal Base Characters o importar más piezas del Standard desde `../Eldmark-raw/` | La variedad por raza de §7.1 y el índice `body = 1` | El catálogo solo lista lo que hay: un cuerpo, una cabeza, `Hair_SimpleParted` y `Hair_Beard`; las razas difieren en colores permitidos |
| Iconos de los cuatro objetos (ART-12) | Inventario y tooltip | `icon_path` vacío: el casillero pinta el nombre corto con el color de la categoría |
| Visto bueno visual de la apariencia y de las dos ventanas | UI-26, ART-19 | Lo provisional queda marcado con `# TODO(arte)` |
| Revisión legal de la retención de un año del libro tras la purga | RGPD, con las de plataforma.md §11 | La cifra es provisional |
| Las decisiones provisionales de §0 | | Se aplican tal cual |

## 17. Riesgos

| Riesgo | Mitigación |
|---|---|
| Dos validaciones (GDScript y Go) que divergen | Los mismos casos, generados por `write_fixtures.gd`, subidos al repo y comprobados por las dos (§13.3) |
| Precisión de JSON: un id de 2^53 o más se corrompe sin avisar en Godot | Todos los ids salen de secuencias y bloques desde 1; la zona y el servicio rechazan los que no sean enteros por debajo de 2^53 (§3.4, S1) |
| Net ids alfabéticos: añadir un objeto cambia los de los demás | Entran en el `sim_hash`; la BD nunca guarda net ids; a otros clientes nunca viajan |
| Reutilizaciones de menos de 30 s: reconectar las reinicia | Las limita el tiempo de reconexión y, en combate, el cuerpo que se queda 15 s (GUE-41); se revisa con la telemetría |
| Encaje con habilidades.md: `set_weapons`, el reparto de cargas y el cambio de la recarga dependen de H1b, H3c y H4 | Los nombres de habilidades.md mandan; si cambian, se ajustan §4.1, §4.4 y §8 al integrar |
| Encaje con plataforma.md: la sección, el gancho del WELCOME, la purga y la retención dependen de lo pedido en §13.1 | Si plataforma.md no lo adopta, este documento se cambia antes de P5a y P7 |
| Sin persistencia local sin plataforma (el usuario desarrolla en Windows) | `deploy/dev.sh` o el compose de plataforma.md; sin ellos, todo funciona en efímero |
| Abuso con dividir y juntar, o con clientes que gastan ids | No dejan eventos (§4.3), RATE de 2/s para lo que gasta ids y reserva del servidor (§4.5) |
| Volumen del guardado | Unos 40 objetos (~4 KB de JSON) y una GAMEPLAY por guardado; con 1000 jugadores y un guardado por minuto, ~70 KB/s hacia el servicio. Se mide en TEC-25 |
| Retención de un año: datos de un personaje purgado | Seudónimos sin cuenta detrás; revisión legal (§16) |

## 18. Revisión

Tres revisores (seguridad, coherencia e implementabilidad): 41 hallazgos sobre la versión 1, los
repetidos en una fila. Comprobados en el código, en plataforma.md (0f6781b) y en habilidades.md
(32e23af): todos se sostienen. En ocho filas la solución es otra que la propuesta o se queda en parte
(«en parte», «de otra forma»). Lo que pide cambiar en plataforma.md está en §13.1.

| Id | Gravedad | Qué era | Qué se hizo |
|---|---|---|---|
| PR-SEG2 · PR-COH2 · PR-IMP1 | bloqueante | Dos tuberías de carga y guardado incompatibles con plataforma.md: WELCOME antes del un solo uso y las sanciones, `begin_load` sin `lease_token`, dos idempotencias (`save_id`/`base_version` frente a `lease_id`/`seq`), dos generadores de uid, JSON distinto (cadenas frente a números, campos repetidos en `state`), raza y apariencia distintas | El progreso es la sección `progress` de `CharacterSaver`; llega en la reclamación y `prepare` corre antes del WELCOME; idempotencia `(lease_id, seq)`; fuera `save_id`, `base_version`, `save_version`, VERSION_CONFLICT y la antigua S2; un solo generador (`item_uid_blocks`); vida, posición y tiempo jugado solo en `state`; números < 2^53; `race_<reino>` y 8 B pedidos a plataforma.md (§0, §3, §9, §13.1). **En parte**: sin `starter_template_id` al crear (la plantilla se elige en la primera entrada) |
| PR-COH1 · PR-IMP2 | bloqueante | Dos `class_name CharacterRecord` (Godot registra solo una) | La de aquí es `ProgressRecord`; `CharacterRecord` es de plataforma.md y lleva `progress`; `test_architecture` prohíbe `class_name` repetidos (§14.2) |
| PR-SEG1 · PR-COH4 · PR-IMP7 | bloqueante | El disparador de solo añadir abortaba la cascada desde `characters`: ni purga horaria ni supresión de cuenta, y sin camino para «un año después» | Tablas de solo añadir sin clave ajena; lápida con `Purge`; retención a un año con `set local eldmark.retention_purge`; exportación; comprobado en PostgreSQL 16; pruebas de Go (§3.3, §3.5, §15). **En parte**: los `ref_id` no se ponen a 0 (sería un UPDATE en el libro y ya son seudónimos) |
| PR-COH3 · PR-IMP3 | bloqueante | Nadie diseñaba el lado Go del progreso; esquemas que se pisaban; rutas de operación y libro inexistentes | P7 es de aquí: `platform/internal/progress/`, migración 0010 con `world_id`, S1–S8, rutas, retención y pruebas, con dependencias de plataforma.md P0 y P3; `character_progress` sin lo que guarda plataforma.md (§3.3, §13.2, §14.1) |
| PR-COH5 · PR-IMP4 | bloqueante | `EquipmentState`, `StatBlock`, hoja derivada, armaduras e ids visuales que habilidades.md deja fuera y nadie diseña | Decisión provisional: en la fase 5 solo armas y pociones; ranuras 2–6 reservadas; `ActionMachine.set_weapons` que conserva reutilizaciones y cargas, y LOADOUT con `template_id` 0; criterio de UI-26 anotado en el backlog (§0, §4.1, §11) |
| PR-SEG3 · PR-COH11 | importante | Con `--debug-commands` y `--platform`, cualquiera se daba oro, XP y objetos persistentes; `currency_add` por red sin motivo | DEBUG_COMMAND con plataforma exige `gm` (40–43, `admin`); `ServerMain` no arranca en staging o producción con los dos; nota «debug»; prueba en `test_gm_progress` (§10). **En parte**: sin texto libre en el id 41 |
| PR-SEG4 | importante | Comandos de GM sin rastro en la BD o con rastro que se podía perder; actor sin comprobar; GM que se regala; roles distintos | `note` y `detail` en `economy_ops`; S2 comprueba el rol y la propia cuenta; el guardado escribe la auditoría con `op:<op_id>`; consultas para `gm` (§3.3, §10, §13.3) |
| PR-SEG5 | importante | CAMP_REFILL por pila: dividir daba pociones sin límite | Reposición por total de la definición; propiedad y caso de tabla (§4.4, §15) |
| PR-SEG6 | importante | Dividir y juntar gastaban ids y llenaban el libro; un cliente agotaba los bloques de la zona | Mover, dividir y juntar sin eventos ni `op_id`; RATE de 2/s para lo que gasta ids; reserva de 256 para el servidor; sin `save_id`; prueba con 10 000 peticiones (§4.2, §4.3, §4.5) |
| PR-SEG7 | importante | Méritos y XP de víctimas falsas o PNJ; capturas sin freno | Méritos de baja solo por víctimas persistentes de otro reino; PNJ solo `xp_reward` y `gold_reward`; captura una vez cada 30 min por fortaleza; sin recompensas con `--fake-players` y plataforma (§6.2). **En parte**: la captura sin defensores sigue pagando (en el Vado Gris es la de los Huecos; GUE-35) |
| PR-SEG8 · PR-COH9 | importante | El SPAWN se codificaba una vez para todos: nivel real al enemigo; net id de objeto como id visual | `encode_spawn(tick, for_owner, receiver_realm)` y tres variantes por reino; sin bloque de equipo ni net ids hacia otros (las armas van en `CombatState`); `visual_id` previsto para PRG-05 y PRG-06; pruebas (§2.1, §7.3) |
| PR-SEG9 | importante | Una operación de dos personajes no cabía en el esquema; traspaso sin congelar | `op_participants` con S2 por `(op_id, character_id)`; traspaso con congelación y HANDOFF tras el OK (§3.3, §8) |
| PR-COH6 | importante | Vida, posición, nivel, tiempo jugado, raza y apariencia en dos sitios con reglas opuestas | Un dueño por campo (§3.1); reglas de plataforma.md para posición y vida; `characters.level` lo escribe P7 |
| PR-COH7 · PR-IMP8 | importante | CMB-30 sin dueño, con semánticas opuestas y ganchos inexistentes | Es de aquí; el tiempo corre (UTC con `ZonePlatform.now_unix()`); en la fase 5 solo `unstuck` y `capture:<id>`, con `get_ready_at`/`set_ready_at` por personaje; efectos largos aplazados; billete de 52 B (§8). **En parte**: la imposición de `ability_ready` no se escribe hasta que exista una reutilización de 30 s (una prueba lo vigila) |
| PR-COH8 · PR-IMP5 | importante | Pociones contra el modelo de habilidades.md: cargas predichas, gasto al empezar, recarga gratis | Cargas `min(15, bolsa)` con `set_charges`; CONSUME en el compromiso; la recarga de habilidades.md se sustituye por CAMP_REFILL con su cadencia; pila de 15 (§4.4) |
| PR-COH10 · PR-IMP9 | importante | Creación sin `starter_template_id`, razas distintas, dos archivos de reglas, apariencia de 0–64 B; `go:embed` no admite `..` | Un solo `progression_rules.json` dentro de `platform/internal/gamedata/`, escrito por la herramienta de plataforma.md con `ProgressionRulesExport`; 8 B y `race_<reino>` pedidos (§13.1). **En parte**: sin `starter_template_id` al crear |
| PR-COH12 | importante | Mensajes nuevos que `NetClient` y `SwarmBot` contaban como malformados; «efímero» mal definido | La recepción va en P4; `test_bot_swarm` y `test_net_processes` siguen en 0; efímero = sin plataforma; los falsos, sin inventario (§4.6, §9.4) |
| PR-IMP6 | importante | Una operación suelta a mitad de minuto rompía S3 por las ganancias sin apuntar; nadie ponía `seq` | Se cierra lo agregado antes de cada operación suelta; `seq` lo pone el servicio; caso en `test_player_progress` (§5.2) |
| PR-IMP10 | importante | P5 demasiado grande, sin ganchos ni dependencias, primer bloque sin definir | P5a a P5d con sus ganchos en `ZoneServer`, dependencias de PRG-09, MUN-07 y GUE-12, y primer bloque antes de abrir el puerto (§4.5, §9, §14.1) |
| PR-IMP11 | importante | Pruebas que no demostraban PRG-10 ni TEC-25; casos escritos por pruebas; Askarra cerrada | Prueba de extremo a extremo con PostgreSQL y `kill -9`; casos generados por herramienta y subidos; criterio de PRG-14 anotado en el backlog (§15) |
| PR-IMP12 | importante | 20 × 5000 operaciones no cabían en 10 s | 20 × 1000 con invariantes incrementales, menos de 5 s; la larga, aparte (§15) |
| PR-IMP13 | importante | Lo que necesita al usuario sin marcar; catálogo con piezas que no existen; `HumanoidVisual` sin API para cambiar piezas | Tabla «Pendiente del usuario»; el catálogo solo lista lo que hay; `set_part` y `clear_part` (§7, §16) |
| PR-SEG10 | menor | La red de seguridad dejaba pasar `starter_granted`, `bound` y `bag_slots` hacia atrás, I8, I9 y uids fuera de la unión | I12; S2, S4, S5 y S6 los comprueban; conservación por definición sobre la BD, la foto y los eventos (§3.2, §13.3) |
| PR-SEG11 | menor | `--progress-file` persistía sin autenticación ni bloqueo y delataba reinos | **De otra forma**: se quita el modo; sin plataforma nada se guarda y la persistencia local usa `deploy/dev.sh` (§0, §9.4) |
| PR-SEG12 | menor | Dividir o juntar esquivaba una reversión | La reversión quita la cantidad de la definición en todo el personaje (§10). **En parte**: sin `parent_uid`, que deja de hacer falta |
| PR-COH13 | menor | Versión del protocolo sin coordinar | Una sola para la fase 5, compartida, con la regla de quién la sube (§12) |
| PR-COH14 | menor | La apariencia en el `sim_hash` rechazaba clientes sin motivo | Fuera; `ItemDatabase` se queda y red.md §3 y el texto del REJECT cambian (§12) |
| PR-COH15 | menor | PRG-13, el billete de 47 B, `escudero` y MUN-07 desfasados | PRG-13 y la decisión, en el backlog; 52 B; `squire`; MUN-07 en P5c |
| PR-IMP14 | menor | MOVE sobre pila llena, pociones en dos reglas del kit, `smallint[]`, textura en `data/characters/`, motivo del id 41, reino en JSON | Intercambia; regla 2 sin `camp_refill`; `integer[]` 0–65535; `texture_path`; «debug»; sin reino en `progress` (§2.5, §3.3, §4.2, §7.2, §10) |
