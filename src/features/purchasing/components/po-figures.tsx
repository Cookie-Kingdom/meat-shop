"use client";

import { useState } from "react";

import {
  MoneyField,
  PercentField,
  WeightField,
} from "@/components/shared/decimal-field";
import { divRound, fromHundredths, toHundredths } from "@/lib/format/number";

/* The figures half of `PurchaseOrderForm` (DESIGN-CONTRACTS.md), and the only client code
 * on OW 01. It exists for the contract's `computing` state: the total and the brine weight
 * update as the Owner types, before anything is saved.
 *
 * DISPLAY ONLY, AND EXACT. The preview runs in bigint hundredths (src/lib/format/number.ts),
 * never a JS float. What is kept is what v_po_register computes in SQL after the save — the
 * caption says so, so nobody mistakes the preview for the record.
 *
 * Price and total pair up at `md:` and nowhere else. Those are the only read-together pairs
 * S1 allows side by side, and the primary weight field is never in two columns.
 */

const HUNDRED = BigInt(100);
const TEN_THOUSAND = BigInt(10000);

function Computed({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex flex-col gap-1">
      <span className="text-label text-text-secondary">{label}</span>
      <output className="flex h-12 items-center justify-end rounded-md border border-dashed border-border bg-surface-sunken px-3 text-num-md text-text-primary tabular-nums">
        {value}
      </output>
    </div>
  );
}

export function PoFigures({
  defaults,
  brinePctHint,
}: {
  defaults: {
    weight: string;
    price: string;
    brinePct: string;
    brineCost: string;
  };
  brinePctHint: string;
}) {
  const [weight, setWeight] = useState(defaults.weight);
  const [price, setPrice] = useState(defaults.price);
  const [brinePct, setBrinePct] = useState(defaults.brinePct);

  const w = toHundredths(weight);
  const p = toHundredths(price);
  const b = toHundredths(brinePct);

  const total =
    w !== null && p !== null ? fromHundredths(divRound(w * p, HUNDRED)) : null;
  const brineKg =
    w !== null && b !== null
      ? fromHundredths(divRound(w * b, TEN_THOUSAND))
      : null;

  const bad = (raw: string, parsed: bigint | null) =>
    raw !== "" && parsed === null ? "ตัวเลขทศนิยมไม่เกิน 2 ตำแหน่ง" : undefined;

  return (
    <>
      <WeightField
        label="น้ำหนักที่สั่ง"
        name="ordered_weight_kg"
        required
        value={weight}
        onChange={(e) => setWeight(e.target.value)}
        error={bad(weight, w)}
        hint="น้ำหนักรวมของ PO — แต่ละรอบส่งบันทึกแยกหลังสร้าง PO"
      />

      <div className="grid gap-3 md:grid-cols-2">
        <MoneyField
          label="ราคาต่อกิโลกรัม"
          name="unit_price_thb_per_kg"
          required
          value={price}
          onChange={(e) => setPrice(e.target.value)}
          error={bad(price, p)}
        />
        <Computed
          label="ยอดรวมค่าเนื้อ (คำนวณให้)"
          value={total ? `${total} บาท` : "—"}
        />
      </div>

      <div className="grid gap-3 md:grid-cols-2">
        <PercentField
          label="น้ำดองที่ผู้ขายเสนอ"
          name="brine_pct_offered"
          value={brinePct}
          onChange={(e) => setBrinePct(e.target.value)}
          error={bad(brinePct, b)}
          hint={brinePctHint}
        />
        <Computed
          label="น้ำหนักน้ำดองที่เสนอ (คำนวณให้)"
          value={brineKg ? `${brineKg} กก.` : "—"}
        />
      </div>

      <MoneyField
        label="ต้นทุนน้ำดอง"
        name="brine_cost_thb"
        defaultValue={defaults.brineCost}
        hint="เว้นว่างถ้า PO นี้ไม่มีน้ำดอง — ไม่ใช่ 0"
      />

      <p className="text-caption text-text-muted">
        ตัวเลขที่คำนวณให้เป็นตัวอย่างก่อนบันทึก ตัวเลขที่เก็บจริงคำนวณโดยระบบหลังบันทึก
      </p>
    </>
  );
}
