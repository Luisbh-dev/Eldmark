-- Progreso de los personajes (progresion.md §3.3, su P7): estado (progreso, saldos, objetos y
-- temporizadores), que cuelga de characters con on delete cascade y borra ProgressStore.Purge, y lo
-- de solo añadir (operaciones, participantes, libro, eventos de objeto y reversiones), que llega a
-- characters por op_participants con clave ajena sin cascada y borra la retención de un año
-- (progresion.md §3.5). Ninguna tabla lleva world_id: sale de characters.

create table character_progress (
  character_id bigint primary key references characters on delete cascade,
  race_id text not null,
  appearance bytea not null check (length(appearance) = 8),
  starter_template_id text not null,
  starter_granted boolean not null default false,
  level smallint not null default 1 check (level between 1 and 40),
  xp_total bigint not null default 0 check (xp_total >= 0),
  realm_points bigint not null default 0 check (realm_points >= 0),
  played_seconds bigint not null default 0 check (played_seconds >= 0),
  bag_slots smallint not null default 30 check (bag_slots between 1 and 120),
  health int check (health >= 0),                                               -- null: llena
  active_weapon_slot smallint not null default 0 check (active_weapon_slot between 0 and 1),
  last_zone_id text,                                                            -- null: nunca ha entrado
  last_channel smallint,
  pos_x real,
  pos_y real,
  pos_z real,
  yaw real,
  last_in_combat boolean not null default false,
  saved_at timestamptz,                                                         -- la hora de la plataforma al aplicar
  save_version bigint not null default 0                                        -- contador; no es la idempotencia
);

create table character_wallets (
  character_id bigint not null references characters on delete cascade,
  currency smallint not null check (currency > 0),                             -- 1 oro, 2 méritos
  balance bigint not null default 0 check (balance between 0 and 1000000000),
  last_seq bigint not null default 0 check (last_seq >= 0),
  primary key (character_id, currency)
);

create table item_instances (
  uid bigint primary key check (uid > 0),                                       -- nunca se reutiliza (I1)
  character_id bigint not null references characters on delete cascade,
  container smallint check (container between 0 and 3),                         -- 0 bolsa, 1 equipo, 2 banco, 3 reservado
  slot smallint check (slot between 0 and 119),
  def_id text not null,
  count int not null check (count between 1 and 999),
  durability smallint check (durability between 0 and 1000),                   -- null: sin durabilidad
  rarity smallint not null default 0 check (rarity between 0 and 4),
  bound boolean not null default false,
  seed bigint not null default 0 check (seed between 0 and 4294967295),
  affixes integer[] not null default '{}' check (cardinality(affixes) <= 6 and array_position(affixes, null) is null
    and 0 <= all (affixes) and 65535 >= all (affixes)),
  created_op bigint,                                                            -- null: nació al dividir
  retired_at timestamptz,                                                       -- retirada: destruida o juntada
  check ((retired_at is null) = (container is not null and slot is not null)),
  constraint item_instances_slot_key unique (character_id, container, slot) deferrable initially deferred
);
create index item_instances_alive_idx on item_instances (character_id) where retired_at is null;

create table character_timers (
  character_id bigint not null references characters on delete cascade,
  key text not null check (key ~ '^[a-z0-9_:]{1,48}$'),
  ends_at timestamptz not null,
  primary key (character_id, key)
);

-- Solo añadir: ni UPDATE ni DELETE salvo la retención (eldmark_append_only, abajo).

create table economy_ops (
  op_id bigint primary key check (op_id > 0),
  kind smallint not null check (kind between 1 and 15),                         -- progresion.md §5.3
  actor_account_id bigint,                                                      -- null salvo GM y REVERSAL (y desde la consola)
  ref_op_id bigint,                                                             -- la revertida (REVERSAL)
  zone_id text,                                                                 -- la de la instancia que guarda; null en una MIGRATION
  note text check (char_length(note) <= 200),
  detail jsonb not null default '{}',
  created_at timestamptz not null default now(),
  check (kind not in (4, 5) or (note is not null and btrim(note) <> ''))         -- GM y REVERSAL, con note
);

create table op_participants (
  op_id bigint not null references economy_ops,
  character_id bigint not null references characters,                          -- sin cascada: la lápida se queda
  primary key (op_id, character_id)
);
create index op_participants_character_idx on op_participants (character_id);

create table ledger_entries (
  entry_id bigint generated always as identity primary key,
  character_id bigint not null,
  currency smallint not null,
  seq bigint not null check (seq > 0),                                          -- last_seq + 1 por saldo, lo pone Apply
  op_id bigint not null,
  delta bigint not null check (delta <> 0),
  balance_after bigint not null check (balance_after between 0 and 1000000000),
  reason smallint not null,
  ref_kind smallint not null default 0 check (ref_kind between 0 and 4),
  ref_id bigint not null default 0 check (ref_id >= 0),
  created_at timestamptz not null default now(),
  unique (character_id, currency, seq),
  foreign key (op_id, character_id) references op_participants
);
create index ledger_entries_character_idx on ledger_entries (character_id, entry_id desc);

create table item_events (
  event_id bigint generated always as identity primary key,
  op_id bigint not null,
  character_id bigint not null,
  def_id text not null,
  uid bigint,                                                                   -- null: agregado (CAMP_REFILL, CONSUME)
  reason smallint not null,
  count_delta int not null check (count_delta <> 0),
  created_at timestamptz not null default now(),
  foreign key (op_id, character_id) references op_participants
);
create index item_events_character_idx on item_events (character_id, op_id);

create table op_reversals (
  op_id bigint primary key references economy_ops,                              -- una operación se revierte una vez
  reversal_op_id bigint not null unique references economy_ops
);

create function eldmark_append_only() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' and coalesce(current_setting('eldmark.retention_purge', true), '') = 'on' then
    return old;                                                                 -- solo la retención de progresion.md §3.5
  end if;
  raise exception '% es de solo añadir', tg_table_name using errcode = 'P0001';
end $$;

create trigger append_only before update or delete on economy_ops
  for each row execute function eldmark_append_only();
create trigger append_only before update or delete on op_participants
  for each row execute function eldmark_append_only();
create trigger append_only before update or delete on ledger_entries
  for each row execute function eldmark_append_only();
create trigger append_only before update or delete on item_events
  for each row execute function eldmark_append_only();
create trigger append_only before update or delete on op_reversals
  for each row execute function eldmark_append_only();

-- TRUNCATE no dispara los de fila: estos lo prohíben siempre (también con la marca).
create trigger append_only_truncate before truncate on economy_ops
  for each statement execute function eldmark_append_only();
create trigger append_only_truncate before truncate on op_participants
  for each statement execute function eldmark_append_only();
create trigger append_only_truncate before truncate on ledger_entries
  for each statement execute function eldmark_append_only();
create trigger append_only_truncate before truncate on item_events
  for each statement execute function eldmark_append_only();
create trigger append_only_truncate before truncate on op_reversals
  for each statement execute function eldmark_append_only();
