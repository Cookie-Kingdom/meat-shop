/** The first value of a repeated search param, "" when absent — one shape for a query
 * builder and for a form's `defaultValue`. */
export function one(value: string | string[] | undefined): string {
  return (Array.isArray(value) ? value[0] : value) ?? "";
}

/** A submitted form field, trimmed, "" when absent. */
export function str(form: FormData, name: string): string {
  return (form.get(name) ?? "").toString().trim();
}
