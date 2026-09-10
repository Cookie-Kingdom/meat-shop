/* The RPC error split every typed wrapper shares. Moved out of `config.ts` by card ^ref-41
 * (PLAN-thaw.md T8) so a second wrapper file — `branch.ts` — does not re-derive the `CODE:`
 * split. A move with no behaviour change for the config setters.
 *
 * AN UNMAPPED ERROR IS SHOWN VERBATIM, NEVER SWALLOWED. A silent catch is how a refused write
 * reads as a saved one.
 */

export type RpcFailure = { ok: false; code: string; message: string };

export type RpcResult = { ok: true } | RpcFailure;

/** A Thai sentence per named raise — or a function that builds one from the raw
 * `CODE: detail` message, when the detail (a date, a balance) is what the person has to act
 * on. */
export type Messages = Record<string, string | ((raw: string) => string)>;

/** Postgres reports our raises as `CODE: detail`. Split the code off so the screen can show
 * the Thai sentence for the ones we named, and the raw message for the ones we did not. */
export function toFailure(
  error: { message: string },
  messages: Messages,
): RpcFailure {
  const code = error.message.match(/^([A-Z_]+):/)?.[1] ?? "";
  const known = messages[code];
  const message =
    typeof known === "function" ? known(error.message) : (known ?? error.message);
  return { ok: false, code, message };
}

export function toResult(
  error: { message: string } | null,
  messages: Messages,
): RpcResult {
  return error ? toFailure(error, messages) : { ok: true };
}
