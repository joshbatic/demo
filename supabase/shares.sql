-- *[demo] share links: a song anyone can open at hellodemo.app/s/?<id>, no account needed.
-- Run once in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- What's in it
--   shares        one row per shared song: a snapshot (title, lyrics, timings, colours, waveform) as JSON.
--                 Only the owner can see, add, change or delete their rows directly...
--   get_share()   ...and the public reads ONE share by its id through this function, so nobody can list
--                 everyone's shares; they need the exact (random, 10-character) id from the link.
--   'shares'      a public storage bucket for each share's artwork and audio, under <user id>/<share id>/.
--                 Files are readable by their URL; only the owner can add, replace or delete them, and
--                 nobody can list the bucket.

create table if not exists public.shares (
  id          text primary key check (id ~ '^[A-Za-z0-9]{10}$'),
  owner       uuid not null default auth.uid() references auth.users(id) on delete cascade,
  song_id     text,
  data        jsonb not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists shares_owner_idx on public.shares(owner);

alter table public.shares enable row level security;

drop policy if exists "shares: owner reads"   on public.shares;
drop policy if exists "shares: owner adds"    on public.shares;
drop policy if exists "shares: owner changes" on public.shares;
drop policy if exists "shares: owner deletes" on public.shares;
create policy "shares: owner reads"   on public.shares for select to authenticated using (owner = auth.uid());
create policy "shares: owner adds"    on public.shares for insert to authenticated with check (owner = auth.uid());
create policy "shares: owner changes" on public.shares for update to authenticated using (owner = auth.uid()) with check (owner = auth.uid());
create policy "shares: owner deletes" on public.shares for delete to authenticated using (owner = auth.uid());

-- the one public door: fetch a single share's snapshot by id
create or replace function public.get_share(sid text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select data || jsonb_build_object('updated', extract(epoch from updated_at)::bigint)
  from public.shares where id = sid
$$;
revoke all on function public.get_share(text) from public;
grant execute on function public.get_share(text) to anon, authenticated;

-- artwork and audio for shared songs
insert into storage.buckets (id, name, public)
values ('shares', 'shares', true)
on conflict (id) do update set public = true;

drop policy if exists "shares files: add own"    on storage.objects;
drop policy if exists "shares files: change own" on storage.objects;
drop policy if exists "shares files: delete own" on storage.objects;
drop policy if exists "shares files: list own"   on storage.objects;
create policy "shares files: add own" on storage.objects for insert to authenticated
  with check (bucket_id = 'shares' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "shares files: change own" on storage.objects for update to authenticated
  using (bucket_id = 'shares' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'shares' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "shares files: delete own" on storage.objects for delete to authenticated
  using (bucket_id = 'shares' and (storage.foldername(name))[1] = auth.uid()::text);
-- (upserting a file needs to read it first, so owners can see their own; the public still can't list)
create policy "shares files: list own" on storage.objects for select to authenticated
  using (bucket_id = 'shares' and (storage.foldername(name))[1] = auth.uid()::text);
