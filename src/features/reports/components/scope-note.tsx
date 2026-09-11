import type { ReactNode } from "react";

/* ScopeNote — a declared boundary, not missing data (DESIGN-CONTRACTS DashboardGrid, D04,
 * UAT-17). It is never dismissible and has no close control: a profit figure shown without its
 * scope is a defect, because the Owner reads it as the whole picture. */

export function ScopeNote({ children }: { children: ReactNode }) {
  return (
    <p className="text-caption text-text-secondary">
      <span className="font-medium">ขอบเขต:</span> {children}
    </p>
  );
}
