import Link from "next/link";

import { actionLink } from "@/components/ui/controls";
import { getReadiness, unsetBlocking } from "@/lib/rpc/setup";

/* The Owner's persistent banner (card ^ref-61, ADR-023). Rendered on every (owner) page by
 * `app/(owner)/template.tsx` while any BLOCK item is unset — the Owner may skip setup, and
 * this is what keeps a skipped item from being forgotten.
 *
 * It names each item AND what it stops, because "3 items unset" tells the Owner nothing about
 * which work is waiting on them. An announcement on the page, never a push (ADR-023).
 *
 * Warning, not danger: nothing is broken and nobody made a mistake — the system is waiting
 * for a number only the Owner has. */

export async function SetupBanner() {
  const { rows, error } = await getReadiness();

  if (error) {
    return (
      <p className="rounded-lg border border-border bg-surface-sunken p-3 text-caption text-text-secondary">
        อ่านสถานะการตั้งค่าไม่สำเร็จ — {error}
      </p>
    );
  }

  const unset = unsetBlocking(rows);
  if (unset.length === 0) return null;

  return (
    <section
      aria-label="ค่าที่ยังไม่ได้ตั้ง"
      className="flex flex-col gap-2 rounded-lg border border-warning bg-warning-subtle p-4"
    >
      <p className="text-label text-text-primary">
        ยังตั้งค่าไม่ครบ {unset.length} รายการ — ระบบไม่เดาค่าให้
        งานที่ต้องใช้ค่าเหล่านี้จะยังบันทึกไม่ได้
      </p>
      <ul className="flex flex-col gap-1 text-body-sm text-text-secondary">
        {unset.map((r) => (
          <li key={r.item_key}>
            <span className="text-text-primary">{r.label_th}</span> —
            ยังใช้ไม่ได้: {r.gates_th}
          </li>
        ))}
      </ul>
      <Link href="/owner/setup" className={actionLink}>
        ไปหน้าตั้งค่าเริ่มต้น →
      </Link>
    </section>
  );
}
