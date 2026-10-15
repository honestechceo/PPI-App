-- Honestech Mobile Mechanic App: push notifications (run after team.sql)
-- Supabase → SQL Editor → New query → paste → Run. Safe to run more than once.

-- Each phone that allowed notifications.
create table if not exists public.push_subs (
  endpoint text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  p256dh text not null,
  auth text not null,
  ua text,
  created_at timestamptz not null default now()
);
alter table public.push_subs enable row level security;
drop policy if exists push_own on public.push_subs;
create policy push_own on public.push_subs for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- The app's notification keys (made automatically the first time; only the server can read them).
create table if not exists public.push_keys (
  id int primary key default 1 check (id = 1),
  public_key text not null,
  private_key text not null,
  created_at timestamptz not null default now()
);
alter table public.push_keys enable row level security;
-- no policies: only the server function (service role) can read it
