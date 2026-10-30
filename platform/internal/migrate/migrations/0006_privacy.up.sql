-- Registro de purgas y correos sancionados (plataforma.md §3 y §11.2). Sin datos personales.

create table purge_log (
  kind text not null check (kind in ('account', 'character')),
  id bigint not null,
  purged_at timestamptz not null default now(),
  primary key (kind, id)
);

create table sanctioned_email_hashes (
  hmac bytea primary key,               -- HMAC-SHA256 del correo normalizado (§11.2)
  until timestamptz not null
);
