-- Retention seed for schema 0010 (docs/progression.md §3.3): the progress of Aneira with a live item
-- and a retired one, a balance and a timer; a GM and its REVERSAL with participants, entries, an event
-- and the reversal, and a retained tombstone operation (its ledger lasts a year after the purge).
insert into character_progress (character_id, race_id, appearance, starter_template_id, starter_granted, level,
  xp_total, realm_points, played_seconds, health, last_zone_id, last_channel, pos_x, pos_y, pos_z, yaw, saved_at,
  save_version)
select character_id, 'race_vardheim', '\x0100000101030201', 'squire', true, 1, 300, 30, 120, 820, 'vado_gris', 0,
  12.5, 0, -40.25, 1.5, now(), 2
from characters where name_key = 'aneira';
insert into character_wallets (character_id, currency, balance, last_seq)
select character_id, 1, 0, 2 from characters where name_key = 'aneira';
insert into item_instances (uid, character_id, container, slot, def_id, count, bound, created_op)
select 1025, character_id, 1, 0, 'sword_shield_vado', 1, true, null from characters where name_key = 'aneira';
insert into item_instances (uid, character_id, def_id, count, bound, retired_at)
select 1031, character_id, 'potion_health', 1, true, now() from characters where name_key = 'aneira';
insert into character_timers (character_id, key, ends_at)
select character_id, 'unstuck', now() + interval '5 min' from characters where name_key = 'aneira';
insert into economy_ops (op_id, kind, actor_account_id, zone_id, note, detail)
select 1032, 4, account_id, 'vado_gris', 'devolución del fallo 12', '{"command": "currency_add", "source": "gm"}'
from accounts where email = 'semilla@eldmark.test';
insert into economy_ops (op_id, kind, actor_account_id, ref_op_id, zone_id, note, detail)
select 1033, 5, account_id, 1032, 'vado_gris', 'devolución mal dada', '{"command": "op_revert", "source": "gm"}'
from accounts where email = 'semilla@eldmark.test';
insert into economy_ops (op_id, kind, zone_id) values (1030, 1, 'vado_gris');
insert into op_participants (op_id, character_id)
select op_id, character_id from characters, (values (1032), (1033)) as o(op_id) where name_key = 'aneira';
insert into op_participants (op_id, character_id) select 1030, character_id from characters where purged_at is not null;
insert into ledger_entries (character_id, currency, seq, op_id, delta, balance_after, reason)
select character_id, 1, 1, 1032, 50, 50, 7 from characters where name_key = 'aneira';
insert into ledger_entries (character_id, currency, seq, op_id, delta, balance_after, reason, ref_kind, ref_id)
select character_id, 1, 2, 1033, -50, 0, 128, 4, 1032 from characters where name_key = 'aneira';
insert into item_events (op_id, character_id, def_id, uid, reason, count_delta)
select 1030, character_id, 'potion_stamina', 1029, 64, -1 from characters where purged_at is not null;
insert into op_reversals (op_id, reversal_op_id) values (1032, 1033);
