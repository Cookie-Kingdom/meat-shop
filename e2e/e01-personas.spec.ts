import { expect, test } from "@playwright/test";

import { enterAs } from "./helpers";

/* IT-E01 — each of the four personas lands on its role home and the bar names it; an L2 sees
 * its own branch only. ^ref-65's M-02, automated. */

const HOME = {
  owner: "/owner",
  chef: "/cm",
  salaeng: "/branch",
  minburi: "/branch",
} as const;

for (const key of Object.keys(HOME) as (keyof typeof HOME)[]) {
  test(`IT-E01 ${key} lands on ${HOME[key]}`, async ({ page }) => {
    await enterAs(page, key);
    await expect(page).toHaveURL(new RegExp(`${HOME[key]}(\\?.*)?$`));
  });
}

test("IT-E01 each branch admin sees their own branch and not the other", async ({ page }) => {
  await enterAs(page, "salaeng");
  await expect(page.getByText("สาขาศาลาแดง").first()).toBeVisible();
  await expect(page.getByText("สาขามีนบุรี")).toHaveCount(0);

  await enterAs(page, "minburi");
  await expect(page.getByText("สาขามีนบุรี").first()).toBeVisible();
  await expect(page.getByText("สาขาศาลาแดง")).toHaveCount(0);
});
