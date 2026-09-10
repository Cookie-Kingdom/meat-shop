-- Cards ^ref-35 / ^ref-36 — three transport_lines columns F8 needs (PLAN-movement.md T1,
-- Finding 5). One migration for the range, taken by ^ref-35 because its receipt reads the
-- bag-count pair; fifo_override_reason is ^ref-36's and lands here so the numbering the sales
-- plan builds on (...0017, ...0018) does not move a second time.
--
-- FIFO_OVERRIDE_REASON IS NOT VARIANCE_REASON. The sender writes it at allocation; the receiver
-- writes variance_reason days later and fn_confirm_transport_receipt overwrites that column
-- unconditionally, so a FIFO reason parked there is deleted by an ordinary branch receipt
-- (Seam 4, TC-31).
--
-- THE BAG COUNT IS A SECOND MEASURED DIMENSION, NOT THE STOCK FIGURE. v0.2:108 (OW 07) loads
-- "น้ำหนัก และจำนวนถุง", v0.2:89 (BR 02) receives "น้ำหนักจริง จำนวนถุง และเหตุผลเมื่อไม่ตรง".
-- The branch thaws by weight without needing a whole bag (v0.2:199), so stock_ledger stays in
-- kg. Null on either side means NOT COUNTED, never zero bags: no FOODIVA_TO_CM or CM_TO_FOODIVA
-- line carries a count.

alter table transport_lines add column fifo_override_reason text;
alter table transport_lines add column bag_count          integer check (bag_count > 0);
alter table transport_lines add column received_bag_count integer check (received_bag_count > 0);

comment on column transport_lines.fifo_override_reason is
  'BR07 - why the oldest smoke-date group was skipped at allocation. Written by the '
  'SENDER at dispatch. Never variance_reason, which the RECEIVER overwrites (Finding 5).';
comment on column transport_lines.bag_count is
  'v0.2:108 (OW 07) - bags loaded. A whole bag ships to one branch and is never cut, so '
  'the count is a SECOND MEASURED DIMENSION of this movement, not a derivative of the '
  'weight. It is NOT the stock figure: the branch thaws by weight without needing a whole '
  'bag (v0.2:199), so dispatched_weight_kg stays the one stock figure. Not derivable from '
  'lot_bags - that counts what was PACKED, never what was LOADED, and bags carry no code '
  '(BR18). Required by fn_allocate_to_branch even though the column is nullable.';
comment on column transport_lines.received_bag_count is
  'v0.2:89 (BR 02) - bags the receiver actually counted, against bag_count. Null until the '
  'receiving side confirms, exactly like received_weight_kg. A mismatch demands a reason '
  'in fn_confirm_transport_receipt, not in the screen.';
