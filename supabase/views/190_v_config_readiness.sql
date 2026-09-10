-- v_config_readiness — the first-run gate's one read (card ^ref-61, ADR-023, R35).
--
-- ONE ROW PER REQUIRED ITEM, AND NO VALUE. Each row names an item the Owner still has to
-- enter (or, for WARN, a capability that stays off), its severity, the feature it stops and
-- one boolean. There is no numeric, text or jsonb value column — which is the only reason all
-- three roles may read the same rows (ADR-023): an L2 or L3 learns THAT the average pack
-- weight is missing, never what any price is (R20).
--
-- ADVISORY, NOT ENFORCEMENT (R35). The refusal stays in the RPC: every BLOCK item raises
-- CONFIG_NOT_SET from the function that consumes it, through fn_config_value. Delete this view
-- and nothing unconfigured can be written; the screens just stop saying why.
--
-- THE LIST IS HAND-KEPT HERE, on purpose and with the cost ADR-023 names: a new required key
-- nobody adds below is silently ungated — which is why R35 puts the enforcement in the RPC.
-- 10 BLOCK + 8 WARN. It differs from API_DATA_MODEL.md's list in six places
-- (PLAN-config-seed.md Finding 5):
--   chilli_paste_cost_thb_per_tube  removed — v0.2 gives 15 (:335), so …0024 seeds it
--   rice_sale_price_thb_per_kg,
--   chilli_paste_sale_price_thb_per_tube
--                                   removed — lane C's built fn_record_sales prices EVERY SKU,
--                                   RICE_KG and CHILLI_TUBE included, from product_prices
--                                   (fn_record_sales.sql:228) and reads neither key. A BLOCK
--                                   row nothing consumes breaks R35, and would send the Owner
--                                   to set a number that unblocks nothing.
--   freight_alloc_method            added   — D04.1 leaves the method to the Owner, and
--                                             fn_create_transport_run already raises on it
--   product_prices                  every active product, for that same reason
--   smoke_fee_tiers                 gates v_lot_cost only — ADR-024 took pricing out of
--                                   fn_close_lot
--   product_costs                   added (WARN), lane K's request: a rice or water cost left
--                                   null makes the P&L incomplete (PLAN-reporting Finding 6).
--                                   Meat (the lot decides, R30) and chilli (the seeded config
--                                   key decides, BR13) are not asked.
--
-- "SET" MEANS "WOULD RESOLVE TODAY", or the view says set while the RPC still raises:
--   config key       a scope_location_id-null row with effective_from <= current_date. Every
--                    config key listed is global; a branch-only row does not resolve for a
--                    global lookup (R36), so it does not count.
--   smoke_fee_tiers  any band set in effect — fn_set_smoke_fee_tier validated it as a set.
--   product_prices,
--   full_stock_qty   at least one active product / packaging item AND every one resolves.
--                    Zero items is NOT "all set": vacuous truth would read an empty catalogue
--                    as configured, which is R9's null-is-not-zero failure over again. A
--                    packaging item resolves on a global row, or a row for EVERY active branch.
--   product_costs    no active non-meat, non-chilli product whose CURRENT price row lacks a
--                    cost. Vacuous truth is right here and only here: it is a completeness
--                    WARN over products that exist, and an empty catalogue is already the
--                    product_prices BLOCK row's to report.
--   opening_balance_close  the one-row switch has its row (ADR-021, R46).
-- `current_date` — the same "today" v_config_history (050) uses, so the two views cannot
-- disagree about whether a row is in force.
--
-- "SET" IS NOT "WELL-FORMED". A jsonb key such as freight_thb_by_vehicle_type counts as set
-- whatever its shape; the shape is its reader's to refuse (PLAN-config-seed.md gap 12).
--
-- WHO READS IT: every ACTIVE profile, any role — `fn_current_role() is not null` (R34). A
-- deactivated profile resolves to null and reads nothing; anon holds no grant. SECURITY
-- DEFINER (the Postgres default), not security_invoker: the base tables are deny-all, so an
-- invoker view returns nothing for everyone. Standing consequence, the same as 050/060: never
-- `force row level security` on the tables read below.
--
-- `affects_roles` is who a missing item stops. The L2/L3 notice lists only their rows; the
-- Owner sees all of them. It is not an access rule — every role reads every row.
--
-- ponytail: correlated EXISTS per row, no index. Eighteen rows over tables of tens of rows.
-- Ceiling: config_settings past ~10k rows, when 050's ceiling arrives too.
--
-- Covered by supabase/tests/config_seed_test.sql (TC-09 … TC-26).

create or replace view public.v_config_readiness as
with req (sort_order, item_key, source, severity, feature, label_th, gates_th, affects_roles) as (
  values
    -- ── BLOCK: the feature raises CONFIG_NOT_SET until the item exists ──────────────────────
    (10, 'smoke_fee_tiers', 'smoke_fee_tiers', 'BLOCK', 'F7',
     'ค่ารมควัน (บาท/กรัม)', 'คำนวณต้นทุนล็อต',
     array['L1_OWNER']::user_role[]),
    (20, 'avg_pack_weight_kg', 'config_settings', 'BLOCK', 'F10',
     'น้ำหนักเฉลี่ยต่อซอง', 'บันทึกยอดขายเนื้อ และตรวจ Diff ตอนปิดวัน',
     array['L1_OWNER', 'L2_BRANCH_ADMIN']::user_role[]),
    (30, 'product_prices', 'product_prices', 'BLOCK', 'F10',
     'ราคาขายสินค้าทุกรายการ (กล่อง 350 / เนื้อซีล 320 ตามข้อกำหนด)', 'บันทึกยอดขาย',
     array['L1_OWNER', 'L2_BRANCH_ADMIN']::user_role[]),
    (60, 'brine_cost_thb_per_kg', 'config_settings', 'BLOCK', 'F7',
     'ต้นทุนน้ำดอง', 'คำนวณต้นทุนล็อต',
     array['L1_OWNER']::user_role[]),
    (70, 'freight_thb_by_vehicle_type', 'config_settings', 'BLOCK', 'F5',
     'ค่าขนส่งตามประเภทรถ', 'ตั้งค่าเที่ยวรถ',
     array['L1_OWNER']::user_role[]),
    (80, 'freight_alloc_method', 'config_settings', 'BLOCK', 'F5',
     'วิธีเฉลี่ยค่าขนส่งหลายล็อต', 'สร้างรอบขนส่ง และจัดสรรเนื้อไปสาขา',
     array['L1_OWNER']::user_role[]),
    (90, 'full_stock_qty', 'packaging_full_stock', 'BLOCK', 'F11',
     'สต๊อกเต็มของวัสดุทุกรายการ', 'แจ้งเตือนวัสดุใกล้หมด',
     array['L1_OWNER', 'L2_BRANCH_ADMIN']::user_role[]),
    (100, 'receipt_variance_settlement_method', 'config_settings', 'BLOCK', 'F8',
     'วิธีปิดส่วนต่างที่ขาด', 'ปิดส่วนต่างตอนรับเข้าคลังกลาง',
     array['L1_OWNER']::user_role[]),
    (110, 'opening_cutoff_date', 'config_settings', 'BLOCK', 'F3',
     'วันที่ยอดยกมาเป็นจริง', 'บันทึกยอดยกมา',
     array['L1_OWNER', 'L2_BRANCH_ADMIN', 'L3_CM_OPERATOR']::user_role[]),
    (120, 'unlock_window_hours', 'config_settings', 'BLOCK', 'F1',
     'ปลดล็อกแล้วใช้ได้กี่ชั่วโมง', 'ขอเปิดแก้ข้อมูลย้อนหลัง',
     array['L1_OWNER', 'L2_BRANCH_ADMIN', 'L3_CM_OPERATOR']::user_role[]),
    -- ── WARN: it runs, a capability is missing ───────────────────────────────────────────
    (200, 'opening_balances_open', 'opening_balance_close', 'WARN', 'F3',
     'ยังไม่ได้ปิดรับยอดยกมา', 'ระหว่างนี้ย้อนหลังได้ไม่จำกัดวัน — ปิดทันทีที่กรอกยอดครบ',
     array['L1_OWNER']::user_role[]),
    (210, 'alert_recipients', 'config_settings', 'WARN', 'F14',
     'ผู้รับการแจ้งเตือนและช่องทาง', 'ส่งการแจ้งเตือน',
     array['L1_OWNER']::user_role[]),
    (220, 'alert_enabled', 'config_settings', 'WARN', 'F14',
     'เปิด/ปิดการแจ้งเตือนแต่ละประเภท', 'ส่งการแจ้งเตือน',
     array['L1_OWNER']::user_role[]),
    (230, 'central_warehouse_keeper_ids', 'config_settings', 'WARN', 'F14',
     'ผู้รับของเข้าคลังกลาง', 'ส่งการแจ้งเตือนถึงผู้ดูแลคลัง',
     array['L1_OWNER']::user_role[]),
    (240, 'vehicle_schedule', 'config_settings', 'WARN', 'F14',
     'ตารางรถเข้า', 'วางแผนวันรถเข้า',
     array['L1_OWNER']::user_role[]),
    (250, 'material_reorder_point_qty', 'config_settings', 'WARN', 'F11',
     'จุดสั่งซื้อวัสดุ', 'เตือนตามจำนวนคงเหลือ (เตือน 20% ยังทำงาน)',
     array['L1_OWNER']::user_role[]),
    (260, 'material_days_of_cover_target', 'config_settings', 'WARN', 'F11',
     'จำนวนวันที่ต้องมีของสำรอง', 'เตือนตามจำนวนวันสำรอง (เตือน 20% ยังทำงาน)',
     array['L1_OWNER']::user_role[]),
    (270, 'product_costs', 'product_prices', 'WARN', 'F13',
     'ต้นทุนสินค้าที่ไม่ใช่เนื้อและน้ำพริก (เช่น ข้าว น้ำเปล่า)', 'แสดงกำไรขาดทุนแบบครบ',
     array['L1_OWNER']::user_role[])
)
select
  r.item_key,
  r.source,
  r.label_th,
  r.severity,
  r.feature,
  r.gates_th,
  r.affects_roles,
  case
    when r.source = 'config_settings' then
      exists (
        select 1 from config_settings c
         where c.key = r.item_key
           and c.scope_location_id is null
           and c.effective_from <= current_date)

    when r.source = 'smoke_fee_tiers' then
      exists (select 1 from smoke_fee_tiers t where t.effective_from <= current_date)

    -- Before the product_prices arm: it shares the source and asks a different question.
    when r.item_key = 'product_costs' then
      not exists (
        select 1 from products p
         where p.is_active
           and p.item_type not in ('SMOKED_MEAT', 'CHILLI_PASTE')
           and not exists (
             -- the CURRENT price row carries a cost; an older row's cost is not today's
             select 1 from product_prices pp
              where pp.product_id = p.id
                and pp.cost_thb is not null
                and pp.effective_from = (
                  select max(pp2.effective_from) from product_prices pp2
                   where pp2.product_id = p.id
                     and pp2.effective_from <= current_date)))

    when r.source = 'product_prices' then
      exists (select 1 from products p where p.is_active)
      and not exists (
        select 1 from products p
         where p.is_active
           and not exists (
             select 1 from product_prices pp
              where pp.product_id = p.id
                and pp.effective_from <= current_date))

    when r.source = 'packaging_full_stock' then
      exists (select 1 from packaging_items i where i.is_active)
      and not exists (
        -- an item is unset when it has no global row AND some active branch has no row of
        -- its own — or there is no branch at all to fall back on
        select 1 from packaging_items i
         where i.is_active
           and not exists (
             select 1 from packaging_full_stock f
              where f.packaging_item_id = i.id
                and f.location_id is null
                and f.effective_from <= current_date)
           and (
             not exists (select 1 from locations l where l.kind = 'BRANCH' and l.is_active)
             or exists (
               select 1 from locations l
                where l.kind = 'BRANCH' and l.is_active
                  and not exists (
                    select 1 from packaging_full_stock f
                     where f.packaging_item_id = i.id
                       and f.location_id = l.id
                       and f.effective_from <= current_date))))

    when r.source = 'opening_balance_close' then
      exists (select 1 from opening_balance_close)
  end as is_set,
  r.sort_order
from req r
where fn_current_role() is not null;

comment on view public.v_config_readiness is
  'ADR-023 first-run gate. One row per required config item: severity (BLOCK/WARN), the '
  'feature it stops, affects_roles, and is_set — names and a boolean, never a value, so every '
  'active profile of every role reads the same rows (R34). Advisory: the RPC''s '
  'CONFIG_NOT_SET is the enforcement (R35).';

revoke all    on public.v_config_readiness from anon, authenticated;
grant  select on public.v_config_readiness to   authenticated;
