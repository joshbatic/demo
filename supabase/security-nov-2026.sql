-- *[demo] fixes from the 10 Nov 2026 security review (applied 13 Nov 2026). Safe to run again.
-- (AI spending limits are in ai-budget.sql; the exact demo sign-up list is in demo-signups.sql.)

-- 1. The public "shares" bucket (share-page artwork, and audio for songs that only live on one device):
--    images and audio only, up to 50 MB. Nothing that a browser would run as a page (HTML, SVG, scripts).
update storage.buckets
   set allowed_mime_types = array['image/png', 'image/jpeg', 'image/webp', 'audio/*', 'application/octet-stream'],
       file_size_limit = 52428800
 where id = 'shares';

-- 2. Nudges between accounts. ping_user only reaches someone you've just invited, or a co-writer on a song you own
--    (to tell them it's gone); the realtime "library" channel only takes messages from its own account
--    (ping_user sends with the server's rights).
create or replace function public.ping_user(p_user uuid, p_event text)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null or p_user is null or p_user = me or p_event not in ('invite', 'gone') then return; end if;
  if p_event = 'invite' and not exists (select 1 from public.collab_invites i where i.owner_id = me and i.invitee_user_id = p_user
                                          and i.status = 'pending' and i.created_at > now() - interval '10 minutes') then return; end if;
  if p_event = 'gone' and not exists (select 1 from public.collab_members m join public.shared_songs s on s.id = m.song_id
                                        where s.owner_id = me and m.user_id = p_user) then return; end if;
  perform realtime.send('{}'::jsonb, p_event, 'library:' || p_user::text, true);
end $$;

alter policy "demo: library nudge" on realtime.messages
  with check (extension = 'broadcast' and realtime.topic() = 'library:' || (select auth.uid())::text);

-- 3. Membership checks answer only for yourself (they're used by row-level security with your own id);
--    on_song is only used inside other server functions.
create or replace function public.is_song_member(p_song_id text, p_uid uuid)
returns boolean language sql security definer set search_path = public as $$
  select p_uid = auth.uid() and exists (select 1 from collab_members where song_id = p_song_id and user_id = p_uid);
$$;
create or replace function public.is_song_owner(p_song_id text, p_uid uuid)
returns boolean language sql security definer set search_path = public as $$
  select p_uid = auth.uid() and exists (select 1 from shared_songs where id = p_song_id and owner_id = p_uid);
$$;
revoke execute on function public.on_song(text, uuid) from public, anon, authenticated;

-- 4. Beta invite codes: after 10 wrong tries in an hour, an account can't try again until the hour is up.
create table if not exists public.beta_code_tries (user_id uuid not null, at timestamptz not null default now());
alter table public.beta_code_tries enable row level security;   -- no policies: only redeem_beta_code uses it
create index if not exists beta_code_tries_user_at on public.beta_code_tries (user_id, at);

create or replace function public.redeem_beta_code(code text)
returns text language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); c text := upper(regexp_replace(coalesce(code, ''), '[^A-Za-z0-9]', '', 'g')); rid uuid;
begin
  if me is null or length(c) < 6 then return 'invalid'; end if;
  if (select count(*) from public.beta_code_tries t where t.user_id = me and t.at > now() - interval '1 hour') >= 10 then
    perform pg_sleep(0.5); return 'invalid';
  end if;
  select id into rid from public.beta_requests b
   where b.code = c and b.status = 'approved' and (b.user_id is null or b.user_id = me);
  if rid is null then
    insert into public.beta_code_tries (user_id) values (me);
    perform pg_sleep(0.5); return 'invalid';
  end if;
  update public.beta_requests set user_id = me where id = rid;
  return 'approved';
end $$;

-- 5. profiles.pro / pro_since are old (Pro comes from plans) and every signed-in person can read profiles:
--    clear them so they don't show who pays. Nothing writes them any more (security-hardening.sql).
update public.profiles set pro = false, pro_since = null where pro or pro_since is not null;

-- 6. One invite push per invite (the push function marks it).
alter table public.collab_invites add column if not exists pushed_at timestamptz;
