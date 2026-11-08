-- *[demo] song files on shared songs, part 2: files stay playable when a co-writer leaves.
-- Run once in the Supabase dashboard: SQL Editor -> New query -> paste -> Run (after song-files-shared.sql and
-- plans.sql). Safe to run again. Applied 9 Nov 2026.
--
-- song-files-shared.sql lets you read someone else's file on a song only while you AND the uploader are both on
-- it. When a co-writer left, everyone else lost their demos, even though the song still lists them. Now a file
-- also opens for anyone on the song while the shared copy of the song lists it (in its audio or files).
-- (When the owner stops sharing, the app first copies co-writers' files into the owner's own folder.)
-- Changing and deleting stay limited to each person's own files.

create or replace function public.can_read_song_file(uploader text, song text, path text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare up uuid;
begin
  if not public.on_song(song, auth.uid()) then return false; end if;
  begin up := uploader::uuid; exception when others then up := null; end;
  if up is not null and public.on_song(song, up) then return true; end if;
  return exists (select 1 from public.shared_songs s where s.id::text = song
                   and (coalesce(s.data->'audio', '[]'::jsonb) @> jsonb_build_array(jsonb_build_object('path', path))
                     or coalesce(s.data->'files', '[]'::jsonb) @> jsonb_build_array(jsonb_build_object('path', path))));
end
$$;
revoke all on function public.can_read_song_file(text, text, text) from public;
grant execute on function public.can_read_song_file(text, text, text) to authenticated;

alter policy "song-files: read shared" on storage.objects
  using (bucket_id = 'song-files' and public.paid()
         and public.can_read_song_file((storage.foldername(name))[1], (storage.foldername(name))[2], name));
