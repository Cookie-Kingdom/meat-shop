-- v_material_alerts — BR 08's list: every packaging material at every branch, what is left, and
-- whether it is low (card ^ref-50, R9, R10, BR20, UAT-13; PLAN-materials.md T6, TDD Seam 5).
--
-- THE CARD'S ACCEPTANCE IS A NULL. "Returns null, not 0, when full_stock_qty is unset — an
-- unconfigured material must not read as out of stock." is_low is therefore three-valued, and
-- null whenever any input is missing:
--
--   full_stock_qty   no packaging_full_stock row in force  → null   (R9: absence of a row, never 0)
--   alert_ratio      no material_alert_ratio row in force  → null   (ADR-023: never a defaulted 0.20)
--   remaining_qty    the item has never been counted here  → null   (not counted is not zero left)
--
-- Otherwise is_low = remaining_qty < full_stock_qty * alert_ratio, STRICTLY. v0.2:248, BR20,
-- UAT-13: full 1,000, 199 alerts, 200 and 201 do not ("เท่ากับ 20% ไม่เตือน").
--
-- remaining_qty IS THE LATEST COUNT, NOT THE LEDGER. BR 08 has the branch enter what is left
-- (v0.2:95), and nothing posts packaging consumption to stock_ledger, so the ledger balance only
-- ever goes up. The newest physical_counts row for the item at the branch wins, whatever report
-- it came from (a recount appends, v0.2:253). And receiving new stock does not move the base
-- (BR20: "การรับของใหม่ไม่เปลี่ยนค่าฐาน"): full_stock_qty is an Owner-set target, written only by
-- fn_set_packaging_full_stock (R11), and nothing here reads an intake (TC-70).
--
-- RESOLUTION IS fn_config_value'S, AT current_date: branch scope beats recency, then the newest
-- effective_from on or before today. A global row the Owner edited last week must not silently
-- override a per-branch level somebody set on purpose. The alert is about now, so today's date
-- is the event date; a closed day's alert is not recomputed from here.
--
-- THE RATIO IS A DIRECT SUBSELECT, NOT fn_config_numeric. That function has no grant (R20:
-- config_settings holds prices), and a view checks function EXECUTE against the CALLER, so an L2
-- selecting this view would fail on it. The subselect repeats the resolution order and reads one
-- non-price key. material_alert_ratio is a RATIO (0.20, keys.ts), not a percentage, and is used
-- as written.
--
-- POPULATION: every BRANCH × every ACTIVE packaging item, so a material nobody has configured or
-- counted still appears, as a row of nulls, rather than silently missing from the list.
--
-- SCOPE is v_stock_balance's: L1 all branches, an L2 their own, L3 none (R34). SECURITY DEFINER
-- (the default); the base tables are deny-all. No price column (R20).
--
-- Covered by supabase/tests/materials_alerts_test.sql (TC-63 ... TC-73).

create or replace view public.v_material_alerts as
select l.id                                      as location_id,
       l.code                                    as location_code,
       p.id                                      as packaging_item_id,
       p.code                                    as packaging_code,
       p.name_th,
       p.unit,
       fs.full_stock_qty,
       r.alert_ratio,
       round(fs.full_stock_qty * r.alert_ratio, 2) as alert_threshold_qty,
       c.counted_qty                             as remaining_qty,
       c.event_date                              as counted_on,
       case when fs.full_stock_qty is null or r.alert_ratio is null or c.counted_qty is null
            then null
            else c.counted_qty < fs.full_stock_qty * r.alert_ratio
       end                                       as is_low
  from locations l
 cross join packaging_items p
  left join lateral (
         select f.full_stock_qty
           from packaging_full_stock f
          where f.packaging_item_id = p.id
            and (f.location_id = l.id or f.location_id is null)
            and f.effective_from <= current_date
          order by (f.location_id is not null) desc, f.effective_from desc
          limit 1) fs on true
  left join lateral (
         select cs.value_numeric as alert_ratio
           from config_settings cs
          where cs.key = 'material_alert_ratio'
            and (cs.scope_location_id = l.id or cs.scope_location_id is null)
            and cs.effective_from <= current_date
          order by (cs.scope_location_id is not null) desc, cs.effective_from desc
          limit 1) r on true
  left join lateral (
         select pc.counted_qty, pc.event_date
           from physical_counts pc
          where pc.location_id = l.id
            and pc.item_type = 'PACKAGING'
            and pc.packaging_item_id = p.id
          order by pc.event_date desc, pc.created_at desc
          limit 1) c on true
 where l.kind = 'BRANCH'
   and p.is_active
   and (fn_current_role() = 'L1_OWNER'
        or (fn_current_role() = 'L2_BRANCH_ADMIN' and l.id = any (fn_current_locations())));

comment on view public.v_material_alerts is
  'BR 08 / R10 — every BRANCH x active packaging item: latest counted remainder, the full level '
  'and ratio in force today (branch scope beats recency), and is_low = remaining < full x ratio, '
  'strictly. is_low is NULL, never false or 0, when the full level, the ratio or the count is '
  'missing (R9). L1 all, L2 own branches, L3 none (R34).';

revoke all    on public.v_material_alerts from anon, authenticated;
grant  select on public.v_material_alerts to   authenticated;
