import { WaitingNotice } from "@/features/setup/components/waiting-notice";

/* (branch) template — the L2 wait-for-Owner notice (card ^ref-61, ADR-023).
 *
 * A template rather than the layout, for the reason `(owner)/template.tsx` gives: it wraps
 * every BR page without touching `layout.tsx`, which the parallel build reserves for nav
 * lines. The notice names only what stops an L2's own work, and never a value (R20). */

export default function BranchTemplate({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <>
      <WaitingNotice />
      {children}
    </>
  );
}
