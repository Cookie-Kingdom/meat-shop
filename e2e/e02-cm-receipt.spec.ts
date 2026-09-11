import { expect, test, type Page } from "@playwright/test";

import { enterAs } from "./helpers";

/* IT-E02 — the chef receives lot C on CM 02 at the full 100.00, and the Owner's OW 02 ค้างรับ
 * stops listing it. The ^fix-cm02-sign-line class of defect: every function passed its own test
 * and the screen called the wrong ones. (A short weight would leave it as a partial, D06.) */

function outstanding(page: Page) {
  return page
    .locator("section")
    .filter({ has: page.getByRole("heading", { name: "ค้างรับ", exact: true }) });
}

test("IT-E02 CM 02 at the full weight takes lot C off OW 02 ค้างรับ", async ({ page }) => {
  await enterAs(page, "chef");
  const lotC = page.getByRole("link").filter({ hasText: "กำลังขนส่ง" });
  await expect(lotC).toHaveCount(1);
  const code = (await lotC.textContent())?.match(/PO-\d+-\d+-\d+/)?.[0];
  const href = await lotC.getAttribute("href");
  expect(code, "lot C shows its code").toBeTruthy();

  // Control: before the receipt, OW 02 does list it. The section renders a phone list and a
  // desktop table; at 360px only the list shows. The check after the receipt counts both.
  await enterAs(page, "owner");
  await page.goto("/owner/transport");
  await expect(outstanding(page).getByText(code!).filter({ visible: true })).toBeVisible();

  await enterAs(page, "chef");
  await page.goto(`${href}/receive`);
  await page.getByLabel("น้ำหนักรับจริง").fill("100.00");
  await expect(page.getByText("ตรงกับที่ Foodiva ส่ง")).toBeVisible();
  await page.getByRole("button", { name: "บันทึกน้ำหนักรับ" }).click();
  await page.waitForURL(/saved=receive/);

  await enterAs(page, "owner");
  await page.goto("/owner/transport");
  await expect(outstanding(page)).toBeVisible();
  await expect(outstanding(page).getByText(code!)).toHaveCount(0);
});
