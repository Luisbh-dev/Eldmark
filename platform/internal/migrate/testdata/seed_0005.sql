-- Retention seed for schema 0005: chat, ignores, reports, sanctions and audit.
insert into chat_messages (world_id, zone_id, zone_channel, channel, sender_character_id, sender_account_id, text, sent_at, message_key)
select 1, 'vado_gris', 0, 1, c.character_id, c.account_id, 'Hola', now(), '00000000-0000-4000-8000-000000000001:2'
from characters c where c.name_key = 'aneira';
insert into ignores (account_id, ignored_account_id, ignored_name)
select a.account_id, b.account_id, 'Aneira' from accounts a, accounts b
where a.email = 'otra@eldmark.test' and b.email = 'semilla@eldmark.test';
insert into reports (world_id, reporter_account_id, target_account_id, target_name, category, context)
select 1, a.account_id, b.account_id, 'Aneira', 'language', '{"zone": "vado_gris", "tick": 1}'
from accounts a, accounts b where a.email = 'otra@eldmark.test' and b.email = 'semilla@eldmark.test';
insert into report_evidence (report_id, seq, sender_name, channel, text, sent_at) select report_id, 0, 'Aneira', 1, 'Hola', now() from reports;
insert into sanctions (account_id, world_id, kind, reason, author_account_id, ends_at)
select b.account_id, 1, 'mute', 'Lenguaje', a.account_id, now() + interval '1 h'
from accounts a, accounts b where a.email = 'semilla@eldmark.test' and b.email = 'otra@eldmark.test';
insert into sanction_reports (sanction_id, report_id) select sanction_id, report_id from sanctions, reports;
insert into audit_log (world_id, source, actor_account_id, command, target_account_id, args, event_key)
select 1, 'cli', account_id, 'set-role', account_id, '{"from": "player", "to": "admin", "os_user": "semilla"}', 'semilla:1'
from accounts where email = 'semilla@eldmark.test';
