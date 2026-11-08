-- *[demo] share links, part 2: audio without a second copy, and links that can expire.
-- Run once in the Supabase dashboard: SQL Editor -> New query -> paste -> Run (after shares.sql,
-- song-files-shared.sql and song-files-kept.sql). Safe to run again. Applied 9 Nov 2026.
--
-- Audio: a link used to copy the demo into the public 'shares' bucket, so every link stored the audio twice.
-- Now the link records where the song's own file is (shares.audio_path, never shown publicly), and the
-- share-audio function hands listeners a short-lived address for that file. share_audio() only gives out a
-- file the link's owner may open themselves (their own upload, or one on a song they're on), and only while
-- the link exists and hasn't expired.
-- Expiry: shares.expires_at (null = never). An expired link opens as "not shared any more"; the owner's app
-- removes expired links and their files the next time it starts.

alter table public.shares add column if not exists audio_path text;
alter table public.shares add column if not exists expires_at timestamptz;

create or replace function public.get_share(sid text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select data || jsonb_build_object('updated', extract(epoch from updated_at)::bigint)
  from public.shares where id = sid and (expires_at is null or expires_at > now())
$$;
revoke all on function public.get_share(text) from public;
grant execute on function public.get_share(text) to anon, authenticated;

-- for the share-audio function (service role) only
create or replace function public.share_audio(sid text)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare r record; up text; song text;
begin
  select owner, audio_path into r from public.shares
   where id = sid and audio_path is not null and (expires_at is null or expires_at > now());
  if not found then return null; end if;
  up := (storage.foldername(r.audio_path))[1];
  song := (storage.foldername(r.audio_path))[2];
  if up = r.owner::text then return r.audio_path; end if;
  if public.on_song(song, r.owner) and (
       (up ~ '^[0-9a-f-]{36}$' and public.on_song(song, up::uuid))
       or exists (select 1 from public.shared_songs s where s.id::text = song
                    and (coalesce(s.data->'audio', '[]'::jsonb) @> jsonb_build_array(jsonb_build_object('path', r.audio_path))
                      or coalesce(s.data->'files', '[]'::jsonb) @> jsonb_build_array(jsonb_build_object('path', r.audio_path)))))
  then return r.audio_path; end if;
  return null;
end
$$;
revoke all on function public.share_audio(text) from public, anon, authenticated;
grant execute on function public.share_audio(text) to service_role;
