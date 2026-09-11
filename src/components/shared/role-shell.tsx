import { Button } from "@/components/ui/button";
import { NavTabs, type NavTab } from "@/components/shared/nav-tabs";
import { signOut } from "@/features/auth/actions";
import { DemoBar } from "@/features/demo/components/demo-bar";
import { isDemoMode } from "@/features/demo/personas";
import { cn } from "@/lib/utils";

/* The frame the three role groups share: one top bar, the role's tab set, the page. In demo
 * mode the demo bar IS the top bar — its `เปลี่ยนตำแหน่ง` is the sign-out, so a second
 * `ออกจากระบบ` would be the same button twice and 56px the phone does not have (^ref-67).
 *
 * `tabs` is the AppShell set for the role (DESIGN-CONTRACTS.md); a group with no tab set
 * (L3, whose nav is the lot hub) passes none and gets no bar. The bar is fixed below `lg:`,
 * so `main` keeps room for it. */

export function RoleShell({
  title,
  tabs = [],
  children,
}: {
  title: string;
  tabs?: NavTab[];
  children: React.ReactNode;
}) {
  const demo = isDemoMode();
  const hasTabs = tabs.length > 0;

  return (
    <>
      {demo ? (
        <DemoBar />
      ) : (
        <header className="flex min-h-14 items-center justify-between gap-4 border-b border-border bg-surface px-4 py-1">
          <span className="text-h3 text-text-primary">{title}</span>
          <form action={signOut}>
            <Button type="submit" variant="outline">
              ออกจากระบบ
            </Button>
          </form>
        </header>
      )}
      {hasTabs ? <NavTabs tabs={tabs} /> : null}
      <main
        className={cn(
          "flex flex-1 flex-col gap-4 p-4 md:p-6",
          hasTabs && "pb-20 md:pb-20 lg:pb-6",
        )}
      >
        {children}
      </main>
    </>
  );
}
