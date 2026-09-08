-- ER diagram 2: purchasing, transport, production.

create table suppliers (
  id        uuid primary key default gen_random_uuid(),
  name      text not null,
  contact   text,
  is_active boolean not null default true
);

create table purchase_orders (
  id                    uuid primary key default gen_random_uuid(),
  po_number             text not null unique,
  supplier_id           uuid not null references suppliers(id),
  event_date            date not null,                      -- order date
  ordered_weight_kg     numeric(12,2) not null check (ordered_weight_kg > 0),
  unit_price_thb_per_kg numeric(12,2) check (unit_price_thb_per_kg >= 0),
  brine_pct_offered     numeric(6,2) check (brine_pct_offered >= 0),   -- 10.00 = 10%
  brine_cost_thb        numeric(12,2) check (brine_cost_thb >= 0),
  note                  text,
  created_by            uuid not null references profiles(id),
  created_at            timestamptz not null default now()
);

create table po_deliveries (
  id                      uuid primary key default gen_random_uuid(),
  po_id                   uuid not null references purchase_orders(id),
  seq                     integer not null check (seq > 0),
  event_date              date not null,                    -- dispatch date
  -- BR03 / BR10: THE loss base and the smoke-fee tier base
  foodiva_sent_weight_kg  numeric(12,2) not null check (foodiva_sent_weight_kg > 0),
  note                    text,
  unique (po_id, seq)
);

create table lots (
  id                     uuid primary key default gen_random_uuid(),
  lot_code               text not null unique,
  po_id                  uuid not null references purchase_orders(id),
  -- D01: one delivery round, one lot
  po_delivery_id         uuid not null unique references po_deliveries(id),
  foodiva_sent_weight_kg numeric(12,2) not null check (foodiva_sent_weight_kg > 0),
  chef_house_location_id uuid not null references locations(id),
  assigned_operator_id   uuid references profiles(id),
  state                  lot_state not null default 'PO_CREATED',
  event_date             date not null,
  closed_at              timestamptz,
  closed_by              uuid references profiles(id),
  return_pickup_date     date,                              -- BR17, gates the return run
  return_pickup_set_by   uuid references profiles(id),
  created_at             timestamptz not null default now()
);
create index lots_state on lots (state);

alter table notifications
  add constraint notifications_lot_id_fkey foreign key (lot_id) references lots(id);

create table lot_receipts (
  id                    uuid primary key default gen_random_uuid(),
  lot_id                uuid not null unique references lots(id),
  event_date            date not null,
  -- CROSS-CHECK only. R16a: never the loss base.
  received_weight_kg    numeric(12,2) not null check (received_weight_kg >= 0),
  post_drain_weight_kg  numeric(12,2) check (post_drain_weight_kg >= 0),
  variance_reason       text,
  recorded_by           uuid not null references profiles(id),
  created_at            timestamptz not null default now()
);

create table smoke_daily_logs (
  id                     uuid primary key default gen_random_uuid(),
  lot_id                 uuid not null references lots(id),
  event_date             date not null,
  -- roll-up of smoke_daily_log_sources, maintained by trigger (R6a)
  input_weight_kg        numeric(12,2) not null default 0 check (input_weight_kg >= 0),
  smoked_weight_kg       numeric(12,2) check (smoked_weight_kg >= 0),
  brine_used_kg          numeric(12,2) check (brine_used_kg >= 0),
  post_freeze_weight_kg  numeric(12,2) check (post_freeze_weight_kg >= 0),
  packed_weight_kg       numeric(12,2) check (packed_weight_kg >= 0),
  bag_count              integer check (bag_count >= 0),
  recorded_by            uuid not null references profiles(id),
  created_at             timestamptz not null default now(),
  unique (lot_id, event_date)                               -- R6
);

create table smoke_daily_log_sources (
  id                  uuid primary key default gen_random_uuid(),
  smoke_daily_log_id  uuid not null references smoke_daily_logs(id) on delete cascade,
  lot_id              uuid not null references lots(id),     -- D05
  input_weight_kg     numeric(12,2) not null check (input_weight_kg > 0),
  created_at          timestamptz not null default now(),
  unique (smoke_daily_log_id, lot_id)
);

-- R6a: the parent input weight is the sum of its sources, never typed directly.
create function fn_rollup_smoke_log_input() returns trigger language plpgsql as $$
declare v_log uuid := coalesce(new.smoke_daily_log_id, old.smoke_daily_log_id);
begin
  update smoke_daily_logs
     set input_weight_kg = (select coalesce(sum(input_weight_kg), 0)
                              from smoke_daily_log_sources where smoke_daily_log_id = v_log)
   where id = v_log;
  return null;
end $$;

create trigger trg_rollup_smoke_log_input
  after insert or update or delete on smoke_daily_log_sources
  for each row execute function fn_rollup_smoke_log_input();

create table smoke_date_groups (
  id               uuid primary key default gen_random_uuid(),
  lot_id           uuid not null references lots(id),
  smoke_date       date not null,
  packed_weight_kg numeric(12,2) not null default 0 check (packed_weight_kg >= 0),
  bag_count        integer not null default 0 check (bag_count >= 0),
  created_at       timestamptz not null default now(),
  unique (lot_id, smoke_date)                               -- R7
);

create table lot_bags (
  id                  uuid primary key default gen_random_uuid(),
  smoke_date_group_id uuid not null references smoke_date_groups(id) on delete cascade,
  seq                 integer not null check (seq > 0),
  packed_weight_kg    numeric(12,2) not null check (packed_weight_kg > 0),
  created_at          timestamptz not null default now(),
  unique (smoke_date_group_id, seq)
);

create table transport_runs (
  id            uuid primary key default gen_random_uuid(),
  route         transport_route not null,
  vehicle_type  text,
  is_round_trip boolean not null default false,
  event_date    date not null,
  run_cost_thb  numeric(12,2) not null default 0 check (run_cost_thb >= 0),
  alloc_method  freight_alloc not null,                     -- snapshot, BR16
  created_by    uuid not null references profiles(id),
  note          text,
  created_at    timestamptz not null default now(),
  -- R25: the branch leg carries no fare
  constraint transport_runs_branch_leg_free
    check (route <> 'CENTRAL_TO_BRANCH' or run_cost_thb = 0)
);

create table transport_lines (
  id                     uuid primary key default gen_random_uuid(),
  run_id                 uuid not null references transport_runs(id) on delete cascade,
  lot_id                 uuid not null references lots(id),  -- D01
  smoke_date_group_id    uuid references smoke_date_groups(id),
  from_location_id       uuid references locations(id),
  to_location_id         uuid references locations(id),
  dispatched_weight_kg   numeric(12,2) not null check (dispatched_weight_kg > 0),
  received_weight_kg     numeric(12,2) check (received_weight_kg >= 0),
  outstanding_weight_kg  numeric(12,2)
    generated always as (dispatched_weight_kg - received_weight_kg) stored,   -- D06
  variance_pct           numeric(12,4)
    generated always as (
      abs(received_weight_kg - dispatched_weight_kg) / dispatched_weight_kg * 100
    ) stored,                                                                  -- BR12
  freight_share_thb      numeric(12,2) check (freight_share_thb >= 0),
  received_by            uuid references profiles(id),
  received_at            timestamptz,
  variance_reason        text,
  variance_settlement    text
);
create index transport_lines_lot on transport_lines (lot_id);
create index transport_lines_run on transport_lines (run_id);
