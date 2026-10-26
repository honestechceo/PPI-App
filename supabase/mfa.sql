-- Honestech Mobile Mechanic App: two-step sign-in (authenticator app codes)
-- Supabase → SQL Editor → New query → paste → Run. Safe to run more than once.
-- Anyone who turned on two-step sign-in can only read or change shop data after entering their 6-digit code.
-- People who haven't turned it on are not affected.

create or replace function public.mfa_ok() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(auth.jwt()->>'aal', 'aal1') = 'aal2'
      or not exists (select 1 from auth.mfa_factors f where f.user_id = auth.uid() and f.status = 'verified');
$$;
grant execute on function public.mfa_ok() to authenticated;

do $$
declare t text;
begin
  foreach t in array array['records','shops','shop_members','subscriptions','invites','push_subs','gifts'] loop
    execute format('drop policy if exists mfa_required on public.%I', t);
    execute format('create policy mfa_required on public.%I as restrictive for all to authenticated using (public.mfa_ok()) with check (public.mfa_ok())', t);
  end loop;
end $$;

drop policy if exists mfa_required_media on storage.objects;
create policy mfa_required_media on storage.objects as restrictive for all to authenticated
  using (bucket_id <> 'media' or public.mfa_ok()) with check (bucket_id <> 'media' or public.mfa_ok());
