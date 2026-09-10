import { getReadiness, unsetBlocking } from "@/lib/rpc/setup";

/* ADR-023's marker at the point of entry (card ^ref-61): a dot and a count beside the nav link
 * that leads to the unset items, so the Owner reaches the gap by following the highlight
 * rather than by remembering the banner. Renders nothing once every BLOCK item is set. */

export async function UnsetMarker() {
  const { rows } = await getReadiness();
  const n = unsetBlocking(rows).length;
  if (n === 0) return null;

  return (
    <span className="ml-2 inline-flex items-center gap-1 text-caption text-warning">
      <span aria-hidden className="size-2 rounded-full bg-warning" />
      ยังไม่ครบ {n}
    </span>
  );
}
