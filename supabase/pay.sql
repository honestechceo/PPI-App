-- Honestech Mobile Mechanic App: technician pay & tax info (run after team.sql)
-- Supabase → SQL Editor → New query → paste → Run. Safe to run more than once.
-- Lets each technician save their own tax info (record kind 'techinfo', id = their user id).
-- Owners/admins can read it; other technicians can't.

alter table public.records drop constraint if exists records_kind_check;
alter table public.records add constraint records_kind_check
  check (kind in ('job','customer','expense','trip','request','settings','techcfg','techinfo'));

drop policy if exists records_read on public.records;
drop policy if exists records_insert on public.records;
drop policy if exists records_update on public.records;
drop policy if exists records_delete on public.records;

create policy records_read on public.records for select using (
  public.is_manager(shop_id)
  or (public.member_role(shop_id) = 'tech' and (
        kind = 'techcfg'
     or (kind = 'job' and data->>'techUser' = auth.uid()::text)
     or (kind = 'techinfo' and id = auth.uid()::text)))
);
create policy records_insert on public.records for insert with check (
  (public.is_manager(shop_id) and kind <> 'techinfo')
  or (public.member_role(shop_id) = 'tech' and (
        (kind = 'job' and data->>'techUser' = auth.uid()::text)
     or (kind = 'techinfo' and id = auth.uid()::text)))
);
create policy records_update on public.records for update using (
  (public.is_manager(shop_id) and kind <> 'techinfo')
  or (public.member_role(shop_id) = 'tech' and (
        (kind = 'job' and data->>'techUser' = auth.uid()::text)
     or (kind = 'techinfo' and id = auth.uid()::text)))
) with check (
  (public.is_manager(shop_id) and kind <> 'techinfo')
  or (public.member_role(shop_id) = 'tech' and (
        (kind = 'job' and data->>'techUser' = auth.uid()::text)
     or (kind = 'techinfo' and id = auth.uid()::text)))
);
create policy records_delete on public.records for delete using (public.is_manager(shop_id) and kind <> 'techinfo');
