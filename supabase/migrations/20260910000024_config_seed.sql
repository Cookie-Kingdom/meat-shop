-- Card ^ref-61 — seed the config values v0.2 already confirmed (ADR-023).
--
-- ADR-023: "Keys whose value v0.2 already confirmed ship as a seed migration dated before any
-- transaction exists, and appear in setup pre-filled for confirmation rather than as empty
-- fields. Only keys with no confirmed value are BLOCK." This file is that seed, and nothing
-- else: every value below is traced to a line of source/Requirement_Dev_รวม_v0.2.md in its
-- `note`. A key v0.2 does not give a number for is NOT here — it stays absent, raises
-- CONFIG_NOT_SET through fn_config_value (R35), and is a BLOCK row in v_config_readiness.
-- Inventing one is the failure ADR-006 and BR23 exist to prevent.
--
-- A SEED ROW HAS NO AUTHOR. `created_by` was NOT NULL (…0002), and a migration runs with no
-- session — in the Docker harness no profile exists at all when this file applies. So the
-- column goes nullable and a flag says why, held together by a biconditional in the shape of
-- `lots_round_or_opening`: a row with no person behind it must be a seed, and a seed has no
-- person behind it. fn_set_config is untouched — it resolves created_by from
-- fn_require_owner() and takes no seed flag, so no session can write a seed row.
--
-- A "system" profile was rejected: profiles.id references auth.users, so it would be a login,
-- and a login nobody owns is a credential nobody rotates.
--
-- THE DATE IS 2000-01-01. "Before any transaction" has to hold for opening rows back-dated to
-- whatever opening_cutoff_date the Owner picks, and it must not collide with a fixture: the
-- test suite sets these keys at 2026-01-01, where a different value on the same key and date
-- raises CONFIG_DUPLICATE_DATE. An Owner's own dated row supersedes the seed from its date on
-- and the seed still answers for every date before it (R12, BR23).
--
-- Deliberately NOT seeded (PLAN-config-seed.md Finding 4):
--   freight_alloc_method        D04.1 — the Owner chooses the method; no value is given.
--   box_sale_price_thb,
--   addon_sealed_meat_price_thb 350/320 are confirmed (D03.1) but sales price from
--                               product_prices, not from these keys; a seeded key nothing
--                               reads would show on OW 10 as a price that is set.
--   line_man_gp_pct,
--   corporate_tax_pct           deferred by D04 — no row on purpose.
--
-- Booleans are json (^ref-12 decision 4, read by fn_config_boolean). Percentages are stored
-- as 20.00 meaning 20%; material_alert_ratio is a ratio by name and is 0.20 (R10).

alter table public.config_settings alter column created_by drop not null;

alter table public.config_settings
  add column is_seed boolean not null default false;

alter table public.config_settings
  add constraint config_settings_author_or_seed check ((created_by is null) = is_seed);

comment on column public.config_settings.is_seed is
  'True only for the v0.2-confirmed rows migration …0024 wrote at 2000-01-01, which have no '
  'author (created_by is null). No RPC can write one (ADR-023, ^ref-61).';

insert into public.config_settings
  (key, value_numeric, value_text, value_json, effective_from, created_by, is_seed, note)
values
  ('brine_pct_of_meat',                10.00, null, null, date '2000-01-01', null, true,
   'v0.2 BR 02 (:324) — น้ำดองเท่ากับ 10% ของน้ำหนักเนื้อ'),
  ('rice_serving_weight_kg',            0.20, null, null, date '2000-01-01', null, true,
   'v0.2 BR 05 (:327, :240) — ข้าวเหนียวหนึ่งที่ 200 กรัม'),
  ('chilli_paste_tube_weight_g',       30,    null, null, date '2000-01-01', null, true,
   'v0.2 BR 13 (:335) — น้ำพริกหน่วยหลอด 30 กรัม'),
  ('chilli_paste_cost_thb_per_tube',   15.00, null, null, date '2000-01-01', null, true,
   'v0.2 BR 13 (:335, :226) — ต้นทุนเริ่มต้น 15 บาทต่อหลอด แก้ไขได้ใน Config'),
  ('receipt_variance_threshold_pct',   20.00, null, null, date '2000-01-01', null, true,
   'v0.2 BR 12 (:334) — ส่วนต่างเกิน 20% ต้อง Alert'),
  ('yield_alert_threshold_pct',        20.00, null, null, date '2000-01-01', null, true,
   'v0.2 BR 03 (:325) — Loss เกิน 20% แจ้งเตือนแต่ Flow เดินต่อ'),
  ('material_alert_ratio',              0.20, null, null, date '2000-01-01', null, true,
   'v0.2 BR 20 (:342) — เตือนเมื่อคงเหลือน้อยกว่า 20% ของสต็อกเต็ม'),
  ('unlock_max_days_back',              3,    null, null, date '2000-01-01', null, true,
   'v0.2 BR 15 (:337), D07 — ภายใน 3 วันผู้รับผิดชอบเปิดแก้ได้ (R28, inclusive)'),
  ('receipt_variance_requires_reason', null,  null, 'true'::jsonb, date '2000-01-01', null, true,
   'v0.2 BR 12 (:334) — ผู้รับต้องกรอกเหตุผลเมื่อส่วนต่างเกินเกณฑ์'),
  ('partial_receipt_allowed',          null,  null, 'true'::jsonb, date '2000-01-01', null, true,
   'v0.2 M2 (:153), UAT-07 — ระบบรองรับแบ่งส่ง/แบ่งรับ ยอดค้างรับ'),
  ('business_day_close_earliest',      null,  '21:00', null, date '2000-01-01', null, true,
   'v0.2 BR 21 (:343) — เริ่มปิดยอดได้ตั้งแต่ 21:00'),
  ('smoke_fee_tier_basis',             null,  'FOODIVA_DISPATCH', null, date '2000-01-01', null, true,
   'v0.2 (:22), BR 10 — Tier ใช้น้ำหนัก Foodiva ส่งออก'),
  ('business_day_shift_rule',          null,  'SHIFT_OPEN_TO_NEXT_SHIFT_OPEN', null, date '2000-01-01', null, true,
   'v0.2 D07 (:401) — 00:00 ถึงก่อนเริ่มกะใหม่นับเป็นวันของกะก่อนหน้า (R5 implements it)')
on conflict (key, coalesce(scope_location_id, '00000000-0000-0000-0000-000000000000'::uuid),
             effective_from) do nothing;
