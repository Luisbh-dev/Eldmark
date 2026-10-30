-- Cuentas, sesiones, enlaces, accesos, textos legales, consentimientos, derechos y correo de
-- pruebas (plataforma.md §3, §4 y §11). Las tablas de la cuenta no llevan world_id.

create table worlds (
  world_id smallint primary key,
  name text not null unique,
  created_at timestamptz not null default now(),
  status text not null default 'open' check (status in ('open', 'locked', 'maintenance'))
);
insert into worlds (world_id, name) values (1, 'Eld');

create table accounts (
  account_id bigint generated always as identity primary key,
  email text unique,                    -- null: purgada
  password_hash text,                   -- null: purgada o pendiente de restablecer (§4.3)
  email_verified_at timestamptz,
  role text not null default 'player' check (role in ('player', 'moderator', 'gm', 'admin')),
  status text not null default 'active' check (status in ('active', 'pending_deletion', 'purged')),
  age_confirmed_at timestamptz not null,
  deletion_requested_at timestamptz,
  purge_after timestamptz,
  purged_at timestamptz,
  created_at timestamptz not null default now()
);

create table sessions (
  session_id bigint generated always as identity primary key,
  account_id bigint not null references accounts on delete cascade,
  access_hash bytea not null unique,
  access_expires_at timestamptz not null,
  refresh_hash bytea not null unique,
  prev_refresh_hash bytea unique,
  refresh_expires_at timestamptz not null,  -- inicio de sesión + 12 h; rotar no lo alarga
  scope text not null default 'game' check (scope in ('game', 'privacy')),  -- privacy: cuenta sancionada (§4.2)
  ip inet,
  user_agent text,
  client_protocol int,
  created_at timestamptz not null default now(),
  rotated_at timestamptz,
  revoked_at timestamptz,
  revoke_reason text check (revoke_reason in ('logout', 'replaced', 'password_changed', 'email_changed',
    'email_reverted', 'refresh_reuse', 'role_changed', 'deletion', 'admin'))
);
create index on sessions (account_id) where revoked_at is null;

create table account_tokens (
  token_hash bytea primary key,
  account_id bigint not null references accounts on delete cascade,
  purpose text not null check (purpose in ('verify_email', 'reset_password', 'change_email', 'revert_email')),
  email text,                           -- change_email: el nuevo; revert_email: el viejo
  expires_at timestamptz not null,
  used_at timestamptz,
  created_at timestamptz not null default now()
);

create table auth_events (
  id bigint generated always as identity primary key,
  account_id bigint references accounts on delete set null,
  kind text not null,                   -- §4.2
  ip inet,
  user_agent text,
  at timestamptz not null default now()
);
create index on auth_events (at);
create index on auth_events (account_id, kind, at);

create table legal_documents (
  kind text not null check (kind in ('terms', 'privacy', 'rules')),
  version int not null,
  sha256 bytea not null,
  published_at timestamptz not null default now(),
  primary key (kind, version)
);

create table legal_acceptances (
  account_id bigint not null references accounts on delete cascade,
  kind text not null,
  version int not null,
  accepted_at timestamptz not null default now(),
  primary key (account_id, kind, version),
  foreign key (kind, version) references legal_documents
);

create table consents (
  account_id bigint not null references accounts on delete cascade,
  granted boolean not null,
  updated_at timestamptz not null default now(),
  purpose text not null check (purpose in ('crash_reports', 'analytics')),
  primary key (account_id, purpose)
);

create table entitlements (                               -- PRG-41
  entitlement_id bigint generated always as identity primary key,
  account_id bigint not null references accounts on delete cascade,
  world_id smallint references worlds,  -- null: todos los mundos
  kind text not null check (kind in ('character_slots', 'expansion', 'cosmetic')),
  ref text not null default '',
  quantity int not null default 1 check (quantity > 0),
  source text not null check (source in ('grant', 'purchase', 'promo')),
  granted_at timestamptz not null default now(),
  expires_at timestamptz,
  revoked_at timestamptz
);

create table outbound_mail (                              -- solo con ELDMARK_MAIL=log
  id bigint generated always as identity primary key,
  to_email text not null,
  template text not null,
  body text not null,
  created_at timestamptz not null default now()
);
