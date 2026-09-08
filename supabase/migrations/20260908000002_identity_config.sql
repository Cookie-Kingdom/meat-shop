-- ER diagram 1: identity, locations, config, control.

create table profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  role         user_role not null,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now()
);

create table locations (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique,
  name_th    text not null,
  kind       location_kind not null,
  rice_model rice_model,
  is_active  boolean not null default true,
  -- rice model only means anything for a branch
  constraint locations_rice_model_branch_only
    check (rice_model is null or kind = 'BRANCH')
);

create table user_locations (
  id                 uuid primary key default gen_random_uuid(),
  profile_id         uuid not null references profiles(id) on delete cascade,
  location_id        uuid not null references locations(id),
  -- BR12 / BR17 delegation: grants the act, not the data
  can_receive_central boolean not null default false,
  unique (profile_id, location_id)
);

create table smoke_fee_tiers (
  id             uuid primary key default gen_random_uuid(),
  min_weight_kg  numeric(12,2) not null check (min_weight_kg >= 0),
  max_weight_kg  numeric(12,2),              -- null = open-ended top band
  rate_thb       numeric(12,2) not null check (rate_thb >= 0),
  rate_basis     text not null check (rate_basis in ('PER_KG','FLAT')),
  effective_from date not null,
  created_by     uuid not null references profiles(id),
  created_at     timestamptz not null default now(),
  constraint smoke_fee_tiers_band check (max_weight_kg is null or max_weight_kg > min_weight_kg),
  unique (effective_from, min_weight_kg)
);

create table config_settings (
  id                uuid primary key default gen_random_uuid(),
  key               text not null,
  scope_location_id uuid references locations(id),   -- null = global
  value_numeric     numeric(18,4),
  value_text        text,
  value_json        jsonb,
  effective_from    date not null,
  created_by        uuid not null references profiles(id),
  created_at        timestamptz not null default now(),
  note              text,
  constraint config_settings_one_value check (
    num_nonnulls(value_numeric, value_text, value_json) = 1
  )
);
-- ADR-006: resolution is (key, scope, effective_from <= event_date) desc limit 1
create unique index config_settings_key_scope_date
  on config_settings (key, coalesce(scope_location_id, '00000000-0000-0000-0000-000000000000'::uuid), effective_from);

create table unlock_requests (
  id            uuid primary key default gen_random_uuid(),
  target_type   unlock_target not null,
  target_id     uuid not null,
  requested_by  uuid not null references profiles(id),
  reason        text not null,
  status        unlock_status not null default 'PENDING',
  decided_by    uuid references profiles(id),
  decided_at    timestamptz,
  decision_note text,
  expires_at    timestamptz,
  created_at    timestamptz not null default now()
);
create index unlock_requests_target on unlock_requests (target_type, target_id, status);

create table audit_log (
  id              uuid primary key default gen_random_uuid(),
  table_name      text not null,
  row_id          uuid,
  action          text not null,
  actor_id        uuid references profiles(id),
  actor_role      user_role,
  event_date      date,
  before          jsonb,
  after           jsonb,
  reason          text,
  idempotency_key uuid,
  created_at      timestamptz not null default now()
);
create index audit_log_row on audit_log (table_name, row_id, created_at desc);

create table notifications (
  id          uuid primary key default gen_random_uuid(),
  kind        notification_kind not null,
  target_role user_role,
  location_id uuid references locations(id),
  lot_id      uuid,                        -- FK added after lots exists
  payload     jsonb,
  created_at  timestamptz not null default now(),
  read_at     timestamptz,
  read_by     uuid references profiles(id)
);
create index notifications_unread on notifications (target_role, created_at desc) where read_at is null;
