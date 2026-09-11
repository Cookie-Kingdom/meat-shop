import Link from "next/link";
import { ChevronLeft } from "lucide-react";

import type { OperatorLot } from "@/features/production/types";

import { ReadError } from "@/components/shared/read-error";
import { EmptyState } from "./empty-state";
import { LotStateBadge } from "./lot-state-badge";

/* The header every CM screen past CM 01 opens with (S1/S2/S4: "◀ Screen title"): a back link,
 * the screen's title, and which lot this is. It scrolls away; the DateNavigator, where there
 * is one, is what stays. */

const back =
  "inline-flex h-11 items-center gap-1 self-start text-label text-accent hover:underline";

export function LotHeader({
  lot,
  title,
  backHref,
  backLabel = "กลับ",
}: {
  lot: OperatorLot;
  title: string;
  backHref: string;
  backLabel?: string;
}) {
  return (
    <header className="flex flex-col gap-1">
      <Link href={backHref} className={back}>
        <ChevronLeft aria-hidden className="size-4" />
        {backLabel}
      </Link>
      <h1 className="text-h1 text-text-primary">{title}</h1>
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono text-num-md text-text-primary">
          {lot.lot_code}
        </span>
        <LotStateBadge state={lot.state} />
        {lot.chef_house_name ? (
          <span className="text-caption text-text-secondary">
            {lot.chef_house_name}
          </span>
        ) : null}
      </div>
    </header>
  );
}

/** The lot could not be read: a failed read is an error with a retry; no row is a stale link
 * or somebody else's lot — the view answers both with nothing, by design (R34). */
export function LotUnavailable({
  error,
  retryHref,
}: {
  error?: string | null;
  retryHref?: string;
}) {
  return (
    <div className="flex flex-col gap-4">
      <Link href="/cm" className={back}>
        <ChevronLeft aria-hidden className="size-4" />
        งานของฉัน
      </Link>
      {error ? (
        <ReadError title="อ่านข้อมูล Lot ไม่สำเร็จ" raw={error}>
          {retryHref ? (
            <Link href={retryHref} className="text-accent underline">
              ลองอีกครั้ง
            </Link>
          ) : null}
        </ReadError>
      ) : (
        <EmptyState
          title="ไม่พบ Lot นี้ในงานของคุณ"
          body="ลิงก์อาจเก่า หรือ Lot นี้มอบหมายให้คนอื่น — กลับไปเลือกจากรายการงานของฉัน"
        />
      )}
    </div>
  );
}
