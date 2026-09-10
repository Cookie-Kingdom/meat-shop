"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";

import { newIdempotencyKey } from "@/lib/rpc/config";
import { seedPackagingItems } from "@/lib/rpc/setup";

/* /owner/setup write path (card ^ref-61). The only write the setup screen owns; every value
 * it sets goes through OW 10's own actions (`features/config/actions.ts`) with `back` pointed
 * here.
 *
 * The idempotency key is minted here, once per submit, never during render (ADR-005, R38). */

export async function submitPackagingSeed() {
  const result = await seedPackagingItems(newIdempotencyKey());
  const q = new URLSearchParams(
    result.ok ? { saved: "1" } : { err: result.message },
  );
  revalidatePath("/owner/setup");
  redirect(`/owner/setup?${q.toString()}`);
}
