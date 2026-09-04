-- ============================================================
-- Budget Buddy — database schema
-- Run this once in your Supabase project's SQL Editor
-- (Project: https://pilgamuburdkpdfsuirk.supabase.co — a dedicated
-- project for Budget Buddy, separate from Task Planner. Auth/login
-- lives here independently: a Budget Buddy account is a normal
-- Supabase Auth user in this project only.)
--
-- If you already ran an earlier version of this file, it's safe to
-- run again — every statement below uses IF NOT EXISTS / ON CONFLICT
-- so it won't duplicate tables or wipe existing data.
-- ============================================================

-- Entries: one row per income/expense/asset/liability line item.
-- Liabilities that are loans carry extra columns (nullable for
-- everything else) so a single liability entry can also track an
-- amortizing loan.
create table if not exists bb_entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  category text not null check (category in ('income', 'expense', 'asset', 'liability')),
  description text not null,
  amount numeric(14,2) not null check (amount >= 0),
  created_at timestamptz not null default now(),

  -- Loan-tracking columns (only used when category = 'liability' and is_loan = true)
  is_loan boolean not null default false,
  loan_type text check (loan_type in ('mortgage', 'car', 'personal')),
  rate_type text check (rate_type in ('fixed', 'prime_plus')),
  fixed_rate numeric(6,4),        -- annual rate as a fraction, e.g. 0.115 = 11.5% (only when rate_type = 'fixed')
  prime_margin numeric(6,4),      -- margin added to prime, e.g. 0.005 = prime + 0.5% (only when rate_type = 'prime_plus')
  principal numeric(14,2),        -- original amount borrowed
  term_months integer,            -- original loan term
  start_date date,                -- date the loan started (used to work out months elapsed / remaining balance)

  -- Recurring payment columns (only used for category = 'income' or 'expense')
  is_recurring boolean not null default false,
  recurrence_frequency text check (recurrence_frequency in ('weekly', 'biweekly', 'monthly', 'annual')),
  recurrence_next_date date,      -- the next (or first) date this income/expense is due/received; future occurrences are worked out from this anchor date + frequency

  -- Custom tags: comma-separated free text, e.g. "groceries,essential"
  tags text,

  -- Receipt photo: storage path in the 'receipts' bucket (expenses only), e.g. "<user_id>/<entry_id>/photo.jpg"
  receipt_path text,

  -- Tax set-aside (income only): percentage of this untaxed (freelance/
  -- business) income entry to hold back from the predicted balance and
  -- forecast. General calculator only — not tax advice.
  tax_set_aside_pct numeric(5,2) check (tax_set_aside_pct is null or (tax_set_aside_pct >= 0 and tax_set_aside_pct <= 100))
);

-- If you're re-running this against a database created before loan
-- tracking existed, this adds the new columns without touching data:
alter table bb_entries add column if not exists is_loan boolean not null default false;
alter table bb_entries add column if not exists loan_type text;
alter table bb_entries add column if not exists rate_type text;
alter table bb_entries add column if not exists fixed_rate numeric(6,4);
alter table bb_entries add column if not exists prime_margin numeric(6,4);
alter table bb_entries add column if not exists principal numeric(14,2);
alter table bb_entries add column if not exists term_months integer;
alter table bb_entries add column if not exists start_date date;
alter table bb_entries add column if not exists is_recurring boolean not null default false;
alter table bb_entries add column if not exists recurrence_frequency text;
alter table bb_entries add column if not exists recurrence_next_date date;
alter table bb_entries add column if not exists tags text;
alter table bb_entries add column if not exists receipt_path text;
alter table bb_entries add column if not exists tax_set_aside_pct numeric(5,2);

create index if not exists bb_entries_user_category_idx
  on bb_entries (user_id, category);

-- Settings: kept for backward compatibility (no longer used for balances —
-- see bb_accounts below, which supports more than one account per user).
create table if not exists bb_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  starting_bank_balance numeric(14,2) not null default 0,
  savings_balance numeric(14,2) not null default 0,
  updated_at timestamptz not null default now()
);

-- Accounts: a user can have any number of bank accounts and any number of
-- savings accounts (e.g. "FNB Cheque", "Capitec Savings", "Discovery Save").
-- Predicted Bank Balance = sum of all 'bank' accounts + income - expenses.
-- Total Savings = sum of all 'savings' accounts.
create table if not exists bb_accounts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  account_type text not null check (account_type in ('bank', 'savings')),
  starting_balance numeric(14,2) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists bb_accounts_user_type_idx
  on bb_accounts (user_id, account_type);

-- Prime rate: a single shared row (not per-user). Every prime-linked
-- loan reads this value, so updating it once here updates every
-- prime-linked loan's rate and payment across the whole app instantly.
-- Regular users can only READ this table — it's kept up to date by a
-- scheduled task writing with the Supabase service role key, which
-- bypasses RLS entirely (no write policy is defined for normal users
-- below on purpose).
create table if not exists bb_prime_rate (
  id int primary key default 1,
  rate numeric(6,4) not null,       -- annual prime rate as a fraction, e.g. 0.105 = 10.5%
  updated_at timestamptz not null default now(),
  source text,                      -- where the rate was confirmed from, for transparency
  constraint bb_prime_rate_single_row check (id = 1)
);

insert into bb_prime_rate (id, rate, source)
values (1, 0.105, 'Seeded manually — South African prime rate, August 2026')
on conflict (id) do nothing;

-- Scenarios: NPV/IRR cash-flow scenario comparison (Scenarios menu tab).
-- A scenario is a named set of cash flows at a discount rate — general
-- purpose, so it works for comparing loan offers, investments, or any
-- decision with cash flows over time (same approach as the Loan Decision
-- Toolkit workbook). Period 0 is normally the initial outlay/investment
-- (usually negative); periods 1+ are the cash flows that follow.
create table if not exists bb_scenarios (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  discount_rate numeric(6,4) not null default 0.10,  -- annual/period discount rate as a fraction, e.g. 0.115 = 11.5%
  created_at timestamptz not null default now()
);

create table if not exists bb_scenario_cashflows (
  id uuid primary key default gen_random_uuid(),
  scenario_id uuid not null references bb_scenarios(id) on delete cascade,
  period integer not null,      -- 0 = initial outlay, 1, 2, 3... = subsequent periods
  amount numeric(14,2) not null,-- negative for cash out, positive for cash in
  created_at timestamptz not null default now()
);

create index if not exists bb_scenarios_user_idx on bb_scenarios (user_id);
create index if not exists bb_scenario_cashflows_scenario_idx on bb_scenario_cashflows (scenario_id);

-- Goals: savings goals with progress rings on the Dashboard. current_amount
-- is updated manually by the user (via the "Update" button on each goal
-- card) — it isn't tied to any account automatically, since one goal is
-- often only part of a broader savings balance.
create table if not exists bb_goals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  target_amount numeric(14,2) not null check (target_amount > 0),
  current_amount numeric(14,2) not null default 0,
  target_date date,
  created_at timestamptz not null default now()
);

create index if not exists bb_goals_user_idx on bb_goals (user_id);

-- Balance snapshots: powers the Savings Streak counter. One row per
-- user/month — start_balance is set the first time the app is opened that
-- month, end_balance is kept current on every later visit within the same
-- month. A streak counts back from the current month while each month's
-- end_balance is higher than its start_balance.
create table if not exists bb_balance_snapshots (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  year integer not null,
  month integer not null check (month between 0 and 11),
  start_balance numeric(14,2) not null,
  end_balance numeric(14,2) not null,
  updated_at timestamptz not null default now(),
  unique (user_id, year, month)
);

create index if not exists bb_balance_snapshots_user_idx on bb_balance_snapshots (user_id);

-- Budgets: a monthly spending limit per tag, compared live against actual
-- tagged expenses for the current calendar month (Budget vs Actual on the
-- Dashboard) — "actual" is computed in the app, not stored here.
create table if not exists bb_budgets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  tag text not null,
  monthly_amount numeric(14,2) not null check (monthly_amount > 0),
  created_at timestamptz not null default now(),
  unique (user_id, tag)
);

create index if not exists bb_budgets_user_idx on bb_budgets (user_id);

-- ============================================================
-- Receipt photo storage (Receipt Photo Capture feature)
-- Private bucket — files are only readable via short-lived signed URLs
-- generated for the owning user, never public.
-- ============================================================
insert into storage.buckets (id, name, public)
values ('receipts', 'receipts', false)
on conflict (id) do nothing;

drop policy if exists "receipts: users can upload own" on storage.objects;
create policy "receipts: users can upload own" on storage.objects
  for insert with check (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "receipts: users can view own" on storage.objects;
create policy "receipts: users can view own" on storage.objects
  for select using (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "receipts: users can delete own" on storage.objects;
create policy "receipts: users can delete own" on storage.objects
  for delete using (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text);

-- ============================================================
-- Row Level Security: every user can only ever see/change their own rows
-- ============================================================
alter table bb_entries enable row level security;
alter table bb_settings enable row level security;
alter table bb_prime_rate enable row level security;
alter table bb_accounts enable row level security;
alter table bb_scenarios enable row level security;
alter table bb_scenario_cashflows enable row level security;
alter table bb_goals enable row level security;
alter table bb_balance_snapshots enable row level security;
alter table bb_budgets enable row level security;

-- drop-then-create makes this whole file safe to run more than once
-- (Postgres doesn't support "create policy if not exists")
drop policy if exists "bb_entries: select own" on bb_entries;
create policy "bb_entries: select own" on bb_entries
  for select using (auth.uid() = user_id);
drop policy if exists "bb_entries: insert own" on bb_entries;
create policy "bb_entries: insert own" on bb_entries
  for insert with check (auth.uid() = user_id);
drop policy if exists "bb_entries: update own" on bb_entries;
create policy "bb_entries: update own" on bb_entries
  for update using (auth.uid() = user_id);
drop policy if exists "bb_entries: delete own" on bb_entries;
create policy "bb_entries: delete own" on bb_entries
  for delete using (auth.uid() = user_id);

drop policy if exists "bb_settings: select own" on bb_settings;
create policy "bb_settings: select own" on bb_settings
  for select using (auth.uid() = user_id);
drop policy if exists "bb_settings: insert own" on bb_settings;
create policy "bb_settings: insert own" on bb_settings
  for insert with check (auth.uid() = user_id);
drop policy if exists "bb_settings: update own" on bb_settings;
create policy "bb_settings: update own" on bb_settings
  for update using (auth.uid() = user_id);

-- Any logged-in user can read AND update the prime rate (it's a single
-- shared row, manually kept current from inside the app for now — see
-- the pencil icon next to the prime rate badge on the Liabilities tab).
-- No insert/delete policy is defined, so the row can only be edited, not
-- duplicated or removed, by a normal user.
drop policy if exists "bb_prime_rate: select all authenticated" on bb_prime_rate;
create policy "bb_prime_rate: select all authenticated" on bb_prime_rate
  for select using (auth.role() = 'authenticated');
drop policy if exists "bb_prime_rate: update all authenticated" on bb_prime_rate;
create policy "bb_prime_rate: update all authenticated" on bb_prime_rate
  for update using (auth.role() = 'authenticated');

drop policy if exists "bb_accounts: select own" on bb_accounts;
create policy "bb_accounts: select own" on bb_accounts
  for select using (auth.uid() = user_id);
drop policy if exists "bb_accounts: insert own" on bb_accounts;
create policy "bb_accounts: insert own" on bb_accounts
  for insert with check (auth.uid() = user_id);
drop policy if exists "bb_accounts: update own" on bb_accounts;
create policy "bb_accounts: update own" on bb_accounts
  for update using (auth.uid() = user_id);
drop policy if exists "bb_accounts: delete own" on bb_accounts;
create policy "bb_accounts: delete own" on bb_accounts
  for delete using (auth.uid() = user_id);

drop policy if exists "bb_scenarios: select own" on bb_scenarios;
create policy "bb_scenarios: select own" on bb_scenarios
  for select using (auth.uid() = user_id);
drop policy if exists "bb_scenarios: insert own" on bb_scenarios;
create policy "bb_scenarios: insert own" on bb_scenarios
  for insert with check (auth.uid() = user_id);
drop policy if exists "bb_scenarios: update own" on bb_scenarios;
create policy "bb_scenarios: update own" on bb_scenarios
  for update using (auth.uid() = user_id);
drop policy if exists "bb_scenarios: delete own" on bb_scenarios;
create policy "bb_scenarios: delete own" on bb_scenarios
  for delete using (auth.uid() = user_id);

-- bb_scenario_cashflows has no user_id column of its own, so its policies
-- check ownership via the parent scenario row instead.
drop policy if exists "bb_scenario_cashflows: select own" on bb_scenario_cashflows;
create policy "bb_scenario_cashflows: select own" on bb_scenario_cashflows
  for select using (exists (
    select 1 from bb_scenarios s where s.id = scenario_id and s.user_id = auth.uid()
  ));
drop policy if exists "bb_scenario_cashflows: insert own" on bb_scenario_cashflows;
create policy "bb_scenario_cashflows: insert own" on bb_scenario_cashflows
  for insert with check (exists (
    select 1 from bb_scenarios s where s.id = scenario_id and s.user_id = auth.uid()
  ));
drop policy if exists "bb_scenario_cashflows: delete own" on bb_scenario_cashflows;
create policy "bb_scenario_cashflows: delete own" on bb_scenario_cashflows
  for delete using (exists (
    select 1 from bb_scenarios s where s.id = scenario_id and s.user_id = auth.uid()
  ));

drop policy if exists "bb_goals: select own" on bb_goals;
create policy "bb_goals: select own" on bb_goals
  for select using (auth.uid() = user_id);
drop policy if exists "bb_goals: insert own" on bb_goals;
create policy "bb_goals: insert own" on bb_goals
  for insert with check (auth.uid() = user_id);
drop policy if exists "bb_goals: update own" on bb_goals;
create policy "bb_goals: update own" on bb_goals
  for update using (auth.uid() = user_id);
drop policy if exists "bb_goals: delete own" on bb_goals;
create policy "bb_goals: delete own" on bb_goals
  for delete using (auth.uid() = user_id);

drop policy if exists "bb_balance_snapshots: select own" on bb_balance_snapshots;
create policy "bb_balance_snapshots: select own" on bb_balance_snapshots
  for select using (auth.uid() = user_id);
drop policy if exists "bb_balance_snapshots: insert own" on bb_balance_snapshots;
create policy "bb_balance_snapshots: insert own" on bb_balance_snapshots
  for insert with check (auth.uid() = user_id);
drop policy if exists "bb_balance_snapshots: update own" on bb_balance_snapshots;
create policy "bb_balance_snapshots: update own" on bb_balance_snapshots
  for update using (auth.uid() = user_id);

drop policy if exists "bb_budgets: select own" on bb_budgets;
create policy "bb_budgets: select own" on bb_budgets
  for select using (auth.uid() = user_id);
drop policy if exists "bb_budgets: insert own" on bb_budgets;
create policy "bb_budgets: insert own" on bb_budgets
  for insert with check (auth.uid() = user_id);
drop policy if exists "bb_budgets: delete own" on bb_budgets;
create policy "bb_budgets: delete own" on bb_budgets
  for delete using (auth.uid() = user_id);
