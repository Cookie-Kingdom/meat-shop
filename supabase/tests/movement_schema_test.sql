-- Schema-shaped cases for cards ^ref-35 / ^ref-36 — migration ...0016. Covers TC-01 and TC-02
-- of TDD-movement.md; the behaviour of the three columns is movement_test.sql's.
--
-- Each assert is a way the F8 legs silently stop being checkable:
--   * a bag count of zero is accepted, and "not counted" and "none arrived" become one value
--   * a comment goes missing, and the next agent parks the FIFO reason in variance_reason
--     (Seam 4) or derives the bag count from lot_bags (Seam 7) — the comments are the guard
--
-- Run:  psql "$DATABASE_URL" -f supabase/tests/movement_schema_test.sql

do $$
declare
  v_txt text;
  v_n   bigint;
begin
  --------------------------------------------------------------------------------- TC-01
  select string_agg(column_name || ':' || data_type, ', ' order by column_name), count(*)
    into v_txt, v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'transport_lines'
     and (column_name, data_type) in (('fifo_override_reason', 'text'),
                                      ('bag_count', 'integer'),
                                      ('received_bag_count', 'integer'));
  assert v_n = 3, format('TC-01: %s of 3 F8 columns on transport_lines (%s)', v_n, v_txt);

  select count(*) into v_n from pg_constraint
   where conrelid = 'public.transport_lines'::regclass and contype = 'c'
     and pg_get_constraintdef(oid) in ('CHECK ((bag_count > 0))', 'CHECK ((received_bag_count > 0))');
  assert v_n = 2, format('TC-01: %s of 2 bag-count columns refuse zero', v_n);

  --------------------------------------------------------------------------------- TC-02
  v_txt := col_description('public.transport_lines'::regclass,
             (select attnum from pg_attribute where attrelid = 'public.transport_lines'::regclass
                and attname = 'fifo_override_reason'));
  assert v_txt like '%variance_reason%',
    format('TC-02: fifo_override_reason''s comment does not warn off variance_reason (%s)', v_txt);

  v_txt := col_description('public.transport_lines'::regclass,
             (select attnum from pg_attribute where attrelid = 'public.transport_lines'::regclass
                and attname = 'bag_count'));
  assert v_txt like '%lot_bags%',
    format('TC-02: bag_count''s comment does not warn off lot_bags (%s)', v_txt);

  v_txt := col_description('public.transport_lines'::regclass,
             (select attnum from pg_attribute where attrelid = 'public.transport_lines'::regclass
                and attname = 'received_bag_count'));
  assert coalesce(v_txt, '') <> '', 'TC-02: received_bag_count carries no comment';

  raise exception 'MOVEMENT_SCHEMA_TEST_PASSED';
end $$;
