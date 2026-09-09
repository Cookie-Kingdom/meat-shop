import Link from "next/link";

import {
  ResponsiveTable,
  type Column,
} from "@/components/shared/responsive-table";
import { labelFor } from "../keys";
import { itemId, thaiDate, type ConfigRow } from "../types";

/* ConfigTable — OW 10 (card ^ref-12).
 *
 * Contract: `design/DESIGN-CONTRACTS.md` → `ConfigTable`. Rendered through the shared
 * `ResponsiveTable` extracted in this same card.
 *
 * THERE IS NO EDIT AFFORDANCE, ANYWHERE. Every row's action is
 * `ตั้งค่าใหม่ตั้งแต่วันที่…`, which opens a create sheet and appends a new dated row
 * (ADR-006, BR23). A cell that looks editable implies a mutation the database will not do —
 * and the shape that looks most like an edit, a same-day correction, is the one
 * `fn_set_config` refuses by name.
 *
 * A FUTURE ROW IS VISUALLY DISTINCT FROM THE EFFECTIVE ONE (the contract says so, and the
 * view computes `is_future` for exactly this). The Owner entering next month's price has to
 * be able to see, at a glance, that today's number is still the old one.
 */

/** One configurable item: the row in force (or the next one, if only future rows exist),
 * plus what it replaced — the revision line's `จาก 300.00`. */
export type Item = {
  id: string;
  current: ConfigRow;
  previous: ConfigRow | null;
};

function Value({ row }: { row: ConfigRow }) {
  return (
    <span className="text-num-sm text-text-primary tabular-nums">
      {row.value_display ?? "—"}
    </span>
  );
}

const COLUMNS: Column<Item>[] = [
  {
    id: "item",
    header: "รายการ",
    priority: 1,
    cell: ({ current }) => (
      <>
        <span className="block">
          {labelFor(current.source, current.item_key, current.item_label_th)}
        </span>
        {current.scope_name_th ? (
          <span className="block text-caption text-text-muted">
            เฉพาะ {current.scope_name_th}
          </span>
        ) : null}
      </>
    ),
  },
  {
    id: "value",
    header: "ค่าปัจจุบัน",
    numeric: true,
    cell: (item) => (
      <>
        <Value row={item.current} />
        {/* The revision line. Without it the append-only rule is invisible: the screen shows
            one number and nothing says it replaced another. */}
        {item.previous ? (
          <span className="mt-0.5 block text-caption text-text-muted tabular-nums">
            แก้ {thaiDate(item.current.effective_from)} · จาก{" "}
            {item.previous.value_display ?? "—"}
          </span>
        ) : null}
      </>
    ),
  },
  {
    id: "effective",
    header: "เริ่มใช้",
    numeric: true,
    className: "whitespace-nowrap",
    cell: ({ current }) => (
      <>
        <span className="block text-text-secondary">
          {thaiDate(current.effective_from)}
        </span>
        {current.is_future ? (
          <span className="mt-0.5 inline-flex items-center rounded-sm bg-warning-subtle px-1.5 py-0.5 text-caption font-medium text-warning">
            ยังไม่มีผล
          </span>
        ) : null}
      </>
    ),
  },
  {
    id: "by",
    header: "ผู้ตั้งค่า",
    cell: ({ current }) => (
      <span className="text-text-secondary">
        {current.created_by_name ?? "—"}
      </span>
    ),
  },
  {
    id: "actions",
    header: "",
    align: "right",
    className: "whitespace-nowrap",
    cell: ({ current }) => (
      <span className="flex flex-wrap items-center justify-end gap-3">
        <Link
          href={`/owner/config?history=${encodeURIComponent(itemId(current))}`}
          className="inline-flex h-11 items-center text-label text-accent hover:underline"
        >
          ประวัติ
        </Link>
        <Link
          href={`/owner/config?set=${encodeURIComponent(itemId(current))}`}
          className="inline-flex h-11 items-center text-label text-accent hover:underline"
        >
          ตั้งค่าใหม่ตั้งแต่วันที่…
        </Link>
      </span>
    ),
  },
];

export function ConfigTable({
  items,
  mode,
  emptyState,
}: {
  items: Item[];
  mode: "cards" | "table";
  emptyState: React.ReactNode;
}) {
  return (
    <ResponsiveTable
      columns={COLUMNS}
      rows={items}
      keyField={(i) => i.id}
      mode={mode}
      /* A row whose value has not taken effect yet reads as locked rather than as active —
       * the same `--color-locked-subtle` the contract gives a locked row. */
      isMuted={(i) => i.current.is_future}
      emptyState={emptyState}
    />
  );
}
