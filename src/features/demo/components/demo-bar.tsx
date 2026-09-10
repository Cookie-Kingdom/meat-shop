import { Button } from "@/components/ui/button";
import { signOut } from "@/features/auth/actions";
import { personaNameByEmail } from "@/features/demo/personas";
import { getViewer } from "@/lib/auth/session";

/* ^ref-65 D6 — on every role page in demo mode, so a demo screen can never pass for
 * production. `เปลี่ยนตำแหน่ง` is the ordinary sign-out, which lands on the picker. The name
 * is the persona table's, the same string the seed writes to profiles.display_name. */

export async function DemoBar() {
  const viewer = await getViewer();
  const name = personaNameByEmail(viewer?.email ?? null) ?? "—";

  return (
    <div className="flex items-center justify-between gap-3 border-b border-warning bg-warning-subtle px-4 py-2">
      <span className="text-body-sm text-text-primary">
        โหมดทดลอง · กำลังใช้เป็น: <strong>{name}</strong>
      </span>
      <form action={signOut}>
        <Button type="submit" variant="outline" className="h-11 px-4">
          เปลี่ยนตำแหน่ง
        </Button>
      </form>
    </div>
  );
}
