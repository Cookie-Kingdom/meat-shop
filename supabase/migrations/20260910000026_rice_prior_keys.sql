-- Fix ^fix-rice-replay-key (final test pass, 11 Sep) — rice_records remembers every key it took.
-- rice_records.idempotency_key holds only the most recent write's key (R39, ...0020), because the
-- morning (BR 03) and evening (BR 07) visits write one row under two keys. Once the evening had
-- stamped its key, a replay of the morning call missed fn_record_rice's lookup and wrote again,
-- so the morning figure moved (materials_rice_test.sql TC-22). prior_keys keeps every key the
-- row held before the current one, and fn_record_rice looks a key up in both (R4).
--
-- ponytail: an array on the row, not a key table. A day has two or three visits; a key table
-- is the upgrade if a row ever takes hundreds of writes.

alter table rice_records add column prior_keys uuid[] not null default '{}';
create index rice_records_prior_keys on rice_records using gin (prior_keys);

comment on column rice_records.prior_keys is
  'R4: every idempotency_key this row held before the current one. fn_record_rice treats a key found here as a replay and writes nothing.';
