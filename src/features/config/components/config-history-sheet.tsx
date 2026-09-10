import { thaiDate } from "@/lib/format/date";
import { labelFor } from "../keys";
import type { ConfigRow } from "../types";
import { Sheet } from "./sheet";

/* The ประวัติ action's panel — OW 10 (card ^ref-12).
 *
 * The `ConfigTable` contract asks for a history action per row, "because the append-only
 * rule below is invisible unless the history is reachable from the value". This is that.
 *
 * IT IS THE SAME VIEW, FILTERED. `v_config_history` carries every dated row for every
 * source; the table renders `where is_current` and this renders one item's rows in full.
 * One definition of the data, two filters over it — a second `v_config_current` would be a
 * second definition of the word "current" (T1's decision 1).
 *
 * Server-rendered from `?history=` in the URL, so the panel is a link away and costs no
 * client JavaScript. A URL that reproduces an open history sheet is also a URL the Owner
 * can send to whoever asks why a rate changed.
 */

export function ConfigHistorySheet({
  rows,
  closeHref,
}: {
  rows: ConfigRow[];
  closeHref: string;
}) {
  const head = rows[0];
  if (!head) return null;

  return (
    <Sheet
      title={`ประวัติ · ${labelFor(head.source, head.item_key, head.item_label_th)}`}
      subtitle={head.scope_name_th ? `เฉพาะ ${head.scope_name_th}` : undefined}
      closeHref={closeHref}
      closeLabel="ปิด"
      tone="history"
    >
      <p className="text-caption text-text-secondary">
        ทุกแถวยังอ่านได้เสมอ ค่าที่เคยใช้คำนวณไปแล้วจะไม่ถูกเขียนทับ (BR23)
      </p>

      <ol className="flex flex-col gap-2">
        {rows.map((row) => (
          <li
            key={row.row_id}
            className="flex flex-wrap items-baseline gap-x-3 gap-y-1 rounded-md border border-border bg-surface p-3"
          >
            <span className="text-num-sm text-text-primary tabular-nums">
              {row.value_display ?? "—"}
            </span>
            <span className="text-body-sm text-text-secondary tabular-nums">
              ตั้งแต่ {thaiDate(row.effective_from)}
            </span>
            {row.is_current ? (
              <span className="rounded-sm bg-success-subtle px-1.5 py-0.5 text-caption font-medium text-success">
                ใช้อยู่
              </span>
            ) : null}
            {row.is_future ? (
              <span className="rounded-sm bg-warning-subtle px-1.5 py-0.5 text-caption font-medium text-warning">
                ยังไม่มีผล
              </span>
            ) : null}
            <span className="text-caption text-text-muted">
              โดย{" "}
              {row.created_by_name ??
                (row.created_by === null ? "ค่าตั้งต้นตามข้อกำหนด (v0.2)" : "—")}
            </span>
            {row.note ? (
              <span className="w-full text-caption text-text-secondary">
                หมายเหตุ: {row.note}
              </span>
            ) : null}
          </li>
        ))}
      </ol>
    </Sheet>
  );
}
