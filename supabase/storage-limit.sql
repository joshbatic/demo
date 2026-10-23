-- NOTE (23 Oct 2026): plans.sql replaces my_storage() and storage_has_room() below with plan-aware versions
-- (Free/Pro limits). If you ever run this file again, run plans.sql straight after it, or Pro drops to 150 MB.
-- Storage limit per account (audio, voice memos, files and share-link copies).
-- New uploads are refused once an account has used its limit; replacing an existing file still works.
-- The app shows "Storage: 40 MB of 150 MB" in Account, and a clear message when it's full.
--
-- Change the limit any time in Table Editor › storage_limit (or run the update at the bottom):
--   per_account_mb = 150  → 150 MB per account (the beta setting)
--   per_account_mb = null → no limit
-- Safe to run again.

create table if not exists public.storage_limit (
  id int primary key default 1 check (id = 1),
  per_account_mb int default 150 check (per_account_mb is null or per_account_mb >= 0)
);
insert into public.storage_limit (id, per_account_mb) values (1, 150) on conflict (id) do nothing;
-- already ran this file with the old 500 MB default? Run:  update public.storage_limit set per_account_mb = 150 where id = 1;

alter table public.storage_limit enable row level security;
revoke all on public.storage_limit from anon, authenticated;

-- Bytes an account has stored, across both buckets (everything lives under a folder named after the account ID).
create or replace function public.storage_used(uid uuid)
returns bigint
language sql
stable
security definer
set search_path = public, storage
as $$
  select coalesce(sum((o.metadata->>'size')::bigint), 0)
  from storage.objects o
  where o.bucket_id in ('song-files', 'shares')
    and (storage.foldername(o.name))[1] = uid::text;
$$;
revoke execute on function public.storage_used(uuid) from public, anon, authenticated;

-- For the app: how much you've used and your limit (null limit = unlimited).
create or replace function public.my_storage()
returns table (used_bytes bigint, limit_bytes bigint)
language sql
stable
security definer
set search_path = public
as $$
  select public.storage_used(auth.uid()),
         (select per_account_mb::bigint * 1048576 from public.storage_limit where id = 1);
$$;
revoke execute on function public.my_storage() from public, anon;
grant execute on function public.my_storage() to authenticated;

-- True while the signed-in account is under its limit.
create or replace function public.storage_has_room()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select public.storage_used(auth.uid()) < per_account_mb::bigint * 1048576
       from public.storage_limit where id = 1 and per_account_mb is not null),
    true);
$$;
revoke execute on function public.storage_has_room() from public, anon;
grant execute on function public.storage_has_room() to authenticated;

-- Applies on top of the existing upload rules: a new file needs room.
drop policy if exists "storage: under limit" on storage.objects;
create policy "storage: under limit" on storage.objects as restrictive for insert to authenticated
  with check (bucket_id not in ('song-files', 'shares') or public.storage_has_room());

-- update public.storage_limit set per_account_mb = 1000 where id = 1;
