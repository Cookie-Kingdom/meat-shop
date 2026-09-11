import Link from "next/link";
import type { ReactNode } from "react";
import { cva } from "class-variance-authority";

/* ChecklistItem — BR 01's row (DESIGN-CONTRACTS.md `ChecklistItem`, LAYOUT-SKELETONS S6).
 *
 * DONE IS DERIVED FROM THE RECORDS, NEVER FROM A LOCAL TICK. The page decides `done` from a
 * view (a report exists, no line is outstanding, thawed_kg > 0) and this component only draws
 * it. Tapping an item navigates to the screen that completes it; it never marks anything.
 *
 * 56px, full width, chevron when it goes somewhere. `blocked` names the missing prerequisite;
 * `disabled` is a screen that is not built yet. */

export const checklistItem = cva(
  "flex min-h-14 w-full items-center gap-3 rounded-lg border px-4 py-2 text-left",
  {
    variants: {
      state: {
        todo: "border-border bg-surface text-text-primary hover:bg-surface-sunken",
        done: "border-success bg-success-subtle text-text-primary",
        blocked: "border-border bg-surface-sunken text-text-secondary",
        disabled:
          "border-dashed border-border bg-surface-sunken text-text-muted",
      },
    },
    defaultVariants: { state: "todo" },
  },
);

const MARK = { todo: "○", done: "✓", blocked: "–", disabled: "–" } as const;
/* The mark is aria-hidden and the border is colour, so the state is spoken here (^ref-67). */
const STATE_TH = {
  todo: "ยังไม่ทำ",
  done: "เสร็จแล้ว",
  blocked: "ทำยังไม่ได้",
  disabled: "ยังไม่เปิดใช้",
} as const;

type State = keyof typeof MARK;

export function ChecklistBody({
  state,
  label,
  detail,
  chevron,
}: {
  state: State;
  label: string;
  detail?: ReactNode;
  chevron: boolean;
}) {
  return (
    <>
      <span
        aria-hidden
        className={
          state === "done" ? "text-h3 text-success" : "text-h3 text-text-muted"
        }
      >
        {MARK[state]}
      </span>
      <span className="sr-only">{STATE_TH[state]} · </span>
      <span className="flex flex-1 flex-col">
        <span className="text-body">{label}</span>
        {detail ? (
          <span className="text-caption text-text-secondary">{detail}</span>
        ) : null}
      </span>
      {chevron ? (
        <span aria-hidden className="text-h3 text-text-muted">
          ›
        </span>
      ) : null}
    </>
  );
}

export function ChecklistItem({
  label,
  done = false,
  href,
  blocked,
  disabled = false,
  detail,
}: {
  label: string;
  done?: boolean;
  href?: string;
  /** Thai reason the item cannot be started yet. */
  blocked?: string;
  disabled?: boolean;
  detail?: ReactNode;
}) {
  const state: State = disabled
    ? "disabled"
    : blocked
      ? "blocked"
      : done
        ? "done"
        : "todo";
  const goes = Boolean(href) && state !== "disabled" && state !== "blocked";
  const body = (
    <ChecklistBody
      state={state}
      label={label}
      detail={blocked ?? detail}
      chevron={goes}
    />
  );

  return goes && href ? (
    <Link href={href} className={checklistItem({ state })}>
      {body}
    </Link>
  ) : (
    <div
      aria-disabled={state === "disabled" || state === "blocked"}
      className={checklistItem({ state })}
    >
      {body}
    </div>
  );
}
