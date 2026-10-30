# Eldmark · Fase 5: diseño de la progresión

Diseño de lo que se guarda de un personaje y de lo que se juega con ello en el paso 5 de la
[hoja de ruta](vision.md#hoja-de-ruta): objetos (PRG-02), qué se guarda y sus invariantes (PRG-10),
inventario autoritativo (PRG-11), monedas y libro mayor (PRG-12), niveles (PRG-13), razas (PRG-14),
herramientas de GM (PRG-16), configuración de combate persistente (CMB-30), apariencia (ART-19) y la
ventana de inventario y personaje (UI-26).

Versión 2: la 1 tras la revisión de tres revisores (§18), conciliada después con plataforma.md (§13.1).
Lo marcado «comprobado» sale de sondas en esta máquina (Godot 4.7.2 headless, PostgreSQL 16, Go 1.24) que
no se suben.

Se apoya en [red.md](red.md), [combate.md](combate.md), [fuerte.md](fuerte.md), [social.md](social.md)
y `docs/habilidades.md` (fase 4, ya fusionado en `fase4-fuerte`). Con **`docs/plataforma.md`**
(TEC-22 a TEC-28), escrito a la vez, el reparto es este:

- **plataforma.md**: servicio, cuentas, billete, reclamación, arrendamiento, `CharacterSaver` (cuándo y
  cómo se guarda), API interna, bloques de ids, purgas y RGPD.
- **Este documento**: qué va en la sección `progress` del guardado (posición, vida y tiempo jugado
  incluidos), sus invariantes, su almacén en Go (`platform/internal/progress/`, migración 0010 y las
  siguientes del progreso, paquete P7) y lo que se juega con ello. Lo acordado con plataforma.md está en la
  [sección 13](#13-interfaz-con-plataformamd).
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
| ¿Méritos gastables y puntos de reino separados? | **Dos contadores con el mismo evento** (fuerte.md §0): méritos gastables (moneda) y puntos de reino, que solo bajan al revertir los méritos que los dieron (I9) |
| ¿Quién recibe XP y crédito sin selección de objetivo? | **Contribución**: todo el que hace ≥ 10 % del daño en los últimos 900 ticks (`DamageLedger`, GUE-05), con recompensa personal (§6) |
| ¿Cambia el nivel las estadísticas en la fase 5? | **No.** La hoja base es la misma a cualquier nivel hasta que la zona PvE (PRG-22) y la normalización de Eldrun (PRG-31) lo activen. El Vado Gris es la única zona y es RvR |
| ¿Qué equipo hay en la fase 5? | **Las dos armas y las pociones.** Armaduras, `StatBlock` y hoja derivada esperan a PRG-01 y PRG-06, como en habilidades.md §9. Las ranuras de equipo 2–6 existen y quedan reservadas. *Provisional, tomada de noche* |
| Unidad del oro | Un solo entero, «oro», sin plata ni cobre |
| ¿Se equipa en combate? | No: equipar y desequipar solo fuera de combate y sin acción en curso. El cambio entre las dos armas (Q, CMB-24) sí vale en combate |
| Plantillas de la fase 4 (PRG-07) | Se convierten en el **kit de inicio** (§2.5). La plantilla se elige **al crear** el personaje (UI-24, plataforma.md §4.4) y es el kit de la primera entrada |
| Pociones (PRG-08) | Objetos apilables y ligados. Las cargas de `CombatState` son las pociones de la bolsa (tope 15). El campamento repone el **total** a 3 de vida y 2 de resistencia, las cargas del escudero (§4.4) |
| ¿De quién es CMB-30? ¿Corre el tiempo sin conexión? | **De este documento** (§8). **Sí**: las reutilizaciones largas se guardan con su fin en UTC. En la fase 5 solo `/atascado` llega a 30 s. *Provisional, tomada de noche* |
| Carga, guardado e idempotencia | **Los de plataforma.md**: el progreso es la sección `progress` de `CharacterSaver`, llega en la reclamación antes del WELCOME y cada guardado se aplica una vez por `(lease_id, seq)` (plataforma.md §5.2 y §7; aquí, §9) |
| Posición y vida | Van en el registro de §3.4; la regla de volver al mundo es la de §8. En las zonas RvR (todas las de la fase 5) se vuelve al campamento del reino |
| Enteros en JSON | **Ids como cadena y el resto como número** (plataforma.md §4.1). Comprobado en Godot 4.7.2: `JSON.stringify` escribe un int64 exacto, pero `JSON.parse_string` devuelve `float` (lee 2^53 + 1 como 2^53). Aun así, todos los ids salen de secuencias y bloques que empiezan en 1 y quedan por debajo de 2^53 |
| Sin plataforma | **Nada se guarda.** Todo personaje es efímero, con inventario en memoria. No hay modo de archivo local. *Provisional, tomada de noche* |

Siguen **pendientes** (fase 6) y el modelo admite cualquier respuesta: reglas de ligado (el campo
existe; los objetos de inicio van ligados), penalización por morir (la durabilidad existe y no baja en
la fase 5), formato de los datos de diseño (en la fase 5, `.tres` a mano) y nivel en Eldrun.
`vision.md` («Por definir: razas») se actualiza al integrar.

## 1. Qué es de quién

| Pieza | La decide | Dónde |
|---|---|---|
| Contenido de la sección `progress` (raza, apariencia, posición, vida y tiempo jugado incluidos), invariantes, objetos, inventario, libro, niveles, reglas de raza y apariencia, CMB-30, lista de eventos críticos, regla de volver al mundo | Este documento | §2–§12 |
| Almacén en Go del progreso: migración 0010 y las siguientes del progreso, comprobaciones S1–S8, purga y retención del libro, exportación, cuerpos de las rutas de operación y libro, reglas exportadas | Este documento (P7) | §3.3, §3.5, §13 |
| Servicio, billete, reclamación, arrendamiento, `CharacterSaver` (cuándo, `seq`, respuestas), API interna, bloques de ids, lápida y purgas, archivo de exportación (RGPD) | plataforma.md | Sus §5–§8 y §11 |
| Identidad y nombre (`characters`); validación de raza, apariencia y plantilla al crear | plataforma.md, con las reglas exportadas de aquí | §7, §13.4 |
| Roles, auditoría, sanciones | plataforma.md y social.md | SOC-13, SOC-14, SOC-18 |
| Armas en `CombatState`, LOADOUT, `set_loadout`, `set_charges`, plantillas, pociones, recarga | habilidades.md (H1a–H3c) | Para quien tiene inventario, §4.1 y §4.4 |
| Armaduras, `StatBlock`, hoja derivada, ids visuales por ranura | PRG-01, PRG-05, PRG-06 y el resto de PRG-04: después de la fase 5, sin diseño | §4.1, §7.3 |
| Méritos: reparto y antifarmeo | PRG-09 | Aquí solo se filtran y se apuntan (§6.2) |
| Estadísticas PvP; atributos, maestrías, habilidades elegidas, rareza y afijos | plataforma.md (GUE-19); fase 6 (PRG-17 a PRG-20) | Los campos de objeto ya existen (§2); sus tablas llegan con sus entradas |

**Qué se juega en la fase 5.** El jugador entra con su cuenta (UI-22) y crea un personaje (reino,
apariencia de su pueblo, plantilla y nombre; UI-24). En su primera entrada aparece en el Vado Gris con el
kit de su plantilla. Pelea como en la fase 4 y gana méritos, puntos de reino, XP y algo de oro de los
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

En la **primera entrada** al mundo (`starter_granted = false`), al dar de alta al personaje
(`ProgressService.on_arrival`), la zona crea el kit en una sola operación STARTER_KIT y marca el guardado
como crítico (`CharacterSaver.track` ya se ha llamado al crear la entidad, plataforma.md §14.3). La plantilla es, con plataforma, el `starter_template_id` del registro: se elige al crear el
personaje (UI-24), la valida la plataforma con `starter_templates` (las `EquipmentTemplate` con
`selectable = true`, §13.4; plataforma.md §4.4) y se guarda en `character_progress`. En los personajes
efímeros (§9.4) es `ServerPeer.pending_template_id` (la que mandó LOADOUT_SELECT antes de CLIENT_READY;
habilidades.md §4.6) o, si no hay, `default_template`:

1. Cada arma de la plantilla → su objeto (`ItemDatabase.for_ref`), puesto en las ranuras de equipo 0 y
   1 por el orden de la plantilla.
2. Cada objeto de inicio sin `camp_refill` que no haya quedado puesto (las armas de las demás
   plantillas) → una unidad en la bolsa, desde la ranura 0 por orden de `id`.
3. Cada objeto con `camp_refill > 0` → una pila con esa cantidad en la bolsa.

Así se conserva la libertad de la fase 4 (cambiar de estilo) dentro del inventario. Se guarda
`starter_granted = true`. Una plantilla desconocida usa la primera por orden de `id`, con aviso en el
registro.

Para quien tiene inventario, LOADOUT_SELECT no cambia nada tras el alta (un id que no existe sigue
sumando el aviso de habilidades.md §5.1) y la reaparición toma las armas de su equipo, no de la
plantilla. El cliente no muestra el selector a quien entra con billete y, sin plataforma, lo oculta tras
la primera aparición. Los **jugadores falsos** (`--fake-players`) no tienen inventario: siguen con su
plantilla (`--fake-loadout`) y la recarga de habilidades.md §4.6.

## 3. El personaje que se guarda (PRG-10)

### 3.1 Qué se guarda (un dueño por campo)

La única tabla de quién guarda qué; plataforma.md §3 la cita. Todo son columnas: no hay `characters.state`
ni JSON de estado.

| Grupo | Campos | Dónde | Dueño |
|---|---|---|---|
| Identidad | `character_id`, `account_id`, `world_id`, `realm`, `name`, `name_key`, fechas, borrado con gracia, renombrado obligatorio, lápida | `characters` | plataforma.md |
| Raza y apariencia | `race_id`, `appearance` (8 B exactos, §7.2) | `character_progress` | Este documento; la plataforma los valida al crear con las reglas exportadas (§7.2, §13.4) |
| Posición, giro, vida, tiempo jugado | `last_zone_id`, `last_channel`, `pos_x`, `pos_y`, `pos_z`, `yaw`, `last_in_combat`, `health`, `played_seconds` (también para SOC-38) | `character_progress` | Este documento (§3.4, §8) |
| Nivel | `level`, la única copia (la lista de personajes, UI-23, lo lee con `ProgressStore.Summaries`) | `character_progress` | Este documento |
| Progreso | `xp_total`, `realm_points`, `bag_slots`, `starter_template_id`, `starter_granted` | `character_progress` | Este documento |
| Inventario | Una fila por instancia | `item_instances` | Este documento |
| Monedas | Saldo por moneda y el libro mayor | `character_wallets`, `ledger_entries` | Este documento |
| Operaciones | Operaciones, participantes, eventos de objeto y reversiones | `economy_ops`, `op_participants`, `item_events`, `op_reversals` | Este documento |
| Combate (CMB-30) | `active_weapon_slot` y temporizadores largos | `character_progress`, `character_timers` | Este documento (§8) |
| Guardado | `saved_at`, `save_version` | `character_progress` | Las columnas, este documento; la regla, plataforma.md §7.3 (los escribe `Apply`, S8) |
| PvP | Totales | `character_pvp_stats` | plataforma.md (GUE-19) |
| Arrendamiento y bloques de ids | `lease_id`, `seq`, hash y `save_version` (`last_save_version`) del último guardado; bloques dados a cada instancia | `character_leases`, `id_blocks` | plataforma.md |

No se guardan las habilidades elegidas (en la fase 5 son el kit fijo del arma, habilidades.md §2.3) ni
las cargas de pociones (son las pociones de la bolsa, §4.4).

### 3.2 Invariantes

Los comprueban la zona al aplicar y el servicio al guardar (§13.3, S1–S8).

| # | Invariante |
|---|---|
| I1 | Un `uid` identifica una sola instancia en todo el mundo y nunca se reutiliza, ni tras destruirla (la fila retirada se queda). Mientras vive conserva `def_id`, `seed`, `rarity` y `affixes`: solo cambian `count`, `durability`, `bound` (de false a true, I12), contenedor y ranura |
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

Es el único DDL del progreso (plataforma.md §3 lo cita); lo escribe P7, con su `.down.sql` y la semilla de
conservación `internal/migrate/testdata/seed_0010.sql` (plataforma.md §2.4). Ninguna tabla lleva
`world_id`: sale de `characters`, que no se borra mientras queden filas del personaje (lápida,
plataforma.md §11.2). Las de **estado** cuelgan de `characters` con `on delete cascade`. Las de **solo
añadir** llegan a `characters` por `op_participants`, con clave ajena **sin cascada**: un `delete from
characters` con libro falla, nunca a medias, y se borran por retención (§3.5). Comprobado en PostgreSQL 16
con sondas en `build/` (la de este documento y la de plataforma.md §2.6): restricciones, disparador,
operación de dos personajes, uid retirado que no se reutiliza, intercambio de ranuras con la restricción
diferida, lápida y retención a un año.

```sql
create table character_progress (character_id bigint primary key references characters on delete cascade,
  race_id text not null, appearance bytea not null check (length(appearance) = 8),
  starter_template_id text not null, starter_granted boolean not null default false,
  level smallint not null default 1 check (level between 1 and 40),
  xp_total bigint not null default 0 check (xp_total >= 0),
  realm_points bigint not null default 0 check (realm_points >= 0),
  played_seconds bigint not null default 0 check (played_seconds >= 0),
  bag_slots smallint not null default 30 check (bag_slots between 1 and 120),
  health int check (health >= 0),                                               -- null: llena
  active_weapon_slot smallint not null default 0 check (active_weapon_slot between 0 and 1),
  last_zone_id text, last_channel smallint, pos_x real, pos_y real, pos_z real, yaw real,   -- null: nunca ha entrado
  last_in_combat boolean not null default false,
  saved_at timestamptz,                                                         -- now() de la plataforma al aplicar
  save_version bigint not null default 0);                                      -- contador; no es la idempotencia
```

Sin `consumable_def_id` (las pociones son fijas, R y T) ni `updated_at` (es `saved_at`). `characters` no
gana `level` ni `state`.

| Tabla | Columnas | Claves y restricciones |
|---|---|---|
| `character_wallets` | `character_id`, `currency smallint` (1 oro, 2 méritos), `balance bigint`, `last_seq bigint` | PK (`character_id`, `currency`), FK en cascada; CHECK `balance BETWEEN 0 AND 1000000000` |
| `item_instances` | `uid`, `character_id`, `container smallint` (0–3), `slot smallint` (0–119), `def_id text`, `count int` (1–999), `durability smallint` (0–1000; NULL = sin), `rarity smallint` (0–4), `bound bool`, `seed bigint` (0 … 2^32 − 1), `affixes integer[]` (≤ 6, cada uno 0–65535), `created_op bigint` (NULL = nació al dividir), `retired_at timestamptz` | PK `uid` (CHECK > 0), FK en cascada; CHECK `(retired_at IS NULL) = (container IS NOT NULL AND slot IS NOT NULL)`; UNIQUE (`character_id`, `container`, `slot`) **DEFERRABLE INITIALLY DEFERRED**; índice por `character_id` de las vivas |
| `character_timers` | `character_id`, `key text` (`^[a-z0-9_:]{1,48}$`), `ends_at timestamptz` | PK (`character_id`, `key`), FK en cascada (§8) |
| `economy_ops` | `op_id`, `kind smallint` (§5.3), `actor_account_id` (NULL salvo GM y REVERSAL; también NULL en ellas desde la consola), `ref_op_id` (la revertida), `zone_id text` (la de la instancia que guarda, `SaveKey.ZoneID`), `note text` (≤ 200), `detail jsonb`, `created_at` | PK `op_id` (CHECK > 0); CHECK `kind BETWEEN 1 AND 15`; CHECK: `kind` GM o REVERSAL ⇒ `note` no vacía. **Solo añadir** |
| `op_participants` | `op_id`, `character_id` | PK (`op_id`, `character_id`); FK `op_id` a `economy_ops` y `character_id` a `characters`, **sin cascada**; índice por `character_id`. **Solo añadir** |
| `ledger_entries` | `entry_id` (identidad), `character_id`, `currency`, `seq bigint`, `op_id`, `delta bigint`, `balance_after bigint`, `reason smallint`, `ref_kind smallint`, `ref_id bigint`, `created_at` | UNIQUE (`character_id`, `currency`, `seq`); FK (`op_id`, `character_id`) a `op_participants`; CHECK `delta <> 0`, `balance_after` 0 … tope; índice (`character_id`, `entry_id` desc). **Solo añadir** |
| `item_events` | `event_id` (identidad), `op_id`, `character_id`, `def_id`, `uid bigint` (NULL = agregado), `reason smallint`, `count_delta int`, `created_at` | FK (`op_id`, `character_id`) a `op_participants`; CHECK `count_delta <> 0`; índice (`character_id`, `op_id`). **Solo añadir** |
| `op_reversals` | `op_id`, `reversal_op_id` | PK `op_id`; UNIQUE `reversal_op_id`; las dos, FK a `economy_ops`: una operación se revierte una vez. **Solo añadir** |

`container`: 0 BAG, 1 EQUIPMENT, 2 BANK (PRG-25), 3 reservado; en la fase 5 solo 0 y 1. La restricción
de ranura es diferida para que un intercambio quepa en una transacción. Un `uid` que muere (destruido
o juntado con otro) no se borra: su fila queda **retirada** (`retired_at`, sin contenedor ni ranura) y la
clave primaria impide reutilizarlo. Las operaciones son de varios personajes desde ya
(`op_participants`): el comercio de la fase 6 guarda una sola operación con los dos.

El disparador de las cinco tablas de solo añadir (`economy_ops`, `op_participants`, `ledger_entries`,
`item_events`, `op_reversals`):

```sql
create function eldmark_append_only() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' and coalesce(current_setting('eldmark.retention_purge', true), '') = 'on' then
    return old;                                                                 -- solo la retención de §3.5
  end if;
  raise exception '% es de solo añadir', tg_table_name using errcode = 'P0001';
end $$;
create trigger append_only before update or delete on ledger_entries
  for each row execute function eldmark_append_only();   -- y lo mismo en las otras cuatro
```

`0010_progress.down.sql` quita disparadores, función y tablas en orden inverso. Las tablas de
atributos (PRG-17), maestrías (PRG-18) y habilidades elegidas (PRG-19) llegan con sus entradas, en
migraciones propias con el siguiente número libre (plataforma.md §2.4: las franjas solo valen en la fase 5).

### 3.4 `ProgressRecord` en JSON (`progress_format` 1)

Es la clave `progress` de la reclamación (plataforma.md §6, completa) y, sin los campos de solo lectura y
con el diario, la del cuerpo de cada guardado (§9.3). La construye `PlayerProgress.build_section` y la lee
`ProgressRecord.from_dictionary`; el almacén de P7 (`Load`) devuelve un personaje recién creado con los
valores por defecto. `progress_format` es `ProgressRecord.FORMAT`, el `record_format` que la zona declara
al registrarse (plataforma.md §7.1). Todo id (`uid`, `op_id`, `actor_account_id`, `ref_op_id`, `ref_id`,
`seed`) es una cadena decimal (plataforma.md §4.1) con un entero de 1 a 2^53 − 1 (`seed` y `ref_id`, desde
0); el resto de enteros son números exactos (`v == floor(v)`; se convierten con `int()`). Si no, la zona
rechaza el registro.

```json
{"progress_format": 1, "race_id": "race_vardheim", "appearance": "AQAAAQEDAgE=",
 "starter_template_id": "squire", "starter_granted": true, "level": 8, "xp_total": 12345,
 "realm_points": 420, "played_seconds": 5400, "bag_slots": 30, "active_weapon_slot": 0, "health": 820,
 "location": {"zone_id": "vado_gris", "channel": 0, "x": 12.5, "y": 0.0, "z": -40.25, "yaw": 1.57,
              "in_combat": false, "saved_at_unix": 1793282400},
 "wallets": [{"currency": 1, "balance": 150}, {"currency": 2, "balance": 3200}],
 "items": [{"uid": "1025", "def_id": "sword_shield_vado", "container": 1, "slot": 0, "count": 1,
            "durability": null, "rarity": 0, "bound": true, "seed": "0", "affixes": []},
           {"uid": "1027", "def_id": "potion_health", "container": 0, "slot": 1, "count": 3,
            "durability": null, "rarity": 0, "bound": true, "seed": "0", "affixes": []}],
 "timers": [{"key": "unstuck", "ends_at_unix": 1793282700}]}
```

- `appearance`: los 8 B de §7.2 en base64. `health`: entero; null = llena. `location`: null si nunca ha
  entrado; si no, zona, canal, posición y giro (de la entidad), «en combate» (del `Combatant`) y
  `saved_at_unix`. `played_seconds`: el cargado más lo jugado desde el alta.
- **Solo en la reclamación** (en el guardado no van y S1 los rechaza): `race_id`, `appearance`,
  `starter_template_id` y `location.saved_at_unix` (lo pone `Load` desde `saved_at`). `to_dictionary` da la
  forma del guardado y `to_claim_dictionary(saved_at_unix)` la de la reclamación, con ellos: la ida y vuelta
  de las pruebas es `from_dictionary(to_claim_dictionary(t))`.
- `items` son las instancias vivas. Los temporizadores van en segundos Unix. Las habilidades elegidas no
  se guardan en la fase 5 (§8).
- `from_dictionary` devuelve null ante una clave que falta o que no conoce, un tipo que no cuadra o un
  valor fuera de rango. Nivel y `xp_total` deben cumplir I8. La validez de la apariencia la mira
  `ProgressService.prepare` (§7.2, §9.1).

### 3.5 Retención y purga

| Qué | Cuánto | Cómo |
|---|---|---|
| Estado: progreso, saldos, objetos (vivos y retirados), temporizadores | Hasta la purga del personaje | `ProgressStore.Purge` |
| Operaciones, participantes, libro, eventos de objeto, reversiones | Mientras exista el personaje y **1 año** después de su purga (PRG-39) | La lápida de `characters` y `ProgressStore.PurgeRetention` |

- **Purga.** La de plataforma.md §11.2 (personaje al vencer `restore_until`, con la cuenta, y en
  `reapply-purges`) llama dentro de su transacción, ya con el arrendamiento y la fila de `characters`
  bloqueados y sin arrendamiento vivo, a `ProgressStore.Purge(ctx, tx, characterID)`, que
  borra `character_progress`, `character_wallets`, `item_instances` (también las retiradas) y
  `character_timers` y deja las de solo añadir. Después la plataforma hace lo suyo: la fila de
  `characters` queda como **lápida** (nombre a null, `purged_at`) y no se borra hasta acabar la retención.
  Es la única lápida: no hay otra en el progreso, y la clave ajena sin cascada de `op_participants`
  impide borrarla antes (comprobado, plataforma.md §11.2).
- **Retención.** El trabajo horario de plataforma.md §2.5 llama a `ProgressStore.PurgeRetention(ctx, tx)
  (deleted int64, emptied []int64, err error)` mientras `deleted` sea mayor que 0, una transacción cada vez.
  Dentro, `set local eldmark.retention_purge = 'on'` y borra, como mucho 10 000 apuntes por llamada, los
  apuntes, eventos y participaciones de los personajes con `purged_at < now() − 365 días`; después, las
  reversiones y operaciones que se han quedado sin participantes. `emptied` son los personajes purgados hace
  más de un año que ya no tienen filas en `op_participants` (también los que nunca las tuvieron): en la misma
  transacción, la plataforma borra solo esas filas de `characters`, sin mirar tablas del progreso. Revisión
  legal del año (§16).
- **Sin la marca**, UPDATE y DELETE fallan siempre (también tras una transacción que la puso: `set
  local` solo vale dentro de ella, comprobado). Corregir datos es añadir apuntes de MIGRATION; una
  migración que tuviera que borrar pone la misma marca y se revisa a mano.
- **Seudónimos, solo tras purgar la cuenta.** Tras la purga del personaje, `character_id` apunta a una
  lápida sin nombre y ningún `detail.args` lo nombra (el objetivo va por id, §10), pero la lápida sigue
  ligada a su cuenta: mientras la cuenta exista, ese libro es del titular y se exporta. Es un seudónimo
  cuando la cuenta también se purga y queda como lápida. Los `ref_id` de víctimas no se reescriben (sería un
  UPDATE en una tabla de solo añadir). La `note` de las operaciones GM y REVERSAL es texto del personal y
  se conserva como dato de moderación (revisión legal, plataforma.md §11.1).
- **Exportación.** `ProgressStore.Export(ctx, q, characterID)` da el registro (`null` en una lápida) y las
  operaciones, apuntes y eventos propios; de las operaciones GM y REVERSAL, el tipo, la fecha, los apuntes y
  los eventos, sin `actor_account_id`, `note` ni `detail` (datos del personal). La plataforma lo pone bajo
  `characters[i].progress` del archivo de plataforma.md §11.2, también de las lápidas de la cuenta con libro
  retenido.

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

**La ranura activa tiene una sola fuente: el bit0 de `combat_flags2`** (CMB-24), que cambian SWAP (Q, predicho y
válido en combate) y `set_weapons`. `InventoryState` no la guarda: `InventoryOps.Context.active_weapon_slot` la lleva a
cada petición, y la rellenan `PlayerProgress.apply_request` desde el `CombatState` del servidor y el cliente desde su
estado predicho. Así WEAPON_REQUIRED mira el arma que de verdad está en la mano.

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
| 3 | NOT_NOW | Sin personaje o fuera del mundo. La op toca EQUIPMENT y el personaje está muerto, derribado, en combate (`Combatant.is_in_combat`) o con una acción (`CombatState.action ≠ NONE`: beber, cambiar de arma, levantar y rematar incluidos). DESTROY de un consumible mientras bebe uno (si no, el compromiso restaría una carga de 0). SPLIT o DESTROY sin ids para clientes (§4.5). DESTROY con 256 operaciones o más en el diario sin confirmar (la plataforma no responde: así el cuerpo del guardado no crece sin límite, plataforma.md §7.3); lo mira `PlayerProgress.apply_request` antes de `InventoryOps` | «Ahora no puedes hacerlo»; en combate, «No puedes cambiar el equipo en combate» |
| 4 | CANNOT_EQUIP | Ranura de equipo incompatible, ranura 2–6 en la fase 5 o `required_level` por encima del nivel | «No puedes equipar eso ahí» o «Necesitas nivel N» |
| 5 | WEAPON_REQUIRED | Dejaría vacía la ranura de arma activa (`Context.active_weapon_slot`, §4.1) | «Necesitas un arma en la mano» |
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
  un guardado. Cada guardado manda la foto completa y las operaciones del diario que aún no iban en ningún
  cuerpo (§9.2), y el servicio lo aplica en **una** transacción (I7).
- `kill -9`, SIGTERM o SIGINT (no llegan a GDScript, red.md §1.3) pierden lo posterior al último
  guardado aceptado (60 s como mucho, plataforma.md §7.4), y a la vez el cambio y su registro: la BD
  nunca ve uno sin el otro. TEC-25 lo prueba matando el proceso (§15, P8).
- Cada petición aplicada deja una línea en el registro de la zona (personaje, op, ranuras, uids,
  resultado).

### 4.4 Lo que cambia el servidor por su cuenta

| Motivo | Cuándo | Efecto |
|---|---|---|
| `STARTER_KIT` | Primera entrada | §2.5; operación suelta, guardado crítico; luego INVENTORY_FULL |
| `CAMP_REFILL` | Paso 8 del tick (habilidades.md §4.1), cada 60 ticks, si está vivo, fuera de combate y en la zona segura de su reino | Por cada definición con `camp_refill`: `falta = camp_refill − count_of(def)` (bolsa y equipo). Si falta > 0, se suma a la pila de esa definición con la ranura más baja hasta `max_stack` y el resto va a una pila nueva en la primera ranura libre, con un `uid` del tramo del servidor (§4.5; sin él, esa parte espera al siguiente bloque). Bolsa llena: no se repone y llega un NOTICE «Bolsa llena», una vez por entrada en la zona segura. Agregado (§5.2). **Sustituye** la recarga de habilidades.md §4.6 para quien tiene inventario |
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
(habilidades.md §5.1), para quien tiene inventario, repone hasta `camp_refill` sin mirar zona ni combate. Sin
plataforma es un CAMP_REFILL forzado (agregado). **Con plataforma** pide `admin` y es un comando de GM más (§10):
una operación GM con un evento GM_GRANT (7) por lo que falta de cada definición, `note` «debug», el actor y el
`detail` del rastro, y guardado crítico; así S2 la admite y queda en la auditoría. Los jugadores falsos siguen con la
plantilla y la recarga de habilidades.md.

### 4.5 `uid` y `op_id`: bloques

- Con plataforma, un solo generador, el de plataforma.md §6: `POST /internal/v1/id-blocks
  {zone_instance_id}` → `{"first": "1025", "count": 1024}` (secuencia global `uid_block_seq` y tabla
  `id_blocks`), por `ZonePlatform.request_id_block()`. Del mismo bloque salen los `uid` y los `op_id`,
  únicos en todos los mundos. El servicio rechaza (S2, S5) los nuevos que no caen en un bloque de la
  instancia que reclamó.
- `IdAllocator` guarda dos bloques como mucho y pide otro cuando quedan menos de 512 por encima de la
  reserva de los guardados.
- **Tres tramos.** Los últimos `build_reserve` ids (2 × `max_players`: 128 con 64 plazas) solo los toma
  `build_section`, para cerrar lo agregado al construir un guardado. Los 256 de encima (`SERVER_RESERVE`) son del
  resto del servidor (kit, pila nueva de CAMP_REFILL, cierre de lo agregado antes de una operación suelta, GM,
  reversión), que se detiene con `available() ≤ build_reserve`: GM y reversión responden con su aviso sin
  crear nada, el kit no se da (`starter_granted` sigue false y llega en la siguiente entrada) y CAMP_REFILL no abre
  la pila nueva hasta el siguiente bloque. Un SPLIT o DESTROY del cliente con `build_reserve + 256` o menos da
  NOT_NOW. Así ningún cliente deja a otro sin beber ni a la zona sin guardar: con la plataforma caída nada sale salvo el guardado en vuelo, nadie nuevo entra y cada personaje
  construye como mucho dos cuerpos (el siguiente y el final), que la reserva cubre.
- Las operaciones agregadas toman su `op_id` al construir el guardado: beber y reponer nunca esperan a
  un id (salvo la pila nueva, que sale del tramo del servidor). Si aun así `build_section` no tiene id (un
  fallo: la reserva está para que no pase), devuelve `{}` sin tocar nada y `CharacterSaver` no manda ese
  guardado (plataforma.md §7.2).
- **Primer bloque**: es parte del arranque de plataforma.md §8 (tras el GET de fortalezas y antes de
  abrir el puerto, con los mismos reintentos); `startup_finished` espera a tenerlo y llega a
  `ProgressService` como evento `id_block`, igual que los siguientes.
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
  `character_id`); 2 PNJ y 3 fortaleza (la huella u32 de su id de texto: `HandoffTicket.zone_key_of(id)`,
  la misma función del `zone_key` de plataforma.md §5.1, y `tickets.ZoneKey` si Go la necesita; los ids
  de `NpcCatalog` cambian al añadir PNJ); 4 operación (la revertida). Ejemplo: `hollow` da 3021413298
  (caso de la prueba de aquí); `vado_gris`, 0x19efc013, el del vector de plataforma.md.
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
- **Idempotencia.** La del guardado es la de plataforma.md §7.3. Dentro del progreso, una operación
  repetida en un guardado nuevo falla S2: un `op_id` que ya está en `economy_ops` no vuelve a entrar.

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
| Captura | 300 | 20 | A cada jugador de la lista de plataforma.md §8 (del reino captor, presente, vivo y conectado en el círculo en el tick de la captura, sin GM invisibles ni personajes marcados por un comando de GM), la misma que suma `ScoreKeeper.captures`. **Una vez por personaje y fortaleza cada 30 min**: temporizador `capture:<fortress_id>` (§8). Guardado crítico |
| GM | `xp_add` | `currency_add` | §10 |

- `xp_reward` y `gold_reward` son dos campos nuevos de `NpcDefinition`
  (`scripts/shared/ai/npc_definition.gd`, MUN-07), con 0 por defecto, y se rellenan en `data/npcs/`.
- **Con `--platform` y `--fake-players` la zona no da ninguna recompensa persistente** y lo dice en el
  registro al arrancar: los falsos podrían ayudar a capturar o a sostener un círculo. Las opciones y su
  guardia son de plataforma.md §5.5.
- **Un GM invisible no recibe recompensas** (plataforma.md §9.1): ni méritos, ni XP, ni oro, ni la de
  captura. Tampoco cuenta como contribuyente de un PNJ: no hace daño, así que no está en `DamageLedger`.
- **Con plataforma, lo que provoca un comando del fuerte no paga nada persistente** (a nadie, tampoco al GM que
  lo usa estando en el círculo). `fort_owner`, `fort_reset` y `fort_kill_captain` marcan su cambio como
  **forzado**, y una captura con `capture_rate_multiplier ≠ 1` (`fort_capture_speed`) también lo es.
  `ScoreKeeper.captures`, `on_capture`, `on_npc_killed` y los méritos de objetivo de PRG-09 se saltan un cambio
  forzado, igual que todo con `--fake-players`. Sin plataforma, como hoy (personajes efímeros).
- **Con plataforma, un comando de GM que mueve, cura o muestra a un personaje lo marca como forzado** hasta su
  siguiente reaparición: `/gm teleport` (al que se mueve), `/gm visible` (al GM) y los DEBUG_COMMAND 1 `teleport`,
  2 `heal` y 4 `stamina_inf`. La marca es `NetEntity.gm_forced` (el campo y su borrado al reaparecer, plataforma.md P6; ponerla, plataforma.md P7b).
  Mientras dura, el personaje no entra en la lista de capturas (`ScoreKeeper.captures` y `on_capture`) ni cobra en
  `on_merits` ni en `on_npc_killed`, igual que con un cambio forzado del fuerte: un `gm` no lleva a nadie, ni a sí
  mismo, a cobrar con un comando. Sin plataforma, como hoy.
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

**Validación** (`CharacterAppearance.validate(catalog, realm, race_id)`, con `realm` en el código de
`NetProtocol.Realm`, el mismo de `claimed.realm` y de `ValidateCreate`; dentro se traduce con `RealmCatalog`): `race_id`
existe y es del reino, y el byte 0 es su índice + 1 (la raza va en los dos sitios y deben coincidir); cada índice está en
las listas de la raza; cada pieza es compatible con el cuerpo (sus `bodies`); un 0 de pelo o barba solo si
la raza lo admite (`allows_no_hair`, `allows_no_beard`). La regla es esta y la aplican dos sitios, con los
mismos datos (las reglas exportadas de §13.4 llevan las piezas con sus `bodies` y esos dos campos) y los
mismos casos: `tests/fixtures/progression/appearance_cases.json` (`[{realm, race_id, appearance, valid}]`,
con `realm` en código (1–3) y `appearance` en base64 de los 8 B, como en la API; escritos a mano en P3, uno o más
por regla), que leen `test_character_appearance` y la prueba de Go de
`ValidateCreate`. La plataforma, al crear el personaje, con `persistence.CreateValidator`, que implementa
`*progress.Rules` (§13.2); hasta tener P3 y P7, con la provisional de plataforma.md §4.4 paso 5 (`race_` + reino y 8
B cualesquiera). La zona, al
cargarlo (`ProgressService.prepare`, con el `race_id` del registro): una apariencia inválida se sustituye
por `default_for(raza)` y se registra, sin echar al jugador.

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
cliente (inválida → `default_for` de la raza). El payload de NPC no cambia: `npc_def_id` sigue justo tras
el nombre (red.md §5.5), sin nivel ni apariencia. El bit 3 de `flags` (personal del juego) es de
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

Es de este documento: plataforma.md solo guarda la sección `progress` (§13.1). Aquí está también la única
regla de volver al mundo (plataforma.md §0 y §7.1 la citan); la aplica `ProgressService.on_arrival`.

| Qué | Cómo se guarda | Al cargar |
|---|---|---|
| Las dos armas | Son objetos de EQUIPMENT 0 y 1 | `set_loadout` con sus armas de `CombatCatalog` (habilidades.md §3.5), en el sitio donde H3c pone las de la plantilla |
| Arma activa | `active_weapon_slot` = bit0 de `combat_flags2` al construir el guardado (CMB-24, la única fuente, §4.1): 0 WEAPON_1, 1 WEAPON_2; si esa ranura no tiene arma (un DEBUG_COMMAND 5 sobre una WEAPON_1 vacía), la otra, para cumplir I10 | En el alta, tras `set_loadout`, `set_weapons(…, second_active = true, [], [])` si vale 1. Al reaparecer, `reset_for_respawn` deja activa WEAPON_1; si WEAPON_1 está vacía, `set_weapons(…, second_active = true, [], [])` justo después, igual que en el alta (los dos por `loadout_for`) |
| Habilidades elegidas | No se guardan: en la fase 5 son el kit fijo del arma (habilidades.md §2.3). Llegan con PRG-19 | — |
| Consumibles | Las pociones de la bolsa (§4.4) | Cargas = `min(15, en la bolsa)` |
| Vida | `health` del registro (§3.4), del `Combatant`; null = llena | `min(máx, health + CombatRules.health_regen_per_s · (now_unix − saved_at_unix))`; con `health` null o 0, o sin `location`, llena |
| Reutilizaciones de 30 s o más | `timers`: clave y `ends_at_unix` | `ready_tick = s + max(0, ends_at_unix − now_unix) · 60`; las vencidas se descartan |
| Efectos largos | No hay en la fase 5: el más largo, `bleed`, dura 6 s | Cuando CMB-20 tenga uno con `persists`, con clave `effect:<id>` |
| Posición | `location` del registro (§3.4): zona, canal, posición y giro de la entidad y «en combate» del `Combatant`. Se guarda siempre: la usa `enter` (plataforma.md §4.5) | Zonas `PvpMode.RVR` (en la fase 5, todas: `vado_gris` y `test_world`): siempre el punto de aparición de su reino, el campamento; así nadie aparece dentro de un fuerte que ha cambiado de dueño. Zonas `SAFE` (desde la fase 6): el sitio guardado si `location.zone_id` y `channel` son los de esta instancia, `now_unix − saved_at_unix < 900`, `in_combat` es false, estaba vivo, pisa suelo y no está en la zona segura de otro reino; si no, el punto de aparición de su reino |

**Temporizadores de la fase 5:**

| Clave | Qué | Quién la lee y la escribe |
|---|---|---|
| `unstuck` | Reutilización de `/atascado` (5 min, fuerte.md §5) | `UnstuckTracker.get_ready_at(player)` y `set_ready_at(player, tick)`, nuevos; con plataforma, `player` es `"character:<id>"` en lugar del nombre normalizado |
| `capture:<fortress_id>` | Recompensa de captura (30 min, §6.2) | `ProgressService` |
| `ability:<id>`, `consumable` | Reservadas | Ninguna habilidad ni consumible llega a 30 s (las reutilizaciones van de 10 a 20 s). `test_player_progress` falla si aparece una: habría que imponer su `ability_ready` al aparecer, solo con la misma arma |

El tiempo **corre sin conexión** (decisión §0). Al construir el guardado: `ends_at_unix = now_unix +
ceili((ready_tick - s) / 60.0)`, con `now_unix = ZonePlatform.now_unix()` (el reloj corregido de
plataforma.md §6). En GDScript, `(ready_tick - s) / 60` entre enteros trunca antes de redondear y `ceil` devuelve
`float`: vencería hasta 1 s antes y viajaría como `float` en el JSON. `scripts/shared/` no ve fechas y `scripts/server/progress/` no lee `Time`. Sin
plataforma no se guardan temporizadores (efímeros), así que no hace falta otro reloj.

**Nada de lo que se predice por tick se guarda**: ni el resto de `CombatState` (resistencia, acción,
combo, controles, parada), ni la posición exacta entre guardados, ni las reutilizaciones de menos de
30 s (reconectar las reinicia; §17).

**Traspasos (fase 6).** El billete solo lleva la identidad, y lo de CMB-30 llega con el guardado final y
la reclamación en el destino (plataforma.md §5.1). La zona de origen hace un guardado
final con `release`. Desde la foto, el personaje queda **congelado**: inventario y monedas responden
NOT_NOW y no recibe recompensas. El HANDOFF sale solo tras el OK del guardado; si falla, el traspaso se
cancela y se descongela. La zona de destino lo carga en su reclamación.

## 9. Ciclo de vida en la zona

### 9.1 Carga y alta

1. HELLO con billete → `TicketAuthProvider` → `VERIFYING` → reclamación (plataforma.md §5.2).
2. **Reclamación con 200** (`AuthOutcome.claimed: ClaimedCharacter`, con `progress: Dictionary`;
   plataforma.md §14.3). En el paso «poll», tras comprobar el reino y el cupo y antes del WELCOME (el
   orden es el de plataforma.md §5.2), `ZoneServer` llama a `progress.prepare(peer_id, claimed)`:
   - decodifica `ProgressRecord.from_dictionary(claimed.progress, ItemDatabase.shared())`;
   - valida `appearance` con `race_id` y `claimed.realm` (inválida → `default_for`, aviso);
   - crea el `PlayerProgress` del peer.

   Si devuelve false, la zona responde REJECT `UNAVAILABLE` con «No se ha podido cargar el personaje»,
   alerta en el registro y libera (plataforma.md §5.2). Así nadie recibe WELCOME sin haber pasado el un
   solo uso, las sanciones y la carga.
3. WELCOME con el reino del personaje y `LOADING` (plataforma.md §5.2). Si el peer se va antes de
   CLIENT_READY (o lo expulsan), la zona llama a `progress.cancel_prepared(peer_id)`, que descarta el
   `PlayerProgress` preparado, y libera sin guardar (la baja en `LOADING` de plataforma.md §5.2).
4. CLIENT_READY → `_process_arrivals`, que crea la entidad y llama a `CharacterSaver.track` (plataforma.md
   §14.3). Antes del SPAWN, `progress.on_arrival(entity, peer, s)`:
   - ata el `PlayerProgress` preparado al `net_id`;
   - kit de inicio si toca (§2.5);
   - la regla de volver al mundo (§8): coloca la entidad y le pone la vida;
   - impone los temporizadores (`unstuck` con `set_ready_at`; los vencidos se descartan);
   - `NetEntity.level` y `NetEntity.appearance`;
   - devuelve el `Loadout` (armas, ranura activa y cargas) que usa el alta en lugar de la plantilla.
5. Tras el SPAWN propio, `progress.after_spawn(entity, peer, s)`: INVENTORY_FULL, un WALLET_UPDATE por
   moneda y un PROGRESS_UPDATE (estado).

Sin plataforma, el paso 2 no existe: `on_arrival` crea un personaje efímero (§9.4).

### 9.2 La sección `progress` de `CharacterSaver`

`ProgressService.setup` la registra con `CharacterSaver.register_section(&"progress", build, acknowledge,
is_dirty)` (firmas en plataforma.md §14.3):

| Llamada | Qué hace |
|---|---|
| `build(net_id, seq) -> Dictionary` | `PlayerProgress.build_section(seq)`: cierra lo agregado (una GAMEPLAY), toma posición, giro, vida, «en combate», tiempo jugado, `active_weapon_slot` y los temporizadores (§8) y devuelve la foto (sin los campos de solo lectura) y **solo las operaciones con `save_seq = 0`**, a las que pone `save_seq = seq` (§9.3). Sin id para cerrar lo agregado (`next_for_build`), devuelve `{}` sin tocar nada (§4.5). Nunca reenvía una ya marcada: el final construido con otro en vuelo no repite sus operaciones (si el que vuela se aplica, S2 lo rechazaría; si recibe un definitivo, el final se descarta con él) |
| `acknowledge(net_id, seq)` | Tras 200 `applied` o `duplicate`: quita del diario las operaciones con `save_seq ≤ seq`. Sobre un `net_id` sin `PlayerProgress`, nada (tras `finish` no se llama: plataforma.md §7.2) |
| `is_dirty(net_id) -> bool` | `PlayerProgress.is_dirty()`: alguna operación con `save_seq = 0`, algún campo del registro cambiado desde el último confirmado, posición movida o vida distinta |

No hay `restore`: `CharacterSaver` no carga nada (la carga es `prepare` y `on_arrival`, §9.1).

- **Cuándo**: lo decide plataforma.md §7.2 (cada 60 s con cambios, críticos al instante, al salir con
  `release`, cierre ordenado). **Los eventos críticos** (la lista es de aquí) se marcan con
  `CharacterSaver.mark_critical(net_id, reason)`: `&"starter_kit"`, `&"level_up"`, `&"capture"` y `&"gm"`
  (todo comando de §10 que cambia algo, `op_revert` incluido); desde la fase 6, comercio, correo y botín
  raro. `reason` solo va al registro y a las métricas. El renombrado no es crítico: no cambia el cuerpo.
- **Un `seq`, un cuerpo**: `build` se llama una vez por `seq` y los reintentos mandan el mismo cuerpo.
  Lo que cambie mientras hay uno en vuelo va en el siguiente.
- **Salida**: en el orden de plataforma.md §7.2: `CharacterSaver.finish(net_id, reason)` →
  `ScoreKeeper.forget` → `ProgressService.on_departure(net_id)`, que libera el estado; sobre un `net_id` sin
  `PlayerProgress` no hace nada. En `ZoneServer.stop`, `finish` de todos antes de `_clear_players()` (hoy
  `stop()` vacía los jugadores en ese mismo paso).
- **Respuestas**: la tabla y la regla de errores son las de plataforma.md §7.3. Antes de `finish`, la
  sección solo recibe `acknowledge` en 200, y en las definitivas (`lease_lost`, `stale_seq`, `seq_conflict`,
  `invalid_save` y cualquier otro 4xx) la zona hace la baja sin guardado de plataforma.md §7.2: el cuerpo sale en
  el acto y `ProgressService.on_departure` descarta el estado sin guardar. Después de `finish`, las respuestas ya
  no llegan a la sección (plataforma.md §7.2).
- **Sin `PlayerProgress`, nada.** Todo gancho de `ProgressService` que recibe un `net_id` (`acknowledge`,
  `is_dirty`, `on_departure`, `loadout_for`, `on_merits`, `camp_step`, `on_capture` y `on_npc_killed` por cada
  `net_id` de su lista, `after_simulate` por cada jugador) no hace nada con uno que no tiene `PlayerProgress`
  (`loadout_for` devuelve null y quien lo llama usa la plantilla, como con un falso).

### 9.3 La sección `progress` de un guardado

Es el valor de la clave `progress` del cuerpo de plataforma.md §7.3: el `ProgressRecord` de §3.4 sin los
campos de solo lectura, más el diario (`ops`), en orden de aplicación. No lleva zona: la del guardado es
la de la instancia que reclamó (`SaveKey.ZoneID`), que rellena `economy_ops.zone_id` y contra la que S1
compara `location.zone_id`.

```json
{"progress_format": 1, "level": 8, "xp_total": 12345, "…": "resto de §3.4, sin los campos de solo lectura",
 "ops": [{"op_id": "5120", "kind": 2, "actor_account_id": null, "ref_op_id": null, "note": null, "detail": {},
          "ledger": [{"currency": 1, "delta": 2, "balance_after": 102, "reason": 6, "ref_kind": 2, "ref_id": "3021413298"},
                     {"currency": 2, "delta": 30, "balance_after": 3230, "reason": 3, "ref_kind": 1, "ref_id": "88"}],
          "items": [{"uid": null, "def_id": "potion_health", "count_delta": -1, "reason": 65}]},
         {"op_id": "5121", "kind": 4, "actor_account_id": "77", "ref_op_id": null, "note": "devolución del fallo 12",
          "detail": {"command": "currency_add", "source": "gm", "actor_character_id": "41", "at_unix": 1793282390,
                     "args": ["42", "oro", "50"]},
          "ledger": [{"currency": 1, "delta": 50, "balance_after": 152, "reason": 7, "ref_kind": 0, "ref_id": "0"}],
          "items": []}]}
```

- `items` de la foto: todas las instancias vivas. `items` de una operación: sus eventos (I4). Un evento
  lleva `uid` cuando es de una instancia concreta (kit, GM, DESTROY del jugador) y `null` cuando es
  agregado (CAMP_REFILL, CONSUME).
- Los apuntes de cada moneda, en orden. No llevan `seq` (§5.2).
- La idempotencia es la de plataforma.md §7.3.

### 9.4 Sin plataforma: personajes efímeros

- Sin `--platform`, todo jugador con peer es efímero: `ProgressService.setup(zone, null, null, commands)`
  (no hay `CharacterSaver`) y `on_arrival` crea `ProgressRecord.new_character()` y el kit con la plantilla
  de LOADOUT_SELECT (§2.5), con `IdAllocator.local()`. Nada se guarda y al salir se pierde: no hay
  `--progress-file` ni otro almacén local.
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
| `--debug-commands` y `--platform` | Además, el `min_role` de cada comando (plataforma.md §9.1) con el rol de la reclamación (`ClaimedCharacter.role`): `gm` o más. Declaran `admin` los que crean o conservan valor de un personaje persistente o se saltan su equipo, porque siempre actúan sobre el propio personaje (regla de los propios personajes, abajo): los ids 40–43; el 5 `set_weapon` (pone un arma que no está en su equipo, habilidades.md §3.5); el 13 `cooldowns_off` (bebe sin gastar pociones, habilidades.md §3.3); y el 16 `refill` (crea pociones, §4.4). Sin rol: aviso, y nada se ejecuta ni se guarda |
| `--debug-commands`, `--platform` y `env` `staging` o `production` en el registro | La zona sale con código 1 (plataforma.md §5.5) |

**Rastro de cada comando que cambia algo.** Crea una sola operación: una GM (aunque no tenga apuntes ni
eventos) o, en `op_revert`, la REVERSAL (abajo). Las dos llevan:

- `actor_account_id` (null solo desde la consola);
- `note`: el motivo escrito; «debug» por DEBUG_COMMAND; obligatoria y no vacía;
- `detail`: `command`, `args`, `source` (`gm`, `console` o `debug`), `actor_character_id` (el personaje
  del GM; null desde la consola), `at_unix` (`ZonePlatform.now_unix()` al crearla: la hora de su fila de
  auditoría y la del rol del actor en S2) y, si toca nivel o XP, `level_before`, `level_after`, `xp_before`,
  `xp_after` y `xp_delta`. En `args`, el personaje objetivo va como su `character_id` en cadena, nunca
  como el nombre que escribió el GM: el libro es de solo añadir y la purga no podría quitarlo.

Su fila de `audit_log` la escribe el propio guardado (§13.3, S8) con `event_key = "op:<op_id>"`, y la
entrada del lote de auditoría de la zona usa la misma clave y los mismos campos: llegue antes o después,
no se duplica ni se pierde. La regla de las dos vías y los campos son de plataforma.md §9.1 (`source` =
`console` si `detail.source` es `console`; si no, `zone`). Los comandos de consulta (`inv_show`,
`ledger_show`, `op_show`, rol `gm`) van al lote de auditoría como cualquier otro.

Los DEBUG_COMMAND que no cambian nada guardado (el 5 `set_weapon` y el 13 `cooldowns_off`: solo tocan el
`CombatState`) no crean operación: van solo al lote de auditoría, con su clave `<zone_instance_id>:<n>`. El 16
`refill` sí la crea (§4.4).

**Sobre un personaje de la cuenta del propio GM**, todo comando que cambie algo (también por
DEBUG_COMMAND, y `op_revert`) exige `admin`, sin excepción por entorno; si no, «No puedes usarlo sobre tus
personajes». El servicio lo vuelve a comprobar (S2, en las GM y las REVERSAL). Con una excepción en `dev` o
`test`, la zona aceptaría el comando, S2 rechazaría el guardado (`invalid_save`) y el personaje perdería lo
no guardado.

**Zona cercada** (plataforma.md §5.3): todo comando que cambie algo responde «El servicio de cuentas no
responde; inténtalo más tarde» si `platform.is_fenced()`, sin crear la operación. Los críticos del juego
(kit, subida de nivel, captura) no se rechazan: se marcan y salen en cuanto se pueda.

**Reversión** (`op_revert op_id motivo…`):

- Solo de una operación ya guardada (con plataforma, la lee de `GET /internal/v1/ops/{op_id}`; sin
  plataforma, del diario de la sesión) de un personaje conectado en esta zona. Ni una REVERSAL, ni una
  MIGRATION, ni una ya revertida (`op_reversals`, o una REVERSAL suya aún sin guardar en el diario: «Esa
  operación ya se está revirtiendo»). Una aún sin guardar: «Esa operación aún no está guardada; inténtalo
  en unos segundos».
- Cierra lo agregado (§5.2) y crea una REVERSAL (la única operación del comando) con `ref_op_id`, el
  motivo como `note` y el actor y el `detail` del rastro de arriba. Es crítica. Todo o nada.
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
| Versión | **7**, la de plataforma.md §5.4: una sola subida para toda la fase 5, compartida. La sube plataforma.md P4 (va antes en el orden conjunto) con la línea completa en `net_protocol.gd`; P4 de aquí añade su parte del código sin subirla. Lo de aquí: +9 B del SPAWN de PLAYER, 0x50–0x55, ENTITY_EVENT 16 LEVEL_UP, DEBUG_COMMAND 40–43 e `ItemDatabase` en el `sim_hash`. Lo de plataforma.md, en la misma versión: REJECT 10–12, billete de 52 B, `auth_timeout` de 10 s (`NetTransport.AUTH_TIMEOUT_SECONDS`) y el bit 3 del `flags` de la cabecera del SPAWN. En red.md, cada P4 escribe las filas y la marca «v7» de lo suyo (la regla, plataforma.md §5.4): P4 de aquí, §3 (`sim_hash` y el texto del REJECT `SIM_HASH`), §5.2 (0x50–0x55), §5.4 (40–43) y, en §5.5, los +9 B y LEVEL_UP |
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

### 13.1 Acordado con plataforma.md

La interfaz con plataforma.md, ya conciliada. Cada regla está escrita una sola vez, en el documento dueño;
el otro la cita. La misma tabla está en plataforma.md §17.

| Tema | Acordado | Dueño | Lo cita |
|---|---|---|---|
| Idempotencia del guardado | Solo `(lease_id, seq)`: mismo `seq` y mismo SHA-256 → `duplicate` (aplicado, con el `save_version` guardado en `character_leases`); otro cuerpo → `seq_conflict`; menor → `stale_seq`. `save_version` es un contador que no interviene; `saved_at` y `save_version` los escribe `Apply` (S8) | plataforma.md §7.3 | progresion.md §5.4, §13.3 |
| Cuerpo del guardado | Sobre `save_format` 1 con una clave por sección: `progress` (el registro sin los campos de solo lectura, con `ops`) y `pvp`. Sin `zone_id`: la zona es la de `claimed_by` | plataforma.md §7.1, §7.3 | progresion.md §9.3 |
| Diario en el guardado | Cada cuerpo lleva solo las operaciones con `save_seq = 0`, que `build` marca con su `seq`; `acknowledge(seq)` quita las de `save_seq ≤ seq`. Un final construido con otro en vuelo no repite nada | progresion.md §9.2 | plataforma.md §7.1, §7.2 |
| Formatos | `progress.progress_format` es el `record_format` del registro de la zona (`ZonePlatform.RECORD_FORMAT`, de plataforma.md P4; `ProgressRecord.FORMAT` vale lo mismo y lo prueba progresion.md P5a): la compatibilidad se decide al registrarse (409 `schema_mismatch`); en un guardado, otro formato es 400 `invalid_save` | plataforma.md §7.1 | progresion.md §3.4 |
| Secciones de `CharacterSaver` | `register_section(section, build, acknowledge, is_dirty)` con `build(net_id, seq)`, `acknowledge(net_id, seq)` e `is_dirty(net_id)`; sin `restore`. `track(net_id, character_id, lease_id, tick)` al crear la entidad, antes de `on_arrival`; `mark_critical(net_id, reason)`, `on_platform_event`, `save_rejected`, `drop(net_id, code)`. `CharacterSaver` arma el sobre entero (`zone_instance_id` incluido); un `build` que devuelve `{}` aplaza ese guardado (el final no espera: alerta y `release`). Entradas por `lease_id`, y cada respuesta, por el `lease_id` y el `seq` de su petición: tras `finish` o `drop`, ni `acknowledge`, ni `is_dirty`, ni `save_rejected` | plataforma.md §7.2, §14.3 | progresion.md §9.1, §9.2 |
| Eventos críticos | Kit de inicio, subida de nivel, captura y todo comando de GM que cambia algo (`op_revert` incluido); desde la fase 6, comercio, correo y botín raro. El renombrado no es crítico | progresion.md §9.2 | plataforma.md §7.2 |
| Cuándo se guarda | Cada 60 s con alguna sección sucia, en fases; una escritura en vuelo; el final en `finish`. Salida: `finish` → `ScoreKeeper.forget` → `ProgressService.on_departure`; al parar, `release` de `LOADING`, `cancel` de `VERIFYING` y `finish` de todos antes de `_clear_players()` | plataforma.md §7.2 | progresion.md §9.2 |
| Baja sin guardado | Un definitivo antes de `finish` o un `revoked` `lease_lost`: `CharacterSaver.drop(net_id, code)` (con `release` salvo en `lease_lost`), expulsión con el cuerpo fuera en el acto (sin salida en combate), `ScoreKeeper.forget` y `ProgressService.on_departure`. Todo gancho de `ProgressService` por `net_id` sin `PlayerProgress` no hace nada | plataforma.md §7.2 | progresion.md §9.2, §14.2 |
| Baja en `LOADING` | Sin guardado: `ZonePlatform.release(character_id, lease_id)` y `ProgressService.cancel_prepared(peer_id)`, también con un `revoked` | plataforma.md §5.2, §14.3 | progresion.md §9.1, §14.2 |
| Respuestas del guardado | Una tabla y una regla de errores. Contenido o base que no es pasajero (`*persistence.InvalidSaveError`, SQLSTATE de clase 22 o 23 o `P0001`, también en el COMMIT): 400 `invalid_save` con `fields.check` y `fields.detail`. `40001` y `40P01` tras reintentar, sin conexión o plazo: 503. Un error del sobre: `invalid_save` con `check = "envelope"`. No hay `invalid_progress` ni `progress.ErrFormat`. `instance_*`: cierre con guardados finales. Cualquier otro 4xx es definitivo, como `invalid_save`, también en la liberación. `progress` es obligatoria y `pvp`, opcional y sin bajar | plataforma.md §6.1, §7.3 | progresion.md §9.2, §13.3 |
| Sin plataforma | Nada se guarda: personajes efímeros; no hay `--progress-file` ni repositorios de progreso. `CharacterSaver` solo existe con `--platform` y llama a `ZonePlatform.save` | progresion.md §0, §9.4 | plataforma.md §5.5, §7.5 |
| Reclamación | `{lease_id, instance_status, account, character, progress, pvp}`, solo de un personaje no borrado, con la cuenta bloqueada, sin otro personaje de la cuenta en el mundo y con `Load` en su transacción; en la zona, `AuthOutcome.claimed: ClaimedCharacter` con `progress: Dictionary`. No hay clase `CharacterRecord` | plataforma.md §5.3, §6, §14.3 | progresion.md §3.4, §9.1 |
| Antes del WELCOME | Reino → cupo → `ProgressService.prepare(peer_id, claimed)` → WELCOME con el reino del personaje; si algo falla, REJECT (`REALM`, `FULL` o `UNAVAILABLE`) y `release`. El WELCOME no cambia de bytes | plataforma.md §5.2 | progresion.md §9.1 |
| Contenido del registro | Un solo `ProgressRecord`, con raza, apariencia, `played_seconds`, `health` y `location`. Solo en la reclamación: `race_id`, `appearance`, `starter_template_id` y `location.saved_at_unix` (`to_claim_dictionary` los pone). No hay `characters.state` ni JSON de estado | progresion.md §3.4 | plataforma.md §7.1 |
| Falso de la plataforma | `FakeZonePlatform` devuelve en la reclamación siguiente lo último aplicado: `pvp` (plataforma.md P4) y `progress` sin `ops`, con los campos de solo lectura de la reclamación anterior y `location.saved_at_unix` (progresion.md P5a, con `claim_progress`). Su API de pruebas (`add_character`, `script_next`, `set_fenced`, `next_block_first`, `applied`, `sent`) es una sola, de plataforma.md P4 | plataforma.md §14.1, §14.3 | progresion.md §14.1 |
| Volver al mundo | Zonas RVR (todas en la fase 5): el campamento del reino. Zonas SAFE (fase 6): el sitio guardado si es la misma instancia, hace menos de 15 min, sin combate y vivo. Vida regenerada con el tiempo pasado | progresion.md §8 | plataforma.md §0, §7.1 |
| Quién guarda qué | Una tabla con todos los campos y su dueño; `characters` solo identidad (no gana `level` ni `state`) | progresion.md §3.1 | plataforma.md §3 |
| Tablas del progreso | DDL de `0010_progress` solo en progresion.md, sin `world_id`; las de solo añadir, con clave ajena sin cascada a `characters` por `op_participants`; disparador en las cinco; `actor_account_id` en las GM y REVERSAL | progresion.md §3.3 | plataforma.md §3 |
| Migraciones | En la fase 5, 0001–0006 de la plataforma y 0010_progress (progresion.md P7, con `.down.sql` y semilla); después, el siguiente número libre, sea de quien sea. El ejecutor aplica en orden y se niega ante una pendiente por debajo de la mayor aplicada. No hay P3b | plataforma.md §2.4 | progresion.md §3.3 |
| Bloques de ids | `POST /internal/v1/id-blocks {zone_instance_id}` → `{first, count: 1024}`, en `starting` y `live`; `uid_block_seq` e `id_blocks` en 0003_zones; el primer bloque, en el arranque; `Apply` rechaza ids fuera de los bloques de `claimed_by` | plataforma.md §3, §6, §8 | progresion.md §4.5, §13.3 |
| Purga y retención | La lápida es la fila de `characters`. La purga bloquea el arrendamiento y la fila del personaje, y no purga con un arrendamiento vivo; con la cuenta y en `reapply-purges` (que corre antes de `serve` y borra los arrendamientos restaurados) basta `purged_at` nulo; `ProgressStore.Purge` borra el estado del progreso; `PurgeRetention` vacía el libro al año y devuelve las lápidas vacías, que la plataforma borra; `reapply-purges` conserva el `purged_at` | plataforma.md §11.1, §11.2 | progresion.md §3.5 |
| Exportación | `ProgressStore.Export` de cada personaje no purgado y de cada lápida de la cuenta con libro (sin registro), bajo `characters[i].progress`; de las operaciones GM y REVERSAL, sin actor, `note` ni `detail`. El libro de una lápida es seudónimo solo tras purgar la cuenta | plataforma.md §11.2 | progresion.md §3.5 |
| `ProgressStore` en Go | `Create`, `Load`, `Apply`, `Summaries`, `Purge`, `PurgeRetention` (con las lápidas vacías), `Export`, `Op` (con la instancia) y `Ledger`, con JSON crudo en la frontera; sus errores (`InvalidSaveError`, `ErrNotFound`) y la validación de la creación (`CreateValidator`, `*ValidationError`) en `internal/persistence`, de plataforma.md P2, que `*progress.Rules` implementa. La plataforma no lee columnas del progreso | progresion.md §13.2 | plataforma.md §7.5 |
| Operación y libro | Rutas `?zone_instance_id=` del enrutador interno de la plataforma (comprobaciones de su §6.1), solo con arrendamiento en la instancia (el del personaje, que mira el enrutador; o el de algún participante, que mira `Op` en su propia consulta); si no, 404. Cuerpos de progresion.md; `limit` de 1 a 100 | plataforma.md §6 | progresion.md §13.2 |
| Ids en JSON | Cadena decimal para todo id `bigint`, también en la reclamación y en el guardado (`jsonx.ID`, hasta 2^63 − 1; los del progreso, hasta 2^53 − 1 por S1); número para cantidades, saldos, nivel, `seq`, códigos y fechas. Reinos: id de texto en la API pública y código en la interna | plataforma.md §4.1 | progresion.md §0, §3.4 |
| Comprobaciones del guardado | S1–S8 de progresion.md; arrendamiento y `seq` son los pasos 2 y 3 del guardado, sin número S. S2 admite de las zonas los tipos 1–5 con sus motivos, rechaza un `op_id` ya guardado y comprueba el actor de GM y REVERSAL con el rol que tenía en `detail.at_unix` (la fila `set-role` de la CLI, plataforma.md §9.1). S7 admite fechas pasadas | progresion.md §13.3 | plataforma.md §6.1, §7.3 |
| Nivel | Solo `character_progress.level`; la lista de personajes lo lee con `Summaries` | progresion.md §3.1 | plataforma.md §4.4 |
| Raza y apariencia | `race_vardheim`, `race_solmarch` y `race_askarra`; 8 B en `character_progress`, con el byte 0 de `race_id`; valida la plataforma al crear (`ValidateCreate` o la provisional) y la zona al cargar (`default_for`), con las mismas reglas exportadas (piezas con sus `bodies`, `allows_no_hair`, `allows_no_beard`) y los mismos casos (`appearance_cases.json`); el reino, en el código de `NetProtocol.Realm` en `validate`, `ValidateCreate`, las reglas y los casos | progresion.md §7.2 | plataforma.md §4.4 |
| Plantilla de inicio | Se elige al crear (`starter_template_id`, UI-24) entre las `selectable`; es el kit de la primera entrada; con plataforma, LOADOUT_SELECT no cambia nada | progresion.md §2.5 | plataforma.md §4.4, §13.2 |
| Reglas exportadas | Un archivo (`platform/internal/gamedata/progression_rules.json`), una herramienta (`tools/progression/export_rules.gd`) y una prueba (`test_progression_rules_export.gd`); `protocol_version` y `names` son de plataforma.md. Los datos de prueba compartidos con Go, bajo `tests/fixtures/` | progresion.md §13.4 | plataforma.md §4.4 |
| Protocolo | `PROTOCOL_VERSION = 7` para toda la fase 5, con `AUTH_TIMEOUT_SECONDS = 10.0`; reparto fijo (5 chat y grupos, 6 habilidades.md); lo sube plataforma.md P4, tras habilidades.md, con la línea completa en `net_protocol.gd`; progresion.md P4 añade lo suyo sin subirla. En red.md cada P4 escribe las filas y la marca «v7» de lo que añade su código | plataforma.md §5.4 | progresion.md §12 |
| CMB-30 | Es de progresion.md; la plataforma guarda la sección `progress` | progresion.md §8 | plataforma.md §7.1 |
| Billete y traspasos | 52 B, solo identidad; lo de CMB-30 llega con el guardado final y la reclamación en el destino (fase 6) | plataforma.md §5.1 | progresion.md §8 |
| DEBUG_COMMAND con plataforma | El `min_role` de cada comando; declaran `admin` los 40–43 y el 5, el 13 y el 16 | progresion.md §10 | plataforma.md §9.1 |
| Guardia de entorno | Manda el `env` del registro: con `staging` o `production`, las opciones de desarrollo hacen salir a la zona | plataforma.md §5.5 | progresion.md §10 |
| Sobre los propios personajes | Todo comando que cambia algo (`op_revert` incluido) exige `admin`, sin excepción por entorno; S2 lo repite en las GM y las REVERSAL | progresion.md §10 | plataforma.md §9.1 |
| Consultas de GM | `inv_show`, `ledger_show` y `op_show` piden `gm` y se auditan | progresion.md §10 | plataforma.md §9.1 |
| Auditoría | Un comando que crea una operación (una GM, o la REVERSAL de `op_revert`) va con `key = "op:<op_id>"` en el lote y en S8, con `on conflict do nothing` y los mismos campos: `actor_account_id`, `source` (`zone` o `console`), `args` con el objetivo por id y `at` = `detail.at_unix`; `world_id` y `zone_id`, de la instancia. Cada entrada del lote se valida por separado y contra la instancia que la manda: ni otra instancia, ni filas `cli` o `platform`, ni `op_id` de otros bloques (plataforma.md §6). Ninguna fila de `audit_log` lleva correos ni nombres en `args` | plataforma.md §9.1 | progresion.md §10, §13.3 |
| GM invisible | Ni méritos, ni XP, ni oro, ni recompensa de captura | plataforma.md §9.1 | progresion.md §6.2 |
| Zona cercada | Los comandos que cambian algo se rechazan sin crear la operación; los críticos del juego se marcan y salen después | plataforma.md §5.3 | progresion.md §10 |
| Jugadores falsos | Opciones y guardia, plataforma.md; con plataforma y falsos, ninguna recompensa persistente | progresion.md §6.2 | plataforma.md §5.5 |
| Comandos del fuerte y de GM | Con plataforma, lo que provoca un comando del fuerte (`fort_owner`, `fort_reset`, `fort_kill_captain`, una captura con `fort_capture_speed`) no paga nada persistente ni suma en `ScoreKeeper`; `/gm teleport`, `/gm visible` y los DEBUG_COMMAND 1, 2 y 4 marcan al personaje (`gm_forced`) hasta su reaparición: ni capturas, ni méritos, ni PNJ | progresion.md §6.2 | plataforma.md §8, §9.1 |
| Eventos en la zona | `take_events()` se reparte por `kind`, con un consumidor cada uno: `claim` (`auth_provider`), `save` (`saver`), `heartbeat` (la zona), `id_block`, `progress_op` y `progress_ledger` (`progress`), `fortress`, `ignore`, `report`, `sanction` e `instance_closed` (`ServerMain`); después `take_completed` y `prepare` | plataforma.md §14.3 | progresion.md §14.2 |
| Peticiones de la zona | `ZonePlatform.request` pone `zone_instance_id` (el guardado lo lleva en el sobre de `CharacterSaver`, y `save(character_id, lease_id, body, release_lease, context)` manda los bytes sin tocarlos); `enqueue_batch`, la `key` que falta; ningún cuerpo lleva `world_id` (lo pone la plataforma desde la instancia); `body` leído con `JSON.new().parse` (nunca `parse_string`) | plataforma.md §14.3 | progresion.md §13.2 |
| Capturas | Una lista de `FortressController` (captor, presentes, vivos, conectados, sin invisibles ni marcados con `gm_forced`) para `ScoreKeeper.captures` y `ProgressService.on_capture`; una captura forzada no va a ninguno | plataforma.md §8 | progresion.md §6.2 |
| Huella u32 | `HandoffTicket.zone_key_of` para el `zone_key` del billete y los `ref_id` de PNJ y fortaleza | plataforma.md §5.1 | progresion.md §5.2 |
| Reloj y tamaño | `ZonePlatform.now_unix()` para los temporizadores; cuerpo de 1 MB como mucho en la API interna | plataforma.md §6 | progresion.md §8, §17 |
| Paquetes | El almacén del progreso es progresion.md P7, con las dependencias de su §14.1; la interfaz `ProgressStore`, `CreateValidator` y sus errores, plataforma.md P2; los dos documentos esperan a habilidades.md; progresion.md P5c, a plataforma.md P6 (lista de capturas); un orden conjunto para `zone_server.gd` | plataforma.md §14.1 | progresion.md §14.1 |
| Pruebas | Las del almacén, en progresion.md P7; DEBUG_COMMAND 40–43, la regla de los propios personajes y el cercado con `item_give`, en progresion.md P5d (plataforma.md P7b prueba `min_role` con comandos de red y de moderación); las de extremo a extremo, con el arnés de plataforma.md P10 | progresion.md §15 | plataforma.md §15 |
| Cliente | UI-23, UI-24 y el bot usan `CharacterAppearance` y `AppearanceApplier` | plataforma.md §13.2, §13.3 | progresion.md §7.2, §7.4 |

### 13.2 El almacén en Go (P7, este documento)

```go
// platform/internal/persistence/progress.go: la interfaz y sus errores los define plataforma.md P2 con un falso;
// la implementa internal/progress (P7), que importa persistence (nunca al revés). Todo va dentro de la
// transacción o la conexión de quien llama.
type InvalidSaveError struct{ Check, Detail string }  // S1–S7 → 400 invalid_save con fields.check y fields.detail
func (e *InvalidSaveError) Error() string             // se devuelve siempre como puntero (errors.As con *InvalidSaveError)
var ErrNotFound = errors.New("not_found")             // Op y Ledger → 404
type CreateParams struct { RaceID string; Appearance [8]byte; StarterTemplateID string }
type SaveKey struct { WorldID int16; CharacterID int64; InstanceID [16]byte; ZoneID string }  // InstanceID: claimed_by
type Summary struct { RaceID string; Appearance [8]byte; Level int; LastZoneID string; LastChannel int
	PlayedSeconds int64 }
type Querier interface { // lo cumplen pgx.Tx y *pgxpool.Pool
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}
type ProgressStore interface {
	Create(ctx context.Context, tx pgx.Tx, worldID int16, characterID int64, p CreateParams) error
	Load(ctx context.Context, q Querier, characterID int64) (json.RawMessage, error)     // §3.4, la de la reclamación
	Apply(ctx context.Context, tx pgx.Tx, key SaveKey, progress json.RawMessage) (saveVersion int64, err error)  // S1–S8
	Summaries(ctx context.Context, q Querier, characterIDs []int64) (map[int64]Summary, error)  // lista, enter, nombre
	Purge(ctx context.Context, tx pgx.Tx, characterID int64) error                      // §3.5
	PurgeRetention(ctx context.Context, tx pgx.Tx) (deleted int64, emptied []int64, err error)  // §3.5; emptied: lápidas sin libro
	Export(ctx context.Context, q Querier, characterID int64) (json.RawMessage, error)   // §3.5
	Op(ctx context.Context, q Querier, opID int64, instance [16]byte) (json.RawMessage, error)  // ruta de operación;
		// ErrNotFound si no existe o si ningún participante tiene character_leases.zone_instance_id = instance
		// (un join en la misma consulta: la plataforma no lee op_participants)
	Ledger(ctx context.Context, q Querier, characterID int64, limit int,
		beforeEntryID int64) (json.RawMessage, error)                                    // limit 1–100; más recientes primero
}

// En el mismo archivo, también de plataforma.md P2 (su §7.5), con la implementación provisional de su §4.4 paso 5:
type CreateValidator interface {
	ValidateCreate(realm int16, raceID string, appearance [8]byte, templateID string) error  // nil o *ValidationError
}
type ValidationError struct{ Fields map[string]string }  // → 400 validation con estos fields; siempre como puntero

// platform/internal/progress
package progress

type Rules struct{ /* de gamedata: progression_rules.json, §13.4 */ }
func LoadRules(raw []byte) (*Rules, error)
// Creación (plataforma.md §4.4 paso 5): raza del reino, 8 B válidos para la raza y plantilla selectable.
// Implementa persistence.CreateValidator; serve la elige en lugar de la provisional.
func (r *Rules) ValidateCreate(realm int16, raceID string, appearance [8]byte, templateID string) error
	// &persistence.ValidationError{Fields: {"race_id": "wrong_realm"}}, {"appearance": "invalid"} o
	// {"starter_template_id": "not_selectable"}

type Store struct{ /* reglas y reloj inyectable */ }
func New(rules *Rules, now func() time.Time) *Store   // implementa persistence.ProgressStore; devuelve
                                                      // *persistence.InvalidSaveError y persistence.ErrNotFound
```

- Archivos: `store.go`, `checks.go` (S1–S7), `write.go` (S8), `summaries.go`, `retention.go`,
  `export.go` y sus pruebas; migraciones `internal/migrate/migrations/0010_progress.up.sql` y
  `.down.sql`, y la semilla `internal/migrate/testdata/seed_0010.sql`. Las reglas, con `//go:embed
  progression_rules.json` en `internal/gamedata`.
- En la frontera viaja JSON crudo; dentro, decodificación estricta (`jsonx.Int`, `jsonx.ID`,
  `DisallowUnknownFields`).
- `Load` arma el JSON de §3.4 desde las tablas (`location.saved_at_unix` desde `saved_at`); un personaje
  recién creado da el registro con los valores por defecto.
- `Summaries` es lo único que la plataforma lee del progreso fuera del guardado: raza, apariencia, nivel,
  última zona y canal, y tiempo jugado, para la lista de personajes, `enter` y la excepción de la reserva
  del nombre (plataforma.md §4.4 y §4.5).
- **Rutas.** Las registra el enrutador interno de plataforma.md §6, con sus comprobaciones (token,
  alcance, instancia `live` y arrendamiento en la instancia: el del personaje en el libro, que mira el
  enrutador; el de algún participante en la operación, que mira `Op` con la instancia que recibe; si no, 404),
  y llaman a `Op` y `Ledger`. La zona las pide con
  `ZonePlatform.request`, que pone `zone_instance_id` (plataforma.md §14.3). Los cuerpos son de aquí (ids en
  cadena):
  - `GET /internal/v1/ops/{op_id}?zone_instance_id=` → `{op: {op_id, kind, actor_account_id, ref_op_id,
    zone_id, note, detail, created_at_unix, participants: ["41", "42"], reversed_by, ledger: [{character_id,
    currency, seq, delta, balance_after, reason, ref_kind, ref_id}], items: [{character_id, uid,
    def_id, count_delta, reason}], instances: [{uid, def_id, count, durability, rarity, bound, seed,
    affixes, retired}]}}`, o 404.
  - `GET /internal/v1/characters/{id}/ledger?zone_instance_id=&limit=20&before_entry_id=` → `{entries:
    [{entry_id, op_id, currency, seq, delta, balance_after, reason, ref_kind, ref_id,
    created_at_unix}]}`; `limit` de 1 a 100 (20 por defecto), más recientes primero.
- Los casos de `tests/fixtures/progression/` (los de §13.3 y `appearance_cases.json`) se leen con
  `os.ReadFile("../../../tests/fixtures/…")` (no con `go:embed`, que no admite `..`): las pruebas de Go
  corren en el directorio del paquete. Es la misma raíz que los casos de nombres de plataforma.md §4.4
  (`tests/fixtures/names/`).

### 13.3 Comprobaciones del guardado (S1–S8)

Dentro del paso 4 de plataforma.md §7.3: el arrendamiento ya está bloqueado y comprobado y el `seq` es
nuevo (pasos 2 y 3, sin número S). Cualquier fallo de S1–S7 devuelve `&persistence.InvalidSaveError{Check,
Detail}` y el guardado entero se deshace. Un error de la base en S8 o en el COMMIT sigue la regla de errores de
plataforma.md §7.3 (clases 22 y 23 y `P0001` → `invalid_save` con `check = "S8"`; `40001`, `40P01` y sin
conexión → 503 y reintento).

| # | Comprobación |
|---|---|
| S1 | `progress_format` = 1. Claves conocidas y ninguna de solo lectura (`race_id`, `appearance`, `starter_template_id`, `location.saved_at_unix`). Todo id es una cadena decimal de 1 a 2^53 − 1 (`seed` y `ref_id`, desde 0); los demás enteros, números exactos. `location.zone_id` = `SaveKey.ZoneID` |
| S2 | **Operaciones.** Todo `op_id` del cuerpo cae en un bloque de `id_blocks` dado a `SaveKey.InstanceID` y **no está ya en `economy_ops`**: un `op_id` guardado antes falla siempre, sea cual sea su participante (I6). Si dos guardados a la vez traen el mismo, los dos pasan esta lectura y el segundo choca en S8 con la clave primaria de `economy_ops`, que S8 inserta sin `on conflict`: sale con `check = "S8"` (plataforma.md §7.3). En la fase 5 ninguna operación tiene dos participantes; la del comercio (fase 6) solo podrá entrar entera dentro de un mismo `SaveMany` (plataforma.md §7.3), con el mismo `kind`, `actor_account_id`, `note` y `detail` en los dos cuerpos, y esa excepción (con el `on conflict do nothing` que entonces necesita S8) se escribe con él. `kind` 1–5 en la fase 5 (MIGRATION, el 6, solo la crean las migraciones SQL) y, por tipo, solo sus motivos en apuntes y eventos: PLAYER 64; GAMEPLAY 2–6 y 65; STARTER_KIT 1; GM 7 y 66; REVERSAL 128. GM y REVERSAL, con `note` no vacía; `detail.at_unix` entero, no posterior a ahora + 60 s ni anterior en más de 60 s al `granted_at` del bloque de `id_blocks` que contiene su `op_id` (una operación no es más vieja que su id); y `actor_account_id` con rol `gm` o `admin` **en `detail.at_unix`** y `detail.actor_character_id` un personaje de esa cuenta, o `detail.source = "console"` sin actor ni `actor_character_id`; sobre un personaje de la cuenta del actor, solo `admin`. El rol en `detail.at_unix` es el `args.from` de la primera fila de `set-role` de la CLI posterior a esa hora (la fila fija de plataforma.md §9.1: `where source = 'cli' and command = 'set-role' and target_account_id = $actor and at > to_timestamp($at_unix) order by at, id limit 1`) o, si no hay ninguna, el de `accounts`: bajar de rol a un GM no invalida los guardados, aún en vuelo, de las operaciones que creó antes. Solo cuentan las filas `cli`: una zona no puede escribirlas (plataforma.md §6, «Lotes»). STARTER_KIT solo si `starter_granted` era false en la BD. REVERSAL: `ref_op_id` existe, es de este personaje, no es REVERSAL ni MIGRATION, no está en `op_reversals` ni es el `ref_op_id` de otra REVERSAL del mismo cuerpo |
| S3 | **Libro.** Por moneda y en orden: `balance_after = anterior + delta`, entre 0 y el tope, con el signo del rango de su motivo; el último es el saldo de la foto; una moneda sin apuntes no cambia de saldo |
| S4 | **Objetos (I4).** Por definición: Σ `count` vivas en la BD + Σ `count_delta` de los eventos = Σ `count` de la foto. Un evento con `uid` y `count_delta > 0` es de un uid que no estaba en la BD; con `count_delta < 0`, de un uid vivo de este personaje en la BD |
| S5 | **Foto.** Uids sin repetir; contenedor 0–1; ranuras únicas, bolsa < `bag_slots`, equipo 0–1; definición en las reglas; `count` 1 … `max_stack`; durabilidad según `has_durability`; rareza 0 y sin afijos en la fase 5; en el equipo, un WEAPON por ranura y la activa con arma (I10); un uid que ya estaba vivo en la BD para este personaje conserva `def_id`, `seed`, `rarity` y `affixes` y su `bound` no pasa a false (I1, I12): S4 cuenta por definición y no vería dos uids que se cambian el tipo. Un uid nuevo cae en un bloque de `id_blocks` dado a `SaveKey.InstanceID`; si ya existe en `item_instances` (vivo o retirado, de cualquier personaje) choca con la clave primaria al insertarlo (I1): es un error de la base de S8 y sale con `check = "S8"` (plataforma.md §7.3) |
| S6 | **Progreso.** `level = level_for(xp_total)` con la curva de las reglas; `xp_total` no baja sin una GM o REVERSAL en el guardado; `realm_points` nuevo = antiguo + Σ apuntes de méritos de motivo 3–5 + Σ apuntes de méritos de las REVERSAL de operaciones con méritos de motivo 3–5; `bag_slots` no cambia; `starter_granted` no vuelve a false; `active_weapon_slot` 0–1; `played_seconds` no baja; `health` null o entre 0 y la vida máxima de las reglas (`combat`) |
| S7 | **Temporizadores.** Claves `^[a-z0-9_:]{1,48}$`, 16 como mucho, `ends_at_unix ≤ ahora + 7 días`. **Las fechas pasadas valen**: un cuerpo reintentado puede llegar minutos después de construirse (plataforma.md §6) y un temporizador vencido no es un error (`on_arrival` descarta los vencidos) |
| S8 | **Escribe.** `character_progress` entero, con `saved_at = now()` y `save_version + 1`, que `Apply` devuelve; saldos con su `last_seq`; objetos: inserta los nuevos, actualiza los que cambian y retira los que faltan (`retired_at`, sin contenedor ni ranura); operaciones con `zone_id = SaveKey.ZoneID`, sin `on conflict` (un `op_id` repetido es un 23505 de `economy_ops_pkey` y sale con `check = "S8"`, S2), participantes, apuntes con su `seq`, eventos y `op_reversals`; una fila de `audit_log` por operación GM o REVERSAL (`event_key = "op:<op_id>"`, `on conflict (event_key) do nothing`) con `world_id` y `zone_id` de la instancia (`SaveKey`), `at = to_timestamp(detail.at_unix)` y `source`, `command`, `actor_account_id`, `actor_character_id`, `target_character_id`, `target_account_id` y `args` sacados de la operación: los mismos campos y valores que la entrada del lote (plataforma.md §9.1); temporizadores (sustituye el conjunto). No toca `characters` |

S3 a S6 repiten en Go lo que `InventoryOps`, `CurrencyRules` y `PlayerProgress` ya garantizan en
GDScript: son la red de seguridad contra un error de la zona, no la regla del juego. Para que las dos
implementaciones no diverjan, `tools/progression/write_fixtures.gd` genera con `PlayerProgress` los
casos de `tests/fixtures/progression/` (secuencias de guardados con su resultado esperado, válidos e
inválidos, uno por comprobación; entre ellos, dos uids que se cambian el `def_id` con los totales cuadrados, que
falla S5). Los casos se suben al repo; `test_progression_fixtures.gd` los
regenera en memoria y falla si difieren, y las pruebas de Go los leen.

### 13.4 Reglas exportadas

Un archivo, `platform/internal/gamedata/progression_rules.json`, con claves ordenadas, generado por
`ProgressionRulesExport.build()` (`scripts/shared/progression/`, P3) y escrito por
`tools/progression/export_rules.gd`. Una sola prueba, `tests/test_progression_rules_export.gd`: `build()`
da lo mismo dos veces y coincide con el archivo del repo. No hay otro generador, otra prueba ni
`appearance_limits.json`.

| Sección | Contenido | La define |
|---|---|---|
| `protocol_version` | `NetProtocol.PROTOCOL_VERSION` (el `ELDMARK_MIN_PROTOCOL` por defecto en `dev` y `test`) | plataforma.md §2.3 |
| `names` | `NameRules`: longitudes, letras, plegado y reservados | plataforma.md §4.4 |
| `races` | Ids, reino (el código de `NetProtocol.Realm`, 1–3: `build()` traduce `RaceDefinition.realm` con `RealmCatalog.code_of`), listas permitidas por categoría, `allows_no_hair` y `allows_no_beard` (§7.1, §7.2) | Este documento |
| `appearance` | Por categoría de pieza (`heads`, `hairs`, `beards`, `marks`), la lista de piezas con sus `bodies` compatibles (vacía = todos); de `bodies` y de las de color, los tamaños (§7.2). Con esto Go aplica la regla entera de `CharacterAppearance.validate` | Este documento |
| `starter_templates` | Las `EquipmentTemplate` con `selectable = true` (hoy `marksman` y `squire`) y sus armas (§2.5) | Este documento |
| `items` | Por definición: id, categoría, ranura, pila, durabilidad y `required_level` (§2) | Este documento |
| `level_curve` | La tabla de §6.1 | Este documento |
| `currencies` | Códigos y topes (§5.1) | Este documento |
| `reasons` | Rangos de motivos y tipos de operación (§5.3) | Este documento |
| `containers` | Contenedores y ranuras (§4.1) | Este documento |
| `combat` | Vida máxima (`CombatRules`, para S6) | Este documento |

Quien llegue antes (plataforma.md P2 o P3 de aquí) crea `build()`, la herramienta, la prueba y el archivo;
el otro añade sus secciones. En Go, `internal/gamedata` lo incrusta con `//go:embed` (que no lee fuera de
`platform/`); `internal/names` lee `names` y `progress.LoadRules` el resto.

## 14. Paquetes y contratos

### 14.1 Paquetes

Todo empieza con habilidades.md fusionado (H1a a H3c para P2 y P5b, H4 para P6). Los paquetes de
servidor esperan además a los de plataforma.md que se nombran.

| Paquete | Contenido | Depende de |
|---|---|---|
| **P1 · objetos** | `ItemDefinition`, `ItemInstance` (encode/decode, `to_dictionary`/`from_dictionary`), `ItemDatabase`, `data/items/` (§2.4), `tests/fixtures/items/`; `test_item_database`, `test_item_instance` | `CombatCatalog` |
| **P2 · inventario puro** | `InventoryState`, `InventoryOps` (con `Context.active_weapon_slot`, §4.1), `ItemEvent`, `EconomyReason`, `Currency`, `CurrencyRules`, `StarterKit`, `ActionMachine.set_weapons`; `test_inventory_ops`, `test_inventory_properties`, `test_currency_rules`, `test_action_machine_weapons` | P1; H1b |
| **P3 · progreso y apariencia** | `LevelCurve` y su `.tres`, `ProgressionRules`, `CharacterAppearance`, `AppearanceCatalog`, `AppearancePart`, `AppearanceColor`, `RaceDefinition`, `data/characters/`, `ProgressionRulesExport` y `tools/progression/export_rules.gd` (§13.4, si plataforma.md P2 no los ha creado), `tests/fixtures/progression/appearance_cases.json` (§7.2); `test_level_curve`, `test_character_appearance`, `test_progression_rules_export` | — |
| **P4 · protocolo** | `ProgressMessages` (0x50–0x55), LEVEL_UP, ids 40–43, `NetEntity.level`, `appearance` y `encode_spawn(…, receiver_realm)` con sus tres llamadas en `ZoneServer`, lo de aquí de la versión 7 (§12; la sube plataforma.md P4), `sim_hash`; recepción en `NetClient` (señales) y en `SwarmBot` (descarte); en red.md, las filas y la marca «v7» de lo de aquí (§12); `test_progress_messages` | P1, P3; H2 |
| **P5a · registro y sección** | `scripts/server/progress/`: `ProgressRecord` (con `to_claim_dictionary`), `LedgerEntry`, `EconomyOp`, `IdAllocator`, `PlayerProgress` (inventario, monedas, agregación, diario con `save_seq`, `build_section`, `acknowledge`, `is_dirty`), `ProgressService.setup`, `start`, `prepare`, `cancel_prepared`, `on_departure` (descartar el estado) y `on_platform_event`; la sección en `CharacterSaver` (`build`, `acknowledge`, `is_dirty`); el gancho antes del WELCOME y la baja en `LOADING`; la parte `progress` de `FakeZonePlatform` (la reclamación siguiente desde lo último aplicado, plataforma.md §14.1, y `claim_progress`; el resto de su API de pruebas es de plataforma.md P4, su §14.3); `tools/progression/write_fixtures.gd` y los casos; `test_progress_record` (con `ProgressRecord.FORMAT == ZonePlatform.RECORD_FORMAT`), `test_player_progress`, `test_progress_section`, `test_progression_fixtures` | P2, P3; plataforma.md P4 y P5 |
| **P5b · inventario en la zona** | Alta (`on_arrival` con la regla de volver al mundo de §8, `after_spawn`, `loadout_for`, donde H3c pone la plantilla), `handle_packet` en `_on_packet_received` (0x50–0x53, con RATE), `apply_pending` tras `_process_arrivals` (la ranura activa del `CombatState` en `Context`, el tope de DESTROY), `set_weapons` y LOADOUT, la reaparición con WEAPON_1 vacía (§8), CONSUME (`after_simulate`, tras el paso 1), CAMP_REFILL (`camp_step`, en el paso 8 en lugar de la recarga), cargas, `UnstuckTracker.get_ready_at`/`set_ready_at` y su clave, la llamada a `on_departure` en la salida (tras `CharacterSaver.finish`) y en la baja sin guardado, ganchos sin efecto sobre un `net_id` sin `PlayerProgress` (§9.2), efímeros, `NetEntity.level`; `test_progress_service`. `test_bot_swarm` y `test_net_processes` siguen con 0 malformados | P5a, P4; H3c |
| **P5c · recompensas** | `on_merits` (PRG-09), `on_npc_killed` (`xp_reward` y `gold_reward` en `NpcDefinition` y `data/npcs/`), `on_capture` (GUE-12) con su temporizador, XP, LEVEL_UP, PROGRESS_UPDATE, críticos, regla de `--fake-players`, de los cambios forzados del fuerte y de la marca `gm_forced` (§6.2); `test_progress_rewards` | P5b; plataforma.md P6 (lista de capturas y marca de cambio forzado); PRG-09, MUN-07, GUE-12 |
| **P5d · GM** | Comandos de §10 con `min_role`, ids 40–43, reglas de DEBUG_COMMAND en `_handle_debug_command` (con `admin` en 40–43, 5, 13 y 16; con plataforma, el 16 como operación GM y el 5 y el 13 solo en la auditoría, §4.4 y §10), `detail.at_unix`, regla de los propios personajes, rastro con el objetivo por id, zona cercada, reversión (una sola REVERSAL), `op_show` y `ledger_show` por las rutas; `test_gm_progress`, con las pruebas del id 40 y de `item_give` propio (las respuestas de `progress_op` y `progress_ledger`, con `FakeZonePlatform.script_next`, plataforma.md §14.3) | P5b; plataforma.md P7b (`min_role`); TEC-19 |
| **P6 · cliente** | `ClientInventory`, `InventoryWindow`, `CharacterWindow`, `InventorySlotView`, `SplitDialog`, `AppearanceApplier`, `HumanoidVisual.set_part`/`clear_part`, selector de plantilla oculto con billete (§2.5); `test_client_inventory`, `test_inventory_window`, `test_appearance_visual` | P2, P3, P4, UI-09; H4 |
| **P7 · almacén en Go** | `platform/internal/progress/` (§13.2), `0010_progress` con su `.down.sql` y `seed_0010.sql`, S1–S8, `Summaries`, `ValidateCreate`, purga, retención, exportación, `Op` y `Ledger`; pruebas de Go de §15 | plataforma.md P0 (`testdb`, `migrate`), P2 (interfaz `ProgressStore`) y P3 (rutas); P3 de aquí (reglas exportadas); los casos de P5a |
| **P8 · integración** | `test_progress_loopback`, `test_progress_platform_loopback`, `--bot-scenario=progress` del bot, `platform/e2e/progress_test.go` (§15) | P5a–P5d, P6, P7; plataforma.md P8 y P10 |

P1 y P3 van en paralelo; después P2 y P4; después P5a y P6 en paralelo; después P5b; después P5c y P5d en
serie. P7 empieza en cuanto estén plataforma.md P0, P2 y P3, P3 de aquí y los casos de P5a (que llega tras
plataforma.md P4 y P5); plataforma.md P9a y P10 esperan a P7. P8 al final. El protocolo lo sube plataforma.md
P4, que va antes que P4 de aquí; este añade lo suyo sin subirlo (§12).
`zone_server.gd` lo tocan los dos documentos en el orden de plataforma.md §14.1 (habilidades.md H3c → plataforma.md
P4 → P4 → plataforma.md P5 → P5a → P5b → plataforma.md P6 → P5c → plataforma.md P7b → P5d).

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
func to_dictionary(container: int, slot: int) -> Dictionary              # una entrada de §3.4; ids con str()
static func from_dictionary(data: Dictionary, db: ItemDatabase) -> ItemInstance  # null si no cuadra; ids: cadena con
		# is_valid_int() y to_int(); enteros con int() (acepta 820.0)
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
var bag_slots: int                                                       # sin ranura activa: es el bit0 de combat_flags2 (§4.1)
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
	var active_weapon_slot: int = 0               # bit0 de combat_flags2: del CombatState (servidor) o del predicho (cliente)
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
class_name Currency extends RefCounted         # enum Code { GOLD = 1, MERITS = 2 }; const CAP: int = 1_000_000_000
                                               # (en GDScript, ^ es XOR: 10^9 valdría 3)
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
func validate(catalog: AppearanceCatalog, realm: int, race_id: StringName) -> bool   # §7.2; realm: código de NetProtocol.Realm
static func random(catalog: AppearanceCatalog, race_index: int,
		rng: RandomNumberGenerator) -> CharacterAppearance
static func default_for(catalog: AppearanceCatalog, race_index: int) -> CharacterAppearance

class_name ProgressionRulesExport extends RefCounted
static func build() -> Dictionary     # §13.4; claves ordenadas: el JSON sale igual en cada llamada

# scripts/shared/combat/action_machine.gd (amplía): set_weapons de §4.1

# scripts/server/net_entity.gd (amplía)
var level: int = 0; var appearance: PackedByteArray
func encode_spawn(tick: int, for_owner: bool, receiver_realm: int = 0) -> PackedByteArray

# scripts/server/unstuck_tracker.gd (amplía)
func get_ready_at(player: String) -> int; func set_ready_at(player: String, tick: int) -> void

# scripts/server/progress/ (servidor; sin Time: la hora UTC es ZonePlatform.now_unix())
class_name ProgressRecord extends RefCounted     # la sección progress de §3.4
const FORMAT: int = 1                                             # progress_format; igual a ZonePlatform.RECORD_FORMAT (prueba)
var race_id: StringName; var appearance: PackedByteArray          # 8 B
var level: int = 1; var xp_total: int; var realm_points: int; var played_seconds: int; var bag_slots: int = 30
var starter_template_id: StringName; var starter_granted: bool; var active_weapon_slot: int   # la del registro (§8)
var health: int = -1                                              # −1 = llena (null en JSON)
var location: Dictionary                                          # vacío = null; §3.4
var inventory: InventoryState; var wallets: PackedInt64Array      # índice = moneda; [0] sin usar
var timers: Dictionary[String, int]                               # clave → ends_at_unix
static func new_character() -> ProgressRecord                     # efímeros (§9.4)
static func from_dictionary(data: Dictionary, db: ItemDatabase) -> ProgressRecord   # null si no cuadra (§3.4)
func to_dictionary() -> Dictionary                                # la del guardado: sin los de solo lectura ni ops
func to_claim_dictionary(saved_at_unix: int) -> Dictionary        # la de la reclamación: con los de solo lectura (pruebas)

class_name LedgerEntry extends RefCounted
var currency: int; var delta: int; var balance_after: int; var reason: int; var ref_kind: int
var ref_id: int
class_name EconomyOp extends RefCounted
enum Kind { PLAYER = 1, GAMEPLAY = 2, STARTER_KIT = 3, GM = 4, REVERSAL = 5, MIGRATION = 6 }
var op_id: int; var kind: int; var actor_account_id: int; var ref_op_id: int; var note: String
var detail: Dictionary; var ledger: Array[LedgerEntry]; var items: Array[ItemEvent]
var save_seq: int                                                 # 0 = aún en ningún guardado
func to_dictionary() -> Dictionary; static func from_dictionary(data: Dictionary) -> EconomyOp  # ids en cadena

class_name IdAllocator extends RefCounted
const BLOCK_SIZE: int = 1024; const REFILL_BELOW: int = 512; const SERVER_RESERVE: int = 256
var build_reserve: int = 128                                      # 2 × max_players; lo pone ProgressService.setup
static func local() -> IdAllocator                                # sin plataforma: desde 1, sin bloques ni tramos
func add_block(first: int, count: int) -> void
func needs_block() -> bool                                        # available() < build_reserve + REFILL_BELOW
func available() -> int
func next_for_client() -> int                                     # 0 si quedan ≤ build_reserve + SERVER_RESERVE
func next_for_server() -> int                                     # 0 si quedan ≤ build_reserve
func next_for_build() -> int                                      # solo build_section; 0 si no queda ninguno

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
func build_section(seq: int) -> Dictionary                        # §9.3; solo las operaciones con save_seq 0, que marca;
		# {} sin tocar nada si no hay id para cerrar lo agregado (§4.5)
func acknowledge(seq: int) -> void                                # quita las de save_seq ≤ seq
func is_dirty() -> bool                                           # diario, registro, posición o vida (§9.2)
func journal() -> Array[EconomyOp]                                # sin plataforma: las últimas 256

class_name ProgressService extends RefCounted
class Loadout:
	var weapon_1: int; var weapon_2: int; var second_active: bool; var charges: int
func setup(zone: ZoneServer, platform: ZonePlatform, saver: CharacterSaver,
		commands: CommandRegistry) -> void                             # platform y saver null sin plataforma
func start(s: int) -> void
func prepare(peer_id: int, claimed: ClaimedCharacter) -> bool       # §9.1 paso 2; el orden, plataforma.md §5.2
func cancel_prepared(peer_id: int) -> void   # baja en LOADING: descarta lo de prepare (§9.1 paso 3); sin nada, nada
func on_arrival(entity: NetEntity, peer: ServerPeer, s: int) -> Loadout   # kit, volver al mundo (§8), temporizadores
func after_spawn(entity: NetEntity, peer: ServerPeer, s: int) -> void
func loadout_for(net_id: int) -> Loadout                            # también al reaparecer (WEAPON_1 vacía: second_active)
func has_inventory(net_id: int) -> bool; func level_of(net_id: int) -> int
func handle_packet(peer: ServerPeer, bytes: PackedByteArray) -> void   # 0x50 y 0x53
func after_simulate(s: int) -> void                                 # CONSUME
func camp_step(entity: NetEntity, s: int) -> void                   # CAMP_REFILL
func apply_pending(s: int) -> void                                  # peticiones, tras las altas
func on_merits(net_id: int, amount: int, reason: int, victim_net_id: int, s: int) -> void
func on_npc_killed(npc: NpcDefinition, contributors: PackedInt32Array, s: int) -> void
func on_capture(fortress_id: StringName, owner_realm: int, in_circle: PackedInt32Array, s: int) -> void
		# in_circle: la lista de plataforma.md §8, la misma que suma ScoreKeeper.captures
func on_platform_event(event: PlatformEvent) -> bool                # kind id_block, progress_op y progress_ledger
func on_departure(net_id: int) -> void        # tras CharacterSaver.finish y ScoreKeeper.forget, o en la baja sin guardado
		# (plataforma.md §7.2). Todo gancho por net_id, sobre uno sin PlayerProgress, no hace nada (§9.2)
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
| P2 | `test_inventory_ops` | Tabla de casos: cada op y cada código de §4.2, en su orden; juntar parcial; pila de destino llena → intercambio; ligado al equipar; ranuras 2–6 → CANNOT_EQUIP; DESTROY de un consumible bebiendo → NOT_NOW; solo DESTROY da eventos; con `Context.active_weapon_slot` = 1 (tras un SWAP), desequipar WEAPON_2 → WEAPON_REQUIRED y desequipar WEAPON_1, OK |
| P2 | `test_inventory_properties` | 20 semillas × 1000 operaciones aleatorias (válidas e inválidas), con invariantes incrementales (cantidad por definición y uids vivos y muertos, que actualizan los eventos de cada `Outcome`) y la comprobación completa cada 100 operaciones y al final: la cantidad no cambia sin evento, ningún uid se repite ni vuelve, ranuras únicas, la activa con arma; tras CAMP_REFILL, `count_of(def) ≤ max(camp_refill, antes)`, con un caso de tabla de la pila dividida. Menos de 5 s medidos. La versión larga (20 × 5000) solo con `--filter=inventory_properties_long` |
| P2 | `test_currency_rules` | Topes, negativos, dos operaciones del mismo tick sobre un saldo, reconstrucción desde los apuntes |
| P2 | `test_action_machine_weapons` | `set_weapons` conserva cargas, `consumable_ready_tick` y ranuras de movimiento; reparte `ability_ready` por arma; con acción, no hace nada |
| P3 | `test_level_curve` | 39 valores crecientes; `level_for(total_to(n)) = n`; varias subidas con un solo aporte; tope |
| P3 | `test_character_appearance` | Ida y vuelta de 8 B; los casos de `appearance_cases.json` (los mismos que lee Go); `validate` rechaza cada índice fuera de rango, la raza de otro reino, un byte 0 que no es el de `race_id`, una pieza de otro cuerpo y un 0 de pelo o barba en una raza que no lo admite; 100 aleatorias válidas por raza; `appearance_ids.txt` es prefijo del catálogo; el catálogo solo nombra escenas que existen; `stat_modifiers` vacío |
| P3 | `test_progression_rules_export` | La única prueba del archivo (§13.4): `build()` da lo mismo dos veces, contiene las secciones de §13.4 (las tres razas, las plantillas `selectable`, los objetos, la curva, los topes y los rangos de motivos) y coincide con `platform/internal/gamedata/progression_rules.json` |
| P4 | `test_progress_messages` | Ida y vuelta de 0x50–0x55, SPAWN con nivel y apariencia y LEVEL_UP; null con cada malformación; ninguno pasa de 1200 B; DEBUG 40–43; `encode_spawn` con un receptor de otro reino da `level` 0 |
| P5a | `test_progress_record` | `ProgressRecord.FORMAT == ZonePlatform.RECORD_FORMAT`; ida y vuelta de `ProgressRecord` por `to_claim_dictionary`, `JSON.stringify`, `parse_string` y `from_dictionary`, campo a campo, con `location` y sin ella; ids en cadena (un id como número → null) y enteros reescritos como `820.0` aceptados; null con una clave que falta o desconocida, un id no entero o ≥ 2^53; `to_dictionary` no lleva los campos de solo lectura |
| P5a | `test_player_progress` | Kit de inicio (por plantilla y por defecto); agregación (un apunte por moneda, motivo y referencia); el cierre antes de una operación suelta (ganancia, `currency_add`, guardado: S3 cuadra); `build_section` y `acknowledge`; con `n` en vuelo, `build_section(n + 1)` no repite las operaciones de `n` y `acknowledge(n)` no quita las de `n + 1`; los tres tramos de ids (con `build_reserve` libres, CAMP_REFILL no abre pila nueva y `build_section` aún cierra lo agregado; sin ninguno, devuelve `{}` y no cambia nada); DESTROY con 256 operaciones sin confirmar → NOT_NOW; ninguna habilidad ni consumible de `CombatCatalog` dura 30 s o más; `ends_at_unix` sale entero y redondea hacia arriba (`ceili`) |
| P5a | `test_progress_section` | Con `FakeZonePlatform` (plataforma.md P4): sección registrada; reintento con el mismo cuerpo; `duplicate` confirma; `lease_lost` descarta (`on_departure`); 400 `invalid_save` expulsa y libera, y después ningún gancho de `ProgressService` falla con ese `net_id`; `is_dirty` con solo moverse o perder vida; `prepare` con un `progress` roto → REJECT `UNAVAILABLE` y liberación; irse en `LOADING` → `cancel_prepared` y liberación; la reclamación siguiente del falso trae lo último aplicado; el final construido con un guardado en vuelo se aplica tras él sin `invalid_save` |
| P5a | `test_progression_fixtures` | Los casos de `tests/fixtures/progression/` coinciden con los que genera `write_fixtures.gd` |
| P5b | `test_progress_service` | Alta con el `Loadout` del inventario y la ranura activa; equipar y desequipar sin reiniciar reutilizaciones; CONSUME al comprometer y no al interrumpir; CAMP_REFILL por total y con la cadencia de habilidades.md; cargas `min(15, bolsa)`; peticiones antes del mundo → aviso; un cliente que manda 10 000 SPLIT y juntar: ningún evento, ids acotados por RATE y otro jugador sigue bebiendo y guardando; `/atascado` restaurado por su clave; muerto se guarda para reaparecer (vida y campamento al volver); un `squire` que pone el arco en WEAPON_2, cambia a él (Q) y desequipa WEAPON_1 muere y reaparece con el arco activo, y su siguiente guardado pasa S5 |
| P5c | `test_progress_rewards` | Méritos de una víctima persistente de otro reino → apunte y XP; matar a un falso o a un PNJ no da méritos; PNJ con dos contribuyentes → los dos cobran; dos capturas en 30 min pagan una; un GM invisible en el círculo no cobra la captura; un personaje llevado al círculo con `/gm teleport` o un GM que se hace visible en él con `/gm visible` no cobra captura, méritos ni PNJ hasta reaparecer, y después sí; una captura forzada por un GM en el círculo (`fort_owner` o con `fort_capture_speed`) y el capitán muerto con `fort_kill_captain` no pagan a nadie; `--fake-players` con plataforma → nada; subida de nivel → LEVEL_UP solo al mismo reino y crítico |
| P5d | `test_gm_progress` | Da un objeto, lo divide en 3 y 2, junta las 2 con otra pila y lo revierte: el total baja 5 y se encuentran el GM_GRANT, la REVERSAL y sus apuntes; segunda reversión rechazada, también la que llega antes de guardar la primera; con plataforma falsa y rol `player`, el id 41 no cambia el saldo y suma un aviso; DEBUG_COMMAND 40 sin rol → aviso, ni objeto ni guardado; el 16 con rol `gm` → aviso, y con `admin` crea una operación GM con GM_GRANT y `note` «debug» que el guardado acepta; el 5 y el 13 con `admin` no crean operación y dejan su entrada de auditoría; `item_give` y `op_revert` de un `gm` sobre su propio personaje, rechazados (también con `env` `dev`); `detail.args` lleva el `character_id` del objetivo, no su nombre; con la zona cercada, `item_give` responde «El servicio de cuentas no responde…» y no crea la operación; `level_set` deja `detail` con antes y después y `at_unix` |
| P6 | `test_client_inventory`, `test_inventory_window` | Optimista, confirmación, rechazo que devuelve el objeto, deltas del servidor intercalados, plazo de 5 s; arrastrar, dividir y destruir simulados generan la petición correcta |
| P6 | `test_appearance_visual` | Todas las combinaciones de piezas que existen (cuerpo, cabeza, pelo y barba, con y sin) con un color aleatorio cada una, y 100 aleatorias, aplicadas a `HumanoidVisual` sin errores del motor; `set_part` no recrea el nodo |
| P7 | Go: `TestCreateLoad` | Crear, guardar, recargar y comparar campo a campo (PRG-10); `ValidateCreate` con los casos de `appearance_cases.json`, raza de otro reino y plantilla que no es `selectable`, cada uno con su `*persistence.ValidationError` y sus `fields` |
| P7 | Go: `TestApply*` | Cada caso de los fixtures con su resultado; S1–S8 uno a uno; `saved_at` y `save_version` escritos; auditoría con `op:<op_id>` sin duplicar, también de una REVERSAL; S7 acepta un temporizador vencido en un reintento tardío; un `uid` u `op_id` fuera de los bloques de la instancia → `*persistence.InvalidSaveError`; una MIGRATION, un motivo de otro tipo, dos REVERSAL de la misma operación, una REVERSAL de un `gm` sobre su propia cuenta y un `op_id` ya guardado para otro personaje → S2; una GM de un actor bajado a `player` por un `set-role` posterior a su `detail.at_unix` pasa, y una creada después del `set-role`, no; una fila `set-role` con `source = 'zone'` no cuenta; un `detail.at_unix` anterior en más de 60 s al `granted_at` de su bloque, o un `actor_character_id` de otra cuenta → S2; la fila de auditoría lleva `at = detail.at_unix`; intercambio de ranuras con la restricción diferida |
| P7 | Go: `TestDuplicateUid` | Dos guardados a la vez de dos personajes con el mismo `uid` nuevo: uno falla con `check = "S8"` y nada se duplica. Lo mismo con el mismo `op_id`: uno falla con `check = "S8"` y la operación queda con un solo participante |
| P7 | Go: `TestWalletConcurrency` | Dos transacciones a la vez sobre un saldo (§5.4); reconstrucción del saldo |
| P7 | Go: `TestTwoCharacterOp` | El esquema, en SQL: una operación con dos participantes en una transacción; el mismo participante dos veces falla. Por `Apply`, la misma operación en el guardado de otro personaje falla S2 (la excepción de `SaveMany` es de la fase 6) |
| P7 | Go: `TestPurgeKeepsLedger`, `TestRetention` | Purga de un personaje con kit y apuntes dentro de la purga de la cuenta: la fila de `characters` queda como lápida, sin objetos y con el libro; un `delete` del libro sin la marca falla; con el reloj a +366 días, `PurgeRetention` lo borra, devuelve la lápida en `emptied` y deja las operaciones de otros |
| P7 | Go: `TestSummaries`, `TestExport` | `Summaries` de varios personajes (con y sin `location`); `Export` con el registro y lo propio del libro; de una lápida, sin registro; las GM y REVERSAL sin actor, `note` ni `detail` |
| P7 | Go: `TestOpLedger` | `Op` (con las filas retiradas, `reversed_by` y `participants`) y `Ledger` con paginación y `limit` de 1 a 100; `Op` con una instancia en la que no está ningún participante → `ErrNotFound`; 404 |
| P8 | `test_progress_loopback` | Dos clientes por `NetHarness`, sin plataforma: equipar el arco desde la bolsa cambia el arma del otro por LOADOUT, la barra y 0 correcciones sin explicar; un rechazo devuelve el objeto; un cliente de otro reino recibe `level` 0 y uno del mismo, el real; beber gasta una poción de la bolsa |
| P8 | `test_progress_platform_loopback` | Con `FakeZonePlatform` (plataforma.md §14.3: `add_character` con `claim_progress(&"race_vardheim", …, &"marksman")` y los ids desde `next_block_first`) y billetes de prueba: personaje creado con `marksman` → kit; LOADOUT_SELECT ignorado; beber, reponer, `/atascado`; salir y volver conserva uids, equipo, arma activa, saldos y la reutilización de 5 min (menos lo transcurrido); vuelve al campamento |
| P8 | Go: `platform/e2e/progress_test.go` | `TestProgressEndToEnd`, con el arnés de plataforma.md P10 (con `test_world` como zona de entrada de los dos reinos): plataforma en el proceso, PostgreSQL efímero, `test_world` con `--platform --debug-commands`, cuenta `admin` y `--bot --bot-scenario=progress --report=<ruta>` (equipa el arco, da 50 de oro y una poción por DEBUG_COMMAND y sale); `Load` de la BD frente al informe del bot, campo a campo. `TestProgressCrash`: lo mismo con `kill -9` a la zona tras el delta del oro; por SQL, Σ `delta` = saldo, por definición Σ `count_delta` = Σ `count` vivas, y el bot vuelve a entrar con lo mismo |

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
| Precisión de JSON: un id de 2^53 o más se corrompe sin avisar en Godot | Ids como cadena (plataforma.md §4.1): `jsonx.ID` en Go y `to_int()` en GDScript, exactos hasta 2^63 − 1; además, los del progreso salen de secuencias y bloques desde 1, y la zona y el servicio rechazan los que pasan de 2^53 − 1 (§3.4, S1) |
| Net ids alfabéticos: añadir un objeto cambia los de los demás | Entran en el `sim_hash`; la BD nunca guarda net ids; a otros clientes nunca viajan |
| Reutilizaciones de menos de 30 s: reconectar las reinicia | Las limita el tiempo de reconexión y, en combate, el cuerpo que se queda 15 s (GUE-41); se revisa con la telemetría |
| Encaje con habilidades.md: `set_weapons`, el reparto de cargas y el cambio de la recarga dependen de H1b, H3c y H4 | Los nombres de habilidades.md mandan; si cambian, se ajustan §4.1, §4.4 y §8 al integrar |
| Sin persistencia local sin plataforma (el usuario desarrolla en Windows) | `deploy/dev.sh` o el compose de plataforma.md; sin ellos, todo funciona en efímero |
| Abuso con dividir y juntar, o con clientes que gastan ids | No dejan eventos (§4.3), RATE de 2/s para lo que gasta ids y reserva del servidor (§4.5) |
| Volumen del guardado | Unos 40 objetos (~4 KB de JSON) y una GAMEPLAY por guardado; con 1000 jugadores y un guardado por minuto, ~70 KB/s hacia el servicio; el cuerpo de la API interna, 1 MB como mucho (plataforma.md §6). Se mide en TEC-25 |
| Retención de un año: datos de un personaje purgado | Sin nombres (lápida y `detail.args` por id); mientras la cuenta exista, ligados a ella y exportables; seudónimos solo tras purgarla (§3.5); revisión legal (§16) |

## 18. Revisión

Tres revisores (seguridad, coherencia e implementabilidad): 41 hallazgos sobre la versión 1, los
repetidos en una fila. Comprobados en el código, en plataforma.md (0f6781b) y en habilidades.md
(32e23af): todos se sostienen. En ocho filas la solución es otra que la propuesta o se queda en parte
(«en parte», «de otra forma»). Las filas son la historia de la revisión; lo que cambió después, al
conciliar con plataforma.md, está en las cuatro últimas filas y en §13.1.

| Id | Gravedad | Qué era | Qué se hizo |
|---|---|---|---|
| PR-SEG2 · PR-COH2 · PR-IMP1 | bloqueante | Dos tuberías de carga y guardado incompatibles con plataforma.md: WELCOME antes del un solo uso y las sanciones, `begin_load` sin `lease_token`, dos idempotencias (`save_id`/`base_version` frente a `lease_id`/`seq`), dos generadores de uid, JSON distinto (cadenas frente a números, campos repetidos en `state`), raza y apariencia distintas | El progreso es la sección `progress` de `CharacterSaver`; llega en la reclamación y `prepare` corre antes del WELCOME; idempotencia `(lease_id, seq)`; fuera `save_id`, `base_version`, VERSION_CONFLICT y la antigua S2 (`save_version` se queda como contador que no interviene en la idempotencia, plataforma.md §7.3; nota de la conciliación); un solo generador (`item_uid_blocks`); vida, posición y tiempo jugado solo en `state`; números < 2^53; `race_<reino>` y 8 B pedidos a plataforma.md (§0, §3, §9, §13.1). **En parte**: sin `starter_template_id` al crear (la plantilla se elige en la primera entrada) |
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
| PR-COH10 · PR-IMP9 | importante | Creación sin `starter_template_id`, razas distintas, dos archivos de reglas, apariencia de 0–64 B; `go:embed` no admite `..` | Un solo `progression_rules.json` dentro de `platform/internal/gamedata/`, escrito por la herramienta de plataforma.md con `ProgressionRulesExport`; 8 B y `race_<reino>` pedidos (§13.1). **En parte**: sin `starter_template_id` al crear. *Conciliación*: la plantilla se elige al crear y es el kit de la primera entrada (§2.5); la herramienta es `tools/progression/export_rules.gd`, con una sola prueba (§13.4) |
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
| Conciliación | bloqueante | Tras las revisiones, este documento (§13.1) y plataforma.md (§17) seguían con dos listas de peticiones que no casaban | Interfaz conciliada (§13.1): una regla por tema, en el documento dueño, y la cita en el otro. Aquí: `save_version` y `saved_at` vuelven a `character_progress` (§3.3); raza, apariencia, posición, vida y tiempo jugado pasan al registro y a `character_progress`, sin `characters.state` ni `characters.level` (§3.1, §3.4); la regla de volver al mundo se escribe aquí (§8); no hay `CharacterRecord` (la reclamación trae `progress`, §9.1); sección sin `restore` y con `is_dirty`, y respuestas de plataforma.md §7.3 (§9.2); ids en cadena (§0, §3.4, S1); bloques de `id_blocks` de plataforma.md (§4.5, S2, S5); lápida única en `characters`, sin `progress_tombstones` (§3.5); tablas sin `world_id` y con clave ajena sin cascada por `op_participants` (§3.3); `ProgressStore` con `Summaries` y `ValidateCreate`, sin `ErrFormat` ni `RegisterInternalRoutes` (§13.2); S7 admite fechas pasadas (§13.3); reglas exportadas en §13.4; plantilla al crear (§2.5); guardia de entorno por el `env` del registro (§10) |
| Revisión de la conciliación | bloqueante | Revisores sobre los dos documentos ya conciliados (43 hallazgos, varios repetidos; todos se sostienen). Aquí: el final repetía las operaciones del guardado en vuelo; `op_revert` (REVERSAL) fuera de S2 y S8, MIGRATION desde las zonas, motivos sin comprobar y dos reversiones sin guardar; `ValidateCreate` sin los datos de la regla de la apariencia ni casos comunes; errores del progreso en `internal/progress` (ciclo de imports); ida y vuelta de `ProgressRecord` imposible; DEBUG_COMMAND 5, 13 y 16 con `gm`; `detail.args` con nombres; libro de una lápida sin exportar | Diario con `save_seq = 0` por cuerpo (§4.3, §9.2); una sola REVERSAL con actor y `detail`, S2 con tipos 1–5 y sus motivos, S8 para GM y REVERSAL (§3.3, §10, §13.3); byte 0 = `race_id`, reglas con `bodies` y `allows_no_*`, `appearance_cases.json` (§7.2, §13.4); `persistence.InvalidSaveError` y `ErrNotFound` (§13.2); `to_claim_dictionary` y `cancel_prepared` (§3.4, §9.1, §14.2); `admin` en 5, 13 y 16 (§4.4, §10); objetivo por id y exportación sin datos del personal (§3.5, §10); `PurgeRetention` con `emptied` (§3.5); el protocolo lo sube plataforma.md P4 (§12, §14.1). Tabla de §13.1 al día |
| Segunda revisión de la conciliación | bloqueante | 30 hallazgos sobre los dos documentos (varios repetidos; todos se sostienen, y en cuatro la solución difiere en parte de la propuesta). Aquí: puntos de reino «que nunca bajan»; dos fuentes de la ranura activa y reaparición con WEAPON_1 vacía; `refill` como CAMP_REFILL o como GM; `ValidateCreate` sin costura; `Op` sin la instancia; S2 con el rol del actor al aplicar y con `op_id` ya guardados; hora de la auditoría; comandos del fuerte que pagaban al GM; ganchos sobre un `net_id` sin progreso; `10^9` y `ceil` en GDScript; P5c sin plataforma.md P6 | I9 en §0 y en el backlog; la ranura activa es el bit0 de `combat_flags2`, en `InventoryOps.Context`, y al reaparecer WEAPON_2 si WEAPON_1 está vacía (§4.1, §8); `refill` con plataforma es una GM con GM_GRANT, y el 5 y el 13 solo van a la auditoría (§4.4, §10); `CreateValidator` y `ValidationError` (§13.2); `Op(…, instance)` (§13.2); S2 con el rol en `detail.at_unix` y sin `op_id` repetidos (de otra forma: en la fase 5 falla siempre; la excepción de `SaveMany` llega con el comercio) (§13.3); `at_unix` en `detail` y en S8 (§10, §13.3); cambios forzados del fuerte sin recompensa (§6.2); ganchos sin efecto (§9.2); `CAP` y `ceili` (§8, §14.2); tope de DESTROY (§4.2); dependencias de P5a y P5c (§14.1). plataforma.md, §17 |
| Tercera revisión de la conciliación | bloqueante | Los mismos 25 hallazgos (23 distintos; plataforma.md §18). Aquí: un `op_id` repetido en dos guardados a la vez pasaba por el `on conflict do nothing` de S8; un uid duplicado salía como S5 o como S8; `last_save_version` fuera de §3.1; el reino en tres representaciones; `build_section` sin ids en una caída larga; S2 sin la fila fija de `set-role`, sin cota inferior de `at_unix` y sin mirar `actor_character_id`; un uid podía cambiar de definición; `/gm teleport` y `/gm visible` pagaban | S8 sin `on conflict` en `economy_ops` y el uid duplicado como S8 (§13.3; pruebas en P7); §3.1; el reino en código de `NetProtocol.Realm` en `validate`, las reglas y los casos (§7.2, §13.4, §14.2); tres tramos de ids y `build_section` que devuelve `{}` (§4.4, §4.5, §9.2, §14.2; **en parte**: el final no espera al siguiente bloque, plataforma.md §7.2); S2 con la fila `cli` de `set-role`, el `granted_at` del bloque y el personaje del actor (§13.3); I1 y S5 con la definición fija (§3.2, §13.3); `gm_forced` (§6.2); filas y marcas «v7» de lo de aquí en red.md (§12, §14.1); API de `FakeZonePlatform` citada en P5a, P5d y P8 (§14.1, §15). Tabla de §13.1 al día |

La interfaz con plataforma.md quedó conciliada después de la revisión: §13.1 dice qué se acordó y en qué
documento está cada regla. Lo que las filas de arriba nombran y ya no existe (`item_uid_blocks`, `state`,
`characters.level`, `world_id` en las tablas del progreso, `CharacterRecord`, tablas de solo añadir sin
clave ajena, reglas de posición y vida en plataforma.md, `ServerMain` que no arranca, la herramienta de
plataforma.md, la plantilla en la primera entrada) es anterior a la conciliación.

## 19. Implementación

Lo que hizo cada paquete, en qué se aparta de este documento y lo que se midió. Cada paquete añade su
apartado al terminar.

### 19.1 Lo que adelantó plataforma.md P2

plataforma.md P2 (su §19.3) llegó antes que P3 de aquí, así que creó lo que §13.4 da a «quien llegue antes»:

- **Reglas exportadas.** `ProgressionRulesExport` (`scripts/shared/progression/progression_rules_export.gd`)
  con `build()` y `to_json()` (claves ordenadas, tabuladores y un salto de línea al final) y las dos secciones de
  plataforma.md, `protocol_version` y `names`; `tools/progression/export_rules.gd`, que escribe
  `platform/internal/gamedata/progression_rules.json` (con `-- --check` solo compara); y la única prueba,
  `tests/test_progression_rules_export.gd`: `build()` determinista, el archivo al día, claves ordenadas y las
  secciones de plataforma.md. En Go, `internal/gamedata` lo incrusta y da `Raw()` entero.
- **La frontera de §13.2** en `platform/internal/persistence/progress.go`, con las firmas tal cual
  (`ProgressStore`, `Querier`, `CreateParams`, `SaveKey`, `Summary`, `InvalidSaveError`, `ErrNotFound`,
  `CreateValidator` y `ValidationError`), la validación provisional (`ProvisionalValidator`) y el falso
  (`MemoryProgressStore`, en `memory.go`), que `serve` usa en `dev` y `test` hasta tener P7 (en `staging` y
  `production` no arranca con él).

**Para P3 de aquí:** cada sección nueva (`races`, `appearance`, `starter_templates`, `items`, `level_curve`,
`currencies`, `reasons`, `containers` y `combat`) entra en `build()` con su propia función, como `_names`, y sus
comprobaciones van en la misma prueba; después se vuelve a exportar el archivo y se sube con el cambio.
`gamedata` no mira las claves que no son de plataforma.md, así que nada de Go se rompe al añadirlas.
**Para P7:** `progress.LoadRules(gamedata.Raw())`; `*progress.Rules` implementa `persistence.CreateValidator` y
el almacén `persistence.ProgressStore`; `serve` los elige cambiando solo `progressStore()` de
`platform/cmd/eldmark-platform/services.go`. La plataforma ya usa `Summaries` así: `LastZoneID` vacío es «nunca ha
entrado», y un personaje que el almacén no devuelve sale en la lista con raza, apariencia y última zona a null y
nivel 1. `Purge` ya se llama desde la purga de personajes de plataforma.md (§11.2), dentro de su transacción y con
el arrendamiento y la fila del personaje bloqueados.

### 19.2 Lo que dejó plataforma.md P3

plataforma.md P3 (su §19.4) montó la API interna sobre la interfaz `ProgressStore`, así que P7 solo tiene que
implementarla:

- **Rutas de §13.2.** `GET /internal/v1/ops/{op_id}?zone_instance_id=` llama a `Op(ctx, pool, opID,
  instance)` fuera de transacción y responde su JSON tal cual (o 404 con `ErrNotFound`); `GET
  /internal/v1/characters/{id}/ledger?zone_instance_id=&limit=&before_entry_id=` mira antes el arrendamiento
  del personaje en la instancia, valida `limit` (1–100, 20 por defecto) y `before_entry_id` (0 sin él) y llama
  a `Ledger(ctx, pool, …)`. Las dos exigen la instancia `live` (§6.1 de plataforma.md).
- **Guardado.** `Apply(ctx, tx, key, progress)` corre en la transacción que ya tiene el arrendamiento
  bloqueado y el `seq` comprobado, con `key.ZoneID` de la instancia `claimed_by` y `key.WorldID` del
  arrendamiento; un `*InvalidSaveError` o un SQLSTATE de clase 22 o 23 o `P0001` (también en el COMMIT) son 400
  `invalid_save`, y un `40001` se reintenta con la transacción entera. Un `duplicate` no llama a `Apply`. Desde la
  revisión de la implementación de plataforma.md (su §19.7), la clase 22 (un dato que la base no admite: un NUL en
  un `jsonb`, un número o una fecha fuera de rango) cuenta como la 23: antes era un 500 que la zona reintentaba sin
  fin.
- **Reclamación.** `Load(ctx, tx, characterID)` corre en la transacción de la reclamación, con el
  arrendamiento recién tomado; un error de `Load` es un 500.
- **El falso** (`MemoryProgressStore`) imita una S2 mínima (un `op_id` ya aplicado falla) y `Op` con la
  consulta de los arrendamientos de los participantes: las pruebas de P7 con el almacén de verdad son las que
  dicen que S1–S8 y el `join` de `op_participants` hacen lo mismo.

### 19.3 Lo que deja plataforma.md P7a

plataforma.md P7a (su §19.5) escribe la fila de `set-role` que lee S2 (§13.3) y da la consulta hecha:

- **`sanctions.RoleAt(ctx, q, accountID, at)`** (`platform/internal/sanctions/roles.go`) es la regla de S2 tal
  cual: el `args.from` de la primera fila de `audit_log` con `source = 'cli'`, `command = 'set-role'` y
  `target_account_id` la cuenta, con `at` posterior al instante (`order by at, id`), o, si no hay ninguna, el
  rol de `accounts`; "" si la cuenta no existe. P7 la llama dentro de `Apply` con `time.Unix(detail.at_unix, 0)`
  y la transacción del guardado. Su prueba (`TestRoleAtOnlyReadsCLI`) comprueba que una fila `set-role` con otro
  `source` no cuenta y que el lote de auditoría de la zona rechaza las entradas con `source = 'cli'` o `command =
  'set-role'`.
- **El orden de los bloqueos:** `set-role` bloquea las filas de `accounts` del `--actor` y del objetivo (`for no
  key update`, en orden de id) y escribe la fila con la hora de Go en la misma transacción que cambia el rol.
- **Auditoría sin datos personales:** las filas de la CLI y de la plataforma nunca llevan correos ni nombres en
  `args` (plataforma.md §9.1); las de S8 siguen la misma regla (el objetivo por id en `detail.args`, §10).

### 19.4 P3 · progreso y apariencia (PRG-13, PRG-14, ART-19)

**Qué hay.** Lo de §14.1 P3, en `scripts/shared/progression/` salvo donde se dice:

| Pieza | Contenido |
|---|---|
| `LevelCurve` y `data/progression/level_curve.tres` | La tabla de §6.1 (39 valores, tope 40, un punto de atributo por nivel). `shared()`, `total_to`, `level_for`, `xp_for_next` (la XP del nivel al siguiente, 0 en el tope: la que pide PROGRESS_UPDATE) y `get_errors` |
| `ProgressionRules` | `XP_PER_MERIT`, `XpResult`, `add_xp` y `attribute_points` (§6.3) |
| `AppearancePart`, `AppearanceColor`, `RaceDefinition` | Los recursos de §7.2. Las escenas y texturas van como rutas (`String`), nunca como recursos cargados. `RaceDefinition` añade `description` (lo propio del pueblo, para la creación) y `allowed(categoría)` |
| `AppearanceCatalog` | `shared()`, `race_index`, `race_for_realm`, `entries`, `ids_of`, `fitting_indices` y `get_errors`: ids con formato y sin repetir, tamaños que caben en los 8 B (16 colores de ojos y 15 marcas como mucho), al menos un cuerpo, una cabeza y un color de cada tipo, piezas con cuerpos que existen y, por pueblo, reino jugable, índices que existen sin repetir, una cabeza (y pelo o barba si no admite ir sin ellos) para cada cuerpo permitido y `stat_modifiers` vacío |
| `CharacterAppearance` | Los 8 B: `encode`, `decode`, `validate`, `random`, `default_for` y `equals` |
| `data/characters/` | `appearance_catalog.tres`; `races/race_vardheim.tres`, `race_solmarch.tres` y `race_askarra.tres`; `appearance_ids.txt` («categoría índice id», con tres líneas de comentario `#` al principio) |
| `ProgressionRulesExport` | Las secciones `races`, `appearance`, `level_curve`, `currencies`, `reasons`, `containers` y `combat`; el archivo exportado de nuevo |
| `tests/fixtures/progression/appearance_cases.json` | 40 casos escritos a mano (7 válidos), uno o más por regla: raza y reino, cada índice fuera de rango, lo que no permite cada pueblo, y tamaños de 0, 7 y 9 B |
| `platform/internal/progress/rules.go` | El paquete de P7 empieza aquí: `LoadRules` (las siete secciones, cada una estricta con `jsonx.DecodeBytes`, y las mismas comprobaciones que `get_errors` del catálogo y de la curva, más las de monedas, motivos, contenedores y vida), `ValidAppearance` (la regla de `validate`), `RaceIndex`, `TotalTo` y `LevelFor` |

**El catálogo de la fase 5** solo tiene lo que hay en el repo (§16): el cuerpo `body_male` (`Male_Ranger.gltf`, el
traje de explorador con su cuerpo), la cabeza `head_superhero_male` (`Superhero_Male_Head.gltf`), el peinado
`hair_simple_parted` (`Hair_SimpleParted.gltf`) y la barba `beard_full` (`Hair_Beard.gltf`); ninguna marca. La
cabeza y la barba encajan solo con el cuerpo 0 y el peinado con todos, para que un cuerpo femenino (ART-20) no
herede una cabeza ni una barba masculinas. Colores: 8 tonos de piel (la paleta completa en los tres reinos, §0),
10 de pelo y 7 de ojos. Lo que distingue a los pueblos (provisional, **tomado de noche**, hasta ART-20 y el visto
bueno visual de §16):

| Pueblo | Pelo (índices) | Ojos (índices) | Sin pelo | Sin barba |
|---|---|---|---|---|
| `race_vardheim` | castaño, caoba, pelirrojo, cobrizo, rubio, rubio pajizo, ceniza, canoso (2–9) | avellana, verdes, azules, grises, azul hielo (1, 3–6) | no (trenzas y melenas) | no (barbas largas) |
| `race_solmarch` | negro, castaño oscuro, castaño, caoba, rubio, canoso (0–3, 6, 9) | marrones, avellana, ámbar, verdes, azules (0–4) | sí (tonsura) | sí |
| `race_askarra` | negro, castaño oscuro, caoba, pelirrojo, ceniza, canoso (0, 1, 3, 4, 8, 9) | marrones, ámbar, verdes, grises (0, 2, 3, 5) | no (pelo recogido) | sí |

**Formato de las secciones** (claves ordenadas, como todo el archivo):

- `races`: `[{id, realm, allows_no_hair, allows_no_beard, bodies, heads, hairs, beards, marks, skin_tones,
  hair_colors, eye_colors}]` en el orden del catálogo (la posición es el byte 0 − 1), con el reino en el código de
  `NetProtocol.Realm` y las listas como índices desde 0 (también pelo y barba).
- `appearance`: `{body_count, heads, hairs, beards, marks, skin_tone_count, hair_color_count, eye_color_count}`, con
  cada lista de piezas como `[{id, bodies}]`.
- `level_curve`: `{level_cap, xp_to_next, attribute_points_per_level}`.
- `currencies`: `[{code, id, cap}]` (`gold` y `merits`, tope 10^9).
- `reasons`: `{ranges: {source, sink, internal}, codes, op_kinds}`, cada rango `{min, max}` y los motivos y tipos de
  operación por nombre en minúsculas (`starter_kit`: 1…).
- `containers`: `{bag: {code, default_slots, max_slots}, equipment: {code, slots, open_slots}, open: [0, 1]}`.
- `combat`: `{health_max}`.

**Desviaciones y decisiones de la implementación:**

- **Sin `items` ni `starter_templates`.** §14.1 dice que P3 no depende de nada, pero §13.4 y §15 ponen en su
  exportación los objetos (de `ItemDatabase`, P1, que va en paralelo) y las plantillas `selectable` (de
  `EquipmentTemplate`, habilidades.md H1a, que aún no está en esta rama: `wip/fase5-go` sale de `b4affb7`, antes
  de habilidades). Entran con esos paquetes, cada una con su función en `build()` y sus comprobaciones en
  `test_progression_rules_export`; `LoadRules` las ignora hasta que P7 las lea. Mientras, `*progress.Rules` no
  implementa `CreateValidator` y `serve` sigue con la validación provisional de plataforma.md P2.
- **Monedas, motivos, contenedores y tipos de operación son constantes de `ProgressionRulesExport`**
  (`CURRENCIES`, `REASON_RANGES`, `REASON_CODES`, `OP_KINDS`, `CONTAINERS`): sus clases (`Currency`,
  `EconomyReason` e `InventoryState` de P2; `EconomyOp.Kind` de P5a, en `scripts/server/`, que lo compartido no
  puede leer) aún no existen. En `reasons` están todos los motivos de §5.3, también los de fases siguientes, porque
  sus números ya son fijos.
- **Los casos compartidos llevan una quinta clave, `case`** (la regla que prueban), además de `{realm, race_id,
  appearance, valid}`: con 40 casos en base64, sin ella un fallo no se entiende. Las dos pruebas exigen las cinco.
  Lo que no son 8 B no vale, en los dos lados.
- **La regla de los cuerpos no tiene caso compartido:** con un solo cuerpo en el repositorio no se puede escribir
  «una pieza de otro cuerpo» con los datos de verdad. Las dos pruebas la comprueban con el mismo catálogo de dos
  cuerpos hecho en la prueba (`_two_body_catalog` en GDScript, `twoBodyRules` en Go).
- **Ir sin marcas vale siempre** (no hay `allows_no_marks`). La piel, el color de pelo (también el de las cejas)
  y el de ojos se piden siempre, haya o no pelo y barba.
- **`default_for`** toma lo primero que permite cada lista, con pelo y barba si hay alguno compatible y sin marcas;
  **`random`** es uniforme en cada campo entre lo compatible con el cuerpo elegido, con «sin» entre las opciones
  cuando se admite. Las dos devuelven null con un índice de raza que no existe.
- **`add_xp`** con 0 o menos no aplica nada; un total por encima del tope se lleva al tope (I8).
  **`attribute_points`** nunca baja de 0 (tras una reversión que quita niveles).
- **`shared()`** (curva y catálogo) carga una vez y, si el recurso no está, registra el error y devuelve uno vacío
  (todos a nivel 1; ninguna apariencia vale). El catálogo registra también sus `get_errors`.
- **Los ejemplos de §3.4 y §9.3 no cumplían I8** (nivel 7 con 12345 de XP, que con esta curva es nivel 8) **y su
  apariencia no valía** (marcas 2, y no hay marcas): pasan a nivel 8 y a `AQAAAQEDAgE=`, que está en los casos
  compartidos.
- **`test_architecture`** gana tres pruebas: la progresión compartida no nombra `Time`, `OS` ni `Input` y
  `scripts/server/progress/` no nombra `Time` (la carpeta aún no existe: la regla ya está para P5a); ningún `.tres`
  de `data/characters/`, `data/items/` ni `data/progression/` enlaza o tiene, declarada o con valor, una textura,
  una escena o una malla, tampoco en sus subrecursos; y ningún `class_name` se repite en `scripts/`, `tests/`,
  `tools/` ni `addons/` (§14.2 decía `scripts/` y `tests/`, pero las herramientas y los complementos también
  registran clases).
- **`test_export_config`:** el catálogo, una raza y la curva están entre lo que ningún filtro puede quitar, y el
  catálogo y la curva, en el paquete del servidor.

**Para los paquetes siguientes.**

- **P1** añade `items` (`_items()` con `ItemDatabase`) y **la integración con habilidades.md** `starter_templates`
  (las `EquipmentTemplate` con `selectable`); cada una vuelve a exportar el archivo y amplía
  `test_progression_rules_export` y `LoadRules`.
- **P2** hace que `_currencies`, `_reasons` y `_containers` lean de `Currency`, `EconomyReason` e
  `InventoryState`: el archivo no debe cambiar. **P5a** comprueba que `EconomyOp.Kind` coincide con
  `ProgressionRulesExport.OP_KINDS`.
- **P4:** el SPAWN lleva `CharacterAppearance.encode()`; el cliente sustituye una que no vale por `default_for`.
- **P5a:** en `ProgressService.prepare`, `CharacterAppearance.decode` y `validate(AppearanceCatalog.shared(),
  claimed.realm, race_id)`; si no vale, `default_for(catalog, catalog.race_index(race_id))`. `ProgressRecord`
  comprueba I8 con `LevelCurve.shared().level_for`, y `PlayerProgress.add_xp` usa `ProgressionRules.add_xp`.
- **P6 y plataforma.md P8:** `random` para «Aleatorio», `display_name` de piezas, colores y pueblos para la creación;
  `AppearanceApplier` monta `scene_path` y tiñe con `color`.
- **P7:** `progress.LoadRules(gamedata.Raw())` ya lee y comprueba lo de P3. Le quedan `items` y `starter_templates`,
  `ValidateCreate` (`RaceIndex` y el reino para `{"race_id": "wrong_realm"}`, `ValidAppearance` para
  `{"appearance": "invalid"}`) y lo que leen S5 y S6 (`LevelFor`, `Combat.HealthMax`, `Containers`,
  `Currencies`, `Reasons`).

**Pruebas.** En Godot: `test_level_curve` (9: recurso en texto y sin errores, 39 valores crecientes, la tabla de
§6.1 y su fórmula, `level_for(total_to(n)) = n` y un punto antes, varias subidas con un solo aporte, el tope, aportes
de 0 o negativos, puntos de atributo y una curva rota); `test_character_appearance` (13: ida y vuelta de 200 × 8 B
al azar y de una conocida campo a campo, otros tamaños, los 40 casos compartidos, cada campo fuera de rango, raza y
reino, ir sin pelo o barba, la pieza de otro cuerpo, 100 aleatorias válidas por raza y `default_for`, una raza por
reino en su archivo, sin estadísticas, `appearance_ids.txt` como prefijo, escenas que existen y errores del
catálogo); `test_progression_rules_export` (las 5 de plataforma.md P2 y 5 nuevas, una por sección o grupo);
`test_architecture` (3 nuevas, arriba) y `test_export_config` (los datos nuevos). En Go, `internal/progress` (5):
los casos compartidos, la pieza de otro cuerpo, las reglas incrustadas (razas, curva, monedas, motivos,
contenedores, vida), cada byte fuera de rango y 28 archivos rotos que `LoadRules` rechaza.

**Medido** (esta máquina, 4 núcleos, Godot 4.7.2 headless, Go 1.24.7):

| Qué | Resultado |
|---|---|
| Las 30 pruebas nuevas de Godot | La más lenta, 8 ms (`test_100_random_valid_per_race`); cada archivo, unos 7 s con el arranque del ejecutor |
| `test_architecture` | 12 s (las tres nuevas, 0,8 s: casi todo es `test_class_names_are_unique`) |
| Suite entera de Godot | 1954 pruebas (1924 antes), todas correctas, en 1042 s |
| `go test ./internal/progress` | 0,01 s (5 pruebas); `go test -p 2 -count=1 ./...` entero, 32 s |
| `progression_rules.json` | 4286 B (877 con solo las secciones de plataforma.md) |

`--import` da el mismo registro que antes (las fugas al salir de siempre) y la herramienta con `-- --check` sale
con 0.

**Sin comprobar:** las piezas y los colores sobre `HumanoidVisual` (`AppearanceApplier`, P6) y el visto bueno visual
de los colores de cada pueblo (§16); la regla de los cuerpos con datos de verdad (llega con el cuerpo femenino de
ART-20).

**Queda para después:** `items` (P1) y `starter_templates` (integración con habilidades.md) en las reglas
exportadas; `ValidateCreate` y el resto del almacén en Go (P7); el uso de todo esto en la zona (P4, P5a, P5c) y en el
cliente (P6, plataforma.md P8).

### 19.5 Lo que cambia la revisión de la implementación de plataforma.md

La revisión de plataforma.md (su §19.7) toca tres cosas que ve P7:

- **La regla de errores del guardado** (§13.1, «Respuestas del guardado», cambiada igual en los dos documentos):
  un SQLSTATE de clase 22 es, como uno de clase 23, 400 `invalid_save` con `check = "S8"` (`db.Deterministic`).
  Un `progress` con `\u0000` en una cadena que `Apply` guarde en `jsonb`, o un número que no quepa en su columna,
  ya no deja al personaje sin guardar para siempre. Aun así, S1–S7 deberían rechazar antes lo que no cabe, con su
  propio `check`.
- **`characters.last_entered_at`** ya no lo escribe la reclamación sino el primer guardado aplicado de cada
  arrendamiento (con la hora de la reclamación); lo hace `persistence.Store` después de `Apply`, en la misma
  transacción. P7 no tiene que hacer nada.
- **`pvp`**: el sobre rechaza (`envelope`) los totales `int` de más de 2^31 − 1.

### 19.6 P1 · objetos (PRG-02)

**Qué hay.** Lo de §14.1 P1, en `scripts/shared/progression/` salvo donde se dice:

| Pieza | Contenido |
|---|---|
| `ItemDefinition` | Los campos de §2.1 con sus enumerados (`Category`, `EquipSlot`, `BindRule`), `ID_PATTERN`, `MAX_STACK` e `is_equipable()`. Icono y escenas como rutas (`String`), nunca como recursos |
| `ItemInstance` | Los campos de §2.1 y las constantes de §14.2; `encode`, `decode` y `encoded_size_at` (§2.3, little endian como el resto del protocolo), `to_dictionary`/`from_dictionary` (§3.4), `duplicate_instance`, `equals`; además `create(uid, definición, cantidad)` (durabilidad llena y ligada si la regla es `ON_PICKUP`), `is_valid(db)` (la regla de `decode` sobre una instancia en memoria) y `encoded_size()` |
| `ItemDatabase` | `shared()`, `build_from_directory` (con subcarpetas y `.tres.remap`), `build_from_definitions(definiciones, combat)` (la que usan las pruebas y los casos), `get_definition`, `net_id_of`, `definition_by_net_id`, `for_ref`, `consumable_definition`, `all_ids`, `wire_hash` y `errors` |
| `ProgressJson` | La lectura estricta del JSON del progreso, igual que `jsonx` en Go: `is_id` (cadena decimal canónica, ≤ 2^53 − 1), `id_value`, `id_text`, `is_int` (número exacto, admite `820.0`) e `is_bool`. La usarán también `ProgressRecord`, `EconomyOp` y `LedgerEntry` (P5a) |
| `data/items/` | `weapon/sword_shield_vado.tres`, `weapon/bow_vado.tres`, `consumable/potion_health.tres` y `consumable/potion_stamina.tres` (§2.4) |
| `tests/fixtures/items/` | `armor/` (tres armaduras que valen: yelmo y botas con durabilidad, peto sin ella) y `broken/` (tres que no: en la ranura de arma, sin ranura y apilable) |
| `ProgressionRulesExport` | Las secciones `items` y `starter_templates`; el archivo exportado de nuevo |
| `platform/internal/progress/rules.go` | `LoadRules` lee las dos secciones, estrictas como las demás, con las comprobaciones de `ItemDatabase` que tienen sentido sin el catálogo de combate; `Item(id)`, `SelectableTemplate(id)` y las constantes `Category*`, `Slot*` y `MaxStack` |

**Formato de las secciones** (claves ordenadas):

- `items`: `[{id, category, equip_slot, max_stack, has_durability, required_level}]` en orden de net id
  (alfabético), con la categoría y la ranura en los números de §2.1. Go exige ese orden.
- `starter_templates`: `[{id, weapons}]`, las `EquipmentTemplate` con `selectable = true` en el orden de su id
  (hoy `marksman` y `squire`) y, en `weapons`, los **ids de objeto** de sus armas en orden de ranura
  (`["bow_vado", "sword_shield_vado"]` y `["sword_shield_vado"]`): el kit de la regla 1 de §2.5. Un arma sin
  objeto saldría como `""` y `LoadRules` rechaza el archivo.

**Desviaciones y decisiones de la implementación:**

- **`starter_templates` entra aquí.** §19.4 la dejaba para «la integración con habilidades.md», que no es un
  paquete de §14.1; habilidades.md ya está en `main`, sus armas son objetos de esta base y P7 la necesita para
  `ValidateCreate`. `*progress.Rules` sigue sin implementar `CreateValidator` (es de P7): ya tiene
  `RaceIndex`, `ValidAppearance` y `SelectableTemplate`.
- **Ids más estrictos que «`is_valid_int()` y `to_int()`»** (§14.2): `ProgressJson.is_id` pide la forma de
  `jsonx.ParseID` (solo dígitos, sin signo ni ceros a la izquierda) y como mucho 16 cifras antes de llamar a
  `to_int()`, que con 20 cifras registra un error del motor. `"+5"`, `"007"`, `" 5"` y `"5.0"` no valen en ninguno
  de los dos lados.
- **`from_dictionary` pide las diez claves de la entrada de §3.4**, también `container` y `slot` (enteros
  exactos de 0 a 65 535): su rango depende del contenedor y de `bag_slots`, y lo mira `ProgressRecord` (P5a).
  No exige las reglas de la fase 5 (rareza 0, sin afijos): el modelo es el general y esas las mira S5.
- **`encode` de una instancia que no vale** (`is_valid` falso: definición desconocida, cantidad, durabilidad,
  rareza, semilla o afijos fuera de rango) devuelve un array vacío sin registrar nada; quien construye el
  mensaje (P4) lo trata como un fallo suyo. **`encoded_size_at`** da −1 también con otro formato o más de 6
  afijos: así recorrer una lista nunca se salta mal una entrada.
- **Reglas de coherencia además de las de §2.1:** `camp_refill` cabe en una pila (la regla 3 del kit la pone
  en una); icono vacío o bajo `res://assets/icons/items/`; escenas solo en las armaduras y bajo `res://assets/`;
  las categorías que no son arma, armadura ni consumible van sin ranura ni `ref_id`; y **dos objetos para la
  misma arma o el mismo consumible son un error** («en la fase 5 hay uno por `ref_id`», §2.2): el kit y
  CAMP_REFILL dependen de que `for_ref` no dude. Si la fase 6 trae variantes de un arma, la regla cambia con
  ellas. `required_level` se comprueba contra `LevelCurve.shared().level_cap`.
- **Un id repetido** se avisa y se queda el que llega antes (`build_from_directory` llega en orden de ruta):
  `sort_custom` no es estable, así que el orden desempata por la posición.
- **`wire_hash`** es el SHA-256 de `var_to_bytes` de la lista `[id, net_id, category, equip_slot, max_stack,
  has_durability]` por objeto, sin versión. Aún no entra en `NetProtocol.compute_sim_hash`: lo hace P4 con el
  resto de la versión 7.
- **Carpetas en inglés** (`weapon/`, `consumable/`: el nombre del enumerado en minúsculas) y archivos con el
  nombre del id; la prueba lo exige para `data/items/`. Las pociones son destruibles (§2.4 solo fija las armas).

**Para los paquetes siguientes.**

- **P2:** `StarterKit` con `for_ref(WEAPON, arma)` y las definiciones con `starter` y `camp_refill` de
  `all_ids()`; `ItemInstance.create` da la instancia del kit (ligada, porque los objetos de inicio son
  `ON_PICKUP`); el ligado al equipar es de `InventoryOps`.
- **P4:** `ItemDatabase.wire_hash()` en `compute_sim_hash`; INVENTORY_DELTA e INVENTORY_FULL con `encode` y
  `encoded_size_at`/`decode` (un `encode` vacío es un error del servidor).
- **P5a:** `ProgressRecord.from_dictionary` lee `container` y `slot` y llama a `ItemInstance.from_dictionary`;
  los demás ids del registro, con `ProgressJson`.
- **P7:** `ValidateCreate` con `SelectableTemplate` para `{"starter_template_id": "not_selectable"}`; S5 con
  `Item(def_id)` (definición en las reglas, pila, durabilidad, armas en el equipo).

**Pruebas.** En Godot: `test_item_database` (10: los datos sin errores y en orden, ids únicos con formato y en
texto en `data/items/` y en los casos, el contenido de §2.4, `ref_id` que existen, un objeto por arma de cada
plantilla y por consumible, net ids alfabéticos también con las armaduras intercaladas, la huella estable que
cambia con lo que la forma y no con lo demás, la regla de ARMOR con los casos, cada regla de coherencia una a una
y una carpeta con lo que no es un objeto); `test_item_instance` (8: ida y vuelta de 1000 instancias con semilla,
con y sin durabilidad y afijos, en binario, recorridas en un búfer con `encoded_size_at` y por el texto JSON;
una codificación conocida byte a byte; null en cada caso de §2.3 y en cada truncado; `encode` vacío de lo que no
vale; la entrada de §3.4 tal cual; `from_dictionary` con 38 entradas rotas, cada clave que falta, una de más y
los enteros como `820.0`; `create`, `duplicate_instance` y `equals`; la base compartida por defecto);
`test_progression_rules_export` (2 nuevas: `items` y `starter_templates`, y las secciones exactas);
`test_export_config` (dos objetos entre lo que ningún filtro puede quitar y en el paquete del servidor). En Go,
`internal/progress`: `TestEmbeddedItemsAndTemplates` y 25 archivos rotos más en
`TestLoadRulesRejectsBrokenFiles`. Las pruebas de ida y vuelta, la de ARMOR y la de los ids se comprobaron con la
mutación que deberían pillar (sin la comprobación de los flags, de la ranura de la armadura o de los ceros a la
izquierda, fallan).

**Medido** (esta máquina, 4 núcleos, Godot 4.7.2 headless, Go 1.24.7):

| Qué | Resultado |
|---|---|
| `test_item_database` | 10 pruebas; la más lenta, 18 ms (la primera carga de `data/items` con el catálogo de combate); el archivo, unos 10 s con el arranque del ejecutor |
| `test_item_instance` | 8 pruebas; la de 1000 instancias, 131 ms (codificar, decodificar y pasar por el JSON cada una); el archivo, unos 12 s |
| `test_architecture`, `test_export_config` | 19 y 10 pruebas, correctas (18 y 27 s) |
| `go test -race ./internal/progress` | 1,2 s; `go test -race -count=1 ./...` entero, correcto |
| `progression_rules.json` | 5066 B (4286 antes) |

**Sin comprobar:** `ItemDatabase` en un proyecto exportado de verdad (los `.tres.remap` de las subcarpetas): la
prueba del paquete del servidor comprueba que los objetos van dentro, no que se cargan desde él.

**Queda para después:** `ItemDatabase` en el `sim_hash` y los mensajes de inventario (P4); el inventario, el kit
y las monedas (P2); el registro (P5a); `ValidateCreate` y S5 en Go (P7); los iconos (ART-12, §16).
