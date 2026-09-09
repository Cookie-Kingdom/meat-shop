-- v_smoke_group_available — the FIFO picking list (D01, D05, R21, ADR-017).
--
-- Oldest smoke date first, then the lots inside that date, each as its OWN row. Two lots
-- smoked on the same day do not collapse into one line: the moment they do, a branch
-- quantity stops naming the lot it came from and the trace back to a supplier batch is
-- gone. That is the whole reason ADR-017 exists, and it is invisible until someone tries
-- to answer "which delivery was this from" six months later.
--
-- Only positive balances are offered. A group drawn to zero is not pickable, and a group
-- that has somehow gone negative is not offered as if it were stock.
--
-- Same access rule as v_stock_balance: filtered on R31's helpers, so an L3 session gets
-- zero rows (R20, PLAN D3).

create or replace view public.v_smoke_group_available as
select
  b.smoke_date_group_id,
  g.smoke_date,
  b.lot_id,
  lo.lot_code,
  b.location_id,
  b.stock_state,
  b.balance_qty      as available_qty
from v_stock_balance b
join smoke_date_groups g on g.id = b.smoke_date_group_id
join lots lo            on lo.id = b.lot_id
where b.item_type = 'SMOKED_MEAT'
  and b.balance_qty > 0
order by g.smoke_date asc, b.lot_id asc;

grant select on public.v_smoke_group_available to authenticated;
