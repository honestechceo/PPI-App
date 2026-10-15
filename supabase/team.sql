-- Honestech Mobile Mechanic App: technician logins (run after schema.sql and billing.sql)
-- Supabase → SQL Editor → New query → paste → Run. Safe to run more than once.

-- 1) A shared, price-free settings record the owner publishes for techs ("techcfg").
alter table public.records drop constraint if exists records_kind_check;
alter table public.records add constraint records_kind_check
  check (kind in ('job','customer','expense','trip','request','settings','techcfg'));

-- 2) Invites: the owner creates one per technician and texts the link.
create table if not exists public.invites (
  token uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  tech_id text not null,              -- the technician's entry in the owner's Team list
  tech_name text not null default '',
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  accepted_by uuid references auth.users(id)
);
alter table public.invites enable row level security;
-- No direct access; everything goes through the functions below.

-- 3) Helpers
create or replace function public.member_role(s uuid) returns text
language sql stable security definer set search_path = public as $$
  select role from shop_members where shop_id = s and user_id = auth.uid() limit 1
$$;
create or replace function public.is_manager(s uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.member_role(s) in ('owner','admin'), false)
$$;

-- The shop you work in. Newest membership wins, so a tech who joins a shop lands there.
create or replace function public.my_shop() returns uuid
language plpgsql security definer set search_path = public as $$
declare s uuid;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select shop_id into s from shop_members where user_id = auth.uid() order by created_at desc limit 1;
  if s is null then
    insert into shops default values returning id into s;
    insert into shop_members (shop_id, user_id, role) values (s, auth.uid(), 'owner');
  end if;
  return s;
end $$;

-- How many technicians this shop may have.
create or replace function public.tech_allowance(s uuid) returns int
language sql stable security definer set search_path = public as $$
  select case
    when coalesce(sub.comp,false) then 50
    when sub.status in ('active','trialing','past_due') and sub.plan = 'team' then greatest(coalesce(sub.seats,2),2)
    when sub.status in ('active','trialing','past_due') then 0
    when sh.trial_ends > now() then 2
    else 0 end
  from shops sh left join subscriptions sub on sub.shop_id = sh.id where sh.id = s
$$;

-- 4) Records: owners/admins see everything; techs only their assigned jobs and the techcfg record.
drop policy if exists records_rw on public.records;
drop policy if exists records_read on public.records;
drop policy if exists records_insert on public.records;
drop policy if exists records_update on public.records;
drop policy if exists records_delete on public.records;
create policy records_read on public.records for select using (
  public.is_manager(shop_id)
  or (public.member_role(shop_id) = 'tech' and (kind = 'techcfg' or (kind = 'job' and data->>'techUser' = auth.uid()::text)))
);
create policy records_insert on public.records for insert with check (
  public.is_manager(shop_id)
  or (public.member_role(shop_id) = 'tech' and kind = 'job' and data->>'techUser' = auth.uid()::text)
);
create policy records_update on public.records for update using (
  public.is_manager(shop_id)
  or (public.member_role(shop_id) = 'tech' and kind = 'job' and data->>'techUser' = auth.uid()::text)
) with check (
  public.is_manager(shop_id)
  or (public.member_role(shop_id) = 'tech' and kind = 'job' and data->>'techUser' = auth.uid()::text)
);
create policy records_delete on public.records for delete using (public.is_manager(shop_id));

-- 5) Owner: create an invite link for a technician (checks the plan's technician limit).
create or replace function public.create_invite(p_tech_id text, p_tech_name text) returns uuid
language plpgsql security definer set search_path = public as $$
declare s uuid := public.my_shop(); used int; allowed int; t uuid;
begin
  if not public.is_manager(s) then raise exception 'Only the shop owner can invite technicians'; end if;
  -- Re-inviting the same tech replaces their old, unused link.
  delete from invites where shop_id = s and tech_id = p_tech_id and accepted_at is null;
  select count(*) into used from (
    select user_id::text from shop_members where shop_id = s and role = 'tech'
    union all
    select token::text from invites where shop_id = s and accepted_at is null and created_at > now() - interval '14 days'
  ) x;
  allowed := public.tech_allowance(s);
  if used >= allowed then
    raise exception 'TECH_LIMIT:%', allowed;
  end if;
  insert into invites (shop_id, tech_id, tech_name, created_by) values (s, p_tech_id, coalesce(p_tech_name,''), auth.uid()) returning token into t;
  return t;
end $$;

-- 6) Anyone with the link: which shop is this invite for?
create or replace function public.invite_info(p_token uuid) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'shop', coalesce((select data->>'biz' from records r where r.shop_id = i.shop_id and r.kind = 'settings' and r.id = 'main'), 'a shop'),
    'tech_name', i.tech_name,
    'used', i.accepted_at is not null,
    'expired', i.created_at < now() - interval '14 days')
  from invites i where i.token = p_token
$$;

-- 7) Technician: accept the invite after signing in.
create or replace function public.accept_invite(p_token uuid) returns json
language plpgsql security definer set search_path = public as $$
declare i invites;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select * into i from invites where token = p_token for update;
  if i.token is null then raise exception 'This invite link is not valid. Ask the owner for a new one.'; end if;
  if i.accepted_at is not null and i.accepted_by <> auth.uid() then raise exception 'This invite link was already used. Ask the owner for a new one.'; end if;
  if i.created_at < now() - interval '14 days' then raise exception 'This invite link has expired. Ask the owner for a new one.'; end if;
  if exists (select 1 from shop_members where shop_id = i.shop_id and user_id = auth.uid() and role in ('owner','admin')) then
    raise exception 'You are already the owner of this shop.';
  end if;
  insert into shop_members (shop_id, user_id, role) values (i.shop_id, auth.uid(), 'tech')
    on conflict (shop_id, user_id) do update set role = 'tech', created_at = now();
  update invites set accepted_at = now(), accepted_by = auth.uid() where token = p_token;
  return json_build_object('shop_id', i.shop_id, 'tech_id', i.tech_id);
end $$;

-- 8) Owner: who has joined, and which links are still open.
create or replace function public.team_status() returns json
language plpgsql stable security definer set search_path = public as $$
declare s uuid;
begin
  select shop_id into s from shop_members where user_id = auth.uid() order by created_at desc limit 1;
  if s is null or not public.is_manager(s) then return '[]'::json; end if;
  return coalesce((select json_agg(json_build_object(
      'tech_id', i.tech_id, 'token', i.token, 'created_at', i.created_at,
      'accepted_at', i.accepted_at, 'user_id', i.accepted_by,
      'email', (select email from auth.users u where u.id = i.accepted_by),
      'active', i.accepted_by is not null and exists (select 1 from shop_members m where m.shop_id = s and m.user_id = i.accepted_by and m.role = 'tech'))
      order by i.created_at desc)
    from invites i where i.shop_id = s), '[]'::json);
end $$;

-- 9) Owner: remove a technician's access right away.
create or replace function public.remove_tech(p_tech_id text) returns void
language plpgsql security definer set search_path = public as $$
declare s uuid := public.my_shop();
begin
  if not public.is_manager(s) then raise exception 'Only the shop owner can remove technicians'; end if;
  delete from shop_members m using invites i
    where i.shop_id = s and i.tech_id = p_tech_id and m.shop_id = s and m.user_id = i.accepted_by and m.role = 'tech';
  delete from invites where shop_id = s and tech_id = p_tech_id;
end $$;

grant execute on function public.my_shop() to authenticated;
grant execute on function public.member_role(uuid) to authenticated;
grant execute on function public.is_manager(uuid) to authenticated;
grant execute on function public.tech_allowance(uuid) to authenticated;
grant execute on function public.create_invite(text, text) to authenticated;
grant execute on function public.invite_info(uuid) to anon, authenticated;
grant execute on function public.accept_invite(uuid) to authenticated;
grant execute on function public.team_status() to authenticated;
grant execute on function public.remove_tech(text) to authenticated;
