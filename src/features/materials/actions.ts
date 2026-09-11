"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";

import { hundredthsToDecimal, toHundredths } from "@/lib/format/number";
import { backTo, str, whole, withParams } from "@/lib/params";
import {
  recordBranchExpense,
  recordPhysicalCount,
  recordRice,
  type CountLine,
  type RiceFigures,
} from "@/lib/rpc/materials";

/* BR 03 / BR 08 / BR 07-expense write path (card ^ref-52, PLAN-material-screens.md T4).
 *
 * THE KEYS ARE NOT MINTED HERE. Each arrives as a hidden input the server component rendered once
 * for the page view, so a double tap is a replay (R4). On a refusal the typed values ride back in
 * the URL; BR 08's two keys ride back too, because the retry must reuse them (Finding 2).
 *
 * Weights and money are refused past two decimals rather than rounded (toHundredths): the
 * columns are numeric(12,2) and would round a third decimal away silently. Counts are whole
 * (BR21). Both are checked again by the functions. */

const RICE_FIELDS = [
  "cooked_received_kg",
  "raw_purchased_kg",
  "cooked_today_kg",
  "raw_remaining_kg",
  "cooked_remaining_kg",
] as const;

const RICE_BAD = "กรอกน้ำหนักข้าวเป็นตัวเลข ทศนิยมไม่เกิน 2 ตำแหน่ง";

/** The rice weights typed on this form. Only typed ones are sent: an absent field keeps the
 * row's value (fn_record_rice's merge). */
function riceFigures(form: FormData, keep: Record<string, string>) {
  const figures: RiceFigures = {};
  let bad = false;
  for (const name of RICE_FIELDS) {
    const raw = str(form, name);
    if (raw === "") continue;
    keep[name] = raw;
    const h = toHundredths(raw);
    if (h === null) bad = true;
    else figures[name] = Number(hundredthsToDecimal(h));
  }
  return { figures, bad };
}

export async function submitRice(form: FormData) {
  const to = backTo(form, "/branch");
  const keep: Record<string, string> = {};
  const { figures, bad } = riceFigures(form, keep);
  if (bad) redirect(withParams(to, { ...keep, err: RICE_BAD }));
  if (Object.keys(figures).length === 0) {
    redirect(withParams(to, { err: "ยังไม่ได้กรอกน้ำหนักข้าว — กรอกอย่างน้อยหนึ่งช่อง" }));
  }

  const result = await recordRice({
    idempotencyKey: str(form, "idempotency_key"),
    dailyReportId: str(form, "daily_report_id"),
    figures,
  });
  revalidatePath("/branch", "layout");
  redirect(withParams(to, result.ok ? { saved: "rice" } : { ...keep, err: result.message }));
}

/** BR 08: the count first, then the rice, each under its own page-view key (Finding 2). A count
 * saved and a rice refused returns with count_saved=1, the counts read-only, and the same keys:
 * the resubmit replays the count (writes nothing) and retries the rice. */
export async function submitCount(form: FormData) {
  const to = backTo(form, "/branch");
  const countKey = str(form, "count_key");
  const riceKey = str(form, "rice_key");
  const dailyReportId = str(form, "daily_report_id");
  const keep: Record<string, string> = { count_key: countKey, rice_key: riceKey };
  if (str(form, "count_saved") === "1") keep.count_saved = "1";

  const counts: CountLine[] = [];
  let bad: string | null = null;
  for (const [name, raw] of form.entries()) {
    const value = raw.toString().trim();
    const isPackaging = name.startsWith("pkg:");
    if ((!isPackaging && name !== "chilli") || value === "") continue; // empty = not counted
    keep[name] = value;
    const qty = whole(value);
    if (qty === null) {
      bad ??= "วัสดุและน้ำพริกนับเป็นจำนวนเต็ม";
      continue;
    }
    counts.push(
      isPackaging
        ? { item_type: "PACKAGING", packaging_item_id: name.slice(4), counted_qty: qty }
        : { item_type: "CHILLI_PASTE", counted_qty: qty },
    );
  }
  const rice = riceFigures(form, keep);
  if (rice.bad) bad ??= RICE_BAD;
  if (bad) redirect(withParams(to, { ...keep, err: bad }));

  const hasRice = Object.keys(rice.figures).length > 0;
  if (counts.length === 0 && !hasRice) {
    redirect(withParams(to, { ...keep, err: "ยังไม่ได้กรอกยอดนับ — กรอกอย่างน้อยหนึ่งรายการ" }));
  }

  if (counts.length > 0) {
    const counted = await recordPhysicalCount({ idempotencyKey: countKey, dailyReportId, counts });
    if (!counted.ok) {
      revalidatePath("/branch", "layout");
      redirect(withParams(to, { ...keep, err: counted.message }));
    }
  }
  if (hasRice) {
    const riced = await recordRice({ idempotencyKey: riceKey, dailyReportId, figures: rice.figures });
    if (!riced.ok) {
      revalidatePath("/branch", "layout");
      redirect(
        withParams(to, {
          ...keep,
          count_saved: counts.length > 0 ? "1" : null,
          err: riced.message,
        }),
      );
    }
  }
  revalidatePath("/branch", "layout");
  redirect(withParams(to, { saved: "count" }));
}

/** BR 07's expense: one row per submit. The category is the picker's CODE (Finding 8); an empty
 * payer is the function's PAID_BY_REQUIRED to refuse, not the browser's. */
export async function submitExpense(form: FormData) {
  const to = backTo(form, "/branch");
  const category = str(form, "exp_category");
  const amountRaw = str(form, "exp_amount");
  const paidBy = str(form, "exp_paid_by");
  const detail = str(form, "exp_detail");
  const keep = {
    exp_category: category,
    exp_amount: amountRaw,
    exp_paid_by: paidBy,
    exp_detail: detail,
  };

  const h = toHundredths(amountRaw);
  if (h === null) {
    redirect(
      withParams(to, { ...keep, err: "กรอกจำนวนเงินเป็นตัวเลข ทศนิยมไม่เกิน 2 ตำแหน่ง" }),
    );
  }

  const result = await recordBranchExpense({
    idempotencyKey: str(form, "idempotency_key"),
    dailyReportId: str(form, "daily_report_id"),
    category,
    amountThb: Number(hundredthsToDecimal(h)),
    paidByPerson: paidBy,
    detail: detail || null,
  });
  revalidatePath("/branch", "layout");
  redirect(withParams(to, result.ok ? { saved: "expense" } : { ...keep, err: result.message }));
}
