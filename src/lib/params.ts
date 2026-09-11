/** The first value of a repeated search param, "" when absent — one shape for a query
 * builder and for a form's `defaultValue`. */
export function one(value: string | string[] | undefined): string {
  return (Array.isArray(value) ? value[0] : value) ?? "";
}

/** A submitted form field, trimmed, "" when absent. */
export function str(form: FormData, name: string): string {
  return (form.get(name) ?? "").toString().trim();
}

/* The branch screens' write path (^ref-41, moved here by ^ref-46 so BR 07–09 and BR 03/08 do
 * not each keep a copy). The outcome rides back in the URL, typed values included. */

/** The posted `back` path, only if it stays under `prefix` — never an open redirect. */
export function backTo(form: FormData, prefix: string): string {
  const back = str(form, "back");
  return back.startsWith(prefix) ? back : prefix;
}

/** `path` with `set` applied to its query: a value sets, null or "" removes. */
export function withParams(
  path: string,
  set: Record<string, string | null>,
): string {
  const [pathname, query = ""] = path.split("?");
  const q = new URLSearchParams(query);
  for (const [k, v] of Object.entries(set)) {
    if (v === null || v === "") q.delete(k);
    else q.set(k, v);
  }
  const s = q.toString();
  return s ? `${pathname}?${s}` : pathname;
}

/** A decimal someone typed, or null for anything that is not a finite number. The database
 * validates the range and the 2 decimals; this only keeps NaN off the wire. */
export function num(value: string): number | null {
  if (value === "") return null;
  const n = Number(value.replace(/,/g, ""));
  return Number.isFinite(n) ? n : null;
}

/** A whole count. A decimal is refused here, at the input layer (BR21, CountField). */
export function whole(value: string): number | null {
  return /^\d+$/.test(value) ? Number(value) : null;
}
