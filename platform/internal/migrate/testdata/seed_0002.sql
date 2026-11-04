-- Retention seed for schema 0002: characters, names and statistics.
insert into account_realms (account_id, world_id, realm) select account_id, 1, 1 from accounts where email = 'semilla@eldmark.test';
insert into characters (world_id, account_id, name, name_key, realm)
select 1, account_id, 'Aneira', 'aneira', 1 from accounts where email = 'semilla@eldmark.test';
-- A tombstone (§11.2): nameless and purged.
insert into characters (world_id, account_id, realm, deleted_at, restore_until, purged_at)
select 1, account_id, 1, now() - interval '8 days', now() - interval '1 day', now() from accounts where email = 'semilla@eldmark.test';
insert into character_names (world_id, name_key, character_id, status)
select 1, 'aneira', character_id, 'active' from characters where name_key = 'aneira';
insert into character_names (world_id, name_key, status, reserved_until) values (1, 'borrado', 'reserved', now() + interval '30 days');
insert into name_blacklist (name_key, reason) values ('eldmark', 'reservado');
insert into character_pvp_stats (character_id, world_id, kills, deaths) select character_id, 1, 3, 1 from characters where name_key = 'aneira';
