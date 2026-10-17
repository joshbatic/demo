-- *[demo] muse memory: what each writer does with the muse's suggestions, and the voice profile learned from it.
-- Run once in the Supabase dashboard: SQL Editor -> New query -> paste -> Run. Safe to run again.
--
-- muse_events   one row per suggestion outcome: kept as written, edited (with the writer's own version),
--               deleted, thrown out with a reason ("Not this"), or a batch passed over for new ideas.
-- muse_profile  one row per writer: a short description of how they write, learned from their songs and
--               the events above. They can read and edit it in Writing voice.
-- Both are private: each account can only see and change its own rows.

create table if not exists public.muse_events (
  id          text primary key,
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  song_id     text,
  src         text,
  outcome     text not null check (outcome in ('kept','edited','deleted','reject','passed')),
  shown       text,
  final       text,
  reason      text,
  created_at  timestamptz not null default now()
);
create index if not exists muse_events_user_idx on public.muse_events(user_id, created_at desc);
alter table public.muse_events enable row level security;

drop policy if exists "muse_events: own read"   on public.muse_events;
drop policy if exists "muse_events: own add"    on public.muse_events;
drop policy if exists "muse_events: own delete" on public.muse_events;
create policy "muse_events: own read"   on public.muse_events for select to authenticated using (user_id = auth.uid());
create policy "muse_events: own add"    on public.muse_events for insert to authenticated with check (user_id = auth.uid());
create policy "muse_events: own delete" on public.muse_events for delete to authenticated using (user_id = auth.uid());

create table if not exists public.muse_profile (
  user_id     uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  profile     text not null default '',
  edited      boolean not null default false,
  basis       integer not null default 0,
  updated_at  timestamptz not null default now()
);
alter table public.muse_profile enable row level security;

drop policy if exists "muse_profile: own read"   on public.muse_profile;
drop policy if exists "muse_profile: own add"    on public.muse_profile;
drop policy if exists "muse_profile: own change" on public.muse_profile;
create policy "muse_profile: own read"   on public.muse_profile for select to authenticated using (user_id = auth.uid());
create policy "muse_profile: own add"    on public.muse_profile for insert to authenticated with check (user_id = auth.uid());
create policy "muse_profile: own change" on public.muse_profile for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
