"use client";

import {
  memo,
  useCallback,
  useEffect,
  useRef,
  useState,
  type Dispatch,
  type SetStateAction,
} from "react";
import { cva } from "class-variance-authority";
import { Plus, Trash2 } from "lucide-react";

import {
  acceptKgKeystroke,
  formatHundredths,
  parseKg,
} from "@/features/production/kg";

import { NumericKeypad } from "./numeric-keypad";

const packInput = cva(
  "h-12 w-full rounded-md border bg-surface pr-10 pl-3 text-right font-mono text-num-md text-text-primary tabular-nums focus-visible:outline-2 focus-visible:outline-focus-ring",
  {
    variants: {
      state: {
        idle: "border-border",
        /** The row the keypad is typing into. */
        active: "border-accent",
        invalid: "border-danger",
      },
    },
    defaultVariants: { state: "idle" },
  },
);

/* PackWeightList + PackWeightRow (DESIGN-CONTRACTS) — CM 04's hardest part: up to sixty bag
 * weights, entered one after another with wet hands, standing (LAYOUT-SKELETONS S2).
 *
 * - ONE SCROLL REGION. The rows scroll inside a box capped at four rows on a phone
 *   (max-h-56 = 4 × 56px, the --scroll-cap derivation), ten at md:, uncapped at lg:.
 * - THE TOTALS ARE PINNED ABOVE IT, outside the scroll, so at row 60 the operator still sees
 *   the count and the kilograms. The add action is up there too — reaching the bottom of a
 *   scrolled list to find "add" is wrong one-handed.
 * - ROW 61 IS ONE TAP. ↵ on the last row appends a row and moves the keypad to it, scrolled
 *   into view inside the region.
 * - STABLE KEYS. Rows are keyed by id and memoised, so deleting row 30 does not remount or
 *   re-focus the other 59.
 * - NO BAG CODE (BR18) and NO YIELD (BR15): a row is an index and a weight, nothing else.
 *
 * The rows are a NEW BATCH. What is already saved for this smoke date is shown as a figure
 * above, not as editable rows: a saved batch is append-only from here, and a new key on the
 * same date appends to it (R39, TC-28). */

export type BagRow = { id: string; kg: string };

let seq = 0;
/** A client-only row id. Called from event handlers, never during render. */
export function newRowId(prefix = "r"): string {
  seq += 1;
  return `${prefix}${seq}`;
}

const PackRow = memo(function PackRow({
  id,
  index,
  value,
  active,
  onFocusRow,
  onChangeRow,
  onDeleteRow,
  onBlurRow,
  register,
}: {
  id: string;
  index: number;
  value: string;
  active: boolean;
  onFocusRow: (id: string) => void;
  onChangeRow: (id: string, next: string) => void;
  onDeleteRow: (id: string) => void;
  onBlurRow: (e: React.FocusEvent<HTMLInputElement>) => void;
  register: (id: string, el: HTMLInputElement | null) => void;
}) {
  const invalid = value !== "" && parseKg(value) === 0;
  const state = invalid ? "invalid" : active ? "active" : "idle";
  return (
    <li className="flex h-14 items-center gap-2 border-b border-border px-1 last:border-b-0">
      <span className="w-8 shrink-0 text-right font-mono text-caption text-text-secondary tabular-nums">
        {index}
      </span>
      <div className="relative min-w-0 flex-1">
        <input
          ref={(el) => register(id, el)}
          type="text"
          /* The in-app NumericKeypad replaces the OS keypad here; a hardware keyboard still types. */
          inputMode="none"
          autoComplete="off"
          aria-label={`น้ำหนักถุงที่ ${index} (กก.)`}
          aria-invalid={invalid ? true : undefined}
          value={value}
          onFocus={() => onFocusRow(id)}
          onBlur={onBlurRow}
          onChange={(e) => onChangeRow(id, e.target.value)}
          className={packInput({ state })}
        />
        <span className="pointer-events-none absolute inset-y-0 right-2 flex items-center text-caption text-text-secondary">
          กก.
        </span>
      </div>
      <button
        type="button"
        onPointerDown={(e) => e.preventDefault()}
        onClick={() => onDeleteRow(id)}
        aria-label={`ลบถุงที่ ${index}`}
        className="inline-flex size-11 shrink-0 items-center justify-center rounded-md border border-border text-text-secondary hover:bg-surface-sunken"
      >
        <Trash2 aria-hidden className="size-5" />
      </button>
    </li>
  );
});

export function PackWeightList({
  rows,
  setRows,
  savedCount,
  savedH,
}: {
  rows: BagRow[];
  setRows: Dispatch<SetStateAction<BagRow[]>>;
  /** Bags already saved under this smoke date (the group roll-up). */
  savedCount: number;
  savedH: number;
}) {
  const [activeId, setActiveId] = useState<string | null>(null);
  const inputs = useRef(new Map<string, HTMLInputElement>());

  const register = useCallback((id: string, el: HTMLInputElement | null) => {
    if (el) inputs.current.set(id, el);
    else inputs.current.delete(id);
  }, []);

  // Keep the active row focused and in view inside the region, above the keypad.
  useEffect(() => {
    if (!activeId) return;
    const el = inputs.current.get(activeId);
    if (!el) return;
    if (document.activeElement !== el) el.focus({ preventScroll: true });
    el.scrollIntoView({ block: "nearest" });
  }, [activeId]);

  const onFocusRow = useCallback((id: string) => setActiveId(id), []);

  const onChangeRow = useCallback(
    (id: string, next: string) =>
      setRows((rs) =>
        rs.map((r) =>
          r.id === id ? { ...r, kg: acceptKgKeystroke(r.kg, next) } : r,
        ),
      ),
    [setRows],
  );

  const onDeleteRow = useCallback(
    (id: string) => {
      setRows((rs) =>
        rs.length === 1
          ? [{ id: newRowId(), kg: "" }]
          : rs.filter((r) => r.id !== id),
      );
      setActiveId((a) => (a === id ? null : a));
    },
    [setRows],
  );

  // Focus leaving the pack rows for anything but the keypad closes the keypad.
  const onBlurRow = useCallback((e: React.FocusEvent<HTMLInputElement>) => {
    const next = e.relatedTarget;
    if (
      !(next instanceof HTMLInputElement) ||
      ![...inputs.current.values()].includes(next)
    ) {
      setActiveId(null);
    }
  }, []);

  function addRow() {
    const id = newRowId();
    setRows((rs) => [...rs, { id, kg: "" }]);
    setActiveId(id);
  }

  function edit(fn: (value: string) => string) {
    if (!activeId) return;
    setRows((rs) =>
      rs.map((r) =>
        r.id === activeId ? { ...r, kg: acceptKgKeystroke(r.kg, fn(r.kg)) } : r,
      ),
    );
  }

  function advance() {
    const i = rows.findIndex((r) => r.id === activeId);
    if (i >= 0 && i < rows.length - 1) {
      setActiveId(rows[i + 1].id);
      return;
    }
    addRow();
  }

  function commit() {
    inputs.current.get(activeId ?? "")?.blur();
    setActiveId(null);
  }

  let newH = 0;
  let newCount = 0;
  for (const r of rows) {
    const h = parseKg(r.kg);
    if (h !== null && h > 0) {
      newH += h;
      newCount += 1;
    }
  }

  return (
    <section className="flex flex-col gap-2" aria-label="น้ำหนักแพ็คแต่ละถุง">
      {/* SectionHeader: title, count, and the add action above the region. */}
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h2 className="flex items-center gap-2 text-h3 text-text-primary">
          น้ำหนักแพ็คแต่ละถุง
          <span className="rounded-full bg-surface-sunken px-2 font-mono text-caption text-text-secondary tabular-nums">
            {rows.length}
          </span>
        </h2>
        <button
          type="button"
          onClick={addRow}
          className="inline-flex h-11 items-center gap-1 rounded-md border border-border px-3 text-label text-accent hover:bg-surface-sunken"
        >
          <Plus aria-hidden className="size-4" />
          เพิ่มถุง
        </button>
      </div>

      {/* Pinned above the scroll region, outside it. */}
      <div className="flex flex-col gap-1 rounded-lg border border-border bg-surface-sunken p-3 text-body-sm text-text-secondary">
        <p>
          รอบนี้{" "}
          <span className="font-mono text-num-md text-text-primary tabular-nums">
            {newCount}
          </span>{" "}
          ถุง รวม{" "}
          <span className="font-mono text-num-md text-text-primary tabular-nums">
            {formatHundredths(newH)}
          </span>{" "}
          กก.
        </p>
        <p>
          บันทึกแล้วของวันนี้{" "}
          <span className="font-mono text-text-primary tabular-nums">
            {savedCount}
          </span>{" "}
          ถุง รวม{" "}
          <span className="font-mono text-text-primary tabular-nums">
            {formatHundredths(savedH)}
          </span>{" "}
          กก.
        </p>
        {rows.length > 4 ? (
          <p className="text-caption">
            เลื่อนดูได้ในกรอบ · ทั้งหมด {rows.length} แถว
          </p>
        ) : null}
      </div>

      <ol className="max-h-56 overflow-y-auto overscroll-contain rounded-lg border border-border bg-surface md:max-h-140 lg:max-h-none">
        {rows.map((r, i) => (
          <PackRow
            key={r.id}
            id={r.id}
            index={i + 1}
            value={r.kg}
            active={r.id === activeId}
            onFocusRow={onFocusRow}
            onChangeRow={onChangeRow}
            onDeleteRow={onDeleteRow}
            onBlurRow={onBlurRow}
            register={register}
          />
        ))}
      </ol>

      {activeId ? (
        <>
          {/* Room for the page to scroll above the keypad. */}
          <div aria-hidden className="h-72" />
          <NumericKeypad
            onKey={(k) => edit((v) => v + k)}
            onBackspace={() => edit((v) => v.slice(0, -1))}
            onClear={() => edit(() => "")}
            onAdvance={advance}
            onCommit={commit}
          />
        </>
      ) : null}
    </section>
  );
}
