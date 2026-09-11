import { expect, test } from "@playwright/test";

import { enterAs } from "./helpers";

/* IT-E04 — every role home, and OW 08, at 360px: nothing scrolls sideways and no read-error
 * notice shows. Guards ^fix-dashboard-filter-360 and ^fix-read-error-text. */

const PAGES = [
  ["owner", "/owner"],
  ["owner", "/owner/dashboard"],
  ["chef", "/cm"],
  ["salaeng", "/branch"],
  ["minburi", "/branch"],
] as const;

for (const [who, path] of PAGES) {
  test(`IT-E04 ${path} as ${who} fits 360px with no read error`, async ({ page }) => {
    await enterAs(page, who);
    await page.goto(path);
    await expect(page.locator("h1")).toBeVisible();
    // ReadError's fold is the one notice that means a read failed.
    await expect(page.getByText("รายละเอียดสำหรับผู้ดูแลระบบ")).toHaveCount(0);
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - window.innerWidth,
    );
    expect(overflow, "px past the right edge").toBeLessThanOrEqual(0);
  });
}
