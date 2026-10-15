-- Honestech Mobile Mechanic App: cloud photos, videos and receipts (run after team.sql)
-- Supabase → SQL Editor → New query → paste → Run. Safe to run more than once.

-- A private bucket. Each shop's files live in a folder named after the shop.
insert into storage.buckets (id, name, public, file_size_limit)
values ('media', 'media', false, 52428800)   -- 50 MB per file
on conflict (id) do update set public = false, file_size_limit = 52428800;

-- Is the signed-in user in the shop whose folder this is?
create or replace function public.is_member_txt(s text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from shop_members where shop_id::text = s and user_id = auth.uid())
$$;
grant execute on function public.is_member_txt(text) to authenticated;

drop policy if exists media_read on storage.objects;
drop policy if exists media_insert on storage.objects;
drop policy if exists media_update on storage.objects;
drop policy if exists media_delete on storage.objects;
create policy media_read on storage.objects for select to authenticated
  using (bucket_id = 'media' and public.is_member_txt((storage.foldername(name))[1]));
create policy media_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'media' and public.is_member_txt((storage.foldername(name))[1]));
create policy media_update on storage.objects for update to authenticated
  using (bucket_id = 'media' and public.is_member_txt((storage.foldername(name))[1]))
  with check (bucket_id = 'media' and public.is_member_txt((storage.foldername(name))[1]));
create policy media_delete on storage.objects for delete to authenticated
  using (bucket_id = 'media' and public.is_member_txt((storage.foldername(name))[1]));
