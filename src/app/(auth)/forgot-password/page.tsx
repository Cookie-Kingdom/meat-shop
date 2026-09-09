import Link from "next/link";

import { Button } from "@/components/ui/button";
import { requestPasswordReset } from "@/features/auth/actions";
import { AUTH_ERRORS, type AuthErrorCode } from "@/features/auth/messages";
import { Field } from "@/features/auth/field";

type Search = { error?: string; sent?: string };

export default async function ForgotPasswordPage({
  searchParams,
}: {
  searchParams: Promise<Search>;
}) {
  const { error, sent } = await searchParams;
  const message = AUTH_ERRORS[error as AuthErrorCode] ?? null;

  if (sent) {
    return (
      <div className="flex flex-col gap-4">
        <p className="rounded-sm bg-success-subtle p-2 text-body-sm text-success">
          ส่งลิงก์ตั้งรหัสผ่านใหม่ไปที่อีเมลแล้ว หากไม่พบ กรุณาตรวจในกล่องสแปม
        </p>
        <Link
          href="/login"
          className="text-center text-body-sm text-text-secondary underline hover:text-text-primary"
        >
          กลับไปหน้าเข้าสู่ระบบ
        </Link>
      </div>
    );
  }

  return (
    <form action={requestPasswordReset} className="flex flex-col gap-4">
      <p className="text-body-sm text-text-secondary">
        กรอกอีเมลที่ใช้เข้าระบบ ระบบจะส่งลิงก์สำหรับตั้งรหัสผ่านใหม่ไปให้
      </p>

      <Field
        label="อีเมล"
        name="email"
        type="email"
        autoComplete="email"
        autoFocus
      />

      {message ? (
        <p
          role="alert"
          className="rounded-sm bg-danger-subtle p-2 text-body-sm text-danger"
        >
          {message}
        </p>
      ) : null}

      <Button type="submit" className="h-12">
        ส่งลิงก์
      </Button>

      <Link
        href="/login"
        className="text-center text-body-sm text-text-secondary underline hover:text-text-primary"
      >
        กลับไปหน้าเข้าสู่ระบบ
      </Link>
    </form>
  );
}
