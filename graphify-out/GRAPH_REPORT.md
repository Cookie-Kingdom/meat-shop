# Graph Report - .  (2026-09-10)

## Corpus Check
- 163 files · ~92,544 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 480 nodes · 1051 edges · 28 communities (25 shown, 3 thin omitted)
- Extraction: 93% EXTRACTED · 7% INFERRED · 0% AMBIGUOUS · INFERRED: 72 edges (avg confidence: 0.82)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Purchasing, Transport and Audit|Purchasing, Transport and Audit]]
- [[_COMMUNITY_Auth Flow and Role Layouts|Auth Flow and Role Layouts]]
- [[_COMMUNITY_Config Management UI|Config Management UI]]
- [[_COMMUNITY_Production and Sales Schema|Production and Sales Schema]]
- [[_COMMUNITY_Package Dependencies|Package Dependencies]]
- [[_COMMUNITY_Stock Ledger and Opening Balances|Stock Ledger and Opening Balances]]
- [[_COMMUNITY_Dated Config Resolution|Dated Config Resolution]]
- [[_COMMUNITY_Audit Log Screen|Audit Log Screen]]
- [[_COMMUNITY_RLS Deny-All Posture|RLS Deny-All Posture]]
- [[_COMMUNITY_shadcn Component Config|shadcn Component Config]]
- [[_COMMUNITY_Config Server Actions and RPC|Config Server Actions and RPC]]
- [[_COMMUNITY_TypeScript Compiler Config|TypeScript Compiler Config]]
- [[_COMMUNITY_Git Workflow and Scaffold Docs|Git Workflow and Scaffold Docs]]
- [[_COMMUNITY_Supabase Clients and Proxy|Supabase Clients and Proxy]]
- [[_COMMUNITY_Branch Daily Concurrency Test|Branch Daily Concurrency Test]]
- [[_COMMUNITY_Migrations Apply Test|Migrations Apply Test]]
- [[_COMMUNITY_Purchasing Concurrency Test|Purchasing Concurrency Test]]
- [[_COMMUNITY_Transport Concurrency Test|Transport Concurrency Test]]
- [[_COMMUNITY_Ledger Concurrency Test|Ledger Concurrency Test]]
- [[_COMMUNITY_Prettier Config|Prettier Config]]
- [[_COMMUNITY_Root Layout and Thai Font|Root Layout and Thai Font]]
- [[_COMMUNITY_Next Config|Next Config]]
- [[_COMMUNITY_PostCSS Config|PostCSS Config]]

## God Nodes (most connected - your core abstractions)
1. `profiles (table)` - 38 edges
2. `lots (table)` - 35 edges
3. `stock_ledger (table)` - 32 edges
4. `fn_current_role()` - 26 edges
5. `locations (table)` - 26 edges
6. `Deny-all RLS posture (one door: SECURITY DEFINER view in, fn_* out)` - 21 edges
7. `createClient()` - 18 edges
8. `transport_lines (table)` - 18 edges
9. `fn_record_opening_balance()` - 17 edges
10. `config_settings (table)` - 17 edges

## Surprising Connections (you probably didn't know these)
- `Next.js Agent Rules Block` --semantically_similar_to--> `Create Next App scaffold README`  [INFERRED] [semantically similar]
  AGENTS.md → README.md
- `node_modules/next/dist/docs (authoritative Next.js guides)` --semantically_similar_to--> `Next.js official documentation and tutorials`  [INFERRED] [semantically similar]
  AGENTS.md → README.md
- `Merge gate: acceptance line true, pnpm build and pnpm lint pass` --shares_data_with--> `Development server startup (npm/yarn/pnpm/bun dev)`  [INFERRED]
  AGENTS.md → README.md
- `fn_check_variance` --semantically_similar_to--> `fn_config_value`  [INFERRED] [semantically similar]
  supabase/functions/fn_check_variance.sql → supabase/functions/fn_config_value.sql
- `fn_create_po` --conceptually_related_to--> `stock_ledger (table)`  [AMBIGUOUS]
  supabase/functions/fn_create_po.sql → supabase/migrations/20260908000004_stock_and_branch_daily.sql

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Card-to-merge branch lifecycle** — agents_tasks_md, agents_develop_branch, agents_feature_branch_convention, agents_merge_gate, agents_main_branch [EXTRACTED 1.00]
- **Create Next App defaults superseded by project conventions** — readme_dev_server, readme_app_page_entrypoint, readme_next_font_geist, readme_nextjs_scaffold [INFERRED 0.85]
- **Transport run: fare snapshot, freight split, and signed receipt** — supabase_functions_fn_create_transport_run_fn_create_transport_run, supabase_functions_fn_allocate_freight_fn_allocate_freight, supabase_functions_fn_confirm_transport_receipt_fn_confirm_transport_receipt, supabase_functions_fn_check_variance_fn_check_variance, supabase_migrations_20260908000003_purchasing_production_transport_lines [EXTRACTED 1.00]
- **Dated config resolution stack (one lookup, typed readers, never a default)** — supabase_functions_fn_config_value_fn_config_value, supabase_functions_fn_config_value_fn_config_numeric, supabase_functions_fn_config_boolean_fn_config_boolean, supabase_functions_fn_config_date_fn_config_date, supabase_functions_fn_backdating_allowed_fn_backdating_allowed [EXTRACTED 1.00]
- **Audit trail integrity: blanket capture, append-only guard, revoked defaults** — supabase_functions_fn_audit_row_fn_audit_row, supabase_functions_fn_audit_row_fn_audit_log_append_only, supabase_functions_fn_audit_row_trg_audit_log_append_only, supabase_functions_fn_audit_row_trg_audit_log_no_truncate, supabase_functions_fn_audit_row_trg_audit_attach_loop, supabase_functions_000_revoke_defaults_000_revoke_defaults [EXTRACTED 1.00]
- **Append-only correction: reversal plus replacement** — supabase_functions_fn_reverse_ledger_entry_fn_reverse_ledger_entry, supabase_functions_fn_post_ledger_fn_post_ledger, supabase_migrations_20260908000004_stock_and_branch_daily_stock_ledger [EXTRACTED 1.00]
- **L1-only dated config setters sharing one preamble and BR23** — supabase_functions_fn_set_config_fn_set_config, supabase_functions_fn_set_product_price_fn_set_product_price, supabase_functions_fn_set_packaging_full_stock_fn_set_packaging_full_stock, supabase_functions_fn_set_smoke_fee_tier_fn_set_smoke_fee_tier, supabase_functions_fn_require_owner_fn_require_owner [EXTRACTED 1.00]
- **Read views gating role in the WHERE while their tables stay deny-all** — supabase_views_010_v_stock_balance_v_stock_balance, supabase_views_030_v_po_outstanding_v_po_outstanding, supabase_views_040_v_audit_trail_v_audit_trail, supabase_views_050_v_config_history_v_config_history, supabase_views_060_v_config_catalogue_v_config_catalogue, supabase_views_070_v_freight_allocation_v_freight_allocation [EXTRACTED 1.00]
- **Go-live opening balance: a lot with no PO, a cost off the ledger, and a one-way close** — supabase_migrations_20260910000012_opening_balances_lots_round_or_opening, supabase_migrations_20260910000012_opening_balances_opening_balance_close, supabase_migrations_20260910000012_opening_balances_opening_costs, supabase_migrations_20260910000012_opening_balances_fn_stock_ledger_opening_closed, supabase_migrations_20260910000011_movement_type_opening_movement_type_opening_value, supabase_migrations_20260908000004_stock_and_branch_daily_stock_ledger [EXTRACTED 1.00]
- **Ledger immutability: three triggers closing UPDATE/DELETE, TRUNCATE and post-close OPENING** — supabase_migrations_20260908000004_stock_and_branch_daily_stock_ledger, supabase_migrations_20260908000004_stock_and_branch_daily_trg_stock_ledger_append_only, supabase_migrations_20260908000007_ledger_truncate_guard_trg_stock_ledger_no_truncate, supabase_migrations_20260910000012_opening_balances_trg_stock_ledger_opening_closed, supabase_migrations_20260908000004_stock_and_branch_daily_fn_stock_ledger_append_only [EXTRACTED 1.00]
- **Traceability chain: supplier batch to dispatch round to lot to smoke-date group to ledger row** — supabase_migrations_20260908000003_purchasing_production_purchase_orders, supabase_migrations_20260908000003_purchasing_production_po_deliveries, supabase_migrations_20260908000003_purchasing_production_lots, supabase_migrations_20260908000003_purchasing_production_smoke_date_groups, supabase_migrations_20260908000004_stock_and_branch_daily_stock_ledger, supabase_migrations_20260908000003_purchasing_production_transport_lines [EXTRACTED 1.00]
- **FINAL deny-all: the SECURITY DEFINER view is the only read door (no table policy ever lands)** — supabase_policies_config_settings_config_settings_deny_all, supabase_policies_packaging_full_stock_packaging_full_stock_deny_all, supabase_policies_product_prices_product_prices_deny_all, supabase_policies_audit_log_audit_log_deny_all, concept_no_second_read_path, supabase_functions_fn_current_role_fn_current_role [EXTRACTED 1.00]
- **Tables denied outright so an L3 session cannot reach a price or yield column (R20 / BR15)** — supabase_policies_opening_costs_opening_costs_deny_all, supabase_policies_product_prices_product_prices_deny_all, supabase_policies_packaging_full_stock_packaging_full_stock_deny_all, supabase_policies_lots_lots_deny_all, supabase_policies_po_deliveries_po_deliveries_deny_all, concept_l3_price_blindness [INFERRED 0.85]
- **Provisional deny-all: per-table declaration held until the card owning its role-specific v_* view is written** — supabase_policies_attendance_attendance_deny_all, supabase_policies_branch_expenses_branch_expenses_deny_all, supabase_policies_daily_reports_daily_reports_deny_all, supabase_policies_influencer_shipments_influencer_shipments_deny_all, supabase_policies_locations_locations_deny_all, supabase_policies_lot_bags_lot_bags_deny_all, supabase_policies_lot_receipts_lot_receipts_deny_all, supabase_policies_lots_lots_deny_all, supabase_policies_notifications_notifications_deny_all, supabase_policies_owner_expenses_owner_expenses_deny_all, supabase_policies_packaging_items_packaging_items_deny_all, supabase_policies_physical_counts_physical_counts_deny_all, supabase_policies_po_deliveries_po_deliveries_deny_all, supabase_policies_opening_balance_close_opening_balance_close_deny_all, concept_deny_all_rls_posture [EXTRACTED 1.00]
- **Tables held deny-all until their role-specific v_* view exists (ADR-002, ADR-004)** — supabase_policies_products_products_rls_posture, supabase_policies_purchase_orders_purchase_orders_rls_posture, supabase_policies_rice_records_rice_records_rls_posture, supabase_policies_sales_lines_sales_lines_rls_posture, supabase_policies_smoke_daily_log_sources_smoke_daily_log_sources_rls_posture, supabase_policies_smoke_daily_logs_smoke_daily_logs_rls_posture, supabase_policies_smoke_date_groups_smoke_date_groups_rls_posture, supabase_policies_staff_staff_rls_posture, supabase_policies_stock_ledger_stock_ledger_rls_posture, supabase_policies_suppliers_suppliers_rls_posture, supabase_policies_thaw_records_thaw_records_rls_posture, supabase_policies_transport_lines_transport_lines_rls_posture, supabase_policies_transport_runs_transport_runs_rls_posture, supabase_policies_unlock_requests_unlock_requests_rls_posture, supabase_policies_user_locations_user_locations_rls_posture, supabase_policies_waste_records_waste_records_rls_posture, supabase_policies_products_deny_all_until_view_posture [EXTRACTED 1.00]
- **The L1 Owner single-read-door pattern: SECURITY DEFINER view gated on fn_current_role(), never a second table policy, and never force RLS** — supabase_policies_smoke_fee_tiers_smoke_fee_tiers_rls_posture, supabase_policies_smoke_fee_tiers_v_config_history, supabase_functions_fn_current_role_fn_current_role, supabase_policies_profiles_profiles_select_self_or_owner, supabase_policies_profiles_three_role_boundary [EXTRACTED 1.00]
- **Tables whose closed posture is what keeps price and yield columns away from an L3 session (R20)** — supabase_policies_smoke_fee_tiers_smoke_fee_tiers_rls_posture, supabase_policies_purchase_orders_purchase_orders_rls_posture, supabase_policies_sales_lines_sales_lines_rls_posture, supabase_policies_smoke_daily_logs_smoke_daily_logs_rls_posture, supabase_policies_transport_lines_transport_lines_rls_posture, supabase_policies_staff_staff_rls_posture, supabase_policies_smoke_fee_tiers_l3_price_yield_restriction [INFERRED 0.85]
- **Tests that together prove the append-only stock ledger (ADR-003, R1)** — supabase_tests_ledger_truncate_test_ledger_truncate_test, supabase_tests_schema_smoke_test_schema_smoke_test, supabase_tests_ledger_reversal_test_ledger_reversal_test, supabase_tests_ledger_post_test_ledger_post_test, supabase_tests_audit_trigger_test_audit_trigger_test, supabase_migrations_20260908000004_stock_and_branch_daily_stock_ledger [INFERRED 0.85]
- **Tests that together prove the deny-all RLS posture and the database-side role gate (ADR-004, R20)** — supabase_tests_rls_deny_all_test_rls_deny_all_test, supabase_tests_rls_behaviour_test_rls_behaviour_test, supabase_tests_rls_helpers_test_rls_helpers_test, supabase_tests_audit_trail_test_audit_trail_test, supabase_tests_config_screen_test_config_screen_test, supabase_tests_ledger_views_test_ledger_views_test [INFERRED 0.85]
- **Tests asserting the client-generated idempotency key survives a dropped connection (ADR-005, R4)** — supabase_tests_ledger_post_test_ledger_post_test, supabase_tests_config_writers_test_config_writers_test, supabase_tests_purchasing_test_purchasing_test, supabase_tests_transport_test_transport_test, supabase_tests_branch_daily_test_branch_daily_test, supabase_tests_opening_balance_test_opening_balance_test, supabase_tests_opening_close_test_opening_close_test [INFERRED 0.85]

## Communities (28 total, 3 thin omitted)

### Community 0 - "Purchasing, Transport and Audit"
Cohesion: 0.08
Nodes (73): 000_revoke_defaults (schema-wide grant revocation sweep), fn_add_po_delivery, fn_allocate_freight, fn_audit_log_append_only, fn_audit_row (generic audit trigger function), trg_audit_<table> attach loop (blanket audit trigger over pg_tables), trg_audit_log_append_only (before update or delete on audit_log), trg_audit_log_no_truncate (before truncate on audit_log) (+65 more)

### Community 1 - "Auth Flow and Role Layouts"
Cohesion: 0.10
Nodes (27): GET(), Search, Search, Search, BranchLayout(), CmLayout(), OwnerLayout(), Root() (+19 more)

### Community 2 - "Config Management UI"
Cohesion: 0.10
Nodes (30): ConfigPage(), one(), parseItemId(), ConfigHistorySheet(), COLUMNS, ConfigTable(), Item, ChooseItemSheet() (+22 more)

### Community 3 - "Production and Sales Schema"
Cohesion: 0.07
Nodes (40): item_type (enum), unlock_status (enum), unlock_target (enum), unlock_requests (table), fn_rollup_smoke_log_input() (trigger function), smoke_daily_log_sources (table), smoke_daily_logs (table), trg_rollup_smoke_log_input (trigger) (+32 more)

### Community 4 - "Package Dependencies"
Cohesion: 0.06
Nodes (34): dependencies, class-variance-authority, clsx, lucide-react, next, radix-ui, react, react-dom (+26 more)

### Community 5 - "Stock Ledger and Opening Balances"
Cohesion: 0.18
Nodes (28): fn_backdating_allowed, fn_close_opening_balances, fn_post_ledger(), fn_record_opening_balance(), fn_reverse_ledger_entry(), fn_set_opening_cost(), movement_type (enum), stock_state (enum) (+20 more)

### Community 6 - "Dated Config Resolution"
Cohesion: 0.20
Nodes (26): fn_config_boolean, fn_config_date, fn_config_numeric, fn_config_value, fn_set_config(), fn_set_packaging_full_stock(), fn_set_product_price(), fn_set_smoke_fee_tier() (+18 more)

### Community 7 - "Audit Log Screen"
Cohesion: 0.11
Nodes (17): ACTIONS, AuditPage(), one(), ROLES, Column, Props, ResponsiveTable(), ACTION_LABEL (+9 more)

### Community 8 - "RLS Deny-All Posture"
Cohesion: 0.13
Nodes (24): Deny-all RLS posture (one door: SECURITY DEFINER view in, fn_* out), L3 price-blindness (R20): a CM Operator session never reads a price or yield column, No second read path: a table policy would bypass the view's owner-only WHERE, Three-role boundary (L1 Owner / L2 Branch Admin / L3 CM Operator) enforced in the database, expense_kind (enum), lot_bags (table), branch_expenses (table), influencer_shipments (table) (+16 more)

### Community 9 - "shadcn Component Config"
Cohesion: 0.09
Nodes (21): aliases, components, hooks, lib, ui, utils, iconLibrary, menuAccent (+13 more)

### Community 10 - "Config Server Actions and RPC"
Cohesion: 0.24
Nodes (16): eslintConfig, finish(), num(), submitConfigValue(), submitFullStock(), submitProductPrice(), submitSmokeFeeTier(), MESSAGES (+8 more)

### Community 11 - "TypeScript Compiler Config"
Cohesion: 0.10
Nodes (19): compilerOptions, allowJs, esModuleInterop, incremental, isolatedModules, jsx, lib, module (+11 more)

### Community 12 - "Git Workflow and Scaffold Docs"
Cohesion: 0.18
Nodes (16): develop (integration branch), feature/<short-slug> branch naming convention, generate-agent-files.js (Next.js AGENTS.md generator), Git Workflow, main (release-only branch), Merge gate: acceptance line true, pnpm build and pnpm lint pass, node_modules/next/dist/docs (authoritative Next.js guides), Next.js Agent Rules Block (+8 more)

### Community 13 - "Supabase Clients and Proxy"
Cohesion: 0.24
Nodes (8): SUPABASE_PUBLISHABLE_KEY, SUPABASE_URL, createProxyClient(), AUTH_ONLY_PREFIXES, config, isUnder(), proxy(), PUBLIC_PREFIXES

### Community 14 - "Branch Daily Concurrency Test"
Cohesion: 0.47
Nodes (3): note(), open_day(), branch_daily_concurrency_test.sh script

### Community 15 - "Migrations Apply Test"
Cohesion: 0.47
Nodes (3): apply_state_folders(), migrations_apply_test.sh script, usage()

### Community 16 - "Purchasing Concurrency Test"
Cohesion: 0.47
Nodes (3): book(), note(), purchasing_concurrency_test.sh script

### Community 17 - "Transport Concurrency Test"
Cohesion: 0.47
Nodes (3): note(), transport_concurrency_test.sh script, sign()

### Community 18 - "Ledger Concurrency Test"
Cohesion: 0.60
Nodes (3): draw(), note(), ledger_concurrency_test.sh script

### Community 19 - "Prettier Config"
Cohesion: 0.50
Nodes (3): plugins, tailwindFunctions, tailwindStylesheet

## Ambiguous Edges - Review These
- `fn_create_po` → `stock_ledger (table)`  [AMBIGUOUS]
  supabase/functions/fn_create_po.sql · relation: conceptually_related_to
- `smoke_fee_tiers (table)` → `po_deliveries (table)`  [AMBIGUOUS]
  supabase/migrations/20260908000003_purchasing_production.sql · relation: shares_data_with

## Knowledge Gaps
- **123 isolated node(s):** `plugins`, `tailwindStylesheet`, `tailwindFunctions`, `$schema`, `style` (+118 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **3 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **What is the exact relationship between `fn_create_po` and `stock_ledger (table)`?**
  _Edge tagged AMBIGUOUS (relation: conceptually_related_to) - confidence is low._
- **What is the exact relationship between `smoke_fee_tiers (table)` and `po_deliveries (table)`?**
  _Edge tagged AMBIGUOUS (relation: shares_data_with) - confidence is low._
- **Why does `profiles (table)` connect `Purchasing, Transport and Audit` to `RLS Deny-All Posture`, `Production and Sales Schema`, `Stock Ledger and Opening Balances`, `Dated Config Resolution`?**
  _High betweenness centrality (0.039) - this node is a cross-community bridge._
- **Why does `createClient()` connect `Auth Flow and Role Layouts` to `Config Management UI`, `Config Server Actions and RPC`, `Supabase Clients and Proxy`, `Audit Log Screen`?**
  _High betweenness centrality (0.028) - this node is a cross-community bridge._
- **Why does `stock_ledger (table)` connect `Stock Ledger and Opening Balances` to `Purchasing, Transport and Audit`, `Production and Sales Schema`, `Dated Config Resolution`?**
  _High betweenness centrality (0.025) - this node is a cross-community bridge._
- **Are the 2 inferred relationships involving `lots (table)` (e.g. with `lot_bags RLS posture (deny-all, provisional)` and `lot_receipts RLS posture (deny-all, provisional)`) actually correct?**
  _`lots (table)` has 2 INFERRED edges - model-reasoned connections that need verification._
- **Are the 2 inferred relationships involving `stock_ledger (table)` (e.g. with `fn_confirm_transport_receipt` and `RLS deny-all bootstrap (DO block)`) actually correct?**
  _`stock_ledger (table)` has 2 INFERRED edges - model-reasoned connections that need verification._