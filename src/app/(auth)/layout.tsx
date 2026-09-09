/* (auth) — login and password reset. The one route group reachable without a session;
 * `src/proxy.ts` names its paths in PUBLIC_PREFIXES. */

export default function AuthLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <main className="flex flex-1 items-center justify-center bg-bg p-4">
      <div className="flex w-full max-w-sm flex-col gap-6 rounded-lg border border-border bg-surface p-6">
        <header className="flex flex-col gap-1">
          <h1 className="text-h1 text-text-primary">NerdNuea Stock</h1>
          <p className="text-body-sm text-text-secondary">
            ระบบสต๊อกและต้นทุนเนื้อรมควัน
          </p>
        </header>
        {children}
      </div>
    </main>
  );
}
