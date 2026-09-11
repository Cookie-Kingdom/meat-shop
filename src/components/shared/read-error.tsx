import type { ReactNode } from "react";
import { readErrorDetail, readErrorHint } from "@/lib/read-error";

/* The one read-error notice (^fix-read-error-text). A Thai sentence the person at the screen can
 * act on comes first; PostgREST's own text sits under a fold for whoever fixes it — shown, never
 * swallowed (the rule in `rpc/result.ts`). `title` is the whole first clause ("อ่านข้อมูลล็อตไม่สำเร็จ")
 * because some carry a space-separated English noun. Children go after the hint: a retry link. */
type Raw = string | null | undefined;

export function ReadError({
  title,
  raw,
  children,
}: {
  title: string;
  raw: Raw | Raw[];
  children?: ReactNode;
}) {
  const list = (Array.isArray(raw) ? raw : [raw]).filter(
    (s): s is string => typeof s === "string" && s.length > 0,
  );
  return (
    <div
      role="alert"
      className="rounded-lg border border-danger bg-danger-subtle p-4 text-body text-danger"
    >
      <p>
        {title}: {readErrorHint(list)}
        {children ? <> {children}</> : null}
      </p>
      <details className="mt-2 text-body-sm">
        <summary className="flex min-h-11 cursor-pointer items-center">
          รายละเอียดสำหรับผู้ดูแลระบบ
        </summary>
        <p className="break-words">{readErrorDetail(list)}</p>
      </details>
    </div>
  );
}
