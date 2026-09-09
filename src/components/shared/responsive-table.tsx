import type { ReactNode } from "react";

import { cn } from "@/lib/utils";

/* ResponsiveTable — the shared organism (extracted at OW 10, card ^ref-12).
 *
 * Contract: `design/COMPONENT-INVENTORY.md` (shared across OW 03, OW 08, OW 10, OW 11 and
 * BR 08) and `design/DESIGN-CONTRACTS.md` → columns with `align` / `numeric` / `priority`,
 * rows, keyField, emptyState, stickyHeader.
 *
 * ^ref-09 built OW 11's table inline and deferred the extraction here on purpose: OW 10 is
 * the second S8 screen and the first real evidence of what the props need to be. Two callers
 * is the point at which the shape stops being invented.
 *
 * MOBILE IS NOT A SHRUNKEN TABLE. Below `md:` each row is a card: the `priority: 1` columns
 * are the headline, the rest are label/value pairs inside it. Five columns do not fit at
 * 360px, and the card mode is the real design there, not a fallback. At `md:` and up it is a
 * real <table> that OWNS ITS OWN `overflow-x`, so the page body never scrolls sideways.
 *
 * Sizes from the contract: card min-height 72px, table row 48px. Numeric columns are
 * `tabular-nums` and right-aligned in BOTH modes — a column of kg values that does not align
 * is a defect (DESIGN.md).
 *
 * One row must not look broken: no zebra striping, header still present. That is why there
 * is no `odd:` background anywhere below.
 *
 * ponytail: no `loading` prop and no Skeleton state. Both callers are Server Components that
 * render with their data or not at all — a loading state here would be a prop nothing ever
 * sets to true. Ceiling: the first client-side caller. Add it then, alongside `onRowClick`
 * and `stickyHeader`, which the contract lists and neither caller needs yet.
 * ponytail: no virtualisation. The contract says revisit above ~200 rows; both callers
 * paginate well below that.
 */

export type Column<Row> = {
  /** Stable id — used as the React key and as the card's label. */
  id: string;
  /** Thai header text. Also the label in card mode; "" hides the label there. */
  header: string;
  /** Cell content for a row, in both modes. */
  cell: (row: Row) => ReactNode;
  /** 1 = card headline. Everything else becomes a label/value pair inside the card. */
  priority?: number;
  /** Right-aligned and `tabular-nums`, in both modes. */
  numeric?: boolean;
  align?: "left" | "right";
  /** Table-mode only. Card mode wraps instead — it has the room a 360px cell has not. */
  className?: string;
};

type Props<Row> = {
  columns: Column<Row>[];
  rows: Row[];
  keyField: (row: Row) => string;
  /** Rendered instead of the table when `rows` is empty. Missing data is not an error. */
  emptyState: ReactNode;
  /** Card mode below `md:` is the default; `table` forces the table at every width, which
   * is what the ConfigTable contract's `การ์ด` / `ตาราง` toggle sets. */
  mode?: "cards" | "table";
  /** Marks a row as superseded / locked — `--color-locked-subtle` (contract: locked-row). */
  isMuted?: (row: Row) => boolean;
};

const alignOf = <Row,>(c: Column<Row>) =>
  c.align ?? (c.numeric ? "right" : "left");

const numericCell = (numeric?: boolean) => (numeric ? "tabular-nums" : "");

export function ResponsiveTable<Row>({
  columns,
  rows,
  keyField,
  emptyState,
  mode = "cards",
  isMuted,
}: Props<Row>) {
  if (rows.length === 0) return <>{emptyState}</>;

  const headline = columns.filter((c) => c.priority === 1);
  const rest = columns.filter((c) => c.priority !== 1);

  return (
    <>
      {/* Cards. Hidden entirely in `table` mode — the toggle is a user choice, not a
          breakpoint, so both modes must be reachable at 360px. */}
      {mode === "cards" ? (
        <ul className="flex flex-col gap-3 md:hidden">
          {rows.map((row) => (
            <li
              key={keyField(row)}
              className={cn(
                "flex min-h-[72px] flex-col gap-2 rounded-lg border border-border p-4",
                isMuted?.(row) ? "bg-locked-subtle" : "bg-surface",
              )}
            >
              {headline.length > 0 ? (
                <div className="flex items-start justify-between gap-2">
                  {headline.map((c) => (
                    <span
                      key={c.id}
                      className={cn(
                        "text-label text-text-primary",
                        numericCell(c.numeric),
                        alignOf(c) === "right" && "text-right",
                      )}
                    >
                      {c.cell(row)}
                    </span>
                  ))}
                </div>
              ) : null}
              <dl className="flex flex-col gap-1 text-body-sm">
                {rest.map((c) => (
                  <div key={c.id} className="flex gap-2">
                    {c.header ? (
                      <dt className="shrink-0 text-text-secondary">
                        {c.header}
                      </dt>
                    ) : null}
                    <dd
                      className={cn(
                        "break-words text-text-primary",
                        numericCell(c.numeric),
                        alignOf(c) === "right" && "ml-auto text-right",
                      )}
                    >
                      {c.cell(row)}
                    </dd>
                  </div>
                ))}
              </dl>
            </li>
          ))}
        </ul>
      ) : null}

      {/* Table. Owns its own horizontal overflow (S8) — the page body never scrolls. */}
      <div
        className={cn(
          "overflow-x-auto rounded-lg border border-border bg-surface",
          mode === "cards" ? "hidden md:block" : "block",
        )}
      >
        <table className="w-full min-w-[48rem] text-body-sm">
          <thead className="border-b border-border text-label text-text-secondary">
            <tr>
              {columns.map((c) => (
                <th
                  key={c.id}
                  className={cn(
                    "px-4 py-3 font-medium",
                    alignOf(c) === "right" ? "text-right" : "text-left",
                  )}
                >
                  {c.header}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr
                key={keyField(row)}
                className={cn(
                  "h-12 border-b border-border last:border-b-0",
                  isMuted?.(row) && "bg-locked-subtle",
                )}
              >
                {columns.map((c) => (
                  <td
                    key={c.id}
                    className={cn(
                      "px-4 py-3 align-top text-text-primary",
                      alignOf(c) === "right" ? "text-right" : "text-left",
                      numericCell(c.numeric),
                      c.className,
                    )}
                  >
                    {c.cell(row)}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
