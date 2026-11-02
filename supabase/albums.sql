-- Albums: one row per album, synced per row (last writer wins on `updated`, ms since 1970).
-- data: { id, title, kind: "Album"|"EP"|"Single", year, artist, art (data URL or ""), updated, deleted? }
-- Songs join an album through their own keys in cloud_library: song.album (album id) and song.track (order).
-- Kept out of cloud_library so older apps, which rewrite that row whole, can't drop albums.
create table if not exists public.albums (
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  id text not null check (char_length(id) between 1 and 64),
  data jsonb not null default '{}'::jsonb,
  updated double precision not null default 0,
  primary key (user_id, id)
);
alter table public.albums enable row level security;
create policy "albums: own rows" on public.albums for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
alter table public.albums add constraint albums_data_size check (pg_column_size(data) < 1500000);
grant select, insert, update, delete on public.albums to authenticated;
