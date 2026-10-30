-- Chat, ignorados, reportes, sanciones y auditoría (plataforma.md §3 y §9).

create table chat_messages (
  id bigint generated always as identity primary key,
  world_id smallint not null references worlds,
  zone_id text not null,
  zone_channel smallint not null,       -- la copia: el channel de la instancia
  channel smallint not null,
  sender_character_id bigint not null,
  sender_account_id bigint not null,
  target_character_id bigint,
  text text not null check (length(text) <= 255),
  sent_at timestamptz not null,
  message_key text not null unique
);
create index on chat_messages (sent_at);
create index on chat_messages (sender_character_id, sent_at);

create table ignores (
  account_id bigint not null references accounts on delete cascade,
  ignored_account_id bigint not null references accounts on delete cascade,
  ignored_character_id bigint,
  ignored_name text not null,
  created_at timestamptz not null default now(),
  primary key (account_id, ignored_account_id)
);

create table reports (
  report_id bigint generated always as identity primary key,
  world_id smallint not null references worlds,
  reporter_account_id bigint references accounts on delete set null,
  reporter_character_id bigint,
  target_account_id bigint references accounts on delete set null,
  target_character_id bigint,
  target_name text not null,
  category text not null check (category in ('language', 'harassment', 'cheating', 'bot', 'offensive_name', 'other')),
  comment text not null default '' check (length(comment) <= 500),
  context jsonb not null,               -- zona, posición, tick
  status text not null default 'open' check (status in ('open', 'in_review', 'actioned', 'dismissed')),
  handled_by bigint references accounts on delete set null,
  resolution text,
  created_at timestamptz not null default now(),
  closed_at timestamptz
);
create index on reports (status, created_at);
create index on reports (reporter_account_id, created_at);

create table report_evidence (
  report_id bigint not null references reports on delete cascade,
  seq smallint not null,
  sender_name text not null,
  channel smallint not null,
  text text not null,
  sent_at timestamptz not null,
  primary key (report_id, seq)
);

create table sanctions (
  sanction_id bigint generated always as identity primary key,
  account_id bigint not null references accounts on delete cascade,
  world_id smallint references worlds,
  character_id bigint,
  kind text not null check (kind in ('warning', 'mute', 'suspension', 'ban', 'rename')),
  reason text not null,
  author_account_id bigint references accounts on delete set null,
  starts_at timestamptz not null default now(),
  ends_at timestamptz,                  -- null: permanente
  revoked_at timestamptz,
  revoked_by bigint references accounts on delete set null,
  created_at timestamptz not null default now()
);
create index on sanctions (account_id) where revoked_at is null;

create table sanction_reports (
  sanction_id bigint not null references sanctions on delete cascade,
  report_id bigint not null references reports on delete cascade,
  primary key (sanction_id, report_id)
);

create table audit_log (                                  -- sin claves ajenas
  id bigint generated always as identity primary key,
  world_id smallint,
  source text not null check (source in ('zone', 'console', 'platform', 'cli')),
  actor_account_id bigint,
  actor_character_id bigint,
  zone_id text,
  command text not null,
  target_account_id bigint,
  target_character_id bigint,
  args jsonb not null default '{}',
  at timestamptz not null default now(),
  event_key text unique
);
create index on audit_log (at);
create index on audit_log (target_character_id, at);
create index on audit_log (target_account_id, command, at);  -- S2: el set-role de §9.1
