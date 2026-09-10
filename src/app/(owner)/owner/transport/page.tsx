import Link from "next/link";

import { actionButton } from "@/components/ui/controls";
import { configAt, configBoolean } from "@/features/config/resolve";
import { NewRunSheet } from "@/features/transport/components/new-run-sheet";
import { OutstandingList } from "@/features/transport/components/outstanding-list";
import { ReceiveSheet } from "@/features/transport/components/receive-sheet";
import { RunSheet } from "@/features/transport/components/run-sheet";
import { RunsList } from "@/features/transport/components/runs-list";
import { VarianceList } from "@/features/transport/components/variance-list";
import {
  allocMethod,
  parseFareTable,
  tripKind,
} from "@/features/transport/outbound";
import {
  getRun,
  listDispatchableLots,
  listOutstanding,
  listPlaces,
  listRuns,
  listVariance,
  runLines,
} from "@/features/transport/queries";
import { todayBangkok } from "@/lib/format/date";
import { one } from "@/lib/params";
import { createClient } from "@/lib/supabase/server";

/* OW 02 — ขนส่ง (card ^ref-24, F5 / M2). Route `/owner/transport`, kept exactly as
 * PLAN-transport.md T9 names it, because lane A's ^ref-37 (OW 05–07) links here.
 *
 * One page, three sheets opened through the URL like OW 01 and OW 10: `?new=1` books an
 * outbound run (GET preview, then confirm), `?run=<id>` is one run with its stored split,
 * and `?receive=<line>` signs for a CENTRAL line. Underneath, always: ค้างรับ
 * (v_outstanding_receipts) and ส่วนต่างตอนรับ (v_transport_variance). Both views are reachable
 * from this screen without a click, which is ^ref-24's acceptance clause 1. Then the runs.
 *
 * THE ROLE GATE IS NOT HERE. Every read is a view with its own role test (R34) and every
 * write an fn_* with its own preamble. The (owner) layout's requireRole is the mirror
 * (ADR-004).
 *
 * ONE IDEMPOTENCY KEY PER RENDER, handed back in `?k=` after a refusal, as on OW 01. The
 * outbound action derives each step's key from it (Finding 5), so a retry replays.
 */

const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

function many(value: string | string[] | undefined): string[] {
  if (value === undefined) return [];
  return Array.isArray(value) ? value : [value];
}

const RECEIPT_ECHO = [
  "event_date",
  "received_weight_kg",
  "variance_reason",
  "variance_settlement",
];

const SAVED: Record<string, string> = {
  run: "ส่งรถแล้ว — ล็อตบนรถเปลี่ยนเป็น “กำลังขนส่ง” และปรากฏที่หน้าเชียงใหม่ ค่าขนส่งแบ่งตามวิธีที่บันทึกไว้ด้านล่าง",
  lines: "เพิ่มล็อตขึ้นรถแล้ว และแบ่งค่าขนส่งใหม่ให้ทุกล็อตบนรถ",
  alloc: "แบ่งค่าขนส่งใหม่แล้ว",
  receipt: "บันทึกรับของเข้าคลังกลางแล้ว",
};

export default async function TransportPage(
  props: PageProps<"/owner/transport">,
) {
  const params = await props.searchParams;
  // One sheet at a time, in this order, so two forms never share a render key.
  const receiveId = UUID.test(one(params.receive)) ? one(params.receive) : "";
  const runId = !receiveId && UUID.test(one(params.run)) ? one(params.run) : "";
  const isNew = !receiveId && !runId && one(params.new) === "1";

  const saved = SAVED[one(params.saved)] ?? "";
  const err = one(params.err);
  const returnedKey = one(params.k);
  const idempotencyKey = UUID.test(returnedKey)
    ? returnedKey
    : crypto.randomUUID();
  const today = todayBangkok();
  const date = ISO_DATE.test(one(params.date)) ? one(params.date) : today;
  const selected = [...new Set(many(params.lot))].filter((v) => UUID.test(v));

  const db = await createClient();
  const [
    outstanding,
    variance,
    runs,
    places,
    thresholdCfg,
    requiresCfg,
    fareCfg,
    methodCfg,
    dispatchable,
    run,
    lines,
  ] = await Promise.all([
    listOutstanding(db),
    listVariance(db),
    listRuns(db),
    listPlaces(db),
    configAt(db, "receipt_variance_threshold_pct", today),
    receiveId ? configAt(db, "receipt_variance_requires_reason", today) : null,
    isNew ? configAt(db, "freight_thb_by_vehicle_type", date) : null,
    isNew ? configAt(db, "freight_alloc_method", date) : null,
    isNew || runId ? listDispatchableLots(db) : null,
    runId ? getRun(db, runId) : null,
    runId ? runLines(db, runId) : null,
  ]);

  const readError =
    outstanding.error ??
    variance.error ??
    runs.error ??
    dispatchable?.error ??
    lines?.error;
  const threshold =
    thresholdCfg?.value_numeric != null ? Number(thresholdCfg.value_numeric) : null;
  const receiveLine = receiveId
    ? (outstanding.rows.find((r) => r.line_id === receiveId) ?? null)
    : null;
  const echo = Object.fromEntries(RECEIPT_ECHO.map((f) => [f, one(params[f])]));
  const closeHref = "/owner/transport";

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-h1 text-text-primary">ขนส่ง</h1>
        <Link href="/owner/transport?new=1" className={actionButton}>
          ส่งรถขาไป
        </Link>
      </div>

      <p className="text-body-sm text-text-secondary">
        ค่าขนส่งดึงจากการตั้งค่าตามประเภทรถ ไม่มีช่องกรอกค่าขนส่ง (BR10) ·
        ของทุกล็อตต้องเข้าคลังกลางก่อนส่งสาขาเสมอ และรถส่งสาขาไม่มีค่าขนส่ง (BR11)
      </p>

      {saved ? (
        <p className="rounded-lg border border-success bg-success-subtle p-3 text-body-sm text-success">
          {saved}
        </p>
      ) : null}
      {err ? (
        <p
          role="alert"
          className="rounded-lg border border-danger bg-danger-subtle p-3 text-body-sm text-danger"
        >
          {err}
        </p>
      ) : null}
      {readError ? (
        <p className="rounded-lg border border-danger bg-danger-subtle p-4 text-body text-danger">
          อ่านข้อมูลขนส่งไม่สำเร็จ — {readError}
        </p>
      ) : null}

      {isNew ? (
        <NewRunSheet
          date={date}
          vehicle={one(params.vehicle)}
          trip={tripKind(one(params.trip))}
          selected={selected}
          preview={one(params.preview) === "1"}
          note={one(params.note)}
          fareTable={parseFareTable(fareCfg?.value_json)}
          method={allocMethod(methodCfg?.value_text)}
          methodSet={methodCfg !== null}
          dispatchable={dispatchable?.rows ?? []}
          idempotencyKey={idempotencyKey}
          closeHref={closeHref}
        />
      ) : null}

      {runId ? (
        <RunSheet
          run={run}
          lines={lines?.rows ?? []}
          dispatchable={dispatchable?.rows ?? []}
          idempotencyKey={idempotencyKey}
          closeHref={closeHref}
        />
      ) : null}

      {receiveId ? (
        <ReceiveSheet
          line={receiveLine}
          place={
            receiveLine?.to_location_id
              ? places.get(receiveLine.to_location_id)
              : undefined
          }
          thresholdPct={threshold !== null ? threshold.toFixed(2) : null}
          requiresReason={configBoolean(requiresCfg)}
          idempotencyKey={idempotencyKey}
          today={today}
          echo={echo}
          closeHref={closeHref}
        />
      ) : null}

      <section className="flex flex-col gap-2">
        <h2 className="text-h2 text-text-primary">ค้างรับ</h2>
        <p className="text-caption text-text-muted">
          ส่งแล้วแต่ยังไม่ยืนยันรับครบ รวมรายการที่รับไม่ครบ (D06)
        </p>
        <OutstandingList
          rows={outstanding.rows}
          places={places}
          receiveHref={(id) => `/owner/transport?receive=${id}`}
        />
      </section>

      <section className="flex flex-col gap-2">
        <h2 className="text-h2 text-text-primary">ส่วนต่างตอนรับ</h2>
        <VarianceList rows={variance.rows} thresholdPct={threshold} />
      </section>

      <section className="flex flex-col gap-2">
        <h2 className="text-h2 text-text-primary">รอบรถล่าสุด</h2>
        <RunsList
          rows={runs.rows}
          hrefFor={(id) => `/owner/transport?run=${id}`}
        />
      </section>
    </div>
  );
}
