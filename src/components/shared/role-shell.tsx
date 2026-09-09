import { Button } from "@/components/ui/button";
import { signOut } from "@/features/auth/actions";

/* The frame the three role groups share. Deliberately thin — nav, BranchSelector,
 * DateNavigator and the theme toggle are the app-shell card, not this one. It exists so
 * a signed-in session has a way out that is a POST, not a link. */

export function RoleShell({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <>
      <header className="flex items-center justify-between gap-4 border-b border-border bg-surface px-4 py-3">
        <span className="text-h3 text-text-primary">{title}</span>
        <form action={signOut}>
          <Button type="submit" variant="outline">
            ออกจากระบบ
          </Button>
        </form>
      </header>
      <main className="flex flex-1 flex-col gap-4 p-4 md:p-6">{children}</main>
    </>
  );
}
