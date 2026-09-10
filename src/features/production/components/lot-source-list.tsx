"use client";

import { Plus, Trash2 } from "lucide-react";

import {
  acceptKgKeystroke,
  formatHundredths,
  parseKg,
} from "@/features/production/kg";
import { cn } from "@/lib/utils";

/* LotSourceList + LotSourceRow (DESIGN-CONTRACTS) for CM 04: which lots went into the smoker
 * today, and how much from each. Every kilogram names the lot it came out of, even when two
 * lots were smoked on one day (D05, ADR-017) — the lot is chosen, never inferred.
 *
 * Capped at 4 rows and rendered inline: this list does not get its own scroll region, so
 * CM 04 keeps exactly one (PackWeightList's). One row is the normal day and must not look
 * like a repeater, so the delete control appears only once there are two.
 *
 * A weight over the lot's pending remainder is WARNED, not refused: R18's remainder is a
 * computed figure with no constraint behind it, and the scale is the truth. A lot picked twice
 * is marked, since fn_upsert_smoke_daily_log refuses it (SOURCE_LOT_DUPLICATED). Rows are
 * keyed by a stable id, never the index. */

export const MAX_SOURCE_ROWS = 4;

export type SourceOption = {
  lotId: string;
  lotCode: string;
  /** What this lot still has waiting, BEFORE today's entry — the view's remainder plus
   * whatever today's saved log already drew, since saving replaces it. Null when the lot's
   * pre-smoke weight is not recorded yet. */
  availableH: number | null;
};

export type SourceRow = { id: string; lotId: string; kg: string };

export function LotSourceList({
  rows,
  options,
  onChange,
  onAdd,
  onDelete,
  onFieldFocus,
}: {
  rows: SourceRow[];
  options: SourceOption[];
  onChange: (id: string, patch: Partial<Omit<SourceRow, "id">>) => void;
  onAdd: () => void;
  onDelete: (id: string) => void;
  onFieldFocus?: () => void;
}) {
  const byLot = new Map(options.map((o) => [o.lotId, o]));
  const picks = new Map<string, number>();
  for (const r of rows)
    if (r.lotId) picks.set(r.lotId, (picks.get(r.lotId) ?? 0) + 1);

  let totalH = 0;
  for (const r of rows) totalH += parseKg(r.kg) ?? 0;

  return (
    <section className="flex flex-col gap-2" aria-label="Lot ที่นำไปรมควัน">
      <h2 className="text-h3 text-text-primary">Lot ที่นำไปรมควันวันนี้</h2>

      {rows.map((row, i) => {
        const option = byLot.get(row.lotId);
        const typed = parseKg(row.kg);
        const duplicate = row.lotId !== "" && (picks.get(row.lotId) ?? 0) > 1;
        const over =
          option?.availableH != null &&
          typed !== null &&
          typed > option.availableH;
        return (
          <div key={row.id} className="flex flex-col gap-1">
            <div className="flex flex-wrap items-center gap-2">
              <select
                aria-label={`Lot ต้นทางแถวที่ ${i + 1}`}
                value={row.lotId}
                onChange={(e) => onChange(row.id, { lotId: e.target.value })}
                onFocus={onFieldFocus}
                aria-invalid={duplicate ? true : undefined}
                className={cn(
                  "h-12 min-w-0 flex-1 basis-40 rounded-md border bg-surface px-3 font-mono text-body text-text-primary focus-visible:outline-2 focus-visible:outline-focus-ring",
                  duplicate ? "border-danger" : "border-border",
                )}
              >
                <option value="">เลือก Lot</option>
                {options.map((o) => (
                  <option key={o.lotId} value={o.lotId}>
                    {o.availableH === null
                      ? o.lotCode
                      : `${o.lotCode} · รอทำ ${formatHundredths(o.availableH)} กก.`}
                  </option>
                ))}
              </select>
              <div className="relative w-32">
                <input
                  type="text"
                  inputMode="decimal"
                  autoComplete="off"
                  enterKeyHint="next"
                  aria-label={`น้ำหนักที่นำไปรมควันแถวที่ ${i + 1} (กก.)`}
                  value={row.kg}
                  onFocus={onFieldFocus}
                  onChange={(e) =>
                    onChange(row.id, {
                      kg: acceptKgKeystroke(row.kg, e.target.value),
                    })
                  }
                  className="h-12 w-full rounded-md border border-border bg-surface pr-10 pl-3 text-right font-mono text-num-md text-text-primary tabular-nums focus-visible:outline-2 focus-visible:outline-focus-ring"
                />
                <span className="pointer-events-none absolute inset-y-0 right-2 flex items-center text-caption text-text-secondary">
                  กก.
                </span>
              </div>
              {rows.length > 1 ? (
                <button
                  type="button"
                  onClick={() => onDelete(row.id)}
                  aria-label={`ลบแถว Lot ที่ ${i + 1}`}
                  className="inline-flex size-11 items-center justify-center rounded-md border border-border text-text-secondary hover:bg-surface-sunken"
                >
                  <Trash2 aria-hidden className="size-5" />
                </button>
              ) : null}
            </div>
            {duplicate ? (
              <p className="text-caption text-danger">
                เลือก Lot นี้ซ้ำ — รวมน้ำหนักให้อยู่แถวเดียว
              </p>
            ) : over && option?.availableH != null ? (
              <p className="text-caption text-warning">
                เกินน้ำหนักรอทำของ Lot นี้ (
                {formatHundredths(option.availableH)} กก.) — ตรวจตาชั่งอีกครั้ง
              </p>
            ) : null}
          </div>
        );
      })}

      <div className="flex flex-wrap items-center justify-between gap-2">
        {rows.length < MAX_SOURCE_ROWS ? (
          <button
            type="button"
            onClick={onAdd}
            className="inline-flex h-11 items-center gap-1 rounded-md border border-border px-3 text-label text-accent hover:bg-surface-sunken"
          >
            <Plus aria-hidden className="size-4" />
            เพิ่ม Lot
          </button>
        ) : (
          <span className="text-caption text-text-muted">ครบ 4 Lot แล้ว</span>
        )}
        <p className="text-body-sm text-text-secondary">
          น้ำหนักที่นำไปรมควันรวม{" "}
          <span className="font-mono text-num-md text-text-primary tabular-nums">
            {formatHundredths(totalH)}
          </span>{" "}
          กก.
        </p>
      </div>
    </section>
  );
}
