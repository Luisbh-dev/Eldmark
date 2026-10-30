-- Semilla de conservación del esquema 0001 (plataforma.md §2.4): al menos una fila en cada tabla.
-- worlds ya tiene la de «Eld» de la propia migración.
insert into accounts (email, password_hash, email_verified_at, role, age_confirmed_at)
values ('semilla@eldmark.test', '$argon2id$v=19$m=8,t=1,p=1$c2FsdA$aGFzaA', now(), 'admin', now()),
       ('otra@eldmark.test', null, null, 'player', now());
insert into sessions (account_id, access_hash, access_expires_at, refresh_hash, refresh_expires_at, ip, user_agent, client_protocol)
select account_id, '\x01', now() + interval '15 min', '\x02', now() + interval '12 h', '203.0.113.7', 'semilla', 5
from accounts where email = 'semilla@eldmark.test';
insert into account_tokens (token_hash, account_id, purpose, expires_at)
select '\x03', account_id, 'verify_email', now() + interval '24 h' from accounts where email = 'semilla@eldmark.test';
insert into auth_events (account_id, kind, ip) select account_id, 'register', '203.0.113.7' from accounts where email = 'semilla@eldmark.test';
insert into legal_documents (kind, version, sha256) values ('terms', 1, '\x04'), ('privacy', 1, '\x05'), ('rules', 1, '\x06');
insert into legal_acceptances (account_id, kind, version)
select account_id, kind, 1 from accounts, (values ('terms'), ('privacy'), ('rules')) as k(kind) where email = 'semilla@eldmark.test';
insert into consents (account_id, purpose, granted) select account_id, 'analytics', false from accounts where email = 'semilla@eldmark.test';
insert into entitlements (account_id, world_id, kind, quantity, source)
select account_id, 1, 'character_slots', 2, 'grant' from accounts where email = 'semilla@eldmark.test';
insert into outbound_mail (to_email, template, body) values ('semilla@eldmark.test', 'verify_email', 'Enlace de prueba');
