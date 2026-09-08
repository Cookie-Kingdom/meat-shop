/* Placeholder home page. Replaced by the real shell when the route groups land
 * (`(auth)` / `(owner)` / `(cm)` / `(branch)`). It exists now only so the token
 * layer is visible in a browser. */

const states = [
  { label: "ปกติ", className: "bg-success-subtle text-success" },
  { label: "ใกล้หมด", className: "bg-warning-subtle text-warning" },
  { label: "เกินเกณฑ์", className: "bg-danger-subtle text-danger" },
  { label: "ล็อกแล้ว", className: "bg-locked-subtle text-locked" },
  { label: "ยังไม่ได้ตั้งค่า", className: "bg-surface-sunken text-text-muted" },
];

export default function Home() {
  return (
    <main className="flex flex-1 flex-col gap-8 p-4 md:p-6">
      <header className="flex flex-col gap-2">
        <h1 className="text-h1 text-text-primary">NerdNuea Stock</h1>
        <p className="text-body-sm text-text-secondary">
          ระบบสต๊อกและต้นทุนเนื้อรมควัน — ยังไม่มีหน้าจอใช้งานจริง
        </p>
      </header>

      <section className="flex flex-col gap-1 rounded-lg border border-border bg-surface p-6">
        <span className="text-label text-text-secondary">น้ำหนักคงเหลือ</span>
        <span className="text-num-xl text-text-primary tabular-nums">
          128.50
          <span className="ml-1 text-caption text-text-secondary">กก.</span>
        </span>
      </section>

      <section className="flex flex-wrap gap-2">
        {states.map((state) => (
          <span
            key={state.label}
            className={`rounded-sm px-2 py-1 text-caption ${state.className}`}
          >
            {state.label}
          </span>
        ))}
      </section>
    </main>
  );
}
