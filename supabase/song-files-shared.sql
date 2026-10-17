-- *[demo] song files on shared songs: let everyone on a shared song play its audio and open its files.
-- Run once in the Supabase dashboard: SQL Editor -> New query -> paste -> Run (after song-files.sql). Safe to run again.
--
-- Files live at <uploader's id>/<song id>/<file>. song-files.sql only lets people read their OWN folder,
-- so a co-writer couldn't play a demo the owner added (or the other way round): Supabase reports that as
-- "Object not found". This adds read access (only reading, nothing else) when BOTH you and the person who
-- uploaded the file are on that song (its owner or a co-writer). Checking the uploader too means that
-- claiming an old song id later can't unlock files someone else uploaded to it.
-- Changing and deleting stay limited to each person's own files.

create or replace function public.on_song(song text, who uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select who is not null and (
         exists (select 1 from public.shared_songs s where s.id::text = song and s.owner_id = who)
      or exists (select 1 from public.collab_members m where m.song_id::text = song and m.user_id = who))
$$;
revoke all on function public.on_song(text, uuid) from public;

create or replace function public.can_read_song_file(uploader text, song text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare up uuid;
begin
  begin up := uploader::uuid; exception when others then return false; end;
  return public.on_song(song, auth.uid()) and public.on_song(song, up);
end
$$;
revoke all on function public.can_read_song_file(text, text) from public;
grant execute on function public.can_read_song_file(text, text) to authenticated;

drop policy if exists "song-files: read shared" on storage.objects;
create policy "song-files: read shared" on storage.objects for select to authenticated
  using (bucket_id = 'song-files'
         and public.can_read_song_file((storage.foldername(name))[1], (storage.foldername(name))[2]));

-- the earlier one-argument version is no longer used
drop function if exists public.can_read_song_file(text);
