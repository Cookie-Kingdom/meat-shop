import Link from "next/link";

import { UnsetMarker } from "@/features/setup/components/unset-marker";

/* ponytail: placeholder. It proves the group renders for its role and 403s for every
 * other one. The real OW 01–11 screens arrive with the cards that own their data.
 *
 * The links below are the only way into the built screens until the app-shell nav card
 * lands — and a nav item is not the enforcement anyway (^ref-09 acceptance, ADR-004). */

export default function OwnerHome() {
  return (
    <div className="flex flex-col gap-4">
      <p className="text-body text-text-secondary">
        OW 01–11 — ยังไม่มีหน้าจอใช้งานจริงครบทุกหน้า
      </p>
      <Link
        href="/owner/config"
        className="text-label text-accent hover:underline"
      >
        OW 10 · ตั้งค่าระบบ →
      </Link>
      <Link href="/owner/setup" className="text-label text-accent hover:underline">
        ตั้งค่าเริ่มต้น → <UnsetMarker />
      </Link>
      <Link href="/owner/expenses" className="text-label text-accent hover:underline">
        OW 09 · ค่าใช้จ่ายและเงินลงทุน →
      </Link>
      <Link
        href="/owner/audit"
        className="text-label text-accent hover:underline"
      >
        OW 11 · ประวัติการแก้ไข →
      </Link>
    </div>
  );
}
