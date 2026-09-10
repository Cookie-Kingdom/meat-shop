/** One row of `v_config_history` (card ^ref-12). Shared by the table, the history sheet and
 * the create sheet, which is why it is here rather than in whichever of them was written
 * first. */
export type ConfigRow = {
  source: "CONFIG" | "PRODUCT_PRICE" | "FULL_STOCK" | "SMOKE_FEE_TIER";
  item_key: string;
  item_label_th: string;
  scope_location_id: string | null;
  scope_name_th: string | null;
  effective_from: string;
  value_numeric: number | null;
  value_text: string | null;
  value_json: unknown;
  value_display: string | null;
  note: string | null;
  created_at: string;
  created_by: string | null;
  created_by_name: string | null;
  is_current: boolean;
  is_future: boolean;
  row_id: string;
};

/** One row of `v_config_catalogue` — a picker option, no rate attached. */
export type CatalogueRow = {
  kind: "PRODUCT" | "PACKAGING_ITEM" | "LOCATION";
  id: string;
  name_th: string;
  code: string;
  unit: string;
};

/** The identity of one configurable item: source + key + scope. Three sources key on an id
 * and one on a text key, and all four can be branch-scoped in principle, so the identity is
 * a triple everywhere rather than a special case per source. */
export function itemId(row: {
  source: string;
  item_key: string;
  scope_location_id: string | null;
}): string {
  return `${row.source}:${row.item_key}:${row.scope_location_id ?? ""}`;
}
