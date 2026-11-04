-- Retention seed for schema 0006: purges and sanctioned emails.
insert into purge_log (kind, id) select 'character', character_id from characters where purged_at is not null;
insert into sanctioned_email_hashes (hmac, until) values ('\x07', now() + interval '90 days');
