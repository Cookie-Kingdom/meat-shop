import { missingTh } from "@/features/reports/labels";

/* IncompleteDataNotice — REPLACES the number, never sits beside it (DESIGN-CONTRACTS, F13:
 * "the report says the data is incomplete rather than presenting a profit figure as
 * complete"; v0.2:455). It lists what is missing so the Owner knows what to go and set. */

export function IncompleteDataNotice({
  figure,
  missing,
}: {
  figure: string;
  missing: string[];
}) {
  return (
    <div role="status" className="flex flex-col gap-1">
      <p className="text-label text-warning">{figure} — ข้อมูลยังไม่ครบ</p>
      {missing.length > 0 ? (
        <ul className="list-disc pl-5 text-caption text-text-secondary">
          {missing.map((code) => (
            <li key={code}>{missingTh(code)}</li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}
