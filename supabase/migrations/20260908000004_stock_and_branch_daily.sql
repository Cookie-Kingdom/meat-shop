-- ER diagram 3: stock ledger and branch daily entry.

create table products (
  id               uuid primary key default gen_random_uuid(),
  code             text not null unique,
  name_th          text not null,
  item_type        item_type not null,
  sale_unit        text not null,                  -- box, bag, tube, kg, bottle
  is_stock_tracked boolean not null default true,  -- false for drinks
  is_active        boolean not null default true
);

create table product_prices (
  id             uuid primary key default gen_random_uuid(),
  product_id     uuid not null references products(id),
  price_thb      numeric(12,2) not null check (price_thb >= 0),
  cost_thb       numeric(12,2) check (cost_thb >= 0),   -- null where cost comes from the lot
  effective_from date not null,
  created_by     uuid not null references profiles(id),
  created_at     timestamptz not null default now(),
  unique (product_id, effective_from)                   -- BR23
);

create table packaging_items (
  id        uuid primary key default gen_random_uuid(),
  code      text not null unique,
  name_th   text not null,
  unit      text not null,
  is_active boolean not null default true
);

create table packaging_full_stock (
  id                 uuid primary key default gen_random_uuid(),
  packaging_item_id  uuid not null references packaging_items(id),
  location_id        uuid references locations(id),
  -- R9: zero means "not configured", and is never a divisor
  full_stock_qty     numeric(12,2) not null check (full_stock_qty > 0),
  effective_from     date not null,
  created_by         uuid not null references profiles(id),
  created_at         timestamptz not null default now(),
  unique (packaging_item_id, location_id, effective_from)
);

create table daily_reports (
  id               uuid primary key default gen_random_uuid(),
  location_id      uuid not null references locations(id),
  -- BR22: the BUSINESS date. A 01:00 entry belongs to the day before.
  report_date      date not null,
  shift_started_at timestamptz,
  status           report_status not null default 'OPEN',
  opened_by        uuid references profiles(id),
  closed_by        uuid references profiles(id),
  closed_at        timestamptz,
  remark           text,
  unique (location_id, report_date)                     -- R5
);
create index daily_reports_open on daily_reports (location_id, report_date) where status <> 'CLOSED';

create table sales_lines (
  id                  uuid primary key default gen_random_uuid(),
  daily_report_id     uuid not null references daily_reports(id),
  product_id          uuid not null references products(id),
  lot_id              uuid references lots(id),         -- R21: NOT NULL for meat, see trigger
  smoke_date_group_id uuid references smoke_date_groups(id),
  qty                 numeric(12,2) not null check (qty > 0),
  unit_price_thb      numeric(12,2) not null check (unit_price_thb >= 0),  -- BR23 snapshot
  channel             text,                             -- LINE MAN only in round one (D04)
  created_at          timestamptz not null default now()
);
create index sales_lines_report on sales_lines (daily_report_id);

create table thaw_records (
  id                  uuid primary key default gen_random_uuid(),
  daily_report_id     uuid not null references daily_reports(id),
  lot_id              uuid not null references lots(id),          -- D01
  smoke_date_group_id uuid references smoke_date_groups(id),
  thawed_weight_kg    numeric(12,2) not null check (thawed_weight_kg > 0),
  fifo_override_reason text,                                      -- R15
  created_by          uuid not null references profiles(id),
  created_at          timestamptz not null default now()
);
create index thaw_records_report on thaw_records (daily_report_id);

create table waste_records (
  id                  uuid primary key default gen_random_uuid(),
  daily_report_id     uuid not null references daily_reports(id),
  item_type           item_type not null,
  lot_id              uuid references lots(id),         -- R21: NOT NULL for meat, see trigger
  smoke_date_group_id uuid references smoke_date_groups(id),
  qty                 numeric(12,2) not null check (qty > 0),
  reason              text not null,
  created_by          uuid not null references profiles(id),
  created_at          timestamptz not null default now()
);
create index waste_records_report on waste_records (daily_report_id);

-- R21: every meat movement names its source lot.
create function fn_require_lot_for_meat() returns trigger language plpgsql as $$
declare v_item item_type;
begin
  if tg_table_name = 'sales_lines' then
    select item_type into v_item from products where id = new.product_id;
  else
    v_item := new.item_type;
  end if;
  if v_item = 'SMOKED_MEAT' and new.lot_id is null then
    raise exception 'LOT_REQUIRED: % on SMOKED_MEAT needs lot_id (R21/D01)', tg_table_name;
  end if;
  return new;
end $$;

create trigger trg_sales_lines_lot before insert or update on sales_lines
  for each row execute function fn_require_lot_for_meat();
create trigger trg_waste_records_lot before insert or update on waste_records
  for each row execute function fn_require_lot_for_meat();

create table physical_counts (
  id                  uuid primary key default gen_random_uuid(),
  daily_report_id     uuid references daily_reports(id),   -- null for ad-hoc counts
  location_id         uuid not null references locations(id),
  event_date          date not null,
  item_type           item_type not null,
  product_id          uuid references products(id),
  packaging_item_id   uuid references packaging_items(id),
  smoke_date_group_id uuid references smoke_date_groups(id),
  counted_qty         numeric(12,2) not null check (counted_qty >= 0),
  system_qty          numeric(12,2) not null,               -- snapshot at count time
  variance_qty        numeric(12,2) generated always as (counted_qty - system_qty) stored,
  reason              text,
  created_by          uuid not null references profiles(id),
  created_at          timestamptz not null default now()
);

create table rice_records (
  id                       uuid primary key default gen_random_uuid(),
  daily_report_id          uuid not null references daily_reports(id),
  location_id              uuid not null references locations(id),
  event_date               date not null,
  model                    rice_model not null,
  carried_in_cooked_kg     numeric(12,2) check (carried_in_cooked_kg >= 0),
  cooked_received_kg       numeric(12,2) check (cooked_received_kg >= 0),      -- M7A
  cooked_price_thb_per_kg  numeric(12,2) check (cooked_price_thb_per_kg >= 0), -- M7A, L1 only
  raw_purchased_kg         numeric(12,2) check (raw_purchased_kg >= 0),        -- M7B
  raw_price_thb_per_kg     numeric(12,2) check (raw_price_thb_per_kg >= 0),    -- M7B, L1 only
  cooked_today_kg          numeric(12,2) check (cooked_today_kg >= 0),         -- M7B
  raw_remaining_kg         numeric(12,2) check (raw_remaining_kg >= 0),
  cooked_remaining_kg      numeric(12,2) check (cooked_remaining_kg >= 0),
  created_by               uuid not null references profiles(id),
  created_at               timestamptz not null default now(),
  unique (daily_report_id)
);

create table branch_expenses (
  id              uuid primary key default gen_random_uuid(),
  daily_report_id uuid not null references daily_reports(id),
  category        text not null,
  amount_thb      numeric(12,2) not null check (amount_thb >= 0),
  paid_by_person  text,
  detail          text,
  created_by      uuid not null references profiles(id),
  created_at      timestamptz not null default now()
);

create table influencer_shipments (
  id              uuid primary key default gen_random_uuid(),
  daily_report_id uuid not null references daily_reports(id),
  recipient_name  text not null,
  box_count       integer not null check (box_count > 0),
  value_thb       numeric(12,2) check (value_thb >= 0),
  note            text,
  created_at      timestamptz not null default now()
);

-- ADR-003: the only stock table. Append-only, signed deltas, no balance column anywhere.
create table stock_ledger (
  id                  uuid primary key default gen_random_uuid(),
  idempotency_key     uuid not null unique,                 -- R4 / ADR-005
  item_type           item_type not null,
  product_id          uuid references products(id),
  packaging_item_id   uuid references packaging_items(id),
  lot_id              uuid references lots(id),
  smoke_date_group_id uuid references smoke_date_groups(id),
  location_id         uuid not null references locations(id),
  stock_state         stock_state not null,
  movement_type       movement_type not null,
  qty_delta           numeric(12,2) not null check (qty_delta <> 0),  -- signed
  business_date       date not null,                        -- BR22
  event_at            timestamptz not null,
  created_at          timestamptz not null default now(),
  source_table        text,
  source_id           uuid,
  reason              text,
  reversal_of         uuid references stock_ledger(id),      -- R2
  created_by          uuid not null references profiles(id)
);
create index stock_ledger_balance
  on stock_ledger (location_id, item_type, stock_state, lot_id, smoke_date_group_id);
create index stock_ledger_business_date on stock_ledger (business_date);

-- R1: INSERT only. Corrections are a REVERSAL row, never an edit.
create function fn_stock_ledger_append_only() returns trigger language plpgsql as $$
begin
  raise exception 'LEDGER_APPEND_ONLY: stock_ledger is insert-only; post a REVERSAL row (R1/R2)';
end $$;

create trigger trg_stock_ledger_append_only
  before update or delete on stock_ledger
  for each statement execute function fn_stock_ledger_append_only();
