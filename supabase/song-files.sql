-- *[demo] song files: audio versions, stems and attachments.
-- Run once in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- One private bucket. Every file lives under a folder named after the signed-in user's id
-- (<user id>/<song id>/<file id>.<ext>), and these rules only let people read, add, change or
-- delete files inside their own folder. Nothing in it is public: the app plays files through
-- short-lived signed links.

-- No per-bucket size limit: uploads follow the project's own limit (Storage -> Settings).
insert into storage.buckets (id, name, public)
values ('song-files', 'song-files', false)
on conflict (id) do update set public = false;

drop policy if exists "song-files: read own" on storage.objects;
drop policy if exists "song-files: add own" on storage.objects;
drop policy if exists "song-files: change own" on storage.objects;
drop policy if exists "song-files: delete own" on storage.objects;

create policy "song-files: read own" on storage.objects for select to authenticated
  using (bucket_id = 'song-files' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "song-files: add own" on storage.objects for insert to authenticated
  with check (bucket_id = 'song-files' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "song-files: change own" on storage.objects for update to authenticated
  using (bucket_id = 'song-files' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'song-files' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "song-files: delete own" on storage.objects for delete to authenticated
  using (bucket_id = 'song-files' and (storage.foldername(name))[1] = auth.uid()::text);
