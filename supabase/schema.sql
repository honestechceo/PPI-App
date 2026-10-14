-- Honestech Mobile Mechanic App: cloud sync database
-- Paste this whole file into Supabase → SQL Editor → New query → Run.
-- Safe to run more than once.

-- A "shop" is one business. Today it's just you; techs can join it later.
create table if not exists public.shops (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'My shop',
  created_at timestamptz not null default now()
);

create table if not exists public.shop_members (
  shop_id uuid not null references public.shops(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'owner' check (role in ('owner','admin','tech')),
  created_at timestamptz not null default now(),
  primary key (shop_id, user_id)
);

-- Every record the app keeps (jobs, customers, expenses, trips, requests, settings)
-- is one row. "data" holds the record exactly as the app stores it.
create table if not exists public.records (
  shop_id uuid not null references public.shops(id) on delete cascade,
  kind text not null check (kind in ('job','customer','expense','trip','request','settings')),
  id text not null,
  data jsonb not null,
  deleted boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),
  primary key (shop_id, kind, id)
);
create index if not exists records_sync_idx on public.records (shop_id, updated_at);

-- Server sets the time so phones with wrong clocks can't break syncing.
create or replace function public.touch_record() returns trigger language plpgsql as $$
begin new.updated_at := now(); new.updated_by := auth.uid(); return new; end $$;
drop trigger if exists records_touch on public.records;
create trigger records_touch before insert or update on public.records
  for each row execute function public.touch_record();

-- Is the signed-in user a member of this shop?
create or replace function public.is_member(s uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from shop_members where shop_id = s and user_id = auth.uid())
$$;

-- First sign-in: create a shop for this user (or return the one they already have).
create or replace function public.my_shop() returns uuid
language plpgsql security definer set search_path = public as $$
declare s uuid;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select shop_id into s from shop_members where user_id = auth.uid() order by created_at limit 1;
  if s is null then
    insert into shops default values returning id into s;
    insert into shop_members (shop_id, user_id, role) values (s, auth.uid(), 'owner');
  end if;
  return s;
end $$;

-- Row-level security: each shop only ever sees its own data.
alter table public.shops enable row level security;
alter table public.shop_members enable row level security;
alter table public.records enable row level security;

drop policy if exists shops_member on public.shops;
create policy shops_member on public.shops for select using (public.is_member(id));

drop policy if exists members_self on public.shop_members;
create policy members_self on public.shop_members for select using (public.is_member(shop_id));

drop policy if exists records_rw on public.records;
create policy records_rw on public.records for all
  using (public.is_member(shop_id)) with check (public.is_member(shop_id));

grant execute on function public.my_shop() to authenticated;
grant execute on function public.is_member(uuid) to authenticated;
