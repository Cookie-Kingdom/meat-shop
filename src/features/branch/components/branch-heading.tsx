import { actionLink, control } from "@/components/ui/controls";
import { thaiDate } from "@/lib/format/date";
import type { Branch } from "../context";

/* "Branch name · date" (LAYOUT-SKELETONS S6), and the BranchSelector when there is a choice.
 *
 * BranchSelector's contract: an L2 with one branch sees PLAIN TEXT, never a disabled dropdown —
 * a disabled control implies branches that exist and are merely unavailable, and RLS means they
 * are not visible at all (ADR-004). With several (PLAN Open Question 2), a GET form picks one. */

export function BranchHeading({
  title,
  branches,
  branch,
  date,
  basePath,
}: {
  title: string;
  branches: Branch[];
  branch: Branch;
  date: string;
  basePath: string;
}) {
  return (
    <div className="flex flex-col gap-2">
      <h1 className="text-h1 text-text-primary">{title}</h1>
      {branches.length > 1 ? (
        <form method="get" action={basePath} className="flex flex-wrap items-center gap-2">
          <select
            name="location"
            defaultValue={branch.id}
            aria-label="สาขา"
            className={control}
          >
            {branches.map((b) => (
              <option key={b.id} value={b.id}>
                {b.name_th}
              </option>
            ))}
          </select>
          <button type="submit" className={actionLink}>
            เปลี่ยนสาขา
          </button>
          <span className="text-body text-text-secondary">· {thaiDate(date)}</span>
        </form>
      ) : (
        <p className="text-body text-text-secondary">
          {branch.name_th} · {thaiDate(date)}
        </p>
      )}
    </div>
  );
}
