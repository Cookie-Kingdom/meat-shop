import { kg, pct } from "../format";
import type { LotYieldRow } from "../types";
import { SummaryRow } from "./summary-row";

/* OW 04's yield block (card ^ref-33, reading v_lot_yield from ^ref-31).
 *
 * TWO FIGURES, TWO NAMES, TWO BASES (ADR-011, R16a). "Loss หลัก" divides by the Foodiva
 * dispatch weight; "Smoke Yield" divides by the pre-smoke weight. The CM received weight is
 * shown as a cross-check and is never labelled loss — three weights and one word is how three
 * different "loss" figures end up in three reports.
 *
 * The alert says the flow continued (R16b): it is information for the Owner, not a gate. */

export function YieldFigures({ row }: { row: LotYieldRow }) {
  const noPreSmoke = row.pre_smoke_weight_kg === null;

  return (
    <section className="flex flex-col gap-3 rounded-lg border border-border bg-surface p-4">
      <h2 className="text-h2 text-text-primary">Loss และ Yield</h2>

      {row.yield_alert ? (
        <p className="rounded-lg border border-danger bg-danger-subtle p-3 text-body-sm text-danger">
          Loss หลักเกินเกณฑ์ {pct(row.alert_threshold_pct)} — ระบบแจ้งเตือนแล้ว
          งานเดินต่อตามปกติ ไม่ต้องอนุมัติล็อต
        </p>
      ) : null}

      <div>
        <SummaryRow
          label="Loss หลัก (เทียบน้ำหนัก Foodiva ส่งออก)"
          value={pct(row.loss_pct)}
          emphasis
          trace={`(ส่งออก ${kg(row.foodiva_sent_weight_kg)} − ผลผลิตแพ็ค ${kg(row.output_weight_kg)}) ÷ ส่งออก × 100 · เกณฑ์แจ้งเตือน ${pct(row.alert_threshold_pct)}`}
        />
        <SummaryRow
          label="Smoke Yield (เทียบน้ำหนักก่อนรมควัน)"
          value={noPreSmoke ? "ข้อมูลไม่ครบ" : pct(row.smoke_yield_pct)}
          trace={
            noPreSmoke
              ? "ยังไม่ได้บันทึกน้ำหนักก่อนรมควัน — ระบบไม่หารด้วยศูนย์"
              : `ผลผลิตแพ็ค ${kg(row.output_weight_kg)} ÷ ก่อนรมควัน ${kg(row.pre_smoke_weight_kg)} × 100`
          }
        />
      </div>

      <h3 className="text-h3 text-text-primary">น้ำหนักที่ใช้คำนวณ</h3>
      <div>
        <SummaryRow
          label="Foodiva ส่งออก"
          value={kg(row.foodiva_sent_weight_kg)}
          trace={
            row.po_number
              ? `ใบสั่งซื้อ ${row.po_number} · ฐานของ Loss หลัก`
              : "ฐานของ Loss หลัก"
          }
        />
        <SummaryRow
          label="เชียงใหม่รับจริง"
          value={kg(row.cm_received_weight_kg)}
          trace="ใช้ตรวจสอบส่วนต่างระหว่างขนส่งเท่านั้น ไม่ใช่ฐานของ Loss"
        />
        <SummaryRow
          label="ก่อนรมควัน (หลังแกะและซับเลือด)"
          value={kg(row.pre_smoke_weight_kg)}
          trace="ฐานของ Smoke Yield"
        />
        <SummaryRow
          label="ผลผลิตแพ็ครวม"
          value={kg(row.output_weight_kg)}
          trace="น้ำหนักถุงทุกกลุ่มวันรมควัน ณ ตอนปิดล็อต"
        />
        <SummaryRow
          label="น้ำหนักที่หายไปเทียบ Foodiva ส่งออก"
          value={kg(row.loss_weight_kg)}
          trace="บันทึกครั้งเดียวตอนปิดล็อต"
        />
      </div>
    </section>
  );
}
