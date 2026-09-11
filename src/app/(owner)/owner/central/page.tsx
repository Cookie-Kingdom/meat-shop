import Link from "next/link";

import { actionButton, actionLink } from "@/components/ui/controls";
import {
  ResponsiveTable,
  type Column,
} from "@/components/shared/responsive-table";
import { CentralIntakeForm } from "@/features/movement/components/central-intake-form";
import type {
  DatedValue,
  OutstandingReceiptRow,
} from "@/features/movement/types";
import { thaiDate, todayBangkok } from "@/lib/format/date";
import { kg, parseKg, toHundredths } from "@/lib/format/weight";
import { one } from "@/lib/params";
import { newFormKey } from "@/lib/rpc/movement";
import { createClient } from "@/lib/supabase/server";

/* OW 06 — สต็อกกลาง (card ^ref-37). A return leg from Chiang Mai becomes central stock only
 * when somebody signs for the weight that actually arrived (BR12). The list shows the legs
 * still on the truck, and a tap opens the S1 intake form (`?line=`).
 *
 * READS: v_outstanding_receipts narrowed to the return leg; v_config_history for the receipt
 * threshold and the reason toggle (both L1); v_central_available for the balance. WRITES:
 * fn_confirm_central_intake, through the form.
 *
 * ONLY AN UNRECEIVED LINE IS OFFERED. A partial receipt stays in v_outstanding_receipts as a
 * balance still on the truck (D06), and receiving it again is LINE_ALREADY_RECEIVED by design,
 * so it renders read-only.
 *
 * The `(owner)` group admits L1 only. A can_receive_central delegate is admitted by the
 * functions (R27) and has no screen yet. See PLAN-movement.md, Cross-lane gaps. */

const THRESHOLD = "receipt_variance_threshold_pct";
const REQUIRES = "receipt_variance_requires_reason";

type ConfigValueRow = {
  item_key: string;
  effective_from: string;
  value_numeric: number | null;
  value_text: string | null;
  value_json: unknown;
};

const waitingColumns: Column<OutstandingReceiptRow>[] = [
  { id: "lot", header: "Lot", priority: 1, cell: (r) => `Lot ${r.lot_code}` },
  {
    id: "open",
    header: "",
    priority: 1,
    align: "right",
    cell: (r) => (
      <Link href={`/owner/central?line=${r.line_id}`} className={actionButton}>
        รับของ
      </Link>
    ),
  },
  {
    id: "date",
    header: "ออกจากเชียงใหม่",
    cell: (r) => thaiDate(r.dispatch_date),
  },
  {
    id: "kg",
    header: "น้ำหนักส่งออก",
    numeric: true,
    cell: (r) => `${kg(r.dispatched_weight_kg)} กก.`,
  },
  {
    id: "age",
    header: "รอมาแล้ว",
    numeric: true,
    cell: (r) => `${r.age_days} วัน`,
  },
];

const partialColumns: Column<OutstandingReceiptRow>[] = [
  { id: "lot", header: "Lot", priority: 1, cell: (r) => `Lot ${r.lot_code}` },
  {
    id: "left",
    header: "ยังค้าง",
    priority: 1,
    numeric: true,
    cell: (r) => `${kg(r.outstanding_weight_kg)} กก.`,
  },
  {
    id: "kg",
    header: "ส่งออก / รับแล้ว",
    numeric: true,
    cell: (r) =>
      `${kg(r.dispatched_weight_kg)} / ${kg(r.received_weight_kg)} กก.`,
  },
  {
    id: "age",
    header: "รอมาแล้ว",
    numeric: true,
    cell: (r) => `${r.age_days} วัน`,
  },
];

function asBoolean(r: ConfigValueRow): boolean {
  return r.value_json === true || r.value_text?.toLowerCase() === "true";
}

export default async function CentralPage(props: PageProps<"/owner/central">) {
  const params = await props.searchParams;
  const lineId = one(params.line);
  const received = parseKg(one(params.received));

  const supabase = await createClient();
  const [linesRes, configRes, centralRes] = await Promise.all([
    supabase
      .from("v_outstanding_receipts")
      .select("*")
      .eq("route", "CM_TO_FOODIVA")
      .order("dispatched_at"),
    supabase
      .from("v_config_history")
      .select("item_key, effective_from, value_numeric, value_text, value_json")
      .eq("source", "CONFIG")
      .in("item_key", [THRESHOLD, REQUIRES])
      .is("scope_location_id", null),
    supabase.from("v_central_available").select("available_qty"),
  ]);
  const error = linesRes.error ?? configRes.error ?? centralRes.error;

  const lines = (linesRes.data ?? []) as OutstandingReceiptRow[];
  const waiting = lines.filter((l) => l.received_weight_kg === null);
  const partial = lines.filter((l) => l.received_weight_kg !== null);

  const config = (configRes.data ?? []) as ConfigValueRow[];
  const thresholds: DatedValue<number>[] = config
    .filter((r) => r.item_key === THRESHOLD && r.value_numeric !== null)
    .map((r) => ({
      effective_from: r.effective_from,
      value: Number(r.value_numeric),
    }));
  const requiresReason: DatedValue<boolean>[] = config
    .filter((r) => r.item_key === REQUIRES)
    .map((r) => ({ effective_from: r.effective_from, value: asBoolean(r) }));

  const centralH = (
    (centralRes.data ?? []) as { available_qty: number }[]
  ).reduce((s, r) => s + toHundredths(r.available_qty), 0);

  if (lineId) {
    const line = waiting.find((l) => l.line_id === lineId);
    const part = partial.find((l) => l.line_id === lineId);
    return (
      <div className="mx-auto flex w-full max-w-[720px] flex-col gap-4">
        <Link href="/owner/central" className={actionLink}>
          ← รายการรอรับเข้าคลัง
        </Link>
        {line ? (
          <>
            <h1 className="text-h1 text-text-primary">
              รับของขากลับ · Lot {line.lot_code}
            </h1>
            <CentralIntakeForm
              line={line}
              idempotencyKey={newFormKey()}
              today={todayBangkok()}
              thresholds={thresholds}
              requiresReason={requiresReason}
            />
          </>
        ) : (
          <p className="rounded-lg border border-border bg-surface p-6 text-body text-text-secondary">
            {part
              ? `Lot ${part.lot_code} รับเข้าคลังไปแล้วบางส่วน ยังค้างบนรถ ${kg(part.outstanding_weight_kg)} กก. — รับซ้ำไม่ได้ ยอดค้างรอปิดตามวิธีที่เจ้าของตั้งไว้`
              : "รายการนี้ไม่อยู่ในรายการรอรับแล้ว"}
          </p>
        )}
      </div>
    );
  }

  return (
    <div className="mx-auto flex w-full max-w-[960px] flex-col gap-4">
      <h1 className="text-h1 text-text-primary">สต็อกกลาง</h1>
      <p className="text-body-sm text-text-secondary">
        ของขากลับจากเชียงใหม่เป็นสต็อกกลางเมื่อยืนยันน้ำหนักรับจริงเท่านั้น
        ส่วนต่างเกินเกณฑ์ต้องมีเหตุผล แต่ยังบันทึกได้
      </p>

      {received !== null ? (
        <p
          role="status"
          className="rounded-lg border border-success bg-success-subtle p-3 text-body-sm text-success"
        >
          รับเข้าคลังกลาง {kg(received)} กก. แล้ว — พร้อมจัดสรรที่{" "}
          <Link href="/owner/allocate" className="font-medium underline">
            จัดสรรสู่สาขา
          </Link>
        </p>
      ) : null}

      <section className="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-border bg-surface p-4">
        <span className="flex flex-col">
          <span className="text-body-sm text-text-secondary">
            ของแช่แข็งในคลังกลาง พร้อมจัดสรร
          </span>
          <span className="text-num-lg text-text-primary tabular-nums">
            {kg(centralH / 100)} กก.
          </span>
        </span>
        <Link href="/owner/allocate" className={actionLink}>
          จัดสรรสู่สาขา →
        </Link>
      </section>

      {error ? (
        <p className="rounded-lg border border-danger bg-danger-subtle p-4 text-body text-danger">
          อ่านรายการไม่สำเร็จ — {error.message}
        </p>
      ) : (
        <>
          <h2 className="text-h2 text-text-primary">
            รอรับเข้าคลัง ({waiting.length})
          </h2>
          <ResponsiveTable
            columns={waitingColumns}
            rows={waiting}
            keyField={(r) => r.line_id}
            emptyState={
              <p className="rounded-lg border border-border bg-surface p-6 text-center text-body text-text-secondary">
                ไม่มีของขากลับที่รอรับ — รถขากลับออกจากเชียงใหม่ที่{" "}
                <Link href="/owner/transport" className="text-accent underline">
                  ขนส่ง
                </Link>
              </p>
            }
          />

          {partial.length > 0 ? (
            <>
              <h2 className="text-h2 text-text-primary">
                รับไม่ครบ ยอดยังค้างบนรถ ({partial.length})
              </h2>
              <ResponsiveTable
                columns={partialColumns}
                rows={partial}
                keyField={(r) => r.line_id}
                emptyState={null}
              />
            </>
          ) : null}
        </>
      )}
    </div>
  );
}
