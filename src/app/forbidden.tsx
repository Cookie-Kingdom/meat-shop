import Link from "next/link";

/* The 403 `forbidden()` renders. A refusal reads as a refusal — bouncing the user to
 * their own home would make a permissions failure look like navigation (ADR-004). */

export default function Forbidden() {
  return (
    <main className="flex flex-1 flex-col items-center justify-center gap-3 bg-bg p-6 text-center">
      <h1 className="text-h1 text-text-primary">ไม่มีสิทธิ์เข้าถึง</h1>
      <p className="text-body-sm text-text-secondary">
        บัญชีของคุณไม่มีสิทธิ์เปิดหน้านี้ หากคิดว่าผิดพลาด
        กรุณาติดต่อเจ้าของกิจการ
      </p>
      <Link href="/" className="text-body-sm text-accent underline">
        กลับหน้าหลัก
      </Link>
    </main>
  );
}
