-- Instancias de zona, billetes, arrendamientos y bloques de ids (plataforma.md §3, §5 y §6).

create table zone_instances (
  zone_instance_id uuid primary key,
  world_id smallint not null references worlds,
  zone_id text not null,
  channel smallint not null default 0,
  public_host text not null,
  public_port int not null check (public_port between 1 and 65535),
  realms smallint[] not null,
  build_id text not null,
  protocol_version int not null,
  record_format smallint not null,
  dtls_cert_pem text,
  dtls_name text,
  max_players int not null,
  players int not null default 0,
  status text not null check (status in ('starting', 'live', 'stopped', 'lost', 'replaced')),
  started_at timestamptz not null default now(),
  live_at timestamptz,
  last_heartbeat_at timestamptz not null default now(),
  ended_at timestamptz
);
create unique index on zone_instances (world_id, zone_id, channel) where status in ('starting', 'live');

create table enter_tickets (
  ticket_id bigint primary key,         -- u64 con el bit 63 a 0
  world_id smallint not null references worlds,
  character_id bigint not null references characters on delete cascade,
  session_id bigint not null references sessions on delete cascade,
  zone_instance_id uuid not null references zone_instances on delete cascade,
  issued_at timestamptz not null,
  expires_at timestamptz not null,
  consumed_at timestamptz
);

create table character_leases (
  character_id bigint primary key references characters on delete cascade,
  world_id smallint not null references worlds,
  lease_id uuid not null,               -- solo cambia al reclamar (§5.3)
  zone_instance_id uuid references zone_instances on delete set null,  -- null: libre
  claimed_by uuid not null,             -- la instancia que reclamó; no cambia al liberar
  session_id bigint references sessions on delete set null,  -- la del billete: revocarla expulsa
  expires_at timestamptz,
  last_seq bigint not null default 0,
  last_save_hash bytea,                 -- SHA-256 del último cuerpo aplicado (§7.3)
  last_save_version bigint not null default 0,  -- el save_version que devolvió Apply (§7.3)
  claimed_at timestamptz not null default now(),
  released_at timestamptz
);
create index on character_leases (zone_instance_id) where zone_instance_id is not null;

create sequence uid_block_seq start 1 increment 1024;  -- uid y op_id (progresion.md §4.5)

create table id_blocks (
  first_id bigint primary key,          -- [first_id, first_id + 1023]
  zone_instance_id uuid not null references zone_instances on delete cascade,  -- cae con la retención de §11.1
  granted_at timestamptz not null default now()
);
