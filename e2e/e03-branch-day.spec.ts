import { expect, test } from "@playwright/test";

import { enterAs, openDay } from "./helpers";

/* IT-E03 — one branch day at ศาลาแดง through its screens: open, thaw, 12 packs, waste 0.60, the
 * BR 08 counts the close needs, close; then one more edit. What SQL cannot see: each server
 * action's key and its error mapping, end to end.
 *
 * The seed's pack weight is 0.50 kg, so 6.60 kg thawed = 12 × 0.50 sold + 0.60 wasted, and the
 * Diff is 0.00. The branch holds 10.00 kg of opening meat (up.sh), so 3.40 kg stays frozen for
 * the edit after the close. */

test("IT-E03 ศาลาแดง closes a reconciled day, and a later edit reads REPORT_CLOSED in Thai", async ({
  page,
}) => {
  await enterAs(page, "salaeng");

  await openDay(page); // BR 01

  // BR 05
  await page.goto("/branch/thaw");
  await page.getByLabel("น้ำหนักที่ละลายจริง").fill("6.60");
  await page.getByRole("button", { name: "บันทึกการละลาย" }).click();
  await expect(page.getByText(/ละลาย 6\.6 กก\. จากล็อต OPEN-SLD/)).toBeVisible();

  // BR 07: sales, then waste
  await page.goto("/branch/close");
  await page.getByLabel("กล่องปกติ").fill("12");
  await page.getByRole("button", { name: "บันทึกยอดขาย" }).click();
  await expect(page.getByText("บันทึกยอดขายแล้ว")).toBeVisible();
  await page.getByLabel("น้ำหนักที่ทิ้งจริง").fill("0.60");
  await page.getByLabel("เหตุผล").fill("เหลือปลายวัน");
  await page.getByRole("button", { name: "บันทึก Waste" }).click();
  await expect(page.getByText("บันทึก Waste แล้ว")).toBeVisible();

  // BR 08: every active material, and ศาลาแดง cooks its own rice, so the evening rice too.
  await page.goto("/branch/count");
  const materials = page.locator('input[name^="pkg:"]');
  for (let i = 0; i < (await materials.count()); i++) await materials.nth(i).fill("50");
  await page.getByLabel("ข้าวสุกคงเหลือ").fill("1.00");
  await page.getByLabel("ข้าวดิบคงเหลือ").fill("2.00");
  await page.getByRole("button", { name: "บันทึกยอดนับ" }).click();
  await expect(page.getByText("บันทึกยอดนับแล้ว")).toBeVisible();

  // BR 09
  await page.goto("/branch/close/confirm");
  const diff = page.locator("dt", { hasText: /^Diff$/ }).locator("xpath=following-sibling::dd");
  await expect(diff).toHaveText(/^0\.00 กก\./);
  await page.getByRole("link", { name: /^ปิดวัน \d/ }).click();
  await page.getByRole("button", { name: "ยืนยันปิดวัน", exact: true }).click();
  await expect(page.getByText("ปิดวันแล้ว", { exact: true })).toBeVisible();

  // One more edit on the closed day: refused, in Thai, and the raw code never reaches the screen.
  await page.goto("/branch/thaw");
  await page.getByLabel("น้ำหนักที่ละลายจริง").fill("0.50");
  await page.getByRole("button", { name: "บันทึกการละลาย" }).click();
  await expect(page.getByText(/ปิดไปแล้ว — ถ้าต้องแก้ ต้องขอปลดล็อกจากเจ้าของร้าน/)).toBeVisible();
  await expect(page.getByText("REPORT_CLOSED")).toHaveCount(0);
});
