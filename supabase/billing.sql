-- Honestech Mobile Mechanic App: subscriptions (run after schema.sql)
-- Supabase → SQL Editor → New query → paste → Run. Safe to run more than once.

alter table public.shops add column if not exists trial_ends timestamptz not null default (now() + interval '30 days');

create table if not exists public.subscriptions (
  shop_id uuid primary key references public.shops(id) on delete cascade,
  status text not null default 'none',          -- none | trialing | active | past_due | canceled | unpaid
  plan text,                                    -- solo | team
  seats int not null default 1,
  stripe_customer text,
  stripe_subscription text unique,
  current_period_end timestamptz,
  comp boolean not null default false,          -- free forever (your own shop)
  updated_at timestamptz not null default now()
);
alter table public.subscriptions enable row level security;
drop policy if exists subs_member_read on public.subscriptions;
create policy subs_member_read on public.subscriptions for select using (public.is_member(shop_id));
-- (only the Stripe connector, using the service key, can write)

-- What the app asks: "what's my plan?"
create or replace function public.my_plan() returns json
language plpgsql security definer set search_path = public as $$
declare s uuid; r json;
begin
  s := public.my_shop();
  select json_build_object(
    'shop_id', sh.id,
    'trial_ends', sh.trial_ends,
    'status', coalesce(sub.status,'none'),
    'plan', sub.plan,
    'seats', coalesce(sub.seats,1),
    'period_end', sub.current_period_end,
    'comp', coalesce(sub.comp,false),
    'role', (select role from shop_members where shop_id = sh.id and user_id = auth.uid())
  ) into r
  from shops sh left join subscriptions sub on sub.shop_id = sh.id where sh.id = s;
  return r;
end $$;
grant execute on function public.my_plan() to authenticated;

-- Make YOUR shop free forever: put your sign-in email below, then run just this part.
-- update public.subscriptions set comp = true where shop_id = (select m.shop_id from public.shop_members m join auth.users u on u.id = m.user_id where u.email = 'YOUR-EMAIL-HERE' limit 1);
-- insert into public.subscriptions (shop_id, comp, status) select m.shop_id, true, 'active' from public.shop_members m join auth.users u on u.id = m.user_id where u.email = 'YOUR-EMAIL-HERE' on conflict (shop_id) do update set comp = true;
