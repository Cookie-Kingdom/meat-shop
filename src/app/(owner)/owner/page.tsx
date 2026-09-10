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
        href="/owner/lots"
        className="text-label text-accent hover:underline"
      >
        OW 03 · ติดตามล็อต →
      </Link>
      <Link
        href="/owner/lots/results"
        className="text-label text-accent hover:underline"
      >
        OW 04 · ผลล็อตและต้นทุน →
      </Link>
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
      <Link
        href="/owner/audit#unlock"
        className="text-label text-accent hover:underline"
      >
        OW 11 · คำขอปลดล็อก →
      </Link>
      <Link
        href="/owner/purchasing"
        className="text-label text-accent hover:underline"
      >
        OW 01 · สั่งซื้อเนื้อ (PO) →
      </Link>
      <Link
        href="/owner/transport"
        className="text-label text-accent hover:underline"
      >
        OW 02 · ขนส่ง →
      </Link>
      <Link href="/owner/returns" className="text-label text-accent hover:underline">
        OW 05 · ต้นทุนและนัดรับขากลับ →
      </Link>
      <Link href="/owner/central" className="text-label text-accent hover:underline">
        OW 06 · สต็อกกลาง →
      </Link>
      <Link href="/owner/allocate" className="text-label text-accent hover:underline">
        OW 07 · จัดสรรสู่สาขา →
      </Link>
    </div>
  );
}
