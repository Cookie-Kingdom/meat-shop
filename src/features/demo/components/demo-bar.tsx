import { Button } from "@/components/ui/button";
import { signOut } from "@/features/auth/actions";
import { personaNameByEmail } from "@/features/demo/personas";
import { getViewer } from "@/lib/auth/session";

/* ^ref-65 D6 — on every role page in demo mode, so a demo screen can never pass for
 * production. `เปลี่ยนตำแหน่ง` is the ordinary sign-out, which lands on the picker. The name
 * is the persona table's, the same string the seed writes to profiles.display_name.
 *
 * One line, 48px: it is the top bar in demo mode (RoleShell), so it pays the header's rent. */

export async function DemoBar() {
  const viewer = await getViewer();
  const name = personaNameByEmail(viewer?.email ?? null) ?? "—";

  return (
    <div className="flex min-h-12 items-center justify-between gap-2 border-b border-warning bg-warning-subtle px-3 py-0.5">
      <span className="truncate text-body-sm text-text-primary">
        โหมดทดลอง · <strong>{name}</strong>
      </span>
      <form action={signOut} className="shrink-0">
        <Button type="submit" variant="outline" className="px-3">
          เปลี่ยนตำแหน่ง
        </Button>
      </form>
    </div>
  );
}
