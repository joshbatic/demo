-- *[demo] co-writing access rules, tightened. Run once in Supabase: SQL Editor -> New query -> paste -> Run.
-- Safe to run again. Written against the policies that were in place on 17 Oct 2026.
--
-- What was loose, and what this changes:
--  1. Anyone signed in could add themselves to ANY song as a co-writer (collab_members only checked user_id).
--     Now you can only join a song you own or have a pending invite to (or accepted in the last 10 minutes).
--  2. Anyone could create an "invite" for a song they don't own (only owner_id was checked), which together with
--     (1) was a way in. Now only the song's owner can invite.
--  3. An invitee could rewrite an invite (song, owner, who it's for) while answering it. Now they can only answer.
--  4. Invite matching used ILIKE on emails, where _ and % are wildcards. Now it's an exact, case-insensitive match.
--  5. A co-writer could change a shared song's owner_id, or create the shared row for someone else's song.
--     Now only the owner can create it, and nobody but the owner can hand it over.
--  6. Stopping sharing left the old co-writer list and invites behind. Now they're removed with it.
--  7. Usernames are made unique regardless of case (if that fails, duplicates already exist: see the notice).

-- helpers (security definer so they can look across tables without opening them up)
create or replace function public.owns_song(song text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.shared_songs s where s.id::text = song and s.owner_id = auth.uid())
$$;
create or replace function public.has_invite(song text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.collab_invites i
    where i.song_id::text = song
      and (i.invitee_user_id = auth.uid()
           or (i.invitee_email is not null and lower(i.invitee_email) = lower(auth.jwt() ->> 'email')))
      and (i.status = 'pending' or (i.status = 'accepted' and i.responded_at > now() - interval '10 minutes')))
$$;
revoke all on function public.owns_song(text) from public;
revoke all on function public.has_invite(text) from public;
grant execute on function public.owns_song(text), public.has_invite(text) to authenticated;

-- 1. joining a song
drop policy if exists "collab_members_insert" on public.collab_members;
create policy "collab_members_insert" on public.collab_members for insert to authenticated
  with check (user_id = auth.uid() and (public.owns_song(song_id::text) or public.has_invite(song_id::text)));
drop policy if exists "collab_members_update" on public.collab_members;
create policy "collab_members_update" on public.collab_members for update to authenticated
  using (user_id = auth.uid() or public.owns_song(song_id::text))
  with check ((user_id = auth.uid() and (public.owns_song(song_id::text) or public.has_invite(song_id::text)))
              or public.owns_song(song_id::text));

-- 2. sending invites
drop policy if exists "owner creates invites" on public.collab_invites;
create policy "owner creates invites" on public.collab_invites for insert to authenticated
  with check (owner_id = auth.uid() and public.owns_song(song_id::text));

-- 4. seeing and answering invites: exact matches only
drop policy if exists "collab_invites_select_v2" on public.collab_invites;
drop policy if exists "collab_invites_update_v2" on public.collab_invites;
drop policy if exists "invitee sees own invites" on public.collab_invites;
create policy "invitee sees own invites" on public.collab_invites for select to authenticated
  using (invitee_user_id = auth.uid());
drop policy if exists "invitee answers own invites" on public.collab_invites;
create policy "invitee answers own invites" on public.collab_invites for update to authenticated
  using (invitee_user_id = auth.uid()) with check (invitee_user_id = auth.uid());

-- 3. answering can't rewrite the invite
create or replace function public.collab_invites_guard()
returns trigger language plpgsql as $$
begin
  if auth.uid() is not null and auth.uid() is distinct from old.owner_id and (
       new.song_id is distinct from old.song_id or new.owner_id is distinct from old.owner_id
    or new.invitee_user_id is distinct from old.invitee_user_id or new.invitee_email is distinct from old.invitee_email) then
    raise exception 'Only the person who sent an invite can change who or what it is for';
  end if;
  return new;
end $$;
drop trigger if exists collab_invites_guard on public.collab_invites;
create trigger collab_invites_guard before update on public.collab_invites for each row execute function public.collab_invites_guard();

-- 5. shared songs: only the owner creates the shared copy, and ownership can't be taken
drop policy if exists "shared_songs_insert" on public.shared_songs;
-- (co-writers are included because an upsert is checked against this rule as well as the edit rule; with no
--  co-writer rows left once sharing stops, see 6., they can't use it to recreate someone else's song)
create policy "shared_songs_insert" on public.shared_songs for insert to authenticated
  with check (owner_id = auth.uid() or public.is_song_member(id, auth.uid()));
drop policy if exists "shared_songs_update" on public.shared_songs;
create policy "shared_songs_update" on public.shared_songs for update to authenticated
  using (owner_id = auth.uid() or public.is_song_member(id, auth.uid()))
  with check (owner_id = auth.uid() or public.is_song_member(id, auth.uid()));
create or replace function public.shared_songs_guard()
returns trigger language plpgsql as $$
begin
  if auth.uid() is not null and (new.id is distinct from old.id
     or (new.owner_id is distinct from old.owner_id and auth.uid() is distinct from old.owner_id)) then
    raise exception 'Only the owner can hand a shared song over';
  end if;
  return new;
end $$;
drop trigger if exists shared_songs_guard on public.shared_songs;
create trigger shared_songs_guard before update on public.shared_songs for each row execute function public.shared_songs_guard();

-- 6. stop sharing = co-writers and pending invites go too
create or replace function public.shared_songs_cleanup()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  delete from public.collab_members where song_id::text = old.id::text;
  delete from public.collab_invites where song_id::text = old.id::text;
  return old;
end $$;
drop trigger if exists shared_songs_cleanup on public.shared_songs;
create trigger shared_songs_cleanup after delete on public.shared_songs for each row execute function public.shared_songs_cleanup();

-- 7. one username per person, whatever the capitals
do $$ begin
  create unique index if not exists profiles_username_lower on public.profiles (lower(username)) where username is not null;
exception when unique_violation then
  raise notice 'Two profiles share a username (ignoring case). Rename one, then run this again.';
end $$;
