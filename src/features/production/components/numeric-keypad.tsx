"use client";

import type { ReactNode } from "react";
import { cva } from "class-variance-authority";
import { Check, CornerDownLeft, Delete } from "lucide-react";

const keyStyle = cva(
  "inline-flex items-center justify-center rounded-sm font-mono text-num-md select-none focus-visible:outline-2 focus-visible:outline-focus-ring active:opacity-70",
  {
    variants: {
      accent: {
        /** ↵ and ✓ — the two keys that move the work on. */
        true: "bg-accent text-accent-fg",
        false: "border border-border bg-surface text-text-primary",
      },
    },
    defaultVariants: { accent: false },
  },
);

/* NumericKeypad (DESIGN-CONTRACTS) — CM 04's in-app keypad for sixty pack weights in a row.
 * Three things the OS keypad cannot do: a fixed height the S2 budget is built on, a
 * "commit and advance" key, and the same layout on every Android IME.
 *
 *   7  8  9  ⌫
 *   4  5  6  .
 *   1  2  3  ↵
 *   00 0  C  ✓
 *
 * h-72 is 288px against the contract's 290 (--h-keyboard is not a token yet); the two px do
 * not move anything the budget depends on. Every key is a 70px-tall tap target.
 *
 * Keys must not take focus from the pack row being edited, so pointerdown is cancelled and
 * the action runs on click. ⌫ deletes one character; C clears the active row only, never the
 * list; there is no long-press behaviour, because a wet gloved press is not reliably
 * distinguishable from a slow tap. */

type Props = {
  onKey: (key: string) => void;
  onBackspace: () => void;
  onClear: () => void;
  onAdvance: () => void;
  onCommit: () => void;
};

type Cell = {
  label: ReactNode;
  aria: string;
  run: (p: Props) => void;
  accent?: boolean;
};

const digit = (d: string): Cell => ({
  label: d,
  aria: d,
  run: (p) => p.onKey(d),
});

const CELLS: Cell[] = [
  digit("7"),
  digit("8"),
  digit("9"),
  {
    label: <Delete aria-hidden className="size-6" />,
    aria: "ลบหนึ่งตัว",
    run: (p) => p.onBackspace(),
  },
  digit("4"),
  digit("5"),
  digit("6"),
  { label: ".", aria: "จุดทศนิยม", run: (p) => p.onKey(".") },
  digit("1"),
  digit("2"),
  digit("3"),
  {
    label: <CornerDownLeft aria-hidden className="size-6" />,
    aria: "ถุงถัดไป",
    run: (p) => p.onAdvance(),
    accent: true,
  },
  digit("00"),
  digit("0"),
  { label: "C", aria: "ล้างช่องนี้", run: (p) => p.onClear() },
  {
    label: <Check aria-hidden className="size-6" />,
    aria: "เสร็จ ปิดแป้น",
    run: (p) => p.onCommit(),
    accent: true,
  },
];

export function NumericKeypad(props: Props) {
  return (
    <div
      role="group"
      aria-label="แป้นตัวเลข"
      /* The safe-area inset has no token: it is the device's, not ours (REVIEW 1). */
      className="fixed inset-x-0 bottom-0 z-20 grid h-72 grid-cols-4 grid-rows-4 gap-1 border-t border-border bg-surface-sunken p-1 pb-[calc(0.25rem+env(safe-area-inset-bottom))]"
    >
      {CELLS.map((cell) => (
        <button
          key={cell.aria}
          type="button"
          aria-label={cell.aria}
          onPointerDown={(e) => e.preventDefault()}
          onClick={() => cell.run(props)}
          className={keyStyle({ accent: Boolean(cell.accent) })}
        >
          {cell.label}
        </button>
      ))}
    </div>
  );
}
