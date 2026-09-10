import Link from "next/link";

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
      <Link
        href="/owner/audit"
        className="text-label text-accent hover:underline"
      >
        OW 11 · ประวัติการแก้ไข →
      </Link>
    </div>
  );
}
