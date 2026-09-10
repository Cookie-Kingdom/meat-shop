import Link from "next/link";
import { ChevronRight } from "lucide-react";

import { formatKg } from "@/features/production/kg";
import type { OperatorLot } from "@/features/production/types";
import { thaiDate } from "@/lib/format/date";

import { LotStateBadge } from "./lot-state-badge";

/* LotList (DESIGN-CONTRACTS), CM 01's rows: 88px each at 360px — reference and LotStateBadge
 * on line 1, the Owner-declared weight and the date on line 2 (v0.2 line 78). No price and no
 * yield, because the view has neither (BR15). The whole row is the tap target. */

export function LotList({ lots }: { lots: OperatorLot[] }) {
  return (
    <ul className="flex flex-col gap-2">
      {lots.map((lot) => (
        <li key={lot.lot_id}>
          <Link
            href={`/cm/lots/${lot.lot_id}`}
            className="flex min-h-22 items-center gap-3 rounded-lg border border-border bg-surface px-4 py-3 hover:bg-surface-sunken"
          >
            <div className="flex min-w-0 flex-1 flex-col gap-1">
              <div className="flex flex-wrap items-center gap-2">
                <span className="font-mono text-num-md text-text-primary">
                  {lot.lot_code}
                </span>
                <LotStateBadge state={lot.state} />
              </div>
              <p className="text-body-sm text-text-secondary">
                Foodiva ส่ง{" "}
                <span className="font-mono text-text-primary tabular-nums">
                  {formatKg(lot.foodiva_sent_weight_kg)}
                </span>{" "}
                กก. · {thaiDate(lot.lot_date)}
              </p>
            </div>
            <ChevronRight
              aria-hidden
              className="size-5 shrink-0 text-text-muted"
            />
          </Link>
        </li>
      ))}
    </ul>
  );
}
