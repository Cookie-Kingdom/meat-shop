import "server-only";

import { todayBangkok } from "@/lib/format/date";
import { createClient } from "@/lib/supabase/server";

/* Which branch, and which business day, a branch screen is looking at (card ^ref-41).
 *
 * THE BRANCH comes from v_my_branches (view 141): with one row the screen uses it, with several
 * `?location=` picks (PLAN Open Question 2). Scope is the view's WHERE (R34), so a location id
 * typed into the URL that is not the caller's simply is not in the list — the screen falls back
 * to the caller's own branch rather than trusting the parameter.
 *
 * THE DAY defaults to THE BRANCH'S OPEN REPORT'S DATE, else today in Asia/Bangkok. At 01:00 the
 * calendar says Wednesday while Tuesday is still open, and the screen must show Tuesday
 * (ADR-014, D07, UAT-18, TDD TC-41). A date in the future is not a day anyone can work in, so
 * it falls back too.
 */

export type Branch = {
  id: string;
  code: string;
  name_th: string;
  rice_model: "EXTERNAL_COOKED" | "SELF_COOK" | null;
};

export type ReportStatus = "OPEN" | "CLOSED" | "UNLOCKED";

export type DailyReport = {
  id: string;
  location_id: string;
  report_date: string;
  status: ReportStatus;
  shift_started_at: string;
  /** The day's thawed weight. 0 means nothing was thawed, which is a fact. */
  thawed_kg: number;
};

export const REPORT_STATUS_TH: Record<ReportStatus, string> = {
  OPEN: "เปิดอยู่",
  UNLOCKED: "ปลดล็อกให้แก้ไข",
  CLOSED: "ปิดแล้ว",
};

export type BranchDay = {
  supabase: Awaited<ReturnType<typeof createClient>>;
  today: string;
  branches: Branch[];
  branch: Branch | null;
  /** The branch's one OPEN report, whatever its date (daily_reports_one_open). */
  open: DailyReport | null;
  /** The report for `date`, if the day exists. */
  report: DailyReport | null;
  date: string;
  error: string | null;
};

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

export async function loadBranchDay(params: {
  location: string;
  date: string;
}): Promise<BranchDay> {
  const supabase = await createClient();
  const today = todayBangkok();

  const { data: branchRows, error } = await supabase
    .from("v_my_branches")
    .select("id, code, name_th, rice_model")
    .order("code");
  const branches = (branchRows ?? []) as Branch[];
  const branch =
    branches.find((b) => b.id === params.location) ?? branches[0] ?? null;

  if (!branch) {
    return {
      supabase,
      today,
      branches,
      branch: null,
      open: null,
      report: null,
      date: today,
      error: error?.message ?? null,
    };
  }

  const { data: openRows } = await supabase
    .from("v_daily_reports")
    .select("*")
    .eq("location_id", branch.id)
    .eq("status", "OPEN")
    .limit(1);
  const open = ((openRows ?? [])[0] ?? null) as DailyReport | null;

  const asked = ISO_DATE.test(params.date) && params.date <= today;
  const date = asked ? params.date : (open?.report_date ?? today);

  const { data: dayRows } = await supabase
    .from("v_daily_reports")
    .select("*")
    .eq("location_id", branch.id)
    .eq("report_date", date)
    .limit(1);
  const report = ((dayRows ?? [])[0] ?? null) as DailyReport | null;

  return { supabase, today, branches, branch, open, report, date, error: null };
}
