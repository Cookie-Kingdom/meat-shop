import { execFileSync } from "node:child_process";
import { expect, type Page } from "@playwright/test";

import { DEMO_PERSONAS, type PersonaKey } from "../src/features/demo/personas";

/** Sign in the way a tester does: one tap on the persona's card (^ref-65), then wait for the
 * demo bar to name them. Clears the session first, so one test can switch persona. */
export async function enterAs(page: Page, key: PersonaKey) {
  const { name } = DEMO_PERSONAS[key];
  await page.context().clearCookies();
  await page.goto("/login");
  // The card's accessible name starts with the persona's name; "เจ้าของร้าน" also appears
  // inside the branch cards' hint lines, so the match is anchored.
  await page.getByRole("button", { name: new RegExp(`^${name}`) }).click();
  await page.waitForURL((url) => !url.pathname.startsWith("/login"));
  await expect(page.getByText(`โหมดทดลอง · ${name}`)).toBeVisible();
}

/** BR 01's one action. The button's name leads with its state ("ยังไม่ทำ · เปิดวัน <date>"). */
export async function openDay(page: Page) {
  await page.getByRole("button", { name: /เปิดวัน \d/ }).click();
  await expect(page.getByText("เปิดวันแล้ว")).toBeVisible();
}

/** Read what no screen shows, straight from the stack's database (IT-E05). */
export function sql(query: string): string {
  return execFileSync(
    "docker",
    ["exec", "meatshop-e2e-db", "psql", "-U", "postgres", "-d", "meatshop", "-At", "-c", query],
    { encoding: "utf8" },
  ).trim();
}
