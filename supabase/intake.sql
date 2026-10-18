-- Honestech Mobile Mechanic App: automatic requests (website forms and forwarded emails)
-- Supabase → SQL Editor → New query → paste → Run. Safe to run more than once.
-- Gives each shop a private key. The key is part of the shop's form link and its forwarding email address.

create table if not exists public.intake_keys (
  shop_id uuid primary key references public.shops(id) on delete cascade,
  key text not null unique,
  created_at timestamptz not null default now()
);
alter table public.intake_keys enable row level security;   -- no policies: only the functions below and the server can read it

-- Owners/admins get their shop's key (made on first use). p_new = true makes a new one, so the old link stops working.
create or replace function public.intake_key(p_shop uuid, p_new boolean default false) returns text
language plpgsql security definer set search_path = public as $$
declare k text;
begin
  if not public.is_manager(p_shop) then raise exception 'Only the shop owner can do this'; end if;
  select key into k from intake_keys where shop_id = p_shop;
  if k is null or p_new then
    k := substr(replace(gen_random_uuid()::text, '-', ''), 1, 12);
    insert into intake_keys (shop_id, key) values (p_shop, k)
      on conflict (shop_id) do update set key = excluded.key, created_at = now();
  end if;
  return k;
end $$;
grant execute on function public.intake_key(uuid, boolean) to authenticated;
