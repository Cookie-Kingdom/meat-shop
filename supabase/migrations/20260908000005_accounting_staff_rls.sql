-- ER diagram 4: accounting and staff, then RLS across everything.

create table owner_expenses (
  id            uuid primary key default gen_random_uuid(),
  kind          expense_kind not null,
  event_date    date not null,
  expense_month text check (expense_month ~ '^\d{4}-\d{2}$'),   -- M11.5
  location_id   uuid references locations(id),                  -- null = central
  amount_thb    numeric(12,2) not null check (amount_thb >= 0),
  detail        text,
  created_by    uuid not null references profiles(id),
  created_at    timestamptz not null default now()
);

create table staff (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  location_id     uuid not null references locations(id),
  employment_type text not null check (employment_type in ('DAILY','MONTHLY')),
  is_active       boolean not null default true
);

create table attendance (
  id          uuid primary key default gen_random_uuid(),
  staff_id    uuid not null references staff(id),
  location_id uuid not null references locations(id),
  event_date  date not null,
  status      text not null check (status in ('PRESENT','ABSENT','LEAVE')),
  recorded_by uuid not null references profiles(id),
  created_at  timestamptz not null default now(),
  unique (staff_id, event_date)
);

-- ADR-002 / ADR-004: every write goes through a SECURITY DEFINER fn_*, every read through
-- a role-specific v_*. RLS on with no policy = deny-all for anon and authenticated, which
-- is exactly the posture we want until those functions and views exist.
do $$
declare t text;
begin
  for t in
    select tablename from pg_tables
     where schemaname = 'public'
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;
