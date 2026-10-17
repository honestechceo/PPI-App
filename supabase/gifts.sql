-- Honestech Mobile Mechanic App: gift free months (run after billing.sql and team.sql)
-- Supabase → SQL Editor → New query → paste → Run. Safe to run more than once.
-- Only a comped shop (subscriptions.comp = true, i.e. the app owner) can send gifts.

create table if not exists public.gifts (
  token uuid primary key default gen_random_uuid(),
  from_shop uuid not null references public.shops(id) on delete cascade,
  created_by uuid references auth.users(id),
  months int not null default 1 check (months between 1 and 12),
  to_name text not null default '',
  to_contact text not null default '',
  created_at timestamptz not null default now(),
  redeemed_at timestamptz,
  redeemed_by uuid references auth.users(id),
  redeemed_shop uuid references public.shops(id) on delete set null
);
alter table public.gifts enable row level security;
-- No direct access; everything goes through the functions below.

create or replace function public.can_gift() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from shop_members m join subscriptions sub on sub.shop_id = m.shop_id
    where m.user_id = auth.uid() and m.role = 'owner' and coalesce(sub.comp,false))
$$;

-- Owner: make a gift link.
create or replace function public.create_gift(p_months int, p_name text, p_contact text) returns uuid
language plpgsql security definer set search_path = public as $$
declare s uuid; t uuid;
begin
  if not public.can_gift() then raise exception 'Only the app owner can send gift months'; end if;
  select m.shop_id into s from shop_members m join subscriptions sub on sub.shop_id = m.shop_id
    where m.user_id = auth.uid() and m.role = 'owner' and coalesce(sub.comp,false) limit 1;
  insert into gifts (from_shop, created_by, months, to_name, to_contact)
    values (s, auth.uid(), greatest(1, least(12, coalesce(p_months,1))), coalesce(p_name,''), coalesce(p_contact,''))
    returning token into t;
  return t;
end $$;

-- Anyone with the link: what is this gift?
create or replace function public.gift_info(p_token uuid) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'from', coalesce((select data->>'biz' from records r where r.shop_id = g.from_shop and r.kind = 'settings' and r.id = 'main'), 'Honestech'),
    'months', g.months,
    'to_name', g.to_name,
    'used', g.redeemed_at is not null,
    'expired', g.redeemed_at is null and g.created_at < now() - interval '60 days')
  from gifts g where g.token = p_token
$$;

-- The person who got the link: add the free months to their own shop.
create or replace function public.redeem_gift(p_token uuid) returns json
language plpgsql security definer set search_path = public as $$
declare g gifts; s uuid; st text; newend timestamptz;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select * into g from gifts where token = p_token for update;
  if g.token is null then raise exception 'This gift link is not valid.'; end if;
  if g.redeemed_at is not null then
    if g.redeemed_by = auth.uid() then
      return json_build_object('months', g.months, 'trial_ends', (select trial_ends from shops where id = g.redeemed_shop), 'again', true);
    end if;
    raise exception 'This gift link was already used.';
  end if;
  if g.created_at < now() - interval '60 days' then raise exception 'This gift link has expired.'; end if;
  s := public.my_shop();
  if public.member_role(s) <> 'owner' then raise exception 'Gift months go on your own account. Sign in with your own email, not a technician login.'; end if;
  if s = g.from_shop then raise exception 'You can''t use your own gift link.'; end if;
  select status into st from subscriptions where shop_id = s;
  if st in ('active','trialing','past_due') then
    raise exception 'You already have a paid plan, so the free months can''t be added here. Contact info@honestechservice.com.';
  end if;
  update shops set trial_ends = greatest(trial_ends, now()) + make_interval(days => 30 * g.months)
    where id = s returning trial_ends into newend;
  update gifts set redeemed_at = now(), redeemed_by = auth.uid(), redeemed_shop = s where token = p_token;
  return json_build_object('months', g.months, 'trial_ends', newend);
end $$;

-- Owner: gifts sent and who used them.
create or replace function public.list_gifts() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can_gift() then return '[]'::json; end if;
  return coalesce((select json_agg(json_build_object(
      'token', g.token, 'months', g.months, 'to_name', g.to_name, 'to_contact', g.to_contact,
      'created_at', g.created_at, 'redeemed_at', g.redeemed_at,
      'email', (select email from auth.users u where u.id = g.redeemed_by),
      'expired', g.redeemed_at is null and g.created_at < now() - interval '60 days')
      order by g.created_at desc)
    from gifts g where g.created_by = auth.uid()), '[]'::json);
end $$;

-- Owner: take back an unused gift link.
create or replace function public.cancel_gift(p_token uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.can_gift() then raise exception 'Only the app owner can do that'; end if;
  delete from gifts where token = p_token and created_by = auth.uid() and redeemed_at is null;
end $$;

grant execute on function public.can_gift() to authenticated;
grant execute on function public.create_gift(int, text, text) to authenticated;
grant execute on function public.gift_info(uuid) to anon, authenticated;
grant execute on function public.redeem_gift(uuid) to authenticated;
grant execute on function public.list_gifts() to authenticated;
grant execute on function public.cancel_gift(uuid) to authenticated;
