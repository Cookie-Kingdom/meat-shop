import { actionButton, control, Field } from "@/components/ui/controls";

/* OW 08's filter bar: date range · branch · lot (S7). A plain GET form, so every filter state is
 * a URL the Owner can bookmark and no client JavaScript ships. Sticky at the top and
 * horizontally scrollable in its own container at 360px. */

export type Option = { id: string; label: string };

export function FilterBar({
  action,
  from,
  to,
  branch,
  lot,
  view,
  branches,
  lots,
}: {
  action: string;
  from: string;
  to: string;
  branch: string;
  lot: string;
  view: string;
  branches: Option[];
  lots: Option[];
}) {
  return (
    <form
      method="get"
      action={action}
      className="sticky top-0 z-10 -mx-4 overflow-x-auto border-b border-border bg-background px-4 py-2 md:-mx-6 md:px-6"
    >
      <div className="flex min-w-max items-end gap-2">
        <Field label="ตั้งแต่">
          <input
            type="date"
            name="from"
            defaultValue={from}
            className={control}
          />
        </Field>
        <Field label="ถึง">
          <input type="date" name="to" defaultValue={to} className={control} />
        </Field>
        <Field label="สาขา">
          <select name="branch" defaultValue={branch} className={control}>
            <option value="">ทุกสาขา</option>
            {branches.map((b) => (
              <option key={b.id} value={b.id}>
                {b.label}
              </option>
            ))}
          </select>
        </Field>
        <Field label="ล็อต">
          <select name="lot" defaultValue={lot} className={control}>
            <option value="">ทุกล็อต</option>
            {lots.map((l) => (
              <option key={l.id} value={l.id}>
                {l.label}
              </option>
            ))}
          </select>
        </Field>
        <input type="hidden" name="view" value={view} />
        <button type="submit" className={actionButton}>
          ดูรายงาน
        </button>
      </div>
    </form>
  );
}
