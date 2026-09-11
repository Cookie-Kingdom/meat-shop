import { getViewer } from "@/lib/auth/session";
import { getReadiness, waitingFor } from "@/lib/rpc/setup";

/* The L2 / L3 wait-for-Owner notice (card ^ref-61, ADR-023). Rendered on every (branch) and
 * (cm) page by that group's `template.tsx`.
 *
 * THE REGISTER IS A CONNECTIVITY NOTICE — the same as "ไม่มีสัญญาณอินเตอร์เน็ต": this is a
 * condition, it is not your fault, it is not yours to fix, and here is what it is waiting on.
 * So: neutral surface, no red, no form, no link to setup, and never a value — the view carries
 * none (R20). It lists only the items that stop something THIS role does (`affects_roles`).
 *
 * The notice tells; it does not enforce. The entry points it names stay refused by the RPC's
 * own CONFIG_NOT_SET (R35), and each screen greys its button out with `waitingFeatures()`. */

export async function WaitingNotice() {
  const viewer = await getViewer();
  const role = viewer?.role;
  // The Owner has the setup banner in (owner); on a branch or CM page they need no notice.
  if (!role || role === "L1_OWNER") return null;

  const { rows, error } = await getReadiness();

  if (error) {
    return (
      <p
        role="status"
        className="rounded-lg border border-border bg-surface-sunken p-3 text-caption text-text-secondary"
      >
        ตรวจสถานะการตั้งค่าไม่สำเร็จ — ถ้าบันทึกไม่ได้ ให้แจ้งเจ้าของร้าน
      </p>
    );
  }

  const waiting = waitingFor(rows, role);
  if (waiting.length === 0) return null;

  return (
    <section
      role="status"
      aria-label="รอเจ้าของร้านตั้งค่า"
      className="flex flex-col gap-2 rounded-lg border border-border bg-surface-sunken p-4"
    >
      <p className="text-label text-text-primary">รอเจ้าของร้านตั้งค่า</p>
      <ul className="flex flex-col gap-1 text-body-sm text-text-secondary">
        {waiting.map((r) => (
          <li key={r.item_key}>
            <span className="text-text-primary">{r.label_th}</span> —
            ยังใช้ไม่ได้: {r.gates_th}
          </li>
        ))}
      </ul>
      <p className="text-caption text-text-muted">
        ไม่ใช่สิ่งที่คุณต้องแก้ เมื่อเจ้าของร้านตั้งค่าแล้ว
        หน้าจอที่เกี่ยวข้องจะใช้ได้ทันที
      </p>
    </section>
  );
}
