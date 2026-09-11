import { defineConfig } from "@playwright/test";

/* Card ^ref-72 — browser E2E on the local stack (vault PLAN-integration-tests.md §^ref-72).
 * Run it as `pnpm test:e2e`: e2e/run.sh brings the stack up and exports what this file reads.
 * Chromium only, 360×800 with touch, because these are phone screens. */

const api = process.env.NEXT_PUBLIC_SUPABASE_URL ?? "";
// The build below inlines this URL. Without run.sh it would come from .env.local, the real project.
if (!api.startsWith("http://127.0.0.1:")) {
  throw new Error(
    "Run E2E with `pnpm test:e2e`. NEXT_PUBLIC_SUPABASE_URL is not the local stack.",
  );
}
const port = process.env.E2E_APP_PORT ?? "3100";

export default defineConfig({
  testDir: "e2e",
  // One seeded database: the specs run one at a time, in file order.
  workers: 1,
  fullyParallel: false,
  forbidOnly: true,
  reporter: "list",
  use: {
    baseURL: `http://127.0.0.1:${port}`,
    browserName: "chromium",
    viewport: { width: 360, height: 800 },
    hasTouch: true,
    isMobile: true,
    locale: "th-TH",
    timezoneId: "Asia/Bangkok",
    trace: "retain-on-failure",
  },
  webServer: {
    command: `pnpm build && pnpm start -p ${port} -H 127.0.0.1`,
    url: `http://127.0.0.1:${port}/login`,
    timeout: 300_000,
    // Never a developer's `next dev`: that one talks to .env.local.
    reuseExistingServer: false,
  },
});
