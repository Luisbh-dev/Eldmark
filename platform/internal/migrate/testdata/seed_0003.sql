-- Semilla de conservación del esquema 0003: una instancia viva con su billete, su arrendamiento y
-- un bloque de ids.
insert into zone_instances (zone_instance_id, world_id, zone_id, channel, public_host, public_port, realms, build_id,
  protocol_version, record_format, max_players, status, live_at)
values ('00000000-0000-4000-8000-000000000001', 1, 'vado_gris', 0, '127.0.0.1', 24600, '{1,2}', 'semilla', 7, 1, 64, 'live', now());
insert into enter_tickets (ticket_id, world_id, character_id, session_id, zone_instance_id, issued_at, expires_at)
select 72623859790382856, 1, c.character_id, s.session_id, '00000000-0000-4000-8000-000000000001', now(), now() + interval '10 s'
from characters c join sessions s using (account_id) where c.name_key = 'aneira';
insert into character_leases (character_id, world_id, lease_id, zone_instance_id, claimed_by, session_id, expires_at)
select c.character_id, 1, '00000000-0000-4000-8000-0000000000aa', '00000000-0000-4000-8000-000000000001',
  '00000000-0000-4000-8000-000000000001', s.session_id, now() + interval '30 s'
from characters c join sessions s using (account_id) where c.name_key = 'aneira';
insert into id_blocks (first_id, zone_instance_id) values (nextval('uid_block_seq'), '00000000-0000-4000-8000-000000000001');
