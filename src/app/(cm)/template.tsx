import { WaitingNotice } from "@/features/setup/components/waiting-notice";

/* (cm) template — the L3 wait-for-Owner notice (card ^ref-61, ADR-023).
 *
 * A template rather than the layout, for the reason `(owner)/template.tsx` gives: it wraps
 * every CM page without touching `layout.tsx`, which the parallel build reserves for nav
 * lines. The notice names only what stops an L3's own work, and never a value — the chef
 * house never sees a price (BR15, R20). */

export default function CmTemplate({
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
