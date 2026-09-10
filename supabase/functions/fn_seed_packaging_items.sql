-- Card ^ref-61 — fn_seed_packaging_items. The seven BR 08 materials, entered by the Owner
-- from /owner/setup, NOT by a migration.
--
-- v0.2 names them (BR 08, :95 and :246): กล่องสกรีน, กระดาษรอง, ถุงซิปเนื้อ, ถุงซิปข้าว,
-- ถุงหิ้วกระดาษ, สติกเกอร์โลโก้ and การ์ด/สติกเกอร์วิธีอุ่น. They are reference data with no owner
-- (lane D's plan, gap 1), and v_config_readiness's full_stock_qty row cannot clear while no
-- packaging item exists — so the setup gate is the natural place to create them.
--
-- WHY A FUNCTION AND NOT …0024. Lane D found, and the coordinator confirmed on 10 Sep, that a
-- migration seeding these rows switches on lane C's MATERIAL_COUNT_INCOMPLETE close gate for
-- every test the harness runs, and breaks lane C's close happy path. A migration applies to
-- every database, including the Docker one every test runs in; an RPC runs when the Owner
-- presses the button. Same rows, applied by a person on the live project and by nobody in the
-- harness. Recorded in PLAN-config-seed.md Finding 10.
--
-- CODES AND UNIT. v0.2 gives the names and no codes; lane D's plan defines none either. The
-- codes below are identifiers (English, ADR-009), and the unit is ชิ้น for all seven — BR 21
-- counts packs, tubes and pieces as whole numbers, and v0.2 gives no per-item unit. Neither is
-- a business number; the Owner can retire an item and add another from OW 10's catalogue
-- card when that card exists.
--
-- IDEMPOTENCY RIDES THE NATURAL KEY (R38): `packaging_items.code` is UNIQUE, and
-- `on conflict (code) do nothing` makes a replay write nothing. The return value is how many
-- of the seven codes exist afterwards — 7 on the first call and on every retry — so a retry
-- looks exactly like the first call succeeding (R4). p_idempotency_key is still required, so
-- the RPC and wrapper shape stay uniform (ADR-005); it is not stored, there being no column.
--
-- A RETIRED ITEM STAYS RETIRED. `do nothing` never touches an existing row, so a code the
-- Owner deactivated is not revived and a name they changed is not overwritten.
--
-- L1 only (fn_require_owner), because the catalogue is the Owner's. The audit row is written
-- by ^ref-06's generic trigger in the same transaction (R32).
--
-- Covered by supabase/tests/config_seed_test.sql (TC-27, TC-28).

create or replace function public.fn_seed_packaging_items(p_idempotency_key uuid)
  returns integer
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_codes constant text[] := array[
    'PKG_SCREEN_BOX', 'PKG_LINER', 'PKG_ZIP_MEAT', 'PKG_ZIP_RICE',
    'PKG_PAPER_BAG', 'PKG_LOGO_STICKER', 'PKG_REHEAT_CARD'];
  v_n integer;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  perform fn_require_owner();

  insert into packaging_items (code, name_th, unit)
  values
    ('PKG_SCREEN_BOX',   'กล่องสกรีน',               'ชิ้น'),
    ('PKG_LINER',        'กระดาษรอง',               'ชิ้น'),
    ('PKG_ZIP_MEAT',     'ถุงซิปเนื้อ',               'ชิ้น'),
    ('PKG_ZIP_RICE',     'ถุงซิปข้าว',                'ชิ้น'),
    ('PKG_PAPER_BAG',    'ถุงหิ้วกระดาษ',             'ชิ้น'),
    ('PKG_LOGO_STICKER', 'สติกเกอร์โลโก้',            'ชิ้น'),
    ('PKG_REHEAT_CARD',  'การ์ด/สติกเกอร์วิธีอุ่น',   'ชิ้น')
  on conflict (code) do nothing;

  select count(*) into v_n from packaging_items where code = any(v_codes);
  return v_n;
end $$;

revoke execute on function public.fn_seed_packaging_items(uuid) from public, anon, authenticated;
grant  execute on function public.fn_seed_packaging_items(uuid) to authenticated;
