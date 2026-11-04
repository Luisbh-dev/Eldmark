-- Retention seed for schema 0004: a fortress, an event and a resource.
insert into fortresses (world_id, fortress_id, zone_id, record, version, updated_by)
values (1, 'vado_gris_fort', 'vado_gris', '{"schema": 1, "owner": 1, "phase": "consolidating"}', 1,
  '00000000-0000-4000-8000-000000000001');
insert into fortress_events (world_id, fortress_id, event, realm, at, zone_instance_id, event_key)
values (1, 'vado_gris_fort', 6, 1, now(), '00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000001:1');
insert into realm_resources (world_id, realm, resource, amount) values (1, 1, 'madera', 10);
