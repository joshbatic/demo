-- *[demo] artist pages: artist.hellodemo.app/<username>, a link-in-bio page for every writer.
-- Run once in Supabase: SQL Editor -> New query -> paste -> Run (after shares.sql). Safe to run again.
--
-- What's in it
--   artist_pages   one row per writer: their page settings (what to show, bio, extra links) and the published
--                  snapshot the page is drawn from. Only the writer can see or change their own row.
--   get_artist()   the one public door: a page's snapshot by username, and only while the page is switched on.
--   artist_fans    "Remind me" / "Get new music first" sign-ups: an email, which page, and which song.
--                  Only the writer whose page it was can see or delete them; nobody can list anyone else's.
--   fan_signup()   how the public page adds a fan: checks the email, the page is on, and slows down floods.
-- Artwork and audio for pages go in the existing public 'shares' bucket, under <user id>/page/.

create table if not exists public.artist_pages (
  user_id     uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  enabled     boolean not null default false,
  settings    jsonb not null default '{}'::jsonb,
  data        jsonb,
  updated_at  timestamptz not null default now()
);
alter table public.artist_pages enable row level security;

drop policy if exists "artist_pages: own read"   on public.artist_pages;
drop policy if exists "artist_pages: own add"    on public.artist_pages;
drop policy if exists "artist_pages: own change" on public.artist_pages;
drop policy if exists "artist_pages: own delete" on public.artist_pages;
create policy "artist_pages: own read"   on public.artist_pages for select to authenticated using (user_id = auth.uid());
create policy "artist_pages: own add"    on public.artist_pages for insert to authenticated with check (user_id = auth.uid());
create policy "artist_pages: own change" on public.artist_pages for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "artist_pages: own delete" on public.artist_pages for delete to authenticated using (user_id = auth.uid());

-- a page by username (any capitals), only while it's switched on; the username always comes from the profile
-- as it is now, so changing your username moves your page with it
create or replace function public.get_artist(name text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select a.data || jsonb_build_object('username', p.username, 'updated', extract(epoch from a.updated_at)::bigint)
  from public.profiles p
  join public.artist_pages a on a.user_id = p.user_id
  where p.username is not null and lower(p.username) = lower(name) and a.enabled and a.data is not null
  order by p.updated_at desc nulls last
  limit 1
$$;
revoke all on function public.get_artist(text) from public;
grant execute on function public.get_artist(text) to anon, authenticated;

create table if not exists public.artist_fans (
  id          uuid primary key default gen_random_uuid(),
  artist_id   uuid not null references auth.users(id) on delete cascade,
  email       text not null check (length(email) between 6 and 254),
  song_id     text,
  song_title  text,
  created_at  timestamptz not null default now()
);
create unique index if not exists artist_fans_one_each on public.artist_fans (artist_id, email); -- emails are stored lower-case
create index if not exists artist_fans_recent on public.artist_fans (artist_id, created_at desc);
alter table public.artist_fans enable row level security;

drop policy if exists "artist_fans: artist reads"   on public.artist_fans;
drop policy if exists "artist_fans: artist deletes" on public.artist_fans;
create policy "artist_fans: artist reads"   on public.artist_fans for select to authenticated using (artist_id = auth.uid());
create policy "artist_fans: artist deletes" on public.artist_fans for delete to authenticated using (artist_id = auth.uid());
-- (no insert policy: fans are only ever added through fan_signup below)

-- returns 'ok' (also when they'd already signed up), 'email' (doesn't look like an email), 'gone' (no such page),
-- or 'busy' (too many sign-ups on this page in the last minute)
create or replace function public.fan_signup(name text, email text, song text default null, title text default null)
returns text
language plpgsql
volatile
security definer
set search_path = public
as $$
#variable_conflict use_column
declare who uuid; e text := lower(trim(coalesce(fan_signup.email, '')));
begin
  if length(e) > 254 or e !~ '^[^@\s<>"]+@[^@\s<>"]+\.[a-z]{2,}$' then return 'email'; end if;
  select a.user_id into who
  from public.profiles p join public.artist_pages a on a.user_id = p.user_id
  where p.username is not null and lower(p.username) = lower(name) and a.enabled
  order by p.updated_at desc nulls last limit 1;
  if who is null then return 'gone'; end if;
  if (select count(*) from public.artist_fans f where f.artist_id = who and f.created_at > now() - interval '1 minute') >= 20 then
    return 'busy';
  end if;
  insert into public.artist_fans (artist_id, email, song_id, song_title)
  values (who, e, left(song, 80), left(title, 160))
  on conflict (artist_id, email) do nothing;
  return 'ok';
end $$;
revoke all on function public.fan_signup(text, text, text, text) from public;
grant execute on function public.fan_signup(text, text, text, text) to anon, authenticated;
