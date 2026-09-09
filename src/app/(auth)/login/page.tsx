import Link from "next/link";

import { Button } from "@/components/ui/button";
import { signIn } from "@/features/auth/actions";
import { AUTH_ERRORS, type AuthErrorCode } from "@/features/auth/messages";
import { Field } from "@/features/auth/field";

type Search = { error?: string; next?: string };

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<Search>;
}) {
  const { error, next = "/" } = await searchParams;
  const message = AUTH_ERRORS[error as AuthErrorCode] ?? null;

  return (
    <form action={signIn} className="flex flex-col gap-4">
      <input type="hidden" name="next" value={next} />

      <Field
        label="อีเมล"
        name="email"
        type="email"
        autoComplete="email"
        autoFocus
      />
      <Field
        label="รหัสผ่าน"
        name="password"
        type="password"
        autoComplete="current-password"
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
        เข้าสู่ระบบ
      </Button>

      <Link
        href="/forgot-password"
        className="text-center text-body-sm text-text-secondary underline hover:text-text-primary"
      >
        ลืมรหัสผ่าน
      </Link>
    </form>
  );
}
