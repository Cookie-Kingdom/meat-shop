-- Card ^ref-29, ADR-025 — the PRODUCTION movement type. ONE STATEMENT, AND NOTHING ELSE IN
-- THIS FILE, for the two reasons ...0011 gives: `alter type ... add value` cannot be rolled
-- back, and the new value cannot be used in the transaction that added it, which
-- `supabase db push` wraps each file in. migrations_apply_test.sh asserts the shape.
--
-- WHY A NEW VALUE RATHER THAN `ADJUSTMENT` WITH A REASON. PLAN-lots.md Finding 10 recommended
-- the reason string; ADR-025 closed against it, on ...0011's three arguments. A rule scoped
-- by `reason like` is string matching on free text. ADJUSTMENT already means a correction,
-- and sharing it makes "show me the corrections" a LIKE query for ever. And v_cost_breakdown
-- and v_pnl have to scope production OUT, because the loss is already inside every
-- kilogram's cost — `movement_type = 'PRODUCTION'` is a predicate they can state.
--
-- fn_close_lot (^ref-29) is the only writer: at close it takes the lot's raw tuple
-- (lot, null, FROZEN) at the chef house to zero and puts each smoke-date group's packed
-- weight onto (lot, group, FROZEN). The net of those rows is not called loss anywhere —
-- ADR-011's Loss is against the Foodiva dispatch weight and belongs to v_lot_yield.

alter type movement_type add value 'PRODUCTION';
