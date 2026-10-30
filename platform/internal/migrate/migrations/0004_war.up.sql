-- Guerra persistente: registro de las fortalezas, su historial y los recursos de reino
-- (plataforma.md §3 y §8).

create table fortresses (
  world_id smallint not null references worlds,
  fortress_id text not null,
  zone_id text not null,
  record jsonb not null,
  version bigint not null default 0,
  updated_at timestamptz not null default now(),
  updated_by uuid references zone_instances on delete set null,
  primary key (world_id, fortress_id)
);

create table fortress_events (
  id bigint generated always as identity primary key,
  world_id smallint not null references worlds,
  fortress_id text not null,
  event smallint not null check (event between 1 and 7),
  realm smallint not null check (realm between 0 and 3),
  at timestamptz not null,
  zone_instance_id uuid references zone_instances on delete set null,
  event_key text not null unique
);

create table realm_resources (                            -- fase 7
  world_id smallint not null references worlds,
  realm smallint not null check (realm between 1 and 3),
  resource text not null,
  amount bigint not null default 0 check (amount >= 0),
  primary key (world_id, realm, resource)
);
