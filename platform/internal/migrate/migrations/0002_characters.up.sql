-- Identidad de los personajes, reino de la cuenta, nombres y estadísticas PvP (plataforma.md §3,
-- §4.4 y §8). El progreso no está aquí: es de progresion.md (0010_progress).

create table account_realms (
  account_id bigint not null references accounts on delete cascade,
  world_id smallint not null references worlds,
  realm smallint not null check (realm between 1 and 3),
  unlock_at timestamptz,
  primary key (account_id, world_id)
);

create table characters (
  character_id bigint generated always as identity primary key,
  world_id smallint not null references worlds,
  account_id bigint not null references accounts,
  name text,                            -- null solo en la lápida (§11.2)
  name_key text,
  realm smallint not null check (realm between 1 and 3),
  must_rename boolean not null default false,
  created_at timestamptz not null default now(),
  last_entered_at timestamptz,
  deleted_at timestamptz,
  restore_until timestamptz,
  purged_at timestamptz,
  check ((purged_at is null) = (name is not null and name_key is not null))
);
create index on characters (account_id, world_id) where purged_at is null;

create table character_names (
  world_id smallint not null references worlds,
  name_key text not null,
  character_id bigint references characters on delete set null,
  status text not null check (status in ('active', 'reserved')),
  reserved_until timestamptz,
  primary key (world_id, name_key)
);

create table name_blacklist (
  name_key text primary key,
  reason text not null,
  added_by bigint references accounts on delete set null,
  added_at timestamptz not null default now()
);

create table character_pvp_stats (
  character_id bigint primary key references characters on delete cascade,
  world_id smallint not null references worlds,
  kills int not null default 0,
  deaths int not null default 0,
  assists int not null default 0,
  captures int not null default 0,
  gate_damage bigint not null default 0,
  defend_s int not null default 0,
  updated_at timestamptz not null default now()
);
