import Link from "next/link";

import {
  ConfigTable,
  type Item,
} from "@/features/config/components/config-table";
import { ConfigHistorySheet } from "@/features/config/components/config-history-sheet";
import {
  ChooseItemSheet,
  NewValueSheet,
} from "@/features/config/components/new-value-sheet";
import { SmokeFeeTierForm } from "@/features/config/components/smoke-fee-tier-form";
import {
  GROUP_LABEL,
  GROUPS,
  groupFor,
  type Group,
} from "@/features/config/keys";
import {
  itemId,
  type CatalogueRow,
  type ConfigRow,
} from "@/features/config/types";
import { createClient } from "@/lib/supabase/server";

/* OW 10 — the config screen (card ^ref-12). Skeleton S8: title + ตั้งค่าใหม่, filter bar,
 * table, pagination. No bottom action bar.
 *
 * THE ROLE GATE IS NOT HERE. `v_config_history` and `v_config_catalogue` both carry
 * `where fn_current_role() = 'L1_OWNER'`, so an L2 or L3 session reads zero rows from the
 * database (R20, R34, ADR-004). The `(owner)` layout's `requireRole` 403s them first, but
 * that is the mirror — delete it and this page still shows nothing. That ordering is the
 * card's acceptance line.
 *
 * `supabase.from(...)` is the sanctioned path for these two reads: they go through a view
 * under RLS. The `CLAUDE.md` prohibition is on `.from()` for a WRITE — every write here goes
 * through `src/lib/rpc/config.ts` and an `fn_set_*` RPC.
 *
 * Group, page, display mode and which sheet is open all live in `searchParams`. The whole
 * route is a Server Component and ships no client JavaScript: the sheets are links, the
 * filter bar is a GET form, and the create forms post to Server Actions.
 *
 * ponytail: one unpaginated read of the whole view per render, filtered and grouped in
 * TypeScript. The config surface is ~24 items and a handful of revisions each, so a second
 * round trip to count and page in SQL costs more than the rows do. Ceiling: a few hundred
 * rows, or the first item with a long revision history. Upgrade path is a `.range()` over
 * `is_current` plus a separate query for the revision line's previous value.
 */

const PAGE_SIZE = 6; // the ConfigTable contract: six per page from the first release

const control =
  "h-11 rounded-md border border-border bg-surface px-3 text-body text-text-primary " +
  "focus-visible:border-focus-ring focus-visible:outline-2 focus-visible:outline-focus-ring";

function one(value: string | string[] | undefined): string {
  return (Array.isArray(value) ? value[0] : value) ?? "";
}

/** `SOURCE:item_key:scope` — the identity `itemId()` builds. Split from the right, because
 * a `CONFIG` key never contains a colon but this keeps the parse honest if one ever does. */
function parseItemId(raw: string) {
  const first = raw.indexOf(":");
  const last = raw.lastIndexOf(":");
  if (first < 0 || last <= first) return null;
  return {
    source: raw.slice(0, first),
    itemKey: raw.slice(first + 1, last),
    scopeLocationId: raw.slice(last + 1) || null,
  };
}

export default async function ConfigPage(props: PageProps<"/owner/config">) {
  const params = await props.searchParams;
  const group = one(params.group);
  const mode = one(params.mode) === "table" ? "table" : "cards";
  const page = Math.max(1, Number.parseInt(one(params.page), 10) || 1);
  const set = one(params.set);
  const history = one(params.history);
  const saved = one(params.saved);
  const err = one(params.err);

  const supabase = await createClient();

  const [historyRes, catalogueRes] = await Promise.all([
    supabase.from("v_config_history").select("*"),
    supabase.from("v_config_catalogue").select("*"),
  ]);

  const rows = (historyRes.data ?? []) as ConfigRow[];
  const catalogue = (catalogueRes.data ?? []) as CatalogueRow[];
  const error = historyRes.error ?? catalogueRes.error;

  /* One entry per configured item, newest first within it. `is_current` already picks the
   * row in force per (source, item_key, scope); `previous` is the next one down, which is
   * what the revision line names. An item whose only rows are future has no current row —
   * it still has to appear, or the Owner cannot see what they scheduled. */
  const byItem = new Map<string, ConfigRow[]>();
  for (const row of rows) {
    const id = itemId(row);
    const list = byItem.get(id);
    if (list) list.push(row);
    else byItem.set(id, [row]);
  }
  for (const list of byItem.values()) {
    list.sort((a, b) => b.effective_from.localeCompare(a.effective_from));
  }

  const allItems: Item[] = [...byItem.entries()]
    .map(([id, list]) => {
      const at = list.findIndex((r) => r.is_current);
      const i = at >= 0 ? at : list.length - 1; // future-only: show the earliest scheduled
      return { id, current: list[i], previous: list[i + 1] ?? null };
    })
    .sort((a, b) =>
      a.current.item_label_th.localeCompare(b.current.item_label_th, "th"),
    );

  const items = group
    ? allItems.filter(
        (i) => groupFor(i.current.source, i.current.item_key) === group,
      )
    : allItems;

  const lastPage = Math.max(1, Math.ceil(items.length / PAGE_SIZE));
  const shown = items.slice((page - 1) * PAGE_SIZE, page * PAGE_SIZE);

  const href = (over: Record<string, string | null>) => {
    const next = new URLSearchParams();
    const base: Record<string, string> = { group, mode, page: String(page) };
    for (const [k, v] of Object.entries({ ...base, ...over })) {
      if (
        v &&
        !(k === "page" && v === "1") &&
        !(k === "mode" && v === "cards")
      ) {
        next.set(k, v);
      }
    }
    const qs = next.toString();
    return qs ? `/owner/config?${qs}` : "/owner/config";
  };

  const closeHref = href({ set: null, history: null });
  const target = set && set !== "1" ? parseItemId(set) : null;
  const historyTarget = history ? (byItem.get(history) ?? []) : [];

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-h1 text-text-primary">ตั้งค่าระบบ</h1>
        <Link
          href={href({ set: "1", history: null })}
          className="inline-flex h-11 items-center rounded-md bg-accent px-4 text-label text-accent-fg hover:bg-accent-hover"
        >
          ตั้งค่าใหม่
        </Link>
      </div>

      <p className="text-body-sm text-text-secondary">
        การเปลี่ยนค่าคือการเพิ่มแถวใหม่พร้อมวันที่เริ่มใช้
        ไม่ใช่การแก้ทับของเดิม — ตัวเลขที่รายงานเก่าใช้ไปแล้วจะไม่เปลี่ยนตาม
        (ADR-006, BR23)
      </p>

      {saved ? (
        <p className="rounded-lg border border-success bg-success-subtle p-3 text-body-sm text-success">
          บันทึกค่าใหม่แล้ว
        </p>
      ) : null}
      {err ? (
        <p className="rounded-lg border border-danger bg-danger-subtle p-3 text-body-sm text-danger">
          {err}
        </p>
      ) : null}

      {/* The create sheet. `?set=1` picks an item; `?set=SOURCE:key:scope` sets its value. */}
      {set === "1" ? (
        <ChooseItemSheet catalogue={catalogue} closeHref={closeHref} />
      ) : null}
      {target?.source === "SMOKE_FEE_TIER" ? (
        <SmokeFeeTierForm
          current={
            (byItem.get(set) ?? []).find((r) => r.is_current) ??
            (byItem.get(set) ?? [])[0] ??
            null
          }
          backHref={closeHref}
          closeHref={closeHref}
        />
      ) : target ? (
        <NewValueSheet
          source={target.source}
          itemKey={target.itemKey}
          scopeLocationId={target.scopeLocationId}
          catalogue={catalogue}
          backHref={closeHref}
          closeHref={closeHref}
        />
      ) : null}

      {historyTarget.length > 0 ? (
        <ConfigHistorySheet rows={historyTarget} closeHref={closeHref} />
      ) : null}

      {/* A plain GET form. Submitting rewrites the URL, which is the state. */}
      <form
        method="get"
        className="flex flex-wrap items-end gap-3 rounded-lg border border-border bg-surface p-4"
      >
        <label className="flex flex-col gap-1">
          <span className="text-label text-text-secondary">หมวด</span>
          <select name="group" defaultValue={group} className={control}>
            <option value="">ทั้งหมด</option>
            {GROUPS.map((g) => (
              <option key={g} value={g}>
                {GROUP_LABEL[g as Group]}
              </option>
            ))}
          </select>
        </label>

        <label className="flex flex-col gap-1">
          <span className="text-label text-text-secondary">มุมมองบนมือถือ</span>
          <select name="mode" defaultValue={mode} className={control}>
            <option value="cards">การ์ด</option>
            <option value="table">ตาราง</option>
          </select>
        </label>

        <button
          type="submit"
          className="h-11 rounded-md bg-accent px-4 text-label text-accent-fg hover:bg-accent-hover"
        >
          กรอง
        </button>
      </form>

      {mode === "table" ? (
        <p className="text-caption text-text-muted">
          โหมดตารางบนมือถือต้องเลื่อนแนวนอน ใช้เมื่อต้องเทียบหลายรายการเท่านั้น
        </p>
      ) : null}

      {error ? (
        <p className="rounded-lg border border-danger bg-danger-subtle p-4 text-body text-danger">
          อ่านค่าตั้งต้นไม่สำเร็จ — {error.message}
        </p>
      ) : (
        <ConfigTable
          items={shown}
          mode={mode}
          /* NotConfiguredNotice's rule: missing config is not the user's mistake. Never a
           * zero, never a red error — a calm sentence naming who sets it and how. */
          emptyState={
            <p className="rounded-lg border border-border bg-surface p-6 text-center text-body text-text-secondary">
              {group
                ? `ยังไม่ได้ตั้งค่าในหมวด${GROUP_LABEL[group as Group] ?? ""}`
                : "ยังไม่ได้ตั้งค่าใดในระบบ"}{" "}
              — กด “ตั้งค่าใหม่” เพื่อเริ่ม
            </p>
          }
        />
      )}

      <nav className="flex items-center justify-between gap-4">
        {page > 1 ? (
          <Link
            href={href({ page: String(page - 1) })}
            className="inline-flex h-11 items-center text-label text-accent hover:underline"
          >
            ← ก่อนหน้า
          </Link>
        ) : (
          <span />
        )}
        <span className="text-caption text-text-secondary tabular-nums">
          {page} / {lastPage}
        </span>
        {page < lastPage ? (
          <Link
            href={href({ page: String(page + 1) })}
            className="inline-flex h-11 items-center text-label text-accent hover:underline"
          >
            ถัดไป →
          </Link>
        ) : (
          <span />
        )}
      </nav>
    </div>
  );
}
