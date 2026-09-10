-- Card ^ref-32 — the per-lot smoke-fee override (ADR-024, R41).
--
-- The configured fee is a default, not the fee. When the chef house charges a lot something
-- other than the rate — usually a discount agreed after the run — these two columns hold what
-- was actually charged and why. v_lot_cost (171) reads coalesce(override, computed) and says
-- which one it used.
--
-- NULL MEANS "CHARGE THE RATE", NOT ZERO. An ordinary lot has no number typed into it, and a
-- 0.00 override is a real free run entered deliberately — which is why the floor below is
-- `>= 0` and not `> 0`.
--
-- SET TOGETHER OR NOT AT ALL (lots_smoke_fee_override_pair). An unexplained discount is the one
-- that gets found in an audit and cannot be answered, and a reason with no amount is a note
-- about nothing. The check is the whole enforcement for any future writer; the function
-- (fn_set_smoke_fee_override) raises named errors ahead of it, because a check_violation
-- arrives as a constraint name, not as a sentence OW 04 can render in Thai.
--
-- A blank reason is not a reason (lots_smoke_fee_override_reason_not_blank). The function trims
-- before it writes; this keeps a later writer from storing '   '.
--
-- PRICE COLUMNS, SO NO SESSION READS THEM (R20, BR15). lots stays deny-all to anon and
-- authenticated (policies/lots.sql); the new columns inherit the table-level revoke and are
-- reached only through v_lot_cost, which is L1 only in its WHERE.
--
-- Not a ledger change and not a guard change: lots carries no fn_guard_lot_closed trigger, so a
-- closed lot accepts an override, as R41 and R30 require.

alter table lots add column smoke_fee_override_thb    numeric(12,2);
alter table lots add column smoke_fee_override_reason text;

alter table lots add constraint lots_smoke_fee_override_nonneg
  check (smoke_fee_override_thb >= 0);

alter table lots add constraint lots_smoke_fee_override_pair
  check ((smoke_fee_override_thb is null) = (smoke_fee_override_reason is null));

alter table lots add constraint lots_smoke_fee_override_reason_not_blank
  check (smoke_fee_override_reason is null or btrim(smoke_fee_override_reason) <> '');

comment on column lots.smoke_fee_override_thb is
  'What the chef house actually charged for this lot when it differs from the configured rate '
  '(ADR-024, R41). Null = charge the rate; 0.00 = a free run. Written only by '
  'fn_set_smoke_fee_override (L1). Read through v_lot_cost.';

comment on column lots.smoke_fee_override_reason is
  'Why the override differs from the rate. Set exactly when smoke_fee_override_thb is set '
  '(lots_smoke_fee_override_pair).';
