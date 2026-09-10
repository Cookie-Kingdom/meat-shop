-- Card ^ref-29 — the close's retry key (PLAN-lots.md, the ^ref-29 corrections).
--
-- A lots row is written by several callers over its life, and the close is the one that has
-- to tell a replay from a second attempt. Without a stored key the two are the same state —
-- LOT_CLOSED, with a different caller asking — and the only tell left would be the ledger:
-- fn_post_ledger's derived keys do stop a double post, but a lot with no raw balance and no
-- bags posts nothing for a replay to find. So the lot carries the key, the shape ...0010 gave
-- transport_lines.receipt_idempotency_key for the same reason: a second key on a row a
-- second caller writes.
--
-- Nullable, because every lot that is not closed has none. fn_close_lot rejects a null key by
-- name before it writes anything, the precedent ...0008, ...0010 and ...0013 set.

alter table lots add column close_idempotency_key uuid;

create unique index lots_close_idempotency_key on lots (close_idempotency_key);

comment on column lots.close_idempotency_key is
  'The key fn_close_lot closed this lot under (R4). The same key again is a replay and '
  'returns the original response; a different key on a closed lot is LOT_ALREADY_CLOSED. '
  'Null until close.';

-- lots.loss_weight_kg — the lost weight, STORED rather than only derived (requested 10 Sep
-- 2026; PLAN-lots.md, the ^ref-29 corrections). The numerator of v0.2's Loss (line 168,
-- BR03): foodiva_sent_weight_kg minus the lot's packed output, written once by fn_close_lot
-- inside the close. Dispatch 100, output 75 stores 25.00 (UAT-02).
--
-- One number, not two: the close's alert computes its percentage from this figure, and
-- v_lot_yield (^ref-31) reads the column instead of re-deriving it, so no two screens can
-- disagree (v0.2 line 299). It is yield-bearing — beside the dispatch weight CM 01 already
-- shows an L3, it IS the loss percentage — so it never enters the close response (UAT-15),
-- and lots stays deny-all to every session. It is not ADR-025's PRODUCTION net, which sits on
-- the chef-house balance. Null until close, and for ever on an opening lot, which never
-- passes fn_close_lot. No check: output above dispatch is a typo worth seeing as a negative,
-- not a constraint name.
alter table lots add column loss_weight_kg numeric(12,2);

comment on column lots.loss_weight_kg is
  'foodiva_sent_weight_kg minus the packed output, stored by fn_close_lot at close — the '
  'numerator of Loss (BR03, v0.2 line 168). Read by v_lot_yield; never in the close response '
  '(UAT-15). Not the PRODUCTION ledger net (ADR-025). Null until close and on opening lots.';
