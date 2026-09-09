import Link from "next/link";

/* ponytail: placeholder. It proves the group renders for its role and 403s for every
 * other one. The real OW 01–11 screens arrive with the cards that own their data.
 *
 * The link below is the only way into /owner/audit until the app-shell nav card lands —
 * and a nav item is not the enforcement anyway (^ref-09 acceptance, ADR-004). */

export default function OwnerHome() {
  return (
    <div className="flex flex-col gap-4">
      <p className="text-body text-text-secondary">
        OW 01–11 — ยังไม่มีหน้าจอใช้งานจริง
      </p>
      <Link
        href="/owner/audit"
        className="text-label text-accent hover:underline"
      >
        OW 11 · ประวัติการแก้ไข →
      </Link>
    </div>
  );
}
