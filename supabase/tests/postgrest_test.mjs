// Card ^ref-71 — IT-H01…H07 over HTTP, against the PostgREST that postgrest_test.sh starts.
// That script sets PGRST_URL, PGRST_JWT_SECRET and PG_CONTAINER; this file is not run alone.
//
// Node 24 stdlib only. toFailure is the real one from src/lib/rpc/result.ts: Node strips its
// types, and the file imports nothing. Reads that are not under test (ids, row counts) go
// straight to the database as postgres, so they cannot be skewed by the RLS being tested.

import { createHmac, randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { toFailure } from "../../src/lib/rpc/result.ts";

const { PGRST_URL: BASE, PGRST_JWT_SECRET: SECRET, PG_CONTAINER: DB } = process.env;

const sql = (q) =>
  execFileSync("docker", ["exec", DB, "psql", "-U", "postgres", "-d", "meatshop", "-Atqc", q], {
    encoding: "utf8",
  }).trim();

// HS256, the shape Supabase Auth signs: the subject, and the role PostgREST switches to.
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
function jwt(sub) {
  const exp = Math.floor(Date.now() / 1000) + 600;
  const unsigned = `${b64({ alg: "HS256", typ: "JWT" })}.${b64({ sub, role: "authenticated", exp })}`;
  return `${unsigned}.${createHmac("sha256", SECRET).update(unsigned).digest("base64url")}`;
}

// No `as` is an anon request: no Authorization header at all, the way a logged-out browser
// calls. PGRST_DB_ANON_ROLE makes it `anon`.
async function call(method, path, { as, body } = {}) {
  const headers = { "Content-Type": "application/json" };
  if (as) headers.Authorization = `Bearer ${jwt(as)}`;
  const res = await fetch(BASE + path, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : null };
}

let failures = 0;
function check(id, ok, detail) {
  if (ok) {
    console.log(`PASS  ${id}`);
  } else {
    failures++;
    console.log(`FAIL  ${id}  ${detail}`);
  }
}
const refused = (r) => r.status === 401 || r.status === 403;
const show = (r) => `HTTP ${r.status} ${JSON.stringify(r.body)}`.slice(0, 300);

// Readiness, polled: PostgREST answers 503 until its schema cache has loaded.
for (let i = 0; ; i++) {
  try {
    if ((await fetch(BASE + "/")).status !== 503) break;
  } catch {}
  if (i === 60) {
    console.log("FAIL  postgrest_test.sh  PostgREST never answered within 30 s");
    process.exit(1);
  }
  await new Promise((r) => setTimeout(r, 500));
}

// --------------------------------------------------------------------------- the fixture's ids
const user = (k) => sql(`select id from auth.users where email = 'demo-${k}@demo.local'`);
const OWNER = user("owner");
const CHEF = user("chef");
const SLD_ADMIN = user("salaeng");
const loc = (code) => sql(`select id from locations where code = '${code}'`);
const SLD = loc("SLD");
const MNB = loc("MNB");
const reportAt = (l) => sql(`select id from daily_reports where location_id = '${l}'`);
const TODAY = sql("select current_date");
const SUPPLIER = sql("select id from suppliers limit 1");
const count = (table) => Number(sql(`select count(*) from ${table}`));
const aLine = [{ product_code: "MEAT_BOX", qty: 1 }];

// ----------------------------------------------------------- IT-H01: anon executes no write
// Valid argument names, so a 404 would mean PostgREST never found the function, which is a
// different failure from being refused it (ADR-002, ^ref-64).
{
  const pos = count("purchase_orders");
  const writes = {
    fn_create_po: {
      p_idempotency_key: randomUUID(), p_supplier_id: SUPPLIER,
      p_event_date: TODAY, p_ordered_weight_kg: 10,
    },
    fn_record_sales: {
      p_idempotency_key: randomUUID(), p_daily_report_id: reportAt(SLD), p_lines: aLine,
    },
    fn_close_lot: { p_idempotency_key: randomUUID(), p_lot_id: sql("select id from lots limit 1") },
  };
  for (const [fn, args] of Object.entries(writes)) {
    const r = await call("POST", `/rpc/${fn}`, { body: args });
    check(`IT-H01 anon POST /rpc/${fn} is refused`, refused(r), show(r));
  }
  check("IT-H01 anon wrote no purchase order", count("purchase_orders") === pos, "row count moved");
}

// ------------------------------------------------ IT-H02: stock_ledger takes no direct write
// ADR-003: corrections are a reversal plus a replacement, through fn_*, never a PATCH.
{
  const rows = count("stock_ledger");
  const own = sql(`select id from stock_ledger where location_id = '${SLD}' limit 1`);
  const attempts = [
    ["POST", "/stock_ledger", {
      item_type: "SMOKED_MEAT", location_id: SLD, stock_state: "READY",
      movement_type: "OPENING", qty_delta: 1,
    }],
    ["PATCH", `/stock_ledger?id=eq.${own}`, { qty_delta: 0 }],
    ["DELETE", `/stock_ledger?id=eq.${own}`, undefined],
  ];
  for (const [method, path, body] of attempts) {
    const r = await call(method, path, { as: SLD_ADMIN, body });
    check(`IT-H02 L2 ${method} /stock_ledger is refused`, refused(r), show(r));
  }
  const sum = sql(`select qty_delta from stock_ledger where id = '${own}'`);
  check("IT-H02 the ledger is unchanged", count("stock_ledger") === rows && sum === "5.00",
    `${count("stock_ledger")} rows (was ${rows}), own row qty ${sum}`);
}

// ------------------------------------------ IT-H03: L2 of branch A reads none of B's rows
// The Owner's read is the control: B has rows, so "none of B's" is not true by emptiness.
for (const view of ["v_stock_balance", "v_daily_reports"]) {
  const mine = await call("GET", `/${view}?select=location_id`, { as: SLD_ADMIN });
  const all = await call("GET", `/${view}?select=location_id`, { as: OWNER });
  const at = (r, l) => Array.isArray(r.body) && r.body.some((x) => x.location_id === l);
  check(`IT-H03 L2 ศาลาแดง reads only its own ${view}`,
    mine.status === 200 && at(mine, SLD) && mine.body.every((x) => x.location_id === SLD),
    show(mine));
  check(`IT-H03 control: the Owner reads มีนบุรี in ${view}`, at(all, MNB), show(all));
}

// ------------------------------------------------ IT-H04: L3 gets no price and no yield
// Every view with a column whose NAME says price, cost, yield or loss: cm_screens_test.sql
// TC-56a's sweep, run over HTTP here. Refused or empty both pass; a row fails (BR15, R20).
// One column is exempt by name: variance_pct is received against dispatched WEIGHT (ADR-019),
// and v_transport_variance shows it to L3 for their own lots on purpose (080's header). It
// matched `pct` and went red on this file's first run. Exempting the column, not the view,
// keeps a real `_thb` column added there later inside the sweep.
{
  const priced = sql(`select string_agg(distinct c.table_name, ',')
                        from information_schema.columns c
                        join pg_views v on v.schemaname = c.table_schema and v.viewname = c.table_name
                       where c.table_schema = 'public'
                         and c.column_name ~ '(_thb$|price|cost|yield|loss|fee|freight|margin|profit|pct)'
                         and c.column_name <> 'variance_pct'`).split(",");
  check("IT-H04 the sweep found v_lot_cost and v_lot_yield",
    priced.includes("v_lot_cost") && priced.includes("v_lot_yield"), priced.join(","));
  const leaks = [];
  for (const view of priced) {
    const r = await call("GET", `/${view}`, { as: CHEF });
    if (!(refused(r) || (r.status === 200 && r.body.length === 0))) leaks.push(`${view}: ${show(r)}`);
  }
  check(`IT-H04 L3 reads no row from any of ${priced.length} priced views`, leaks.length === 0,
    leaks.join(" | "));
  for (const view of ["v_lot_cost", "v_lot_yield"]) {
    const r = await call("GET", `/${view}`, { as: OWNER });
    check(`IT-H04 control: the Owner reads ${view}`, r.status === 200 && r.body.length > 0, show(r));
  }
}

// ------------------------------------------- IT-H05: the real toFailure splits the code
// sales_test.sql TC-16 asserts FORBIDDEN_LOCATION for right role, wrong branch.
{
  const r = await call("POST", "/rpc/fn_record_sales", {
    as: SLD_ADMIN,
    body: { p_idempotency_key: randomUUID(), p_daily_report_id: reportAt(MNB), p_lines: aLine },
  });
  const failure = toFailure(r.body ?? { message: "" }, {});
  check("IT-H05 L2 ศาลาแดง selling on มีนบุรี's report is FORBIDDEN_LOCATION",
    r.status >= 400 && r.status < 500 && failure.code === "FORBIDDEN_LOCATION",
    `${show(r)} -> code "${failure.code}"`);
}

// ---------------------------------------------- IT-H06: a replayed key returns the first id
// The retry after a dropped response (ADR-005). On an existing lot: the lot-code path
// inserts a lot row before the ledger's replay check, which is not what this case is about.
{
  const rows = count("stock_ledger");
  const lot = sql("select id from lots where lot_code = 'OPEN-SLD'");
  const args = {
    p_idempotency_key: randomUUID(), p_item_type: "SMOKED_MEAT", p_location_id: SLD,
    p_qty: 2, p_business_date: TODAY, p_lot_id: lot,
    p_smoke_date: sql(`select smoke_date from smoke_date_groups where lot_id = '${lot}'`),
  };
  const first = await call("POST", "/rpc/fn_record_opening_balance", { as: SLD_ADMIN, body: args });
  const again = await call("POST", "/rpc/fn_record_opening_balance", { as: SLD_ADMIN, body: args });
  check("IT-H06 the same key twice returns the same id",
    first.status === 200 && again.status === 200 && typeof first.body === "string" &&
      first.body === again.body,
    `${show(first)} / ${show(again)}`);
  check("IT-H06 and posts one ledger row", count("stock_ledger") === rows + 1,
    `${count("stock_ledger") - rows} rows`);
}

// ------------------------------------------ IT-H07: a JSON float does not round on the way in
// 10.005 as a JSON number, not a string. If anything between the body and `numeric` went
// through a double, it would arrive as 10.00 or 10.01 and be stored (^fix-numeric-scale).
{
  const pos = count("purchase_orders");
  const r = await call("POST", "/rpc/fn_create_po", {
    as: OWNER,
    body: {
      p_idempotency_key: randomUUID(), p_supplier_id: SUPPLIER,
      p_event_date: TODAY, p_ordered_weight_kg: 10.005,
    },
  });
  check("IT-H07 10.005 kg raises TOO_MANY_DECIMALS",
    r.status === 400 && toFailure(r.body, {}).code === "TOO_MANY_DECIMALS" &&
      count("purchase_orders") === pos,
    show(r));
}

console.log(failures ? `${failures} failing` : "PASS  postgrest_test.sh  (IT-H01…H07 over HTTP)");
process.exit(failures ? 1 : 0);
