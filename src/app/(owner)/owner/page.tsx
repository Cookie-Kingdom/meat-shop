import Link from "next/link";
import { ChevronRight } from "lucide-react";

import { UnsetMarker } from "@/features/setup/components/unset-marker";

/* The Owner's home: every built OW screen as a 56px row, grouped by when the Owner reaches
 * for it (^ref-67). The tab bar carries the daily four; this is AppShell's "เพิ่มเติม" set
 * (DESIGN-CONTRACTS.md). A row is a link and nothing more — the role gate is the (owner)
 * layout, and RLS decides (ADR-004). */

type Row = { href: string; label: string; detail: string; marker?: boolean };

const GROUPS: { title: string; rows: Row[] }[] = [
  {
    title: "งานประจำวัน",
    rows: [
      {
        href: "/owner/dashboard",
        label: "แดชบอร์ด",
        detail: "ยอดขาย กำไรรอบแรก Loss และรายการที่ต้องจัดการ",
      },
      {
        href: "/owner/central",
        label: "สต็อกกลาง",
        detail: "รับของขากลับจากเชียงใหม่เข้าคลัง และยอดที่พร้อมจัดสรร",
      },
      {
        href: "/owner/allocate",
        label: "จัดสรรสู่สาขา",
        detail: "ส่งของจากคลังกลางไปสาขา วันรมควันเก่าที่สุดก่อน",
      },
    ],
  },
  {
    title: "ล็อตและเชียงใหม่",
    rows: [
      {
        href: "/owner/purchasing",
        label: "สั่งซื้อเนื้อ (PO)",
        detail: "ใบสั่งซื้อจาก Foodiva และรอบส่งที่สร้างล็อต",
      },
      {
        href: "/owner/transport",
        label: "ขนส่ง",
        detail: "รอบรถขาไปและขากลับ ของค้างรับ ส่วนต่างตอนรับ",
      },
      {
        href: "/owner/lots",
        label: "ติดตามล็อต",
        detail: "ล็อตที่ยังไม่ปิด และความคืบหน้ารายวันที่เชียงใหม่",
      },
      {
        href: "/owner/lots/results",
        label: "ผลล็อตและต้นทุน",
        detail: "Loss และต้นทุนของล็อตที่ปิดแล้ว",
      },
      {
        href: "/owner/returns",
        label: "ต้นทุนและนัดรับขากลับ",
        detail: "ล็อตที่ปิดแล้ว รอกำหนดวันรถไปรับ",
      },
    ],
  },
  {
    title: "การเงินและการตั้งค่า",
    rows: [
      {
        href: "/owner/expenses",
        label: "ค่าใช้จ่ายและเงินลงทุน",
        detail: "รายจ่ายของเจ้าของ นอกเหนือจากต้นทุนล็อต",
      },
      {
        href: "/owner/setup",
        label: "ตั้งค่าเริ่มต้น",
        detail: "ตัวเลขที่ระบบต้องรู้ก่อนใช้งาน",
        marker: true,
      },
      {
        href: "/owner/config",
        label: "ตั้งค่าระบบ",
        detail: "ราคา เกณฑ์ และค่าอื่นที่มีวันเริ่มใช้",
      },
      {
        href: "/owner/audit",
        label: "ปลดล็อกและประวัติการแก้ไข",
        detail: "คำขอปลดล็อก และใครแก้อะไรเมื่อไร",
      },
    ],
  },
];

export default function OwnerHome() {
  return (
    <div className="flex flex-col gap-6">
      <h1 className="text-h1 text-text-primary">เมนูเจ้าของ</h1>
      <div className="grid gap-6 md:grid-cols-3">
        {GROUPS.map((group) => (
          <section
            key={group.title}
            aria-label={group.title}
            className="flex flex-col gap-2"
          >
            <h2 className="text-h3 text-text-primary">{group.title}</h2>
            {group.rows.map((row) => (
              <Link
                key={row.href}
                href={row.href}
                className="flex min-h-14 items-center gap-3 rounded-lg border border-border bg-surface px-4 py-2 hover:bg-surface-sunken"
              >
                <span className="flex min-w-0 flex-1 flex-col">
                  <span className="text-label text-text-primary">
                    {row.label}
                    {row.marker ? <UnsetMarker /> : null}
                  </span>
                  <span className="text-caption text-text-secondary">
                    {row.detail}
                  </span>
                </span>
                <ChevronRight
                  aria-hidden
                  className="size-5 shrink-0 text-text-muted"
                />
              </Link>
            ))}
          </section>
        ))}
      </div>
    </div>
  );
}
