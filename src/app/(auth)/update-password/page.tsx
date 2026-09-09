import { Button } from "@/components/ui/button";
import { updatePassword } from "@/features/auth/actions";
import { AUTH_ERRORS, type AuthErrorCode } from "@/features/auth/messages";
import { Field } from "@/features/auth/field";

/* Reached from the emailed link, via /auth/callback which exchanges the code for a
 * session first. Not in the proxy's PUBLIC_PREFIXES on purpose: without that session
 * there is nothing to update, and the proxy sends the visitor to /login instead. */

type Search = { error?: string };

export default async function UpdatePasswordPage({
  searchParams,
}: {
  searchParams: Promise<Search>;
}) {
  const { error } = await searchParams;
  const message = AUTH_ERRORS[error as AuthErrorCode] ?? null;

  return (
    <form action={updatePassword} className="flex flex-col gap-4">
      <p className="text-body-sm text-text-secondary">
        ตั้งรหัสผ่านใหม่ อย่างน้อย 8 ตัวอักษร
      </p>

      <Field
        label="รหัสผ่านใหม่"
        name="password"
        type="password"
        autoComplete="new-password"
        autoFocus
      />
      <Field
        label="ยืนยันรหัสผ่านใหม่"
        name="confirm"
        type="password"
        autoComplete="new-password"
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
        บันทึกรหัสผ่าน
      </Button>
    </form>
  );
}
