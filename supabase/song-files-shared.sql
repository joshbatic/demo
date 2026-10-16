-- *[demo] song files on shared songs: let everyone on a shared song play its audio and open its files.
-- Run once in the Supabase dashboard: SQL Editor -> New query -> paste -> Run (after song-files.sql).
--
-- Files live at <uploader's id>/<song id>/<file>. song-files.sql only lets people read their OWN folder,
-- so a co-writer couldn't play a demo the owner added (or the other way round): Supabase reports that as
-- "Object not found". This adds read access (only reading, nothing else) for files whose song is one you
-- own or have joined. Changing and deleting stay limited to each person's own files.

create or replace function public.can_read_song_file(song text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.shared_songs s where s.id::text = song and s.owner_id = auth.uid())
      or exists (select 1 from public.collab_members m where m.song_id::text = song and m.user_id = auth.uid())
$$;
revoke all on function public.can_read_song_file(text) from public;
grant execute on function public.can_read_song_file(text) to authenticated;

drop policy if exists "song-files: read shared" on storage.objects;
create policy "song-files: read shared" on storage.objects for select to authenticated
  using (bucket_id = 'song-files' and public.can_read_song_file((storage.foldername(name))[2]));
