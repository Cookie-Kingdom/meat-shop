import { expect, test } from "@playwright/test";

import { enterAs, openDay, sql } from "./helpers";

/* IT-E05 — a double tap on BR 05's save is one thaw. The page renders one idempotency key per
 * view (features/branch/actions.ts), so the second submit is a replay (ADR-005). The disabled
 * button is decoration, not the guard, so both submits are fired before it can disable and the
 * test checks that both reached the server. At มีนบุรี, so it shares no day with IT-E03. */

test("IT-E05 two submits of one thaw form write one thaw_records row", async ({ page }) => {
  await enterAs(page, "minburi");
  await openDay(page);

  await page.goto("/branch/thaw");
  await page.getByLabel("น้ำหนักที่ละลายจริง").fill("1.00");

  let posts = 0;
  page.on("request", (r) => {
    if (r.method() === "POST" && r.headers()["next-action"]) posts++;
  });
  await page
    .locator("form")
    .filter({ has: page.getByLabel("น้ำหนักที่ละลายจริง") })
    .evaluate((form: HTMLFormElement) => {
      form.requestSubmit();
      form.requestSubmit();
    });
  await expect(page.getByText(/ละลาย 1 กก\. จากล็อต OPEN-MNB/)).toBeVisible();

  expect(posts, "both submits reached the server").toBe(2);
  expect(
    sql(`select count(*) from thaw_records t
           join daily_reports d on d.id = t.daily_report_id
           join locations l on l.id = d.location_id
          where l.code = 'MNB'`),
  ).toBe("1");
});
